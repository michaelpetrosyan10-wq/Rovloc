// Rovloc Web engine: the public API W3 (creature) and W4 (game) code against.
//
//   const engine = await Engine.create({ root, assets, onProgress });
//   engine.world      decoded data + scene + BVH: raycast(origin, dir, maxDist, {ignoreEntities?}) -> hit | null,
//                     lineClear(a, b) -> boolean, probeAt(pos) -> THREE.Color, zoneAt(pos), levelAt(pos), meta (world.json)
//   engine.player     MoveState machine + meters (stamina / oxygen / battery), pushOverride(token, state) /
//                     popOverride(token), lock(reason) / unlock(reason), teleport(cframe), eye(), look(),
//                     setCameraOverride(token, fn | null, priority), setMode, setMotionOverride, flashlight, panic, ...
//   engine.noise      emit(position, kind, opts) with NoiseConfig radii, on(fn)
//   engine.audio      play(name, {position?, volume?, loop?}) -> handle with stop(fade); setAmbience; 3D panning
//   engine.ui         HUD kit: panels, meters, rings, prompts with hold rings, toasts, captions, key glyphs, fades
//   engine.input      keyboard + pointer lock + gamepad + touch; actions (InputConfig) and contexts
//   engine.prompts    add({position | entity, text, holdSeconds, distance, onTriggered})
//   engine.entities   setPivot(id, cframe), get(id), setNodePivot, setNodeTransform, setVisible, ...
//   engine.quality    tiers Low / Medium / High (+ dynamic resolution)
//   engine.loop       onTick(dt) fixed 30 Hz game logic, onFrame(dt) per render frame
//   engine.save       localStorage JSON with versioning
//   engine.lighting   flicker groups, overrides, bursts, lightning, dynamic lights, the level film
//   engine.settings   the player's settings (SettingsSchema)

import * as THREE from 'three';
import { Audio } from './audio/audio.js';
import { CameraConfig, GameConfig, InputBindings, NoiseConfig, PhysicsConfig, WorldConfig } from './config.js';
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
import { UI } from './ui/ui.js';
import { Volumetrics } from './volumetrics.js';
import { World } from './world.js';

const ZONE_INTERVAL = 0.2; // AudioController: 5 Hz acoustics / ambience
const LEVEL_BEDS = {
  Lobby: 'DroneLobby', Level0_Basement: 'DroneBasement', Level1_Hallways: 'DroneHallways',
  Level2_ScienceHall: 'DroneScience', Level3_Gymnasium: 'DroneGym', Level4_FloodedPool: 'DronePool',
  Level5_Roof: 'DroneRoof', Exterior: 'DroneRoof',
};

/**
 * Inlined assets as build.mjs writes them: base64 gzip of world.json and world.bin, base64 WebP textures keyed by
 * their path relative to build/ ("textures/StainedBrick_color.webp").
 * @typedef {{json: string, bin: string, textures: Record<string, string>}} Assets
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

/** Reads the assets build.mjs inlined into the page (script tags of type application/x-rovloc). */
export function readInlinedAssets(doc = document) {
  const get = (id) => {
    const el = doc.getElementById(id);
    return el ? el.textContent.trim() : null;
  };
  const json = get('rv-world-json');
  const bin = get('rv-world-bin');
  const texIndex = get('rv-textures');
  if (!json || !bin) return null;
  const textures = {};
  if (texIndex) {
    for (const name of JSON.parse(texIndex)) textures[name] = get(`rv-tex:${name}`);
  }
  return { json, bin, textures };
}

/**
 * Decodes the inlined assets into the world data and texture images.
 * @param {Assets} assets
 * @param {(fraction: number, text: string) => void} [progress]
 */
