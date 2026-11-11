// run.js: a co-op run's squad rules (LifeStateService, DownedReviveService, SpectatorService, CheckpointAirlockService's
// squad side, the stage transitions, the run outcome and MatchResetService), host-authoritative.
//
// Lives (docs/design/game-spec-v2.md 3.3, 3.7). The host owns every player's lives: its book holds each teammate's
// LivesRules record (its own player's is its Life's), and it decides downs, get-ups, respawns and the Creature's
// relocation. A page feels what happens to its own body (damage, traps, the bleed-out's clock, a held get-up) and sends
// the intent ({t: 'lethal'}, {t: 'getUp'}); the host answers with the rules' word ({t: 'lifeCmd'}: down, killed and what
// follows, up, the lives record) and every page reports its life state ({t: 'life'}). A killed player with a respawn left
// gets RespawnBlackout of black and stands up at their slot's spawn at the stage's entry; on the host the Creature is
// moved away from that entry and blind to them for the grace. Out of respawns they spectate. A teammate going down or
// dying is announced; a dying player's carried objective items are set down where they fell ({t: 'drop'}), as are a
// leaver's. Each page tells the host whether its loadout holds the syringe ({t: 'livesKit'}).
// Revive. A Downed teammate carries a Revive prompt (hold ReviveHold) on every other page, live for an Alive player with
// no control lock while the victim is not being caught. The hold tells the victim who is reviving them; completing it
// asks the host ({t: 'revive'}), which checks both and the distance and has the victim's page get up at ReviveHealth
// ({t: 'cmd', c: 'revive'}); the reviver's RunStats Revives counts it.
// Spectating. Dead, or left behind by an airlock (Spectating), a player watches their squad: the camera rides a playing
// teammate's eyes (their interpolated pose and look), Q / E (bumpers, the touch arrows) switch, a lost target hands over
// to the next; the HUD says who and why.
// Airlock (host). The checkpoint counts every playing participant: inside when their pose's root or feet stand in the
// volume, the tower or the next level's entry room (the airlock's own test). Waiting starts with the first one in (the
// squad hears the straggler warning), seals when every Alive one is in or at the deadline; the clients' banners follow
// ({t: 'airlock'}). Sealed ({t: 'sealed'}): those outside are left behind (Spectating), the run advances on every
// page, the survivors are paid the floor, and everyone Dead or Spectating (not about to respawn) stands up at the next
// stage's entry at CheckpointHealth (LivesRules.checkpointReturn).
// Stages (host). Every other transition is the host's word ({t: 'stageNext'}, with who stands up): a stand-in's end
// (a client's Skip is a vote, {t: 'standInSkip'}) and the roof's, once every participant still playing has landed
// below ({t: 'landed'}).
// Outcome (host). Continue until LivesRules.runEnds over the squad (nobody Alive or Downed, nobody with a respawn
// left): a wipe; after the last stage everyone still playing escaped. Either resolves the run for everyone
// ({t: 'resolve'}), each page paying its own player from its own stats and outcome. Results end when every participant
// still here pressed Play Again or at the host's timer ({t: 'reset'}).
// Late joiners. A player who joins during a run is put in it as a spectator ({t: 'run'} in the welcome) and stands up at
// the next stage's entry with the others out of play.

import * as THREE from 'three';
import { PoseFlags } from '../../net/codec.js';
import { GameConfig } from '../config.js';
import { S } from '../strings/index.js';
import '../strings/run.js';
import { Palette, el } from '../ui/style.js';
import { isNumber, oneOf } from './events.js';
import { C } from './strings.js';

const REVIVE_DISTANCE = 7;
const REVIVE_CHECK_SLACK = 5;
const ROOT_TO_FEET = 3;
const LETHAL_HITS = ['Catch', 'Damage', 'BleedOut', 'Execute', 'Abandon'];
const PLAYING = ['Alive', 'Downed'];
const RUN_PHASES = ['Deploying', 'InRun'];
const EYE = { Standing: 1.5, Sprinting: 1.4, Crouching: 0, VentCrawling: -0.6, VentScurrying: -0.6, DownedCrawling: -0.8,
  Hiding: 1.3, Trapped: 1.1 };
