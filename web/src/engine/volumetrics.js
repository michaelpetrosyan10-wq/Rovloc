// Volumetrics: the visible air (LightingController/Volumetrics + FixtureGlow cones).
//
//   * Shafts. The nearest `budget.shafts` burning fixtures whose kind throws a haze cone (Fluorescent, ClassroomGlow,
//     Bulb, Floodlight, EmergencyRed) show one: a camera-facing additive quad from the lamp (width0) toward the floor
//     (width1, at most `length` studs; floodlights aim along their face), bright at the lamp and fading toward the
//     floor, in the light's colour, brightening and dying with its flicker group, scaled by the film's `shafts`.
//     Sources behind the camera rank 1.8x further; nothing beyond 90 studs. The choice refreshes at 4 Hz, brightness
//     fades at 1.6/s.
//   * Dust. The nearest `budget.dust` shafts carry a slow cloud of motes (additive points) that glint inside the
//     light, scaled by the film's `dust`.

import * as THREE from 'three';
import { clamp01 } from './math.js';

const CONES = {
  Fluorescent: { width0: 3.2, width1: 9.5, length: 13, strength: 1, aimed: false },
  ClassroomGlow: { width0: 3, width1: 9, length: 12, strength: 0.9, aimed: false },
  Bulb: { width0: 0.7, width1: 7, length: 11, strength: 1.15, aimed: false },
  Floodlight: { width0: 1.8, width1: 14, length: 26, strength: 1.3, aimed: true },
  EmergencyRed: { width0: 0.9, width1: 5, length: 7, strength: 0.7, aimed: false },
};
const OFF_LEVEL = 0.02; // FixtureGlow.OffLevel
const SHAFT_RANGE = 90;
const DUST_RANGE = 45;
const BEHIND_PENALTY = 1.8;
const FADE_RATE = 1.6;
const REFRESH = 0.25;
const SHAFT_ALPHA = 0.055; // additive strength of a full-brightness shaft
const DUST_PER_SHAFT = 48;

const SHAFT_VERT = /* glsl */ `
uniform vec3 uTop; uniform vec3 uAxis; uniform float uLen; uniform float uW0; uniform float uW1;
varying float vAlong; varying float vAcross;
void main() {
  vAlong = position.y;            // 0 at the lamp, 1 at the far end
  vAcross = position.x;           // -1..1
  vec3 p = uTop + uAxis * (uLen * position.y);
  vec3 toCam = normalize(cameraPosition - p);
  vec3 side = normalize(cross(uAxis, toCam));
  float w = mix(uW0, uW1, position.y) * 0.5;
  p += side * position.x * w;
  gl_Position = projectionMatrix * viewMatrix * vec4(p, 1.0);
}`;
const SHAFT_FRAG = /* glsl */ `
uniform vec3 uColor; uniform float uStrength;
varying float vAlong; varying float vAcross;
void main() {
  float along = smoothstep(0.0, 0.08, vAlong) * pow(1.0 - vAlong, 1.4);
  float across = 1.0 - smoothstep(0.35, 1.0, abs(vAcross));
  float core = 1.0 - smoothstep(0.0, 0.45, abs(vAcross));
  gl_FragColor = vec4(uColor * uStrength * along * (across * 0.6 + core * 0.4), 1.0);
}`;

export class Volumetrics {
  /** @param {import('./index.js').Engine} engine */
  constructor(engine) {
    this.engine = engine;
    this.group = new THREE.Group();
    this.group.name = 'Volumetrics';
    engine.world.scene.add(this.group);
    this.sources = [];
    const cones = (engine.world.meta.lighting && engine.world.meta.lighting.fixtureCones) || CONES;
    for (const l of engine.world.meta.lights || []) {
      const cone = cones[l.kind] || CONES[l.kind];
      if (!cone || l.broken || !l.baked) continue;
      const pos = new THREE.Vector3(...l.pos);
      const axis = cone.aimed && l.dir ? new THREE.Vector3(...l.dir).normalize() : new THREE.Vector3(0, -1, 0);
      const color = new THREE.Color().setRGB(l.color[0], l.color[1], l.color[2], THREE.SRGBColorSpace);
      this.sources.push({ light: l, cone, pos, axis, color, level: l.level, shown: 0, slot: null, group: l.group || 0 });
    }
    const geo = new THREE.PlaneGeometry(2, 1, 1, 6);
    geo.translate(0, 0.5, 0);
    this.slots = [];
    for (let i = 0; i < 14; i++) {
      const mat = new THREE.ShaderMaterial({
        uniforms: {
          uTop: { value: new THREE.Vector3() }, uAxis: { value: new THREE.Vector3(0, -1, 0) }, uLen: { value: 10 },
          uW0: { value: 1 }, uW1: { value: 4 }, uColor: { value: new THREE.Color() }, uStrength: { value: 0 },
        },
        vertexShader: SHAFT_VERT,
        fragmentShader: SHAFT_FRAG,
        transparent: true,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
        side: THREE.DoubleSide,
      });
      const mesh = new THREE.Mesh(geo, mat);
      mesh.frustumCulled = false;
      mesh.visible = false;
      mesh.renderOrder = 15;
      this.group.add(mesh);
      this.slots.push({ mesh, source: null });
    }
    // dust motes
    this.dustSlots = [];
    for (let i = 0; i < 8; i++) {
      const g = new THREE.BufferGeometry();
      const seeds = new Float32Array(DUST_PER_SHAFT * 3);
      for (let k = 0; k < seeds.length; k++) seeds[k] = Math.random();
      g.setAttribute('position', new THREE.BufferAttribute(seeds, 3));
      const mat = new THREE.ShaderMaterial({
        uniforms: {
          uTop: { value: new THREE.Vector3() }, uLen: { value: 10 }, uW: { value: 4 }, uTime: { value: 0 },
          uColor: { value: new THREE.Color() }, uStrength: { value: 0 }, uSize: { value: 2 },
        },
        vertexShader: /* glsl */ `
          uniform vec3 uTop; uniform float uLen; uniform float uW; uniform float uTime; uniform float uSize;
          varying float vFade;
          void main() {
            vec3 s = position;
            float t = uTime * (0.02 + 0.03 * s.z);
            float along = fract(s.y + t);
            float ang = s.x * 6.2831 + uTime * 0.05 * (s.z - 0.5);
            float r = sqrt(fract(s.z * 7.13)) * uW * 0.5 * (0.35 + 0.65 * along);
            vec3 p = uTop + vec3(cos(ang) * r, -along * uLen, sin(ang) * r);
            vFade = sin(along * 3.14159);
            vec4 mv = viewMatrix * vec4(p, 1.0);
            gl_PointSize = uSize * 30.0 / max(1.0, -mv.z);
            gl_Position = projectionMatrix * mv;
          }`,
        fragmentShader: /* glsl */ `
          uniform vec3 uColor; uniform float uStrength; varying float vFade;
          void main() {
            vec2 d = gl_PointCoord - 0.5;
            float a = smoothstep(0.5, 0.0, length(d));
            gl_FragColor = vec4(uColor * uStrength * vFade * a, 1.0);
          }`,
        transparent: true,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
      });
      const pts = new THREE.Points(g, mat);
      pts.frustumCulled = false;
      pts.visible = false;
      this.group.add(pts);
      this.dustSlots.push({ points: pts, source: null });
    }
    this.clock = REFRESH;
    this._fwd = new THREE.Vector3();
  }

