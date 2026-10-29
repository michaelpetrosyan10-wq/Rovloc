// NodeBatch: many independently movable parts drawn with one draw call per material.
//
// Every chunk belongs to a node (an entity's root or one of its leaves, a creature bone). Chunks sharing a material
// and bucket are concatenated into one geometry whose `node` attribute indexes a float texture holding each node's
// world frame (3 texels, affine rows) and its light (1 texel: probe RGB + mode). Mode 0 hides the node, 1 draws it
// with the vertex light baked where it was built, 2 with its probe irradiance (a moved door leaf, a carried flask).
// Moving a node rewrites four texels; the texture uploads once per frame when anything changed.

import * as THREE from 'three';

const PER_ROW = 64; // nodes per texture row (4 texels each)

export class NodeTable {
  /** @param {number} capacity */
  constructor(capacity) {
    this.capacity = Math.max(1, capacity);
    const rows = Math.ceil(this.capacity / PER_ROW);
    this.data = new Float32Array(PER_ROW * 4 * rows * 4);
    this.texture = new THREE.DataTexture(this.data, PER_ROW * 4, rows, THREE.RGBAFormat, THREE.FloatType);
    this.texture.minFilter = this.texture.magFilter = THREE.NearestFilter;
    this.texture.needsUpdate = true;
    this.count = 0;
    this.dirty = false;
  }

  /** Allocates a node slot initialised to `matrix` (world) and `mode`. */
  alloc(matrix, mode = 1) {
    if (this.count >= this.capacity) throw new Error('NodeTable full');
    const slot = this.count++;
    this.setMatrix(slot, matrix);
    this.setLight(slot, 0.05, 0.05, 0.06, mode);
    return slot;
  }

  setMatrix(slot, m) {
    const e = m.elements;
    const o = slot * 16;
    const d = this.data;
    d[o] = e[0]; d[o + 1] = e[4]; d[o + 2] = e[8]; d[o + 3] = e[12];
    d[o + 4] = e[1]; d[o + 5] = e[5]; d[o + 6] = e[9]; d[o + 7] = e[13];
    d[o + 8] = e[2]; d[o + 9] = e[6]; d[o + 10] = e[10]; d[o + 11] = e[14];
    this.dirty = true;
  }

  setLight(slot, r, g, b, mode) {
    const o = slot * 16 + 12;
    this.data[o] = r;
    this.data[o + 1] = g;
    this.data[o + 2] = b;
    if (mode !== undefined) this.data[o + 3] = mode;
    this.dirty = true;
  }

  setMode(slot, mode) {
    this.data[slot * 16 + 15] = mode;
    this.dirty = true;
  }

  getMode(slot) {
    return this.data[slot * 16 + 15];
  }

  /** Uploads the texture if anything changed (once per frame). */
  flush() {
    if (this.dirty) {
      this.texture.needsUpdate = true;
      this.dirty = false;
    }
  }
}

/**
 * Merges decoded chunks into one geometry per (group key), tagging each vertex with its node slot.
 * @param {Array<{chunk: any, slot: number}>} items
 * @returns {THREE.BufferGeometry}
 */
export function mergeNodeChunks(items) {
  let vertices = 0;
  let indices = 0;
  for (const { chunk } of items) {
    vertices += chunk.attributes.position.array.length / 3;
    indices += chunk.index.length;
  }
  const position = new Float32Array(vertices * 3);
  const normal = new Int8Array(vertices * 3);
  const uv = new Float32Array(vertices * 2);
  const color = new Uint8Array(vertices * 3);
  const baked = new Uint16Array(vertices * 3);
  const flicker = new Uint8Array(vertices * 2);
  const node = new Float32Array(vertices);
  const hasAlpha = items.some((i) => i.chunk.attributes.alpha);
  const alpha = hasAlpha ? new Float32Array(vertices).fill(1) : null;
  const index = vertices < 65536 ? new Uint16Array(indices) : new Uint32Array(indices);
  let v = 0;
  let i = 0;
  for (const { chunk, slot } of items) {
    const a = chunk.attributes;
    const n = a.position.array.length / 3;
    position.set(a.position.array, v * 3);
    normal.set(a.normal.array, v * 3);
    uv.set(a.uv.array, v * 2);
    color.set(a.color.array, v * 3);
    if (a.bakedLight) baked.set(a.bakedLight.array, v * 3);
    if (a.flicker) flicker.set(a.flicker.array, v * 2);
    if (alpha && a.alpha) alpha.set(a.alpha.array, v);
    node.fill(slot, v, v + n);
    for (let k = 0; k < chunk.index.length; k++) index[i + k] = chunk.index[k] + v;
    v += n;
    i += chunk.index.length;
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(position, 3));
  g.setAttribute('normal', new THREE.BufferAttribute(normal, 3, true));
  g.setAttribute('uv', new THREE.BufferAttribute(uv, 2));
  g.setAttribute('color', new THREE.BufferAttribute(color, 3, true));
  g.setAttribute('bakedLight', new THREE.BufferAttribute(baked, 3, true));
  g.setAttribute('flicker', new THREE.BufferAttribute(flicker, 2, false));
  g.setAttribute('node', new THREE.BufferAttribute(node, 1));
  if (alpha) g.setAttribute('alpha', new THREE.BufferAttribute(alpha, 1));
  g.setIndex(new THREE.BufferAttribute(index, 1));
  g.boundingSphere = new THREE.Sphere(new THREE.Vector3(), 1e6);
  return g;
}
