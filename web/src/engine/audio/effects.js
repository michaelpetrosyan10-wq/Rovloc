// Roblox SoundEffects as WebAudio graphs. Each builder returns { input, output, set(props), tail, reverb } so a
// chain can be wired in order and the environment chain can retune its slots smoothly.
//   Equalizer   3-band crossover: < 400 Hz, 400 Hz - 4 kHz, > 4 kHz, each band's gain in dB (-80 = off)
//   Reverb      convolution with a generated impulse (exponentially decaying noise; DecayTime = RT60; density and
//               diffusion shape the early reflections); WetLevel / DryLevel in dB
//   Echo        delay line with feedback; WetLevel / DryLevel in dB
//   Distortion  soft-clip wave shaper, Level 0..1
//   Tremolo     amplitude LFO (Frequency Hz, Depth 0..1, Duty = the share of the cycle at full level)
//   Chorus      a 20 ms delay swept by an LFO (Rate, Depth), Mix wet share
//   Flanger     a 1-6 ms delay swept by an LFO with feedback (Rate, Depth), Mix wet share
//   Compressor  DynamicsCompressor (Threshold dB, Ratio <= 20, Attack, Release) + GainMakeup dB
//   PitchShift  applied by the voice as a playback-rate multiplier (Octave), so it is not a node here
// Impulses and LFO waves are cached and shared.

import { Random } from '../math.js';

const dbToGain = (db) => (db <= -79.9 ? 0 : 10 ** (db / 20));
const MAX_IMPULSE = 6; // seconds: longer tails are cut (Roblox reverbs go to 20 s; the last seconds are inaudible)

const impulseCache = new Map();
const pulseCache = new Map();
const curveCache = new Map();

/** A stereo reverb impulse for (decay, density, diffusion). */
export function impulse(ctx, decay, density = 1, diffusion = 1) {
  const key = `${decay.toFixed(1)}:${density.toFixed(1)}:${diffusion.toFixed(1)}:${ctx.sampleRate}`;
  let buf = impulseCache.get(key);
  if (buf) return buf;
  const sr = ctx.sampleRate;
  const seconds = Math.min(MAX_IMPULSE, Math.max(0.15, decay * 1.1));
  const n = Math.floor(seconds * sr);
  buf = ctx.createBuffer(2, n, sr);
  const rng = new Random(Math.floor(decay * 1000) + 77);
  const k = Math.log(1000) / Math.max(0.05, decay); // -60 dB at `decay`
  const sparse = 1 - 0.85 * (1 - density); // low density: sparser early reflections
  const preDelay = Math.floor(sr * (0.004 + 0.012 * (1 - diffusion)));
  for (let c = 0; c < 2; c++) {
    const d = buf.getChannelData(c);
    let lp = 0;
    const smooth = 0.25 + 0.6 * (1 - diffusion) * 0.5;
    for (let i = preDelay; i < n; i++) {
      const t = (i - preDelay) / sr;
      let w = rng.next() * 2 - 1;
      if (t < 0.08 && rng.next() > sparse) w = 0;
      lp += (w - lp) * (1 - smooth * Math.min(1, t * 2)); // highs decay faster later in the tail
      d[i] = lp * Math.exp(-k * t);
    }
  }
  impulseCache.set(key, buf);
  return buf;
}

function pulseWave(ctx, duty) {
  const key = duty.toFixed(2);
  let wave = pulseCache.get(key);
  if (wave) return wave;
  const N = 12;
  const real = new Float32Array(N);
  const imag = new Float32Array(N);
  for (let h = 1; h < N; h++) {
    // pulse of width `duty`, softened (Lanczos sigma)
    const sigma = Math.sin((Math.PI * h) / N) / ((Math.PI * h) / N);
    real[h] = ((2 / (h * Math.PI)) * Math.sin(Math.PI * h * duty)) * sigma;
    imag[h] = 0;
  }
  wave = ctx.createPeriodicWave(real, imag, { disableNormalization: false });
  pulseCache.set(key, wave);
  return wave;
}

function softClip(level) {
  const key = level.toFixed(2);
  let curve = curveCache.get(key);
  if (curve) return curve;
  const k = 1 + level * 60;
  const n = 1024;
  curve = new Float32Array(n);
  const norm = Math.tanh(k);
  for (let i = 0; i < n; i++) {
    const x = (i / (n - 1)) * 2 - 1;
    curve[i] = Math.tanh(k * x) / norm;
  }
  curveCache.set(key, curve);
  return curve;
}

