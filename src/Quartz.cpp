// Quartz: a SuperCollider UGen running the open-source Beads texture
// synthesizer DSP by Emilie Gillet (MIT license).
//
// Inputs (in order):
//   0 inL, 1 inR (audio)
//   2 time, 3 size, 4 shape (0..1), 5 pitch (semitones, -24..24),
//   6 density (0..1, noon = silent unless seeded)
//   7..10 time/size/shape/pitch randomness (-1..1, Beads attenurandomizers)
//   11 feedback, 12 drywet, 13 reverb (0..1)
//   14 freeze (gate), 15 seed button (0 off, 1 on, 2 locked)
//   16 trig (gate), 17 clocked (1 = trig acts as Beads' SEED jack)
//   18 quality (0 dirty tape, 1 clean tape, 2 vintage digital, 3 digital)
//   19 synth (1 = wavetable synth mode), 20 mono, 21 input gain
// Outputs: L, R

#include "SC_PlugIn.h"

#include <cmath>
#include <cstring>
#include <new>

#include "beads/dsp/processor.h"
#include "beads/dsp/synth.h"

static InterfaceTable* ft;

namespace {

const int kInternalBlock = 12;   // largest Beads block (48k / 4000 Hz)
const int kFifo = 64;
const size_t kBuffer1 = 512 * 1024;
const size_t kBuffer2 = 256 * 1024;
const size_t kReverbWords = 32768;

enum Inputs {
  IN_L, IN_R,
  IN_TIME, IN_SIZE, IN_SHAPE, IN_PITCH, IN_DENSITY,
  IN_TIME_RND, IN_SIZE_RND, IN_SHAPE_RND, IN_PITCH_RND,
  IN_FEEDBACK, IN_DRYWET, IN_REVERB,
  IN_FREEZE, IN_SEED, IN_TRIG, IN_CLOCKED,
  IN_QUALITY, IN_SYNTH, IN_MONO, IN_GAIN,
  IN_LAST
};

// 2nd order lowpass section; four of them make an 8th order Butterworth for
// anti-aliasing when the
// lo-fi modes run below 48 kHz.
struct Biquad {
  float b0, b1, b2, a1, a2, z1, z2;
  void Init(float fc, float sr, float q) {
    float k = tanf(float(M_PI) * fc / sr);
    float norm = 1.0f / (1.0f + k / q + k * k);
    b0 = k * k * norm; b1 = 2.0f * b0; b2 = b0;
    a1 = 2.0f * (k * k - 1.0f) * norm;
    a2 = (1.0f - k / q + k * k) * norm;
    z1 = z2 = 0.0f;
  }
  inline float Process(float x) {
    float y = b0 * x + z1;
    z1 = b1 * x - a1 * y + z2;
    z2 = b2 * x - a2 * y;
    return y;
  }
};

struct StereoLP {
  Biquad l[4], r[4];
  void Init(float fc, float sr) {
    const float q[4] = { 0.5098f, 0.6013f, 0.9000f, 2.5629f };
    for (int i = 0; i < 4; ++i) { l[i].Init(fc, sr, q[i]); r[i].Init(fc, sr, q[i]); }
  }
  inline void Process(float* a, float* b) {
    for (int i = 0; i < 4; ++i) { *a = l[i].Process(*a); *b = r[i].Process(*b); }
  }
};

struct Engine {
  beads::Processor processor;
  beads::Synth synth;
};

}  // namespace

struct Quartz : public Unit {
  Engine* engine;
  uint8_t* buffer1;
  uint8_t* buffer2;
  uint16_t* reverb_buffer;

  int media;
  bool mono;
  bool synth_mode;

  float host_sr;
  float ratio;        // internal sr / host sr
  int block;          // internal block size
  float phase;

  beads::FloatFrame prev_in, cur_in;
  beads::FloatFrame in_fifo[kInternalBlock];
  int in_count;

  beads::FloatFrame out_fifo[kFifo];
  int out_read, out_write, out_avail;
  beads::FloatFrame out_prev, out_next;

  StereoLP in_lp, out_lp;
  stmlib::GateFlags previous_trig;
  bool trig_buffer[kInternalBlock];
};

static void Quartz_next(Quartz* unit, int inNumSamples);
static void Quartz_Ctor(Quartz* unit);
static void Quartz_Dtor(Quartz* unit);

static float InternalRate(int media, bool synth) {
  if (synth) return 48000.0f;
  const float sr[4] = { 24000.0f, 48000.0f, 32000.0f, 48000.0f };
  return sr[media];
}

