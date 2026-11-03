// Brain: the pure core of the Creature's mind, shared by the service and its states.
//
//   * decide(summary): the transition table. Priorities, highest first: Scripted > Stunned > Dormant (its level is not
//     awake yet) > hold still while a catch plays > hold while it fades out / in (a warp) > a stun just ended: Patrol
//     (withdraw) > retreating in the water after a grab: AquaticStalk > a chase MaxChase seconds in, or one the
//     pacing calls off (catch cooldown, Relax): it gives up and fades out (Patrol) > no hunting allowed: Patrol >
//       the Chase (WallChase): it saw its quarry hide:
//       HidingResponse; still in sight (or stared at): on; line of sight lost for ChaseLost seconds, or the last seen
//       point reached: Search >
//     HidingResponse holds until its hider is out or taken (then WallChase on whoever it sees, else Search) > it saw
//     someone hide: HidingResponse > a 1 s stare: WallChase > someone in sight: WallChase (AquaticStalk when it is in
//     the water and they swim: a swimmer is only ever taken by the telegraphed lunge) > a swimmer on the pool level:
//     AquaticStalk > AquaticStalk ends when the water is calm > a teleport runs to its end (warning, FadeIn, stare,
//     stalk) > a noise at least as loud as the one being investigated (a High one breaks a Search): InvestigateNoise >
//     an investigation or a search that is over: Patrol > a teleport that is due: Teleport > Patrol (the Stalk).
//   * catchKind(check): whether a catch may happen now (reach, the same floor, a clear line eye to eye AND chest to
//     chest: never through a wall).
//   * levelInfo(levelId, meta): patrol loops (world.json `patrolLoops`, else the PatrolWaypoint anchors by loop /
//     order or "<prefix>_WP_<loop>_<NN>", else loops derived from the level's rooms: today's basement has no
//     waypoints), rooms and the open doorways between them, pool basins and the CreatureSpawn.

import * as THREE from 'three';
import { CFrame } from './cframe.js';
import { CreatureConfig, difficultySpec } from './config.js';
import { levelObstacles } from './nav.js';
import { makeBasin } from './water.js';

const SENSES = CreatureConfig.Senses;
const WAYPOINT_PATTERN = /_WP_(.+)_(\d+)$/;
const PASSABLE_DOORS = new Set(['Doorway', 'Door', 'Ajar']);
const WALKABLE_DOORS = new Set(['Doorway', 'Door', 'Ajar', 'RoofDoor', 'Gate', 'Airlock']);
const CHASES = new Set(['WallChase']);
const SEARCHES = new Set(['InvestigateNoise', 'Search']);
const EXACT_RANK = 3;
// rooms the derived patrol never walks into (the stair vestibules, ducts, the stairwells, crawlways)
const NO_PATROL = new Set(['Airlock', 'Chase', 'Stairwell', 'Crawlway']);
const DERIVED_SPACING = 30;
const DERIVED_INSET = 3;
const DERIVED_LOOP = 6;
const FREE_CLEARANCE = 2.5;

export const MemorySeconds = SENSES.MemorySeconds;
export const CatchVertical = SENSES.CatchVertical;

/**
 * @typedef {Object} Summary
 * @property {string} state
 * @property {number} elapsed
 * @property {boolean} scripted
 * @property {boolean} stunned
 * @property {boolean} awake
 * @property {boolean} catching
 * @property {boolean} warping a FadeOut / FadeIn relocation runs
 * @property {boolean} canHunt
 * @property {boolean} sees someone it may chase is in sight
 * @property {boolean} stared someone held a stare on it for the full second
 * @property {boolean} hidingWatch it saw someone climb into a hiding spot
 * @property {number} heard
 * @property {number} investigating
 * @property {number} chaseSeconds
 * @property {number} lostSeconds seconds since the chase last saw its quarry
 * @property {number} maxChase
 * @property {number} chaseLost
 * @property {boolean} swimmer
 * @property {boolean} [inWater] the Creature swims
 * @property {boolean} [retreating] it retreats in the water after a grab
 * @property {boolean} teleportDue
 * @property {boolean} stateDone
 *
 * @typedef {{state: string, reason: string, reposition: boolean, giveUp: boolean}} Decision
 *
 * @typedef {{id: string, loop: string, order: number, position: THREE.Vector3, zoneId: string}} Waypoint
 * @typedef {{id: string, waypoints: Waypoint[], zones: Set<string>, centre: THREE.Vector3}} Loop
 * @typedef {{id: string, kind: string, minX: number, maxX: number, minZ: number, maxZ: number, floorY: number,
 *   height: number, centre: THREE.Vector3}} Room
 * @typedef {{levelId: string, origin: THREE.Vector3, loops: Loop[], waypoints: Waypoint[], derived: boolean,
 *   rooms: Record<string, Room>, roomList: Room[], neighbours: Record<string, string[]>,
 *   basins: import('./water.js').Basin[], spawn: CFrame|null}} LevelInfo
 *
 * @typedef {{position: THREE.Vector3, rank: number, priority: string, medium: string, kind: string,
 *   sourceUserId: number|null, zoneId: string|null, strength: number, at: number}} HeardNoise
 */

