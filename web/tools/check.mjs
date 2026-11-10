// Headless verification with the pre-installed Playwright Chromium (`npm run check` builds first).
//
//   node tools/check.mjs [--shots <dir>] [--quick] [--no-perf] [--perf-only]
//
// 1. The website (site/, served over HTTP as Vercel serves it): boots, renders a non-black image (pixels read back from
//    the canvas), logs no console or page error, and fetches nothing but its own assets (same origin; anything else
//    fails). What a Chromebook on Potato downloads (the Graphics setting saved as Potato before the page loads) and
//    what Max streams after boot are measured from the page's resource timings: Potato must not fetch a texture
//    bigger than its 256 px set, nor any normal map.
// 1b. The lite build (dist/Rovloc-lite.html) from file://: boots and renders with no request at all.
// 1c. Co-op's network rule on the site: nothing but its own assets until the player presses HOST or JOIN, then only the
//    Supabase project's host (the page's CSP allows no other) and the STUN servers (WebRTC, outside CSP and request
//    events); pressing HOST without that network shows "Multiplayer can't connect on this network" and single-player
//    still plays.
// 2. The engine walk (a sandbox build of the same engine, served from build/cache/check-sandbox/, so the game's own
//    flow cannot hold the player): spawn in the Level 1 corridor; walking W moves the body along the floor (it neither
//    falls through nor floats), a wall stops it, a Level 0 crawlway's mouth stops a standing body and lets a crouched
//    one crawl through, Shift sprints and drains stamina, C crouches, F toggles the torch, a held E fills a prompt and
//    triggers it once, walking emits locomotion noise, an airlock door's leaves swung shut through the entity API
//    block rays (and open do not), decals and the creature rig build, the audio engine runs and every one of the 101
//    SynthPresets recipes renders non-silent, finite audio offline.
// 3. Performance per graphics tier (Max, High, Medium, Low, Potato) with the CPU throttled 4x
//    (Emulation.setCPUThrottlingRate), in the Level 1 hallway, the Level 0 tunnels, Level 2's west gallery and the
//    lobby: the main-thread time of a whole frame
//    (simulation + draw submission; median and p95 of 60 frames, measured on a tiny canvas so the software
//    rasterizer's backlog cannot stall it: the figure that carries over to a Chromebook CPU), its draw calls and
//    triangles, and the fps headless Chromium reaches at 1280x720. Headless WebGL is SwiftShader (CPU rasterization):
//    that fps is a floor far below any real GPU, and no school GPU (Intel UHD 600) can be emulated here. Potato must
//    fit 16.7 ms (60 fps) per frame.
// 4. Screenshots (--shots <dir>, default build/cache/shots), each asserted non-black: the main views, the same Level 0
//    tunnel and the lobby at every tier (tier-<Tier>-l0.png, tier-<Tier>-lobby.png) and the Graphics menu.
//
// The website runs W4's game when src/game/index.js exists: its start(engine) must resolve once its first screen is up
// (main.js sets window.__rovloc.ready then), and the world must be drawn behind it for the non-black test.
// Exit code 1 on any failure.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.resolve(here, '..');
const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : fallback;
};
const quick = argv.includes('--quick');
const noPerf = argv.includes('--no-perf');
// --perf-only: the tier measurements and screenshots alone (the sandbox site is built and served as usual)
const perfOnly = argv.includes('--perf-only');
const shotsDir = path.resolve(opt('--shots', path.join(web, 'build/cache/shots')));
const siteDir = path.resolve(web, '..', 'site');
const liteFile = path.join(web, 'dist/Rovloc-lite.html');
const sandboxDir = path.join(web, 'build/cache/check-sandbox');
const TIERS = ['Max', 'High', 'Medium', 'Low', 'Potato'];
// the boot and network checks need a rendered frame, not a big one (headless WebGL is a software rasterizer)
const SMALL = { width: 640, height: 360 };

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

const { chromium } = loadPlaywright();
const LAUNCH = {
  args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist',
    '--autoplay-policy=no-user-gesture-required', '--enable-webgl'],
};

const results = [];
let failed = false;
function report(ok, name, detail = '') {
  results.push({ ok, name, detail });
  if (!ok) failed = true;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  ${detail}` : ''}`);
}

const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.json': 'application/json',
  '.gz': 'application/gzip', '.webp': 'image/webp', '.png': 'image/png', '.md': 'text/plain' };

/** A static server for the site (/) and the sandbox site (/sandbox/), as Vercel serves site/. */
function serve() {
  const roots = [['/sandbox/', sandboxDir], ['/', siteDir]];
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://local');
    const [prefix, root] = roots.find(([p]) => url.pathname.startsWith(p));
    let rel = decodeURIComponent(url.pathname.slice(prefix.length));
    if (!rel || rel.endsWith('/')) rel += 'index.html';
    const file = path.resolve(root, rel);
    if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      res.writeHead(404);
      res.end();
      return;
    }
    res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, origin: `http://127.0.0.1:${server.address().port}` })));
}

