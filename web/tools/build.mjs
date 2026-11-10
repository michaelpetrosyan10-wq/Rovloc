// Builds the website: a multi-file static site (what Vercel serves) and the single-file offline "lite" build,
// dist/Rovloc-lite.html.
//
//   node tools/build.mjs                    site/beta/ + dist/Rovloc-lite.html
//   node tools/build.mjs --site <dir>       the site only, into <dir>
//   node tools/build.mjs --lite <file>      the lite build only, into <file>
//   node tools/build.mjs --out <file>       one self-contained page (the test tools' pages): world + the Low and
//                                           Potato texture sets inline (--textures 256,512,1024 picks the sets),
//                                           starting on Low while nothing is saved (--tier picks another)
//   [--stamp "BETA 10 NOV"]                 the build's stamp, shown small on the title screen (at most 24 printable
//                                           characters); a build without it shows nothing
//   [--sandbox | --entry <game module>] [--no-minify]
//
// * esbuild bundles src/main.js (three, three-mesh-bvh and every module) into one IIFE. "@rovloc/game" resolves to
//   src/game/index.js (W4's game; --entry picks another module) or, while that does not exist or with --sandbox, to
//   the engine sandbox.
// * The site (tools/assets.mjs writeSite): index.html (the asset manifest inline) + assets/ with content-hashed names:
//   the bundle, world.json.gz, world.bin.gz, the decal and wear atlases and every texture map at every tier size
//   (2048 Max, 1024 High / Medium, 512 Low, 256 Potato). The page boots on the 256 set and streams its tier's set in
//   the background, so a Chromebook on Potato downloads only light assets. Every reference is relative to the page,
//   so the site works from the path its directory is served at.
// * Where it goes. site/ is what Vercel serves (site/vercel.json: the caching rules). site/index.html is the
//   published stable game, and no build writes it by default: the site is built into site/beta/, the work in
//   progress players test at rovloc.vercel.app/beta/, with a stamp naming the build (--stamp). vercel.json caches
//   beta/assets/ forever and revalidates beta/index.html. Promoting a build to the root is `--site ../site` (and
//   vercel.json's rules for /assets/ and / with it).
// * The lite build (writeSingleFile): every byte inline, the Low and Potato sets only, starting on Potato until the
//   player picks a tier; it runs from file:// on a school Chromebook offline.
// * Requests. The site fetches only its own assets (same origin); the lite page fetches nothing. Neither makes any
//   other request unless the player presses HOST or JOIN (co-op): then only the Supabase project's Realtime (wss /
//   https on its one host, allowed by the page's Content-Security-Policy connect-src) and the two STUN servers
//   (WebRTC, outside CSP). No CDN, no font.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { SupabaseProject } from '../src/net/config.js';
import { buildStamp, bundle, readWorld, textureSets, writeSingleFile, writeSite } from './assets.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const realtimeHost = new URL(SupabaseProject.url).host;
const web = path.resolve(here, '..');
const argv = process.argv.slice(2);
const opt = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : null;
};
const sandbox = argv.includes('--sandbox');
const minify = !argv.includes('--no-minify');
const buildDir = path.join(web, 'build');
const out = opt('--out') ? path.resolve(opt('--out')) : null;
let siteDir = opt('--site') ? path.resolve(opt('--site')) : null;
let lite = opt('--lite') ? path.resolve(opt('--lite')) : null;
if (!out && !siteDir && !lite) {
  // the beta: site/index.html (the published stable game) is never written by default
  siteDir = path.resolve(web, '..', 'site', 'beta');
  lite = path.join(web, 'dist', 'Rovloc-lite.html');
}
const inlineSizes = (opt('--textures') || '256,512').split(',').map(Number);
const testTier = opt('--tier') || 'Low';

function fail(message) {
  console.error(`build: ${message}`);
  process.exit(1);
}

let stamp = null;
try {
  stamp = buildStamp(opt('--stamp'));
  if (argv.includes('--stamp') && (!stamp || stamp.startsWith('--'))) throw new Error('--stamp needs the stamp\'s text, as in --stamp "BETA 10 NOV"');
} catch (err) {
  fail(err.message);
}

const t0 = Date.now();
const entryArg = opt('--entry');
const gameEntry = entryArg ? path.resolve(entryArg) : path.join(web, 'src/game/index.js');
const useGame = !sandbox && fs.existsSync(gameEntry);
const entry = useGame ? gameEntry : path.join(web, 'src/engine/sandbox.js');

let world;
let textures;
try {
  world = readWorld(buildDir);
  textures = textureSets(buildDir, world.meta);
} catch (err) {
  fail(err.message);
}
const js = await bundle(web, entry, { minify });
const mb = (n) => (n / 1048576).toFixed(2);
const what = useGame ? path.relative(web, entry).startsWith('src/game') ? 'src/game' : path.relative(web, entry) : 'sandbox';

if (siteDir) {
  const r = writeSite({ dir: siteDir, js, world, buildDir, textures, realtimeHost, stamp });
  const sets = Object.entries(r.sets).sort((a, b) => Number(b[0]) - Number(a[0])).map(([s, b]) => `${s}: ${mb(b)}`).join(', ');
  const boot = Object.values(r.boot)[0];
  console.log(`build: site ${path.relative(process.cwd(), siteDir) || '.'}/ ${r.files} files, ${mb(r.bytes)} MB ` +
    `(js ${mb(r.js)}, world ${mb(r.world)}, atlases ${mb(r.atlases)}, texture sets MB ${sets}); ` +
    `Potato boots on ${mb(r.js + r.world + r.atlases + boot)} MB; game: ${what}${stamp ? `; stamp "${stamp}"` : ''}`);
}
if (lite) {
  const r = writeSingleFile({ out: lite, js, world, buildDir, textures, inlineSizes: [256, 512], realtimeHost, defaultTier: 'Potato', stamp });
  console.log(`build: ${path.relative(web, lite)} ${mb(r.bytes)} MB single file (lite: the Low and Potato sets inline, Potato by default; game: ${what})`);
}
if (out) {
  const r = writeSingleFile({ out, js, world, buildDir, textures, inlineSizes, realtimeHost, defaultTier: testTier, stamp });
  console.log(`build: ${path.relative(web, out)} ${mb(r.bytes)} MB single file (sets ${Object.keys(r.sets).join(', ')}, starts on ${testTier}; game: ${what})`);
}
console.log(`build: done in ${Date.now() - t0} ms`);