export function isChase(state) {
  return CHASES.has(state);
}

function go(state, reason, reposition = false, giveUp = false) {
  return { state, reason, reposition: reposition === true, giveUp: giveUp === true };
}

/** @param {Summary} s @returns {Decision} */
export function decide(s) {
  const state = s.state;
  if (s.scripted) return go('Scripted', 'scripted');
  if (s.stunned) return go('Stunned', 'stunned');
  if (!s.awake) return go('Dormant', 'asleep');
  if (s.catching) return go(state, 'catching');
  if (s.warping) return go(state, 'fading');
  if (state === 'Stunned') return go('Patrol', 'recovered', true);
  if (s.retreating && s.inWater) return go('AquaticStalk', 'retreating');
  // a chase that runs out (MaxChase) or is called off (the pacing's breather) ends the same way: it fades away
  if (state === 'WallChase' && (s.chaseSeconds >= s.maxChase || !s.canHunt)) {
    return go('Patrol', s.canHunt ? 'gave up' : 'breather', true, true);
  }
  if (!s.canHunt) return go('Patrol', 'breather', state === 'HidingResponse');
  if (state === 'WallChase') {
    if (s.hidingWatch) return go('HidingResponse', 'saw them hide');
    if (s.sees || s.stared) return go('WallChase', 'in sight');
    if (s.lostSeconds >= s.chaseLost || s.stateDone) return go('Search', 'lost sight');
    return go('WallChase', 'tracking');
  }
  if (state === 'HidingResponse') {
    if (!s.stateDone) return go('HidingResponse', 'waiting');
    if (s.sees || s.stared) return go('WallChase', 'out of hiding');
    return go('Search', 'slipped away');
  }
  if (s.hidingWatch) return go('HidingResponse', 'saw them hide');
  if (s.stared) return go('WallChase', 'stared at');
  if (s.sees) {
    if (s.swimmer && s.inWater) return go('AquaticStalk', 'swimmer in sight');
    return go('WallChase', 'seen');
  }
  if (s.swimmer) return go('AquaticStalk', 'swimmer');
  if (state === 'AquaticStalk') return go('Patrol', 'water calm');
  if (state === 'Teleport' && !s.stateDone) return go('Teleport', 'teleporting');
  if (s.heard > 0 && !SEARCHES.has(state)) return go('InvestigateNoise', 'heard');
  if (state === 'InvestigateNoise') {
    if (s.heard >= s.investigating && s.heard > 0) return go('InvestigateNoise', 'heard');
    if (s.stateDone) return go('Patrol', 'nothing found');
    return go('InvestigateNoise', 'searching');
  }
  if (state === 'Search') {
    if (s.heard >= EXACT_RANK) return go('InvestigateNoise', 'heard');
    if (s.stateDone) return go('Patrol', 'search over');
    return go('Search', 'searching');
  }
  if (s.teleportDue) return go('Teleport', 'teleport');
  return go('Patrol', 'patrolling');
}

/**
 * @param {{horizontal: number, vertical: number, reach: number, targetInVent: boolean, creatureInWater?: boolean,
 *   targetSwimming?: boolean, lineClear: boolean, bodyClear: boolean, playing: boolean, hiding: boolean,
 *   canHunt: boolean, busy: boolean, hidden: boolean, stunned: boolean, warping?: boolean}} check
 * @returns {string|null} JumpscareKind
 */
