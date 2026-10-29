// CreatureEnv: the ONE adapter between the Creature (web/src/creature) and the engine (web/src/engine, agent W2) plus
// the game (web/src/game, agent W4). Every engine call the Creature makes is in this file, so integration touches
// only here.
//
// Engine surface used (src/engine/index.js Engine):
//   loop        time, alpha, tickDt, onTick(fn, priority), onFrame(fn, priority)
//   world       meta (world.json), decoded.collision, colliders (level -> {bvh, box}), entityColliders(),
//               lineClear(a, b), raycast(origin, dir, max, opts), probeAt(pos, out), levelAt(pos), scene,
//               createCreatureModel()
//   player      body.position, moveState, mode, lifeState, setLifeState(state), locks, lock(reason),
//               unlock(reason), teleport(matrix), eye(), look(), setLook(yaw, pitch), setCameraOverride(token, fn, opts),
//               surfaceAt(pos), flashlight.on, flashlight.setEmfSource(fn), panic.setCreatureSource(fn),
//               panic.setFloor(token, value)
//   renderer    camera (position, frustum)
//   noise       on(fn), splashCrossed
//   audio       play(name, opts) -> voice {stop(fade), setVolume(v, fade), playing}
//   lighting    addLight(props) -> {set, remove}
//   input       pushContext(token, context), popContext(token)
//   ui          setVisible(visible, seconds), hudTarget, root
//   entities    get(id), list(type), attachmentWorld(id, name), setAttribute(id, key, value), setNodePivot(...)
//   settings    get(key)
//   shared      uFlickerData (flicker group factors)
//
// Game state the Roblox Creature read from other services (VentNetworkService, LifeStateService, the locker and door
// fixtures) comes from W4's hooks (bindGame); without a hook the adapter derives it from the engine (player mode, the
// entities' Roblox attributes) so the Creature still behaves.
//
// Monster collision. The Creature's collision group (Monster) walks through MonsterPassthrough parts (desks, lockers,
// door leaves, trims). When world.json's collision table carries `defaultIndexCount` (the leading triangles that are
// Default-group parts) the Creature collides with that prefix only; otherwise with the level's whole collision.

import * as THREE from 'three';
import { MeshBVH } from 'three-mesh-bvh';
import { CFrame } from './cframe.js';
import { nearest as railNearest } from './ventgraph.js';

const PASSTHROUGH = 'MonsterPassthrough';
const OCCLUDER_SKIP = 1.5; // the far face of a wall this close behind its near face is the same occluder
const FLOOR_NORMAL = 0.35;

/**
 * @typedef {Object} GameHooks what W4's systems tell the Creature (all optional)
 * @property {() => string} [lifeState] 'Lobby' | 'Alive' | 'Downed' | 'Dead' | 'Spectating'
 * @property {() => number} [downedCount] times the player has gone down this run
 * @property {(cause: string) => void} [down] LifeStateService.Down
 * @property {(cause: string) => void} [execute] LifeStateService.Execute
 * @property {() => boolean} [isInVent] VentNetworkService.IsInVent
 * @property {(graph: import('./ventgraph.js').Graph) => import('./ventgraph.js').RailPoint|null} [railPoint]
 * @property {(grateId: string) => string} [grateState] 'Closed' | 'Unscrewing' | 'Open' | 'Kicked' | 'Locked'
 * @property {(grateId: string, state: string) => void} [forceGrate] VentNetworkService.ForceGrate (the kick)
 * @property {(doorId: string) => boolean} [doorOpen] a fixture door (Gate, Airlock, RoofDoor) lets it through
 * @property {(lockerId: string) => boolean} [lockerOccupied] the player hides in this locker
 * @property {() => string|null} [playerLevel] the LevelId the player is on
 */

export class CreatureEnv {
  /** @param {any} engine the W2 Engine (or a stand-in with the same surface) */
  constructor(engine) {
    this.engine = engine;
    /** @type {GameHooks} */
    this.hooks = {};
    this.navLevel = null;
    this.monsterStatic = new Map();
    this.downs = 0;
    this.kicked = new Set();
    this.catchHooks = null;
  }

  /**
   * The game's side of a catch (W4): canCatch(kind) -> boolean, outcome(kind) -> 'Down' | 'Execute',
   * apply('Down' | 'Execute'). Without them the JumpscareHandler's own rule and the player's life state are used.
   * @param {{canCatch?: (kind: string) => boolean, outcome?: (kind: string) => string, apply?: (o: string) => void}|null} hooks
   */
  setCatchHooks(hooks) {
    this.catchHooks = hooks || null;
  }

