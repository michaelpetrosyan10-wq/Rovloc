// classes.mjs: the audit's classes and their numeric rules (docs/SOUND.md 3 prints this table). A voice declares its
// class; the audit measures every variant (lib/measure.mjs) and holds it to the universal rules plus its class's.
// A rule is [metric, op, threshold, why]; metrics are the fields of the audit's measurement record:
//
//   seconds, truePeak (dBTP), loudness (LUFS: one-shots the loudest 400 ms, loops integrated), laptopLoss (dB lost
//   through the laptop filter), low (energy share under 250 Hz), lowMid (80-800 Hz), high (over 2.5 kHz), centroid
//   (Hz), purity and peaks (tonality over the sustain), roughness (30-150 Hz envelope modulation), attack (s: the rise
//   of the first strong transient), rise (s: 10-90 % of the loudest 10 ms),
//   crest (dB), dc, clipped (samples), lead and tail (s of silence), endLevel (dB of the last 5 ms re: the peak),
//   edge (dB of the first / last sample re: the peak), seamRatio and seamLevel (loops), variantMin (dB, the closest
//   two variants), rattle (his throat's 20-35 Hz rattle index), porcelain (ticks counted at 1.2-5 kHz).

/** @typedef {[string, '<='|'>='|'<'|'>', number, string]} Rule */
/** @typedef {{title: string, looks: string, bright?: boolean, resonance?: boolean, maxSeconds?: number,
 *   loop?: boolean, rules: Rule[]}} AuditClass */

/** Every sound, whatever its class. */
export const UNIVERSAL = Object.freeze([
  ['clipped', '<=', 0, 'no clipped samples'],
  ['truePeak', '<=', -0.9, 'peak-limited at -1 dBTP (never painful on earbuds)'],
  ['dc', '<=', 0.0025, 'no DC offset (the mean stays under -52 dBFS)'],
  ['edge', '<=', -40, 'starts and ends at silence (no click at either end)'],
]);

/** One-shots only. */
export const ONE_SHOT = Object.freeze([
  ['lead', '<=', 0.012, 'no dead air before it starts'],
  ['endLevel', '<=', -50, 'its tail decays into silence, it is not cut'],
]);

/** Loops only. */
export const LOOPING = Object.freeze([
  ['seconds', '>=', 8, 'a loop is 8-24 s (shorter repeats audibly)'],
  ['seconds', '<=', 24, 'a loop is 8-24 s'],
  ['seamRatio', '<=', 1.5, 'the seam jumps no more than anywhere inside'],
  ['seamLevel', '<=', 1.5, 'no level step across the seam beyond the loop\'s own (dB)'],
]);

/** The rules every class shares unless the class or the voice declares otherwise. */
export const DEFAULTS = Object.freeze({
  maxCentroid: 3000, // only glass, porcelain, sparks and keys are brighter
  maxPurity: 0.45, // a beep is near 1
  minPeaksIfResonant: 5, // a declared inharmonic resonance shows at least 5 strong peaks
  minVariantDistance: 2, // dB: variants are not near-copies
  maxSeconds: 2.5, // one-shots; stingers 6, baked far events 5
  loudnessTolerance: 1.5, // LU from the voice's declared reference
});

