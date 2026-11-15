// reverb.mjs: space. Early reflections (a tapped delay: the first bounces off the nearest walls, which tell the ear
// the size and shape of the place) and a feedback delay network for the tail: 8 delay lines mixed through a
// Hadamard matrix, each with a damping filter tuned so the lows die in rt60 and the highs in rt60High, two lines
// slowly modulated so the tail never rings metallic. impulse() renders a space's impulse response (the shared
// convolver's IR); convolveStereo() applies one; place() bakes a dry sound into a space (always-far events).

import { DelayLine } from './delay.mjs';
import { convolve } from './fft.mjs';
import { Biquad } from './filters.mjs';

/** @typedef {{rt60: number, rt60High: number, size: number, predelay: number, early: Array<[number, number, number]>,
 *   lowCut: number, highCut: number}} Space  early taps: [delay s, gain, pan -1..1] */

/** The spaces of the game: what a sound is baked into, and what the shared convolver's IR is rendered from. */
export const SPACES = Object.freeze({
  /** a long school corridor: hard parallel walls (a flutter), lino and plaster */
  corridor: { rt60: 1.7, rt60High: 0.55, size: 1.0, predelay: 0.008, lowCut: 70, highCut: 7000,
    early: [[0.007, 0.55, -0.6], [0.0095, 0.5, 0.6], [0.0142, 0.38, -0.4], [0.019, 0.34, 0.5], [0.0265, 0.28, -0.2], [0.034, 0.24, 0.3], [0.047, 0.2, 0], [0.061, 0.16, -0.5]] },
  /** the basement: concrete, low ceiling, pipes; long and dark */
  basement: { rt60: 2.3, rt60High: 0.6, size: 1.25, predelay: 0.012, lowCut: 45, highCut: 5200,
    early: [[0.011, 0.5, -0.3], [0.016, 0.45, 0.5], [0.023, 0.36, -0.6], [0.031, 0.3, 0.2], [0.044, 0.26, -0.1], [0.058, 0.22, 0.6], [0.079, 0.17, -0.4]] },
  /** the auditorium: big, soft seats, a tall ceiling */
  hall: { rt60: 2.6, rt60High: 1.1, size: 1.6, predelay: 0.022, lowCut: 50, highCut: 8000,
    early: [[0.019, 0.42, -0.5], [0.027, 0.4, 0.5], [0.038, 0.32, -0.2], [0.052, 0.28, 0.3], [0.07, 0.22, 0], [0.093, 0.18, -0.6]] },
  /** a classroom: small, furnished */
  room: { rt60: 0.6, rt60High: 0.3, size: 0.55, predelay: 0.003, lowCut: 90, highCut: 9000,
    early: [[0.004, 0.5, -0.5], [0.006, 0.45, 0.5], [0.009, 0.35, 0.1], [0.013, 0.28, -0.3], [0.018, 0.2, 0.4]] },
  /** a concrete stairwell: tall, hard, bright */
  stairwell: { rt60: 2.4, rt60High: 1.3, size: 0.9, predelay: 0.006, lowCut: 80, highCut: 9500,
    early: [[0.006, 0.55, -0.4], [0.012, 0.5, 0.4], [0.018, 0.45, -0.1], [0.024, 0.4, 0.2], [0.03, 0.36, -0.3], [0.036, 0.32, 0.3], [0.042, 0.28, 0]] },
  /** a roof at night: no tail of its own, slaps off the buildings around */
  outdoor: { rt60: 0.9, rt60High: 0.35, size: 1.8, predelay: 0.03, lowCut: 60, highCut: 6000,
    early: [[0.045, 0.32, -0.6], [0.083, 0.26, 0.7], [0.131, 0.2, -0.2], [0.19, 0.14, 0.4]] },
});

const HADAMARD_8 = (() => {
  const h = [[1]];
  let m = h;
  while (m.length < 8) {
    const n = m.length;
    const next = [];
    for (let i = 0; i < 2 * n; i++) {
      next.push([]);
      for (let j = 0; j < 2 * n; j++) next[i].push(m[i % n][j % n] * (i >= n && j >= n ? -1 : 1));
    }
    m = next;
  }
  return m.map((row) => row.map((v) => v / Math.sqrt(8)));
})();

const BASE_DELAYS = [0.0297, 0.0371, 0.0411, 0.0437, 0.0533, 0.0593, 0.0671, 0.0739];

/**
 * The FDN tail of `input`: [left, right], `length` samples (wet only).
 * @param {Float32Array} input
 * @param {number} sr
 * @param {{rt60: number, rt60High: number, size?: number, predelay?: number, length: number,
 *   rng: import('./rng.mjs').Rng}} spec
 * @returns {[Float32Array, Float32Array]}
 */
