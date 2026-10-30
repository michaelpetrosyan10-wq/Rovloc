// JumpscareHandler (MonsterAIService/JumpscareHandler.luau): the Creature's catch. The brain's states call catch() when
// the Creature reaches its target; this runs the whole moment and reports how it ended. One catch at a time.
//
// catch(player, kind) validates first (nothing else is being caught, a known kind, the Creature in the world and not
// hidden or stunned, the victim playing (Alive or Downed) with a body, no Jumpscare lock already, not in a cutscene,
// within MaxReach). Then:
//   1. Lock: the victim is held (player.lock "Jumpscare": anchored, look frozen).
//   2. Face to face (facePair): the victim's root turns in place to face the Creature; the Creature's root is anchored
//      for the moment and set on the line between them at the kind's spacing, facing the victim, at its own height.
//      It only ever closes in, unless closer than the kind's minimum, where it is eased back out to it.
//   3. The moment at startAt = now + OneShotLead: the Lunge action on the rig, the victim's camera session
//      (JumpscareView: face lock, lunge, shake, flashes, cut to black) until resolveAt, the Screech at the Creature's
//      face and the JumpscareSting for the victim.
//   4. At resolveAt = startAt + LungeSeconds + HoldSeconds the outcome (outcomeFor): Downed for an Alive victim never
//      downed this run, else Executed (the game's life hooks apply it). Then unlock, the Creature's root back to how it
//      was anchored, and finished(victim, kind, outcome).
// Aborts (the victim no longer playing, the run ending, abort(reason)): no outcome; the screech and sting are cut, the
// victim's session cuts to black at once, the lock and the Creature are released, and finished fires "Aborted".

import * as THREE from 'three';
import { CFrame } from './cframe.js';
import { CreatureConfig, GameConfig, JumpscareKinds } from './config.js';
import { Signal, clamp, isFiniteVector } from './util.js';

const J = CreatureConfig.Jumpscare;
export const CAUSE = 'Creature';
export const MAX_REACH = 12;
const CUT_FADE = 0.15;
const FALLBACK_FACE_LEAD = 0.6;
const MIN_DIRECTION = 1e-3;

/** @typedef {'Downed'|'Executed'|'Aborted'} Outcome */
/** @typedef {{startAt: number, lungeEndsAt: number, resolveAt: number}} Schedule */

const SPACING = {
  Hallway: { distance: J.FaceDistance + 0.8, minimum: J.FaceDistance + 0.3 },
  Locker: { distance: J.FaceDistance + 1.4, minimum: J.FaceDistance + 0.8 },
  Vent: { distance: J.FaceDistance + 1.2, minimum: J.FaceDistance + 0.7 },
  Underwater: { distance: J.FaceDistance + 1.0, minimum: J.FaceDistance + 0.4 },
};

/**
 * Whether a catch may start, and why not: [ok, reason].
 * @param {{busy: boolean, kind: string, creatureInWorld: boolean, hidden: boolean, monsterState: string,
 *   lifeState: string, hasBody: boolean, caught: boolean, controlLock: string, distance: number}} check
 * @returns {[boolean, string|null]}
 */
export function validate(check) {
  if (check.busy) return [false, 'Busy'];
  if (!JumpscareKinds.includes(check.kind)) return [false, 'Kind'];
  if (!check.creatureInWorld) return [false, 'NoCreature'];
  if (check.hidden) return [false, 'Hidden'];
  if (check.monsterState === 'Stunned') return [false, 'Stunned'];
  if (check.lifeState !== 'Alive' && check.lifeState !== 'Downed') return [false, 'NotPlaying'];
  if (!check.hasBody) return [false, 'NoBody'];
  if (check.caught) return [false, 'Caught'];
  if (check.controlLock === 'Cutscene') return [false, 'Cutscene'];
  if (!Number.isFinite(check.distance) || check.distance > MAX_REACH) return [false, 'TooFar'];
  return [true, null];
}

