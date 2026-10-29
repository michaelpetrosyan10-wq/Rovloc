// First-person camera pieces ported from FirstPersonController: CameraRig (look input maths, the eye pivot),
// CameraStates (MoveState -> camera state, eye offsets, pitch ranges, bob profiles), ViewBob (gait bob, breathing
// sway, shake) and CameraStack (priority overrides blended over the base view).

import * as THREE from 'three';
import { CameraConfig, GameConfig } from './config.js';
import { clamp, clamp01, damp, dampNumber, lerp, noise1, rad, smoothstep } from './math.js';

// ---------------------------------------------------------------------------------------------------------------
// CameraRig
// ---------------------------------------------------------------------------------------------------------------

export const CameraRig = Object.freeze({
  GamepadDeadzone: 0.14,
  GamepadExponent: 1.7,
  PitchRatio: 0.75,
  NeckShare: 0.6,
  DefaultEye: Object.freeze({ neckHeight: 0.9, neckForward: 0, eyeUp: 0.6, eyeForward: 0.3 }),
});

const BOOST_THRESHOLD = 0.92;
const BOOST_DELAY = 0.22;
const BOOST_RAMP = 0.35;
const BOOST_MAX = 1.6;
const SETTLE_SPEED = 10;
const SETTLE_MIN_RATE = 0.6;

/** Radial deadzone + power curve; keeps the stick's direction. */
export function gamepadCurve(x, y, deadzone = CameraRig.GamepadDeadzone, exponent = CameraRig.GamepadExponent) {
  const m = Math.hypot(x, y);
  if (m <= deadzone || !Number.isFinite(m)) return { x: 0, y: 0 };
  const n = Math.min((m - deadzone) / (1 - deadzone), 1) ** exponent;
  return { x: (x / m) * n, y: (y / m) * n };
}

export function turnBoost(heldSeconds) {
  return 1 + (BOOST_MAX - 1) * clamp01((heldSeconds - BOOST_DELAY) / BOOST_RAMP);
}

/** Adds an input delta to pitch without letting input push past a limit. */
export function applyPitch(pitch, delta, minPitch, maxPitch) {
  if (delta > 0) return Math.min(pitch + delta, Math.max(pitch, maxPitch));
  if (delta < 0) return Math.max(pitch + delta, Math.min(pitch, minPitch));
  return pitch;
}

/** Eases a pitch outside [min, max] back inside. */
export function settlePitch(pitch, minPitch, maxPitch, dt) {
  if (pitch > maxPitch) {
    const eased = dampNumber(pitch, maxPitch, SETTLE_SPEED, dt);
    return Math.max(maxPitch, Math.min(eased, pitch - SETTLE_MIN_RATE * dt));
  }
  if (pitch < minPitch) {
    const eased = dampNumber(pitch, minPitch, SETTLE_SPEED, dt);
    return Math.min(minPitch, Math.max(eased, pitch + SETTLE_MIN_RATE * dt));
  }
  return pitch;
}

/** Look input -> (dYaw, dPitch) for this frame, with the gamepad yaw boost state. */
export class LookInput {
  constructor() {
    this.boostHeld = 0;
  }

  /**
   * @param {number} dt
   * @param {{mouse: {x: number, y: number}, touch: {x: number, y: number}, stick: {x: number, y: number}}} raw
   * @param {{mouse: number, gamepad: number, touch: number, invertY: boolean}} s
   */
  consume(dt, raw, s) {
    const invert = s.invertY ? -1 : 1;
    const M = CameraConfig.Mouse;
    let yaw = -raw.mouse.x * M.RadiansPerPixel * s.mouse;
    let pitch = -raw.mouse.y * M.RadiansPerPixel * s.mouse * invert;
    yaw -= raw.touch.x * M.TouchRadiansPerPixel * s.touch;
    pitch -= raw.touch.y * M.TouchRadiansPerPixel * s.touch * invert;
    const c = gamepadCurve(raw.stick.x, raw.stick.y);
    if (Math.abs(c.x) >= BOOST_THRESHOLD) this.boostHeld += dt;
    else this.boostHeld = 0;
    const rate = M.GamepadRadiansPerSecond * s.gamepad * dt;
    yaw -= c.x * rate * turnBoost(this.boostHeld);
    pitch += c.y * rate * CameraRig.PitchRatio * invert;
    return { yaw, pitch };
  }

