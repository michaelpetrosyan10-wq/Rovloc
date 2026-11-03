// Perception: what the Creature sees, and who is looking at it. Pure rules over an injected line test; the service
// builds the Viewer and the Observations and calls scan() once per brain tick.
//
// Eyes. The Creature's eye is its root + the rig's eye height for the PoseMode in the root's own frame, nudged
// EyeForward studs along the facing (inside the root's half depth, so the eye never pokes through a wall the root
// touches). A player's eye is their root + CameraConfig.EyeHeightAboveRoot[MoveState]. Sight runs eye to eye through
// the BVH; walls, lockers, desks and debris block it.
//
// Who can be seen: only a playing player (Alive or Downed). Never: MoveState Hiding; a player in a duct or a crawlway
// (it never goes in after them); an Underwater player unless the Creature swims (PoseMode Swim or AquaticStalk).
// How far (Tunnels §2.2): SightTorch with their torch on, SightLit with it off in a lit pool (the level's probe
// irradiance at their chest above LitIrradiance), SightDark with it off in the dark; crouched x CrouchFactor; times
// the difficulty's sightRangeMultiplier. The view cone is SightHalfAngle (MovingHalfAngle while they move), and anything
// within PeripheralRange (MovingPeripheralRange) is felt whatever the facing; while it looks away (HidingResponse's
// LookAway) the peripheral sense is off. Then the line of sight.
// Score: closeness + InCone + Lit + Target - Downed; ties: nearer, then lower UserId.
//
// The stare (§2.2): stareAngle() is the angle between a player's view centre and the Creature's head; within
// Stare.HalfAngle, within stareRange (LitRange when it stands lit or their torch is on, else DarkRange) and with a clear
// line it counts toward the 1 s that starts a chase.

import * as THREE from 'three';
import { CameraConfig, CreatureConfig, difficultySpec } from './config.js';
import { clamp } from './util.js';
import { pairKey } from './ventgraph.js';

const SENSES = CreatureConfig.Senses;
const STARE = CreatureConfig.Stare;
export const EYE_FORWARD = 0.6;
const SAME_SPOT = 1e-6;

export const ScoreWeights = Object.freeze({ Closeness: 1, InCone: 0.35, Lit: 0.2, Target: 0.5, Downed: -0.25 });

/**
 * @typedef {{player: any, eye: THREE.Vector3, playing: boolean, downed: boolean, moveState: string, torch: boolean,
 *   lit: boolean, moving: boolean, inVent: boolean}} Observation
 * @typedef {{eye: THREE.Vector3, facing: THREE.Vector3, difficulty: string, aquatic: boolean, targetUserId: number|null,
 *   blindPeripheral?: boolean, raycast: (a: THREE.Vector3, b: THREE.Vector3) => boolean}} Viewer
 * @typedef {{player: any, eye: THREE.Vector3, distance: number, inCone: boolean, lit: boolean, score: number}} Sighting
 */

/**
 * The Creature's eye for a root frame and PoseMode.
 * @param {import('./cframe.js').CFrame} rootCFrame
 * @param {string} poseMode
 * @param {Record<string, number>} [eyeHeights] above the root, per PoseMode (creatureMetrics)
 */
export function creatureEyeAt(rootCFrame, poseMode, eyeHeights = CreatureConfig.EyeHeightAboveRoot) {
  const height = eyeHeights[poseMode] ?? eyeHeights.Biped ?? CreatureConfig.EyeHeightAboveRoot.Biped;
  return rootCFrame.point(0, height, -EYE_FORWARD);
}

/** A player's eye point for a root position and MoveState. */
export function playerEyeAt(rootPosition, moveState) {
  const height = CameraConfig.EyeHeightAboveRoot[moveState] ?? CameraConfig.EyeHeightAboveRoot.Standing;
  return new THREE.Vector3(rootPosition.x, rootPosition.y + height, rootPosition.z);
}

