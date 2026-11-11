// Renderer: the WebGL2 context and the frame, scaled to the graphics tier (quality.js).
//
// Frame:
//   1. shadows: the torch's shadow map (every tier but Potato; 2048 with soft PCF at Max) and, at Max / High / Medium,
//      the fixture shadow atlas: the nearest lit fixtures render the moving casters (the Creature) into a tile each;
//   2. the world into the scene target (its depth kept as a texture when a depth effect runs);
//   3. depth effects (Max, High): SSAO (full / half resolution, bilateral blur) and the ray-marched torch cone (in-
//      scattering along each pixel's ray, cut by the torch's shadow map: the Creature's shape in the beam), composited
//      into the main target;
//   4. the first-person viewmodel over it (depth cleared);
//   5. bloom: a bright pass and a chain of blurred levels (3 at Max, 2 High, 1 Medium);
//   6. post to the canvas: FXAA, a slight chromatic aberration, contrast, saturation, lift, tint (level grade x panic x
//      lightning; Potato's flat grade keeps only its luminance), vignette, grain, the scares' tear.
// Materials already output tone-mapped display values, so the targets are 8-bit. The internal resolution follows
// quality.internalSize (Max 100 %, Max+ 150 %, Potato 50-70 % of 720p, dynamic in between).

import * as THREE from 'three';
import { createDepthMaterial, MAX_FIX } from './materials.js';
import { SCREEN_FX_DECL, SCREEN_FX_FINISH, SCREEN_FX_SAMPLE, screenFxUniforms } from './screenfx.js';

const POST_VERT = /* glsl */ `
precision highp float;
in vec3 position;
out vec2 vUv;
void main() { vUv = position.xy * 0.5 + 0.5; gl_Position = vec4(position.xy, 0.0, 1.0); }
`;

const IGN = /* glsl */ `
float ign(vec2 p) { return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))); }
`;

const ACES = /* glsl */ `
vec3 aces(vec3 x) { return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0); }
vec3 encodeSrgb(vec3 c) {
  return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, c * 12.92, vec3(lessThanEqual(c, vec3(0.0031308))));
}
`;

// FXAA (Lottes; the edge walk after Jasper Flick's port, as three's FXAAShader), on the display-encoded frame.
const FXAA = /* glsl */ `
float fxLuma(vec2 uv) { return dot(texture(tScene, uv).rgb, vec3(0.3, 0.59, 0.11)); }
vec3 fxaa(vec2 uv, vec2 px) {
  vec3 mid = texture(tScene, uv).rgb;
  float m = dot(mid, vec3(0.3, 0.59, 0.11));
  float n = fxLuma(uv + vec2(0.0, px.y));
  float e = fxLuma(uv + vec2(px.x, 0.0));
  float s = fxLuma(uv - vec2(0.0, px.y));
  float w = fxLuma(uv - vec2(px.x, 0.0));
  float hi = max(max(max(max(n, e), s), w), m);
  float lo = min(min(min(min(n, e), s), w), m);
  float contrast = hi - lo;
  if (contrast < max(0.0312, 0.063 * hi)) return mid;
  float ne = fxLuma(uv + px);
  float nw = fxLuma(uv + vec2(-px.x, px.y));
  float se = fxLuma(uv + vec2(px.x, -px.y));
  float sw = fxLuma(uv - px);
  float f = (2.0 * (n + e + s + w) + ne + nw + se + sw) / 12.0;
  f = clamp(abs(f - m) / contrast, 0.0, 1.0);
  float pixelBlend = smoothstep(0.0, 1.0, f);
  pixelBlend *= pixelBlend;
  float horizontal = abs(n + s - 2.0 * m) * 2.0 + abs(ne + se - 2.0 * e) + abs(nw + sw - 2.0 * w);
  float vertical = abs(e + w - 2.0 * m) * 2.0 + abs(ne + nw - 2.0 * n) + abs(se + sw - 2.0 * s);
  bool isH = horizontal >= vertical;
  float pL = isH ? n : e;
  float nL = isH ? s : w;
  float pG = abs(pL - m);
  float nG = abs(nL - m);
  float stepLen = isH ? px.y : px.x;
  float opposite = pL;
  float gradient = pG;
  if (pG < nG) { stepLen = -stepLen; opposite = nL; gradient = nG; }
  vec2 uvEdge = uv;
  vec2 edgeStep;
  if (isH) { uvEdge.y += stepLen * 0.5; edgeStep = vec2(px.x, 0.0); }
  else { uvEdge.x += stepLen * 0.5; edgeStep = vec2(0.0, px.y); }
  float edgeL = (m + opposite) * 0.5;
  float threshold = gradient * 0.25;
  const float STEPS[6] = float[6](1.0, 1.5, 2.0, 2.0, 2.0, 4.0);
  vec2 puv = uvEdge + edgeStep * STEPS[0];
  float pD = fxLuma(puv) - edgeL;
  bool pEnd = abs(pD) >= threshold;
  for (int i = 1; i < 6 && !pEnd; i++) { puv += edgeStep * STEPS[i]; pD = fxLuma(puv) - edgeL; pEnd = abs(pD) >= threshold; }
  if (!pEnd) puv += edgeStep * 8.0;
  vec2 nuv = uvEdge - edgeStep * STEPS[0];
  float nD = fxLuma(nuv) - edgeL;
  bool nEnd = abs(nD) >= threshold;
  for (int i = 1; i < 6 && !nEnd; i++) { nuv -= edgeStep * STEPS[i]; nD = fxLuma(nuv) - edgeL; nEnd = abs(nD) >= threshold; }
  if (!nEnd) nuv -= edgeStep * 8.0;
  float pDist = isH ? puv.x - uv.x : puv.y - uv.y;
  float nDist = isH ? uv.x - nuv.x : uv.y - nuv.y;
  float shortest = pDist <= nDist ? pDist : nDist;
  bool sign_ = pDist <= nDist ? pD >= 0.0 : nD >= 0.0;
  float edgeBlend = sign_ == (m - edgeL >= 0.0) ? 0.0 : 0.5 - shortest / (pDist + nDist);
  float blend = max(pixelBlend, edgeBlend);
  vec2 o = isH ? vec2(0.0, stepLen * blend) : vec2(stepLen * blend, 0.0);
  return texture(tScene, uv + o).rgb;
}
`;

