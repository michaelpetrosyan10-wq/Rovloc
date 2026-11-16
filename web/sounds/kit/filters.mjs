// filters.mjs: RBJ cookbook biquads, Simper's state-variable filter (stable under per-sample sweeps), the DC blocker,
// Butterworth cascades, and the "laptop" filter (a 12 dB/octave high-pass at 220 Hz: what a Chromebook
// speaker leaves of a sound; docs/SOUND.md 2).

/** @typedef {'lowpass'|'highpass'|'bandpass'|'notch'|'peak'|'lowshelf'|'highshelf'|'allpass'} BiquadType */

export class Biquad {
  /**
   * @param {BiquadType} type
   * @param {number} sr sample rate
   * @param {number} freq Hz
   * @param {number} [q]
   * @param {number} [gainDb] peak and shelf gain
   */
  constructor(type, sr, freq, q = Math.SQRT1_2, gainDb = 0) {
    this.sr = sr;
    this.x1 = 0;
    this.x2 = 0;
    this.y1 = 0;
    this.y2 = 0;
    this.set(type, freq, q, gainDb);
  }

  /** Recomputes the coefficients (the state is kept, so a slow sweep stays smooth). */
  set(type, freq, q = Math.SQRT1_2, gainDb = 0) {
    this.type = type;
    const f = Math.min(Math.max(freq, 1), this.sr * 0.4999);
    const w = (2 * Math.PI * f) / this.sr;
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
    switch (type) {
      case 'lowpass':
        b0 = (1 - cs) / 2; b1 = 1 - cs; b2 = (1 - cs) / 2; a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha;
        break;
      case 'highpass':
        b0 = (1 + cs) / 2; b1 = -(1 + cs); b2 = (1 + cs) / 2; a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha;
        break;
      case 'bandpass':
        b0 = alpha; b1 = 0; b2 = -alpha; a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha;
        break;
      case 'notch':
        b0 = 1; b1 = -2 * cs; b2 = 1; a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha;
        break;
      case 'peak':
        b0 = 1 + alpha * A; b1 = -2 * cs; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cs; a2 = 1 - alpha / A;
        break;
      case 'lowshelf': {
        const s = 2 * Math.sqrt(A) * alpha;
        b0 = A * (A + 1 - (A - 1) * cs + s); b1 = 2 * A * (A - 1 - (A + 1) * cs); b2 = A * (A + 1 - (A - 1) * cs - s);
        a0 = A + 1 + (A - 1) * cs + s; a1 = -2 * (A - 1 + (A + 1) * cs); a2 = A + 1 + (A - 1) * cs - s;
        break;
      }
      case 'highshelf': {
        const s = 2 * Math.sqrt(A) * alpha;
        b0 = A * (A + 1 + (A - 1) * cs + s); b1 = -2 * A * (A - 1 + (A + 1) * cs); b2 = A * (A + 1 + (A - 1) * cs - s);
        a0 = A + 1 - (A - 1) * cs + s; a1 = 2 * (A - 1 - (A + 1) * cs); a2 = A + 1 - (A - 1) * cs - s;
        break;
      }
      case 'allpass':
        b0 = 1 - alpha; b1 = -2 * cs; b2 = 1 + alpha; a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha;
        break;
      default:
        throw new Error(`Biquad: unknown type ${type}`);
    }
    this.b0 = b0 / a0;
    this.b1 = b1 / a0;
    this.b2 = b2 / a0;
    this.a1 = a1 / a0;
    this.a2 = a2 / a0;
  }

  /** One sample. */
  tick(x) {
    const y = this.b0 * x + this.b1 * this.x1 + this.b2 * this.x2 - this.a1 * this.y1 - this.a2 * this.y2;
    this.x2 = this.x1;
    this.x1 = x;
    this.y2 = this.y1;
    this.y1 = y;
    return y;
  }

  /**
   * Filters `input` into `output` (in place when they are the same array).
   * @param {Float32Array} input
   * @param {Float32Array} [output]
   */
  process(input, output = input) {
    for (let i = 0; i < input.length; i++) output[i] = this.tick(input[i]);
    return output;
  }

  /** The magnitude response at `freq` Hz. */
  response(freq) {
    const w = (2 * Math.PI * freq) / this.sr;
    const c1 = Math.cos(w);
    const s1 = Math.sin(w);
    const c2 = Math.cos(2 * w);
    const s2 = Math.sin(2 * w);
    const nr = this.b0 + this.b1 * c1 + this.b2 * c2;
    const ni = -(this.b1 * s1 + this.b2 * s2);
    const dr = 1 + this.a1 * c1 + this.a2 * c2;
    const di = -(this.a1 * s1 + this.a2 * s2);
    return Math.sqrt((nr * nr + ni * ni) / (dr * dr + di * di));
  }
}

