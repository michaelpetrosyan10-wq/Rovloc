// render.mjs (npm run sounds [-- --only <family|name>[,...]] [--force] [--jobs 1|2]): renders every voice's variants
// offline at 48 kHz into the shipped files (docs/SOUND.md 7).
//
//   web/build/audio/<family>/<Name>-<n>.mp3        what ships
//   web/build/audio/raw/<family>/<Name>-<n>.f32    the finished samples the audit measures (+ .json)
//   web/build/audio/space/<space>.mp3              the shared convolver's impulse responses (kit/reverb.mjs SPACES)
//   web/build/audio/manifest-<family>.json         one per family (so two engineers can render different families
//   web/build/audio/manifest.json                  into the same directory at once), merged into this one
//
// A content-hash cache skips a variant whose inputs (the kit, the pipeline, its family file, its name and variant)
// are unchanged. At most two worker threads (the machine is shared); run it under "nice -n 10" (the npm script does).

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { Worker } from 'node:worker_threads';
import { ROOT, SR, loadVoices, stem } from './lib/voices.mjs';
import { readInfo } from './lib/raw.mjs';
import { encodeMp3 } from './lib/encode.mjs';
import { SPACES, impulse } from './kit/reverb.mjs';
import { Rng, hashString } from './kit/rng.mjs';

export const BUILD = path.resolve(ROOT, '..', 'build', 'audio');

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const option = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const only = option('--only')?.split(',').filter(Boolean);
const force = flag('--force');
const jobs = Math.max(1, Math.min(2, Number(option('--jobs') ?? 2)));

/** The text of every file a render depends on besides its family file. */
function engineText() {
  const dirs = [path.join(ROOT, 'kit')];
  const files = dirs.flatMap((d) => fs.readdirSync(d).filter((f) => f.endsWith('.mjs')).sort().map((f) => path.join(d, f)));
  files.push(path.join(ROOT, 'lib', 'pipeline.mjs'), path.join(ROOT, 'lib', 'encode.mjs'), path.join(ROOT, 'lib', 'worker.mjs'));
  return files.map((f) => fs.readFileSync(f, 'utf8')).join('\n');
}

const sha = (text) => crypto.createHash('sha256').update(text).digest('hex').slice(0, 24);

/** Renders the shared convolver's impulse responses (cached on the kit). */
function renderSpaces(engineHash) {
  const dir = path.join(BUILD, 'space');
  fs.mkdirSync(dir, { recursive: true });
  const stamp = path.join(dir, 'key.txt');
  const out = {};
  const fresh = fs.existsSync(stamp) && fs.readFileSync(stamp, 'utf8') === engineHash;
  for (const name of Object.keys(SPACES)) {
    const file = path.join(dir, `${name}.mp3`);
    if (!fresh || !fs.existsSync(file)) encodeMp3(impulse(SR, SPACES[name], new Rng(hashString(`space:${name}`))), SR, file);
    out[name] = { file: `space/${name}.mp3`, bytes: fs.statSync(file).size, rt60: SPACES[name].rt60 };
  }
  fs.writeFileSync(stamp, engineHash);
  return out;
}

/** Runs jobs on a pool of worker threads; resolves with their results in order. */
async function runPool(list, size) {
  const results = new Array(list.length);
  let next = 0;
  const worker = async () => {
    const w = new Worker(new URL('./lib/worker.mjs', import.meta.url));
    try {
      while (next < list.length) {
        const i = next++;
        results[i] = await new Promise((resolve) => {
          w.once('message', resolve);
          w.postMessage(list[i]);
        });
        const job = list[i];
        const r = results[i];
        console.log(`${r.ok ? 'rendered' : 'FAILED  '} ${job.family}/${stem(job.name, job.variant)}${r.ok ? ` ${r.stats.seconds.toFixed(2)} s ${(r.stats.bytes / 1024).toFixed(1)} KB ${r.stats.renderMs} ms` : `\n${r.error}`}`);
      }
    } finally {
      await w.terminate();
    }
  };
  await Promise.all(Array.from({ length: Math.min(size, list.length) }, worker));
  return results;
}

