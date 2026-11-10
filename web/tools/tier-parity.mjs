// tier-parity.mjs: the graphics tiers are visual only. The same scripted run is played at Max and at Potato (the same
// seed, the same inputs on the same ticks, the same Creature encounter), each with its own render loop of 20 and of
// 144 frames a second, and the gameplay state is compared tick for tick: the player's position, velocity, MoveState,
// life, health and meters; the Creature's state, decision, position, pose, target, action and catches; every noise
// pulse; the floor's objective progress and what is carried. Every frame is rendered at its tier (the tiny canvas keeps
// SwiftShader quick), so everything a tier changes runs: the post chain, the shadows, zone culling, particles, the
// Creature's look, texture streaming.
//
//   node tools/tier-parity.mjs [--html <page>] [--no-build] [--seconds 40] [--fps 20,144] [--tiers Max,Potato]
//
// Every frame runs the whole frame (the camera, the lights, zone culling, particles, volumetrics, the Creature's view,
// the texture streamer...); the GPU work is drawn every frame of the 20 fps loop and every 6th frame of the 144 fps
// one (a software rasterizer cannot draw 144 a second, and nothing gameplay reads comes back from the GPU).
//
// The page is the game test page (tools/game-build.mjs, unminified). The engine's requestAnimationFrame loop is held from
// the first frame (an init script), so every frame of the run, the title and the deploy included, is stepped here with
// a fixed frame time: two runs of one tier are identical by construction, and any difference between tiers is a leak
// of a visual setting into gameplay. Exit code 1 on any difference (or a scenario that did not happen).

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
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const seconds = Number(opt('--seconds', '40'));
const DRAW_EVERY = { 20: 1, 144: 6 };
const rates = opt('--fps', '20,144').split(',').map(Number);
const tiers = opt('--tiers', 'Max,Potato').split(',');
const seed = 1029;
let page = opt('--html', null);
if (!page) {
  page = path.join(web, 'build/cache/tier-parity.html');
  if (!argv.includes('--no-build') || !fs.existsSync(page)) {
    execFileSync(process.execPath, [path.join(here, 'game-build.mjs'), '--out', page, '--no-minify'], { stdio: 'inherit' });
  }
}

function loadPlaywright() {
  const require = createRequire(import.meta.url);
  const roots = [web, process.cwd(), '/opt/node-tools/node_modules'];
  try {
    roots.push(execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim());
  } catch { /* npm missing */ }
  roots.push('/usr/local/lib/node_modules_global', '/usr/local/lib/node_modules', '/usr/lib/node_modules', '/opt/node22/lib/node_modules');
  for (const r of roots) {
    try {
      return require(require.resolve('playwright', { paths: [r] }));
    } catch { /* next */ }
  }
  throw new Error('playwright not found (it is expected pre-installed globally)');
}

