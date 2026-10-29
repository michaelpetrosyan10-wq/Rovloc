// The world material: albedo (generated texture x part colour) x (baked light + dynamic light), the Roblox Future
// look on a Chromebook budget. One ShaderMaterial per (material key x variant); every instance shares the same
// uniform objects for the dynamic lights, flicker table, fog and grade, so one write per frame updates them all.
//
//   * Baked: per-vertex RGB irradiance from W1's bake (encoded / 4), modulated by its flicker group: a vertex lit
//     `share` by group g gets baked x (1 - share + share x factor[g]); factor lives in a 256-texel float texture the
//     lighting system rewrites each frame (group 0 is steady).
//   * Probe: entities and dynamic things (doors, props, hands, the creature) get one probe irradiance uniform,
//     trilinearly sampled from the level's probe grid where they stand.
//   * Dynamic: the flashlight (two spot cones like Flashlight.luau, optional shadow map), the presence glow around
//     the player, and up to MAX_POINT nearest scripted / flickering point lights. Diffuse is Lambert; the generated
//     roughness and normal maps give the specular sheen that makes glossy floors and bumpy walls read under the torch.
//   * Neon parts are emissive (x their flicker), glass / water blend.
//   * Fog: exponential-squared haze in the level film's colour. Output is exposure-scaled, ACES-filmic tone mapped
//     and gamma encoded, so the post pass works on display values (like Roblox's ColorCorrection).

import * as THREE from 'three';

export const MAX_POINT = 4;
export const FLICKER_GROUPS = 256;

/** Uniforms shared by every world material (written by the lighting system, the flashlight and the renderer). */
export function createSharedUniforms() {
  const flickerData = new Float32Array(FLICKER_GROUPS).fill(1);
  const flickerTex = new THREE.DataTexture(flickerData, FLICKER_GROUPS, 1, THREE.RedFormat, THREE.FloatType);
  flickerTex.minFilter = flickerTex.magFilter = THREE.NearestFilter;
  flickerTex.needsUpdate = true;
  const plPos = [];
  const plColor = [];
  for (let i = 0; i < MAX_POINT; i++) {
    plPos.push(new THREE.Vector4(0, -1e5, 0, 1));
    plColor.push(new THREE.Vector3());
  }
  return {
    uFlickerTex: { value: flickerTex },
    uFlickerData: flickerData,
    uFlPos: { value: new THREE.Vector3() },
    uFlDir: { value: new THREE.Vector3(0, 0, -1) },
    uFlInner: { value: new THREE.Vector3() }, // colour x brightness of the inner cone
    uFlOuter: { value: new THREE.Vector3() },
    uFlCone: { value: new THREE.Vector4(0.95, 0.9, 0.8, 0.7) }, // cos: inner full, inner edge, outer full, outer edge
    uFlRange: { value: new THREE.Vector2(60, 48) },
    uGlowPos: { value: new THREE.Vector3(0, -1e5, 0) },
    uGlowColor: { value: new THREE.Vector3() },
    uGlowRange: { value: 10 },
    uPlPos: { value: plPos },
    uPlColor: { value: plColor },
    uShadowMap: { value: null },
    uShadowMatrix: { value: new THREE.Matrix4() },
    uShadowOn: { value: 0 },
    uShadowTexel: { value: 1 / 512 },
    uFogColor: { value: new THREE.Vector3(0.02, 0.025, 0.03) },
    uFogDensity: { value: 0.006 },
    uExposure: { value: 1.3 },
    uAmbientBoost: { value: 0 },
    uFlash: { value: new THREE.Vector3() }, // lightning: additive sky light on surfaces open to the sky
    uFalloffK: { value: 0.004 }, // meta.lighting.falloff.inverseSquareK
    uNodeTex: { value: null },
    uTime: { value: 0 },
  };
}

