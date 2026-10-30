// store-art.mjs: the Roblox store art (icon, thumbnails, logo) rendered from the browser build's real engine.
//
//   node tools/store-art.mjs [--out ../docs/store] [--only icon-a,thumb-1,...] [--compose-only] [--no-build]
//                            [--seed 1029] [--scale 2] [--icon-scale 4]
//
// 1. Builds the game test page (tools/game-build.mjs -> build/cache/store-art.html) unless --no-build finds one.
// 2. Opens it with ?dev in the pre-installed Playwright Chromium (SwiftShader WebGL), skips the title and deploys a
//    run, then stages every shot through the dev hooks: dev.gotoLevel for the floor, the Creature taken with
//    acquireScripted (teleport / setPose / setTarget, so it stares into the lens), the player teleported with the torch
//    on (the key light), a camera override for framing and focal length. High tier, the internal resolution raised to
//    the viewport (--scale x the output size; icons --icon-scale), and only the WebGL canvas is read back, so no HUD,
//    crosshair, prompt or caption is ever in the frame. Raw renders are cached in build/cache/store-art/.
// 3. Composes the deliverables on a 2D canvas page: downscale (anti-aliasing), a grade (exposure, contrast, split
//    tone, vignette), a bloom on the brightest pixels, and the type: a procedural horror wordmark from the local
//    Inter Display Black (seeded chips along the glyph edges, scratches, a claw slash, speckle, a faint red glow).
//    --compose-only re-composes from the cached renders.
//
// Everything in frame exists in the game: the levels, props, lights, the Creature's rig, poses and pupils, the torch,
// the locker slits, the pool, the generator, the finale's lightning. Nothing is painted in but the type.
//
// Outputs (docs/store): icon.png (= icon-a), icon-a.png, icon-b.png (512), thumb-1-keyart.png .. thumb-5-roof.png
// (1920x1080), logo.png (transparent), logo-on-dark.png (1920x1080).

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
const outDir = path.resolve(web, opt('--out', '../docs/store'));
const cacheDir = path.join(web, 'build/cache/store-art');
const page = path.join(web, 'build/cache/store-art.html');
const seed = Number(opt('--seed', 1029));
const scale = Number(opt('--scale', 2));
const iconScale = Number(opt('--icon-scale', 4));
const only = opt('--only', '') ? new Set(opt('--only', '').split(',')) : null;
const composeOnly = argv.includes('--compose-only');
const FONT_DIR = '/usr/share/fonts/opentype/inter';

function loadPlaywright() {
  const require = createRequire(import.meta.url);
  const roots = [web, process.cwd(), '/opt/node-tools/node_modules'];
  try {
    roots.push(execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim());
  } catch { /* npm missing */ }
  roots.push('/opt/node22/lib/node_modules', '/usr/local/lib/node_modules', '/usr/lib/node_modules');
  for (const r of roots) {
    try {
      return require(require.resolve('playwright', { paths: [r] }));
    } catch { /* next */ }
  }
  throw new Error('playwright not found (it is expected pre-installed globally)');
}

// ------------------------------------------------------------------------------------------------ the game page side

