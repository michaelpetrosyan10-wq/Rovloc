// flaskFx.js: what the chemical flasks look like away from the world props (ChemicalThrowController's cosmetics and
// ChemicalFlaskBuilder.buildVisual): the flask carried in the hand and tumbling
// through the air, the dotted aim arc with its impact ring, and a shatter's glass shards, liquid splash, puddle and
// lingering cloud with its coloured glow. Plain three.js objects in the world scene (the held flask rides the
// first-person hand); lit by the baked light probe where they are, except what glows (the Neon liquid, the arc, the
// gas).
//
// The models are the builders' own, part for part (sizes and frames in flask space: origin on the resting point, Y up).
// A chemical flask's look (fill line, crack) comes from flaskLook: ChemicalFlaskBuilder.lookOf drawn in the builder's
// order from its stream on the world's generator (Rng), so the flask in a hand is the one the world built for that
// variant, on either platform.

import * as THREE from 'three';
import { S } from '../strings/index.js';
import { Fonts } from '../ui/style.js';
import { Rng, clamp01, seededRandom, smoothstep } from '../util.js';

const DEG = Math.PI / 180; // Luau's math.rad factor

// ChemicalFlaskBuilder (flask space: origin on the resting point, Y up, the tag facing +Z)
const FOOT_DIAMETER = 0.28;
const FOOT_HEIGHT = 0.035;
const BULB_DIAMETER = 0.66;
const BULB_RADIUS = BULB_DIAMETER / 2;
const BULB_Y = 0.01 + BULB_RADIUS;
const GLASS_WALL = 0.03;
const NECK_DIAMETER = 0.17;
const NECK_BOTTOM = BULB_Y + 0.28;
const NECK_TOP = 0.97;
const LIP_DIAMETER = 0.215;
const LIP_HEIGHT = 0.035;
const LIP_TOP = NECK_TOP + 0.02;
const PLUG_DIAMETER = 0.14;
const PLUG_BOTTOM = 0.9;
const CAP_DIAMETER = 0.19;
const CAP_HEIGHT = 0.08;
const LIQUID_TIERS = 3;
const LIQUID_BOTTOM = -0.92;
const LIQUID_MARGIN = 0.006;
const FILL_MIN = -0.35;
const FILL_MAX = 0.3;
const TIE_Y = 0.71;
const TIE_HEIGHT = 0.025;
const TIE_DIAMETER = NECK_DIAMETER + 0.012;
const TAG_SIZE = [0.2, 0.13, 0.012];
const TAG_ELEVATION = 46 * DEG;
const STRING_THICK = 0.012;
const CRACK_CHANCE = 0.4;
const CRACK_DEPTH = 0.008;
const CRACK_SIZE = [0.006, 0.014];
export const GripY = 0.8;
export const FlaskCentreY = 0.45;

const LIQUID_COLORS = [[118, 212, 52], [212, 202, 40], [150, 64, 214]];
const rgb = (r, g, b) => new THREE.Color(r / 255, g / 255, b / 255);
const GLASS_COLOR = rgb(206, 222, 216); // glass as the hand sees it (unlit, see-through)
const RUBBER_COLOR = new THREE.Color(0.16, 0.14, 0.13);
const TWINE_COLOR = rgb(96, 84, 60);
const TAG_COLOR = rgb(148, 132, 86);
const TAG_TEXT_COLOR = 'rgb(92,24,18)';
const CRACK_COLOR = rgb(172, 180, 174);

// shatter (ChemicalThrowController)
const SHARD_COUNT = 10;
const SHARD_LIFE = 1.2;
const SHARD_FADE = 0.45;
const SHARD_GRAVITY = 70;
const SPLASH_COUNT = 28;
const SPLASH_SECONDS = 1.2;
const CLOUD_RATE = 22;
const CLOUD_GOUT = 26;
const CLOUD_TAIL = 2.6;
const CLOUD_LIFE_MIN = 2.2;
const CLOUD_LIFE_MAX = 3.4;
const CLOUD_LIGHT_RANGE = 14;
const CLOUD_LIGHT_BRIGHTNESS = 1.6;
const GLOW_RISE = 0.15;
const GLOW_FADE = 1.6;
const PUDDLE_DIAMETER = 2.6;
const PUDDLE_SPREAD = 0.45;
const PUDDLE_LINGER = 3;
const FLOOR_NORMAL_Y = 0.7;
const ARC_DOT_SIZE = 0.13;
const ARC_OPACITY = 0.45;
const RING_DIAMETER = 1.3;
const RING_THICKNESS = 0.03;
const MAX_CLOUD_PARTICLES = 160;
const CLOUD_ALPHA = 0.42; // a puff's peak opacity (the built-in smoke texture's density)

