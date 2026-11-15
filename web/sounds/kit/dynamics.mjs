// dynamics.mjs: the look-ahead peak limiter every render ends in. Offline, the limiter can see the future: the gain it
// needs at each sample is the ceiling over the largest (4x oversampled, so inter-sample peaks count) peak within the
// next `lookahead`; that need is smoothed by a ramp down over the look-ahead (no instant gain steps: no clicks) and
// an exponential recovery over `release`. Channels share one gain (the image never shifts). A gain that moves
// reshapes the waveform between samples, so a pass can leave an inter-sample overshoot of a few tenths of a dB:
// limit() runs passes until the true peak is under the ceiling.

import { upsample, saturate } from './shape.mjs';
import { truePeak, momentaryMax } from './loudness.mjs';
import { peak } from './mix.mjs';

/**
 * Limits channels in place so no (true) peak passes `ceilingDb`. Returns the deepest gain reduction in dB (0 when
 * nothing was touched).
 * @param {Float32Array[]} channels
 * @param {number} sr
 * @param {{ceilingDb?: number, lookahead?: number, release?: number}} [spec]
 */
export function limit(channels, sr, { ceilingDb = -1, lookahead = 0.002, release = 0.08 } = {}) {
  let total = 0;
  let aim = ceilingDb;
  for (let pass = 0; pass < 8; pass++) {
    total = Math.max(total, limitPass(channels, sr, aim, lookahead, release));
    const over = truePeak(channels) - ceilingDb;
    if (over <= 0) break;
    // the next pass aims under the ceiling by what this one left over
    aim -= over + 0.02;
  }
  return total;
}

/**
 * One pass of the limiter (see limit()).
 * @param {Float32Array[]} channels
 * @param {number} sr
 * @param {number} ceilingDb
 * @param {number} lookahead
 * @param {number} release
 */
function limitPass(channels, sr, ceilingDb, lookahead, release) {
  const n = channels[0].length;
  const ceiling = 10 ** (ceilingDb / 20);
  // the (true) peak envelope per sample
  const env = new Float32Array(n);
  for (const c of channels) {
    const up = upsample(c, 4);
    const delay = 96; // the up filter's half length (48 * 4 + 1 taps) in high-rate samples
    for (let i = 0; i < n; i++) {
      let m = Math.abs(c[i]);
      for (let k = 0; k < 4; k++) {
        const j = i * 4 + k + delay;
        if (j < up.length) m = Math.max(m, Math.abs(up[j]));
      }
      env[i] = Math.max(env[i], m);
    }
  }
  // the gain each sample needs, then the minimum over the look-ahead window (a running minimum, backwards)
  const need = new Float32Array(n);
  for (let i = 0; i < n; i++) need[i] = env[i] > ceiling ? ceiling / env[i] : 1;
  const L = Math.max(1, Math.round(lookahead * sr));
  const ahead = new Float32Array(n);
  // monotonic deque for the sliding minimum of need[i .. i + L]
  const dq = new Int32Array(n + 1);
  let head = 0;
  let tail = 0;
  for (let i = n - 1; i >= 0; i--) {
    while (tail > head && need[dq[tail - 1]] >= need[i]) tail--;
    dq[tail++] = i;
    while (dq[head] > i + L) head++;
    ahead[i] = need[dq[head]];
  }
  // smooth: the gain falls linearly toward a coming need over L samples (never later than the peak) and recovers
  // exponentially
  const rel = Math.exp(-1 / Math.max(1, release * sr));
  const gainTrack = new Float32Array(n);
  let g = 1;
  for (let i = 0; i < n; i++) {
    const target = ahead[i];
    if (target < g) g = Math.max(target, g - (1 - target) / L);
    else g = target + (g - target) * rel;
    gainTrack[i] = Math.min(g, need[i]);
  }
  let deepest = 1;
  for (const c of channels) for (let i = 0; i < n; i++) c[i] *= gainTrack[i];
  for (let i = 0; i < n; i++) deepest = Math.min(deepest, gainTrack[i]);
  return deepest < 1 ? -20 * Math.log10(deepest) : 0;
}

/**
 * Weight by density: drives a sound into an oversampled tanh, harder step by step, until its peak-to-loudness ratio
 * (true peak over the loudest 400 ms, dB) is at most `plr`, so it reaches its loudness without leaning on the limiter.
 * An impact is mostly peak; a heavy one's body has to fill in under the peak, the way a big thing's does. Returns a
 * unit-peak copy (the gentlest drive that gets there, or the hardest tried).
 * @param {Float32Array} input
 * @param {number} sr
 * @param {number} plr dB
 * @param {number[]} [drives]
 */
export function densify(input, sr, plr, drives = [1, 1.6, 2.2, 3, 4, 5.2, 6.6, 8.4]) {
  let out = input;
  for (const drive of drives) {
    const p = peak(input);
    const x = Float32Array.from(input);
    if (p > 0) for (let i = 0; i < x.length; i++) x[i] /= p;
    out = drive > 1 ? saturate(x, { drive, curve: 'tanh', factor: 4 }) : x;
    const q = peak(out);
    if (q > 0) for (let i = 0; i < out.length; i++) out[i] /= q;
    if (truePeak([out]) - momentaryMax([out], sr) <= plr) return out;
  }
  return out;
}
