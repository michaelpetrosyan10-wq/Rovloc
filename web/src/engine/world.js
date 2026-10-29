// World: W1's decoded data (data.js decodeWorld) turned into a renderable scene, plus the spatial queries the rest of
// the game uses.
//
//   * Scene. Static chunks arrive split per level x bucket (opaque / transparent / emissive Neon) x material x
//     120-stud cell, in world space with their baked vertex light; each is one mesh, frustum culled. Entity chunks
//     are node-batched by Entities; creature chunks are kept for W3 (creatureChunks + buildNodeMeshes).
//   * Level culling. Only the levels in focus are visible: the player's level, the stairwells, both ends of the
//     stairwell the player stands in, and the exterior from the street-level floor and the roof (setFocus /
//     focusFor).
//   * Collision. Every level's collision buffer (every colliding static part, invisible walls included) has a
//     three-mesh-bvh BVH; entity colliders (boxes in node space) are tested through their node frames.
//   * Queries: raycast (first hit on colliding geometry, like a Roblox ray with RespectCanCollide), lineClear,
//     probeAt (trilinear probe irradiance), zoneAt (the Zone volume holding a point, joined with its room's
//     ambience), levelAt (the level whose bounds hold a point).

import * as THREE from 'three';
import { MeshBVH } from 'three-mesh-bvh';
import { sampleProbe } from './data.js';
import { createWorldMaterial } from './materials.js';
import { mergeNodeChunks } from './batch.js';
import { toMatrix } from './math.js';
import { WorldConfig } from './config.js';

const NEON_STRENGTH = 2.4; // Roblox Neon renders well above its colour; the bloom catches it on High
const STAIRWELLS = 'Stairwells';
const EXTERIOR = 'Exterior';
const EXTERIOR_FROM = new Set(['Level1_Hallways', 'Level5_Roof']);

/**
 * @typedef {import('./data.js').WorldData} Decoded
 * @typedef {{color?: ImageBitmap, normal?: ImageBitmap, orm?: ImageBitmap}} TextureSet
 */

export class World {
  /**
   * @param {Decoded} decoded data.js decodeWorld output
   * @param {Record<string, TextureSet>} images texture id -> decoded maps
   * @param {{shared: any, quality: import('./quality.js').Quality}} deps
   */
  constructor(decoded, images, deps) {
    this.decoded = decoded;
    this.meta = decoded.meta;
    /** The parsed world.json (levels, lights, entities, anchors, triggers, zones, rooms, pools, graphs, ...). */
    this.data = decoded.meta;
    this.images = images || {};
    this.shared = deps.shared;
    this.quality = deps.quality;
    this.scene = new THREE.Scene();
    /** @type {Map<string, THREE.Group>} */
    this.levelGroups = new Map();
    /** @type {Map<string, {bvh: MeshBVH, box: THREE.Box3, level: string}>} */
    this.colliders = new Map();
    /** @type {Map<string, THREE.RawShaderMaterial>} */
    this.materials = new Map();
    this.textureCache = new Map();
    this.focus = new Set();
    this.levelBoxes = [];
    this.zones = [];
    this.roomsById = new Map();
    this.lastZone = null;
    /** Entity colliders, filled by Entities: () => [{id, level, matrix, bvh, box, group}] */
    this.entityColliders = null;
    /** Creature chunks (rest space of their bone part) for W3. */
    this.creatureChunks = decoded.chunks.filter((c) => c.kind === 'creature');
    /** Entity chunks (node space) for Entities. */
    this.entityChunks = decoded.chunks.filter((c) => c.kind === 'entity');
    const k = this.meta.lighting && this.meta.lighting.falloff && this.meta.lighting.falloff.inverseSquareK;
    if (Number.isFinite(k)) this.shared.uFalloffK.value = k;
    this._buildStatic(decoded.chunks.filter((c) => c.kind === 'static'));
    this._buildCollision(decoded.collision);
    this._indexLevels();
    this._indexZones();
  }

  // ------------------------------------------------------------------ materials

