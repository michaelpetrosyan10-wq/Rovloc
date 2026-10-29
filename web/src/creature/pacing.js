// PacingDirector (NoiseAndDirectorService/PacingDirector.luau): the Creature's tension curve, so hunts come in waves
// with breathers between them. One Pacing per run, ticked by the brain.
//
// Tension (0..1) rises while the Creature chases (ChaseRise/s), while its target is in sight (SightRise/s) and on
// near misses (a player within NearMissDistance adds up to NearMissRise/s, more the closer). It decays at Decay/s.
// Phases: BuildUp -> Peak (tension >= PeakEnter with a player within PeakProximity); BuildUp -> Relax (a chase lasting
// maxChaseSeconds); Peak -> Relax (a catch, the leash, PeakMaxSeconds, or tension fell to PeakExit with no chase);
// Relax -> BuildUp after RelaxSeconds once the catch cooldown is over (tension leaves at most RelaxExitTension). In
// Relax rises count RelaxRiseScale and tension decays at RelaxDecay. A catch pins tension at 1 and goes to Relax; an
// airlock starts a fresh BuildUp at most AirlockTension.
// CanHunt is false during the catch cooldown, the airlock grace and all of Relax. ShouldBreakChase: maxChaseSeconds
// (RelaxChaseSeconds while relaxing). HearingScale: 0.8 Relax, 1 BuildUp, 1.15 Peak.

import { difficultySpec } from './config.js';
import { clamp } from './util.js';

/** @typedef {'BuildUp'|'Peak'|'Relax'} PacingPhase */
/** @typedef {{chasing: boolean, seesTarget: boolean, nearestPlayerDistance: number|null}} PacingInput */

function tuningFor(difficulty) {
  const spec = difficultySpec(difficulty);
  const nightmare = difficulty === 'Nightmare';
  return Object.freeze({
    ChaseRise: nightmare ? 0.06 : 0.05,
    SightRise: nightmare ? 0.035 : 0.03,
    NearMissRise: 0.15,
    NearMissDistance: 12,
    Decay: nightmare ? 0.02 : 0.025,
    RelaxRiseScale: 0.25,
    RelaxDecay: 0.06,
    PeakEnter: nightmare ? 0.62 : 0.7,
    PeakProximity: nightmare ? 50 : 40,
    PeakExit: 0.3,
    PeakMaxSeconds: nightmare ? 80 : 55,
    RelaxSeconds: nightmare ? 15 : 25,
    RelaxChaseSeconds: 3,
    RelaxExitTension: 0.35,
    AirlockTension: 0.15,
    HearingScale: Object.freeze({ BuildUp: 1, Peak: 1.15, Relax: 0.8 }),
    CatchCooldownSeconds: spec.catchCooldownSeconds,
    MaxChaseSeconds: spec.maxChaseSeconds,
    AirlockGraceSeconds: spec.postAirlockGraceSeconds,
  });
}

/** Tension per second added by a player `distance` studs away. */
export function nearMissRise(tuning, distance) {
  if (distance === null || distance === undefined || !Number.isFinite(distance)) return 0;
  if (distance >= tuning.NearMissDistance) return 0;
  return tuning.NearMissRise * (1 - Math.max(distance, 0) / tuning.NearMissDistance);
}

export class Pacing {
  /** @param {string} difficulty @param {number} now */
  constructor(difficulty, now) {
    const start = Number.isFinite(now) ? now : 0;
    this.tuning = tuningFor(difficulty);
    /** @type {PacingPhase} */
    this.phase = 'BuildUp';
    this.tension = 0;
    this.clock = start;
    this.phaseSeconds = 0;
    this.chaseSeconds = 0;
    this.cooldownUntil = start;
    this.graceUntil = start;
  }

  _sync(now) {
    if (Number.isFinite(now) && now > this.clock) this.clock = now;
  }

  _enter(phase) {
    this.phase = phase;
    this.phaseSeconds = 0;
    if (phase === 'Relax') this.chaseSeconds = 0;
  }

  _near(distance) {
    return distance !== null && distance !== undefined && Number.isFinite(distance) && distance <= this.tuning.PeakProximity;
  }

