// actors.js: who a cutscene shows (docs/design/game-spec-v2.md 2.2, 2.3), drawn where its timeline's tracks put them.
//
//   Cast      a story character in their CastConfig costume (Danny's grey hoodie and red beanie, Gus's jumpsuit),
//             drawn with the co-op avatar renderer (coop/avatars.js AvatarBody), playing the track's clips
//   Party     P1..P4: the squad's own avatars as themselves (each in their slot's colour, the local player included),
//             in the seeded cast order
//   Crawler   the mask crawler: the Tall Man's mask (creature/mask.js's sculpt) at CastConfig.Crawler.MaskScale on eight
//             pale two-segment finger-legs; clips Folded (lying face up, legs tucked away), Held (upright in a hand,
//             legs tucked away), Unfold (the legs open out of the rim, feeling the air), Wrap (they curl back round a
//             head), Hidden
//   Monster   the Creature rig itself, held by the scene (creatureApi's scripted handle: only the authority moves it;
//             a co-op client sees the host's): its root teleported along the track every tick, the clips its actions
//             (Unfold: FadeIn at the clip's rate from folded, Stare, ReachIn, Hunch: hunched and staring down at the
//             gap of the bin the authority's player hides in, Walk
//             and Idle: no layer, Hidden)
//   Prop      a small set piece (Sneakers: a pair of white sneakers, empty)
// Positions arrive in the timeline's origin frame (its CutsceneMark); a body's track point is its feet. No gore, no
// blood (I12): the transformation is the lamp, the shadow, the sound and the Creature's own reveal.

import * as THREE from 'three';
import { NodeTable } from '../../engine/batch.js';
import { createWorldMaterial } from '../../engine/materials.js';
import { maskSpec, sculptGrid } from '../../creature/mask.js';
import { AvatarBody, createBodyBatch, lookOfCostume, lookOfSlot, PARTS } from '../coop/avatars.js';
import { CreatureMetrics } from '../creatureApi.js';
import { items } from '../rules/tracks.js';
import { cfMatrix } from '../util.js';

const ROOT_TO_FEET = 3;
const BODIES = 6;
const PORCELAIN = [226, 220, 210];
const EYE = [22, 20, 20];
const SNEAKER = [226, 226, 222];
const SOLE = [190, 188, 184];
const CRACK = [92, 86, 80];
/** hairline cracks over the glaze, face frame before the scale: x, y, length, angle */
const CRACKS = [[0.2, 0.32, 0.34, -0.9], [0.27, 0.18, 0.18, -0.2], [-0.24, -0.12, 0.3, 1.1], [0.08, -0.55, 0.22, 0.5]];

const _m = new THREE.Matrix4();
const _q = new THREE.Quaternion();
const _v = new THREE.Vector3();
const _w = new THREE.Vector3();
const _s = new THREE.Vector3(1, 1, 1);
const _down = new THREE.Vector3(0, -1, 0);
const _probe = new THREE.Color();

/** Colours and tags a geometry for a node slot (the world material's attributes). */
function tagged(g, rgb, slot) {
  const geometry = g.index ? g.toNonIndexed() : g;
  const n = geometry.attributes.position.count;
  const color = new Float32Array(n * 3);
  const node = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    color[i * 3] = rgb[0] / 255;
    color[i * 3 + 1] = rgb[1] / 255;
    color[i * 3 + 2] = rgb[2] / 255;
    node[i] = slot;
  }
  geometry.setAttribute('color', new THREE.BufferAttribute(color, 3));
  geometry.setAttribute('node', new THREE.BufferAttribute(node, 1));
  if (!geometry.attributes.uv) geometry.setAttribute('uv', new THREE.BufferAttribute(new Float32Array(n * 2), 2));
  return geometry;
}

function mergeAll(parts) {
  let count = 0;
  for (const g of parts) count += g.attributes.position.count;
  const out = new THREE.BufferGeometry();
  for (const [name, size] of [['position', 3], ['normal', 3], ['uv', 2], ['color', 3], ['node', 1]]) {
    const arr = new Float32Array(count * size);
    let o = 0;
    for (const g of parts) {
      arr.set(g.attributes[name].array, o);
      o += g.attributes[name].array.length;
    }
    out.setAttribute(name, new THREE.BufferAttribute(arr, size));
  }
  for (const g of parts) g.dispose();
  out.boundingSphere = new THREE.Sphere(new THREE.Vector3(), 1e6);
  return out;
}

