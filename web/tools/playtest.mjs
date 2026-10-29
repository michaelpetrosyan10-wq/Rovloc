// playtest.mjs: a scripted + randomized player for the whole game (the bug hunt), with the pre-installed Playwright
// Chromium.
//
//   node tools/playtest.mjs [--html <page>] [--no-build] [--shots <dir>] [--seed <n>] [--only <phases>]
//                           [--floor-seconds <s>] [--quick] [--start <level>]
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
// --start <level>: (debugging a floor) the run phase starts there by the level skip
const START = opt('--start', null);
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
    drive: null, catches: [], events: [], ticks: 0, gameSpikes: [],
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
      // in a stair tower or an airlock vestibule (the previous floor's, after the seal) the player is between floors
      const z = g.env.zoneAt(root);
      const between = !!z && (/^Stairwell/.test(z.id) || z.kind === 'Airlock');
      if (box && !tower && !roof && !between && ms !== 'Parachuting') {
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

  // per-part timing, so a long frame names its culprit (or none: a GC pause)
  pt.parts = {};
  const timed = (obj, name, label) => {
    if (!obj || typeof obj[name] !== 'function') return;
    const orig = obj[name].bind(obj);
    obj[name] = (...a) => {
      const t0 = performance.now();
      try {
        return orig(...a);
      } finally {
        pt.parts[label] = (pt.parts[label] || 0) + performance.now() - t0;
      }
    };
  };
  for (const sys of g.systems) for (const m of ['tick', 'frame']) timed(sys, m, `${sys.name}.${m}`);
  timed(e.player, 'frame', 'player.frame');
  timed(e.prompts, 'update', 'prompts.update');
  timed(e.lighting, 'update', 'lighting.update');
  timed(e.volumetrics, 'update', 'volumetrics.update');
  timed(g.creature.c.service, 'step', 'creature.brain');
  timed(g.creature.c.service, 'stepMotion', 'creature.motion');
  timed(e.audio, 'update', 'audio.update');
  timed(e.world, 'setFocus', 'world.setFocus');
  pt.watchMs = 0;
  e.loop.onTick(() => {
    const t0 = performance.now();
    try {
      pt.watch();
    } catch (err) {
      pt.note('watcher-error', String(err && err.stack), null, true);
    }
    pt.watchMs += performance.now() - t0; // the watcher's own cost (DOM reads) is not the game's
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
        pt.watchMs = 0;
        pt.parts = {};
        const heap0 = performance.memory ? performance.memory.usedJSHeapSize : 0;
        const t0 = performance.now();
        loop._run(1 / 30, 1 / 30);
        const ms = performance.now() - t0 - pt.watchMs;
        // the heap shrinking by megabytes inside the frame: a garbage collection ran in it
        const gc = !!performance.memory && performance.memory.usedJSHeapSize < heap0 - 4e6;
        const s = pt.sim;
        s.n++;
        s.total += ms;
        if (ms > s.max) s.max = ms;
        if (ms > 50) s.over50++;
        if (ms > 100) {
          s.over100++;
          const top = Object.entries(pt.parts).sort((a, b) => b[1] - a[1]).slice(0, 3).map(([k, v]) => `${k} ${r1(v)}`);
          // a frame the game's own code made long (the parts sum), not a garbage collection or the harness
          const own = Object.values(pt.parts).reduce((a, b) => a + b, 0);
          if (own > 50 && !gc && pt.gameSpikes.length < 20) pt.gameSpikes.push({ ms: r1(own), level: g.level, t: r1(g.env.now()), top });
          if (s.worst.length < 12) s.worst.push({ ms: r1(ms), level: g.level, phase: g.phase, ms2: g.env.moveState(), t: r1(g.env.now()), top, gc });
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
    // what a player sees and steps round (the route knows rooms and doorways, not door leaves or furniture): the
    // direction nearest the route's whose way is clear for the body's width, at the knee and the chest
    if (d.avoid !== false && g.env.mode() === 'OnFoot') {
      const reach = Math.min(3, Math.hypot(w[0] - root.x, w[2] - root.z));
      const feet = root.y - ROOT_ABOVE_FEET;
      const clearAlong = (ux, uz) => {
        for (const side of [-0.85, 0, 0.85]) {
          for (const h of [1.9, 3.8]) {
            const o = new T.Vector3(root.x - uz * side, feet + h, root.z + ux * side);
            if (e.world.raycast(o, new T.Vector3(ux, 0, uz), reach + 0.9, { ignoreEntities: false })) return false;
          }
        }
        return true;
      };
      if (!clearAlong(dx, dz)) {
        const base = Math.atan2(dx, dz);
        for (const deg of [25, -25, 50, -50, 75, -75, 100, -100, 130, -130]) {
          const a = base + (deg * Math.PI) / 180 * (d.side || 1);
          if (clearAlong(Math.sin(a), Math.cos(a))) {
            dx = Math.sin(a);
            dz = Math.cos(a);
            break;
          }
        }
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
        d.side = -(d.side || 1);
        return 'stuck';
      }
    }
    return null;
  };

  /** A floor route on the current level from the player to `to` (the Creature's FloorNav), or null. */
  pt.path = (to, level = g.level || 'Lobby') => {
    const nav = g.creature.c.service._nav(level);
    if (!nav) return null;
    const from = g.env.feetPosition(V());
    const target = new T.Vector3(to[0], to[1], to[2]);
    const res = nav.computePath(from, target);
    if (!res) return null;
    return res.waypoints.map((p) => [p.x, p.y, p.z]);
  };

  /**
   * A route for the player's own body where the floor routes cannot go (up a stair tower): a breadth-first search
   * over 1-stud cells inside `box` ({minX, maxX, minZ, maxZ}), each standing on a floor found by a ray down, with
   * room for the capsule (knee and chest rays) and the head, stepping up at most a stair riser and down at most a
   * short drop, until a cell inside `goal` ({x, z, w, d, y}) at its floor height.
   */
  pt.bodyPath = (box, goal, maxStates = 9000) => {
    const down = new T.Vector3(0, -1, 0);
    const upDir = new T.Vector3(0, 1, 0);
    const floorAt = (x, z, y) => {
      const hit = e.world.raycast(new T.Vector3(x, y + 2.1, z), down, 4.2, { ignoreEntities: false });
      return hit && hit.normal.y > 0.35 ? hit.point.y : null;
    };
    const clear = (x, y, z) => {
      if (e.world.raycast(new T.Vector3(x, y + 0.3, z), upDir, 4.8, { ignoreEntities: false })) return false;
      for (let k = 0; k < 8; k++) {
        const a = (k * Math.PI) / 4;
        const dir = new T.Vector3(Math.sin(a), 0, Math.cos(a));
        for (const h of [1.9, 3.8]) if (e.world.raycast(new T.Vector3(x, y + h, z), dir, 1.05, { ignoreEntities: false })) return false;
      }
      return true;
    };
    const feet = g.env.feetPosition(V());
    const sx = Math.round(feet.x);
    const sz = Math.round(feet.z);
    const sy = floorAt(feet.x, feet.z, feet.y) ?? feet.y;
    const key = (x, z, y) => `${x},${z},${Math.round(y * 2)}`;
    const seen = new Map([[key(sx, sz, sy), null]]);
    const queue = [[sx, sz, sy]];
    let found = null;
    while (queue.length && seen.size < maxStates) {
      const cur = queue.shift();
      const [x, z, y] = cur;
      if (x >= goal.x + 1 && x <= goal.x + goal.w - 1 && z >= goal.z + 1 && z <= goal.z + goal.d - 1 && Math.abs(y - goal.y) < 1.2) {
        found = cur;
        break;
      }
      for (const [dx, dz] of [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]]) {
        const nx = x + dx;
        const nz = z + dz;
        if (nx < box.minX || nx > box.maxX || nz < box.minZ || nz > box.maxZ) continue;
        const ny = floorAt(nx, nz, y);
        if (ny === null || ny - y > 1.6 || y - ny > 3) continue;
        const k = key(nx, nz, ny);
        if (seen.has(k) || !clear(nx, ny, nz)) continue;
        seen.set(k, cur);
        queue.push([nx, nz, ny]);
      }
    }
    if (!found) return null;
    const out = [];
    for (let c = found; c; c = seen.get(key(c[0], c[1], c[2]))) out.unshift([c[0], c[2], c[1]]);
    return out.filter((_, i) => i % 2 === 0 || i === out.length - 1);
  };

  /**
   * A local detour for the body (furniture, door leaves and lab counters the floor routes do not know): the body path
   * to the first route point at least 6 studs on, spliced into the drive. False when there is none.
   */
  pt.detour = () => {
    const d = pt.drive;
    if (!d) return false;
    const root = g.env.rootPosition(V());
    let j = d.i;
    while (j < d.pts.length - 1 && Math.hypot(d.pts[j][0] - root.x, d.pts[j][2] - root.z) < 6) j++;
    const w = d.pts[j];
    const box = { minX: Math.min(root.x, w[0]) - 10, maxX: Math.max(root.x, w[0]) + 10,
      minZ: Math.min(root.z, w[2]) - 10, maxZ: Math.max(root.z, w[2]) + 10 };
    const hit = e.world.raycast(new T.Vector3(w[0], root.y + 2, w[2]), down, 8);
    const gy = hit ? hit.point.y : w[1];
    const local = pt.bodyPath(box, { x: w[0] - 1.6, z: w[2] - 1.6, w: 3.2, d: 3.2, y: gy }, 5000);
    if (!local || local.length < 2) return false;
    d.pts.splice(d.i, j - d.i, ...local.slice(1));
    d.hist.length = 0;
    d.detours = (d.detours || 0) + 1;
    return true;
  };

  /** Up (or down) the stair tower into the current level's entry vestibule, when the player stands below it. */
  pt.stairsIn = () => {
    const sw = (meta.stairwells || []).find((x) => x.to === g.level);
    if (!sw) return null;
    const goalRoom = meta.rooms.find((r) => r.id === sw.toRoom);
    const fromRoom = meta.rooms.find((r) => r.id === sw.fromRoom);
    const tower = (meta.worldConfig.Towers || {})[sw.tower];
    if (!goalRoom || !tower) return null;
    const rects = [goalRoom.rect, fromRoom ? fromRoom.rect : goalRoom.rect,
      { x: tower.minX, z: tower.minZ, w: tower.maxX - tower.minX, d: tower.maxZ - tower.minZ }];
    const box = { minX: Math.min(...rects.map((r) => r.x)) - 1, maxX: Math.max(...rects.map((r) => r.x + r.w)) + 1,
      minZ: Math.min(...rects.map((r) => r.z)) - 1, maxZ: Math.max(...rects.map((r) => r.z + r.d)) + 1 };
    return pt.bodyPath(box, { ...goalRoom.rect, y: goalRoom.floorY });
  };

  pt.go = (pts, opts = {}) => {
    pt.drive = { pts, i: 0, arrive: opts.arrive || 1.5, turnRate: opts.turnRate || 9, hist: [], ticks: 0, pitch: opts.pitch,
      avoidTraps: opts.avoidTraps, avoid: opts.avoid };
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
      loops: e.audio && e.audio.voices ? [...new Set(e.audio.voices.filter((v) => v.looped && v.playing).map((v) => v.name))] : [],
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

/** Grabbed in the pool: mash Space (STRUGGLE) like a player until free (or the run ends). */
async function struggle(D) {
  const held = [...D.held];
  await D.upAll();
  let s = await D.st();
  for (let i = 0; i < 60 && s.ms === 'Grabbed' && s.life === 'Alive'; i++) {
    await D.press('Space', 0.06);
    await D.run(0.06);
    s = await D.st();
  }
  report.coverage.struggles = (report.coverage.struggles || 0) + 1;
  for (const k of held) await D.down(k);
  return s;
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
  await D.G((g, pt, a) => pt.go(a.pts, a.o), { pts, o: { arrive: opts.arrive || 1.6, pitch: opts.pitch, avoidTraps: opts.avoidTraps,
    avoid: opts.avoid } });
  const start = await D.st();
  await D.down('KeyW');
  if (opts.sprint) await D.down('ShiftLeft');
  let stuck = 0;
  let detours = 0;
  let best = Infinity;
  let bestAt = start.now;
  let sprintUntil = -1;
  let crouchUntil = -1;
  let result = { ok: false, reason: 'timeout' };
  try {
    for (;;) {
      const r = await D.run(0.5);
      const s = await D.st();
      if (s.phase !== start.phase || s.life !== start.life || s.level !== start.level) {
        result = { ok: false, reason: `interrupted:${s.phase}:${s.life}:${s.level}` };
        break;
      }
      if (s.ms === 'Grabbed') {
        await struggle(D);
        continue;
      }
      if (s.ms === 'Trapped' && opts.stopOnTrap) {
        result = { ok: true, trapped: true };
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
      if (r.stuck && s.mode === 'Swim') {
        // at a pool edge: climb out (jump), as the swim hint says
        await D.press('Space', 0.5);
        continue;
      }
      // circling without getting nearer (a counter in the way the whiskers keep turning back to): a detour
      const left = Math.hypot(s.root[0] - target[0], s.root[2] - target[2]);
      if (left < best - 1) {
        best = left;
        bestAt = s.now;
      } else if (s.now - bestAt > 8 && detours < 4) {
        bestAt = s.now;
        if (await D.G((g, pt) => pt.detour())) detours++;
      }
      if (r.stuck && detours < 4 && (await D.G((g, pt) => pt.detour()))) {
        detours++;
        continue; // round it: a body route past whatever blocks the way
      }
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
      // the kick is a 130-stud GrateKick noise: a patrolling Creature in earshot must come to look
      const before = await D.G((g) => {
        const svc = g.creature.c.service;
        const snap = svc.snapshot();
        const here = g.env.rootPosition(new g.env.THREE.Vector3());
        return { state: snap.state, awake: snap.awake, ignored: !!svc.ignored, sameLevel: snap.levelId === g.level,
          distance: snap.position ? snap.position.distanceTo(here) : Infinity, canHunt: !!(svc.ctx && svc.ctx.canHunt) };
      });
      await D.press('KeyR', 0.1);
      await D.run(0.6);
      if (before.state === 'Patrol' && before.awake && !before.ignored && before.sameLevel && before.canHunt && before.distance < 110) {
        await D.run(2.4);
        const after = await D.G((g) => g.creature.getState());
        if (!['InvestigateNoise', 'WallChase', 'VentChase'].includes(after)) {
          await D.G((g, pt, a) => pt.note('creature-deaf', a, null, false), { ...before, after });
        }
        log.heard = after;
      }
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
async function exploreFloor(D, level, budget, onRoom, skip) {
  const rooms = (await floorRooms(D, level)).filter((r) => !skip || !skip.has(r.id));
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
    const res = await goTo(D, target, { timeout: 25 });
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
  await goTo(D, trap.at, { arrive: 0.4, random: false, pickups: false, timeout: 60, avoidTraps: false, stopOnTrap: true });
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
  if (!(await D.tab.evaluate(() => !!document.pointerLockElement))) {
    await D.tab.mouse.down();
    await D.tab.mouse.up();
    await D.run(0.2);
  }
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

/** Level 4: into the pool, a dive, across (the pool crossing pass), and out at the far edge; the floodlight switch. */
async function poolMoment(D) {
  // a crossing line: the z where open water runs from one deck to the other (no walkway piece to surface under)
  const lane = await D.G((g) => {
    const T = g.env.THREE;
    const e = window.__rovloc.engine;
    const b = g.world.pools.find((p) => p.id.includes('Basin'));
    if (!b) return null;
    const down = new T.Vector3(0, -1, 0);
    const floorAt = (x, z) => {
      const h = e.world.raycast(new T.Vector3(x, b.surfaceY + 9, z), down, 30);
      return h ? h.point.y : -Infinity;
    };
    let best = null;
    for (let z = b.rect.z + 5; z <= b.rect.z + b.rect.d - 5; z += 2) {
      let west = null;
      let east = null;
      let blocked = false;
      for (let x = b.rect.x - 4; x <= b.rect.x + b.rect.w + 4; x += 1) {
        // open water across the swimmer's width: nothing to climb onto or surface under either side of the line
        const y = Math.max(floorAt(x, z - 2.5), floorAt(x, z), floorAt(x, z + 2.5));
        const water = y < b.surfaceY - 2;
        if (water && west === null) west = x;
        if (!water && west !== null && east === null) east = x;
        if (water && east !== null) blocked = true; // a walkway piece mid-pool
      }
      if (west === null || east === null || blocked) continue;
      const score = Math.abs(z - (b.rect.z + b.rect.d / 2));
      if (!best || score < best.score) best = { z, west, east, score, surface: b.surfaceY };
    }
    return best;
  });
  check('Level 4: a lane of open water across the pool (deck to deck)', !!lane, lane);
  if (!lane) return;
  let walk = await goTo(D, [lane.west - 3, 82, lane.z], { arrive: 1.2, timeout: 70 });
  await D.G((g) => g.env.setLook(-Math.PI / 2, -0.1)); // face east, over the water
  await D.down('KeyW');
  let into = await D.run(3, { until: { ctx: 'Swim' } });
  for (let i = 0; i < 3 && !into.until; i++) {
    await D.press('Space', 0.3); // a lip at the edge: jump in
    into = await D.run(1.5, { until: { ctx: 'Swim' } });
  }
  await D.run(0.4); // the MoveState follows the mode on the next ticks
  let s = await D.st();
  check('Level 4: walking off the deck into the pool swims', ['Treading', 'Freestyle', 'Underwater'].includes(s.ms), { ms: s.ms, walk, root: s.root });
  await D.run(0.6);
  await D.up('KeyW');
  await D.down('KeyC');
  await D.run(2);
  s = await D.st();
  await D.shot('underwater');
  await D.up('KeyC');
  check('Level 4: diving (hold C) goes under', s.ms === 'Underwater', { ms: s.ms });
  await D.run(2);
  // across to the east deck at the surface (freestyle, the Creature's AquaticStalk is slower), and out
  await D.G((g, pt, a) => pt.go([[a.east + 2, 81, a.z]], { arrive: 2.5, pitch: 0, avoid: false }), lane);
  await D.down('KeyW');
  await D.down('ShiftLeft');
  for (let i = 0; i < 40; i++) {
    const r = await D.run(0.5);
    s = await D.st();
    if (s.ms === 'Grabbed') s = await struggle(D);
    if (r.arrived || s.mode === 'OnFoot' || s.life !== 'Alive') break;
    if (r.stuck) await D.press('Space', 0.4); // at the edge: climb
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
  check('Level 4: swimming across and climbing out at the far edge', s.life === 'Alive' && s.mode === 'OnFoot' && s.root[0] >= lane.east - 1,
    { ms: s.ms, root: s.root, life: s.life, lane });
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
  // out across the deck first, well clear of the parapet's gap, then to the crate's far side
  await goTo(D, [crate[0] + 14, crate[1], crate[2] - 14], { arrive: 2, timeout: 40, sprint: true });
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
  check('Level 5: off the gap with a pack: freefall', s.chute === 'Freefall' || s.chute === 'Canopy', { chute: s.chute, root: s.root, walk });
  await D.run(0.4);
  await D.press('Space', 0.1);
  await D.run(1.5);
  s = await D.st();
  check('Level 5: the ripcord (Space) opens the canopy', s.chute === 'Canopy' || s.chute === 'Landed', { chute: s.chute });
  await D.shot('canopy');
  for (let i = 0; i < 24 && !(await D.G((g) => !!g.level5.finale)); i++) await D.run(0.5);
  await finaleLedgeCheck(D);
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

// ---------------------------------------------------------------------------------------------------- phases

/** Title -> walkthrough -> lobby -> a ready pad -> the countdown -> Level 0, all by keyboard and walking. */
async function titleToRun(D, firstTime = true) {
  let s = await D.st();
  check('title screen up', s.onboarding === 'Title', { onboarding: s.onboarding });
  await D.shot('title');
  await uiAudit(D, 'title');
  if (firstTime) await D.G((g) => g.env.setSetting('TutorialDone', false));
  await D.tab.keyboard.press('Enter');
  await D.run(0.5);
  s = await D.st();
  if (s.onboarding === 'Walkthrough') {
    for (let i = 0; i < 7; i++) {
      await uiAudit(D, `walkthrough-${i}`);
      if (i === 2) await D.shot('walkthrough');
      await D.tab.keyboard.press('ArrowRight');
      await D.run(0.3);
    }
    await D.tab.keyboard.press('Enter');
    await D.run(0.8);
  }
  s = await D.st();
  check('in the lobby after the title', s.phase === 'Lobby' && s.onboarding === 'Hidden', { phase: s.phase, onboarding: s.onboarding });
  await D.shot('lobby');
  await uiAudit(D, 'lobby');
  // to the bus's rear step, then aboard onto the nearest pad
  const bus = await D.G((g) => {
    const b = g.lobby.bus;
    const e = b.entrance;
    const pad = g.lobby.pads.map((x) => x.centre).sort((a, c) => Math.hypot(a.x - e.x, a.z - e.z) - Math.hypot(c.x - e.x, c.z - e.z))[0];
    const behind = e.clone().addScaledVector(b.axis, -4);
    return { behind: [behind.x, behind.y, behind.z], entrance: [e.x, e.y, e.z], pad: [pad.x, pad.y, pad.z] };
  });
  // the glowing arrows lead round to the rear step: line up behind it, then up the step along the aisle
  const toBus = await goTo(D, bus.behind, { arrive: 0.8, timeout: 60 });
  check('lobby: walking to the bus (floor route)', toBus.ok, toBus);
  await D.G((g, pt, a) => pt.go([a.entrance, a.pad], { arrive: 0.8, pitch: 0 }), bus);
  await D.down('KeyW');
  await D.run(8, { until: { phase: 'Countdown' } });
  await D.upAll();
  await D.G((g, pt) => pt.stop());
  s = await D.st();
  check('lobby: stepping onto a ready pad starts the countdown', s.phase === 'Countdown', { phase: s.phase, root: s.root });
  await D.shot('countdown');
  await D.run(14, { until: { level: 'Level0_Basement' } });
  await D.run(2.5);
  s = await D.st();
  check('deployed into Level 0', s.phase === 'InRun' && s.level === 'Level0_Basement' && s.life === 'Alive', s);
  await heap(D.tab, 'Level0 start');
}

/** Restarts after a death: the results, Play Again, the pad, Level 0, then the level skip to `level`. */
async function restartAt(D, level) {
  let s = await D.st();
  if (s.phase === 'RunEnded') await D.run(12, { until: { phase: 'Results' } });
  s = await D.st();
  if (s.phase === 'Results') {
    for (let i = 0; i < 20 && !(await D.G((g) => g.results.showing && g.results.alpha > 0.9)); i++) await D.run(0.5);
    await D.shot('results');
    await uiAudit(D, 'results');
    await D.tab.keyboard.press('Enter');
    await D.run(1.5);
    s = await D.st();
    check('Play Again (Enter on the results): back in the lobby, ready, the countdown running', s.phase === 'Countdown', { phase: s.phase });
  }
  if (s.phase === 'Lobby') {
    await D.press('KeyR', 0.1); // "Step onto a pad on the bus to ready up, or press R"
    await D.run(0.5);
    s = await D.st();
  }
  if (s.phase !== 'Countdown') {
    check(`restart: a countdown after the run ended (${s.phase})`, false, s);
    return false;
  }
  await D.run(16, { until: { level: 'Level0_Basement' } });
  await D.run(2);
  s = await D.st();
  check('Play Again: the next run deploys', s.phase === 'InRun' && s.level === 'Level0_Basement' && s.health === 100, s);
  if (level !== 'Level0_Basement') {
    await D.G((g, pt, lv) => pt.dev.gotoLevel(lv), level);
    await D.run(1.5);
  }
  return true;
}

/** The DOM audit: visible UI off screen, overflowing text, overlapping prompt rows (screens and panels). */
async function uiAudit(D, label) {
  const bad = await D.tab.evaluate(() => {
    const out = [];
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const root = document.getElementById('rv-root') || document.body;
    for (const el of root.querySelectorAll('*')) {
      if (el.tagName === 'CANVAS' || el.closest('svg')) continue;
      const cs = getComputedStyle(el);
      if (cs.display === 'none' || cs.visibility === 'hidden') continue;
      let o = 1;
      for (let p = el; p && p !== document.body; p = p.parentElement) o *= Number(getComputedStyle(p).opacity);
      if (o < 0.2) continue;
      const r = el.getBoundingClientRect();
      if (r.width < 2 || r.height < 2) continue;
      const text = (el.childNodes.length === 1 && el.firstChild.nodeType === 3) ? el.textContent.trim() : '';
      if (!text) continue;
      if (r.left < -2 || r.top < -2 || r.right > vw + 2 || r.bottom > vh + 2) out.push({ issue: 'off-screen', text: text.slice(0, 60), r: [r.left, r.top, r.right, r.bottom].map(Math.round) });
      if (el.scrollWidth > el.clientWidth + 3 && cs.overflowX !== 'visible' && el.clientWidth > 0) out.push({ issue: 'text-clipped', text: text.slice(0, 60) });
    }
    return out.slice(0, 10);
  });
  for (const b of bad) await D.G((g, pt, a) => pt.note(`ui-${a.b.issue}`, { ...a.b, screen: a.label }), { b, label });
  return bad;
}

async function phaseRun(D) {
  const budget = FLOOR_SECONDS;
  const ignore = (on) => D.G((g, pt, v) => {
    const svc = g.creature.c.service;
    if (!!svc.ignored !== v && svc.running) g.creature.devCommand('ignoreme');
    return !!svc.ignored;
  }, on);
  if (START && START !== 'Level0_Basement') {
    await D.G((g, pt, lv) => pt.dev.gotoLevel(lv), START);
    await D.run(1.5);
  }
  let level = (await D.st()).level;
  const startIdx = Math.max(0, LEVELS.indexOf(level));
  for (let li = startIdx; li < LEVELS.length; li++) {
    level = LEVELS[li];
    let s = await D.st();
    const natural = s.level === level && s.phase === 'InRun' && s.life === 'Alive';
    if (!natural && !(await restartAt(D, level))) return;
    s = await D.st();
    await ignore(false);
    console.log(`---- ${level} (${s.zone}, entered ${natural ? 'naturally' : 'by the level skip'})`);
    report.coverage[level] = { ...(report.coverage[level] || {}), natural };
    // a natural arrival stands at the foot of the stair tower: up the stairs into the floor's entry vestibule
    const below = await D.G((g, pt) => {
      const sw = (g.env.meta.stairwells || []).find((x) => x.to === g.level);
      const room = sw && g.env.meta.rooms.find((r) => r.id === sw.toRoom);
      return room ? g.env.feetPosition(new g.env.THREE.Vector3()).y < room.floorY - 2 : false;
    });
    if (below) {
      const pts = await D.G((g, pt) => pt.stairsIn());
      const climb = pts ? await goTo(D, pts[pts.length - 1], { pts, arrive: 1.2, random: false, avoid: false, timeout: 60, pickups: false }) : { ok: false, reason: 'no stair route' };
      const after = await D.st();
      check(`${level}: up the stair tower into the floor`, climb.ok, { climb, root: after.root, zone: after.zone, steps: pts && pts.length });
    }
    await D.G((g) => g.env.setFlashlight(true));
    await D.shot(`${level}-start`);
    await uiAudit(D, level);
    if (level === 'Level0_Basement') await trapMoment(D);
    if (level === 'Level5_Roof') {
      await D.run(2);
      await roofMoment(D);
      await heap(D.tab, 'results');
      break;
    }
    // the sweep; a death mid-floor restarts the run here and finishes the sweep with the Creature ignoring the player
    let cov = await exploreFloor(D, level, budget);
    s = await D.st();
    if (s.life !== 'Alive' || s.level !== level) {
      const c = (await D.G((g, pt) => pt.catches)).slice(-1)[0];
      console.log(`     ${level}: the run ended (${s.life}, ${s.phase}) — last catch ${JSON.stringify(c)}`);
      report.coverage[level].died = c || s.life;
      await D.shot(`${level}-ended`);
      if (!(await restartAt(D, level))) return;
      await ignore(true);
      await D.G((g) => g.env.setFlashlight(true));
      const visited = new Set(cov.visited);
      const more = await exploreFloor(D, level, budget, null, visited);
      cov = { ...more, visited: [...cov.visited, ...more.visited] };
      report.coverage[level].explore = cov;
    }
    s = await D.st();
    if (s.life === 'Alive' && s.level === level) {
      if (level === 'Level2_ScienceHall') await flaskMoment(D);
      if (level === 'Level3_Gymnasium') await lockerMoment(D);
      if (level === 'Level4_FloodedPool') await poolMoment(D);
    }
    s = await D.st();
    if (s.life !== 'Alive' || s.level !== level) continue;
    const left = await leaveFloor(D, level);
    check(`${level}: left by its exit airlock`, left.ok, left);
    await heap(D.tab, `${level} done`);
    if (!left.ok) {
      const t = await D.st();
      if (t.life === 'Alive' && t.level === level) {
        // a softlock (or the route failing): the next floor by the level skip
        await D.shot(`${level}-no-exit`);
        await D.G((g, pt, lv) => pt.dev.gotoLevel(lv), LEVELS[li + 1]);
        await D.run(1.5);
      }
    }
  }
  await ignore(false);
  // the second run: Play Again from the results
  const s = await D.st();
  if (s.phase === 'Results' || s.phase === 'RunEnded') {
    await restartAt(D, 'Level0_Basement');
    await heap(D.tab, 'second run Level0');
  }
}

/** Escape pauses and resumes; a lost pointer lock opens the menu; a blur releases held keys. */
async function phasePause(D) {
  let s = await D.st();
  if (s.phase !== 'InRun' || s.life !== 'Alive') return check('pause: needs a live run', false, s);
  const t0 = s.now;
  await D.tab.keyboard.press('Escape');
  await D.run(1.5);
  s = await D.st();
  check('pause: Escape opens the menu and stops the clock', s.menu && s.now - t0 < 0.1, { menu: s.menu, advanced: s.now - t0 });
  await D.shot('pause-menu');
  await uiAudit(D, 'pause menu');
  await D.tab.keyboard.press('Escape');
  await D.run(1);
  s = await D.st();
  check('pause: Escape again resumes', !s.menu && s.now - t0 > 0.8, { menu: s.menu });
  // the pointer lock lost mid-run (Alt+Tab, a notification): the menu opens, keys held are let go
  await D.tab.mouse.click(640, 360);
  await D.run(0.2);
  const locked = await D.tab.evaluate(() => !!document.pointerLockElement);
  await D.down('KeyW');
  await D.run(0.3);
  await D.tab.evaluate(() => document.exitPointerLock());
  await D.tab.waitForTimeout(50);
  await D.run(0.5);
  s = await D.st();
  const moving = await D.G((g) => g.env.moveVector().y);
  check('pause: losing the pointer lock opens the menu', locked && s.menu, { locked, menu: s.menu });
  await D.up('KeyW');
  // the menu's Resume (the button) and the lock coming back with the next click
  const resumed = await D.tab.evaluate(() => {
    const b = [...document.querySelectorAll('button')].find((x) => /resume/i.test(x.textContent) && x.offsetParent);
    if (b) b.click();
    return !!b;
  });
  await D.run(0.5);
  await D.tab.mouse.click(640, 360);
  await D.run(0.3);
  s = await D.st();
  const relocked = await D.tab.evaluate(() => !!document.pointerLockElement);
  check('pause: Resume closes the menu and a click locks the pointer again', resumed && !s.menu && relocked, { resumed, menu: s.menu, relocked, heldMove: moving });
  // a blur (switching windows) with W held: the key is released, the player stops
  await D.down('KeyW');
  await D.run(0.3);
  await D.tab.evaluate(() => window.dispatchEvent(new Event('blur')));
  await D.run(0.4);
  const mv = await D.G((g) => g.env.moveVector());
  await D.up('KeyW');
  check('pause: a window blur lets go of held keys', mv.y === 0 && mv.x === 0, mv);
  await D.run(0.5);
  s = await D.st();
  if (s.menu) await D.tab.keyboard.press('Escape');
  await D.run(0.3);
}

/** Settings survive a reload; a corrupted save boots clean. */
async function phaseSave(context) {
  let { tab, logs } = await openGame(context);
  let D = makeDriver(tab, 'save');
  await D.G((g) => {
    g.env.setSetting('MouseSensitivity', 1.75);
    g.env.setSetting('Captions', true);
    g.env.saveFlush();
  });
  const keys = await tab.evaluate(() => Object.keys(localStorage));
  await tab.reload();
  await tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 240000 });
  await tab.evaluate(pageLib);
  await tab.evaluate(() => window.__rovloc.engine.loop.stop());
  D = makeDriver(tab, 'save');
  const back = await D.G((g) => ({ sens: g.env.setting('MouseSensitivity'), captions: g.env.setting('Captions') }));
  check('save: settings survive a reload', back.sens === 1.75 && back.captions === true, { back, keys });
  // corrupt the saved blob from another page of the same file:// origin (the game page flushes its own copy on the
  // way out, so it has to be gone first), then load the game on it
  const blank = path.join(shots, 'blank.html');
  fs.writeFileSync(blank, '<!doctype html><title>blank</title>');
  await tab.goto(`file://${blank}`);
  await tab.evaluate(() => {
    for (const k of Object.keys(localStorage)) localStorage.setItem(k, '{"broken": [1, 2,');
  });
  await tab.goto(`file://${page}`);
  await tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 240000 });
  const err = await tab.evaluate(() => window.__rovloc.error);
  await tab.evaluate(pageLib);
  D = makeDriver(tab, 'save');
  const fresh = await D.G((g) => ({ sens: g.env.setting('MouseSensitivity'), onboarding: g.onboarding.mode }));
  check('save: a corrupted save still boots to the title with defaults', !err && fresh.onboarding === 'Title' && fresh.sens === 1, { err, fresh });
  report.console.push(...logs.map((l) => `[save] ${l}`));
  await tab.close();
}

/** A touch screen: the controls exist, sit on screen without overlapping, and move the player. */
async function phaseTouch() {
  const context = await browser.newContext({ viewport: { width: 1024, height: 600 }, hasTouch: true, isMobile: true, deviceScaleFactor: 1 });
  const { tab, logs } = await openGame(context);
  const D = makeDriver(tab, 'touch');
  const device = await D.G((g) => g.env.device());
  check('touch: a coarse pointer starts on the Touch device', device === 'Touch', device);
  await D.G((g, pt) => { g.env.setSetting('TutorialDone', true); });
  // PLAY by tapping the title's primary button
  const tapped = await tab.evaluate(() => {
    const b = [...document.querySelectorAll('button')].find((x) => x.offsetParent && /play/i.test(x.textContent));
    if (!b) return null;
    const r = b.getBoundingClientRect();
    return [r.left + r.width / 2, r.top + r.height / 2];
  });
  if (tapped) await tab.touchscreen.tap(tapped[0], tapped[1]);
  await D.run(1);
  let s = await D.st();
  check('touch: tapping PLAY reaches the lobby', s.phase === 'Lobby' && s.onboarding === 'Hidden', { tapped, onboarding: s.onboarding });
  const layout = async (label) => {
    const r = await tab.evaluate(() => {
      const root = window.__rovloc.engine.input.touchRoot;
      if (!root || root.style.display === 'none') return { shown: false, items: [] };
      const items = [...root.children].map((c) => {
        const b = c.getBoundingClientRect();
        return { label: c.textContent || 'stick', l: b.left, t: b.top, r: b.right, b: b.bottom };
      });
      return { shown: true, items };
    });
    const overlaps = [];
    for (let i = 0; i < r.items.length; i++) {
      for (let j = i + 1; j < r.items.length; j++) {
        const a = r.items[i];
        const b = r.items[j];
        const ox = Math.min(a.r, b.r) - Math.max(a.l, b.l);
        const oy = Math.min(a.b, b.b) - Math.max(a.t, b.t);
        if (ox > 2 && oy > 2) overlaps.push(`${a.label}/${b.label}`);
      }
    }
    const off = r.items.filter((x) => x.l < 0 || x.t < 0 || x.r > 1024 || x.b > 600).map((x) => x.label);
    check(`touch: ${label} controls on screen, none overlapping`, r.shown && r.items.length > 1 && !overlaps.length && !off.length,
      { buttons: r.items.map((x) => x.label), overlaps, off });
    return r;
  };
  await layout('lobby');
  await D.shot('touch-lobby');
  // the thumbstick pushed up walks forward
  const stick = await tab.evaluate(() => {
    const b = document.querySelector('.rv-thumb').getBoundingClientRect();
    return [b.left + b.width / 2, b.top + b.height / 2];
  });
  const cdp = await context.newCDPSession(tab);
  const touch = (type, x, y) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y, id: 1 }] });
  const before = (await D.st()).root;
  await touch('touchStart', stick[0], stick[1]);
  await touch('touchMove', stick[0], stick[1] - 50);
  await D.run(1.2);
  await touch('touchEnd');
  await D.run(0.4);
  const after = (await D.st()).root;
  const moved = Math.hypot(after[0] - before[0], after[2] - before[2]);
  const mv = await D.G((g) => g.env.moveVector());
  check('touch: the thumbstick walks the player and lets go on release', moved > 4 && mv.x === 0 && mv.y === 0, { moved, mv });
  // into a run (the natural route was played on the keyboard): the run's context buttons, a locker's LEAVE
  await D.G((g, pt) => {
    pt.dev.deploy(); // not awaited: its fades resolve on frames, and the loop only runs when stepped
    return true;
  });
  await D.run(14, { until: { level: 'Level0_Basement' } });
  await D.run(2);
  await layout('in-run (on foot)');
  await D.shot('touch-run');
  await D.G((g, pt) => pt.dev.gotoLevel('Level3_Gymnasium'));
  await D.run(1);
  await D.G((g, pt) => g.creature.devCommand('ignoreme'));
  const hid = await D.G((g, pt) => {
    const l = g.world.entities('Locker', g.level).find((e) => g.lockers.lockers && true) || g.world.entities('Locker', g.level)[0];
    const T = g.env.THREE;
    const p = g.world.attachmentPos(l.id, 'ExitAnchor');
    g.env.teleport({ position: new T.Vector3(p.x, p.y + 3, p.z), yaw: 0 });
    const piv = new T.Vector3().fromArray(l.pivot);
    g.env.setLook(Math.atan2(-(piv.x - p.x), -(piv.z - p.z)), -0.1);
    return l.id;
  });
  await D.run(0.5);
  // the Hide prompt row pressed by touch
  const row = await tab.evaluate(() => {
    for (const v of window.__rovloc.engine.ui.promptRows.values()) {
      if (Number(v.frame.style.opacity) > 0.5) {
        const r = v.frame.getBoundingClientRect();
        return { text: v.text, at: [r.left + r.width / 2, r.top + r.height / 2] };
      }
    }
    return null;
  });
  if (row) {
    await touch('touchStart', row.at[0], row.at[1]);
    await D.run(0.6);
    await touch('touchEnd');
  }
  await D.run(2);
  s = await D.st();
  check('touch: pressing the Hide prompt row hides in a locker', s.ms === 'Hiding', { row, ms: s.ms, locker: hid });
  await layout('locker');
  await D.shot('touch-locker');
  const leave = await tab.evaluate(() => {
    const b = [...document.querySelectorAll('button, div')].find((x) => x.offsetParent && /^leave$/i.test(x.textContent.trim()));
    if (!b) return null;
    const r = b.getBoundingClientRect();
    return [r.left + r.width / 2, r.top + r.height / 2];
  });
  if (leave) {
    await touch('touchStart', leave[0], leave[1]);
    await D.run(0.2);
    await touch('touchEnd');
    // a tap also arrives as a click on some browsers
    await D.run(2);
  }
  s = await D.st();
  check('touch: the LEAVE button steps out of the locker', !!leave && s.ms !== 'Hiding' && s.ctx === 'OnFoot', { leave, ms: s.ms, ctx: s.ctx });
  report.console.push(...logs.map((l) => `[touch] ${l}`));
  await context.close();
}

/** A gamepad (faked through navigator.getGamepads): the stick moves, unplugging with a button held lets it go. */
async function phaseGamepad() {
  const context = await browser.newContext({ viewport: { width: 1280, height: 720 } });
  const { tab, logs } = await openGame(context);
  const D = makeDriver(tab, 'pad');
  await D.G((g, pt) => {
    g.env.setSetting('TutorialDone', true);
    g.onboarding.pressPlay();
  });
  await D.run(1);
  await tab.evaluate(() => {
    const button = () => ({ pressed: false, touched: false, value: 0 });
    window.__fakePad = { id: 'Fake pad (STANDARD GAMEPAD)', index: 0, connected: true, mapping: 'standard', timestamp: 0,
      axes: [0, 0, 0, 0], buttons: Array.from({ length: 17 }, button) };
    window.dispatchEvent(new Event('gamepadconnected'));
  });
  await D.run(0.3);
  const device = await D.G((g) => g.env.device());
  const before = (await D.st()).root;
  await tab.evaluate(() => { window.__fakePad.axes[1] = -1; });
  await D.run(1.2);
  await tab.evaluate(() => { window.__fakePad.axes[1] = 0; });
  await D.run(0.3);
  const after = (await D.st()).root;
  const moved = Math.hypot(after[0] - before[0], after[2] - before[2]);
  check('gamepad: the device switches and the left stick walks', device === 'Gamepad' && moved > 4, { device, moved });
  // sprint held (L3) and the pad unplugged: the sprint must not stay held
  await tab.evaluate(() => { window.__fakePad.buttons[10] = { pressed: true, touched: true, value: 1 }; });
  await D.run(0.3);
  const heldBefore = await D.G((g) => window.__rovloc.engine.input.isHeld('Sprint'));
  await tab.evaluate(() => {
    window.__fakePad = null;
    window.dispatchEvent(new Event('gamepaddisconnected'));
  });
  await D.run(0.3);
  const heldAfter = await D.G((g) => window.__rovloc.engine.input.isHeld('Sprint'));
  check('gamepad: unplugging it with a button held lets the button go', heldBefore && !heldAfter, { heldBefore, heldAfter });
  report.console.push(...logs.map((l) => `[gamepad] ${l}`));
  await context.close();
}

// ---------------------------------------------------------------------------------------------------- main

const mainContext = await browser.newContext({ viewport: { width: 1280, height: 720 } });
let main = null;
try {
  if (phases.has('title') || phases.has('run') || phases.has('pause')) {
    main = await openGame(mainContext);
    const D = makeDriver(main.tab, 'run');
    await heap(main.tab, 'title');
    await titleToRun(D);
    if (phases.has('pause')) await phasePause(D);
    if (phases.has('run')) await phaseRun(D);
  }
} catch (err) {
  check('the run phases completed', false, String(err && err.stack ? err.stack : err));
  if (main) {
    try {
      const D = makeDriver(main.tab, 'run');
      await D.shot('failure');
    } catch { /* gone */ }
  }
}
if (main) {
  const pt = await main.tab.evaluate(() => ({ anomalies: window.__pt.anomalies, sim: window.__pt.sim, catches: window.__pt.catches,
    gameSpikes: window.__pt.gameSpikes,
    events: window.__pt.events.slice(-60), voicesMax: window.__pt.voicesMax }));
  report.anomalies.push(...pt.anomalies);
  report.perf.sim = { frames: pt.sim.n, avgMs: +(pt.sim.total / Math.max(1, pt.sim.n)).toFixed(2), maxMs: +pt.sim.max.toFixed(1),
    over50: pt.sim.over50, over100: pt.sim.over100, worst: pt.sim.worst, gameSpikes: pt.gameSpikes };
  report.catches = pt.catches;
  report.creatureEvents = pt.events;
  report.perf.voicesMax = pt.voicesMax;
  report.console.push(...main.logs);
}
for (const [name, fn] of [['save', () => phaseSave(mainContext)], ['touch', phaseTouch], ['gamepad', phaseGamepad]]) {
  if (!phases.has(name)) continue;
  try {
    await fn();
  } catch (err) {
    check(`the ${name} phase completed`, false, String(err && err.stack ? err.stack : err));
  }
}

// ---------------------------------------------------------------------------------------------------- the verdict

const fatal = report.anomalies.filter((a) => a.fatal);
for (const a of report.anomalies) console.log(`  anomaly ${a.fatal ? '[fatal] ' : ''}${a.kind} ${a.level || a.phase} at ${a.at.join(',')} t=${a.t} ${a.ms}/${a.ctx} ${JSON.stringify(a.detail)}`);
check('no fatal anomalies (NaN, falling out, in a wall, floating Creature, catch through a wall, wrong hint)', fatal.length === 0,
  fatal.map((a) => `${a.kind}@${a.level}`));
const errors = report.console.filter((l) => /error|pageerror|\[game\]|TypeError|ReferenceError/i.test(l));
check('no console errors or page errors', errors.length === 0, errors.slice(0, 8));
const warnings = report.console.filter((l) => !errors.includes(l));
check('no console warnings', warnings.length === 0, warnings.slice(0, 8));
if (report.memory.length > 2) {
  const first = report.memory.find((m) => m.label === 'Level0 start');
  const last = report.memory[report.memory.length - 1];
  if (first && last && first.heapMB && last.heapMB) {
    check('heap growth across the run stays under 60 MB', last.heapMB - first.heapMB < 60, { from: first.heapMB, to: last.heapMB });
  }
  const prompts = report.memory.map((m) => m.prompts);
  check('prompts do not pile up across levels and runs', Math.max(...prompts) < 400, prompts);
}
if (report.perf.sim) {
  // the frame time the game's own systems spent (rendering skipped); a long frame none of them explains is a garbage
  // collection or the harness, reported but not failed
  check('no frame where the game\'s own code spends over 50 ms (CPU, rendering skipped)', report.perf.sim.gameSpikes.length === 0,
    { gameSpikes: report.perf.sim.gameSpikes, longFramesUnattributed: report.perf.sim.over100 });
}
console.log(`coverage: ${JSON.stringify(Object.fromEntries(Object.entries(report.coverage).map(([k, v]) =>
  [k, v.explore ? `${v.explore.visited.length}/${v.explore.rooms} rooms, failed ${v.explore.failed.length}` : v])))}`);
fs.writeFileSync(path.join(shots, 'report.json'), JSON.stringify(report, null, 2));
console.log(`report: ${path.join(shots, 'report.json')}\nscreenshots: ${report.shots.length} in ${shots}`);
await browser.close();
console.log(failures.length ? `\n${failures.length} FAILED: ${failures.join(', ')}` : '\nall checks passed');
process.exit(failures.length ? 1 : 0);
