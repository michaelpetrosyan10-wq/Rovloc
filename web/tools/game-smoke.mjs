// game-smoke.mjs: the game's headless smoke run (W4) with the pre-installed Playwright Chromium.
//
//   node tools/game-smoke.mjs [--html <page>] [--shots <dir>] [--no-build]
//
// Builds the game test page (tools/game-build.mjs, unless --html names one), opens it with ?dev and plays:
//   title -> walkthrough -> lobby -> onto a ready pad -> countdown -> deploy -> the Back Lot's stand-in (its name and
//   the honest line; Skip) -> Level 0: walk onto a bear trap ->
//   look down and pry free -> walk into the stairwell airlock -> it seals -> Level 1 starts;
// then each floor's signature moment:
//   Level 1 the classroom scare (walking into Classroom 108), the gate slamming, and the bypass vent (kick the grate:
//   its panel and screws land in both looks; crouch in, crawl the duct, kick the far grate, out beyond the gate),
//   Escape pausing the clock and closing again, a locker check (hiding, HOLD YOUR BREATH, held through the peek,
//   stepping out);
//   then, by the dev level skip with the Creature told to ignore the player (so a hunt cannot end the run before every
//   moment is checked): Level 2 the Auditorium (its exit open from the start, the Creature held at its start), Level 3
//   the roof (the door smash, the jump, the canopy, the Creature on the ledge, the landing: the roof done within one
//   roof check); then every stage still on the stand-in (City1_Rooftops held to its own end, City2_Airport, Runway and
//   Bahamas skipped, each its card or name), ESCAPED and the chapter strip 8 / 8 on the results. Play Again, and the
//   same on Nightmare: the Back Lot, the four school levels (one respawn for the run), the roof's jump, the stand-ins,
//   the results. The stages still on the stand-in are printed at the end.
// Every step asserts the game's state; each moment is screenshotted into the shots directory (default
// build/cache/game-shots). Headless WebGL is SwiftShader (slow), so the game clock is fast-forwarded between shots by
// stepping the engine loop with rendering skipped. Exit code 1 on any failure.

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
const shots = path.resolve(opt('--shots', path.join(web, 'build/cache/game-shots')));
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
const results = [];
const logs = [];
const IGNORED_CONSOLE = /useProgram|Shader Error|WebGL|GPU stall|AudioContext/;

