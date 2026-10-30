// squad.js: the room's players as every page keeps them. The host owns the record (slots, ready, votes, life states,
// who is in the run, outcomes, links and pings) and sends it whole on every change ('squad'); each page fills in the
// poses from the state packets. A member's poses are buffered with their arrival time and read back
// NetConfig.InterpDelay behind real time, interpolated (yaw the short way round), so a teammate moves smoothly however
// the packets bunch up; a member whose packets stop is extrapolated for at most MAX_EXTRAPOLATE and then held.

import { NetConfig } from '../../net/config.js';

const BUFFER = 12;
const MAX_EXTRAPOLATE = 0.15;

/**
 * @typedef {import('../../net/codec.js').Pose} Pose
 * @typedef {{id: string, name: string, slot: number, host: boolean, ready: boolean, vote: string|null,
 *   link: string, ping: number|null, life: string, participant: boolean, outcome: string, downedCount: number,
 *   lateJoin: boolean, playAgain: boolean}} MemberRecord
 */

/** The fields the host replicates (everything but the poses). */
export const RECORD_KEYS = ['id', 'name', 'slot', 'host', 'ready', 'vote', 'link', 'ping', 'life', 'participant', 'outcome',
  'downedCount', 'lateJoin', 'playAgain'];

export class Member {
  /** @param {Partial<MemberRecord>} record */
  constructor(record) {
    this.id = record.id;
    this.name = record.name || 'Survivor';
    this.slot = record.slot ?? 0;
    this.host = !!record.host;
    this.ready = false;
    this.vote = null;
    this.link = 'connecting';
    this.ping = null;
    this.life = 'Lobby';
    this.participant = false;
    this.outcome = 'Pending';
    this.downedCount = 0;
    this.lateJoin = false;
    this.playAgain = false;
    /** @type {Pose|null} the newest pose */
    this.pose = null;
    this.poseAt = 0;
    /** @type {Array<{t: number, pose: Pose}>} */
    this.buffer = [];
    this.local = false;
    /** the locker this member hides in (the host's view, from the claim) */
    this.lockerId = null;
    /** a catch holds them (host) */
    this.caught = false;
    this.lastSeq = -1;
    Object.assign(this, pick(record));
  }

  /** The member's record for the 'squad' message. */
  record() {
    const out = {};
    for (const k of RECORD_KEYS) out[k] = this[k];
    return out;
  }

  /** A pose arrived (seconds of real time). */
  pushPose(pose, t) {
    this.pose = pose;
    this.poseAt = t;
    this.buffer.push({ t, pose });
    if (this.buffer.length > BUFFER) this.buffer.shift();
  }

  /** The pose to draw at real time `t` (interpolated NetConfig.InterpDelay behind), or null before any arrived. */
  sample(t, out = {}) {
    const b = this.buffer;
    if (!b.length) return null;
    const at = t - NetConfig.InterpDelay;
    let i = b.length - 1;
    while (i > 0 && b[i - 1].t > at) i--;
    const next = b[i];
    const prev = i > 0 ? b[i - 1] : null;
    if (!prev || at >= next.t) {
      // past the newest sample: extrapolate briefly from the last two, then hold
      const last = b[b.length - 1];
      const before = b.length > 1 ? b[b.length - 2] : null;
      Object.assign(out, last.pose);
      if (before && last.t > before.t) {
        const ahead = Math.min(MAX_EXTRAPOLATE, Math.max(0, at - last.t));
        const k = ahead / (last.t - before.t);
        if (k > 0 && distanceSq(before.pose, last.pose) < 400) {
          out.x = last.pose.x + (last.pose.x - before.pose.x) * k;
          out.y = last.pose.y + (last.pose.y - before.pose.y) * k;
          out.z = last.pose.z + (last.pose.z - before.pose.z) * k;
        }
      }
      return out;
    }
    const span = next.t - prev.t;
    const f = span > 1e-6 ? Math.min(1, Math.max(0, (at - prev.t) / span)) : 1;
    Object.assign(out, f < 0.5 ? prev.pose : next.pose);
    // a jump of more than 20 studs between samples is a teleport: no sliding across the map
    if (distanceSq(prev.pose, next.pose) > 400) return Object.assign(out, next.pose);
    out.x = prev.pose.x + (next.pose.x - prev.pose.x) * f;
    out.y = prev.pose.y + (next.pose.y - prev.pose.y) * f;
    out.z = prev.pose.z + (next.pose.z - prev.pose.z) * f;
    out.yaw = lerpAngle(prev.pose.yaw, next.pose.yaw, f);
    out.pitch = prev.pose.pitch + (next.pose.pitch - prev.pose.pitch) * f;
    return out;
  }

  /** Alive or Downed (in play). */
  playing() {
    return this.life === 'Alive' || this.life === 'Downed';
  }
}

function pick(record) {
  const out = {};
  for (const k of RECORD_KEYS) if (record[k] !== undefined) out[k] = record[k];
  return out;
}

function distanceSq(a, b) {
  const dx = a.x - b.x;
  const dy = a.y - b.y;
  const dz = a.z - b.z;
  return dx * dx + dy * dy + dz * dz;
}

/** Linear interpolation of an angle the short way round. */
export function lerpAngle(a, b, f) {
  let d = (b - a) % (Math.PI * 2);
  if (d > Math.PI) d -= Math.PI * 2;
  if (d < -Math.PI) d += Math.PI * 2;
  return a + d * f;
}

/** The squad: members by id, in slot order. */
export class Squad {
  constructor() {
    /** @type {Map<string, Member>} */
    this.map = new Map();
  }

  get(id) {
    return this.map.get(id) || null;
  }

  bySlot(slot) {
    for (const m of this.map.values()) if (m.slot === slot) return m;
    return null;
  }

  /** Every member in slot order. */
  list() {
    return [...this.map.values()].sort((a, b) => a.slot - b.slot);
  }

  /** The other members (not this page's). */
  others() {
    return this.list().filter((m) => !m.local);
  }

  add(member) {
    this.map.set(member.id, member);
    return member;
  }

  remove(id) {
    const m = this.map.get(id);
    this.map.delete(id);
    return m || null;
  }

  clear() {
    this.map.clear();
  }

  /** The lowest slot nobody holds. */
  freeSlot() {
    for (let s = 0; s < NetConfig.MaxPlayers; s++) if (!this.bySlot(s)) return s;
    return -1;
  }

  /** The members deployed in the current run. */
  participants() {
    return this.list().filter((m) => m.participant);
  }

  /** Replaces the records with the host's (keeping poses); returns [joined, left] members. */
  applyRecords(records, localId) {
    const seen = new Set();
    const joined = [];
    for (const r of records) {
      seen.add(r.id);
      let m = this.map.get(r.id);
      if (!m) {
        m = this.add(new Member(r));
        m.local = r.id === localId;
        joined.push(m);
      } else {
        Object.assign(m, pick(r));
      }
    }
    const left = [];
    for (const id of [...this.map.keys()]) {
      if (!seen.has(id)) left.push(this.remove(id));
    }
    return [joined, left];
  }
}
