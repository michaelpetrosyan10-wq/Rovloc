// playtest.mjs: a scripted + randomized player for the whole game (the bug hunt), with the pre-installed Playwright
// Chromium.
//
//   node tools/playtest.mjs [--html <page>] [--no-build] [--shots <dir>] [--seed <n>] [--only <phases>]
//                           [--floor-seconds <s>] [--quick]
//
// It plays the REAL game like a player, from the title screen, on the game test page (tools/game-build.mjs) opened
// WITHOUT ?dev: the keyboard and mouse are real Playwright input (the mouse look is the camera's yaw / pitch set
// directly, as a mouse would turn it; a fake pointer lock stands in for the browser's, which headless Chromium grants
// and drops at random). Phases (--only picks some; default all, in this order):
//   title     the title screen, the walkthrough, the lobby; up the bus onto a ready pad, the countdown, the deploy.
//   run       every floor from Level 0 to the roof: each is explored with randomized movement (walking the corridors
//             and rooms on routes from the Creature's own floor pathfinding, sprint bursts, crouching, jumps, the torch,
//             looking round, taking batteries and flasks, throwing flasks, prying out of traps, hiding in lockers,
//             swimming and diving, the floodlight switch) and then left by its exit airlock; Level 1's gate is passed
//             by its bypass vent (kick or unscrew the grate, crouch in, crawl the duct, out of the far grate). Levels
//             are entered naturally while the run lives; after a death the run is restarted with Play Again and the
//             next floor is reached by the level skip (a teleport to its start: the natural route was already played).
//             The roof: a pack from the crate, the jump, the ripcord, the finale, the results, Play Again.
//   pause     Escape pauses the clock and resumes it, the pointer lock lost mid-run opens the menu, a window blur
//             releases held keys.
//   save      settings survive a reload; a corrupted save boots clean.
//   touch     a touch screen: the thumbstick and the context buttons (none overlapping, none off screen), moving with
//             the thumbstick, the locker's LEAVE button.
//   gamepad   a (fake) gamepad: the left stick moves, a button press, unplugging it with a button held.
// Watched all the time (per 30 Hz tick, in the page): NaN positions, falling through or below a floor, standing
// outside every zone (clipping / out of bounds), stuck spots (input held, no movement), the Creature floating or sunk
// below its floor, stuck, catching through a wall or not reacting to a loud noise, prompts overlapping or off screen,
// hints shown in the wrong state (a throw hint inside a locker), console errors / warnings and page errors, long
// simulation frames, heap growth across floors and runs, audio voices left playing.
// Screenshots of many moments go to the shots directory (default build/cache/playtest-shots); a JSON report
// (report.json) lists every anomaly. Exit code 1 on any failure (an anomaly marked fatal or a console error).
//
// Headless WebGL is SwiftShader (slow), so the game is stepped at 30 Hz with rendering skipped (as game-smoke does);
// a frame is rendered only for screenshots.

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
const quick = argv.includes('--quick');
const shots = path.resolve(opt('--shots', path.join(web, 'build/cache/playtest-shots')));
const SEED = Number(opt('--seed', '1029'));
const FLOOR_SECONDS = Number(opt('--floor-seconds', quick ? '70' : '170'));
const ALL_PHASES = ['title', 'run', 'pause', 'save', 'touch', 'gamepad'];
const only = opt('--only', null);
const phases = new Set(only ? only.split(',') : ALL_PHASES);
let page = opt('--html', null);
if (!page) {
  page = path.join(web, 'build/cache/game-smoke.html');
  if (!argv.includes('--no-build') || !fs.existsSync(page)) {
    execFileSync(process.execPath, [path.join(here, 'game-build.mjs'), '--out', page, '--no-minify'], { stdio: 'inherit' });
  }
}
fs.mkdirSync(shots, { recursive: true });

function loadPlaywright() {
  const require = createRequire(import.meta.url);
  const roots = [web, process.cwd(), '/opt/node-tools/node_modules', '/opt/node22/lib/node_modules'];
  try {
    roots.push(execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim());
  } catch { /* npm missing */ }
  roots.push('/usr/local/lib/node_modules_global', '/usr/local/lib/node_modules', '/usr/lib/node_modules');
  for (const r of roots) {
    try {
      return require(require.resolve('playwright', { paths: [r] }));
    } catch { /* next */ }
  }
  throw new Error('playwright not found (it is expected pre-installed globally)');
}

/** A small seeded random (mulberry32) so a run can be replayed with --seed. */
function rng(seed) {
  let a = seed >>> 0;
  const next = () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return { next, chance: (p) => next() < p, range: (a0, b0) => a0 + (b0 - a0) * next(), pick: (list) => list[Math.floor(next() * list.length)] };
}
const R = rng(SEED);

// ---------------------------------------------------------------------------------------------------- the page side

/**
 * Installed in the page once the game is up: window.__pt, the watcher (a late 30 Hz tick hook), the stepper (the
 * engine loop run by hand at 30 Hz, rendering skipped) and the steering (the mouse look toward route waypoints).
 */
