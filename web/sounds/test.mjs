// test.mjs (npm run sounds:test): every part of the kit and the measurements, checked on known signals.
// No framework: each case is a name and a function that throws on failure.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as K from './kit/index.mjs';
import * as M from './lib/measure.mjs';

const SR = 48000;
const here = path.dirname(fileURLToPath(import.meta.url));
/** @type {Array<[string, () => void|Promise<void>]>} */
const cases = [];
const test = (name, fn) => cases.push([name, fn]);

function ok(cond, msg) {
  if (!cond) throw new Error(msg);
}
function near(a, b, tol, what) {
  ok(Math.abs(a - b) <= tol, `${what}: ${a.toFixed(4)} is not within ${tol} of ${b}`);
}
function sine(freq, seconds, amp = 1) {
  const x = new Float32Array(Math.round(seconds * SR));
  for (let i = 0; i < x.length; i++) x[i] = amp * Math.sin((2 * Math.PI * freq * i) / SR);
  return x;
}
/** The frequency of the strongest bin (parabolic interpolation). */
function peakFreq(x, size = 65536) {
  const p = M.segmentPower(x, 0, Math.min(x.length, size), size);
  let k = 1;
  for (let i = 2; i < p.length - 1; i++) if (p[i] > p[k]) k = i;
  const a = Math.log(p[k - 1] + 1e-30);
  const b = Math.log(p[k] + 1e-30);
  const c = Math.log(p[k + 1] + 1e-30);
  const d = (0.5 * (a - c)) / (a - 2 * b + c);
  return ((k + d) * SR) / size;
}
/** Measured T60 of a decaying signal from its 10 ms envelope (fit between -5 and -35 dB). */
function t60Of(x) {
  const env = M.rmsEnvelope(x, SR, 0.01);
  let max = 0;
  let at = 0;
  for (let i = 0; i < env.length; i++) if (env[i] > max) {
    max = env[i];
    at = i;
  }
  let a = at;
  while (a < env.length && env[a] > max * K.db(-5)) a++;
  let b = a;
  while (b < env.length && env[b] > max * K.db(-35)) b++;
  return ((b - a) / SR) * 2;
}
function bandEnergy(x, lo, hi) {
  const size = 65536;
  const p = M.segmentPower(x, 0, Math.min(x.length, size), size);
  let s = 0;
  for (let k = 0; k < p.length; k++) {
    const f = (k * SR) / size;
    if (f >= lo && f < hi) s += p[k];
  }
  return s;
}

// ------------------------------------------------------------------ rng
test('rng: the same seed gives the same numbers; forks are independent and stable', () => {
  const a = new K.Rng(K.seedOf('Thing', 1));
  const b = new K.Rng(K.seedOf('Thing', 1));
  for (let i = 0; i < 1000; i++) ok(a.u32() === b.u32(), 'two generators with one seed diverged');
  ok(K.seedOf('Thing', 1) !== K.seedOf('Thing', 2), 'variants share a seed');
  const r = new K.Rng(7);
  const f1 = r.fork('layer').next();
  r.next();
  ok(r.fork('layer').next() === f1, 'a fork depends on draws made before it');
});
test('rng: uniform mean 0.5, normal mean 0 and sd 1', () => {
  const r = new K.Rng(99);
  let s = 0;
  let s1 = 0;
  let s2 = 0;
  const n = 200000;
  for (let i = 0; i < n; i++) s += r.next();
  for (let i = 0; i < n; i++) {
    const v = r.normal();
    s1 += v;
    s2 += v * v;
  }
  near(s / n, 0.5, 0.005, 'uniform mean');
  near(s1 / n, 0, 0.01, 'normal mean');
  near(Math.sqrt(s2 / n), 1, 0.01, 'normal sd');
});
test('no Math.random anywhere in web/sounds', () => {
  const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(dir, e.name)) : [path.join(dir, e.name)]));
  for (const f of walk(here).filter((p) => p.endsWith('.mjs') && !p.endsWith('test.mjs'))) {
    ok(!/Math\.random\s*\(/.test(fs.readFileSync(f, 'utf8')), `${path.relative(here, f)} calls Math.random`);
  }
});