/** The first catch of an Alive victim downs them; every later one (or one on a Downed victim) executes. */
export function outcomeFor(lifeState, downedCount) {
  if (lifeState === 'Alive') return downedCount <= 0 ? 'Downed' : 'Executed';
  if (lifeState === 'Downed') return 'Executed';
  return null;
}

/** The moment's timings for a catch starting at `now`. @returns {Schedule} */
export function schedule(now) {
  const startAt = now + GameConfig.OneShotLead;
  const lungeEndsAt = startAt + J.LungeSeconds;
  return { startAt, lungeEndsAt, resolveAt: lungeEndsAt + J.HoldSeconds };
}

export function spacing(kind) {
  return SPACING[kind] || SPACING.Hallway;
}

/**
 * The two roots face to face: [victim CFrame, creature CFrame].
 * @param {CFrame} victim @param {CFrame} creature @param {string} kind
 * @returns {[CFrame, CFrame]}
 */
export function facePair(victim, creature, kind) {
  const from = victim.position;
  const offset = creature.position.sub(from);
  if (!isFiniteVector(from) || !isFiniteVector(offset)) return [victim, creature];
  const flatOffset = new THREE.Vector3(offset.x, 0, offset.z);
  const distance = flatOffset.length();
  let direction;
  if (distance > MIN_DIRECTION) direction = flatOffset.divideScalar(distance);
  else {
    const look = victim.lookVector;
    const lf = new THREE.Vector3(look.x, 0, look.z);
    direction = lf.length() > MIN_DIRECTION ? lf.normalize() : new THREE.Vector3(0, 0, -1);
  }
  const s = spacing(kind);
  const at = from.clone().addScaledVector(direction, clamp(distance, s.minimum, s.distance)).add(new THREE.Vector3(0, offset.y, 0));
  return [CFrame.lookAt(from, from.clone().add(direction)), CFrame.lookAt(at, at.clone().sub(direction))];
}

/** The face point in the root's space: from the rig's face frame, else EyeHeightAboveRoot ahead. */
export function faceOffset(rootCFrame, faceWorld, poseMode) {
  if (faceWorld && isFiniteVector(faceWorld.position)) return rootCFrame.toObjectSpace(faceWorld);
  const height = CreatureConfig.EyeHeightAboveRoot[poseMode] ?? CreatureConfig.EyeHeightAboveRoot.Biped;
  return new CFrame(0, height, -FALLBACK_FACE_LEAD);
}

/**
 * @typedef {Object} HandlerDeps
 * @property {() => number} now
 * @property {(player: any) => string} lifeState
 * @property {(player: any) => number} downedCount
 * @property {(player: any, cause: string) => void} down
 * @property {(player: any, cause: string) => void} execute
 * @property {(player: any) => CFrame|null} playerRoot root CFrame of a living character (null without)
 * @property {(player: any) => boolean} caughtLock whether the victim already holds a Jumpscare lock
 * @property {(player: any) => string} controlLock the victim's highest held lock ('None', 'Cutscene', ...)
 * @property {(player: any) => void} lock
 * @property {(player: any) => void} unlock
 * @property {(player: any, cframe: CFrame) => void} turnPlayer
 * @property {() => {body: import('./body.js').CreatureBody, state: string}|null} creature
 * @property {() => CFrame|null} faceWorld the rig's face frame (FaceFrontAttachment) in world space now
 * @property {(kind: string, startAt: number) => void} playLunge
 * @property {(cue: {kind: string, startAt: number, endsAt: number, face: THREE.Vector3}) => void} victimCue
 * @property {(kind: string, now: number) => void} abortCue
 * @property {(name: string, opts: any) => any} play audio: returns a voice with stop(fade), or null
 * @property {(kind: string, player: any) => boolean} allowed the game lets this catch of `player` start
 * @property {(kind: string, player: any) => (Outcome|null)} outcome the game's outcome rule (null: outcomeFor)
 */

export class JumpscareHandler {
  /** @param {HandlerDeps} deps */
  constructor(deps) {
    this.deps = deps;
    this.active = null;
    /** (victim, kind, outcome) once a catch is over. */
    this.finished = new Signal();
  }

