// life.js: health and life state (LifeStateService), the perks' effects (LoadoutService: syringe charges, battery
// capacity), the battery pickups (FlashlightService) and the downed screen (DownedController), for the one player.
//
// LifeState: Lobby (not in a run) · Alive · Downed · Dead · Spectating.
//   beginRun   Alive at MaxHealth, DownedCount 0, a full battery at the loadout's capacity, switched off.
//   damage     Alive: health drops; lethal damage is a Down. Downed: any damage executes.
//   down       the one lethal path (traps, jumpscares, drowning): the first time in a run -> Downed (DownedCount + 1,
//              health 1, BleedoutEndsAt = now + BleedoutSeconds, a gasp, RunStats TimesDowned); already downed once
//              or Downed now -> execute.
//   revive     Downed -> Alive at a fraction of MaxHealth (default 0.5).  execute: Alive / Downed -> Dead.
// Solo: a Downed player with a syringe charge can get back up (Syringe action, SelfRevive); without one the run's
// evaluator sees nobody left and the run ends; a bleedout that runs out executes.

import * as THREE from 'three';
import { GameConfig, batteryCapacity, syringeCharges } from './config.js';
import { S } from './strings.js';
import { Signal, clamp01, lerp, smoothstep } from './util.js';
import { Palette } from './ui/style.js';
import { el } from './ui/style.js';
import { glyphFor } from './ui/nav.js';

const DEFAULT_REVIVE_FRACTION = 0.5;
const PANIC_REST = 0.3;
const PANIC_PEAK = 0.95;
const SATURATION_FLOOR = 0.85;
const SYRINGE_COOLDOWN = 1;
const FADE_IN = 1.4;
const FADE_OUT = 1.1;
const RING = 96;

export class Life {
  /** @param {import('./game.js').Game} game */
  constructor(game) {
    this.name = 'Life';
    this.game = game;
    this.env = game.env;
    /** @type {'Lobby'|'Alive'|'Downed'|'Dead'|'Spectating'} */
    this.state = 'Lobby';
    this.health = GameConfig.MaxHealth;
    this.downedCount = 0;
    this.bleedoutEndsAt = null;
    this.syringeCharges = 0;
    this.perks = [];
    this.lastSyringeAt = -Infinity;
    /** @type {Signal<[string, string, string]>} (state, previous, cause) */
    this.changed = new Signal();
    /** @type {Signal<[number, string]>} */
    this.damaged = new Signal();
    this.env.onAction('Syringe', (phase) => {
      if (phase === 'Begin') this._syringeKey();
    });
    this.wasEmpty = false;
  }

  /** Alive or Downed. */
  playing() {
    return this.state === 'Alive' || this.state === 'Downed';
  }

  _write(state, cause = '') {
    const previous = this.state;
    if (previous === state) return;
    this.state = state;
    this.env.setLifeState(state);
    if (state === 'Dead' || state === 'Spectating') this.env.setFlashlight(false);
    this.changed.fire(state, previous, cause);
    this.game.match.requestEvaluation();
  }

  beginRun(run) {
    this.perks = run.perks.slice();
    this.health = GameConfig.MaxHealth;
    this.downedCount = 0;
    this.bleedoutEndsAt = null;
    this.syringeCharges = syringeCharges(this.perks);
    const battery = this.env.meters().battery;
    battery.setMax(batteryCapacity(this.perks));
    battery.set(battery.max);
    this.env.setFlashlight(false);
    this.env.setMetersActive(true);
    this.env.setSyringePips(this.syringeCharges);
    this._write('Alive');
    this.wasEmpty = false;
  }

  endRun() {
    this.bleedoutEndsAt = null;
    this.health = GameConfig.MaxHealth;
    this.downedCount = 0;
    this.syringeCharges = 0;
    this.env.setSyringePips(0);
    this.env.setMetersActive(false);
    const battery = this.env.meters().battery;
    battery.setMax(GameConfig.BatteryMax);
    battery.set(battery.max);
    this.env.setFlashlight(false);
    this._write('Lobby');
  }

  /** LifeStateService.lethalAction */
  lethalAction() {
    if (this.state === 'Alive') return this.downedCount <= 0 ? 'Down' : 'Execute';
    if (this.state === 'Downed') return 'Execute';
    return 'Ignore';
  }

  damage(amount, cause) {
    if (!this.game.live() || !Number.isFinite(amount) || amount <= 0) return;
    if (this.state === 'Alive') {
      const remaining = this.health - amount;
      if (remaining <= 0) {
        this.health = 0;
        if (this.lethalAction() === 'Down') this._goDown(cause);
        else this.execute(cause);
      } else {
        this.health = remaining;
      }
    } else if (this.state === 'Downed') {
      this.execute(cause);
    } else {
      return;
    }
    this.damaged.fire(amount, cause);
  }

  down(cause) {
    if (!this.game.live()) return;
    const action = this.lethalAction();
    if (action === 'Down') this._goDown(cause);
    else if (action === 'Execute') this.execute(cause);
  }

