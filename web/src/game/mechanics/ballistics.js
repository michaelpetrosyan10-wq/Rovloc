// ballistics.js: a thrown chemical flask's flight (Shared/Util/Ballistics), used by the throw, the flight and the
// aim arc, so all three trace the same parabola from the same launch.
//
// Flight: position(t) = origin + velocity t + g t^2 / 2 with g = (0, -Gravity, 0), no drag. A throw leaves from the
// eye plus ReleaseOffset in the throw's frame (right of, below and just ahead of the eye), pulled back toward the eye
// when something solid is in between. Speed GameConfig.FlaskThrowSpeed (x VentTossMultiplier while crawling a duct).
// advance walks the parabola in segments of at most `maxStep` seconds, casting each; the first contact ends it.
// surfaceCrossing finds where a segment crosses the top face of a PoolWater box (a flask landing in the pool shatters
// at its surface).

import * as THREE from 'three';
import { GameConfig } from '../config.js';

export const Gravity = 64;
export const ReleaseOffset = new THREE.Vector3(0.45, -0.3, -0.6);
export const VentTossMultiplier = 0.45;
export const PullBackSkin = 0.15;
export const DefaultStep = 1 / 30;
const MIN_STEP = 1 / 240;
const MAX_SEGMENTS = 4096;

const BLOCKED = new Set(['Hiding', 'Trapped', 'Scripted', 'Grabbed', 'Parachuting']);
const DUCT = new Set(['VentCrawling', 'VentScurrying']);

/**
 * @typedef {{position: THREE.Vector3, normal: THREE.Vector3, fraction: number, kind: 'World'|'Creature'|'Water'}} Hit
 * @typedef {(from: THREE.Vector3, to: THREE.Vector3) => Hit|null} Cast
 */

/** Whether a player in `moveState` may throw (not hidden, trapped, scripted, grabbed or parachuting). */
export function mayThrowIn(moveState) {
  return !BLOCKED.has(moveState);
}

export function inDuct(moveState) {
  return DUCT.has(moveState);
}

export function throwSpeed(moveState) {
  return GameConfig.FlaskThrowSpeed * (inDuct(moveState) ? VentTossMultiplier : 1);
}

/** The throw's frame at `eye`: -Z along `direction`, X to the right, Y up as far as the direction allows. */
export function throwFrame(eye, direction, out = new THREE.Matrix4()) {
  const forward = _f.copy(direction);
  if (forward.lengthSq() < 1e-12) forward.set(0, 0, -1);
  forward.normalize();
  const right = _r.crossVectors(forward, _yAxis);
  if (right.length() < 1e-4) right.set(1, 0, 0);
  else right.normalize();
  const up = _u.crossVectors(right, forward).normalize();
  _b.copy(forward).negate();
  return out.makeBasis(right, up, _b).setPosition(eye);
}

/** Where a throw from `eye` along `direction` leaves the hand (before pullBack). */
export function releasePoint(eye, direction, out = new THREE.Vector3()) {
  return out.copy(ReleaseOffset).applyMatrix4(throwFrame(eye, direction, _m));
}

/** `point` kept on the eye's side of an obstacle at `blockedAt` (PullBackSkin short of it). */
export function pullBack(eye, point, blockedAt, out = new THREE.Vector3()) {
  if (!blockedAt) return out.copy(point);
  const offset = _o.subVectors(point, eye);
  const length = offset.length();
  if (length < 1e-6) return out.copy(eye);
  offset.divideScalar(length);
  const reach = Math.min(length, Math.max(0, _d.subVectors(blockedAt, eye).dot(offset) - PullBackSkin));
  return out.copy(eye).addScaledVector(offset, reach);
}

export function position(origin, velocity, gravity, t, out = new THREE.Vector3()) {
  return out.copy(origin).addScaledVector(velocity, t).add(_g.set(0, -0.5 * gravity * t * t, 0));
}

export function velocityAt(velocity, gravity, t, out = new THREE.Vector3()) {
  return out.copy(velocity).add(_g.set(0, -gravity * t, 0));
}

