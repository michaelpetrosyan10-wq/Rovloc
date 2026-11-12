// worldData.js: the game's index over W1's world.json (anchors, triggers, entities, rooms, zone graph, vents,
// stairwells, the objectives) and the run planner (RunDirector) for every run seed.
//
// Everything placed comes from the export: anchors and trigger volumes are CFrames + sizes, entity attachments are
// world frames at the built pivot (relative frames are derived here), room rects are level-local studs already
// placed in world space. Nothing is hand-placed.
//
// Routes. A run leaves each floor by one exit stairwell: routes(seed) gives every school level its Route (the exit
// vestibule, its fire doors, Checkpoint volumes, ExitLock, the stair tower, the next level's entry room and spawn slots).
// Every floor pair has three candidates (meta.routes: slots North, Middle, South); chooseRoute is the one seam where a
// floor's route is picked among them (RunDirector.pickRoute: stream "Route|<level>", unfair draws redrawn by
// meta.routeRule.checks for the entry the previous pick leads to). The other two are jammed for the run (doors.js).
//
// The plan (RunDirector.plan, ported rule for rule over the export's candidate anchors): the objective picks
// (pickObjective: one seeded shuffle per level, "Objective|<level>"), bear traps (the guard traps of the first fuses
// picked, then the difficulty's count spaced from them), the radar's batteries (pickBatteries: per sneaking stage, the
// placement rules walked on TunnelRules' walk graph from the route's entry and the floor's main station), the stun
// flasks (pickFlasks) and rusted grates, every one from its own stream of the run seed. The streams are Rng (util.js), the world's generator bit for bit, so a seed picks
// what the export's RunDirector and a live Roblox server pick (data-test.mjs replays the export's plans). The export
// built a prop on every candidate anchor (a prop's look is its anchor's, never the run's), so a run shows the entities
// on its chosen anchors; placements (entity id -> world pivot) move a spare onto an anchor only if one was missing.

import * as THREE from 'three';
import { DifficultyConfig, LevelOrder, nextLevel } from './config.js';
import { compassOf } from './objectives/config.js';
import { Rng, cfMatrix, cfPos, horizontalDistance, inVolume, list, shuffle } from './util.js';

/**
 * @typedef {{id: string, kind: string, level: string, room: string|null, cframe: number[], attributes: Record<string, any>, tags: string[]}} Anchor
 * @typedef {{id: string, kind: string, level: string, room: string|null, cframe: number[], size: number[], attributes: Record<string, any>}} Trigger
 * @typedef {{id: string, level: string, kind: string, rect: {x: number, z: number, w: number, d: number}, floorY: number, height: number|null}} Room
 * @typedef {{index: number, id: string, type: string, level: string, attributes: Record<string, any>, tags: string[],
 *   pivot: number[], nodes: {path: string, pivot: number[]}[], attachments: Record<string, number[]>,
 *   prompts: any[], colliders: {node: string, cf: number[], size: number[]}[]}} EntityInfo
 * @typedef {{level: string, stairwellId: string, slot: string|null, tower: string|null, exitRoom: string,
 *   nextLevel: string|null, entryRoomOfNextLevel: string|null, exitDoorIds: string[], entryDoorIds: string[],
 *   checkpointVolumes: Trigger[], spawnAnchors: Anchor[], lockEntity: string|null, creatureSpawn: string|null,
 *   compass: string|null, exitPoint: THREE.Vector3}} Route
 * @typedef {{levelId: string, anchors: string[], guards: string[]}} ObjectivePicks
 * @typedef {{difficulty: string, seed: number, props: Set<string>, placements: Map<string, THREE.Matrix4>,
 *   lockedGrates: Set<string>, objectives: Record<string, ObjectivePicks>,
 *   batteries: Record<string, {anchors: string[], broken: number}>, flasks: Record<string, string[]>,
 *   short: Record<string, number>}} Plan
 */

const MIN_TRAP_SPACING = 6;
const TRAP_ATTEMPTS = 16;
const MAX_REROLLS = 64;
const TRAP_LEVEL = 'Level0_Basement';
const WALK_DOOR_KINDS = new Set(['Doorway', 'Door', 'Airlock', 'Ajar', 'Gate', 'RoofDoor']);
const MAX_SEED = 2 ** 31 - 2;
const VARIANT_RANGE = 1000000;

