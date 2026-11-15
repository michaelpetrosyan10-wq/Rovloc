// distance.mjs: the ONE distance model the game uses for positional sounds (docs/SOUND.md 6). A pure function of the
// listener's distance, the walls between, and the sound's own carry (from the manifest): how loud it arrives, how
// dark (air and walls eat the highs), and how much of it is the room's reverberation rather than the direct sound.
//
//   gain     1 inside `ref`; then (ref / d) ^ rolloff (1 = free field, -6 dB per doubling; under 1 for sounds that
//            the building's corridors carry), fading linearly to 0 between `fade` x max and max; x 0.5 per wall.
//   cutoff   a low-pass: air and distance (18 kHz at 8 studs falling to 900 Hz at about 250), then the walls'
//            2,400 / 1,100 / 600 Hz (spec 3.4's voice model), whichever is lower.
//   reverb   the reverberant share of the arriving energy: d / (d + critical) (critical 12 studs), +0.12 per wall,
//            at most 0.92. The game sends sqrt(share) of the gain to the one shared convolver and keeps
//            sqrt(1 - share) direct (energy preserved), and without a convolver plays the direct part at the full
//            gain, so it sounds right either way.
//
// The spec's talking-monster Head channel is this model with carry {ref: 8, rolloff: 1, max: 90, fade: 2/3}.

import { butter } from './filters.mjs';
import { convolveStereo } from './reverb.mjs';

/** @typedef {{ref: number, max: number, rolloff?: number, fade?: number}} Carry */
/** @typedef {{gain: number, cutoff: number, reverb: number, direct: number, send: number}} Heard */

export const WALL_CUTOFFS = Object.freeze([20000, 2400, 1100, 600]);
export const CRITICAL_DISTANCE = 12;
export const MAX_REVERB = 0.92;

/**
 * @param {number} distance studs from the listener's head
 * @param {number} walls walls between (as hearing counts them)
 * @param {Carry} carry
 * @returns {Heard}
 */
export function heard(distance, walls, carry) {
  const d = Math.max(0, distance);
  const rolloff = carry.rolloff ?? 1;
  const fadeStart = (carry.fade ?? 2 / 3) * carry.max;
  let gain = d <= carry.ref ? 1 : (carry.ref / d) ** rolloff;
  if (d >= carry.max) gain = 0;
  else if (d > fadeStart) gain *= 1 - (d - fadeStart) / (carry.max - fadeStart);
  const w = Math.max(0, Math.round(walls));
  gain *= 0.5 ** w;
  const air = Math.min(20000, Math.max(900, 18000 * (8 / Math.max(d, 8)) ** 0.95));
  const cutoff = Math.min(air, WALL_CUTOFFS[Math.min(w, WALL_CUTOFFS.length - 1)]);
  const reverb = Math.min(MAX_REVERB, d / (d + CRITICAL_DISTANCE) + 0.12 * w);
  return { gain, cutoff, reverb, direct: gain * Math.sqrt(1 - reverb), send: gain * Math.sqrt(reverb) };
}

/**
 * A dry mono sound as heard through the model (what the game will do at run time): low-passed at the cutoff
 * (12 dB/octave), the direct part plus the send through the shared IR. Without an IR the direct part plays at the
 * full gain. Returns [left, right].
 * @param {Float32Array} dry
 * @param {number} sr
 * @param {Heard} h
 * @param {[Float32Array, Float32Array]|null} ir
 * @returns {[Float32Array, Float32Array]}
 */
export function hear(dry, sr, h, ir) {
  const dark = h.cutoff < 19000 ? butter(dry, sr, 'lowpass', h.cutoff, 2) : Float32Array.from(dry);
  if (!ir) {
    const l = Float32Array.from(dark);
    for (let i = 0; i < l.length; i++) l[i] *= h.gain;
    return [l, Float32Array.from(l)];
  }
  const [wl, wr] = convolveStereo(dark, ir);
  for (let i = 0; i < wl.length; i++) {
    const d = i < dark.length ? dark[i] * h.direct : 0;
    wl[i] = d + wl[i] * h.send;
    wr[i] = d + wr[i] * h.send;
  }
  return [wl, wr];
}
