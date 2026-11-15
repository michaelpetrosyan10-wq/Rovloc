// pipeline.mjs: one variant from a voice's render to the samples that ship (docs/SOUND.md 7).
//
//   one-shot   high-passed at 18 Hz (DC, drift); leading silence and the dead tail (under -72 dB of the peak) trimmed, the tail faded over
//              its last 20 ms; a 0.3 ms fade-in (an impact still attacks in well under 5 ms); scaled to its reference
//              loudness (the loudest 400 ms block); peak-limited to -1 dBTP.
//   loop       high-passed at 18 Hz; the render's last `crossfade` seconds folded over its start (equal power), so the period
//              runs into itself; scaled to its reference loudness (integrated); limited over three periods and the
//              middle one kept (the limiter's gain is then periodic too). It ships with MARGIN seconds of its own
//              signal before and after the loop points, so any decoder offset under MARGIN still loops seamlessly.

import { Rng, seedOf } from '../kit/rng.mjs';
import { butter } from '../kit/filters.mjs';
import { loopCrossfade, db, peak, fade } from '../kit/mix.mjs';
import { limit } from '../kit/dynamics.mjs';
import { momentaryMax, integrated } from '../kit/loudness.mjs';
import { SR } from './voices.mjs';

export const MARGIN = 0.1;
export const CEILING = -1;

/**
 * Renders one variant of a voice and finishes it.
 * @param {import('./voices.mjs').Voice} voice
 * @param {number} variant 1-based
 * @returns {{channels: Float32Array[], loop: null|{start: number, end: number}, render: Float32Array[]}} channels: what
 *   ships (with the margins for a loop); render: the finished sound itself (the loop's one period)
 */
export function renderVariant(voice, variant) {
  const rng = new Rng(seedOf(voice.name, variant));
  const seconds = voice.loop ? voice.loop.seconds + voice.loop.crossfade : 0;
  const out = voice.render({ sr: SR, rng, variant, name: voice.name, seconds });
  let channels = Array.isArray(out) ? out.map((c) => Float32Array.from(c)) : [Float32Array.from(out)];
  if (channels.length !== voice.channels) {
    if (voice.channels === 2 && channels.length === 1) channels = [channels[0], Float32Array.from(channels[0])];
    else throw new Error(`${voice.name}: rendered ${channels.length} channels, declared ${voice.channels}`);
  }
  for (const c of channels) {
    for (let i = 0; i < c.length; i++) if (!Number.isFinite(c[i])) throw new Error(`${voice.name} #${variant}: a non-finite sample at ${i}`);
  }
  // DC and subsonic drift out (a 12 dB/octave high-pass at 18 Hz: the sub thumps at 35-90 Hz are untouched)
  channels = channels.map((c) => butter(c, SR, 'highpass', 18, 2));
  return voice.loop ? finishLoop(voice, channels) : finishOneShot(voice, channels);
}

/** @param {import('./voices.mjs').Voice} voice @param {Float32Array[]} channels */
function finishOneShot(voice, channels) {
  const p = peak(...channels);
  if (!(p > 0)) throw new Error(`${voice.name}: the render is silent`);
  const floorLead = p * db(-60);
  const floorTail = p * db(-72);
  let first = channels[0].length;
  let last = 0;
  for (const c of channels) {
    for (let i = 0; i < c.length; i++) if (Math.abs(c[i]) > floorLead) {
      first = Math.min(first, i);
      break;
    }
    for (let i = c.length - 1; i >= 0; i--) if (Math.abs(c[i]) > floorTail) {
      last = Math.max(last, i);
      break;
    }
  }
  const from = Math.max(0, first - Math.round(0.0005 * SR));
  const to = Math.min(channels[0].length, last + Math.round(0.02 * SR));
  let cut = channels.map((c) => c.slice(from, to));
  for (const c of cut) fade(c, SR, 0.0003, Math.min(0.02, c.length / SR / 3));
  const level = momentaryMax(cut, SR);
  const g = db(voice.loudness - level);
  for (const c of cut) for (let i = 0; i < c.length; i++) c[i] *= g;
  limit(cut, SR, { ceilingDb: CEILING });
  return { channels: cut, loop: null, render: cut };
}

/** @param {import('./voices.mjs').Voice} voice @param {Float32Array[]} channels */
function finishLoop(voice, channels) {
  const loop = /** @type {{seconds: number, crossfade: number}} */ (voice.loop);
  const L = Math.round(loop.seconds * SR);
  const periodic = channels.map((c) => {
    if (loop.crossfade > 0) return loopCrossfade(c, SR, loop.crossfade).slice(0, L);
    if (c.length < L) throw new Error(`${voice.name}: a crossfade-free loop must render ${loop.seconds} s`);
    return c.slice(0, L);
  });
  const level = integrated(periodic, SR);
  const g = db(voice.loudness - level);
  // three periods limited together; the middle one keeps a periodic gain
  const tiled = periodic.map((c) => {
    const t = new Float32Array(3 * L);
    for (let k = 0; k < 3; k++) t.set(c, k * L);
    for (let i = 0; i < t.length; i++) t[i] *= g;
    return t;
  });
  limit(tiled, SR, { ceilingDb: CEILING });
  const period = tiled.map((t) => t.slice(L, 2 * L));
  const M = Math.round(MARGIN * SR);
  const shipped = period.map((c) => {
    const s = new Float32Array(L + 2 * M);
    s.set(c.subarray(L - M), 0);
    s.set(c, M);
    s.set(c.subarray(0, M), M + L);
    // the file's own ends fade (they are outside the loop points: never heard in a loop)
    fade(s, SR, 0.003, 0.003);
    return s;
  });
  return { channels: shipped, loop: { start: M / SR, end: (M + L) / SR }, render: period };
}
