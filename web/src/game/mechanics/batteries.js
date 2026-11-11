// batteries.js: the batteries that feed the radar and the torch (docs/design/game-spec-v2.md 3.2; FlashlightService's
// pickups). The run's plan picks them (worldData.pickBatteries, RunDirector's rules: one 20-60 walked from the entry,
// one near the floor's main station, every pair 30 apart, none in a dead end); a squad of n uses the first
// RadarRules.batteriesPlaced of each sneaking stage's picks (the squad's size at the deploy: run.players). The export
// built a battery on every candidate anchor; the run shows the placed ones and hides the rest.
//
//   Pickup   the battery's Pickup prompt: RadarRules.battery gives +BatteryCharge radar charge and +BatteryTorch of the
//            torch, each to its full, and the battery is gone (co-op: personal, first come: the host grants the claim).
//            With the radar's charges and the torch both full its prompt reads "Full" instead and the battery stays.
//   LED      every placed battery blinks a cold-white LED: on LedOn seconds every LedPeriod (meta.radarConfig), each
//            battery at its own phase; an unlit, unfogged mesh, the same on every graphics tier (I10).
// live(level) lists the batteries still lying on a level ({id, point}): the radar shows those within DotRange.

import * as THREE from 'three';
import { radarRules } from '../rules/radar.js';
import { S } from '../strings/index.js';
import '../strings/kit.js';
import { hash } from '../util.js';

const LED_COLOR = new THREE.Color(0.86, 0.94, 1);
const LED_RADIUS = 0.07;
const LED_LIFT = 0.28;

export class Batteries {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Batteries';
    this.game = game;
    this.env = game.env;
    this.rules = radarRules(game.world.meta);
    /** @type {Map<string, {id: string, level: string, point: THREE.Vector3, led: THREE.Mesh, phase: number, pickup: any, full: any}>} */
    this.placed = new Map();
    this.ledGeometry = new THREE.SphereGeometry(LED_RADIUS, 10, 8);
    this.ledMaterial = new THREE.MeshBasicMaterial({ color: LED_COLOR, fog: false, toneMapped: false });
  }

  beginRun(run) {
    this._clear();
    const { env, world } = this.game;
    const ids = new Set();
    for (const level of Object.keys(run.plan.batteries || {})) {
      for (const id of world.batteriesOf(run.plan, level, run.players, this.rules.batteriesPlaced)) ids.add(id);
    }
    for (const info of world.entities('Battery')) {
      const live = ids.has(info.id);
      env.setEntityVisible(info.id, live);
      env.setEntityPivot(info.id, info.pivot);
      if (live) this._place(info);
    }
  }

  endRun() {
    this._clear();
  }

  _clear() {
    for (const b of this.placed.values()) this._remove(b);
    this.placed.clear();
  }

  _remove(b) {
    b.led.removeFromParent();
    b.pickup.remove();
    b.full.remove();
  }

  _place(info) {
    const env = this.env;
    const spec = info.prompts.find((p) => p.name === 'Pickup') || info.prompts[0];
    const at = env.attachmentWorld(info.id, 'PromptPoint');
    const point = at ? new THREE.Vector3().setFromMatrixPosition(at) : new THREE.Vector3(info.pivot[0], info.pivot[1], info.pivot[2]);
    const led = new THREE.Mesh(this.ledGeometry, this.ledMaterial);
    led.position.copy(point);
    led.position.y += LED_LIFT;
    led.visible = false;
    env.addToScene(led);
    const base = {
      entity: info.id,
      attachment: spec ? spec.host : 'PromptPoint',
      objectText: S('Prompt.Battery'),
      distance: spec ? spec.maxDistance : 7,
      requiresLineOfSight: false,
    };
    const b = { id: info.id, level: info.level, point, led, phase: (hash(info.id) % 1000) / 1000, pickup: null, full: null };
    b.pickup = env.addPrompt({
      ...base,
      text: S('Prompt.Pickup'),
      holdSeconds: spec ? spec.holdDuration : 0.25,
      // co-op: the first teammate to take it has it; on the other pages it is just gone
      net: 'claim',
      netRemote: () => this._gone(b),
      onTriggered: () => this._take(b),
    });
    // both full: the prompt reads Full and a press only clicks; nothing is taken (this page alone)
    b.full = env.addPrompt({ ...base, text: S('Prompt.Full'), holdSeconds: 0, net: 'local', enabled: false,
      onTriggered: () => env.play('UiBack') });
    this.placed.set(info.id, b);
  }

  /** RadarRules.battery: +1 charge and +45 torch, each to its full; gone once taken. */
  _take(b) {
    const g = this.game;
    if (!g.alive() || !this.placed.has(b.id)) return;
    const torch = this.env.meters().battery;
    const r = this.rules.battery(g.run.difficulty, g.radar.charges, torch.value, torch.max);
    if (!r.taken) return;
    g.radar.setCharges(r.charges);
    torch.set(r.torch);
    g.playAt('Pickup', b.point);
    this._gone(b);
  }

  _gone(b) {
    if (!this.placed.has(b.id)) return;
    this.env.setEntityVisible(b.id, false);
    this._remove(b);
    this.placed.delete(b.id);
  }

  /** Whether this page's player holds a full radar and a full torch (a battery would not be taken). */
  _full() {
    const g = this.game;
    const torch = this.env.meters().battery;
    return !this.rules.battery(g.run ? g.run.difficulty : 'Standard', g.radar.charges, torch.value, torch.max).taken;
  }

  /** The batteries still lying on `level`: [{id, point}]. */
  live(level) {
    const out = [];
    for (const b of this.placed.values()) if (b.level === level) out.push({ id: b.id, point: b.point });
    return out;
  }

  tick() {
    if (!this.placed.size) return;
    const full = this._full();
    for (const b of this.placed.values()) {
      b.pickup.setEnabled(!full);
      b.full.setEnabled(full);
    }
  }

  frame() {
    const c = this.rules.config;
    const now = this.env.now();
    for (const b of this.placed.values()) b.led.visible = (now / c.LedPeriod + b.phase) % 1 < c.LedOn / c.LedPeriod;
  }
}
