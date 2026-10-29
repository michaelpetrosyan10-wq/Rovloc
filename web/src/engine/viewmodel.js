// Viewmodel: the first-person hands and the torch they carry (HandRig.luau). The web has no R15 body under the
// camera, so the right forearm and hand (and the left one for two-handed poses) are drawn as a viewmodel over the
// world (rendered after it with the depth cleared, so it never clips into walls), placed by HandRig's own maths.
//
// Torch: the procedural flashlight (knurled body, rubber grip band, tail cap, switch, flared head, chrome lens ring,
// lens that glows while lit), HandRig's dimensions. Poses (setPose(name, target?)):
//   Flashlight  right hand holding the torch along the look (follows PITCH_SHARE of the pitch from the shoulder),
//               lowered to the hip while sprinting; Free: hands down (out of view); Pry / Ripcord / SlitGrip: both
//               hands at fixed offsets in the target's frame; Flask: the right hand at the target itself.
// While the body needs both hands (crawling, swimming, grabbed, parachuting) Flashlight / Flask fall back to Free.
// `hands.right` / `hands.left` are the hand frames: held props (a flask) can be parented to them.

import * as THREE from 'three';
import { createWorldMaterial } from './materials.js';
import { dampNumber, smoothstep } from './math.js';

const SHOULDER = new THREE.Vector3(1, -0.84, 0.34);
const HOLD_REACH = new THREE.Vector3(-0.45, 0.09, -1.59);
const LOWERED_REACH = new THREE.Vector3(-0.45, -0.76, -0.84);
const LOWERED_TILT = (-38 * Math.PI) / 180;
const PITCH_SHARE = 0.8;
const LOWER_SPEED = 9;
const HAND_MOUNT = new THREE.Vector3(0, -0.08, -0.12);
const BUSY = new Set(['VentCrawling', 'VentScurrying', 'DownedCrawling', 'Treading', 'Freestyle', 'Underwater',
  'Grabbed', 'Parachuting']);
export const Poses = Object.freeze(['Flashlight', 'Free', 'Pry', 'Ripcord', 'SlitGrip', 'Flask']);

const BODY_COLOR = [38, 40, 43];
const GRIP_COLOR = [20, 20, 21];
const RING_COLOR = [150, 152, 156];
const LENS_OFF = [196, 206, 214];
const LENS_ON = [255, 240, 214];
const SKIN = [186, 132, 100];
const SLEEVE = [46, 50, 58];

function colored(geo, rgb) {
  const n = geo.attributes.position.count;
  const c = new Float32Array(n * 3);
  for (let i = 0; i < n; i++) {
    c[i * 3] = rgb[0] / 255;
    c[i * 3 + 1] = rgb[1] / 255;
    c[i * 3 + 2] = rgb[2] / 255;
  }
  geo.setAttribute('color', new THREE.BufferAttribute(c, 3));
  return geo;
}

/** A cylinder along the torch's Z axis (length, diameter) centred at z. */
function cyl(length, diameter, z, rgb, segments = 14) {
  const g = new THREE.CylinderGeometry(diameter / 2, diameter / 2, length, segments, 1, false);
  g.rotateX(Math.PI / 2);
  g.translate(0, 0, z);
  return colored(g, rgb);
}

export class Viewmodel {
  /** @param {{shared: any, scene: THREE.Scene}} deps */
  constructor(deps) {
    this.root = new THREE.Group();
    this.root.name = 'Viewmodel';
    deps.scene.add(this.root);
    this.material = createWorldMaterial(deps.shared, { baked: false, roughness: 0.55, reflectance: 0.05 });
    this.lensMaterial = createWorldMaterial(deps.shared, { baked: false, roughness: 0.2, emissive: 0 });
    this.pose = 'Flashlight';
    /** @type {THREE.Matrix4|null} */
    this.target = null;
    this.lowered = 0;
    this.hands = { right: new THREE.Group(), left: new THREE.Group() };
    this.root.add(this.hands.right, this.hands.left);

    // torch (in the right hand's frame, offset by HAND_MOUNT)
    this.torch = new THREE.Group();
    const parts = [
      cyl(0.86, 0.24, 0, BODY_COLOR),
      cyl(0.34, 0.27, 0.12, GRIP_COLOR),
      cyl(0.08, 0.26, 0.45, BODY_COLOR),
      cyl(0.26, 0.34, -0.56, BODY_COLOR),
      cyl(0.05, 0.36, -0.71, RING_COLOR),
      colored(new THREE.BoxGeometry(0.07, 0.05, 0.14).translate(0, 0.13, -0.18), GRIP_COLOR),
    ];
    for (const g of parts) this.torch.add(new THREE.Mesh(g, this.material));
    this.lens = new THREE.Mesh(cyl(0.03, 0.28, -0.735, LENS_OFF), this.lensMaterial);
    this.torch.add(this.lens);
    this.torch.position.copy(HAND_MOUNT);
    this.lensLit = null;

    // hands and forearms
    this.rightHand = this._hand();
    this.hands.right.add(this.rightHand);
    this.hands.right.add(this.torch);
    this.leftHand = this._hand();
    this.hands.left.add(this.leftHand);
    this.rightArm = this._forearm();
    this.leftArm = this._forearm();
    this.root.add(this.rightArm, this.leftArm);
    for (const o of [this.root]) o.traverse((m) => {
      m.frustumCulled = false;
    });
  }

