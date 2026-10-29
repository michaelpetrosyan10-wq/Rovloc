// level1.js: Floor 1's scripted classroom scare (Level1_HallwaysController). Once per run.
//
// Staging. When the level activates the Creature is taken (acquireScripted(TOKEN)); on the next step it is
// teleported to the CreatureScarePose anchor (L1_ScarePose_Classroom108, root height, facing into the north-west
// corner of Classroom 108), posed Hunched and shown. It is only staged while the player cannot see the spot it leaves
// or the pose, so it never pops in; a Creature that could not be acquired (busy) is asked for again every STAGE_RETRY
// seconds the same way. The ClassroomGlow lights over the corner burn.
//
// The trigger, at GameConfig.ServerTickHz, when the player:
//   Glass      stands in the ScareStep volume (L1_Trigger_GlassStep, the glass outside the ajar door),
//   Classroom  is inside Classroom 108 (in through the door, or out of its vent grate),
//   Near       is within NEAR_DISTANCE of the Creature with a clear line to its eyes (never from inside a duct),
//   Slipped    is in the corridor between the glass and the gate (round through Classroom 136, or out of a vent),
//   Beyond     is past the gate (any room joined to the exit airlock without the gate) or in the gate's bypass vent.
//
// The scene (Scenes.ClassroomScare times, from startAt S = trigger + OneShotLead): the FloorDebris noise at the
// player's feet now; the "L1_ClassroomScare" timeline (the crunch, the stumble, the drag of the view onto the
// Creature, NeckSnap, the hush and the burst sounds); just before the snap the body turns its back square to the
// player so the 180-degree stare lands on them; the two glow fixtures burst (LightBurst, SpillStagger apart); the
// Creature vanishes as the bulbs stutter out and is hidden as they die; the bulbs stay dead for the run; the
// HallwayGate locks shut in GATE_SECONDS so it lands at GateLand (the slam, the shake, the DoorSlam noise; Locked
// refuses every open, so the bypass vent is the only way on); the hidden Creature moves to the nearest patrol spot
// east of the gate that is HIDE_DISTANCE from the player and out of sight; and 6-9 s (seeded) after the slam it is
// released into Patrol with a High alert at the glass: it comes hunting from out of sight.
// Without a staged Creature the scare is skipped: the crunch and stumble alone ("L1_GlassStep") and the gate.
//
// Leaving the level cancels everything still scheduled: a scene cut short leaves the world as the scene would (gate
// shut, bulbs dead) and the Creature is let go Dormant. The run ending restores the bulbs (the lighting resets).
// Everything placed comes from the export's Level 1 layout (rooms, doors, triggers, anchors, lights).

import * as THREE from 'three';
import { CreatureMetrics } from '../creatureApi.js';
import { GameConfig } from '../config.js';
import * as Scenes from '../scenes.js';
import { Schedule, list, lookAtMatrix, seededRandom } from '../util.js';

const LEVEL = 'Level1_Hallways';
const TOKEN = 'L1_ClassroomScare';
const POSE_ANCHOR = 'L1_ScarePose_Classroom108';
const GLASS_TRIGGER = 'L1_Trigger_GlassStep';
const CLASSROOM_ROOM = 'L1_Classroom_108';
const BURST_LIGHTS = ['L1_Light_ClassroomGlow', 'L1_Light_ClassroomGlowSpill'];
const GATE_ID = 'HallwayGate';
const BYPASS_CHASE = 'L1_Chase_Gate';
const SEALED_DOOR_KINDS = new Set(['Gate', 'Boarded']);
const NEAR_DISTANCE = 14;
const GATE_SECONDS = 0.35;
const HIDE_DISTANCE = 30;
const EAST_MARGIN = 16;
const STAGE_RETRY = 1;
const TICK = 1 / GameConfig.ServerTickHz;
const LEAD = GameConfig.OneShotLead;
const ROOT_TO_FEET = 3;
const CLASSROOM = Scenes.ClassroomScare;
const ARGS = Scenes.Args;