  reset() {
    this.boostHeld = 0;
  }
}

/** The eye relative to the root centre for a look, before any camera-state offset (CameraRig.eyeOffset). */
export function eyeOffset(metrics, yaw, pitch, out = new THREE.Vector3()) {
  const sy = Math.sin(yaw);
  const cy = Math.cos(yaw);
  // heading forward (-Z rotated by yaw)
  const fx = -sy;
  const fz = -cy;
  const neckPitch = pitch * CameraRig.NeckShare;
  // neckTurn * (0, eyeUp, -eyeForward): pitch about X then yaw about Y
  const up = metrics.eyeUp;
  const fw = metrics.eyeForward;
  const cp = Math.cos(neckPitch);
  const sp = Math.sin(neckPitch);
  const localY = up * cp + fw * sp;
  const localF = -up * sp + fw * cp; // distance along forward
  out.set(
    fx * (metrics.neckForward + localF),
    metrics.neckHeight + localY,
    fz * (metrics.neckForward + localF),
  );
  return out;
}

// ---------------------------------------------------------------------------------------------------------------
// CameraStates
// ---------------------------------------------------------------------------------------------------------------

const MOVE_TO_CAMERA = {
  Standing: 'Standing', Sprinting: 'Standing', Crouching: 'Crouching', VentCrawling: 'VentCrawling',
  VentScurrying: 'VentCrawling', DownedCrawling: 'DownedCrawling', Treading: 'SurfaceSwimming',
  Freestyle: 'SurfaceSwimming', Underwater: 'UnderwaterSwimming', Hiding: 'LockerPeeking', Trapped: 'Standing',
  Grabbed: 'UnderwaterSwimming', Parachuting: 'Standing', Scripted: 'Standing',
};
const PRIMARY_MOVE = {
  Standing: 'Standing', Crouching: 'Crouching', VentCrawling: 'VentCrawling', DownedCrawling: 'DownedCrawling',
  LockerPeeking: 'Hiding', SurfaceSwimming: 'Treading', UnderwaterSwimming: 'Underwater',
  ParachuteLookback: 'Parachuting',
};
const P = CameraConfig.Pitch;
const PITCH = {
  Standing: [P.Min, P.Max], Crouching: [P.Min, P.Max], VentCrawling: [P.VentMin, P.VentMax],
  DownedCrawling: [-50, 65], LockerPeeking: [-25, 25], SurfaceSwimming: [-70, 75],
  UnderwaterSwimming: [P.Min, P.Max], ParachuteLookback: [P.Min, P.Max],
};
const B = CameraConfig.Bob;
const STILL = { amplitude: 0, frequency: 1, nominalSpeed: GameConfig.WalkSpeed };
const BOB = {
  Standing: { amplitude: 1, frequency: 1, nominalSpeed: GameConfig.WalkSpeed },
  Sprinting: { amplitude: B.SprintMultiplier, frequency: 1.32, nominalSpeed: GameConfig.SprintSpeed },
  Crouching: { amplitude: B.CrouchMultiplier, frequency: 0.8, nominalSpeed: GameConfig.CrouchSpeed },
  VentCrawling: { amplitude: B.VentMultiplier, frequency: 0.7, nominalSpeed: GameConfig.VentCrawlSpeed },
  VentScurrying: { amplitude: B.VentMultiplier * 1.4, frequency: 0.95, nominalSpeed: GameConfig.VentScurrySpeed },
  DownedCrawling: { amplitude: 0.9, frequency: 0.5, nominalSpeed: GameConfig.DownedMoveSpeed },
  Treading: { amplitude: 0.35, frequency: 0.45, nominalSpeed: GameConfig.TreadSpeed },
  Freestyle: { amplitude: 0.6, frequency: 0.65, nominalSpeed: GameConfig.FreestyleSpeed },
  Underwater: { amplitude: 0.3, frequency: 0.4, nominalSpeed: GameConfig.UnderwaterSpeed },
  Hiding: STILL, Trapped: STILL, Grabbed: STILL, Parachuting: STILL, Scripted: STILL,
};

