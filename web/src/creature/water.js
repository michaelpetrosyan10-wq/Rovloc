// Pool basins (the pure water helpers of MonsterAIService/Locomotion.luau): a basin's water volume, its deck edges
// and the crossing points where the Creature slips in or climbs out.

import * as THREE from 'three';
import { CFrame } from './cframe.js';
import { ROOT_HEIGHT } from './config.js';
import { closestOnSegment } from './ventgraph.js';
import { clamp, horizontalDistance } from './util.js';

export const SWIM_DEPTH = 2.5; // the root this far under the surface while swimming
const WATER_MARGIN = 1.5; // from the basin walls and floor
const DECK_IN = 2.5; // deck stand point inside the coping
const WATER_IN = 2; // water point inside the coping

/**
 * @typedef {{from: THREE.Vector3, to: THREE.Vector3, outward: THREE.Vector3}} DeckEdge
 * @typedef {{id: string, minX: number, maxX: number, minZ: number, maxZ: number, surfaceY: number, floorY: number,
 *   deckY: number, edges: DeckEdge[], ventExitOnly?: boolean}} Basin  ventExitOnly: no climbing out at the deck
 */

/**
 * Locomotion.makeBasin: a basin in world space from its layout data (`rect` and `room` level-local, water level and
 * depth relative to the deck; the deck is wherever the room reaches past the basin by `minDeck`).
 * @param {string} id
 * @param {THREE.Vector3} origin level origin
 * @param {{x: number, z: number, w: number, d: number}} rect
 * @param {{x: number, z: number, w: number, d: number}} room
 * @param {number} waterLevel
 * @param {number} depth
 * @param {number} [minDeck]
 * @returns {Basin}
 */
export function makeBasin(id, origin, rect, room, waterLevel, depth, minDeck = 3) {
  const minX = origin.x + rect.x;
  const maxX = origin.x + rect.x + rect.w;
  const minZ = origin.z + rect.z;
  const maxZ = origin.z + rect.z + rect.d;
  const deckY = origin.y;
  const inset = 2;
  const edges = [];
  const edge = (from, to, outward) => edges.push({ from, to, outward });
  const V = (x, y, z) => new THREE.Vector3(x, y, z);
  if (rect.x - room.x >= minDeck) edge(V(minX, deckY, minZ + inset), V(minX, deckY, maxZ - inset), V(-1, 0, 0));
  if (room.x + room.w - (rect.x + rect.w) >= minDeck) edge(V(maxX, deckY, minZ + inset), V(maxX, deckY, maxZ - inset), V(1, 0, 0));
  if (rect.z - room.z >= minDeck) edge(V(minX + inset, deckY, minZ), V(maxX - inset, deckY, minZ), V(0, 0, -1));
  if (room.z + room.d - (rect.z + rect.d) >= minDeck) edge(V(minX + inset, deckY, maxZ), V(maxX - inset, deckY, maxZ), V(0, 0, 1));
  return { id, minX, maxX, minZ, maxZ, surfaceY: deckY + waterLevel, floorY: deckY - depth, deckY, edges };
}

/** Is `position` in the basin's water (inside its walls, below the deck, above its floor)? */
export function inWater(basin, position) {
  return position.x >= basin.minX && position.x <= basin.maxX && position.z >= basin.minZ && position.z <= basin.maxZ &&
    position.y < basin.deckY - 0.5 && position.y > basin.floorY - 1;
}

/** `position` moved inside the basin's water: clear of its walls and floor, at least `depth` under the surface. */
export function clampToWater(basin, position, depth = SWIM_DEPTH) {
  const top = basin.surfaceY - depth;
  const bottom = Math.min(basin.floorY + WATER_MARGIN, top);
  return new THREE.Vector3(
    clamp(position.x, basin.minX + WATER_MARGIN, basin.maxX - WATER_MARGIN),
    clamp(position.y, bottom, top),
    clamp(position.z, basin.minZ + WATER_MARGIN, basin.maxZ - WATER_MARGIN),
  );
}

/**
 * The deck crossing nearest `near`: [stand (root CFrame on the deck facing out), water point], or [null, null].
 * @param {Basin} basin @param {THREE.Vector3} near
 * @returns {[CFrame|null, THREE.Vector3|null]}
 */
export function deckCrossing(basin, near) {
  let best = null;
  let bestPoint = null;
  let bestDistance = Infinity;
  for (const edge of basin.edges) {
    const [, point] = closestOnSegment(edge.from, edge.to, new THREE.Vector3(near.x, edge.from.y, near.z));
    const distance = horizontalDistance(point, near);
    if (distance < bestDistance) {
      best = edge;
      bestPoint = point;
      bestDistance = distance;
    }
  }
  if (!best || !bestPoint) return [null, null];
  const outward = best.outward;
  const deck = bestPoint.clone().addScaledVector(outward, DECK_IN);
  const at = new THREE.Vector3(deck.x, deck.y + ROOT_HEIGHT, deck.z);
  const stand = CFrame.lookAt(at, at.clone().add(outward));
  const water = new THREE.Vector3(bestPoint.x, basin.surfaceY - SWIM_DEPTH, bestPoint.z).addScaledVector(outward, -WATER_IN);
  return [stand, water];
}
