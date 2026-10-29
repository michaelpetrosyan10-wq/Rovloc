// objective-run.mjs: the floor objectives played through, lobby to landing, with the pre-installed Playwright Chromium.
//
//   node tools/objective-run.mjs [--seeds 1029,4242] [--html <page>] [--no-build] [--shots <dir>]
//
// For every seed (a fresh page with ?dev&seed=N, so the run's picks, plan, routes and Creature start come from it):
// the lobby's ready pad (real keys), the countdown, the deploy; then every floor's objective with real input and the
// prompts' real holds (E / R held for each hold, Throw held and let go, C to dive, Space to struggle and to pull the
// cord). The harness may teleport the player next to a step's spot within a floor (a clear spot within reach, facing
// it, never on an armed trap); every gate is the game's own logic. The Creature is told to ignore the player
// ("ignoreme") so a hunt cannot end the run; its start rule and grace are still checked:
//   every floor  the exit is locked before (its door Locked, the airlock idle) and open after; walking at the locked
//                basement door does not get you through; the tracker shows the title and steps, then the stairwell.
//   Level 0      three fuses taken, fitted one slot at a time, the breaker thrown (loud), the basement lights back.
//   Level 1      the scare and the gate; the keys past it; the 4 s unlock with its Normal noise every second.
//   Level 2      the Creature's start (70-140 studs walking from the entry, out of its sight, not in an objective room,
//                held until its grace ends or a loud noise of yours); three reagents; the mix let go half way keeps
//                its progress; a missed acid throw loses only the flask (the hood brews another); the chain burnt by a
//                throw (first seed) or by the pour (second seed).
//   Level 3      the start rule again; an empty locker searched (the Hide prompt still there), the key's locker; the
//                store unlocked; the generator's Critical noise; the 45 s countdown and the exit unlocking after it.
//   Level 4      the grate under the hatch blocked; a dive for the wheel (the oxygen drains); a grab while carrying it
//                keeps it; fitted, turned half way (kept) and done: the hatch open, the grate usable.
//   Level 5      the packs chained; the cutters; the cut (the door smash brought forward while the Creature waits);
//                a pack, the jump, the cord, the landing, ESCAPED.
//   Routes       each seed's random exits are logged (North / Middle / South per floor); every stairwell off the
//                route is jammed (its doors shut and Locked at both ends, the debris shown, the "collapsed" prompt,
//                walking at it does not get you through) and stays so all run (checked on every floor); the route's
//                doors show no debris; every arrival spawns in the route's entry vestibule; the roof's finale plays at
//                the arrival housing (its own roof door smashed, the Creature behind it), corner housings included.
// Screenshots (the first seed only): the tracker on each floor, the breaker panel before and after power, the fume
// hood, the chain burning, the generator, the valve seated, the crate's chain cut. Exit code 1 on any failure.

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
const SEEDS = opt('--seeds', '1029,4242').split(',').map(Number);
const shots = path.resolve(opt('--shots', path.join(web, 'build/cache/objective-shots')));
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
  const roots = [web, process.cwd(), '/opt/node-tools/node_modules'];
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

const { chromium } = loadPlaywright();
const failures = [];
const IGNORED_CONSOLE = /useProgram|Shader Error|WebGL|GPU stall|AudioContext/;
const shotsTaken = [];
const routeLog = [];
let seedTag = '';

