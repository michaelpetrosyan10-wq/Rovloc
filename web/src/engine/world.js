// World: W1's decoded data (data.js decodeWorld) turned into a renderable scene, plus the spatial queries the rest of
// the game uses.
//
//   * Scene. Static chunks arrive split per level x bucket (opaque / transparent / emissive Neon) x material x
//     120-stud cell, in world space with their baked vertex light; each is one mesh, frustum culled. Entity chunks
//     are node-batched by Entities; the Creature's skinned chunks render through createCreatureModel (W3).
//   * Level culling. Only the levels in focus are visible: the player's level, the stairwells, both ends of the
//     stairwell the player stands in, and the exterior from the roof (setFocus /
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
import { NodeTable } from './batch.js';
import { toMatrix } from './math.js';
import { WorldConfig } from './config.js';

const NEON_STRENGTH = 2.4; // Roblox Neon renders well above its colour; the bloom catches it on High
const STAIRWELLS = 'Stairwells';
/**
 * Draw order per bucket: opaque, Neon, wear (multiplied onto the walls), decals (alpha-blended), then glass and water.
 */
export const RENDER_ORDER = Object.freeze({ opaque: 0, emissive: 1, wear: 3, decal: 5, transparent: 10 });
const EXTERIOR = 'Exterior';
const EXTERIOR_FROM = new Set(['Level5_Roof']);
// The school's floors above ground: their outer walls, windows and slab edges are the building seen from outside.
const FACADE_LEVELS = /^Level[1-5]_/;
const FACADE_REACH = 600; // outdoors (the street, the canopy ride) within this of the school, its facade shows
const FACADE_EDGE = 14; // on the roof within this of the outer wall, the floors below show over the parapet

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
      // images arrive already flipped (createImageBitmap imageOrientation 'flipY' = three's flipY upload)
      tex = new THREE.Texture(image);
      const atlas = this.meta.textures[id] && this.meta.textures[id].atlas;
      tex.wrapS = tex.wrapT = atlas ? THREE.ClampToEdgeWrapping : THREE.RepeatWrapping;
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
    const decal = !!info.decal;
    const wear = !!info.wear;
    const transparent = !!variant.transparent && !decal && !wear;
    const emissive = !!(variant.emissive || info.emissive) && !decal && !wear;
    const nodes = !!variant.nodes;
    const cacheKey = `${key}|${baked}|${transparent}|${emissive}|${nodes}|${variant.nodeTexture ? variant.nodeTexture.id : ''}`;
    let mat = this.materials.get(cacheKey);
    if (mat) return mat;
    const budget = this.quality.budget;
    const tex = info.texture;
    mat = createWorldMaterial(this.shared, {
      map: tex ? this._texture(tex, 'color') : null,
      normalMap: tex && !decal && !wear && budget.normalMaps ? this._texture(tex, 'normal') : null,
      roughMap: tex && !decal && !wear && budget.normalMaps ? this._texture(tex, 'orm') : null,
      decal: decal ? { lightInfluence: info.lightInfluence ?? 1, brightness: info.brightness ?? 1 } : null,
      wear,
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
      pointLights: budget.pointLights,
      shadow: budget.flashlightShadow && !emissive && !transparent && !decal && !wear,
    });
    mat.userData.key = cacheKey;
    mat.userData.tex = decal || wear ? null : tex;
    mat.userData.castShadow = !emissive && !transparent && !decal && !wear;
    this.materials.set(cacheKey, mat);
    return mat;
  }

  /** Rebuilds every material for a new quality tier (normal maps / shadow sampling change the shaders). */
  applyQuality() {
    const budget = this.quality.budget;
    for (const mat of this.materials.values()) {
      const tex = mat.userData.tex;
      const want = !!tex && budget.normalMaps;
      const defs = mat.defines;
      let changed = false;
      if (tex && want !== ('USE_NORMALMAP' in defs)) {
        if (want) {
          mat.uniforms.uNormalMap.value = this._texture(tex, 'normal');
          mat.uniforms.uRoughMap.value = this._texture(tex, 'orm');
          defs.USE_NORMALMAP = '';
          defs.USE_ROUGHMAP = '';
        } else {
          delete defs.USE_NORMALMAP;
          delete defs.USE_ROUGHMAP;
        }
        changed = true;
      }
      if (defs.NUM_POINT !== String(budget.pointLights)) {
        defs.NUM_POINT = String(budget.pointLights);
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
      mesh.renderOrder = RENDER_ORDER[c.bucket] ?? 0;
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
      const bvh = new MeshBVH(geometry, { targetLeafSize: 8, strategy: 0 });
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
    /** The school's footprint (the union of its floors' boxes): where its facade stands. */
    this.schoolFootprint = null;
    for (const e of this.levelBoxes) {
      if (!FACADE_LEVELS.test(e.id)) continue;
      if (!this.schoolFootprint) this.schoolFootprint = e.box.clone();
      else this.schoolFootprint.union(e.box);
    }
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
    // Outdoors the Exterior box holds the point, so without this only the street and the stair towers drew: the
    // building vanished under the canopy ride and the Creature stood on the finale's ledge over nothing.
    const outdoors = !level || level === EXTERIOR;
    if (outdoors || EXTERIOR_FROM.has(level)) {
      const f = this.schoolFootprint;
      if (f) {
        const dx = Math.max(f.min.x - position.x, 0, position.x - f.max.x);
        const dz = Math.max(f.min.z - position.z, 0, position.z - f.max.z);
        const inside = dx === 0 && dz === 0;
        const edge = inside ? Math.min(position.x - f.min.x, f.max.x - position.x, position.z - f.min.z, f.max.z - position.z) : 0;
        if (outdoors ? Math.hypot(dx, dz) <= FACADE_REACH : !inside || edge <= FACADE_EDGE) {
          for (const id of this.levelGroups.keys()) if (FACADE_LEVELS.test(id)) out.add(id);
        }
      }
    }
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
   * Irradiance at `pos` from the probe grid of the level holding it (linear RGB, the baked-light scale), with every
   * scripted light group's grid added at its current level (flicker table).
   * @returns {THREE.Color}
   */
  probeAt(pos, out = new THREE.Color()) {
    let level = this.levelAt(pos);
    if (!level || level === STAIRWELLS || !this.decoded.probes[level]) level = this.nearestLevel(pos.y);
    const grid = (level && this.decoded.probes[level]) || this.decoded.probes.Stairwells;
    if (!grid) return out.setRGB(0.04, 0.045, 0.055);
    // scripted groups (the pool floodlights, the classroom glow) add their own grids at their current level
    sampleProbe(grid, pos.x, pos.y, pos.z, _probe, this.shared.uFlickerData);
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
   * A node-batched mesh for one decoded chunk: `slots[v]` is vertex v's slot in `table`, whose entry holds the
   * node's delta frame (current x inverse(rest)) and light. Entity chunks and the creature's skinned chunks use it.
   * @param {any} chunk decoded chunk
   * @param {Float32Array} slots per-vertex node slot
   * @param {import('./batch.js').NodeTable} table
   */
  nodeMesh(chunk, slots, table) {
    const g = chunkGeometry(chunk);
    g.setAttribute('node', new THREE.BufferAttribute(slots, 1));
    g.boundingSphere = new THREE.Sphere(new THREE.Vector3(), 1e6); // nodes move: never frustum-cull on rest bounds
    const mat = this.material(chunk.material, {
      nodes: true, nodeTexture: table.texture, emissive: chunk.bucket === 'emissive',
      transparent: chunk.bucket === 'transparent',
    });
    const mesh = new THREE.Mesh(g, mat);
    mesh.frustumCulled = false;
    mesh.matrixAutoUpdate = false;
    mesh.renderOrder = RENDER_ORDER[chunk.bucket] ?? 0;
    return mesh;
  }

  /**
   * The Creature's renderable rig for W3: its skinned chunks (model space at rest, one bone per vertex) drawn
   * node-batched, one draw call per material. Pose it every frame with setBoneWorld(i, worldMatrix) (bone i is
   * meta.creature.bones[i], whose `rest` is its model-space CFrame at rest), light it with setLight(probeColor), then
   * flush(). Add `object` to the scene yourself (it is not level-culled).
   */
  createCreatureModel() {
    const bones = (this.meta.creature && this.meta.creature.bones) || [];
    const table = new NodeTable(Math.max(1, bones.length));
    for (let i = 0; i < bones.length; i++) table.alloc(new THREE.Matrix4(), 2);
    const restInverse = bones.map((b) => toMatrix(b.rest).invert());
    const object = new THREE.Group();
    object.name = 'Creature';
    for (const c of this.creatureChunks) {
      const skin = c.attributes.skinIndex.array;
      const slots = new Float32Array(c.vertexCount);
      for (let v = 0; v < c.vertexCount; v++) slots[v] = skin[v * 4];
      const lean = { ...c, attributes: { ...c.attributes } };
      delete lean.attributes.skinIndex;
      delete lean.attributes.skinWeight;
      object.add(this.nodeMesh(lean, slots, table));
    }
    const delta = new THREE.Matrix4();
    return {
      object,
      table,
      bones,
      /** Bone i's world frame now (its part's CFrame). */
      setBoneWorld(i, world) {
        delta.multiplyMatrices(world, restInverse[i]);
        table.setMatrix(i, delta);
      },
      /** Probe irradiance (THREE.Color) lighting the whole rig. */
      setLight(color, bone) {
        if (bone !== undefined) table.setLight(bone, color.r, color.g, color.b, 2);
        else for (let i = 0; i < bones.length; i++) table.setLight(i, color.r, color.g, color.b, 2);
      },
      /** Hides / shows one bone's parts (or all). */
      setVisible(on, bone) {
        if (bone !== undefined) table.setMode(bone, on ? 2 : 0);
        else for (let i = 0; i < bones.length; i++) table.setMode(i, on ? 2 : 0);
      },
      flush() {
        table.flush();
      },
    };
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