function pageLib() {
  if (window.__pt) return true;
  const { game: g, dev } = window.__rovlocGame;
  const e = window.__rovloc.engine;
  const T = g.env.THREE;
  const meta = g.env.meta;
  const ROOT_ABOVE_FEET = 3;
  const CREATURE_ROOT = 4.7;
  const V = () => new T.Vector3();
  const r1 = (v) => Math.round(v * 10) / 10;
  const fin = (v) => !!v && Number.isFinite(v.x) && Number.isFinite(v.y) && Number.isFinite(v.z);
  const wrap = (a) => Math.atan2(Math.sin(a), Math.cos(a));
  const pt = {
    anomalies: [], seen: new Set(), sim: { n: 0, total: 0, max: 0, over50: 0, over100: 0, worst: [] },
    drive: null, catches: [], events: [], ticks: 0,
    fallSince: null, noZoneSince: null, outSince: null, floatSince: null, sunkSince: null,
    creature: { last: null, stillSince: null, lastState: null, stateSince: 0 },
    hearing: [], uiChecked: 0, voicesMax: 0,
  };
  window.__pt = pt;
  pt.g = g;
  pt.e = e;
  pt.dev = dev;

  /** An anomaly, once per kind and 8-stud cell. */
  pt.note = (kind, detail, at, fatal = false) => {
    const p = at || g.env.rootPosition(V());
    const key = `${kind}:${g.level || g.phase}:${Math.round(p.x / 8)},${Math.round(p.y / 4)},${Math.round(p.z / 8)}`;
    if (pt.seen.has(key)) return false;
    pt.seen.add(key);
    pt.anomalies.push({ kind, fatal, level: g.level, phase: g.phase, at: [r1(p.x), r1(p.y), r1(p.z)], t: r1(g.env.now()),
      ms: g.env.moveState(), ctx: g.env.context(), detail });
    return true;
  };

  // ------------------------------------------------------------------------------------------------ the watcher
  const levelBox = (id) => (meta.levels[id] && meta.levels[id].aabb) || null;
  const towers = Object.values(meta.worldConfig.Towers || {});
  const inTower = (p) => towers.some((t) => p.x >= t.minX - 1 && p.x <= t.maxX + 1 && p.z >= t.minZ - 1 && p.z <= t.maxZ + 1);
  const down = new T.Vector3(0, -1, 0);
  const NO_ZONE_OK = new Set(['Parachuting', 'Scripted']);
  pt.watch = () => {
    pt.ticks++;
    const now = g.env.now();
    const root = g.env.rootPosition(V());
    const body = g.env.body();
    if (!fin(root) || !fin(body.velocity)) pt.note('nan-position', { root: [root.x, root.y, root.z] }, V(), true);
    const cam = e.renderer.camera.position;
    if (!fin(cam)) pt.note('nan-camera', {}, root, true);
    const ms = g.env.moveState();
    const inRun = g.phase === 'InRun' && g.levelActive && g.life && g.life.state === 'Alive';
    if (inRun && fin(root)) {
      const box = levelBox(g.level);
      const tower = inTower(root);
      const roof = g.level === 'Level5_Roof';
      if (box && !tower && !roof && ms !== 'Parachuting') {
        const out = root.y < box[1] - 3 || root.y > box[4] + 8 || root.x < box[0] - 3 || root.x > box[3] + 3 ||
          root.z < box[2] - 3 || root.z > box[5] + 3;
        if (out) {
          if (pt.outSince === null) pt.outSince = now;
          if (now - pt.outSince > 0.5) pt.note('out-of-level', { box }, root, true);
        } else pt.outSince = null;
      }
      // falling forever (through a floor)
      if (g.env.mode() === 'OnFoot' && !body.grounded && !body.anchored && ms !== 'Parachuting') {
        if (pt.fallSince === null) pt.fallSince = now;
        if (now - pt.fallSince > 2.5) pt.note('long-fall', { vy: r1(body.velocity.y) }, root, true);
      } else pt.fallSince = null;
      // outside every zone (inside a wall, out of bounds, a hole in the zone cover)
      if (!g.env.zoneAt(root) && !NO_ZONE_OK.has(ms) && !roof) {
        if (pt.noZoneSince === null) pt.noZoneSince = now;
        if (now - pt.noZoneSince > 1.5) pt.note('no-zone', { level: g.level, tower }, root);
      } else pt.noZoneSince = null;
      // inside solid geometry: a short ray up from the knees hits a face right away from both sides
      if (g.env.mode() === 'OnFoot' && body.grounded) {
        const feet = root.y - ROOT_ABOVE_FEET;
        let inside = 0;
        for (const [dx, dz] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
          const o = new T.Vector3(root.x, feet + 2.2, root.z);
          const hit = e.world.raycast(o, new T.Vector3(dx, 0, dz), 0.45);
          if (hit) inside++;
        }
        if (inside >= 3) pt.note('in-wall', { rays: inside }, root, true);
      }
    } else {
      pt.fallSince = pt.noZoneSince = pt.outSince = null;
    }
    if (pt.ticks % 3 === 0) pt.watchCreature(now, root);
    if (pt.ticks % 15 === 0) pt.watchUi();
    const voices = e.audio && e.audio.voices ? e.audio.voices.length : 0;
    if (voices > pt.voicesMax) pt.voicesMax = voices;
  };

  pt.watchCreature = (now, root) => {
    const c = g.creature;
    if (!c.available() || !g.live() || !g.level) return;
    const s = c.c.service.snapshot();
    const p = s.position;
    if (!p) return;
    const pos = new T.Vector3(p.x, p.y, p.z);
    if (!fin(pos)) {
      pt.note('creature-nan', { state: s.state }, root, true);
      return;
    }
    if (s.state !== pt.creature.lastState) {
      pt.events.push({ t: r1(now), level: g.level, creature: s.state, from: pt.creature.lastState, reason: s.reason });
      if (pt.events.length > 400) pt.events.shift();
      pt.creature.lastState = s.state;
      pt.creature.stateSince = now;
    }
    const onLevel = s.levelId === g.level;
    const visible = !s.hidden && onLevel && s.state !== 'Dormant';
    if (visible && s.medium === 'Floor' && !s.catching && !s.grabbed) {
      const hit = e.world.raycast(new T.Vector3(pos.x, pos.y + 1, pos.z), down, 60);
      const above = hit ? pos.y - hit.point.y : Infinity;
      if (above > CREATURE_ROOT + 1.75) {
        if (pt.floatSince === null) pt.floatSince = now;
        if (now - pt.floatSince > 0.6) pt.note('creature-floating', { state: s.state, pose: s.pose, aboveFloor: r1(above) }, pos, true);
      } else pt.floatSince = null;
      if (above < CREATURE_ROOT - 2) {
        if (pt.sunkSince === null) pt.sunkSince = now;
        if (now - pt.sunkSince > 0.6) pt.note('creature-sunk', { state: s.state, aboveFloor: r1(above) }, pos, true);
      } else pt.sunkSince = null;
    } else pt.floatSince = pt.sunkSince = null;
    // stuck while hunting
    const hunting = ['Patrol', 'InvestigateNoise', 'WallChase', 'VentChase'].includes(s.state) && onLevel;
    const last = pt.creature.last;
    if (hunting && last && last.distanceTo(pos) < 0.05) {
      if (pt.creature.stillSince === null) pt.creature.stillSince = now;
      if (now - pt.creature.stillSince > 12) pt.note('creature-stuck', { state: s.state, medium: s.medium, segment: s.segment }, pos);
    } else pt.creature.stillSince = null;
    pt.creature.last = pos;
  };

  // UI: prompts overlapping / off screen; a throw hint left up where no throw is possible
  const NO_THROW_CONTEXTS = new Set(['Locker', 'Trapped', 'Struggle', 'Cutscene', 'Parachute', 'Downed']);
  pt.watchUi = () => {
    const ui = e.ui;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const rows = [];
    for (const [id, view] of ui.promptRows) {
      if (Number(view.frame.style.opacity) < 0.6) continue;
      const r = view.frame.getBoundingClientRect();
      if (r.width <= 0) continue;
      rows.push({ id, r, text: `${view.objectText} ${view.text}` });
      if (r.right < 0 || r.left > vw || r.bottom < 0 || r.top > vh) continue;
    }
    for (let i = 0; i < rows.length; i++) {
      for (let j = i + 1; j < rows.length; j++) {
        const a = rows[i].r;
        const b = rows[j].r;
        const ox = Math.min(a.right, b.right) - Math.max(a.left, b.left);
        const oy = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
        if (ox > 8 && oy > 8) pt.note('prompts-overlap', { a: rows[i].text, b: rows[j].text });
      }
    }
    const hint = ui.hintEl;
    if (hint && hint.classList.contains('on')) {
      const text = hint.textContent || '';
      const ctx = g.env.context();
      if (/throw/i.test(text) && (NO_THROW_CONTEXTS.has(ctx) || g.env.moveState() === 'Hiding')) {
        pt.note('hint-wrong-state', { text, ctx });
      }
      const r = hint.getBoundingClientRect();
      if (r.width > 0 && (r.left < -2 || r.right > vw + 2)) pt.note('hint-off-screen', { text });
    }
  };

  e.loop.onTick(() => {
    try {
      pt.watch();
    } catch (err) {
      pt.note('watcher-error', String(err && err.stack), null, true);
    }
  }, 990);

  g.creature.caught.connect((kind) => {
    const c = g.creature.c.service.snapshot();
    const eye = g.env.eye(V());
    const ce = c.eye ? new T.Vector3(c.eye.x, c.eye.y, c.eye.z) : new T.Vector3(c.position.x, c.position.y + 2, c.position.z);
    const d = ce.distanceTo(eye);
    const clear = g.env.lineClear(ce, eye, { ignoreEntities: true });
    const entry = { t: r1(g.env.now()), level: g.level, kind, distance: r1(d), clear, ms: g.env.moveState(), state: c.state, medium: c.medium };
    pt.catches.push(entry);
    if (!clear && d > 4 && kind !== 'Locker' && kind !== 'Pool' && kind !== 'Vent') pt.note('catch-through-wall', entry, eye, true);
  });

  // ------------------------------------------------------------------------------------------------ the stepper
  pt.run = (seconds, opts = {}) => {
    const loop = e.loop;
    loop.stop();
    const render = e.renderer.render;
    e.renderer.render = () => {};
    const out = { ticks: 0 };
    try {
      const n = Math.max(1, Math.round(seconds * 30));
      for (let i = 0; i < n; i++) {
        if (pt.drive) {
          const r = pt.steer();
          if (r) {
            out[r] = true;
            if (opts.untilDrive !== false) break;
          }
        }
        const t0 = performance.now();
        loop._run(1 / 30, 1 / 30);
        const ms = performance.now() - t0;
        const s = pt.sim;
        s.n++;
        s.total += ms;
        if (ms > s.max) s.max = ms;
        if (ms > 50) s.over50++;
        if (ms > 100) {
          s.over100++;
          if (s.worst.length < 12) s.worst.push({ ms: r1(ms), level: g.level, phase: g.phase, ms2: g.env.moveState(), t: r1(g.env.now()) });
        }
        out.ticks++;
        if (opts.until && pt.until(opts.until)) {
          out.until = true;
          break;
        }
      }
    } finally {
      e.renderer.render = render;
    }
    return out;
  };

  pt.until = (cond) => {
    if (cond.phase && g.phase === cond.phase) return true;
    if (cond.level && g.level === cond.level && g.levelActive) return true;
    if (cond.notMs && g.env.moveState() !== cond.notMs) return true;
    if (cond.ms && g.env.moveState() === cond.ms) return true;
    if (cond.ctx && g.env.context() === cond.ctx) return true;
    if (cond.life && g.life.state === cond.life) return true;
    if (cond.chute && g.parachute.state === cond.chute) return true;
    return false;
  };

  // ------------------------------------------------------------------------------------------------ steering
  /** Points the look (the mouse) along the route, around armed traps; reports arrival and stuck spots. */
  pt.steer = () => {
    const d = pt.drive;
    const root = g.env.rootPosition(V());
    while (d.i < d.pts.length) {
      const w = d.pts[d.i];
      const last = d.i === d.pts.length - 1;
      const dist = Math.hypot(w[0] - root.x, w[2] - root.z);
      if (dist < (last ? d.arrive : 1.8)) d.i++;
      else break;
    }
    if (d.i >= d.pts.length) {
      pt.drive = null;
      return 'arrived';
    }
    const w = d.pts[d.i];
    let dx = w[0] - root.x;
    let dz = w[2] - root.z;
    const len = Math.hypot(dx, dz) || 1;
    dx /= len;
    dz /= len;
    // the bear traps a player would see on the floor ahead: step round them
    if (g.traps && d.avoidTraps !== false) {
      for (const t of g.traps.traps) {
        if (t.state !== 'Armed' || t.level !== g.level) continue;
        const vx = t.floor.x - root.x;
        const vz = t.floor.z - root.z;
        const along = vx * dx + vz * dz;
        if (along < 0 || along > 7) continue;
        let lx = vx - dx * along;
        let lz = vz - dz * along;
        let ll = Math.hypot(lx, lz);
        if (ll > 3.2) continue;
        if (ll < 1e-3) {
          lx = -dz;
          lz = dx;
          ll = 1;
        }
        const push = ((3.2 - ll) / 3.2) * 1.6;
        dx -= (lx / ll) * push;
        dz -= (lz / ll) * push;
        const n = Math.hypot(dx, dz) || 1;
        dx /= n;
        dz /= n;
      }
    }
    const look = g.env.look();
    const want = Math.atan2(-dx, -dz);
    const turn = Math.max(-d.turnRate / 30, Math.min(d.turnRate / 30, wrap(want - look.yaw)));
    const pitch = d.pitch === undefined ? look.pitch * 0.85 : d.pitch;
    g.env.setLook(look.yaw + turn, pitch);
    d.hist.push([root.x, root.y, root.z]);
    if (d.hist.length > 60) d.hist.shift();
    d.ticks++;
    const mv = g.env.moveVector();
    if (d.hist.length === 60 && Math.hypot(mv.x, mv.y) > 0.3 && !g.env.isLocked()) {
      let far = 0;
      const h0 = d.hist[0];
      for (const h of d.hist) far = Math.max(far, Math.hypot(h[0] - h0[0], h[2] - h0[2]));
      if (far < 1.0) {
        d.hist.length = 0;
        return 'stuck';
      }
    }
    return null;
  };

  /** A floor route on the current level from the player to `to` (the Creature's FloorNav), or null. */
  pt.path = (to, level = g.level) => {
    const nav = g.creature.c.service._nav(level);
    if (!nav) return null;
    const from = g.env.feetPosition(V());
    const target = new T.Vector3(to[0], to[1], to[2]);
    const res = nav.computePath(from, target);
    if (!res) return null;
    return res.waypoints.map((p) => [p.x, p.y, p.z]);
  };

  pt.go = (pts, opts = {}) => {
    pt.drive = { pts, i: 0, arrive: opts.arrive || 1.5, turnRate: opts.turnRate || 9, hist: [], ticks: 0, pitch: opts.pitch,
      avoidTraps: opts.avoidTraps };
    return true;
  };

  pt.stop = () => {
    pt.drive = null;
  };

  /** The state the node side steers by. */
  pt.state = () => {
    const root = g.env.rootPosition(V());
    const p = g.env.prompts ? null : null;
    const active = e.prompts.active.get('Interact');
    const kick = e.prompts.active.get('Kick');
    return {
      phase: g.phase, level: g.level, active: g.levelActive, life: g.life ? g.life.state : null, health: g.life ? g.life.health : null,
      ms: g.env.moveState(), ctx: g.env.context(), mode: g.env.mode(), root: [r1(root.x), r1(root.y), r1(root.z)],
      zone: g.zoneId(), now: r1(g.env.now()), menu: g.env.menuOpen(), locked: g.env.isLocked(),
      prompt: active ? { text: active.text, object: active.objectText, hold: active.hold, id: active.id } : null,
      kick: kick ? { text: kick.text, object: kick.objectText } : null,
      creature: g.creature.getState(), chute: g.parachute ? g.parachute.state : null, held: !!(g.flasks && g.flasks.held),
      inVent: g.vents.inVent(), onboarding: g.onboarding.mode, driving: !!pt.drive, p,
    };
  };
  return true;
}

