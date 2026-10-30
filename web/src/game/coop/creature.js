// creature.js: the Creature in a co-op run. One brain, on the host; a puppet on every client.
//
// Host. The brain's roster (MonsterAI.setRoster) gets a RemotePlayer handle per teammate in play, read from their
// newest pose: root, look, MoveState, duct / swim mode, torch, life state, downs, the locker they hide in. It sees, hears
// and chases whichever player its rules pick (the Roblox brain's choice among a server's players). A teammate's noises
// come as {t: 'noise'} from their page (hearRemote, deduplicated against the host's own copy of a replayed action's
// noise), their splash threshold as {t: 'splash'}. A catch of a teammate runs in the host's JumpscareHandler; their
// page gets {t: 'catch'} (the kind, the moment's times, the face, the turn) and plays the moment as its own (lock,
// JumpscareView, the sting), then {t: 'catchEnd', o} applies Down or Execute there, or {t: 'catchAbort'}. Only the caught
// player sees their jumpscare; everyone hears the screech.
// Its state goes out in every world packet (codec.js creature block): position, facing, MonsterState, PoseMode,
// hidden, in a duct, its target's slot.
//
// Client. The local Creature's brain is switched off (its tick and snapshot replaced): the body is placed from the
// host's states, interpolated InterpDelay behind like a teammate, and the rig, its sounds and the panic / EMF senses
// run from that. What the page's own systems ask of it is answered from the host's state (state, target = you, duct,
// hidden); what they tell it is forwarded (stun, alert) or declined (acquireScripted: the scenes are the host's).
// The host also asks a client to run a locker check on its own hiding player ({t: 'breathReq'} -> its registered
// inspector -> {t: 'breath', v}) and to start a pool grab on its swimmer ({t: 'grabReq'}).

import * as THREE from 'three';
import { CFrame } from '../../creature/cframe.js';
import { NetConfig } from '../../net/config.js';
import { PoseFlags } from '../../net/codec.js';
import { lerpAngle } from './squad.js';

const DEDUPE_RADIUS = 4;
const DEDUPE_SECONDS = 1.5;
const BUFFER = 10;
const SWIM_STATES = new Set(['Treading', 'Freestyle', 'Underwater', 'Grabbed']);

const vec = (p) => [p.x, p.y, p.z];

export class CreatureNet {
  /** @param {import('./index.js').Coop} coop */
  constructor(coop) {
    this.coop = coop;
    this.game = coop.game;
    this.env = coop.game.env;
    /** @type {Map<string, any>} member id -> RemotePlayer handle */
    this.handles = new Map();
    this.installed = false;
    this.restore = [];
    /** host: recent noises of its own (dedupe of the clients' copies) */
    this.recent = [];
    /** client: the host's creature states [{t, s}] */
    this.buffer = [];
    this.state = null;
    this.lastState = 'Dormant';
    /** client: the catch being played on this page */
    this.catching = null;
    this.breathRequests = new Map();
    this.nextRequest = 1;
    this.handlers = {
      noise: (from, msg) => this._onNoise(from, msg),
      splash: (from) => this._onSplash(from),
      cstun: (from, msg) => this._onStun(from, msg),
      calert: (from, msg) => this._onAlert(from, msg),
      catch: (from, msg) => this._onCatch(msg),
      catchEnd: (from, msg) => this._onCatchEnd(msg),
      catchAbort: () => this._onCatchAbort(),
      breathReq: (from, msg) => this._onBreathRequest(msg),
      breath: (from, msg) => this._onBreath(from, msg),
      grabReq: () => this._onGrabRequest(),
      grabbed: (from, msg) => this._onGrabbed(from, msg),
      drowned: () => this._onDrowned(),
    };
  }

  /** The W3 Creature object (createCreature's) behind the game's adapter, or null. */
  _creature() {
    const api = this.game.creature;
    return api && api.c ? api.c : null;
  }

  // ---------------------------------------------------------------------------------------------------- install