/** Installs window.__art: the staging kit (runs in the game page). */
function installArt() {
  const w = window.__rovlocGame;
  const g = w.game;
  const dev = w.dev;
  const e = window.__rovloc.engine;
  const T = e.THREE;
  const TOKEN = 'store-art';
  const RH = 4.7; // the Creature's root over the floor (CreatureConfig.Rig: HipHeight 3.4 + RootSize.Y / 2)
  const EYE = 4.6; // the player's eye over the floor (root 3 + 1.6)
  const val = (v) => (typeof v === 'function' ? v() : v);
  const art = {
    T,
    /** Advances the game `s` seconds at 30 Hz without drawing. */
    ff(s) {
      const loop = e.loop;
      loop.stop();
      e.skipRender = true;
      try {
        for (let i = 0; i < Math.round(s * 30); i++) loop._run(1 / 30, 1 / 30);
      } finally {
        e.skipRender = false;
      }
    },
    /** High tier at full scale, the internal resolution allowed up to the canvas. */
    hires() {
      const q = e.quality;
      q.adapt = false;
      q.probing = null;
      q.setTier('High');
      q.budget = Object.assign({}, q.budget, { maxHeight: 8192 });
      q.scale = 1;
      e.renderer._resize();
      e.renderer._resizeTarget();
      return e.renderer.stats.internal;
    },
    /** Draws one frame and reads the canvas back (the HUD is DOM over it, so never in the image). */
    capture() {
      art.hires();
      e.loop.stop();
      e.loop._run(1 / 30, 1 / 30);
      return e.canvas.toDataURL('image/png');
    },
    async freshRun() {
      art.cam(null);
      for (let a = 0; a < 4 && g.phase !== 'InRun'; a++) {
        dev.deploy();
        for (let i = 0; i < 30; i++) {
          art.ff(0.5);
          await new Promise((r) => setTimeout(r, 10));
          if (g.phase === 'InRun') break;
        }
      }
      art.ff(1);
      return g.phase;
    },
    /** On `level` (dev level skip), the Creature told to ignore the player, the torch on. */
    prepare(level, flashScale = 0) {
      art.cam(null);
      if (g.lockers.occupiedId()) g.lockers.release();
      if (g.level !== level) {
        dev.gotoLevel(level);
        art.ff(1.5);
      }
      g.creature.devCommand('ignoreme');
      e.settings.set('FlashScale', flashScale); // the torch's EMF flicker (the Accessibility setting)
      e.player.flashlight.setOn(true);
      return g.level;
    },
    /** The Creature, taken from whichever level script holds it. */
    handle() {
      const s = g.creature.c.service;
      if (s.scripted && s.scripted.token !== TOKEN) s._releaseScripted('Dormant');
      return g.creature.c.acquireScripted(TOKEN);
    },
    /** The Creature's root at `root` facing `facing` (horizontal), in `pose`, staring at the camera. */
    creatureAt(root, facing, pose = 'Biped') {
      const h = art.handle();
      if (!h) throw new Error('the Creature could not be taken');
      h.setHidden(false);
      const p = new T.Vector3(root.x, root.y, root.z);
      const m = new T.Matrix4().lookAt(p, new T.Vector3(facing.x, p.y, facing.z), new T.Vector3(0, 1, 0));
      m.setPosition(p);
      h.teleport(m);
      h.setPose(pose);
      h.setTarget(true);
      return h;
    },
    /** Standing on the floor at (x, floorY, z). */
    creature(x, floorY, z, facing, pose = 'Biped') {
      return art.creatureAt({ x, y: floorY + RH, z }, facing, pose);
    },
    /** The live head's face point. */
    face() {
      const f = g.creature.c.service.view.faceWorld();
      return f ? new T.Vector3().copy(f.position) : null;
    },
    /** The player standing at (x, floorY, z), looking (and aiming the torch) at `target`. */
    player(x, floorY, z, target) {
      g.env.teleport({ position: new T.Vector3(x, floorY + 3, z), yaw: 0 });
      g.traps.noteTeleport();
      art.ff(0.05);
      if (target) art.aim(target);
      e.player.flashlight.setOn(true);
    },
    /** Turns the player's look (and the torch with it) toward `target`. */
    aim(target) {
      const eye = e.player.eyePosition.clone();
      const d = new T.Vector3(target.x, target.y, target.z).sub(eye);
      const yaw = Math.atan2(-d.x, -d.z);
      g.env.setLook(yaw, Math.atan2(d.y, Math.hypot(d.x, d.z)));
    },
    /**
     * The shot's camera (a top-priority override; the torch stays the player's): pos (default the player's eye) and
     * look (a point; default the player's look), either may be a function; fov in degrees. null releases it.
     */
    cam(opt) {
      const pl = e.player;
      if (!opt) {
        pl.setCameraOverride(TOKEN, null);
        return;
      }
      pl.setCameraOverride(TOKEN, () => {
        const position = opt.pos ? val(opt.pos).clone() : pl.eyePosition.clone();
        const look = opt.look ? val(opt.look) : null;
        if (look) return { position, lookAt: look.clone(), fov: opt.fov };
        return { position, quaternion: pl.eyeQuat.clone(), fov: opt.fov };
      }, { priority: 1000, blendIn: 0, blendOut: 0 });
    },
    /** Holds the current camera where it is, re-aimed by (dyaw, dpitch) radians, at `fov`. */
    freeze(fov, dyaw = 0, dpitch = 0) {
      const c = e.renderer.camera;
      const pos = c.position.clone();
      const eu = new T.Euler().setFromQuaternion(c.quaternion, 'YXZ');
      eu.y += dyaw;
      eu.x += dpitch;
      const q = new T.Quaternion().setFromEuler(eu);
      e.player.setCameraOverride(TOKEN, () => ({ position: pos.clone(), quaternion: q.clone(), fov }),
        { priority: 1000, blendIn: 0, blendOut: 0 });
    },
    /** Climbs into locker `id` (the real hide: door, camera behind the slits, the torch off). */
    hideIn(id) {
      if (g.lockers.occupiedId()) g.lockers.release();
      art.ff(0.3);
      const lk = g.lockers.lockers.get(id);
      const p = new T.Vector3().setFromMatrixPosition(lk.exit).add(new T.Vector3(0, 3, 0));
      g.env.teleport({ position: p, yaw: Math.atan2(lk.exit.elements[8], lk.exit.elements[10]) });
      g.traps.noteTeleport();
      art.ff(0.3);
      const ok = g.lockers.hide(lk);
      art.ff(2.5);
      return ok && g.lockers.occupiedId() === id;
    },
    /** Lets the Creature go (back to the game's own scripts, e.g. the finale). */
    release() {
      const s = g.creature.c.service;
      if (s.scripted && s.scripted.token === TOKEN) s._releaseScripted('Dormant');
    },
    /** The head's roll (its face frame's right vector, up component) and how squarely it faces `from`. */
    head(from) {
      const f = g.creature.c.service.view.faceWorld();
      const to = new T.Vector3(from.x, from.y, from.z).sub(f.position).normalize();
      return { roll: f.rightVector.y, facing: f.lookVector.dot(to) };
    },
    /** Steps the game (0.1 s at a time, up to `max` s) until the head's roll satisfies `ok` while it faces `from`. */
    untilHead(from, ok, max = 12) {
      for (let t = 0; t < max; t += 0.1) {
        const h = art.head(from);
        if (ok(h.roll) && Math.abs(h.facing) > 0.97) return true;
        art.ff(0.1);
      }
      return false;
    },
    /** Where a world point lands on the screen (0..1, y down) with the current camera. */
    project(p) {
      const v = new T.Vector3(p.x, p.y, p.z).project(e.renderer.camera);
      return { x: (v.x + 1) / 2, y: (1 - v.y) / 2, z: v.z };
    },
    EYE,
    RH,
  };
  window.__art = art;
  return true;
}

