// run.js: a co-op run's squad rules (DownedReviveService, SpectatorService, CheckpointAirlockService's squad side,
// the run outcome and MatchResetService), host-authoritative.
//
// Life. Each page's Life owns its own player (damage, traps, drowning, bleeding out are felt where the body is) and
// reports every change ({t: 'life'}); the host keeps the squad's record and decides from it. A teammate going down or
// dying is announced; a dying player's carried objective items are set down where they fell ({t: 'drop'}), as are a
// leaver's.
// Revive. A Downed teammate carries a Revive prompt (hold GameConfig.ReviveHoldSeconds) on every other page, live for
// an Alive player with no control lock while the victim is not being caught. The hold tells the victim who is reviving
// them; completing it asks the host ({t: 'revive'}), which checks both and the distance and has the victim's page get
// up at half health ({t: 'cmd', c: 'revive'}); the reviver's RunStats Revives counts it. Self-revive with a syringe is
// solo only (Life.useSyringe asks soloRules()).
// Spectating. Dead, or left behind by an airlock (Spectating), a player watches their squad: the camera rides a playing
// teammate's eyes (their interpolated pose and look), Q / E (bumpers, the touch arrows) switch, a lost target hands over
// to the next; the HUD says who and why.
// Airlock (host). The checkpoint counts every playing participant: inside when their pose's root or feet stand in the
// volume, the tower or the next level's entry room (the airlock's own test). Waiting starts with the first one in (the
// squad hears the straggler warning), seals when every Alive one is in or at the deadline; the clients' banners follow
// ({t: 'airlock'}). Sealed ({t: 'sealed'}): those outside are left behind (Spectating), the run advances on every
// page, the survivors are paid the floor, and everyone Dead or Spectating gets up at the next floor's entry at half
// health.
// Outcome (host). Continue while someone not yet escaped is Alive (alone: the solo rule, a syringe counts); else the run
// resolves for everyone ({t: 'resolve'}), each page paying its own player from its own stats and outcome. Results end
// when every participant still here pressed Play Again or at the host's timer ({t: 'reset'}).
// Late joiners. A player who joins during a run is put in it as a spectator ({t: 'run'} in the welcome) and gets up at
// the next sealed airlock with the others left behind.

import * as THREE from 'three';
import { PoseFlags } from '../../net/codec.js';
import { GameConfig } from '../config.js';
import { S } from '../strings.js';
import { Palette, el } from '../ui/style.js';
import { C } from './strings.js';

const REVIVE_DISTANCE = 7;
const REVIVE_CHECK_SLACK = 5;
const REVIVE_FRACTION = 0.5;
const RESPAWN_HEALTH = GameConfig.MaxHealth * 0.5;
const ROOT_TO_FEET = 3;
const EYE = { Standing: 1.5, Sprinting: 1.4, Crouching: 0, VentCrawling: -0.6, VentScurrying: -0.6, DownedCrawling: -0.8,
  Treading: 0.4, Freestyle: 0.2, Underwater: -0.6, Hiding: 1.3, Trapped: 1.1, Grabbed: -0.6 };
const SPECTATE_SMOOTH = 12;
/** Seconds a client's lander is held after touching down (the finale's lookback) before their hold ends. */
const LANDING_HOLD = 8;

