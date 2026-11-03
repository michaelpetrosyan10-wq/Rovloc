// JumpscareView (Controllers/Gameplay/JumpscareController.luau): what being caught looks like, and the lighter reveal.
//
// The catch. A session runs on the game clock from the catch's cue (kind, face, startAt, endsAt): nothing shows before
// startAt; the sequence lasts about 1.6 s (SEQUENCE), cutting to black at min(endsAt, startAt + SEQUENCE.cut) plus the
// static's last frames, and the black holds while the outcome lands at endsAt.
//   * At startAt: input context Cutscene, the HUD hidden, panic floor 1, and the "Jumpscare" camera override (FOV
//     JumpscareFov, an almost instant blend in). The camera locks onto the Creature's mask (the live, animated head:
//     the Lunge bows the Tall Man down to the victim until the mask hangs level with their eye) and looks level into
//     it: it snaps in over SEQUENCE.snap on an overshooting ease to HOLD_DISTANCE (about 1.35 studs: the mask fills
//     most of the frame), lurches at the tear and at the flash. The camera stays upright, so the mask's cock shows.
//   * On the mask (CreatureView drives it from the Lunge: mask.js maskFx): the cracks race across it, the slit tears
//     into a jagged vertical maw (porcelain shards breaking off, thin strands stretching across it), the right pupil
//     dilates.
//   * The shake: small through the snap and the race, a jolt at the tear, violent 0.85-1.25 s, held into the static.
//   * A cold light under and to one side of the camera lights the mask: it flares with the snap, then holds, stuttering.
//   * The screen: a cold-white flash at the snap; at SEQUENCE.flash a white flash and then red (the post pass grades the
//     frame blood red by its brightness, engine/screenfx.js); the frame tears (the
//     post pass's screen-tear hook, engine/screenfx.js: bands slipping sideways, a chromatic split) from the tear,
//     growing into static from SEQUENCE.staticFrom; static fills it for STATIC_CUT, then a hard cut to black. Under the
//     black the override is popped and the look turned toward the Creature. After a beat in black, input, HUD and
//     panic are handed back and the black fades out.
//   * Variants (the cue's kind): Hallway as above; Locker, closer and darker, the frame edged in the locker's black;
//     Vent (legacy), dim and tight; Underwater, murky green-blue, the tear rolling slower and the static softer.
// MotionScale scales the shake, the camera's travel and the tear's slip; FlashScale scales the flashes, the static and
// the light's stutter. A catch called off early cuts to black at once and restores after a shorter beat.
//
// The reveal (no catch): reveal(kind, opts) snaps a phantom of the head, mask, tatters, chest and arms into view 3-4
// studs ahead of the camera (the hiding-spot kinds, matched without case: `Fakeout`, `Locker`, `Barrel`, `Cabinet`: 0.75
// studs off, in the dark of the spot with you), its mask cocked 20-30 degrees and half in shadow (a cold light from one
// side), the torch stuttering on it, glitching, for a third of a second, with a sting (a shriek for the locker kinds; a
// `Fakeout`'s shriek is the game's own FakeoutShriek), a camera jolt and a burst of tear and static; it never takes the
// camera or the input. For the teleport reveal and the fake-outs.

import * as THREE from 'three';
import { CFrame } from './cframe.js';
import { CameraConfig, CreatureConfig } from './config.js';
import { applyCreatureLook } from './look.js';
import { clamp, clamp01, isFiniteVector, lerp, noise1, smoothstep, yawPitchFromVector } from './util.js';

const J = CreatureConfig.Jumpscare;
const TOKEN = 'Jumpscare';
const LUNGE = J.LungeSeconds;
const HOLD = J.HoldSeconds;
const FOV = CameraConfig.JumpscareFov;

