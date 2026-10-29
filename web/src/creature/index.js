// The Creature for Rovloc Web: MonsterAIService + JumpscareHandler (the brain and the catch), CreatureController (the
// animated, lit rig and its sounds) and JumpscareController (the victim's moment), for the single player.
//
//   import { createCreature } from './creature/index.js';
//   const creature = createCreature(engine);
//   creature.beginRun({ difficulty: 'Standard' });   // run start (BeginRun): placed Dormant on Level 1
//   creature.activateLevel('Level2_ScienceHall');    // each level the run activates (LevelActivated)
//   creature.deactivate();                           // run end (EndRun)
//
// API (MonsterAIService's, as W4's level code uses it):
//   getState() -> MonsterState                       getTarget() -> PLAYER | null
//   stun(seconds, from)                              alert(position, priority)
//   acquireScripted(token) -> {moveTo, teleport, setPose, setHidden, face, release, setTarget, playAction} | null
//   registerLockerInspector(fn)   fn(lockerId) -> Promise<'Empty' | 'HiddenSafe' | 'Caught'> (or the verdict)
//   registerPoolGrabber(fn)       fn(PLAYER) -> boolean (a grab started)
//   setSpeedScale(scale)          catchGrabbed(PLAYER) -> boolean
//   stateChanged (new, old) / caught (player, kind) / jumpscareFinished (player, kind, outcome): Signals (connect)
//   activateLevel(levelId) / deactivate()            bindGame(hooks) (env.js GameHooks)
//   playAction(name, startAt?) / stopAction(name?)   one-shot animation layers on the rig
//   snapshot() / setPaused(on) / devCommand("ai ..." | "hunt" | "ignoreme") / setClock(fn) / dispose()
//   W4's extras: events {stateChanged(new, old), caught(kind), jumpscareFinished(kind, outcome)} (single-player
//   shapes), getPosition(), getEye(), isHidden(), getPoseMode(), getVentNode(), setDifficulty(name),
//   setCatchHooks({canCatch(kind), outcome(kind) -> 'Down' | 'Execute', apply(outcome)})

import { CreatureConfig, WorldDefaults } from './config.js';
import { CreatureEnv } from './env.js';
import { JumpscareView } from './jumpscareView.js';
import { PLAYER, MonsterAI, levelIndex } from './service.js';
import { CreatureView } from './view.js';
import { segmentNodes } from './perception.js';
import { adjacentZones } from './ventgraph.js';
import { Signal, clamp01, smoothstep } from './util.js';

export { PLAYER, levelIndex };

const EMF_FULL_SHARE = 0.15;
const VENT_ADJACENT_INTENSITY = 0.55;

/** Flashlight.emfIntensity: EMF 0..1 for a Creature `distance` studs away (or in an adjacent wall vent). */
export function emfIntensity(distance, radius, ventAdjacent) {
  let level = 0;
  if (distance === distance && radius > 0 && distance < radius) level = smoothstep(radius, radius * EMF_FULL_SHARE, distance);
  if (ventAdjacent) level = Math.max(level, VENT_ADJACENT_INTENSITY);
  return clamp01(level);
}

/**
 * Builds the Creature on an engine and wires it into the loop.
 * @param {any} engine the W2 Engine
 * @param {{env?: CreatureEnv, render?: boolean}} [opts] `render: false` runs the brain without a rig (tools)
 */
export function createCreature(engine, opts = {}) {
  const env = opts.env || new CreatureEnv(engine);
  const service = new MonsterAI(env);
  const view = opts.render === false ? null : new CreatureView(env, service);
  const jumpscareView = new JumpscareView(env, () => (view ? view.faceWorld() : null));
  service.view = view;
  service.jumpscareView = jumpscareView;

  const offTick = env.onTick((dt) => {
    if (view) view.beforeTick();
    service.tick(dt);
    if (view) view.afterTick();
  });
  const offFrame = env.onFrame((dt, alpha) => {
    if (view) view.frame(dt, alpha);
    jumpscareView.step();
  });

  // PanicFx senses the Creature; the flashlight flickers near it (EMF).
  env.setCreatureSource(() => {
    const s = service.snapshot();
    if (!s.running) return null;
    return { eye: s.eye, state: s.state, hidden: s.hidden, targetingMe: s.targetingPlayer };
  });
  const adjacency = new Map();
  const touches = (levelId, segment, zoneId) => {
    const key = `${levelId}|${segment}`;
    if (!adjacency.has(key)) {
      const graph = service._graph(levelId);
      const nodes = graph ? segmentNodes(graph, segment) : null;
      let zones = [];
      if (graph && nodes) {
        const rooms = (env.meta().rooms || []).filter((r) => r.level === levelId);
        const world = { ...WorldDefaults, ...(env.meta().worldConfig || {}) };
        zones = adjacentZones(rooms, graph.nodes[nodes[0]].position, graph.nodes[nodes[1]].position, world);
      }
      adjacency.set(key, new Set(zones));
    }
    return adjacency.get(key).has(zoneId);
  };
  env.setEmfSource((position) => {
    const s = service.snapshot();
    if (!s.running) return 0;
    let adjacent = false;
    if (s.inVent && s.segment) {
      const zone = env.playerZone();
      if (zone) adjacent = touches(s.levelId, s.segment, zone);
    }
    return emfIntensity(s.position.distanceTo(position), CreatureConfig.Senses.EmfRadius, adjacent);
  });

  // single-player shapes of the events (W4's adapter reads `events` first): caught(kind),
  // jumpscareFinished(kind, outcome)
  const events = { stateChanged: new Signal(), caught: new Signal(), jumpscareFinished: new Signal() };
  service.stateChanged.connect((next, previous) => events.stateChanged.fire(next, previous));
  service.caught.connect((_player, kind) => events.caught.fire(kind));
  service.jumpscareFinished.connect((_player, kind, outcome) => events.jumpscareFinished.fire(kind, outcome));

  return {
    PLAYER,
    events,
    service,
    view,
    env,
    getState: () => service.getState(),
    getTarget: () => service.getTarget(),
    stun: (seconds, from) => service.stun(seconds, from),
    alert: (position, priority) => service.alert(position, priority),
    acquireScripted: (token) => service.acquireScripted(token),
    setScriptedTarget: (token, target) => service.setScriptedTarget(token, target),
    registerLockerInspector: (fn) => service.registerLockerInspector(fn),
    registerPoolGrabber: (fn) => service.registerPoolGrabber(fn),
    setSpeedScale: (scale) => service.setSpeedScale(scale),
    getSpeedScale: () => service.getSpeedScale(),
    catchGrabbed: (player = PLAYER) => service.catchGrabbed(player),
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
    getPosition: () => service.body.getPosition(),
    getEye: () => service.snapshot().eye,
    isHidden: () => service.body.hidden,
    getPoseMode: () => service.body.pose,
    getVentNode: () => (service.mover && service.mover.getMedium() === 'Vent' ? service.mover.nearestNode() : null),
    setDifficulty: (name) => service.setDifficulty(name),
    setCatchHooks: (hooks) => env.setCatchHooks(hooks),
    setPaused: (on) => service.setPaused(on),
    devCommand: (command) => service.devCommand(command),
    setClock: (fn) => service.setClock(fn),
    dispose: () => {
      service.endRun();
      offTick();
      offFrame();
      env.setCreatureSource(null);
      env.setEmfSource(null);
      if (view) view.dispose();
    },
  };
}
