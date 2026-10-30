// codec.js: the binary state packets and the relay's delta compression.
//
//   Pose (23 bytes): position x / y / z as signed 24-bit at 1/64 stud, yaw as u16 over a full turn, pitch as i16 at
//   1/16000 rad, the MoveState and life state as enum indices, 16 flag bits (torch, crouch, duct, swim, hidden in a
//   locker, trapped, grabbed, wearing a pack, torch lowered, in the airlock, carrying an objective item, being revived,
//   being caught), the held item, oxygen / stamina / battery / health as 0..255 fractions and the level index.
//   Client -> host (StateHz): [kind 1][seq u16][pose].
//   Host -> clients (StateHz): [kind 2][seq u16][count u8]{slot u8, pose}x count [creature block (16 bytes) or none].
//   Creature block (17 bytes): flags (present, hidden, in a duct, awake), position (as above), yaw u16, MonsterState,
//   PoseMode, level index, target slot, grabbed slot (255: nobody).
// Four players and the Creature make a 117-byte world packet; one player's pose is 26 bytes (budget: 300 per player).
//
// Delta compression (the relay): XOR against the previous packet of the same stream, then runs of zero bytes and
// literal bytes: [zeros u8][literals u8][literal bytes] repeated. A packet that barely moved shrinks to a few bytes.

import { Reader, Writer } from './bytes.js';

export const MoveStates = Object.freeze(['Standing', 'Crouching', 'Sprinting', 'VentCrawling', 'VentScurrying',
  'Treading', 'Freestyle', 'Underwater', 'Grabbed', 'Trapped', 'Hiding', 'Parachuting', 'DownedCrawling', 'Scripted',
  'Falling', 'Freefall']);
export const LifeStates = Object.freeze(['Lobby', 'Alive', 'Downed', 'Dead', 'Spectating']);
export const MonsterStateList = Object.freeze(['Dormant', 'Patrol', 'InvestigateNoise', 'WallChase', 'VentChase',
  'Stunned', 'AquaticStalk', 'Scripted']);
export const PoseModes = Object.freeze(['Biped', 'Hunched', 'Quadruped', 'Swim']);
export const Levels = Object.freeze(['Lobby', 'Level0_Basement', 'Level1_Hallways', 'Level2_ScienceHall',
  'Level3_Gymnasium', 'Level4_FloodedPool', 'Level5_Roof', 'Exterior']);
export const HeldItems = Object.freeze(['None', 'Flask', 'AcidFlask', 'Pack', 'Item']);

export const PoseFlags = Object.freeze({
  Torch: 1 << 0,
  Crouch: 1 << 1,
  Vent: 1 << 2,
  Swim: 1 << 3,
  Hidden: 1 << 4,
  Trapped: 1 << 5,
  Grabbed: 1 << 6,
  Pack: 1 << 7,
  Lowered: 1 << 8,
  Airlock: 1 << 9,
  Carrying: 1 << 10,
  Reviving: 1 << 11,
  Caught: 1 << 12,
  Underwater: 1 << 13,
});

export const PacketKind = Object.freeze({ Pose: 1, World: 2 });
export const POSE_BYTES = 23;
const POS_SCALE = 64;
const PITCH_SCALE = 16000;
const TWO_PI = Math.PI * 2;

/**
 * @typedef {{x: number, y: number, z: number, yaw: number, pitch: number, moveState: string, life: string,
 *   flags: number, held: string, oxygen: number, stamina: number, battery: number, health: number, level: string|null}} Pose
 * oxygen / stamina / battery / health are fractions 0..1.
 */

/**
 * @typedef {{present: boolean, hidden: boolean, inVent: boolean, awake: boolean, x: number, y: number, z: number,
 *   yaw: number, state: string, pose: string, level: string|null, target: number, grabbed: number}} CreatureState
 * target / grabbed: the squad slot it hunts / holds under water (-1: nobody)
 */

function i24(w, v) {
  const q = Math.max(-8388608, Math.min(8388607, Math.round(v * POS_SCALE)));
  const u = q & 0xffffff;
  w.u8((u >> 16) & 0xff);
  w.u8((u >> 8) & 0xff);
  w.u8(u & 0xff);
}

function readI24(r) {
  const u = (r.u8() << 16) | (r.u8() << 8) | r.u8();
  return ((u << 8) >> 8) / POS_SCALE;
}

function index(list, value) {
  const i = list.indexOf(value);
  return i < 0 ? 0 : i;
}

function frac(v) {
  return Math.max(0, Math.min(255, Math.round((Number.isFinite(v) ? v : 0) * 255)));
}

/** @param {Writer} w @param {Pose} p */
export function writePose(w, p) {
  i24(w, p.x);
  i24(w, p.y);
  i24(w, p.z);
  const yaw = ((p.yaw % TWO_PI) + TWO_PI) % TWO_PI;
  w.u16(Math.round((yaw / TWO_PI) * 65535) & 0xffff);
  w.u16(Math.max(-32768, Math.min(32767, Math.round(p.pitch * PITCH_SCALE))) & 0xffff);
  w.u8(index(MoveStates, p.moveState));
  w.u8(index(LifeStates, p.life));
  w.u16(p.flags & 0xffff);
  w.u8(index(HeldItems, p.held));
  w.u8(frac(p.oxygen));
  w.u8(frac(p.stamina));
  w.u8(frac(p.battery));
  w.u8(frac(p.health));
  w.u8(p.level ? index(Levels, p.level) : 255);
}