export const CameraStates = Object.freeze({
  List: Object.freeze(['Standing', 'Crouching', 'VentCrawling', 'DownedCrawling', 'LockerPeeking',
    'SurfaceSwimming', 'UnderwaterSwimming', 'ParachuteLookback']),
  fromMoveState: (moveState) => MOVE_TO_CAMERA[moveState] || 'Standing',
  /** Vertical trim of a MoveState relative to its camera state's primary MoveState. */
  eyeTrim(moveState, cameraState) {
    const primary = PRIMARY_MOVE[cameraState];
    if (!primary || MOVE_TO_CAMERA[moveState] !== cameraState) return 0;
    const H = CameraConfig.EyeHeightAboveRoot;
    return (H[moveState] ?? H.Standing) - (H[primary] ?? H.Standing);
  },
  /** Eye offset from the standing eye, in camera-yaw space. */
  offset(moveState, forced, out = new THREE.Vector3()) {
    const cs = forced || CameraStates.fromMoveState(moveState);
    const base = CameraConfig.StateOffsets[cs] || [0, 0, 0];
    return out.set(base[0], base[1] + CameraStates.eyeTrim(moveState, cs), base[2]);
  },
  /** Pitch range of a camera state (degrees). */
  pitchLimits: (cs) => PITCH[cs] || PITCH.Standing,
  bob: (moveState) => BOB[moveState] || BOB.Standing,
});

// ---------------------------------------------------------------------------------------------------------------
// ViewBob
// ---------------------------------------------------------------------------------------------------------------

const TAU = Math.PI * 2;
const S = CameraConfig.Shake;
const INTENSITY_SMOOTH = 7;
const AIR_INTENSITY = 0.2;
const MAX_INTENSITY = 1.25;
const MIN_CADENCE = 0.55;
const PITCH_LAG = 0.6;
const LATERAL_SHARE = 0.35;
const BREATH_RATE_PANIC = 1.6;
const BREATH_YAW_SHARE = 0.35;
const IDLE_SPEED = 0.6;
const SHAKE_TAIL = 0.25;
const SHAKE_EXTRA = 0.35;
const MAX_IMPULSES = 8;
const SHAKE_SEED = 7;

export function bobAt(phase, intensity, amplitude) {
  const theta = TAU * phase;
  const scale = intensity * amplitude;
  return {
    vertical: -B.WalkVertical * scale * Math.cos(2 * theta),
    pitch: -B.WalkPitch * scale * Math.cos(2 * theta - PITCH_LAG),
    roll: B.WalkRoll * scale * Math.sin(theta),
    lateral: B.WalkVertical * LATERAL_SHARE * scale * Math.sin(theta),
  };
}

export function breathAt(phase, panic) {
  const depth = B.IdleBreathPitch * (1 + (B.PanicBreathMultiplier - 1) * clamp01(panic));
  return { pitch: depth * Math.sin(TAU * phase), yaw: depth * BREATH_YAW_SHARE * Math.sin(Math.PI * phase + 1.3) };
}

export const breathRate = (panic) => B.IdleBreathFrequency * (1 + BREATH_RATE_PANIC * clamp01(panic));

export function shakeEnvelope(age, seconds, decay) {
  if (age < 0 || seconds <= 0 || age >= seconds) return 0;
  const tail = Math.min(SHAKE_TAIL, seconds);
  return Math.exp(-decay * age) * clamp01((seconds - age) / tail);
}

export function bobIntensity(speed, profile, grounded) {
  if (profile.amplitude <= 0 || profile.nominalSpeed <= 0) return 0;
  const ratio = clamp(speed / profile.nominalSpeed, 0, MAX_INTENSITY);
  return grounded ? ratio : ratio * AIR_INTENSITY;
}

export class ViewBob {
  constructor() {
    this.reset();
    this.matrix = new THREE.Matrix4();
    this._e = new THREE.Euler(0, 0, 0, 'YXZ');
    /** @type {Array<{amplitude: number, seconds: number, age: number}>} */
    this.impulses = [];
  }

