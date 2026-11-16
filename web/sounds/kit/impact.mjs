// impact.mjs: unit(), the scale every recipe layer is brought to (unit peak) before it is mixed at its own dB, so a
// recipe reads as a balance of parts.

import { peak, gain } from './mix.mjs';

/**
 * Scales a buffer to unit peak in place (a silent buffer stays silent).
 * @param {Float32Array} buf
 */
export function unit(buf) {
  const p = peak(buf);
  return p > 0 ? gain(buf, 1 / p) : buf;
}
