// grains.mjs: Poisson showers. Debris, rain, sparks, fizz and shattered glass are many tiny events whose timing is
// random but whose density follows a law (a burst that thins out, a steady patter): event times are drawn from a
// non-homogeneous Poisson process (by thinning), and each event renders its own small grain: a shard's ping, a
// grit click, a bubble.

import { decayFactor } from './env.mjs';
import { white } from './noise.mjs';
import { Biquad } from './filters.mjs';

/**
 * Event times in [0, duration) of a Poisson process with intensity rate(t) <= peak events per second.
 * @param {import('./rng.mjs').Rng} rng
 * @param {number} duration seconds
 * @param {number|((t: number) => number)} rate
 * @param {number} [peak] an upper bound of rate(t) (required when rate is a function)
 */
export function poissonTimes(rng, duration, rate, peak) {
  const top = typeof rate === 'number' ? rate : peak;
  if (!(top > 0)) throw new Error('poissonTimes: a function rate needs its peak');
  const times = [];
  let t = 0;
  for (;;) {
    t += -Math.log(1 - rng.next()) / top;
    if (t >= duration) break;
    const r = typeof rate === 'number' ? rate : rate(t);
    if (rng.next() * top <= r) times.push(t);
  }
  return times;
}

/**
 * A shower: one grain per time, mixed into a buffer of n samples.
 * @param {number} n
 * @param {number} sr
 * @param {number[]} times seconds
 * @param {(t: number, index: number) => {grain: Float32Array, gain: number}} make
 */
export function shower(n, sr, times, make) {
  const out = new Float32Array(n);
  times.forEach((t, index) => {
    const { grain, gain } = make(t, index);
    const start = Math.round(t * sr);
    const to = Math.min(grain.length, n - start);
    for (let i = 0; i < to; i++) out[start + i] += grain[i] * gain;
  });
  return out;
}

/**
 * A shard's ping: a few high-Q partials of a thin glass sliver (inharmonic ratios, each detuned a little), struck
 * with a sharp attack, decaying in t60. Short and many, never one long whistle.
 * @param {number} sr
 * @param {import('./rng.mjs').Rng} rng
 * @param {{freq: number, t60: number, ratios?: number[], spread?: number}} spec
 */
export function ping(sr, rng, { freq, t60, ratios = [1, 2.32, 4.25], spread = 0.03 }) {
  const n = Math.round(Math.min(1.2, t60 * 1.05) * sr) + 8;
  const out = new Float32Array(n);
  ratios.forEach((ratio, k) => {
    const f = freq * ratio * (1 + rng.range(-spread, spread));
    if (f >= sr * 0.45) return;
    const amp = (k === 0 ? 1 : rng.range(0.15, 0.6)) / (k + 1);
    const r = decayFactor(t60 / (1 + k * 0.6), sr);
    const w = (2 * Math.PI * f) / sr;
    let ph = rng.range(0, Math.PI * 2);
    let env = amp;
    for (let i = 0; i < n; i++) {
      const attack = i < 24 ? i / 24 : 1;
      out[i] += Math.sin(ph) * env * attack;
      ph += w;
      env *= r;
    }
  });
  return out;
}

/**
 * A grit click: a few milliseconds of band-passed noise (a grain of sand, a crumb of plaster, a crushed fleck).
 * @param {number} sr
 * @param {import('./rng.mjs').Rng} rng
 * @param {{freq: number, q?: number, length?: number}} spec
 */
export function click(sr, rng, { freq, q = 1.5, length = 0.004 }) {
  const n = Math.max(8, Math.round(length * sr));
  const noise = white(n, rng);
  for (let i = 0; i < n; i++) noise[i] *= Math.exp((-5 * i) / n);
  return new Biquad('bandpass', sr, freq, q).process(noise, new Float32Array(n + 64));
}

/**
 * A bubble (Minnaert): a sine near f that rises in pitch as the bubble shrinks to the surface, decaying fast.
 * Liquid: splashes, a fizz, a gurgle in a pipe.
 * @param {number} sr
 * @param {import('./rng.mjs').Rng} rng
 * @param {{freq: number, t60?: number, rise?: number}} spec rise: the fractional pitch rise over the bubble's life
 */
export function bubble(sr, rng, { freq, t60 = 0.03, rise = 0.6 }) {
  const n = Math.round(t60 * 1.1 * sr) + 8;
  const out = new Float32Array(n);
  const r = decayFactor(t60, sr);
  let ph = rng.range(0, Math.PI * 2);
  let env = 1;
  for (let i = 0; i < n; i++) {
    const t = i / n;
    const f = freq * (1 + rise * t);
    ph += (2 * Math.PI * f) / sr;
    const attack = i < 16 ? i / 16 : 1;
    out[i] = Math.sin(ph) * env * attack;
    env *= r;
  }
  return out;
}