export class RunNet {
  /** @param {import('./index.js').Coop} coop */
  constructor(coop) {
    this.coop = coop;
    this.game = coop.game;
    this.env = coop.game.env;
    /** @type {Map<string, any>} victim id -> revive prompt */
    this.revivePrompts = new Map();
    this.reviving = null;
    /** victim side: who is reviving this page's player */
    this.beingRevivedBy = null;
    /** @type {import('./squad.js').Member|null} */
    this.spectating = null;
    this.spectateReason = null;
    this.spectateCam = { position: new THREE.Vector3(), quaternion: new THREE.Quaternion(), ready: false };
    this.lateJoin = false;
    /** host: the revive in flight ({victim, by}) until the victim reports getting up */
    this.pendingReviver = null;
    this.landedAt = null;
    this.landingReleased = false;
    this.handlers = {
      life: (from, msg) => this._onLife(from, msg),
      drop: (from, msg) => this._onDrop(msg),
      revive: (from, msg) => this._onRevive(from, msg),
      reviving: (from, msg) => this._onReviving(from, msg),
      beingRevived: (from, msg) => this._onBeingRevived(msg),
      reviveDone: (from, msg) => this._onReviveDone(msg),
      cmd: (from, msg) => this._onCommand(msg),
      airlock: (from, msg) => this._onAirlock(msg),
      sealed: (from, msg) => this._onSealed(msg),
      escaped: (from) => this._onEscaped(from),
      resolve: (from, msg) => this._onResolve(msg),
      playAgain: (from) => this._onPlayAgain(from),
      reset: (from, msg) => this._onReset(msg),
      run: (from, msg) => this._onRun(msg),
    };
    this._buildHud();
    this.game.life.changed.connect((state, previous, cause) => this._localLife(state, previous, cause));
    this.env.onAction('SpectateNext', (phase) => {
      if (phase === 'Begin') this.cycle(1);
    });
    this.env.onAction('SpectatePrev', (phase) => {
      if (phase === 'Begin') this.cycle(-1);
    });
  }

  // ---------------------------------------------------------------------------------------------------- life

  _localLife(state, previous, cause) {
    const coop = this.coop;
    if (!coop.active || !coop.me) return;
    const life = this.game.life;
    if (coop.isClient()) {
      coop.toHost({ t: 'life', s: state, c: cause || '', d: life.downedCount });
      coop.me.life = state;
      coop.me.downedCount = life.downedCount;
      return;
    }
    const me = coop.me;
    me.downedCount = life.downedCount;
    this._lifeChanged(me, me.life, state, cause);
  }

  _onLife(from, msg) {
    if (!this.coop.isHost()) return;
    const m = this.coop.squad.get(from);
    if (!m || typeof msg.s !== 'string') return;
    m.downedCount = Number(msg.d) || 0;
    this._lifeChanged(m, m.life, msg.s, msg.c);
  }

  /** Host: a member's life state changed. */
  _lifeChanged(member, previous, state, cause) {
    const coop = this.coop;
    if (previous === state) return;
    member.life = state;
    if (state !== 'Alive') this._clearReviving(member.id);
    if (member.participant && this.game.run) {
      if (state === 'Downed') this._announce(member, 'Downed.TeammateDown');
      if (state === 'Dead' && previous === 'Downed') this._announce(member, 'Downed.TeammateLost');
      if (state === 'Dead' && member.pose) this._drop(member);
      if ((state === 'Dead' || state === 'Spectating') && this.game.flasks) this.game.flasks.memberGone(member.id);
    }
    coop.touch();
    if (this.game.match) this.game.match.requestEvaluation();
    if (state === 'Alive' && cause === 'Revive' && this.pendingReviver && this.pendingReviver.victim === member.id) {
      const by = this.pendingReviver.by;
      this.pendingReviver = null;
      coop.toMember(by, { t: 'reviveDone', v: member.name });
      coop.toMember(member.id, { t: 'cmd', c: 'revivedBy', by: coop.squad.get(by) ? coop.squad.get(by).name : '' });
    }
  }

  /** Toasts every page but the member's own. */
  _announce(member, key) {
    for (const m of this.coop.squad.list()) {
      if (m.id === member.id) continue;
      if (m.local) this.env.toast(S(key, member.name));
      else this.coop.send(m.id, { t: 'note', k: key, a: [member.name] });
    }
  }

  /** Host: a member's carried items are set down where they stand. */
  _drop(member) {
    const p = member.pose;
    if (!p) return;
    const at = [p.x, p.y - ROOT_TO_FEET, p.z];
    this.coop.everyone({ t: 'drop', id: member.id, at, name: member.name });
  }

