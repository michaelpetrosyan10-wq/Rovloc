// Shared helpers for the game layer (the web port of Shared/Util: Signal, Trove, MathUtil, LevelKit's schedule, the
// CFrame maths the Luau services use). Pure: no engine, no DOM. Roblox conventions throughout: studs, Y up, yaw 0
// looks down -Z, a CFrame travels as its 12 GetComponents() numbers [x, y, z, R00 .. R22].

import * as THREE from 'three';

// ---------------------------------------------------------------------------------------------------------------
// Signal / Trove
// ---------------------------------------------------------------------------------------------------------------

/** An immediate-fire signal. A handler that throws is logged and does not stop the others. @template {any[]} T */
export class Signal {
  constructor() {
    /** @type {Array<(...args: T) => void>} */
    this.handlers = [];
  }

  /** @param {(...args: T) => void} fn @returns {() => void} */
  connect(fn) {
    this.handlers.push(fn);
    return () => {
      const i = this.handlers.indexOf(fn);
      if (i >= 0) this.handlers.splice(i, 1);
    };
  }

  /** @param {(...args: T) => void} fn */
  once(fn) {
    const off = this.connect((...args) => {
      off();
      fn(...args);
    });
    return off;
  }

  /** @param {T} args */
  fire(...args) {
    for (const fn of this.handlers.slice()) {
      try {
        fn(...args);
      } catch (err) {
        console.error('[game] signal handler failed', err);
      }
    }
  }

  clear() {
    this.handlers.length = 0;
  }
}

/** Cleanup bag (Trove.luau): functions run in reverse order on clean(). */
export class Trove {
  constructor() {
    /** @type {Array<() => void>} */
    this.items = [];
  }

  /** @param {(() => void)|null|undefined} fn @returns {() => void} */
  add(fn) {
    if (typeof fn === 'function') this.items.push(fn);
    return fn;
  }

  clean() {
    const items = this.items;
    this.items = [];
    for (let i = items.length - 1; i >= 0; i--) {
      try {
        items[i]();
      } catch (err) {
        console.error('[game] cleanup failed', err);
      }
    }
  }
}

/**
 * A time-ordered list of callbacks run against a clock (LevelKit.newSchedule): entries due together run in the
 * order they were added; entries added by a running entry run in the same pass when already due.
 */
export class Schedule {
  constructor() {
    /** @type {Array<{at: number, order: number, name: string, fn: () => void}>} */
    this.entries = [];
    this.counter = 0;
  }

  /** @param {number} at @param {string} name @param {() => void} fn */
  at(at, name, fn) {
    this.entries.push({ at, order: ++this.counter, name, fn });
  }

  /** Runs every entry due at `now`; returns how many ran. */
  run(now) {
    let ran = 0;
    for (;;) {
      let best = -1;
      for (let i = 0; i < this.entries.length; i++) {
        const e = this.entries[i];
        if (e.at > now) continue;
        const b = best >= 0 ? this.entries[best] : null;
        if (!b || e.at < b.at || (e.at === b.at && e.order < b.order)) best = i;
      }
      if (best < 0) return ran;
      const entry = this.entries.splice(best, 1)[0];
      ran++;
      try {
        entry.fn();
      } catch (err) {
        console.error('[game] scheduled', entry.name, 'failed', err);
      }
    }
  }

  clear() {
    this.entries.length = 0;
  }

  isEmpty() {
    return this.entries.length === 0;
  }

