// flasks.js: the Science Hall's volatile chemical flasks (ChemicalProjectileService + ChemicalThrowController), for
// the one player. Level 2 keeps them in stock (level2.js).
//
// World flasks: the run's planned ChemicalFlask props (the export's entities; their look is the plan's variant). The
// Pickup prompt (0.35 s hold, 7 studs) serves an untaken flask to an Alive player with a free hand (a second one is
// refused with Hud.FlaskHandsFull); taking it plays the Pickup cue there and lifts the prop out of the world. One
// flask at a time: it rides the right hand in the "Flask" pose (carried low in the right of the view, drawn back
// beside the head while winding up, swung through on the throw) whenever the hands are free (not hiding, trapped,
// grabbed, parachuting or scripted, whose systems own the hands then).
//
// Throwing ("Throw", a Hold: LMB / R2 / THROW). A press winds up when canWindUp allows (Alive, holding, no control
// lock, a MoveState that may throw, FlaskThrowCooldown since the last throw). While it is held the dotted aim arc
// traces the predicted flight (after ARC_DELAY). Releasing throws once the wind-up has lasted MIN_WINDUP (a tap still
// draws back): from the eye plus the release offset, pulled back from walls, along the look at FlaskThrowSpeed (a
// short toss in a duct); FlasksThrown + 1. A context change that takes the action away cancels the wind-up.
//
// Flight: every tick the flask flies on in cast segments of at most STEP_SECONDS against the world, the Creature's
// hitbox and the pool's surfaces; the first contact shatters it there, FlaskMaxFlightSeconds without one expires it.
// The flask tumbles along the parabola between ticks.
//
// Shatter: the FlaskShatter noise (the Vent medium and the duct's node when it broke in a duct), the FlaskShatter cue
// and the ChemHiss for FlaskCloudSeconds; shards, splash, puddle and the coloured cloud (flaskFx.js). The cloud stuns
// the Creature at most once (stunVerdict), at the shatter and then at ServerTickHz: on the cloud's level, not hidden,
// in a stunnable state (not Stunned, Scripted or Dormant), and either both in the ducts within FlaskVentHopRadius
// edges, or its hitbox within FlaskCloudRadius with a clear line to it (centre, nearest point or top). A stun is
// Stun(StunSeconds, the shatter point) and counts Stuns.
//
// Downed players keep their flask (and cannot throw it); death, spectating and the end of the run empty the hand.

import * as THREE from 'three';
import { GameConfig } from '../config.js';
import { S } from '../strings.js';
import { cfMatrix, clamp01, frameAt, smoothstep } from '../util.js';
import * as Ballistics from './ballistics.js';
import { FlaskEffects, FlaskModel, FlaskCentreY, GripY, liquidColor } from './flaskFx.js';

const PICKUP_HOLD = 0.35;
const STEP_SECONDS = 1 / 60;
const CLOUD_LIFT = 0.6;
const HALF_BORE = 3.5 / 2;
const BORE_SKIN = 0.1;
const FACE_MARGIN = 0.05;
const WALL_THICKNESS = 1;
const REACH_PULL = 0.25;
const TOP_INSET = 0.3;
const UNSTUNNABLE = new Set(['Stunned', 'Scripted', 'Dormant']);
const POLL = 1 / GameConfig.ServerTickHz;
const LIVE_CONTEXTS = new Set(['OnFoot', 'Vent', 'Swim']);

// throw timing (ChemicalThrowController)
const WINDUP_SECONDS = 0.3;
const MIN_WINDUP = 0.16;
const FOLLOW_SECONDS = 0.28;
const ARC_DELAY = 0.12;
const ARC_FADE = 0.15;
const ARC_DOTS = 14;
const ARC_STEP = 1 / 24;
const SPIN_RATE = 9;
const HINT_SECONDS = 6;
// hands: frames in the eye's heading (yaw, plus PITCH_SHARE of the pitch); X right, Y up, -Z ahead
const PITCH_SHARE = 0.7;
const CARRY = frame(0.6, -0.7, -1.2, 8, 0, -6);
const DRAWN = frame(0.82, 0.08, 0.05, 62, -12, -14);
const FOLLOW = frame(0.28, -0.62, -1.75, -38, 10, 0);
const HAND_GRIP = new THREE.Matrix4().makeTranslation(0, -0.12, -0.1);
// the viewmodel's fist closes around its -Z axis: turned so it grips the upright neck
const FIST_TO_NECK = new THREE.Matrix4().makeRotationX(Math.PI / 2);

