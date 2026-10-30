// parachute.js: the roof jump (ParachuteService + ParachuteMotion + ParachuteController), for the one player.
//
// Packs: the crate's ParachutePack nodes, each with its ParachuteGrab prompt (0.5 s). An Alive player on the live roof
// who wears no pack takes one (Hud.ParachuteHaveOne refuses a second): the pack vanishes from the crate, the buckles
// click (PackBuckle), Hud.ParachuteTaken: Packed. A pack goes back into the crate when its wearer dies before jumping.
// While the roof objective keeps the crate chained (setCrateOpen(false)) no pack can be taken.
//
// The jump (advance, at the tick rate while the roof is the live level):
//   None / Packed  a root off the roof (offRoof: LeaveClear past the exterior wall's outer face, or past the face and
//                  dropping under the deck; the stair towers never count): with a pack, Freefall; without one, Falling,
//                  executed ("Fall") past FatalDrop or on whatever it hits.
//   Freefall       the cord (Ripcord: Space / A / PULL CORD) opens the canopy; so does the ground coming up to
//                  AutoDeployClearance or FreefallMax in the air (the late, harder canopy: a hard landing). Down on
//                  something first: landed hard.
//   Canopy         the root flies at canopyVelocity (DescentSpeed down, DriftSpeed out along the edge's outward normal),
//                  the Parachuting MoveState, CanopyDeploy and the canopy fluttering; the camera turns over LOOKBACK_BLEND
//                  to stare back up at the ledge with the canopy's sway (lookback) after the opening jolt; the HUD
//                  hides, the storm stops (the finale owns the sky) and the Cutscene context holds the view. Down
//                  (landed: within the standing height + LandingSlack over the ground) or CanopyMax in the air: Landed.
//   Landed         ParachuteLanding (HardLanding after an auto-deploy), the knees taking it (landingDip), the body held
//                  (the Parachute lock) for the finale camera; a Downed jumper is back on their feet. Level 5 escapes
//                  them and ends the hold once the finale has played (releaseHold).
// forceLand puts a jumper still in the air on the ground under them (the finale's fade). The edge hint near the gap:
// Hud.RoofLeap with a pack on, Hud.RoofNoPack without; Hud.Ripcord.<device> while falling; the wind roars with speed.

import * as THREE from 'three';
import { GameConfig } from '../config.js';
import { S } from '../strings.js';
import { cfPos, clamp01, frameAt, lookAtMatrix, smoothstep, yawOf } from '../util.js';

const LEVEL = 'Level5_Roof';
const LEAVE_CLEAR = 2.2;
const DROP_Y = 1.5;
const DESCENT = GameConfig.ParachuteDescentSpeed;
const HARD_DESCENT = 15;
const DRIFT = 7;
const AUTO_CLEARANCE = 32;
const FATAL_DROP = 26;
const FREEFALL_MAX = 3.5;
const CANOPY_MAX = 30;
const ROOT_HEIGHT = 3;
const LANDING_SLACK = 0.9;
const WARN_DISTANCE = 10;
const LEDGE_AIM = 2.5;
const LANDING_REVIVE = 0.35;
const GROUND_REACH = 400;
const LOOKBACK_BLEND = 0.9;
const FOCUS_FOV = 46;
const BASE_FOV = 70;
const RIPCORD_SECONDS = 0.35;
const WIND_SPEED_FULL = 120;
const SHAKE_EVERY = 0.15;
const PACK_HOLD = 0.5;
const TAU = Math.PI * 2;

/** The roof's measures (ParachuteMotion) from the export: the deck, the footprint, the wall face, the gap, the towers. */
export function roofGeometry(meta) {
  const wc = meta.worldConfig;
  const layout = meta.layouts[LEVEL];
  const origin = new THREE.Vector3(...meta.levels[LEVEL].origin);
  const school = wc.SchoolOrigin || [0, 0, 0];
  const exit = layout.rooms.find((r) => r.id === layout.exit);
  return {
    deckY: origin.y,
    groundY: wc.ParachuteLandingY,
    footprint: { minX: school[0], maxX: school[0] + wc.FootprintSize[0], minZ: school[2], maxZ: school[2] + wc.FootprintSize[1] },
    face: wc.ExteriorWallThickness / 2,
    gap: { minX: origin.x + exit.rect.x, maxX: origin.x + exit.rect.x + exit.rect.w, minZ: origin.z + exit.rect.z, maxZ: origin.z + exit.rect.z + exit.rect.d },
    towers: Object.values(wc.Towers).map((t) => ({ minX: school[0] + t.minX, maxX: school[0] + t.maxX, minZ: school[2] + t.minZ, maxZ: school[2] + t.maxZ })),
  };
}

