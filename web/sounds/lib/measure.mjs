// measure.mjs: everything the audit reads off a render (docs/SOUND.md 3). Pure functions of samples.
//
//   bandShares    energy share per band: < 80, 80-250, 250-800, 800-2.5k, 2.5k-8k, > 8k Hz
//   centroid      the power-weighted mean frequency
//   tonality      over the sustain, above 110 Hz: the share of energy in the strongest twelfth-octave band (a beep
//                 is near 1) and the number of twelfth-octave peaks within 20 dB of the strongest
//   roughness     the envelope's modulation depth at 30-150 Hz (rms of that band of the envelope / its mean)
//   attack        10 % -> 90 % of the 1 ms RMS envelope's peak
//   crest, dc, clipped samples, silence at either end, a cut tail, the loop seam, variant difference,
//   his throat's rattle (the 18-38 Hz pulsing of a slowed voice), and the click at a contact (how much of the first
//   12 ms lies over 1.5 kHz: a dry click or a knock is bright there, a body landing is not)

import { welch, fft, nextPow2, hann } from '../kit/fft.mjs';
import { butter } from '../kit/filters.mjs';

export const BANDS = Object.freeze([
  ['<80', 0, 80], ['80-250', 80, 250], ['250-800', 250, 800], ['800-2.5k', 800, 2500], ['2.5k-8k', 2500, 8000], ['>8k', 8000, 24000],
]);

/** A mono mix of channels. */
export function mono(channels) {
  if (channels.length === 1) return channels[0];
  const out = new Float32Array(channels[0].length);
  for (const c of channels) for (let i = 0; i < out.length; i++) out[i] += c[i] / channels.length;
  return out;
}

/**
 * The power spectrum of [from, to) with a Hann window over exactly that segment, zero-padded to `size`.
 * @param {Float32Array} x
 * @param {number} from
 * @param {number} to
 * @param {number} size
 */
export function segmentPower(x, from, to, size) {
  const len = Math.min(size, to - from);
  const w = hann(len);
  const re = new Float64Array(size);
  const im = new Float64Array(size);
  for (let i = 0; i < len; i++) re[i] = x[from + i] * w[i];
  fft(re, im);
  const out = new Float64Array(size / 2 + 1);
  for (let k = 0; k <= size / 2; k++) out[k] = re[k] * re[k] + im[k] * im[k];
  return out;
}

/** The power spectrum of a whole sound (Welch for long ones), bins of sr / size. */
export function spectrumOf(x, sr) {
  const size = 8192;
  if (x.length < size * 2) return { power: segmentPower(x, 0, x.length, nextPow2(Math.max(x.length, 4096))), size: nextPow2(Math.max(x.length, 4096)) };
  return { power: welch(x, size), size };
}

/** @param {Float32Array} x @param {number} sr */
export function bandShares(x, sr) {
  const { power, size } = spectrumOf(x, sr);
  const shares = BANDS.map(() => 0);
  let total = 0;
  for (let k = 1; k < power.length; k++) {
    const f = (k * sr) / size;
    if (f < 20) continue;
    total += power[k];
    const b = BANDS.findIndex(([, lo, hi]) => f >= lo && f < hi);
    if (b >= 0) shares[b] += power[k];
  }
  return shares.map((s) => (total > 0 ? s / total : 0));
}

/** @param {Float32Array} x @param {number} sr */
export function centroid(x, sr) {
  const { power, size } = spectrumOf(x, sr);
  let num = 0;
  let den = 0;
  for (let k = 1; k < power.length; k++) {
    const f = (k * sr) / size;
    if (f < 20 || f > 20000) continue;
    num += f * power[k];
    den += power[k];
  }
  return den > 0 ? num / den : 0;
}

/**
 * The 1 ms RMS envelope (one value per sample, centred).
 * @param {Float32Array} x
 * @param {number} sr
 * @param {number} [seconds]
 */
export function rmsEnvelope(x, sr, seconds = 0.001) {
  const w = Math.max(1, Math.round(seconds * sr));
  const out = new Float32Array(x.length);
  let s = 0;
  const half = Math.floor(w / 2);
  for (let i = 0; i < x.length + half; i++) {
    if (i < x.length) s += x[i] * x[i];
    if (i - w >= 0) s -= x[i - w] * x[i - w];
    const j = i - half;
    if (j >= 0 && j < x.length) out[j] = Math.sqrt(Math.max(0, s) / w);
  }
  return out;
}

