// The Creature's look ("the Tall Man"): its visual constants, its graphics tiers and its materials.
//
// The materials are the engine's world material (createCreatureModel's node-batched meshes) with the creature's
// shading spliced into its shader, so the level probe, the torch (with its shadow map), the presence glow and the
// point lights light it exactly like everything else:
//   * Shadow (the SmoothPlastic chunk: body, skull, tatters, fingers): near-black albedo with a faint sheen, a cold
//     fresnel rim (about 0.15 on screen at grazing angles), a slight saturating response to the torch at its
//     silhouette; whatever lights it, it stays a dark shape (its response saturates at Look.bodyCap); at Max, smoke
//     crawling over its surface (the rim flickering through it) and a dithered edge haze that drifts like smoke, so it
//     reads as a silhouette swallowing light.
//   * Mask: the website's sculpt (mask.js: a dense mesh of the rig's MaskShape in two pieces, the upper mask on the Head
//     bone and the chin on the Jaw bone) replaces the Roblox shell (the Marble chunk, hidden). Ivory porcelain, painted
//     in the face frame: ambient occlusion in the sockets and the creases (from the sculpt's cavity), grime and
//     yellowing in the creases and toward the rim, the cracks (the rig's MaskCrack<N> strips: the major crack and the
//     hairlines), the weeping streaks (MaskStreak<N>), the chipped edge (a real hole onto the black behind), the
//     half-smiling slit, the nostrils, the eye holes (pure black sockets, a tiny pale pinprick deep in each, the right
//     one larger) and, in the jumpscare (set({fx})), the cracks racing across it, the slit torn into a jagged vertical
//     maw (a real hole) with thin wet strands stretched across it, and the right pupil dilating. At Max a detail
//     normal map (crazing and pitting in the glaze), a glaze roughness map, cracks grooved into the surface and the eye
//     holes followed into their depth (parallax).
//   * Drawn detail (the Fabric chunk: the parts Roblox renders the detail with) and the Neon pupils: hidden.
//   * Dissolve on every chunk: a noise threshold rising from the feet (the mask goes last, forms first), per-pixel
//     static and an emissive cold edge, driven by `fade` (1 whole .. 0 gone); at Max a finer octave and embers.
// Graphics tiers (LookTiers, chosen from the engine's quality tier by lookTierFor): Max is the default, everything on;
// Potato (the Low tier: a school Chromebook) drops only visual layers (no haze, no skin smoke, no detail map, flat eye
// holes, a plain dissolve, sparse smoke and shards, no torch shadow): the mask keeps its sculpt, its silhouette and
// all its painted layout. A tier never touches the rig's skeleton, its animation, its hitboxes or anything gameplay
// reads.

import * as THREE from 'three';
import { CRACK_COUNT, STREAK_COUNT, buildMaskSculpt, crackSegments, detailTexture, maskSpec, streakSegments } from './mask.js';

export { CRACK_COUNT, crackSegments, maskSpec };

export const Look = Object.freeze({
  rim: 0.07, // fresnel rim at grazing angles (about 0.15 on screen after exposure and tone mapping)
  rimColor: Object.freeze([0.55, 0.68, 1.0]), // cold
  torchSheen: 0.06, // the torch catching its silhouette (saturating: at most this much)
  bodyCap: 0.035, // the shadow body's lit colour saturates at about this (linear): a light inches away leaves it dark
  haze: 0.42, // dithered edge haze
  bodyRoughness: 0.78,
  bodyReflectance: 0.0,
  maskColor: Object.freeze([0.71, 0.64, 0.5]), // ivory porcelain (sRGB), about CreatureConfig.Rig.MaskColor
  maskRoughness: 0.34,
  maskReflectance: 0.06,
  edgeColor: Object.freeze([0.42, 0.66, 1.0]), // the dissolve's cold edge
  pupilColor: Object.freeze([1.0, 0.9, 0.74]),
  glowNear: 11, // the pinpricks glow fully within this many studs of the camera ...
  glowFar: 15, // ... and not at all past this
  fadeOutSeconds: 0.6, // FadeOut: it dissolves into smoke and static
  fadeInSeconds: 0.8, // FadeIn: it forms from the dark
});

/**
 * What each graphics tier draws of the Creature. Visual layers only: a tier never changes the skeleton, the
 * animation, the hitboxes, the metrics or anything gameplay reads.
 */
export const LookTiers = Object.freeze({
  Max: Object.freeze({
    haze: true, // dithered edge haze on the shadow body
    skin: true, // smoke crawling over the shadow body, the rim flickering through it
    detail: true, // the mask's detail normal map, glaze roughness, grooved cracks and grime noise
    parallax: true, // the eye holes followed into their depth, the pinprick on the back wall
    dissolveDetail: true, // the dissolve's finer octave and its embers
    smoke: 'Max', // smoke.js SmokeBudget
    shards: 20, // porcelain shards breaking off in the jumpscare
    shadow: true, // it casts the torch's shadow (where the engine draws one)
    halos: false, // additive halos round the pinpricks (off: no cute glowing dots)
  }),
  Potato: Object.freeze({
    haze: false,
    skin: false,
    detail: false,
    parallax: false,
    dissolveDetail: false,
    smoke: 'Potato',
    shards: 8,
    shadow: false,
    halos: false,
  }),
});