  /** A fist closed around the torch grip (hand frame: -Z along the torch, the grip at HAND_MOUNT). */
  _hand() {
    const g = new THREE.Group();
    const parts = [];
    // back of the hand on the outside (right) of the grip, the wrist behind it
    parts.push(new THREE.BoxGeometry(0.1, 0.26, 0.3).translate(0.17, -0.06, 0.05));
    parts.push(new THREE.BoxGeometry(0.22, 0.22, 0.14).translate(0.08, -0.12, 0.24));
    // four fingers curled under and around the grip
    for (let i = 0; i < 4; i++) {
      // a ring around the torch axis (Z) from the upper left, under the grip, to the upper right
      const finger = new THREE.TorusGeometry(0.19, 0.052, 6, 10, Math.PI * 1.22);
      finger.rotateZ(-3.49);
      finger.translate(0, -0.08, -0.06 + i * 0.075);
      parts.push(finger);
    }
    // thumb across the top of the grip
    parts.push(new THREE.CylinderGeometry(0.05, 0.055, 0.24, 8).rotateZ(Math.PI / 2 - 0.35).translate(0.02, 0.07, -0.02));
    for (const p of parts) g.add(new THREE.Mesh(colored(p, SKIN), this.material));
    return g;
  }

  _forearm() {
    const g = colored(new THREE.CylinderGeometry(0.16, 0.19, 1, 10, 1, true).rotateX(Math.PI / 2), SLEEVE);
    const m = new THREE.Mesh(g, this.material);
    m.matrixAutoUpdate = false;
    return m;
  }

  /** @param {string} name @param {THREE.Matrix4|null} [target] */
  setPose(name, target = null) {
    if (!Poses.includes(name)) return;
    this.pose = name;
    this.target = target ? target.clone() : null;
  }

  /** The torch lens frame (world). */
  lensPosition(out = new THREE.Vector3()) {
    return this.lens.getWorldPosition(out).add(_v.set(0, 0, -0.75));
  }

  /**
   * @param {{dt: number, eye: THREE.Vector3, yaw: number, pitch: number, moveState: string, lit: boolean,
   *   active: boolean, probe: THREE.Color}} ctx
   */
  update(ctx) {
    this.lowered = dampNumber(this.lowered, ctx.moveState === 'Sprinting' ? 1 : 0, LOWER_SPEED, ctx.dt);
    this.material.uniforms.uProbe.value.set(ctx.probe.r, ctx.probe.g, ctx.probe.b);
    this.lensMaterial.uniforms.uProbe.value.set(ctx.probe.r, ctx.probe.g, ctx.probe.b);
    if (this.lensLit !== ctx.lit) {
      this.lensLit = ctx.lit;
      const c = ctx.lit ? LENS_ON : LENS_OFF;
      const attr = this.lens.geometry.attributes.color;
      for (let i = 0; i < attr.count; i++) attr.setXYZ(i, c[0] / 255, c[1] / 255, c[2] / 255);
      attr.needsUpdate = true;
      this.lensMaterial.uniforms.uEmissive.value = ctx.lit ? 3 : 0;
      this.lensMaterial.defines.EMISSIVE = '';
      this.lensMaterial.needsUpdate = true;
    }
    let pose = this.pose;
    if ((pose === 'Flashlight' || pose === 'Flask') && BUSY.has(ctx.moveState)) pose = 'Free';
    if (!ctx.active) pose = 'Free';
    if (pose !== 'Flashlight' && pose !== 'Free' && !this.target) pose = 'Free';
    this.root.visible = pose !== 'Free';
    if (pose === 'Free') return;

    const heading = _heading.makeRotationY(ctx.yaw).setPosition(ctx.eye);
    const shoulder = _sh.copy(SHOULDER).applyMatrix4(heading);
    let right = null;
    let left = null;
    this.torch.visible = pose === 'Flashlight';
    if (pose === 'Flashlight') {
      right = flashlightTarget(ctx.eye, ctx.yaw, ctx.pitch, this.lowered, _r);
    } else if (pose === 'Flask') {
      right = _r.copy(this.target);
    } else if (pose === 'Pry') {
      right = _r.copy(this.target).multiply(_o.compose(_p.set(0.42, 0.12, 0.05), _qa.setFromEuler(_e.set(-1.22, 0, -0.17)), _one));
      left = _l.copy(this.target).multiply(_o.compose(_p.set(-0.42, 0.12, 0.05), _qa.setFromEuler(_e.set(-1.22, 0, 0.17)), _one));
    } else if (pose === 'Ripcord') {
      right = _r.copy(this.target).multiply(_o.makeRotationX(-0.35));
      left = _l.copy(this.target).multiply(_o.compose(_p.set(-0.9, 0.55, 0.2), _qa.setFromEuler(_e.set(0, 0, 0.26)), _one));
    } else if (pose === 'SlitGrip') {
      right = _r.copy(this.target).multiply(_o.compose(_p.set(0.55, 0.06, 0.12), _qa.setFromEuler(_e.set(-0.17, 0, -0.07)), _one));
      left = _l.copy(this.target).multiply(_o.compose(_p.set(-0.55, 0.06, 0.12), _qa.setFromEuler(_e.set(-0.17, 0, 0.07)), _one));
    }
    this._place(this.hands.right, this.rightArm, right, shoulder);
    const leftShoulder = _ls.set(-SHOULDER.x, SHOULDER.y, SHOULDER.z).applyMatrix4(heading);
    this._place(this.hands.left, this.leftArm, left, leftShoulder);
  }