/**
 * Builds one effect.
 * @param {BaseAudioContext} ctx
 * @param {{kind: string, props: Record<string, number>}} effect
 */
export function buildEffect(ctx, effect) {
  const p = effect.props || {};
  switch (effect.kind) {
    case 'Equalizer': {
      const input = ctx.createGain();
      const output = ctx.createGain();
      const low = ctx.createBiquadFilter();
      low.type = 'lowpass';
      low.frequency.value = 400;
      const high = ctx.createBiquadFilter();
      high.type = 'highpass';
      high.frequency.value = 4000;
      const midA = ctx.createBiquadFilter();
      midA.type = 'highpass';
      midA.frequency.value = 400;
      const midB = ctx.createBiquadFilter();
      midB.type = 'lowpass';
      midB.frequency.value = 4000;
      const gl = ctx.createGain();
      const gm = ctx.createGain();
      const gh = ctx.createGain();
      input.connect(low).connect(gl).connect(output);
      input.connect(midA).connect(midB).connect(gm).connect(output);
      input.connect(high).connect(gh).connect(output);
      const set = (q, fade = 0) => {
        ramp(ctx, gl.gain, dbToGain(q.LowGain ?? -20), fade);
        ramp(ctx, gm.gain, dbToGain(q.MidGain ?? -10), fade);
        ramp(ctx, gh.gain, dbToGain(q.HighGain ?? 0), fade);
      };
      set(p);
      return { input, output, set, tail: 0 };
    }
    case 'Reverb': {
      const input = ctx.createGain();
      const output = ctx.createGain();
      const conv = ctx.createConvolver();
      conv.normalize = true;
      conv.buffer = impulse(ctx, p.DecayTime ?? 1.5, p.Density ?? 1, p.Diffusion ?? 1);
      const wet = ctx.createGain();
      const dry = ctx.createGain();
      input.connect(dry).connect(output);
      input.connect(conv).connect(wet).connect(output);
      let decay = p.DecayTime ?? 1.5;
      const set = (q, fade = 0) => {
        ramp(ctx, wet.gain, dbToGain(q.WetLevel ?? 0) * 0.9, fade);
        ramp(ctx, dry.gain, dbToGain(q.DryLevel ?? 0), fade);
        const d = q.DecayTime ?? decay;
        if (Math.abs(d - decay) > 0.05) {
          decay = d;
          conv.buffer = impulse(ctx, d, q.Density ?? 1, q.Diffusion ?? 1);
        }
      };
      set(p);
      return { input, output, set, tail: Math.min(MAX_IMPULSE, decay), reverb: true };
    }
    case 'Echo': {
      const input = ctx.createGain();
      const output = ctx.createGain();
      const delay = ctx.createDelay(5);
      const fb = ctx.createGain();
      const wet = ctx.createGain();
      const dry = ctx.createGain();
      input.connect(dry).connect(output);
      input.connect(delay);
      delay.connect(fb).connect(delay);
      delay.connect(wet).connect(output);
      const set = (q, fade = 0) => {
        ramp(ctx, delay.delayTime, Math.max(0.01, q.Delay ?? 1), fade);
        ramp(ctx, fb.gain, Math.min(0.95, q.Feedback ?? 0.5), fade);
        ramp(ctx, wet.gain, dbToGain(q.WetLevel ?? 0), fade);
        ramp(ctx, dry.gain, dbToGain(q.DryLevel ?? 0), fade);
      };
      set(p);
      const fbk = Math.min(0.95, p.Feedback ?? 0.5);
      const wetDb = Math.min(0, p.WetLevel ?? 0);
      const repeats = fbk > 0.001 ? Math.max(1, (-60 - wetDb) / (20 * Math.log10(fbk))) : 1;
      return { input, output, set, tail: Math.min(14, (p.Delay ?? 1) * repeats) };
    }
    case 'Distortion': {
      const shaper = ctx.createWaveShaper();
      shaper.curve = softClip(p.Level ?? 0.75);
      const out = ctx.createGain();
      out.gain.value = 1 / (1 + (p.Level ?? 0.75) * 0.6);
      shaper.connect(out);
      return { input: shaper, output: out, set: () => {}, tail: 0 };
    }
    case 'Tremolo': {
      const amp = ctx.createGain();
      const depth = Math.min(1, Math.max(0, p.Depth ?? 1));
      const duty = Math.min(0.95, Math.max(0.05, p.Duty ?? 0.5));
      amp.gain.value = 1 - depth / 2;
      const lfo = ctx.createOscillator();
      lfo.setPeriodicWave(pulseWave(ctx, duty));
      lfo.frequency.value = Math.max(0.01, p.Frequency ?? 5);
      const lfoGain = ctx.createGain();
      lfoGain.gain.value = depth / 2;
      lfo.connect(lfoGain).connect(amp.gain);
      lfo.start();
      return { input: amp, output: amp, set: () => {}, tail: 0, stop: () => safeStop(lfo) };
    }
    case 'Chorus':
    case 'Flanger': {
      const flanger = effect.kind === 'Flanger';
      const input = ctx.createGain();
      const output = ctx.createGain();
      const delay = ctx.createDelay(0.1);
      const base = flanger ? 0.0035 : 0.02;
      const swing = (flanger ? 0.0025 : 0.008) * Math.min(1, Math.max(0.01, p.Depth ?? 0.5));
      delay.delayTime.value = base;
      const lfo = ctx.createOscillator();
      lfo.frequency.value = Math.max(0.01, p.Rate ?? 0.5);
      const lg = ctx.createGain();
      lg.gain.value = swing;
      lfo.connect(lg).connect(delay.delayTime);
      lfo.start();
      const mix = Math.min(1, Math.max(0, p.Mix ?? 0.5));
      const wet = ctx.createGain();
      const dry = ctx.createGain();
      wet.gain.value = mix;
      dry.gain.value = 1 - mix * 0.5;
      input.connect(dry).connect(output);
      input.connect(delay).connect(wet).connect(output);
      if (flanger) {
        const fb = ctx.createGain();
        fb.gain.value = 0.45;
        delay.connect(fb).connect(delay);
      }
      const set = (q, fade = 0) => {
        const m = Math.min(1, Math.max(0, q.Mix ?? mix));
        ramp(ctx, wet.gain, m, fade);
        ramp(ctx, dry.gain, 1 - m * 0.5, fade);
        if (q.Rate !== undefined) ramp(ctx, lfo.frequency, Math.max(0.01, q.Rate), fade);
      };
      return { input, output, set, tail: 0.05, stop: () => safeStop(lfo) };
    }
    case 'Compressor': {
      const comp = ctx.createDynamicsCompressor();
      comp.threshold.value = Math.max(-60, Math.min(0, p.Threshold ?? -40));
      comp.ratio.value = Math.min(20, Math.max(1, p.Ratio ?? 40));
      comp.attack.value = Math.min(1, Math.max(0, p.Attack ?? 0.1));
      comp.release.value = Math.min(1, Math.max(0.01, p.Release ?? 0.1));
      comp.knee.value = 3;
      const make = ctx.createGain();
      make.gain.value = dbToGain(p.GainMakeup ?? 0);
      comp.connect(make);
      return { input: comp, output: make, set: () => {}, tail: 0 };
    }
    default:
      return null;
  }
}

