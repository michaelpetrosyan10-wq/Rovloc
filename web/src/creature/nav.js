// FloorNav: the Creature's floor pathfinding (the PathfindingService call in Locomotion.defaultEngine), built on the
// level's zone graph: its rooms and the door portals between them (ZoneGraph's Doorway / Door / Ajar / RoofDoor /
// Gate / Airlock edges; Boarded doors are planked shut and give no portal).
//
// The agent is CreatureConfig.PathAgent (radius 2, no jumping or climbing). A route is A* over the portals (each
// door's opening on the shared wall, from LayoutSchema's sharedEdge and the door's `at` / width), then string-pulled
// (the funnel algorithm) through each opening narrowed by the agent radius, entering and leaving it square to the
// wall, so every waypoint keeps the agent clear of the jambs and the walls either side. Rooms are convex rectangles,
// so a straight leg inside one never meets a wall. Fixture doors (the Hallway Gate, airlock doors, the roof door) are
// passable only while open (their DoorState; closed and locked leaves collide in the Default group in Roblox, so
// PathfindingService routes around them or reports no path). Ordinary classroom doors stand open with
// MonsterPassthrough leaves, and doorways are open arches: always passable.
//
// Inside a room the Default-group fixtures of the layout stand in the way (its `platforms` taller than the walker
// steps up: HVAC units, the water tank, boilers, bleachers, the diving tower; and its `pillars`). PathfindingService
// routes around them, so every straight leg of the route is cut where it crosses from room to room, and a piece that
// meets one of those footprints (grown by the agent radius) is replaced by the shortest way round it inside its
// room: Dijkstra over the grown footprints' corners that keep the agent clear of the room's walls. Footprints holding
// the start or the goal do not block (the Creature is already beside it, or its target is on it).
//
// Tunnels. The Creature never enters a crawlway or a duct: rooms of kind Crawlway / Chase give it no floor, and a
// portal flagged crawl-only, or lower than its hunched height, is shut to it. The flags come from the layout door
// (`crawlOnly`, `clearance`) or from the zone graph edge of the same portal; until the tunnel maps carry them every
// edge is clear. A portal (or a room) lower than its standing height is walked hunched (clearanceAt).
// pathLength(from, to) is the walking distance of a route (Infinity without one); samplePoints() is a lattice of free
// floor points over the walkable rooms (the teleport's candidates while the maps carry none); reachable(from) tells
// which points a walk from `from` can get to through the portals open now (a level may fall apart into several parts
// joined only by locked airlocks or ducts).
//
// Pools. A basin's water is no floor (the Creature enters and leaves the water only by a warp, Locomotion): a room a
// basin lies in keeps only the deck round it, as up to four strips (west and east the room's full depth, north and
// south between them), each a node of its own (`key`; `id` stays the room's), joined where they meet. A door opens
// onto the strip it lies on, none onto the water. So no route crosses the pool, and decks the water parts are joined
// only by the ways round it.

import * as THREE from 'three';
import { STEP_UP } from './body.js';
import { CreatureConfig, WorldDefaults } from './config.js';
import { BinaryHeap } from './util.js';

const PASSABLE = new Set(['Doorway', 'Door', 'Ajar', 'RoofDoor', 'Gate', 'Airlock']);
const NO_FLOOR = new Set(['Chase', 'Crawlway']);
const NO_SAMPLES = new Set(['Airlock', 'Chase', 'Stairwell', 'Crawlway', 'Pool']);
const SAMPLE_INSET = 2.5;
const PORTAL_REACH = 3; // within this of a portal's opening its clearance counts
const SCRIPTED = new Set(['Gate', 'Airlock', 'RoofDoor']);
const EPS = 1e-3;
const RADIUS = CreatureConfig.PathAgent.AgentRadius;
const AGENT_HEIGHT = CreatureConfig.PathAgent.AgentHeight;
// The hunch comes before the lintel (headroomAlong): the head room counts this far along its way ahead, its head's lead
// on its root (the mask hangs about 1.6 studs ahead of it, more in a chase) plus what its pace covers while it bends
// (the rig's hunch settles in about half a second), sampled every HEADROOM_STEP studs.
export const HEAD_LEAD = 2;
export const HUNCH_LEAD_SECONDS = 0.5;
const HEADROOM_STEP = 1;
const _ahead = new THREE.Vector3();
const CLEARANCE = RADIUS + 0.25; // a footprint grows by this for the agent
const WALL_CLEARANCE = RADIUS + WorldDefaults.WallThickness / 2; // a detour corner stays this far inside its room
const INTERIOR = 0.01; // footprints shrink by this for the crossing test, so legs along their edges are clear
const MAX_SPLITS = 24;
const SPACING = CreatureConfig.PathAgent.WaypointSpacing;
const MIN_DECK = 2; // a deck strip narrower than this beside a pool is no floor

