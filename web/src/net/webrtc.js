// webrtc.js: WebRtcTransport, direct WebRTC data channels in a star around the host, on top of a SignalingChannel.
//
// Each client links to the host only (the host to every client). The client makes the offer; offer, answer and ICE
// candidates travel as 'sig' broadcasts addressed to one peer. Two pre-negotiated data channels per link: 'state'
// (id 0, unordered, no retransmits: a lost pose is replaced by the next) and 'events' (id 1, ordered, reliable).
// STUN only (config.js IceServers); host candidates are enough on one network.
//
// A link that is not open within NetConfig.DirectTimeout (timed from when the client first sees the host in presence;
// the side that gives up first tells the other with {t: 'relay'}, the host's own timer running HOST_GRACE longer as a
// backstop) falls back to the relay for that peer: the RelayTransport sharing the signaling channel carries its traffic
// from then on (the peer connection is closed; a link never flips back, so events can never be reordered across the
// two paths). A data channel closing on a live peer falls back the same way. `forceRelay` skips WebRTC altogether (the
// peer never offers or answers, so its links time out into the relay: the tests drive the real fallback with it).
// Events sent while a link is still connecting wait for it; state packets are dropped (the next one supersedes them).

import { IceServers, NetConfig } from './config.js';
import { Listeners, RelayTransport } from './transport.js';

const SIG = 'sig';
const HOST_GRACE = 2000;

class Link {
  constructor(id) {
    this.id = id;
    /** @type {'connecting'|'direct'|'relay'} */
    this.kind = 'connecting';
    /** @type {RTCPeerConnection|null} */
    this.pc = null;
    this.state = null;
    this.events = null;
    this.startedAt = performance.now();
    /** @type {RTCIceCandidateInit[]} */
    this.pendingIce = [];
    this.remoteSet = false;
    /** @type {Uint8Array[]} events waiting for the link to settle */
    this.queue = [];
    this.timer = null;
  }
}

export class WebRtcTransport {
  /**
   * @param {import('./transport.js').SignalingChannel} signaling
   * @param {string} id this peer's id
   * @param {{forceRelay?: boolean, iceServers?: RTCIceServer[], directTimeout?: number}} [opts]
   */
  constructor(signaling, id, opts = {}) {
    this.signaling = signaling;
    this.id = id;
    this.forceRelay = !!opts.forceRelay;
    this.iceServers = opts.iceServers || IceServers;
    this.directTimeout = (opts.directTimeout ?? NetConfig.DirectTimeout) * 1000;
    this.relay = new RelayTransport(signaling, id);
    this.relay.only = new Set();
    /** @type {Map<string, Link>} */
    this.links = new Map();
    this.messages = new Listeners();
    this.linkListeners = new Listeners();
    this.role = 'client';
    this.closed = false;
    this.relay.onMessage((from, channel, data) => {
      const link = this.links.get(from);
      if (link && link.kind === 'relay') this.messages.fire(from, channel, data);
    });
    this.offSig = signaling.on(SIG, (msg) => this._onSignal(msg));
    this.offMembers = signaling.onMembers((members) => this._onMembers(members));
  }

  async connect(room, meta) {
    this.role = meta.role;
    await this.signaling.join(room, meta);
    this._onMembers(this.signaling.members());
  }

  track(meta) {
    this.role = meta.role;
    this.signaling.track(meta);
    this._onMembers(this.signaling.members());
  }

  members() {
    return this.signaling.members();
  }

  onMembers(fn) {
    return this.signaling.onMembers(fn);
  }

  onStatus(fn) {
    return this.signaling.onStatus(fn);
  }

  onMessage(fn) {
    return this.messages.add(fn);
  }

  onLink(fn) {
    return this.linkListeners.add(fn);
  }

  linkOf(peerId) {
    const link = this.links.get(peerId);
    return link ? link.kind : 'connecting';
  }

  /** The peers this one links to: the host for a client, every client for the host. */
  _wanted(members) {
    const out = [];
    for (const m of members) {
      if (!m || m.id === this.id) continue;
      if (this.role === 'host' ? m.role === 'client' : m.role === 'host') out.push(m.id);
    }
    return out;
  }

  _onMembers(members) {
    if (this.closed) return;
    const wanted = new Set(this._wanted(members));
    for (const id of wanted) if (!this.links.has(id)) this._open(id);
    for (const [id, link] of this.links) {
      if (!wanted.has(id)) this._close(link, true);
    }
  }

  _open(id) {
    const link = new Link(id);
    this.links.set(id, link);
    // the client decides first and tells the host ({t: 'relay'}); the host's own timer is the backstop
    const wait = this.role === 'host' ? this.directTimeout + HOST_GRACE : this.directTimeout;
    link.timer = setTimeout(() => {
      if (link.kind === 'connecting') this._fallback(link, 'timeout');
    }, wait);
    if (this.forceRelay || typeof RTCPeerConnection === 'undefined') return;
    // the client offers; the host builds its side when the offer arrives
    if (this.role !== 'host') this._startOffer(link);
  }