/**
 * Wires a chain of effects (PitchShift skipped: the voice applies it as rate). Returns { input, output, tail,
 * reverbs, stop }.
 */
export function buildChain(ctx, effects) {
  const input = ctx.createGain();
  let last = input;
  let tail = 0;
  let reverbs = 0;
  const stops = [];
  const slots = [];
  for (const e of effects || []) {
    if (e.kind === 'PitchShift') continue;
    const fx = buildEffect(ctx, e);
    if (!fx) continue;
    last.connect(fx.input);
    last = fx.output;
    tail += fx.tail;
    if (fx.reverb) reverbs++;
    if (fx.stop) stops.push(fx.stop);
    slots.push(fx);
  }
  return {
    input,
    output: last,
    tail: Math.min(14, tail),
    reverbs,
    slots,
    stop: () => stops.forEach((s) => s()),
  };
}

/** The PitchShift octave product of a chain (applied to playback rate). */
export function pitchOf(effects) {
  let o = 1;
  for (const e of effects || []) if (e.kind === 'PitchShift') o *= Math.min(2, Math.max(0.5, e.props.Octave ?? 1.25));
  return o;
}

export function ramp(ctx, param, value, fade) {
  const t = ctx.currentTime;
  if (!fade) {
    param.cancelScheduledValues(t);
    param.setValueAtTime(value, t);
    return;
  }
  param.cancelScheduledValues(t);
  param.setValueAtTime(param.value, t);
  param.linearRampToValueAtTime(value, t + fade);
}

function safeStop(node) {
  try {
    node.stop();
  } catch { /* already stopped */ }
}

export { dbToGain };