const SPECTATE_SMOOTH = 12;

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
    this.landed = false;
    /** host: each teammate's lives (memberId -> {lives, downedAt, respawning}); its own player's are its Life's */
    this.book = new Map();
    /** host: teammates' respawns due ({id, at}): the Creature moved away from their entry and blind to them */
    this.respawnsDue = [];
    this._register();
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
    this._lifeChanged(m, m.life, msg.s, msg.c);
  }

  /** Host: a member's life state changed. */
  _lifeChanged(member, previous, state, cause) {
    const coop = this.coop;
    if (previous === state) return;
    member.life = state;
    const rec = member.local ? null : this.book.get(member.id);
    if (rec && state === 'Alive') {
      rec.downedAt = null;
      rec.respawning = false;
    }
    if (state !== 'Alive') this._clearReviving(member.id);
    if (member.participant && this.game.run) {
      // a respawn keeps its flasks (LivesRules.respawn); out of play they are gone
      const respawning = member.local ? !!this.game.life.respawning : !!(rec && rec.respawning);
      if (state === 'Downed') this._announce(member, 'Downed.TeammateDown');
      if (state === 'Dead' && previous === 'Downed') this._announce(member, 'Downed.TeammateLost');
      if (state === 'Dead' && member.pose) this._drop(member);
      if (((state === 'Dead' && !respawning) || state === 'Spectating') && this.game.flasks) {
        this.game.flasks.memberGone(member.id);
      }
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
    const dropped = floors.dropCarried(msg.id, new THREE.Vector3(msg.at[0], msg.at[1], msg.at[2]));
    if (!dropped.length) return;
    if (msg.id !== this.coop.localId) this.env.toast(C('Coop.Dropped', msg.name || ''));
    // pinned on every HUD for PinSeconds
    const who = msg.id === this.coop.localId ? S('Lives.You') : msg.name || '';
    if (this.game.livesHud) this.game.livesHud.pinDropped(dropped, who);
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
      if (life.state === 'Downed') life.revive();
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

  /** The downed screen's teammates' status: each teammate's name and how they are. */
  teammatesStatus() {
    const parts = [];
    for (const m of this.coop.participants()) {
      if (m.local) continue;
      parts.push(S('Lives.Teammate', m.name, S(`Lives.State.${PLAYING.includes(m.life) ? m.life : 'Dead'}`)));
    }
    return parts.join('   ');
  }

  // ---------------------------------------------------------------------------------------------------- lives

  /** The messages of the lives, the stages and the stand-in (events.js: each with its rules). */
  _register() {
    const ev = this.coop.events;
    ev.register('lethal', { to: 'host', phases: RUN_PHASES, life: PLAYING, rate: 6,
      validate: (m) => LETHAL_HITS.includes(m.h), handle: (from, m) => this._onLethal(from, m) });
    ev.register('getUp', { to: 'host', phases: RUN_PHASES, life: ['Downed'], rate: 4,
      validate: (m) => isNumber(m.held), handle: (from, m) => this._onGetUp(from, m) });
    ev.register('livesKit', { to: 'host', phases: RUN_PHASES, rate: 2,
      validate: (m) => typeof m.s === 'boolean', handle: (from, m) => this._onLivesKit(from, m) });
    ev.register('lifeCmd', { to: 'client', phases: RUN_PHASES,
      validate: (m) => oneOf(['down', 'kill', 'up', 'lives'])(m.c) && !!m.l && typeof m.l === 'object',
      handle: (from, m) => this._onLifeCmd(m) });
    ev.register('landed', { to: 'host', phases: ['InRun'], life: PLAYING, rate: 2,
      validate: (m) => typeof m.s === 'string', handle: (from, m) => this._onLanded(from, m) });
    ev.register('standInSkip', { to: 'host', phases: ['InRun'], rate: 2,
      validate: (m) => typeof m.s === 'string', handle: (from, m) => this.game.standIn.vote(from, m.s) });
    ev.register('stageNext', { to: 'client', phases: ['InRun'],
      validate: (m) => typeof m.from === 'string' && Array.isArray(m.resp), handle: (from, m) => this._onStageNext(m) });
  }

  /** Client: a lethal hit on this page's player, for the host to decide. */
  sendLethal(hit, cause) {
    this.coop.toHost({ t: 'lethal', h: hit, c: String(cause || '') });
  }

  /** Client: this page's player held the get-up long enough, for the host to grant. */
  sendGetUp(held) {
    this.coop.toHost({ t: 'getUp', held });
  }

  _onLethal(from, msg) {
    const m = this.coop.squad.get(from);
    if (m && m.participant) this.hostLethal(m, msg.h, msg.c);
  }

  /**
   * Host: a lethal hit on teammate `member` (their page's report, or a catch of the host's Creature): the rules decide
   * on the host's record, and the member's page is told (down; or killed and what follows).
   * @param {'Catch'|'Damage'|'BleedOut'|'Execute'|'Abandon'} hit
   */
  hostLethal(member, hit, cause) {
    const rec = this.book.get(member.id);
    const game = this.game;
    if (!rec || !game.run || !game.live() || !PLAYING.includes(member.life)) return;
    const rules = game.life.rules;
    const d = game.run.difficulty;
    if (hit === 'Abandon') rec.lives = { ...rec.lives, stage: 0, run: 0, syringe: 0 };
    const result = hit === 'Execute' || hit === 'Abandon' ? { outcome: 'Killed', lives: rec.lives }
      : rules.lethal(rec.lives, member.life, hit);
    rec.lives = result.lives;
    member.downedCount = rec.lives.downs;
    const previous = member.life;
    if (result.outcome === 'Downed') {
      rec.downedAt = this.env.now();
      this.coop.toMember(member.id, { t: 'lifeCmd', c: 'down', l: rec.lives, cause });
      this._lifeChanged(member, previous, 'Downed', cause);
      return;
    }
    const after = rules.afterDeath(rec.lives, this.coop.participants().length);
    rec.lives = after.lives;
    rec.downedAt = null;
    rec.respawning = after.action === 'Respawn';
    if (rec.respawning) this.respawnsDue.push({ id: member.id, at: this.env.now() + rules.of(d).RespawnBlackout });
    this.coop.toMember(member.id, { t: 'lifeCmd', c: 'kill', l: result.lives, a: after, cause });
    this._lifeChanged(member, previous, 'Dead', cause);
  }

  _onGetUp(from, msg) {
    const m = this.coop.squad.get(from);
    const rec = m ? this.book.get(m.id) : null;
    const game = this.game;
    if (!rec || rec.downedAt === null || !game.run) return;
    const check = game.life.rules.getUp(game.run.difficulty, rec.lives, this.env.now() - rec.downedAt, msg.held);
    if (!check.up) return;
    rec.lives = { ...rec.lives, getUpUsed: true };
    rec.downedAt = null;
    this.coop.toMember(m.id, { t: 'lifeCmd', c: 'up', l: rec.lives, hp: check.health });
  }

  _onLivesKit(from, msg) {
    const m = this.coop.squad.get(from);
    const rec = m ? this.book.get(m.id) : null;
    if (!rec) return;
    rec.lives = { ...rec.lives, syringe: msg.s ? this.game.life.rules.of(rec.difficulty).SyringeRespawns : 0 };
    this.coop.toMember(m.id, { t: 'lifeCmd', c: 'lives', l: rec.lives });
  }

  /** Client: the host's word on this page's player. */
  _onLifeCmd(msg) {
    const life = this.game.life;
    if (msg.c === 'lives') life.setLives(msg.l);
    else if (msg.c === 'down') life.applyLethal('Downed', msg.l, msg.cause);
    else if (msg.c === 'kill') life.applyLethal('Killed', msg.l, msg.cause, msg.a);
    else if (msg.c === 'up') life.applyGetUp(Number(msg.hp) || 1, msg.l);
  }

  _onLanded(from, msg) {
    const m = this.coop.squad.get(from);
    if (!m || !m.participant || msg.s !== this.game.stage) return;
    m.landed = true;
    this.coop.touch();
  }

  /** Host: a stage's activation hands every teammate their stage's lives (LivesRules.stageActivated). */
  stageActivated(stage) {
    if (!this.coop.isHost() || !this.game.run) return;
    const rules = this.game.life.rules;
    for (const [id, rec] of this.book) {
      rec.lives = rules.stageActivated(this.game.run.difficulty, rec.lives, stage);
      const m = this.coop.squad.get(id);
      if (m) m.downedCount = rec.lives.downs;
      this.coop.toMember(id, { t: 'lifeCmd', c: 'lives', l: rec.lives });
    }
  }

  /** Host: teammates' respawns come due: the Creature moved away from their entry, blind to them for the grace. */
  _stepRespawns(now) {
    if (!this.coop.isHost() || !this.respawnsDue.length) return;
    const game = this.game;
    const due = this.respawnsDue.filter((r) => now >= r.at);
    if (!due.length) return;
    this.respawnsDue = this.respawnsDue.filter((r) => now < r.at);
    for (const r of due) {
      const m = this.coop.squad.get(r.id);
      const spawn = m && game.level ? game.match.spawnOf(game.level, m.slot) : null;
      const handle = m ? this.coop.creatureNet.handleOf(m.id) : null;
      if (spawn && handle) game.life.respawnEffects(spawn.cframe, handle);
    }
  }

  // ---------------------------------------------------------------------------------------------------- spectating

  /** Out of play: Dead (not about to respawn: the respawn's black is not spectating) or left behind. */
  _spectateWanted() {
    const s = this.game.life.state;
    const out = (s === 'Dead' && !this.game.life.respawning) || s === 'Spectating';
    return this.coop.active && !!this.game.run && this.game.live() && out;
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
    this.spectateReason = out ? (this.lateJoin ? 'Coop.LateJoin' : 'Spectate.LeftBehind') : 'Lives.OutOfRespawns';
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
      if (playing && inside) surv.push(m.id);
      else if (playing) {
        left.push(m.id);
        resp.push(m.id);
      } else if (this._standsUp(m)) resp.push(m.id);
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
    if (to && msg.resp.includes(id)) this._checkpointReturn(to);
  }

  /** Host: whether a participant out of play stands up at the next stage's entry (LivesRules.checkpointReturn). */
  _standsUp(m) {
    const rec = m.local ? null : this.book.get(m.id);
    if (m.local ? this.game.life.respawning : rec && rec.respawning) return false;
    const state = m.local ? this.game.life.state : m.life;
    return this.game.life.rules.checkpointReturn(this.game.run.difficulty, state).stand;
  }

  /** Back on your feet at the new stage's entry at CheckpointHealth (the dead, the left behind, the late joiner). */
  _checkpointReturn(stage) {
    const game = this.game;
    const back = game.life.rules.checkpointReturn(game.run.difficulty, game.life.state === 'Alive' ? 'Dead' : game.life.state);
    this._stopSpectating();
    this.lateJoin = false;
    game.life.setAlive(back.health);
    if (game.stages.isLevel(stage)) game.match.spawnAt(stage, game.match.slot());
    if (game.traps) game.traps.noteTeleport();
    this.env.toast(C('Coop.Respawned'));
  }

  // ---------------------------------------------------------------------------------------------------- stages

  /** Host: stage `stage` is done (a stand-in's end, the roof once everyone has landed): every page moves on. */
  stageDone(stage) {
    const game = this.game;
    if (!this.coop.isHost() || game.stage !== stage || !game.run) return;
    const resp = this.coop.participants().filter((m) => this._standsUp(m)).map((m) => m.id);
    this.coop.everyone({ t: 'stageNext', from: stage, resp });
  }

  _onStageNext(msg) {
    const game = this.game;
    if (!game.run || game.stage !== msg.from) return;
    for (const m of this.coop.squad.list()) m.landed = false;
    const to = game.advance();
    if (this.coop.isHost()) {
      for (const m of this.coop.participants()) if (msg.resp.includes(m.id) && m.lateJoin) m.lateJoin = false;
      this.coop.touch();
    }
    if (to && msg.resp.includes(this.coop.localId)) this._checkpointReturn(to);
  }

  /** This page's player landed below the roof (the host's level3.js counts the squad: squadLanded). */
  localLanded() {
    const coop = this.coop;
    if (!coop.me) return;
    coop.me.landed = true;
    if (coop.isClient()) coop.toHost({ t: 'landed', s: this.game.stage });
    else coop.touch();
  }

  /** Host: someone landed and every participant still playing has (a Downed or dead one does not hold the squad). */
  squadLanded() {
    let any = false;
    for (const m of this.coop.participants()) {
      const state = m.local ? this.game.life.state : m.life;
      if (m.landed) any = true;
      else if (state === 'Alive') return false;
    }
    return any;
  }

  // ---------------------------------------------------------------------------------------------------- outcome

  /** The squad as LivesRules sees it ([{slot, left, lifeState}]; a respawn under way stands for Alive). */
  squadMembers() {
    const life = this.game.life;
    return this.coop.participants().map((m) => {
      if (m.local) return life.member(m.slot + 1);
      const rec = this.book.get(m.id);
      return { slot: m.slot + 1, left: rec ? life.rules.respawnsLeft(rec.lives) : 0,
        lifeState: rec && rec.respawning ? 'Alive' : m.life };
    });
  }

  /** Host: MatchAndDataService.verdict over the squad (LivesRules.runEnds); null for a squad of one (the solo rule). */
  verdict() {
    if (this.coop.participants().length <= 1) return null;
    return this.game.life.runEnds(this.squadMembers()) ? 'Wipe' : 'Continue';
  }

  /** Host: the run's last stage is done: every participant still playing escaped. */
  finished() {
    for (const m of this.coop.participants()) {
      const state = m.local ? this.game.life.state : m.life;
      if (state === 'Alive' || state === 'Downed') m.outcome = 'Escaped';
    }
    this.coop.touch();
  }

  /** Host: the verdict of a finished run (Escape when anyone made it). */
  finishVerdict() {
    return this.coop.participants().some((m) => m.outcome === 'Escaped') ? 'Escape' : 'Wipe';
  }

  /** Host: the run resolved here; every client resolves with its own player's outcome. */
  resolved(verdict) {
    const coop = this.coop;
    const list = coop.participants();
    const escaped = list.filter((m) => m.outcome === 'Escaped').map((m) => m.id);
    for (const m of list) if (m.outcome === 'Pending') m.outcome = 'Dead';
    for (const m of coop.squad.list()) m.playAgain = false;
    coop.touch();
    coop.broadcast({ t: 'resolve', v: verdict, esc: escaped.length, ids: escaped, size: list.length,
      ends: GameConfig.ResultsSeconds });
  }

  _onResolve(msg) {
    if (!this.coop.isClient()) return;
    const escaped = Array.isArray(msg.ids) && msg.ids.includes(this.coop.localId);
    this.game.match.resolveFromHost(msg.v, { escapees: msg.esc, squadSize: msg.size, escaped });
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
  deployed(difficulty) {
    const coop = this.coop;
    this.book.clear();
    this.respawnsDue = [];
    for (const m of coop.squad.list()) {
      m.participant = true;
      m.outcome = 'Pending';
      m.lateJoin = false;
      m.playAgain = false;
      m.caught = false;
      m.landed = false;
      m.lockerId = null;
      m.life = m.local ? m.life : 'Alive';
      if (!m.local) this._open(m, difficulty);
    }
    coop.touch();
  }

  /** Host: a teammate's lives record for the run (no syringe until their page says so: livesKit). */
  _open(member, difficulty, syringe = false) {
    const rules = this.game.life.rules;
    let lives = rules.newRun(difficulty, syringe);
    if (this.game.stage) lives = rules.stageActivated(difficulty, lives, this.game.stage);
    this.book.set(member.id, { lives, difficulty, downedAt: null, respawning: false });
    member.downedCount = lives.downs;
  }

  /** Host: the welcome of a player joining during a run. */
  welcome(member, msg) {
    const game = this.game;
    if (!game.run || (game.phase !== 'InRun' && game.phase !== 'Deploying')) return;
    member.participant = true;
    member.lateJoin = true;
    member.outcome = 'Pending';
    member.landed = false;
    member.life = 'Spectating';
    this._open(member, game.run.difficulty);
    msg.run = { seed: game.run.seed, d: game.run.difficulty, id: game.run.runId, stage: game.stage,
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
      stage: run.stage, cleared: run.cleared, spectate: true });
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
    this.book.delete(member.id);
    this.respawnsDue = this.respawnsDue.filter((r) => r.id !== member.id);
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
        zone: game.zoneId(), inVent: !!(game.vents && game.vents.inVent()), life: game.life.state });
    }
    if (!this.coop.isHost()) return out;
    for (const m of this.coop.participants()) {
      if (m.local || !m.playing() || !m.pose) continue;
      const p = m.pose;
      const root = new THREE.Vector3(p.x, p.y, p.z);
      const zone = env.zoneAt(root);
      out.push({ id: m.id, local: false, eye: new THREE.Vector3(p.x, p.y + (EYE[p.moveState] ?? 1.5), p.z), root,
        zone: zone ? zone.id : null, inVent: (p.flags & PoseFlags.Vent) !== 0, life: m.life });
    }
    return out;
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

  beginRun(run) {
    this.beingRevivedBy = null;
    this.landed = false;
    // the host keeps this page's lives; it needs to know whether its loadout holds the syringe
    if (this.coop.active && this.coop.isClient()) {
      this.coop.toHost({ t: 'livesKit', s: run.perks.includes('AdrenalineSyringe') });
    }
  }

  endRun() {
    this.book.clear();
    this.respawnsDue = [];
    for (const p of this.revivePrompts.values()) p.remove();
    this.revivePrompts.clear();
    this.reviving = null;
    this.beingRevivedBy = null;
    this._stopSpectating();
    this.lateJoin = false;
  }

  /**
   * A client's own landing (the roof scene is the host's): the touchdown is told to the host and the landing's hold
   * ends at once (the host's level3.js does both for the host's player).
   */
  _clientLanding() {
    const game = this.game;
    const p = game.parachute;
    if (!this.coop.isClient() || !game.run || !p || p.state !== 'Landed' || this.landed) return;
    this.landed = true;
    game.stats.increment('FloorsCleared');
    this.localLanded();
    p.releaseHold();
  }

  tick(dt, now) {
    if (!this.coop.active) return;
    this._clientLanding();
    this._stepRespawns(now);
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
