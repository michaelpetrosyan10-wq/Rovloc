// library.mjs: a library of downloaded packs outside the repo, as the fetch tools leave it:
//
//   <library>/<lib>/<pack>/source.json        {page, author, licences, files: [{name, sha256, unpacked?}]}
//   <library>/oga/<pack>/page.html            the pack's opengameart.org page as fetched (its Author field and description)
//   <library>/<lib>/<pack>/<file>             a recording downloaded as it is
//   <library>/<lib>/<pack>/unpacked/...       the contents of the pack's archives
//
// import.mjs copies the recordings the voices name from it into web/sounds/sources; probe.mjs measures candidates
// straight from it. Nothing else reads it: once imported, the repo needs no library.

import fs from 'node:fs';
import path from 'node:path';

const AUDIO = /\.(ogg|wav|flac|mp3)$/i;

/** A pack's source.json, checked: it has a page, an author and its licences. */
export function packRecord(library, pack) {
  const file = path.join(library, pack, 'source.json');
  if (!fs.existsSync(file)) throw new Error(`${pack}: no source.json in the library (a recording must be traceable)`);
  const record = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!record.page || !Array.isArray(record.licences)) throw new Error(`${pack}: source.json has no page or licences`);
  return record;
}

const text = (html) => html.replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#0?39;/g, "'")
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/\s+/g, ' ').trim();

/**
 * What an opengameart.org pack's own page says about who made it, read from the page the fetch saved beside the
 * pack's source.json (<library>/oga/<pack>/page.html): the author as the page's "Author:" field names them (a
 * submitter's account is not the author: "Dub (Submitted by qubodup)"), the submitter when the page names one, and
 * the links its description gives (a work it was derived from, the author's site or game). A kenney.nl pack is
 * Kenney's own work: its source.json names the author and there is no submitter.
 * @returns {{author: string, submitter?: string, links?: string[]}}
 */
export function pageFacts(library, pack, record) {
  if (!pack.startsWith('oga/')) return { author: record.author };
  const file = path.join(library, pack, 'page.html');
  if (!fs.existsSync(file)) throw new Error(`${pack}: no page.html in the library (the page's author field is the record of who made it)`);
  const html = fs.readFileSync(file, 'utf8');
  const field = html.match(/field-name-author-submitter[\s\S]*?<div class="field-item[^"]*">([\s\S]*?)<\/div>/);
  if (!field) throw new Error(`${pack}: its page.html has no Author field`);
  const submitted = field[1].match(/\(Submitted by([\s\S]*?)\)/i);
  const author = text(submitted ? field[1].slice(0, submitted.index) : field[1]);
  if (!author) throw new Error(`${pack}: its page names no author`);
  const facts = { author };
  if (submitted) facts.submitter = text(submitted[1]);
  const body = html.match(/field-name-body[\s\S]*?property="content:encoded">([\s\S]*?)<\/div><\/div><\/div>/);
  const links = body ? [...new Set([...body[1].matchAll(/href="(https?:\/\/[^"]+)"/g)].map((m) => m[1].replace(/&amp;/g, '&')).filter((u) => !/^https?:\/\/(www\.)?opengameart\.org\//.test(u)))] : [];
  if (links.length) facts.links = links;
  return facts;
}

/** Every audio file of a pack: [{name, rel, file}] (rel: its path inside the pack). */
export function packFiles(library, pack) {
  const root = path.join(library, pack);
  const out = [];
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (e.name.startsWith('._') || e.name === '__MACOSX') continue;
      const full = path.join(dir, e.name);
      if (e.isDirectory()) walk(full);
      else if (AUDIO.test(e.name)) out.push({ name: e.name, rel: path.relative(root, full).split(path.sep).join('/'), file: full });
    }
  };
  walk(root);
  return out.sort((a, b) => a.rel.localeCompare(b.rel));
}

/**
 * The library file of a recording id "<lib>/<pack>/<file>": the one file of that name in the pack. A ".flac" id
 * whose pack has only the ".wav" of that name resolves to the WAV (import.mjs stores it as FLAC).
 * @returns {{file: string, rel: string, convert: boolean}}
 */
export function locate(library, id) {
  const parts = id.split('/');
  if (parts.length !== 3) throw new Error(`a recording's id is <lib>/<pack>/<file>: ${id}`);
  const pack = `${parts[0]}/${parts[1]}`;
  const files = packFiles(library, pack);
  let hits = files.filter((f) => f.name === parts[2]);
  let convert = false;
  if (!hits.length && /\.flac$/i.test(parts[2])) {
    const wav = parts[2].replace(/\.flac$/i, '.wav');
    hits = files.filter((f) => f.name.toLowerCase() === wav.toLowerCase());
    convert = hits.length > 0;
  }
  if (!hits.length) throw new Error(`${id}: no such file in the library pack`);
  if (hits.length > 1) throw new Error(`${id}: ${hits.length} files of that name in the pack (${hits.map((h) => h.rel).join(', ')})`);
  return { file: hits[0].file, rel: hits[0].rel, convert };
}