/** The look tier for the engine's quality budget: Potato on the Low tier (a school Chromebook), else Max. */
export function lookTierFor(budget) {
  const tier = budget && budget.tier;
  return tier === 'Low' || tier === 'Potato' ? 'Potato' : 'Max';
}

// ---------------------------------------------------------------------------------------------------------------
// Shader splicing
// ---------------------------------------------------------------------------------------------------------------

const VERT_DECL = 'out float vGlow;\n';
const VERT_BODY = '  vWorldPos = wp.xyz;\n';
const FRAG_IN = 'in float vGlow;\n';
const FRAG_DECL = 'uniform float uFalloffK;\n';
const FRAG_ALBEDO = '  vec3 albedo = vColor * uTint;\n';
const FRAG_VIEW = '  vec3 v = normalize(cameraPosition - vWorldPos);\n';
const FRAG_FOG = '  float fogF = 1.0 - exp(-pow(length(cameraPosition - vWorldPos) * uFogDensity, 2.0));\n';

const V_DECL = /* glsl */ `
#ifdef CREATURE
uniform vec3 cameraPosition;
out vec3 vRest;
out vec3 vRestNormal;
out float vNodeId;
out vec3 vViewRest;
#ifdef CREATURE_MASK
in vec3 sculpt;
out vec3 vSculpt;
uniform mat4 uMaskInv;
out vec3 vFaceX;
out vec3 vFaceY;
#endif
#endif
`;

const V_BODY = /* glsl */ `
#ifdef CREATURE
  vRest = position;
  vRestNormal = normal;
  vNodeId = node;
  // the direction to the camera in rest (model) space: undo the node's rotation
  mat3 nodeRot = mat3(modelMatrix) * mat3(nodeMatrix);
  vViewRest = transpose(nodeRot) * (cameraPosition - wp.xyz);
#ifdef CREATURE_MASK
  vSculpt = sculpt;
  // the face frame's x / y axes (rows of its rest-space rotation) carried into world space
  mat3 toFace = mat3(uMaskInv);
  vFaceX = nodeRot * vec3(toFace[0][0], toFace[1][0], toFace[2][0]);
  vFaceY = nodeRot * vec3(toFace[0][1], toFace[1][1], toFace[2][1]);
#endif
#endif
`;

const F_IN = /* glsl */ `
#ifdef CREATURE
in vec3 vRest;
in vec3 vRestNormal;
in float vNodeId;
in vec3 vViewRest;
#ifdef CREATURE_MASK
in vec3 vSculpt;
in vec3 vFaceX;
in vec3 vFaceY;
#endif
#endif
`;

const F_DECL = /* glsl */ `
#ifdef CREATURE
uniform float uFade;
uniform float uCreatureTime;
uniform vec3 uEdgeColor;
uniform float uRim;
uniform vec3 uRimColor;
uniform float uHaze;
uniform float uTorchSheen;
uniform float uBodyCap;
float cHash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
float cHash3(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
float cNoise(vec3 p) {
  vec3 i = floor(p);
  vec3 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float a = cHash3(i);
  float b = cHash3(i + vec3(1.0, 0.0, 0.0));
  float c = cHash3(i + vec3(0.0, 1.0, 0.0));
  float d = cHash3(i + vec3(1.0, 1.0, 0.0));
  float e = cHash3(i + vec3(0.0, 0.0, 1.0));
  float g = cHash3(i + vec3(1.0, 0.0, 1.0));
  float h = cHash3(i + vec3(0.0, 1.0, 1.0));
  float k = cHash3(i + vec3(1.0, 1.0, 1.0));
  return mix(mix(mix(a, b, f.x), mix(c, d, f.x), f.y), mix(mix(e, g, f.x), mix(h, k, f.x), f.y), f.z);
}
float cBayer(vec2 p) {
  ivec2 q = ivec2(mod(p, 4.0));
  int m[16] = int[16](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
  return (float(m[q.x + q.y * 4]) + 0.5) / 16.0;
}
#ifdef CREATURE_MASK
uniform mat4 uMaskInv;
uniform vec4 uEye; // eye x, hole half-width, hole half-height, hole depth
uniform vec4 uSlit; // slit y, slit half-width, pinprick radius, the Jaw's node
uniform vec4 uSlit2; // the slit's upturn, the right pinprick's scale, unused, unused
uniform vec4 uChip; // centre, radii
uniform float uChipAngle;
uniform vec3 uPupilColor;
uniform float uPupil;
uniform vec4 uFx; // the jumpscare: race, tear, strands, dilate (0..1 each)
uniform float uMaskAmbient; // the room's light on the mask (the jumpscare dims it so its own light models the face)
uniform vec4 uCracks[${CRACK_COUNT}];
uniform vec4 uCrackInfo[${CRACK_COUNT}]; // width, appears at (race 0..1), grows over, unused
uniform int uCrackBase; // the rig's cracks come first and are always there
uniform vec4 uStreaks[${STREAK_COUNT}];
uniform vec4 uStreakW[${STREAK_COUNT / 4}];
#ifdef CREATURE_DETAIL
uniform sampler2D uDetail;
#endif
float cSegment(vec2 p, vec4 s, out float h) {
  vec2 pa = p - s.xy;
  vec2 ba = s.zw - s.xy;
  h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
  return length(pa - ba * h);
}
// an eye hole's normalized coordinates (1 on its rim): an almond drooping at the outer corner
vec2 cHoleQ(vec2 p, float side) {
  vec2 d = p - vec2(side * uEye.x, 0.0);
  float a = side * -0.3;
  d = mat2(cos(a), sin(a), -sin(a), cos(a)) * d;
  d.y *= 1.0 + 0.55 * smoothstep(0.0, 1.0, d.x * side / uEye.y);
  return d / uEye.yz;
}
float cSlitY(float x) {
  float corner = smoothstep(uSlit.y * 0.35, uSlit.y * 1.02, x);
  return uSlit.x + uSlit2.x * corner * corner;
}
float cZig(float x) { return abs(fract(x) - 0.5) * 2.0; }
#endif
#endif
`;

