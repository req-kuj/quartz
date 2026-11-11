-- quartz
-- granular texture synth
-- DSP: Beads by Emilie Gillet
--
-- encoder 1: page
-- encoder 2, 3: knobs shown
-- key 2: freeze
-- key 3: cloud on/off
-- key 1 + key 3: grain burst
-- key 1 + key 2: random patch
-- hold key 1: help
--
-- grid shows the cloud
-- arc 1 = encoder 1 (page)
-- arc 2, 3 = encoder 2, 3
-- crow: set up in PARAMS

engine.name = "Quartz"

local ControlSpec = require "controlspec"
local fileselect = require "fileselect"
local crowio = include("lib/crowio")

local PLUGIN_DIR = _path.home .. "/.local/share/SuperCollider/Extensions/Quartz"
local PLUGIN = PLUGIN_DIR .. "/Quartz.so"

local QUALITY = {"dirty tape", "clean tape", "vintage digital", "digital"}
local SOURCES = {"grains", "synth drone", "synth follow", "synth midi", "sample"}
-- engine voice for each source (sample feeds the grains like live input)
local ENGINE_SOURCE = {0, 1, 2, 3, 0}

local function is_synth()
  local src = params:get("source")
  return src >= 2 and src <= 4
end

-- each page is named after its encoder 2 knob; like Beads, the main
-- knobs share a page with their attenurandomizer
local PATCH_PAGE = {name = "patch", a = "random_patch", b = "reset_patch", actions = true}
local SAMPLE_PAGE = {name = "sample", a = "sample_file", b = "sample_speed"}
local pages = {
  {name = "time", a = "time", b = "time_rnd"},
  {name = "size", a = "size", b = "size_rnd"},
  {name = "shape", a = "shape", b = "shape_rnd"},
  {name = "pitch", a = "pitch", b = "pitch_rnd"},
  {name = "density", a = "density", b = "drywet"},
  {name = "feedback", a = "feedback", b = "cloud_reverb"},
  {name = "quality", a = "quality", b = "gain"},
  {name = "source", a = "source", b = "octave"},
  PATCH_PAGE,
}
local page = 1

