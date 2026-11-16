// assets.mjs: what build.mjs and game-build.mjs share: the esbuild bundle, the world data, the texture sets per
// graphics tier, and the two ways of shipping them.
//
//   * The site (writeSite): index.html plus content-hashed assets/ (the bundle, world.json.gz, world.bin.gz, every
//     texture map of every tier set, the decal and wear atlases). The page carries an asset manifest (an inline JSON
//     script, `rv-manifest`) naming every asset; it boots on the 256 px set (the Potato colour maps: the first
//     fetches, a few hundred KB) and streams the tier's own set in the background (src/engine/textures.js), so a
//     Chromebook on Potato downloads only light assets. Hashed names never change for the same bytes: they cache
//     forever (vercel.json); index.html revalidates. Every reference is relative to the page (`assets/<name>`), so
//     the site works from whatever path its directory is served at (the beta at /beta/).
//   * A single file (writeSingleFile): the same page with every byte inline (base64 in non-executed script tags,
//     `inline:<id>` in the manifest): the offline "lite" build (dist/Rovloc-lite.html: the Low and Potato sets) and
//     the headless test pages. It runs from file:// with no request at all.
//
// The texture sets come from build/textures/textures.json (tools/textures.py: `tiers[size].maps`); the atlases from
// world.json (meta.textures entries with `atlas`). A build may carry a stamp (`stamp` in the manifest, build.mjs
// --stamp "BETA 10 NOV"): the title screen shows it, so a player can tell which build is on screen.
//
// The sounds (soundPacks): every MP3 web/sounds rendered (build/audio, `npm run sounds`), end to end in two packs:
// `first` (what a stage needs at once: him, the scares, footsteps, doors: fetched and decoded before the first frame)
// and `rest` (fetched and decoded in the background), with the index the game's sound bank reads
// (src/engine/audio/bank.js) in the manifest's `audio`. A site ships the packs as hashed assets, a single file as
// base64. The build stops when a render is missing or stale.

import { build } from 'esbuild';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

export const TIER_SIZES = [2048, 1024, 512, 256];
export const BOOT_SIZE = 256;
/** The rate the game decodes a dark sound at (half the samples of 48 kHz; bank.js). */
const DARK_RATE = 24000;
const FULL_RATE = 48000;

/** The esbuild bundle of src/main.js with "@rovloc/game" resolved to `entry`. */
export async function bundle(web, entry, { minify = true } = {}) {
  const result = await build({
    entryPoints: [path.join(web, 'src/main.js')],
    bundle: true,
    format: 'iife',
    platform: 'browser',
    target: ['chrome100'],
    minify,
    sourcemap: false,
    legalComments: 'none',
    write: false,
    nodePaths: [path.join(web, 'node_modules')],
    plugins: [{
      name: 'rovloc-modules',
      setup(b) {
        b.onResolve({ filter: /^@rovloc\/game$/ }, () => ({ path: entry }));
      },
    }],
    logLevel: 'warning',
    define: { 'process.env.NODE_ENV': '"production"' },
  });
  return result.outputFiles[0].text;
}

/** world.json + world.bin, gzipped, and the parsed metadata. */
export function readWorld(buildDir, level = 9) {
  const jsonPath = path.join(buildDir, 'world.json');
  const binPath = path.join(buildDir, 'world.bin');
  if (!fs.existsSync(jsonPath) || !fs.existsSync(binPath)) {
    throw new Error('build/world.json and build/world.bin are missing: run `npm run data` first (W1 tools).');
  }
  const json = fs.readFileSync(jsonPath);
  const meta = JSON.parse(json.toString('utf8'));
  return {
    meta,
    jsonGz: zlib.gzipSync(json, { level }),
    binGz: zlib.gzipSync(fs.readFileSync(binPath), { level }),
  };
}

/**
 * The texture sets per size (relative paths under build/) and the atlases: { sets: { [size]: { maps: { [id]: {
 * [kind]: path } }, bytes } }, atlases: { [id]: { color: path } } }.
 */
