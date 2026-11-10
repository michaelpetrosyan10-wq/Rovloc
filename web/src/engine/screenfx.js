// Screen tear for the Creature's scares: a hook in the post pass (renderer.js splices these into its shader) that tears
// the finished frame into static: horizontal bands slipping sideways, a chromatic split, and static over it. Driven by
// postUniforms.uTear = (split, tear, static, seed): split and tear in uv units, static 0..1 (the share of the frame
// replaced by noise), seed changes the band pattern; and postUniforms.uTearTint = (r, g, b, amount): the jumpscare's
// red flash, the frame graded into that colour by its brightness (its darks stay black). All zero (the default) leaves
// the frame untouched and costs two branches per pixel.

import * as THREE from 'three';

/** Declarations (after the post shader's uniforms). */
export const SCREEN_FX_DECL = /* glsl */ `
uniform vec4 uTear; // x chromatic split, y band slip (uv), z static 0..1, w seed
uniform vec4 uTearTint; // rgb the flash's colour, a amount: the frame graded into it by brightness
`;

/** Replaces the post shader's scene fetch (`vec3 c = sceneSample(vUv);`: FXAA and the lens fringe when the tier has them). */
export const SCREEN_FX_SAMPLE = /* glsl */ `
  vec3 c;
  if (uTear.x + uTear.y > 0.0) {
    float band = floor(vUv.y * 26.0 + uTear.w * 7.0);
    float bh = fract(sin(band * 91.7 + uTear.w * 13.1) * 43758.5453);
    float slip = (bh - 0.5) * 2.0 * uTear.y * step(0.55, bh);
    float fine = (fract(sin(floor(vUv.y * 190.0) * 12.3 + uTear.w * 3.7) * 9341.7) - 0.5) * uTear.y * 0.3;
    vec2 tuv = vec2(vUv.x + slip + fine, vUv.y);
    c.r = texture(tScene, tuv + vec2(uTear.x, 0.0)).r;
    c.g = texture(tScene, tuv).g;
    c.b = texture(tScene, tuv - vec2(uTear.x, uTear.x * 0.35)).b;
  } else {
    c = sceneSample(vUv);
  }
`;

/** Before the post shader's output: the static. */
export const SCREEN_FX_FINISH = /* glsl */ `
  if (uTearTint.a > 0.0) {
    float lum = dot(c, vec3(0.299, 0.587, 0.114));
    c = mix(c, min(uTearTint.rgb * (lum * 1.9 + 0.06), vec3(1.0)), uTearTint.a);
  }
  if (uTear.z > 0.0) {
    float sn = hash(floor(vUv * vec2(330.0, 190.0)) + fract(uTime * 23.7) * 61.0);
    float roll = step(0.5, fract(vUv.y * 70.0 + uTime * 37.0)) * 0.18;
    c = mix(c, vec3(sn * (0.82 + roll)), uTear.z);
  }
`;

/** The uniforms the hook adds to the post material. */
export function screenFxUniforms() {
  return { uTear: { value: new THREE.Vector4(0, 0, 0, 0) }, uTearTint: { value: new THREE.Vector4(1, 0.1, 0.08, 0) } };
}
