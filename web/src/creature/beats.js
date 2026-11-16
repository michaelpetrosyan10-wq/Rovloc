// The presence beats' geometry (docs/MONSTER.md 16): where a Peek, a Glimpse, a Shadow or a Pass-by may play for a
// player, over the Creature's own floor lattice. Pure rules over an injected Geo; the service builds it.
//
// Every beat needs a safe, readable place: its stand points are SafeWalk walked or more from every player (never in
// catch reach), the player is not cornered (their room has two ways out or more), a hiding spot stands within HideWalk
// of where they are, and the Creature can walk to the beat's start within ApproachWalk. A plan is null when the floor
// does not offer one; the director then tries another beat, or nothing.
//
//   Peek     a stand point S PeekMin..PeekMax ahead of the player (within PeekCone of the way they face or go), its head
//            in their view (a clear line), and a corner W CornerMin..CornerMax from S where nobody sees it (head and
//            chest): it walks to W unseen, steps out to S, holds PeekHold seconds facing them, steps back to W.
//   Glimpse  a crossing point J GlimpseMin..GlimpseMax ahead (within GlimpseCone), its head in their view, with a point
//            A on their left and B on their right, each CrossMin..CrossMax from J, out of everyone's sight, A and B on
//            opposite sides of J: it walks to A unseen and crosses A -> J -> B at GlimpsePace, then is gone.
//   Shadow   it is ShadowMin..ShadowStart walked from a player who is on the move (ShadowMoving..ShadowRunning: a
//            sprinter would leave it behind), behind them (against their travel): it follows ShadowGap behind along
//            their trail (the service runs it).
//   Pass-by  for a player moving no faster than PassMoving (working, crouching, standing: one on the run would run into
//            it), a point P PassNear..PassFar from them (PassWalk walked or more) and a point E PassOn..PassOnMax walked
//            past P, on the far side from where the Creature comes, PassClear or more from the player: its walk goes
//            through their corridor and on, and nowhere along it (to P, then to E) nearer than PassWalk walked to them
//            (on a shortest way from X to Y every point Q has walk(player, Q) >= (walk(player, X) + walk(player, Y) -
//            walk(X, Y)) / 2: that bound is what is held to PassWalk).

import * as THREE from 'three';

/**
 * @typedef {{player: any, eye: THREE.Vector3, feet: THREE.Vector3, facing: THREE.Vector3, travel: THREE.Vector3|null,
 *   speed: number}} Viewer a player as the beats read one (facing and travel flat and unit)
 * @typedef {Object} Geo
 * @property {THREE.Vector3[]} samples floor points of the Creature's lattice
 * @property {THREE.Vector3} from its feet
 * @property {(a: THREE.Vector3, b: THREE.Vector3) => number} walk walking distance between floor points (Infinity: none)
 * @property {(floor: THREE.Vector3) => boolean} seen whether any player sees its head or chest with its feet there
 * @property {(viewer: Viewer, floor: THREE.Vector3) => boolean} headSeenBy a clear line from their eye to its head there
 * @property {Viewer[]} viewers every player in play
 * @property {(feet: THREE.Vector3) => number} hideWalk walking distance to the nearest hiding spot
 * @property {(feet: THREE.Vector3) => boolean} cornered the player's room has one way out or none
 * @property {() => number} roll the seeded stream
 */

const LEVEL_SPAN = 6;
const EVALUATE = 10; // candidates whose walks are asked, nearest the Creature first

const flatDistance = (a, b) => Math.hypot(a.x - b.x, a.z - b.z);

/** The cosine of the angle between `dir` (flat, unit) and the way from `from` to `to`, flat. */
function bearing(dir, from, to) {
  const dx = to.x - from.x;
  const dz = to.z - from.z;
  const d = Math.hypot(dx, dz);
  if (d < 1e-6) return 1;
  return (dir.x * dx + dir.z * dz) / d;
}

/** The way the player is going (their travel), else the way they face. */
const heading = (viewer) => viewer.travel || viewer.facing;

/** Whether `floor` is SafeWalk walked or more from every player. */
function safe(geo, cfg, floor) {
  for (const v of geo.viewers) {
    if (flatDistance(v.feet, floor) < cfg.SafeWalk && geo.walk(v.feet, floor) < cfg.SafeWalk) return false;
  }
  return true;
}