const POST_FRAG = /* glsl */ `
precision highp float;
in vec2 vUv;
out vec4 fragColor;
uniform sampler2D tScene;
uniform sampler2D tBloom;
uniform sampler2D tBloom2;
uniform sampler2D tBloom3;
uniform vec3 uBloomLevels; // weight per bloom level
uniform float uBloom;
uniform float uContrast;
uniform float uSaturation;
uniform float uLift;
uniform vec3 uTint;
uniform float uVignette;
uniform float uVignetteDepth;
uniform float uAspect;
uniform float uGrain;
uniform float uTime;
uniform vec4 uOverlay; // rgb colour, a amount (flashes)
uniform float uBlur;   // 0..1 cheap radial softening (panic depth of field stand-in)
uniform vec2 uTexel;
uniform float uFxaa;   // 1: FXAA on the scene fetch
uniform float uChroma; // chromatic aberration at the frame's edge (uv)
uniform float uFlat;   // 1: Potato's flat grade (the tint's luminance, pixel by pixel; no colour cast)
uniform vec3 uPanicTint; // panic's red (and the lightning) over the grade, on every tier
${SCREEN_FX_DECL}
const float CONTRAST_PIVOT = 0.16;

float edgeAlpha(float x, float depth) {
  float t = clamp(x / max(depth, 1e-4), 0.0, 1.0);
  float tr = t < 0.45 ? mix(0.0, 0.55, t / 0.45) : mix(0.55, 1.0, (t - 0.45) / 0.55);
  return 1.0 - tr;
}
float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
${FXAA}
// The scene fetch the screen-fx hook uses when the frame is not torn: FXAA, then the slight lens fringe.
vec3 sceneSample(vec2 uv) {
  vec3 c = uFxaa > 0.5 ? fxaa(uv, uTexel) : texture(tScene, uv).rgb;
  if (uChroma > 0.0) {
    vec2 d = (uv - 0.5) * uChroma * dot(uv - 0.5, uv - 0.5) * 4.0;
    c.r = mix(c.r, texture(tScene, uv + d).r, 0.85);
    c.b = mix(c.b, texture(tScene, uv - d).b, 0.85);
  }
  return c;
}

void main() {
${SCREEN_FX_SAMPLE}
  if (uBlur > 0.001) {
    vec2 d = (vUv - 0.5);
    float r = dot(d, d) * 4.0 * uBlur;
    vec2 o = uTexel * 2.0 * r;
    c = (c * 2.0 + texture(tScene, vUv + vec2(o.x, 0.0)).rgb + texture(tScene, vUv - vec2(o.x, 0.0)).rgb
      + texture(tScene, vUv + vec2(0.0, o.y)).rgb + texture(tScene, vUv - vec2(0.0, o.y)).rgb) / 6.0;
  }
  vec3 bloom = texture(tBloom, vUv).rgb * uBloomLevels.x;
  if (uBloomLevels.y > 0.0) bloom += texture(tBloom2, vUv).rgb * uBloomLevels.y;
  if (uBloomLevels.z > 0.0) bloom += texture(tBloom3, vUv).rgb * uBloomLevels.z;
  c += bloom * uBloom;
  c = mix(c, uOverlay.rgb, uOverlay.a);
  c += uLift;
  // Contrast as an S-curve through a dark-frame pivot. LightingMood's film raises contrast with the blacks lifted
  // "so the gaps between pools read as dark grey-blue, not void": pivoting at mid-grey would crush this night-time
  // frame (most of it sits below 0.15) to black, so the pivot sits where the frame's lit surfaces are. Two power
  // curves meet at the pivot with slope 1 + contrast; black stays black and white stays white (no clipped hotspots).
  c = clamp(c, 0.0, 1.0);
  vec3 k = vec3(max(0.2, 1.0 + uContrast));
  vec3 lo = CONTRAST_PIVOT * pow(c / CONTRAST_PIVOT, k);
  vec3 hi = 1.0 - (1.0 - CONTRAST_PIVOT) * pow((1.0 - c) / (1.0 - CONTRAST_PIVOT), k);
  c = mix(lo, hi, step(CONTRAST_PIVOT, c));
  float l = dot(c, vec3(0.299, 0.587, 0.114));
  c = mix(vec3(l), c, 1.0 + uSaturation);
  // the area grade's tint; the flat grade keeps exactly the brightness the tint gives each pixel, without its cast
  vec3 tinted = c * uTint;
  float lt = dot(tinted, vec3(0.299, 0.587, 0.114));
  float l0 = dot(c, vec3(0.299, 0.587, 0.114));
  c = mix(tinted, c * (lt / max(l0, 1e-5)), uFlat);
  c *= uPanicTint;
  float side = uVignetteDepth * 0.55;
  float a = edgeAlpha(vUv.y, uVignetteDepth);
  float b = edgeAlpha(1.0 - vUv.y, uVignetteDepth);
  float lft = edgeAlpha(vUv.x, side);
  float rgt = edgeAlpha(1.0 - vUv.x, side);
  float keep = (1.0 - a * uVignette) * (1.0 - b * uVignette) * (1.0 - lft * uVignette) * (1.0 - rgt * uVignette);
  c *= keep;
  float n = hash(vUv * vec2(1931.0, 1213.0) + fract(uTime * 7.31)) - 0.5;
  c += n * uGrain;
${SCREEN_FX_FINISH}
  fragColor = vec4(clamp(c, 0.0, 1.0), 1.0);
}
`;