function check(name, ok, detail) {
  const full = `[seed ${seedTag}] ${name}`;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${full}${detail !== undefined ? ` ${JSON.stringify(detail)}` : ''}`);
  if (!ok) failures.push(full);
}

const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader',
  '--ignore-gpu-blocklist', '--autoplay-policy=no-user-gesture-required', '--enable-webgl'] });

for (const [si, seed] of SEEDS.entries()) {
  seedTag = String(seed);
  const first = si === 0;
  const logs = [];
  const tab = await browser.newPage({ viewport: { width: 1280, height: 720 } });
  await tab.addInitScript(() => {
    Element.prototype.requestPointerLock = function requestPointerLock() {
      return Promise.resolve();
    };
  });
  tab.on('console', (m) => {
    if ((m.type() === 'error' || m.type() === 'warning') && !IGNORED_CONSOLE.test(m.text())) logs.push(`${m.type()}: ${m.text()}`);
  });
  tab.on('pageerror', (e) => logs.push(`pageerror: ${e.message}\n${e.stack}`));

  const G = (fn, arg) => tab.evaluate(([src, a]) => {
    const w = window.__rovlocGame;
    // eslint-disable-next-line no-new-func
    return new Function('game', 'dev', 'arg', `return (${src})(game, dev, arg);`)(w.game, w.dev, a);
  }, [fn.toString(), arg]);
  const ff = (seconds) => tab.evaluate((s) => {
    const e = window.__rovloc.engine;
    const loop = e.loop;
    loop.stop();
    const render = e.renderer.render;
    e.renderer.render = () => {};
    try {
      for (let i = 0; i < Math.round(s * 30); i++) loop._run(1 / 30, 1 / 30);
    } finally {
      e.renderer.render = render;
      loop.start();
    }
  }, seconds);
  const shot = async (name) => {
    if (!first) return;
    await tab.evaluate(() => {
      const loop = window.__rovloc.engine.loop;
      loop.stop();
      loop._run(0, 0);
    });
    await tab.waitForTimeout(250);
    const file = path.join(shots, name);
    try {
      await tab.screenshot({ path: file, timeout: 180000 });
    } finally {
      await tab.evaluate(() => window.__rovloc.engine.loop.start());
    }
    shotsTaken.push(file);
  };
  /** Holds a key for `seconds` of game time. */
  const hold = async (seconds, key = 'KeyE') => {
    await tab.keyboard.down(key);
    await ff(seconds);
    await tab.keyboard.up(key);
    await ff(0.1);
  };
  /**
   * Stands the player within reach of a world point, facing it: spots `reach` studs off it on sixteen bearings, on the
   * surface found under them (or at `y`, a pool's water), with headroom, no wall within a body's width, a clear line to
   * the point and no armed trap within 2.5 studs. Each spot is tried in turn (teleport, settle, aim again) until the
   * prompt answering `action` matches `expect`; without `expect` the first spot that settles is kept.
   */
  const standAt = async (point, opts = {}) => {
    const spots = await G((g, dev, a) => {
      const T = g.env.THREE;
      const p = new T.Vector3(...a.point);
      const traps = g.traps.traps.filter((t) => t.state === 'Armed' && t.level === g.level);
      const out = [];
      const home = g.world.roomAt(p, g.level);
      for (const reach of a.reach) {
        for (let i = 0; i < 16; i++) {
          const ang = (i / 16) * Math.PI * 2;
          const x = p.x + Math.sin(ang) * reach;
          const z = p.z + Math.cos(ang) * reach;
          let root;
          if (a.y !== null) root = new T.Vector3(x, a.y, z);
          else {
            const down = g.env.raycast(new T.Vector3(x, p.y + 1.5, z), new T.Vector3(0, -1, 0), 9, { ignoreEntities: false });
            if (!down || down.normal.y < 0.7) continue;
            root = new T.Vector3(x, down.point.y + 3.05, z);
            if (g.env.raycast(root, new T.Vector3(0, 1, 0), 2.6, { ignoreEntities: false })) continue;
          }
          if (traps.some((t) => Math.hypot(t.floor.x - root.x, t.floor.z - root.z) < 2.5)) continue;
          let blocked = false;
          for (const [dx, dz] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
            if (g.env.raycast(root, new T.Vector3(dx, 0, dz), 1.0, { ignoreEntities: false })) blocked = true;
          }
          if (blocked) continue;
          if (!g.env.lineClear(root.clone().add(new T.Vector3(0, 1.5, 0)), p, { ignoreEntities: false })) continue;
          const here = g.world.roomAt(root, g.level);
          out.push({ at: root.toArray(), same: !!home && !!here && here.id === home.id });
        }
      }
      return out.sort((a, b) => Number(b.same) - Number(a.same)).map((s) => s.at);
    }, { point, reach: opts.reach || [2.2, 3, 1.6, 4], y: opts.y ?? null });
    const aim = () => G((g, dev, q) => {
      const eye = g.env.eye();
      const d = { x: q[0] - eye.x, y: q[1] - eye.y, z: q[2] - eye.z };
      g.env.setLook(Math.atan2(-d.x, -d.z), Math.atan2(d.y, Math.hypot(d.x, d.z)));
    }, point);
    for (const spot of spots.slice(0, 12)) {
      await G((g, dev, r) => {
        g.env.teleport({ position: { x: r[0], y: r[1], z: r[2] }, yaw: 0 });
        g.traps.noteTeleport();
      }, spot);
      await aim();
      await ff(0.35);
      await aim();
      await ff(0.1);
      if (!opts.expect) return { ok: true, at: spot };
      const pr = await active(opts.action || 'Interact');
      if (pr && opts.expect.test(`${pr.text} ${pr.object}`)) return { ok: true, at: spot, prompt: pr };
    }
    return { ok: false, spots: spots.length };
  };
  /** The prompt answering Interact / Kick now: {text, object} or null. */
  const active = (action = 'Interact') => tab.evaluate((act) => {
    const p = window.__rovloc.engine.prompts.active.get(act);
    return p ? { text: p.text, object: p.objectText, hold: p.hold } : null;
  }, action);
  /** A point of an entity attachment (current pose). */
  const at = (id, att) => G((g, dev, a) => {
    const m = a.att ? g.env.attachmentWorld(a.id, a.att) : null;
    const T = g.env.THREE;
    return (m ? new T.Vector3().setFromMatrixPosition(m) : new T.Vector3().setFromMatrixPosition(g.env.entity(a.id).pivot)).toArray();
  }, { id, att });
  const floorOf = () => G((g) => {
    const f = g.floors.floor(g.level);
    return { level: g.level, unlocked: f.unlocked, steps: Object.fromEntries(f.spec.steps.map((s) => [s.id, f.count(s.id)])),
      carry: Object.fromEntries(g.floors.carry.items), door: f.route ? g.doors.get(f.route.exitDoorIds[0]).state : null,
      airlock: g.airlock.phase, tracker: g.objectives.scan.title, life: g.life.state };
  });
  const tracker = () => G((g) => ({ title: g.objectives.scan.title, steps: (g.objectives.scan.steps || []).map((s) => s.text) }));
  /** Walks into the floor's exit vestibule from the floor side and waits for the next level. */
  const leave = async (next) => {
    await jamCheck(`leaving ${await G((g) => g.level)}`);
    const entryRoom = await G((g) => g.route(g.level).entryRoomOfNextLevel);
    await G((g) => {
      const T = g.env.THREE;
      const route = g.route(g.level);
      const door = g.doors.get(route.exitDoorIds[0]);
      const v = route.checkpointVolumes[0];
      const c = new T.Vector3(v.cframe[0], door.centre.y, v.cframe[2]);
      const dir = c.clone().sub(door.centre).setY(0).normalize();
      const start = door.centre.clone().addScaledVector(dir, -5);
      const room = g.world.roomAt(start, g.level);
      start.y = (room ? room.floorY : door.centre.y - 5) + 3;
      const yaw = Math.atan2(-dir.x, -dir.z);
      g.env.teleport({ position: start, yaw });
      g.env.setLook(yaw, 0);
      g.traps.noteTeleport();
    });
    await tab.keyboard.down('KeyW');
    await ff(1.8);
    await tab.keyboard.up('KeyW');
    await ff(6);
    const s = await G((g) => ({ level: g.level, phase: g.phase, root: g.env.rootPosition().toArray().map(Math.round),
      airlock: g.airlock.phase, inside: g.airlock.isInside(), creature: (g.creature.position() || { toArray: () => [] }).toArray().map(Math.round) }));
    check(`left by the airlock into ${next}`, s.level === next && s.phase === 'InRun', s);
    const arrived = await G((g, dev, room) => ({ room, inRoom: g.world.inRoom(room, g.env.rootPosition()),
      zone: (g.world.roomAt(g.env.rootPosition(), g.level) || {}).id || null,
      spawn: g.world.spawns(g.level, g.run.routes).map((a) => a.room) }), entryRoom);
    check(`${next}: the arrival spawn is in the route's entry vestibule ${entryRoom}`, arrived.inRoom &&
      arrived.spawn.every((r) => r === entryRoom), arrived);
  };
  const noiseLog = () => G((g) => {
    if (!window.__objNoise) {
      window.__objNoise = [];
      g.env.onNoise((e) => window.__objNoise.push({ kind: e.kind, priority: e.priority, t: g.env.now() }));
    }
    window.__objNoise.length = 0;
  });
  const noises = () => tab.evaluate(() => (window.__objNoise || []).map((n) => n.kind));
  /** Every jammed stairwell door shut and Locked (both ends), its debris shown; the route's doors without debris. */
  const jamCheck = async (where) => {
    const j = await G((g) => {
      const route = new Set(Object.values(g.run.routes).map((r) => r.stairwellId));
      const bad = [];
      let jammed = 0;
      let open = 0;
      for (const d of g.doors.byId.values()) {
        if (!d.stairwellId) continue;
        const node = g.env.entity(d.id).nodes.get('Jam');
        const jam = !!node && !node.hidden;
        if (route.has(d.stairwellId)) {
          open++;
          if (d.jammed || jam) bad.push(`${d.id} on the route: jammed ${d.jammed}, debris ${jam}`);
        } else {
          jammed++;
          if (!d.jammed || d.state !== 'Locked' || d.openness > 1e-3 || g.doors.isMoving(d) || !jam) {
            bad.push(`${d.id}: ${d.state} ${d.openness.toFixed(2)} jammed ${d.jammed} debris ${jam}`);
          }
        }
      }
      return { jammed, open, bad };
    });
    check(`${where}: every off-route stairwell door stays shut and Locked with its debris (${j.jammed}); the route's ${j.open} show none`,
      j.bad.length === 0 && j.jammed === 20 && j.open === 10, j);
  };
  const spawnCheck = async (level, wantReason) => {
    const s = await G((g, dev, lv) => {
      const e = g.floors.spawns.log.filter((x) => x.level === lv).pop();
      return e ? { ...e, state: g.creature.getState(), holding: g.floors.spawns.holding(lv) } : null;
    }, level);
    check(`${level}: the Creature starts 70-140 studs walking from the entry, unseen, outside the objective rooms`,
      !!s && s.walk >= 70 && s.walk <= 140 && !s.visible && !s.inObjectiveRoom && !s.fallback && s.candidates > 0 &&
      s.state === 'Scripted' && s.holding, s);
    if (wantReason === 'Grace') {
      const left = await G((g) => g.floors.spawns.graceUntil - g.env.now());
      await ff(left - 1.5);
      const mid = await G((g, dev, lv) => g.floors.spawns.holding(lv), level);
      await ff(2);
      const end = await G((g, dev, lv) => ({ holding: g.floors.spawns.holding(lv), state: g.creature.getState(),
        reason: g.floors.spawns.log[g.floors.spawns.log.length - 1].reason }), level);
      check(`${level}: held through its ${s.grace} s grace, then it patrols`, mid && !end.holding && end.reason === 'Grace' &&
        end.state !== 'Scripted', end);
    } else {
      // a loud noise of the player's (sprinting is High) ends the grace at once: from the entry, down its longest
      // open line
      await G((g) => {
        const T = g.env.THREE;
        const sp = g.world.spawns(g.level, g.run.routes)[0];
        const root = new T.Vector3(sp.cframe[0], sp.cframe[1], sp.cframe[2]);
        let best = { yaw: 0, d: 0 };
        for (let i = 0; i < 24; i++) {
          const yaw = (i / 24) * Math.PI * 2;
          const hit = g.env.raycast(root, new T.Vector3(-Math.sin(yaw), 0, -Math.cos(yaw)), 60, { ignoreEntities: false });
          const d = hit ? hit.distance : 60;
          if (d > best.d) best = { yaw, d };
        }
        g.env.teleport({ position: root, yaw: best.yaw });
        g.env.setLook(best.yaw, 0);
        g.traps.noteTeleport();
      });
      await ff(0.4);
      await tab.keyboard.down('ShiftLeft');
      await tab.keyboard.down('KeyW');
      await ff(1.2);
      await tab.keyboard.up('KeyW');
      await tab.keyboard.up('ShiftLeft');
      await ff(0.3);
      const end = await G((g, dev, lv) => ({ holding: g.floors.spawns.holding(lv), state: g.creature.getState(),
        reason: g.floors.spawns.log[g.floors.spawns.log.length - 1].reason }), level);
      check(`${level}: a High noise (sprinting) ends the grace at once`, !end.holding && end.reason === 'Noise', end);
    }
  };

  try {
    await tab.goto(`file://${page}?dev&seed=${seed}`);
    await tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 180000 });
    check('boot', await tab.evaluate(() => !window.__rovloc.error));
    await tab.waitForTimeout(1200);
    await G((g, dev) => dev.skipTitle());
    await ff(0.5);
    // ------------------------------------------------------------------ the lobby: onto a ready pad, the countdown
    await G((g) => {
      const e = g.lobby.bus.entrance;
      const pad = g.lobby.pads.map((x) => x.centre).sort((a, b) => Math.hypot(a.x - e.x, a.z - e.z) - Math.hypot(b.x - e.x, b.z - e.z))[0];
      const yaw = Math.atan2(-(pad.x - e.x), -(pad.z - e.z));
      g.env.teleport({ position: { x: e.x, y: e.y + 3, z: e.z }, yaw });
      window.__padD = Math.hypot(pad.x - e.x, pad.z - e.z);
    });
    await ff(0.2);
    await tab.keyboard.down('KeyW');
    await ff(Math.max(0.1, (await tab.evaluate(() => window.__padD)) / 11));
    await tab.keyboard.up('KeyW');
    await ff(12);
    let p = null;
    let s = await G((g) => ({ phase: g.phase, level: g.level, seed: g.run && g.run.seed }));
    check('deployed into Level 0 on the pinned seed', s.phase === 'InRun' && s.level === 'Level0_Basement' && s.seed === seed, s);
    await G((g) => g.creature.devCommand('ignoreme'));
    await noiseLog();
    const picks = await G((g) => Object.fromEntries(Object.entries(g.run.plan.objectives).map(([k, v]) => [k, v.anchors])));
    console.log(`  picks: ${JSON.stringify(picks)}`);
    const route = await G((g) => Object.values(g.run.routes).map((r) => ({ level: r.level, id: r.stairwellId, slot: r.slot,
      compass: r.compass, entry: r.entryRoomOfNextLevel })));
    console.log(`  route: ${route.map((r) => `${r.level.slice(0, 6)} ${r.slot} (${r.id})`).join(', ')}`);
    routeLog.push({ seed, slots: route.map((r) => r.slot).join('/') });
    const expected = await G((g, dev, sd) => Object.values(g.world.routes(sd)).map((r) => r.stairwellId), seed);
    check('the run route is the world rule\'s for the seed (one per floor pair, chained)', route.length === 5 &&
      route.every((r, i) => r.id === expected[i]), route.map((r) => r.id));
    await jamCheck('run start');
    // a jammed door off the basement: its "collapsed" prompt, a thud, and walking at it does not get you through
    const jam = await G((g) => {
      const d = [...g.doors.byId.values()].find((x) => x.jammed && x.level === g.level && x.kind === 'Airlock');
      return d ? { id: d.id } : null;
    });
    check('L0: a jammed stairwell door exists', !!jam, jam);
    if (jam) {
      await standAt(await at(jam.id, 'JamPrompt'), { reach: [2.4, 3, 2], expect: /Jammed/ });
      p = await active();
      await noiseLog();
      await hold(0.3);
      await ff(0.5);
      const after = await G((g, dev, id) => {
        const d = g.doors.get(id);
        const forced = g.doors.setState(d, 'Open', 0);
        return { state: d.state, forced, openness: d.openness };
      }, jam.id);
      check('L0: the jammed door\'s prompt: "Jammed — this stairwell has collapsed", hold 0, no noise; it never opens',
        !!p && /Jammed — this stairwell has collapsed/.test(p.text) && p.hold === 0 && (await noises()).length === 0 &&
        after.state === 'Locked' && !after.forced && after.openness < 1e-3, { p, after });
      await shot('route-jammed-door.png');
      await G((g, dev, id) => {
        const T = g.env.THREE;
        const d = g.doors.get(id);
        const room = g.world.roomAt(d.centre, g.level);
        const lay = g.world.meta.layoutDoors.find((x) => x.id === id);
        const floorSide = lay ? lay.rooms.find((r) => !/Airlock/.test(r)) : null;
        const c = floorSide ? g.world.roomCentre(floorSide) : null;
        const dir = d.centre.clone().sub(c || d.centre.clone().add(new T.Vector3(-1, 0, 0))).setY(0).normalize();
        const start = d.centre.clone().addScaledVector(dir, -5);
        start.y = (room ? room.floorY : d.centre.y - 5) + 3;
        g.env.teleport({ position: start, yaw: Math.atan2(-dir.x, -dir.z) });
        g.env.setLook(Math.atan2(-dir.x, -dir.z), 0);
        g.traps.noteTeleport();
        window.__jamDir = dir.toArray();
        window.__jamAt = d.centre.toArray();
      }, jam.id);
      await tab.keyboard.down('KeyW');
      await ff(2.5);
      await tab.keyboard.up('KeyW');
      await ff(0.5);
      s = await G((g) => {
        const root = g.env.rootPosition();
        const d = window.__jamDir;
        const c = window.__jamAt;
        return { past: (root.x - c[0]) * d[0] + (root.z - c[2]) * d[2], level: g.level };
      });
      check('L0: walking into a jammed stairwell door does not get you through', s.past < 0, s);
    }

    // ================================================================== Level 0: restore power
    await ff(1);
    await shot('L0-tracker.png');
    let f = await floorOf();
    check('L0: the exit door is Locked and the airlock idle', f.door === 'Locked' && !f.unlocked && f.airlock === 'Idle', f);
    let t = await tracker();
    check('L0: the tracker shows the objective and its steps', t.title === 'Restore power' && t.steps[0] === 'Fuses 0/3', t);
    // walking at the locked door does not get you through
    await G((g) => {
      const T = g.env.THREE;
      const route = g.route(g.level);
      const door = g.doors.get(route.exitDoorIds[0]);
      const v = route.checkpointVolumes[0];
      const dir = new T.Vector3(v.cframe[0], door.centre.y, v.cframe[2]).sub(door.centre).setY(0).normalize();
      const start = door.centre.clone().addScaledVector(dir, -6).setY(3);
      g.env.teleport({ position: start, yaw: Math.atan2(-dir.x, -dir.z) });
      g.env.setLook(Math.atan2(-dir.x, -dir.z), 0);
      g.traps.noteTeleport();
      window.__doorDir = dir.toArray();
      window.__doorAt = door.centre.toArray();
    });
    const lockedPrompt = await (async () => {
      await tab.keyboard.down('KeyW');
      await ff(0.35);
      const p = await active();
      await ff(2.2);
      await tab.keyboard.up('KeyW');
      return p;
    })();
    await ff(1);
    s = await G((g) => {
      const root = g.env.rootPosition();
      const d = window.__doorDir;
      const c = window.__doorAt;
      return { past: (root.x - c[0]) * d[0] + (root.z - c[2]) * d[2], airlock: g.airlock.phase, inside: g.airlock.isInside(),
        level: g.level };
    });
    check('L0: walking into the locked exit does not get you through', s.past < 0 && s.airlock === 'Idle' && !s.inside, { ...s, lockedPrompt });
    const lock0 = await G((g) => g.route(g.level).lockEntity);
    await standAt(await at(lock0, 'LockPrompt'), { reach: [2.4, 3, 2], expect: /Locked/ });
    p = await active();
    check('L0: the lock prompt reads "Locked — no power"', !!p && /Locked — no power/.test(p.text), p);
    // the fuses
    for (const id of picks.Level0_Basement) {
      const r = await standAt(await at(id, 'PromptPoint'), { expect: /Fuse/ });
      const p = await active();
      await hold(1.0);
      f = await floorOf();
      check(`L0: fuse ${id} taken with its hold`, r.ok && p && /Pick Up/.test(p.text) && f.carry.Fuse >= 1, { r, p, carry: f.carry });
    }
    f = await floorOf();
    check('L0: three fuses carried', f.carry.Fuse === 3 && f.steps.FindFuses === 3, f);
    const panel = await G((g) => g.world.entities('BreakerPanel', g.level)[0].id);
    await standAt(await at(panel, 'LeverPrompt'), { reach: [2.6, 3.2] });
    await shot('L0-breaker-before.png');
    for (let i = 1; i <= 3; i++) {
      await standAt(await at(panel, `FuseSlot${i}Prompt`), { reach: [2.4, 3, 2], expect: /Fit Fuse/ });
      const p = await active();
      await hold(2.3);
      f = await floorOf();
      check(`L0: fuse fitted in slot ${i} (2 s hold)`, p && /Fit Fuse/.test(p.text) && f.steps.FitFuses === i, { p, steps: f.steps });
    }
    await noiseLog();
    await standAt(await at(panel, 'LeverPrompt'), { reach: [2.4, 3, 2], expect: /Breaker/ });
    p = await active();
    await hold(3.3);
    await ff(3.5);
    f = await floorOf();
    const lights = await G((g) => g.floors.floor('Level0_Basement').powered);
    check('L0: the main breaker thrown (3 s, loud): power back, the exit unlocked', p && /Breaker/.test(p.text) && lights &&
      f.unlocked && f.door === 'Open' && (await noises()).includes('ObjectiveClunk'), { p, f });
    await shot('L0-breaker-after.png');
    t = await tracker();
    const compass0 = await G((g) => g.route(g.level).compass);
    const named = { East: 'east', NorthEast: 'north-east', SouthEast: 'south-east' }[compass0];
    check(`L0: the tracker names the route's stairwell (the ${named} one)`, !!named && t.title === `Get to the ${named} stairwell`, t);
    if (route[0].slot !== 'Middle') await shot('route-corner-vestibule-L0.png');
    await leave('Level1_Hallways');

    // ================================================================== Level 1: master keys
    await ff(1);
    await shot('L1-tracker.png');
    f = await floorOf();
    check('L1: the exit door is Locked', f.door === 'Locked' && !f.unlocked, f);
    await G((g) => {
      const T = g.env.THREE;
      const door = g.doors.find('Level1_Hallways', 'ClassroomDoor');
      const room = g.world.room('L1_Classroom_108');
      const centre = new T.Vector3(room.rect.x + room.rect.w / 2, room.floorY + 3, room.rect.z + room.rect.d / 2);
      const q = new T.Vector3(door.centre.x, room.floorY + 3, door.centre.z).lerp(centre, 0.35);
      g.env.teleport({ position: q, yaw: 0 });
      g.traps.noteTeleport();
    });
    await ff(6);
    s = await G((g) => ({ gate: g.doors.find('Level1_Hallways', 'HallwayGate').state }));
    check('L1: the scare slams the gate', s.gate === 'Locked', s);
    const lock1 = await G((g) => g.route(g.level).lockEntity);
    await standAt(await at(lock1, 'LockPrompt'), { reach: [2.4, 3, 2], expect: /Locked/ });
    p = await active();
    check('L1: without the keys the padlock says why', !!p && /needs the master keys/.test(p.text), p);
    const keys = picks.Level1_Hallways[0];
    const kr = await standAt(await at(keys, 'PromptPoint'), { expect: /Master Keys/ });
    await hold(1.0);
    f = await floorOf();
    check('L1: the master keys taken past the gate', kr.ok && f.carry.MasterKeys === 1, { kr, f });
    await standAt(await at(lock1, 'LockPrompt'), { reach: [2.4, 3, 2], expect: /Unlock/ });
    p = await active();
    await noiseLog();
    await hold(4.4);
    await ff(3);
    f = await floorOf();
    const work = (await noises()).filter((n) => n === 'ObjectiveWork').length;
    check('L1: the 4 s unlock with the keys (a Normal noise each second) opens the exit', p && /Unlock/.test(p.text) &&
      work >= 4 && f.unlocked && f.door === 'Open', { p, work, f });
    await leave('Level2_ScienceHall');

    // ================================================================== Level 2: burn the chain
    await shot('L2-tracker.png');
    await spawnCheck('Level2_ScienceHall', first ? 'Grace' : 'Noise');
    f = await floorOf();
    check('L2: the exit door is Locked', f.door === 'Locked' && !f.unlocked, f);
    for (const id of picks.Level2_ScienceHall) {
      const r = await standAt(await at(id, 'PromptPoint'), { expect: /Reagent/ });
      await hold(1.0);
      f = await floorOf();
      check(`L2: reagent ${id} taken`, r.ok && f.carry.Reagent >= 1, { r, carry: f.carry });
    }
    const hood = await G((g) => g.world.entities('FumeHood', g.level)[0].id);
    await standAt(await at(hood, 'MixPrompt'), { reach: [2.4, 3, 2], expect: /Mix/ });
    await noiseLog();
    await hold(2);
    await ff(0.5);
    s = await G((g) => ({ done: g.floors.floor(g.level).mix.done, loaded: g.floors.floor(g.level).loaded }));
    check('L2: mixing let go half way keeps its progress', s.loaded && s.done > 1.6 && s.done < 2.4, s);
    await shot('L2-fumehood.png');
    await hold(3.4);
    await ff(0.5);
    f = await floorOf();
    check('L2: the mix (5 s, bubbling noise each second) brews the acid', f.steps.MixAcid === 1 &&
      (await noises()).filter((n) => n === 'ObjectiveWork').length >= 4, f);
    const takeAcid = async () => {
      const acid = await G((g) => g.world.entities('AcidFlask', g.level)[0].id);
      await standAt(await at(acid, 'PromptPoint'), { reach: [2.2, 2.8, 1.8], expect: /Acid/ });
      await hold(0.8);
      return G((g) => !!(g.flasks.held && g.flasks.held.objective));
    };
    check('L2: the acid flask taken into the hand', await takeAcid());
    // a miss: thrown away from the chain
    await G((g) => g.env.setLook(g.env.look().yaw + Math.PI, 0.1));
    await G((g) => g.env.injectAction('Throw', 'obj', true));
    await ff(0.45);
    await G((g) => g.env.injectAction('Throw', 'obj', false));
    await ff(3.5);
    f = await floorOf();
    s = await G((g) => ({ acid: g.floors.floor(g.level).acidState, held: !!g.flasks.held }));
    check('L2: a missed throw loses only the flask: the hood can brew another', s.acid === 'None' && !s.held &&
      f.steps.MixAcid === 0 && !f.unlocked, { s, f });
    await standAt(await at(hood, 'MixPrompt'), { reach: [2.4, 3, 2], expect: /Mix/ });
    await hold(5.4);
    await ff(0.5);
    check('L2: re-mixed and the second flask taken', await takeAcid());
    const lock2 = await G((g) => g.route(g.level).lockEntity);
    const chain = await at(lock2, null);
    const centre = await G((g, dev, id) => g.floors.floor(g.level).lock.chainCentre().toArray(), lock2);
    if (first) {
      // thrown at the chain from a few studs off it
      await G((g) => {
        const T = g.env.THREE;
        const route = g.route(g.level);
        const door = g.doors.get(route.exitDoorIds[0]);
        const v = route.checkpointVolumes[0];
        const dir = new T.Vector3(v.cframe[0], door.centre.y, v.cframe[2]).sub(door.centre).setY(0).normalize();
        const room = g.world.roomAt(door.centre.clone().addScaledVector(dir, -6), g.level);
        const spot = door.centre.clone().addScaledVector(dir, -6);
        spot.y = (room ? room.floorY : door.centre.y - 5) + 3;
        g.env.teleport({ position: spot, yaw: Math.atan2(-dir.x, -dir.z) });
        g.traps.noteTeleport();
      });
      await ff(0.4);
      await G((g, dev, c) => {
        const eye = g.env.eye();
        const d = { x: c[0] - eye.x, y: c[1] - eye.y, z: c[2] - eye.z };
        g.env.setLook(Math.atan2(-d.x, -d.z), Math.atan2(d.y, Math.hypot(d.x, d.z)) + 0.03);
      }, centre);
      await G((g) => g.env.injectAction('Throw', 'obj', true));
      await ff(0.45);
      await G((g) => g.env.injectAction('Throw', 'obj', false));
      await ff(0.5);
      await shot('L2-chain-burning.png');
      await ff(4);
    } else {
      await standAt(await at(lock2, 'LockPrompt'), { reach: [2.4, 3, 2], expect: /Pour/ });
      p = await active();
      check('L2: with the acid in hand the door offers Pour', !!p && /Pour/.test(p.text), p);
      await hold(2.4);
      await ff(4.5);
    }
    f = await G((g) => ({ unlocked: g.floors.floor('Level2_ScienceHall').unlocked,
      door: g.doors.get(g.world.route('Level2_ScienceHall', g.run.routes).exitDoorIds[0]).state, level: g.level }));
    check(`L2: the chain burnt by the ${first ? 'throw' : 'pour'}: the exit unlocked`, f.unlocked && f.door === 'Open' &&
      f.level === 'Level2_ScienceHall', { f, chain });
    await leave('Level3_Gymnasium');

    // ================================================================== Level 3: the gym generator
    await shot('L3-tracker.png');
    await spawnCheck('Level3_Gymnasium', first ? 'Noise' : 'Grace');
    const l3 = await G((g) => {
      const fl = g.floors.floor(g.level);
      const wrong = fl.lockers.find((l) => l.id !== fl.keyLocker);
      return { key: fl.keyLocker, wrong: wrong.id, keyItem: fl.keyEntity.id };
    });
    await standAt(await at(l3.wrong, 'HidePrompt'), { reach: [2.2, 2.8, 1.8], action: 'Kick', expect: /Search/ });
    const hideP = await active('Interact');
    const searchP = await active('Kick');
    await hold(1.3, 'KeyR');
    await ff(1.5);
    s = await G((g, dev, id) => ({ searched: g.floors.floor(g.level).searched.has(id), found: g.floors.floor(g.level).keyShown,
      state: g.lockers.stateOf(id) }), l3.wrong);
    check('L3: searching an empty locker (1 s, R) says so; Hide stays its own prompt', hideP && /Hide/.test(hideP.text) &&
      searchP && /Search/.test(searchP.text) && s.searched && !s.found && s.state === 'Free', { hideP, searchP, s });
    await standAt(await at(l3.key, 'HidePrompt'), { reach: [2.2, 2.8, 1.8], action: 'Kick', expect: /Search/ });
    await hold(1.3, 'KeyR');
    await ff(0.8);
    await standAt(await at(l3.keyItem, 'PromptPoint'), { reach: [2, 2.6, 1.6], expect: /Coach/ });
    p = await active();
    await hold(1.0);
    f = await floorOf();
    check('L3: the key locker searched, the coach\'s key taken', !!p && /Pick Up/.test(p.text) && f.carry.CoachKey === 1, { p, f });
    const store = await G((g) => g.world.entities('StoreLock', g.level)[0].id);
    await standAt(await at(store, 'LockPrompt'), { reach: [2.4, 3, 2], expect: /Unlock/ });
    await hold(2.4);
    await ff(3);
    s = await G((g) => ({ door: g.doors.get(g.world.entities('StoreDoor', g.level)[0].id).state }));
    check('L3: the store unlocked (2 s): its door opens', s.door === 'Open', s);
    const gen = await G((g) => g.world.entities('Generator', g.level)[0].id);
    await standAt(await at(gen, 'PullPrompt'), { reach: [2.2, 2.8, 1.8], expect: /Pull Start/ });
    await noiseLog();
    await hold(3.3);
    await ff(1.5);
    f = await floorOf();
    check('L3: the generator started (3 s): its Critical noise', f.steps.StartGenerator === 1 &&
      (await noises()).includes('GeneratorStart'), f);
    await shot('L3-generator.png');
    await ff(42);
    f = await floorOf();
    t = await tracker();
    check('L3: still winding near the end of the 45 s (the countdown on the tracker)', !f.unlocked && t.steps.some((x) => /winds: \d+s/.test(x)), t);
    await ff(4);
    f = await floorOf();
    check('L3: after 45 s the door motor has wound: the exit unlocked', f.unlocked && f.door === 'Open', f);
    await leave('Level4_FloodedPool');

    // ================================================================== Level 4: the valve wheel
    await ff(1);
    await shot('L4-tracker.png');
    const valve = await G((g) => {
      const v = g.world.entities('HatchValve', g.level)[0];
      return { id: v.id, grate: v.attributes.GrateId };
    });
    s = await G((g, dev, v) => ({ passable: g.vents.passable(v.grate), blocked: !!g.vents.grates.get(v.grate).blocked }), valve);
    f = await floorOf();
    check('L4: the exit Locked and the hatch\'s grate blocked', f.door === 'Locked' && s.blocked && !s.passable, { f, s });
    const wheel = picks.Level4_FloodedPool[0];
    const wp = await at(wheel, 'PromptPoint');
    await G((g, dev, w) => {
      g.env.teleport({ position: { x: w[0], y: 80, z: w[2] + 3 }, yaw: 0 });
      g.traps.noteTeleport();
    }, wp);
    await ff(0.6);
    await tab.keyboard.down('KeyC');
    for (let i = 0; i < 16; i++) {
      await G((g, dev, w) => {
        const eye = g.env.eye();
        const d = { x: w[0] - eye.x, y: w[1] - eye.y, z: w[2] - eye.z };
        g.env.setLook(Math.atan2(-d.x, -d.z), Math.atan2(d.y, Math.hypot(d.x, d.z)));
      }, wp);
      await ff(0.25);
      const near = await G((g, dev, w) => g.env.rootPosition().distanceTo(new g.env.THREE.Vector3(...w)), wp);
      if (near < 3.5) break;
    }
    s = await G((g) => ({ ms: g.env.moveState(), ox: g.env.meters().oxygen.value }));
    await tab.keyboard.down('KeyE');
    await ff(1.1);
    await tab.keyboard.up('KeyE');
    await tab.keyboard.up('KeyC');
    f = await floorOf();
    check('L4: dived for the wheel and took it underwater (oxygen draining)', f.carry.ValveWheel === 1 && s.ms === 'Underwater' &&
      s.ox < 100, { s, carry: f.carry });
    await G((g) => g.pool.devGrab());
    await ff(1.2);
    for (let i = 0; i < 24; i++) {
      await tab.keyboard.press('Space');
      await ff(0.1);
    }
    await ff(1);
    f = await floorOf();
    s = await G((g) => ({ grab: !!g.pool.grab, life: g.life.state }));
    check('L4: a grab while carrying the wheel does not lose it', !s.grab && s.life === 'Alive' && f.carry.ValveWheel === 1, { s, f });
    const seat = await G((g, dev, v) => g.floors.floor(g.level).seatPos.toArray(), valve);
    await G((g, dev, c) => {
      g.env.teleport({ position: { x: c[0], y: 80.5, z: c[2] + 3.2 }, yaw: 0 });
      g.traps.noteTeleport();
    }, seat);
    await ff(0.8);
    await G((g, dev, c) => {
      const eye = g.env.eye();
      const d = { x: c[0] - eye.x, y: c[1] - eye.y, z: c[2] - eye.z };
      g.env.setLook(Math.atan2(-d.x, -d.z), Math.atan2(d.y, Math.hypot(d.x, d.z)));
    }, seat);
    p = await active();
    await hold(3.3);
    f = await floorOf();
    check('L4: the wheel fitted on the hatch valve (3 s)', !!p && /Fit Valve/.test(p.text) && f.steps.FitWheel === 1, { p, f });
    await shot('L4-valve-seated.png');
    await noiseLog();
    await hold(2);
    await ff(0.4);
    s = await G((g) => g.floors.floor(g.level).turn.done);
    check('L4: turning let go half way keeps how far it turned', s > 1.6 && s < 2.4, s);
    await hold(2.4);
    await ff(3);
    f = await floorOf();
    s = await G((g, dev, v) => ({ passable: !g.vents.grates.get(v.grate).blocked }), valve);
    check('L4: the valve turned (Normal noise each second): hatch open, grate usable, exit unlocked', f.unlocked &&
      f.door === 'Open' && s.passable && (await noises()).filter((n) => n === 'ObjectiveWork').length >= 4, { f, s });
    await leave('Level5_Roof');

    // ================================================================== Level 5: cut the crate open
    await ff(1);
    const arrival = await G((g) => {
      const r = g.run.routes.Level4_FloodedPool;
      const door = g.level5.roofDoor();
      const geo = g.level5.geo;
      const root = g.env.rootPosition();
      const inRect = (b, p) => p.x >= b.minX && p.x <= b.maxX && p.z >= b.minZ && p.z <= b.maxZ;
      return { housing: geo.housingId, want: r.entryRoomOfNextLevel, door: door && door.id, wantDoor: r.entryDoorIds[0],
        doorState: door && door.state, inHousing: g.world.inRoom(geo.housingId, root),
        behindIn: inRect(geo.housing, geo.behindPosition), slot: r.slot };
    });
    check(`L5: the finale follows the arrival housing (${arrival.slot}): its roof door opens behind the squad`,
      arrival.housing === arrival.want && arrival.door === arrival.wantDoor && arrival.inHousing && arrival.behindIn &&
      arrival.doorState === 'Open', arrival);
    if (arrival.slot !== 'Middle') {
      await G((g) => {
        const geo = g.level5.geo;
        const T = g.env.THREE;
        const p = geo.doorway.clone().addScaledVector(geo.out, 14);
        p.y = geo.doorway.y + 3;
        const yaw = Math.atan2(geo.out.x, geo.out.z);
        g.env.teleport({ position: p, yaw });
        g.env.setLook(yaw, 0.05);
        g.traps.noteTeleport();
        return new T.Vector3();
      });
      await ff(0.4);
      await shot('route-roof-corner-housing.png');
    }
    await shot('L5-tracker.png');
    s = await G((g) => ({ packs: g.parachute.packs.map((x) => x.handle && x.handle.isHolding !== undefined), open: g.parachute.crateOpen,
      phase: g.level5.phase }));
    check('L5: the packs are chained in (no pack can be taken)', s.open === false, s);
    const cutters = picks.Level5_Roof[0];
    await standAt(await at(cutters, 'PromptPoint'), { expect: /Bolt Cutters/ });
    await hold(1.0);
    f = await floorOf();
    check('L5: the bolt cutters taken', f.carry.BoltCutters === 1, f);
    const crate = await G((g) => g.world.entities('CrateChain', g.level)[0].id);
    await standAt(await at(crate, 'LockPrompt'), { reach: [2.4, 3, 2], expect: /Cut Chain/ });
    p = await active();
    const before = await G((g) => g.level5.phase);
    await hold(4.4);
    await ff(0.4);
    s = await G((g) => ({ open: g.parachute.crateOpen, phase: g.level5.phase }));
    f = await floorOf();
    check('L5: the chain cut (4 s, loud): the crate opens; the door smash brought forward', !!p && /Cut Chain/.test(p.text) &&
      s.open && f.unlocked && (before !== 'Arrival' || s.phase === 'Smash'), { p, before, s });
    await ff(1);
    await shot('L5-crate-cut.png');
    const pack = await G((g) => g.parachute.freePackPoint(g.env.rootPosition()).toArray());
    await standAt(pack, { reach: [2, 2.6, 1.6], expect: /Parachute/ });
    await hold(0.9);
    s = await G((g) => g.parachute.state);
    check('L5: a parachute pack taken', s === 'Packed', s);
    await G((g) => {
      const pg = g.parachute.geo;
      const gap = pg.gap;
      const c = g.parachute.gapCentre();
      g.env.teleport({ position: { x: gap.minX + 8, y: c.y + 3.2, z: c.z }, yaw: Math.PI / 2 });
      g.env.setLook(Math.PI / 2, 0);
      g.traps.noteTeleport();
    });
    await tab.keyboard.down('KeyW');
    for (let i = 0; i < 20; i++) {
      await ff(0.2);
      if ((await G((g) => g.parachute.state)) === 'Freefall') break;
    }
    await tab.keyboard.up('KeyW');
    await tab.keyboard.press('Space');
    await ff(14);
    s = await G((g) => ({ chute: g.parachute.state, outcome: g.match.outcome, phase: g.phase }));
    check('L5: off the gap, the cord, landed: ESCAPED', s.chute === 'Landed' && s.outcome === 'Escaped', s);
    s = await G((g, dev, id) => ({ door: g.doors.get(id).state, smashed: !!g.level5.smash && g.level5.smash.released }), arrival.wantDoor);
    check(`L5: the arrival housing's roof door (${arrival.wantDoor}) was smashed and the Creature let go from behind it`,
      s.door === 'Smashed' && s.smashed, s);
  } catch (err) {
    check('objective run completed', false, String(err && err.stack ? err.stack : err));
    try {
      await shot('99-failure.png');
    } catch { /* gone */ }
  }
  const fatal = logs.filter((l) => /pageerror|error:|warning:/.test(l));
  check('no console errors or warnings', fatal.length === 0, fatal.slice(0, 8));
  await tab.close();
}

await browser.close();
console.log(`screenshots in ${shots}:\n${shotsTaken.map((x) => `  ${path.basename(x)}`).join('\n')}`);
console.log(`routes (L0/L1/L2/L3/L4 exits): ${routeLog.map((r) => `seed ${r.seed} ${r.slots}`).join('; ')}`);
console.log(failures.length ? `\n${failures.length} FAILED:\n  ${failures.join('\n  ')}` : '\nall checks passed');
process.exit(failures.length ? 1 : 0);