/** A variant as a whole number (ChemicalFlaskBuilder.wholeVariant: 0 for NaN or an infinity). */
function wholeVariant(variant) {
  return Number.isFinite(variant) ? Math.floor(variant) : 0;
}

/** ChemicalFlaskBuilder.liquidColor (0..1 RGB). */
export function liquidColor(variant) {
  const c = LIQUID_COLORS[((wholeVariant(variant) % 3) + 3) % 3];
  return new THREE.Color(c[0] / 255, c[1] / 255, c[2] / 255);
}

/**
 * ChemicalFlaskBuilder.lookOf: the fill line (bulb inner radii from its centre) and the crack of a flask variant. Every
 * draw is made, in the builder's order, from its stream Rng.seeded(variant, "ChemicalFlask:look").
 */
export function flaskLook(variant) {
  const random = Rng.seeded(wholeVariant(variant), 'ChemicalFlask:look');
  const fill = random.number(FILL_MIN, FILL_MAX);
  const cracked = random.next() < CRACK_CHANCE;
  return {
    fill,
    cracked,
    crackAzimuth: random.number(120 * DEG, 240 * DEG), // round the back, away from the tag
    crackElevation: random.number(-25 * DEG, 25 * DEG),
    crackRoll: random.number(0, Math.PI),
    crackLength: random.number(0.14, 0.22),
  };
}

/**
 * A look's liquid (ChemicalFlaskBuilder.buildLiquid): three flat tiers [y0, y1, diameter] in flask space stepped up the
 * bulb to the fill line, each touching the inner wall at its further end less a margin.
 */
export function liquidTiers(look) {
  const inner = BULB_RADIUS - GLASS_WALL;
  const bottom = LIQUID_BOTTOM * inner;
  const surface = look.fill * inner;
  const out = [];
  for (let i = 1; i <= LIQUID_TIERS; i++) {
    const y0 = bottom + ((surface - bottom) * (i - 1)) / LIQUID_TIERS;
    const y1 = bottom + ((surface - bottom) * i) / LIQUID_TIERS;
    const reach = Math.max(Math.abs(y0), Math.abs(y1));
    const radius = Math.sqrt(Math.max(0, inner * inner - reach * reach)) - LIQUID_MARGIN;
    out.push([BULB_Y + y0, BULB_Y + y1, radius * 2]);
  }
  return out;
}

/**
 * A cracked look's crack (ChemicalFlaskBuilder.buildCrack): its frame in flask space (CFrame.fromMatrix: X along the
 * crack, Y out of the bulb) and its size.
 */
export function crackFrame(look) {
  const az = look.crackAzimuth;
  const el = look.crackElevation;
  const outward = new THREE.Vector3(Math.sin(az) * Math.cos(el), Math.sin(el), Math.cos(az) * Math.cos(el));
  const east = new THREE.Vector3(Math.cos(az), 0, -Math.sin(az));
  const north = outward.clone().cross(east);
  const along = east.clone().multiplyScalar(Math.cos(look.crackRoll)).addScaledVector(north, Math.sin(look.crackRoll));
  const position = new THREE.Vector3(0, BULB_Y, 0).addScaledVector(outward, BULB_RADIUS - CRACK_DEPTH);
  const frame = new THREE.Matrix4().makeBasis(along, outward, along.clone().cross(outward)).setPosition(position);
  return { frame, size: [look.crackLength, CRACK_SIZE[0], CRACK_SIZE[1]] };
}

/** The cloud's emission rate (particles/s) `age` into a cloud lasting `seconds` (ChemicalThrowController.cloudRate). */
export function cloudRate(age, seconds, inVent) {
  const stopAt = Math.max(seconds - CLOUD_TAIL, 0);
  if (age < 0 || age >= stopAt) return 0;
  const remaining = 1 - age / Math.max(stopAt, 1e-3);
  const rate = CLOUD_RATE * (0.35 + 0.65 * remaining);
  return inVent ? rate * 0.6 : rate;
}

