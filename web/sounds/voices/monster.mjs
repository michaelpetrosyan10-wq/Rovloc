// monster.mjs: HIM. Every sound here plays only where he really is (at him, at his planned teleport spot, or as the
// Ear whisper on the true line to him: spec I1), and each carries at least one of his three signatures (docs/SOUND.md
// 1, law 7): PORCELAIN (the cracked mask: short dry high-Q ticks at 1.2-5 kHz, chattering like teeth), the THROAT (a
// wet, old breath from far too big a chest: formants scaled down to 0.5-0.6, a 20-35 Hz rattle of soft tissue in the
// exhale) and the GAIT (his-steps.mjs). Nothing else in the game uses them; 2D stingers that play at the player
// (scares.mjs) carry none.
//
// The jumpscare and the screech are a cluster of formant voices with roughness, pitch breaks and period doubling over
// a sub drop, under a metallic shriek (a bowed inharmonic plate): frightening by suddenness and density, not treble.
// The teleport is a pressure change: the vanish is a reversed swell that sucks into near silence; the arrival is a
// thud and one settling porcelain tick. The catch (NeckSnap, a death) is dull, dry and abrupt (spec I12).

import * as K from '../kit/index.mjs';

const FAMILY = 'monster';
/** His body's sounds carry like his steps. */
const CARRY = Object.freeze({ ref: 10, max: 140, rolloff: 0.9, fade: 0.7 });
/** His voice: the spec's Head channel (8 / d, silent past 90). */
const HEAD = Object.freeze({ ref: 8, max: 90, rolloff: 1, fade: 2 / 3 });
/** The screech carries through the building. */
const SCREECH = Object.freeze({ ref: 12, max: 420, rolloff: 0.8, fade: 0.75 });
/** His throat's size: formants at 0.55 of a man's (a tract almost twice as long). */
const THROAT = 0.55;

/**
 * His exhale: turbulence through a huge tract, a faint voiced creak, and the soft-palate rattle (20-35 Hz).
 * @param {number} n samples
 * @param {number} sr
 * @param {K.Rng} r
 * @param {{rattle?: number, voiced?: number, vowel?: string, scale?: number}} [spec]
 */
function exhale(n, sr, r, { rattle = 0.75, voiced = 0.35, vowel = 'uh', scale = THROAT } = {}) {
  const out = K.breath(n, sr, { rng: r, vowel: /** @type {any} */ (vowel), scale, rattle, rattleRate: r.range(22, 32), voiced, f0: r.range(38, 48) });
  return K.unit(out);
}

/**
 * His inhale: a slow pull of air, narrower, no rattle, a little whistle of the nose band.
 * @param {number} n
 * @param {number} sr
 * @param {K.Rng} r
 */
function inhale(n, sr, r) {
  const out = K.breath(n, sr, { rng: r, vowel: 'o', scale: THROAT * 1.15, rattle: 0.15, rattleRate: r.range(24, 34) });
  return K.unit(out);
}

/** A breath's envelope: in over `a`, held, out over the rest (seconds), curved. */
function swellEnv(n, sr, a, hold = 0) {
  const s = n / sr;
  return K.segments(n, sr, [[0, 0], [a, 1, -2], [a + hold, 1], [s, 0, 3]]);
}

/**
 * A metallic shriek: a bowed inharmonic plate (the friction of something dragged across steel locking onto its
 * modes), its bow pressure surging and breaking.
 * @param {number} n
 * @param {number} sr
 * @param {K.Rng} r
 * @param {{base?: number, count?: number}} [spec]
 */
function shriek(n, sr, r, { base = r.range(420, 620), count = 14 } = {}) {
  const modes = K.modesFrom(base, K.plateRatios(count, 1.29), { t60: 0.5, damp: 0.4, tilt: -2, gains: K.strikeGains(count, r.range(0.1, 0.9), r.range(0.1, 0.9)), detune: 0.03, rng: r });
  const surge = K.smoothRandom(n, sr, 9, r.fork('surge'), 0.2, 1);
  const vel = new Float32Array(n);
  const force = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    vel[i] = 0.6 + 0.8 * surge[i];
    force[i] = 0.5 + 0.9 * (1 - surge[i]);
  }
  const out = K.bowed(n, sr, { modes, velocity: vel, force, coupling: 0.7, stiffness: 2200, irregularity: 0.4, rng: r.fork('bow') });
  return K.unit(K.butter(out, sr, 'lowpass', 3800, 2));
}

/**
 * The scream cluster: `count` formant voices at different sizes and pitches, each breaking in pitch and doubling its
 * period, roughened, noise bursting through.
 * @param {number} n
 * @param {number} sr
 * @param {K.Rng} r
 * @param {{count?: number, f0?: [number, number], scale?: [number, number], rough?: number}} [spec]
 */
