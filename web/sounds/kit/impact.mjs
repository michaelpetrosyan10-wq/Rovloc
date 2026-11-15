// impact.mjs: struck things. burst() is the exciter every impact starts from (a noise burst whose length and colour
// say how soft and how big the contact is: a heel is 4-8 ms of dull noise, a knuckle 1 ms of bright). footfall() is a
// whole step, built the way a foot lands on a floor (docs/SOUND.md 5):
//
//   heel     an optional first contact (a walking heel) `heel.delay` before the weight
//   thump    the mass settling: the pitch-dropping saturated sub (thump.mjs)
//   body     the floor answering: a modal bank (a slab's few low-mid modes, a plate's dense shimmer, boards' hollow)
//   contact  the dull slap of the sole: low-passed noise
//   texture  what the surface adds at the contact: grit (Poisson clicks: gravel, sand, shards) or a bright crack (tile)
//   after    what follows: a creak, a drag, a rattle (a buffer the voice renders, mixed at its own offset)
//
// Every layer is scaled to unit peak and mixed at its own dB, so a recipe reads as a balance of parts.

import { modal } from './modal.mjs';
import { white, pink } from './noise.mjs';
import { butter } from './filters.mjs';
import { thump } from './thump.mjs';
import { poissonTimes, shower, click } from './grains.mjs';
import { addAt, db, peak, gain } from './mix.mjs';

/**
 * Scales a buffer to unit peak in place (a silent buffer stays silent).
 * @param {Float32Array} buf
 */
export function unit(buf) {
  const p = peak(buf);
  return p > 0 ? gain(buf, 1 / p) : buf;
}

/**
 * A noise burst: a raised-cosine attack of `attack` s, an exponential fall over `length` (to about -40 dB), band
 * limited by a 12 dB/octave high-pass at `hp` and low-pass at `cutoff`.
 * @param {number} sr
 * @param {import('./rng.mjs').Rng} rng
 * @param {{length?: number, attack?: number, cutoff?: number, hp?: number, colour?: 'white'|'pink'}} [spec]
 */
export function burst(sr, rng, { length = 0.006, attack = 0.0003, cutoff = 2000, hp = 30, colour = 'white' } = {}) {
  const n = Math.round(length * sr * 1.6) + Math.round(attack * sr) + 32;
  const src = colour === 'pink' ? pink(n, rng) : white(n, rng);
  const a = Math.max(1, Math.round(attack * sr));
  const k = 4.6 / Math.max(1, length * sr);
  for (let i = 0; i < n; i++) {
    const rise = i < a ? 0.5 - 0.5 * Math.cos((Math.PI * i) / a) : 1;
    src[i] *= rise * Math.exp(-k * Math.max(0, i - a));
  }
  let out = cutoff < sr * 0.45 ? butter(src, sr, 'lowpass', cutoff, 2) : src;
  if (hp > 0) out = butter(out, sr, 'highpass', hp, 2);
  return out;
}

/**
 * Grit: `count` (Poisson, over `spread` s with a falling rate) band-passed clicks: gravel shifting, sand, a crushed
 * fleck, shards grinding. Unit peak.
 * @param {number} sr
 * @param {import('./rng.mjs').Rng} rng
 * @param {{count: number, spread: number, freq: [number, number], q?: number, length?: [number, number]}} spec
 */
export function grit(sr, rng, { count, spread, freq, q = 1.2, length = [0.002, 0.006] }) {
  const n = Math.round((spread + 0.03) * sr);
  const rate = (t) => Math.exp(-3 * (t / spread));
  const times = poissonTimes(rng.fork('times'), spread, (t) => (count / spread) * 2.9 * rate(t), (count / spread) * 2.9);
  const r = rng.fork('grains');
  return unit(shower(n, sr, times, (t) => ({
    grain: click(sr, r, { freq: freq[0] * (freq[1] / freq[0]) ** r.next(), q, length: r.range(length[0], length[1]) }),
    gain: r.range(0.3, 1) * (0.4 + 0.6 * rate(t)),
  })));
}

/**
 * @typedef {{
 *   length?: number,
 *   heel?: {delay: number, gain: number, cutoff?: number, length?: number},
 *   thump: {f0: number, f1: number, drop: number, t60: number, drive?: number, gain: number},
 *   body: {modes: import('./modal.mjs').Mode[], gain: number, excite?: number, cutoff?: number},
 *   contact: {length: number, cutoff: number, gain: number, hp?: number},
 *   texture?: {buffer: Float32Array, gain: number, offset?: number},
 *   after?: {buffer: Float32Array, gain: number, offset: number},
 * }} Footfall  gains in dB; offsets and delays in seconds after the weight lands
 */

/**
 * One footfall. The weight lands at `heel.delay` (or 0); everything is mixed into `length` seconds.
 * @param {number} sr
 * @param {import('./rng.mjs').Rng} rng
 * @param {Footfall} spec
 */
export function footfall(sr, rng, spec) {
  const { length = 1.2, heel, thump: th, body, contact, texture, after } = spec;
  const out = new Float32Array(Math.round(length * sr));
  const land = heel ? Math.round(heel.delay * sr) : 0;
  if (heel) {
    // the heel: a short dull contact and a little of the floor's answer
    const hb = burst(sr, rng.fork('heel'), { length: heel.length ?? 0.004, cutoff: heel.cutoff ?? 900, hp: 60 });
    const hbody = modal(hb, sr, body.modes.map((m) => ({ ...m, t60: m.t60 * 0.5 })), Math.round(0.25 * sr));
    addAt(out, unit(hb), 0, db(heel.gain));
    addAt(out, unit(hbody), 0, db(heel.gain - 4));
  }
  const exc = burst(sr, rng.fork('excite'), { length: body.excite ?? 0.005, cutoff: body.cutoff ?? 1800, hp: 20 });
  const bodySound = modal(exc, sr, body.modes, Math.round(Math.min(length, 1.5) * sr));
  addAt(out, unit(bodySound), land, db(body.gain));
  const sub = thump(sr, { f0: th.f0, f1: th.f1, drop: th.drop, t60: th.t60, drive: th.drive ?? 2.5, phase: rng.range(0, 0.6) });
  addAt(out, unit(sub), land, db(th.gain));
  const slap = burst(sr, rng.fork('contact'), { length: contact.length, cutoff: contact.cutoff, hp: contact.hp ?? 50, colour: 'pink' });
  addAt(out, unit(slap), land, db(contact.gain));
  if (texture) addAt(out, unit(Float32Array.from(texture.buffer)), land + Math.round((texture.offset ?? 0) * sr), db(texture.gain));
  if (after) addAt(out, unit(Float32Array.from(after.buffer)), land + Math.round(after.offset * sr), db(after.gain));
  return out;
}
