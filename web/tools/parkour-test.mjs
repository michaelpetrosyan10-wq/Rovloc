// parkour-test.mjs: the player's movement is a function of the 30 Hz tick, never of the frame rate (spec v2 §3.1,
// invariant I8), and its numbers hold: the jump apex, the top speeds, the sprint jump and the widest gap it crosses,
// the hurdle and the wall, the step-up limit, the latched presses, the render interpolation, the motion overrides and
// the eye the levels see. Named cases, each with its checks; a summary at the end and exit code 1 on any failure.
//
//   node tools/parkour-test.mjs [--no-build] [--only <case,...>] [--sandbox-html <page>] [--game-html <page>]
//
// Pages. The cases on the body run on the engine sandbox (build.mjs --sandbox --out, unminified: the engine alone, so
// nothing of the game's flow holds or moves the player): real level geometry where it exists (the Level 1 east
// corridor) and a fixture course built in the page where it does not (a slab far outside the school with a flat lane,
// step and mount blocks, slabs off the floor, a stair, a ramp, a ledge, a wall, the 2.6 hurdle, the 5.5 wall and
// runways with gaps). The motion-override and senses cases run on the game test page (game-build.mjs, unminified):
// the real vent rail, the real parachute and a walk through Level 1.
// The engine's requestAnimationFrame loop is held (an init script) and every frame is stepped here with a scripted
// frame time (20, 30, 60 or 144 fps, or an irregular sequence); input is applied on the tick it is due (a tick
// callback that runs before the player's), and the body is recorded at the end of every tick.
//
// Cases:
//   determinism   one tick-indexed input trace (walk, sprint, crouch, a standing jump, a sprint jump, stairs up and
//                 down, a ramp, stepping off a ledge, a jump against a wall, sliding along a wall, turning while
//                 moving; the same moves in the Level 1 corridor; held and repeated presses) gives the same tick
//                 states (<= 1e-6) at 20, 30, 60 and 144 fps, with irregular frame times and with stalls (frames far
//                 longer than the loop's 0.1 s clamp, which drops their time).
//   numbers       the jump apex 2.50 +/- 0.02 and the walk / sprint / crouch top speeds 11 / 19 / 5.5 within 1 %, at
//                 every frame rate.
//   jumps         the sprint jump on level ground (take-off to landing) is printed: the same at every frame rate
//                 and under 10 studs. A 2.6-high hurdle is mounted with a jump; a 5.5-high wall never is (standing
//                 against it or sprinting at it). The highest block a standing jump mounts is printed (at least the
//                 2.8 of the tallest hurdle, under the 5.5 of a wall).
//   gaps          the envelope (I9): the widest gap a free sprint jump crosses, from a runway onto a landing level
//                 with it and onto one 2 lower, the jump pressed on the last tick the runner stands (every phase of
//                 the run-up tried). Printed; the level one under 10 studs, a 12-stud gap never crossed, the same at
//                 20 and 144 fps.
//   step-up       the highest block walked onto without a jump: every block up to PhysicsConfig.StepHeight (1.6) is
//                 climbed, nothing from 2.0 up is (a hurdle starts at 2.4), the same at 20 and 144 fps, for blocks on
//                 the floor and for slabs off it. And nothing is ever walked through: a block the body does not
//                 stand on stops it at its near face.
//   presses       a held jump hops again on every landing; at a walk two Crouch presses on one tick change nothing and
//                 three toggle; a press and release on one tick still acts. A press still pending when the pause menu
//                 opens is dropped, a press made while the menu is open or the controls are locked does nothing.
//   interpolation at 144 fps with a constant velocity the drawn camera advances in near-equal steps (< 2 % spread)
//                 and the drawn root always lies between the last two tick states; a Jump press and a Crouch press
//                 that last a single 144 fps frame (no tick inside it) still act on the next tick. A teleport (from
//                 a tick before or after the player's, between two frames, or a bare write of the body's position)
//                 is a cut: no frame draws the root or the camera between the two places. The pause holds the drawn
//                 root still; a one-second stall moves it by the three ticks the loop runs and no further.
//   rules         src/game/rules/parkour.js replays every ParkourRules row of build/cache/golden.json (numbers within
//                 1e-9) and the engine's leap curve is the golden one; the spec's numbers, written here from its text.
//   slide         (lane x 40, a slide bar at x 70, a low ceiling at x 100) a Crouch press at a sprint slides on its tick
//                 for 0.70 s (21 ticks): 10.5 studs, the speed 17 falling to 13 tick by tick, the body 3.7 tall, the
//                 crouched eye, the Slide noise once, the press consumed (it ends standing), no jump, steering at most
//                 30 degrees a second; a walk's press crouches; standing, the bar (4.2 clear) stops the body, a slide
//                 and a crouch-walk pass under it; a slide ending under a low ceiling ends crouched. 20 / 30 / 60 / 144.
//   leap          (a runway 12 high, its lip, the 12 gap, pads level and 2 lower; strips A and B over them, a blind
//                 strip) on time (Jump in the strip) the leap starts on the tick, 18 ticks on the curve (to 2 past the
//                 far edge, apex 2) and lands on the pad at 17, heard as JumpLand; early in the band the request waits
//                 for the strip; outside the band it is a free jump into the gap; in the air within 0.10 s of the lip
//                 it still leaps, at 0.13 s it does not; no leap under 15 studs/s nor 40 degrees off (30 leaps); leap
//                 assist On leaps with no press, Auto on a keyboard and Off do not; the five never-blind rays reach each
//                 pad and the walled one is blind. Identical at 20 / 30 / 60 / 144.
//   landing       a 12-stud fall lands hard (HardLanding once on the landing tick), 0.6 s at 40 % of the sprint then
//                 the sprint again; a drop of 4 is not hard; a jump's landing is JumpLand. 20 / 30 / 144.
//   lookback      LookBack held: the view turns 150 degrees in 0.18 s and back on release, the walk keeps its heading;
//                 nothing in a vent. 20 / 60 / 144.
//   overrides     the vent rail and the parachute (freefall, ripcord, canopy) give identical tick states at 20 and
//                 144 fps (the game page booted once per rate, the same preamble at 30 fps); entering a vent puts the
//                 body on the rail at once (the drive's first tick moves it by its speed alone).
//   senses        the eye the levels see (game.eye(), subjects()) is tick state, the root plus the MoveState's eye
//                 height: identical at 20 and 144 fps on a walk through Level 1.
//   falls         in the game, a fall of 15 onto the roof lands hard once and never damages (health and life kept).

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { parkourRules } from '../src/game/rules/parkour.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.resolve(here, '..');
const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const noBuild = argv.includes('--no-build');
const ALL_CASES = ['determinism', 'numbers', 'jumps', 'gaps', 'step-up', 'presses', 'interpolation', 'rules', 'slide', 'leap',
  'landing', 'lookback', 'overrides', 'senses', 'falls'];
const GAME_CASES = ['overrides', 'senses', 'falls'];
const only = new Set(opt('--only', ALL_CASES.join(',')).split(','));
const RATES = [20, 30, 60, 144];
const TOLERANCE = 1e-6;

function page(flag, file, build) {
  const given = opt(flag, null);
  if (given) return path.resolve(given);
  if (!noBuild || !fs.existsSync(file)) build(file);
  return file;
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

// ---------------------------------------------------------------------------------------------------- the report

/** @type {Array<{name: string, checks: Array<{ok: boolean, name: string}>}>} */
const caseResults = [];
let current = null;
function check(name, ok, detail) {
  const line = `${ok ? 'ok  ' : 'FAIL'} ${name}${detail !== undefined ? ` ${typeof detail === 'string' ? detail : JSON.stringify(detail)}` : ''}`;
  console.log(`  ${line}`);
  current.checks.push({ ok: !!ok, name });
}
function info(text) {
  console.log(`  INFO ${text}`);
}
async function runCase(name, fn) {
  if (!only.has(name)) return;
  console.log(`\n[${name}]`);
  current = { name, checks: [] };
  caseResults.push(current);
  try {
    await fn();
  } catch (err) {
    check(`${name} ran to the end`, false, String(err && err.stack ? err.stack : err));
  }
  if (current.checks.length === 0) check(`${name} made its checks`, false);
}

// ---------------------------------------------------------------------------------------------------- the traces

/**
 * Tick-indexed input traces: [tick, action, ...args]. Actions: 'at' x z yaw [height] (teleport on the course, the
 * feet `height` above its slab), 'corridor' (teleport into the Level 1 east corridor facing west), 'key' code down,
 * 'sprint' down, 'jump' down, 'crouch' (a press), 'yaw' radians, 'turn' radians per tick until 'turn' 0.
 * Course coordinates are relative to the fixture's origin (lab.O); -z is ahead at yaw 0.
 */
const COURSE = [
  // the flat lane: walk, sprint, a sprint jump, crouch, stand, a standing jump, turning while walking
  [0, 'at', 0, 40, 0], [3, 'key', 'KeyW', true],
  [40, 'sprint', true], [75, 'jump', true], [76, 'jump', false], [110, 'sprint', false],
  [120, 'crouch'], [160, 'crouch'], [170, 'key', 'KeyW', false],
  [190, 'jump', true], [191, 'jump', false],
  [215, 'key', 'KeyW', true], [215, 'turn', 0.05], [260, 'turn', 0], [260, 'key', 'KeyW', false],
  // the stair: 8 risers up, a landing, 8 down (walking)
  [280, 'at', 300, -10, 0], [283, 'key', 'KeyW', true], [430, 'key', 'KeyW', false],
  // the 30 degree ramp, sprinting up and down
  [440, 'at', 330, -10, 0], [443, 'key', 'KeyW', true], [443, 'sprint', true], [540, 'key', 'KeyW', false],
  [540, 'sprint', false],
  // stepping off a 4-high ledge
  [550, 'at', 360, 0, 0, 4], [553, 'key', 'KeyW', true], [610, 'key', 'KeyW', false],
  // a jump against a wall, then sliding along it
  [620, 'at', -330, -10, 0], [623, 'key', 'KeyW', true], [660, 'jump', true], [661, 'jump', false],
  [700, 'yaw', 0.7], [760, 'key', 'KeyW', false],
];
const COURSE_TICKS = 780;
const CORRIDOR = [
  [0, 'corridor'], [3, 'key', 'KeyW', true], [40, 'sprint', true], [80, 'sprint', false],
  [85, 'yaw', Math.PI / 2 + 0.6], [140, 'crouch'], [180, 'crouch'], [185, 'jump', true], [186, 'jump', false],
  [220, 'turn', -0.06], [270, 'turn', 0], [300, 'key', 'KeyW', false],
];
const CORRIDOR_TICKS = 320;
// held and repeated presses: a jump held through a sprint (it hops again on every landing); then at a walk (a Crouch
// press at a sprint is a slide): two Crouch presses on one tick (no change), three on one tick (a toggle), one more
// (back up), a Jump pressed and released on the same tick
const PRESSES = [
  [0, 'at', 0, 40, 0], [3, 'key', 'KeyW', true], [3, 'sprint', true],
  [30, 'jump', true], [95, 'jump', false], [100, 'sprint', false],
  [110, 'crouch'], [110, 'crouch'],
  [120, 'crouch'], [120, 'crouch'], [120, 'crouch'],
  [150, 'crouch'],
  [165, 'jump', true], [165, 'jump', false],
  [190, 'key', 'KeyW', false],
];
const PRESSES_TICKS = 220;

/**
 * Irregular frame times (seconds): a seeded mix of fast and slow frames, with long ones: 0.09 s (three ticks in one
 * frame), or with `stalls` 0.25 to 1 s, far over the loop's 0.1 s clamp (the frame's time is dropped).
 */
function irregularFrames(seed, count, stalls = false) {
  let s = seed >>> 0;
  const rnd = () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 4294967296;
  };
  const out = [];
  for (let i = 0; i < count; i++) {
    const r = rnd();
    out.push(r < 0.05 ? (stalls ? 0.25 + rnd() * 0.75 : 0.09) : r < 0.2 ? 1 / 240 + rnd() * 0.004 : 1 / 200 + rnd() * (1 / 25));
  }
  return out;
}