// The shots. Each runs in the game page as (art, g, dev, e, T) and leaves the frame staged; the runner captures it.
// `size` is the output size; the render is size x scale. `meta` (returned) is kept for the composer.
const SHOTS = [
  {
    // The icon: the Creature's face caught in the torch, frontal and level, in the dark gym (its far wall 80 studs
    // back). The head twitches between tilts on its own; the frame waits for a level one.
    name: 'icon-a',
    size: [512, 512],
    icon: true,
    run: async (art, g, dev, e, T) => {
      art.prepare('Level3_Gymnasium');
      art.creature(40, 50, 80, { x: 0, z: 80 });
      art.ff(0.4);
      const face = art.face();
      const cam = face.clone().add(new T.Vector3(-6.2, -0.75, 0));
      art.player(cam.x, cam.y - art.EYE, cam.z, face);
      art.cam({ pos: cam, look: () => art.face().add(new T.Vector3(0, -0.12, 0)), fov: 21 });
      art.ff(0.6);
      art.aim(art.face().add(new T.Vector3(0, -0.25, 0)));
      art.untilHead(cam, (roll) => Math.abs(roll) < 0.03);
      return { face: art.project(art.face()), roll: art.head(cam).roll };
    },
  },
  {
    // The second icon: three-quarter and tilted (one of its head twitches), the torch from low left (a teammate's
    // beam), a harder shadow across the face; the wordmark under it.
    name: 'icon-b',
    size: [512, 512],
    icon: true,
    run: async (art, g, dev, e, T) => {
      art.prepare('Level3_Gymnasium');
      art.creature(40, 50, 80, { x: 0, z: 74 });
      art.ff(0.4);
      const face = art.face();
      const cam = face.clone().add(new T.Vector3(-5.6, -0.8, -2.4));
      const light = face.clone().add(new T.Vector3(-4.2, -1.6, 3.6));
      art.player(light.x, light.y - art.EYE, light.z, face);
      art.cam({ pos: cam, look: () => art.face().add(new T.Vector3(0, -0.62, 0)), fov: 25 });
      art.ff(0.6);
      art.aim(art.face().add(new T.Vector3(0, 0.1, 0)));
      art.untilHead(cam, (roll) => roll < -0.18);
      return { face: art.project(art.face()), roll: art.head(cam).roll };
    },
  },
  {
    // Hiding: from inside a boys' locker room locker, through the slits; the Creature walks past under the far working
    // tube, its head turned to the locker. The torch is off in a locker, as in the game.
    name: 'thumb-2-hide',
    size: [1920, 1080],
    run: async (art, g, dev, e, T) => {
      art.prepare('Level3_Gymnasium');
      if (!art.hideIn('L3_Locker_08')) throw new Error('could not hide in L3_Locker_08');
      e.player.flashlight.setOn(false);
      art.cam(null);
      art.ff(0.2);
      art.creature(165, 50, 68.5, { x: 147, z: 69.5 });
      art.handle().moveTo(new T.Vector3(147, 50 + art.RH, 69.5), 2.0);
      art.ff(1.25);
      art.freeze(33, 0.14, 0.01);
      art.ff(0.1);
      return { face: art.project(art.face()) };
    },
  },
  {
    // An objective moment, Floor 2: the chem prep room's fume hood, brewed (the three reagent jars loaded, the sash up,
    // the acid flask's Neon glowing beside them), and the Creature just in through the west door from the science
    // wing, caught in the torch.
    name: 'thumb-4-objective',
    size: [1920, 1080],
    run: async (art, g, dev, e, T) => {
      art.prepare('Level2_ScienceHall');
      const f = g.floors.floor('Level2_ScienceHall');
      if (f.acidState !== 'Ready') {
        for (let i = 0; i < 3; i++) f.carry.add('Reagent');
        f._load();
        art.ff(2);
        f._brewed();
      }
      art.ff(0.5);
      art.creature(97, 34, 62.5, { x: 118, z: 63.5 });
      art.player(118, 34, 63.5, { x: 97, y: 39.5, z: 62.5 });
      art.cam({ pos: new T.Vector3(118, 38.6, 63.5), look: new T.Vector3(101.5, 38.6, 52), fov: 56 });
      art.ff(1.0);
      return { face: art.project(art.face()), hood: art.project({ x: 107.5, y: 37.2, z: 41.5 }) };
    },
  },
  {
    // Key art: the Level 1 west corridor, the Creature standing in the torch cone down the hall, on the right third.
    name: 'thumb-1-keyart',
    size: [1920, 1080],
    run: async (art, g, dev, e, T) => {
      art.prepare('Level1_Hallways');
      art.creature(39.5, 18, 82.4, { x: 18, z: 78 });
      art.ff(0.3);
      art.player(18, 18, 77.2, { x: 39.5, y: 18 + 5.6, z: 82.4 });
      art.cam({ look: new T.Vector3(39.5, 18 + 5.0, 75.6), fov: 64 });
      art.ff(1.5);
      return { face: art.project(art.face()) };
    },
  },
  {
    // The flooded pool: crouched at the deck edge, the torch on the black water, the Creature's head breaking the
    // surface in the beam (its body pale under it), the lane rope and a kickboard floating by.
    name: 'thumb-3-pool',
    size: [1920, 1080],
    run: async (art, g, dev, e, T) => {
      art.prepare('Level4_FloodedPool');
      art.player(125.6, 82, 103.5, { x: 137, y: 81, z: 99 });
      art.ff(0.5);
      art.creatureAt({ x: 138.5, y: 80.72, z: 98.6 }, { x: 125.6, z: 103.5 }, 'Swim');
      art.ff(0.4);
      art.aim(art.face().add(new T.Vector3(0, -1.3, 0)));
      const cam = new T.Vector3(125.6, 84.7, 103.5);
      art.cam({ pos: cam, look: () => art.face().add(new T.Vector3(0, 0.3, 0)), fov: 37 });
      art.ff(1.0);
      return { face: art.project(art.face()) };
    },
  },
  {
    // The roof finale (the real one: dev.signature jumps with a pack and pulls the cord; the finale takes the
    // Creature): under the canopy, looking back up at the ledge in the first lightning strike's afterglow.
    name: 'thumb-5-roof',
    size: [1920, 1080],
    run: async (art, g, dev, e, T) => {
      art.prepare('Level5_Roof', 1);
      art.release();
      const old = g.level5.finale;
      dev.signature('Level5_Roof');
      art.ff(1.5);
      for (let k = 0; k < 80 && (!g.level5.finale || g.level5.finale === old); k++) art.ff(0.1);
      const fin = g.level5.finale;
      if (!fin) throw new Error('the finale did not start');
      const until = (t) => fin.startAt + t - g.env.now();
      let wait = until(1.25);
      if (wait > 0) art.ff(wait);
      const face = art.face().clone();
      art.cam({ look: () => face.clone().add(new T.Vector3(0, -2.7, -0.3)), fov: 15.5 });
      wait = until(1.97);
      if (wait > 0) art.ff(wait);
      if (g.creature.isHidden()) throw new Error('the Creature is not on the ledge');
      return { face: art.project(art.face()), flash: e.lighting.flash };
    },
  },
];

// ------------------------------------------------------------------------------------------------ the composer side