/** Merges every per-family manifest into manifest.json. */
export function mergeManifests(spaces) {
  const sounds = {};
  let bytes = 0;
  for (const f of fs.readdirSync(BUILD).filter((x) => /^manifest-.+\.json$/.test(x)).sort()) {
    const m = JSON.parse(fs.readFileSync(path.join(BUILD, f), 'utf8'));
    for (const s of m.sounds) {
      sounds[s.name] = s;
      bytes += s.variants.reduce((t, v) => t + v.bytes, 0);
    }
  }
  const spaceBytes = Object.values(spaces).reduce((t, s) => t + s.bytes, 0);
  const manifest = { sampleRate: SR, format: 'mp3', bytes: bytes + spaceBytes, spaces, sounds };
  fs.writeFileSync(path.join(BUILD, 'manifest.json'), JSON.stringify(manifest, null, 1));
  return manifest;
}

async function main() {
  const voices = await loadVoices(only);
  const engine = engineText();
  const engineHash = sha(engine);
  const jobsList = [];
  const familyText = new Map();
  for (const v of voices) {
    const file = path.join(ROOT, 'voices', `${v.family}.mjs`);
    if (!familyText.has(file)) familyText.set(file, fs.readFileSync(file, 'utf8'));
    for (let variant = 1; variant <= v.variants; variant++) {
      const key = sha(`${engineHash}\n${familyText.get(file)}\n${v.name}#${variant}`);
      const raw = path.join(BUILD, 'raw', v.family, `${stem(v.name, variant)}.f32`);
      const mp3 = path.join(BUILD, v.family, `${stem(v.name, variant)}.mp3`);
      const info = readInfo(raw);
      if (!force && info && info.key === key && fs.existsSync(mp3)) continue;
      jobsList.push({ file, family: v.family, name: v.name, variant, key, raw, mp3 });
    }
  }
  console.log(`${voices.length} sounds, ${jobsList.length} variants to render (${jobs} workers)`);
  const results = await runPool(jobsList, jobs);
  const failed = results.filter((r) => !r.ok).length;
  // the per-family manifests, from every variant's record (fresh or cached)
  const families = [...new Set(voices.map((v) => v.family))];
  const all = only ? (await loadVoices()).filter((v) => families.includes(v.family)) : voices;
  for (const family of families) {
    const sounds = [];
    for (const v of all.filter((x) => x.family === family)) {
      const variants = [];
      for (let variant = 1; variant <= v.variants; variant++) {
        const raw = path.join(BUILD, 'raw', family, `${stem(v.name, variant)}.f32`);
        const mp3 = path.join(BUILD, family, `${stem(v.name, variant)}.mp3`);
        const info = readInfo(raw);
        if (!info || !fs.existsSync(mp3)) continue;
        variants.push({
          file: `${family}/${stem(v.name, variant)}.mp3`, bytes: fs.statSync(mp3).size, seconds: +info.seconds.toFixed(4),
          fileSeconds: +info.fileSeconds.toFixed(4), loop: info.loop, truePeak: +info.truePeak.toFixed(2),
          loudness: +info.loudness.toFixed(2), tail: +info.tail.toFixed(3),
        });
      }
      sounds.push({
        name: v.name, family, group: v.group, title: v.title, description: v.description, class: v.class, board: v.board,
        him: v.him ?? null, channels: v.channels, space: v.space, loop: !!v.loop, reference: v.loudness,
        carry: v.carry ?? null, variants,
      });
    }
    fs.writeFileSync(path.join(BUILD, `manifest-${family}.json`), JSON.stringify({ family, sounds }, null, 1));
  }
  const spaces = renderSpaces(engineHash);
  const manifest = mergeManifests(spaces);
  console.log(`manifest: ${Object.keys(manifest.sounds).length} sounds, ${(manifest.bytes / 1048576).toFixed(2)} MB shipped`);
  if (failed) {
    console.log(`${failed} variants FAILED`);
    process.exit(1);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) await main();
