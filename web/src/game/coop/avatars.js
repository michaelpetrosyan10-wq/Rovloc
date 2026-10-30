// avatars.js: the other players as this page draws them (Roblox's teammate characters, RemoteFlashlightRenderer and the
// name tags), from the interpolated poses.
//
// Body. A procedural low-poly survivor in the school's look, built from code: boxes for the hips, torso, head, hair,
// backpack and the jointed limbs (upper / lower arm, thigh / shin with a shoe), a torch in the right hand; the jacket
// takes the member's slot colour. Twelve parts per avatar, node-batched in one mesh (one draw call each): every part's
// frame and the probe light where they stand are written to a NodeTable texture, the same path the Creature's rig uses,
// and the world material lights them (your torch included) and casts their shadow in it.
// Motion, procedural from the MoveState and the measured speed: a walk / run cycle (legs and opposite arms swinging
// with the stride, a bob), the crouch walk (hips low, knees bent), the duct crawl (body flat, limbs pawing), swimming
// (treading upright with sculling arms; freestyle and underwater flat with strokes and a flutter kick), downed (prone,
// dragging on the arms), dead (prone, still), trapped (one knee down), grabbed (thrashing), the parachute's freefall
// and canopy (arms up). A flask they hold shows in their left fist, a parachute pack they wear on their back. Hidden in
// a locker or left behind (spectating), the body is not drawn; neither is the teammate this page is spectating through
// (the camera is in their eyes), whose torch still lights the way they look.
// Torch. While theirs is on: a faint visible beam from the hand along their look (lowered while sprinting) and a dynamic
// light where it lands (one ray every BEAM_RAY seconds), so you see where a teammate is looking from round a corner.
// Name tag. Their name over the head (DOWN in red while downed, a reviving ring), fading out beyond TAG_FAR studs and
// while the head is behind a wall (a ray every TAG_RAY seconds); the HUD's teammate list carries the rest.

import * as THREE from 'three';
import { NodeTable } from '../../engine/batch.js';
import { createWorldMaterial } from '../../engine/materials.js';
import { PoseFlags } from '../../net/codec.js';
import { Palette, el } from '../ui/style.js';
import { C } from './strings.js';

const PARTS = 14;
const P = { Pelvis: 0, Torso: 1, Head: 2, Pack: 3, UpperArmL: 4, ForearmL: 5, UpperArmR: 6, ForearmR: 7, ThighL: 8,
  ShinL: 9, ThighR: 10, ShinR: 11, Flask: 12, Chute: 13 };
const FLASK_GLASS = [150, 190, 170];
const FLASK_LIQUID = [120, 210, 90];
const CHUTE = [88, 92, 60];
const JACKETS = [[104, 112, 78], [138, 88, 60], [72, 96, 116], [128, 116, 90]];
const PANTS = [44, 44, 50];
const SKIN = [192, 156, 126];
const HAIR = [52, 40, 32];
const PACK = [74, 62, 48];
const SHOE = [30, 28, 26];
const TORCH = [42, 42, 44];
const LENS = [236, 224, 196];
const ROOT_TO_HIP = 0.85;
const THIGH = 1.05;
const SHIN = 1.0;
const UPPER_ARM = 0.95;
const FOREARM = 0.9;
const BEAM_LENGTH = 22;
const BEAM_RAY = 0.1;
const BEAM_RANGE = 60;
const SPLASH_RANGE = 11;
const SPLASH_BRIGHTNESS = 0.4;
const SPLASH_COLOR = [255, 226, 190];
const TAG_FAR = 70;
const TAG_RAY = 0.25;
const SAME_LEVEL_SLACK = 40;
const SWIM_STATES = new Set(['Treading', 'Freestyle', 'Underwater', 'Grabbed']);
const ANIM_SMOOTH = 10;

/** Box geometry centred at (cx, cy, cz) in part space, coloured, tagged with a node slot. */
function box(w, h, d, cx, cy, cz, rgb, slot) {
  const g = new THREE.BoxGeometry(w, h, d).toNonIndexed();
  g.translate(cx, cy, cz);
  return tag(g, rgb, slot);
}

