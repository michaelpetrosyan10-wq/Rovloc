// transport.js: the network's two contracts and the relay transport.
//
//   SignalingChannel  a room on a shared broadcast service: presence (who is in the room, each with a small meta
//                     record) and broadcast (an event to everyone else in the room, JSON or binary). Two of them:
//                     SupabaseChannel (supabase.js, production: Supabase Realtime presence + broadcast) and
//                     LocalRelayChannel (localRelay.js: the test tool's WebSocket relay with the same semantics).
//   Transport         peer-to-peer messages for the game session: send(to, channel, bytes) on two channels, 'state'
//                     (unordered, unreliable: the newest pose wins) and 'events' (ordered, reliable), plus the
//                     members and each peer's link ('direct' / 'relay' / 'connecting'). Two of them: RelayTransport
//                     (here: everything through the signaling channel's broadcast) and WebRtcTransport (webrtc.js:
//                     direct data channels, falling back to a RelayTransport per peer).
//
// The relay is frugal because the free plan counts messages: one broadcast per sender per batch (RelayHz), holding the
// newest state packet for the relayed peers (a delta against the previous one, a whole keyframe every
// RelayKeyframeEvery batches; a packet shared by every relayed peer is sent once) and the events queued since the last
// batch. Events are numbered per sender and receiver; each batch acknowledges the highest contiguous number received,
// and an event not acknowledged within RelayResendSeconds goes again (a receiver drops what it has already seen), so the
// events channel stays reliable and ordered over the relay too.

import { NetConfig } from './config.js';
import { Reader, Writer, seqNewer } from './bytes.js';
import { deltaDecode, deltaEncode } from './codec.js';

/**
 * @typedef {{id: string, name: string, role: 'host'|'client', v: number, at: number, [k: string]: any}} PresenceMeta
 */

/**
 * @typedef {Object} SignalingChannel
 * @property {string} kind 'supabase' | 'local'
 * @property {(room: string, meta: PresenceMeta) => Promise<void>} join resolves once subscribed and tracked; rejects
 *   with an Error whose `code` is 'unreachable' when the service cannot be reached
 * @property {(meta: PresenceMeta) => void} track updates this member's presence meta
 * @property {() => PresenceMeta[]} members everyone in the room (this member included)
 * @property {(fn: (members: PresenceMeta[]) => void) => () => void} onMembers
 * @property {(event: string, payload: any) => void} broadcast to everyone else in the room (JSON value or ArrayBuffer)
 * @property {(event: string, fn: (payload: any) => void) => () => void} on
 * @property {(fn: (status: 'open'|'reconnecting'|'closed', detail?: string) => void) => () => void} onStatus
 * @property {() => Promise<void>} leave
 */

/**
 * @typedef {'state'|'events'} ChannelName
 * @typedef {'direct'|'relay'|'connecting'} LinkKind
 * @typedef {Object} Transport
 * @property {string} id this peer's id
 * @property {(room: string, meta: PresenceMeta) => Promise<void>} connect
 * @property {(meta: PresenceMeta) => void} track
 * @property {() => PresenceMeta[]} members
 * @property {(fn: (members: PresenceMeta[]) => void) => () => void} onMembers
 * @property {(to: string, channel: ChannelName, data: Uint8Array) => void} send
 * @property {(fn: (from: string, channel: ChannelName, data: Uint8Array) => void) => () => void} onMessage
 * @property {(peerId: string) => LinkKind} linkOf
 * @property {(fn: (peerId: string, link: LinkKind) => void) => () => void} onLink
 * @property {(fn: (status: string, detail?: string) => void) => () => void} onStatus
 * @property {() => void} flush sends the relay batch (the session calls it RelayHz times a second)
 * @property {() => Promise<void>} close
 */

/** A tiny listener list (the net layer's own, independent of the game). */
export class Listeners {
  constructor() {
    /** @type {Set<Function>} */
    this.set = new Set();
  }

  add(fn) {
    this.set.add(fn);
    return () => this.set.delete(fn);
  }

  fire(...args) {
    for (const fn of [...this.set]) {
      try {
        fn(...args);
      } catch (err) {
        console.error('[net]', err);
      }
    }
  }
}

/**
 * Presence with a grace period: a member who drops out of the service's presence is kept for `seconds` before the room
 * is told they left, so a school network's blip (the socket reconnecting, presence re-tracked) never ends a run; a
 * member who comes back within the grace never left. Closing a tab is noticed `seconds` later.
 */