const VERT = /* glsl */ `
precision highp float;
in vec3 position;
in vec3 normal;
in vec2 uv;
in vec3 color;
#ifdef BAKED
in vec3 bakedLight;
in vec2 flicker;
uniform sampler2D uFlickerTex;
#endif
#ifdef VERTEX_ALPHA
in float alpha;
out float vAlpha;
#endif
#ifdef NODES
// node batching: each vertex belongs to a node whose affine frame (3 texels) and probe / mode (1 texel) live in a
// float texture; mode 0 hides the node, 1 uses the vertex baked light, 2 the node's probe irradiance
in float node;
uniform sampler2D uNodeTex;
out vec3 vProbe;
out float vMode;
#endif
uniform mat4 modelMatrix;
uniform mat4 viewMatrix;
uniform mat4 projectionMatrix;
out vec3 vWorldPos;
out vec3 vNormal;
out vec2 vUv;
out vec3 vColor;
out vec3 vBaked;
out float vGlow;
void main() {
#ifdef NODES
  int ni = int(node + 0.5);
  ivec2 base = ivec2((ni % 64) * 4, ni / 64);
  vec4 r0 = texelFetch(uNodeTex, base, 0);
  vec4 r1 = texelFetch(uNodeTex, base + ivec2(1, 0), 0);
  vec4 r2 = texelFetch(uNodeTex, base + ivec2(2, 0), 0);
  vec4 pm = texelFetch(uNodeTex, base + ivec2(3, 0), 0);
  mat4 nodeMatrix = mat4(r0.x, r1.x, r2.x, 0.0, r0.y, r1.y, r2.y, 0.0, r0.z, r1.z, r2.z, 0.0, r0.w, r1.w, r2.w, 1.0);
  vProbe = pm.rgb;
  vMode = pm.a;
  vec4 wp = modelMatrix * nodeMatrix * vec4(position, 1.0);
  vNormal = normalize(mat3(modelMatrix) * mat3(nodeMatrix) * normal);
#else
  vec4 wp = modelMatrix * vec4(position, 1.0);
  vNormal = normalize(mat3(modelMatrix) * normal);
#endif
  vWorldPos = wp.xyz;
  vUv = uv;
  vColor = pow(color, vec3(2.2));
#ifdef BAKED
  float f = texelFetch(uFlickerTex, ivec2(int(flicker.x + 0.5), 0), 0).r;
  float mod_ = mix(1.0, f, flicker.y / 255.0);
  vBaked = bakedLight * 4.0 * mod_;
  vGlow = mod_;
#else
  vBaked = vec3(0.0);
  vGlow = 1.0;
#endif
#ifdef VERTEX_ALPHA
  vAlpha = alpha;
#endif
  gl_Position = projectionMatrix * viewMatrix * wp;
#ifdef NODES
  if (vMode < 0.5) gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
#endif
}
`;

