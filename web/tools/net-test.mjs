// net-test.mjs: unit tests of the co-op network layer in Node (no browser): the packet codec and the relay's delta
// coding, the relay transport through the local test relay (presence, reliable ordered events with acknowledgements
// and resends, state packets, a host leaving), and SupabaseChannel driven through the real @supabase/realtime-js
// client against a mocked Realtime server socket (the Phoenix join / presence / binary broadcast frames the service
// sends, built with realtime-js's own serializer layout).
//
//   node tools/net-test.mjs            exit code 1 on any failure

import { startRelay } from './coop-relay.mjs';
import { decodePacket, deltaDecode, deltaEncode, encodePosePacket, encodeWorldPacket, PoseFlags } from '../src/net/codec.js';
import { normalizeRoomCode, newRoomCode } from '../src/net/code.js';
import { LocalRelayChannel } from '../src/net/localRelay.js';
import { RelayTransport } from '../src/net/transport.js';
import { SupabaseChannel } from '../src/net/supabase.js';
import { Session } from '../src/net/session.js';
import { NetConfig } from '../src/net/config.js';

const failures = [];
function check(name, ok, detail) {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail !== undefined ? ` ${JSON.stringify(detail)}` : ''}`);
  if (!ok) failures.push(name);
}
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms = 4000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (fn()) return true;
    await wait(10);
  }
  return !!fn();
}

// ------------------------------------------------------------------------------------------------ codes and packets
{
  const codes = new Set();
  let valid = true;
  for (let i = 0; i < 500; i++) {
    const c = newRoomCode();
    codes.add(c);
    if (!/^[A-HJ-NP-Z2-9]{5}$/.test(c) || normalizeRoomCode(c.toLowerCase()) !== c) valid = false;
  }
  check('room codes: 5 characters, no 0 / O / 1 / I, typed in any case', valid && codes.size > 450, codes.size);
  check('room codes: look-alikes and bad lengths are refused', normalizeRoomCode('AB0CD') === null &&
    normalizeRoomCode('ABCD') === null && normalizeRoomCode(' ab-cde ') === 'ABCDE');

  const pose = { x: -776.3, y: 3.5, z: 38.25, yaw: 5.9, pitch: -0.4, moveState: 'Crouching', life: 'Downed',
    flags: PoseFlags.Torch | PoseFlags.Carrying, held: 'Flask', oxygen: 0.5, stamina: 0.25, battery: 1, health: 0.01,
    level: 'Level1_Hallways' };
  const bytes = encodePosePacket(7, pose);
  const back = decodePacket(bytes);
  const p = back.pose;
  check('pose packet: 26 bytes, round trip within quantisation', bytes.length === 26 && back.kind === 1 && back.seq === 7 &&
    Math.abs(p.x - pose.x) < 0.02 && Math.abs(p.z - pose.z) < 0.02 && Math.abs(p.yaw - pose.yaw) < 1e-3 &&
    Math.abs(p.pitch - pose.pitch) < 1e-3 && p.moveState === 'Crouching' && p.life === 'Downed' && p.held === 'Flask' &&
    p.flags === pose.flags && p.level === 'Level1_Hallways', { length: bytes.length, p });
  const players = [0, 1, 2, 3].map((slot) => ({ slot, pose: { ...pose, x: pose.x + slot } }));
  const creature = { present: true, hidden: false, inVent: true, awake: true, x: 10, y: 20, z: 30, yaw: 1, state: 'WallChase',
    pose: 'Quadruped', level: 'Level2_ScienceHall', target: 2, grabbed: -1 };
  const world = encodeWorldPacket(9, players, creature);
  const w = decodePacket(world);
  check('world packet: four players and the Creature in 117 bytes (under 300 per player)', world.length === 117 &&
    w.players.length === 4 && w.players[3].slot === 3 && w.creature.state === 'WallChase' && w.creature.target === 2 &&
    w.creature.grabbed === -1 && w.creature.inVent, world.length);
  const moved = encodeWorldPacket(10, players.map((q, i) => (i === 1 ? { slot: 1, pose: { ...q.pose, x: q.pose.x + 0.5 } } : q)), creature);
  const d = deltaEncode(world, moved);
  check('delta: a world packet where one player moved shrinks to a few bytes and decodes exactly',
    d.length < 16 && deltaDecode(world, d).every((b, i) => b === moved[i]), d.length);
  check('delta: a delta against the wrong baseline is refused', deltaDecode(world.slice(0, 50), d) === null);
}

// ------------------------------------------------------------------------------------------------ the local relay
const relay = await startRelay(0);
{
  const a = new LocalRelayChannel(relay.url);
  const b = new LocalRelayChannel(relay.url);
  await a.join('TEST1', { id: 'a', name: 'A', role: 'host', v: 1, at: 1 });
  await b.join('TEST1', { id: 'b', name: 'B', role: 'client', v: 1, at: 2 });
  await until(() => a.members().length === 2 && b.members().length === 2);
  check('local relay: presence lists both members on both sides', a.members().length === 2 && b.members().length === 2);
  const ta = new RelayTransport(a, 'a');
  const tb = new RelayTransport(b, 'b');
  const gotB = [];
  const statesB = [];
  tb.onMessage((from, channel, data) => {
    if (channel === 'events') gotB.push(new TextDecoder().decode(data));
    else statesB.push(data);
  });
  const enc = (s) => new TextEncoder().encode(s);
  for (let i = 0; i < 30; i++) ta.send('b', 'events', enc(`e${i}`));
  const still = { x: 0, y: 0, z: 0, yaw: 0, pitch: 0, moveState: 'Standing', life: 'Alive', flags: 0, held: 'None', oxygen: 1,
    stamina: 1, battery: 1, health: 1, level: 'Lobby' };
  const base = encodeWorldPacket(1, [{ slot: 0, pose: still }], null);
  ta.send('b', 'state', base);
  ta.flush();
  await until(() => gotB.length === 30 && statesB.length === 1);
  check('relay transport: 30 events in one batch arrive in order; the state packet arrives', gotB.join(',') ===
    Array.from({ length: 30 }, (_, i) => `e${i}`).join(',') && statesB.length === 1, { events: gotB.length, states: statesB.length });
  // deltas after the keyframe
  const next = base.slice();
  next[5] ^= 3;
  ta.send('b', 'state', next);
  ta.flush();
  await until(() => statesB.length === 2);
  check('relay transport: the next state is a delta and rebuilds exactly', statesB.length === 2 && statesB[1].every((x, i) => x === next[i]));
  // acknowledgements empty the outbox: b's batch carries its ack
  tb.flush();
  await until(() => ta.peers.get('b').outbox.length === 0);
  check('relay transport: acknowledged events leave the outbox', ta.peers.get('b').outbox.length === 0, ta.peers.get('b').outbox.length);
  // a lost batch is sent again: drop b's listener for one batch by unsubscribing the channel event
  const off = tb.offChannel;
  off();
  ta.send('b', 'events', enc('lost-once'));
  ta.flush();
  await wait(100);
  tb.offChannel = b.on('r', (payload) => tb._receive(payload));
  await wait(NetConfig.RelayResendSeconds * 1000 + 50);
  ta.flush();
  await until(() => gotB.includes('lost-once'));
  check('relay transport: an event lost on the way is resent and arrives once', gotB.filter((x) => x === 'lost-once').length === 1);
  ta.flush();
  await wait(100);
  check('relay transport: a resend of a delivered event is not delivered twice', gotB.filter((x) => x === 'lost-once').length === 1);
  // presence grace: a member gone for less than NetConfig.PresenceGrace never left; longer, they did
  const c = new LocalRelayChannel(relay.url);
  await c.join('TEST1', { id: 'c', name: 'C', role: 'client', v: 1, at: 3 });
  await until(() => b.members().length === 3);
  let flickered = false;
  const offFlicker = b.onMembers((list) => {
    if (!list.some((m) => m.id === 'c')) flickered = true;
  });
  await c.leave();
  await wait(400);
  const rejoin = new LocalRelayChannel(relay.url);
  await rejoin.join('TEST1', { id: 'c', name: 'C', role: 'client', v: 1, at: 3 });
  await wait(300);
  check('presence grace: a member back within the grace never left (a network blip)', !flickered &&
    b.members().some((m) => m.id === 'c'));
  offFlicker();
  await rejoin.leave();
  await ta.close();
  const t1 = Date.now();
  await until(() => b.members().length === 1, (NetConfig.PresenceGrace + 2) * 1000);
  check(`local relay: leaving removes the member after the grace (${((Date.now() - t1) / 1000).toFixed(1)} s)`,
    b.members().length === 1 && b.members()[0].id === 'b' && Date.now() - t1 >= NetConfig.PresenceGrace * 1000 - 200);
  await tb.close();
}

// ------------------------------------------------------------------------------------------------ sessions over the relay
{
  const opts = { service: 'local', relayUrl: relay.url, webrtc: false };
  const host = await Session.host({ ...opts, name: 'Host' });
  const client = await Session.join(host.code, { ...opts, name: 'Client' });
  await until(() => host.peers().length === 1);
  check('session: a client joins the host by code', host.peers().length === 1 && host.peers()[0].name === 'Client' &&
    client.hostId === host.id && host.peers()[0].link === 'relay');
  const got = [];
  client.on('event', (from, msg) => got.push(msg));
  host.sendEvent('*', { t: 'hello', n: 1 });
  await until(() => got.length === 1, 2000);
  check('session: host events reach the client through the relay batch', got.length === 1 && got[0].n === 1);
  await until(() => host.rttOf(client.id) !== null, (NetConfig.PingSeconds + 1) * 1000);
  check('session: the host measures each client\'s ping', host.rttOf(client.id) !== null, host.rttOf(client.id));
  let refused = null;
  try {
    await Session.join('ZZZZZ', { ...opts, name: 'Nobody' });
  } catch (err) {
    refused = err.code;
  }
  check('session: a code nobody hosts is refused (nohost)', refused === 'nohost', refused);
  let left = false;
  client.on('hostLeft', () => {
    left = true;
  });
  await host.close();
  await until(() => left, (NetConfig.PresenceGrace + 2) * 1000);
  check('session: the client hears the host leave', left);
  await client.close();
}

// ------------------------------------------------------------------------------------------------ SupabaseChannel (mocked socket)
/** A mocked Realtime server: Phoenix frames (JSON arrays, binary user broadcasts), presence state / diffs. */
class MockRealtime {
  constructor() {
    /** @type {Map<string, Map<any, {joinRef: string, key: string, meta: any, ref: number}>>} */
    this.topics = new Map();
    this.refs = 0;
    this.urls = [];
    this.frames = { join: 0, track: 0, broadcast: 0, heartbeat: 0 };
  }

  socketClass() {
    const server = this;
    return class MockSocket {
      constructor(url) {
        server.urls.push(String(url));
        this.url = String(url);
        this.readyState = 0;
        this.binaryType = 'arraybuffer';
        setTimeout(() => {
          this.readyState = 1;
          if (this.onopen) this.onopen({});
        }, 5);
      }

      send(data) {
        setTimeout(() => server.handle(this, data), 1);
      }

      close(code = 1000, reason = '') {
        if (this.readyState === 3) return;
        this.readyState = 3;
        server.drop(this);
        setTimeout(() => {
          if (this.onclose) this.onclose({ code, reason, wasClean: true });
        }, 1);
      }
    };
  }

  push(socket, frame) {
    if (socket.readyState !== 1 || !socket.onmessage) return;
    socket.onmessage({ data: typeof frame === 'string' ? frame : frame });
  }

  reply(socket, joinRef, ref, topic, response = {}) {
    this.push(socket, JSON.stringify([joinRef, ref, topic, 'phx_reply', { status: 'ok', response }]));
  }

  state(topic) {
    const out = {};
    for (const e of (this.topics.get(topic) || new Map()).values()) {
      if (e.meta) out[e.key] = { metas: [{ ...e.meta, phx_ref: String(e.ref) }] };
    }
    return out;
  }

  diff(topic, joins, leaves) {
    for (const s of (this.topics.get(topic) || new Map()).keys()) {
      this.push(s, JSON.stringify([null, null, topic, 'presence_diff', { joins, leaves }]));
    }
  }

  drop(socket) {
    for (const [topic, members] of this.topics) {
      const e = members.get(socket);
      if (!e) continue;
      members.delete(socket);
      if (e.meta) this.diff(topic, {}, { [e.key]: { metas: [{ ...e.meta, phx_ref: String(e.ref) }] } });
    }
  }

  handle(socket, data) {
    if (data instanceof ArrayBuffer || ArrayBuffer.isView(data)) {
      this.binary(socket, data instanceof ArrayBuffer ? data : data.buffer);
      return;
    }
    const [joinRef, ref, topic, event, payload] = JSON.parse(data);
    if (topic === 'phoenix' && event === 'heartbeat') {
      this.frames.heartbeat++;
      this.reply(socket, null, ref, topic);
      return;
    }
    if (event === 'phx_join') {
      this.frames.join++;
      if (!this.topics.has(topic)) this.topics.set(topic, new Map());
      const key = payload.config && payload.config.presence ? payload.config.presence.key : '';
      this.topics.get(topic).set(socket, { joinRef, key, meta: null, ref: ++this.refs });
      this.reply(socket, joinRef, ref, topic);
      this.push(socket, JSON.stringify([joinRef, null, topic, 'presence_state', this.state(topic)]));
      return;
    }
    if (event === 'phx_leave') {
      this.reply(socket, joinRef, ref, topic);
      const members = this.topics.get(topic);
      const e = members && members.get(socket);
      if (e) {
        members.delete(socket);
        if (e.meta) this.diff(topic, {}, { [e.key]: { metas: [{ ...e.meta, phx_ref: String(e.ref) }] } });
      }
      return;
    }
    if (event === 'presence') {
      const e = (this.topics.get(topic) || new Map()).get(socket);
      this.reply(socket, joinRef, ref, topic);
      if (!e) return;
      if (payload.event === 'track') {
        this.frames.track++;
        e.meta = payload.payload;
        e.ref = ++this.refs;
        this.diff(topic, { [e.key]: { metas: [{ ...e.meta, phx_ref: String(e.ref) }] } }, {});
      } else if (payload.event === 'untrack' && e.meta) {
        const old = e.meta;
        e.meta = null;
        this.diff(topic, {}, { [e.key]: { metas: [{ ...old, phx_ref: String(e.ref) }] } });
      }
      return;
    }
    this.reply(socket, joinRef, ref, topic);
  }

  /** A user broadcast push (kind 3) relayed to the topic's other sockets as a user broadcast (kind 4). */
  binary(socket, buffer) {
    const view = new DataView(buffer);
    const bytes = new Uint8Array(buffer);
    if (view.getUint8(0) !== 3) return;
    const joinRefLen = view.getUint8(1);
    const refLen = view.getUint8(2);
    const topicLen = view.getUint8(3);
    const eventLen = view.getUint8(4);
    const metaLen = view.getUint8(5);
    const encoding = view.getUint8(6);
    let o = 7;
    const dec = new TextDecoder();
    const joinRef = dec.decode(bytes.subarray(o, o + joinRefLen));
    o += joinRefLen;
    const ref = dec.decode(bytes.subarray(o, o + refLen));
    o += refLen;
    const topicBytes = bytes.subarray(o, o + topicLen);
    const topic = dec.decode(topicBytes);
    o += topicLen;
    const eventBytes = bytes.subarray(o, o + eventLen);
    o += eventLen + metaLen;
    const payload = bytes.subarray(o);
    this.frames.broadcast++;
    const out = new Uint8Array(5 + topicLen + eventLen + payload.length);
    out[0] = 4;
    out[1] = topicLen;
    out[2] = eventLen;
    out[3] = 0;
    out[4] = encoding;
    out.set(topicBytes, 5);
    out.set(eventBytes, 5 + topicLen);
    out.set(payload, 5 + topicLen + eventLen);
    for (const s of (this.topics.get(topic) || new Map()).keys()) {
      if (s !== socket) this.push(s, out.buffer.slice(0));
    }
    if (ref) this.reply(socket, joinRef || null, ref, topic);
  }
}

{
  const server = new MockRealtime();
  const Socket = server.socketClass();
  const a = new SupabaseChannel({ transport: Socket, timeoutSeconds: 4 });
  const b = new SupabaseChannel({ transport: Socket, timeoutSeconds: 4 });
  await a.join('QWERT', { id: 'pa', name: 'Host', role: 'host', v: 1, at: 1 });
  await b.join('QWERT', { id: 'pb', name: 'Client', role: 'client', v: 1, at: 2 });
  await until(() => a.members().length === 2 && b.members().length === 2);
  check('supabase channel: realtime-js joins rovloc-room-<CODE> on the project endpoint with the publishable key',
    server.urls.length === 2 && server.urls.every((u) => u.startsWith('wss://pywkvjldlozftfutepbr.supabase.co/realtime/v1/websocket') &&
      u.includes('apikey=sb_publishable_')) && server.topics.has('realtime:rovloc-room-QWERT'), server.urls[0]);
  check('supabase channel: presence lists both members (meta round trip)', a.members().length === 2 &&
    b.members().some((m) => m.id === 'pa' && m.role === 'host' && m.name === 'Host'), b.members());
  const gotJson = [];
  const gotBin = [];
  b.on('sig', (p) => gotJson.push(p));
  b.on('r', (p) => gotBin.push(p));
  a.broadcast('sig', { to: 'pb', from: 'pa', t: 'offer', sdp: 'v=0' });
  a.broadcast('r', new Uint8Array([1, 2, 3, 250]).buffer);
  await until(() => gotJson.length === 1 && gotBin.length === 1);
  check('supabase channel: a JSON broadcast arrives as JSON', gotJson.length === 1 && gotJson[0].sdp === 'v=0', gotJson[0]);
  check('supabase channel: a binary broadcast arrives as an ArrayBuffer, byte for byte', gotBin.length === 1 &&
    gotBin[0] instanceof ArrayBuffer && new Uint8Array(gotBin[0]).join(',') === '1,2,3,250');
  // the relay transport over Supabase
  const ra = new RelayTransport(a, 'pa');
  const rb = new RelayTransport(b, 'pb');
  const ev = [];
  rb.onMessage((from, channel, data) => ev.push([from, channel, new TextDecoder().decode(data)]));
  ra.send('pb', 'events', new TextEncoder().encode('{"t":"x"}'));
  ra.flush();
  await until(() => ev.length === 1);
  check('supabase channel: relay batches travel as binary broadcasts', ev.length === 1 && ev[0][0] === 'pa' && ev[0][2] === '{"t":"x"}');
  await a.leave();
  await until(() => b.members().length === 1, (NetConfig.PresenceGrace + 2) * 1000);
  check('supabase channel: leaving untracks presence (the other side sees it after the grace)', b.members().length === 1);
  await b.leave();
  // unreachable: a socket that never opens
  class DeadSocket {
    constructor() {
      this.readyState = 0;
      setTimeout(() => {
        this.readyState = 3;
        if (this.onerror) this.onerror(new Event('error'));
        if (this.onclose) this.onclose({ code: 1006, reason: '', wasClean: false });
      }, 5);
    }

    send() {}

    close() {}
  }
  const dead = new SupabaseChannel({ transport: DeadSocket, timeoutSeconds: 1 });
  let code = null;
  const t0 = Date.now();
  try {
    await dead.join('QWERT', { id: 'pc', name: 'C', role: 'client', v: 1, at: 3 });
  } catch (err) {
    code = err.code;
  }
  check('supabase channel: an unreachable service is reported (code unreachable) within the timeout', code === 'unreachable' &&
    Date.now() - t0 < 2500, { code, ms: Date.now() - t0 });
}

await relay.close();
console.log(failures.length ? `\n${failures.length} failure(s)` : '\nall net checks passed');
process.exit(failures.length ? 1 : 0);