/** The mask's face as a mesh at `scale` (face frame: x right, y up, z back; the face looks along -Z). */
function maskGeometry(meta, scale, slot) {
  const spec = maskSpec(meta);
  const pieces = sculptGrid(spec, { cols: 28, upperRows: 26, lowerRows: 16 });
  const positions = [];
  const normals = [];
  for (const g of pieces) {
    const at = (i, j) => i * g.width + j;
    for (let i = 0; i < g.rows - 1; i++) {
      for (let j = 0; j < g.width - 1; j++) {
        for (const v of [at(i, j), at(i + 1, j + 1), at(i, j + 1), at(i, j), at(i + 1, j), at(i + 1, j + 1)]) {
          positions.push(g.P[v * 3] * scale, g.P[v * 3 + 1] * scale, g.P[v * 3 + 2] * scale);
          normals.push(g.N[v * 3], g.N[v * 3 + 1], g.N[v * 3 + 2]);
        }
      }
    }
  }
  const face = new THREE.BufferGeometry();
  face.setAttribute('position', new THREE.BufferAttribute(new Float32Array(positions), 3));
  face.setAttribute('normal', new THREE.BufferAttribute(new Float32Array(normals), 3));
  const parts = [tagged(face, PORCELAIN, slot)];
  // the eye holes and the slit, dark in the pale glaze, and the hairline cracks that make it pretty and old
  const front = -spec.depth * scale - 0.006;
  for (const sx of [-1, 1]) {
    const eye = new THREE.SphereGeometry(1, 10, 6);
    eye.scale(spec.holeW * scale * 0.62, spec.holeH * scale * 0.62, 0.012);
    eye.translate(sx * spec.eyeX * scale, 0, front);
    parts.push(tagged(eye, EYE, slot));
  }
  const slit = new THREE.BoxGeometry(spec.slitHalf * 1.3 * scale, 0.008, 0.012);
  slit.rotateZ(0.06);
  slit.translate(0.01, spec.slitY * scale, front * 0.86);
  parts.push(tagged(slit, EYE, slot));
  for (const [x, y, length, angle] of CRACKS) {
    const crack = new THREE.BoxGeometry(length * scale, 0.006, 0.01);
    crack.rotateZ(angle);
    crack.translate(x * scale, y * scale, front * 0.9);
    parts.push(tagged(crack, CRACK, slot));
  }
  return { parts, spec };
}

/**
 * The cutscene's drawables over one timeline: build(...) once per cutscene, draw(sample, dt) each frame (bodies, the
 * crawler, props), tickMonster(...) each tick (the Creature), dispose() at its end.
 */
