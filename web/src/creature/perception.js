// Perception (MonsterAIService/Perception.luau): what the Creature sees. Pure rules over an injected line test; the
// service builds the Viewer and the Observations and calls scan() once per brain tick.
//
// Eyes. The Creature's eye is its root + EyeHeightAboveRoot[PoseMode] in the root's own frame, nudged EyeForward studs
// along the facing (inside the root's half depth, so the eye never pokes through a wall the root touches). A player's
// eye is their root + CameraConfig.EyeHeightAboveRoot[MoveState]. Sight runs eye to eye; walls, lockers, desks and
// debris block it.
// Who can be seen: only a playing player (Alive or Downed). Never: MoveState Hiding; a player in a vent unless the
// Creature is in a vent too on the same duct edge or one sharing a node with it; an Underwater player unless the
// Creature swims (PoseMode Swim or AquaticStalk). Then range (SightRange x sightRangeMultiplier with a lit flashlight,
// x DarknessSightMultiplier in the dark), the view cone (SightHalfAngle, or anything within PeripheralRange), then
// the line of sight.
// Score: closeness + InCone + Lit + Target - Downed; ties: nearer, then lower UserId.

import * as THREE from 'three';
import { CameraConfig, CreatureConfig, difficultySpec } from './config.js';
import { clamp } from './util.js';
import { nearest, pairKey } from './ventgraph.js';

const SENSES = CreatureConfig.Senses;
export const EYE_FORWARD = 0.6;
const SAME_SPOT = 1e-6;
const RAIL_SNAP = 4;

export const ScoreWeights = Object.freeze({ Closeness: 1, InCone: 0.35, Lit: 0.2, Target: 0.5, Downed: -0.25 });

/**
 * @typedef {{player: any, eye: THREE.Vector3, playing: boolean, downed: boolean, moveState: string, lit: boolean,
 *   inVent: boolean, rail: import('./ventgraph.js').RailPoint|null}} Observation
 * @typedef {{eye: THREE.Vector3, facing: THREE.Vector3, difficulty: string, inVent: boolean, ventNodes: string[]|null,
 *   aquatic: boolean, targetUserId: number|null, raycast: (a: THREE.Vector3, b: THREE.Vector3) => boolean}} Viewer
 * @typedef {{player: any, eye: THREE.Vector3, distance: number, inCone: boolean, lit: boolean, score: number}} Sighting
 */

/** The Creature's eye for a root frame and PoseMode. @param {import('./cframe.js').CFrame} rootCFrame */
export function creatureEyeAt(rootCFrame, poseMode) {
  const height = CreatureConfig.EyeHeightAboveRoot[poseMode] ?? CreatureConfig.EyeHeightAboveRoot.Biped;
  return rootCFrame.point(0, height, -EYE_FORWARD);
}

/** A player's eye point for a root position and MoveState. */
export function playerEyeAt(rootPosition, moveState) {
  const height = CameraConfig.EyeHeightAboveRoot[moveState] ?? CameraConfig.EyeHeightAboveRoot.Standing;
  return new THREE.Vector3(rootPosition.x, rootPosition.y + height, rootPosition.z);
}

/** How far the Creature sees a player (lit: full range; dark: DarknessSightMultiplier of it). */
export function visibleRange(lit, difficulty) {
  const range = SENSES.SightRange * difficultySpec(difficulty).sightRangeMultiplier;
  return lit ? range : range * SENSES.DarknessSightMultiplier;
}

/** Inside the cone of `halfAngleDeg` around `facing`, or within `peripheral` of the eye. */
export function inViewCone(eye, facing, target, halfAngleDeg, peripheral) {
  const ox = target.x - eye.x;
  const oy = target.y - eye.y;
  const oz = target.z - eye.z;
  const distance = Math.hypot(ox, oy, oz);
  if (distance <= peripheral || distance < SAME_SPOT) return true;
  const fl = Math.hypot(facing.x, facing.y, facing.z);
  if (fl < SAME_SPOT) return false;
  const dot = (facing.x * ox + facing.y * oy + facing.z * oz) / (fl * distance);
  return dot >= Math.cos((halfAngleDeg * Math.PI) / 180) - 1e-9;
}