  _onDrop(msg) {
    const floors = this.game.floors;
    if (!floors || !Array.isArray(msg.at)) return;
    const n = floors.dropCarried(msg.id, new THREE.Vector3(msg.at[0], msg.at[1], msg.at[2]));
    if (n > 0 && msg.id !== this.coop.localId) this.env.toast(C('Coop.Dropped', msg.name || ''));
  }

  // ---------------------------------------------------------------------------------------------------- revive

  _reviveAnchor(member, out) {
    const pose = member.sample(performance.now() / 1000, {}) || member.pose;
    if (!pose) return null;
    return out.set(pose.x, pose.y - 1.6, pose.z);
  }

  _syncRevivePrompts() {
    const coop = this.coop;
    const game = this.game;
    const want = new Set();
    if (game.run && game.live()) {
      for (const m of coop.squad.list()) {
        if (!m.local && m.participant && m.life === 'Downed') want.add(m.id);
      }
    }
    for (const id of want) {
      if (this.revivePrompts.has(id)) continue;
      const member = coop.squad.get(id);
      const at = new THREE.Vector3();
      const prompt = this.env.addPrompt({
        position: () => this._reviveAnchor(member, at),
        text: S('Prompt.Revive'),
        objectText: member.name,
        holdSeconds: GameConfig.ReviveHoldSeconds,
        distance: REVIVE_DISTANCE,
        requiresLineOfSight: false,
        net: 'local',
        onHoldBegan: () => this._reviveHold(member, true),
        onHoldEnded: () => this._reviveHold(member, false),
        onTriggered: () => this._reviveDone(member),
      });
      this.revivePrompts.set(id, prompt);
    }
    for (const [id, prompt] of this.revivePrompts) {
      if (!want.has(id)) {
        prompt.remove();
        this.revivePrompts.delete(id);
        if (this.reviving === id) this.reviving = null;
        continue;
      }
      const member = coop.squad.get(id);
      const ok = game.life.state === 'Alive' && game.controlLock() === 'None' && !!member && !member.caught &&
        !(member.pose && member.pose.flags & PoseFlags.Caught);
      prompt.setEnabled(ok);
    }
  }

  _reviveHold(member, on) {
    this.reviving = on ? member.id : null;
    const msg = { t: 'reviving', v: member.id, on };
    if (this.coop.isHost()) this._onReviving(this.coop.localId, msg);
    else this.coop.toHost(msg);
  }

  _reviveDone(member) {
    this.reviving = null;
    const msg = { t: 'revive', v: member.id };
    if (this.coop.isHost()) this._onRevive(this.coop.localId, msg);
    else this.coop.toHost(msg);
  }

  _onReviving(from, msg) {
    if (!this.coop.isHost()) return;
    const by = this.coop.squad.get(from);
    if (!by) return;
    this.coop.toMember(msg.v, { t: 'beingRevived', by: by.name, on: !!msg.on });
  }

  _onBeingRevived(msg) {
    this.beingRevivedBy = msg.on ? msg.by : null;
  }

  _clearReviving(victimId) {
    if (this.reviving === victimId) this.reviving = null;
  }

  /** Host: a revive completed on the reviver's page. */
  _onRevive(from, msg) {
    if (!this.coop.isHost() || !this.game.live()) return;
    const coop = this.coop;
    const reviver = coop.squad.get(from);
    const victim = coop.squad.get(msg.v);
    if (!reviver || !victim || !reviver.participant || !victim.participant) return;
    if (reviver.life !== 'Alive' || victim.life !== 'Downed' || victim.caught) return;
    const a = reviver.local ? this.env.rootPosition() : reviver.pose;
    const b = victim.local ? this.env.rootPosition() : victim.pose;
    if (!a || !b) return;
    const d = Math.hypot(a.x - b.x, a.y - b.y, a.z - b.z);
    if (d > REVIVE_DISTANCE + REVIVE_CHECK_SLACK) return;
    this.pendingReviver = { victim: victim.id, by: reviver.id };
    coop.toMember(victim.id, { t: 'cmd', c: 'revive' });
  }

