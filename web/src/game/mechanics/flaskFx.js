// flaskFx.js: what the chemical flasks look like away from the world props (ChemicalThrowController's cosmetics and
// ChemicalFlaskBuilder.buildVisual): the flask carried in the hand and tumbling through the air, the dotted aim arc
// with its impact ring, and a shatter's glass shards, liquid splash, puddle and lingering cloud with its coloured
// glow. Plain three.js objects in the world scene (the held flask rides the first-person hand); lit by the baked
// light probe where they are, except what glows (the Neon liquid, the arc, the gas).

import * as THREE from 'three';
import { clamp01, seededRandom, smoothstep } from '../util.js';

// ChemicalFlaskBuilder dimensions (flask space: origin on the resting point, Y up)
const FOOT_DIAMETER = 0.28;
const FOOT_HEIGHT = 0.035;
const BULB_RADIUS = 0.33;
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
const LIQUID_BOTTOM = -0.92;
const FILL_MIN = -0.35;
const FILL_MAX = 0.3;
export const GripY = 0.8;
export const FlaskCentreY = 0.45;

const LIQUID_COLORS = [[118, 212, 52], [212, 202, 40], [150, 64, 214]];
const GLASS_COLOR = new THREE.Color(206 / 255, 222 / 255, 216 / 255);
const RUBBER_COLOR = new THREE.Color(0.16, 0.14, 0.13);
const TWINE_COLOR = new THREE.Color(96 / 255, 84 / 255, 60 / 255);
const TAG_COLOR = new THREE.Color(148 / 255, 132 / 255, 86 / 255);

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

