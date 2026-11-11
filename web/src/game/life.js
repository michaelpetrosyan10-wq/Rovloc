// life.js: health and life state (LifeStateService) on the lives rules (docs/design/game-spec-v2.md 3.3: rules/lives.js,
// the port of LivesRules, over the world's meta.livesConfig), the perks' effects (LoadoutService: the syringe's one
// more respawn, battery capacity), for this page's player (the battery pickups are mechanics/batteries.js). The HUD of
// it all (the pips, the downed screen, the respawn's black) is ui/lives.js.
//
// LifeState: Lobby (not in a run) · Alive · Downed · Dead · Spectating.
//   beginRun     Alive at MaxHealth; the run's lives (LivesRules.newRun: the run respawn on Nightmare, the syringe's),
//                a full battery at the loadout's capacity, switched off.
//   stageActivated  downs and the get-up reset; a playable stage sets the stage respawn (never banked).
//   lethal       a catch, damage that empties health, the bleed-out: the stage's first one while Alive downs
//                (bleed-out BleedoutSeconds, crawling), anything after that kills.
//   get-up       Downed, from GetUpDelay after going down, hold Interact GetUpHold: up at GetUpHealth, once a stage.
//   revive       a teammate's (coop/run.js): up at ReviveHealth.
//   killed       LivesRules.afterDeath: a respawn left (stage, run, syringe in that order) -> RespawnBlackout of black,
//                then this player's slot's spawn at the current stage's entry at RespawnHealth, at least RespawnTorch
//                of the torch, the Creature moved away from that entry (MonsterClearance walked, PlayerClearance from
//                everyone, its next teleport TeleportDelay off) and blind to them for RespawnGrace; none left ->
//                spectating (a squad: they stand up at CheckpointHealth at the next stage's entry) or the run's end
//                (alone). A carried objective item is set down where they fell (pinned on the HUD for PinSeconds).
// Authority: alone this page decides everything; in a squad the host does (coop/run.js keeps every teammate's lives,
// decides their downs, get-ups and respawns and moves the Creature), and a client's page sends what happened to its
// player (a lethal hit, a held get-up) and applies the host's word. Flasks, the torch and the squad's progress are kept
// through a respawn; the get-up is given back.

import * as THREE from 'three';
import { GameConfig, batteryCapacity } from './config.js';
import { livesRules } from './rules/lives.js';
import { S } from './strings/index.js';
import './strings/run.js';
import { Signal } from './util.js';

const RESPAWN_LOCK = 'Respawn';
const ROOT_TO_FEET = 3;

export class Life {
  /** @param {import('./game.js').Game} game */
  constructor(game) {
    this.name = 'Life';
    this.game = game;
    this.env = game.env;
    this.rules = livesRules(game.world.meta);
    /** @type {'Lobby'|'Alive'|'Downed'|'Dead'|'Spectating'} */
    this.state = 'Lobby';
    this.health = GameConfig.MaxHealth;
    /** @type {import('./rules/lives.js').Lives} this player's respawns by source, downs this stage, the get-up used */
    this.lives = this.rules.newRun('Standard', false);
    this.downedAt = null;
    this.bleedoutEndsAt = null;
    /** the get-up's hold so far (seconds; it starts counting from GetUpDelay) */
    this.getUpHeld = 0;
    this.getUpHolding = false;
    this.getUpAsked = false;
    /** @type {{source: string, endsAt: number}|null} a respawn's black, until its end */
    this.respawning = null;
    this.perks = [];
    /** @type {Signal<[string, string, string]>} (state, previous, cause) */
    this.changed = new Signal();
    /** @type {Signal<[number, string]>} */
    this.damaged = new Signal();
    /** @type {Signal<[]>} the lives record changed (the HUD's pips) */
    this.livesChanged = new Signal();
    /** @type {Signal<[string]>} a respawn started (its source: stage, run or syringe) */
    this.respawnStarted = new Signal();
    this.env.onAction('Interact', (phase) => {
      this.getUpHolding = phase === 'Begin' && this.state === 'Downed';
      if (!this.getUpHolding) this.getUpHeld = 0;
    });
    this.wasEmpty = false;
  }

  /** The numbers of the run's difficulty (LivesConfig). */
  config() {
    return this.rules.of(this.game.run ? this.game.run.difficulty : 'Standard');
  }

  _difficulty() {
    return this.game.run ? this.game.run.difficulty : 'Standard';
  }