const BRIGHT_FRAG = /* glsl */ `
precision highp float;
in vec2 vUv;
out vec4 fragColor;
uniform sampler2D tScene;
uniform float uThreshold;
uniform vec2 uTexel;
void main() {
  // a 4-tap box over the source (it is downsampled 4x): no shimmering single bright texels
  vec3 c = (texture(tScene, vUv + uTexel * vec2(-1.0, -1.0)).rgb + texture(tScene, vUv + uTexel * vec2(1.0, -1.0)).rgb
    + texture(tScene, vUv + uTexel * vec2(-1.0, 1.0)).rgb + texture(tScene, vUv + uTexel * vec2(1.0, 1.0)).rgb) * 0.25;
  float l = max(c.r, max(c.g, c.b));
  fragColor = vec4(c * smoothstep(uThreshold, 1.0, l), 1.0);
}
`;

const BLUR_FRAG = /* glsl */ `
precision highp float;
in vec2 vUv;
out vec4 fragColor;
uniform sampler2D tSrc;
uniform vec2 uDir;
void main() {
  vec3 c = texture(tSrc, vUv).rgb * 0.227027;
  c += texture(tSrc, vUv + uDir * 1.3846).rgb * 0.316216;
  c += texture(tSrc, vUv - uDir * 1.3846).rgb * 0.316216;
  c += texture(tSrc, vUv + uDir * 3.2308).rgb * 0.070270;
  c += texture(tSrc, vUv - uDir * 3.2308).rgb * 0.070270;
  fragColor = vec4(c, 1.0);
}
`;

const COPY_FRAG = /* glsl */ `
precision highp float;
in vec2 vUv;
out vec4 fragColor;
uniform sampler2D tSrc;
uniform vec2 uTexel;
void main() {
  fragColor = vec4((texture(tSrc, vUv + uTexel * vec2(-0.5, -0.5)).rgb + texture(tSrc, vUv + uTexel * vec2(0.5, -0.5)).rgb
    + texture(tSrc, vUv + uTexel * vec2(-0.5, 0.5)).rgb + texture(tSrc, vUv + uTexel * vec2(0.5, 0.5)).rgb) * 0.25, 1.0);
}
`;

// Screen-space ambient occlusion: view positions from the depth buffer, a normal from the flatter neighbour on each
// axis, SSAO_SAMPLES points of a hemisphere (a golden-angle spiral rotated per pixel) at most uRadius studs away.
const SSAO_FRAG = /* glsl */ `
precision highp float;
in vec2 vUv;
out vec4 fragColor;
uniform sampler2D tDepth;
uniform mat4 uProj;
uniform mat4 uProjInv;
uniform vec2 uTexel;
uniform float uRadius;
uniform float uIntensity;
${IGN}
vec3 viewPos(vec2 uv) {
  float d = texture(tDepth, uv).r;
  vec4 p = uProjInv * vec4(uv * 2.0 - 1.0, d * 2.0 - 1.0, 1.0);
  return p.xyz / p.w;
}
void main() {
  float d = texture(tDepth, vUv).r;
  if (d >= 1.0) { fragColor = vec4(1.0); return; }
  vec3 P = viewPos(vUv);
  vec3 pr = viewPos(vUv + vec2(uTexel.x, 0.0));
  vec3 pl = viewPos(vUv - vec2(uTexel.x, 0.0));
  vec3 pu = viewPos(vUv + vec2(0.0, uTexel.y));
  vec3 pd = viewPos(vUv - vec2(0.0, uTexel.y));
  vec3 dx = abs(pr.z - P.z) < abs(P.z - pl.z) ? pr - P : P - pl;
  vec3 dy = abs(pu.z - P.z) < abs(P.z - pd.z) ? pu - P : P - pd;
  vec3 N = normalize(cross(dx, dy));
  vec3 T = normalize(abs(N.y) < 0.95 ? cross(N, vec3(0.0, 1.0, 0.0)) : cross(N, vec3(1.0, 0.0, 0.0)));
  vec3 B = cross(N, T);
  float rot = 6.2831853 * ign(gl_FragCoord.xy);
  float radius = uRadius * clamp(-P.z / 6.0, 0.35, 1.0); // smaller near the lens (hands, close walls)
  float occ = 0.0;
  for (int i = 0; i < SSAO_SAMPLES; i++) {
    float fi = (float(i) + 0.5) / float(SSAO_SAMPLES);
    float phi = float(i) * 2.39996323 + rot;
    float z = sqrt(1.0 - fi);
    float r = sqrt(fi);
    float len = mix(0.15, 1.0, fi * fi);
    vec3 k = (T * (cos(phi) * r) + B * (sin(phi) * r) + N * z) * (len * radius);
    vec3 S = P + k;
    vec4 c = uProj * vec4(S, 1.0);
    vec2 suv = c.xy / c.w * 0.5 + 0.5;
    if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) continue;
    float sz = viewPos(suv).z;
    float range = smoothstep(0.0, 1.0, radius / max(abs(P.z - sz), 1e-3));
    occ += (sz >= S.z + 0.02 ? 1.0 : 0.0) * range;
  }
  float ao = clamp(1.0 - occ / float(SSAO_SAMPLES), 0.0, 1.0);
  ao = pow(ao, uIntensity);
  // fade out in the distance (the haze owns it there)
  ao = mix(ao, 1.0, smoothstep(45.0, 110.0, -P.z));
  fragColor = vec4(ao, -P.z, 0.0, 1.0);
}
`;