/** @typedef {{id: string, minX: number, maxX: number, minZ: number, maxZ: number}} Obstacle */

/**
 * `id` is the layout room's; `key` names the node in the route graph (the room's id, or `<id>#<side>` for one strip
 * of the deck round a pool).
 * @typedef {{id: string, key: string, kind: string, minX: number, maxX: number, minZ: number, maxZ: number,
 *   floorY: number, height: number}} NavRoom
 * @typedef {{id: string, kind: string, a: string, b: string, axis: 'X'|'Z', coord: number, u0: number, u1: number,
 *   mid: THREE.Vector3, scripted: boolean, clearance: number}} Portal  `a` / `b` are room keys
 */

/** The tunnel flags of every portal: zone graph edges first, the layout door's own fields win. */
export function portalFlags(meta) {
  /** @type {Map<string, {clearance: number, crawlOnly: boolean}>} */
  const out = new Map();
  const edges = meta.zoneGraph && Array.isArray(meta.zoneGraph.edges) ? meta.zoneGraph.edges : [];
  for (const e of edges) {
    if (!e || !e.portalId || (e.clearance === undefined && e.crawlOnly === undefined)) continue;
    out.set(e.portalId, { clearance: Number.isFinite(e.clearance) ? e.clearance : Infinity, crawlOnly: e.crawlOnly === true });
  }
  for (const d of meta.layoutDoors || []) {
    if (!d || (d.clearance === undefined && d.crawlOnly === undefined)) continue;
    const was = out.get(d.id) || { clearance: Infinity, crawlOnly: false };
    out.set(d.id, {
      clearance: Number.isFinite(d.clearance) ? d.clearance : was.clearance,
      crawlOnly: d.crawlOnly === true || (d.crawlOnly === undefined && was.crawlOnly),
    });
  }
  return out;
}

export class FloorNav {
  /**
   * @param {string} levelId
   * @param {any} meta world.json
   * @param {(doorId: string) => boolean} doorOpen whether a fixture door lets the Creature through now
   * @param {{hunchedHeight?: number}} [metrics] the rig's hunched height (lower portals are shut to it)
   */
  constructor(levelId, meta, doorOpen, metrics = {}) {
    this.levelId = levelId;
    this.doorOpen = doorOpen;
    this.minClearance = Number.isFinite(metrics.hunchedHeight) ? metrics.hunchedHeight : 9;
    const flags = portalFlags(meta);
    const levelHeight = meta.levels && meta.levels[levelId] ? meta.levels[levelId].height : undefined;
    const world = meta.worldConfig || {};
    const doorWidth = world.DoorWidth ?? WorldDefaults.DoorWidth;
    const airlockWidth = world.AirlockDoorWidth ?? WorldDefaults.AirlockDoorWidth;
    // rooms are world rects; a layout door's `at` is level-local (along the shared wall)
    const level = meta.levels && meta.levels[levelId];
    const origin = level && Array.isArray(level.origin) ? level.origin : [0, 0, 0];
    const basins = levelBasins(meta, levelId, origin);
    /** @type {NavRoom[]} */
    this.rooms = [];
    /** @type {Map<string, NavRoom>} the route graph's nodes, by key */
    this.roomById = new Map();
    /** @type {Map<string, NavRoom[]>} a layout room's nodes: itself, or the deck strips round the pool in it */
    this.partsOf = new Map();
    for (const room of meta.rooms || []) {
      if (room.level !== levelId || NO_FLOOR.has(room.kind)) continue;
      const r = room.rect;
      const nr = { id: room.id, key: room.id, kind: room.kind, minX: r.x, maxX: r.x + r.w, minZ: r.z, maxZ: r.z + r.d,
        floorY: room.floorY, height: room.height ?? levelHeight ?? Infinity };
      const parts = deckParts(nr, basins);
      this.partsOf.set(room.id, parts);
      for (const part of parts) {
        this.rooms.push(part);
        this.roomById.set(part.key, part);
      }
    }
    /** @type {Portal[]} */
    this.portals = [];
    /** @type {Map<string, Portal[]>} */
    this.portalsOf = new Map();
    for (const room of this.rooms) this.portalsOf.set(room.key, []);
    for (const door of meta.layoutDoors || []) {
      if (door.level !== levelId || !PASSABLE.has(door.kind)) continue;
      const flag = flags.get(door.id);
      // crawl-only, or too low even hunched: never its way
      if (flag && (flag.crawlOnly || flag.clearance < this.minClearance)) continue;
      const width = door.width ?? (door.kind === 'Airlock' ? airlockWidth : doorWidth);
      // the door opens onto the node (a deck strip, or the room) its opening lies on
      for (const a of this.partsOf.get(door.rooms[0]) || []) {
        for (const b of this.partsOf.get(door.rooms[1]) || []) {
          const edge = sharedEdge(a, b);
          if (!edge) continue;
          const at = door.at + (edge.axis === 'X' ? origin[2] : origin[0]);
          const u0 = Math.max(at - width / 2, edge.from);
          const u1 = Math.min(at + width / 2, edge.to);
          if (u1 - u0 < EPS) continue;
          this._addPortal({ id: door.id, kind: door.kind, a, b, edge, u0, u1, scripted: SCRIPTED.has(door.kind),
            clearance: flag ? flag.clearance : Infinity });
        }
      }
    }
    // the strips of a deck join where they meet, round the pool's corners
    for (const parts of this.partsOf.values()) {
      for (let i = 0; i < parts.length; i++) {
        for (let j = i + 1; j < parts.length; j++) {
          const edge = sharedEdge(parts[i], parts[j]);
          if (!edge) continue;
          this._addPortal({ id: `${parts[i].key}|${parts[j].key}`, kind: 'Doorway', a: parts[i], b: parts[j], edge,
            u0: edge.from, u1: edge.to, scripted: false, clearance: Infinity });
        }
      }
    }
    /** @type {Obstacle[]} the layout's in-room footprints, grown by CLEARANCE (it passes under a platform only hunched) */
    this.obstacles = levelObstacles(meta, levelId, Math.max(AGENT_HEIGHT, this.minClearance)).map((o) => ({
      id: o.id, minX: o.minX - CLEARANCE, maxX: o.maxX + CLEARANCE, minZ: o.minZ - CLEARANCE, maxZ: o.maxZ + CLEARANCE,
    }));
    /** @type {Array<{position: THREE.Vector3, room: string}>|null} */
    this.samples = null;
  }

