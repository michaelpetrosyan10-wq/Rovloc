// voice.mjs: throats. A source (glottal pulses with jitter, shimmer, subharmonics, pitch breaks and chaos, plus
// aspiration noise gated by the open glottis; or turbulence alone for breath and whisper) through a bank of formant
// resonators that move between vowels. The nonlinearities are what make a voice alive and frightening (Blumstein et
// al. 2010: distress calls are rough, break in pitch, double their period, burst into noise); roughness is amplitude
// modulation at 30-150 Hz (Arnal et al. 2015). Size is the formant scale: a tract twice as long halves every formant.
//
//   glottal()      the pulse source           formants()   the resonator bank (tracks per formant)
//   vowelTracks()  a vowel path as tracks     roughen()    30-150 Hz amplitude modulation
//   flutter()      a soft-palate rattle (a 20-35 Hz flap train)
//   breath(), growl(), scream(), whisper(), babble(), child(): the voices built from them

import { white, pink } from './noise.mjs';
import { svf } from './filters.mjs';
import { smoothRandom } from './env.mjs';

/** @typedef {number|Float32Array} Signal */
/** @typedef {{freq: Signal, bw: Signal, gain: Signal}} Formant  gain linear */

const at = (v, i) => (typeof v === 'number' ? v : v[Math.min(i, v.length - 1)]);

/**
 * Formants of an adult male tract: [freq Hz, bandwidth Hz, gain dB] x 5.
 * @type {Readonly<Record<string, ReadonlyArray<readonly [number, number, number]>>>}
 */
export const VOWELS = Object.freeze({
  a: [[730, 90, 0], [1090, 110, -4], [2440, 160, -16], [3400, 250, -22], [4400, 300, -28]],
  o: [[570, 80, 0], [840, 90, -6], [2410, 160, -22], [3300, 250, -28], [4200, 300, -34]],
  u: [[300, 60, 0], [870, 90, -14], [2240, 160, -26], [3200, 250, -32], [4100, 300, -36]],
  e: [[530, 80, 0], [1840, 120, -10], [2480, 160, -14], [3500, 250, -22], [4500, 300, -28]],
  i: [[270, 60, 0], [2290, 120, -18], [3010, 160, -16], [3700, 250, -24], [4600, 300, -30]],
  ae: [[660, 90, 0], [1720, 120, -6], [2410, 160, -12], [3400, 250, -20], [4400, 300, -26]],
  uh: [[640, 80, 0], [1190, 100, -6], [2390, 160, -18], [3300, 250, -24], [4300, 300, -30]],
});

/**
 * The glottal source: Rosenberg flow pulses (open phase `open` of the period, `skew` of it opening), differentiated
 * (the radiated pressure), with per-period jitter and shimmer, period doubling (`sub` 0..1), pitch breaks
 * ({at, length, ratio}: a sudden jump and back), chaos (0..1: wild period scatter), creak (the chance a period is a
 * long irregular one: vocal fry), and aspiration noise breathing through the open glottis.
 * @param {number} n samples
 * @param {number} sr
 * @param {{f0: Signal, rng: import('./rng.mjs').Rng, jitter?: number, shimmer?: number, open?: number, skew?: number,
 *   sub?: Signal, breaks?: Array<{at: number, length: number, ratio: number}>, chaos?: Signal, creak?: number,
 *   aspiration?: number}} spec
 */
export function glottal(n, sr, { f0, rng, jitter = 0.01, shimmer = 0.04, open = 0.6, skew = 0.72, sub = 0, breaks = [], chaos = 0, creak = 0, aspiration = 0.05 }) {
  const out = new Float32Array(n);
  const asp = white(n, rng.fork('aspiration'));
  const r = rng.fork('periods');
  let i = 0;
  let period = 0;
  let prev = 0;
  const tp = open * skew;
  const tn = open * (1 - skew);
  while (i < n) {
    const t = i / sr;
    let f = Math.max(15, at(f0, i));
    for (const b of breaks) if (t >= b.at && t < b.at + b.length) f *= b.ratio;
    let T = sr / f;
    T *= 1 + jitter * r.normal() + at(chaos, i) * r.range(-0.5, 0.5);
    let amp = Math.max(0, 1 + shimmer * r.normal());
    const s = at(sub, i);
    if (s > 0) {
      const odd = (period & 1) === 1;
      T *= 1 + (odd ? s : -s) * 0.3;
      if (odd) amp *= 1 - 0.65 * s;
    }
    if (creak > 0 && r.chance(creak)) T *= r.range(1.6, 2.8);
    T = Math.max(4, T);
    const len = Math.round(T);
    for (let k = 0; k < len && i < n; k++, i++) {
      const ph = k / T;
      let flow = 0;
      if (ph < tp) flow = 0.5 * (1 - Math.cos((Math.PI * ph) / tp));
      else if (ph < tp + tn) flow = Math.cos((Math.PI * (ph - tp)) / (2 * tn));
      flow *= amp;
      out[i] = (flow - prev) * T * 0.15 + asp[i] * aspiration * (0.2 + flow);
      prev = flow;
    }
    period++;
  }
  return out;
}

