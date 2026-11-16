// fft.mjs: an iterative radix-2 FFT, windows, averaged power spectra and frame powers (what the audit and the pictures
// read), and FFT convolution (the convolver of reverb.mjs).

/** @type {Map<number, {cos: Float64Array, sin: Float64Array, rev: Uint32Array}>} */
const TABLES = new Map();

/** The smallest power of two >= n. */
export function nextPow2(n) {
  let p = 1;
  while (p < n) p *= 2;
  return p;
}

function tables(n) {
  let t = TABLES.get(n);
  if (t) return t;
  const cos = new Float64Array(n / 2);
  const sin = new Float64Array(n / 2);
  for (let i = 0; i < n / 2; i++) {
    cos[i] = Math.cos((2 * Math.PI * i) / n);
    sin[i] = Math.sin((2 * Math.PI * i) / n);
  }
  const rev = new Uint32Array(n);
  const bits = Math.round(Math.log2(n));
  for (let i = 0; i < n; i++) {
    let r = 0;
    for (let b = 0; b < bits; b++) r |= ((i >>> b) & 1) << (bits - 1 - b);
    rev[i] = r;
  }
  t = { cos, sin, rev };
  TABLES.set(n, t);
  return t;
}

/**
 * In-place complex FFT (forward: e^-j; inverse: e^+j and divided by n).
 * @param {Float64Array} re
 * @param {Float64Array} im
 * @param {boolean} [inverse]
 */
export function fft(re, im, inverse = false) {
  const n = re.length;
  if (n !== im.length || (n & (n - 1)) !== 0) throw new Error(`fft: length ${n} is not a power of two`);
  const { cos, sin, rev } = tables(n);
  for (let i = 0; i < n; i++) {
    const j = rev[i];
    if (j > i) {
      let t = re[i];
      re[i] = re[j];
      re[j] = t;
      t = im[i];
      im[i] = im[j];
      im[j] = t;
    }
  }
  const sign = inverse ? 1 : -1;
  for (let size = 2; size <= n; size *= 2) {
    const half = size / 2;
    const step = n / size;
    for (let start = 0; start < n; start += size) {
      for (let k = 0; k < half; k++) {
        const wr = cos[k * step];
        const wi = sign * sin[k * step];
        const a = start + k;
        const b = a + half;
        const tr = re[b] * wr - im[b] * wi;
        const ti = re[b] * wi + im[b] * wr;
        re[b] = re[a] - tr;
        im[b] = im[a] - ti;
        re[a] += tr;
        im[a] += ti;
      }
    }
  }
  if (inverse) {
    for (let i = 0; i < n; i++) {
      re[i] /= n;
      im[i] /= n;
    }
  }
}

/** A periodic Hann window of length n. */
export function hann(n) {
  const w = new Float64Array(n);
  for (let i = 0; i < n; i++) w[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / n);
  return w;
}

/**
 * The power spectrum (|X|^2, bins 0..size/2) of one windowed frame starting at `start` (zero-padded past the end).
 * @param {Float32Array} x
 * @param {number} start
 * @param {number} size a power of two
 * @param {Float64Array} window
 * @param {{re: Float64Array, im: Float64Array}} [scratch]
 */
export function framePower(x, start, size, window, scratch) {
  const re = scratch ? scratch.re : new Float64Array(size);
  const im = scratch ? scratch.im : new Float64Array(size);
  for (let i = 0; i < size; i++) {
    const j = start + i;
    re[i] = j >= 0 && j < x.length ? x[j] * window[i] : 0;
    im[i] = 0;
  }
  fft(re, im);
  const out = new Float64Array(size / 2 + 1);
  for (let k = 0; k <= size / 2; k++) out[k] = re[k] * re[k] + im[k] * im[k];
  return out;
}

/**
 * Welch's averaged power spectrum over [from, to) samples (Hann, 50 % overlap), bins 0..size/2.
 * @param {Float32Array} x
 * @param {number} [size]
 * @param {number} [from]
 * @param {number} [to]
 */
export function welch(x, size = 4096, from = 0, to = x.length) {
  const window = hann(size);
  const scratch = { re: new Float64Array(size), im: new Float64Array(size) };
  const sum = new Float64Array(size / 2 + 1);
  const hop = size / 2;
  let frames = 0;
  const last = Math.max(from, to - size);
  for (let s = from; s <= last; s += hop) {
    const p = framePower(x, s, size, window, scratch);
    for (let k = 0; k < sum.length; k++) sum[k] += p[k];
    frames++;
    if (to - from < size) break;
  }
  if (frames === 0) frames = 1;
  for (let k = 0; k < sum.length; k++) sum[k] /= frames;
  return sum;
}

/**
 * Linear convolution of a and b by one FFT (the length is a.length + b.length - 1).
 * @param {Float32Array} a
 * @param {Float32Array} b
 */
export function convolve(a, b) {
  const len = a.length + b.length - 1;
  const n = nextPow2(len);
  const ar = new Float64Array(n);
  const ai = new Float64Array(n);
  const br = new Float64Array(n);
  const bi = new Float64Array(n);
  ar.set(a);
  br.set(b);
  fft(ar, ai);
  fft(br, bi);
  for (let k = 0; k < n; k++) {
    const r = ar[k] * br[k] - ai[k] * bi[k];
    const i = ar[k] * bi[k] + ai[k] * br[k];
    ar[k] = r;
    ai[k] = i;
  }
  fft(ar, ai, true);
  const out = new Float32Array(len);
  for (let i = 0; i < len; i++) out[i] = ar[i];
  return out;
}
