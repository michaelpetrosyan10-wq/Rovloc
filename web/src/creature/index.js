// The Creature for Rovloc Web ("the Tall Man", Tunnels §2): the brain and the catch (service.js), the animated, lit
// rig and its sounds (view.js, R's) and the victim's moment (jumpscareView.js, R's), for the local player.
//
//   import { createCreature } from './creature/index.js';
//   const creature = createCreature(engine);
//   creature.beginRun({ difficulty: 'Standard' });   // run start: placed Dormant on the basement
//   creature.activateLevel('Level0_Basement');       // each level the run activates (the basement is hunted too)
//   creature.deactivate();                           // run end
//
// API (MonsterAIService's, as the level code uses it):
//   getState() -> MonsterState                       getTarget() -> PLAYER | null
//   stun(seconds, from)                              alert(position, priority)
//   acquireScripted(token) -> {moveTo, teleport, setPose, setHidden, face, release, setTarget, playAction} | null
//   registerLockerInspector(fn)   fn(spotId) -> Promise<'Empty' | 'HiddenSafe' | 'Caught'> (lockers, barrels, cabinets)
//   setSpeedScale(scale)
//   stateChanged (new, old) / caught (player, kind) / jumpscareFinished (player, kind, outcome): Signals (connect)
//   activateLevel(levelId) / deactivate()            bindGame(hooks) (env.js GameHooks)
//   playAction(name, startAt?) / stopAction(name?)   one-shot animation layers on the rig
//   snapshot() / viewState() / setPaused(on) / devCommand("ai ..." | "hunt" | "ignoreme") / setClock(fn) / dispose()
//   events {stateChanged(new, old), caught(kind), jumpscareFinished(kind, outcome),
//     teleportWarning(spot, targetsMe, seconds), revealed(kind), stared(), gaveUp(position, wasMe), grunted(position)}
//     (single-player shapes: the local player's own), getPosition(), getEye(), isHidden(), getPoseMode(),
//     setDifficulty(name), setCatchHooks({canCatch(kind), outcome(kind) -> 'Down' | 'Execute', apply(outcome)}),
//     notePulled(player), reveal(kind) (the reveal scare on this page: R's jumpscareView.reveal, else a flash),
//     warnLocal(spot, seconds, targetsMe) (a teleport warning's torch stutter on this page)
//
// The player's feel (§3): the heartbeat and breathing rise when it is within Senses.NearRadius whether or not it is
// seen (a panic floor), the torch crackles with static within Senses.EmfRadius and stutters through a teleport warning
// aimed at you.

import { CreatureConfig } from './config.js';
import { CreatureEnv } from './env.js';
import { JumpscareView } from './jumpscareView.js';
import { PLAYER, MonsterAI, levelIndex } from './service.js';
import { registerMonsterSounds } from './sounds.js';
import { CreatureView } from './view.js';
import { Signal, clamp01, smoothstep } from './util.js';

export { PLAYER, levelIndex };

const EMF_FULL_SHARE = 0.15;
const NEAR_TOKEN = 'CreatureNear';
const NEAR_FLOOR_FAR = 0.27; // a slow heartbeat and breathing at the edge of NearRadius
const NEAR_FLOOR_CLOSE = 0.7; // racing within NEAR_CLOSE
const NEAR_CLOSE = 6;
const NEAR_EVERY = 0.1;
const STUTTER_HZ = 9;
const FLASH_SECONDS = 0.35;

/** Flashlight.emfIntensity: EMF 0..1 for a Creature `distance` studs away. */
export function emfIntensity(distance, radius) {
  let level = 0;
  if (distance === distance && radius > 0 && distance < radius) level = smoothstep(radius, radius * EMF_FULL_SHARE, distance);
  return clamp01(level);
}

/** The panic floor for a Creature `distance` studs away (null beyond NearRadius): the heartbeat, seen or not. */
export function nearFloor(distance) {
  const radius = CreatureConfig.Senses.NearRadius;
  if (!(distance < radius)) return null;
  return NEAR_FLOOR_FAR + (NEAR_FLOOR_CLOSE - NEAR_FLOOR_FAR) * smoothstep(radius, NEAR_CLOSE, distance);
}

