// Timeline (Shared/Sequence/Timeline.luau): keyed tracks played against a clock.
//
// A Spec is { duration, tracks }. Each track names a handler `kind` and holds keys { t, value, ease?, persist? }
// sorted by time. Continuous handlers are sampled every update (numbers, Vector3, Matrix4 and Color interpolate with
// the destination key's ease; booleans and strings step); event handlers fire each key once when playback passes it.
// A playback first updated after its start is fast-forwarded: event keys more than LateTolerance seconds in the past
// are skipped unless the key (or its track) persists; continuous tracks jump to the current sample. At the end the
// last values apply and every handler's stop(ctx, track, completed) runs; stop() ends early (completed = false).

import * as THREE from 'three';
import { lerpFrame } from './util.js';

export const LateTolerance = 0.25;
const C1 = 1.70158;
const C3 = C1 + 1;

/**
 * @typedef {'Linear'|'Step'|'InQuad'|'OutQuad'|'InOutQuad'|'InCubic'|'OutCubic'|'InOutCubic'|'InSine'|'OutSine'|
 *   'InOutSine'|'InExpo'|'OutExpo'|'InOutExpo'|'InBack'|'OutBack'} Ease
 * @typedef {number|boolean|string|THREE.Vector3|THREE.Matrix4|THREE.Color} Value
 * @typedef {{t: number, value: Value, ease?: Ease, persist?: boolean}} Key
 * @typedef {{kind: string, keys: Key[], target?: string, arg?: string, volume?: number, persist?: boolean,
 *   hold?: boolean}} Track
 * @typedef {{duration: number, tracks: Track[]}} Spec
 * @typedef {{id: string, startAt: number, args: Record<string, any>, elapsed: number}} Context
 * @typedef {{mode: 'Continuous'|'Events', apply?: (ctx: Context, track: Track, value: Value) => void,
 *   fire?: (ctx: Context, track: Track, key: Key, late: number) => void,
 *   stop?: (ctx: Context, track: Track, completed: boolean) => void}} TrackHandler
 */

/** Eased progress for x in [0, 1] (clamped). Step stays 0 until x reaches 1. */
export function ease(name, x) {
  const t = Math.min(1, Math.max(0, x));
  switch (name) {
    case undefined:
    case null:
    case 'Linear': return t;
    case 'Step': return t >= 1 ? 1 : 0;
    case 'InQuad': return t * t;
    case 'OutQuad': return 1 - (1 - t) * (1 - t);
    case 'InOutQuad': return t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2;
    case 'InCubic': return t * t * t;
    case 'OutCubic': return 1 - (1 - t) ** 3;
    case 'InOutCubic': return t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2;
    case 'InSine': return 1 - Math.cos((t * Math.PI) / 2);
    case 'OutSine': return Math.sin((t * Math.PI) / 2);
    case 'InOutSine': return -(Math.cos(Math.PI * t) - 1) / 2;
    case 'InExpo': return t <= 0 ? 0 : 2 ** (10 * t - 10);
    case 'OutExpo': return t >= 1 ? 1 : 1 - 2 ** (-10 * t);
    case 'InOutExpo':
      if (t <= 0 || t >= 1) return t;
      return t < 0.5 ? 2 ** (20 * t - 10) / 2 : (2 - 2 ** (-20 * t + 10)) / 2;
    case 'InBack': return C3 * t * t * t - C1 * t * t;
    case 'OutBack': {
      const u = t - 1;
      return 1 + C3 * u * u * u + C1 * u * u;
    }
    default: return t;
  }
}

/** a toward b by alpha: numbers, vectors, frames and colours interpolate; anything else steps at alpha 1. */
export function interpolate(a, b, alpha) {
  if (typeof a === 'number' && typeof b === 'number') return a + (b - a) * alpha;
  if (a instanceof THREE.Vector3 && b instanceof THREE.Vector3) return a.clone().lerp(b, alpha);
  if (a instanceof THREE.Matrix4 && b instanceof THREE.Matrix4) return lerpFrame(a, b, alpha);
  if (a instanceof THREE.Color && b instanceof THREE.Color) return a.clone().lerp(b, alpha);
  return alpha >= 1 ? b : a;
}

/** The track's value at t (undefined without keys). @param {Track} track */
export function sampleTrack(track, t) {
  const keys = track.keys;
  if (keys.length === 0) return undefined;
  if (t <= keys[0].t) return keys[0].value;
  for (let i = 1; i < keys.length; i++) {
    const k = keys[i];
    if (t < k.t) {
      const p = keys[i - 1];
      const span = k.t - p.t;
      if (span <= 0) return k.value;
      return interpolate(p.value, k.value, ease(k.ease, (t - p.t) / span));
    }
  }
  return keys[keys.length - 1].value;
}

