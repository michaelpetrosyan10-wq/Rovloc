// Builds the deliverable: ONE self-contained file, web/dist/Rovloc.html.
//
//   node tools/build.mjs [--sandbox | --entry <game module>] [--no-minify] [--out <file>]
//
// * esbuild bundles src/main.js (three, three-mesh-bvh and every module) into one IIFE. "@rovloc/game" resolves to
//   src/game/index.js (W4's game; --entry picks another module) or, while that does not exist or with --sandbox, to
//   the engine sandbox.
// * The world data is inlined: build/world.json and build/world.bin gzipped (level 9) and base64'd, every
//   build/textures/*.webp base64'd, each in its own non-executed <script type="application/x-rovloc"> tag that the
//   engine reads with textContent and inflates with DecompressionStream at boot.
// * No external URL anywhere: no CDN, no font, no fetch. The page runs from file:// on a school Chromebook offline.

import { build } from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.resolve(here, '..');
const args = new Set(process.argv.slice(2));
const sandbox = args.has('--sandbox');
const minify = !args.has('--no-minify');
const buildDir = path.join(web, 'build');
const distDir = path.join(web, 'dist');
const argv = process.argv.slice(2);
const outArg = argv.indexOf('--out');
const out = outArg >= 0 ? path.resolve(argv[outArg + 1]) : path.join(distDir, 'Rovloc.html');

function fail(message) {
  console.error(`build: ${message}`);
  process.exit(1);
}

const t0 = Date.now();
const worldJson = path.join(buildDir, 'world.json');
const worldBin = path.join(buildDir, 'world.bin');
if (!fs.existsSync(worldJson) || !fs.existsSync(worldBin)) {
  fail('build/world.json and build/world.bin are missing: run `npm run data` first (W1 tools).');
}

// ---------------------------------------------------------------------------------------------------- bundle
const entryArg = argv.indexOf('--entry');
const gameEntry = entryArg >= 0 ? path.resolve(argv[entryArg + 1]) : path.join(web, 'src/game/index.js');
const sandboxEntry = path.join(web, 'src/engine/sandbox.js');
const useGame = !sandbox && fs.existsSync(gameEntry);
const optionalModules = {
  name: 'rovloc-modules',
  setup(b) {
    b.onResolve({ filter: /^@rovloc\/game$/ }, () => ({ path: useGame ? gameEntry : sandboxEntry }));
  },
};
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
  plugins: [optionalModules],
  logLevel: 'warning',
  define: { 'process.env.NODE_ENV': '"production"' },
});
const js = result.outputFiles[0].text;
// ---------------------------------------------------------------------------------------------------- data
const gz = (buf) => zlib.gzipSync(buf, { level: 9 });
const jsonGz = gz(fs.readFileSync(worldJson));
const binGz = gz(fs.readFileSync(worldBin));
const texDir = path.join(buildDir, 'textures');
const textures = fs.existsSync(texDir)
  ? fs.readdirSync(texDir).filter((f) => f.endsWith('.webp')).sort()
  : [];
const meta = JSON.parse(fs.readFileSync(worldJson, 'utf8'));
const referenced = new Set();
for (const t of Object.values(meta.textures || {})) for (const p of Object.values(t.maps || {})) referenced.add(p);
for (const p of referenced) {
  if (!fs.existsSync(path.join(buildDir, p))) fail(`world.json references ${p}, which is missing from build/`);
}

const dataTag = (id, content) => `<script type="application/x-rovloc" id="${id}">${content}</script>`;
const tags = [
  dataTag('rv-world-json', jsonGz.toString('base64')),
  dataTag('rv-world-bin', binGz.toString('base64')),
  dataTag('rv-textures', JSON.stringify(textures.map((f) => `textures/${f}`))),
  ...textures.map((f) => dataTag(`rv-tex:textures/${f}`, fs.readFileSync(path.join(texDir, f)).toString('base64'))),
];

// ---------------------------------------------------------------------------------------------------- page
const safeJs = js.replace(/<\/script/gi, '<\\/script');
const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; worker-src blob:; connect-src data: blob:">
<title>Rovloc</title>
<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#rv-root{position:fixed;inset:0}</style>
</head>
<body>
<div id="rv-root"></div>
${tags.join('\n')}
<script>${safeJs}</script>
</body>
</html>
`;
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, html);

const mb = (n) => (n / 1048576).toFixed(2);
const texBytes = textures.reduce((s, f) => s + fs.statSync(path.join(texDir, f)).size, 0);
console.log(`build: ${path.relative(web, out)} ${mb(Buffer.byteLength(html))} MB ` +
  `(js ${mb(js.length)}, world.json.gz ${mb(jsonGz.length)}, world.bin.gz ${mb(binGz.length)}, ` +
  `textures ${mb(texBytes)} x${textures.length}; game: ${useGame ? 'src/game' : 'sandbox'}) in ${Date.now() - t0} ms`);
