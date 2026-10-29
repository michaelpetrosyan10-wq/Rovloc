// CreatureBody (MonsterAIService/CreatureBody.luau) plus the Humanoid it rode on in Roblox.
//
//   * Pose: SetPose(poseMode) changes the hitbox (CreatureConfig.Hitbox): tall for Biped, shorter for Hunched, a low
//     long box on the rail for Quadruped, on the water line for Swim.
//   * Hidden: a hidden Creature's hitbox stops answering queries; the view hides the rig.
//   * Kinematic modes (the vent rail, swimming, scripted holds, dormancy) anchor the root and place it by CFrame; the
//     floor mode leaves it unanchored and the walker (the Humanoid) walks it at WalkSpeed toward its MoveTo target,
//     turning with AutoRotate.
//   * Facing on the floor: Face(direction) turns the root toward a direction with AutoRotate off (the
//     AlignOrientation, responsiveness 14); Face(null) hands rotation back. Anchored, the root is turned directly.
//   * The walker collides like the Humanoid: only its root box (HipHeight above the floor, RootSize tall) meets the
//     world, against the Monster group's geometry (env.monsterColliders: Default parts and Default-group entity
//     colliders; MonsterPassthrough desks, lockers and door leaves are walked through). Below it a floor probe keeps
//     the root HipHeight + RootSize.Y / 2 above whatever floor it stands on, stepping up and down small ledges; with
//     no floor in reach it falls under gravity (walking off a pool coping drops it into the water).
//   * Stuck detection is a pure tracker: no progress of MinProgress studs for Repath.StuckSeconds while trying to move.

import * as THREE from 'three';
import { CFrame } from './cframe.js';
import { CreatureConfig, ROOT_HEIGHT } from './config.js';
import { flatDirection, wrapAngle } from './util.js';

export const MIN_PROGRESS = 1.2;
const FACE_RESPONSIVENESS = 14;
const AUTO_ROTATE_SPEED = 12;
const ARRIVE_EPSILON = 0.15;
const GRAVITY = 196.2;
const STEP_UP = 1.6; // ledges the Humanoid walks up
const SNAP_DOWN = 1.2; // a grounded walker follows the floor down this far
const BODY_RADIUS = 1.0; // the root box (2.6 wide, 1.4 deep) as a capsule
const BODY_BOTTOM = CreatureConfig.Rig.HipHeight; // root box bottom above the floor
const BODY_TOP = CreatureConfig.Rig.HipHeight + CreatureConfig.Rig.RootSize[1];
const SUBSTEP = 0.4;
const PUSH_ITERATIONS = 3;

/** No progress of `minProgress` studs for `seconds` while trying to move (pure; the caller samples it). */
export class StuckTracker {
  constructor(seconds, minProgress = MIN_PROGRESS) {
    this.seconds = seconds;
    this.need = minProgress;
    /** @type {THREE.Vector3|null} */
    this.anchor = null;
    this.since = 0;
  }

  /** @param {THREE.Vector3} position @param {number} now @param {boolean} trying */
  sample(position, now, trying) {
    const from = this.anchor;
    if (!trying || from === null) {
      this.anchor = position.clone();
      this.since = now;
      return false;
    }
    if (position.distanceTo(from) >= this.need) {
      this.anchor = position.clone();
      this.since = now;
      return false;
    }
    if (now - this.since >= this.seconds) {
      this.anchor = position.clone();
      this.since = now;
      return true;
    }
    return false;
  }

  reset() {
    this.anchor = null;
    this.since = 0;
  }
}

/**
 * @typedef {Object} BodyPhysics the world queries the walker needs (env.js provides them)
 * @property {(position: THREE.Vector3, radius: number, bottom: number, top: number) => THREE.Vector3} pushOut
 *   resolves a capsule (vertical segment from `bottom` to `top` world Y at `position`'s XZ) out of the Monster
 *   geometry; returns the corrected XZ position (y untouched)
 * @property {(x: number, z: number, fromY: number, maxDrop: number) => number[]} floorHits Monster-geometry floor
 *   heights under (x, z) between fromY and fromY - maxDrop (upward-facing surfaces), highest first
 */

export class CreatureBody {
  /** @param {BodyPhysics} physics */
  constructor(physics) {
    this.physics = physics;
    this.cframe = new CFrame();
    /** @type {'Biped'|'Hunched'|'Quadruped'|'Swim'} */
    this.pose = 'Biped';
    this.anchored = true;
    this.hidden = false;
    this.walkSpeed = 0;
    this.autoRotate = true;
    /** @type {THREE.Vector3|null} AlignOrientation target direction (flat unit) */
    this.faceDirection = null;
    /** @type {THREE.Vector3|null} Humanoid MoveTo target */
    this.moveTarget = null;
    this.velocity = new THREE.Vector3();
    this.verticalSpeed = 0;
    this.grounded = true;
    /** Bumped on every teleport (the view snaps instead of interpolating). */
    this.placements = 0;
    this.hitbox = CreatureConfig.Hitbox.Biped;
  }

  /** @param {'Biped'|'Hunched'|'Quadruped'|'Swim'} pose */
  setPose(pose) {
    if (this.pose === pose) return;
    this.pose = pose;
    this.hitbox = CreatureConfig.Hitbox[pose] || CreatureConfig.Hitbox.Biped;
  }

  setAnchored(anchored) {
    this.anchored = anchored;
    if (!anchored) {
      this.verticalSpeed = 0;
      this.velocity.set(0, 0, 0);
    } else {
      // anchoring disables the AlignOrientation; AutoRotate keeps its setting (CreatureBody.SetAnchored)
      this.faceDirection = null;
    }
  }