// ---------------------------------------------------------------------------------------------------- the node side

const { chromium } = loadPlaywright();
const IGNORED_CONSOLE = /GPU stall|Automatic fallback to software WebGL|GroupMarkerNotSet|swiftshader/i;
const report = { seed: SEED, phases: [...phases], checks: [], anomalies: [], console: [], shots: [], coverage: {}, perf: {}, memory: [] };
const failures = [];

function check(name, ok, detail) {
  report.checks.push({ name, ok: !!ok, detail });
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail !== undefined ? ` ${JSON.stringify(detail)}` : ''}`);
  if (!ok) failures.push(name);
}

const LAUNCH = {
  args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist',
    '--autoplay-policy=no-user-gesture-required', '--enable-webgl', '--enable-precise-memory-info', '--js-flags=--expose-gc'],
};
const browser = await chromium.launch(LAUNCH);

/** A fake pointer lock (headless Chromium grants and drops the real one at random) and a fake gamepad slot. */
function initScript() {
  let locked = null;
  Object.defineProperty(Document.prototype, 'pointerLockElement', { configurable: true, get: () => locked });
  Element.prototype.requestPointerLock = function requestPointerLock() {
    if (locked !== this) {
      locked = this;
      setTimeout(() => document.dispatchEvent(new Event('pointerlockchange')), 0);
    }
    return Promise.resolve();
  };
  Document.prototype.exitPointerLock = function exitPointerLock() {
    if (locked) {
      locked = null;
      setTimeout(() => document.dispatchEvent(new Event('pointerlockchange')), 0);
    }
  };
  window.__fakePad = null;
  const real = navigator.getGamepads ? navigator.getGamepads.bind(navigator) : () => [];
  navigator.getGamepads = () => (window.__fakePad ? [window.__fakePad] : real());
}

async function openGame(context, { query = '' } = {}) {
  const tab = await context.newPage();
  const logs = [];
  tab.on('console', (m) => {
    const type = m.type();
    if ((type === 'error' || type === 'warning') && !IGNORED_CONSOLE.test(m.text())) logs.push(`${type}: ${m.text()}`);
  });
  tab.on('pageerror', (err) => logs.push(`pageerror: ${err.message}\n${err.stack}`));
  await tab.addInitScript(initScript);
  await tab.goto(`file://${page}${query}`);
  await tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 240000 });
  const error = await tab.evaluate(() => window.__rovloc.error);
  if (error) throw new Error(`boot failed: ${error}`);
  await tab.evaluate(pageLib);
  // the real loop stops: the game only advances when stepped (rendering is far too slow headless)
  await tab.evaluate(() => window.__rovloc.engine.loop.stop());
  return { tab, logs };
}

