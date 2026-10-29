// VentGraph + VentPathfinder (Shared/Vents): one level's duct network as pure data and the routes over it.
//
// The graph comes from world.json's vents.graphs[level] (W1 exports exactly what VentGraph.build reads in Roblox):
// nodes on the duct centreline with their links (two-way), grates with their wall frame (LookVector into the room)
// and mouth (the rail point just inside the room face), grateAtNode, and segments ("<a>|<b>" -> VentShaft
// SegmentId). The rail is every duct edge plus one mouth stub per grate; a RailPoint names where on it a position
// projects (edge points: a < b, t from a; stub points: b = null, a = the grate's node).

import * as THREE from 'three';
import { CFrame } from './cframe.js';
import { BinaryHeap, vec } from './util.js';

const TIE = 1e-9;
const DEGENERATE = 1e-12;

/**
 * @typedef {{id: string, position: THREE.Vector3, links: string[], grateId: string|null}} VentNode
 * @typedef {{id: string, nodeId: string, facingZoneId: string, lockable: boolean, criticalPath: boolean,
 *   wall: CFrame, mouth: THREE.Vector3}} Grate
 * @typedef {{levelId: string, nodes: Record<string, VentNode>, grates: Record<string, Grate>,
 *   grateAtNode: Record<string, string>, segments: Record<string, string>, ids: string[], grateIds: string[],
 *   adjacency: Record<string, string[]>}} Graph
 * @typedef {{a: string, b: string|null, t: number, position: THREE.Vector3, distance: number}} RailPoint
 */

/**
 * Builds a Graph from the exported data (nil-safe: null for a level without ducts).
 * @param {any} raw world.json vents.graphs[level]
 * @param {string} levelId
 * @returns {Graph|null}
 */
export function buildGraph(raw, levelId) {
  if (!raw || !raw.nodes) return null;
  /** @type {Record<string, VentNode>} */
  const nodes = {};
  for (const [id, n] of Object.entries(raw.nodes)) {
    nodes[id] = { id, position: vec(n.position), links: [...(n.links || [])], grateId: null };
  }
  const ids = Object.keys(nodes).sort();
  if (ids.length === 0) return null;
  // every link two-way (VentGraph.build)
  for (const id of ids) {
    nodes[id].links = nodes[id].links.filter((other) => other !== id && nodes[other]);
  }
  for (const id of ids) {
    for (const other of nodes[id].links) if (!nodes[other].links.includes(id)) nodes[other].links.push(id);
  }
  /** @type {Record<string, Grate>} */
  const grates = {};
  const grateAtNode = {};
  for (const [id, g] of Object.entries(raw.grates || {})) {
    if (!nodes[g.nodeId] || grateAtNode[g.nodeId]) continue;
    grates[id] = {
      id,
      nodeId: g.nodeId,
      facingZoneId: g.facingZoneId || '',
      lockable: !!g.lockable,
      criticalPath: !!g.criticalPath,
      wall: CFrame.fromComponents(g.wall),
      mouth: vec(g.mouth),
    };
    grateAtNode[g.nodeId] = id;
    nodes[g.nodeId].grateId = id;
  }
  const graph = {
    levelId,
    nodes,
    grates,
    grateAtNode,
    segments: { ...(raw.segments || {}) },
    ids,
    grateIds: Object.keys(grates).sort(),
    adjacency: {},
  };
  graph.adjacency = adjacency(graph);
  return graph;
}

/** The key `segments` uses for the ordered pair (a, b). */
export function pairKey(a, b) {
  return `${a}|${b || ''}`;
}

/** The point of segment p0 -> p1 nearest q: [t, point]. */
export function closestOnSegment(p0, p1, q) {
  const dx = p1.x - p0.x;
  const dy = p1.y - p0.y;
  const dz = p1.z - p0.z;
  const lengthSquared = dx * dx + dy * dy + dz * dz;
  if (lengthSquared < DEGENERATE) return [0, p0.clone()];
  let t = ((q.x - p0.x) * dx + (q.y - p0.y) * dy + (q.z - p0.z) * dz) / lengthSquared;
  t = t < 0 ? 0 : t > 1 ? 1 : t;
  return [t, new THREE.Vector3(p0.x + dx * t, p0.y + dy * t, p0.z + dz * t)];
}

function linked(graph, a, b) {
  const na = graph.nodes[a];
  const nb = graph.nodes[b];
  if (!na || !nb || a === b) return false;
  return na.links.includes(b) || nb.links.includes(a);
}

/** The VentShaft SegmentId of the duct between linked nodes (either order), or null. */
export function segmentId(graph, a, b) {
  return graph.segments[pairKey(a, b)] || null;
}