  setHidden(hidden) {
    this.hidden = hidden;
  }

  setWalkSpeed(speed) {
    this.walkSpeed = speed;
  }

  /** Face(direction | null). @param {THREE.Vector3|null} direction */
  face(direction) {
    const f = direction ? flatDirection(direction) : null;
    if (!f) {
      this.faceDirection = null;
      this.autoRotate = true;
      return;
    }
    if (this.anchored) {
      const p = this.cframe.position;
      this.cframe = CFrame.lookAt(p, p.clone().add(f));
      return;
    }
    this.autoRotate = false;
    this.faceDirection = f;
  }

  /** PlaceAt(cframe): a teleport. @param {CFrame} cframe */
  placeAt(cframe) {
    this.cframe = cframe;
    this.velocity.set(0, 0, 0);
    this.verticalSpeed = 0;
    this.placements++;
  }

  /** Sets the root frame (kinematic motion; not a teleport). @param {CFrame} cframe */
  setCFrame(cframe) {
    this.cframe = cframe;
  }

  getCFrame() {
    return this.cframe;
  }

  getPosition() {
    return this.cframe.position;
  }

  /** Humanoid:MoveTo(target) (null stops). @param {THREE.Vector3|null} target */
  moveTo(target) {
    this.moveTarget = target ? target.clone() : null;
  }

  /** One physics step of the walker (nothing while anchored). @param {number} dt */
  stepPhysics(dt) {
    if (this.anchored || dt <= 0) return;
    const p = this.cframe.position;
    // walk toward the MoveTo target at WalkSpeed
    let vx = 0;
    let vz = 0;
    const target = this.moveTarget;
    if (target) {
      const dx = target.x - p.x;
      const dz = target.z - p.z;
      const d = Math.hypot(dx, dz);
      if (d > ARRIVE_EPSILON && this.walkSpeed > 0) {
        const step = Math.min(this.walkSpeed, d / dt);
        vx = (dx / d) * step;
        vz = (dz / d) * step;
      }
    }
    // rotation: the AlignOrientation, else AutoRotate toward the travel
    let yaw = Math.atan2(-this.cframe.lookVector.x, -this.cframe.lookVector.z);
    if (this.faceDirection) {
      const want = Math.atan2(-this.faceDirection.x, -this.faceDirection.z);
      yaw = yaw + wrapAngle(want - yaw) * (1 - Math.exp(-FACE_RESPONSIVENESS * dt));
    } else if (this.autoRotate && Math.hypot(vx, vz) > 0.1) {
      const want = Math.atan2(-vx, -vz);
      yaw = yaw + wrapAngle(want - yaw) * (1 - Math.exp(-AUTO_ROTATE_SPEED * dt));
    }
    // move with collision in substeps
    const travel = Math.hypot(vx, vz) * dt;
    const steps = Math.max(1, Math.ceil(travel / SUBSTEP));
    let x = p.x;
    let z = p.z;
    let y = p.y;
    for (let i = 0; i < steps; i++) {
      x += (vx * dt) / steps;
      z += (vz * dt) / steps;
      const feet = y - ROOT_HEIGHT;
      let pushed = _probe.set(x, y, z);
      for (let k = 0; k < PUSH_ITERATIONS; k++) {
        const out = this.physics.pushOut(pushed, BODY_RADIUS, feet + BODY_BOTTOM, feet + BODY_TOP);
        if (Math.abs(out.x - pushed.x) < 1e-5 && Math.abs(out.z - pushed.z) < 1e-5) break;
        pushed = _probe.set(out.x, y, out.z);
      }
      x = pushed.x;
      z = pushed.z;
    }
    // floor: stand HipHeight over the floor below, step up small ledges, fall when there is none in reach
    const feet = y - ROOT_HEIGHT;
    const hits = this.physics.floorHits(x, z, feet + STEP_UP, STEP_UP + Math.max(SNAP_DOWN, -this.verticalSpeed * dt + 0.5));
    let floor = null;
    for (const h of hits) {
      if (h <= feet + STEP_UP) {
        floor = h;
        break;
      }
    }
    if (floor !== null && (this.grounded ? floor >= feet - SNAP_DOWN : floor >= feet + this.verticalSpeed * dt - 0.05)) {
      y = floor + ROOT_HEIGHT;
      this.verticalSpeed = 0;
      this.grounded = true;
    } else {
      this.verticalSpeed -= GRAVITY * dt;
      this.verticalSpeed = Math.max(this.verticalSpeed, -120);
      y += this.verticalSpeed * dt;
      this.grounded = false;
    }
    this.velocity.set((x - p.x) / dt, (y - p.y) / dt, (z - p.z) / dt);
    const look = _look.set(-Math.sin(yaw), 0, -Math.cos(yaw));
    this.cframe = CFrame.lookAt(_at.set(x, y, z), _tgt.set(x + look.x, y, z + look.z));
  }

  /** The root frame settled on the floor below `cframe` (placement helper). */
  settleOnFloor() {
    const p = this.cframe.position;
    const feet = p.y - ROOT_HEIGHT;
    const hits = this.physics.floorHits(p.x, p.z, feet + STEP_UP, STEP_UP + 3);
    if (hits.length > 0) {
      const y = hits[0] + ROOT_HEIGHT;
      this.cframe = this.cframe.withPosition(new THREE.Vector3(p.x, y, p.z));
      this.grounded = true;
    }
  }
}

const _probe = new THREE.Vector3();
const _look = new THREE.Vector3();
const _at = new THREE.Vector3();
const _tgt = new THREE.Vector3();