export function textureSets(buildDir, meta) {
  const index = path.join(buildDir, 'textures', 'textures.json');
  const sets = {};
  if (fs.existsSync(index)) {
    const t = JSON.parse(fs.readFileSync(index, 'utf8'));
    for (const [id, entry] of Object.entries(t.textures || {})) {
      for (const [size, tier] of Object.entries(entry.tiers || {})) {
        const set = sets[size] || (sets[size] = { maps: {}, bytes: 0 });
        set.maps[id] = tier.maps;
      }
    }
  }
  if (!Object.keys(sets).length) {
    // an old textures.json (one set, no tiers): ship it as the only set
    const set = { maps: {}, bytes: 0 };
    for (const [id, t] of Object.entries(meta.textures || {})) if (!t.atlas && t.maps) set.maps[id] = t.maps;
    sets[String(BOOT_SIZE)] = set;
  }
  const atlases = {};
  for (const [id, t] of Object.entries(meta.textures || {})) if (t.atlas && t.maps && t.maps.color) atlases[id] = { color: t.maps.color };
  for (const set of Object.values(sets)) {
    for (const maps of Object.values(set.maps)) {
      for (const p of Object.values(maps)) {
        const file = path.join(buildDir, p);
        if (!fs.existsSync(file)) throw new Error(`textures.json names ${p}, which is missing from build/`);
        set.bytes += fs.statSync(file).size;
      }
    }
  }
  for (const a of Object.values(atlases)) {
    if (!fs.existsSync(path.join(buildDir, a.color))) throw new Error(`world.json names ${a.color}, which is missing from build/`);
  }
  return { sets, atlases };
}

/**
 * The rendered sounds, packed for the page: { packs: {first, rest} (the MP3s end to end), sounds: the bank's index
 * (name -> {p, f, r, c, l, v}), files, bytes }. `keep` (a voice -> boolean) packs a part of them. Throws when a
 * render is missing or older than its recipe.
 * @param {string} buildDir
 * @param {(voice: any) => boolean} [keep]
 */
export async function soundPacks(buildDir, keep = () => true) {
  const { loadVoices } = await import('../sounds/lib/voices.mjs');
  const { pendingRenders } = await import('../sounds/render.mjs');
  const voices = await loadVoices();
  const { jobs } = pendingRenders(voices);
  if (jobs.length) {
    const some = jobs.slice(0, 4).map((j) => `${j.name}-${j.variant}`).join(', ');
    throw new Error(`${jobs.length} sound renders are missing or stale (${some}${jobs.length > 4 ? ', ...' : ''}): run \`npm run sounds\` first.`);
  }
  const manifestFile = path.join(buildDir, 'audio', 'manifest.json');
  if (!fs.existsSync(manifestFile)) throw new Error('build/audio/manifest.json is missing: run `npm run sounds` first.');
  const rendered = JSON.parse(fs.readFileSync(manifestFile, 'utf8')).sounds;
  const parts = { first: [], rest: [] };
  const sizes = { first: 0, rest: 0 };
  const sounds = {};
  let files = 0;
  for (const voice of voices.filter(keep)) {
    const r = rendered[voice.name];
    if (!r || r.variants.length !== voice.variants) throw new Error(`build/audio/manifest.json does not have every render of ${voice.name}: run \`npm run sounds\` first.`);
    const pack = voice.first ? 'first' : 'rest';
    const entry = { p: pack, r: r.variants.every((v) => v.dark) ? DARK_RATE : FULL_RATE, c: voice.channels, v: [] };
    if (voice.first) entry.f = 1;
    // every variant of a loop has the same loop points (the pipeline's margins)
    if (voice.loop) entry.l = [r.variants[0].loop.start, r.variants[0].loop.end];
    for (const v of r.variants) {
      const buf = fs.readFileSync(path.join(buildDir, 'audio', v.file));
      entry.v.push([sizes[pack], buf.length, v.fileSeconds]);
      parts[pack].push(buf);
      sizes[pack] += buf.length;
      files++;
    }
    sounds[voice.name] = entry;
  }
  return { packs: { first: Buffer.concat(parts.first), rest: Buffer.concat(parts.rest) }, sounds, files, bytes: sizes.first + sizes.rest };
}

/** The boot set: the smallest size there is (256 when the tiers are built). */
export function bootSize(sets) {
  return Math.min(...Object.keys(sets).map(Number));
}

const STYLE = 'html,body{margin:0;height:100%;background:#000;overflow:hidden}#rv-root{position:fixed;inset:0}';

