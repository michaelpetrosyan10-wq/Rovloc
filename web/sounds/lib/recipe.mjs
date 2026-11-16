// recipe.mjs: a sound as a recipe over recordings (docs/SOUND.md 3 and 7). recorded(def) turns a definition whose
// `layers(variant, rng)` returns plain data into a voice (lib/voices.mjs): its `sources` (every recording any variant
// plays, listed without rendering) and its `render`.
//
// A layer is one recording, played the way tape is:
//
//   src        the recording's id, "<lib>/<pack>/<file>" (lib/sources.mjs)
//   from, to   the part of the recording, in its own seconds (default: all of it that sounds)
//   rate       the playback rate, or [lo, hi] drawn per variant: under 1 is slower, lower and longer
//   bend       the rate over the layer's own seconds as factors of `rate`: [[0, 1], [0.8, 0.6]] falls by 40 %
//   reverse    played backwards
//   trim       cut at the transient, the way an editor tops a hit: the soft run-up before the first sample that
//              reaches a quarter of the peak is dropped (0.5 ms is kept and faded in)
//   hp, lp     cut-offs in Hz (12 dB/octave), or [Hz, order]
//   eq         biquads: [[type, Hz, q, dB], ...] (a low shelf is weight, a peak is a body)
//   drive      dB into the oversampled soft clipper (density; the harmonics a laptop speaker plays of a low sound)
//   fadeIn, fadeOut   seconds
//   env        level breakpoints over the layer's seconds: [[0, 0], [0.4, 1], [2, 0]]
//   flutter    [Hz, depth]: the soft palate's flutter (kit/voice.mjs) pulsing a throat recording, the way a slowed
//              voice's fry is thickened in creature design: his rattle
//   gain       dB, of the layer brought to peak 1 (default 0)
//   at         where it starts in the sound, seconds, or [lo, hi] drawn per variant
//   pan        -1 (left) .. 1 (right): any panned layer makes the mix stereo
//   chance     the share of the variants it is in
//
// `finish(ctx, mix)` takes the mix on (a sub under it, drive, a room: the helpers below) and returns the samples.
// A loop's layers are laid into exactly the loop's length; with a crossfade of 0 what runs past the end wraps to the
// start (a rhythm that closes on itself), otherwise the pipeline folds the crossfade.

import * as K from '../kit/index.mjs';
import { take } from './sources.mjs';

/**
 * @typedef {{
 *   src: string, from?: number, to?: number, rate?: number|[number, number], bend?: Array<[number, number]>,
 *   reverse?: boolean, trim?: boolean, hp?: number|[number, number], lp?: number|[number, number],
 *   eq?: Array<[K.BiquadType, number, number, number]>, drive?: number, fadeIn?: number, fadeOut?: number,
 *   env?: Array<[number, number]>, flutter?: [number, number], gain?: number, at?: number|[number, number], pan?: number, chance?: number,
 * }} Layer
 * @typedef {{sr: number, rng: K.Rng, variant: number, name: string, seconds: number}} Ctx
 */

const draw = (rng, v, fallback) => (v === undefined ? fallback : Array.isArray(v) ? rng.range(v[0], v[1]) : v);

function cut(x, sr, type, spec) {
  if (spec === undefined) return x;
  const [freq, order] = Array.isArray(spec) ? spec : [spec, 2];
  return K.butter(x, sr, type, freq, order);
}

/** `x` from 0.5 ms before its first sample at a quarter of its peak, faded in over that 0.5 ms. */
function topped(x, sr) {
  const limit = 0.25 * K.peak(x);
  let i = 0;
  while (i < x.length - 1 && Math.abs(x[i]) < limit) i++;
  return K.region(x, sr, Math.max(0, i / sr - 0.0005), Infinity, 0.0005, 0.01);
}

/**
 * One layer's samples, at peak 1 times its gain (null when its chance fell out).
 * @param {Layer} layer
 * @param {number} sr
 * @param {K.Rng} rng
 */