const { chromium } = loadPlaywright();
let failed = false;
function check(name, ok, detail) {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail !== undefined ? ` ${typeof detail === 'string' ? detail : JSON.stringify(detail)}` : ''}`);
  if (!ok) failed = true;
}

/**
 * The scripted run, in game seconds after the run starts on Level 0: [time, action, ...args]. Keys go through the
 * page's own keyboard listeners (synthetic events on the tick they are due), the Creature encounter through its dev
 * commands: brought near (out of sight), then hunting the player, who runs.
 */
const SCRIPT = [
  [0.5, 'key', 'KeyF', true], [0.6, 'key', 'KeyF', false], // torch
  [1.0, 'key', 'KeyW', true],
  [4.0, 'key', 'ShiftLeft', true],
  [6.5, 'key', 'ShiftLeft', false],
  [7.0, 'look', 1.2, 0],
  [9.0, 'key', 'KeyC', true], [9.1, 'key', 'KeyC', false], // crouch
  [11.5, 'key', 'KeyC', true], [11.6, 'key', 'KeyC', false],
  [12.0, 'key', 'KeyW', false],
  // the encounter, once the floor's grace is over: brought near (out of sight), then hunting; the player runs
  [21.5, 'creature', 'ai tp'],
  [22.0, 'creature', 'hunt'],
  [23.0, 'creature', 'hunt'],
  [23.2, 'look', -1.6, 0],
  [23.5, 'key', 'KeyW', true], [23.5, 'key', 'ShiftLeft', true],
  [27.0, 'look', -0.4, 0],
  [30.0, 'key', 'ShiftLeft', false],
  [31.0, 'look', 2.4, 0],
  [34.0, 'key', 'KeyW', false],
  [35.0, 'key', 'KeyD', true], [37.0, 'key', 'KeyD', false],
];

/** One run at `tier` with a `fps` render loop: the per-tick gameplay log. */
async function play(browser, tier, fps) {
  const context = await browser.newContext({ viewport: { width: 320, height: 180 } });
  const tab = await context.newPage();
  const errors = [];
  tab.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
  tab.on('console', (m) => {
    if (m.type() === 'error' && !/useProgram|Shader Error|WebGL|GPU stall|AudioContext/i.test(m.text())) errors.push(m.text());
  });
  await tab.addInitScript((t) => {
    // the engine's own frame loop never runs (its bound _step is never scheduled): every frame is stepped by the test;
    // the boot screen's and the HUD's animation frames run as usual
    const raf = window.requestAnimationFrame.bind(window);
    window.requestAnimationFrame = (cb) => (cb && cb.name === 'bound _step' ? 0 : raf(cb));
    Element.prototype.requestPointerLock = function requestPointerLock() {
      return Promise.resolve();
    };
    localStorage.setItem('rovloc.save', JSON.stringify({ version: 1, data: { settings: { Graphics: t, TutorialDone: true } } }));
  }, tier);
  await tab.goto(`file://${page}?dev&seed=${seed}`);
  await tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 240000 });
  const bootError = await tab.evaluate(() => window.__rovloc.error);
  if (bootError) throw new Error(`boot: ${bootError}`);
  const log = await tab.evaluate(async ([script, dt, total, drawEvery]) => {
    const e = window.__rovloc.engine;
    const { game: g, dev } = window.__rovlocGame;
    const loop = e.loop;
    loop.stop();
    e.quality.adapt = false;
    const step = async (n) => {
      for (let i = 0; i < n; i++) {
        loop._run(dt, dt);
        await null;
      }
    };
    const frames = (s) => Math.max(1, Math.round(s / dt));
    await step(frames(1));
    dev.skipTitle();
    await step(frames(0.5));
    dev.deploy();
    let guard = frames(40);
    while (!(g.phase === 'InRun' && g.level === 'Level0_Basement' && g.levelActive) && guard-- > 0) await step(1);
    if (guard <= 0) return { error: `no run: ${g.phase} ${g.level}` };
    // the per-tick record, after every system ticked
    const round = (v) => Math.round(v * 1e6) / 1e6;
    const vec = (v) => (v ? [round(v.x), round(v.y), round(v.z)] : null);
    const ticks = [];
    let tick = 0;
    let noises = [];
    let caught = [];
    e.noise.on((n) => noises.push([n.kind, ...vec(n.position), round(n.radius), n.source || '', n.level || '']));
    const api = g.creature;
    if (api.caught && api.caught.connect) api.caught.connect((kind) => caught.push(String(kind)));
    const t0 = loop.time;
    loop.onTick(() => {
      tick++;
      const p = e.player;
      const s = api.snapshot ? api.snapshot() : null;
      const floor = g.floors && g.floors.floor ? g.floors.floor(g.level) : null;
      ticks.push({
        tick,
        t: round(loop.time - t0),
        level: g.level,
        phase: g.phase,
        player: vec(p.rootPosition()),
        velocity: vec(p.body.velocity),
        move: p.moveState,
        life: g.life ? g.life.state : null,
        health: g.life ? round(g.life.health) : null,
        stamina: round(p.meters.stamina.value),
        battery: round(p.meters.battery.value),
        torch: p.flashlight.on,
        creature: s ? {
          state: s.state, reason: s.reason, pos: vec(s.position), pose: s.pose, hidden: s.hidden, target: s.targetingPlayer,
          catching: s.catching, warping: s.warping, teleports: s.teleports, action: s.action || null, awake: s.awake,
        } : null,
        objective: floor && floor.progress ? [...floor.progress.entries()].map(([k, v]) => `${k}:${v}`).join(',') : null,
        carry: g.floors && g.floors.carry && g.floors.carry.bags
          ? JSON.stringify([...g.floors.carry.bags.entries()].map(([k, v]) => [String(k), v.items instanceof Map ? [...v.items.entries()] : [], v.ids || []]))
          : null,
        noises,
        caught,
      });
      noises = [];
      caught = [];
    }, 1e9);
    // the script, applied on the frame it falls due
    const due = script.slice().sort((a, b) => a[0] - b[0]);
    let next = 0;
    const replies = [];
    const n = frames(total);
    const passes = new Set();
    const particles = new Set();
    let fixtureShadows = 0;
    let drawn = 0;
    for (let f = 0; f < n; f++) {
      const t = loop.time - t0;
      while (next < due.length && due[next][0] <= t + 1e-9) {
        const [, action, a, b] = due[next++];
        if (action === 'key') window.dispatchEvent(new KeyboardEvent(b ? 'keydown' : 'keyup', { code: a, key: a, bubbles: true }));
        else if (action === 'look') e.player.setLook(a, b);
        else if (action === 'creature') replies.push(`${a}: ${api.devCommand(a)}`);
      }
      e.skipRender = f % drawEvery !== 0;
      loop._run(dt, dt);
      if (!e.skipRender) {
        drawn++;
        for (const p of (e.renderer.stats.passes || '').split(' ')) if (p) passes.add(p.replace(/\d+$/, ''));
        fixtureShadows = Math.max(fixtureShadows, e.renderer.stats.fixtureShadows || 0);
        for (const sys of e.particles.systems) if (sys.points.visible) particles.add(sys.name);
      }
      await null;
    }
    e.skipRender = false;
    return {
      ticks, replies,
      tier: e.quality.tier,
      frames: n,
      drawn,
      textures: e.textures.current,
      passes: [...passes].join(' '),
      fixtureShadows,
      particles: [...particles],
    };
  }, [SCRIPT, 1 / fps, seconds, DRAW_EVERY[fps] || Math.max(1, Math.round(fps / 24))]);
  await context.close();
  if (log.error) throw new Error(log.error);
  log.errors = errors;
  return log;
}

