// people-shot.mjs: frames of the people and of the opening's picture in the real engine (headless Playwright Chromium,
// SwiftShader WebGL), for looking at: the opening at its moments with a squad of four, a teammate by torchlight in the
// Basement, the cast side by side.
//
//   node tools/people-shot.mjs --out <dir> [--only opening,teammate] [--tiers Max,Potato] [--moments 03-two-shot,...]
//                              [--times 46..61,61.5] [--size 1280x720] [--no-build]
//
// opening   every moment of MOMENTS (a shot of StoryConfig's Opening and how far into it), on each tier, a squad of four
//           in the cast (the page's own player and three stand-ins in slots 1..3): <out>/opening-<tier>-<moment>.png;
//           with --times, the Full cut at those seconds instead (a..b: every second from a to b), and past its end the
//           hand-over's prologue: <out>/opening-<tier>-t<seconds>.png
// teammate  the Basement in the dark, the page's torch on a teammate 9 studs off: front, side, walking across and
//           walking at the lens: <out>/teammate-<tier>-<view>.png
// Builds build/cache/people-shot.html (game-build.mjs --entry tools/people-shot-entry.js, the 256 and 2048 px texture
// sets inline: Potato's and Max's). Fails on a page error or a console error.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { passBackLot } from './story-pass.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.resolve(here, '..');
const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const outDir = path.resolve(opt('--out', path.join(web, 'build/cache/people-shots')));
const only = new Set(opt('--only', 'opening,teammate').split(','));
const tiers = opt('--tiers', 'Max,Potato').split(',');
const [width, height] = opt('--size', '1280x720').split('x').map(Number);
const wanted = opt('--moments', null);
/** --times: seconds of the Full cut (`a..b` is every second from a to b). */
const times = opt('--times', null)?.split(',').flatMap((item) => {
  const [a, b] = item.split('..').map(Number);
  if (b === undefined) return [a];
  return Array.from({ length: Math.floor(b - a + 1e-9) + 1 }, (_, i) => a + i);
});
const page = path.join(web, 'build/cache/people-shot.html');

/** The opening's moments: [name, shot, how far into the shot (0..1)]. */
export const MOMENTS = [
  ['01-crane', 'S1', 0.5],
  ['02-walk-out', 'S2', 0.5],
  ['03-two-shot', 'S3', 0.42],
  ['04-toward-gate', 'S4', 0.4],
  ['05-the-bin', 'S5', 0.55],
  ['06-the-face', 'S6', 0.82],
  ['07-the-latch', 'S8', 0.36],
  ['08-recoil', 'S9', 0.5],
  ['09-unfold', 'S10', 0.55],
  ['10-run', 'S11', 0.53],
  ['11-in-the-bin', 'S12', 0.8],
  ['12-lockdown', 'S14', 0.75],
  ['13-time-lapse', 'S15', 0.5],
  ['14-night', 'S16', 0.92],
];

const SQUAD = [{ slot: 0, id: '', name: 'Maya' }, { slot: 1, id: 'lab-1', name: 'Bo' }, { slot: 2, id: 'lab-2', name: 'Ana' },
  { slot: 3, id: 'lab-3', name: 'Kit' }];
/** A dark stretch of the Basement's pipe gallery (check.mjs's L0 place): the eye looks along +Z. */
const BASEMENT = { root: [168, 3.5, 40], yaw: Math.PI, feet: 0.5 };
const IGNORED_CONSOLE = /useProgram|Shader Error|WebGL|GPU stall|AudioContext|autoplay/i;

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

