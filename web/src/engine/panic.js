// PanicVFX: the local player's panic level (0..1) and everything it drives (PanicVFX.luau).
//
// Target panic = clamp01(max(proximity, chase floor, external floors) + downed bonus):
//   * proximity: the Creature (from the creature source W3 registers; ignored while Dormant or hidden) between
//     CreatureNearDistance (1) and CreatureFarDistance (0) on a smoothstep, full with line of sight from my eye to its
//     eye, OccludedShare of it through walls. Sensed at 10 Hz.
//   * chase floor: the Creature targets me in WallChase / VentChase.
//   * floors: setFloor(token, value) from later systems (struggles, scripted beats); the highest wins.
//   * Downed: +DownedBonus.
// Panic rises at RiseSpeed / falls at FallSpeed per second. Outputs: the post grade (saturation, contrast, red tint),
// the vignette (rests at the level film's vignette, closes in with panic, throbs with the heartbeat), the FOV bonus
// and heartbeat warp, and the Body-bus loops (Heartbeat / HeartbeatFast, Breathing / BreathingPanic with
// hysteresis; breathing follows the higher of panic and exertion and is silenced while a held breath suppresses it).

import * as THREE from 'three';
import { CameraConfig } from './config.js';
import { approach, clamp01, lerp, smoothstep } from './math.js';

const Panic = CameraConfig.Panic;
export const OccludedShare = 0.3;
export const DownedBonus = 0.4;
const SENSE_HZ = 10;
const HEART_SLOW = 0.25;
const HEART_FAST = 0.62;
const BREATH_SLOW = 0.18;
const BREATH_FAST = 0.55;
const HYSTERESIS = 0.06;
const HEART_SLOW_PERIOD = 0.92;
const HEART_FAST_PERIOD = 0.43;
const LOOP_FADE_IN = 0.8;
const LOOP_FADE_OUT = 1.2;
const VOLUME_EPSILON = 0.03;
const REST_VIGNETTE = 0.28;
const VIGNETTE_REST_DEPTH = 0.2;
const VIGNETTE_FULL_DEPTH = 0.42;
const PULSE_OPACITY = 0.12;
const WARP_DEGREES = 1.4;

export function proximity(distance, visible) {
  if (!Number.isFinite(distance)) return 0;
  const raw = 1 - smoothstep(Panic.CreatureNearDistance, Panic.CreatureFarDistance, distance);
  return visible ? raw : raw * OccludedShare;
}

export function panicTarget({ proximity: p, chased, floor, downed }) {
  let level = Math.max(p, chased ? Panic.ChaseFloor : 0, floor);
  if (downed) level += DownedBonus;
  return clamp01(level);
}

export function integrate(current, target, dt) {
  const rate = target > current ? Panic.RiseSpeed : Panic.FallSpeed;
  return clamp01(approach(current, target, rate * Math.max(dt, 0)));
}

export function vignetteOpacity(panic, pulse, flashScale, rest) {
  const p = clamp01(panic);
  const full = 1 - Panic.VignetteTransparencyAtFull;
  const base = lerp(clamp01(rest ?? REST_VIGNETTE), full, p);
  return clamp01(base + PULSE_OPACITY * p * clamp01(pulse) * clamp01(flashScale));
}

export function heartbeatPreset(panic, current) {
  const fast = current === 'HeartbeatFast' ? HEART_FAST - HYSTERESIS : HEART_FAST;
  const slow = current ? HEART_SLOW - HYSTERESIS : HEART_SLOW;
  if (panic >= fast) return 'HeartbeatFast';
  if (panic >= slow) return 'Heartbeat';
  return null;
}

export function breathingPreset(level, current) {
  const fast = current === 'BreathingPanic' ? BREATH_FAST - HYSTERESIS : BREATH_FAST;
  const slow = current ? BREATH_SLOW - HYSTERESIS : BREATH_SLOW;
  if (level >= fast) return 'BreathingPanic';
  if (level >= slow) return 'Breathing';
  return null;
}

/** Heartbeat pulse 0..1 at `phase` (beats): a sharp lub and a softer dub. */
export function pulse(phase) {
  const p = phase % 1;
  const lub = Math.exp(-(((p - 0.05) / 0.06) ** 2));
  const dub = 0.6 * Math.exp(-(((p - 0.33) / 0.07) ** 2));
  return Math.max(lub, dub);
}

/**
 * @typedef {Object} CreatureSample what the creature source reports each sense tick
 * @property {THREE.Vector3} eye the Creature's eye point (world)
 * @property {string} state MonsterState (Dormant, Patrol, WallChase, VentChase, ...)
 * @property {boolean} hidden Hidden attribute (vanished / staged out of sight)
 * @property {boolean} targetingMe the Creature's target is the local player
 */

