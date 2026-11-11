// Offline check of the Creature's animation profile on the baked rig (no GPU): steps the animator in each state and
// reports the crown and eye heights over the floor (standing and hunched), where the face and hands go in the actions,
// and what a step costs.
//
//   node tools/creature-pose-probe.mjs [--build <dir>]

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as THREE from 'three';
import { Animator } from '../src/creature/animator.js';
import { CFrame } from '../src/creature/cframe.js';
import * as Creature from '../src/creature/profile.js';
import { buildJointMap } from '../src/creature/rig.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const i = argv.indexOf('--build');
const buildDir = path.resolve(i >= 0 ? argv[i + 1] : path.join(here, '..', 'build'));
const meta = JSON.parse(fs.readFileSync(path.join(buildDir, 'world.json'), 'utf8'));
const creature = meta.creature;
const map = buildJointMap(creature);
const m = Creature.measure(map);
const ground = map.groundY;
const headRest = CFrame.fromComponents(creature.bones.find((b) => b.name === 'Head').rest);
const crownPart = creature.parts.find((p) => p.name === 'Crown');
const crownInHead = headRest.toObjectSpace(CFrame.fromComponents(crownPart.cf));
const crownRadius = crownPart.size[0] / 2;

function heights(animator) {
  const head = animator.getPartFrame('Head');
  const crown = head.mul(crownInHead).position.y + crownRadius - ground;
  const face = head.mul(m.faceInHead).position;
  return { crown, eye: face.y - ground, faceAhead: -face.z };
}

function run(state, opts = {}) {
  const animator = new Animator(map, Creature.Profile, { seed: 8517 });
  const root = new CFrame(0, -ground, 0);
  Creature.setHunch(map, opts.hunch ? 1 : 0);
  Creature.setFocus(map, false);
  if (opts.target) Creature.setLookTarget(map, opts.target);
  else Creature.setLookTarget(map, null);
  const velocity = new THREE.Vector3(0, 0, -(opts.speed || 0));
  let t = 0;
  const dt = 1 / 30;
  const steps = Math.round((opts.seconds || 2) * 30);
  let cost = 0;
  const samples = [];
  for (let k = 0; k < steps; k++) {
    t += dt;
    if (opts.action && k === (opts.actionAt ?? 1)) Creature.playAction(map, opts.action, t);
    animator.setInputs({ moveState: state, velocity, grounded: true, lookYaw: 0, lookPitch: opts.pitch || 0, time: t });
    const a = performance.now();
    animator.step(dt, root);
    cost += performance.now() - a;
    if (opts.sampleEvery && k % opts.sampleEvery === 0) samples.push({ t: +t.toFixed(2), ...heights(animator) });
  }
  Creature.stopAction(map, null);
  return { ...heights(animator), ms: cost / steps, samples, animator };
}

const fmt = (r) => `crown ${r.crown.toFixed(2)}  eye ${r.eye.toFixed(2)}  face ahead ${r.faceAhead.toFixed(2)}  step ${r.ms.toFixed(3)} ms`;
console.log(`rig: ${creature.bones.length} bones, leg ${m.leg.toFixed(2)}, arm ${m.arm.toFixed(2)}, fingers ${m.fingers.Left.length}+${m.fingers.Right.length}`);
console.log(`metrics: height ${creature.height}, hunched ${creature.hunchedHeight}, eye ${creature.eyeHeight}, hunched eye ${creature.eyeHeights && creature.eyeHeights.Hunched}`);
console.log('stand      ', fmt(run('Patrol', { seconds: 2 })));
console.log('hunched    ', fmt(run('Patrol', { seconds: 3, hunch: true })));
console.log('hunch walk ', fmt(run('Patrol', { seconds: 3, hunch: true, speed: 6 })));
console.log('stalk 7    ', fmt(run('Patrol', { seconds: 3, speed: 7 })));
console.log('chase 16.5 ', fmt(run('Chase', { seconds: 3, speed: 16.5 })));
console.log('investigate', fmt(run('Investigate', { seconds: 3, speed: 4 })));
console.log('stunned    ', fmt(run('Stunned', { seconds: 2 })));
console.log('dormant    ', fmt(run('Dormant', { seconds: 2 })));
const victim = new THREE.Vector3(0, ground + 4.6, -4.2);
const j = run('Patrol', { seconds: 2.4, action: 'Jumpscare', actionAt: 36, target: victim, sampleEvery: 6 });
console.log('jumpscare  ', fmt(j), 'victim eye', (victim.y - ground).toFixed(2));
for (const s of j.samples) console.log(`   t ${s.t}  eye ${s.eye.toFixed(2)}  ahead ${s.faceAhead.toFixed(2)}`);
for (const name of ['Stare', 'LookAway', 'ReachIn', 'FadeOut', 'FadeIn', 'NeckSnap', 'DoorSmash', 'LockerRip', 'Vanish', 'Reveal']) {
  const r = run('Patrol', { seconds: 2.7, action: name, actionAt: 36, target: new THREE.Vector3(0.6, ground + 3.5, -3.2) });
  let bad = false;
  for (const [part, f] of Object.entries(r.animator.frames)) {
    if (!f || !Number.isFinite(f.x) || !Number.isFinite(f.y) || !Number.isFinite(f.z)) bad = part;
  }
  console.log(`${name.padEnd(11)}`, fmt(r), bad ? `NaN in ${bad}` : '');
}