export class PresenceGrace {
  /** @param {number} seconds @param {() => void} onChange */
  constructor(seconds, onChange) {
    this.ms = seconds * 1000;
    this.onChange = onChange;
    /** @type {Map<string, PresenceMeta>} */
    this.current = new Map();
    /** @type {Map<string, number>} id -> when it went missing (Date.now) */
    this.gone = new Map();
    this.timer = null;
  }

  /** The service's member list now. */
  update(list) {
    const now = Date.now();
    const ids = new Set();
    for (const m of list) {
      if (!m || typeof m.id !== 'string') continue;
      ids.add(m.id);
      this.current.set(m.id, m);
      this.gone.delete(m.id);
    }
    for (const id of this.current.keys()) if (!ids.has(id) && !this.gone.has(id)) this.gone.set(id, now);
    this._schedule();
    this.onChange();
  }

  _schedule() {
    clearTimeout(this.timer);
    this.timer = null;
    if (!this.gone.size) return;
    const next = Math.min(...this.gone.values()) + this.ms;
    this.timer = setTimeout(() => this._expire(), Math.max(0, next - Date.now()) + 5);
  }

  _expire() {
    const now = Date.now();
    let changed = false;
    for (const [id, at] of [...this.gone]) {
      if (now - at < this.ms) continue;
      this.gone.delete(id);
      this.current.delete(id);
      changed = true;
    }
    this._schedule();
    if (changed) this.onChange();
  }

  list() {
    return [...this.current.values()];
  }

  clear() {
    clearTimeout(this.timer);
    this.timer = null;
    this.current.clear();
    this.gone.clear();
  }
}

const RELAY_EVENT = 'r';

/**
 * Everything between this peer and one other peer over the relay: the outgoing event queue (numbered, kept until
 * acknowledged), the newest outgoing state packet, the state baselines both ways and the incoming event counter.
 */
class RelayPeer {
  constructor(id) {
    this.id = id;
    /** @type {Array<{seq: number, data: Uint8Array, sentAt: number}>} */
    this.outbox = [];
    this.nextSeq = 1;
    /** highest contiguous event number received from this peer */
    this.received = 0;
    /** @type {Uint8Array|null} newest state packet to send */
    this.state = null;
    /** @type {Uint8Array|null} the state baseline received from this peer (for its deltas) */
    this.inBase = null;
    this.inBaseSeq = -1;
    this.ackDue = false;
  }
}

/**
 * A Transport where every message goes through the signaling channel (Supabase broadcast or the local relay). Used on
 * its own (forced relay) and inside WebRtcTransport for the peers without a direct link.
 */
export class RelayTransport {
  /**
   * @param {SignalingChannel} channel
   * @param {string} id this peer's id
   * @param {{now?: () => number}} [opts]
   */
  constructor(channel, id, opts = {}) {
    this.channel = channel;
    this.id = id;
    this.now = opts.now || (() => performance.now() / 1000);
    /** @type {Map<string, RelayPeer>} */
    this.peers = new Map();
    this.messages = new Listeners();
    this.links = new Listeners();
    this.batch = 0;
    /** @type {Uint8Array|null} the shared state packet sent last (the baseline of the next shared delta) */
    this.sharedBase = null;
    this.baseSeq = 0;
    /** peers this relay serves (null: every member) */
    this.only = null;
    this.sentMessages = 0;
    this.sentBytes = 0;
    this.offChannel = channel.on(RELAY_EVENT, (payload) => this._receive(payload));
  }

  async connect(room, meta) {
    await this.channel.join(room, meta);
  }

  track(meta) {
    this.channel.track(meta);
  }

  members() {
    return this.channel.members();
  }

  onMembers(fn) {
    return this.channel.onMembers(fn);
  }

  onStatus(fn) {
    return this.channel.onStatus(fn);
  }

  onMessage(fn) {
    return this.messages.add(fn);
  }

  onLink(fn) {
    return this.links.add(fn);
  }

  linkOf() {
    return 'relay';
  }

  _peer(id) {
    let p = this.peers.get(id);
    if (!p) {
      p = new RelayPeer(id);
      this.peers.set(id, p);
    }
    return p;
  }

  /** Forgets a peer (it left the room). */
  drop(id) {
    this.peers.delete(id);
  }

  send(to, channel, data) {
    const p = this._peer(to);
    if (channel === 'state') p.state = data;
    else p.outbox.push({ seq: p.nextSeq++ & 0xffff, data, sentAt: -Infinity });
  }

