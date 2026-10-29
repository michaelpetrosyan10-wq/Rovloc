// Sky: the storm deck over the roof and the street (LightingRig's night sky: ClockTime 0.5, Terrain clouds at cover
// 0.93 / density 0.78 in CloudColor (38, 40, 46)). A camera-centred dome drawn behind everything when the exterior is
// in focus: a dark cloud ceiling with slow value-noise structure, fading into the level film's haze toward the
// horizon. Lightning lights the deck (FLASH_CLOUDS) with the flash envelope, as the Roblox flash recolours the clouds.

import * as THREE from 'three';

const CLOUD = [38 / 255, 40 / 255, 46 / 255]; // LightingRig.Baseline.CloudColor (display)
const FLASH_CLOUDS = [214 / 255, 220 / 255, 242 / 255];

const VERT = /* glsl */ `
varying vec3 vDir;
void main() {
  vDir = normalize(position);
  vec4 p = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  gl_Position = p.xyww; // on the far plane
}`;

const FRAG = /* glsl */ `
uniform vec3 uCloud;
uniform vec3 uHaze;
uniform vec3 uFlashColor;
uniform float uFlash;
uniform float uTime;
varying vec3 vDir;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}
void main() {
  vec3 d = normalize(vDir);
  float up = clamp(d.y, -0.2, 1.0);
  vec2 uv = d.xz / max(0.12, d.y + 0.15) * 1.6 + vec2(uTime * 0.004, uTime * 0.002);
  float n = vnoise(uv) * 0.55 + vnoise(uv * 2.3) * 0.3 + vnoise(uv * 5.1) * 0.15;
  vec3 deck = uCloud * (0.55 + 0.75 * n);
  vec3 col = mix(uHaze, deck, smoothstep(-0.05, 0.35, up));
  col += uFlashColor * uFlash * (0.35 + 0.65 * n) * smoothstep(-0.1, 0.25, up);
  gl_FragColor = vec4(col, 1.0);
}`;

export class Sky {
  /** @param {import('./index.js').Engine} engine */
  constructor(engine) {
    this.engine = engine;
    this.material = new THREE.ShaderMaterial({
      uniforms: {
        uCloud: { value: new THREE.Color(...CLOUD) },
        uHaze: { value: new THREE.Color() },
        uFlashColor: { value: new THREE.Color(...FLASH_CLOUDS) },
        uFlash: { value: 0 },
        uTime: { value: 0 },
      },
      vertexShader: VERT,
      fragmentShader: FRAG,
      side: THREE.BackSide,
      depthWrite: false,
      depthTest: true,
    });
    this.mesh = new THREE.Mesh(new THREE.SphereGeometry(500, 24, 12), this.material);
    this.mesh.frustumCulled = false;
    this.mesh.renderOrder = -100;
    this.mesh.visible = false;
    engine.world.scene.add(this.mesh);
  }

  /**
   * @param {THREE.Camera} camera
   * @param {Set<string>} focus
   * @param {{hazeColor: number[]}} film
   */
  update(camera, focus, film) {
    const on = focus.has('Exterior') || focus.has('Level5_Roof');
    this.mesh.visible = on;
    if (!on) return;
    this.mesh.position.copy(camera.position);
    const u = this.material.uniforms;
    // the horizon reads as the haze lit faintly by the city: the film colour, display-encoded
    u.uHaze.value.setRGB(film.hazeColor[0], film.hazeColor[1], film.hazeColor[2]);
    u.uFlash.value = this.engine.lighting.skyFlash;
    u.uTime.value = this.engine.loop.realTime;
  }
}