// ---------------------------------------------------------------------------------------------------- the page lab

/**
 * Installs window.__lab on the sandbox page: the fixture course (a collider of its own far outside the school) and
 * play(), which steps a tick-indexed trace through the real loop at a given frame schedule.
 */
function installLab() {
  const e = window.__rovloc.engine;
  const loop = e.loop;
  loop.stop();
  e.skipRender = true;
  e.quality.adapt = false;
  const world = e.world;
  const p = e.player;
  const input = e.input;
  const O = { x: -2000, y: 200, z: -2000 };
  const any = [...world.colliders.values()][0];
  const MeshBVH = any.bvh.constructor;
  const Geometry = any.bvh.geometry.constructor;
  const Attribute = any.bvh.geometry.getAttribute('position').constructor;
  const Box3 = any.box.constructor;
  const pos = [];
  const quad = (a, b, c, d) => pos.push(...a, ...b, ...c, ...a, ...c, ...d);
  // course-relative boxes: x, z relative to O, y above the slab
  const box = (x0, y0, z0, x1, y1, z1) => {
    const X0 = O.x + x0;
    const X1 = O.x + x1;
    const Y0 = O.y + y0;
    const Y1 = O.y + y1;
    const Z0 = O.z + z0;
    const Z1 = O.z + z1;
    const v = (x, y, z) => [x, y, z];
    const [a, b, c, d] = [v(X0, Y0, Z0), v(X1, Y0, Z0), v(X1, Y0, Z1), v(X0, Y0, Z1)];
    const [A, B, C, D] = [v(X0, Y1, Z0), v(X1, Y1, Z0), v(X1, Y1, Z1), v(X0, Y1, Z1)];
    quad(a, b, c, d);
    quad(A, D, C, B);
    quad(a, A, B, b);
    quad(b, B, C, c);
    quad(c, C, D, d);
    quad(d, D, A, a);
  };
  // a ramp across x0..x1 from z0 toward -z over `run`, rising (or falling) by `rise`
  const wedge = (x0, x1, z0, run, rise, falling) => {
    const X0 = O.x + x0;
    const X1 = O.x + x1;
    const y = O.y;
    const za = O.z + z0;
    const zb = za - run;
    const ya = falling ? y + rise : y;
    const yb = falling ? y : y + rise;
    quad([X0, ya, za], [X1, ya, za], [X1, yb, zb], [X0, yb, zb]);
    quad([X0, y, za], [X0, ya, za], [X0, yb, zb], [X0, y, zb]);
    quad([X1, y, za], [X1, y, zb], [X1, yb, zb], [X1, ya, za]);
    quad([X0, y, za], [X1, y, za], [X1, ya, za], [X0, ya, za]);
    quad([X0, y, zb], [X0, yb, zb], [X1, yb, zb], [X1, y, zb]);
  };
  // the slab
  box(-400, -2, -650, 400, 0, 60);
  // step lanes (x = 30 + 12 i): blocks 10 deep at z -20..-30, and the same heights as slabs off the floor (0.6
  // thick: a bench, a bar, a table top) at z -70..-80
  const steps = [1.0, 1.2, 1.4, 1.5, 1.6, 1.65, 1.7, 1.75, 1.8, 1.85, 1.9, 1.95, 2.0, 2.2, 2.4];
  steps.forEach((h, i) => box(30 + i * 12 - 4, 0, -30, 30 + i * 12 + 4, h, -20));
  steps.forEach((h, i) => box(30 + i * 12 - 4, h - 0.6, -80, 30 + i * 12 + 4, h, -70));
  // mount lanes (x = -30 - 12 i): blocks 3 deep at z -25..-28; the 2.6 hurdle, the 5.5 wall and the mount limit
  const mounts = [2.6, 5.5, 3.8, 3.9, 4.0, 4.05, 4.1, 4.15, 4.2, 4.3, 4.4, 4.5, 4.6, 4.8, 5.0];
  mounts.forEach((h, i) => box(-30 - i * 12 - 4, 0, -28, -30 - i * 12 + 4, h, -25));
  // gap lanes (x = -380 + 14 j): a runway 12 high from z -240 to -300, the gap, a landing 30 long: level with the
  // runway (j even) or 2 lower (j odd)
  const gaps = [7.0, 7.4, 7.8, 8.2, 8.6, 9.0, 9.4, 9.8, 10.2, 12];
  gaps.forEach((w, k) => {
    for (const [j, drop] of [[2 * k, 0], [2 * k + 1, 2]]) {
      const x = -380 + j * 14;
      box(x - 5, 0, -300, x + 5, 12, -240);
      box(x - 5, 0, -300 - w - 30, x + 5, 12 - drop, -300 - w);
    }
  });
  // the stair (x 300): 8 risers of 1.0 on treads of 1.25, a landing at 8 (10 long), 8 risers down
  for (let k = 1; k <= 8; k++) box(294, 0, -20 - k * 1.25, 306, k, -20 - (k - 1) * 1.25);
  box(294, 0, -40, 306, 8, -30);
  for (let k = 1; k <= 8; k++) box(294, 0, -40 - k * 1.25, 306, 8 - k, -40 - (k - 1) * 1.25);
  // the ramp (x 330): 30 degrees up 6, a plateau of 10, down again
  const run = 6 / Math.tan(Math.PI / 6);
  wedge(324, 336, -20, run, 6, false);
  box(324, 0, -20 - run - 10, 336, 6, -20 - run);
  wedge(324, 336, -20 - run - 10, run, 6, true);
  // the ledge (x 360): a platform 4 high from z +10 to -20
  box(354, 0, -20, 366, 4, 10);
  // the wall (x -330): 20 high, 40 wide, across z -20..-22
  box(-350, 0, -22, -310, 20, -20);
  // the slide lanes (x 40 open floor, x 70 and x 100): a slide bar at x 70 (4.2 clear under it, solid to 9.7, 2 deep:
  // z -500..-502), a low ceiling at x 100 (4.2 clear, from z -490 to -560)
  box(64, 4.2, -502, 76, 9.7, -500);
  box(94, 4.2, -560, 106, 9.7, -490);
  // the leap course: a runway 12 high (x 220..380, z -380 to its lip at -440), the 12-stud gap (its floor the slab, 12
  // below), the pads 40 deep: level with the runway (x 220..300) and 2 lower (x 300..380). Its strips: A over the level
  // pad, B over the lower one, each 80 wide
  box(220, 0, -440, 380, 12, -380);
  box(220, 0, -492, 300, 12, -452);
  box(300, 0, -492, 380, 10, -452);
  // a blind strip (on the slab, lip at z -600 by x -250): a wall 20 high across its gap hides the pad
  box(-270, 0, -607, -230, 20, -606);
  const geometry = new Geometry();
  geometry.setAttribute('position', new Attribute(new Float32Array(pos), 3));
  const index = new Uint32Array(pos.length / 3);
  for (let i = 0; i < index.length; i++) index[i] = i;
  geometry.setIndex(new Attribute(index, 1));
  const bvh = new MeshBVH(geometry);
  const bounds = new Box3();
  bvh.getBoundingBox(bounds);
  world.colliders.set('ParkourFixture', { bvh, box: bounds, level: 'ParkourFixture' });
  const strips = {
    A: p.parkour.addStrip('FixtureA', { x: O.x + 260, y: O.y + 12, z: O.z - 440 }, { x: 0, z: -1 }, 80),
    B: p.parkour.addStrip('FixtureB', { x: O.x + 340, y: O.y + 12, z: O.z - 440 }, { x: 0, z: -1 }, 80),
    Blind: p.parkour.addStrip('FixtureBlind', { x: O.x - 250, y: O.y, z: O.z - 600 }, { x: 0, z: -1 }, 40),
  };
  const hall = world.meta.rooms.find((x) => x.id === 'L1_Corridor_East');
  const corridor = { x: hall.rect.x + hall.rect.w - 16, y: hall.floorY + 3, z: hall.rect.z + hall.rect.d / 2 };

  const TICK = loop.tickDt;
  const releaseAll = () => {
    input.keys.clear();
    for (const action of ['Sprint', 'Jump', 'Crouch', 'LookBack']) input.inject(action, 'lab', false);
  };
  const teleport = (x, y, z, yaw) => {
    p.teleport({ position: { x, y, z }, yaw });
    p.setLook(yaw, 0);
  };
  /** Puts the player in the same state before every play: clock, meters, intents, latches. */
  const reset = () => {
    releaseAll();
    loop.time = 0;
    loop.tickCount = 0;
    loop.accumulator = 0;
    loop.alpha = 0;
    p.intent = { crouch: false, sprint: false, dive: false };
    p.crouchPresses = 0;
    p.jumpLatched = false;
    p.exhausted = false;
    p.drainEndedAt = null;
    p.noiseClock = 0;
    p.speed = 0;
    p.moving = false;
    p.wasGrounded = true;
    p.moveState = 'Standing';
    p.body.height = 5.2;
    p.meters.stamina.set(p.meters.stamina.max);
    e.settings.set('LeapAssist', 'Auto');
    teleport(O.x, O.y + 3, O.z + 40, 0);
  };
  const apply = (op, turn) => {
    const [, action, a, b, c, d] = op;
    switch (action) {
      case 'at': teleport(O.x + a, O.y + (d || 0) + 3, O.z + b, c); break;
      case 'corridor': teleport(corridor.x, corridor.y, corridor.z, Math.PI / 2); break;
      case 'key': if (a) input.keys.add(a); else input.keys.delete(a); break;
      case 'sprint': input.inject('Sprint', 'lab', !!a); break;
      case 'jump': input.inject('Jump', 'lab', !!a); break;
      case 'crouch': input.inject('Crouch', 'lab', true); input.inject('Crouch', 'lab', false); break;
      case 'lookback': input.inject('LookBack', 'lab', !!a); break;
      case 'assist': e.settings.set('LeapAssist', a); break;
      case 'mode': p.setMode(a); break;
      case 'yaw': p.setLook(a, 0); break;
      case 'turn': turn.rate = a; break;
      default: throw new Error(`unknown trace action ${action}`);
    }
  };

  /**
   * Plays `trace` for `ticks` ticks with frame times from `frames` (a number: fps; an array: seconds, cycled).
   * Returns the tick states [x, y, z, vx, vy, vz, grounded, moveState, feet] and, with `sampleFrames`, the frames.
   */
  function play({ trace, ticks, frames, sampleFrames, perFrame }) {
    reset();
    const due = new Map();
    for (const op of trace) {
      if (!due.has(op[0])) due.set(op[0], []);
      due.get(op[0]).push(op);
    }
    const turn = { rate: 0 };
    const states = [];
    const samples = [];
    const offInput = loop.onTick(() => {
      const r = loop.tickCount - 1;
      for (const op of due.get(r) || []) apply(op, turn);
      if (turn.rate) p.setLook(p.yaw + turn.rate, 0);
    }, -1000);
    const offRecord = loop.onTick(() => {
      const b = p.body;
      states.push([b.position.x, b.position.y, b.position.z, b.velocity.x, b.velocity.y, b.velocity.z,
        b.grounded ? 1 : 0, p.moveState, b.feetY, b.height, p.parkour.lookNow]);
    }, 1e9);
    const noises = [];
    const offNoise = e.noise.on((ev) => noises.push([states.length, ev.kind]));
    const leaps = [];
    const offLeap = p.leapt.connect((strip, takeoff) => leaps.push({ tick: states.length, strip: strip.id, takeoff }));
    let f = 0;
    try {
      while (states.length < ticks) {
        const dt = typeof frames === 'number' ? 1 / frames : frames[f % frames.length];
        if (perFrame) perFrame(f, states.length);
        loop.stepManual(dt);
        f++;
        if (sampleFrames) {
          const cam = e.renderer.camera.position;
          samples.push({
            tick: loop.tickCount, alpha: loop.alpha,
            camera: [cam.x, cam.y, cam.z], eye: [p.eyePosition.x, p.eyePosition.y, p.eyePosition.z],
            drawn: [p.drawnRoot.x, p.drawnRoot.y, p.drawnRoot.z],
            prev: [p.tickPrevious.x, p.tickPrevious.y, p.tickPrevious.z],
            cur: [p.tickCurrent.x, p.tickCurrent.y, p.tickCurrent.z],
          });
        }
      }
    } finally {
      offInput();
      offRecord();
      offNoise();
      offLeap();
      releaseAll();
    }
    return { states: states.slice(0, ticks), frames: f, samples, noises, leaps };
  }

  window.__lab = { O: { ...O }, play, steps, mounts, gaps, corridor, strips };
  return { O, steps, mounts, gaps, corridor, colliders: [...world.colliders.keys()] };
}