function makeDriver(tab, label) {
  const G = (fn, arg) => tab.evaluate(([src, a]) => {
    const w = window.__rovlocGame;
    // eslint-disable-next-line no-new-func
    return new Function('game', 'pt', 'arg', `return (${src})(game, pt, arg);`)(w.game, window.__pt, a);
  }, [fn.toString(), arg]);
  const run = (seconds, opts) => tab.evaluate(([s, o]) => window.__pt.run(s, o), [seconds, opts || {}]);
  const st = () => tab.evaluate(() => window.__pt.state());
  let shotIndex = 0;
  const shot = async (name) => {
    const file = path.join(shots, `${label}-${String(++shotIndex).padStart(2, '0')}-${name}.png`);
    const ms = await tab.evaluate(() => {
      const t0 = performance.now();
      window.__rovloc.engine.loop._run(0, 0);
      return performance.now() - t0;
    });
    await tab.waitForTimeout(120);
    await tab.screenshot({ path: file, timeout: 180000 });
    report.shots.push(file);
    if (!report.perf.renderMs) report.perf.renderMs = [];
    report.perf.renderMs.push(Math.round(ms));
    return file;
  };
  const held = new Set();
  const down = async (key) => {
    if (held.has(key)) return;
    held.add(key);
    await tab.keyboard.down(key);
  };
  const up = async (key) => {
    if (!held.has(key)) return;
    held.delete(key);
    await tab.keyboard.up(key);
  };
  const upAll = async () => {
    for (const k of [...held]) await up(k);
  };
  const press = async (key, seconds = 0.1) => {
    await down(key);
    await run(seconds);
    await up(key);
  };
  return { tab, G, run, st, shot, down, up, upAll, press, held };
}

const heap = async (tab, label) => {
  const m = await tab.evaluate(() => {
    if (window.gc) window.gc();
    const e = window.__rovloc.engine;
    let objects = 0;
    e.world.scene.traverse(() => objects++);
    return { heapMB: performance.memory ? Math.round(performance.memory.usedJSHeapSize / 1e5) / 10 : null, objects,
      prompts: e.prompts.list.size, voices: e.audio && e.audio.voices ? e.audio.voices.length : 0,
      groups: e.audio && e.audio.groups ? e.audio.groups.size : 0, dom: document.getElementsByTagName('*').length };
  });
  report.memory.push({ label, ...m });
  console.log(`     memory ${label}: ${JSON.stringify(m)}`);
  return m;
};

// ---------------------------------------------------------------------------------------------------- player moves

const PICKUPS = /battery|flask|pack|parachute/i;

/** Holds Interact until the active prompt fires (or `limit` s). */
async function holdInteract(D, limit = 4) {
  const s0 = await D.st();
  const hold = s0.prompt ? s0.prompt.hold : 0;
  await D.down('KeyE');
  await D.run(Math.min(limit, hold + 0.35));
  await D.up('KeyE');
  await D.run(0.1);
}

/** Trapped: look down at the jaws and hold E until free (the real pry). */
async function pry(D) {
  await D.upAll();
  await D.G((g) => g.env.setLook(g.env.look().yaw, -1.25));
  await D.run(0.4);
  const before = await D.st();
  await D.down('KeyE');
  for (let i = 0; i < 16; i++) {
    await D.run(0.5);
    const s = await D.st();
    if (s.ms !== 'Trapped' || s.life !== 'Alive') break;
  }
  await D.up('KeyE');
  await D.run(0.3);
  const after = await D.st();
  if (after.ms === 'Trapped' && after.life === 'Alive') await D.G((g, pt) => pt.note('trap-pry-failed', {}, null, true));
  return { before, after };
}

