// localRelay.js: LocalRelayChannel, the SignalingChannel of the test tool's local WebSocket relay (tools/coop-relay.mjs):
// the same semantics as Supabase Realtime presence + broadcast, close enough for the co-op tests to run the real game
// pages against each other without the internet. Wire format: one JSON text frame per message.
//
//   client -> relay   {op: 'join', room, meta} · {op: 'track', meta} · {op: 'broadcast', event, payload, bin?}
//                     · {op: 'leave'}
//   relay -> client   {op: 'joined'} · {op: 'presence', members: [meta]} (the whole room on every change)
//                     · {op: 'broadcast', event, payload, bin?} (from someone else in the room)
// A binary payload (ArrayBuffer) travels base64 with bin: true. Leaving, or the socket closing, removes the member
// (this page hears it NetConfig.PresenceGrace later, as with Supabase).

import { NetConfig } from './config.js';
import { Listeners, PresenceGrace } from './transport.js';

export class LocalRelayChannel {
  /** @param {string} url ws://127.0.0.1:<port> @param {{graceSeconds?: number}} [opts] */
  constructor(url, opts = {}) {
    this.kind = 'local';
    this.url = url;
    /** @type {WebSocket|null} */
    this.ws = null;
    this.memberListeners = new Listeners();
    this.presence = new PresenceGrace(opts.graceSeconds ?? NetConfig.PresenceGrace, () => this.memberListeners.fire(this.members()));
    this.statusListeners = new Listeners();
    /** @type {Map<string, Listeners>} */
    this.eventListeners = new Map();
    this.joined = false;
    this.closed = false;
  }

  join(room, meta) {
    return new Promise((resolve, reject) => {
      let settled = false;
      const fail = (detail) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        const err = new Error(`relay unreachable (${detail})`);
        err.code = 'unreachable';
        reject(err);
      };
      const timer = setTimeout(() => {
        fail('timeout');
        if (this.ws) this.ws.close();
      }, NetConfig.ConnectTimeout * 1000);
      const ws = new WebSocket(this.url);
      this.ws = ws;
      ws.onopen = () => ws.send(JSON.stringify({ op: 'join', room, meta }));
      ws.onerror = () => fail('error');
      ws.onclose = () => {
        this.joined = false;
        if (!settled) fail('closed');
        else if (!this.closed) {
          this.closed = true;
          this.statusListeners.fire('closed');
        }
      };
      ws.onmessage = (ev) => {
        let msg;
        try {
          msg = JSON.parse(ev.data);
        } catch {
          return;
        }
        if (msg.op === 'joined') {
          this.joined = true;
          if (!settled) {
            settled = true;
            clearTimeout(timer);
            resolve();
          }
          this.statusListeners.fire('open');
        } else if (msg.op === 'presence') {
          this.presence.update(Array.isArray(msg.members) ? msg.members : []);
        } else if (msg.op === 'broadcast') {
          const l = this.eventListeners.get(msg.event);
          if (l) l.fire(msg.bin ? fromBase64(msg.payload) : msg.payload);
        }
      };
    });
  }

  track(meta) {
    this._send({ op: 'track', meta });
  }

  /** Everyone in the room (with PresenceGrace for a member who just dropped out). */
  members() {
    return this.presence.list();
  }

  onMembers(fn) {
    return this.memberListeners.add(fn);
  }

  onStatus(fn) {
    return this.statusListeners.add(fn);
  }

  on(event, fn) {
    let l = this.eventListeners.get(event);
    if (!l) {
      l = new Listeners();
      this.eventListeners.set(event, l);
    }
    return l.add(fn);
  }

  broadcast(event, payload) {
    if (payload instanceof ArrayBuffer) this._send({ op: 'broadcast', event, payload: toBase64(payload), bin: true });
    else this._send({ op: 'broadcast', event, payload });
  }

  _send(msg) {
    if (this.ws && this.ws.readyState === 1 && !this.closed) this.ws.send(JSON.stringify(msg));
  }

  async leave() {
    if (this.closed) return;
    this._send({ op: 'leave' });
    this.closed = true;
    this.joined = false;
    this.presence.clear();
    if (this.ws) this.ws.close();
    this.statusListeners.fire('closed');
  }
}

function toBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}

function fromBase64(b64) {
  const s = atob(b64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out.buffer;
}