/** The catch's sequence (seconds after startAt): about 1.6 s from the snap to the black. */
export const SEQUENCE = Object.freeze({
  snap: 0.15, // the camera snaps onto the mask, overshooting in
  tear: 0.36, // the slit tears open into the maw (the cracks race 0.12-0.5, the pupil dilates 0.62-0.9: mask.js)
  shake: Object.freeze([0.84, 1.26]), // the violent shake
  flash: 1.02, // a white flash, then red
  staticFrom: 1.18, // the static tear grows ...
  cut: 1.47, // ... fills the frame for STATIC_CUT: black at about 1.6 s
});
export const HOLD_DISTANCE = 1.35; // studs from the mask: it fills most of the frame
export const MIN_START_DISTANCE = 1.9;
export const MAX_START_DISTANCE = 2.6;
const OVERSHOOT = 2.4;
export const CLOSEST = 0.95;
const BLEND_IN = 0.04;
const MAX_PITCH = 0.1; // the camera looks level into the mask: at most this much of its look's sine up or down
const TILT_SHOWN = 0.25; // how much of the mask's roll the camera follows (so most of its cock shows)

const SHAKE_DEGREES = CameraConfig.JumpscareShakeAmplitude;
const SHAKE_HZ = 19;
const SHAKE_STUDS = 0.06;

const FLASH_PEAK = 0.75;
const FLASH_SECONDS = 0.12;
const RED_PEAK = 0.62;
const VIGNETTE_PEAK = 0.6;
const VIGNETTE_RISE = 0.08;
const VIGNETTE_PULSE = 0.3;
const VIGNETTE_HZ = 2.4;
const STATIC_CUT = 0.13; // the frame is static for this long before the black
export const BEAT = 0.6;
export const ABORT_BEAT = 0.2;
export const FADE = 0.7;
const COLD_WHITE = 'rgb(226,236,255)';
const RED_TINT = Object.freeze([1.0, 0.07, 0.06]); // the red flash: the frame graded blood red by its brightness
const EDGE_RGB = '4,6,10';

const LIGHT_FLARE = 2.2;
const LIGHT_SLAM = 1.0;
const LIGHT_HOLD = 0.85;
const LIGHT_FLARE_DECAY = 8;
const LIGHT_STUTTER = 0.35;
const LIGHT_STUTTER_HZ = 6;
const LIGHT_RANGE = 7;
const LIGHT_COLOR = [196 / 255, 214 / 255, 1];
const LIGHT_UNDER = Object.freeze([0.85, -0.55, -0.55]); // camera space: low and to one side, raking across the mask
const TORCH_DIM = 0.3; // the victim's torch gutters down to this through the catch
const MAX_LEAD = 1;
const PHANTOM_WARMUP = 1.5; // seconds of game time before the reveal's phantom is built
const MAX_HOLD = 6;

/** Per catch kind: the hold distance, the tear's strength, the static's, the light's, and an overlay tint. */
export const Variants = Object.freeze({
  Hallway: Object.freeze({ hold: HOLD_DISTANCE, split: 1, slip: 1, static: 1, light: 1, edge: 0.6, tint: null }),
  Locker: Object.freeze({ hold: 1.22, split: 1.15, slip: 0.8, static: 1, light: 0.75, edge: 0.95, tint: null }),
  Vent: Object.freeze({ hold: 1.25, split: 0.9, slip: 0.7, static: 0.9, light: 0.6, edge: 0.85, tint: null }),
  Underwater: Object.freeze({ hold: 1.45, split: 0.8, slip: 0.45, static: 0.7, light: 0.7, edge: 0.7, tint: [18, 54, 58, 0.42] }),
});

export const RevealConfig = Object.freeze({
  distance: 3.4, // studs ahead of the camera the mask snaps in at
  lockerDistance: 0.75, // the locker kinds: in the dark of the hiding spot with you
  seconds: 0.36, // how long it hangs there
  snapIn: 0.05,
  snapOut: 0.09,
  offset: 0.35, // studs off the view's centre, to one side
  cock: 0.45, // radians the mask is cocked over (about 26 degrees)
  jolt: 5.5, // degrees of camera shake
  joltSeconds: 0.45,
  light: 2.2, // the cold light from one side: half the mask in shadow
  torch: 0.12, // the torch stutters down to this
});

