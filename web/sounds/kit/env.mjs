// env.mjs: envelopes and slow modulators. Every attack is a raised cosine of at least 0.5 ms (no clicks); decays are
// exponential, specified by T60 (the time to fall 60 dB), so a body's ringing reads in seconds of physics.

/** The per-sample factor that falls 60 dB in `t60` seconds. */
export function decayFactor(t60, sr) {
  return Math.exp(Math.log(0.001) / Math.max(1e-4, t60 * sr));
}

/**
 * An exponential decay from 1, falling 60 dB in `t60`, after a raised-cosine attack of `attack` seconds and a hold.
 * @param {number} n samples
 * @param {number} sr
 * @param {{attack?: number, hold?: number, t60: number}} spec
 */
export function decayEnv(n, sr, { attack = 0.001, hold = 0, t60 }) {
  const out = new Float32Array(n);
  const a = Math.max(1, Math.round(Math.max(attack, 0.0005) * sr));
  const h = Math.round(hold * sr);
  const k = decayFactor(t60, sr);
  let v = 1;
  for (let i = 0; i < n; i++) {
    if (i < a) out[i] = 0.5 - 0.5 * Math.cos((Math.PI * i) / a);
    else if (i < a + h) out[i] = 1;
    else {
      v *= k;
      out[i] = v;
    }
  }
  return out;
}

/**
 * A breakpoint envelope: points [time s, value, curve?]; a segment's curve 0 is linear, > 0 bends it toward an
 * exponential (fast start, slow end; e.g. 4), < 0 the other way. Before the first point and after the last the
 * envelope holds the nearest value.
 * @param {number} n samples
 * @param {number} sr
 * @param {Array<[number, number, number?]>} points
 */
export function segments(n, sr, points) {
  const out = new Float32Array(n);
  let p = 0;
  for (let i = 0; i < n; i++) {
    const t = i / sr;
    while (p < points.length - 1 && t >= points[p + 1][0]) p++;
    const [t0, v0] = points[p];
    if (p >= points.length - 1 || t < t0) {
      out[i] = t < points[0][0] ? points[0][1] : points[points.length - 1][1];
      continue;
    }
    const [t1, v1, curve = 0] = points[p + 1];
    let u = (t - t0) / Math.max(1e-9, t1 - t0);
    if (curve !== 0) u = (1 - Math.exp(-curve * u)) / (1 - Math.exp(-curve));
    out[i] = v0 + (v1 - v0) * u;
  }
  return out;
}

/**
 * A smooth random modulator: cubic (Catmull-Rom) interpolation between random points `rate` times a second,
 * values in [lo, hi]. Used for drift, tremble, slow beating and wandering formants.
 * @param {number} n samples
 * @param {number} sr
 * @param {number} rate points per second
 * @param {import('./rng.mjs').Rng} rng
 * @param {number} [lo]
 * @param {number} [hi]
 */
export function smoothRandom(n, sr, rate, rng, lo = -1, hi = 1) {
  const count = Math.ceil((n / sr) * rate) + 4;
  const pts = new Float64Array(count);
  for (let i = 0; i < count; i++) pts[i] = rng.range(lo, hi);
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const x = (i / sr) * rate + 1;
    const k = Math.floor(x);
    const u = x - k;
    const p0 = pts[k - 1];
    const p1 = pts[k];
    const p2 = pts[k + 1];
    const p3 = pts[k + 2];
    const v = 0.5 * (2 * p1 + (-p0 + p2) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u * u + (-p0 + 3 * p1 - 3 * p2 + p3) * u * u * u);
    out[i] = Math.min(hi, Math.max(lo, v));
  }
  return out;
}

/**
 * The same modulator made periodic over n samples (its end runs into its start): for loops.
 * @param {number} n
 * @param {number} sr
 * @param {number} rate
 * @param {import('./rng.mjs').Rng} rng
 * @param {number} [lo]
 * @param {number} [hi]
 */
export function smoothRandomLoop(n, sr, rate, rng, lo = -1, hi = 1) {
  const count = Math.max(2, Math.round((n / sr) * rate));
  const pts = new Float64Array(count);
  for (let i = 0; i < count; i++) pts[i] = rng.range(lo, hi);
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const x = (i / n) * count;
    const k = Math.floor(x);
    const u = x - k;
    const at = (j) => pts[((j % count) + count) % count];
    const p0 = at(k - 1);
    const p1 = at(k);
    const p2 = at(k + 1);
    const p3 = at(k + 2);
    const v = 0.5 * (2 * p1 + (-p0 + p2) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u * u + (-p0 + 3 * p1 - 3 * p2 + p3) * u * u * u);
    out[i] = Math.min(hi, Math.max(lo, v));
  }
  return out;
}
