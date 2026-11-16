// probe.mjs (npm run sounds:probe -- [--from <library>] <lib>/<pack>[/<file regex>] ... [--rate r] [--lp Hz]
// [--events]): measures candidate recordings before one is chosen (docs/SOUND.md 7), as they are or as a recipe would
// play them (--rate 0.5 --lp 1600), with the audit's own measurements (lib/measure.mjs). Without --from it reads the
// recordings already in web/sounds/sources.
//
//   sec      where it sounds          low%     energy under 250 Hz      rough   30-150 Hz envelope modulation
//   lufs     its loudest 400 ms       sub%     energy under 80 Hz       pitch   the strongest partial under 400 Hz
//   laptop   dB lost through the      cent     centroid, Hz             crest   peak over RMS, dB
//            laptop-speaker filter    att      attack, ms               click   % of the first 12 ms over 1.5 kHz
//                                                                      rattle  his throat's 18-38 Hz pulsing
//
// --events lists the separate takes of a long recording (kit/sample.mjs events) instead.

import path from 'node:path';
import * as K from './kit/index.mjs';
import { SR } from './lib/voices.mjs';
import * as M from './lib/measure.mjs';
import { packFiles } from './lib/library.mjs';
import { SOURCE_DIR, decodeFile } from './lib/sources.mjs';
import { fmt } from './lib/analyze.mjs';

const args = process.argv.slice(2);
const option = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args.splice(i, 2)[1] : undefined;
};
const flag = (name) => {
  const i = args.indexOf(name);
  if (i >= 0) args.splice(i, 1);
  return i >= 0;
};
const library = option('--from') ?? SOURCE_DIR;
const rate = Number(option('--rate') ?? 1);
const lp = Number(option('--lp') ?? 0);
const listEvents = flag('--events');

/** The strongest spectral peak between 25 and 400 Hz (the pitch a slowed voice or a body sits at). */
function lowPitch(x) {
  const size = K.nextPow2(Math.min(Math.max(x.length, 8192), 65536));
  const power = M.segmentPower(x, 0, Math.min(x.length, size), size);
  let best = 0;
  let at = 0;
  for (let k = 1; k < power.length; k++) {
    const f = (k * SR) / size;
    if (f < 25 || f > 400) continue;
    if (power[k] > best) {
      best = power[k];
      at = f;
    }
  }
  return at;
}

function row(name, x) {
  const [a, b] = K.active(x, SR);
  const y = K.region(x, SR, a, b, 0.0005, 0.005);
  const loud = K.momentaryMax([y], SR);
  const bands = M.bandShares(y, SR);
  const att = M.attack(y, SR);
  const seconds = y.length / SR;
  const cells = [
    name.padEnd(44), fmt(seconds).padStart(6), fmt(loud).padStart(6), fmt(loud - K.momentaryMax([K.laptop(y, SR)], SR)).padStart(6),
    String(Math.round((bands[0] + bands[1]) * 100)).padStart(4), String(Math.round(bands[0] * 100)).padStart(4),
    String(Math.round(M.centroid(y, SR))).padStart(6), fmt(att.attack * 1000).padStart(6), fmt(M.roughness(y, SR)).padStart(6),
    String(Math.round(lowPitch(y))).padStart(5), fmt(M.crest(y)).padStart(5), fmt(M.onsetClick(y, SR) * 100).padStart(5), fmt(M.rattleIndex(y, SR)).padStart(6),
  ];
  console.log(cells.join(' '));
}

if (!args.length) {
  console.log('usage: node sounds/probe.mjs [--from <library>] <lib>/<pack>[/<file regex>] ... [--rate r] [--lp Hz] [--events]');
  process.exit(1);
}
for (const spec of args) {
  const parts = spec.split('/');
  const pack = parts.slice(0, 2).join('/');
  const pattern = parts.length > 2 ? new RegExp(parts.slice(2).join('/'), 'i') : null;
  const files = packFiles(library, pack).filter((f) => !pattern || pattern.test(f.name));
  console.log(`## ${pack}${rate !== 1 ? `  at rate ${rate}` : ''}${lp ? `  low-passed at ${lp} Hz` : ''}  (${files.length} files)`);
  if (!listEvents) console.log(`${'file'.padEnd(44)} ${'sec'.padStart(6)} ${'lufs'.padStart(6)} laptop low% sub% ${'cent'.padStart(6)} ${'att'.padStart(6)} ${'rough'.padStart(6)} pitch crest click rattle`);
  for (const f of files) {
    let x = decodeFile(f.file, 1);
    if (listEvents) {
      const takes = K.events(x, SR);
      console.log(`${path.basename(f.file)}: ${(x.length / SR).toFixed(2)} s, ${takes.length} takes: ${takes.map(([a, b]) => `${a.toFixed(2)}-${b.toFixed(2)}`).join('  ')}`);
      continue;
    }
    if (rate !== 1) x = K.resample(x, rate);
    if (lp) x = K.butter(x, SR, 'lowpass', lp, 2);
    row(f.name, x);
  }
}
