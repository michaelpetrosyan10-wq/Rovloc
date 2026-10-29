// Brain (MonsterAIService/Brain.luau): the pure core of the Creature's mind, shared by the service and its states.
//
//   * decide(summary): the transition table. Priorities, highest first: Scripted > Stunned > Dormant (its level is
//     not awake yet) > hold still while a catch plays > a stun just ended: Patrol (withdraw) > no hunting allowed
//     (catch cooldown, airlock grace, Relax): Patrol, withdrawing from a chase > a chase that ran too long: Patrol
//     (withdraw) > a crawler gave itself away: VentChase > VentChase continues until done, then WallChase if someone
//     is in sight, else InvestigateNoise > someone in sight: WallChase (VentChase when both are in the ducts) > a
//     swimmer on the pool level: AquaticStalk > a lost chase follows the last known position for MemorySeconds, then
//     searches > AquaticStalk ends when the water is calm > a noise at least as loud as the one being investigated:
//     InvestigateNoise > an investigation that found nothing: Patrol.
//   * catchKind(check): whether a catch may happen now and which jumpscare (Hallway on floors, Vent in ducts).
//   * levelInfo(levelId, meta): patrol loops (PatrolWaypoint anchors "<prefix>_WP_<loop>_<NN>", walked in order, the
//     last back to the first), rooms and the open doorways between them, pool basins and the CreatureSpawn.

import * as THREE from 'three';
import { CFrame } from './cframe.js';
import { CreatureConfig, difficultySpec } from './config.js';
import { makeBasin } from './water.js';

const SENSES = CreatureConfig.Senses;
const CATCH_VERTICAL = 5;
const WAYPOINT_PATTERN = /_WP_(.+)_(\d+)$/;
const PASSABLE_DOORS = new Set(['Doorway', 'Door', 'Ajar']);
const CHASES = new Set(['WallChase', 'VentChase']);

export const MemorySeconds = SENSES.MemorySeconds;
export const CatchVertical = CATCH_VERTICAL;

/**
 * @typedef {Object} Summary
 * @property {string} state
 * @property {number} elapsed
 * @property {boolean} scripted
 * @property {boolean} stunned
 * @property {boolean} awake
 * @property {boolean} catching
 * @property {boolean} canHunt
 * @property {boolean} inVent
 * @property {boolean} sees
 * @property {boolean} seesInVent
 * @property {boolean} ventQuarry
 * @property {number} heard
 * @property {number} investigating
 * @property {number|null} memoryAge
 * @property {boolean} breakChase
 * @property {boolean} swimmer
 * @property {boolean} stateDone
 *
 * @typedef {{state: string, reason: string, reposition: boolean}} Decision
 *
 * @typedef {{id: string, loop: string, order: number, position: THREE.Vector3, zoneId: string}} Waypoint
 * @typedef {{id: string, waypoints: Waypoint[], zones: Set<string>, centre: THREE.Vector3}} Loop
 * @typedef {{id: string, kind: string, minX: number, maxX: number, minZ: number, maxZ: number, floorY: number,
 *   height: number, centre: THREE.Vector3}} Room
 * @typedef {{levelId: string, origin: THREE.Vector3, loops: Loop[], waypoints: Waypoint[], rooms: Record<string, Room>,
 *   roomList: Room[], neighbours: Record<string, string[]>, basins: import('./water.js').Basin[], spawn: CFrame|null}} LevelInfo
 *
 * @typedef {{position: THREE.Vector3, rank: number, priority: string, medium: string, kind: string,
 *   sourceUserId: number|null, zoneId: string|null, strength: number, at: number}} HeardNoise
 */

export function isChase(state) {
  return CHASES.has(state);
}

function go(state, reason, reposition = false) {
  return { state, reason, reposition: reposition === true };
}

/** @param {Summary} s @returns {Decision} */
export function decide(s) {
  const state = s.state;
  if (s.scripted) return go('Scripted', 'scripted');
  if (s.stunned) return go('Stunned', 'stunned');
  if (!s.awake) return go('Dormant', 'asleep');
  if (s.catching) return go(s.state, 'catching');
  if (state === 'Stunned') return go('Patrol', 'recovered', true);
  if (!s.canHunt) return go('Patrol', 'breather', CHASES.has(state));
  if (CHASES.has(state) && s.breakChase) return go('Patrol', 'chase ran too long', true);
  if (s.ventQuarry && state !== 'VentChase') return go('VentChase', 'crawler');
  if (state === 'VentChase') {
    if (!s.stateDone) return go('VentChase', 'crawling');
    if (s.sees && !s.seesInVent) return go('WallChase', 'out of the ducts');
    return go('InvestigateNoise', 'lost in the ducts');
  }
  if (s.sees) {
    if (s.seesInVent) return go('VentChase', 'seen in the ducts');
    return go('WallChase', 'seen');
  }
  if (s.swimmer) return go('AquaticStalk', 'swimmer');
  if (state === 'WallChase') {
    const age = s.memoryAge;
    if (age !== null && age <= SENSES.MemorySeconds && !s.stateDone) return go('WallChase', 'tracking');
    return go('InvestigateNoise', 'lost sight');
  }
  if (state === 'AquaticStalk') return go('Patrol', 'water calm');
  if (s.heard > 0 && (state !== 'InvestigateNoise' || s.heard >= s.investigating)) return go('InvestigateNoise', 'heard');
  if (state === 'InvestigateNoise') {
    if (s.stateDone) return go('Patrol', 'nothing found');
    return go('InvestigateNoise', 'searching');
  }
  return go('Patrol', 'patrolling');
}