// ------------------------------------------------------------------ fft
test('fft: matches a direct DFT and inverts', () => {
  const n = 64;
  const r = new K.Rng(3);
  const re = new Float64Array(n);
  const im = new Float64Array(n);
  for (let i = 0; i < n; i++) re[i] = r.range(-1, 1);
  const orig = Float64Array.from(re);
  K.fft(re, im);
  for (const k of [0, 5, 31]) {
    let dr = 0;
    let di = 0;
    for (let t = 0; t < n; t++) {
      dr += orig[t] * Math.cos((-2 * Math.PI * k * t) / n);
      di += orig[t] * Math.sin((-2 * Math.PI * k * t) / n);
    }
    near(re[k], dr, 1e-9, `bin ${k} re`);
    near(im[k], di, 1e-9, `bin ${k} im`);
  }
  K.fft(re, im, true);
  for (let i = 0; i < n; i++) near(re[i], orig[i], 1e-12, 'inverse');
});
test('fft: convolution equals direct convolution', () => {
  const r = new K.Rng(4);
  const a = K.white(300, r);
  const b = K.white(77, r);
  const c = K.convolve(a, b);
  for (const i of [0, 50, 200, 375]) {
    let s = 0;
    for (let j = 0; j < b.length; j++) if (i - j >= 0 && i - j < a.length) s += a[i - j] * b[j];
    near(c[i], s, 1e-4, `sample ${i}`);
  }
});

// ------------------------------------------------------------------ filters
test('biquad: a Butterworth low-pass is -3 dB at its cutoff and -12 dB/octave beyond', () => {
  const f = new K.Biquad('lowpass', SR, 1000, Math.SQRT1_2);
  near(20 * Math.log10(f.response(1000)), -3.01, 0.05, 'gain at fc');
  // the slope well under Nyquist (near it the bilinear transform steepens it)
  const g = new K.Biquad('lowpass', SR, 100, Math.SQRT1_2);
  near(20 * Math.log10(g.response(1600)) - 20 * Math.log10(g.response(800)), -12, 0.5, 'slope');
  const p = new K.Biquad('peak', SR, 500, 2, 6);
  near(20 * Math.log10(p.response(500)), 6, 0.01, 'peak gain');
});
test('laptop filter: -3 dB at 220 Hz, about -25 dB at 50 Hz, flat at 1 kHz', () => {
  const lo = M.rmsEnvelope(K.laptop(sine(50, 1), SR), SR, 0.1)[SR / 2] / M.rmsEnvelope(sine(50, 1), SR, 0.1)[SR / 2];
  near(20 * Math.log10(lo), -25.7, 1, '50 Hz');
  const mid = M.rmsEnvelope(K.laptop(sine(220, 1), SR), SR, 0.1)[SR / 2] / M.rmsEnvelope(sine(220, 1), SR, 0.1)[SR / 2];
  near(20 * Math.log10(mid), -3, 0.3, '220 Hz');
  const hi = M.rmsEnvelope(K.laptop(sine(1000, 1), SR), SR, 0.1)[SR / 2] / M.rmsEnvelope(sine(1000, 1), SR, 0.1)[SR / 2];
  near(20 * Math.log10(hi), 0, 0.3, '1 kHz');
});
test('svf: the band output peaks at the cutoff with unity gain; a sweep is stable', () => {
  const x = sine(2000, 0.5);
  const y = K.svf(x, SR, 'bandpass', 2000, 4);
  near(K.rms(y, SR / 4) / K.rms(x, SR / 4), 1, 0.02, 'band gain at fc');
  const off = K.svf(sine(8000, 0.5), SR, 'bandpass', 2000, 4);
  ok(K.rms(off, SR / 4) < 0.15, 'two octaves off is not attenuated');
  const sweep = K.svf(K.white(SR, new K.Rng(1)), SR, 'lowpass', (i) => 100 + 15000 * (i / SR), 8);
  ok(sweep.every(Number.isFinite) && K.peak(sweep) < 50, 'a fast resonant sweep blew up');
});
test('dc blocker: removes an offset, passes 100 Hz', () => {
  const x = sine(100, 1, 0.5);
  for (let i = 0; i < x.length; i++) x[i] += 0.3;
  K.dcBlock(x, SR);
  near(M.dc(x.subarray(SR / 2)), 0, 1e-3, 'residual DC');
  near(K.rms(x, SR / 2) / (0.5 / Math.SQRT2), 1, 0.02, '100 Hz level');
});