  /** Adds a portal on `edge` (the wall `a` and `b` share) over [u0, u1] along it. */
  _addPortal({ id, kind, a, b, edge, u0, u1, scripted, clearance }) {
    const um = (u0 + u1) / 2;
    const mid = edge.axis === 'X' ? new THREE.Vector3(edge.coord, a.floorY, um) : new THREE.Vector3(um, a.floorY, edge.coord);
    const portal = { id, kind, a: a.key, b: b.key, axis: edge.axis, coord: edge.coord, u0, u1, mid, scripted, clearance };
    this.portals.push(portal);
    this.portalsOf.get(a.key).push(portal);
    this.portalsOf.get(b.key).push(portal);
  }

  /**
   * Which points a walk from `from` can get to now, through the portals open now: a test (point) => boolean. A point
   * off every room counts by the room nearest it.
   * @param {THREE.Vector3} from
   * @returns {(point: THREE.Vector3) => boolean}
   */
  reachable(from) {
    const start = this.roomAt(from) || this.nearestRoom(from);
    if (!start) return () => false;
    const seen = new Set([start.key]);
    const stack = [start.key];
    while (stack.length > 0) {
      const key = stack.pop();
      for (const portal of this.portalsOf.get(key) || []) {
        if (!this.open(portal)) continue;
        const next = portal.a === key ? portal.b : portal.a;
        if (seen.has(next)) continue;
        seen.add(next);
        stack.push(next);
      }
    }
    return (point) => {
      const room = this.roomAt(point) || this.nearestRoom(point);
      return !!room && seen.has(room.key);
    };
  }

  /**
   * The head room it walks under (the hunch rule, docs/MONSTER.md 2): the lowest clearance at `root` and along `route`
   * (the points it walks to next), HEAD_LEAD + `pace` x HUNCH_LEAD_SECONDS studs ahead, sampled every HEADROOM_STEP
   * studs, so it is down before its head reaches a lintel or a tunnel's ceiling. The host's brain passes its planned
   * route and walk speed; a co-op client's puppet the host's positions ahead of it and its measured speed.
   * @param {THREE.Vector3} root
   * @param {Iterable<THREE.Vector3>} route
   * @param {number} pace studs a second
   */
  headroomAlong(root, route, pace) {
    let clearance = this.clearanceAt(root);
    let left = HEAD_LEAD + Math.max(0, pace) * HUNCH_LEAD_SECONDS;
    let from = root;
    for (const to of route) {
      const leg = Math.hypot(to.x - from.x, to.z - from.z);
      const span = Math.min(leg, left);
      for (let s = HEADROOM_STEP; s < span + HEADROOM_STEP; s += HEADROOM_STEP) {
        const k = Math.min(s, span) / leg;
        _ahead.set(from.x + (to.x - from.x) * k, from.y, from.z + (to.z - from.z) * k);
        clearance = Math.min(clearance, this.clearanceAt(_ahead));
      }
      left -= leg;
      if (left <= 0) break;
      from = to;
    }
    return clearance;
  }

