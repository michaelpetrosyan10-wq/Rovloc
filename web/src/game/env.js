// env.js: the ONE adapter between the game (src/game) and the engine (src/engine, agent W2). Every engine call the
// game makes goes through this class, so integration changes touch only this file. The engine API it codes against
// is the one src/engine/index.js documents:
//
//   engine.loop       time, realTime, onTick(fn, priority) (30 Hz), onFrame(fn, priority), setPaused
//   engine.world      meta (world.json), raycast, lineClear, zoneAt, levelAt, probeAt, scene (the game's effects:
//                     flask shards, splashes, clouds, the aim arc, are plain three.js objects added to it)
//   engine.player     teleport, rootPosition, feetPosition, eye, look, setLook, moveState, speed, mode / setMode,
//                     pushOverride / popOverride, lock / unlock / isLocked, setLifeState, setMetersActive, meters,
//                     addStamina, refillStamina, setOxygenRate, addOxygen, addBattery, oxygenDepleted,
//                     moveStateChanged, setCameraOverride, forceCameraState, setPitchLimits, shake, setHandPose,
//                     setMotionOverride, body, intent, flashlight (on, setOn), panic (setFloor, panic,
//                     setBreathSuppressed, setCreatureSource), cameraEnabled, resetForRun
//   engine.noise      emit(position, kind, opts), on(fn), splashCrossed, resetSplash, splashValue(now)
//   engine.audio      play(name, opts) -> voice {stop(fade), setVolume, setPosition}, setAmbience,
//                     setEnvironmentOverride(token, name), stopAll
//   engine.ui         root, hud, panel, ring, keyCap, inlineKey, toast, hint, clearHint, caption, card, fade, black,
//                     setVisible, setCrosshair, setMenuButtons, openMenu, closeMenu, menuOpen
//   engine.input      on(action, fn), isHeld, pushContext / popContext, getContext, device, deviceChanged,
//                     contextChanged, setCursorFree, requestPointerLock, moveVector, setEnabled, inject
//   engine.prompts    add(spec) -> handle, clear()
//   engine.entities   get, list, setPivot, setNodePivot, setNodeTransform, nodeWorld, attachmentWorld, setVisible,
//                     setCollides, setAttribute, resetAll
//   engine.lighting   setOverride(lightId, brightness), setGroupFactor(groupId, factor), burst(lightId),
//                     lightning({intensity, stages}), setStormEnabled, resetForRun, addLight
//   engine.save / engine.settings   localStorage blob (get / set / update / flush / persistent) and the settings
//   engine            setCurrentLevel, setAmbienceEnabled, menuEnabled, syringes, renderer.camera, spawnPoints

import * as THREE from 'three';

/** @typedef {import('three').Vector3} Vector3 */
/** @typedef {import('three').Matrix4} Matrix4 */

const TMP = new THREE.Vector3();

export class Env {
  /**
   * @param {any} engine the W2 Engine instance
   */
  constructor(engine) {
    if (!engine || !engine.world || !engine.player) throw new Error('game: the engine is missing its world or player');
    this.engine = engine;
    /** world.json as W1 exported it (anchors, triggers, entities, rooms, vents, pools, plan, ...). */
    this.meta = engine.world.meta || engine.world.data;
    if (!this.meta || !this.meta.entities) throw new Error('game: the engine exposes no world metadata');
    this.THREE = THREE;
  }

  // ---------------------------------------------------------------------------------------------------- clock

  /** The game clock (seconds; stops while the loop is paused). Everything "server time" in the port uses it. */
  now() {
    return this.engine.loop.time;
  }

  /** Wall clock seconds since boot. */
  realNow() {
    return this.engine.loop.realTime;
  }

  /** Fixed 30 Hz logic. @param {(dt: number) => void} fn @returns {() => void} */
  onTick(fn, priority = 150) {
    return this.engine.loop.onTick(fn, priority);
  }

  /** Once per rendered frame, before the engine's render. @param {(dt: number, realDt?: number) => void} fn */
  onFrame(fn, priority = 150) {
    return this.engine.loop.onFrame(fn, priority);
  }