// ------------------------------------------------------------------ noise, envelopes
test('noise: pink falls 3 dB/octave, brown 6 dB/octave, white is flat', () => {
  const r = new K.Rng(5);
  const n = SR * 4;
  const slope = (x) => 10 * Math.log10(bandEnergy(x, 2000, 4000) / bandEnergy(x, 500, 1000)) / 2;
  near(slope(K.white(n, r)), 3, 0.5, 'white (energy per octave doubles: +3)');
  near(slope(K.pink(n, r)), 0, 0.6, 'pink (equal energy per octave)');
  near(slope(K.brown(n, SR, r)), -3, 0.8, 'brown');
});
test('velvet: about the asked density of unit impulses', () => {
  const v = K.velvet(SR, SR, 2000, new K.Rng(6));
  const count = v.reduce((s, x) => s + (x !== 0 ? 1 : 0), 0);
  near(count, 2000, 5, 'impulses');
});
test('envelopes: decayEnv falls 60 dB in t60; segments interpolate; smoothRandom stays in range', () => {
  const e = K.decayEnv(SR, SR, { attack: 0.002, t60: 0.5 });
  near(20 * Math.log10(e[Math.round(0.502 * SR)]), -60, 0.5, 'level at t60');
  ok(e[0] === 0, 'the attack starts at 0');
  const s = K.segments(SR, SR, [[0, 0], [0.5, 1], [1, 0]]);
  near(s[SR / 4], 0.5, 0.001, 'linear midpoint');
  const m = K.smoothRandom(SR, SR, 5, new K.Rng(8), -0.2, 0.3);
  ok(m.every((v) => v >= -0.2 && v <= 0.3), 'out of range');
  const l = K.smoothRandomLoop(SR, SR, 5, new K.Rng(8));
  ok(Math.abs(l[0] - l[l.length - 1]) < 0.01, 'the loop modulator does not wrap');
});
test('mix: a crossfaded loop is seamless; fades start and end at 0', () => {
  const r = new K.Rng(9);
  const x = K.svf(K.white(SR * 2, r), SR, 'lowpass', 400, 0.7);
  const loop = K.loopCrossfade(x, SR, 0.2);
  ok(M.loopSeam([loop], SR).ratio < 1.5, 'seam');
  const f = K.fade(Float32Array.from(x), SR, 0.01, 0.01);
  ok(f[0] === 0 && Math.abs(f[f.length - 1]) < 1e-6, 'fade ends');
});

// ------------------------------------------------------------------ voice
test('voice: the flutter pulses at its rate (the rattle detector finds it)', () => {
  const r = new K.Rng(14);
  const fl = K.flutter(SR, SR, { rate: 28, depth: 0.8, rng: r, irregularity: 0 });
  const noise = K.svf(K.white(SR, r), SR, 'bandpass', 400, 0.8);
  const rattled = K.mul(Float32Array.from(noise), fl);
  ok(M.rattleIndex(rattled, SR) > 0.25 && M.rattleIndex(noise, SR) < 0.15, 'the rattle detector misses a 28 Hz flutter');
});

