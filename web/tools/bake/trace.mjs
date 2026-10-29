// Shadow / occlusion rays for the bake: a three-mesh-bvh (SAH) tree over the shadow casters, walked by a small
// any-hit traversal (shadow rays only need "is anything in the way", not the closest hit).
//
// The packed node layout read here is three-mesh-bvh 0.9's: 32 bytes per node, float32[0..5] = bounds min / max,
// leaf: uint32[6] = first triangle, uint16[14] = count, uint16[15] = 0xFFFF; internal: uint32[6] = right child
// offset in nodes (relative), uint32[7] = split axis, left child follows the parent.

import * as THREE from 'three';
import { MeshBVH, SAH } from 'three-mesh-bvh';

/**
 * Builds the serialisable tracer data from flat triangle positions.
 * @param {Float32Array} positions xyz per vertex, 3 vertices per triangle
 * @returns {{ positions: Float32Array, index: Uint32Array, nodes: ArrayBuffer }}
 */
export function buildTracer(positions) {
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
  const count = positions.length / 3;
  const index = new Uint32Array(count);
  for (let i = 0; i < count; i++) index[i] = i;
  geometry.setIndex(new THREE.BufferAttribute(index, 1));
  const bvh = new MeshBVH(geometry, { strategy: SAH, targetLeafSize: 6, maxDepth: 60 });
  const roots = bvh._roots;
  if (roots.length !== 1) throw new Error(`expected one BVH root, got ${roots.length}`);
  return { positions, index: geometry.index.array, nodes: roots[0] };
}

/** Any-hit ray tracer over buildTracer() data (works in workers on shared or copied buffers). */
export class Tracer {
  /** @param {{ positions: Float32Array, index: Uint32Array, nodes: ArrayBuffer }} data */
  constructor(data) {
    this.pos = data.positions;
    this.index = data.index;
    this.f32 = new Float32Array(data.nodes);
    this.u32 = new Uint32Array(data.nodes);
    this.u16 = new Uint16Array(data.nodes);
    this.stack = new Int32Array(256);
    this.rays = 0;
  }

  /**
   * True when a triangle lies between origin and origin + dir * maxT (dir need not be unit; t is in its units).
   * @param {number} ox @param {number} oy @param {number} oz @param {number} dx @param {number} dy @param {number} dz
   * @param {number} maxT
   */
  occluded(ox, oy, oz, dx, dy, dz, maxT) {
    this.rays++;
    const f32 = this.f32;
    const u32 = this.u32;
    const u16 = this.u16;
    const stack = this.stack;
    const ix = 1 / dx;
    const iy = 1 / dy;
    const iz = 1 / dz;
    let sp = 0;
    stack[sp++] = 0;
    while (sp > 0) {
      const n32 = stack[--sp];
      // slab test
      let t0x = (f32[n32] - ox) * ix;
      let t1x = (f32[n32 + 3] - ox) * ix;
      if (t0x > t1x) {
        const s = t0x;
        t0x = t1x;
        t1x = s;
      }
      let t0y = (f32[n32 + 1] - oy) * iy;
      let t1y = (f32[n32 + 4] - oy) * iy;
      if (t0y > t1y) {
        const s = t0y;
        t0y = t1y;
        t1y = s;
      }
      let t0z = (f32[n32 + 2] - oz) * iz;
      let t1z = (f32[n32 + 5] - oz) * iz;
      if (t0z > t1z) {
        const s = t0z;
        t0z = t1z;
        t1z = s;
      }
      const tmin = Math.max(t0x, t0y, t0z, 0);
      const tmax = Math.min(t1x, t1y, t1z, maxT);
      if (tmin > tmax) continue;
      const n16 = n32 * 2;
      if (u16[n16 + 15] === 0xffff) {
        const offset = u32[n32 + 6];
        const count = u16[n16 + 14];
        if (this.hitTriangles(offset, count, ox, oy, oz, dx, dy, dz, maxT)) return true;
      } else {
        stack[sp++] = n32 + 8;
        stack[sp++] = n32 + u32[n32 + 6] * 8;
      }
    }
    return false;
  }

  hitTriangles(offset, count, ox, oy, oz, dx, dy, dz, maxT) {
    const pos = this.pos;
    const index = this.index;
    for (let t = offset; t < offset + count; t++) {
      const a = index[t * 3] * 3;
      const b = index[t * 3 + 1] * 3;
      const c = index[t * 3 + 2] * 3;
      const ax = pos[a];
      const ay = pos[a + 1];
      const az = pos[a + 2];
      const e1x = pos[b] - ax;
      const e1y = pos[b + 1] - ay;
      const e1z = pos[b + 2] - az;
      const e2x = pos[c] - ax;
      const e2y = pos[c + 1] - ay;
      const e2z = pos[c + 2] - az;
      const px = dy * e2z - dz * e2y;
      const py = dz * e2x - dx * e2z;
      const pz = dx * e2y - dy * e2x;
      const det = e1x * px + e1y * py + e1z * pz;
      if (det > -1e-12 && det < 1e-12) continue;
      const inv = 1 / det;
      const sx = ox - ax;
      const sy = oy - ay;
      const sz = oz - az;
      const u = (sx * px + sy * py + sz * pz) * inv;
      if (u < 0 || u > 1) continue;
      const qx = sy * e1z - sz * e1y;
      const qy = sz * e1x - sx * e1z;
      const qz = sx * e1y - sy * e1x;
      const v = (dx * qx + dy * qy + dz * qz) * inv;
      if (v < 0 || u + v > 1) continue;
      const tt = (e2x * qx + e2y * qy + e2z * qz) * inv;
      if (tt > 1e-4 && tt < maxT) return true;
    }
    return false;
  }
}

/** Deterministic hash -> [0, 1). */
export function hash01(a, b = 0, c = 0) {
  let h = Math.imul(a | 0, 0x9e3779b1) ^ Math.imul(b | 0, 0x85ebca77) ^ Math.imul(c | 0, 0xc2b2ae3d);
  h ^= h >>> 16;
  h = Math.imul(h, 0x7feb352d);
  h ^= h >>> 15;
  h = Math.imul(h, 0x846ca68b);
  h ^= h >>> 16;
  return (h >>> 0) / 4294967296;
}