  _goDown(cause) {
    this.downedCount += 1;
    this.health = 1;
    this.bleedoutEndsAt = this.env.now() + GameConfig.BleedoutSeconds;
    this.game.stats.increment('TimesDowned');
    this.game.playAt('Gasp', this.env.rootPosition(_p), { volume: 1 });
    this._write('Downed', cause);
  }

  execute(cause) {
    if (!this.game.live() || !this.playing()) return;
    this.bleedoutEndsAt = null;
    this.health = 0;
    this._write('Dead', cause);
  }

  revive(fraction = DEFAULT_REVIVE_FRACTION) {
    if (this.state !== 'Downed') return;
    this.bleedoutEndsAt = null;
    this.health = Math.min(GameConfig.MaxHealth, Math.max(1, (Number.isFinite(fraction) ? fraction : 0.5) * GameConfig.MaxHealth));
    this.game.playAt('Gasp', this.env.rootPosition(_p), { volume: 0.8 });
    this._write('Alive', 'Revive');
  }

  /** Any state -> Alive (checkpoint respawns, dev revives). */
  setAlive(health = GameConfig.MaxHealth) {
    this.bleedoutEndsAt = null;
    this.health = Math.min(GameConfig.MaxHealth, Math.max(1, health));
    this._write('Alive');
  }

  /** Left behind by an airlock: out of play until a checkpoint (solo: the run's evaluator ends it). */
  setSpectating() {
    if (!this.playing()) return;
    this.bleedoutEndsAt = null;
    this._write('Spectating', 'LeftBehind');
  }

  /** LoadoutService.UseSyringe: SelfRevive while Downed, Stamina while Alive; one charge. */
  useSyringe(mode) {
    if (this.syringeCharges < 1 || !this.game.live()) return false;
    if (mode === 'SelfRevive' && this.state !== 'Downed') return false;
    if (mode === 'Stamina' && this.state !== 'Alive') return false;
    this.syringeCharges -= 1;
    this.env.setSyringePips(this.syringeCharges);
    this.game.notify('Hud.SyringeUsed');
    if (mode === 'SelfRevive') this.revive(0.5);
    else this.env.refillStamina();
    return true;
  }

  _syringeKey() {
    const now = this.env.realNow();
    if (now - this.lastSyringeAt < SYRINGE_COOLDOWN) return;
    const mode = this.state === 'Downed' ? 'SelfRevive' : this.state === 'Alive' ? 'Stamina' : null;
    if (!mode || this.syringeCharges <= 0) return;
    this.lastSyringeAt = now;
    this.useSyringe(mode);
  }

  tick(dt, now) {
    if (this.state === 'Downed' && this.bleedoutEndsAt !== null && now >= this.bleedoutEndsAt && this.game.live()) {
      this.execute('Bleedout');
    }
    if (this.game.live()) {
      const empty = this.env.meters().battery.value <= 1e-3;
      if (empty && !this.wasEmpty) this.game.notify('Hud.BatteryEmpty');
      this.wasEmpty = empty;
    }
  }
}

/** FlashlightService's pickups: the plan's batteries on every level, Pickup prompt, Charge added. */
export class BatteryPickups {
  /** @param {import('./game.js').Game} game */
  constructor(game) {
    this.name = 'BatteryPickups';
    this.game = game;
    this.prompts = [];
  }

  beginRun(run) {
    const { env, world } = this.game;
    for (const info of world.entities('Battery')) {
      const live = run.plan.props.has(info.id);
      env.setEntityVisible(info.id, live);
      if (!live) continue;
      const spec = info.prompts.find((p) => p.name === 'Pickup') || info.prompts[0];
      const charge = info.attributes.Charge ?? GameConfig.BatteryPickupCharge;
      const prompt = env.addPrompt({
        entity: info.id,
        attachment: spec ? spec.host : 'PromptPoint',
        text: S('Prompt.Pickup'),
        objectText: S('Prompt.Battery'),
        holdSeconds: spec ? spec.holdDuration : 0.25,
        distance: spec ? spec.maxDistance : 7,
        requiresLineOfSight: false,
        onTriggered: (handle) => {
          if (!this.game.alive()) return;
          const battery = env.meters().battery;
          battery.set(Math.min(battery.max, battery.value + charge));
          this.game.playAt('Pickup', world.attachmentPos(info.id, 'PromptPoint') || env.rootPosition());
          env.setEntityVisible(info.id, false);
          handle.remove();
        },
      });
      this.prompts.push(prompt);
    }
  }

  endRun() {
    for (const p of this.prompts) p.remove();
    this.prompts = [];
  }
}

