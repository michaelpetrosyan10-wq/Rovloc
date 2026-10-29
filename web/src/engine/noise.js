// The noise bus (NoiseAndDirectorService): every sound the Creature can hear is a pulse with a stud radius and a
// priority from NoiseConfig. `emit(position, kind, opts)` broadcasts it to every listener (`on(fn)`); W3's Hearing
// decides who hears it (same level, wall occlusion, vent path distance).
//
// The locomotion sampler (LocomotionNoiseSampler) lives here too: the player reports its MoveState and observed
// horizontal speed at 10 Hz and pulses the louder of the MoveState tier and the speed tier, paced by the kind's
// interval. Lobby rooms are silent (the safe zone). Water noises feed the splash meter; crossing its grab threshold
// fires `splashCrossed` (re-armed only after decaying below rearmBelow).

import { NoiseConfig, NoiseKinds } from './config.js';
import { Signal } from './signal.js';

const MEDIUM_BY_STATE = {
  Standing: 'Air', Sprinting: 'Air', Crouching: 'Air', DownedCrawling: 'Air', VentCrawling: 'Vent',
  VentScurrying: 'Vent', Treading: 'Water', Freestyle: 'Water', Underwater: 'Water',
};
const TIER_BY_STATE = {
  Standing: 'Walk', Sprinting: 'Sprint', Crouching: 'CrouchWalk', DownedCrawling: 'CrouchWalk',
  VentCrawling: 'SlowVentCrawl', VentScurrying: 'VentScurry', Treading: 'Treading', Freestyle: 'Freestyle',
  Underwater: 'Treading',
};
const SPEED_TIERS = { Air: NoiseConfig.SpeedTiers, Vent: NoiseConfig.VentSpeedTiers, Water: NoiseConfig.WaterSpeedTiers };
const SPLASH = NoiseConfig.SplashMeter;
const SPLASH_GAIN = { Freestyle: SPLASH.perFreestylePulse, Splash: SPLASH.perSplash, Treading: SPLASH.perTreadingPulse };
const SPLASH_CAP_FACTOR = 1.5;
const PACE_EPSILON = 1e-6;

/**
 * @typedef {Object} NoiseEvent
 * @property {import('three').Vector3} position
 * @property {string} kind NoiseConfig kind
 * @property {number} radius studs (NoiseConfig radius x radiusMultiplier)
 * @property {'Low'|'Normal'|'High'|'Critical'} priority
 * @property {'Air'|'Vent'|'Water'} medium
 * @property {string|null} level LevelId of the source
 * @property {string|null} ventNodeId
 * @property {'player'|string} source
 * @property {number} time game clock
 */

export class NoiseBus {
  /** @param {{loop: import('./loop.js').Loop, world: import('./world.js').World|null}} deps */
  constructor(deps) {
    this.loop = deps.loop;
    this.world = deps.world;
    /** @type {Signal<[NoiseEvent]>} */
    this.emitted = new Signal();
    /** @type {Signal<[NoiseEvent]>} the splash meter crossed its grab threshold */
    this.splashCrossed = new Signal();
    this.splash = { value: 0, at: 0, crossed: false };
    this.lastPulseAt = null;
    this.trackMedium = undefined;
    this.silent = false;
  }

  /** Subscribe to every pulse. Returns the disconnect function. @param {(e: NoiseEvent) => void} fn */
  on(fn) {
    return this.emitted.connect(fn);
  }

  /**
   * Emits one pulse.
   * @param {import('three').Vector3} position
   * @param {string} kind
   * @param {{radiusMultiplier?: number, level?: string, medium?: string, ventNodeId?: string, source?: string}} [opts]
   * @returns {NoiseEvent|null}
   */
  emit(position, kind, opts = {}) {
    const spec = NoiseKinds[kind];
    if (!spec) {
      console.warn('[noise] unknown kind', kind);
      return null;
    }
    const event = {
      position: position.clone(),
      kind,
      radius: spec.radius * (opts.radiusMultiplier ?? 1),
      priority: spec.priority,
      medium: opts.medium || spec.medium,
      level: opts.level ?? (this.world ? this.world.levelAt(position) : null),
      ventNodeId: opts.ventNodeId || null,
      source: opts.source || 'world',
      time: this.loop.time,
    };
    this.emitted.fire(event);
    const gain = SPLASH_GAIN[kind] || 0;
    if (gain > 0 && this.addSplash(gain, this.loop.time)) this.splashCrossed.fire(event);
    return event;
  }

  /** The louder of two kinds (radius, then priority). */
  static louder(a, b) {
    if (!a) return b;
    if (!b) return a;
    const A = NoiseKinds[a];
    const Bk = NoiseKinds[b];
    if (A.radius !== Bk.radius) return Bk.radius > A.radius ? b : a;
    return NoiseConfig.PriorityRank[Bk.priority] > NoiseConfig.PriorityRank[A.priority] ? b : a;
  }

  /** Locomotion classification: the louder of the MoveState tier and the speed tier, nil when silent / still. */
  static classify(moveState, speed) {
    const medium = MEDIUM_BY_STATE[moveState];
    if (!medium || !Number.isFinite(speed)) return null;
    let observed = null;
    for (const tier of SPEED_TIERS[medium]) {
      if (speed >= tier.minSpeed) {
        observed = tier.kind;
        break;
      }
    }
    if (!observed) return null;
    return NoiseBus.louder(observed, TIER_BY_STATE[moveState]);
  }

  /**
   * One locomotion sample of the player (10 Hz).
   * @param {import('three').Vector3} position
   * @param {string} moveState
   * @param {number} speed observed horizontal speed
   * @param {{inLobby?: boolean, level?: string, ventNodeId?: string}} [opts]
   */
  sampleLocomotion(position, moveState, speed, opts = {}) {
    const medium = MEDIUM_BY_STATE[moveState] || null;
    if (medium !== this.trackMedium) {
      this.trackMedium = medium;
      this.lastPulseAt = null;
    }
    if (this.silent || opts.inLobby || !medium) return null;
    const kind = NoiseBus.classify(moveState, speed);
    if (!kind) return null;
    const now = this.loop.time;
    const interval = NoiseKinds[kind].interval;
    if (this.lastPulseAt !== null && interval > 0 && now - this.lastPulseAt < interval - PACE_EPSILON) return null;
    this.lastPulseAt = now;
    return this.emit(position, kind, { source: 'player', level: opts.level, ventNodeId: opts.ventNodeId });
  }

  splashValue(now) {
    return Math.max(0, this.splash.value - SPLASH.decayPerSecond * Math.max(0, now - this.splash.at));
  }

  /** Adds to the splash meter; true exactly when this add crossed the grab threshold. */
  addSplash(amount, now) {
    const m = this.splash;
    let value = this.splashValue(now);
    if (m.crossed && value < SPLASH.rearmBelow) m.crossed = false;
    if (Number.isFinite(amount) && amount > 0) value = Math.min(SPLASH.grabThreshold * SPLASH_CAP_FACTOR, value + amount);
    m.value = value;
    m.at = Math.max(m.at, now);
    if (!m.crossed && value >= SPLASH.grabThreshold) {
      m.crossed = true;
      return true;
    }
    return false;
  }

  resetSplash() {
    this.splash = { value: 0, at: this.loop.time, crossed: false };
  }
}