/** A torch stutter's EMF at `t` seconds into it: hard on / off flicker, fading out at the end. */
export function stutter(t, seconds) {
  if (t < 0 || t > seconds) return 0;
  const on = Math.floor(t * STUTTER_HZ + Math.sin(t * 23) * 0.6) % 2 === 0;
  return on ? 1 : 0.35;
}

/**
 * Builds the Creature on an engine and wires it into the loop.
 * @param {any} engine the W2 Engine
 * @param {{env?: CreatureEnv, render?: boolean}} [opts] `render: false` runs the brain without a rig (tools)
 */
export function createCreature(engine, opts = {}) {
  registerMonsterSounds();
  const env = opts.env || new CreatureEnv(engine);
  const service = new MonsterAI(env);
  const view = opts.render === false ? null : new CreatureView(env, service);
  const jumpscareView = new JumpscareView(env, () => (view ? view.faceWorld() : null));
  service.view = view;
  service.jumpscareView = jumpscareView;

  // the heartbeat within NearRadius (seen or not), sensed at 10 Hz from the published state (a co-op client's puppet
  // publishes the host's)
  let nearClock = 0;
  let nearOn = false;
  const senseNear = (dt) => {
    nearClock += dt;
    if (nearClock < NEAR_EVERY) return;
    nearClock = 0;
    const s = service.snapshot();
    const eye = s.running && !s.hidden && s.state !== 'Dormant' && s.state !== 'Scripted' ? env.playerEye() : null;
    const floor = eye && s.eye ? nearFloor(s.eye.distanceTo(eye)) : null;
    if (floor === null && !nearOn) return;
    nearOn = floor !== null;
    env.setPanicFloor(NEAR_TOKEN, floor);
  };

  const offTick = env.onTick((dt) => {
    if (view) view.beforeTick();
    service.tick(dt);
    if (view) view.afterTick();
    senseNear(dt);
  });
  const offFrame = env.onFrame((dt, alpha) => {
    if (view) view.frame(dt, alpha);
    jumpscareView.step();
  });

  // PanicFx senses the Creature; the flashlight crackles near it (EMF) and stutters through a warning aimed at us.
  env.setCreatureSource(() => {
    const s = service.snapshot();
    if (!s.running) return null;
    return { eye: s.eye, state: s.state, hidden: s.hidden, targetingMe: s.targetingPlayer };
  });
  let stutterFrom = -Infinity;
  let stutterSeconds = 0;
  env.setEmfSource((position) => {
    const t = env.now() - stutterFrom;
    const warning = t >= 0 && t <= stutterSeconds ? stutter(t, stutterSeconds) : 0;
    const s = service.snapshot();
    if (!s.running || s.hidden) return warning;
    return Math.max(warning, emfIntensity(s.position.distanceTo(position), CreatureConfig.Senses.EmfRadius));
  });
  const warnLocal = (spot, seconds, targetsMe) => {
    if (!targetsMe) return;
    stutterFrom = env.now();
    stutterSeconds = seconds;
    env.play('TorchStutter', { volume: 0.8 });
  };

  // the reveal scare (a teleport's, a fake-out's): R's jumpscareView.reveal, else a flash, the sting and a jolt
  const reveal = (kind) => {
    if (typeof jumpscareView.reveal === 'function') {
      try {
        jumpscareView.reveal(kind);
        return;
      } catch (err) {
        console.warn('[creature] reveal failed', err);
      }
    }
    fallbackReveal(env, kind);
  };

  // single-player shapes of the events (the game's adapter reads `events` first), for the local player
  const events = {
    stateChanged: new Signal(), caught: new Signal(), jumpscareFinished: new Signal(),
    teleportWarning: new Signal(), revealed: new Signal(), stared: new Signal(), gaveUp: new Signal(), grunted: new Signal(),
    feed: new Signal(),
  };
  service.stateChanged.connect((next, previous) => events.stateChanged.fire(next, previous));
  service.caught.connect((player, kind) => {
    if (player === PLAYER) events.caught.fire(kind);
  });
  service.jumpscareFinished.connect((player, kind, outcome) => {
    if (player === PLAYER) events.jumpscareFinished.fire(kind, outcome);
  });
  service.teleportWarning.connect((spot, target, seconds) => {
    warnLocal(spot, seconds, target === PLAYER);
    events.teleportWarning.fire(spot, target === PLAYER, seconds);
  });
  service.revealed.connect((target, kind) => {
    if (target !== PLAYER) return;
    reveal(kind);
    events.revealed.fire(kind);
  });
  service.stared.connect((player) => {
    if (player === PLAYER) events.stared.fire();
  });
  service.gaveUp.connect((player, position) => events.gaveUp.fire(position, player === PLAYER));
  service.grunted.connect((position) => events.grunted.fire(position));
  service.feed.connect((event) => events.feed.fire({ ...event, player: event.player === PLAYER ? true : event.player || null }));

  return {
    PLAYER,
    events,
    service,
    view,
    env,
    getState: () => service.getState(),
    getTarget: () => (service.getTarget() === PLAYER ? PLAYER : null),
    stun: (seconds, from) => service.stun(seconds, from),
    alert: (position, priority) => service.alert(position, priority),
    acquireScripted: (token) => service.acquireScripted(token),
    setScriptedTarget: (token, target) => service.setScriptedTarget(token, target),
    registerLockerInspector: (fn) => service.registerLockerInspector(fn),
    setSpeedScale: (scale) => service.setSpeedScale(scale),
    getSpeedScale: () => service.getSpeedScale(),
    notePulled: (player = PLAYER) => service.notePulled(player),
    ignore: (player, seconds) => service.ignore(player === true ? PLAYER : player, seconds),
    relocateFrom: (entry, opts) => service.relocateFrom(entry, opts),
    stateChanged: service.stateChanged,
    caught: service.caught,
    jumpscareFinished: service.jumpscareFinished,
    beginRun: (runOpts) => service.beginRun(runOpts),
    activateLevel: (levelId) => service.activateLevel(levelId),
    deactivate: () => service.endRun(),
    bindGame: (hooks) => env.bindGame(hooks),
    playAction: (name, startAt) => (view ? view.playAction(name, startAt) : false),
    stopAction: (name) => (view ? view.stopAction(name) : undefined),
    snapshot: () => service.snapshot(),
    viewState: () => service.viewState(),
    getPosition: () => service.body.getPosition(),
    getEye: () => service.snapshot().eye,
    isHidden: () => service.body.hidden,
    getPoseMode: () => service.body.pose,
    getVentNode: () => null,
    setDifficulty: (name) => service.setDifficulty(name),
    setCatchHooks: (hooks) => env.setCatchHooks(hooks),
    setPaused: (on) => service.setPaused(on),
    devCommand: (command) => service.devCommand(command),
    setClock: (fn) => service.setClock(fn),
    reveal,
    warnLocal,
    dispose: () => {
      service.endRun();
      offTick();
      offFrame();
      env.setCreatureSource(null);
      env.setEmfSource(null);
      env.setPanicFloor(NEAR_TOKEN, null);
      if (view) view.dispose();
    },
  };
}