  /** The co-op room when one is open (null alone). */
  _coop() {
    const coop = this.game.coop;
    return coop && coop.active ? coop : null;
  }

  /** Whether this page decides its player's life (alone, or the host); a client applies the host's word. */
  authority() {
    const coop = this._coop();
    return !coop || coop.isHost();
  }

  /** Alive or Downed. */
  playing() {
    return this.state === 'Alive' || this.state === 'Downed';
  }

  /** stage + run + syringe respawns left. */
  respawnsLeft() {
    return this.rules.respawnsLeft(this.lives);
  }

  /** This player as LivesRules sees a squad member (a respawn under way stands for Alive: they are coming back). */
  member(slot) {
    return { slot, left: this.respawnsLeft(), lifeState: this.respawning ? 'Alive' : this.state };
  }

  /** LivesRules.runEnds over `members`. */
  runEnds(members) {
    return this.rules.runEnds(members);
  }

  /** The downs counted on this stage (the Creature's catch rule reads it). */
  get downedCount() {
    return this.lives.downs;
  }

  _write(state, cause = '') {
    const previous = this.state;
    if (previous === state) return;
    this.state = state;
    this.env.setLifeState(state);
    if (state === 'Dead' || state === 'Spectating') this.env.setFlashlight(false);
    if (state !== 'Downed') {
      this.getUpHeld = 0;
      this.getUpHolding = false;
      this.getUpAsked = false;
    }
    this.changed.fire(state, previous, cause);
    this.game.match.requestEvaluation();
  }

  /** Replaces the lives record (the rules' answer, or the host's word on a client). */
  setLives(lives) {
    this.lives = { ...lives };
    this.livesChanged.fire();
  }

  beginRun(run) {
    this.perks = run.perks.slice();
    this.health = GameConfig.MaxHealth;
    this.downedAt = null;
    this.bleedoutEndsAt = null;
    this.respawning = null;
    this.setLives(this.rules.newRun(run.difficulty, this.perks.includes('AdrenalineSyringe')));
    const battery = this.env.meters().battery;
    battery.setMax(batteryCapacity(this.perks));
    battery.set(battery.max);
    this.env.setFlashlight(false);
    this.env.setMetersActive(true);
    this._write('Alive');
    this.wasEmpty = false;
  }

  endRun() {
    this.bleedoutEndsAt = null;
    this.downedAt = null;
    this.health = GameConfig.MaxHealth;
    if (this.respawning) this.game.unlock(RESPAWN_LOCK);
    this.respawning = null;
    this.setLives(this.rules.newRun('Standard', false));
    this.env.setMetersActive(false);
    const battery = this.env.meters().battery;
    battery.setMax(GameConfig.BatteryMax);
    battery.set(battery.max);
    this.env.setFlashlight(false);
    this._write('Lobby');
  }

  stageActivated(stage) {
    if (!this.game.run || !this.authority()) return;
    this.setLives(this.rules.stageActivated(this._difficulty(), this.lives, stage));
  }

  // ---------------------------------------------------------------------------------------------------- lethal

  /** LifeStateService.lethalAction: what a catch does to this player now ('Down' | 'Execute' | 'Ignore'). */
  lethalAction() {
    if (!this.playing()) return 'Ignore';
    return this.rules.lethal(this.lives, this.state, 'Catch').outcome === 'Downed' ? 'Down' : 'Execute';
  }

  damage(amount, cause) {
    if (!this.game.live() || !Number.isFinite(amount) || amount <= 0) return;
    if (this.state === 'Alive') {
      const remaining = this.health - amount;
      if (remaining <= 0) {
        this.health = 0;
        this.lethal('Damage', cause);
      } else {
        this.health = remaining;
      }
    } else if (this.state === 'Downed') {
      this.lethal('Damage', cause);
    } else {
      return;
    }
    this.damaged.fire(amount, cause);
  }

  /** The one lethal path of traps and catches: a catch is 'Creature', anything else lethal damage. */
  down(cause) {
    this.lethal(cause === 'Creature' ? 'Catch' : 'Damage', cause);
  }

