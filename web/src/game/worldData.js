// worldData.js: the game's index over W1's world.json (anchors, triggers, entities, rooms, zone graph, vents, pools,
// stairwells, the run plan) and the run planner (RunDirector) for difficulties the export was not planned for.
//
// Everything placed comes from the export: anchors and trigger volumes are CFrames + sizes, entity attachments are
// world frames at the built pivot (relative frames are derived here), room rects are level-local studs already
// placed in world space. Nothing is hand-placed.

import * as THREE from 'three';
import { DifficultyConfig, LevelOrder } from './config.js';
import { cfMatrix, cfPos, horizontalDistance, inVolume, list, seededRandom, shuffle } from './util.js';

/**
 * @typedef {{id: string, kind: string, level: string, room: string|null, cframe: number[], attributes: Record<string, any>, tags: string[]}} Anchor
 * @typedef {{id: string, kind: string, level: string, room: string|null, cframe: number[], size: number[], attributes: Record<string, any>}} Trigger
 * @typedef {{id: string, level: string, kind: string, rect: {x: number, z: number, w: number, d: number}, floorY: number, height: number|null}} Room
 * @typedef {{index: number, id: string, type: string, level: string, attributes: Record<string, any>, tags: string[],
 *   pivot: number[], nodes: {path: string, pivot: number[]}[], attachments: Record<string, number[]>,
 *   prompts: any[], colliders: {node: string, cf: number[], size: number[]}[]}} EntityInfo
 */

const MIN_TRAP_SPACING = 6;
const FLASK_SPACING = 3;
const BATTERY_SPACING = 10;
const TRAP_ATTEMPTS = 16;
const MAX_REROLLS = 64;

export class WorldData {
  /** @param {any} meta world.json */
  constructor(meta) {
    this.meta = meta;
    /** @type {Map<string, Anchor>} */
    this.anchorById = new Map(meta.anchors.map((a) => [a.id, a]));
    /** @type {Map<string, EntityInfo>} */
    this.entityById = new Map(meta.entities.map((e) => [e.id, e]));
    /** @type {Map<string, Room>} */
    this.roomById = new Map(meta.rooms.map((r) => [r.id, r]));
    this.stairwells = meta.stairwells || [];
    this.vents = meta.vents || { graphs: {} };
    this.pools = meta.pools || [];
    /** @type {Map<string, THREE.Matrix4>} */
    this._restInv = new Map();
  }

  // ---------------------------------------------------------------------------------------------------- anchors

  anchor(id) {
    return this.anchorById.get(id) || null;
  }

  /** Anchors of a kind (optionally on one level), in export order. */
  anchors(kind, level) {
    return this.meta.anchors.filter((a) => a.kind === kind && (!level || a.level === level));
  }

  /** Spawn slots of a level (PlayerSpawn anchors sorted by id: slot 1 first). */
  spawns(level) {
    return this.anchors('PlayerSpawn', level).sort((a, b) => (a.id < b.id ? -1 : 1));
  }

  /** The level's entry room (where its PlayerSpawn anchors stand). */
  entryRoom(level) {
    const s = this.spawns(level)[0];
    return s ? s.room : null;
  }

  // ---------------------------------------------------------------------------------------------------- triggers

  /** @returns {Trigger[]} */
  triggers(kind, level) {
    return this.meta.triggers.filter((t) => t.kind === kind && (!level || t.level === level));
  }

  /** Whether a point is inside a trigger volume (ZoneService point-in-box). */
  inTrigger(trigger, p, pad = 0) {
    return inVolume(trigger.cframe, trigger.size, p, pad);
  }

  // ---------------------------------------------------------------------------------------------------- rooms

  room(id) {
    return this.roomById.get(id) || null;
  }

  /** The room whose rect holds the point (horizontal) within its floor band; null outside every room. */
  roomAt(p, level) {
    for (const r of this.meta.rooms) {
      if (level && r.level !== level) continue;
      const { x, z, w, d } = r.rect;
      if (p.x < x || p.x > x + w || p.z < z || p.z > z + d) continue;
      const top = r.height == null ? 40 : r.height;
      if (p.y < r.floorY - 3 || p.y > r.floorY + top + 1) continue;
      return r;
    }
    return null;
  }

  /** Whether a point stands in a room's rect (horizontally, with padding) and its floor band. */
  inRoom(roomId, p, pad = 0) {
    const r = this.room(roomId);
    if (!r) return false;
    const { x, z, w, d } = r.rect;
    const top = r.height == null ? 40 : r.height;
    return p.x >= x - pad && p.x <= x + w + pad && p.z >= z - pad && p.z <= z + d + pad &&
      p.y >= r.floorY - 3 && p.y <= r.floorY + top + 1;
  }

