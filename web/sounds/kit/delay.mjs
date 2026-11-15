// delay.mjs: delay lines and what is built on them: the feedback comb (a duct's ring, a pipe's bore, a tight flutter
// between walls), the Schroeder all-pass (diffusion), and the Karplus-Strong waveguide (a plucked wire, a sprung
// steel strip, a taut cable: a delay loop with a loss filter, tuned by a fractional all-pass).

import { decayFactor } from './env.mjs';

/** A circular delay line with linearly interpolated fractional reads. */
export class DelayLine {
  /** @param {number} capacity samples */
  constructor(capacity) {
    this.buf = new Float64Array(Math.max(4, Math.ceil(capacity) + 4));
    this.at = 0;
  }

  /** Writes one sample. */
  write(x) {
    this.buf[this.at] = x;
    this.at = (this.at + 1) % this.buf.length;
  }

  /** The sample written `delay` samples ago (fractional; >= 1). */
  read(delay) {
    const n = this.buf.length;
    const d = Math.min(Math.max(delay, 1), n - 2);
    const pos = this.at - d;
    const i = Math.floor(pos);
    const frac = pos - i;
    const a = this.buf[((i % n) + n) % n];
    const b = this.buf[(((i + 1) % n) + n) % n];
    return a + (b - a) * frac;
  }
}

/**
 * A feedback comb: y = x + g * lowpass(y delayed). `damp` 0..1 darkens each round trip (a soft wall, a lined duct).
 * The output is `length` long so the ringing is kept.
 * @param {Float32Array} input
 * @param {number} sr
 * @param {{delay: number, feedback: number, damp?: number, length?: number}} spec delay in seconds
 */
export function comb(input, sr, { delay, feedback, damp = 0, length = input.length }) {
  const line = new DelayLine(delay * sr + 2);
  const out = new Float32Array(length);
  let lp = 0;
  const d = delay * sr;
  for (let i = 0; i < length; i++) {
    const x = i < input.length ? input[i] : 0;
    const back = line.read(d);
    lp = (1 - damp) * back + damp * lp;
    const y = x + feedback * lp;
    line.write(y);
    out[i] = y;
  }
  return out;
}

/**
 * A Schroeder all-pass (flat magnitude, smeared phase): diffusion.
 * @param {Float32Array} input
 * @param {number} sr
 * @param {number} delay seconds
 * @param {number} g
 */
export function allpass(input, sr, delay, g) {
  const line = new DelayLine(delay * sr + 2);
  const out = new Float32Array(input.length);
  const d = delay * sr;
  for (let i = 0; i < input.length; i++) {
    const back = line.read(d);
    const v = input[i] + g * back;
    line.write(v);
    out[i] = back - g * v;
  }
  return out;
}

/**
 * Karplus-Strong: a waveguide loop at `freq` Hz excited by `exciter` (or a noise burst), losing 60 dB in `t60`.
 * `brightness` 0..1 sets the loop filter (1: barely filtered, 0: the classic two-point average). `stretch` > 0 adds
 * dispersion (stiff wire: the partials run sharp), which keeps it from ringing like a clean string.
 * @param {number} n samples
 * @param {number} sr
 * @param {{freq: number, t60: number, brightness?: number, stretch?: number, exciter: Float32Array}} spec
 */
export function karplus(n, sr, { freq, t60, brightness = 0.5, stretch = 0, exciter }) {
  const out = new Float32Array(n);
  const s = 0.5 * (1 - brightness);
  // the loop: delay N + the averaging filter's s samples + the all-pass's fraction = sr / freq
  const total = sr / freq;
  const N = Math.max(2, Math.floor(total - s - 0.5));
  const frac = total - s - N;
  const ap = (1 - frac) / (1 + frac);
  const g = decayFactor(t60, sr) ** (total);
  const line = new Float64Array(N + 2);
  let w = 0;
  let prev = 0;
  let apX1 = 0;
  let apY1 = 0;
  let dispX1 = 0;
  let dispY1 = 0;
  const dc = -Math.min(0.9, stretch);
  for (let i = 0; i < n; i++) {
    const back = line[w];
    // loss filter: a one-zero average of the last two outputs of the delay
    const lossed = g * ((1 - s) * back + s * prev);
    prev = back;
    // fractional tuning (first-order all-pass)
    const tuned = ap * lossed + apX1 - ap * apY1;
    apX1 = lossed;
    apY1 = tuned;
    // dispersion (another first-order all-pass: stiffness)
    const disp = stretch > 0 ? dc * tuned + dispX1 - dc * dispY1 : tuned;
    dispX1 = tuned;
    dispY1 = disp;
    const x = i < exciter.length ? exciter[i] : 0;
    const y = x + disp;
    line[w] = y;
    w = (w + 1) % N;
    out[i] = y;
  }
  return out;
}
