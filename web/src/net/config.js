// config.js: the co-op network's fixed settings. The page makes no request at all until the player presses HOST or
// JOIN; from then on only to the one Supabase project (Realtime: presence + broadcast over its WebSocket) and the two
// STUN servers (WebRTC's address discovery). No TURN: a pair WebRTC cannot join directly talks through the Realtime
// channel instead (the relay).

/** The Supabase project used for Rovloc's rooms (Realtime only: no tables, no auth). */
export const SupabaseProject = Object.freeze({
  url: 'https://pywkvjldlozftfutepbr.supabase.co',
  /** The publishable key: public by design, safe in the client. */
  key: 'sb_publishable_7K1YbqGpa2hWrpypbQscZQ_jsaph-vo',
});

/** The Realtime WebSocket endpoint of the project (realtime-js appends /websocket and the protocol version). */
export function realtimeEndpoint(url = SupabaseProject.url) {
  return `${url.replace(/^http/, 'ws')}/realtime/v1`;
}

/** STUN only (address discovery); no TURN relay of our own. */
export const IceServers = Object.freeze([
  { urls: 'stun:stun.l.google.com:19302' },
  { urls: 'stun:stun.cloudflare.com:3478' },
]);

export const NetConfig = Object.freeze({
  /** Protocol version: peers with another version cannot share a room. */
  Version: 1,
  /** Room code length and alphabet (no 0 / O / 1 / I). */
  CodeLength: 5,
  CodeAlphabet: 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
  /** Realtime channel name prefix: rovloc-room-<CODE>. */
  ChannelPrefix: 'rovloc-room-',
  MaxPlayers: 4,
  /** Seconds a direct WebRTC link may take before that peer talks through the relay. */
  DirectTimeout: 8,
  /** Pose / world state packets per second (client -> host, host -> clients). */
  StateHz: 15,
  /** Relay batches per second (one message per sender per batch). */
  RelayHz: 10,
  /** A relayed state packet is sent whole every this many batches (the rest are deltas). */
  RelayKeyframeEvery: 10,
  /** Unacknowledged relayed events are sent again after this many seconds. */
  RelayResendSeconds: 1,
  /** Ping period (host -> each client), seconds. */
  PingSeconds: 2,
  /** Interpolation delay for remote poses and the Creature (seconds). */
  InterpDelay: 0.1,
  /** Seconds the Realtime connection may take before multiplayer is declared unreachable. */
  ConnectTimeout: 12,
  /** Seconds a joiner waits for the room's host to show up in presence. */
  FindHostTimeout: 8,
  /** Seconds a member missing from presence is still counted in the room (a network blip is not a leave). */
  PresenceGrace: 5,
});