/** Straight-line length of the duct a-b; Infinity when they are not linked. */
export function edgeLength(graph, a, b) {
  if (!linked(graph, a, b)) return Infinity;
  return graph.nodes[a].position.distanceTo(graph.nodes[b].position);
}

/**
 * The closest point on any duct edge or mouth stub to `position` (null beyond `maxDistance`).
 * @param {Graph} graph @param {THREE.Vector3} position @param {number} [maxDistance]
 * @returns {RailPoint|null}
 */
export function nearest(graph, position, maxDistance) {
  /** @type {RailPoint|null} */
  let best = null;
  let bestKey = '';
  const consider = (a, b, from, to) => {
    const [t, point] = closestOnSegment(from, to, position);
    const distance = position.distanceTo(point);
    const key = pairKey(a, b);
    if (best === null || distance < best.distance - TIE || (distance <= best.distance + TIE && key < bestKey)) {
      best = { a, b, t, position: point, distance };
      bestKey = key;
    }
  };
  const nodes = graph.nodes;
  for (const id of graph.ids) {
    const node = nodes[id];
    for (const other of node.links) {
      const otherNode = nodes[other];
      if (!otherNode || other === id) continue;
      if (id > other && otherNode.links.includes(id)) continue;
      if (id < other) consider(id, other, node.position, otherNode.position);
      else consider(other, id, otherNode.position, node.position);
    }
  }
  for (const gid of graph.grateIds) {
    const grate = graph.grates[gid];
    const node = nodes[grate.nodeId];
    if (node) consider(grate.nodeId, null, node.position, grate.mouth);
  }
  const found = /** @type {RailPoint|null} */ (best);
  if (found && maxDistance !== undefined && found.distance > maxDistance) return null;
  return found;
}

/** The nodes `nodeId` is linked to. */
export function neighbours(graph, nodeId) {
  return graph.adjacency[nodeId] ? [...graph.adjacency[nodeId]] : [];
}

/** The node nearest `position` (ties: the smaller id), or null. */
export function nearestNode(graph, position) {
  let bestId = null;
  let bestDistance = Infinity;
  for (const id of graph.ids) {
    const d = graph.nodes[id].position.distanceTo(position);
    if (bestId === null || d < bestDistance - TIE || (d <= bestDistance + TIE && id < bestId)) {
      bestId = id;
      bestDistance = d;
    }
  }
  return bestId;
}

/** The grate whose mouth stub starts at `nodeId`, if any. */
export function grateOf(graph, nodeId) {
  const id = graph.grateAtNode[nodeId];
  return id ? graph.grates[id] : null;
}

/** VentPathfinder.adjacency: two-way, fixed order (sorted ids, then link order). */
function adjacency(graph) {
  const out = {};
  for (const id of graph.ids) out[id] = [];
  for (const id of graph.ids) {
    for (const other of graph.nodes[id].links) {
      if (other === id || !out[other]) continue;
      if (!out[id].includes(other)) out[id].push(other);
      if (!out[other].includes(id)) out[other].push(id);
    }
  }
  return out;
}

/**
 * VentPathfinder.path: A* over the ducts. [nodes from..to, length] or [null, Infinity].
 * @param {Graph} graph @param {string} from @param {string} to @param {Record<string, boolean>} [blocked]
 * @returns {[string[]|null, number]}
 */
export function path(graph, from, to, blocked) {
  const nodes = graph.nodes;
  const goal = nodes[to];
  if (!nodes[from] || !goal) return [null, Infinity];
  if (from === to) return [[from], 0];
  if (blocked && blocked[to]) return [null, Infinity];
  const cost = { [from]: 0 };
  const cameFrom = {};
  const closed = {};
  const open = new BinaryHeap();
  open.push(from, nodes[from].position.distanceTo(goal.position));
  while (open.size() > 0) {
    const current = open.pop();
    if (current === undefined) break;
    if (closed[current]) continue;
    if (current === to) {
      const route = [to];
      let cursor = to;
      while (cursor !== from) {
        cursor = cameFrom[cursor];
        route.unshift(cursor);
      }
      return [route, cost[to]];
    }
    closed[current] = true;
    const here = cost[current];
    for (const next of graph.adjacency[current]) {
      if (closed[next] || (blocked && blocked[next])) continue;
      const through = here + nodes[current].position.distanceTo(nodes[next].position);
      const known = cost[next];
      if (known === undefined || through < known - TIE) {
        cost[next] = through;
        cameFrom[next] = current;
        open.push(next, through + nodes[next].position.distanceTo(goal.position));
      }
    }
  }
  return [null, Infinity];
}

/** VentPathfinder.leadsAway. */
export function leadsAway(from, to, awayFrom) {
  const toAway = to.distanceTo(awayFrom);
  const fromAway = from.distanceTo(awayFrom);
  const dot = (to.x - from.x) * (from.x - awayFrom.x) + (to.y - from.y) * (from.y - awayFrom.y) +
    (to.z - from.z) * (from.z - awayFrom.z);
  return toAway > fromAway && dot >= 0;
}