/** Installs window.C: the 2D compositing kit (runs in the blank composer page). */
function installComposer() {
  const C = {};
  C.canvas = (w, h) => {
    const c = document.createElement('canvas');
    c.width = Math.max(1, Math.round(w));
    c.height = Math.max(1, Math.round(h));
    return c;
  };
  C.ctx = (c) => c.getContext('2d', { willReadFrequently: true });
  C.image = (src) => new Promise((resolve, reject) => {
    const i = new Image();
    i.onload = () => resolve(i);
    i.onerror = reject;
    i.src = src;
  });
  C.font = async (family, b64) => {
    const bytes = Uint8Array.from(atob(b64), (ch) => ch.charCodeAt(0));
    const face = new FontFace(family, bytes.buffer);
    await face.load();
    document.fonts.add(face);
  };
  /** mulberry32 */
  C.rng = (seed) => {
    let a = seed >>> 0;
    return () => {
      a = (a + 0x6d2b79f5) >>> 0;
      let t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  };
  /** Halving steps (each a 2x2 box filter by the browser's smoothing) down to w x h, optional crop of the source. */
  C.downscale = (src, w, h, crop) => {
    const [sx, sy, sw, sh] = crop || [0, 0, src.width, src.height];
    let cur = C.canvas(sw, sh);
    C.ctx(cur).drawImage(src, sx, sy, sw, sh, 0, 0, sw, sh);
    while (cur.width / 2 >= w * 0.999 && cur.height / 2 >= h * 0.999) {
      const next = C.canvas(cur.width / 2, cur.height / 2);
      const x = C.ctx(next);
      x.imageSmoothingEnabled = true;
      x.imageSmoothingQuality = 'high';
      x.drawImage(cur, 0, 0, next.width, next.height);
      cur = next;
    }
    const out = C.canvas(w, h);
    const x = C.ctx(out);
    x.imageSmoothingEnabled = true;
    x.imageSmoothingQuality = 'high';
    x.drawImage(cur, 0, 0, w, h);
    return out;
  };
  const smooth = (a, b, x) => {
    const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
    return t * t * (3 - 2 * t);
  };
  /**
   * The grade, per pixel: exposure, gamma, an S-curve about `pivot`, lift, saturation, a split tone (shadow / highlight
   * multipliers), a radial vignette (centre cx, cy) and an optional radial pool of light `spot` {x, y, r, gain}.
   */
  C.grade = (cv, o) => {
    const x = C.ctx(cv);
    const W = cv.width;
    const H = cv.height;
    const img = x.getImageData(0, 0, W, H);
    const d = img.data;
    const exposure = o.exposure ?? 1;
    const knee = o.knee ?? 0.8; // highlights roll off above it instead of clipping
    const gamma = 1 / (o.gamma ?? 1);
    const k = Math.max(0.2, 1 + (o.contrast ?? 0));
    const pivot = o.pivot ?? 0.2;
    const lift = o.lift ?? 0;
    const sat = o.saturation ?? 1;
    const sh = o.shadows || [1, 1, 1];
    const hi = o.highlights || [1, 1, 1];
    const vig = o.vignette ?? 0;
    const vpow = o.vignettePower ?? 2.2;
    const cx = (o.cx ?? 0.5) * W;
    const cy = (o.cy ?? 0.5) * H;
    const rr = Math.hypot(Math.max(cx, W - cx), Math.max(cy, H - cy));
    const spot = o.spot || null;
    const lut = new Float32Array(256);
    for (let i = 0; i < 256; i++) lut[i] = (i / 255) ** 2.2;
    for (let y = 0; y < H; y++) {
      for (let xx = 0; xx < W; xx++) {
        const i = (y * W + xx) * 4;
        let r = d[i] / 255;
        let gg = d[i + 1] / 255;
        let b = d[i + 2] / 255;
        let gain = exposure;
        if (spot) {
          const sd = Math.hypot(xx - spot.x * W, y - spot.y * H) / (spot.r * W);
          gain *= 1 + spot.gain * Math.max(0, 1 - sd * sd);
        }
        r *= gain;
        gg *= gain;
        b *= gain;
        const ch = [r, gg, b];
        for (let c = 0; c < 3; c++) {
          let v = Math.max(0, ch[c]);
          if (v > knee) v = knee + (1 - knee) * (1 - Math.exp(-(v - knee) / (1 - knee)));
          v = Math.min(1, v) ** gamma;
          v = v < pivot ? pivot * (v / pivot) ** k : 1 - (1 - pivot) * ((1 - v) / (1 - pivot)) ** k;
          ch[c] = lift + (1 - lift) * v;
        }
        const l = 0.299 * ch[0] + 0.587 * ch[1] + 0.114 * ch[2];
        const t = smooth(0.08, 0.6, l);
        let v2 = 1;
        if (vig > 0) {
          const dist = Math.hypot(xx - cx, y - cy) / rr;
          v2 = 1 - vig * dist ** vpow;
        }
        for (let c = 0; c < 3; c++) {
          let v = l + (ch[c] - l) * sat;
          v *= sh[c] + (hi[c] - sh[c]) * t;
          d[i + c] = Math.max(0, Math.min(255, Math.round(v * v2 * 255)));
        }
      }
    }
    x.putImageData(img, 0, 0);
    return cv;
  };
  /** Bloom: the pixels over `threshold` (luma), blurred at two radii, screened back on. */
  C.bloom = (cv, o) => {
    const W = cv.width;
    const H = cv.height;
    const small = C.canvas(W / 4, H / 4);
    const sx = C.ctx(small);
    sx.drawImage(cv, 0, 0, small.width, small.height);
    const img = sx.getImageData(0, 0, small.width, small.height);
    const d = img.data;
    const th = o.threshold ?? 0.7;
    for (let i = 0; i < d.length; i += 4) {
      const l = (0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2]) / 255;
      const f = Math.max(0, (l - th) / (1 - th));
      d[i] *= f;
      d[i + 1] *= f;
      d[i + 2] *= f;
    }
    sx.putImageData(img, 0, 0);
    const x = C.ctx(cv);
    x.save();
    x.globalCompositeOperation = 'screen';
    for (const [radius, amount] of [[o.radius ?? W * 0.006, o.strength ?? 0.6], [(o.radius ?? W * 0.006) * 4, (o.strength ?? 0.6) * 0.6]]) {
      x.globalAlpha = Math.min(1, amount);
      x.filter = `blur(${radius}px)`;
      x.drawImage(small, 0, 0, W, H);
    }
    x.restore();
    return cv;
  };
  /** A mask canvas tinted one colour. */
  C.tint = (mask, color) => {
    const c = C.canvas(mask.width, mask.height);
    const x = C.ctx(c);
    x.drawImage(mask, 0, 0);
    x.globalCompositeOperation = 'source-in';
    x.fillStyle = color;
    x.fillRect(0, 0, c.width, c.height);
    return c;
  };
  /**
   * The distressed wordmark: Inter Display Black letters (tracked, each nudged and tilted a hair), then cut with
   * destination-out: chips bitten from the glyph edges, long hairline scratches, a three-line claw slash, speckle.
   * Bone fill (a vertical gradient, blotched with grime) over a faint blood-red glow. Transparent canvas.
   */
  C.wordmark = (o) => {
    const text = o.text;
    const size = o.size;
    const R = C.rng(o.seed ?? 7);
    const distress = o.distress ?? 1;
    const font = `${size}px "${o.family || 'IDB'}"`;
    const meas = C.ctx(C.canvas(8, 8));
    meas.font = font;
    const track = size * (o.track ?? 0.03);
    const squeeze = o.squeeze ?? 1;
    const letters = [...text].map((ch) => ({ ch, w: meas.measureText(ch).width * squeeze }));
    const total = letters.reduce((a, l) => a + l.w, 0) + track * (letters.length - 1);
    const pad = size * (o.pad ?? 0.42);
    const capH = size * 0.73;
    const W = Math.ceil(total + pad * 2);
    const H = Math.ceil(capH + pad * 2);
    const mask = C.canvas(W, H);
    const m = C.ctx(mask);
    m.font = font;
    m.fillStyle = '#fff';
    const base = pad + capH;
    let x = pad;
    for (const l of letters) {
      const jy = (R() - 0.5) * size * 0.035 * (o.jitter ?? 1);
      const rot = (R() - 0.5) * 0.04 * (o.jitter ?? 1);
      m.save();
      m.translate(x + l.w / 2, base + jy);
      m.rotate(rot);
      m.scale(squeeze, 1);
      m.fillText(l.ch, -l.w / squeeze / 2, 0);
      m.restore();
      x += l.w + track;
    }
    if (distress > 0) {
      // edge pixels
      const a = m.getImageData(0, 0, W, H).data;
      const at = (px, py) => (px < 0 || py < 0 || px >= W || py >= H ? 0 : a[(py * W + px) * 4 + 3]);
      const edges = [];
      const st = Math.max(1, Math.round(size / 160));
      const reach = Math.max(2, Math.round(size / 90));
      for (let py = 0; py < H; py += st) {
        for (let px = 0; px < W; px += st) {
          if (at(px, py) < 128) continue;
          if (at(px + reach, py) < 128 || at(px - reach, py) < 128 || at(px, py + reach) < 128 || at(px, py - reach) < 128) edges.push([px, py]);
        }
      }
      m.globalCompositeOperation = 'destination-out';
      m.fillStyle = '#000';
      m.strokeStyle = '#000';
      const blob = (cx, cy, r, n) => {
        m.beginPath();
        for (let i = 0; i < n; i++) {
          const ang = (i / n) * Math.PI * 2 + R() * 0.4;
          const rad = r * (0.45 + R() * 0.75);
          const px = cx + Math.cos(ang) * rad;
          const py = cy + Math.sin(ang) * rad;
          if (i === 0) m.moveTo(px, py);
          else m.lineTo(px, py);
        }
        m.closePath();
        m.fill();
      };
      // chips: small bites everywhere along the edges, a few bigger ones
      const chips = Math.round(edges.length * 0.03 * distress);
      for (let i = 0; i < chips && edges.length; i++) {
        const [px, py] = edges[Math.floor(R() * edges.length)];
        const big = R() < 0.08;
        blob(px, py, size * (big ? 0.022 + R() * 0.02 : 0.005 + R() * 0.012), big ? 9 : 6);
      }
      // hairline scratches, steep and mostly one way
      const scratches = Math.round(26 * distress);
      for (let i = 0; i < scratches; i++) {
        const sx0 = pad + R() * total;
        const sy0 = pad - size * 0.1 + R() * (capH + size * 0.2);
        const ang = (-62 + (R() - 0.5) * 34) * Math.PI / 180;
        const len = size * (0.12 + R() * 0.55);
        m.globalAlpha = 0.55 + R() * 0.45;
        m.lineWidth = size * (0.0025 + R() * 0.006);
        m.lineCap = 'round';
        m.beginPath();
        m.moveTo(sx0, sy0);
        m.quadraticCurveTo(sx0 + Math.cos(ang) * len * 0.5 + (R() - 0.5) * size * 0.04, sy0 + Math.sin(ang) * len * 0.5,
          sx0 + Math.cos(ang) * len, sy0 + Math.sin(ang) * len);
        m.stroke();
      }
      m.globalAlpha = 1;
      // the claw: three tapered slashes side by side across the word
      if (o.claw !== false) {
        const cxs = pad + total * (o.clawAt ?? 0.56);
        const ang = (-54 * Math.PI) / 180;
        const len = capH * 1.6;
        const gap = size * 0.085;
        for (let k = -1; k <= 1; k++) {
          const ox = cxs + k * gap * 1.15;
          const oy = base - capH * 0.5 + k * gap * 0.25;
          const dx = Math.cos(ang) * len * 0.5;
          const dy = Math.sin(ang) * len * 0.5;
          const wmax = size * (0.042 - Math.abs(k) * 0.008) * Math.min(1, distress + 0.3);
          const steps = Math.ceil(len / Math.max(1, wmax * 0.2));
          for (let s = 0; s <= steps; s++) {
            const t = s / steps;
            const px = ox - dx + 2 * dx * t + Math.sin(t * Math.PI) * size * 0.02;
            const py = oy - dy + 2 * dy * t;
            const wv = wmax * Math.sin(Math.PI * Math.min(1, Math.max(0, t * 1.05 - 0.02))) ** 0.7;
            m.beginPath();
            m.arc(px, py, Math.max(0.5, wv / 2), 0, Math.PI * 2);
            m.fill();
          }
        }
      }
      // speckle: clustered pits
      const pits = Math.round(900 * distress * (W * H) / (2400 * 900));
      for (let i = 0; i < pits; i++) {
        const cx = pad + R() * total;
        const cy = pad + R() * capH;
        m.globalAlpha = 0.35 + R() * 0.65;
        m.beginPath();
        m.arc(cx, cy, size * (0.0015 + R() ** 3 * 0.009), 0, Math.PI * 2);
        m.fill();
      }
      m.globalAlpha = 1;
      m.globalCompositeOperation = 'source-over';
    }
    // fill
    const fill = C.canvas(W, H);
    const f = C.ctx(fill);
    const grad = f.createLinearGradient(0, pad, 0, pad + capH);
    const cols = o.colors || ['#f4eddc', '#ddd2b8', '#b9a985'];
    grad.addColorStop(0, cols[0]);
    grad.addColorStop(0.55, cols[1]);
    grad.addColorStop(1, cols[2]);
    f.fillStyle = grad;
    f.fillRect(0, 0, W, H);
    f.globalCompositeOperation = 'multiply';
    const blots = Math.round(220 * (o.grime ?? 1));
    for (let i = 0; i < blots; i++) {
      const cx = pad + R() * total;
      const cy = pad + R() * capH;
      const r = size * (0.02 + R() * 0.09);
      const gr = f.createRadialGradient(cx, cy, 0, cx, cy, r);
      const shade = o.grimeColor || [118, 92, 66];
      gr.addColorStop(0, `rgba(${shade[0]},${shade[1]},${shade[2]},${0.12 + R() * 0.2})`);
      gr.addColorStop(1, `rgba(${shade[0]},${shade[1]},${shade[2]},0)`);
      f.fillStyle = gr;
      f.fillRect(cx - r, cy - r, r * 2, r * 2);
    }
    if (o.stain !== false) {
      // a dried-blood wash up from the foot of the letters
      const sg = f.createLinearGradient(0, pad + capH * 0.55, 0, pad + capH);
      sg.addColorStop(0, 'rgba(150,40,30,0)');
      sg.addColorStop(1, `rgba(150,40,30,${o.stain ?? 0.35})`);
      f.fillStyle = sg;
      f.fillRect(0, 0, W, H);
    }
    f.globalCompositeOperation = 'destination-in';
    f.drawImage(mask, 0, 0);
    // glow + edge, then the fill
    const out = C.canvas(W, H);
    const ox = C.ctx(out);
    const glow = o.glow ?? 1;
    if (glow > 0) {
      const red = C.tint(mask, o.glowColor || 'rgb(178,18,12)');
      ox.globalAlpha = 0.5 * glow;
      ox.filter = `blur(${size * 0.11}px)`;
      ox.drawImage(red, 0, 0);
      ox.globalAlpha = 0.55 * glow;
      ox.filter = `blur(${size * 0.035}px)`;
      ox.drawImage(red, 0, 0);
      ox.filter = 'none';
      ox.globalAlpha = 1;
    }
    if (o.outline) {
      ox.filter = `blur(${size * 0.012}px)`;
      ox.globalAlpha = o.outline;
      ox.drawImage(C.tint(mask, 'rgb(20,6,4)'), 0, 0);
      ox.filter = 'none';
      ox.globalAlpha = 1;
    }
    ox.drawImage(fill, 0, 0);
    out.box = { pad, capH, total, W, H };
    return out;
  };
  /** Plain tracked text (the tagline) on its own canvas, with a soft shadow. */
  C.line = (o) => {
    const meas = C.ctx(C.canvas(8, 8));
    meas.font = `${o.size}px "${o.family}"`;
    meas.letterSpacing = `${o.track ?? 0}px`;
    const parts = o.parts || [{ text: o.text, color: o.color }];
    const widths = parts.map((p) => meas.measureText(p.text).width);
    const total = widths.reduce((a, b) => a + b, 0);
    const pad = o.size * 0.6;
    const c = C.canvas(total + pad * 2, o.size * 1.4 + pad * 2);
    const x = C.ctx(c);
    x.font = meas.font;
    x.letterSpacing = meas.letterSpacing;
    x.textBaseline = 'middle';
    x.shadowColor = 'rgba(0,0,0,0.85)';
    x.shadowBlur = o.size * 0.4;
    let px = pad;
    parts.forEach((p, i) => {
      x.fillStyle = p.color;
      x.fillText(p.text, px, c.height / 2);
      px += widths[i];
    });
    c.box = { pad, total };
    return c;
  };
  /** A soft dark pool behind type (a radial gradient), so it reads on any frame. */
  C.shade = (ctx, cx, cy, rx, ry, alpha) => {
    ctx.save();
    ctx.translate(cx, cy);
    ctx.scale(rx, ry);
    const gr = ctx.createRadialGradient(0, 0, 0, 0, 0, 1);
    gr.addColorStop(0, `rgba(0,0,0,${alpha})`);
    gr.addColorStop(0.55, `rgba(0,0,0,${alpha * 0.6})`);
    gr.addColorStop(1, 'rgba(0,0,0,0)');
    ctx.fillStyle = gr;
    ctx.fillRect(-1, -1, 2, 2);
    ctx.restore();
  };
  /** Draws `src` (a canvas with .box) so its glyph box's left / centre / right edge sits at x and cap middle at y. */
  C.place = (ctx, src, x, y, width, align = 'left') => {
    const b = src.box;
    const s = width / b.total;
    const gx = align === 'left' ? x : align === 'center' ? x - width / 2 : x - width;
    const capMid = b.capH !== undefined ? b.pad + b.capH / 2 : src.height / 2;
    ctx.drawImage(src, gx - b.pad * s, y - capMid * s, src.width * s, src.height * s);
    return { x: gx, y: y - (b.capH !== undefined ? b.capH / 2 : 0) * s, w: width, h: (b.capH ?? 0) * s, s };
  };
  C.png = (cv) => cv.toDataURL('image/png');
  window.C = C;
  return true;
}