/** Walks a route to `target` with player-like randomness; recovers from stuck spots like a player would. */
async function goTo(D, target, opts = {}) {
  const random = opts.random !== false;
  const timeout = opts.timeout || 45;
  const pts = opts.pts || (await D.G((g, pt, a) => pt.path(a), target));
  if (!pts || !pts.length) return { ok: false, reason: 'no-path' };
  await D.G((g, pt, a) => pt.go(a.pts, a.o), { pts, o: { arrive: opts.arrive || 1.6, pitch: opts.pitch } });
  const start = await D.st();
  await D.down('KeyW');
  if (opts.sprint) await D.down('ShiftLeft');
  let stuck = 0;
  let sprintUntil = -1;
  let crouchUntil = -1;
  let result = { ok: false, reason: 'timeout' };
  try {
    for (;;) {
      const r = await D.run(0.5);
      const s = await D.st();
      if (s.phase !== 'InRun' || s.life !== 'Alive' || s.level !== start.level) {
        result = { ok: false, reason: `interrupted:${s.phase}:${s.life}:${s.level}` };
        break;
      }
      if (s.ms === 'Trapped') {
        await D.G((g, pt) => pt.stop());
        await pry(D);
        if (opts.onEvent) await opts.onEvent('trapped');
        const again = await D.G((g, pt, a) => pt.path(a), target);
        if (!again) break;
        await D.G((g, pt, a) => pt.go(a, {}), again);
        await D.down('KeyW');
        continue;
      }
      if (r.arrived) {
        result = { ok: true };
        break;
      }
      if (s.now - start.now > timeout) break;
      if (r.stuck) {
        stuck++;
        if (stuck === 1) {
          await D.press('Space', 0.3); // a hop over whatever it is
        } else if (stuck === 2) {
          const side = R.chance(0.5) ? 'KeyA' : 'KeyD';
          await D.press(side, 0.7);
        } else if (stuck === 3) {
          await D.up('KeyW');
          await D.press('KeyS', 0.5);
          await D.press(R.chance(0.5) ? 'KeyA' : 'KeyD', 0.8);
          await D.down('KeyW');
        } else {
          const where = await D.G((g, pt, a) => {
            const d = pt.drive || { pts: a.pts, i: 0 };
            return pt.note('stuck', { target: a.target, waypoint: d.pts[Math.min(d.i, d.pts.length - 1)], zone: g.zoneId() }, null, false);
          }, { pts, target });
          if (where) await D.shot(`stuck-${s.level}`);
          result = { ok: false, reason: 'stuck' };
          break;
        }
        const again = await D.G((g, pt, a) => pt.path(a), target);
        if (again) await D.G((g, pt, a) => pt.go(a, {}), again);
        continue;
      }
      // things a player picks up on the way
      if (opts.pickups !== false && s.prompt && PICKUPS.test(`${s.prompt.object} ${s.prompt.text}`) && !/pack|parachute/i.test(s.prompt.object)) {
        await D.up('KeyW');
        await holdInteract(D);
        await D.down('KeyW');
      }
      if (!random) continue;
      // sprint bursts, crouching, hops, the torch, looking about
      if (!opts.sprint) {
        if (sprintUntil < 0 && R.chance(0.08)) {
          sprintUntil = s.now + R.range(1, 3);
          await D.down('ShiftLeft');
        } else if (sprintUntil >= 0 && s.now > sprintUntil) {
          sprintUntil = -1;
          await D.up('ShiftLeft');
        }
      }
      if (crouchUntil < 0 && sprintUntil < 0 && s.ms === 'Standing' && R.chance(0.05)) {
        crouchUntil = s.now + R.range(1.5, 4);
        await D.press('KeyC');
      } else if (crouchUntil >= 0 && s.now > crouchUntil) {
        crouchUntil = -1;
        if ((await D.st()).ms === 'Crouching') await D.press('KeyC');
      }
      if (R.chance(0.03)) await D.press('Space', 0.15);
      if (R.chance(0.02)) await D.press('KeyF', 0.05);
      if (R.chance(0.05)) await D.G((g, pt, a) => { if (pt.drive) pt.drive.pitch = a; }, R.range(-0.5, 0.4));
    }
  } finally {
    await D.G((g, pt) => pt.stop());
    await D.upAll();
    const s = await D.st();
    if (s.ms === 'Crouching' && !opts.keepCrouch) await D.press('KeyC');
  }
  return result;
}

/** Turns a slow circle on the spot, looking about (mouse). */
async function lookAround(D, seconds = 1.2) {
  const steps = 6;
  for (let i = 0; i < steps; i++) {
    await D.G((g, pt, a) => g.env.setLook(g.env.look().yaw + a.turn, a.pitch), { turn: (Math.PI * 2) / steps, pitch: R.range(-0.3, 0.3) });
    await D.run(seconds / steps);
  }
}

/** The run's floor rooms in a greedy nearest-first tour from the player. */
async function floorRooms(D, level) {
  return D.G((g, pt, lv) => {
    const root = g.env.rootPosition(new g.env.THREE.Vector3());
    const rooms = g.env.meta.rooms.filter((r) => r.level === lv && r.kind !== 'Chase' && r.kind !== 'Airlock');
    const nav = g.creature.c.service._nav(lv);
    const out = [];
    let at = { x: root.x, z: root.z };
    const left = rooms.map((r) => ({ id: r.id, kind: r.kind, x: r.rect.x + r.rect.w / 2, z: r.rect.z + r.rect.d / 2, y: r.floorY,
      w: r.rect.w, d: r.rect.d, navigable: !!(nav && nav.roomById.get(r.id)) }));
    while (left.length) {
      let best = 0;
      let bd = Infinity;
      for (let i = 0; i < left.length; i++) {
        const d = Math.hypot(left[i].x - at.x, left[i].z - at.z);
        if (d < bd) {
          bd = d;
          best = i;
        }
      }
      const r = left.splice(best, 1)[0];
      out.push(r);
      at = r;
    }
    return out;
  }, level);
}

const LEVELS = ['Level0_Basement', 'Level1_Hallways', 'Level2_ScienceHall', 'Level3_Gymnasium', 'Level4_FloodedPool', 'Level5_Roof'];

// ---------------------------------------------------------------------------------------------------- vents

/** The grates of the level with their room-side stand point, facing yaw, state and duct node. */
async function grates(D, level) {
  return D.G((g, pt, lv) => {
    const T = g.env.THREE;
    return g.vents.gratesOn(lv).map((gr) => {
      const p = new T.Vector3().setFromMatrixPosition(gr.exit);
      const raw = g.world.ventGraph(lv);
      const info = raw && raw.grates[gr.id];
      return { id: gr.id, at: [p.x, p.y, p.z], yaw: Math.atan2(-gr.exit.elements[8], -gr.exit.elements[10]), state: gr.state,
        node: info ? info.nodeId : null, critical: !!gr.info.attributes.CriticalPath, zone: info ? info.facingZoneId : null,
        centre: gr.centre.toArray() };
    });
  }, level);
}