/**
 * VentPathfinder.retreatPath: the walk of up to `hops` edges from `from` ending farthest from `awayFrom`, every step
 * leading away.
 * @returns {string[]}
 */
export function retreatPath(graph, from, awayFrom, hops) {
  const nodes = graph.nodes;
  if (!nodes[from]) return [];
  const limit = Number.isFinite(hops) && hops > 0 ? Math.floor(hops) : 0;
  const away = {};
  for (const id of graph.ids) away[id] = nodes[id].position.distanceTo(awayFrom);
  const parent = {};
  const reached = { [from]: true };
  let best = from;
  let bestDistance = away[from];
  let frontier = [from];
  for (let i = 0; i < limit; i++) {
    const nextFrontier = [];
    for (const id of frontier) {
      for (const other of graph.adjacency[id]) {
        if (reached[other] || !leadsAway(nodes[id].position, nodes[other].position, awayFrom)) continue;
        reached[other] = true;
        parent[other] = id;
        nextFrontier.push(other);
        if (away[other] > bestDistance + TIE) {
          best = other;
          bestDistance = away[other];
        }
      }
    }
    if (nextFrontier.length === 0) break;
    frontier = nextFrontier;
  }
  const walk = [best];
  let cursor = best;
  while (cursor !== from) {
    cursor = parent[cursor];
    walk.unshift(cursor);
  }
  return walk;
}

/**
 * ZoneGraph.adjacentZones: the non-Chase rooms whose walls the duct a-b runs inside (EMF from a Creature in a wall
 * vent next to a room).
 * @param {Array<{id: string, kind: string, rect: {x: number, z: number, w: number, d: number}}>} rooms the level's rooms
 * @param {THREE.Vector3} a @param {THREE.Vector3} b node positions (school levels: level-local X / Z = world)
 * @param {{VentBore: number, VentShell: number}} world
 * @returns {string[]}
 */
export function adjacentZones(rooms, a, b, world) {
  const EPS = 1e-3;
  const ADJACENT_RANGE = 1;
  const DUCT_HALF_OUTER = world.VentBore / 2 + world.VentShell;
  const overlap = (a0, a1, b0, b1) => Math.min(a1, b1) - Math.max(a0, b0);
  const gap = (a0, a1, b0, b1) => Math.max(0, b0 - a1, a0 - b1);
  const besideRect = (room, chase, range) => {
    const ox = overlap(room.x, room.x + room.w, chase.x, chase.x + chase.w);
    const oz = overlap(room.z, room.z + room.d, chase.z, chase.z + chase.d);
    const gx = gap(room.x, room.x + room.w, chase.x, chase.x + chase.w);
    const gz = gap(room.z, room.z + room.d, chase.z, chase.z + chase.d);
    return (oz > EPS && gx <= range + EPS) || (ox > EPS && gz <= range + EPS);
  };
  const x0 = Math.min(a.x, b.x);
  const x1 = Math.max(a.x, b.x);
  const z0 = Math.min(a.z, b.z);
  const z1 = Math.max(a.z, b.z);
  const besideSpan = (room, chase, reach) => {
    if (chase.w >= chase.d - EPS && overlap(room.x, room.x + room.w, x0 - reach, x1 + reach) <= EPS) return false;
    if (chase.d >= chase.w - EPS && overlap(room.z, room.z + room.d, z0 - reach, z1 + reach) <= EPS) return false;
    return true;
  };
  const segmentInside = (rect) => {
    const ox = overlap(x0, x1, rect.x, rect.x + rect.w);
    const oz = overlap(z0, z1, rect.z, rect.z + rect.d);
    if (ox < -EPS || oz < -EPS) return false;
    const sx = x1 - x0;
    const sz = z1 - z0;
    if (sx <= EPS && sz <= EPS) return true;
    return sx >= sz ? ox > EPS : oz > EPS;
  };
  const chases = rooms.filter((r) => r.kind === 'Chase' && segmentInside(r.rect)).map((r) => r.rect);
  const reach = DUCT_HALF_OUTER + ADJACENT_RANGE;
  const out = [];
  for (const room of rooms) {
    if (room.kind === 'Chase') continue;
    let near = false;
    if (chases.length > 0) {
      near = chases.some((chase) => besideRect(room.rect, chase, ADJACENT_RANGE) && besideSpan(room.rect, chase, reach));
    } else {
      const r = room.rect;
      near = gap(r.x, r.x + r.w, x0, x1) <= ADJACENT_RANGE + EPS && gap(r.z, r.z + r.d, z0, z1) <= ADJACENT_RANGE + EPS;
    }
    if (near) out.push(room.id);
  }
  return out;
}