  // ---------------------------------------------------------------------------------------------------- world

  /** First hit along a ray (static levels + colliding entities unless ignoreEntities). */
  raycast(origin, dir, maxDist, opts = {}) {
    return this.engine.world.raycast(origin, dir, maxDist, opts);
  }

  /** True when nothing solid lies between a and b. */
  lineClear(a, b, opts = {}) {
    return this.engine.world.lineClear(a, b, opts);
  }

  /** The room / zone record holding a point ({id, level, ...}) or null. */
  zoneAt(p) {
    return this.engine.world.zoneAt(p);
  }

  /** The level key whose bounds hold a point. */
  levelAt(p) {
    return this.engine.world.levelAt(p);
  }

  /** Spawn anchors of a level (world.json anchors of kind PlayerSpawn). */
  spawnPoints(level) {
    return this.meta.anchors.filter((a) => a.kind === 'PlayerSpawn' && a.level === level);
  }

  /** Tells the engine the run's level (ambience fallback). */
  setCurrentLevel(level) {
    if (this.engine.setCurrentLevel) this.engine.setCurrentLevel(level);
  }

  /** The automatic ambience beds on / off (title screen, results). */
  setAmbienceEnabled(on) {
    if (this.engine.setAmbienceEnabled) this.engine.setAmbienceEnabled(on);
  }

  /** The render camera (THREE.PerspectiveCamera). */
  camera() {
    return this.engine.renderer.camera;
  }

  // ---------------------------------------------------------------------------------------------------- player

  get player() {
    return this.engine.player;
  }

  rootPosition(out = new THREE.Vector3()) {
    return out.copy(this.engine.player.rootPosition());
  }

  feetPosition(out = new THREE.Vector3()) {
    return this.engine.player.feetPosition(out);
  }

  eye(out = new THREE.Vector3()) {
    return this.engine.player.eye(out);
  }

  /** {yaw, pitch, direction} (yaw 0 faces -Z, pitch up positive, radians). */
  look() {
    return this.engine.player.look();
  }

  setLook(yaw, pitch) {
    this.engine.player.setLook(yaw, pitch);
  }

  /** Moves the root (HumanoidRootPart centre) to a CFrame (12 numbers / Matrix4 / {position, yaw}). */
  teleport(cframe) {
    this.engine.player.teleport(cframe);
  }

  moveState() {
    return this.engine.player.moveState;
  }

  /** Observed horizontal speed (studs/s). */
  speed() {
    return this.engine.player.speed;
  }

  mode() {
    return this.engine.player.mode;
  }

  /** 'OnFoot' | 'Vent' | 'Swim' */
  setMode(mode) {
    this.engine.player.setMode(mode);
  }

  pushOverride(token, state) {
    this.engine.player.pushOverride(token, state);
  }

  popOverride(token) {
    this.engine.player.popOverride(token);
  }

  /** ControlLock: anchors the body and ignores movement while held. */
  lock(reason) {
    this.engine.player.lock(reason);
  }

  unlock(reason) {
    this.engine.player.unlock(reason);
  }

  isLocked() {
    return this.engine.player.isLocked();
  }

  hasLock(reason) {
    const locks = this.engine.player.locks;
    return !!locks && locks.has(reason);
  }

  /** 'Lobby' | 'Alive' | 'Downed' | 'Dead' | 'Spectating' */
  setLifeState(state) {
    this.engine.player.setLifeState(state);
  }

  setMetersActive(active) {
    this.engine.player.setMetersActive(active);
  }

  /** @returns {{stamina: any, oxygen: any, battery: any}} meters with value / max / fraction / set / setMax */
  meters() {
    return this.engine.player.meters;
  }

  addStamina(delta) {
    this.engine.player.addStamina(delta);
  }

  refillStamina() {
    this.engine.player.refillStamina();
  }

  setOxygenRate(rate) {
    this.engine.player.setOxygenRate(rate);
  }

  addOxygen(delta) {
    this.engine.player.addOxygen(delta);
  }

  addBattery(delta) {
    this.engine.player.addBattery(delta);
  }

