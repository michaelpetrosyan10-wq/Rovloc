// hints.js: one short line the first time something new turns up (FirstTimeHints).
//
// TutorialConfig.Hints, highest priority first: the stairwell airlock (near its vestibule, or its countdown), a downed
// teammate (never solo), the first bear trap, flask, vent grate or locker within the hint's radius on the current
// level, getting into the water, a low battery with the light on. Each shows once ever: its hidden setting
// (Hint<Id>) is set the moment it shows and saved with the settings. After the airlock come the floor objective's
// stations and locks (FloorObjectives.hintSpots: a Hint.Obj.<what> line the first time one is within HintRadius of the
// eye with a clear line; once ever, saved under ObjectiveHintsSeen). The card: a taped strip below the crosshair with
// the line and the device's input glyphs, HintSeconds long, HintGap quiet seconds between two; it ends when the floor
// changes. Never at a bad moment: only Alive in a run with "First-time hints" on, the HUD visible, no onboarding
// screen, outside the Cutscene / Menu / Struggle / Locker / Trapped / Parachute contexts, under no Cutscene /
// Jumpscare / Drag lock, not while the Creature chases you, not while the panic is above HintPanicMax.

import * as THREE from 'three';
import { TutorialConfig } from '../config.js';
import { S } from '../strings.js';
import { cfPos } from '../util.js';
import { glyphFor } from './nav.js';
import { ObjectiveTuning } from '../objectives/config.js';
import { Palette, el } from './style.js';

const T = TutorialConfig.Timing;
const SCAN = 0.25;
const FADE_IN = 3;
const FADE_OUT = 2;
const QUICK_FADE_OUT = 6;
// a locker, a trap and a grab show their own lines; a first-time card about flasks or grates does not belong there
const BLOCKED_CONTEXTS = new Set(['Cutscene', 'Menu', 'Struggle', 'Locker', 'Trapped', 'Parachute']);
const BLOCKED_LOCKS = new Set(['Cutscene', 'Jumpscare', 'Drag']);
const WATER_STATES = new Set(['Treading', 'Freestyle', 'Underwater']);
const GRATE_SHUT = new Set(['Closed', 'Unscrewing', 'Locked']);
const AIRLOCK_HINT_RADIUS = 22;
const OBJECTIVE_HINTS = 'ObjectiveHintsSeen';

