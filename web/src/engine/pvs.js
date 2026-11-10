// Zone culling from the bake's potentially visible sets (meta.visibility, tools/bake/pvs.mjs), on every graphics tier.
// Visual only: it decides which triangles are drawn, never what collides, what rays hit or what anything can see.
//
//   * Static chunks are one per level x bucket x material x Detail level, so a whole level used to be drawn wherever
//     the camera stood. At boot (prepare) every static chunk's triangles are put in zone order: a triangle belongs to
//     the zone its front face looks into (its centroid nudged along its normal, so a wall face belongs to the room it
//     faces); one that looks into no zone of its level (the facade, slab undersides, the fill between tunnels) is
//     always drawn. The sort is stable, so overlapping decals keep their order.
//   * Each frame (update) the zone the camera stands in gives the visible set: that zone's PVS. When it changes, every
//     chunk of the camera's level rewrites its index buffer to the triangles of the visible zones (plus the always
//     drawn ones) and draws that range: the same draw calls, a fraction of the triangles. Away from every zone (a
//     doorway gap, the stairwells, outdoors) the zones within reach are unioned; with none, everything is drawn.
//   * Transparent chunks (glass, water) are never reordered (their blend order matters); they are drawn whole.
//   * Lookups use this module's own zone grid, never World.zoneAt (whose cache gameplay reads).

const NUDGE = 0.35; // studs a triangle's centroid is moved along its normal to find the zone it faces
const CELL = 4; // zone grid cell (studs)
const REACH = 2.5; // outside every zone, zones within this of the camera count as where it stands
const NO_ZONE = -1;

export class ZoneCulling {
  /** @param {import('./world.js').World} world */
  constructor(world) {
    this.world = world;
    this.meta = world.meta;
    this.visibility = this.meta.visibility || {};
    /** @type {Map<string, {zones: any[], byId: Map<string, number>, grid: Map<number, number[]>}>} per level */
    this.levels = new Map();
    /** @type {Map<string, any[]>} level -> prepared chunk meshes */
    this.chunks = new Map();
    this.prepared = false;
    this.enabled = true;
    /** the level whose chunks are filtered now (null: none) */
    this.activeLevel = null;
    /** the visible zone ids now (null: everything) */
    this.visible = null;
    this.key = '';
    this.stats = { level: null, zone: null, visibleZones: 0, triangles: 0, totalTriangles: 0 };
    for (const z of this.meta.zones || []) {
      if (!this.visibility[z.level]) continue;
      let entry = this.levels.get(z.level);
      if (!entry) {
        entry = { zones: [], byId: new Map(), grid: new Map() };
        this.levels.set(z.level, entry);
      }
      const c = z.cframe;
      const h = [z.size[0] / 2, z.size[1] / 2, z.size[2] / 2];
      const zone = {
        id: z.id, index: entry.zones.length,
        min: [c[0] - h[0], c[1] - h[1], c[2] - h[2]], max: [c[0] + h[0], c[1] + h[1], c[2] + h[2]],
        volume: z.size[0] * z.size[1] * z.size[2],
      };
      entry.zones.push(zone);
      entry.byId.set(z.id, zone.index);
      for (let gx = Math.floor(zone.min[0] / CELL); gx <= Math.floor(zone.max[0] / CELL); gx++) {
        for (let gz = Math.floor(zone.min[2] / CELL); gz <= Math.floor(zone.max[2] / CELL); gz++) {
          const k = cellKey(gx, gz);
          let list = entry.grid.get(k);
          if (!list) entry.grid.set(k, (list = []));
          list.push(zone.index);
        }
      }
    }
    // the zones' order in the index buffers: along a serpentine of 24-stud bands, so nearby zones sit near each other
    for (const entry of this.levels.values()) {
      const order = entry.zones.map((z) => z.index);
      const cx = (z) => (z.min[0] + z.max[0]) / 2;
      const cz = (z) => (z.min[2] + z.max[2]) / 2;
      order.sort((a, b) => {
        const za = entry.zones[a];
        const zb = entry.zones[b];
        const ba = Math.floor(cz(za) / 24);
        const bb = Math.floor(cz(zb) / 24);
        if (ba !== bb) return ba - bb;
        return ba % 2 === 0 ? cx(za) - cx(zb) : cx(zb) - cx(za);
      });
      entry.rank = new Int32Array(entry.zones.length);
      order.forEach((zi, r) => {
        entry.rank[zi] = r;
      });
    }
  }

