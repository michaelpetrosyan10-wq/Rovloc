// JointMap (Shared/Animation/ProceduralAnimator/JointMap.luau) and IK (IK.luau), built from W1's creature data
// (world.json `creature`: CreatureRigBuilder's rig as bones (part rest frames, model space) and Motor6D joints with
// C0 / C1, every welded detail part with the bone that carries it, and the FaceFrontAttachment).
//
// Joint frames. Roblox poses Part1 = Part0 * C0 * Transform * C1:Inverse(). `rest[part]` is each part's frame in rig
// space (the root part's own frame) with every Transform at identity. Each joint keeps its rest pivot and `axes` (the
// rotation of its joint frame in rig space); toTransform turns a pose entry written in rig axes into the joint-frame
// Transform: Transform = axes^-1 * entry * axes. Ground: -(HipHeight + root height / 2) in rig space.

import * as THREE from 'three';
import { CFrame, IDENTITY } from './cframe.js';

/**
 * @typedef {Object} Joint
 * @property {string} name
 * @property {string} part0Name
 * @property {string} part1Name
 * @property {CFrame} c0
 * @property {CFrame} c1
 * @property {CFrame} c1Inverse
 * @property {CFrame} axes
 * @property {CFrame} axesInverse
 * @property {THREE.Vector3} pivot rest pivot in rig space
 * @property {string|null} parent the joint driving Part0
 * @property {string[]} children
 * @property {number} index
 *
 * @typedef {Object} JointMap
 * @property {string} rootName
 * @property {Record<string, Joint>} joints
 * @property {Joint[]} order parents before children
 * @property {Record<string, THREE.Vector3>} sizes size of the root part and every jointed part
 * @property {Record<string, CFrame>} rest each part's rest frame in rig space
 * @property {Record<string, CFrame>} restRotationInverse
 * @property {Record<string, string>} drivenBy part name -> its joint
 * @property {number} groundY rig-space floor
 * @property {CFrame} rootRestModel the root part's rest frame in model space (floor at the CreatureSpawn point)
 * @property {Array<{bone: string, cframe: CFrame, size: THREE.Vector3}>} details welded detail parts (bone space)
 * @property {Record<string, {parent: string, cframe: CFrame}>} attachments
 */

/**
 * Builds the joint map of the creature rig.
 * @param {any} creature world.json `creature`
 * @returns {JointMap}
 */
export function buildJointMap(creature) {
  const rootName = creature.primaryPart || 'HumanoidRootPart';
  const boneByName = new Map(creature.bones.map((b) => [b.name, b]));
  const rootBone = boneByName.get(rootName);
  if (!rootBone) throw new Error('creature rig has no root part');
  const rootRestModel = CFrame.fromComponents(rootBone.rest);
  /** @type {Record<string, Joint>} */
  const joints = {};
  /** @type {Joint[]} */
  const order = [];
  const rest = { [rootName]: IDENTITY };
  const drivenBy = {};
  const placed = new Set([rootName]);
  const partJoint = {};
  let pending = creature.joints.slice();
  let frontier = [rootName];
  while (frontier.length > 0) {
    const next = [];
    for (const parent of frontier) {
      const remaining = [];
      for (const j of pending) {
        if (j.part0 !== parent) {
          remaining.push(j);
          continue;
        }
        if (placed.has(j.part1) || joints[j.name]) continue;
        const c0 = CFrame.fromComponents(j.c0);
        const c1 = CFrame.fromComponents(j.c1);
        const frame = rest[j.part0].mul(c0);
        const axes = frame.rotation;
        const joint = {
          name: j.name,
          part0Name: j.part0,
          part1Name: j.part1,
          c0,
          c1,
          c1Inverse: c1.inverse(),
          axes,
          axesInverse: axes.inverse(),
          pivot: frame.position,
          parent: partJoint[j.part0] || null,
          children: [],
          index: order.length,
        };
        joints[joint.name] = joint;
        order.push(joint);
        rest[j.part1] = frame.mul(joint.c1Inverse);
        drivenBy[j.part1] = joint.name;
        placed.add(j.part1);
        partJoint[j.part1] = joint.name;
        if (joint.parent) joints[joint.parent].children.push(joint.name);
        next.push(j.part1);
      }
      pending = remaining;
    }
    frontier = next;
  }
  const restRotationInverse = {};
  for (const [name, frame] of Object.entries(rest)) restRotationInverse[name] = frame.rotation.inverse();
  const sizes = {};
  for (const b of creature.bones) sizes[b.name] = new THREE.Vector3(b.size[0], b.size[1], b.size[2]);
  const rootSize = sizes[rootName];
  const hipHeight = creature.hipHeight ?? 3.4;
  const groundY = -(hipHeight + rootSize.y / 2);
  // welded details (every non-jointed part) in the space of the bone carrying them
  const details = [];
  for (const p of creature.parts || []) {
    if (p.name === p.bone || boneByName.has(p.name)) continue;
    const bone = boneByName.get(p.bone);
    if (!bone) continue;
    const boneModel = CFrame.fromComponents(bone.rest);
    details.push({ bone: p.bone, cframe: boneModel.toObjectSpace(CFrame.fromComponents(p.cf)), size: new THREE.Vector3(...p.size) });
  }
  const attachments = {};
  for (const a of creature.attachments || []) attachments[a.name] = { parent: a.parent, cframe: CFrame.fromComponents(a.cframe) };
  return { rootName, joints, order, sizes, rest, restRotationInverse, drivenBy, groundY, rootRestModel, details, attachments };
}

