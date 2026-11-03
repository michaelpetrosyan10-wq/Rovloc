// monsterFx.js: the game's side of the Tall Man (Tunnels §2.3, §3): what the players see and hear of its new rules,
// on every page, and the game state its brain asks about.
//
//   * Teleport warnings (DOORS / Pressure): WarningSeconds before it forms at a spot, the lights within FlickerRadius
//     of it stutter through the lighting's flicker groups (setGroupFactor; scripted groups and lights a level keeps lit
//     are left alone), a static hiss rises there (TeleportHiss) and, for its target, the torch stutters (the
//     Creature's EMF, index.js warnLocal).
//   * The chase music: while it chases this page's player, a pulse layer (ChasePulse) under a sting at its start
//     (ChaseSting); a held stare that started it stings (StareSting).
//   * A chase that gives up: the reverse swell for the one it chased (GiveUpSwell); every FadeOut, the rush of air
//     where it stood (CreatureVanish).
//   * The rattle: a low rattle in its throat while it stalks within RATTLE_RANGE (CreatureRattle), the grunt before a
//     LookAway on the co-op clients (the host's own plays from the brain).
//   * The jump landing noise (JumpLand, 26 studs) after any fall of LAND_AIRTIME or more.
//   * The brain's vetoes and reads (bindGame): no teleport during an objective's survive countdown or once the roof's
//     finale chase has started; the hiding spot this page's player is in.
// Co-op: the host's brain fires the events; game/coop/creature.js relays them and a client calls warning(), stare(),
// giveUp(), grunt() here itself.

import * as THREE from 'three';
import { CreatureConfig } from '../../creature/config.js';
import { seededRandom } from '../util.js';

const T = CreatureConfig.Teleport;
const LAND_AIRTIME = 0.32;
const RATTLE_RANGE = 22;
const RATTLE_MIN = 4.5;
const RATTLE_MAX = 8;
const RATTLE_STATES = new Set(['Patrol', 'Teleport', 'Search', 'HidingResponse', 'InvestigateNoise']);
const FINALE_PHASES = new Set(['Smash', 'Chase', 'FinaleWait', 'Finale', 'Done']);
const FLICKER_FALLBACK = 32; // no flickering light within FlickerRadius: the nearest within this
const MAX_FLICKER = 6;

export class MonsterFx {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'MonsterFx';
    this.game = game;
    this.env = game.env;
    /** @type {Array<{group: number, from: number, until: number, seed: number}>} */
    this.flickers = [];
    this.chase = null;
    this.wasChased = false;
    this.airborneAt = null;
    this.nextRattleAt = 0;
    this.random = seededRandom(1, 'MonsterFx');
    this.lastAction = null;
    this.lastActionAt = 0;
    const meta = game.world.meta;
    this.groupNames = new Map((meta.flickerGroups || []).map((g) => [g.id, g.name || '']));
    this.lights = (meta.lights || []).filter((l) => l.group > 0 && !l.broken && l.kind !== 'Moonlight')
      .map((l) => ({ id: l.id, group: l.group, level: l.level, position: new THREE.Vector3(...l.pos) }));

