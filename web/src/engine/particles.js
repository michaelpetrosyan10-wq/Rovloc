// GPU particles: steam from the tunnels' leaking relief valves, water dripping from leaking pipes, grit shaken from the
// ceiling when a door slams (or a grate is kicked, debris falls), and dust motes drifting through the torch beam.
//
// Every particle is stateless on the GPU: its position, size and fade are a pure function of time, its emitter and
// its own seed, computed in the vertex shader, so the CPU does nothing per particle (one draw per system and level).
// They are lit by the torch's two cones (the bake's falloff) over a faint ambient sampled from the probes at their
// emitter, and fogged like the world.
//
//   * Steam: meta.emitters (kind Steam, from the SteamVent nozzles' Mouth attachments; bake.mjs). Rate and spread from
//     the Roblox emitter (TunnelDressingBuilder): about 13 puffs a second, 1.1-2.1 s, 3.2-5.2 studs/s, spread 14 deg,
//     rising 1.6, drag 1.6.
//   * Drips: the DripPipe anchors; drops fall to the floor below (one ray at boot) and splash.
//   * Grit: a noise pulse (DoorSlam, FloorDebris, GrateKick, TrapSnap) within reach of the camera on its level drops a
//     burst of grit and dust from the ceiling above it (one ray up).
//   * Motes: a box of dust round the camera that only shows where the torch lights it.
//
// Tiers (quality.js): particleScale scales every system's count (Max / High 1, Medium 0.7, Low 0.4) and Potato draws
// none. Purely visual: nothing here writes game state; noise pulses are only listened to, rays only cast.

import * as THREE from 'three';
import { sampleProbe } from './data.js';

const STEAM_PER_VENT = 26;
const STEAM_LIFE = 1.6;
const DRIPS_PER_PIPE = 4;
const GRIT_BURSTS = 4;
const GRIT_PER_BURST = 120;
const GRIT_LIFE = 2.2;
const GRIT_REACH = 45;
const GRIT_KINDS = new Set(['DoorSlam', 'FloorDebris', 'GrateKick', 'TrapSnap']);
const MOTES = 700;
const MOTE_BOX = 14;

const COMMON = /* glsl */ `
uniform float uTime;
uniform vec3 uFlPos;
uniform vec3 uFlDir;
uniform vec3 uFlInner;
uniform vec3 uFlOuter;
uniform vec4 uFlCone;
uniform vec2 uFlRange;
uniform float uFalloffK;
uniform float uExposure;
uniform vec3 uFogColor;
uniform float uFogDensity;
uniform float uPxScale;
float falloff(float d, float range) {
  float x = clamp(d / range, 0.0, 1.0);
  float w = 1.0 - x * x;
  return (w * w) / (1.0 + uFalloffK * d * d);
}
vec3 torchAt(vec3 p) {
  vec3 toP = p - uFlPos;
  float d = length(toP);
  float cosA = dot(toP / max(d, 1e-4), uFlDir);
  return uFlInner * smoothstep(uFlCone.y, uFlCone.x, cosA) * falloff(d, uFlRange.x)
    + uFlOuter * smoothstep(uFlCone.w, uFlCone.z, cosA) * falloff(d, uFlRange.y);
}
float hash1(float n) { return fract(sin(n) * 43758.5453123); }
vec3 aces(vec3 x) { return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0); }
vec3 display(vec3 lin, vec3 wp) {
  float fogF = 1.0 - exp(-pow(length(cameraPosition - wp) * uFogDensity, 2.0));
  vec3 c = aces(mix(lin, uFogColor, fogF) * uExposure);
  return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, c * 12.92, vec3(lessThanEqual(c, vec3(0.0031308))));
}
`;

