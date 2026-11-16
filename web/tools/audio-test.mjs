// audio-test.mjs: the recorded sounds in the real game (docs/SOUND.md 12), headless Chromium on the game test page
// (tools/game-build.mjs: the page a player gets, the sound packs inline).
//
//   node tools/audio-test.mjs [--html <page>] [--no-build]
//
//   files     every shipped file decodes, as long as the build says and at its decode rate; every file is a preset's
//   names     every name the game can play (every preset registered once a run is deployed) has a file, or is on
//             OLD_PATH below (the names that still play their old recipe: none is ever silent); a name the game loops
//             has a loop or a pulse to loop
//   him       through the game's own engine (its buses, roll-off, room and master, rendered offline), every variant:
//             his quietest footstep is at least 10 dB over a player's loudest at the same distance (near, mid, and as
//             far as CreatureConfig.Footfalls says he is heard), and there it stands at least 6 dB over the Basement's
//             beds as the game plays them (the drone and the building's bed at its volume); out of sight (the view's
//             Reduced level of detail) he plants as many footfalls per stud walked at 10, 20 and 30 fps
//   scare     the jumpscare is the loudest file there is, and through the engine it stays under the peak limit and at
//             most 24 dB over the Basement's beds (a player who turns the quiet up is not hurt by it)
//   memory    the decoded samples stay under the bank's budget on every stage of a run, and what a stage needs at
//             once is decoded before its first frame
//   run       a run with the sound on (the opening, the prologue, the Basement with him hunting, the Hallways): his
//             steps are his own sounds, the played names come from files, and the console stays clean
//
// Exit code 1 on any failure.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { build } from 'esbuild';
import * as THREE from 'three';
import { integrated, momentaryMax } from '../sounds/kit/loudness.mjs';
import { Animator } from '../src/creature/animator.js';
import { CFrame } from '../src/creature/cframe.js';
import * as CreatureProfile from '../src/creature/profile.js';
import { buildJointMap } from '../src/creature/rig.js';
import { LodClock, stepAnimator } from '../src/creature/view.js';
import { CreatureFootfalls, CreatureStepSurface } from '../src/engine/audio/presets.js';
import { passBackLot } from './story-pass.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.resolve(here, '..');
const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};

/**
 * The names still on the old path: presets the game can play that have no recorded file, with why. Everything else
 * plays its recording.
 * @type {Record<string, string>}
 */
const OLD_PATH = {};

/** His footstep over a player's at the same distance, at least (dB). */
const OVER_PLAYER = 10;
/** His quietest footstep at CreatureConfig.Footfalls.HeardTo over the Basement's beds, at least (dB). */
const OVER_BED = 6;
/** The jumpscare's loudest 400 ms at the output over the Basement's beds, at most (dB). */
const SCARE_OVER_BEDS = 24;
/** The most the jumpscare may reach at the output, through the engine (dBFS). */
const PEAK_LIMIT = -1;
const SR = 48000;
const IGNORED_CONSOLE = /useProgram|Shader Error|WebGL|GPU stall/;

let page = opt('--html', null);
if (!page) {
  page = path.join(web, 'build/cache/audio-test.html');
  if (!argv.includes('--no-build') || !fs.existsSync(page)) {
    execFileSync(process.execPath, [path.join(here, 'game-build.mjs'), '--out', page, '--no-minify'], { stdio: 'inherit' });
  }
}

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