function cylinder(r, h, cx, cy, cz, rgb, slot, rotX = 0) {
  const g = new THREE.CylinderGeometry(r, r, h, 8, 1, false).toNonIndexed();
  if (rotX) g.rotateX(rotX);
  g.translate(cx, cy, cz);
  return tag(g, rgb, slot);
}

function tag(g, rgb, slot) {
  const n = g.attributes.position.count;
  const color = new Float32Array(n * 3);
  const node = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    color[i * 3] = rgb[0] / 255;
    color[i * 3 + 1] = rgb[1] / 255;
    color[i * 3 + 2] = rgb[2] / 255;
    node[i] = slot;
  }
  g.setAttribute('color', new THREE.BufferAttribute(color, 3));
  g.setAttribute('node', new THREE.BufferAttribute(node, 1));
  return g;
}

function merge(parts) {
  let count = 0;
  for (const g of parts) count += g.attributes.position.count;
  const out = new THREE.BufferGeometry();
  for (const [name, size] of [['position', 3], ['normal', 3], ['uv', 2], ['color', 3], ['node', 1]]) {
    const arr = new Float32Array(count * size);
    let o = 0;
    for (const g of parts) {
      const a = g.attributes[name].array;
      arr.set(a, o);
      o += a.length;
    }
    out.setAttribute(name, new THREE.BufferAttribute(arr, size));
  }
  for (const g of parts) g.dispose();
  out.boundingSphere = new THREE.Sphere(new THREE.Vector3(), 1e6);
  return out;
}

/** The survivor's parts in part space (each joint at its part's origin, limbs hanging down -Y, facing -Z). */
function survivorGeometry(base, jacket) {
  const s = (i) => base + i;
  const parts = [
    // hips
    box(1.3, 0.55, 0.75, 0, 0, 0, PANTS, s(P.Pelvis)),
    // torso (from the waist up) with a collar
    box(1.55, 1.75, 0.85, 0, 0.9, 0, jacket, s(P.Torso)),
    box(0.95, 0.18, 0.7, 0, 1.82, 0, jacket, s(P.Torso)),
    // head (neck at the origin), hair cap, a face plane hint
    box(0.42, 0.3, 0.4, 0, 0.12, 0, SKIN, s(P.Head)),
    box(0.95, 0.95, 0.9, 0, 0.72, 0, SKIN, s(P.Head)),
    box(1.0, 0.32, 0.95, 0, 1.18, 0.04, HAIR, s(P.Head)),
    box(1.0, 0.55, 0.3, 0, 0.92, 0.36, HAIR, s(P.Head)),
    // backpack on the torso's back (+Z is behind)
    box(1.15, 1.25, 0.5, 0, 0.95, 0.66, PACK, s(P.Pack)),
    box(0.9, 0.35, 0.32, 0, 0.35, 0.82, PACK, s(P.Pack)),
    // arms: sleeves, then forearm and hand
    box(0.48, UPPER_ARM, 0.5, 0, -UPPER_ARM / 2, 0, jacket, s(P.UpperArmL)),
    box(0.42, FOREARM - 0.25, 0.44, 0, -(FOREARM - 0.25) / 2, 0, jacket, s(P.ForearmL)),
    box(0.36, 0.3, 0.38, 0, -FOREARM + 0.12, 0, SKIN, s(P.ForearmL)),
    box(0.48, UPPER_ARM, 0.5, 0, -UPPER_ARM / 2, 0, jacket, s(P.UpperArmR)),
    box(0.42, FOREARM - 0.25, 0.44, 0, -(FOREARM - 0.25) / 2, 0, jacket, s(P.ForearmR)),
    box(0.36, 0.3, 0.38, 0, -FOREARM + 0.12, 0, SKIN, s(P.ForearmR)),
    // the torch held along the forearm's end, its lens pointing out of the fist (-Y of the forearm)
    cylinder(0.11, 0.75, 0, -FOREARM - 0.05, -0.18, TORCH, s(P.ForearmR), Math.PI / 2),
    cylinder(0.14, 0.12, 0, -FOREARM - 0.05, -0.58, LENS, s(P.ForearmR), Math.PI / 2),
    // legs
    box(0.6, THIGH, 0.62, 0, -THIGH / 2, 0, PANTS, s(P.ThighL)),
    box(0.54, SHIN, 0.56, 0, -SHIN / 2, 0, PANTS, s(P.ShinL)),
    box(0.58, 0.28, 0.9, 0, -SHIN - 0.02, -0.14, SHOE, s(P.ShinL)),
    box(0.6, THIGH, 0.62, 0, -THIGH / 2, 0, PANTS, s(P.ThighR)),
    box(0.54, SHIN, 0.56, 0, -SHIN / 2, 0, PANTS, s(P.ShinR)),
    box(0.58, 0.28, 0.9, 0, -SHIN - 0.02, -0.14, SHOE, s(P.ShinR)),
    // a chemical flask in the left fist (shown while one is held)
    cylinder(0.2, 0.42, 0, -0.25, 0, FLASK_LIQUID, s(P.Flask)),
    cylinder(0.08, 0.3, 0, 0.08, 0, FLASK_GLASS, s(P.Flask)),
    // the parachute pack strapped over the backpack (shown while one is worn)
    box(1.3, 1.45, 0.42, 0, 0.95, 1.04, CHUTE, s(P.Chute)),
    box(1.1, 0.12, 0.08, 0, 1.45, -0.46, CHUTE, s(P.Chute)),
  ];
  return merge(parts);
}

