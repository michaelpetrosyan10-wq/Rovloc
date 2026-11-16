// The engine stand-in the headless Creature tools share (creature-sim.mjs, presence-sim.mjs): the engine pieces that
// hold no GPU or DOM state are the real ones (World with its BVHs and probes, Entities with their colliders and
// attributes, the NoiseBus); the loop, the player, audio, input and UI are stand-ins with the engine's surface, driven
// tick by tick (30 Hz).

import fs from 'node:fs';
import path from 'node:path';
import * as THREE from 'three';
import { decodeWorld } from '../src/engine/data.js';
import { Entities } from '../src/engine/entities.js';
import { createSharedUniforms } from '../src/engine/materials.js';
import { NoiseBus } from '../src/engine/noise.js';
import { World } from '../src/engine/world.js';
import { CreatureConfig } from '../src/creature/config.js';

export const PLAYER_ROOT = 3; // R15 root centre above the floor (HipHeight 2 + half the root)
export const TICK = 1 / 30;

/** world.json and world.bin of a build directory: {meta, decoded}. */
export function loadWorld(buildDir) {
  console.log(`[sim] decoding ${buildDir}`);
  const meta = JSON.parse(fs.readFileSync(path.join(buildDir, 'world.json'), 'utf8'));
  const binBuf = fs.readFileSync(path.join(buildDir, 'world.bin'));
  const decoded = decodeWorld(meta, binBuf.buffer.slice(binBuf.byteOffset, binBuf.byteOffset + binBuf.byteLength));
  return { meta, decoded };
}

export class SimLoop {
  /** @param {number|null} fps a render loop at this rate interleaved with the 30 Hz ticks (null: one frame per tick) */
  constructor(fps = null) {
    this.time = 0;
    this.alpha = 0;
    this.tickDt = TICK;
    this.ticks = [];
    this.frames = [];
    this.fps = fps;
    this.frameAt = 0;
  }

  onTick(fn) {
    this.ticks.push(fn);
    return () => this.ticks.splice(this.ticks.indexOf(fn), 1);
  }

  onFrame(fn) {
    this.frames.push(fn);
    return () => this.frames.splice(this.frames.indexOf(fn), 1);
  }

  /** One fixed tick; with a render rate, the frames that fall before it run first (alpha between the ticks). */
  step() {
    const next = this.time + TICK;
    if (this.fps) {
      while (this.frameAt < next - 1e-9) {
        this.alpha = Math.max(0, (this.frameAt - this.time) / TICK);
        for (const f of this.frames.slice()) f(1 / this.fps, this.alpha);
        this.frameAt += 1 / this.fps;
      }
    }
    this.time = next;
    for (const f of this.ticks.slice()) f(TICK);
    if (!this.fps) for (const f of this.frames.slice()) f(TICK, 1);
  }
}

export class SimPlayer {
  constructor() {
    this.body = { position: new THREE.Vector3(0, -1000, 0) };
    this.moveState = 'Standing';
    this.mode = 'OnFoot';
    this.lifeState = 'Alive';
    this.locks = new Map();
    this.yaw = 0;
    this.pitch = 0;
    this.flashlight = { on: true, setEmfSource: (fn) => { this.emf = fn; } };
    this.panic = { floors: new Map(), setFloor: (t, v) => { if (v == null) this.panic.floors.delete(t); else this.panic.floors.set(t, v); }, setCreatureSource: (fn) => { this.sense = fn; } };
    this.cameraOverrides = new Map();
  }

  lock(reason) {
    this.locks.set(reason, true);
  }

  unlock(reason) {
    this.locks.delete(reason);
  }

  teleport(m) {
    this.body.position.setFromMatrixPosition(m);
    const d = new THREE.Vector3(-m.elements[8], 0, -m.elements[10]);
    if (d.lengthSq() > 1e-6) this.yaw = Math.atan2(-d.x, -d.z);
  }

  eye(out = new THREE.Vector3()) {
    const h = CreatureConfig && { VentCrawling: -0.6, DownedCrawling: -0.8, Hiding: 1.3, Crouching: 0 }[this.moveState];
    return out.copy(this.body.position).add(new THREE.Vector3(0, h ?? 1.5, 0));
  }

  look() {
    const cp = Math.cos(this.pitch);
    return { yaw: this.yaw, pitch: this.pitch, direction: new THREE.Vector3(-Math.sin(this.yaw) * cp, Math.sin(this.pitch), -Math.cos(this.yaw) * cp) };
  }

  setLook(yaw, pitch) {
    this.yaw = yaw;
    this.pitch = pitch;
  }

  /** Turns the view to look straight at `point` from the eye. */
  lookAt(point) {
    const eye = this.eye();
    const d = point.clone().sub(eye);
    this.yaw = Math.atan2(-d.x, -d.z);
    this.pitch = Math.atan2(d.y, Math.hypot(d.x, d.z));
  }

  setLifeState(state) {
    this.lifeState = state;
    this.moveState = state === 'Downed' ? 'DownedCrawling' : this.moveState;
  }

  setCameraOverride(token, fn) {
    if (fn) this.cameraOverrides.set(token, fn);
    else this.cameraOverrides.delete(token);
  }

  surfaceAt() {
    return 'Concrete';
  }

  /** Stands the player on the floor at `floorPoint`. */
  place(floorPoint, mode = 'OnFoot') {
    this.mode = mode;
    if (mode === 'Vent') {
      this.body.position.copy(floorPoint);
      this.moveState = 'VentCrawling';
    } else {
      this.body.position.set(floorPoint.x, floorPoint.y + PLAYER_ROOT, floorPoint.z);
      if (this.moveState === 'VentCrawling') this.moveState = 'Standing';
    }
  }
}

/**
 * An engine with the real World, Entities and NoiseBus over `decoded` and stand-ins for the rest.
 * @param {any} decoded decodeWorld's result @param {number|null} [fps] a render loop at this rate (null: one frame per tick)
 */
export function makeEngine(decoded, fps = null) {
  const shared = createSharedUniforms((decoded.meta.flickerGroups || []).length);
  const quality = { budget: { normalMaps: false, anisotropy: 1, flashlightShadow: false }, changed: { connect() {} } };
  const world = new World(decoded, {}, { shared, quality });
  const engine = { world, shared, loop: new SimLoop(fps), currentLevel: null };
  engine.entities = new Entities(engine);
  engine.noise = new NoiseBus({ loop: engine.loop, world });
  engine.player = new SimPlayer();
  const played = [];
  engine.audio = {
    played,
    play(name, opts = {}) {
      played.push({ name, at: engine.loop.time, position: opts.position ? opts.position.clone() : null });
      return { playing: true, stop() { this.playing = false; }, setVolume() {} };
    },
  };
  engine.lighting = { addLight: () => ({ set() {}, remove() {} }) };
  engine.input = { stack: [], pushContext(token, ctx) { this.stack.push([token, ctx]); }, popContext(token) { this.stack = this.stack.filter((e) => e[0] !== token); } };
  engine.ui = { hudTarget: 1, setVisible(v) { this.hudTarget = v ? 1 : 0; }, root: null };
  engine.settings = { get: () => 1 };
  const camera = new THREE.PerspectiveCamera(70, 16 / 9, 0.1, 1000);
  engine.renderer = { camera };
  engine.loop.onFrame(() => {
    engine.player.eye(camera.position);
    camera.lookAt(camera.position.clone().add(engine.player.look().direction));
    camera.updateMatrixWorld();
  });
  return engine;
}