// Per-output composition, run in the composer page as (C, raws, meta, logo) -> canvas.
const COMPOSE = {
  'icon-a': (C, raw, meta) => {
    const s = raw.width;
    const cv = C.downscale(raw, 512, 512, [0, 0, s, s]);
    C.grade(cv, { exposure: 1.0, knee: 0.72, gamma: 1.0, contrast: 0.38, pivot: 0.3, saturation: 0.85,
      shadows: [1.1, 0.86, 0.84], highlights: [1.02, 1.0, 0.95], vignette: 0.6, vignettePower: 2.4,
      cx: meta.face.x, cy: meta.face.y + 0.05 });
    C.bloom(cv, { threshold: 0.8, strength: 0.75, radius: 4 });
    return cv;
  },
  'icon-b': (C, raw, meta, logo) => {
    const s = raw.width;
    const cv = C.downscale(raw, 512, 512, [0, 0, s, s]);
    C.grade(cv, { exposure: 1.05, knee: 0.72, gamma: 1.0, contrast: 0.4, pivot: 0.3, saturation: 0.82,
      shadows: [1.1, 0.84, 0.82], highlights: [1.02, 1.0, 0.94], vignette: 0.6, vignettePower: 2.2,
      cx: meta.face.x, cy: meta.face.y });
    C.bloom(cv, { threshold: 0.8, strength: 0.75, radius: 4 });
    const x = C.ctx(cv);
    C.shade(x, 256, 452, 250, 70, 0.75);
    C.place(x, logo.small, 256, 446, 300, 'center');
    return cv;
  },
  'thumb-1-keyart': (C, raw, meta, logo) => {
    const cv = C.downscale(raw, 1920, 1080);
    C.grade(cv, { exposure: 1.18, knee: 0.74, gamma: 1.1, contrast: 0.3, pivot: 0.22, saturation: 0.9,
      shadows: [0.9, 1.0, 1.06], highlights: [1.05, 1.0, 0.92], vignette: 0.42, cx: meta.face.x, cy: meta.face.y });
    C.bloom(cv, { threshold: 0.78, strength: 0.5, radius: 10 });
    const x = C.ctx(cv);
    // the logo and the tagline in the dark lower left, inside the middle 80 %
    C.shade(x, 540, 830, 600, 260, 0.82);
    const box = C.place(x, logo.big, 236, 770, 640, 'left');
    C.place(x, logo.tag, 240, box.y + box.h + 62, 600, 'left');
    return cv;
  },
  'thumb-2-hide': (C, raw, meta, logo) => {
    const cv = C.downscale(raw, 1920, 1080);
    C.grade(cv, { exposure: 1.3, knee: 0.74, gamma: 1.2, contrast: 0.32, pivot: 0.2, saturation: 0.8, lift: 0.008,
      shadows: [0.9, 1.0, 1.08], highlights: [1.06, 0.98, 0.9], vignette: 0.3, cx: meta.face.x, cy: meta.face.y });
    C.bloom(cv, { threshold: 0.75, strength: 0.55, radius: 8 });
    const x = C.ctx(cv);
    C.place(x, logo.caption('HIDE', 11), 250, 885, 440, 'left');
    return cv;
  },
  'thumb-3-pool': (C, raw, meta, logo) => {
    const cv = C.downscale(raw, 1920, 1080);
    C.grade(cv, { exposure: 0.95, knee: 0.58, gamma: 1.45, contrast: 0.3, pivot: 0.2, saturation: 0.95, lift: 0.01,
      shadows: [0.86, 1.0, 1.08], highlights: [1.03, 1.0, 0.94], vignette: 0.38, cx: meta.face.x, cy: meta.face.y });
    C.bloom(cv, { threshold: 0.75, strength: 0.55, radius: 8 });
    const x = C.ctx(cv);
    C.shade(x, 960, 880, 700, 150, 0.55);
    C.place(x, logo.caption('DON’T SPLASH', 23), 960, 870, 1000, 'center');
    return cv;
  },
  'thumb-4-objective': (C, raw, meta, logo) => {
    const cv = C.downscale(raw, 1920, 1080);
    C.grade(cv, { exposure: 1.35, knee: 0.74, gamma: 1.18, contrast: 0.3, pivot: 0.2, saturation: 0.88, lift: 0.008,
      shadows: [0.9, 1.0, 1.08], highlights: [1.05, 1.0, 0.92], vignette: 0.32,
      spot: { x: meta.hood.x, y: meta.hood.y, r: 0.16, gain: 0.55 } });
    C.bloom(cv, { threshold: 0.74, strength: 0.6, radius: 8 });
    const x = C.ctx(cv);
    C.shade(x, 1300, 900, 600, 150, 0.65);
    C.place(x, logo.caption('4-PLAYER CO-OP', 41), 1728, 885, 900, 'right');
    return cv;
  },
  'thumb-5-roof': (C, raw, meta, logo) => {
    const cv = C.downscale(raw, 1920, 1080);
    C.grade(cv, { exposure: 1.15, knee: 0.78, gamma: 1.05, contrast: 0.45, pivot: 0.28, saturation: 1.05, lift: 0.0,
      shadows: [0.86, 0.9, 1.1], highlights: [1.04, 0.98, 1.06], vignette: 0.45, cx: meta.face.x, cy: meta.face.y });
    C.bloom(cv, { threshold: 0.8, strength: 0.45, radius: 12 });
    const x = C.ctx(cv);
    C.shade(x, 960, 880, 640, 150, 0.6);
    C.place(x, logo.caption('ESCAPE', 5), 960, 870, 720, 'center');
    return cv;
  },
};

