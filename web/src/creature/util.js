// Numeric helpers the Creature's Luau code relied on (Shared/Util/MathUtil, Spring, Signal, BinaryHeap) plus the
// engine shims: math.noise (improved Perlin), a seeded Random stream, and Vector3 helpers over THREE.Vector3.
// Pure: no engine access. Everything here is deterministic.

import * as THREE from 'three';

export const TAU = Math.PI * 2;
export const EPSILON = 1e-9;

/** @param {number} a @param {number} b @param {number} t */
export const lerp = (a, b, t) => a + (b - a) * t;
/** @param {number} v @param {number} lo @param {number} hi */
export const clamp = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);
/** @param {number} v */
export const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
/** @param {number} degrees */
export const rad = (degrees) => (degrees * Math.PI) / 180;
/** @param {number} radians */
export const deg = (radians) => (radians * 180) / Math.PI;

/** @param {number} a @param {number} b @param {number} value */
export function inverseLerp(a, b, value) {
  return a === b ? 0 : (value - a) / (b - a);
}

/** MathUtil.remapClamped. */
export function remapClamped(value, inMin, inMax, outMin, outMax) {
  return lerp(outMin, outMax, clamp01(inverseLerp(inMin, inMax, value)));
}

/** MathUtil.smoothstep (edges may run downward). */
export function smoothstep(edge0, edge1, value) {
  const t = clamp01(inverseLerp(edge0, edge1, value));
  return t * t * (3 - 2 * t);
}

/** Frame-rate independent exponential approach: the share of the remaining distance to cover this step. */
export function damp(speed, dt) {
  return 1 - Math.exp(-speed * dt);
}

export function dampNumber(current, target, speed, dt) {
  return lerp(current, target, damp(speed, dt));
}

/** Moves `current` toward `target` by at most `maxDelta`. */
export function approach(current, target, maxDelta) {
  return current < target ? Math.min(current + maxDelta, target) : Math.max(current - maxDelta, target);
}

/** Wraps an angle into [-pi, pi). */
export function wrapAngle(radians) {
  const wrapped = (((radians + Math.PI) % TAU) + TAU) % TAU;
  return wrapped - Math.PI;
}

export function angleDelta(from, to) {
  return wrapAngle(to - from);
}

/** @param {unknown} v */
export function isFiniteNumber(v) {
  return typeof v === 'number' && Number.isFinite(v);
}

/** @param {{x: number, y: number, z: number}|null|undefined} v */
export function isFiniteVector(v) {
  return !!v && Number.isFinite(v.x) && Number.isFinite(v.y) && Number.isFinite(v.z);
}

/** @param {THREE.Vector3} a @param {THREE.Vector3} b */
export function horizontalDistance(a, b) {
  const dx = a.x - b.x;
  const dz = a.z - b.z;
  return Math.sqrt(dx * dx + dz * dz);
}

/** MathUtil.flat: the horizontal part of `v` (a new vector). */
export function flat(v) {
  return new THREE.Vector3(v.x, 0, v.z);
}

/** CreatureBody.flatDirection: a horizontal unit direction, or null when `v` has no horizontal part. */
export function flatDirection(v) {
  const len = Math.hypot(v.x, v.z);
  if (len < 1e-4) return null;
  return new THREE.Vector3(v.x / len, 0, v.z / len);
}

/** Yaw / pitch of a direction (yaw 0 looks down -Z, CFrame.lookAt convention). */
export function yawPitchFromVector(direction) {
  const len = Math.hypot(direction.x, direction.y, direction.z);
  const x = len > 1e-6 ? direction.x / len : 0;
  const y = len > 1e-6 ? direction.y / len : 0;
  const z = len > 1e-6 ? direction.z / len : -1;
  return { yaw: Math.atan2(-x, -z), pitch: Math.asin(clamp(y, -1, 1)) };
}

/** A Vector3 from an [x, y, z] array (or a copy of a vector). */
export function vec(value) {
  if (Array.isArray(value) || ArrayBuffer.isView(value)) return new THREE.Vector3(value[0], value[1], value[2]);
  return new THREE.Vector3(value.x, value.y, value.z);
}

