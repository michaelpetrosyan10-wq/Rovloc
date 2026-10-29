// Entities: every interactive / scripted object kept out of the static merge so it can move (fixture doors, the
// hallway gate, vent grates, bear traps, hideable lockers, flasks, batteries, the parachute crate, the floodlight
// switch, ready pads, terminals).
//
// An entity has a pivot (its Roblox model CFrame) and nodes: the root ("") and its moving leaves (a door's leaves, a
// grate's panel and screws, a trap's jaws). W1's chunks are in their node's space; they are drawn node-batched (one
// draw call per level x material x bucket for every entity together, see batch.js), so moving a node is four texel
// writes. A node at its built pose keeps the vertex light baked there; a node moved away from it is lit by the
// level's probe grid at its centre. Colliders (boxes in node space) block the player and rays through their node
// frames; "MonsterPassthrough" ones are flagged so the creature can ignore them.
//
//   setPivot(id, cframe)              moves the whole entity rigidly
//   setNodePivot(id, path, cframe)    places one node in world space (DoorMotion leaf poses use the <Leaf>Open /
//                                     <Leaf>Rest attachments, which are world frames of the leaf at build)
//   setNodeTransform(id, path, m)     a node relative to its built pose (world = rest node frame x m)
//   attachmentWorld(id, name)         an attachment's current world frame (prompt points, anchors)
//   setVisible(id, on[, path])        hides an entity or one node (a picked-up battery, a smashed leaf)

import * as THREE from 'three';
import { MeshBVH } from 'three-mesh-bvh';
import { NodeTable } from './batch.js';
import { toMatrix } from './math.js';
import { Signal } from './signal.js';

const IDENTITY = new THREE.Matrix4();

/**
 * @typedef {Object} EntityNode
 * @property {string} path
 * @property {number} slot node-table slot
 * @property {THREE.Matrix4} restWorld the node's world frame as built
 * @property {THREE.Matrix4} restLocal the node relative to the entity's built pivot
 * @property {THREE.Matrix4} local the node relative to the entity pivot now
 * @property {THREE.Matrix4} matrix the node's world frame now
 * @property {THREE.Vector3} centre the node's chunk centre (node space), where its probe light is sampled
 * @property {boolean} hidden
 */

/**
 * @typedef {Object} Entity
 * @property {string} id
 * @property {string} type AirlockDoor, HallwayGate, ClassroomDoor, RoofStairDoor, VentGrate, BearTrap, Locker,
 *   ChemicalFlask, Battery, ParachuteCrate, FloodlightSwitch, ReadyPad, Terminal
 * @property {string} level
 * @property {Record<string, any>} attributes
 * @property {string[]} tags
 * @property {any[]} prompts the Roblox ProximityPrompts the builders put on it (action / object text, hold, host
 *   attachment, max distance, line of sight, attributes)
 * @property {THREE.Matrix4} pivot current pivot (world)
 * @property {THREE.Matrix4} rest built pivot
 * @property {Record<string, THREE.Matrix4>} attachments frames relative to the built pivot
 * @property {Map<string, EntityNode>} nodes
 * @property {any} info the raw world.json entry
 */

export class Entities {
  /** @param {import('./index.js').Engine} engine */
  constructor(engine) {
    this.engine = engine;
    this.world = engine.world;
    const meta = this.world.meta;
    /** @type {Map<string, Entity>} */
    this.byId = new Map();
    /** @type {Entity[]} by world.json index */
    this.byIndex = [];
    /** @type {Signal<[string, string, any]>} (id, key, value) */
    this.attributeChanged = new Signal();
    let nodeCount = 0;
    for (const e of meta.entities || []) nodeCount += 1 + (e.nodes ? e.nodes.length : 0);
    this.table = new NodeTable(nodeCount + 64);
    this.world.shared.uNodeTex.value = this.table.texture;
    for (const info of meta.entities || []) this._build(info);
    this._buildMeshes();
    this._colliders = [];
    this._buildColliders();
    this.world.entityColliders = () => this._colliders;
  }

