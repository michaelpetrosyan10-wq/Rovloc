// session.js: a co-op room as the game sees it: one host and up to three clients in a star, on any Transport.
//
//   Session.host(opts)        a fresh room code, joined as the host (a code another host already holds is re-rolled)
//   Session.join(code, opts)  joins a room and waits for its host (NetConfig.FindHostTimeout)
//   sendEvent(to, msg)        a JSON message on the reliable, ordered events channel ('*' from the host: every client)
//   sendState(to, bytes)      a binary state packet on the unordered, unreliable channel ('*': every client)
//   on(kind, fn)              'event' (from, msg), 'state' (from, bytes), 'peers' (peers), 'hostLeft' (), 'closed'
//                             (reason), 'link' (peerId, link)
//   peers()                   [{id, name, role, link, rtt}] in join order (the host's view of ping is measured; a
//                             client knows its own link and ping to the host)
// The host pings each client every NetConfig.PingSeconds; the relay batch goes out RelayHz times a second on a timer of
// its own (it keeps running while the page's frames are throttled). Errors carry a `code`: 'unreachable' (the service
// cannot be reached), 'nohost' (nobody hosts that code), 'full' (four players already), 'version' (another build).

import { NetConfig } from './config.js';
import { newPeerId, newRoomCode } from './code.js';
import { LocalRelayChannel } from './localRelay.js';
import { SupabaseChannel } from './supabase.js';
import { Listeners, RelayTransport } from './transport.js';
import { WebRtcTransport } from './webrtc.js';

const ENCODER = new TextEncoder();
const DECODER = new TextDecoder();
const HOST_TRIES = 3;

/**
 * @typedef {Object} SessionOptions
 * @property {string} name the player's display name
 * @property {'supabase'|'local'} [service] default supabase
 * @property {string} [relayUrl] the local relay (service 'local')
 * @property {boolean} [forceRelay] skip WebRTC (tests)
 * @property {boolean} [webrtc] false: relay only for every peer
 * @property {any} [socketClass] a WebSocket class for the Supabase client (tests)
 */

function error(code, message) {
  const err = new Error(message);
  err.code = code;
  return err;
}

/** The SignalingChannel and Transport for a set of options. */
export function createTransport(id, opts) {
  const channel = opts.service === 'local' ? new LocalRelayChannel(opts.relayUrl) : new SupabaseChannel({ transport: opts.socketClass });
  if (opts.webrtc === false) return new RelayTransport(channel, id);
  return new WebRtcTransport(channel, id, { forceRelay: !!opts.forceRelay });
}

export class Session {
  /**
   * @param {'host'|'client'} role
   * @param {string} code
   * @param {SessionOptions} opts
   */
  constructor(role, code, opts) {
    this.role = role;
    this.code = code;
    this.opts = opts;
    this.id = newPeerId();
    this.name = opts.name || 'Survivor';
    this.joinedAt = Date.now();
    /** @type {import('./transport.js').Transport} */
    this.transport = createTransport(this.id, opts);
    this.hostId = role === 'host' ? this.id : null;
    this.listeners = { event: new Listeners(), state: new Listeners(), peers: new Listeners(), hostLeft: new Listeners(),
      closed: new Listeners(), link: new Listeners() };
    /** @type {Map<string, {id: string, name: string, role: string, at: number, rtt: number|null}>} */
    this.peerMap = new Map();
    this.closed = false;
    this.pingTimer = null;
    this.flushTimer = null;
    this.hostSeen = false;
    this.rttToHost = null;
  }

  /** Hosts a new room. @param {SessionOptions} opts @returns {Promise<Session>} */
  static async host(opts) {
    let last = null;
    for (let i = 0; i < HOST_TRIES; i++) {
      const s = new Session('host', newRoomCode(), opts);
      try {
        await s._connect();
      } catch (err) {
        await s.close('error');
        throw err;
      }
      const rival = s.transport.members().find((m) => m.role === 'host' && m.id !== s.id && m.at <= s.joinedAt);
      if (!rival) {
        s._start();
        return s;
      }
      last = s;
      await s.close('collision');
    }
    throw error(last ? 'collision' : 'unreachable', 'could not find a free room code');
  }

  /** Joins a room. @param {string} code @param {SessionOptions} opts @returns {Promise<Session>} */
  static async join(code, opts) {
    const s = new Session('client', code, opts);
    try {
      await s._connect();
      await s._findHost();
    } catch (err) {
      await s.close('error');
      throw err;
    }
    s._start();
    return s;
  }

  _meta() {
    return { id: this.id, name: this.name, role: this.role, v: NetConfig.Version, at: this.joinedAt };
  }

  async _connect() {
    const t = this.transport;
    t.onMessage((from, channel, data) => this._onMessage(from, channel, data));
    t.onMembers((members) => this._onMembers(members));
    t.onLink((peer, link) => this.listeners.link.fire(peer, link));
    t.onStatus((status) => {
      if (status === 'closed' && !this.closed) this._lost('connection');
    });
    await t.connect(this.code, this._meta());
    this._onMembers(t.members());
  }