/** The cloud glow 0..1 `age` into a cloud lasting `seconds`: up at once, out over its last GLOW_FADE. */
export function cloudGlow(age, seconds) {
  if (age < 0 || age >= seconds) return 0;
  return Math.min(clamp01(age / GLOW_RISE), clamp01((seconds - age) / GLOW_FADE));
}

/** Opacity of something `age` into a `life`, fading over its last `fade` seconds. */
export function fadeAlpha(age, life, fade) {
  if (age >= life) return 0;
  return clamp01((life - age) / Math.max(fade, 1e-3));
}

// ---------------------------------------------------------------------------------------------------------------
// The flask models
// ---------------------------------------------------------------------------------------------------------------

/** A builder's `upright`: a cylinder on the flask's axis from height y0 to y1. */
function upright(diameter, y0, y1, segments = 16) {
  const g = new THREE.CylinderGeometry(diameter / 2, diameter / 2, Math.max(1e-3, y1 - y0), segments);
  g.translate(0, (y0 + y1) / 2, 0);
  return g;
}

/** A block of `size` at a flask-space frame (Matrix4). */
function block(size, frame) {
  return new THREE.BoxGeometry(size[0], size[1], size[2]).applyMatrix4(frame);
}

const LABEL_WIDTH = 256;
const labelTextures = new Map();

/**
 * The print on a tag's Front face (a SurfaceGui TextLabel inset 5% / 8%, TextScaled and TextWrapped): `text` in the
 * condensed caps the builders print tags in, on a transparent canvas of the face's aspect. One texture per text.
 */
function labelTexture(text, color, aspect) {
  const key = `${text}|${color}|${aspect.toFixed(3)}`;
  const cached = labelTextures.get(key);
  if (cached) return cached;
  const canvas = document.createElement('canvas');
  canvas.width = LABEL_WIDTH;
  canvas.height = Math.round(LABEL_WIDTH / aspect);
  const ctx = canvas.getContext('2d');
  const boxW = canvas.width * 0.9;
  const boxH = canvas.height * 0.84;
  const words = text.split(' ');
  // one line, or wrapped at the space that balances two lines best: whichever lets the text stand larger
  const layouts = [[text]];
  if (words.length > 1) {
    let best = null;
    for (let i = 1; i < words.length; i++) {
      const lines = [words.slice(0, i).join(' '), words.slice(i).join(' ')];
      const longest = Math.max(lines[0].length, lines[1].length);
      if (!best || longest < best.longest) best = { lines, longest };
    }
    layouts.push(best.lines);
  }
  let chosen = layouts[0];
  let size = 0;
  for (const lines of layouts) {
    ctx.font = `600 100px ${Fonts.Strong}`;
    const widest = Math.max(...lines.map((l) => ctx.measureText(l).width));
    const fit = Math.min((100 * boxW) / Math.max(widest, 1), boxH / (lines.length * 1.05));
    if (fit > size) {
      size = fit;
      chosen = lines;
    }
  }
  ctx.font = `600 ${size}px ${Fonts.Strong}`;
  ctx.fillStyle = color;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  const lineH = size * 1.05;
  const top = canvas.height / 2 - (lineH * chosen.length) / 2 + lineH / 2;
  chosen.forEach((line, i) => ctx.fillText(line, canvas.width / 2, top + i * lineH));
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.NoColorSpace; // raw bytes, as the engine takes every colour
  labelTextures.set(key, texture);
  return texture;
}

/** The label quad on the Front (-Z) face of a tag block of `size` at `frame`, reading left to right from the front. */
function frontLabel(size, frame) {
  return new THREE.PlaneGeometry(size[0] * 0.98, size[1] * 0.98)
    .rotateY(Math.PI)
    .translate(0, 0, -(size[2] / 2 + 0.0015))
    .applyMatrix4(frame);
}