/**
 * The resonator bank: each formant a band-pass (unity peak) with its own frequency, bandwidth and gain track.
 * @param {Float32Array} source
 * @param {number} sr
 * @param {Formant[]} tracks
 */
export function formants(source, sr, tracks) {
  const out = new Float32Array(source.length);
  for (const tr of tracks) {
    const q = typeof tr.freq === 'number' && typeof tr.bw === 'number'
      ? tr.freq / tr.bw
      : (/** @type {number} */ i) => at(tr.freq, i) / Math.max(10, at(tr.bw, i));
    const band = svf(source, sr, 'bandpass', tr.freq, q);
    for (let i = 0; i < out.length; i++) out[i] += band[i] * at(tr.gain, i);
  }
  return out;
}

/**
 * Formant tracks along a vowel path [[time s, vowel], ...] (linear moves between them), scaled in frequency by
 * `scale` (tract size: 0.6 is a throat far too large) and in bandwidth by `bwScale`, each formant wandering by
 * `wander` (a fraction) on a smooth random curve.
 * @param {number} n
 * @param {number} sr
 * @param {Array<[number, keyof typeof VOWELS]>} path
 * @param {{scale?: number, bwScale?: number, wander?: number, count?: number, rng: import('./rng.mjs').Rng}} spec
 * @returns {Formant[]}
 */
export function vowelTracks(n, sr, path, { scale = 1, bwScale = 1, wander = 0, count = 5, rng }) {
  const tracks = [];
  for (let k = 0; k < count; k++) {
    const freq = new Float32Array(n);
    const bw = new Float32Array(n);
    const gain = new Float32Array(n);
    const drift = wander > 0 ? smoothRandom(n, sr, 3, rng.fork(`wander${k}`)) : null;
    let p = 0;
    for (let i = 0; i < n; i++) {
      const t = i / sr;
      while (p < path.length - 1 && t >= path[p + 1][0]) p++;
      const [t0, v0] = path[p];
      const [t1, v1] = path[Math.min(p + 1, path.length - 1)];
      const u = p >= path.length - 1 || t1 <= t0 ? 0 : Math.min(1, Math.max(0, (t - t0) / (t1 - t0)));
      const A = VOWELS[v0][k];
      const B = VOWELS[v1][k];
      freq[i] = (A[0] + (B[0] - A[0]) * u) * scale * (drift ? 1 + wander * drift[i] : 1);
      bw[i] = (A[1] + (B[1] - A[1]) * u) * bwScale * Math.max(0.6, scale);
      gain[i] = 10 ** ((A[2] + (B[2] - A[2]) * u) / 20);
    }
    tracks.push({ freq, bw, gain });
  }
  return tracks;
}

/**
 * Roughness: amplitude modulation at `rate` Hz (30-150: the band the ear hears as rough), jittered per cycle, depth
 * 0..1 (a number or a track). In place.
 * @param {Float32Array} buf
 * @param {number} sr
 * @param {{rate: Signal, depth: Signal, rng: import('./rng.mjs').Rng, jitter?: number}} spec
 */
export function roughen(buf, sr, { rate, depth, rng, jitter = 0.25 }) {
  let ph = 0;
  let step = 1;
  for (let i = 0; i < buf.length; i++) {
    ph += (at(rate, i) * step) / sr;
    if (ph >= 1) {
      ph -= 1;
      step = 1 + jitter * rng.range(-0.5, 0.5);
    }
    const m = 0.5 - 0.5 * Math.cos(2 * Math.PI * ph);
    const d = at(depth, i);
    buf[i] *= 1 - d + d * m * 1.6;
  }
  return buf;
}