export function fdn(input, sr, { rt60, rt60High, size = 1, predelay = 0, length, rng }) {
  const lines = BASE_DELAYS.map((d) => d * size * sr * (1 + rng.range(-0.04, 0.04)));
  const del = lines.map((d) => new DelayLine(d + 64));
  // per line: a one-pole low-pass whose DC gain gives rt60 and Nyquist gain rt60High
  const filt = lines.map((d) => {
    const g0 = 10 ** ((-3 * d) / (sr * rt60));
    const gpi = 10 ** ((-3 * d) / (sr * rt60High));
    const ratio = g0 / gpi;
    const a = (ratio - 1) / (ratio + 1);
    return { b: g0 * (1 - a), a, y: 0 };
  });
  const modRate = [0.31, 0.47].map((r) => r * rng.range(0.8, 1.2));
  const pre = Math.round(predelay * sr);
  const left = new Float32Array(length);
  const right = new Float32Array(length);
  const outs = new Float64Array(8);
  const signsL = [1, -1, 1, -1, 1, -1, 1, -1];
  const signsR = [1, 1, -1, -1, 1, 1, -1, -1];
  for (let i = 0; i < length; i++) {
    const xi = i - pre;
    const x = xi >= 0 && xi < input.length ? input[xi] : 0;
    for (let k = 0; k < 8; k++) {
      let d = lines[k];
      if (k < 2) d += 0.0004 * sr * Math.sin((2 * Math.PI * modRate[k] * i) / sr);
      const raw = del[k].read(d);
      const f = filt[k];
      f.y = f.b * raw + f.a * f.y;
      outs[k] = f.y;
    }
    let l = 0;
    let r = 0;
    for (let k = 0; k < 8; k++) {
      l += outs[k] * signsL[k];
      r += outs[k] * signsR[k];
    }
    left[i] = l * 0.35;
    right[i] = r * 0.35;
    for (let k = 0; k < 8; k++) {
      const row = HADAMARD_8[k];
      let v = 0;
      for (let j = 0; j < 8; j++) v += row[j] * outs[j];
      del[k].write(v + x * 0.5);
    }
  }
  return [left, right];
}

/**
 * Early reflections of `input`: [left, right] (wet only), `length` samples.
 * @param {Float32Array} input
 * @param {number} sr
 * @param {Array<[number, number, number]>} taps [delay s, gain, pan]
 * @param {number} length
 * @returns {[Float32Array, Float32Array]}
 */
export function early(input, sr, taps, length) {
  const left = new Float32Array(length);
  const right = new Float32Array(length);
  for (const [delay, g, p] of taps) {
    const off = Math.round(delay * sr);
    const a = ((p + 1) * Math.PI) / 4;
    const gl = g * Math.cos(a) * Math.SQRT2;
    const gr = g * Math.sin(a) * Math.SQRT2;
    for (let i = 0; i < input.length && i + off < length; i++) {
      left[i + off] += input[i] * gl;
      right[i + off] += input[i] * gr;
    }
  }
  return [left, right];
}

/**
 * A space's stereo impulse response, `seconds` long, normalized to unit energy per channel pair (a convolver with it
 * keeps a sound's loudness), band-limited by the space's lowCut / highCut.
 * @param {number} sr
 * @param {Space} space
 * @param {import('./rng.mjs').Rng} rng
 * @param {number} [seconds]
 * @returns {[Float32Array, Float32Array]}
 */
export function impulse(sr, space, rng, seconds = Math.min(4, space.rt60 * 1.15 + 0.1)) {
  const length = Math.round(seconds * sr);
  const click = new Float32Array(1);
  click[0] = 1;
  const [el, er] = early(click, sr, space.early, length);
  const [tl, tr] = fdn(click, sr, { rt60: space.rt60, rt60High: space.rt60High, size: space.size, predelay: space.predelay, length, rng });
  const ir = [new Float32Array(length), new Float32Array(length)];
  for (let i = 0; i < length; i++) {
    ir[0][i] = el[i] + tl[i];
    ir[1][i] = er[i] + tr[i];
  }
  let energy = 0;
  for (const ch of ir) {
    new Biquad('highpass', sr, space.lowCut, 0.7).process(ch);
    new Biquad('lowpass', sr, space.highCut, 0.7).process(ch);
    // the end fades out over its last 20 % (the tail is under -50 dB there already)
    const f = Math.round(length * 0.2);
    for (let i = 0; i < f; i++) ch[length - 1 - i] *= i / f;
    for (let i = 0; i < length; i++) energy += ch[i] * ch[i];
  }
  const norm = 1 / Math.sqrt(energy / 2);
  for (const ch of ir) for (let i = 0; i < length; i++) ch[i] *= norm;
  return /** @type {[Float32Array, Float32Array]} */ (ir);
}

/**
 * A mono sound through a stereo IR: [left, right], the input's length plus the IR's.
 * @param {Float32Array} input
 * @param {[Float32Array, Float32Array]} ir
 * @returns {[Float32Array, Float32Array]}
 */
export function convolveStereo(input, ir) {
  return [convolve(input, ir[0]), convolve(input, ir[1])];
}

/**
 * Bakes a dry mono sound into a space as heard from far off: `wet` of its energy reverberant, the direct part
 * low-passed at `darken` Hz. Returns [left, right] including the tail.
 * @param {Float32Array} input
 * @param {number} sr
 * @param {Space} space
 * @param {{wet: number, darken?: number, rng: import('./rng.mjs').Rng}} spec
 * @returns {[Float32Array, Float32Array]}
 */
export function place(input, sr, space, { wet, darken = 20000, rng }) {
  const ir = impulse(sr, space, rng);
  const direct = darken < 20000 ? new Biquad('lowpass', sr, darken, 0.7).process(Float32Array.from(input)) : input;
  const [l, r] = convolveStereo(direct, ir);
  const dry = Math.sqrt(1 - wet);
  const w = Math.sqrt(wet);
  for (let i = 0; i < l.length; i++) {
    const d = i < direct.length ? direct[i] * dry : 0;
    l[i] = d + l[i] * w;
    r[i] = d + r[i] * w;
  }
  return [l, r];
}