  /** Whether the game lets a catch of `kind` start now. */
  catchAllowed(kind) {
    const h = this.catchHooks;
    return !h || typeof h.canCatch !== 'function' || !!h.canCatch(kind);
  }

  /** The game's outcome for a catch ('Downed' | 'Executed'), or null to use the handler's own rule. */
  catchOutcome(kind) {
    const h = this.catchHooks;
    if (!h || typeof h.outcome !== 'function') return null;
    const o = h.outcome(kind);
    return o === 'Down' ? 'Downed' : o === 'Execute' ? 'Executed' : null;
  }

  /** W4's game state hooks (merged; pass a key as null to drop it). @param {GameHooks} hooks */
  bindGame(hooks) {
    for (const [k, v] of Object.entries(hooks || {})) {
      if (typeof v === 'function') this.hooks[k] = v;
      else delete this.hooks[k];
    }
  }

  // ------------------------------------------------------------------ time and loop

  now() {
    return this.engine.loop.time;
  }

  /** The game clock interpolated to this render frame. */
  renderTime() {
    const loop = this.engine.loop;
    return loop.time + (loop.alpha || 0) * (loop.tickDt || 1 / 30);
  }

  onTick(fn) {
    return this.engine.loop.onTick(fn, 150);
  }

  onFrame(fn) {
    return this.engine.loop.onFrame((dt) => fn(dt, this.engine.loop.alpha || 0), 250);
  }

  meta() {
    return this.engine.world.meta;
  }

  // ------------------------------------------------------------------ world queries

  /** Sight line (Default group: walls, lockers, desks, closed doors block it). */
  lineClear(a, b) {
    return this.engine.world.lineClear(a, b);
  }

  /** Solid surfaces between two points, up to `max` (SpatialQuery.countOccluders: each wall counts once). */
  countOccluders(a, b, max) {
    const world = this.engine.world;
    let hits = 0;
    const current = a.clone();
    const dir = new THREE.Vector3();
    let lastHit = null;
    for (let guard = 0; guard < max * 3 && hits < max; guard++) {
      dir.subVectors(b, current);
      const remaining = dir.length();
      if (remaining <= 0.05) break;
      dir.divideScalar(remaining);
      const hit = world.raycast(current, dir, remaining);
      if (!hit) break;
      if (!lastHit || hit.point.distanceTo(lastHit) > OCCLUDER_SKIP) hits++;
      lastHit = hit.point.clone();
      current.copy(hit.point).addScaledVector(dir, 0.05);
    }
    return hits;
  }

  probeAt(position, out = new THREE.Color()) {
    return this.engine.world.probeAt(position, out);
  }

  surfaceAt(position) {
    const p = this.engine.player;
    return p && p.surfaceAt ? p.surfaceAt(position) : 'Concrete';
  }

  /** The level whose Monster geometry the walker collides with (the Creature's level). */
  setNavLevel(levelId) {
    this.navLevel = levelId;
  }

  _staticBvh(level) {
    if (!level) return null;
    if (this.monsterStatic.has(level)) return this.monsterStatic.get(level);
    const world = this.engine.world;
    const table = world.meta.collision && world.meta.collision[level];
    const decoded = world.decoded && world.decoded.collision && world.decoded.collision[level];
    let bvh = null;
    if (table && Number.isFinite(table.defaultIndexCount) && decoded) {
      const geometry = new THREE.BufferGeometry();
      geometry.setAttribute('position', new THREE.BufferAttribute(decoded.position, 3));
      geometry.setIndex(new THREE.BufferAttribute(decoded.index.slice(0, table.defaultIndexCount), 1));
      bvh = new MeshBVH(geometry, { maxLeafTris: 8 });
    } else {
      const c = world.colliders && world.colliders.get(level);
      bvh = c ? c.bvh : null;
    }
    this.monsterStatic.set(level, bvh);
    return bvh;
  }

  _entityShapes(level) {
    const world = this.engine.world;
    if (!world.entityColliders) return [];
    return world.entityColliders().filter((c) => c.group !== PASSTHROUGH && (!level || c.level === level));
  }

