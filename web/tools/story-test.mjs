// story-test.mjs: the story's cutscenes, the opening and the prologue on the website (docs/design/game-spec-v2.md 2.3,
// 2.4, 4.1; WP11; invariants I7, I8, I11, I13), against the rules and in the game.
//
//   node tools/story-test.mjs [--no-build] [--html <page>] [--only rules,solo,fps,coop] [--shots <dir>]
//
// rules  rules/tracks.js and rules/names.js (the ports of CinematicTracks and NameSanitizer) replay every golden row of
//        build/cache/golden.json (numbers within 1e-9); then the spec's numbers, written here from the spec's text
//        (never read back from meta.storyConfig): the opening 61.0 s Full and 24.0 s Short; every line of 2.4's table
//        at its start in its slot, words / (2.6 x rate) within it and none overlapping (1 to 4 players); the vote
//        matrix 1/1, 1/2, 2/3, 2/4, 3/4 with and without a first-timer; the automatic climb-out at 8 s; the chute's
//        30 s rule and the prologue's 50 s; a bin per slot.
// solo   one page (the game test page, unminified), a solo run from the deploy: the squad placed in its bin (slot 1:
//        Dumpster A), the Full opening watched through (the Cutscene lock, the letterbox, every line heard at its start
//        with the page's own name in {you}, P2's line skipped alone), nobody hurt or caught while it plays (I13), the
//        hand-over at 61.0 s; the prologue: still in the bin at 7.9 s, out by itself at 8 s, I13 (no damage, no
//        noise), the walk to the hatch (real keys), "Climb in", the cut, the Basement: the phase InRun and the run
//        clock from its activation; a replay: the Short cut, the hand-over at 24.0 s, the skip vote (alone at once:
//        the fade to the last shot).
// fps    the same page: the Creature (the Monster actor, placed on the tick) at every tick of 43..47 s of the opening
//        played at 20 fps, then at 144 fps: identical positions (I8).
// coop   two pages (the single-file game, the local test relay): a bin per slot (host Dumpster A, client the skip),
//        one cut and one cast on both, two pages within one tick, each page its own {you}; the vote: one of two does
//        not pass; a first-timer's veto holds a majority; both pass; the prologue's chute: the host in, the client
//        not, the cut on both pages 30 s after the first (the client placed in it), the Basement on both.
// --shots <dir>  six frames of the opening (the walk-out, the bin, the crawler, the jump, the transformation, the bins
//        at night) at the High tier.
// Exit code 1 on any failure.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { startRelay } from './coop-relay.mjs';
import { AT_HATCH, passOpening } from './story-pass.mjs';
import { nameRules } from '../src/game/rules/names.js';
import { cinematicTracks } from '../src/game/rules/tracks.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.resolve(here, '..');
const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const only = new Set(opt('--only', 'rules,solo,fps,coop').split(','));
const shotsDir = opt('--shots', null);
const failures = [];
let checks = 0;