/** A unit cone along -Z (apex at the origin) for the visible beam. */
function beamGeometry() {
  const g = new THREE.ConeGeometry(Math.tan(THREE.MathUtils.degToRad(19)) * BEAM_LENGTH, BEAM_LENGTH, 18, 1, true);
  g.translate(0, -BEAM_LENGTH / 2, 0);
  g.rotateX(Math.PI / 2);
  return g;
}

const _m = new THREE.Matrix4();
const _r = new THREE.Matrix4();
const _t = new THREE.Matrix4();
const _q = new THREE.Quaternion();
const _e = new THREE.Euler();
const _v = new THREE.Vector3();
const _v2 = new THREE.Vector3();
const _dir = new THREE.Vector3();
const _probe = new THREE.Color();

/** Rotation from Euler angles (XYZ) as a Matrix4. */
function rot(x, y, z, out = _r) {
  _e.set(x, y, z, 'XYZ');
  return out.makeRotationFromEuler(_e);
}

/** One teammate's drawn body, beam, light and tag. */
class Avatar {
  constructor(avatars, member, base) {
    this.avatars = avatars;
    this.member = member;
    this.base = base;
    const jacket = JACKETS[member.slot % JACKETS.length];
    this.mesh = new THREE.Mesh(survivorGeometry(base, jacket), avatars.material);
    this.mesh.frustumCulled = false;
    this.mesh.matrixAutoUpdate = false;
    this.mesh.name = `Avatar:${member.name}`;
    avatars.env.addToScene(this.mesh);
    this.beam = new THREE.Mesh(avatars.beamGeometry, avatars.beamMaterial);
    this.beam.frustumCulled = false;
    this.beam.renderOrder = 11;
    this.beam.visible = false;
    avatars.env.addToScene(this.beam);
    this.light = null;
    this.tag = el('div', 'rg-caps rg-outline', avatars.tags, '');
    Object.assign(this.tag.style, { position: 'absolute', transform: 'translate(-50%, -100%)', whiteSpace: 'nowrap',
      fontSize: '12px', color: Palette.Bone, opacity: '0', pointerEvents: 'none', textAlign: 'center' });
    this.pose = {};
    /** the parts' world frames (P order), reused every frame */
    this.frames = Array.from({ length: PARTS }, () => new THREE.Matrix4());
    this.phase = 0;
    this.speed = 0;
    this.lastPos = null;
    this.blend = { crouch: 0, prone: 0, swim: 0 };
    this.rayClock = Math.random() * BEAM_RAY;
    this.tagClock = Math.random() * TAG_RAY;
    this.tagVisible = 1;
    this.hitPoint = new THREE.Vector3();
    this.hasHit = false;
    this.shown = false;
  }

  dispose() {
    const env = this.avatars.env;
    env.removeFromScene(this.mesh);
    env.removeFromScene(this.beam);
    this.mesh.geometry.dispose();
    for (let i = 0; i < PARTS; i++) this.avatars.table.setMode(this.base + i, 0);
    if (this.light) this.light.remove();
    this.light = null;
    this.tag.remove();
  }