// ---------------------------------------------------------------------------------------------------- helpers

/** Largest difference between two tick-state logs, and the first tick past the tolerance. */
function compare(a, b) {
  let max = 0;
  let first = null;
  if (a.length !== b.length) return { max: Infinity, first: { tick: Math.min(a.length, b.length), why: 'length' } };
  for (let t = 0; t < a.length; t++) {
    for (let k = 0; k < a[t].length; k++) {
      const x = a[t][k];
      const y = b[t][k];
      let d;
      if (typeof x === 'number') d = Math.abs(x - y);
      else d = x === y ? 0 : Infinity;
      if (d > max) max = d;
      if (d > TOLERANCE && !first) first = { tick: t, field: k, a: x, b: y };
    }
  }
  return { max, first };
}

/** A rule's answer against a golden row's: numbers within 1e-9, tables key by key (an empty Luau table is {} or []). */
function sameValue(a, b) {
  if (typeof a === 'number' || typeof b === 'number') return typeof a === 'number' && typeof b === 'number' && Math.abs(a - b) <= 1e-9;
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    return [...new Set([...Object.keys(a), ...Object.keys(b)])].every((k) => sameValue(a[k], b[k]));
  }
  return a === b;
}

const horizontal = (s, a, b) => Math.hypot(s[b][0] - s[a][0], s[b][2] - s[a][2]);
/** Mean horizontal speed over ticks a..b. */
const speedOver = (s, a, b) => horizontal(s, a, b) / ((b - a) / 30);
const fmt = (v, n = 3) => (v === null || v === undefined || !Number.isFinite(v) ? String(v) : v.toFixed(n));

/** Take-off (the last grounded tick) to landing (the first grounded tick after it) from tick `from` on. */
function jumpOf(s, from) {
  let k = from;
  while (k < s.length && s[k][6] === 1) k++;
  if (k >= s.length || k === 0) return null;
  let land = k;
  while (land < s.length && s[land][6] === 0) land++;
  if (land >= s.length) return null;
  return { takeoff: k - 1, land, distance: horizontal(s, k - 1, land), air: (land - k + 1) / 30 };
}

// ---------------------------------------------------------------------------------------------------- run

const sandboxHtml = page('--sandbox-html', path.join(web, 'build/cache/parkour-sandbox.html'), (file) => {
  execFileSync(process.execPath, [path.join(here, 'build.mjs'), '--sandbox', '--out', file, '--no-minify'], { stdio: 'inherit' });
});
const needGame = GAME_CASES.some((c) => only.has(c));
const gameHtml = needGame ? page('--game-html', path.join(web, 'build/cache/parkour-game.html'), (file) => {
  execFileSync(process.execPath, [path.join(here, 'game-build.mjs'), '--out', file, '--no-minify'], { stdio: 'inherit' });
}) : null;

const { chromium } = loadPlaywright();
const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist',
  '--autoplay-policy=no-user-gesture-required', '--enable-webgl'] });
const pageErrors = [];

/** A page with the engine's own frame loop held: every frame is stepped by the test. */
async function open(file, query, init) {
  const context = await browser.newContext({ viewport: { width: 320, height: 180 } });
  const tab = await context.newPage();
  tab.on('pageerror', (err) => pageErrors.push(`pageerror: ${err.message}`));
  tab.on('console', (m) => {
    if (m.type() === 'error' && !/useProgram|Shader Error|WebGL|GPU stall|AudioContext/i.test(m.text())) pageErrors.push(m.text());
  });
  await tab.addInitScript((save) => {
    const raf = window.requestAnimationFrame.bind(window);
    window.requestAnimationFrame = (cb) => (cb && cb.name === 'bound _step' ? 0 : raf(cb));
    Element.prototype.requestPointerLock = function requestPointerLock() {
      return Promise.resolve();
    };
    localStorage.setItem('rovloc.save', JSON.stringify({ version: 1, data: { settings: save } }));
  }, init || { Graphics: 'Low' });
  await tab.goto(`file://${file}${query}`);
  await tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 240000 });
  const bootError = await tab.evaluate(() => window.__rovloc.error);
  if (bootError) throw new Error(`boot: ${bootError}`);
  return { tab, context };
}

let lab = null;
let sandbox = null;
const needSandbox = ALL_CASES.filter((c) => !GAME_CASES.includes(c)).some((c) => only.has(c));
if (needSandbox) {
  sandbox = await open(sandboxHtml, '?level=Level1_Hallways', { Graphics: 'Low', MotionScale: 0 });
  lab = await sandbox.tab.evaluate(installLab);
  console.log(`sandbox ${path.relative(web, sandboxHtml)}: fixture course at ${JSON.stringify(lab.O)}, corridor start ${JSON.stringify(lab.corridor)}`);
}
const play = (spec) => sandbox.tab.evaluate((s) => {
  const lab2 = window.__lab;
  if (s.frames === 'irregular') s.frames = s.irregular;
  return lab2.play(s);
}, spec);

const runs = { course: {}, corridor: {}, presses: {} };
const SCHEDULES = [...RATES.map((fps) => ({ name: `${fps} fps`, frames: fps })),
  { name: 'irregular', frames: 'irregular', irregular: irregularFrames(7, 4000) },
  { name: 'stalls', frames: 'irregular', irregular: irregularFrames(13, 4000, true) }];
async function courseRuns() {
  if (Object.keys(runs.course).length) return;
  for (const sch of SCHEDULES) {
    runs.course[sch.name] = await play({ trace: COURSE, ticks: COURSE_TICKS, frames: sch.frames, irregular: sch.irregular });
    runs.corridor[sch.name] = await play({ trace: CORRIDOR, ticks: CORRIDOR_TICKS, frames: sch.frames, irregular: sch.irregular });
    runs.presses[sch.name] = await play({ trace: PRESSES, ticks: PRESSES_TICKS, frames: sch.frames, irregular: sch.irregular });
  }
}
/**
 * Jumps launched in ticks a..b of a tick-state log: the body rises and its vertical speed has leapt up since the tick
 * before (a landing and the next launch can share one tick, so the grounded flag alone misses them).
 */
const launches = (s, a, b) => {
  let n = 0;
  for (let t = Math.max(a, 1); t <= b; t++) if (s[t][4] > 10 && s[t][4] - s[t - 1][4] > 10) n++;
  return n;
};