/**
 * Onset (the first sample at 10 % of the envelope's peak), the peak's index, and the attack: the 10-90 % rise of the
 * FIRST strong transient (the first local maximum of the 1 ms envelope, over +-3 ms, that reaches 20 % of the peak).
 * A heel before the weight, or a crack before the boom, is its own transient: the attack is how sharply the sound
 * starts, not how long until its loudest moment. The rise is that: 10 % to 90 % of the loudest 10 ms.
 */
export function attack(x, sr) {
  const env = rmsEnvelope(x, sr);
  let max = 0;
  let at = 0;
  for (let i = 0; i < env.length; i++) {
    if (env[i] > max) {
      max = env[i];
      at = i;
    }
  }
  let t10 = 0;
  while (t10 < env.length && env[t10] < 0.1 * max) t10++;
  const w = Math.round(0.003 * sr);
  let first = at;
  for (let i = t10; i < at; i++) {
    if (env[i] < 0.2 * max) continue;
    let isMax = true;
    for (let k = Math.max(0, i - w); k <= Math.min(env.length - 1, i + w); k++) if (env[k] > env[i]) {
      isMax = false;
      break;
    }
    if (isMax) {
      first = i;
      break;
    }
  }
  let t90 = t10;
  while (t90 < first && env[t90] < 0.9 * env[first]) t90++;
  // the rise: 10 % to 90 % of the loudest moment on a 10 ms envelope (how slowly a swell or a breath comes in)
  const slow = rmsEnvelope(x, sr, 0.01);
  let smax = 0;
  for (const v of slow) smax = Math.max(smax, v);
  let r10 = 0;
  while (r10 < slow.length && slow[r10] < 0.1 * smax) r10++;
  let r90 = r10;
  while (r90 < slow.length && slow[r90] < 0.9 * smax) r90++;
  return { onset: t10, peakAt: at, attack: (t90 - t10) / sr, rise: (r90 - r10) / sr, envelope: env, envPeak: max };
}

/**
 * The sustain: from 20 ms past the onset to where the 10 ms envelope falls 40 dB under its peak (the whole active
 * part for a sound shorter than 60 ms of sustain).
 */
export function sustainRange(x, sr) {
  const env = rmsEnvelope(x, sr, 0.01);
  let max = 0;
  for (const v of env) max = Math.max(max, v);
  let first = 0;
  while (first < env.length && env[first] < max * 0.1) first++;
  let last = env.length - 1;
  while (last > first && env[last] < max * 0.01) last--;
  let from = Math.min(last, first + Math.round(0.02 * sr));
  if (last - from < 0.06 * sr) from = first;
  return [from, Math.max(from + 64, last)];
}

/**
 * Tonal purity and strong peaks over the sustain, above 110 Hz (sub thumps may be pure).
 * @param {Float32Array} x
 * @param {number} sr
 */
export function tonality(x, sr) {
  const [from, to] = sustainRange(x, sr);
  const size = Math.min(16384, nextPow2(Math.max(4096, to - from)));
  let power;
  if (to - from > size * 2) power = welch(x, size, from, to);
  else power = segmentPower(x, from, Math.min(to, from + size), size);
  const lo = 110;
  const edges = [];
  for (let f = lo; f < 20000; f *= 2 ** (1 / 12)) edges.push(f);
  const bands = new Float64Array(edges.length);
  let total = 0;
  for (let k = 1; k < power.length; k++) {
    const f = (k * sr) / size;
    if (f < lo || f >= 20000) continue;
    const b = Math.min(edges.length - 1, Math.floor(12 * Math.log2(f / lo)));
    bands[b] += power[k];
    total += power[k];
  }
  let max = 0;
  for (const b of bands) max = Math.max(max, b);
  let peaks = 0;
  for (let i = 0; i < bands.length; i++) {
    const left = i > 0 ? bands[i - 1] : 0;
    const right = i < bands.length - 1 ? bands[i + 1] : 0;
    if (bands[i] > left && bands[i] >= right && bands[i] >= max / 100) peaks++;
  }
  return { purity: total > 0 ? max / total : 0, peaks };
}

/**
 * The envelope (rectified, low-passed at `lp` Hz) decimated to `rate` Hz, over the part above -30 dB of its peak.
 */
function slowEnvelope(x, sr, lp, rate) {
  const rect = new Float32Array(x.length);
  for (let i = 0; i < x.length; i++) rect[i] = Math.abs(x[i]);
  const smooth = butter(butter(rect, sr, 'lowpass', lp, 2), sr, 'lowpass', lp, 2);
  const step = Math.max(1, Math.round(sr / rate));
  const env = new Float32Array(Math.floor(x.length / step));
  for (let i = 0; i < env.length; i++) env[i] = smooth[i * step];
  let max = 0;
  for (const v of env) max = Math.max(max, v);
  let a = 0;
  while (a < env.length && env[a] < max * 0.03) a++;
  let b = env.length - 1;
  while (b > a && env[b] < max * 0.03) b--;
  return { env: env.slice(a, b + 1), rate: sr / step };
}