  update(dt, camera, film, focus) {
    const budget = this.engine.quality.budget;
    const lighting = this.engine.lighting;
    const flicker = this.engine.shared.uFlickerData;
    this.clock += dt;
    if (this.clock >= REFRESH) {
      this.clock = 0;
      camera.getWorldDirection(this._fwd);
      const ranked = [];
      for (const s of this.sources) {
        if (!focus.has(s.level)) continue;
        const d = s.pos.distanceTo(camera.position);
        if (d > SHAFT_RANGE) continue;
        _to.subVectors(s.pos, camera.position);
        const behind = _to.dot(this._fwd) < -2;
        ranked.push({ s, rank: behind ? d * BEHIND_PENALTY : d, d });
      }
      ranked.sort((a, b) => a.rank - b.rank);
      const want = new Set(ranked.slice(0, budget.shafts).map((r) => r.s));
      for (const s of this.sources) s.wanted = want.has(s);
      const dustWant = ranked.filter((r) => r.d < DUST_RANGE).slice(0, budget.dust).map((r) => r.s);
      // assign shaft slots
      for (const slot of this.slots) if (slot.source && !slot.source.wanted && slot.source.shown <= 0.001) slot.source = null;
      for (const s of want) {
        if (this.slots.some((sl) => sl.source === s)) continue;
        const free = this.slots.find((sl) => !sl.source);
        if (free) free.source = s;
      }
      for (let i = 0; i < this.dustSlots.length; i++) this.dustSlots[i].source = dustWant[i] || null;
    }
    const shafts = Math.max(0, film.shafts);
    for (const slot of this.slots) {
      const s = slot.source;
      if (!s) {
        slot.mesh.visible = false;
        continue;
      }
      const target = s.wanted ? 1 : 0;
      s.shown += Math.sign(target - s.shown) * Math.min(Math.abs(target - s.shown), FADE_RATE * dt);
      const g = s.group > 0 ? flicker[s.group] ?? 1 : 1;
      const level = clamp01(g);
      const strength = level <= OFF_LEVEL ? 0 : s.cone.strength * shafts * level ** 0.8;
      const u = slot.mesh.material.uniforms;
      u.uTop.value.copy(s.pos);
      u.uAxis.value.copy(s.axis);
      u.uLen.value = s.cone.length;
      u.uW0.value = s.cone.width0;
      u.uW1.value = s.cone.width1;
      u.uColor.value.copy(s.color);
      u.uStrength.value = strength * s.shown * SHAFT_ALPHA * (1 + lighting.flash * 2);
      slot.mesh.visible = u.uStrength.value > 1e-4;
    }
    const t = this.engine.loop.realTime;
    for (const slot of this.dustSlots) {
      const s = slot.source;
      slot.points.visible = !!s && film.dust > 0.01;
      if (!slot.points.visible) continue;
      const g = s.group > 0 ? flicker[s.group] ?? 1 : 1;
      const u = slot.points.material.uniforms;
      u.uTop.value.copy(s.pos);
      u.uLen.value = s.cone.length;
      u.uW.value = s.cone.width1;
      u.uTime.value = t;
      u.uColor.value.setRGB(0.92, 0.9, 0.84);
      u.uStrength.value = 0.35 * clamp01(film.dust) * clamp01(g) * budget.particleScale;
      u.uSize.value = 1.6 * (this.engine.renderer.stats.internal[1] / 720);
    }
  }
}

const _to = new THREE.Vector3();