  /** The head room at `p`: its room's height, or a low portal's clearance when it stands in that opening. */
  clearanceAt(p) {
    const room = this.roomAt(p);
    let c = room ? room.height : Infinity;
    for (const portal of this.portals) {
      if (!(portal.clearance < c)) continue;
      const along = portal.axis === 'X' ? p.z : p.x;
      const across = portal.axis === 'X' ? p.x : p.z;
      if (Math.abs(across - portal.coord) <= PORTAL_REACH && along >= portal.u0 - 1 && along <= portal.u1 + 1) c = portal.clearance;
    }
    return c;
  }

  /** The walking distance of the route from `from` to `to` (Infinity when there is none). */
  pathLength(from, to) {
    const route = this.computePath(from, to);
    if (!route) return Infinity;
    let length = 0;
    let a = from;
    for (const b of route.waypoints) {
      length += Math.hypot(b.x - a.x, b.z - a.z);
      a = b;
    }
    return length;
  }

  /**
   * Free floor points over the walkable rooms, every `spacing` studs (no stair vestibule, duct, crawlway or pool;
   * clear of the obstacle footprints and SAMPLE_INSET off the walls). Cached; deterministic.
   */
  samplePoints(spacing = 6) {
    if (this.samples) return this.samples;
    const out = [];
    for (const room of this.rooms) {
      if (NO_SAMPLES.has(room.kind)) continue;
      const minX = room.minX + SAMPLE_INSET;
      const maxX = room.maxX - SAMPLE_INSET;
      const minZ = room.minZ + SAMPLE_INSET;
      const maxZ = room.maxZ - SAMPLE_INSET;
      if (minX > maxX || minZ > maxZ) continue;
      const nx = Math.max(1, Math.floor((maxX - minX) / spacing) + 1);
      const nz = Math.max(1, Math.floor((maxZ - minZ) / spacing) + 1);
      for (let i = 0; i < nx; i++) {
        for (let j = 0; j < nz; j++) {
          const x = nx === 1 ? (minX + maxX) / 2 : minX + ((maxX - minX) * i) / (nx - 1);
          const z = nz === 1 ? (minZ + maxZ) / 2 : minZ + ((maxZ - minZ) * j) / (nz - 1);
          let free = true;
          for (const o of this.obstacles) if (insideRect(o, x, z)) free = false;
          if (free) out.push({ position: new THREE.Vector3(x, room.floorY, z), room: room.id });
        }
      }
    }
    this.samples = out;
    return out;
  }

  /** The (non-Chase) room holding `p` horizontally, or null. @param {THREE.Vector3} p */
  roomAt(p) {
    for (const room of this.rooms) {
      if (p.x >= room.minX - EPS && p.x <= room.maxX + EPS && p.z >= room.minZ - EPS && p.z <= room.maxZ + EPS) return room;
    }
    return null;
  }

  /** The room nearest `p` (distance to its rectangle). */
  nearestRoom(p) {
    let best = null;
    let bestD = Infinity;
    for (const room of this.rooms) {
      const dx = Math.max(room.minX - p.x, 0, p.x - room.maxX);
      const dz = Math.max(room.minZ - p.z, 0, p.z - room.maxZ);
      const d = dx * dx + dz * dz;
      if (d < bestD) {
        bestD = d;
        best = room;
      }
    }
    return best;
  }

  /** Whether a portal lets the Creature through now. @param {Portal} portal */
  open(portal) {
    return !portal.scripted || this.doorOpen(portal.id);
  }

  /**
   * A route from `from` to `to`: {waypoints} (floor-level points, the first after the start, ending at `to`), or
   * null when no open portal sequence joins their rooms.
   * @param {THREE.Vector3} from @param {THREE.Vector3} to
   * @returns {{waypoints: THREE.Vector3[]}|null}
   */
  computePath(from, to) {
    const start = this.roomAt(from) || this.nearestRoom(from);
    const goal = this.roomAt(to) || this.nearestRoom(to);
    if (!start || !goal) return null;
    const goalPoint = new THREE.Vector3(to.x, goal.floorY, to.z);
    if (start === goal) return { waypoints: spaced(from, this._detour(from, [goalPoint])) };
    const route = this._search(start, goal, from, to);
    if (!route) return null;
    const corridor = [];
    let room = start;
    for (const portal of route) {
      const next = portal.a === room.key ? this.roomById.get(portal.b) : this.roomById.get(portal.a);
      for (const piece of crossing(portal, room)) corridor.push(piece);
      room = next;
    }
    const points = funnel(from, goalPoint, corridor);
    const waypoints = [];
    for (const p of points) waypoints.push(new THREE.Vector3(p.x, p.y, p.z));
    return { waypoints: spaced(from, this._detour(from, waypoints)) };
  }

