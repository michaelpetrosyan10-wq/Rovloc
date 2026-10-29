// Renderer: the WebGL2 context, dynamic-resolution scene target, the flashlight shadow pass, the first-person
// viewmodel pass and one cheap post pass (Roblox's ColorCorrection / Bloom / the panic vignette / film grain).
//
// Frame: [shadow depth (Medium/High, torch on)] -> world into the scaled target -> viewmodel over it (depth cleared)
// -> [bloom: bright pass + two blurs at quarter size (High)] -> post to the canvas: contrast, saturation, lift, tint
// (level grade x panic x lightning), vignette edges, grain. Materials already output tone-mapped display values, so
// the targets are 8-bit.

import * as THREE from 'three';
import { createDepthMaterial } from './materials.js';

const POST_VERT = /* glsl */ `
precision highp float;
in vec3 position;
out vec2 vUv;
void main() { vUv = position.xy * 0.5 + 0.5; gl_Position = vec4(position.xy, 0.0, 1.0); }
`;

const POST_FRAG = /* glsl */ `
precision highp float;
in vec2 vUv;
out vec4 fragColor;
uniform sampler2D tScene;
uniform sampler2D tBloom;
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
uniform vec4 uOverlay; // rgb colour, a amount (underwater murk, flashes)
uniform float uBlur;   // 0..1 cheap radial softening (panic depth of field stand-in)
uniform vec2 uTexel;

float edgeAlpha(float x, float depth) {
  float t = clamp(x / max(depth, 1e-4), 0.0, 1.0);
  float tr = t < 0.45 ? mix(0.0, 0.55, t / 0.45) : mix(0.55, 1.0, (t - 0.45) / 0.55);
  return 1.0 - tr;
}
float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

void main() {
  vec3 c = texture(tScene, vUv).rgb;
  if (uBlur > 0.001) {
    vec2 d = (vUv - 0.5);
    float r = dot(d, d) * 4.0 * uBlur;
    vec2 o = uTexel * 2.0 * r;
    c = (c * 2.0 + texture(tScene, vUv + vec2(o.x, 0.0)).rgb + texture(tScene, vUv - vec2(o.x, 0.0)).rgb
      + texture(tScene, vUv + vec2(0.0, o.y)).rgb + texture(tScene, vUv - vec2(0.0, o.y)).rgb) / 6.0;
  }
  c += texture(tBloom, vUv).rgb * uBloom;
  c = mix(c, uOverlay.rgb, uOverlay.a);
  c += uLift;
  c = (c - 0.5) * (1.0 + uContrast) + 0.5;
  float l = dot(c, vec3(0.299, 0.587, 0.114));
  c = mix(vec3(l), c, 1.0 + uSaturation);
  c *= uTint;
  float side = uVignetteDepth * 0.55;
  float a = edgeAlpha(vUv.y, uVignetteDepth);
  float b = edgeAlpha(1.0 - vUv.y, uVignetteDepth);
  float lft = edgeAlpha(vUv.x, side);
  float rgt = edgeAlpha(1.0 - vUv.x, side);
  float keep = (1.0 - a * uVignette) * (1.0 - b * uVignette) * (1.0 - lft * uVignette) * (1.0 - rgt * uVignette);
  c *= keep;
  float n = hash(vUv * vec2(1931.0, 1213.0) + fract(uTime * 7.31)) - 0.5;
  c += n * uGrain;
  fragColor = vec4(clamp(c, 0.0, 1.0), 1.0);
}
`;

