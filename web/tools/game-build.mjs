// game-build.mjs: builds a test page of the whole game for the game's smoke checks (W4), the same way build.mjs
// builds its single-file pages (tools/assets.mjs: the esbuild bundle of src/main.js, the world data and the Low and
// Potato texture sets inline), with "@rovloc/game" resolved to a chosen entry.
//
//   node tools/game-build.mjs [--entry src/game/index.js] [--out dist/Rovloc-game-test.html] [--no-minify]
//                             [--textures 256,512]   the texture sets to inline (add 1024 / 2048 for higher tiers)
//                             [--tier Low]           the Graphics tier the page starts on while nothing is saved: Low,
//                                                    the tier the old automatic pick chose in headless (software GPU)
//                                                    runs; a test that wants another tier sets it

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { bundle, readWorld, textureSets, writeSingleFile } from './assets.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.resolve(here, '..');
const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const entry = path.resolve(web, opt('--entry', 'src/game/index.js'));
const out = path.resolve(web, opt('--out', 'dist/Rovloc-game-test.html'));
const minify = !argv.includes('--no-minify');
const buildDir = path.join(web, 'build');
const inlineSizes = opt('--textures', '256,512').split(',').map(Number);
const defaultTier = opt('--tier', 'Low');

if (!fs.existsSync(entry)) {
  console.error(`game-build: no entry at ${entry}`);
  process.exit(1);
}
const js = await bundle(web, entry, { minify });
const world = readWorld(buildDir, 6);
const textures = textureSets(buildDir, world.meta);
const r = writeSingleFile({ out, js, world, buildDir, textures, inlineSizes, policy: false, defaultTier });
console.log(`game-build: ${path.relative(web, out)} ${(r.bytes / 1048576).toFixed(1)} MB (entry ${path.relative(web, entry)}, texture sets ${Object.keys(r.sets).join(', ')}, starts on ${defaultTier})`);
