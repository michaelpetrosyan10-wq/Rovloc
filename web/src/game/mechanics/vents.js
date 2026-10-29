// vents.js: the wall vents (VentNetworkService + GrateRules + CrawlRules + VentController + VentGraph.nearest).
//
// Grates. Every exported VentGrate starts Closed, or Locked when the run's plan rusted it shut. Unscrew (hold, 3.5 s,
// 1.2 s with the Rusty Screwdriver) makes it Unscrewing while held: the four screws back out with the hold, the
// Unscrew cue plays at the panel, a quiet GrateUnscrew noise every 0.9 s; letting go runs the screws back in (Closed);
// completing it makes it Open (the screws drop, the panel swings out over 0.6 s with a creak). Kick (instant) makes
// it Kicked: the panel tears off and lands in 0.35 s after the lead, the 130-stud GrateKick noise, a MetalCrash. A
// locked grate offers both prompts relabelled "Rusted shut" and refuses them. Open and Kicked let crawlers through.
// Crawling. A Crouching player on foot whose root stands in an open grate's mouth box (in front of the room face, at
// most 1.6 studs to either side, at a crouched root height over the floor) and who looks into the wall is put in the
// duct: locomotion mode Vent (VentCrawling / VentScurrying), the root on the duct centreline at the EntryAnchor;
// RunStats VentsCrawled counts each grate once per run. The rail drives the body (VentController): the input picks
// the way along the duct whose tangent matches it best, bends are rounded, junctions take the branch the input points
// down, dead ends and shut grates stop it (just behind the louvres), an open grate's mouth stub carries you out past
// the room face, where the exit stands you up at its ExitAnchor (or 0.75 studs to a side). After an exit you cannot
// crawl back in for 1 s. Presentation: the Vent input context, a dark vignette tightening while scurrying, the
// VentCrawl loop following the rail speed, metal knocks on reversals, corners and stops.

import * as THREE from 'three';
import { GameConfig, perkHoldSeconds } from '../config.js';
import { S } from '../strings.js';
import { approach, cfMatrix, cfPos, clamp, smoothstep } from '../util.js';
import { el } from '../ui/style.js';

const WALL_HALF = 0.5;
const HALF_BORE = 3.5 / 2;
const MOUTH_DEPTH = 2.4;
const MOUTH_HALF_WIDTH = 1.6;
const CROUCH_BELOW = 1.5;
const CROUCH_ABOVE = 1;
const FACING_DOT = 0.4;
const EXIT_DEPTH = WALL_HALF - 0.1;
const EXIT_REACH = WALL_HALF + 3;
const EXIT_SIDE_STEP = 0.75;
const SWIM_BELOW = 2.2;
const SWIM_ABOVE = 1.2;
const ROOT_HEIGHT = 3;
const VENT_CENTRE_HEIGHT = 2;
const ENTRY_COOLDOWN = 1;
const POLL = 0.1;
const PANEL_SECONDS = 0.6;
const KICK_SECONDS = 0.35;
const SCREW_RESET_SECONDS = 0.25;
const SCREW_TRAVEL = 0.36;
const SCREW_TURNS = 9;
const SCREW_BACKOUT = 0.75;
const KICK_HOP = 0.6;
const LEAD = 0.2;
const UNSCREW_NOISE_INTERVAL = 0.9;
// rail
const BALL_RADIUS = 2.6 / 2;
const PANEL_MARGIN = 0.08;
const PANEL_FALLBACK = WALL_HALF;
const ROUND_RADIUS = 3.5 / 2;
const LOOKAHEAD = 3.5 / 2;
const MAX_HOPS = 8;
const MIN_TRAVEL_DOT = 0.2;
const FULL_TRAVEL_DOT = 0.45;
const INPUT_DEADZONE = 0.1;
const PREFER_BONUS = 0.05;
const ACCEL_TIME = 0.14;
const DECEL_TIME = 0.09;
const SPEED_EPS = 1e-3;
const CRAWL_SPEEDS = { VentCrawling: GameConfig.VentCrawlSpeed, VentScurrying: GameConfig.VentScurrySpeed, DownedCrawling: GameConfig.DownedMoveSpeed };
const SWIM_ENTRY = new Set(['Treading', 'Freestyle', 'Underwater']);
// presentation
const KNOCK_COOLDOWN = 0.3;
const KNOCK_SHAKE = 0.45;
const KNOCK_TURN = (30 * Math.PI) / 180;
const BUMP_SPEED = 1.5;
const VIGNETTE_OPACITY = 0.8;
const VIGNETTE_SCURRY = 0.1;

const _v = new THREE.Vector3();
const _w = new THREE.Vector3();

function flatUnit(v, out = new THREE.Vector3()) {
  out.set(v.x, 0, v.z);
  const m = out.length();
  return m > 1e-6 ? out.divideScalar(m) : out.set(0, 0, 0);
}

/** CrawlRules.wallSpace: x along the wall, y up, z out into the room. */
export function wallSpace(wallInv, p, out = new THREE.Vector3()) {
  out.copy(p).applyMatrix4(wallInv);
  out.z = -out.z;
  return out;
}

