// porcelain.mjs: HIS signature, the mask (docs/SOUND.md 1, law 7). Glazed porcelain is hard, thick and brittle: struck,
// it gives a short, dry, high-Q "tick" whose few partials sit between 1.2 and 5 kHz and die in tens of milliseconds
// (no long ring: the crack through it damps it). The mask rattles against itself and his face in irregular clusters,
// like chattering teeth: chatter() scatters those clusters in time. Only his sounds use this (spec invariant I1); the
// audit's porcelain detector (lib/measure.mjs porcelainClicks) counts the ticks.

import { modal } from './modal.mjs';
import { white } from './noise.mjs';
import { Biquad } from './filters.mjs';

/** A cracked porcelain shell's partial ratios (thick, so sparser and less stretched than thin glass). */
export const PORCELAIN = Object.freeze([1, 1.47, 2.09, 2.78, 3.56]);

/**
 * One porcelain tick: a 0.15 ms impulse and a fleck of contact noise into a bank of the shell's partials.
 * @param {number} sr
 * @param {import('./rng.mjs').Rng} rng
 * @param {{freq?: number, t60?: number, hardness?: number, crack?: number}} [spec] freq: the lowest partial (Hz,
 *   1200-3400 keeps every strong partial under 5 kHz); t60: its decay (s); hardness 0..1: how much bright contact
 *   noise; crack 0..1: the crack's buzz (a second, detuned strike 2-5 ms later, as the two halves knock)
 */
export function porcelainTick(sr, rng, { freq = 2200, t60 = 0.03, hardness = 0.5, crack = 0.3 } = {}) {
  const n = Math.round((t60 * 1.3 + 0.012) * sr);
  const exc = new Float32Array(n);
  const imp = Math.max(1, Math.round(0.00015 * sr));
  for (let i = 0; i < imp; i++) exc[i] = 1 - i / imp;
  const fleck = white(Math.round(0.0006 * sr), rng.fork('fleck'));
  for (let i = 0; i < fleck.length; i++) exc[i] += fleck[i] * hardness * 0.4 * (1 - i / fleck.length);
  if (crack > 0) {
    const at = Math.round(rng.range(0.002, 0.005) * sr);
    if (at < n) exc[at] += crack * rng.range(0.4, 0.8) * rng.sign();
  }
  const modes = PORCELAIN.map((ratio, k) => ({
    f: freq * ratio * (1 + rng.range(-0.035, 0.035)),
    t60: t60 / ratio ** 0.6,
    gain: (k === 0 ? 1 : rng.range(0.35, 0.8)) / (1 + 0.45 * k),
  })).filter((m) => m.f < 5200);
  const out = modal(exc, sr, modes, n);
  // the contact itself: a sub-millisecond high fleck
  const hp = new Biquad('highpass', sr, 3000, 0.7);
  for (let i = 0; i < fleck.length; i++) out[i] += hp.tick(fleck[i]) * hardness * 0.05;
  return out;
}

/**
 * Chattering: clusters of ticks, `rate` clusters a second on average (Poisson), each cluster 2-5 ticks 10-40 ms apart
 * with falling level, every tick its own pitch and damping. Returns the buffer (unit peak tick ~ level 1).
 * @param {number} n samples
 * @param {number} sr
 * @param {import('./rng.mjs').Rng} rng
 * @param {{rate?: number, from?: number, to?: number, cluster?: [number, number], spacing?: [number, number],
 *   freq?: [number, number], t60?: [number, number], density?: (t: number) => number}} [spec] from / to: the span (s)
 *   the clusters may start in; density(t) 0..1 thins the clusters over time
 */
export function chatter(n, sr, rng, { rate = 4, from = 0, to = n / sr, cluster = [2, 5], spacing = [0.01, 0.04], freq = [1300, 3400], t60 = [0.015, 0.045], density } = {}) {
  const out = new Float32Array(n);
  const r = rng.fork('chatter');
  let t = from + -Math.log(1 - r.next()) / rate;
  while (t < to) {
    if (!density || r.next() < density(t)) {
      const count = r.int(cluster[0], cluster[1]);
      let at = t;
      let level = r.range(0.6, 1);
      for (let k = 0; k < count; k++) {
        const tick = porcelainTick(sr, r.fork(`t${k}`), { freq: r.range(freq[0], freq[1]), t60: r.range(t60[0], t60[1]), hardness: r.range(0.3, 0.8), crack: r.range(0, 0.5) });
        const start = Math.round(at * sr);
        for (let i = 0; i < tick.length && start + i < n; i++) out[start + i] += tick[i] * level;
        at += r.range(spacing[0], spacing[1]);
        level *= r.range(0.55, 0.9);
      }
    }
    t += -Math.log(1 - r.next()) / rate;
  }
  return out;
}