  _onReviveDone(msg) {
    this.game.stats.increment('Revives');
    this.env.toast(S('Revive.YouRevived', msg.v));
  }

  /** The host's word for this page's player. */
  _onCommand(msg) {
    const life = this.game.life;
    if (msg.c === 'revive') {
      if (life.state === 'Downed') life.revive(REVIVE_FRACTION);
    } else if (msg.c === 'revivedBy') {
      this.beingRevivedBy = null;
      if (msg.by) this.env.toast(S('Revive.RevivedBy', msg.by));
    }
  }

  /** DownedHud's status line in a co-op run (null alone). */
  downedStatus() {
    if (!this.coop.active || this.coop.soloRules()) return null;
    if (this.beingRevivedBy) return S('Downed.BeingRevived', this.beingRevivedBy);
    const someone = this.coop.squad.list().some((m) => !m.local && m.participant && m.life === 'Alive' && m.outcome !== 'Escaped');
    return S(someone ? 'Downed.TeammateCanRevive' : 'Downed.NoTeammates');
  }

  // ---------------------------------------------------------------------------------------------------- spectating

  _spectateWanted() {
    const s = this.game.life.state;
    return this.coop.active && !!this.game.run && this.game.live() && (s === 'Dead' || s === 'Spectating');
  }

  _candidates() {
    return this.coop.squad.list().filter((m) => !m.local && m.participant && m.playing() && m.pose);
  }

  /** Switches the spectated teammate (+1 next, -1 previous, wrapping). */
  cycle(direction) {
    if (!this.spectating && !this._spectateWanted()) return;
    const list = this._candidates();
    if (!list.length) {
      this.spectating = null;
      return;
    }
    const i = this.spectating ? list.findIndex((m) => m.id === this.spectating.id) : -1;
    const next = list[(((i < 0 ? 0 : i + direction) % list.length) + list.length) % list.length];
    if (next !== this.spectating) {
      this.spectating = next;
      this.spectateCam.ready = false;
    }
  }

  _startSpectating() {
    const env = this.env;
    this.spectateActive = true;
    env.pushContext('CoopSpectate', 'Spectator');
    env.lock('Spectate');
    const out = this.game.life.state === 'Spectating';
    this.spectateReason = out ? (this.lateJoin ? 'Coop.LateJoin' : 'Spectate.LeftBehind') : 'Spectate.Eliminated';
    this.cycle(1);
    env.setCameraOverride('Spectating', () => this._spectateFrame(), { priority: 3, blendIn: 0.4, blendOut: 0.3 });
  }

  _stopSpectating() {
    if (!this.spectateActive) return;
    const env = this.env;
    this.spectateActive = false;
    this.spectating = null;
    env.setCameraOverride('Spectating', null);
    env.popContext('CoopSpectate');
    env.unlock('Spectate');
  }

  _spectateFrame() {
    const cam = this.spectateCam;
    const m = this.spectating;
    const pose = m ? m.sample(performance.now() / 1000, {}) : null;
    if (pose) {
      const target = _p.set(pose.x, pose.y + (EYE[pose.moveState] ?? 1.5), pose.z);
      _e.set(pose.pitch, pose.yaw, 0, 'YXZ');
      _q.setFromEuler(_e);
      if (!cam.ready) {
        cam.position.copy(target);
        cam.quaternion.copy(_q);
        cam.ready = true;
      } else {
        const k = Math.min(1, (this.lastDt || 1 / 60) * SPECTATE_SMOOTH);
        cam.position.lerp(target, k);
        cam.quaternion.slerp(_q, k);
      }
    } else if (!cam.ready) {
      cam.position.copy(this.env.eye(_p));
      cam.quaternion.copy(this.env.camera().quaternion);
      cam.ready = true;
    }
    return { position: cam.position, quaternion: cam.quaternion };
  }

