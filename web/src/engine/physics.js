// Character physics: the Roblox Humanoid as a floating capsule.
//
// A Humanoid hovers its root part HipHeight above the floor and climbs anything its legs reach; walls stop its body.
// So the body here is a capsule from StepHeight above the feet to the crown (radius BodyRadius), resolved against
// the level BVHs (and colliding entities through their pivots) by pushing out of every triangle closer than the
// radius, in substeps short enough that a sprint never tunnels a 1-stud wall. Below the capsule, five downward rays
// (centre + a ring) find the floor: within StepHeight above or SnapDown below the feet the body stands on it (steps,
// stairs and debris are walked up and down), otherwise it falls under Workspace.Gravity. A falling body's floor rays
// start from where its feet were before the step, so a fast fall never drops it through a slab between two probes.
// The rays start half a stud above StepHeight, where the capsule is wider than the ring, so none starts inside what
// it probes; a ring ray reaches a little past the capsule's round bottom, so the legs climb about 0.3 more than
// StepHeight, and whatever is higher than that the capsule stops like a wall. (A reach of exactly StepHeight would
// leave a gap between the two: the round bottom cannot hold the body out of a block only a little higher than a
// step, and with no leg able to stand on it the body walks straight through.)
// Jumps launch at sqrt(2 g JumpHeight) and a falling body moves on the exact parabola of its substep (position by the
// mean of the velocities at the substep's two ends), so the apex is JumpHeight whatever the substep. The player steps
// the body on the fixed 30 Hz tick in substeps of 1/60 s (player.js), never per rendered frame. "Ball" mode is the
// vent crawl's 2.6-stud VentCollider: a sphere at the root, no floor probe, no gravity (the vent rail drives it).
// Crouching lowers the crown to CrouchHeight (the player sets `height`), so a crouched body fits the tunnels'
// crawlways (CrouchHeight + 0.6 of head room, TunnelRules.CrawlClearance); `headroom()` says whether it may stand.

import * as THREE from 'three';
import { PhysicsConfig } from './config.js';

const SUBSTEP = 0.35; // studs of travel per collision substep
const TERMINAL_SPEED = 200; // studs/s a fall never exceeds
const SNAP_DOWN = 0.75; // studs a grounded body follows the floor down (stairs, ramps)
const RING = 0.72; // floor probe ring radius
const MAX_PUSH_ITERATIONS = 3;
const ROOT_ABOVE_FEET = PhysicsConfig.HipHeight + PhysicsConfig.RootHalfHeight;
/** Feet to crown of a crouched body (TunnelRules.CrouchHeight in the map tool). */
export const CrouchHeight = 3.7;
const HEADROOM_RING = 0.85;

const _seg = new THREE.Line3();
const _segLocal = new THREE.Line3();
const _box = new THREE.Box3();
const _tri = new THREE.Vector3();
const _cap = new THREE.Vector3();
const _dir = new THREE.Vector3();
const _push = new THREE.Vector3();
const _inv = new THREE.Matrix4();
const _down = new THREE.Vector3(0, -1, 0);
const _up = new THREE.Vector3(0, 1, 0);
const _o = new THREE.Vector3();
const _ray = new THREE.Ray();
const _m3 = new THREE.Matrix3();
const _moved = new THREE.Vector3();

export class CharacterBody {
  /** @param {import('./world.js').World} world */
  constructor(world) {
    this.world = world;
    /** HumanoidRootPart centre */
    this.position = new THREE.Vector3();
    this.velocity = new THREE.Vector3();
    this.grounded = false;
    this.floorY = 0;
    this.floorNormal = new THREE.Vector3(0, 1, 0);
    /** surface info of the floor hit (material / level) for footsteps */
    this.floorLevel = null;
    /** @type {'Biped'|'Ball'} */
    this.shape = 'Biped';
    this.radius = PhysicsConfig.BodyRadius;
    /** feet to crown (BodyHeight standing, CrouchHeight crouched) */
    this.height = PhysicsConfig.BodyHeight;
    this.anchored = false;
    this.gravity = true;
    this.lastPush = new THREE.Vector3();
  }

  /** Feet height (root centre minus hip height and half the root). */
  get feetY() {
    return this.position.y - ROOT_ABOVE_FEET;
  }