  _hide() {
    if (this.shown) {
      for (let i = 0; i < PARTS; i++) this.avatars.table.setMode(this.base + i, 0);
      this.shown = false;
    }
    this.beam.visible = false;
    if (this.light) this.light.set({ enabled: false });
    this.tag.style.opacity = '0';
  }

  /** Draws the member at real time `t`. */
  frame(dt, t, ctx) {
    const m = this.member;
    const pose = m.sample(t, this.pose);
    // spectated: the camera is in their eyes, so their body and beam are not drawn, but their torch still lights
    const spectated = ctx.spectating === m.id;
    if (!pose || (!spectated && !ctx.visible(m, pose))) {
      this._hide();
      return;
    }
    const table = this.avatars.table;
    // measured speed (horizontal), smoothed
    if (this.lastPos) {
      const d = Math.hypot(pose.x - this.lastPos.x, pose.z - this.lastPos.z);
      const v = dt > 1e-4 && d < 12 ? d / dt : 0;
      this.speed += (v - this.speed) * Math.min(1, dt * ANIM_SMOOTH);
    } else this.lastPos = new THREE.Vector3();
    this.lastPos.set(pose.x, pose.y, pose.z);
    const state = pose.moveState;
    const life = pose.life;
    const dead = life === 'Dead';
    const downed = life === 'Downed' || state === 'DownedCrawling';
    const vent = (pose.flags & PoseFlags.Vent) !== 0 || state === 'VentCrawling' || state === 'VentScurrying';
    const swim = (pose.flags & PoseFlags.Swim) !== 0 || SWIM_STATES.has(state);
    const flatSwim = swim && (state === 'Freestyle' || state === 'Underwater' || state === 'Grabbed');
    const crouch = state === 'Crouching' || state === 'Trapped';
    const prone = dead || downed || vent || flatSwim;
    const k = Math.min(1, dt * 8);
    this.blend.crouch += ((crouch ? 1 : 0) - this.blend.crouch) * k;
    this.blend.prone += ((prone ? 1 : 0) - this.blend.prone) * k;
    // gait phase from the distance covered
    const stride = vent || downed ? 1.6 : swim ? 2.2 : crouch ? 2.2 : 3.4;
    this.phase += (this.speed * dt) / stride * Math.PI;
    if (dead) this.phase = 0;
    const moving = Math.min(1, this.speed / 6);
    const sway = Math.sin(this.phase);
    const cosw = Math.cos(this.phase);
    const run = state === 'Sprinting' ? 1 : 0;

    // body frame: root, yaw; prone poses lie along the facing (head forward)
    const body = _m.makeTranslation(pose.x, pose.y, pose.z).multiply(rot(0, pose.yaw, 0));
    const proneAngle = -Math.PI / 2 * this.blend.prone;
    let drop = 0;
    if (crouch) drop = 0.9 * this.blend.crouch;
    if (prone) drop = vent ? 0.9 : flatSwim ? 0 : 2.3;
    drop *= prone ? this.blend.prone : 1;
    body.multiply(_t.makeTranslation(0, -drop, 0));
    if (this.blend.prone > 0.01) {
      // lying down pivots about the hips
      body.multiply(_t.makeTranslation(0, -ROOT_TO_HIP, 0)).multiply(rot(proneAngle, 0, 0));
      body.multiply(_t.makeTranslation(0, ROOT_TO_HIP, 0));
    }
    const bob = prone ? 0 : Math.abs(cosw) * 0.12 * moving * (1 + run);
    const f = this.frames;
    const pelvis = f[P.Pelvis].copy(body).multiply(_t.makeTranslation(0, -ROOT_TO_HIP + bob, 0));
    const lean = prone ? 0 : (-0.12 * moving - 0.18 * run - 0.35 * this.blend.crouch);
    const torso = f[P.Torso].copy(pelvis).multiply(_t.makeTranslation(0, 0.25, 0)).multiply(rot(lean, sway * 0.05 * moving, 0));
    const headPitch = prone ? Math.max(-0.2, pose.pitch * 0.5 + 0.9 * this.blend.prone) : pose.pitch * 0.6 - lean;
    const head = f[P.Head].copy(torso).multiply(_t.makeTranslation(0, 1.92, 0)).multiply(rot(headPitch, 0, 0));
    f[P.Pack].copy(torso);

    // limbs
    let legL = 0;
    let legR = 0;
    let kneeL = 0;
    let kneeR = 0;
    let armL = 0;
    let armR = 0;
    let elbowL = -0.25;
    let elbowR = -0.25;
    let spreadL = 0.08;
    let spreadR = -0.08;
    const torchOn = (pose.flags & PoseFlags.Torch) !== 0 && !dead;
    if (dead) {
      armL = -0.3;
      armR = -0.3;
      spreadL = 0.5;
      spreadR = -0.5;
    } else if (downed) {
      // dragging on the forearms
      armL = -2.6 + sway * 0.45 * moving;
      armR = -2.6 - sway * 0.45 * moving;
      elbowL = -0.9;
      elbowR = -0.9;
      legL = 0.15 + cosw * 0.15 * moving;
      legR = 0.15 - cosw * 0.15 * moving;
      kneeL = 0.35;
      kneeR = 0.35;
    } else if (vent) {
      armL = -2.4 + sway * 0.6 * Math.max(0.3, moving);
      armR = -2.4 - sway * 0.6 * Math.max(0.3, moving);
      elbowL = -1.0;
      elbowR = -1.0;
      legL = 0.6 - sway * 0.4 * moving;
      legR = 0.6 + sway * 0.4 * moving;
      kneeL = 1.4;
      kneeR = 1.4;
    } else if (swim) {
      if (flatSwim) {
        const stroke = this.phase * 0.8;
        armL = -Math.PI + Math.sin(stroke) * 1.6;
        armR = -Math.PI + Math.sin(stroke + Math.PI) * 1.6;
        legL = Math.sin(this.phase * 3) * 0.35;
        legR = -legL;
        if (state === 'Grabbed') {
          armL = -2.2 + Math.sin(t * 13) * 0.9;
          armR = -2.2 + Math.sin(t * 11 + 1) * 0.9;
          legL = Math.sin(t * 9) * 0.6;
          legR = -legL;
        }
      } else {
        spreadL = 0.9 + Math.sin(t * 3) * 0.35;
        spreadR = -spreadL;
        armL = -0.3;
        armR = -0.3;
        legL = Math.sin(t * 2.6) * 0.45;
        legR = -legL;
        kneeL = 0.5;
        kneeR = 0.5;
      }
    } else if (state === 'Parachuting' || state === 'Freefall' || (pose.flags & PoseFlags.Pack && state === 'Falling')) {
      armL = -2.7;
      armR = -2.7;
      spreadL = 0.4;
      spreadR = -0.4;
      legL = 0.2;
      legR = -0.1;
      kneeL = 0.4;
      kneeR = 0.6;
    } else if (state === 'Trapped') {
      legL = -1.2;
      kneeL = 1.9;
      legR = 0.35;
      kneeR = 0.2;
      armL = -0.9;
      armR = -0.9;
      elbowL = -1.1;
      elbowR = -1.1;
    } else {
      const amp = (0.55 + 0.35 * run) * moving;
      legL = sway * amp;
      legR = -sway * amp;
      kneeL = Math.max(0, -cosw) * (0.6 + run * 0.5) * moving + 0.9 * this.blend.crouch;
      kneeR = Math.max(0, cosw) * (0.6 + run * 0.5) * moving + 0.9 * this.blend.crouch;
      legL -= 0.7 * this.blend.crouch;
      legR -= 0.7 * this.blend.crouch;
      armL = -sway * amp * 0.8;
      armR = sway * amp * 0.8;
      elbowL = -0.3 - 0.6 * run;
      elbowR = -0.3 - 0.6 * run;
    }
    // the torch arm points along the look (lowered while sprinting), whatever the gait
    if (torchOn && !prone && state !== 'Trapped') {
      const lowered = (pose.flags & PoseFlags.Lowered) !== 0;
      armR = -Math.PI / 2 + (pose.pitch - lean) - (lowered ? 0.5 : 0);
      elbowR = -0.08;
      spreadR = -0.06;
    }
    const upperL = f[P.UpperArmL].copy(torso).multiply(_t.makeTranslation(-0.98, 1.62, 0)).multiply(rot(armL, 0, spreadL));
    f[P.ForearmL].copy(upperL).multiply(_t.makeTranslation(0, -UPPER_ARM, 0)).multiply(rot(elbowL, 0, 0));
    const upperR = f[P.UpperArmR].copy(torso).multiply(_t.makeTranslation(0.98, 1.62, 0)).multiply(rot(armR, 0, spreadR));
    const foreR = f[P.ForearmR].copy(upperR).multiply(_t.makeTranslation(0, -UPPER_ARM, 0)).multiply(rot(elbowR, 0, 0));
    const thighL = f[P.ThighL].copy(pelvis).multiply(_t.makeTranslation(-0.34, -0.12, 0)).multiply(rot(legL, 0, 0));
    f[P.ShinL].copy(thighL).multiply(_t.makeTranslation(0, -THIGH, 0)).multiply(rot(kneeL, 0, 0));
    const thighR = f[P.ThighR].copy(pelvis).multiply(_t.makeTranslation(0.34, -0.12, 0)).multiply(rot(legR, 0, 0));
    f[P.ShinR].copy(thighR).multiply(_t.makeTranslation(0, -THIGH, 0)).multiply(rot(kneeR, 0, 0));
    f[P.Flask].copy(f[P.ForearmL]).multiply(_t.makeTranslation(0, -FOREARM - 0.1, -0.1));
    f[P.Chute].copy(torso);

    this.avatars.env.probeAt(_v.set(pose.x, pose.y, pose.z), _probe);
    const dim = dead ? 0.45 : 1;
    const flask = pose.held === 'Flask' || pose.held === 'AcidFlask';
    const chute = (pose.flags & PoseFlags.Pack) !== 0;
    for (let i = 0; i < PARTS; i++) {
      let mode = spectated ? 0 : 2;
      if ((i === P.Flask && !flask) || (i === P.Chute && !chute)) mode = 0;
      table.setMatrix(this.base + i, f[i]);
      table.setLight(this.base + i, _probe.r * dim, _probe.g * dim, _probe.b * dim, mode);
    }
    this.shown = !spectated;

    // the beam and its light
    if (torchOn) {
      const lens = _v.set(0, -FOREARM - 0.05, -0.65).applyMatrix4(foreR);
      const dir = _dir.set(0, 0, -1).applyAxisAngle(_v2.set(1, 0, 0), pose.pitch - ((pose.flags & PoseFlags.Lowered) ? 0.35 : 0))
        .applyAxisAngle(_v2.set(0, 1, 0), pose.yaw).normalize();
      _q.setFromUnitVectors(_v2.set(0, 0, -1), dir);
      this.beam.position.copy(lens);
      this.beam.quaternion.copy(_q);
      this.beam.visible = ctx.beams && !spectated;
      this.rayClock += dt;
      if (this.rayClock >= BEAM_RAY) {
        this.rayClock = 0;
        const hit = this.avatars.env.raycast(lens, dir, BEAM_RANGE, { ignoreEntities: false });
        this.hasHit = !!hit;
        if (hit) this.hitPoint.copy(hit.point || hit.position || lens).addScaledVector(dir, -1.5);
      }
      if (this.hasHit) {
        if (!this.light) this.light = this.avatars.env.addLight({ position: this.hitPoint.clone(), color: SPLASH_COLOR,
          brightness: SPLASH_BRIGHTNESS, range: SPLASH_RANGE });
        this.light.set({ position: this.hitPoint, enabled: true });
      } else if (this.light) this.light.set({ enabled: false });
    } else {
      this.beam.visible = false;
      if (this.light) this.light.set({ enabled: false });
    }

    // the name tag
    if (spectated) {
      this.tag.style.opacity = '0';
      return;
    }
    this.tagClock += dt;
    const headPos = _v.set(0, 1.6, 0).applyMatrix4(head);
    const camera = ctx.camera;
    const distance = camera.distanceTo(headPos);
    if (this.tagClock >= TAG_RAY) {
      this.tagClock = 0;
      this.tagVisible = distance < TAG_FAR && this.avatars.env.lineClear(camera, headPos, { ignoreEntities: true }) ? 1 : 0;
    }
    const screen = distance < TAG_FAR ? this.avatars.env.project(headPos) : null;
    const fade = Math.max(0, Math.min(1, (TAG_FAR - distance) / 20)) * this.tagVisible;
    if (!screen || fade <= 0.01 || Math.abs(screen.ndcX) > 1.1 || Math.abs(screen.ndcY) > 1.1) {
      this.tag.style.opacity = '0';
      return;
    }
    const label = downed ? `${m.name} · ${C('Coop.Status.Downed')}` : dead ? `${m.name} · ${C('Coop.Status.Dead')}` : m.name;
    if (this.tag.textContent !== label) this.tag.textContent = label;
    this.tag.style.color = downed || dead ? Palette.Ember : Palette.Bone;
    this.tag.style.left = `${screen.x.toFixed(1)}px`;
    this.tag.style.top = `${(screen.y - 6).toFixed(1)}px`;
    this.tag.style.opacity = String(fade.toFixed(2));
  }
}

