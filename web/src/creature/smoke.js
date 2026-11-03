// Smoke: the Creature's wisps. Cheap camera-facing puffs (one instanced draw call) that leave its smoke anchors
// (CreatureRigBuilder's Smoke* attachments: shoulders, elbows, fingertips, the back, the skull) and hang in the air
// behind it, so a moving Creature trails smoke; denser the faster it moves. The shroud's anchors (SmokeShroud: the
// chest, the flanks, the hips, the thighs) shed a tattered dark shroud from the shoulders down: bigger, denser puffs
// that sink and drag behind it. burst() throws a cloud off the whole body (the FadeOut / FadeIn). The puffs are
// near-black smoke that scatters the torch, the presence glow and the level probe (the engine's shared light
// uniforms), fogged and tone-mapped like the world. Max: dense, detailed wisps and a full shroud; Potato: a few plain
// puffs.

import * as THREE from 'three';

/** Per look tier (look.js LookTiers): how many puffs live at once, the emission scale, the puffs' noise detail. */
export const SmokeBudget = Object.freeze({
  Max: Object.freeze({ capacity: 300, rate: 2.2, shroud: 1, detail: true }),
  Potato: Object.freeze({ capacity: 14, rate: 0.3, shroud: 0.15, detail: false }),
});

const BASE_RATE = 3; // puffs per second standing still
const SPEED_RATE = 1.7; // more per stud per second of speed
const LIFE = [1.1, 1.9];
const SIZE_START = [0.16, 0.3];
const SIZE_END = [0.9, 1.5];
const ALPHA = 0.42;
const DRAG = 1.4;
const RISE = [0.25, 0.6];
const CARRY = 0.22; // share of the body's velocity a fresh puff keeps
const JITTER = 0.06;
const SHROUD_RATE = 11; // shroud puffs per second off the shroud anchors (x the budget's shroud share)
const SHROUD_SINK = [0.1, 0.35]; // the shroud's puffs sink this fast ...
const SHROUD_SIZE = 1.7; // ... and are this much bigger
const SHROUD_ALPHA = 1.5;
const SMOKE_ALBEDO = [0.11, 0.115, 0.13];

const VERT = /* glsl */ `
precision highp float;
in vec3 position;
in vec3 iPos;
in vec4 iParams; // size, alpha, seed, age 0..1
uniform mat4 viewMatrix;
uniform mat4 projectionMatrix;
uniform vec3 uFlPos;
uniform vec3 uFlDir;
uniform vec3 uFlInner;
uniform vec3 uFlOuter;
uniform vec4 uFlCone;
uniform vec2 uFlRange;
uniform vec3 uGlowPos;
uniform vec3 uGlowColor;
uniform float uGlowRange;
uniform float uFalloffK;
uniform vec3 uSmokeProbe;
out vec2 vUv;
out float vAlpha;
out float vSeed;
out vec3 vLight;
out float vDist;
float falloff(float d, float range) {
  float x = clamp(d / range, 0.0, 1.0);
  float w = 1.0 - x * x;
  return (w * w) / (1.0 + uFalloffK * d * d);
}
void main() {
  vec3 right = vec3(viewMatrix[0][0], viewMatrix[1][0], viewMatrix[2][0]);
  vec3 up = vec3(viewMatrix[0][1], viewMatrix[1][1], viewMatrix[2][1]);
  float a = iParams.z * 6.2832 + iParams.w * (iParams.z - 0.5) * 2.5;
  vec2 c = mat2(cos(a), sin(a), -sin(a), cos(a)) * position.xy;
  vec3 wp = iPos + (right * c.x + up * c.y) * iParams.x;
  vUv = position.xy;
  vAlpha = iParams.y;
  vSeed = iParams.z;
  vec3 toL = uFlPos - iPos;
  float d = length(toL);
  vec3 l = toL / max(d, 1e-4);
  float cosA = dot(-l, uFlDir);
  float inner = smoothstep(uFlCone.y, uFlCone.x, cosA) * falloff(d, uFlRange.x);
  float outer = smoothstep(uFlCone.w, uFlCone.z, cosA) * falloff(d, uFlRange.y);
  vLight = (uFlInner * inner + uFlOuter * outer) * 0.55 + uSmokeProbe
    + uGlowColor * falloff(length(uGlowPos - iPos), uGlowRange) * 0.5;
  vec4 view = viewMatrix * vec4(wp, 1.0);
  vDist = -view.z;
  gl_Position = projectionMatrix * view;
}
`;

