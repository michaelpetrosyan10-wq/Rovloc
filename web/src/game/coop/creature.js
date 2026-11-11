// creature.js: the Creature in a co-op run. One brain, on the host; a puppet on every client.
//
// Host. The brain's roster (MonsterAI.setRoster) gets a RemotePlayer handle per teammate in play, read from their
// newest pose: root, look, MoveState, duct mode, torch, life state, downs, the locker they hide in. It sees, hears and
// chases whichever player its rules pick (the Roblox brain's choice among a server's players). A teammate's noises
// come as {t: 'noise'} from their page (hearRemote, deduplicated against the host's own copy of a replayed action's
// noise). A catch of a teammate runs in the host's JumpscareHandler; their
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
// inspector -> {t: 'breath', v}). A level scene's stare at a teammate goes through their roster handle (handleOf).
//
// Tunnels (the Tall Man). The host's brain stares back at every player through their pose's yaw and pitch (the
// handle's look). The world packet carries the states the codec knows (Search and HidingResponse go as
// InvestigateNoise, Teleport as Patrol); the exact state and the view contract's action go reliably beside it
// ({t: 'cst', st, a, ago} on every change), so a client's puppet publishes the same {state, speed, poseMode, action,
// actionStartedAt, fade} as the host's Creature. Its poseMode and eye follow the host's rules: hunched by the same
// head-room rule (FloorNav.headroomAlong: at its root and along the way it walks, read from the host's positions
// ahead of the one drawn, then its heading), and the eye at the rig's height for that pose (creatureMetrics,
// Perception.creatureEyeAt). Positions are never interpolated across a hidden sample (a teleport snaps). The host
// relays its events: a teleport's warning to everyone ({t: 'cwarn'}: the flicker and the hiss; the
// torch stutter on its target's page), the grunt before a LookAway ({t: 'cgrunt'}), a chase giving up ({t: 'cgive'}),
// and to their target only a reveal scare ({t: 'creveal'}) and a stare's sting ({t: 'cstare'}). Hiding spots: a
// teammate's Pull ({t: 'hpull'} to the host -> {t: 'hpulled'} to the hider, the brain told it was a pull), a fake-out
// that played ({t: 'hfake'}: safe for everyone now).

import * as THREE from 'three';
import { CFrame } from '../../creature/cframe.js';
import { CreatureConfig } from '../../creature/config.js';
import { HEAD_LEAD, HUNCH_LEAD_SECONDS } from '../../creature/nav.js';
import { creatureEyeAt } from '../../creature/perception.js';
import { NetConfig } from '../../net/config.js';
import { PoseFlags } from '../../net/codec.js';
import { lerpAngle } from './squad.js';