  // ---------------------------------------------------------------------------------------------------- airlock

  /** Host: the squad's view of the airlock: is anyone playing inside, is every Alive participant inside. */
  airlockSquad(airlock) {
    const env = this.env;
    let anyInside = false;
    let allAliveInside = true;
    let anyPlaying = false;
    for (const m of this.coop.participants()) {
      if (m.outcome === 'Escaped') continue;
      const playing = m.local ? this.game.life.playing() : m.playing();
      if (!playing) continue;
      anyPlaying = true;
      const root = m.local ? env.rootPosition(_p) : m.pose ? _p.set(m.pose.x, m.pose.y, m.pose.z) : null;
      const inside = !!root && airlock.isInside(root);
      m.inAirlock = inside;
      if (inside) anyInside = true;
      const alive = m.local ? this.game.life.state === 'Alive' : m.life === 'Alive';
      if (alive && !inside) allAliveInside = false;
    }
    return { anyInside, allAliveInside, anyPlaying };
  }

  /** Host: the airlock's banner state changed (Waiting / Sealing / idle). */
  airlockChanged(airlock, straggler) {
    const now = this.env.now();
    const msg = { t: 'airlock', ph: airlock.phase, dl: airlock.deadline === null ? null : Math.max(0, airlock.deadline - now),
      lv: airlock.level, st: !!straggler };
    this.coop.broadcast(msg);
    if (straggler) this._stragglerToast(airlock, true);
  }

  _onAirlock(msg) {
    if (!this.coop.isClient()) return;
    const a = this.game.airlock;
    if (!a || this.game.level !== msg.lv) return;
    a.phase = msg.ph;
    a._setDeadline(msg.dl === null ? null : this.env.now() + msg.dl);
    if (msg.st) this._stragglerToast(a, false);
  }

  _stragglerToast(airlock, host) {
    const inside = host ? airlock.isInside() : airlock.inside;
    if (!inside && this.game.life.playing()) this.env.toast(S('Hud.Straggler', GameConfig.StragglerSeconds));
  }

  /** Host: the doors are shut: who made it, who is left, who gets up; then every page moves on (_onSealed). */
  finalizeAirlock(airlock) {
    const from = airlock.level;
    const surv = [];
    const left = [];
    const resp = [];
    for (const m of this.coop.participants()) {
      const playing = m.local ? this.game.life.playing() : m.playing();
      const root = m.local ? this.env.rootPosition(_p) : m.pose ? _p.set(m.pose.x, m.pose.y, m.pose.z) : null;
      const inside = !!root && airlock.isInside(root);
      if (m.outcome === 'Escaped') continue;
      if (playing && inside) surv.push(m.id);
      else if (playing) {
        left.push(m.id);
        resp.push(m.id);
      } else resp.push(m.id);
    }
    airlock._setDeadline(null);
    airlock.phase = 'Sealed';
    airlock.sealingSince = null;
    this.coop.everyone({ t: 'sealed', from, surv, left, resp });
  }

  _onSealed(msg) {
    const game = this.game;
    const coop = this.coop;
    const id = coop.localId;
    if (!game.run || game.level !== msg.from) return;
    if (coop.isClient() && game.airlock) {
      game.airlock._setDeadline(null);
      game.airlock.phase = 'Sealed';
    }
    if (msg.left.includes(id)) {
      game.notify('Airlock.LeftBehind');
      game.life.setSpectating();
    }
    const to = game.advance();
    if (msg.surv.includes(id)) {
      game.stats.increment('FloorsCleared');
      game.notify('Checkpoint.Sealed');
      if (!game.run.devRun && !game.profile.readOnly) game.notify('Checkpoint.Reached', GameConfig.CreditsPerLevelCleared);
    }
    if (to && game.hints) game.hints.noteSeal(msg.from);
    if (coop.isHost()) {
      for (const m of coop.participants()) if (msg.resp.includes(m.id) && m.lateJoin) m.lateJoin = false;
      coop.touch();
    }
    if (to && msg.resp.includes(id)) this._respawn(to);
  }