// After the albedo: the mask's paint (face frame: x right, y up, z back, origin between the pupils).
const F_ALBEDO = /* glsl */ `
#ifdef CREATURE
  float cHole = 0.0;
  float cHoleShade = 0.0;
  float cInner = 0.0;
  vec3 cEmit = vec3(0.0);
#ifdef CREATURE_MASK
  vec3 cFp = (uMaskInv * vec4(vRest, 1.0)).xyz;
  vec2 cP = cFp.xy;
  float cSide = cP.x < 0.0 ? -1.0 : 1.0;
  vec2 cQ = cHoleQ(cP, cSide);
  float cR = length(cQ);
  float cBack = gl_FrontFacing ? 0.0 : 1.0;
  float cAo = 1.0;
  float cGrime = 0.0;
  float cWet = 0.0;
  float cCrack = 1e3;
  vec2 cCrackAxis = vec2(1.0, 0.0);
  float cLip = 0.0;
  {
    vec2 p = cP;
    float aa = fwidth(p.x) + fwidth(p.y) + 1e-5;
    // the chipped edge: a piece of the rim broke away: a hole onto the black behind, ragged
    vec2 cd = p - uChip.xy;
    float ca = cos(uChipAngle);
    float sa = sin(uChipAngle);
    cd = vec2(ca * cd.x + sa * cd.y, -sa * cd.x + ca * cd.y) / uChip.zw;
    float cAng = atan(cd.y, cd.x);
    float chipD = length(cd) * (0.88 + 0.16 * cZig(cAng * 1.7 + 0.3) + 0.07 * cZig(cAng * 4.3 + 0.8));
    if (chipD < 1.0) discard;
    float chipEdge = 1.0 - smoothstep(1.0, 1.0 + 0.012 / uChip.w + aa / uChip.w, chipD);

    // the maw: the slit torn open into a jagged, vertical hole leaning across the face; thin wet strands across it
    float tear = uFx.y;
    float maw = 0.0;
    float strand = 0.0;
    if (tear > 0.001) {
      vec2 mc = vec2(0.016, uSlit.x - 0.035);
      vec2 md = p - mc;
      md.x -= 0.17 * md.y;
      float hw = mix(uSlit.y * 0.9, 0.078, smoothstep(0.0, 0.6, tear));
      float hh = mix(0.008, 0.33, tear) * (md.y > 0.0 ? 0.7 : 1.0);
      vec2 m = md / vec2(hw, hh);
      float ang = atan(m.y, m.x);
      float r = pow(pow(abs(m.x), 1.25) + pow(abs(m.y), 1.25), 1.0 / 1.25);
      float d = r * (0.74 + 0.36 * cZig(ang * 0.93 + 0.17) + 0.13 * cZig(ang * 2.4 + 0.61) + 0.04 * cZig(ang * 6.1));
      float daa = fwidth(d) + 1e-4;
      maw = 1.0 - smoothstep(1.0 - daa, 1.0 + daa, d);
      cLip = (1.0 - smoothstep(1.0, 1.0 + 0.022 / hw + daa, d)) * (1.0 - maw);
      for (int k = 0; k < 4; k++) {
        float fk = float(k);
        float a1 = 1.6 + fk * 0.9 + 0.3 * sin(fk * 3.1);
        float a2 = a1 + 2.6 + 0.5 * sin(fk * 1.7);
        vec2 s1 = mc + vec2(cos(a1) * hw * 0.92 + 0.24 * sin(a1) * hh, sin(a1) * hh * 0.92);
        vec2 s2 = mc + vec2(cos(a2) * hw * 0.92 + 0.24 * sin(a2) * hh, sin(a2) * hh * 0.92);
        vec2 sab = s2 - s1;
        float t = clamp(dot(p - s1, sab) / max(dot(sab, sab), 1e-6), 0.0, 1.0);
        vec2 on = s1 + sab * t - vec2(0.0, (0.012 + 0.035 * uFx.z) * 4.0 * t * (1.0 - t));
        float intact = step(uFx.z, 0.5 + 0.16 * fk) * smoothstep(0.0, 0.08, uFx.z);
        float w = mix(0.007, 0.0024, uFx.z) * (0.75 + 0.5 * cZig(t * 3.0 + fk)) * intact;
        strand = max(strand, 1.0 - smoothstep(w, w + aa, length(p - on)));
      }
      strand *= maw;
    }

    // ambient occlusion and grime from the sculpt: the sockets and the creases hold shadow and dirt; the porcelain
    // yellows toward its rim
    float cav = vSculpt.x;
    float rim = clamp(vSculpt.y, 0.0, 1.0);
    float soot = 1.0 - smoothstep(1.0, 2.6, cR);
    float ao = 1.0 - clamp(cav * 15.0, 0.0, 0.8) - 0.62 * soot * soot;
    cGrime = clamp(cav * 12.0, 0.0, 0.85) + 0.35 * smoothstep(0.55, 1.0, rim) + 0.25 * soot;
    // aged porcelain: blotched with dirt, yellowed round the mouth and the chin, darker toward its rim
    float blotch = cNoise(vec3(p * 6.0, 2.3)) * 0.65 + cNoise(vec3(p * 15.0, 5.1)) * 0.35;
#ifdef CREATURE_DETAIL
    vec4 dm = texture(uDetail, p * 2.7);
    vec4 dm2 = texture(uDetail, p * 0.9 + vec2(0.37, 0.71));
    blotch = mix(blotch, dm2.a, 0.4);
    cGrime += 0.4 * dm.b * (0.4 + cGrime);
    ao *= 1.0 - 0.06 * dm.b;
#endif
    cGrime += 0.45 * smoothstep(0.45, 0.85, blotch) + 0.2 * smoothstep(-0.25, -0.6, p.y) + 0.15 * (1.0 - smoothstep(0.05, 0.22, length(p - vec2(0.0, uSlit.x))));
    cGrime = clamp(cGrime, 0.0, 1.0);
    albedo *= mix(vec3(1.0), vec3(0.92, 0.83, 0.62), 0.65 * smoothstep(0.3, 1.0, rim) + 0.3 * cGrime);
    albedo = mix(albedo, albedo * vec3(0.48, 0.37, 0.22), cGrime * 0.72);
    cAo = max(ao, 0.12);
    albedo *= mix(1.0, cAo, 0.45);

    // the weeping: dark streaks run down from both eye holes
    float streak = 0.0;
    for (int i = 0; i < ${STREAK_COUNT}; i++) {
      float h;
      float d = cSegment(p, uStreaks[i], h);
      float w = uStreakW[i / 4][i - (i / 4) * 4] * mix(0.55, 0.4, h);
      w *= 0.8 + 0.4 * cNoise(vec3(p * vec2(30.0, 6.0), float(i)));
      streak = max(streak, 1.0 - smoothstep(w * 0.5, w * 0.5 + aa * 1.2, d));
    }
    albedo *= 1.0 - 0.8 * streak;
    cWet = max(cWet, streak * 0.5);

    // the cracks: the rig's always, the race's as it runs (each grows from its start); a dark gap, a stained halo
    float stain = 0.0;
    float line = 0.0;
    for (int i = 0; i < ${CRACK_COUNT}; i++) {
      vec4 info = uCrackInfo[i];
      if (i >= uCrackBase && uFx.x <= info.y) continue;
      float grow = i < uCrackBase ? 1.0 : clamp((uFx.x - info.y) / max(info.z, 1e-3), 0.0, 1.0);
      vec4 s = uCracks[i];
      s.zw = mix(s.xy, s.zw, grow);
      float h;
      float d = cSegment(p, s, h);
      float w = info.x * (i < uCrackBase ? 1.0 : 0.9 + 0.3 * (1.0 - h));
      float l = (1.0 - smoothstep(w * 0.5, w * 0.5 + aa * 1.3, d)) * (i < uCrackBase ? 1.0 : 0.85);
      line = max(line, l);
      if (d < cCrack) {
        cCrack = d - w * 0.5;
        cCrackAxis = normalize(s.zw - s.xy + 1e-6);
      }
      stain = max(stain, (1.0 - smoothstep(0.0, w * 2.5 + 0.012, d)) * min(1.0, w * 90.0));
    }
    albedo = mix(albedo, albedo * vec3(0.5, 0.38, 0.22), 0.5 * stain);
    albedo = mix(albedo, vec3(0.035, 0.026, 0.02), 0.88 * line);
    cGrime = max(cGrime, 0.6 * stain);

    // the slit: thin, the right corner curling up into the wrong half-smile; the nostrils
    float sy = cSlitY(p.x);
    float slit = 1.0 - smoothstep(0.0018, 0.0018 + aa * 1.2, abs(p.y - sy));
    slit *= 1.0 - smoothstep(uSlit.y - 0.04, uSlit.y + 0.002, abs(p.x));
    albedo *= 1.0 - 0.85 * slit;
    vec2 nos = vec2(abs(p.x) - 0.024, p.y + 0.216) / vec2(0.011, 0.004);
    albedo *= 1.0 - 0.45 * (1.0 - smoothstep(0.5, 1.0, length(nos)));

    // the broken edges (the maw's lip and the chip's): the unglazed body, chalky and pale, a shadow just inside
    float body = max(cLip, chipEdge);
    albedo = mix(albedo, vec3(0.62, 0.6, 0.55), 0.7 * body);
    cGrime = mix(cGrime, 0.8, body);

    // inside the maw: a void, black but for the strands (dark, wet, catching the light)
    albedo = mix(albedo, vec3(0.16, 0.08, 0.07), strand);
    cWet = max(cWet, strand);
    cInner = max(cInner, maw * (1.0 - strand));

    // the eye holes: pure black sockets bored uEye.w deep; a tiny pale pinprick deep in each, the right one larger
    // (and dilating in the jumpscare)
    float raa = fwidth(cR) + 1e-4;
    cHole = (1.0 - smoothstep(1.0 - raa, 1.0 + raa, cR)) * (1.0 - cInner);
    if (cHole > 0.0) {
      vec2 ec = vec2(cSide * uEye.x, 0.0);
      float pr = uSlit.z * (cSide > 0.0 ? uSlit2.y : 1.0);
      float dil = cSide > 0.0 ? uFx.w : 0.0;
      pr = mix(pr, 0.03, dil);
#ifdef CREATURE_PARALLAX
      // follow the view ray into the bore: the near wall's lip catches a little light, deeper is black, and the
      // pinprick glows on the back wall
      vec3 fv = normalize(mat3(uMaskInv) * vViewRest);
      vec3 dir = -fv;
      float t = uEye.w / max(dir.z, 0.08);
      vec2 backQ = cHoleQ(p + dir.xy * t, cSide) / 0.7;
      vec2 backP = p + dir.xy * t - ec;
      vec2 dq = (cHoleQ(p + dir.xy * 0.01, cSide) - cQ) / 0.01;
      float qa = max(dot(dq, dq), 1e-6);
      float qb = dot(cQ, dq);
      float tExit = (-qb + sqrt(max(qb * qb - qa * (cR * cR - 1.0), 0.0))) / qa;
      float depth = clamp(tExit * dir.z / uEye.w, 0.0, 1.0);
      float lip = 1.0 - smoothstep(0.0, 0.3, depth);
      cHoleShade = 0.2 * lip * lip * smoothstep(0.85, 1.05, length(backQ));
      float inBore = 1.0 - smoothstep(0.85, 1.05, length(backQ));
#else
      cHoleShade = 0.12 * smoothstep(0.78, 1.0, cR);
      vec2 backP = p - ec;
      float inBore = 1.0;
#endif
      float rp = length(backP);
      float core = 1.0 - smoothstep(pr * 0.35, pr, rp);
      float halo = exp(-rp * rp / (pr * pr * 2.5)) * 0.1;
      // dilated: a dim, milky iris with a black pupil swelling in it
      float iris = core * (1.0 - dil * (1.0 - smoothstep(pr * 0.38, pr * 0.55, rp))) * (1.0 - 0.45 * dil);
      cEmit = uPupilColor * ((iris + halo * (1.0 - dil * 0.5)) * uPupil * 0.45 * cHole * inBore);
    }
  }
#endif
#endif
`;