/** How far the Creature sees a player: by their torch, the light they stand in and their posture. */
export function sightRange(o, difficulty) {
  let range = o.torch ? SENSES.SightTorch : o.lit ? SENSES.SightLit : SENSES.SightDark;
  if (o.moveState === 'Crouching' || o.moveState === 'DownedCrawling') range *= SENSES.CrouchFactor;
  return range * difficultySpec(difficulty).sightRangeMultiplier;
}

/** The longest sight range on a difficulty (the score's closeness scale). */
export function fullRange(difficulty) {
  return SENSES.SightTorch * difficultySpec(difficulty).sightRangeMultiplier;
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

/** The duct edge whose SegmentId is `segment` (its two end nodes), or null (the EMF's duct adjacency). */
export function segmentNodes(graph, segment) {
  for (const id of graph.ids) {
    for (const other of graph.nodes[id].links) {
      if (graph.segments[pairKey(id, other)] === segment) return [id, other];
    }
  }
  return null;
}

/** Why a player is out of the candidate set (null: still a candidate). @param {Viewer} viewer @param {Observation} o */
export function excluded(viewer, o) {
  if (!o.playing) return 'NotPlaying';
  if (o.moveState === 'Hiding') return 'Hiding';
  if (o.moveState === 'Underwater' && !viewer.aquatic) return 'Underwater';
  if (o.inVent) return 'InVent';
  return null;
}

export function score(distance, range, inCone, lit, isTarget, downed) {
  const closeness = range > 0 ? clamp(1 - distance / range, 0, 1) : 0;
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
  if (distance > sightRange(o, viewer.difficulty)) return null;
  const half = o.moving ? SENSES.MovingHalfAngle : SENSES.SightHalfAngle;
  const peripheral = viewer.blindPeripheral ? 0 : o.moving ? SENSES.MovingPeripheralRange : SENSES.PeripheralRange;
  if (!inViewCone(viewer.eye, viewer.facing, o.eye, half, peripheral)) return null;
  if (!viewer.raycast(viewer.eye, o.eye)) return null;
  const inCone = inViewCone(viewer.eye, viewer.facing, o.eye, half, 0);
  const isTarget = viewer.targetUserId !== null && viewer.targetUserId === o.player.userId;
  const shown = o.torch || o.lit;
  return {
    player: o.player,
    eye: o.eye,
    distance,
    inCone,
    lit: shown,
    score: score(distance, fullRange(viewer.difficulty), inCone, shown, isTarget, o.downed),
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

/** Degrees between a look direction from `eye` and the direction to `head` (180 when degenerate). */
export function stareAngle(eye, look, head) {
  const ox = head.x - eye.x;
  const oy = head.y - eye.y;
  const oz = head.z - eye.z;
  const d = Math.hypot(ox, oy, oz);
  const l = Math.hypot(look.x, look.y, look.z);
  if (d < SAME_SPOT || l < SAME_SPOT) return 180;
  const dot = clamp((look.x * ox + look.y * oy + look.z * oz) / (d * l), -1, 1);
  return (Math.acos(dot) * 180) / Math.PI;
}

/** How far a stare reaches: LitRange when the Creature stands lit or the player's torch is on, else DarkRange. */
export function stareRange(torchOn, creatureLit) {
  return torchOn || creatureLit ? STARE.LitRange : STARE.DarkRange;
}

/**
 * Whether a look counts toward the stare this tick.
 * @param {{eye: THREE.Vector3, look: THREE.Vector3, torch: boolean}} looker
 * @param {THREE.Vector3} head the Creature's head (its eye)
 * @param {boolean} creatureLit
 * @param {(a: THREE.Vector3, b: THREE.Vector3) => boolean} lineClear
 * @param {number} [halfAngle]
 */
export function staring(looker, head, creatureLit, lineClear, halfAngle = STARE.HalfAngle) {
  if (looker.eye.distanceTo(head) > stareRange(looker.torch, creatureLit)) return false;
  if (stareAngle(looker.eye, looker.look, head) > halfAngle) return false;
  return lineClear(looker.eye, head);
}
