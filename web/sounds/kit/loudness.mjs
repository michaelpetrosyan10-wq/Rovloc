// loudness.mjs: ITU-R BS.1770-4 loudness (K-weighting: a +4 dB shelf above ~1.7 kHz and a high-pass at 38 Hz;
// mean square over 400 ms blocks with 75 % overlap; LUFS = -0.691 + 10 log10 of the channel sum), the momentary
// maximum (how loud a one-shot peaks), the gated integrated loudness (how loud a loop sits), and the true peak
// (4x oversampled, dBTP). Coefficients follow libebur128's derivation, so any sample rate works.

import { upsample } from './shape.mjs';

/**
 * The two K-weighting biquads for a sample rate: [shelf, highpass], each {b: [3], a: [3]}.
 * @param {number} sr
 */
export function kCoefficients(sr) {
  let f0 = 1681.974450955533;
  const G = 3.999843853973347;
  let Q = 0.7071752369554196;
  let K = Math.tan((Math.PI * f0) / sr);
  const Vh = 10 ** (G / 20);
  const Vb = Vh ** 0.4996667741545416;
  let a0 = 1 + K / Q + K * K;
  const shelf = {
    b: [(Vh + (Vb * K) / Q + K * K) / a0, (2 * (K * K - Vh)) / a0, (Vh - (Vb * K) / Q + K * K) / a0],
    a: [1, (2 * (K * K - 1)) / a0, (1 - K / Q + K * K) / a0],
  };
  f0 = 38.13547087602444;
  Q = 0.5003270373238773;
  K = Math.tan((Math.PI * f0) / sr);
  a0 = 1 + K / Q + K * K;
  const hp = { b: [1, -2, 1], a: [1, (2 * (K * K - 1)) / a0, (1 - K / Q + K * K) / a0] };
  return [shelf, hp];
}

/**
 * A K-weighted copy (Float64Array).
 * @param {Float32Array} x
 * @param {number} sr
 */
export function kWeight(x, sr) {
  const out = new Float64Array(x.length);
  const stages = kCoefficients(sr);
  for (let i = 0; i < x.length; i++) out[i] = x[i];
  for (const { b, a } of stages) {
    let x1 = 0;
    let x2 = 0;
    let y1 = 0;
    let y2 = 0;
    for (let i = 0; i < out.length; i++) {
      const v = out[i];
      const y = b[0] * v + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2;
      x2 = x1;
      x1 = v;
      y2 = y1;
      y1 = y;
      out[i] = y;
    }
  }
  return out;
}

/**
 * The mean square (channel sum) of each 400 ms block, hop 100 ms. A sound shorter than a block is one block
 * (zero-padded): a short impact is measured as heard in 400 ms of the ear's integration.
 * @param {Float32Array[]} channels
 * @param {number} sr
 */
export function blockPowers(channels, sr) {
  const weighted = channels.map((c) => kWeight(c, sr));
  const block = Math.round(0.4 * sr);
  const hop = Math.round(0.1 * sr);
  const n = channels[0].length;
  const powers = [];
  for (let start = 0; start === 0 || start + block <= n; start += hop) {
    let p = 0;
    for (const w of weighted) {
      let s = 0;
      const end = Math.min(n, start + block);
      for (let i = start; i < end; i++) s += w[i] * w[i];
      p += s / block;
    }
    powers.push(p);
    if (start + block >= n) break;
  }
  return powers;
}

const lufs = (p) => (p > 0 ? -0.691 + 10 * Math.log10(p) : -Infinity);

/**
 * The loudest 400 ms block (LUFS): a one-shot's loudness.
 * @param {Float32Array[]} channels
 * @param {number} sr
 */
export function momentaryMax(channels, sr) {
  return lufs(Math.max(...blockPowers(channels, sr)));
}

/**
 * Gated integrated loudness (LUFS): absolute gate -70 LUFS, relative gate -10 LU: a loop's or a bed's loudness.
 * @param {Float32Array[]} channels
 * @param {number} sr
 */
export function integrated(channels, sr) {
  const powers = blockPowers(channels, sr);
  const abs = powers.filter((p) => lufs(p) > -70);
  if (!abs.length) return -Infinity;
  const mean = abs.reduce((s, p) => s + p, 0) / abs.length;
  const rel = abs.filter((p) => lufs(p) > lufs(mean) - 10);
  return lufs(rel.reduce((s, p) => s + p, 0) / rel.length);
}

/**
 * The true peak in dBTP (4x oversampled).
 * @param {Float32Array[]} channels
 */
export function truePeak(channels) {
  let m = 0;
  for (const c of channels) {
    const up = upsample(c, 4);
    for (let i = 0; i < up.length; i++) m = Math.max(m, Math.abs(up[i]));
    for (let i = 0; i < c.length; i++) m = Math.max(m, Math.abs(c[i]));
  }
  return m > 0 ? 20 * Math.log10(m) : -Infinity;
}