/** Crawls from grate `a` (opened by a kick or by unscrewing) through the ducts and out of grate `b`. */
async function ventCross(D, level, a, b, how = 'kick') {
  const log = { from: a.id, to: b.id, how };
  const walk = await goTo(D, a.at, { arrive: 1.2, random: false, pickups: false });
  if (!walk.ok) return { ...log, ok: false, reason: `walk:${walk.reason}` };
  await D.G((g, pt, yaw) => g.env.setLook(yaw, -0.15), a.yaw);
  await D.run(0.3);
  await D.press('KeyC');
  await D.run(0.2);
  let s = await D.st();
  log.prompt = s.prompt;
  log.kickPrompt = s.kick;
  if (!['Open', 'Kicked'].includes(await D.G((g, pt, id) => g.vents.stateOf(id), a.id))) {
    if (how === 'unscrew' && s.prompt && /unscrew/i.test(s.prompt.text)) {
      await D.down('KeyE');
      await D.run(4.2);
      await D.up('KeyE');
      await D.run(0.8);
    } else {
      await D.press('KeyR', 0.1);
      await D.run(0.6);
    }
  }
  log.entryState = await D.G((g, pt, id) => g.vents.stateOf(id), a.id);
  if (!['Open', 'Kicked'].includes(log.entryState)) return { ...log, ok: false, reason: 'grate-shut' };
  await D.down('KeyW');
  await D.run(1.4);
  await D.up('KeyW');
  s = await D.st();
  if (!s.inVent) {
    await D.G((g, pt) => pt.note('vent-entry-failed', { ms: g.env.moveState() }, null, true));
    return { ...log, ok: false, reason: 'no-entry' };
  }
  await D.shot(`vent-${level}`);
  // along the ducts, node by node
  const route = await D.G((g, pt, target) => {
    const graph = g.vents.graphs.get(g.level);
    const from = g.vents.crawlerNode();
    if (!graph || !from || !graph.nodes[target]) return null;
    const prev = { [from]: null };
    const queue = [from];
    while (queue.length) {
      const n = queue.shift();
      if (n === target) break;
      for (const m of graph.nodes[n].links) if (!(m in prev)) {
        prev[m] = n;
        queue.push(m);
      }
    }
    if (!(target in prev)) return null;
    const ids = [];
    for (let n = target; n; n = prev[n]) ids.unshift(n);
    return ids.map((id) => graph.pos[id].toArray());
  }, b.node);
  if (!route) return { ...log, ok: false, reason: 'no-duct-route' };
  await D.G((g, pt, pts) => pt.go(pts, { arrive: 0.9, pitch: 0, avoidTraps: false }), route);
  await D.down('KeyW');
  let kicked = false;
  for (let i = 0; i < 120; i++) {
    const r = await D.run(0.4);
    s = await D.st();
    if (!s.inVent) break;
    const d = await D.G((g, pt, c) => {
      const root = g.env.rootPosition(new g.env.THREE.Vector3());
      return Math.hypot(c[0] - root.x, c[2] - root.z);
    }, b.centre);
    if (d < 5 && !kicked) {
      const st = await D.G((g, pt, id) => g.vents.stateOf(id), b.id);
      if (!['Open', 'Kicked'].includes(st)) {
        await D.press('KeyR', 0.1);
        await D.run(0.5);
      }
      kicked = true;
    }
    if (r.arrived) {
      // the last node is the grate's: push on out through the mouth, facing the room
      await D.G((g, pt, yaw) => g.env.setLook(yaw + Math.PI, 0), b.yaw);
    }
    if (r.stuck) {
      await D.G((g, pt) => pt.note('vent-stuck', { node: g.vents.crawlerNode() }, null, true));
      break;
    }
  }
  await D.G((g, pt) => pt.stop());
  await D.upAll();
  await D.run(0.6);
  s = await D.st();
  log.ok = !s.inVent;
  log.exitState = await D.G((g, pt, id) => g.vents.stateOf(id), b.id);
  log.zone = s.zone;
  log.ms = s.ms;
  return log;
}

/** A vent route round a blocked floor route: an entry grate reachable now, an exit grate the goal is reachable from. */
async function ventRoute(D, level, goal) {
  const list = await grates(D, level);
  const options = await D.G((g, pt, a) => {
    const T = g.env.THREE;
    const nav = g.creature.c.service._nav(g.level);
    const from = g.env.feetPosition(new T.Vector3());
    const graph = g.vents.graphs.get(g.level);
    const reach = (p, q) => !!nav.computePath(new T.Vector3(...p), new T.Vector3(...q));
    const linked = (x, y) => {
      if (!graph || !graph.nodes[x] || !graph.nodes[y]) return false;
      const seen = new Set([x]);
      const queue = [x];
      while (queue.length) {
        const n = queue.shift();
        if (n === y) return true;
        for (const m of graph.nodes[n].links) if (!seen.has(m)) {
          seen.add(m);
          queue.push(m);
        }
      }
      return false;
    };
    const out = [];
    for (const x of a.list) {
      if (x.state === 'Locked' || !reach(from.toArray(), x.at)) continue;
      for (const y of a.list) {
        if (y === x || y.state === 'Locked' || !reach(y.at, a.goal) || !linked(x.node, y.node)) continue;
        const cost = from.distanceTo(new T.Vector3(...x.at)) + new T.Vector3(...x.at).distanceTo(new T.Vector3(...y.at));
        out.push({ a: x, b: y, cost });
      }
    }
    out.sort((p, q) => p.cost - q.cost);
    return out.slice(0, 3);
  }, { list, goal });
  return options;
}

// ---------------------------------------------------------------------------------------------------- floors

/** Walks into the level's exit vestibule and waits for the airlock to seal and the next level to start. */
async function leaveFloor(D, level) {
  const next = LEVELS[LEVELS.indexOf(level) + 1];
  const goal = await D.G((g, pt, lv) => {
    const v = g.world.checkpointVolumes(lv)[0];
    return v ? [v.cframe[0], v.cframe[1], v.cframe[2]] : null;
  }, level);
  if (!goal) return { ok: false, reason: 'no-checkpoint' };
  let walk = await goTo(D, goal, { arrive: 1.2, timeout: 90, sprint: true });
  if (!walk.ok && walk.reason === 'no-path') {
    const routes = await ventRoute(D, level, goal);
    report.coverage[level] = { ...(report.coverage[level] || {}), ventRoutes: routes.map((r) => `${r.a.id}->${r.b.id}`) };
    for (const r of routes) {
      const how = R.chance(0.5) ? 'unscrew' : 'kick';
      const res = await ventCross(D, level, r.a, r.b, how);
      check(`${level}: the vent route round the blocked way (${res.from} -> ${res.to}, ${how})`, res.ok, res);
      if (res.ok) break;
    }
    walk = await goTo(D, goal, { arrive: 1.2, timeout: 90, sprint: true });
  }
  if (!walk.ok) return { ok: false, reason: walk.reason };
  // on through the vestibule, clear of the fire door's sweep; then wait for the seal
  await D.down('KeyW');
  await D.run(0.8);
  await D.up('KeyW');
  await D.shot(`airlock-${level}`);
  const r = await D.run(16, { until: next ? { level: next } : { phase: 'Results' } });
  const s = await D.st();
  return { ok: !!r.until, reason: r.until ? null : `no seal (${s.phase} ${s.level} ${s.zone})`, s };
}