export class Hints {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Hints';
    this.game = game;
    this.env = game.env;
    this.clock = 0;
    this.alpha = 0;
    this.showing = null;
    this.shownAt = -Infinity;
    this.endedAt = -Infinity;
    this.scannedAt = -Infinity;
    /** @type {Set<string>} */
    this.due = new Set();
    this.positions = new Map();
    for (const type of ['Locker', 'VentGrate']) {
      for (const e of game.world.entities(type)) this.positions.set(e.id, cfPos(e.pivot));
    }
    const root = this.env.uiRoot();
    this.card = el('div', 'rg-sheet', root);
    Object.assign(this.card.style, { position: 'absolute', left: '50%', top: '60%', transform: 'translateX(-50%) rotate(-0.4deg)',
      width: 'min(460px, 92vw)', padding: '12px 16px', opacity: '0', display: 'none', pointerEvents: 'none', zIndex: '13' });
    el('div', 'rg-tape l', this.card);
    this.text = el('div', 'rg-body', this.card, '');
    this.text.style.fontSize = '15px';
    this.inputs = el('div', '', this.card);
    Object.assign(this.inputs.style, { display: 'flex', gap: '16px', marginTop: '8px', flexWrap: 'wrap' });
  }

  /** The airlock just sealed: nothing to do (the hint is driven by the countdown). */
  noteSeal() {}

  _seen() {
    const out = {};
    for (const h of TutorialConfig.Hints) out[h.id] = !!this.env.setting(h.setting);
    return out;
  }

  _allowed() {
    const g = this.game;
    return !!this.env.setting(TutorialConfig.HintsSetting) && g.phase === 'InRun' && g.life.state === 'Alive' &&
      this.env.hudVisible() && !(g.onboarding && g.onboarding.busy()) && !BLOCKED_CONTEXTS.has(this.env.context()) &&
      !BLOCKED_LOCKS.has(g.controlLock()) && !g.creature.chasingPlayer() && this.env.panic() <= T.HintPanicMax;
  }

  _nearCheckpoint(level, from) {
    const v = this.game.world.checkpointVolumes(level)[0];
    return !!v && Math.hypot(v.cframe[0] - from.x, v.cframe[2] - from.z) <= AIRLOCK_HINT_RADIUS && Math.abs(v.cframe[1] - from.y) < 8;
  }

  _near(id, from, radius) {
    const p = this.positions.get(id);
    return !!p && p.distanceTo(from) <= radius;
  }

  _scan(seen) {
    const g = this.game;
    this.due.clear();
    if (g.phase !== 'InRun' || g.life.state !== 'Alive' || !g.level) return;
    const level = g.level;
    const from = this.env.rootPosition(_from);
    const radius = (id) => (TutorialConfig.Hints.find((h) => h.id === id) || {}).radius || 0;
    // what the stairwell airlock does, told on the way in (alone, Waiting lasts one poll: the doors are already
    // sealing by the time a countdown hint could show, and it used to ride on into the next floor)
    if (!seen.Airlock && g.airlock.level === level && (g.airlock.phase === 'Waiting' ||
      (g.airlock.phase === 'Idle' && this._nearCheckpoint(level, from)))) {
      this.due.add('Airlock');
    }
    if (!seen.BearTrap && g.traps) {
      for (const t of g.traps.traps) {
        if (t.state === 'Armed' && t.level === level && t.floor.distanceTo(from) <= radius('BearTrap')) {
          this.due.add('BearTrap');
          break;
        }
      }
    }
    if (!seen.Flask && g.flasks) {
      for (const f of g.flasks.pickupsOn(level)) {
        if (f.position.distanceTo(from) <= radius('Flask')) {
          this.due.add('Flask');
          break;
        }
      }
    }
    if (!seen.VentGrate && g.vents) {
      for (const gr of g.vents.gratesOn(level)) {
        if (GRATE_SHUT.has(gr.state) && this._near(gr.id, from, radius('VentGrate'))) {
          this.due.add('VentGrate');
          break;
        }
      }
    }
    if (!seen.Locker) {
      for (const e of g.world.entities('Locker', level)) {
        if (this._near(e.id, from, radius('Locker'))) {
          this.due.add('Locker');
          break;
        }
      }
    }
    if (WATER_STATES.has(this.env.moveState())) this.due.add('Water');
    if (!seen.LowBattery) {
      const b = this.env.meters().battery;
      const f = b.max > 0 ? b.value / b.max : 0;
      if (this.env.flashlightOn() && f > 0 && f <= TutorialConfig.LowBatteryFraction) this.due.add('LowBattery');
    }
  }

  /** The objective hints already shown (saved: once ever, like the settings' Hint flags). */
  _objectiveSeen() {
    const v = this.env.saveGet(OBJECTIVE_HINTS, []);
    return Array.isArray(v) ? v.slice() : [];
  }

  /** The first objective station / lock of this floor in reach and in sight whose hint has not shown yet, or null. */
  _scanObjective() {
    const g = this.game;
    if (!g.floors || g.phase !== 'InRun' || g.life.state !== 'Alive' || !g.level) return null;
    const seen = new Set(this._objectiveSeen());
    const eye = this.env.eye(_eye);
    for (const spot of g.floors.hintSpots(g.level)) {
      if (seen.has(spot.key)) continue;
      if (spot.point.distanceTo(eye) > (spot.radius || ObjectiveTuning.HintRadius)) continue;
      if (this.env.lineClear(eye, spot.point, { ignoreEntities: true })) return spot.key;
    }
    return null;
  }

  _fill(hint) {
    const env = this.env;
    this.text.textContent = S(hint.text);
    this.inputs.textContent = '';
    for (const input of hint.inputs) {
      const row = el('div', '', this.inputs);
      Object.assign(row.style, { display: 'flex', alignItems: 'center', gap: '6px' });
      const device = env.device();
      el('span', `rg-key${device === 'KeyboardMouse' ? '' : ' round'}`, row, glyphFor(env, input.action, device));
      const label = el('span', 'rg-caps', row, S(input.label));
      label.style.color = Palette.Bone;
    }
  }

  frame(dt) {
    this.clock += dt;
    const ok = this._allowed();
    const seen = this._seen();
    if (this.clock - this.scannedAt >= SCAN) {
      this.scannedAt = this.clock;
      if (TutorialConfig.Hints.some((h) => !seen[h.id])) this._scan(seen);
      else this.due.clear();
      this.objectiveDue = this._scanObjective();
    }
    if (this.showing) {
      // a card belongs to the floor it came up on: the airlock's "step inside" must not ride into the next floor
      const stale = this.showing.level !== this.game.level;
      if (!ok || stale || this.clock - this.shownAt >= T.HintSeconds) {
        this.showing = null;
        this.endedAt = this.clock;
      }
    } else if (ok && this.clock - this.endedAt >= T.HintGap) {
      // the airlock first, then a station or lock of the floor objective seen for the first time, then the rest
      let next = TutorialConfig.Hints.find((h) => this.due.has(h.id) && !seen[h.id]);
      // (still a hint spot now: the step may have been done since the scan)
      const spots = this.game.floors && this.game.level ? this.game.floors.hintSpots(this.game.level) : [];
      if (this.objectiveDue && !spots.some((x) => x.key === this.objectiveDue)) this.objectiveDue = null;
      if (this.objectiveDue && (!next || next.id !== 'Airlock')) {
        next = { id: this.objectiveDue, text: this.objectiveDue, inputs: [], objective: true };
      }
      if (next) {
        this.showing = { ...next, level: this.game.level };
        this.shownAt = this.clock;
        this._fill(next);
        if (next.objective) {
          const done = this._objectiveSeen();
          done.push(next.id);
          this.env.saveSet(OBJECTIVE_HINTS, done);
          this.objectiveDue = null;
        } else this.env.setSetting(next.setting, true);
      }
    }
    const target = this.showing ? 1 : 0;
    const speed = target > this.alpha ? FADE_IN : ok ? FADE_OUT : QUICK_FADE_OUT;
    this.alpha += Math.sign(target - this.alpha) * Math.min(Math.abs(target - this.alpha), dt * speed);
    this.card.style.display = this.alpha > 0.001 ? '' : 'none';
    this.card.style.opacity = String(this.alpha);
  }
}

const _from = new THREE.Vector3();
const _eye = new THREE.Vector3();