  /** @param {() => void} fn */
  onOxygenDepleted(fn) {
    return this.engine.player.oxygenDepleted.connect(fn);
  }

  /** @param {(next: string, prev: string) => void} fn */
  onMoveStateChanged(fn) {
    return this.engine.player.moveStateChanged.connect(fn);
  }

  /** The flashlight's switch. */
  flashlightOn() {
    return !!this.engine.player.flashlight.on;
  }

  setFlashlight(on) {
    this.engine.player.flashlight.setOn(on);
  }

  /** A camera override layer: fn() returns a Matrix4 / {position, quaternion} / {position, lookAt}; null removes. */
  setCameraOverride(token, fn, priority) {
    this.engine.player.setCameraOverride(token, fn, priority);
  }

  forceCameraState(token, state) {
    this.engine.player.forceCameraState(token, state);
  }

  setPitchLimits(minDeg, maxDeg) {
    this.engine.player.setPitchLimits(minDeg, maxDeg);
  }

  shake(amplitudeDeg, seconds) {
    this.engine.player.shake(amplitudeDeg, seconds);
  }

  /** 'Flashlight' | 'Free' | 'Pry' | 'Ripcord' | 'SlitGrip' | 'Flask' (+ target frame). */
  setHandPose(pose, target) {
    this.engine.player.setHandPose(pose, target);
  }

  /** Replaces the walking physics while held: fn(dt, player) moves player.body itself. */
  setMotionOverride(token, fn, priority = 0) {
    this.engine.player.setMotionOverride(token, fn, priority);
  }

  /** The character body (position = root centre, velocity, grounded, move(delta), feetY). */
  body() {
    return this.engine.player.body;
  }

  /** The movement intents ({crouch, sprint, dive}). */
  intent() {
    return this.engine.player.intent;
  }

  setPanicFloor(token, value) {
    this.engine.player.panic.setFloor(token, value);
  }

  panic() {
    return this.engine.player.panic.panic;
  }

  setBreathSuppressed(token, on) {
    this.engine.player.panic.setBreathSuppressed(token, on);
  }

  /** Whether the first-person camera drives the render camera. */
  setCameraEnabled(on) {
    this.engine.player.cameraEnabled = !!on;
  }

  /** Clears run-scoped camera / movement state (overrides, locks, layers, hand pose). */
  resetPlayerForRun() {
    this.engine.player.resetForRun();
  }

  /** Syringe pips on the status bars. */
  setSyringePips(n) {
    this.engine.syringes = n;
  }

  // ---------------------------------------------------------------------------------------------------- noise

  /** One noise pulse (NoiseConfig kind). */
  emitNoise(position, kind, opts = {}) {
    return this.engine.noise.emit(position, kind, opts);
  }

  onNoise(fn) {
    return this.engine.noise.on(fn);
  }

  onSplashCrossed(fn) {
    return this.engine.noise.splashCrossed.connect(fn);
  }

  resetSplash() {
    this.engine.noise.resetSplash();
  }

  splashValue() {
    return this.engine.noise.splashValue(this.now());
  }

  /** Mutes the locomotion sampler (lobby, cutscenes). */
  setNoiseSilent(silent) {
    this.engine.noise.silent = !!silent;
  }

  // ---------------------------------------------------------------------------------------------------- audio

  /**
   * Plays a SynthPresets voice.
   * @param {string} name
   * @param {{position?: Vector3, follow?: () => Vector3, volume?: number, loop?: boolean, fadeIn?: number}} [opts]
   */
  play(name, opts = {}) {
    try {
      return this.engine.audio.play(name, opts);
    } catch (err) {
      console.warn('[game] sound', name, err);
      return null;
    }
  }

  setEnvironmentOverride(token, name) {
    if (this.engine.audio.setEnvironmentOverride) this.engine.audio.setEnvironmentOverride(token, name);
  }

  stopAllSounds(fade = 0.3) {
    if (this.engine.audio.stopAll) this.engine.audio.stopAll(fade);
  }

  // ---------------------------------------------------------------------------------------------------- ui

  get ui() {
    return this.engine.ui;
  }

  /** The overlay container game screens mount into (the engine's #rv-root). */
  uiRoot() {
    return this.engine.ui.root;
  }