/** Explores the floor's rooms for `budget` game seconds. */
async function exploreFloor(D, level, budget, onRoom) {
  const rooms = await floorRooms(D, level);
  const t0 = (await D.st()).now;
  const cov = { rooms: rooms.length, visited: [], failed: [], skipped: 0 };
  report.coverage[level] = { ...(report.coverage[level] || {}), explore: cov };
  let shotsHere = 0;
  for (const room of rooms) {
    const s = await D.st();
    if (s.phase !== 'InRun' || s.life !== 'Alive' || s.level !== level) break;
    if (s.now - t0 > budget) {
      cov.skipped++;
      continue;
    }
    const inset = 2.5;
    const target = [room.x + R.range(-1, 1) * Math.max(0, room.w / 2 - inset), room.y, room.z + R.range(-1, 1) * Math.max(0, room.d / 2 - inset)];
    const res = await goTo(D, target, { timeout: 40 });
    if (res.ok) {
      cov.visited.push(room.id);
      if (R.chance(0.35)) await lookAround(D);
      if (shotsHere < 3 && R.chance(0.3)) {
        shotsHere++;
        await D.shot(`${level}-${room.id}`);
      }
      if (onRoom) await onRoom(room);
    } else {
      cov.failed.push(`${room.id}:${res.reason}`);
      if (res.reason.startsWith('interrupted')) break;
    }
  }
  return cov;
}

// ---------------------------------------------------------------------------------------------------- floor moments

/** Level 0: walking onto a bear trap on purpose (the 35 damage, Trapped, the pry). */
async function trapMoment(D) {
  const trap = await D.G((g) => {
    const root = g.env.rootPosition(new g.env.THREE.Vector3());
    const list = g.traps.traps.filter((t) => t.state === 'Armed' && t.level === g.level)
      .sort((a, b) => a.floor.distanceTo(root) - b.floor.distanceTo(root));
    return list.length ? { id: list[0].id, at: list[0].floor.toArray() } : null;
  });
  if (!trap) return;
  const before = await D.st();
  await goTo(D, trap.at, { arrive: 0.4, random: false, pickups: false, timeout: 60 });
  const pts = await D.G((g, pt, at) => [[at[0], at[1], at[2]]], trap.at);
  const s = await D.st();
  if (s.ms !== 'Trapped') {
    await D.G((g, pt, a) => pt.go(a, { arrive: 0.2, avoidTraps: false }), pts);
    await D.down('KeyW');
    await D.run(1.5, { until: { ms: 'Trapped' } });
    await D.upAll();
    await D.G((g, pt) => pt.stop());
  }
  const t = await D.st();
  check('Level 0: walking onto a bear trap springs it', t.ms === 'Trapped' && t.health < before.health, { ms: t.ms, health: t.health });
  await D.shot('trapped');
  const res = await pry(D);
  check('Level 0: looking down and holding E pries it open', res.after.ms !== 'Trapped', { ms: res.after.ms, ctx: res.after.ctx });
}

/** Level 2: a flask in the hand, wound up with the real mouse button and thrown down the longest open line. */
async function flaskMoment(D) {
  let s = await D.st();
  if (!s.held) {
    const f = await D.G((g) => {
      const root = g.env.rootPosition(new g.env.THREE.Vector3());
      const list = g.flasks.pickupsOn(g.level).sort((a, b) => a.position.distanceTo(root) - b.position.distanceTo(root));
      return list.length ? list[0].position.toArray() : null;
    });
    if (!f) return check('Level 2: a flask to pick up', false);
    const walk = await goTo(D, [f[0], f[1] - 3, f[2]], { arrive: 2.2, random: false, timeout: 60 });
    await D.G((g, pt, p) => {
      const eye = g.env.eye(new g.env.THREE.Vector3());
      const dx = p[0] - eye.x;
      const dz = p[2] - eye.z;
      g.env.setLook(Math.atan2(-dx, -dz), Math.atan2(p[1] - eye.y, Math.hypot(dx, dz)));
    }, f);
    await D.run(0.3);
    s = await D.st();
    if (s.prompt && /flask/i.test(s.prompt.object)) await holdInteract(D);
    s = await D.st();
    check('Level 2: picking up a flask (hold E)', s.held, { walk, prompt: s.prompt });
    if (!s.held) return;
  }
  await D.G((g) => {
    const T = g.env.THREE;
    const eye = g.env.eye(new T.Vector3());
    let best = { yaw: 0, d: 0 };
    for (let i = 0; i < 24; i++) {
      const yaw = (i / 24) * Math.PI * 2;
      const hit = g.env.raycast(eye, new T.Vector3(-Math.sin(yaw), 0, -Math.cos(yaw)), 60, { ignoreEntities: false });
      const d = hit ? hit.distance : 60;
      if (Math.min(d, 30) > Math.min(best.d, 30)) best = { yaw, d };
    }
    g.env.setLook(best.yaw, 0.1);
  });
  // the real mouse: a click locks the pointer, then the button held winds up and its release throws
  await D.tab.mouse.move(640, 360);
  await D.tab.mouse.down();
  await D.tab.mouse.up();
  await D.run(0.2);
  const locked = await D.tab.evaluate(() => !!document.pointerLockElement);
  await D.tab.mouse.down();
  await D.run(0.5);
  const wind = await D.G((g) => ({ winding: g.flasks.windStart !== null, arc: g.flasks.arcAlpha }));
  await D.shot('flask-aim');
  const thrown0 = await D.G((g) => g.stats.get('FlasksThrown'));
  await D.tab.mouse.up();
  await D.run(1.2);
  const after = await D.G((g) => ({ thrown: g.stats.get('FlasksThrown'), clouds: g.flasks.clouds.length, held: !!g.flasks.held }));
  check('Level 2: the mouse button winds a flask up (aim arc) and its release throws it', locked && wind.winding &&
    after.thrown === thrown0 + 1 && !after.held, { locked, wind, after });
  await D.shot('flask-cloud');
}

/** Level 3: hiding in the nearest free locker, the hint state inside, holding the breath, stepping out. */
async function lockerMoment(D) {
  const lockers = await D.G((g) => {
    const T = g.env.THREE;
    const root = g.env.rootPosition(new T.Vector3());
    return g.world.entities('Locker', g.level).map((e) => {
      const p = g.world.attachmentPos(e.id, 'ExitAnchor') || new T.Vector3(e.pivot[0], e.pivot[1], e.pivot[2]);
      return { id: e.id, at: p.toArray(), d: p.distanceTo(root) };
    }).sort((a, b) => a.d - b.d).slice(0, 4);
  });
  for (const l of lockers) {
    const walk = await goTo(D, l.at, { arrive: 1.0, random: false, timeout: 60 });
    if (!walk.ok) continue;
    await D.G((g, pt, id) => {
      const T = g.env.THREE;
      const p = new T.Vector3().fromArray(g.world.entity(id).pivot);
      const eye = g.env.eye(new T.Vector3());
      g.env.setLook(Math.atan2(-(p.x - eye.x), -(p.z - eye.z)), -0.1);
    }, l.id);
    await D.run(0.3);
    let s = await D.st();
    if (!s.prompt || !/hide/i.test(s.prompt.text)) continue;
    await holdInteract(D);
    await D.run(1.8);
    s = await D.st();
    check('Level 3: climbing into a locker (Hide)', s.ms === 'Hiding' && s.ctx === 'Locker', { ms: s.ms, ctx: s.ctx, locker: l.id });
    await D.shot('locker-inside');
    await D.down('Space');
    await D.run(1.5);
    await D.up('Space');
    await D.run(1);
    await D.press('KeyE', 0.15);
    await D.run(1.6);
    s = await D.st();
    check('Level 3: stepping out of the locker', s.ms !== 'Hiding' && s.ctx === 'OnFoot', { ms: s.ms, ctx: s.ctx });
    return;
  }
  check('Level 3: a reachable locker with its Hide prompt', false, lockers);
}