  _place(hand, arm, frame, shoulder) {
    hand.visible = !!frame;
    arm.visible = !!frame;
    if (!frame) return;
    frame.decompose(hand.position, hand.quaternion, _s);
    // forearm from the wrist toward the elbow (a little below the shoulder-hand midpoint)
    _a.set(0, 0, 0.14).applyQuaternion(hand.quaternion).add(hand.position);
    _b.copy(shoulder).lerp(hand.position, 0.42);
    _b.y -= 0.35;
    const len = _a.distanceTo(_b);
    _mid.copy(_a).add(_b).multiplyScalar(0.5);
    _m.lookAt(_a, _b, _up);
    arm.matrix.compose(_mid, _qa.setFromRotationMatrix(_m), _s.set(1, 1, len));
  }
}

/** The right-hand frame holding the torch along the look (HandRig.flashlightTarget); lowered 0..1 = sprint carry. */
export function flashlightTarget(eye, yaw, pitch, lowered, out = new THREE.Matrix4()) {
  const heading = _h2.makeRotationY(yaw).setPosition(eye);
  const shoulder = _h3.copy(heading).multiply(_t.makeTranslation(SHOULDER.x, SHOULDER.y, SHOULDER.z));
  const raised = _h4.copy(shoulder).multiply(_t.makeRotationX(pitch * PITCH_SHARE));
  const heldPos = _hp.copy(HOLD_REACH).applyMatrix4(raised);
  const lookDir = _ld.set(-Math.sin(yaw) * Math.cos(pitch), Math.sin(pitch), -Math.cos(yaw) * Math.cos(pitch));
  _lm.lookAt(heldPos, _tp.copy(heldPos).add(lookDir), _up);
  _hq.setFromRotationMatrix(_lm);
  const carryPos = _cp.copy(LOWERED_REACH).applyMatrix4(shoulder);
  _cq.setFromEuler(_e2.set(LOWERED_TILT, yaw, 0, 'YXZ'));
  const t = smoothstep(0, 1, lowered);
  _hp.lerp(carryPos, t);
  _hq.slerp(_cq, t);
  return out.compose(_hp, _hq, _one);
}

const _v = new THREE.Vector3();
const _heading = new THREE.Matrix4();
const _sh = new THREE.Vector3();
const _ls = new THREE.Vector3();
const _r = new THREE.Matrix4();
const _l = new THREE.Matrix4();
const _o = new THREE.Matrix4();
const _p = new THREE.Vector3();
const _qa = new THREE.Quaternion();
const _e = new THREE.Euler();
const _one = new THREE.Vector3(1, 1, 1);
const _s = new THREE.Vector3();
const _a = new THREE.Vector3();
const _b = new THREE.Vector3();
const _mid = new THREE.Vector3();
const _m = new THREE.Matrix4();
const _up = new THREE.Vector3(0, 1, 0);
const _h2 = new THREE.Matrix4();
const _h3 = new THREE.Matrix4();
const _h4 = new THREE.Matrix4();
const _t = new THREE.Matrix4();
const _hp = new THREE.Vector3();
const _ld = new THREE.Vector3();
const _lm = new THREE.Matrix4();
const _tp = new THREE.Vector3();
const _hq = new THREE.Quaternion();
const _cp = new THREE.Vector3();
const _cq = new THREE.Quaternion();
const _e2 = new THREE.Euler();
