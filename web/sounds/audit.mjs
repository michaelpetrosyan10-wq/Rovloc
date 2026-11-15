// audit.mjs (npm run sounds:audit [-- --group reference|world|air] [--only <family|name>[,...]] [--no-sheets]):
// measures every render (web/build/audio/raw) and holds it to its class's numeric rules (lib/classes.mjs, printed in
// docs/SOUND.md 3), checks the cast (web/sounds/cast.json: every sound the game needs has a render), checks the
// distance rule for his footsteps, and draws the contact sheets (web/build/audio/audit/<family>-<n>.png).
//
// Exit code 1 on any breach and on any cast sound of the audited groups without a render. With --group, only that
// group's cast entries are required; the others are listed as pending (never as passes).

import fs from 'node:fs';
import path from 'node:path';
import { ROOT, SR, loadVoices, stem } from './lib/voices.mjs';
import { readRaw } from './lib/raw.mjs';
import { measure, check, fmt } from './lib/analyze.mjs';
import { variantDistance, mono } from './lib/measure.mjs';
import { DEFAULTS, CLASSES } from './lib/classes.mjs';
import { contactSheet } from './lib/sheet.mjs';
import { heard, hear } from './kit/distance.mjs';
import { SPACES, impulse } from './kit/reverb.mjs';
import { momentaryMax } from './kit/loudness.mjs';
import { Rng, hashString } from './kit/rng.mjs';

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

/** His surfaces -> the player's surface a footstep of theirs is compared with. */
const PLAYER_SURFACE = { Concrete: 'Concrete', Tile: 'Tile', Wood: 'Wood', Metal: 'Metal', Gravel: 'Grass' };
/** All shipped audio at most 8 MB (docs/SOUND.md 9). */
const BUDGET_BYTES = 8 * 1048576;
/** The distances (studs) the distance rule is reported at. */
const DISTANCES = [10, 40, 80];

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

/** The loudness (LUFS) of a dry sound heard at `d` studs through the distance model in a space. */
function heardLoudness(x, carry, d, ir) {
  const h = heard(d, 0, carry);
  if (h.gain <= 0) return -Infinity;
  return momentaryMax(hear(x, SR, h, ir), SR);
}

/**
 * The distance rule: his footfall at 80 studs at least 6 dB over the Basement bed, and at least 10 dB over a
 * player's footstep at the same distance.
 */
function distanceRule(voices, results, cast) {
  const ir = impulse(SR, SPACES.basement, new Rng(hashString('space:basement')));
  const beds = ['DreadBedBasement', 'DroneBasement'];
  let bed = null;
  let bedNote = '';
  for (const b of beds) {
    const v = voices.find((x) => x.name === b);
    const r = v && results.get(b);
    if (r && r.records.length) {
      bed = Math.max(...r.records.map((x) => x.m.loudness));
      bedNote = `${b} rendered at ${fmt(bed)} LUFS`;
      break;
    }
  }
  if (bed === null) {
    bed = CLASSES.bed.rules.find((r) => r[0] === 'loudness')[2];
    bedNote = `the Basement bed is not rendered yet (${beds.filter((b) => cast.some((c) => c.name === b)).join(', ')} pending): its class ceiling ${bed} LUFS stands in`;
  }
  const lines = [`distance rule (the Basement space, no walls; ${bedNote})`];
  for (const pace of ['Walk', 'Chase']) {
    for (const [surface, playerSurface] of Object.entries(PLAYER_SURFACE)) {
      const his = voices.find((v) => v.name === `CreatureStep${pace}${surface}`);
      const hisR = his && results.get(his.name);
      if (!hisR || !hisR.samples.length) continue;
      const playerName = `Footstep${pace === 'Chase' ? 'Sprint' : ''}${playerSurface}`;
      const player = voices.find((v) => v.name === playerName);
      const playerR = player && results.get(playerName);
      const cells = [];
      for (const d of DISTANCES) {
        // the quietest of his variants against the loudest of the player's
        const hisL = Math.min(...hisR.samples.map((x) => heardLoudness(x, his.carry, d, ir)));
        const playerL = playerR && playerR.samples.length ? Math.max(...playerR.samples.map((x) => heardLoudness(x, player.carry, d, ir))) : null;
        cells.push(`${d}: ${fmt(hisL)}${playerL === null ? '' : ` vs ${Number.isFinite(playerL) ? fmt(playerL) : 'silent'}`}`);
        if (d === 80 && !(hisL >= bed + 6)) breaches.push(`${his.name}: at 80 studs ${fmt(hisL)} LUFS is not 6 dB over the Basement bed (${fmt(bed)})`);
        if (playerL !== null && Number.isFinite(playerL) && !(hisL >= playerL + 10)) breaches.push(`${his.name}: at ${d} studs ${fmt(hisL)} LUFS is not 10 dB over ${playerName} (${fmt(playerL)})`);
        if (!player && d === DISTANCES[0]) breaches.push(`${his.name}: ${playerName} is not voiced, so the 10 dB rule cannot be checked`);
      }
      lines.push(`  ${his.name.padEnd(28)} ${cells.join('   ')}   (80 studs over the bed: ${fmt(Math.min(...hisR.samples.map((x) => heardLoudness(x, his.carry, 80, ir))) - bed)} dB)`);
    }
  }
  return lines;
}