export function catchKind(check) {
  if (check.busy || !check.canHunt || check.hidden || check.stunned || check.warping) return null;
  // in the water the pool's telegraphed grab is the only catch
  if (check.creatureInWater || check.targetSwimming) return null;
  if (!check.playing || check.hiding || check.targetInVent) return null;
  // never through a wall: the eyes and the bodies both see each other
  if (!check.lineClear || !check.bodyClear) return null;
  if (check.horizontal <= check.reach && check.vertical <= SENSES.CatchVertical) return 'Hallway';
  return null;
}

/** The speed of a state on a difficulty (Scripted moves at its own pace; nothing else outruns a sprinter). */
export function speedFor(state, difficulty) {
  const base = CreatureConfig.Speeds[state] ?? CreatureConfig.Speeds.Patrol;
  if (state === 'Scripted') return base;
  return Math.min(CreatureConfig.SpeedCap, base * difficultySpec(difficulty).creatureSpeedMultiplier);
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
    const loop = typeof anchor.loop === 'string' && anchor.loop !== '' ? anchor.loop : match ? match[1] : null;
    const number = Number.isFinite(anchor.order) ? anchor.order : match ? Number(match[2]) : NaN;
    if (loop === null || !Number.isFinite(number)) continue;
    if (!byLoop.has(loop)) byLoop.set(loop, []);
    const c = anchor.cframe;
    byLoop.get(loop).push({
      id: anchor.id, loop, order: number, position: new THREE.Vector3(c[0], c[1], c[2]), zoneId: anchor.room || '',
    });
  }
  return finishLoops(byLoop);
}

/**
 * Patrol loops from world.json `patrolLoops` (the exporter's PatrolWaypoint loops, already in walking order).
 * @param {Array<{level: string, loop: string, waypoints: Array<{id: string, room: string, pos: number[]}>}>} entries
 * @param {string} levelId
 * @returns {Loop[]}
 */
export function exportedLoops(entries, levelId) {
  /** @type {Map<string, Waypoint[]>} */
  const byLoop = new Map();
  for (const entry of entries) {
    if (entry.level !== levelId || !Array.isArray(entry.waypoints) || entry.waypoints.length === 0) continue;
    const list = entry.waypoints.map((w, i) => ({
      id: w.id, loop: entry.loop, order: i + 1, position: new THREE.Vector3(w.pos[0], w.pos[1], w.pos[2]), zoneId: w.room || '',
    }));
    byLoop.set(entry.loop, list);
  }
  return finishLoops(byLoop);
}

