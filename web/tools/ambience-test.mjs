// ambience-test.mjs: the building at night (src/game/ambience.js over meta.dreadConfig.Ambience; DreadConfig), on the
// baked world's numbers and teleport points, without a page:
//
//   * an hour on each dressed floor through the AmbienceDirector at the 30 Hz tick, the Creature far, within the duck
//     radius, chasing, then far again: no two events closer than MinGap; nothing at all while it chases; within the
//     radius every event at EventVolume x DuckVolume and the bed at BedVolume x DuckBed, and the events rarer there;
//     only the floor's own weighted presets;
//   * every event's place (placeEvent): a thump over the listener's floor, anything else on a tunnel centreline point
//     Distance studs away and out of the listener's sight (no clear line), or no event when none is;
//   * honest monster audio (I1): every preset is SynthPresets' own (meta), on the Ambience bus, captioned, built from
//     no voice sample, named as no NoiseKind; ambience.js never emits a noise pulse and never reads the graphics tier
//     (so every tier hears the same events at the same times), and two directors on the same seed decide the same;
//   * under a cutscene (held) nothing plays, nor for MinGap after it, and the bed dips to DuckBed.
// game  in the game (the game test page, unminified; a solo run, the Back Lot passed by the rules: tools/story-pass.mjs),
//       the building at night belongs to the school's floors in play (docs/design/game-spec-v2.md 2.4, 4.1; I13):
//   * the title: the name prompt opens on PLAY and keeps the keys while the camera drifts through the lobby's boiler
//     room (the kit's lightly dressed way in); no director, no bed, no ambient sound or caption before a run;
//   * the opening (Full, watched through) and the prologue on the Back Lot, by day and at night: no director, no bed,
//     no ambient event; every camera of it outside the dressed floors, so the haze and the torch's dust stay as they
//     are (scale 1) and the day reads as the cutscene sets it; the cutscene's sound captions shown over its black,
//     above its subtitles, never overlapping them;
//   * the Basement from the chute: the director and the bed start there, the haze and the dust thicken there;
//   * a subtitle and an ambient caption in play share the screen without overlapping (960 x 540 and 1920 x 1080);
//   * a cutscene played on the Basement holds the building still (no event though one was due, the bed dipped) and
//     nothing plays for MinGap after its end.
//
//   node tools/ambience-test.mjs [--world build/world.json] [--no-game] [--no-build] [--html <page>]
// Exit code 1 on any failure.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as THREE from 'three';

import { passPrologue } from './story-pass.mjs';
import { AmbienceDirector, placeEvent } from '../src/game/ambience.js';
import { seededRandom } from '../src/game/util.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.resolve(here, '..');
const argv = process.argv.slice(2);
const at = argv.indexOf('--world');
const worldPath = at >= 0 ? path.resolve(argv[at + 1]) : path.join(web, 'build/world.json');
const meta = JSON.parse(fs.readFileSync(worldPath, 'utf8'));

