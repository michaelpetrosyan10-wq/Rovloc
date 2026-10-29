// JumpscareView (Controllers/Gameplay/JumpscareController.luau): what being caught looks like.
//
// A session runs on the game clock from the catch's cue (kind, face, startAt, endsAt): nothing shows before startAt,
// and the hold ends ("the cut") at endsAt, when the outcome lands.
//   * At startAt: input context Cutscene, the HUD hidden, panic floor 1, and the "Jumpscare" camera override (FOV
//     JumpscareFov, an almost instant blend in). The camera snaps onto the Creature's face (the live, animated head,
//     so the face stays framed through the Lunge) at the eye's distance (clamped) and lunges in to FaceDistance over
//     LungeSeconds on an overshooting ease: the face slams in past FaceDistance and recoils to it. On top, a violent
//     shake (noise rotation up to Shake.JumpscareAmplitude x the envelope, peaking at the slam, sustained through the
//     hold, plus a positional jitter).
//   * A light rides the locked camera and lights the face: it flares with the snap and the slam, then holds,
//     stuttering.
//   * An overlay: a white flash at the snap, a red one at the slam, a pulsing red vignette through the hold, and a
//     hard cut to black at the end. Under the black the override is popped and the look turned toward the Creature.
//   * After a beat in black, input, HUD and panic are handed back and the black fades out.
// MotionScale scales the shake and the lunge's travel; FlashScale scales the flashes, the vignette's pulse and the
// light's stutter. A catch called off early cuts to black at once and restores after a shorter beat.

import * as THREE from 'three';
import { CFrame } from './cframe.js';
import { CameraConfig, CreatureConfig } from './config.js';
import { clamp, clamp01, isFiniteVector, lerp, noise1, smoothstep, yawPitchFromVector } from './util.js';

const J = CreatureConfig.Jumpscare;
const TOKEN = 'Jumpscare';
const TAU = Math.PI * 2;
const LUNGE = J.LungeSeconds;
const HOLD = J.HoldSeconds;
const FACE_DISTANCE = J.FaceDistance;
const FOV = CameraConfig.JumpscareFov;

export const MIN_START_DISTANCE = FACE_DISTANCE + 0.9;
export const MAX_START_DISTANCE = 5.5;
const OVERSHOOT = 2.2;
export const CLOSEST = FACE_DISTANCE * 0.6;
const SLAM_SHARE = 1 - (2 * OVERSHOOT) / (3 * (OVERSHOOT + 1));
export const SLAM_AT = LUNGE * SLAM_SHARE;
const BLEND_IN = 0.04;

const SHAKE_DEGREES = CameraConfig.JumpscareShakeAmplitude;
const SHAKE_HZ = 19;
const SHAKE_ONSET = 1;
const SHAKE_SLAM = 1.8;
const SHAKE_HOLD = 0.65;
const SHAKE_DECAY = 5;
const SHAKE_STUDS = 0.07;

const FLASH_PEAK = 0.9;
const SLAM_TINT = 0.6;
const FLASH_SECONDS = 0.16;
const VIGNETTE_PEAK = 0.55;
const VIGNETTE_RISE = 0.08;
const VIGNETTE_PULSE = 0.35;
const VIGNETTE_HZ = 2.4;
export const BEAT = 0.6;
export const ABORT_BEAT = 0.2;
export const FADE = 0.7;
const WHITE = 'rgb(255,247,238)';
const BLOOD = 'rgb(150,6,4)';
const BLOOD_EDGE = '60,0,0';

const LIGHT_FLARE = 5;
const LIGHT_SLAM = 2;
const LIGHT_HOLD = 1.6;
const LIGHT_FLARE_DECAY = 8;
const LIGHT_STUTTER = 0.35;
const LIGHT_STUTTER_HZ = 6;
const LIGHT_RANGE = 7;
const LIGHT_COLOR = [206 / 255, 220 / 255, 1];
const LIGHT_RISE = 0.25;
const MAX_LEAD = 1;
const MAX_HOLD = 6;

const finiteOr = (v, fallback) => (Number.isFinite(v) ? v : fallback);

function backOut(t, tension) {
  const u = t - 1;
  return 1 + (tension + 1) * u * u * u + tension * u * u;
}

function spike(t, at) {
  const age = t - at;
  if (age < 0 || age >= FLASH_SECONDS) return 0;
  const fall = 1 - age / FLASH_SECONDS;
  return fall * fall;
}

