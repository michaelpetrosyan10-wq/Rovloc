// coop-relay.mjs: the co-op tests' local stand-in for Supabase Realtime (presence + broadcast), a tiny WebSocket relay.
// The game's LocalRelayChannel (src/net/localRelay.js) speaks to it; tools/coop-test.mjs starts it.
//
//   node tools/coop-relay.mjs [--port 8787]      (or import { startRelay } and call it)
//
// Semantics, as Realtime's: a socket joins one room with a presence meta (join); every change of a room's members
// (join, track, leave, the socket closing) sends the whole member list to everyone in it; a broadcast goes to every
// other socket in the room (self: false), in order. Counters (messages and bytes per event) let the tests check how
// frugal the relay traffic is.

import { WebSocketServer } from 'ws';

/**
 * Starts the relay on 127.0.0.1.
 * @param {number} [port] 0 picks a free one
 * @returns {Promise<{port: number, url: string, stats: Record<string, {messages: number, bytes: number}>,
 *   bySender: Record<string, Record<string, {messages: number, bytes: number}>>, rooms: Map<string, Set<any>>,
 *   close: () => Promise<void>}>}
 */
export function startRelay(port = 0) {
  return new Promise((resolve, reject) => {
    const wss = new WebSocketServer({ host: '127.0.0.1', port });
    /** @type {Map<string, Set<any>>} */
    const rooms = new Map();
    const stats = {};
    /** per sender (presence id): {event: {messages, bytes}} */
    const bySender = {};
    const count = (event, bytes, sender) => {
      const s = stats[event] || (stats[event] = { messages: 0, bytes: 0 });
      s.messages++;
      s.bytes += bytes;
      const who = bySender[sender] || (bySender[sender] = {});
      const e = who[event] || (who[event] = { messages: 0, bytes: 0 });
      e.messages++;
      e.bytes += bytes;
    };
    const presence = (room) => {
      const set = rooms.get(room);
      if (!set) return;
      const members = [...set].filter((s) => s.meta).map((s) => s.meta);
      const text = JSON.stringify({ op: 'presence', members });
      for (const s of set) if (s.readyState === 1) s.send(text);
    };
    const leave = (socket) => {
      const room = socket.room;
      if (!room) return;
      socket.room = null;
      const set = rooms.get(room);
      if (!set) return;
      set.delete(socket);
      if (set.size === 0) rooms.delete(room);
      else presence(room);
    };
    wss.on('connection', (socket) => {
      socket.room = null;
      socket.meta = null;
      socket.on('message', (raw) => {
        let msg;
        try {
          msg = JSON.parse(String(raw));
        } catch {
          return;
        }
        if (msg.op === 'join' && typeof msg.room === 'string') {
          leave(socket);
          socket.room = msg.room;
          socket.meta = msg.meta || null;
          if (!rooms.has(msg.room)) rooms.set(msg.room, new Set());
          rooms.get(msg.room).add(socket);
          socket.send(JSON.stringify({ op: 'joined' }));
          presence(msg.room);
        } else if (msg.op === 'track' && socket.room) {
          socket.meta = msg.meta || null;
          presence(socket.room);
        } else if (msg.op === 'broadcast' && socket.room) {
          const text = JSON.stringify({ op: 'broadcast', event: msg.event, payload: msg.payload, bin: !!msg.bin });
          count(String(msg.event), text.length, socket.meta && socket.meta.id ? socket.meta.id : '?');
          for (const s of rooms.get(socket.room) || []) if (s !== socket && s.readyState === 1) s.send(text);
        } else if (msg.op === 'leave') {
          leave(socket);
        }
      });
      socket.on('close', () => leave(socket));
      socket.on('error', () => leave(socket));
    });
    wss.on('listening', () => {
      const actual = wss.address().port;
      resolve({
        port: actual,
        url: `ws://127.0.0.1:${actual}`,
        stats,
        bySender,
        rooms,
        close: () => new Promise((done) => {
          for (const set of rooms.values()) for (const s of set) s.terminate();
          wss.close(() => done());
        }),
      });
    });
    wss.on('error', reject);
  });
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  const i = process.argv.indexOf('--port');
  const relay = await startRelay(i >= 0 ? Number(process.argv[i + 1]) : 8787);
  console.log(`coop-relay: listening on ${relay.url}`);
}