const failures = [];
function check(name, ok, detail) {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail !== undefined ? ` ${typeof detail === 'string' ? detail : JSON.stringify(detail)}` : ''}`);
  if (!ok) failures.push(name);
}
const fmt = (v) => (Number.isFinite(v) ? v.toFixed(1) : String(v));

const { chromium } = loadPlaywright();
const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader',
  '--ignore-gpu-blocklist', '--autoplay-policy=no-user-gesture-required', '--enable-webgl'] });
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
  if ((m.type() === 'error' || m.type() === 'warning') && !IGNORED_CONSOLE.test(m.text())) logs.push(`${m.type()}: ${m.text()}`);
});

/** Runs `fn(game, dev, arg)` in the page. */
const G = (fn, arg) => tab.evaluate(([src, a]) => {
  const w = window.__rovlocGame;
  // eslint-disable-next-line no-new-func
  return new Function('game', 'dev', 'arg', `return (${src})(game, dev, arg);`)(w.game, w.dev, a);
}, [fn.toString(), arg]);

/** Advances the game `seconds` at 30 Hz without rendering (SwiftShader is too slow to play in real time). */
const ff = (seconds) => tab.evaluate((s) => {
  const e = window.__rovloc.engine;
  e.loop.stop();
  const render = e.renderer.render;
  e.renderer.render = () => {};
  try {
    for (let i = 0; i < Math.round(s * 30); i++) e.loop._run(1 / 30, 1 / 30);
  } finally {
    e.renderer.render = render;
    e.loop.start();
  }
}, seconds);

/**
 * His footfalls per stud walked out of sight: the real animator on the baked rig, stepped by the view's own
 * level-of-detail clock in the Reduced tier (every third frame, LodClock) at `fps`, walking at `speed` studs/s in
 * `state` for `seconds` of game time.
 */
function footfallsPerStud(fps, state, speed, seconds) {
  const meta = JSON.parse(fs.readFileSync(path.join(web, 'build/world.json'), 'utf8'));
  const map = buildJointMap(meta.creature);
  const animator = new Animator(map, CreatureProfile.Profile, { seed: 8517 });
  let plants = 0;
  animator.footstep.connect(() => plants++);
  const clock = new LodClock();
  const root = new CFrame(0, -map.groundY, 0);
  const velocity = new THREE.Vector3(0, 0, -speed);
  // the loop clamps a frame to 0.1 s (MAX_FRAME_DT): at 10 fps and under the game itself runs at that pace
  const dt = Math.min(1 / fps, 0.1);
  let t = 0;
  for (let k = 0; k < Math.round(seconds / dt); k++) {
    t += dt;
    const step = clock.tick(dt, 'Reduced');
    if (step === null) continue;
    animator.setInputs({ moveState: state, velocity, grounded: true, lookYaw: 0, lookPitch: 0, time: t });
    stepAnimator(animator, step, root);
  }
  return plants / (speed * seconds);
}

/**
 * Renders voices through a copy of the game's audio engine on an OfflineAudioContext (the same buses, roll-off,
 * room chain and master, the game's own decoded files): `plays` are [name, {distance?, volume?, loop?, seed?}] (seed:
 * the variant), heard in
 * the acoustic environment `environment` for `seconds`. Returns the two output channels.
 */
async function renderInGame(plays, seconds, environment = 'Basement') {
  const b64 = await tab.evaluate(async ({ list, secs, env, rate }) => {
    const e = window.__rovloc.engine;
    await e.audio.bank.prepare(list.map((p) => p[0]));
    const ctx = new OfflineAudioContext(2, Math.ceil(secs * rate), rate);
    const audio = new e.audio.constructor({ settings: e.settings, context: ctx, bank: e.audio.bank });
    audio.setEnvironment(env, 0);
    for (const [name, o] of list) {
      const opts = { volume: o.volume ?? 1 };
      if (o.loop) opts.loop = true;
      if (o.seed !== undefined) opts.seed = o.seed;
      if (o.distance !== undefined) opts.position = new e.THREE.Vector3(0, 0, -o.distance);
      // a placed sound past its roll-off is culled (silent); anything else must play
      if (!audio.play(name, opts) && o.distance === undefined) throw new Error(`${name} did not play`);
    }
    const buf = await ctx.startRendering();
    const out = new Float32Array(buf.length * 2);
    out.set(buf.getChannelData(0), 0);
    out.set(buf.getChannelData(1), buf.length);
    let s = '';
    const bytes = new Uint8Array(out.buffer);
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(s);
  }, { list: plays, secs: seconds, env: environment, rate: SR });
  const bytes = Buffer.from(b64, 'base64');
  const all = new Float32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 4);
  const n = all.length / 2;
  return [Float32Array.from(all.subarray(0, n)), Float32Array.from(all.subarray(n))];
}

try {
  await tab.goto(`file://${page}?dev&seed=1029`);
  await tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 240000 });
  check('the game page boots', !(await tab.evaluate(() => window.__rovloc.error)), await tab.evaluate(() => window.__rovloc.error));
  // the kit's loudness meter in the page (the audit's own: ITU BS.1770), for measuring the decoded files there
  const meter = await build({ entryPoints: [path.join(web, 'sounds/kit/loudness.mjs')], bundle: true, format: 'iife', globalName: 'RvLoudness', write: false, logLevel: 'silent' });
  await tab.addScriptTag({ content: meter.outputFiles[0].text });

  // ------------------------------------------------------------------------------------------------ memory at boot
  console.log('== the first set');
  const boot = await tab.evaluate(() => {
    const bank = window.__rovloc.engine.audio.bank;
    const first = bank.names().filter((n) => bank.sounds[n].f);
    return { names: bank.names().length, first: first.length, decodedFirst: first.filter((n) => bank.decoded.has(n)).length,
      bytes: bank.decodedBytes, state: window.__rovloc.engine.audio.ctx.state, rate: window.__rovloc.engine.audio.ctx.sampleRate };
  });
  check('the page carries the sound bank and the audio context runs', boot.names > 0 && boot.state === 'running', boot);
  check(`what every stage needs at once (${boot.first} sounds) was decoded before the first frame`, boot.first > 0 && boot.decodedFirst === boot.first,
    `${(boot.bytes / 1048576).toFixed(1)} MB of samples`);

  // ------------------------------------------------------------------------------------------------ files
  console.log('== the files');
  const files = await tab.evaluate(async () => {
    const e = window.__rovloc.engine;
    const bank = e.audio.bank;
    const out = { count: 0, bad: [], loudness: {}, peak: {}, seconds: 0 };
    for (const name of bank.names()) {
      const entry = bank.sounds[name];
      const buffers = await bank.load(name);
      if (!buffers || buffers.length !== entry.v.length) {
        out.bad.push(`${name}: not decoded`);
        continue;
      }
      let loudest = -Infinity;
      let peak = -Infinity;
      buffers.forEach((b, k) => {
        out.count++;
        out.seconds += b.duration;
        const want = Math.min(entry.r, e.audio.ctx.sampleRate);
        if (b.sampleRate !== want) out.bad.push(`${name} #${k + 1}: decoded at ${b.sampleRate} Hz, not ${want}`);
        if (b.numberOfChannels !== entry.c) out.bad.push(`${name} #${k + 1}: ${b.numberOfChannels} channels, not ${entry.c}`);
        if (Math.abs(b.duration - entry.v[k][2]) > 0.05) out.bad.push(`${name} #${k + 1}: ${b.duration.toFixed(3)} s, the build says ${entry.v[k][2]}`);
        const channels = [];
        for (let c = 0; c < b.numberOfChannels; c++) channels.push(b.getChannelData(c));
        loudest = Math.max(loudest, entry.l ? window.RvLoudness.integrated(channels, b.sampleRate) : window.RvLoudness.momentaryMax(channels, b.sampleRate));
        peak = Math.max(peak, window.RvLoudness.truePeak(channels));
      });
      out.loudness[name] = loudest;
      out.peak[name] = peak;
    }
    out.failed = [...bank.failed];
    return out;
  });
  check(`every shipped file decodes (${files.count} files, ${files.seconds.toFixed(0)} s of sound)`, files.count > 0 && !files.bad.length && !files.failed.length,
    files.bad.length || files.failed.length ? [...files.bad, ...files.failed].slice(0, 8) : undefined);

  // ------------------------------------------------------------------------------------------------ a run, for the names
  console.log('== a run with the sound on');
  await G((g, dev) => {
    // every play of the run: the name, whether its file played, and the level
    window.__played = [];
    const audio = window.__rovloc.engine.audio;
    const play = audio.play.bind(audio);
    audio.play = (name, opts) => {
      const voice = play(name, opts);
      window.__played.push({ name, file: !!(voice && voice.file), played: !!voice, level: g.level, loop: !!(voice && voice.looped),
        pulse: !!(voice && voice.preset.repeat) });
      return voice;
    };
    dev.skipTitle();
  });
  await ff(1);
  const stages = [];
  const memory = async (stage) => {
    const m = await tab.evaluate(() => {
      const bank = window.__rovloc.engine.audio.bank;
      const first = bank.names().filter((n) => bank.sounds[n].f);
      return { bytes: bank.decodedBytes, peak: bank.peakBytes, first: first.every((n) => bank.decoded.has(n)), pending: bank.pending.size };
    });
    stages.push({ stage, ...m });
  };
  await memory('Lobby');
  await G((g, dev) => dev.deploy('Standard'));
  await ff(2);
  let at = await G((g) => ({ phase: g.phase, stage: g.stage }));
  check('deployed onto the Back Lot (the opening)', at.stage === 'BackLot', at);
  await ff(20);
  await memory('BackLot (the opening)');
  at = await passBackLot(tab, G, ff);
  check('the opening and the prologue pass: the Basement', at.level === 'Level0_Basement', at);
  await memory('Level0_Basement (first frame)');
  // the Basement: walk, with him set on the player, long enough for him to come and chase
  await G((g) => {
    g.env.setFlashlight(true);
    g.creature.devCommand('hunt');
  });
  await tab.keyboard.down('KeyW');
  for (let i = 0; i < 6; i++) {
    await ff(10);
    // real time passes too, so the audio context plays what the game asked for
    await tab.waitForTimeout(400);
  }
  await tab.keyboard.up('KeyW');
  await memory('Level0_Basement');
  await G((g, dev) => dev.gotoLevel('Level1_Hallways'));
  await ff(1);
  await memory('Level1_Hallways (first frame)');
  await G((g) => g.creature.devCommand('hunt'));
  for (let i = 0; i < 4; i++) {
    await ff(10);
    await tab.waitForTimeout(400);
  }
  await memory('Level1_Hallways');
  for (const level of ['Level2_Auditorium', 'Level3_Roof']) {
    const there = await G((g, dev, l) => dev.gotoLevel(l), level);
    if (!there) continue;
    await ff(8);
    await tab.waitForTimeout(400);
    await memory(level);
  }
  const played = await tab.evaluate(() => window.__played);
  const playedNames = [...new Set(played.map((p) => p.name))].sort();
  // a footfall past its roll-off or over the Monster bus's voice cap is culled (nothing plays); every one that plays
  // is his own file
  const steps = played.filter((p) => /^CreatureStep/.test(p.name));
  const heard = steps.filter((p) => p.played);
  const playersAsHim = await G((g) => window.__played.filter((p) => /^Footstep/.test(p.name)).length);
  check(`he walked on his own sounds (${steps.length} footfalls, ${heard.length} in earshot: ${[...new Set(steps.map((p) => p.name))].join(', ')})`,
    heard.length > 10 && heard.every((p) => p.file), { players: playersAsHim });
  const expectedSteps = new Set(Object.values(CreatureStepSurface).flatMap((c) => [`CreatureStepWalk${c}`, `CreatureStepChase${c}`]));
  check('every footstep of his is one of his five surfaces\' own', steps.every((p) => expectedSteps.has(p.name)));

  // ------------------------------------------------------------------------------------------------ names
  console.log('== the names');
  const names = await tab.evaluate(() => {
    const audio = window.__rovloc.engine.audio;
    const bank = audio.bank;
    return { presets: audio.presetNames, recipe: audio.recipeNames, bank: bank.names() };
  });
  const orphan = names.bank.filter((n) => !names.presets.includes(n));
  check(`every file is a preset's (${names.bank.length} sounds in the bank, ${names.presets.length} presets)`, !orphan.length, orphan);
  const unexpected = names.recipe.filter((n) => !Object.hasOwn(OLD_PATH, n));
  const stale = Object.keys(OLD_PATH).filter((n) => !names.recipe.includes(n));
  check(`every name the game can play has a file or is on the old-path list (${names.presets.length - names.recipe.length} play files, ${names.recipe.length} their old recipe)`,
    !unexpected.length && !stale.length, { withoutFile: unexpected, listedButHasFile: stale });
  const recipePlayed = playedNames.filter((n) => played.some((p) => p.name === n && p.played && !p.file) && !Object.hasOwn(OLD_PATH, n));
  check(`what the run played came from files (${playedNames.length} names played)`, !recipePlayed.length, recipePlayed);
  // each looped play is judged as it was played (its preset read then): a pulse voice the panic level has since
  // stopped (Heartbeat, Breathing) or the torch has put away (EmfStatic) was no less a pulse
  const loops = await tab.evaluate((list) => {
    const bank = window.__rovloc.engine.audio.bank;
    return [...new Set(list.filter((p) => { const entry = bank.entry(p.name); return entry && !entry.l && !p.pulse; }).map((p) => p.name))];
  }, played.filter((p) => p.loop && p.file));
  check('every file the game loops is a loop, or a pulse its preset repeats', !loops.length, loops);

  // ------------------------------------------------------------------------------------------------ him
  console.log('== his footsteps against a player\'s, and the Basement\'s beds');
  const distances = [10, 30, CreatureFootfalls.HeardTo];
  const variantsOf = (name) => tab.evaluate((n) => window.__rovloc.engine.audio.bank.sounds[n].v.length, name);
  /** The loudest 400 ms of each variant of `name` at `distance` through the engine (LUFS; -Infinity: culled). */
  const levels = async (name, distance) => {
    const out = [];
    for (let seed = 0, n = await variantsOf(name); seed < n; seed++) out.push(momentaryMax(await renderInGame([[name, { distance, seed }]], 2.5), SR));
    return out;
  };
  let worst = Infinity;
  const rows = [];
  for (const [his, theirs] of [['CreatureStepWalkConcrete', 'FootstepConcrete'], ['CreatureStepChaseConcrete', 'FootstepSprintConcrete'],
    ['CreatureStepWalkTile', 'FootstepTile'], ['CreatureStepChaseWood', 'FootstepSprintWood']]) {
    const cells = [];
    for (const d of distances) {
      // his quietest variant against the player's loudest
      const a = Math.min(...await levels(his, d));
      const b = Math.max(...await levels(theirs, d));
      worst = Math.min(worst, a - b);
      cells.push(`${d} studs ${fmt(a)} vs ${fmt(b)}`);
    }
    rows.push(`${his} / ${theirs}: ${cells.join('; ')}`);
  }
  for (const r of rows) console.log(`     ${r}`);
  check(`his quietest footstep is at least ${OVER_PLAYER} dB over a player's loudest at the same distance (LUFS through the game's engine, every variant)`,
    worst >= OVER_PLAYER, `the least: ${fmt(worst)} dB`);
  const bedVolume = await G((g) => g.world.meta.dreadConfig.Ambience.BedVolume);
  const beds = await renderInGame([['DroneBasement', { loop: true }], ['DreadBedBasement', { loop: true, volume: bedVolume }]], 14);
  const bedLoudness = integrated(beds.map((c) => c.subarray(2 * SR)), SR);
  let quietest = Infinity;
  const far = [];
  for (const c of new Set(Object.values(CreatureStepSurface))) {
    const all = await levels(`CreatureStepWalk${c}`, CreatureFootfalls.HeardTo);
    quietest = Math.min(quietest, ...all);
    far.push(`${c} ${all.map(fmt).join('/')}`);
  }
  check(`at ${CreatureFootfalls.HeardTo} studs (as far as the config says he is heard) his quietest footstep stands at least ${OVER_BED} dB over the Basement's beds (every variant)`,
    quietest >= bedLoudness + OVER_BED, `${fmt(quietest)} LUFS over ${fmt(bedLoudness)} LUFS (+${fmt(quietest - bedLoudness)} dB; the drone and the building's bed at ${bedVolume}); ${far.join(', ')}`);
  const pace = [10, 20, 30].map((fps) => ({ fps, walk: footfallsPerStud(fps, 'Patrol', 7, 12), chase: footfallsPerStud(fps, 'Chase', 16.5, 12) }));
  const spread = (key) => Math.max(...pace.map((p) => p[key])) / Math.min(...pace.map((p) => p[key])) - 1;
  check('out of sight he plants as many footfalls per stud walked at 10, 20 and 30 fps (the view\'s level-of-detail clock)',
    pace.every((p) => p.walk > 0 && p.chase > 0) && spread('walk') <= 0.05 && spread('chase') <= 0.05,
    pace.map((p) => `${p.fps} fps: ${p.walk.toFixed(3)} walking, ${p.chase.toFixed(3)} chasing`).join('; '));

  // ------------------------------------------------------------------------------------------------ the scare
  console.log('== the jumpscare');
  const ranked = Object.entries(files.loudness).sort((a, b) => b[1] - a[1]);
  check('the jumpscare is the loudest file there is', ranked.length > 0 && ranked[0][0] === 'JumpscareSting',
    ranked.slice(0, 4).map(([n, l]) => `${n} ${fmt(l)} LUFS`).join(', '));
  if (Object.hasOwn(files.loudness, 'JumpscareSting')) {
    const out = await renderInGame([['JumpscareSting', {}]], 4);
    let peak = 0;
    for (const c of out) for (const v of c) peak = Math.max(peak, Math.abs(v));
    const peakDb = 20 * Math.log10(peak);
    const loudest = momentaryMax(out, SR);
    check(`through the engine the jumpscare peaks under ${PEAK_LIMIT} dBFS (never painful on earbuds)`, peakDb <= PEAK_LIMIT,
      `${fmt(peakDb)} dBFS at the output, ${fmt(loudest)} LUFS; the file ${fmt(files.peak.JumpscareSting)} dBTP`);
    check(`through the engine the jumpscare's loudest 400 ms is at most ${SCARE_OVER_BEDS} dB over the Basement's beds (turning the quiet up never makes it painful)`,
      loudest <= bedLoudness + SCARE_OVER_BEDS, `${fmt(loudest)} LUFS against the beds' ${fmt(bedLoudness)} LUFS: +${fmt(loudest - bedLoudness)} dB`);
  }

  // ------------------------------------------------------------------------------------------------ memory
  console.log('== memory');
  const budget = await tab.evaluate(() => {
    const bank = window.__rovloc.engine.audio.bank;
    const all = bank.names().reduce((t, n) => {
      const e = bank.sounds[n];
      return t + e.v.reduce((u, v) => u + v[2], 0) * e.c * Math.min(e.r, bank.ctx.sampleRate) * 4;
    }, 0);
    return { peak: bank.peakBytes, now: bank.decodedBytes, all };
  });
  const BUDGET = 60 * 1048576;
  for (const s of stages) console.log(`     ${s.stage.padEnd(34)} ${(s.bytes / 1048576).toFixed(1)} MB decoded${s.first ? '' : '   (the first set is NOT whole)'}`);
  check(`the decoded samples stay under the ${BUDGET / 1048576} MB budget on every stage`, budget.peak <= BUDGET && stages.every((s) => s.bytes <= BUDGET),
    `the most at once ${(budget.peak / 1048576).toFixed(1)} MB; everything decoded at once would be ${(budget.all / 1048576).toFixed(1)} MB`);
  check('on every stage what it needs at once is decoded at its first frame', stages.every((s) => s.first));

  // ------------------------------------------------------------------------------------------------ the console
  check('the console stayed clean through the run', !logs.length, logs.slice(0, 6));
  console.log(`\nold path (${names.recipe.length}): ${names.recipe.join(', ') || 'none'}`);
} catch (err) {
  console.error(err);
  failures.push(`threw: ${err.message}`);
} finally {
  await browser.close();
}

if (failures.length) {
  console.log(`\nFAIL: ${failures.length} check(s)\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('\naudio-test: pass');