  _texture(id, kind) {
    const key = `${id}:${kind}`;
    if (this.textureCache.has(key)) return this.textureCache.get(key);
    const set = this.images[id];
    const image = set && set[kind];
    let tex = null;
    if (image) {
      tex = new THREE.Texture(image);
      tex.wrapS = tex.wrapT = THREE.RepeatWrapping;
      tex.colorSpace = THREE.NoColorSpace;
      tex.anisotropy = this.quality.budget.anisotropy;
      tex.generateMipmaps = true;
      tex.minFilter = THREE.LinearMipmapLinearFilter;
      tex.magFilter = THREE.LinearFilter;
      tex.flipY = false;
      tex.needsUpdate = true;
    }
    this.textureCache.set(key, tex);
    return tex;
  }

  /**
   * The (cached) world material for a material key and variant.
   * @param {string} key meta.materials key
   * @param {{baked?: boolean, emissive?: boolean, transparent?: boolean, nodes?: boolean, nodeTexture?: THREE.Texture}} [variant]
   */
  material(key, variant = {}) {
    const info = this.meta.materials[key] || { texture: null, studsPerTile: 8, roughness: 0.8, reflectance: 0 };
    const baked = variant.baked !== false;
    const transparent = !!variant.transparent;
    const emissive = !!(variant.emissive || info.emissive);
    const nodes = !!variant.nodes;
    const cacheKey = `${key}|${baked}|${transparent}|${emissive}|${nodes}|${variant.nodeTexture ? variant.nodeTexture.id : ''}`;
    let mat = this.materials.get(cacheKey);
    if (mat) return mat;
    const budget = this.quality.budget;
    const tex = info.texture;
    mat = createWorldMaterial(this.shared, {
      map: tex ? this._texture(tex, 'color') : null,
      normalMap: tex && budget.normalMaps ? this._texture(tex, 'normal') : null,
      roughMap: tex && budget.normalMaps ? this._texture(tex, 'orm') : null,
      studsPerTile: info.studsPerTile || 8,
      roughness: info.roughness ?? 0.8,
      reflectance: (info.reflectance || 0) + (info.metalness || 0) * 0.3,
      emissive: emissive ? NEON_STRENGTH : 0,
      opacity: 1,
      transparent,
      vertexAlpha: transparent,
      baked,
      nodes,
      nodeTexture: variant.nodeTexture,
      shadow: budget.flashlightShadow && !emissive && !transparent,
    });
    mat.userData.key = cacheKey;
    mat.userData.castShadow = !emissive && !transparent;
    this.materials.set(cacheKey, mat);
    return mat;
  }

  /** Rebuilds every material for a new quality tier (normal maps / shadow sampling change the shaders). */
  applyQuality() {
    const budget = this.quality.budget;
    for (const mat of this.materials.values()) {
      const spec = mat.userData.spec;
      const tex = spec.map ? true : false;
      const want = !!spec.map && budget.normalMaps;
      const defs = mat.defines;
      let changed = false;
      if (want !== ('USE_NORMALMAP' in defs) && tex) {
        const id = Object.entries(this.meta.materials).find(([, i]) => i.texture && this._texture(i.texture, 'color') === spec.map);
        if (want && id) {
          mat.uniforms.uNormalMap.value = this._texture(id[1].texture, 'normal');
          mat.uniforms.uRoughMap.value = this._texture(id[1].texture, 'orm');
          defs.USE_NORMALMAP = '';
          defs.USE_ROUGHMAP = '';
        } else {
          delete defs.USE_NORMALMAP;
          delete defs.USE_ROUGHMAP;
        }
        changed = true;
      }
      const shadow = budget.flashlightShadow && mat.userData.castShadow;
      if (shadow !== ('USE_SHADOW' in defs)) {
        if (shadow) defs.USE_SHADOW = '';
        else delete defs.USE_SHADOW;
        changed = true;
      }
      if (changed) mat.needsUpdate = true;
    }
  }

  // ------------------------------------------------------------------ build

  _buildStatic(chunks) {
    for (const c of chunks) {
      const group = this._levelGroup(c.level);
      const mat = this.material(c.material, { emissive: c.bucket === 'emissive', transparent: c.bucket === 'transparent' });
      const mesh = new THREE.Mesh(chunkGeometry(c), mat);
      mesh.matrixAutoUpdate = false;
      mesh.renderOrder = c.bucket === 'transparent' ? 10 : c.bucket === 'emissive' ? 1 : 0;
      mesh.userData.level = c.level;
      group.add(mesh);
    }
  }