  _build(info) {
    const pivot = toMatrix(info.pivot);
    const restInv = pivot.clone().invert();
    /** @type {Map<string, EntityNode>} */
    const nodes = new Map();
    const addNode = (path, world) => {
      const restLocal = new THREE.Matrix4().multiplyMatrices(restInv, world);
      const node = {
        path,
        slot: this.table.alloc(world, 1),
        restWorld: world.clone(),
        restLocal,
        local: restLocal.clone(),
        matrix: world.clone(),
        centre: new THREE.Vector3(),
        hidden: false,
        moved: false,
      };
      nodes.set(path, node);
      return node;
    };
    addNode('', pivot);
    for (const n of info.nodes || []) addNode(n.path, toMatrix(n.pivot));
    const attachments = {};
    for (const [name, cf] of Object.entries(info.attachments || {})) {
      attachments[name] = new THREE.Matrix4().multiplyMatrices(restInv, toMatrix(cf));
    }
    /** @type {Entity} */
    const e = {
      id: info.id,
      type: info.type,
      name: info.name,
      level: info.level,
      index: info.index,
      attributes: { ...(info.attributes || {}) },
      tags: info.tags || [],
      prompts: info.prompts || [],
      pivot: pivot.clone(),
      rest: pivot,
      attachments,
      nodes,
      hidden: false,
      collides: true,
      info,
    };
    this.byId.set(e.id, e);
    this.byIndex[info.index] = e;
    return e;
  }

  _buildMeshes() {
    const chunks = this.world.entityChunks;
    // node centres from their chunks' bounds (node space)
    const bounds = new Map();
    for (const c of chunks) {
      const e = this.byIndex[c.entity];
      if (!e) continue;
      const node = e.nodes.get(c.node || '') || e.nodes.get('');
      const b = bounds.get(node) || new THREE.Box3();
      const a = c.aabb;
      b.expandByPoint(_v.set(a[0], a[1], a[2])).expandByPoint(_v.set(a[3], a[4], a[5]));
      bounds.set(node, b);
    }
    for (const [node, b] of bounds) b.getCenter(node.centre);
    // one batch per level x material x bucket
    const perLevel = new Map();
    for (const c of chunks) {
      const e = this.byIndex[c.entity];
      if (!e) continue;
      if (!perLevel.has(e.level)) perLevel.set(e.level, []);
      perLevel.get(e.level).push(c);
    }
    for (const [level, list] of perLevel) {
      const meshes = this.world.buildNodeMeshes(list, (c) => {
        const e = this.byIndex[c.entity];
        return (e.nodes.get(c.node || '') || e.nodes.get('')).slot;
      }, this.table);
      const group = this.world._levelGroup(level);
      for (const m of meshes) {
        m.name = `entities:${level}`;
        group.add(m);
      }
    }
    for (const e of this.byId.values()) this._relight(e);
    this.table.flush();
  }

  _buildColliders() {
    const shapes = new Map(); // `${id}|${node}|${group}` -> boxes
    for (const e of this.byId.values()) {
      for (const col of e.info.colliders || []) {
        const key = `${e.id}|${col.node || ''}|${col.group || 'Default'}`;
        if (!shapes.has(key)) shapes.set(key, { e, node: col.node || '', group: col.group || 'Default', boxes: [] });
        shapes.get(key).boxes.push(col);
      }
    }
    this.colliderShapes = [];
    for (const s of shapes.values()) {
      const node = s.e.nodes.get(s.node) || s.e.nodes.get('');
      const geo = boxesGeometry(s.boxes);
      const bvh = new MeshBVH(geo, { maxLeafTris: 4 });
      const localBox = new THREE.Box3();
      bvh.getBoundingBox(localBox);
      this.colliderShapes.push({
        id: s.e.id, entity: s.e, node: s.node, group: s.group, level: s.e.level, bvh, localBox,
        matrix: node.matrix, box: localBox.clone().applyMatrix4(node.matrix), nodeRef: node,
      });
    }
    this._refreshColliders();
  }

  _refreshColliders() {
    this._colliders = this.colliderShapes.filter((c) => c.entity.collides && !c.entity.hidden && !c.nodeRef.hidden);
  }

  // ------------------------------------------------------------------ queries

  /** @returns {Entity|undefined} */
  get(id) {
    return this.byId.get(id);
  }

  /** Every entity of a type (or all). */
  list(type) {
    const out = [];
    for (const e of this.byId.values()) if (!type || e.type === type) out.push(e);
    return out;
  }

  /** Every entity carrying a CollectionService tag. */
  byTag(tag) {
    const out = [];
    for (const e of this.byId.values()) if (e.tags.includes(tag)) out.push(e);
    return out;
  }

  /** An attachment's current world frame (null when unknown). */
  attachmentWorld(id, name, out = new THREE.Matrix4()) {
    const e = this.byId.get(id);
    if (!e || !e.attachments[name]) return null;
    return out.multiplyMatrices(e.pivot, e.attachments[name]);
  }

  /** A node's current world frame. */
  nodeWorld(id, path = '', out = new THREE.Matrix4()) {
    const e = this.byId.get(id);
    const node = e && e.nodes.get(path);
    return node ? out.copy(node.matrix) : null;
  }

  // ------------------------------------------------------------------ moving

