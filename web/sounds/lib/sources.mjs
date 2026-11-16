// sources.mjs: the recordings every sound is made from (docs/SOUND.md 2). They live UNMODIFIED in
// web/sounds/sources/<lib>/<pack>/<file> (a WAV over 1 MB is stored as FLAC, bit for bit the same samples), and
// web/sounds/sources/SOURCES.json records each pack's page, author and licence and each file's SHA-256. A recording
// is named by its id, "<lib>/<pack>/<file>" (lib: kenney = kenney.nl, oga = opengameart.org).
//
// take(id, from, to) decodes one with ffmpeg (once: the decoded samples are cached in web/build/audio/cache, keyed by
// the file's hash) and returns it mono at 48 kHz; takeStereo() keeps both channels. A recording that is not in
// SOURCES.json, or whose bytes are not the recorded ones, cannot be taken.

import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { FFMPEG } from './encode.mjs';
import { ROOT, SR } from './voices.mjs';

export const SOURCE_DIR = path.join(ROOT, 'sources');
export const INDEX_FILE = path.join(SOURCE_DIR, 'SOURCES.json');
export const CACHE_DIR = path.resolve(ROOT, '..', 'build', 'audio', 'cache');
/** The only licence a recording may carry. */
export const LICENCE = 'CC0';

/**
 * @typedef {{sha256: string, bytes: number, from: string, original?: {name: string, sha256: string, bytes: number}}} SourceFile
 *   from: its path inside the pack (or the pack's archive); original: the WAV a FLAC was made from
 * @typedef {{page: string, author: string, submitter?: string, links?: string[], licences: string[],
 *   archives?: Array<{name: string, sha256: string}>, files: Record<string, SourceFile>}} SourcePack
 *   author: who made it, as the pack's page names them; submitter: who uploaded it, when the page names someone else;
 *   links: the links the page's description gives (a work it was derived from, the author's site or game)
 */

/** @type {{about: string, packs: Record<string, SourcePack>}|null} */
let index = null;

/** SOURCES.json (read once). */
export function loadIndex() {
  if (!index) index = fs.existsSync(INDEX_FILE) ? JSON.parse(fs.readFileSync(INDEX_FILE, 'utf8')) : { about: '', packs: {} };
  return /** @type {{about: string, packs: Record<string, SourcePack>}} */ (index);
}

/** Forgets the index read so far (the import tool rewrites it). */
export function resetIndex() {
  index = null;
  verified.clear();
}

/** "<lib>/<pack>/<file>" -> its pack key and file name. */
export function splitId(id) {
  const parts = id.split('/');
  if (parts.length !== 3 || parts.some((p) => !p || p === '.' || p === '..')) throw new Error(`a recording's id is <lib>/<pack>/<file>: ${id}`);
  return { pack: `${parts[0]}/${parts[1]}`, file: parts[2] };
}

/** The stored file of a recording. */
export function sourcePath(id) {
  const { pack, file } = splitId(id);
  return path.join(SOURCE_DIR, pack, file);
}

