// lives-test.mjs: the lives (docs/design/game-spec-v2.md 3.3) on the website, against the rules and in the game.
//
//   node tools/lives-test.mjs [--no-build] [--html <page>] [--only rules,page]
//
// rules   src/game/rules/lives.js, the port of Shared/Rules/LivesRules.luau over the world's numbers, replays every
//         LivesRules row of build/cache/golden.json (numbers within 1e-9); then the spec's numbers, written here from the
//         spec's text (never read back from meta.livesConfig): the get-up from 3 s, held 4 s [6 s], up at 50 [35]; the
//         stage respawn set back at each playable stage and never banked; Nightmare's one respawn for the run; the
//         syringe's spent last; out of respawns the run's end alone and spectating in a squad; the checkpoint return at
//         50; levelAt by box (x, y and z) over the stages, a set's box included.
// page    the game test page (game-build.mjs, unminified), one solo run per difficulty from the deploy: the Back Lot's
//         stand-in (its card, skipped), the Basement's lives (Standard: one stage respawn; Nightmare: one for the run);
//         a down, the get-up offered from 3 s and up after 4 s [6 s] of holding Interact at 50 [35], its chevron spent;
//         the next lethal hit kills; the respawn: 4 s of black with NOT YET., at this player's spawn at the stage's
//         entry at 50 [35], the Creature (put beside that entry first) moved at least 70 studs walked from it and 45
//         from the player, its next teleport at least 45 s off, the player ignored (not seen, heard or caught) for
//         10 s [6 s] and noticed again after; the get-up given back; the fuse carried dropped where they fell and pinned;
//         Standard: the next stage's activation sets the stage respawn back to 1, an unused one is not banked;
//         Nightmare: out of respawns the next death ends the solo run (THE NIGHT TOOK YOU).
// pieces  the co-op message registry (events.js: registered once, validated, rate limited, the sender's life state and
//         the phase, the host's word only from the host), the strings split (a package's file adds its lines, a key
//         defined twice refused), the creature event feed (a stun's Stun and State events, in the page run).
// Exit code 1 on any failure.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { EventRegistry } from '../src/game/coop/events.js';
import { livesRules } from '../src/game/rules/lives.js';
import { levelAt } from '../src/game/stages.js';
import { S as S_, defineStrings } from '../src/game/strings/index.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.resolve(here, '..');
const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const only = new Set(opt('--only', 'rules,page').split(','));
const failures = [];
let checks = 0;