// depth-aware separable blur of the occlusion (r: ao, g: view depth)
const AO_BLUR_FRAG = /* glsl */ `
precision highp float;
in vec2 vUv;
out vec4 fragColor;
uniform sampler2D tSrc;
uniform vec2 uDir;
void main() {
  vec2 c = texture(tSrc, vUv).rg;
  float sum = c.r;
  float wsum = 1.0;
  for (int i = -3; i <= 3; i++) {
    if (i == 0) continue;
    vec2 s = texture(tSrc, vUv + uDir * float(i)).rg;
    float w = exp(-abs(s.g - c.g) * 4.0 / max(c.g * 0.05, 0.05)) * (1.0 - abs(float(i)) / 4.5);
    sum += s.r * w;
    wsum += w;
  }
  fragColor = vec4(sum / wsum, c.g, 0.0, 1.0);
}
`;

// The torch cone as a volume: VOL_STEPS samples along each pixel's ray up to the surface (at most 60 studs), each lit by
// the two cones with the bake's falloff and the torch's shadow map, scattered isotropically by the level's haze.
const VOL_FRAG = /* glsl */ `
precision highp float;
in vec2 vUv;
out vec4 fragColor;
uniform sampler2D tDepth;
uniform sampler2D uShadowMap;
uniform mat4 uShadowMatrix;
uniform float uShadowOn;
uniform mat4 uProjInv;
uniform mat4 uViewInv;
uniform vec3 uCamPos;
uniform vec3 uFlPos;
uniform vec3 uFlDir;
uniform vec3 uFlInner;
uniform vec3 uFlOuter;
uniform vec4 uFlCone;
uniform vec2 uFlRange;
uniform float uFalloffK;
uniform float uDensity;
uniform float uExposure;
${IGN}
${ACES}
float falloff(float d, float range) {
  float x = clamp(d / range, 0.0, 1.0);
  float w = 1.0 - x * x;
  return (w * w) / (1.0 + uFalloffK * d * d);
}
void main() {
  float d = texture(tDepth, vUv).r;
  vec4 vp = uProjInv * vec4(vUv * 2.0 - 1.0, d * 2.0 - 1.0, 1.0);
  vp /= vp.w;
  vec3 wp = (uViewInv * vec4(vp.xyz, 1.0)).xyz;
  vec3 rd = wp - uCamPos;
  float len = length(rd);
  rd /= max(len, 1e-4);
  len = min(len, 60.0);
  float stepLen = len / float(VOL_STEPS);
  float jitter = ign(gl_FragCoord.xy);
  vec3 acc = vec3(0.0);
  for (int i = 0; i < VOL_STEPS; i++) {
    float t = (float(i) + jitter) * stepLen;
    vec3 x = uCamPos + rd * t;
    vec3 toX = x - uFlPos;
    float dist = length(toX);
    vec3 dir = toX / max(dist, 1e-4);
    float cosA = dot(dir, uFlDir);
    float inner = smoothstep(uFlCone.y, uFlCone.x, cosA) * falloff(dist, uFlRange.x);
    float outer = smoothstep(uFlCone.w, uFlCone.z, cosA) * falloff(dist, uFlRange.y);
    if (inner + outer <= 0.0) continue;
    float vis = 1.0;
    if (uShadowOn > 0.5) {
      vec4 sc = uShadowMatrix * vec4(x, 1.0);
      if (sc.w > 0.0) {
        vec3 p = sc.xyz / sc.w;
        if (p.x > 0.0 && p.x < 1.0 && p.y > 0.0 && p.y < 1.0 && p.z < 1.0) vis = (p.z - 0.0008) <= texture(uShadowMap, p.xy).r ? 1.0 : 0.0;
      }
    }
    acc += (uFlInner * inner + uFlOuter * outer) * vis;
  }
  acc *= uDensity * stepLen * 0.0796; // isotropic phase 1/4pi
  fragColor = vec4(encodeSrgb(aces(acc * uExposure)), 1.0);
}
`;

// scene x occlusion + the torch volume -> the main target
const COMPOSITE_FRAG = /* glsl */ `
precision highp float;
in vec2 vUv;
out vec4 fragColor;
uniform sampler2D tScene;
uniform sampler2D tAo;
uniform sampler2D tVol;
uniform float uAo;
uniform float uVol;
void main() {
  vec3 c = texture(tScene, vUv).rgb;
  if (uAo > 0.0) {
    float ao = texture(tAo, vUv).r;
    // the lights themselves and the brightest pools keep their glow
    float l = max(c.r, max(c.g, c.b));
    c *= mix(1.0, ao, uAo * (1.0 - smoothstep(0.55, 0.95, l)));
  }
  if (uVol > 0.0) c += texture(tVol, vUv).rgb * uVol;
  fragColor = vec4(c, 1.0);
}
`;

function fullscreen(frag, uniforms, defines = {}) {
  return new THREE.RawShaderMaterial({
    glslVersion: THREE.GLSL3,
    vertexShader: POST_VERT,
    fragmentShader: frag,
    uniforms,
    defines,
    depthTest: false,
    depthWrite: false,
  });
}

function colorTarget(depth = false, type = THREE.UnsignedByteType) {
  return new THREE.WebGLRenderTarget(4, 4, {
    depthBuffer: depth,
    type,
    minFilter: THREE.LinearFilter,
    magFilter: THREE.LinearFilter,
  });
}

const FIX_NEAR = 0.15;
// the torch volume's scattering, of the level haze's fog density: a visible beam, not a brighter frame
const VOL_DENSITY = 0.3;
const FIX_MARGIN = 1.15; // the shadow frustum's angular margin round the caster