const FRAG = /* glsl */ `
precision highp float;
precision highp sampler2D;
in vec3 vWorldPos;
in vec3 vNormal;
in vec2 vUv;
in vec3 vColor;
in vec3 vBaked;
in float vGlow;
#ifdef VERTEX_ALPHA
in float vAlpha;
#endif
#ifdef NODES
in vec3 vProbe;
in float vMode;
#endif
out vec4 fragColor;
uniform vec3 cameraPosition;
#ifdef USE_MAP
uniform sampler2D uMap;
#endif
#ifdef USE_NORMALMAP
uniform sampler2D uNormalMap;
uniform float uNormalScale;
#endif
#ifdef USE_ROUGHMAP
uniform sampler2D uRoughMap;
#endif
uniform float uTile;
uniform float uRoughness;
uniform float uReflectance;
uniform float uEmissive;
uniform float uOpacity;
uniform vec3 uTint;
uniform vec3 uProbe;
uniform vec3 uFlPos;
uniform vec3 uFlDir;
uniform vec3 uFlInner;
uniform vec3 uFlOuter;
uniform vec4 uFlCone;
uniform vec2 uFlRange;
uniform vec3 uGlowPos;
uniform vec3 uGlowColor;
uniform float uGlowRange;
uniform vec4 uPlPos[${MAX_POINT}];
uniform vec3 uPlColor[${MAX_POINT}];
#ifdef USE_SHADOW
uniform sampler2D uShadowMap;
uniform mat4 uShadowMatrix;
uniform float uShadowOn;
uniform float uShadowTexel;
#endif
uniform vec3 uFogColor;
uniform float uFogDensity;
uniform float uExposure;
uniform vec3 uFlash;
uniform float uFalloffK;

// The bake's light falloff (meta.lighting.falloff): (1 - (d/R)^2)^2 / (1 + k d^2), k = 0.004.
float falloff(float d, float range) {
  float x = clamp(d / range, 0.0, 1.0);
  float w = 1.0 - x * x;
  return (w * w) / (1.0 + uFalloffK * d * d);
}

vec3 perturbNormal(vec3 pos, vec3 n, vec3 mapN, vec2 uv) {
  vec3 q0 = dFdx(pos);
  vec3 q1 = dFdy(pos);
  vec2 st0 = dFdx(uv);
  vec2 st1 = dFdy(uv);
  vec3 q1perp = cross(q1, n);
  vec3 q0perp = cross(n, q0);
  vec3 T = q1perp * st0.x + q0perp * st1.x;
  vec3 B = q1perp * st0.y + q0perp * st1.y;
  float det = max(dot(T, T), dot(B, B));
  float scale = det == 0.0 ? 0.0 : inversesqrt(det);
  return normalize(T * (mapN.x * scale) + B * (mapN.y * scale) + n * mapN.z);
}

vec3 aces(vec3 v) {
  v *= 0.6;
  vec3 a = v * (v + 0.0245786) - 0.000090537;
  vec3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
  return clamp(a / b, 0.0, 1.0);
}

#ifdef USE_SHADOW
float shadowAt(vec3 wp, float ndl) {
  vec4 sc = uShadowMatrix * vec4(wp, 1.0);
  if (sc.w <= 0.0) return 1.0;
  vec3 p = sc.xyz / sc.w;
  if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0 || p.z > 1.0) return 1.0;
  float bias = 0.0006 + 0.0025 * (1.0 - ndl);
  float lit = 0.0;
  for (int i = -1; i <= 1; i++) {
    for (int j = -1; j <= 1; j++) {
      float d = texture(uShadowMap, p.xy + vec2(float(i), float(j)) * uShadowTexel).r;
      lit += (p.z - bias) <= d ? 1.0 : 0.0;
    }
  }
  return mix(1.0, lit / 9.0, uShadowOn);
}
#endif

void main() {
  vec2 tuv = vUv / uTile;
  vec3 albedo = vColor * uTint;
#ifdef USE_MAP
  vec4 tex = texture(uMap, tuv);
  albedo *= pow(tex.rgb, vec3(2.2));
#endif
  vec3 n = normalize(vNormal);
  if (!gl_FrontFacing) n = -n;
  float rough = uRoughness;
#ifdef USE_ROUGHMAP
  rough = clamp(rough * texture(uRoughMap, tuv).g * 1.4, 0.04, 1.0);
#endif
#ifdef USE_NORMALMAP
  vec3 mapN = texture(uNormalMap, tuv).xyz * 2.0 - 1.0;
  mapN.xy *= uNormalScale;
  n = perturbNormal(vWorldPos, n, normalize(mapN), tuv);
#endif
  vec3 v = normalize(cameraPosition - vWorldPos);
  float gloss = 1.0 - rough;
  float specPow = exp2(10.0 * gloss + 1.0);
  float specK = (0.04 + uReflectance) * gloss * gloss * (specPow + 8.0) / 25.0;

  vec3 diffuse = vec3(0.0);
  vec3 spec = vec3(0.0);

  // the flashlight: inner and outer cones
  vec3 toL = uFlPos - vWorldPos;
  float d = length(toL);
  vec3 l = toL / max(d, 1e-4);
  float ndl = max(dot(n, l), 0.0);
  float cosA = dot(-l, uFlDir);
  float inner = smoothstep(uFlCone.y, uFlCone.x, cosA) * falloff(d, uFlRange.x);
  float outer = smoothstep(uFlCone.w, uFlCone.z, cosA) * falloff(d, uFlRange.y);
  vec3 fl = uFlInner * inner + uFlOuter * outer;
#ifdef USE_SHADOW
  fl *= shadowAt(vWorldPos, ndl);
#endif
  vec3 h = normalize(l + v);
  diffuse += fl * ndl;
  spec += fl * pow(max(dot(n, h), 0.0), specPow) * specK * ndl;

  // presence glow (always on around the player)
  vec3 toG = uGlowPos - vWorldPos;
  float dg = length(toG);
  diffuse += uGlowColor * max(dot(n, toG / max(dg, 1e-4)), 0.0) * falloff(dg, uGlowRange);

  // nearest dynamic point lights
  for (int i = 0; i < ${MAX_POINT}; i++) {
    vec3 tp = uPlPos[i].xyz - vWorldPos;
    float dp = length(tp);
    vec3 lp = tp / max(dp, 1e-4);
    float a = falloff(dp, uPlPos[i].w);
    float nl = max(dot(n, lp), 0.0);
    diffuse += uPlColor[i] * nl * a;
    spec += uPlColor[i] * pow(max(dot(n, normalize(lp + v)), 0.0), specPow) * specK * nl * a;
  }

#if defined(NODES) && defined(BAKED)
  vec3 light = vMode > 1.5 ? vProbe : vBaked;
#elif defined(NODES)
  vec3 light = vProbe;
#elif defined(BAKED)
  vec3 light = vBaked;
#else
  vec3 light = uProbe;
#endif
  light += uFlash * max(n.y, 0.25);
  vec3 col = albedo * (light + diffuse) + spec;
#ifdef EMISSIVE
  col += albedo * uEmissive * vGlow;
#endif
  float fogF = 1.0 - exp(-pow(length(cameraPosition - vWorldPos) * uFogDensity, 2.0));
  col = mix(col, uFogColor, fogF);
  col = aces(col * uExposure);
  col = pow(col, vec3(1.0 / 2.2));
  float alphaOut = uOpacity;
#ifdef VERTEX_ALPHA
  alphaOut *= vAlpha;
#endif
#ifdef TRANSPARENT
  alphaOut = max(alphaOut, (spec.r + spec.g + spec.b) * 0.3);
#endif
  fragColor = vec4(col, alphaOut);
}
`;

