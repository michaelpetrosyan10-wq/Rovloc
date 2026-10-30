// index.js: co-op (Roblox's 1-4 player server) for the web game: the Coop system, the hub between the room (net/) and
// the game's systems. Played alone none of it runs: `active` is false, every hook in the game returns at once, and the
// page makes no request.
//
// Authority, as on Roblox. The host's page is the server: it runs the lobby (ready pads, the vote, the countdown), the
// run's seed and route, the Creature (it sees, hears and chases every player), the objectives' shared progress, the
// doors, grates, traps, pickups and lockers, the airlock, life states, revives, spectating and the results. Each page
// owns its own player's movement (network ownership): it simulates its body and sends its pose and state at StateHz
// (codec.js Pose); it asks the host for everything that touches the shared world (intents: prompts, claims, revives,
// noises, trap snaps) and the host applies them and sends the results to everyone as events. The host sends the world
// state (every player's pose and the Creature) at StateHz; poses are drawn InterpDelay behind.
//
// Modules: actions.js (prompt replication, the actor context, claims), lobby.js (the squad lobby), run.js (life, revive,
// spectating, the airlock, floors, results, leaving, late joins), world.js (the host's level scenes, doors and lights
// mirrored on the clients, the periodic digest), creature.js (the Creature's roster on the host, its puppet on the
// clients, remote catches), avatars.js (teammates' bodies), ui.js (the title's friends panel, the lobby list, the HUD).
//
// Messages arrive on the network's own callbacks and wait in a queue; the game tick takes them first (the Coop system
// is registered first), so every game change happens on the tick like everything else.

import { NetConfig } from '../../net/config.js';
import { decodePacket, encodePosePacket, encodeWorldPacket, PacketKind, PoseFlags } from '../../net/codec.js';
import { Session } from '../../net/session.js';
import { normalizeRoomCode } from '../../net/code.js';
import { GameConfig } from '../config.js';
import { Signal } from '../util.js';
import { Actions } from './actions.js';
import { Avatars } from './avatars.js';
import { CreatureNet } from './creature.js';
import { LobbyNet } from './lobby.js';
import { MechanicsNet } from './mechanics.js';
import { RunNet } from './run.js';
import { Member, Squad } from './squad.js';
import { C } from './strings.js';
import { CoopUi } from './ui.js';
import { WorldNet } from './world.js';

const STATE_EVERY = Math.max(1, Math.round(30 / NetConfig.StateHz));
const LINK_REFRESH = 1;

/**
 * Query flags for tests and debugging (the page's URL): `relay=<ws url>` uses the local test relay instead of Supabase,
 * `relayonly` skips WebRTC for this page (its link falls back to the relay).
 */
function urlOptions() {
  const search = typeof location !== 'undefined' ? location.search : '';
  const relay = /[?&]relay=([^&]+)/.exec(search);
  return {
    relayUrl: relay ? decodeURIComponent(relay[1]) : null,
    forceRelay: /[?&]relayonly\b/.test(search),
  };
}