/** What both held flasks share: their materials (unlit, shaded by the probe where they are), meshes and disposal. */
class HeldFlask {
  constructor(name, liquid, rubber, tag, text, aspect) {
    this.group = new THREE.Group();
    this.group.name = name;
    this.liquid = liquid.clone();
    this.rubberColor = rubber.clone();
    this.tagColor = tag.clone();
    this.glass = new THREE.MeshBasicMaterial({ color: GLASS_COLOR.clone(), transparent: true, opacity: 0.38, depthWrite: false });
    this.thick = new THREE.MeshBasicMaterial({ color: GLASS_COLOR.clone(), transparent: true, opacity: 0.6 });
    this.rubber = new THREE.MeshBasicMaterial({ color: rubber.clone() });
    this.twine = new THREE.MeshBasicMaterial({ color: TWINE_COLOR.clone() });
    this.tag = new THREE.MeshBasicMaterial({ color: tag.clone() });
    this.print = new THREE.MeshBasicMaterial({ map: labelTexture(text.value, text.color, aspect), transparent: true, depthWrite: false });
    this.crack = new THREE.MeshBasicMaterial({ color: CRACK_COLOR.clone(), transparent: true, opacity: 0.7, depthWrite: false });
    this.neon = new THREE.MeshBasicMaterial({ color: this.liquid.clone() });
  }

  /** Adds the meshes: [geometry, material] pairs; the glass draws after the liquid it holds. */
  _add(parts) {
    for (const [g, m] of parts) {
      const mesh = new THREE.Mesh(g, m);
      mesh.frustumCulled = false;
      mesh.renderOrder = m === this.glass || m === this.crack ? 2 : m === this.neon ? 1 : 0;
      this.group.add(mesh);
    }
  }

  /** Shades the unlit parts by the probe irradiance where the flask is. @param {THREE.Color} probe */
  setLight(probe) {
    const k = Math.min(1.4, 0.25 + (probe.r + probe.g + probe.b) * 0.9);
    this.glass.color.copy(GLASS_COLOR).multiplyScalar(k);
    this.thick.color.copy(GLASS_COLOR).multiplyScalar(k);
    this.rubber.color.copy(this.rubberColor).multiplyScalar(Math.max(0.4, k));
    this.twine.color.copy(TWINE_COLOR).multiplyScalar(k);
    this.tag.color.copy(this.tagColor).multiplyScalar(k);
    this.print.color.setScalar(Math.min(1, k));
    this.crack.color.copy(CRACK_COLOR).multiplyScalar(k);
  }

  dispose() {
    this.group.traverse((o) => {
      if (o.geometry) o.geometry.dispose();
    });
    for (const m of [this.glass, this.thick, this.rubber, this.twine, this.tag, this.print, this.crack, this.neon]) m.dispose();
  }
}

/**
 * A chemical flask of `variant` (ChemicalFlaskBuilder.buildVisual, part for part): the glass foot, bulb, neck and lip,
 * the two-step stopper, the glowing liquid's three tiers up to the variant's fill line, the twine tie with the string
 * down to the hazard tag on the bulb's shoulder (printed "DANGER: CORROSIVE"), and the variant's hairline crack round
 * the back when it has one. setLight(probe) shades the unlit parts.
 */