/** Keys with from < t <= to. */
function keysBetween(track, from, to) {
  return track.keys.filter((k) => k.t > from && k.t <= to);
}

/**
 * A playback of `spec` (call update(now) with the clock). Handlers are resolved by kind on each update until found.
 * @param {Spec} spec
 * @param {string} id
 * @param {number} startAt
 * @param {(kind: string) => TrackHandler|undefined} resolve
 * @param {Record<string, any>} [args]
 */
export function play(spec, id, startAt, resolve, args = {}) {
  /** @type {Context} */
  const ctx = { id, startAt, args, elapsed: 0 };
  /** @type {Array<TrackHandler|undefined>} */
  const handlers = [];
  const applied = [];
  let last = null;
  let finished = false;
  const handlerFor = (i) => {
    if (!handlers[i]) handlers[i] = resolve(spec.tracks[i].kind);
    return handlers[i];
  };
  const finish = (completed) => {
    if (finished) return;
    finished = true;
    spec.tracks.forEach((track, i) => {
      const h = handlerFor(i);
      if (h && h.stop) safe(() => h.stop(ctx, track, completed));
    });
  };
  return {
    id,
    spec,
    ctx,
    /** Advances to `now`; false once the playback has ended. */
    update(now) {
      if (finished) return false;
      const elapsed = now - startAt;
      if (elapsed < 0) return true;
      const at = Math.min(elapsed, spec.duration);
      ctx.elapsed = at;
      if (last === null) {
        const due = [];
        const cutoff = at - LateTolerance;
        spec.tracks.forEach((track, i) => {
          const h = handlerFor(i);
          if (!h || h.mode !== 'Events') return;
          for (const key of track.keys) {
            if (key.t > at) break;
            if (key.t >= cutoff || key.persist || track.persist) due.push({ i, key });
          }
        });
        due.sort((a, b) => a.key.t - b.key.t || a.i - b.i);
        for (const d of due) {
          const h = handlerFor(d.i);
          if (h.fire) safe(() => h.fire(ctx, spec.tracks[d.i], d.key, Math.max(0, elapsed - d.key.t)));
        }
      }
      spec.tracks.forEach((track, i) => {
        const h = handlerFor(i);
        if (!h) return;
        if (h.mode === 'Events') {
          if (last !== null && h.fire) {
            for (const key of keysBetween(track, last, at)) safe(() => h.fire(ctx, track, key, Math.max(0, elapsed - key.t)));
          }
        } else {
          const value = sampleTrack(track, at);
          if (value !== undefined && h.apply && applied[i] !== value) {
            applied[i] = value;
            safe(() => h.apply(ctx, track, value));
          }
        }
      });
      last = at;
      if (elapsed >= spec.duration) {
        finish(true);
        return false;
      }
      return true;
    },
    stop() {
      finish(false);
    },
    isFinished() {
      return finished;
    },
  };
}

function safe(fn) {
  try {
    fn();
  } catch (err) {
    console.error('[timeline] handler failed', err);
  }
}

/**
 * Runs playbacks against a clock (SequenceController): play(spec, id, startAt, args) starts one; update(now) drives
 * every live playback; handlers are registered per kind.
 */
export class Sequencer {
  constructor() {
    /** @type {Map<string, TrackHandler>} */
    this.handlers = new Map();
    /** @type {Map<string, Spec>} */
    this.specs = new Map();
    /** @type {Set<ReturnType<typeof play>>} */
    this.live = new Set();
  }

  /** @param {string} kind @param {TrackHandler} handler */
  register(kind, handler) {
    this.handlers.set(kind, handler);
  }

  /** @param {Record<string, Spec>} specs */
  addSpecs(specs) {
    for (const [id, spec] of Object.entries(specs)) this.specs.set(id, spec);
  }

  /** Starts the registered timeline `id` at `startAt` with `args`; returns the playback (or null). */
  play(id, startAt, args = {}) {
    const spec = this.specs.get(id);
    if (!spec) {
      console.warn('[timeline] unknown timeline', id);
      return null;
    }
    const p = play(spec, id, startAt, (kind) => this.handlers.get(kind), args);
    this.live.add(p);
    return p;
  }

  update(now) {
    for (const p of this.live) if (!p.update(now)) this.live.delete(p);
  }

  /** Stops every live playback (run reset). */
  stopAll() {
    for (const p of this.live) p.stop();
    this.live.clear();
  }
}