  /** Knee (-2.5) and chest (+1) rays from the root toward `to` against the Monster geometry (Locomotion's clear). */
  monsterClear(from, to) {
    for (const lift of [-2.5, 1]) {
      _o.set(from.x, from.y + lift, from.z);
      _d.set(to.x - from.x, 0, to.z - from.z);
      const len = _d.length();
      if (len <= 1e-3) continue;
      _d.divideScalar(len);
      if (this._monsterRay(_o, _d, len) !== null) return false;
    }
    return true;
  }

  _monsterRay(origin, dir, max) {
    const level = this.navLevel;
    let best = null;
    _ray.origin.copy(origin);
    _ray.direction.copy(dir);
    const bvh = this._staticBvh(level);
    if (bvh) {
      const hit = bvh.raycastFirst(_ray, THREE.DoubleSide, 0, max);
      if (hit && hit.distance <= max) best = hit.distance;
    }
    for (const e of this._entityShapes(level)) {
      _inv.copy(e.matrix).invert();
      _ray2.copy(_ray).applyMatrix4(_inv);
      const hit = e.bvh.raycastFirst(_ray2, THREE.DoubleSide, 0, Infinity);
      if (!hit) continue;
      const d = hit.point.applyMatrix4(e.matrix).distanceTo(origin);
      if (d <= max && (best === null || d < best)) best = d;
    }
    return best;
  }

  /** A downward probe on the Monster geometry for the animator's feet: the hit point, or null. */
  monsterFloorProbe(origin, direction) {
    const len = direction.length();
    if (len < 1e-6) return null;
    _d2.copy(direction).divideScalar(len);
    const d = this._monsterRay(origin, _d2, len);
    return d === null ? null : origin.clone().addScaledVector(_d2, d);
  }

  /** The walker's world queries (CreatureBody.BodyPhysics). */
  bodyPhysics() {
    return {
      pushOut: (position, radius, bottom, top) => this._pushOut(position, radius, bottom, top),
      floorHits: (x, z, fromY, maxDrop) => this._floorHits(x, z, fromY, maxDrop),
    };
  }

  _pushOut(position, radius, bottom, top) {
    const level = this.navLevel;
    const lo = Math.min(bottom + radius, (bottom + top) / 2);
    const hi = Math.max(top - radius, lo);
    _seg.start.set(position.x, lo, position.z);
    _seg.end.set(position.x, hi, position.z);
    _box.min.set(position.x - radius, lo - radius, position.z - radius);
    _box.max.set(position.x + radius, hi + radius, position.z + radius);
    const bvh = this._staticBvh(level);
    if (bvh) {
      bvh.shapecast({
        intersectsBounds: (b) => b.intersectsBox(_box),
        intersectsTriangle: (tri) => {
          const dist = tri.closestPointToSegment(_seg, _tp, _sp);
          if (dist < radius) {
            _push.subVectors(_sp, _tp);
            _push.y = 0;
            if (_push.lengthSq() < 1e-10) {
              tri.getNormal(_push);
              _push.y = 0;
            }
            if (_push.lengthSq() < 1e-10) return;
            _push.normalize().multiplyScalar(radius - dist);
            _seg.start.add(_push);
            _seg.end.add(_push);
            _box.translate(_push);
          }
        },
      });
    }
    for (const e of this._entityShapes(level)) {
      if (!e.box.intersectsBox(_box)) continue;
      _inv.copy(e.matrix).invert();
      _segL.copy(_seg).applyMatrix4(_inv);
      _before.copy(_segL.start);
      e.bvh.shapecast({
        intersectsBounds: () => true,
        intersectsTriangle: (tri) => {
          const dist = tri.closestPointToSegment(_segL, _tp, _sp);
          if (dist < radius) {
            _push.subVectors(_sp, _tp);
            if (_push.lengthSq() < 1e-10) tri.getNormal(_push);
            _push.normalize().multiplyScalar(radius - dist);
            _segL.start.add(_push);
            _segL.end.add(_push);
          }
        },
      });
      _push.subVectors(_segL.start, _before).transformDirection(e.matrix).multiplyScalar(_segL.start.distanceTo(_before));
      _push.y = 0;
      _seg.start.add(_push);
      _seg.end.add(_push);
    }
    return new THREE.Vector3(_seg.start.x, position.y, _seg.start.z);
  }