/** @typedef {'Glass'|'Classroom'|'Near'|'Slipped'|'Beyond'} Reason */

/**
 * Everything the scene needs from Level 1's blueprint (world positions; the plan's X / Z are level-local).
 * @param {any} meta world.json
 */
export function geometry(meta) {
  const layout = meta.layouts[LEVEL];
  const origin = new THREE.Vector3(...meta.levels[LEVEL].origin);
  const rooms = new Map(layout.rooms.map((r) => [r.id, r]));
  const anchor = meta.anchors.find((a) => a.id === POSE_ANCHOR);
  const glass = layout.triggers.find((t) => t.id === GLASS_TRIGGER);
  if (!anchor || !glass) throw new Error(`Level 1 has no ${anchor ? GLASS_TRIGGER : POSE_ANCHOR}`);

  let gateX = glass.rect.x;
  for (const door of layout.doors) {
    if (door.scriptedId !== GATE_ID) continue;
    const a = rooms.get(door.rooms[0]);
    const b = rooms.get(door.rooms[1]);
    const edge = a && b ? sharedEdgeX(a.rect, b.rect) : null;
    if (edge !== null) gateX = edge;
  }

  // past the gate: every room the exit airlock reaches through doors other than the gate and the barricades
  const beyond = new Set([layout.exit]);
  const frontier = [layout.exit];
  while (frontier.length) {
    const here = frontier.pop();
    for (const door of layout.doors) {
      if (SEALED_DOOR_KINDS.has(door.kind)) continue;
      const [a, b] = door.rooms;
      const other = a === here ? b : b === here ? a : null;
      if (other && !beyond.has(other)) {
        beyond.add(other);
        frontier.push(other);
      }
    }
  }
  if (rooms.has(BYPASS_CHASE)) beyond.add(BYPASS_CHASE);

  const lights = [];
  for (const id of BURST_LIGHTS) {
    for (const room of layout.rooms) {
      for (const light of list(room.lights)) {
        if (light.id === id) lights.push({ id, position: origin.clone().add(new THREE.Vector3(...light.pos)) });
      }
    }
  }

  const hidingSpots = [];
  for (const a of layout.anchors) {
    if (a.kind === 'PatrolWaypoint' && a.pos[0] > gateX + EAST_MARGIN) {
      hidingSpots.push(origin.clone().add(new THREE.Vector3(a.pos[0], a.pos[1] + CreatureMetrics.rootHeight, a.pos[2])));
    }
  }

  const r = glass.rect;
  return {
    origin,
    pose: anchor.cframe,
    posePosition: new THREE.Vector3(anchor.cframe[0], anchor.cframe[1], anchor.cframe[2]),
    glassVolume: meta.triggers.find((t) => t.id === GLASS_TRIGGER) || null,
    corridor: glass.room,
    glassMinX: r.x,
    gateX,
    classroom: CLASSROOM_ROOM,
    beyond,
    lights,
    hidingSpots,
    alertPoint: origin.clone().add(new THREE.Vector3(r.x + r.w / 2, 0, r.z + r.d / 2)),
  };
}

/** The X of the wall two rects share (LayoutSchema.sharedEdge with axis X), or null. */
function sharedEdgeX(a, b) {
  const overlapZ = Math.min(a.z + a.d, b.z + b.d) - Math.max(a.z, b.z);
  if (overlapZ <= 0) return null;
  if (Math.abs(a.x + a.w - b.x) < 1e-6) return b.x;
  if (Math.abs(b.x + b.w - a.x) < 1e-6) return a.x;
  return null;
}

/**
 * Why a sample sets the scare off (null: it does not).
 * @param {{onGlass: boolean, zone: string|null, localX: number|null, inVent: boolean, distance: number|null, sightline: boolean}} sample
 * @returns {Reason|null}
 */
export function triggerReason(sample, g) {
  if (sample.onGlass) return 'Glass';
  const zone = sample.zone;
  if (zone === g.classroom) return 'Classroom';
  if (!sample.inVent && sample.distance !== null && sample.distance <= NEAR_DISTANCE && sample.sightline) return 'Near';
  if (zone === g.corridor && sample.localX !== null && sample.localX < g.glassMinX) return 'Slipped';
  if (zone !== null && g.beyond.has(zone)) return 'Beyond';
  return null;
}