export async function loadAssets(assets, progress = () => {}) {
  progress(0.05, 'Unpacking the building');
  const metaBytes = await gunzip(base64Bytes(assets.json));
  const meta = JSON.parse(new TextDecoder().decode(metaBytes));
  progress(0.15, 'Unpacking the building');
  const bin = await gunzip(base64Bytes(assets.bin));
  progress(0.35, 'Laying the floors');
  const decoded = decodeWorld(meta, bin);
  progress(0.5, 'Painting the walls');
  const images = {};
  const jobs = [];
  for (const [id, t] of Object.entries(meta.textures || {})) {
    images[id] = {};
    for (const [kind, path] of Object.entries(t.maps || {})) {
      const b64 = assets.textures[path];
      if (!b64) continue;
      const blob = new Blob([base64Bytes(b64)], { type: 'image/webp' });
      jobs.push(createImageBitmap(blob, { colorSpaceConversion: 'none', premultiplyAlpha: 'none' })
        .then((bmp) => {
          images[id][kind] = bmp;
        })
        .catch((err) => console.warn('[assets] texture', path, err)));
    }
  }
  await Promise.all(jobs);
  progress(0.6, 'Wiring the lights');
  return { decoded, images };
}

export class Engine {
  /**
   * Builds the engine from inlined assets (or already decoded data).
   * @param {{root: HTMLElement, assets?: Assets, decoded?: any, images?: any, onProgress?: (f: number, t: string) => void}} opts
   */
  static async create(opts) {
    const progress = opts.onProgress || (() => {});
    let decoded = opts.decoded;
    let images = opts.images || {};
    if (!decoded) {
      const assets = opts.assets || readInlinedAssets();
      if (!assets) throw new Error('No world data in this page');
      ({ decoded, images } = await loadAssets(assets, progress));
    }
    const engine = new Engine(opts.root, decoded, images, progress);
    await engine._warmUp(progress);
    return engine;
  }

  constructor(root, decoded, images, progress = () => {}) {
    this.root = root;
    /** The configuration ports (GameConfig, CameraConfig, NoiseConfig, InputBindings, WorldConfig, PhysicsConfig). */
    this.config = { GameConfig, CameraConfig, NoiseConfig, InputBindings, WorldConfig, PhysicsConfig };
    this.THREE = THREE;
    this.save = new Save({ key: 'rovloc.save', version: 1 });
    this.settings = new Settings(this.save);
    this.quality = new Quality(this.settings, this.save);
    this.loop = new Loop();
    this.shared = createSharedUniforms();

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
    this.audio.captioned.connect((text, preset) => {
      const p = this.audio.ready ? preset : '';
      this.ui.caption(text, { danger: /Screech|Lunge|Creature|Growl|Vent(Scrape|Breathing)|NeckSnap/.test(p) });
    });
    this.quality.changed.connect(() => this.world.applyQuality());

    /** The run's current level (W4's LevelDirector writes it); ambience falls back to it outside every room. */
    this.currentLevel = null;
    this.cameraLevel = null;
    this.zoneClock = ZONE_INTERVAL;
    this.showStats = /[?&]stats\b/.test(location.search);
    this.frameMs = 0;
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
    window.addEventListener('keydown', (e) => {
      if (e.code === 'F3') {
        this.showStats = !this.showStats;
        if (!this.showStats) this.ui.setStats('');
      }
    });
    window.addEventListener('pagehide', () => this.save.flush());
  }

  /** Compiles every shader and uploads the level geometry before the first visible frame. */
  async _warmUp(progress) {
    progress(0.85, 'Waking the school');
    const levels = Object.keys(this.world.meta.levels || {});
    this.world.setFocus(levels);
    try {
      await this.renderer.gl.compileAsync(this.world.scene, this.renderer.camera);
    } catch {
      this.renderer.gl.compile(this.world.scene, this.renderer.camera);
    }
    progress(0.95, 'Waking the school');
    this.world.setFocus([]);
  }

