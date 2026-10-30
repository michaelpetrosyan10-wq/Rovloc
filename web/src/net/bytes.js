// bytes.js: the little big-endian binary writer / reader the packets and the relay batches are built with, and the
// wrapping 16-bit sequence comparison.

const ENCODER = new TextEncoder();
const DECODER = new TextDecoder();

/** Little binary writer (growable). */
export class Writer {
  constructor(size = 256) {
    this.buf = new Uint8Array(size);
    this.view = new DataView(this.buf.buffer);
    this.n = 0;
  }

  _need(k) {
    if (this.n + k <= this.buf.length) return;
    const next = new Uint8Array(Math.max(this.buf.length * 2, this.n + k));
    next.set(this.buf.subarray(0, this.n));
    this.buf = next;
    this.view = new DataView(next.buffer);
  }

  u8(v) {
    this._need(1);
    this.view.setUint8(this.n, v);
    this.n += 1;
  }

  u16(v) {
    this._need(2);
    this.view.setUint16(this.n, v);
    this.n += 2;
  }

  u32(v) {
    this._need(4);
    this.view.setUint32(this.n, v);
    this.n += 4;
  }

  bytes(b) {
    this._need(b.length);
    this.buf.set(b, this.n);
    this.n += b.length;
  }

  /** A string of at most 255 UTF-8 bytes, length-prefixed. */
  str8(s) {
    const b = ENCODER.encode(s);
    this.u8(b.length);
    this.bytes(b);
  }

  /** Bytes with a 16-bit length prefix. */
  blob16(b) {
    this.u16(b.length);
    this.bytes(b);
  }

  done() {
    return this.buf.slice(0, this.n);
  }
}

/** The matching reader; throws RangeError on a short buffer. */
export class Reader {
  /** @param {Uint8Array} bytes */
  constructor(bytes) {
    this.buf = bytes;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    this.n = 0;
  }

  u8() {
    const v = this.view.getUint8(this.n);
    this.n += 1;
    return v;
  }

  u16() {
    const v = this.view.getUint16(this.n);
    this.n += 2;
    return v;
  }

  u32() {
    const v = this.view.getUint32(this.n);
    this.n += 4;
    return v;
  }

  bytes(k) {
    if (this.n + k > this.buf.length) throw new RangeError('short buffer');
    const b = this.buf.subarray(this.n, this.n + k);
    this.n += k;
    return b;
  }

  str8() {
    return DECODER.decode(this.bytes(this.u8()));
  }

  blob16() {
    return this.bytes(this.u16());
  }

  left() {
    return this.buf.length - this.n;
  }
}

/** Sequence numbers wrap at 2^16: a is newer than b. */
export function seqNewer(a, b) {
  const d = (a - b) & 0xffff;
  return d !== 0 && d < 0x8000;
}