export class Renderer {
  /**
   * @param {HTMLCanvasElement} canvas
   * @param {import('./quality.js').Quality} quality
   * @param {any} shared world material uniforms
   */
  constructor(canvas, quality, shared) {
    this.canvas = canvas;
    this.quality = quality;
    this.shared = shared;
    this.gl = new THREE.WebGLRenderer({
      canvas,
      antialias: false,
      alpha: false,
      depth: true,
      stencil: false,
      powerPreference: 'high-performance',
      preserveDrawingBuffer: false,
    });
    this.gl.autoClear = false;
    this.gl.outputColorSpace = THREE.LinearSRGBColorSpace;
    this.gl.toneMapping = THREE.NoToneMapping;
    this.gl.info.autoReset = false;
    this.gl.setClearColor(0x000000, 1);
    this.camera = new THREE.PerspectiveCamera(70, 16 / 9, 0.1, 900);
    this.camera.rotation.order = 'YXZ';
    this.baseFar = 900;
    this.viewScene = new THREE.Scene();
    // the world: colour + a depth texture (the depth effects read it)
    this.sceneTarget = colorTarget(true);
    this.sceneDepth = new THREE.DepthTexture(4, 4, THREE.UnsignedIntType);
    this.sceneDepth.minFilter = this.sceneDepth.magFilter = THREE.NearestFilter;
    this.sceneTarget.depthTexture = this.sceneDepth;
    // after the depth effects: their composite, then the viewmodel (its own depth buffer)
    this.mainTarget = colorTarget(true);
    // occlusion (r) and view depth (g) for the bilateral blur: half floats
    this.aoTarget = colorTarget(false, THREE.HalfFloatType);
    this.aoBlur = colorTarget(false, THREE.HalfFloatType);
    this.volTarget = colorTarget(false);
    this.bloomLevels = [0, 1, 2].map(() => ({ a: colorTarget(false), b: colorTarget(false) }));
    this.black = new THREE.DataTexture(new Uint8Array([0, 0, 0, 255]), 1, 1);
    this.black.needsUpdate = true;
    this.white = new THREE.DataTexture(new Uint8Array([255, 255, 255, 255]), 1, 1);
    this.white.needsUpdate = true;
    /** kept for tools that read the frame before the post pass */
    this.target = this.sceneTarget;

    const quad = new THREE.BufferGeometry();
    quad.setAttribute('position', new THREE.BufferAttribute(new Float32Array([-1, -1, 0, 3, -1, 0, -1, 3, 0]), 3));
    this.post = fullscreen(POST_FRAG, {
      tScene: { value: this.sceneTarget.texture },
      tBloom: { value: this.black },
      tBloom2: { value: this.black },
      tBloom3: { value: this.black },
      uBloomLevels: { value: new THREE.Vector3(1, 0, 0) },
      uBloom: { value: 0 },
      uContrast: { value: 0.2 },
      uSaturation: { value: -0.22 },
      uLift: { value: 0.015 },
      uTint: { value: new THREE.Color(1, 1, 1) },
      uVignette: { value: 0.32 },
      uVignetteDepth: { value: 0.2 },
      uAspect: { value: 1 },
      uGrain: { value: 0.035 },
      uTime: { value: 0 },
      uOverlay: { value: new THREE.Vector4(0, 0, 0, 0) },
      uBlur: { value: 0 },
      uTexel: { value: new THREE.Vector2(1 / 1280, 1 / 720) },
      uFxaa: { value: 0 },
      uChroma: { value: 0 },
      uFlat: { value: 0 },
      uPanicTint: { value: new THREE.Color(1, 1, 1) },
      ...screenFxUniforms(),
    });
    this.bright = fullscreen(BRIGHT_FRAG, { tScene: { value: this.sceneTarget.texture }, uThreshold: { value: 0.72 }, uTexel: { value: new THREE.Vector2() } });
    this.blur = fullscreen(BLUR_FRAG, { tSrc: { value: null }, uDir: { value: new THREE.Vector2() } });
    this.copy = fullscreen(COPY_FRAG, { tSrc: { value: null }, uTexel: { value: new THREE.Vector2() } });
    this.ssao = null; // built for the tier's sample count
    this.aoBlurMat = fullscreen(AO_BLUR_FRAG, { tSrc: { value: null }, uDir: { value: new THREE.Vector2() } });
    this.vol = null;
    this.composite = fullscreen(COMPOSITE_FRAG, {
      tScene: { value: this.sceneTarget.texture }, tAo: { value: this.white }, tVol: { value: this.black },
      uAo: { value: 0 }, uVol: { value: 0 },
    });
    this.quad = new THREE.Mesh(quad, this.post);
    this.quad.frustumCulled = false;
    this.postScene = new THREE.Scene();
    this.postScene.add(this.quad);
    this.postCamera = new THREE.Camera();

    // flashlight shadow map
    this.shadowCamera = new THREE.PerspectiveCamera(80, 1, 0.3, 60);
    this.shadowTarget = null;
    this.depthMaterial = createDepthMaterial(false);
    /** node-batch depth materials, one per node texture (entities share one, each creature has its own) */
    this.depthNodes = new Map();
    this._casters = [];
    this.shadowBias = new THREE.Matrix4().set(0.5, 0, 0, 0.5, 0, 0.5, 0, 0.5, 0, 0, 0.5, 0.5, 0, 0, 0, 1);
    // fixture shadows: an atlas of tiles, one per shadowed fixture
    this.fixTarget = null;
    this.fixCamera = new THREE.PerspectiveCamera(90, 1, FIX_NEAR, 30);
    this.fixShadows = [];

    this.width = 0;
    this.height = 0;
    this.stats = { calls: 0, triangles: 0, internal: [0, 0], fixtureShadows: 0, passes: '' };
    this._resize();
    window.addEventListener('resize', () => this._resize());
    quality.scaleChanged.connect(() => this._resizeTarget());
    quality.changed.connect(() => this._applyBudget());
    this._applyBudget();
  }

  /** Whether this tier reads the scene's depth after drawing it (SSAO, the torch volume). */
  get depthEffects() {
    const b = this.quality.budget;
    return !!b.ssao || b.volumetricSteps > 0;
  }

