// Shards: porcelain breaking off the Tall Man's mask when its slit tears into the maw (the jumpscare). A handful of
// small jagged ivory triangles (one draw call, positions rebuilt on the CPU each frame: there are at most a few dozen)
// thrown out of the maw toward the victim, tumbling and falling, lit like the world (the torch, the presence glow, the
// level probe and the point lights through the engine's shared uniforms), fogged and tone-mapped like it. Max throws
// more of them than Potato (look.js LookTiers.shards).

import * as THREE from 'three';

const LIFE = [0.7, 1.15];
const SPEED = [1.6, 3.4];
const GRAVITY = 14;
const SIZE = [0.01, 0.028];
const SPIN = [8, 22];
const DRAG = 0.8;
const IVORY = [0.4, 0.36, 0.27]; // linear

const VERT = /* glsl */ `
precision highp float;
in vec3 position;
in vec3 normal;
in float shade;
uniform mat4 viewMatrix;
uniform mat4 projectionMatrix;
uniform vec3 cameraPosition;
uniform vec3 uFlPos;
uniform vec3 uFlDir;
uniform vec3 uFlInner;
uniform vec3 uFlOuter;
uniform vec4 uFlCone;
uniform vec2 uFlRange;
uniform vec3 uGlowPos;
uniform vec3 uGlowColor;
uniform float uGlowRange;
uniform vec4 uPlPos[4];
uniform vec3 uPlColor[4];
uniform float uFalloffK;
uniform vec3 uShardProbe;
out vec3 vLight;
out float vDist;
out float vShade;
float falloff(float d, float range) {
  float x = clamp(d / range, 0.0, 1.0);
  float w = 1.0 - x * x;
  return (w * w) / (1.0 + uFalloffK * d * d);
}
void main() {
  vec3 n = normalize(normal);
  if (dot(n, cameraPosition - position) < 0.0) n = -n;
  vec3 toL = uFlPos - position;
  float d = length(toL);
  vec3 l = toL / max(d, 1e-4);
  float cosA = dot(-l, uFlDir);
  float inner = smoothstep(uFlCone.y, uFlCone.x, cosA) * falloff(d, uFlRange.x);
  float outer = smoothstep(uFlCone.w, uFlCone.z, cosA) * falloff(d, uFlRange.y);
  vec3 light = (uFlInner * inner + uFlOuter * outer) * max(dot(n, l), 0.0);
  vec3 tg = uGlowPos - position;
  light += uGlowColor * max(dot(n, normalize(tg)), 0.0) * falloff(length(tg), uGlowRange);
  for (int i = 0; i < 4; i++) {
    vec3 tp = uPlPos[i].xyz - position;
    light += uPlColor[i] * max(dot(n, normalize(tp)), 0.0) * falloff(length(tp), uPlPos[i].w);
  }
  vLight = light / (1.0 + 1.2 * light) + uShardProbe;
  vShade = shade;
  vec4 view = viewMatrix * vec4(position, 1.0);
  vDist = -view.z;
  gl_Position = projectionMatrix * view;
}
`;

const FRAG = /* glsl */ `
precision highp float;
in vec3 vLight;
in float vDist;
in float vShade;
uniform vec3 uFogColor;
uniform float uFogDensity;
uniform float uExposure;
uniform vec3 uShardAlbedo;
out vec4 fragColor;
vec3 aces(vec3 x) {
  return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}
void main() {
  float fogF = 1.0 - exp(-pow(vDist * uFogDensity, 2.0));
  vec3 col = mix(uShardAlbedo * vShade * vLight, uFogColor, fogF);
  col = aces(col * uExposure);
  col = mix(1.055 * pow(col, vec3(1.0 / 2.4)) - 0.055, col * 12.92, vec3(lessThanEqual(col, vec3(0.0031308))));
  fragColor = vec4(col, 1.0);
}
`;

const between = (range, u) => range[0] + (range[1] - range[0]) * u;