  _levelGroup(level) {
    let g = this.levelGroups.get(level);
    if (!g) {
      g = new THREE.Group();
      g.name = level;
      g.matrixAutoUpdate = false;
      g.visible = false;
      this.levelGroups.set(level, g);
      this.scene.add(g);
    }
    return g;
  }

  _buildCollision(collision) {
    for (const [level, c] of Object.entries(collision || {})) {
      if (!c.index.length) continue;
      const geometry = new THREE.BufferGeometry();
      geometry.setAttribute('position', new THREE.BufferAttribute(c.position, 3));
      geometry.setIndex(new THREE.BufferAttribute(c.index, 1));
      const bvh = new MeshBVH(geometry, { maxLeafTris: 8, strategy: 0 });
      const box = new THREE.Box3();
      bvh.getBoundingBox(box);
      this.colliders.set(level, { bvh, box, level });
    }
  }

  _indexLevels() {
    for (const [id, info] of Object.entries(this.meta.levels || {})) {
      if (!info.aabb || id === STAIRWELLS) continue;
      const a = info.aabb;
      const box = new THREE.Box3(new THREE.Vector3(a[0], a[1], a[2]), new THREE.Vector3(a[3], a[4], a[5]));
      // a level owns the band from its floor slab to the next floor's slab
      this.levelBoxes.push({ id, box, volume: (a[3] - a[0]) * (a[4] - a[1]) * (a[5] - a[2]) });
    }
    // the stair towers: one box per tower over the full height
    const wc = this.meta.worldConfig || {};
    const towers = wc.Towers || WorldConfig.Towers;
    for (const [name, t] of Object.entries(towers)) {
      const box = new THREE.Box3(new THREE.Vector3(t.minX, -2, t.minZ), new THREE.Vector3(t.maxX, 130, t.maxZ));
      this.levelBoxes.push({ id: STAIRWELLS, tower: name, box, volume: 1 });
    }
    this.levelBoxes.sort((a, b) => a.volume - b.volume);
    this.stairwells = (this.meta.stairwells || []).map((s) => {
      const t = towers[s.tower];
      const lo = (this.meta.levels[s.from] || {}).elevation ?? 0;
      const hi = (this.meta.levels[s.to] || {}).elevation ?? lo + 20;
      return { ...s, box: new THREE.Box3(new THREE.Vector3(t.minX - 1, lo - 2, t.minZ - 1), new THREE.Vector3(t.maxX + 1, hi + 4, t.maxZ + 1)) };
    });
  }

  _indexZones() {
    for (const r of this.meta.rooms || []) this.roomsById.set(r.id, r);
    for (const z of this.meta.zones || []) {
      const m = toMatrix(z.cframe);
      const inv = m.clone().invert();
      const half = new THREE.Vector3(z.size[0] / 2, z.size[1] / 2, z.size[2] / 2);
      const room = this.roomsById.get(z.id);
      const box = new THREE.Box3(half.clone().negate(), half.clone()).applyMatrix4(m);
      this.zones.push({
        box,
        ...z,
        matrix: m,
        inverse: inv,
        half,
        ambience: room ? room.ambience : null,
        kind: z.roomKind || (room && room.kind),
        room: room || null,
      });
    }
  }

  // ------------------------------------------------------------------ focus

  /**
   * Shows only `levels` (plus the stairwells). Returns true when the set changed.
   * @param {Iterable<string>} levels
   */
  setFocus(levels) {
    const next = new Set(levels);
    next.add(STAIRWELLS);
    let changed = next.size !== this.focus.size;
    if (!changed) for (const l of next) if (!this.focus.has(l)) changed = true;
    if (!changed) return false;
    this.focus = next;
    for (const [level, group] of this.levelGroups) group.visible = next.has(level);
    return true;
  }