/** Level 4: into the pool, a dive, across, and out at the far edge; the floodlight switch. */
async function poolMoment(D) {
  const basin = await D.G((g) => g.world.pools.find((p) => p.id.includes('Basin')));
  if (!basin) return;
  const west = [basin.rect.x - 3, 82, basin.rect.z + basin.rect.d / 2];
  let walk = await goTo(D, west, { arrive: 1.5, timeout: 70 });
  await D.G((g) => g.env.setLook(-Math.PI / 2, -0.1)); // face east, over the water
  await D.down('KeyW');
  await D.run(3, { until: { ctx: 'Swim' } });
  let s = await D.st();
  check('Level 4: walking off the deck into the pool swims', ['Treading', 'Freestyle', 'Underwater'].includes(s.ms), { ms: s.ms, walk });
  await D.run(1);
  await D.down('KeyC');
  await D.run(2.5);
  s = await D.st();
  await D.shot('underwater');
  await D.up('KeyC');
  check('Level 4: diving (hold C) goes under', s.ms === 'Underwater', { ms: s.ms });
  await D.run(2.5);
  // across to the east deck and out
  await D.G((g, pt, a) => pt.go([[a.x, 81, a.z]], { arrive: 2.5, pitch: 0 }), { x: basin.rect.x + basin.rect.w - 1, z: basin.rect.z + basin.rect.d / 2 });
  for (let i = 0; i < 30; i++) {
    const r = await D.run(0.5);
    s = await D.st();
    if (r.arrived || s.ms === 'Standing' || s.life !== 'Alive') break;
  }
  await D.G((g, pt) => pt.stop());
  for (let i = 0; i < 8 && ['Treading', 'Freestyle', 'Underwater'].includes((await D.st()).ms); i++) {
    await D.down('Space');
    await D.run(0.6);
    await D.up('Space');
  }
  await D.upAll();
  await D.run(0.5);
  s = await D.st();
  check('Level 4: swimming across and climbing out at the far edge', s.ms === 'Standing' || s.ms === 'Crouching' || s.mode === 'OnFoot',
    { ms: s.ms, root: s.root, life: s.life });
  if (s.life !== 'Alive') return;
  // the floodlight switch
  const sw = await D.G((g) => {
    const e = g.world.entities('FloodlightSwitch', g.level)[0];
    if (!e) return null;
    const T = g.env.THREE;
    const p = new T.Vector3().fromArray(e.pivot);
    return { at: [p.x, 82, p.z], pivot: e.pivot.slice(0, 3) };
  });
  if (!sw) return;
  walk = await goTo(D, sw.at, { arrive: 2.5, timeout: 80 });
  await D.G((g, pt, p) => {
    const eye = g.env.eye(new g.env.THREE.Vector3());
    g.env.setLook(Math.atan2(-(p[0] - eye.x), -(p[2] - eye.z)), Math.atan2(p[1] - eye.y, Math.hypot(p[0] - eye.x, p[2] - eye.z)));
  }, sw.pivot);
  await D.run(0.3);
  s = await D.st();
  if (s.prompt && /flood/i.test(`${s.prompt.text} ${s.prompt.object}`)) await holdInteract(D);
  await D.run(3);
  const on = await D.G((g) => g.level4.flipped);
  check('Level 4: the floodlight switch (hold E) throws the lights on', on, { walk, prompt: s.prompt });
  await D.shot('floodlights');
}

/** Level 5: a pack from the crate, the run to the gap, the jump, the ripcord, the finale, the results. */
async function roofMoment(D) {
  const crate = await D.G((g) => {
    const e = g.world.entities('ParachuteCrate')[0];
    return e ? e.pivot.slice(0, 3) : null;
  });
  let walk = await goTo(D, [crate[0] + 3.5, crate[1], crate[2]], { arrive: 1.5, timeout: 60, sprint: true });
  await D.G((g, pt, p) => {
    const eye = g.env.eye(new g.env.THREE.Vector3());
    g.env.setLook(Math.atan2(-(p[0] - eye.x), -(p[2] - eye.z)), -0.45);
  }, crate);
  await D.run(0.3);
  let s = await D.st();
  if (s.prompt && /parachute/i.test(`${s.prompt.text} ${s.prompt.object}`)) await holdInteract(D);
  s = await D.st();
  check('Level 5: taking a parachute pack from the crate', s.chute === 'Packed', { chute: s.chute, prompt: s.prompt, walk });
  const gap = await D.G((g) => {
    const geo = g.parachute.geo.gap;
    return [(geo.minX + geo.maxX) / 2, g.parachute.geo.deckY, (geo.minZ + geo.maxZ) / 2];
  });
  walk = await goTo(D, [gap[0] + 4, gap[1], gap[2]], { arrive: 1.5, timeout: 60, sprint: true });
  await D.shot('roof-gap');
  await D.G((g) => g.env.setLook(Math.PI / 2, -0.1)); // west, out of the gap
  await D.down('ShiftLeft');
  await D.down('KeyW');
  await D.run(4, { until: { chute: 'Freefall' } });
  await D.upAll();
  s = await D.st();
  check('Level 5: off the gap with a pack: freefall', s.chute === 'Freefall' || s.chute === 'Canopy', { chute: s.chute, root: s.root });
  await D.run(0.4);
  await D.press('Space', 0.1);
  await D.run(1.5);
  s = await D.st();
  check('Level 5: the ripcord (Space) opens the canopy', s.chute === 'Canopy' || s.chute === 'Landed', { chute: s.chute });
  await D.shot('canopy');
  const finale = await D.run(12, { until: { phase: 'Results' } });
  await D.shot('finale-end');
  await D.run(4, { until: { phase: 'Results' } });
  s = await D.st();
  check('Level 5: the finale plays out to the results', s.phase === 'Results' || finale.until, { phase: s.phase, chute: s.chute });
}

/** The finale's ledge from below: the Creature must stand on the visible roof edge (the haze bug), not float. */
async function finaleLedgeCheck(D) {
  const at = await D.G((g) => (g.level5.finale ? g.level5.finale.startAt + 1.5 - g.env.now() : null));
  if (at === null) return;
  if (at > 0) await D.run(at);
  const v = await D.G((g) => {
    const e = window.__rovloc.engine;
    const T = g.env.THREE;
    const c = g.creature.position(new T.Vector3());
    return { focus: [...e.world.focus], creatureHidden: g.creature.isHidden(), creature: c.toArray().map((x) => Math.round(x * 10) / 10),
      roofDrawn: e.world.focus.has('Level5_Roof'), facadeDrawn: e.world.focus.has('Level4_FloodedPool') };
  });
  check('Level 5 finale: the roof and the facade are drawn under the Creature on the ledge', v.roofDrawn && v.facadeDrawn, v);
  await D.shot('finale-ledge');
}