static void Configure(Quartz* unit, int media, bool mono, bool synth) {
  unit->media = media;
  unit->mono = mono;
  unit->synth_mode = synth;
  if (!synth) {
    unit->engine->processor.Configure(beads::Processor::Media(media), mono);
  }
  float internal_sr = InternalRate(media, synth);
  unit->ratio = internal_sr / unit->host_sr;
  unit->block = int(internal_sr / 4000.0f);
  unit->phase = 0.0f;
  unit->in_count = 0;
  unit->prev_in = 0.0f;
  unit->cur_in = 0.0f;
  float cutoff = internal_sr * 0.42f;
  if (cutoff > unit->host_sr * 0.45f) cutoff = unit->host_sr * 0.45f;
  unit->in_lp.Init(cutoff, unit->host_sr);
  unit->out_lp.Init(cutoff, unit->host_sr);
  // Prime the output with one block of silence so it never runs dry.
  for (int i = 0; i < kFifo; ++i) unit->out_fifo[i] = 0.0f;
  unit->out_read = 0;
  unit->out_write = unit->block + 1;
  unit->out_avail = unit->block + 1;
  unit->out_prev = 0.0f;
  unit->out_next = 0.0f;
}

static void Quartz_Ctor(Quartz* unit) {
  unit->engine = nullptr;
  unit->buffer1 = (uint8_t*)calloc(kBuffer1, 1);
  unit->buffer2 = (uint8_t*)calloc(kBuffer2, 1);
  unit->reverb_buffer = (uint16_t*)calloc(kReverbWords, sizeof(uint16_t));
  void* mem = calloc(1, sizeof(Engine));
  if (!unit->buffer1 || !unit->buffer2 || !unit->reverb_buffer || !mem) {
    Print("Quartz: not enough memory\n");
    free(mem);
    SETCALC(ft->fClearUnitOutputs);
    ClearUnitOutputs(unit, 1);
    return;
  }
  unit->engine = new (mem) Engine();

  uint8_t* buffers[3];
  buffers[0] = unit->buffer1;
  buffers[1] = unit->buffer1 + (256 * 1024);
  buffers[2] = unit->buffer2;
  unit->engine->processor.Init(buffers, unit->reverb_buffer);
  unit->engine->synth.Init(unit->reverb_buffer);

  unit->host_sr = float(SAMPLERATE);
  unit->previous_trig = stmlib::GATE_FLAG_LOW;

  int media = int(IN0(IN_QUALITY));
  if (media < 0) media = 0;
  if (media > 3) media = 3;
  Configure(unit, media, IN0(IN_MONO) > 0.5f, IN0(IN_SYNTH) > 0.5f);

  SETCALC(Quartz_next);
  Quartz_next(unit, 1);
}

static void Quartz_Dtor(Quartz* unit) {
  if (unit->engine) {
    unit->engine->~Engine();
    free(unit->engine);
  }
  free(unit->buffer1);
  free(unit->buffer2);
  free(unit->reverb_buffer);
}

static inline float Clamp(float x, float lo, float hi) {
  return x < lo ? lo : (x > hi ? hi : x);
}

static void RunBlock(Quartz* unit) {
  beads::Parameters p;
  p.time.base = Clamp(IN0(IN_TIME), 0.0f, 1.0f);
  p.size.base = Clamp(IN0(IN_SIZE), 0.0f, 1.0f);
  p.shape.base = Clamp(IN0(IN_SHAPE), 0.0f, 1.0f);
  p.pitch.base = Clamp(IN0(IN_PITCH), -48.0f, 48.0f);
  p.time.attenuverter = Clamp(IN0(IN_TIME_RND), -1.0f, 1.0f);
  p.size.attenuverter = Clamp(IN0(IN_SIZE_RND), -1.0f, 1.0f);
  p.shape.attenuverter = Clamp(IN0(IN_SHAPE_RND), -1.0f, 1.0f);
  p.pitch.attenuverter = Clamp(IN0(IN_PITCH_RND), -1.0f, 1.0f);
  p.time.cv = p.size.cv = p.shape.cv = p.pitch.cv = 0.0f;
  p.time.has_cv = p.size.has_cv = p.shape.has_cv = p.pitch.has_cv = false;
  p.monophonic_mode = false;

  beads::ModulatedParameter d;
  d.base = Clamp(IN0(IN_DENSITY), 0.0f, 1.0f);
  d.cv = 0.0f;

  beads::Processor::MixParameters m;
  m.feedback = Clamp(IN0(IN_FEEDBACK), 0.0f, 1.0f);
  m.dry_wet = Clamp(IN0(IN_DRYWET), 0.0f, 1.0f);
  m.reverb_amount = Clamp(IN0(IN_REVERB), 0.0f, 1.0f);
  m.output_gate = false;

  int seed = int(IN0(IN_SEED) + 0.5f);
  beads::SeedButtonState seed_state = seed >= 2
      ? beads::SEED_BUTTON_STATE_LOCKED
      : (seed == 1 ? beads::SEED_BUTTON_STATE_ON : beads::SEED_BUTTON_STATE_OFF);

  bool freeze[kInternalBlock];
  stmlib::GateFlags seed_flags[kInternalBlock];
  const bool frozen = IN0(IN_FREEZE) > 0.5f;
  for (int i = 0; i < unit->block; ++i) {
    freeze[i] = frozen;
    unit->previous_trig = seed_flags[i] =
        stmlib::ExtractGateFlags(unit->previous_trig, unit->trig_buffer[i]);
  }
  const stmlib::GateFlags* seed_input =
      IN0(IN_CLOCKED) > 0.5f ? seed_flags : nullptr;

  beads::FloatFrame out[kInternalBlock];
  if (unit->synth_mode) {
    unit->engine->synth.Render(
        seed_state, seed_input, freeze,
        beads::Synth::Resolution(unit->media), d, p, m, out, unit->block);
  } else {
    unit->engine->processor.Process(
        seed_state, seed_input, freeze, d, p, m,
        unit->in_fifo, out, unit->block);
  }
  for (int i = 0; i < unit->block; ++i) {
    unit->out_fifo[unit->out_write] = out[i];
    unit->out_write = (unit->out_write + 1) % kFifo;
  }
  unit->out_avail += unit->block;
}

