// Rovloc Web engine: the public API W3 (creature) and W4 (game) code against.
//
//   const engine = await Engine.create({ root, assets, onProgress });
//   engine.world      decoded data + scene + BVH: raycast(origin, dir, maxDist, {ignoreEntities?}) -> hit | null,
//                     lineClear(a, b) -> boolean, probeAt(pos) -> THREE.Color, zoneAt(pos), levelAt(pos), meta (world.json)
//   engine.player     MoveState machine + meters (stamina / battery), pushOverride(token, state) /
//                     popOverride(token), lock(reason) / unlock(reason), teleport(cframe), eye(), look(),
//                     setCameraOverride(token, fn | null, priority), setMode, setMotionOverride, flashlight, panic, ...
//                     The body moves on the 30 Hz tick (2 substeps of 1/60 s); rootPosition() is the tick state and
//                     drawnRoot the root drawn this frame (interpolated between the last two ticks by loop.alpha).
//   engine.noise      emit(position, kind, opts) with NoiseConfig radii, on(fn)
//   engine.audio      play(name, {position?, volume?, loop?}) -> handle with stop(fade); setAmbience; 3D panning
//   engine.ui         HUD kit: panels, meters, rings, prompts with hold rings, toasts, captions, key glyphs, fades
//   engine.input      keyboard + pointer lock + gamepad + touch; actions (InputConfig) and contexts
//   engine.prompts    add({position | entity, text, holdSeconds, distance, onTriggered})
//   engine.entities   setPivot(id, cframe), get(id), setNodePivot, setNodeTransform, setVisible, ...
//   engine.quality    graphics tiers Max / High / Medium / Low / Potato (the Graphics setting; + dynamic resolution)
//   engine.textures   the tier's texture set, streamed in the background (textures.js)
//   engine.particles  GPU particles: steam vents, drips, ceiling grit, torch motes (particles.js)
//   engine.loop       onTick(dt) fixed 30 Hz game logic (and the player's body), onFrame(dt) per render frame
//   engine.save       localStorage JSON with versioning
//   engine.lighting   flicker groups, overrides, bursts, lightning, dynamic lights, the level film
//   engine.settings   the player's settings (SettingsSchema)
//   engine.buildStamp the build's stamp ("BETA 10 NOV": build.mjs --stamp), '' on a build without one

import * as THREE from 'three';
import { Audio } from './audio/audio.js';
import { CameraConfig, GameConfig, InputBindings, NoiseConfig, PhysicsConfig, WorldConfig, installInputBindings,
  installSettings } from './config.js';
import { decodeWorld } from './data.js';
import { Entities } from './entities.js';
import { Input } from './input.js';
import { Lighting } from './lighting.js';
import { FramePriority, Loop } from './loop.js';
import { createSharedUniforms } from './materials.js';
import { NoiseBus } from './noise.js';
import { Player } from './player.js';
import { Prompts } from './prompts.js';
import { Quality } from './quality.js';
import { Renderer } from './renderer.js';
import { Save } from './save.js';
import { Settings } from './settings.js';
import { Particles } from './particles.js';
import { Sky } from './sky.js';
import { STRINGS, formatTime, getString } from './strings.js';
import { TextureStreamer, decodeImage } from './textures.js';
import { UI } from './ui/ui.js';
import { Volumetrics } from './volumetrics.js';
import { World } from './world.js';

const ZONE_INTERVAL = 0.2; // AudioController: 5 Hz acoustics / ambience
const LEVEL_BEDS = {
  Lobby: 'DroneLobby', Level0_Basement: 'DroneBasement', Level1_Hallways: 'DroneHallways',
  Level2_Auditorium: 'DroneHallways', Level3_Roof: 'DroneRoof', Exterior: 'DroneRoof',
};

/**
 * The page's assets as build.mjs describes them: the asset manifest (an inline JSON script `rv-manifest`). Every
 * reference is a URL of the site's hashed assets/ or `inline:<script id>` (base64 in a non-executed script tag of a
 * single-file build):
 *   world.json / world.bin            gzip
 *   textures.boot                     the set the page boots with (256: the Potato colour maps)
 *   textures.sets[size].maps[id][kind] every surface texture per size (2048, 1024, 512, 256); `inline` sets came with the page
 *   textures.atlases[id].color        the decal and wear atlases (every tier)
 *   defaultTier                       the Graphics tier a player without a saved choice starts on (the lite build)
 *   stamp                             the build's stamp, shown on the title screen (a beta build)
 * @typedef {{version: number, world: {json: string, bin: string}, textures: any, defaultTier?: string, stamp?: string}} Manifest
 */