/** The common conditions on where the player stands. */
function placeOk(geo, cfg, viewer) {
  return !geo.cornered(viewer.feet) && geo.hideWalk(viewer.feet) <= cfg.HideWalk;
}

/** Floor points within `min..max` (flat) of `centre`, on its level, nearest the Creature first. */
function around(geo, centre, min, max, filter) {
  const out = [];
  for (const p of geo.samples) {
    if (Math.abs(p.y - centre.y) > LEVEL_SPAN) continue;
    const d = flatDistance(p, centre);
    if (d < min || d > max) continue;
    if (filter && !filter(p)) continue;
    out.push(p);
  }
  out.sort((a, b) => flatDistance(a, geo.from) - flatDistance(b, geo.from));
  return out;
}

/** A Peek for `viewer`: {kind, target, stand, corner} or null. @param {Geo} geo */
export function planPeek(geo, cfg, viewer) {
  if (!placeOk(geo, cfg, viewer)) return null;
  const cone = Math.cos((cfg.PeekCone * Math.PI) / 180);
  const stands = around(geo, viewer.feet, cfg.PeekMin, cfg.PeekMax,
    (p) => bearing(heading(viewer), viewer.feet, p) >= cone && geo.headSeenBy(viewer, p));
  let tried = 0;
  for (const stand of stands) {
    if (tried++ >= EVALUATE) break;
    if (!safe(geo, cfg, stand) || geo.walk(geo.from, stand) > cfg.ApproachWalk) continue;
    const toViewer = flatDistance(stand, viewer.feet);
    const corners = around(geo, stand, cfg.CornerMin, cfg.CornerMax,
      (p) => flatDistance(p, viewer.feet) >= toViewer - 2 && !geo.seen(p));
    for (const corner of corners.slice(0, EVALUATE)) {
      if (geo.walk(stand, corner) > cfg.CornerMax + 6) continue;
      return { kind: 'Peek', target: viewer.player, stand: stand.clone(), corner: corner.clone() };
    }
  }
  return null;
}

/** A Glimpse for `viewer`: {kind, target, from, via, to} or null. @param {Geo} geo */
export function planGlimpse(geo, cfg, viewer) {
  if (!placeOk(geo, cfg, viewer)) return null;
  const cone = Math.cos((cfg.GlimpseCone * Math.PI) / 180);
  const crossings = around(geo, viewer.feet, cfg.GlimpseMin, cfg.GlimpseMax,
    (p) => bearing(heading(viewer), viewer.feet, p) >= cone && geo.headSeenBy(viewer, p));
  let tried = 0;
  for (const via of crossings) {
    if (tried++ >= EVALUATE) break;
    if (!safe(geo, cfg, via)) continue;
    // their right, looking at the crossing (three.js: Y up, looking down -Z the right is +X)
    const fx = via.x - viewer.feet.x;
    const fz = via.z - viewer.feet.z;
    const fl = Math.hypot(fx, fz) || 1;
    const right = new THREE.Vector3(-fz / fl, 0, fx / fl);
    const side = (p) => (p.x - via.x) * right.x + (p.z - via.z) * right.z;
    const hidden = around(geo, via, cfg.CrossMin, cfg.CrossMax, (p) => !geo.seen(p));
    const lefts = hidden.filter((p) => side(p) < -cfg.CrossMin * 0.5);
    const rights = hidden.filter((p) => side(p) > cfg.CrossMin * 0.5);
    for (const from of lefts.slice(0, 4)) {
      if (geo.walk(from, via) > cfg.CrossMax + 4 || geo.walk(geo.from, from) > cfg.ApproachWalk) continue;
      for (const to of rights.slice(0, 4)) {
        const a = new THREE.Vector3(from.x - via.x, 0, from.z - via.z).normalize();
        const b = new THREE.Vector3(to.x - via.x, 0, to.z - via.z).normalize();
        if (a.dot(b) > -0.5 || geo.walk(via, to) > cfg.CrossMax + 4) continue;
        return { kind: 'Glimpse', target: viewer.player, from: from.clone(), via: via.clone(), to: to.clone() };
      }
    }
  }
  return null;
}