function frame(x, y, z, rx, ry, rz) {
  const d = Math.PI / 180;
  return new THREE.Matrix4().makeRotationFromEuler(new THREE.Euler(rx * d, ry * d, rz * d, 'XYZ')).setPosition(x, y, z);
}

/** Whether the throw rules allow a wind-up now (ChemicalThrowController.canWindUp). */
export function canWindUp(check) {
  if (!check.holding || check.lifeState !== 'Alive' || check.locked || check.winding) return false;
  if (!Ballistics.mayThrowIn(check.moveState)) return false;
  return check.sinceLastThrow === null || check.sinceLastThrow >= GameConfig.FlaskThrowCooldown;
}

/** The right hand's frame (look frame `eye`/`yaw`/`pitch`): carried, drawn back (windup), swung through (follow). */
export function handTarget(eye, yaw, pitch, windup, follow, out = new THREE.Matrix4()) {
  frameAt(eye, yaw, pitch * PITCH_SHARE, out);
  lerpRigid(CARRY, DRAWN, smoothstep(0, 1, windup), _hand);
  const swing = smoothstep(0, 1, follow);
  if (swing > 0) lerpRigid(_hand, FOLLOW, swing, _hand);
  return out.multiply(_hand);
}

function lerpRigid(a, b, t, out) {
  a.decompose(_pa, _qa, _s);
  b.decompose(_pb, _qb, _s);
  _pa.lerp(_pb, t);
  _qa.slerp(_qb, t);
  return out.compose(_pa, _qa, _one);
}

/** Distance from `point` to the box (frame `m`, `size` array) (0 inside). */
export function boxDistance(inv, size, point) {
  const p = _l.copy(point).applyMatrix4(inv);
  const dx = Math.max(Math.abs(p.x) - size[0] / 2, 0);
  const dy = Math.max(Math.abs(p.y) - size[1] / 2, 0);
  const dz = Math.max(Math.abs(p.z) - size[2] / 2, 0);
  return Math.hypot(dx, dy, dz);
}

/** The hitbox points a cloud may reach it by: its centre, its nearest point (pulled in a little), its top. */
export function reachPoints(m, inv, size, from) {
  const p = _l.copy(from).applyMatrix4(inv);
  const near = new THREE.Vector3(
    Math.min(size[0] / 2, Math.max(-size[0] / 2, p.x)),
    Math.min(size[1] / 2, Math.max(-size[1] / 2, p.y)),
    Math.min(size[2] / 2, Math.max(-size[2] / 2, p.z)),
  ).multiplyScalar(1 - REACH_PULL);
  return [
    new THREE.Vector3().setFromMatrixPosition(m),
    near.applyMatrix4(m),
    new THREE.Vector3(0, Math.max(size[1] / 2 - TOP_INSET, 0), 0).applyMatrix4(m),
  ];
}