// ------------------------------------------------------------------ thump, saturation
test('thump: the pitch falls from f0 to f1; saturation adds the harmonics a laptop plays', () => {
  const clean = K.thump(SR, { f0: 60, f1: 42, drop: 0.05, t60: 1.2, drive: 0 });
  near(peakFreq(clean.subarray(Math.round(0.4 * SR)), 32768), 42, 1, 'settled pitch');
  // the sine starts at phase 0, so its first upward zero crossing ends the first cycle (near f0: about 57 Hz
  // averaged over it); the pitch falls cycle by cycle
  const ups = [];
  for (let i = 1; i < clean.length && ups.length < 12; i++) if (clean[i - 1] < 0 && clean[i] >= 0) ups.push(i);
  near(SR / ups[0], 57, 1.5, 'first cycle pitch');
  ok(SR / (ups[11] - ups[10]) < SR / (ups[2] - ups[1]), 'the pitch does not fall');
  // a hard-driven thump keeps about 5 dB more through the laptop filter (its 3rd, 5th, 7th harmonics at 130-400 Hz);
  // the rest of a heavy sound's laptop weight is its low-mid body (docs/SOUND.md 2)
  const driven = K.thump(SR, { f0: 60, f1: 42, drop: 0.05, t60: 1.2, drive: 8 });
  const l0 = 20 * Math.log10(K.rms(K.laptop(clean, SR)) / K.rms(clean));
  const l1 = 20 * Math.log10(K.rms(K.laptop(driven, SR)) / K.rms(driven));
  ok(l1 > l0 + 5, `saturation gained only ${(l1 - l0).toFixed(1)} dB through the laptop filter`);
  const share = (x) => bandEnergy(x, 100, 400) / bandEnergy(x, 20, 400);
  ok(10 * Math.log10(share(driven) / share(clean)) > 20, 'saturation added no harmonics at 100-400 Hz');
});
test('saturation: 4x oversampling keeps the aliases of a hard-driven 7 kHz sine under -60 dB', () => {
  const x = sine(7000, 0.5, 0.9);
  const y = K.saturate(x, { drive: 6, curve: 'tanh', factor: 4 });
  // the harmonics are 21, 35, 49 kHz...; the aliases of 35 and 49 kHz land at 13 and 1 kHz
  const p = M.segmentPower(y, 0, 16384, 16384);
  const binOf = (f) => Math.round((f * 16384) / SR);
  const lvl = (f) => {
    let m = 0;
    for (let k = binOf(f) - 3; k <= binOf(f) + 3; k++) m = Math.max(m, p[k]);
    return m;
  };
  const fund = lvl(7000);
  for (const alias of [13000, 1000, 11000]) ok(10 * Math.log10(lvl(alias) / fund) < -60, `alias at ${alias} Hz`);
  const naive = Float32Array.from(x, (v) => Math.tanh(v * 6));
  const q = M.segmentPower(naive, 0, 16384, 16384);
  ok(10 * Math.log10(q[binOf(13000)] / q[binOf(7000)]) > -40, 'the alias test does not discriminate');
  const s = K.saturate(sine(100, 0.2, 0.1), { drive: 2 });
  ok(Math.abs(s[2000] - 0.1 * Math.sin((2 * Math.PI * 100 * 2000) / SR) * (2 / Math.tanh(2))) < 0.02, 'oversampling shifted the signal in time');
});

// ------------------------------------------------------------------ space
test('reverb: the FDN tail decays in about its RT60; the IR has unit energy', () => {
  const r = new K.Rng(16);
  const imp = new Float32Array(1);
  imp[0] = 1;
  const [l] = K.fdn(imp, SR, { rt60: 1.5, rt60High: 1.5, length: SR * 3, rng: r });
  const band = K.butter(K.butter(l, SR, 'highpass', 300, 2), SR, 'lowpass', 1500, 2);
  near(t60Of(band.subarray(Math.round(0.1 * SR))), 1.5, 0.3, 'RT60');
  const ir = K.impulse(SR, K.SPACES.corridor, r);
  let e = 0;
  for (const c of ir) for (const v of c) e += v * v;
  near(e / 2, 1, 1e-3, 'IR energy');
  const [pl] = K.place(sine(300, 0.2), SR, K.SPACES.room, { wet: 0.5, rng: r });
  ok(pl.length > SR * 0.2 && pl.every(Number.isFinite), 'place');
});