// a: emitter position + seed; b: direction + phase; c: ambient light (rgb) + per-particle seed
const STEAM_VERT = /* glsl */ `
${COMMON}
attribute vec4 aEmit;
attribute vec4 aDir;
attribute vec4 aAmb;
varying vec3 vColor;
varying float vAlpha;
void main() {
  float s = aAmb.w;
  float life = ${STEAM_LIFE.toFixed(2)} * (0.7 + 0.6 * hash1(s * 17.1));
  float age = mod(uTime + aDir.w * life, life);
  float t = age / life;
  // a jittered cone round the nozzle's direction
  vec3 dir = normalize(aDir.xyz);
  vec3 side = normalize(abs(dir.y) < 0.95 ? cross(dir, vec3(0.0, 1.0, 0.0)) : cross(dir, vec3(1.0, 0.0, 0.0)));
  vec3 up = cross(side, dir);
  float a = hash1(s * 3.7) * 6.2831853;
  float spread = 0.25 * sqrt(hash1(s * 9.1));
  vec3 v0 = normalize(dir + (side * cos(a) + up * sin(a)) * spread) * (3.2 + 2.0 * hash1(s * 5.3));
  float k = 1.6;
  vec3 p = aEmit.xyz + v0 * (1.0 - exp(-k * age)) / k + vec3(0.0, 0.8, 0.0) * age * age;
  p += vec3(sin(uTime * 1.3 + s * 11.0), 0.0, cos(uTime * 1.1 + s * 7.0)) * 0.12 * age;
  vec4 mv = viewMatrix * vec4(p, 1.0);
  float size = mix(0.25, 1.5, sqrt(t));
  gl_PointSize = min(size * uPxScale / max(0.3, -mv.z), 512.0);
  gl_Position = projectionMatrix * mv;
  vec3 lit = aAmb.rgb + torchAt(p);
  vColor = display(vec3(0.62, 0.64, 0.66) * lit, p);
  vAlpha = smoothstep(0.0, 0.12, t) * (1.0 - smoothstep(0.45, 1.0, t)) * 0.32;
}`;

const SOFT_FRAG = /* glsl */ `
varying vec3 vColor;
varying float vAlpha;
void main() {
  vec2 d = gl_PointCoord - 0.5;
  float r = length(d) * 2.0;
  float a = (1.0 - smoothstep(0.35, 1.0, r)) * vAlpha;
  if (a < 0.004) discard;
  gl_FragColor = vec4(vColor, a);
}`;

// drips: aEmit = pipe position + seed; aDir.x = floor y, aDir.y = period, aDir.z = drop index, aDir.w = phase
const DRIP_VERT = /* glsl */ `
${COMMON}
attribute vec4 aEmit;
attribute vec4 aDir;
attribute vec4 aAmb;
varying vec3 vColor;
varying float vAlpha;
void main() {
  float period = aDir.y;
  float t = mod(uTime + aDir.w * period, period);
  float fall = max(0.0, aEmit.y - aDir.x);
  float tFall = sqrt(2.0 * fall / 32.0);
  vec3 p = aEmit.xyz;
  float size = 0.07;
  float alpha = 0.0;
  float splash = aDir.z; // 0: the drop, 1..3: splash droplets
  if (splash < 0.5) {
    // forms (swelling at the pipe), falls, gone at the floor
    float form = 0.35 * period;
    if (t < form) { size = 0.04 + 0.05 * t / form; alpha = 0.8; }
    else if (t < form + tFall) { float tt = t - form; p.y -= 16.0 * tt * tt; alpha = 1.0; size = 0.06; }
  } else {
    float tt = t - 0.35 * period - tFall;
    if (tt > 0.0 && tt < 0.32) {
      float a = splash * 2.1 + aEmit.w * 6.0;
      vec3 v = vec3(cos(a) * 1.4, 2.6 + splash * 0.5, sin(a) * 1.4);
      p = vec3(aEmit.x, aDir.x + 0.02, aEmit.z) + v * tt + vec3(0.0, -16.0, 0.0) * tt * tt;
      alpha = 1.0 - tt / 0.32;
      size = 0.035;
    }
  }
  vec4 mv = viewMatrix * vec4(p, 1.0);
  gl_PointSize = alpha > 0.0 ? clamp(size * uPxScale / max(0.3, -mv.z), 1.0, 64.0) : 0.0;
  gl_Position = alpha > 0.0 ? projectionMatrix * mv : vec4(2.0, 2.0, 2.0, 1.0);
  vec3 lit = aAmb.rgb * 2.0 + torchAt(p) * 1.6 + vec3(0.02);
  vColor = display(vec3(0.75, 0.82, 0.86) * lit, p);
  vAlpha = alpha * 0.85;
}`;