static void Quartz_next(Quartz* unit, int inNumSamples) {
  if (!unit->engine) return;

  int media = int(IN0(IN_QUALITY));
  if (media < 0) media = 0;
  if (media > 3) media = 3;
  bool mono = IN0(IN_MONO) > 0.5f;
  bool synth = IN0(IN_SYNTH) > 0.5f;
  if (media != unit->media || mono != unit->mono || synth != unit->synth_mode) {
    Configure(unit, media, mono, synth);
  }

  const float* in_l = IN(IN_L);
  const float* in_r = IN(IN_R);
  const float* trig = IN(IN_TRIG);
  const bool trig_audio = INRATE(IN_TRIG) == calc_FullRate;
  float* out_l = OUT(0);
  float* out_r = OUT(1);
  const float gain = IN0(IN_GAIN);
  const bool soft_clip = !synth && media <= 1;
  const bool resample = unit->ratio < 0.999f;

  for (int n = 0; n < inNumSamples; ++n) {
    float l = in_l[n] * gain;
    float r = in_r[n] * gain;
    if (mono) r = l;
    if (soft_clip) {
      l = stmlib::SoftClip(l);
      r = stmlib::SoftClip(r);
    }
    if (resample) unit->in_lp.Process(&l, &r);
    unit->prev_in = unit->cur_in;
    unit->cur_in.l = l;
    unit->cur_in.r = r;
    const bool trig_high = (trig_audio ? trig[n] : trig[0]) > 0.0f;

    unit->phase += unit->ratio;
    if (unit->phase >= 1.0f) {
      unit->phase -= 1.0f;
      // Interpolate the internal-rate sample between the last two inputs.
      float t = unit->phase / unit->ratio;
      beads::FloatFrame s;
      s.l = unit->cur_in.l + (unit->prev_in.l - unit->cur_in.l) * t;
      s.r = unit->cur_in.r + (unit->prev_in.r - unit->cur_in.r) * t;
      unit->trig_buffer[unit->in_count] = trig_high;
      unit->in_fifo[unit->in_count++] = s;
      if (unit->in_count >= unit->block) {
        RunBlock(unit);
        unit->in_count = 0;
      }
      // Advance the output reader by one internal sample.
      unit->out_prev = unit->out_next;
      if (unit->out_avail > 0) {
        unit->out_next = unit->out_fifo[unit->out_read];
        unit->out_read = (unit->out_read + 1) % kFifo;
        --unit->out_avail;
      }
    }
    float t = 1.0f - unit->phase / unit->ratio;
    if (t < 0.0f) t = 0.0f;
    float ol = unit->out_next.l + (unit->out_prev.l - unit->out_next.l) * t;
    float orr = unit->out_next.r + (unit->out_prev.r - unit->out_next.r) * t;
    if (!resample) {
      ol = unit->out_next.l;
      orr = unit->out_next.r;
    } else {
      unit->out_lp.Process(&ol, &orr);
    }
    out_l[n] = ol;
    out_r[n] = orr;
  }
}

PluginLoad(Quartz) {
  ft = inTable;
  DefineDtorCantAliasUnit(Quartz);
}