/** The first difference between two tick logs (null when identical). */
function firstDifference(a, b) {
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) {
    const x = JSON.stringify(a[i]);
    const y = JSON.stringify(b[i]);
    if (x !== y) return { tick: i + 1, a: a[i], b: b[i] };
  }
  return null;
}

function summary(ticks) {
  const states = new Set();
  let noises = 0;
  let caught = 0;
  let moved = 0;
  let maxSpeed = 0;
  for (let i = 0; i < ticks.length; i++) {
    const t = ticks[i];
    if (t.creature) states.add(t.creature.state);
    noises += t.noises.length;
    caught += t.caught.length;
    if (i > 0 && t.player && ticks[i - 1].player) moved += Math.hypot(t.player[0] - ticks[i - 1].player[0], t.player[2] - ticks[i - 1].player[2]);
    if (t.velocity) maxSpeed = Math.max(maxSpeed, Math.hypot(t.velocity[0], t.velocity[2]));
  }
  const last = ticks[ticks.length - 1] || {};
  return { ticks: ticks.length, states: [...states], noises, caught, moved: Math.round(moved), maxSpeed: Math.round(maxSpeed * 10) / 10, life: last.life, objective: last.objective };
}

const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist',
  '--autoplay-policy=no-user-gesture-required', '--enable-webgl'] });
const results = {};
try {
  for (const fps of rates) {
    const logs = {};
    for (const tier of tiers) {
      const t0 = Date.now();
      logs[tier] = await play(browser, tier, fps);
      const s = summary(logs[tier].ticks);
      console.log(`  ${tier} at ${fps} fps: ${logs[tier].frames} frames (${logs[tier].drawn} drawn) in ${((Date.now() - t0) / 1000).toFixed(0)} s; ` +
        `passes seen: ${logs[tier].passes || 'world only'}; fixture shadows up to ${logs[tier].fixtureShadows}; particles ${logs[tier].particles.join(',') || 'none'}; ` +
        `${JSON.stringify(s)}; ${logs[tier].replies.join(' | ')}`);
      check(`${tier} at ${fps} fps plays without page errors`, logs[tier].errors.length === 0, logs[tier].errors.slice(0, 3).join(' | '));
      check(`${tier} at ${fps} fps really is ${tier}`, logs[tier].tier === tier, logs[tier].tier);
    }
    const [a, b] = tiers;
    const s = summary(logs[a].ticks);
    check(`the scenario happened at ${fps} fps (moved, sprinted, heard, chased)`,
      s.moved > 40 && s.maxSpeed > 15 && s.noises > 10 && s.states.includes('WallChase'), s);
    const diff = firstDifference(logs[a].ticks, logs[b].ticks);
    check(`${a} and ${b} play identically at ${fps} fps: ${logs[a].ticks.length} ticks, every player, Creature, noise, objective and catch value equal`,
      !diff && logs[a].ticks.length === logs[b].ticks.length, diff ? diff : `${summary(logs[b].ticks).noises} noise pulses, ${s.caught} catches`);
    results[fps] = logs[a].ticks;
  }
  if (rates.length > 1) {
    // informational: the render loop's rate is not a tier, and a frame's input lands on the next tick at any rate;
    // the game's per-frame systems (camera, torch battery) integrate per frame, so these may differ
    const diff = firstDifference(results[rates[0]], results[rates[1]]);
    console.log(`INFO  ${rates[0]} fps vs ${rates[1]} fps: ${diff ? `first difference at tick ${diff.tick}` : 'identical'}`);
  }
} finally {
  await browser.close();
}
console.log(failed ? 'TIER PARITY FAILED' : 'TIER PARITY PASSED');
process.exit(failed ? 1 : 0);
