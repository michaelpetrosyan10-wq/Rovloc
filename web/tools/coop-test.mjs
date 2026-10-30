// coop-test.mjs: co-op played for real by up to four browser pages: a host and two clients from the lobby, a third
// client joining mid-run; real WebRTC between the pages (host candidates on this machine, no STUN needed) and the local
// test relay (coop-relay.mjs) standing in for Supabase Realtime; one client is forced onto the relay (?relayonly: its
// direct link times out into the relay fallback).
//
//   node tools/coop-test.mjs [--served] [--live] [--html <page>] [--build] [--no-minify] [--seed 1029]
//
// --live plays the same game through the real Supabase project (no test relay; supabase.co must be reachable) and its
// STUN servers.
// The page is the deliverable (dist/Rovloc.html, built when missing or with --build), opened from file:// (as from a
// Downloads folder: origin "null") or, with --served, from a local HTTP server. Each page has its own browser context
// (its own saved profile, like separate computers); the relay URL rides in the query (?relay=ws://127.0.0.1:<port>),
// so the page's Content-Security-Policy is bypassed for the test relay only (production allows the Supabase host).
// The pages run in real time with the 3D drawing switched off (headless WebGL is software).
//
//   lobby      host through the title's PLAY WITH FRIENDS (the code shown), two joins by code, the squad list on every
//              page (link Direct / Relay and ping), the difficulty vote, ready on every page -> the countdown -> one
//              run deployed everywhere (same seed, own spawn slots)
//   Level 0    two players doing the fuses (the host one, a client two: each carries their own); a fourth player joins
//              mid-run and spectates; the host's networking per tick measured with four players and its CPU slowed 4x;
//              the fuses fitted by both, the breaker thrown: the progress, the carry and the exit door the same on
//              every page
//   downed     the relayed client goes down; the other client revives them (the Revive hold on their avatar)
//   airlock    the host and a client in the vestibule, the relayed client outside: the airlock waits (the straggler
//              timer on every page), the straggler comes in, it seals, every page moves to Level 1; the late joiner
//              gets up there at half health (then leaves)
//   Level 1    the classroom scare set off by a client (the scene on the host, the gate slam everywhere); the Creature
//              hunts and chases a client (not the host): its state, its target and its position agree on that page
//   leaving    a client carrying the master keys closes their page: the keys drop where they stood on the other pages
//   the end    the last client dies and spectates the host; the host dies: a wipe, results on both pages, Play Again
//              waits for both and brings them back to the lobby Ready; then the host closes their page: the client is
//              told "The host left" and is back on the title screen
//   always     poses agree across pages (within interpolation), doors and objective counts agree, the relay sends at
//              most ~10 messages a second per sender, and no page logs a console error
// Exit code 1 on any failure.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startRelay } from './coop-relay.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.resolve(here, '..');
const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const served = argv.includes('--served');
/** --live: the real Supabase project instead of the test relay (needs supabase.co reachable). */
const liveService = argv.includes('--live');
const seed = Number(opt('--seed', '1029'));
let pageFile = path.resolve(opt('--html', path.join(web, 'dist/Rovloc.html')));
if (argv.includes('--build') || !fs.existsSync(pageFile)) {
  execFileSync(process.execPath, [path.join(here, 'build.mjs'), ...(argv.includes('--no-minify') ? ['--no-minify'] : []),
    '--out', pageFile], { stdio: 'inherit' });
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

const { chromium } = loadPlaywright();
const failures = [];
const IGNORED_CONSOLE = /useProgram|Shader Error|WebGL|GPU stall|AudioContext|autoplay/i;
const t0 = Date.now();

function check(name, ok, detail) {
  const time = ((Date.now() - t0) / 1000).toFixed(0).padStart(4);
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${time}s ${name}${detail !== undefined ? ` ${JSON.stringify(detail)}` : ''}`);
  if (!ok) failures.push(name);
  return ok;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ------------------------------------------------------------------------------------------------ the pages
const relay = await startRelay(0);
let server = null;
let base = `file://${pageFile}`;
if (served) {
  server = http.createServer((req, res) => {
    if (!req.url.startsWith('/Rovloc.html')) {
      res.writeHead(404);
      res.end();
      return;
    }
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    fs.createReadStream(pageFile).pipe(res);
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}/Rovloc.html`;
}
const via = liveService ? 'Supabase Realtime (live)' : `relay ${relay.url}`;
console.log(`coop-test: ${served ? 'served' : 'file://'} ${base}, ${via}, seed ${seed}`);

const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist',
  '--autoplay-policy=no-user-gesture-required', '--enable-webgl', '--disable-features=WebRtcHideLocalIpsWithMdns'] });

/** One player's page. */
async function openPlayer(name, query) {
  const context = await browser.newContext({ bypassCSP: true, viewport: { width: 960, height: 540 } });
  const tab = await context.newPage();
  const logs = [];
  const external = [];
  await tab.addInitScript(() => {
    Element.prototype.requestPointerLock = function requestPointerLock() {
      return Promise.resolve();
    };
  });
  tab.on('console', (m) => {
    if (m.type() === 'error' && !IGNORED_CONSOLE.test(m.text())) logs.push(`${name} console.error: ${m.text()}`);
  });
  tab.on('pageerror', (e) => logs.push(`${name} pageerror: ${e.message}\n${e.stack}`));
  tab.on('request', (r) => {
    const u = r.url();
    if (!/^(file|data|blob):/i.test(u) && !u.startsWith(base.split('?')[0])) external.push(u);
  });
  const room = liveService ? '' : `relay=${encodeURIComponent(relay.url)}&`;
  await tab.goto(`${base}?${room}seed=${seed}${query}`);
  return { name, context, tab, logs, external, closed: false };
}

/** Runs `fn(game, dev, arg)` in a page. */
const G = (p, fn, arg) => p.tab.evaluate(([src, a]) => {
  const w = window.__rovlocGame;
  // eslint-disable-next-line no-new-func
  return new Function('game', 'dev', 'arg', `return (${src})(game, dev, arg);`)(w.game, w.dev, a);
}, [fn.toString(), arg]);

/** Polls `fn` in a page until it returns truthy (or the timeout): the last value. */
async function until(p, fn, arg, seconds = 20) {
  const end = Date.now() + seconds * 1000;
  let v = null;
  while (Date.now() < end) {
    v = await G(p, fn, arg);
    if (v) return v;
    await sleep(200);
  }
  return v;
}

const host = await openPlayer('host', '');
const alice = await openPlayer('alice', '');
const bob = await openPlayer('bob', '&relayonly');
const players = [host, alice, bob];
const live = () => players.filter((p) => !p.closed);

try {
  await Promise.all(players.map((p) => p.tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error),
    null, { timeout: 240000 })));
  for (const p of players) {
    const err = await p.tab.evaluate(() => window.__rovloc.error);
    check(`${p.name}: boots`, !err, err);
    await G(p, (g) => {
      window.__rovloc.engine.skipRender = true;
      g.env.setSetting('TutorialDone', true);
      window.__phases = [];
      g.phaseChanged.connect((phase) => window.__phases.push(phase));
    });
  }
  check('nothing is requested before HOST / JOIN', players.every((p) => p.external.length === 0),
    players.flatMap((p) => p.external).slice(0, 3));

  // ---------------------------------------------------------------------------------------------- the room
  await G(host, (g) => {
    g.onboarding.friendsBtn.click();
    g.coop.ui.nameInput.value = 'Hana';
    g.coop.ui.hostBtn.click();
  });
  const code = await until(host, (g) => (g.coop.active && g.coop.ui.codeText.textContent) || null, null, 15);
  check('the host opens a room and the title shows its code', /^[A-HJ-NP-Z2-9]{5}$/.test(code || ''), code);
  await G(host, (g) => g.coop.ui.enterBtn.click());
  for (const [p, name] of [[alice, 'Alice'], [bob, 'Bob']]) {
    await G(p, (g, dev, a) => {
      g.onboarding.friendsBtn.click();
      g.coop.ui.nameInput.value = a.name;
      g.coop.ui.codeInput.value = a.code.toLowerCase();
      g.coop.ui.joinBtn.click();
    }, { name, code });
  }
  const squad3 = await until(host, (g) => g.coop.squad.list().length === 3 && g.coop.squad.list().every((m) => m.id), null, 20);
  check('two clients join by code (typed in lower case)', !!squad3);
  const ids = {};
  for (const p of players) ids[p.name] = await until(p, (g) => g.coop.localId, null, 10);
  const links = await until(host, (g, dev, a) => {
    const m = g.coop.squad.list();
    const al = m.find((x) => x.id === a.alice);
    const bo = m.find((x) => x.id === a.bob);
    return al && bo && al.link === 'direct' && bo.link === 'relay' && al.ping !== null && bo.ping !== null
      ? { alice: al.link, bob: bo.link, pings: [al.ping, bo.ping] } : null;
  }, ids, 25);
  check('links: Alice direct (WebRTC), Bob relay (forced fallback after the timeout); pings measured', !!links, links);
  const bobLink = await G(bob, (g) => g.coop.session.linkOf(g.coop.session.hostId));
  check('Bob\'s page knows it talks through the relay', bobLink === 'relay', bobLink);
  for (const p of players) {
    const rows = await until(p, (g) => {
      const box = g.coop.ui.lobbyBox;
      const text = box ? box.textContent : '';
      return box && g.phase === 'Lobby' && /Hana/.test(text) && /Alice/.test(text) && /Bob/.test(text) ? text : null;
    }, null, 15);
    check(`${p.name}: the lobby lists the squad with links and pings`, !!rows && /Direct/.test(rows) && /Relay/.test(rows), rows);
  }

  // ---------------------------------------------------------------------------------------------- the vote
  const vote = (p, d) => G(p, (g, dev, a) => g.lobby._castVote(a), d);
  await vote(alice, 'Nightmare');
  await vote(bob, 'Nightmare');
  await vote(host, 'Standard');
  const nightmare = await until(bob, (g) => g.lobby.difficulty() === 'Nightmare' && g.coop.lobbyNet.votesFor('Nightmare') === 2, null, 8);
  check('the squad\'s votes decide: two for Nightmare beat one for Standard (every page)', !!nightmare &&
    (await G(host, (g) => g.lobby.difficulty())) === 'Nightmare');
  await vote(bob, 'Standard');
  const tie = await until(alice, (g) => g.lobby.difficulty() === 'Standard' && g.coop.lobbyNet.votesFor('Standard') === 2, null, 8);
  check('a change of vote: Standard wins again', !!tie);

  // ---------------------------------------------------------------------------------------------- ready -> run
  for (const p of players) await G(p, (g) => g.lobby.setReady(true));
  await until(host, (g) => g.phase !== 'Lobby', null, 12);
  await sleep(1500);
  const phases = [];
  for (const p of players) phases.push(await G(p, () => window.__phases.slice()));
  check('every page counts down once the squad is ready', phases.every((list) => list.includes('Countdown')), phases);
  const runs = [];
  for (const p of players) {
    runs.push(await until(p, (g) => (g.phase === 'InRun' && g.level === 'Level0_Basement' ? { seed: g.run.seed, id: g.run.runId,
      root: g.env.rootPosition().toArray().map((v) => Math.round(v * 10) / 10) } : null), null, 30));
  }
  check('one run deployed everywhere: same seed and run id, each at their own spawn', runs.every((r) => r &&
    r.seed === runs[0].seed && r.id === runs[0].id) && new Set(runs.map((r) => r && r.root.join(','))).size === 3, runs);
  check('the host\'s seed (?seed) is the run\'s', runs[0] && runs[0].seed === seed, runs[0] && runs[0].seed);

  // ---------------------------------------------------------------------------------------------- helpers in the run
  /** Stands a player within reach of a point, facing it, until the prompt answering Interact matches `expect`. */
  const standAt = async (p, point, expect, action = 'Interact') => {
    const spots = await G(p, (g, dev, a) => {
      const T = g.env.THREE;
      const q = new T.Vector3(...a.point);
      const traps = g.traps.traps.filter((t) => t.state === 'Armed' && t.level === g.level);
      const out = [];
      for (const reach of [2.2, 3, 1.6, 4]) {
        for (let i = 0; i < 16; i++) {
          const ang = (i / 16) * Math.PI * 2;
          const x = q.x + Math.sin(ang) * reach;
          const z = q.z + Math.cos(ang) * reach;
          const down = g.env.raycast(new T.Vector3(x, q.y + 1.5, z), new T.Vector3(0, -1, 0), 9, { ignoreEntities: false });
          if (!down || down.normal.y < 0.7) continue;
          const root = new T.Vector3(x, down.point.y + 3.05, z);
          if (g.env.raycast(root, new T.Vector3(0, 1, 0), 2.6, { ignoreEntities: false })) continue;
          if (traps.some((t) => Math.hypot(t.floor.x - root.x, t.floor.z - root.z) < 2.5)) continue;
          let blocked = false;
          for (const [dx, dz] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
            if (g.env.raycast(root, new T.Vector3(dx, 0, dz), 1.0, { ignoreEntities: false })) blocked = true;
          }
          if (blocked || !g.env.lineClear(root.clone().add(new T.Vector3(0, 1.5, 0)), q, { ignoreEntities: false })) continue;
          out.push(root.toArray());
        }
      }
      return out;
    }, { point });
    for (const spot of spots.slice(0, 14)) {
      const pr = await G(p, async (g, dev, a) => {
        g.env.teleport({ position: { x: a.spot[0], y: a.spot[1], z: a.spot[2] }, yaw: 0 });
        g.traps.noteTeleport();
        const aim = () => {
          const eye = g.env.eye();
          const d = { x: a.point[0] - eye.x, y: a.point[1] - eye.y, z: a.point[2] - eye.z };
          g.env.setLook(Math.atan2(-d.x, -d.z), Math.atan2(d.y, Math.hypot(d.x, d.z)));
        };
        aim();
        await new Promise((r) => setTimeout(r, 350));
        aim();
        await new Promise((r) => setTimeout(r, 150));
        const active = window.__rovloc.engine.prompts.active.get(a.action);
        return active ? `${active.text} ${active.objectText}` : null;
      }, { spot, point, action });
      if (pr && expect.test(pr)) return pr;
    }
    return null;
  };
  /** Holds a key on a page for `seconds` of that page's game time (a page that runs slow still holds long enough). */
  const gameTime = (p) => p.tab.evaluate(() => window.__rovloc.engine.loop.time);
  const hold = async (p, seconds, key = 'KeyE') => {
    const start = await gameTime(p);
    await p.tab.keyboard.down(key);
    const end = Date.now() + seconds * 4000;
    while (Date.now() < end && (await gameTime(p)) - start < seconds) await sleep(100);
    await p.tab.keyboard.up(key);
    await sleep(250);
  };
  /** The floor's state as a page sees it. */
  const floorState = (p, level) => G(p, (g, dev, lv) => {
    const f = g.floors.floor(lv);
    return { steps: Object.fromEntries(f.spec.steps.map((s) => [s.id, f.count(s.id)])), unlocked: f.unlocked,
      taken: [...f.taken].sort() };
  }, level);
  const doorsState = (p) => G(p, (g) => Object.fromEntries([...g.doors.byId.values()].map((d) => [d.id, d.state])));
  const sameEverywhere = async (name, read) => {
    const values = [];
    for (const p of live()) values.push(JSON.stringify(await read(p)));
    return check(name, values.every((v) => v === values[0]), values.length > 1 && values[0] !== values[1] ? values : values[0]);
  };

  // ---------------------------------------------------------------------------------------------- Level 0: the fuses
  const L0 = 'Level0_Basement';
  const fuses = await G(host, (g, dev, lv) => {
    const f = g.floors.floor(lv);
    return f.items.filter((e) => f.picked(e.id)).map((e) => ({ id: e.id, at: f.pointOf(e.id, 'PromptPoint').toArray() }));
  }, L0);
  check('Level 0 has three picked fuses', fuses.length === 3, fuses.map((f) => f.id));
  const takers = [host, alice, alice];
  for (let i = 0; i < fuses.length; i++) {
    const p = takers[i];
    const pr = await standAt(p, fuses[i].at, /fuse/i);
    check(`${p.name} faces fuse ${i + 1}`, !!pr, pr);
    await hold(p, 1.6);
  }
  await sleep(600);
  const carried = await until(host, (g, dev, a) => {
    const c = g.floors.carry;
    const h = c.of(a.host).get('Fuse') || 0;
    const al = c.of(a.alice).get('Fuse') || 0;
    return h === 1 && al === 2 ? { host: h, alice: al } : null;
  }, ids, 10);
  check('each carries their own fuses (the host 1, Alice 2) on the host\'s page', !!carried, carried);
  const aliceChip = await G(alice, (g) => g.floors.carry.lines().join('|'));
  check('Alice\'s HUD shows her two fuses', /2/.test(aliceChip), aliceChip);
  await sameEverywhere('Level 0 progress (3 fuses found) agrees on every page', (p) => floorState(p, L0));

  // a fourth player joins during the run: they watch until the next airlock
  const dana = await openPlayer('dana', '');
  players.push(dana);
  await dana.tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 240000 });
  await G(dana, (g, dev, c) => {
    window.__rovloc.engine.skipRender = true;
    g.env.setSetting('TutorialDone', true);
    g.onboarding.friendsBtn.click();
    g.coop.ui.nameInput.value = 'Dana';
    g.coop.ui.codeInput.value = c;
    g.coop.ui.joinBtn.click();
  }, code);
  ids.dana = await until(dana, (g) => g.coop.localId, null, 15);
  const late = await until(dana, (g) => (g.phase === 'InRun' && g.life.state === 'Spectating' && g.coop.runNet.spectating
    ? { level: g.level, watching: g.coop.runNet.spectating.name, seed: g.run.seed } : null), null, 25);
  check('a player joining mid-run gets the same run and watches the squad until the next floor', !!late &&
    late.level === 'Level0_Basement' && late.seed === seed, late);

  // the host's networking work per tick with four players, its CPU slowed 4x (a Chromebook's)
  const cdp = await host.context.newCDPSession(host.tab);
  const before = await G(host, (g) => g.coop.perfStats());
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: 4 });
  await sleep(6000);
  const after = await G(host, (g) => g.coop.perfStats());
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: 1 });
  const ticks = after.ticks - before.ticks;
  const mean = ticks > 0 ? (after.mean * after.ticks - before.mean * before.ticks) / ticks : Infinity;
  check(`four players, 4x CPU throttle: the host's networking ${mean.toFixed(3)} ms per tick (< 2 ms), the avatars ` +
    `${after.frameMean.toFixed(3)} ms per frame`, ticks > 10 && mean < 2, { ticks, mean, max: after.max });

  const panel = await G(host, (g, dev, lv) => {
    const f = g.floors.floor(lv);
    return f.slots.map((s) => f.pointOf(f.panel, `FuseSlot${s}Prompt`).toArray()).concat([f.pointOf(f.panel, 'LeverPrompt').toArray()]);
  }, L0);
  for (const [i, p] of [[0, alice], [1, alice], [2, host]]) {
    const pr = await standAt(p, panel[i], /fuse/i);
    check(`${p.name} at fuse slot ${i + 1}`, !!pr, pr);
    await hold(p, 2.4);
  }
  const pr = await standAt(host, panel[3], /breaker|throw|lever/i);
  check('the host at the breaker', !!pr, pr);
  await hold(host, 3.6);
  const powered = await until(bob, (g) => g.floors.floor('Level0_Basement').unlocked, null, 10);
  check('the breaker thrown: Level 0 unlocked on Bob\'s page too', !!powered);
  await sleep(3500);
  await sameEverywhere('Level 0 progress (fitted, thrown, unlocked) agrees on every page', (p) => floorState(p, L0));
  await sameEverywhere('every door agrees on every page (the exit open)', (p) => doorsState(p));

  // ---------------------------------------------------------------------------------------------- downed + revive
  await G(bob, (g) => g.life.down('Test'));
  const downed = await until(host, (g, dev, id) => g.coop.squad.get(id).life === 'Downed', ids.bob, 8);
  check('Bob goes down; the host\'s squad record says so', !!downed);
  const bobAt = await G(bob, (g) => g.env.rootPosition().toArray());
  await sleep(500);
  const revivePrompt = await standAt(alice, [bobAt[0], bobAt[1] - 1.6, bobAt[2]], /revive/i);
  check('Alice gets the Revive prompt on Bob\'s avatar', !!revivePrompt, revivePrompt);
  await hold(alice, 4.6);
  const revived = await until(bob, (g) => (g.life.state === 'Alive' ? { health: g.life.health } : null), null, 8);
  check('Alice\'s hold gets Bob back up at half health', !!revived && revived.health === 50, revived);
  const revives = await G(alice, (g) => g.stats.get('Revives'));
  check('Alice\'s run counts the revive', revives === 1, revives);

  // ---------------------------------------------------------------------------------------------- the airlock
  const vestibule = await G(host, (g) => {
    const T = g.env.THREE;
    const route = g.route(g.level);
    const v = route.checkpointVolumes[0];
    const door = g.doors.get(route.exitDoorIds[0]);
    const c = new T.Vector3(v.cframe[0], door.centre.y, v.cframe[2]);
    const dir = c.clone().sub(door.centre).setY(0).normalize();
    const inside = door.centre.clone().addScaledVector(dir, 7);
    const room = g.world.roomAt(inside, g.level) || g.world.roomAt(c, g.level);
    inside.y = (room ? room.floorY : door.centre.y - 5) + 3.1;
    return { inside: inside.toArray(), yaw: Math.atan2(-dir.x, -dir.z) };
  });
  const enter = (p, dx) => G(p, (g, dev, a) => {
    g.env.teleport({ position: { x: a.inside[0] + a.dx, y: a.inside[1], z: a.inside[2] }, yaw: a.yaw });
    g.traps.noteTeleport();
  }, { ...vestibule, dx });
  await enter(host, 0);
  await enter(alice, 1.2);
  const waiting = await until(bob, (g) => (g.airlock.phase === 'Waiting' && g.airlock.deadline !== null
    ? { left: Math.round(g.airlock.deadline - g.env.now()) } : null), null, 8);
  check('the airlock waits for the straggler: Bob\'s page counts the deadline down', !!waiting && waiting.left > 5, waiting);
  const hostWaits = await G(host, (g) => g.airlock.phase);
  check('the host\'s airlock is Waiting (not sealing without Bob)', hostWaits === 'Waiting', hostWaits);
  await sleep(2500);
  await enter(bob, -1.2);
  const sealed = [];
  for (const p of [host, alice, bob]) {
    sealed.push(await until(p, (g) => (g.level === 'Level1_Hallways' ? { cleared: g.stats.get('FloorsCleared'), life: g.life.state } : null),
      null, 15));
  }
  check('the straggler made it: sealed, every page on Level 1, the floor cleared for all three', sealed.every((s) => s &&
    s.cleared === 1 && s.life === 'Alive'), sealed);
  const danaUp = await until(dana, (g) => (g.level === 'Level1_Hallways' && g.life.state === 'Alive'
    ? { health: g.life.health, cleared: g.stats.get('FloorsCleared') } : null), null, 10);
  check('the late joiner gets up at the new floor with half health (no floor credited)', !!danaUp && danaUp.health === 50 &&
    danaUp.cleared === 0, danaUp);
  dana.closed = true;
  await dana.context.close();
  const three = await until(host, (g) => g.coop.squad.list().length === 3, null, 10);
  check('the late joiner leaves again; the squad is three', !!three);

  // poses agree (direct and relayed)
  await sleep(1200);
  for (const [p, viewer] of [[alice, host], [bob, host], [bob, alice], [host, bob]]) {
    const actual = await G(p, (g) => g.env.rootPosition().toArray());
    const seen = await G(viewer, (g, dev, id) => {
      const m = g.coop.squad.get(id);
      const s = m && m.sample(performance.now() / 1000, {});
      return s ? [s.x, s.y, s.z] : null;
    }, ids[p.name]);
    const d = seen ? Math.hypot(actual[0] - seen[0], actual[1] - seen[1], actual[2] - seen[2]) : Infinity;
    check(`${viewer.name} sees ${p.name} where they stand (${d.toFixed(2)} studs)`, d < 1.5, { actual, seen });
  }

  // ---------------------------------------------------------------------------------------------- Level 1
  await G(alice, (g) => {
    const T = g.env.THREE;
    const door = g.doors.find('Level1_Hallways', 'ClassroomDoor');
    const room = g.world.room('L1_Classroom_108');
    const centre = new T.Vector3(room.rect.x + room.rect.w / 2, room.floorY + 3, room.rect.z + room.rect.d / 2);
    const p = new T.Vector3(door.centre.x, room.floorY + 3, door.centre.z).lerp(centre, 0.35);
    g.env.teleport({ position: p, yaw: 0 });
    g.traps.noteTeleport();
  });
  const scare = await until(host, (g, dev, id) => (g.level1.hasRun() ? { subject: g.level1.scene && g.level1.scene.subjectId,
    full: !!(g.level1.scene && g.level1.scene.full) } : null), ids.alice, 10);
  check('Alice walking into Classroom 108 sets the scare off on the host, with her as its subject', !!scare &&
    scare.subject === ids.alice, scare);
  for (const p of live()) {
    const gate = await until(p, (g) => g.doors.find('Level1_Hallways', 'HallwayGate').state === 'Locked', null, 15);
    check(`${p.name}: the hallway gate slammed Locked`, !!gate);
  }

  // the Creature hunts: Alice in its sight, the host and Bob far off; the pacing told to let it hunt now
  await until(host, (g) => !g.level1.pending().length && g.creature.getState() !== 'Scripted', null, 40);
  const creatureAt = await G(host, (g) => {
    const s = g.creature.c.service;
    s.devHuntUntil = s.now() + 45;
    return { state: s.state, p: s.body.getPosition().toArray() };
  });
  check('the Creature is out of its scene', creatureAt.state !== 'Scripted' && creatureAt.state !== 'Dormant', creatureAt);
  const spawnFar = await G(host, (g) => g.world.spawns('Level1_Hallways', g.run.routes)[0].cframe.slice(0, 3));
  for (const p of [host, bob]) {
    await G(p, (g, dev, a) => {
      g.env.teleport({ position: { x: a[0], y: a[1], z: a[2] }, yaw: 0 });
      g.traps.noteTeleport();
    }, spawnFar);
  }
  const placed = await G(alice, (g, dev, c) => {
    const T = g.env.THREE;
    const at = new T.Vector3(...c.p);
    for (let r = 10; r <= 22; r += 4) {
      for (let i = 0; i < 16; i++) {
        const a = (i / 16) * Math.PI * 2;
        const q = new T.Vector3(at.x + Math.sin(a) * r, at.y + 0.5, at.z + Math.cos(a) * r);
        const down = g.env.raycast(q, new T.Vector3(0, -1, 0), 8, { ignoreEntities: false });
        if (!down) continue;
        const root = new T.Vector3(q.x, down.point.y + 3.05, q.z);
        if (!g.env.lineClear(root.clone().add(new T.Vector3(0, 1.4, 0)), at.clone().add(new T.Vector3(0, 2.5, 0)))) continue;
        const d = at.clone().sub(root);
        g.env.teleport({ position: root, yaw: Math.atan2(-d.x, -d.z) });
        g.traps.noteTeleport();
        return root.toArray();
      }
    }
    return null;
  }, creatureAt);
  check('Alice stands in the Creature\'s sight', !!placed, placed);
  const chase = await until(host, (g, dev, a) => {
    const s = g.creature.c.service.snapshot();
    return s.state === 'WallChase' && s.targetUserId === a.slot + 1 ? { state: s.state, target: s.targetUserId } : null;
  }, { slot: await G(alice, (g) => g.coop.me.slot) }, 20);
  check('the host\'s Creature chases Alice (a client, not the host)', !!chase, chase);
  const aliceSees = await until(alice, (g) => (g.creature.getState() === 'WallChase' && g.creature.chasingPlayer()
    ? { state: g.creature.getState(), at: g.creature.position().toArray() } : null), null, 5);
  const hostCreature = await G(host, (g) => g.creature.position().toArray());
  const lag = aliceSees ? Math.hypot(...aliceSees.at.map((v, i) => v - hostCreature[i])) : Infinity;
  check(`Alice's page: the Creature is chasing her, where the host has it (${lag.toFixed(1)} studs)`, !!aliceSees && lag < 8,
    { aliceSees, hostCreature });
  // called off before it catches her (a catch would take the rest of the test), and away from it
  await G(host, (g) => {
    const s = g.creature.c.service;
    s.devHuntUntil = 0;
    s.ignored = true;
    if (s.jumpscare.isBusy()) s.jumpscare.abort('Test');
  });
  await sleep(500);
  await G(alice, (g, dev, a) => {
    g.env.teleport({ position: { x: a[0] + 3, y: a[1], z: a[2] }, yaw: 0 });
    g.traps.noteTeleport();
  }, spawnFar);
  await sleep(1500);

  // ---------------------------------------------------------------------------------------------- leaving
  const keys = await G(host, (g) => {
    const f = g.floors.floor('Level1_Hallways');
    const e = f.items.find((x) => f.picked(x.id));
    return { id: e.id, at: f.pointOf(e.id, 'PromptPoint').toArray() };
  });
  const keysPrompt = await standAt(alice, keys.at, /key/i);
  check('Alice reaches the master keys', !!keysPrompt, keysPrompt || await G(alice, (g) => ({ life: g.life.state,
    lock: g.controlLock(), ctx: g.env.context(), active: g.floors.floor('Level1_Hallways').active })));
  await hold(alice, 1.6);
  const aliceHas = await until(host, (g, dev, a) => (g.floors.carry.of(a.alice).get('MasterKeys') || 0) === 1, ids, 8);
  check('Alice carries the master keys (the host\'s page agrees)', !!aliceHas);
  const aliceRoot = await G(alice, (g) => g.env.rootPosition().toArray());
  alice.closed = true;
  await alice.context.close();
  const dropped = await until(bob, (g, dev, a) => {
    const f = g.floors.floor('Level1_Hallways');
    const e = g.env.entity(a.id);
    const p = new g.env.THREE.Vector3().setFromMatrixPosition(e.pivot);
    return !f.taken.has(a.id) && !e.hidden && f.itemAvailable(a.id) ? p.toArray() : null;
  }, keys, 15);
  const dropDistance = dropped ? Math.hypot(dropped[0] - aliceRoot[0], dropped[2] - aliceRoot[2]) : Infinity;
  check('Alice leaves: the keys drop where she stood, takeable on Bob\'s page', !!dropped && dropDistance < 2, { dropped, aliceRoot });
  const hostSquad = await until(host, (g) => g.coop.squad.list().length === 2, null, 10);
  check('the host\'s squad is down to two; the run goes on', !!hostSquad && (await G(host, (g) => g.phase)) === 'InRun');
  await sameEverywhere('Level 1 progress agrees after the leave', (p) => floorState(p, 'Level1_Hallways'));

  // relay traffic
  const elapsed = (Date.now() - t0) / 1000;
  // counted by the relay (the test relay) or by the pages themselves (--live: Supabase counts on its side)
  const counted = (p, id) => (liveService ? G(p, (g) => g.coop.session.relayStats().messages)
    : relay.bySender[id] && relay.bySender[id].r ? relay.bySender[id].r.messages : 0);
  const bobSent = await counted(bob, ids.bob);
  const hostSent = await counted(host, ids.host);
  check(`the relay stays frugal: Bob ${(bobSent / elapsed).toFixed(1)} and the host ${(hostSent / elapsed).toFixed(1)} messages/s`,
    bobSent / elapsed <= 10.5 && hostSent / elapsed <= 10.5 && bobSent > 0, { bobSent, hostSent, seconds: Math.round(elapsed) });

  // dead: Bob watches the host; then the host dies too: the squad is wiped, results on both pages, Play Again
  await G(bob, (g) => {
    g.life.down('Test');
    g.life.execute('Test');
  });
  const watching = await until(bob, (g, dev, id) => (g.coop.runNet.spectating && g.coop.runNet.spectating.id === id
    ? g.coop.runNet.hudName.textContent : null), ids.host, 10);
  check('Bob dies and spectates the host (camera in their eyes, the HUD says who)', !!watching && /Hana/.test(watching), watching);
  const going = await G(host, (g) => ({ phase: g.phase, verdict: g.match.verdict() }));
  check('the run goes on while the host is alive', going.phase === 'InRun' && going.verdict === 'Continue', going);
  await G(host, (g) => {
    g.life.down('Test');
    g.life.execute('Test');
  });
  const results = [];
  for (const p of [host, bob]) {
    results.push(await until(p, (g) => (g.phase === 'Results' && g.match.summary ? { outcome: g.match.summary.outcome,
      size: g.match.summary.squadSize, verdict: g.match.summary.verdict } : null), null, 10));
  }
  check('nobody left alive: the run resolves as a wipe on both pages (a squad of two)', results.every((r) => r &&
    r.outcome === 'Dead' && r.size === 2 && r.verdict === 'Wipe'), results);
  await G(bob, (g) => g.match.pressPlayAgain());
  await sleep(800);
  const stillResults = await G(host, (g) => g.phase);
  check('Play Again waits for the whole squad', stillResults === 'Results', stillResults);
  await G(host, (g) => g.match.pressPlayAgain());
  const back = [];
  for (const p of [host, bob]) {
    back.push(await until(p, (g) => (g.phase === 'Lobby' || g.phase === 'Countdown' ? { phase: g.phase, ready: g.lobby.ready }
      : null), null, 10));
  }
  check('both back in the lobby, Ready (Play Again)', back.every((b) => b && b.ready), back);

  // the host leaves
  host.closed = true;
  await host.context.close();
  const told = await until(bob, (g) => (!g.coop.active && g.onboarding.mode === 'Title' ? g.coop.ui.messageText.textContent : null),
    null, 15);
  check('the host leaves: Bob is told "The host left" and is back on the title screen', !!told && /host left/i.test(told), told);
} catch (err) {
  check('the run completed without an exception', false, String(err && err.stack ? err.stack : err));
} finally {
  for (const p of players) {
    for (const l of p.logs) console.log(l);
    check(`${p.name}: no console errors`, p.logs.length === 0, p.logs.length);
  }
  await browser.close();
  await relay.close();
  if (server) server.close();
}
console.log(failures.length ? `\n${failures.length} failure(s)` : '\nall co-op checks passed');
process.exit(failures.length ? 1 : 0);