try {
  await runCase('determinism', async () => {
    await courseRuns();
    for (const trace of ['course', 'corridor', 'presses']) {
      const ref = runs[trace]['30 fps'].states;
      for (const sch of SCHEDULES) {
        if (sch.name === '30 fps') continue;
        const r = runs[trace][sch.name];
        const d = compare(ref, r.states);
        check(`${trace}: ${sch.name} (${r.frames} frames) gives the 30 fps tick states (${ref.length} ticks)`, d.max <= TOLERANCE,
          d.first ? d.first : `max difference ${d.max.toExponential(2)}`);
      }
    }
    // the trace really did what it says (moved, jumped, climbed, dropped, slid)
    const s = runs.course['30 fps'].states;
    const floor = lab.O.y;
    const stairTop = Math.max(...s.slice(280, 440).map((q) => q[8])) - floor;
    const stairEnd = s[429][8] - floor;
    const rampTop = Math.max(...s.slice(440, 550).map((q) => q[8])) - floor;
    const ledge = jumpOf(s, 553);
    const slide = Math.abs(s[759][0] - s[700][0]);
    const wallZ = Math.max(...s.slice(620, 780).map((q) => q[2] - lab.O.z));
    info(`course: stair top ${fmt(stairTop)} then ${fmt(stairEnd)}, ramp top ${fmt(rampTop)}, ledge drop ${ledge ? fmt(ledge.air) : 'none'} s, ` +
      `slid ${fmt(slide)} studs along the wall, nearest the wall z ${fmt(-wallZ)}`);
    check('the course trace climbs the stair, crosses the ramp, drops off the ledge and slides along the wall',
      stairTop > 7.9 && Math.abs(stairEnd) < 0.05 && rampTop > 5.9 && ledge && slide > 3 && s.slice(620, 780).every((q) => q[2] - lab.O.z > -20),
      { stairTop, stairEnd, rampTop, ledge, slide });
    const c = runs.corridor['30 fps'].states;
    const turned = horizontal(c, 0, 319);
    check('the corridor trace moves through the real Level 1 corridor', turned > 20 && c.every((q) => q.slice(0, 6).every(Number.isFinite)), { moved: turned });
    const longest = Math.max(...SCHEDULES.find((x) => x.name === 'stalls').irregular);
    check(`the stalls schedule has frames far over the loop's 0.1 s clamp (longest ${fmt(longest, 2)} s) and still ran every tick`,
      longest > 0.5 && runs.course.stalls.states.length === COURSE_TICKS);
  });

  await runCase('numbers', async () => {
    await courseRuns();
    for (const sch of SCHEDULES) {
      const s = runs.course[sch.name].states;
      const floor = lab.O.y;
      const apex = Math.max(...s.slice(190, 215).map((q) => q[8])) - floor;
      const walk = speedOver(s, 20, 39);
      const sprint = speedOver(s, 55, 74);
      const crouch = speedOver(s, 140, 159);
      const states = [s[30][7], s[65][7], s[150][7]];
      check(`${sch.name}: apex ${fmt(apex)} (2.50 +/- 0.02)`, Math.abs(apex - 2.5) <= 0.02);
      check(`${sch.name}: walk ${fmt(walk)} / sprint ${fmt(sprint)} / crouch ${fmt(crouch)} (11 / 19 / 5.5 within 1 %; ${states.join(' / ')})`,
        Math.abs(walk / 11 - 1) <= 0.01 && Math.abs(sprint / 19 - 1) <= 0.01 && Math.abs(crouch / 5.5 - 1) <= 0.01 &&
        states.join() === 'Standing,Sprinting,Crouching');
    }
    // acceleration as measured on the tick (the old per-frame game at 60 fps: 90 % of the walk speed after 0.083 s)
    const s = runs.course['30 fps'].states;
    let reach = null;
    for (let t = 4; t < 40 && reach === null; t++) if (speedOver(s, t - 1, t) >= 0.9 * 11) reach = (t - 3) / 30;
    info(`walk speed reaches 90 % ${fmt(reach)} s after W (tick resolution 0.033 s)`);
  });

  await runCase('jumps', async () => {
    await courseRuns();
    const distances = [];
    for (const sch of SCHEDULES) {
      const j = jumpOf(runs.course[sch.name].states, 74);
      distances.push(j ? j.distance : null);
      check(`${sch.name}: the sprint jump takes off at 19 and lands on level ground: ${j ? `${fmt(j.distance)} studs, ${fmt(j.air)} s` : 'no jump'}`,
        j && j.distance < 10 && j.distance > 5);
    }
    info(`the sprint jump on level ground (take-off to landing, tick states): ${fmt(distances[0])} studs`);
    check('the sprint jump is the same at every frame rate', distances.every((d) => d !== null && Math.abs(d - distances[0]) <= TOLERANCE), distances);
    // the hurdle and the wall: standing against it and jumping (forward held), and sprinting at it and jumping
    const mounts = lab.mounts;
    for (const fps of [20, 144]) {
      const lane = (h) => -30 - mounts.indexOf(h) * 12;
      const stand = (h) => [[0, 'at', lane(h), -15, 0], [2, 'key', 'KeyW', true], [40, 'jump', true], [41, 'jump', false]];
      const sprint = (h) => [[0, 'at', lane(h), 30, 0], [2, 'key', 'KeyW', true], [2, 'sprint', true], [82, 'jump', true], [83, 'jump', false]];
      const top = (s, h) => s.some((q) => q[6] === 1 && Math.abs(q[8] - lab.O.y - h) < 0.05);
      const past = (s) => s.some((q) => q[2] - lab.O.z < -28 - 1);
      const hurdle = await play({ trace: stand(2.6), ticks: 90, frames: fps });
      check(`${fps} fps: a 2.6-high hurdle is mounted by a standing jump against it`, top(hurdle.states, 2.6));
      const over = await play({ trace: sprint(2.6), ticks: 120, frames: fps });
      check(`${fps} fps: sprinting at the 2.6 hurdle and jumping gets on it or over it`, top(over.states, 2.6) || past(over.states));
      for (const [name, trace] of [['standing against it', stand(5.5)], ['sprinting at it', sprint(5.5)]]) {
        const r = await play({ trace, ticks: 120, frames: fps });
        const highest = Math.max(...r.states.map((q) => q[8])) - lab.O.y;
        check(`${fps} fps: a 5.5-high wall is never mounted (${name}; feet at most ${fmt(highest)})`, !top(r.states, 5.5) && !past(r.states) && highest < 5.5);
      }
    }
    let limit = 0;
    for (const h of mounts) {
      if (h === 2.6 || h === 5.5) continue;
      const lane = -30 - mounts.indexOf(h) * 12;
      const r = await play({ trace: [[0, 'at', lane, -15, 0], [2, 'key', 'KeyW', true], [40, 'jump', true], [41, 'jump', false]], ticks: 90, frames: 30 });
      if (r.states.some((q) => q[6] === 1 && Math.abs(q[8] - lab.O.y - h) < 0.05)) limit = Math.max(limit, h);
    }
    const tallest = Math.max(...mounts.filter((h) => h !== 5.5));
    info(`the highest block a standing jump mounts: ${fmt(limit, 2)} (the jump apex 2.5 plus what the legs reach at the top)`);
    check(`the jump mount limit covers the tallest hurdle (2.8) and stays under a wall (5.5), inside the ladder (under ${tallest})`,
      limit >= 2.8 && limit < 5.5 && limit < tallest, limit);
  });

  await runCase('gaps', async () => {
    // the runner starts 45 studs before the edge at one of several phases of the tick, sprints, and Jump goes down
    // on the last tick it still stands on the runway (found by a run without a jump): the furthest take-off there is
    const lane = (k, drop) => -380 + (2 * k + (drop ? 1 : 0)) * 14;
    const PHASES = [0, 0.11, 0.22, 0.33, 0.44, 0.55];
    const run = (k, drop, phase, press) => [[0, 'at', lane(k, drop), -255 + phase, 0, 12], [2, 'key', 'KeyW', true], [2, 'sprint', true],
      ...(press === null ? [] : [[press, 'jump', true], [press + 1, 'jump', false]])];
    const leaves = {};
    for (const phase of PHASES) {
      const r = await play({ trace: run(0, 0, phase, null), ticks: 110, frames: 30 });
      leaves[phase] = r.states.findIndex((q, t) => t > 10 && q[6] === 0);
    }
    check('the run-up reaches the edge at a sprint and runs off it without a jump', Object.values(leaves).every((t) => t > 60 && t < 100), leaves);
    /** Whether a jump from the runway's edge lands on the far side of gap k (any phase), at `fps`. */
    const crosses = async (k, drop, fps) => {
      const w = lab.gaps[k];
      for (const phase of PHASES) {
        for (const press of [leaves[phase], leaves[phase] - 1]) {
          const r = await play({ trace: run(k, drop, phase, press), ticks: press + 40, frames: fps });
          const jumped = r.states.some((q) => q[4] > 1);
          const landed = r.states.some((q, t) => t > press && q[6] === 1 && Math.abs(q[8] - lab.O.y - (12 - drop)) < 0.05 && q[2] - lab.O.z < -300 - w + 1);
          if (jumped && landed) return true;
        }
      }
      return false;
    };
    const widest = {};
    for (const drop of [0, 2]) {
      const name = drop ? 'a landing 2 lower' : 'a level landing';
      let best = 0;
      let misses = 0;
      const crossed = [];
      for (let k = 0; k < lab.gaps.length; k++) {
        const w = lab.gaps[k];
        if (misses >= 2 && w !== 12) continue;
        if (await crosses(k, drop, 30)) {
          best = Math.max(best, w);
          crossed.push(w);
          misses = 0;
        } else misses++;
      }
      widest[drop] = best;
      const next = lab.gaps[lab.gaps.indexOf(best) + 1];
      info(`the widest gap a free sprint jump crosses onto ${name}: ${fmt(best, 1)} (the ${fmt(next, 1)} one is not crossed; crossed: ${crossed.join(', ')})`);
      check(`onto ${name}: a 12-stud gap is never crossed`, !crossed.includes(12) && best > 0, crossed);
      for (const fps of [20, 144]) {
        const same = (await crosses(lab.gaps.indexOf(best), drop, fps)) && !(await crosses(lab.gaps.indexOf(next), drop, fps));
        check(`onto ${name}: the same widest gap at ${fps} fps`, same);
      }
    }
    check(`the longest free jump is under 10 studs (the spec's "about 8.4"): ${fmt(widest[0], 1)} onto a level landing`, widest[0] >= 7 && widest[0] < 10, widest);
    check(`onto a landing 2 lower the widest gap stays under the 12 of a leap gap: ${fmt(widest[2], 1)}`, widest[2] >= widest[0] && widest[2] < 12, widest);
  });

  await runCase('step-up', async () => {
    // walk at every block for 2 s: it is climbed (the feet end on its top), or it stops the body at its near face.
    // The third outcome, walking on through it at floor level, is what must never happen
    const rows = [['a block on the floor', -12, -20], ['a slab off the floor', -62, -70]];
    const limits = {};
    for (const fps of [20, 144]) {
      for (const [name, startZ, face] of rows) {
        let limit = 0;
        const refused = [];
        const through = [];
        for (let i = 0; i < lab.steps.length; i++) {
          const h = lab.steps[i];
          const r = await play({ trace: [[0, 'at', 30 + i * 12, startZ, 0], [2, 'key', 'KeyW', true]], ticks: 60, frames: fps });
          const climbed = r.states.some((q) => q[6] === 1 && Math.abs(q[8] - lab.O.y - h) < 0.02);
          const deepest = Math.min(...r.states.map((q) => q[2] - lab.O.z));
          if (climbed) limit = Math.max(limit, h);
          else {
            refused.push(h);
            if (deepest < face) through.push(`${h} (root ${fmt(face - deepest, 2)} past its near face)`);
          }
        }
        limits[`${name} at ${fps} fps`] = limit;
        info(`${fps} fps, ${name}: step-up limit ${fmt(limit, 2)} (refused: ${refused.join(', ')})`);
        check(`${fps} fps, ${name}: every height up to StepHeight (1.6) is walked onto and none from 2.0 up`,
          limit >= 1.6 && limit < 2.0 && refused.every((h) => h > limit), { limit, refused });
        check(`${fps} fps, ${name}: what is not walked onto stops the body at its near face (nothing is walked through)`,
          through.length === 0, through);
      }
    }
    const values = Object.values(limits);
    check(`the step-up limit is the same at 20 and 144 fps, on the floor and off it (${values.join(', ')})`, values.every((l) => l === values[0]), limits);
  });

  await runCase('presses', async () => {
    await courseRuns();
    const s = runs.presses['30 fps'].states;
    const hops = launches(s, 30, 100);
    check(`a Jump held through a sprint hops again on every landing (${hops} jumps in the 2.2 s it is held)`, hops >= 5, hops);
    check('two Crouch presses on one tick change nothing; three toggle the crouch; one more stands up',
      s[115][7] !== 'Crouching' && s[130][7] === 'Crouching' && s[158][7] !== 'Crouching', [s[115][7], s[130][7], s[158][7]]);
    check('a Jump pressed and released on the same tick jumps, once', launches(s, 165, 168) === 1 && launches(s, 100, 219) === 1, s.slice(163, 169).map((q) => q[4]));
    // pending presses and the pause menu, presses while the menu is open, presses while the controls are locked
    const menu = await sandbox.tab.evaluate(() => {
      const e = window.__rovloc.engine;
      const loop = e.loop;
      const p = e.player;
      const input = e.input;
      const settle = () => {
        window.__lab.play({ trace: [[0, 'at', 0, 40, 0]], ticks: 20, frames: 144 });
        while (Math.floor((loop.accumulator + 1 / 144) / loop.tickDt) > 0) loop.stepManual(1 / 144);
      };
      const tap = (action) => {
        input.inject(action, 'tap', true);
        input.inject(action, 'tap', false);
      };
      const airborne = (frames) => {
        let air = false;
        for (let i = 0; i < frames; i++) {
          loop.stepManual(1 / 144);
          if (!p.body.grounded) air = true;
        }
        return air;
      };
      const out = {};
      // Jump and Crouch pressed, then the menu opens before any tick ran
      settle();
      tap('Jump');
      tap('Crouch');
      out.pending = { jump: p.jumpLatched, crouch: p.crouchPresses };
      e.ui.openMenu();
      out.before = { during: airborne(30) };
      e.ui.closeMenu();
      out.before.after = airborne(30);
      out.before.crouch = p.intent.crouch;
      // pressed while the menu is open
      settle();
      e.ui.openMenu();
      tap('Jump');
      tap('Crouch');
      out.inMenu = { during: airborne(30) };
      e.ui.closeMenu();
      out.inMenu.after = airborne(30);
      out.inMenu.crouch = p.intent.crouch;
      // pressed while the controls are locked
      settle();
      p.lock('ParkourTest');
      tap('Jump');
      tap('Crouch');
      out.locked = { during: airborne(30) };
      p.unlock('ParkourTest');
      out.locked.after = airborne(30);
      out.locked.crouch = p.intent.crouch;
      return out;
    });
    check('a Jump and a Crouch press still pending when the pause menu opens are dropped (nothing fires in the menu or after it)',
      menu.pending.jump === true && menu.pending.crouch === 1 && !menu.before.during && !menu.before.after && !menu.before.crouch, menu);
    check('presses made while the pause menu is open do nothing, then or after it', !menu.inMenu.during && !menu.inMenu.after && !menu.inMenu.crouch, menu.inMenu);
    check('presses made while the controls are locked do nothing, then or after the lock', !menu.locked.during && !menu.locked.after && !menu.locked.crouch, menu.locked);
  });

  await runCase('interpolation', async () => {
    // walk at a constant 11 for 1 s, then watch 1.5 s of 144 fps frames
    const r = await play({ trace: [[0, 'at', 0, 40, 0], [2, 'key', 'KeyW', true]], ticks: 75, frames: 144, sampleFrames: true });
    const samples = r.samples.filter((q) => q.tick >= 30);
    const steps = [];
    for (let i = 1; i < samples.length; i++) {
      steps.push(Math.hypot(samples[i].camera[0] - samples[i - 1].camera[0], samples[i].camera[2] - samples[i - 1].camera[2]));
    }
    const mean = steps.reduce((a, b) => a + b, 0) / steps.length;
    const spread = (Math.max(...steps) - Math.min(...steps)) / mean;
    check(`144 fps at a constant walk: ${steps.length} camera steps of ${fmt(mean, 4)} studs (11 / 144 = ${fmt(11 / 144, 4)}), spread ${fmt(spread * 100, 2)} % (< 2 %)`,
      spread < 0.02 && Math.abs(mean - 11 / 144) / (11 / 144) < 0.02);
    let worst = 0;
    for (const q of r.samples) {
      const d = [0, 1, 2].map((k) => q.cur[k] - q.prev[k]);
      const len2 = d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
      const w = [0, 1, 2].map((k) => q.drawn[k] - q.prev[k]);
      const t = len2 > 0 ? (w[0] * d[0] + w[1] * d[1] + w[2] * d[2]) / len2 : 0;
      const off = Math.hypot(...[0, 1, 2].map((k) => w[k] - t * d[k]));
      worst = Math.max(worst, off, t < -1e-9 ? -t : 0, t > 1 + 1e-9 ? t - 1 : 0);
    }
    check(`the drawn root lies between the last two tick states on every one of ${r.samples.length} frames`, worst < 1e-9, `worst ${worst.toExponential(2)}`);
    // a press lasting one 144 fps frame with no tick inside it
    const tap = await sandbox.tab.evaluate(() => {
      const e = window.__rovloc.engine;
      const loop = e.loop;
      const p = e.player;
      const input = e.input;
      const out = {};
      for (const action of ['Jump', 'Crouch']) {
        window.__lab.play({ trace: [[0, 'at', 0, 40, 0]], ticks: 20, frames: 144 });
        // reach a frame that runs no tick: the press starts and ends inside it
        while (Math.floor((loop.accumulator + 1 / 144) / loop.tickDt) > 0) loop.stepManual(1 / 144);
        const before = loop.tickCount;
        const crouched = p.intent.crouch;
        input.inject(action, 'tap', true);
        loop.stepManual(1 / 144);
        input.inject(action, 'tap', false);
        const inside = loop.tickCount - before;
        let acted = false;
        for (let i = 0; i < 20 && !acted; i++) {
          loop.stepManual(1 / 144);
          acted = action === 'Jump' ? p.body.velocity.y > 0 || !p.body.grounded : p.intent.crouch !== crouched;
        }
        out[action] = { ticksDuringPress: inside, heldAtTick: action === 'Jump' ? p.jumpHeld : null, acted, ticks: loop.tickCount - before };
        if (action === 'Crouch' && p.intent.crouch) {
          input.inject('Crouch', 'tap', true);
          input.inject('Crouch', 'tap', false);
          for (let i = 0; i < 10; i++) loop.stepManual(1 / 144);
        }
      }
      return out;
    });
    check('a Jump press lasting a single 144 fps frame (no tick during it) jumps at the next tick', tap.Jump.ticksDuringPress === 0 && tap.Jump.acted, tap.Jump);
    check('a Crouch press lasting a single 144 fps frame toggles the crouch at the next tick', tap.Crouch.ticksDuringPress === 0 && tap.Crouch.acted, tap.Crouch);
    // teleports are cuts, the pause holds the drawn root, a stall moves it by the ticks the loop ran
    const cuts = await sandbox.tab.evaluate(() => {
      const e = window.__rovloc.engine;
      const loop = e.loop;
      const p = e.player;
      const input = e.input;
      const cam = e.renderer.camera.position;
      const { O } = window.__lab;
      const Vector = p.body.position.constructor;
      const far = { x: O.x, y: O.y + 3, z: O.z - 400 };
      const frame = () => loop.stepManual(1 / 144);
      /** Walking at 11 at 144 fps, 20 frames past the trace. */
      const walk = () => {
        window.__lab.play({ trace: [[0, 'at', 0, 40, 0], [2, 'key', 'KeyW', true]], ticks: 30, frames: 144 });
        input.keys.add('KeyW');
        for (let i = 0; i < 20; i++) frame();
      };
      const once = (priority, fn) => {
        const off = loop.onTick(() => {
          off();
          fn();
        }, priority);
      };
      const ways = {
        'a tick after the player\'s': () => once(500, () => p.teleport({ position: far, yaw: 0 })),
        'a tick before the player\'s': () => once(-500, () => p.teleport({ position: far, yaw: 0 })),
        'between two frames': () => p.teleport({ position: far, yaw: 0 }),
        'a bare write of the body\'s position, on a tick': () => once(500, () => p.body.position.set(far.x, far.y, far.z)),
        'the body\'s own teleport, between two frames': () => p.body.teleport(new Vector(far.x, far.y, far.z)),
      };
      const out = { teleports: {} };
      for (const [name, go] of Object.entries(ways)) {
        walk();
        const from = p.body.position.clone();
        go();
        let between = 0;
        let cameraBetween = 0;
        for (let i = 0; i < 40; i++) {
          frame();
          const body = p.body.position;
          if (p.drawnRoot.distanceTo(from) > 2 && p.drawnRoot.distanceTo(body) > 2) between++;
          if (cam.distanceTo(from) > 6 && cam.distanceTo(body) > 6) cameraBetween++;
        }
        out.teleports[name] = { moved: p.body.position.distanceTo(from), between, cameraBetween };
      }
      // the pause
      walk();
      const held = p.drawnRoot.clone();
      const heldCamera = cam.clone();
      loop.setPaused(true);
      let drift = 0;
      for (let i = 0; i < 40; i++) {
        frame();
        drift = Math.max(drift, p.drawnRoot.distanceTo(held), cam.distanceTo(heldCamera));
      }
      loop.setPaused(false);
      let last = cam.clone();
      let resumeStep = 0;
      for (let i = 0; i < 40; i++) {
        frame();
        resumeStep = Math.max(resumeStep, Math.hypot(cam.x - last.x, cam.z - last.z));
        last = cam.clone();
      }
      out.pause = { drift, resumeStep };
      // a one-second stall
      walk();
      const ticksBefore = loop.tickCount;
      last = cam.clone();
      loop.stepManual(1);
      const stallTicks = loop.tickCount - ticksBefore;
      const stallStep = Math.hypot(cam.x - last.x, cam.z - last.z);
      last = cam.clone();
      let afterStep = 0;
      for (let i = 0; i < 40; i++) {
        frame();
        afterStep = Math.max(afterStep, Math.hypot(cam.x - last.x, cam.z - last.z));
        last = cam.clone();
      }
      out.stall = { stallTicks, stallStep, afterStep };
      input.keys.clear();
      return out;
    });
    for (const [name, r] of Object.entries(cuts.teleports)) {
      check(`a teleport from ${name} is a cut: no frame draws the root or the camera between the two places`,
        r.moved > 300 && r.between === 0 && r.cameraBetween === 0, r);
    }
    const perFrame = 11 / 144;
    check(`the pause holds the drawn root and the camera still (drift ${cuts.pause.drift.toExponential(1)}) and the walk goes on from there (largest camera step ${fmt(cuts.pause.resumeStep, 4)})`,
      cuts.pause.drift < 1e-9 && cuts.pause.resumeStep < perFrame * 1.1, cuts.pause);
    check(`a one-second stall runs ${cuts.stall.stallTicks} ticks (the 0.1 s clamp) and the camera moves by them alone (${fmt(cuts.stall.stallStep)} studs), then by a frame at a time (${fmt(cuts.stall.afterStep, 4)})`,
      cuts.stall.stallTicks >= 2 && cuts.stall.stallTicks <= 4 && cuts.stall.stallStep < 11 * 4 / 30 + 0.01 && cuts.stall.stallStep > 11 * 2 / 30 && cuts.stall.afterStep < perFrame * 1.1, cuts.stall);
  });

  await runCase('rules', async () => {
    // rules/parkour.js against every ParkourRules golden row, in Node, then the page's own rules (the engine's) on them
    const golden = JSON.parse(fs.readFileSync(path.join(web, 'build/cache/golden.json'), 'utf8')).ParkourRules || [];
    const meta = JSON.parse(fs.readFileSync(path.join(web, 'build/world.json'), 'utf8'));
    const R = parkourRules(meta);
    const bad = [];
    const fns = new Set();
    for (const row of golden) {
      fns.add(row.fn);
      const got = typeof R[row.fn] === 'function' ? R[row.fn](...row.args) : undefined;
      if (!sameValue(got, row.expect)) bad.push({ row: row.name, got, want: row.expect });
    }
    check(`every ParkourRules golden row replays exactly (${golden.length} rows over ${fns.size} functions)`,
      golden.length >= 200 && fns.size === 18 && bad.length === 0, bad.slice(0, 3));
    const inPage = await sandbox.tab.evaluate((rows) => {
      const rules = window.__rovloc.engine.player.parkour.rules;
      return rows.filter((row) => row.fn === 'leap').map((row) => rules.leap(...row.args));
    }, golden);
    const leapRows = golden.filter((row) => row.fn === 'leap');
    check(`the engine's leap curve is the golden one (${leapRows.length} rows)`, leapRows.every((row, i) => sameValue(inPage[i], row.expect)));
    // the spec's numbers, from its text
    check('the leap: 0.60 s, 2.0 past the far edge of a 12 gap, apex 2.0', R.leap(0.3, 0).height === 2 && R.leap(0.6, 0).along === 14 &&
      R.leap(0.6, 0).done && !R.leap(0.59, 0).done);
    check('the slide: 0.70 s, 17 falling to 13, 10.5 studs', Math.abs(R.slide(0.7).distance - 10.5) < 1e-9 && R.slide(0).speed === 17 &&
      Math.abs(R.slide(0.7).speed - 13) < 1e-9 && R.slide(0.7).done);
    check('a hard landing from a fall of 8: 0.6 s at 40 %, never damage', R.hardLanding(8).hard && R.hardLanding(8).seconds === 0.6 &&
      R.hardLanding(8).speedFactor === 0.4 && !R.hardLanding(7.99).hard && [0, 8, 30, 100].every((f) => R.hardLanding(f).damage === 0));
  });

  /** Ticks a trace's root first has z (course-relative) at or below `z`, in a log. */
  const zTick = (s, z) => s.findIndex((q) => q[2] - lab.O.z <= z);
  /** How far before the leap course's lip (z -440) a tick state's root stands (negative: past it). */
  const toLip = (q) => q[2] - lab.O.z + 440;

  await runCase('slide', async () => {
    // the open floor (lane x 40): sprint from rest, Crouch at tick 40
    const open = (extra = []) => [[0, 'at', 40, -400, 0], [2, 'key', 'KeyW', true], [2, 'sprint', true], [40, 'crouch'], ...extra];
    const rates = {};
    for (const fps of RATES) rates[fps] = await play({ trace: open(), ticks: 90, frames: fps });
    const r = rates[30];
    const s = r.states;
    const sliding = s.map((q, t) => (q[7] === 'Sliding' ? t : -1)).filter((t) => t >= 0);
    const first = sliding[0];
    const last = sliding[sliding.length - 1];
    check(`a Crouch press at a sprint (${fmt(speedOver(s, 30, 39))} studs/s) starts the slide on its tick and it lasts 0.70 s (${sliding.length} ticks)`,
      first === 40 && sliding.length === 21 && last === 60, { first, ticks: sliding.length });
    const length = horizontal(s, first - 1, last);
    info(`the slide on open floor: ${fmt(length)} studs in ${fmt(sliding.length / 30, 2)} s`);
    check(`the slide covers 10.5 studs on open floor (${fmt(length)})`, Math.abs(length - 10.5) < 0.02);
    // the profile: 17 falling linearly to 13 over 0.7 s, tick by tick
    const dist = (t) => 17 * t - ((4 / 0.7) * t * t) / 2;
    let worst = 0;
    for (let k = 1; k <= 21; k++) worst = Math.max(worst, Math.abs(horizontal(s, first + k - 2, first + k - 1) - (dist(k / 30) - dist((k - 1) / 30))));
    check(`the slide's speed falls from 17 to 13 tick by tick (largest error ${worst.toExponential(1)} studs a tick)`, worst < 1e-6);
    check('the sliding body is 3.7 tall, then 5.2 again', sliding.every((t) => Math.abs(s[t][9] - 3.7) < 1e-9) && Math.abs(s[last + 1][9] - 5.2) < 1e-9);
    check('the press is consumed: the slide ends standing up (sprinting on, never crouched)',
      s.slice(last + 1).every((q) => q[7] === 'Sprinting'), s.slice(last + 1, last + 4).map((q) => q[7]));
    const slides = r.noises.filter((n) => n[1] === 'Slide');
    check('the slide is heard once (the Slide noise at its start)', slides.length === 1 && slides[0][0] === first, r.noises.filter((n) => n[1] !== 'Sprint'));
    for (const fps of [20, 60, 144]) {
      const d = compare(r.states, rates[fps].states);
      check(`the slide at ${fps} fps gives the 30 fps tick states`, d.max <= TOLERANCE, d.first || `max ${d.max.toExponential(2)}`);
    }
    // the eye: the crouched camera state (eye 1.5 under the standing one) while sliding
    const eye = await sandbox.tab.evaluate(() => {
      const e = window.__rovloc.engine;
      const p = e.player;
      window.__lab.play({ trace: [[0, 'at', 40, -400, 0], [2, 'key', 'KeyW', true], [2, 'sprint', true], [40, 'crouch']], ticks: 46, frames: 60 });
      return { state: p.moveState, camera: p.cameraState };
    });
    check('a slide is seen from the crouched eye (camera state Crouching)', eye.state === 'Sliding' && eye.camera === 'Crouching', eye);
    // no slide without the speed: a walk's Crouch press crouches
    const walk = await play({ trace: [[0, 'at', 40, -400, 0], [2, 'key', 'KeyW', true], [40, 'crouch']], ticks: 50, frames: 30 });
    check('at a walk (11) the Crouch press crouches, no slide', walk.states.slice(40).every((q) => q[7] === 'Crouching'), walk.states[41][7]);
    const released = await play({ trace: [[0, 'at', 40, -400, 0], [2, 'key', 'KeyW', true], [2, 'sprint', true], [40, 'sprint', false],
      [40, 'crouch']], ticks: 50, frames: 30 });
    check('Sprint let go on the tick of the press: it crouches, no slide (still at 19 then)', released.states.slice(40).every((q) => q[7] === 'Crouching'),
      released.states[40][7]);
    // no jump while sliding
    const hop = await play({ trace: open([[45, 'jump', true], [46, 'jump', false]]), ticks: 62, frames: 30 });
    check('Jump does nothing during a slide', hop.states.slice(40, 61).every((q) => q[4] <= 1e-9 && q[7] === 'Sliding'));
    // steering: the look turned 90 degrees at the slide's start, W held: the heading turns at 30 degrees a second at most
    const steer = await play({ trace: open([[41, 'yaw', Math.PI / 2]]), ticks: 62, frames: 30 });
    const ss = steer.states;
    const angles = [];
    for (let t = 41; t <= 60; t++) angles.push(Math.atan2(-(ss[t][0] - ss[t - 1][0]), -(ss[t][2] - ss[t - 1][2])));
    const turns = angles.slice(1).map((a, i) => (Math.abs(a - angles[i]) * 180) / Math.PI);
    const total = ((angles[angles.length - 1] - angles[0]) * 180) / Math.PI;
    check(`steering: at most 30 degrees a second (largest turn ${fmt(Math.max(...turns))} degrees a tick; ${fmt(total, 1)} over the slide)`,
      Math.max(...turns) <= 1 + 1e-6 && total > 15 && total < 21);
    // the bar (lane x 70: 4.2 clear across z -500..-502): sprinting into it stops; a slide passes under; so does a crouch-walk
    const barLane = (extra) => [[0, 'at', 70, -400, 0], [2, 'key', 'KeyW', true], [2, 'sprint', true], ...extra];
    const blocked = await play({ trace: barLane([]), ticks: 200, frames: 30 });
    const furthest = Math.min(...blocked.states.map((q) => q[2] - lab.O.z));
    check(`sprinting into the slide bar standing stops at its face (root reaches z ${fmt(furthest)}; the bar starts at -500)`, furthest > -500);
    const at = zTick(blocked.states, -494);
    const under = await play({ trace: barLane([[at, 'crouch']]), ticks: at + 40, frames: 30 });
    const past = Math.min(...under.states.map((q) => q[2] - lab.O.z));
    check(`a slide started 6 studs before the bar passes under it (root to z ${fmt(past)}, the bar ends at -502)`, past < -503.5 &&
      under.states.slice(at).some((q) => q[7] === 'Sliding'));
    for (const fps of [20, 144]) {
      const again = await play({ trace: barLane([[at, 'crouch']]), ticks: at + 40, frames: fps });
      const d = compare(under.states, again.states);
      check(`the slide under the bar at ${fps} fps gives the 30 fps tick states`, d.max <= TOLERANCE, d.first || `max ${d.max.toExponential(2)}`);
    }
    const crouchWalk = await play({ trace: [[0, 'at', 70, -480, 0], [1, 'crouch'], [2, 'key', 'KeyW', true]], ticks: 150, frames: 30 });
    check('crouch-walking (5.5) passes under the bar too', Math.min(...crouchWalk.states.map((q) => q[2] - lab.O.z)) < -503.5);
    // under the low ceiling (lane x 100: 4.2 clear from z -490): the slide ends crouched
    const ceilLane = [[0, 'at', 100, -400, 0], [2, 'key', 'KeyW', true], [2, 'sprint', true]];
    const toCeil = await play({ trace: ceilLane, ticks: 200, frames: 30 });
    const go = zTick(toCeil.states, -484);
    const ceil = await play({ trace: [...ceilLane, [go, 'crouch']], ticks: go + 40, frames: 30 });
    const end = ceil.states.findIndex((q, t) => t > go && q[7] !== 'Sliding');
    check(`a slide that ends under a low ceiling ends crouched (${ceil.states[end] ? ceil.states[end][7] : '-'} at z ${ceil.states[end] ? fmt(ceil.states[end][2] - lab.O.z) : '-'})`,
      end > go && ceil.states[end][7] === 'Crouching' && ceil.states[end][2] - lab.O.z < -490 && Math.abs(ceil.states[end][9] - 3.7) < 1e-9);
  });

  await runCase('leap', async () => {
    // the runway's lane A (x 260, a level pad) and B (x 340, a pad 2 lower): sprint from 58 studs before the lip
    const lane = (x, extra = [], yaw = 0) => [[0, 'at', x, -382, yaw, 12], [2, 'key', 'KeyW', true], [2, 'sprint', true], ...extra];
    const plain = await play({ trace: lane(260), ticks: 140, frames: 30 });
    const ps = plain.states;
    const inStrip = ps.findIndex((q) => toLip(q) <= 3);
    const inBand = ps.findIndex((q) => toLip(q) <= 7.5);
    const beforeBand = ps.findIndex((q) => toLip(q) <= 11);
    const pastLip = ps.findIndex((q) => toLip(q) < 0);
    const airborne = ps.findIndex((q, t) => t > pastLip - 1 && q[6] === 0);
    check('no press: the runner runs off the lip and falls into the gap (the slab 12 below)', !ps.some((q) => q[7] === 'Leaping') &&
      ps.some((q) => q[6] === 1 && Math.abs(q[8] - lab.O.y) < 0.05));
    const landing = (s, from) => s.findIndex((q, t) => t > from && q[7] !== 'Leaping' && q[6] === 1);
    // on time: Jump in the strip (3 studs before the lip; a press at the tick start reads the root at the end of the last)
    const rates = {};
    for (const fps of RATES) rates[fps] = await play({ trace: lane(260, [[inStrip + 1, 'jump', true], [inStrip + 2, 'jump', false]]), ticks: 140, frames: fps });
    const r = rates[30];
    const s = r.states;
    const leaping = s.map((q, t) => (q[7] === 'Leaping' ? t : -1)).filter((t) => t >= 0);
    const start = leaping[0];
    check(`on time (Jump 3 studs before the lip): the leap starts on that tick and lasts 0.60 s (${leaping.length} ticks)`,
      start === inStrip + 1 && leaping.length === 18 && r.leaps.length === 1, { start, ticks: leaping.length, leaps: r.leaps });
    // the curve: the root on ParkourRules.leap from the take-off (the spec's numbers: 0.6 s, to 2 past the far edge, apex 2)
    const origin = s[start - 1];
    const takeoff = toLip(origin);
    let worst = 0;
    for (let k = 1; k <= 18; k++) {
      const u = Math.min(1, k / 18);
      const along = (takeoff + 12 + 2) * u;
      const q = s[start + k - 1];
      worst = Math.max(worst, Math.abs(q[2] - (origin[2] - along)), Math.abs(q[0] - origin[0]), Math.abs(q[1] - (origin[1] + 4 * 2 * u * (1 - u))));
    }
    check(`the leap follows the curve tick by tick: a straight line to 2 past the far edge, apex 2.0 (largest error ${worst.toExponential(1)})`, worst < 1e-6);
    const land = landing(s, start);
    const landZ = s[land][2] - lab.O.z;
    info(`the leap: ${fmt(leaping.length / 30, 2)} s from a take-off ${fmt(takeoff, 2)} before the lip; the curve ends at z ${fmt(origin[2] - lab.O.z - (takeoff + 14))} (2 past the far edge at -452); the first tick standing at z ${fmt(landZ)}`);
    check(`it lands on the pad (feet at 12, z ${fmt(landZ)} past the far edge -452) and leaves at 17 along the leap`,
      Math.abs(s[land][8] - lab.O.y - 12) < 0.05 && landZ < -452 && Math.abs(s[start + 17][5] + 17) < 1e-6, { land: s[land], exit: s[start + 17] });
    const jl = r.noises.filter((n) => n[1] === 'JumpLand');
    check('the leap\'s landing is heard (JumpLand once, nothing louder)', jl.length === 1 && !r.noises.some((n) => n[1] === 'HardLanding'), r.noises.filter((n) => n[1] !== 'Sprint'));
    for (const fps of [20, 60, 144]) {
      const d = compare(s, rates[fps].states);
      check(`the leap at ${fps} fps gives the 30 fps tick states`, d.max <= TOLERANCE, d.first || `max ${d.max.toExponential(2)}`);
    }
    // the pad 2 lower (lane B)
    const low = await play({ trace: lane(340, [[inStrip + 1, 'jump', true], [inStrip + 2, 'jump', false]]), ticks: 140, frames: 30 });
    const lowLand = landing(low.states, inStrip + 1);
    check('onto a pad 2 lower: the same leap, standing on it after', low.leaps.length === 1 && Math.abs(low.states[lowLand][8] - lab.O.y - 10) < 0.05 &&
      low.states[lowLand][2] - lab.O.z < -452);
    // early: Jump in the band before the strip (7.5 before the lip) is held, and the leap starts in the strip
    const early = await play({ trace: lane(260, [[inBand + 1, 'jump', true], [inBand + 2, 'jump', false]]), ticks: 140, frames: 30 });
    const eLeap = early.leaps[0];
    check(`early (Jump 7.5 before the lip, in the band): no free jump, the request waits and the leap starts in the strip (take-off ${eLeap ? fmt(eLeap.takeoff, 2) : '-'} before the lip, ${eLeap ? eLeap.tick - inBand - 1 : '-'} ticks later)`,
      !!eLeap && eLeap.takeoff <= 4 && eLeap.takeoff > 4 - 19 / 30 - 0.01 && (eLeap.tick - inBand - 1) / 30 <= 0.3 &&
      early.states.slice(inBand, eLeap.tick).every((q) => q[4] <= 1e-9));
    // too early: Jump 11 before the lip (outside the band) is a free jump; no leap, the gap is not crossed
    const tooEarly = await play({ trace: lane(260, [[beforeBand + 1, 'jump', true], [beforeBand + 2, 'jump', false]]), ticks: 160, frames: 30 });
    check('too early (11 before the lip, outside the band): a free jump, no leap; the runner ends in the gap',
      tooEarly.leaps.length === 0 && tooEarly.states.some((q) => q[4] > 10) && tooEarly.states.some((q) => q[6] === 1 && Math.abs(q[8] - lab.O.y) < 0.05));
    // late: Jump just after running off the lip (in the air, within 0.10 s) still leaps; later does not
    const late = await play({ trace: lane(260, [[airborne + 1, 'jump', true], [airborne + 2, 'jump', false]]), ticks: 140, frames: 30 });
    const lLeap = late.leaps[0];
    check(`late (Jump in the air ${airborne + 1 - pastLip} tick(s) after crossing the lip): the leap still starts (take-off ${lLeap ? fmt(lLeap.takeoff, 2) : '-'}) and lands on the pad`,
      !!lLeap && lLeap.takeoff < 0 && landing(late.states, lLeap.tick) > 0 && Math.abs(late.states[landing(late.states, lLeap.tick)][8] - lab.O.y - 12) < 0.05);
    const tooLate = await play({ trace: lane(260, [[pastLip + 5, 'jump', true], [pastLip + 6, 'jump', false]]), ticks: 140, frames: 30 });
    check('too late (0.13 s after crossing the lip): no leap, the runner falls into the gap', tooLate.leaps.length === 0 &&
      tooLate.states.some((q) => q[6] === 1 && Math.abs(q[8] - lab.O.y) < 0.05));
    // under 15 studs/s: a walk (11) with Jump in the strip
    const walk = await play({ trace: [[0, 'at', 260, -420, 0, 12], [2, 'key', 'KeyW', true]], ticks: 80, frames: 30 });
    const wStrip = walk.states.findIndex((q) => toLip(q) <= 2);
    const slow = await play({ trace: [[0, 'at', 260, -420, 0, 12], [2, 'key', 'KeyW', true], [wStrip + 1, 'jump', true], [wStrip + 2, 'jump', false]], ticks: 90, frames: 30 });
    check(`walking (${fmt(speedOver(walk.states, wStrip - 6, wStrip))} studs/s, under 15): Jump in the strip leaps nowhere and frees no jump; the runner walks off into the gap`,
      slow.leaps.length === 0 && slow.states.slice(wStrip, wStrip + 5).every((q) => q[4] <= 1e-9) &&
      slow.states.some((q) => q[6] === 1 && Math.abs(q[8] - lab.O.y) < 0.05));
    // the heading: 40 degrees off the leap never leaps, 30 does (the runner starts to the side and crosses the strips)
    const angled = (deg) => {
      const yaw = (deg * Math.PI) / 180;
      return [[0, 'at', 260 + 58 * Math.tan(yaw), -382, yaw, 12], [2, 'key', 'KeyW', true], [2, 'sprint', true]];
    };
    for (const [deg, want] of [[40, false], [30, true]]) {
      const pre = await play({ trace: angled(deg), ticks: 140, frames: 30 });
      const t = pre.states.findIndex((q) => toLip(q) <= 2);
      const tr = await play({ trace: [...angled(deg), [t + 1, 'jump', true], [t + 2, 'jump', false]], ticks: 140, frames: 30 });
      check(`${deg} degrees off the leap's line at a sprint: ${want ? 'it leaps' : 'no leap'}`, (tr.leaps.length === 1) === want, tr.leaps);
    }
    // leap assist: On leaps with no press at all; Auto on a keyboard and Off do not
    for (const [setting, want] of [['On', true], ['Auto', false], ['Off', false]]) {
      const tr = await play({ trace: lane(260, [[1, 'assist', setting]]), ticks: 140, frames: 30 });
      const a = tr.leaps[0];
      check(`Leap assist ${setting} (keyboard), no press: ${want ? `it leaps at the strip (take-off ${a ? fmt(a.takeoff, 2) : '-'})` : 'no leap'}`,
        (tr.leaps.length === 1) === want && (!want || (a.takeoff <= 4 && a.takeoff > 3)));
    }
    // never blind: the five rays from a sprinting eye 20 studs before the strip reach the pad; a wall over the gap hides it
    const sight = await sandbox.tab.evaluate(() => {
      const { strips } = window.__lab;
      const kit = window.__rovloc.engine.player.parkour;
      return { A: kit.sight(strips.A), B: kit.sight(strips.B), blind: kit.sight(strips.Blind) };
    });
    check(`never blind: 5 of 5 rays reach each fixture pad (A ${sight.A}, B ${sight.B}); the walled one is seen blind (${sight.blind} of 5)`,
      sight.A === 5 && sight.B === 5 && sight.blind < 5, sight);
  });

  await runCase('landing', async () => {
    // off the runway's west side at a sprint: a 12-stud fall onto open floor is a hard landing; 0.6 s at 40 %, heard
    const trace = [[0, 'at', 226, -410, Math.PI / 2, 12], [2, 'key', 'KeyW', true], [2, 'sprint', true]];
    const r = await play({ trace, ticks: 80, frames: 30 });
    const s = r.states;
    const land = s.findIndex((q, t) => t > 2 && q[6] === 1 && Math.abs(q[8] - lab.O.y) < 0.05);
    const hard = r.noises.filter((n) => n[1] === 'HardLanding');
    check(`a 12-stud fall lands hard: the HardLanding noise once, on the landing tick (${hard.length ? hard[0][0] : '-'} / ${land})`,
      hard.length === 1 && hard[0][0] === land && !r.noises.some((n) => n[1] === 'JumpLand'), r.noises.filter((n) => n[1] !== 'Sprint'));
    const slow = speedOver(s, land + 12, land + 17);
    const after = speedOver(s, land + 30, land + 40);
    check(`for 0.6 s after it the body moves at 40 % (${fmt(slow)} studs/s, 40 % of 19 is 7.6), then at its sprint again (${fmt(after)})`,
      slow <= 7.6 * 1.01 && slow > 6 && after > 18.5);
    // a small drop (the 4-high ledge, walked off) is neither
    const ledge = await play({ trace: [[0, 'at', 360, 0, 0, 4], [3, 'key', 'KeyW', true]], ticks: 60, frames: 30 });
    check('a drop of 4 is no hard landing', !ledge.noises.some((n) => n[1] === 'HardLanding'));
    // a standing jump's landing (0.33 s in the air) is heard as JumpLand
    const hop = await play({ trace: [[0, 'at', 0, 40, 0], [5, 'jump', true], [6, 'jump', false]], ticks: 30, frames: 30 });
    check('a jump\'s landing is heard (JumpLand once)', hop.noises.filter((n) => n[1] === 'JumpLand').length === 1, hop.noises);
    for (const fps of [20, 144]) {
      const again = await play({ trace, ticks: 80, frames: fps });
      const d = compare(s, again.states);
      check(`the hard landing at ${fps} fps gives the 30 fps tick states`, d.max <= TOLERANCE && again.noises.filter((n) => n[1] === 'HardLanding').length === 1,
        d.first || `max ${d.max.toExponential(2)}`);
    }
  });

  await runCase('lookback', async () => {
    // V held while walking: the view turns 150 degrees in 0.18 s (6 ticks), the walk keeps its heading; released, back
    const trace = [[0, 'at', 0, 40, 0], [2, 'key', 'KeyW', true], [20, 'lookback', true], [40, 'lookback', false]];
    const r = await play({ trace, ticks: 60, frames: 60 });
    const s = r.states;
    const shares = s.slice(19, 28).map((q) => q[10]);
    check(`held, the turn grows over 0.18 s to the full 150 degrees (shares ${shares.map((v) => fmt(v, 2)).join(' ')})`,
      s[19][10] === 0 && s[20][10] > 0 && s[24][10] < 1 && s[25][10] === 1 && s[39][10] === 1);
    check('released, it turns back as fast', s[40][10] < 1 && s[45][10] === 0);
    check('movement keeps its heading (straight ahead, -z, the whole time)', s.slice(10, 60).every((q) => Math.abs(q[0] - s[10][0]) < 1e-9) &&
      horizontal(s, 20, 40) > 6);
    const view = await sandbox.tab.evaluate(() => {
      const e = window.__rovloc.engine;
      const p = e.player;
      window.__lab.play({ trace: [[0, 'at', 0, 40, 0], [2, 'lookback', true]], ticks: 12, frames: 60 });
      e.input.inject('LookBack', 'lab', true);
      e.loop.stepManual(1 / 60);
      const fwd = new (p.body.position.constructor)(0, 0, -1).applyQuaternion(e.renderer.camera.quaternion);
      const turned = Math.atan2(-fwd.x, -fwd.z) - p.yaw;
      e.input.inject('LookBack', 'lab', false);
      // in a vent (not on foot) it never turns
      window.__lab.play({ trace: [[0, 'at', 0, 40, 0], [1, 'mode', 'Vent'], [2, 'lookback', true]], ticks: 12, frames: 60 });
      const vent = p.parkour.lookNow;
      p.setMode('OnFoot');
      return { turned: ((turned * 180) / Math.PI + 720) % 360, vent };
    });
    check(`the camera looks 150 degrees from the heading (${fmt(view.turned, 2)})`, Math.abs(view.turned - 150) < 0.5);
    check('in a vent the look-back does nothing (on foot only)', view.vent === 0, view);
    for (const fps of [20, 144]) {
      const again = await play({ trace, ticks: 60, frames: fps });
      const d = compare(s, again.states);
      check(`the look-back at ${fps} fps gives the 60 fps tick states`, d.max <= TOLERANCE, d.first || `max ${d.max.toExponential(2)}`);
    }
  });
} finally {
  if (sandbox) await sandbox.context.close();
}

