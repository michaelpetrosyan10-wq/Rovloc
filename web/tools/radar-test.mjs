// radar-test.mjs: the radar (docs/design/game-spec-v2.md 3.2; invariant I15) on the website, against the rules, in a
// solo run and on two pages.
//
//   node tools/radar-test.mjs [--no-build] [--html <page>] [--coop-html <page>] [--only rules,solo,night,coop]
//
// rules   src/game/rules/radar.js, the port of Shared/Rules/RadarRules.luau over the world's numbers, replays every
//         RadarRules row of build/cache/golden.json (numbers within 1e-9); then the spec's numbers, written here from
//         its text (never read back from meta.radarConfig): 3 charges held, 1 at the start; a scan 0.4 s up, 8 s [6 s]
//         long; a battery +1 charge and +45 torch, Full with both full; 6 [4] batteries per sneaking stage, +1 per
//         extra player, 9 [7] at most; the arrival floor on every sneaking stage [the Basement and the Rooftops];
//         5 [2] scans guaranteed with no battery ever found; every refusal; 0.28 m per stud.
// solo    the game test page (game-build.mjs, unminified), a Standard run on seed 1029: one charge at the start, the
//         three pips and RADAR 1/3; the Basement's batteries (6 of the plan's picks shown, the rest hidden), each
//         LED on 0.2 s of every 2 s; a scan (Tab): one charge spent, nothing shown during the 0.4 s raise, then for
//         8 s the three fuses still needed at their exact spots and the batteries within 50 studs as dots, no panel,
//         no exit, never the Creature (stood beside the player), never a noise, the soft ping once at the scanner;
//         a second press while it is up is refused at no cost; the empty press opens the sheet with "Radar empty.
//         Batteries blink." and a dry click; a battery taken: +1 charge, +45 torch; with both full its prompt reads
//         Full and it stays; the refusals (Hiding, Downed, a cutscene, the roof) cost nothing. The targets per step:
//         the fuses taken, the panel; a fuse dropped where its carrier fell, that fuse at any step; the breaker
//         thrown, the exit. The Hallways (the arrival floor gives the empty-handed one charge): the keys, then the
//         stairwell door's lock; the HUD draws a marker per target and the chevron.
// night   a Nightmare run: 4 batteries on the Basement, a 6 s scan, and no charge on arriving at the Hallways empty.
// coop    two pages (a host and a client, the local test relay): the client's scan spends the client's charge, not
//         the host's, and shows on both pages (each its own markers); the host's press while it is up is refused.
// Exit code 1 on any failure.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { radarRules } from '../src/game/rules/radar.js';
import { startRelay } from './coop-relay.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.resolve(here, '..');
const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const only = new Set(opt('--only', 'rules,solo,night,coop').split(','));
const failures = [];
let checks = 0;