// ---------------------------------------------------------------------------------------------------------------
// Hashing, Random, noise
// ---------------------------------------------------------------------------------------------------------------

/** MathUtil.hash: 32-bit FNV-1a of a string. */
export function hashString(text) {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i) & 0xff;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

/** A seeded stream with the Roblox Random API (NextNumber / NextInteger), mulberry32. */
export class Random {
  /** @param {number} seed */
  constructor(seed) {
    this.state = (Math.floor(seed) >>> 0) || 0x9e3779b9;
  }

  /** Uniform [0, 1). */
  next() {
    this.state = (this.state + 0x6d2b79f5) >>> 0;
    let t = this.state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }

  /** NextNumber(): [0, 1); NextNumber(min, max): [min, max). */
  nextNumber(min = 0, max = 1) {
    return min + (max - min) * this.next();
  }

  /** Inclusive integer in [min, max]. */
  nextInteger(min, max) {
    return min + Math.floor(this.next() * (max - min + 1));
  }
}

/** MathUtil.seededRandom: a stream unique to (seed, key). */
export function seededRandom(seed, key) {
  return new Random(((Math.floor(seed) >>> 0) ^ hashString(key)) >>> 0);
}

const PERM = new Uint8Array(512);
{
  const p = [151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30, 69, 142, 8, 99,
    37, 240, 21, 10, 23, 190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32, 57, 177,
    33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175, 74, 165, 71, 134, 139, 48, 27, 166, 77, 146, 158,
    231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54, 65, 25, 63, 161,
    1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169, 200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198,
    173, 186, 3, 64, 52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212, 207, 206, 59, 227, 47,
    16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213, 119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43,
    172, 9, 129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246, 97, 228, 251, 34,
    242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199,
    106, 157, 184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205, 93, 222, 114, 67, 29, 24, 72, 243,
    141, 128, 195, 78, 66, 215, 61, 156, 180];
  for (let i = 0; i < 512; i++) PERM[i] = p[i & 255];
}

function fade(t) {
  return t * t * t * (t * (t * 6 - 15) + 10);
}

function grad(h, x, y, z) {
  const k = h & 15;
  const u = k < 8 ? x : y;
  const v = k < 4 ? y : k === 12 || k === 14 ? x : z;
  return ((k & 1) === 0 ? u : -u) + ((k & 2) === 0 ? v : -v);
}

/** math.noise(x, y, z): improved Perlin noise in about [-1, 1], 0 on integer lattice points. */
export function noise(x, y = 0, z = 0) {
  const X = Math.floor(x) & 255;
  const Y = Math.floor(y) & 255;
  const Z = Math.floor(z) & 255;
  x -= Math.floor(x);
  y -= Math.floor(y);
  z -= Math.floor(z);
  const u = fade(x);
  const v = fade(y);
  const w = fade(z);
  const A = PERM[X] + Y;
  const AA = PERM[A] + Z;
  const AB = PERM[A + 1] + Z;
  const B = PERM[X + 1] + Y;
  const BA = PERM[B] + Z;
  const BB = PERM[B + 1] + Z;
  return lerp(
    lerp(lerp(grad(PERM[AA], x, y, z), grad(PERM[BA], x - 1, y, z), u),
      lerp(grad(PERM[AB], x, y - 1, z), grad(PERM[BB], x - 1, y - 1, z), u), v),
    lerp(lerp(grad(PERM[AA + 1], x, y, z - 1), grad(PERM[BA + 1], x - 1, y, z - 1), u),
      lerp(grad(PERM[AB + 1], x, y - 1, z - 1), grad(PERM[BB + 1], x - 1, y - 1, z - 1), u), v),
    w,
  );
}

/** MathUtil.noise1: smooth value noise in [-1, 1]. */
export function noise1(t, seed) {
  return noise(t, seed * 0.137, 0.5) * 2;
}