const REVEAL_FX = Object.freeze({ race: 0, tear: 0, strands: 0, dilate: 0, focus: 1 });

const finiteOr = (v, fallback) => (Number.isFinite(v) ? v : fallback);

function backOut(t, tension) {
  const u = t - 1;
  return 1 + (tension + 1) * u * u * u + tension * u * u;
}

function bump(t, at, rise, decay) {
  const age = t - at;
  if (age < 0) return 0;
  if (age < rise) return age / rise;
  return Math.exp(-(age - rise) * decay);
}

/** How far through the snap (0..1) the moment is `elapsed` seconds after startAt. */
export function lungeProgress(elapsed) {
  return clamp01(finiteOr(elapsed, 0) / SEQUENCE.snap);
}

/**
 * The camera's distance from the mask `elapsed` seconds after startAt: snapping in from the start distance past `hold`
 * and back, lurching in at the tear and at the flash.
 */
export function maskDistance(elapsed, startDistance, motionScale, hold = HOLD_DISTANCE) {
  const t = finiteOr(elapsed, 0);
  const motion = clamp01(finiteOr(motionScale, 1));
  const start = clamp(finiteOr(startDistance, MIN_START_DISTANCE), hold, MAX_START_DISTANCE);
  const from = hold + (start - hold) * motion;
  let d = from + (hold - from) * backOut(lungeProgress(t), OVERSHOOT);
  d -= motion * (0.1 * bump(t, SEQUENCE.tear, 0.04, 7) + 0.16 * smoothstep(SEQUENCE.flash - 0.04, SEQUENCE.flash + 0.1, t));
  return Math.max(d, CLOSEST);
}

/** @deprecated kept for tools: the distance at snap `progress` (0..1). */
export function lungeDistance(startDistance, progress, motionScale) {
  return maskDistance(clamp01(finiteOr(progress, 0)) * SEQUENCE.snap, startDistance, motionScale);
}

/**
 * The camera `distance` studs out along the mask's look, levelled (it looks straight into the mask, not up at it),
 * upright but for a share of the mask's roll, looking back at it. @param {CFrame} face
 */
export function faceLock(face, distance) {
  const target = face.position;
  if (!isFiniteVector(target)) return face;
  const reach = Math.max(finiteOr(distance, HOLD_DISTANCE), 0.05);
  const look = face.lookVector.clone();
  const flat = Math.hypot(look.x, look.z);
  if (flat > 1e-3) {
    look.y = clamp(look.y, -MAX_PITCH, MAX_PITCH);
    look.normalize();
  }
  const up = new THREE.Vector3(0, 1, 0).lerp(face.upVector, TILT_SHOWN).normalize();
  return CFrame.lookAt(target.clone().addScaledVector(look, reach), target, up);
}

export function faceLockCFrame(face, progress, startDistance, motionScale) {
  return faceLock(face, lungeDistance(startDistance, progress, motionScale));
}

/** Where the snap starts: the eye's distance from the face, clamped. */
export function startDistanceFor(eye, face) {
  const d = face.distanceTo(eye);
  return Number.isFinite(d) ? clamp(d, MIN_START_DISTANCE, MAX_START_DISTANCE) : MIN_START_DISTANCE;
}

/** The shake's strength (multiples of the jumpscare amplitude) `elapsed` seconds after startAt. */
export function shakeEnvelope(elapsed, cutAt = SEQUENCE.cut) {
  const t = elapsed;
  if (!Number.isFinite(t) || t < 0 || t >= cutAt + STATIC_CUT) return 0;
  const [from, to] = SEQUENCE.shake;
  const violent = 1.55 * smoothstep(from - 0.04, from + 0.06, t) * (1 - 0.45 * smoothstep(to - 0.06, to + 0.08, t));
  return 0.22 + 0.9 * bump(t, 0, 0.02, 9) + 1.3 * bump(t, SEQUENCE.tear, 0.02, 10) + 0.4 * smoothstep(0.12, 0.5, t) * (t < from ? 1 : 0) + violent;
}

