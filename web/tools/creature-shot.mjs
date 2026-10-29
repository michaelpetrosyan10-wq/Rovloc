// Screenshots of the Creature in the real engine (headless Playwright Chromium, SwiftShader WebGL).
//
//   node tools/creature-shot.mjs [--out <dir> (default: <os tmp>/rovloc-creature-shots)] [--stages idle,walk,...]
//                                [--width 1280 --height 720]
//
// Builds a single-file page with build.mjs --entry tools/creature-shot-entry.js (the engine, the world data and the
// Creature; the entry stands in for the game), opens it from file://, then for every stage: poses the Creature
// (window.__shot.stage), steps the frames it asks for by hand (deterministic 30 fps, drawing only the last) and
// saves <out>/creature-<stage>.png. Fails on a page error, a console error or an all-black capture.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.resolve(here, '..');
const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const outDir = path.resolve(opt('--out', path.join(os.tmpdir(), 'rovloc-creature-shots')));
const width = Number(opt('--width', 1280));
const height = Number(opt('--height', 720));
const page = path.join(outDir, 'creature-shot.html');

function loadPlaywright() {
  const require = createRequire(import.meta.url);
  const roots = [web, process.cwd()];
  try {
    roots.push(execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim());
  } catch { /* npm missing */ }
  roots.push('/opt/node22/lib/node_modules', '/usr/lib/node_modules', '/usr/local/lib/node_modules');
  for (const r of roots) {
    try {
      return require(require.resolve('playwright', { paths: [r] }));
    } catch { /* next */ }
  }
  throw new Error('playwright not found (it is expected pre-installed globally)');
}

async function main() {
  fs.mkdirSync(outDir, { recursive: true });
  execFileSync(process.execPath, [path.join(here, 'build.mjs'), '--entry', path.join(here, 'creature-shot-entry.js'), '--out', page],
    { stdio: 'inherit' });
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({
    args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--enable-webgl'],
  });
  const tab = await browser.newPage({ viewport: { width, height } });
  const errors = [];
  tab.on('console', (m) => {
    if (m.type() === 'error') errors.push(m.text());
  });
  tab.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
  await tab.goto(`file://${page}`);
  await tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 240000 });
  const bootError = await tab.evaluate(() => window.__rovloc.error);
  if (bootError) throw new Error(`boot failed: ${bootError} ${errors.join(' | ')}`);
  const place = await tab.evaluate(() => {
    const e = window.__rovloc.engine;
    e.loop.stop();
    e.quality.adapt = false;
    e.quality.probing = null;
    e.quality.setTier('High');
    return window.__shot.place;
  });
  console.log(`[creature-shot] ${place.level} ${place.room}: Creature at ${place.at.map((v) => v.toFixed(1)).join(', ')}, probe ${place.probe.toFixed(3)}`);
  const all = await tab.evaluate(() => window.__shot.stages);
  const wanted = opt('--stages', '') ? opt('--stages', '').split(',') : all;
  const saved = [];
  let failed = false;
  for (const stage of wanted) {
    const result = await tab.evaluate((name) => {
      const e = window.__rovloc.engine;
      const { frames } = window.__shot.stage(name);
      e.skipRender = true;
      for (let i = 0; i < frames - 1; i++) e.loop.stepManual(1 / 30);
      const m = e.measure(); // draws the last frame and reads it back
      e.skipRender = false;
      return { measure: m, snapshot: window.__shot.snapshot() };
    }, stage);
    const file = path.join(outDir, `creature-${stage}.png`);
    await tab.screenshot({ path: file, timeout: 180000 });
    saved.push(file);
    const m = result.measure;
    const ok = !!m && m.mean > 1;
    if (!ok) failed = true;
    const s = result.snapshot;
    console.log(`${ok ? 'SHOT' : 'DARK'}  ${stage.padEnd(10)} ${s.state}/${s.pose}${s.hidden ? ' hidden' : ''}  mean ${m ? m.mean.toFixed(1) : '-'}  ${path.relative(web, file)}`);
  }
  await browser.close();
  if (errors.length > 0) {
    failed = true;
    console.log(`errors: ${errors.slice(0, 6).join(' | ')}`);
  }
  console.log(failed ? '[creature-shot] FAILED' : `[creature-shot] ${saved.length} screenshots in ${outDir}`);
  process.exit(failed ? 1 : 0);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