function check(name, ok, detail) {
  checks++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail !== undefined ? ` ${JSON.stringify(detail)}` : ''}`);
  if (!ok) failures.push(name);
  return ok;
}

const meta = JSON.parse(fs.readFileSync(path.join(web, 'build/world.json'), 'utf8'));
const T = cinematicTracks(meta);
const N = nameRules(meta);
const TICK = 1 / T.story.TickRate;

/** Plain data equal (numbers within 1e-9; a missing key and null alike). */
function same(a, b) {
  if (a === null) a = undefined;
  if (b === null) b = undefined;
  if (typeof a === 'number' || typeof b === 'number') return typeof a === 'number' && typeof b === 'number' && Math.abs(a - b) <= 1e-9;
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
    return [...keys].every((k) => same(a[k], b[k]));
  }
  return a === b;
}

// ------------------------------------------------------------------------------------------------ the rules
if (only.has('rules')) {
  console.log('== the rules (rules/tracks.js, rules/names.js)');
  const golden = JSON.parse(fs.readFileSync(path.join(web, 'build/cache/golden.json'), 'utf8'));
  for (const [module, rules, least] of [['CinematicTracks', T, 60], ['NameSanitizer', N, 30]]) {
    const rows = golden[module] || [];
    const bad = [];
    const fns = new Set();
    for (const row of rows) {
      fns.add(row.fn);
      const fn = rules[row.fn];
      const got = typeof fn === 'function' ? fn(...row.args) : undefined;
      if (!same(got, row.expect)) bad.push({ row: row.name, got });
    }
    check(`every ${module} golden row replays exactly (${rows.length} rows over ${fns.size} functions)`,
      rows.length >= least && bad.length === 0, bad.slice(0, 2));
  }

  // the spec's numbers, from its text
  check('the opening: Full 61.0 s, Short 24.0 s', Math.abs(T.length('Opening', 'Full') - 61.0) < 1e-9 &&
    Math.abs(T.length('Opening', 'Short') - 24.0) < 1e-9);
  check('the Short cut opens with S1 and closes with S16 (the hand-over at its end)', T.toSource('Opening', 'Short', 0).t === 0 &&
    Math.abs(T.toSource('Opening', 'Short', 23.99).t - 60.99) < 1e-6);
  // 2.4's lines: start, slot, speaker's web rate (Danny 1.05, the Tall Man 0.82, the PA 0.95)
  const TABLE = [[4.6, 4.0, 1.05], [9.3, 3.4, 1.05], [12.9, 1.6, 1.05], [14.8, 3.2, 1.05], [18.0, 1.5, 1.05], [21.0, 1.6, 1.05],
    [23.6, 2.6, 1.05], [26.4, 1.8, 1.05], [32.0, 2.0, 1.05], [50.1, 2.5, 0.82], [54.0, 2.2, 0.95], [59.2, 1.5, 0.82]];
  const lines = T.story.Timelines.Opening.lines;
  for (const [start, slot, rate] of TABLE) {
    const line = lines.find((l) => Math.abs(l.t - start) < 1e-9);
    const words = line ? T.words(line.text) : 99;
    check(`2.4: the line at ${start} s has its ${slot} s slot and fits it (${words} words / (2.6 x ${rate}) = ` +
      `${(words / (2.6 * rate)).toFixed(2)} s)`, !!line && Math.abs(line.slot - slot) < 1e-9 && words <= 12 &&
      words / (2.6 * rate) <= slot + 1e-9 && (!line.twin || T.words(line.twin) / (2.6 * rate) <= slot + 1e-9), line && line.text);
  }
  for (const id of T.story.Order) {
    const timeline = T.story.Timelines[id];
    for (const line of timeline.lines) {
      const speaker = T.story.Speakers[line.speaker];
      const rate = line.rate ?? (speaker ? speaker.voice.web.rate : 1);
      if (!(T.words(line.text) / (2.6 * rate) <= line.slot + 1e-9 && T.words(line.text) <= 12)) {
        check(`${id}: ${line.id} fits its slot`, false, line.text);
      }
    }
    for (let players = 1; players <= 4; players++) {
      for (const cut of ['Full', 'Short']) {
        if (cut === 'Short' && !timeline.cuts.Short) continue;
        const heard = T.lines(id, cut, -1, T.length(id, cut), players);
        const overlap = heard.find((l, i) => i > 0 && l.at < heard[i - 1].at + heard[i - 1].slot - 1e-9);
        if (overlap) check(`${id} ${cut}, ${players} players: no two lines overlap`, false, overlap);
      }
    }
  }
  check('every line of every cutscene fits its slot, and no two overlap (1 to 4 players, both cuts)',
    !failures.some((f) => /fits its slot|overlap/.test(f)));
  // the vote matrix: votes / players, with and without a first-timer who did not vote
  const ids = ['a', 'b', 'c', 'd'];
  const matrix = [[1, 1, true], [1, 2, false], [2, 3, true], [2, 4, false], [3, 4, true]];
  for (const [votes, players, passes] of matrix) {
    const voters = ids.slice(0, votes);
    check(`the vote ${votes}/${players}: ${passes ? 'passes' : 'holds'}`, T.skipPasses('Opening', players, voters, []) === passes);
    const outsider = ids[players - 1];
    const firstTimerVoted = voters.includes(outsider);
    check(`the vote ${votes}/${players} with a first-timer (${outsider}, ${firstTimerVoted ? 'voted' : 'did not vote'}): ` +
      `${passes && firstTimerVoted ? 'passes' : 'holds'}`, T.skipPasses('Opening', players, voters, [outsider]) === (passes && firstTimerVoted));
  }
  check('the vote is offered from 5 s in, never in the last shot', !T.skipOffered('Opening', 'Full', 4.99) &&
    T.skipOffered('Opening', 'Full', 5) && !T.skipOffered('Opening', 'Full', 59.5));
  check('the prologue: out of the bin by itself at 8 s', T.climbOutAt(100) === 108);
  check('the chute: 30 s after the first in, at once when everyone is in, 50 s at most', T.chuteCutAt(61, 73, -1) === 103 &&
    T.chuteCutAt(61, 73, 78) === 78 && T.chuteCutAt(61, -1, -1) === 111 && T.chuteCutAt(61, 93, -1) === 111);
  // a bin per slot: four BinStart marks, slots 1..4, and the opening's bins at them
  const starts = (meta.anchors || []).filter((a) => a.kind === 'BinStart');
  const slots = new Set(starts.map((a) => a.attributes.Slot));
  check('a bin per slot: four BinStart marks, slots 1 to 4', starts.length === 4 && [1, 2, 3, 4].every((s) => slots.has(s)), [...slots]);
  const bins = T.story.Timelines.Opening.points.Bins;
  const origin = meta.anchors.find((a) => a.id === 'BL_Mark_Origin');
  const binOk = starts.every((a) => {
    const inside = bins[a.attributes.Slot - 1].Inside;
    // the origin mark turned 180 degrees: world x = -x, z = 290 - z
    return Math.abs(origin.cframe[0] - inside.x - a.cframe[0]) < 0.8 && Math.abs(origin.cframe[2] - inside.z - a.cframe[2]) < 0.8;
  });
  check('each party actor dives into its own slot\'s bin', binOk);
  check('names: the first token, 2 to 12 letters, the blocklist with leetspeak', N.sanitize('MayaRivers') === 'Maya' &&
    N.sanitize('x') === '' && N.sanitize('sh1t') === '' && N.compose({ text: '{you}…', twin: 'Still here…' }, { you: 'Bo' }, true) === 'Bo…');
}

// ------------------------------------------------------------------------------------------------ the pages
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

const IGNORED_CONSOLE = /useProgram|Shader Error|WebGL|GPU stall|AudioContext|autoplay/i;

/** A page's handles: G(fn, arg) runs fn(game, dev, arg) in it; ff(s) steps its game s seconds at 30 Hz, unrendered. */
function handles(tab) {
  const G = (fn, arg) => tab.evaluate(([src, a]) => {
    const w = window.__rovlocGame;
    // eslint-disable-next-line no-new-func
    return new Function('game', 'dev', 'arg', `return (${src})(game, dev, arg);`)(w.game, w.dev, a);
  }, [fn.toString(), arg]);
  const ff = (seconds, fps = 30) => tab.evaluate(([s, rate]) => {
    const e = window.__rovloc.engine;
    e.loop.stop();
    const render = e.renderer.render;
    e.renderer.render = () => {};
    try {
      for (let i = 0; i < Math.round(s * rate); i++) e.loop._run(1 / rate, 1 / rate);
    } finally {
      e.renderer.render = render;
    }
  }, [seconds, fps]);
  return { G, ff };
}

/** Opens the game test page in a fresh context; resolves once it booted. */
async function openPage(browser, url, name) {
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
    if (m.type() === 'error' && !IGNORED_CONSOLE.test(m.text())) logs.push(`${name}: ${m.text()}`);
  });
  await tab.goto(url);
  await tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 240000 });
  const h = handles(tab);
  // on to the playing timeline's time t (it starts once the deploy has placed the squad: stepped a tick at a time until
  // it plays, at most 5 s of game time)
  const toTime = async (t) => {
    for (let i = 0; i < 150 && !(await h.G((g) => !!g.cinematics.current)); i++) await h.ff(1 / 30);
    return h.ff(Math.max(0, await h.G((g, dev, at) => g.cinematics.current.startAt + at - g.env.now(), t)));
  };
  return { name, context, tab, logs, toTime, ...h };
}

const needPage = only.has('solo') || only.has('fps') || shotsDir;
let page = opt('--html', null);
if (needPage && !page) {
  page = path.join(web, 'build/cache/story-test.html');
  if (!argv.includes('--no-build') || !fs.existsSync(page)) {
    execFileSync(process.execPath, [path.join(here, 'game-build.mjs'), '--out', page, '--no-minify'], { stdio: 'inherit' });
  }
}
const browser = needPage || only.has('coop') ? await loadPlaywright().chromium.launch({ args: ['--use-angle=swiftshader',
  '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--autoplay-policy=no-user-gesture-required', '--enable-webgl',
  '--disable-features=WebRtcHideLocalIpsWithMdns'] }) : null;

/** Deploys a solo run from the lobby (the title closed), on Standard; the page's name set first. */
async function soloDeploy(p, name) {
  await p.G((g, dev, n) => {
    window.__rovloc.engine.loop.stop();
    window.__rovloc.engine.skipRender = true;
    g.env.setSetting('PlayerName', n);
    g.env.setSetting('NameAsked', true);
    g.env.setSetting('TutorialDone', true);
    g.onboarding.closeForCoop();
    window.__subs = [];
    const show = g.cinematics.subtitles.show.bind(g.cinematics.subtitles);
    g.cinematics.subtitles.show = (line) => {
      window.__subs.push({ at: g.cinematics.time(), speaker: line.speaker, struck: !!line.struck, text: line.text, ear: !!line.ear,
        seconds: line.seconds });
      return show(line);
    };
    window.__ends = [];
    // the hand-overs as they happen (then the opening's own: on to the prologue, and what it puts on screen at once)
    g.cinematics.onEnded('Opening', (reason) => {
      const end = { reason, now: g.env.now() };
      window.__ends.push(end);
      g.opening._ended(reason);
      end.tell = g.prologue.tell.style.display !== 'none' ? g.prologue.tell.textContent : null;
    });
    window.__activations = [];
    g.stageActivated.connect((stage) => window.__activations.push({ stage, phase: g.phase, at: g.env.now() }));
    dev.deploy('Standard');
  }, name);
}

try {
  if (only.has('solo') || only.has('fps')) {
    const p = await openPage(browser, `file://${page}?dev&seed=1029`, 'solo');
    const { G, ff, tab, toTime } = p;
    check('solo: boots', !(await tab.evaluate(() => window.__rovloc.error)));
    if (only.has('solo')) {
      console.log('== solo: the Full opening watched through, the prologue, the Basement');
      await soloDeploy(p, 'MayaRivers');
      await ff(0.6);
      await toTime(0.5);
      let s = await G((g) => {
        const c = g.cinematics.current;
        const root = g.env.rootPosition();
        const bin = g.world.meta.anchors.find((a) => a.id === 'BL_BinStart_1');
        return { phase: g.phase, stage: g.stage, lock: g.controlLock(), id: c && c.id, cut: c && c.cut, t: g.cinematics.time(),
          startAt: c && c.startAt, bars: g.cinematics.barTop.style.height, ui: g.cinematics.ui.style.display,
          inBin: Math.hypot(root.x - bin.cframe[0], root.z - bin.cframe[2]) < 0.5, hidden: g.env.moveState(),
          storm: window.__rovloc.engine.lighting.stormEnabled };
      });
      check('the deploy: the match phase Prologue on the Back Lot, the Opening (Full the first time) under the Cutscene lock',
        s.phase === 'Prologue' && s.stage === 'BackLot' && s.lock === 'Cutscene' && s.id === 'Opening' && s.cut === 'Full', s);
      check('the squad placed at the bin marks: alone, slot 1, Dumpster A, hidden in it', s.inBin && s.hidden === 'Hiding', s);
      check('the letterbox: bars of 12 % each', parseFloat(s.bars) === 12 && /vh$/.test(s.bars) && s.ui !== 'none', s.bars);
      check('a timeline\'s start is on a tick (I8)', Math.abs(s.startAt / TICK - Math.round(s.startAt / TICK)) < 1e-6, s.startAt);
      check('the ambient storm is off while the cutscene plays (2.3: its weather is the timeline\'s)', s.storm === false, s.storm);
      const startAt0 = s.startAt;
      // I13 while it plays: no lethal hit, no damage, no catch
      s = await G((g) => {
        g.life.lethal('Catch', 'Test');
        g.life.damage(500, 'Test');
        return { life: g.life.state, health: g.life.health, safe: g.safeMoment(), catchable: g.playing() };
      });
      check('I13 in the cutscene: a lethal hit and 500 damage change nothing, nobody can be caught', s.life === 'Alive' &&
        s.health === 100 && s.safe && !s.catchable, s);
      // to the end, a tick at a time near it
      s = await G((g) => g.cinematics.time());
      await ff(60.9 - s);
      s = await G((g) => ({ active: g.cinematics.active(), t: g.cinematics.time() }));
      check('60.9 s: the opening still plays', s.active, s);
      await ff(0.2);
      s = await G((g) => ({ active: g.cinematics.active(), ends: window.__ends, pro: g.prologue.state, handOver: g.prologue.handOver,
        lock: g.controlLock(), phase: g.phase }));
      check('the hand-over at 61.0 s (Full): the prologue starts in the bin, still the Prologue phase', !s.active &&
        s.ends.length === 1 && s.ends[0].reason === 'End' && Math.abs(s.ends[0].now - startAt0 - 61) <= TICK + 1e-6 &&
        s.pro === 'Bin' && s.phase === 'Prologue', s);
      const subs = await G(() => window.__subs);
      const wanted = [[4.6, 'Did you SEE Kessler'], [9.3, 'Maya, back me up'], [12.9, 'Worth the detention'], [14.8, 'Sal\'s?'],
        [21.0, 'Wait. Guys.'], [23.6, 'Ha! Look'], [26.4, 'Booo.'], [32.0, 'GET IT OFF'], [50.1, 'I know you\'re close, Maya.'],
        [54.0, 'LOCKDOWN'], [59.2, 'Maya…']];
      const missing = wanted.filter(([at, text]) => !subs.some((x) => Math.abs(x.at - at) <= TICK + 1e-6 && x.text.includes(text)));
      check('every line at its start (within a tick), with this page\'s name for {P1} and {you}', missing.length === 0, missing);
      check('alone, P2\'s line ("…you\'re paying") is skipped', !subs.some((x) => /paying/.test(x.text)), subs.length);
      const ear = subs.find((x) => /close/.test(x.text));
      check('the monster\'s whisper: DANNY struck through, in italics (Ear)', !!ear && ear.speaker === 'DANNY' && ear.struck && ear.ear, ear);
      check('each subtitle stays up for its line\'s slot', subs.every((x) => x.seconds > 0 && x.seconds <= 4.0), subs.map((x) => x.seconds));
      const seen = await G((g) => g.profile.cutsceneSeen('Opening'));
      check('the Full cut played to its end marks the opening seen', seen === true);
      // the hand-over's first words say what to do, there at once (in the hand-over's own tick: nothing to wait for)
      s = await G((g) => ({ atHandOver: window.__ends[0].tell, shown: g.prologue.tell.style.display !== 'none',
        text: g.prologue.tell.textContent, z: Number(getComputedStyle(g.prologue.tell).zIndex),
        menuZ: Number(getComputedStyle(document.querySelector('.rv-menu')).zIndex),
        storm: window.__rovloc.engine.lighting.stormEnabled }));
      check('the hand-over: "Hold E to push the lid" is on screen in its own tick, and stays', s.atHandOver ===
        'Hold E to push the lid' && s.shown && s.text === 'Hold E to push the lid', s);
      check('the hint sits under the pause menu', s.z > 0 && s.menuZ > s.z, s);
      check('the ambient storm is back at the hand-over', s.storm === true, s.storm);

      // the lid's prompt answers whichever way the player looks: they are inside the bin, and its anchor is at their feet
      for (const [yaw, pitch] of [[0, 0.9], [2.6, 0.4], [-1.5, -0.2]]) {
        await G((g, look) => g.env.setLook(look[0], look[1]), [yaw, pitch]);
        await ff(0.1);
        s = await G(() => {
          const p = window.__rovloc.engine.prompts.active.get('Interact');
          return { text: p ? p.text : null, shown: !!p && p.shown };
        });
        check(`in the bin, looking ${yaw} / ${pitch}: "Push the lid" answers`, s.text === 'Push the lid' && s.shown, s);
      }
      s = await G(() => {
        const p = window.__rovloc.engine.prompts.active.get('Interact');
        return p ? p.objectText : null;
      });
      check('the lid\'s prompt names its object in words ("Bin", not a string key)', s === 'Bin', s);
      await G((g) => g.env.setLook(0, -0.05));
      // the prologue: the automatic climb-out at 8 s (counted from the hand-over)
      const inBin = await G((g) => g.env.now() - g.prologue.handOver);
      await ff(7.9 - inBin);
      s = await G((g) => ({ pro: g.prologue.state, since: g.env.now() - g.prologue.handOver }));
      check('the prologue: still in the bin at 7.9 s', s.pro === 'Bin', s);
      await ff(0.2);
      s = await G((g) => ({ pro: g.prologue.state, tell: g.prologue.tell.style.display !== 'none' }));
      check('8 s in the bin: the climb-out happens by itself (and "Hold E to push the lid" goes)', s.pro === 'Climbing' &&
        !s.tell, s);
      await ff(1.3);
      s = await G((g) => {
        const before = g.life.health;
        g.life.lethal('Catch', 'Test');
        g.life.damage(500, 'Test');
        const noise = g.noise(g.env.rootPosition(), 'Sprint');
        return { pro: g.prologue.state, life: g.life.state, health: g.life.health, before, noise, lock: g.controlLock(), safe: g.safeMoment() };
      });
      check('on the lot: free to move; I13 holds (no lethal hit, no damage, no noise)', s.pro === 'Lot' && s.lock === 'None' &&
        s.life === 'Alive' && s.health === s.before && s.noise === null && s.safe, s);
      // the walk to the hatch, for real: facing it, W held
      const walk = await G((g) => {
        const root = g.env.rootPosition();
        const hatch = g.prologue.hatch.attachments.ClimbIn;
        const at = new g.env.THREE.Matrix4().fromArray([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
        const climbIn = g.env.attachmentWorld(g.prologue.hatch.id, 'ClimbIn', at);
        const target = new g.env.THREE.Vector3().setFromMatrixPosition(climbIn);
        const dx = target.x - root.x;
        const dz = target.z - root.z;
        g.env.setLook(Math.atan2(-dx, -dz), -0.3);
        return { distance: Math.hypot(dx, dz), hatch: !!hatch };
      });
      await tab.keyboard.down('KeyW');
      let walked = null;
      for (let i = 0; i < 40 && !walked; i++) {
        await ff(0.25);
        walked = await G((g) => (g.prologue.atHatch() && g.prologue.climbPrompt ? g.env.rootPosition().toArray() : null));
      }
      await tab.keyboard.up('KeyW');
      check(`the walk from the bin to the hatch (${walk.distance.toFixed(1)} studs) on foot`, !!walked && walk.distance >= 25 &&
        walk.distance <= 46, walked);
      await ff(0.3);
      await tab.keyboard.down('KeyE');
      await ff(0.75);
      await tab.keyboard.up('KeyE');
      s = await G((g) => ({ pro: g.prologue.state, dark: g.prologue.line.textContent }));
      check('"Climb in" at the hatch: into the chute; alone everyone is in, so the cut follows', s.pro === 'Chute' || s.pro === 'Cut', s);
      await ff(0.2);
      s = await G((g) => ({ pro: g.prologue.state }));
      check('the cut (the hatch pushed shut, the bolt)', s.pro === 'Cut', s);
      await ff(1.7);
      s = await G((g) => ({ phase: g.phase, stage: g.stage, level: g.level, clockFrom: g.run.clockFrom, acts: window.__activations,
        pro: g.prologue.state, cin: g.cinematics.active() }));
      const basement = s.acts.find((a) => a.stage === 'Level0_Basement');
      check('the Basement: InRun at its activation, the run clock from that moment', s.phase === 'InRun' && s.level === 'Level0_Basement' &&
        !!basement && basement.phase === 'InRun' && Math.abs(s.clockFrom - basement.at) < 1e-9 && s.pro === null && !s.cin, s);
      const backLot = s.acts.find((a) => a.stage === 'BackLot');
      check('the Back Lot activated in the Prologue phase; no run clock before the Basement', !!backLot && backLot.phase === 'Prologue');

      // a replay: the Short cut, the hand-over at 24.0 s; the skip vote alone passes at once
      console.log('== solo: a replay (Short), the skip');
      await G((g) => {
        g.match.reset();
        window.__ends = [];
        window.__subs = [];
      });
      await G((g, dev) => {
        dev.deploy('Standard'); // its promise settles on the game's own steps (ff below)
      });
      await ff(0.6);
      s = await G((g) => ({ cut: g.cinematics.current && g.cinematics.current.cut, len: g.cinematics.current && g.cinematics.current.length }));
      check('a replay plays the Short cut (every member has seen the Full one; nobody asked for Full)', s.cut === 'Short' &&
        Math.abs(s.len - 24) < 1e-9, s);
      await toTime(23.9);
      s = await G((g) => g.cinematics.active());
      check('23.9 s: the Short cut still plays', s === true);
      await ff(0.2);
      s = await G((g) => ({ active: g.cinematics.active(), ends: window.__ends, pro: g.prologue.state }));
      check('the hand-over at 24.0 s (Short)', !s.active && s.ends.length === 1 && s.pro === 'Bin', s);
      await G((g) => {
        g.match.reset();
        window.__ends = [];
        g.env.setSetting('ReplayCutscenes', 'Full');
      });
      await G((g, dev) => {
        dev.deploy('Standard'); // its promise settles on the game's own steps (ff below)
      });
      await ff(0.6);
      s = await G((g) => g.cinematics.current && g.cinematics.current.cut);
      check('"Cutscenes on replays: Full" plays the Full cut again', s === 'Full', s);
      await toTime(4.0);
      await tab.keyboard.down('Enter');
      await ff(0.9);
      s = await G((g) => ({ t: g.cinematics.time(), voted: g.cinematics.skip.voted }));
      check('the skip is not offered before 5 s: a hold from 4 s has not voted at 4.9 s', s.voted === false, s);
      await ff(1.2);
      await tab.keyboard.up('Enter');
      s = await G((g) => ({ t: g.cinematics.time(), skipping: !!(g.cinematics.current && g.cinematics.current.skipping),
        voted: g.cinematics.skip.voted }));
      check('held on, it votes 1.0 s after the offer (6.0 s): alone the vote passes at once', s.voted === true && s.skipping, s);
      await ff(0.7);
      s = await G((g) => ({ t: g.cinematics.time(), shot: g.cinematics.tracks.sample('Opening', 'Full', g.cinematics.time(),
        g.cinematics.current.binding).shot }));
      check('alone the vote passes at once: the fade, then the last shot (S16 from 59.0 s)', s.shot === 'S16' && s.t >= 59 && s.t < 60, s);
      await G((g) => g.env.setSetting('ReplayCutscenes', 'Short'));
      await G((g) => g.match.reset());
    }

    if (only.has('fps')) {
      console.log('== fps: the Monster actor on the tick at 20 and 144 fps (I8)');
      const record = async (fps) => {
        await G((g) => {
          g.env.setSetting('ReplayCutscenes', 'Full');
          if (g.run) g.match.reset();
          g.onboarding.closeForCoop();
        });
        await G((g, dev) => {
          dev.deploy('Standard'); // its promise settles on the game's own steps (ff below)
        });
        await ff(0.5);
        await toTime(43);
        await G(() => {
          const g = window.__rovlocGame.game;
          window.__track = [];
          window.__offTrack = g.env.onTick(() => {
            const p = g.creature.position();
            const crawler = g.cinematics.current ? g.cinematics.tracks.sample('Opening', 'Full', g.cinematics.time(),
              g.cinematics.current.binding).actors.P1.pos : null;
            if (p) window.__track.push({ t: g.cinematics.time(), p: [p.x, p.y, p.z], party: crawler });
          }, 1000);
        });
        await ff(4, fps);
        return G(() => {
          window.__offTrack();
          return window.__track;
        });
      };
      const slow = await record(20);
      const fast = await record(144);
      const byTick = (list) => new Map(list.map((e) => [Math.round(e.t / TICK), e]));
      const a = byTick(slow);
      const b = byTick(fast);
      let compared = 0;
      const diffs = [];
      for (const [k, e] of a) {
        const f = b.get(k);
        if (!f) continue;
        compared++;
        if (e.p.some((v, i) => Math.abs(v - f.p[i]) > 1e-9) || !same(e.party, f.party)) diffs.push({ tick: k, slow: e, fast: f });
      }
      check(`actor positions identical at 20 and 144 fps (${compared} ticks of 43..47 s compared: the Creature and P1)`,
        compared >= 100 && diffs.length === 0, diffs.slice(0, 2));
      await G((g) => {
        g.env.setSetting('ReplayCutscenes', 'Short');
        if (g.run) g.match.reset();
      });
    }
    if (p.logs.length) check('solo: no console errors', false, p.logs.slice(0, 5));
    await p.context.close();
  }

  // ---------------------------------------------------------------------------------------------- the frames
  if (shotsDir) {
    console.log('== frames of the opening');
    fs.mkdirSync(shotsDir, { recursive: true });
    const p = await openPage(browser, `file://${page}?dev&seed=1029`, 'shots');
    const { G, ff, tab, toTime } = p;
    await G((g) => {
      window.__rovloc.engine.loop.stop();
      g.env.setSetting('Graphics', 'High');
      g.env.setSetting('PlayerName', 'Maya');
      g.env.setSetting('NameAsked', true);
      g.onboarding.closeForCoop();
    });
    await G((g, dev) => {
      dev.deploy('Standard'); // its promise settles on the game's own steps (ff below)
    });
    await ff(0.5);
    const FRAMES = [[6.5, '1-walk-out'], [20.5, '2-the-bin'], [29.6, '3-the-crawler'], [31.9, '4-the-jump'],
      [41.2, '5-the-transformation'], [60.8, '6-the-bins-at-night']];
    for (const [t, name] of FRAMES) {
      await toTime(t);
      await tab.evaluate(() => {
        const e = window.__rovloc.engine;
        for (let i = 0; i < 3; i++) e.loop._run(1 / 90, 1 / 90);
      });
      const file = path.join(shotsDir, `opening-${name}.png`);
      await tab.screenshot({ path: file });
      console.log(`  ${file}`);
    }
    await p.context.close();
  }

  // ---------------------------------------------------------------------------------------------- co-op
  if (only.has('coop')) {
    console.log('== coop: two pages');
    const coopPage = path.join(web, 'build/cache/story-coop.html');
    if (!argv.includes('--no-build') || !fs.existsSync(coopPage)) {
      execFileSync(process.execPath, [path.join(here, 'build.mjs'), '--out', coopPage], { stdio: 'inherit' });
    }
    const relay = await startRelay(0);
    const q = `relay=${encodeURIComponent(relay.url)}&seed=1029`;
    const host = await openPage(browser, `file://${coopPage}?${q}`, 'host');
    const client = await openPage(browser, `file://${coopPage}?${q}`, 'client');
    const pages = [host, client];
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    /** Polls fn in a page until it returns truthy, at most `seconds` of real time: the last value. */
    const until = async (p, fn, arg, seconds = 30) => {
      const end = Date.now() + seconds * 1000;
      for (;;) {
        const v = await p.G(fn, arg);
        if (v || Date.now() > end) return v;
        await sleep(150);
      }
    };
    try {
      for (const [p, name] of [[host, 'Ana'], [client, 'Bo']]) {
        await p.G((g, dev, n) => {
          window.__rovloc.engine.skipRender = true;
          g.env.setSetting('TutorialDone', true);
          g.env.setSetting('NameAsked', true);
          g.env.setSetting('PlayerName', n);
          window.__subs = [];
          const show = g.cinematics.subtitles.show.bind(g.cinematics.subtitles);
          g.cinematics.subtitles.show = (line) => {
            window.__subs.push({ at: g.cinematics.time(), text: line.text });
            return show(line);
          };
        }, name);
      }
      await host.G((g) => {
        g.onboarding.friendsBtn.click();
        g.coop.ui.hostBtn.click();
      });
      const code = await until(host, (g) => (g.coop.active && g.coop.ui.codeText.textContent) || null, null, 20);
      await host.G((g) => g.coop.ui.enterBtn.click());
      await client.G((g, dev, c) => {
        g.onboarding.friendsBtn.click();
        g.coop.ui.codeInput.value = c.toLowerCase();
        g.coop.ui.joinBtn.click();
      }, code);
      const two = await until(host, (g) => g.coop.squad.list().length === 2 && g.coop.squad.list().every((m) => m.id), null, 30);
      // the client's own record arrives with the host's welcome, a moment after the host has counted it
      const bo = await until(client, (g) => (g.coop.me && g.coop.me.name) || null, null, 10);
      check('coop: a host and a client in one room (names from the title\'s prompt)', !!two && bo === 'Bo', bo);
      for (const p of pages) await p.G((g) => g.lobby.setReady(true));
      const playing = [];
      for (const p of pages) {
        playing.push(await until(p, (g) => (g.cinematics.current ? { cut: g.cinematics.current.cut, cast: g.cinematics.current.cast,
          slot: g.prologue.slot, phase: g.phase } : null), null, 60));
      }
      check('coop: one Opening on both pages, one cut and one cast (the seeded order of the two slots)', playing.every((x) => x &&
        x.cut === 'Full' && x.phase === 'Prologue') && JSON.stringify(playing[0].cast.map((c) => c.slot)) ===
        JSON.stringify(playing[1].cast.map((c) => c.slot)), playing);
      check('coop: a bin per slot (host Dumpster A, client the skip)', playing[0] && playing[0].slot === 1 && playing[1] &&
        playing[1].slot === 2, playing.map((x) => x && x.slot));
      // two pages within one tick: each page's timeline time against the host's, read together (the read's own skew
      // measured on the wall clock and taken off)
      let worst = null;
      for (let i = 0; i < 4; i++) {
        await sleep(1200);
        const reads = await Promise.all(pages.map((p) => p.tab.evaluate(() => ({ t: window.__rovlocGame.game.cinematics.time(),
          wall: performance.timeOrigin + performance.now() }))));
        const off = Math.abs((reads[1].t - reads[0].t) - (reads[1].wall - reads[0].wall) / 1000);
        worst = worst === null ? off : Math.max(worst, off);
      }
      check(`coop: two pages within one tick (worst ${(worst * 1000).toFixed(1)} ms of timeline apart)`, worst !== null && worst <= TICK + 0.02, worst);
      // the vote: one of two holds; the host's veto as a first-timer is lifted only by their own vote
      await until(client, (g) => g.cinematics.time() > 5.2, null, 20);
      await client.G((g) => g.cinematics.skip.vote());
      const one = await until(host, (g) => (g.cinematics.skip.votes.size === 1 ? { votes: g.cinematics.skip.votes.size,
        skipping: !!g.cinematics.current.skipping } : null), null, 10);
      check('coop: one vote of two does not pass', !!one && !one.skipping, one);
      await host.G((g) => g.cinematics.skip.vote());
      const passed = await until(client, (g) => (g.cinematics.current && g.cinematics.current.skipping) || g.cinematics.time() >= 59, null, 10);
      check('coop: both vote, the cut to the last shot on both pages', !!passed);
      const last = [];
      for (const p of pages) last.push(await until(p, (g) => (g.prologue.state === 'Bin' && !g.cinematics.active() ? true : null), null, 20));
      check('coop: the hand-over on both pages, each in its own bin', last.every(Boolean));
      const you = [];
      for (const p of pages) you.push(await p.G(() => window.__subs.filter((s) => /…$/.test(s.text)).map((s) => s.text)));
      check('coop: each page its own {you} (Ana… on the host, Bo… on the client)', you[0].includes('Ana…') && you[1].includes('Bo…'), you);
      // the chute: the host in, the client not; the cut 30 s after the first, the client placed in it
      await host.G((g) => g.prologue.climbOut());
      await until(host, (g) => g.prologue.state === 'Lot', null, 10);
      await host.G((g, dev, frame) => {
        g.env.teleport(frame);
        g.prologue.climbIn();
      }, AT_HATCH);
      const firstIn = await until(host, (g) => (g.prologue.firstIn !== null ? { at: g.prologue.firstIn, n: g.prologue.tally } : null), null, 10);
      check('coop: the host in the chute, the client not: 1 / 2', !!firstIn && firstIn.n && firstIn.n.n === 1 && firstIn.n.of === 2, firstIn);
      const hostAt29 = await until(host, (g, dev, at) => (g.env.now() >= at + 29 ? { cut: g.prologue.cutCalled } : null), firstIn.at, 60);
      check('coop: no cut before 30 s after the first in', !!hostAt29 && hostAt29.cut === false, hostAt29);
      const cut = await until(host, (g, dev, at) => (g.prologue.cutCalled ? { since: g.prologue.cutAt - at } : null), firstIn.at, 20);
      check('coop: the cut 30 s after the first in (the 30 s rule)', !!cut && Math.abs(cut.since - 30) <= 0.1, cut);
      const down = [];
      for (const p of pages) down.push(await until(p, (g) => (g.level === 'Level0_Basement' && g.phase === 'InRun' ? true : null), null, 20));
      check('coop: both pages in the Basement, InRun', down.every(Boolean));
      for (const p of pages) if (p.logs.length) check(`coop: ${p.name}: no console errors`, false, p.logs.slice(0, 4));
    } finally {
      for (const p of pages) await p.context.close();
      await relay.close();
    }
  }
} finally {
  if (browser) await browser.close();
}

console.log(`\nstory-test: ${checks - failures.length} / ${checks} checks pass`);
if (failures.length) {
  console.log(`FAILED:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