/** The shake as a camera-space offset. */
export function shakeOffset(elapsed, motionScale, seed, cutAt) {
  const level = shakeEnvelope(elapsed, cutAt) * clamp01(finiteOr(motionScale, 1));
  if (level <= 0) return new CFrame();
  const x = elapsed * SHAKE_HZ;
  const wobble = (offset) => clamp(noise1(x, seed + offset), -1, 1);
  const turn = ((SHAKE_DEGREES * Math.PI) / 180) * level;
  const reach = SHAKE_STUDS * level;
  return new CFrame(wobble(43) * reach, wobble(59) * reach, 0)
    .mul(CFrame.angles(wobble(0) * turn, wobble(17) * turn * 0.8, wobble(31) * turn * 1.2));
}

/**
 * The victim's camera `elapsed` seconds after startAt: from their own eye (`eye`, when given) looking at the mask as it
 * swoops down, into the level lock on it by the end of the snap.
 */
export function cameraCFrame(face, elapsed, startDistance, motionScale, seed, hold = HOLD_DISTANCE, cutAt = SEQUENCE.cut, eye = null) {
  let frame = faceLock(face, maskDistance(elapsed, startDistance, motionScale, hold));
  const join = smoothstep(0, SEQUENCE.snap + 0.08, finiteOr(elapsed, 0));
  if (eye && isFiniteVector(eye) && join < 1 && isFiniteVector(face.position)) {
    const at = eye.clone().lerp(frame.position, join);
    if (at.distanceTo(face.position) > 0.05) frame = CFrame.lookAt(at, face.position, frame.upVector);
  }
  return frame.mul(shakeOffset(elapsed, motionScale, seed, cutAt));
}

function spike(t, at, seconds = FLASH_SECONDS) {
  const age = t - at;
  if (age < 0 || age >= seconds) return 0;
  const fall = 1 - age / seconds;
  return fall * fall;
}

/** A 0/1 gate that flickers on in random slots (rate per second, share on). */
function gate(t, rate, share, seed) {
  const slot = Math.floor(t * rate);
  const h = Math.sin(slot * 12.9898 + seed * 78.233) * 43758.5453;
  return h - Math.floor(h) < share ? 1 : 0;
}

/**
 * The screen `elapsed` seconds after startAt: {flash, red, vignette, black, split, slip, static, seed}. The tear starts
 * at the maw's tear and grows; static floods from SEQUENCE.staticFrom and fills the STATIC_CUT before the black.
 */
export function screen(elapsed, flashScale, motionScale, cutAt, beat, variant = Variants.Hallway) {
  const t = finiteOr(elapsed, 0);
  const flash = clamp01(finiteOr(flashScale, 1));
  const motion = clamp01(finiteOr(motionScale, 1));
  const cut = Math.max(finiteOr(cutAt, SEQUENCE.cut), 0);
  const hold = Math.max(finiteOr(beat, BEAT), 0);
  const none = { flash: 0, red: 0, vignette: 0, black: 0, split: 0, slip: 0, static: 0, seed: 0 };
  if (t < 0) return none;
  const seed = Math.floor(t * 18) % 97;
  if (t >= cut) {
    const inStatic = t < cut + STATIC_CUT;
    return {
      ...none,
      static: inStatic ? 0.85 * Math.max(flash, 0.35) * variant.static : 0,
      split: inStatic ? 0.02 * motion * variant.split : 0,
      slip: inStatic ? 0.06 * motion * variant.slip : 0,
      seed,
      black: inStatic ? 0 : 1 - smoothstep(cut + STATIC_CUT + hold, cut + STATIC_CUT + hold + FADE, t),
    };
  }
  const torn = smoothstep(SEQUENCE.tear - 0.02, cut, t);
  const burst = gate(t, 11, 0.3 + 0.45 * torn, 3) * (t > SEQUENCE.tear ? 1 : 0);
  const flood = smoothstep(Math.min(SEQUENCE.staticFrom, cut - 0.05), cut, t);
  const trough = 0.5 - 0.5 * Math.cos(Math.PI * 2 * VIGNETTE_HZ * t);
  const red = RED_PEAK * flash * smoothstep(SEQUENCE.flash + 0.03, SEQUENCE.flash + 0.07, t) * (1 - smoothstep(SEQUENCE.flash + 0.14, SEQUENCE.flash + 0.26, t));
  return {
    flash: FLASH_PEAK * flash * (0.55 * spike(t, 0) + spike(t, SEQUENCE.flash, 0.07)),
    red,
    vignette: VIGNETTE_PEAK * variant.edge * smoothstep(0, VIGNETTE_RISE, t) * (1 - VIGNETTE_PULSE * flash * trough),
    black: 0,
    split: (0.002 + 0.01 * torn + 0.016 * spike(t, SEQUENCE.tear, 0.18) + 0.02 * spike(t, SEQUENCE.flash, 0.2)) * motion * variant.split,
    slip: (0.003 + 0.028 * burst * torn + 0.045 * spike(t, SEQUENCE.tear, 0.14) + 0.05 * spike(t, SEQUENCE.flash, 0.16)) * motion * variant.slip,
    static: (0.06 * burst * torn + 0.75 * flood * flood) * Math.max(flash, 0.35) * variant.static,
    seed,
  };
}