/** ChemicalFlaskBuilder.liquidColor (0..1 RGB). */
export function liquidColor(variant) {
  const v = Number.isFinite(variant) ? Math.floor(variant) : 0;
  const c = LIQUID_COLORS[((v % 3) + 3) % 3];
  return new THREE.Color(c[0] / 255, c[1] / 255, c[2] / 255);
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
// The flask model
// ---------------------------------------------------------------------------------------------------------------

function upright(diameter, y0, y1, segments = 16) {
  const g = new THREE.CylinderGeometry(diameter / 2, diameter / 2, Math.max(1e-3, y1 - y0), segments);
  g.translate(0, (y0 + y1) / 2, 0);
  return g;
}

/**
 * A flask of `variant` (ChemicalFlaskBuilder.buildVisual): glass bulb on its foot, neck and lip, the two-step stopper,
 * the glowing liquid up to its fill line, the twine tie and hazard tag. setLight(probe) shades the unlit parts.
 */
export class FlaskModel {
  constructor(variant) {
    this.group = new THREE.Group();
    this.group.name = 'Flask';
    const look = seededRandom(Math.floor(variant) || 0, 'ChemicalFlask:look');
    const fill = look.number(FILL_MIN, FILL_MAX);
    this.liquid = liquidColor(variant);
    this.glass = new THREE.MeshBasicMaterial({ color: GLASS_COLOR.clone(), transparent: true, opacity: 0.38, depthWrite: false });
    this.thick = new THREE.MeshBasicMaterial({ color: GLASS_COLOR.clone(), transparent: true, opacity: 0.6 });
    this.rubber = new THREE.MeshBasicMaterial({ color: RUBBER_COLOR.clone() });
    this.twine = new THREE.MeshBasicMaterial({ color: TWINE_COLOR.clone() });
    this.tag = new THREE.MeshBasicMaterial({ color: TAG_COLOR.clone(), side: THREE.DoubleSide });
    this.neon = new THREE.MeshBasicMaterial({ color: this.liquid.clone() });
    const inner = BULB_RADIUS - GLASS_WALL;
    const surface = fill * inner;
    // liquid: the bulb's inner sphere from its bottom up to the surface, capped flat
    const theta0 = Math.acos(Math.min(1, Math.max(-1, surface / inner)));
    const bottomTheta = Math.acos(Math.max(-1, LIQUID_BOTTOM));
    const body = new THREE.SphereGeometry(inner * 0.98, 16, 10, 0, Math.PI * 2, theta0, bottomTheta - theta0);
    body.translate(0, BULB_Y, 0);
    const capRadius = Math.sqrt(Math.max(0, inner * inner - surface * surface)) * 0.98;
    const cap = new THREE.CircleGeometry(capRadius, 16).rotateX(-Math.PI / 2).translate(0, BULB_Y + surface, 0);
    const parts = [
      [body, this.neon], [cap, this.neon],
      [upright(FOOT_DIAMETER, 0, FOOT_HEIGHT), this.thick],
      [new THREE.SphereGeometry(BULB_RADIUS, 18, 12).translate(0, BULB_Y, 0), this.glass],
      [upright(NECK_DIAMETER, NECK_BOTTOM, NECK_TOP, 14), this.glass],
      [upright(LIP_DIAMETER, LIP_TOP - LIP_HEIGHT, LIP_TOP, 14), this.thick],
      [upright(PLUG_DIAMETER, PLUG_BOTTOM, LIP_TOP + 0.01, 12), this.rubber],
      [upright(CAP_DIAMETER, LIP_TOP + 0.01, LIP_TOP + 0.01 + CAP_HEIGHT, 14), this.rubber],
      [new THREE.TorusGeometry(NECK_DIAMETER / 2 + 0.012, 0.012, 5, 14).rotateX(Math.PI / 2).translate(0, 0.84, 0), this.twine],
      [new THREE.PlaneGeometry(0.16, 0.1).translate(0, 0.72, NECK_DIAMETER / 2 + 0.03), this.tag],
    ];
    for (const [g, m] of parts) {
      const mesh = new THREE.Mesh(g, m);
      mesh.frustumCulled = false;
      this.group.add(mesh);
    }
    // the glass draws after the liquid it holds
    this.group.children.forEach((m, i) => (m.renderOrder = m.material === this.glass ? 2 : i < 2 ? 1 : 0));
  }

  /** Shades the unlit parts by the probe irradiance where the flask is. @param {THREE.Color} probe */
  setLight(probe) {
    const k = Math.min(1.4, 0.25 + (probe.r + probe.g + probe.b) * 0.9);
    this.glass.color.copy(GLASS_COLOR).multiplyScalar(k);
    this.thick.color.copy(GLASS_COLOR).multiplyScalar(k);
    this.rubber.color.copy(RUBBER_COLOR).multiplyScalar(Math.max(0.4, k));
    this.twine.color.copy(TWINE_COLOR).multiplyScalar(k);
    this.tag.color.copy(TAG_COLOR).multiplyScalar(k);
  }

  dispose() {
    this.group.traverse((o) => {
      if (o.geometry) o.geometry.dispose();
    });
    for (const m of [this.glass, this.thick, this.rubber, this.twine, this.tag, this.neon]) m.dispose();
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Billboard particles (the splash, the gas, the pool bubbles): camera-facing quads sized in studs
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
  shatter(point, normal, centre, color, seconds, inVent, kind) {
    const now = this.env.realNow();
    this.env.probeAt(point, this.probe);
    this._shards(point, normal, now);
    this._splash(point, normal, color, now);
    if (kind !== 'Water' && normal.y >= FLOOR_NORMAL_Y && !inVent) this._puddle(point, normal, color, seconds, now);
    if (kind === 'Water') this._ripple(point, color, now);
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

  _ripple(point, color, born) {
    const env = this.env;
    const material = new THREE.MeshBasicMaterial({ color: color.clone().multiplyScalar(0.6), transparent: true, opacity: 0.5,
      depthWrite: false, side: THREE.DoubleSide });
    const mesh = new THREE.Mesh(new THREE.RingGeometry(0.85, 1, 28).rotateX(-Math.PI / 2), material);
    mesh.frustumCulled = false;
    mesh.position.copy(point).add(_v.set(0, 0.03, 0));
    env.addToScene(mesh);
    this._add({
      step: (dt, now) => {
        const age = now - born;
        if (age >= 1.4) return false;
        mesh.scale.setScalar(0.3 + age * 2.4);
        material.opacity = 0.5 * fadeAlpha(age, 1.4, 1);
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