/** @param {Map<string, Waypoint[]>} byLoop @returns {Loop[]} */
function finishLoops(byLoop) {
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

function insideAny(obstacles, x, z, grow) {
  for (const o of obstacles) {
    if (x >= o.minX - grow && x <= o.maxX + grow && z >= o.minZ - grow && z <= o.maxZ + grow) return true;
  }
  return false;
}

/** The point of `room` nearest `x, z` (inset from its walls) that no obstacle footprint covers, or null. */
export function freePointIn(room, obstacles, x, z, inset = DERIVED_INSET) {
  const minX = room.minX + inset;
  const maxX = room.maxX - inset;
  const minZ = room.minZ + inset;
  const maxZ = room.maxZ - inset;
  if (minX > maxX || minZ > maxZ) return null;
  const cx = Math.min(maxX, Math.max(minX, x));
  const cz = Math.min(maxZ, Math.max(minZ, z));
  if (!insideAny(obstacles, cx, cz, FREE_CLEARANCE)) return [cx, cz];
  for (let r = 2; r <= 30; r += 2) {
    for (let i = 0; i < 16; i++) {
      const a = (i / 16) * Math.PI * 2;
      const px = cx + Math.cos(a) * r;
      const pz = cz + Math.sin(a) * r;
      if (px < minX || px > maxX || pz < minZ || pz > maxZ) continue;
      if (!insideAny(obstacles, px, pz, FREE_CLEARANCE)) return [px, pz];
    }
  }
  return null;
}

/**
 * Patrol loops for a level without PatrolWaypoints (today's basement): points over its rooms (one at the free spot
 * nearest each room's centre, a grid every DERIVED_SPACING studs in the big ones), chained nearest-first into loops of
 * DERIVED_LOOP points. Deterministic.
 * @param {Room[]} rooms @param {any[]} obstacles @returns {Loop[]}
 */
export function derivedLoops(rooms, obstacles) {
  const points = [];
  for (const room of rooms) {
    if (NO_PATROL.has(room.kind)) continue;
    const w = room.maxX - room.minX;
    const d = room.maxZ - room.minZ;
    const nx = Math.max(1, Math.round(w / DERIVED_SPACING));
    const nz = Math.max(1, Math.round(d / DERIVED_SPACING));
    for (let i = 0; i < nx; i++) {
      for (let j = 0; j < nz; j++) {
        const x = room.minX + (w * (i + 0.5)) / nx;
        const z = room.minZ + (d * (j + 0.5)) / nz;
        const free = freePointIn(room, obstacles, x, z);
        if (free) points.push({ room: room.id, position: new THREE.Vector3(free[0], room.floorY, free[1]) });
      }
    }
  }
  /** @type {Map<string, Waypoint[]>} */
  const byLoop = new Map();
  const left = points.slice().sort((a, b) => a.position.x - b.position.x || a.position.z - b.position.z);
  let n = 0;
  while (left.length) {
    const chain = [left.shift()];
    while (chain.length < DERIVED_LOOP && left.length) {
      const last = chain[chain.length - 1].position;
      let best = 0;
      for (let i = 1; i < left.length; i++) {
        if (left[i].position.distanceTo(last) < left[best].position.distanceTo(last)) best = i;
      }
      chain.push(left.splice(best, 1)[0]);
    }
    n++;
    const id = `Derived${String(n).padStart(2, '0')}`;
    byLoop.set(id, chain.map((p, i) => ({ id: `${id}_${i + 1}`, loop: id, order: i + 1, position: p.position, zoneId: p.room })));
  }
  return finishLoops(byLoop);
}

/**
 * The rooms of the level's main walkable component (the largest set joined by doorways, doors, gates and airlocks):
 * a room boarded shut (today's Condemned Store) or reached only through a duct is left out.
 * @param {any} meta @param {string} levelId @returns {Set<string>}
 */
export function mainRooms(meta, levelId) {
  const ids = (meta.rooms || []).filter((r) => r.level === levelId && r.kind !== 'Chase' && r.kind !== 'Crawlway').map((r) => r.id);
  const links = new Map(ids.map((id) => [id, []]));
  for (const door of meta.layoutDoors || []) {
    if (door.level !== levelId || !WALKABLE_DOORS.has(door.kind) || door.crawlOnly === true) continue;
    const [a, b] = door.rooms;
    if (!links.has(a) || !links.has(b)) continue;
    links.get(a).push(b);
    links.get(b).push(a);
  }
  let best = new Set();
  const seen = new Set();
  for (const id of ids) {
    if (seen.has(id)) continue;
    const part = new Set([id]);
    const queue = [id];
    seen.add(id);
    while (queue.length) {
      for (const next of links.get(queue.shift())) {
        if (seen.has(next)) continue;
        seen.add(next);
        part.add(next);
        queue.push(next);
      }
    }
    if (part.size > best.size) best = part;
  }
  return best;
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
  const exported = Array.isArray(meta.patrolLoops) ? exportedLoops(meta.patrolLoops, levelId) : [];
  let loops = exported.length > 0 ? exported : patrolLoops(anchors);
  let derived = false;
  const reachable = mainRooms(meta, levelId);
  if (loops.length === 0) {
    loops = derivedLoops(roomList.filter((r) => r.kind !== 'Pool' && reachable.has(r.id)), levelObstacles(meta, levelId));
    derived = loops.length > 0;
  }
  const waypoints = [];
  for (const loop of loops) for (const w of loop.waypoints) waypoints.push(w);
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
    const made = makeBasin(basin.id, origin, basin.rect, room, basin.waterLevel, basin.depth);
    // Level 4 fairness: the Creature enters and leaves the water only by fading out and in, out of sight
    made.fadeOnly = CreatureConfig.Water.FadeOnly;
    basins.push(made);
  }
  // its CreatureSpawn (one in a room it could never walk out of does not count: the first waypoint instead)
  let spawn = null;
  for (const anchor of anchors) {
    if (anchor.kind === 'CreatureSpawn' && (!anchor.room || reachable.size === 0 || reachable.has(anchor.room))) {
      spawn = CFrame.fromComponents(anchor.cframe);
      break;
    }
  }
  return { levelId, origin, loops, waypoints, derived, rooms, roomList, neighbours, basins, spawn };
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
