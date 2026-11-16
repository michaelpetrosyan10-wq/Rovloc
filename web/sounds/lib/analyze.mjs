// analyze.mjs: one rendered variant's measurement record (the metrics lib/classes.mjs names), and the check of that
// record against the universal, one-shot / loop, class and default rules.

import * as M from './measure.mjs';
import { laptop } from '../kit/filters.mjs';
import { momentaryMax, integrated, truePeak } from '../kit/loudness.mjs';
import { CLASSES, UNIVERSAL, ONE_SHOT, LOOPING, DEFAULTS, RATTLE_SIGNATURE, HIS_HIGH_SHARE } from './classes.mjs';

/**
 * @param {Float32Array[]} channels the finished render (a loop: one period)
 * @param {number} sr
 * @param {{loop: unknown}} voice
 */
export function measure(channels, sr, voice) {
  const x = M.mono(channels);
  const loud = (ch) => (voice.loop ? integrated(ch, sr) : momentaryMax(ch, sr));
  const loudness = loud(channels);
  const lap = loud(channels.map((c) => laptop(c, sr)));
  const bands = M.bandShares(x, sr);
  const tone = M.tonality(x, sr);
  const a = M.attack(x, sr);
  let p = 0;
  for (const c of channels) for (const v of c) p = Math.max(p, Math.abs(v));
  const edgeOf = (v) => (p > 0 && Math.abs(v) > 0 ? 20 * Math.log10(Math.abs(v) / p) : -200);
  const sil = M.silences(x, sr);
  const seam = voice.loop ? M.loopSeam(channels, sr) : { ratio: 0, level: 0 };
  return {
    seconds: x.length / sr,
    truePeak: truePeak(channels),
    loudness,
    laptopLoss: loudness - lap,
    bands,
    low: bands[0] + bands[1],
    lowMid: bands[1] + bands[2],
    high: bands[4] + bands[5],
    centroid: M.centroid(x, sr),
    purity: tone.purity,
    peaks: tone.peaks,
    roughness: M.roughness(x, sr),
    attack: a.attack,
    rise: a.rise,
    crest: M.crest(x),
    dc: Math.max(...channels.map((c) => Math.abs(M.dc(c)))),
    clipped: M.clipped(...channels),
    lead: sil.lead,
    tail: sil.tail,
    endLevel: voice.loop ? -200 : M.endLevel(x, sr),
    edge: voice.loop ? -200 : Math.max(...channels.flatMap((c) => [edgeOf(c[0]), edgeOf(c[c.length - 1])])),
    seamRatio: seam.ratio,
    seamLevel: seam.level,
    rattle: M.rattleIndex(x, sr),
    click: M.onsetClick(x, sr),
  };
}

const OPS = {
  '<=': (a, b) => a <= b,
  '>=': (a, b) => a >= b,
  '<': (a, b) => a < b,
  '>': (a, b) => a > b,
};

/**
 * Every rule a voice is held to, as [metric, op, threshold, why].
 * @param {import('./voices.mjs').Voice} voice
 * @returns {import('./classes.mjs').Rule[]}
 */
export function rulesFor(voice) {
  const cls = CLASSES[voice.class];
  const bright = cls.bright || voice.expect?.bright;
  const resonance = cls.resonance || voice.expect?.resonance;
  /** @type {import('./classes.mjs').Rule[]} */
  const rules = [...UNIVERSAL, ...(voice.loop ? LOOPING : ONE_SHOT), ...cls.rules];
  if (!voice.loop) {
    const max = Math.min(voice.expect?.maxSeconds ?? Infinity, cls.maxSeconds ?? (voice.space === 'baked' ? 5 : DEFAULTS.maxSeconds));
    rules.push(['seconds', '<=', max, `a one-shot of this class is at most ${max} s`]);
  }
  if (!bright) rules.push(['centroid', '<=', DEFAULTS.maxCentroid, 'only glass, sparks and keys are brighter than 3 kHz']);
  if (resonance) rules.push(['peaks', '>=', DEFAULTS.minPeaksIfResonant, 'a declared resonance shows at least 5 strong peaks']);
  else rules.push(['purity', '<=', DEFAULTS.maxPurity, 'not a beep: no single twelfth-octave band holds most of it']);
  rules.push(['loudness', '>=', voice.loudness - DEFAULTS.loudnessTolerance, 'at its reference loudness']);
  rules.push(['loudness', '<=', voice.loudness + DEFAULTS.loudnessTolerance, 'at its reference loudness']);
  if (!voice.him && (voice.class === 'breath' || voice.class === 'vocal')) rules.push(['rattle', '<', RATTLE_SIGNATURE, "only he has the throat's rattle (I1)"]);
  if (voice.him) rules.push(['high', '<=', HIS_HIGH_SHARE, 'nothing of his is bright: no dry ticking']);
  return rules;
}

/**
 * The failed rules of one record.
 * @param {ReturnType<typeof measure>} m
 * @param {import('./voices.mjs').Voice} voice
 * @returns {string[]}
 */
export function check(m, voice) {
  const failures = [];
  for (const [metric, op, threshold, why] of rulesFor(voice)) {
    const value = m[metric];
    if (!OPS[op](value, threshold)) failures.push(`${metric} ${fmt(value)} not ${op} ${threshold} (${why})`);
  }
  if (voice.him) {
    const has = {
      throat: m.rattle >= RATTLE_SIGNATURE,
      gait: m.low >= 0.3 && m.laptopLoss < 9,
    };
    if (!voice.him.some((s) => has[s])) failures.push(`none of his declared signatures measured (${voice.him.join(', ')}: rattle ${fmt(m.rattle)}, low ${fmt(m.low)}, laptop loss ${fmt(m.laptopLoss)})`);
  }
  return failures;
}

/** A number for a report line. */
export function fmt(v) {
  if (typeof v !== 'number') return String(v);
  if (!Number.isFinite(v)) return String(v);
  const a = Math.abs(v);
  return a >= 100 ? v.toFixed(0) : a >= 10 ? v.toFixed(1) : a >= 1 ? v.toFixed(2) : v.toFixed(3);
}