function rectDistance(r, p) {
  const dx = Math.max(r.minX - p.x, 0, p.x - r.maxX);
  const dz = Math.max(r.minZ - p.z, 0, p.z - r.maxZ);
  return Math.hypot(dx, dz);
}

const inRect = (r, p) => p.x >= r.minX && p.x <= r.maxX && p.z >= r.minZ && p.z <= r.maxZ;

/** ParachuteMotion.offRoof */
export function offRoof(g, p) {
  if (g.towers.some((t) => inRect(t, p))) return false;
  const out = rectDistance(g.footprint, p);
  if (out <= g.face) return false;
  return out >= g.face + LEAVE_CLEAR || p.y < g.deckY + DROP_Y;
}

/** ParachuteMotion.edgePoint: the footprint's edge nearest the point, at deck height. */
export function edgePoint(g, p, out = new THREE.Vector3()) {
  const f = g.footprint;
  let x = Math.min(f.maxX, Math.max(f.minX, p.x));
  let z = Math.min(f.maxZ, Math.max(f.minZ, p.z));
  if (x === p.x && z === p.z) {
    const west = x - f.minX;
    const east = f.maxX - x;
    const north = z - f.minZ;
    const south = f.maxZ - z;
    const nearest = Math.min(west, east, north, south);
    if (nearest === west) x = f.minX;
    else if (nearest === east) x = f.maxX;
    else if (nearest === north) z = f.minZ;
    else z = f.maxZ;
  }
  return out.set(x, g.deckY, z);
}

/** ParachuteMotion.outward: the edge's outward horizontal normal. */
export function outward(g, p) {
  const edge = edgePoint(g, p);
  const away = new THREE.Vector3(p.x - edge.x, 0, p.z - edge.z);
  if (rectDistance(g.footprint, p) > 1e-3 && away.length() > 1e-3) return away.normalize();
  const f = g.footprint;
  if (edge.x === f.minX) return new THREE.Vector3(-1, 0, 0);
  if (edge.x === f.maxX) return new THREE.Vector3(1, 0, 0);
  if (edge.z === f.minZ) return new THREE.Vector3(0, 0, -1);
  return new THREE.Vector3(0, 0, 1);
}

export function canopyVelocity(direction, auto) {
  const flat = new THREE.Vector3(direction.x, 0, direction.z);
  const drift = flat.length() > 1e-3 ? flat.normalize().multiplyScalar(DRIFT) : flat.set(0, 0, 0);
  return drift.add(new THREE.Vector3(0, -(auto ? HARD_DESCENT : DESCENT), 0));
}

/** The opening shock (eye space): the head snapped down, a bounce, settled by 0.9 s. */
export function deployJolt(t, scale, out = new THREE.Matrix4()) {
  const amount = clamp01(scale);
  if (t <= 0 || t >= 0.9 || amount <= 0) return out.identity();
  const envelope = smoothstep(0, 0.05, t) * Math.exp(-6 * t) * amount;
  const pitch = -((11 * Math.PI) / 180) * envelope * Math.cos(t * 14);
  const roll = ((3 * Math.PI) / 180) * envelope * Math.sin(t * 23);
  return out.makeRotationFromEuler(_e.set(pitch, 0, roll, 'XYZ')).setPosition(0, -0.5 * envelope, 0);
}

/** The knees taking the landing (eye space). */
export function landingDip(t, hard, scale, out = new THREE.Matrix4()) {
  const amount = clamp01(scale);
  const length = hard ? 1.2 : 0.7;
  if (t <= 0 || t >= length || amount <= 0) return out.identity();
  const u = t / length;
  const envelope = smoothstep(0, 0.12, u) * (1 - smoothstep(0.3, 1, u)) * amount;
  const pitch = -(((hard ? 13 : 6) * Math.PI) / 180) * envelope;
  const roll = hard ? ((5 * Math.PI) / 180) * envelope * Math.sin(t * 9) : 0;
  return out.makeRotationFromEuler(_e.set(pitch, 0, roll, 'XYZ')).setPosition(0, -(hard ? 1.6 : 0.8) * envelope, 0);
}