  /**
   * A lethal hit (LivesRules.lethal): Downed the first time on a stage while Alive, else Killed. A client asks the
   * host (coop/run.js), which answers with applyLethal.
   * @param {'Catch'|'Damage'|'BleedOut'} hit
   */
  lethal(hit, cause) {
    if (!this.game.live() || !this.playing()) return;
    const coop = this._coop();
    if (coop && coop.isClient()) {
      coop.runNet.sendLethal(hit, cause);
      return;
    }
    const result = this.rules.lethal(this.lives, this.state, hit);
    this.applyLethal(result.outcome, result.lives, cause);
  }

  /**
   * The rules' (or the host's) answer to a lethal hit; a kill's `after` is the host's LivesRules.afterDeath (alone, and
   * on the host for its own player, it is worked out here).
   */
  applyLethal(outcome, lives, cause, after = null) {
    if (!this.game.live() || !this.playing()) return;
    this.setLives(lives);
    if (outcome === 'Downed') this._goDown(cause);
    else this._kill(cause, after);
  }

  /** Killed outright, past any down (tests, the dev panel): the same death as the rules' Killed. */
  execute(cause) {
    if (!this.game.live() || !this.playing()) return;
    const coop = this._coop();
    if (coop && coop.isClient()) {
      coop.runNet.sendLethal('Execute', cause);
      return;
    }
    this._kill(cause);
  }

  /** The pause menu's Abandon: the respawns given up, then killed (the run ends; a squad watches on). */
  abandon() {
    if (!this.game.live() || !this.playing()) return;
    const coop = this._coop();
    if (coop && coop.isClient()) {
      coop.runNet.sendLethal('Abandon', 'Abandoned');
      return;
    }
    this.setLives({ ...this.lives, stage: 0, run: 0, syringe: 0 });
    this._kill('Abandoned');
  }

  _goDown(cause) {
    const now = this.env.now();
    this.downedAt = now;
    this.health = 1;
    this.bleedoutEndsAt = now + this.config().BleedoutSeconds;
    this.game.stats.increment('TimesDowned');
    this.game.playAt('Gasp', this.env.rootPosition(_p), { volume: 1 });
    this._write('Downed', cause);
  }

  /**
   * Killed: down to Dead; what follows is LivesRules.afterDeath over the squad's size (alone this page works it out,
   * the host for its own player; a client gets the host's), applied first so the death already knows a respawn is
   * coming (what it keeps through one).
   */
  _kill(cause, after = null) {
    this.bleedoutEndsAt = null;
    this.downedAt = null;
    this.health = 0;
    const coop = this._coop();
    let next = after;
    if (!next && this.game.run && (!coop || coop.isHost())) {
      next = this.rules.afterDeath(this.lives, coop ? coop.participants().length : 1);
    }
    if (next) this.applyAfterDeath(next);
    this._dropCarried();
    this._write('Dead', cause);
  }

  /** What a death leads to (LivesRules.afterDeath, or the host's word): the respawn's black begins, or nothing more. */
  applyAfterDeath(after) {
    this.setLives(after.lives);
    if (after.action !== 'Respawn' || !this.game.run) return;
    this.game.stats.increment('RespawnsUsed');
    this.respawning = { source: after.source, endsAt: this.env.now() + this.config().RespawnBlackout };
    this.game.lock(RESPAWN_LOCK);
    this.respawnStarted.fire(after.source);
  }

  /** Alone: what this player carried is set down where they fell, pinned on the HUD (a squad's host drops for all). */
  _dropCarried() {
    if (this._coop() || !this.game.floors) return;
    const root = this.env.rootPosition(_p);
    const at = new THREE.Vector3(root.x, root.y - ROOT_TO_FEET, root.z);
    const dropped = this.game.floors.dropCarried('', at);
    if (dropped.length && this.game.livesHud) this.game.livesHud.pinDropped(dropped, S('Lives.You'));
  }

  /** The respawn's end: at this player's slot's spawn at the current stage's entry, up again (LivesRules.respawn). */
  _standUp() {
    const g = this.game;
    this.respawning = null;
    g.unlock(RESPAWN_LOCK);
    const level = g.level;
    const spawn = level ? g.match.spawnOf(level, g.match.slot()) : null;
    if (spawn) {
      if (g.traps && g.traps.caught) g.traps._free(g.traps.caught, 'Release');
      g.env.teleport(spawn.cframe);
      if (g.traps) g.traps.noteTeleport();
    }
    const battery = this.env.meters().battery;
    const r = this.rules.respawn(this._difficulty(), 0, battery.value, battery.max);
    battery.set(r.torch);
    this.health = r.health;
    this._write('Alive', 'Respawn');
    if (this.authority() && spawn) this.respawnEffects(spawn.cframe, true);
  }