  /** Back on your feet at the new floor's entry, half health (a checkpoint brings the dead and the left behind back). */
  _respawn(level) {
    const game = this.game;
    this._stopSpectating();
    this.lateJoin = false;
    game.life.setAlive(RESPAWN_HEALTH);
    game.match.spawnAt(level, this.coop.me ? this.coop.me.slot : 0);
    if (game.traps) game.traps.noteTeleport();
    this.env.toast(C('Coop.Respawned'));
  }

  // ---------------------------------------------------------------------------------------------------- outcome

  /** Host: MatchAndDataService.verdict over the squad. */
  verdict() {
    const coop = this.coop;
    const list = coop.participants();
    if (list.length <= 1) return null;
    let anyAlive = false;
    let anyEscaped = false;
    for (const m of list) {
      if (m.outcome === 'Escaped') {
        anyEscaped = true;
        continue;
      }
      const state = m.local ? this.game.life.state : m.life;
      if (state === 'Alive') anyAlive = true;
    }
    if (anyAlive) return 'Continue';
    return anyEscaped ? 'Escape' : 'Wipe';
  }

  /** Host / clients: this page's player escaped (Level 5's landing). */
  localEscaped() {
    const coop = this.coop;
    if (!coop.me) return;
    coop.me.outcome = 'Escaped';
    if (coop.isClient()) coop.toHost({ t: 'escaped' });
    else {
      coop.touch();
      this.game.match.requestEvaluation();
    }
  }

  _onEscaped(from) {
    if (!this.coop.isHost()) return;
    const m = this.coop.squad.get(from);
    if (!m || !m.participant) return;
    m.outcome = 'Escaped';
    this.coop.touch();
    this.game.match.requestEvaluation();
  }

  /** Host: the run resolved here; every client resolves with its own player's outcome. */
  resolved(verdict) {
    const coop = this.coop;
    const list = coop.participants();
    const escapees = list.filter((m) => m.outcome === 'Escaped').length;
    for (const m of list) if (m.outcome === 'Pending') m.outcome = 'Dead';
    for (const m of coop.squad.list()) m.playAgain = false;
    coop.touch();
    coop.broadcast({ t: 'resolve', v: verdict, esc: escapees, size: list.length, ends: GameConfig.ResultsSeconds });
  }

  _onResolve(msg) {
    if (!this.coop.isClient()) return;
    this.game.match.resolveFromHost(msg.v, { escapees: msg.esc, squadSize: msg.size });
  }

  /** Results: this page pressed Play Again. */
  playAgain() {
    const coop = this.coop;
    if (coop.isClient()) {
      coop.toHost({ t: 'playAgain' });
      return;
    }
    if (coop.me) coop.me.playAgain = true;
    coop.touch();
    this._maybeReset();
  }

  _onPlayAgain(from) {
    const m = this.coop.squad.get(from);
    if (!m || !this.coop.isHost()) return;
    m.playAgain = true;
    this.coop.touch();
    this._maybeReset();
  }

  _maybeReset() {
    const list = this.coop.participants();
    if (list.length && list.every((m) => m.playAgain)) this.resetAll();
  }

  /** Host: Results -> the lobby for everyone (those who pressed Play Again arrive Ready). */
  resetAll() {
    const coop = this.coop;
    const ready = coop.squad.list().filter((m) => m.playAgain).map((m) => m.id);
    coop.everyone({ t: 'reset', ready });
  }

  _onReset(msg) {
    const match = this.game.match;
    match.playAgain = Array.isArray(msg.ready) && msg.ready.includes(this.coop.localId);
    match.resetFromHost();
  }

  // ---------------------------------------------------------------------------------------------------- deploy / join

  /** Host: who is in the run (everyone in the room at the deploy). */
  deployed() {
    const coop = this.coop;
    for (const m of coop.squad.list()) {
      m.participant = true;
      m.outcome = 'Pending';
      m.lateJoin = false;
      m.playAgain = false;
      m.caught = false;
      m.lockerId = null;
      m.life = m.local ? m.life : 'Alive';
    }
    coop.touch();
  }