  /**
   * The route `from` -> `points` with every piece that meets an obstacle footprint replaced by the way round it.
   * @param {THREE.Vector3} from @param {THREE.Vector3[]} points @returns {THREE.Vector3[]}
   */
  _detour(from, points) {
    if (this.obstacles.length === 0 || points.length === 0) return points;
    const goal = points[points.length - 1];
    const skip = new Set();
    for (const o of this.obstacles) if (insideRect(o, from.x, from.z) || insideRect(o, goal.x, goal.z)) skip.add(o);
    const blockers = this.obstacles.filter((o) => !skip.has(o));
    if (blockers.length === 0) return points;
    const out = [];
    let a = from;
    for (const b of points) {
      if (!blocked(blockers, a.x, a.z, b.x, b.z)) {
        out.push(b);
        a = b;
        continue;
      }
      const pieces = this._splitByRooms(a, b);
      for (let i = 0; i + 1 < pieces.length; i++) {
        const p = pieces[i];
        const q = pieces[i + 1];
        const last = i + 2 === pieces.length;
        const room = this.roomAt(new THREE.Vector3((p.x + q.x) / 2, 0, (p.z + q.z) / 2));
        const way = room && blocked(blockers, p.x, p.z, q.x, q.z) ? aroundIn(room, blockers, p, q) : null;
        if (way) for (const c of way) out.push(new THREE.Vector3(c.x, room.floorY, c.z));
        // a room boundary point only stays where a detour turns at it
        if (last) out.push(b);
        else if (way || (i + 2 < pieces.length && room && blocked(blockers, q.x, q.z, pieces[i + 2].x, pieces[i + 2].z))) {
          out.push(new THREE.Vector3(q.x, q.y, q.z));
        }
      }
      a = b;
    }
    return out;
  }

  /** `a` -> `b` cut where it passes from one room's rectangle into the next: [a, crossings..., b]. */
  _splitByRooms(a, b) {
    const pieces = [a];
    let cursor = a;
    let room = this.roomAt(a);
    for (let k = 0; k < MAX_SPLITS && room; k++) {
      if (insideRect(room, b.x, b.z)) break;
      const t = exitParameter(room, cursor, b);
      if (!(t > EPS && t < 1 - EPS)) break;
      const at = cursor.clone().lerp(b, t);
      pieces.push(at);
      const ahead = cursor.clone().lerp(b, Math.min(1, t + 0.01));
      room = this.roomAt(ahead);
      cursor = at;
    }
    pieces.push(b);
    return pieces;
  }

  /** A* over the portals: the portal list from `start` room to `goal` room, or null. */
  _search(start, goal, from, to) {
    const key = (portal, into) => `${portal.id}>${into}`;
    const cost = new Map();
    const came = new Map();
    const closed = new Set();
    const open = new BinaryHeap();
    const h = (p) => Math.hypot(p.x - to.x, p.z - to.z);
    for (const portal of this.portalsOf.get(start.key) || []) {
      if (!this.open(portal)) continue;
      const into = portal.a === start.key ? portal.b : portal.a;
      const k = key(portal, into);
      const c = Math.hypot(portal.mid.x - from.x, portal.mid.z - from.z);
      if (!cost.has(k) || c < cost.get(k)) {
        cost.set(k, c);
        came.set(k, null);
        open.push({ k, portal, into }, c + h(portal.mid));
      }
    }
    while (open.size() > 0) {
      const node = open.pop();
      if (closed.has(node.k)) continue;
      closed.add(node.k);
      if (node.into === goal.key) {
        const route = [];
        let cursor = node;
        while (cursor) {
          route.unshift(cursor.portal);
          cursor = came.get(cursor.k);
        }
        return route;
      }
      const here = cost.get(node.k);
      for (const portal of this.portalsOf.get(node.into) || []) {
        if (portal === node.portal || !this.open(portal)) continue;
        const into = portal.a === node.into ? portal.b : portal.a;
        const k = key(portal, into);
        if (closed.has(k)) continue;
        const c = here + node.portal.mid.distanceTo(portal.mid);
        if (!cost.has(k) || c < cost.get(k) - 1e-9) {
          cost.set(k, c);
          came.set(k, node);
          open.push({ k, portal, into }, c + h(portal.mid));
        }
      }
    }
    return null;
  }
}

/**
 * LayoutSchema.sharedEdge: the wall two touching rooms share (axis "X": constant X, running along Z), with the
 * stretch [from, to] they share along it.
 */