let failures = 0;
let checks = 0;
function check(ok, message, detail) {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL ${message}${detail !== undefined ? ` ${JSON.stringify(detail)}` : ''}`);
  }
  return ok;
}

const dread = meta.dreadConfig;
check(!!dread && !!dread.Ambience, 'meta.dreadConfig.Ambience is exported');
const config = dread.Ambience;
const presets = config.Presets || {};
const noiseKinds = new Set(Object.keys((meta.noiseConfig && meta.noiseConfig.Kinds) || {}));
check(noiseKinds.size > 10, `the NoiseKinds are known (${noiseKinds.size})`);
const VOICES = new Set(['Ouch', 'Oof']); // the throat and voice samples the Creature's own sounds are made of

console.log('== presets');
const names = new Set([...Object.values(config.Beds), ...config.Events.map((e) => e.preset)]);
for (const name of names) {
  const p = presets[name];
  check(!!p, `${name}: a SynthPresets recipe in meta`);
  if (!p) continue;
  check(p.bus === 'Ambience', `${name}: on the Ambience bus`);
  check(!noiseKinds.has(name), `${name}: not a NoiseKind`);
  check(p.layers.every((l) => !VOICES.has(l.sample)), `${name}: no voice sample`);
  if (!Object.values(config.Beds).includes(name)) check(!!p.caption && !!p.captionText, `${name}: captioned (${p.captionText})`);
}
console.log(`  ${names.size} presets`);

console.log('== the source');
const source = fs.readFileSync(path.join(web, 'src/game/ambience.js'), 'utf8');
check(!/emitNoise|\.noise\(|noise\.emit/.test(source), 'ambience.js emits no noise pulse');
check(!/quality|tier|budget/i.test(source.replace(/\/\/.*$/gm, '')), 'ambience.js reads nothing of the graphics tier');

console.log('== an hour per floor');
const TICK = 1 / 30;
const PHASES = [
  { until: 900, distance: Infinity, chasing: false, name: 'far' },
  { until: 1800, distance: 40, chasing: false, name: 'near' },
  { until: 2400, distance: 12, chasing: true, name: 'chase' },
  { until: 3600, distance: Infinity, chasing: false, name: 'far again' },
];
for (const level of Object.keys(config.Beds)) {
  const points = (meta.teleportPoints && meta.teleportPoints[level]) || [];
  check(points.length > 100, `${level}: ${points.length} tunnel points to place events on`);
  const floorY = meta.worldConfig && meta.worldConfig.Levels && meta.worldConfig.Levels[level] ? meta.worldConfig.Levels[level].elevation : 0;
  const listener = new THREE.Vector3(points[0].pos[0], floorY + 4.6, points[0].pos[2]);
  const run = (seed) => {
    const director = new AmbienceDirector(config, level, seed);
    const placeRandom = seededRandom(seed, 'place');
    const phaseOf = (t) => PHASES.find((p) => t < p.until) || PHASES[PHASES.length - 1];
    const events = [];
    for (let t = 0; t < 3600; t += TICK) {
      const ph = phaseOf(t);
      // half the candidate points are "in sight" (a clear line), by a hash of the point
      const event = director.step(t, ph.distance, ph.chasing, (preset) =>
        placeEvent(preset, config, points, listener, floorY, placeRandom, (a, b) => Math.sin(b.x * 12.9898 + b.z * 78.233) > 0));
      if (event) events.push({ ...event, phase: ph.name, bed: director.bedVolume(ph.distance, ph.chasing) });
    }
    return events;
  };
  const events = run(1029);
  const again = run(1029);
  check(JSON.stringify(events) === JSON.stringify(again), `${level}: the same seed decides the same events`);
  check(events.length >= 20, `${level}: ${events.length} events in the hour`);
  let minGap = Infinity;
  for (let i = 1; i < events.length; i++) minGap = Math.min(minGap, events[i].at - events[i - 1].at);
  check(minGap >= config.MinGap, `${level}: events at least ${config.MinGap} s apart (closest ${minGap.toFixed(1)} s)`);
  check(!events.some((e) => e.phase === 'chase'), `${level}: nothing while it chases`);
  const weights = new Set(config.Events.filter((e) => (e[level] || 0) > 0).map((e) => e.preset));
  check(events.every((e) => weights.has(e.preset)), `${level}: only the floor's own events`);
  const near = events.filter((e) => e.phase === 'near');
  const far = events.filter((e) => e.phase === 'far' || e.phase === 'far again');
  check(near.every((e) => Math.abs(e.volume - config.EventVolume * config.DuckVolume) < 1e-9 && e.ducked), `${level}: near it, every event ducked to ${config.DuckVolume}`);
  check(far.every((e) => Math.abs(e.volume - config.EventVolume) < 1e-9 && !e.ducked), `${level}: far from it, every event at full volume`);
  const rate = (list, seconds) => list.length / seconds;
  check(rate(near, 900) < rate(far, 2100) * 0.75, `${level}: rarer near it (${near.length} in 15 min, ${far.length} in 35 min far)`);
  check(near.every((e) => Math.abs(e.bed - config.BedVolume * config.DuckBed) < 1e-9), `${level}: the bed dips near it`);
  for (const e of events) {
    const d = Math.hypot(e.position.x - listener.x, e.position.z - listener.z);
    if (e.preset === 'DreadThumpAbove') {
      check(e.position.y >= floorY + config.Above, `${level}: the thump comes from the floor above (${e.position.y.toFixed(1)})`);
    } else {
      check(d >= config.Distance[0] - 1e-6 && d <= config.Distance[1] + 1e-6, `${level}: ${e.preset} ${d.toFixed(1)} studs away`);
      check(!(Math.sin(e.position.x * 12.9898 + e.position.z * 78.233) > 0), `${level}: ${e.preset} out of sight`);
    }
  }
  const counts = {};
  for (const e of events) counts[e.preset] = (counts[e.preset] || 0) + 1;
  console.log(`  ${level}: ${events.length} events (closest ${minGap.toFixed(1)} s apart; ${near.length} near it, ${far.length} far): ${Object.entries(counts).map(([k, v]) => `${k} ${v}`).join(', ')}`);
  // with every point in sight there is nowhere to put an event: none plays
  const blind = new AmbienceDirector(config, level, 7);
  let placed = 0;
  for (let t = 0; t < 900; t += 1) {
    const e = blind.step(t, Infinity, false, (preset) => placeEvent(preset, config, points, listener, floorY, blind.random, () => true));
    if (e && e.preset !== 'DreadThumpAbove') placed++;
  }
  check(placed === 0, `${level}: no event in plain sight`);
  // under a cutscene (held) the building holds still: no event while it plays nor for MinGap after it, the bed dipped
  const HELD = [600, 700];
  const quiet = new AmbienceDirector(config, level, 1029);
  const heard = [];
  let heldBed = true;
  let lastHeld = -Infinity;
  for (let t = 0; t < 1200; t += TICK) {
    const held = t >= HELD[0] && t < HELD[1];
    if (held) {
      lastHeld = t;
      heldBed = heldBed && Math.abs(quiet.bedVolume(Infinity, false, true) - config.BedVolume * config.DuckBed) < 1e-9;
    }
    const e = quiet.step(t, Infinity, false, (preset) => placeEvent(preset, config, points, listener, floorY, quiet.random,
      (a, b) => Math.sin(b.x * 12.9898 + b.z * 78.233) > 0), held);
    if (e) heard.push(e.at);
  }
  const under = heard.filter((at) => at >= HELD[0] && at < lastHeld + config.MinGap - 1e-6);
  check(under.length === 0 && heard.some((at) => at < HELD[0]) && heard.some((at) => at >= HELD[1] + config.MinGap),
    `${level}: a cutscene holds the building still, and ${config.MinGap} s after it (${under.length} under it; ${heard.length} in 20 min)`);
  check(heldBed, `${level}: under a cutscene the bed dips to ${config.DuckBed}`);
}