export function sha256Of(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

/** @type {Map<string, string>} id -> its verified hash */
const verified = new Map();

/** The recorded hash of a recording, after checking that the stored bytes are the recorded ones. */
function verifiedHash(id) {
  const known = verified.get(id);
  if (known) return known;
  const { pack, file } = splitId(id);
  const entry = loadIndex().packs[pack]?.files[file];
  if (!entry) throw new Error(`${id} is not in sources/SOURCES.json (npm run sounds:import -- --from <library>)`);
  if (!loadIndex().packs[pack].licences.includes(LICENCE)) throw new Error(`${pack} is not ${LICENCE}`);
  const stored = sourcePath(id);
  if (!fs.existsSync(stored)) throw new Error(`${id} is in SOURCES.json but not in sources/`);
  const hash = sha256Of(stored);
  if (hash !== entry.sha256) throw new Error(`${id} was modified: its SHA-256 is not the recorded one`);
  verified.set(id, hash);
  return hash;
}

/**
 * Decodes [from, to) seconds of an audio file to float32 channels at 48 kHz.
 * @param {string} file
 * @param {number} channels 1 (a mono mix) or 2
 * @param {number} from
 * @param {number|null} to
 */
export function decodeFile(file, channels, from = 0, to = null) {
  const args = ['-hide_banner', '-loglevel', 'error', '-threads', '1'];
  if (from > 0) args.push('-ss', from.toFixed(4));
  if (to !== null) args.push('-t', (to - from).toFixed(4));
  args.push('-i', file, '-map', '0:a:0', '-f', 'f32le', '-ar', String(SR), '-ac', String(channels), 'pipe:1');
  const r = spawnSync(FFMPEG, args, { maxBuffer: 1 << 30 });
  if (r.status !== 0) throw new Error(`ffmpeg could not decode ${file}: ${r.stderr?.toString() ?? r.error}`);
  return new Float32Array(r.stdout.buffer.slice(r.stdout.byteOffset, r.stdout.byteOffset + (r.stdout.byteLength - (r.stdout.byteLength % 4))));
}

/** @type {Map<string, Float32Array>} */
const memory = new Map();

function decoded(id, channels, from, to) {
  const hash = verifiedHash(id);
  const key = `${hash.slice(0, 32)}-${channels}-${Math.round(from * 1000)}-${to === null ? 'end' : Math.round(to * 1000)}`;
  let data = memory.get(key);
  if (data) return data;
  const cached = path.join(CACHE_DIR, `${key}.f32`);
  if (fs.existsSync(cached)) {
    const buf = fs.readFileSync(cached);
    data = new Float32Array(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));
  } else {
    data = decodeFile(sourcePath(id), channels, from, to);
    if (!data.length) throw new Error(`${id}: nothing decoded${from || to !== null ? ` between ${from} and ${to} s` : ''}`);
    fs.mkdirSync(CACHE_DIR, { recursive: true });
    // written beside and renamed, so two workers decoding the same recording never read half a file
    const partial = `${cached}.${process.pid}.${crypto.randomBytes(4).toString('hex')}`;
    fs.writeFileSync(partial, Buffer.from(data.buffer, data.byteOffset, data.byteLength));
    fs.renameSync(partial, cached);
  }
  memory.set(key, data);
  return data;
}

/**
 * A recording, mono at 48 kHz (a copy: the caller may change it). `from` / `to` (seconds of the recording) decode
 * only that part of a long one.
 * @param {string} id
 * @param {number} [from]
 * @param {number|null} [to]
 */
export function take(id, from = 0, to = null) {
  return Float32Array.from(decoded(id, 1, from, to));
}

/**
 * A recording's two channels at 48 kHz (a mono recording gives the same channel twice).
 * @param {string} id
 * @param {number} [from]
 * @param {number|null} [to]
 * @returns {[Float32Array, Float32Array]}
 */
export function takeStereo(id, from = 0, to = null) {
  const all = decoded(id, 2, from, to);
  const n = all.length >> 1;
  const left = new Float32Array(n);
  const right = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    left[i] = all[2 * i];
    right[i] = all[2 * i + 1];
  }
  return [left, right];
}

/** Every recording in the index, as ids. */
export function indexedIds() {
  const out = [];
  for (const [pack, p] of Object.entries(loadIndex().packs)) for (const file of Object.keys(p.files)) out.push(`${pack}/${file}`);
  return out.sort();
}

/**
 * Checks the whole store: every indexed recording is there with its recorded bytes, every pack is CC0 with a page
 * and an author, and nothing lies in sources/ that the index does not name. Returns the problems.
 */
export function verifyStore() {
  const problems = [];
  const idx = loadIndex();
  const expected = new Set(['SOURCES.json']);
  for (const [pack, p] of Object.entries(idx.packs)) {
    if (!Array.isArray(p.licences) || !p.licences.includes(LICENCE)) problems.push(`${pack}: its licences (${(p.licences ?? []).join(', ')}) do not include ${LICENCE}`);
    if (!/^https:\/\//.test(p.page ?? '')) problems.push(`${pack}: no page`);
    if (!p.author) problems.push(`${pack}: no author`);
    for (const [file, f] of Object.entries(p.files)) {
      const rel = `${pack}/${file}`;
      expected.add(rel);
      const stored = path.join(SOURCE_DIR, rel);
      if (!fs.existsSync(stored)) problems.push(`${rel}: missing from sources/`);
      else if (sha256Of(stored) !== f.sha256) problems.push(`${rel}: its SHA-256 is not the recorded one (a recording is never edited)`);
    }
  }
  const walk = (dir, rel) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const r = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) walk(path.join(dir, e.name), r);
      else if (!expected.has(r)) problems.push(`${r}: in sources/ but not in SOURCES.json`);
    }
  };
  if (fs.existsSync(SOURCE_DIR)) walk(SOURCE_DIR, '');
  return problems;
}
