// rng.mjs: the only source of randomness in a render (Math.random is banned in web/sounds; test.mjs checks).
//
// Every voice variant starts from seedOf(name, variant). A render forks a child generator per layer (fork(label)), so
// a draw added to one layer never shifts the numbers another layer sees, and two variants differ in every layer.
// The generator is sfc32 seeded through splitmix32: fast, 128 bits of state, and the same numbers on every machine.

/**
 * A well-mixed 32-bit hash of a string (FNV-1a, then the murmur3 finalizer).
 * @param {string} text
 * @returns {number} an unsigned 32-bit integer
 */
export function hashString(text) {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  h ^= h >>> 16;
  h = Math.imul(h, 0x85ebca6b);
  h ^= h >>> 13;
  h = Math.imul(h, 0xc2b2ae35);
  h ^= h >>> 16;
  return h >>> 0;
}

/**
 * The seed of one rendered variant.
 * @param {string} name the sound's name
 * @param {number} variant 1-based variant number
 */
export function seedOf(name, variant) {
  return hashString(`${name}#${variant}`);
}

export class Rng {
  /** @param {number} seed any 32-bit integer */
  constructor(seed) {
    this.seed = seed >>> 0;
    let s = this.seed;
    const splitmix = () => {
      s = (s + 0x9e3779b9) >>> 0;
      let z = s;
      z = Math.imul(z ^ (z >>> 16), 0x85ebca6b);
      z = Math.imul(z ^ (z >>> 13), 0xc2b2ae35);
      return (z ^ (z >>> 16)) >>> 0;
    };
    this.a = splitmix();
    this.b = splitmix();
    this.c = splitmix();
    this.d = splitmix();
    /** @type {number|null} the second value of the last Box-Muller pair */
    this.spare = null;
    for (let i = 0; i < 12; i++) this.u32();
  }

  /** The next unsigned 32-bit integer (sfc32). */
  u32() {
    const t = (((this.a + this.b) >>> 0) + this.d) >>> 0;
    this.d = (this.d + 1) >>> 0;
    this.a = this.b ^ (this.b >>> 9);
    this.b = (this.c + (this.c << 3)) >>> 0;
    this.c = ((this.c << 21) | (this.c >>> 11)) >>> 0;
    this.c = (this.c + t) >>> 0;
    return t;
  }

  /** Uniform in [0, 1). */
  next() {
    return this.u32() / 4294967296;
  }

  /** Uniform in [lo, hi). */
  range(lo, hi) {
    return lo + (hi - lo) * this.next();
  }

  /** A uniform integer in [lo, hi] (both inclusive). */
  int(lo, hi) {
    return lo + Math.floor(this.next() * (hi - lo + 1));
  }

  /** Standard normal (Box-Muller, the pair's second value cached). */
  normal() {
    if (this.spare !== null) {
      const v = this.spare;
      this.spare = null;
      return v;
    }
    let u = 0;
    while (u <= 1e-12) u = this.next();
    const v = this.next();
    const r = Math.sqrt(-2 * Math.log(u));
    this.spare = r * Math.sin(2 * Math.PI * v);
    return r * Math.cos(2 * Math.PI * v);
  }

  /** True with probability p. */
  chance(p) {
    return this.next() < p;
  }

  /** -1 or 1. */
  sign() {
    return this.next() < 0.5 ? -1 : 1;
  }

  /**
   * One element of a list.
   * @template T
   * @param {readonly T[]} list
   * @returns {T}
   */
  pick(list) {
    return list[Math.floor(this.next() * list.length)];
  }

  /** `value` scattered by a fraction: value * (1 + U(-spread, spread)). */
  vary(value, spread) {
    return value * (1 + this.range(-spread, spread));
  }

  /**
   * A child generator for one part of a render: its numbers depend only on this seed and the label.
   * @param {string} label
   */
  fork(label) {
    return new Rng(hashString(`${this.seed}/${label}`));
  }
}