  /** One batch: at most one broadcast message holding every relayed peer's state and due events. */
  flush() {
    const now = this.now();
    this.batch++;
    const keyframe = this.batch % NetConfig.RelayKeyframeEvery === 1;
    // a state packet shared by every relayed peer goes once, in the shared section
    let shared = null;
    let sharedCount = 0;
    for (const p of this.peers.values()) {
      if (!p.state) continue;
      if (shared === null) {
        shared = p.state;
        sharedCount = 1;
      } else if (bytesEqual(shared, p.state)) sharedCount++;
      else {
        shared = null;
        sharedCount = -1;
        break;
      }
    }
    const sections = [];
    if (shared && sharedCount > 0) {
      sections.push({ to: '', state: shared });
      for (const p of this.peers.values()) p.state = null;
    }
    for (const p of this.peers.values()) {
      const due = p.outbox.filter((e) => now - e.sentAt >= NetConfig.RelayResendSeconds);
      if (!p.state && !due.length && !p.ackDue) continue;
      sections.push({ to: p.id, state: p.state, events: due, ack: p.received });
      for (const e of due) e.sentAt = now;
      p.state = null;
      p.ackDue = false;
    }
    if (!sections.length) return;
    const w = new Writer(512);
    w.u8(1);
    w.str8(this.id);
    w.u16(this.batch & 0xffff);
    w.u8(sections.length);
    for (const s of sections) {
      w.str8(s.to);
      w.u16(s.ack || 0);
      let flags = 0;
      if (s.state) flags |= 1;
      if (s.events && s.events.length) flags |= 2;
      w.u8(flags);
      if (s.state) {
        const base = s.to === '' ? this.sharedBase : null;
        const useDelta = !keyframe && base !== null && base.length === s.state.length;
        w.u8(useDelta ? 1 : 0);
        w.u16(useDelta ? this.baseSeq : 0);
        w.blob16(useDelta ? deltaEncode(base, s.state) : s.state);
        if (s.to === '') {
          this.sharedBase = s.state;
          this.baseSeq = this.batch & 0xffff;
        }
      }
      if (s.events && s.events.length) {
        w.u8(s.events.length);
        for (const e of s.events) {
          w.u16(e.seq);
          w.blob16(e.data);
        }
      }
    }
    const bytes = w.done();
    this.sentMessages++;
    this.sentBytes += bytes.length;
    this.channel.broadcast(RELAY_EVENT, bytes.buffer);
  }

  _receive(payload) {
    let bytes;
    if (payload instanceof ArrayBuffer) bytes = new Uint8Array(payload);
    else if (payload instanceof Uint8Array) bytes = payload;
    else return;
    try {
      const r = new Reader(bytes);
      if (r.u8() !== 1) return;
      const from = r.str8();
      if (from === this.id) return;
      if (this.only && !this.only.has(from)) return;
      const batch = r.u16();
      const count = r.u8();
      const p = this._peer(from);
      for (let i = 0; i < count; i++) {
        const to = r.str8();
        const ack = r.u16();
        const flags = r.u8();
        const mine = to === '' || to === this.id;
        let state = null;
        if (flags & 1) {
          const delta = r.u8() === 1;
          const baseSeq = r.u16();
          const body = r.blob16();
          if (mine) {
            if (!delta) state = body.slice();
            else if (p.inBase && p.inBaseSeq === baseSeq) state = deltaDecode(p.inBase, body);
            if (state && to === '') {
              p.inBase = state;
              p.inBaseSeq = batch;
            }
          }
        }
        const events = [];
        if (flags & 2) {
          const n = r.u8();
          for (let k = 0; k < n; k++) events.push({ seq: r.u16(), data: r.blob16() });
        }
        if (!mine) continue;
        if (to === this.id) {
          // their acknowledgement of our events
          while (p.outbox.length && !seqNewer(p.outbox[0].seq, ack)) p.outbox.shift();
        }
        if (state) this.messages.fire(from, 'state', state);
        for (const e of events) {
          const expected = (p.received + 1) & 0xffff;
          if (e.seq !== expected) {
            if (!seqNewer(e.seq, p.received)) p.ackDue = true; // a resend we already had: acknowledge again
            continue;
          }
          p.received = e.seq;
          p.ackDue = true;
          this.messages.fire(from, 'events', e.data.slice());
        }
      }
    } catch (err) {
      console.warn('[net] a relay message could not be read', err);
    }
  }

  async close() {
    this.offChannel();
    this.peers.clear();
    await this.channel.leave();
  }
}

function bytesEqual(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