/** A Shadow on `viewer`: {kind, target} or null. @param {Geo} geo @param {number} walk its walk to them now */
export function planShadow(geo, cfg, viewer, walk) {
  // a sprinter would leave it behind, never seeing it: not shadowed
  if (!placeOk(geo, cfg, viewer) || !viewer.travel || viewer.speed < cfg.ShadowMoving || viewer.speed > cfg.ShadowRunning) {
    return null;
  }
  if (walk < cfg.ShadowMin || walk > cfg.ShadowStart) return null;
  // behind them: against the way they go
  if (bearing(viewer.travel, viewer.feet, geo.from) > -cfg.ShadowBehind) return null;
  if (geo.headSeenBy(viewer, geo.from) && bearing(viewer.facing, viewer.feet, geo.from) > 0) return null;
  return { kind: 'Shadow', target: viewer.player };
}

/**
 * Whether a shortest way between two points `a` and `b` walked from a player (`ab` walked between them) keeps `least`
 * walked off them all along (the triangle bound: no point of it is nearer than (a + b - ab) / 2).
 */
export function keepsOff(a, b, ab, least) {
  return Number.isFinite(a) && Number.isFinite(b) && Number.isFinite(ab) && (a + b - ab) / 2 >= least;
}

/** A Pass-by of `viewer`: {kind, target, via, to} or null. @param {Geo} geo */
export function planPassBy(geo, cfg, viewer) {
  if (!placeOk(geo, cfg, viewer) || viewer.speed > cfg.PassMoving) return null;
  const vias = around(geo, viewer.feet, cfg.PassNear, cfg.PassFar);
  let tried = 0;
  for (const via of vias) {
    if (tried++ >= EVALUATE) break;
    const near = geo.walk(viewer.feet, via);
    if (near < cfg.PassWalk || !Number.isFinite(near)) continue;
    const approach = geo.walk(geo.from, via);
    if (approach > cfg.ApproachWalk + cfg.PassFar) continue;
    if (!keepsOff(geo.walk(viewer.feet, geo.from), near, approach, cfg.PassWalk)) continue;
    const inward = new THREE.Vector3(via.x - geo.from.x, 0, via.z - geo.from.z).normalize();
    const ends = around(geo, via, cfg.PassOn, cfg.PassOnMax, (p) => flatDistance(p, viewer.feet) >= cfg.PassClear &&
      new THREE.Vector3(p.x - via.x, 0, p.z - via.z).normalize().dot(inward) > 0.2);
    for (const to of ends.slice(0, 4)) {
      const on = geo.walk(via, to);
      if (on < cfg.PassOn || on > cfg.PassOnMax + 10) continue;
      if (!keepsOff(near, geo.walk(viewer.feet, to), on, cfg.PassWalk)) continue;
      return { kind: 'PassBy', target: viewer.player, via: via.clone(), to: to.clone() };
    }
  }
  return null;
}

/**
 * The beats to try for `viewer`, in a seeded order weighted by BeatWeights (a beat whose weight is 0 never plays),
 * the first whose geometry fits wins.
 * @param {Geo} geo @param {any} cfg presence Beats @param {Viewer} viewer @param {number} walk
 */
export function planBeat(geo, cfg, viewer, walk) {
  const weights = { ...cfg.Weights };
  const order = [];
  while (Object.keys(weights).length) {
    let total = 0;
    for (const w of Object.values(weights)) total += Math.max(0, w);
    if (!(total > 0)) break;
    let at = geo.roll() * total;
    let pick = null;
    for (const [kind, w] of Object.entries(weights)) {
      at -= Math.max(0, w);
      if (at < 0) {
        pick = kind;
        break;
      }
    }
    if (pick === null) pick = Object.keys(weights).pop();
    order.push(pick);
    delete weights[pick];
  }
  for (const kind of order) {
    const plan = kind === 'Peek' ? planPeek(geo, cfg, viewer) : kind === 'Glimpse' ? planGlimpse(geo, cfg, viewer)
      : kind === 'Shadow' ? planShadow(geo, cfg, viewer, walk) : planPassBy(geo, cfg, viewer);
    if (plan) return plan;
  }
  return null;
}