// Before the view vector (Max): the glaze's crazing and pitting (the detail normal map), the cracks grooved into the
// surface and the eye holes' rims rounded over into the bore bend the lighting normal; the glaze's roughness varies
// (shinier glaze, dull grime and broken edges, wet streaks and strands).
const F_NORMAL = /* glsl */ `
#ifdef CREATURE_MASK
  {
    vec3 fx = normalize(vFaceX);
    vec3 fy = normalize(vFaceY);
    vec2 g = vec2(0.0);
#ifdef CREATURE_DETAIL
    vec4 dn = texture(uDetail, cP * 2.7);
    g += (dn.rg - 0.5) * 0.7;
    // a crack is a groove: its walls face each other across it
    float groove = 1.0 - smoothstep(0.0, 0.006, cCrack);
    vec2 across = vec2(-cCrackAxis.y, cCrackAxis.x);
    g += across * sign(dot(cP, across) + 1e-4) * groove * 0.6 * sin(clamp(cCrack / 0.006, 0.0, 1.0) * 3.14159);
    // the eye holes' rims round over into the bore
    vec2 toHole = cP - vec2(cSide * uEye.x, 0.0);
    g += normalize(toHole + 1e-5) * smoothstep(1.32, 1.0, cR) * step(1.0, cR) * 0.5;
    rough = clamp(uRoughness * (0.6 + 0.75 * dn.a) + 0.55 * cGrime - 0.25 * cWet, 0.06, 1.0);
#else
    rough = clamp(uRoughness + 0.4 * cGrime - 0.2 * cWet, 0.06, 1.0);
#endif
    n = normalize(n - (g.x * fx + g.y * fy) * (1.0 - cBack));
  }
#endif
`;