function cluster(n, sr, r, { count = 4, f0 = [150, 330], scale = [0.55, 0.85], rough = 0.6 } = {}) {
  const out = new Float32Array(n);
  const s = n / sr;
  for (let k = 0; k < count; k++) {
    const v = r.fork(`voice${k}`);
    const base = v.range(f0[0], f0[1]);
    // each voice climbs, cracks and sags; the period doubling comes and goes
    const pitch = K.segments(n, sr, [[0, base * 0.7], [0.08, base * v.range(1.05, 1.25), -3], [s * 0.6, base * v.range(0.9, 1.1)], [s, base * v.range(0.55, 0.75)]]);
    const breaks = [];
    for (let b = 0; b < v.int(1, 3); b++) breaks.push({ at: v.range(0.1, s * 0.8), length: v.range(0.04, 0.15), ratio: v.pick([0.5, 0.66, 1.5, 1.33]) });
    const sub = K.smoothRandom(n, sr, 4, v.fork('sub'), 0, 0.9);
    const chaos = K.smoothRandom(n, sr, 3, v.fork('chaos'), 0.05, 0.35);
    const voice = K.scream(n, sr, { rng: v, f0: pitch, path: [[0, 'a'], [s * 0.4, v.pick(['ae', 'a', 'o'])], [s, 'uh']], scale: v.range(scale[0], scale[1]), breaks, chaos, sub, rough, roughRate: v.range(45, 90) });
    K.addAt(out, K.unit(voice), 0, v.range(0.6, 1));
  }
  return K.unit(out);
}

/**
 * The pressure drop under a scare: a sub sine falling from f0 to f1 (allowed: under 110 Hz), saturated so a laptop
 * plays its harmonics.
 * @param {number} sr
 * @param {number} seconds
 * @param {number} [f0]
 * @param {number} [f1]
 */
function subDrop(sr, seconds, f0 = 75, f1 = 30) {
  return K.unit(K.thump(sr, { f0, f1, drop: seconds / 3, t60: seconds, attack: 0.003, drive: 3, bias: 0.3, length: seconds * 1.1 }));
}

/** A tiny breath of "air pushed aside": a fast swept noise (a big body moving fast past you). */
function displacement(sr, r, seconds) {
  const n = Math.round(seconds * sr);
  const arc = K.segments(n, sr, [[0, 0], [seconds * 0.35, 1, -2], [seconds, 0, 3]]);
  const centre = new Float32Array(n);
  for (let i = 0; i < n; i++) centre[i] = 180 + 700 * arc[i];
  const out = K.svf(K.pink(n, r), sr, 'bandpass', centre, 0.8);
  K.mul(out, arc);
  return K.unit(out);
}

/**
 * @param {Partial<import('../lib/voices.mjs').Voice> & Pick<import('../lib/voices.mjs').Voice, 'name'|'title'|'description'|'class'|'render'>} v
 * @returns {import('../lib/voices.mjs').Voice}
 */
function his(v) {
  return /** @type {import('../lib/voices.mjs').Voice} */ ({ family: FAMILY, group: 'reference', variants: 3, channels: 1, loop: null, space: 'dry', carry: CARRY, board: 'Him', ...v });
}

