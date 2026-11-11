// objective-run.mjs: the floor objectives played through, lobby to landing, with the pre-installed Playwright Chromium.
//
//   node tools/objective-run.mjs [--seeds 1029,4242] [--floors L0,L1,L2,L3] [--html <page>] [--no-build]
//                                [--shots <dir>]
//
// --floors stops each seed's run after the last floor listed (from Level 0: `--floors L0` plays the basement, spawn
// to fuses to breaker to the exit unlocked and the airlock out).
//
// For every seed (a fresh page with ?dev&seed=N, so the run's picks, plan, routes and Creature start come from it):
// the lobby's ready pad (real keys), the countdown, the deploy, the Back Lot's stand-in (Skip); then every floor's
// objective with real input and the prompts' real holds (E held for each hold, Space to pull the cord). The harness may teleport the player next to a step's spot within a floor (a clear spot within reach, facing
// it, never on an armed trap); every gate is the game's own logic. The Creature is told to ignore the player
// ("ignoreme") so a hunt cannot end the run; its start rule and grace are still checked:
//   floors 0-1   the exit is locked before (its door Locked, the airlock idle) and open after; walking at the locked
//                basement door does not get you through; the tracker shows the title and steps, then the stairwell.
//   Level 0      three fuses taken, fitted one slot at a time, the breaker thrown (loud), the basement lights back.
//   Level 1      the scare and the gate; the keys past it; the 4 s unlock with its Normal noise every second.
//   Level 2      the Auditorium's crossing: the Creature's start (70-140 studs walking from the entry, out of its sight,
//                not in an objective room, held until its grace ends or a loud noise of yours); no item, no lock: the
//                exit open from the start, the tracker on the way to the stairwell; the step done on leaving.
//   Level 3      the roof: the arrival housing's door open, the Creature hidden behind it; every pack free; the door
//                smashed after the grace once out; the first seed takes a pack, the others step off without one (a
//                spare is buckled on); the cord, the Creature on the ledge over the jumper at the touchdown, the landing
//                (the roof done at the touchdown, within one roof check at ServerTickHz: on to City1_Rooftops; the hold
//                released at once); the stand-ins of the stages still to be built play out; the ESCAPED results.
//   Routes       each seed's random exits are logged (North / Middle / South per floor); every stairwell off the
//                route is jammed (its doors shut and Locked at both ends, the debris shown, the "collapsed" prompt,
//                walking at it does not get you through) and stays so all run (checked on every floor); the route's
//                doors show no debris; every arrival spawns in the route's entry vestibule; the roof's door smash plays
//                at the arrival housing (its own roof door smashed, the Creature behind it), corner housings included.
//   Grates       at run start every grate shows the look the run's plan picks: rusted shut (Locked) where it locks
//                one, galvanized everywhere else, never both looks at once.
//   Radar        every floor of every seed is finished without a single radar scan (I14), but the last of several
//                seeds plays the basement by radar: Tab shows the three fuses (the run's picks: it never reads them),
//                a battery (its LED blinks) gives the spent charge back, the next scan shows the breaker panel.
// Screenshots (the first seed only): the tracker on each floor, the breaker panel before and after power, the results.
// Exit code 1 on any failure.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { GameConfig } from '../src/engine/config.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.resolve(here, '..');
const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const SEEDS = opt('--seeds', '1029,4242').split(',').map(Number);
const FLOORS = opt('--floors', 'L0,L1,L2,L3').split(',').map((f) => Number(f.replace(/^L/, ''))).filter(Number.isFinite);
const LAST_FLOOR = Math.max(0, ...FLOORS);
/** Thrown to end a seed's run after the last floor asked for (not a failure). */
class FloorsDone extends Error {}
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
  // the last of several seeds finds the basement's fuses and its panel by radar scans alone; every other floor and
  // every other seed is played without a single scan (I14)
  const scanned = SEEDS.length > 1 && si === SEEDS.length - 1;
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
   * surface found under them, with headroom, no wall within a body's width, a clear line to
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
          const down = g.env.raycast(new T.Vector3(x, p.y + 1.5, z), new T.Vector3(0, -1, 0), 9, { ignoreEntities: false });
          if (!down || down.normal.y < 0.7) continue;
          const root = new T.Vector3(x, down.point.y + 3.05, z);
          if (g.env.raycast(root, new T.Vector3(0, 1, 0), 2.6, { ignoreEntities: false })) continue;
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
    }, { point, reach: opts.reach || [2.2, 3, 1.6, 4] });
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
    const scans = await G((g) => ({ level: g.level, scans: g.radar.scans }));
    if (!scanned) check(`${scans.level}: finished without a single radar scan (I14)`, scans.scans === 0, scans);
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
    // the climb is not walked: the player is put at the level's first spawn slot (CharacterService.SpawnCFrame)
    const arrived = await G((g, dev, room) => {
      g.match.spawnAt(g.level, 0);
      g.traps.noteTeleport();
      const spawns = g.world.spawns(g.level, g.run.routes);
      return { room, inRoom: g.world.inRoom(room, g.env.rootPosition()), spawns: spawns.length,
        rooms: [...new Set(spawns.map((a) => a.room))],
        inside: spawns.every((a) => g.world.inRoom(room, new g.env.THREE.Vector3(a.cframe[0], a.cframe[1], a.cframe[2]))) };
    }, entryRoom);
    await ff(0.3);
    check(`${next}: the arrival spawns are in the route's entry vestibule ${entryRoom}`, arrived.inRoom && arrived.inside &&
      arrived.spawns === 4 && arrived.rooms.length === 1 && arrived.rooms[0] === entryRoom, arrived);
  };
  const noiseLog = () => G((g) => {
    if (!window.__objNoise) {
      window.__objNoise = [];
      g.env.onNoise((e) => window.__objNoise.push({ kind: e.kind, priority: e.priority, t: g.env.now() }));
    }
    window.__objNoise.length = 0;
  });
  const noises = () => tab.evaluate(() => (window.__objNoise || []).map((n) => n.kind));
  /** Stands `back` studs from a fire door on its floor side (or its vestibule's: `inside`), facing it (screenshots). */
  const viewDoor = (id, back, inside = false) => G((g, dev, a) => {
    const d = g.doors.get(a.id);
    const lay = g.world.meta.layoutDoors.find((x) => x.id === a.id);
    const floorSide = lay ? lay.rooms.find((r) => g.world.room(r) && /Airlock|RoofAccess/.test(r) === a.inside) : null;
    const c = g.world.roomCentre(floorSide);
    const dir = d.centre.clone().sub(c).setY(0);
    // the doorway's normal: the larger axis of the floor-room-to-door offset
    if (Math.abs(dir.x) > Math.abs(dir.z)) dir.set(Math.sign(dir.x), 0, 0);
    else dir.set(0, 0, Math.sign(dir.z));
    const start = d.centre.clone().addScaledVector(dir, -a.back);
    start.y = g.world.room(floorSide).floorY + 3;
    const yaw = Math.atan2(-dir.x, -dir.z);
    g.env.teleport({ position: start, yaw });
    g.env.setLook(yaw, 0.06);
    g.traps.noteTeleport();
    return { floorSide, dir: dir.toArray() };
  }, { id, back, inside });
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
      j.bad.length === 0 && j.jammed === 12 && j.open === 6, j);
  };
  /** Every grate shows the look its run's plan picks (VentGrateBuilder.setLocked): rusted shut where the plan locks it,
   *  galvanized elsewhere, never both; and its state follows. */
  const grateLookCheck = async (where) => {
    const r = await G((g) => {
      const locked = g.run.plan.lockedGrates;
      const bad = [];
      let rusted = 0;
      let exported = 0;
      for (const grate of g.vents.grates.values()) {
        const e = g.env.entity(grate.id);
        const lock = locked.has(grate.id);
        if (lock) rusted++;
        if (e.info.attributes.GrateState === 'Locked') exported++;
        for (const node of ['', 'Panel', 'Screw1', 'Screw2', 'Screw3', 'Screw4']) {
          const galvanized = e.nodes.get(node);
          const rust = e.nodes.get(node ? `${node}/Rusted` : 'Rusted');
          if (!galvanized || !rust || galvanized.hidden !== lock || rust.hidden === lock) {
            bad.push(`${grate.id} ${node || 'frame'}: locked ${lock}, galvanized ${!!galvanized && !galvanized.hidden}, rusted ${!!rust && !rust.hidden}`);
          }
        }
        if ((grate.state === 'Locked') !== lock) bad.push(`${grate.id}: ${grate.state}, locked ${lock}`);
      }
      return { grates: g.vents.grates.size, rusted, exported, bad };
    });
    check(`${where}: every grate shows its run's look (${r.rusted} of ${r.grates} rusted shut by the plan; the export seed locked ${r.exported})`,
      r.bad.length === 0 && r.grates > 0, r);
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
    await ff(10);
    let p = null;
    let s = await G((g) => ({ phase: g.phase, stage: g.stage, standIn: g.standIn.stage() }));
    check('deployed: the run opens on the Back Lot\'s stand-in', s.phase === 'InRun' && s.stage === 'BackLot' &&
      s.standIn === 'BackLot', s);
    await tab.keyboard.press('Enter');
    await ff(2.5);
    s = await G((g) => ({ phase: g.phase, level: g.level, seed: g.run && g.run.seed }));
    check('Skip: on into Level 0 on the pinned seed', s.phase === 'InRun' && s.level === 'Level0_Basement' && s.seed === seed, s);
    await G((g) => g.creature.devCommand('ignoreme'));
    await noiseLog();
    const picks = await G((g) => Object.fromEntries(Object.entries(g.run.plan.objectives).map(([k, v]) => [k, v.anchors])));
    console.log(`  picks: ${JSON.stringify(picks)}`);
    const route = await G((g) => Object.values(g.run.routes).map((r) => ({ level: r.level, id: r.stairwellId, slot: r.slot,
      compass: r.compass, entry: r.entryRoomOfNextLevel })));
    console.log(`  route: ${route.map((r) => `${r.level.slice(0, 6)} ${r.slot} (${r.id})`).join(', ')}`);
    routeLog.push({ seed, slots: route.map((r) => r.slot).join('/') });
    const expected = await G((g, dev, sd) => Object.values(g.world.routes(sd)).map((r) => r.stairwellId), seed);
    check('the run route is the world rule\'s for the seed (one per floor pair, chained)', route.length === 3 &&
      route.every((r, i) => r.id === expected[i]), route.map((r) => r.id));
    await jamCheck('run start');
    await grateLookCheck('run start');
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
      await viewDoor(jam.id, 9);
      await ff(0.4);
      await shot('route-jammed-door.png');
      await viewDoor(jam.id, 4, true);
      await ff(0.4);
      await shot('route-jammed-door-vestibule-side.png');
      const v = await viewDoor(jam.id, 5);
      await G((g, dev, a) => {
        window.__jamDir = a.dir;
        window.__jamAt = g.doors.get(a.id).centre.toArray();
      }, { id: jam.id, dir: v.dir });
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
    if (route[0].slot !== 'Middle') {
      await viewDoor(await G((g) => g.route(g.level).exitDoorIds[0]), 10);
      await ff(0.4);
      await shot('route-corner-exit-L0.png');
    }
    await standAt(await at(lock0, 'LockPrompt'), { reach: [2.4, 3, 2], expect: /Locked/ });
    p = await active();
    check('L0: the lock prompt reads "Locked — no power"', !!p && /Locked — no power/.test(p.text), p);
    // the fuses: from the run's picks, or (the scanning seed) where a radar scan shows them
    let fuseIds = picks.Level0_Basement;
    let panel = await G((g) => g.world.entities('BreakerPanel', g.level)[0].id);
    /** Tab, then what the scan shows once it is up: [{kind, id, at}] (never the Creature: kinds and ids checked). */
    const scan = async () => {
      await tab.keyboard.press('Tab');
      await ff(0.5);
      return G((g) => g.radar.targets().map((x) => ({ kind: x.kind, id: x.id, at: x.point.toArray() })));
    };
    if (scanned) {
      const seen = await scan();
      const items = seen.filter((x) => x.kind === 'Item');
      check(`L0 (by radar): the scan shows the three fuses (${items.map((x) => x.id).join(', ')}), they are the run's`, items.length === 3 &&
        items.every((x) => picks.Level0_Basement.includes(x.id)) && seen.every((x) => ['Item', 'Battery'].includes(x.kind)), seen);
      fuseIds = items.map((x) => x.id);
      await ff(8);
    }
    for (const id of fuseIds) {
      const r = await standAt(await at(id, 'PromptPoint'), { expect: /Fuse/ });
      const p = await active();
      await hold(1.0);
      f = await floorOf();
      check(`L0: fuse ${id} taken with its hold`, r.ok && p && /Pick Up/.test(p.text) && f.carry.Fuse >= 1, { r, p, carry: f.carry });
    }
    f = await floorOf();
    check('L0: three fuses carried', f.carry.Fuse === 3 && f.steps.FindFuses === 3, f);
    if (scanned) {
      // the charge spent: a battery (its LED blinks) gives one more; the next scan shows the breaker panel
      const battery = await G((g) => {
        const root = g.env.rootPosition();
        const live = g.batteries.live(g.level).sort((a, b) => a.point.distanceTo(root) - b.point.distanceTo(root));
        return live[0] ? { id: live[0].id, at: live[0].point.toArray() } : null;
      });
      const r = await standAt(battery.at, { expect: /Battery/ });
      await hold(0.5);
      const charges = await G((g) => g.radar.charges);
      check('L0 (by radar): a battery taken gives the charge back', r.ok && charges === 1, { r, charges });
      const seen = await scan();
      const stations = seen.filter((x) => x.kind === 'Station');
      check(`L0 (by radar): the next scan shows the breaker panel (${stations.map((x) => x.id).join(', ')})`, stations.length === 1, seen);
      panel = stations.length ? stations[0].id.split('#')[0] : panel;
      await ff(8);
    }
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

    await leave('Level1_Hallways');
    if (LAST_FLOOR < 1) throw new FloorsDone('L0');

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
    await leave('Level2_Auditorium');
    if (LAST_FLOOR < 2) throw new FloorsDone('L1');

    // ================================================================== Level 2: the Auditorium, crossed
    await shot('L2-tracker.png');
    await spawnCheck('Level2_Auditorium', first ? 'Grace' : 'Noise');
    f = await floorOf();
    t = await tracker();
    const tower2 = await G((g) => g.route(g.level).tower);
    const towerWord = { East: 'east', NorthEast: 'north-east', SouthEast: 'south-east' }[tower2];
    check('L2: no item and no lock: the exit is open from the start and the tracker shows the way to the stairwell',
      f.unlocked && f.door === 'Open' && Object.keys(f.carry).length === 0 && t.title === null &&
      f.tracker === null && t.steps.length === 1 && t.steps[0] === 'Get to the stairwell' && f.steps.ReachExit === 0 &&
      !!towerWord && (await G((g) => g.objectives.line.textContent)) === `Find the ${towerWord} stairwell`, { f, t, tower2 });
    s = await G((g) => ({ locks: g.world.entities('ExitLock', g.level).length, items: g.world.entities('Fuse', g.level).length +
      g.world.entities('MasterKeys', g.level).length, picks: Object.keys(g.run.plan.objectives) }));
    check('L2: nothing to find or unlock (no ExitLock, no item, no picks)', s.locks === 0 && s.items === 0 &&
      !s.picks.includes('Level2_Auditorium'), s);
    await leave('Level3_Roof');
    s = await G((g) => ({ done: g.floors.floor('Level2_Auditorium').done('ReachExit'), cleared: g.cleared.has('Level2_Auditorium') }));
    check('L2: the crossing is done once the squad leaves it', s.done && s.cleared, s);
    if (LAST_FLOOR < 3) throw new FloorsDone('L2');

    // ================================================================== Level 3: the roof, the jump, the landing
    await ff(2);
    const arrival = await G((g) => {
      const r = g.run.routes.Level2_Auditorium;
      const door = g.level3.roofDoor();
      const geo = g.level3.geo;
      const root = g.env.rootPosition();
      const inRect = (b, p) => p.x >= b.minX && p.x <= b.maxX && p.z >= b.minZ && p.z <= b.maxZ;
      return { housing: geo.housingId, want: r.entryRoomOfNextLevel, door: door && door.id, wantDoor: r.entryDoorIds[0],
        doorState: door && door.state, inHousing: g.world.inRoom(geo.housingId, root),
        behindIn: inRect(geo.housing, geo.behindPosition), slot: r.slot, phase: g.level3.phase,
        held: !!g.level3.handle, hidden: g.creature.isHidden() };
    });
    check(`L3: the roof follows the arrival housing (${arrival.slot}): its roof door opens, the Creature waits hidden`,
      arrival.housing === arrival.want && arrival.door === arrival.wantDoor && arrival.inHousing && arrival.behindIn &&
      arrival.doorState === 'Open' && arrival.phase === 'Arrival' && arrival.held && arrival.hidden, arrival);
    if (arrival.slot !== 'Middle') {
      await G((g) => {
        const geo = g.level3.geo;
        const p = geo.doorway.clone().addScaledVector(geo.out, 14);
        p.y = geo.doorway.y + 3;
        const yaw = Math.atan2(geo.out.x, geo.out.z);
        g.env.teleport({ position: p, yaw });
        g.env.setLook(yaw, 0.05);
        g.traps.noteTeleport();
      });
      await ff(0.4);
      await shot('route-roof-corner-housing.png');
    }
    await shot('L3-tracker.png');
    s = await G((g) => ({ packs: g.parachute.packs.length, free: g.parachute.packs.filter((x) => !x.taken && x.handle).length,
      floor: !!g.floors.floor('Level3_Roof') }));
    check('L3: no roof objective: every pack in the crate can be taken from the start', s.packs === 4 && s.free === 4 && !s.floor, s);
    // out on the roof: the wait behind the door runs out (the grace) and the door is smashed
    await G((g) => {
      const geo = g.level3.geo;
      const p = geo.doorway.clone().addScaledVector(geo.out, 16);
      p.y = geo.doorway.y + 3;
      g.env.teleport({ position: p, yaw: Math.atan2(geo.out.x, geo.out.z) });
      g.traps.noteTeleport();
    });
    await ff(1);
    const grace = await G((g) => g.level3.firstOutAt !== null && (g.level3.firstOutAt + 20) - g.env.now());
    await ff(Math.max(0, grace) + 7);
    s = await G((g, dev, id) => ({ door: g.doors.get(id).state, released: !!g.level3.smash && g.level3.smash.released,
      phase: g.level3.phase }), arrival.wantDoor);
    check(`L3: the arrival housing's roof door (${arrival.wantDoor}) smashed after the grace, the Creature let go from behind it`,
      s.door === 'Smashed' && s.released && s.phase === 'Chase', s);
    if (first) {
      // the first seed takes a pack from the crate
      const pack = await G((g) => g.parachute.freePackPoint(g.env.rootPosition()).toArray());
      await standAt(pack, { reach: [2, 2.6, 1.6], expect: /Parachute/ });
      await hold(0.9);
      s = await G((g) => g.parachute.state);
      check('L3: a parachute pack taken', s === 'Packed', s);
    } else {
      s = await G((g) => g.parachute.state);
      check('L3: no pack taken (this seed steps off without one)', s === 'None', s);
    }
    await G((g) => {
      const gap = g.parachute.geo.gap;
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
    s = await G((g) => ({ chute: g.parachute.state, pack: g.parachute.hasPack(), life: g.life.state }));
    check(first ? 'L3: off the gap with the pack: freefall' : 'L3: off the gap without a pack: a spare buckled on, freefall (nobody dies in the fall)',
      s.chute === 'Freefall' && s.pack && s.life === 'Alive', s);
    await tab.keyboard.press('Space');
    // the descent stepped in the page one frame at a time (no real frames in between) up to the touchdown, then until the
    // stage changes, at most one roof check (the roof's checks run at ServerTickHz, as on Roblox: Roof.spec times the
    // landing within that of the touchdown)
    s = await tab.evaluate(({ tick, limit }) => {
      const loop = window.__rovloc.engine.loop;
      const g = window.__rovlocGame.game;
      const e = window.__rovloc.engine;
      loop.stop();
      const render = e.renderer.render;
      e.renderer.render = () => {};
      let changedAt = null;
      const off = g.stageActivated.connect(() => {
        if (changedAt === null) changedAt = g.env.now();
      });
      try {
        for (let i = 0; i < limit * 30 && g.parachute.state !== 'Landed'; i++) loop._run(1 / 30, 1 / 30);
        const landedAt = g.parachute.landedAt;
        const ledge = { phase: g.level3.phase, ledgeAt: g.level3.ledgeAt, hidden: g.creature.isHidden() };
        while (g.parachute.state === 'Landed' && changedAt === null && g.env.now() - landedAt < tick) loop._run(1 / 30, 1 / 30);
        return { chute: g.parachute.state, stage: g.stage, lock: g.controlLock(), life: g.life.state, ledge, landedAt,
          doneAfter: changedAt === null || landedAt === null ? null : changedAt - landedAt };
      } finally {
        off();
        e.renderer.render = render;
        loop.start();
      }
    }, { tick: 1 / GameConfig.ServerTickHz, limit: 15 });
    // (the roof is done in the touchdown's own tick on some seeds, so it may have let the Creature go by then)
    check('L3: the Creature was put on the ledge over the jumper before the touchdown, shown', s.ledge.ledgeAt !== null &&
      s.landedAt !== null && s.ledge.ledgeAt <= s.landedAt && !s.ledge.hidden, s);
    check('L3: the cord, landed: the roof done at the touchdown (within one roof check), on to City1_Rooftops; the ' +
      'landing hold released at once', s.chute === 'Landed' && s.stage === 'City1_Rooftops' && s.doneAfter !== null &&
      s.doneAfter >= 0 && s.doneAfter <= 1 / GameConfig.ServerTickHz + 1e-6 && s.lock !== 'Parachute' &&
      s.life === 'Alive', s);
    // the stages still to be built play their stand-ins, each to its own end, then the results
    await ff(28);
    s = await G((g) => ({ match: g.phase, cleared: [...g.cleared], view: g.parachute.viewHeld }));
    check('the stand-ins of the city, the runway and the Bahamas play out; the view is the player\'s again; the results ' +
      'follow', s.match === 'Results' && !s.view &&
      ['City1_Rooftops', 'City2_Airport', 'Runway', 'Bahamas'].every((id) => s.cleared.includes(id)), s);
    await ff(1.5);
    await shot('L3-results.png');
    s = await G((g) => ({ open: g.results.showing, title: g.results.title.textContent }));
    check('the ESCAPED results', s.open && /ESCAPED/.test(String(s.title)), s);
  } catch (err) {
    if (err instanceof FloorsDone) {
      console.log(`  stopped after ${err.message} (--floors)`);
    } else {
      check('objective run completed', false, String(err && err.stack ? err.stack : err));
      try {
        await shot('99-failure.png');
      } catch { /* gone */ }
    }
  }
  const fatal = logs.filter((l) => /pageerror|error:|warning:/.test(l));
  check('no console errors or warnings', fatal.length === 0, fatal.slice(0, 8));
  await tab.close();
}

await browser.close();
console.log(`screenshots in ${shots}:\n${shotsTaken.map((x) => `  ${path.basename(x)}`).join('\n')}`);
console.log(`routes (L0/L1/L2 exits): ${routeLog.map((r) => `seed ${r.seed} ${r.slots}`).join('; ')}`);
console.log(failures.length ? `\n${failures.length} FAILED:\n  ${failures.join('\n  ')}` : '\nall checks passed');
process.exit(failures.length ? 1 : 0);