  /** Puts the body at `position`, at rest. A walker stands on the floor under it; a crawler stays there. */
  teleport(position) {
    this.position.copy(position);
    this.velocity.set(0, 0, 0);
    this.grounded = false;
    if (this.shape === 'Biped' && this.gravity) this._probeFloor(true);
  }

  /**
   * Advances the body by one physics substep (the player's 1/60 s) with a desired horizontal velocity.
   * @param {number} dt
   * @param {THREE.Vector3} wish horizontal velocity (studs/s)
   * @param {{jump?: boolean, accel?: number}} [opts]
   */
  step(dt, wish, opts = {}) {
    if (this.anchored || dt <= 0) {
      this.velocity.set(0, 0, 0);
      return;
    }
    const accel = opts.accel ?? (this.grounded ? 30 : 12);
    const k = 1 - Math.exp(-accel * dt);
    this.velocity.x += (wish.x - this.velocity.x) * k;
    this.velocity.z += (wish.z - this.velocity.z) * k;
    let dy;
    if (this.shape === 'Ball' || !this.gravity) {
      this.velocity.y += ((wish.y || 0) - this.velocity.y) * k;
      dy = this.velocity.y * dt;
    } else {
      if (this.grounded) {
        this.velocity.y = 0;
        if (opts.jump) {
          this.velocity.y = Math.sqrt(2 * PhysicsConfig.Gravity * PhysicsConfig.JumpHeight);
          this.grounded = false;
        }
      }
      if (this.grounded) {
        dy = 0;
      } else {
        // the exact parabola over the substep (the mean of the two end velocities), capped at terminal speed
        const v0 = this.velocity.y;
        const v1 = Math.max(v0 - PhysicsConfig.Gravity * dt, -TERMINAL_SPEED);
        this.velocity.y = v1;
        dy = 0.5 * (v0 + v1) * dt;
      }
    }
    const feetBefore = this.feetY;
    this.move(_o.set(this.velocity.x * dt, dy, this.velocity.z * dt));
    if (this.shape === 'Biped' && this.gravity) this._probeFloor(false, feetBefore);
  }

  /**
   * Moves by `delta` with collide-and-slide (no gravity, no floor probe). Drivers (vent rails, the parachute) use it.
   * Returns the distance actually travelled.
   * @param {THREE.Vector3} delta
   */
  move(delta) {
    const start = _push.copy(this.position);
    const len = delta.length();
    const steps = Math.max(1, Math.ceil(len / SUBSTEP));
    const sx = delta.x / steps;
    const sy = delta.y / steps;
    const sz = delta.z / steps;
    this.lastPush.set(0, 0, 0);
    for (let i = 0; i < steps; i++) {
      this.position.x += sx;
      this.position.y += sy;
      this.position.z += sz;
      this._resolve();
    }
    // kill velocity into whatever pushed us
    const p = this.lastPush;
    const pl = p.length();
    if (pl > 1e-5) {
      _dir.copy(p).divideScalar(pl);
      const into = this.velocity.dot(_dir);
      if (into < 0) this.velocity.addScaledVector(_dir, -into);
    }
    return this.position.distanceTo(start);
  }

  _segment(out) {
    if (this.shape === 'Ball') {
      out.start.copy(this.position);
      out.end.copy(this.position);
      return PhysicsConfig.VentColliderDiameter / 2;
    }
    const feet = this.feetY;
    const r = this.radius;
    out.start.set(this.position.x, feet + PhysicsConfig.StepHeight + r, this.position.z);
    out.end.set(this.position.x, feet + this.height - r, this.position.z);
    if (out.end.y < out.start.y) out.end.y = out.start.y;
    return r;
  }

  /** Whether a body `height` tall (default standing) fits over the feet here: nothing overhead below its crown. */
  headroom(height = PhysicsConfig.BodyHeight) {
    const feet = this.feetY;
    const from = Math.min(this.height, height) - 0.15;
    const reach = height - from + 0.05;
    if (reach <= 0) return true;
    for (let i = 0; i < 5; i++) {
      const a = (i - 1) * (Math.PI / 2);
      _o.set(
        this.position.x + (i === 0 ? 0 : Math.cos(a) * HEADROOM_RING),
        feet + from,
        this.position.z + (i === 0 ? 0 : Math.sin(a) * HEADROOM_RING),
      );
      if (this.world.raycast(_o, _up, reach)) return false;
    }
    return true;
  }

