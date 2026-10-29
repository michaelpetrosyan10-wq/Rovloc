// game-smoke.mjs: the game's headless smoke run (W4) with the pre-installed Playwright Chromium.
//
//   node tools/game-smoke.mjs [--html <page>] [--shots <dir>] [--no-build]
//
// Builds the game test page (tools/game-build.mjs, unless --html names one), opens it with ?dev and plays:
//   title -> walkthrough -> lobby -> onto a ready pad -> countdown -> deploy -> Level 0: walk onto a bear trap ->
//   look down and pry free -> walk into the stairwell airlock -> it seals -> Level 1 starts;
// then each floor's signature moment:
//   Level 1 the classroom scare (walking into Classroom 108), the gate slamming, and the bypass vent (kick the grate,
//   crouch in, crawl the duct, kick the far grate, out beyond the gate), Escape pausing the clock and closing again;
//   then, by the dev level skip with the Creature
//   told to ignore the player (so a hunt cannot end the run before every moment is checked): Level 2 a flask (held,
//   wound up with the aim arc, thrown, the shatter cloud), Level 3 a locker check (hiding, HOLD YOUR BREATH, held
//   through the peek, stepping out), Level 4 a pool grab (the struggle, mashed free) and the floodlight switch,
//   Level 5 the jump and the finale (the canopy, the lightning on the ledge, the landing, ESCAPED, the results).
// Every step asserts the game's state; each moment is screenshotted into the shots directory (default
// build/cache/game-shots). Headless WebGL is SwiftShader (slow), so the game clock is fast-forwarded between shots by
// stepping the engine loop with rendering skipped. Exit code 1 on any failure.

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