/**
 * @param {{horizontal: number, vertical: number, distance: number, creatureInVent: boolean, targetInVent: boolean,
 *   lineClear: boolean, playing: boolean, hiding: boolean, canHunt: boolean, busy: boolean, hidden: boolean,
 *   stunned: boolean}} check
 * @returns {string|null} JumpscareKind
 */
export function catchKind(check) {
  if (check.busy || !check.canHunt || check.hidden || check.stunned) return null;
  if (!check.playing || check.hiding || !check.lineClear) return null;
  if (check.creatureInVent !== check.targetInVent) return null;
  if (check.creatureInVent) return check.distance <= SENSES.VentCatchDistance ? 'Vent' : null;
  if (check.horizontal <= SENSES.CatchDistance && check.vertical <= CATCH_VERTICAL) return 'Hallway';
  return null;
}

/** The speed of a state on a difficulty (Scripted moves at its own pace). */
export function speedFor(state, difficulty) {
  const base = CreatureConfig.Speeds[state] ?? CreatureConfig.Speeds.Patrol;
  if (state === 'Scripted') return base;
  return base * difficultySpec(difficulty).creatureSpeedMultiplier;
}

/**
 * Patrol loops from PatrolWaypoint anchors, each loop's waypoints in walking order, loops by id.
 * @param {any[]} anchors world.json anchors of one level
 * @returns {Loop[]}
 */
export function patrolLoops(anchors) {
  /** @type {Map<string, Waypoint[]>} */
  const byLoop = new Map();
  for (const anchor of anchors) {
    if (anchor.kind !== 'PatrolWaypoint') continue;
    const match = WAYPOINT_PATTERN.exec(anchor.id);
    const number = match ? Number(match[2]) : NaN;
    if (!match || !Number.isFinite(number)) continue;
    const loop = match[1];
    if (!byLoop.has(loop)) byLoop.set(loop, []);
    const c = anchor.cframe;
    byLoop.get(loop).push({
      id: anchor.id, loop, order: number, position: new THREE.Vector3(c[0], c[1], c[2]), zoneId: anchor.room || '',
    });
  }
  /** @type {Loop[]} */
  const loops = [];
  for (const [id, list] of byLoop) {
    list.sort((a, b) => a.order - b.order);
    const zones = new Set();
    const sum = new THREE.Vector3();
    for (const w of list) {
      zones.add(w.zoneId);
      sum.add(w.position);
    }
    loops.push({ id, waypoints: list, zones, centre: sum.divideScalar(list.length) });
  }
  loops.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return loops;
}

/**
 * What the Creature knows about a level from its blueprint.
 * @param {string} levelId
 * @param {any} meta world.json
 * @returns {LevelInfo|null}
 */
export function levelInfo(levelId, meta) {
  const level = meta.levels && meta.levels[levelId];
  if (!level || !/^Level\d/.test(levelId)) return null;
  const origin = new THREE.Vector3(level.origin[0], level.origin[1], level.origin[2]);
  const anchors = (meta.anchors || []).filter((a) => a.level === levelId);
  const loops = patrolLoops(anchors);
  const waypoints = [];
  for (const loop of loops) for (const w of loop.waypoints) waypoints.push(w);
  /** @type {Record<string, Room>} */
  const rooms = {};
  /** @type {Room[]} */
  const roomList = [];
  const roomRects = {};
  for (const room of meta.rooms || []) {
    if (room.level !== levelId) continue;
    const r = room.rect;
    const entry = {
      id: room.id,
      kind: room.kind,
      minX: r.x,
      maxX: r.x + r.w,
      minZ: r.z,
      maxZ: r.z + r.d,
      floorY: room.floorY,
      height: room.height ?? level.height ?? 14,
      centre: new THREE.Vector3(r.x + r.w / 2, room.floorY, r.z + r.d / 2),
    };
    rooms[room.id] = entry;
    roomRects[room.id] = { x: r.x - origin.x, z: r.z - origin.z, w: r.w, d: r.d };
    roomList.push(entry);
  }
  /** @type {Record<string, string[]>} */
  const neighbours = {};
  for (const door of meta.layoutDoors || []) {
    if (door.level !== levelId || !PASSABLE_DOORS.has(door.kind)) continue;
    const [a, b] = door.rooms;
    if (!rooms[a] || !rooms[b]) continue;
    for (const [x, y] of [[a, b], [b, a]]) {
      if (!neighbours[x]) neighbours[x] = [];
      if (!neighbours[x].includes(y)) neighbours[x].push(y);
    }
  }
  const basins = [];
  for (const basin of meta.basins || []) {
    if (basin.level !== levelId) continue;
    const room = roomRects[basin.room] || basin.rect;
    basins.push(makeBasin(basin.id, origin, basin.rect, room, basin.waterLevel, basin.depth));
  }
  let spawn = null;
  for (const anchor of anchors) {
    if (anchor.kind === 'CreatureSpawn') {
      spawn = CFrame.fromComponents(anchor.cframe);
      break;
    }
  }
  return { levelId, origin, loops, waypoints, rooms, roomList, neighbours, basins, spawn };
}

/**
 * The room `position` stands in (a real room before a service chase; null outside every room of the level).
 * @param {LevelInfo} info @param {THREE.Vector3} position @returns {Room|null}
 */
export function roomAt(info, position) {
  let chase = null;
  for (const room of info.roomList) {
    if (position.x >= room.minX && position.x <= room.maxX && position.z >= room.minZ && position.z <= room.maxZ &&
      position.y >= room.floorY - 40 && position.y <= room.floorY + room.height + 2) {
      if (room.kind !== 'Chase') return room;
      chase = room;
    }
  }
  return chase;
}