function check(name, ok, detail) {
  checks++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail !== undefined ? ` ${JSON.stringify(detail)}` : ''}`);
  if (!ok) failures.push(name);
  return ok;
}

const meta = JSON.parse(fs.readFileSync(path.join(web, 'build/world.json'), 'utf8'));
const R = radarRules(meta);
const S = 'Standard';
const N = 'Nightmare';

/** A rule's answer against a golden row's: numbers within 1e-9, tables key by key (an empty Luau table is {} or []). */
function same(a, b) {
  if (typeof a === 'number' || typeof b === 'number') return typeof a === 'number' && typeof b === 'number' && Math.abs(a - b) <= 1e-9;
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    return [...new Set([...Object.keys(a), ...Object.keys(b)])].every((k) => same(a[k], b[k]));
  }
  return a === b;
}

// ------------------------------------------------------------------------------------------------ the rules
if (only.has('rules')) {
  console.log('== the rules (rules/radar.js)');
  const golden = JSON.parse(fs.readFileSync(path.join(web, 'build/cache/golden.json'), 'utf8')).RadarRules || [];
  const bad = [];
  const fns = new Set();
  for (const row of golden) {
    fns.add(row.fn);
    const fn = R[row.fn];
    const got = typeof fn === 'function' ? fn(...row.args) : undefined;
    if (!same(got, row.expect)) bad.push({ row: row.name, got, want: row.expect });
  }
  check(`every RadarRules golden row replays exactly (${golden.length} rows over ${fns.size} functions)`,
    golden.length >= 100 && fns.size === 9 && bad.length === 0, bad.slice(0, 3));
  // the spec's numbers, from its text
  check('3 charges held, 1 at the run\'s start (both difficulties)', [S, N].every((d) => R.startCharges(d) === 1 &&
    R.battery(d, 3, 10, 100).charges === 3 && R.battery(d, 2, 100, 100).charges === 3));
  const scan = R.scan(S, 2, 10);
  const scanN = R.scan(N, 2, 10);
  check('a scan: one charge, a 0.4 s raise, then 8 s [6 s] of markers', scan.charges === 1 && Math.abs(scan.showAt - 10.4) < 1e-9 &&
    Math.abs(scan.endsAt - 18.4) < 1e-9 && Math.abs(scanN.endsAt - 16.4) < 1e-9);
  const b = R.battery(S, 1, 30, 100);
  check('a battery: +1 charge and +45 torch; with both full it is not taken (Full)', b.taken && b.charges === 2 && b.torch === 75 &&
    !R.battery(S, 3, 100, 100).taken && R.battery(S, 3, 99, 100).taken && R.battery(S, 2, 100, 100).taken);
  check('batteries per sneaking stage: 6, +1 per extra player, 9 at most [4, +1, 7]',
    [1, 2, 3, 4].map((n) => R.batteriesPlaced(S, n)).join() === '6,7,8,9' && [1, 2, 3, 4].map((n) => R.batteriesPlaced(N, n)).join() === '4,5,6,7');
  const sneaking = ['Level0_Basement', 'Level1_Hallways', 'Level2_Auditorium', 'City1_Rooftops', 'City2_Airport'];
  check('the arrival floor: every sneaking stage on Standard; the Basement and the Rooftops on Nightmare; never the roof',
    sneaking.every((id) => R.arrival(S, id, 0) === 1) && sneaking.map((id) => R.arrival(N, id, 0)).join() === '1,0,0,1,0' &&
    R.arrival(S, 'Level3_Roof', 0) === 0 && R.arrival(S, 'Level1_Hallways', 2) === 2);
  check('5 [2] scans guaranteed in a run with no battery ever found', R.guaranteedScans(S) === 5 && R.guaranteedScans(N) === 2);
  const ask = (o) => ({ charges: 1, lifeState: 'Alive', moveState: 'Standing', cutscene: false, stage: 'Level0_Basement', squadScanLive: false, ...o });
  check('the refusals: Hiding, Downed, dead, seated, a cutscene, the roof and the runway, a squad scan live; Empty with no charge',
    R.refusal(ask({})) === 'Ok' && R.refusal(ask({ moveState: 'Hiding' })) === 'Hiding' && R.refusal(ask({ lifeState: 'Downed' })) === 'Downed' &&
    R.refusal(ask({ lifeState: 'Spectating' })) === 'Dead' && R.refusal(ask({ moveState: 'Seated' })) === 'Seated' &&
    R.refusal(ask({ cutscene: true })) === 'Cutscene' && R.refusal(ask({ stage: 'Level3_Roof' })) === 'Stage' &&
    R.refusal(ask({ stage: 'Runway' })) === 'Stage' && R.refusal(ask({ squadScanLive: true })) === 'Live' &&
    R.refusal(ask({ charges: 0 })) === 'Empty');
  check('distances in metres: 0.28 a stud', R.metres(100) === 28 && R.metres(1) === 0 && R.metres(2) === 1);
  const view = {
    openStep: 'FindFuses',
    items: [{ id: 'F1', step: 'FindFuses', carried: false, dropped: false }, { id: 'F2', step: 'FindFuses', carried: true, dropped: false }],
    stations: [{ id: 'P', step: 'FitFuses', done: false }],
    exit: { id: 'X', unlocked: false },
    batteries: [{ id: 'B1', distance: 50 }, { id: 'B2', distance: 50.5 }],
    creature: { id: 'Creature' },
    teammates: [{ id: 'Mate' }],
  };
  const t = R.targets(view).map((x) => x.id).join();
  check(`a scan shows the items still needed and the batteries within 50; never the Creature or a teammate (${t})`, t === 'F1,B1');
}

// ------------------------------------------------------------------------------------------------ the pages
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

const needPages = ['solo', 'night', 'coop'].some((c) => only.has(c));
let browser = null;
if (needPages) {
  const { chromium } = loadPlaywright();
  browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist',
    '--autoplay-policy=no-user-gesture-required', '--enable-webgl', '--disable-features=WebRtcHideLocalIpsWithMdns'] });
}
const IGNORED = /useProgram|Shader Error|WebGL|GPU stall|AudioContext|autoplay/i;

/** The game test page, built once unless given. */
let gameFile = null;
function gamePage() {
  if (gameFile) return gameFile;
  const given = opt('--html', null);
  gameFile = given ? path.resolve(given) : path.join(web, 'build/cache/radar-game.html');
  if (!given && (!argv.includes('--no-build') || !fs.existsSync(gameFile))) {
    execFileSync(process.execPath, [path.join(here, 'game-build.mjs'), '--out', gameFile, '--no-minify'], { stdio: 'inherit' });
  }
  return gameFile;
}

/** A solo page with the loop held: game time moves only by ff(). */
async function soloPage() {
  const tab = await browser.newPage({ viewport: { width: 960, height: 540 } });
  const logs = [];
  await tab.addInitScript(() => {
    Element.prototype.requestPointerLock = function requestPointerLock() {
      return Promise.resolve();
    };
  });
  tab.on('pageerror', (e) => logs.push(`pageerror: ${e.message}`));
  tab.on('console', (m) => {
    if (m.type() === 'error' && !IGNORED.test(m.text())) logs.push(m.text());
  });
  const G = (fn, arg) => tab.evaluate(([src, a]) => {
    const w = window.__rovlocGame;
    // eslint-disable-next-line no-new-func
    return new Function('game', 'dev', 'arg', `return (${src})(game, dev, arg);`)(w.game, w.dev, a);
  }, [fn.toString(), arg]);
  // steps the game `seconds` at 30 Hz inside the page (frames drawn into the HUD, the 3D render skipped)
  const ff = (seconds) => tab.evaluate((s) => {
    const e = window.__rovloc.engine;
    e.loop.stop();
    for (let i = 0; i < Math.round(s * 30); i++) e.loop._run(1 / 30, 1 / 30);
  }, seconds);
  return { tab, logs, G, ff };
}

/** Into a run on `difficulty`, past the Back Lot's stand-in, on the Basement; the Creature held off and ignoring. */
async function intoRun(p, difficulty) {
  await p.tab.goto(`file://${gamePage()}?dev&seed=1029`);
  await p.tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 180000 });
  check(`${difficulty}: boot`, await p.tab.evaluate(() => !window.__rovloc.error));
  await p.G((g) => {
    window.__rovloc.engine.skipRender = true;
    window.__rovloc.engine.loop.stop();
    g.env.setSetting('TutorialDone', true);
  });
  await p.G((g, dev, d) => {
    dev.deploy(d);
  }, difficulty);
  await p.ff(1.5);
  await p.tab.keyboard.press('Enter');
  await p.ff(2.5);
  await p.G((g) => {
    g.floors.spawns._letGo('Test');
    g.creature.c.service.ignored = true;
    window.__sounds = [];
    window.__noise = [];
    const play = g.env.play.bind(g.env);
    g.env.play = (name, opts = {}) => {
      window.__sounds.push({ name, at: opts.position ? opts.position.toArray() : null, t: g.env.now() });
      return play(name, opts);
    };
    g.env.onNoise((e) => window.__noise.push({ kind: e.kind, source: e.source, t: g.env.now() }));
  });
  await p.ff(0.5);
  return p.G((g) => ({ stage: g.stage, level: g.level, life: g.life.state }));
}