export class Flasks {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Flasks';
    this.game = game;
    this.env = game.env;
    const variants = new Map((game.world.meta.plan?.props || []).map((p) => [p.anchorId, p.variant]));
    /** @type {Map<string, any>} */
    this.flasks = new Map();
    for (const info of game.world.entities('ChemicalFlask')) {
      const rest = cfMatrix(info.pivot);
      const grip = info.attachments.Grip ? cfMatrix(info.attachments.Grip) : null;
      const variant = variants.get(info.id) ?? 0;
      this.flasks.set(info.id, {
        id: info.id,
        info,
        level: info.level,
        rest,
        pivot: rest.clone(),
        gripOffset: grip ? rest.clone().invert().multiply(grip) : new THREE.Matrix4().makeTranslation(0, GripY, 0),
        prompt: info.prompts.find((p) => p.name === 'Pickup') || null,
        variant,
        color: liquidColor(variant),
        state: 'Gone',
        handle: null,
      });
    }
    this.waters = game.world.triggers('PoolWater').map((t) => ({
      level: t.level, size: t.size, inv: cfMatrix(t.cframe).invert(), up: upOf(t.cframe),
    }));
    this.fx = new FlaskEffects(this.env);
    this.held = null;
    this.heldModel = null;
    this.flights = [];
    this.clouds = [];
    this.lastThrowAt = null;
    this.windStart = null;
    this.releaseQueued = false;
    this.followStart = null;
    this.poseOwned = false;
    this.arcAlpha = 0;
    this.pollClock = 0;
    this.hintShownFor = null;
    /** Until when (real seconds) the throw hint stands on the hint line, or null. */
    this.hintUntil = null;
    this.hintText = null;
    this.env.onAction('Throw', (phase) => this._onThrow(phase));
  }

  // ---------------------------------------------------------------------------------------------------- world flasks

  _place(flask, pivot) {
    flask.pivot.copy(pivot);
    this.env.setEntityPivot(flask.id, pivot);
  }

  _toWorld(flask) {
    flask.state = 'World';
    this.env.setEntityVisible(flask.id, true);
    if (flask.handle) flask.handle.remove();
    const spec = flask.prompt;
    flask.handle = this.env.addPrompt({
      entity: flask.id,
      attachment: spec ? spec.host : 'PromptPoint',
      text: S('Prompt.Pickup'),
      objectText: S('Prompt.Flask'),
      holdSeconds: PICKUP_HOLD,
      distance: spec ? spec.maxDistance : 7,
      requiresLineOfSight: false,
      onTriggered: () => this._pickup(flask),
    });
  }

  _gone(flask) {
    flask.state = 'Gone';
    this.env.setEntityVisible(flask.id, false);
    if (flask.handle) flask.handle.remove();
    flask.handle = null;
  }

  _pickup(flask) {
    const game = this.game;
    if (flask.state !== 'World' || !game.live()) return;
    if (this.held) {
      this.env.hint(S('Hud.FlaskHandsFull'), 3);
      return;
    }
    if (game.life.state !== 'Alive') return;
    const at = new THREE.Vector3().setFromMatrixPosition(flask.pivot).add(_lift.set(0, FlaskCentreY, 0));
    this._gone(flask);
    flask.state = 'Held';
    this._hold(flask);
    game.playAt('Pickup', at);
  }

  _hold(flask) {
    this.held = flask;
    if (this.heldModel) {
      this.env.removeFromScene(this.heldModel.group);
      this.heldModel.dispose();
    }
    this.heldModel = new FlaskModel(flask.variant);
    // the flask's Grip in the fist (ChemicalThrowController.heldPivot), in the turned fist's frame
    this.heldModel.group.matrixAutoUpdate = false;
    this.heldModel.group.matrix.copy(FIST_TO_NECK).invert().multiply(HAND_GRIP).multiply(_m.copy(flask.gripOffset).invert());
    this.env.rightHand().add(this.heldModel.group);
    this.hintShownFor = null;
  }

  _emptyHand() {
    const flask = this.held;
    this.held = null;
    this.windStart = null;
    this.releaseQueued = false;
    if (this.heldModel) {
      if (this.heldModel.group.parent) this.heldModel.group.parent.remove(this.heldModel.group);
      this.heldModel.dispose();
      this.heldModel = null;
    }
    return flask;
  }

  /** Untaken world flasks on a level (Level 2's restock, the hints). */
  pickupsOn(level) {
    const out = [];
    for (const f of this.flasks.values()) {
      if (f.state === 'World' && f.level === level) {
        out.push({ id: f.id, position: new THREE.Vector3().setFromMatrixPosition(f.pivot).add(_lift.set(0, FlaskCentreY, 0)) });
      }
    }
    return out;
  }

  /** CountAvailable: untaken world flasks on a level. */
  available(level) {
    let n = 0;
    for (const f of this.flasks.values()) if (f.state === 'World' && f.level === level) n++;
    return n;
  }

  /**
   * SpawnFlask: an untaken world flask resting on `cframe` (a CFrame array or Matrix4) on `level` (Level 2's restock): a spent
   * flask is set back on the worktop. False when every flask is in play.
   */
  spawnAt(level, cframe) {
    if (!this.game.run) return false;
    let pick = null;
    for (const f of this.flasks.values()) {
      if (f.state !== 'Gone') continue;
      if (!pick || (f.level === level && pick.level !== level)) pick = f;
    }
    if (!pick) return false;
    pick.level = level;
    this._place(pick, Array.isArray(cframe) ? cfMatrix(cframe, _m) : _m.copy(cframe));
    this._toWorld(pick);
    return true;
  }

  // ---------------------------------------------------------------------------------------------------- run

  beginRun(run) {
    this.fx.clear();
    this._emptyHand();
    this.flights.length = 0;
    this.clouds.length = 0;
    this.lastThrowAt = null;
    this.followStart = null;
    for (const f of this.flasks.values()) {
      f.level = f.info.level;
      this._place(f, f.rest);
      if (run.plan.props.has(f.id)) this._toWorld(f);
      else this._gone(f);
    }
  }

  endRun() {
    this._emptyHand();
    for (const fl of this.flights) if (fl.model) this._dropModel(fl);
    this.flights.length = 0;
    for (const c of this.clouds) if (c.hiss) c.hiss.stop(0.3);
    this.clouds.length = 0;
    this.fx.clear();
    this.followStart = null;
    this._releasePose();
    for (const f of this.flasks.values()) {
      this._place(f, f.rest);
      this._gone(f);
    }
  }

  // ---------------------------------------------------------------------------------------------------- throwing

  _onThrow(phase) {
    const env = this.env;
    if (phase === 'Begin') {
      if (this._windUpAllowed()) {
        this.windStart = env.realNow();
        this.releaseQueued = false;
      }
      return;
    }
    if (this.windStart === null) return;
    if (!LIVE_CONTEXTS.has(env.context())) {
      this.windStart = null;
      this.releaseQueued = false;
      return;
    }
    this.releaseQueued = true;
  }

  _windUpAllowed() {
    const game = this.game;
    return game.live() && canWindUp({
      holding: !!this.held,
      lifeState: game.life.state,
      moveState: this.env.moveState(),
      locked: game.controlLock() !== 'None',
      winding: this.windStart !== null,
      sinceLastThrow: this.lastThrowAt === null ? null : this.env.now() - this.lastThrowAt,
    });
  }

  /** The look the throw leaves along (unit), from the camera's eye. */
  _aim(eye, dir) {
    const look = this.env.look();
    this.game.eye(eye);
    dir.copy(look.direction).normalize();
    return look;
  }

  /** The release point: the eye's hand offset, pulled back from anything solid in between. */
  _release(eye, dir, out) {
    const release = Ballistics.releasePoint(eye, dir, _rel);
    _seg.subVectors(release, eye);
    const len = _seg.length();
    const hit = len > 1e-4 ? this.env.raycast(eye, _seg.divideScalar(len), len, { ignoreEntities: false }) : null;
    return Ballistics.pullBack(eye, release, hit ? hit.point : null, out);
  }

  /** RequestThrow: the flask leaves the hand; false when the rules refuse it now. */
  throw() {
    const game = this.game;
    const env = this.env;
    const moveState = env.moveState();
    if (!this.held || !game.live() || game.life.state !== 'Alive' || game.controlLock() !== 'None') return false;
    if (!Ballistics.mayThrowIn(moveState)) return false;
    const now = env.now();
    if (this.lastThrowAt !== null && now - this.lastThrowAt < GameConfig.FlaskThrowCooldown) return false;
    const eye = new THREE.Vector3();
    const dir = new THREE.Vector3();
    this._aim(eye, dir);
    const origin = this._release(eye, dir, new THREE.Vector3());
    const flask = this._emptyHand();
    flask.state = 'Flying';
    this.lastThrowAt = now;
    this.followStart = env.realNow();
    game.stats.increment('FlasksThrown');
    const flight = {
      flask,
      origin,
      velocity: dir.clone().multiplyScalar(Ballistics.throwSpeed(moveState)),
      gravity: Ballistics.Gravity,
      startAt: now,
      t: 0,
      level: game.level,
      axis: new THREE.Vector3(Math.random() - 0.5, Math.random() - 0.5, Math.random() - 0.5).normalize(),
      model: new FlaskModel(flask.variant),
      done: false,
    };
    flight.model.group.matrixAutoUpdate = false;
    this.env.addToScene(flight.model.group);
    this.flights.push(flight);
    return true;
  }

  _dropModel(flight) {
    if (!flight.model) return;
    this.env.removeFromScene(flight.model.group);
    flight.model.dispose();
    flight.model = null;
  }

  // ---------------------------------------------------------------------------------------------------- flight

  /** The first contact on from -> to: the world, the Creature's hitbox, a pool surface. */
  _cast(from, to, level) {
    _seg.subVectors(to, from);
    const len = _seg.length();
    if (len < 1e-4) return null;
    _dir.copy(_seg).divideScalar(len);
    let best = null;
    const hit = this.env.raycast(from, _dir, len, { ignoreEntities: false });
    if (hit) best = { position: hit.point.clone(), normal: hit.normal.clone(), fraction: hit.distance / len, kind: 'World' };
    const box = this.game.creature.hitbox();
    if (box) {
      const f = segmentBox(box.inv, box.size, from, to);
      if (f !== null && (!best || f < best.fraction)) {
        const p = from.clone().lerp(to, f);
        best = { position: p, normal: _dir.clone().negate(), fraction: f, kind: 'Creature' };
      }
    }
    for (const w of this.waters) {
      if (w.level !== level) continue;
      const f = Ballistics.surfaceCrossing(w.inv, w.size, from, to);
      if (f !== null && (!best || f < best.fraction)) {
        const down = _seg.dot(w.up) > 0;
        best = { position: from.clone().lerp(to, f), normal: w.up.clone().multiplyScalar(down ? -1 : 1), fraction: f, kind: 'Water' };
      }
    }
    return best;
  }

  _stepFlights(now) {
    for (const flight of this.flights) {
      if (flight.done) continue;
      const result = Ballistics.advance(flight.origin, flight.velocity, flight.gravity, flight.t, now - flight.startAt,
        GameConfig.FlaskMaxFlightSeconds, STEP_SECONDS, (a, b) => this._cast(a, b, flight.level));
      flight.t = result.t;
      if (result.hit) this._shatter(flight, result.hit);
      else if (result.expired) this._finish(flight);
    }
    this.flights = this.flights.filter((f) => !f.done);
  }

  _finish(flight) {
    flight.done = true;
    this._dropModel(flight);
    flight.flask.state = 'Gone';
  }

  /** The VentGraph node of the duct `point` lies inside, or null (ChemicalProjectileService.ductNode). */
  _ductNode(level, point) {
    const g = this.game.vents ? this.game.vents.graphs.get(level) : null;
    if (!g) return null;
    const reach = HALF_BORE + BORE_SKIN;
    let inside = false;
    for (const [id, node] of Object.entries(g.nodes)) {
      for (const other of node.links) {
        if (!g.pos[other]) continue;
        const [across, along, length] = boreOffset(g.pos[id], g.pos[other], point);
        if (across <= reach && along >= -reach && along <= length + reach) {
          inside = true;
          break;
        }
      }
      if (inside) break;
    }
    if (!inside) {
      for (const [gid, grate] of Object.entries(g.grates)) {
        const nodePos = g.pos[grate.nodeId];
        if (!nodePos) continue;
        const wall = g.wall[gid];
        _face.setFromMatrixPosition(wall).add(_look.set(-wall.elements[8], -wall.elements[9], -wall.elements[10]).multiplyScalar(WALL_THICKNESS / 2));
        const [across, along, length] = boreOffset(nodePos, _face, point);
        if (across <= reach && along >= -reach && along <= length - FACE_MARGIN) {
          inside = true;
          break;
        }
      }
    }
    if (!inside) return null;
    let best = null;
    let bestD = Infinity;
    for (const [id, p] of Object.entries(g.pos)) {
      const d = p.distanceTo(point);
      if (d < bestD) {
        bestD = d;
        best = id;
      }
    }
    return best;
  }

  _shatter(flight, hit) {
    const game = this.game;
    const env = this.env;
    flight.done = true;
    this._dropModel(flight);
    flight.flask.state = 'Gone';
    const point = hit.position;
    const normal = hit.normal.lengthSq() > 1e-12 ? hit.normal.clone().normalize() : new THREE.Vector3(0, 1, 0);
    const ventNode = this._ductNode(flight.level, point);
    const inVent = ventNode !== null;
    const centre = point.clone().addScaledVector(normal, CLOUD_LIFT);
    const now = env.now();
    if (game.live()) {
      game.noise(point, 'FlaskShatter', inVent ? { medium: 'Vent', ventNodeId: ventNode } : {});
    }
    game.playAt('FlaskShatter', point);
    const hiss = game.playAt('ChemHiss', centre, { loop: true });
    this.fx.shatter(point, normal, centre, flight.flask.color, GameConfig.FlaskCloudSeconds, inVent, hit.kind);
    const cloud = { point: point.clone(), centre, level: flight.level, ventNode, inVent, expiresAt: now + GameConfig.FlaskCloudSeconds,
      spent: false, hiss };
    this.clouds.push(cloud);
    if (this.game.pool) this.game.pool.noteShatter(point);
    this._evaluate(cloud, now);
  }

  /** Stuns the Creature with `cloud` if the rules allow it now (stunVerdict). */
  _evaluate(cloud, at) {
    if (cloud.spent || at > cloud.expiresAt) return;
    const c = this.game.creature;
    const snap = c.snapshot();
    if (!snap || !snap.running || snap.levelId !== cloud.level || snap.hidden) return;
    if (UNSTUNNABLE.has(snap.state)) return;
    let stuns = false;
    if (cloud.ventNode && snap.inVent) {
      const node = c.ventNode();
      const hops = node ? ventHops(this.game.vents.graphs.get(cloud.level), cloud.ventNode, node, GameConfig.FlaskVentHopRadius) : null;
      stuns = hops !== null && hops <= GameConfig.FlaskVentHopRadius;
    }
    if (!stuns) {
      const box = c.hitbox();
      if (box && boxDistance(box.inv, box.size, cloud.centre) <= GameConfig.FlaskCloudRadius) {
        for (const target of reachPoints(box.matrix, box.inv, box.size, cloud.centre)) {
          if (this.env.lineClear(cloud.centre, target, { ignoreEntities: false })) {
            stuns = true;
            break;
          }
        }
      }
    }
    if (!stuns) return;
    cloud.spent = true;
    c.stun(GameConfig.StunSeconds, cloud.point);
    this.game.stats.increment('Stuns');
  }

  // ---------------------------------------------------------------------------------------------------- drive

  tick(dt, now) {
    const game = this.game;
    if (this.held && game.run && (game.life.state === 'Dead' || game.life.state === 'Spectating')) this._emptyHand();
    this._stepFlights(now);
    this.pollClock += dt;
    if (this.pollClock >= POLL) {
      this.pollClock = 0;
      this.clouds = this.clouds.filter((c) => {
        if (now <= c.expiresAt) return true;
        if (c.hiss) c.hiss.stop(0.6);
        return false;
      });
      for (const cloud of this.clouds.slice()) this._evaluate(cloud, now);
    }
  }

  _releasePose() {
    if (!this.poseOwned) return;
    this.poseOwned = false;
    this.env.setHandPose('Flashlight');
  }

  frame(dt) {
    const env = this.env;
    const game = this.game;
    const real = env.realNow();
    // the release, once the wind-up has drawn back far enough
    if (this.windStart !== null) {
      if (!this.held || game.life.state !== 'Alive') {
        this.windStart = null;
        this.releaseQueued = false;
      } else if (this.releaseQueued && real - this.windStart >= MIN_WINDUP) {
        this.windStart = null;
        this.releaseQueued = false;
        this.throw();
      }
    }
    // the hand
    const following = this.followStart !== null && real - this.followStart < FOLLOW_SECONDS;
    if (!following) this.followStart = null;
    const life = game.life.state;
    const pose = (this.held || following) && (life === 'Alive' || life === 'Downed') && Ballistics.mayThrowIn(env.moveState());
    if (pose) {
      const look = env.look();
      const windup = this.windStart !== null ? clamp01((real - this.windStart) / WINDUP_SECONDS) : 0;
      const follow = following ? 1 - (1 - clamp01((real - this.followStart) / FOLLOW_SECONDS)) ** 2 : 0;
      handTarget(game.eye(_eye), look.yaw, look.pitch, windup, follow, _target).multiply(FIST_TO_NECK);
      env.setHandPose('Flask', _target);
      this.poseOwned = true;
    } else this._releasePose();
    if (this.heldModel) {
      this.heldModel.group.visible = !!pose;
      this.heldModel.setLight(env.probeAt(game.eye(_eye), _probe));
    }
    this._hint();
    this._arc(real, dt);
    // the flights between ticks
    const now = env.renderNow();
    for (const flight of this.flights) {
      if (!flight.model) continue;
      const t = Math.min(Math.max(0, now - flight.startAt), Math.max(flight.t, 0) + 1 / 30);
      Ballistics.position(flight.origin, flight.velocity, flight.gravity, t, _p);
      const m = flight.model.group.matrix;
      m.makeRotationAxis(flight.axis, SPIN_RATE * t).premultiply(_m.makeTranslation(_p.x, _p.y, _p.z));
      m.multiply(_m.makeTranslation(0, -FlaskCentreY, 0));
      flight.model.setLight(env.probeAt(_p, _probe));
    }
    this.fx.step(dt);
  }

  /**
   * While holding a flask the hint line says how to throw it (once per flask and device), only where a throw is
   * possible: it waits out a locker, a trap, a grab or a cutscene, and one still up when the player gets into such a
   * spot is taken down (it read "Hold LMB to aim" inside a locker).
   */
  _hint() {
    const env = this.env;
    const real = env.realNow();
    const canThrow = !!this.held && this.game.life.state === 'Alive' && Ballistics.mayThrowIn(env.moveState()) &&
      LIVE_CONTEXTS.has(env.context());
    if (!canThrow) {
      // only our line: another system may have put its own hint up since
      const line = env.ui && env.ui.hintEl ? env.ui.hintEl.textContent : null;
      if (this.hintUntil !== null && real < this.hintUntil && line === this.hintText) env.clearHint();
      this.hintUntil = null;
      return;
    }
    const device = env.device();
    const key = `${this.held.id}:${device}`;
    if (this.hintShownFor === key) return;
    this.hintShownFor = key;
    this.hintUntil = real + HINT_SECONDS;
    this.hintText = S(`Hud.FlaskThrow.${device}`);
    env.hint(this.hintText, HINT_SECONDS);
  }

  /** The aim arc while winding up (after ARC_DELAY), fading in and out over ARC_FADE. */
  _arc(real, dt) {
    const winding = this.windStart !== null && this.held && real - this.windStart >= ARC_DELAY;
    const step = dt / ARC_FADE;
    this.arcAlpha = winding ? Math.min(1, this.arcAlpha + step) : Math.max(0, this.arcAlpha - step);
    if (this.arcAlpha <= 0 || !this.held) {
      this.fx.hideArc();
      return;
    }
    const eye = new THREE.Vector3();
    const dir = new THREE.Vector3();
    this._aim(eye, dir);
    const origin = this._release(eye, dir, new THREE.Vector3());
    const velocity = dir.multiplyScalar(Ballistics.throwSpeed(this.env.moveState()));
    const level = this.game.level;
    const traced = Ballistics.trace(origin, velocity, Ballistics.Gravity, GameConfig.FlaskMaxFlightSeconds, ARC_STEP,
      (a, b) => this._cast(a, b, level));
    this.fx.showArc(Ballistics.resample(traced.points, ARC_DOTS), traced.hit, this.held.color, this.arcAlpha);
  }

  // ---------------------------------------------------------------------------------------------------- dev

  /** Give: puts a flask in a playing player's free hand (dev); false without a spare flask. */
  give() {
    if (this.held || !this.game.run) return false;
    const all = [...this.flasks.values()];
    const pick = all.find((f) => f.state === 'Gone') || all.find((f) => f.state === 'World');
    if (!pick) return false;
    if (pick.state === 'World') this._gone(pick);
    pick.state = 'Held';
    this._hold(pick);
    return true;
  }

  /** Dev: a flask in the hand thrown at once along the look (the signature moment of Level 2). */
  devThrow() {
    if (!this.held && !this.give()) return false;
    this.lastThrowAt = null;
    return this.throw();
  }
}

