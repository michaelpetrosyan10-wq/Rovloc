// level4.js: the flooded natatorium (Level4_FloodedPoolController). The water, the oxygen and the grab are pool.js;
// this runs the level around them.
//
// Pool activation. A pool session starts when the player gets into the water and ends when they are out. ALERT_MIN..
// ALERT_MAX s into a session (seeded), if the Creature is wandering the level (Patrol or InvestigateNoise), it is
// alerted (Normal) to the swimmer's spot: it comes to the water, where its own senses take over. One alert per
// session, at most one every ALERT_COOLDOWN s; while the Creature is busy the alert waits.
//
// The emergency floodlights (the FloodlightSwitch's 1 s Floodlight prompt, one use per run): the lever is thrown over
// LEVER_SECONDS (the green indicator lit once it is up), the breaker clanks at the switch, and BREAKER_DELAY later the
// nine L4 Floodlight fixtures strike up ("L4_Floodlights") and stay lit for the run. At that moment a held swimmer is
// let go (ReleaseGrab "Floodlight", which stuns), and a Creature in the natatorium or stalking the water that held
// nobody is blinded (Stun for StunSeconds from the nearest lamp; Stuns + 1). Hud.FloodlightsOn.
//
// Ambience: a beat every BEAT_MIN..BEAT_MAX s, never the same kind twice in a row, BAND_MIN..BAND_MAX studs from the
// player and out of sight: PoolDrip, WaterSlosh, TileFall (over the water), DistantGroan (under the roof). None within
// QUIET_GAP s of a grab starting or ending or of the floodlights; nowhere to place one retries in RETRY s. Sounds only.

import * as THREE from 'three';
import { GameConfig } from '../config.js';
import * as Scenes from '../scenes.js';
import { S } from '../strings.js';
import { Schedule, cfMatrix, horizontalDistance, list, seededRandom, smoothstep } from '../util.js';

const LEVEL = 'Level4_FloodedPool';
const POOL_ROOM = 'L4_Natatorium';
const ALERT_MIN = 4;
const ALERT_MAX = 7;
const ALERT_COOLDOWN = 40;
const ALERT_CHECK = 1;
const ALERTABLE = new Set(['Patrol', 'InvestigateNoise']);
const HUNTING = new Set(['AquaticStalk', 'WallChase', 'VentChase']);
const LEVER_SECONDS = 0.45;
const LEVER_LIT_AT = 0.85;
const LEVER_THROW = (2 * 50 * Math.PI) / 180;
const BREAKER_DELAY = 0.35;
const LEAD = GameConfig.OneShotLead;
const BEAT_MIN = 18;
const BEAT_MAX = 36;
const BAND_MIN = 18;
const BAND_MAX = 45;
const QUIET_GAP = 8;
const RETRY = 4;
const GRID = 9;
const INSET = 3;
const WATER_LIFT = 0.1;
const CEILING_DROP = 1.2;
const BASIN_WALL = 1;
const SKIPPED_ROOMS = new Set(['Airlock', 'Chase']);
const BEAT_KINDS = ['Drip', 'Slosh', 'TileFall', 'Groan'];
const BEAT_PRESETS = { Drip: 'PoolDrip', Slosh: 'WaterSlosh', TileFall: 'TileFall', Groan: 'DistantGroan' };
const BEAT_VOLUME = { Drip: 1.2, Slosh: 1, TileFall: 1.1, Groan: 0.9 };
const RED = [0.86, 0.12, 0.08];
const GREEN = [0.2, 0.9, 0.3];

/** Level4.poolAlert: 'Wait' | 'Alert' | 'Done'. */
export function poolAlert(input) {
  if (!input.swimming || input.alerted) return 'Done';
  if (HUNTING.has(input.state)) return 'Done';
  if (input.now < input.alertAt || input.now < input.cooldownUntil) return 'Wait';
  return ALERTABLE.has(input.state) ? 'Alert' : 'Wait';
}

/** Level4.leverAt: the lever's travel (overshooting a little) `t` seconds after the throw. */
export function leverAt(t) {
  if (t <= 0) return 0;
  const u = Math.min(1, t / LEVER_SECONDS);
  if (u < 0.8) return 1.06 * (1 - (1 - u / 0.8) ** 3);
  return 1.06 - 0.06 * smoothstep(0, 1, (u - 0.8) / 0.2);
}