function check(name, ok, detail) {
  results.push({ name, ok: !!ok, detail });
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail !== undefined ? ` ${JSON.stringify(detail)}` : ''}`);
  if (!ok) failures.push(name);
}

const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader',
  '--ignore-gpu-blocklist', '--autoplay-policy=no-user-gesture-required', '--enable-webgl'] });
const tab = await browser.newPage({ viewport: { width: 1280, height: 720 } });
// Headless Chromium grants pointer lock after a key press and drops it again at random moments, and a lost lock
// opens the pause menu (as Escape does), which stops the game clock. The run steers with keys and setLook, so the
// lock is never requested here.
await tab.addInitScript(() => {
  Element.prototype.requestPointerLock = function requestPointerLock() {
    return Promise.resolve();
  };
});
tab.on('console', (m) => {
  if ((m.type() === 'error' || m.type() === 'warning') && !IGNORED_CONSOLE.test(m.text())) logs.push(`${m.type()}: ${m.text()}`);
});
tab.on('pageerror', (e) => logs.push(`pageerror: ${e.message}\n${e.stack}`));

/** Runs `fn(game, dev, arg)` in the page. */
const G = (fn, arg) => tab.evaluate(([src, a]) => {
  const w = window.__rovlocGame;
  // eslint-disable-next-line no-new-func
  return new Function('game', 'dev', 'arg', `return (${src})(game, dev, arg);`)(w.game, w.dev, a);
}, [fn.toString(), arg]);

/** Advances the game `seconds` at 30 Hz without rendering (SwiftShader is too slow to play in real time). */
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

/**
 * Screenshots the game at this exact game time: the loop is stopped, one frame is rendered (the clock not advanced)
 * and the page captured before the loop runs on.
 */
const shot = async (name) => {
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
  return file;
};

const state = () => G((g) => ({
  phase: g.phase, level: g.level, life: g.life.state, health: g.life.health, ctx: g.env.context(),
  ms: g.env.moveState(), root: g.env.rootPosition().toArray().map((v) => Math.round(v * 10) / 10),
}));

const walk = async (seconds, key = 'KeyW') => {
  await tab.keyboard.down(key);
  await ff(seconds);
  await tab.keyboard.up(key);
};

/**
 * The descent stepped in the page one frame at a time (no real frames in between) up to the touchdown (at most `limit`
 * seconds), then until the run's stage changes or one roof check (ServerTickHz) has passed: the stage then and how
 * long after the touchdown it changed.
 */
const landing = (limit) => tab.evaluate(({ tick, max }) => {
  const e = window.__rovloc.engine;
  const g = window.__rovlocGame.game;
  const loop = e.loop;
  loop.stop();
  const render = e.renderer.render;
  e.renderer.render = () => {};
  let changedAt = null;
  const off = g.stageActivated.connect(() => {
    if (changedAt === null) changedAt = g.env.now();
  });
  try {
    for (let i = 0; i < max * 30 && g.parachute.state !== 'Landed'; i++) loop._run(1 / 30, 1 / 30);
    const landedAt = g.parachute.landedAt;
    while (g.parachute.state === 'Landed' && changedAt === null && g.env.now() - landedAt < tick) loop._run(1 / 30, 1 / 30);
    return { chute: g.parachute.state, stage: g.stage, outcome: g.match.outcome, lock: g.controlLock(),
      doneAfter: changedAt === null || landedAt === null ? null : changedAt - landedAt };
  } finally {
    off();
    e.renderer.render = render;
    loop.start();
  }
}, { tick: 1 / GameConfig.ServerTickHz, max: limit });

/** Skips each of `stages` in turn (Skip on its stand-in), checking its card text where `cards` names one. */
const skipStandIns = async (stages, cards) => {
  const seen = [];
  for (const stage of stages) {
    const at = await G((g) => ({ stage: g.stage, standIn: g.standIn.stage(), title: g.standIn.title.textContent }));
    seen.push(at);
    if (at.stage !== stage || at.standIn !== stage || (cards[stage] && at.title !== cards[stage])) return { ok: false, seen };
    await tab.keyboard.press('Enter');
    await ff(2.2);
  }
  return { ok: true, seen };
};

let standIns = null;
const shotsTaken = [];
try {
  // a pinned run seed: the plan (which traps, where) is the same every smoke run
  await tab.goto(`file://${page}?dev&seed=1029`);
  await tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 180000 });
  check('boot', await tab.evaluate(() => !window.__rovloc.error), await tab.evaluate(() => window.__rovloc.error));
  await tab.waitForTimeout(1500);

  // ------------------------------------------------------------------------------------------- title + lobby
  check('title screen', (await G((g) => g.onboarding.mode)) === 'Title');
  // this page was built without --stamp: only a stamped build (a beta) names itself on the title
  const stamped = await G((g) => ({ stamp: g.env.buildStamp(), shown: g.onboarding.stamp ? g.onboarding.stamp.textContent : null }));
  check('a build without a stamp shows none on the title', stamped.stamp === '' && stamped.shown === null, stamped);
  shotsTaken.push(await shot('01-title.png'));
  await G((g) => g.env.setSetting('TutorialDone', false));
  await tab.keyboard.press('Enter');
  await tab.waitForTimeout(600);
  check('walkthrough opens on PLAY', (await G((g) => g.onboarding.mode)) === 'Walkthrough');
  shotsTaken.push(await shot('02-walkthrough.png'));
  for (let i = 0; i < 6; i++) await tab.keyboard.press('ArrowRight');
  await tab.keyboard.press('Enter');
  await tab.waitForTimeout(800);
  let s = await state();
  check('lobby after the walkthrough', s.phase === 'Lobby' && (await G((g) => g.onboarding.mode)) === 'Hidden', s);
  shotsTaken.push(await shot('03-lobby.png'));
  // up the bus's rear step and onto the nearest ready pad
  await G((g) => {
    const e = g.lobby.bus.entrance;
    const pad = g.lobby.pads.map((x) => x.centre).sort((a, b) => Math.hypot(a.x - e.x, a.z - e.z) - Math.hypot(b.x - e.x, b.z - e.z))[0];
    const yaw = Math.atan2(-(pad.x - e.x), -(pad.z - e.z));
    g.env.teleport({ position: { x: e.x, y: e.y + 3, z: e.z }, yaw });
    window.__smokePad = Math.hypot(pad.x - e.x, pad.z - e.z);
  });
  await ff(0.2);
  const padDistance = await tab.evaluate(() => window.__smokePad);
  await walk(Math.max(0.1, padDistance / 11));
  await ff(0.3);
  s = await G((g) => ({ phase: g.phase, ready: g.lobby.ready, pad: g.lobby.onPadId }));
  check('ready pad starts the countdown', s.phase === 'Countdown' && s.ready, s);
  shotsTaken.push(await shot('04-countdown.png'));
  await ff(9);
  await ff(1.5);
  s = await G((g) => ({ phase: g.phase, stage: g.stage, level: g.level, standIn: g.standIn.stage(), lock: g.controlLock(),
    title: g.standIn.title.textContent, line: g.standIn.line.textContent, lives: g.life.lives }));
  check('deployed: the run starts on its first stage, the Back Lot, on the stand-in (its name, the honest line, held)',
    s.phase === 'InRun' && s.stage === 'BackLot' && s.level === null && s.standIn === 'BackLot' && s.lock === 'Cutscene' &&
    /BACK LOT/.test(s.title) && /still being built/.test(s.line), s);
  shotsTaken.push(await shot('05a-standin.png'));
  await tab.keyboard.press('Enter');
  await ff(2.5);
  s = await state();
  const lives = await G((g) => g.life.lives);
  check('Skip: on into Level 0 (Standard: one stage respawn, the get-up unused)', s.phase === 'InRun' &&
    s.level === 'Level0_Basement' && s.life === 'Alive' && lives.stage === 1 && !lives.getUpUsed, { ...s, lives });
  await G((g) => g.env.setFlashlight(true));
  shotsTaken.push(await shot('05-level0.png'));

  // ------------------------------------------------------------------------------------------- Level 0: a trap
  const trap = await G((g) => {
    const t = g.traps.traps.find((x) => x.state === 'Armed' && x.level === g.level);
    // walk at it from a side with clear floor (a guard trap stands in a bay's mouth): the first of eight headings whose
    // start 2.5 studs off and the floor 2.5 studs past the trap are in clear line of it, at the shin and the chest
    const V = t.floor.constructor;
    const clear = (a, b) => [1, 3].every((h) => g.env.lineClear(new V(a.x, a.y + h, a.z), new V(b.x, b.y + h, b.z)));
    let from = null;
    for (let k = 0; k < 8 && !from; k++) {
      const a = (k * Math.PI) / 4;
      const dx = Math.sin(a);
      const dz = Math.cos(a);
      const start = new V(t.floor.x + dx * 2.5, t.floor.y, t.floor.z + dz * 2.5);
      const past = new V(t.floor.x - dx * 2.5, t.floor.y, t.floor.z - dz * 2.5);
      if (clear(start, t.floor) && clear(t.floor, past)) from = start;
    }
    from = from || new V(t.floor.x, t.floor.y, t.floor.z + 2.5);
    const yaw = Math.atan2(-(t.floor.x - from.x), -(t.floor.z - from.z));
    g.env.teleport({ position: { x: from.x, y: from.y + 3, z: from.z }, yaw });
    g.traps.noteTeleport();
    return t.id;
  });
  await tab.waitForTimeout(300);
  await walk(0.9);
  await ff(1.2);
  s = await G((g) => ({ caught: !!g.traps.caught, ms: g.env.moveState(), health: g.life.health, ctx: g.env.context() }));
  check('walking onto the trap springs it (35 damage, Trapped)', s.caught && s.ms === 'Trapped' && s.health === 65, { trap, ...s });
  shotsTaken.push(await shot('06-trapped.png'));
  await G((g) => g.env.setLook(g.env.look().yaw, -1.2));
  await tab.keyboard.down('KeyE');
  await ff(2.5);
  shotsTaken.push(await shot('07-prying.png'));
  await ff(3);
  await tab.keyboard.up('KeyE');
  await ff(0.5);
  s = await G((g) => ({ caught: !!g.traps.caught, ms: g.env.moveState(), ctx: g.env.context() }));
  check('looking down and holding E pries the trap open', !s.caught && s.ms !== 'Trapped' && s.ctx === 'OnFoot', s);

  // ------------------------------------------------------------------------------------------- the airlock -> Level 1
  // the exit stays locked until the floor's objective is done (tools/objective-run.mjs plays the objectives for real)
  s = await G((g) => ({ door: g.doors.get(g.route(g.level).exitDoorIds[0]).state, open: g.floors.exitOpen(g.level) }));
  check('the basement exit is locked until its objective is done', s.door === 'Locked' && !s.open, s);
  await G((g, dev) => dev.completeObjective());
  await ff(3);
  await G((g) => {
    const v = g.airlock.volumes[0] || g.world.checkpointVolumes(g.level)[0];
    g.env.teleport({ position: { x: v.cframe[0] - 14, y: v.cframe[1] + 0.5, z: v.cframe[2] }, yaw: -Math.PI / 2 });
    g.traps.noteTeleport();
  });
  await tab.waitForTimeout(300);
  // well into the vestibule, clear of the fire door's sweep (the never-crush hold would keep it open until the seal timeout)
  await walk(1.5);
  shotsTaken.push(await shot('08-airlock.png'));
  await ff(5);
  s = await G((g) => ({ phase: g.phase, level: g.level, cleared: g.stats.get('FloorsCleared'), life: g.life.state }));
  check('the airlock seals behind the player and Level 1 starts', s.phase === 'InRun' && s.level === 'Level1_Hallways' &&
    s.cleared === 1 && s.life === 'Alive', s);
  await G((g) => g.match.spawnAt('Level1_Hallways', 0));
  await ff(0.5);
  shotsTaken.push(await shot('09-level1.png'));

  // ------------------------------------------------------------------------------------------- Level 1: the scare
  // in through the ajar door of Classroom 108, facing the corner it waits in (the scare's Classroom trigger)
  await G((g) => {
    const T = g.env.THREE;
    const door = g.doors.find('Level1_Hallways', 'ClassroomDoor');
    const room = g.world.room('L1_Classroom_108');
    const centre = new T.Vector3(room.rect.x + room.rect.w / 2, room.floorY + 3, room.rect.z + room.rect.d / 2);
    const p = new T.Vector3(door.centre.x, room.floorY + 3, door.centre.z).lerp(centre, 0.35);
    const head = g.level1.geo.posePosition.clone().add(new T.Vector3(0, 1.6, 0));
    const d = head.clone().sub(p);
    g.env.teleport({ position: p, yaw: Math.atan2(-d.x, -d.z) });
    g.env.setLook(Math.atan2(-d.x, -d.z), Math.atan2(d.y - 1.5, Math.hypot(d.x, d.z)));
    g.traps.noteTeleport();
  });
  await ff(0.75);
  s = await G((g) => ({ ran: g.level1.hasRun(), full: !!(g.level1.scene && g.level1.scene.full), pending: g.level1.pending(),
    creature: g.creature.getState() }));
  check('stepping on the glass sets the classroom scare off', s.ran, s);
  shotsTaken.push(await shot('10-l1-scare.png'));
  await ff(4);
  s = await G((g) => ({ gate: g.doors.find('Level1_Hallways', 'HallwayGate').state }));
  check('the hallway gate slams Locked', s.gate === 'Locked', s);
  shotsTaken.push(await shot('11-l1-gate.png'));

  // the dev jumps below run with the Creature told to ignore the player (DevTools "ignoreme"), so a hunt it starts
  // on its own cannot end the run before each floor's moment has been checked
  await G((g) => g.creature.devCommand('ignoreme'));

  // ------------------------------------------------------------------------------------------- Level 1: the bypass vent
  const vent = await G((g) => {
    const T = g.env.THREE;
    const grates = g.vents.gratesOn('Level1_Hallways').filter((x) => x.info.attributes.CriticalPath);
    const east = grates.reduce((a, b) => (a.centre.x > b.centre.x ? a : b));
    const west = grates.reduce((a, b) => (a.centre.x < b.centre.x ? a : b));
    const p = new T.Vector3().setFromMatrixPosition(east.exit).add(new T.Vector3(0, 3, 0));
    const yaw = Math.atan2(-east.exit.elements[8], -east.exit.elements[10]); // facing the wall (against the anchor)
    g.env.teleport({ position: p, yaw });
    g.env.setLook(yaw, -0.2);
    g.traps.noteTeleport();
    return { east: east.id, west: west.id, westAt: west.centre.toArray() };
  });
  await ff(0.3);
  await tab.keyboard.press('KeyC');
  await ff(0.3);
  await tab.keyboard.press('KeyR');
  await ff(0.6);
  s = await G((g, dev, id) => {
    // the panel and the screws landed in both looks: each leaf's Rusted twin (hidden on this never-locked grate) posed
    // with it, so a run that shows the rusted look sees it move the same way
    const e = g.env.entity(id);
    const apart = ['Panel', 'Screw1', 'Screw2', 'Screw3', 'Screw4'].filter((leaf) => {
      const a = e.nodes.get(leaf);
      const b = e.nodes.get(`${leaf}/Rusted`);
      return !a || !b || !a.matrix.elements.every((v, i) => Math.abs(v - b.matrix.elements[i]) < 1e-4) || !b.hidden || a.hidden;
    });
    const moved = !e.nodes.get('Panel').matrix.equals(e.nodes.get('Panel').restWorld);
    return { state: g.vents.stateOf(id), ms: g.env.moveState(), apart, moved };
  }, vent.east);
  check('kicking the bypass vent grate open', s.state === 'Kicked', s);
  check('the kicked panel and screws landed in both looks (the galvanized one shown)', s.moved && s.apart.length === 0, s);
  await walk(1.2);
  s = await G((g) => ({ inVent: g.vents.inVent(), ms: g.env.moveState(), ctx: g.env.context() }));
  check('crouching into the open grate starts the crawl', s.inVent && s.ctx === 'Vent', s);
  await walk(1.5);
  shotsTaken.push(await shot('12-l1-vent.png'));
  // crawl on toward the far grate; kick it from inside, then out beyond the gate
  for (let i = 0; i < 24; i++) {
    const at = await G((g, dev, w) => {
      const root = g.env.rootPosition();
      const yaw = Math.atan2(-(w[0] - root.x), -(w[2] - root.z));
      g.env.setLook(yaw, 0);
      return { inVent: g.vents.inVent(), d: Math.hypot(w[0] - root.x, w[2] - root.z) };
    }, vent.westAt);
    if (!at.inVent) break;
    if (at.d < 4.5) {
      await tab.keyboard.press('KeyR');
      await ff(0.4);
    }
    await walk(0.8);
  }
  s = await G((g) => ({ inVent: g.vents.inVent(), zone: g.zoneId(), crawled: g.stats.get('VentsCrawled'),
    beyond: g.level1.geo.beyond.has(g.zoneId()) }));
  check('through the bypass vent and out beyond the gate', !s.inVent && s.beyond && s.crawled >= 1, s);
  shotsTaken.push(await shot('13-l1-beyond.png'));

  // ------------------------------------------------------------------------------------------- the pause menu
  // played alone, Escape's menu stops the game clock until it closes (the loop held from the clock's read to the
  // press, so no real-time frame between them moves it: only ff's frames do)
  const before = await G((g) => {
    window.__rovloc.engine.loop.stop();
    return g.env.now();
  });
  await tab.keyboard.press('Escape');
  await ff(2);
  s = await G((g, dev, t) => ({ open: g.env.menuOpen(), advanced: Math.round((g.env.now() - t) * 100) / 100 }), before);
  check('Escape pauses the run', s.open && s.advanced < 0.1, s);
  await tab.keyboard.press('Escape');
  await ff(1);
  s = await G((g, dev, t) => ({ open: g.env.menuOpen(), advanced: Math.round((g.env.now() - t) * 100) / 100 }), before);
  check('closing the menu resumes it', !s.open && s.advanced > 0.8, s);

  // ------------------------------------------------------------------------------------------- Level 1: a locker
  await G((g) => g.lockers.devCheck());
  await ff(2.2);
  s = await G((g) => ({ hiding: g.lockers.occupiedId(), ms: g.env.moveState(), ctx: g.env.context(),
    window: !!(g.lockers.session && g.lockers.session.window) }));
  check('climbing into a locker and its breath check', !!s.hiding && s.ms === 'Hiding' && s.ctx === 'Locker' && s.window, s);
  await tab.keyboard.down('Space');
  await ff(0.8);
  shotsTaken.push(await shot('14-l1-holdbreath.png'));
  await ff(6);
  await tab.keyboard.up('Space');
  await ff(0.3);
  s = await G((g) => ({ verdict: g.lockers.session && g.lockers.session.window ? g.lockers.session.window.verdict : null,
    life: g.life.state, stat: g.stats.get('LockersHidden') }));
  check('holding the breath through the peek is HiddenSafe', s.verdict === 'HiddenSafe' && s.life === 'Alive', s);
  shotsTaken.push(await shot('15-l1-safe.png'));
  await tab.keyboard.press('KeyE');
  await ff(2);
  s = await G((g) => ({ hiding: g.lockers.occupiedId(), ms: g.env.moveState(), ctx: g.env.context() }));
  check('stepping out of the locker', !s.hiding && s.ms !== 'Hiding' && s.ctx === 'OnFoot', s);

  // ------------------------------------------------------------------------------------------- Level 2: the Auditorium
  await G((g, dev) => dev.gotoLevel('Level2_Auditorium'));
  await ff(1);
  s = await G((g) => {
    const f = g.floors.floor(g.level);
    const door = g.doors.get(g.route(g.level).exitDoorIds[0]);
    return { level: g.level, phase: g.phase, unlocked: f.unlocked, door: door.state, holding: g.floors.spawns.holding(g.level),
      creature: g.creature.getState() };
  });
  check('dev skip to the Auditorium: the exit open from the start, the Creature held at its start for its grace',
    s.level === 'Level2_Auditorium' && s.phase === 'InRun' && s.unlocked && s.door === 'Open' && s.holding &&
    s.creature === 'Scripted', s);
  shotsTaken.push(await shot('16-l2-auditorium.png'));

  // ------------------------------------------------------------------------------------------- Level 3: the roof
  await G((g, dev) => dev.gotoLevel('Level3_Roof'));
  await ff(1.5);
  s = await G((g) => ({ phase: g.level3.phase, door: g.level3.roofDoor().state, held: !!g.level3.handle }));
  check('the roof: the Creature held behind the arrival housing\'s door, the door swung open', s.phase === 'Arrival' &&
    s.door === 'Open' && s.held, s);
  await G((g, dev) => dev.roof('smash'));
  await ff(4.3);
  shotsTaken.push(await shot('17-l3-smash.png'));
  await ff(2);
  s = await G((g) => ({ phase: g.level3.phase, door: g.level3.roofDoor().state, released: g.level3.smash && g.level3.smash.released }));
  check('the roof door smashed and the Creature let go', s.door === 'Smashed' && s.released && s.phase === 'Chase', s);
  await G((g, dev) => dev.signature('Level3_Roof'));
  await ff(1.5);
  s = await G((g) => ({ chute: g.parachute.state, phase: g.level3.phase }));
  check('off the gap with a pack: the canopy opens', s.chute === 'Canopy' || s.chute === 'Landed', s);
  shotsTaken.push(await shot('18-l3-canopy.png'));
  await ff(2.5);
  s = await G((g) => ({ phase: g.level3.phase, hidden: g.creature.isHidden(), chute: g.parachute.state }));
  check('the Creature stands on the ledge over the jumper', s.phase === 'Ledge' && !s.hidden, s);
  shotsTaken.push(await shot('19-l3-ledge.png'));
  // the rest of the descent stepped in the page one frame at a time (no real frames in between) up to the touchdown, then
  // one roof check (the roof's checks run at ServerTickHz, as on Roblox: Roof.spec times the escape within that)
  s = await landing(10);
  check('landed below: the roof done at the touchdown (within one roof check), on to the next stage; the landing hold ' +
    'released', s.chute === 'Landed' && s.stage === 'City1_Rooftops' && s.doneAfter !== null && s.doneAfter >= 0 &&
    s.doneAfter <= 1 / GameConfig.ServerTickHz + 1e-6 && s.lock !== 'Parachute' && s.outcome === 'Pending', s);
  // the stages still to be built: each its stand-in (its card, the honest line), the first one held to its end
  await ff(0.5);
  s = await G((g) => ({ stage: g.stage, standIn: g.standIn.stage(), title: g.standIn.title.textContent, lock: g.controlLock() }));
  check('City1_Rooftops: the stand-in shows its card (PART TWO · THE CITY · ROOFTOPS), the controls held', s.stage === 'City1_Rooftops' &&
    s.standIn === 'City1_Rooftops' && s.title === 'PART TWO · THE CITY · ROOFTOPS' && s.lock === 'Cutscene', s);
  shotsTaken.push(await shot('20-standin-city1.png'));
  await ff(6.5);
  s = await G((g) => ({ stage: g.stage, title: g.standIn.title.textContent }));
  check('the stand-in holds, fades and moves on by itself: City2_Airport (THE CITY · AIRPORT)', s.stage === 'City2_Airport' &&
    s.title === 'THE CITY · AIRPORT', s);
  s = await skipStandIns(['City2_Airport', 'Runway', 'Bahamas'], { Runway: 'WHEELS UP', Bahamas: 'THE BAHAMAS' });
  check('Skip goes on through the Runway (WHEELS UP) and the Bahamas (no card: its name) to the results', s.ok, s);
  await ff(1.5);
  s = await G((g) => ({ phase: g.phase, showing: g.results.showing, title: g.results.title.textContent,
    chapters: g.results.chapters.textContent, outcome: g.match.summary && g.match.summary.outcome }));
  check('after the last stage the run ends: the ESCAPED results, the chapter strip 8 / 8', s.phase === 'Results' && s.showing &&
    s.outcome === 'Escaped' && /ESCAPED/.test(s.title) && s.chapters === 'CHAPTER 8 / 8', s);
  shotsTaken.push(await shot('21-results.png'));

  // ------------------------------------------------------------------------------------------- Nightmare: every stage again
  await G((g) => g.match.pressPlayAgain());
  await ff(2);
  s = await G((g) => ({ phase: g.phase }));
  check('Play Again: back in the lobby', s.phase === 'Lobby' || s.phase === 'Countdown', s);
  await G((g, dev) => {
    dev.deploy('Nightmare');
  });
  await ff(2);
  s = await G((g) => ({ stage: g.stage, difficulty: g.run && g.run.difficulty, standIn: g.standIn.stage() }));
  check('Nightmare: the run starts on the Back Lot\'s stand-in', s.stage === 'BackLot' && s.difficulty === 'Nightmare' &&
    s.standIn === 'BackLot', s);
  await tab.keyboard.press('Enter');
  await ff(2.5);
  await G((g) => g.creature.devCommand('ignoreme'));
  s = await G((g) => ({ stage: g.stage, lives: g.life.lives }));
  check('Nightmare: Level 0 with no stage respawn and one for the run', s.stage === 'Level0_Basement' && s.lives.stage === 0 &&
    s.lives.run === 1, s);
  for (const level of ['Level1_Hallways', 'Level2_Auditorium', 'Level3_Roof']) {
    await G((g, dev, l) => dev.gotoStage(l), level);
    await ff(1);
    s = await G((g) => ({ stage: g.stage, level: g.level, phase: g.phase, lives: g.life.lives, life: g.life.state }));
    check(`Nightmare: ${level} (still one respawn for the run)`, s.stage === level && s.level === level && s.phase === 'InRun' &&
      s.life === 'Alive' && s.lives.stage === 0 && s.lives.run === 1, s);
  }
  await G((g, dev) => dev.roof('smash'));
  await ff(6.5);
  await G((g, dev) => dev.signature('Level3_Roof'));
  s = await landing(15);
  check('Nightmare: the jump and the landing move the run on to City1_Rooftops', s.chute === 'Landed' &&
    s.stage === 'City1_Rooftops', s);
  s = await skipStandIns(['City1_Rooftops', 'City2_Airport', 'Runway', 'Bahamas'], {});
  check('Nightmare: every stand-in skipped to the end', s.ok, s);
  await ff(1.5);
  s = await G((g) => ({ phase: g.phase, title: g.results.title.textContent, chapters: g.results.chapters.textContent,
    difficulty: g.match.summary && g.match.summary.difficulty }));
  check('Nightmare: the ESCAPED results, 8 / 8', s.phase === 'Results' && /ESCAPED/.test(s.title) &&
    s.chapters === 'CHAPTER 8 / 8' && s.difficulty === 'Nightmare', s);
  shotsTaken.push(await shot('22-results-nightmare.png'));
  standIns = await G((g) => g.stages.standIns());
} catch (err) {
  check('smoke run completed', false, String(err && err.stack ? err.stack : err));
  try {
    shotsTaken.push(await shot('99-failure.png'));
  } catch { /* the page is gone */ }
}

const fatal = logs.filter((l) => /pageerror|\[game\]|TypeError|ReferenceError/.test(l));
check('no page errors or game errors in the console', fatal.length === 0, fatal.slice(0, 8));
if (logs.length) console.log(`console (${logs.length}):\n${logs.slice(0, 30).join('\n')}`);
// the stages a release build may not have: still played by the stand-in (data-test --release fails on any)
console.log(`stages on the stand-in: ${standIns ? standIns.join(', ') || 'none' : '(not reached)'}`);
console.log(`screenshots in ${shots}:\n${shotsTaken.map((f) => `  ${path.basename(f)}`).join('\n')}`);
await browser.close();
console.log(failures.length ? `\n${failures.length} FAILED: ${failures.join(', ')}` : '\nall checks passed');
process.exit(failures.length ? 1 : 0);