export function sharedEdge(a, b) {
  const overlapZ = [Math.max(a.minZ, b.minZ), Math.min(a.maxZ, b.maxZ)];
  const overlapX = [Math.max(a.minX, b.minX), Math.min(a.maxX, b.maxX)];
  if (overlapZ[1] - overlapZ[0] > EPS) {
    if (Math.abs(a.maxX - b.minX) < EPS) return { axis: 'X', coord: a.maxX, from: overlapZ[0], to: overlapZ[1] };
    if (Math.abs(a.minX - b.maxX) < EPS) return { axis: 'X', coord: a.minX, from: overlapZ[0], to: overlapZ[1] };
  }
  if (overlapX[1] - overlapX[0] > EPS) {
    if (Math.abs(a.maxZ - b.minZ) < EPS) return { axis: 'Z', coord: a.maxZ, from: overlapX[0], to: overlapX[1] };
    if (Math.abs(a.minZ - b.maxZ) < EPS) return { axis: 'Z', coord: a.minZ, from: overlapX[0], to: overlapX[1] };
  }
  return null;
}

/**
 * The two funnel segments crossing `portal` out of `room`: the opening narrowed by the agent radius, set back by the
 * radius into the room it leaves and out into the room it enters (so the route meets the wall square on).
 * @returns {Array<{p: THREE.Vector3, q: THREE.Vector3}>}
 */
function crossing(portal, room) {
  const inward = portal.axis === 'X'
    ? (room.minX < portal.coord - EPS ? -1 : 1)
    : (room.minZ < portal.coord - EPS ? -1 : 1);
  let u0 = portal.u0 + RADIUS;
  let u1 = portal.u1 - RADIUS;
  if (u1 < u0) {
    const m = (portal.u0 + portal.u1) / 2;
    u0 = m;
    u1 = m;
  }
  const y = portal.mid.y;
  const at = (offset, u) => (portal.axis === 'X'
    ? new THREE.Vector3(portal.coord + offset, y, u)
    : new THREE.Vector3(u, y, portal.coord + offset));
  const back = inward * RADIUS;
  return [
    { p: at(back, u0), q: at(back, u1) },
    { p: at(-back, u0), q: at(-back, u1) },
  ];
}

// Twice the signed area of the triangle a, b, c in the XZ plane (Recast's triarea2 on x / z).
function triarea2(a, b, c) {
  const ax = b.x - a.x;
  const az = b.z - a.z;
  const bx = c.x - a.x;
  const bz = c.z - a.z;
  return bx * az - ax * bz;
}

function same(a, b) {
  return Math.abs(a.x - b.x) < 1e-6 && Math.abs(a.z - b.z) < 1e-6;
}

/**
 * The simple stupid funnel algorithm (Mononen) over portal segments: the string-pulled route from `start` to `goal`
 * through every segment. Returns the points after the start, ending at the goal.
 * @param {THREE.Vector3} start @param {THREE.Vector3} goal
 * @param {Array<{p: THREE.Vector3, q: THREE.Vector3}>} segments
 */
export function funnel(start, goal, segments) {
  // orient every segment: `left` / `right` as seen walking through it
  const portals = [{ left: start, right: start }];
  let prev = start;
  for (let i = 0; i < segments.length; i++) {
    const s = segments[i];
    const next = i + 1 < segments.length ? midpoint(segments[i + 1]) : goal;
    const dir = { x: next.x - prev.x, z: next.z - prev.z };
    const mid = midpoint(s);
    const side = (pt) => dir.x * (pt.z - mid.z) - dir.z * (pt.x - mid.x);
    // the funnel's convention (triarea2(apex, right, left) < 0 for an apex behind the portal): `left` is the end
    // on the positive side of the travel direction (cross(dir, end - mid) > 0)
    let left = s.q;
    let right = s.p;
    if (side(s.p) > side(s.q)) {
      left = s.p;
      right = s.q;
    }
    portals.push({ left, right });
    prev = mid;
  }
  portals.push({ left: goal, right: goal });
  const path = [];
  let apex = start;
  let left = portals[0].left;
  let right = portals[0].right;
  let apexIndex = 0;
  let leftIndex = 0;
  let rightIndex = 0;
  for (let i = 1; i < portals.length; i++) {
    const pl = portals[i].left;
    const pr = portals[i].right;
    // right side
    if (triarea2(apex, right, pr) <= 0) {
      if (same(apex, right) || triarea2(apex, left, pr) > 0) {
        right = pr;
        rightIndex = i;
      } else {
        path.push(left);
        apex = left;
        apexIndex = leftIndex;
        left = apex;
        right = apex;
        leftIndex = apexIndex;
        rightIndex = apexIndex;
        i = apexIndex;
        continue;
      }
    }
    // left side
    if (triarea2(apex, left, pl) >= 0) {
      if (same(apex, left) || triarea2(apex, right, pl) < 0) {
        left = pl;
        leftIndex = i;
      } else {
        path.push(right);
        apex = right;
        apexIndex = rightIndex;
        left = apex;
        right = apex;
        leftIndex = apexIndex;
        rightIndex = apexIndex;
        i = apexIndex;
        continue;
      }
    }
  }
  const out = [];
  for (const p of path) if (!same(p, start) && (out.length === 0 || !same(out[out.length - 1], p))) out.push(p);
  if (out.length === 0 || !same(out[out.length - 1], goal)) out.push(goal);
  return out;
}