const shotsTaken = [];
try {
  // a pinned run seed: the plan (which traps, where) is the same every smoke run
  await tab.goto(`file://${page}?dev&seed=1029`);
  await tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 180000 });
  check('boot', await tab.evaluate(() => !window.__rovloc.error), await tab.evaluate(() => window.__rovloc.error));
  await tab.waitForTimeout(1500);

  // ------------------------------------------------------------------------------------------- title + lobby
  check('title screen', (await G((g) => g.onboarding.mode)) === 'Title');
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
  await ff(2.5);
  s = await state();
  check('deployed into Level 0', s.phase === 'InRun' && s.level === 'Level0_Basement' && s.life === 'Alive', s);
  await G((g) => g.env.setFlashlight(true));
  shotsTaken.push(await shot('05-level0.png'));

  // ------------------------------------------------------------------------------------------- Level 0: a trap
  const trap = await G((g) => {
    const t = g.traps.traps.find((x) => x.state === 'Armed' && x.level === g.level);
    g.env.teleport({ position: { x: t.floor.x, y: t.floor.y + 3, z: t.floor.z + 2.5 }, yaw: 0 });
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
  s = await G((g, dev, id) => ({ state: g.vents.stateOf(id), ms: g.env.moveState() }), vent.east);
  check('kicking the bypass vent grate open', s.state === 'Kicked', s);
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
  // played alone, Escape's menu stops the game clock until it closes
  const before = await G((g) => g.env.now());
  await tab.keyboard.press('Escape');
  await ff(2);
  s = await G((g, dev, t) => ({ open: g.env.menuOpen(), advanced: Math.round((g.env.now() - t) * 100) / 100 }), before);
  check('Escape pauses the run', s.open && s.advanced < 0.1, s);
  await tab.keyboard.press('Escape');
  await ff(1);
  s = await G((g, dev, t) => ({ open: g.env.menuOpen(), advanced: Math.round((g.env.now() - t) * 100) / 100 }), before);
  check('closing the menu resumes it', !s.open && s.advanced > 0.8, s);

  // ------------------------------------------------------------------------------------------- Level 2: a flask
  await G((g, dev) => dev.gotoLevel('Level2_ScienceHall'));
  await ff(1);
  s = await state();
  check('dev skip to Level 2', s.level === 'Level2_ScienceHall' && s.phase === 'InRun', s);
  await G((g) => {
    const f = g.flasks.pickupsOn('Level2_ScienceHall')[0];
    if (!f) return;
    g.env.teleport({ position: { x: f.position.x, y: f.position.y + 1.5, z: f.position.z + 3.5 }, yaw: 0 });
    g.env.setLook(0, -0.35);
  });
  await ff(0.3);
  shotsTaken.push(await shot('14-l2-flask.png'));
  // aim down the longest open line in the room so the flask carries before it breaks
  await G((g) => {
    const T = g.env.THREE;
    const eye = g.env.eye(new T.Vector3());
    let best = { yaw: 0, d: 0 };
    for (let i = 0; i < 24; i++) {
      const yaw = (i / 24) * Math.PI * 2;
      const dir = new T.Vector3(-Math.sin(yaw), 0, -Math.cos(yaw));
      const hit = g.env.raycast(eye, dir, 60, { ignoreEntities: false });
      const d = hit ? hit.distance : 60;
      if (Math.min(d, 30) > Math.min(best.d, 30)) best = { yaw, d };
    }
    g.env.setLook(best.yaw, 0.12);
  });
  // a flask in the hand, the throw held: the wind-up and the aim arc; released: the throw (the real input path)
  const given = await G((g) => g.flasks.give());
  await G((g) => g.env.injectAction('Throw', 'smoke', true));
  await ff(0.45);
  s = await G((g) => ({ held: !!g.flasks.held, winding: g.flasks.windStart !== null, arc: g.flasks.arcAlpha }));
  check('holding Throw winds up with the aim arc', given && s.held && s.winding && s.arc > 0.5, s);
  shotsTaken.push(await shot('15-l2-aim.png'));
  await G((g) => g.env.injectAction('Throw', 'smoke', false));
  await ff(0.9);
  const thrown = true;
  s = await G((g) => ({ thrown: g.stats.get('FlasksThrown'), clouds: g.flasks.clouds.length, flights: g.flasks.flights.length }));
  check('a flask throw shatters into a cloud', thrown && s.thrown >= 1 && s.clouds >= 1, s);
  shotsTaken.push(await shot('16-l2-cloud.png'));

  // ------------------------------------------------------------------------------------------- Level 3: a locker
  await G((g, dev) => dev.gotoLevel('Level3_Gymnasium'));
  await ff(1);
  await G((g, dev) => dev.signature('Level3_Gymnasium'));
  await ff(2.2);
  s = await G((g) => ({ hiding: g.lockers.occupiedId(), ms: g.env.moveState(), ctx: g.env.context(),
    window: !!(g.lockers.session && g.lockers.session.window) }));
  check('climbing into a locker and its breath check', !!s.hiding && s.ms === 'Hiding' && s.ctx === 'Locker' && s.window, s);
  await tab.keyboard.down('Space');
  await ff(0.8);
  shotsTaken.push(await shot('17-l3-holdbreath.png'));
  await ff(6);
  await tab.keyboard.up('Space');
  await ff(0.3);
  s = await G((g) => ({ verdict: g.lockers.session && g.lockers.session.window ? g.lockers.session.window.verdict : null,
    life: g.life.state, stat: g.stats.get('LockersHidden') }));
  check('holding the breath through the peek is HiddenSafe', s.verdict === 'HiddenSafe' && s.life === 'Alive', s);
  shotsTaken.push(await shot('18-l3-safe.png'));
  await tab.keyboard.press('KeyE');
  await ff(2);
  s = await G((g) => ({ hiding: g.lockers.occupiedId(), ms: g.env.moveState(), ctx: g.env.context() }));
  check('stepping out of the locker', !s.hiding && s.ms !== 'Hiding' && s.ctx === 'OnFoot', s);

  // ------------------------------------------------------------------------------------------- Level 4: the pool
  await G((g, dev) => dev.gotoLevel('Level4_FloodedPool'));
  await ff(1);
  await G((g, dev) => dev.signature('Level4_FloodedPool'));
  await ff(1.4);
  s = await G((g) => ({ grab: !!g.pool.grab, ms: g.env.moveState(), ctx: g.env.context(), swimming: g.pool.swimming() }));
  check('a pool grab drags the swimmer under', s.grab && s.ms === 'Grabbed' && s.ctx === 'Struggle', s);
  shotsTaken.push(await shot('19-l4-grab.png'));
  for (let i = 0; i < 30; i++) {
    await tab.keyboard.press('Space');
    await ff(0.1);
  }
  await ff(0.5);
  s = await G((g) => ({ grab: !!g.pool.grab, ms: g.env.moveState(), ctx: g.env.context(), life: g.life.state }));
  check('mashing STRUGGLE breaks free', !s.grab && s.ms !== 'Grabbed' && s.life === 'Alive', s);
  shotsTaken.push(await shot('20-l4-free.png'));
  await G((g) => g.level4.devFloodlights());
  await ff(2.5);
  s = await G((g) => ({ on: g.level4.flipped }));
  check('the floodlight switch throws', s.on, s);
  shotsTaken.push(await shot('21-l4-floodlights.png'));

  // ------------------------------------------------------------------------------------------- Level 5: the finale
  await G((g, dev) => dev.gotoLevel('Level5_Roof'));
  await ff(1);
  await G((g, dev) => dev.signature('Level5_Roof'));
  await ff(1.5);
  s = await G((g) => ({ chute: g.parachute.state, phase: g.level5.phase }));
  check('off the gap with a pack: the canopy opens', s.chute === 'Canopy' || s.chute === 'Landed', s);
  shotsTaken.push(await shot('22-l5-canopy.png'));
  await ff(2.2);
  s = await G((g) => ({ chute: g.parachute.state, phase: g.level5.phase, finale: !!g.level5.finale }));
  check('the finale starts over the canopy', s.finale, s);
  // the main strike of the first flash shows it on the ledge; the focus then holds on its face
  const untilFinale = (t) => G((g, dev, at) => g.level5.finale.startAt + at - g.env.now(), t);
  let wait = await untilFinale(1.48);
  if (wait > 0) await ff(wait);
  shotsTaken.push(await shot('23-l5-lightning.png'));
  wait = await untilFinale(2.4);
  if (wait > 0) await ff(wait);
  shotsTaken.push(await shot('24-l5-ledge.png'));
  await ff(7);
  s = await G((g) => ({ chute: g.parachute.state, outcome: g.match.outcome, phase: g.phase }));
  check('landed below: ESCAPED', s.chute === 'Landed' && (s.outcome === 'Escaped' || s.phase === 'RunEnded' || s.phase === 'Results'), s);
  await ff(3);
  s = await G((g) => ({ phase: g.phase }));
  check('the results screen', s.phase === 'Results', s);
  shotsTaken.push(await shot('25-results.png'));
} catch (err) {
  check('smoke run completed', false, String(err && err.stack ? err.stack : err));
  try {
    shotsTaken.push(await shot('99-failure.png'));
  } catch { /* the page is gone */ }
}

const fatal = logs.filter((l) => /pageerror|\[game\]|TypeError|ReferenceError/.test(l));
check('no page errors or game errors in the console', fatal.length === 0, fatal.slice(0, 8));
if (logs.length) console.log(`console (${logs.length}):\n${logs.slice(0, 30).join('\n')}`);
console.log(`screenshots in ${shots}:\n${shotsTaken.map((f) => `  ${path.basename(f)}`).join('\n')}`);
await browser.close();
console.log(failures.length ? `\n${failures.length} FAILED: ${failures.join(', ')}` : '\nall checks passed');
process.exit(failures.length ? 1 : 0);