  _findHost() {
    return new Promise((resolve, reject) => {
      const check = () => {
        const host = this.transport.members().find((m) => m.role === 'host');
        if (!host) return false;
        if (host.v !== NetConfig.Version) {
          reject(error('version', 'that room runs another version of the game'));
          return true;
        }
        const clients = this.transport.members().filter((m) => m.role === 'client' && m.v === NetConfig.Version)
          .sort((a, b) => a.at - b.at || (a.id < b.id ? -1 : 1));
        if (clients.findIndex((m) => m.id === this.id) >= NetConfig.MaxPlayers - 1) {
          reject(error('full', 'that room is full'));
          return true;
        }
        this.hostId = host.id;
        this.hostSeen = true;
        resolve();
        return true;
      };
      if (check()) return;
      const off = this.transport.onMembers(() => {
        if (check()) {
          off();
          clearTimeout(timer);
        }
      });
      const timer = setTimeout(() => {
        off();
        reject(error('nohost', 'nobody is hosting that code'));
      }, NetConfig.FindHostTimeout * 1000);
    });
  }

  _start() {
    this.flushTimer = setInterval(() => {
      if (!this.closed) this.transport.flush();
    }, 1000 / NetConfig.RelayHz);
    if (this.role === 'host') {
      this.pingTimer = setInterval(() => {
        for (const p of this.peerMap.values()) this.sendEvent(p.id, { t: 'ping', s: performance.now() });
      }, NetConfig.PingSeconds * 1000);
    }
  }

  _onMembers(members) {
    if (this.closed) return;
    const next = new Map();
    const sorted = members.slice().sort((a, b) => (a.at || 0) - (b.at || 0) || (a.id < b.id ? -1 : 1));
    let clients = 0;
    for (const m of sorted) {
      if (!m || m.id === this.id || m.v !== NetConfig.Version) continue;
      if (this.role === 'client' && m.role !== 'host') continue;
      if (this.role === 'host' && m.role !== 'client') continue;
      // the host serves the first three clients; later ones were told the room is full by their own check
      if (this.role === 'host' && ++clients > NetConfig.MaxPlayers - 1) continue;
      const old = this.peerMap.get(m.id);
      next.set(m.id, { id: m.id, name: String(m.name || 'Survivor').slice(0, 24), role: m.role, at: m.at || 0, rtt: old ? old.rtt : null });
    }
    if (this.role === 'client' && this.hostSeen && this.hostId && !next.has(this.hostId)) {
      this.peerMap = next;
      this.listeners.hostLeft.fire();
      return;
    }
    this.peerMap = next;
    this.listeners.peers.fire(this.peers());
  }

  /** The other side(s): every client for the host, the host for a client; in join order. */
  peers() {
    return [...this.peerMap.values()].sort((a, b) => a.at - b.at || (a.id < b.id ? -1 : 1))
      .map((p) => ({ ...p, link: this.transport.linkOf(p.id) }));
  }

  linkOf(id) {
    return this.transport.linkOf(id);
  }

  on(kind, fn) {
    return this.listeners[kind].add(fn);
  }

  _onMessage(from, channel, data) {
    if (this.closed) return;
    if (this.role === 'client' && from !== this.hostId) return;
    if (this.role === 'host' && !this.peerMap.has(from)) return;
    if (channel === 'state') {
      this.listeners.state.fire(from, data);
      return;
    }
    let msg;
    try {
      msg = JSON.parse(DECODER.decode(data));
    } catch {
      return;
    }
    if (!msg || typeof msg.t !== 'string') return;
    if (msg.t === 'ping' && this.role === 'client') {
      this.sendEvent(from, { t: 'pong', s: msg.s });
      return;
    }
    if (msg.t === 'pong' && this.role === 'host') {
      const p = this.peerMap.get(from);
      if (p && Number.isFinite(msg.s)) p.rtt = Math.max(0, performance.now() - msg.s);
      return;
    }
    this.listeners.event.fire(from, msg);
  }

  /** A reliable message to one peer, or '*' from the host to every client. */
  sendEvent(to, msg) {
    if (this.closed) return;
    const data = ENCODER.encode(JSON.stringify(msg));
    if (to === '*') {
      for (const p of this.peerMap.values()) this.transport.send(p.id, 'events', data);
    } else {
      this.transport.send(to, 'events', data);
    }
  }

  /** An unreliable state packet to one peer, or '*' from the host to every client. */
  sendState(to, bytes) {
    if (this.closed) return;
    if (to === '*') {
      for (const p of this.peerMap.values()) this.transport.send(p.id, 'state', bytes);
    } else {
      this.transport.send(to, 'state', bytes);
    }
  }

  /** The measured round trip to a client (host only), ms or null. */
  rttOf(id) {
    const p = this.peerMap.get(id);
    return p ? p.rtt : null;
  }

  /** Relay statistics (messages and bytes this peer has put on the relay). */
  relayStats() {
    const t = this.transport;
    const relay = t.relay || t;
    return { messages: relay.sentMessages || 0, bytes: relay.sentBytes || 0 };
  }

  _lost(reason) {
    if (this.closed) return;
    if (this.role === 'client') this.listeners.hostLeft.fire();
    this.close(reason);
  }

  async close(reason = 'left') {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.pingTimer);
    clearInterval(this.flushTimer);
    try {
      await this.transport.close();
    } catch {
      // the room is being left anyway
    }
    this.listeners.closed.fire(reason);
  }
}