export class Actors {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.game = game;
    this.env = game.env;
    const meta = game.world.meta;
    this.cast = meta.castConfig || { Actors: {}, Crawler: {} };
    this.crawlerSpec = this.cast.Crawler || {};
    this.bodyBatch = null;
    /** @type {Map<string, {kind: string, body?: AvatarBody, pose?: any}>} */
    this.list = new Map();
    this.origin = new THREE.Matrix4();
    this.originYaw = 0;
    this.props = null;
    this.monster = null;
  }

  _ensureProps() {
    if (this.props) return this.props;
    const env = this.env;
    const c = this.crawlerSpec;
    const legs = c.Legs || 8;
    const segments = c.LegSegments || 2;
    const table = new NodeTable(1 + legs * segments + 1);
    for (let i = 0; i < 1 + legs * segments + 1; i++) table.alloc(new THREE.Matrix4(), 0);
    const material = createWorldMaterial(env.engine.shared, { baked: false, nodes: true, nodeTexture: table.texture,
      roughness: 0.35, reflectance: 0.12 });
    material.userData.castShadow = true;
    const scale = c.MaskScale || 0.45;
    const { parts, spec } = maskGeometry(this.game.world.meta, scale, 0);
    const segment = (c.LegLength || 0.9) / segments;
    const thick = c.LegThickness || 0.06;
    const legColor = c.LegColor || [222, 214, 204];
    for (let i = 0; i < legs * segments; i++) {
      const g = new THREE.BoxGeometry(thick, segment, thick);
      g.translate(0, -segment / 2, 0);
      parts.push(tagged(g, legColor, 1 + i));
    }
    const crawler = new THREE.Mesh(mergeAll(parts), material);
    const sneakers = [];
    const shoe = 1 + legs * segments;
    for (const sx of [-0.34, 0.34]) {
      const upper = new THREE.BoxGeometry(0.58, 0.28, 0.9);
      upper.translate(sx, 0.2, -0.04);
      const sole = new THREE.BoxGeometry(0.62, 0.08, 0.96);
      sole.translate(sx, 0.04, -0.04);
      sneakers.push(tagged(upper, SNEAKER, shoe), tagged(sole, SOLE, shoe));
    }
    const sneakerMesh = new THREE.Mesh(mergeAll(sneakers), material);
    for (const mesh of [crawler, sneakerMesh]) {
      mesh.frustumCulled = false;
      mesh.matrixAutoUpdate = false;
      env.addToScene(mesh);
    }
    this.props = { table, material, crawler, sneakers: sneakerMesh, legs, segments, segment, scale, spec, shoe };
    return this.props;
  }

  /**
   * The drawables of `timeline` (StoryConfig's), its positions in the mark `originCframe` (12 numbers). `cast` names
   * each party actor's player: {P1: {slot, name}, ...} (absent ones are not drawn).
   */
  build(timeline, originCframe, cast) {
    this.dispose();
    cfMatrix(originCframe, this.origin);
    _v.set(-this.origin.elements[8], 0, -this.origin.elements[10]);
    this.originYaw = Math.atan2(-_v.x, -_v.z);
    if (!this.bodyBatch) this.bodyBatch = createBodyBatch(this.env, BODIES);
    let next = 0;
    for (const track of items(timeline.actors)) {
      if (track.kind === 'Cast' || track.kind === 'Party') {
        let look = null;
        if (track.kind === 'Cast' && this.cast.Actors && this.cast.Actors[track.actor]) look = lookOfCostume(this.cast.Actors[track.actor]);
        if (track.kind === 'Party' && cast[track.actor]) look = lookOfSlot(cast[track.actor].slot);
        if (!look || next >= BODIES) continue;
        const body = new AvatarBody(this.env, this.bodyBatch, next * PARTS, look, `Actor:${track.actor}`);
        next++;
        this.list.set(track.actor, { kind: track.kind, body });
      } else {
        if (track.kind === 'Crawler' || track.kind === 'Prop') this._ensureProps();
        this.list.set(track.actor, { kind: track.kind });
      }
    }
  }

  /** A track point (origin frame) in the world. */
  worldOf(pos, out = new THREE.Vector3()) {
    return out.set(pos.x, pos.y, pos.z).applyMatrix4(this.origin);
  }

  /** A track yaw (degrees, origin frame) as a world yaw in radians. */
  yawOf(yaw) {
    return this.originYaw + (yaw * Math.PI) / 180;
  }

  /**
   * Draws everyone the sample shows (a frame: the sample is taken at the frame's time, so motion is smooth; every
   * pose is a function of that time alone).
   * @param {any} sample CinematicTracks.sample's
   * @param {number} dt
   * @param {Set<string>} [hiddenActors] actors not to draw (a leaver's, after the next cut)
   */
  draw(sample, dt, hiddenActors) {
    for (const [name, actor] of this.list) {
      const s = sample.actors[name];
      if (!s) continue;
      const visible = s.visible && !(hiddenActors && hiddenActors.has(name));
      if (actor.body) {
        if (!visible) {
          if (actor.body.shown) actor.body.hide();
          continue;
        }
        const p = this.worldOf(s.pos, _w);
        actor.body.draw(dt, { x: p.x, y: p.y + ROOT_TO_FEET, z: p.z, yaw: this.yawOf(s.yaw), pitch: 0, clip: s.clip,
          clipTime: s.clipTime });
      } else if (actor.kind === 'Crawler') this._drawCrawler(s, visible);
      else if (actor.kind === 'Prop') this._drawProp(name, s, visible);
    }
    if (this.bodyBatch) this.bodyBatch.table.flush();
    if (this.props) this.props.table.flush();
  }

  _drawCrawler(s, visible) {
    const P = this.props;
    const table = P.table;
    const total = 1 + P.legs * P.segments;
    if (!visible) {
      for (let i = 0; i < total; i++) table.setMode(i, 0);
      return;
    }
    const p = this.worldOf(s.pos, _w);
    this.env.probeAt(p, _probe);
    // the mask's frame: upright facing along its yaw; lying face up while folded on the straw
    const frame = _m.makeRotationY(this.yawOf(s.yaw)).setPosition(p);
    // (the face looks along -Z, its shell behind it: a quarter turn about X turns the face up and the shell above the straw)
    if (s.clip === 'Folded') frame.multiply(new THREE.Matrix4().makeRotationX(Math.PI / 2));
    table.setMatrix(0, frame);
    table.setLight(0, _probe.r, _probe.g, _probe.b, 2);
    const t = s.clipTime;
    const open = s.clip === 'Unfold' ? Math.min(1, t / 1.6) : s.clip === 'Wrap' ? 1 : 0;
    const wrap = s.clip === 'Wrap' ? Math.min(1, t / 0.4) : 0;
    const spread = ((this.crawlerSpec.LegSpread || 38) * Math.PI) / 180;
    const rx = 0.42 * P.scale;
    const ry = 0.6 * P.scale;
    for (let leg = 0; leg < P.legs; leg++) {
      const a = (leg / P.legs) * Math.PI * 2 + Math.PI / P.legs;
      const root = _v.set(Math.cos(a) * rx, Math.sin(a) * ry, 0.04);
      // outward in the mask's plane, swept back by the spread; wrapping, they reach back round the head
      const feel = Math.sin(t * 9 + leg * 1.7) * 0.25 * open * (1 - wrap);
      const back = spread + (Math.PI / 2 - spread) * wrap + feel;
      const dir = new THREE.Vector3(Math.cos(a) * Math.cos(back), Math.sin(a) * Math.cos(back), Math.sin(back));
      const segFrame = new THREE.Matrix4();
      let at = root.clone();
      for (let k = 0; k < P.segments; k++) {
        const slot = 1 + leg * P.segments + k;
        if (open <= 0.001) {
          table.setMode(slot, 0);
          continue;
        }
        // the knuckle bends the second segment inward (toward the face's middle, and back when wrapping)
        const bend = k === 0 ? 0 : 0.9 + 0.7 * wrap;
        const d = dir.clone().lerp(new THREE.Vector3(-Math.cos(a), -Math.sin(a), 0.6 + wrap).normalize(), Math.min(1, bend * 0.5)).normalize();
        _q.setFromUnitVectors(_down, d);
        segFrame.compose(at, _q, _s.set(1, open, 1));
        const world = new THREE.Matrix4().multiplyMatrices(frame, segFrame);
        table.setMatrix(slot, world);
        table.setLight(slot, _probe.r, _probe.g, _probe.b, 2);
        at = at.clone().addScaledVector(d, P.segment * open);
      }
    }
  }

  _drawProp(name, s, visible) {
    const P = this.props;
    if (name !== 'Sneakers' || s.clip !== 'Sneakers' || !visible) {
      P.table.setMode(P.shoe, 0);
      return;
    }
    const p = this.worldOf(s.pos, _w);
    this.env.probeAt(p, _probe);
    P.table.setMatrix(P.shoe, _m.makeRotationY(this.yawOf(s.yaw)).setPosition(p));
    P.table.setLight(P.shoe, _probe.r, _probe.g, _probe.b, 2);
  }

  /**
   * The Creature as the Monster actor, on the tick: placed along its track, its clip's actions when the clip changes
   * (a clip's start in the Creature's clock is now - clipTime, so a late page joins it where it is).
   * @param {import('../creatureApi.js').ScriptedHandle|null} handle
   * @param {any} s the actor's sample
   * @param {number} now the game clock
   */
  tickMonster(handle, s, now) {
    if (!handle || !s) return;
    const state = this.monster || (this.monster = { clip: null, hidden: null });
    const hidden = !s.visible;
    if (hidden !== state.hidden) {
      handle.setHidden(hidden);
      state.hidden = hidden;
    }
    const p = this.worldOf(s.pos, _w);
    const yaw = this.yawOf(s.yaw);
    _m.makeRotationY(yaw).setPosition(p.x, p.y + CreatureMetrics.rootHeight, p.z);
    handle.teleport(_m.clone());
    if (s.clip === state.clip) return;
    const previous = state.clip;
    state.clip = s.clip;
    const startAt = now - s.clipTime;
    if (previous === 'Stare' || previous === 'Hunch') handle.stopAction('Stare');
    if (previous === 'ReachIn') handle.stopAction('ReachIn');
    if (previous === 'Unfold') handle.stopAction('FadeIn');
    if (previous === 'Hunch') handle.setPose('Biped');
    // ReachIn and Hunch reach for, and bring the mask down to, the gap of the bin this page's player hides in (the
    // authority's: slot 0, Dumpster A, the shot the squad shares); every other clip stares at nobody
    handle.setTarget(s.clip === 'ReachIn' || s.clip === 'Hunch' ? true : null);
    if (s.clip === 'Unfold') {
      handle.setPose('Biped');
      handle.action('FadeIn', startAt, s.rate);
    } else if (s.clip === 'Stare') handle.action('Stare', startAt);
    else if (s.clip === 'ReachIn') handle.action('ReachIn', startAt);
    else if (s.clip === 'Hunch') {
      handle.setPose('Hunched');
      handle.action('Stare', startAt);
    }
  }

  dispose() {
    for (const actor of this.list.values()) if (actor.body) actor.body.dispose();
    this.list.clear();
    if (this.bodyBatch) this.bodyBatch.table.flush();
    if (this.props) {
      const total = 1 + this.props.legs * this.props.segments + 1;
      for (let i = 0; i < total; i++) this.props.table.setMode(i, 0);
      this.props.table.flush();
    }
    this.monster = null;
  }
}