/** @type {Readonly<Record<string, AuditClass>>} */
export const CLASSES = Object.freeze({
  heavy: {
    title: 'Heavy impact',
    looks: 'a vertical broadband wall at the onset whose low end smears and decays; most of the picture is under 600 Hz',
    rules: [
      ['low', '>=', 0.3, 'at least 30 % of its energy under 250 Hz'],
      ['laptopLoss', '<', 9, 'loses under 9 dB through the laptop filter (its low-mid body carries it)'],
      ['attack', '<=', 0.005, 'attacks in under 5 ms'],
      ['centroid', '<=', 1500, 'dark'],
    ],
  },
  body: {
    title: 'Body impact',
    looks: 'a short broadband onset over a low-mid body that decays fast',
    rules: [
      ['low', '>=', 0.15, 'at least 15 % under 250 Hz'],
      ['laptopLoss', '<', 12, 'loses under 12 dB through the laptop filter'],
      ['attack', '<=', 0.005, 'attacks in under 5 ms'],
    ],
  },
  light: {
    title: 'Light step or touch',
    looks: 'a small, short, dry smudge low in the picture; no ringing lines',
    rules: [
      ['attack', '<=', 0.005, 'attacks in under 5 ms'],
      ['seconds', '<=', 0.9, 'short and dry'],
      ['loudness', '<=', -24, 'small: well under his steps at the same distance'],
      ['centroid', '<=', 2500, 'not bright'],
    ],
  },
  glass: {
    title: 'Glass',
    looks: 'a spray of many short high lines over a low thump; the lines thin out over a few hundred ms',
    bright: true,
    resonance: true,
    rules: [
      ['high', '>=', 0.2, 'at least 20 % of its energy over 2.5 kHz'],
      ['peaks', '>=', 5, 'many partials, never one whistle'],
      ['attack', '<=', 0.005, 'attacks in under 5 ms'],
    ],
  },
  crunch: {
    title: 'Crunch (shards, grit underfoot)',
    looks: 'a dense cloud of tiny clicks, no lines',
    bright: true,
    rules: [
      ['purity', '<=', 0.2, 'gritty clusters, not pings'],
      ['attack', '<=', 0.005, 'attacks in under 5 ms'],
      ['seconds', '<=', 1.2, 'short'],
    ],
  },
  porcelain: {
    title: 'Porcelain (his mask)',
    looks: 'a few short dots between 1.2 and 5 kHz, irregular in time',
    bright: true,
    resonance: true,
    rules: [
      ['porcelain', '>=', 2, 'at least two porcelain ticks'],
      ['attack', '<=', 0.005, 'attacks in under 5 ms'],
    ],
  },
  keys: {
    title: 'Keys and small metal',
    looks: 'a handful of short high lines, scattered',
    bright: true,
    resonance: true,
    rules: [
      ['attack', '<=', 0.005, 'attacks in under 5 ms'],
      ['seconds', '<=', 0.6, 'short'],
      ['peaks', '>=', 5, 'many partials'],
    ],
  },
  spark: {
    title: 'Sparks and electric crackle',
    looks: 'scattered vertical ticks over a broken buzz',
    bright: true,
    rules: [['attack', '<=', 0.005, 'attacks in under 5 ms']],
  },
  liquid: {
    title: 'Liquid (splash, fizz, bubbling, drips)',
    looks: 'a cloud of tiny rising strokes (bubbles), denser where it splashes',
    rules: [
      ['purity', '<=', 0.3, 'many bubbles, never one tone'],
      ['peaks', '>=', 5, 'many partials'],
    ],
  },
  breath: {
    title: 'Breath',
    looks: 'a moving cloud with formant bands; no lines, no hard edges',
    rules: [
      ['rise', '>=', 0.04, 'a breath swells in; it never clicks on'],
      ['purity', '<=', 0.25, 'noise through a throat, not a tone'],
      ['centroid', '<=', 2500, 'dark'],
    ],
  },
  vocal: {
    title: 'Vocal (growl, scream, grunt)',
    looks: 'formant bands smeared by roughness, breaking in pitch; noise bursting through',
    rules: [
      ['roughness', '>=', 0.12, 'rough: amplitude modulation at 30-150 Hz'],
      ['centroid', '<=', 2500, 'frightening by density, not treble'],
    ],
  },
  friction: {
    title: 'Friction (scrape, creak, drag)',
    looks: 'a band of fine vertical striations (the slips) over the body\'s modes',
    rules: [['centroid', '<=', 2500, 'dark']],
  },
  swell: {
    title: 'Swell (hiss, pressure, reversed tail)',
    looks: 'a cloud that grows (or shrinks) smoothly; no onset wall',
    rules: [
      ['rise', '>=', 0.08, 'it swells; no hard onset'],
      ['centroid', '<=', 2500, 'dark'],
    ],
  },
  stinger: {
    title: 'Stinger (scare hit, 2D)',
    looks: 'a sudden dense wall: low drop, rough formant bands, an inharmonic shriek; decays fast',
    maxSeconds: 6,
    rules: [
      ['low', '>=', 0.15, 'weight under it'],
      ['laptopLoss', '<', 9, 'survives a laptop speaker'],
      ['roughness', '>=', 0.1, 'rough'],
      ['loudness', '<=', -8, 'loud, never painful'],
      ['attack', '<=', 0.02, 'sudden'],
    ],
  },
  music: {
    title: 'Music (chase pulse)',
    looks: 'regular vertical hits over a low rough band; no seam',
    loop: true,
    rules: [
      ['low', '>=', 0.2, 'weight'],
      ['laptopLoss', '<', 9, 'survives a laptop speaker'],
      ['loudness', '<=', -14, 'under the stingers'],
    ],
  },
  bed: {
    title: 'Bed (ambience loop)',
    looks: 'a low even cloud; nothing stands out; no seam',
    loop: true,
    rules: [
      ['loudness', '<=', -34, 'far down in level, so that events stand out'],
      ['centroid', '<=', 1500, 'dark'],
    ],
  },
  far: {
    title: 'Far event (baked distance)',
    looks: 'a dark, smeared event inside a long reverberant tail',
    maxSeconds: 5,
    rules: [['centroid', '<=', 1500, 'far away is dark']],
  },
  menu: {
    title: 'Menu',
    looks: 'one tiny low dot',
    maxSeconds: 0.3,
    rules: [
      ['centroid', '<=', 2000, 'low'],
      ['loudness', '<=', -26, 'quiet'],
    ],
  },
});

/** The rattle index at or above which a sound carries his throat's rattle. */
export const RATTLE_SIGNATURE = 0.2;
/** The porcelain ticks at or above which a sound carries his mask. */
export const PORCELAIN_SIGNATURE = 2;