// Before the fog: rim, skin smoke, torch sheen, the painted holes and void, the haze and the dissolve.
const F_FOG = /* glsl */ `
#ifdef CREATURE
  {
    float cf = 1.0 - abs(dot(n, v));
#ifdef CREATURE_SHADOW
    // whatever lights it, it stays a dark shape
    col = uBodyCap * col / (uBodyCap + col);
    float rim = uRim * cf * cf * cf * cf;
#ifdef CREATURE_SKIN
    // smoke crawling over the skin: the body breathes darker and lighter, the rim flickering through it
    float crawl = cNoise(vRest * 1.7 + vec3(0.0, -uCreatureTime * 0.35, uCreatureTime * 0.12));
    col *= 0.7 + 0.6 * crawl;
    rim *= 0.6 + 0.8 * smoothstep(0.35, 0.85, crawl);
#endif
    col += uRimColor * rim;
    // a slight response to the torch that saturates: even inches from the torch it stays a shadow
    col += (fl / (1.0 + fl)) * (uTorchSheen * pow(cf, 1.5) * clamp(dot(n, l) + 0.35, 0.0, 1.0));
#endif
#ifdef CREATURE_MASK
    // porcelain, relit: the light round it comes from above and the cavities hold it back (whatever turns down,
    // under the brow, the nose, the lips, the cheekbones and the chin, holds shadow; the sockets are deep and dark),
    // and it takes the torch hard but saturating, so the relief and the grime still read inches from the lens
    float hemi = 0.15 + 0.85 * smoothstep(-0.75, 0.85, n.y);
    vec3 flSat = fl / (1.0 + 1.1 * fl);
    vec3 direct = diffuse + (flSat - fl) * ndl;
    direct = direct / (1.0 + 0.55 * direct);
    col = albedo * (light * uMaskAmbient * hemi * cAo + direct * mix(1.0, cAo, 0.7)) + spec * cAo * (1.0 - 0.6 * cGrime);
    col = col / (1.0 + 0.3 * col);
    col *= mix(1.0, cHoleShade, cHole);
    col *= 1.0 - cInner;
    col *= 1.0 - 0.96 * cBack;
    col += cEmit;
#endif
#ifdef CREATURE_HAZE
    float wisp = cNoise(vRest * 2.6 + vec3(0.0, -uCreatureTime * 0.9, 0.0));
    float haze = smoothstep(0.62, 0.98, cf) * (0.45 + 0.55 * wisp) * uHaze;
    if (cBayer(gl_FragCoord.xy) < haze) discard;
#endif
    if (uFade < 0.999) {
#ifdef CREATURE_DISSOLVE_DETAIL
      float dn = cNoise(vRest * 2.3 + vec3(0.0, uCreatureTime * 0.6, 0.0)) * 0.6 + cNoise(vRest * 7.1) * 0.28
        + cNoise(vRest * 19.0 - vec3(0.0, uCreatureTime * 1.3, 0.0)) * 0.12;
#else
      float dn = cNoise(vRest * 2.3 + vec3(0.0, uCreatureTime * 0.6, 0.0));
#endif
      dn = mix(dn, 1.0 - clamp(vRest.y / 11.5, 0.0, 1.0), 0.4);
      dn += (cHash(gl_FragCoord.xy + fract(uCreatureTime * 13.0) * 97.0) - 0.5) * 0.14 * (1.0 - uFade);
      float th = uFade * 1.16 - 0.08;
      if (dn > th) discard;
      float edge = 1.0 - smoothstep(0.0, 0.09, th - dn);
      col += uEdgeColor * (edge * 2.2);
#ifdef CREATURE_DISSOLVE_DETAIL
      // embers: sparks flaring along the edge as it burns away
      float ember = step(0.93, cHash3(floor(vRest * 34.0) + floor(uCreatureTime * 14.0))) * (1.0 - smoothstep(0.0, 0.05, th - dn));
      col += mix(uEdgeColor, vec3(1.0), 0.6) * (ember * 5.0);
#endif
    }
  }
#endif
`;