export class Parachute {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Parachute';
    this.game = game;
    this.env = game.env;
    this.geo = roofGeometry(game.world.meta);
    const crate = game.world.entities('ParachuteCrate')[0] || null;
    this.crate = crate;
    this.packs = crate ? crate.nodes.filter((n) => /^ParachutePack\d+$/.test(n.path)).map((n, i) => ({
      node: n.path,
      at: cfPos((crate.prompts[i] || {}).hostCFrame || n.pivot),
      prompt: crate.prompts[i] || null,
      taken: false,
      handle: null,
    })) : [];
    this.state = 'None';
    this.since = 0;
    this.pack = null;
    this.leftFrom = null;
    this.direction = null;
    this.velocity = null;
    this.auto = false;
    this.deployedAt = null;
    this.landedAt = null;
    this.hard = false;
    this.pullAt = null;
    this.focus = 0;
    this.focusHead = null;
    this.wind = null;
    this.flutter = null;
    this.hintKey = null;
    this.viewHeld = false;
    this.ripcordUntil = 0;
    this.nextShakeAt = 0;
    this.env.onAction('Ripcord', (phase) => {
      if (phase === 'Begin') this.pull();
    });
    game.life.changed.connect((state) => {
      if (state !== 'Alive' && state !== 'Downed' && this.state === 'Packed') this._returnPack();
    });
  }

  // ---------------------------------------------------------------------------------------------------- reads

  /** Whether the player has jumped (off the roof with or without a pack). */
  jumped() {
    return this.state === 'Freefall' || this.state === 'Canopy' || this.state === 'Landed' || this.state === 'Falling';
  }

  /** Whether a point stands in a stair tower beside the school (the stairwell, not the roof). */
  inTower(p) {
    return this.geo.towers.some((t) => inRect(t, p));
  }

  /** The untaken pack nearest `from` (the tracker's target), or null. */
  freePackPoint(from) {
    let best = null;
    let bestD = Infinity;
    for (const p of this.packs) {
      if (p.taken) continue;
      const d = p.at.distanceTo(from);
      if (d < bestD) {
        bestD = d;
        best = p.at;
      }
    }
    return best ? best.clone() : null;
  }

  /** The jump gap's centre on the deck. */
  gapCentre() {
    const g = this.geo.gap;
    return new THREE.Vector3((g.minX + g.maxX) / 2, this.geo.deckY, (g.minZ + g.maxZ) / 2);
  }

  /** A read-only view of the jump (ParachuteService.GetJump). */
  jump() {
    return { state: this.state, since: this.since, leftFrom: this.leftFrom, deployedAt: this.deployedAt, landedAt: this.landedAt,
      auto: this.auto, hard: this.hard };
  }

  /** The finale's focus track: the lookback tightening from the ledge onto the Creature's eyes (0..1). */
  setFinaleFocus(head, value) {
    this.focusHead = head ? head.clone() : null;
    this.focus = clamp01(value);
  }

  // ---------------------------------------------------------------------------------------------------- packs

  /** Whether this page's player wears a pack (packed, falling with it or under the canopy). */
  hasPack() {
    return this.state === 'Packed' || this.state === 'Freefall' || this.state === 'Canopy';
  }

  /** Co-op: a teammate took this pack on their page. */
  _takenElsewhere(pack) {
    pack.taken = true;
    if (pack.handle) pack.handle.setEnabled(false);
    if (this.crate) this.env.setEntityVisible(this.crate.id, false, pack.node);
  }

  /** Co-op: the teammate's pack went back into the crate. */
  _returnedElsewhere(pack) {
    pack.taken = false;
    if (pack.handle) pack.handle.setEnabled(this.crateOpen !== false);
    if (this.crate) this.env.setEntityVisible(this.crate.id, true, pack.node);
  }

  /** Co-op: hands a claimed pack back to the squad. */
  _release(pack) {
    const coop = this.game.coop;
    if (coop && coop.active && pack.handle) coop.actions.release(pack.handle.id);
  }

  _take(pack) {
    const g = this.game;
    if (pack.taken || !g.live() || g.level !== LEVEL || g.life.state !== 'Alive') {
      this._release(pack);
      return;
    }
    if (this.pack || this.state !== 'None') {
      this.env.hint(S('Hud.ParachuteHaveOne'), 3);
      this._release(pack);
      return;
    }
    pack.taken = true;
    pack.handle.setEnabled(false);
    this.env.setEntityVisible(this.crate.id, false, pack.node);
    this.pack = pack;
    this.state = 'Packed';
    this.since = this.env.now();
    g.playAt('PackBuckle', this.env.rootPosition(new THREE.Vector3()));
    this.env.toast(S('Hud.ParachuteTaken'));
  }

  _returnPack() {
    const pack = this.pack;
    this.pack = null;
    if (this.state === 'Packed') this.state = 'None';
    if (!pack) return;
    pack.taken = false;
    if (pack.handle) pack.handle.setEnabled(this.crateOpen !== false);
    this.env.setEntityVisible(this.crate.id, true, pack.node);
    this._release(pack);
  }

  /** The roof objective's lock: while the crate is chained (false) no pack can be taken. */
  setCrateOpen(open) {
    this.crateOpen = !!open;
    for (const p of this.packs) if (p.handle) p.handle.setEnabled(this.crateOpen && !p.taken);
  }

  /** Dev `chute give`: a pack on (no crate pack taken). */
  give() {
    if (this.state !== 'None') return false;
    this.state = 'Packed';
    this.since = this.env.now();
    return true;
  }

  // ---------------------------------------------------------------------------------------------------- the jump

  /** ParachutePull: the cord (only while falling with a pack). */
  pull() {
    if (this.state !== 'Freefall' || this.game.life.state !== 'Alive') return false;
    this.pullAt = this.env.now();
    this.ripcordUntil = this.env.realNow() + RIPCORD_SECONDS;
    this._deploy(false);
    return true;
  }

  _ground(p) {
    const hit = this.env.raycast(_o.set(p.x, p.y - 0.5, p.z), _down, GROUND_REACH, { ignoreEntities: false });
    return hit ? hit.point.y : null;
  }

  _leap(root) {
    const env = this.env;
    this.state = 'Freefall';
    this.since = env.now();
    this.leftFrom = root.clone();
    this.direction = outward(this.geo, root);
    env.pushContext('Parachute', 'Parachute');
    env.hint(S(`Hud.Ripcord.${env.device()}`), 4);
    this.wind = env.play('WindRush', { loop: true, volume: 0, fadeIn: 0.2 });
  }

  _deploy(auto) {
    const env = this.env;
    const g = this.game;
    const now = env.now();
    this.state = 'Canopy';
    this.since = now;
    this.auto = auto;
    this.deployedAt = now;
    this.velocity = canopyVelocity(this.direction || new THREE.Vector3(-1, 0, 0), auto);
    env.popContext('Parachute');
    env.pushOverride('Parachute', 'Parachuting');
    env.setMotionOverride('Canopy', (dt) => this._fly(dt), 4);
    g.playAt('CanopyDeploy', env.rootPosition(new THREE.Vector3()));
    if (this.wind) this.wind.stop(0.8);
    this.wind = null;
    this.flutter = env.play('CanopyFlutter', { loop: true, volume: 0.8, fadeIn: 0.3 });
    env.setStormEnabled(false);
    env.setHudVisible(false);
    this._holdView();
    this._startCamera();
  }

  _fly(dt) {
    const body = this.env.body();
    body.velocity.copy(this.velocity);
    body.move(_d.copy(this.velocity).multiplyScalar(dt));
  }

  _land(hard) {
    const env = this.env;
    const g = this.game;
    const now = env.now();
    const wasCanopy = this.state === 'Canopy';
    this.state = 'Landed';
    this.since = now;
    this.landedAt = now;
    this.hard = hard;
    env.setMotionOverride('Canopy', null);
    env.popOverride('Parachute');
    env.popContext('Parachute');
    if (this.wind) this.wind.stop(0.4);
    this.wind = null;
    if (this.flutter) this.flutter.stop(0.6);
    this.flutter = null;
    const root = env.rootPosition(new THREE.Vector3());
    g.playAt(hard ? 'HardLanding' : 'ParachuteLanding', root);
    g.lock('Parachute');
    if (g.life.state === 'Downed') g.life.revive(LANDING_REVIVE);
    if (!wasCanopy) {
      env.setStormEnabled(false);
      env.setHudVisible(false);
      this._holdView();
      this._startCamera();
    }
  }

  /** ForceLand: a jumper still in the air is put on the ground under them and lands. */
  forceLand() {
    if (this.state !== 'Canopy' && this.state !== 'Freefall') return false;
    const env = this.env;
    const root = env.rootPosition(new THREE.Vector3());
    const ground = this._ground(root);
    env.teleport({ position: new THREE.Vector3(root.x, (ground ?? this.geo.groundY) + ROOT_HEIGHT, root.z), yaw: env.look().yaw });
    this._land(false);
    return true;
  }

  /** ReleaseHold: the lander's hold ends once the finale has played for them. */
  releaseHold() {
    if (this.state !== 'Landed') return false;
    this.game.unlock('Parachute');
    this._releaseView();
    return true;
  }

  _holdView() {
    if (this.viewHeld) return;
    this.viewHeld = true;
    this.env.pushContext('ParachuteView', 'Cutscene');
  }

  _releaseView() {
    const env = this.env;
    if (this.viewHeld) env.popContext('ParachuteView');
    this.viewHeld = false;
    env.setCameraOverride('Parachute', null);
    env.setHudVisible(true);
  }

  // ---------------------------------------------------------------------------------------------------- the camera

  _startCamera() {
    const env = this.env;
    env.setCameraOverride('Parachute', () => this._view(), { priority: 5, blendIn: LOOKBACK_BLEND, blendOut: 0.6 });
    env.setHandPose('Free');
  }

  _view() {
    const env = this.env;
    const now = env.renderNow();
    const eye = env.eye(_eye);
    const ledge = edgePoint(this.geo, this.leftFrom || eye, _ledge).add(_up.set(0, LEDGE_AIM, 0));
    const aim = _aim.copy(ledge);
    if (this.focusHead && this.focus > 0) aim.lerp(this.focusHead, this.focus);
    if (Math.hypot(aim.x - eye.x, aim.z - eye.z) < 0.5) aim.z += 0.5;
    const scale = clamp01(env.setting('MotionScale') ?? 1);
    const t = now - (this.deployedAt ?? now);
    const view = lookAtMatrix(eye, aim, _view);
    const roll = ((2.4 * Math.PI) / 180) * Math.sin(t * TAU * 0.14) * scale;
    const yaw = ((1.2 * Math.PI) / 180) * Math.sin(t * TAU * 0.085 + 1.3) * scale;
    const pitch = ((0.8 * Math.PI) / 180) * Math.sin(t * TAU * 0.11 + 0.4) * scale;
    view.multiply(_m.makeRotationFromEuler(_e.set(pitch, yaw, roll, 'XYZ')));
    if (this.deployedAt !== null) view.multiply(deployJolt(now - this.deployedAt, scale, _m));
    if (this.landedAt !== null) view.multiply(landingDip(now - this.landedAt, this.hard, scale, _m));
    // the base look follows, so the view is the player's own when the hold ends
    _dir.set(-view.elements[8], -view.elements[9], -view.elements[10]);
    env.setLook(yawOf(_dir), Math.asin(Math.max(-1, Math.min(1, _dir.y))));
    // the view narrows onto the Creature with the finale's focus (the camera stack reads frame.fov)
    view.fov = this.focus > 0 ? BASE_FOV + (FOCUS_FOV - BASE_FOV) * this.focus : undefined;
    return view;
  }

  // ---------------------------------------------------------------------------------------------------- drive

  beginRun() {
    this._reset();
    for (const p of this.packs) {
      p.taken = false;
      if (this.crate) this.env.setEntityVisible(this.crate.id, true, p.node);
      if (p.handle) p.handle.remove();
      const spec = p.prompt;
      p.handle = this.env.addPrompt({
        position: p.at,
        text: S('Prompt.ParachuteGrab'),
        objectText: S('Prompt.Parachute'),
        holdSeconds: spec ? spec.holdDuration : PACK_HOLD,
        distance: spec ? spec.maxDistance : 7,
        requiresLineOfSight: false,
        // co-op: one pack per teammate (the host grants it); it leaves the crate on every page, and comes back when
        // its wearer dies or leaves before jumping
        net: 'claim',
        netRemote: () => this._takenElsewhere(p),
        netRelease: () => this._returnedElsewhere(p),
        onTriggered: () => this._take(p),
      });
    }
  }

  endRun() {
    this._reset();
    for (const p of this.packs) {
      if (p.handle) p.handle.remove();
      p.handle = null;
    }
  }

  _reset() {
    const env = this.env;
    if (this.state === 'Freefall') env.popContext('Parachute');
    if (this.state === 'Canopy') {
      env.setMotionOverride('Canopy', null);
      env.popOverride('Parachute');
    }
    if (this.wind) this.wind.stop(0.3);
    if (this.flutter) this.flutter.stop(0.3);
    this.wind = null;
    this.flutter = null;
    this._releaseView();
    env.setStormEnabled(true);
    this.state = 'None';
    this.pack = null;
    this.leftFrom = null;
    this.direction = null;
    this.velocity = null;
    this.auto = false;
    this.deployedAt = null;
    this.landedAt = null;
    this.hard = false;
    this.pullAt = null;
    this.focus = 0;
    this.focusHead = null;
    this.hintKey = null;
  }

  tick(dt, now) {
    const g = this.game;
    if (!g.live() || g.level !== LEVEL) return;
    const env = this.env;
    const root = env.rootPosition(_root);
    const ground = this.state === 'None' || this.state === 'Packed' ? null : this._ground(root);
    const down = ground !== null && root.y - ground <= ROOT_HEIGHT + LANDING_SLACK;
    const life = g.life.state;
    if (life !== 'Alive' && life !== 'Downed') return;
    switch (this.state) {
      case 'None':
        if (offRoof(this.geo, root)) {
          this.state = 'Falling';
          this.since = now;
          this.leftFrom = root.clone();
        }
        break;
      case 'Packed':
        if (offRoof(this.geo, root)) this._leap(root);
        break;
      case 'Falling':
        if (down || root.y <= this.geo.deckY - FATAL_DROP) g.life.execute('Fall');
        break;
      case 'Freefall':
        if (down) this._land(true);
        else if (ground !== null && root.y - ground <= AUTO_CLEARANCE) this._deploy(true);
        else if (now - this.since >= FREEFALL_MAX) this._deploy(true);
        break;
      case 'Canopy':
        if (down) this._land(false);
        else if (now - this.since >= CANOPY_MAX) this.forceLand();
        break;
      default:
        break;
    }
  }

  frame(dt) {
    const env = this.env;
    const g = this.game;
    // the edge hint near the gap
    if (g.live() && g.level === LEVEL && (this.state === 'None' || this.state === 'Packed') && g.life.state === 'Alive') {
      const root = env.rootPosition(_root);
      const key = !offRoof(this.geo, root) && rectDistance(this.geo.gap, root) <= WARN_DISTANCE
        ? (this.state === 'Packed' ? 'Hud.RoofLeap' : 'Hud.RoofNoPack') : null;
      if (key !== this.hintKey) {
        this.hintKey = key;
        if (key) env.hint(S(key), 4);
      }
    }
    if (this.state === 'Freefall') {
      const v = env.body().velocity;
      const speed = Math.abs(v.y);
      if (this.wind) this.wind.setVolume(Math.min(1, speed / WIND_SPEED_FULL) * 1.2);
      const real = env.realNow();
      if (real >= this.nextShakeAt) {
        this.nextShakeAt = real + SHAKE_EVERY;
        env.shake(0.5 * Math.min(1, speed / WIND_SPEED_FULL) * (env.setting('MotionScale') ?? 1), 0.2);
      }
      const look = env.look();
      const eye = env.eye(_eye);
      env.setHandPose('Ripcord', frameAt(eye, look.yaw, 0, _hand).multiply(_m.makeTranslation(0.15, -0.9, -0.55)));
    } else if (this.state === 'Canopy' && env.realNow() < this.ripcordUntil) {
      const look = env.look();
      env.setHandPose('Ripcord', frameAt(env.eye(_eye), look.yaw, 0, _hand).multiply(_m.makeTranslation(0.15, -0.6, -0.5)));
    }
  }

  /** Dev: a pack on and a step off the gap (the roof's moment). */
  devJump() {
    const env = this.env;
    if (this.state === 'None') this.give();
    const g = this.geo.gap;
    const centre = this.gapCentre();
    env.teleport({ position: new THREE.Vector3(g.minX - LEAVE_CLEAR - this.geo.face - 1, centre.y + ROOT_HEIGHT + 1, centre.z), yaw: Math.PI / 2 });
    if (this.game.traps) this.game.traps.noteTeleport();
    return true;
  }
}

const _o = new THREE.Vector3();
const _down = new THREE.Vector3(0, -1, 0);
const _d = new THREE.Vector3();
const _root = new THREE.Vector3();
const _eye = new THREE.Vector3();
const _ledge = new THREE.Vector3();
const _aim = new THREE.Vector3();
const _up = new THREE.Vector3();
const _dir = new THREE.Vector3();
const _view = new THREE.Matrix4();
const _m = new THREE.Matrix4();
const _hand = new THREE.Matrix4();
const _e = new THREE.Euler();