  _floorHits(x, z, fromY, maxDrop) {
    const level = this.navLevel;
    const out = [];
    _ray.origin.set(x, fromY, z);
    _ray.direction.set(0, -1, 0);
    const bvh = this._staticBvh(level);
    if (bvh) {
      for (const hit of bvh.raycast(_ray, THREE.DoubleSide, 0, maxDrop)) {
        if (hit.face && Math.abs(hit.face.normal.y) > FLOOR_NORMAL) out.push(hit.point.y);
      }
    }
    for (const e of this._entityShapes(level)) {
      _inv.copy(e.matrix).invert();
      _ray2.copy(_ray).applyMatrix4(_inv);
      for (const hit of e.bvh.raycast(_ray2, THREE.DoubleSide, 0, Infinity)) {
        const p = hit.point.applyMatrix4(e.matrix);
        if (fromY - p.y > maxDrop || p.y > fromY) continue;
        const n = hit.face ? hit.face.normal.clone().transformDirection(e.matrix) : _up;
        if (Math.abs(n.y) > FLOOR_NORMAL) out.push(p.y);
      }
    }
    out.sort((a, b) => b - a);
    return out;
  }

  // ------------------------------------------------------------------ the player

  _player() {
    return this.engine.player;
  }

  /** HumanoidRootPart centre, or null without a character. */
  playerRoot() {
    const p = this._player();
    if (!p || !p.body) return null;
    const s = this.playerLifeState();
    if (s === 'Dead' || s === 'Spectating') return null;
    return p.body.position.clone();
  }

  playerRootCFrame() {
    const root = this.playerRoot();
    if (!root) return null;
    const look = this._player().look();
    const flatLook = new THREE.Vector3(look.direction.x, 0, look.direction.z);
    if (flatLook.lengthSq() < 1e-8) flatLook.set(0, 0, -1);
    return CFrame.lookAt(root, root.clone().add(flatLook.normalize()));
  }

  playerMoveState() {
    return this._player().moveState;
  }

  playerMode() {
    return this._player().mode;
  }

  playerLifeState() {
    if (this.hooks.lifeState) return this.hooks.lifeState();
    return this._player().lifeState;
  }

  playerDownedCount() {
    if (this.hooks.downedCount) return this.hooks.downedCount();
    return this.downs;
  }

  playerFlashlightOn() {
    const f = this._player().flashlight;
    return !!f && !!f.on;
  }

  playerInVent() {
    if (this.hooks.isInVent) return !!this.hooks.isInVent();
    return this._player().mode === 'Vent';
  }

  /** Where on the duct rail the player crawls (VentNetworkService.GetRailPoint). */
  playerRailPoint(graph) {
    if (this.hooks.railPoint) return this.hooks.railPoint(graph);
    const root = this.playerRoot();
    return root ? railNearest(graph, root) : null;
  }

  playerLevel() {
    if (this.hooks.playerLevel) return this.hooks.playerLevel();
    const root = this.playerRoot();
    return (root && this.engine.world.levelAt(root)) || this.engine.currentLevel || null;
  }

  playerHasLock(reason) {
    const locks = this._player().locks;
    return !!locks && locks.has(reason);
  }

  lockPlayer(reason) {
    this._player().lock(reason);
  }

  unlockPlayer(reason) {
    this._player().unlock(reason);
  }

  /** CharacterService.Teleport of the victim's root to face the Creature. @param {CFrame} cframe */
  turnPlayer(cframe) {
    this._player().teleport(cframe.toMatrix4());
  }

  downPlayer(cause) {
    this.downs++;
    const h = this.catchHooks;
    if (h && typeof h.apply === 'function') h.apply('Down');
    else if (this.hooks.down) this.hooks.down(cause);
    else this._player().setLifeState('Downed');
  }

  executePlayer(cause) {
    const h = this.catchHooks;
    if (h && typeof h.apply === 'function') h.apply('Execute');
    else if (this.hooks.execute) this.hooks.execute(cause);
    else this._player().setLifeState('Dead');
  }

  playerEye() {
    return this._player().eye();
  }

  playerLookVector() {
    return this._player().look().direction;
  }

  setLook(yaw, pitch) {
    this._player().setLook(yaw, pitch);
  }

  // ------------------------------------------------------------------ fixtures (grates, doors, lockers)

  _entity(id) {
    const e = this.engine.entities;
    return e ? e.get(id) : null;
  }