// ------------------------------------------------------------------ dynamics, loudness
test('limiter: no true peak over the ceiling; quiet signals untouched', () => {
  const r = new K.Rng(17);
  const x = K.white(SR, r, 0.5);
  const gr = K.limit([x], SR, { ceilingDb: -1 });
  ok(K.truePeak([x]) <= -0.9, `true peak ${K.truePeak([x]).toFixed(2)} dBTP`);
  ok(gr > 0, 'no reduction reported');
  const q = sine(1000, 0.3, 0.1);
  const before = Float32Array.from(q);
  ok(K.limit([q], SR, { ceilingDb: -1 }) === 0 && q.every((v, i) => v === before[i]), 'a quiet signal was changed');
});
test('loudness: a -23 dBFS 1 kHz sine reads -26.0 LUFS mono and -23.0 stereo (EBU 3341)', () => {
  const x = sine(997, 5, K.db(-23));
  near(K.integrated([x], SR), -26.0, 0.1, 'mono');
  near(K.integrated([x, x], SR), -23.0, 0.1, 'stereo');
  near(K.momentaryMax([x, x], SR), -23.0, 0.1, 'momentary');
  near(K.truePeak([x]), -23, 0.1, 'true peak');
  const gated = new Float32Array(SR * 10);
  gated.set(x.subarray(0, SR * 5));
  near(K.integrated([gated, gated], SR), -23.0, 0.2, 'silence is gated out');
});

// ------------------------------------------------------------------ distance model
test('distance: the spec voice model (8/d, fade 60 -> 90, x0.5 a wall), cutoffs and reverb share', () => {
  const carry = { ref: 8, max: 90, rolloff: 1 };
  near(K.heard(4, 0, carry).gain, 1, 1e-9, 'inside ref');
  near(K.heard(40, 0, carry).gain, 0.2, 1e-9, '8/40');
  near(K.heard(75, 0, carry).gain, (8 / 75) * 0.5, 1e-9, 'half way through the fade');
  near(K.heard(40, 1, carry).gain, 0.1, 1e-9, 'one wall');
  ok(K.heard(95, 0, carry).gain === 0, 'past max');
  ok(K.heard(40, 1, carry).cutoff === 2400 && K.heard(40, 3, carry).cutoff === 600, 'wall cutoffs');
  ok(K.heard(10, 0, carry).cutoff > K.heard(80, 0, carry).cutoff, 'distance darkens');
  const h = K.heard(30, 0, carry);
  near(h.direct ** 2 + h.send ** 2, h.gain ** 2, 1e-12, 'energy split');
  ok(K.heard(80, 0, carry).reverb > K.heard(10, 0, carry).reverb, 'far is more reverberant');
});