  install() {
    if (this.installed) return;
    const c = this._creature();
    if (!c || !c.service) return;
    this.installed = true;
    const service = c.service;
    const set = (obj, name, value) => {
      const own = Object.prototype.hasOwnProperty.call(obj, name);
      const old = obj[name];
      obj[name] = value;
      this.restore.push(() => {
        if (own) obj[name] = old;
        else delete obj[name];
      });
    };
    if (this.coop.isHost()) {
      service.setRoster(() => this.roster());
      this.restore.push(() => service.setRoster(null));
      const off = this.env.onNoise((n) => {
        if (n.source === 'player') this.recent.push({ kind: n.kind, p: n.position.clone(), t: this.env.now() });
      });
      this.restore.push(off);
      // the locker inspector: a teammate's locker is checked on their page
      const originalInspector = () => service.lockerInspector;
      set(c, 'registerLockerInspector', (fn) => {
        this.localInspector = typeof fn === 'function' ? fn : null;
      });
      this.localInspector = originalInspector();
      service.registerLockerInspector((lockerId) => this._inspect(lockerId));
      this.restore.push(() => service.registerLockerInspector(this.localInspector));
      set(c, 'registerPoolGrabber', (fn) => {
        this.localGrabber = typeof fn === 'function' ? fn : null;
      });
      this.localGrabber = service.poolGrabber;
      service.registerPoolGrabber((player) => this._grab(player));
      this.restore.push(() => service.registerPoolGrabber(this.localGrabber));
      return;
    }
    // client: the puppet
    this.buffer = [];
    this.state = null;
    set(service, 'tick', () => this._puppetTick());
    set(service, 'snapshot', () => this._snapshot());
    set(c, 'getState', () => (this.state ? this.state.state : 'Dormant'));
    set(c, 'getTarget', () => (this._targetsMe() ? c.PLAYER : null));
    set(c, 'getVentNode', () => null);
    set(c, 'acquireScripted', () => null);
    set(c, 'setScriptedTarget', () => false);
    set(c, 'setSpeedScale', () => {});
    set(c, 'devCommand', () => 'the Creature runs on the host');
    set(c, 'stun', (seconds, from) => {
      if (from) this.coop.toHost({ t: 'cstun', s: seconds, f: vec(from) });
    });
    set(c, 'alert', (position, priority) => {
      if (position) this.coop.toHost({ t: 'calert', p: vec(position), pr: priority });
    });
    // the drowning catch is the host's; if it cannot start there the host says so and the air runs out here
    set(c, 'catchGrabbed', () => {
      this.coop.toHost({ t: 'grabbed', drown: true });
      return true;
    });
    set(c, 'registerLockerInspector', (fn) => {
      this.localInspector = typeof fn === 'function' ? fn : null;
    });
    set(c, 'registerPoolGrabber', (fn) => {
      this.localGrabber = typeof fn === 'function' ? fn : null;
    });
    this.localInspector = service.lockerInspector;
    this.localGrabber = service.poolGrabber;
    // the local noise and splash go to the host's brain
    const offNoise = this.env.onNoise((n) => this._forwardNoise(n));
    this.restore.push(offNoise);
    const offSplash = this.env.onSplashCrossed(() => this.coop.toHost({ t: 'splash' }));
    this.restore.push(offSplash);
  }

  uninstall() {
    if (this.catching) this._onCatchAbort();
    for (const fn of this.restore.splice(0).reverse()) fn();
    this.installed = false;
    this.handles.clear();
    this.buffer = [];
    this.state = null;
  }

  sessionEnding() {
    // the room is closing: the next session installs afresh
  }

  // ---------------------------------------------------------------------------------------------------- host

  /** The brain's remote players: teammates in play with a pose. */
  roster() {
    const out = [];
    for (const m of this.coop.squad.list()) {
      if (m.local || !m.participant || !m.pose) continue;
      out.push(this._handle(m));
    }
    return out;
  }