  isBusy() {
    return this.active !== null;
  }

  getVictim() {
    return this.active ? this.active.victim : null;
  }

  /** Starts the catch of `player` (false, nothing changed, when refused). */
  catch(player, kind) {
    const d = this.deps;
    const creature = d.creature();
    const victimRoot = d.playerRoot(player);
    const distance = creature && victimRoot ? creature.body.getPosition().distanceTo(victimRoot.position) : Infinity;
    const [ok] = validate({
      busy: this.active !== null,
      kind,
      creatureInWorld: creature !== null,
      hidden: creature ? creature.body.hidden : false,
      monsterState: creature ? creature.state : '',
      lifeState: victimRoot ? d.lifeState(player) : 'Lobby',
      hasBody: victimRoot !== null,
      caught: victimRoot !== null && d.caughtLock(player),
      controlLock: victimRoot ? d.controlLock(player) : 'None',
      distance,
    });
    if (!ok || !creature || !victimRoot || !d.allowed(kind, player)) return false;
    this._begin(creature.body, player, victimRoot, kind);
    return true;
  }

  _begin(body, victim, victimRoot, kind) {
    const d = this.deps;
    const now = d.now();
    const sched = schedule(now);
    const sequence = { victim, kind, body, wasAnchored: body.anchored, schedule: sched, screech: null, sting: null, settled: false };
    this.active = sequence;
    // 1. the victim is held
    d.lock(victim);
    // 2. face to face
    const faceInRoot = faceOffset(body.getCFrame(), d.faceWorld(), body.pose);
    const [victimTarget, creatureTarget] = facePair(victimRoot, body.getCFrame(), kind);
    d.turnPlayer(victim, victimTarget);
    if (!body.anchored) body.setAnchored(true);
    body.placeAt(creatureTarget);
    const face = creatureTarget.mul(faceInRoot).position;
    // 3. the moment
    d.playLunge(kind, sched.startAt);
    d.victimCue({ kind, startAt: sched.startAt, endsAt: sched.resolveAt, face });
    sequence.screech = d.play('Screech', { position: face });
    sequence.sting = d.play('JumpscareSting', {});
  }

  /** Steps the running catch (the service calls this every motion tick): resolves it at resolveAt. */
  update() {
    const sequence = this.active;
    if (!sequence || sequence.settled) return;
    const d = this.deps;
    const state = d.lifeState(sequence.victim);
    if (state !== 'Alive' && state !== 'Downed') {
      this._settle(sequence, 'Aborted', 'LifeState');
      return;
    }
    if (d.now() >= sequence.schedule.resolveAt) {
      const outcome = d.outcome(sequence.kind, sequence.victim) || outcomeFor(state, d.downedCount(sequence.victim));
      if (!outcome) this._settle(sequence, 'Aborted', 'NotPlaying');
      else this._settle(sequence, outcome, null);
    }
  }

  _settle(sequence, outcome, reason) {
    if (this.active !== sequence || sequence.settled) return;
    sequence.settled = true;
    const d = this.deps;
    const victim = sequence.victim;
    if (outcome === 'Downed') d.down(victim, CAUSE);
    else if (outcome === 'Executed') d.execute(victim, CAUSE);
    else {
      for (const handle of [sequence.screech, sequence.sting]) if (handle) handle.stop(CUT_FADE);
      sequence.screech = null;
      sequence.sting = null;
      d.abortCue(sequence.kind, d.now());
    }
    d.unlock(victim);
    if (sequence.body.anchored !== sequence.wasAnchored) sequence.body.setAnchored(sequence.wasAnchored);
    this.active = null;
    if (outcome === 'Aborted' && reason) console.debug(`[creature] catch aborted: ${reason}`);
    this.finished.fire(victim, sequence.kind, outcome);
  }

  /** Calls off the running catch (finished fires "Aborted"). False when nothing runs. */
  abort(reason = 'Requested') {
    const sequence = this.active;
    if (!sequence) return false;
    this._settle(sequence, 'Aborted', reason);
    return true;
  }
}