// ---------------------------------------------------------------------------------------------------- the game page

/**
 * On the game test page: the same preamble at 30 fps (title, deploy, the Creature told to ignore the player), then a
 * walk through Level 1, the vent rail segment and the parachute segment at `fps`, each started on a tick and recorded
 * tick by tick.
 */
async function gameRun(fps) {
  const { tab, context } = await open(gameHtml, '?dev&seed=1029', { Graphics: 'Low', TutorialDone: true, MotionScale: 0 });
  try {
    return await tab.evaluate(async (rate) => {
      const e = window.__rovloc.engine;
      const { game: g, dev } = window.__rovlocGame;
      const loop = e.loop;
      loop.stop();
      e.quality.adapt = false;
      e.skipRender = true;
      const TICK = loop.tickDt;
      const step30 = async (n) => {
        for (let i = 0; i < n; i++) {
          loop.stepManual(TICK);
          if (i % 15 === 0) await null;
        }
      };
      /**
       * Runs `ticks` ticks at `fps`, calling `op(r)` at the start of tick r (before the player's tick) and recording
       * the body at its end; the last frame is cut short so that no tick past the segment runs.
       */
      const segment = async (fps, ticks, op, extra) => {
        const base = loop.tickCount;
        const states = [];
        const offOp = loop.onTick(() => {
          const r = loop.tickCount - base - 1;
          if (r < ticks) op(r);
        }, -1000);
        const offRec = loop.onTick(() => {
          const b = e.player.body;
          if (loop.tickCount - base <= ticks) {
            states.push([b.position.x, b.position.y, b.position.z, b.velocity.x, b.velocity.y, b.velocity.z,
              b.grounded ? 1 : 0, e.player.moveState, e.player.mode, ...(extra ? extra() : [])]);
          }
        }, 1e9);
        try {
          let n = 0;
          while (loop.tickCount - base < ticks) {
            const remaining = ticks - (loop.tickCount - base);
            const dt = Math.min(1 / fps, (remaining + 0.5) * TICK - loop.accumulator);
            loop.stepManual(dt);
            if (++n % 30 === 0) await null;
          }
        } finally {
          offOp();
          offRec();
        }
        return states;
      };
      await step30(30);
      dev.skipTitle();
      await step30(15);
      dev.deploy();
      let guard = 1200;
      while (!(g.phase === 'InRun' && g.level === 'Level0_Basement' && g.levelActive) && guard-- > 0) await step30(1);
      if (guard <= 0) return { error: `no run: ${g.phase} ${g.level}` };
      g.creature.devCommand('ignoreme');
      dev.gotoLevel('Level1_Hallways');
      await step30(30);
      const input = e.input;
      // a walk from the Level 1 spawn (walking, sprinting, turning, a crouch): the body, and the eye the levels see
      // (game.eye() and the local subject's)
      let yaw0 = e.player.yaw;
      const walk = await segment(rate, 120, (r) => {
        if (r === 0) yaw0 = e.player.yaw;
        if (r === 2) input.keys.add('KeyW');
        if (r === 20) input.inject('Sprint', 'lab', true);
        if (r >= 30 && r < 70) e.player.setLook(yaw0 + (r - 30) * 0.04, 0);
        if (r === 80) input.inject('Sprint', 'lab', false);
        if (r === 85 || r === 105) {
          input.inject('Crouch', 'lab', true);
          input.inject('Crouch', 'lab', false);
        }
        if (r === 112) input.keys.delete('KeyW');
      }, () => {
        const eye = g.eye();
        const subject = g.subjects()[0];
        return [eye.x, eye.y, eye.z, subject ? subject.eye.x : NaN, subject ? subject.eye.y : NaN, subject ? subject.eye.z : NaN];
      });
      input.keys.clear();
      await step30(15);
      // the vent rail: into the Level 1 bypass duct, crawling, scurrying, turning
      const grates = g.vents.gratesOn('Level1_Hallways').filter((x) => x.info.attributes.CriticalPath);
      const east = grates.reduce((a, b) => (a.centre.x > b.centre.x ? a : b));
      let entered = null;
      const vent = await segment(rate, 150, (r) => {
        if (r === 0) {
          g.vents._enter(east);
          entered = e.player.body.position.clone();
          yaw0 = e.player.yaw;
        }
        if (r === 2) input.keys.add('KeyW');
        if (r === 40) input.inject('Sprint', 'lab', true);
        if (r >= 60 && r < 90) e.player.setLook(yaw0 + (r - 60) * 0.02, 0);
        if (r === 100) input.inject('Sprint', 'lab', false);
        if (r === 140) input.keys.delete('KeyW');
      });
      const crawled = g.vents.inVent();
      if (g.vents.inVent()) g.vents.leave();
      input.keys.clear();
      dev.gotoLevel('Level3_Roof');
      await step30(30);
      // a fall of 15 onto the roof (open air): a hard landing, and never damage
      const before = { health: g.life.health, life: g.life.state };
      // a spot of open roof near the arrival: the floor under it at the arrival's height, nothing over it for 20 studs
      const here = e.player.body.position.clone();
      const Vec = here.constructor;
      let top = here;
      for (let i = 0; i < 64 && top === here; i++) {
        const a = (i % 16) * (Math.PI / 8);
        const r = 12 + 6 * Math.floor(i / 16);
        const at = new Vec(here.x + Math.sin(a) * r, here.y + 16, here.z + Math.cos(a) * r);
        const down = e.world.raycast(at, new Vec(0, -1, 0), 40);
        if (down && Math.abs(down.point.y - (here.y - 3)) < 0.5 && !e.world.raycast(new Vec(at.x, down.point.y + 0.5, at.z), new Vec(0, 1, 0), 20)) {
          top = new Vec(at.x, down.point.y + 3, at.z);
        }
      }
      let hard = 0;
      const offHard = e.player.hardLanded.connect(() => hard++);
      const fallen = await segment(rate, 45, (r) => {
        if (r === 0) e.player.teleport({ position: { x: top.x, y: top.y + 15, z: top.z }, yaw: e.player.yaw });
      });
      offHard();
      const drop = { hard, before, after: { health: g.life.health, life: g.life.state }, grounded: fallen[fallen.length - 1][6],
        fell: top.y + 15 - fallen[fallen.length - 1][1] };
      // the parachute: a pack and off the gap, the ripcord after 10 ticks, the canopy down to the landing
      const chute = [];
      const parachute = await segment(rate, 360, (r) => {
        if (r === 0) g.parachute.devJump();
        if (r === 10) g.parachute.pull();
        if (r % 60 === 0) chute.push(`${r}:${g.parachute.state}`);
      });
      // where entering left the body against where the drive's first tick (no input yet) holds it
      const entryJump = Math.hypot(vent[0][0] - entered.x, vent[0][1] - entered.y, vent[0][2] - entered.z);
      return { walk, vent, entryJump, parachute, crawled, chute, landed: g.parachute.state, drop };
    }, fps);
  } finally {
    await context.close();
  }
}