  _handle(member) {
    let h = this.handles.get(member.id);
    if (h && h.member === member) return h;
    const coop = this.coop;
    const root = new THREE.Vector3();
    const pose = () => member.pose;
    h = {
      member,
      userId: member.slot + 1,
      name: member.name,
      victimFrame: null,
      root: () => (member.playing() && pose() ? root.set(pose().x, pose().y, pose().z).clone() : null),
      rootCFrame: () => {
        const p = pose();
        if (!p || !member.playing()) return null;
        const at = new THREE.Vector3(p.x, p.y, p.z);
        return CFrame.lookAt(at, at.clone().add(new THREE.Vector3(-Math.sin(p.yaw), 0, -Math.cos(p.yaw))));
      },
      lifeState: () => member.life,
      downedCount: () => member.downedCount,
      moveState: () => (pose() ? pose().moveState : 'Standing'),
      mode: () => {
        const p = pose();
        if (!p) return 'OnFoot';
        if (p.flags & PoseFlags.Vent) return 'Vent';
        if (p.flags & PoseFlags.Swim || SWIM_STATES.has(p.moveState)) return 'Swim';
        return 'OnFoot';
      },
      inVent: () => !!pose() && (pose().flags & PoseFlags.Vent) !== 0,
      flashlightOn: () => !!pose() && (pose().flags & PoseFlags.Torch) !== 0,
      lockerId: () => member.lockerId,
      hasLock: (reason) => reason === 'Jumpscare' && member.caught,
      controlLock: () => (member.caught ? 'Jumpscare' : 'None'),
      canCatch: () => member.playing() && !member.caught && coop.game.live(),
      setCaught: (on) => {
        member.caught = !!on;
      },
      turn: (cframe) => {
        h.victimFrame = cframe;
      },
      catchCue: (cue) => {
        const now = this.env.now();
        const f = h.victimFrame;
        coop.send(member.id, {
          t: 'catch', kind: cue.kind, start: cue.startAt - now, end: cue.endsAt - now, face: vec(cue.face),
          at: f ? vec(f.position) : null, yaw: f ? Math.atan2(-f.lookVector.x, -f.lookVector.z) : null,
        });
      },
      catchAbort: () => coop.send(member.id, { t: 'catchAbort' }),
      catchOutcome: (outcome) => coop.send(member.id, { t: 'catchEnd', o: outcome }),
    };
    this.handles.set(member.id, h);
    return h;
  }

  memberLeft(member) {
    const h = this.handles.get(member.id);
    const c = this._creature();
    if (h && c && c.service) c.service.forgetPlayer(h);
    this.handles.delete(member.id);
    for (const [id, req] of this.breathRequests) {
      if (req.member === member.id) {
        req.resolve('Empty');
        this.breathRequests.delete(id);
      }
    }
  }

  /** The Creature's block of the world packet (host). */
  snapshot() {
    const c = this._creature();
    if (!c || !c.service || !this.game.run) return null;
    const s = c.service.snapshot();
    if (!s.running) return null;
    const look = c.service.body.getCFrame().lookVector;
    let target = -1;
    if (s.targetUserId !== null && s.targetUserId !== undefined) target = s.targetUserId - 1;
    const held = c.service.grabbed;
    const grabbed = held ? held.userId - 1 : -1;
    return { present: true, hidden: s.hidden, inVent: s.inVent, awake: s.awake, x: s.position.x, y: s.position.y,
      z: s.position.z, yaw: Math.atan2(-look.x, -look.z), state: s.state, pose: s.pose, level: s.levelId, target, grabbed };
  }

  _member(from) {
    const m = this.coop.squad.get(from);
    return m && m.participant ? m : null;
  }

  _onNoise(from, msg) {
    if (!this.coop.isHost()) return;
    const m = this._member(from);
    const c = this._creature();
    if (!m || !c || !c.service || !Array.isArray(msg.p)) return;
    const position = new THREE.Vector3(msg.p[0], msg.p[1], msg.p[2]);
    const now = this.env.now();
    this.recent = this.recent.filter((r) => now - r.t <= DEDUPE_SECONDS);
    if (this.recent.some((r) => r.kind === msg.k && r.p.distanceTo(position) <= DEDUPE_RADIUS)) return;
    const event = describeNoise(msg, position, now, m.slot + 1);
    c.service.hearRemote(event);
    // a loud noise of theirs ends the Creature's start grace like the host's own (objectives/spawns.js)
    if (this.game.floors) {
      this.game.floors.spawns.hearRemote({ position, kind: event.kind, radius: event.radius, priority: event.priority,
        level: event.levelId });
    }
  }

  _onSplash(from) {
    const m = this._member(from);
    const c = this._creature();
    if (m && c && c.service) c.service.noteSplash(this._handle(m));
  }

  _onStun(from, msg) {
    const c = this._creature();
    if (!this._member(from) || !c || !Array.isArray(msg.f)) return;
    c.stun(msg.s, new THREE.Vector3(msg.f[0], msg.f[1], msg.f[2]));
  }

  _onAlert(from, msg) {
    const c = this._creature();
    if (!this._member(from) || !c || !Array.isArray(msg.p)) return;
    c.alert(new THREE.Vector3(msg.p[0], msg.p[1], msg.p[2]), msg.pr);
  }

