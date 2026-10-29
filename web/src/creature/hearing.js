// Hearing (MonsterAIService/Hearing.luau): whether the Creature hears a noise pulse, how strongly, and where it
// believes it came from. Pure rules over an injected wall counter and grate test.
//
// A pulse is heard only on the listener's level and only with a radius above 0. Its reach is radius x
// HearingMultiplier x the difficulty's hearingMultiplier x the pacing's HearingScale, shrunk per route:
//   Air    straight line; each wall between (at most MaxOccludingWalls count) multiplies the reach by WallOcclusion.
//   Water  straight line, no occlusion.
//   Vent, listener in a vent: the rail distance through the ducts x VentPropagationMultiplier (the Air route when
//          the ducts do not connect).
//   Vent, listener outside: the Air route, or a leak out of an open grate near the listener, whichever is stronger.
// Heard when the distance is within the reach; strength = 1 - distance / reach. Critical and High pulses are placed
// exactly; Low and Normal ones are blurred by up to 15% of the listener's distance, seeded by the pulse's time.

import * as THREE from 'three';
import { CreatureConfig, NoiseConfig, difficultySpec } from './config.js';
import { clamp, seededRandom } from './util.js';
import { closestOnSegment, grateOf, neighbours, path as ventPath } from './ventgraph.js';

export const BLUR_FRACTION = 0.15;
const BLUR_KEY = 'HearingBlur';
const PRIORITY_RANK = { Low: 1, Normal: 2, High: 3, Critical: 4 };
const EXACT_RANK = 3;
const ON_DUCT = 1;

/**
 * @typedef {{position: THREE.Vector3, kind: string, radius: number, priority: string, medium: string,
 *   levelId: string|null, ventNodeId: string|null, serverTime: number, sourceUserId: number|null}} NoiseEvent
 * @typedef {{position: THREE.Vector3, levelId: string|null, inVent: boolean, ventNode: string|null,
 *   graph: import('./ventgraph.js').Graph|null, difficulty: string,
 *   occluders: (from: THREE.Vector3, to: THREE.Vector3) => number, grateOpen: (id: string) => boolean,
 *   scale: number}} Listener
 * @typedef {{distance: number, reach: number}} Route
 */

/** Low 1 < Normal 2 < High 3 < Critical 4 (0 for anything else). */
export function priorityRank(priority) {
  return PRIORITY_RANK[priority] || 0;
}

/** The factor every reach is multiplied by. */
export function multiplier(difficulty, scale) {
  const extra = scale !== undefined && scale !== null && Number.isFinite(scale) && scale >= 0 ? scale : 1;
  return CreatureConfig.Senses.HearingMultiplier * difficultySpec(difficulty).hearingMultiplier * extra;
}

/** Reach left after `walls` walls. */
export function occluded(reach, walls) {
  const counted = clamp(Math.floor(walls), 0, NoiseConfig.MaxOccludingWalls);
  return reach * NoiseConfig.WallOcclusion ** counted;
}

/** 1 at the source, falling to 0 at the reach; null out of reach. @param {Route} route */
export function strengthOf(route) {
  if (!(route.reach > 0) || route.distance > route.reach) return null;
  return clamp(1 - route.distance / route.reach, 0, 1);
}

function onPiece(p0, p1, point) {
  const [, closest] = closestOnSegment(p0, p1, point);
  return point.distanceTo(closest) <= ON_DUCT;
}

function sharePiece(graph, nodeId, a, b) {
  const origin = graph.nodes[nodeId].position;
  for (const other of neighbours(graph, nodeId)) {
    const far = graph.nodes[other].position;
    if (onPiece(origin, far, a) && onPiece(origin, far, b)) return true;
  }
  const grate = grateOf(graph, nodeId);
  return !!grate && onPiece(origin, grate.mouth, a) && onPiece(origin, grate.mouth, b);
}

