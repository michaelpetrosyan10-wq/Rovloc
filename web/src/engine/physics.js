// Character physics: the Roblox Humanoid as a floating capsule.
//
// A Humanoid hovers its root part HipHeight above the floor and climbs anything its legs reach; walls stop its body.
// So the body here is a capsule from StepHeight above the feet to the crown (radius BodyRadius), resolved against
// the level BVHs (and colliding entities through their pivots) by pushing out of every triangle closer than the
// radius, in substeps short enough that a sprint never tunnels a 1-stud wall. Below the capsule, five downward rays
// (centre + a ring) find the floor: within StepHeight above or SnapDown below the feet the body stands on it (steps,
// stairs and debris are walked up and down), otherwise it falls under Workspace.Gravity. A falling body's floor rays
// start from where its feet were before the step, so a long frame (the loop allows 0.1 s) or a fast fall never drops
// it through a slab between two probes. Jumps launch at
// sqrt(2 g JumpHeight). "Ball" mode is the vent crawl's 2.6-stud VentCollider: a sphere at the root, no floor
// probe, no gravity (the vent rail drives it).

import * as THREE from 'three';
import { PhysicsConfig } from './config.js';

const SUBSTEP = 0.35; // studs of travel per collision substep
const SNAP_DOWN = 0.75; // studs a grounded body follows the floor down (stairs, ramps)
const RING = 0.72; // floor probe ring radius
const MAX_PUSH_ITERATIONS = 3;
const ROOT_ABOVE_FEET = PhysicsConfig.HipHeight + PhysicsConfig.RootHalfHeight;

const _seg = new THREE.Line3();
const _segLocal = new THREE.Line3();
const _box = new THREE.Box3();
const _tri = new THREE.Vector3();
const _cap = new THREE.Vector3();
const _dir = new THREE.Vector3();
const _push = new THREE.Vector3();
const _inv = new THREE.Matrix4();
const _down = new THREE.Vector3(0, -1, 0);
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
    this.anchored = false;
    this.gravity = true;
    this.lastPush = new THREE.Vector3();
  }

  /** Feet height (root centre minus hip height and half the root). */
  get feetY() {
    return this.position.y - ROOT_ABOVE_FEET;
  }

  teleport(position) {
    this.position.copy(position);
    this.velocity.set(0, 0, 0);
    this.grounded = false;
    this._probeFloor(true);
  }

  /**
   * Advances the body by dt with a desired horizontal velocity.
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
    if (this.shape === 'Ball' || !this.gravity) {
      this.velocity.y += ((wish.y || 0) - this.velocity.y) * k;
    } else if (this.grounded) {
      this.velocity.y = 0;
      if (opts.jump) {
        this.velocity.y = Math.sqrt(2 * PhysicsConfig.Gravity * PhysicsConfig.JumpHeight);
        this.grounded = false;
      }
    } else {
      this.velocity.y -= PhysicsConfig.Gravity * dt;
      this.velocity.y = Math.max(this.velocity.y, -200);
    }
    const feetBefore = this.feetY;
    this.move(_o.copy(this.velocity).multiplyScalar(dt));
    if (this.shape === 'Biped' && this.gravity) this._probeFloor(false, feetBefore);
  }

  /**
   * Moves by `delta` with collide-and-slide (no gravity, no floor probe). Drivers (vent rails, swimming) use it.
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
    out.end.set(this.position.x, feet + PhysicsConfig.BodyHeight - r, this.position.z);
    if (out.end.y < out.start.y) out.end.y = out.start.y;
    return r;
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
      // a walker's capsule only blocks sideways and from above (the floor probe owns standing); a body a driver moves
      // without gravity (swimming) has no floor probe, so floors push it up too: a swimmer who hit the water fast
      // used to sink straight through the pool's floor slab into the gap above the gym
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
   * sweeps the rays down from there when the body dropped further than a step this frame.
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