  _applyBudget() {
    const b = this.quality.budget;
    if (b.flashlightShadow && b.shadowMapSize > 0) {
      const size = b.shadowMapSize;
      if (!this.shadowTarget || this.shadowTarget.width !== size) {
        if (this.shadowTarget) this.shadowTarget.dispose();
        const depth = new THREE.DepthTexture(size, size, THREE.UnsignedIntType);
        depth.minFilter = depth.magFilter = THREE.NearestFilter;
        this.shadowTarget = new THREE.WebGLRenderTarget(size, size, { depthBuffer: true, depthTexture: depth });
        this.shared.uShadowMap.value = depth;
        this.shared.uShadowTexel.value = 1 / size;
      }
    }
    this.shared.uShadowSoft.value = b.shadowSoftness || 1;
    const fixes = Math.min(MAX_FIX, b.fixtureShadows || 0);
    const fixSize = b.fixtureShadowSize || 0;
    if (fixes > 0 && fixSize > 0) {
      const w = fixSize * fixes;
      if (!this.fixTarget || this.fixTarget.width !== w || this.fixTarget.height !== fixSize) {
        if (this.fixTarget) this.fixTarget.dispose();
        const depth = new THREE.DepthTexture(w, fixSize, THREE.UnsignedIntType);
        depth.minFilter = depth.magFilter = THREE.NearestFilter;
        this.fixTarget = new THREE.WebGLRenderTarget(w, fixSize, { depthBuffer: true, depthTexture: depth });
        this.fixTarget.scissorTest = true;
        this.shared.uFixAtlas.value = depth;
        this.shared.uFixTexel.value.set(1 / w, 1 / fixSize);
      }
    }
    if (b.ssao) {
      const samples = b.ssao === 'Full' ? 16 : 10;
      if (!this.ssao || this.ssao.defines.SSAO_SAMPLES !== String(samples)) {
        if (this.ssao) this.ssao.dispose();
        this.ssao = fullscreen(SSAO_FRAG, {
          tDepth: { value: this.sceneDepth }, uProj: { value: new THREE.Matrix4() }, uProjInv: { value: new THREE.Matrix4() },
          uTexel: { value: new THREE.Vector2() }, uRadius: { value: 1.4 }, uIntensity: { value: 1.6 },
        }, { SSAO_SAMPLES: String(samples) });
      }
    }
    if (b.volumetricSteps > 0) {
      const steps = String(b.volumetricSteps);
      if (!this.vol || this.vol.defines.VOL_STEPS !== steps) {
        if (this.vol) this.vol.dispose();
        const s = this.shared;
        this.vol = fullscreen(VOL_FRAG, {
          tDepth: { value: this.sceneDepth }, uShadowMap: s.uShadowMap, uShadowMatrix: s.uShadowMatrix, uShadowOn: s.uShadowOn,
          uProjInv: { value: new THREE.Matrix4() }, uViewInv: { value: new THREE.Matrix4() }, uCamPos: { value: new THREE.Vector3() },
          uFlPos: s.uFlPos, uFlDir: s.uFlDir, uFlInner: s.uFlInner, uFlOuter: s.uFlOuter, uFlCone: s.uFlCone, uFlRange: s.uFlRange,
          uFalloffK: s.uFalloffK, uDensity: { value: 0.004 }, uExposure: s.uExposure,
        }, { VOL_STEPS: steps });
      }
    }
    // the haze closes at the tier's view distance: nothing past it needs drawing
    const far = Number.isFinite(b.viewDistance) ? Math.min(this.baseFar, b.viewDistance * 1.6) : this.baseFar;
    if (this.camera.far !== far) {
      this.camera.far = far;
      this.camera.updateProjectionMatrix();
    }
    this.post.uniforms.uFxaa.value = b.aa === 'FXAA' ? 1 : 0;
    this.post.uniforms.uChroma.value = 0.0045 * (b.chroma || 0);
    this._resizeTarget();
  }

