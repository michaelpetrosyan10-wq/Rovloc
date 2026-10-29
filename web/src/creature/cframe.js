// CFrame: the Roblox coordinate frame (a position and a rotation matrix) with Roblox's semantics, so the ported
// Luau maths reads the same. Components are GetComponents() order: x, y, z, R00..R22 (row-major; the columns are
// RightVector, UpVector and -LookVector). Immutable: every operation returns a new CFrame.

import * as THREE from 'three';

export class CFrame {
  /**
   * @param {number} [x] @param {number} [y] @param {number} [z]
   * @param {number} [r00] @param {number} [r01] @param {number} [r02]
   * @param {number} [r10] @param {number} [r11] @param {number} [r12]
   * @param {number} [r20] @param {number} [r21] @param {number} [r22]
   */
  constructor(x = 0, y = 0, z = 0, r00 = 1, r01 = 0, r02 = 0, r10 = 0, r11 = 1, r12 = 0, r20 = 0, r21 = 0, r22 = 1) {
    this.x = x;
    this.y = y;
    this.z = z;
    this.r00 = r00;
    this.r01 = r01;
    this.r02 = r02;
    this.r10 = r10;
    this.r11 = r11;
    this.r12 = r12;
    this.r20 = r20;
    this.r21 = r21;
    this.r22 = r22;
  }

  /** CFrame.new(position). @param {{x: number, y: number, z: number}} v */
  static at(v) {
    return new CFrame(v.x, v.y, v.z);
  }