  toast(text, opts) {
    this.engine.ui.toast(text, opts);
  }

  hint(content, seconds) {
    this.engine.ui.hint(content, seconds);
  }

  clearHint() {
    this.engine.ui.clearHint();
  }

  caption(text, opts) {
    this.engine.ui.caption(text, opts);
  }

  /** Fades the screen toward alpha (0 clear .. 1 black). */
  fade(alpha, seconds, color) {
    return this.engine.ui.fade(alpha, seconds, color);
  }

  /** Fades the HUD (cutscenes). */
  setHudVisible(visible, seconds = 0.5) {
    this.engine.ui.setVisible(visible, seconds);
  }

  hudVisible() {
    return this.engine.ui.hudTarget !== 0;
  }

  setCrosshair(on) {
    this.engine.ui.setCrosshair(on);
  }

  /** A key glyph element for an action on the current device. */
  keyCap(parent, action, size) {
    return this.engine.ui.keyCap(parent, action, size);
  }

  inlineKey(action, size) {
    return this.engine.ui.inlineKey(action, size);
  }

  /** A clockwise SVG ring {root, setProgress, setColor, setAlpha}. */
  ring(parent, diameter, thickness, color) {
    return this.engine.ui.ring(parent, diameter, thickness, color);
  }

  /** The pause menu's buttons. */
  setMenuButtons(buttons) {
    this.engine.ui.setMenuButtons(buttons);
  }

  openMenu(title) {
    this.engine.ui.openMenu(title);
  }

  closeMenu() {
    this.engine.ui.closeMenu();
  }

  menuOpen() {
    return !!this.engine.ui.menuOpen;
  }

  /** Whether Menu / Escape opens the pause menu. */
  setMenuEnabled(on) {
    this.engine.menuEnabled = !!on;
  }

  // ---------------------------------------------------------------------------------------------------- input

  /** @param {string} action @param {(phase: 'Begin'|'End') => void} fn */
  onAction(action, fn) {
    return this.engine.input.on(action, fn);
  }

  isHeld(action) {
    return this.engine.input.isHeld(action);
  }

  pushContext(token, context) {
    this.engine.input.pushContext(token, context);
  }

  popContext(token) {
    this.engine.input.popContext(token);
  }

  context() {
    return this.engine.input.getContext();
  }

  /** 'KeyboardMouse' | 'Gamepad' | 'Touch' */
  device() {
    return this.engine.input.device;
  }

  onDeviceChanged(fn) {
    return this.engine.input.deviceChanged.connect(fn);
  }

  onContextChanged(fn) {
    return this.engine.input.contextChanged.connect(fn);
  }

  setCursorFree(token, free) {
    this.engine.input.setCursorFree(token, free);
  }

  requestPointerLock() {
    this.engine.input.requestPointerLock();
  }

  /** {x right, y forward}, length <= 1. */
  moveVector() {
    return this.engine.input.moveVector();
  }

  /** Feeds an action press / release (touch buttons drawn by the game, dev shortcuts). */
  injectAction(action, id, down) {
    this.engine.input.inject(action, id, down);
  }

  /** The key label of an action's first keyboard binding ("E", "SPACE"). */
  bindingOf(action) {
    const b = this.engine.config && this.engine.config.InputBindings && this.engine.config.InputBindings[action];
    return b || null;
  }

  // ---------------------------------------------------------------------------------------------------- prompts

  /** A proximity prompt (see engine/prompts.js PromptSpec). */
  addPrompt(spec) {
    return this.engine.prompts.add(spec);
  }

  clearPrompts() {
    this.engine.prompts.clear();
  }

  // ---------------------------------------------------------------------------------------------------- entities

  /** The engine's entity record ({id, type, level, attributes, pivot, rest, attachments, nodes, info}). */
  entity(id) {
    return this.engine.entities.get(id);
  }

  entitiesOf(type) {
    return this.engine.entities.list(type);
  }

  setEntityPivot(id, cframe) {
    this.engine.entities.setPivot(id, cframe);
  }

