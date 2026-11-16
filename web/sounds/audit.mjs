// audit.mjs (npm run sounds:audit [-- --group reference|world|air] [--only <family|name>[,...]] [--no-sheets]):
// measures every render (web/build/audio/raw) and holds it to its class's numeric rules (lib/classes.mjs, printed in
// docs/SOUND.md 4), checks the cast (web/sounds/cast.json: every sound the game plays has a render), the recordings
// (every one in SOURCES.json with its bytes, CC0; his recordings his alone), his footsteps against the players' and
// the Basement's bed over distance, and draws the contact sheets (web/build/audio/audit/<family>-<n>.png).
//
// Exit code 1 on any breach and on any cast sound of the audited groups without a render (a sound whose status is
// `waiting` belongs to a stage that does not exist yet: listed, never required). With --group, only that group's cast
// entries are required; the others are listed as pending (never as passes).

import fs from 'node:fs';
import path from 'node:path';
import { ROOT, SR, loadVoices, stem } from './lib/voices.mjs';
import { readRaw } from './lib/raw.mjs';
import { measure, check, fmt } from './lib/analyze.mjs';
import { variantDistance, mono } from './lib/measure.mjs';
import { DEFAULTS, CLASSES } from './lib/classes.mjs';
import { contactSheet } from './lib/sheet.mjs';
import { verifyStore, loadIndex, splitId, LICENCE } from './lib/sources.mjs';
import { momentaryMax } from './kit/loudness.mjs';
import { toDb } from './kit/mix.mjs';
import { Presets, CreatureFootfalls } from '../src/engine/audio/presets.js';
import { attenuation } from '../src/engine/audio/rolloff.js';

const BUILD = path.resolve(ROOT, '..', 'build', 'audio');
const AUDIT = path.join(BUILD, 'audit');
const args = process.argv.slice(2);
const option = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const group = option('--group');
const only = option('--only')?.split(',').filter(Boolean);
const sheets = !args.includes('--no-sheets');

/** All shipped audio at most 8 MB (docs/SOUND.md 9). */
const BUDGET_BYTES = 8 * 1048576;
/** His footfall over a player's footstep at the same distance, at least (dB). */
const OVER_PLAYER = 10;
/** His quietest footfall at CreatureConfig.Footfalls.HeardTo over the Basement's bed, at least (dB). */
const OVER_BED = 6;
/** The classes that are scares or music: the only things that may be louder than his footsteps. */
const SCARE_CLASSES = new Set(['stinger', 'music']);

/** @type {string[]} */
const breaches = [];

function loadCast() {
  const cast = JSON.parse(fs.readFileSync(path.join(ROOT, 'cast.json'), 'utf8'));
  return /** @type {Array<{name: string, group: string, status: string, source: any, family?: string, note?: string}>} */ (cast.sounds);
}

/**
 * Measures every variant of a voice; returns the records and the rendered mono samples.
 * @param {import('./lib/voices.mjs').Voice} v
 */
function auditVoice(v) {
  const records = [];
  const samples = [];
  for (let k = 1; k <= v.variants; k++) {
    const file = path.join(BUILD, 'raw', v.family, `${stem(v.name, k)}.f32`);
    if (!fs.existsSync(file)) {
      breaches.push(`${v.name} #${k}: no render (npm run sounds -- --only ${v.family})`);
      continue;
    }
    const { channels } = readRaw(file);
    const m = measure(channels, SR, v);
    const failures = check(m, v);
    records.push({ variant: k, m, failures });
    samples.push(mono(channels));
  }
  let variantMin = Infinity;
  for (let a = 0; a < samples.length; a++) for (let b = a + 1; b < samples.length; b++) variantMin = Math.min(variantMin, variantDistance(samples[a], samples[b], SR));
  const minDistance = v.expect?.minVariantDistance ?? DEFAULTS.minVariantDistance;
  const variantFailure = samples.length > 1 && variantMin < minDistance ? `variants too alike: the closest two differ by ${fmt(variantMin)} dB (at least ${minDistance})` : null;
  for (const r of records) for (const f of r.failures) breaches.push(`${v.name} #${r.variant}: ${f}`);
  if (variantFailure) breaches.push(`${v.name}: ${variantFailure}`);
  return { records, samples, variantMin: samples.length > 1 ? variantMin : null };
}