  /** The brain's locker inspector: the host's own player locally, a teammate's on their page. */
  _inspect(lockerId) {
    const occupant = this.coop.squad.list().find((m) => !m.local && m.lockerId === lockerId);
    if (!occupant) return this.localInspector ? this.localInspector(lockerId) : 'Empty';
    const id = this.nextRequest++;
    return new Promise((resolve) => {
      this.breathRequests.set(id, { member: occupant.id, resolve });
      this.coop.send(occupant.id, { t: 'breathReq', r: id, locker: lockerId });
    });
  }

  /** Host: whether a teammate's breath check is running on their page (Level 3 keeps quiet meanwhile). */
  checking() {
    return this.breathRequests.size > 0;
  }

  _onBreath(from, msg) {
    const req = this.breathRequests.get(msg.r);
    if (!req || req.member !== from) return;
    this.breathRequests.delete(msg.r);
    req.resolve(msg.v === 'Caught' || msg.v === 'HiddenSafe' ? msg.v : 'Empty');
  }

  /** The brain's pool grabber: the host's swimmer locally, a teammate on their page (granted at once). */
  _grab(player) {
    const h = [...this.handles.values()].find((x) => x === player);
    if (!h) return this.localGrabber ? this.localGrabber(player) : false;
    if (!h.member.playing() || h.member.caught) return false;
    this.coop.send(h.member.id, { t: 'grabReq' });
    return true;
  }

  _onGrabbed(from, msg) {
    const m = this._member(from);
    const c = this._creature();
    if (!m || !c || !c.service) return;
    if (msg.drown && !c.service.catchGrabbed(this._handle(m))) this.coop.send(from, { t: 'drowned' });
  }

  /** Client: the host's Creature could not take this page's drowning swimmer: the air runs out. */
  _onDrowned() {
    const game = this.game;
    this.env.addOxygen(-1e6);
    if (game.life.state === 'Alive') game.life.down('Drowned');
  }

  // ---------------------------------------------------------------------------------------------------- client

  /** Every noise of this page's own body goes to the host (not the copies of replayed actions). */
  _forwardNoise(n) {
    if (!this.coop.isClient() || !this.game.run || n.source !== 'player' || this.coop.actor) return;
    this.coop.toHost({ t: 'noise', k: n.kind, p: vec(n.position), lv: n.level, md: n.medium, vn: n.ventNodeId,
      r: n.radius, pr: n.priority });
  }

  /** A world packet's Creature block arrived. */
  receive(state, t) {
    if (!this.coop.isClient()) return;
    this.buffer.push({ t, s: state });
    if (this.buffer.length > BUFFER) this.buffer.shift();
  }

  _sample() {
    const b = this.buffer;
    if (!b.length) return null;
    const at = performance.now() / 1000 - NetConfig.InterpDelay;
    let i = b.length - 1;
    while (i > 0 && b[i - 1].t > at) i--;
    const next = b[i];
    const prev = i > 0 ? b[i - 1] : null;
    if (!next.s) return null;
    if (!prev || !prev.s || at >= next.t) return { ...next.s, teleport: false };
    const f = Math.min(1, Math.max(0, (at - prev.t) / Math.max(1e-6, next.t - prev.t)));
    const a = prev.s;
    const z = next.s;
    const jump = (a.x - z.x) ** 2 + (a.y - z.y) ** 2 + (a.z - z.z) ** 2 > 144;
    if (jump) return { ...z, teleport: true };
    return { ...(f < 0.5 ? a : z), x: a.x + (z.x - a.x) * f, y: a.y + (z.y - a.y) * f, z: a.z + (z.z - a.z) * f,
      yaw: lerpAngle(a.yaw, z.yaw, f), teleport: false };
  }

  _targetsMe() {
    const s = this.state;
    return !!s && !!this.coop.me && s.target === this.coop.me.slot;
  }

  _puppetTick() {
    const c = this._creature();
    if (!c) return;
    const service = c.service;
    const s = this._sample();
    const was = this.state;
    this.state = s;
    service.running = !!s && !!this.game.run;
    if (!s) return;
    const at = new THREE.Vector3(s.x, s.y, s.z);
    const cf = CFrame.lookAt(at, at.clone().add(new THREE.Vector3(-Math.sin(s.yaw), 0, -Math.cos(s.yaw))));
    const moved = !was || s.teleport || Math.abs(was.x - s.x) + Math.abs(was.z - s.z) > 12;
    if (moved) service.body.placeAt(cf);
    else service.body.setCFrame(cf);
    service.body.setPose(s.pose);
    service.body.setHidden(s.hidden);
    service.creatureLevel = s.level;
    if (s.state !== this.lastState) {
      const previous = this.lastState;
      this.lastState = s.state;
      service.state = s.state;
      service.stateChanged.fire(s.state, previous);
    }
  }