// ------------------------------------------------------------------------------------------------ the game
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

/** What the page shows of the building at night and the screen's bottom, read in the page (no arguments). */
function readAir() {
  const g = window.__rovlocGame.game;
  const e = window.__rovloc.engine;
  const ui = e.ui;
  const rect = (el) => {
    const r = el.getBoundingClientRect();
    return { top: r.top, bottom: r.bottom, left: r.left, right: r.right };
  };
  const subs = g.cinematics.subtitles.lines.filter((l) => Number(l.el.style.opacity) > 0.05).map((l) => rect(l.el));
  const caps = ui.captions.map((c) => rect(c.el));
  const overlap = subs.some((a) => caps.some((b) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom));
  const cin = g.cinematics.current;
  return { phase: g.phase, stage: g.stage, level: g.level, cutscene: g.cinematics.active(), t: g.cinematics.time(),
    cut: cin ? cin.cut : null, prologue: g.prologue.state, cameraLevel: e.cameraLevel, haze: e.lighting.haze,
    motes: e.particles.moteUniforms.uMoteGain.value, day: e.renderer.dayAmount, director: !!g.ambience.director,
    directorLevel: g.ambience.director ? g.ambience.director.level : null, bed: !!g.ambience.bed, held: g.ambience.held(),
    subs: subs.length, caps: caps.length, overlap, capsOpacity: Number(ui.captionsEl.style.opacity),
    capsZ: ui.captionsEl.style.zIndex, capsAbove: subs.length && caps.length ? Math.max(...caps.map((c) => c.bottom)) <=
      Math.min(...subs.map((r) => r.top)) + 0.5 : null };
}