const FRAG = /* glsl */ `
precision highp float;
in vec2 vUv;
in float vAlpha;
in float vSeed;
in vec3 vLight;
in float vDist;
uniform vec3 uFogColor;
uniform float uFogDensity;
uniform float uExposure;
uniform vec3 uSmokeAlbedo;
out vec4 fragColor;
float sh(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
float sn(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(sh(i), sh(i + vec2(1.0, 0.0)), f.x), mix(sh(i + vec2(0.0, 1.0)), sh(i + vec2(1.0, 1.0)), f.x), f.y);
}
vec3 aces(vec3 x) {
  return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}
void main() {
  float r2 = dot(vUv, vUv);
  if (r2 > 1.0) discard;
  float puff = 1.0 - r2;
#ifdef SMOKE_DETAIL
  float n = sn(vUv * 2.3 + vSeed * 17.0) * 0.6 + sn(vUv * 5.1 - vSeed * 9.0) * 0.4;
  puff *= smoothstep(0.2, 0.85, n);
#endif
  float fogF = 1.0 - exp(-pow(vDist * uFogDensity, 2.0));
  float alpha = vAlpha * puff * (1.0 - fogF);
  if (alpha < 0.004) discard;
  vec3 col = mix(uSmokeAlbedo * vLight, uFogColor, fogF);
  col = aces(col * uExposure);
  col = mix(1.055 * pow(col, vec3(1.0 / 2.4)) - 0.055, col * 12.92, vec3(lessThanEqual(col, vec3(0.0031308))));
  fragColor = vec4(col, alpha);
}
`;

const between = (range, u) => range[0] + (range[1] - range[0]) * u;

export class Smoke {
  /**
   * @param {any} shared the engine's shared world uniforms (torch, glow, fog, exposure, falloff)
   * @param {number} [seed]
   */
  constructor(shared, seed = 8517) {
    this.capacity = SmokeBudget.Max.capacity;
    this.budget = SmokeBudget.Max;
    this.seed = seed >>> 0 || 1;
    const n = this.capacity;
    this.px = new Float32Array(n);
    this.py = new Float32Array(n);
    this.pz = new Float32Array(n);
    this.vx = new Float32Array(n);
    this.vy = new Float32Array(n);
    this.vz = new Float32Array(n);
    this.age = new Float32Array(n);
    this.life = new Float32Array(n);
    this.size0 = new Float32Array(n);
    this.size1 = new Float32Array(n);
    this.alpha = new Float32Array(n);
    this.pseed = new Float32Array(n);
    this.count = 0;
    this.carry = 0;
    const geometry = new THREE.InstancedBufferGeometry();
    geometry.setAttribute('position', new THREE.BufferAttribute(new Float32Array([-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0]), 3));
    geometry.setIndex([0, 1, 2, 0, 2, 3]);
    this.iPos = new THREE.InstancedBufferAttribute(new Float32Array(n * 3), 3);
    this.iParams = new THREE.InstancedBufferAttribute(new Float32Array(n * 4), 4);
    this.iPos.setUsage(THREE.DynamicDrawUsage);
    this.iParams.setUsage(THREE.DynamicDrawUsage);
    geometry.setAttribute('iPos', this.iPos);
    geometry.setAttribute('iParams', this.iParams);
    geometry.instanceCount = 0;
    geometry.boundingSphere = new THREE.Sphere(new THREE.Vector3(), 1e6);
    const pick = (k, fallback) => (shared && shared[k]) || { value: fallback };
    this.material = new THREE.RawShaderMaterial({
      glslVersion: THREE.GLSL3,
      vertexShader: VERT,
      fragmentShader: FRAG,
      uniforms: {
        uFlPos: pick('uFlPos', new THREE.Vector3()),
        uFlDir: pick('uFlDir', new THREE.Vector3(0, 0, -1)),
        uFlInner: pick('uFlInner', new THREE.Vector3()),
        uFlOuter: pick('uFlOuter', new THREE.Vector3()),
        uFlCone: pick('uFlCone', new THREE.Vector4(0.95, 0.9, 0.8, 0.7)),
        uFlRange: pick('uFlRange', new THREE.Vector2(60, 48)),
        uGlowPos: pick('uGlowPos', new THREE.Vector3(0, -1e5, 0)),
        uGlowColor: pick('uGlowColor', new THREE.Vector3()),
        uGlowRange: pick('uGlowRange', 10),
        uFalloffK: pick('uFalloffK', 0.004),
        uFogColor: pick('uFogColor', new THREE.Vector3(0.02, 0.025, 0.03)),
        uFogDensity: pick('uFogDensity', 0.006),
        uExposure: pick('uExposure', 1.3),
        uSmokeProbe: { value: new THREE.Vector3(0.02, 0.02, 0.025) },
        uSmokeAlbedo: { value: new THREE.Vector3(...SMOKE_ALBEDO) },
      },
      defines: { SMOKE_DETAIL: '' },
      transparent: true,
      depthWrite: false,
      side: THREE.DoubleSide,
    });
    this.mesh = new THREE.Mesh(geometry, this.material);
    this.mesh.frustumCulled = false;
    this.mesh.matrixAutoUpdate = false;
    this.mesh.renderOrder = 11;
    this.mesh.name = 'CreatureSmoke';
    this.geometry = geometry;
  }