  /**
   * The authority's side of a respawn at `entry` (a spawn CFrame): the Creature moved away from that entry, unseen,
   * when it is within MonsterClearance walked of it, and `who` (true: this page's player; a teammate's roster handle)
   * ignored for RespawnGrace.
   */
  respawnEffects(entry, who) {
    const c = this.config();
    const at = new THREE.Vector3(entry[0], entry[1] - ROOT_TO_FEET, entry[2]);
    this.game.creature.relocateFrom(at, { walked: c.MonsterClearance, clear: c.PlayerClearance,
      teleportDelay: c.TeleportDelay });
    this.game.creature.ignore(who, c.RespawnGrace);
  }

  // ---------------------------------------------------------------------------------------------------- getting up

  /** The lone get-up now (LivesRules.getUp: the hold so far, the time since going down). */
  getUpCheck() {
    if (this.state !== 'Downed' || this.downedAt === null) return { allowed: false, up: false, health: 0 };
    return this.rules.getUp(this._difficulty(), this.lives, this.env.now() - this.downedAt, this.getUpHeld);
  }

  /** A get-up granted (the rules here, or the host's word): up at `health`, the stage's get-up used. */
  applyGetUp(health, lives) {
    if (this.state !== 'Downed') return;
    this.setLives(lives);
    this.bleedoutEndsAt = null;
    this.downedAt = null;
    this.health = Math.min(GameConfig.MaxHealth, Math.max(1, health));
    this.game.playAt('Gasp', this.env.rootPosition(_p), { volume: 0.8 });
    this._write('Alive', 'GetUp');
  }

  _stepGetUp(dt) {
    if (this.state !== 'Downed' || !this.getUpHolding || this.getUpAsked) return;
    const before = this.getUpCheck();
    if (!before.allowed) {
      this.getUpHeld = 0;
      return;
    }
    this.getUpHeld += dt;
    const check = this.getUpCheck();
    if (!check.up) return;
    const coop = this._coop();
    if (coop && coop.isClient()) {
      this.getUpAsked = true;
      coop.runNet.sendGetUp(this.getUpHeld);
      return;
    }
    this.applyGetUp(check.health, { ...this.lives, getUpUsed: true });
  }

  /** A teammate's revive, or the landing's: Downed -> Alive at `fraction` of MaxHealth (ReviveHealth by default). */
  revive(fraction) {
    if (this.state !== 'Downed') return;
    const health = fraction === undefined ? this.rules.revive(this._difficulty(), this.config().ReviveHold).health
      : (Number.isFinite(fraction) ? fraction : 0.5) * GameConfig.MaxHealth;
    this.bleedoutEndsAt = null;
    this.downedAt = null;
    this.health = Math.min(GameConfig.MaxHealth, Math.max(1, health));
    this.game.playAt('Gasp', this.env.rootPosition(_p), { volume: 0.8 });
    this._write('Alive', 'Revive');
  }

  /** Any state -> Alive (the checkpoint return, the late joiner, dev revives). */
  setAlive(health = GameConfig.MaxHealth) {
    this.bleedoutEndsAt = null;
    this.downedAt = null;
    if (this.respawning) this.game.unlock(RESPAWN_LOCK);
    this.respawning = null;
    this.health = Math.min(GameConfig.MaxHealth, Math.max(1, health));
    this._write('Alive');
  }

  /** Left behind by an airlock: out of play until the next stage's entry (solo: the run's evaluator ends it). */
  setSpectating() {
    if (!this.playing()) return;
    this.bleedoutEndsAt = null;
    this.downedAt = null;
    this._write('Spectating', 'LeftBehind');
  }

  tick(dt, now) {
    if (!this.game.live()) return;
    if (this.state === 'Downed' && this.bleedoutEndsAt !== null && now >= this.bleedoutEndsAt) {
      this.bleedoutEndsAt = null;
      this.lethal('BleedOut', 'Bleedout');
    }
    this._stepGetUp(dt);
    if (this.respawning && now >= this.respawning.endsAt) this._standUp();
    const empty = this.env.meters().battery.value <= 1e-3;
    if (empty && !this.wasEmpty) this.game.notify('Hud.BatteryEmpty');
    this.wasEmpty = empty;
  }
}

const _p = new THREE.Vector3();
