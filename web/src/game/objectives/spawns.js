// spawns.js: where the Creature starts on Levels 2 and 3, and its grace (Level 1 keeps its scripted scare start, Level
// 4 its pool, Level 5 its roof door: see level5.js).
//
// Candidates: the level's PatrolWaypoint and CreatureSpawn anchors that pass all three rules:
//   * MinDistance..MaxDistance studs of walking distance from the entry (the run route's entry room, from its first
//     PlayerSpawn slot) over the zone graph (rooms joined by doorways, and the ducts: worldData.walkDistance);
//   * not visible from the entry: no clear line (static geometry) from any of five eye-height points of the entry room
//     (its centre and four inset corners) to the anchor at AnchorHeights over its floor;
//   * not inside an objective room: a room holding one of the floor's picked items or one of its stations.
// Pick: one candidate by the run seed (stream "CreatureSpawn|<level>", in anchor id order). Fallback, never silent:
// with no candidate the nearest to the band among the unseen ones outside the objective rooms (then any unseen one) is
// used and logged (console.info and the log the checks read).
// On activation the Creature is held there (acquireScripted "CreatureSpawn", shown, facing the entry) for the grace:
// SpawnTuning.Grace by difficulty. The grace ends early on a High or Critical noise of the player's on the level (the
// Creature is then alerted to it when it lay within the noise's radius: a sound it heard, never the player's spot), or
// when the player comes within ReleaseNear or can see its head from ReleaseSight. Released, it patrols.

import * as THREE from 'three';
import { CreatureMetrics } from '../creatureApi.js';
import { SpawnTuning } from './config.js';
import { cfPos, lookAtMatrix, seededRandom } from '../util.js';

const LEVELS = new Set(['Level2_ScienceHall', 'Level3_Gymnasium']);
const TOKEN = 'CreatureSpawn';
const LOUD = new Set(['High', 'Critical']);
const RETRY = 0.25;