/** Until R's jumpscareView.reveal lands: a white-to-red flash over the screen, the sting and a camera jolt. */
function fallbackReveal(env, kind) {
  env.play('RevealSting', {});
  const player = env.engine && env.engine.player;
  const motion = clamp01(env.setting('MotionScale') ?? 1);
  if (player && typeof player.shake === 'function') player.shake(2.6 * motion, 0.45);
  const root = env.overlayRoot();
  if (!root || typeof document === 'undefined') return;
  const flashScale = clamp01(env.setting('FlashScale') ?? 1);
  const el = document.createElement('div');
  el.dataset.creatureReveal = kind;
  Object.assign(el.style, {
    position: 'absolute', inset: '0', pointerEvents: 'none', zIndex: '40', opacity: String(0.85 * flashScale),
    background: 'radial-gradient(ellipse at center, rgba(255,247,238,0.95) 0%, rgba(150,6,4,0.75) 70%, rgba(0,0,0,0.9) 100%)',
    transition: `opacity ${FLASH_SECONDS}s ease-out`,
  });
  root.appendChild(el);
  requestAnimationFrame(() => requestAnimationFrame(() => {
    el.style.opacity = '0';
  }));
  setTimeout(() => el.remove(), FLASH_SECONDS * 1000 + 120);
}
