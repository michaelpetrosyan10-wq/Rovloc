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

import * as THREE from 'three';
import { CreatureConfig, WorldDefaults } from './config.js';
import { BinaryHeap } from './util.js';

const PASSABLE = new Set(['Doorway', 'Door', 'Ajar', 'RoofDoor', 'Gate', 'Airlock']);
const SCRIPTED = new Set(['Gate', 'Airlock', 'RoofDoor']);
const EPS = 1e-3;
const RADIUS = CreatureConfig.PathAgent.AgentRadius;

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
    for (const door of meta.layoutDoors || []) {
      if (door.level !== levelId || !PASSABLE.has(door.kind)) continue;
      const a = this.roomById.get(door.rooms[0]);
      const b = this.roomById.get(door.rooms[1]);
      if (!a || !b) continue;
      const edge = sharedEdge(a, b);
      if (!edge) continue;
      const width = door.width ?? (door.kind === 'Airlock' ? airlockWidth : doorWidth);
      const u0 = Math.max(door.at - width / 2, edge.from);
      const u1 = Math.min(door.at + width / 2, edge.to);
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
    if (start === goal) return { waypoints: [goalPoint] };
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
    return { waypoints };
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