/** Opens a page with the request / console / error guards: `allowed(url)` marks the requests a page may make. */
async function open(browser, url, { allowed = () => false, viewport = { width: 1280, height: 720 }, init = null } = {}) {
  const page = await browser.newPage({ viewport });
  if (init) await page.addInitScript(init);
  const guard = { external: [], errors: [], warnings: [], own: 0 };
  page.on('request', (r) => {
    const u = r.url();
    if (/^(data|blob):/i.test(u)) return;
    if (allowed(u)) guard.own++;
    else guard.external.push(u);
  });
  page.on('console', (m) => {
    if (m.type() === 'error') guard.errors.push(m.text());
    else if (m.type() === 'warning') guard.warnings.push(m.text());
  });
  page.on('pageerror', (e) => guard.errors.push(`pageerror: ${e.message}`));
  const t0 = Date.now();
  await page.goto(url);
  await page.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null,
    { timeout: 240000 });
  const bootMs = Date.now() - t0;
  const bootError = await page.evaluate(() => window.__rovloc.error);
  return { page, guard, bootMs, bootError };
}

/** Bytes the page fetched (resource timings + the document), split by kind. */
function downloads(page) {
  return page.evaluate(() => {
    const out = { total: 0, world: 0, js: 0, textures: 0, atlases: 0, normals: 0, biggestTexture: 0, list: [] };
    const nav = performance.getEntriesByType('navigation')[0];
    if (nav) out.total += nav.encodedBodySize || 0;
    for (const e of performance.getEntriesByType('resource')) {
      const n = e.encodedBodySize || e.transferSize || 0;
      const name = e.name.split('/').pop();
      out.total += n;
      out.list.push([name, n]);
      if (/^world\./.test(name)) out.world += n;
      else if (/\.js$/.test(name)) out.js += n;
      else if (/^(decals|wear)_/.test(name)) out.atlases += n;
      else if (/\.webp$/.test(name)) {
        out.textures += n;
        const size = Number((/-(\d+)\./.exec(name) || [])[1] || 0);
        out.biggestTexture = Math.max(out.biggestTexture, size);
        if (/_normal-/.test(name)) out.normals++;
      }
    }
    return out;
  });
}

/** Waits until the engine's texture streamer has the set of its tier in use (or `ms` passes). */
async function texturesSettled(page, ms = 180000) {
  // the swaps happen a few a frame: frames are stepped here (without drawing) while the set downloads and decodes
  const until = Date.now() + ms;
  while (Date.now() < until) {
    const done = await page.evaluate(() => {
      const e = window.__rovloc.engine;
      const t = e.textures;
      if (t.pendingSize === null && t.loading.size === 0 && t.current === t.wanted) return true;
      if (!e.loop.running && t.pendingSize !== null) {
        const skip = e.skipRender;
        e.skipRender = true;
        for (let i = 0; i < 6; i++) e.loop.stepManual(1 / 30);
        e.skipRender = skip;
      }
      return false;
    });
    if (done) return true;
    await page.waitForTimeout(200);
  }
  return false;
}

/** Holds the page's own frame loop (headless WebGL draws in software: frames are stepped by the checks). */
const hold = (page) => page.evaluate(() => window.__rovloc.engine && window.__rovloc.engine.loop.stop());

const mb = (n) => (n / 1048576).toFixed(2);

