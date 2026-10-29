// worldData.js: the game's index over W1's world.json (anchors, triggers, entities, rooms, zone graph, vents, pools,
// stairwells, the objectives) and the run planner (RunDirector) for every run seed.
//
// Everything placed comes from the export: anchors and trigger volumes are CFrames + sizes, entity attachments are
// world frames at the built pivot (relative frames are derived here), room rects are level-local studs already
// placed in world space. Nothing is hand-placed.
//
// Routes. A run leaves each floor by one exit stairwell: routes(seed) gives every school level its Route (the exit
// vestibule, its fire doors, Checkpoint volumes, ExitLock, the stair tower, the next level's entry room and spawn slots).
// chooseRoute is the one seam where a floor's route is picked among candidates (stream "Route|<level>"); today every
// floor has a single stairwell (meta.stairwells), so it is that one.
//
// The plan (RunDirector.plan, ported rule for rule over the export's candidate anchors): the objective picks
// (pickObjective: one seeded shuffle per level, "Objective|<level>"), bear traps (the guard traps of the first fuses
// picked, then the difficulty's count spaced from them), chemical flasks, batteries and rusted grates, every one from
// its own seeded stream of the run seed. The export built entities for one plan only, so a run's chosen anchors are
// served by those entities moved there (placements: entity id -> world pivot), as many as the export built.

import * as THREE from 'three';
import { DifficultyConfig, LevelOrder, nextLevel } from './config.js';
import { compassOf } from './objectives/config.js';
import { cfMatrix, cfPos, horizontalDistance, inVolume, list, seededRandom, shuffle } from './util.js';

/**
 * @typedef {{id: string, kind: string, level: string, room: string|null, cframe: number[], attributes: Record<string, any>, tags: string[]}} Anchor
 * @typedef {{id: string, kind: string, level: string, room: string|null, cframe: number[], size: number[], attributes: Record<string, any>}} Trigger
 * @typedef {{id: string, level: string, kind: string, rect: {x: number, z: number, w: number, d: number}, floorY: number, height: number|null}} Room
 * @typedef {{index: number, id: string, type: string, level: string, attributes: Record<string, any>, tags: string[],
 *   pivot: number[], nodes: {path: string, pivot: number[]}[], attachments: Record<string, number[]>,
 *   prompts: any[], colliders: {node: string, cf: number[], size: number[]}[]}} EntityInfo
 * @typedef {{level: string, stairwellId: string, tower: string|null, exitRoom: string, nextLevel: string|null,
 *   entryRoomOfNextLevel: string|null, exitDoorIds: string[], checkpointVolumes: Trigger[], spawnAnchors: Anchor[],
 *   lockEntity: string|null, compass: string|null, exitPoint: THREE.Vector3}} Route
 * @typedef {{levelId: string, anchors: string[], guards: string[], slots: Record<string, number>}} ObjectivePicks
 * @typedef {{difficulty: string, seed: number, props: Set<string>, placements: Map<string, THREE.Matrix4>,
 *   lockedGrates: Set<string>, objectives: Record<string, ObjectivePicks>, short: Record<string, number>}} Plan
 */

const MIN_TRAP_SPACING = 6;
const FLASK_SPACING = 3;
const BATTERY_SPACING = 10;
const TRAP_ATTEMPTS = 16;
const MAX_REROLLS = 64;
const TRAP_LEVEL = 'Level0_Basement';
const WALK_DOOR_KINDS = new Set(['Doorway', 'Door', 'Airlock', 'Ajar', 'Gate', 'RoofDoor']);
const MAX_SEED = 2 ** 31 - 2;