  /** Starts the loop (and the frame-time probe that picks the quality tier). */
  start() {
    this.loop.start();
    this.quality.probe((tier) => this.world.applyQuality(tier));
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
    const playerFocus = this.world.focusFor(this.player.rootPosition());
    for (const l of playerFocus) focus.add(l);
    this.world.setFocus(focus);
    this.cameraLevel = this.world.levelAt(camera.position);

    const film = this.lighting.update(realDt, camera.position, this.cameraLevel);
    this._post(film);
    this.volumetrics.update(dt, camera, film, this.world.focus);
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
      { id: 'Battery', label: 'Battery', fraction: m.battery.fraction, color: 'rgb(204,158,88)', active: this.player.flashlight.on },
      { id: 'Stamina', label: 'Stamina', fraction: m.stamina.fraction, color: 'rgb(150,158,132)', active: false },
      { id: 'Oxygen', label: 'Air', fraction: m.oxygen.fraction, color: 'rgb(110,148,160)', active: m.oxygen.rate !== 0 },
    ], this.syringes || 0);
    this.ui.update(realDt);

    this.renderer.render(this.world.scene, { shadow: this.player.flashlight.shadowSpec(), time: this.loop.realTime });
    this.frameMs = performance.now() - t0;
    this.quality.frame(realDt);
    if (this.showStats) {
      const s = this.renderer.stats;
      this.ui.setStats(`${this.quality.fps.toFixed(0)} fps  cpu ${this.frameMs.toFixed(1)} ms\n` +
        `${this.quality.tier} x${this.quality.scale.toFixed(2)} ${s.internal[0]}x${s.internal[1]}\n` +
        `calls ${s.calls}  tris ${(s.triangles / 1000).toFixed(0)}k\n${this.cameraLevel || '-'} ${this.player.moveState}`);
    }
  }

  _post(film) {
    const u = this.renderer.postUniforms;
    const panic = this.player.panic;
    const flash = this.lighting.flash;
    u.uContrast.value = film.contrast + panic.grade.contrast + flash * 0.18;
    u.uSaturation.value = film.saturation + panic.grade.saturation - flash * 0.25;
    u.uLift.value = film.lift + flash * 0.22 * 0.4;
    u.uTint.value.copy(this.lighting.grade).multiply(panic.grade.tint);
    u.uVignette.value = panic.vignette.opacity;
    u.uVignetteDepth.value = panic.vignette.depth;
    u.uGrain.value = this.quality.budget.grain ? 0.035 : 0;
    u.uBloom.value = this.quality.budget.bloom ? film.bloomIntensity * 0.6 : 0;
    u.uBlur.value = this.quality.budget.dof ? panic.panic * 0.6 : 0;
  }

  _acoustics() {
    const p = this.player.rootPosition();
    const zone = this.world.zoneAt(p);
    const state = this.player.moveState;
    let env = zone ? zone.acoustic || 'Room' : 'Outdoor';
    if (state === 'VentCrawling' || state === 'VentScurrying') env = 'Vent';
    if (state === 'Underwater' || state === 'Grabbed') env = 'Underwater';
    this.audio.setZoneEnvironment(env);
    let bed = zone && zone.ambience ? zone.ambience : null;
    if (!bed) bed = LEVEL_BEDS[this.currentLevel || this.world.levelAt(p) || 'Exterior'] || null;
    if (state === 'Underwater' || state === 'Grabbed') bed = 'UnderwaterBed';
    if (this.ambienceEnabled !== false) this.audio.setAmbience(bed);
  }

  /** Turns the automatic ambience beds on / off (title screen, results). */
  setAmbienceEnabled(on) {
    this.ambienceEnabled = !!on;
    if (!on) this.audio.setAmbience(null);
  }
}

const _fwd = new THREE.Vector3();
const _up = new THREE.Vector3();

export { THREE, GameConfig, CameraConfig, NoiseConfig, InputBindings, WorldConfig, PhysicsConfig, FramePriority };