    const creature = game.creature;
    creature.bindGame({
      teleportBlocked: () => this.teleportBlocked(),
      hideSpotOf: () => (game.lockers ? game.lockers.occupiedId() : null),
      hideSpotOccupied: (id) => !!game.lockers && game.lockers.occupiedId() === id,
    });
    creature.teleportWarning.connect((spot, targetsMe, seconds) => this.warning(spot, seconds));
    creature.stared.connect(() => this.stare());
    creature.gaveUp.connect((position, wasMe) => this.giveUp(position, wasMe));
    // the host's brain plays its grunt itself; a co-op client hears it from the relay
    creature.grunted.connect((position) => {
      if (game.coop && game.coop.isClient()) this.grunt(position);
    });
  }

  // ---------------------------------------------------------------------------------------------------- the vetoes

  /** No teleport during an objective's survive countdown, nor once the roof's finale chase has started. */
  teleportBlocked() {
    const g = this.game;
    const floor = g.floors && g.level ? g.floors.floor(g.level) : null;
    if (floor && floor.spec && Array.isArray(floor.spec.steps) && floor.spec.steps.some((s) => s.seconds && floor.timerRunning(s))) return true;
    if (g.level === 'Level5_Roof' && g.level5 && FINALE_PHASES.has(g.level5.phase)) return true;
    return false;
  }

  // ---------------------------------------------------------------------------------------------------- the events

  /** A teleport's warning at `spot` (a floor point) for `seconds`: the lights near it stutter, the hiss rises. */
  warning(spot, seconds = T.WarningSeconds) {
    const env = this.env;
    const now = env.now();
    const kept = this.game.lightsKeptLit;
    const usable = (l) => !(this.groupNames.get(l.group) || '').startsWith('Scripted:') && !(kept && kept.has(l.id)) &&
      Math.abs(l.position.y - spot.y) < 20;
    let near = this.lights.filter((l) => usable(l) && l.position.distanceTo(spot) <= T.FlickerRadius);
    if (!near.length) {
      near = this.lights.filter((l) => usable(l) && l.position.distanceTo(spot) <= FLICKER_FALLBACK)
        .sort((a, b) => a.position.distanceTo(spot) - b.position.distanceTo(spot)).slice(0, 1);
    }
    const groups = [...new Set(near.map((l) => l.group))].slice(0, MAX_FLICKER);
    for (const group of groups) {
      this.flickers = this.flickers.filter((f) => f.group !== group);
      this.flickers.push({ group, from: now, until: now + seconds, seed: this.random.number(0, 100) });
    }
    env.play('TeleportHiss', { position: spot.clone().add(new THREE.Vector3(0, 4, 0)), volume: 1 });
  }

  /** A held stare caught its attention (this page's player). */
  stare() {
    this.env.play('StareSting', { volume: 1 });
  }

  /** A chase gave up where it stood: the swell for the one it chased. */
  giveUp(position, wasMe) {
    if (wasMe) this.env.play('GiveUpSwell', { volume: 1 });
    else if (position) this.env.play('CreatureVanish', { position: position.clone().add(new THREE.Vector3(0, 6, 0)), volume: 0.8 });
  }

  /** The grunt before a LookAway (a co-op client: the host's brain played it there). */
  grunt(position) {
    if (position) this.env.play('CreatureGrunt', { position: position.clone(), volume: 1 });
  }

  // ---------------------------------------------------------------------------------------------------- drive

  beginRun() {
    this._endFlickers();
    this._stopChase(0);
    this.wasChased = false;
    this.airborneAt = null;
    this.lastAction = null;
  }

  endRun() {
    this._endFlickers();
    this._stopChase(0.3);
  }

  levelDeactivated() {
    this._endFlickers();
  }

  _endFlickers() {
    for (const f of this.flickers) this.env.setGroupFactor(f.group, null);
    this.flickers = [];
  }

  _stopChase(fade) {
    if (this.chase) this.chase.stop(fade);
    this.chase = null;
  }

  frame(dt, now) {
    // the warning flickers: hard stutters, mostly dark, black at the end, then the lights come back
    const env = this.env;
    for (let i = this.flickers.length - 1; i >= 0; i--) {
      const f = this.flickers[i];
      const t = now - f.from;
      if (now >= f.until || t < 0) {
        env.setGroupFactor(f.group, null);
        this.flickers.splice(i, 1);
        continue;
      }
      const left = f.until - now;
      const beat = Math.floor((t + f.seed) * 11 + Math.sin((t + f.seed) * 7.3) * 1.6);
      const factor = left < 0.25 ? 0 : beat % 3 === 0 ? 0.9 : beat % 3 === 1 ? 0.05 : 0.25;
      env.setGroupFactor(f.group, factor);
    }
  }

  tick(dt, now) {
    const g = this.game;
    if (!g.live()) {
      if (this.chase) this._stopChase(0.8);
      return;
    }
    const creature = g.creature;
    // the chase music on this page
    const chased = creature.chasingPlayer() && creature.getState() === 'WallChase';
    if (chased && !this.wasChased) {
      this.env.play('ChaseSting', { volume: 1 });
      this._stopChase(0);
      this.chase = this.env.play('ChasePulse', { loop: true, fadeIn: 0.4, volume: 0.9 });
    } else if (!chased && this.wasChased) this._stopChase(1.4);
    this.wasChased = chased;
    const snap = creature.snapshot();
    if (snap && snap.running) {
      // every FadeOut: the rush of air where it stood
      if (snap.action !== this.lastAction || snap.actionStartedAt !== this.lastActionAt) {
        if (snap.action === 'FadeOut' && snap.position) {
          this.env.play('CreatureVanish', { position: snap.position.clone().add(new THREE.Vector3(0, 5, 0)), volume: 0.9 });
        }
        this.lastAction = snap.action;
        this.lastActionAt = snap.actionStartedAt;
      }
      // the rattle while it stalks close by
      if (now >= this.nextRattleAt && !snap.hidden && RATTLE_STATES.has(snap.state) && snap.eye) {
        const eye = this.env.eye(_eye);
        if (eye.distanceTo(snap.eye) <= RATTLE_RANGE) {
          this.env.play('CreatureRattle', { position: snap.eye.clone(), volume: 0.9 });
          this.nextRattleAt = now + this.random.number(RATTLE_MIN, RATTLE_MAX);
        }
      }
    }
    // the landing noise after a jump or a fall
    const body = this.env.body();
    if (body && g.life && g.life.state === 'Alive' && this.env.mode() === 'OnFoot') {
      if (!body.grounded) {
        if (this.airborneAt === null) this.airborneAt = now;
      } else if (this.airborneAt !== null) {
        const air = now - this.airborneAt;
        this.airborneAt = null;
        if (air >= LAND_AIRTIME) g.noise(this.env.feetPosition(_feet), 'JumpLand');
      }
    } else this.airborneAt = null;
  }
}

const _eye = new THREE.Vector3();
const _feet = new THREE.Vector3();