/** The mask light's brightness `elapsed` seconds after startAt. */
export function faceLight(elapsed, flashScale, cutAt) {
  const t = finiteOr(elapsed, 0);
  const cut = Math.max(finiteOr(cutAt, SEQUENCE.cut), 0);
  if (t < 0 || t >= cut) return 0;
  const scale = clamp01(finiteOr(flashScale, 1));
  const level = LIGHT_HOLD + (LIGHT_FLARE - LIGHT_HOLD) * Math.exp(-LIGHT_FLARE_DECAY * t) + LIGHT_SLAM * spike(t, SEQUENCE.tear) + LIGHT_SLAM * spike(t, SEQUENCE.flash);
  const stutter = 0.5 + 0.5 * clamp(noise1(t * LIGHT_STUTTER_HZ, 5), -1, 1);
  return level * (1 - LIGHT_STUTTER * scale * stutter);
}

/** Seconds from startAt to the cut: the sequence's, or sooner when the catch's hold ends sooner. */
export function holdLength(startAt, endsAt) {
  const full = Math.min(LUNGE + HOLD, SEQUENCE.cut);
  if (endsAt === null || endsAt === undefined || !Number.isFinite(endsAt) || !Number.isFinite(startAt)) return full;
  const length = endsAt - startAt;
  if (length <= 0 || length > MAX_HOLD) return full;
  return Math.min(length, SEQUENCE.cut);
}

/** The reveal phantom's visibility (0..1) `t` seconds into it. */
export function revealFade(t) {
  const R = RevealConfig;
  if (!(t >= 0) || t > R.seconds + R.snapOut) return 0;
  return smoothstep(0, R.snapIn, t) * (1 - smoothstep(R.seconds, R.seconds + R.snapOut, t));
}