/** The loudest 400 ms (LUFS) of a sound played `d` studs away through its preset's roll-off (the game's own). */
function heardLoudness(x, name, d) {
  const preset = Presets[name];
  const g = attenuation(d, preset.rollOff);
  return g > 0 ? momentaryMax([x], SR) + toDb(g) : -Infinity;
}

/**
 * His footsteps over distance (the roll-offs are the shared config's, through presets.js): at 10 and 40 studs and at
 * CreatureConfig.Footfalls.HeardTo his quietest take is at least 10 dB over the loudest take of a player's footstep
 * on the same surface, and at HeardTo it still stands at least 6 dB over the Basement's bed.
 */
function distanceRule(voices, results) {
  const distances = [10, 40, CreatureFootfalls.HeardTo];
  const bedVoice = voices.find((v) => v.name === 'DreadBedBasement');
  const bedResult = bedVoice && results.get(bedVoice.name);
  const bed = bedResult && bedResult.records.length ? Math.max(...bedResult.records.map((x) => x.m.loudness)) : CLASSES.bed.rules.find((r) => r[0] === 'loudness')[2];
  const lines = [`his footsteps over distance (roll-off ${CreatureFootfalls.RollOffMin}..${CreatureFootfalls.RollOffMax} studs, heard to ${CreatureFootfalls.HeardTo}; the Basement bed ${bedResult && bedResult.records.length ? `at ${fmt(bed)} LUFS` : `not audited here: its class ceiling ${bed} LUFS stands in`})`];
  for (const his of voices.filter((v) => /^CreatureStep(Walk|Chase)/.test(v.name))) {
    const hisR = results.get(his.name);
    if (!hisR || !hisR.samples.length) continue;
    const [, pace, surface] = /** @type {RegExpMatchArray} */ (his.name.match(/^CreatureStep(Walk|Chase)(.+)$/));
    const playerName = `Footstep${pace === 'Chase' ? 'Sprint' : ''}${surface}`;
    const playerR = results.get(playerName);
    const cells = [];
    for (const d of distances) {
      // the quietest of his takes against the loudest of the player's
      const hisL = Math.min(...hisR.samples.map((x) => heardLoudness(x, his.name, d)));
      const playerL = playerR && playerR.samples.length ? Math.max(...playerR.samples.map((x) => heardLoudness(x, playerName, d))) : null;
      cells.push(`${d}: ${fmt(hisL)}${playerL === null ? '' : ` vs ${Number.isFinite(playerL) ? fmt(playerL) : 'silent'}`}`);
      if (d === CreatureFootfalls.HeardTo && !(hisL >= bed + OVER_BED)) breaches.push(`${his.name}: at ${d} studs ${fmt(hisL)} LUFS is not ${OVER_BED} dB over the Basement bed (${fmt(bed)})`);
      if (playerL !== null && Number.isFinite(playerL) && !(hisL >= playerL + OVER_PLAYER)) breaches.push(`${his.name}: at ${d} studs ${fmt(hisL)} LUFS is not ${OVER_PLAYER} dB over ${playerName} (${fmt(playerL)})`);
    }
    lines.push(`  ${his.name.padEnd(28)} ${cells.join('   ')}`);
  }
  return lines;
}

/**
 * The heaviest thing that is not a scare: no sound outside the scares, the music and his own is louder than his
 * quietest footstep (by their reference loudness).
 */
function heaviestRule(voices) {
  const steps = voices.filter((v) => /^CreatureStep/.test(v.name));
  if (!steps.length) return;
  const floor = Math.min(...steps.map((v) => v.loudness));
  for (const v of voices) {
    if (v.him || v.loop || SCARE_CLASSES.has(v.class)) continue;
    if (v.loudness > floor - 1) breaches.push(`${v.name}: its reference loudness ${v.loudness} LUFS is not under his footsteps' (${floor}): only a scare is louder than he walks`);
  }
}

