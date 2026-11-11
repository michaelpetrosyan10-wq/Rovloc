// lives.js: the lives on the HUD (docs/design/game-spec-v2.md 3.3; the rules are life.js and rules/lives.js).
//
//   Pips       beside the meters, bottom left, through a run: a heart per respawn left (the stage's and the run's), a
//              syringe glyph for the syringe's, and the get-up chevron, grey once used on this stage.
//   Downed     DownedController: the bleed-out ring, its seconds and the draining colour, the blood vignette; from
//              GetUpDelay after going down "HOLD [E] TO GET UP" with the hold's bar (a hold button on touch), or the
//              line that the get-up is spent; the get-up's first-time hint (tutorialConfig's GetUp: once ever, its
//              hidden setting); the teammates' status (each name and how they are).
//   Respawn    RespawnBlackout of black with "NOT YET." while a respawn runs.
//   Dropped    a carried objective item set down where its carrier fell: a marker over it with "<who> dropped it
//              here." on every page for PinSeconds.

import * as THREE from 'three';
import { S } from '../strings/index.js';
import '../strings/run.js';
import { clamp01, lerp, smoothstep } from '../util.js';
import { Palette, el } from './style.js';

const PANIC_REST = 0.3;
const PANIC_PEAK = 0.95;
const SATURATION_FLOOR = 0.85;
const FADE_IN = 1.4;
const FADE_OUT = 1.1;
const BLACK_IN = 6;
const BLACK_OUT = 2;
const RING = 96;
const SVG = 'http://www.w3.org/2000/svg';
const PIN_LIFT = 2.2;

function svg(parent, w, h) {
  const s = document.createElementNS(SVG, 'svg');
  s.setAttribute('width', String(w));
  s.setAttribute('height', String(h));
  s.setAttribute('viewBox', `0 0 ${w} ${h}`);
  parent.appendChild(s);
  return s;
}

function node(parent, tag, attrs) {
  const n = document.createElementNS(SVG, tag);
  for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, String(v));
  parent.appendChild(n);
  return n;
}

/** A heart pip (a stage or run respawn). */
function heart(parent) {
  const s = svg(parent, 16, 15);
  node(s, 'path', { d: 'M8 14 L1.6 7.4 A3.7 3.7 0 0 1 8 2.9 A3.7 3.7 0 0 1 14.4 7.4 Z', fill: Palette.Ember });
  return s;
}

/** The syringe's pip. */
function syringe(parent) {
  const s = svg(parent, 22, 15);
  const g = node(s, 'g', { transform: 'translate(2 11) rotate(-30)' });
  node(g, 'rect', { x: 3, y: -2.5, width: 11, height: 5, rx: 1, fill: 'none', stroke: Palette.Moss, 'stroke-width': 1.5 });
  node(g, 'rect', { x: 4, y: -1.2, width: 6, height: 2.4, fill: Palette.Moss });
  node(g, 'rect', { x: 14, y: -0.6, width: 5, height: 1.2, fill: Palette.Bone });
  node(g, 'rect', { x: -1, y: -2.8, width: 1.4, height: 5.6, fill: Palette.Moss });
  node(g, 'rect', { x: 0.4, y: -0.7, width: 2.6, height: 1.4, fill: Palette.Moss });
  return s;
}

/** The get-up chevron. */
function chevron(parent) {
  const s = svg(parent, 16, 15);
  return node(s, 'polyline', { points: '2,11 8,4 14,11', fill: 'none', stroke: Palette.Bone, 'stroke-width': 2.6,
    'stroke-linecap': 'round', 'stroke-linejoin': 'round' });
}