/** How far through the lunge (0..1) the moment is `elapsed` seconds after startAt. */
export function lungeProgress(elapsed) {
  return clamp01(finiteOr(elapsed, 0) / LUNGE);
}

/** The camera's distance from the face at lunge `progress`. */
export function lungeDistance(startDistance, progress, motionScale) {
  const motion = clamp01(finiteOr(motionScale, 1));
  const start = Math.max(finiteOr(startDistance, FACE_DISTANCE), FACE_DISTANCE);
  const from = FACE_DISTANCE + (start - FACE_DISTANCE) * motion;
  const eased = backOut(clamp01(finiteOr(progress, 0)), OVERSHOOT);
  return Math.max(from + (FACE_DISTANCE - from) * eased, CLOSEST);
}

/** The camera `distance` studs out along the face's look, looking back at it, upright with the face. @param {CFrame} face */
export function faceLock(face, distance) {
  const target = face.position;
  if (!isFiniteVector(target)) return face;
  const reach = Math.max(finiteOr(distance, FACE_DISTANCE), 0.05);
  return CFrame.lookAt(target.clone().addScaledVector(face.lookVector, reach), target, face.upVector);
}

export function faceLockCFrame(face, progress, startDistance, motionScale) {
  return faceLock(face, lungeDistance(startDistance, progress, motionScale));
}

/** Where the lunge starts: the eye's distance from the face, clamped. */
export function startDistanceFor(eye, face) {
  const d = face.distanceTo(eye);
  return Number.isFinite(d) ? clamp(d, MIN_START_DISTANCE, MAX_START_DISTANCE) : MIN_START_DISTANCE;
}

/** The shake's strength (multiples of the jumpscare amplitude) `elapsed` seconds after startAt. */
export function shakeEnvelope(elapsed) {
  if (!Number.isFinite(elapsed) || elapsed < 0 || elapsed >= LUNGE + HOLD) return 0;
  if (elapsed < SLAM_AT) return lerp(SHAKE_ONSET, SHAKE_SLAM, smoothstep(0, SLAM_AT, elapsed));
  return SHAKE_HOLD + (SHAKE_SLAM - SHAKE_HOLD) * Math.exp(-SHAKE_DECAY * (elapsed - SLAM_AT));
}

/** The shake as a camera-space offset. */
export function shakeOffset(elapsed, motionScale, seed) {
  const level = shakeEnvelope(elapsed) * clamp01(finiteOr(motionScale, 1));
  if (level <= 0) return new CFrame();
  const x = elapsed * SHAKE_HZ;
  const wobble = (offset) => clamp(noise1(x, seed + offset), -1, 1);
  const turn = ((SHAKE_DEGREES * Math.PI) / 180) * level;
  const reach = SHAKE_STUDS * level;
  return new CFrame(wobble(43) * reach, wobble(59) * reach, 0)
    .mul(CFrame.angles(wobble(0) * turn, wobble(17) * turn * 0.8, wobble(31) * turn * 1.2));
}

/** The victim's camera `elapsed` seconds after startAt. */
export function cameraCFrame(face, elapsed, startDistance, motionScale, seed) {
  return faceLockCFrame(face, lungeProgress(elapsed), startDistance, motionScale).mul(shakeOffset(elapsed, motionScale, seed));
}

/** The overlay `elapsed` seconds after startAt: {flash, tint, vignette, black}. */
export function overlay(elapsed, flashScale, cutAt, beat) {
  const t = finiteOr(elapsed, 0);
  const scale = clamp01(finiteOr(flashScale, 1));
  const cut = Math.max(finiteOr(cutAt, LUNGE + HOLD), 0);
  const hold = Math.max(finiteOr(beat, BEAT), 0);
  if (t < 0) return { flash: 0, tint: 0, vignette: 0, black: 0 };
  if (t >= cut) return { flash: 0, tint: 0, vignette: 0, black: 1 - smoothstep(cut + hold, cut + hold + FADE, t) };
  const trough = 0.5 - 0.5 * Math.cos(TAU * VIGNETTE_HZ * t);
  return {
    flash: FLASH_PEAK * scale * spike(t, 0),
    tint: SLAM_TINT * scale * spike(t, SLAM_AT),
    vignette: VIGNETTE_PEAK * smoothstep(0, VIGNETTE_RISE, t) * (1 - VIGNETTE_PULSE * scale * trough),
    black: 0,
  };
}