  reset() {
    this.phase = 0;
    this.intensity = 0;
    this.amplitude = 1;
    this.breathPhase = 0;
    this.clock = 0;
    if (this.impulses) this.impulses.length = 0;
  }

  /**
   * One frame of bob; returns the offset matrix (applied to the eye in look space) and whether a footfall happened.
   * @param {number} dt
   * @param {{speed: number, profile: any, panic: number, motionScale: number, chase: number, grounded: boolean}} i
   */
  step(dt, i) {
    this.clock += dt;
    const profile = i.profile;
    const blend = damp(INTENSITY_SMOOTH, dt);
    this.intensity = lerp(this.intensity, bobIntensity(i.speed, profile, i.grounded), blend);
    this.amplitude = lerp(this.amplitude, profile.amplitude, blend);
    let footfall = false;
    if (this.intensity > 1e-3 && profile.nominalSpeed > 0) {
      const cadence = clamp(i.speed / profile.nominalSpeed, MIN_CADENCE, MAX_INTENSITY);
      const before = this.phase;
      this.phase = (this.phase + dt * B.WalkFrequency * profile.frequency * cadence) % 1;
      // two footfalls per gait cycle: at the eye's lowest points (phase 0 and 0.5)
      if ((before < 0.5 && this.phase >= 0.5) || this.phase < before) footfall = true;
    }
    this.breathPhase = (this.breathPhase + dt * breathRate(i.panic)) % 2;
    const b = bobAt(this.phase, this.intensity, this.amplitude);
    const idle = 1 - clamp01(this.intensity / IDLE_SPEED);
    const br = breathAt(this.breathPhase, i.panic);
    const share = 0.35 + 0.65 * idle;
    let pitch = b.pitch + br.pitch * share;
    let yaw = br.yaw * share;
    let roll = b.roll;
    let lead = 0;
    let extra = 0;
    for (let k = this.impulses.length - 1; k >= 0; k--) {
      const imp = this.impulses[k];
      imp.age += dt;
      const level = imp.amplitude * shakeEnvelope(imp.age, imp.seconds, S.Decay);
      if (imp.age >= imp.seconds) this.impulses.splice(k, 1);
      else if (level > lead) {
        extra += lead;
        lead = level;
      } else extra += level;
    }
    const shake = lead + extra * SHAKE_EXTRA + S.ChaseAmplitude * clamp01(i.chase);
    if (shake > 1e-4) {
      const x = this.clock * S.Frequency;
      pitch += shake * noise1(x, SHAKE_SEED);
      yaw += shake * 0.8 * noise1(x, SHAKE_SEED + 17);
      roll += shake * 0.6 * noise1(x, SHAKE_SEED + 31);
    }
    const m = clamp01(i.motionScale);
    this._e.set(rad(pitch * m), rad(yaw * m), rad(roll * m), 'YXZ');
    this.matrix.makeRotationFromEuler(this._e);
    this.matrix.setPosition(b.lateral * m, b.vertical * m, 0);
    return { matrix: this.matrix, footfall, intensity: this.intensity };
  }

  /** Adds a shake impulse (degrees, seconds). */
  shake(amplitudeDeg, seconds) {
    if (!(amplitudeDeg > 0 && seconds > 0)) return;
    this.impulses.push({ amplitude: Math.min(amplitudeDeg, 20), seconds: Math.min(seconds, 30), age: 0 });
    while (this.impulses.length > MAX_IMPULSES) this.impulses.shift();
  }
}

// ---------------------------------------------------------------------------------------------------------------
// CameraStack
// ---------------------------------------------------------------------------------------------------------------

export const OverridePriority = Object.freeze({ Trapped: 1, Struggle: 2, Spectating: 3, Jumpscare: 4, Cutscene: 5 });
const DEFAULT_BLEND_IN = 0.35;
const DEFAULT_BLEND_OUT = 0.5;

/**
 * Priority camera overrides. A source supplies a function returning the camera frame (a Matrix4 or
 * {position, quaternion} or {position, lookAt}) plus optional fov / blendIn / blendOut. Layers blend in ascending
 * priority: result = lerp(result, layer, smoothstep(weight)).
 */
export class CameraStack {
  constructor() {
    /** @type {Array<{token: string, priority: number, fn: Function, fov?: number, blendIn: number, blendOut: number, weight: number, active: boolean}>} */
    this.layers = [];
  }