  /** From 12 GetComponents() numbers. @param {ArrayLike<number>} c */
  static fromComponents(c) {
    return new CFrame(c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11]);
  }

  /** CFrame.Angles(rx, ry, rz) == CFrame.fromEulerAnglesXYZ: R = Rx * Ry * Rz. */
  static angles(rx, ry, rz) {
    const cx = Math.cos(rx);
    const sx = Math.sin(rx);
    const cy = Math.cos(ry);
    const sy = Math.sin(ry);
    const cz = Math.cos(rz);
    const sz = Math.sin(rz);
    return new CFrame(0, 0, 0,
      cy * cz, -cy * sz, sy,
      sx * sy * cz + cx * sz, -sx * sy * sz + cx * cz, -sx * cy,
      -cx * sy * cz + sx * sz, cx * sy * sz + sx * cz, cx * cy);
  }

  /** CFrame.fromEulerAnglesYXZ(rx, ry, rz): R = Ry * Rx * Rz. */
  static fromEulerAnglesYXZ(rx, ry, rz) {
    const cx = Math.cos(rx);
    const sx = Math.sin(rx);
    const cy = Math.cos(ry);
    const sy = Math.sin(ry);
    const cz = Math.cos(rz);
    const sz = Math.sin(rz);
    return new CFrame(0, 0, 0,
      cy * cz + sy * sx * sz, -cy * sz + sy * sx * cz, sy * cx,
      cx * sz, cx * cz, -sx,
      -sy * cz + cy * sx * sz, sy * sz + cy * sx * cz, cy * cx);
  }

  /** CFrame.fromMatrix(pos, vX, vY, vZ?). */
  static fromMatrix(pos, vx, vy, vz) {
    const z = vz || new THREE.Vector3().crossVectors(vx, vy);
    return new CFrame(pos.x, pos.y, pos.z, vx.x, vy.x, z.x, vx.y, vy.y, z.y, vx.z, vy.z, z.z);
  }

  /** CFrame.lookAt(at, target, up?). */
  static lookAt(at, target, up) {
    const f = new THREE.Vector3(target.x - at.x, target.y - at.y, target.z - at.z);
    if (f.lengthSq() < 1e-12) return new CFrame(at.x, at.y, at.z);
    f.normalize();
    const u = up ? new THREE.Vector3(up.x, up.y, up.z) : new THREE.Vector3(0, 1, 0);
    let r = new THREE.Vector3().crossVectors(f, u);
    if (r.lengthSq() < 1e-10) {
      // looking straight along up: pick any right vector
      r = new THREE.Vector3().crossVectors(f, Math.abs(f.z) < 0.9 ? new THREE.Vector3(0, 0, 1) : new THREE.Vector3(1, 0, 0));
    }
    r.normalize();
    const nu = new THREE.Vector3().crossVectors(r, f).normalize();
    return new CFrame(at.x, at.y, at.z, r.x, nu.x, -f.x, r.y, nu.y, -f.y, r.z, nu.z, -f.z);
  }

  /** CFrame.fromAxisAngle(axis, angle). */
  static fromAxisAngle(axis, angle) {
    const len = Math.hypot(axis.x, axis.y, axis.z) || 1;
    const x = axis.x / len;
    const y = axis.y / len;
    const z = axis.z / len;
    const c = Math.cos(angle);
    const s = Math.sin(angle);
    const t = 1 - c;
    return new CFrame(0, 0, 0,
      t * x * x + c, t * x * y - s * z, t * x * z + s * y,
      t * x * y + s * z, t * y * y + c, t * y * z - s * x,
      t * x * z - s * y, t * y * z + s * x, t * z * z + c);
  }

  /** From a THREE.Matrix4 (affine). */
  static fromMatrix4(m) {
    const e = m.elements;
    return new CFrame(e[12], e[13], e[14], e[0], e[4], e[8], e[1], e[5], e[9], e[2], e[6], e[10]);
  }

  /** Writes this frame into a THREE.Matrix4. */
  toMatrix4(out = new THREE.Matrix4()) {
    return out.set(this.r00, this.r01, this.r02, this.x, this.r10, this.r11, this.r12, this.y,
      this.r20, this.r21, this.r22, this.z, 0, 0, 0, 1);
  }

  /** The 12 GetComponents() numbers. */
  components() {
    return [this.x, this.y, this.z, this.r00, this.r01, this.r02, this.r10, this.r11, this.r12, this.r20, this.r21, this.r22];
  }

  /** this * other. @param {CFrame} o */
  mul(o) {
    return new CFrame(
      this.r00 * o.x + this.r01 * o.y + this.r02 * o.z + this.x,
      this.r10 * o.x + this.r11 * o.y + this.r12 * o.z + this.y,
      this.r20 * o.x + this.r21 * o.y + this.r22 * o.z + this.z,
      this.r00 * o.r00 + this.r01 * o.r10 + this.r02 * o.r20,
      this.r00 * o.r01 + this.r01 * o.r11 + this.r02 * o.r21,
      this.r00 * o.r02 + this.r01 * o.r12 + this.r02 * o.r22,
      this.r10 * o.r00 + this.r11 * o.r10 + this.r12 * o.r20,
      this.r10 * o.r01 + this.r11 * o.r11 + this.r12 * o.r21,
      this.r10 * o.r02 + this.r11 * o.r12 + this.r12 * o.r22,
      this.r20 * o.r00 + this.r21 * o.r10 + this.r22 * o.r20,
      this.r20 * o.r01 + this.r21 * o.r11 + this.r22 * o.r21,
      this.r20 * o.r02 + this.r21 * o.r12 + this.r22 * o.r22,
    );
  }

  /** this * point (CFrame * Vector3). */
  pointToWorld(v, out = new THREE.Vector3()) {
    return out.set(
      this.r00 * v.x + this.r01 * v.y + this.r02 * v.z + this.x,
      this.r10 * v.x + this.r11 * v.y + this.r12 * v.z + this.y,
      this.r20 * v.x + this.r21 * v.y + this.r22 * v.z + this.z,
    );
  }

  /** Point from components (x, y, z) in this frame. */
  point(x, y, z, out = new THREE.Vector3()) {
    return out.set(
      this.r00 * x + this.r01 * y + this.r02 * z + this.x,
      this.r10 * x + this.r11 * y + this.r12 * z + this.y,
      this.r20 * x + this.r21 * y + this.r22 * z + this.z,
    );
  }

  /** The rotation applied to a vector (VectorToWorldSpace). */
  vectorToWorld(v, out = new THREE.Vector3()) {
    return out.set(
      this.r00 * v.x + this.r01 * v.y + this.r02 * v.z,
      this.r10 * v.x + this.r11 * v.y + this.r12 * v.z,
      this.r20 * v.x + this.r21 * v.y + this.r22 * v.z,
    );
  }

  /** VectorToObjectSpace. */
  vectorToObject(v, out = new THREE.Vector3()) {
    return out.set(
      this.r00 * v.x + this.r10 * v.y + this.r20 * v.z,
      this.r01 * v.x + this.r11 * v.y + this.r21 * v.z,
      this.r02 * v.x + this.r12 * v.y + this.r22 * v.z,
    );
  }

  /** PointToObjectSpace. */
  pointToObject(v, out = new THREE.Vector3()) {
    const dx = v.x - this.x;
    const dy = v.y - this.y;
    const dz = v.z - this.z;
    return out.set(
      this.r00 * dx + this.r10 * dy + this.r20 * dz,
      this.r01 * dx + this.r11 * dy + this.r21 * dz,
      this.r02 * dx + this.r12 * dy + this.r22 * dz,
    );
  }

  /** CFrame:Inverse(). */
  inverse() {
    const { x, y, z } = this;
    return new CFrame(
      -(this.r00 * x + this.r10 * y + this.r20 * z),
      -(this.r01 * x + this.r11 * y + this.r21 * z),
      -(this.r02 * x + this.r12 * y + this.r22 * z),
      this.r00, this.r10, this.r20,
      this.r01, this.r11, this.r21,
      this.r02, this.r12, this.r22,
    );
  }

  /** ToObjectSpace: this:Inverse() * other. */
  toObjectSpace(o) {
    return this.inverse().mul(o);
  }

  /** The position as a new Vector3. */
  get position() {
    return new THREE.Vector3(this.x, this.y, this.z);
  }

  /** The rotation alone (CFrame.Rotation). */
  get rotation() {
    return new CFrame(0, 0, 0, this.r00, this.r01, this.r02, this.r10, this.r11, this.r12, this.r20, this.r21, this.r22);
  }

  get lookVector() {
    return new THREE.Vector3(-this.r02, -this.r12, -this.r22);
  }

  get upVector() {
    return new THREE.Vector3(this.r01, this.r11, this.r21);
  }

  get rightVector() {
    return new THREE.Vector3(this.r00, this.r10, this.r20);
  }

  /** CFrame + Vector3 (translation in world axes). */
  add(v) {
    return new CFrame(this.x + v.x, this.y + v.y, this.z + v.z, this.r00, this.r01, this.r02, this.r10, this.r11,
      this.r12, this.r20, this.r21, this.r22);
  }

  /** The same rotation at `v`. */
  withPosition(v) {
    return new CFrame(v.x, v.y, v.z, this.r00, this.r01, this.r02, this.r10, this.r11, this.r12, this.r20, this.r21,
      this.r22);
  }

  /** ToEulerAnglesYXZ: [rx, ry, rz] with R = Ry * Rx * Rz. */
  toEulerAnglesYXZ() {
    const sx = Math.max(-1, Math.min(1, -this.r12));
    const rx = Math.asin(sx);
    if (Math.abs(sx) < 0.9999999) {
      return [rx, Math.atan2(this.r02, this.r22), Math.atan2(this.r10, this.r11)];
    }
    return [rx, Math.atan2(-this.r20, this.r00), 0];
  }

  /** ToEulerAnglesXYZ: [rx, ry, rz] with R = Rx * Ry * Rz. */
  toEulerAnglesXYZ() {
    const sy = Math.max(-1, Math.min(1, this.r02));
    const ry = Math.asin(sy);
    if (Math.abs(sy) < 0.9999999) {
      return [Math.atan2(-this.r12, this.r22), ry, Math.atan2(-this.r01, this.r00)];
    }
    return [Math.atan2(this.r21, this.r11), ry, 0];
  }

  /** ToAxisAngle: [axis, angle]. */
  toAxisAngle() {
    const q = this.quaternion();
    const w = Math.max(-1, Math.min(1, q[3]));
    const angle = 2 * Math.acos(w);
    const s = Math.sqrt(Math.max(0, 1 - w * w));
    if (s < 1e-8) return [new THREE.Vector3(0, 0, 0), 0];
    return [new THREE.Vector3(q[0] / s, q[1] / s, q[2] / s), angle];
  }

  /** The rotation as a quaternion [x, y, z, w]. */
  quaternion() {
    const m00 = this.r00;
    const m11 = this.r11;
    const m22 = this.r22;
    const trace = m00 + m11 + m22;
    let x;
    let y;
    let z;
    let w;
    if (trace > 0) {
      const s = 0.5 / Math.sqrt(trace + 1);
      w = 0.25 / s;
      x = (this.r21 - this.r12) * s;
      y = (this.r02 - this.r20) * s;
      z = (this.r10 - this.r01) * s;
    } else if (m00 > m11 && m00 > m22) {
      const s = 2 * Math.sqrt(1 + m00 - m11 - m22);
      w = (this.r21 - this.r12) / s;
      x = 0.25 * s;
      y = (this.r01 + this.r10) / s;
      z = (this.r02 + this.r20) / s;
    } else if (m11 > m22) {
      const s = 2 * Math.sqrt(1 + m11 - m00 - m22);
      w = (this.r02 - this.r20) / s;
      x = (this.r01 + this.r10) / s;
      y = 0.25 * s;
      z = (this.r12 + this.r21) / s;
    } else {
      const s = 2 * Math.sqrt(1 + m22 - m00 - m11);
      w = (this.r10 - this.r01) / s;
      x = (this.r02 + this.r20) / s;
      y = (this.r12 + this.r21) / s;
      z = 0.25 * s;
    }
    const n = Math.hypot(x, y, z, w) || 1;
    return [x / n, y / n, z / n, w / n];
  }

  /** A frame from a position and a quaternion [x, y, z, w]. */
  static fromQuaternion(px, py, pz, q) {
    const [x, y, z, w] = q;
    const x2 = x + x;
    const y2 = y + y;
    const z2 = z + z;
    const xx = x * x2;
    const xy = x * y2;
    const xz = x * z2;
    const yy = y * y2;
    const yz = y * z2;
    const zz = z * z2;
    const wx = w * x2;
    const wy = w * y2;
    const wz = w * z2;
    return new CFrame(px, py, pz,
      1 - (yy + zz), xy - wz, xz + wy,
      xy + wz, 1 - (xx + zz), yz - wx,
      xz - wy, yz + wx, 1 - (xx + yy));
  }

  /** CFrame:Lerp(goal, alpha): position linear, rotation slerped the short way round. */
  lerp(goal, alpha) {
    if (alpha <= 0) return this;
    if (alpha >= 1) return goal;
    const a = this.quaternion();
    const b = goal.quaternion();
    let dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
    if (dot < 0) {
      dot = -dot;
      b[0] = -b[0];
      b[1] = -b[1];
      b[2] = -b[2];
      b[3] = -b[3];
    }
    let s0;
    let s1;
    if (dot > 0.9995) {
      s0 = 1 - alpha;
      s1 = alpha;
    } else {
      const theta = Math.acos(dot);
      const sin = Math.sin(theta);
      s0 = Math.sin((1 - alpha) * theta) / sin;
      s1 = Math.sin(alpha * theta) / sin;
    }
    const q = [a[0] * s0 + b[0] * s1, a[1] * s0 + b[1] * s1, a[2] * s0 + b[2] * s1, a[3] * s0 + b[3] * s1];
    return CFrame.fromQuaternion(
      this.x + (goal.x - this.x) * alpha,
      this.y + (goal.y - this.y) * alpha,
      this.z + (goal.z - this.z) * alpha,
      q,
    );
  }
}

/** CFrame.identity. */
export const IDENTITY = new CFrame();