const gameLogs = {};
async function gameRuns() {
  if (Object.keys(gameLogs).length) return;
  for (const fps of [20, 144]) {
    const t0 = Date.now();
    gameLogs[fps] = await gameRun(fps);
    if (gameLogs[fps].error) throw new Error(gameLogs[fps].error);
    info(`${fps} fps: ${((Date.now() - t0) / 1000).toFixed(0)} s; parachute ${gameLogs[fps].chute.join(' ')}; finally ${gameLogs[fps].landed}`);
  }
}

await runCase('overrides', async () => {
  await gameRuns();
  const a = gameLogs[20];
  const b = gameLogs[144];
  const ventMoved = Math.hypot(a.vent[149][0] - a.vent[1][0], a.vent[149][2] - a.vent[1][2]);
  check('the vent rail drove the body (mode Vent, moved along the duct)', a.vent.slice(1).every((q) => q[8] === 'Vent') && ventMoved > 5, { moved: ventMoved });
  check(`entering a vent puts the body on the rail at once (the drive's first tick moves it ${a.entryJump.toExponential(1)} studs; the camera has no jump to slide through)`,
    a.entryJump < 1e-6 && b.entryJump < 1e-6, [a.entryJump, b.entryJump]);
  const v = compare(a.vent, b.vent);
  check(`the vent rail: identical tick states at 20 and 144 fps (${a.vent.length} ticks)`, v.max <= TOLERANCE, v.first || `max difference ${v.max.toExponential(2)}`);
  const canopy = a.parachute.filter((q) => q[7] === 'Parachuting').length;
  check('the parachute flew (freefall, then the canopy override) and landed', canopy > 20 && a.landed === 'Landed' && b.landed === 'Landed',
    { canopyTicks: canopy, chute: a.chute });
  const c = compare(a.parachute, b.parachute);
  check(`the parachute: identical tick states at 20 and 144 fps (${a.parachute.length} ticks)`, c.max <= TOLERANCE, c.first || `max difference ${c.max.toExponential(2)}`);
});