/** Fewest duct edges between nodes (null when more than maxHops or unknown). */
export function ventHops(graph, from, to, maxHops) {
  if (!graph || !graph.nodes[from] || !graph.nodes[to]) return null;
  if (from === to) return 0;
  const seen = new Set([from]);
  let frontier = [from];
  for (let hops = 1; hops <= Math.max(0, Math.floor(maxHops)); hops++) {
    const next = [];
    for (const id of frontier) {
      for (const n of graph.nodes[id].links) {
        if (n === to) return hops;
        if (!seen.has(n) && graph.nodes[n]) {
          seen.add(n);
          next.push(n);
        }
      }
    }
    if (!next.length) return null;
    frontier = next;
  }
  return null;
}

/** Where `point` sits against the duct piece a -> b: [across the square bore, along from a, length]. */
export function boreOffset(a, b, point) {
  const axis = _ax.subVectors(b, a);
  const length = axis.length();
  const offset = _of.subVectors(point, a);
  if (length < 1e-6) return [Math.max(Math.abs(offset.x), Math.abs(offset.y), Math.abs(offset.z)), 0, 0];
  axis.divideScalar(length);
  const side = Math.abs(axis.y) > 0.9 ? _sd.set(1, 0, 0) : _sd.crossVectors(axis, _yAxis).normalize();
  const up = _up.crossVectors(side, axis).normalize();
  return [Math.max(Math.abs(offset.dot(side)), Math.abs(offset.dot(up))), offset.dot(axis), length];
}