-- the sample page only exists while the sample source is chosen
local function rebuild_pages(with_sample)
  local has = pages[#pages - 1] == SAMPLE_PAGE
  if with_sample and not has then
    table.insert(pages, #pages, SAMPLE_PAGE)
  elseif not with_sample and has then
    table.remove(pages, #pages - 1)
  end
  page = util.clamp(page, 1, #pages)
end

-- voice params that only matter for some sources
-- (source: 1 grains, 2 synth drone, 3 synth follow, 4 synth midi)
local ONLY_FOR = {
  grid_lowest = {4},
  grid_dx = {4},
  grid_dy = {4},
  sample_file = {5},
  sample_speed = {5},
  octave = {3, 4},
  release = {3, 4},
  dry_level = {3, 4},
  glide = {3},
  threshold = {3},
}

local function active(id)
  local only = ONLY_FOR[id]
  if not only then return true end
  local src = params:get("source")
  for _, s in ipairs(only) do
    if s == src then return true end
  end
  return false
end

local function update_visibility()
  for id in pairs(ONLY_FOR) do
    if active(id) then params:show(id) else params:hide(id) end
  end
  if _menu.rebuild_params then _menu.rebuild_params() end
end

local k1_held = false
local burst = false
local toast, toast_clock
local dice_acc, reset_acc = 0, 0
local RESET_TURNS = 24
local show_help = true   -- splash on launch
local splash_count
local help_clock
local cloud_on = true
local frozen = false
local needs_restart = false
local midi_in
local held_notes = {}
local specks = {}
-- view state, declared early so param actions can reach it
local tape = {}            -- recorded level per column, oldest first
local scope_pts            -- latest scope snapshot from the engine
local clear_tape
local prev_osc_event, on_osc
local g = grid.connect()
local a = arc.connect()
local arc_acc = {0, 0}
local arc_page_acc = 0

-- install the compiled UGen where scsynth can find it
-- install or update the compiled UGen; returns true when a restart is needed
local function install_plugin()
  local src = norns.state.path .. "bin/quartz-plugin"
  if util.file_exists(PLUGIN) and os.execute("cmp -s '" .. src .. "' '" .. PLUGIN .. "'") then
    return false
  end
  util.make_dir(PLUGIN_DIR)
  os.execute("cp '" .. src .. "' '" .. PLUGIN .. "'")
  return util.file_exists(PLUGIN)
end

-- settings are remembered between sessions
local function last_state() return norns.state.data .. "last.pset" end

local function seed_state()
  if cloud_on then return 2 end
  return burst and 1 or 0
end

local function update_seed()
  engine.seed(seed_state())
  -- a burst sprays dense random grains whether the cloud is on or off,
  -- then density goes back to where the knob is
  if burst then
    engine.density(0.98)
  elseif params.lookup and params.lookup["density"] then
    params:lookup_param("density"):bang()
  end
end


-- pitch shown as a note in drone mode, as an interval everywhere else
local NOTE_NAMES = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
local INTERVALS = {"min 2nd", "maj 2nd", "min 3rd", "maj 3rd", "4th", "tritone",
  "5th", "min 6th", "maj 6th", "min 7th", "maj 7th"}

function pitch_name(v)
  v = util.round(v)
  if params:get("source") == 2 then
    local note = 48 + v
    return NOTE_NAMES[note % 12 + 1] .. (math.floor(note / 12) - 1)
  end
  if v == 0 then return "unison" end
  local sign = v > 0 and "+" or "-"
  local n = math.abs(v)
  local octs, rem = math.floor(n / 12), n % 12
  local parts = {}
  if octs == 1 then table.insert(parts, "oct") end
  if octs == 2 then table.insert(parts, "2 oct") end
  if rem > 0 then table.insert(parts, INTERVALS[rem]) end
  return sign .. table.concat(parts, "+")
end

-- patch: the sound-shaping knobs (not source, input, or midi setup)
local PATCH = {"time", "time_rnd", "size", "size_rnd", "shape", "shape_rnd",
  "pitch", "pitch_rnd", "density", "drywet", "feedback", "cloud_reverb", "quality"}

local function flash(msg)
  toast = msg
  if toast_clock then clock.cancel(toast_clock) end
  toast_clock = clock.run(function()
    clock.sleep(1)
    toast = nil
    toast_clock = nil
  end)
end

local function reset_patch()
  for _, id in ipairs(PATCH) do
    local p = params:lookup_param(id)
    params:set(id, p.controlspec and p.controlspec.default or p.default)
  end
  flash("reset")
end

-- random but musical: avoids silent density, delay mode, and wild pitch.
-- the four attenurandomizers stay where you set them
local function random_patch()
  local function r(lo, hi) return lo + math.random() * (hi - lo) end
  local intervals = {0, 0, 7, 12, -12, 5, -5, 19}
  params:set("time", r(0, 1))
  params:set("size", r(0.05, 0.9))
  params:set("shape", r(0, 1))
  params:set("pitch", intervals[math.random(#intervals)])
  params:set("density", math.random() < 0.5 and r(0.05, 0.42) or r(0.58, 0.98))
  -- attenurandomizers are left alone: small moves swing their knobs a lot
  params:set("drywet", r(0.4, 1))
  params:set("feedback", r(0, 0.6))
  params:set("cloud_reverb", r(0, 0.8))
  params:set("quality", math.random(4))
  flash("randomized")
end

-- patch page: encoder 2 rolls a new patch every few clicks,
-- encoder 3 must be turned a good way to reset (no accidents)
function patch_enc(n, d)
  if n == 2 then
    dice_acc = dice_acc + math.abs(d)
    if dice_acc >= 4 then
      dice_acc = 0
      random_patch()
    end
  elseif n == 3 then
    reset_acc = util.clamp(reset_acc + d, 0, RESET_TURNS)
    if reset_acc >= RESET_TURNS then
      reset_acc = 0
      reset_patch()
    end
  end
end

function set_frozen(state)
  frozen = state
  engine.freeze(frozen and 1 or 0)
  crowio.update_freeze()
end

-- file browser for samples, opened from the sample page
local selecting = false
function open_sample_browser()
  if selecting then return end
  selecting = true
  fileselect.enter(_path.audio, function(path)
    selecting = false
    if path and path ~= "cancel" then params:set("sample_file", path) end
  end)
end

local function add_params()
  params:add_separator("quartz")

  params:add_control("time", "time", ControlSpec.new(0, 1, "lin", 0, 0.5))
  params:set_action("time", function(v) engine.time(v) end)
  params:add_control("size", "size", ControlSpec.new(0, 1, "lin", 0, 0.5))
  params:set_action("size", function(v) engine.size(v) end)
  params:add_control("shape", "shape", ControlSpec.new(0, 1, "lin", 0, 0.5))
  params:set_action("shape", function(v) engine.shape(v) end)
  params:add_control("pitch", "pitch", ControlSpec.new(-24, 24, "lin", 1, 0),
    function(param) return pitch_name(param:get()) end)
  params:set_action("pitch", function(v) engine.pitch(v) end)
  params:add_control("density", "density", ControlSpec.new(0, 1, "lin", 0, 0.75))
  params:set_action("density", function(v) engine.density(v) end)
  -- random knobs (Beads' attenurandomizers), one per main knob
  for _, r in ipairs({{"time_rnd", 0.15}, {"size_rnd", 0.1}, {"shape_rnd", 0.1}, {"pitch_rnd", 0}}) do
    local main = r[1]:gsub("_rnd", "")
    params:add_control(r[1], main .. " attenurandomizer", ControlSpec.new(-1, 1, "lin", 0, r[2]))
    params:set_action(r[1], function(v) engine[r[1]](v) end)
  end

  params:add_control("feedback", "feedback", ControlSpec.new(0, 1, "lin", 0, 0.2))
  params:set_action("feedback", function(v) engine.feedback(v) end)
  params:add_control("cloud_reverb", "reverb", ControlSpec.new(0, 1, "lin", 0, 0.4))
  params:set_action("cloud_reverb", function(v) engine.reverb(v) end)
  params:add_control("drywet", "dry/wet", ControlSpec.new(0, 1, "lin", 0, 0.6))
  params:set_action("drywet", function(v) engine.drywet(v) end)
  params:add_option("quality", "quality", QUALITY, 4)
  params:set_action("quality", function(v)
    engine.quality(v - 1)
    clear_tape()   -- Beads starts a fresh buffer when the mode changes
  end)

  params:add_trigger("random_patch", "randomize patch")
  params:set_action("random_patch", function() random_patch() end)
  params:add_trigger("reset_patch", "reset patch")
  params:set_action("reset_patch", function() reset_patch() end)

  crowio.add_params({
    get_frozen = function() return frozen end,
    set_frozen = function(state) set_frozen(state) end,
  })

  params:add_separator("input")
  params:add_option("input_mode", "input", {"stereo", "mono (left)"}, 2)
  params:set_action("input_mode", function(v)
    engine.mono(v - 1)
    clear_tape()
  end)
  params:add_control("gain", "input gain", ControlSpec.new(0, 4, "lin", 0, 1))
  params:set_action("gain", function(v) engine.gain(v) end)

  params:add_separator("voice")
  params:add_option("source", "source", SOURCES, 1)
  params:set_action("source", function(v)
    engine.source(ENGINE_SOURCE[v])
    -- the scope only runs for the synth sources
    if engine.scope then engine.scope((v >= 2 and v <= 4) and 1 or 0) end
    scope_pts = nil
    engine.use_sample(v == 5 and 1 or 0)
    rebuild_pages(v == 5)
    -- release any held notes when leaving or entering synth midi
    for i = #held_notes, 1, -1 do held_notes[i] = nil end
    engine.gate(0)
    update_visibility()
  end)
  params:add_file("sample_file", "sample file", _path.audio)
  params:set_action("sample_file", function(f)
    if f and f ~= "" and f ~= "-" and f:sub(-1) ~= "/" then engine.load_sample(f) end
  end)
  params:add_control("sample_speed", "sample speed", ControlSpec.new(-2, 2, "lin", 0, 1, "x"))
  params:set_action("sample_speed", function(v) engine.samp_speed(v) end)
  params:add_number("octave", "octave", -3, 3, 0)
  params:set_action("octave", function(v) engine.octave(v) end)
  params:add_option("glide", "pitch follow", {"snap", "glide"}, 2)
  params:set_action("glide", function(v) engine.glide(v - 1) end)
  params:add_control("release", "release", ControlSpec.new(0.05, 8, "exp", 0, 1.5, "s"))
  params:set_action("release", function(v) engine.release(v) end)
  params:add_control("threshold", "follow threshold", ControlSpec.new(0.001, 0.2, "exp", 0, 0.02))
  params:set_action("threshold", function(v) engine.threshold(v) end)
  params:add_control("dry_level", "dry (follow/midi)", ControlSpec.new(0, 1, "lin", 0, 0))
  params:set_action("dry_level", function(v) engine.dry_level(v) end)
  -- grid keyboard for synth midi, laid out like doubledecker:
  -- each key right is dx semitones, each row up is dy (5 = fourths)
  params:add_number("grid_lowest", "grid lowest note", 0, 36, 24)
  params:add_number("grid_dx", "grid key dx", 1, 7, 1)
  params:add_number("grid_dy", "grid key dy", 1, 12, 5)
  params:add_number("midi_device", "midi device", 1, 16, 1)
  params:set_action("midi_device", function(v) connect_midi(v) end)
end

-- MIDI: last-note priority, plays the synth voice in midi mode
local function play_top_note()
  local n = held_notes[#held_notes]
  if n then
    engine.note(n)
    engine.gate(1)
  else
    engine.gate(0)
  end
end

function connect_midi(dev)
  if midi_in then midi_in.event = nil end
  midi_in = midi.connect(dev)
  midi_in.event = function(data)
    local msg = midi.to_msg(data)
    if msg.type == "note_on" and msg.vel > 0 then
      for i = #held_notes, 1, -1 do
        if held_notes[i] == msg.note then table.remove(held_notes, i) end
      end
      table.insert(held_notes, msg.note)
      play_top_note()
    elseif msg.type == "note_off" or (msg.type == "note_on" and msg.vel == 0) then
      for i = #held_notes, 1, -1 do
        if held_notes[i] == msg.note then table.remove(held_notes, i) end
      end
      play_top_note()
    elseif msg.type == "cc" and msg.cc == 64 then
      set_frozen(msg.val >= 64)
    end
  end
end

function init()
  needs_restart = install_plugin()
  -- a new engine file only loads after a restart; until then, ask for one
  if not engine.scope then needs_restart = true end
  add_params()
  if util.file_exists(last_state()) then params:read(last_state(), true) end
  params:bang()
  update_seed()
  engine.freeze(0)
  crowio.init()
  local in_poll = poll.set("in_amp", function(v) tape_input(v) end)
  if in_poll then
    in_poll.time = 0.02
    in_poll:start()
  end
  prev_osc_event = osc.event
  osc.event = on_osc

  local frame = metro.init()
  frame.time = 1 / 20
  frame.event = function()
    -- the file browser owns the screen while it is open
    if not selecting then redraw() end
  end
  frame:start()

  -- splash: show the help view with a 3, 2, 1 countdown on launch
  clock.run(function()
    for n = 3, 1, -1 do
      splash_count = n
      clock.sleep(1)
    end
    splash_count = nil
    if not k1_held then show_help = false end
  end)
end

function enc(n, d)
  if n == 1 then
    page = util.clamp(page + d, 1, #pages)
    arc_acc = {0, 0}
    dice_acc, reset_acc = 0, 0
  elseif pages[page].actions then
    patch_enc(n, d)
  elseif n == 2 and pages[page].a == "sample_file" then
    open_sample_browser()
  elseif n == 2 then
    if active(pages[page].a) then params:delta(pages[page].a, d) end
  elseif n == 3 then
    if active(pages[page].b) then params:delta(pages[page].b, d) end
  end
end

function key(n, z)
  if n == 1 then
    k1_held = z == 1
    if help_clock then clock.cancel(help_clock) help_clock = nil end
    if k1_held then
      -- holding key 1 on its own brings up the help view
      help_clock = clock.run(function()
        clock.sleep(0.6)
        show_help = true
        help_clock = nil
      end)
    else
      show_help = false
      if burst then burst = false update_seed() end
    end
  elseif n == 2 and z == 1 and k1_held then
    -- key 1 + key 2: randomize the patch
    if help_clock then clock.cancel(help_clock) help_clock = nil end
    show_help = false
    random_patch()
  elseif n == 2 and z == 1 then
    show_help = false
    set_frozen(not frozen)
  elseif n == 3 then
    if k1_held then
      -- key 1 + key 3: burst of grains while held, cloud on or off
      if help_clock then clock.cancel(help_clock) help_clock = nil end
      show_help = false
      burst = z == 1
      update_seed()
    elseif z == 1 then
      show_help = false
      cloud_on = not cloud_on
      update_seed()
    end
  end
end

-- main view. grains and sample show a tape: the record head sits on the
-- right, recorded audio scrolls left as it ages, and each grain is a tick
-- on the tape at its time position. pitch makes a grain drift: toward the
-- record head when higher, away when lower. freeze stops the tape, and the
-- heads keep reading through what's held.
-- the synth sources show a live scope of the output instead.
local TAPE_X0, TAPE_X1, REC_X, VIEW_Y = 4, 116, 120, 27
local TAPE_W = TAPE_X1 - TAPE_X0
local FPS = 20

-- buffer length in seconds per quality mode, [stereo, mono], measured from
-- the Beads DSP. the time knob maps linearly across it.
local BUFFER_SECONDS = {{16, 32}, {10.67, 21.33}, {8, 16}, {4, 8}}

local function buffer_seconds()
  return BUFFER_SECONDS[params:get("quality")][params:get("input_mode")]
end

local tape_peak = 0        -- loudest input since the last column
local tape_clock = 0
local clock_phase = 0

clear_tape = function()
  for i = 1, TAPE_W + 1 do tape[i] = 0 end
  tape_peak, tape_clock = 0, 0
end
clear_tape()

-- called from the in_amp poll
function tape_input(v)
  if v > tape_peak then tape_peak = v end
end

local function advance_tape()
  if frozen then return end
  tape_clock = tape_clock + 1 / FPS
  local column = buffer_seconds() / (TAPE_W + 1)
  while tape_clock >= column do
    tape_clock = tape_clock - column
    table.remove(tape, 1)
    table.insert(tape, tape_peak)
    tape_peak = 0
  end
end

local function spawn_speck()
  local spread_t = math.abs(params:get("time_rnd"))
  local spread_p = math.abs(params:get("pitch_rnd"))
  local function jitter(amt) return (math.random() + math.random() - 1) * amt end
  local time = util.clamp(params:get("time") + jitter(spread_t * 0.4), 0, 1)
  local semis = params:get("pitch") + jitter(spread_p * 12)
  local ratio = 2 ^ (semis / 12)
  -- relative to the record head, a playing grain moves at (ratio - 1);
  -- once frozen the tape stops, so it moves at the full ratio
  local speed = (frozen and ratio or ratio - 1) * TAPE_W / buffer_seconds() / FPS
  table.insert(specks, {
    x = REC_X - 4 - time * TAPE_W,
    vx = speed,
    gx = util.linlin(0, 1, 124, 4, time),               -- grid column
    gy = util.linlin(-24, 24, 40, 14, semis),           -- grid row
    age = 0,
    life = 4 + math.floor(params:get("size") * 16),
    shape = params:get("shape"),
    level = 0,
  })
end

local function spawn_grains()
  if not (cloud_on or burst) then return end
  local d = params:get("density")
  if burst then
    for _ = 1, 3 do spawn_speck() end
  elseif d < 0.48 then
    -- clocked: even pulses, faster the farther left
    local rate = util.linlin(0, 0.48, 1.0, 0.08, d)
    clock_phase = clock_phase + rate
    while clock_phase >= 1 do
      clock_phase = clock_phase - 1
      spawn_speck()
    end
  elseif d > 0.52 then
    -- random: chance per frame, more the farther right
    local chance = util.linlin(0.52, 1, 0.05, 1.6, d)
    while chance > 0 do
      if math.random() < chance then spawn_speck() end
      chance = chance - 1
    end
  end
end

-- age the grains; shape blends a sharp decay into a rise-and-fall swell,
-- brightness follows the cloud's actual loudness
local function update_specks()
  spawn_grains()
  local amp = crowio.amp
  local gain = amp and util.clamp(amp * 12, 0.15, 1) or 1
  for i = #specks, 1, -1 do
    local s = specks[i]
    local t = s.age / s.life
    local env = (1 - s.shape) * (1 - t) + s.shape * math.sin(math.pi * t)
    s.level = util.clamp(util.round(15 * env * gain), 0, 15)
    s.x = s.x + s.vx
    s.age = s.age + 1
    if s.age > s.life or s.x < TAPE_X0 or s.x > TAPE_X1 then table.remove(specks, i) end
  end
end

local function draw_tape()
  advance_tape()
  -- recorded audio, newest on the right
  for i, v in ipairs(tape) do
    local x = TAPE_X0 + i - 1
    local h = util.clamp(util.round(v * 14), 0, 6)
    if h > 0 then
      local age = 1 - i / #tape
      screen.level(frozen and 2 or (1 + util.round(2 * (1 - age))))
      screen.move(x + 0.5, VIEW_Y - h)
      screen.line(x + 0.5, VIEW_Y + h + 1)
      screen.stroke()
    end
  end
  screen.level(3)
  screen.move(TAPE_X0, VIEW_Y + 0.5)
  screen.line(TAPE_X1 + 1, VIEW_Y + 0.5)
  screen.stroke()

  -- record head: solid while recording, an outline when frozen
  if frozen then
    screen.level(6)
    screen.rect(REC_X - 1.5, VIEW_Y - 5.5, 3, 12)
    screen.stroke()
  else
    screen.level(15)
    screen.rect(REC_X - 1, VIEW_Y - 6, 3, 13)
    screen.fill()
    screen.level(8)
    screen.move(TAPE_X1 + 1, VIEW_Y + 0.5)
    screen.line(REC_X - 1, VIEW_Y + 0.5)
    screen.stroke()
  end

  -- grains: a tick each, with a short trail showing which way it drifts
  for _, s in ipairs(specks) do
    if s.level > 0 then
      local x = util.round(s.x)
      screen.level(s.level)
      screen.move(x + 0.5, VIEW_Y - 4)
      screen.line(x + 0.5, VIEW_Y + 5)
      screen.stroke()
      if math.abs(s.vx) > 0.05 then
        local dir = s.vx > 0 and 1 or -1
        for t = 1, 4 do
          local l = s.level - t * 3
          if l > 0 then
            screen.level(l)
            screen.pixel(x - dir * t * 2, VIEW_Y - 4)
            screen.pixel(x - dir * t * 2, VIEW_Y + 4)
            screen.fill()
          end
        end
      end
    end
  end
end

local function draw_scope()
  screen.level(2)
  for x = 2, 125, 3 do
    screen.pixel(x, VIEW_Y)
  end
  screen.fill()
  local pts = scope_pts
  if not pts or #pts < 2 then return end
  screen.level(15)
  local step = 123 / (#pts - 1)
  for i, v in ipairs(pts) do
    local x = 2 + (i - 1) * step
    local y = VIEW_Y - util.clamp(v, -1, 1) * 11
    if i == 1 then screen.move(x, y) else screen.line(x, y) end
  end
  screen.stroke()
end

local function draw_view()
  update_specks()
  if is_synth() then draw_scope() else draw_tape() end
end

-- scope snapshots arrive from the engine over OSC
on_osc = function(path, args, from)
  if path == "/quartz/scope" then
    scope_pts = args
  elseif prev_osc_event then
    prev_osc_event(path, args, from)
  end
end

-- mirror the grains onto the grid: column is time, row is pitch, brightness = life left
local function grid_note(x, y)
  return params:get("grid_lowest") + params:get("grid_dx") * x + params:get("grid_dy") * (8 - y)
end

local WHITE = {[0] = true, [2] = true, [4] = true, [5] = true, [7] = true, [9] = true, [11] = true}

-- synth midi: the grid is a keyboard. C is brighter, other white keys dim,
-- held notes (from grid or a MIDI keyboard) light up
local function grid_keyboard()
  local held = {}
  for _, n in ipairs(held_notes) do held[n] = true end
  g:all(0)
  for x = 1, g.cols or 16 do
    for y = 1, g.rows or 8 do
      local note = grid_note(x, y)
      local pc = note % 12
      if held[note] then
        g:led(x, y, 15)
      elseif pc == 0 then
        g:led(x, y, 6)
      elseif WHITE[pc] then
        g:led(x, y, 3)
      end
    end
  end
  g:refresh()
end

local function grid_redraw()
  if not g.device then return end
  if params:get("source") == 4 then
    grid_keyboard()
    return
  end
  local cols, rows = g.cols or 16, g.rows or 8
  local lit = {}
  for _, s in ipairs(specks) do
    local c = util.round(util.linlin(4, 124, 1, cols, s.gx))
    local r = util.round(util.clamp(util.linlin(14, 40, 1, rows, s.gy), 1, rows))
    local key = c .. ":" .. r
    lit[key] = math.max(lit[key] or 0, s.level)
  end
  g:all(0)
  for key, level in pairs(lit) do
    local c, r = key:match("(%d+):(%d+)")
    g:led(tonumber(c), tonumber(r), level)
  end
  g:refresh()
end

-- arc rings 1 and 2 show and edit the current page's params
local function page_param(n)
  if pages[page].actions then return nil end
  local id = n == 1 and pages[page].a or pages[page].b
  if id == "sample_file" then return nil end
  return active(id) and id or nil
end

-- position of a param as 0..1, plus whether it is bipolar or stepped
local function param_shape(id)
  local p = params:lookup_param(id)
  if p.t == params.tOPTION then
    return (p.selected - 1) / math.max(1, #p.options - 1), false, #p.options
  elseif p.t == params.tNUMBER then
    local span = p.max - p.min
    return (p.value - p.min) / span, p.min < 0, span + 1
  else
    return params:get_raw(id), p.controlspec.minval < 0, nil
  end
end

-- segments laid out like a knob: first on the lower left, sweeping
-- clockwise over the top to the lower right (270 degrees)
local function arc_segments(ring, count, current)
  local seg = math.floor(48 / count)
  local start = 1 - math.floor(seg * count / 2)
  for s = 0, count - 1 do
    local level = (s + 1 == current) and 15 or 2
    for i = 0, math.max(1, seg - 1) - 1 do
      a:led(ring, util.wrap(start + s * seg + i, 1, 64), level)
    end
  end
end

-- ring 1 turns pages, rings 2 and 3 are encoders 2 and 3
local function arc_redraw()
  if not a.device then return end
  a:all(0)
  arc_segments(1, #pages, page)
  for n = 1, 2 do
    local ring = n + 1
    local id = page_param(n)
    local pos, bipolar, steps
    if id then pos, bipolar, steps = param_shape(id) end
    if not id then
      -- param not used by this source: ring stays dark
    elseif steps then
      -- one segment per choice, the current one bright
      arc_segments(ring, steps, util.round(pos * (steps - 1)) + 1)
    elseif bipolar then
      -- fill from the top, clockwise for positive, counterclockwise for negative
      local amt = util.round((pos - 0.5) * 64)
      a:led(ring, 1, 6)
      for i = 1, math.abs(amt) do
        local led = amt > 0 and (1 + i) or (65 - i)
        a:led(ring, util.wrap(led, 1, 64), 12)
      end
    else
      local lit = util.round(pos * 64)
      for i = 1, 64 do
        a:led(ring, i, i <= lit and 12 or 1)
      end
    end
  end
  a:refresh()
end

a.delta = function(n, d)
  if n == 1 then
    -- ring 1 flips pages, like encoder 1
    arc_page_acc = arc_page_acc + d
    if math.abs(arc_page_acc) >= 24 then
      enc(1, arc_page_acc > 0 and 1 or -1)
      arc_page_acc = 0
    end
    return
  end
  if n > 3 then return end
  n = n - 1   -- rings 2 and 3 are encoders 2 and 3
  local id = page_param(n)
  if not id then return end
  local p = params:lookup_param(id)
  if p.t == params.tOPTION or p.t == params.tNUMBER then
    -- stepped params need a bit of travel per step
    arc_acc[n] = arc_acc[n] + d
    if math.abs(arc_acc[n]) >= 16 then
      params:delta(id, arc_acc[n] > 0 and 1 or -1)
      arc_acc[n] = 0
    end
  else
    params:delta(id, d / 4)
  end
end

-- in the synth sources some knobs take on Beads' synth-mode meanings
local SYNTH_BITS = {"4-bit", "16/6-bit", "7-bit", "16-bit"}

local function param_label(id)
  local name = params:lookup_param(id).name
  local value = params:string(id)
  if id:find("_rnd") then name = "attenurandom" end
  if is_synth() then
    if id == "feedback" then
      name = "wavetable"
      value = "bank " .. util.clamp(math.floor(params:get("feedback") * 12) + 1, 1, 12)
    elseif id == "drywet" then
      name = "osc/cloud"
    elseif id == "quality" then
      name = "bit depth"
      value = SYNTH_BITS[params:get("quality")]
    end
  end
  return name, value
end

local function draw_param(id, x)
  if id == "sample_file" then
    local f = params:get("sample_file")
    local name = (f and f ~= "-" and f:sub(-1) ~= "/") and f:match("[^/]+$") or nil
    screen.level(4)
    screen.move(x, 52)
    screen.text("file")
    screen.level(15)
    screen.move(x, 61)
    screen.text(name and name:gsub("%.%w+$", ""):sub(1, 12) or "turn to pick")
    return
  end
  if pages[page].actions then
    screen.level(4)
    screen.move(x, 52)
    if id == "random_patch" then
      screen.text("randomize")
      screen.level(15)
      screen.move(x, 61)
      screen.text("turn")
    else
      screen.text("reset")
      screen.level(3)
      screen.rect(x, 56, 58, 5)
      screen.stroke()
      screen.level(15)
      screen.rect(x, 56, 58 * reset_acc / RESET_TURNS, 5)
      screen.fill()
    end
    return
  end
  if not active(id) then return end
  local name, value = param_label(id)
  screen.level(4)
  screen.move(x, 52)
  screen.text(name)
  screen.level(15)
  screen.move(x, 61)
  screen.text(value)
end

-- mini panel drawn from the Beads module's open hardware layout
-- (positions in mm from the PCB, panel is 71 x 108 mm).
-- each knob shows its current value; the two on this page are bright.
local PANEL_SCALE = 0.53
local PANEL_KNOBS = {
  -- id, x, y, big
  {"time", 10.8, 79.1, true},
  {"density", 34.6, 93.3, true},
  {"pitch", 58.4, 79.1, true},
  {"size", 23.5, 56.8, true},
  {"shape", 45.7, 56.8, true},
  {"feedback", 6.0, 56.8, false},
  {"drywet", 63.2, 56.8, false},
  {"cloud_reverb", 63.2, 40.6, false},
  -- the four random knobs (attenurandomizers)
  {"time_rnd", 17.5, 36.8, false},
  {"size_rnd", 28.9, 36.8, false},
  {"shape_rnd", 40.3, 36.8, false},
  {"pitch_rnd", 51.8, 36.8, false},
}
local PANEL_JACKS_X = {6.0, 17.5, 28.9, 40.3, 51.8, 63.2}

function draw_panel(x0)
  local y0 = 3
  local function px(x) return x0 + x * PANEL_SCALE end
  local function py(y) return y0 + (108 - y) * PANEL_SCALE end

  screen.level(3)
  screen.rect(x0 + 0.5, y0 - 1.5, 71 * PANEL_SCALE, 60)
  screen.stroke()

  local on = {[pages[page].a] = true, [pages[page].b] = true}
  for _, k in ipairs(PANEL_KNOBS) do
    local id, cx, cy = k[1], px(k[2]), py(k[3])
    local r = k[4] and 3.5 or 2.2
    local lit = on[id]
    screen.level(lit and 15 or 4)
    screen.circle(cx, cy, r)
    if lit then screen.fill() else screen.stroke() end
    -- pointer at the knob's current value (7 to 5 o'clock sweep)
    local pos = param_shape(id)
    local ang = math.rad(-225 + pos * 270)
    screen.level(lit and 0 or 10)
    screen.move(cx, cy)
    screen.line(cx + math.cos(ang) * r, cy + math.sin(ang) * r)
    screen.stroke()
  end

  -- quality (media) button with its color LED beside it
  screen.level(on["quality"] and 15 or 5)
  screen.rect(px(34.6) - 1.5, py(72.4) - 1.5, 3, 3)
  screen.fill()
  screen.level(3 + params:get("quality") * 3)
  screen.pixel(px(28.3), py(72.4))
  screen.fill()

  -- illuminated buttons: freeze top left, seed (cloud) top right
  screen.level(frozen and 15 or 3)
  screen.circle(px(7.9), py(99.7), 2.5)
  screen.fill()
  screen.level(cloud_on and 15 or 3)
  screen.circle(px(61.3), py(99.7), 2.5)
  screen.fill()

  -- jack rows
  screen.level(2)
  for _, jx in ipairs(PANEL_JACKS_X) do
    for _, jy in ipairs({20.95, 6.35}) do
      screen.circle(px(jx), py(jy), 1.4)
      screen.stroke()
    end
  end
end

-- help view: controls on the left, the quartz panel on the right
local HELP_LINES = {
  {"encoder 1", "page"},
  {"encoder 2, 3", "knobs"},
  {"key 2", "freeze"},
  {"key 3", "cloud"},
  {"key 1 + 3", "burst"},
  {"key 1 + 2", "random"},
}

local function draw_help()
  screen.level(15)
  screen.move(0, 7)
  screen.text("quartz")
  if splash_count then
    screen.level(4)
    screen.move(58, 7)
    screen.text(splash_count .. "...")
  end
  for i, line in ipairs(HELP_LINES) do
    local y = 7 + i * 9
    screen.level(4)
    screen.move(0, y)
    screen.text(line[1])
    screen.level(15)
    screen.move(58, y)
    screen.text(line[2])
  end

  draw_panel(89)
end

function redraw()
  if selecting then return end
  screen.clear()
  screen.aa(0)
  screen.font_size(8)

  if needs_restart then
    screen.level(15)
    screen.move(64, 28)
    screen.text_center("quartz installed")
    screen.move(64, 40)
    screen.text_center("SYSTEM > RESTART")
    screen.update()
    return
  end

  if show_help then
    draw_help()
    screen.update()
    return
  end

  screen.level(15)
  screen.move(0, 7)
  screen.text(toast or "quartz")
  screen.level(4)
  screen.move(128, 7)
  -- the title is the first knob's label, so it follows synth relabels
  local title = pages[page].name
  if not pages[page].actions and pages[page] ~= SAMPLE_PAGE then
    title = param_label(pages[page].a)
  end
  screen.text_right(title .. " " .. page .. "/" .. #pages)

  draw_view()
  grid_redraw()
  arc_redraw()

  screen.level(frozen and 15 or 2)
  screen.move(0, 43)
  screen.text(frozen and "frozen" or "")
  screen.level(cloud_on and 2 or 15)
  screen.move(128, 43)
  if burst then
    screen.level(15)
    screen.text_right("burst")
  else
    screen.text_right(cloud_on and "" or "cloud off")
  end

  draw_param(pages[page].a, 0)
  draw_param(pages[page].b, 66)
  screen.update()
end

-- grid keys play notes in synth midi, sharing MIDI's last-note priority
g.key = function(x, y, z)
  if params:get("source") ~= 4 then return end
  local note = grid_note(x, y)
  for i = #held_notes, 1, -1 do
    if held_notes[i] == note then table.remove(held_notes, i) end
  end
  if z == 1 then table.insert(held_notes, note) end
  play_top_note()
end

function cleanup()
  if not needs_restart then params:write(last_state()) end
  osc.event = prev_osc_event
  if midi_in then midi_in.event = nil end
  if g.device then
    g:all(0)
    g:refresh()
  end
  if a.device then
    a:all(0)
    a:refresh()
  end
end