async function gameCase() {
  console.log('== the game: the title, the Back Lot, the Basement');
  const dressed = new Set([...Object.keys(config.Beds), ...Object.keys(dread.Air.HazeScale), ...Object.keys(dread.Air.MoteGain)]);
  const hi = argv.indexOf('--html');
  let page = hi >= 0 ? path.resolve(argv[hi + 1]) : path.join(web, 'build/cache/ambience-test.html');
  if (hi < 0 && (!argv.includes('--no-build') || !fs.existsSync(page))) {
    execFileSync(process.execPath, [path.join(here, 'game-build.mjs'), '--out', page, '--no-minify'], { stdio: 'inherit' });
  }
  const browser = await loadPlaywright().chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader',
    '--ignore-gpu-blocklist', '--autoplay-policy=no-user-gesture-required', '--enable-webgl'] });
  try {
    const context = await browser.newContext({ bypassCSP: true, viewport: { width: 960, height: 540 } });
    const tab = await context.newPage();
    const logs = [];
    await tab.addInitScript(() => {
      Element.prototype.requestPointerLock = function requestPointerLock() {
        return Promise.resolve();
      };
    });
    tab.on('pageerror', (e) => logs.push(`pageerror: ${e.message}`));
    tab.on('console', (m) => {
      if (m.type() === 'error' && !IGNORED_CONSOLE.test(m.text())) logs.push(m.text());
    });
    await tab.goto(`file://${page}?dev&seed=1029`);
    await tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 240000 });
    const G = (fn, arg) => tab.evaluate(([src, a]) => {
      const w = window.__rovlocGame;
      // eslint-disable-next-line no-new-func
      return new Function('game', 'dev', 'arg', `return (${src})(game, dev, arg);`)(w.game, w.dev, a);
    }, [fn.toString(), arg]);
    const ff = (seconds) => tab.evaluate((sec) => {
      const e = window.__rovloc.engine;
      e.loop.stop();
      const render = e.renderer.render;
      e.renderer.render = () => {};
      try {
        for (let i = 0; i < Math.round(sec * 30); i++) e.loop._run(1 / 30, 1 / 30);
      } finally {
        e.renderer.render = render;
      }
    }, seconds);
    const air = () => tab.evaluate(`(${readAir.toString()})()`);
    check(!(await tab.evaluate(() => window.__rovloc.error)), 'the game page boots');

    // every ambient sound and caption the page plays, with the moment's phase and cutscene
    await G((g) => {
      window.__dread = [];
      const play = g.env.play.bind(g.env);
      g.env.play = (preset, opts) => {
        if (/^Dread/.test(preset)) {
          window.__dread.push({ preset, at: g.env.now(), phase: g.phase, stage: g.stage, cutscene: g.cinematics.active(),
            prologue: g.prologue.state });
        }
        return play(preset, opts);
      };
      g.env.setSetting('Captions', true);
    });

    // the title: PLAY opens the name prompt; it keeps the keys while the title drifts through the boiler room
    let s = await G((g) => {
      const o = g.onboarding;
      const title = o.mode;
      o.playBtn.click();
      return { title, open: o.namePrompt.isOpen() };
    });
    check(s.title === 'Title' && s.open, 'the title: PLAY opens the name prompt', s);
    await ff(3);
    await tab.keyboard.type('Bo');
    s = await G((g) => {
      const p = g.onboarding.namePrompt;
      return { open: p.isOpen(), focused: document.activeElement === p.input, value: p.input.value, preview: p.preview.textContent,
        camera: window.__rovloc.engine.cameraLevel, director: !!g.ambience.director, bed: !!g.ambience.bed, dread: window.__dread.length,
        captions: window.__rovloc.engine.ui.captions.length };
    });
    check(s.open && s.focused && s.value === 'Bo' && s.camera === 'Lobby',
      'the name prompt keeps the focus and the keys over the title\'s drift through the lobby\'s boiler room', s);
    check(!s.director && !s.bed && s.dread === 0 && s.captions === 0, 'before a run: no director, no bed, no ambient sound or caption', s);
    await G((g) => {
      const p = g.onboarding.namePrompt;
      p.okBtn.click();
      g.env.setSetting('TutorialDone', true);
      g.onboarding.closeForCoop();
    });
    await G((g, dev) => {
      dev.deploy('Standard'); // its promise settles on the game's own steps (ff below)
    });
    await ff(0.6);
    for (let i = 0; i < 150 && !(await G((g) => g.cinematics.active())); i++) await ff(1 / 30);

    // the opening, watched through: the Back Lot by day, then at night
    const samples = [];
    for (let i = 0; i < 400; i++) {
      s = await air();
      if (!s.cutscene) break;
      samples.push(s);
      await ff(0.5);
    }
    const first = samples[0] || {};
    check(first.phase === 'Prologue' && first.stage === 'BackLot' && first.cut === 'Full' && samples.length >= 150,
      `the deploy opens on the Back Lot with the Full opening (${samples.length} samples of it)`, first);
    const lit = samples.filter((x) => x.director || x.bed || x.held !== true);
    check(lit.length === 0, 'the opening: no director and no bed on the Back Lot; the building would hold still under it', lit[0]);
    const dressedCam = samples.filter((x) => dressed.has(x.cameraLevel) || Math.abs(x.haze - 1) > 1e-9 || Math.abs(x.motes - 1) > 1e-9);
    check(dressedCam.length === 0, 'every camera of the opening outside the dressed floors: the haze and the dust at scale 1', dressedCam[0]);
    const day = samples.filter((x) => x.t <= 60).map((x) => x.day);
    const night = samples.filter((x) => x.t >= 74).map((x) => x.day);
    check(day.length > 0 && Math.min(...day) > 0.5 && night.length > 0 && Math.max(...night) === 0,
      `the day reads as the opening sets it: daylight to 60 s (least ${Math.min(...day).toFixed(2)}), night from 74 s`);
    const both = samples.filter((x) => x.subs > 0 && x.caps > 0);
    check(both.length > 0 && both.every((x) => !x.overlap && x.capsAbove && x.capsOpacity === 1 && x.capsZ === '42'),
      `the opening's sound captions show over its black, above its subtitles (${both.length} moments with both)`,
      both.find((x) => x.overlap || !x.capsAbove || x.capsOpacity !== 1));

    const cams = [...new Set(samples.map((x) => x.cameraLevel))];
    console.log(`  the opening: ${samples.length} samples, camera levels ${cams.join(', ')}; ${both.length} moments with a caption ` +
      `and a subtitle up`);
    // the prologue at night, by the rules (tools/story-pass.mjs), into the Basement
    const lot = [await air()];
    s = await passPrologue(tab, G, ff);
    check(s.phase === 'InRun' && s.level === 'Level0_Basement', 'the prologue passed by the rules: InRun in the Basement', s);
    const early = await G(() => window.__dread);
    const before = early.filter((x) => x.stage !== 'Level0_Basement' || x.phase !== 'InRun' || x.cutscene || x.prologue !== null);
    check(before.length === 0 && early.some((x) => x.preset === config.Beds.Level0_Basement),
      'no ambient sound before the Basement (the title, the opening, the prologue); its bed starts there', early.slice(0, 3));
    check(lot.every((x) => x.prologue === 'Bin' && x.day === 0 && !x.director && !x.bed && Math.abs(x.haze - 1) < 1e-9),
      'the prologue on the lot at night: no director, no bed, the haze at scale 1', lot);
    await ff(3);
    s = await air();
    check(s.director && s.directorLevel === 'Level0_Basement' && s.bed && !s.held, 'the Basement: the director and the bed start', s);
    check(Math.abs(s.haze - dreadHaze('Level0_Basement')) < 0.01 && Math.abs(s.motes - dreadMotes('Level0_Basement')) < 1e-9,
      `the Basement: the haze at ${dreadHaze('Level0_Basement')}, the dust at ${dreadMotes('Level0_Basement')}`, s);

    // a subtitle and an ambient caption in play
    for (const [w, h] of [[960, 540], [1920, 1080]]) {
      await tab.setViewportSize({ width: w, height: h });
      await G((g) => {
        g.cinematics.subtitles.clear();
        g.cinematics.subtitles.show({ speaker: 'DANNY', struck: true, text: 'I know you\'re close.', ear: true, seconds: 4 });
        g.cinematics.subtitles.show({ speaker: 'DANNY', struck: true, text: 'Still here.', ear: true, seconds: 4 });
        g.env.caption('[a door slams somewhere far off]');
        g.env.caption('[metal groans in the walls]');
      });
      await ff(0.4);
      s = await air();
      check(s.subs === 2 && s.caps >= 2 && !s.overlap && s.capsAbove && s.capsOpacity === 1,
        `in play at ${w} x ${h}: two subtitles and two ambient captions, the captions above, none overlapping`, s);
      await G((g) => {
        g.cinematics.subtitles.clear();
        window.__rovloc.engine.ui.clearCaptions();
      });
    }
    await tab.setViewportSize({ width: 960, height: 540 });

    // a cutscene on the dressed floor: an event due under it, held; nothing for MinGap after its end
    s = await G((g) => {
      const a = g.ambience;
      window.__bedVolumes = [];
      const set = a.bed.setVolume.bind(a.bed);
      a.bed.setVolume = (v, sec) => {
        window.__bedVolumes.push({ v, cutscene: g.cinematics.active() });
        return set(v, sec);
      };
      a.director.nextAt = g.env.now() + 1;
      window.__dread = [];
      const logged = a.director.log.length;
      g.cinematics.play('Fall');
      const c = g.cinematics.current;
      return { logged, length: c ? c.length : 0, started: g.env.now() };
    });
    check(s.length > 2, `a cutscene (Fall, ${s.length} s) plays on the Basement`, s);
    await ff(s.length + 0.5);
    const under = await G((g, dev, logged) => ({ active: g.cinematics.active(), dread: window.__dread, log: g.ambience.director.log.length - logged,
      beds: window.__bedVolumes.filter((b) => b.cutscene).map((b) => b.v), endedAt: g.env.now() }), s.logged);
    check(!under.active && under.dread.length === 0 && under.log === 0, 'under the cutscene: no ambient event, though one was due', under);
    check(under.beds.length > 0 && under.beds.every((v) => Math.abs(v - config.BedVolume * config.DuckBed) < 1e-9),
      `under the cutscene the bed dips to ${config.DuckBed}`, under.beds.slice(0, 3));
    await ff(config.MinGap - 1.5);
    const after = await G(() => window.__dread);
    check(after.length === 0, `nothing for ${config.MinGap} s after the cutscene`, after);
    if (logs.length) check(false, 'the game page: no console errors', logs.slice(0, 5));
    await context.close();
  } finally {
    await browser.close();
  }
}

function dreadHaze(level) {
  return dread.Air.HazeScale[level] || 1;
}

function dreadMotes(level) {
  return dread.Air.MoteGain[level] || 1;
}

if (!argv.includes('--no-game')) await gameCase();

console.log(failures ? `${failures} of ${checks} checks failed` : `all ${checks} checks passed`);
process.exit(failures ? 1 : 0);