/**
 * A copy of `input` through one biquad.
 * @param {Float32Array} input
 * @param {number} sr
 * @param {BiquadType} type
 * @param {number} freq
 * @param {number} [q]
 * @param {number} [gainDb]
 */
export function biquad(input, sr, type, freq, q = Math.SQRT1_2, gainDb = 0) {
  return new Biquad(type, sr, freq, q, gainDb).process(input, new Float32Array(input.length));
}

/** The Q of each second-order section of an order-`order` Butterworth filter (order even). */
export function butterworthQs(order) {
  const qs = [];
  for (let k = 0; k < order / 2; k++) qs.push(1 / (2 * Math.cos((Math.PI * (2 * k + 1)) / (2 * order))));
  return qs;
}

/**
 * A copy of `input` through an even-order Butterworth low- or high-pass (order 2 = 12 dB/octave).
 * @param {Float32Array} input
 * @param {number} sr
 * @param {'lowpass'|'highpass'} type
 * @param {number} freq
 * @param {number} [order]
 */
export function butter(input, sr, type, freq, order = 2) {
  const out = Float32Array.from(input);
  for (const q of butterworthQs(order)) new Biquad(type, sr, freq, q).process(out);
  return out;
}

/** The laptop speaker: a 12 dB/octave Butterworth high-pass at 220 Hz (a copy). */
export function laptop(input, sr) {
  return butter(input, sr, 'highpass', 220, 2);
}

/**
 * Simper's trapezoidal state-variable filter: low, band and high outputs from one state, stable when the cutoff or the
 * Q moves every sample (sweeps, formant glides, wah).
 */
export class Svf {
  /** @param {number} sr */
  constructor(sr) {
    this.sr = sr;
    this.ic1 = 0;
    this.ic2 = 0;
    this.lp = 0;
    this.bp = 0;
    this.hp = 0;
    this.setup(1000, Math.SQRT1_2);
  }

  /** @param {number} freq Hz @param {number} q */
  setup(freq, q) {
    const g = Math.tan((Math.PI * Math.min(Math.max(freq, 1), this.sr * 0.49)) / this.sr);
    this.k = 1 / q;
    this.a1 = 1 / (1 + g * (g + this.k));
    this.a2 = g * this.a1;
    this.a3 = g * this.a2;
  }

  /** One sample; the outputs land in this.lp, this.bp (unity peak at the cutoff when multiplied by k) and this.hp. */
  tick(x) {
    const v3 = x - this.ic2;
    const v1 = this.a1 * this.ic1 + this.a2 * v3;
    const v2 = this.ic2 + this.a2 * this.ic1 + this.a3 * v3;
    this.ic1 = 2 * v1 - this.ic1;
    this.ic2 = 2 * v2 - this.ic2;
    this.lp = v2;
    this.bp = v1;
    this.hp = x - this.k * v1 - v2;
    return v2;
  }
}

/**
 * A swept SVF over a whole buffer: `freq` and `q` are numbers, arrays (one per sample) or functions of the sample index.
 * The band output is scaled by 1/Q so its peak gain is 1.
 * @param {Float32Array} input
 * @param {number} sr
 * @param {'lowpass'|'bandpass'|'highpass'|'notch'} mode
 * @param {number|Float32Array|((i: number) => number)} freq
 * @param {number|Float32Array|((i: number) => number)} [q]
 */
export function svf(input, sr, mode, freq, q = Math.SQRT1_2) {
  const f = new Svf(sr);
  const out = new Float32Array(input.length);
  const at = (v, i) => (typeof v === 'number' ? v : typeof v === 'function' ? v(i) : v[i]);
  const constant = typeof freq === 'number' && typeof q === 'number';
  if (constant) f.setup(freq, q);
  for (let i = 0; i < input.length; i++) {
    if (!constant && (i & 7) === 0) f.setup(at(freq, i), at(q, i));
    f.tick(input[i]);
    switch (mode) {
      case 'lowpass': out[i] = f.lp; break;
      case 'highpass': out[i] = f.hp; break;
      case 'bandpass': out[i] = f.bp * f.k; break;
      default: out[i] = input[i] - f.k * f.bp; break;
    }
  }
  return out;
}

/**
 * Removes DC in place: a first-order high-pass at `freq` Hz (y = x - x1 + R y1).
 * @param {Float32Array} buf
 * @param {number} sr
 * @param {number} [freq]
 */
export function dcBlock(buf, sr, freq = 8) {
  const R = Math.exp((-2 * Math.PI * freq) / sr);
  let x1 = 0;
  let y1 = 0;
  for (let i = 0; i < buf.length; i++) {
    const x = buf[i];
    const y = x - x1 + R * y1;
    x1 = x;
    y1 = y;
    buf[i] = y;
  }
  return buf;
}