/** The duct edge whose SegmentId is `segment` (its two end nodes), or null. */
export function segmentNodes(graph, segment) {
  for (const id of graph.ids) {
    for (const other of graph.nodes[id].links) {
      if (graph.segments[pairKey(id, other)] === segment) return [id, other];
    }
  }
  return null;
}

/** The nodes of the duct piece under `position` (an edge's two ends, a stub's one node), null off the rail. */
export function railNodes(graph, position) {
  const rail = nearest(graph, position, RAIL_SNAP);
  if (!rail) return null;
  return rail.b ? [rail.a, rail.b] : [rail.a];
}

/** Same or adjacent duct: the player's rail piece shares a node with the Creature's edge. */
export function ventsAdjacent(creatureNodes, rail) {
  if (creatureNodes.includes(rail.a)) return true;
  return rail.b !== null && creatureNodes.includes(rail.b);
}

/** Why a player is out of the candidate set (null: still a candidate). @param {Viewer} viewer @param {Observation} o */
export function excluded(viewer, o) {
  if (!o.playing) return 'NotPlaying';
  if (o.moveState === 'Hiding') return 'Hiding';
  if (o.moveState === 'Underwater' && !viewer.aquatic) return 'Underwater';
  if (o.inVent) {
    const nodes = viewer.ventNodes;
    if (!viewer.inVent || !nodes || !o.rail || !ventsAdjacent(nodes, o.rail)) return 'InVent';
  }
  return null;
}

export function score(distance, fullRange, inCone, lit, isTarget, downed) {
  const closeness = fullRange > 0 ? clamp(1 - distance / fullRange, 0, 1) : 0;
  let s = closeness * ScoreWeights.Closeness;
  if (inCone) s += ScoreWeights.InCone;
  if (lit) s += ScoreWeights.Lit;
  if (isTarget) s += ScoreWeights.Target;
  if (downed) s += ScoreWeights.Downed;
  return s;
}

/** The Sighting of one player, or null (the line test runs last). @param {Viewer} viewer @param {Observation} o */
export function judge(viewer, o) {
  if (excluded(viewer, o) !== null) return null;
  const distance = o.eye.distanceTo(viewer.eye);
  if (distance > visibleRange(o.lit, viewer.difficulty)) return null;
  if (!inViewCone(viewer.eye, viewer.facing, o.eye, SENSES.SightHalfAngle, SENSES.PeripheralRange)) return null;
  if (!viewer.raycast(viewer.eye, o.eye)) return null;
  const inCone = inViewCone(viewer.eye, viewer.facing, o.eye, SENSES.SightHalfAngle, 0);
  const isTarget = viewer.targetUserId !== null && viewer.targetUserId === o.player.userId;
  return {
    player: o.player,
    eye: o.eye,
    distance,
    inCone,
    lit: o.lit,
    score: score(distance, visibleRange(true, viewer.difficulty), inCone, o.lit, isTarget, o.downed),
  };
}

/** Sorts sightings best first, in place. @param {Sighting[]} sightings */
export function rank(sightings) {
  sightings.sort((a, b) => {
    if (a.score !== b.score) return b.score - a.score;
    if (a.distance !== b.distance) return a.distance - b.distance;
    return a.player.userId - b.player.userId;
  });
  return sightings;
}

/** Every observed player the viewer can see, best first. @param {Viewer} viewer @param {Observation[]} observations */
export function scan(viewer, observations) {
  const out = [];
  for (const o of observations) {
    const s = judge(viewer, o);
    if (s) out.push(s);
  }
  return rank(out);
}
