// delay.mjs: the delay line the rooms are built on (reverb.mjs: the feedback delay network of the game's spaces).

/** A circular delay line with linearly interpolated fractional reads. */
export class DelayLine {
  /** @param {number} capacity samples */
  constructor(capacity) {
    this.buf = new Float64Array(Math.max(4, Math.ceil(capacity) + 4));
    this.at = 0;
  }

  /** Writes one sample. */
  write(x) {
    this.buf[this.at] = x;
    this.at = (this.at + 1) % this.buf.length;
  }

  /** The sample written `delay` samples ago (fractional; >= 1). */
  read(delay) {
    const n = this.buf.length;
    const d = Math.min(Math.max(delay, 1), n - 2);
    const pos = this.at - d;
    const i = Math.floor(pos);
    const frac = pos - i;
    const a = this.buf[((i % n) + n) % n];
    const b = this.buf[(((i + 1) % n) + n) % n];
    return a + (b - a) * frac;
  }
}
