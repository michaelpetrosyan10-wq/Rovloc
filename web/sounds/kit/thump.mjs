// thump.mjs: the pitch-dropping sub burst under every heavy impact. A sine (allowed: it stays under 110 Hz) whose
// pitch falls exponentially from f0 to f1 as the struck mass settles, a raised-cosine attack under 3 ms, an
// exponential decay, then oversampled saturation: the harmonics it adds (2f, 3f, 4f... at 100-400 Hz) are what a
// laptop speaker plays of it, and the ear rebuilds the missing fundamental from them.

import { saturate } from './shape.mjs';
import { decayFactor } from './env.mjs';

/**
 * @param {number} sr
 * @param {{f0?: number, f1?: number, drop?: number, t60?: number, attack?: number, length?: number, drive?: number,
 *   bias?: number, phase?: number}} [spec] drop: the pitch fall's time constant (s); t60: the amplitude's 60 dB decay;
 *   drive: saturation (0 = a clean sine); bias: asymmetry (even harmonics)
 */
export function thump(sr, { f0 = 60, f1 = 42, drop = 0.07, t60 = 0.4, attack = 0.0015, length, drive = 2.5, bias = 0.25, phase = 0 } = {}) {
  const n = Math.round((length ?? Math.min(2.5, t60 * 1.1 + attack)) * sr);
  const out = new Float32Array(n);
  const a = Math.max(1, Math.round(attack * sr));
  const k = decayFactor(t60, sr);
  let ph = phase;
  let env = 1;
  for (let i = 0; i < n; i++) {
    const t = i / sr;
    const f = f1 + (f0 - f1) * Math.exp(-t / drop);
    ph += (2 * Math.PI * f) / sr;
    let amp;
    if (i < a) amp = 0.5 - 0.5 * Math.cos((Math.PI * i) / a);
    else {
      env *= k;
      amp = env;
    }
    out[i] = Math.sin(ph) * amp;
  }
  if (drive <= 0) return out;
  return saturate(out, { drive, curve: 'asym', bias, factor: 4 });
}