/** The modulation depth of the envelope in [lo, hi] Hz: rms of that band / the envelope's mean. */
function modulationDepth(env, rate, lo, hi) {
  if (env.length < rate * 0.08) return 0;
  let mean = 0;
  for (const v of env) mean += v;
  mean /= env.length;
  if (mean <= 0) return 0;
  const band = Float32Array.from(env);
  for (let i = 0; i < band.length; i++) band[i] -= mean;
  const hp = butter(band, rate, 'highpass', lo, 2);
  const bp = butter(hp, rate, 'lowpass', hi, 2);
  // skip the filters' settling at the start
  const skip = Math.min(bp.length - 1, Math.round(rate / lo));
  let s = 0;
  for (let i = skip; i < bp.length; i++) s += bp[i] * bp[i];
  return Math.sqrt(s / Math.max(1, bp.length - skip)) / mean;
}

/** Roughness: the envelope's modulation depth at 30-150 Hz. */
export function roughness(x, sr) {
  const { env, rate } = slowEnvelope(x, sr, 400, 2000);
  return modulationDepth(env, rate, 30, 150);
}

/** His throat's rattle: the 100-1200 Hz band's envelope modulated at 18-38 Hz (depth). */
export function rattleIndex(x, sr) {
  const band = butter(butter(x, sr, 'highpass', 100, 2), sr, 'lowpass', 1200, 2);
  const { env, rate } = slowEnvelope(band, sr, 90, 500);
  return modulationDepth(env, rate, 18, 38);
}

/**
 * The click at the contact: the share of the first 12 ms' energy (from the onset) that lies over 1.5 kHz. A dry
 * click, a tick or a knock puts most of its first milliseconds there; a body landing or a breath does not.
 * @param {Float32Array} x
 * @param {number} sr
 */
export function onsetClick(x, sr) {
  const { onset } = attack(x, sr);
  const len = Math.min(x.length - onset, Math.round(0.012 * sr));
  if (len < 16) return 0;
  const size = nextPow2(Math.max(2048, len));
  const re = new Float64Array(size);
  const im = new Float64Array(size);
  // the start is kept whole (the click is there); the end tapers
  const taper = Math.round(len / 3);
  for (let i = 0; i < len; i++) re[i] = x[onset + i] * (i < len - taper ? 1 : 0.5 + 0.5 * Math.cos((Math.PI * (i - (len - taper))) / taper));
  fft(re, im);
  let high = 0;
  let total = 0;
  for (let k = 1; k <= size / 2; k++) {
    const f = (k * sr) / size;
    if (f < 20) continue;
    const p = re[k] * re[k] + im[k] * im[k];
    total += p;
    if (f >= 1500) high += p;
  }
  return total > 0 ? high / total : 0;
}

/** Crest factor (dB): the peak over the RMS of the part above -40 dB. */
export function crest(x) {
  let peak = 0;
  for (const v of x) peak = Math.max(peak, Math.abs(v));
  let s = 0;
  let n = 0;
  for (const v of x) {
    if (Math.abs(v) < peak * 0.01) continue;
    s += v * v;
    n++;
  }
  return peak > 0 && n > 0 ? 20 * Math.log10(peak / Math.sqrt(s / n)) : 0;
}

/** The mean (DC) of a buffer. */
export function dc(x) {
  let s = 0;
  for (const v of x) s += v;
  return s / x.length;
}

/** Samples at or over full scale. */
export function clipped(...channels) {
  let n = 0;
  for (const c of channels) for (const v of c) if (Math.abs(v) >= 0.9999) n++;
  return n;
}

/** Silence at the start and the end (s): before the first / after the last sample above -60 dB of the peak. */
export function silences(x, sr) {
  let peak = 0;
  for (const v of x) peak = Math.max(peak, Math.abs(v));
  const thr = peak * 1e-3;
  let a = 0;
  while (a < x.length && Math.abs(x[a]) < thr) a++;
  let b = x.length - 1;
  while (b > 0 && Math.abs(x[b]) < thr) b--;
  return { lead: a / sr, tail: (x.length - 1 - b) / sr };
}

