// The 11 source sounds every Roblox recipe is built from (SoundLibrary.luau: the engine files under
// rbxasset://sounds/), synthesized once at start-up because the web build ships no sound files. Each is generated to
// the character SoundLibrary documents and to its catalog length, so the recipes' PlaybackRegions, speeds and loop
// slices land on the same kind of material:
//   Falling           1.2 s  sustained broadband wind rush (seamless loop): drones, hiss, rain air, breath, static
//   FootstepsPlastic  0.35 s dry clicky footstep transients (two steps, seamless loop)
//   GetUp             0.4 s  soft body and cloth rustle
//   Jump              0.25 s short airy whoosh
//   JumpLand          0.2 s  dull low thump
//   Swim              0.8 s  wet sloshing stroke (seamless loop)
//   Explosion         1.8 s  boom with a crackling tail
//   WaterImpact       0.7 s  splash transient with droplets
//   Oof               0.35 s short voiced grunt
//   Ouch              0.35 s short voiced cry
//   VolumeSlider      0.08 s tiny tonal tick (looped slices of it become pitched hums)
// Everything is deterministic (a fixed-seed generator), so every load sounds the same.

import { Random } from '../math.js';

/** Catalog lengths (SoundLibrary estimates) in seconds. */
export const SampleLengths = Object.freeze({
  Falling: 1.2, FootstepsPlastic: 0.35, GetUp: 0.4, Jump: 0.25, JumpLand: 0.2, Swim: 0.8, Explosion: 1.8,
  WaterImpact: 0.7, Oof: 0.35, Ouch: 0.35, VolumeSlider: 0.08,
});

/** Files that loop seamlessly as a whole (the engine's looping character sounds). */
export const Seamless = new Set(['Falling', 'FootstepsPlastic', 'Swim']);

/** A direct-form biquad for offline generation. */
class Biquad {
  constructor(type, freq, q, sr, gainDb = 0) {
    this.set(type, freq, q, sr, gainDb);
    this.x1 = this.x2 = this.y1 = this.y2 = 0;
  }
  set(type, freq, q, sr, gainDb = 0) {
    const w = (2 * Math.PI * Math.min(freq, sr * 0.49)) / sr;
    const cs = Math.cos(w);
    const sn = Math.sin(w);
    const alpha = sn / (2 * q);
    const A = 10 ** (gainDb / 40);
    let b0;
    let b1;
    let b2;
    let a0;
    let a1;
    let a2;
    if (type === 'lowpass') {
      b0 = (1 - cs) / 2; b1 = 1 - cs; b2 = (1 - cs) / 2; a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha;
    } else if (type === 'highpass') {
      b0 = (1 + cs) / 2; b1 = -(1 + cs); b2 = (1 + cs) / 2; a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha;
    } else if (type === 'bandpass') {
      b0 = alpha; b1 = 0; b2 = -alpha; a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha;
    } else {
      // peaking
      b0 = 1 + alpha * A; b1 = -2 * cs; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cs; a2 = 1 - alpha / A;
    }
    this.b0 = b0 / a0; this.b1 = b1 / a0; this.b2 = b2 / a0; this.a1 = a1 / a0; this.a2 = a2 / a0;
  }
  run(x) {
    const y = this.b0 * x + this.b1 * this.x1 + this.b2 * this.x2 - this.a1 * this.y1 - this.a2 * this.y2;
    this.x2 = this.x1; this.x1 = x; this.y2 = this.y1; this.y1 = y;
    return y;
  }
}

function normalize(data, peak = 0.9) {
  let m = 0;
  for (let i = 0; i < data.length; i++) m = Math.max(m, Math.abs(data[i]));
  if (m > 0) for (let i = 0; i < data.length; i++) data[i] *= peak / m;
  return data;
}