export class Shards {
  /** @param {any} shared the engine's shared world uniforms @param {number} [capacity] */
  constructor(shared, capacity = 32, seed = 4242) {
    this.capacity = capacity;
    this.seed = seed >>> 0 || 1;
    this.items = [];
    const geometry = new THREE.BufferGeometry();
    this.position = new THREE.BufferAttribute(new Float32Array(capacity * 9), 3);
    this.normal = new THREE.BufferAttribute(new Float32Array(capacity * 9), 3);
    this.shade = new THREE.BufferAttribute(new Float32Array(capacity * 3), 1);
    for (const a of [this.position, this.normal, this.shade]) a.setUsage(THREE.DynamicDrawUsage);
    geometry.setAttribute('position', this.position);
    geometry.setAttribute('normal', this.normal);
    geometry.setAttribute('shade', this.shade);
    geometry.setDrawRange(0, 0);
    geometry.boundingSphere = new THREE.Sphere(new THREE.Vector3(), 1e6);
    const pick = (k, fallback) => (shared && shared[k]) || { value: fallback };
    const plPos = [];
    const plColor = [];
    for (let i = 0; i < 4; i++) {
      plPos.push(new THREE.Vector4(0, -1e5, 0, 1));
      plColor.push(new THREE.Vector3());
    }
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
        uPlPos: pick('uPlPos', plPos),
        uPlColor: pick('uPlColor', plColor),
        uFalloffK: pick('uFalloffK', 0.004),
        uFogColor: pick('uFogColor', new THREE.Vector3(0.02, 0.025, 0.03)),
        uFogDensity: pick('uFogDensity', 0.006),
        uExposure: pick('uExposure', 1.3),
        uShardProbe: { value: new THREE.Vector3(0.03, 0.03, 0.035) },
        uShardAlbedo: { value: new THREE.Vector3(...IVORY) },
      },
      side: THREE.DoubleSide,
    });
    this.mesh = new THREE.Mesh(geometry, this.material);
    this.mesh.frustumCulled = false;
    this.mesh.matrixAutoUpdate = false;
    this.mesh.renderOrder = 10;
    this.mesh.name = 'CreatureShards';
    this.mesh.visible = false;
    this.geometry = geometry;
  }

  _random() {
    this.seed = (this.seed + 0x6d2b79f5) >>> 0;
    let t = this.seed;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }

  /** The level probe's irradiance at the Creature (THREE.Color, linear). */
  setProbe(color) {
    this.material.uniforms.uShardProbe.value.set(color.r, color.g, color.b).multiplyScalar(0.6);
  }

  /**
   * Throws `count` shards off the points `points` (world), outward along `out` (unit, world: toward the victim) and
   * spread across the plane of `right` / `up`.
   */
  burst(points, out, right, up, count) {
    const r = () => this._random();
    for (let k = 0; k < count && this.items.length < this.capacity; k++) {
      const p = points[Math.floor(r() * points.length) % points.length];
      const speed = between(SPEED, r());
      const v = out.clone().multiplyScalar(speed * (0.6 + 0.4 * r()))
        .addScaledVector(right, (r() - 0.5) * 2.2)
        .addScaledVector(up, 0.4 + r() * 1.6);
      const size = between(SIZE, r());
      // a jagged sliver: three corners round its centre, uneven
      const corners = [];
      for (let c = 0; c < 3; c++) {
        const a = (c / 3) * Math.PI * 2 + (r() - 0.5) * 1.2;
        const len = size * (0.45 + r() * 0.9);
        corners.push(new THREE.Vector2(Math.cos(a) * len, Math.sin(a) * len));
      }
      const axis = new THREE.Vector3(r() - 0.5, r() - 0.5, r() - 0.5).normalize();
      this.items.push({
        p: p.clone(),
        v,
        age: 0,
        life: between(LIFE, r()),
        corners,
        axis,
        spin: between(SPIN, r()),
        angle: r() * Math.PI * 2,
        right: right.clone(),
        up: up.clone(),
        shade: 0.85 + 0.3 * r(),
      });
    }
  }

  step(dt) {
    const list = this.items;
    let j = 0;
    for (let i = 0; i < list.length; i++) {
      const s = list[i];
      s.age += dt;
      if (s.age >= s.life) continue;
      s.v.multiplyScalar(Math.exp(-DRAG * dt));
      s.v.y -= GRAVITY * dt;
      s.p.addScaledVector(s.v, dt);
      s.angle += s.spin * dt;
      list[j++] = s;
    }
    list.length = j;
    const pos = this.position.array;
    const nrm = this.normal.array;
    const shade = this.shade.array;
    for (let i = 0; i < j; i++) {
      const s = list[i];
      _q.setFromAxisAngle(s.axis, s.angle);
      _r.copy(s.right).applyQuaternion(_q);
      _u.copy(s.up).applyQuaternion(_q);
      _n.crossVectors(_r, _u).normalize();
      const shrink = 1 - Math.max(0, (s.age / s.life - 0.8) / 0.2);
      for (let c = 0; c < 3; c++) {
        const k = (i * 3 + c) * 3;
        _p.copy(s.p).addScaledVector(_r, s.corners[c].x * shrink).addScaledVector(_u, s.corners[c].y * shrink);
        pos[k] = _p.x;
        pos[k + 1] = _p.y;
        pos[k + 2] = _p.z;
        nrm[k] = _n.x;
        nrm[k + 1] = _n.y;
        nrm[k + 2] = _n.z;
        shade[i * 3 + c] = s.shade;
      }
    }
    this.geometry.setDrawRange(0, j * 3);
    if (j > 0) {
      this.position.addUpdateRange(0, j * 9);
      this.normal.addUpdateRange(0, j * 9);
      this.shade.addUpdateRange(0, j * 3);
      this.position.needsUpdate = true;
      this.normal.needsUpdate = true;
      this.shade.needsUpdate = true;
    }
    this.mesh.visible = j > 0;
  }

  clear() {
    this.items.length = 0;
    this.geometry.setDrawRange(0, 0);
    this.mesh.visible = false;
  }

  dispose() {
    this.geometry.dispose();
    this.material.dispose();
  }
}

const _q = new THREE.Quaternion();
const _r = new THREE.Vector3();
const _u = new THREE.Vector3();
const _n = new THREE.Vector3();
const _p = new THREE.Vector3();