// ------------------------------------------------------------------------------------------------ main

async function main() {
  fs.mkdirSync(outDir, { recursive: true });
  fs.mkdirSync(cacheDir, { recursive: true });
  const want = (name) => !only || only.has(name);
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader',
    '--ignore-gpu-blocklist', '--enable-webgl', '--autoplay-policy=no-user-gesture-required'] });
  const errors = [];
  try {
    // ---------------------------------------------------------------------------------------- renders
    const shots = SHOTS.filter((s) => want(s.name) || (s.name === 'thumb-1-keyart' && want('logo-on-dark')));
    if (!composeOnly && shots.length) {
      if (!argv.includes('--no-build') || !fs.existsSync(page)) {
        execFileSync(process.execPath, [path.join(here, 'game-build.mjs'), '--out', page], { stdio: 'inherit' });
      }
      const tab = await browser.newPage({ viewport: { width: 1280, height: 720 } });
      await tab.addInitScript(() => {
        Element.prototype.requestPointerLock = function requestPointerLock() {
          return Promise.resolve();
        };
      });
      tab.on('pageerror', (err) => errors.push(`pageerror: ${err.message}`));
      tab.on('console', (m) => {
        if (m.type() === 'error' && !/useProgram|Shader Error|WebGL|GPU stall|AudioContext/.test(m.text())) errors.push(m.text());
      });
      await tab.goto(`file://${page}?dev&seed=${seed}`);
      await tab.waitForFunction(() => window.__rovloc && (window.__rovloc.ready || window.__rovloc.error), null, { timeout: 300000 });
      const bootError = await tab.evaluate(() => window.__rovloc.error);
      if (bootError) throw new Error(`boot failed: ${bootError}`);
      await tab.evaluate(installArt);
      await tab.evaluate(async () => {
        window.__rovlocGame.dev.skipTitle();
        window.__art.ff(0.5);
        return window.__art.freshRun();
      });
      for (const shot of shots) {
        const t0 = Date.now();
        const k = shot.icon ? iconScale : scale;
        const [w, h] = [shot.size[0] * k, shot.size[1] * k];
        await tab.setViewportSize({ width: w, height: h });
        await tab.waitForTimeout(150);
        const res = await tab.evaluate(async ([src]) => {
          const g = window.__rovlocGame;
          const e = window.__rovloc.engine;
          // eslint-disable-next-line no-new-func
          const fn = new Function('art', 'g', 'dev', 'e', 'T', `return (${src})(art, g, dev, e, T);`);
          const meta = await fn(window.__art, g.game, g.dev, e, e.THREE);
          const png = window.__art.capture();
          window.__art.cam(null);
          e.settings.set('BaseFov', 70);
          return { meta, png, internal: e.renderer.stats.internal };
        }, [shot.run.toString()]);
        const file = path.join(cacheDir, `raw-${shot.name}.png`);
        fs.writeFileSync(file, Buffer.from(res.png.split(',')[1], 'base64'));
        fs.writeFileSync(path.join(cacheDir, `raw-${shot.name}.json`), JSON.stringify(res.meta));
        console.log(`render ${shot.name.padEnd(18)} ${res.internal.join('x')}  ${((Date.now() - t0) / 1000).toFixed(1)} s  ${JSON.stringify(res.meta)}`);
      }
      await tab.close();
    }

    // ---------------------------------------------------------------------------------------- composition
    const cpage = path.join(cacheDir, 'compose.html');
    fs.writeFileSync(cpage, '<!doctype html><html><head><meta charset="utf-8"></head><body style="margin:0;background:#000"></body></html>');
    const comp = await browser.newPage({ viewport: { width: 800, height: 600 } });
    comp.on('pageerror', (err) => errors.push(`compose pageerror: ${err.message}`));
    await comp.goto(`file://${cpage}`);
    await comp.evaluate(installComposer);
    for (const [family, file] of [['IDB', 'InterDisplay-Black.otf'], ['IDX', 'InterDisplay-ExtraBold.otf'], ['IDBold', 'InterDisplay-Bold.otf']]) {
      await comp.evaluate(([f, b64]) => window.C.font(f, b64), [family, fs.readFileSync(path.join(FONT_DIR, file)).toString('base64')]);
    }
    // the type kit every composition shares
    await comp.evaluate(() => {
      const C = window.C;
      C.logoSet = {
        big: C.wordmark({ text: 'ROVLOC', size: 300, seed: 7, distress: 1, squeeze: 0.9 }),
        small: C.wordmark({ text: 'ROVLOC', size: 220, seed: 7, distress: 0.8, outline: 0.6, squeeze: 0.9 }),
        tag: C.line({ size: 52, family: 'IDX', track: 1, parts: [{ text: 'Escape the school. ', color: '#e9e1cf' },
          { text: 'Together.', color: '#d4291c' }] }),
        caption: (text, seed) => C.wordmark({ text, size: 260, seed, distress: 0.45, jitter: 0.6, claw: false, stain: 0.2,
          glow: 0.9, outline: 0.85, track: 0.02 }),
      };
      return true;
    });
    const outputs = [];
    const write = (name, dataUrl) => {
      const file = path.join(outDir, name);
      fs.writeFileSync(file, Buffer.from(dataUrl.split(',')[1], 'base64'));
      outputs.push(file);
    };
    // the logo (transparent) and the group banner
    if (want('logo')) {
      write('logo.png', await comp.evaluate(() => window.C.png(window.C.wordmark({ text: 'ROVLOC', size: 420, seed: 7, distress: 1,
        squeeze: 0.9 }))));
    }
    const rawOf = (name) => {
      const file = path.join(cacheDir, `raw-${name}.png`);
      if (!fs.existsSync(file)) return null;
      return { png: `data:image/png;base64,${fs.readFileSync(file).toString('base64')}`,
        meta: JSON.parse(fs.readFileSync(path.join(cacheDir, `raw-${name}.json`), 'utf8')) };
    };
    if (want('logo-on-dark')) {
      const backdrop = rawOf('thumb-1-keyart');
      write('logo-on-dark.png', await comp.evaluate(async (bg) => {
        const C = window.C;
        const cv = C.canvas(1920, 1080);
        const x = C.ctx(cv);
        x.fillStyle = '#060506';
        x.fillRect(0, 0, 1920, 1080);
        if (bg) {
          // the key art's corridor, sunk into the dark behind the type
          const img = await C.image(bg.png);
          const back = C.downscale(img, 1920, 1080);
          C.grade(back, { exposure: 0.55, contrast: 0.2, saturation: 0.6, vignette: 0.9, vignettePower: 1.6 });
          x.filter = 'blur(6px)';
          x.globalAlpha = 0.55;
          x.drawImage(back, 0, 0);
          x.filter = 'none';
          x.globalAlpha = 1;
        }
        C.shade(x, 960, 520, 900, 330, 0.75);
        const L = C.logoSet;
        const box = C.place(x, L.big, 960, 500, 1040, 'center');
        C.place(x, L.tag, 960, box.y + box.h + 92, 760, 'center');
        return C.png(cv);
      }, backdrop));
    }
    for (const name of Object.keys(COMPOSE)) {
      if (!want(name)) continue;
      const raw = rawOf(name);
      if (!raw) {
        console.log(`compose ${name}: no render cached (run without --compose-only)`);
        continue;
      }
      const url = await comp.evaluate(async ([src, r]) => {
        const C = window.C;
        const img = await C.image(r.png);
        // eslint-disable-next-line no-new-func
        const fn = new Function('C', 'raw', 'meta', 'logo', `return (${src})(C, raw, meta, logo);`);
        return C.png(fn(C, img, r.meta, C.logoSet));
      }, [COMPOSE[name].toString(), raw]);
      write(`${name}.png`, url);
      if (name === 'icon-a') write('icon.png', url); // the default icon; icon-b is its A/B rival
    }
    await comp.close();
    for (const f of outputs) console.log(`wrote ${path.relative(path.resolve(web, '..'), f)}`);
  } finally {
    await browser.close();
  }
  if (errors.length) {
    console.log(`page errors (${errors.length}):\n  ${errors.slice(0, 10).join('\n  ')}`);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