/** VentGraph.nearest: the closest point on the rail (ducts + grate mouth stubs). */
export function nearestRail(graph, position) {
  let best = null;
  const consider = (a, b, from, to) => {
    const d = _w.subVectors(to, from);
    const len2 = d.lengthSq();
    const t = len2 > 1e-9 ? clamp(_v.subVectors(position, from).dot(d) / len2, 0, 1) : 0;
    const point = from.clone().addScaledVector(d, t);
    const distance = point.distanceTo(position);
    if (!best || distance < best.distance - 1e-6) best = { a, b, t, position: point, distance };
  };
  for (const [id, node] of Object.entries(graph.nodes)) {
    for (const other of node.links) {
      const on = graph.nodes[other];
      if (!on || other === id) continue;
      if (id > other && on.links.includes(id)) continue;
      if (id < other) consider(id, other, graph.pos[id], graph.pos[other]);
      else consider(other, id, graph.pos[other], graph.pos[id]);
    }
  }
  for (const g of Object.values(graph.grates)) {
    if (graph.nodes[g.nodeId]) consider(g.nodeId, null, graph.pos[g.nodeId], graph.mouth[g.id]);
  }
  return best;
}

/** The rail (one level's VentGraph + which grates are passable). */
class Rail {
  constructor(graph, passable, stopShort) {
    this.graph = graph;
    this.passable = passable;
    this.stopShort = stopShort;
  }

  span(c) {
    const g = this.graph;
    const from = g.pos[c.a];
    if (!from) return null;
    if (c.b === null) {
      const grateId = g.grateAtNode[c.a];
      return grateId ? [from, g.mouth[grateId]] : null;
    }
    const to = g.pos[c.b];
    return to ? [from, to] : null;
  }

  position(c, out = new THREE.Vector3()) {
    const s = this.span(c);
    return s ? out.lerpVectors(s[0], s[1], clamp(c.t, 0, 1)) : null;
  }

  fromPoint(point) {
    const c = { a: point.a, b: point.b, t: 0 };
    const s = this.span(c);
    if (s) {
      const off = _w.subVectors(s[1], s[0]);
      const l2 = off.lengthSq();
      if (l2 > 1e-9) c.t = clamp(_v.subVectors(point.position, s[0]).dot(off) / l2, 0, 1);
    }
    return c;
  }

  ways(nodeId) {
    const g = this.graph;
    const node = g.nodes[nodeId];
    const out = [];
    if (!node) return out;
    const p = g.pos[nodeId];
    for (const other of node.links) {
      const q = g.pos[other];
      if (!q) continue;
      const off = new THREE.Vector3().subVectors(q, p);
      if (off.length() > 1e-6) out.push({ a: nodeId, b: other, direction: off.normalize(), blocked: false });
    }
    const grateId = g.grateAtNode[nodeId];
    if (grateId && g.mouth[grateId]) {
      const off = new THREE.Vector3().subVectors(g.mouth[grateId], p);
      if (off.length() > 1e-6) out.push({ a: nodeId, b: null, direction: off.normalize(), blocked: !this.passable(grateId) });
    }
    return out;
  }

  onward(nodeId, c) {
    const fromA = nodeId === c.a;
    const back = fromA ? c.b : c.a;
    const backIsStub = fromA && c.b === null;
    return this.ways(nodeId).filter((w) => !(backIsStub ? w.b === null : w.b === back));
  }

  frontOf(c, heading) {
    const s = this.span(c);
    const length = s ? s[0].distanceTo(s[1]) : 0;
    return heading > 0 ? [c.b, (1 - c.t) * length] : [c.a, c.t * length];
  }

  tangent(c, heading, out = new THREE.Vector3()) {
    const s = this.span(c);
    if (!s) return out.set(0, 0, 0);
    const off = new THREE.Vector3().subVectors(s[1], s[0]);
    const length = off.length();
    if (length < 1e-6) return out.set(0, 0, 0);
    const sign = heading < 0 ? -1 : 1;
    const base = off.divideScalar(length).multiplyScalar(sign);
    const ahead = (sign > 0 ? 1 - c.t : c.t) * length;
    const behind = length - ahead;
    const front = sign > 0 ? c.b : c.a;
    const rear = sign > 0 ? c.a : c.b;
    const blended = base.clone();
    if (front !== null && ahead < ROUND_RADIUS) {
      const next = this.onward(front, c).filter((w) => !w.blocked);
      if (next.length === 1) blended.addScaledVector(_v.subVectors(next[0].direction, base), 0.5 * (1 - ahead / ROUND_RADIUS));
    }
    if (rear !== null && behind < ROUND_RADIUS) {
      const prev = this.onward(rear, c).filter((w) => !w.blocked);
      if (prev.length === 1) blended.addScaledVector(_v.copy(prev[0].direction).negate().sub(base), 0.5 * (1 - behind / ROUND_RADIUS));
    }
    return blended.length() < 1e-4 ? out.copy(base) : out.copy(blended).normalize();
  }