function splice(source, anchor, text, before) {
  const i = source.indexOf(anchor);
  if (i < 0) return null;
  return before ? source.slice(0, i) + text + source.slice(i) : source.slice(0, i + anchor.length) + text + source.slice(i + anchor.length);
}

/** The world material's shaders with the creature's shading spliced in (null if the engine's shader changed). */
export function creatureShaders(vertexShader, fragmentShader) {
  let v = splice(vertexShader, VERT_DECL, V_DECL, false);
  v = v && splice(v, VERT_BODY, V_BODY, false);
  let f = splice(fragmentShader, FRAG_IN, F_IN, false);
  f = f && splice(f, FRAG_DECL, F_DECL, false);
  f = f && splice(f, FRAG_ALBEDO, F_ALBEDO, false);
  f = f && splice(f, FRAG_VIEW, F_NORMAL, true);
  f = f && splice(f, FRAG_FOG, F_FOG, true);
  return v && f ? { vertexShader: v, fragmentShader: f } : null;
}

/**
 * Which look a creature chunk's material gets: 'Shell' (the Marble chunk: Roblox's mask parts, replaced by the
 * sculpt) | 'Glow' (the Neon pinpricks) | 'Drawn' (the Fabric detail Roblox renders) | 'Shadow'.
 */
export function chunkKind(material) {
  const key = String((material && material.userData && material.userData.key) || '').split('|')[0];
  if (key.startsWith('Marble')) return 'Shell';
  if (key.startsWith('Fabric')) return 'Drawn';
  if (material && material.uniforms && material.uniforms.uEmissive && material.uniforms.uEmissive.value > 0) return 'Glow';
  return 'Shadow';
}

