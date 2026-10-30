// Headless verification with the pre-installed Playwright Chromium (`npm run check` builds first).
//
//   node tools/check.mjs [--shots <dir>] [--quick]
//
// 1. The deliverable (dist/Rovloc.html): loads from file:// with no request leaving the page (anything but file:,
//    data:, blob: fails), no console error or page error, boots within the time limit, and renders a non-black
//    image (pixels read back from the canvas). Co-op's rule: no request at all until the player presses HOST or
//    JOIN, then only the Supabase project's host (the page's CSP allows no other) and the STUN servers (WebRTC, outside
//    CSP and request events); pressing HOST without that network shows "Multiplayer can't connect on this network"
//    and single-player still plays.
// 2. The engine walk (a sandbox build of the same engine, build/cache/check-sandbox.html, so the game's own flow
//    cannot hold the player): spawn in the Level 1 corridor; walking W moves the body along the floor (it neither
//    falls through nor floats), a wall stops it, Shift sprints and drains stamina, C crouches, F toggles the torch,
//    a held E fills a prompt and triggers it once, walking emits locomotion noise, an airlock door's leaves swung
//    shut through the entity API block rays (and open do not), decals and the creature rig build, the audio engine
//    runs and every one of the 101 SynthPresets recipes renders non-silent, finite audio offline.
// 3. Performance with the CPU throttled 4x (Emulation.setCPUThrottlingRate) per quality tier: main-thread ms per frame
//    (measured on a tiny canvas so the software rasterizer's backlog cannot stall it: the figure that carries over to
//    a Chromebook CPU) and the fps headless Chromium reaches at 1280x720. Headless WebGL is SwiftShader (CPU
//    rasterization), so that fps is a floor far below any real GPU.
// 4. Screenshots of the main views (--shots <dir>, default build/cache/shots), each asserted non-black.
//
// The deliverable runs W4's game when src/game/index.js exists: its start(engine) must resolve once its first screen
// is up (main.js sets window.__rovloc.ready then), and the world must be drawn behind it for the non-black test.
// Exit code 1 on any failure.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
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
const shotsDir = path.resolve(opt('--shots', path.join(web, 'build/cache/shots')));
const deliverable = path.join(web, 'dist/Rovloc.html');
const sandboxPage = path.join(web, 'build/cache/check-sandbox.html');

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

/** Opens a page with the request / console / error guards. */
async function open(browser, file, query = '', viewport = { width: 1280, height: 720 }) {
  const page = await browser.newPage({ viewport });
  const guard = { external: [], errors: [], warnings: [] };
  page.on('request', (r) => {
    const u = r.url();
    if (!/^(file|data|blob):/i.test(u)) guard.external.push(u);
  });
  page.on('console', (m) => {
    if (m.type() === 'error') guard.errors.push(m.text());
    else if (m.type() === 'warning') guard.warnings.push(m.text());
  });
  page.on('pageerror', (e) => guard.errors.push(`pageerror: ${e.message}`));
  const t0 = Date.now();
  await page.goto(`file://${file}${query}`);
  await page.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null,
    { timeout: 180000 });
  const bootMs = Date.now() - t0;
  const bootError = await page.evaluate(() => window.__rovloc.error);
  return { page, guard, bootMs, bootError };
}

