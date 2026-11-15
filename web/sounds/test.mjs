// test.mjs (npm run sounds:test): every part of the kit and the measurements, checked on known signals.
// No framework: each case is a name and a function that throws on failure.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as K from './kit/index.mjs';
import * as M from './lib/measure.mjs';

const SR = 48000;
const here = path.dirname(fileURLToPath(import.meta.url));
/** @type {Array<[string, () => void]>} */
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
/** The pitch from the autocorrelation's strongest lag in 40..1200 samples (over 0.04-0.4 s), interpolated. */
function lagPitch(x) {
  const ac = (L) => {
    let s = 0;
    for (let i = 2000; i < 20000; i++) s += x[i] * x[i + L];
    return s;
  };
  let best = -Infinity;
  let lag = 40;
  for (let L = 40; L < 1200; L++) {
    const v = ac(L);
    if (v > best) {
      best = v;
      lag = L;
    }
  }
  const a = ac(lag - 1);
  const c = ac(lag + 1);
  const d = (0.5 * (a - c)) / (a - 2 * best + c);
  return SR / (lag + d);
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

// ------------------------------------------------------------------ bodies
test('modal: a mode rings at its frequency with its T60', () => {
  const imp = new Float32Array(1);
  imp[0] = 1;
  const y = K.modal(imp, SR, [{ f: 440, t60: 0.8, gain: 1 }], SR * 2);
  near(peakFreq(y), 440, 0.5, 'frequency');
  near(t60Of(y), 0.8, 0.06, 'T60');
  near(K.peak(y), 1, 0.05, 'unit impulse amplitude');
});
test('modal: plate ratios are inharmonic and sorted; strike position changes the mode gains', () => {
  const p = K.plateRatios(12);
  ok(p[0] === 1 && p.every((v, i) => i === 0 || v >= p[i - 1]), 'sorted from 1');
  ok(p.some((v) => Math.abs(v - Math.round(v)) > 0.1), 'all harmonic');
  const mid = K.strikeGains(6, 0.5);
  ok(mid[1] < 0.2 && mid[0] > 0.9, 'a centre strike excites mode 2');
});
test('comb and Karplus-Strong: pitch from the delay', () => {
  const r = new K.Rng(10);
  const burst = K.white(200, r);
  const ks = K.karplus(SR, SR, { freq: 220, t60: 1.5, brightness: 0.5, exciter: burst });
  near(lagPitch(ks), 220, 1, 'string pitch');
  const dull = K.karplus(SR, SR, { freq: 110, t60: 1.5, brightness: 0, exciter: burst });
  near(lagPitch(dull), 110, 0.5, 'dull string pitch');
  const imp = new Float32Array(1);
  imp[0] = 1;
  const c = K.comb(imp, SR, { delay: 0.005, feedback: 0.9, length: SR });
  near(lagPitch(c), 200, 1, 'comb fundamental');
  const ap = K.allpass(K.white(SR, r), SR, 0.0137, 0.6);
  ok(Number.isFinite(K.rms(ap)), 'allpass');
});
test('friction: the slip rate follows stiffness * v / ((muS - muD) * force)', () => {
  const r = new K.Rng(11);
  const count = (v, f) => K.stickSlip(SR, SR, { velocity: v, force: f, stiffness: 40, irregularity: 0, rng: r }).reduce((s, x) => s + (x > 0 ? 1 : 0), 0);
  near(count(1, 1), 100, 3, 'slips at v 1, force 1');
  near(count(0.5, 1), 50, 3, 'half the speed');
  near(count(1, 2), 50, 3, 'twice the force');
  const b = K.bowed(SR, SR, { modes: [{ f: 700, t60: 0.6 }, { f: 1810, t60: 0.4 }], velocity: 1, force: 0.5, rng: r });
  ok(Number.isFinite(K.rms(b)) && K.rms(b) > 0, 'the bowed body is silent or unstable');
});

// ------------------------------------------------------------------ voice
test('glottal: the pulse rate is f0; period doubling puts energy at f0 / 2', () => {
  const r = new K.Rng(12);
  const g = K.glottal(SR, SR, { f0: 120, rng: r, jitter: 0, shimmer: 0, aspiration: 0 });
  const lp = K.butter(g, SR, 'lowpass', 160, 4);
  near(peakFreq(lp), 120, 1, 'f0');
  const s = K.glottal(SR, SR, { f0: 120, rng: r, jitter: 0, shimmer: 0, aspiration: 0, sub: 0.8 });
  ok(bandEnergy(s, 50, 70) > 30 * bandEnergy(g, 50, 70), 'no subharmonic at 60 Hz');
});
test('formants: a vowel puts its peaks at its formants', () => {
  const r = new K.Rng(13);
  const src = K.white(SR, r);
  const y = K.formants(src, SR, K.vowelTracks(SR, SR, [[0, 'a']], { rng: r }));
  const e1 = bandEnergy(y, 650, 820);
  const gap = bandEnergy(y, 1500, 1670);
  ok(e1 > 8 * gap, 'F1 is not a peak');
  const big = K.formants(src, SR, K.vowelTracks(SR, SR, [[0, 'a']], { rng: r, scale: 0.6 }));
  ok(bandEnergy(big, 390, 490) > bandEnergy(big, 650, 820), 'scale 0.6 did not move F1 down');
});
test('voice: roughen and flutter modulate at their rate; the voices render finite', () => {
  const r = new K.Rng(14);
  const x = K.svf(K.white(SR, r), SR, 'lowpass', 3000, 0.7);
  const before = M.roughness(x, SR);
  K.roughen(x, SR, { rate: 60, depth: 0.8, rng: r, jitter: 0 });
  ok(M.roughness(x, SR) > before + 0.2, 'roughness did not rise');
  const fl = K.flutter(SR, SR, { rate: 28, depth: 0.8, rng: r, irregularity: 0 });
  const noise = K.svf(K.white(SR, r), SR, 'bandpass', 400, 0.8);
  const rattled = K.mul(Float32Array.from(noise), fl);
  ok(M.rattleIndex(rattled, SR) > 0.25 && M.rattleIndex(noise, SR) < 0.15, 'the rattle detector misses a 28 Hz flutter');
  for (const v of [
    K.breath(SR / 2, SR, { rng: r, rattle: 0.5, voiced: 0.2 }),
    K.growl(SR / 2, SR, { rng: r, f0: 60 }),
    K.scream(SR / 2, SR, { rng: r, f0: 500, breaks: [{ at: 0.2, length: 0.1, ratio: 1.5 }] }),
    K.babble(SR / 2, SR, { rng: r }),
    K.child(SR / 2, SR, { rng: r, f0: 300 }),
  ]) ok(v.every(Number.isFinite) && K.rms(v) > 0, 'a voice is silent or not finite');
});

// ------------------------------------------------------------------ grains, thump, saturation
test('grains: a Poisson process gives about rate x duration events, and follows a falling rate', () => {
  const r = new K.Rng(15);
  near(K.poissonTimes(r, 100, 50).length, 5000, 250, 'constant rate');
  const t = K.poissonTimes(r, 1, (x) => 200 * Math.exp(-x * 5), 200);
  const early = t.filter((x) => x < 0.2).length;
  const late = t.filter((x) => x >= 0.6).length;
  ok(early > 5 * late, 'the density does not fall');
  const p = K.ping(SR, r, { freq: 5000, t60: 0.05 });
  near(peakFreq(p, 8192), 5000, 300, 'ping pitch');
  const bub = K.bubble(SR, r, { freq: 1500, t60: 0.02, rise: 0 });
  near(peakFreq(bub, 8192), 1500, 60, 'bubble pitch');
});
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
test('measure: porcelain clicks are counted', () => {
  const r = new K.Rng(21);
  const x = new Float32Array(SR);
  for (const t of [0.1, 0.23, 0.31, 0.5, 0.72]) K.addAt(x, K.ping(SR, r, { freq: 2600, t60: 0.02 }), t * SR);
  near(M.porcelainClicks(x, SR), 5, 0, 'clicks');
  ok(M.porcelainClicks(K.svf(K.white(SR, r), SR, 'lowpass', 800, 0.7), SR) < 3, 'smooth low noise has clicks');
});

// ------------------------------------------------------------------ his signatures, impacts, density, seams
test('porcelain: a tick is short, its strong partials sit in 1.2-5 kHz; chatter makes clusters the detector counts', () => {
  const tick = K.porcelainTick(SR, new K.Rng(30), { freq: 2000, t60: 0.03 });
  ok(tick.length / SR < 0.06, 'a tick is long');
  const share = bandEnergy(tick, 1200, 5000) / bandEnergy(tick, 20, 24000);
  ok(share > 0.8, `only ${(share * 100).toFixed(0)} % of a tick is in 1.2-5 kHz`);
  ok(t60Of(tick) < 0.05, 'a tick rings too long');
  const c = K.chatter(SR, SR, new K.Rng(31), { rate: 4, from: 0, to: 0.9 });
  ok(M.porcelainClicks(c, SR) >= 4, 'chatter is not counted as porcelain');
});
test('impact: a footfall attacks in under 5 ms, carries its low body, and a heel comes before the weight', () => {
  const r = new K.Rng(32);
  const f = K.footfall(SR, r, {
    length: 0.8,
    heel: { delay: 0.07, gain: -5 },
    thump: { f0: 60, f1: 42, drop: 0.06, t60: 0.4, gain: -8 },
    body: { modes: K.scatterModes(r, 6, 130, 420, 0.1, 0.2), gain: 0 },
    contact: { length: 0.012, cutoff: 1400, gain: -3 },
  });
  const a = M.attack(f, SR);
  ok(a.attack < 0.005, `attack ${a.attack}`);
  ok(a.peakAt / SR > 0.06, 'the weight does not land after the heel');
  ok(bandEnergy(f, 20, 250) / bandEnergy(f, 20, 24000) > 0.3, 'no low body');
  const g = K.grit(SR, new K.Rng(33), { count: 30, spread: 0.2, freq: [500, 4000] });
  ok(M.tonality(g, SR).purity < 0.2, 'grit is tonal');
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
    fn();
    console.log(`PASS ${name}`);
  } catch (err) {
    failed++;
    console.log(`FAIL ${name}\n     ${err instanceof Error ? err.message : err}`);
  }
}
console.log(`\n${cases.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