/** Base64 -> bytes. */
export function base64Bytes(b64) {
  if (Uint8Array.fromBase64) return Uint8Array.fromBase64(b64);
  const s = atob(b64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

/** Gunzips bytes with the browser's DecompressionStream. */
export async function gunzip(bytes) {
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
  return new Response(stream).arrayBuffer();
}

/** The asset manifest build.mjs wrote into the page (null when there is none). */
export function readManifest(doc = document) {
  const el = doc.getElementById('rv-manifest');
  if (!el) return null;
  try {
    return JSON.parse(el.textContent);
  } catch {
    return null;
  }
}

/**
 * The bytes of one asset reference: an inline script's base64, or a fetch of the site's asset (reporting bytes as
 * they arrive).
 */
export async function assetBytes(ref, onBytes = null) {
  if (ref.startsWith('inline:')) {
    const el = document.getElementById(ref.slice(7));
    if (!el) throw new Error(`missing inline asset ${ref}`);
    return base64Bytes(el.textContent.trim());
  }
  const res = await fetch(ref);
  if (!res.ok) throw new Error(`${ref}: HTTP ${res.status}`);
  if (!onBytes || !res.body) return new Uint8Array(await res.arrayBuffer());
  const reader = res.body.getReader();
  const parts = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    parts.push(value);
    total += value.length;
    onBytes(value.length);
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

/**
 * Loads the world (gzip JSON + binary streams) and the boot texture set through the manifest.
 * @param {Manifest} manifest
 * @param {(fraction: number, text: string) => void} [progress]
 */
export async function loadAssets(manifest, progress = () => {}) {
  if (!manifest || !manifest.world) throw new Error('No world data in this page');
  const sizes = manifest.world.bytes || {};
  const expected = (sizes.json || 0) + (sizes.bin || 0);
  let received = 0;
  const onBytes = expected > 0 ? (n) => {
    received += n;
    progress(0.02 + 0.33 * Math.min(1, received / expected), getString('Boot.Receiving', Math.round(Math.min(1, received / expected) * 100)));
  } : null;
  progress(0.02, 'Unpacking the building');
  const [jsonGz, binGz] = await Promise.all([assetBytes(manifest.world.json, onBytes), assetBytes(manifest.world.bin, onBytes)]);
  const meta = JSON.parse(new TextDecoder().decode(await gunzip(jsonGz)));
  const bin = await gunzip(binGz);
  progress(0.38, 'Laying the floors');
  const decoded = decodeWorld(meta, bin);
  progress(0.5, 'Painting the walls');
  const images = {};
  const jobs = [];
  const tex = manifest.textures || {};
  const boot = tex.sets && tex.sets[String(tex.boot)];
  const want = { ...(boot ? boot.maps : {}), ...(tex.atlases || {}) };
  for (const [id, maps] of Object.entries(want)) {
    images[id] = {};
    for (const [kind, ref] of Object.entries(maps)) {
      // flipped at decode: the data's UVs assume three's default flipY upload, which ImageBitmaps ignore
      jobs.push(assetBytes(ref).then((bytes) => decodeImage(new Blob([bytes], { type: 'image/webp' })))
        .then((bmp) => {
          images[id][kind] = bmp;
        })
        .catch((err) => console.warn('[assets] texture', ref, err)));
    }
  }
  await Promise.all(jobs);
  progress(0.6, 'Wiring the lights');
  return { decoded, images, bootSize: Number(tex.boot) || 0 };
}

export class Engine {
  /**
   * Builds the engine from the page's assets (the manifest), or already decoded data.
   * @param {{root: HTMLElement, manifest?: Manifest, decoded?: any, images?: any, onProgress?: (f: number, t: string) => void}} opts
   */
  static async create(opts) {
    const progress = opts.onProgress || (() => {});
    let decoded = opts.decoded;
    let images = opts.images || {};
    const manifest = opts.manifest || readManifest();
    let bootSize = 0;
    if (!decoded) ({ decoded, images, bootSize } = await loadAssets(manifest, progress));
    const engine = new Engine(opts.root, decoded, images, progress, { manifest, bootSize });
    await engine._warmUp(progress);
    return engine;
  }

  constructor(root, decoded, images, progress = () => {}, assets = {}) {
    this.root = root;
    // the world's input actions and settings (meta.inputConfig, meta.settingsSchema), before anything reads them
    installInputBindings(decoded.meta);
    installSettings(decoded.meta);
    /** The configuration ports (GameConfig, CameraConfig, NoiseConfig, InputBindings, WorldConfig, PhysicsConfig). */
    this.config = { GameConfig, CameraConfig, NoiseConfig, InputBindings, WorldConfig, PhysicsConfig };
    this.THREE = THREE;
    /** Strings.get(key, ...): every player-facing string of the Roblox game. */
    this.strings = { get: getString, formatTime, all: STRINGS };
    this.save = new Save({ key: 'rovloc.save', version: 1 });
    this.settings = new Settings(this.save);
    // a build may name the tier a player without a saved choice starts on (the offline lite build: Potato)
    const stored = this.save.get('settings', {}) || {};
    if (assets.manifest && assets.manifest.defaultTier && stored.Graphics === undefined && stored.Quality === undefined) {
      this.settings.values.Graphics = Settings.sanitize('Graphics', assets.manifest.defaultTier) || this.settings.values.Graphics;
    }
    this.quality = new Quality(this.settings, this.save);
    /** The build's stamp ("BETA 10 NOV"), which the title screen shows; '' on a build without one. */
    this.buildStamp = assets.manifest && typeof assets.manifest.stamp === 'string' ? assets.manifest.stamp : '';
    this.loop = new Loop();
    this.shared = createSharedUniforms((decoded.meta.flickerGroups || []).length);

    this.canvas = document.createElement('canvas');
    this.canvas.className = 'rv-canvas';
    root.prepend(this.canvas);
    this.renderer = new Renderer(this.canvas, this.quality, this.shared);
    this.input = new Input(root);
    this.ui = new UI(root, { input: this.input, settings: this.settings, quality: this.quality });
    progress(0.65, 'Wiring the lights');
    this.world = new World(decoded, images, { shared: this.shared, quality: this.quality });
    progress(0.75, 'Building the doors');
    this.entities = new Entities(this);
    this.audio = new Audio({ settings: this.settings });
    this.noise = new NoiseBus({ loop: this.loop, world: this.world });
    this.lighting = new Lighting(this);
    this.player = new Player(this);
    this.prompts = new Prompts(this);
    this.volumetrics = new Volumetrics(this);
    this.sky = new Sky(this);
    this.particles = new Particles(this);
    this.audio.captioned.connect((text, preset) => {
      const p = this.audio.ready ? preset : '';
      this.ui.caption(text, { danger: /Screech|Lunge|Creature|Growl|Vent(Scrape|Breathing)|NeckSnap/.test(p) });
    });
    /** the tier's texture set, streamed in the background */
    this.textures = new TextureStreamer(this.world, assets.manifest ? assets.manifest.textures : null, assets.bootSize || 0);
    this.quality.changed.connect((budget) => {
      this.world.applyQuality();
      this.textures.want(budget.textureSize);
    });
    // the Auto hint: a low frame rate suggests Potato once; the tier stays what the player chose
    this.quality.hinted.connect((tier) => {
      this.ui.toast(`Running slowly? Try Graphics: ${tier} (${getString(`Settings.Graphics.${tier}.Info`).split(':')[0]}), in the menu.`, { seconds: 9 });
    });

    /** The run's current level (W4's LevelDirector writes it); ambience falls back to it outside every room. */
    this.currentLevel = null;
    this.cameraLevel = null;
    this.zoneClock = ZONE_INTERVAL;
    this.showStats = /[?&]stats\b/.test(location.search);
    this.frameMs = 0;
    /** Verification only: simulate frames without drawing them (headless software GL is slow). */
    this.skipRender = false;
    this._viewport = { width: 1, height: 1 };

    this.loop.onTick((dt) => this.player.tick(dt), FramePriority.Logic);
    this.loop.onFrame((dt, realDt) => this._frame(dt, realDt ?? dt), FramePriority.Render);
    this.input.on('Menu', (phase) => {
      if (phase !== 'Begin') return;
      if (this.ui.menuOpen) this.ui.closeMenu();
      else if (this.menuEnabled) this.ui.openMenu();
    });
    this.menuEnabled = true;
    this.ui.setMenuButtons([{ label: 'Resume', onClick: () => this.ui.closeMenu() }]);
    // the stats overlay is a dev tool: F3 toggles it only with ?dev or ?stats in the URL (production shows none)
    const statsKey = /[?&](dev|stats)\b/.test(location.search);
    window.addEventListener('keydown', (e) => {
      if (e.code === 'F3' && statsKey) {
        this.showStats = !this.showStats;
        if (!this.showStats) this.ui.setStats('');
      }
    });
    window.addEventListener('pagehide', () => this.save.flush());
  }

  /** Compiles every shader and uploads the level geometry before the first visible frame. */
  async _warmUp(progress) {
    progress(0.8, 'Waking the school');
    // zone culling: every static chunk sorted by the zone it faces (visual only)
    this.world.enableZoneCulling();
    progress(0.85, 'Waking the school');
    const levels = Object.keys(this.world.meta.levels || {});
    this.world.setFocus(levels);
    const gl = this.renderer.gl;
    if (gl.extensions.has('KHR_parallel_shader_compile')) await gl.compileAsync(this.world.scene, this.renderer.camera);
    else gl.compile(this.world.scene, this.renderer.camera);
    progress(0.95, 'Waking the school');
    this.world.setFocus([]);
  }

  /** Starts the loop and asks for the tier's texture set (it streams in the background). */
  start() {
    this.loop.start();
    this.textures.want(this.quality.budget.textureSize);
  }

  /** Sets the run's current level (ambience fallback, W4's LevelDirector). */
  setCurrentLevel(level) {
    this.currentLevel = level;
  }

  /** Spawn anchors of a level (or the lobby). */
  spawnPoints(level) {
    return this.world.meta.anchors.filter((a) => a.kind === 'PlayerSpawn' && a.level === level);
  }

  _frame(dt, realDt) {
    const t0 = performance.now();
    const camera = this.renderer.camera;
    this.input.pollGamepads();
    this.input.setPointerLockWanted(this.player.cameraEnabled && !this.ui.menuOpen);
    this.player.frame(dt, camera);

    // level focus follows the camera (spectating and cutscene cameras included)
    const focus = this.world.focusFor(camera.position);
    const playerFocus = this.world.focusFor(this.player.drawnRoot);
    for (const l of playerFocus) focus.add(l);
    this.world.setFocus(focus);
    this.cameraLevel = this.world.levelAt(camera.position);
    // the zones the camera can see (visual only: what is drawn, never what collides)
    const seen = this.world.updateVisibility(camera.position);

    const film = this.lighting.update(realDt, camera.position, this.cameraLevel);
    this._post(film);
    this.volumetrics.update(dt, camera, film, this.world.focus, seen);
    this.particles.update(realDt, camera, film, seen);
    this.sky.update(camera, this.world.focus, film);
    this.textures.frame();
    this._viewport.width = this.renderer.width;
    this._viewport.height = this.renderer.height;
    this.prompts.update(dt, camera, this._viewport);
    this.entities.flush();

    // acoustics + ambience at 5 Hz (AudioController)
    this.zoneClock += realDt;
    if (this.zoneClock >= ZONE_INTERVAL) {
      this.zoneClock = 0;
      this._acoustics();
    }
    camera.getWorldDirection(_fwd);
    _up.set(0, 1, 0).applyQuaternion(camera.quaternion);
    this.audio.update(realDt, camera.position, _fwd, _up);

    const m = this.player.meters;
    this.ui.updateStatus(realDt, [
      { id: 'Battery', label: getString('Hud.Battery'), fraction: m.battery.fraction, color: 'rgb(204,158,88)', active: this.player.flashlight.on },
      { id: 'Stamina', label: getString('Hud.Stamina'), fraction: m.stamina.fraction, color: 'rgb(150,158,132)', active: false },
    ]);
    this.ui.update(realDt);

    if (!this.skipRender) {
      const budget = this.quality.budget;
      const fixtures = budget.fixtureShadows > 0
        ? this.lighting.shadowFixtures(this.world.dynamicCasters, camera.position, budget.fixtureShadows) : null;
      this.renderer.render(this.world.scene, {
        shadow: this.player.flashlight.shadowSpec(), time: this.loop.realTime, fixtures,
        haze: film.density * 0.02, clear: this.lighting.displayFog(_clear),
      });
    }
    this.frameMs = performance.now() - t0;
    this.quality.frame(realDt);
    if (this.showStats) {
      const s = this.renderer.stats;
      const c = this.world.culling ? this.world.culling.stats : null;
      this.ui.setStats(`${this.quality.fps.toFixed(0)} fps  cpu ${this.frameMs.toFixed(1)} ms\n` +
        `${this.quality.tier} x${this.quality.scale.toFixed(2)} ${s.internal[0]}x${s.internal[1]}  tex ${this.textures.current}\n` +
        `calls ${s.calls}  tris ${(s.triangles / 1000).toFixed(0)}k  ${s.passes}\n` +
        `pvs ${c && c.level ? `${c.zone} ${c.visibleZones} zones` : 'off'}\n${this.cameraLevel || '-'} ${this.player.moveState}`);
    }
  }

  _post(film) {
    const u = this.renderer.postUniforms;
    const panic = this.player.panic;
    const flash = this.lighting.flash;
    u.uContrast.value = film.contrast + panic.grade.contrast + flash * 0.18;
    u.uSaturation.value = film.saturation + panic.grade.saturation - flash * 0.25;
    u.uLift.value = film.lift + flash * 0.22 * 0.4;
    u.uTint.value.copy(this.lighting.grade);
    u.uPanicTint.value.copy(panic.grade.tint);
    const budget = this.quality.budget;
    // Potato's flat grade (GraphicsConfig flatGrade): the film's colour look goes, its brightness stays: the post keeps
    // the luminance the area tint gives each pixel without its cast, and the film's saturation is dropped (panic's own
    // grade is kept)
    const flat = budget.tier === 'Potato';
    u.uFlat.value = flat ? 1 : 0;
    if (flat) u.uSaturation.value = panic.grade.saturation - flash * 0.25;
    u.uVignette.value = panic.vignette.opacity;
    u.uVignetteDepth.value = panic.vignette.depth;
    u.uGrain.value = budget.grain || 0;
    u.uBloom.value = budget.bloom ? film.bloomIntensity * 0.6 : 0;
    u.uBlur.value = budget.dof ? panic.panic * 0.6 : 0;
  }

  _acoustics() {
    const p = this.player.rootPosition();
    const zone = this.world.zoneAt(p);
    const state = this.player.moveState;
    let env = zone ? zone.acoustic || 'Room' : 'Outdoor';
    if (state === 'VentCrawling' || state === 'VentScurrying') env = 'Vent';
    this.audio.setZoneEnvironment(env);
    let bed = zone && zone.ambience ? zone.ambience : null;
    if (!bed) bed = LEVEL_BEDS[this.currentLevel || this.world.levelAt(p) || 'Exterior'] || null;
    if (this.ambienceEnabled !== false) this.audio.setAmbience(bed);
  }

  /**
   * Renders one frame now and reads the canvas back: mean luminance (0..255) and the share of pixels brighter
   * than 10/255 (verification: the world renders, not a black screen).
   */
  measure() {
    const skip = this.skipRender;
    this.skipRender = false;
    this.loop.stepManual(1 / 30);
    this.skipRender = skip;
    const gl = this.renderer.gl.getContext();
    const w = gl.drawingBufferWidth;
    const h = gl.drawingBufferHeight;
    const px = new Uint8Array(w * h * 4);
    gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, px);
    let sum = 0;
    let lit = 0;
    for (let i = 0; i < px.length; i += 4) {
      const l = 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2];
      sum += l;
      if (l > 10) lit++;
    }
    const n = w * h;
    return { width: w, height: h, mean: sum / n, litShare: lit / n };
  }

  /** Turns the automatic ambience beds on / off (title screen, results). */
  setAmbienceEnabled(on) {
    this.ambienceEnabled = !!on;
    if (!on) this.audio.setAmbience(null);
  }
}

const _fwd = new THREE.Vector3();
const _up = new THREE.Vector3();
const _clear = new THREE.Color();

export { THREE, GameConfig, CameraConfig, NoiseConfig, InputBindings, WorldConfig, PhysicsConfig, FramePriority };
export { STRINGS, getString, formatTime };

// Building blocks for W3 / W4 (node batching for the creature rig, CFrame helpers, the shared maths and signals).
export { NodeTable } from './batch.js';
export { Signal } from './signal.js';
export { emfIntensity, flickerFactor as torchFlicker, Cones as TorchCones } from './flashlight.js';
export { proximity as panicProximity } from './panic.js';
export { attenuation as rollOffAttenuation } from './audio/audio.js';
export { CameraStates, CameraStack, ViewBob, OverridePriority as CameraOverridePriority } from './camera.js';
export { flashlightTarget } from './viewmodel.js';
export * as MathUtil from './math.js';