  grateState(grateId) {
    if (this.hooks.grateState) return this.hooks.grateState(grateId);
    const e = this._entity(grateId);
    const state = (e && e.attributes && e.attributes.GrateState) || 'Closed';
    const plan = this.meta().plan;
    if (state === 'Closed' && plan && plan.lockedGrates && plan.lockedGrates[grateId] && !this.kicked.has(grateId)) return 'Locked';
    return state;
  }

  /** VentNetworkService.ForceGrate(grateId, "Kicked"): the crash, noise and panel flying of a kick. */
  forceGrate(grateId, state) {
    if (this.hooks.forceGrate) {
      this.hooks.forceGrate(grateId, state);
      return;
    }
    this.kicked.add(grateId);
    const entities = this.engine.entities;
    if (!entities) return;
    entities.setAttribute(grateId, 'GrateState', state);
    const panel = entities.attachmentWorld(grateId, 'PanelKicked');
    if (panel) entities.setNodePivot(grateId, 'Panel', panel);
    const at = entities.attachmentWorld(grateId, 'ExitAnchor');
    if (at && this.engine.noise) this.engine.noise.emit(new THREE.Vector3().setFromMatrixPosition(at), 'GrateKick', { source: 'creature' });
  }

  /** The grate's ExitAnchor (room side of the opening, floor level, facing the room). */
  grateExitAnchor(grateId) {
    const entities = this.engine.entities;
    const m = entities ? entities.attachmentWorld(grateId, 'ExitAnchor') : null;
    return m ? CFrame.fromMatrix4(m) : null;
  }

  doorOpen(doorId) {
    if (this.hooks.doorOpen) return !!this.hooks.doorOpen(doorId);
    const entities = this.engine.entities;
    if (!entities) return true;
    for (const e of entities.list()) {
      if (e.attributes && e.attributes.DoorId === doorId) {
        const s = e.attributes.DoorState;
        return s === 'Open' || s === 'Smashed' || s === undefined;
      }
    }
    return true;
  }

  /** The hideable lockers of a room: [{locker: id, front: ExitAnchor CFrame}]. */
  lockersIn(levelId, zoneId) {
    const entities = this.engine.entities;
    if (!entities) return [];
    const out = [];
    for (const e of entities.list('Locker')) {
      const a = e.attributes || {};
      if (a.LevelId !== levelId || a.ZoneId !== zoneId) continue;
      const m = entities.attachmentWorld(e.id, 'ExitAnchor');
      if (m) out.push({ locker: e.id, front: CFrame.fromMatrix4(m) });
    }
    return out;
  }

  lockerOccupied(lockerId) {
    if (this.hooks.lockerOccupied) return !!this.hooks.lockerOccupied(lockerId);
    const e = this._entity(lockerId);
    const v = e && e.attributes ? e.attributes.OccupantUserId : 0;
    return v !== undefined && v !== null && v !== 0 && v !== false;
  }

  lockerFront(lockerId) {
    const entities = this.engine.entities;
    const m = entities ? entities.attachmentWorld(lockerId, 'ExitAnchor') : null;
    return m ? CFrame.fromMatrix4(m) : null;
  }

  // ------------------------------------------------------------------ events and audio

  /** Every noise pulse, in Hearing's shape. */
  onNoise(fn) {
    return this.engine.noise.on((e) => fn({
      position: e.position.clone(),
      kind: e.kind,
      radius: e.radius,
      priority: e.priority,
      medium: e.medium,
      levelId: e.level,
      ventNodeId: e.ventNodeId || null,
      serverTime: e.time,
      sourceUserId: e.source === 'player' ? 1 : null,
    }));
  }

  /** The splash meter crossed its grab threshold (NoiseAndDirectorService.SplashThresholdCrossed). */
  onSplashCrossed(fn) {
    const s = this.engine.noise.splashCrossed;
    return s ? s.connect(() => fn()) : () => {};
  }

  /** Plays a SynthPresets voice: {position?, follow?, volume?, loop?, speed?, fadeIn?, seed?} -> voice or null. */
  play(name, opts = {}) {
    const audio = this.engine.audio;
    if (!audio || !audio.play) return null;
    return audio.play(name, opts);
  }

  // ------------------------------------------------------------------ rendering

  /** The engine's skinned creature model (bone-driven, node-batched). */
  createCreatureModel() {
    return this.engine.world.createCreatureModel();
  }

  addToScene(object) {
    this.engine.world.scene.add(object);
  }

  removeFromScene(object) {
    if (object.parent) object.parent.remove(object);
  }