/**
 * @typedef {Object} MaterialSpec
 * @property {THREE.Texture} [map]
 * @property {THREE.Texture} [normalMap]
 * @property {THREE.Texture} [roughMap]
 * @property {number} [studsPerTile]
 * @property {number} [roughness]
 * @property {number} [reflectance]
 * @property {number} [emissive]   Neon strength (0 = not emissive)
 * @property {number} [opacity]
 * @property {boolean} [baked]     true: vertex baked light + flicker; false: the probe uniform
 * @property {boolean} [transparent]
 * @property {boolean} [vertexAlpha]
 * @property {boolean} [shadow]    sample the flashlight shadow map
 * @property {boolean} [nodes]     node-batched geometry (a `node` attribute indexing the node texture)
 * @property {THREE.Texture} [nodeTexture]
 * @property {THREE.Color} [tint]
 */

/**
 * Creates a world material bound to the shared uniforms.
 * @param {ReturnType<typeof createSharedUniforms>} shared
 * @param {MaterialSpec} spec
 */
export function createWorldMaterial(shared, spec) {
  const defines = {};
  if (spec.baked !== false) defines.BAKED = '';
  if (spec.map) defines.USE_MAP = '';
  if (spec.normalMap) defines.USE_NORMALMAP = '';
  if (spec.roughMap) defines.USE_ROUGHMAP = '';
  if (spec.emissive) defines.EMISSIVE = '';
  if (spec.transparent) defines.TRANSPARENT = '';
  if (spec.vertexAlpha) defines.VERTEX_ALPHA = '';
  if (spec.shadow) defines.USE_SHADOW = '';
  if (spec.nodes) defines.NODES = '';
  const uniforms = {
    ...shared,
    uMap: { value: spec.map || null },
    uNormalMap: { value: spec.normalMap || null },
    uNormalScale: { value: 0.9 },
    uRoughMap: { value: spec.roughMap || null },
    uTile: { value: spec.studsPerTile || 8 },
    uRoughness: { value: spec.roughness ?? 0.8 },
    uReflectance: { value: spec.reflectance || 0 },
    uEmissive: { value: spec.emissive || 0 },
    uOpacity: { value: spec.opacity ?? 1 },
    uTint: { value: spec.tint ? spec.tint.clone() : new THREE.Color(1, 1, 1) },
    uProbe: { value: new THREE.Vector3(0.05, 0.05, 0.06) },
  };
  if (spec.nodes) uniforms.uNodeTex = { value: spec.nodeTexture || null };
  const mat = new THREE.RawShaderMaterial({
    glslVersion: THREE.GLSL3,
    vertexShader: VERT,
    fragmentShader: FRAG,
    uniforms,
    defines,
    transparent: !!spec.transparent,
    depthWrite: !spec.transparent,
    side: THREE.DoubleSide,
  });
  mat.userData.spec = spec;
  return mat;
}