/** The face light's brightness `elapsed` seconds after startAt. */
export function faceLight(elapsed, flashScale, cutAt) {
  const t = finiteOr(elapsed, 0);
  const cut = Math.max(finiteOr(cutAt, LUNGE + HOLD), 0);
  if (t < 0 || t >= cut) return 0;
  const scale = clamp01(finiteOr(flashScale, 1));
  const level = LIGHT_HOLD + (LIGHT_FLARE - LIGHT_HOLD) * Math.exp(-LIGHT_FLARE_DECAY * t) + LIGHT_SLAM * spike(t, SLAM_AT);
  const stutter = 0.5 + 0.5 * clamp(noise1(t * LIGHT_STUTTER_HZ, 5), -1, 1);
  return level * (1 - LIGHT_STUTTER * scale * stutter);
}

/** Seconds from startAt to the cut. */
export function holdLength(startAt, endsAt) {
  if (endsAt === null || endsAt === undefined || !Number.isFinite(endsAt) || !Number.isFinite(startAt)) return LUNGE + HOLD;
  const length = endsAt - startAt;
  if (length <= 0 || length > MAX_HOLD) return LUNGE + HOLD;
  return length;
}

export class JumpscareView {
  /**
   * @param {import('./env.js').CreatureEnv} env
   * @param {() => CFrame|null} faceWorld the rig's animated face frame
   */
  constructor(env, faceWorld) {
    this.env = env;
    this.faceWorld = faceWorld;
    this.session = null;
    /** () once a session (begun or not) has fully ended. */
    this.onEnded = null;
  }

  /** The victim cue. @param {{kind: string, startAt: number, endsAt: number, face: THREE.Vector3}} cue */
  start(cue) {
    const now = this.env.renderTime();
    const start = Number.isFinite(cue.startAt) ? Math.min(cue.startAt, now + MAX_LEAD) : now;
    const cutAt = holdLength(start, cue.endsAt);
    if (now - start >= cutAt) return;
    if (this.session) this._end(this.session);
    this.session = {
      kind: cue.kind || 'Hallway',
      startAt: start,
      cutAt,
      beat: BEAT,
      facePoint: cue.face && isFiniteVector(cue.face) ? cue.face.clone() : null,
      fallbackFace: new CFrame(),
      startDistance: MIN_START_DISTANCE,
      motionScale: 1,
      flashScale: 1,
      seed: (1 + Math.floor(start * 10)) % 997,
      paint: null,
      light: null,
      hudWasVisible: true,
      begun: false,
      cut: false,
      restored: false,
    };
    this.step();
  }

  /** The catch was called off: before it showed it simply ends; once shown, it cuts to black now. */
  abort() {
    const s = this.session;
    if (!s) return;
    if (!s.begun) {
      this._end(s);
      return;
    }
    const elapsed = this.env.renderTime() - s.startAt;
    if (elapsed < s.cutAt) {
      s.cutAt = Math.max(0, elapsed);
      s.beat = ABORT_BEAT;
    }
  }

  /** The run ended: tear everything down at once. */
  end() {
    if (this.session) this._end(this.session);
  }

  isActive() {
    return this.session !== null;
  }

  _face(s) {
    const live = this.faceWorld();
    if (live && isFiniteVector(live.position)) return live;
    return s.fallbackFace;
  }

  _camera(s) {
    const elapsed = clamp(this.env.renderTime() - s.startAt, 0, s.cutAt);
    return cameraCFrame(this._face(s), elapsed, s.startDistance, s.motionScale, s.seed);
  }

  _begin(s) {
    const env = this.env;
    s.begun = true;
    s.motionScale = clamp01(finiteOr(env.setting('MotionScale'), 1));
    s.flashScale = clamp01(finiteOr(env.setting('FlashScale'), 1));
    env.pushInputContext(TOKEN, 'Cutscene');
    s.hudWasVisible = env.isHudVisible();
    if (s.hudWasVisible) env.setHudVisible(false, 0);
    env.setPanicFloor(TOKEN, 1);
    const eye = env.playerEye();
    const live = this.faceWorld();
    const facePoint = live ? live.position : s.facePoint;
    if (facePoint && isFiniteVector(facePoint) && facePoint.distanceTo(eye) > 1e-3) {
      s.fallbackFace = CFrame.lookAt(facePoint, eye);
      s.startDistance = startDistanceFor(eye, facePoint);
    } else {
      s.startDistance = MIN_START_DISTANCE;
      const look = env.playerLookVector();
      const ahead = eye.clone().addScaledVector(look, MIN_START_DISTANCE);
      s.fallbackFace = CFrame.lookAt(ahead, eye);
    }
    env.setCameraOverride(TOKEN, () => this._camera(s), { fov: FOV, blendIn: BLEND_IN, blendOut: 0 });
    s.paint = this._buildPaint();
    s.light = env.addLight({ position: eye.clone(), color: LIGHT_COLOR, brightness: 0, range: LIGHT_RANGE });
  }