export class LivesHud {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'LivesHud';
    this.game = game;
    this.env = game.env;
    this.alpha = 0;
    this.clock = 0;
    this.black = 0;
    /** @type {{at: THREE.Vector3, text: string, until: number, el: HTMLElement}[]} */
    this.pins = [];
    this.getUpHint = (game.world.meta.tutorialConfig.hints || []).find((h) => h.id === 'GetUp') || null;
    this.hintShown = false;
    this.pipsKey = '';
    const root = this.env.uiRoot();
    this._buildPips(root);
    this._buildDowned(root);
    this.blackEl = el('div', 'rg-layer', root);
    Object.assign(this.blackEl.style, { background: Palette.Ink, opacity: '0', display: 'none', zIndex: '36',
      alignItems: 'center', justifyContent: 'center' });
    this.notYet = el('div', 'rg-title', this.blackEl, S('Lives.NotYet'));
    Object.assign(this.notYet.style, { fontSize: 'clamp(30px, 6vw, 52px)', letterSpacing: '0.12em', color: Palette.Bone });
    this.pinLayer = el('div', 'rg-layer', root);
    this.pinLayer.style.zIndex = '12';
    this.downed = false;
    game.life.changed.connect((state, prev) => this._onLife(state, prev));
    game.life.livesChanged.connect(() => {
      this.pipsKey = '';
    });
  }

  // ---------------------------------------------------------------------------------------------------- building

  _buildPips(root) {
    this.pips = el('div', '', root);
    Object.assign(this.pips.style, { position: 'absolute', left: '22px', bottom: '78px', display: 'none', gap: '5px',
      alignItems: 'center', pointerEvents: 'none', zIndex: '9' });
    this.pipRow = el('div', '', this.pips);
    Object.assign(this.pipRow.style, { display: 'flex', gap: '4px', alignItems: 'center' });
    const wrap = el('div', '', this.pips);
    wrap.style.marginLeft = '6px';
    this.chevron = chevron(wrap);
  }

  _buildDowned(root) {
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
    this.getUp = el('div', 'rg-title rg-outline', box, '');
    Object.assign(this.getUp.style, { fontSize: '18px', color: Palette.Bone, letterSpacing: '0.08em' });
    this.getUpBar = el('div', '', box);
    Object.assign(this.getUpBar.style, { width: '200px', height: '5px', background: Palette.Track, borderRadius: '3px',
      overflow: 'hidden' });
    this.getUpFill = el('div', '', this.getUpBar);
    Object.assign(this.getUpFill.style, { height: '100%', width: '0%', background: Palette.Bone });
    this.getUpButton = el('button', 'rg-btn', box, S('Lives.GetUpButton'));
    this.getUpButton.style.pointerEvents = 'auto';
    const hold = (on) => (e) => {
      e.preventDefault();
      const life = this.game.life;
      life.getUpHolding = on && life.state === 'Downed';
      if (!on) life.getUpHeld = 0;
    };
    this.getUpButton.addEventListener('touchstart', hold(true));
    this.getUpButton.addEventListener('touchend', hold(false));
    this.getUpButton.addEventListener('touchcancel', hold(false));
    this.hint = el('div', 'rg-body rg-outline', box, '');
    Object.assign(this.hint.style, { fontSize: '14px', color: Palette.Ash });
    this.status = el('div', 'rg-body rg-outline', box, '');
    this.status.style.fontSize = '15px';
    this.team = el('div', 'rg-caps', box, '');
    this.team.style.color = Palette.Ash;
    this.panel.style.opacity = '0';
    this.panel.style.display = 'none';
  }

  // ---------------------------------------------------------------------------------------------------- events

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

  /**
   * Pins dropped items on this page's HUD for PinSeconds ([{at, kind}], `who` names their carrier).
   * @param {{at: THREE.Vector3, kind: string}[]} items
   */
  pinDropped(items, who) {
    const until = this.env.now() + this.game.life.config().PinSeconds;
    for (const item of items) {
      const tag = el('div', 'rg-caps rg-outline', this.pinLayer, S('Lives.Dropped', who));
      Object.assign(tag.style, { position: 'absolute', transform: 'translate(-50%, -100%)', color: Palette.Amber,
        whiteSpace: 'nowrap', display: 'none' });
      const label = el('div', '', tag, `◆ ${S(`Carry.${item.kind}`)}`);
      label.style.color = Palette.Bone;
      this.pins.push({ at: new THREE.Vector3(item.at.x, item.at.y + PIN_LIFT, item.at.z), until, el: tag });
    }
  }

  // ---------------------------------------------------------------------------------------------------- frame

  _framePips() {
    const g = this.game;
    const life = g.life;
    const show = !!g.run && g.live() && this.env.hudVisible() && g.controlLock() !== 'Cutscene' &&
      (life.state === 'Alive' || life.state === 'Downed');
    this.pips.style.display = show ? 'flex' : 'none';
    if (!show) return;
    const l = life.lives;
    const key = `${l.stage}|${l.run}|${l.syringe}|${l.getUpUsed}`;
    if (key === this.pipsKey) return;
    this.pipsKey = key;
    this.pipRow.textContent = '';
    for (let i = 0; i < l.stage + l.run; i++) heart(this.pipRow);
    for (let i = 0; i < l.syringe; i++) syringe(this.pipRow);
    this.chevron.setAttribute('stroke', l.getUpUsed ? Palette.Smoke : Palette.Bone);
    this.chevron.parentNode.style.opacity = l.getUpUsed ? '0.45' : '1';
  }

  _frameDowned(dt) {
    const g = this.game;
    const life = g.life;
    const env = this.env;
    const showing = this.downed && g.live();
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
    const bleed = life.config().BleedoutSeconds;
    const left = life.bleedoutEndsAt !== null ? Math.max(0, life.bleedoutEndsAt - env.now()) : 0;
    const fraction = clamp01(left / bleed);
    const spent = 1 - fraction;
    this.ring.setProgress(fraction);
    this.time.textContent = String(Math.ceil(left));
    // the get-up: its line from GetUpDelay, the hold's bar, or that it is spent on this stage
    const c = life.config();
    const check = life.getUpCheck();
    const device = env.device();
    const used = life.lives.getUpUsed;
    this.getUp.textContent = used ? S('Lives.GetUpUsed') : check.allowed ? S(`Lives.GetUp.${device}`) : '';
    this.getUp.style.fontSize = used ? '14px' : '18px';
    this.getUpBar.style.display = check.allowed ? '' : 'none';
    this.getUpFill.style.width = `${Math.round(clamp01(life.getUpHeld / c.GetUpHold) * 100)}%`;
    this.getUpButton.style.display = check.allowed && device === 'Touch' ? '' : 'none';
    // the get-up's first-time hint, once ever (its hidden setting), while the downed screen is up
    const hint = this.getUpHint;
    if (hint && showing && !used && !this.hintShown && env.setting(g.world.meta.tutorialConfig.hintsSetting) &&
      !env.setting(hint.setting)) {
      this.hintShown = true;
      env.setSetting(hint.setting, true);
      this.hint.textContent = S(hint.text);
    }
    this.hint.style.display = this.hintShown ? '' : 'none';
    const coop = g.coop && g.coop.active ? g.coop : null;
    const squad = coop ? coop.runNet.downedStatus() : null;
    this.status.textContent = squad || '';
    this.status.style.display = squad ? '' : 'none';
    this.team.textContent = coop ? coop.runNet.teammatesStatus() : '';
    if (showing) env.setPanicFloor('Downed', lerp(PANIC_REST, PANIC_PEAK, spent ** 1.2));
    const bpm = lerp(62, 132, spent ** 1.4);
    const beat = 0.5 + 0.5 * Math.sin(this.clock * (bpm / 60) * Math.PI * 2);
    const flash = clamp01(env.setting('FlashScale') ?? 1);
    this.panel.style.opacity = String(this.alpha);
    this.vignette.style.opacity = String(this.alpha * (0.55 + 0.25 * spent + 0.2 * beat * flash));
    this.grade.style.opacity = String(this.alpha * SATURATION_FLOOR * smoothstep(0, 1, spent));
  }

  _frameBlack(dt) {
    const want = this.game.life.respawning ? 1 : 0;
    this.black += Math.sign(want - this.black) * Math.min(Math.abs(want - this.black), (want ? BLACK_IN : BLACK_OUT) * dt);
    this.blackEl.style.display = this.black > 0.001 ? 'flex' : 'none';
    this.blackEl.style.opacity = String(this.black);
  }

  _framePins() {
    const now = this.env.now();
    this.pins = this.pins.filter((p) => {
      if (now < p.until && this.game.run) return true;
      p.el.remove();
      return false;
    });
    for (const p of this.pins) {
      const s = this.env.hudVisible() ? this.env.project(p.at) : null;
      p.el.style.display = s ? '' : 'none';
      if (s) {
        p.el.style.left = `${s.x}px`;
        p.el.style.top = `${s.y}px`;
      }
    }
  }

  frame(dt) {
    this._framePips();
    this._frameDowned(dt);
    this._frameBlack(dt);
    this._framePins();
  }

  endRun() {
    this.downed = false;
    this.hintShown = false;
    this.env.popContext('Downed');
    this.env.setPanicFloor('Downed', null);
    for (const p of this.pins) p.el.remove();
    this.pins = [];
    this.pipsKey = '';
  }
}