  /** The smallest zone of `level` holding the point (index), else NO_ZONE. */
  zoneIndex(level, x, y, z, pad = 0) {
    const entry = this.levels.get(level);
    if (!entry) return NO_ZONE;
    const list = entry.grid.get(cellKey(Math.floor(x / CELL), Math.floor(z / CELL)));
    if (!list) return NO_ZONE;
    let best = NO_ZONE;
    let bestVolume = Infinity;
    for (const i of list) {
      const zone = entry.zones[i];
      if (x < zone.min[0] - pad || x > zone.max[0] + pad || y < zone.min[1] - pad || y > zone.max[1] + pad ||
        z < zone.min[2] - pad || z > zone.max[2] + pad) continue;
      if (zone.volume < bestVolume) {
        best = i;
        bestVolume = zone.volume;
      }
    }
    return best;
  }

  /**
   * Sorts every static chunk's triangles by the zone they face (once). `meshes` are the World's static meshes with
   * their decoded chunk in userData.chunk.
   */
  prepare(meshes) {
    if (this.prepared) return;
    this.prepared = true;
    const t0 = performance.now();
    let total = 0;
    for (const mesh of meshes) {
      const chunk = mesh.userData.chunk;
      if (!chunk || chunk.bucket === 'transparent' || !this.levels.has(chunk.level)) continue;
      const g = mesh.geometry;
      const index = g.index.array;
      const pos = g.attributes.position.array;
      const nrm = g.attributes.normal ? g.attributes.normal.array : null;
      const nScale = g.attributes.normal && g.attributes.normal.normalized ? 1 / 127 : 1;
      const tris = index.length / 3;
      const zoneOf = new Int32Array(tris);
      const entry = this.levels.get(chunk.level);
      for (let t = 0; t < tris; t++) {
        const a = index[t * 3] * 3;
        const b = index[t * 3 + 1] * 3;
        const c = index[t * 3 + 2] * 3;
        const cx = (pos[a] + pos[b] + pos[c]) / 3;
        const cy = (pos[a + 1] + pos[b + 1] + pos[c + 1]) / 3;
        const cz = (pos[a + 2] + pos[b + 2] + pos[c + 2]) / 3;
        let nx = 0;
        let ny = 0;
        let nz = 0;
        if (nrm) {
          nx = (nrm[a] + nrm[b] + nrm[c]) * nScale;
          ny = (nrm[a + 1] + nrm[b + 1] + nrm[c + 1]) * nScale;
          nz = (nrm[a + 2] + nrm[b + 2] + nrm[c + 2]) * nScale;
        }
        const len = Math.hypot(nx, ny, nz);
        const k = len > 1e-6 ? NUDGE / len : 0;
        const zi = this.zoneIndex(chunk.level, cx + nx * k, cy + ny * k, cz + nz * k);
        zoneOf[t] = zi === NO_ZONE ? -1 : entry.rank[zi];
      }
      // stable counting sort by rank (-1: always drawn, first)
      const zones = entry.zones.length;
      const counts = new Int32Array(zones + 1);
      for (let t = 0; t < tris; t++) counts[zoneOf[t] + 1]++;
      const starts = new Int32Array(zones + 2);
      for (let r = 0; r <= zones; r++) starts[r + 1] = starts[r] + counts[r];
      const fill = starts.slice(0, zones + 1);
      const sorted = new (index.constructor)(index.length);
      for (let t = 0; t < tris; t++) {
        const at = fill[zoneOf[t] + 1]++ * 3;
        sorted[at] = index[t * 3];
        sorted[at + 1] = index[t * 3 + 1];
        sorted[at + 2] = index[t * 3 + 2];
      }
      index.set(sorted);
      g.index.needsUpdate = true;
      // runs per zone (by zone index): [start, count] in indices
      const runs = new Int32Array(zones * 2);
      for (let zi = 0; zi < zones; zi++) {
        const r = entry.rank[zi] + 1;
        runs[zi * 2] = starts[r] * 3;
        runs[zi * 2 + 1] = counts[r] * 3;
      }
      mesh.userData.pvs = { sorted, runs, always: counts[0] * 3, count: index.length, full: true };
      let list = this.chunks.get(chunk.level);
      if (!list) this.chunks.set(chunk.level, (list = []));
      list.push(mesh);
      total += tris;
    }
    this.stats.totalTriangles = total;
    this.stats.prepareMs = performance.now() - t0;
  }