const _faceRest = new THREE.Matrix4();
const _attach = new THREE.Matrix4();

function cfMatrix(c, out) {
  return out.set(c[3], c[4], c[5], c[0], c[6], c[7], c[8], c[1], c[9], c[10], c[11], c[2], 0, 0, 0, 1);
}

const sculpts = new WeakMap();

/** The sculpt's geometry for a meta (built once, shared by the Creature and the reveal's phantom). */
function sculptFor(meta, spec, faceToModel) {
  let g = sculpts.get(meta);
  if (g) return g;
  const bones = meta.creature.bones.map((b) => b.name);
  g = buildMaskSculpt(spec, faceToModel, { head: Math.max(0, bones.indexOf('Head')), jaw: Math.max(0, bones.indexOf('Jaw')) }, Look.maskColor);
  sculpts.set(meta, g);
  return g;
}

let warned = false;

function creatureMaterial(base, kind, uniforms) {
  const shaders = creatureShaders(base.vertexShader, base.fragmentShader);
  if (!shaders) {
    if (!warned) console.warn('[creature] the world shader changed: the Creature keeps the plain world material');
    warned = true;
    return null;
  }
  const defines = { ...base.defines, CREATURE: '' };
  defines[kind === 'Mask' ? 'CREATURE_MASK' : 'CREATURE_SHADOW'] = '';
  const own = { ...base.uniforms, ...uniforms };
  // own copies of the per-material values (the base material is no longer drawn)
  own.uRoughness = { value: kind === 'Mask' ? Look.maskRoughness : Look.bodyRoughness };
  own.uReflectance = { value: kind === 'Mask' ? Look.maskReflectance : Look.bodyReflectance };
  const mat = new THREE.RawShaderMaterial({
    glslVersion: THREE.GLSL3,
    vertexShader: shaders.vertexShader,
    fragmentShader: shaders.fragmentShader,
    uniforms: own,
    defines,
    side: THREE.DoubleSide,
  });
  mat.userData = { ...base.userData, creature: kind, castShadow: true };
  return mat;
}

/**
 * Gives a creature model (env.createCreatureModel()) the Creature's look. Returns the handle the views drive:
 *   set({fade, time, pupil, fx}) per frame (fx: the jumpscare's {race, tear, strands, dilate}, mask.js maskFx);
 *   setBudget(budget) with the engine's quality budget (picks the look tier); tierName / tier (the LookTiers entry);
 *   materials (by kind) and sculpt (the mask's mesh) for tools.
 * @param {{object: THREE.Group}} model @param {any} meta world meta (meta.creature) @param {any} [budget]
 */