  _random() {
    // mulberry32: deterministic puffs (screenshots and tests repeat)
    this.seed = (this.seed + 0x6d2b79f5) >>> 0;
    let t = this.seed;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }

  /** The look tier ('Max' | 'Potato'). */
  setTier(tier) {
    const b = SmokeBudget[tier] || SmokeBudget.Max;
    if (b === this.budget) return;
    this.budget = b;
    if (b.detail) this.material.defines.SMOKE_DETAIL = '';
    else delete this.material.defines.SMOKE_DETAIL;
    this.material.needsUpdate = true;
  }

  /** The level probe's irradiance at the Creature (THREE.Color, linear). */
  setProbe(color) {
    this.material.uniforms.uSmokeProbe.value.set(color.r, color.g, color.b);
  }

  /** One puff at `p` drifting with `v` (THREE.Vector3s); `scale` grows it, `alpha` thickens it, `sink` drops it. */
  spawn(p, v, scale = 1, alpha = 1, sink = 0) {
    if (this.count >= this.budget.capacity) return;
    const i = this.count++;
    const r = () => this._random();
    this.px[i] = p.x + (r() - 0.5) * JITTER;
    this.py[i] = p.y + (r() - 0.5) * JITTER;
    this.pz[i] = p.z + (r() - 0.5) * JITTER;
    this.vx[i] = v.x + (r() - 0.5) * 0.3;
    this.vy[i] = v.y + (sink > 0 ? -between(SHROUD_SINK, r()) * sink : between(RISE, r()));
    this.vz[i] = v.z + (r() - 0.5) * 0.3;
    this.age[i] = 0;
    this.life[i] = between(LIFE, r()) * (0.8 + 0.4 * scale);
    this.size0[i] = between(SIZE_START, r()) * scale;
    this.size1[i] = between(SIZE_END, r()) * scale;
    this.alpha[i] = ALPHA * alpha;
    this.pseed[i] = r();
  }