  /** The levels a position should show: its level, both ends of a stairwell it stands in, the exterior outdoors. */
  focusFor(position) {
    const out = new Set();
    const level = this.levelAt(position);
    if (level && level !== STAIRWELLS) out.add(level);
    for (const s of this.stairwells) {
      if (s.box.containsPoint(position)) {
        out.add(s.from);
        out.add(s.to);
      }
    }
    if (!level) {
      const near = this.nearestLevel(position.y);
      if (near && Math.abs(position.x) < 900) out.add(near);
      out.add(EXTERIOR);
    }
    for (const l of out) if (EXTERIOR_FROM.has(l)) out.add(EXTERIOR);
    return out;
  }

  /** The school level whose floor band holds height `y`. */
  nearestLevel(y) {
    let best = null;
    let bestElev = -Infinity;
    for (const [id, info] of Object.entries(this.meta.levels || {})) {
      if (!/^Level\d/.test(id)) continue;
      if (info.elevation <= y + 0.5 && info.elevation > bestElev) {
        best = id;
        bestElev = info.elevation;
      }
    }
    return best;
  }

  // ------------------------------------------------------------------ queries

  /**
   * The level holding `pos`: the level of the Zone volume around it, else the level whose bounds hold it
   * ("Stairwells" inside a stair tower), else null.
   */
  levelAt(pos) {
    const z = this.zoneAt(pos);
    if (z) return z.level;
    for (const entry of this.levelBoxes) if (entry.box.containsPoint(pos)) return entry.id;
    return null;
  }

  /**
   * The Zone volume holding `pos` (ZoneService's point-in-volume test), or null. The result carries the zone's id,
   * level, acoustic preset, footstep surface, room kind and its room's ambience bed.
   */
  zoneAt(pos) {
    const last = this.lastZone;
    if (last && zoneContains(last, pos)) return last;
    for (const z of this.zones) {
      if (zoneContains(z, pos)) {
        this.lastZone = z;
        return z;
      }
    }
    return null;
  }

  /**
   * Irradiance at `pos` from the probe grid of the level holding it (linear RGB, the baked-light scale).
   * @returns {THREE.Color}
   */
  probeAt(pos, out = new THREE.Color()) {
    let level = this.levelAt(pos);
    if (!level || level === STAIRWELLS || !this.decoded.probes[level]) level = this.nearestLevel(pos.y);
    const grid = (level && this.decoded.probes[level]) || this.decoded.probes.Stairwells;
    if (!grid) return out.setRGB(0.04, 0.045, 0.055);
    sampleProbe(grid, pos.x, pos.y, pos.z, _probe);
    return out.setRGB(_probe[0], _probe[1], _probe[2]);
  }

  /**
   * First hit along a ray against collision geometry (static levels + colliding entities).
   * @param {THREE.Vector3} origin
   * @param {THREE.Vector3} dir unit direction
   * @param {number} maxDist
   * @param {{ignoreEntities?: boolean, levels?: Iterable<string>, ignoreGroups?: string[], ignoreEntity?: string}} [opts]
   * @returns {{point: THREE.Vector3, normal: THREE.Vector3, distance: number, level: string|null, entity: string|null, node: string|null}|null}
   */
  raycast(origin, dir, maxDist, opts = {}) {
    _ray.origin.copy(origin);
    _ray.direction.copy(dir);
    let best = null;
    const allowed = opts.levels ? new Set(opts.levels) : null;
    for (const c of this.colliders.values()) {
      if (allowed && !allowed.has(c.level)) continue;
      if (!rayHitsBox(_ray, c.box, maxDist)) continue;
      const hit = c.bvh.raycastFirst(_ray, THREE.DoubleSide, 0, maxDist);
      if (hit && hit.distance <= maxDist && (!best || hit.distance < best.distance)) {
        best = {
          point: hit.point.clone(),
          normal: hit.face ? hit.face.normal.clone() : new THREE.Vector3(0, 1, 0),
          distance: hit.distance,
          level: c.level,
          entity: null,
          node: null,
        };
      }
    }
    if (!opts.ignoreEntities && this.entityColliders) {
      for (const e of this.entityColliders()) {
        if (opts.ignoreEntity === e.id) continue;
        if (opts.ignoreGroups && opts.ignoreGroups.includes(e.group)) continue;
        if (!rayHitsBox(_ray, e.box, maxDist)) continue;
        _inv.copy(e.matrix).invert();
        _ray2.copy(_ray).applyMatrix4(_inv);
        const hit = e.bvh.raycastFirst(_ray2, THREE.DoubleSide, 0, Infinity);
        if (!hit) continue;
        const point = hit.point.applyMatrix4(e.matrix);
        const distance = point.distanceTo(origin);
        if (distance <= maxDist && (!best || distance < best.distance)) {
          const normal = hit.face ? hit.face.normal.clone().transformDirection(e.matrix) : new THREE.Vector3(0, 1, 0);
          best = { point, normal, distance, level: e.level, entity: e.id, node: e.node };
        }
      }
    }
    if (best && best.normal.dot(dir) > 0) best.normal.negate();
    return best;
  }