  /** A room's floor centre. */
  roomCentre(roomId, out = new THREE.Vector3()) {
    const r = this.room(roomId);
    if (!r) return null;
    return out.set(r.rect.x + r.rect.w / 2, r.floorY, r.rect.z + r.rect.d / 2);
  }

  // ---------------------------------------------------------------------------------------------------- stairwells

  /** The stairwell a level leaves by (WorldConfig.Stairwells), or null on the roof. */
  stairwellFrom(level) {
    return this.stairwells.find((s) => s.from === level) || null;
  }

  /** The level's exit vestibule room id (CheckpointAirlockService.exitRoom). */
  exitRoom(level) {
    const s = this.stairwellFrom(level);
    return s ? s.fromRoom : null;
  }

  /** The level's Checkpoint volume(s) in its exit vestibule. */
  checkpointVolumes(level) {
    const room = this.exitRoom(level);
    const all = this.triggers('Checkpoint', level);
    const inRoom = all.filter((t) => t.room === room);
    return inRoom.length ? inRoom : all;
  }

  // ---------------------------------------------------------------------------------------------------- entities

  /** @returns {EntityInfo|null} */
  entity(id) {
    return this.entityById.get(id) || null;
  }

  /** @returns {EntityInfo[]} */
  entities(type, level) {
    return this.meta.entities.filter((e) => e.type === type && (!level || e.level === level));
  }

  /** World frame of an entity attachment at its built pose (world.json stores world frames). */
  attachmentRest(id, name, out = new THREE.Matrix4()) {
    const e = this.entity(id);
    const cf = e && e.attachments[name];
    return cf ? cfMatrix(cf, out) : null;
  }

  /** An attachment's position at the built pose. */
  attachmentPos(id, name, out = new THREE.Vector3()) {
    const e = this.entity(id);
    const cf = e && e.attachments[name];
    return cf ? cfPos(cf, out) : null;
  }

  /** The entity's built pivot. */
  pivotRest(id, out = new THREE.Matrix4()) {
    const e = this.entity(id);
    return e ? cfMatrix(e.pivot, out) : null;
  }

  /** Inverse of the built pivot (cached). */
  restInverse(id) {
    let m = this._restInv.get(id);
    if (!m) {
      const p = this.pivotRest(id);
      if (!p) return null;
      m = p.invert();
      this._restInv.set(id, m);
    }
    return m;
  }

  /** Local bounds of the colliders on one node (node space): {centre: Matrix4, size: Vector3} or null. */
  nodeBounds(id, node) {
    const e = this.entity(id);
    if (!e) return null;
    const box = new THREE.Box3();
    const corner = new THREE.Vector3();
    const m = new THREE.Matrix4();
    let any = false;
    for (const c of e.colliders || []) {
      if (c.node !== node) continue;
      cfMatrix(c.cf, m);
      for (let i = 0; i < 8; i++) {
        corner.set((i & 1 ? 0.5 : -0.5) * c.size[0], (i & 2 ? 0.5 : -0.5) * c.size[1], (i & 4 ? 0.5 : -0.5) * c.size[2]);
        box.expandByPoint(corner.applyMatrix4(m));
        any = true;
      }
    }
    if (!any) return null;
    const centre = box.getCenter(new THREE.Vector3());
    return { centre: new THREE.Matrix4().makeTranslation(centre.x, centre.y, centre.z), size: box.getSize(new THREE.Vector3()) };
  }

  // ---------------------------------------------------------------------------------------------------- vents

  /** The level's VentGraph ({nodes: {id: {id, links, position}}, grates: {...}, grateAtNode, segments}) or null. */
  ventGraph(level) {
    return (this.vents.graphs && this.vents.graphs[level]) || null;
  }

  // ---------------------------------------------------------------------------------------------------- plan