export class FlaskModel extends HeldFlask {
  constructor(variant) {
    super('Flask', liquidColor(variant), RUBBER_COLOR, TAG_COLOR, { value: S('Prop.Lab.Hazard'), color: TAG_TEXT_COLOR },
      TAG_SIZE[0] / TAG_SIZE[1]);
    const look = flaskLook(variant);
    const parts = liquidTiers(look).map(([y0, y1, d]) => [upright(d, y0, y1, 14), this.neon]);
    parts.push(
      [upright(FOOT_DIAMETER, 0, FOOT_HEIGHT), this.thick],
      [new THREE.SphereGeometry(BULB_RADIUS, 18, 12).translate(0, BULB_Y, 0), this.glass],
      [upright(NECK_DIAMETER, NECK_BOTTOM, NECK_TOP, 14), this.glass],
      [upright(LIP_DIAMETER, LIP_TOP - LIP_HEIGHT, LIP_TOP, 14), this.thick],
      [upright(PLUG_DIAMETER, PLUG_BOTTOM, LIP_TOP, 12), this.rubber],
      [upright(CAP_DIAMETER, LIP_TOP, LIP_TOP + CAP_HEIGHT, 14), this.rubber],
      [upright(TIE_DIAMETER, TIE_Y - TIE_HEIGHT / 2, TIE_Y + TIE_HEIGHT / 2, 14), this.twine],
    );
    // the tag hangs against the bulb's shoulder: its Front (-Z) out along the surface normal, +Y up the slope
    const normal = new THREE.Vector3(0, Math.sin(TAG_ELEVATION), Math.cos(TAG_ELEVATION));
    const upSlope = new THREE.Vector3(0, Math.cos(TAG_ELEVATION), -Math.sin(TAG_ELEVATION));
    const centre = new THREE.Vector3(0, BULB_Y, 0).addScaledVector(normal, BULB_RADIUS + TAG_SIZE[2] / 2 + 0.004);
    const right = new THREE.Vector3(-1, 0, 0);
    const tagFrame = new THREE.Matrix4().makeBasis(right, upSlope, right.clone().cross(upSlope)).setPosition(centre);
    parts.push([block(TAG_SIZE, tagFrame), this.tag], [frontLabel(TAG_SIZE, tagFrame), this.print]);
    const tagTop = centre.clone().addScaledVector(upSlope, TAG_SIZE[1] / 2);
    const knot = new THREE.Vector3(0, TIE_Y, TIE_DIAMETER / 2);
    const mid = knot.clone().add(tagTop).multiplyScalar(0.5);
    const stringFrame = new THREE.Matrix4().lookAt(mid, tagTop, new THREE.Vector3(0, 1, 0)).setPosition(mid);
    parts.push([block([STRING_THICK, STRING_THICK, tagTop.distanceTo(knot)], stringFrame), this.twine]);
    if (look.cracked) {
      const crack = crackFrame(look);
      parts.push([block(crack.size, crack.frame), this.crack]);
    }
    this._add(parts);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Billboard particles (the splash, the gas): camera-facing quads sized in studs
// ---------------------------------------------------------------------------------------------------------------

let softTexture = null;
function soft() {
  if (softTexture) return softTexture;
  const c = document.createElement('canvas');
  c.width = c.height = 64;
  const g = c.getContext('2d');
  const grad = g.createRadialGradient(32, 32, 0, 32, 32, 32);
  grad.addColorStop(0, 'rgba(255,255,255,1)');
  grad.addColorStop(0.45, 'rgba(255,255,255,0.55)');
  grad.addColorStop(1, 'rgba(255,255,255,0)');
  g.fillStyle = grad;
  g.fillRect(0, 0, 64, 64);
  softTexture = new THREE.CanvasTexture(c);
  return softTexture;
}

const BILLBOARD_VERT = /* glsl */ `
attribute vec4 aInst;
attribute float aAlpha;
varying vec2 vUv;
varying float vAlpha;
void main() {
  vec3 right = vec3(viewMatrix[0][0], viewMatrix[1][0], viewMatrix[2][0]);
  vec3 up = vec3(viewMatrix[0][1], viewMatrix[1][1], viewMatrix[2][1]);
  vec3 p = aInst.xyz + (right * position.x + up * position.y) * aInst.w;
  vUv = uv;
  vAlpha = aAlpha;
  gl_Position = projectionMatrix * viewMatrix * vec4(p, 1.0);
}`;
const BILLBOARD_FRAG = /* glsl */ `
uniform sampler2D uMap;
uniform vec3 uColor;
varying vec2 vUv;
varying float vAlpha;
void main() {
  float a = texture2D(uMap, vUv).a * vAlpha;
  if (a < 0.004) discard;
  gl_FragColor = vec4(uColor, a);
}`;

export class Billboards {
  constructor(capacity, color, additive) {
    const geo = new THREE.InstancedBufferGeometry();
    const quad = new THREE.PlaneGeometry(1, 1);
    geo.index = quad.index;
    geo.setAttribute('position', quad.getAttribute('position'));
    geo.setAttribute('uv', quad.getAttribute('uv'));
    this.inst = new THREE.InstancedBufferAttribute(new Float32Array(capacity * 4), 4).setUsage(THREE.DynamicDrawUsage);
    this.alpha = new THREE.InstancedBufferAttribute(new Float32Array(capacity), 1).setUsage(THREE.DynamicDrawUsage);
    geo.setAttribute('aInst', this.inst);
    geo.setAttribute('aAlpha', this.alpha);
    geo.instanceCount = 0;
    this.material = new THREE.ShaderMaterial({
      vertexShader: BILLBOARD_VERT,
      fragmentShader: BILLBOARD_FRAG,
      uniforms: { uMap: { value: soft() }, uColor: { value: color.clone() } },
      transparent: true,
      depthWrite: false,
      blending: additive ? THREE.AdditiveBlending : THREE.NormalBlending,
    });
    this.mesh = new THREE.Mesh(geo, this.material);
    this.mesh.frustumCulled = false;
    this.mesh.renderOrder = 5;
    this.capacity = capacity;
  }

  /** Writes particle i (centre, size in studs, alpha). */
  set(i, p, size, alpha) {
    this.inst.setXYZW(i, p.x, p.y, p.z, size);
    this.alpha.setX(i, alpha);
  }

  commit(count) {
    this.mesh.geometry.instanceCount = count;
    this.inst.needsUpdate = true;
    this.alpha.needsUpdate = true;
  }

  dispose() {
    this.mesh.geometry.dispose();
    this.material.dispose();
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------------------------------------------

/** Every running flask effect; step(dt, now) advances them and drops the finished ones. */
export class FlaskEffects {
  /** @param {import('../env.js').Env} env */
  constructor(env) {
    this.env = env;
    /** @type {Array<{step: (dt: number, now: number) => boolean, dispose: () => void}>} */
    this.effects = [];
    this.random = seededRandom(7, 'FlaskFx');
    this.probe = new THREE.Color();
    this.arc = null;
  }

  _add(effect) {
    this.effects.push(effect);
  }

  /**
   * A shatter at `point` (surface `normal`): shards and a splash at once, a puddle on a floor, the cloud at `centre`
   * for `seconds` (smaller and slower inside a duct) with its coloured glow.
   */
  shatter(point, normal, centre, color, seconds, inVent) {
    const now = this.env.realNow();
    this.env.probeAt(point, this.probe);
    this._shards(point, normal, now);
    this._splash(point, normal, color, now);
    if (normal.y >= FLOOR_NORMAL_Y && !inVent) this._puddle(point, normal, color, seconds, now);
    this._cloud(centre, color, seconds, inVent, now);
  }

  _shards(point, normal, born) {
    const env = this.env;
    const r = this.random;
    const k = Math.min(1.3, 0.3 + (this.probe.r + this.probe.g + this.probe.b) * 0.9);
    const material = new THREE.MeshBasicMaterial({ color: GLASS_COLOR.clone().multiplyScalar(k), transparent: true, opacity: 0.85 });
    const group = new THREE.Group();
    const shards = [];
    const floor = env.raycast(_v.copy(point).addScaledVector(normal, 0.2), _down, 12, { ignoreEntities: true });
    const floorY = floor ? floor.point.y + 0.02 : point.y - 6;
    for (let i = 0; i < SHARD_COUNT; i++) {
      const g = new THREE.BoxGeometry(r.number(0.05, 0.14), 0.012, r.number(0.04, 0.11));
      const mesh = new THREE.Mesh(g, material);
      mesh.frustumCulled = false;
      mesh.position.copy(point).addScaledVector(normal, 0.05);
      const dir = new THREE.Vector3(r.number(-1, 1), r.number(-1, 1), r.number(-1, 1)).normalize();
      if (dir.dot(normal) < 0) dir.addScaledVector(normal, -2 * dir.dot(normal));
      dir.addScaledVector(normal, 0.6).normalize();
      group.add(mesh);
      shards.push({ mesh, velocity: dir.multiplyScalar(r.number(7, 16)), spin: new THREE.Vector3(r.number(-14, 14), r.number(-14, 14), r.number(-14, 14)), settled: false });
    }
    env.addToScene(group);
    this._add({
      step: (dt, now) => {
        const age = now - born;
        if (age >= SHARD_LIFE) return false;
        for (const s of shards) {
          if (s.settled) continue;
          s.velocity.y -= SHARD_GRAVITY * dt;
          s.mesh.position.addScaledVector(s.velocity, dt);
          s.mesh.rotation.x += s.spin.x * dt;
          s.mesh.rotation.y += s.spin.y * dt;
          s.mesh.rotation.z += s.spin.z * dt;
          if (s.mesh.position.y <= floorY) {
            s.mesh.position.y = floorY;
            s.mesh.rotation.set(0, s.mesh.rotation.y, 0);
            s.settled = true;
          }
        }
        material.opacity = 0.85 * fadeAlpha(age, SHARD_LIFE, SHARD_FADE);
        return true;
      },
      dispose: () => {
        env.removeFromScene(group);
        group.traverse((o) => o.geometry && o.geometry.dispose());
        material.dispose();
      },
    });
  }

  _splash(point, normal, color, born) {
    const env = this.env;
    const r = this.random;
    const drops = new Billboards(SPLASH_COUNT, color.clone().multiplyScalar(0.9), false);
    const list = [];
    for (let i = 0; i < SPLASH_COUNT; i++) {
      const dir = new THREE.Vector3(r.number(-1, 1), r.number(-0.2, 1), r.number(-1, 1)).normalize().addScaledVector(normal, 0.8).normalize();
      list.push({ p: point.clone().addScaledVector(normal, 0.1), v: dir.multiplyScalar(r.number(4, 12)), size: r.number(0.12, 0.3) });
    }
    env.addToScene(drops.mesh);
    this._add({
      step: (dt, now) => {
        const age = now - born;
        if (age >= SPLASH_SECONDS) return false;
        const alpha = 0.9 * fadeAlpha(age, SPLASH_SECONDS, 0.5);
        list.forEach((d, i) => {
          d.v.y -= 40 * dt;
          d.p.addScaledVector(d.v, dt);
          drops.set(i, d.p, d.size, alpha);
        });
        drops.commit(list.length);
        return true;
      },
      dispose: () => {
        env.removeFromScene(drops.mesh);
        drops.dispose();
      },
    });
  }

  _puddle(point, normal, color, seconds, born) {
    const env = this.env;
    const material = new THREE.MeshBasicMaterial({ color: color.clone().multiplyScalar(0.45), transparent: true, opacity: 0.75,
      depthWrite: false, polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -2 });
    const mesh = new THREE.Mesh(new THREE.CircleGeometry(PUDDLE_DIAMETER / 2, 20), material);
    mesh.frustumCulled = false;
    mesh.position.copy(point).addScaledVector(normal, 0.02);
    mesh.quaternion.setFromUnitVectors(_z, normal);
    mesh.scale.setScalar(0.01);
    env.addToScene(mesh);
    const life = seconds + PUDDLE_LINGER;
    this._add({
      step: (dt, now) => {
        const age = now - born;
        if (age >= life) return false;
        mesh.scale.setScalar(Math.max(0.01, smoothstep(0, PUDDLE_SPREAD, age)));
        material.opacity = 0.75 * fadeAlpha(age, life, 1);
        return true;
      },
      dispose: () => {
        env.removeFromScene(mesh);
        mesh.geometry.dispose();
        material.dispose();
      },
    });
  }

  _cloud(centre, color, seconds, inVent, born) {
    const env = this.env;
    const r = this.random;
    const gas = new Billboards(MAX_CLOUD_PARTICLES, color.clone().multiplyScalar(0.78), false);
    const glow = env.addLight({ position: centre.clone(), color: [color.r, color.g, color.b], brightness: 0, range: CLOUD_LIGHT_RANGE });
    const scale = inVent ? 0.45 : 1;
    const puffs = [];
    let owed = CLOUD_GOUT;
    let last = born;
    env.addToScene(gas.mesh);
    const emit = (now) => {
      if (puffs.length >= MAX_CLOUD_PARTICLES) return;
      const spread = 1.2 * scale;
      puffs.push({
        p: centre.clone().add(_v.set(r.number(-spread, spread), r.number(-0.3, 0.6) * scale, r.number(-spread, spread))),
        v: new THREE.Vector3(r.number(-1.4, 1.4) * scale, r.number(0.3, 1.2) * scale, r.number(-1.4, 1.4) * scale),
        born: now,
        life: r.number(CLOUD_LIFE_MIN, CLOUD_LIFE_MAX),
        size0: r.number(1.6, 2.6) * scale,
        size1: r.number(4.5, 7) * scale,
      });
    };
    this._add({
      step: (dt, now) => {
        const age = now - born;
        owed += cloudRate(age, seconds, inVent) * Math.max(0, now - last);
        last = now;
        while (owed >= 1) {
          emit(now);
          owed -= 1;
        }
        let n = 0;
        for (let i = puffs.length - 1; i >= 0; i--) {
          const q = puffs[i];
          const t = (now - q.born) / q.life;
          if (t >= 1) {
            puffs.splice(i, 1);
            continue;
          }
          q.p.addScaledVector(q.v, dt);
          q.v.multiplyScalar(Math.exp(-0.6 * dt));
        }
        for (const q of puffs) {
          const t = (now - q.born) / q.life;
          const alpha = CLOUD_ALPHA * smoothstep(0, 0.15, t) * (1 - smoothstep(0.55, 1, t));
          gas.set(n++, q.p, q.size0 + (q.size1 - q.size0) * Math.sqrt(t), alpha);
        }
        gas.commit(n);
        glow.set({ brightness: CLOUD_LIGHT_BRIGHTNESS * cloudGlow(age, seconds) });
        return age < seconds || puffs.length > 0;
      },
      dispose: () => {
        env.removeFromScene(gas.mesh);
        gas.dispose();
        glow.remove();
      },
    });
  }

  // ------------------------------------------------------------------------------------------------- the aim arc

  /** Shows the aim arc through `dots` (evenly spaced points) and the impact ring at `hit` (null: none), at `alpha`. */
  showArc(dots, hit, color, alpha) {
    if (!this.arc) this.arc = this._buildArc();
    const arc = this.arc;
    arc.dotMaterial.color.copy(color);
    arc.ringMaterial.color.copy(color);
    arc.dotMaterial.opacity = ARC_OPACITY * alpha;
    arc.ringMaterial.opacity = ARC_OPACITY * alpha;
    arc.group.visible = alpha > 0.001;
    arc.dots.forEach((m, i) => {
      const p = dots[i];
      m.visible = !!p && i > 0;
      if (p) m.position.copy(p);
    });
    arc.ring.visible = !!hit;
    if (hit) {
      arc.ring.position.copy(hit.position).addScaledVector(hit.normal, 0.05);
      arc.ring.quaternion.setFromUnitVectors(_z, hit.normal);
    }
  }

  hideArc() {
    if (this.arc) this.arc.group.visible = false;
  }

  _buildArc() {
    const group = new THREE.Group();
    const dotMaterial = new THREE.MeshBasicMaterial({ transparent: true, depthWrite: false });
    const ringMaterial = new THREE.MeshBasicMaterial({ transparent: true, depthWrite: false, side: THREE.DoubleSide });
    const dotGeo = new THREE.SphereGeometry(ARC_DOT_SIZE / 2, 8, 6);
    const dots = [];
    for (let i = 0; i < 14; i++) {
      const m = new THREE.Mesh(dotGeo, dotMaterial);
      m.frustumCulled = false;
      group.add(m);
      dots.push(m);
    }
    const ring = new THREE.Mesh(new THREE.RingGeometry(RING_DIAMETER / 2 - RING_THICKNESS * 1.5, RING_DIAMETER / 2, 32), ringMaterial);
    ring.frustumCulled = false;
    group.add(ring);
    group.visible = false;
    this.env.addToScene(group);
    return { group, dots, ring, dotMaterial, ringMaterial };
  }

  step(dt) {
    const now = this.env.realNow();
    for (let i = this.effects.length - 1; i >= 0; i--) {
      const e = this.effects[i];
      let alive = false;
      try {
        alive = e.step(dt, now);
      } catch (err) {
        console.error('[game] flask effect failed', err);
      }
      if (!alive) {
        e.dispose();
        this.effects.splice(i, 1);
      }
    }
  }

  /** Ends every effect at once (the run's end). */
  clear() {
    for (const e of this.effects) e.dispose();
    this.effects.length = 0;
    this.hideArc();
  }
}

const _v = new THREE.Vector3();
const _z = new THREE.Vector3(0, 0, 1);
const _down = new THREE.Vector3(0, -1, 0);
