// supabase.js: SupabaseChannel, the production SignalingChannel: a Supabase Realtime channel `rovloc-room-<CODE>` with
// Presence (who is in the room: each member tracks its PresenceMeta under its own peer id) and Broadcast (events to
// everyone else; self is off). The Phoenix protocol, heartbeats and reconnection are realtime-js's (pinned in
// package.json, bundled into the page). Nothing connects before join(): the page makes no request until the player
// presses HOST or JOIN. The endpoint is absolute and nothing here reads the page's origin, so the same file works from
// rovloc.vercel.app and straight from a Downloads folder (file://, origin "null").
//
// join() resolves once the channel is subscribed and this member tracked; it rejects with code 'unreachable' when
// Realtime cannot be reached within NetConfig.ConnectTimeout (a school filter blocking supabase.co): the socket is then
// shut so nothing keeps retrying in the background.

import { RealtimeClient } from '@supabase/realtime-js';
import { NetConfig, SupabaseProject, realtimeEndpoint } from './config.js';
import { Listeners, PresenceGrace } from './transport.js';

export class SupabaseChannel {
  /**
   * @param {{url?: string, key?: string, transport?: any, timeoutSeconds?: number, graceSeconds?: number}} [opts]
   *   `transport` replaces the WebSocket class (unit tests pass a mock)
   */
  constructor(opts = {}) {
    this.kind = 'supabase';
    this.url = opts.url || SupabaseProject.url;
    this.key = opts.key || SupabaseProject.key;
    this.socketClass = opts.transport || null;
    this.timeoutSeconds = opts.timeoutSeconds ?? NetConfig.ConnectTimeout;
    /** @type {RealtimeClient|null} */
    this.client = null;
    this.channel = null;
    this.meta = null;
    this.memberListeners = new Listeners();
    this.presence = new PresenceGrace(opts.graceSeconds ?? NetConfig.PresenceGrace, () => this.memberListeners.fire(this.members()));
    this.statusListeners = new Listeners();
    /** @type {Map<string, Listeners>} */
    this.eventListeners = new Map();
    this.joined = false;
    this.closed = false;
    /** messages broadcast before the channel joined (sent once it has) */
    this.pending = [];
  }

  /**
   * @param {string} room the room code
   * @param {import('./transport.js').PresenceMeta} meta
   */
  join(room, meta) {
    this.meta = { ...meta };
    const options = {
      params: { apikey: this.key, eventsPerSecond: 40 },
      heartbeatIntervalMs: 15000,
      timeout: this.timeoutSeconds * 1000,
      logLevel: 'error',
      logger: () => {},
      reconnectAfterMs: (tries) => [1000, 2000, 4000, 8000][tries - 1] || 10000,
    };
    if (this.socketClass) options.transport = this.socketClass;
    this.client = new RealtimeClient(realtimeEndpoint(this.url), options);
    const channel = this.client.channel(`${NetConfig.ChannelPrefix}${room}`, {
      config: { broadcast: { self: false, ack: false }, presence: { key: meta.id } },
    });
    this.channel = channel;
    channel.on('presence', { event: 'sync' }, () => this._syncPresence());
    channel.on('broadcast', { event: '*' }, (message) => this._onBroadcast(message));
    return new Promise((resolve, reject) => {
      let settled = false;
      const fail = (detail) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        this._shutdown();
        const err = new Error(`Realtime unreachable (${detail})`);
        err.code = 'unreachable';
        reject(err);
      };
      const timer = setTimeout(() => fail('timeout'), this.timeoutSeconds * 1000);
      channel.subscribe((status, err) => {
        if (this.closed) return;
        if (status === 'SUBSCRIBED') {
          this.joined = true;
          channel.track(this.meta).then(() => {
            this._flushPending();
            if (!settled) {
              settled = true;
              clearTimeout(timer);
              resolve();
            }
            this.statusListeners.fire('open');
          }, (e) => fail(e && e.message ? e.message : 'track'));
        } else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
          this.joined = false;
          if (!settled) fail(err && err.message ? err.message : status);
          else this.statusListeners.fire('reconnecting', status);
        } else if (status === 'CLOSED') {
          this.joined = false;
          if (!settled) fail('closed');
          else this.statusListeners.fire('closed');
        }
      });
    });
  }

  track(meta) {
    this.meta = { ...meta };
    if (this.channel && this.joined) this.channel.track(this.meta).catch(() => {});
  }

  _syncPresence() {
    const state = this.channel ? this.channel.presenceState() : {};
    const list = [];
    for (const [key, metas] of Object.entries(state)) {
      if (!Array.isArray(metas) || !metas.length) continue;
      const m = metas[metas.length - 1];
      const clean = { ...m, id: typeof m.id === 'string' ? m.id : key };
      delete clean.presence_ref;
      list.push(clean);
    }
    this.presence.update(list);
  }

  /** Everyone in the room (presence, with PresenceGrace for a member who just dropped out). */
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

  _onBroadcast(message) {
    const l = message ? this.eventListeners.get(message.event) : null;
    if (l) l.fire(message.payload);
  }

  /** @param {string} event @param {any} payload a JSON value or an ArrayBuffer */
  broadcast(event, payload) {
    if (this.closed) return;
    if (!this.channel || !this.joined) {
      this.pending.push([event, payload]);
      if (this.pending.length > 64) this.pending.shift();
      return;
    }
    this.channel.send({ type: 'broadcast', event, payload }).catch(() => {});
  }

  _flushPending() {
    const list = this.pending;
    this.pending = [];
    for (const [event, payload] of list) this.broadcast(event, payload);
  }

  _shutdown() {
    this.closed = true;
    this.joined = false;
    this.presence.clear();
    const client = this.client;
    const channel = this.channel;
    this.channel = null;
    this.client = null;
    if (client) {
      if (channel) client.removeChannel(channel).catch(() => {});
      client.disconnect().catch(() => {});
    }
  }

  async leave() {
    if (this.closed) return;
    const channel = this.channel;
    if (channel && this.joined) {
      try {
        await channel.untrack();
      } catch {
        // leaving anyway
      }
    }
    this._shutdown();
    this.statusListeners.fire('closed');
  }
}