/** The first fraction (0..1) of the segment from -> to inside the box (inverse frame, size array), or null. */
function segmentBox(inv, size, from, to) {
  const a = _ba.copy(from).applyMatrix4(inv);
  const b = _bb.copy(to).applyMatrix4(inv);
  let t0 = 0;
  let t1 = 1;
  for (const axis of ['x', 'y', 'z']) {
    const half = size[axis === 'x' ? 0 : axis === 'y' ? 1 : 2] / 2;
    const d = b[axis] - a[axis];
    if (Math.abs(d) < 1e-9) {
      if (Math.abs(a[axis]) > half) return null;
      continue;
    }
    let lo = (-half - a[axis]) / d;
    let hi = (half - a[axis]) / d;
    if (lo > hi) [lo, hi] = [hi, lo];
    t0 = Math.max(t0, lo);
    t1 = Math.min(t1, hi);
    if (t0 > t1) return null;
  }
  return t0;
}

function upOf(cf) {
  return new THREE.Vector3(cf[4], cf[7], cf[10]).normalize();
}

const _hand = new THREE.Matrix4();
const _pa = new THREE.Vector3();
const _pb = new THREE.Vector3();
const _qa = new THREE.Quaternion();
const _qb = new THREE.Quaternion();
const _s = new THREE.Vector3();
const _one = new THREE.Vector3(1, 1, 1);
const _l = new THREE.Vector3();
const _m = new THREE.Matrix4();
const _lift = new THREE.Vector3();
const _rel = new THREE.Vector3();
const _seg = new THREE.Vector3();
const _dir = new THREE.Vector3();
const _face = new THREE.Vector3();
const _look = new THREE.Vector3();
const _eye = new THREE.Vector3();
const _target = new THREE.Matrix4();
const _probe = new THREE.Color();
const _p = new THREE.Vector3();
const _ax = new THREE.Vector3();
const _of = new THREE.Vector3();
const _sd = new THREE.Vector3();
const _up = new THREE.Vector3();
const _yAxis = new THREE.Vector3(0, 1, 0);
const _ba = new THREE.Vector3();
const _bb = new THREE.Vector3();
