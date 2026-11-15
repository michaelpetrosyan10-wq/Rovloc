// scares.mjs: the creature code's 2D sounds, played at the player rather than at him: the chase music (its sting and
// its driving pulse), the stare's sting, the give-up swell, the fake-out's shriek (he is NOT in that spot), the hiding
// spot's warning knock and the shove out of it, and the torch stuttering. Because they do not come from where he is,
// they carry none of his signatures (spec I1: what sounds like him is him): no porcelain, no throat rattle, no gait.
// They are music and machinery: struck and bowed metal, drums of stretched skin, rough clusters of low voices, a
// filament crackling.

import * as K from '../kit/index.mjs';

const FAMILY = 'scares';

/**
 * A big struck sheet of steel: dense plate modes from `base`, struck at a random place, ringing `t60`.
 * @param {number} sr
 * @param {K.Rng} r
 * @param {{base: number, t60: number, count?: number, seconds: number}} spec
 */
function steelHit(sr, r, { base, t60, count = 24, seconds }) {
  const exc = K.burst(sr, r.fork('strike'), { length: 0.004, cutoff: 5000, hp: 40 });
  const modes = K.modesFrom(base, K.plateRatios(count, 1.37), { t60, damp: 0.5, tilt: -2.5, gains: K.strikeGains(count, r.range(0.1, 0.9), r.range(0.1, 0.9)), detune: 0.025, rng: r });
  return K.unit(K.modal(exc, sr, modes, Math.round(seconds * sr)));
}

/**
 * A low drum: a stretched membrane (Bessel-ratio modes) over a pitch-dropping thump; `tension` sets the pitch.
 * @param {number} sr
 * @param {K.Rng} r
 * @param {{base: number, seconds?: number}} spec
 */
function drum(sr, r, { base, seconds = 0.7 }) {
  const skin = K.modal(K.burst(sr, r.fork('stick'), { length: 0.003, cutoff: 2500, hp: 30 }), sr, K.modesFrom(base, K.MEMBRANE, { t60: 0.35, damp: 0.8, tilt: -3, detune: 0.02, rng: r }), Math.round(seconds * sr));
  const out = K.unit(skin);
  K.addAt(out, K.unit(K.thump(sr, { f0: base * 1.4, f1: base * 0.85, drop: 0.03, t60: 0.3, drive: 2.5 })), 0, 0.8);
  return K.unit(out);
}

/**
 * A rough cluster of low voiced drones (horn-like, never a clean tone): glottal pulses through an open vowel,
 * detuned so they beat at 2-7 Hz, roughened.
 * @param {number} n
 * @param {number} sr
 * @param {K.Rng} r
 * @param {{f0: number[], rough?: number, scale?: number}} spec
 */
function drones(n, sr, r, { f0, rough = 0.5, scale = 0.9 }) {
  const out = new Float32Array(n);
  f0.forEach((f, k) => {
    const v = r.fork(`d${k}`);
    const src = K.glottal(n, sr, { f0: f, rng: v, jitter: 0.004, shimmer: 0.05, open: 0.5, aspiration: 0.08 });
    const tone = K.formants(src, sr, K.vowelTracks(n, sr, [[0, 'o']], { scale, bwScale: 1.4, wander: 0.04, rng: v.fork('tract') }));
    K.roughen(tone, sr, { rate: v.range(35, 55), depth: rough, rng: v.fork('rough') });
    K.addAt(out, K.unit(tone), 0, 1 / f0.length);
  });
  return K.unit(out);
}

/**
 * @param {Partial<import('../lib/voices.mjs').Voice> & Pick<import('../lib/voices.mjs').Voice, 'name'|'title'|'description'|'class'|'loudness'|'render'>} v
 * @returns {import('../lib/voices.mjs').Voice}
 */
function scare(v) {
  return /** @type {import('../lib/voices.mjs').Voice} */ ({ family: FAMILY, group: 'reference', variants: 2, channels: 2, loop: null, space: 'baked', board: 'Scares', ...v });
}