/** A family file that renders his porcelain must hold only his sounds (law 7: nobody else uses his signatures). */
function signatureOwnership(voices) {
  for (const family of new Set(voices.map((v) => v.family))) {
    const text = fs.readFileSync(path.join(ROOT, 'voices', `${family}.mjs`), 'utf8');
    if (!/porcelainTick|chatter\(/.test(text)) continue;
    for (const v of voices.filter((x) => x.family === family && !x.him)) breaches.push(`${v.name}: ${family}.mjs renders his porcelain but ${v.name} is not his`);
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
          `PURITY ${fmt(m.purity)} PEAKS ${m.peaks}  ROUGH ${fmt(m.roughness)}  ATTACK ${fmt(m.attack * 1000)}MS  RATTLE ${fmt(m.rattle)} TICKS ${m.porcelain}${r.variantMin !== null ? `  VAR ${fmt(r.variantMin)}DB` : ''}`,
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
  signatureOwnership(all);
  // every voice is in the cast, under its own group
  for (const v of all) {
    const c = cast.find((x) => x.name === v.name);
    if (!c) breaches.push(`${v.name}: not in cast.json`);
    else if (c.group !== v.group) breaches.push(`${v.name}: cast.json says group ${c.group}, its voice says ${v.group}`);
  }
  const results = new Map();
  console.log(`${'sound'.padEnd(30)} ${'class'.padEnd(9)} var  ${'sec'.padStart(5)} ${'LUFS'.padStart(6)} laptop  low%  cent  pur  pk rough  att(ms) rattle ticks  result`);
  for (const v of voices) {
    const r = auditVoice(v);
    results.set(v.name, r);
    const ms = r.records.map((x) => x.m);
    if (!ms.length) continue;
    const worst = (key, dir) => (dir > 0 ? Math.max(...ms.map((m) => m[key])) : Math.min(...ms.map((m) => m[key])));
    const bad = r.records.reduce((t, x) => t + x.failures.length, 0);
    console.log(`${v.name.padEnd(30)} ${v.class.padEnd(9)} ${String(ms.length).padStart(3)} ${fmt(worst('seconds', 1)).padStart(5)} ${fmt(worst('loudness', 1)).padStart(6)} ${fmt(worst('laptopLoss', 1)).padStart(6)} ${String(Math.round(worst('low', -1) * 100)).padStart(5)} ${String(Math.round(worst('centroid', 1))).padStart(5)} ${fmt(worst('purity', 1)).padStart(4)} ${String(worst('peaks', -1)).padStart(3)} ${fmt(worst('roughness', -1)).padStart(5)} ${fmt(worst('attack', 1) * 1000).padStart(8)} ${fmt(worst('rattle', 1)).padStart(6)} ${String(worst('porcelain', -1)).padStart(5)}  ${bad ? `FAIL ${bad}` : 'pass'}`);
  }
  // the cast: every sound the audited groups need has a render
  const pending = [];
  for (const c of cast) {
    if (c.status === 'dropped') continue;
    const v = all.find((x) => x.name === c.name);
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
  const distance = distanceRule(all, results, cast);
  console.log(`\n${distance.join('\n')}`);
  const drawn = sheets ? drawSheets(voices, results) : [];
  const byGroup = {};
  for (const c of cast) byGroup[c.group] = (byGroup[c.group] ?? 0) + 1;
  console.log(`\nshipped: ${(shipped / 1048576).toFixed(2)} MB of the 8 MB budget`);
  console.log(`cast: ${cast.length} sounds (${Object.entries(byGroup).map(([g, n]) => `${g} ${n}`).join(', ')}); ${pending.length} pending outside the audited group${pending.length ? `: ${pending.slice(0, 12).join(', ')}${pending.length > 12 ? ', ...' : ''}` : ''}`);
  if (drawn.length) console.log(`sheets: ${drawn.join(', ')}`);
  fs.mkdirSync(AUDIT, { recursive: true });
  fs.writeFileSync(path.join(AUDIT, `report${group ? `-${group}` : ''}.json`), JSON.stringify({
    group: group ?? 'all',
    breaches,
    pending,
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