const BRIGHT_FRAG = /* glsl */ `
precision highp float;
in vec2 vUv;
out vec4 fragColor;
uniform sampler2D tScene;
uniform float uThreshold;
void main() {
  vec3 c = texture(tScene, vUv).rgb;
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

function fullscreen(frag, uniforms) {
  return new THREE.RawShaderMaterial({
    glslVersion: THREE.GLSL3,
    vertexShader: POST_VERT,
    fragmentShader: frag,
    uniforms,
    depthTest: false,
    depthWrite: false,
  });
}

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
    this.viewScene = new THREE.Scene();
    this.target = new THREE.WebGLRenderTarget(4, 4, {
      depthBuffer: true,
      type: THREE.UnsignedByteType,
      minFilter: THREE.LinearFilter,
      magFilter: THREE.LinearFilter,
    });
    this.bloomA = new THREE.WebGLRenderTarget(4, 4, { depthBuffer: false });
    this.bloomB = new THREE.WebGLRenderTarget(4, 4, { depthBuffer: false });
    this.black = new THREE.DataTexture(new Uint8Array([0, 0, 0, 255]), 1, 1);
    this.black.needsUpdate = true;

    const quad = new THREE.BufferGeometry();
    quad.setAttribute('position', new THREE.BufferAttribute(new Float32Array([-1, -1, 0, 3, -1, 0, -1, 3, 0]), 3));
    this.post = fullscreen(POST_FRAG, {
      tScene: { value: this.target.texture },
      tBloom: { value: this.black },
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
    });
    this.bright = fullscreen(BRIGHT_FRAG, { tScene: { value: this.target.texture }, uThreshold: { value: 0.72 } });
    this.blur = fullscreen(BLUR_FRAG, { tSrc: { value: null }, uDir: { value: new THREE.Vector2() } });
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

    this.width = 0;
    this.height = 0;
    this.stats = { calls: 0, triangles: 0, internal: [0, 0] };
    this._resize();
    window.addEventListener('resize', () => this._resize());
    quality.scaleChanged.connect(() => this._resizeTarget());
    quality.changed.connect(() => this._applyBudget());
    this._applyBudget();
  }

  _applyBudget() {
    const b = this.quality.budget;
    if (b.flashlightShadow) {
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
    this._resizeTarget();
  }

  _resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
    const w = Math.max(1, Math.floor(this.canvas.clientWidth || window.innerWidth));
    const h = Math.max(1, Math.floor(this.canvas.clientHeight || window.innerHeight));
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
    let h = this.height * dpr * this.quality.scale;
    h = Math.min(h, b.maxHeight * Math.max(this.quality.scale / b.maxScale, 0.5));
    const w = h * (this.width / this.height);
    const iw = Math.max(64, Math.round(w));
    const ih = Math.max(36, Math.round(h));
    if (iw !== this.target.width || ih !== this.target.height) {
      this.target.setSize(iw, ih);
      this.bloomA.setSize(Math.max(16, iw >> 2), Math.max(16, ih >> 2));
      this.bloomB.setSize(Math.max(16, iw >> 2), Math.max(16, ih >> 2));
      this.post.uniforms.uTexel.value.set(1 / iw, 1 / ih);
    }
    this.stats.internal = [iw, ih];
  }

  /**
   * Renders one frame.
   * @param {THREE.Scene} scene the world
   * @param {{shadow?: {position: THREE.Vector3, direction: THREE.Vector3, fov: number, far: number}|null, time: number}} opts
   */
  render(scene, opts) {
    const gl = this.gl;
    gl.info.reset();
    const b = this.quality.budget;
    this.post.uniforms.uTime.value = opts.time;
    this.shared.uTime.value = opts.time;

    // flashlight shadow
    if (b.flashlightShadow && opts.shadow && this.shadowTarget) {
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
    } else {
      this.shared.uShadowOn.value = 0;
    }

    // world + viewmodel
    gl.setRenderTarget(this.target);
    gl.clear(true, true, false);
    gl.render(scene, this.camera);
    if (this.viewScene.children.length) {
      gl.clearDepth();
      gl.render(this.viewScene, this.camera);
    }

    // bloom
    if (b.bloom) {
      this.quad.material = this.bright;
      gl.setRenderTarget(this.bloomA);
      gl.render(this.postScene, this.postCamera);
      this.quad.material = this.blur;
      this.blur.uniforms.tSrc.value = this.bloomA.texture;
      this.blur.uniforms.uDir.value.set(1 / this.bloomA.width, 0);
      gl.setRenderTarget(this.bloomB);
      gl.render(this.postScene, this.postCamera);
      this.blur.uniforms.tSrc.value = this.bloomB.texture;
      this.blur.uniforms.uDir.value.set(0, 1 / this.bloomA.height);
      gl.setRenderTarget(this.bloomA);
      gl.render(this.postScene, this.postCamera);
      this.post.uniforms.tBloom.value = this.bloomA.texture;
    } else {
      this.post.uniforms.tBloom.value = this.black;
      this.post.uniforms.uBloom.value = 0;
    }

    // post to the canvas
    this.quad.material = this.post;
    gl.setRenderTarget(null);
    gl.render(this.postScene, this.postCamera);
    this.stats.calls = gl.info.render.calls;
    this.stats.triangles = gl.info.render.triangles;
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