/** Seconds after the gate lands before the Creature hunts (seeded per run). */
export function releaseDelay(seed) {
  return seededRandom(seed, 'L1_ClassroomScare:release').number(CLASSROOM.ReleaseMin, CLASSROOM.ReleaseMax);
}

/** The point the body faces so its back is square to `eye` (the 180-degree snap then stares at it); null overhead. */
export function backTurn(root, eye) {
  const away = new THREE.Vector3(root.x - eye.x, 0, root.z - eye.z);
  if (away.length() < 0.1) return null;
  return root.clone().addScaledVector(away.normalize(), 4);
}

/** The spot nearest `from` at least `minDistance` from the player's eye that the player cannot see (LevelKit). */
function hidingSpot(candidates, eyes, from, minDistance, visible) {
  const eligible = [];
  candidates.forEach((point, index) => {
    if (eyes.length) {
      let nearest = Infinity;
      for (const e of eyes) nearest = Math.min(nearest, point.distanceTo(e));
      if (nearest < minDistance) return;
    }
    eligible.push({ point, distance: point.distanceTo(from), index });
  });
  eligible.sort((a, b) => a.distance - b.distance || a.index - b.index);
  for (const c of eligible) if (!visible(c.point)) return c.point;
  return null;
}

export class Level1 {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Level1';
    this.game = game;
    this.geo = geometry(game.world.meta);
    this.schedule = new Schedule();
    this.active = false;
    this.seed = 0;
    this.done = false;
    /** @type {import('../creatureApi.js').ScriptedHandle|null} */
    this.handle = null;
    this.staged = false;
    this.nextStageAt = -Infinity;
    this.nextTickAt = -Infinity;
    /** @type {any} */
    this.scene = null;
    this.lightsKilled = false;
  }

  // ---------------------------------------------------------------------------------------------------- holding

  _acquire() {
    if (!this.handle) {
      this.handle = this.game.creature.acquireScripted(TOKEN);
      if (this.handle) this.game.creatureHandle = this.handle;
    }
    return this.handle;
  }

  _drop(parkState) {
    const h = this.handle;
    this.handle = null;
    this.staged = false;
    if (this.game.creatureHandle === h) this.game.creatureHandle = null;
    if (h && parkState) h.release(parkState);
  }

  _eyes() {
    return this.game.playing() ? [this.game.eye(new THREE.Vector3())] : [];
  }

  /** Could the player see a Creature whose root is at `root` (its eyes or its chest)? */
  _seen(root) {
    _p.copy(root).y += CreatureMetrics.eye.Biped;
    return this.game.seen(_p) || this.game.seen(root);
  }

  _creatureEyes(out) {
    const root = this.game.creature.position(out);
    return root ? root.add(_up.set(0, CreatureMetrics.eye.Hunched, 0)) : null;
  }

  _stage(h) {
    h.teleport(this.geo.pose);
    h.setPose('Hunched');
    h.setHidden(false);
    this.staged = true;
  }

  _stagingUnseen() {
    if (this._seen(this.geo.posePosition)) return false;
    const c = this.game.creature;
    const root = c.position(_root);
    return root === null || c.isHidden() || !this._seen(root);
  }

  _ensureStaged(now) {
    if (this.staged || now < this.nextStageAt) return;
    this.nextStageAt = now + STAGE_RETRY;
    if (!this._stagingUnseen()) return;
    const h = this._acquire();
    if (h) this._stage(h);
  }

  // ---------------------------------------------------------------------------------------------------- the scene

  _killLights() {
    if (this.scene) this.scene.lightsKilled = true;
    if (this.lightsKilled) return;
    this.lightsKilled = true;
    for (const id of BURST_LIGHTS) this.game.env.setLightOverride(id, 0);
  }

  _lockGate(seconds) {
    if (this.scene) this.scene.gateLocked = true;
    const gate = this.game.doors.find(LEVEL, GATE_ID);
    if (!gate) {
      console.warn(`[game] no ${GATE_ID} on ${LEVEL}: the gate cannot close`);
      return;
    }
    this.game.doors.setState(gate, 'Locked', seconds);
  }

  /** Moves the hidden Creature to the nearest unseen patrol spot east of the gate; false when there is none now. */
  _relocate() {
    const h = this.handle;
    const scene = this.scene;
    if (!(h && scene)) return false;
    const from = this.game.creature.position(_root) || this.geo.posePosition;
    const spot = hidingSpot(this.geo.hidingSpots, this._eyes(), from, HIDE_DISTANCE, (p) => this._seen(p));
    h.setPose('Biped');
    if (!spot) return false;
    // facing back toward the gate, the way it will come hunting
    h.teleport(lookAtMatrix(spot, _look.copy(spot).add(_west), _m));
    scene.relocated = true;
    return true;
  }

  _release() {
    const h = this.handle;
    const scene = this.scene;
    if (!(h && scene)) return;
    if (!scene.relocated) this._relocate();
    this._drop('Patrol');
    this.game.creature.alert(this.geo.alertPoint, 'High');
  }

  _scheduleFull(scene) {
    const s = scene.startAt;
    const g = this.geo;
    const env = this.game.env;
    this.schedule.at(s + CLASSROOM.Snap - CLASSROOM.FaceLead, 'face', () => {
      const h = this.handle;
      const root = this.game.creature.position(_root);
      if (!(h && root)) return;
      const eye = this.game.playing() ? this.game.eye(_eye) : scene.triggerEye;
      const target = backTurn(root, eye);
      if (target) h.face(target);
    });
    g.lights.forEach((light, index) => {
      this.schedule.at(s + CLASSROOM.Burst + index * CLASSROOM.SpillStagger, 'burst', () => env.burstLight(light.id));
    });
    this.schedule.at(s + CLASSROOM.Vanish, 'vanish', () => {
      if (this.handle) this.handle.action('Vanish');
    });
    this.schedule.at(s + CLASSROOM.Hide, 'hide', () => {
      if (this.handle) this.handle.setHidden(true);
    });
    this.schedule.at(s + CLASSROOM.KillLights, 'lights', () => this._killLights());
    this.schedule.at(s + CLASSROOM.GateLand - LEAD - GATE_SECONDS, 'gate', () => this._lockGate(GATE_SECONDS));
    this.schedule.at(s + CLASSROOM.Relocate, 'relocate', () => this._relocate());
    this.schedule.at(s + CLASSROOM.GateLand + releaseDelay(this.seed), 'release', () => this._release());
  }

  _scheduleSkipped(scene) {
    const s = scene.startAt;
    this.schedule.at(s + CLASSROOM.SkippedGateLand - LEAD - GATE_SECONDS, 'gate', () => this._lockGate(GATE_SECONDS));
    if (this.handle) {
      // held but never staged (it was in sight the whole time): let it go after the slam
      this.schedule.at(s + CLASSROOM.SkippedGateLand + releaseDelay(this.seed), 'release', () => this._release());
    }
  }

  _startScene(reason, now) {
    const game = this.game;
    const g = this.geo;
    this.done = true;
    const eye = game.eye(new THREE.Vector3());
    const feet = game.feet(new THREE.Vector3());
    const full = this.handle !== null && this.staged;
    const scene = { startAt: now + LEAD, reason, full, triggerEye: eye, gateLocked: false, lightsKilled: false, relocated: false };
    this.scene = scene;
    game.noise(feet, 'FloorDebris');
    if (full) {
      const head = this._creatureEyes(new THREE.Vector3()) ||
        g.posePosition.clone().add(_up.set(0, CreatureMetrics.eye.Hunched, 0));
      const glow = g.lights[0];
      const spill = g.lights[1] || glow;
      const args = {
        [ARGS.Subject]: true,
        [ARGS.Feet]: feet,
        [ARGS.Head]: head,
        [ARGS.Focus]: game.env.lineClear(eye, head),
      };
      if (glow) args[ARGS.Glow] = glow.position;
      if (spill) args[ARGS.Spill] = spill.position;
      game.seq.play(CLASSROOM.Id, scene.startAt, args);
      this._scheduleFull(scene);
    } else {
      game.seq.play(CLASSROOM.SkippedId, scene.startAt, { [ARGS.Subject]: true, [ARGS.Feet]: feet });
      this._scheduleSkipped(scene);
    }
  }

  /** Why the player sets the scare off this tick, or null. */
  _findTrigger() {
    const game = this.game;
    if (!game.playing()) return null;
    const g = this.geo;
    const env = game.env;
    const eye = game.eye(_eye);
    const root = env.rootPosition(_root);
    const head = this.staged ? this._creatureEyes(_head) : null;
    _feet.set(root.x, root.y - ROOT_TO_FEET, root.z);
    const inVent = game.vents.inVent();
    const sample = {
      onGlass: !!g.glassVolume && (game.world.inTrigger(g.glassVolume, root) || game.world.inTrigger(g.glassVolume, _feet)),
      zone: game.zoneId(),
      localX: eye.x - g.origin.x,
      inVent,
      distance: head ? eye.distanceTo(head) : null,
      sightline: false,
    };
    if (head && sample.distance !== null && sample.distance <= NEAR_DISTANCE && !inVent) sample.sightline = env.lineClear(eye, head);
    return triggerReason(sample, g);
  }

  /** Ends whatever is in flight; with `finish` a scene cut short leaves the gate shut and the bulbs dead. */
  _cancel(finish, parkState) {
    this.schedule.clear();
    const scene = this.scene;
    if (scene && finish) {
      if (!scene.gateLocked) this._lockGate(0);
      if (scene.full && !scene.lightsKilled) this._killLights();
    }
    this.scene = null;
    this._drop(parkState);
  }

  // ---------------------------------------------------------------------------------------------------- lifecycle

  levelActivated(level) {
    if (level !== LEVEL) return;
    this.active = true;
    this.nextTickAt = -Infinity;
    this.nextStageAt = -Infinity;
    if (this.done) return;
    // taken now, so the brain never starts its own patrol here; placed on the next step
    this.staged = false;
    this._acquire();
  }

  levelDeactivated(level) {
    if (level !== LEVEL) return;
    this.active = false;
    this._cancel(true, 'Dormant');
  }

  beginRun(run) {
    this._cancel(false, null);
    this.seed = run.seed;
    this.done = false;
    this.active = false;
    this.lightsKilled = false;
  }

  endRun() {
    this._cancel(false, 'Dormant');
    this.done = false;
    this.active = false;
    this.lightsKilled = false;
  }

  tick(dt, now) {
    this.schedule.run(now);
    if (!this.active || this.done || now < this.nextTickAt || this.game.phase !== 'InRun') return;
    this.nextTickAt = now + TICK;
    this._ensureStaged(now);
    const reason = this._findTrigger();
    if (reason) this._startScene(reason, now);
  }

  // ---------------------------------------------------------------------------------------------------- dev

  /** Dev `scare`: plays the scare now with the player as the subject; false when it ran or the level is not active. */
  devScare() {
    if (!this.active || this.done) return false;
    const h = this._acquire();
    if (h && !this.staged) this._stage(h);
    this._startScene('Glass', this.game.env.now());
    return true;
  }

  /** Whether the scare (or its fallback) fired this run. */
  hasRun() {
    return this.done;
  }

  /** Names of the scene beats still to come. */
  pending() {
    return this.schedule.entries.slice().sort((a, b) => a.at - b.at || a.order - b.order).map((e) => e.name);
  }
}

const _p = new THREE.Vector3();
const _up = new THREE.Vector3();
const _root = new THREE.Vector3();
const _eye = new THREE.Vector3();
const _head = new THREE.Vector3();
const _feet = new THREE.Vector3();
const _look = new THREE.Vector3();
const _west = new THREE.Vector3(-1, 0, 0);
const _m = new THREE.Matrix4();