  /** Host: the welcome of a player joining during a run. */
  welcome(member, msg) {
    const game = this.game;
    if (!game.run || (game.phase !== 'InRun' && game.phase !== 'Deploying')) return;
    member.participant = true;
    member.lateJoin = true;
    member.outcome = 'Pending';
    member.life = 'Spectating';
    msg.run = { seed: game.run.seed, d: game.run.difficulty, id: game.run.runId, level: game.level,
      cleared: [...game.cleared] };
  }

  /** Client: welcomed into a room whose run is underway. */
  welcomed(msg) {
    if (msg.run) this._onRun(msg.run);
  }

  async _onRun(run) {
    const game = this.game;
    if (game.run) return;
    if (game.onboarding && game.onboarding.busy()) game.onboarding.closeForCoop();
    this.lateJoin = true;
    const ok = await game.match.deploy(run.d, { seed: run.seed, runId: run.id, slot: this.coop.me ? this.coop.me.slot : 0,
      level: run.level, cleared: run.cleared, spectate: true });
    if (ok) game.life.setSpectating();
  }

  // ---------------------------------------------------------------------------------------------------- leaving

  memberLeft(member) {
    if (this.revivePrompts.has(member.id)) {
      this.revivePrompts.get(member.id).remove();
      this.revivePrompts.delete(member.id);
    }
    if (this.spectating && this.spectating.id === member.id) {
      this.spectating = null;
      this.cycle(1);
    }
    if (!this.coop.isHost()) return;
    if (member.participant && this.game.run) {
      if (member.pose) this._drop(member);
      if (this.game.flasks) this.game.flasks.memberGone(member.id);
      this.game.match.requestEvaluation();
    }
  }

  /** The room is gone (left, the host left, the connection dropped): back to the title, the run dropped. */
  backToTitle(reason) {
    const game = this.game;
    this._stopSpectating();
    if (game.run || game.phase !== 'Lobby') {
      game.match.playAgain = false;
      game.match.resetFromHost(true);
    }
    if (game.lobby) game.lobby.arrive(false);
    if (game.onboarding) game.onboarding.openTitle();
    this.coop.ui.showMessage(reason);
  }

  sessionEnding() {
    for (const p of this.revivePrompts.values()) p.remove();
    this.revivePrompts.clear();
    this.reviving = null;
    this.beingRevivedBy = null;
    this._stopSpectating();
    this.lateJoin = false;
  }

  /**
   * The players a host-run scene can happen to: [{id, local, eye, root, zone, inVent}] for everyone in play (this
   * page's player first; alone or on a client just them).
   */
  subjects() {
    const game = this.game;
    const env = this.env;
    const out = [];
    if (game.playing()) {
      out.push({ id: this.coop.localId, local: true, eye: game.eye(new THREE.Vector3()), root: env.rootPosition(new THREE.Vector3()),
        zone: game.zoneId(), inVent: !!(game.vents && game.vents.inVent()) });
    }
    if (!this.coop.isHost()) return out;
    for (const m of this.coop.participants()) {
      if (m.local || !m.playing() || !m.pose) continue;
      const p = m.pose;
      const root = new THREE.Vector3(p.x, p.y, p.z);
      const zone = env.zoneAt(root);
      out.push({ id: m.id, local: false, eye: new THREE.Vector3(p.x, p.y + (EYE[p.moveState] ?? 1.5), p.z), root,
        zone: zone ? zone.id : null, inVent: (p.flags & PoseFlags.Vent) !== 0 });
    }
    return out;
  }

  /** Host: the root of a teammate in the water (Level 4 calls the Creature to the pool for them too), or null. */
  remoteSwimmerRoot() {
    if (!this.coop.isHost()) return null;
    for (const m of this.coop.participants()) {
      if (m.local || !m.playing() || !m.pose || !(m.pose.flags & PoseFlags.Swim)) continue;
      return new THREE.Vector3(m.pose.x, m.pose.y, m.pose.z);
    }
    return null;
  }

