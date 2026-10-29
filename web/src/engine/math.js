// Numeric helpers ported from Shared/Util/MathUtil.luau and Spring.luau, plus the engine shims the Luau code relied
// on: math.noise (improved Perlin), Random (a seeded stream) and Roblox CFrame conversions.
//
// Conventions match the Roblox code: yaw 0 looks down -Z, pitch up is positive, angles are radians unless a name
// says degrees. A Roblox CFrame travels as its 12 GetComponents() numbers
// [x, y, z, R00, R01, R02, R10, R11, R12, R20, R21, R22]; three.js is also right-handed and Y-up, so positions and
// rotation matrices are used as they are.

import * as THREE from 'three';

export const TAU = Math.PI * 2;

/** @param {number} a @param {number} b @param {number} t */
export const lerp = (a, b, t) => a + (b - a) * t;
/** @param {number} v @param {number} lo @param {number} hi */
export const clamp = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);
/** @param {number} v */
export const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
export const rad = (deg) => (deg * Math.PI) / 180;
export const deg = (r) => (r * 180) / Math.PI;

export function inverseLerp(a, b, value) {
  return a === b ? 0 : (value - a) / (b - a);
}
export function remapClamped(value, inMin, inMax, outMin, outMax) {
  return lerp(outMin, outMax, clamp01(inverseLerp(inMin, inMax, value)));
}
export function smoothstep(edge0, edge1, value) {
  const t = clamp01(inverseLerp(edge0, edge1, value));
  return t * t * (3 - 2 * t);
}
/** Frame-rate independent exponential approach: the share of the remaining distance to cover this frame. */
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
export function wrapAngle(radians) {
  const wrapped = (((radians + Math.PI) % TAU) + TAU) % TAU;
  return wrapped - Math.PI;
}
export function angleDelta(from, to) {
  return wrapAngle(to - from);
}
export function isFiniteNumber(v) {
  return typeof v === 'number' && Number.isFinite(v);
}
export function horizontalDistance(a, b) {
  const dx = a.x - b.x;
  const dz = a.z - b.z;
  return Math.sqrt(dx * dx + dz * dz);
}

/** Yaw and pitch (radians) of a look direction. Yaw 0 looks down -Z (CFrame.lookAt convention). */
export function yawPitchFromVector(direction) {
  const len = Math.hypot(direction.x, direction.y, direction.z);
  const x = len > 1e-6 ? direction.x / len : 0;
  const y = len > 1e-6 ? direction.y / len : 0;
  const z = len > 1e-6 ? direction.z / len : -1;
  return { yaw: Math.atan2(-x, -z), pitch: Math.asin(clamp(y, -1, 1)) };
}

/** Unit look vector for a yaw / pitch. */
export function vectorFromYawPitch(yaw, pitch, out = new THREE.Vector3()) {
  const cp = Math.cos(pitch);
  return out.set(-Math.sin(yaw) * cp, Math.sin(pitch), -Math.cos(yaw) * cp);
}

// ---------------------------------------------------------------------------------------------------------------
// Hashing, seeded random streams, value noise
// ---------------------------------------------------------------------------------------------------------------

/** Exact 32-bit FNV-1a of a string (MathUtil.hash). */
export function hash(text) {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i) & 0xff;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

/** A seeded pseudo-random stream with the Roblox Random API (NextNumber / NextInteger). */
export class Random {
  /** @param {number} seed */
  constructor(seed) {
    this.state = (Math.floor(seed) >>> 0) || 0x9e3779b9;
  }
  /** Uniform [0, 1). */
  next() {
    // mulberry32
    let t = (this.state = (this.state + 0x6d2b79f5) >>> 0);
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }
  /** NextNumber() is [0, 1); NextNumber(min, max) is [min, max). */
  nextNumber(min = 0, max = 1) {
    return min + (max - min) * this.next();
  }
  /** Inclusive integer in [min, max]. */
  nextInteger(min, max) {
    return min + Math.floor(this.next() * (max - min + 1));
  }
}

/** A Random stream unique to (seed, key) (MathUtil.seededRandom). */
export function seededRandom(seed, key) {
  return new Random(((Math.floor(seed) >>> 0) ^ hash(key)) >>> 0);
}

// Improved Perlin noise (Ken Perlin's reference permutation), the function behind Roblox math.noise.
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
const fade = (t) => t * t * t * (t * (t * 6 - 15) + 10);
function grad(h, x, y, z) {
  const k = h & 15;
  const u = k < 8 ? x : y;
  const v = k < 4 ? y : k === 12 || k === 14 ? x : z;
  return ((k & 1) === 0 ? u : -u) + ((k & 2) === 0 ? v : -v);
}

