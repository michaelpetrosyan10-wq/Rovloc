// NodeTable: many independently movable parts drawn with one draw call per material.
//
// Each vertex of a node-batched chunk (entity parts, creature bones) carries a `node` attribute indexing this float
// texture, which holds the node's frame (3 texels, affine rows: for W1's rest-pose chunks the delta
// `current x inverse(rest)`) and its light (1 texel: probe RGB + mode). Mode 0 hides the node, 1 draws it with the
// vertex light baked where it was built, 2 with its probe irradiance (a moved door leaf, a carried flask, the
// Creature). Moving a node rewrites four texels; the texture uploads once per frame when anything changed.

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
