// Flashlight: the local dual-cone torch, its battery, and EMF interference (Flashlight.luau + FlashlightService).
//
// Beam. Two spot cones from just ahead of the eye (BEAM_OFFSET: right and low, so nothing of the player's own body
// can shadow it): the inner cone (38 deg, range 60, brightness 9, shadowed on Medium / High) and the outer cone
// (80 deg, range 48, brightness 2.2). Its orientation chases the look with a damped slerp, pitched down while the
// torch is lowered for sprinting. A faint visible shaft in the haze shows on Medium / High (film shafts permitting):
// like the Roblox HazeCore / HazeSheath, two camera-facing additive ribbons 34 studs long, clear at the lens.
// The presence glow (range 10, brightness 0.45, cold) is always on around the player.
// Switch. Toggle needs a charged cell (a dead cell only clicks); every toggle plays UiClick; toggles are spaced at
// least TOGGLE_COOLDOWN apart.
// Battery (FlashlightService): drains BatteryDrain per second while lit; at 0 the light goes out. Full brightness
// down to LowBattery (15 %), then dimming and warming toward a dying orange, with a sputter in the last 5 %.
// EMF. A source W3 registers reports the Creature's interference 0..1 at the torch (emfIntensity helps compute it:
// 45 studs, full inside 15 %, at least 0.55 from an adjacent wall vent); the light flickers with value noise and
// seeded dropouts (scaled by the FlashScale setting) and an EmfStatic loop plays on the Body bus.

import * as THREE from 'three';
import { GameConfig } from './config.js';
import { clamp01, damp, hash, lerp, noise1, smoothstep } from './math.js';

export const EmfRadius = 45; // CreatureConfig.Senses.EmfRadius
export const VentAdjacentIntensity = 0.55;
export const LowBattery = 0.15;
const EMF_FULL_SHARE = 0.15;
const NOISE_PERIOD = 4096;
const FLICKER_BASE_HZ = 5;
const FLICKER_EXTRA_HZ = 16;
const DROPOUT_HZ = 9;
const DROPOUT_CHANCE = 0.42;
const DROPOUT_LEVEL = 0.04;
const LOW_FLOOR = 0.3;
const SPUTTER_BELOW = 0.05;
const STATIC_THRESHOLD = 0.04;
const STATIC_VOLUME_EPSILON = 0.04;

export const Cones = Object.freeze({
  innerAngle: 38,
  innerRange: 60,
  innerBrightness: 9,
  outerAngle: 80,
  outerRange: 48,
  outerBrightness: 2.2,
  offset: [0.3, -0.25, -0.6],
});
const GLOW_RANGE = 10;
const GLOW_BRIGHTNESS = 0.45;
const GLOW_COLOR = [176, 190, 214];
const BEAM_COLOR = new THREE.Color().setRGB(255 / 255, 233 / 255, 202 / 255, THREE.SRGBColorSpace);
const DYING_COLOR = new THREE.Color().setRGB(255 / 255, 176 / 255, 112 / 255, THREE.SRGBColorSpace);
const LAG_SPEED = 16;
const LOWERED_PITCH = (7 * Math.PI) / 180;
const TOGGLE_COOLDOWN = 0.22;
const HAZE_LENGTH = 34;
const HAZE_CORE_OPACITY = 0.035;
const HAZE_SHEATH_OPACITY = 0.018;
const HAZE_SEGMENTS = 8;
const HAZE_BRIGHTNESS = 1.2;
/** Roblox light Brightness -> the shader's linear light units (the bake uses the same scale). */
export const BRIGHTNESS_UNIT = 1;

export function emfIntensity(distance, radius = EmfRadius, ventAdjacent = false) {
  let level = 0;
  if (Number.isFinite(distance) && radius > 0 && distance < radius) {
    level = smoothstep(radius, radius * EMF_FULL_SHARE, distance);
  }
  if (ventAdjacent) level = Math.max(level, VentAdjacentIntensity);
  return clamp01(level);
}