  _peer(link) {
    const pc = new RTCPeerConnection({ iceServers: this.iceServers });
    link.pc = pc;
    link.state = pc.createDataChannel('state', { negotiated: true, id: 0, ordered: false, maxRetransmits: 0 });
    link.events = pc.createDataChannel('events', { negotiated: true, id: 1, ordered: true });
    for (const [name, dc] of [['state', link.state], ['events', link.events]]) {
      dc.binaryType = 'arraybuffer';
      dc.onopen = () => this._checkOpen(link);
      dc.onclose = () => {
        if (link.kind === 'direct' && this.links.get(link.id) === link) this._fallback(link, 'closed');
      };
      dc.onmessage = (ev) => {
        if (link.kind !== 'direct') return;
        const data = ev.data instanceof ArrayBuffer ? new Uint8Array(ev.data) : null;
        if (data) this.messages.fire(link.id, name, data);
      };
    }
    pc.onicecandidate = (ev) => {
      if (ev.candidate) this._signal(link.id, { t: 'ice', c: ev.candidate.toJSON() });
    };
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === 'failed' && link.kind === 'connecting') this._fallback(link, 'failed');
    };
    return pc;
  }

  async _startOffer(link) {
    try {
      const pc = this._peer(link);
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      this._signal(link.id, { t: 'offer', sdp: pc.localDescription.sdp });
    } catch (err) {
      console.warn('[net] WebRTC offer failed; using the relay', err);
      this._fallback(link, 'offer');
    }
  }

  async _onSignal(msg) {
    if (this.closed || !msg || msg.to !== this.id || typeof msg.from !== 'string') return;
    const link = this.links.get(msg.from);
    if (!link || link.kind === 'relay') return;
    if (msg.t === 'relay') {
      this._fallback(link, 'peer');
      return;
    }
    if (this.forceRelay || typeof RTCPeerConnection === 'undefined') return;
    try {
      if (msg.t === 'offer' && this.role === 'host') {
        if (link.pc) {
          link.pc.close();
          link.remoteSet = false;
        }
        const pc = this._peer(link);
        await pc.setRemoteDescription({ type: 'offer', sdp: msg.sdp });
        link.remoteSet = true;
        await this._drainIce(link);
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        this._signal(link.id, { t: 'answer', sdp: pc.localDescription.sdp });
      } else if (msg.t === 'answer' && link.pc && this.role !== 'host') {
        await link.pc.setRemoteDescription({ type: 'answer', sdp: msg.sdp });
        link.remoteSet = true;
        await this._drainIce(link);
      } else if (msg.t === 'ice' && msg.c) {
        if (link.pc && link.remoteSet) await link.pc.addIceCandidate(msg.c);
        else link.pendingIce.push(msg.c);
      }
    } catch (err) {
      console.warn('[net] WebRTC signalling failed; using the relay', err);
      this._fallback(link, 'signal');
    }
  }

  async _drainIce(link) {
    const list = link.pendingIce;
    link.pendingIce = [];
    for (const c of list) {
      try {
        await link.pc.addIceCandidate(c);
      } catch {
        // a stale candidate: the others still apply
      }
    }
  }

  _signal(to, body) {
    this.signaling.broadcast(SIG, { ...body, to, from: this.id });
  }

  _checkOpen(link) {
    if (link.kind !== 'connecting') return;
    if (link.state && link.state.readyState === 'open' && link.events && link.events.readyState === 'open') {
      link.kind = 'direct';
      clearTimeout(link.timer);
      for (const data of link.queue) link.events.send(data);
      link.queue = [];
      this.linkListeners.fire(link.id, 'direct');
    }
  }

  _fallback(link, why) {
    if (link.kind === 'relay' || this.links.get(link.id) !== link) return;
    clearTimeout(link.timer);
    link.kind = 'relay';
    if (link.pc) {
      link.pc.onconnectionstatechange = null;
      link.pc.close();
    }
    link.pc = null;
    if (why !== 'peer') this._signal(link.id, { t: 'relay' });
    this.relay.only.add(link.id);
    for (const data of link.queue) this.relay.send(link.id, 'events', data);
    link.queue = [];
    console.info(`[net] ${link.id} talks through the relay (${why})`);
    this.linkListeners.fire(link.id, 'relay');
  }

  _close(link, left) {
    clearTimeout(link.timer);
    if (link.pc) link.pc.close();
    link.pc = null;
    this.links.delete(link.id);
    this.relay.only.delete(link.id);
    this.relay.drop(link.id);
    if (left) this.linkListeners.fire(link.id, 'gone');
  }

  send(to, channel, data) {
    const link = this.links.get(to);
    if (!link) return;
    if (link.kind === 'direct') {
      const dc = channel === 'state' ? link.state : link.events;
      if (dc && dc.readyState === 'open') {
        try {
          dc.send(data);
        } catch (err) {
          console.warn('[net] data channel send failed', err);
        }
      }
    } else if (link.kind === 'relay') {
      this.relay.send(to, channel, data);
    } else if (channel === 'events') {
      link.queue.push(data);
    }
  }

  flush() {
    if (this.relay.only.size) this.relay.flush();
  }

  async close() {
    this.closed = true;
    this.offSig();
    this.offMembers();
    for (const link of [...this.links.values()]) this._close(link, false);
    await this.relay.close();
  }
}