export function renderLayer(layer, sr, rng) {
  // every draw is made whether or not the layer plays, so one layer's chance never shifts another's numbers
  const playing = layer.chance === undefined || rng.chance(layer.chance);
  const rate = draw(rng, layer.rate, 1);
  if (!playing) return null;
  let x;
  if (layer.from !== undefined || layer.to !== undefined) {
    x = K.region(take(layer.src, layer.from ?? 0, layer.to ?? null), sr, 0, Infinity, 0.004, 0.02);
  } else {
    const whole = take(layer.src);
    const [a, b] = K.active(whole, sr);
    x = K.region(whole, sr, a, b, 0.0005, 0.01);
  }
  if (layer.trim) x = topped(x, sr);
  if (layer.reverse) x = K.reverse(x);
  if (layer.bend) {
    const points = layer.bend;
    const curve = (t) => {
      let k = 0;
      while (k < points.length - 1 && t >= points[k + 1][0]) k++;
      if (k >= points.length - 1) return rate * points[points.length - 1][1];
      const [t0, v0] = points[k];
      const [t1, v1] = points[k + 1];
      return rate * (t <= t0 ? v0 : v0 + ((v1 - v0) * (t - t0)) / (t1 - t0));
    };
    x = K.resample(x, curve, sr);
  } else if (rate !== 1) x = K.resample(x, rate);
  x = cut(x, sr, 'highpass', layer.hp);
  x = cut(x, sr, 'lowpass', layer.lp);
  for (const [type, freq, q, gainDb] of layer.eq ?? []) x = K.biquad(x, sr, type, freq, q, gainDb);
  if (layer.drive) x = K.saturate(K.unit(x), { drive: K.db(layer.drive), curve: 'tanh' });
  if (layer.env) K.mul(x, K.segments(x.length, sr, layer.env.map(([t, v]) => [t, v])));
  if (layer.flutter) K.mul(x, K.flutter(x.length, sr, { rate: layer.flutter[0], depth: layer.flutter[1], rng: rng.fork('flutter') }));
  if (layer.fadeIn || layer.fadeOut) K.fade(x, sr, layer.fadeIn ?? 0, layer.fadeOut ?? 0);
  K.unit(x);
  return K.gain(x, K.db(layer.gain ?? 0));
}

/**
 * The layers mixed: a Float32Array, or [left, right] when any layer is panned.
 * @param {Ctx} ctx
 * @param {Layer[]} layers
 * @param {{seconds?: number, wrap?: boolean}} [spec] a fixed length (loops), wrapping what runs past it
 */
export function mixLayers(ctx, layers, { seconds = 0, wrap = false } = {}) {
  const { sr } = ctx;
  const parts = [];
  layers.forEach((layer, index) => {
    const rng = ctx.rng.fork(`layer${index}`);
    const at = draw(rng, layer.at, 0);
    const x = renderLayer(layer, sr, rng);
    if (x) parts.push({ x, at: Math.round(at * sr), pan: layer.pan });
  });
  if (!parts.length) throw new Error(`${ctx.name} #${ctx.variant}: no layer plays`);
  const n = seconds > 0 ? Math.round(seconds * sr) : Math.max(...parts.map((p) => p.at + p.x.length));
  const stereo = parts.some((p) => p.pan !== undefined);
  const left = new Float32Array(n);
  const right = stereo ? new Float32Array(n) : left;
  const add = wrap ? K.addWrapped : K.addAt;
  for (const p of parts) {
    if (!stereo) add(left, p.x, p.at, 1);
    else {
      const angle = ((Math.max(-1, Math.min(1, p.pan ?? 0)) + 1) * Math.PI) / 4;
      add(left, p.x, p.at, Math.cos(angle) * Math.SQRT2);
      add(right, p.x, p.at, Math.sin(angle) * Math.SQRT2);
    }
  }
  return stereo ? [left, right] : left;
}