export function flickerFactor(intensity, t, seed) {
  if (!(intensity > 0)) return 1;
  const level = clamp01(intensity);
  const slot = Math.floor(t * DROPOUT_HZ);
  const roll = hash(`${Math.floor(seed)}:${slot}`) / 4294967296;
  if (roll < level * DROPOUT_CHANCE) return DROPOUT_LEVEL;
  const folded = t % NOISE_PERIOD;
  const wave = noise1(folded * (FLICKER_BASE_HZ + FLICKER_EXTRA_HZ * level), seed) * 0.5 + 0.5;
  return clamp01(1 - level * (0.25 + 0.45 * clamp01(wave)));
}

export function batteryFactor(fraction) {
  if (!(fraction > 0)) return 0;
  if (fraction >= LowBattery) return 1;
  return lerp(LOW_FLOOR, 1, fraction / LowBattery);
}

export function beamColor(fraction, out = new THREE.Color()) {
  const warmth = 1 - clamp01(fraction / LowBattery);
  return out.copy(BEAM_COLOR).lerp(DYING_COLOR, warmth);
}

export function sputter(fraction, t, seed) {
  if (fraction >= SPUTTER_BELOW || !(fraction > 0)) return 1;
  const depth = 1 - fraction / SPUTTER_BELOW;
  const wave = noise1((t % NOISE_PERIOD) * 11, seed + 101) * 0.5 + 0.5;
  return clamp01(1 - 0.55 * depth * clamp01(wave));
}

export class Flashlight {
  /**
   * @param {{shared: any, audio: any, scene: THREE.Scene, meters: any, settings: any, quality: any}} deps
   */
  constructor(deps) {
    this.shared = deps.shared;
    this.audio = deps.audio;
    this.meters = deps.meters;
    this.settings = deps.settings;
    this.quality = deps.quality;
    this.on = false;
    this.output = 0;
    this.emf = 0;
    this.lastToggle = -Infinity;
    this.rotation = null;
    this.position = new THREE.Vector3();
    this.direction = new THREE.Vector3(0, 0, -1);
    this.color = new THREE.Color();
    this.seed = 1;
    /** @type {((position: THREE.Vector3) => number)|null} */
    this.emfSource = null;
    this.staticVoice = null;
    this.staticVolume = 0;
    this.allowed = true;
    this.haze = this._buildHaze();
    deps.scene.add(this.haze);
    this.filmShafts = 1;
  }

  /** W3 registers the EMF rule: intensity 0..1 at a world position. */
  setEmfSource(fn) {
    this.emfSource = fn || null;
  }

  /** The Flashlight action. */
  toggle(now) {
    if (now - this.lastToggle < TOGGLE_COOLDOWN) return;
    this.lastToggle = now;
    if (this.audio) this.audio.play('UiClick');
    const want = !this.on;
    if (want && this.meters.battery.value <= 0) return;
    this.on = want;
  }

  setOn(on) {
    this.on = !!on && this.meters.battery.value > 0;
  }

