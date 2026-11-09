-- crow i/o for quartz
-- inputs: seed clock/gate, freeze gate, cv to a knob, v/oct to pitch
-- outputs: followed pitch, cloud envelope, random cv, freeze gate

local ControlSpec = require "controlspec"

local M = {}

local IN_MODES = {"off", "seed (clock/gate)", "freeze (gate)", "cv > knob", "v/oct > pitch"}
local OUT_MODES = {"off", "follow pitch", "envelope", "random", "freeze gate"}
local TARGETS = {"time", "size", "shape", "density", "feedback", "drywet",
  "cloud_reverb", "time_rnd", "size_rnd", "shape_rnd", "pitch_rnd"}
local TARGET_NAMES = {"time", "size", "shape", "density", "feedback", "dry/wet",
  "reverb", "time atten", "size atten", "shape atten", "pitch atten"}
local CMD = {cloud_reverb = "reverb"}

local ctx
local last_target = {}
local random_clock

local function out_mode(o) return params:get("crow_out_" .. o) end

local function send_knob(id, offset)
  local p = params:lookup_param(id)
  local raw = util.clamp(params:get_raw(id) + offset, 0, 1)
  engine[CMD[id] or id](p.controlspec:map(raw))
end

local function restore(id)
  if id then params:lookup_param(id):bang() end
end

local function setup_input(i)
  local mode = params:get("crow_in_" .. i)
  local target = TARGETS[params:get("crow_in_" .. i .. "_target")]
  restore(last_target[i])
  last_target[i] = nil

  if mode == 2 then
    crow.input[i].mode("change", 1.0, 0.1, "both")
    crow.input[i].change = function(s) engine.trig(s and 1 or 0) end
  elseif mode == 3 then
    crow.input[i].mode("change", 1.0, 0.1, "both")
    crow.input[i].change = function(s) ctx.set_frozen(s) end
  elseif mode == 4 then
    last_target[i] = target
    crow.input[i].mode("stream", 0.02)
    -- 0 to 5V sweeps the whole knob range on top of where it is set
    crow.input[i].stream = function(v) send_knob(target, v / 5) end
  elseif mode == 5 then
    crow.input[i].mode("stream", 0.02)
    crow.input[i].stream = function(v) engine.pitch(params:get("pitch") + v * 12) end
  else
    crow.input[i].mode("none")
  end
end

function M.setup()
  if not (crow and crow.connected and crow.connected()) then return end
  local clocked = 0
  for i = 1, 2 do
    setup_input(i)
    if params:get("crow_in_" .. i) == 2 then clocked = 1 end
  end
  engine.clocked(clocked)
  for o = 1, 4 do
    crow.output[o].slew = out_mode(o) == 4 and 0.05 or 0
    if out_mode(o) == 1 then crow.output[o].volts = 0 end
  end
  M.update_freeze()
end

function M.update_freeze()
  if not (crow and crow.connected and crow.connected()) then return end
  for o = 1, 4 do
    if out_mode(o) == 5 then crow.output[o].volts = ctx.get_frozen() and 5 or 0 end
  end
end

function M.add_params(context)
  ctx = context
  params:add_separator("crow")
  -- inputs start off: a seed clock set but unpatched would silence the cloud
  local defaults = {1, 1}
  for i = 1, 2 do
    params:add_option("crow_in_" .. i, "in " .. i, IN_MODES, defaults[i])
    params:set_action("crow_in_" .. i, function() M.setup() end)
    params:add_option("crow_in_" .. i .. "_target", "in " .. i .. " knob", TARGET_NAMES, i == 1 and 1 or 4)
    params:set_action("crow_in_" .. i .. "_target", function() M.setup() end)
  end
  for o = 1, 4 do
    params:add_option("crow_out_" .. o, "out " .. o, OUT_MODES, o + 1)
    params:set_action("crow_out_" .. o, function() M.setup() end)
  end
  params:add_control("crow_random_rate", "random rate",
    ControlSpec.new(0.1, 20, "exp", 0, 2, "hz"))
end

function M.init()
  local function connected() return crow and crow.connected and crow.connected() end

  local amp_poll = poll.set("amp", function(v)
    M.amp = v   -- also drives the screen's brightness
    if not connected() then return end
    for o = 1, 4 do
      if out_mode(o) == 3 then crow.output[o].volts = util.clamp(v * 10, 0, 5) end
    end
  end)
  amp_poll.time = 0.02
  amp_poll:start()

  local note_poll = poll.set("note", function(v)
    if not connected() then return end
    for o = 1, 4 do
      -- 0V = C4
      if out_mode(o) == 2 then crow.output[o].volts = (v - 60) / 12 end
    end
  end)
  note_poll.time = 0.02
  note_poll:start()

  random_clock = clock.run(function()
    while true do
      clock.sleep(1 / params:get("crow_random_rate"))
      if connected() then
        for o = 1, 4 do
          if out_mode(o) == 4 then crow.output[o].volts = math.random() * 10 - 5 end
        end
      end
    end
  end)

  crow.add = function() M.setup() end
  M.setup()
end

return M