  /** VentController.travel: [heading, strength] for a world input vector. */
  travel(c, input, prefer) {
    const flat = new THREE.Vector3(input.x, 0, input.z);
    const mag = flat.length();
    if (mag < INPUT_DEADZONE) return [0, 0];
    flat.divideScalar(mag);
    let bestHeading = 0;
    let bestScore = -Infinity;
    let bestRank = -Infinity;
    for (const heading of [1, -1]) {
      let score = flat.dot(flatUnit(this.tangent(c, heading)));
      const [front, distance] = this.frontOf(c, heading);
      if (front !== null && distance <= LOOKAHEAD) {
        for (const w of this.onward(front, c)) if (!w.blocked) score = Math.max(score, flat.dot(flatUnit(w.direction)));
      }
      const rank = score + (heading === prefer ? PREFER_BONUS : 0);
      if (rank > bestRank) {
        bestHeading = heading;
        bestScore = score;
        bestRank = rank;
      }
    }
    if (bestScore < MIN_TRAVEL_DOT) return [0, 0];
    return [bestHeading, Math.min(mag, 1) * smoothstep(MIN_TRAVEL_DOT, FULL_TRAVEL_DOT, bestScore)];
  }

  chooseBranch(ways, input, arrival) {
    const open = ways.filter((w) => !w.blocked);
    if (!open.length) return null;
    if (open.length === 1 && arrival) return open[0];
    const flat = new THREE.Vector3(input.x, 0, input.z);
    if (flat.length() < INPUT_DEADZONE) return null;
    flat.normalize();
    let best = null;
    let bestDot = MIN_TRAVEL_DOT;
    for (const w of open) {
      const d = flat.dot(flatUnit(w.direction));
      if (d >= bestDot) {
        best = w;
        bestDot = d;
      }
    }
    return best;
  }

  /** VentController.advance */
  advance(cursor, heading, distance, input) {
    const g = this.graph;
    let cur = { a: cursor.a, b: cursor.b, t: clamp(cursor.t, 0, 1) };
    let sign = heading < 0 ? -1 : 1;
    let remaining = distance > 0 ? distance : 0;
    let travelled = 0;
    let turned = 0;
    let stopped = null;
    for (let hop = 0; hop < MAX_HOPS; hop++) {
      const s = this.span(cur);
      if (!s) {
        stopped = 'DeadEnd';
        break;
      }
      const length = Math.max(s[0].distanceTo(s[1]), 1e-6);
      const ahead = (sign > 0 ? 1 - cur.t : cur.t) * length;
      const front = sign > 0 ? cur.b : cur.a;
      let room = ahead;
      let shut = false;
      if (cur.b === null) {
        const grateId = g.grateAtNode[cur.a];
        if (sign > 0 && grateId && !this.passable(grateId)) {
          room = 0;
          shut = true;
        }
      } else if (front !== null) {
        const grateId = g.grateAtNode[front];
        if (grateId && !this.passable(grateId)) {
          const short = this.stopShort(grateId);
          if (short > 0) {
            room = Math.max(0, ahead - short);
            shut = true;
          }
        }
      }
      if (remaining <= room) {
        cur.t = clamp(cur.t + (sign * remaining) / length, 0, 1);
        travelled += remaining;
        remaining = 0;
        break;
      }
      cur.t = clamp(cur.t + (sign * room) / length, 0, 1);
      travelled += room;
      remaining -= room;
      if (shut) {
        stopped = 'Blocked';
        break;
      }
      if (front === null) {
        stopped = 'Mouth';
        break;
      }
      const arrival = new THREE.Vector3().subVectors(s[1], s[0]).normalize().multiplyScalar(sign);
      const ways = this.onward(front, cur);
      const choice = this.chooseBranch(ways, input, arrival);
      if (!choice) {
        stopped = ways.some((w) => w.blocked) ? 'Blocked' : ways.length ? 'Junction' : 'DeadEnd';
        break;
      }
      turned = Math.max(turned, Math.acos(clamp(flatUnit(arrival).dot(flatUnit(choice.direction)), -1, 1)));
      cur = { a: front, b: choice.b, t: 0 };
      sign = 1;
    }
    return { cursor: cur, heading: sign, travelled, stopped, turned };
  }
}

/** VentController.stepSpeed: [speed, heading, reversed] */
function stepSpeed(speed, heading, wantHeading, want, top, dt) {
  const accel = Math.max(top, 1) / ACCEL_TIME;
  const decel = Math.max(top, speed, 1) / DECEL_TIME;
  if (wantHeading === 0 || want <= 0) return [approach(speed, 0, decel * dt), heading, false];
  if (speed > SPEED_EPS && wantHeading !== heading) {
    const braked = approach(speed, 0, decel * dt);
    if (braked > SPEED_EPS) return [braked, heading, false];
    return [0, wantHeading, true];
  }
  const target = Math.min(want, Math.max(top, 0));
  return [approach(speed, target, (speed < target ? accel : decel) * dt), wantHeading, false];
}