  cameraPosition() {
    const cam = this.engine.renderer && this.engine.renderer.camera;
    return cam ? cam.position.clone() : null;
  }

  /** Whether a sphere around `position` is inside the camera's view. */
  inView(position, radius) {
    const cam = this.engine.renderer && this.engine.renderer.camera;
    if (!cam) return true;
    cam.updateMatrixWorld();
    _pm.multiplyMatrices(cam.projectionMatrix, cam.matrixWorldInverse);
    _frustum.setFromProjectionMatrix(_pm);
    _sphere.center.copy(position);
    _sphere.radius = radius;
    return _frustum.intersectsSphere(_sphere);
  }

  /** The level's light fixtures (world.json lights, not the moon's window spills). */
  fixtureLights(levelId) {
    return (this.meta().lights || [])
      .filter((l) => l.level === levelId && l.kind !== 'Moonlight' && !l.broken)
      .map((l) => ({ position: new THREE.Vector3(l.pos[0], l.pos[1], l.pos[2]), brightness: l.brightness, range: l.range, group: l.group }));
  }

  /** A fixture's current share of its brightness (its flicker group's factor). */
  lightFactor(light) {
    const data = this.engine.shared && this.engine.shared.uFlickerData;
    if (!data || !light.group) return 1;
    return data[light.group] ?? 1;
  }

  // ------------------------------------------------------------------ jumpscare presentation

  /** A camera override returning a CFrame each frame (null removes it). */
  setCameraOverride(token, fn, opts) {
    const player = this._player();
    if (!fn) {
      player.setCameraOverride(token, null, opts);
      return;
    }
    const position = new THREE.Vector3();
    const quaternion = new THREE.Quaternion();
    const m = new THREE.Matrix4();
    player.setCameraOverride(token, () => {
      const cf = fn();
      if (!cf) return null;
      cf.toMatrix4(m).decompose(position, quaternion, _scale);
      return { position, quaternion, fov: opts && opts.fov };
    }, opts);
  }

  pushInputContext(token, context) {
    this.engine.input.pushContext(token, context);
  }

  popInputContext(token) {
    this.engine.input.popContext(token);
  }

  isHudVisible() {
    const ui = this.engine.ui;
    return !ui || ui.hudTarget === undefined ? true : ui.hudTarget > 0.5;
  }

  setHudVisible(visible, seconds) {
    if (this.engine.ui) this.engine.ui.setVisible(visible, seconds);
  }

  setPanicFloor(token, value) {
    const panic = this._player().panic;
    if (panic) panic.setFloor(token, value);
  }

  /** A dynamic point light: {set(props), remove()}. */
  addLight(props) {
    return this.engine.lighting.addLight(props);
  }

  overlayRoot() {
    const ui = this.engine.ui;
    return ui && ui.root ? ui.root : typeof document !== 'undefined' ? document.body : null;
  }

  setting(key) {
    const s = this.engine.settings;
    return s ? s.get(key) : undefined;
  }

  // ------------------------------------------------------------------ engine hooks W2 asks W3 to register

  /** PanicFx's creature sense: () => {eye, state, hidden, targetingMe}. */
  setCreatureSource(fn) {
    const panic = this._player().panic;
    if (panic && panic.setCreatureSource) panic.setCreatureSource(fn);
  }

  /** The flashlight's EMF rule: (position) => 0..1. */
  setEmfSource(fn) {
    const f = this._player().flashlight;
    if (f && f.setEmfSource) f.setEmfSource(fn);
  }

  /** The zone the player stands in (EMF adjacency). */
  playerZone() {
    const root = this.playerRoot();
    const z = root ? this.engine.world.zoneAt(root) : null;
    return z ? z.id : null;
  }
}

const _o = new THREE.Vector3();
const _d = new THREE.Vector3();
const _d2 = new THREE.Vector3();
const _up = new THREE.Vector3(0, 1, 0);
const _ray = new THREE.Ray();
const _ray2 = new THREE.Ray();
const _inv = new THREE.Matrix4();
const _seg = new THREE.Line3();
const _segL = new THREE.Line3();
const _box = new THREE.Box3();
const _tp = new THREE.Vector3();
const _sp = new THREE.Vector3();
const _push = new THREE.Vector3();
const _before = new THREE.Vector3();
const _pm = new THREE.Matrix4();
const _frustum = new THREE.Frustum();
const _sphere = new THREE.Sphere();
const _scale = new THREE.Vector3();