/**
 * A soft-palate rattle: the flap of wet tissue fluttering in the airflow at `rate` Hz (20-35 for something huge),
 * as a gain track (0..1): each closure a short dip, each reopening a burst. Irregular period to period.
 * @param {number} n
 * @param {number} sr
 * @param {{rate: Signal, depth: Signal, rng: import('./rng.mjs').Rng, irregularity?: number}} spec
 */
export function flutter(n, sr, { rate, depth, rng, irregularity = 0.3 }) {
  const out = new Float32Array(n);
  let ph = 0;
  let step = 1;
  let open = 0.55;
  for (let i = 0; i < n; i++) {
    ph += (at(rate, i) * step) / sr;
    if (ph >= 1) {
      ph -= 1;
      step = 1 + irregularity * rng.range(-0.5, 0.5);
      open = 0.35 + 0.4 * rng.next();
    }
    // closed for (1 - open) of the cycle, a burst at the reopening; wet tissue closes softly (a smooth zero, not a
    // cusp: a cusp is a click every cycle, a buzz of clicks up to 10 kHz instead of a rattle)
    const g = ph < open ? Math.sin((Math.PI * ph) / open) ** 1.5 : 0;
    const d = at(depth, i);
    out[i] = 1 - d + d * g * 1.5;
  }
  return out;
}

/**
 * Breath: turbulence (pink and white) through the tract's formants, wide and breathy; an exhale may carry the
 * flutter rattle and a faint voiced creak.
 * @param {number} n
 * @param {number} sr
 * @param {{rng: import('./rng.mjs').Rng, vowel?: keyof typeof VOWELS, scale?: number, rattle?: number,
 *   rattleRate?: number, voiced?: number, f0?: number}} spec
 */
export function breath(n, sr, { rng, vowel = 'uh', scale = 1, rattle = 0, rattleRate = 28, voiced = 0, f0 = 60 }) {
  const turb = pink(n, rng.fork('pink'));
  const hiss = white(n, rng.fork('white'));
  for (let i = 0; i < n; i++) turb[i] = turb[i] + 0.35 * hiss[i];
  let src = turb;
  if (voiced > 0) {
    const v = glottal(n, sr, { f0, rng: rng.fork('voice'), jitter: 0.06, shimmer: 0.2, creak: 0.15, sub: 0.4, aspiration: 0 });
    for (let i = 0; i < n; i++) src[i] += v[i] * voiced;
  }
  const tracks = vowelTracks(n, sr, [[0, vowel]], { scale, bwScale: 2.2, wander: 0.06, rng: rng.fork('tract') });
  const out = formants(src, sr, tracks);
  if (rattle > 0) {
    const g = flutter(n, sr, { rate: rattleRate, depth: rattle, rng: rng.fork('rattle') });
    for (let i = 0; i < n; i++) out[i] *= g[i];
  }
  return out;
}

/**
 * A growl: a low pulse source with period doubling, jitter and creak, roughened, through a big tract.
 * @param {number} n
 * @param {number} sr
 * @param {{rng: import('./rng.mjs').Rng, f0: Signal, path?: Array<[number, keyof typeof VOWELS]>, scale?: number,
 *   sub?: Signal, rough?: number, roughRate?: number, noise?: number}} spec
 */
export function growl(n, sr, { rng, f0, path = [[0, 'o']], scale = 0.65, sub = 0.5, rough = 0.6, roughRate = 45, noise = 0.25 }) {
  const src = glottal(n, sr, { f0, rng: rng.fork('glottis'), jitter: 0.07, shimmer: 0.25, sub, creak: 0.06, open: 0.7, aspiration: noise });
  const tracks = vowelTracks(n, sr, path, { scale, bwScale: 1.6, wander: 0.08, rng: rng.fork('tract') });
  const out = formants(src, sr, tracks);
  return roughen(out, sr, { rate: roughRate, depth: rough, rng: rng.fork('rough') });
}