/**
 * The route as PathfindingService hands it out: a waypoint every WaypointSpacing studs along each leg, every turn
 * kept (Locomotion moves on from a waypoint 2.5 studs short of it, so a turn is never cut by more than that).
 * @param {THREE.Vector3} from @param {THREE.Vector3[]} points @returns {THREE.Vector3[]}
 */
export function spaced(from, points, spacing = SPACING) {
  const out = [];
  let a = from;
  for (const b of points) {
    const length = Math.hypot(b.x - a.x, b.z - a.z);
    const steps = Math.floor(length / spacing - 1e-6);
    for (let k = 1; k <= steps; k++) {
      const t = (k * spacing) / length;
      out.push(new THREE.Vector3(a.x + (b.x - a.x) * t, b.y, a.z + (b.z - a.z) * t));
    }
    out.push(b);
    a = b;
  }
  return out;
}

function midpoint(s) {
  return { x: (s.p.x + s.q.x) / 2, y: s.p.y, z: (s.p.z + s.q.z) / 2 };
}

/**
 * The level's pool basins as world rects (world.json basins: `rect` level-local).
 * @param {any} meta @param {string} levelId @param {number[]} origin the level's origin
 * @returns {Array<{minX: number, maxX: number, minZ: number, maxZ: number}>}
 */
function levelBasins(meta, levelId, origin) {
  const out = [];
  for (const b of meta.basins || []) {
    const r = b && b.rect;
    if (!r || b.level !== levelId) continue;
    out.push({ minX: origin[0] + r.x, maxX: origin[0] + r.x + r.w, minZ: origin[2] + r.z, maxZ: origin[2] + r.z + r.d });
  }
  return out;
}

/**
 * The floor of `room` round the pools in it: [room] when no basin lies in it, else the deck strips round each basin
 * (west and east the full depth, north and south between them; one narrower than MIN_DECK is left out), keyed
 * `<key>#W|E|N|S` (see the header).
 * @param {NavRoom} room
 * @param {Array<{minX: number, maxX: number, minZ: number, maxZ: number}>} basins
 * @returns {NavRoom[]}
 */
export function deckParts(room, basins) {
  let parts = [room];
  for (const b of basins) {
    const next = [];
    for (const p of parts) {
      if (!(b.minX < p.maxX - EPS && b.maxX > p.minX + EPS && b.minZ < p.maxZ - EPS && b.maxZ > p.minZ + EPS)) {
        next.push(p);
        continue;
      }
      const x0 = Math.max(p.minX, b.minX);
      const x1 = Math.min(p.maxX, b.maxX);
      const strip = (side, minX, maxX, minZ, maxZ) => {
        if (maxX - minX >= MIN_DECK && maxZ - minZ >= MIN_DECK) next.push({ ...p, key: `${p.key}#${side}`, minX, maxX, minZ, maxZ });
      };
      strip('W', p.minX, x0, p.minZ, p.maxZ);
      strip('E', x1, p.maxX, p.minZ, p.maxZ);
      strip('N', x0, x1, p.minZ, Math.max(p.minZ, b.minZ));
      strip('S', x0, x1, Math.min(p.maxZ, b.maxZ), p.maxZ);
    }
    parts = next;
  }
  return parts;
}

/**
 * The layout's Default-group footprints inside rooms, in world space: platforms whose top is above what the walker
 * steps up and whose underside the agent cannot pass beneath, and the pillars.
 * @param {any} meta world.json @param {string} levelId
 * @param {number} [agentHeight] the head room the agent needs under a platform
 * @returns {Obstacle[]}
 */
export function levelObstacles(meta, levelId, agentHeight = AGENT_HEIGHT) {
  const layout = meta.layouts && meta.layouts[levelId];
  const level = meta.levels && meta.levels[levelId];
  if (!layout || !level) return [];
  const ox = level.origin ? level.origin[0] : 0;
  const oz = level.origin ? level.origin[2] : 0;
  /** @type {Obstacle[]} */
  const out = [];
  for (const p of layout.platforms || []) {
    const r = p.rect;
    if (!r || !(p.top > STEP_UP)) continue;
    const bottom = p.top - (p.thickness ?? p.top);
    if (bottom >= agentHeight) continue;
    out.push({ id: p.id, minX: ox + r.x, maxX: ox + r.x + r.w, minZ: oz + r.z, maxZ: oz + r.z + r.d });
  }
  (layout.pillars || []).forEach((p, i) => {
    const half = (p.size ?? 2) / 2;
    out.push({ id: `Pillar_${i + 1}`, minX: ox + p.x - half, maxX: ox + p.x + half, minZ: oz + p.z - half, maxZ: oz + p.z + half });
  });
  return out;
}