/** Distance along the ducts between two points (each with its nearest node); null when they do not connect. */
export function railDistance(graph, fromPosition, fromNode, toPosition, toNode) {
  const from = graph.nodes[fromNode];
  const to = graph.nodes[toNode];
  if (!from || !to) return null;
  const straight = fromPosition.distanceTo(toPosition);
  const lead = fromPosition.distanceTo(from.position);
  const tail = toPosition.distanceTo(to.position);
  if (fromNode === toNode) return sharePiece(graph, fromNode, fromPosition, toPosition) ? straight : lead + tail;
  const [route, length] = ventPath(graph, fromNode, toNode);
  if (!route) return null;
  if (route.length === 2 && onPiece(from.position, to.position, fromPosition) && onPiece(from.position, to.position, toPosition)) {
    return straight;
  }
  return lead + length + tail;
}

/** `position` moved horizontally by up to BlurFraction x `distance`, seeded by `seed`. */
export function blur(position, distance, seed) {
  if (!(Number.isFinite(distance) && distance > 0)) return position.clone();
  const stableSeed = Number.isFinite(seed) ? Math.floor(seed * 1000) : 0;
  const random = seededRandom(stableSeed, BLUR_KEY);
  const angle = random.nextNumber() * 2 * Math.PI;
  const radius = BLUR_FRACTION * distance * Math.sqrt(random.nextNumber());
  return new THREE.Vector3(position.x + Math.cos(angle) * radius, position.y, position.z + Math.sin(angle) * radius);
}

/** Where the listener believes the pulse came from. @param {NoiseEvent} event */
export function believedPosition(event, listenerPosition) {
  if (priorityRank(event.priority) >= EXACT_RANK) return event.position.clone();
  return blur(event.position, event.position.distanceTo(listenerPosition), event.serverTime);
}

function airRoute(senses, from) {
  const to = senses.listener.position;
  return { distance: from.distanceTo(to), reach: occluded(senses.reach, senses.listener.occluders(from, to)) };
}

function ductRoute(senses, event) {
  const l = senses.listener;
  if (!l.graph || !event.ventNodeId || !l.ventNode) return null;
  const d = railDistance(l.graph, event.position, event.ventNodeId, l.position, l.ventNode);
  if (d === null) return null;
  return { distance: d * NoiseConfig.VentPropagationMultiplier, reach: senses.reach };
}

function leakRoute(senses, event) {
  const l = senses.listener;
  if (!l.graph || !event.ventNodeId) return null;
  let best = null;
  let bestStrength = -1;
  for (const id of l.graph.grateIds) {
    const grate = l.graph.grates[id];
    const outside = grate.mouth.distanceTo(l.position);
    if (outside > senses.reach || !l.grateOpen(id)) continue;
    const inside = railDistance(l.graph, event.position, event.ventNodeId, grate.mouth, grate.nodeId);
    if (inside === null) continue;
    const route = {
      distance: inside * NoiseConfig.VentPropagationMultiplier + outside,
      reach: occluded(senses.reach, l.occluders(grate.mouth, l.position)),
    };
    const strength = strengthOf(route);
    if (strength !== null && strength > bestStrength) {
      best = route;
      bestStrength = strength;
    }
  }
  return best;
}

function bestRoute(senses, event) {
  const l = senses.listener;
  if (event.medium === 'Water') return { distance: event.position.distanceTo(l.position), reach: senses.reach };
  if (event.medium === 'Vent') {
    if (l.inVent) return ductRoute(senses, event) || airRoute(senses, event.position);
    const direct = airRoute(senses, event.position);
    const leak = leakRoute(senses, event);
    if (!leak) return direct;
    const ds = strengthOf(direct);
    const ls = strengthOf(leak);
    if (ls !== null && (ds === null || ls > ds)) return leak;
    return direct;
  }
  return airRoute(senses, event.position);
}

/**
 * Whether `listener` hears `event`: {event, position, strength} or null.
 * @param {NoiseEvent} event @param {Listener} listener
 */
export function perceive(event, listener) {
  if (!(event.radius > 0) || event.levelId !== listener.levelId) return null;
  const senses = { listener, reach: event.radius * multiplier(listener.difficulty, listener.scale) };
  if (event.position.distanceTo(listener.position) > senses.reach) return null;
  const strength = strengthOf(bestRoute(senses, event));
  if (strength === null) return null;
  return { event, position: believedPosition(event, listener.position), strength };
}