function csp(realtimeHost, site) {
  const supabase = realtimeHost ? ` wss://${realtimeHost} https://${realtimeHost}` : '';
  return site
    ? `default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data: blob:; media-src data: blob:; worker-src blob:; connect-src 'self' data: blob:${supabase}`
    : `default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; worker-src blob:; connect-src data: blob:${supabase}`;
}

/** JSON safe inside a script tag. */
function scriptJson(value) {
  return JSON.stringify(value).replace(/</g, '\\u003c');
}

export const STAMP_LIMIT = 24;

/**
 * A build stamp as the title screen shows it ("BETA 10 NOV"): trimmed, one line of printable characters, at most
 * STAMP_LIMIT of them. Null for no stamp; throws on one the title cannot show.
 */
export function buildStamp(text) {
  if (text === null || text === undefined) return null;
  const stamp = String(text).trim();
  if (!stamp) return null;
  if (stamp.length > STAMP_LIMIT) throw new Error(`the build stamp "${stamp}" is longer than ${STAMP_LIMIT} characters`);
  if (/[^\x20-\x7e]/.test(stamp)) throw new Error(`the build stamp "${stamp}" has characters outside printable ASCII`);
  return stamp;
}

/**
 * One self-contained page: world and the texture sets of `inlineSizes` inline.
 * @returns {{bytes: number, sets: Record<string, number>}}
 */