/** A copy of `material` with its own probe / tint / opacity uniforms (for one entity or dynamic object). */
export function cloneForObject(material) {
  const m = material.clone();
  // RawShaderMaterial.clone copies uniforms deeply; re-link the shared ones so they keep updating.
  for (const [k, u] of Object.entries(material.uniforms)) {
    if (!['uProbe', 'uTint', 'uOpacity', 'uNodeTex'].includes(k)) m.uniforms[k] = u;
  }
  return m;
}

/** Depth-only material for the flashlight's shadow map (`nodes`: node-batched geometry). */
export function createDepthMaterial(nodes = false, shared = null) {
  return new THREE.RawShaderMaterial({
    glslVersion: THREE.GLSL3,
    defines: nodes ? { NODES: '' } : {},
    uniforms: nodes ? { uNodeTex: shared ? shared.uNodeTex : { value: null } } : {},
    vertexShader: /* glsl */ `
      precision highp float;
      in vec3 position;
      uniform mat4 modelMatrix; uniform mat4 viewMatrix; uniform mat4 projectionMatrix;
#ifdef NODES
      in float node;
      uniform sampler2D uNodeTex;
#endif
      void main() {
#ifdef NODES
        int ni = int(node + 0.5);
        ivec2 base = ivec2((ni % 64) * 4, ni / 64);
        vec4 r0 = texelFetch(uNodeTex, base, 0);
        vec4 r1 = texelFetch(uNodeTex, base + ivec2(1, 0), 0);
        vec4 r2 = texelFetch(uNodeTex, base + ivec2(2, 0), 0);
        float mode = texelFetch(uNodeTex, base + ivec2(3, 0), 0).a;
        mat4 nm = mat4(r0.x, r1.x, r2.x, 0.0, r0.y, r1.y, r2.y, 0.0, r0.z, r1.z, r2.z, 0.0, r0.w, r1.w, r2.w, 1.0);
        gl_Position = projectionMatrix * viewMatrix * modelMatrix * nm * vec4(position, 1.0);
        if (mode < 0.5) gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
#else
        gl_Position = projectionMatrix * viewMatrix * modelMatrix * vec4(position, 1.0);
#endif
      }`,
    fragmentShader: /* glsl */ `
      precision highp float;
      out vec4 c;
      void main() { c = vec4(1.0); }`,
    side: THREE.DoubleSide,
  });
}