/**
 * Flies from flight time `fromT` to `toT` (clamped to `maxSeconds`) in segments of at most `maxStep`, casting each.
 * @param {Cast} cast
 * @returns {{hit: Hit|null, t: number, position: THREE.Vector3, expired: boolean}}
 */
export function advance(origin, velocity, gravity, fromT, toT, maxSeconds, maxStep, cast) {
  const finish = Math.min(toT, maxSeconds);
  const step = Math.max(maxStep || DefaultStep, MIN_STEP);
  let t = Math.max(0, fromT);
  let at = position(origin, velocity, gravity, t);
  let segments = 0;
  while (t < finish && segments < MAX_SEGMENTS) {
    segments++;
    const nextT = Math.min(finish, t + step);
    const next = position(origin, velocity, gravity, nextT);
    const hit = cast(at, next);
    if (hit) {
      const fraction = Math.min(1, Math.max(0, hit.fraction));
      return { hit, t: t + (nextT - t) * fraction, position: hit.position.clone(), expired: false };
    }
    t = nextT;
    at = next;
  }
  return { hit: null, t, position: at, expired: t >= maxSeconds - 1e-9 };
}

/** A whole flight from the release: its contact (null when it expires) and the points it passed through. */
export function trace(origin, velocity, gravity, maxSeconds, step, cast) {
  const points = [origin.clone()];
  const stride = Math.max(step, MIN_STEP);
  let t = 0;
  let segments = 0;
  while (t < maxSeconds && segments < MAX_SEGMENTS) {
    segments++;
    const result = advance(origin, velocity, gravity, t, t + stride, maxSeconds, stride, cast);
    points.push(result.position);
    if (result.hit) return { hit: result.hit, points, t: result.t };
    t = result.t;
  }
  return { hit: null, points, t: Math.min(t, maxSeconds) };
}

/** `count` points evenly spaced by length along the polyline (first and last included). */
export function resample(points, count) {
  const out = [];
  if (count <= 0 || !points.length) return out;
  if (points.length === 1 || count === 1) {
    for (let i = 0; i < count; i++) out.push(points[0].clone());
    return out;
  }
  const lengths = [0];
  for (let i = 1; i < points.length; i++) lengths[i] = lengths[i - 1] + points[i].distanceTo(points[i - 1]);
  const total = lengths[points.length - 1];
  let segment = 1;
  for (let k = 0; k < count; k++) {
    const target = (total * k) / (count - 1);
    while (segment < points.length - 1 && lengths[segment] < target) segment++;
    const span = lengths[segment] - lengths[segment - 1];
    const alpha = span > 1e-9 ? (target - lengths[segment - 1]) / span : 1;
    out.push(points[segment - 1].clone().lerp(points[segment], Math.min(1, Math.max(0, alpha))));
  }
  return out;
}

/**
 * Where (0..1 along the segment) from -> to crosses the top face of the box (inverse frame `inv`, `size`) inside its
 * footprint, either way; null when it does not.
 */
export function surfaceCrossing(inv, size, from, to) {
  const a = _a.copy(from).applyMatrix4(inv);
  const b = _c.copy(to).applyMatrix4(inv);
  const top = size[1] * 0.5;
  const da = a.y - top;
  const db = b.y - top;
  if (da * db > 0 || Math.abs(b.y - a.y) < 1e-9) return null;
  const fraction = Math.min(1, Math.max(0, da / (a.y - b.y)));
  const p = a.lerp(b, fraction);
  if (Math.abs(p.x) > size[0] * 0.5 || Math.abs(p.z) > size[2] * 0.5) return null;
  return fraction;
}

const _f = new THREE.Vector3();
const _r = new THREE.Vector3();
const _u = new THREE.Vector3();
const _b = new THREE.Vector3();
const _o = new THREE.Vector3();
const _d = new THREE.Vector3();
const _g = new THREE.Vector3();
const _a = new THREE.Vector3();
const _c = new THREE.Vector3();
const _m = new THREE.Matrix4();
const _yAxis = new THREE.Vector3(0, 1, 0);