/**
 * The recordings: the store is whole and CC0 (lib/sources.mjs verifyStore), every voice's recordings are in it, and
 * what sounds like him is him (spec I1): a recording one of his sounds is made from is in no sound that is not his.
 */
function sourcesRule(voices) {
  for (const p of verifyStore()) breaches.push(`sources: ${p}`);
  const index = loadIndex();
  /** @type {Map<string, string>} */
  const his = new Map();
  for (const v of voices.filter((x) => x.him)) for (const id of v.sources) his.set(id, v.name);
  for (const v of voices) {
    for (const id of v.sources) {
      const { pack, file } = splitId(id);
      const entry = index.packs[pack];
      if (!entry || !entry.files[file]) breaches.push(`${v.name}: ${id} is not in SOURCES.json`);
      else if (!entry.licences.includes(LICENCE)) breaches.push(`${v.name}: ${pack} is not ${LICENCE}`);
      if (!v.him && his.has(id)) breaches.push(`${v.name}: plays ${id}, which is one of his recordings (${his.get(id)}): what sounds like him is him (I1)`);
    }
  }
}

function drawSheets(voices, results) {
  fs.mkdirSync(AUDIT, { recursive: true });
  const drawn = [];
  for (const family of [...new Set(voices.map((v) => v.family))]) {
    const items = [];
    for (const v of voices.filter((x) => x.family === family)) {
      const r = results.get(v.name);
      if (!r || !r.samples.length) continue;
      const rec = r.records[0];
      const m = rec.m;
      items.push({
        x: r.samples[0],
        name: `${v.name} #1/${v.variants}`,
        ok: r.records.every((x) => !x.failures.length),
        lines: [
          `${v.class.toUpperCase()} ${fmt(m.seconds)}S  L ${fmt(m.loudness)}  LAPTOP -${fmt(m.laptopLoss)}DB  LOW ${Math.round(m.low * 100)}%  HIGH ${Math.round(m.high * 100)}%  CENTROID ${Math.round(m.centroid)}`,
          `PURITY ${fmt(m.purity)} PEAKS ${m.peaks}  ROUGH ${fmt(m.roughness)}  ATTACK ${fmt(m.attack * 1000)}MS  RATTLE ${fmt(m.rattle)} CLICK ${fmt(m.click * 100)}%${r.variantMin !== null ? `  VAR ${fmt(r.variantMin)}DB` : ''}`,
        ],
      });
    }
    for (let k = 0; k * 8 < items.length; k++) {
      const file = path.join(AUDIT, `${family}-${k + 1}.png`);
      fs.writeFileSync(file, contactSheet(items.slice(k * 8, k * 8 + 8), SR, `${family} ${k + 1}/${Math.ceil(items.length / 8)}`));
      drawn.push(path.relative(path.resolve(ROOT, '..'), file));
    }
  }
  return drawn;
}