export class PanicFx {
  /** @param {{world: any, audio: any}} deps */
  constructor(deps) {
    this.world = deps.world;
    this.audio = deps.audio;
    this.panic = 0;
    /** @type {Map<string, number>} */
    this.floors = new Map();
    /** @type {Set<string>} */
    this.breathHeld = new Set();
    this.proximity = 0;
    this.chased = false;
    this.senseClock = Infinity;
    this.heartPhase = 0;
    this.heart = { preset: null, voice: null, volume: 0 };
    this.breath = { preset: null, voice: null, volume: 0 };
    /** @type {(() => CreatureSample|null)|null} */
    this.creatureSource = null;
    this.vignette = { opacity: REST_VIGNETTE, depth: VIGNETTE_REST_DEPTH };
    this.grade = { saturation: 0, contrast: 0, tint: new THREE.Color(1, 1, 1) };
  }

  /** W3 registers how the Creature is sensed (nil removes it). */
  setCreatureSource(fn) {
    this.creatureSource = fn || null;
  }

  setFloor(token, value) {
    if (value == null || !Number.isFinite(value)) this.floors.delete(token);
    else this.floors.set(token, clamp01(value));
  }

  clearFloors() {
    this.floors.clear();
  }

  setBreathSuppressed(token, suppressed) {
    if (suppressed) this.breathHeld.add(token);
    else this.breathHeld.delete(token);
  }

  sense(dt, eye) {
    this.senseClock += dt;
    if (this.senseClock < 1 / SENSE_HZ) return;
    this.senseClock = 0;
    this.proximity = 0;
    this.chased = false;
    const sample = this.creatureSource ? this.creatureSource() : null;
    if (!sample) return;
    this.chased = !!sample.targetingMe && (sample.state === 'WallChase' || sample.state === 'VentChase');
    if (!eye || sample.state === 'Dormant' || sample.hidden || !sample.eye) return;
    const distance = sample.eye.distanceTo(eye);
    if (distance >= Panic.CreatureFarDistance) return;
    const visible = this.world.lineClear(eye, sample.eye, { ignoreEntities: false });
    this.proximity = proximity(distance, visible);
  }

  step(dt, downed) {
    let floor = 0;
    for (const v of this.floors.values()) floor = Math.max(floor, v);
    const target = panicTarget({ proximity: this.proximity, chased: this.chased, floor, downed });
    this.panic = integrate(this.panic, target, dt);
    const period = this.panic >= HEART_FAST ? HEART_FAST_PERIOD : HEART_SLOW_PERIOD;
    this.heartPhase = (this.heartPhase + dt / period) % 1;
    return this.panic;
  }

  fovBonus(motionScale) {
    return CameraConfig.FieldOfView.PanicMaxBonus * clamp01(this.panic) * clamp01(motionScale);
  }

  fovWarp(motionScale) {
    return WARP_DEGREES * this.panic * pulse(this.heartPhase) * clamp01(motionScale);
  }

  /**
   * Updates grade / vignette / loops.
   * @param {{visible: boolean, flashScale: number, exertion: number, restVignette: number}} ctx
   */
  apply(ctx) {
    const p = ctx.visible ? this.panic : 0;
    this.grade.saturation = Panic.Saturation * p;
    this.grade.contrast = Panic.Contrast * p;
    const t = Panic.TintRed;
    this.grade.tint.setRGB(lerp(1, t[0] / 255, p), lerp(1, t[1] / 255, p), lerp(1, t[2] / 255, p));
    this.vignette.opacity = vignetteOpacity(p, pulse(this.heartPhase), ctx.flashScale, ctx.restVignette);
    this.vignette.depth = lerp(VIGNETTE_REST_DEPTH, VIGNETTE_FULL_DEPTH, p);
    const breathless = Math.max(p, ctx.visible ? clamp01(ctx.exertion) : 0);
    this._drive(this.heart, ctx.visible ? heartbeatPreset(p, this.heart.preset) : null, 0.35 + 0.65 * p);
    const wantBreath = ctx.visible && this.breathHeld.size === 0 ? breathingPreset(breathless, this.breath.preset) : null;
    this._drive(this.breath, wantBreath, 0.3 + 0.7 * breathless);
  }

  _drive(loop, want, volume) {
    if (!this.audio) return;
    if (!want) {
      if (loop.voice) loop.voice.stop(LOOP_FADE_OUT);
      loop.voice = null;
      loop.preset = null;
      return;
    }
    if (loop.preset !== want || !loop.voice || !loop.voice.playing) {
      if (loop.voice) loop.voice.stop(LOOP_FADE_OUT * 0.5);
      loop.preset = want;
      loop.volume = volume;
      loop.voice = this.audio.play(want, { loop: true, fadeIn: LOOP_FADE_IN, volume });
      return;
    }
    if (Math.abs(loop.volume - volume) > VOLUME_EPSILON) {
      loop.volume = volume;
      loop.voice.setVolume(volume, 0.4);
    }
  }

  stopLoops() {
    this._drive(this.heart, null, 0);
    this._drive(this.breath, null, 0);
  }
}