/** @type {import('../lib/voices.mjs').Voice[]} */
export const voices = [
  his({
    name: 'CreatureGrowl',
    title: 'His growl',
    description: 'Low in his chest, swelling: it comes while he is chasing you.',
    class: 'vocal',
    him: ['throat', 'porcelain'],
    variants: 4,
    loudness: -16,
    render: ({ sr, rng }) => {
      const s = rng.range(1.3, 1.6);
      const n = Math.round(s * sr);
      const r = rng.fork('growl');
      const f0 = K.segments(n, sr, [[0, r.range(40, 46)], [s * 0.5, r.range(56, 66), -2], [s, r.range(42, 48)]]);
      const g = K.growl(n, sr, { rng: r, f0, path: [[0, 'o'], [s * 0.45, 'a'], [s, 'uh']], scale: THROAT, sub: 0.6, rough: 0.7, roughRate: r.range(36, 48), noise: 0.4 });
      K.mul(K.unit(g), swellEnv(n, sr, s * 0.45));
      const out = K.unit(g);
      const ex = exhale(Math.round(0.8 * sr), sr, r.fork('out'), { rattle: 0.85 });
      K.mul(ex, swellEnv(ex.length, sr, 0.15));
      K.addAt(out, ex, (s - 0.6) * sr, 0.35);
      K.addAt(out, K.chatter(n, sr, r.fork('mask'), { rate: 6, from: s * 0.3, to: s * 0.9 }), 0, 0.12);
      return K.fade(K.densify(out, sr, 15), sr, 0.01, 0.08);
    },
  }),
  his({
    name: 'CreatureSniff',
    title: 'Him sniffing at your hiding place',
    description: 'Short, greedy pulls of air right outside the locker, then a long wet breath out: he is smelling for you.',
    class: 'breath',
    him: ['throat'],
    variants: 1,
    loop: { seconds: 10, crossfade: 0.5 },
    loudness: -22,
    carry: Object.freeze({ ref: 4, max: 46, rolloff: 1, fade: 0.67 }),
    render: ({ sr, rng, seconds }) => {
      const n = Math.round(seconds * sr);
      const out = new Float32Array(n);
      const r = rng.fork('sniffs');
      let t = 0.3;
      while (t < seconds - 0.2) {
        // a run of 3-5 sniffs through a huge nose: narrow, bright-ish turbulence bursts
        const count = r.int(3, 5);
        for (let k = 0; k < count; k++) {
          const len = r.range(0.07, 0.13);
          const sn = Math.round(len * sr);
          const nose = K.svf(K.pink(sn, r.fork(`n${t.toFixed(2)}${k}`)), sr, 'bandpass', r.range(700, 1300), 1.6);
          const body = K.breath(sn, sr, { rng: r.fork(`b${t.toFixed(2)}${k}`), vowel: 'i', scale: THROAT * 1.3 });
          K.unit(nose);
          K.unit(body);
          const e = K.segments(sn, sr, [[0, 0], [len * 0.25, 1, -2], [len, 0, 2]]);
          for (let i = 0; i < sn; i++) nose[i] = (0.6 * nose[i] + body[i]) * e[i];
          K.addAt(out, nose, t * sr, r.range(0.6, 1));
          t += len + r.range(0.04, 0.09);
        }
        // the long wet breath out, rattling
        const exLen = r.range(1.1, 1.7);
        const ex = exhale(Math.round(exLen * sr), sr, r.fork(`x${t.toFixed(2)}`), { rattle: 0.85, voiced: 0.3 });
        K.mul(ex, swellEnv(ex.length, sr, 0.25, exLen * 0.2));
        K.addAt(out, ex, (t + 0.15) * sr, 0.7);
        t += exLen + r.range(0.6, 1.4);
      }
      return out;
    },
  }),
  his({
    name: 'CreatureVanish',
    title: 'Him vanishing',
    description: 'The air pulls in toward where he stood, his breath and the mask sucked backwards into a sudden hush.',
    class: 'swell',
    him: ['throat'],
    loudness: -20,
    render: ({ sr, rng }) => {
      const r = rng.fork('vanish');
      // a hit of him (a thud, a rattling breath, the mask) rung into the basement, then played backwards
      const hit = new Float32Array(Math.round(0.9 * sr));
      K.addAt(hit, subDrop(sr, 0.4, 70, 40), 0, 0.6);
      const ex = exhale(Math.round(0.7 * sr), sr, r.fork('breath'), { rattle: 0.9, voiced: 0.5 });
      K.mul(ex, K.segments(ex.length, sr, [[0, 0], [0.03, 1], [0.7, 0, 3]]));
      K.addAt(hit, ex, 0, 1);
      K.addAt(hit, K.chatter(hit.length, sr, r.fork('mask'), { rate: 14, from: 0, to: 0.3 }), 0, 0.3);
      const [wet] = K.place(hit, sr, K.SPACES.basement, { wet: 0.75, darken: 2500, rng: r.fork('space') });
      const back = K.reverse(K.trimTail(wet, sr, -60, 0.01));
      // his breath drawn backwards into him, dry and close, rattling (the last thing you hear of him)
      const pull = exhale(Math.round(1.6 * sr), sr, r.fork('pull'), { rattle: 1, voiced: 0.5 });
      K.mul(pull, K.segments(pull.length, sr, [[0, 0], [0.05, 1], [1.6, 0, 2]]));
      K.addAt(back, K.reverse(pull), back.length - pull.length, 1.3);
      // the suck: once it peaks it is gone in 60 ms, then the hush (the next beat is silence)
      const at = back.length;
      const out = new Float32Array(at + Math.round(0.15 * sr));
      out.set(back);
      const tail = Math.round(0.06 * sr);
      for (let i = 0; i < tail; i++) out[at - tail + i] *= Math.exp((-6 * i) / tail);
      return K.fade(out.subarray(Math.max(0, at - Math.round(2.6 * sr))).slice(), sr, 0.05, 0.004);
    },
  }),
  his({
    name: 'CreatureArrive',
    title: 'Him arriving',
    description: 'Out of the silence he lands where you did not expect him: a heavy thud that shakes the floor, one tick of the mask settling.',
    class: 'heavy',
    him: ['gait', 'porcelain'],
    loudness: -16,
    render: ({ sr, rng }) => {
      const r = rng.fork('arrive');
      const land = K.footfall(sr, r.fork('land'), {
        length: 1.6,
        heel: { delay: r.range(0.02, 0.035), gain: -4, cutoff: 900, length: 0.006 },
        thump: { f0: 55, f1: 34, drop: 0.09, t60: 0.7, drive: 3.5, gain: -7 },
        body: { modes: K.scatterModes(r, 8, 110, 460, 0.12, 0.3, -1), gain: 0, excite: 0.008, cutoff: 1400 },
        contact: { length: 0.02, cutoff: 1000, gain: -4 },
        after: { buffer: exhale(Math.round(0.9 * sr), sr, r.fork('breath'), { rattle: 0.8 }), gain: -16, offset: r.range(0.35, 0.5) },
      });
      const out = K.densify(land, sr, 15);
      // one settling tick of the mask
      K.addAt(out, K.porcelainTick(sr, r.fork('tick'), { freq: r.range(1800, 2600), t60: 0.04, hardness: 0.6 }), r.range(0.28, 0.42) * sr, 0.25);
      return out;
    },
  }),
  his({
    name: 'TeleportHiss',
    title: 'Where he is about to appear',
    description: 'The air at one spot thickening: a low pressure building, a hiss rising, the mask chattering faster and faster.',
    class: 'swell',
    him: ['porcelain'],
    variants: 2,
    loudness: -20,
    carry: Object.freeze({ ref: 6, max: 90, rolloff: 1, fade: 0.67 }),
    render: ({ sr, rng }) => {
      const s = 2.4;
      const n = Math.round(s * sr);
      const r = rng.fork('warn');
      const grow = K.segments(n, sr, [[0, 0], [s * 0.92, 1, -2.5], [s, 0, 2]]);
      const centre = new Float32Array(n);
      for (let i = 0; i < n; i++) centre[i] = 250 + 1300 * grow[i];
      const hiss = K.unit(K.svf(K.pink(n, r.fork('hiss')), sr, 'bandpass', centre, 1.1));
      const rumble = K.unit(K.svf(K.brown(n, sr, r.fork('rumble')), sr, 'lowpass', 90, 0.8));
      const out = new Float32Array(n);
      for (let i = 0; i < n; i++) out[i] = (0.6 * hiss[i] + rumble[i]) * grow[i];
      // the mask, faster and faster as he comes through
      K.addAt(out, K.chatter(n, sr, r.fork('mask'), { rate: 18, from: 0.2, to: s - 0.1, density: (t) => (t / s) ** 2 }), 0, 0.35);
      return K.fade(out, sr, 0.05, 0.08);
    },
  }),
  his({
    name: 'Lunge',
    title: 'Him lunging at you',
    description: 'The air shoved aside, one enormous step, the mask clattering and a roar torn out of him: he has you.',
    class: 'body',
    him: ['gait', 'porcelain', 'throat'],
    loudness: -12,
    carry: Object.freeze({ ref: 10, max: 200, rolloff: 0.9, fade: 0.7 }),
    render: ({ sr, rng }) => {
      const r = rng.fork('lunge');
      const out = new Float32Array(Math.round(1.3 * sr));
      const step = K.footfall(sr, r.fork('step'), {
        length: 1.0,
        thump: { f0: 62, f1: 38, drop: 0.06, t60: 0.45, drive: 3.5, gain: -8 },
        body: { modes: K.scatterModes(r, 8, 120, 460, 0.1, 0.22, -1), gain: 0, excite: 0.005, cutoff: 2200 },
        contact: { length: 0.012, cutoff: 2200, gain: -2 },
      });
      K.addAt(out, step, 0, 1);
      K.addAt(out, displacement(sr, r.fork('air'), 0.25), 0, 0.5);
      const rn = Math.round(0.7 * sr);
      const roar = K.growl(rn, sr, { rng: r.fork('roar'), f0: K.segments(rn, sr, [[0, 60], [0.12, 95, -3], [0.7, 55]]), path: [[0, 'a'], [0.7, 'o']], scale: THROAT * 1.1, sub: 0.7, rough: 0.8, roughRate: 55, noise: 0.5 });
      K.mul(K.unit(roar), K.segments(rn, sr, [[0, 0], [0.04, 1, -2], [0.7, 0, 2]]));
      K.addAt(out, roar, 0.04 * sr, 0.7);
      K.addAt(out, K.chatter(out.length, sr, r.fork('mask'), { rate: 20, from: 0.01, to: 0.35 }), 0, 0.3);
      return K.densify(out, sr, 12);
    },
  }),
  his({
    name: 'NeckSnap',
    title: 'Caught',
    description: 'He has you: a dull, dry knock and a jolt, and the mask right against you. Then nothing.',
    class: 'body',
    him: ['porcelain'],
    loudness: -15.5,
    render: ({ sr, rng }) => {
      const r = rng.fork('catch');
      // a grab and a heavy dull knock: the impact of being slammed, not anything breaking open
      const knock = K.footfall(sr, r.fork('knock'), {
        length: 0.7,
        thump: { f0: 80, f1: 50, drop: 0.03, t60: 0.22, drive: 3, gain: -4 },
        body: { modes: K.scatterModes(r, 6, 160, 700, 0.03, 0.08, -1), gain: 0, excite: 0.003, cutoff: 1800 },
        contact: { length: 0.006, cutoff: 1500, gain: -2 },
      });
      const out = K.densify(knock, sr, 11);
      // a dry crack, short and muffled (a joint giving, heard through cloth): a damped wooden-ish snap
      const snap = K.modal(K.burst(sr, r.fork('snap'), { length: 0.0008, cutoff: 6000, hp: 300 }), sr, K.scatterModes(r, 6, 600, 2400, 0.008, 0.02, -2), Math.round(0.06 * sr));
      K.addAt(out, K.unit(K.butter(snap, sr, 'lowpass', 2500, 2)), r.range(0.015, 0.03) * sr, 0.35);
      K.addAt(out, K.chatter(out.length, sr, r.fork('mask'), { rate: 12, from: 0, to: 0.1 }), 0, 0.2);
      return out;
    },
  }),
  his({
    name: 'Screech',
    title: 'His screech',
    description: 'The scream he lets out when the chase starts: many throats at once, cracking and doubling, over a metal shriek and a drop you feel in your chest.',
    class: 'vocal',
    him: ['throat', 'porcelain'],
    loudness: -11,
    carry: SCREECH,
    render: ({ sr, rng }) => {
      const s = rng.range(1.4, 1.8);
      const n = Math.round(s * sr);
      const r = rng.fork('screech');
      const out = new Float32Array(n);
      const voices = cluster(n, sr, r.fork('cluster'), { count: 4, f0: [140, 300], scale: [0.5, 0.75], rough: 0.65 });
      const env = K.segments(n, sr, [[0, 0], [0.025, 1, -3], [s * 0.55, 0.85], [s, 0, 2]]);
      K.mul(voices, env);
      K.addAt(out, voices, 0, 1);
      const steel = shriek(n, sr, r.fork('steel'));
      K.mul(steel, env);
      K.addAt(out, steel, 0, 0.35);
      K.addAt(out, subDrop(sr, s * 0.8, 70, 32), 0, 0.55);
      // the breath that ends it, rattling, and the mask shaking with it
      const ex = exhale(Math.round(0.6 * sr), sr, r.fork('out'), { rattle: 0.95, voiced: 0.6 });
      K.mul(ex, K.segments(ex.length, sr, [[0, 0], [0.05, 1], [0.6, 0, 2]]));
      K.addAt(out, ex, (s - 0.55) * sr, 0.45);
      K.addAt(out, K.chatter(n, sr, r.fork('mask'), { rate: 10, from: 0, to: s * 0.8 }), 0, 0.18);
      return K.densify(out, sr, 11);
    },
  }),
  his({
    name: 'JumpscareSting',
    title: 'His face in yours',
    description: 'The catch, up close: his screaming throats and the shrieking metal all at once over a drop through the floor.',
    class: 'stinger',
    him: ['throat', 'porcelain'],
    channels: 2,
    space: 'baked',
    loudness: -9,
    board: 'Scares',
    render: ({ sr, rng }) => {
      const s = rng.range(1.5, 1.8);
      const n = Math.round(s * sr);
      const r = rng.fork('jumpscare');
      const left = new Float32Array(n);
      const right = new Float32Array(n);
      const env = K.segments(n, sr, [[0, 0], [0.008, 1, -4], [s * 0.5, 0.8], [s, 0, 2]]);
      // the cluster spread across the head: each throat its own place
      for (let k = 0; k < 5; k++) {
        const v = cluster(n, sr, r.fork(`c${k}`), { count: 2, f0: [130 + 30 * k, 230 + 50 * k], scale: [0.5, 0.8], rough: 0.7 });
        K.mul(v, env);
        const [l, rr] = K.pan(v, -0.8 + 0.4 * k);
        K.addAt(left, l, 0, 0.6);
        K.addAt(right, rr, 0, 0.6);
      }
      const steel = shriek(n, sr, r.fork('steel'), { base: r.range(380, 520), count: 16 });
      K.mul(steel, env);
      const drop = subDrop(sr, s, 80, 28);
      const mask = K.chatter(n, sr, r.fork('mask'), { rate: 16, from: 0, to: s * 0.6 });
      const ex = exhale(Math.round(0.5 * sr), sr, r.fork('out'), { rattle: 0.95, voiced: 0.6 });
      K.mul(ex, K.segments(ex.length, sr, [[0, 0], [0.04, 1], [0.5, 0, 2]]));
      for (const [ch, side] of [[left, -1], [right, 1]]) {
        K.addAt(ch, steel, 0, 0.3);
        K.addAt(ch, drop, 0, 0.6);
        K.addAt(ch, mask, side * 0.0004 * sr + 0.0004 * sr, 0.15);
        K.addAt(ch, ex, (s - 0.5) * sr, 0.35);
      }
      const p = K.peak(left, right);
      return [K.densify(K.gain(left, 1 / p), sr, 9), K.densify(K.gain(right, 1 / p), sr, 9)];
    },
  }),
  his({
    name: 'RevealSting',
    title: 'Him, right there',
    description: 'You turn and he is in front of you: a crack of the mask, a scrape of steel and a drop under your feet.',
    class: 'stinger',
    him: ['porcelain'],
    channels: 2,
    space: 'baked',
    loudness: -11,
    board: 'Scares',
    render: ({ sr, rng }) => {
      const s = 1.4;
      const n = Math.round(s * sr);
      const r = rng.fork('reveal');
      const mono = new Float32Array(n);
      const env = K.segments(n, sr, [[0, 0], [0.006, 1, -4], [s, 0, 3]]);
      const steel = shriek(n, sr, r.fork('steel'), { base: r.range(300, 420) });
      K.mul(steel, env);
      K.addAt(mono, steel, 0, 0.5);
      K.addAt(mono, subDrop(sr, s, 85, 30), 0, 0.5);
      const choke = cluster(n, sr, r.fork('choke'), { count: 3, f0: [90, 160], scale: [0.5, 0.65], rough: 0.8 });
      K.mul(choke, K.segments(n, sr, [[0, 0], [0.01, 1, -3], [0.6, 0, 2]]));
      K.addAt(mono, choke, 0, 0.45);
      K.addAt(mono, K.chatter(n, sr, r.fork('mask'), { rate: 12, from: 0, to: 0.6 }), 0, 0.45);
      K.addAt(mono, K.porcelainTick(sr, r.fork('crack'), { freq: 1500, t60: 0.06, hardness: 1, crack: 1 }), 0, 0.6);
      const dense = K.densify(mono, sr, 10);
      const [l, rr] = K.pan(dense, -0.15);
      const wide = K.delayed(dense, sr, 0.011).subarray(0, n);
      for (let i = 0; i < n; i++) rr[i] = 0.75 * rr[i] + 0.25 * wide[i];
      return [l, rr];
    },
  }),
  his({
    name: 'VentBreathing',
    title: 'Him breathing in the vents',
    description: 'Slow, enormous breaths inside the metal ducts, the steel humming with them, a wet rattle in every breath out.',
    class: 'breath',
    him: ['throat'],
    variants: 1,
    loop: { seconds: 12, crossfade: 1 },
    loudness: -24,
    carry: Object.freeze({ ref: 6, max: 130, rolloff: 0.9, fade: 0.7 }),
    render: ({ sr, rng, seconds }) => {
      const n = Math.round(seconds * sr);
      const out = new Float32Array(n);
      const r = rng.fork('vent');
      let t = 0.2;
      while (t < seconds) {
        const inLen = r.range(1.4, 2.0);
        const exLen = r.range(2.0, 2.8);
        const a = inhale(Math.round(inLen * sr), sr, r.fork(`i${t.toFixed(2)}`));
        K.mul(a, swellEnv(a.length, sr, inLen * 0.7));
        K.addAt(out, a, t * sr, 0.5);
        const b = exhale(Math.round(exLen * sr), sr, r.fork(`e${t.toFixed(2)}`), { rattle: 0.85, voiced: 0.4 });
        K.mul(b, swellEnv(b.length, sr, 0.3, exLen * 0.25));
        K.addAt(out, b, (t + inLen + 0.1) * sr, 0.9);
        t += inLen + exLen + r.range(0.4, 1.0);
      }
      // the duct: a sheet-steel tube around it (a short comb and the panels' low modes)
      const duct = K.comb(out, sr, { delay: 0.0052, feedback: 0.35, damp: 0.4 });
      const panels = K.modal(out, sr, K.scatterModes(r, 6, 120, 600, 0.08, 0.16, -1), n);
      K.unit(duct);
      K.unit(panels);
      for (let i = 0; i < n; i++) duct[i] += 0.25 * panels[i];
      return duct;
    },
  }),
  his({
    name: 'VentScrape',
    title: 'Him dragging himself through the vents',
    description: 'Something huge hauling itself along a metal duct: the steel groaning and booming, the mask scraping the walls.',
    class: 'friction',
    him: ['porcelain'],
    variants: 1,
    loop: { seconds: 12, crossfade: 0.8 },
    loudness: -22,
    carry: Object.freeze({ ref: 10, max: 180, rolloff: 0.9, fade: 0.7 }),
    render: ({ sr, rng, seconds }) => {
      const n = Math.round(seconds * sr);
      const out = new Float32Array(n);
      const r = rng.fork('drag');
      // hauls: every 1-2 s a push, the steel bowed by his weight sliding
      const push = new Float32Array(n);
      const force = new Float32Array(n);
      let t = 0.1;
      const knocks = [];
      while (t < seconds) {
        const len = r.range(0.5, 1.0);
        const a = Math.round(t * sr);
        const b = Math.min(n, Math.round((t + len) * sr));
        for (let i = a; i < b; i++) push[i] = Math.sin((Math.PI * (i - a)) / (b - a)) ** 1.5 * r.range(0.9, 1.1);
        knocks.push(t);
        t += len + r.range(0.4, 1.0);
      }
      const wobble = K.smoothRandom(n, sr, 6, r.fork('w'), 0.6, 1.4);
      for (let i = 0; i < n; i++) force[i] = 0.9 * wobble[i];
      const panel = K.modesFrom(r.range(140, 190), K.plateRatios(16, 1.618), { t60: 0.35, damp: 0.5, tilt: -3, detune: 0.03, rng: r });
      const steel = K.bowed(n, sr, { modes: panel, velocity: push, force, coupling: 0.5, stiffness: 600, irregularity: 0.6, rng: r.fork('bow') });
      K.addAt(out, K.unit(K.butter(steel, sr, 'lowpass', 2200, 2)), 0, 0.7);
      // a palm or a knee coming down on the panel at the start of each haul: a sheet-steel boom
      for (const k of knocks) {
        const boom = K.modal(K.burst(sr, r.fork(`k${k.toFixed(2)}`), { length: 0.008, cutoff: 700 }), sr, K.modesFrom(r.range(70, 90), K.plateRatios(12, 1.618), { t60: 0.6, damp: 0.6, tilt: -4, detune: 0.02, rng: r }), Math.round(0.8 * sr));
        K.addAt(out, K.unit(boom), k * sr, 0.8);
      }
      // the mask scraping the duct wall during the hauls
      const mask = K.chatter(n, sr, r.fork('mask'), { rate: 7, from: 0, to: seconds, density: (x) => push[Math.min(n - 1, Math.round(x * sr))] });
      K.addAt(out, mask, 0, 0.3);
      return out;
    },
  }),
  his({
    name: 'CreatureGrunt',
    title: 'His grunt',
    description: 'A short, low grunt from deep in his chest, the breath rattling out after it: he is about to turn.',
    class: 'vocal',
    him: ['throat'],
    variants: 4,
    loudness: -20,
    carry: HEAD,
    render: ({ sr, rng }) => {
      const s = rng.range(0.55, 0.75);
      const n = Math.round(s * sr);
      const r = rng.fork('grunt');
      const g = K.growl(n, sr, { rng: r, f0: K.segments(n, sr, [[0, r.range(50, 58)], [s, r.range(38, 44)]]), path: [[0, 'uh'], [s, 'o']], scale: THROAT, sub: 0.75, rough: 0.75, roughRate: r.range(32, 42), noise: 0.35 });
      K.mul(K.unit(g), K.segments(n, sr, [[0, 0], [0.025, 1, -3], [s * 0.4, 0.8], [s, 0, 2]]));
      const out = new Float32Array(Math.round((s + 0.7) * sr));
      K.addAt(out, g, 0, 1);
      const ex = exhale(Math.round(0.8 * sr), sr, r.fork('out'), { rattle: 0.9, voiced: 0.4 });
      K.mul(ex, K.segments(ex.length, sr, [[0, 0], [0.05, 1], [0.8, 0, 3]]));
      K.addAt(out, ex, (s - 0.15) * sr, 0.55);
      return K.densify(out, sr, 18);
    },
  }),
  his({
    name: 'CreatureRattle',
    title: 'The rattle in his throat',
    description: 'A slow wet breath out of a chest far too big, the throat rattling with it and the mask shivering: he is close.',
    class: 'breath',
    him: ['throat', 'porcelain'],
    variants: 4,
    loudness: -20,
    carry: Object.freeze({ ref: 6, max: 55, rolloff: 1, fade: 0.67 }),
    render: ({ sr, rng }) => {
      const s = rng.range(1.4, 1.9);
      const n = Math.round(s * sr);
      const r = rng.fork('rattle');
      const ex = exhale(n, sr, r.fork('out'), { rattle: 0.95, voiced: 0.45, vowel: r.pick(['uh', 'o']) });
      K.mul(ex, swellEnv(n, sr, 0.3, s * 0.3));
      const out = K.unit(ex);
      K.addAt(out, K.chatter(n, sr, r.fork('mask'), { rate: 7, from: 0.45, to: s * 0.75 }), 0, 0.15);
      return out;
    },
  }),
  his({
    name: 'VoiceThroat',
    title: 'His voice, under his words',
    description: 'The breathy growl that carries every word he says: a huge throat working, wet and rough.',
    class: 'vocal',
    him: ['throat'],
    variants: 1,
    loop: { seconds: 10, crossfade: 0.5 },
    loudness: -20,
    carry: HEAD,
    render: ({ sr, rng, seconds }) => {
      const n = Math.round(seconds * sr);
      const r = rng.fork('throat');
      const f0 = K.smoothRandom(n, sr, 2.5, r.fork('pitch'), 46, 62);
      const names = /** @type {const} */ (['o', 'uh', 'a', 'u', 'o', 'ae']);
      /** @type {Array<[number, any]>} */
      const path = [];
      for (let t = 0; t < seconds; t += r.range(0.18, 0.35)) path.push([t, r.pick(names)]);
      const g = K.growl(n, sr, { rng: r.fork('growl'), f0, path, scale: THROAT * 1.05, sub: 0.55, rough: 0.6, roughRate: r.range(30, 40), noise: 0.7 });
      const ex = K.breath(n, sr, { rng: r.fork('air'), vowel: 'uh', scale: THROAT, rattle: 0.8, rattleRate: 27 });
      const out = K.unit(g);
      K.addAt(out, K.unit(ex), 0, 0.5);
      return out;
    },
  }),
  his({
    name: 'VoiceWhisper',
    title: 'His whisper',
    description: 'The whisper that doubles his words, close to your ear: syllables you almost understand, breathed through a wet throat.',
    class: 'breath',
    him: ['throat'],
    variants: 1,
    loop: { seconds: 10, crossfade: 0.5 },
    loudness: -24,
    carry: Object.freeze({ ref: 2.5, max: 10, rolloff: 1, fade: 0.67 }),
    render: ({ sr, rng, seconds }) => {
      const n = Math.round(seconds * sr);
      const r = rng.fork('whisper');
      const words = K.babble(n, sr, { rng: r.fork('words'), rate: 4, scale: THROAT * 1.35, hiss: 0.18 });
      const wet = K.flutter(n, sr, { rate: 26, depth: 0.85, rng: r.fork('wet') });
      for (let i = 0; i < n; i++) words[i] *= wet[i];
      return K.butter(K.unit(words), sr, 'lowpass', 4500, 2);
    },
  }),
  his({
    name: 'KeyJingle',
    title: 'His keys',
    description: 'A heavy ring of keys at his hip, swinging with every step: you will hear him coming across the rooftops.',
    class: 'keys',
    him: ['porcelain'],
    repeats: true,
    variants: 5,
    loudness: -22,
    render: ({ sr, rng }) => {
      const r = rng.fork('keys');
      const out = new Float32Array(Math.round(0.45 * sr));
      const count = r.int(4, 6);
      for (let k = 0; k < count; k++) {
        // each key a small steel bar struck by its neighbour
        const key = r.fork(`k${k}`);
        const strike = K.burst(sr, key, { length: 0.0006, attack: 0.00005, cutoff: 14000, hp: 800 });
        const bar = K.modal(strike, sr, K.modesFrom(key.range(1900, 4200), K.BAR.slice(0, 5), { t60: key.range(0.04, 0.09), damp: 0.7, tilt: -2, detune: 0.03, rng: key }), Math.round(0.2 * sr));
        K.addAt(out, K.unit(bar), key.range(0, 0.12) * sr, key.range(0.4, 1));
      }
      // the heavy ring and the clip knocking under them
      K.addAt(out, K.unit(K.modal(K.burst(sr, r.fork('ring'), { length: 0.002, cutoff: 4000, hp: 200 }), sr, K.scatterModes(r, 5, 700, 1800, 0.02, 0.05, -2), Math.round(0.1 * sr))), 0, 0.5);
      return out;
    },
  }),
  his({
    name: 'CrawlerClick',
    title: 'Clicking in the crate',
    description: 'Something small and hard clicking inside a crate, like teeth: pieces of porcelain moving on their own.',
    class: 'porcelain',
    him: ['porcelain'],
    repeats: true,
    variants: 4,
    loudness: -26,
    board: 'Story',
    carry: Object.freeze({ ref: 4, max: 60, rolloff: 1, fade: 0.67 }),
    render: ({ sr, rng }) => {
      const n = Math.round(0.45 * sr);
      return K.chatter(n, sr, rng.fork('crawl'), { rate: 16, from: 0, to: 0.25, cluster: [3, 6], spacing: [0.012, 0.045], freq: [1700, 4800], t60: [0.012, 0.035] });
    },
  }),
  his({
    name: 'MaskCrack',
    title: 'The mask cracking',
    description: 'A dry crack running through porcelain, the pieces knocking against each other, a dull knock of the head under it.',
    class: 'porcelain',
    him: ['porcelain'],
    loudness: -21,
    board: 'Story',
    render: ({ sr, rng }) => {
      const r = rng.fork('crack');
      const out = new Float32Array(Math.round(0.6 * sr));
      K.addAt(out, K.porcelainTick(sr, r.fork('main'), { freq: r.range(1300, 1800), t60: 0.07, hardness: 1, crack: 1 }), 0, 1);
      K.addAt(out, K.chatter(out.length, sr, r.fork('pieces'), { rate: 30, from: 0.005, to: 0.12, cluster: [2, 3] }), 0, 0.5);
      const head = K.modal(K.burst(sr, r.fork('head'), { length: 0.004, cutoff: 900 }), sr, K.scatterModes(r, 4, 150, 450, 0.03, 0.06, -1), Math.round(0.2 * sr));
      K.addAt(out, K.unit(head), 0.001 * sr, 0.5);
      return out;
    },
  }),
  his({
    name: 'MaskClatter',
    title: 'The mask falling',
    description: 'The porcelain mask hitting the roof and tumbling: two hard clacks and a skitter.',
    class: 'porcelain',
    him: ['porcelain'],
    variants: 2,
    loudness: -20,
    board: 'Story',
    render: ({ sr, rng }) => {
      const r = rng.fork('fall');
      const out = new Float32Array(Math.round(1.4 * sr));
      let t = 0;
      let gap = r.range(0.28, 0.4);
      let level = 1;
      for (let k = 0; k < 5 && level > 0.08; k++) {
        const b = r.fork(`b${k}`);
        K.addAt(out, K.porcelainTick(sr, b, { freq: b.range(1250, 2200), t60: b.range(0.04, 0.08), hardness: 0.9, crack: 0.6 }), t * sr, level);
        const thud = K.modal(K.burst(sr, b.fork('roof'), { length: 0.003, cutoff: 1500 }), sr, K.scatterModes(b, 4, 200, 700, 0.02, 0.05, -2), Math.round(0.12 * sr));
        K.addAt(out, K.unit(thud), t * sr, level * 0.5);
        t += gap;
        gap *= b.range(0.45, 0.65);
        level *= b.range(0.5, 0.7);
      }
      // the last skitter as it settles, rocking on its rim
      K.addAt(out, K.chatter(Math.round(0.4 * sr), sr, r.fork('rock'), { rate: 20, from: 0, to: 0.2, cluster: [3, 5], spacing: [0.02, 0.05] }), t * sr, 0.25);
      return out;
    },
  }),
  his({
    name: 'WetBreath',
    title: 'A wet breath in the dark',
    description: 'A long, wet, shuddering breath from something that should not be breathing: the first sound he makes.',
    class: 'breath',
    him: ['throat'],
    variants: 2,
    loudness: -20,
    board: 'Story',
    render: ({ sr, rng }) => {
      const r = rng.fork('wet');
      const inLen = r.range(0.9, 1.2);
      const exLen = r.range(1.1, 1.4);
      const out = new Float32Array(Math.round((inLen + exLen + 0.2) * sr));
      // a shuddering pull of air (it catches 6-9 times a second)
      const a = inhale(Math.round(inLen * sr), sr, r.fork('in'));
      const shudder = new Float32Array(a.length);
      const rate = r.range(6, 9);
      for (let i = 0; i < a.length; i++) shudder[i] = 0.55 + 0.45 * Math.sin((2 * Math.PI * rate * i) / sr) ** 2;
      K.mul(a, shudder);
      K.mul(a, swellEnv(a.length, sr, inLen * 0.6));
      K.addAt(out, a, 0, 0.7);
      const b = exhale(Math.round(exLen * sr), sr, r.fork('out'), { rattle: 0.95, voiced: 0.5 });
      K.mul(b, swellEnv(b.length, sr, 0.2, exLen * 0.3));
      K.addAt(out, b, (inLen + 0.05) * sr, 1);
      return out;
    },
  }),
];