  _cut(s) {
    const env = this.env;
    s.cut = true;
    const toward = this._face(s).position.sub(env.playerEye());
    env.setCameraOverride(TOKEN, null, { blendOut: 0 });
    if (s.light) {
      s.light.remove();
      s.light = null;
    }
    if (isFiniteVector(toward) && Math.hypot(toward.x, toward.z) > 1e-3) env.setLook(yawPitchFromVector(toward).yaw, 0);
  }

  _restore(s) {
    const env = this.env;
    s.restored = true;
    env.popInputContext(TOKEN);
    env.setPanicFloor(TOKEN, null);
    if (s.hudWasVisible) env.setHudVisible(true, 0.4);
  }

  _end(s) {
    if (this.session === s) this.session = null;
    if (s.begun && !s.cut) {
      s.cut = true;
      this.env.setCameraOverride(TOKEN, null, { blendOut: 0 });
    }
    if (s.begun && !s.restored) this._restore(s);
    if (s.light) {
      s.light.remove();
      s.light = null;
    }
    if (s.paint) {
      s.paint.root.remove();
      s.paint = null;
    }
    if (this.onEnded) this.onEnded();
  }

  /** Per render frame. */
  step() {
    const s = this.session;
    if (!s) return;
    const elapsed = this.env.renderTime() - s.startAt;
    if (!s.begun) {
      if (elapsed < 0) return;
      if (elapsed >= s.cutAt) {
        this._end(s);
        return;
      }
      this._begin(s);
    }
    if (!s.cut && elapsed >= s.cutAt) this._cut(s);
    if (!s.restored && elapsed >= s.cutAt + s.beat) this._restore(s);
    this._paint(s, elapsed);
    if (s.light) {
      const cam = this._camera(s);
      s.light.set({ position: cam.pointToWorld(new THREE.Vector3(0, LIGHT_RISE, 0)), brightness: faceLight(elapsed, s.flashScale, s.cutAt) });
    }
    if (elapsed >= s.cutAt + s.beat + FADE) this._end(s);
  }

  // ------------------------------------------------------------------ overlay

  _buildPaint() {
    const parent = this.env.overlayRoot();
    if (!parent || typeof document === 'undefined') return null;
    const layer = (style) => {
      const el = document.createElement('div');
      el.style.cssText = `position:absolute;inset:0;pointer-events:none;opacity:0;${style}`;
      root.appendChild(el);
      return el;
    };
    const root = document.createElement('div');
    root.className = 'rv-jumpscare';
    root.style.cssText = 'position:absolute;inset:0;pointer-events:none;z-index:40;';
    const edge = `rgba(${BLOOD_EDGE},1)`;
    const fadeTo = `rgba(${BLOOD_EDGE},0.45) 45%, rgba(${BLOOD_EDGE},0) 100%`;
    const edges = [
      layer(`bottom:auto;height:34%;background:linear-gradient(180deg, ${edge} 0%, ${fadeTo});`),
      layer(`top:auto;height:34%;background:linear-gradient(0deg, ${edge} 0%, ${fadeTo});`),
      layer(`right:auto;width:30%;background:linear-gradient(90deg, ${edge} 0%, ${fadeTo});`),
      layer(`left:auto;width:30%;background:linear-gradient(270deg, ${edge} 0%, ${fadeTo});`),
    ];
    const paint = {
      root,
      edges,
      tint: layer(`background:${BLOOD};`),
      flash: layer(`background:${WHITE};`),
      black: layer('background:#000;'),
      written: new Map(),
    };
    parent.appendChild(root);
    return paint;
  }

  _paint(s, elapsed) {
    const paint = s.paint;
    if (!paint) return;
    const o = overlay(elapsed, s.flashScale, s.cutAt, s.beat);
    const set = (el, value) => {
      const v = clamp01(value);
      const last = paint.written.get(el);
      if (last !== undefined && Math.abs(last - v) < 0.002 && (v > 0 || last === 0)) return;
      paint.written.set(el, v);
      el.style.opacity = String(v);
    };
    for (const e of paint.edges) set(e, o.vignette);
    set(paint.tint, o.tint);
    set(paint.flash, o.flash);
    set(paint.black, o.black);
  }
}