/** DownedController: the bleedout ring, the way back, the syringe, the blood vignette and the draining colour. */
export class DownedHud {
  /** @param {import('./game.js').Game} game */
  constructor(game) {
    this.name = 'DownedHud';
    this.game = game;
    this.env = game.env;
    this.alpha = 0;
    this.clock = 0;
    const root = this.env.uiRoot();
    this.grade = el('div', 'rg-layer', root);
    this.grade.style.background = 'rgb(128,128,128)';
    this.grade.style.mixBlendMode = 'saturation';
    this.grade.style.opacity = '0';
    this.vignette = el('div', 'rg-layer', root);
    this.vignette.style.background = `radial-gradient(ellipse at center, rgba(0,0,0,0) 45%, ${Palette.Blood} 135%)`;
    this.vignette.style.opacity = '0';
    this.panel = el('div', 'rg-layer', root);
    const box = el('div', '', this.panel);
    Object.assign(box.style, {
      position: 'absolute', left: '50%', top: '62%', transform: 'translate(-50%, -50%)', width: 'min(420px, 92vw)',
      display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '8px', textAlign: 'center',
    });
    this.title = el('div', 'rg-title rg-outline', box, S('Downed.Title'));
    this.title.style.fontSize = '30px';
    this.title.style.color = Palette.Ember;
    const ringWrap = el('div', '', box);
    Object.assign(ringWrap.style, { position: 'relative', width: `${RING}px`, height: `${RING}px` });
    this.ring = this.env.ring(ringWrap, RING, 4, Palette.Ember);
    this.time = el('div', 'rg-title', ringWrap, '35');
    Object.assign(this.time.style, { position: 'absolute', inset: '0', display: 'flex', alignItems: 'center',
      justifyContent: 'center', fontSize: '28px' });
    this.caption = el('div', 'rg-caps', box, S('Hud.Bleedout'));
    this.status = el('div', 'rg-body rg-outline', box, '');
    this.status.style.fontSize = '15px';
    this.syringe = el('button', 'rg-btn', box);
    this.syringeKey = el('span', 'rg-glyph', this.syringe, 'G');
    el('span', '', this.syringe, S('Downed.UseSyringe'));
    this.syringe.style.pointerEvents = 'auto';
    this.syringe.addEventListener('click', () => this.game.life.useSyringe('SelfRevive'));
    this.syringe.addEventListener('touchstart', (e) => {
      e.preventDefault();
      this.game.life.useSyringe('SelfRevive');
    });
    this.panel.style.opacity = '0';
    this.panel.style.display = 'none';
    this.downed = false;
    game.life.changed.connect((state, prev) => this._onLife(state, prev));
  }

  _onLife(state, prev) {
    const env = this.env;
    if (state === 'Downed') {
      this.downed = true;
      env.pushContext('Downed', 'Downed');
      this.panel.style.display = '';
    } else if (prev === 'Downed') {
      this.downed = false;
      env.popContext('Downed');
      env.setPanicFloor('Downed', null);
    }
  }

  frame(dt) {
    const life = this.game.life;
    const env = this.env;
    const showing = this.downed && this.game.live();
    this.alpha += Math.sign((showing ? 1 : 0) - this.alpha) * Math.min(Math.abs((showing ? 1 : 0) - this.alpha),
      (showing ? FADE_IN : FADE_OUT) * dt);
    if (this.alpha <= 0.001) {
      if (this.panel.style.display !== 'none') {
        this.panel.style.display = 'none';
        this.vignette.style.opacity = '0';
        this.grade.style.opacity = '0';
      }
      return;
    }
    this.clock += dt;
    const left = life.bleedoutEndsAt !== null ? Math.max(0, life.bleedoutEndsAt - env.now()) : 0;
    const fraction = clamp01(left / GameConfig.BleedoutSeconds);
    const spent = 1 - fraction;
    this.ring.setProgress(fraction);
    this.time.textContent = String(Math.ceil(left));
    this.status.textContent = S(life.syringeCharges > 0 ? 'Hud.SelfRevive' : 'Downed.NoTeammates');
    this.syringe.style.display = life.syringeCharges > 0 ? '' : 'none';
    this.syringeKey.textContent = glyphFor(env, 'Syringe');
    this.syringeKey.style.display = env.device() === 'Touch' ? 'none' : '';
    if (showing) env.setPanicFloor('Downed', lerp(PANIC_REST, PANIC_PEAK, spent ** 1.2));
    const bpm = lerp(62, 132, spent ** 1.4);
    const beat = 0.5 + 0.5 * Math.sin(this.clock * (bpm / 60) * Math.PI * 2);
    const flash = clamp01(env.setting('FlashScale') ?? 1);
    this.panel.style.opacity = String(this.alpha);
    this.vignette.style.opacity = String(this.alpha * (0.55 + 0.25 * spent + 0.2 * beat * flash));
    this.grade.style.opacity = String(this.alpha * SATURATION_FLOOR * smoothstep(0, 1, spent));
  }

  endRun() {
    this.downed = false;
    this.env.popContext('Downed');
    this.env.setPanicFloor('Downed', null);
  }
}

const _p = new THREE.Vector3();
