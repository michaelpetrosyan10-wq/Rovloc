// board.mjs (npm run sounds:board [-- --no-check]): the sound board, web/build/soundboard/, for the player to judge
// every sound by ear on a Chromebook. A self-contained static page (no framework, no external request) plus the audio:
//
//   index.html                 the page (its script and style inline; the sounds' list and the distance model too)
//   audio/<family>/*.mp3        the shipped files, fetched and decoded over http
//   audio/space/corridor.mp3    the shared convolver's impulse response (the Near / Mid / Far switch)
//   data/<family>.js            the same files as base64, loaded by <script> when the page is opened by double-click
//                               (file:// pages cannot fetch)
//
// Sounds are grouped under plain headings; a big play button per sound cycles its variants; "Play the group"; a
// Near / Mid / Far switch plays positional sounds through the game's distance model (10 / 40 / 80 studs, the same
// heard() as kit/distance.mjs); a volume slider. Audio starts only on a click.
// Then it checks the page in headless Chromium, over http and from the file: it loads, every file decodes, a click
// plays, the console is clean.

import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { ROOT, BOARD } from './lib/voices.mjs';
import { heard, WALL_CUTOFFS, CRITICAL_DISTANCE, MAX_REVERB } from './kit/distance.mjs';
import { loadPlaywright } from './lib/browser.mjs';

const BUILD = path.resolve(ROOT, '..', 'build');
const AUDIO = path.join(BUILD, 'audio');
const OUT = path.join(BUILD, 'soundboard');
const DISTANCES = { Near: 10, Mid: 40, Far: 80 };

function build() {
  const manifest = JSON.parse(fs.readFileSync(path.join(AUDIO, 'manifest.json'), 'utf8'));
  fs.rmSync(OUT, { recursive: true, force: true });
  fs.mkdirSync(path.join(OUT, 'data'), { recursive: true });
  const sounds = Object.values(manifest.sounds).filter((s) => s.variants.length);
  const families = {};
  for (const s of sounds) {
    for (const v of s.variants) {
      const dst = path.join(OUT, 'audio', v.file);
      fs.mkdirSync(path.dirname(dst), { recursive: true });
      fs.copyFileSync(path.join(AUDIO, v.file), dst);
      (families[s.family] ??= {})[v.file] = fs.readFileSync(dst).toString('base64');
    }
  }
  const ir = 'space/corridor.mp3';
  fs.mkdirSync(path.join(OUT, 'audio', 'space'), { recursive: true });
  fs.copyFileSync(path.join(AUDIO, ir), path.join(OUT, 'audio', ir));
  (families.space ??= {})[ir] = fs.readFileSync(path.join(OUT, 'audio', ir)).toString('base64');
  for (const [family, files] of Object.entries(families)) {
    fs.writeFileSync(path.join(OUT, 'data', `${family}.js`), `(window.BOARD_DATA = window.BOARD_DATA || {}, Object.assign(window.BOARD_DATA, ${JSON.stringify(files)}));\n`);
  }
  const list = sounds.map((s) => ({
    name: s.name, family: s.family, title: s.title, description: s.description, board: s.board, him: !!s.him,
    loop: s.loop, space: s.space, carry: s.carry, files: s.variants.map((v) => v.file), loopPoints: s.variants.map((v) => v.loop),
  }));
  const groups = BOARD.filter((b) => list.some((s) => s.board === b));
  const bytes = Object.values(manifest.sounds).reduce((t, s) => t + s.variants.reduce((u, v) => u + v.bytes, 0), 0);
  fs.writeFileSync(path.join(OUT, 'index.html'), page(list, groups, ir, bytes));
  return { sounds: list.length, files: list.reduce((t, s) => t + s.files.length, 0), groups };
}