// ------------------------------------------------------------------ measurements
test('measure: a sine is pure with one peak; noise is not; band shares and centroid', () => {
  const s = sine(1000, 0.5, 0.5);
  const t = M.tonality(s, SR);
  ok(t.purity > 0.9 && t.peaks === 1, `sine purity ${t.purity.toFixed(2)} peaks ${t.peaks}`);
  // white noise's strongest twelfth-octave band is its top one (about 6 % of the energy); pink is spread evenly
  ok(M.tonality(K.white(SR, new K.Rng(18)), SR).purity < 0.08, 'white noise purity');
  ok(M.tonality(K.pink(SR, new K.Rng(18)), SR).purity < 0.03, 'pink noise purity');
  const sh = M.bandShares(sine(100, 1), SR);
  ok(sh[1] > 0.99, 'a 100 Hz sine is not in 80-250');
  near(M.centroid(sine(3000, 1), SR), 3000, 30, 'centroid');
});
test('measure: attack, crest, silences, cut tail, clipping, variant distance', () => {
  const x = K.mul(K.white(SR, new K.Rng(19)), K.decayEnv(SR, SR, { attack: 0.002, t60: 0.3 }));
  const a = M.attack(x, SR);
  ok(a.attack < 0.004, `attack ${a.attack}`);
  const padded = new Float32Array(SR + 4800);
  padded.set(x, 4800);
  near(M.silences(padded, SR).lead, 0.1, 0.002, 'lead silence');
  ok(M.endLevel(sine(200, 0.2), SR) > -10, 'a cut sine is not flagged');
  ok(M.endLevel(x, SR) < -50, 'a decayed tail is flagged');
  ok(M.clipped(Float32Array.of(0.5, 1, -1)) === 2, 'clipped count');
  const copy = K.gain(Float32Array.from(x), 0.5);
  ok(M.variantDistance(x, copy, SR) < 0.01, 'a copy is not a near-copy');
  const other = K.mul(K.svf(K.white(SR, new K.Rng(20)), SR, 'lowpass', 900, 0.7), K.decayEnv(SR, SR, { attack: 0.002, t60: 0.1 }));
  ok(M.variantDistance(x, other, SR) > 3, 'different sounds read as copies');
  ok(M.crest(sine(100, 0.5)) > 2.9 && M.crest(sine(100, 0.5)) < 3.2, 'sine crest');
});
test('measure: the rattle index finds an 18-38 Hz pulsing; the onset click finds a bright contact', () => {
  const r = new K.Rng(21);
  const body = K.svf(K.white(SR, r), SR, 'lowpass', 900, 0.7);
  const pulsed = K.mul(Float32Array.from(body), K.flutter(body.length, SR, { rate: 26, depth: 0.7, rng: new K.Rng(22) }));
  ok(M.rattleIndex(pulsed, SR) >= 0.2, `a throat pulsing at 26 Hz reads ${M.rattleIndex(pulsed, SR).toFixed(3)}`);
  ok(M.rattleIndex(body, SR) < M.rattleIndex(pulsed, SR) / 2, 'steady noise reads as a rattle');
  const thud = K.mul(K.svf(K.white(SR / 2, r), SR, 'lowpass', 300, 0.7), K.decayEnv(SR / 2, SR, { attack: 0.002, t60: 0.2 }));
  const click = K.mul(K.svf(K.white(SR / 2, r), SR, 'highpass', 3000, 0.7), K.decayEnv(SR / 2, SR, { attack: 0.0005, t60: 0.02 }));
  ok(M.onsetClick(thud, SR) < 0.03, 'a low thud reads as a click');
  ok(M.onsetClick(click, SR) > 0.5, 'a bright tick does not read as a click');
});