  _resolve() {
    for (let it = 0; it < MAX_PUSH_ITERATIONS; it++) {
      const r = this._segment(_seg);
      const before = _o.copy(_seg.start);
      _box.makeEmpty();
      _box.expandByPoint(_seg.start).expandByPoint(_seg.end);
      _box.min.addScalar(-r);
      _box.max.addScalar(r);
      for (const c of this.world.collidersNear(_box)) {
        c.bvh.shapecast({
          intersectsBounds: (b) => b.intersectsBox(_box),
          intersectsTriangle: (tri) => {
            const d = tri.closestPointToSegment(_seg, _tri, _cap);
            if (d < r) {
              const depth = r - d;
              _dir.subVectors(_cap, _tri);
              if (_dir.lengthSq() < 1e-10) _dir.copy(tri.getNormal(_dir));
              _dir.normalize();
              _seg.start.addScaledVector(_dir, depth);
              _seg.end.addScaledVector(_dir, depth);
            }
          },
        });
      }
      if (this.world.entityColliders) {
        for (const e of this.world.entityColliders()) {
          if (!e.box.intersectsBox(_box)) continue;
          _inv.copy(e.matrix).invert();
          _segLocal.copy(_seg).applyMatrix4(_inv);
          const moved = _moved.copy(_segLocal.start);
          e.bvh.shapecast({
            intersectsBounds: () => true,
            intersectsTriangle: (tri) => {
              const d = tri.closestPointToSegment(_segLocal, _tri, _cap);
              if (d < r) {
                _dir.subVectors(_cap, _tri);
                if (_dir.lengthSq() < 1e-10) _dir.copy(tri.getNormal(_dir));
                _dir.normalize();
                _segLocal.start.addScaledVector(_dir, r - d);
                _segLocal.end.addScaledVector(_dir, r - d);
              }
            },
          });
          moved.subVectors(_segLocal.start, moved);
          if (moved.lengthSq() > 0) {
            _m3.setFromMatrix4(e.matrix);
            moved.applyMatrix3(_m3);
            _seg.start.add(moved);
            _seg.end.add(moved);
          }
        }
      }
      const dx = _seg.start.x - before.x;
      const dy = _seg.start.y - before.y;
      const dz = _seg.start.z - before.z;
      if (dx * dx + dy * dy + dz * dz < 1e-10) return;
      // a walker's capsule only blocks sideways and from above (the floor probe owns standing); a body moved without
      // gravity has no floor probe, so floors push it up too (it never sinks through a slab)
      const lift = this.shape === 'Ball' || dy < 0 || !this.gravity;
      this.position.x += dx;
      this.position.z += dz;
      if (lift) this.position.y += dy;
      this.lastPush.x += dx;
      this.lastPush.y += lift ? dy : 0;
      this.lastPush.z += dz;
    }
  }

  /**
   * Finds the floor under the feet and stands on it (or starts falling). `feetBefore` (the feet before this step)
   * sweeps the rays down from there when the body dropped further than a step this substep.
   */
  _probeFloor(force, feetBefore = -Infinity) {
    const feet = this.feetY;
    const reachUp = Math.max(PhysicsConfig.StepHeight, Math.min(feetBefore - feet, 60));
    const reachDown = this.grounded || force ? SNAP_DOWN : 0.05;
    let best = -Infinity;
    let bestNormal = null;
    let level = null;
    for (let i = 0; i < 5; i++) {
      const a = (i - 1) * (Math.PI / 2);
      _o.set(
        this.position.x + (i === 0 ? 0 : Math.cos(a) * RING),
        feet + reachUp + 0.5,
        this.position.z + (i === 0 ? 0 : Math.sin(a) * RING),
      );
      const hit = this.world.raycast(_o, _down, reachUp + 0.5 + reachDown);
      if (hit && hit.normal.y > 0.35 && hit.point.y > best) {
        best = hit.point.y;
        bestNormal = hit.normal;
        level = hit.level;
      }
    }
    if (best > -Infinity && this.velocity.y <= 0.01) {
      this.grounded = true;
      this.floorY = best;
      this.floorNormal.copy(bestNormal);
      this.floorLevel = level;
      this.position.y = best + ROOT_ABOVE_FEET;
      this.velocity.y = 0;
    } else {
      this.grounded = false;
    }
  }
}

export { ROOT_ABOVE_FEET };