  /** Could any playing participant see `point` (host; a client answers for its own player)? */
  seenByAnyone(point, range = 250) {
    const game = this.game;
    if (game.seen(point, range)) return true;
    if (!this.coop.isHost()) return false;
    for (const m of this.coop.participants()) {
      if (m.local || !m.playing() || !m.pose) continue;
      const eye = _p.set(m.pose.x, m.pose.y + (EYE[m.pose.moveState] ?? 1.5), m.pose.z);
      if (eye.distanceTo(point) > range) continue;
      if (this.env.lineClear(eye, point, { ignoreEntities: false })) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------------------------------- drive

  beginRun() {
    this.beingRevivedBy = null;
    this.landedAt = null;
    this.landingReleased = false;
  }

  endRun() {
    for (const p of this.revivePrompts.values()) p.remove();
    this.revivePrompts.clear();
    this.reviving = null;
    this.beingRevivedBy = null;
    this._stopSpectating();
    this.lateJoin = false;
  }

  /**
   * A client's own landing (the roof finale is the host's): the touchdown is this player's escape, and the landing's
   * hold ends after the finale's beat (the host's Level 5 does both for the host's player).
   */
  _clientLanding(now) {
    const game = this.game;
    const p = game.parachute;
    if (!this.coop.isClient() || !game.run || !p) return;
    if (p.state === 'Landed' && this.landedAt === null) {
      this.landedAt = now;
      game.match.markEscaped();
    }
    if (this.landedAt !== null && !this.landingReleased && now - this.landedAt >= LANDING_HOLD) {
      this.landingReleased = true;
      p.releaseHold();
    }
  }

  tick(dt, now) {
    if (!this.coop.active) return;
    this._clientLanding(now);
    this._syncRevivePrompts();
    const want = this._spectateWanted();
    if (want && !this.spectateActive) this._startSpectating();
    else if (!want && this.spectateActive) this._stopSpectating();
    if (this.spectateActive && (!this.spectating || !this.spectating.playing() || !this.coop.squad.get(this.spectating.id))) {
      this.spectating = null;
      this.cycle(1);
    }
  }

  frame(dt) {
    this.lastDt = dt;
    const show = this.spectateActive;
    this.hud.style.display = show ? '' : 'none';
    if (!show) return;
    this.hudName.textContent = this.spectating ? S('Hud.Spectating', this.spectating.name) : S('Hud.NoOneToSpectate');
    this.hudReason.textContent = this.spectateReason ? C(this.spectateReason) : '';
    this.hudHint.textContent = this.spectating ? `${S('Spectate.Respawn')}  ·  ${C('Coop.SpectateHint',
      this.env.device() === 'Gamepad' ? 'LB' : 'Q', this.env.device() === 'Gamepad' ? 'RB' : 'E')}` : '';
  }

  _buildHud() {
    const root = this.env.uiRoot();
    this.hud = el('div', 'rg-panel', root);
    Object.assign(this.hud.style, { position: 'absolute', left: '50%', bottom: '86px', transform: 'translateX(-50%)',
      padding: '10px 18px', textAlign: 'center', pointerEvents: 'none', display: 'none', zIndex: '14', minWidth: '280px' });
    this.hudName = el('div', 'rg-title', this.hud, '');
    this.hudName.style.fontSize = '20px';
    this.hudReason = el('div', 'rg-body', this.hud, '');
    Object.assign(this.hudReason.style, { fontSize: '13px', color: Palette.Ash, marginTop: '4px' });
    this.hudHint = el('div', 'rg-caps', this.hud, '');
    this.hudHint.style.marginTop = '6px';
  }
}

const _p = new THREE.Vector3();
const _q = new THREE.Quaternion();
const _e = new THREE.Euler();