/** The level of the last 5 ms over the peak (dB): above -50 means the tail was cut, not decayed. */
export function endLevel(x, sr) {
  let peak = 0;
  for (const v of x) peak = Math.max(peak, Math.abs(v));
  const n = Math.max(1, Math.round(0.005 * sr));
  let s = 0;
  for (let i = x.length - n; i < x.length; i++) s += x[i] * x[i];
  const r = Math.sqrt(s / n);
  return peak > 0 && r > 0 ? 20 * Math.log10(r / peak) : -Infinity;
}

/**
 * The loop seam: the jump from the last sample to the first against the 99.9th percentile of sample steps (a
 * ratio; under 1.5 is as smooth as anywhere inside), and the level step across it (dB, the 50 ms before the end
 * against the 50 ms after the start) beyond the 95th percentile of the steps between neighbouring 50 ms windows
 * inside the loop (a loop of breaths or footfalls changes level all the time; the seam must not change it more).
 * @param {Float32Array[]} channels
 * @param {number} sr
 */
export function loopSeam(channels, sr) {
  let ratio = 0;
  let level = 0;
  const w = Math.round(0.05 * sr);
  const dbOf = (x, from) => {
    let e = 0;
    for (let i = 0; i < w; i++) e += x[(from + i + x.length) % x.length] ** 2;
    return 10 * Math.log10(e / w + 1e-12);
  };
  for (const x of channels) {
    const steps = new Float32Array(x.length - 1);
    for (let i = 1; i < x.length; i++) steps[i - 1] = Math.abs(x[i] - x[i - 1]);
    const sorted = Float32Array.from(steps).sort();
    const typical = sorted[Math.floor(sorted.length * 0.999)] || 1e-9;
    ratio = Math.max(ratio, Math.abs(x[0] - x[x.length - 1]) / typical);
    const inner = [];
    for (let a = 0; a + 2 * w <= x.length; a += w) inner.push(Math.abs(dbOf(x, a) - dbOf(x, a + w)));
    inner.sort((p, q) => p - q);
    const usual = inner.length ? inner[Math.floor(inner.length * 0.95)] : 0;
    const seam = Math.abs(dbOf(x, x.length - w) - dbOf(x, 0));
    level = Math.max(level, Math.max(0, seam - usual));
  }
  return { ratio, level };
}

/**
 * A third-octave x 20 ms level map (dB) from the onset, over `seconds`, the sound scaled to unit peak band.
 */
function levelMap(x, sr, seconds) {
  const { onset } = attack(x, sr);
  const size = 2048;
  const hop = Math.round(0.02 * sr);
  const frames = Math.max(1, Math.floor((seconds * sr) / hop));
  const centres = [];
  for (let f = 63; f <= 16000; f *= 2 ** (1 / 3)) centres.push(f);
  const map = [];
  const w = hann(size);
  for (let j = 0; j < frames; j++) {
    const start = onset + j * hop - size / 4;
    const re = new Float64Array(size);
    const im = new Float64Array(size);
    for (let i = 0; i < size; i++) {
      const k = start + i;
      re[i] = k >= 0 && k < x.length ? x[k] * w[i] : 0;
    }
    fft(re, im);
    const row = centres.map((c) => {
      const lo = Math.floor(((c / 2 ** (1 / 6)) * size) / sr);
      const hi = Math.max(lo + 1, Math.ceil(((c * 2 ** (1 / 6)) * size) / sr));
      let s = 0;
      for (let k = lo; k < hi && k <= size / 2; k++) s += re[k] * re[k] + im[k] * im[k];
      return s;
    });
    map.push(row);
  }
  let max = 0;
  for (const row of map) for (const v of row) max = Math.max(max, v);
  return map.map((row) => row.map((v) => (v > 0 && max > 0 ? Math.max(-70, 10 * Math.log10(v / max)) : -70)));
}

/**
 * How different two variants are: the mean absolute dB difference of their onset-aligned third-octave x 20 ms level
 * maps over the cells either has above -50 dB. A copy (at any level) is 0; a re-pitched copy a few dB.
 * @param {Float32Array} a
 * @param {Float32Array} b
 * @param {number} sr
 */
export function variantDistance(a, b, sr) {
  const seconds = Math.min(0.8, Math.max(0.1, Math.min(a.length, b.length) / sr));
  const A = levelMap(a, sr, seconds);
  const B = levelMap(b, sr, seconds);
  let s = 0;
  let n = 0;
  for (let j = 0; j < Math.min(A.length, B.length); j++) {
    for (let k = 0; k < A[j].length; k++) {
      if (A[j][k] < -50 && B[j][k] < -50) continue;
      s += Math.abs(A[j][k] - B[j][k]);
      n++;
    }
  }
  return n ? s / n : 0;
}