// grit: per particle aEmit = (burst slot, seeds); bursts in uniforms: origin + start, floor y + ceiling y
const GRIT_VERT = /* glsl */ `
${COMMON}
uniform vec4 uBurst[${GRIT_BURSTS}];
uniform vec4 uBurstY[${GRIT_BURSTS}];
uniform vec3 uBurstAmb[${GRIT_BURSTS}];
attribute vec4 aEmit;
varying vec3 vColor;
varying float vAlpha;
void main() {
  int slot = int(aEmit.x + 0.5);
  vec4 b = uBurst[slot];
  float age = uTime - b.w - aEmit.w * 0.5; // the grit keeps coming for half a second
  float floorY = uBurstY[slot].x;
  float ceilY = uBurstY[slot].y;
  float dust = step(0.7, aEmit.y); // 30 %: soft dust that hangs, the rest grit that drops
  vec3 p = vec3(0.0);
  float alpha = 0.0;
  if (age > 0.0 && age < ${GRIT_LIFE.toFixed(1)}) {
    float r = 4.5 * sqrt(aEmit.z);
    float a = aEmit.y * 61.7 + aEmit.z * 13.1;
    vec3 start = vec3(b.x + cos(a) * r, ceilY - 0.05, b.z + sin(a) * r);
    float g = mix(30.0, 2.2, dust);
    p = start + vec3(sin(a * 3.0), 0.0, cos(a * 5.0)) * age * mix(0.3, 0.9, dust);
    p.y -= 0.5 * g * age * age;
    alpha = p.y > floorY + 0.03 ? 1.0 : 0.0;
    p.y = max(p.y, floorY + 0.03);
    alpha *= 1.0 - smoothstep(${(GRIT_LIFE * 0.55).toFixed(2)}, ${GRIT_LIFE.toFixed(1)}, age);
  }
  vec4 mv = viewMatrix * vec4(p, 1.0);
  float size = mix(0.05, 0.55, dust);
  gl_PointSize = alpha > 0.0 ? clamp(size * uPxScale / max(0.3, -mv.z), 1.0, 256.0) : 0.0;
  gl_Position = alpha > 0.0 ? projectionMatrix * mv : vec4(2.0, 2.0, 2.0, 1.0);
  vec3 lit = uBurstAmb[slot] + torchAt(p);
  vColor = display(mix(vec3(0.36, 0.33, 0.29), vec3(0.6, 0.57, 0.52), dust) * lit, p);
  vAlpha = alpha * mix(0.95, 0.16, dust);
}`;

// motes: a box of dust wrapping round the camera; only the torch shows them
const MOTE_VERT = /* glsl */ `
${COMMON}
attribute vec4 aEmit;
varying vec3 vColor;
varying float vAlpha;
void main() {
  vec3 seed = aEmit.xyz;
  vec3 drift = vec3(sin(uTime * 0.07 + aEmit.w * 9.0), sin(uTime * 0.05 + aEmit.w * 4.0) * 0.6 - 0.15, cos(uTime * 0.06 + aEmit.w * 7.0)) * 0.035 * uTime;
  vec3 local = fract(seed + drift / ${MOTE_BOX.toFixed(1)}) - 0.5;
  vec3 p = cameraPosition + local * ${MOTE_BOX.toFixed(1)};
  vec3 light = torchAt(p);
  float l = dot(light, vec3(0.3, 0.5, 0.2));
  vec4 mv = viewMatrix * vec4(p, 1.0);
  float near = smoothstep(0.4, 1.4, -mv.z) * (1.0 - smoothstep(${(MOTE_BOX * 0.32).toFixed(1)}, ${(MOTE_BOX * 0.5).toFixed(1)}, length(local * ${MOTE_BOX.toFixed(1)})));
  float twinkle = 0.6 + 0.4 * sin(uTime * (1.5 + aEmit.w * 3.0) + aEmit.w * 40.0);
  vAlpha = clamp(l * 0.9, 0.0, 1.0) * near * twinkle;
  gl_PointSize = vAlpha > 0.003 ? clamp(0.03 * uPxScale / max(0.3, -mv.z), 1.0, 8.0) : 0.0;
  gl_Position = vAlpha > 0.003 ? projectionMatrix * mv : vec4(2.0, 2.0, 2.0, 1.0);
  vColor = display(vec3(0.9, 0.86, 0.78) * light * 0.35, p);
}`;

function hash(n) {
  const x = Math.sin(n * 12.9898 + 78.233) * 43758.5453;
  return x - Math.floor(x);
}

export class Particles {
  /** @param {import('./index.js').Engine} engine */
  constructor(engine) {
    this.engine = engine;
    this.world = engine.world;
    this.shared = engine.shared;
    this.group = new THREE.Group();
    this.group.name = 'Particles';
    this.world.scene.add(this.group);
    this.systems = [];
    this.uniforms = {
      uTime: { value: 0 },
      uPxScale: { value: 400 },
      uFlPos: this.shared.uFlPos, uFlDir: this.shared.uFlDir, uFlInner: this.shared.uFlInner, uFlOuter: this.shared.uFlOuter,
      uFlCone: this.shared.uFlCone, uFlRange: this.shared.uFlRange, uFalloffK: this.shared.uFalloffK,
      uExposure: this.shared.uExposure, uFogColor: this.shared.uFogColor, uFogDensity: this.shared.uFogDensity,
    };
    this.bursts = [];
    this.burstCursor = 0;
    this.time = 0;
    this._built = false;
    // a listener only: it never throws into the bus the Creature hears through
    this._unsubscribe = engine.noise ? engine.noise.on((e) => {
      try {
        this._onNoise(e);
      } catch (err) {
        console.warn('[particles] grit', err);
      }
    }) : null;
  }