async function main() {
  // the sandbox site for the engine walk and the tier measurements (served next to the website)
  execFileSync(process.execPath, [path.join(here, 'build.mjs'), '--sandbox', '--site', sandboxDir], { stdio: 'inherit' });
  if (!fs.existsSync(path.join(siteDir, 'index.html')) || !fs.existsSync(liteFile)) {
    execFileSync(process.execPath, [path.join(here, 'build.mjs')], { stdio: 'inherit' });
  }
  fs.mkdirSync(shotsDir, { recursive: true });
  const { server, origin } = await serve();
  const own = (u) => u.startsWith(`${origin}/`);
  const browser = await chromium.launch(LAUNCH);

  // ------------------------------------------------------------------ 1. the website
  if (!perfOnly) {
    const { page, guard, bootMs, bootError } = await open(browser, `${origin}/`, { allowed: own, viewport: SMALL });
    report(!bootError, 'website boots (served site/)', bootError ? bootError : `${bootMs} ms`);
    await page.waitForTimeout(1500);
    await hold(page);
    const m = await page.evaluate(() => window.__rovloc.engine && window.__rovloc.engine.measure());
    report(!!m && m.litShare > 0.004 && m.mean > 0.5, 'website renders a non-black image',
      m ? `mean ${m.mean.toFixed(1)}/255, ${(m.litShare * 100).toFixed(1)}% lit` : 'no engine');
    report(guard.external.length === 0, 'website fetches nothing but its own assets', guard.external.slice(0, 5).join(' '));
    report(guard.errors.length === 0, 'website has no console errors', guard.errors.slice(0, 5).join(' | '));
    await page.screenshot({ path: path.join(shotsDir, 'deliverable.png'), timeout: 180000 });
    await texturesSettled(page);
    const max = await downloads(page);
    const tex = await page.evaluate(() => ({ current: window.__rovloc.engine.textures.current, stats: window.__rovloc.engine.textures.stats }));
    report(tex.current === 2048 && max.normals > 0, 'Max streams its 2048 texture set in the background',
      `${mb(max.total)} MB in all (world ${mb(max.world)}, js ${mb(max.js)}, textures ${mb(max.textures)}, atlases ${mb(max.atlases)}); set ${tex.current}`);
    await page.close();
  }
  {
    const init = () => localStorage.setItem('rovloc.save', JSON.stringify({ version: 1, data: { settings: { Graphics: 'Potato' } } }));
    const { page, guard, bootError } = await open(browser, `${origin}/`, { allowed: own, init, viewport: SMALL });
    await page.waitForTimeout(1500);
    await hold(page);
    await texturesSettled(page, 30000);
    const d = await downloads(page);
    const tier = await page.evaluate(() => window.__rovloc.engine.quality.tier);
    report(!bootError && tier === 'Potato' && d.biggestTexture <= 256 && d.normals === 0 && guard.external.length === 0,
      'Potato downloads only light assets (the 256 colour set, no normal maps)',
      `${mb(d.total)} MB: world ${mb(d.world)}, js ${mb(d.js)}, textures ${mb(d.textures)}, atlases ${mb(d.atlases)}; biggest texture ${d.biggestTexture}px`);
    console.log(`INFO  Potato downloads ${mb(d.total)} MB (${d.list.length} files)`);
    await page.close();
  }

  // ------------------------------------------------------------------ 1b. the lite build from file://
  if (!perfOnly) {
    // the page itself loads from file://; nothing else may be requested
    const { page, guard, bootMs, bootError } = await open(browser, `file://${liteFile}`, { viewport: SMALL, allowed: (u) => /^file:/i.test(u) });
    report(!bootError, 'lite build boots from file://', bootError ? bootError : `${bootMs} ms, ${mb(fs.statSync(liteFile).size)} MB`);
    await page.waitForTimeout(1500);
    await hold(page);
    const liteTier = await page.evaluate(() => window.__rovloc.engine.quality.tier);
    report(liteTier === 'Potato', 'the lite build starts on Potato (for school Chromebooks)', liteTier);
    const m = await page.evaluate(() => window.__rovloc.engine && window.__rovloc.engine.measure());
    report(!!m && m.litShare > 0.004, 'lite build renders a non-black image', m ? `mean ${m.mean.toFixed(1)}/255` : 'no engine');
    report(guard.external.length === 0, 'lite build makes no request at all', guard.external.slice(0, 5).join(' '));
    report(guard.errors.length === 0, 'lite build has no console errors', guard.errors.slice(0, 5).join(' | '));
    await page.close();
  }

  // ------------------------------------------------------------------ 1c. co-op's network rule (on the website)
  // Nothing but its own assets until HOST / JOIN; then only the Supabase project's host (this sandbox cannot reach it,
  // as a school filter would not: the friends sheet says multiplayer cannot connect and single-player still works).
  if (!perfOnly) {
    const html = fs.readFileSync(path.join(siteDir, 'index.html'), 'utf8');
    const csp = (/http-equiv="Content-Security-Policy" content="([^"]+)"/.exec(html) || [])[1] || '';
    const connect = (/connect-src ([^;]+)/.exec(csp) || [])[1] || '';
    const hosts = connect.split(/\s+/).filter((s) => /^(wss|https):/.test(s)).map((s) => new URL(s).host);
    report(hosts.length === 2 && new Set(hosts).size === 1 && /\.supabase\.co$/.test(hosts[0]) && /'self'/.test(connect),
      'the page may connect to its own origin and one other host only (the Supabase project), by its CSP', connect);
    // the network rule holds on every tier; Potato keeps the software rasterizer quick
    const init = () => localStorage.setItem('rovloc.save', JSON.stringify({ version: 1, data: { settings: { Graphics: 'Potato' } } }));
    const { page, guard, bootError } = await open(browser, `${origin}/`, { allowed: own, init, viewport: SMALL });
    const sockets = [];
    page.on('websocket', (ws) => sockets.push(ws.url()));
    await page.waitForTimeout(1500);
    report(!bootError && guard.external.length === 0 && sockets.length === 0, 'co-op: nothing but its own assets before HOST',
      [...guard.external, ...sockets].slice(0, 3).join(' '));
    await page.evaluate(() => {
      const g = window.__rovlocGame.game;
      g.onboarding.friendsBtn.click();
      g.coop.ui.hostBtn.click();
    });
    const said = await page.waitForFunction(() => {
      const t = window.__rovlocGame.game.coop.ui.status.textContent;
      return /can't connect/.test(t) ? t : null;
    }, null, { timeout: 60000 }).then((h) => h.jsonValue(), () => null);
    report(!!said, 'co-op without the network: the friends sheet says multiplayer cannot connect here', said || '');
    const others = [...guard.external, ...sockets].filter((u) => !hosts.some((h) => new URL(u).host === h));
    report(others.length === 0 && sockets.length > 0, 'co-op: HOST reaches for the Supabase host and nothing else',
      [...new Set([...guard.external, ...sockets].map((u) => new URL(u).host))].join(' '));
    const solo = await page.evaluate(async () => {
      const g = window.__rovlocGame.game;
      g.coop.ui.backBtn.click();
      g.env.setSetting('TutorialDone', true);
      g.onboarding.playBtn.click();
      await new Promise((r) => setTimeout(r, 300));
      return { active: g.coop.active, title: g.onboarding.mode, phase: g.phase };
    });
    report(!solo.active && solo.title === 'Hidden' && solo.phase === 'Lobby', 'co-op failing leaves single-player playable',
      JSON.stringify(solo));
    await page.close();
  }

  // ------------------------------------------------------------------ 2. the engine walk (sandbox)
  // the walk runs on Low (it only simulates); the tiers are measured below
  const lowFirst = () => localStorage.setItem('rovloc.save', JSON.stringify({ version: 1, data: { settings: { Graphics: 'Low' } } }));
  const { page, guard, bootMs, bootError } = await open(browser, `${origin}/sandbox/?level=Level1_Hallways`, { allowed: own, init: lowFirst });
  report(!bootError, 'sandbox boots', bootError ? bootError : `${bootMs} ms`);
  const step = (frames) => page.evaluate((n) => {
    const e = window.__rovloc.engine;
    for (let i = 0; i < n; i++) e.loop.stepManual(1 / 30);
  }, frames);
  const state = () => page.evaluate(() => {
    const e = window.__rovloc.engine;
    const p = e.player;
    return {
      pos: p.rootPosition().toArray(), grounded: p.body.grounded, moveState: p.moveState, stamina: p.meters.stamina.value,
      torch: p.flashlight.on, level: e.world.levelAt(p.rootPosition()),
    };
  });
  if (perfOnly) {
    await page.evaluate(() => {
      const e = window.__rovloc.engine;
      e.loop.stop();
      e.quality.adapt = false;
    });
  } else {
    // the Level 1 checkerboard hallway (its world rect, from the layout): the walk starts near its east end
    const hall = await page.evaluate(() => {
      const r = window.__rovloc.engine.world.meta.rooms.find((x) => x.id === 'L1_Corridor_East');
      return { x: r.rect.x, z: r.rect.z, w: r.rect.w, d: r.rect.d, floorY: r.floorY, y: r.floorY + 3 };
    });
    const hallStart = { x: hall.x + hall.w - 16, y: hall.y, z: hall.z + hall.d / 2 };
    await page.evaluate((at) => {
      const e = window.__rovloc.engine;
      e.loop.stop(); // the walk steps frames by hand: deterministic 30 fps game time whatever the software GPU does
      e.skipRender = true; // simulation only (measure() still draws)
      e.quality.adapt = false;
      e.quality.setTier('Low');
      window.__noise = [];
      e.noise.on((n) => window.__noise.push(n.kind));
      e.player.teleport({ position: at, yaw: Math.PI / 2 }); // L1 hallway, facing west
    }, hallStart);
    await step(20);
    const s0 = await state();
    report(s0.grounded && Math.abs(s0.pos[1] - hall.y) < 0.6, 'player stands on the corridor floor', `y ${s0.pos[1].toFixed(2)}`);
    await page.keyboard.down('KeyW');
    await step(90);
    const s1 = await state();
    const walked = s0.pos[0] - s1.pos[0];
    report(walked > 20 && walked < 40 && Math.abs(s1.pos[1] - s0.pos[1]) < 0.6,
      'W walks along the corridor (11 studs/s for 3 s)', `moved ${walked.toFixed(1)} studs, y ${s1.pos[1].toFixed(2)}`);
    const noises = await page.evaluate(() => window.__noise.slice());
    report(noises.includes('Walk'), 'walking emits Walk noise pulses', `${noises.length} pulses`);
    await page.keyboard.down('ShiftLeft');
    await step(60);
    const s2 = await state();
    report(s2.moveState === 'Sprinting' && s2.stamina < 100, 'Shift sprints and drains stamina',
      `${s2.moveState}, stamina ${s2.stamina.toFixed(1)}, moved ${(s1.pos[0] - s2.pos[0]).toFixed(1)}`);
    await page.keyboard.up('ShiftLeft');
    await page.keyboard.up('KeyW');
    await page.keyboard.press('KeyC');
    await step(10);
    const s3 = await state();
    report(s3.moveState === 'Crouching', 'C toggles crouch', s3.moveState);
    await page.keyboard.press('KeyC');
    await step(10);
    // wall: face north and push back into the hallway's south (+Z) wall, where rays across the hallway meet bare wall
    // (no doorway, locker bank or prop in front of it), the spot nearest the hallway's middle
    const wall = await page.evaluate((h) => {
      const e = window.__rovloc.engine;
      const T = e.THREE;
      const dir = new T.Vector3(0, 0, 1);
      const mid = h.z + h.d / 2;
      let best = null;
      for (let x = h.x + 8; x <= h.x + h.w - 8; x += 1) {
        let face = Infinity;
        for (const dx of [-1.5, 0, 1.5]) for (const dy of [0.6, 2.5, 4.5]) {
          const hit = e.world.raycast(new T.Vector3(x + dx, h.floorY + dy, mid), dir, h.d / 2 + 1);
          face = hit && hit.distance > h.d / 2 - 1.2 ? Math.min(face, hit.point.z) : -Infinity;
          if (face === -Infinity) break;
        }
        const centre = h.x + h.w / 2;
        if (face > -Infinity && (!best || Math.abs(x - centre) < Math.abs(best.x - centre))) best = { x, face };
      }
      return best;
    }, hall);
    report(!!wall, 'the hallway has bare wall to push into', wall ? `x ${wall.x}, face at z ${wall.face.toFixed(2)}` : 'none');
    const wallZ = wall ? wall.face : hall.z + hall.d;
    await page.evaluate(([at, x]) => {
      const p = window.__rovloc.engine.player;
      p.teleport({ position: { x, y: at.y, z: at.z }, yaw: 0 });
      p.setLook(0, 0);
    }, [hallStart, wall ? wall.x : hallStart.x]);
    await step(5);
    await page.keyboard.down('KeyS'); // backwards = +Z
    await step(90);
    await page.keyboard.up('KeyS');
    const s4 = await state();
    report(s4.pos[2] < wallZ && s4.pos[2] > wallZ - 3, 'a wall stops the body',
      `z ${s4.pos[2].toFixed(2)} (wall face at ${wallZ.toFixed(2)})`);
    // a crawlway (Level 0): standing, the body does not fit its mouth; crouched, it crawls through to the far side
    const crawl = await page.evaluate(() => {
      const m = window.__rovloc.engine.world.meta;
      const r = m.rooms.find((x) => x.kind === 'Crawlway' && x.level === 'Level0_Basement');
      return r ? { id: r.id, rect: r.rect, floorY: r.floorY } : null;
    });
    report(!!crawl, 'Level 0 has a crawlway', crawl ? crawl.id : 'none');
    if (crawl) {
      const r = crawl.rect;
      const alongX = r.w > r.d;
      const from = alongX ? r.x : r.z;
      const to = alongX ? r.x + r.w : r.z + r.d;
      const along = (s) => (alongX ? s.pos[0] : s.pos[2]);
      await page.evaluate(([rr, ax, fy]) => {
        const e = window.__rovloc.engine;
        const at = ax ? { x: rr.x - 3, y: fy + 3, z: rr.z + rr.d / 2 } : { x: rr.x + rr.w / 2, y: fy + 3, z: rr.z - 3 };
        const yaw = ax ? -Math.PI / 2 : Math.PI; // facing +X / +Z
        e.player.teleport({ position: at, yaw });
        e.player.setLook(yaw, 0);
      }, [r, alongX, crawl.floorY]);
      await step(10);
      await page.keyboard.down('KeyW');
      await step(60);
      await page.keyboard.up('KeyW');
      const c1 = await state();
      report(along(c1) < from + 0.5, 'standing, the body does not fit a crawlway\'s mouth', `${along(c1).toFixed(2)} (mouth at ${from.toFixed(1)})`);
      await page.keyboard.press('KeyC');
      await step(10);
      await page.keyboard.down('KeyW');
      await step(Math.ceil(((to - from + 8) / 5) * 30));
      await page.keyboard.up('KeyW');
      const c2 = await state();
      report(along(c2) > to + 0.5 && c2.grounded, 'crouched, the body crawls through a crawlway', `${along(c2).toFixed(2)} (far mouth at ${to.toFixed(1)}), ${c2.moveState}`);
      await page.keyboard.press('KeyC');
      await step(10);
      await page.evaluate((at) => {
        const e = window.__rovloc.engine;
        e.player.teleport({ position: at, yaw: 0 });
        e.player.setLook(0, 0);
      }, hallStart);
      await step(10);
    }
    const torch0 = s4.torch;
    await page.keyboard.press('KeyF');
    await step(5);
    const s5 = await state();
    report(s5.torch !== torch0, 'F toggles the torch', `${torch0} -> ${s5.torch}`);
    // prompt: hold E for 1 s
    const triggered = await page.evaluate(async () => {
      const e = window.__rovloc.engine;
      const eye = e.player.eye();
      const look = e.player.look().direction;
      window.__prompt = 0;
      e.prompts.add({ position: eye.clone().addScaledVector(look, 3), text: 'Test', objectText: 'Check', holdSeconds: 1,
        distance: 10, requiresLineOfSight: false, onTriggered: () => window.__prompt++ });
      for (let i = 0; i < 3; i++) e.loop.stepManual(1 / 30);
      return true;
    });
    await page.keyboard.down('KeyE');
    await step(40);
    await page.keyboard.up('KeyE');
    const prompted = await page.evaluate(() => window.__prompt);
    report(triggered && prompted === 1, 'holding E fills a prompt ring and triggers it once', `${prompted} trigger(s)`);
    // entities: an airlock door's leaves swung shut through the node table block rays, swung open they do not
    const door = await page.evaluate(() => {
      const e = window.__rovloc.engine;
      const T = e.THREE;
      const d = e.entities.list('AirlockDoor').find((x) => x.level === 'Level1_Hallways');
      const p = new T.Vector3().setFromMatrixPosition(d.pivot);
      const a = new T.Vector3(p.x - 3, p.y + 5, p.z - 2);
      const b = new T.Vector3(p.x + 3, p.y + 5, p.z - 2);
      const pose = (suffix) => {
        for (const leaf of ['LeftLeaf', 'RightLeaf']) e.entities.setNodePivot(d.id, leaf, e.entities.attachmentWorld(d.id, leaf + suffix));
      };
      pose('Rest');
      const shut = !e.world.lineClear(a, b);
      pose('Open');
      const open = e.world.lineClear(a, b);
      const decals = [];
      e.world.scene.traverse((o) => {
        if (o.isMesh && o.material.defines && 'DECAL' in o.material.defines) decals.push(o);
      });
      const creature = e.world.createCreatureModel();
      creature.dispose();
      return { id: d.id, shut, open, decals: decals.length, creatureMeshes: creature.object.children.length, bones: creature.bones.length };
    });
    report(door.shut && door.open, 'entity nodes move: a shut airlock door blocks rays, an open one does not', JSON.stringify(door));
    report(door.decals > 0 && door.creatureMeshes > 0 && door.bones > 0, 'decals and the creature rig build',
      `${door.decals} decal meshes, creature ${door.creatureMeshes} meshes / ${door.bones} bones`);
    const audio = await page.evaluate(() => {
      const a = window.__rovloc.engine.audio;
      return { ready: a.ready, state: a.ctx && a.ctx.state, voices: a.voices.length };
    });
    report(audio.ready, 'audio engine up (WebAudio context, 11 synthesized sources)', JSON.stringify(audio));
    // every SynthPresets recipe rendered offline: sound comes out, nothing is NaN
    const synth = await page.evaluate(async () => {
      const e = window.__rovloc.engine;
      const names = e.audio.presetNames;
      const silent = [];
      const broken = [];
      let loudest = 0;
      for (const name of names) {
        const ctx = new OfflineAudioContext(2, 22050 * 2.5, 22050);
        const a = new e.audio.constructor({ settings: e.settings, context: ctx });
        a.listener = { x: 0, y: 0, z: 0 };
        a.play(name, { volume: 1 });
        const buf = await ctx.startRendering();
        let sum = 0;
        let nan = false;
        for (let c = 0; c < buf.numberOfChannels; c++) {
          const d = buf.getChannelData(c);
          for (let i = 0; i < d.length; i++) {
            if (!Number.isFinite(d[i])) nan = true;
            sum += d[i] * d[i];
          }
        }
        const rms = Math.sqrt(sum / (buf.length * buf.numberOfChannels));
        loudest = Math.max(loudest, rms);
        if (nan) broken.push(name);
        else if (rms < 1e-4) silent.push(name);
      }
      return { count: names.length, silent, broken, loudest };
    });
    report(synth.broken.length === 0 && synth.silent.length === 0,
      `every SynthPresets recipe synthesizes sound (${synth.count} presets, offline render)`,
      `silent: ${synth.silent.join(',') || 'none'}; NaN: ${synth.broken.join(',') || 'none'}`);
    const m1 = await page.evaluate(() => window.__rovloc.engine.measure());
    report(m1.litShare > 0.004, 'the walk view renders', `mean ${m1.mean.toFixed(1)}, ${(m1.litShare * 100).toFixed(1)}% lit`);
  }

  // ------------------------------------------------------------------ 3. performance per tier at 4x CPU throttle
  await page.evaluate(() => {
    window.__rovloc.engine.skipRender = false;
  });
  const cdp = await page.context().newCDPSession(page);
  const perf = {};
  const setView = async (w, h) => {
    await page.setViewportSize({ width: w, height: h });
    // the window resize (which resizes and clears the canvas) can land late behind a backlogged software GPU: wait
    // until the renderer has taken the new size, so no frame drawn below is wiped by it
    await page.waitForFunction(([ww, hh]) => {
      const r = window.__rovloc.engine.renderer;
      return window.innerWidth === ww && window.innerHeight === hh && r.width === ww && r.height === hh;
    }, [w, h], { timeout: 120000 });
    await page.waitForTimeout(300);
  };
  const setTier = async (tier) => {
    await page.evaluate((t) => {
      const e = window.__rovloc.engine;
      e.quality.setTier(t);
      e.quality.scale = e.quality.budget.maxScale;
      e.quality.scaleChanged.fire(e.quality.scale);
    }, tier);
    await texturesSettled(page);
  };
  // the Level 1 checkerboard hallway (west, toward the gate), the Level 0 tunnels (down a lit pipe gallery, the power
  // on), Level 2's west gallery (north along its 240 studs) and the lobby
  const places = {
    L1: { p: [380, 21, 144], yaw: Math.PI / 2 },
    L0: { p: [168, 3.5, 40], yaw: Math.PI },
    L2: { p: [30, 37, 250], yaw: 0 },
    Lobby: { p: [-776, 3.5, 38], yaw: -Math.PI / 2 },
  };
  const prep = ([a, frames = 10]) => {
    const e = window.__rovloc.engine;
    e.player.teleport({ position: { x: a.p[0], y: a.p[1], z: a.p[2] }, yaw: a.yaw });
    e.player.flashlight.setOn(true);
    for (let i = 0; i < frames; i++) e.loop.stepManual(1 / 30);
  };
  // a frame's work in the software GPU outlives the frame: drain it, so no measurement pays for the one before
  const drain = () => page.evaluate(() => window.__rovloc.engine.renderer.gl.getContext().finish());
  if (!noPerf) {
    // main-thread cost of a whole frame (simulation + draw submission) at a tiny canvas, so the software rasterizer's
    // backlog cannot stall it: this is the CPU figure that carries over to a Chromebook
    await setView(320, 180);
    for (const tier of TIERS) {
      await setTier(tier);
      for (const [place, at] of Object.entries(places)) {
        await page.evaluate(prep, [at]);
        await drain();
        await cdp.send('Emulation.setCPUThrottlingRate', { rate: 4 });
        const cpu = await page.evaluate(() => {
          const e = window.__rovloc.engine;
          const ms = [];
          for (let i = 0; i < 60; i++) {
            const t = performance.now();
            e.loop.stepManual(1 / 30);
            ms.push(performance.now() - t);
          }
          ms.sort((a, b) => a - b);
          const s = e.renderer.stats;
          const c = e.world.culling ? e.world.culling.stats : {};
          return { median: (ms[29] + ms[30]) / 2, p95: ms[56], calls: s.calls, triangles: s.triangles, passes: s.passes, pvs: c.visibleZones || 0 };
        });
        await cdp.send('Emulation.setCPUThrottlingRate', { rate: 1 });
        await drain();
        perf[`${place} ${tier}`] = cpu;
      }
    }
    // the frame rate headless Chromium reaches at 1280x720 with the loop running (the software rasterizer included)
    await setView(1280, 720);
    for (const tier of TIERS) {
      await setTier(tier);
      for (const [place, at] of Object.entries(places)) {
        await page.evaluate(prep, [at, 2]);
        await drain();
        await cdp.send('Emulation.setCPUThrottlingRate', { rate: 4 });
        const fps = await page.evaluate(async (seconds) => {
          const e = window.__rovloc.engine;
          e.loop.start();
          const f0 = e.loop.frameCount;
          const t0 = performance.now();
          await new Promise((res) => setTimeout(res, seconds * 1000));
          const n = e.loop.frameCount - f0;
          const fpsValue = (n * 1000) / (performance.now() - t0);
          e.loop.stop();
          return { fps: fpsValue, internal: e.renderer.stats.internal };
        }, quick ? 3 : 6);
        await cdp.send('Emulation.setCPUThrottlingRate', { rate: 1 });
        await drain();
        const r = Object.assign(perf[`${place} ${tier}`], fps);
        console.log(`INFO  4x CPU throttle, ${place.padEnd(5)} ${tier.padEnd(6)}: whole frame ${r.median.toFixed(1)} ms median / ` +
          `${r.p95.toFixed(1)} ms p95 main thread (${r.calls} draw calls, ${(r.triangles / 1000).toFixed(0)}k triangles, ` +
          `${r.pvs ? `${r.pvs} zones seen` : 'no zone culling'}, passes: ${r.passes || 'world'}); ` +
          `${r.fps.toFixed(1)} fps headless at ${r.internal.join('x')} internal (software GPU)`);
      }
    }
    for (const place of Object.keys(places)) {
      const p = perf[`${place} Potato`];
      report(p.median <= 16.7, `Potato fits 60 fps at 4x throttle (${place}: whole frame median <= 16.7 ms)`,
        `${p.median.toFixed(1)} ms median, ${p.p95.toFixed(1)} ms p95`);
    }
    fs.writeFileSync(path.join(shotsDir, 'perf.json'), JSON.stringify(perf, null, 1));
  }

  // ------------------------------------------------------------------ 4. screenshots
  const views = {
    'l1-corridor': { p: [380, 21, 144], yaw: 90, pitch: -3 },
    'l1-lockers': { p: [370, 21, 245], yaw: 0, pitch: -2 },
    'l2-lab': { p: [128, 37, 247], yaw: -45, pitch: -8 },
    'l2-prep': { p: [251, 37, 219], yaw: 0, pitch: -4 },
    'l0-gallery': { p: [168, 3.5, 40], yaw: 180, pitch: 0 },
    'l0-boiler': { p: [207, 3.5, 238], yaw: -90, pitch: -4 },
    'l0-drains': { p: [370, 3.5, 230], yaw: 0, pitch: 0 },
    'l3-gym': { p: [148, 53, 40], yaw: -90, pitch: 5 },
    'l3-lockers': { p: [286, 53, 124], yaw: -90, pitch: -4 },
    'l3-tunnels': { p: [105, 53.5, 192], yaw: 0, pitch: 0 },
    'l4-pool': { p: [320, 85, 283], yaw: 57, pitch: -10 },
    'l4-pumps': { p: [194, 85, 140], yaw: -90, pitch: -6 },
    'l5-roof': { p: [380, 115.5, 144], yaw: 90, pitch: 0 },
    'l5-plant': { p: [300, 115.5, 110], yaw: 180, pitch: 0 },
    lobby: { p: [-776, 3.5, 38], yaw: -90, pitch: 0 },
  };
  const shoot = async (name, v) => {
    const lum = await page.evaluate((view) => {
      const e = window.__rovloc.engine;
      e.player.teleport({ position: { x: view.p[0], y: view.p[1], z: view.p[2] }, yaw: (view.yaw * Math.PI) / 180 });
      e.player.setLook((view.yaw * Math.PI) / 180, (view.pitch * Math.PI) / 180);
      e.player.flashlight.setOn(true);
      e.ui.toastsEl.textContent = '';
      e.ui.lockEl.classList.remove('on');
      e.ui.lockWait = -1e9;
      for (let i = 0; i < 5; i++) e.loop.stepManual(1 / 30);
      return e.measure();
    }, v);
    report(lum.litShare > 0.004, `view ${name} renders`, `mean ${lum.mean.toFixed(1)}, ${(lum.litShare * 100).toFixed(1)}% lit`);
    await page.screenshot({ path: path.join(shotsDir, `${name}.png`), timeout: 240000 });
    return lum;
  };
  await setView(960, 540); // the canvas resize (it clears the drawing buffer) lands before the frames below
  await setTier('High');
  for (const name of quick ? ['l1-corridor'] : Object.keys(views)) await shoot(name, views[name]);
  // the same Level 0 tunnel and the lobby at every tier
  const tierViews = { l0: { p: [168, 3.5, 40], yaw: 180, pitch: -2 }, lobby: views.lobby };
  const brightness = {};
  for (const tier of TIERS) {
    await setTier(tier);
    for (const [name, v] of Object.entries(tierViews)) {
      const lum = await shoot(`tier-${tier}-${name}`, v);
      brightness[`${tier} ${name}`] = lum.mean;
    }
  }
  console.log(`INFO  mean luminance per tier: ${Object.entries(brightness).map(([k, v]) => `${k} ${v.toFixed(1)}`).join(', ')}`);
  // the Graphics menu (at Max, Max+ shown)
  await setTier('Max');
  await page.evaluate(() => {
    const e = window.__rovloc.engine;
    e.settings.set('Graphics', 'Max');
    e.ui.openMenu('PAUSED');
    e.loop.stepManual(1 / 30);
    const block = document.querySelector('.rv-graphics');
    if (block) block.scrollIntoView({ block: 'center' });
  });
  await page.waitForTimeout(400);
  const menu = await page.evaluate(() => {
    const segs = [...document.querySelectorAll('.rv-seg')].map((s) => `${s.textContent}${s.classList.contains('on') ? '*' : ''}`);
    const info = document.querySelector('.rv-graphics-info');
    return { segs, info: info ? info.textContent : '' };
  });
  await page.screenshot({ path: path.join(shotsDir, 'graphics-menu.png'), timeout: 240000 });
  // picking Potato from the menu applies at once and says what it is for
  const picked = await page.evaluate(() => {
    const seg = [...document.querySelectorAll('.rv-seg')].find((s) => s.dataset.tier === 'Potato');
    seg.click();
    const e = window.__rovloc.engine;
    return { tier: e.quality.tier, saved: e.settings.get('Graphics'), info: document.querySelector('.rv-graphics-info').textContent };
  });
  await page.screenshot({ path: path.join(shotsDir, 'graphics-menu-potato.png'), timeout: 240000 });
  report(menu.segs.join(' ') === 'Max* High Medium Low Potato' && picked.tier === 'Potato' && picked.saved === 'Potato' &&
    /^For school Chromebooks/.test(picked.info), 'the Graphics menu: Max .. Potato, a pick applies live and is saved',
  `${menu.segs.join(' ')} | "${menu.info}" -> ${picked.tier}: "${picked.info}"`);
  await page.evaluate(() => window.__rovloc.engine.ui.closeMenu());
  console.log(`INFO  screenshots in ${shotsDir}`);

  report(guard.external.length === 0, 'sandbox fetches nothing but its own assets', guard.external.slice(0, 5).join(' '));
  report(guard.errors.length === 0, 'sandbox has no console errors', guard.errors.slice(0, 5).join(' | '));
  await browser.close();
  server.close();
  console.log(failed ? 'CHECK FAILED' : 'CHECK PASSED');
  process.exit(failed ? 1 : 0);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