  /**
   * The run's spawn plan for a difficulty (RunDirector.plan): which traps, flasks and batteries are live and which
   * grates are rusted shut. The export carries the plan for its own difficulty; another difficulty is planned here
   * with the same rules over the same candidates, limited to the entities the export built.
   * @returns {{difficulty: string, props: Set<string>, lockedGrates: Set<string>}}
   */
  plan(difficulty) {
    const exported = this.meta.plan;
    if (exported && exported.difficulty === difficulty) {
      return {
        difficulty,
        props: new Set(exported.props.map((p) => p.anchorId)),
        lockedGrates: new Set(Object.keys(exported.lockedGrates || {})),
      };
    }
    const spec = DifficultyConfig[difficulty] || DifficultyConfig.Standard;
    const seed = (exported && exported.seed) || this.meta.seed || 0;
    const props = new Set();
    const pick = (kind, level, count, spacing, strict, key) => {
      // candidates the export built an entity for (traps / flasks / batteries live where their entity stands)
      const candidates = this.meta.entities.filter((e) => e.type === kind && e.level === level)
        .map((e) => ({ id: e.id, pos: cfPos(e.pivot) }));
      const rng = seededRandom(seed, `${key}|${level}`);
      const chosen = strict ? chooseSpaced(candidates, count, rng, spacing) : choosePreferSpaced(candidates, count, rng, spacing);
      for (const c of chosen) props.add(c.id);
    };
    pick('BearTrap', 'Level0_Basement', spec.trapCount, MIN_TRAP_SPACING, true, 'Traps');
    pick('ChemicalFlask', 'Level2_ScienceHall', spec.flasksScienceHall, FLASK_SPACING, false, 'Flasks');
    pick('ChemicalFlask', 'Level4_FloodedPool', spec.flasksPool, FLASK_SPACING, false, 'Flasks');
    for (const level of LevelOrder) pick('Battery', level, spec.batteriesPerLevel, BATTERY_SPACING, false, 'Batteries');
    const lockedGrates = new Set();
    for (const level of LevelOrder) {
      for (const id of this._lockGrates(seed, spec.lockedGrateFraction, level)) lockedGrates.add(id);
    }
    return { difficulty, props, lockedGrates };
  }

  _lockGrates(seed, fraction, level) {
    const graph = this.ventGraph(level);
    if (!graph) return [];
    const lockable = Object.values(graph.grates).filter((g) => g.lockable && !g.criticalPath)
      .sort((a, b) => (a.id < b.id ? -1 : 1));
    const count = lockable.length ? Math.max(0, Math.min(lockable.length, Math.round(fraction * lockable.length))) : 0;
    if (count === 0) return [];
    const gates = new Set(this.meta.layoutDoors.filter((d) => d.level === level && d.kind === 'Gate').map((d) => d.id));
    if (!this.levelSolvable(level, gates)) return [];
    const rng = seededRandom(seed, `Grates|${level}`);
    for (let attempt = 0; attempt <= MAX_REROLLS; attempt++) {
      const order = shuffle(lockable.slice(), rng);
      const blocked = new Set(gates);
      const chosen = order.slice(0, count).map((g) => g.id);
      for (const id of chosen) blocked.add(id);
      if (this.levelSolvable(level, blocked)) return chosen;
    }
    return [];
  }

  /** ZoneGraph.isLevelSolvable: the level's entry room reaches its exit without crossing a blocked portal. */
  levelSolvable(level, blocked) {
    const zg = this.meta.zoneGraph;
    const entryRoom = this.entryRoom(level);
    const exitRoom = this.exitRoom(level) || (level === 'Level5_Roof' ? 'L5_JumpGap' : null);
    if (!zg || !entryRoom || !exitRoom) return true;
    const entry = `room:${level}:${entryRoom}`;
    const exit = `room:${level}:${exitRoom}`;
    if (!zg.nodes[entry] || !zg.nodes[exit]) return false;
    const seen = new Set([entry]);
    const queue = [entry];
    while (queue.length) {
      const cur = queue.shift();
      for (const edge of list(zg.adjacency[cur])) {
        if (blocked.has(edge.portalId)) continue;
        const next = edge.a === cur ? edge.b : edge.a;
        if (seen.has(next)) continue;
        const node = zg.nodes[next];
        if (!node || node.layoutId !== level) continue;
        seen.add(next);
        queue.push(next);
      }
    }
    return seen.has(exit);
  }
}

function spacedPass(candidates, count, rng, spacing) {
  const order = shuffle(candidates.slice(), rng);
  const chosen = [];
  const passed = [];
  for (const c of order) {
    if (chosen.length >= count) break;
    if (spacing <= 0 || chosen.every((o) => horizontalDistance(c.pos, o.pos) >= spacing)) chosen.push(c);
    else passed.push(c);
  }
  return { chosen, passed };
}

function chooseSpaced(candidates, count, rng, spacing) {
  let best = [];
  if (count <= 0 || !candidates.length) return best;
  for (let i = 0; i < TRAP_ATTEMPTS; i++) {
    const { chosen } = spacedPass(candidates, count, rng, spacing);
    if (chosen.length > best.length) best = chosen;
    if (best.length >= count) break;
  }
  return best;
}

function choosePreferSpaced(candidates, count, rng, spacing) {
  if (count <= 0 || !candidates.length) return [];
  const { chosen, passed } = spacedPass(candidates, count, rng, spacing);
  for (const c of passed) {
    if (chosen.length >= count) break;
    chosen.push(c);
  }
  return chosen;
}