const DEDUPE_RADIUS = 4;
// the states the world packet's codec carries for the Tall Man's new ones (the exact one rides on {t: 'cst'})
const WIRE_STATE = { Search: 'InvestigateNoise', HidingResponse: 'InvestigateNoise', Teleport: 'Patrol' };
const FADE_OUT = 0.6;
const FADE_IN = 0.8;
const SPEED_DAMP = 10;
const SNAP_SQ = 144; // a jump this long between two of the host's samples is a teleport, never a walk
const STILL = 0.05; // studs: a step shorter than this gives no heading
const DEDUPE_SECONDS = 1.5;
const BUFFER = 10;

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
      cstun: (from, msg) => this._onStun(from, msg),
      calert: (from, msg) => this._onAlert(from, msg),
      catch: (from, msg) => this._onCatch(msg),
      catchEnd: (from, msg) => this._onCatchEnd(msg),
      catchAbort: () => this._onCatchAbort(),
      breathReq: (from, msg) => this._onBreathRequest(msg),
      breath: (from, msg) => this._onBreath(from, msg),
      cst: (from, msg) => this._onCreatureState(msg),
      cwarn: (from, msg) => this._onWarn(msg),
      cgrunt: (from, msg) => this._onGrunt(msg),
      cgive: (from, msg) => this._onGiveUp(msg),
      creveal: (from, msg) => this._onReveal(msg),
      cstare: () => this._onStare(),
      hpull: (from, msg) => this._onPull(from, msg),
      hpulled: (from, msg) => this._onPulled(msg),
      hfake: (from, msg) => this._onFakeout(from, msg),
    };
    /** host: the exact state and action last sent; client: the last received ({state, action, actionAt}) */
    this.sentFx = null;
    this.fx = null;
    this.puppetSpeed = 0;
    this.puppetLast = null;
    /** client: the puppet's way of travel (flat unit vector) while it walks, else null */
    this.heading = null;
    /** client: the time (performance.now() seconds) of the host's state the puppet is drawn at */
    this.sampleTime = 0;
    this.clearance = Infinity;
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
      this._relayEvents(c);
      return;
    }
    // client: the puppet
    this.buffer = [];
    this.state = null;
    set(service, 'tick', () => this._puppetTick());
    set(service, 'snapshot', () => this._snapshot());
    set(service, 'viewState', () => this._viewState());
    set(c, 'getState', () => (this.state ? this._exactState(this.state.state) : 'Dormant'));
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
    set(c, 'registerLockerInspector', (fn) => {
      this.localInspector = typeof fn === 'function' ? fn : null;
    });
    this.localInspector = service.lockerInspector;
    // the local noise goes to the host's brain
    const offNoise = this.env.onNoise((n) => this._forwardNoise(n));
    this.restore.push(offNoise);
  }

  /** Host: the brain's Tall Man events, to the pages they concern. */
  _relayEvents(c) {
    const service = c.service;
    const coop = this.coop;
    const slotOf = (player) => {
      if (!player) return -1;
      if (player === c.PLAYER) return coop.me ? coop.me.slot : -1;
      return player.member ? player.member.slot : -1;
    };
    const offs = [
      service.teleportWarning.connect((spot, target, seconds) => coop.broadcast({ t: 'cwarn', p: vec(spot), s: seconds, tg: slotOf(target) })),
      service.grunted.connect((position) => coop.broadcast({ t: 'cgrunt', p: vec(position) })),
      service.gaveUp.connect((player, position) => coop.broadcast({ t: 'cgive', p: vec(position), tg: slotOf(player) })),
      service.revealed.connect((target, kind) => {
        if (target && target !== c.PLAYER && target.member) coop.send(target.member.id, { t: 'creveal', k: kind });
      }),
      service.stared.connect((player) => {
        if (player && player !== c.PLAYER && player.member) coop.send(player.member.id, { t: 'cstare' });
      }),
    ];
    this.restore.push(() => offs.forEach((off) => off()));
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

  /** The brain's handle of a teammate (a scene's stare at them: acquireScripted's setTarget), or null. */
  handleOf(memberId) {
    const m = this._member(memberId);
    return m && m.pose ? this._handle(m) : null;
  }

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
        return p.flags & PoseFlags.Vent ? 'Vent' : 'OnFoot';
      },
      look: () => {
        const p = pose();
        if (!p) return new THREE.Vector3(0, 0, -1);
        const cp = Math.cos(p.pitch || 0);
        return new THREE.Vector3(-Math.sin(p.yaw) * cp, Math.sin(p.pitch || 0), -Math.cos(p.yaw) * cp);
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
    // the exact state and the action, reliably, whenever they change
    const sent = this.sentFx;
    if (!sent || sent.state !== s.state || sent.action !== s.action || sent.actionAt !== s.actionStartedAt) {
      this.sentFx = { state: s.state, action: s.action, actionAt: s.actionStartedAt };
      this.coop.broadcast({ t: 'cst', st: s.state, a: s.action, ago: Math.max(0, c.service.now() - s.actionStartedAt) });
    }
    return { present: true, hidden: s.hidden, inVent: s.inVent, awake: s.awake, x: s.position.x, y: s.position.y,
      z: s.position.z, yaw: Math.atan2(-look.x, -look.z), state: WIRE_STATE[s.state] || s.state, pose: s.pose, level: s.levelId,
      target };
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
    this.sampleTime = at;
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
    // a teleport: never drawn sliding from where it was (it moves while hidden: no interpolation across a hidden sample)
    if (jump || ((a.hidden || z.hidden) && (a.x - z.x) ** 2 + (a.z - z.z) ** 2 > 1)) return { ...z, teleport: true };
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
    const state = this._exactState(s.state);
    if (state !== this.lastState) {
      const previous = this.lastState;
      this.lastState = state;
      service.state = state;
      service.stateChanged.fire(state, previous);
    }
    // the contract's speed (a snap reads as still) and its way of travel
    const now = this.env.now();
    if (this.puppetLast && !moved) {
      const dt = Math.max(1e-3, now - this.puppetLast.t);
      const dx = at.x - this.puppetLast.x;
      const dz = at.z - this.puppetLast.z;
      const step = Math.hypot(dx, dz);
      this.puppetSpeed += (step / dt - this.puppetSpeed) * Math.min(1, dt * SPEED_DAMP);
      if (step > STILL) this.heading = new THREE.Vector3(dx / step, 0, dz / step);
    } else {
      this.puppetSpeed = 0;
      this.heading = null;
    }
    if (this.puppetSpeed < 0.05) {
      this.puppetSpeed = 0;
      this.heading = null;
    }
    this.puppetLast = { x: at.x, z: at.z, t: now };
    // the head room, by the host's hunch rule every tick (FloorNav.headroomAlong): at its root and along the way it
    // walks, its head's lead plus what its pace covers while it bends
    const nav = s.level && service._nav ? service._nav(s.level) : null;
    this.clearance = nav ? nav.headroomAlong(at, this._routeAhead(at), this.puppetSpeed) : Infinity;
  }

  /**
   * Client: the way the puppet walks next, for the hunch's look-ahead (the host's planned route is not sent): the
   * host's positions newer than the one drawn (the buffer runs InterpDelay ahead of it, up to a hidden sample or a
   * teleport), then on along its heading as far as the look-ahead reaches. Empty while it stands still.
   * @param {THREE.Vector3} at the puppet's root
   */
  _routeAhead(at) {
    const out = [];
    let last = at;
    let dir = this.heading;
    for (const e of this.buffer) {
      if (e.t <= this.sampleTime || !e.s) continue;
      if (e.s.hidden) break;
      const dx = e.s.x - last.x;
      const dz = e.s.z - last.z;
      const d2 = dx * dx + dz * dz;
      if (d2 > SNAP_SQ) break;
      if (d2 <= STILL * STILL) continue;
      const d = Math.sqrt(d2);
      dir = new THREE.Vector3(dx / d, 0, dz / d);
      last = new THREE.Vector3(e.s.x, at.y, e.s.z);
      out.push(last);
    }
    if (dir && this.puppetSpeed > 0) {
      out.push(last.clone().addScaledVector(dir, HEAD_LEAD + this.puppetSpeed * HUNCH_LEAD_SECONDS));
    }
    return out;
  }

  /** The host's exact state: the reliable one when it agrees with the packet's (the codec's coarser) state. */
  _exactState(wire) {
    const fx = this.fx;
    if (fx && (WIRE_STATE[fx.state] || fx.state) === wire) return fx.state;
    return wire;
  }

  /** Client: the view contract from the host's state ({state, speed, poseMode, action, actionStartedAt, fade}). */
  _viewState() {
    const s = this.state;
    const fx = this.fx;
    const now = this.env.now();
    const state = s ? this._exactState(s.state) : 'Dormant';
    const action = fx && s && fx.state === state ? fx.action : null;
    const actionStartedAt = action ? fx.actionAt : 0;
    let fade = !s || s.hidden ? 0 : 1;
    if (action === 'FadeOut') fade = Math.max(0, 1 - (now - actionStartedAt) / FADE_OUT);
    else if (action === 'FadeIn' && s && !s.hidden) fade = Math.min(1, (now - actionStartedAt) / FADE_IN);
    let poseMode = 'Biped';
    if (state === 'Stunned') poseMode = 'Stunned';
    else if ((s && s.pose === 'Hunched') || this.clearance < CreatureConfig.HunchBelow) poseMode = 'Hunched';
    return { state, speed: this.puppetSpeed, poseMode, action, actionStartedAt, fade };
  }

  _snapshot() {
    const c = this._creature();
    const s = this.state;
    const body = c.service.body;
    const position = body.getPosition();
    const view = this._viewState();
    // the host's eye: the rig's eye height for the pose it stands in (hunched under a low lintel), 0.6 forward
    const eye = creatureEyeAt(body.getCFrame(), view.poseMode, c.service.metrics ? c.service.metrics.eyeHeights : undefined);
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
      awake: !!s && s.awake,
      catching: !!this.catching,
      pacing: null,
      position,
      eye,
      ...view,
    };
  }

  // ---------------------------------------------------------------------------------------------------- Tall Man relays

  _onCreatureState(msg) {
    if (!this.coop.isClient()) return;
    this.fx = { state: msg.st, action: msg.a || null, actionAt: this.env.now() - (Number.isFinite(msg.ago) ? msg.ago : 0) };
  }

  _onWarn(msg) {
    const c = this._creature();
    if (!c || !this.coop.isClient() || !Array.isArray(msg.p)) return;
    const spot = new THREE.Vector3(msg.p[0], msg.p[1], msg.p[2]);
    const mine = !!this.coop.me && msg.tg === this.coop.me.slot;
    if (c.warnLocal) c.warnLocal(spot, msg.s, mine);
    if (c.events && c.events.teleportWarning) c.events.teleportWarning.fire(spot, mine, msg.s);
  }

  _onGrunt(msg) {
    const c = this._creature();
    if (!c || !this.coop.isClient() || !Array.isArray(msg.p)) return;
    if (c.events && c.events.grunted) c.events.grunted.fire(new THREE.Vector3(msg.p[0], msg.p[1], msg.p[2]));
  }

  _onGiveUp(msg) {
    const c = this._creature();
    if (!c || !this.coop.isClient() || !Array.isArray(msg.p)) return;
    const mine = !!this.coop.me && msg.tg === this.coop.me.slot;
    if (c.events && c.events.gaveUp) c.events.gaveUp.fire(new THREE.Vector3(msg.p[0], msg.p[1], msg.p[2]), mine);
  }

  _onReveal(msg) {
    const c = this._creature();
    if (!c) return;
    if (c.reveal) c.reveal(msg.k || 'Teleport');
    if (c.events && c.events.revealed) c.events.revealed.fire(msg.k || 'Teleport');
  }

  _onStare() {
    const c = this._creature();
    if (c && c.events && c.events.stared) c.events.stared.fire();
  }

  /** A Pull on spot `id` from this page (its player at `from`): applied here on the host, else asked of it. */
  requestPull(id, from) {
    if (this.coop.isHost()) this._onPull(this.coop.localId, { id, f: vec(from) });
    else this.coop.toHost({ t: 'hpull', id, f: vec(from) });
  }

  /** Host: someone pulls the hider out of `msg.id`: the hider's page throws them out; the brain hears it was a pull. */
  _onPull(from, msg) {
    if (!this.coop.isHost() || typeof msg.id !== 'string') return;
    const c = this._creature();
    const game = this.game;
    const at = Array.isArray(msg.f) ? new THREE.Vector3(msg.f[0], msg.f[1], msg.f[2]) : null;
    if (game.lockers && game.lockers.occupiedId() === msg.id) {
      if (c && c.service) c.service.notePulled(c.PLAYER);
      game.lockers.pulledOut(msg.id, at);
      return;
    }
    const hider = this.coop.squad.list().find((m) => !m.local && m.lockerId === msg.id);
    if (!hider || hider.id === from) return;
    if (c && c.service) c.service.notePulled(this._handle(hider));
    this.coop.send(hider.id, { t: 'hpulled', id: msg.id, f: msg.f });
  }

  _onPulled(msg) {
    const lockers = this.game.lockers;
    if (!lockers || typeof msg.id !== 'string') return;
    lockers.pulledOut(msg.id, Array.isArray(msg.f) ? new THREE.Vector3(msg.f[0], msg.f[1], msg.f[2]) : null);
  }

  /** A fake-out played in a spot on this page: it is safe for the whole squad now. */
  shareHide(ev, data) {
    if (ev !== 'fakeout' || !data || typeof data.id !== 'string') return;
    if (this.coop.isHost()) this.coop.broadcast({ t: 'hfake', id: data.id });
    else this.coop.toHost({ t: 'hfake', id: data.id });
  }

  _onFakeout(from, msg) {
    const lockers = this.game.lockers;
    if (!lockers || typeof msg.id !== 'string') return;
    lockers.remoteFakeout(msg.id);
    if (this.coop.isHost()) {
      for (const m of this.coop.squad.list()) if (!m.local && m.id !== from) this.coop.send(m.id, { t: 'hfake', id: msg.id });
    }
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

  endRun() {
    if (this.catching) this._onCatchAbort();
    this.buffer = [];
    this.state = null;
    this.lastState = 'Dormant';
    this.fx = null;
    this.sentFx = null;
    this.puppetLast = null;
    this.puppetSpeed = 0;
    this.heading = null;
    this.clearance = Infinity;
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