/** Rest pivot of a joint (rig space). */
export function pivot(map, name) {
  const joint = map.joints[name];
  if (!joint) throw new Error(`no joint ${name}`);
  return joint.pivot;
}

/** Distance between two joints' rest pivots. */
export function distance(map, a, b) {
  return pivot(map, b).distanceTo(pivot(map, a));
}

/** The joint-frame Transform for a pose entry written in rig axes. */
export function toTransform(joint, entry) {
  return joint.axesInverse.mul(entry).mul(joint.axes);
}

// ---------------------------------------------------------------------------------------------------------------
// IK (IK.luau): two-bone chains with the law of cosines, bone re-orientation
// ---------------------------------------------------------------------------------------------------------------

const EPSILON = 1e-6;
const REACH_MARGIN = 0.999;
const FOLD_MARGIN = 0.05;

/** Any unit vector perpendicular to `v`. */
export function perpendicular(v) {
  const unit = v.clone().normalize();
  const axis = Math.abs(unit.y) < 0.9 ? new THREE.Vector3(0, 1, 0) : new THREE.Vector3(1, 0, 0);
  return unit.cross(axis).normalize();
}

/** The part of `v` perpendicular to unit `axis`, normalized (fallback when parallel). */
export function orthogonalize(v, axis, fallback) {
  const projected = v.clone().addScaledVector(axis, -v.dot(axis));
  if (projected.length() > 1e-4) return projected.normalize();
  if (fallback) {
    const other = fallback.clone().addScaledVector(axis, -fallback.dot(axis));
    if (other.length() > 1e-4) return other.normalize();
  }
  return perpendicular(axis);
}

/** Two-bone IK: {mid, tip, bend, reached, distance}. */
export function solveTwoBone(origin, target, upper, lower, pole) {
  const maxReach = (upper + lower) * REACH_MARGIN;
  const fold = Math.abs(upper - lower);
  const minReach = Math.max(fold, (upper + lower) * FOLD_MARGIN) * (1 + 1e-3);
  const poleLen = pole.length();
  const fallback = poleLen > EPSILON ? perpendicular(pole) : new THREE.Vector3(0, -1, 0);
  const delta = target.clone().sub(origin);
  let d = delta.length();
  const direction = d > EPSILON ? delta.divideScalar(d) : fallback.clone().normalize();
  const clamped = Math.min(Math.max(d, minReach), maxReach);
  const reached = Math.abs(clamped - d) <= 1e-9;
  const tip = reached ? target.clone() : origin.clone().addScaledVector(direction, clamped);
  d = reached ? Math.max(d, EPSILON) : clamped;
  const bend = orthogonalize(poleLen > EPSILON ? pole.clone().normalize() : fallback, direction);
  const cosine = Math.min(1, Math.max(-1, (upper * upper + d * d - lower * lower) / (2 * upper * d)));
  const sine = Math.sqrt(Math.max(0, 1 - cosine * cosine));
  const mid = origin.clone().addScaledVector(direction, upper * cosine).addScaledVector(bend, upper * sine);
  return { mid, tip, bend, reached, distance: d };
}

/** A rotation whose +Y is `axis` and whose -Z leans toward `hint`. */
export function ikFrame(axis, hint) {
  const y = axis.clone().normalize();
  const front = orthogonalize(hint, y);
  const z = front.clone().negate();
  const x = new THREE.Vector3().crossVectors(y, z);
  return CFrame.fromMatrix(new THREE.Vector3(), x, y, z);
}

/** The rotation turning a bone along `restAxis` (bending toward `restHint`) onto `newAxis` (toward `newHint`). */
export function boneRotation(restAxis, restHint, newAxis, newHint) {
  return ikFrame(newAxis, newHint).mul(ikFrame(restAxis, restHint).inverse());
}

/** The smallest rotation taking direction `from` onto `to`. */
export function aimRotation(from, to) {
  const a = from.clone().normalize();
  const b = to.clone().normalize();
  const cosine = Math.min(1, Math.max(-1, a.dot(b)));
  if (cosine > 1 - 1e-9) return IDENTITY;
  if (cosine < -1 + 1e-9) return CFrame.fromAxisAngle(perpendicular(a), Math.PI);
  return CFrame.fromAxisAngle(new THREE.Vector3().crossVectors(a, b).normalize(), Math.acos(cosine));
}