/** @param {Reader} r @returns {Pose} */
export function readPose(r) {
  const x = readI24(r);
  const y = readI24(r);
  const z = readI24(r);
  const yaw = (r.u16() / 65535) * TWO_PI;
  const pitchRaw = r.u16();
  const pitch = ((pitchRaw << 16) >> 16) / PITCH_SCALE;
  const moveState = MoveStates[r.u8()] || 'Standing';
  const life = LifeStates[r.u8()] || 'Lobby';
  const flags = r.u16();
  const held = HeldItems[r.u8()] || 'None';
  const oxygen = r.u8() / 255;
  const stamina = r.u8() / 255;
  const battery = r.u8() / 255;
  const health = r.u8() / 255;
  const lv = r.u8();
  return { x, y, z, yaw, pitch, moveState, life, flags, held, oxygen, stamina, battery, health, level: lv === 255 ? null : Levels[lv] || null };
}

/** Client -> host: one pose. */
export function encodePosePacket(seq, pose) {
  const w = new Writer(32);
  w.u8(PacketKind.Pose);
  w.u16(seq & 0xffff);
  writePose(w, pose);
  return w.done();
}

/**
 * Host -> clients: every player's pose (by squad slot) and the Creature.
 * @param {number} seq
 * @param {Array<{slot: number, pose: Pose}>} players
 * @param {CreatureState|null} creature
 */
export function encodeWorldPacket(seq, players, creature) {
  const w = new Writer(160);
  w.u8(PacketKind.World);
  w.u16(seq & 0xffff);
  w.u8(players.length);
  for (const p of players) {
    w.u8(p.slot);
    writePose(w, p.pose);
  }
  if (creature && creature.present) {
    let flags = 1;
    if (creature.hidden) flags |= 2;
    if (creature.inVent) flags |= 4;
    if (creature.awake) flags |= 8;
    w.u8(flags);
    i24(w, creature.x);
    i24(w, creature.y);
    i24(w, creature.z);
    const yaw = ((creature.yaw % TWO_PI) + TWO_PI) % TWO_PI;
    w.u16(Math.round((yaw / TWO_PI) * 65535) & 0xffff);
    w.u8(index(MonsterStateList, creature.state));
    w.u8(index(PoseModes, creature.pose));
    w.u8(creature.level ? index(Levels, creature.level) : 255);
    w.u8(creature.target >= 0 ? creature.target : 255);
    w.u8(creature.grabbed >= 0 ? creature.grabbed : 255);
  } else {
    w.u8(0);
  }
  return w.done();
}

/**
 * Reads a packet: {kind: 1, seq, pose} or {kind: 2, seq, players: [{slot, pose}], creature}; null when malformed.
 * @param {Uint8Array} bytes
 */
export function decodePacket(bytes) {
  try {
    const r = new Reader(bytes);
    const kind = r.u8();
    const seq = r.u16();
    if (kind === PacketKind.Pose) return { kind, seq, pose: readPose(r) };
    if (kind !== PacketKind.World) return null;
    const n = r.u8();
    const players = [];
    for (let i = 0; i < n; i++) players.push({ slot: r.u8(), pose: readPose(r) });
    const flags = r.u8();
    let creature = null;
    if (flags & 1) {
      const x = readI24(r);
      const y = readI24(r);
      const z = readI24(r);
      const yaw = (r.u16() / 65535) * TWO_PI;
      const state = MonsterStateList[r.u8()] || 'Dormant';
      const pose = PoseModes[r.u8()] || 'Biped';
      const lv = r.u8();
      const target = r.u8();
      const grabbed = r.u8();
      creature = { present: true, hidden: !!(flags & 2), inVent: !!(flags & 4), awake: !!(flags & 8), x, y, z, yaw, state,
        pose, level: lv === 255 ? null : Levels[lv] || null, target: target === 255 ? -1 : target,
        grabbed: grabbed === 255 ? -1 : grabbed };
    }
    return { kind, seq, players, creature };
  } catch {
    return null;
  }
}

/**
 * XOR delta of `next` against `base` (same length), zero runs and literals.
 * @param {Uint8Array} base @param {Uint8Array} next
 * @returns {Uint8Array}
 */
export function deltaEncode(base, next) {
  const w = new Writer(Math.max(16, next.length));
  let i = 0;
  const n = next.length;
  while (i < n) {
    let zeros = 0;
    while (i + zeros < n && zeros < 255 && (base[i + zeros] ^ next[i + zeros]) === 0) zeros++;
    let lits = 0;
    while (i + zeros + lits < n && lits < 255 && (base[i + zeros + lits] ^ next[i + zeros + lits]) !== 0) lits++;
    w.u8(zeros);
    w.u8(lits);
    for (let k = 0; k < lits; k++) w.u8(base[i + zeros + k] ^ next[i + zeros + k]);
    i += zeros + lits;
  }
  return w.done();
}

/**
 * The packet a delta rebuilds from `base`, or null when the delta does not fit it.
 * @param {Uint8Array} base @param {Uint8Array} delta
 * @returns {Uint8Array|null}
 */
export function deltaDecode(base, delta) {
  const out = base.slice();
  let i = 0;
  let k = 0;
  while (k < delta.length) {
    if (k + 2 > delta.length) return null;
    const zeros = delta[k];
    const lits = delta[k + 1];
    k += 2;
    i += zeros;
    if (i + lits > out.length || k + lits > delta.length) return null;
    for (let j = 0; j < lits; j++) out[i + j] ^= delta[k + j];
    i += lits;
    k += lits;
  }
  return i === out.length ? out : null;
}