/** math.noise(x, y, z): improved Perlin noise, 0 on integer lattice points. */
export function noise3(x, y = 0, z = 0) {
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

/** Smooth value noise in about [-1, 1] for flicker and sway (MathUtil.noise1). */
export function noise1(t, seed) {
  return noise3(t, seed * 0.137, 0.5) * 2;
}

// ---------------------------------------------------------------------------------------------------------------
// Springs (Spring.luau): analytic critically / under-damped steps, frame-rate independent
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

export class NumberSpring {
  constructor(initial, speed, damping) {
    this.position = initial;
    this.velocity = 0;
    this.target = initial;
    this.speed = speed;
    this.damping = damping;
  }
  step(dt) {
    const [o, v] = solveSpring(this.position - this.target, this.velocity, this.speed, this.damping, dt);
    this.position = this.target + o;
    this.velocity = v;
    return this.position;
  }
  reset(value) {
    this.position = value;
    this.target = value;
    this.velocity = 0;
  }
}

export class VectorSpring {
  constructor(initial, speed, damping) {
    this.position = initial.clone();
    this.velocity = new THREE.Vector3();
    this.target = initial.clone();
    this.speed = speed;
    this.damping = damping;
  }
  step(dt) {
    for (const axis of ['x', 'y', 'z']) {
      const [o, v] = solveSpring(this.position[axis] - this.target[axis], this.velocity[axis], this.speed,
        this.damping, dt);
      this.position[axis] = this.target[axis] + o;
      this.velocity[axis] = v;
    }
    return this.position;
  }
  reset(value) {
    this.position.copy(value);
    this.target.copy(value);
    this.velocity.set(0, 0, 0);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Roblox CFrame <-> three.js
// ---------------------------------------------------------------------------------------------------------------

/**
 * A Roblox CFrame as a THREE.Matrix4. Accepts a Matrix4 (cloned), the 12 GetComponents() numbers, or
 * { position: {x,y,z} | [x,y,z], yaw?: number, pitch?: number } (yaw 0 faces -Z).
 * @param {THREE.Matrix4 | number[] | {position: any, yaw?: number, pitch?: number}} value
 * @returns {THREE.Matrix4}
 */
export function toMatrix(value, out = new THREE.Matrix4()) {
  if (value instanceof THREE.Matrix4) return out.copy(value);
  if (Array.isArray(value) || ArrayBuffer.isView(value)) {
    const c = value;
    return out.set(c[3], c[4], c[5], c[0], c[6], c[7], c[8], c[1], c[9], c[10], c[11], c[2], 0, 0, 0, 1);
  }
  if (value && value.position) {
    const p = Array.isArray(value.position) ? { x: value.position[0], y: value.position[1], z: value.position[2] }
      : value.position;
    const e = new THREE.Euler(value.pitch || 0, value.yaw || 0, 0, 'YXZ');
    out.makeRotationFromEuler(e);
    out.setPosition(p.x, p.y, p.z);
    return out;
  }
  throw new Error('toMatrix: unsupported CFrame value');
}

/** The 12 Roblox components of a Matrix4. */
export function toComponents(m) {
  const e = m.elements;
  return [e[12], e[13], e[14], e[0], e[4], e[8], e[1], e[5], e[9], e[2], e[6], e[10]];
}

/** CFrame.LookVector of a matrix (its -Z axis). */
export function lookVector(m, out = new THREE.Vector3()) {
  const e = m.elements;
  return out.set(-e[8], -e[9], -e[10]).normalize();
}

/** A Matrix4 at `position` with yaw / pitch (radians) like CFrame.new(p) * CFrame.fromOrientation(pitch, yaw, 0). */
export function frameFromLook(position, yaw, pitch, out = new THREE.Matrix4()) {
  _euler.set(pitch, yaw, 0, 'YXZ');
  out.makeRotationFromEuler(_euler);
  out.setPosition(position);
  return out;
}
const _euler = new THREE.Euler();

/** Linear RGB [0..1] triple from a Roblox Color3.fromRGB array (or THREE.Color passthrough). */
export function color3(value, out = new THREE.Color()) {
  if (value instanceof THREE.Color) return out.copy(value);
  if (Array.isArray(value)) return out.setRGB(value[0] / 255, value[1] / 255, value[2] / 255, THREE.SRGBColorSpace);
  if (value && typeof value === 'object' && 'r' in value) return out.setRGB(value.r, value.g, value.b);
  return out.set(value);
}