  /**
   * @param {{dt: number, time: number, eye: THREE.Vector3, quaternion: THREE.Quaternion, lowered: number,
   *   allowed: boolean, playing: boolean}} ctx
   */
  update(ctx) {
    const battery = this.meters.battery;
    // FlashlightService: drain while lit (only while the run's meters run)
    if (this.on && ctx.playing) battery.value = Math.max(0, battery.value - GameConfig.BatteryDrain * ctx.dt);
    if (battery.value <= 0) this.on = false;
    const fraction = battery.max > 0 ? clamp01(battery.value / battery.max) : 0;
    this.allowed = ctx.allowed;
    this.emf = ctx.allowed && this.emfSource ? clamp01(this.emfSource(ctx.eye) || 0) : 0;
    this._driveStatic(this.emf);

    // aim: damped slerp of the look, lowered while sprinting
    _q.copy(ctx.quaternion).multiply(_lower.setFromAxisAngle(_x, -LOWERED_PITCH * clamp01(ctx.lowered)));
    if (!this.rotation) this.rotation = _q.clone();
    else this.rotation.slerp(_q, damp(LAG_SPEED, ctx.dt));
    this.position.set(Cones.offset[0], Cones.offset[1], Cones.offset[2]).applyQuaternion(ctx.quaternion).add(ctx.eye);
    this.direction.set(0, 0, -1).applyQuaternion(this.rotation);

    const s = this.shared;
    s.uFlPos.value.copy(this.position);
    s.uFlDir.value.copy(this.direction);
    s.uGlowPos.value.copy(ctx.allowed ? ctx.eye : _far);
    s.uGlowColor.value.set(GLOW_COLOR[0] / 255, GLOW_COLOR[1] / 255, GLOW_COLOR[2] / 255)
      .multiplyScalar(GLOW_BRIGHTNESS * BRIGHTNESS_UNIT);
    s.uGlowRange.value = GLOW_RANGE;
    const halfIn = ((Cones.innerAngle / 2) * Math.PI) / 180;
    const halfOut = ((Cones.outerAngle / 2) * Math.PI) / 180;
    s.uFlCone.value.set(Math.cos(halfIn * 0.55), Math.cos(halfIn), Math.cos(halfOut * 0.6), Math.cos(halfOut));
    s.uFlRange.value.set(Cones.innerRange, Cones.outerRange);

    if (!(this.on && fraction > 0 && ctx.allowed)) {
      this.output = 0;
      s.uFlInner.value.set(0, 0, 0);
      s.uFlOuter.value.set(0, 0, 0);
      this.haze.visible = false;
      return;
    }
    const flashScale = clamp01(this.settings.get('FlashScale'));
    const flicker = 1 - (1 - flickerFactor(this.emf, ctx.time, this.seed)) * flashScale;
    this.output = batteryFactor(fraction) * sputter(fraction, ctx.time, this.seed) * flicker;
    beamColor(fraction, this.color);
    const gain = BRIGHTNESS_UNIT * (s.torchGain ?? 1); // lighting's exposure trim, undone for the torch
    s.uFlInner.value.set(this.color.r, this.color.g, this.color.b)
      .multiplyScalar(Cones.innerBrightness * this.output * gain);
    s.uFlOuter.value.set(this.color.r, this.color.g, this.color.b)
      .multiplyScalar(Cones.outerBrightness * this.output * gain);

    // haze shafts
    const hazeOn = this.quality.budget.flashlightHaze && this.output > 0.01 && this.filmShafts > 0;
    this.haze.visible = hazeOn;
    if (hazeOn) {
      const u = this.haze.material.uniforms;
      u.uP0.value.copy(this.position);
      u.uDir.value.copy(this.direction);
      this.color.getRGB(_rgb, THREE.SRGBColorSpace);
      u.uColor.value.setRGB(_rgb.r, _rgb.g, _rgb.b, THREE.LinearSRGBColorSpace);
      u.uStrength.value = HAZE_BRIGHTNESS * clamp01(this.output) * Math.max(0, this.filmShafts);
    }
  }

  _driveStatic(level) {
    if (!this.audio) return;
    if (level < STATIC_THRESHOLD) {
      if (this.staticVoice) this.staticVoice.stop(0.5);
      this.staticVoice = null;
      return;
    }
    const volume = 0.25 + 0.75 * level;
    if (!this.staticVoice || !this.staticVoice.playing) {
      this.staticVolume = volume;
      this.staticVoice = this.audio.play('EmfStatic', { loop: true, fadeIn: 0.3, volume });
    } else if (Math.abs(volume - this.staticVolume) > STATIC_VOLUME_EPSILON) {
      this.staticVolume = volume;
      this.staticVoice.setVolume(volume, 0.15);
    }
  }

  /** Shadow camera parameters for the renderer (null when the beam is off). */
  shadowSpec() {
    if (this.output <= 0.01) return null;
    return { position: this.position, direction: this.direction, fov: Cones.outerAngle * 0.9, far: Cones.innerRange };
  }