  /**
   * @param {string} token a name for the layer (CameraOverride kinds are the Roblox ones: Trapped, Struggle,
   *   Spectating, Jumpscare, Cutscene)
   * @param {Function|null} fn
   * @param {number|{priority?: number, fov?: number, blendIn?: number, blendOut?: number}} [priority]
   */
  set(token, fn, priority) {
    const existing = this.layers.find((l) => l.token === token);
    if (!fn) {
      if (existing) existing.active = false;
      return;
    }
    const opts = typeof priority === 'object' && priority ? priority : { priority };
    const pr = opts.priority ?? OverridePriority[token] ?? 3;
    if (existing) {
      existing.fn = fn;
      existing.active = true;
      existing.priority = pr;
      existing.fov = opts.fov;
      existing.blendIn = opts.blendIn ?? DEFAULT_BLEND_IN;
      existing.blendOut = opts.blendOut ?? DEFAULT_BLEND_OUT;
    } else {
      this.layers.push({
        token, priority: pr, fn, fov: opts.fov, blendIn: opts.blendIn ?? DEFAULT_BLEND_IN,
        blendOut: opts.blendOut ?? DEFAULT_BLEND_OUT, weight: 0, active: true,
      });
    }
    this.layers.sort((a, b) => a.priority - b.priority);
  }

  clear(instant) {
    if (instant) this.layers.length = 0;
    else for (const l of this.layers) l.active = false;
  }

  step(dt) {
    for (let i = this.layers.length - 1; i >= 0; i--) {
      const l = this.layers[i];
      if (l.active) l.weight = l.blendIn <= 0 ? 1 : Math.min(1, l.weight + dt / l.blendIn);
      else l.weight = l.blendOut <= 0 ? 0 : Math.max(0, l.weight - dt / l.blendOut);
      if (!l.active && l.weight <= 0) this.layers.splice(i, 1);
    }
  }

  /** Blends the layers over the base frame. Returns { position, quaternion, fov }. */
  evaluate(basePos, baseQuat, baseFov) {
    const pos = _p.copy(basePos);
    const quat = _q.copy(baseQuat);
    let fov = baseFov;
    for (const l of this.layers) {
      const share = smoothstep(0, 1, l.weight);
      if (share <= 0) continue;
      let frame;
      try {
        frame = l.fn();
      } catch (err) {
        console.warn('[camera] override', l.token, 'failed', err);
        continue;
      }
      if (!frame) continue;
      readFrame(frame, _lp, _lq);
      const layerFov = frame.fov ?? l.fov;
      pos.lerp(_lp, share);
      quat.slerp(_lq, share);
      if (layerFov) fov = lerp(fov, layerFov, share);
    }
    return { position: pos, quaternion: quat, fov };
  }

  coverage() {
    let base = 1;
    for (const l of this.layers) base *= 1 - smoothstep(0, 1, l.weight);
    return 1 - base;
  }

  top() {
    for (let i = this.layers.length - 1; i >= 0; i--) if (this.layers[i].active) return this.layers[i].token;
    return null;
  }
}

const _p = new THREE.Vector3();
const _q = new THREE.Quaternion();
const _lp = new THREE.Vector3();
const _lq = new THREE.Quaternion();
const _ls = new THREE.Vector3();
const _lm = new THREE.Matrix4();

function readFrame(frame, pos, quat) {
  if (frame.isMatrix4) {
    frame.decompose(pos, quat, _ls);
    return;
  }
  if (Array.isArray(frame)) {
    const c = frame;
    _lm.set(c[3], c[4], c[5], c[0], c[6], c[7], c[8], c[1], c[9], c[10], c[11], c[2], 0, 0, 0, 1);
    _lm.decompose(pos, quat, _ls);
    return;
  }
  pos.copy(frame.position);
  if (frame.quaternion) quat.copy(frame.quaternion);
  else if (frame.lookAt) {
    _lm.lookAt(frame.position, frame.lookAt, frame.up || _up);
    quat.setFromRotationMatrix(_lm);
  }
}
const _up = new THREE.Vector3(0, 1, 0);
