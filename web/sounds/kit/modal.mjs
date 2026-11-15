// modal.mjs: resonant bodies as banks of decaying modes. Each mode is a two-pole resonator tuned to f with a T60;
// struck by an exciter (an impulse, a noise burst, a friction pulse train), the bank rings the way the object does:
// a slab's dull low modes, a plate's dense inharmonic shimmer, a glass's few high partials. Where a body is struck
// (strikeGains) and how its modes are detuned are what make variants differ in their physics.

import { decayFactor } from './env.mjs';

/** @typedef {{f: number, t60: number, gain?: number}} Mode */

/**
 * The bank's response to `exciter`: the sum of every mode (amplitude ~gain for a unit impulse).
 * @param {Float32Array} exciter
 * @param {number} sr
 * @param {Mode[]} modes
 * @param {number} [length] output samples (default: the exciter's length)
 * @param {Float32Array} [glide] an optional per-sample frequency multiplier (a sagging or rising body)
 */
export function modal(exciter, sr, modes, length = exciter.length, glide) {
  const out = new Float32Array(length);
  for (const m of modes) {
    if (!(m.f > 0) || m.f >= sr * 0.47) continue;
    const r = decayFactor(m.t60, sr);
    const g = m.gain ?? 1;
    let w = (2 * Math.PI * m.f) / sr;
    let c = 2 * r * Math.cos(w);
    let s = g * Math.sin(w);
    const d = r * r;
    let y1 = 0;
    let y2 = 0;
    const last = exciter.length;
    for (let i = 0; i < length; i++) {
      if (glide && (i & 15) === 0) {
        w = (2 * Math.PI * Math.min(m.f * glide[Math.min(i, glide.length - 1)], sr * 0.47)) / sr;
        c = 2 * r * Math.cos(w);
        s = g * Math.sin(w);
      }
      const x = i < last ? exciter[i] : 0;
      const y = c * y1 - d * y2 + s * x;
      out[i] += y;
      y2 = y1;
      y1 = y;
      if (i > last && (i & 255) === 0 && Math.abs(y1) + Math.abs(y2) < 1e-10) break;
    }
  }
  return out;
}

/** A free-free bar's partial ratios (a beam, a pipe struck across, a bolt). */
export const BAR = Object.freeze([1, 2.756, 5.404, 8.933, 13.344, 18.638]);

/** A circular membrane's partial ratios (Bessel zeros: a drum skin, a stretched hide). */
export const MEMBRANE = Object.freeze([1, 1.594, 2.136, 2.296, 2.653, 2.918, 3.156, 3.501, 3.6, 3.652, 4.06, 4.154]);

/** A thin glass shell's partial ratios (a flask, a tube, a pane's corner). */
export const GLASS = Object.freeze([1, 2.32, 4.25, 6.63, 9.38]);

/**
 * A simply supported rectangular plate's modes up to `count`: f_mn ~ m^2 + (n * aspect)^2, sorted, scaled so the
 * first is 1. An aspect off 1 (1.37, 1.618) keeps the spectrum dense and inharmonic: sheet steel, a locker, a grate.
 * @param {number} count
 * @param {number} [aspect]
 */
export function plateRatios(count, aspect = 1.37) {
  const list = [];
  for (let m = 1; m <= 12; m++) for (let n = 1; n <= 12; n++) list.push(m * m + (n * aspect) * (n * aspect));
  list.sort((a, b) => a - b);
  const base = list[0];
  return list.slice(0, count).map((v) => v / base);
}

/**
 * How strongly a bar or plate is excited in each mode when struck at `x` (0..1 along it; `y` across a plate):
 * |sin(pi k x)| per mode. A strike near the middle mutes the even modes; near an edge, the high ones ring.
 * @param {number} count
 * @param {number} x
 * @param {number} [y]
 */
export function strikeGains(count, x, y) {
  const out = [];
  for (let k = 1; k <= count; k++) {
    const a = Math.abs(Math.sin(Math.PI * k * x));
    const b = y === undefined ? 1 : Math.abs(Math.sin(Math.PI * (((k * 7) % 5) + 1) * y));
    out.push(0.15 + 0.85 * a * b);
  }
  return out;
}

/**
 * Modes from ratios: f = base * ratio * (1 + detune), T60 scaled per mode (higher modes die faster: t60 / ratio^damp),
 * gains rolled off by `tilt` dB per octave above the first.
 * @param {number} base Hz
 * @param {readonly number[]} ratios
 * @param {{t60: number, damp?: number, tilt?: number, gains?: number[], detune?: number,
 *   rng?: import('./rng.mjs').Rng}} spec
 * @returns {Mode[]}
 */
export function modesFrom(base, ratios, { t60, damp = 0.5, tilt = -3, gains, detune = 0, rng }) {
  return ratios.map((ratio, k) => {
    const jitter = rng && detune ? 1 + rng.range(-detune, detune) : 1;
    const f = base * ratio * jitter;
    return {
      f,
      t60: t60 / ratio ** damp,
      gain: (gains ? gains[k] ?? 1 : 1) * 10 ** ((tilt * Math.log2(ratio)) / 20),
    };
  });
}

/**
 * `count` modes scattered between lo and hi Hz (log-uniform), each T60 in [t60lo, t60hi]: a slab, a deck, a crate:
 * a body with no simple ratio series.
 * @param {import('./rng.mjs').Rng} rng
 * @param {number} count
 * @param {number} lo
 * @param {number} hi
 * @param {number} t60lo
 * @param {number} t60hi
 * @param {number} [tilt] dB per octave above lo
 * @returns {Mode[]}
 */
export function scatterModes(rng, count, lo, hi, t60lo, t60hi, tilt = -3) {
  const out = [];
  for (let k = 0; k < count; k++) {
    const f = lo * (hi / lo) ** ((k + rng.range(0.1, 0.9)) / count);
    out.push({ f, t60: rng.range(t60lo, t60hi), gain: rng.range(0.6, 1) * 10 ** ((tilt * Math.log2(f / lo)) / 20) });
  }
  return out;
}