  _resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
    const w = Math.max(1, Math.floor(this.canvas.clientWidth || window.innerWidth));
    const h = Math.max(1, Math.floor(this.canvas.clientHeight || window.innerHeight));
    // resizing the canvas clears its drawing buffer: only touch it when the size really changed
    if (w === this.width && h === this.height && dpr === this.gl.getPixelRatio()) return;
    this.gl.setPixelRatio(dpr);
    this.gl.setSize(w, h, false);
    this.width = w;
    this.height = h;
    this.camera.aspect = w / h;
    this.camera.updateProjectionMatrix();
    this._resizeTarget();
  }

  _resizeTarget() {
    const b = this.quality.budget;
    const dpr = this.gl.getPixelRatio();
    const [iw, ih] = this.quality.internalSize(this.width * dpr, this.height * dpr);
    if (iw !== this.sceneTarget.width || ih !== this.sceneTarget.height) {
      this.sceneTarget.setSize(iw, ih);
      this.mainTarget.setSize(iw, ih);
      this.post.uniforms.uTexel.value.set(1 / iw, 1 / ih);
    }
    // bloom levels: quarter, eighth, sixteenth
    let bw = Math.max(16, iw >> 2);
    let bh = Math.max(16, ih >> 2);
    for (const lvl of this.bloomLevels) {
      if (lvl.a.width !== bw || lvl.a.height !== bh) {
        lvl.a.setSize(bw, bh);
        lvl.b.setSize(bw, bh);
      }
      bw = Math.max(8, bw >> 1);
      bh = Math.max(8, bh >> 1);
    }
    const aoScale = b.ssao === 'Full' ? 1 : 0.5;
    const aw = Math.max(16, Math.round(iw * aoScale));
    const ah = Math.max(16, Math.round(ih * aoScale));
    if (b.ssao && (this.aoTarget.width !== aw || this.aoTarget.height !== ah)) {
      this.aoTarget.setSize(aw, ah);
      this.aoBlur.setSize(aw, ah);
    }
    const vw = Math.max(16, iw >> 1);
    const vh = Math.max(16, ih >> 1);
    if (b.volumetricSteps > 0 && (this.volTarget.width !== vw || this.volTarget.height !== vh)) this.volTarget.setSize(vw, vh);
    this.stats.internal = [iw, ih];
  }

  /**
   * Renders one frame.
   * @param {THREE.Scene} scene the world
   * @param {{shadow?: {position: THREE.Vector3, direction: THREE.Vector3, fov: number, far: number}|null, time: number,
   *   fixtures?: Array<any>, haze?: number}} opts fixtures: the shadowed fixtures this frame (Lighting.shadowFixtures)
   */
  render(scene, opts) {
    const gl = this.gl;
    gl.info.reset();
    const b = this.quality.budget;
    this.post.uniforms.uTime.value = opts.time;
    this.shared.uTime.value = opts.time;
    const passes = [];

    // flashlight shadow
    const torchShadow = b.flashlightShadow && opts.shadow && this.shadowTarget;
    if (torchShadow) {
      const sc = this.shadowCamera;
      sc.position.copy(opts.shadow.position);
      sc.fov = opts.shadow.fov;
      sc.far = opts.shadow.far;
      sc.updateProjectionMatrix();
      _look.copy(opts.shadow.position).add(opts.shadow.direction);
      sc.up.set(0, 1, 0);
      if (Math.abs(opts.shadow.direction.y) > 0.99) sc.up.set(0, 0, 1);
      sc.lookAt(_look);
      sc.updateMatrixWorld();
      this.shared.uShadowMatrix.value.multiplyMatrices(this.shadowBias, sc.projectionMatrix)
        .multiply(sc.matrixWorldInverse);
      // casters draw depth only (node batches through their node frames); everything else sits the pass out
      const list = this._casters;
      list.length = 0;
      scene.traverseVisible((o) => {
        if (o.isMesh || o.isPoints) list.push(o);
      });
      for (const o of list) {
        const m = o.material;
        o.userData.mat = m;
        if (m.userData && m.userData.castShadow) {
          o.material = m.defines && 'NODES' in m.defines ? this._depthFor(m.uniforms.uNodeTex.value) : this.depthMaterial;
        }
        else o.visible = false;
      }
      gl.setRenderTarget(this.shadowTarget);
      gl.clear(true, true, false);
      gl.render(scene, sc);
      for (const o of list) {
        o.material = o.userData.mat;
        o.visible = true;
      }
      this.shared.uShadowOn.value = 1;
      passes.push('torch');
    } else {
      this.shared.uShadowOn.value = 0;
    }

    // fixture shadows of the moving casters
    this.stats.fixtureShadows = this._fixtureShadows(opts.fixtures || null, b);
    if (this.stats.fixtureShadows) passes.push(`fixtures${this.stats.fixtureShadows}`);

    // the world (cleared to the haze's colour: past the draw distance there is only haze)
    if (opts.clear) gl.setClearColor(opts.clear, 1);
    gl.setRenderTarget(this.sceneTarget);
    gl.clear(true, true, false);
    gl.render(scene, this.camera);
    gl.setClearColor(0x000000, 1);

    let src = this.sceneTarget;
    const camera = this.camera;
    if (this.depthEffects) {
      const comp = this.composite.uniforms;
      comp.uAo.value = 0;
      comp.uVol.value = 0;
      if (b.ssao && this.ssao) {
        const u = this.ssao.uniforms;
        u.uProj.value.copy(camera.projectionMatrix);
        u.uProjInv.value.copy(camera.projectionMatrixInverse);
        u.uTexel.value.set(1 / this.sceneTarget.width, 1 / this.sceneTarget.height);
        this._pass(this.ssao, this.aoTarget);
        this.aoBlurMat.uniforms.tSrc.value = this.aoTarget.texture;
        this.aoBlurMat.uniforms.uDir.value.set(1 / this.aoTarget.width, 0);
        this._pass(this.aoBlurMat, this.aoBlur);
        this.aoBlurMat.uniforms.tSrc.value = this.aoBlur.texture;
        this.aoBlurMat.uniforms.uDir.value.set(0, 1 / this.aoTarget.height);
        this._pass(this.aoBlurMat, this.aoTarget);
        comp.tAo.value = this.aoTarget.texture;
        comp.uAo.value = 0.85;
        passes.push('ssao');
      }
      if (b.volumetricSteps > 0 && this.vol && opts.shadow && this.shared.uFlInner.value.lengthSq() > 1e-6) {
        const u = this.vol.uniforms;
        u.uProjInv.value.copy(camera.projectionMatrixInverse);
        u.uViewInv.value.copy(camera.matrixWorld);
        u.uCamPos.value.setFromMatrixPosition(camera.matrixWorld);
        u.uDensity.value = Math.max(0, opts.haze ?? 0.007) * VOL_DENSITY;
        this._pass(this.vol, this.volTarget);
        comp.tVol.value = this.volTarget.texture;
        comp.uVol.value = 1;
        passes.push('volume');
      }
      comp.tScene.value = this.sceneTarget.texture;
      this._pass(this.composite, this.mainTarget);
      src = this.mainTarget;
    }

    // viewmodel over the world
    gl.setRenderTarget(src);
    if (this.viewScene.children.length) {
      gl.clearDepth();
      gl.render(this.viewScene, this.camera);
    }

    // bloom
    const levels = b.bloom || 0;
    const bu = this.post.uniforms;
    if (levels > 0) {
      const l0 = this.bloomLevels[0];
      this.bright.uniforms.tScene.value = src.texture;
      this.bright.uniforms.uTexel.value.set(1 / src.width, 1 / src.height);
      this._pass(this.bright, l0.a);
      this._blur(l0);
      for (let i = 1; i < levels; i++) {
        const prev = this.bloomLevels[i - 1];
        const cur = this.bloomLevels[i];
        this.copy.uniforms.tSrc.value = prev.a.texture;
        this.copy.uniforms.uTexel.value.set(1 / prev.a.width, 1 / prev.a.height);
        this._pass(this.copy, cur.a);
        this._blur(cur);
      }
      bu.tBloom.value = l0.a.texture;
      bu.tBloom2.value = levels > 1 ? this.bloomLevels[1].a.texture : this.black;
      bu.tBloom3.value = levels > 2 ? this.bloomLevels[2].a.texture : this.black;
      // the wider levels spread the same energy: the total glow stays about the single level's
      if (levels === 1) bu.uBloomLevels.value.set(1, 0, 0);
      else if (levels === 2) bu.uBloomLevels.value.set(0.62, 0.42, 0);
      else bu.uBloomLevels.value.set(0.5, 0.33, 0.24);
      passes.push(`bloom${levels}`);
    } else {
      bu.tBloom.value = this.black;
      bu.tBloom2.value = this.black;
      bu.tBloom3.value = this.black;
      bu.uBloom.value = 0;
    }

    // post to the canvas
    bu.tScene.value = src.texture;
    this.quad.material = this.post;
    gl.setRenderTarget(null);
    gl.render(this.postScene, this.postCamera);
    this.stats.calls = gl.info.render.calls;
    this.stats.triangles = gl.info.render.triangles;
    this.stats.passes = passes.join(' ');
  }

  _pass(material, target) {
    this.quad.material = material;
    this.gl.setRenderTarget(target);
    this.gl.render(this.postScene, this.postCamera);
  }

  _blur(level) {
    this.blur.uniforms.tSrc.value = level.a.texture;
    this.blur.uniforms.uDir.value.set(1 / level.a.width, 0);
    this._pass(this.blur, level.b);
    this.blur.uniforms.tSrc.value = level.b.texture;
    this.blur.uniforms.uDir.value.set(0, 1 / level.a.height);
    this._pass(this.blur, level.a);
  }

  /**
   * Renders each shadowed fixture's tile: a frustum from the lamp fitted round its caster, the caster's depth only.
   * @param {Array<{pos: THREE.Vector3, range: number, color: THREE.Vector3, cone: number, coneEdge: number,
   *   dir: THREE.Vector3|null, caster: any}>|null} fixtures
   */
  _fixtureShadows(fixtures, b) {
    const s = this.shared;
    const n = Math.min(MAX_FIX, b.fixtureShadows || 0);
    for (let i = 0; i < MAX_FIX; i++) s.uFixColor.value[i].set(0, 0, 0, -2);
    if (!n || !this.fixTarget || !fixtures || !fixtures.length) return 0;
    const gl = this.gl;
    const size = this.fixTarget.height;
    const cam = this.fixCamera;
    let done = 0;
    for (let i = 0; i < Math.min(n, fixtures.length); i++) {
      const f = fixtures[i];
      const bounds = f.caster.bounds;
      _toC.subVectors(bounds.center, f.pos);
      const d = _toC.length();
      const r = bounds.radius;
      cam.position.copy(f.pos);
      cam.up.set(0, 1, 0);
      if (d <= r * 1.05) {
        // the lamp inside the caster's bounds: look down the light's axis (a ceiling lamp: the floor)
        cam.fov = 150;
        _look.copy(f.pos).add(f.dir || _down);
      } else {
        cam.fov = Math.min(150, (2 * Math.asin(Math.min(0.999, r / d)) * 180) / Math.PI * FIX_MARGIN);
        _look.copy(bounds.center);
      }
      _dir.subVectors(_look, f.pos).normalize();
      if (Math.abs(_dir.y) > 0.99) cam.up.set(0, 0, 1);
      cam.near = FIX_NEAR;
      cam.far = Math.max(f.range, d + r) + 1;
      cam.updateProjectionMatrix();
      cam.lookAt(_look);
      cam.updateMatrixWorld();
      // draw the caster's depth into tile i
      const t = this.fixTarget;
      t.viewport.set(i * size, 0, size, size);
      t.scissor.set(i * size, 0, size, size);
      gl.setRenderTarget(t);
      gl.clear(false, true, false);
      const obj = f.caster.object;
      const swapped = [];
      obj.traverse((o) => {
        if (!o.isMesh) return;
        const m = o.material;
        if (!o.visible || !m || !m.userData || !m.userData.castShadow || !m.defines || !('NODES' in m.defines)) {
          if (o.visible) {
            swapped.push([o, m, true]);
            o.visible = false;
          }
          return;
        }
        swapped.push([o, m, false]);
        o.material = this._depthFor(m.uniforms.uNodeTex.value);
      });
      gl.render(obj, cam);
      for (const [o, m, hidden] of swapped) {
        o.material = m;
        if (hidden) o.visible = true;
      }
      s.uFixMatrix.value[i].multiplyMatrices(this.shadowBias, cam.projectionMatrix).multiply(cam.matrixWorldInverse);
      s.uFixPos.value[i].set(f.pos.x, f.pos.y, f.pos.z, f.range);
      s.uFixColor.value[i].set(f.color.x, f.color.y, f.color.z, f.dir ? f.cone : -2);
      if (f.dir) s.uFixDir.value[i].set(f.dir.x, f.dir.y, f.dir.z, f.coneEdge);
      done++;
    }
    this.fixTarget.viewport.set(0, 0, this.fixTarget.width, this.fixTarget.height);
    this.fixTarget.scissor.set(0, 0, this.fixTarget.width, this.fixTarget.height);
    return done;
  }

  _depthFor(texture) {
    let mat = this.depthNodes.get(texture);
    if (!mat) {
      mat = createDepthMaterial(true, { uNodeTex: { value: texture } });
      this.depthNodes.set(texture, mat);
    }
    return mat;
  }

  /** The post uniforms (grade, vignette, grain, overlay) for the lighting / panic / game systems to drive. */
  get postUniforms() {
    return this.post.uniforms;
  }

  /** Reads back the canvas as a data URL (debug / screenshots). */
  snapshot() {
    return this.canvas.toDataURL('image/png');
  }
}

const _look = new THREE.Vector3();
const _toC = new THREE.Vector3();
const _dir = new THREE.Vector3();
const _down = new THREE.Vector3(0, -1, 0);