  _snapshot() {
    const c = this._creature();
    const s = this.state;
    const body = c.service.body;
    const position = body.getPosition();
    const eyeLift = { Biped: 3.1, Hunched: 2.2, Quadruped: 1.2, Swim: 0.6 }[body.pose] ?? 3.1;
    return {
      running: !!s && !!this.game.run,
      state: s ? s.state : 'Dormant',
      stateSince: 0,
      reason: 'host',
      pose: body.pose,
      inVent: !!s && s.inVent,
      medium: s && s.inVent ? 'Vent' : 'Floor',
      segment: null,
      hidden: s ? s.hidden : true,
      levelId: s ? s.level : null,
      targetingPlayer: this._targetsMe(),
      targetUserId: null,
      grabbed: !!s && !!this.coop.me && s.grabbed === this.coop.me.slot,
      awake: !!s && s.awake,
      catching: !!this.catching,
      pacing: null,
      position,
      eye: new THREE.Vector3(position.x, position.y + eyeLift, position.z),
    };
  }

  /** The host's Creature caught this page's player: the moment plays here. */
  _onCatch(msg) {
    const c = this._creature();
    if (!c || this.catching) return;
    const env = this.env;
    const now = env.now();
    this.catching = { kind: msg.kind };
    env.lock('Jumpscare');
    if (Array.isArray(msg.at) && Number.isFinite(msg.yaw)) {
      const root = env.rootPosition();
      env.teleport({ position: root, yaw: msg.yaw });
      env.setLook(msg.yaw, 0);
    }
    const face = Array.isArray(msg.face) ? new THREE.Vector3(msg.face[0], msg.face[1], msg.face[2]) : null;
    if (c.service.jumpscareView && face) {
      c.service.jumpscareView.start({ kind: msg.kind, startAt: now + (msg.start || 0), endsAt: now + (msg.end || 0), face });
    }
    this.catching.sting = env.play('JumpscareSting', {});
    if (face) this.catching.screech = env.play('Screech', { position: face });
    if (c.events) c.events.caught.fire(msg.kind);
  }

  _onCatchEnd(msg) {
    const c = this._creature();
    const active = this.catching;
    if (!c || !active) return;
    this.catching = null;
    const outcome = msg.o === 'Down' ? 'Down' : 'Execute';
    const hooks = c.env.catchHooks;
    if (hooks && typeof hooks.apply === 'function') hooks.apply(outcome);
    this.env.unlock('Jumpscare');
    if (c.events) c.events.jumpscareFinished.fire(active.kind, outcome === 'Down' ? 'Downed' : 'Executed');
  }

  _onCatchAbort() {
    const c = this._creature();
    const active = this.catching;
    if (!c || !active) return;
    this.catching = null;
    for (const v of [active.sting, active.screech]) if (v) v.stop(0.15);
    if (c.service.jumpscareView) c.service.jumpscareView.abort();
    this.env.unlock('Jumpscare');
    if (c.events) c.events.jumpscareFinished.fire(active.kind, 'Aborted');
  }

  /** The host's Creature is at the locker this page's player hides in: the breath check runs here. */
  async _onBreathRequest(msg) {
    let verdict = 'Empty';
    try {
      if (this.localInspector) verdict = await this.localInspector(msg.locker);
    } catch (err) {
      console.error('[coop] locker check failed', err);
    }
    this.coop.toHost({ t: 'breath', r: msg.r, v: verdict });
  }

  _onGrabRequest() {
    if (this.localGrabber) this.localGrabber(this._creature() ? this._creature().PLAYER : null);
  }

  endRun() {
    if (this.catching) this._onCatchAbort();
    this.buffer = [];
    this.state = null;
    this.lastState = 'Dormant';
  }
}

/** A teammate's noise in Hearing's shape (creature/env.js onNoise). */
function describeNoise(msg, position, now, userId) {
  return {
    position,
    kind: msg.k,
    radius: Number.isFinite(msg.r) ? msg.r : 30,
    priority: msg.pr || 'Normal',
    medium: msg.md || 'Air',
    levelId: msg.lv || null,
    ventNodeId: msg.vn || null,
    serverTime: now,
    sourceUserId: userId,
  };
}