async function main() {
  // the sandbox build for the engine walk
  execFileSync(process.execPath, [path.join(here, 'build.mjs'), '--sandbox', '--out', sandboxPage],
    { stdio: 'inherit' });
  if (!fs.existsSync(deliverable)) {
    execFileSync(process.execPath, [path.join(here, 'build.mjs')], { stdio: 'inherit' });
  }
  fs.mkdirSync(shotsDir, { recursive: true });
  const browser = await chromium.launch(LAUNCH);

  // ------------------------------------------------------------------ 1. the deliverable
  {
    const { page, guard, bootMs, bootError } = await open(browser, deliverable);
    report(!bootError, 'deliverable boots', bootError ? bootError : `${bootMs} ms`);
    await page.waitForTimeout(4000);
    const m = await page.evaluate(() => window.__rovloc.engine && window.__rovloc.engine.measure());
    report(!!m && m.litShare > 0.004 && m.mean > 0.5, 'deliverable renders a non-black image',
      m ? `mean ${m.mean.toFixed(1)}/255, ${(m.litShare * 100).toFixed(1)}% lit` : 'no engine');
    report(guard.external.length === 0, 'deliverable makes no external request', guard.external.slice(0, 5).join(' '));
    report(guard.errors.length === 0, 'deliverable has no console errors', guard.errors.slice(0, 5).join(' | '));
    await page.screenshot({ path: path.join(shotsDir, 'deliverable.png'), timeout: 180000 });
    await page.close();
  }

  // ------------------------------------------------------------------ 1b. co-op's network rule
  // No request at all until HOST / JOIN; then only the Supabase project's host (this sandbox cannot reach it, as a
  // school filter would not: the friends sheet says multiplayer cannot connect and single-player still works).
  {
    const html = fs.readFileSync(deliverable, 'utf8');
    const csp = (/http-equiv="Content-Security-Policy" content="([^"]+)"/.exec(html) || [])[1] || '';
    const connect = (/connect-src ([^;]+)/.exec(csp) || [])[1] || '';
    const hosts = connect.split(/\s+/).filter((s) => /^(wss|https):/.test(s)).map((s) => new URL(s).host);
    report(hosts.length === 2 && new Set(hosts).size === 1 && /\.supabase\.co$/.test(hosts[0]),
      'the page may connect to one host only (the Supabase project), by its CSP', connect);
    const { page, guard, bootError } = await open(browser, deliverable);
    const sockets = [];
    page.on('websocket', (ws) => sockets.push(ws.url()));
    await page.waitForTimeout(1500);
    report(!bootError && guard.external.length === 0 && sockets.length === 0, 'co-op: nothing is requested before HOST',
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
  const { page, guard, bootMs, bootError } = await open(browser, sandboxPage, '?level=Level1_Hallways');
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
  await page.evaluate(() => {
    const e = window.__rovloc.engine;
    e.loop.stop(); // the walk steps frames by hand: deterministic 30 fps game time whatever the software GPU does
    e.skipRender = true; // simulation only (measure() still draws)
    e.quality.adapt = false;
    e.quality.probing = null;
    e.quality.setTier('Low');
    window.__noise = [];
    e.noise.on((n) => window.__noise.push(n.kind));
    e.player.teleport({ position: { x: 222, y: 21, z: 80 }, yaw: Math.PI / 2 }); // L1 east corridor, facing west
  });
  await step(20);
  const s0 = await state();
  report(s0.grounded && Math.abs(s0.pos[1] - 21) < 0.6, 'player stands on the corridor floor', `y ${s0.pos[1].toFixed(2)}`);
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
  // wall: face north (+Z wall of the corridor is at z = 87) and push
  await page.evaluate(() => window.__rovloc.engine.player.setLook(0, 0));
  await page.keyboard.down('KeyS'); // backwards = +Z
  await step(90);
  await page.keyboard.up('KeyS');
  const s4 = await state();
  report(s4.pos[2] < 87 && s4.pos[2] > 84, 'a wall stops the body', `z ${s4.pos[2].toFixed(2)} (wall at 87)`);
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

  // ------------------------------------------------------------------ 3. performance at 4x CPU throttle
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
  for (const tier of ['Low', 'Medium', 'High']) {
    const prep = (t) => {
      const e = window.__rovloc.engine;
      e.quality.setTier(t);
      e.quality.scale = e.quality.budget.maxScale;
      e.quality.scaleChanged.fire(e.quality.scale);
      e.player.teleport({ position: { x: 222, y: 21, z: 80 }, yaw: Math.PI / 2 });
      e.player.flashlight.setOn(true);
      for (let i = 0; i < 10; i++) e.loop.stepManual(1 / 30);
    };
    // main-thread cost of a frame (simulation + draw submission) at a tiny canvas, so the software rasterizer's
    // backlog never stalls the measurement: this is the CPU figure that carries over to a Chromebook
    await setView(320, 180);
    await page.evaluate(prep, tier);
    await cdp.send('Emulation.setCPUThrottlingRate', { rate: 4 });
    const cpu = await page.evaluate(() => {
      const e = window.__rovloc.engine;
      const ms = [];
      for (let i = 0; i < 40; i++) {
        const t = performance.now();
        e.loop.stepManual(1 / 30);
        ms.push(performance.now() - t);
      }
      ms.sort((a, b) => a - b);
      const s = e.renderer.stats;
      return { median: ms[20], p90: ms[36], calls: s.calls, triangles: s.triangles };
    });
    // real frame rate at 1280x720 with the loop running (software rasterizer included)
    await cdp.send('Emulation.setCPUThrottlingRate', { rate: 1 });
    await setView(1280, 720);
    await page.evaluate(prep, tier);
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
    const r = { cpuMedian: cpu.median, cpuP90: cpu.p90, calls: cpu.calls, triangles: cpu.triangles, ...fps };
    perf[tier] = r;
    console.log(`INFO  4x CPU throttle, ${tier}: main thread ${r.cpuMedian.toFixed(1)} ms median / ` +
      `${r.cpuP90.toFixed(1)} ms p90 per frame (${r.calls} draw calls, ${(r.triangles / 1000).toFixed(0)}k triangles); ` +
      `${r.fps.toFixed(1)} fps headless at ${r.internal.join('x')} internal (software GPU)`);
  }
  report(perf.Low.cpuMedian < 33, 'main-thread frame cost fits 30 fps at 4x throttle (Low)',
    `${perf.Low.cpuMedian.toFixed(1)} ms`);

  // ------------------------------------------------------------------ 4. screenshots
  const views = {
    'l1-corridor': { p: [222, 21, 80], yaw: 90, pitch: -3 },
    'l2-lab': { p: [40, 37, 70], yaw: 38, pitch: -8 },
    'l0-boilerhall': { p: [140, 3, 120], yaw: 0, pitch: 0 },
    'l3-gym': { p: [115, 53, 80], yaw: 90, pitch: 5 },
    'l4-pool': { p: [220, 85, 125], yaw: 57, pitch: -10 },
    'l5-roof': { p: [236, 115.5, 90], yaw: 90, pitch: 0 },
    lobby: { p: [-776, 3.5, 38], yaw: -90, pitch: 0 },
  };
  const list = quick ? ['l1-corridor'] : Object.keys(views);
  await setView(960, 540); // the canvas resize (it clears the drawing buffer) lands before the frames below
  for (const name of list) {
    const v = views[name];
    const lum = await page.evaluate((view) => {
      const e = window.__rovloc.engine;
      e.quality.setTier('High');
      e.player.teleport({ position: { x: view.p[0], y: view.p[1], z: view.p[2] }, yaw: (view.yaw * Math.PI) / 180 });
      e.player.setLook((view.yaw * Math.PI) / 180, (view.pitch * Math.PI) / 180);
      e.player.flashlight.setOn(true);
      e.ui.toastsEl.textContent = '';
      for (let i = 0; i < 5; i++) e.loop.stepManual(1 / 30);
      return e.measure();
    }, v);
    report(lum.litShare > 0.004, `view ${name} renders`, `mean ${lum.mean.toFixed(1)}, ${(lum.litShare * 100).toFixed(1)}% lit`);
    await page.screenshot({ path: path.join(shotsDir, `${name}.png`), timeout: 180000 });
  }
  console.log(`INFO  screenshots in ${shotsDir}`);

  report(guard.external.length === 0, 'sandbox makes no external request', guard.external.slice(0, 5).join(' '));
  report(guard.errors.length === 0, 'sandbox has no console errors', guard.errors.slice(0, 5).join(' | '));
  await browser.close();
  console.log(failed ? 'CHECK FAILED' : 'CHECK PASSED');
  process.exit(failed ? 1 : 0);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
