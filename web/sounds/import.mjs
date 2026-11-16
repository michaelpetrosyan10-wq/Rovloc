// import.mjs (npm run sounds:import -- --from <library> [--prune]): copies every recording the voices name from a
// library of downloaded packs (lib/library.mjs) into web/sounds/sources/<lib>/<pack>/, UNMODIFIED, and records it in
// web/sounds/sources/SOURCES.json: the pack's page and licences (from the pack's source.json, which the fetch tool
// wrote from the pack's own page), its author and submitter and the links its description gives (read from the page
// itself, lib/library.mjs pageFacts), the archive it came out of and its SHA-256, and the file's own SHA-256.
//
// * Only a pack whose source.json lists CC0 is taken (lib/sources.mjs LICENCE).
// * A file the pack offered as a direct download must have the SHA-256 its source.json recorded.
// * A WAV over 1 MB is stored as FLAC (id "<name>.flac"): the same samples bit for bit (the decoded PCM's MD5 is
//   compared before the FLAC is kept), with the WAV's own name, size and hash recorded as `original`.
// * Every pack already in the index has its record (page, author, submitter, links, licences) read again from the
//   library, so a correction to how the record is read reaches every pack, never by hand.
// * --prune removes the recordings no voice names any more.
//
// The repo then needs no library: render.mjs reads web/sounds/sources alone.

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { FFMPEG } from './lib/encode.mjs';
import { locate, packRecord, pageFacts } from './lib/library.mjs';
import { INDEX_FILE, LICENCE, SOURCE_DIR, indexedIds, loadIndex, resetIndex, sha256Of, splitId, verifyStore } from './lib/sources.mjs';
import { loadVoices } from './lib/voices.mjs';

const FLAC_OVER = 1048576;
const ABOUT = 'The recordings ROVLOC\'s sounds are made from (docs/SOUND.md 2), unmodified, each from a pack whose page states CC0. '
  + 'packs: "<lib>/<pack>" (kenney = kenney.nl, oga = opengameart.org) -> its page, its author as the page names them (submitter: who uploaded it, '
  + 'when the page names someone else), links: the links its description gives (a work it was derived from, the author\'s site or game), '
  + 'its licences, the archive(s) the files came out of '
  + '(name and SHA-256 of the download), and files: name -> SHA-256 and size of the stored file and its path inside the pack '
  + '(original: the WAV a FLAC was losslessly made from). Written by web/sounds/import.mjs; never edited by hand.';

const args = process.argv.slice(2);
const fromAt = args.indexOf('--from');
const library = fromAt >= 0 ? args[fromAt + 1] : null;
const prune = args.includes('--prune');

function ffmpeg(list) {
  const r = spawnSync(FFMPEG, ['-hide_banner', '-loglevel', 'error', '-y', ...list], { maxBuffer: 1 << 28 });
  if (r.status !== 0) throw new Error(`ffmpeg ${list.join(' ')}: ${r.stderr?.toString() ?? r.error}`);
  return r.stdout.toString();
}

/** The MD5 of a file's decoded PCM (ffmpeg's md5 muxer, in the stream's own sample format). */
function pcmMd5(file, format) {
  return ffmpeg(['-i', file, '-map', '0:a:0', '-c:a', format, '-f', 'md5', '-']).trim();
}

/** The integer PCM codec a WAV holds (null for float or compressed WAVs, which stay as they are). */
function wavCodec(file) {
  const r = spawnSync('/usr/bin/ffprobe', ['-v', 'error', '-select_streams', 'a:0', '-show_entries', 'stream=codec_name', '-of', 'csv=p=0', file]);
  const codec = r.stdout.toString().trim();
  return ['pcm_s16le', 'pcm_s24le', 'pcm_u8'].includes(codec) ? codec : null;
}

/** A pack's record as its page states it (the page, the author it names, the submitter, the description's links, the licences). */
function recordPack(p, pack, record) {
  const facts = pageFacts(/** @type {string} */ (library), pack, record);
  p.page = record.page;
  p.author = facts.author;
  if (facts.submitter) p.submitter = facts.submitter;
  else delete p.submitter;
  if (facts.links) p.links = facts.links;
  else delete p.links;
  p.licences = record.licences;
}

