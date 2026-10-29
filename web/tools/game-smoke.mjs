// game-smoke.mjs: the game's headless smoke run (W4) with the pre-installed Playwright Chromium.
//
//   node tools/game-smoke.mjs [--html <page>] [--shots <dir>] [--no-build]
//
// Builds the game test page (tools/game-build.mjs, unless --html names one), opens it with ?dev and plays:
//   title -> walkthrough -> lobby -> onto a ready pad -> countdown -> deploy -> Level 0: walk onto a bear trap ->
//   look down and pry free -> walk into the stairwell airlock -> it seals -> Level 1 starts;
// then the dev level skip to each floor and its signature moment:
//   Level 1 the classroom scare (stepping on the glass), Level 2 a flask throw (the shatter cloud), Level 3 a locker
//   check (hiding, HOLD YOUR BREATH, held through the peek), Level 4 a pool grab (the struggle, mashed free), Level 5
//   the jump and the finale (the canopy, the lightning on the ledge, the landing, ESCAPED).
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

const shot = async (name) => {
  await tab.waitForTimeout(400);
  const file = path.join(shots, name);
  await tab.screenshot({ path: file, timeout: 180000 });
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
  await tab.goto(`file://${page}?dev`);
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
  await G((g) => {
    const e = g.lobby.bus.entrance;
    g.env.teleport({ position: { x: e.x, y: e.y + 3, z: e.z }, yaw: -Math.PI / 2 });
  });
  await tab.waitForTimeout(300);
  await walk(0.8);
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
    g.env.teleport({ position: { x: t.floor.x, y: t.floor.y + 3, z: t.floor.z + 7 }, yaw: 0 });
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
  await G((g) => {
    const v = g.airlock.volumes[0] || g.world.checkpointVolumes(g.level)[0];
    g.env.teleport({ position: { x: v.cframe[0] - 14, y: v.cframe[1] + 0.5, z: v.cframe[2] }, yaw: -Math.PI / 2 });
    g.traps.noteTeleport();
  });
  await tab.waitForTimeout(300);
  await walk(1.0);
  shotsTaken.push(await shot('08-airlock.png'));
  await ff(4);
  s = await G((g) => ({ phase: g.phase, level: g.level, cleared: g.stats.get('FloorsCleared'), life: g.life.state }));
  check('the airlock seals behind the player and Level 1 starts', s.phase === 'InRun' && s.level === 'Level1_Hallways' &&
    s.cleared === 1 && s.life === 'Alive', s);
  await G((g) => g.match.spawnAt('Level1_Hallways', 0));
  await ff(0.5);
  shotsTaken.push(await shot('09-level1.png'));

  // ------------------------------------------------------------------------------------------- Level 1: the scare
  await G((g) => {
    const glass = g.level1.geo.glassVolume;
    const door = g.doors.find('Level1_Hallways', 'ClassroomDoor');
    const p = { x: glass.cframe[0], y: glass.cframe[1] - glass.size[1] / 2 + 3, z: glass.cframe[2] };
    const yaw = Math.atan2(-(door.centre.x - p.x), -(door.centre.z - p.z));
    g.env.teleport({ position: p, yaw });
    g.traps.noteTeleport();
  });
  await ff(1.2);
  s = await G((g) => ({ ran: g.level1.hasRun(), full: !!(g.level1.scene && g.level1.scene.full), pending: g.level1.pending(),
    creature: g.creature.getState() }));
  check('stepping on the glass sets the classroom scare off', s.ran, s);
  shotsTaken.push(await shot('10-l1-scare.png'));
  await ff(4);
  s = await G((g) => ({ gate: g.doors.find('Level1_Hallways', 'HallwayGate').state }));
  check('the hallway gate slams Locked', s.gate === 'Locked', s);
  shotsTaken.push(await shot('11-l1-gate.png'));

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
  shotsTaken.push(await shot('12-l2-flask.png'));
  await G((g) => g.env.setLook(g.env.look().yaw, 0.05));
  const thrown = await G((g, dev) => dev.signature('Level2_ScienceHall'));
  await ff(0.6);
  s = await G((g) => ({ thrown: g.stats.get('FlasksThrown'), clouds: g.flasks.clouds.length, flights: g.flasks.flights.length }));
  check('a flask throw shatters into a cloud', thrown && s.thrown >= 1 && s.clouds >= 1, s);
  shotsTaken.push(await shot('13-l2-cloud.png'));

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
  shotsTaken.push(await shot('14-l3-holdbreath.png'));
  await ff(6);
  await tab.keyboard.up('Space');
  await ff(0.3);
  s = await G((g) => ({ verdict: g.lockers.session && g.lockers.session.window ? g.lockers.session.window.verdict : null,
    life: g.life.state, stat: g.stats.get('LockersHidden') }));
  check('holding the breath through the peek is HiddenSafe', s.verdict === 'HiddenSafe' && s.life === 'Alive', s);
  shotsTaken.push(await shot('15-l3-safe.png'));
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
  shotsTaken.push(await shot('16-l4-grab.png'));
  for (let i = 0; i < 30; i++) {
    await tab.keyboard.press('Space');
    await ff(0.1);
  }
  await ff(0.5);
  s = await G((g) => ({ grab: !!g.pool.grab, ms: g.env.moveState(), ctx: g.env.context(), life: g.life.state }));
  check('mashing STRUGGLE breaks free', !s.grab && s.ms !== 'Grabbed' && s.life === 'Alive', s);
  shotsTaken.push(await shot('17-l4-free.png'));
  await G((g) => g.level4.devFloodlights());
  await ff(2.5);
  s = await G((g) => ({ on: g.level4.flipped }));
  check('the floodlight switch throws', s.on, s);
  shotsTaken.push(await shot('18-l4-floodlights.png'));

  // ------------------------------------------------------------------------------------------- Level 5: the finale
  await G((g, dev) => dev.gotoLevel('Level5_Roof'));
  await ff(1);
  await G((g, dev) => dev.signature('Level5_Roof'));
  await ff(1.5);
  s = await G((g) => ({ chute: g.parachute.state, phase: g.level5.phase }));
  check('off the gap with a pack: the canopy opens', s.chute === 'Canopy' || s.chute === 'Landed', s);
  shotsTaken.push(await shot('19-l5-canopy.png'));
  await ff(2.2);
  s = await G((g) => ({ chute: g.parachute.state, phase: g.level5.phase, finale: !!g.level5.finale }));
  check('the finale starts over the canopy', s.finale, s);
  await G((g) => {
    const f = g.level5.finale;
    const target = f.startAt + 1.45;
    window.__smokeTarget = target - g.env.now();
  });
  const toReveal = await tab.evaluate(() => window.__smokeTarget);
  if (toReveal > 0) await ff(toReveal);
  shotsTaken.push(await shot('20-l5-lightning.png'));
  await ff(9);
  s = await G((g) => ({ chute: g.parachute.state, outcome: g.match.outcome, phase: g.phase }));
  check('landed below: ESCAPED', s.chute === 'Landed' && (s.outcome === 'Escaped' || s.phase === 'RunEnded' || s.phase === 'Results'), s);
  await ff(3);
  s = await G((g) => ({ phase: g.phase }));
  check('the results screen', s.phase === 'Results', s);
  shotsTaken.push(await shot('21-results.png'));
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
