// game-build.mjs: builds a test page of the whole game for the game's smoke checks (W4), the same way build.mjs
// builds the deliverable (one self-contained HTML file: the esbuild bundle of src/main.js plus the inlined world data
// and textures), with "@rovloc/game" resolved to a chosen entry.
//
//   node tools/game-build.mjs [--entry src/game/index.js] [--out dist/Rovloc-game-test.html] [--no-minify]

import { build } from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';

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

if (!fs.existsSync(entry)) {
  console.error(`game-build: no entry at ${entry}`);
  process.exit(1);
}
const result = await build({
  entryPoints: [path.join(web, 'src/main.js')],
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: ['chrome100'],
  minify,
  write: false,
  legalComments: 'none',
  logLevel: 'warning',
  nodePaths: [path.join(web, 'node_modules')],
  define: { 'process.env.NODE_ENV': '"production"' },
  plugins: [{
    name: 'rovloc-game',
    setup(b) {
      b.onResolve({ filter: /^@rovloc\/game$/ }, () => ({ path: entry }));
    },
  }],
});
const js = result.outputFiles[0].text.replace(/<\/script/gi, '<\\/script');
const gz = (buf) => zlib.gzipSync(buf, { level: 6 });
const texDir = path.join(buildDir, 'textures');
const textures = fs.existsSync(texDir) ? fs.readdirSync(texDir).filter((f) => f.endsWith('.webp')).sort() : [];
const tag = (id, content) => `<script type="application/x-rovloc" id="${id}">${content}</script>`;
const tags = [
  tag('rv-world-json', gz(fs.readFileSync(path.join(buildDir, 'world.json'))).toString('base64')),
  tag('rv-world-bin', gz(fs.readFileSync(path.join(buildDir, 'world.bin'))).toString('base64')),
  tag('rv-textures', JSON.stringify(textures.map((f) => `textures/${f}`))),
  ...textures.map((f) => tag(`rv-tex:textures/${f}`, fs.readFileSync(path.join(texDir, f)).toString('base64'))),
];
const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>Rovloc</title>
<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#rv-root{position:fixed;inset:0}</style>
</head><body><div id="rv-root"></div>
${tags.join('\n')}
<script>${js}</script>
</body></html>
`;
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, html);
console.log(`game-build: ${path.relative(web, out)} ${(Buffer.byteLength(html) / 1048576).toFixed(1)} MB (entry ${path.relative(web, entry)})`);