/** RunLifecycleService.normalizeSeed: a whole seed in [1, 2^31 - 2], or null. */
export function normalizeSeed(seed) {
  if (seed === null || seed === undefined || !Number.isFinite(Number(seed))) return null;
  const whole = Math.abs(Math.floor(Number(seed)));
  return (((whole - 1) % MAX_SEED) + MAX_SEED) % MAX_SEED + 1;
}

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
    /** @type {Map<string, any>} the walking graph per level */
    this._walk = new Map();
    /** @type {Record<string, Route>} the default routes (the first candidate of every floor) */
    this.defaultRoutes = this.routes(0);
  }

  // ---------------------------------------------------------------------------------------------------- anchors

  anchor(id) {
    return this.anchorById.get(id) || null;
  }

  /** Anchors of a kind (optionally on one level), in export order. */
  anchors(kind, level) {
    return this.meta.anchors.filter((a) => a.kind === kind && (!level || a.level === level));
  }

  /**
   * Spawn slots of a level (PlayerSpawn anchors sorted by id: slot 1 first): the ones in its entry room by `routes`
   * (the previous floor's route), else every one on the level.
   */
  spawns(level, routes) {
    const all = this.anchors('PlayerSpawn', level).sort((a, b) => (a.id < b.id ? -1 : 1));
    const entry = this.entryRoom(level, routes);
    const inEntry = entry ? all.filter((a) => a.room === entry) : [];
    return inEntry.length ? inEntry : all;
  }

  /** The level's entry room: the previous floor's route ends there; Level 0 and the lobby use their layout's entry. */
  entryRoom(level, routes) {
    const order = LevelOrder.indexOf(level);
    if (order > 0) {
      const from = LevelOrder[order - 1];
      const route = (routes || this.defaultRoutes)[from];
      if (route && route.entryRoomOfNextLevel) return route.entryRoomOfNextLevel;
    }
    const layout = this.meta.layouts && this.meta.layouts[level];
    if (layout && layout.entry) return layout.entry;
    const s = this.anchors('PlayerSpawn', level)[0];
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

  // ---------------------------------------------------------------------------------------------------- routes

  /** Every school level's route for a run seed ({levelId: Route}; the roof has none). */
  routes(seed) {
    /** @type {Record<string, Route>} */
    const out = {};
    for (const level of LevelOrder) {
      const route = this.chooseRoute(level, seed);
      if (route) out[level] = route;
    }
    return out;
  }

  /**
   * THE seam where a floor's exit is chosen: one of the floor's route candidates by the run seed (stream
   * "Route|<level>"). Today a floor has the one stairwell meta.stairwells lists; when the world data carries several
   * (meta.routes[level]: candidates with a stairwellId), this picks among them and only this function and the data
   * change.
   * @returns {Route|null}
   */
  chooseRoute(level, seed) {
    const candidates = this.routeCandidates(level);
    if (!candidates.length) return null;
    const pick = candidates.length > 1 ? seededRandom(seed, `Route|${level}`).integer(0, candidates.length - 1) : 0;
    return candidates[pick];
  }

  /** The exits a floor may be left by, as Routes (stairwells leaving it, in data order). */
  routeCandidates(level) {
    const declared = this.meta.routes && this.meta.routes[level];
    const stairs = Array.isArray(declared) && declared.length
      ? declared.map((r) => this.stairwells.find((s) => s.id === (r.stairwellId || r.id)) || r)
      : this.stairwells.filter((s) => s.from === level);
    return stairs.map((s) => this._route(level, s)).filter(Boolean);
  }

  _route(level, stair) {
    const exitRoom = stair.fromRoom || stair.exitRoom;
    if (!exitRoom) return null;
    const doors = (this.meta.layoutDoors || []).filter((d) => d.level === level && d.kind === 'Airlock' &&
      list(d.rooms).includes(exitRoom)).map((d) => d.id);
    const exitDoorIds = doors.length ? doors : this.meta.entities.filter((e) => e.type === 'AirlockDoor' &&
      e.level === level && e.attributes.FromLevel === level).map((e) => e.id);
    const triggers = this.triggers('Checkpoint', level);
    const inRoom = triggers.filter((t) => t.room === exitRoom);
    const next = stair.to || nextLevel(level);
    const entry = stair.toRoom || stair.entryRoomOfNextLevel || null;
    const spawns = next ? this.anchors('PlayerSpawn', next).filter((a) => !entry || a.room === entry)
      .sort((a, b) => (a.id < b.id ? -1 : 1)) : [];
    const lock = this.meta.entities.find((e) => e.type === 'ExitLock' && e.level === level &&
      exitDoorIds.includes(e.attributes.DoorId));
    const exitPoint = this.roomCentre(exitRoom) || new THREE.Vector3();
    return {
      level,
      stairwellId: stair.id,
      tower: stair.tower || null,
      exitRoom,
      nextLevel: next || null,
      entryRoomOfNextLevel: entry,
      exitDoorIds,
      checkpointVolumes: inRoom.length ? inRoom : triggers,
      spawnAnchors: spawns,
      lockEntity: lock ? lock.id : null,
      compass: compassOf(this.meta.levels[level], exitPoint),
      exitPoint,
    };
  }

  /** The route a level leaves by under `routes` (default routes when none), or null on the roof. */
  route(level, routes) {
    return (routes || this.defaultRoutes)[level] || null;
  }

  /** The level's exit vestibule room id (CheckpointAirlockService.exitRoom) on a route set. */
  exitRoom(level, routes) {
    const r = this.route(level, routes);
    return r ? r.exitRoom : null;
  }

  /** The level's Checkpoint volume(s) in its exit vestibule. */
  checkpointVolumes(level, routes) {
    const r = this.route(level, routes);
    return r ? r.checkpointVolumes : [];
  }

  // ---------------------------------------------------------------------------------------------------- walking

  /**
   * The walking graph of a level (the zone graph: rooms joined by doorways, and the ducts): nodes are the doorways
   * (floor points on their walls, opening into two rooms), the vent grates' mouths (opening into one room) and the duct
   * nodes, with explicit links along the ducts. Two nodes opening into the same room are joined in a straight line.
   */
  _walkGraph(level) {
    let g = this._walk.get(level);
    if (g) return g;
    const layout = this.meta.layouts && this.meta.layouts[level];
    const origin = this.meta.levels[level] ? this.meta.levels[level].origin : [0, 0, 0];
    const rects = new Map((layout ? layout.rooms : []).map((r) => [r.id, r.rect]));
    const nodes = new Map();
    const byRoom = new Map();
    const add = (node) => {
      nodes.set(node.id, node);
      for (const r of node.rooms) {
        if (!byRoom.has(r)) byRoom.set(r, []);
        byRoom.get(r).push(node);
      }
      return node;
    };
    for (const d of layout ? layout.doors : []) {
      if (!WALK_DOOR_KINDS.has(d.kind)) continue;
      const [a, b] = list(d.rooms);
      const ra = rects.get(a);
      const rb = rects.get(b);
      if (!ra || !rb) continue;
      const p = portalPoint(ra, rb, d.at);
      if (!p) continue;
      const room = this.room(a) || this.room(b);
      add({ id: d.id, rooms: [a, b], links: [], door: true,
        pos: new THREE.Vector3(origin[0] + p.x, room ? room.floorY : origin[1], origin[2] + p.z) });
    }
    const zg = this.meta.zoneGraph;
    const vents = this.ventGraph(level);
    if (zg) {
      const link = (a, b, length) => {
        a.links.push({ node: b, length });
        b.links.push({ node: a, length });
      };
      const ventNode = (key) => {
        const id = `duct:${key}`;
        if (nodes.has(id)) return nodes.get(id);
        const z = zg.nodes[key];
        return z && z.layoutId === level ? add({ id, rooms: [], links: [], pos: new THREE.Vector3(...z.center) }) : null;
      };
      for (const e of zg.edges) {
        if (e.kind === 'Duct') {
          const a = ventNode(e.a);
          const b = ventNode(e.b);
          if (a && b) link(a, b, e.length);
        } else if (e.kind === 'Grate') {
          const roomKey = e.a.startsWith('room:') ? e.a : e.b;
          const zr = zg.nodes[roomKey];
          if (!zr || zr.layoutId !== level) continue;
          const grate = vents && vents.grates ? vents.grates[e.portalId] : null;
          const v = ventNode(roomKey === e.a ? e.b : e.a);
          if (!grate || !v) continue;
          const mouth = add({ id: `grate:${e.portalId}`, rooms: [roomKey.split(':')[2]], links: [],
            pos: new THREE.Vector3(...grate.mouth) });
          link(mouth, v, mouth.pos.distanceTo(v.pos));
        }
      }
    }
    g = { nodes, byRoom };
    this._walk.set(level, g);
    return g;
  }

  /**
   * Walking distance over the zone graph from `from` (in room `fromRoom`) to a point in room `toRoom`: Dijkstra over its
   * nodes (straight lines inside a room). Infinity when unreachable.
   */
  walkDistance(level, fromRoom, from, toRoom, to) {
    if (fromRoom === toRoom) return horizontalDistance(from, to);
    const dist = this.portalDistances(level, fromRoom, from);
    let best = Infinity;
    for (const p of this._walkGraph(level).byRoom.get(toRoom) || []) {
      const d = dist.get(p.id);
      if (d !== undefined) best = Math.min(best, d + horizontalDistance(p.pos, to));
    }
    return best;
  }

  /** Distance from `from` (in `fromRoom`) to every reachable node of the level's walking graph (Map id -> studs). */
  portalDistances(level, fromRoom, from) {
    const g = this._walkGraph(level);
    const dist = new Map();
    const done = new Set();
    const open = [];
    const relax = (node, d) => {
      if (done.has(node.id) || d >= (dist.has(node.id) ? dist.get(node.id) : Infinity)) return;
      if (!dist.has(node.id)) open.push(node);
      dist.set(node.id, d);
    };
    for (const p of g.byRoom.get(fromRoom) || []) relax(p, horizontalDistance(from, p.pos));
    while (open.length) {
      let bi = 0;
      for (let i = 1; i < open.length; i++) if (dist.get(open[i].id) < dist.get(open[bi].id)) bi = i;
      const cur = open.splice(bi, 1)[0];
      done.add(cur.id);
      const dc = dist.get(cur.id);
      for (const room of cur.rooms) {
        for (const p of g.byRoom.get(room) || []) if (p !== cur) relax(p, dc + horizontalDistance(cur.pos, p.pos));
      }
      for (const l of cur.links) relax(l.node, dc + l.length);
    }
    return dist;
  }

  /** The doorways of a room (doors, airlock doors, open doorways) as world floor points. */
  roomPortals(level, roomId) {
    return (this._walkGraph(level).byRoom.get(roomId) || []).filter((p) => p.door)
      .map((p) => ({ id: p.id, pos: p.pos.clone(), rooms: p.rooms.slice() }));
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

  // ---------------------------------------------------------------------------------------------------- objectives

  /** A floor's objective candidates in layout order (meta.objectives.levels[level].candidates). */
  objectiveCandidates(level) {
    const lv = this.meta.objectives && this.meta.objectives.levels ? this.meta.objectives.levels[level] : null;
    return lv ? list(lv.candidates) : [];
  }

  /**
   * RunDirector.pickObjective: `item.count` of the floor's eligible candidates (meta.objectives: at least EntryClearance
   * studs walked from the entry, never in the scare classroom), one seeded stream per level ("Objective|<level>"). One
   * item: the first of a shuffle. Several (meta.objectives.rules): up to pickAttempts passes on the same stream, each
   * taking candidates (fuses: in shuffled order; reagents: kind by kind, the first of each kind's shuffle) that lie in
   * another room than the items taken so far and pickSpacing from each of them; a pass stands when it is full and its
   * three or more items lie in at least pickQuarters quarters of the floor, else the first fullest pass is used. Slot =
   * pick order (reagents: the kind). The guard traps: the TrapCandidate `ref` of each of the first item.guarded picks
   * that is outside the trap-free rooms and MinTrapSpacing from the guards before it.
   * @returns {ObjectivePicks}
   */
  pickObjective(seed, spec) {
    const all = this.objectiveCandidates(spec.levelId);
    const candidates = all.filter((c) => c.eligible !== false);
    const rules = (this.meta.objectives && this.meta.objectives.rules) || {};
    const spacing = rules.pickSpacing ?? 25;
    const quarters = rules.pickQuarters ?? 2;
    const attempts = rules.pickAttempts ?? 24;
    const random = seededRandom(seed, `Objective|${spec.levelId}`);
    const kinds = spec.item.slots;
    const count = kinds ? Math.min(kinds, spec.item.count) : Math.min(spec.item.count, candidates.length);
    const groups = [];
    if (kinds) {
      for (let k = 1; k <= count; k++) groups.push(candidates.filter((c) => c.slot === k));
    }
    const apart = (c, taken) => taken.every((o) => o.room !== c.room &&
      Math.hypot(o.pos[0] - c.pos[0], o.pos[2] - c.pos[2]) >= spacing);
    const spread = (pass) => pass.length < 3 || new Set(pass.map((c) => c.quarter)).size >= quarters;
    let picks = [];
    for (let attempt = 0; attempt < (count > 1 ? attempts : 1); attempt++) {
      const pass = [];
      if (kinds) {
        for (const group of groups) {
          for (const c of shuffle(group.slice(), random)) {
            if (apart(c, pass)) {
              pass.push(c);
              break;
            }
          }
        }
      } else {
        for (const c of shuffle(candidates.slice(), random)) {
          if (pass.length >= count) break;
          if (apart(c, pass)) pass.push(c);
        }
      }
      if (pass.length > picks.length || picks.length === 0) picks = pass;
      if (pass.length >= count && spread(pass)) {
        picks = pass;
        break;
      }
    }
    const slots = {};
    picks.forEach((c, i) => (slots[c.anchorId] = kinds ? c.slot : i + 1));
    const guards = [];
    const wanted = spec.item.guarded || 0;
    if (wanted > 0) {
      const excluded = this.trapExcludedRooms(spec.levelId);
      for (const c of picks) {
        if (guards.length >= wanted) break;
        const guard = this.anchor(c.ref);
        if (guard && guard.kind === 'TrapCandidate' && !excluded.has(guard.room) &&
          guards.every((g) => horizontalDistance(cfPos(g.cframe), cfPos(guard.cframe)) >= MIN_TRAP_SPACING)) {
          guards.push(guard);
        }
      }
    }
    return { levelId: spec.levelId, anchors: picks.map((c) => c.anchorId), guards: guards.map((g) => g.id), slots };
  }

  /** RunDirector.trapExcludedRooms: airlocks, stairwell housings, the entry / exit rooms, rooms holding PlayerSpawns. */
  trapExcludedRooms(level) {
    const layout = this.meta.layouts && this.meta.layouts[level];
    const out = new Set();
    if (!layout) return out;
    out.add(layout.entry);
    out.add(layout.exit);
    for (const r of layout.rooms) if (r.kind === 'Airlock' || r.kind === 'Stairwell') out.add(r.id);
    for (const a of layout.anchors) if (a.kind === 'PlayerSpawn') out.add(a.room);
    return out;
  }

  // ---------------------------------------------------------------------------------------------------- plan

  /**
   * The run's spawn plan (RunDirector.plan) for a difficulty and seed: the objective picks, which traps, flasks and
   * batteries are live and where (props: live entity ids; placements: the world pivot each one is moved to), which
   * grates are rusted shut. `short` counts anchors chosen beyond the entities the export built (per kind).
   * @param {string} difficulty
   * @param {number} seed
   * @param {Record<string, Route>} [routes]
   * @returns {Plan}
   */
  plan(difficulty, seed, routes) {
    const spec = DifficultyConfig[difficulty] || DifficultyConfig.Standard;
    const s = normalizeSeed(seed) ?? 1;
    const props = new Set();
    const placements = new Map();
    const short = {};
    const objectives = {};
    for (const floor of (this.meta.objectives && this.meta.objectives.floors) || []) {
      objectives[floor.levelId] = this.pickObjective(s, floor);
    }

    // bear traps: the objective's guard traps first, then the rest of the difficulty's count spaced from them
    const excluded = this.trapExcludedRooms(TRAP_LEVEL);
    const guardIds = new Set(objectives[TRAP_LEVEL] ? objectives[TRAP_LEVEL].guards : []);
    const guards = [...guardIds].map((id) => this.anchor(id)).filter(Boolean).map(withPos);
    const trapCandidates = this.anchors('TrapCandidate', TRAP_LEVEL)
      .filter((a) => !excluded.has(a.room) && !guardIds.has(a.id)).map(withPos);
    const fill = Math.max(0, spec.trapCount - guards.length);
    const traps = chooseSpaced(trapCandidates, fill, seededRandom(s, `Traps|${TRAP_LEVEL}`), MIN_TRAP_SPACING, guards);
    this._assign('BearTrap', TRAP_LEVEL, [...traps, ...guards], props, placements, short);

    // chemical flasks
    for (const [level, count] of [['Level2_ScienceHall', spec.flasksScienceHall], ['Level4_FloodedPool', spec.flasksPool]]) {
      const candidates = this.anchors('FlaskCandidate', level).map(withPos);
      const chosen = choosePreferSpaced(candidates, count, seededRandom(s, `Flasks|${level}`), FLASK_SPACING);
      this._assign('ChemicalFlask', level, chosen, props, placements, short);
    }

    // batteries
    for (const level of LevelOrder) {
      const candidates = this.anchors('BatteryCandidate', level).map(withPos);
      if (!candidates.length) continue;
      const chosen = choosePreferSpaced(candidates, spec.batteriesPerLevel, seededRandom(s, `Batteries|${level}`), BATTERY_SPACING);
      this._assign('Battery', level, chosen, props, placements, short);
    }

    // grate locks
    const lockedGrates = new Set();
    for (const level of LevelOrder) {
      for (const id of this._lockGrates(s, spec.lockedGrateFraction, level, routes)) lockedGrates.add(id);
    }
    return { difficulty, seed: s, props, placements, lockedGrates, objectives, short };
  }

  /**
   * Serves the chosen anchors of a kind on a level with the export's entities of that kind: an entity standing on a
   * chosen anchor stays, the rest move to the remaining anchors (layout order), keeping their own turn on the anchor.
   */
  _assign(kind, level, chosen, props, placements, short) {
    const order = new Map(this.meta.anchors.map((a, i) => [a.id, i]));
    const anchors = chosen.map((c) => c.anchor).sort((a, b) => (order.get(a.id) ?? 0) - (order.get(b.id) ?? 0));
    const entities = this.entities(kind, level).sort((a, b) => (a.id < b.id ? -1 : 1));
    const free = new Set(entities.map((e) => e.id));
    const pending = [];
    for (const a of anchors) {
      if (free.has(a.id)) {
        free.delete(a.id);
        props.add(a.id);
      } else pending.push(a);
    }
    const spare = entities.filter((e) => free.has(e.id));
    pending.forEach((a, i) => {
      const e = spare[i];
      if (!e) {
        short[kind] = (short[kind] || 0) + 1;
        return;
      }
      props.add(e.id);
      placements.set(e.id, this._placed(e, a));
    });
  }

  /** The pivot an entity takes on another anchor: the anchor frame times the entity's offset from its own anchor. */
  _placed(entity, anchor) {
    const own = this.anchor(entity.id);
    const built = cfMatrix(entity.pivot);
    const rel = own ? cfMatrix(own.cframe).invert().multiply(built) : built.clone().setPosition(0, 0, 0);
    return cfMatrix(anchor.cframe).multiply(rel);
  }

  _lockGrates(seed, fraction, level, routes) {
    const graph = this.ventGraph(level);
    if (!graph) return [];
    const lockable = Object.values(graph.grates).filter((g) => g.lockable && !g.criticalPath)
      .sort((a, b) => (a.id < b.id ? -1 : 1));
    const count = lockable.length ? Math.max(0, Math.min(lockable.length, Math.round(fraction * lockable.length))) : 0;
    if (count === 0) return [];
    const gates = new Set(this.meta.layoutDoors.filter((d) => d.level === level && d.kind === 'Gate').map((d) => d.id));
    if (!this.levelSolvable(level, gates, routes)) return [];
    const rng = seededRandom(seed, `Grates|${level}`);
    for (let attempt = 0; attempt <= MAX_REROLLS; attempt++) {
      const order = shuffle(lockable.slice(), rng);
      const blocked = new Set(gates);
      const chosen = order.slice(0, count).map((g) => g.id);
      for (const id of chosen) blocked.add(id);
      if (this.levelSolvable(level, blocked, routes)) return chosen;
    }
    return [];
  }

  /** ZoneGraph.isLevelSolvable: the level's entry room reaches its exit without crossing a blocked portal. */
  levelSolvable(level, blocked, routes) {
    const zg = this.meta.zoneGraph;
    const entryRoom = this.entryRoom(level, routes);
    const exitRoom = this.exitRoom(level, routes) || (level === 'Level5_Roof' ? 'L5_JumpGap' : null);
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

/** The point where two level-local rects meet at `at` along their shared wall, or null. */
function portalPoint(a, b, at) {
  const overlapZ = Math.min(a.z + a.d, b.z + b.d) - Math.max(a.z, b.z);
  const overlapX = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
  if (overlapZ > 0 && Math.abs(a.x + a.w - b.x) < 1e-6) return { x: b.x, z: at };
  if (overlapZ > 0 && Math.abs(b.x + b.w - a.x) < 1e-6) return { x: a.x, z: at };
  if (overlapX > 0 && Math.abs(a.z + a.d - b.z) < 1e-6) return { x: at, z: b.z };
  if (overlapX > 0 && Math.abs(b.z + b.d - a.z) < 1e-6) return { x: at, z: a.z };
  return null;
}

function withPos(anchor) {
  return { id: anchor.id, anchor, pos: cfPos(anchor.cframe) };
}

function spacedFrom(c, chosen, spacing) {
  return spacing <= 0 || chosen.every((o) => horizontalDistance(c.pos, o.pos) >= spacing);
}

function spacedPass(candidates, count, rng, spacing, fixed) {
  const order = shuffle(candidates.slice(), rng);
  const chosen = [];
  const passed = [];
  for (const c of order) {
    if (chosen.length >= count) break;
    if (spacedFrom(c, chosen, spacing) && (!fixed || spacedFrom(c, fixed, spacing))) chosen.push(c);
    else passed.push(c);
  }
  return { chosen, passed };
}

function chooseSpaced(candidates, count, rng, spacing, fixed) {
  let best = [];
  if (count <= 0 || !candidates.length) return best;
  for (let i = 0; i < TRAP_ATTEMPTS; i++) {
    const { chosen } = spacedPass(candidates, count, rng, spacing, fixed);
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