function page(list, groups, ir, bytes) {
  const model = `const WALL_CUTOFFS = ${JSON.stringify(WALL_CUTOFFS)};\nconst CRITICAL_DISTANCE = ${CRITICAL_DISTANCE};\nconst MAX_REVERB = ${MAX_REVERB};\n${heard.toString()}`;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Rovloc Sound Board</title>
<style>
:root { --bg: #0b0b0f; --card: #16161d; --line: #2a2a35; --text: #ecebf2; --muted: #9a98a8; --accent: #e0483e; --play: #f2c14e; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 16px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
header { position: sticky; top: 0; z-index: 2; background: rgba(11, 11, 15, 0.96); border-bottom: 1px solid var(--line); padding: 12px 16px; }
h1 { margin: 0 0 4px; font-size: 22px; letter-spacing: 0.02em; }
.intro { margin: 0 0 10px; color: var(--muted); font-size: 14px; max-width: 70ch; }
.controls { display: flex; flex-wrap: wrap; gap: 12px 20px; align-items: center; }
.seg { display: inline-flex; border: 1px solid var(--line); border-radius: 10px; overflow: hidden; }
.seg button { background: transparent; color: var(--text); border: 0; padding: 8px 14px; font: inherit; cursor: pointer; min-height: 40px; }
.seg button[aria-pressed="true"] { background: var(--accent); color: #fff; }
label.vol { display: inline-flex; align-items: center; gap: 8px; color: var(--muted); }
input[type=range] { width: 160px; accent-color: var(--accent); }
main { padding: 8px 16px 48px; max-width: 1200px; margin: 0 auto; }
section { margin-top: 26px; }
.sechead { display: flex; align-items: center; justify-content: space-between; gap: 12px; border-bottom: 1px solid var(--line); padding-bottom: 6px; }
h2 { margin: 0; font-size: 19px; }
.group { background: transparent; color: var(--play); border: 1px solid var(--line); border-radius: 10px; padding: 8px 12px; font: inherit; cursor: pointer; min-height: 40px; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 12px; margin-top: 12px; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 12px; display: flex; gap: 12px; align-items: flex-start; }
.card.playing { border-color: var(--play); }
.play { flex: 0 0 64px; height: 64px; border-radius: 50%; border: 0; background: var(--play); color: #111; font: 700 13px/1 system-ui, sans-serif; cursor: pointer; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 4px; }
.play .tri { width: 0; height: 0; border-left: 16px solid #111; border-top: 10px solid transparent; border-bottom: 10px solid transparent; margin-left: 4px; }
.play.on .tri { border: 0; width: 14px; height: 14px; background: #111; margin: 0; }
.card h3 { margin: 0 0 4px; font-size: 16px; }
.card p { margin: 0; color: var(--muted); font-size: 14px; }
.tag { display: inline-block; margin-top: 6px; font-size: 12px; color: var(--muted); border: 1px solid var(--line); border-radius: 6px; padding: 1px 6px; }
footer { color: var(--muted); font-size: 13px; padding: 0 16px 32px; max-width: 1200px; margin: 0 auto; }
@media (max-width: 420px) { input[type=range] { width: 120px; } .play { flex-basis: 56px; height: 56px; } }
</style>
</head>
<body>
<header>
  <h1>Rovloc Sound Board</h1>
  <p class="intro">Every new sound of the game. Press a sound to hear it; press again for the next version of it. Near, Mid and Far play the sounds that happen at a place as you would hear them 10, 40 and 80 studs away down a corridor.</p>
  <div class="controls">
    <div class="seg" role="group" aria-label="Distance">${Object.keys(DISTANCES).map((d, k) => `<button type="button" data-distance="${d}" aria-pressed="${k === 0}">${d}</button>`).join('')}</div>
    <label class="vol">Volume <input id="volume" type="range" min="0" max="1" step="0.01" value="0.7"></label>
  </div>
</header>
<main id="board"></main>
<footer>${list.length} sounds, ${(bytes / 1048576).toFixed(1)} MB of audio. Every sound is made by the game's own code; nothing is recorded.</footer>
<script>
"use strict";
const SOUNDS = ${JSON.stringify(list)};
const GROUPS = ${JSON.stringify(groups)};
const IR = ${JSON.stringify(ir)};
const DISTANCES = ${JSON.stringify(DISTANCES)};
${model}

const state = { ctx: null, master: null, convolver: null, distance: 'Near', buffers: new Map(), next: new Map(), playing: new Map(), loaded: new Set(), lastPlayed: null, errors: [] };
window.__board = state;

function bytesOf(b64) {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src;
    s.onload = resolve;
    s.onerror = () => reject(new Error('could not load ' + src));
    document.head.appendChild(s);
  });
}

/** The encoded bytes of a file: fetched over http, or from data/<family>.js when the page is a local file. */
async function bytesFor(file) {
  if (location.protocol !== 'file:') {
    const res = await fetch('audio/' + file);
    if (!res.ok) throw new Error(file + ': ' + res.status);
    return res.arrayBuffer();
  }
  const family = file.split('/')[0];
  if (!state.loaded.has(family)) {
    await loadScript('data/' + family + '.js');
    state.loaded.add(family);
  }
  return bytesOf(window.BOARD_DATA[file]);
}

async function buffer(file) {
  if (!state.buffers.has(file)) state.buffers.set(file, bytesFor(file).then((b) => state.ctx.decodeAudioData(b)));
  return state.buffers.get(file);
}

async function start() {
  if (state.ctx) {
    if (state.ctx.state === 'suspended') await state.ctx.resume();
    return;
  }
  state.ctx = new AudioContext({ sampleRate: 48000 });
  state.master = state.ctx.createGain();
  state.master.gain.value = Number(document.getElementById('volume').value);
  state.master.connect(state.ctx.destination);
  state.convolver = state.ctx.createConvolver();
  state.convolver.normalize = false;
  state.convolver.connect(state.master);
  state.convolver.buffer = await buffer(IR);
}

function stop(sound) {
  const p = state.playing.get(sound.name);
  if (!p) return;
  const t = state.ctx.currentTime;
  p.out.gain.setTargetAtTime(0, t, 0.03);
  p.src.stop(t + 0.2);
  state.playing.delete(sound.name);
}

/** Plays a sound's next variant; resolves when it ends (a loop: after one pass). */
async function play(sound, card) {
  await start();
  const n = state.next.get(sound.name) ?? 0;
  state.next.set(sound.name, (n + 1) % sound.files.length);
  const buf = await buffer(sound.files[n]);
  stop(sound);
  const ctx = state.ctx;
  const src = ctx.createBufferSource();
  src.buffer = buf;
  const out = ctx.createGain();
  out.connect(state.master);
  let chain = src;
  if (sound.space === 'dry' && sound.carry) {
    const h = heard(DISTANCES[state.distance], 0, sound.carry);
    const lp = ctx.createBiquadFilter();
    lp.type = 'lowpass';
    lp.frequency.value = Math.min(h.cutoff, 20000);
    lp.Q.value = Math.SQRT1_2;
    src.connect(lp);
    const direct = ctx.createGain();
    direct.gain.value = h.direct;
    const send = ctx.createGain();
    send.gain.value = h.send;
    lp.connect(direct).connect(out);
    lp.connect(send).connect(state.convolver);
    chain = null;
  }
  if (chain) chain.connect(out);
  const loop = sound.loopPoints[n];
  if (loop) {
    src.loop = true;
    src.loopStart = loop.start;
    src.loopEnd = loop.end;
  }
  const t = ctx.currentTime + 0.02;
  src.start(t, loop ? loop.start : 0);
  if (loop) src.stop(t + (loop.end - loop.start) + 0.05);
  state.playing.set(sound.name, { src, out });
  state.lastPlayed = { name: sound.name, variant: n + 1, at: t };
  card.classList.add('playing');
  card.querySelector('.play').classList.add('on');
  card.querySelector('.count').textContent = (n + 1) + '/' + sound.files.length;
  return new Promise((resolve) => {
    src.onended = () => {
      if (state.playing.get(sound.name)?.src === src) state.playing.delete(sound.name);
      card.classList.remove('playing');
      card.querySelector('.play').classList.remove('on');
      resolve();
    };
  });
}

function render() {
  const main = document.getElementById('board');
  for (const g of GROUPS) {
    const sec = document.createElement('section');
    const head = document.createElement('div');
    head.className = 'sechead';
    const h2 = document.createElement('h2');
    h2.textContent = g;
    const all = document.createElement('button');
    all.className = 'group';
    all.type = 'button';
    all.textContent = 'Play the group';
    head.append(h2, all);
    const grid = document.createElement('div');
    grid.className = 'grid';
    const cards = [];
    for (const s of SOUNDS.filter((x) => x.board === g)) {
      const card = document.createElement('div');
      card.className = 'card';
      card.dataset.sound = s.name;
      const btn = document.createElement('button');
      btn.className = 'play';
      btn.type = 'button';
      btn.setAttribute('aria-label', 'Play ' + s.title);
      btn.innerHTML = '<span class="tri"></span><span class="count">1/' + s.files.length + '</span>';
      const text = document.createElement('div');
      const h3 = document.createElement('h3');
      h3.textContent = s.title;
      const p = document.createElement('p');
      p.textContent = s.description;
      const tag = document.createElement('span');
      tag.className = 'tag';
      tag.textContent = (s.space === 'dry' ? 'at a place' : 'all around you') + (s.loop ? ' · loop' : '') + (s.files.length > 1 ? ' · ' + s.files.length + ' versions' : '');
      text.append(h3, p, tag);
      card.append(btn, text);
      btn.addEventListener('click', () => {
        if (state.playing.has(s.name) && s.loop) {
          stop(s);
          return;
        }
        play(s, card).catch((e) => state.errors.push(String(e)));
      });
      grid.append(card);
      cards.push([s, card]);
    }
    all.addEventListener('click', async () => {
      for (const [s, card] of cards) {
        await play(s, card).catch((e) => state.errors.push(String(e)));
        await new Promise((r) => setTimeout(r, 350));
      }
    });
    sec.append(head, grid);
    main.append(sec);
  }
}

document.querySelectorAll('[data-distance]').forEach((b) => b.addEventListener('click', () => {
  state.distance = b.dataset.distance;
  document.querySelectorAll('[data-distance]').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
}));
document.getElementById('volume').addEventListener('input', (e) => {
  if (state.master) state.master.gain.value = Number(e.target.value);
});
render();

/** For the headless check: decodes every file (after a click has started the audio). */
window.__decodeAll = async () => {
  await start();
  const files = [IR, ...SOUNDS.flatMap((s) => s.files)];
  let ok = 0;
  const failed = [];
  for (const f of files) {
    try {
      const b = await buffer(f);
      if (b.length > 0) ok++;
    } catch (e) {
      failed.push(f + ': ' + e);
    }
  }
  return { files: files.length, ok, failed };
};
</script>
</body>
</html>
`;
}

/** Serves OUT over http on a free port. */
function serve() {
  const types = { '.html': 'text/html', '.js': 'text/javascript', '.mp3': 'audio/mpeg' };
  const server = http.createServer((req, res) => {
    const rel = decodeURIComponent((req.url ?? '/').split('?')[0]).replace(/^\/+/, '') || 'index.html';
    const file = path.join(OUT, rel);
    if (!file.startsWith(OUT) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
      res.writeHead(404);
      res.end();
      return;
    }
    res.writeHead(200, { 'content-type': types[path.extname(file)] ?? 'application/octet-stream' });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

async function check(url, label) {
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 380, height: 800 } });
  const consoleErrors = [];
  page.on('console', (m) => {
    if (m.type() === 'error' || m.type() === 'warning') consoleErrors.push(m.text());
  });
  page.on('pageerror', (e) => consoleErrors.push(String(e)));
  const requests = [];
  page.on('request', (r) => {
    const u = r.url();
    if (!u.startsWith(url.replace(/index\.html$/, '')) && !u.startsWith('data:')) requests.push(u);
  });
  await page.goto(url);
  const cards = await page.locator('.card').count();
  const before = await page.evaluate(() => (window.__board.ctx ? window.__board.ctx.state : 'none'));
  await page.locator('.card .play').first().click();
  await page.waitForFunction(() => window.__board.lastPlayed !== null, null, { timeout: 15000 });
  const played = await page.evaluate(() => ({ last: window.__board.lastPlayed, ctx: window.__board.ctx.state }));
  await page.locator('[data-distance="Far"]').click();
  await page.locator('.card .play').nth(1).click();
  await page.waitForFunction(() => window.__board.lastPlayed && window.__board.lastPlayed.name !== null, null, { timeout: 15000 });
  const decoded = await page.evaluate(() => window.__decodeAll());
  const width = await page.evaluate(() => ({ scroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth }));
  await browser.close();
  const problems = [];
  if (before !== 'none') problems.push('audio started before a click');
  if (!played.last || played.ctx !== 'running') problems.push(`a click did not play (${JSON.stringify(played)})`);
  if (decoded.ok !== decoded.files) problems.push(`${decoded.files - decoded.ok} files did not decode: ${decoded.failed.slice(0, 3).join('; ')}`);
  if (consoleErrors.length) problems.push(`console: ${consoleErrors.slice(0, 3).join(' | ')}`);
  if (requests.length) problems.push(`external requests: ${requests.slice(0, 3).join(', ')}`);
  if (width.scroll > width.client) problems.push(`horizontal scroll at 380 px (${width.scroll} > ${width.client})`);
  console.log(`${label}: ${cards} sounds on the page; a click played ${played.last ? `${played.last.name} #${played.last.variant}` : 'nothing'} (audio ${played.ctx}); ${decoded.ok}/${decoded.files} files decoded; console ${consoleErrors.length ? 'NOT clean' : 'clean'}; ${requests.length} external requests; no horizontal scroll at 380 px: ${width.scroll <= width.client}`);
  return problems;
}

async function main() {
  const built = build();
  console.log(`board: ${path.relative(path.resolve(ROOT, '..'), OUT)}/index.html, ${built.sounds} sounds (${built.files} files) under ${built.groups.join(', ')}`);
  if (process.argv.includes('--no-check')) return;
  const server = await serve();
  const { port } = /** @type {import('node:net').AddressInfo} */ (server.address());
  const problems = [];
  try {
    problems.push(...(await check(`http://127.0.0.1:${port}/index.html`, 'over http')));
    problems.push(...(await check(pathToFileURL(path.join(OUT, 'index.html')).href, 'by double-click (file://)')));
  } finally {
    server.close();
  }
  if (problems.length) {
    console.log(`FAIL:\n  ${problems.join('\n  ')}`);
    process.exit(1);
  }
  console.log('board: pass');
}

await main();