export class Coop {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Coop';
    this.game = game;
    this.env = game.env;
    /** @type {Session|null} */
    this.session = null;
    /** @type {'host'|'client'|null} */
    this.role = null;
    this.squad = new Squad();
    /** @type {Member|null} this page's member */
    this.me = null;
    /** the actor of the prompt being replayed (a member id), or null */
    this.actor = null;
    this.queue = [];
    this.tickCount = 0;
    this.poseSeq = 0;
    this.squadDirty = false;
    this.linkClock = 0;
    this.closing = false;
    this.urlOpts = urlOptions();
    /** networking work per tick and the avatars' per frame (ms) */
    this.perf = { ticks: 0, total: 0, max: 0, frames: 0, frameTotal: 0 };
    /** @type {Signal<[]>} the squad record changed */
    this.squadChanged = new Signal();
    /** @type {Record<string, (from: string, msg: any) => void>} */
    this.handlers = {};
    this.actions = new Actions(this);
    this.lobbyNet = new LobbyNet(this);
    this.runNet = new RunNet(this);
    this.worldNet = new WorldNet(this);
    this.creatureNet = new CreatureNet(this);
    this.mechanics = new MechanicsNet(this);
    this.avatars = new Avatars(this);
    this.ui = new CoopUi(this);
    this.modules = [this.actions, this.lobbyNet, this.runNet, this.worldNet, this.creatureNet, this.mechanics, this.ui];
    for (const m of this.modules) Object.assign(this.handlers, m.handlers || {});
    this.handlers.hello = (from, msg) => this._onHello(from, msg);
    this.handlers.welcome = (from, msg) => this._onWelcome(msg);
    this.handlers.squad = (from, msg) => this._onSquad(msg);
    this.handlers.note = (from, msg) => this.env.toast(C(msg.k, ...(msg.a || [])));
  }

  // ---------------------------------------------------------------------------------------------------- reads

  /** A room is open (hosting or joined). */
  get active() {
    return this.session !== null;
  }

  isHost() {
    return this.role === 'host';
  }

  isClient() {
    return this.role === 'client';
  }

  /** This page's member id (null when alone). */
  get localId() {
    return this.me ? this.me.id : null;
  }

  /** Solo rules apply (alone, or a room with one participant): a Downed player's syringe gets them back up. */
  soloRules() {
    if (!this.active) return true;
    const run = this.game.run;
    const n = run ? this.squad.participants().length : this.squad.list().length;
    return n <= 1;
  }

  /** The members in play this run (deployed, still in the room). */
  participants() {
    return this.squad.participants();
  }

  /** The level this page's player stands on (the lobby before a run). */
  localLevel() {
    return this.game.level || 'Lobby';
  }

  /** The member this page spectates through (null when not spectating). */
  spectateTargetId() {
    return this.runNet.spectating ? this.runNet.spectating.id : null;
  }

  /** The actor of a replay (the member), or this page's member. */
  actorMember() {
    return (this.actor && this.squad.get(this.actor)) || this.me;
  }

  /** The actor's life state during a replay (game.alive()). */
  actorLife() {
    const m = this.actorMember();
    if (!m || m.local) return this.game.life ? this.game.life.state : 'Lobby';
    return m.life;
  }

  /** Whether the replay running now is this page's own action. */
  actorIsLocal() {
    return !this.actor || (this.me !== null && this.actor === this.me.id);
  }

  // ---------------------------------------------------------------------------------------------------- the room

  _sessionOptions(name) {
    const local = this.urlOpts.relayUrl;
    return { name, service: local ? 'local' : 'supabase', relayUrl: local || undefined, forceRelay: this.urlOpts.forceRelay };
  }

  /** Opens a room as its host. Resolves to the room code; rejects with the session's error (err.code). */
  async host(name) {
    if (this.session) await this.leave(false);
    const session = await Session.host(this._sessionOptions(name));
    this._attach(session, 'host');
    const me = new Member({ id: session.id, name: session.name, slot: 0, host: true });
    me.local = true;
    me.link = 'direct';
    this.me = me;
    this.squad.add(me);
    this.lobbyNet.reset();
    this.squadDirty = true;
    this._started();
    return session.code;
  }

  /** Joins a room by its code. Rejects with err.code: 'badcode', 'unreachable', 'nohost', 'full', 'version'. */
  async join(code, name) {
    const clean = normalizeRoomCode(code);
    if (!clean) {
      const err = new Error('bad code');
      err.code = 'badcode';
      throw err;
    }
    if (this.session) await this.leave(false);
    const session = await Session.join(clean, this._sessionOptions(name));
    this._attach(session, 'client');
    this.welcomed = false;
    session.sendEvent(session.hostId, { t: 'hello', name: session.name });
    return clean;
  }

  _attach(session, role) {
    this.session = session;
    this.role = role;
    this.closing = false;
    this.queue = [];
    session.on('event', (from, msg) => this.queue.push({ from, msg }));
    session.on('state', (from, bytes) => this.queue.push({ from, bytes }));
    session.on('peers', () => this.queue.push({ peers: true }));
    session.on('link', () => {
      this.squadDirty = true;
    });
    session.on('hostLeft', () => this.queue.push({ hostLeft: true }));
    session.on('closed', (reason) => {
      if (!this.closing && this.session === session) this.queue.push({ closed: reason });
    });
  }

  _started() {
    for (const m of this.modules) if (m.sessionStarted) m.sessionStarted();
    this.creatureNet.install();
    if (this.game.menu) this.game.menu.restoreButtons();
  }

  /**
   * Leaves the room. `toTitle`: back to the title screen (the run, if any, is dropped without results, as leaving a
   * Roblox server does).
   */
  async leave(toTitle = true, reason = null) {
    const session = this.session;
    if (!session) return;
    this.closing = true;
    for (const m of this.modules) if (m.sessionEnding) m.sessionEnding(reason);
    this.session = null;
    this.role = null;
    this.queue = [];
    this.avatars.clear();
    this.squad.clear();
    this.me = null;
    this.actor = null;
    this.creatureNet.uninstall();
    await session.close('left');
    if (this.game.menu) this.game.menu.restoreButtons();
    if (toTitle) this.runNet.backToTitle(reason);
  }

  // ---------------------------------------------------------------------------------------------------- sending

  /** A reliable message: to the host (client), or to one member / every client ('*') from the host. */
  send(to, msg) {
    if (this.session) this.session.sendEvent(to, msg);
  }

  /** A client's message to the host. */
  toHost(msg) {
    if (this.session && this.isClient()) this.session.sendEvent(this.session.hostId, msg);
  }

  /** The host's message to every client. */
  broadcast(msg) {
    if (this.session && this.isHost()) this.session.sendEvent('*', msg);
  }

  /** Host: a message to every client and handled here too (the host is a player like the others). */
  everyone(msg) {
    this.broadcast(msg);
    const fn = this.handlers[msg.t];
    if (fn) fn(this.localId, msg);
  }

  /** A message to one member: sent, or handled here when it is this page's. */
  toMember(id, msg) {
    if (this.me && id === this.me.id) {
      const fn = this.handlers[msg.t];
      if (fn) fn(id, msg);
    } else this.send(id, msg);
  }

  // ---------------------------------------------------------------------------------------------------- receiving

  _drain() {
    const list = this.queue;
    this.queue = [];
    for (const item of list) {
      try {
        if (item.hostLeft) this._hostLeft();
        else if (item.closed) this._connectionLost();
        else if (item.peers) this._onPeers();
        else if (item.bytes) this._onState(item.from, item.bytes);
        else this._onEvent(item.from, item.msg);
      } catch (err) {
        console.error('[coop] message failed', item.msg ? item.msg.t : 'state', err);
      }
      if (!this.session) return;
    }
  }

  _onEvent(from, msg) {
    if (this.isClient() && !this.welcomed && msg.t !== 'welcome') return;
    const fn = this.handlers[msg.t];
    if (fn) fn(from, msg);
  }

  _onState(from, bytes) {
    const packet = decodePacket(bytes);
    if (!packet) return;
    const t = performance.now() / 1000;
    if (packet.kind === PacketKind.Pose && this.isHost()) {
      const m = this.squad.get(from);
      if (m && !m.local) m.pushPose(packet.pose, t);
    } else if (packet.kind === PacketKind.World && this.isClient()) {
      for (const p of packet.players) {
        const m = this.squad.bySlot(p.slot);
        if (m && !m.local) m.pushPose(p.pose, t);
      }
      this.creatureNet.receive(packet.creature, t);
    }
  }

  _hostLeft() {
    if (!this.isClient()) return;
    this.leave(true, C('Coop.HostLeft'));
  }

  _connectionLost() {
    this.leave(true, this.isClient() ? C('Coop.HostLeft') : C('Coop.ConnectionLost'));
  }

  /** Host: the room's presence changed (someone's link opened, someone left). */
  _onPeers() {
    if (!this.isHost()) return;
    const present = new Set(this.session.peers().map((p) => p.id));
    for (const m of this.squad.list()) {
      if (!m.local && !present.has(m.id)) this._memberLeft(m);
    }
    this.squadDirty = true;
  }

  _memberLeft(member) {
    this.squad.remove(member.id);
    for (const m of this.modules) if (m.memberLeft) m.memberLeft(member);
    this.broadcast({ t: 'note', k: 'Coop.Left', a: [member.name] });
    this.env.toast(C('Coop.Left', member.name));
    this.squadDirty = true;
  }

  /** Host: a client introduced itself. */
  _onHello(from, msg) {
    if (!this.isHost()) return;
    let m = this.squad.get(from);
    if (!m) {
      const slot = this.squad.freeSlot();
      if (slot < 0) return;
      const peer = this.session.peers().find((p) => p.id === from);
      m = new Member({ id: from, name: String(msg.name || (peer && peer.name) || 'Survivor').slice(0, 24), slot });
      this.squad.add(m);
      this.env.toast(C('Coop.Joined', m.name));
      this.broadcast({ t: 'note', k: 'Coop.Joined', a: [m.name] });
    }
    this._refreshLinks();
    const welcome = { t: 'welcome', you: from, squad: this.squad.list().map((x) => x.record()), phase: this.game.phase };
    for (const mod of this.modules) if (mod.welcome) mod.welcome(m, welcome);
    this.send(from, welcome);
    this.squadDirty = true;
  }

  /** Client: the host took us in. */
  _onWelcome(msg) {
    if (!this.isClient()) return;
    this.welcomed = true;
    this.squad.applyRecords(msg.squad, msg.you);
    this.me = this.squad.get(msg.you);
    if (this.me) this.me.local = true;
    this._started();
    this.avatars.sync(this.squad.list());
    for (const mod of this.modules) if (mod.welcomed) mod.welcomed(msg);
    this.squadChanged.fire();
  }

  /** Client: the host's squad record. */
  _onSquad(msg) {
    if (!this.isClient()) return;
    const [, left] = this.squad.applyRecords(msg.m, this.localId);
    this.me = this.squad.get(this.localId) || this.me;
    for (const m of left) for (const mod of this.modules) if (mod.memberLeft) mod.memberLeft(m);
    this.avatars.sync(this.squad.list());
    this.squadChanged.fire();
  }

  _refreshLinks() {
    if (!this.isHost() || !this.session) return;
    for (const p of this.session.peers()) {
      const m = this.squad.get(p.id);
      if (!m) continue;
      const rtt = this.session.rttOf(p.id);
      const ping = rtt === null ? null : Math.round(rtt);
      if (m.link !== p.link || m.ping !== ping) {
        m.link = p.link;
        m.ping = ping;
        this.squadDirty = true;
      }
    }
  }

  /** Host: marks the squad record as changed (sent once, at the end of the tick). */
  touch() {
    this.squadDirty = true;
  }

  _flushSquad() {
    if (!this.squadDirty || !this.isHost()) return;
    this.squadDirty = false;
    this.broadcast({ t: 'squad', m: this.squad.list().map((m) => m.record()) });
    this.avatars.sync(this.squad.list());
    this.squadChanged.fire();
  }

  // ---------------------------------------------------------------------------------------------------- poses

  /** This page's player as a Pose. */
  localPose() {
    const g = this.game;
    const env = this.env;
    const player = env.player;
    const root = player.rootPosition();
    const look = env.look();
    const ms = env.moveState();
    const meters = env.meters();
    let flags = 0;
    if (env.flashlightOn()) flags |= PoseFlags.Torch;
    if (ms === 'Crouching') flags |= PoseFlags.Crouch;
    if (env.mode() === 'Vent') flags |= PoseFlags.Vent;
    if (env.mode() === 'Swim') flags |= PoseFlags.Swim;
    if (ms === 'Underwater') flags |= PoseFlags.Underwater;
    if (ms === 'Hiding' || (g.lockers && g.lockers.occupiedId())) flags |= PoseFlags.Hidden;
    if (g.traps && g.traps.caught) flags |= PoseFlags.Trapped;
    if (ms === 'Grabbed') flags |= PoseFlags.Grabbed;
    if (ms === 'Sprinting') flags |= PoseFlags.Lowered;
    if (g.airlock && g.airlock.inside) flags |= PoseFlags.Airlock;
    if (g.floors && g.floors.carry.lines().length) flags |= PoseFlags.Carrying;
    if (env.hasLock('Jumpscare')) flags |= PoseFlags.Caught;
    if (this.runNet.reviving) flags |= PoseFlags.Reviving;
    if (g.parachute && g.parachute.hasPack && g.parachute.hasPack()) flags |= PoseFlags.Pack;
    let held = 'None';
    if (g.flasks && g.flasks.held) held = g.flasks.held.objective ? 'AcidFlask' : 'Flask';
    else if (flags & PoseFlags.Pack) held = 'Pack';
    else if (flags & PoseFlags.Carrying) held = 'Item';
    return {
      x: root.x, y: root.y, z: root.z, yaw: look.yaw, pitch: look.pitch, moveState: ms, life: g.life ? g.life.state : 'Lobby',
      flags, held, oxygen: meters.oxygen.fraction, stamina: meters.stamina.fraction, battery: meters.battery.fraction,
      health: g.life ? g.life.health / GameConfig.MaxHealth : 1, level: g.run ? g.level || null : 'Lobby',
    };
  }

  _sendState() {
    const pose = this.localPose();
    const t = performance.now() / 1000;
    if (this.me) {
      this.me.pose = pose;
      this.me.poseAt = t;
    }
    this.poseSeq = (this.poseSeq + 1) & 0xffff;
    if (this.isClient()) {
      this.session.sendState(this.session.hostId, encodePosePacket(this.poseSeq, pose));
      return;
    }
    const players = [];
    for (const m of this.squad.list()) {
      if (m.pose) players.push({ slot: m.slot, pose: m.pose });
    }
    this.session.sendState('*', encodeWorldPacket(this.poseSeq, players, this.creatureNet.snapshot()));
  }

  // ---------------------------------------------------------------------------------------------------- system

  tick(dt, now) {
    if (!this.session) return;
    const t0 = performance.now();
    this._tick(dt, now);
    const ms = performance.now() - t0;
    const p = this.perf;
    p.ticks++;
    p.total += ms;
    p.max = Math.max(p.max, ms);
  }

  /** Networking cost per tick so far (ms): {ticks, mean, max} (the tests read it). */
  perfStats() {
    const p = this.perf;
    return { ticks: p.ticks, mean: p.ticks ? p.total / p.ticks : 0, max: p.max, frameMean: p.frames ? p.frameTotal / p.frames : 0 };
  }

  _tick(dt, now) {
    this._drain();
    if (!this.session) return;
    for (const m of this.modules) if (m.tick) m.tick(dt, now);
    this.tickCount++;
    if (this.tickCount % STATE_EVERY === 0 && (this.isHost() || this.welcomed)) this._sendState();
    this.linkClock += dt;
    if (this.linkClock >= LINK_REFRESH) {
      this.linkClock = 0;
      if (this.isHost()) this._refreshLinks();
      else if (this.me && this.session) {
        this.me.link = this.session.linkOf(this.session.hostId);
      }
    }
    this._flushSquad();
  }

  frame(dt) {
    if (!this.session) {
      this.ui.frame(dt);
      return;
    }
    const t0 = performance.now();
    this.avatars.frame(dt);
    this.perf.frames++;
    this.perf.frameTotal += performance.now() - t0;
    for (const m of this.modules) if (m.frame) m.frame(dt);
  }

  beginRun(run) {
    for (const m of this.modules) if (m.beginRun) m.beginRun(run);
  }

  endRun() {
    for (const m of this.modules) if (m.endRun) m.endRun();
  }

  levelActivated(level) {
    for (const m of this.modules) if (m.levelActivated) m.levelActivated(level);
  }

  phaseChanged(phase, previous) {
    for (const m of this.modules) if (m.phaseChanged) m.phaseChanged(phase, previous);
  }
}