/**
 * RunDirector.variantOf: the look variant (1..VARIANT_RANGE) of a `kind` prop on anchor `anchorId` of `levelId`, fixed
 * per anchor and never per run. The export built every candidate's prop with it, and a live server builds the prop and
 * hands its holder the same one (ChemicalProjectileService: the held flask's look), so a prop looks the same in the
 * world, in the hand and on both platforms.
 */
export function variantOf(kind, levelId, anchorId) {
  return Rng.seeded(1, `Variant|${kind}|${levelId}|${anchorId}`).integer(1, VARIANT_RANGE);
}

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
    /** @type {Map<string, THREE.Matrix4>} */
    this._restInv = new Map();
    /** @type {Map<string, any>} the walking graph per level */
    this._walk = new Map();
    /** @type {Map<string, any>} the battery placement rules' walks per level (_placeWalks) */
    this._places = new Map();
    /** @type {Record<string, Route>} the routes outside a run (every floor's middle stairwell: WorldConfig.routeExit) */
    this.defaultRoutes = {};
    for (const level of LevelOrder) {
      const candidates = this.routeCandidates(level);
      const middle = candidates.find((c) => c.slot === 'Middle') || candidates[0];
      if (middle) this.defaultRoutes[level] = middle;
    }
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
   * A level's anchors of `kind` in the order its layout lists them (meta.layouts: the order RunDirector walks; the
   * export's anchor list is in the built world's order, which is not the same).
   */
  layoutAnchors(kind, level) {
    const layout = this.meta.layouts && this.meta.layouts[level];
    const order = new Map(list(layout && layout.anchors).map((a, i) => [a.id, i]));
    return this.anchors(kind, level).sort((a, b) => (order.get(a.id) ?? Infinity) - (order.get(b.id) ?? Infinity));
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

  /**
   * Every school level's route for a run seed ({levelId: Route}; the roof has none), RunDirector.pickRoute: floors in
   * climbing order, each floor's entry the previous pick's upper vestibule (the basement's layout entry).
   */
  routes(seed) {
    /** @type {Record<string, Route>} */
    const out = {};
    let entry = null;
    for (const level of LevelOrder) {
      const layout = this.meta.layouts && this.meta.layouts[level];
      const route = this.chooseRoute(level, seed, entry || (layout ? layout.entry : null));
      if (route) out[level] = route;
      entry = route ? route.entryRoomOfNextLevel : null;
    }
    return out;
  }

  /**
   * THE seam where a floor's exit is chosen (RunDirector.pickRoute): a draw over the floor's candidates in slot order
   * (North, Middle, South) from the run seed's stream "Route|<level>", kept when it is fair for `entryRoom` (the room the
   * floor is entered by: meta.routeRule.checks[level][entryRoom]), else drawn again from the same stream, up to
   * routeRule.attempts draws; then the first fair candidate in slot order, else the middle one. The stream is Rng, so the
   * picks are a live server's for the same seed.
   * @returns {Route|null}
   */
  chooseRoute(level, seed, entryRoom) {
    const candidates = this.routeCandidates(level);
    if (!candidates.length) return null;
    if (candidates.length === 1) return candidates[0];
    const rule = this.meta.routeRule || {};
    const checks = rule.checks && rule.checks[level] ? rule.checks[level][entryRoom] : null;
    // a way in without precomputed verdicts (none today) counts every candidate fair
    const fair = (c) => !checks || checks.some((k) => k.stairwellId === c.stairwellId && k.fair);
    const attempts = Number.isFinite(rule.attempts) && rule.attempts > 0 ? rule.attempts : 8;
    const random = Rng.seeded(seed, `Route|${level}`);
    for (let i = 0; i < attempts; i++) {
      const candidate = candidates[random.integer(0, candidates.length - 1)];
      if (fair(candidate)) return candidate;
    }
    return candidates.find(fair) || candidates.find((c) => c.slot === 'Middle') || candidates[0];
  }

  /** The exits a floor may be left by, as Routes (meta.routes[level] in slot order; else the stairwells leaving it). */
  routeCandidates(level) {
    const declared = this.meta.routes && this.meta.routes[level];
    const stairs = Array.isArray(declared) && declared.length
      ? declared.map((r) => ({ ...(this.stairwells.find((s) => s.id === (r.stairwellId || r.id)) || {}), ...r }))
      : this.stairwells.filter((s) => s.from === level);
    return stairs.map((s) => this._route(level, s)).filter(Boolean);
  }

  _route(level, stair) {
    const exitRoom = stair.fromRoom || stair.exitRoom;
    if (!exitRoom) return null;
    const doors = Array.isArray(stair.exitDoorIds) && stair.exitDoorIds.length ? stair.exitDoorIds
      : (this.meta.layoutDoors || []).filter((d) => d.level === level && d.kind === 'Airlock' &&
        list(d.rooms).includes(exitRoom)).map((d) => d.id);
    const exitDoorIds = doors.length ? doors : this.meta.entities.filter((e) => e.type === 'AirlockDoor' &&
      e.level === level && e.attributes.FromLevel === level).map((e) => e.id);
    const triggers = this.triggers('Checkpoint', level);
    const declared = stair.checkpoint ? triggers.filter((t) => t.id === stair.checkpoint) : [];
    const inRoom = declared.length ? declared : triggers.filter((t) => t.room === exitRoom);
    const next = stair.to || nextLevel(level);
    const entry = stair.toRoom || stair.entryRoomOfNextLevel || null;
    const listed = Array.isArray(stair.spawns) ? stair.spawns.map((id) => this.anchor(id)).filter(Boolean) : [];
    const spawns = listed.length ? listed : next ? this.anchors('PlayerSpawn', next).filter((a) => !entry || a.room === entry)
      .sort((a, b) => (a.id < b.id ? -1 : 1)) : [];
    const lock = stair.exitLock ? this.entityById.get(stair.exitLock) : this.meta.entities.find((e) => e.type === 'ExitLock' &&
      e.level === level && exitDoorIds.includes(e.attributes.DoorId));
    const exitPoint = this.roomCentre(exitRoom) || new THREE.Vector3();
    return {
      level,
      stairwellId: stair.stairwellId || stair.id,
      slot: stair.slot || null,
      tower: stair.tower || null,
      exitRoom,
      nextLevel: next || null,
      entryRoomOfNextLevel: entry,
      exitDoorIds,
      entryDoorIds: Array.isArray(stair.entryDoorIds) ? stair.entryDoorIds.slice() : [],
      checkpointVolumes: inRoom.length ? inRoom : triggers,
      spawnAnchors: spawns,
      lockEntity: lock ? lock.id : null,
      creatureSpawn: stair.creatureSpawn || null,
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
      add({ id: d.id, rooms: [a, b], links: [],
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
   * taking candidates in shuffled order that lie in another room than the items taken so far and pickSpacing from each of them; a pass stands when it is full and its
   * three or more items lie in at least pickQuarters quarters of the floor, else the first fullest pass is used. The
   * guard traps: the TrapCandidate `ref` of each of the first item.guarded picks that is outside the trap-free rooms
   * and MinTrapSpacing from the guards before it.
   * @returns {ObjectivePicks}
   */
  pickObjective(seed, spec) {
    const all = this.objectiveCandidates(spec.levelId);
    const candidates = all.filter((c) => c.eligible !== false);
    const rules = (this.meta.objectives && this.meta.objectives.rules) || {};
    const spacing = rules.pickSpacing ?? 25;
    const quarters = rules.pickQuarters ?? 2;
    const attempts = rules.pickAttempts ?? 24;
    const random = Rng.seeded(seed, `Objective|${spec.levelId}`);
    const count = Math.min(spec.item.count, candidates.length);
    const apart = (c, taken) => taken.every((o) => o.room !== c.room &&
      Math.hypot(o.pos[0] - c.pos[0], o.pos[2] - c.pos[2]) >= spacing);
    const spread = (pass) => pass.length < 3 || new Set(pass.map((c) => c.quarter)).size >= quarters;
    let picks = [];
    for (let attempt = 0; attempt < (count > 1 ? attempts : 1); attempt++) {
      const pass = [];
      for (const c of shuffle(candidates.slice(), random)) {
        if (pass.length >= count) break;
        if (apart(c, pass)) pass.push(c);
      }
      if (pass.length > picks.length || picks.length === 0) picks = pass;
      if (pass.length >= count && spread(pass)) {
        picks = pass;
        break;
      }
    }
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
    return { levelId: spec.levelId, anchors: picks.map((c) => c.anchorId), guards: guards.map((g) => g.id) };
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
   * The run's spawn plan (RunDirector.plan) for a difficulty and seed: the objective picks (on every floor with an
   * item), which traps and stun flasks are live and where (props: live entity ids; placements: the world pivot of an
   * entity moved onto an anchor without one of its own, none with today's export), the radar's batteries and the stun
   * flasks of every stage that has them (batteries, flasks: anchor ids in pick order; each picked flask spot's
   * ChemicalFlask is live in props), which grates are rusted shut. `short` counts anchors chosen beyond the entities
   * the export built (per kind).
   * @param {string} difficulty
   * @param {number} seed
   * @returns {Plan}
   */
  plan(difficulty, seed) {
    const spec = DifficultyConfig[difficulty] || DifficultyConfig.Standard;
    const s = normalizeSeed(seed) ?? 1;
    const props = new Set();
    const placements = new Map();
    const short = {};
    const objectives = {};
    for (const floor of (this.meta.objectives && this.meta.objectives.floors) || []) {
      if (floor.item) objectives[floor.levelId] = this.pickObjective(s, floor);
    }

    // bear traps: the objective's guard traps first, then the rest of the difficulty's count spaced from them
    const excluded = this.trapExcludedRooms(TRAP_LEVEL);
    const guardIds = new Set(objectives[TRAP_LEVEL] ? objectives[TRAP_LEVEL].guards : []);
    const guards = [...guardIds].map((id) => this.anchor(id)).filter(Boolean).map(withPos);
    const trapCandidates = this.layoutAnchors('TrapCandidate', TRAP_LEVEL)
      .filter((a) => !excluded.has(a.room) && !guardIds.has(a.id)).map(withPos);
    const fill = Math.max(0, spec.trapCount - guards.length);
    const traps = chooseSpaced(trapCandidates, fill, Rng.seeded(s, `Traps|${TRAP_LEVEL}`), MIN_TRAP_SPACING, guards);
    this._assign('BearTrap', TRAP_LEVEL, [...traps, ...guards], props, placements, short);

    // the radar's batteries (every sneaking stage) and the stun flasks (every stage with a count), on the run's route
    const routes = this.routes(s);
    const route = Object.fromEntries(Object.entries(routes).map(([level, r]) => [level, r.stairwellId]));
    const sneaking = new Set(list(this.meta.stageConfig && this.meta.stageConfig.sneaking));
    const flaskCounts = ((this.meta.difficultyConfig || {})[difficulty === 'Nightmare' ? 'Nightmare' : 'Standard'] || {}).flasksPerStage || {};
    /** @type {Record<string, {anchors: string[], broken: number}>} */
    const batteries = {};
    /** @type {Record<string, string[]>} */
    const flasks = {};
    for (const level of LevelOrder) {
      const layout = this.meta.layouts && this.meta.layouts[level];
      if (!layout) continue;
      if (sneaking.has(level)) {
        const picked = objectives[level] ? objectives[level].anchors : null;
        batteries[level] = this.pickBatteries(s, difficulty, level, this.entryPlace(level, routes), this.mainStations(level, route, picked));
      }
      if ((flaskCounts[level] || 0) > 0) {
        flasks[level] = this.pickFlasks(s, flaskCounts[level], level);
        // each picked spot holds its stun flask (RunDirector adds a ChemicalFlask prop per pick)
        this._assign('ChemicalFlask', level, flasks[level].map((id) => withPos(this.anchor(id))), props, placements, short);
      }
    }

    // grate locks
    const lockedGrates = new Set();
    for (const level of LevelOrder) {
      for (const id of this._lockGrates(s, spec.lockedGrateFraction, level)) lockedGrates.add(id);
    }
    return { difficulty, seed: s, props, placements, lockedGrates, objectives, batteries, flasks, short };
  }

  // ---------------------------------------------------------------------------------------------------- batteries

  /**
   * The placement rules' walks on a level (RunDirector walksOf): the walk graph (TunnelRules.walkGraph with crawlways,
   * untimed, the hidden Gates shut) and each battery candidate's distances over it, cached.
   */
  _placeWalks(level) {
    let w = this._places.get(level);
    if (!w) {
      w = { graph: walkGraph(this.meta.layouts[level], true), from: new Map() };
      this._places.set(level, w);
    }
    return w;
  }

  /** Studs walked from layout anchor `anchor` to place `to` ({room, pos: [x, y, z]}, layout coordinates). */
  _walkFromAnchor(level, anchor, to) {
    const w = this._placeWalks(level);
    let dist = w.from.get(anchor.id);
    if (!dist) {
      dist = distances(w.graph, seedsAt(w.graph, anchor.room, anchor.pos[0], anchor.pos[2]));
      w.from.set(anchor.id, dist);
    }
    return reach(w.graph, dist, to.room, to.pos[0], to.pos[2], anchor.room === to.room ? [anchor.pos] : null);
  }

  /** RunDirector.deadEndRooms: the rooms with fewer than two ways in or out (doors, crawlway mouths, open grates). */
  deadEndRooms(level) {
    const g = this._placeWalks(level).graph;
    const out = new Set();
    for (const room of this.meta.layouts[level].rooms) {
      const ways = g.members.get(room.id);
      if (room.kind !== 'Solid' && room.kind !== 'Chase' && (!ways || ways.length < 2)) out.add(room.id);
    }
    return out;
  }

  /** ObjectivePlaces.arrivalPoint: the centroid of a room's PlayerSpawn anchors (else its centre), layout coordinates. */
  arrivalPoint(level, roomId) {
    const layout = this.meta.layouts[level];
    let x = 0;
    let z = 0;
    let n = 0;
    for (const a of layout.anchors) {
      if (a.kind === 'PlayerSpawn' && a.room === roomId) {
        x += a.pos[0];
        z += a.pos[2];
        n++;
      }
    }
    if (n > 0) return [x / n, 0, z / n];
    const room = layout.rooms.find((r) => r.id === roomId);
    return room ? [room.rect.x + room.rect.w / 2, 0, room.rect.z + room.rect.d / 2] : [0, 0, 0];
  }

  /** RunDirector.entryPlace: where the squad enters `level` on `routes` (the previous floor's pick; else its entry). */
  entryPlace(level, routes) {
    const room = this.entryRoom(level, routes);
    return { room, pos: this.arrivalPoint(level, room) };
  }

  /**
   * RunDirector.mainStations: the floor's main station(s) (meta.objectives.floors mainStation): its anchors of that kind,
   * the exit lock nearest the route's exit vestibule for an ExitLock, the exit vestibule for a floor that names none.
   * `route` maps a level to the stairwell it is left by.
   */
  mainStations(level, route, picked) {
    const layout = this.meta.layouts[level];
    const floor = ((this.meta.objectives && this.meta.objectives.floors) || []).find((f) => f.levelId === level);
    const kind = floor ? floor.mainStation : undefined;
    const out = [];
    const exit = this.routeCandidates(level).find((c) => c.stairwellId === route[level]) ||
      this.routeCandidates(level).find((c) => c.slot === 'Middle');
    const exitPlace = exit ? { room: exit.exitRoom, pos: this.arrivalPoint(level, exit.exitRoom) } : null;
    if (!kind) return exitPlace ? [exitPlace] : out;
    const stations = floor.stations;
    const pickedSet = stations && stations.candidate === kind && picked ? new Set(picked) : null;
    let best = null;
    let bestWalk = Infinity;
    for (const anchor of layout.anchors) {
      if (anchor.kind !== kind || (pickedSet && !pickedSet.has(anchor.id))) continue;
      if (kind === 'ExitLock' && exitPlace) {
        const d = this._walkFromAnchor(level, anchor, exitPlace);
        if (d < bestWalk) {
          best = anchor;
          bestWalk = d;
        }
      } else out.push({ room: anchor.room, pos: anchor.pos });
    }
    if (best) out.push({ room: best.room, pos: best.pos });
    return out;
  }

  /**
   * How many battery placement rules layout anchor `anchor` breaks as the `slot`-th pick next to `taken`
   * (RunDirector.brokenRules): the slot's own rule (1st: EntryMin..EntryMax walked from `entry`; 2nd: within
   * StationReach of a station), the spacing (PairSpacing walked from every battery taken), the dead end.
   */
  _brokenRules(level, anchor, slot, taken, entry, stations, dead) {
    const rules = this.meta.radarConfig.Placement;
    let broken = 0;
    if (slot === 1) {
      const d = this._walkFromAnchor(level, anchor, entry);
      if (d < rules.EntryMin || d > rules.EntryMax) broken++;
    } else if (slot === 2 && stations.length > 0) {
      if (!stations.some((st) => this._walkFromAnchor(level, anchor, st) <= rules.StationReach)) broken++;
    }
    if (taken.some((other) => this._walkFromAnchor(level, anchor, { room: other.room, pos: other.pos }) < rules.PairSpacing)) broken++;
    if (dead.has(anchor.room)) broken++;
    return broken;
  }

  /**
   * RunDirector.pickBatteries: the radar's batteries of one sneaking stage (stream "Batteries|<level>"): up to the
   * difficulty's BatteriesMax of its BatteryCandidate anchors in pick order (a squad of n takes the first
   * RadarRules.batteriesPlaced); each slot takes the first shuffled candidate that keeps its rules, else the one breaking
   * the fewest (then the lowest id). `broken` counts the rules broken in all.
   * @returns {{anchors: string[], broken: number}}
   */
  pickBatteries(seed, difficulty, level, entry, stations) {
    const layout = this.meta.layouts[level];
    const radar = this.meta.radarConfig[difficulty === 'Nightmare' ? 'Nightmare' : 'Standard'];
    const candidates = layout.anchors.filter((a) => a.kind === 'BatteryCandidate');
    const count = Math.min(radar.BatteriesMax, candidates.length);
    const order = shuffle(candidates.slice(), Rng.seeded(seed, `Batteries|${level}`));
    const dead = this.deadEndRooms(level);
    const taken = [];
    const used = new Set();
    let broken = 0;
    for (let slot = 1; slot <= count; slot++) {
      let pick = null;
      let fewest = Infinity;
      for (const anchor of order) {
        if (used.has(anchor.id)) continue;
        const n = this._brokenRules(level, anchor, slot, taken, entry, stations, dead);
        if (n === 0) {
          pick = anchor;
          fewest = 0;
          break;
        }
        if (n < fewest || (n === fewest && pick !== null && anchor.id < pick.id)) {
          pick = anchor;
          fewest = n;
        }
      }
      used.add(pick.id);
      taken.push(pick);
      broken += fewest;
    }
    return { anchors: taken.map((a) => a.id), broken };
  }

  /**
   * RunDirector.pickFlasks: `count` (the difficulty's flasksPerStage) of a stage's FlaskCandidate anchors in pick order
   * (stream "Flasks|<level>"; fewer when the floor has fewer candidates).
   */
  pickFlasks(seed, count, level) {
    const candidates = this.meta.layouts[level].anchors.filter((a) => a.kind === 'FlaskCandidate');
    const n = Math.min(count, candidates.length);
    if (n <= 0) return [];
    return shuffle(candidates.slice(), Rng.seeded(seed, `Flasks|${level}`)).slice(0, n).map((a) => a.id);
  }

  /**
   * RunDirector.batteriesOf: the radar batteries of `plan` a squad of `players` uses on `level` (the first
   * RadarRules.batteriesPlaced of its picks).
   * @param {Plan} plan
   * @param {(difficulty: string, players: number) => number} placed RadarRules.batteriesPlaced
   */
  batteriesOf(plan, level, players, placed) {
    const picks = plan.batteries && plan.batteries[level];
    if (!picks) return [];
    return picks.anchors.slice(0, Math.min(picks.anchors.length, placed(plan.difficulty, players)));
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

  /**
   * RunDirector.lockGrates: round(fraction x lockable) of the level's Lockable, non-CriticalPath grates in layout order
   * (RunDirector.lockableGrates), shuffled by the stream "Grates|<level>" and re-rolled from it while the level would be
   * unsolvable with every Gate shut, up to MAX_REROLLS times (then none).
   */
  _lockGrates(seed, fraction, level) {
    const layout = this.meta.layouts && this.meta.layouts[level];
    const specs = layout && layout.vents ? list(layout.vents.grates) : [];
    const lockable = specs.filter((g) => g.lockable && !g.criticalPath);
    const count = lockable.length ? Math.max(0, Math.min(lockable.length, Math.round(fraction * lockable.length))) : 0;
    if (count === 0) return [];
    const gates = new Set(this.meta.layoutDoors.filter((d) => d.level === level && d.kind === 'Gate').map((d) => d.id));
    if (!this.levelSolvable(level, gates)) return [];
    const rng = Rng.seeded(seed, `Grates|${level}`);
    for (let attempt = 0; attempt <= MAX_REROLLS; attempt++) {
      const order = shuffle(lockable.slice(), rng);
      const blocked = new Set(gates);
      const chosen = order.slice(0, count).map((g) => g.id);
      for (const id of chosen) blocked.add(id);
      if (this.levelSolvable(level, blocked)) return chosen;
    }
    return [];
  }

  /**
   * ZoneGraph.isLevelSolvable: the layout's entry room reaches the layout's exit room without crossing a blocked portal
   * (the rule RunDirector re-rolls grate locks by).
   */
  levelSolvable(level, blocked) {
    const zg = this.meta.zoneGraph;
    const layout = this.meta.layouts && this.meta.layouts[level];
    const entryRoom = layout ? layout.entry : null;
    const exitRoom = layout ? layout.exit : null;
    if (!zg || !entryRoom || !exitRoom) return false;
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
  for (const c of order) {
    if (chosen.length >= count) break;
    if (spacedFrom(c, chosen, spacing) && (!fixed || spacedFrom(c, fixed, spacing))) chosen.push(c);
  }
  return chosen;
}

function chooseSpaced(candidates, count, rng, spacing, fixed) {
  let best = [];
  if (count <= 0 || !candidates.length) return best;
  for (let i = 0; i < TRAP_ATTEMPTS; i++) {
    const chosen = spacedPass(candidates, count, rng, spacing, fixed);
    if (chosen.length > best.length) best = chosen;
    if (best.length >= count) break;
  }
  return best;
}

// ---------------------------------------------------------------------------------------------------- the walk graph

/** TunnelRules.walkGraph's walkable door kinds (a hidden Gate is shut for the placement rules). */
const PLACE_DOORS = new Set(['Doorway', 'Door', 'Ajar', 'Airlock', 'RoofDoor']);
const WALK_EPS = 1e-3;

/** TunnelRules.doorPoint: the level-local [x, z] a door opens at (its centre on the shared wall), or null. */
function doorPoint(a, b, at) {
  if (Math.abs(a.x + a.w - b.x) < WALK_EPS || Math.abs(b.x + b.w - a.x) < WALK_EPS) {
    const coord = Math.abs(a.x + a.w - b.x) < WALK_EPS ? b.x : a.x;
    if (Math.min(a.z + a.d, b.z + b.d) - Math.max(a.z, b.z) > WALK_EPS) return [coord, at];
  }
  if (Math.abs(a.z + a.d - b.z) < WALK_EPS || Math.abs(b.z + b.d - a.z) < WALK_EPS) {
    const coord = Math.abs(a.z + a.d - b.z) < WALK_EPS ? b.z : a.z;
    if (Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x) > WALK_EPS) return [at, coord];
  }
  return null;
}

/**
 * TunnelRules.walkGraph(layout, crawl, untimed): door nodes (crawlway doors kept when `crawl`), the always-open vents
 * (duct nodes linked along the ducts, each never-locking grate's node joining its room), and every pair of nodes of one
 * room linked in a straight line (rooms in id order, so the links, and every tie, are RunDirector's).
 * @returns {{pos: number[][], links: {to: number, cost: number}[][], members: Map<string, number[]>}}
 */
function walkGraph(layout, crawl) {
  const rooms = new Map(layout.rooms.map((r) => [r.id, r]));
  const g = { pos: [], links: [], members: new Map() };
  const member = (room, index) => {
    if (!g.members.has(room)) g.members.set(room, []);
    g.members.get(room).push(index);
  };
  const span = (a, b) => Math.hypot(g.pos[a][0] - g.pos[b][0], g.pos[a][1] - g.pos[b][1]);
  const link = (a, b, cost) => {
    g.links[a].push({ to: b, cost });
    g.links[b].push({ to: a, cost });
  };
  for (const door of layout.doors) {
    const ids = list(door.rooms);
    if (!PLACE_DOORS.has(door.kind) || ids.length !== 2) continue;
    const a = rooms.get(ids[0]);
    const b = rooms.get(ids[1]);
    if (!a || !b || ((a.kind === 'Crawlway' || b.kind === 'Crawlway') && !crawl)) continue;
    const p = doorPoint(a.rect, b.rect, door.at);
    if (!p) continue;
    g.pos.push(p);
    g.links.push([]);
    for (const id of ids) member(id, g.pos.length - 1);
  }
  const vents = layout.vents;
  if (vents) {
    const ventIndex = new Map();
    for (const node of list(vents.nodes)) {
      g.pos.push([node.x, node.z]);
      g.links.push([]);
      ventIndex.set(node.id, g.pos.length - 1);
    }
    for (const edge of list(vents.edges)) {
      const a = ventIndex.get(edge.a);
      const b = ventIndex.get(edge.b);
      if (a !== undefined && b !== undefined) link(a, b, span(a, b));
    }
    for (const grate of list(vents.grates)) {
      const index = ventIndex.get(grate.node);
      if (index !== undefined && !grate.lockable && rooms.has(grate.room)) member(grate.room, index);
    }
  }
  for (const id of [...g.members.keys()].sort((x, y) => (x < y ? -1 : x > y ? 1 : 0))) {
    const nodes = g.members.get(id);
    for (let i = 0; i < nodes.length; i++) {
      for (let j = i + 1; j < nodes.length; j++) link(nodes[i], nodes[j], span(nodes[i], nodes[j]));
    }
  }
  return g;
}

/** TunnelRules.distances: the shortest walks from `seeds` ([node, distance]) over the graph (Dijkstra on a heap). */
function distances(g, seeds) {
  const dist = new Array(g.pos.length).fill(Infinity);
  const heap = new Heap();
  for (const [node, d] of seeds) {
    if (d < dist[node]) {
      dist[node] = d;
      heap.push(d, node);
    }
  }
  while (heap.size > 0) {
    const [d, node] = heap.pop();
    if (d > dist[node] + WALK_EPS) continue;
    for (const l of g.links[node]) {
      const nd = d + l.cost;
      if (nd < dist[l.to] - WALK_EPS) {
        dist[l.to] = nd;
        heap.push(nd, l.to);
      }
    }
  }
  return dist;
}

/** TunnelRules.seedsAt: a point's straight line to each door of its room. */
function seedsAt(g, room, x, z) {
  return (g.members.get(room) || []).map((node) => [node, Math.hypot(g.pos[node][0] - x, g.pos[node][1] - z)]);
}

/** TunnelRules.reach: the walk from the sources (`dist`) to point (x, z) in `room`; `direct`: sources in that room. */
function reach(g, dist, room, x, z, direct) {
  let best = Infinity;
  for (const node of g.members.get(room) || []) best = Math.min(best, dist[node] + Math.hypot(g.pos[node][0] - x, g.pos[node][1] - z));
  for (const q of direct || []) best = Math.min(best, Math.hypot(q[0] - x, q[2] - z));
  return best;
}

/** TunnelRules' binary heap of (distance, node): popped in the same order as there. */
class Heap {
  constructor() {
    this.d = [];
    this.n = [];
    this.size = 0;
  }

  push(dist, node) {
    let i = this.size++;
    this.d[i] = dist;
    this.n[i] = node;
    while (i > 0) {
      const p = (i - 1) >> 1;
      if (this.d[p] <= this.d[i]) break;
      this._swap(p, i);
      i = p;
    }
  }

  pop() {
    const out = [this.d[0], this.n[0]];
    const last = --this.size;
    this.d[0] = this.d[last];
    this.n[0] = this.n[last];
    this.d.length = this.size;
    this.n.length = this.size;
    let i = 0;
    for (;;) {
      const l = i * 2 + 1;
      const r = l + 1;
      let m = i;
      if (l < this.size && this.d[l] < this.d[m]) m = l;
      if (r < this.size && this.d[r] < this.d[m]) m = r;
      if (m === i) break;
      this._swap(m, i);
      i = m;
    }
    return out;
  }

  _swap(a, b) {
    [this.d[a], this.d[b]] = [this.d[b], this.d[a]];
    [this.n[a], this.n[b]] = [this.n[b], this.n[a]];
  }
}