export function applyCreatureLook(model, meta, budget) {
  const spec = maskSpec(meta);
  const creature = meta.creature;
  const bones = creature.bones.map((b) => b.name);
  const head = creature.bones.find((b) => b.name === 'Head');
  const face = (creature.attachments || []).find((a) => a.name === 'FaceFrontAttachment');
  const faceToModel = new THREE.Matrix4();
  if (head && face) faceToModel.copy(cfMatrix(head.rest, _faceRest).multiply(cfMatrix(face.cframe, _attach)));
  const maskInv = faceToModel.clone().invert();
  const cracks = crackSegments(meta, spec);
  const streaks = streakSegments(meta);
  const widths = [];
  for (let i = 0; i < STREAK_COUNT; i += 4) widths.push(new THREE.Vector4(streaks[i][4], streaks[i + 1][4], streaks[i + 2][4], streaks[i + 3][4]));
  const shared = {
    uFade: { value: 1 },
    uCreatureTime: { value: 0 },
    uEdgeColor: { value: new THREE.Vector3(...Look.edgeColor) },
    uRim: { value: Look.rim },
    uRimColor: { value: new THREE.Vector3(...Look.rimColor) },
    uHaze: { value: Look.haze },
    uTorchSheen: { value: Look.torchSheen },
    uBodyCap: { value: Look.bodyCap },
  };
  const maskUniforms = {
    uMaskInv: { value: maskInv },
    uEye: { value: new THREE.Vector4(spec.eyeX, spec.holeW, spec.holeH, spec.holeDepth) },
    uSlit: { value: new THREE.Vector4(spec.slitY, spec.slitHalf, spec.pupilR, Math.max(0, bones.indexOf('Jaw'))) },
    uSlit2: { value: new THREE.Vector4(spec.slitUpturn, spec.pupilScaleRight, 0, 0) },
    uChip: { value: new THREE.Vector4(spec.chip.x, spec.chip.y, spec.chip.rx, spec.chip.ry) },
    uChipAngle: { value: spec.chip.angle },
    uPupilColor: { value: new THREE.Vector3(...Look.pupilColor) },
    uPupil: { value: 0 },
    uFx: { value: new THREE.Vector4(0, 0, 0, 0) },
    uMaskAmbient: { value: 1 },
    uCracks: { value: cracks.list.map((c) => new THREE.Vector4(...c.seg)) },
    uCrackInfo: { value: cracks.list.map((c) => new THREE.Vector4(c.width, c.at, c.grow, 0)) },
    uCrackBase: { value: cracks.base },
    uStreaks: { value: streaks.map((s) => new THREE.Vector4(s[0], s[1], s[2], s[3])) },
    uStreakW: { value: widths },
    uDetail: { value: detailTexture() },
  };
  const materials = { Shadow: [], Mask: [], Glow: [], Drawn: [], Shell: [] };
  const glowMeshes = [];
  let shellMaterial = null;
  for (const mesh of model.object.children) {
    const base = mesh.material;
    if (!base || !base.uniforms) continue;
    const kind = chunkKind(base);
    if (kind !== 'Shadow') {
      // the sculpt, the painted pinpricks and detail replace the Roblox shell, the Neon dots and the drawn parts
      mesh.visible = false;
      if (kind === 'Glow') glowMeshes.push(mesh);
      if (kind === 'Shell') shellMaterial = base;
      materials[kind].push(base);
      continue;
    }
    const mat = creatureMaterial(base, kind, shared);
    if (!mat) continue;
    mesh.material = mat;
    materials.Shadow.push(mat);
  }
  let sculpt = null;
  if (shellMaterial) {
    const mat = creatureMaterial(shellMaterial, 'Mask', { ...shared, ...maskUniforms });
    if (mat) {
      sculpt = new THREE.Mesh(sculptFor(meta, spec, faceToModel), mat);
      sculpt.name = 'CreatureMask';
      sculpt.frustumCulled = false;
      sculpt.matrixAutoUpdate = false;
      model.object.add(sculpt);
      materials.Mask.push(mat);
    }
  }
  const drawn = [...materials.Shadow, ...materials.Mask];
  let key = null;
  let fadeCasts = true;
  const look = {
    materials,
    glowMeshes,
    sculpt,
    uniforms: shared,
    mask: maskUniforms,
    tierName: 'Max',
    tier: LookTiers.Max,
    /** Per frame: fade (1 whole .. 0 gone), time (seconds), pupil (0..1 glow), fx (the jumpscare on the mask). */
    set(params) {
      if (params.fade !== undefined) {
        const fade = Math.max(0, Math.min(1, params.fade));
        shared.uFade.value = fade;
        // the torch's shadow pass draws casters without the dissolve: a dissolving body casts no shadow
        const cast = fade > 0.97;
        if (cast !== fadeCasts) {
          fadeCasts = cast;
          this._casting();
        }
      }
      if (params.time !== undefined) shared.uCreatureTime.value = params.time % 1000;
      if (params.pupil !== undefined) maskUniforms.uPupil.value = Math.max(0, Math.min(1, params.pupil));
      if (params.fx) maskUniforms.uFx.value.set(params.fx.race || 0, params.fx.tear || 0, params.fx.strands || 0, params.fx.dilate || 0);
      if (params.fx) maskUniforms.uMaskAmbient.value = 1 - 0.65 * (params.fx.focus || 0);
    },
    _casting() {
      const cast = fadeCasts && this.tier.shadow;
      for (const mat of drawn) mat.userData.castShadow = cast;
    },
    /** The engine's quality budget: picks the look tier (LookTiers) and follows the world's lights and torch shadow. */
    setBudget(b) {
      if (!b) return;
      const name = lookTierFor(b);
      const next = `${name}|${b.pointLights}|${b.flashlightShadow}`;
      if (next === key) return;
      key = next;
      this.tierName = name;
      this.tier = LookTiers[name];
      const t = this.tier;
      const flag = (d, define, on) => {
        if (on) d[define] = '';
        else delete d[define];
      };
      for (const mat of drawn) {
        const d = mat.defines;
        d.NUM_POINT = String(b.pointLights ?? d.NUM_POINT);
        flag(d, 'USE_SHADOW', !!b.flashlightShadow);
        const shadowBody = mat.userData.creature === 'Shadow';
        flag(d, 'CREATURE_HAZE', shadowBody && t.haze);
        flag(d, 'CREATURE_SKIN', shadowBody && t.skin);
        flag(d, 'CREATURE_DETAIL', !shadowBody && t.detail);
        flag(d, 'CREATURE_PARALLAX', !shadowBody && t.parallax);
        flag(d, 'CREATURE_DISSOLVE_DETAIL', t.dissolveDetail);
        mat.needsUpdate = true;
      }
      this._casting();
    },
  };
  look.setBudget(budget || { tier: 'High', pointLights: 4, flashlightShadow: true });
  return look;
}