export class CreatureSpawns {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.game = game;
    this.env = game.env;
    this.world = game.world;
    this.handle = null;
    this.level = null;
    this.graceUntil = null;
    this.pending = null;
    /** @type {any[]} every placement this session (the checks read it) */
    this.log = [];
    this.env.onNoise((e) => this._noise(e));
  }

  /** The levels whose Creature start this rule places. */
  static handles(level) {
    return LEVELS.has(level);
  }

  /** The rooms holding the floor's picked items or its stations (the run's plan). */
  objectiveRooms(level, plan) {
    const rooms = new Set();
    const picks = plan && plan.objectives ? plan.objectives[level] : null;
    const byId = new Map(this.world.objectiveCandidates(level).map((c) => [c.anchorId, c]));
    for (const id of picks ? picks.anchors : []) {
      const c = byId.get(id);
      if (c && c.room) rooms.add(c.room);
    }
    for (const e of this.world.meta.entities) {
      if (e.level === level && e.tags.includes('ObjectiveStation') && e.attributes.ZoneId) rooms.add(e.attributes.ZoneId);
    }
    return rooms;
  }

  /** Every PatrolWaypoint / CreatureSpawn anchor of `level` with its walking distance, sight and room verdicts. */
  evaluate(level, plan, routes) {
    const entryRoom = this.world.entryRoom(level, routes);
    const spawn = this.world.spawns(level, routes)[0];
    const from = spawn ? cfPos(spawn.cframe) : this.world.roomCentre(entryRoom);
    const eyes = this._entryEyes(entryRoom);
    const objective = this.objectiveRooms(level, plan);
    const out = [];
    for (const a of this.world.meta.anchors) {
      if (a.level !== level || (a.kind !== 'PatrolWaypoint' && a.kind !== 'CreatureSpawn')) continue;
      const p = cfPos(a.cframe);
      const walk = this.world.walkDistance(level, entryRoom, from, a.room, p);
      const visible = this._visible(eyes, p);
      out.push({ anchor: a, id: a.id, room: a.room, walk, visible, inObjectiveRoom: objective.has(a.room),
        inBand: walk >= SpawnTuning.MinDistance && walk <= SpawnTuning.MaxDistance });
    }
    out.sort((x, y) => (x.id < y.id ? -1 : 1));
    return out;
  }

  /** The run's pick for `level`: {choice, fallback, candidates}. */
  choose(level, run) {
    const all = this.evaluate(level, run.plan, run.routes);
    const ok = all.filter((c) => c.inBand && !c.visible && !c.inObjectiveRoom);
    const random = seededRandom(run.seed, `CreatureSpawn|${level}`);
    if (ok.length) return { choice: ok[random.integer(0, ok.length - 1)], fallback: false, candidates: ok };
    const gap = (c) => Math.max(0, SpawnTuning.MinDistance - c.walk, c.walk - SpawnTuning.MaxDistance);
    let pool = all.filter((c) => !c.visible && !c.inObjectiveRoom && Number.isFinite(c.walk));
    if (!pool.length) pool = all.filter((c) => !c.visible && Number.isFinite(c.walk));
    if (!pool.length) pool = all.filter((c) => Number.isFinite(c.walk));
    pool.sort((x, y) => gap(x) - gap(y) || (x.id < y.id ? -1 : 1));
    const choice = pool[0] || null;
    if (choice) console.info(`[game] ${level}: no Creature spawn in the ${SpawnTuning.MinDistance}-${SpawnTuning.MaxDistance} band; using ${choice.id} (${Math.round(choice.walk)} studs)`);
    return { choice, fallback: true, candidates: [] };
  }

  _entryEyes(roomId) {
    const r = this.world.room(roomId);
    if (!r) return [];
    const y = r.floorY + SpawnTuning.EntryEyeHeight;
    const i = SpawnTuning.EntryInset;
    const { x, z, w, d } = r.rect;
    return [[x + w / 2, z + d / 2], [x + i, z + i], [x + w - i, z + i], [x + i, z + d - i], [x + w - i, z + d - i]]
      .map(([px, pz]) => new THREE.Vector3(px, y, pz));
  }

  _visible(eyes, floor) {
    for (const h of SpawnTuning.AnchorHeights) {
      _p.set(floor.x, floor.y + h, floor.z);
      for (const e of eyes) if (this.env.lineClear(e, _p, { ignoreEntities: true })) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------------------------------- the hold

  levelActivated(level) {
    this._letGo(null);
    const run = this.game.run;
    if (!run || !CreatureSpawns.handles(level) || !this.game.creature.available()) return;
    const pick = this.choose(level, run);
    if (!pick.choice) return;
    const grace = SpawnTuning.Grace[run.difficulty] ?? SpawnTuning.Grace.Standard;
    this.level = level;
    this.pending = pick;
    this.graceUntil = this.env.now() + grace;
    this.nextTryAt = -Infinity;
    this.entry = { level, anchorId: pick.choice.id, walk: pick.choice.walk, visible: pick.choice.visible,
      inObjectiveRoom: pick.choice.inObjectiveRoom, fallback: pick.fallback, candidates: pick.candidates.length,
      grace, placedAt: null, releasedAt: null, reason: null, seed: run.seed };
    this.log.push(this.entry);
    this._place();
  }

  _place() {
    const pick = this.pending;
    if (!pick) return;
    const h = this.game.creature.acquireScripted(TOKEN);
    if (!h) return;
    this.handle = h;
    this.pending = null;
    const a = pick.choice.anchor;
    const p = cfPos(a.cframe);
    const root = new THREE.Vector3(p.x, p.y + CreatureMetrics.rootHeight, p.z);
    const toward = this.world.roomCentre(this.world.entryRoom(this.level, this.game.run.routes)) || root.clone().add(_ahead);
    toward.y = root.y;
    h.setPose('Biped');
    h.teleport(lookAtMatrix(root, toward));
    h.setHidden(false);
    this.entry.placedAt = this.env.now();
  }

  /** Ends the hold (released into Patrol with a reason; `null`: dropped Dormant, the level left or the run over). */
  _letGo(reason) {
    const h = this.handle;
    this.handle = null;
    this.pending = null;
    this.graceUntil = null;
    if (!h) return;
    if (this.entry) {
      this.entry.releasedAt = this.env.now();
      this.entry.reason = reason || 'Left';
    }
    h.release(reason ? 'Patrol' : 'Dormant');
  }

  /** Whether the Creature is still held in its grace on `level`. */
  holding(level) {
    return (this.handle !== null || this.pending !== null) && this.level === level;
  }

  _noise(e) {
    if (!this.holding(e.level) || e.source !== 'player' || !LOUD.has(e.priority)) return;
    const c = this.game.creature.position(_c);
    const heard = c && c.distanceTo(e.position) <= e.radius;
    this._letGo('Noise');
    if (heard) this.game.creature.alert(e.position, e.priority);
  }

  levelDeactivated(level) {
    if (level === this.level) this._letGo(null);
    this.level = null;
  }

  endRun() {
    this._letGo(null);
    this.level = null;
  }

  tick(dt, now) {
    if (!this.level || !this.game.live()) return;
    if (this.pending && now >= this.nextTryAt) {
      this.nextTryAt = now + RETRY;
      this._place();
    }
    if (!this.handle) return;
    if (now >= this.graceUntil) {
      this._letGo('Grace');
      return;
    }
    if (!this.game.playing()) return;
    const c = this.game.creature.position(_c);
    if (!c) return;
    const root = this.env.rootPosition(_r);
    if (c.distanceTo(root) <= SpawnTuning.ReleaseNear) {
      this._letGo('Near');
      return;
    }
    _h.copy(c).y += CreatureMetrics.eye.Biped;
    if (this.game.seen(_h, SpawnTuning.ReleaseSight)) this._letGo('Seen');
  }
}

const _p = new THREE.Vector3();
const _c = new THREE.Vector3();
const _r = new THREE.Vector3();
const _h = new THREE.Vector3();
const _ahead = new THREE.Vector3(0, 0, -1);