function check(name, ok, detail) {
  checks++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail !== undefined ? ` ${JSON.stringify(detail)}` : ''}`);
  if (!ok) failures.push(name);
  return ok;
}

const meta = JSON.parse(fs.readFileSync(path.join(web, 'build/world.json'), 'utf8'));
const R = livesRules(meta);
const S = 'Standard';
const N = 'Nightmare';
const L = (stage, run, syringe, downs, used) => ({ stage, run, syringe, downs, getUpUsed: used });

// ------------------------------------------------------------------------------------------------ the rules
if (only.has('rules')) {
  console.log('== the rules (rules/lives.js)');
  const golden = JSON.parse(fs.readFileSync(path.join(web, 'build/cache/golden.json'), 'utf8')).LivesRules || [];
  const same = (a, b) => {
    if (typeof a === 'number' || typeof b === 'number') return typeof a === 'number' && typeof b === 'number' && Math.abs(a - b) <= 1e-9;
    if (a && b && typeof a === 'object' && typeof b === 'object') {
      const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
      return [...keys].every((k) => same(a[k], b[k]));
    }
    return a === b;
  };
  const bad = [];
  const fns = new Set();
  for (const row of golden) {
    fns.add(row.fn);
    const fn = R[row.fn];
    const got = typeof fn === 'function' ? fn(...row.args) : undefined;
    if (!same(got, row.expect)) bad.push({ row: row.name, got, want: row.expect });
  }
  check(`every LivesRules golden row replays exactly (${golden.length} rows over ${fns.size} functions)`,
    golden.length >= 150 && fns.size === 13 && bad.length === 0, bad.slice(0, 3));

  // the spec's numbers, from its text
  const downed = L(1, 0, 0, 1, false);
  check('get-up: not before 3 s down', !R.getUp(S, downed, 2.99, 10).allowed && !R.getUp(N, downed, 2.99, 10).allowed);
  check('get-up Standard: 4 s of holding, up at 50', !R.getUp(S, downed, 3, 3.99).up && R.getUp(S, downed, 3, 4).up &&
    R.getUp(S, downed, 3, 4).health === 50);
  check('get-up Nightmare: 6 s of holding, up at 35', !R.getUp(N, downed, 9, 5.99).up && R.getUp(N, downed, 9, 6).up &&
    R.getUp(N, downed, 9, 6).health === 35);
  check('get-up: once a stage', !R.getUp(S, L(1, 0, 0, 1, true), 30, 30).allowed);
  check('get-up: 7 s [9 s] from going down', R.getUpTime(S) === 7 && R.getUpTime(N) === 9);
  check('revive: 4 s, 50 health on both', [S, N].every((d) => !R.revive(d, 3.99).up && R.revive(d, 4).health === 50));
  const first = R.lethal(R.stageActivated(S, R.newRun(S, false), 'Level0_Basement'), 'Alive', 'Catch');
  check('the first lethal hit on a stage downs, the next kills', first.outcome === 'Downed' &&
    R.lethal(first.lives, 'Alive', 'Damage').outcome === 'Killed' && R.lethal(first.lives, 'Downed', 'BleedOut').outcome === 'Killed');
  check('downs are per stage', R.lethal(R.stageActivated(S, first.lives, 'Level1_Hallways'), 'Alive', 'Damage').outcome === 'Downed');
  // the stage respawn: 1 on each of the seven playable stages, set back there, never banked
  const playable = ['Level0_Basement', 'Level1_Hallways', 'Level2_Auditorium', 'Level3_Roof', 'City1_Rooftops', 'City2_Airport', 'Runway'];
  let lives = R.newRun(S, false);
  check('Standard before the first stage: no respawn', R.respawnsLeft(lives) === 0);
  let banked = true;
  for (const id of playable) {
    lives = R.stageActivated(S, lives, id);
    if (lives.stage !== 1) banked = false;
  }
  check('Standard: the stage respawn is 1 at each playable stage\'s activation (never 2: not banked)', banked && lives.stage === 1);
  check('the sets hand out none', ['BackLot', 'Bahamas'].every((id) => R.stageActivated(S, L(0, 0, 0, 1, true), id).stage === 0));
  const spentHere = R.afterDeath(R.stageActivated(S, R.newRun(S, false), 'Level0_Basement'), 1);
  check('Standard: a respawn spends the stage\'s, and the next stage gives one back', spentHere.action === 'Respawn' &&
    spentHere.source === 'stage' && R.stageActivated(S, spentHere.lives, 'Level1_Hallways').stage === 1);
  // Nightmare: one respawn for the whole run
  let night = R.newRun(N, false);
  for (const id of playable) night = R.stageActivated(N, night, id);
  check('Nightmare: no stage respawn, one for the run', night.stage === 0 && night.run === 1 && R.respawnsLeft(night) === 1);
  const nightAfter = R.afterDeath(night, 1);
  check('Nightmare: the run respawn spent, the next stage gives none back', nightAfter.source === 'run' &&
    R.respawnsLeft(R.stageActivated(N, nightAfter.lives, 'Level1_Hallways')) === 0);
  // the syringe: one more, spent last
  const kit = R.stageActivated(S, R.newRun(S, true), 'Level0_Basement');
  const a = R.spend(kit);
  check('the syringe: one more respawn, spent after the stage\'s', R.respawnsLeft(kit) === 2 && a.source === 'stage' &&
    R.spend(a.lives).source === 'syringe');
  const nk = R.stageActivated(N, R.newRun(N, true), 'Level0_Basement');
  check('Nightmare with the syringe: the run\'s first, the syringe\'s last', R.spend(nk).source === 'run' &&
    R.spend(R.spend(nk).lives).source === 'syringe');
  // out of respawns
  check('out of respawns: the solo run ends, a squad member spectates', R.afterDeath(L(0, 0, 0, 1, true), 1).action === 'RunOver' &&
    R.afterDeath(L(0, 0, 0, 1, true), 2).action === 'Spectate');
  check('the run ends when nobody is Alive or Downed and nobody has a respawn left',
    R.runEnds([{ slot: 1, left: 0, lifeState: 'Dead' }, { slot: 2, left: 0, lifeState: 'Spectating' }]) &&
    !R.runEnds([{ slot: 1, left: 1, lifeState: 'Dead' }]) && !R.runEnds([{ slot: 1, left: 0, lifeState: 'Downed' }]));
  check('the checkpoint return: spectators and the dead stand up at 50 on both difficulties', [S, N].every((d) =>
    R.checkpointReturn(d, 'Spectating').stand && R.checkpointReturn(d, 'Dead').health === 50 && !R.checkpointReturn(d, 'Alive').stand));
  const back = R.respawn(S, 0, 10, 100);
  const backN = R.respawn(N, 0, 10, 100);
  check('the respawn: 4 s of black, 50 [35] health, 10 [6] s of grace, at least half the torch',
    back.blackout === 4 && back.health === 50 && back.grace === 10 && back.torch === 50 && backN.health === 35 && backN.grace === 6);
  check('the numbers come from meta.livesConfig (a world with other numbers answers with them)',
    livesRules({ ...meta, livesConfig: { Standard: { ...meta.livesConfig.Standard, GetUpHold: 5 }, Nightmare: meta.livesConfig.Nightmare } })
      .getUpTime(S) === 8);
  // levelAt by box
  const boxes = { ...meta, levels: { ...meta.levels, Runway: { aabb: [2800, -5, 1000, 3200, 60, 1400] } } };
  check('levelAt: the level whose box holds the point (x, y and z)', levelAt(meta, { x: 200, y: 3, z: 140 }) === 'Level0_Basement' &&
    levelAt(meta, { x: 200, y: 22, z: 140 }) === 'Level1_Hallways' && levelAt(meta, { x: 200, y: 70, z: 140 }) === 'Level3_Roof');
  check('levelAt: a set\'s box, and nothing outside every stage', levelAt(boxes, { x: 3000, y: 2, z: 1200 }) === 'Runway' &&
    levelAt(boxes, { x: 3000, y: 80, z: 1200 }) === null && levelAt(meta, { x: -780, y: 3, z: 20 }) === null);
}

// ------------------------------------------------------------------------------------------------ the small pieces
if (only.has('rules')) {
  console.log('== the pieces later packages plug into (co-op registry, strings)');
  // the co-op message registry: a fake room (the host, one client), a registered intent and a host word
  const squad = new Map([['c1', { id: 'c1', life: 'Alive' }]]);
  let role = 'host';
  const room = { localId: 'h', isHost: () => role === 'host', isClient: () => role === 'client', session: { hostId: 'h' },
    squad: { get: (id) => squad.get(id) }, game: { phase: 'InRun' } };
  const reg = new EventRegistry(room);
  const got = [];
  reg.register('ping', { to: 'host', phases: ['InRun'], life: ['Alive'], rate: 2, validate: (m) => typeof m.n === 'number',
    handle: (from, m) => got.push(['ping', from, m.n]) });
  reg.register('word', { to: 'client', handle: (from, m) => got.push(['word', from, m.n]) });
  let threw = false;
  try {
    reg.register('ping', { to: 'host', handle: () => {} });
  } catch {
    threw = true;
  }
  check('co-op registry: a message type is registered once', threw);
  reg.dispatch('c1', { t: 'ping', n: 'x' });
  reg.dispatch('c1', { t: 'ping', n: 1 });
  reg.dispatch('c1', { t: 'ping', n: 2 });
  // (every message counts toward the rate, a malformed one too)
  check('co-op registry: an intent is validated and rate limited per sender (2 a second)', got.length === 1 &&
    got[0][2] === 1 && reg.dropped.get('ping') === 2, { got, dropped: [...reg.dropped] });
  reg.reset();
  reg.dispatch('c1', { t: 'ping', n: 2 });
  squad.get('c1').life = 'Dead';
  room.game.phase = 'InRun';
  reg.reset();
  reg.dispatch('c1', { t: 'ping', n: 4 });
  room.game.phase = 'Results';
  squad.get('c1').life = 'Alive';
  reg.dispatch('c1', { t: 'ping', n: 5 });
  room.game.phase = 'InRun';
  check('co-op registry: a sender in the wrong life state or a message in the wrong phase is dropped', got.length === 2);
  reg.dispatch('c1', { t: 'word', n: 6 });
  reg.dispatch('h', { t: 'word', n: 7 });
  role = 'client';
  reg.dispatch('c1', { t: 'word', n: 8 });
  reg.dispatch('h', { t: 'word', n: 9 });
  reg.dispatch('h', { t: 'ping', n: 10 });
  check('co-op registry: the host\'s word is taken from the host only (its own copy on the host), an intent on the host only',
    got.map((x) => x[2]).join() === '1,2,7,9', got);
  check('co-op registry: an unregistered type is left to the handler tables', reg.dispatch('h', { t: 'other' }) === false);
  // the strings: a package's file adds its lines; a key defined twice is refused
  defineStrings({ 'LivesTest.Line': 'A line of %d' });
  let twice = false;
  try {
    defineStrings({ 'Lives.NotYet': 'again' });
  } catch {
    twice = true;
  }
  check('strings: a package\'s own file adds its lines (S formats them); a key defined twice is refused',
    S_('LivesTest.Line', 3) === 'A line of 3' && S_('Lives.NotYet') === 'NOT YET.' && twice);
}

// ------------------------------------------------------------------------------------------------ in the game
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

async function pageRun(browser, page, difficulty) {
  const tag = difficulty;
  const want = difficulty === N ? { hold: 6, up: 35, grace: 6, health: 35 } : { hold: 4, up: 50, grace: 10, health: 50 };
  const tab = await browser.newPage({ viewport: { width: 960, height: 540 } });
  const logs = [];
  await tab.addInitScript(() => {
    Element.prototype.requestPointerLock = function requestPointerLock() {
      return Promise.resolve();
    };
  });
  tab.on('pageerror', (e) => logs.push(`pageerror: ${e.message}`));
  tab.on('console', (m) => {
    if (m.type() === 'error' && !/useProgram|Shader Error|WebGL|GPU stall|AudioContext/.test(m.text())) logs.push(m.text());
  });
  const G = (fn, arg) => tab.evaluate(([src, a]) => {
    const w = window.__rovlocGame;
    // eslint-disable-next-line no-new-func
    return new Function('game', 'dev', 'arg', `return (${src})(game, dev, arg);`)(w.game, w.dev, a);
  }, [fn.toString(), arg]);
  // steps the game `seconds` at 30 Hz inside the page, without rendering; the loop is held from the boot on, so game
  // time moves only here (never across the real time between two calls)
  const ff = (seconds) => tab.evaluate((s) => {
    const e = window.__rovloc.engine;
    e.loop.stop();
    const render = e.renderer.render;
    e.renderer.render = () => {};
    try {
      for (let i = 0; i < Math.round(s * 30); i++) e.loop._run(1 / 30, 1 / 30);
    } finally {
      e.renderer.render = render;
    }
  }, seconds);
  try {
    await tab.goto(`file://${page}?dev&seed=1029`);
    await tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 180000 });
    check(`${tag}: boot`, await tab.evaluate(() => !window.__rovloc.error));
    await G((g) => {
      window.__rovloc.engine.skipRender = true;
      window.__rovloc.engine.loop.stop();
    });
    // (the deploy's fades run on the stepped frames: not awaited here)
    await G((g, dev, d) => {
      dev.deploy(d);
    }, difficulty);
    await ff(1.5);
    let s = await G((g) => ({ stage: g.stage, level: g.level, standIn: g.standIn.stage(), lock: g.controlLock(),
      title: g.standIn.title.textContent, lives: g.life.lives }));
    check(`${tag}: the run starts on the Back Lot's stand-in (its name, the controls held)`, s.stage === 'BackLot' &&
      s.level === null && s.standIn === 'BackLot' && s.lock === 'Cutscene' && /BACK LOT/.test(s.title), s);
    await tab.keyboard.press('Enter');
    await ff(2.5);
    s = await G((g) => ({ stage: g.stage, level: g.level, lives: g.life.lives, life: g.life.state, lock: g.controlLock() }));
    check(`${tag}: Skip ends the stand-in; the Basement starts (${difficulty === N ? 'no stage respawn, one for the run' : 'one stage respawn'})`,
      s.stage === 'Level0_Basement' && s.level === 'Level0_Basement' && s.life === 'Alive' &&
      (difficulty === N ? s.lives.stage === 0 && s.lives.run === 1 : s.lives.stage === 1 && s.lives.run === 0) && s.lives.syringe === 0, s);
    // the Creature let go of its start and told to leave the player alone while the test sets things up
    await G((g) => {
      g.floors.spawns._letGo('Test');
      g.creature.c.service.ignored = true;
    });
    await ff(0.5);
    if (difficulty === S) {
      // the creature event feed: anything can subscribe; a stun shows as its Stun and its State change
      await G((g) => {
        window.__feed = [];
        g.creature.feed.connect((e) => window.__feed.push({ kind: e.kind, at: e.at, state: e.state, seconds: e.seconds }));
        g.creature.stun(2, g.creature.position());
      });
      await ff(0.2);
      s = await G(() => window.__feed);
      check(`${tag}: the creature event feed carries the stun (Stun, 2 s) and its state change (State: Stunned)`,
        s.some((e) => e.kind === 'Stun' && e.seconds === 2 && e.at > 0) && s.some((e) => e.kind === 'State' && e.state === 'Stunned'), s);
      await ff(2.5);
    }

    // ------------------------------------------------------------------ a down, the get-up
    await G((g) => g.life.down('Test'));
    s = await G((g) => ({ life: g.life.state, downs: g.life.lives.downs, ctx: g.env.context() }));
    check(`${tag}: the stage's first lethal hit downs`, s.life === 'Downed' && s.downs === 1 && s.ctx === 'Downed', s);
    await tab.keyboard.down('KeyE');
    await ff(2.8);
    s = await G((g) => ({ life: g.life.state, offered: g.livesHud.getUp.textContent, held: g.life.getUpHeld }));
    check(`${tag}: no get-up before 3 s (nothing offered, nothing held)`, s.life === 'Downed' && s.offered === '' && s.held === 0, s);
    await ff(0.4 + want.hold - 0.3);
    s = await G((g) => ({ life: g.life.state, offered: g.livesHud.getUp.textContent }));
    check(`${tag}: from 3 s, HOLD E TO GET UP; still down just short of ${want.hold} s held`, s.life === 'Downed' &&
      /HOLD E TO GET UP/.test(s.offered), s);
    await ff(0.5);
    await tab.keyboard.up('KeyE');
    s = await G((g) => ({ life: g.life.state, health: g.life.health, used: g.life.lives.getUpUsed,
      chevron: g.livesHud.chevron.getAttribute('stroke') }));
    check(`${tag}: up after ${want.hold} s of holding at ${want.up} health; the chevron greys`, s.life === 'Alive' &&
      s.health === want.up && s.used && /92/.test(s.chevron), s);

    // ------------------------------------------------------------------ the next lethal hit kills: the respawn
    const placed = await G((g) => {
      const T = g.env.THREE;
      const s2 = g.creature.c.service;
      const spawn = g.match.spawnOf(g.level, g.match.slot()).cframe;
      const entry = new T.Vector3(spawn[0], spawn[1] - 3, spawn[2]);
      const nav = s2._nav(s2.creatureLevel);
      // the Creature on a free floor point within 40 studs walked of the entry
      const near = nav.samplePoints(6).map((p) => p.position).filter((p) => {
        const w = nav.pathLength(entry, p);
        return w > 12 && w < 40;
      })[0];
      s2._placeBody(s2.body.getCFrame().constructor.lookAt(new T.Vector3(near.x, near.y + 3.2, near.z),
        new T.Vector3(entry.x, near.y + 3.2, entry.z)));
      // the fuse taken: carried at the death
      const f = g.floors.floor(g.level);
      const fuse = f.items.find((e) => f.picked(e.id) && f.itemAvailable(e.id));
      f._take(fuse);
      f.carry.noteEntity(fuse.id);
      f.taken.add(fuse.id);
      f.refresh();
      const carried = g.floors.carry.lines().length;
      const root = g.env.rootPosition().clone();
      const feet = new T.Vector3(near.x, near.y, near.z);
      s2.ignored = false;
      g.life.down('Test');
      return { walkBefore: nav.pathLength(entry, feet), entry: entry.toArray(), fell: root.toArray(), fuse: fuse.id, carried };
    });
    s = await G((g) => ({ life: g.life.state, respawning: !!g.life.respawning, lock: g.controlLock(), lives: g.life.lives,
      notYet: g.livesHud.notYet.textContent, used: g.stats.get('RespawnsUsed') }));
    check(`${tag}: the next lethal hit on the stage kills: a respawn starts (the ${difficulty === N ? 'run\'s' : 'stage\'s'}), NOT YET.`,
      s.life === 'Dead' && s.respawning && s.lock === 'Respawn' && s.notYet === 'NOT YET.' && s.used === 1 &&
      s.lives.stage === 0 && s.lives.run === 0 && !s.lives.getUpUsed && s.lives.downs === 0, { ...s, placed });
    s = await G((g, dev, a) => {
      const f = g.floors.floor(g.level);
      const e = g.env.entity(a.fuse);
      const p = new g.env.THREE.Vector3().setFromMatrixPosition(e.pivot);
      return { taken: f.taken.has(a.fuse), at: p.toArray(), pins: g.livesHud.pins.length, carried: g.floors.carry.lines().length };
    }, placed);
    const dropD = Math.hypot(s.at[0] - placed.fell[0], s.at[2] - placed.fell[2]);
    check(`${tag}: the carried fuse lies where they fell, pinned on the HUD`, placed.carried === 1 && !s.taken && dropD < 1.5 &&
      s.pins === 1 && s.carried === 0, { ...s, dropD });
    await ff(3.8);
    s = await G((g) => ({ life: g.life.state, black: g.livesHud.black }));
    check(`${tag}: still black and down at 3.8 s`, s.life === 'Dead' && s.black > 0.9, s);
    await ff(0.3);
    s = await G((g, dev, a) => {
      const T = g.env.THREE;
      const s2 = g.creature.c.service;
      const nav = s2._nav(s2.creatureLevel);
      const entry = new T.Vector3(...a.entry);
      const here = s2.body.getPosition();
      const feet = new T.Vector3(here.x, here.y - 3.2, here.z);
      const root = g.env.rootPosition();
      return { life: g.life.state, health: g.life.health, lock: g.controlLock(), walk: nav.pathLength(entry, feet),
        fromPlayer: Math.hypot(here.x - root.x, here.z - root.z), atEntry: Math.hypot(root.x - a.entry[0], root.z - a.entry[2]),
        teleportIn: s2.teleportReadyAt - s2.now(), grace: s2.graceUntil.get(window.__rovlocGame.game.creature.c.PLAYER) - s2.now(),
        huntable: s2._huntable(window.__rovlocGame.game.creature.c.PLAYER) };
    }, placed);
    check(`${tag}: after 4 s up at the stage's entry (the spawn) at ${want.health}`, s.life === 'Alive' && s.health === want.health &&
      s.lock === 'None' && s.atEntry < 1, s);
    check(`${tag}: the Creature moved from ${placed.walkBefore.toFixed(0)} to at least 70 studs walked from the entry and 45 from the player`,
      placed.walkBefore < 70 && s.walk >= 70 && Number.isFinite(s.walk) && s.fromPlayer >= 45, s);
    // (read a few ticks after the stand-up: both clocks have run down by the same time since)
    const since = want.grace - s.grace;
    check(`${tag}: its next teleport at least 45 s off; the player ignored for ${want.grace} s`, since >= 0 && since < 0.5 &&
      s.teleportIn + since >= 45 - 1e-6 && !s.huntable, { ...s, since });
    await ff(want.grace - 0.5);
    s = await G((g) => g.creature.c.service._huntable(g.creature.c.PLAYER));
    check(`${tag}: still ignored just before ${want.grace} s`, s === false);
    await ff(0.7);
    s = await G((g) => ({ huntable: g.creature.c.service._huntable(g.creature.c.PLAYER), pins: g.livesHud.pins.length }));
    check(`${tag}: noticed again after the grace`, s.huntable === true, s);
    await ff(4);
    s = await G((g) => g.livesHud.pins.length);
    check(`${tag}: the pin is gone after 10 s`, s === 0, s);
    await G((g) => {
      g.creature.c.service.ignored = true;
    });

    if (difficulty === S) {
      // ------------------------------------------------------------------ the next stage: the stage respawn back, not banked
      await G((g, dev) => dev.gotoStage('Level1_Hallways'));
      await ff(0.5);
      s = await G((g) => g.life.lives);
      check(`${tag}: the next stage's activation sets the spent stage respawn back to 1, downs and the get-up reset`,
        s.stage === 1 && s.downs === 0 && !s.getUpUsed, s);
      await G((g, dev) => dev.gotoStage('Level2_Auditorium'));
      await ff(0.5);
      s = await G((g) => g.life.lives);
      check(`${tag}: an unused stage respawn is not banked (still 1)`, s.stage === 1, s);
    } else {
      // ------------------------------------------------------------------ out of respawns: the solo run ends
      await G((g) => {
        g.life.down('Test');
        g.life.execute('Test');
      });
      await ff(2);
      s = await G((g) => ({ phase: g.phase, verdict: g.match.summary && g.match.summary.verdict, title: g.results.title.textContent }));
      await ff(1);
      s = { ...s, title: await G((g) => g.results.title.textContent) };
      check(`${tag}: out of respawns, the next death ends the solo run: THE NIGHT TOOK YOU`, s.phase === 'Results' &&
        s.verdict === 'Wipe' && /THE NIGHT TOOK YOU/.test(s.title), s);
    }
  } catch (err) {
    check(`${tag}: the run completed`, false, String(err && err.stack ? err.stack : err));
  }
  check(`${tag}: no page errors`, logs.length === 0, logs.slice(0, 5));
  await tab.close();
}

if (only.has('page')) {
  console.log('== in the game');
  let page = opt('--html', null);
  if (!page) {
    page = path.join(web, 'build/cache/lives-test.html');
    if (!argv.includes('--no-build') || !fs.existsSync(page)) {
      execFileSync(process.execPath, [path.join(here, 'game-build.mjs'), '--out', page, '--no-minify'], { stdio: 'inherit' });
    }
  }
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader',
    '--ignore-gpu-blocklist', '--autoplay-policy=no-user-gesture-required', '--enable-webgl'] });
  try {
    for (const d of [S, N]) await pageRun(browser, page, d);
  } finally {
    await browser.close();
  }
}

console.log(failures.length ? `\n${failures.length} of ${checks} FAILED:\n  ${failures.join('\n  ')}` : `\nall ${checks} checks passed`);
process.exit(failures.length ? 1 : 0);