// ---------------------------------------------------------------------------------------------------------------
// Springs (Shared/Util/Spring.luau)
// ---------------------------------------------------------------------------------------------------------------

function solveSpring(offset, velocity, speed, damping, dt) {
  if (speed <= 0) return [offset, velocity];
  const w = speed;
  if (damping >= 1) {
    const decay = Math.exp(-w * dt);
    const c1 = offset;
    const c2 = velocity + w * offset;
    return [(c1 + c2 * dt) * decay, (c2 - w * (c1 + c2 * dt)) * decay];
  }
  const wd = w * Math.sqrt(1 - damping * damping);
  const decay = Math.exp(-damping * w * dt);
  const cosT = Math.cos(wd * dt);
  const sinT = Math.sin(wd * dt);
  const c1 = offset;
  const c2 = (velocity + damping * w * offset) / wd;
  return [
    decay * (c1 * cosT + c2 * sinT),
    decay * ((c2 * wd - damping * w * c1) * cosT - (c1 * wd + damping * w * c2) * sinT),
  ];
}

/** A damped number spring (speed: angular frequency rad/s; damping 1 is critical). */
export class NumberSpring {
  constructor(initial, speed, damping) {
    this.position = initial;
    this.velocity = 0;
    this.target = initial;
    this.speed = speed;
    this.damping = damping;
  }

  step(dt) {
    const [offset, velocity] = solveSpring(this.position - this.target, this.velocity, this.speed, this.damping, dt);
    this.position = this.target + offset;
    this.velocity = velocity;
    return this.position;
  }

  impulse(velocity) {
    this.velocity += velocity;
  }

  reset(value) {
    this.position = value;
    this.target = value;
    this.velocity = 0;
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Signal, BinaryHeap
// ---------------------------------------------------------------------------------------------------------------

/** An immediate-fire signal (Shared/Util/Signal): handlers run in connection order; one throwing does not stop the rest. */
export class Signal {
  constructor() {
    /** @type {Array<Function>} */
    this.handlers = [];
  }

  /** @param {Function} fn @returns {() => void} disconnect */
  connect(fn) {
    this.handlers.push(fn);
    return () => {
      const i = this.handlers.indexOf(fn);
      if (i >= 0) this.handlers.splice(i, 1);
    };
  }

  fire(...args) {
    for (const fn of this.handlers.slice()) {
      try {
        fn(...args);
      } catch (err) {
        console.warn('[creature] signal handler failed', err);
      }
    }
  }

  clear() {
    this.handlers.length = 0;
  }
}

/**
 * A stable min-heap (Shared/Util/BinaryHeap): equal priorities pop in push order.
 * @template T
 */
export class BinaryHeap {
  constructor() {
    /** @type {Array<{value: T, priority: number, seq: number}>} */
    this.items = [];
    this.seq = 0;
  }

  size() {
    return this.items.length;
  }

  /** @param {T} value @param {number} priority */
  push(value, priority) {
    const items = this.items;
    items.push({ value, priority, seq: this.seq++ });
    let i = items.length - 1;
    while (i > 0) {
      const parent = (i - 1) >> 1;
      if (!before(items[i], items[parent])) break;
      [items[i], items[parent]] = [items[parent], items[i]];
      i = parent;
    }
  }

  /** @returns {T|undefined} */
  pop() {
    const items = this.items;
    if (items.length === 0) return undefined;
    const top = items[0];
    const last = items.pop();
    if (items.length > 0 && last) {
      items[0] = last;
      let i = 0;
      for (;;) {
        const l = i * 2 + 1;
        const r = l + 1;
        let s = i;
        if (l < items.length && before(items[l], items[s])) s = l;
        if (r < items.length && before(items[r], items[s])) s = r;
        if (s === i) break;
        [items[i], items[s]] = [items[s], items[i]];
        i = s;
      }
    }
    return top.value;
  }
}

function before(a, b) {
  return a.priority !== b.priority ? a.priority < b.priority : a.seq < b.seq;
}