function insideRect(r, x, z) {
  return x > r.minX && x < r.maxX && z > r.minZ && z < r.maxZ;
}

/** Whether the segment (ax, az) -> (bx, bz) runs through the inside of `r` (shrunk by INTERIOR). */
export function crossesRect(r, ax, az, bx, bz) {
  let t0 = 0;
  let t1 = 1;
  const dx = bx - ax;
  const dz = bz - az;
  const lo = [r.minX + INTERIOR, r.minZ + INTERIOR];
  const hi = [r.maxX - INTERIOR, r.maxZ - INTERIOR];
  const o = [ax, az];
  const d = [dx, dz];
  for (let k = 0; k < 2; k++) {
    if (Math.abs(d[k]) < 1e-9) {
      if (o[k] <= lo[k] || o[k] >= hi[k]) return false;
      continue;
    }
    let u = (lo[k] - o[k]) / d[k];
    let v = (hi[k] - o[k]) / d[k];
    if (u > v) [u, v] = [v, u];
    if (u > t0) t0 = u;
    if (v < t1) t1 = v;
    if (t1 - t0 <= 1e-9) return false;
  }
  return true;
}

function blocked(obstacles, ax, az, bx, bz) {
  for (const o of obstacles) if (crossesRect(o, ax, az, bx, bz)) return true;
  return false;
}

/** The parameter along a -> b where it leaves the rectangle of `room` (a inside). */
function exitParameter(room, a, b) {
  let t = Infinity;
  const dx = b.x - a.x;
  const dz = b.z - a.z;
  if (dx > 1e-9) t = Math.min(t, (room.maxX - a.x) / dx);
  else if (dx < -1e-9) t = Math.min(t, (room.minX - a.x) / dx);
  if (dz > 1e-9) t = Math.min(t, (room.maxZ - a.z) / dz);
  else if (dz < -1e-9) t = Math.min(t, (room.minZ - a.z) / dz);
  return t;
}

/**
 * The shortest way from `p` to `q` inside `room` round the footprints: the corners it turns at, in order (null when
 * there is none). Rooms are convex, so a leg between two points kept off its walls never leaves it.
 * @param {NavRoom} room @param {Obstacle[]} obstacles @param {THREE.Vector3} p @param {THREE.Vector3} q
 * @returns {Array<{x: number, z: number}>|null}
 */
export function aroundIn(room, obstacles, p, q) {
  const minX = room.minX + WALL_CLEARANCE;
  const maxX = room.maxX - WALL_CLEARANCE;
  const minZ = room.minZ + WALL_CLEARANCE;
  const maxZ = room.maxZ - WALL_CLEARANCE;
  const near = obstacles.filter((o) => o.maxX > room.minX && o.minX < room.maxX && o.maxZ > room.minZ && o.minZ < room.maxZ);
  /** @type {Array<{x: number, z: number}>} */
  const nodes = [{ x: p.x, z: p.z }, { x: q.x, z: q.z }];
  for (const o of near) {
    for (const [x, z] of [[o.minX, o.minZ], [o.maxX, o.minZ], [o.maxX, o.maxZ], [o.minX, o.maxZ]]) {
      if (x < minX || x > maxX || z < minZ || z > maxZ) continue;
      let buried = false;
      for (const other of near) if (other !== o && insideRect(other, x, z)) buried = true;
      if (!buried) nodes.push({ x, z });
    }
  }
  const n = nodes.length;
  const dist = new Array(n).fill(Infinity);
  const prev = new Array(n).fill(-1);
  const done = new Array(n).fill(false);
  dist[0] = 0;
  for (let iter = 0; iter < n; iter++) {
    let u = -1;
    for (let i = 0; i < n; i++) if (!done[i] && (u < 0 || dist[i] < dist[u])) u = i;
    if (u < 0 || dist[u] === Infinity) break;
    if (u === 1) break;
    done[u] = true;
    for (let v = 0; v < n; v++) {
      if (done[v] || v === u) continue;
      const a = nodes[u];
      const b = nodes[v];
      const d = dist[u] + Math.hypot(b.x - a.x, b.z - a.z);
      if (d >= dist[v] - 1e-9) continue;
      if (blocked(near, a.x, a.z, b.x, b.z)) continue;
      dist[v] = d;
      prev[v] = u;
    }
  }
  if (dist[1] === Infinity) return null;
  const way = [];
  for (let at = 1; at > 0; at = prev[at]) way.unshift(nodes[at]);
  way.pop();
  return way;
}