function importOne(id, index) {
  const { pack, file } = splitId(id);
  const record = packRecord(/** @type {string} */ (library), pack);
  if (!record.licences.includes(LICENCE)) throw new Error(`${pack}: its page lists ${record.licences.join(', ')}, not ${LICENCE}`);
  const found = locate(/** @type {string} */ (library), id);
  const target = path.join(SOURCE_DIR, pack, file);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const downloads = record.files ?? [];
  const direct = downloads.find((d) => d.name === found.rel);
  if (direct && direct.sha256 !== sha256Of(found.file)) throw new Error(`${id}: the library file is not the one its source.json recorded`);
  /** @type {import('./lib/sources.mjs').SourceFile} */
  let entry;
  if (found.convert) {
    const codec = wavCodec(found.file);
    if (!codec || fs.statSync(found.file).size <= FLAC_OVER) throw new Error(`${id}: name the WAV itself (only an integer-PCM WAV over 1 MB is stored as FLAC)`);
    ffmpeg(['-i', found.file, '-map', '0:a:0', '-map_metadata', '-1', '-c:a', 'flac', '-compression_level', '8', '-fflags', '+bitexact', '-flags:a', '+bitexact', target]);
    const format = codec === 'pcm_s24le' ? 'pcm_s24le' : 'pcm_s16le';
    if (pcmMd5(found.file, format) !== pcmMd5(target, format)) throw new Error(`${id}: the FLAC does not decode to the WAV's samples`);
    entry = { sha256: sha256Of(target), bytes: fs.statSync(target).size, from: found.rel, original: { name: path.basename(found.file), sha256: sha256Of(found.file), bytes: fs.statSync(found.file).size } };
  } else {
    if (/\.wav$/i.test(file) && fs.statSync(found.file).size > FLAC_OVER && wavCodec(found.file)) throw new Error(`${id}: a WAV over 1 MB is stored as FLAC: name it ${file.replace(/\.wav$/i, '.flac')}`);
    fs.copyFileSync(found.file, target);
    entry = { sha256: sha256Of(target), bytes: fs.statSync(target).size, from: found.rel };
  }
  const archives = downloads.filter((d) => /\.(zip|7z|rar|tar|gz)$/i.test(d.name)).map((d) => ({ name: d.name, sha256: d.sha256 }));
  if (!direct && !archives.length) throw new Error(`${id}: neither a recorded download nor out of a recorded archive`);
  const p = index.packs[pack] ?? (index.packs[pack] = { files: {} });
  recordPack(p, pack, record);
  if (!direct) p.archives = archives;
  p.files[file] = entry;
  return entry;
}

function writeIndex(index) {
  const packs = {};
  for (const key of Object.keys(index.packs).sort()) {
    const p = index.packs[key];
    const files = {};
    for (const f of Object.keys(p.files).sort()) files[f] = p.files[f];
    const { page, author, submitter, links, licences, archives } = p;
    if (Object.keys(files).length) packs[key] = { page, author, ...(submitter ? { submitter } : {}), ...(links ? { links } : {}), licences, files, ...(archives ? { archives } : {}) };
  }
  fs.mkdirSync(SOURCE_DIR, { recursive: true });
  fs.writeFileSync(INDEX_FILE, `${JSON.stringify({ about: ABOUT, packs }, null, 1)}\n`);
  resetIndex();
}

async function main() {
  const voices = await loadVoices();
  const wanted = new Set(voices.flatMap((v) => v.sources ?? []));
  const index = JSON.parse(JSON.stringify(loadIndex()));
  const have = new Set(indexedIds().filter((id) => fs.existsSync(path.join(SOURCE_DIR, id))));
  const missing = [...wanted].filter((id) => !have.has(id)).sort();
  if (missing.length && !library) {
    console.log(`${missing.length} recordings are not in web/sounds/sources: pass --from <library>\n  ${missing.join('\n  ')}`);
    process.exit(1);
  }
  let bytes = 0;
  for (const id of missing) {
    const entry = importOne(id, index);
    bytes += entry.bytes;
    console.log(`imported ${id} (${(entry.bytes / 1024).toFixed(1)} KB${entry.original ? `, FLAC of ${entry.original.name}` : ''})`);
  }
  if (library) {
    for (const pack of Object.keys(index.packs)) {
      const record = packRecord(library, pack);
      if (!record.licences.includes(LICENCE)) throw new Error(`${pack}: its page lists ${record.licences.join(', ')}, not ${LICENCE}`);
      recordPack(index.packs[pack], pack, record);
    }
  }
  let pruned = 0;
  if (prune) {
    for (const id of indexedIds()) {
      if (wanted.has(id)) continue;
      const { pack, file } = splitId(id);
      delete index.packs[pack].files[file];
      fs.rmSync(path.join(SOURCE_DIR, id), { force: true });
      pruned++;
    }
    for (const lib of fs.existsSync(SOURCE_DIR) ? fs.readdirSync(SOURCE_DIR, { withFileTypes: true }).filter((e) => e.isDirectory()) : []) {
      for (const pack of fs.readdirSync(path.join(SOURCE_DIR, lib.name))) {
        const dir = path.join(SOURCE_DIR, lib.name, pack);
        if (fs.statSync(dir).isDirectory() && !fs.readdirSync(dir).length) fs.rmdirSync(dir);
      }
    }
  }
  writeIndex(index);
  const problems = verifyStore();
  const total = indexedIds().reduce((t, id) => t + fs.statSync(path.join(SOURCE_DIR, id)).size, 0);
  console.log(`sources: ${indexedIds().length} recordings from ${Object.keys(loadIndex().packs).length} packs, ${(total / 1048576).toFixed(2)} MB`
    + ` (${missing.length} imported, ${(bytes / 1048576).toFixed(2)} MB; ${pruned} pruned)`);
  if (problems.length) {
    console.log(`FAIL\n  ${problems.join('\n  ')}`);
    process.exit(1);
  }
}

await main();