/** What the page's radar holds and shows now. */
const radarState = (p) => p.G((g) => {
  const r = g.radar;
  const t = r.targets();
  return {
    charges: r.charges, live: r.live(), showing: r.showing(), lastRefusal: r.lastRefusal, scans: r.scans,
    targets: t.map((x) => ({ kind: x.kind, id: x.id, at: x.point.toArray(), name: x.name })),
    pips: [...g.radarHud.pips.children].filter((d) => d.style.background && d.style.background !== 'transparent').length,
    pipsShown: g.radarHud.pips.style.display !== 'none',
    markers: g.radarHud.count.markers,
    dots: g.radarHud.count.dots,
    drawn: g.radarHud.markers.filter((m) => m.root.style.display !== 'none').length,
    pointer: Number(g.radarHud.pointer.root.style.opacity),
    sheet: g.objectives.extra.textContent, sheetShown: g.objectives.extra.style.display !== 'none',
    tracker: g.objectives.keyLabel.textContent,
  };
});
const press = (p) => p.G((g) => {
  g.env.injectAction('Radar', 'test', true);
  g.env.injectAction('Radar', 'test', false);
});
const near = (a, b, eps = 1e-6) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]) <= eps;

async function soloCase() {
  console.log('== solo, Standard (seed 1029)');
  const p = await soloPage();
  try {
    const st = await intoRun(p, S);
    check('on the Basement, alive', st.level === 'Level0_Basement' && st.life === 'Alive', st);
    let r = await radarState(p);
    check(`one charge at the start: one of three pips lit, the sheet reads ${r.tracker}`, r.charges === 1 && r.pipsShown && r.pips === 1 &&
      r.tracker === 'RADAR 1/3', r);
    // the batteries: the plan's first 6 on the Basement, the other candidates hidden; the LEDs
    const bat = await p.G((g) => {
      const level = 'Level0_Basement';
      const want = g.run.plan.batteries[level].anchors.slice(0, 6);
      const shown = g.world.entities('Battery', level).filter((e) => !g.env.entity(e.id).hidden).map((e) => e.id);
      const placed = g.batteries.live(level).map((b) => b.id);
      const led = g.batteries.placed.get(placed[0]).led;
      return { want, shown, placed, candidates: g.world.entities('Battery', level).length,
        material: { basic: led.material.type, fog: led.material.fog } };
    });
    check(`the Basement shows the plan's first 6 batteries (of ${bat.candidates} spots), the rest hidden`, bat.placed.length === 6 &&
      bat.want.every((id) => bat.placed.includes(id)) && bat.shown.length === 6 && bat.shown.every((id) => bat.want.includes(id)), bat);
    check('each battery\'s LED is an unlit, unfogged mesh', bat.material.basic === 'MeshBasicMaterial' && bat.material.fog === false, bat.material);
    const blink = await p.tab.evaluate(() => {
      const e = window.__rovloc.engine;
      const { game: g } = window.__rovlocGame;
      const on = new Map();
      for (let i = 0; i < 120; i++) {
        e.loop._run(1 / 60, 1 / 60);
        for (const b of g.batteries.placed.values()) on.set(b.id, (on.get(b.id) || 0) + (b.led.visible ? 1 : 0));
      }
      return [...on.values()];
    });
    check(`every LED is on 0.2 s of every 2 s (frames lit of 120 at 60 fps: ${blink.join(', ')})`, blink.length >= 6 && blink.every((n) => n >= 11 && n <= 13));
    // a scan: Tab
    await p.G((g) => {
      // the Creature stood beside the player: a scan never shows it
      const T = g.env.THREE;
      const root = g.env.rootPosition();
      const held = g.creature.acquireScripted('RadarTest');
      held.teleport(new T.Matrix4().makeTranslation(root.x + 4, root.y + 0.2, root.z));
      window.__held = held;
      window.__noise.length = 0;
      window.__sounds.length = 0;
    });
    await p.tab.keyboard.press('Tab');
    r = await radarState(p);
    check('Tab scans: the charge is spent at once, the scan is up, nothing shows during the raise', r.charges === 0 && r.live && !r.showing &&
      r.targets.length === 0 && r.scans === 1, r);
    await p.ff(0.4);
    r = await radarState(p);
    const fuses = await p.G((g) => {
      const f = g.floors.floor('Level0_Basement');
      const root = g.env.rootPosition();
      return { fuses: f.items.filter((e) => f.picked(e.id)).map((e) => ({ id: e.id, at: f.pointOf(e.id, 'PromptPoint').toArray() })),
        batteries: g.batteries.live('Level0_Basement').map((b) => ({ id: b.id, d: b.point.distanceTo(root) })),
        creature: g.creature.position().toArray() };
    });
    const items = r.targets.filter((t) => t.kind === 'Item');
    const dots = r.targets.filter((t) => t.kind === 'Battery');
    const inReach = fuses.batteries.filter((b) => b.d <= 50).map((b) => b.id).sort();
    check(`after the 0.4 s raise the three fuses show at their exact spots (${items.map((t) => t.name).join(', ')})`, items.length === 3 &&
      fuses.fuses.every((f) => items.some((t) => t.id === f.id && near(t.at, f.at))) && /FUSE [123]\/3/.test(items[0].name), r.targets);
    check(`the batteries within 50 studs show as dots (${dots.length}: ${inReach.join(', ') || 'none in reach'})`,
      dots.map((t) => t.id).sort().join() === inReach.join() && r.dots === dots.length, fuses.batteries);
    check('no station and no exit on the open step (find the fuses); nothing else', r.targets.every((t) => t.kind === 'Item' || t.kind === 'Battery'));
    await p.G(() => window.__held.release());
    check('never the Creature (it stands 4 studs away; no marker there)', r.targets.every((t) => Math.hypot(t.at[0] - fuses.creature[0], t.at[2] - fuses.creature[2]) > 1));
    check(`the HUD: a marker for each fuse (${r.markers}; ${r.drawn} in front of the camera), the chevron, the ring`, r.markers === 3 &&
      r.drawn >= 1 && r.pointer > 0, r);
    let s = await p.G(() => ({ sounds: window.__sounds.map((x) => x.name), pings: window.__sounds.filter((x) => x.name === 'RadarPing'),
      noise: window.__noise.slice() }));
    check('the soft ping once, in 3D at the scanner; no noise at all (the Creature never hears it)', s.pings.length === 1 && !!s.pings[0].at &&
      s.noise.length === 0, s);
    // a second press while it is up: refused, no cost
    await press(p);
    r = await radarState(p);
    check('a press while the scan is up is refused (Live) at no cost', r.lastRefusal === 'Live' && r.charges === 0 && r.scans === 1, r);
    await p.ff(7.4);
    r = await radarState(p);
    check('8 s later the markers are still up', r.showing, r);
    await p.ff(1);
    r = await radarState(p);
    check('and then gone', !r.live && r.targets.length === 0 && r.markers === 0 && r.drawn === 0, r);
    // the empty press
    await p.G(() => {
      window.__sounds.length = 0;
    });
    await press(p);
    await p.ff(0.1);
    r = await radarState(p);
    s = await p.G(() => window.__sounds.map((x) => x.name));
    check('with no charge Tab opens the objective sheet with "Radar empty. Batteries blink." and a dry click, no scan',
      r.lastRefusal === 'Empty' && r.sheetShown && r.sheet === 'Radar empty. Batteries blink.' && s.includes('RadarEmpty') && !r.live && r.scans === 1, { r, s });
    // a battery: +1 charge, +45 torch
    const took = await p.G((g) => {
      const torch = g.env.meters().battery;
      torch.set(20);
      const b = [...g.batteries.placed.values()][0];
      g.batteries._take(b);
      return { id: b.id, charges: g.radar.charges, torch: torch.value, left: g.batteries.live('Level0_Basement').length,
        hidden: g.env.entity(b.id).hidden };
    });
    check('a battery taken: +1 charge and +45 torch, and it is gone', took.charges === 1 && took.torch === 65 && took.left === 5 && took.hidden, took);
    // both full: Full, and the battery stays
    const full = await p.G((g) => {
      g.radar.setCharges(3);
      const torch = g.env.meters().battery;
      torch.set(torch.max);
      return true;
    });
    await p.ff(0.1);
    const fp = await p.G((g) => {
      const prompts = window.__rovloc.engine.prompts.list;
      const b = [...g.batteries.placed.values()][0];
      g.batteries._take(b);
      const pickup = prompts.get(b.pickup.id);
      const fullPrompt = prompts.get(b.full.id);
      return { pickup: pickup.enabled, full: fullPrompt.enabled, text: fullPrompt.text, still: g.batteries.placed.has(b.id), charges: g.radar.charges };
    });
    check('with the radar and the torch both full the prompt reads Full and the battery stays', full && !fp.pickup && fp.full &&
      fp.text === 'Full' && fp.still && fp.charges === 3, fp);
    // the refusals, at no cost
    const refusals = await p.G((g) => {
      const out = {};
      g.radar.setCharges(2);
      g.env.pushOverride('RadarTest', 'Hiding');
      window.__rovloc.engine.loop._run(1 / 30, 1 / 30);
      out.hiding = g.radar.press();
      g.env.popOverride('RadarTest');
      window.__rovloc.engine.loop._run(1 / 30, 1 / 30);
      g.lock('Cutscene');
      out.cutscene = g.radar.press();
      g.unlock('Cutscene');
      out.charges = g.radar.charges;
      out.live = g.radar.live();
      return out;
    });
    check('refused at no cost: hiding, in a cutscene', refusals.hiding === 'Hiding' && refusals.cutscene === 'Cutscene' &&
      refusals.charges === 2 && !refusals.live, refusals);
    await p.G((g) => g.life.down('Test'));
    await p.ff(0.1);
    const downed = await p.G((g) => ({ why: g.radar.press(), charges: g.radar.charges, life: g.life.state }));
    check('refused at no cost while Downed', downed.why === 'Downed' && downed.charges === 2, downed);
    await p.G((g) => g.life.setAlive(100));
    await p.ff(0.2);

    // the targets per step on the Basement: the fuses taken -> the panel; one dropped -> it shows at any step
    await p.G((g) => {
      const f = g.floors.floor('Level0_Basement');
      for (const e of f.items.filter((x) => f.picked(x.id))) {
        f._take(e);
        f.carry.noteEntity(e.id);
        f.taken.add(e.id);
      }
      f.refresh();
    });
    await press(p);
    await p.ff(0.5);
    r = await radarState(p);
    const panel = await p.G((g) => g.floors.floor('Level0_Basement').pointOf(g.floors.floor('Level0_Basement').panel, 'LeverPrompt').toArray());
    let main = r.targets.filter((t) => t.kind !== 'Battery');
    check(`the fuses carried (open step: fit them): the breaker panel only (${main.map((t) => t.name).join(', ')})`, main.length === 1 &&
      main[0].kind === 'Station' && near(main[0].at, panel) && /BREAKER PANEL/.test(main[0].name), main);
    const dropped = await p.G((g) => {
      const T = g.env.THREE;
      const at = g.env.rootPosition().clone().add(new T.Vector3(3, -3, 0));
      return g.floors.dropCarried('', at).map((d) => ({ id: d.id, at: d.at.toArray() }));
    });
    await p.ff(0.2);
    r = await radarState(p);
    main = r.targets.filter((t) => t.kind !== 'Battery');
    check(`a fuse dropped where its carrier fell shows, with the panel (${main.map((t) => t.name).join(', ')})`, dropped.length === 3 &&
      main.filter((t) => t.kind === 'Item').length === 3 && main.some((t) => t.kind === 'Station') && /DROPPED/.test(main[0].name), main);
    await p.ff(8.5);
    // the fuses taken again, the floor done: the exit
    await p.G((g, dev) => {
      const f = g.floors.floor('Level0_Basement');
      for (const e of f.items.filter((x) => f.picked(x.id))) {
        f.carry.noteEntity(e.id);
        f.taken.add(e.id);
        f.dropped.delete(e.id);
      }
      dev.completeObjective('Level0_Basement');
    });
    await p.ff(1.2);
    await press(p);
    await p.ff(0.5);
    r = await radarState(p);
    const exit = await p.G((g) => g.doors.get(g.route('Level0_Basement').exitDoorIds[0]).centre.toArray());
    main = r.targets.filter((t) => t.kind !== 'Battery');
    check(`the floor unlocked: the exit (${main.map((t) => t.name).join(', ')})`, main.length === 1 && main[0].kind === 'Exit' &&
      near(main[0].at, exit) && main[0].name === 'EXIT', main);
    await p.ff(8.5);

    // the Hallways: arriving with no charge gives one (Standard's arrival floor); the keys, then the lock
    await p.G((g, dev) => {
      dev.radar(0);
      dev.gotoLevel('Level1_Hallways');
    });
    await p.ff(1);
    r = await radarState(p);
    check('arriving at the Hallways with no charge gives one (the arrival floor)', r.charges === 1, r);
    await press(p);
    await p.ff(0.5);
    r = await radarState(p);
    const keys = await p.G((g) => {
      const f = g.floors.floor('Level1_Hallways');
      return f.items.filter((e) => f.picked(e.id)).map((e) => ({ id: e.id, at: f.pointOf(e.id, 'PromptPoint').toArray() }));
    });
    main = r.targets.filter((t) => t.kind !== 'Battery');
    check(`the Hallways: the master keys (${main.map((t) => t.name).join(', ')})`, main.length === keys.length && keys.length >= 1 &&
      keys.every((k) => main.some((t) => t.id === k.id && near(t.at, k.at))), { main, keys });
    await p.ff(8.5);
    const lock = await p.G((g, dev) => {
      const f = g.floors.floor('Level1_Hallways');
      for (const e of f.items.filter((x) => f.picked(x.id))) f._take(e);
      f.refresh();
      dev.radar(1);
      return f.lock.promptPoint().toArray();
    });
    await press(p);
    await p.ff(0.5);
    r = await radarState(p);
    main = r.targets.filter((t) => t.kind !== 'Battery');
    check(`the keys carried: the stairwell door's lock (${main.map((t) => t.name).join(', ')})`, main.length === 1 && main[0].kind === 'Station' &&
      near(main[0].at, lock), main);
    await p.ff(8.5);
    // the roof: no scan
    await p.G((g, dev) => {
      dev.gotoLevel('Level3_Roof');
      dev.radar(1);
    });
    await p.ff(1);
    const roof = await p.G((g) => ({ why: g.radar.press(), charges: g.radar.charges }));
    check('the roof refuses a scan (Stage) at no cost', roof.why === 'Stage' && roof.charges === 1, roof);
    check('no page errors', p.logs.length === 0, p.logs.slice(0, 3));
  } finally {
    await p.tab.close();
  }
}

