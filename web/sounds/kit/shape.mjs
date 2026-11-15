// shape.mjs: oversampled saturation. A curve bends the waveform and adds harmonics; done at the base rate the
// harmonics above Nyquist fold back as inharmonic aliases. Here the signal is raised to `factor` x the rate through a
// Kaiser-windowed sinc (about 85 dB of stopband), bent, and brought back down through the same filter, so the alias
// products stay under the floor (test.mjs measures it). Saturating a sub thump is how a heavy sound keeps its weight
// on a laptop speaker: the harmonics of 45 Hz at 135, 225, 315 Hz carry the missing fundamental.

/** @typedef {'tanh'|'soft'|'asym'|'fold'|'hard'} Curve */

function bessel0(x) {
  let sum = 1;
  let term = 1;
  for (let k = 1; k < 40; k++) {
    term *= (x / (2 * k)) ** 2;
    sum += term;
    if (term < 1e-12 * sum) break;
  }
  return sum;
}

/** @type {Map<number, Float64Array>} */
const FILTERS = new Map();

/**
 * The interpolation / decimation filter for a factor: a linear-phase Kaiser sinc of 48 * factor + 1 taps, cut at
 * 0.46 of the base rate's Nyquist band, DC gain 1. The tap count makes its delay a whole number of base samples.
 * @param {number} factor
 */
export function halfbandFor(factor) {
  let h = FILTERS.get(factor);
  if (h) return h;
  const taps = 48 * factor + 1;
  const mid = (taps - 1) / 2;
  const cutoff = 0.46 / factor;
  const beta = 8.6;
  h = new Float64Array(taps);
  let sum = 0;
  for (let i = 0; i < taps; i++) {
    const x = i - mid;
    const sinc = x === 0 ? 2 * cutoff : Math.sin(2 * Math.PI * cutoff * x) / (Math.PI * x);
    const r = (2 * i) / (taps - 1) - 1;
    h[i] = sinc * (bessel0(beta * Math.sqrt(Math.max(0, 1 - r * r))) / bessel0(beta));
    sum += h[i];
  }
  for (let i = 0; i < taps; i++) h[i] /= sum;
  FILTERS.set(factor, h);
  return h;
}

/**
 * `input` raised to `factor` x the rate (zero-stuffed and filtered, gain restored). The output is delayed by the
 * filter's half length.
 * @param {Float32Array} input
 * @param {number} factor
 */
export function upsample(input, factor) {
  const h = halfbandFor(factor);
  const n = input.length * factor;
  const out = new Float64Array(n + h.length);
  for (let i = 0; i < input.length; i++) {
    const x = input[i] * factor;
    if (x === 0) continue;
    const base = i * factor;
    for (let k = 0; k < h.length; k++) out[base + k] += x * h[k];
  }
  return out;
}

/**
 * A high-rate signal brought back down by `factor` (filtered, every factor-th sample), `length` base samples,
 * compensating both filters' delay so the result lines up with the original input.
 * @param {Float64Array} input
 * @param {number} factor
 * @param {number} length
 */
export function downsample(input, factor, length) {
  const h = halfbandFor(factor);
  const delay = h.length - 1; // the up filter's half plus the down filter's half, in high-rate samples
  const out = new Float32Array(length);
  for (let i = 0; i < length; i++) {
    const centre = i * factor + delay;
    let acc = 0;
    for (let k = 0; k < h.length; k++) {
      const j = centre - k;
      if (j >= 0 && j < input.length) acc += input[j] * h[k];
    }
    out[i] = acc;
  }
  return out;
}

/**
 * The curve itself, on one sample (already driven).
 * @param {Curve} curve
 * @param {number} x
 * @param {number} bias asymmetry for 'asym'
 */
export function curveAt(curve, x, bias) {
  switch (curve) {
    case 'soft': return x / (1 + Math.abs(x));
    case 'asym': return Math.tanh(x + bias) - Math.tanh(bias);
    case 'fold': return Math.sin(Math.PI * 0.5 * Math.max(-8, Math.min(8, x)));
    case 'hard': return Math.max(-1, Math.min(1, x));
    default: return Math.tanh(x);
  }
}

/**
 * Oversampled saturation: drive -> curve -> back to the input's level (the drive's gain is divided out so `mix`
 * blends like for like).
 * @param {Float32Array} input
 * @param {{drive?: number, curve?: Curve, bias?: number, mix?: number, factor?: number}} [spec]
 */
export function saturate(input, { drive = 2, curve = 'tanh', bias = 0.2, mix = 1, factor = 4 } = {}) {
  const up = upsample(input, factor);
  const norm = 1 / Math.max(1e-6, Math.abs(curveAt(curve, drive, bias)) || 1);
  for (let i = 0; i < up.length; i++) up[i] = curveAt(curve, up[i] * drive, bias) * norm;
  const wet = downsample(up, factor, input.length);
  if (mix >= 1) return wet;
  const out = new Float32Array(input.length);
  for (let i = 0; i < input.length; i++) out[i] = input[i] * (1 - mix) + wet[i] * mix;
  return out;
}