export class Avatars {
  /** @param {import('./index.js').Coop} coop */
  constructor(coop) {
    this.coop = coop;
    this.game = coop.game;
    this.env = coop.game.env;
    const shared = this.env.engine.shared;
    this.table = new NodeTable(PARTS * 4);
    for (let i = 0; i < PARTS * 4; i++) this.table.alloc(new THREE.Matrix4(), 0);
    this.material = createWorldMaterial(shared, { baked: false, nodes: true, nodeTexture: this.table.texture, roughness: 0.7,
      reflectance: 0.04 });
    this.material.userData.castShadow = true;
    this.beamGeometry = beamGeometry();
    this.beamMaterial = new THREE.MeshBasicMaterial({ color: new THREE.Color(1, 0.92, 0.8), transparent: true, opacity: 0.045,
      depthWrite: false, blending: THREE.AdditiveBlending, side: THREE.DoubleSide });
    this.tags = el('div', 'rg-layer', this.env.uiRoot());
    this.tags.style.zIndex = '8';
    /** @type {Map<string, Avatar>} */
    this.list = new Map();
    this.camera = new THREE.Vector3();
  }

  /** Builds / drops avatars to match the squad. */
  sync(members) {
    const want = new Set();
    for (const m of members) {
      if (m.local) continue;
      want.add(m.id);
      const existing = this.list.get(m.id);
      if (existing && existing.member !== m) {
        existing.dispose();
        this.list.delete(m.id);
      }
      if (!this.list.has(m.id)) this.list.set(m.id, new Avatar(this, m, m.slot * PARTS));
    }
    for (const [id, a] of this.list) {
      if (!want.has(id)) {
        a.dispose();
        this.list.delete(id);
      }
    }
  }

  clear() {
    for (const a of this.list.values()) a.dispose();
    this.list.clear();
  }

  /** The avatar of a member (null when not drawn). */
  of(id) {
    return this.list.get(id) || null;
  }

  frame(dt) {
    if (!this.list.size) return;
    const t = performance.now() / 1000;
    this.camera.copy(this.env.camera().position);
    const localLevel = this.coop.localLevel();
    const spectating = this.coop.spectateTargetId();
    const ctx = {
      camera: this.camera,
      beams: this.env.engine.quality.tier !== 'Low',
      spectating,
      visible: (member, pose) => {
        if (pose.life === 'Spectating' || (pose.flags & PoseFlags.Hidden) !== 0 || pose.moveState === 'Hiding') return false;
        if (localLevel && pose.level && pose.level !== localLevel) {
          const dx = pose.x - this.camera.x;
          const dz = pose.z - this.camera.z;
          if (Math.abs(pose.y - this.camera.y) > SAME_LEVEL_SLACK || dx * dx + dz * dz > SAME_LEVEL_SLACK * SAME_LEVEL_SLACK * 4) return false;
        }
        return true;
      },
    };
    for (const a of this.list.values()) a.frame(dt, t, ctx);
    this.table.flush();
  }
}