  /** Names of the pending entries in time order. */
  pending() {
    return this.entries.slice().sort((a, b) => a.at - b.at || a.order - b.order).map((e) => e.name);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Numbers
// ---------------------------------------------------------------------------------------------------------------

export const clamp = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);
export const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
export const lerp = (a, b, t) => a + (b - a) * t;
export const rad = (d) => (d * Math.PI) / 180;
export const deg = (r) => (r * 180) / Math.PI;
export function smoothstep(e0, e1, v) {
  const t = clamp01(e0 === e1 ? 0 : (v - e0) / (e1 - e0));
  return t * t * (3 - 2 * t);
}
export function approach(cur, target, maxDelta) {
  return cur < target ? Math.min(cur + maxDelta, target) : Math.max(cur - maxDelta, target);
}
/** Frame-rate independent share of the remaining distance to cover this step. */
export const damp = (speed, dt) => 1 - Math.exp(-speed * dt);
export function wrapAngle(r) {
  const t = Math.PI * 2;
  return ((((r + Math.PI) % t) + t) % t) - Math.PI;
}
export function isFiniteNumber(v) {
  return typeof v === 'number' && Number.isFinite(v);
}
export function horizontalDistance(a, b) {
  return Math.hypot(a.x - b.x, a.z - b.z);
}
/** "m:ss" (Strings.formatTime). */
export function formatTime(seconds) {
  const total = Math.max(0, Math.floor(seconds));
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
}

// ---------------------------------------------------------------------------------------------------------------
// Seeded randomness: two generators, as on Roblox
//   Rng (xoshiro128** seeded by SplitMix32): the world's, a bit-for-bit port of Shared/Util/Rng.luau. worldData's port
//     of RunDirector draws from Rng.seeded(seed, key) and shuffle, so a run seed picks the same objective spots, traps,
//     flasks, batteries, grate locks and exits as the export and a live Roblox server. web/tools/data-test.mjs pins
//     its golden values (the same as tests/Specs/Rng.spec.luau) and replays RunDirector's plans against the export's.
//   seededRandom (mulberry32): the runtime's own streams (pacing, beats, spawns, fake-outs), as MathUtil.seededRandom
//     (the engine's Random) is the Roblox runtime's: deterministic per seed, but not the same numbers as Roblox's.
// ---------------------------------------------------------------------------------------------------------------

const UTF8 = new TextEncoder();

/** MathUtil.hash: 32-bit FNV-1a of a string's UTF-8 bytes (Luau strings are bytes). */
export function hash(text) {
  let h = 0x811c9dc5;
  for (const byte of UTF8.encode(text)) {
    h ^= byte;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

/** The murmur3 finaliser (Rng.luau fmix32). */
function fmix32(x) {
  let t = Math.imul(x ^ (x >>> 16), 0x85ebca6b);
  t = Math.imul(t ^ (t >>> 13), 0xc2b2ae35);
  return (t ^ (t >>> 16)) >>> 0;
}

/** rotl on 32 bits. */
function rotl(x, k) {
  return (x << k) | (x >>> (32 - k));
}

/**
 * The world's seeded stream (Shared/Util/Rng.luau, bit for bit): `number()` is one 32-bit draw / 2^32, `integer(min,
 * max)` takes integer bounds (at most 2^32 values) and redraws a draw at or past the last whole multiple of the range
 * below 2^32, then min + draw % range (Rng:NextInteger), so `integer(0, n - 1)` draws what NextInteger(1, n) draws.
 */
export class Rng {
  /** @param {number} seed a finite number (its floor, mod 2^32) */
  constructor(seed) {
    if (!Number.isFinite(seed)) throw new Error(`Rng needs a finite seed, got ${seed}`);
    let weyl = Math.floor(seed) >>> 0;
    this.s = new Uint32Array(4);
    for (let i = 0; i < 4; i++) {
      weyl = (weyl + 0x9e3779b9) >>> 0;
      this.s[i] = fmix32(weyl);
    }
  }

  /** Rng.seeded: the stream of (seed, key), floor(seed) mod 2^32 xor hash(key). */
  static seeded(seed, key) {
    if (!Number.isFinite(seed)) throw new Error(`Rng.seeded needs a finite seed, got ${seed}`);
    return new Rng(((Math.floor(seed) >>> 0) ^ hash(key)) >>> 0);
  }

  /** One xoshiro128** step: the next 32-bit output in [0, 2^32). */
  nextU32() {
    const s = this.s;
    const s1 = s[1];
    const result = Math.imul(rotl(Math.imul(s1, 5), 7), 9) >>> 0;
    const t = s1 << 9;
    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];
    s[2] ^= t;
    s[3] = rotl(s[3], 11);
    return result;
  }

  /** NextNumber(): [0, 1). */
  next() {
    return this.nextU32() / 4294967296;
  }

  /** NextNumber(min, max): min + (max - min) * next(). */
  number(min = 0, max = 1) {
    return min + (max - min) * this.next();
  }

  /** NextInteger(min, max): uniform over the integers min..max. */
  integer(min, max) {
    const range = max - min + 1;
    if (!(Number.isInteger(min) && Number.isInteger(max) && range >= 1 && range <= 4294967296)) {
      throw new Error(`Rng.integer(${min}, ${max}) needs integer bounds, min <= max, at most 2^32 values`);
    }
    const limit = 4294967296 - (4294967296 % range);
    let draw = this.nextU32();
    while (draw >= limit) draw = this.nextU32();
    return min + (draw % range);
  }

  /** A random element of a non-empty list. */
  pick(list) {
    return list[this.integer(0, list.length - 1)];
  }
}

/** The runtime's stream (mulberry32), with the Rng shape. */
class RuntimeRandom {
  /** @param {number} seed */
  constructor(seed) {
    this.state = Math.floor(seed) >>> 0 || 0x9e3779b9;
  }

  /** Uniform [0, 1). */
  next() {
    let t = (this.state = (this.state + 0x6d2b79f5) >>> 0);
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }

  /** NextNumber(min, max): [min, max). */
  number(min = 0, max = 1) {
    return min + (max - min) * this.next();
  }

  /** NextInteger(min, max): inclusive. */
  integer(min, max) {
    return min + Math.floor(this.next() * (max - min + 1));
  }

  /** A random element of a non-empty list. */
  pick(list) {
    return list[this.integer(0, list.length - 1)];
  }
}

/** A runtime stream unique to (seed, key) (MathUtil.seededRandom's role: pacing, beats, spawns). */
export function seededRandom(seed, key) {
  return new RuntimeRandom(((Math.floor(seed) >>> 0) ^ hash(key)) >>> 0);
}

/** Fisher-Yates in place (Rng.shuffle: i from the last index down to 1 swaps with integer(0, i)). */
export function shuffle(list, rng) {
  for (let i = list.length - 1; i > 0; i--) {
    const j = rng.integer(0, i);
    const t = list[i];
    list[i] = list[j];
    list[j] = t;
  }
  return list;
}

// ---------------------------------------------------------------------------------------------------------------
// CFrames (Roblox components <-> THREE)
// ---------------------------------------------------------------------------------------------------------------

/**
 * @typedef {number[]} CFrameArray 12 numbers: x, y, z, R00, R01, R02, R10, R11, R12, R20, R21, R22
 */

/** A CFrame array as a Matrix4. @param {CFrameArray} c */
export function cfMatrix(c, out = new THREE.Matrix4()) {
  return out.set(c[3], c[4], c[5], c[0], c[6], c[7], c[8], c[1], c[9], c[10], c[11], c[2], 0, 0, 0, 1);
}

/** The position of a CFrame array. */
export function cfPos(c, out = new THREE.Vector3()) {
  return out.set(c[0], c[1], c[2]);
}

/** CFrame.LookVector of a CFrame array (its -Z column). */
export function cfLook(c, out = new THREE.Vector3()) {
  return out.set(-c[5], -c[8], -c[11]);
}

/** CFrame.RightVector of a CFrame array (its X column). */
export function cfRight(c, out = new THREE.Vector3()) {
  return out.set(c[3], c[6], c[9]);
}

/** The 12 components of a Matrix4. */
export function matrixToCf(m) {
  const e = m.elements;
  return [e[12], e[13], e[14], e[0], e[4], e[8], e[1], e[5], e[9], e[2], e[6], e[10]];
}

/** cf:PointToObjectSpace(p) for a CFrame array (rotation is orthonormal: R^T (p - origin)). */
export function pointToObjectSpace(c, p, out = new THREE.Vector3()) {
  const dx = p.x - c[0];
  const dy = p.y - c[1];
  const dz = p.z - c[2];
  return out.set(c[3] * dx + c[6] * dy + c[9] * dz, c[4] * dx + c[7] * dy + c[10] * dz, c[5] * dx + c[8] * dy + c[11] * dz);
}

/** cf:PointToWorldSpace(local) for a CFrame array. */
export function pointToWorldSpace(c, l, out = new THREE.Vector3()) {
  return out.set(
    c[0] + c[3] * l.x + c[4] * l.y + c[5] * l.z,
    c[1] + c[6] * l.x + c[7] * l.y + c[8] * l.z,
    c[2] + c[9] * l.x + c[10] * l.y + c[11] * l.z,
  );
}

const _local = new THREE.Vector3();
/** Point-in-oriented-box (ZoneService: volume.CFrame:PointToObjectSpace(p) against Size / 2, with padding). */
export function inVolume(cframe, size, p, pad = 0) {
  pointToObjectSpace(cframe, p, _local);
  return Math.abs(_local.x) <= size[0] / 2 + pad && Math.abs(_local.y) <= size[1] / 2 + pad &&
    Math.abs(_local.z) <= size[2] / 2 + pad;
}

/** An exported list as an array (an empty Luau table serialises as {}). */
export function list(value) {
  return Array.isArray(value) ? value : [];
}

/** Yaw (radians, 0 = -Z) of a direction. */
export function yawOf(dir) {
  return Math.atan2(-dir.x, -dir.z);
}

/** A Matrix4 at `pos` facing yaw / pitch (CFrame.new(p) * CFrame.fromOrientation(pitch, yaw, 0)). */
export function frameAt(pos, yaw, pitch = 0, out = new THREE.Matrix4()) {
  _e.set(pitch, yaw, 0, 'YXZ');
  out.makeRotationFromEuler(_e);
  return out.setPosition(pos);
}
const _e = new THREE.Euler();

/** CFrame.lookAt(eye, target) as a Matrix4 (its -Z axis points at the target). */
export function lookAtMatrix(eye, target, out = new THREE.Matrix4()) {
  _dir.subVectors(target, eye);
  if (_dir.lengthSq() < 1e-8) return out.makeTranslation(eye.x, eye.y, eye.z);
  _dir.normalize();
  const yaw = Math.atan2(-_dir.x, -_dir.z);
  const pitch = Math.asin(clamp(_dir.y, -1, 1));
  return frameAt(eye, yaw, pitch, out);
}
const _dir = new THREE.Vector3();

/** Linear interpolation of two rigid frames (position lerp, rotation slerp) like CFrame:Lerp. */
export function lerpFrame(a, b, t, out = new THREE.Matrix4()) {
  a.decompose(_pa, _qa, _s);
  b.decompose(_pb, _qb, _s);
  _pa.lerp(_pb, t);
  _qa.slerp(_qb, t);
  return out.compose(_pa, _qa, _one);
}
const _pa = new THREE.Vector3();
const _pb = new THREE.Vector3();
const _qa = new THREE.Quaternion();
const _qb = new THREE.Quaternion();
const _s = new THREE.Vector3();
const _one = new THREE.Vector3(1, 1, 1);

/** Vector3 from an array or {x,y,z}. */
export function vec(v, out = new THREE.Vector3()) {
  if (Array.isArray(v)) return out.set(v[0], v[1], v[2]);
  return out.set(v.x, v.y, v.z);
}

export { THREE };