  /** True when nothing solid lies between `a` and `b`. */
  lineClear(a, b, opts = {}) {
    _dir.subVectors(b, a);
    const len = _dir.length();
    if (len < 1e-4) return true;
    _dir.divideScalar(len);
    return this.raycast(a, _dir, len - 0.05, opts) === null;
  }

  /** Static colliders whose bounds touch `box` (physics broad phase). */
  *collidersNear(box) {
    for (const c of this.colliders.values()) if (c.box.intersectsBox(box)) yield c;
  }

  /**
   * Builds node-batched meshes for chunks (W3's creature: one mesh per material, nodes = bones).
   * @param {any[]} chunks decoded chunks
   * @param {(chunk: any) => number} slotOf node slot of a chunk in `table`
   * @param {import('./batch.js').NodeTable} table
   * @returns {THREE.Mesh[]}
   */
  buildNodeMeshes(chunks, slotOf, table) {
    const groups = new Map();
    for (const c of chunks) {
      const key = `${c.material}|${c.bucket}`;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push({ chunk: c, slot: slotOf(c) });
    }
    const meshes = [];
    for (const [key, items] of groups) {
      const [material, bucket] = key.split('|');
      const mat = this.material(material, {
        nodes: true, nodeTexture: table.texture, emissive: bucket === 'emissive', transparent: bucket === 'transparent',
      });
      const mesh = new THREE.Mesh(mergeNodeChunks(items), mat);
      mesh.frustumCulled = false;
      mesh.matrixAutoUpdate = false;
      mesh.renderOrder = bucket === 'transparent' ? 10 : 0;
      meshes.push(mesh);
    }
    return meshes;
  }
}

// ---------------------------------------------------------------------------------------------------------------

const _ray = new THREE.Ray();
const _ray2 = new THREE.Ray();
const _inv = new THREE.Matrix4();
const _dir = new THREE.Vector3();
const _hitPoint = new THREE.Vector3();
const _local = new THREE.Vector3();
const _probe = [0, 0, 0];

function rayHitsBox(ray, box, maxDist) {
  if (box.containsPoint(ray.origin)) return true;
  const p = ray.intersectBox(box, _hitPoint);
  return !!p && p.distanceTo(ray.origin) <= maxDist;
}

function zoneContains(z, p) {
  if (!z.box.containsPoint(p)) return false;
  _local.copy(p).applyMatrix4(z.inverse);
  return Math.abs(_local.x) <= z.half.x && Math.abs(_local.y) <= z.half.y && Math.abs(_local.z) <= z.half.z;
}

/** BufferGeometry for one decoded chunk. */
export function chunkGeometry(c) {
  const g = new THREE.BufferGeometry();
  for (const [name, a] of Object.entries(c.attributes)) {
    g.setAttribute(name, new THREE.BufferAttribute(a.array, a.itemSize, a.normalized));
  }
  g.setIndex(new THREE.BufferAttribute(c.index, 1));
  if (c.aabb) {
    const a = c.aabb;
    g.boundingBox = new THREE.Box3(new THREE.Vector3(a[0], a[1], a[2]), new THREE.Vector3(a[3], a[4], a[5]));
    g.boundingSphere = g.boundingBox.getBoundingSphere(new THREE.Sphere());
  } else {
    g.computeBoundingSphere();
  }
  return g;
}