/** @type {import('../lib/voices.mjs').Voice[]} */
export const voices = [
  scare({
    name: 'ChaseSting',
    title: 'The chase begins',
    description: 'The hit as he starts chasing you: a huge sheet of steel struck, a drum and a groan of low horns under a drop.',
    class: 'stinger',
    loudness: -11,
    render: ({ sr, rng }) => {
      const s = 2.2;
      const n = Math.round(s * sr);
      const r = rng.fork('sting');
      const left = new Float32Array(n);
      const right = new Float32Array(n);
      const steel = steelHit(sr, r.fork('steel'), { base: r.range(95, 125), t60: 1.6, seconds: s });
      const hit = drum(sr, r.fork('drum'), { base: r.range(48, 56), seconds: 1.2 });
      const horn = drones(n, sr, r.fork('horns'), { f0: [55, 58.3, 82.4 * 1.01], rough: 0.6, scale: 0.8 });
      K.mul(horn, K.segments(n, sr, [[0, 0], [0.04, 1, -3], [s, 0, 2]]));
      const drop = K.unit(K.thump(sr, { f0: 70, f1: 30, drop: 0.6, t60: s, drive: 3, length: s }));
      const [sl, sr2] = K.pan(steel, -0.35);
      for (const [ch, steelSide, side] of [[left, sl, -1], [right, sr2, 1]]) {
        K.addAt(ch, steelSide, 0, 0.8);
        K.addAt(ch, hit, side > 0 ? 0.008 * sr : 0, 0.6);
        K.addAt(ch, horn, side > 0 ? 0.013 * sr : 0, 0.55);
        K.addAt(ch, drop, 0, 0.3);
      }
      const p = K.peak(left, right);
      return [K.densify(K.gain(left, 1 / p), sr, 10), K.densify(K.gain(right, 1 / p), sr, 10)];
    },
  }),
  scare({
    name: 'ChasePulse',
    title: 'The chase music',
    description: 'While he chases you: drums pounding like a heart about to burst, low horns grinding, steel groaning in waves.',
    class: 'music',
    variants: 1,
    loop: { seconds: 8, crossfade: 0.4 },
    loudness: -16,
    render: ({ sr, rng, seconds }) => {
      const n = Math.round(seconds * sr);
      const r = rng.fork('pulse');
      const left = new Float32Array(n);
      const right = new Float32Array(n);
      // 132 bpm, a heartbeat's double hit on every beat, the second softer; the pattern starts after the crossfade
      const beat = 60 / 132;
      for (let t = 0.45; t < seconds - 0.05; t += beat) {
        const d = r.fork(`b${t.toFixed(3)}`);
        const lub = drum(sr, d, { base: d.range(50, 54), seconds: 0.6 });
        const dub = drum(sr, d.fork('dub'), { base: d.range(56, 60), seconds: 0.5 });
        for (const ch of [left, right]) {
          K.addAt(ch, lub, t * sr, 0.9);
          K.addAt(ch, dub, (t + beat * 0.32) * sr, 0.55);
        }
      }
      // the horns grind underneath, three voices a semitone and a tritone apart, beating
      const horn = drones(n, sr, r.fork('horns'), { f0: [41.2, 43.65, 58.3], rough: 0.55, scale: 0.75 });
      const breathe = K.smoothRandom(n, sr, 0.6, r.fork('swell'), 0.4, 1);
      K.mul(horn, breathe);
      // steel groaning in waves: a bowed plate swelling every two bars
      const push = new Float32Array(n);
      for (let i = 0; i < n; i++) push[i] = 0.3 + 0.7 * Math.max(0, Math.sin((2 * Math.PI * i) / (sr * beat * 8))) ** 2;
      const groan = K.bowed(n, sr, { modes: K.modesFrom(r.range(90, 120), K.plateRatios(16, 1.29), { t60: 0.6, damp: 0.4, tilt: -3, detune: 0.03, rng: r }), velocity: push, force: 0.8, coupling: 0.6, stiffness: 900, irregularity: 0.4, rng: r.fork('bow') });
      const g = K.unit(K.butter(groan, sr, 'lowpass', 1800, 2));
      K.addAt(left, horn, 0, 0.45);
      K.addAt(right, horn, 0.011 * sr, 0.45);
      K.addAt(left, g, 0.007 * sr, 0.3);
      K.addAt(right, g, 0, 0.3);
      return [left, right];
    },
  }),
  scare({
    name: 'StareSting',
    title: 'You looked at him too long',
    description: 'A sharp, sour stab of scraped steel and low horns: your stare caught his attention, and he is coming.',
    class: 'stinger',
    loudness: -12,
    render: ({ sr, rng }) => {
      const s = 1.6;
      const n = Math.round(s * sr);
      const r = rng.fork('stare');
      const steel = steelHit(sr, r.fork('steel'), { base: r.range(80, 100), t60: 1.1, seconds: s });
      const scrape = K.bowed(n, sr, { modes: K.modesFrom(r.range(300, 380), K.plateRatios(14, 1.29), { t60: 0.4, damp: 0.4, tilt: -2, detune: 0.03, rng: r }), velocity: K.segments(n, sr, [[0, 1.4], [s, 0.2]]), force: 0.7, coupling: 0.7, stiffness: 1600, irregularity: 0.4, rng: r.fork('bow') });
      K.mul(scrape, K.segments(n, sr, [[0, 0], [0.01, 1, -3], [s, 0, 2]]));
      const horn = drones(n, sr, r.fork('horn'), { f0: [61.7, 65.4, 87.3], rough: 0.7, scale: 0.8 });
      K.mul(horn, K.segments(n, sr, [[0, 0], [0.02, 1, -3], [s, 0, 2]]));
      const mono = new Float32Array(n);
      K.addAt(mono, steel, 0, 0.6);
      K.addAt(mono, K.unit(K.butter(scrape, sr, 'lowpass', 2600, 2)), 0, 0.35);
      K.addAt(mono, horn, 0, 0.5);
      K.addAt(mono, K.unit(K.thump(sr, { f0: 75, f1: 38, drop: 0.25, t60: 1, drive: 3 })), 0, 0.5);
      const dense = K.densify(mono, sr, 11);
      return [dense, K.delayed(dense, sr, 0.009).subarray(0, n).slice()];
    },
  }),
  scare({
    name: 'GiveUpSwell',
    title: 'He gave up the chase',
    description: 'The chase ends: everything that was pounding pulls back into itself and dissolves into the dark.',
    class: 'swell',
    loudness: -20,
    render: ({ sr, rng }) => {
      const r = rng.fork('giveup');
      // a struck steel sheet and a drum, rung into the hall, played backwards, then let go
      const hit = new Float32Array(Math.round(1.2 * sr));
      K.addAt(hit, steelHit(sr, r.fork('steel'), { base: r.range(60, 75), t60: 1, seconds: 1.2 }), 0, 0.7);
      K.addAt(hit, drum(sr, r.fork('drum'), { base: 50, seconds: 0.8 }), 0, 0.6);
      const [l, rr] = K.place(hit, sr, K.SPACES.hall, { wet: 0.85, darken: 2000, rng: r.fork('space') });
      const len = Math.min(l.length, Math.round(2.2 * sr));
      const back = [K.reverse(l).subarray(l.length - len), K.reverse(rr).subarray(rr.length - len)].map((c) => Float32Array.from(c));
      // and it lets go: a soft fall over the last 0.4 s instead of an edge
      for (const c of back) K.mul(c, K.segments(len, sr, [[0, 1], [len / sr - 0.4, 1], [len / sr, 0, 3]]));
      return back.map((c) => K.fade(c, sr, 0.05, 0.02));
    },
  }),
  scare({
    name: 'FakeoutShriek',
    title: 'Nothing in the locker',
    description: 'You open a hiding place and a scream bursts out at you, and there is nothing there.',
    class: 'stinger',
    loudness: -10,
    render: ({ sr, rng }) => {
      const s = rng.range(0.9, 1.1);
      const n = Math.round(s * sr);
      const r = rng.fork('fake');
      const out = new Float32Array(n);
      // human-sized throats this time (scale 0.85-1.05): a shriek, not him
      for (let k = 0; k < 3; k++) {
        const v = r.fork(`v${k}`);
        const f0 = K.segments(n, sr, [[0, v.range(300, 380)], [0.05, v.range(480, 620), -3], [s, v.range(260, 320)]]);
        const voice = K.scream(n, sr, { rng: v, f0, path: [[0, 'ae'], [s, 'a']], scale: v.range(0.85, 1.05), breaks: [{ at: v.range(0.15, 0.5), length: v.range(0.05, 0.12), ratio: v.pick([0.5, 1.5]) }], chaos: 0.25, sub: 0.4, rough: 0.6, roughRate: v.range(60, 90) });
        K.addAt(out, K.unit(voice), 0, 0.5);
      }
      K.mul(out, K.segments(n, sr, [[0, 0], [0.005, 1, -4], [s * 0.4, 0.8], [s, 0, 2]]));
      K.addAt(out, K.unit(K.thump(sr, { f0: 90, f1: 40, drop: 0.12, t60: 0.6, drive: 3 })), 0, 0.6);
      K.addAt(out, steelHit(sr, r.fork('door'), { base: r.range(110, 150), t60: 0.5, count: 16, seconds: s }), 0, 0.35);
      const dense = K.densify(out, sr, 9);
      return [dense, K.delayed(dense, sr, 0.006).subarray(0, n).slice()];
    },
  }),
  scare({
    name: 'HideWarn',
    title: 'Time to leave your hiding place',
    description: 'A soft double knock on the steel around you: you cannot stay in here much longer.',
    class: 'body',
    variants: 3,
    channels: 1,
    loudness: -22,
    render: ({ sr, rng }) => {
      const r = rng.fork('knock');
      const out = new Float32Array(Math.round(0.9 * sr));
      for (const [at, level] of [[0, 1], [r.range(0.16, 0.22), r.range(0.7, 0.9)]]) {
        const k = r.fork(`k${at}`);
        const panel = K.modal(K.burst(sr, k, { length: 0.004, cutoff: 1200, hp: 60 }), sr, [...K.scatterModes(k, 4, 110, 300, 0.12, 0.2, 0), ...K.modesFrom(k.range(240, 300), K.plateRatios(14, 1.41), { t60: 0.3, damp: 0.6, tilt: -4, detune: 0.03, rng: k })], Math.round(0.6 * sr));
        K.addAt(out, K.unit(panel), at * sr, level);
      }
      return out;
    },
  }),
  scare({
    name: 'HideKick',
    title: 'Shoved out of your hiding place',
    description: 'The locker door bangs open hard around you, steel booming and the latch rattling.',
    class: 'heavy',
    variants: 3,
    channels: 1,
    loudness: -15.5,
    render: ({ sr, rng }) => {
      const r = rng.fork('kick');
      const door = K.modesFrom(r.range(150, 190), K.plateRatios(18, 1.41), { t60: 0.5, damp: 0.55, tilt: -4, detune: 0.03, rng: r });
      door[0].gain = (door[0].gain ?? 1) * 0.3; // the door's panel is held at its hinges and latch
      const bang = K.footfall(sr, r.fork('bang'), {
        length: 1.1,
        thump: { f0: 75, f1: 45, drop: 0.04, t60: 0.35, drive: 3, gain: -5 },
        body: { modes: [...K.scatterModes(r, 7, 100, 320, 0.12, 0.25, 0), ...door], gain: 0, excite: 0.0015, cutoff: 3000 },
        contact: { length: 0.004, cutoff: 3000, gain: -2 },
      });
      // the latch and the hinges rattling as the door swings
      const latch = new Float32Array(Math.round(0.4 * sr));
      let t = 0.03;
      let level = 1;
      while (t < 0.35) {
        const k = r.fork(`l${t.toFixed(3)}`);
        K.addAt(latch, K.unit(K.modal(K.burst(sr, k, { length: 0.001, cutoff: 6000, hp: 500 }), sr, K.scatterModes(k, 4, 800, 2400, 0.015, 0.04, -2), Math.round(0.05 * sr))), t * sr, level);
        t += r.range(0.025, 0.06);
        level *= 0.7;
      }
      K.addAt(bang, latch, 0.02 * sr, 0.25);
      return K.densify(bang, sr, 13);
    },
  }),
  scare({
    name: 'TorchStutter',
    title: 'Your torch stuttering',
    description: 'The torch in your hand crackling and cutting out: the filament spitting, the switch chattering. Something is near.',
    class: 'spark',
    variants: 3,
    channels: 1,
    loudness: -24,
    render: ({ sr, rng }) => {
      const s = rng.range(1.0, 1.3);
      const n = Math.round(s * sr);
      const r = rng.fork('torch');
      const out = new Float32Array(n);
      // the switch contact chattering: bursts of tiny clicks, in clumps
      const times = K.poissonTimes(r.fork('t'), s, (t) => 60 * (0.5 + 0.5 * Math.sin(t * 9)), 60);
      for (const t of times) K.addAt(out, K.click(sr, r, { freq: r.range(1200, 5000), q: 1.5, length: r.range(0.0006, 0.002) }), t * sr, r.range(0.3, 1));
      // it starts with the contact breaking: one hard spit
      K.addAt(K.unit(out), K.unit(K.burst(sr, r.fork('spit'), { length: 0.008, attack: 0.0001, cutoff: 6000, hp: 800 })), 0, 2);
      // the filament sizzling where it touches: a rough electrical buzz, cutting in and out
      const pulses = new Float32Array(n);
      for (let t = 0; t < n; t += sr / r.range(98, 102)) pulses[Math.round(t)] = 1;
      const buzz = K.modal(pulses, sr, K.scatterModes(r, 6, 300, 2500, 0.003, 0.008, -2), n);
      const gate = new Float32Array(n);
      let on = false;
      let i = 0;
      while (i < n) {
        const len = Math.round(r.range(0.02, 0.12) * sr);
        for (let k = 0; k < len && i < n; k++, i++) gate[i] = on ? 1 : 0;
        on = !on;
      }
      const smooth = K.onePole(gate, sr, 'lowpass', 300);
      K.mul(buzz, smooth);
      K.addAt(out, K.unit(buzz), 0, 0.5);
      return K.fade(out, sr, 0.002, 0.02);
    },
  }),
];