/**
 * A scream: high, unstable, breaking: chaos, period doubling, sudden pitch jumps, noise bursting in.
 * @param {number} n
 * @param {number} sr
 * @param {{rng: import('./rng.mjs').Rng, f0: Signal, path?: Array<[number, keyof typeof VOWELS]>, scale?: number,
 *   breaks?: Array<{at: number, length: number, ratio: number}>, chaos?: Signal, sub?: Signal, rough?: number,
 *   roughRate?: number}} spec
 */
export function scream(n, sr, { rng, f0, path = [[0, 'a']], scale = 0.9, breaks = [], chaos = 0.15, sub = 0.3, rough = 0.5, roughRate = 70 }) {
  const src = glottal(n, sr, { f0, rng: rng.fork('glottis'), jitter: 0.03, shimmer: 0.15, sub, chaos, breaks, open: 0.5, skew: 0.8, aspiration: 0.35 });
  const tracks = vowelTracks(n, sr, path, { scale, bwScale: 1.3, wander: 0.05, rng: rng.fork('tract') });
  const out = formants(src, sr, tracks);
  return roughen(out, sr, { rate: roughRate, depth: rough, rng: rng.fork('rough') });
}

/**
 * A whisper: turbulence alone through moving formants (no voicing).
 * @param {number} n
 * @param {number} sr
 * @param {{rng: import('./rng.mjs').Rng, path: Array<[number, keyof typeof VOWELS]>, scale?: number}} spec
 */
export function whisper(n, sr, { rng, path, scale = 1 }) {
  const src = white(n, rng.fork('turbulence'));
  const tracks = vowelTracks(n, sr, path, { scale, bwScale: 1.8, wander: 0.05, rng: rng.fork('tract') });
  return formants(src, sr, tracks);
}

/**
 * Whisper babble: syllables at `rate` a second, each a random vowel with a consonant's hiss at its onset, gated by its
 * own envelope: speech you cannot quite make out.
 * @param {number} n
 * @param {number} sr
 * @param {{rng: import('./rng.mjs').Rng, rate?: number, scale?: number, hiss?: number}} spec
 */
export function babble(n, sr, { rng, rate = 4.5, scale = 1, hiss = 0.25 }) {
  const r = rng.fork('syllables');
  const names = /** @type {Array<keyof typeof VOWELS>} */ (['a', 'o', 'u', 'e', 'i', 'ae', 'uh']);
  /** @type {Array<[number, keyof typeof VOWELS]>} */
  const path = [];
  const gate = new Float32Array(n);
  const onsets = new Float32Array(n);
  let t = r.range(0, 0.1);
  while (t < n / sr) {
    const len = (1 / rate) * r.range(0.6, 1.3);
    path.push([t, r.pick(names)]);
    const a = Math.round(t * sr);
    const b = Math.min(n, Math.round((t + len * 0.85) * sr));
    for (let i = a; i < b; i++) gate[i] = Math.sin((Math.PI * (i - a)) / (b - a)) ** 0.7;
    const c = Math.min(n, a + Math.round(0.035 * sr));
    if (r.chance(0.6)) for (let i = a; i < c; i++) onsets[i] = Math.sin((Math.PI * (i - a)) / (c - a));
    t += len;
  }
  if (!path.length) path.push([0, 'uh']);
  const voiced = whisper(n, sr, { rng: rng.fork('voice'), path, scale });
  const fric = svf(white(n, rng.fork('fricative')), sr, 'highpass', 2800 * scale, 0.8);
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) out[i] = voiced[i] * gate[i] + fric[i] * onsets[i] * hiss;
  return out;
}

/**
 * A child's voice: a high, light, steady source through a small tract (scale ~1.3).
 * @param {number} n
 * @param {number} sr
 * @param {{rng: import('./rng.mjs').Rng, f0: Signal, path?: Array<[number, keyof typeof VOWELS]>, scale?: number}} spec
 */
export function child(n, sr, { rng, f0, path = [[0, 'a']], scale = 1.3 }) {
  const src = glottal(n, sr, { f0, rng: rng.fork('glottis'), jitter: 0.008, shimmer: 0.04, open: 0.55, aspiration: 0.15 });
  const tracks = vowelTracks(n, sr, path, { scale, bwScale: 1.2, wander: 0.03, rng: rng.fork('tract') });
  return formants(src, sr, tracks);
}