await runCase('senses', async () => {
  await gameRuns();
  const a = gameLogs[20].walk;
  const b = gameLogs[144].walk;
  const moved = a.reduce((sum, q, t) => (t ? sum + Math.hypot(q[0] - a[t - 1][0], q[2] - a[t - 1][2]) : 0), 0);
  const states = [...new Set(a.map((q) => q[7]))];
  check(`the walk through Level 1 moved ${fmt(moved, 1)} studs (${states.join(', ')})`, moved > 8 && states.includes('Crouching'), { moved, states });
  // CameraConfig.EyeHeightAboveRoot (LevelKit.eyeOf): Standing 1.5, Sprinting 1.4, Crouching 0
  const HEIGHT = { Standing: 1.5, Sprinting: 1.4, Crouching: 0 };
  const off = a.filter((q) => !(Math.abs(q[9] - q[0]) < 1e-9 && Math.abs(q[11] - q[2]) < 1e-9 && Math.abs(q[10] - q[1] - HEIGHT[q[7]]) < 1e-9 &&
    q[12] === q[9] && q[13] === q[10] && q[14] === q[11]));
  check('the eye the levels see (game.eye(), the local subject) is the tick root plus the MoveState\'s eye height on every tick',
    off.length === 0, off.length ? { ticks: off.length, first: off[0] } : undefined);
  const d = compare(a, b);
  check(`the walk and the levels' eye: identical tick states at 20 and 144 fps (${a.length} ticks)`, d.max <= TOLERANCE, d.first || `max difference ${d.max.toExponential(2)}`);
});

await runCase('falls', async () => {
  await gameRuns();
  for (const fps of [20, 144]) {
    const d = gameLogs[fps].drop;
    check(`${fps} fps, in the game: a fall of ${fmt(d.fell, 1)} onto the roof lands hard once and never damages (health ${d.before.health} -> ${d.after.health}, ${d.after.life})`,
      d.hard === 1 && d.fell >= 8 && d.grounded === 1 && d.after.health === d.before.health && d.after.life === 'Alive', d);
  }
});

await browser.close();
if (pageErrors.length) {
  current = { name: 'pages', checks: [] };
  caseResults.push(current);
  check('no page errors', false, pageErrors.slice(0, 5).join(' | '));
}

console.log('\nSUMMARY');
let failed = 0;
for (const c of caseResults) {
  const bad = c.checks.filter((x) => !x.ok).length;
  if (bad) failed++;
  console.log(`  ${bad ? 'FAIL' : 'PASS'} ${c.name}: ${c.checks.length - bad}/${c.checks.length} checks`);
}
console.log(failed ? `PARKOUR TEST FAILED (${failed} case${failed > 1 ? 's' : ''})` : 'PARKOUR TEST PASSED');
process.exit(failed ? 1 : 0);