export class Level4 {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Level4';
    this.game = game;
    this.env = game.env;
    const meta = game.world.meta;
    const layout = meta.layouts[LEVEL];
    const origin = new THREE.Vector3(...meta.levels[LEVEL].origin);
    this.candidates = { water: [], ceiling: [] };
    const lattice = (r, y, into) => {
      const nx = Math.max(1, Math.floor((r.w - 2 * INSET) / GRID) + 1);
      const nz = Math.max(1, Math.floor((r.d - 2 * INSET) / GRID) + 1);
      for (let i = 0; i < nx; i++) {
        for (let j = 0; j < nz; j++) {
          const x = nx === 1 ? r.x + r.w / 2 : r.x + INSET + ((r.w - 2 * INSET) * i) / (nx - 1);
          const z = nz === 1 ? r.z + r.d / 2 : r.z + INSET + ((r.d - 2 * INSET) * j) / (nz - 1);
          into.push(origin.clone().add(new THREE.Vector3(x, y, z)));
        }
      }
    };
    let depth = 0;
    for (const b of list(layout.basins)) {
      const r = { x: b.rect.x + BASIN_WALL, z: b.rect.z + BASIN_WALL, w: b.rect.w - 2 * BASIN_WALL, d: b.rect.d - 2 * BASIN_WALL };
      lattice(r, b.waterLevel + WATER_LIFT, this.candidates.water);
      depth = Math.max(depth, b.depth);
    }
    for (const room of layout.rooms) {
      if (!SKIPPED_ROOMS.has(room.kind)) lattice(room.rect, (room.height ?? layout.height) - CEILING_DROP, this.candidates.ceiling);
    }
    const nat = layout.rooms.find((r) => r.id === POOL_ROOM);
    this.box = nat
      ? { low: origin.clone().add(new THREE.Vector3(nat.rect.x, -depth - 1, nat.rect.z)),
        high: origin.clone().add(new THREE.Vector3(nat.rect.x + nat.rect.w, nat.height ?? layout.height, nat.rect.z + nat.rect.d)) }
      : { low: origin.clone(), high: origin.clone() };
    this.floodlights = meta.lights.filter((l) => l.level === LEVEL && l.kind === 'Floodlight')
      .map((l) => ({ id: l.id, group: l.group, position: new THREE.Vector3(...l.pos), brightness: l.brightness }))
      .sort((a, b) => (a.id < b.id ? -1 : 1));
    const sw = game.world.entities('FloodlightSwitch', LEVEL)[0] || null;
    this.switch = sw ? {
      id: sw.id, info: sw, leverRest: cfMatrix(sw.attachments.LeverRest), prompt: sw.prompts.find((p) => p.name === 'Floodlight'),
      at: new THREE.Vector3(...sw.attachments.SwitchPrompt.slice(0, 3)),
    } : null;
    this.beats = new Schedule();
    this.lights = new Schedule();
    this.random = seededRandom(1, 'L4Pool');
    this._resetState();
    this.indicator = null;
    this.handle = null;
  }

  _resetState() {
    this.active = false;
    this.nextBeatAt = Infinity;
    this.previousBeat = null;
    this.lastQuietAt = -Infinity;
    this.swimming = false;
    this.alerted = false;
    this.alertAt = Infinity;
    this.cooldownUntil = -Infinity;
    this.nextAlertCheck = -Infinity;
    this.flipped = false;
    this.lever = null;
  }

  // ---------------------------------------------------------------------------------------------------- the switch

  _poseLever(value) {
    const s = this.switch;
    if (!s) return;
    this.env.setNodePivot(s.id, 'Lever', _m.copy(s.leverRest).multiply(_r.makeRotationX(Math.max(0, Math.min(1.06, value)) * LEVER_THROW)));
  }

  /** Flip: throws the switch (the prompt, the dev `floodlights`); false when it was thrown this run. */
  flip() {
    const g = this.game;
    if (this.flipped || !this.switch || !g.run) return false;
    const env = this.env;
    const now = env.now();
    this.flipped = true;
    // co-op: the switch is thrown on every page (coop/actions.js); the stun is counted for whoever threw it
    this.flippedHere = g.actorIsLocal();
    this.lastQuietAt = Math.max(this.lastQuietAt, now);
    env.setEntityAttribute(this.switch.id, 'On', true);
    if (this.handle) this.handle.setEnabled(false);
    this.lever = { from: now, lit: false };
    g.playAt('FloodlightBreaker', this.switch.at, { volume: 1 });
    const startAt = now + LEAD + BREAKER_DELAY;
    const args = {};
    this.floodlights.forEach((f, i) => {
      if (Scenes.FloodlightArgs[i]) args[Scenes.FloodlightArgs[i]] = f.id;
      g.lightsKeptLit.add(f.id);
    });
    g.seq.play(Scenes.FloodlightsId, startAt, args);
    this.lights.at(startAt, 'floodlights', () => this._lightsOn());
    return true;
  }

  _lightsOn() {
    const g = this.game;
    const env = this.env;
    const groups = new Set();
    for (const f of this.floodlights) {
      groups.add(f.group);
      env.setLightOverride(f.id, f.brightness);
    }
    for (const id of groups) if (id) env.setGroupFactor(id, 1);
    const centre = this.box.low.clone().add(this.box.high).multiplyScalar(0.5);
    g.playAt('FloodlightStrike', centre, { volume: 1.2 });
    const freed = g.pool.releaseGrab('Floodlight');
    // co-op: the Creature is the host's to stun (a client's copy of the switch only frees its own swimmer)
    const follower = !!g.coop && g.coop.isClient();
    if (!freed && !follower) {
      const snap = g.creature.snapshot();
      const position = snap && snap.running && snap.levelId === LEVEL ? snap.position : null;
      if (blinds(position, snap ? snap.state : 'Dormant', this.box.low, this.box.high)) {
        let from = centre;
        let best = Infinity;
        if (position) {
          for (const f of this.floodlights) {
            const d = f.position.distanceTo(position);
            if (d < best) {
              best = d;
              from = f.position;
            }
          }
        }
        g.creature.stun(GameConfig.StunSeconds, from);
        if (this.flippedHere) g.stats.increment('Stuns');
      }
    }
    g.notify('Hud.FloodlightsOn');
  }

  _stepLever(now) {
    const lever = this.lever;
    if (!lever) return;
    const t = now - lever.from;
    const value = leverAt(t);
    lever.lit = lever.lit || value >= LEVER_LIT_AT;
    this._poseLever(value);
    if (this.indicator) this.indicator.set({ color: lever.lit ? GREEN : RED });
    if (t >= LEVER_SECONDS) this.lever = null;
  }

  // ---------------------------------------------------------------------------------------------------- pool + beats

  _stepPool(now) {
    const g = this.game;
    // co-op (host): a teammate in the water counts as a swimmer too
    const remote = g.coop && g.coop.active ? g.coop.runNet.remoteSwimmerRoot() : null;
    const on = g.pool.swimming() || !!remote;
    if (on && !this.swimming) {
      this.alerted = false;
      this.alertAt = now + this.random.number(ALERT_MIN, ALERT_MAX);
    }
    this.swimming = on;
    if (now < this.nextAlertCheck) return;
    this.nextAlertCheck = now + ALERT_CHECK;
    const decision = poolAlert({ swimming: this.swimming, alerted: this.alerted, alertAt: this.alertAt,
      cooldownUntil: this.cooldownUntil, now, state: g.creature.getState() });
    if (decision === 'Done' && this.swimming) this.alerted = true;
    else if (decision === 'Alert') {
      g.creature.alert(g.pool.swimming() || !remote ? this.env.rootPosition(new THREE.Vector3()) : remote, 'Normal');
      this.alerted = true;
      this.cooldownUntil = now + ALERT_COOLDOWN;
    }
  }

  /** One beat now around the player (also the dev `poolbeat`); false when none could be placed. */
  tryBeat(only) {
    if (!this.game.playing()) return false;
    const root = this.env.rootPosition(new THREE.Vector3());
    let remaining = only ? [only] : BEAT_KINDS.slice();
    while (remaining.length) {
      const pool = remaining.filter((k) => k !== this.previousBeat);
      const kind = only || (pool.length ? pool[this.random.integer(0, pool.length - 1)] : null);
      if (!kind) return false;
      const points = (kind === 'Groan' ? this.candidates.ceiling : this.candidates.water).filter((p) => {
        const d = horizontalDistance(p, root);
        return d >= BAND_MIN && d <= BAND_MAX && !this.game.seenByAnyone(p);
      });
      if (points.length) {
        this.game.playAt(BEAT_PRESETS[kind], points[this.random.integer(0, points.length - 1)], { volume: BEAT_VOLUME[kind] });
        this.previousBeat = kind;
        return true;
      }
      remaining = remaining.filter((k) => k !== kind);
      if (only) return false;
    }
    return false;
  }

  _stepBeats(now) {
    if (now < this.nextBeatAt) return;
    if (now < this.lastQuietAt + QUIET_GAP) {
      this.nextBeatAt = this.lastQuietAt + QUIET_GAP;
      return;
    }
    this.nextBeatAt = this.tryBeat(null) ? now + this.random.number(BEAT_MIN, BEAT_MAX) : now + RETRY;
  }

  /** A grab started or ended (the beats keep quiet). */
  noteDisturbance(now) {
    this.lastQuietAt = Math.max(this.lastQuietAt, now);
  }

  // ---------------------------------------------------------------------------------------------------- lifecycle

  beginRun(run) {
    this.beats.clear();
    this.lights.clear();
    this.random = seededRandom(run.seed, 'L4Pool');
    this._resetState();
    this.game.lightsKeptLit.clear();
    if (!this.switch) return;
    const env = this.env;
    env.setEntityAttribute(this.switch.id, 'On', false);
    this._poseLever(0);
    if (this.indicator) this.indicator.remove();
    this.indicator = env.addLight({ position: this.switch.at.clone().add(new THREE.Vector3(0, 0.8, 0)), color: RED, brightness: 0.4, range: 4 });
    const spec = this.switch.prompt;
    if (this.handle) this.handle.remove();
    this.handle = env.addPrompt({
      entity: this.switch.id,
      attachment: spec ? spec.host : 'SwitchPrompt',
      text: S('Prompt.Floodlight'),
      objectText: S('Prompt.FloodlightSwitch'),
      holdSeconds: spec ? spec.holdDuration : 1,
      distance: spec ? spec.maxDistance : 7,
      requiresLineOfSight: false,
      net: 'world',
      onTriggered: () => this.flip(),
    });
  }

  endRun() {
    this.beats.clear();
    this.lights.clear();
    this.active = false;
    this.nextBeatAt = Infinity;
    this.lever = null;
    this.game.lightsKeptLit.clear();
    for (const f of this.floodlights) this.env.setLightOverride(f.id, null);
    if (this.handle) this.handle.remove();
    this.handle = null;
    if (this.indicator) this.indicator.remove();
    this.indicator = null;
  }

  levelActivated(level) {
    if (level !== LEVEL) return;
    this.active = true;
    const now = this.env.now();
    this.nextBeatAt = now + this.random.number(BEAT_MIN, BEAT_MAX);
    this.swimming = false;
    this.alerted = false;
  }

  levelDeactivated(level) {
    if (level !== LEVEL) return;
    this.active = false;
    this.nextBeatAt = Infinity;
    this.beats.clear();
  }

  tick(dt, now) {
    this._stepLever(now);
    this.lights.run(now);
    this.beats.run(now);
    if (!this.active || this.game.phase !== 'InRun') return;
    const grabbed = !!this.game.pool.grab;
    if (grabbed !== this.wasGrabbed) this.noteDisturbance(now);
    this.wasGrabbed = grabbed;
    // co-op: the pool's calls and beats are the host's (its beats heard on every page); a client only animates
    const coop = this.game.coop;
    if (coop && coop.isClient()) return;
    this._stepPool(now);
    if (coop && coop.active) coop.worldNet.mirror(() => this._stepBeats(now));
    else this._stepBeats(now);
  }

  /** Dev `floodlights` (Level 4's lights): throws the switch now. */
  devFloodlights() {
    return this.flip();
  }
}

/** Level4.blinds: a Creature stalking the water, or inside the natatorium box. */
export function blinds(position, state, low, high) {
  if (state === 'AquaticStalk') return true;
  if (!position) return false;
  return position.x >= low.x && position.x <= high.x && position.y >= low.y && position.y <= high.y &&
    position.z >= low.z && position.z <= high.z;
}

const _m = new THREE.Matrix4();
const _r = new THREE.Matrix4();