  /**
   * Picks the visible zones for a camera at `pos` and rewrites the index ranges when they changed. Returns the visible
   * zone id set (null: everything is drawn).
   * @param {{x: number, y: number, z: number}} pos
   */
  update(pos) {
    if (!this.prepared) return null;
    let level = null;
    let zones = null;
    if (this.enabled) {
      for (const [lv] of this.levels) {
        const zi = this.zoneIndex(lv, pos.x, pos.y, pos.z);
        if (zi !== NO_ZONE) {
          level = lv;
          zones = [zi];
          break;
        }
      }
      if (!level) {
        // a doorway gap between zones: every zone within reach
        for (const [lv, entry] of this.levels) {
          const list = entry.grid.get(cellKey(Math.floor(pos.x / CELL), Math.floor(pos.z / CELL))) || [];
          const near = list.filter((i) => {
            const zone = entry.zones[i];
            return pos.x >= zone.min[0] - REACH && pos.x <= zone.max[0] + REACH && pos.y >= zone.min[1] - REACH &&
              pos.y <= zone.max[1] + REACH && pos.z >= zone.min[2] - REACH && pos.z <= zone.max[2] + REACH;
          });
          if (near.length) {
            level = lv;
            zones = near;
            break;
          }
        }
      }
    }
    const key = level ? `${level}|${zones.join(',')}` : '';
    if (key === this.key) return this.visible;
    this.key = key;
    // restore the level that was filtered, when the camera left it
    if (this.activeLevel && this.activeLevel !== level) {
      for (const mesh of this.chunks.get(this.activeLevel) || []) this._full(mesh);
    }
    this.activeLevel = level;
    if (!level) {
      this.visible = null;
      this.stats.level = null;
      this.stats.zone = null;
      this.stats.visibleZones = 0;
      return null;
    }
    const entry = this.levels.get(level);
    const pvs = this.visibility[level] || {};
    const ids = new Set();
    for (const zi of zones) {
      const zone = entry.zones[zi];
      ids.add(zone.id);
      const seen = pvs[zone.id];
      if (!seen) {
        // a zone the bake has no set for: draw the level whole
        for (const mesh of this.chunks.get(level) || []) this._full(mesh);
        this.visible = null;
        return null;
      }
      for (const id of seen) ids.add(id);
    }
    const visibleIdx = [];
    for (const id of ids) {
      const zi = entry.byId.get(id);
      if (zi !== undefined) visibleIdx.push(zi);
    }
    visibleIdx.sort((a, b) => entry.rank[a] - entry.rank[b]);
    let drawn = 0;
    for (const mesh of this.chunks.get(level) || []) drawn += this._filter(mesh, visibleIdx) / 3;
    this.visible = ids;
    this.stats.level = level;
    this.stats.zone = entry.zones[zones[0]].id;
    this.stats.visibleZones = ids.size;
    this.stats.triangles = drawn;
    return ids;
  }

  /** Whether zone `id` may be seen now (true when nothing is culled). */
  sees(id) {
    return !this.visible || !id || this.visible.has(id);
  }

  _filter(mesh, visibleIdx) {
    const p = mesh.userData.pvs;
    const g = mesh.geometry;
    const out = g.index.array;
    let n = p.always;
    if (!p.full) out.set(p.sorted.subarray(0, p.always), 0);
    for (const zi of visibleIdx) {
      const start = p.runs[zi * 2];
      const count = p.runs[zi * 2 + 1];
      if (!count) continue;
      out.set(p.sorted.subarray(start, start + count), n);
      n += count;
    }
    p.full = false;
    g.index.clearUpdateRanges();
    g.index.addUpdateRange(0, n);
    g.index.needsUpdate = true;
    g.setDrawRange(0, n);
    mesh.userData.pvsEmpty = n === 0;
    this.world.refreshMeshVisibility(mesh);
    return n;
  }

  _full(mesh) {
    const p = mesh.userData.pvs;
    if (!p || p.full) return;
    const g = mesh.geometry;
    g.index.array.set(p.sorted);
    g.index.clearUpdateRanges();
    g.index.needsUpdate = true;
    g.setDrawRange(0, Infinity);
    p.full = true;
    mesh.userData.pvsEmpty = false;
    this.world.refreshMeshVisibility(mesh);
  }
}

function cellKey(gx, gz) {
  return (gx + 4096) * 8192 + (gz + 4096);
}