async function main() {
  const all = await loadVoices();
  const cast = loadCast();
  let voices = only ? await loadVoices(only) : all;
  if (group) voices = voices.filter((v) => v.group === group);
  sourcesRule(all);
  heaviestRule(all);
  // every voice is in the cast, under its own group
  for (const v of all) {
    const c = cast.find((x) => x.name === v.name);
    if (!c) breaches.push(`${v.name}: not in cast.json`);
    else if (c.group !== v.group) breaches.push(`${v.name}: cast.json says group ${c.group}, its voice says ${v.group}`);
    else if (c.status !== 'voiced') breaches.push(`${v.name}: it has a voice but cast.json says ${c.status}`);
  }
  const results = new Map();
  console.log(`${'sound'.padEnd(30)} ${'class'.padEnd(9)} var  ${'sec'.padStart(5)} ${'LUFS'.padStart(6)} laptop  low% high%  cent  pur  pk rough  att(ms) rattle click%  result`);
  for (const v of voices) {
    const r = auditVoice(v);
    results.set(v.name, r);
    const ms = r.records.map((x) => x.m);
    if (!ms.length) continue;
    const worst = (key, dir) => (dir > 0 ? Math.max(...ms.map((m) => m[key])) : Math.min(...ms.map((m) => m[key])));
    const bad = r.records.reduce((t, x) => t + x.failures.length, 0);
    console.log(`${v.name.padEnd(30)} ${v.class.padEnd(9)} ${String(ms.length).padStart(3)} ${fmt(worst('seconds', 1)).padStart(5)} ${fmt(worst('loudness', 1)).padStart(6)} ${fmt(worst('laptopLoss', 1)).padStart(6)} ${String(Math.round(worst('low', -1) * 100)).padStart(5)} ${String(Math.round(worst('high', 1) * 100)).padStart(5)} ${String(Math.round(worst('centroid', 1))).padStart(5)} ${fmt(worst('purity', 1)).padStart(4)} ${String(worst('peaks', -1)).padStart(3)} ${fmt(worst('roughness', -1)).padStart(5)} ${fmt(worst('attack', 1) * 1000).padStart(8)} ${fmt(worst('rattle', 1)).padStart(6)} ${fmt(worst('click', 1) * 100).padStart(6)}  ${bad ? `FAIL ${bad}` : 'pass'}`);
  }
  // the cast: every sound the audited groups play has a render
  const pending = [];
  const waiting = [];
  for (const c of cast) {
    if (c.status === 'dropped') continue;
    const v = all.find((x) => x.name === c.name);
    if (c.status === 'waiting') {
      if (v) breaches.push(`${c.name}: cast.json says it waits for its stage, but it has a voice`);
      else waiting.push(c.name);
      continue;
    }
    const rendered = v && fs.existsSync(path.join(BUILD, 'raw', v.family, `${stem(v.name, 1)}.f32`));
    const required = only ? only.includes(c.name) || (!!v && only.includes(v.family)) : !group || c.group === group;
    if (!rendered) {
      if (required) breaches.push(`${c.name} (${c.group}): in cast.json but ${v ? 'not rendered' : 'not voiced'}`);
      else pending.push(`${c.name} (${c.group})`);
    }
  }
  // the budget: all shipped audio at most 8 MB
  const manifestFile = path.join(BUILD, 'manifest.json');
  const shipped = fs.existsSync(manifestFile) ? JSON.parse(fs.readFileSync(manifestFile, 'utf8')).bytes : 0;
  if (shipped > BUDGET_BYTES) breaches.push(`shipped audio ${(shipped / 1048576).toFixed(2)} MB is over the 8 MB budget`);
  const distance = distanceRule(all, results);
  console.log(`\n${distance.join('\n')}`);
  const drawn = sheets ? drawSheets(voices, results) : [];
  const byGroup = {};
  for (const c of cast) byGroup[c.group] = (byGroup[c.group] ?? 0) + 1;
  console.log(`\nshipped: ${(shipped / 1048576).toFixed(2)} MB of the 8 MB budget`);
  console.log(`cast: ${cast.length} sounds (${Object.entries(byGroup).map(([g, n]) => `${g} ${n}`).join(', ')}); ${waiting.length} wait for stages that do not exist yet; ${pending.length} pending outside the audited group${pending.length ? `: ${pending.slice(0, 12).join(', ')}${pending.length > 12 ? ', ...' : ''}` : ''}`);
  if (drawn.length) console.log(`sheets: ${drawn.join(', ')}`);
  fs.mkdirSync(AUDIT, { recursive: true });
  fs.writeFileSync(path.join(AUDIT, `report${group ? `-${group}` : ''}.json`), JSON.stringify({
    group: group ?? 'all',
    breaches,
    pending,
    waiting,
    distance,
    sounds: Object.fromEntries([...results].map(([name, r]) => [name, { variantMin: r.variantMin, variants: r.records.map((x) => ({ variant: x.variant, failures: x.failures, ...x.m })) }])),
  }, null, 1));
  if (breaches.length) {
    console.log(`\nFAIL: ${breaches.length} breaches\n  ${breaches.join('\n  ')}`);
    process.exit(1);
  }
  console.log('\naudit: pass');
}

await main();