  /** Builds the systems on first use (the probes and rays it needs are ready by then). */
  _build() {
    this._built = true;
    const meta = this.world.meta;
    // steam
    const vents = (meta.emitters || []).filter((e) => e.kind === 'Steam');
    const byLevel = groupBy(vents, (v) => v.level);
    for (const [level, list] of byLevel) {
      const n = list.length * STEAM_PER_VENT;
      const emit = new Float32Array(n * 4);
      const dir = new Float32Array(n * 4);
      const amb = new Float32Array(n * 4);
      let i = 0;
      // particle-major: the first k particles of the buffer cover every vent (a smaller tier draws fewer per vent)
      for (let p = 0; p < STEAM_PER_VENT; p++) {
        for (let v = 0; v < list.length; v++, i++) {
          const e = list[v];
          const a = this._ambient(e.pos, level);
          emit.set([e.pos[0], e.pos[1], e.pos[2], v], i * 4);
          dir.set([e.dir[0], e.dir[1], e.dir[2], hash(i * 1.37 + v * 7.1)], i * 4);
          amb.set([a.r, a.g, a.b, hash(i * 3.11 + 0.5) * 100], i * 4);
        }
      }
      this._system('Steam', level, STEAM_VERT, { aEmit: emit, aDir: dir, aAmb: amb }, n, THREE.NormalBlending);
    }
    // drips
    const drips = (meta.anchors || []).filter((a) => a.kind === 'DripPipe');
    for (const [level, list] of groupBy(drips, (a) => a.level)) {
      const n = list.length * DRIPS_PER_PIPE;
      const emit = new Float32Array(n * 4);
      const dir = new Float32Array(n * 4);
      const amb = new Float32Array(n * 4);
      let i = 0;
      const pipes = list.map((a, k) => {
        const pos = new THREE.Vector3(a.cframe[0], a.cframe[1], a.cframe[2]);
        const hit = this.world.raycast(pos.clone().add(_up.clone().multiplyScalar(-0.2)), _downV, 40, { ignoreEntities: true });
        return { pos, floor: hit ? hit.point.y : pos.y - 10, period: 1.1 + hash(k * 4.7) * 1.6, phase: hash(k * 2.3), amb: this._ambient(a.cframe, level) };
      });
      for (let p = 0; p < DRIPS_PER_PIPE; p++) {
        for (let k = 0; k < pipes.length; k++, i++) {
          const d = pipes[k];
          emit.set([d.pos.x, d.pos.y, d.pos.z, hash(k * 9.7)], i * 4);
          dir.set([d.floor, d.period, p, d.phase], i * 4);
          amb.set([d.amb.r, d.amb.g, d.amb.b, 0], i * 4);
        }
      }
      this._system('Drips', level, DRIP_VERT, { aEmit: emit, aDir: dir, aAmb: amb }, n, THREE.AdditiveBlending, true);
    }
    // grit bursts
    {
      const n = GRIT_BURSTS * GRIT_PER_BURST;
      const emit = new Float32Array(n * 4);
      let i = 0;
      for (let p = 0; p < GRIT_PER_BURST; p++) {
        for (let b = 0; b < GRIT_BURSTS; b++, i++) emit.set([b, hash(i * 1.1), hash(i * 2.9 + 3), hash(i * 5.3 + 1)], i * 4);
      }
      this.gritUniforms = {
        uBurst: { value: Array.from({ length: GRIT_BURSTS }, () => new THREE.Vector4(0, -1e5, 0, -1e5)) },
        uBurstY: { value: Array.from({ length: GRIT_BURSTS }, () => new THREE.Vector4()) },
        uBurstAmb: { value: Array.from({ length: GRIT_BURSTS }, () => new THREE.Vector3()) },
      };
      this._system('Grit', null, GRIT_VERT, { aEmit: emit }, n, THREE.NormalBlending, false, this.gritUniforms);
    }
    // torch motes
    {
      const emit = new Float32Array(MOTES * 4);
      for (let i = 0; i < MOTES; i++) emit.set([hash(i * 1.3), hash(i * 2.7 + 1), hash(i * 4.1 + 2), hash(i * 7.7 + 3)], i * 4);
      this._system('Motes', null, MOTE_VERT, { aEmit: emit }, MOTES, THREE.AdditiveBlending, true);
    }
  }