export function writeSingleFile({ out, js, world, buildDir, textures, audio = null, inlineSizes, realtimeHost = null, title = 'Rovloc', policy = true, defaultTier = null, stamp = null }) {
  const tags = [];
  const tag = (id, content) => tags.push(`<script type="application/x-rovloc" id="${id}">${content}</script>`);
  tag('rv-world-json', world.jsonGz.toString('base64'));
  tag('rv-world-bin', world.binGz.toString('base64'));
  const audioPacks = {};
  for (const [id, buf] of Object.entries(audio ? audio.packs : {})) {
    if (!buf.length) continue;
    tag(`rv-audio-${id}`, buf.toString('base64'));
    audioPacks[id] = `inline:rv-audio-${id}`;
  }
  const inlined = new Map();
  const ref = (p) => {
    if (!inlined.has(p)) {
      const id = `rv-tex:${p}`;
      inlined.set(p, id);
      tag(id, fs.readFileSync(path.join(buildDir, p)).toString('base64'));
    }
    return `inline:${inlined.get(p)}`;
  };
  const sizes = inlineSizes.filter((s) => textures.sets[String(s)]).map(String);
  if (!sizes.length) sizes.push(String(bootSize(textures.sets)));
  const sets = {};
  const setBytes = {};
  for (const size of sizes) {
    const set = textures.sets[size];
    const maps = {};
    for (const [id, m] of Object.entries(set.maps)) {
      maps[id] = {};
      for (const [kind, p] of Object.entries(m)) maps[id][kind] = ref(p);
    }
    sets[size] = { inline: true, maps };
    setBytes[size] = set.bytes;
  }
  const atlases = {};
  for (const [id, a] of Object.entries(textures.atlases)) atlases[id] = { color: ref(a.color) };
  const mark = buildStamp(stamp);
  const manifest = {
    version: 2,
    world: { json: 'inline:rv-world-json', bin: 'inline:rv-world-bin' },
    textures: { boot: Math.min(...sizes.map(Number)), sets, atlases },
    // the recorded sounds (a page without them plays every sound from its old recipe)
    ...(audio ? { audio: { packs: audioPacks, sounds: audio.sounds } } : {}),
    // the Graphics tier a player without a saved choice starts on (the lite build: Potato, it is for Chromebooks)
    ...(defaultTier ? { defaultTier } : {}),
    // the build's stamp, shown small on the title screen (a beta names itself; nothing without one)
    ...(mark ? { stamp: mark } : {}),
  };
  const safeJs = js.replace(/<\/script/gi, '<\\/script');
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
${policy ? `<meta http-equiv="Content-Security-Policy" content="${csp(realtimeHost, false)}">\n` : ''}<title>${title}</title>
<style>${STYLE}</style>
</head>
<body>
<div id="rv-root"></div>
<script type="application/json" id="rv-manifest">${scriptJson(manifest)}</script>
${tags.join('\n')}
<script>${safeJs}</script>
</body>
</html>
`;
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, html);
  return { bytes: Buffer.byteLength(html), sets: setBytes };
}

function hashed(buf, name) {
  const h = crypto.createHash('sha256').update(buf).digest('hex').slice(0, 10);
  const dot = name.indexOf('.');
  return dot < 0 ? `${name}.${h}` : `${name.slice(0, dot)}.${h}${name.slice(dot)}`;
}

/**
 * The multi-file site in `dir`: index.html + assets/ (content-hashed, referenced relative to the page). Assets of
 * earlier builds that this one no longer names are removed from assets/.
 * @returns {{files: number, bytes: number, boot: Record<string, number>, sets: Record<string, number>, js: number, world: number}}
 */
export function writeSite({ dir, js, world, buildDir, textures, audio, realtimeHost = null, title = 'Rovloc', stamp = null }) {
  const assetsDir = path.join(dir, 'assets');
  fs.mkdirSync(assetsDir, { recursive: true });
  const written = new Set();
  let total = 0;
  const put = (buf, name) => {
    const file = hashed(buf, name);
    const target = path.join(assetsDir, file);
    if (!fs.existsSync(target) || fs.statSync(target).size !== buf.length) fs.writeFileSync(target, buf);
    written.add(file);
    total += buf.length;
    return `assets/${file}`;
  };
  const jsRef = put(Buffer.from(js), 'rovloc.js');
  const worldJson = put(world.jsonGz, 'world.json.gz');
  const worldBin = put(world.binGz, 'world.bin.gz');
  const sets = {};
  const setBytes = {};
  for (const [size, set] of Object.entries(textures.sets)) {
    const maps = {};
    for (const [id, m] of Object.entries(set.maps)) {
      maps[id] = {};
      for (const [kind, p] of Object.entries(m)) {
        maps[id][kind] = put(fs.readFileSync(path.join(buildDir, p)), `${id}_${kind}-${size}.webp`);
      }
    }
    sets[size] = { maps, bytes: set.bytes };
    setBytes[size] = set.bytes;
  }
  const atlases = {};
  let atlasBytes = 0;
  for (const [id, a] of Object.entries(textures.atlases)) {
    const buf = fs.readFileSync(path.join(buildDir, a.color));
    atlasBytes += buf.length;
    atlases[id] = { color: put(buf, path.basename(a.color)) };
  }
  const audioPacks = {};
  for (const [id, buf] of Object.entries(audio.packs)) if (buf.length) audioPacks[id] = put(buf, `audio-${id}.bin`);
  const boot = bootSize(textures.sets);
  const mark = buildStamp(stamp);
  const manifest = {
    version: 2,
    world: { json: worldJson, bin: worldBin, bytes: { json: world.jsonGz.length, bin: world.binGz.length } },
    textures: { boot, sets, atlases },
    audio: { packs: audioPacks, sounds: audio.sounds },
    ...(mark ? { stamp: mark } : {}),
  };
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<meta http-equiv="Content-Security-Policy" content="${csp(realtimeHost, true)}">
<title>${title}</title>
<style>${STYLE}</style>
<link rel="preload" href="${worldBin}" as="fetch" crossorigin="anonymous">
<link rel="preload" href="${worldJson}" as="fetch" crossorigin="anonymous">
</head>
<body>
<div id="rv-root"></div>
<script type="application/json" id="rv-manifest">${scriptJson(manifest)}</script>
<script src="${jsRef}"></script>
</body>
</html>
`;
  fs.writeFileSync(path.join(dir, 'index.html'), html);
  // remove what earlier builds left behind
  for (const f of fs.readdirSync(assetsDir)) if (!written.has(f)) fs.rmSync(path.join(assetsDir, f));
  return {
    files: written.size + 1,
    bytes: total + Buffer.byteLength(html),
    js: js.length,
    world: world.jsonGz.length + world.binGz.length,
    atlases: atlasBytes,
    audio: audio.bytes,
    audioFirst: audio.packs.first.length,
    boot: { [boot]: setBytes[String(boot)] },
    sets: setBytes,
    manifest,
  };
}