  /** @param {number} dt @param {PacingInput} input @returns {PacingPhase} */
  tick(dt, input) {
    const t = this.tuning;
    const step = Number.isFinite(dt) && dt > 0 ? dt : 0;
    this.clock += step;
    this.phaseSeconds += step;
    this.chaseSeconds = input.chasing ? this.chaseSeconds + step : 0;
    let rise = nearMissRise(t, input.nearestPlayerDistance);
    if (input.chasing) rise += t.ChaseRise;
    if (input.seesTarget) rise += t.SightRise;
    const relaxing = this.phase === 'Relax';
    if (relaxing) rise *= t.RelaxRiseScale;
    const fall = relaxing ? t.RelaxDecay : t.Decay;
    this.tension = clamp(this.tension + (rise - fall) * step, 0, 1);
    if (this.phase === 'BuildUp') {
      if (this.chaseSeconds >= t.MaxChaseSeconds) this._enter('Relax');
      else if (this.tension >= t.PeakEnter && this._near(input.nearestPlayerDistance)) this._enter('Peak');
    } else if (this.phase === 'Peak') {
      const lost = !input.chasing && this.tension <= t.PeakExit;
      if (this.chaseSeconds >= t.MaxChaseSeconds || this.phaseSeconds >= t.PeakMaxSeconds || lost) this._enter('Relax');
    } else if (this.phaseSeconds >= t.RelaxSeconds && this.clock >= this.cooldownUntil) {
      this._enter('BuildUp');
      this.tension = Math.min(this.tension, t.RelaxExitTension);
    }
    return this.phase;
  }

  getPhase() {
    return this.phase;
  }

  noteCatch(now) {
    this._sync(now);
    if (Number.isFinite(now)) this.cooldownUntil = Math.max(this.cooldownUntil, now + this.tuning.CatchCooldownSeconds);
    this.tension = 1;
    this._enter('Relax');
  }

  noteAirlock(now) {
    this._sync(now);
    if (Number.isFinite(now)) this.graceUntil = Math.max(this.graceUntil, now + this.tuning.AirlockGraceSeconds);
    this.tension = Math.min(this.tension, this.tuning.AirlockTension);
    this.chaseSeconds = 0;
    this._enter('BuildUp');
  }

  canHunt(now) {
    this._sync(now);
    const at = Number.isFinite(now) ? now : this.clock;
    return this.phase !== 'Relax' && at >= this.cooldownUntil && at >= this.graceUntil;
  }

  shouldBreakChase(chaseSeconds) {
    if (!(chaseSeconds === chaseSeconds)) return false;
    let limit = this.tuning.MaxChaseSeconds;
    if (this.phase === 'Relax') limit = Math.min(limit, this.tuning.RelaxChaseSeconds);
    return chaseSeconds >= limit;
  }

  hearingScale() {
    return this.tuning.HearingScale[this.phase];
  }

  snapshot() {
    return { phase: this.phase, tension: this.tension, cooldownUntil: this.cooldownUntil, graceUntil: this.graceUntil };
  }
}

/**
 * PacingDirector.repositionPoint: of the candidates whose distance to the nearest player lies in [min, max] (all of
 * them without players), the nearest to `from` that no player can see (`visible` asked nearest first).
 * @param {import('three').Vector3[]} candidates
 * @param {import('three').Vector3[]} players
 * @param {import('three').Vector3} from
 * @param {number} minDistance @param {number} maxDistance
 * @param {(p: import('three').Vector3) => boolean} visible
 */
export function repositionPoint(candidates, players, from, minDistance, maxDistance, visible) {
  const eligible = [];
  candidates.forEach((point, index) => {
    if (!Number.isFinite(point.x) || !Number.isFinite(point.y) || !Number.isFinite(point.z)) return;
    if (players.length > 0) {
      let nearest = Infinity;
      for (const p of players) nearest = Math.min(nearest, point.distanceTo(p));
      if (nearest < minDistance || nearest > maxDistance) return;
    }
    eligible.push({ point, distance: point.distanceTo(from), index });
  });
  eligible.sort((a, b) => (a.distance !== b.distance ? a.distance - b.distance : a.index - b.index));
  for (const c of eligible) if (!visible(c.point)) return c.point;
  return null;
}