  /** Places a node of an entity (JawA, LeftLeaf, Panel, Screw1, Door, Lever, ParachutePack2, ...) at a world frame. */
  setNodePivot(id, node, cframe) {
    this.engine.entities.setNodePivot(id, node, cframe);
  }

  /** A node relative to its built pose (world = pivot x restLocal x transform); null restores it. */
  setNodeTransform(id, node, transform) {
    this.engine.entities.setNodeTransform(id, node, transform);
  }

  /** A node's current world frame. */
  nodeWorld(id, node, out = new THREE.Matrix4()) {
    return this.engine.entities.nodeWorld(id, node, out);
  }

  /** An attachment's current world frame. */
  attachmentWorld(id, name, out = new THREE.Matrix4()) {
    return this.engine.entities.attachmentWorld(id, name, out);
  }

  /** Shows / hides an entity (or one node of it). Hidden parts neither draw nor collide. */
  setEntityVisible(id, visible, node) {
    this.engine.entities.setVisible(id, visible, node);
  }

  setEntityCollides(id, collides) {
    this.engine.entities.setCollides(id, collides);
  }

  setEntityAttribute(id, key, value) {
    this.engine.entities.setAttribute(id, key, value);
  }

  /** Every entity back to its built pose, visibility, colliders and attributes. */
  resetEntities() {
    this.engine.entities.resetAll();
  }

  // ---------------------------------------------------------------------------------------------------- lighting

  /** Pins a light's brightness (Roblox Brightness units); null releases. */
  setLightOverride(lightId, brightness) {
    this.engine.lighting.setOverride(lightId, brightness);
  }

  /** A flicker group's factor (Scripted:Floodlights is group 13 in the export); null releases. */
  setGroupFactor(groupId, factor) {
    this.engine.lighting.setGroupFactor(groupId, factor);
  }

  /** LightBurst: the bulb surges, stutters and dies for the run. */
  burstLight(lightId) {
    this.engine.lighting.burst(lightId);
  }

  /** One lightning flash (stages 1 | 2). */
  lightning(intensity = 1, stages = 2) {
    this.engine.lighting.lightning({ intensity, stages });
  }

  setStormEnabled(on) {
    this.engine.lighting.setStormEnabled(on);
  }

  resetLighting() {
    this.engine.lighting.resetForRun();
  }

  /** A dynamic point light {set({position, color, brightness, range, enabled}), remove()}. */
  addLight(props) {
    return this.engine.lighting.addLight(props);
  }

  // ---------------------------------------------------------------------------------------------------- save

  saveGet(key, fallback) {
    return this.engine.save.get(key, fallback);
  }

  saveSet(key, value) {
    this.engine.save.set(key, value);
  }

  saveFlush() {
    this.engine.save.flush();
  }

  /** Whether localStorage accepted the last write (false in a locked-down browser). */
  savePersistent() {
    return this.engine.save.persistent !== false;
  }

  setting(key) {
    return this.engine.settings.get(key);
  }

  setSetting(key, value) {
    this.engine.settings.set(key, value);
  }

  onSettingChanged(fn) {
    return this.engine.settings.changed.connect(fn);
  }

  // ---------------------------------------------------------------------------------------------------- effects

  /** Adds a three.js object (an effect: shards, a cloud, the aim arc) to the world scene. */
  addToScene(object) {
    this.engine.world.scene.add(object);
  }

  removeFromScene(object) {
    if (object.parent) object.parent.remove(object);
  }

  /** The baked light probe's irradiance at a point (lights the effects like the world around them). */
  probeAt(p, out = new THREE.Color()) {
    return this.engine.world.probeAt(p, out);
  }

  // ---------------------------------------------------------------------------------------------------- helpers

  /** Screen position (px) of a world point, or null behind the camera. */
  project(p) {
    const camera = this.camera();
    TMP.copy(p).project(camera);
    if (TMP.z > 1) return null;
    const r = this.uiRoot().getBoundingClientRect();
    return { x: (TMP.x * 0.5 + 0.5) * r.width, y: (-TMP.y * 0.5 + 0.5) * r.height, ndcX: TMP.x, ndcY: TMP.y };
  }
}