// ------------------------------------------------------------------ recordings, density, seams
test('sample: played at half speed a recording is an octave down and twice as long; regions fade; takes are found', () => {
  const x = sine(440, 0.5);
  const slow = K.resample(x, 0.5);
  near(slow.length / x.length, 2, 0.01, 'length at half speed');
  near(peakFreq(slow), 220, 2, 'pitch at half speed');
  near(peakFreq(K.resample(sine(300, 1), 1.5)), 450, 3, 'pitch at 1.5');
  const cut = K.region(x, SR, 0.1, 0.3, 0.01, 0.02);
  near(cut.length / SR, 0.2, 0.001, 'region length');
  ok(cut[0] === 0 && Math.abs(cut[cut.length - 1]) < 1e-3, 'a region starts and ends at silence');
  const takes = new Float32Array(2 * SR);
  takes.set(sine(200, 0.3), 0.2 * SR);
  takes.set(sine(200, 0.4), 1.1 * SR);
  const found = K.events(takes, SR);
  ok(found.length === 2, `${found.length} takes found, not 2`);
  const [a, b] = K.active(takes, SR);
  ok(a > 0.15 && a < 0.21 && b > 1.49 && b < 1.56, `active ${a.toFixed(3)}-${b.toFixed(3)}`);
});
test('recipe: a layer is cut at its transient, pulsed by the throat\'s flutter, and every draw is the same on every run', async () => {
  const { renderLayer } = await import('./lib/recipe.mjs');
  const { indexedIds } = await import('./lib/sources.mjs');
  const id = indexedIds()[0];
  ok(id, 'no recording in sources/SOURCES.json');
  const plain = renderLayer({ src: id }, SR, new K.Rng(40));
  const trimmed = renderLayer({ src: id, trim: true }, SR, new K.Rng(40));
  ok(trimmed.length <= plain.length, 'trimming lengthened the layer');
  const first = trimmed.findIndex((v) => Math.abs(v) >= 0.2);
  ok(first >= 0 && first < 0.002 * SR, `the transient comes ${(first / SR * 1000).toFixed(1)} ms in`);
  const again = renderLayer({ src: id, rate: [0.5, 0.6], flutter: [26, 0.5] }, SR, new K.Rng(41));
  const twice = renderLayer({ src: id, rate: [0.5, 0.6], flutter: [26, 0.5] }, SR, new K.Rng(41));
  ok(again.length === twice.length && again.every((v, i) => v === twice[i]), 'the same seed rendered differently');
});
test('sources: every recording in SOURCES.json is stored unmodified, from a CC0 pack with a page and an author', async () => {
  const { verifyStore, loadIndex } = await import('./lib/sources.mjs');
  const problems = verifyStore();
  ok(!problems.length, problems.slice(0, 4).join('; '));
  for (const [pack, p] of Object.entries(loadIndex().packs)) ok(p.licences.includes('CC0'), `${pack} is not CC0`);
});
test('densify: drives a peaky sound until its peak-to-loudness ratio fits', () => {
  const r = new K.Rng(34);
  const x = K.mul(K.white(SR / 2, r), K.decayEnv(SR / 2, SR, { attack: 0.0005, t60: 0.08 }));
  const plr = (y) => K.truePeak([y]) - K.momentaryMax([y], SR);
  const before = plr(K.unit(Float32Array.from(x)));
  const after = plr(K.densify(x, SR, before - 4));
  ok(after <= before - 4 + 0.01, `peak-to-loudness ${before.toFixed(1)} -> ${after.toFixed(1)}`);
  ok(Math.abs(K.peak(K.densify(x, SR, 40)) - 1) < 1e-6, 'an already dense sound is not unit peak');
});
test('seam: a crossfaded loop has no seam; a cut one has; a loop of bursts is not flagged for its own steps', () => {
  const r = new K.Rng(35);
  const noise = K.svf(K.white(SR * 4, r), SR, 'lowpass', 2000, 0.7);
  const loop = K.loopCrossfade(noise, SR, 0.3);
  const s = M.loopSeam([loop], SR);
  ok(s.ratio < 1.5 && s.level < 1.5, `crossfaded seam ${s.ratio.toFixed(2)} ${s.level.toFixed(2)}`);
  const cut = Float32Array.from(noise.subarray(0, SR * 3));
  K.gain(cut.subarray(0, SR), 0.1);
  ok(M.loopSeam([cut], SR).level > 1.5, 'a level step at the seam is not flagged');
  const bursts = new Float32Array(SR * 4);
  for (let t = 0.1; t < 3.9; t += 0.5) K.addAt(bursts, K.mul(K.white(SR / 5, r), K.decayEnv(SR / 5, SR, { attack: 0.01, t60: 0.15 })), t * SR);
  ok(M.loopSeam([bursts], SR).level < 1.5, 'a loop of bursts is flagged for its own steps');
});

// ------------------------------------------------------------------ run
let failed = 0;
for (const [name, fn] of cases) {
  try {
    await fn();
    console.log(`PASS ${name}`);
  } catch (err) {
    failed++;
    console.log(`FAIL ${name}\n     ${err instanceof Error ? err.message : err}`);
  }
}
console.log(`\n${cases.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