/** The torch's stutter (a share of its beam) `t` seconds into a reveal: it gutters, drops out, catches again. */
export function revealTorch(t) {
  const R = RevealConfig;
  if (!(t >= 0) || t > R.seconds + R.snapOut + 0.12) return 1;
  const out = gate(t, 26, 0.55, 17);
  const dip = R.torch + (1 - R.torch) * (0.25 + 0.4 * gate(t, 9, 0.5, 23));
  return out ? R.torch : dip;
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
    this.revealing = null;
    this.phantom = null;
  }

  /** The victim cue. @param {{kind: string, startAt: number, endsAt: number, face: THREE.Vector3}} cue */
  start(cue) {
    const now = this.env.renderTime();
    const start = Number.isFinite(cue.startAt) ? Math.min(cue.startAt, now + MAX_LEAD) : now;
    const cutAt = holdLength(start, cue.endsAt);
    if (now - start >= cutAt) return;
    if (this.session) this._end(this.session);
    this._endReveal();
    const kind = Variants[cue.kind] ? cue.kind : 'Hallway';
    this.session = {
      kind,
      variant: Variants[kind],
      startAt: start,
      cutAt,
      beat: BEAT,
      facePoint: cue.face && isFiniteVector(cue.face) ? cue.face.clone() : null,
      fallbackFace: new CFrame(),
      eye: null,
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
    this._endReveal();
  }

  isActive() {
    return this.session !== null;
  }

  isRevealing() {
    return this.revealing !== null;
  }

  _face(s) {
    const live = this.faceWorld();
    if (live && isFiniteVector(live.position)) return live;
    return s.fallbackFace;
  }

  _camera(s) {
    const elapsed = clamp(this.env.renderTime() - s.startAt, 0, s.cutAt);
    return cameraCFrame(this._face(s), elapsed, s.startDistance, s.motionScale, s.seed, s.variant.hold, s.cutAt, s.eye);
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
    s.eye = eye.clone();
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
    s.paint = this._buildPaint(s.variant);
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
    this._torch(1);
    this._tear(null);
    if (this.onEnded) this.onEnded();
  }

  /** Per render frame. */
  step() {
    // the reveal's phantom is built ahead of time, so a reveal never waits on it
    if (this.phantom === null && this.env.renderTime() > PHANTOM_WARMUP) this._phantom();
    this._stepReveal();
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
    // the camera holds on the mask through the static; the cut to black comes after it
    if (!s.cut && elapsed >= s.cutAt + STATIC_CUT) this._cut(s);
    if (!s.restored && elapsed >= s.cutAt + STATIC_CUT + s.beat) this._restore(s);
    const o = screen(elapsed, s.flashScale, s.motionScale, s.cutAt, s.beat, s.variant);
    this._paint(s, o);
    this._tear(o);
    if (s.light) {
      const cam = this._camera(s);
      s.light.set({
        position: cam.pointToWorld(new THREE.Vector3(...LIGHT_UNDER)),
        brightness: faceLight(elapsed, s.flashScale, s.cutAt) * s.variant.light,
      });
    }
    // the victim's torch gutters through the catch: the mask's own light models it
    this._torch(s.cut ? 1 : TORCH_DIM + (1 - TORCH_DIM) * 0.25 * gate(elapsed, 13, 0.3, 11));
    if (elapsed >= s.cutAt + STATIC_CUT + s.beat + FADE) this._end(s);
  }

  // ------------------------------------------------------------------ the screen

  /** Drives the post pass's screen-tear hook and its red flash (null clears both). */
  _tear(o) {
    const renderer = this.env.engine && this.env.engine.renderer;
    const post = renderer && renderer.postUniforms;
    const u = post && post.uTear;
    if (!u) return;
    if (!o) u.value.set(0, 0, 0, 0);
    else u.value.set(o.split, o.slip, clamp01(o.static), o.seed);
    if (post.uTearTint) post.uTearTint.value.set(...RED_TINT, o ? clamp01((o.red || 0) * 1.5) : 0);
  }

  _buildPaint(variant) {
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
    const edge = `rgba(${EDGE_RGB},1)`;
    const fadeTo = `rgba(${EDGE_RGB},0.5) 45%, rgba(${EDGE_RGB},0) 100%`;
    const edges = [
      layer(`bottom:auto;height:34%;background:linear-gradient(180deg, ${edge} 0%, ${fadeTo});`),
      layer(`top:auto;height:34%;background:linear-gradient(0deg, ${edge} 0%, ${fadeTo});`),
      layer(`right:auto;width:30%;background:linear-gradient(90deg, ${edge} 0%, ${fadeTo});`),
      layer(`left:auto;width:30%;background:linear-gradient(270deg, ${edge} 0%, ${fadeTo});`),
    ];
    const tint = variant.tint ? layer(`background:rgb(${variant.tint[0]},${variant.tint[1]},${variant.tint[2]});`) : null;
    const paint = {
      root,
      edges,
      tint,
      tintAlpha: variant.tint ? variant.tint[3] : 0,
      flash: layer(`background:${COLD_WHITE};`),
      black: layer('background:#000;'),
      written: new Map(),
    };
    parent.appendChild(root);
    return paint;
  }

  _paint(s, o) {
    const paint = s.paint;
    if (!paint) return;
    const set = (el, value) => {
      const v = clamp01(value);
      const last = paint.written.get(el);
      if (last !== undefined && Math.abs(last - v) < 0.002 && (v > 0 || last === 0)) return;
      paint.written.set(el, v);
      el.style.opacity = String(v);
    };
    for (const e of paint.edges) set(e, o.vignette);
    if (paint.tint) set(paint.tint, o.black > 0 ? 0 : paint.tintAlpha * smoothstep(0, 0.1, this.env.renderTime() - s.startAt));
    set(paint.flash, o.flash);
    set(paint.black, o.black);
  }

  // ------------------------------------------------------------------ the reveal

  /**
   * The lighter scare (no catch): the mask snaps into view ahead of the camera with a sting and a jolt.
   * @param {string} [kind] 'Teleport' (default), 'FakeOut', 'Locker' (inches away, a shriek), 'Stare'
   * @param {{distance?: number, side?: number}} [opts]
   * @returns {boolean} whether it played (not during a catch)
   */
  reveal(kind = 'Teleport', opts = {}) {
    if (this.session) return false;
    const env = this.env;
    const eye = env.playerEye ? env.playerEye() : null;
    const look = env.playerLookVector ? env.playerLookVector() : null;
    if (!eye || !look || !isFiniteVector(eye) || !isFiniteVector(look)) return false;
    const R = RevealConfig;
    const k = String(kind || 'Teleport').toLowerCase();
    const close = k === 'locker' || k === 'fakeout' || k === 'barrel' || k === 'cabinet';
    let distance = finiteOr(opts.distance, close ? R.lockerDistance : R.distance);
    // never inside a wall: pull it in until the line from the eye is clear
    while (distance > 1.1 && env.lineClear && !env.lineClear(eye, eye.clone().addScaledVector(look, distance + 0.4))) distance -= 0.4;
    const flat = new THREE.Vector3(look.x, 0, look.z);
    const right = flat.lengthSq() > 1e-6 ? new THREE.Vector3(-flat.z, 0, flat.x).normalize() : new THREE.Vector3(1, 0, 0);
    const side = opts.side === -1 || opts.side === 1 ? opts.side : Math.random() < 0.5 ? -1 : 1;
    const at = eye.clone().addScaledVector(look, distance).addScaledVector(right, side * (close ? 0.12 : R.offset));
    at.y -= close ? 0.05 : 0.25;
    this._endReveal();
    const now = env.renderTime();
    const phantom = this._phantom();
    const motion = clamp01(finiteOr(env.setting('MotionScale'), 1));
    const flash = clamp01(finiteOr(env.setting('FlashScale'), 1));
    this.revealing = { kind, startAt: now, at, eye: eye.clone(), side, motion, flash, light: null, phantom };
    if (phantom) this._posePhantom(this.revealing, 0);
    const r = this.revealing;
    // a cold light from one side and a little above: half the mask in shadow (the side it cocks toward)
    const lightAt = at.clone().addScaledVector(right, -side * Math.min(1.5, distance * 0.55)).addScaledVector(flat.lengthSq() > 1e-6 ? flat.normalize() : look, -Math.min(0.9, distance * 0.3));
    lightAt.y += 0.35;
    r.light = env.addLight({ position: lightAt, color: LIGHT_COLOR, brightness: 0, range: distance + 2.5 });
    // a fake-out's shriek is the game's own (FakeoutShriek); the other locker kinds shriek here, the rest sting
    if (k !== 'fakeout') env.play(close ? 'Screech' : 'JumpscareSting', { volume: close ? 0.75 : 0.85 });
    const player = env.engine && env.engine.player;
    if (player && typeof player.shake === 'function') player.shake(R.jolt * motion, R.joltSeconds);
    this._stepReveal();
    return true;
  }

  _phantom() {
    if (this.phantom !== null) return this.phantom || null;
    this.phantom = false;
    try {
      const meta = this.env.meta();
      const model = this.env.createCreatureModel();
      const look = applyCreatureLook(model, meta, this.env.engine && this.env.engine.quality ? this.env.engine.quality.budget : null);
      const bones = meta.creature.bones;
      const rest = bones.map((b) => CFrame.fromComponents(b.rest));
      const head = bones.find((b) => b.name === 'Head');
      const face = (meta.creature.attachments || []).find((a) => a.name === 'FaceFrontAttachment');
      const faceModel = head && face ? CFrame.fromComponents(head.rest).mul(CFrame.fromComponents(face.cframe)) : new CFrame(0, 10.3, -1.5);
      // only the head, the mask, the tatters, the chest and the arms snap in; the rest stays in the dark
      const shown = (name) => /^(Head|Jaw|Hair|UpperTorso|LeftUpperArm|RightUpperArm|LeftLowerArm|RightLowerArm)/.test(name);
      bones.forEach((b, i) => model.setVisible(shown(b.name), i));
      model.object.visible = false;
      this.env.addToScene(model.object);
      this.phantom = { model, look, rest, faceModelInverse: faceModel.inverse(), bones };
    } catch (err) {
      console.warn('[creature] no reveal phantom', err);
      this.phantom = false;
    }
    return this.phantom || null;
  }

  _posePhantom(r, t) {
    const p = r.phantom;
    // the mask looks straight at the eye, cocked over, with a glitching jitter that settles
    const jitter = (1 - smoothstep(0, 0.2, t)) * 0.12;
    const cock = r.side * (RevealConfig.cock + 0.1 * Math.sin(t * 40) * jitter * 4);
    const face = CFrame.lookAt(r.at, r.eye).mul(CFrame.angles(0.06 + jitter * Math.sin(t * 57), jitter * Math.sin(t * 43), cock));
    const placement = face.mul(p.faceModelInverse);
    for (let i = 0; i < p.rest.length; i++) p.model.setBoneWorld(i, placement.mul(p.rest[i]).toMatrix4(_m));
    p.model.setLight(this.env.probeAt(r.at, _c));
    p.model.flush();
  }

  _stepReveal() {
    const r = this.revealing;
    if (!r) return;
    const t = this.env.renderTime() - r.startAt;
    const R = RevealConfig;
    const fade = revealFade(t);
    if (t > R.seconds + R.snapOut + 0.05) {
      this._endReveal();
      return;
    }
    if (r.phantom) {
      r.phantom.model.object.visible = fade > 0.01;
      this._posePhantom(r, t);
      // the room's light falls away from it: the cold light from one side leaves half the mask in shadow
      r.phantom.look.set({ fade: Math.max(fade, 0.001), time: this.env.renderTime(), pupil: 1, fx: REVEAL_FX });
    }
    if (r.light) r.light.set({ brightness: R.light * fade * (0.75 + 0.25 * gate(t, 22, 0.6, 5)) });
    // the torch stutters on it
    this._torch(1 - (1 - revealTorch(t)) * Math.max(r.flash, 0.5));
    const kick = 1 - smoothstep(0, R.seconds + R.snapOut, t);
    this._tear({
      split: 0.012 * kick * r.motion,
      slip: (0.025 * gate(t, 14, 0.5, 9) + 0.01) * kick * r.motion,
      static: 0.22 * kick * kick * Math.max(r.flash, 0.3),
      seed: Math.floor(t * 20) % 97,
    });
  }

  _endReveal() {
    const r = this.revealing;
    if (!r) return;
    this.revealing = null;
    if (r.phantom) r.phantom.model.object.visible = false;
    if (r.light) r.light.remove();
    this._torch(1);
    if (!this.session) this._tear(null);
  }

  /** The torch's beam share (the flashlight's stutter hook; 1 lets it be). */
  _torch(share) {
    const player = this.env.engine && this.env.engine.player;
    const f = player && player.flashlight;
    if (f && 'stutter' in f) f.stutter = share;
  }
}

const _m = new THREE.Matrix4();
const _c = new THREE.Color();