/** Makes a buffer loop seamlessly by crossfading its tail into its head (equal-power). */
function seamless(data, sr, fade = 0.08) {
  const n = Math.floor(fade * sr);
  const len = data.length - n;
  const out = new Float32Array(len);
  for (let i = 0; i < len; i++) out[i] = data[i];
  for (let i = 0; i < n; i++) {
    const t = i / n;
    out[i] = data[i] * Math.sin((t * Math.PI) / 2) + data[len + i] * Math.cos((t * Math.PI) / 2);
  }
  return out;
}

function pinkNoise(rng) {
  let b0 = 0;
  let b1 = 0;
  let b2 = 0;
  return () => {
    const w = rng.next() * 2 - 1;
    b0 = 0.99765 * b0 + w * 0.099046;
    b1 = 0.963 * b1 + w * 0.2965164;
    b2 = 0.57 * b2 + w * 1.0526913;
    return (b0 + b1 + b2 + w * 0.1848) * 0.2;
  };
}

/** Additive glottal source: harmonics of f0 with a -12 dB/oct roll-off (a voiced buzz). */
function voiced(f0At, seconds, sr, rng, breath = 0.08) {
  const n = Math.floor(seconds * sr);
  const out = new Float32Array(n);
  let phase = 0;
  for (let i = 0; i < n; i++) {
    const t = i / sr;
    const f0 = f0At(t) * (1 + 0.012 * Math.sin(t * 2 * Math.PI * 5.5));
    phase += f0 / sr;
    let s = 0;
    for (let h = 1; h <= 24; h++) {
      if (h * f0 > sr * 0.45) break;
      s += Math.sin(2 * Math.PI * h * phase) / (h * 1.2);
    }
    out[i] = s + (rng.next() * 2 - 1) * breath;
  }
  return out;
}

function formants(src, sr, list) {
  const out = new Float32Array(src.length);
  const filters = list.map(([f, q, g]) => ({ bq: new Biquad('bandpass', f, q, sr), g }));
  for (let i = 0; i < src.length; i++) {
    let s = 0;
    for (const f of filters) s += f.bq.run(src[i]) * f.g;
    out[i] = s;
  }
  return out;
}