async function nightCase() {
  console.log('== solo, Nightmare (seed 1029)');
  const p = await soloPage();
  try {
    await intoRun(p, N);
    const b = await p.G((g) => g.batteries.live('Level0_Basement').length);
    check(`Nightmare: 4 batteries on the Basement (${b})`, b === 4);
    await press(p);
    await p.ff(0.4 + 5.9);
    let r = await radarState(p);
    check('Nightmare: the scan is still up 5.9 s after the raise', r.showing, r);
    await p.ff(0.2);
    r = await radarState(p);
    check('and gone at 6 s', !r.live, r);
    await p.G((g, dev) => dev.gotoLevel('Level1_Hallways'));
    await p.ff(1);
    r = await radarState(p);
    check('Nightmare: arriving at the Hallways empty gives no charge', r.charges === 0, r);
    check('no page errors', p.logs.length === 0, p.logs.slice(0, 3));
  } finally {
    await p.tab.close();
  }
}

async function coopCase() {
  console.log('== two pages (host and client)');
  const given = opt('--coop-html', '');
  const file = path.resolve(given || path.join(web, 'build/cache/radar-coop.html'));
  if (!given) execFileSync(process.execPath, [path.join(here, 'build.mjs'), '--no-minify', '--out', file], { stdio: 'inherit' });
  const relay = await startRelay(0);
  const pages = [];
  const sleep = (ms) => new Promise((res) => setTimeout(res, ms));
  const open = async (name) => {
    const context = await browser.newContext({ bypassCSP: true, viewport: { width: 960, height: 540 } });
    const tab = await context.newPage();
    const logs = [];
    await tab.addInitScript(() => {
      Element.prototype.requestPointerLock = function requestPointerLock() {
        return Promise.resolve();
      };
    });
    tab.on('pageerror', (e) => logs.push(`${name} pageerror: ${e.message}`));
    tab.on('console', (m) => {
      if (m.type() === 'error' && !IGNORED.test(m.text())) logs.push(`${name}: ${m.text()}`);
    });
    await tab.goto(`file://${file}?relay=${encodeURIComponent(relay.url)}&seed=1029`);
    const p = { name, context, tab, logs };
    pages.push(p);
    return p;
  };
  const G = (p, fn, arg) => p.tab.evaluate(([src, a]) => {
    const w = window.__rovlocGame;
    // eslint-disable-next-line no-new-func
    return new Function('game', 'dev', 'arg', `return (${src})(game, dev, arg);`)(w.game, w.dev, a);
  }, [fn.toString(), arg]);
  const until = async (p, fn, arg, seconds = 20) => {
    const end = Date.now() + seconds * 1000;
    let v = null;
    while (Date.now() < end) {
      v = await G(p, fn, arg);
      if (v) return v;
      await sleep(200);
    }
    return v;
  };
  try {
    const host = await open('host');
    const mate = await open('client');
    for (const p of pages) {
      await p.tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 240000 });
      await G(p, (g) => {
        window.__rovloc.engine.skipRender = true;
        g.env.setSetting('TutorialDone', true);
      });
    }
    await G(host, (g) => {
      g.onboarding.friendsBtn.click();
      g.coop.ui.nameInput.value = 'Hana';
      g.coop.ui.hostBtn.click();
    });
    const code = await until(host, (g) => (g.coop.active && g.coop.ui.codeText.textContent) || null, null, 15);
    await G(host, (g) => g.coop.ui.enterBtn.click());
    await G(mate, (g, dev, c) => {
      g.onboarding.friendsBtn.click();
      g.coop.ui.nameInput.value = 'Ivo';
      g.coop.ui.codeInput.value = c;
      g.coop.ui.joinBtn.click();
    }, code);
    const two = await until(host, (g) => g.coop.squad.list().length === 2 && g.coop.squad.list().every((m) => m.id), null, 25);
    check('a host and a client in one room', !!two, code);
    for (const p of pages) await G(p, (g) => g.lobby.setReady(true));
    for (const p of pages) await until(p, (g) => g.phase === 'InRun' && g.standIn.stage() === 'BackLot', null, 30);
    for (const p of pages) await G(p, (g) => g.standIn.pressSkip());
    const runs = [];
    for (const p of pages) runs.push(await until(p, (g) => (g.phase === 'InRun' && g.level === 'Level0_Basement' ? { players: g.run.players, charges: g.radar.charges } : null), null, 40));
    check('both pages on the Basement: a squad of two (7 batteries a stage), one charge each', runs.every((r) => r && r.players === 2 && r.charges === 1), runs);
    const placed = [];
    for (const p of pages) placed.push(await G(p, (g) => g.batteries.live('Level0_Basement').map((b) => b.id).join()));
    check('the same 7 batteries placed on both pages', placed[0] === placed[1] && placed[0].split(',').length === 7, placed);
    const mateId = await G(mate, (g) => g.coop.localId);
    await G(mate, (g) => {
      g.env.injectAction('Radar', 'test', true);
      g.env.injectAction('Radar', 'test', false);
    });
    const seen = [];
    for (const p of pages) {
      seen.push(await until(p, (g) => (g.radar.showing() ? { by: g.radar.scan.by, charges: g.radar.charges,
        items: g.radar.targets().filter((t) => t.kind === 'Item').map((t) => t.id).sort().join() } : null), null, 10));
    }
    check('the client\'s scan shows on both pages, by the client', seen.every((v) => v && v.by === mateId && v.items.split(',').length === 3) &&
      seen[0].items === seen[1].items, seen);
    check('charges are personal: the client spent its charge, the host kept its own', seen[0] && seen[0].charges === 1 && seen[1] && seen[1].charges === 0, seen);
    const hostPress = await G(host, (g) => ({ why: g.radar.press(), charges: g.radar.charges, by: g.radar.scan.by }));
    check('the host\'s press while the squad scan is up is refused (Live) at no cost', hostPress.why === 'Live' && hostPress.charges === 1 &&
      hostPress.by === mateId, hostPress);
    const huds = [];
    for (const p of pages) huds.push(await until(p, (g) => g.radarHud.count.markers || null, null, 5));
    check('each page draws its own markers', huds.every((n) => n === 3), huds);
    const errors = pages.flatMap((p) => p.logs);
    check('no page errors', errors.length === 0, errors.slice(0, 3));
  } finally {
    for (const p of pages) await p.context.close();
    await relay.close();
  }
}

try {
  if (only.has('solo')) await soloCase();
  if (only.has('night')) await nightCase();
  if (only.has('coop')) await coopCase();
} catch (err) {
  check('the page cases ran to the end', false, String(err && err.stack ? err.stack : err));
} finally {
  if (browser) await browser.close();
}

console.log(failures.length ? `RADAR TEST FAILED: ${failures.length} of ${checks} checks` : `RADAR TEST PASSED: ${checks} checks`);
process.exit(failures.length ? 1 : 0);