  /**
   * HazeCore and HazeSheath (Flashlight.luau newHaze): Beams with FaceCamera, Width0 0.3, Width1 from the cone
   * angles over twice the length, LightEmission 1 (additive), transparency 1 -> 1-op at 0.18 -> 1-0.45op at 0.6 -> 1.
   * Each ribbon's width axis is perpendicular to the beam and to the view at that point; the sheath's brightness is
   * 0.8 of the core's. Drawn additively into the display-encoded frame, one draw for both.
   */
  _buildHaze() {
    const spread = 2 * HAZE_LENGTH;
    const layers = [
      { width1: spread * Math.tan(((Cones.innerAngle / 2) * Math.PI) / 180) * 0.75, opacity: HAZE_CORE_OPACITY, gain: 1 },
      { width1: spread * Math.tan(((Cones.outerAngle / 2) * Math.PI) / 180) * 0.6, opacity: HAZE_SHEATH_OPACITY, gain: 0.8 },
    ];
    const cols = HAZE_SEGMENTS + 1;
    const pos = [];
    const meta = [];
    const index = [];
    layers.forEach((layer, li) => {
      const base = li * cols * 2;
      for (let i = 0; i < cols; i++) {
        const t = i / HAZE_SEGMENTS;
        for (const side of [-1, 1]) {
          pos.push(t, side, 0);
          meta.push(0.15 + (layer.width1 / 2 - 0.15) * t, layer.opacity * layer.gain);
        }
        if (i < HAZE_SEGMENTS) {
          const a = base + i * 2;
          index.push(a, a + 1, a + 2, a + 1, a + 3, a + 2);
        }
      }
    });
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    geo.setAttribute('aRibbon', new THREE.Float32BufferAttribute(meta, 2));
    geo.setIndex(index);
    const mat = new THREE.ShaderMaterial({
      uniforms: {
        uP0: { value: new THREE.Vector3() },
        uDir: { value: new THREE.Vector3(0, 0, -1) },
        uColor: { value: new THREE.Color(1, 1, 1) },
        uStrength: { value: 0 },
      },
      vertexShader: /* glsl */ `
        uniform vec3 uP0; uniform vec3 uDir;
        attribute vec2 aRibbon; // half width at this station, opacity x layer gain
        varying float vT; varying float vOpacity;
        void main() {
          vT = position.x;
          vOpacity = aRibbon.y;
          vec3 p = uP0 + uDir * (position.x * ${HAZE_LENGTH.toFixed(1)});
          vec3 side = cross(uDir, cameraPosition - p);
          float l = length(side);
          side = l > 1e-4 ? side / l : vec3(1.0, 0.0, 0.0);
          p += side * (position.y * aRibbon.x);
          gl_Position = projectionMatrix * viewMatrix * vec4(p, 1.0);
        }`,
      fragmentShader: /* glsl */ `
        uniform vec3 uColor; uniform float uStrength;
        varying float vT; varying float vOpacity;
        void main() {
          // opacity curve: 0 at the lens, full at 0.18, 0.45 at 0.6, 0 at the far end
          float o = vT < 0.18 ? vT / 0.18 : (vT < 0.6 ? mix(1.0, 0.45, (vT - 0.18) / 0.42) : mix(0.45, 0.0, (vT - 0.6) / 0.4));
          gl_FragColor = vec4(uColor * uStrength * vOpacity * o, 1.0);
        }`,
      transparent: true,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
      side: THREE.DoubleSide,
    });
    const mesh = new THREE.Mesh(geo, mat);
    mesh.visible = false;
    mesh.frustumCulled = false;
    mesh.renderOrder = 20;
    mesh.matrixAutoUpdate = false;
    return mesh;
  }
}

const _rgb = { r: 0, g: 0, b: 0 };
const _q = new THREE.Quaternion();
const _lower = new THREE.Quaternion();
const _x = new THREE.Vector3(1, 0, 0);
const _far = new THREE.Vector3(0, -1e5, 0);