  /**
   * Moves the whole entity.
   * @param {string} id
   * @param {THREE.Matrix4|number[]|{position: any, yaw?: number}} cframe
   */
  setPivot(id, cframe) {
    const e = this.byId.get(id);
    if (!e) return;
    toMatrix(cframe, e.pivot);
    for (const node of e.nodes.values()) this._place(e, node);
    this._afterMove(e);
  }

  /** Places one node at a world frame. */
  setNodePivot(id, path, cframe) {
    const e = this.byId.get(id);
    const node = e && e.nodes.get(path);
    if (!node) return;
    _m.copy(e.pivot).invert();
    node.local.multiplyMatrices(_m, toMatrix(cframe, _m2));
    this._place(e, node);
    this._afterMove(e);
  }

  /** Places one node relative to its built pose (world = pivot x restLocal x transform). */
  setNodeTransform(id, path, transform) {
    const e = this.byId.get(id);
    const node = e && e.nodes.get(path);
    if (!node) return;
    node.local.multiplyMatrices(node.restLocal, transform ? toMatrix(transform, _m2) : IDENTITY);
    this._place(e, node);
    this._afterMove(e);
  }

  _place(e, node) {
    node.matrix.multiplyMatrices(e.pivot, node.local);
    this.table.setMatrix(node.slot, node.matrix);
    node.moved = !matricesClose(node.matrix, node.restWorld);
  }

  _afterMove(e) {
    for (const c of this.colliderShapes) if (c.entity === e) c.box.copy(c.localBox).applyMatrix4(c.matrix);
    this._relight(e);
  }

  _relight(e) {
    for (const node of e.nodes.values()) {
      const mode = e.hidden || node.hidden ? 0 : node.moved ? 2 : 1;
      if (mode === 2) {
        _v.copy(node.centre).applyMatrix4(node.matrix);
        this.world.probeAt(_v, _c);
        this.table.setLight(node.slot, _c.r, _c.g, _c.b, 2);
      } else {
        this.table.setMode(node.slot, mode);
      }
    }
  }

  // ------------------------------------------------------------------ state

  /** Shows / hides an entity, or one of its nodes. Hidden parts neither draw nor collide. */
  setVisible(id, visible, path) {
    const e = this.byId.get(id);
    if (!e) return;
    if (path !== undefined) {
      const node = e.nodes.get(path);
      if (node) node.hidden = !visible;
    } else e.hidden = !visible;
    this._relight(e);
    this._refreshColliders();
  }

  /** Whether the entity blocks the player and rays. */
  setCollides(id, collides) {
    const e = this.byId.get(id);
    if (!e) return;
    e.collides = !!collides;
    this._refreshColliders();
  }

  /** Writes an attribute (the web stand-in for Roblox attributes) and fires attributeChanged. */
  setAttribute(id, key, value) {
    const e = this.byId.get(id);
    if (!e || e.attributes[key] === value) return;
    e.attributes[key] = value;
    this.attributeChanged.fire(id, key, value);
  }

  /** Every entity back to its built pose, visibility, colliders and attributes (run reset). */
  resetAll() {
    for (const e of this.byId.values()) {
      e.pivot.copy(e.rest);
      e.hidden = false;
      e.collides = true;
      e.attributes = { ...(e.info.attributes || {}) };
      for (const node of e.nodes.values()) {
        node.hidden = false;
        node.local.copy(node.restLocal);
        this._place(e, node);
      }
      this._afterMove(e);
    }
    this._refreshColliders();
  }

  /** Uploads node changes (once per frame). */
  flush() {
    this.table.flush();
  }
}

function matricesClose(a, b) {
  const x = a.elements;
  const y = b.elements;
  for (let i = 0; i < 16; i++) if (Math.abs(x[i] - y[i]) > 1e-3) return false;
  return true;
}

/** Triangles of a set of boxes ({cf, size}) in node space. */
function boxesGeometry(boxes) {
  const pos = [];
  const idx = [];
  const m = new THREE.Matrix4();
  const corners = [];
  for (let i = 0; i < 8; i++) corners.push(new THREE.Vector3());
  for (const b of boxes) {
    toMatrix(b.cf, m);
    const [sx, sy, sz] = b.size.map((v) => v / 2);
    const base = pos.length / 3;
    for (let i = 0; i < 8; i++) {
      corners[i].set(i & 1 ? sx : -sx, i & 2 ? sy : -sy, i & 4 ? sz : -sz).applyMatrix4(m);
      pos.push(corners[i].x, corners[i].y, corners[i].z);
    }
    const faces = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]];
    for (const [a, b2, c, d] of faces) idx.push(base + a, base + b2, base + c, base + a, base + c, base + d);
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(new Float32Array(pos), 3));
  g.setIndex(idx);
  return g;
}

const _v = new THREE.Vector3();
const _c = new THREE.Color();
const _m = new THREE.Matrix4();
const _m2 = new THREE.Matrix4();