  /**
   * The level's baked probe light at a point (its static grid: no zone lookups, whose cache gameplay shares, and no
   * live flicker).
   */
  _ambient(pos, level) {
    const p = Array.isArray(pos) ? _v.set(pos[0], pos[1], pos[2]) : pos;
    const grid = this.world.decoded.probes && (this.world.decoded.probes[level] || this.world.decoded.probes.Stairwells);
    if (!grid) return { r: 0.03, g: 0.03, b: 0.035 };
    sampleProbe(grid, p.x, p.y, p.z, _rgb, null);
    return { r: _rgb[0] * 0.6 + 0.01, g: _rgb[1] * 0.6 + 0.01, b: _rgb[2] * 0.6 + 0.012 };
  }

  _system(name, level, vert, attributes, count, blending, additive = false, extra = {}) {
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(new Float32Array(count * 3), 3));
    for (const [k, v] of Object.entries(attributes)) g.setAttribute(k, new THREE.BufferAttribute(v, 4));
    const mat = new THREE.ShaderMaterial({
      uniforms: { ...this.uniforms, ...extra },
      vertexShader: vert,
      fragmentShader: SOFT_FRAG,
      transparent: true,
      depthWrite: false,
      blending: additive ? THREE.AdditiveBlending : blending,
    });
    const points = new THREE.Points(g, mat);
    points.frustumCulled = false;
    points.renderOrder = 12;
    points.visible = false;
    points.name = `Particles:${name}${level ? `:${level}` : ''}`;
    this.group.add(points);
    this.systems.push({ name, level, points, count });
  }

  _onNoise(e) {
    if (!GRIT_KINDS.has(e.kind) || !this._built) return;
    const budget = this.engine.quality.budget;
    if (!budget.particles) return;
    const cam = this.engine.renderer.camera.position;
    if (e.position.distanceTo(cam) > GRIT_REACH) return;
    // the ceiling over the noise (one ray up) and the floor under it
    const from = _v.copy(e.position).add(_lift);
    const up = this.world.raycast(from, _upV, 24, { ignoreEntities: true });
    if (!up) return;
    const down = this.world.raycast(from, _downV, 12, { ignoreEntities: true });
    const slot = this.burstCursor++ % GRIT_BURSTS;
    const u = this.gritUniforms;
    u.uBurst.value[slot].set(e.position.x, up.point.y, e.position.z, this.time);
    u.uBurstY.value[slot].set(down ? down.point.y : e.position.y, up.point.y, 0, 0);
    const a = this._ambient(up.point, e.level);
    u.uBurstAmb.value[slot].set(a.r * 1.5, a.g * 1.5, a.b * 1.5);
  }

  /** Per frame: time, which systems draw (the tier, the levels in focus) and how many of their particles. */
  update(dt, camera, film, seen) {
    const budget = this.engine.quality.budget;
    const on = !!budget.particles && budget.particleScale > 0;
    this.time += dt;
    this.uniforms.uTime.value = this.time;
    if (!on) {
      for (const s of this.systems) s.points.visible = false;
      return;
    }
    if (!this._built) this._build();
    const renderer = this.engine.renderer;
    const h = renderer.stats.internal[1] || 720;
    this.uniforms.uPxScale.value = h / (2 * Math.tan((camera.fov * Math.PI) / 360));
    const focus = this.world.focus;
    const torch = this.shared.uFlInner.value.lengthSq() > 1e-6;
    for (const s of this.systems) {
      let visible = s.level ? focus.has(s.level) : true;
      if (s.name === 'Motes') visible = torch && film.dust > 0.01;
      s.points.visible = visible;
      if (visible) s.points.geometry.setDrawRange(0, Math.max(1, Math.round(s.count * budget.particleScale)));
    }
  }
}

function groupBy(list, key) {
  const out = new Map();
  for (const x of list) {
    const k = key(x);
    if (!out.has(k)) out.set(k, []);
    out.get(k).push(x);
  }
  return out;
}

const _v = new THREE.Vector3();
const _rgb = [0, 0, 0];
const _up = new THREE.Vector3(0, 1, 0);
const _upV = new THREE.Vector3(0, 1, 0);
const _downV = new THREE.Vector3(0, -1, 0);
const _lift = new THREE.Vector3(0, 1.5, 0);