export class Vents {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Vents';
    this.game = game;
    this.env = game.env;
    /** @type {Map<string, any>} */
    this.grates = new Map();
    /** @type {Map<string, any>} level -> graph (positions as vectors) */
    this.graphs = new Map();
    this.crawl = null;
    this.cooldownUntil = -Infinity;
    this.pollClock = 0;
    this.crawled = new Set();
    this.perks = [];
    for (const level of Object.keys(game.world.vents.graphs || {})) this._graph(level);
    for (const info of game.world.entities('VentGrate')) this._index(info);
    this._buildVignette();
  }

  _graph(level) {
    const raw = this.game.world.ventGraph(level);
    if (!raw) return null;
    const g = { level, nodes: raw.nodes, grates: raw.grates, grateAtNode: raw.grateAtNode, pos: {}, mouth: {}, wall: {}, wallInv: {} };
    for (const [id, n] of Object.entries(raw.nodes)) g.pos[id] = new THREE.Vector3(...n.position);
    for (const [id, gr] of Object.entries(raw.grates)) {
      g.mouth[id] = new THREE.Vector3(...gr.mouth);
      g.wall[id] = cfMatrix(gr.wall);
      g.wallInv[id] = g.wall[id].clone().invert();
    }
    this.graphs.set(level, g);
    return g;
  }

  _index(info) {
    const g = this.graphs.get(info.level);
    const a = info.attachments;
    const grate = {
      id: info.id,
      level: info.level,
      info,
      state: 'Closed',
      graph: g,
      wall: g && g.wall[info.id] ? g.wall[info.id] : cfMatrix(info.pivot),
      wallInv: g && g.wallInv[info.id] ? g.wallInv[info.id] : cfMatrix(info.pivot).invert(),
      exit: cfMatrix(a.ExitAnchor),
      entry: cfMatrix(a.EntryAnchor),
      centre: a.PanelCentre ? cfPos(a.PanelCentre) : cfPos(info.pivot),
      panelRest: cfMatrix(a.PanelRest),
      panelOpen: cfMatrix(a.PanelOpen),
      panelKicked: cfMatrix(a.PanelKicked),
      panelCentre: cfMatrix(a.PanelCentre),
      screwRest: [1, 2, 3, 4].map((i) => cfMatrix(a[`Screw${i}Rest`])),
      screwOut: [1, 2, 3, 4].map((i) => cfMatrix(a[`Screw${i}Out`])),
      unscrewSpec: info.prompts.find((p) => p.name === 'Unscrew'),
      kickSpec: info.prompts.find((p) => p.name === 'Kick'),
      floorY: cfPos(a.ExitAnchor).y,
      screws: 0,
      screwMotion: null,
      panelMotion: null,
      kickMotion: null,
      holdSince: null,
      noiseAt: 0,
      sound: null,
      prompts: [],
    };
    this.grates.set(info.id, grate);
  }

  /** The grates on a level (for the hints and the tracker). */
  gratesOn(level) {
    return [...this.grates.values()].filter((g) => g.level === level);
  }

  passable(id) {
    const g = this.grates.get(id);
    return !!g && (g.state === 'Open' || g.state === 'Kicked');
  }

  /** VentController.panelStop: the ball stops short of a shut grate's panel at the wall's room face. */
  stopShort() {
    const at = PANEL_FALLBACK - BALL_RADIUS;
    return clamp(PANEL_MARGIN - at, 0, BALL_RADIUS + PANEL_MARGIN + 3.5);
  }

  // ---------------------------------------------------------------------------------------------------- poses

  _setScrews(grate, progress) {
    const p = clamp(progress, 0, 1);
    grate.screws = p;
    for (let i = 0; i < 4; i++) {
      const rest = grate.screwRest[i];
      let t;
      if (p <= SCREW_BACKOUT) {
        const q = p / SCREW_BACKOUT;
        t = new THREE.Matrix4().makeTranslation(0, 0, -SCREW_TRAVEL * q).multiply(new THREE.Matrix4().makeRotationZ(SCREW_TURNS * 2 * Math.PI * q));
      } else {
        const f = (p - SCREW_BACKOUT) / (1 - SCREW_BACKOUT);
        const backed = new THREE.Matrix4().makeTranslation(0, 0, -SCREW_TRAVEL).multiply(new THREE.Matrix4().makeRotationZ(SCREW_TURNS * 2 * Math.PI));
        const out = rest.clone().invert().multiply(grate.screwOut[i]);
        const up = new THREE.Vector3(0, 1, 0).transformDirection(rest.clone().invert());
        const bp = new THREE.Vector3().setFromMatrixPosition(backed);
        const delta = new THREE.Vector3().setFromMatrixPosition(out).sub(bp);
        const rise = delta.dot(up);
        const flat = delta.clone().addScaledVector(up, -rise);
        const pos = bp.clone().addScaledVector(flat, f).addScaledVector(up, rise * f * f);
        const qb = new THREE.Quaternion().setFromRotationMatrix(backed);
        const qo = new THREE.Quaternion().setFromRotationMatrix(out);
        const turn = new THREE.Quaternion().slerp(qb.clone().invert().multiply(qo), f);
        t = new THREE.Matrix4().compose(pos, qb.multiply(turn), new THREE.Vector3(1, 1, 1));
      }
      this.env.setNodePivot(grate.id, `Screw${i + 1}`, rest.clone().multiply(t));
    }
  }

  _setPanel(grate, openness) {
    const full = grate.panelRest.clone().invert().multiply(grate.panelOpen);
    const q = new THREE.Quaternion().setFromRotationMatrix(full);
    const partial = new THREE.Matrix4().makeRotationFromQuaternion(new THREE.Quaternion().slerp(q, clamp(openness, 0, 1)));
    this.env.setNodePivot(grate.id, 'Panel', grate.panelRest.clone().multiply(partial));
  }

  _setKicked(grate, t) {
    const k = clamp(t, 0, 1);
    const rest = grate.panelRest;
    const centre = grate.panelCentre;
    const offset = centre.clone().invert().multiply(rest);
    const landed = grate.panelKicked.clone().multiply(offset.clone().invert());
    const cP = new THREE.Vector3().setFromMatrixPosition(centre);
    const lP = new THREE.Vector3().setFromMatrixPosition(landed);
    const delta = lP.clone().sub(cP);
    const out = 1 - (1 - k) * (1 - k);
    const tip = smoothstep(0, 1, k);
    const pos = new THREE.Vector3(cP.x + delta.x * out, cP.y + delta.y * tip + KICK_HOP * Math.sin(Math.PI * k), cP.z + delta.z * out);
    const qc = new THREE.Quaternion().setFromRotationMatrix(centre);
    const ql = new THREE.Quaternion().setFromRotationMatrix(landed);
    const rel = qc.clone().invert().multiply(ql);
    const rot = qc.clone().multiply(new THREE.Quaternion().slerp(rel, tip));
    const pivot = new THREE.Matrix4().compose(pos, rot, new THREE.Vector3(1, 1, 1)).multiply(offset);
    this.env.setNodePivot(grate.id, 'Panel', pivot);
    const world = pivot.clone().multiply(rest.clone().invert());
    for (let i = 0; i < 4; i++) this.env.setNodePivot(grate.id, `Screw${i + 1}`, world.clone().multiply(grate.screwRest[i]));
  }

  _restPose(grate) {
    this._setPanel(grate, 0);
    this._setScrews(grate, 0);
  }

  // ---------------------------------------------------------------------------------------------------- state

  _setState(grate, state) {
    if (grate.state === state) return;
    grate.state = state;
    this.env.setEntityAttribute(grate.id, 'GrateState', state);
    const serves = state === 'Closed' || state === 'Unscrewing' || state === 'Locked';
    for (const p of grate.prompts) {
      p.setEnabled(serves);
      p.setText(p.kind === 'Kick' ? S('Prompt.Kick') : S('Prompt.Unscrew'), S(state === 'Locked' ? 'Prompt.GrateLocked' : 'Prompt.Grate'));
    }
  }

  /** ForceGrate (scripts, the Creature, dev): Closed / Locked shut it, Open unscrews and swings it, Kicked kicks it. */
  force(id, state) {
    const grate = this.grates.get(id);
    if (!grate || state === 'Unscrewing' || grate.state === state) return false;
    if ((grate.state === 'Open' || grate.state === 'Kicked') && (state === 'Open' || state === 'Kicked')) return false;
    this._cancelUnscrew(grate, true);
    if (state === 'Kicked') return this._kick(grate, false);
    if (state === 'Open') {
      this._setScrews(grate, 1);
      grate.panelMotion = { from: 0, to: 1, startAt: this.env.now(), seconds: PANEL_SECONDS };
      this._setState(grate, 'Open');
      return true;
    }
    this._restPose(grate);
    this._setState(grate, state);
    return true;
  }

  _unscrewBegan(grate) {
    if (grate.state === 'Locked') {
      this.env.hint(S('Prompt.GrateLocked'), 2.5);
      return;
    }
    if (grate.state !== 'Closed' || this.game.life.state !== 'Alive') return;
    grate.holdSince = this.env.now();
    grate.screwMotion = null;
    grate.noiseAt = 0;
    this._setState(grate, 'Unscrewing');
    const seconds = perkHoldSeconds('Unscrew', grate.unscrewSpec ? grate.unscrewSpec.holdDuration : GameConfig.UnscrewSeconds, this.perks);
    grate.sound = this.game.playAt('Unscrew', grate.centre, { loop: true });
    grate.duration = seconds;
  }

  _cancelUnscrew(grate, silent) {
    if (grate.state !== 'Unscrewing') return;
    grate.holdSince = null;
    if (grate.sound) grate.sound.stop(0.1);
    grate.sound = null;
    grate.screwMotion = { from: grate.screws, to: 0, startAt: this.env.now(), seconds: SCREW_RESET_SECONDS };
    if (!silent) this._setState(grate, 'Closed');
    else grate.state = 'Closed';
  }

  _unscrewDone(grate) {
    if (grate.state !== 'Unscrewing') return;
    grate.holdSince = null;
    if (grate.sound) grate.sound.stop(0.1);
    grate.sound = null;
    grate.screwMotion = { from: Math.max(grate.screws, SCREW_BACKOUT), to: 1, startAt: this.env.now(), seconds: 0.35 };
    grate.panelMotion = { from: 0, to: 1, startAt: this.env.now() + 0.15, seconds: PANEL_SECONDS };
    this.game.playAt('MetalCreak', grate.centre, { volume: 0.6 });
    this._setState(grate, 'Open');
  }

  _kick(grate, byPlayer) {
    if (grate.state === 'Locked') {
      this.env.hint(S('Prompt.GrateLocked'), 2.5);
      return false;
    }
    if (byPlayer && (grate.state !== 'Closed' || this.game.life.state !== 'Alive')) return false;
    grate.kickMotion = { from: 0, to: 1, startAt: this.env.now() + LEAD, seconds: KICK_SECONDS };
    this._setState(grate, 'Kicked');
    this.game.noise(grate.centre, 'GrateKick', { medium: this.crawl ? 'Vent' : undefined, ventNodeId: grate.info.attributes.NodeId });
    this.game.playAt('MetalCrash', grate.centre);
    return true;
  }

  // ---------------------------------------------------------------------------------------------------- run

  beginRun(run) {
    this.perks = run.perks;
    this.crawled.clear();
    this.cooldownUntil = -Infinity;
    for (const grate of this.grates.values()) {
      grate.state = run.plan.lockedGrates.has(grate.id) ? 'Locked' : 'Closed';
      this.env.setEntityAttribute(grate.id, 'GrateState', grate.state);
      grate.screwMotion = grate.panelMotion = grate.kickMotion = null;
      grate.holdSince = null;
      this._restPose(grate);
      const locked = grate.state === 'Locked';
      const object = S(locked ? 'Prompt.GrateLocked' : 'Prompt.Grate');
      const unscrewHold = perkHoldSeconds('Unscrew', grate.unscrewSpec ? grate.unscrewSpec.holdDuration : GameConfig.UnscrewSeconds, this.perks);
      const unscrew = this.env.addPrompt({
        entity: grate.id,
        attachment: 'PromptPoint',
        text: S('Prompt.Unscrew'),
        objectText: object,
        holdSeconds: locked ? 0 : unscrewHold,
        distance: grate.unscrewSpec ? grate.unscrewSpec.maxDistance : 7,
        requiresLineOfSight: false,
        onHoldBegan: () => this._unscrewBegan(grate),
        onHoldEnded: () => {
          if (grate.state === 'Unscrewing' && grate.holdSince !== null) this._cancelUnscrew(grate, false);
        },
        onTriggered: () => {
          if (grate.state === 'Unscrewing') this._unscrewDone(grate);
        },
      });
      unscrew.kind = 'Unscrew';
      const kick = this.env.addPrompt({
        entity: grate.id,
        attachment: 'PromptPoint',
        action: 'Kick',
        text: S('Prompt.Kick'),
        objectText: object,
        holdSeconds: 0,
        distance: grate.kickSpec ? grate.kickSpec.maxDistance : 7,
        requiresLineOfSight: false,
        onTriggered: () => this._kick(grate, true),
      });
      kick.kind = 'Kick';
      grate.prompts = [unscrew, kick];
    }
  }

  endRun() {
    if (this.crawl) this._release();
    for (const grate of this.grates.values()) {
      if (grate.sound) grate.sound.stop(0.1);
      grate.sound = null;
      for (const p of grate.prompts) p.remove();
      grate.prompts = [];
      grate.state = 'Closed';
      this._restPose(grate);
    }
  }

  // ---------------------------------------------------------------------------------------------------- crawling

  _rootHeightOk(grate, root) {
    const above = root.y - (grate.wall.elements[13] - VENT_CENTRE_HEIGHT);
    return above >= ROOT_HEIGHT - CROUCH_BELOW && above <= ROOT_HEIGHT + CROUCH_ABOVE;
  }

  _inMouth(grate, root) {
    const p = wallSpace(grate.wallInv, root, _v);
    const out = p.z - WALL_HALF;
    return out >= 0 && out <= MOUTH_DEPTH && Math.abs(p.x) <= MOUTH_HALF_WIDTH;
  }

  _facesWall(grate) {
    const dir = this.env.look().direction;
    _w.set(grate.wall.elements[8], grate.wall.elements[9], grate.wall.elements[10]); // -LookVector = +Z column
    return dir.dot(_w) >= FACING_DOT;
  }

  /** A swimmer at a pool grate's mouth, on the water surface, looking in (CrawlRules.inSwimMouthBox). */
  trySwimEntry(surfaceY) {
    const env = this.env;
    if (this.crawl || env.now() < this.cooldownUntil || this.game.life.state !== 'Alive' || this.game.controlLock() !== 'None') return false;
    if (!SWIM_ENTRY.has(env.moveState())) return false;
    const root = env.rootPosition(_root);
    for (const grate of this.grates.values()) {
      if (grate.level !== this.game.level || !this.passable(grate.id)) continue;
      if (!this._inMouth(grate, root) || !this._facesWall(grate)) continue;
      const above = root.y - surfaceY;
      if (above < -SWIM_BELOW || above > SWIM_ABOVE) continue;
      this._enter(grate);
      return true;
    }
    return false;
  }

  _enter(grate) {
    const env = this.env;
    const graph = grate.graph;
    if (!graph) return;
    if (this.game.pool) this.game.pool.leaveWater();
    env.setMode('Vent');
    const entry = new THREE.Vector3().setFromMatrixPosition(grate.entry);
    entry.y = grate.wall.elements[13];
    const yaw = Math.atan2(grate.entry.elements[8], grate.entry.elements[10]);
    env.teleport({ position: entry, yaw });
    const rail = new Rail(graph, (id) => this.passable(id), () => this.stopShort());
    const near = nearestRail(graph, entry);
    this.crawl = {
      grate: grate.id,
      rail,
      cursor: near ? rail.fromPoint(near) : { a: grate.info.attributes.NodeId, b: null, t: 0.5 },
      heading: -1,
      speed: 0,
      lastKnockAt: -Infinity,
      lastStop: null,
      voice: null,
    };
    if (!this.crawled.has(grate.id)) {
      this.crawled.add(grate.id);
      this.game.stats.increment('VentsCrawled');
    }
    env.pushContext('Vent', 'Vent');
    env.setMotionOverride('VentRail', (dt) => this._drive(dt), 5);
    this.crawl.voice = env.play('VentCrawl', { loop: true, volume: 0, fadeIn: 0.12 });
  }

  _exitThrough(grate) {
    const env = this.env;
    const candidates = [0, -EXIT_SIDE_STEP, EXIT_SIDE_STEP].map((x) => grate.exit.clone().multiply(new THREE.Matrix4().makeTranslation(x, 0, 0)));
    const mouth = grate.graph ? grate.graph.mouth[grate.id] : grate.centre;
    let chosen = candidates[0];
    for (const c of candidates) {
      const stand = new THREE.Vector3().setFromMatrixPosition(c);
      const chest = stand.clone().add(new THREE.Vector3(0, ROOT_HEIGHT, 0));
      if (env.lineClear(mouth, chest, { ignoreEntities: true })) {
        chosen = c;
        break;
      }
    }
    const pos = new THREE.Vector3().setFromMatrixPosition(chosen).add(new THREE.Vector3(0, ROOT_HEIGHT, 0));
    const yaw = Math.atan2(chosen.elements[8], chosen.elements[10]);
    this._release();
    env.teleport({ position: pos, yaw });
    if (this.game.traps) this.game.traps.noteTeleport();
  }

  /** Ends the crawl where the player is (exit, death, scripted moves, the run's end). */
  _release() {
    const env = this.env;
    const c = this.crawl;
    if (!c) return;
    this.crawl = null;
    if (c.voice) c.voice.stop(0.3);
    env.setMotionOverride('VentRail', null);
    env.popContext('Vent');
    env.setMode('OnFoot');
    this.cooldownUntil = env.now() + ENTRY_COOLDOWN;
  }

  /** Whether the player is crawling. */
  inVent() {
    return !!this.crawl;
  }

  /** The VentGraph node nearest the crawler (for the noise bus / flasks), or null. */
  crawlerNode() {
    const c = this.crawl;
    if (!c) return null;
    return c.cursor.t < 0.5 || c.cursor.b === null ? c.cursor.a : c.cursor.b;
  }

  /** The rail motion (the engine's motion override while crawling). */
  _drive(dt) {
    const c = this.crawl;
    if (!c) return;
    const env = this.env;
    const body = env.body();
    if (env.isLocked()) return;
    const mv = env.moveVector();
    const yaw = env.look().yaw;
    const input = _in.set(Math.cos(yaw) * mv.x - Math.sin(yaw) * mv.y, 0, -Math.sin(yaw) * mv.x - Math.cos(yaw) * mv.y);
    const top = CRAWL_SPEEDS[env.moveState()] ?? GameConfig.VentCrawlSpeed;
    const [wantHeading, strength] = c.rail.travel(c.cursor, input, c.heading);
    const [speed, heading, reversed] = stepSpeed(c.speed, c.heading, wantHeading, top * strength, top, dt);
    c.speed = speed;
    c.heading = heading;
    const now = env.now();
    if (reversed && now - c.lastKnockAt > KNOCK_COOLDOWN) this._knock(c, 0.4);
    if (speed > SPEED_EPS) {
      const step = c.rail.advance(c.cursor, heading, speed * dt, input);
      c.cursor = step.cursor;
      c.heading = step.heading;
      if (step.turned > KNOCK_TURN) this._knock(c, 0.55);
      if (step.stopped) {
        if (speed > BUMP_SPEED && c.lastStop !== step.stopped) this._knock(c, 1);
        c.lastStop = step.stopped;
        c.speed = 0;
      } else c.lastStop = null;
    }
    const p = c.rail.position(c.cursor, _pos);
    if (p) {
      body.position.copy(p);
      body.velocity.set(0, 0, 0);
    }
    if (c.voice) c.voice.setVolume(Math.min(1, speed / Math.max(top, 1)) * (env.moveState() === 'VentScurrying' ? 1 : 0.5), 0.1);
  }

  _knock(c, strength) {
    c.lastKnockAt = this.env.now();
    this.env.play('VentCrawl', { volume: 1.1 * strength });
    this.env.shake(KNOCK_SHAKE * strength, 0.22);
  }

  // ---------------------------------------------------------------------------------------------------- drive

  tick(dt, now) {
    const g = this.game;
    // unscrew progress (screws follow the hold), the quiet noise
    for (const grate of this.grates.values()) {
      if (grate.state === 'Unscrewing' && grate.holdSince !== null) {
        const p = clamp((now - grate.holdSince) / Math.max(grate.duration || 1, 1e-3), 0, 1);
        this._setScrews(grate, p * SCREW_BACKOUT);
        if (now >= grate.noiseAt) {
          grate.noiseAt = now + UNSCREW_NOISE_INTERVAL;
          g.noise(grate.centre, 'GrateUnscrew', { medium: this.crawl ? 'Vent' : undefined, ventNodeId: grate.info.attributes.NodeId });
        }
      }
    }
    if (!g.live()) return;
    if (this.crawl && !g.life.playing()) {
      this._release();
      return;
    }
    this.pollClock += dt;
    if (this.pollClock < POLL) return;
    this.pollClock = 0;
    const env = this.env;
    const root = env.rootPosition(_root);
    if (this.crawl) {
      if (g.controlLock() !== 'None') return;
      for (const grate of this.grates.values()) {
        if (grate.level !== g.level || !this.passable(grate.id)) continue;
        const p = wallSpace(grate.wallInv, root, _v);
        if (p.z >= EXIT_DEPTH && p.z <= EXIT_REACH && Math.abs(p.x) <= HALF_BORE && Math.abs(p.y) <= HALF_BORE) {
          this._exitThrough(grate);
          return;
        }
      }
      return;
    }
    if (now < this.cooldownUntil || g.life.state !== 'Alive' || g.controlLock() !== 'None') return;
    if (env.mode() !== 'OnFoot' || env.moveState() !== 'Crouching') return;
    for (const grate of this.grates.values()) {
      if (grate.level !== g.level || !this.passable(grate.id)) continue;
      if (this._inMouth(grate, root) && this._rootHeightOk(grate, root) && this._facesWall(grate)) {
        this._enter(grate);
        return;
      }
    }
  }

  frame(dt, now) {
    for (const grate of this.grates.values()) {
      const s = grate.screwMotion;
      if (s && now >= s.startAt) {
        const t = clamp((now - s.startAt) / s.seconds, 0, 1);
        this._setScrews(grate, s.from + (s.to - s.from) * (1 - (1 - t) * (1 - t)));
        if (t >= 1) grate.screwMotion = null;
      }
      const pm = grate.panelMotion;
      if (pm && now >= pm.startAt) {
        const t = clamp((now - pm.startAt) / pm.seconds, 0, 1);
        this._setPanel(grate, pm.from + (pm.to - pm.from) * (1 - (1 - t) * (1 - t)));
        if (t >= 1) grate.panelMotion = null;
      }
      const km = grate.kickMotion;
      if (km && now >= km.startAt) {
        const t = clamp((now - km.startAt) / km.seconds, 0, 1);
        this._setKicked(grate, t);
        if (t >= 1) grate.kickMotion = null;
      }
    }
    // the duct's vignette
    const inside = !!this.crawl;
    const scurry = inside && this.env.moveState() === 'VentScurrying' ? 1 : 0;
    const want = inside ? VIGNETTE_OPACITY + VIGNETTE_SCURRY * scurry : 0;
    this.vignetteAlpha += Math.sign(want - this.vignetteAlpha) * Math.min(Math.abs(want - this.vignetteAlpha), (inside ? 5 : 7) * dt);
    this.vignette.style.opacity = String(this.vignetteAlpha);
    this.vignette.style.display = this.vignetteAlpha > 0.001 ? '' : 'none';
    this.vignette.style.background = `radial-gradient(ellipse at center, rgba(0,0,0,0) ${46 - 6 * scurry}%, rgba(0,0,0,0.95) 100%)`;
  }

  _buildVignette() {
    this.vignetteAlpha = 0;
    this.vignette = el('div', 'rg-layer', this.env.uiRoot());
    this.vignette.style.zIndex = '2';
    this.vignette.style.display = 'none';
  }
}

const _root = new THREE.Vector3();
const _in = new THREE.Vector3();
const _pos = new THREE.Vector3();