async function main() {
  fs.mkdirSync(outDir, { recursive: true });
  if (!argv.includes('--no-build') || !fs.existsSync(page)) {
    execFileSync(process.execPath, [path.join(here, 'game-build.mjs'), '--entry', path.join(here, 'people-shot-entry.js'),
      '--out', page, '--no-minify', '--textures', '256,2048'], { stdio: 'inherit' });
  }
  const browser = await loadPlaywright().chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader',
    '--ignore-gpu-blocklist', '--autoplay-policy=no-user-gesture-required', '--enable-webgl'] });
  const errors = [];
  try {
    const context = await browser.newContext({ bypassCSP: true, viewport: { width, height } });
    const tab = await context.newPage();
    await tab.addInitScript(() => {
      Element.prototype.requestPointerLock = function requestPointerLock() {
        return Promise.resolve();
      };
    });
    tab.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
    tab.on('console', (m) => {
      if (m.type() === 'error' && !IGNORED_CONSOLE.test(m.text())) errors.push(m.text());
      else if (m.type() === 'warning' && m.text().startsWith('[textures]')) console.log(`  page: ${m.text()}`);
    });
    await tab.goto(`file://${page}?dev&seed=1029`);
    await tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 240000 });
    const bootError = await tab.evaluate(() => window.__rovloc.error);
    if (bootError) throw new Error(`boot failed: ${bootError}`);

    const G = (fn, arg) => tab.evaluate(([src, a]) => {
      const w = window.__rovlocGame;
      // eslint-disable-next-line no-new-func
      return new Function('game', 'dev', 'arg', `return (${src})(game, dev, arg);`)(w.game, w.dev, a);
    }, [fn.toString(), arg]);
    /** Steps the game `seconds` at 30 Hz without drawing. */
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
    /** Draws the frame (three frames, a tick in all) and saves it. */
    const shoot = async (name) => {
      await tab.evaluate(() => {
        const e = window.__rovloc.engine;
        for (let i = 0; i < 3; i++) e.loop._run(1 / 90, 1 / 90);
      });
      const file = path.join(outDir, `${name}.png`);
      await tab.screenshot({ path: file, timeout: 240000 });
      console.log(`  ${file}`);
    };
    const setTier = async (tier) => {
      await tab.evaluate((t) => {
        const e = window.__rovloc.engine;
        e.loop.stop();
        e.quality.adapt = false;
        e.settings.set('Graphics', t);
        e.quality.setTier(t);
        e.quality.scale = e.quality.budget.maxScale;
        e.quality.scaleChanged.fire(e.quality.scale);
      }, tier);
      const until = Date.now() + 180000;
      while (Date.now() < until) {
        const done = await tab.evaluate(() => {
          const e = window.__rovloc.engine;
          const t = e.textures;
          if (t.pendingSize === null && t.loading.size === 0 && t.current === t.wanted) return true;
          if (t.pendingSize !== null) {
            const render = e.renderer.render;
            e.renderer.render = () => {};
            for (let i = 0; i < 6; i++) e.loop._run(1 / 30, 1 / 30);
            e.renderer.render = render;
          }
          return false;
        });
        if (done) return;
        await tab.waitForTimeout(200);
      }
      const state = await tab.evaluate(() => {
        const t = window.__rovloc.engine.textures;
        return { current: t.current, wanted: t.wanted, pending: t.pendingSize, queue: t.queue.length, loading: [...t.loading.keys()],
          available: t.available() };
      });
      throw new Error(`the ${tier} texture set never settled: ${JSON.stringify(state)}`);
    };

    await G((g) => {
      window.__rovloc.engine.loop.stop();
      g.env.setSetting('PlayerName', 'Maya');
      g.env.setSetting('NameAsked', true);
      g.env.setSetting('TutorialDone', true);
      g.onboarding.closeForCoop();
    });
    await G((g, dev) => {
      dev.deploy('Standard'); // its promise settles on the game's own steps (ff below)
    });
    await ff(0.6);
    for (let i = 0; i < 150 && !(await G((g) => !!g.cinematics.current)); i++) await ff(1 / 30);

    if (only.has('opening')) {
      const shots = await G((g) => g.cinematics.story.Timelines.Opening.shots);
      const moments = (times ? times.map((t) => [`t${t.toFixed(1).padStart(4, '0')}`, t]) : MOMENTS.filter(([name]) => !wanted ||
        wanted.split(',').includes(name)).map(([name, shot, share]) => {
        const s = shots.find((x) => x.id === shot);
        if (!s) throw new Error(`the Opening has no shot ${shot}`);
        return [name, s.t0 + (s.t1 - s.t0) * share];
      })).sort((a, b) => a[1] - b[1]);
      for (const tier of tiers) {
        console.log(`== the opening on ${tier}`);
        await setTier(tier);
        // the opening again from its start, a squad of four in its cast
        const startAt = await G((g, dev, squad) => {
          const c = g.cinematics;
          const rest = c.current ? c.current.monsterRest : g.opening._creatureRest();
          const at = c.tracks.quantise(g.env.now(), c.tickSeconds);
          c.begin({ run: `shots:${g.env.now()}`, id: 'Opening', cut: 'Full', startAt: at, cast: squad, monsterRest: rest });
          return at;
        }, SQUAD);
        for (const [name, t] of moments) {
          // (past the cut's end the page has handed over to the prologue: the time still counts from the cut's start)
          await ff(Math.max(0, await G((g, dev, at) => at - g.env.now(), startAt + t)));
          await shoot(`opening-${tier}-${name}`);
        }
      }
    }

    if (only.has('teammate')) {
      // through the Back Lot by the rules, into the Basement
      const at = await passBackLot(tab, G, ff);
      if (at.level !== 'Level0_Basement') throw new Error(`the run is not in the Basement: ${JSON.stringify(at)}`);
      await ff(1);
      const place = async (list) => {
        await tab.evaluate((l) => window.__people.stand(l), list);
        await G((g, dev, b) => {
          const e = window.__rovloc.engine;
          e.player.teleport({ position: { x: b.root[0], y: b.root[1], z: b.root[2] }, yaw: b.yaw });
          e.player.setLook(b.yaw, -0.06);
          e.player.flashlight.setOn(true);
          e.ui.setVisible(false, 0);
        }, BASEMENT);
      };
      const [x, , z] = BASEMENT.root;
      const y = BASEMENT.feet;
      const TORCH = 1; // PoseFlags.Torch
      const views = [
        ['front', [{ look: 'slot:1', x, y, z: z + 9, yaw: 0, flags: TORCH }], 0.5],
        ['side', [{ look: 'slot:1', x, y, z: z + 9, yaw: Math.PI / 2 }], 0.5],
        ['walking-across', [{ look: 'slot:1', x: x + 5.6, y, z: z + 9, yaw: Math.PI / 2, walk: [-8, 0] }], 0.7],
        ['walking-at-lens', [{ look: 'slot:1', x: x - 1.2, y, z: z + 17, yaw: 0, walk: [0, -8] }], 0.95],
        ['squad', [0, 1, 2, 3].map((slot, i) => ({ look: `slot:${slot}`, x: x - 3.6 + i * 2.4, y, z: z + 10 + (i % 2) * 0.8, yaw: (i - 1.5) * 0.25 })), 0.5],
      ];
      for (const tier of tiers) {
        console.log(`== a teammate by torchlight on ${tier}`);
        await setTier(tier);
        for (const [name, list, seconds] of views) {
          await place(list);
          await ff(seconds);
          await shoot(`teammate-${tier}-${name}`);
        }
      }
      await tab.evaluate(() => window.__people.clear());
    }
    await context.close();
  } finally {
    await browser.close();
  }
  if (errors.length) {
    console.log(`people-shot: ${errors.length} page errors\n  ${errors.slice(0, 6).join('\n  ')}`);
    process.exit(1);
  }
  console.log('people-shot: done');
}

await main();