const GENERATORS = {
  Falling(sr, rng) {
    const len = SampleLengths.Falling + 0.08;
    const n = Math.floor(len * sr);
    const out = new Float32Array(n);
    const pink = pinkNoise(rng);
    const bp = new Biquad('bandpass', 700, 0.5, sr);
    for (let i = 0; i < n; i++) {
      const t = i / sr;
      const swell = 0.75 + 0.25 * Math.sin(t * 2 * Math.PI * 0.83 + 0.4) * Math.sin(t * 2 * Math.PI * 1.7);
      if (i % 64 === 0) bp.set('bandpass', 500 + 400 * (0.5 + 0.5 * Math.sin(t * 2 * Math.PI * 0.83)), 0.5, sr);
      const p = pink();
      out[i] = (p * 0.7 + bp.run(p) * 1.4) * swell;
    }
    return normalize(seamless(out, sr), 0.8);
  },
  FootstepsPlastic(sr, rng) {
    const len = SampleLengths.FootstepsPlastic + 0.06;
    const n = Math.floor(len * sr);
    const out = new Float32Array(n);
    const steps = [0.0, 0.028, 0.175, 0.2];
    const gains = [1, 0.55, 0.9, 0.5];
    const hp = new Biquad('bandpass', 2600, 1.1, sr);
    const lo = new Biquad('lowpass', 420, 0.8, sr);
    for (let i = 0; i < n; i++) {
      const t = i / sr;
      let s = 0;
      for (let k = 0; k < steps.length; k++) {
        const dt = t - steps[k];
        if (dt < 0 || dt > 0.09) continue;
        const env = Math.exp(-dt / 0.012) * gains[k];
        s += (rng.next() * 2 - 1) * env + Math.sin(2 * Math.PI * 160 * dt) * Math.exp(-dt / 0.03) * gains[k] * 0.6;
      }
      out[i] = hp.run(s) * 1.6 + lo.run(s) * 0.8;
    }
    return normalize(seamless(out, sr, 0.04), 0.9);
  },
  GetUp(sr, rng) {
    const n = Math.floor(SampleLengths.GetUp * sr);
    const out = new Float32Array(n);
    const bp = new Biquad('bandpass', 1800, 0.7, sr);
    let crackle = 0;
    for (let i = 0; i < n; i++) {
      const t = i / sr;
      const env = Math.sin(Math.PI * Math.min(1, t / SampleLengths.GetUp)) ** 0.8;
      if (rng.next() < 0.004) crackle = 0.6 + rng.next() * 0.8;
      crackle *= 0.9985;
      out[i] = bp.run((rng.next() * 2 - 1) * (0.25 + crackle)) * env;
    }
    return normalize(out, 0.85);
  },
  Jump(sr, rng) {
    const n = Math.floor(SampleLengths.Jump * sr);
    const out = new Float32Array(n);
    const bp = new Biquad('bandpass', 600, 1.2, sr);
    for (let i = 0; i < n; i++) {
      const t = i / sr;
      const x = t / SampleLengths.Jump;
      if (i % 32 === 0) bp.set('bandpass', 500 + 1700 * x, 1.2, sr);
      const env = Math.min(1, t / 0.06) * Math.exp(-Math.max(0, t - 0.06) / 0.07);
      out[i] = bp.run(rng.next() * 2 - 1) * env;
    }
    return normalize(out, 0.85);
  },
  JumpLand(sr, rng) {
    const n = Math.floor(SampleLengths.JumpLand * sr);
    const out = new Float32Array(n);
    const lp = new Biquad('lowpass', 900, 0.7, sr);
    let phase = 0;
    for (let i = 0; i < n; i++) {
      const t = i / sr;
      const f = 50 + 45 * Math.exp(-t / 0.03);
      phase += f / sr;
      const body = Math.sin(2 * Math.PI * phase) * Math.exp(-t / 0.06);
      const click = lp.run(rng.next() * 2 - 1) * Math.exp(-t / 0.008);
      out[i] = body + click * 0.5;
    }
    return normalize(out, 0.95);
  },
  Swim(sr, rng) {
    const len = SampleLengths.Swim + 0.08;
    const n = Math.floor(len * sr);
    const out = new Float32Array(n);
    const lp = new Biquad('lowpass', 1400, 0.9, sr);
    const sloshes = [];
    for (let k = 0; k < 6; k++) sloshes.push({ at: rng.next() * len, dur: 0.12 + rng.next() * 0.25, g: 0.5 + rng.next() * 0.5 });
    const drops = [];
    for (let k = 0; k < 14; k++) drops.push({ at: rng.next() * len, f: 500 + rng.next() * 900 });
    for (let i = 0; i < n; i++) {
      const t = i / sr;
      let amp = 0.25;
      for (const s of sloshes) {
        const d = t - s.at;
        if (d > 0 && d < s.dur) amp += s.g * Math.sin((Math.PI * d) / s.dur);
      }
      let s = lp.run(rng.next() * 2 - 1) * amp;
      for (const dr of drops) {
        const d = t - dr.at;
        if (d > 0 && d < 0.04) s += Math.sin(2 * Math.PI * dr.f * (1 + d * 18) * d) * Math.exp(-d / 0.012) * 0.35;
      }
      out[i] = s;
    }
    return normalize(seamless(out, sr), 0.85);
  },
  Explosion(sr, rng) {
    const n = Math.floor(SampleLengths.Explosion * sr);
    const out = new Float32Array(n);
    const lp = new Biquad('lowpass', 2000, 0.7, sr);
    let sub = 0;
    for (let i = 0; i < n; i++) {
      const t = i / sr;
      if (i % 64 === 0) lp.set('lowpass', 180 + 1900 * Math.exp(-t / 0.25), 0.7, sr);
      sub += (38 + 30 * Math.exp(-t / 0.15)) / sr;
      const body = lp.run(rng.next() * 2 - 1) * Math.exp(-t / 0.55);
      const boom = Math.sin(2 * Math.PI * sub) * Math.exp(-t / 0.4) * 0.8;
      const hit = (rng.next() * 2 - 1) * Math.exp(-t / 0.015);
      const density = 0.012 * Math.exp(-t / 0.7);
      const crackle = rng.next() < density ? (rng.next() * 2 - 1) * 1.2 * Math.exp(-t / 1.1) : 0;
      out[i] = body * 1.4 + boom + hit * 0.7 + crackle;
    }
    return normalize(out, 0.95);
  },
  WaterImpact(sr, rng) {
    const n = Math.floor(SampleLengths.WaterImpact * sr);
    const out = new Float32Array(n);
    const hp = new Biquad('highpass', 900, 0.7, sr);
    const lp = new Biquad('lowpass', 700, 0.8, sr);
    const drops = [];
    for (let k = 0; k < 16; k++) drops.push({ at: 0.04 + (rng.next() ** 1.6) * 0.6, f: 600 + rng.next() * 1200, g: 0.25 + rng.next() * 0.4 });
    for (let i = 0; i < n; i++) {
      const t = i / sr;
      const w = rng.next() * 2 - 1;
      let s = hp.run(w) * Math.exp(-t / 0.09) * 1.2 + lp.run(w) * Math.exp(-t / 0.05) * 0.8;
      for (const d of drops) {
        const dt = t - d.at;
        if (dt > 0 && dt < 0.05) s += Math.sin(2 * Math.PI * d.f * (1 + dt * 25) * dt) * Math.exp(-dt / 0.014) * d.g;
      }
      out[i] = s;
    }
    return normalize(out, 0.9);
  },
  Oof(sr, rng) {
    const len = SampleLengths.Oof;
    const src = voiced((t) => 145 - 50 * Math.min(1, t / len), len, sr, rng, 0.05);
    const out = formants(src, sr, [[480, 6, 1], [950, 8, 0.6], [2450, 10, 0.25]]);
    for (let i = 0; i < out.length; i++) {
      const t = i / sr;
      out[i] *= Math.min(1, t / 0.02) * Math.exp(-Math.max(0, t - 0.06) / 0.11);
    }
    return normalize(out, 0.9);
  },
  Ouch(sr, rng) {
    const len = SampleLengths.Ouch;
    const src = voiced((t) => {
      const x = t / len;
      return x < 0.3 ? 250 + 110 * (x / 0.3) : 360 - 140 * ((x - 0.3) / 0.7);
    }, len, sr, rng, 0.07);
    const out = formants(src, sr, [[650, 6, 1], [1080, 8, 0.7], [2650, 10, 0.3], [3500, 12, 0.12]]);
    for (let i = 0; i < out.length; i++) {
      const t = i / sr;
      out[i] *= Math.min(1, t / 0.025) * (t < 0.24 ? 1 : Math.exp(-(t - 0.24) / 0.05));
    }
    return normalize(out, 0.9);
  },
  VolumeSlider(sr, rng) {
    const n = Math.floor(SampleLengths.VolumeSlider * sr);
    const out = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      const t = i / sr;
      const tone = Math.sin(2 * Math.PI * 2150 * t) + 0.45 * Math.sin(2 * Math.PI * 4310 * t + 0.6)
        + 0.25 * Math.sin(2 * Math.PI * 1075 * t + 1.1);
      const click = (rng.next() * 2 - 1) * Math.exp(-t / 0.0015);
      out[i] = tone * Math.exp(-t / 0.028) + click * 0.5;
    }
    return normalize(out, 0.85);
  },
};

/**
 * Builds every source as an AudioBuffer.
 * @param {BaseAudioContext} ctx
 * @returns {Record<string, AudioBuffer>}
 */
export function buildSamples(ctx) {
  const sr = ctx.sampleRate;
  const out = {};
  let seed = 1029;
  for (const [name, gen] of Object.entries(GENERATORS)) {
    const data = gen(sr, new Random(seed++ * 7919));
    const buf = ctx.createBuffer(1, data.length, sr);
    buf.copyToChannel(data, 0);
    out[name] = buf;
  }
  return out;
}