  /**
   * Trails puffs from the anchors for `dt` seconds of a body moving at `velocity` (fade scales the rate: none
   * while it is gone). @param {{position: THREE.Vector3, weight: number}[]} anchors
   */
  emit(anchors, velocity, dt, fade = 1) {
    if (anchors.length === 0 || fade <= 0.02 || dt <= 0) return;
    const speed = Math.hypot(velocity.x, velocity.z);
    this.carry += (BASE_RATE + SPEED_RATE * speed) * this.budget.rate * fade * dt;
    // the shroud: heavy smoke hanging off the body from the shoulders down, dragging behind it
    this.shroudCarry = (this.shroudCarry || 0) + SHROUD_RATE * (this.budget.shroud || 0) * fade * dt;
    if (this.shroudCarry >= 1) {
      let shroudTotal = 0;
      for (const a of anchors) if (a.shroud) shroudTotal += a.weight;
      _v.copy(velocity).multiplyScalar(CARRY * 0.6);
      while (this.shroudCarry >= 1 && shroudTotal > 0) {
        this.shroudCarry -= 1;
        let pick = this._random() * shroudTotal;
        let anchor = null;
        for (const a of anchors) {
          if (!a.shroud) continue;
          anchor = a;
          pick -= a.weight;
          if (pick <= 0) break;
        }
        if (anchor) this.spawn(anchor.position, _v, SHROUD_SIZE, SHROUD_ALPHA, 1);
      }
      if (this.shroudCarry > 3) this.shroudCarry = 3;
    }
    let total = 0;
    for (const a of anchors) if (!a.shroud) total += a.weight;
    if (total <= 0) return;
    _v.copy(velocity).multiplyScalar(CARRY);
    while (this.carry >= 1) {
      this.carry -= 1;
      let pick = this._random() * total;
      let anchor = null;
      for (const a of anchors) {
        if (a.shroud) continue;
        anchor = a;
        pick -= a.weight;
        if (pick <= 0) break;
      }
      if (!anchor) break;
      this.spawn(anchor.position, _v, 1, 0.7 + 0.3 * Math.min(1, speed / 12));
    }
    if (this.carry > 4) this.carry = 4;
  }

  /** A cloud off the whole body: `count` puffs spread over `points`, thrown outward from `centre`. */
  burst(points, centre, count, outward = 2.4) {
    if (points.length === 0) return;
    const n = Math.round(count * this.budget.rate);
    for (let k = 0; k < n; k++) {
      const p = points[Math.floor(this._random() * points.length) % points.length];
      _d.copy(p).sub(centre);
      _d.y *= 0.3;
      if (_d.lengthSq() < 1e-4) _d.set(this._random() - 0.5, 0, this._random() - 0.5);
      _d.normalize().multiplyScalar(outward * (0.4 + 0.6 * this._random()));
      this.spawn(p, _d, 1.6, 1.4);
    }
  }

  /** Ages, drifts and draws the puffs. */
  step(dt) {
    let j = 0;
    const drag = Math.exp(-DRAG * dt);
    for (let i = 0; i < this.count; i++) {
      const age = this.age[i] + dt;
      if (age >= this.life[i]) continue;
      this.vx[i] *= drag;
      this.vz[i] *= drag;
      this.vy[i] = this.vy[i] * drag + 0.08 * dt;
      if (j !== i) {
        for (const a of [this.px, this.py, this.pz, this.vx, this.vy, this.vz, this.life, this.size0, this.size1, this.alpha, this.pseed]) a[j] = a[i];
      }
      this.age[j] = age;
      this.px[j] += this.vx[j] * dt;
      this.py[j] += this.vy[j] * dt;
      this.pz[j] += this.vz[j] * dt;
      j++;
    }
    this.count = j;
    const pos = this.iPos.array;
    const par = this.iParams.array;
    for (let i = 0; i < j; i++) {
      const u = this.age[i] / this.life[i];
      const envelope = Math.min(1, u / 0.15) * (1 - u) * (1 - u);
      pos[i * 3] = this.px[i];
      pos[i * 3 + 1] = this.py[i];
      pos[i * 3 + 2] = this.pz[i];
      par[i * 4] = this.size0[i] + (this.size1[i] - this.size0[i]) * Math.sqrt(u);
      par[i * 4 + 1] = this.alpha[i] * envelope;
      par[i * 4 + 2] = this.pseed[i];
      par[i * 4 + 3] = u;
    }
    this.geometry.instanceCount = j;
    if (j > 0) {
      this.iPos.addUpdateRange(0, j * 3);
      this.iParams.addUpdateRange(0, j * 4);
      this.iPos.needsUpdate = true;
      this.iParams.needsUpdate = true;
    }
    this.mesh.visible = j > 0;
  }

  clear() {
    this.count = 0;
    this.geometry.instanceCount = 0;
    this.mesh.visible = false;
  }

  dispose() {
    this.geometry.dispose();
    this.material.dispose();
  }
}

const _v = new THREE.Vector3();
const _d = new THREE.Vector3();