/**
 * A voice made of recordings.
 * @param {Omit<import('./voices.mjs').Voice, 'render'|'sources'> & {
 *   layers: (variant: number, rng: K.Rng) => Layer[],
 *   finish?: (ctx: Ctx, mix: any) => Float32Array|[Float32Array, Float32Array],
 * }} def
 * @returns {import('./voices.mjs').Voice}
 */
export function recorded(def) {
  const { layers, finish, ...voice } = def;
  const layersOf = (variant, rng) => layers(variant, rng.fork('layers'));
  const sources = new Set();
  for (let v = 1; v <= def.variants; v++) for (const l of layersOf(v, new K.Rng(K.seedOf(def.name, v)))) sources.add(l.src);
  return {
    ...voice,
    sources: [...sources].sort(),
    render: (ctx) => {
      const loop = def.loop;
      const mixed = mixLayers(ctx, layersOf(ctx.variant, ctx.rng), loop ? { seconds: ctx.seconds, wrap: loop.crossfade === 0 } : {});
      return finish ? finish(ctx, mixed) : mixed;
    },
  };
}

// ------------------------------------------------------------------ finishing

/**
 * The first `seconds` of a mix (mono or [left, right]), faded out over its last `fade` seconds: a one-shot cut to
 * its length (the class's limit) the way an editor ends a take, in its decay.
 * @template {Float32Array|[Float32Array, Float32Array]} T
 * @param {T} mix
 * @param {number} sr
 * @param {number} seconds
 * @param {number} [fade]
 * @returns {T}
 */
export function ending(mix, sr, seconds, fade = 0.3) {
  const cutOne = (x) => K.fade(x.slice(0, Math.min(x.length, Math.round(seconds * sr))), sr, 0, fade);
  return /** @type {T} */ (Array.isArray(mix) ? mix.map(cutOne) : cutOne(mix));
}

/**
 * A sub thump under an impact (the one thing no small recording carries): kit/thump.mjs at `gain` dB re: the mix's
 * peak, starting `at` seconds in. Returns the mix (lengthened if the thump outlasts it).
 * @param {Float32Array} mix
 * @param {number} sr
 * @param {{f0?: number, f1?: number, drop?: number, t60?: number, drive?: number, gain?: number, at?: number}} spec
 */
export function withSub(mix, sr, { f0 = 58, f1 = 40, drop = 0.07, t60 = 0.4, drive = 2.5, gain = -4, at = 0 } = {}) {
  const sub = K.unit(K.thump(sr, { f0, f1, drop, t60, drive }));
  const start = Math.round(at * sr);
  const out = new Float32Array(Math.max(mix.length, start + sub.length));
  out.set(mix);
  K.addAt(out, sub, start, K.peak(mix) * K.db(gain));
  return out;
}

/**
 * A mono sound baked into one of the game's spaces (kit/reverb.mjs SPACES), `wet` of its energy reverberant:
 * [left, right] with the tail.
 * @param {Float32Array} mix
 * @param {Ctx} ctx
 * @param {keyof typeof K.SPACES} space
 * @param {number} wet 0..1
 * @param {number} [darken] a low-pass on the direct sound, Hz (far away is dark)
 */
export function inSpace(mix, ctx, space, wet, darken = 20000) {
  return K.place(mix, ctx.sr, K.SPACES[space], { wet, darken, rng: ctx.rng.fork(`space:${space}`) });
}

/**
 * The same, kept mono (a positional sound that carries a little of its own room: the game adds the level's).
 * @param {Float32Array} mix
 * @param {Ctx} ctx
 * @param {keyof typeof K.SPACES} space
 * @param {number} wet 0..1
 */
export function inSpaceMono(mix, ctx, space, wet) {
  const [l, r] = inSpace(mix, ctx, space, wet);
  const out = new Float32Array(l.length);
  for (let i = 0; i < out.length; i++) out[i] = 0.5 * (l[i] + r[i]);
  return out;
}
