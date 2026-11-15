// mix.mjs: buffers and the small operations every voice is made of: allocate, add at an offset, multiply by an
// envelope, gain, level, raised-cosine fades, panning, a seamless loop by crossfade, reversal, trimming dead tails.

/** dB to a gain factor. */
export function db(decibels) {
  return 10 ** (decibels / 20);
}

/** A gain factor to dB (-Infinity for 0). */
export function toDb(gain) {
  return gain > 0 ? 20 * Math.log10(gain) : -Infinity;
}

/**
 * A silent buffer of `seconds`.
 * @param {number} seconds
 * @param {number} sr
 */
export function alloc(seconds, sr) {
  return new Float32Array(Math.max(1, Math.round(seconds * sr)));
}

/**
 * Adds `src` (times `gain`) into `dst` starting at sample `offset`; what falls outside is dropped.
 * @param {Float32Array} dst
 * @param {Float32Array} src
 * @param {number} [offset] samples
 * @param {number} [gain]
 */
export function addAt(dst, src, offset = 0, gain = 1) {
  const start = Math.round(offset);
  const from = Math.max(0, -start);
  const to = Math.min(src.length, dst.length - start);
  for (let i = from; i < to; i++) dst[start + i] += src[i] * gain;
  return dst;
}

/**
 * Multiplies `buf` by `env` (an array, or a function of the sample index) in place.
 * @param {Float32Array} buf
 * @param {Float32Array|((i: number) => number)} env
 */
export function mul(buf, env) {
  if (typeof env === 'function') for (let i = 0; i < buf.length; i++) buf[i] *= env(i);
  else for (let i = 0; i < buf.length; i++) buf[i] *= i < env.length ? env[i] : 0;
  return buf;
}

/** Multiplies `buf` by a constant in place. */
export function gain(buf, g) {
  for (let i = 0; i < buf.length; i++) buf[i] *= g;
  return buf;
}

/** The largest |sample| over one or more channels. */
export function peak(...channels) {
  let m = 0;
  for (const c of channels) for (let i = 0; i < c.length; i++) m = Math.max(m, Math.abs(c[i]));
  return m;
}

/** The RMS over [from, to). */
export function rms(buf, from = 0, to = buf.length) {
  let s = 0;
  for (let i = from; i < to; i++) s += buf[i] * buf[i];
  return Math.sqrt(s / Math.max(1, to - from));
}

/** Scales `buf` so its peak is `peakDb` dBFS, in place. */
export function normalize(buf, peakDb = -1) {
  const p = peak(buf);
  if (p > 0) gain(buf, db(peakDb) / p);
  return buf;
}

/**
 * Raised-cosine fade-in and fade-out in place (no click at either end).
 * @param {Float32Array} buf
 * @param {number} sr
 * @param {number} fadeIn seconds
 * @param {number} fadeOut seconds
 */
export function fade(buf, sr, fadeIn, fadeOut) {
  const a = Math.min(buf.length, Math.round(fadeIn * sr));
  const b = Math.min(buf.length, Math.round(fadeOut * sr));
  for (let i = 0; i < a; i++) buf[i] *= 0.5 - 0.5 * Math.cos((Math.PI * i) / a);
  for (let i = 0; i < b; i++) buf[buf.length - 1 - i] *= 0.5 - 0.5 * Math.cos((Math.PI * i) / b);
  return buf;
}

/** A reversed copy. */
export function reverse(buf) {
  const out = new Float32Array(buf.length);
  for (let i = 0; i < buf.length; i++) out[i] = buf[buf.length - 1 - i];
  return out;
}

/** A copy delayed by `seconds` (the buffer grows by the delay). */
export function delayed(buf, sr, seconds) {
  const n = Math.round(seconds * sr);
  const out = new Float32Array(buf.length + n);
  out.set(buf, n);
  return out;
}

/** Joins buffers end to end. */
export function concat(...parts) {
  const out = new Float32Array(parts.reduce((s, p) => s + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

/**
 * Equal-power pan of a mono buffer: [left, right]. pan -1 (left) .. 1 (right).
 * @param {Float32Array} mono
 * @param {number} pan
 * @returns {[Float32Array, Float32Array]}
 */
export function pan(mono, pan) {
  const a = ((Math.max(-1, Math.min(1, pan)) + 1) * Math.PI) / 4;
  const l = Float32Array.from(mono);
  const r = Float32Array.from(mono);
  gain(l, Math.cos(a));
  gain(r, Math.sin(a));
  return [l, r];
}

/**
 * A seamless loop: the last `xf` seconds are crossfaded (equal power) over the first `xf` seconds and cut off, so the
 * result's end runs straight into its start. The result is `xf` shorter than the input.
 * @param {Float32Array} buf
 * @param {number} sr
 * @param {number} xf seconds
 */
export function loopCrossfade(buf, sr, xf) {
  const n = Math.round(xf * sr);
  const len = buf.length - n;
  if (len <= n) throw new Error('loopCrossfade: the buffer is too short for the crossfade');
  const out = buf.slice(0, len);
  for (let i = 0; i < n; i++) {
    const t = i / n;
    out[i] = buf[i] * Math.sin((Math.PI / 2) * t) + buf[len + i] * Math.cos((Math.PI / 2) * t);
  }
  return out;
}

/**
 * Adds `src` into `dst` at `offset` circularly (what runs past the end wraps to the start): events in a loop.
 * @param {Float32Array} dst
 * @param {Float32Array} src
 * @param {number} offset samples
 * @param {number} [g]
 */
export function addWrapped(dst, src, offset, g = 1) {
  const n = dst.length;
  let at = ((Math.round(offset) % n) + n) % n;
  for (let i = 0; i < src.length; i++) {
    dst[at] += src[i] * g;
    at++;
    if (at === n) at = 0;
  }
  return dst;
}

/**
 * Cuts the dead end of a one-shot: everything after the last sample above `floorDb` (re: the peak), plus `keep`
 * seconds, with a short fade so the cut is inaudible. Returns a copy.
 * @param {Float32Array} buf
 * @param {number} sr
 * @param {number} [floorDb]
 * @param {number} [keep]
 */
export function trimTail(buf, sr, floorDb = -78, keep = 0.02) {
  const limit = peak(buf) * db(floorDb);
  let last = buf.length - 1;
  while (last > 0 && Math.abs(buf[last]) < limit) last--;
  const end = Math.min(buf.length, last + Math.round(keep * sr));
  const out = buf.slice(0, Math.max(1, end));
  fade(out, sr, 0, Math.min(keep, out.length / sr / 2));
  return out;
}
