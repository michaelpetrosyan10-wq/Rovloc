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

import * as THREE from 'three';
import { STEP_UP } from './body.js';
import { CreatureConfig, WorldDefaults } from './config.js';
import { BinaryHeap } from './util.js';

const PASSABLE = new Set(['Doorway', 'Door', 'Ajar', 'RoofDoor', 'Gate', 'Airlock']);
const SCRIPTED = new Set(['Gate', 'Airlock', 'RoofDoor']);
const EPS = 1e-3;
const RADIUS = CreatureConfig.PathAgent.AgentRadius;
const AGENT_HEIGHT = CreatureConfig.PathAgent.AgentHeight;
const CLEARANCE = RADIUS + 0.25; // a footprint grows by this for the agent
const WALL_CLEARANCE = RADIUS + WorldDefaults.WallThickness / 2; // a detour corner stays this far inside its room
const INTERIOR = 0.01; // footprints shrink by this for the crossing test, so legs along their edges are clear
const MAX_SPLITS = 24;

/** @typedef {{id: string, minX: number, maxX: number, minZ: number, maxZ: number}} Obstacle */

/**
 * @typedef {{id: string, kind: string, minX: number, maxX: number, minZ: number, maxZ: number, floorY: number}} NavRoom
 * @typedef {{id: string, kind: string, a: string, b: string, axis: 'X'|'Z', coord: number, u0: number, u1: number,
 *   mid: THREE.Vector3, scripted: boolean}} Portal
 */

export class FloorNav {
  /**
   * @param {string} levelId
   * @param {any} meta world.json
   * @param {(doorId: string) => boolean} doorOpen whether a fixture door lets the Creature through now
   */
  constructor(levelId, meta, doorOpen) {
    this.levelId = levelId;
    this.doorOpen = doorOpen;
    const world = meta.worldConfig || {};
    const doorWidth = world.DoorWidth ?? WorldDefaults.DoorWidth;
    const airlockWidth = world.AirlockDoorWidth ?? WorldDefaults.AirlockDoorWidth;
    /** @type {NavRoom[]} */
    this.rooms = [];
    /** @type {Map<string, NavRoom>} */
    this.roomById = new Map();
    for (const room of meta.rooms || []) {
      if (room.level !== levelId || room.kind === 'Chase') continue;
      const r = room.rect;
      const nr = { id: room.id, kind: room.kind, minX: r.x, maxX: r.x + r.w, minZ: r.z, maxZ: r.z + r.d, floorY: room.floorY };
      this.rooms.push(nr);
      this.roomById.set(room.id, nr);
    }
    /** @type {Portal[]} */
    this.portals = [];
    /** @type {Map<string, Portal[]>} */
    this.portalsOf = new Map();
    for (const room of this.rooms) this.portalsOf.set(room.id, []);
    // rooms are world rects; a layout door's `at` is level-local (along the shared wall)
    const level = meta.levels && meta.levels[levelId];
    const origin = level && Array.isArray(level.origin) ? level.origin : [0, 0, 0];
    for (const door of meta.layoutDoors || []) {
      if (door.level !== levelId || !PASSABLE.has(door.kind)) continue;
      const a = this.roomById.get(door.rooms[0]);
      const b = this.roomById.get(door.rooms[1]);
      if (!a || !b) continue;
      const edge = sharedEdge(a, b);
      if (!edge) continue;
      const width = door.width ?? (door.kind === 'Airlock' ? airlockWidth : doorWidth);
      const at = door.at + (edge.axis === 'X' ? origin[2] : origin[0]);
      const u0 = Math.max(at - width / 2, edge.from);
      const u1 = Math.min(at + width / 2, edge.to);
      if (u1 - u0 < EPS) continue;
      const um = (u0 + u1) / 2;
      const mid = edge.axis === 'X' ? new THREE.Vector3(edge.coord, a.floorY, um) : new THREE.Vector3(um, a.floorY, edge.coord);
      const portal = {
        id: door.id, kind: door.kind, a: a.id, b: b.id, axis: edge.axis, coord: edge.coord, u0, u1, mid,
        scripted: SCRIPTED.has(door.kind),
      };
      this.portals.push(portal);
      this.portalsOf.get(a.id).push(portal);
      this.portalsOf.get(b.id).push(portal);
    }
    /** @type {Obstacle[]} the layout's in-room footprints, grown by CLEARANCE */
    this.obstacles = levelObstacles(meta, levelId).map((o) => ({
      id: o.id, minX: o.minX - CLEARANCE, maxX: o.maxX + CLEARANCE, minZ: o.minZ - CLEARANCE, maxZ: o.maxZ + CLEARANCE,
    }));
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
    if (start === goal) return { waypoints: this._detour(from, [goalPoint]) };
    const route = this._search(start, goal, from, to);
    if (!route) return null;
    const corridor = [];
    let room = start;
    for (const portal of route) {
      const next = portal.a === room.id ? this.roomById.get(portal.b) : this.roomById.get(portal.a);
      for (const piece of crossing(portal, room)) corridor.push(piece);
      room = next;
    }
    const points = funnel(from, goalPoint, corridor);
    const waypoints = [];
    for (const p of points) waypoints.push(new THREE.Vector3(p.x, p.y, p.z));
    return { waypoints: this._detour(from, waypoints) };
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
    for (const portal of this.portalsOf.get(start.id) || []) {
      if (!this.open(portal)) continue;
      const into = portal.a === start.id ? portal.b : portal.a;
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
      if (node.into === goal.id) {
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

function midpoint(s) {
  return { x: (s.p.x + s.q.x) / 2, y: s.p.y, z: (s.p.z + s.q.z) / 2 };
}

/**
 * The layout's Default-group footprints inside rooms, in world space: platforms whose top is above what the walker
 * steps up and whose underside the agent cannot pass beneath, and the pillars.
 * @param {any} meta world.json @param {string} levelId
 * @returns {Obstacle[]}
 */
export function levelObstacles(meta, levelId) {
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
    if (bottom >= AGENT_HEIGHT) continue;
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
