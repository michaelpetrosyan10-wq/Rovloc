// title.js: the title screen and the HOW TO PLAY walkthrough (OnboardingController).
//
//   Title     ROVLOC in a flickering typewriter stencil with a blood shadow, the premise, PLAY, HOW TO PLAY and
//             SETTINGS, the saved credits and escapes; behind it the camera drifts through the boiler room (a
//             Cutscene camera override along TutorialConfig.TitleDrift, Catmull-Rom, one loop per 64 s). While it is
//             up the HUD is hidden, the cursor is free, the Menu input context is pushed; keyboard, gamepad and touch
//             all drive it. PLAY goes into the lobby, the first time through the walkthrough.
//   Walkthrough  TutorialConfig.Pages on a taped sheet, a drawn illustration each, page count and dots, BACK / SKIP /
//             NEXT (GOT IT on the last); arrows / bumpers page, Enter goes on, B / Escape skips. Finishing or
//             skipping saves TutorialDone. openWalkthrough() replays it from the lobby and returns there.

import * as THREE from 'three';
import { TutorialConfig } from '../config.js';
import { S } from '../strings.js';
import { lookAtMatrix } from '../util.js';
import { FocusGroup, glyphFor } from './nav.js';
import { C } from '../coop/strings.js';
import { Fonts, Palette, el } from './style.js';

const CAMERA_FOV = 60;
const NOISE = { GrateKick: 130, Sprint: 65, Walk: 30, CrouchWalk: 8 };
const SVGNS = 'http://www.w3.org/2000/svg';

/** OnboardingController.drift: the title camera at time t on a looping Catmull-Rom path. */
export function drift(keys, t, period) {
  const n = keys.length;
  const u = (((t % period) + period) % period) / period * n;
  const i = Math.floor(u);
  const f = u - i;
  const at = (o) => keys[(((i + o) % n) + n) % n];
  const k0 = at(-1);
  const k1 = at(0);
  const k2 = at(1);
  const k3 = at(2);
  const cat = (a, b, c, d) => {
    const f2 = f * f;
    const f3 = f2 * f;
    return 0.5 * (2 * b + (c - a) * f + (2 * a - 5 * b + 4 * c - d) * f2 + (3 * b - a - 3 * c + d) * f3);
  };
  const eye = [0, 1, 2].map((j) => cat(k0.eye[j], k1.eye[j], k2.eye[j], k3.eye[j]));
  const look = [0, 1, 2].map((j) => cat(k0.look[j], k1.look[j], k2.look[j], k3.look[j]));
  return { eye, look };
}

export class Onboarding {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Onboarding';
    this.game = game;
    this.env = game.env;
    /** @type {'Hidden'|'Title'|'Walkthrough'} */
    this.mode = 'Hidden';
    this.returnTo = 'Hidden';
    this.page = 0;
    this.clock = 0;
    this.settingsOpen = false;
    this.onPlay = null;
    const origin = game.world.meta.levels.Lobby.origin;
    this.origin = new THREE.Vector3(...origin);
    this._build();
    this.env.onDeviceChanged(() => {
      if (this.mode === 'Walkthrough') this._renderPage();
      this._glyphs();
    });
  }

  // ---------------------------------------------------------------------------------------------------- build

  _build() {
    const root = this.env.uiRoot();
    this.root = el('div', 'rg-screen rg-hidden', root);
    this.root.style.zIndex = '30';
    this.shade = el('div', 'rg-layer', this.root);
    this.shade.style.background = 'linear-gradient(90deg, rgba(8,8,9,0.92) 0%, rgba(8,8,9,0.72) 34%, rgba(8,8,9,0.12) 70%, rgba(8,8,9,0.05) 100%)';

    // title column
    const col = el('div', '', this.root);
    this.titleCol = col;
    Object.assign(col.style, { position: 'absolute', left: '7%', top: '50%', transform: 'translateY(-50%)',
      width: 'min(470px, 86vw)', display: 'flex', flexDirection: 'column', gap: '10px' });
    const mark = el('div', '', col);
    mark.style.position = 'relative';
    mark.style.height = '104px';
    const shadow = el('div', 'rg-title', mark, S('Title.Name'));
    const word = el('div', 'rg-title', mark, S('Title.Name'));
    for (const e of [shadow, word]) Object.assign(e.style, { position: 'absolute', left: '0', top: '0', fontSize: 'clamp(56px, 11vw, 92px)', lineHeight: '1' });
    Object.assign(shadow.style, { color: Palette.Blood, opacity: '0.75', transform: 'translate(4px, 4px)' });
    word.style.animation = 'rg-flicker 7s infinite';
    word.style.textShadow = '0 0 3px rgba(8,8,9,0.9)';
    const scratch = el('div', '', mark);
    Object.assign(scratch.style, { position: 'absolute', left: '2px', bottom: '2px', width: '72%', height: '2px',
      background: `linear-gradient(90deg, ${Palette.Blood}, rgba(142,24,20,0.6) 70%, transparent)` });
    const premise = el('div', 'rg-body rg-outline', col, S('Title.Premise'));
    premise.style.color = Palette.Ash;
    premise.style.fontSize = '16px';
    premise.style.maxWidth = '430px';
    el('div', '', col).style.height = '6px';
    this.group = new FocusGroup({});
    this.playBtn = this._button(col, C('Title.PlaySolo'), true, () => this.pressPlay());
    // co-op: host or join a room (game/coop/ui.js)
    this.friendsBtn = this._button(col, C('Title.PlayFriends'), false, () => {
      if (this.game.coop) this.game.coop.ui.openFriends();
    });
    this.firstTime = el('div', 'rg-body', col, S('Title.FirstTime'));
    Object.assign(this.firstTime.style, { color: Palette.Amber, fontSize: '13px' });
    this.howBtn = this._button(col, S('Title.HowToPlay'), false, () => this.openWalkthrough('Title'));
    this.setBtn = this._button(col, S('Title.Settings'), false, () => this.openSettings());
    this.stats = el('div', 'rg-caps', col, '');
    this.stats.style.fontSize = '13px';
    this.saving = el('div', 'rg-body', col, '');
    Object.assign(this.saving.style, { fontSize: '12px', color: Palette.Smoke });
    this.hint = el('div', 'rg-caps', col, '');
    this.hint.style.marginTop = '8px';

    // walkthrough sheet
    this.walk = el('div', 'rg-screen rg-hidden', this.root);
    this.walk.style.background = 'rgba(0,0,0,0.55)';
    const sheet = el('div', 'rg-sheet', this.walk);
    this.sheet = sheet;
    Object.assign(sheet.style, { width: 'min(620px, 94vw)', padding: '14px 24px 18px', boxSizing: 'border-box' });
    el('div', 'rg-tape l', sheet);
    el('div', 'rg-tape r', sheet);
    const head = el('div', '', sheet);
    Object.assign(head.style, { display: 'flex', justifyContent: 'space-between', alignItems: 'center' });
    el('div', 'rg-caps', head, S('Tutorial.Header'));
    this.counter = el('div', 'rg-caps', head, '');
    el('div', 'rg-rule', sheet).style.margin = '8px 0 10px';
    const content = el('div', '', sheet);
    Object.assign(content.style, { display: 'flex', gap: '24px', flexWrap: 'wrap' });
    this.art = el('div', '', content);
    Object.assign(this.art.style, { width: '250px', height: '262px', flex: 'none', position: 'relative', overflow: 'hidden' });
    const text = el('div', '', content);
    Object.assign(text.style, { flex: '1 1 220px', minWidth: '200px' });
    this.pageTitle = el('div', 'rg-title rg-outline', text, '');
    this.pageTitle.style.fontSize = '26px';
    this.pageBody = el('div', 'rg-body', text, '');
    Object.assign(this.pageBody.style, { fontSize: '16px', marginTop: '10px', lineHeight: '1.38' });
    this.dots = el('div', '', sheet);
    Object.assign(this.dots.style, { display: 'flex', justifyContent: 'center', gap: '8px', margin: '12px 0' });
    this.dotEls = TutorialConfig.Pages.map(() => {
      const d = el('div', '', this.dots);
      Object.assign(d.style, { width: '8px', height: '8px', borderRadius: '50%', background: Palette.Smoke });
      return d;
    });
    const row = el('div', '', sheet);
    Object.assign(row.style, { display: 'flex', gap: '10px', alignItems: 'center' });
    this.walkGroup = new FocusGroup({
      back: () => this.finishWalkthrough(),
      page: (d) => {
        this.turn(d);
        return true;
      },
    });
    this.backBtn = this._button(row, S('Tutorial.Back'), false, () => this.turn(-1), this.walkGroup, 0);
    this.skipBtn = this._button(row, S('Tutorial.Skip'), false, () => this.finishWalkthrough(), this.walkGroup, 0);
    this.skipBtn.style.color = Palette.Ash;
    el('div', '', row).style.flex = '1';
    this.nextBtn = this._button(row, S('Tutorial.Next'), true, () => this.turn(1), this.walkGroup, 0);
    this.nextBtn.style.minWidth = '160px';
  }

  _button(parent, label, primary, press, group = this.group, row) {
    const b = el('button', `rg-btn${primary ? ' primary' : ''}`, parent, label);
    if (parent === this.titleCol) b.style.width = '300px';
    group.add(b, () => {
      this.env.play('UiClick');
      press();
    }, row);
    return b;
  }

  _glyphs() {
    const d = this.env.device();
    this.hint.textContent = d === 'Gamepad' ? '▲▼ SELECT   A PRESS' : d === 'Touch' ? '' : '↑↓ SELECT   ENTER PRESS';
  }

  // ---------------------------------------------------------------------------------------------------- flow

  /** Shows the title screen (once per load, and back from a walkthrough opened there). */
  openTitle() {
    this.mode = 'Title';
    this._hold(true);
    this.root.classList.remove('rg-hidden');
    this.walk.classList.add('rg-hidden');
    this.titleCol.style.display = '';
    this.shade.style.display = '';
    const p = this.game.profile;
    this.stats.textContent = S('Title.Stats', p.credits, p.escapes);
    this.saving.textContent = S(p.persistent() ? 'Title.Saving' : 'Title.NotSaving');
    this.firstTime.style.display = this.env.setting(TutorialConfig.TutorialSetting) ? 'none' : '';
    this._glyphs();
    this.game.nav.push(this.group);
    this.group.focus(0);
  }

  pressPlay() {
    if (!this.env.setting(TutorialConfig.TutorialSetting)) {
      this.openWalkthrough('Lobby');
      return;
    }
    this._closeAll();
    if (this.onPlay) this.onPlay();
  }

  /** Co-op: the squad's run is starting (or underway): any title screen or walkthrough here gives way at once. */
  closeForCoop() {
    if (this.mode === 'Hidden') return;
    if (this.mode === 'Walkthrough') this.env.setSetting(TutorialConfig.TutorialSetting, true);
    this._closeAll();
    if (this.onPlay) this.onPlay();
  }

  /** The walkthrough from the title ('Title'), on the way into the lobby ('Lobby') or from the lobby ('Hidden'). */
  openWalkthrough(from = 'Hidden') {
    this.returnTo = from;
    this.mode = 'Walkthrough';
    this.page = 0;
    this._hold(true);
    this.root.classList.remove('rg-hidden');
    this.walk.classList.remove('rg-hidden');
    this.titleCol.style.display = 'none';
    this.shade.style.display = from === 'Hidden' ? 'none' : '';
    this.game.nav.remove(this.group);
    this.game.nav.push(this.walkGroup);
    this._renderPage();
    this.walkGroup.focus(2);
  }

  turn(delta) {
    const count = TutorialConfig.Pages.length;
    if (delta > 0 && this.page >= count - 1) {
      this.finishWalkthrough();
      return;
    }
    const next = Math.min(count - 1, Math.max(0, this.page + delta));
    if (next === this.page) return;
    this.page = next;
    this.env.play('UiClick');
    this._renderPage();
  }

  finishWalkthrough() {
    this.env.setSetting(TutorialConfig.TutorialSetting, true);
    this.game.nav.remove(this.walkGroup);
    this.walk.classList.add('rg-hidden');
    const back = this.returnTo;
    if (back === 'Title') {
      this.openTitle();
      return;
    }
    this._closeAll();
    if (back === 'Lobby' && this.onPlay) this.onPlay();
  }

  openSettings() {
    this.settingsOpen = true;
    this.group.active = false;
    this.env.setMenuButtons([{ label: S('Settings.Close'), onClick: () => this.env.closeMenu() }]);
    this.env.openMenu(S('Settings.Title'));
  }

  _closeAll() {
    this.mode = 'Hidden';
    this.game.nav.remove(this.group);
    this.game.nav.remove(this.walkGroup);
    this.root.classList.add('rg-hidden');
    this._hold(false);
  }

  /** Whether a screen is up (the tracker and hints stay quiet). */
  busy() {
    return this.mode !== 'Hidden';
  }

  _hold(on) {
    const env = this.env;
    if (on === this.holding) return;
    this.holding = on;
    env.setCursorFree('Onboarding', on);
    if (on) {
      env.pushContext('Onboarding', 'Menu');
      env.setHudVisible(false, 0.3);
      env.setMenuEnabled(false);
    } else {
      env.popContext('Onboarding');
      env.setHudVisible(true, 0.6);
      env.setMenuEnabled(true);
      env.setCameraOverride('Cutscene', null);
      env.requestPointerLock();
    }
  }

  // ---------------------------------------------------------------------------------------------------- page

  _renderPage() {
    const pages = TutorialConfig.Pages;
    const entry = pages[this.page];
    const device = this.env.device();
    this.counter.textContent = S('Tutorial.Page', this.page + 1, pages.length);
    this.pageTitle.textContent = S(entry.title);
    this.pageBody.textContent = entry.deviceBody ? S(`${entry.body}.${device}`)
      : S(entry.body);
    this.dotEls.forEach((d, i) => (d.style.background = i === this.page ? Palette.Bone : Palette.Smoke));
    this.backBtn.toggleAttribute('disabled', this.page === 0);
    this.nextBtn.textContent = S(this.page >= pages.length - 1 ? 'Tutorial.Done' : 'Tutorial.Next');
    this.art.textContent = '';
    const draw = ART[entry.art];
    if (draw) draw(this.art, this);
  }

  // ---------------------------------------------------------------------------------------------------- frame

  frame(dt) {
    if (this.settingsOpen && !this.env.menuOpen()) {
      this.settingsOpen = false;
      this.group.active = true;
      this.env.setMenuEnabled(false);
      this.env.setCursorFree('Onboarding', true);
      if (this.game.menu) this.game.menu.restoreButtons();
    }
    if (this.mode === 'Title' || (this.mode === 'Walkthrough' && this.returnTo !== 'Hidden')) {
      this.clock += dt;
      const { eye, look } = drift(TutorialConfig.TitleDrift, this.clock, TutorialConfig.Timing.TitleDriftPeriod);
      _eye.set(eye[0], eye[1], eye[2]).add(this.origin);
      _look.set(look[0], look[1], look[2]).add(this.origin);
      lookAtMatrix(_eye, _look, _cam);
      this.env.setCameraOverride('Cutscene', () => _cam, { priority: 6, fov: CAMERA_FOV, blendIn: 0, blendOut: 1.6 });
    }
  }
}

const _eye = new THREE.Vector3();
const _look = new THREE.Vector3();
const _cam = new THREE.Matrix4();

// -------------------------------------------------------------------------------------------------------- art

function svg(parent, w = 250, h = 262) {
  const s = document.createElementNS(SVGNS, 'svg');
  s.setAttribute('width', w);
  s.setAttribute('height', h);
  s.setAttribute('viewBox', `0 0 ${w} ${h}`);
  parent.appendChild(s);
  return s;
}

function node(parent, tag, attrs, text) {
  const n = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, v);
  if (text !== undefined) n.textContent = text;
  parent.appendChild(n);
  return n;
}

function caption(s, x, y, text, color = Palette.Ash, anchor = 'middle') {
  return node(s, 'text', { x, y, fill: color, 'font-family': Fonts.Strong, 'font-size': 11, 'letter-spacing': '1.4',
    'text-anchor': anchor, 'font-weight': 600 }, text);
}

const ART = {
  Goal(parent) {
    const s = svg(parent);
    const floors = 6;
    const h = 26;
    const gap = 8;
    const w = 150;
    const left = 20;
    const bottom = 262 - 16;
    for (let i = 1; i <= floors; i++) {
      const y = bottom - i * h - (i - 1) * gap;
      node(s, 'rect', { x: left, y, width: w, height: h, rx: 2, fill: i === floors ? Palette.Track : Palette.Raised,
        stroke: Palette.StrokeDim, 'fill-opacity': 0.9 });
      const label = i === 1 ? S('Tutorial.Art.Basement') : i === floors ? S('Tutorial.Art.Roof') : S('Tutorial.Art.Floor', i - 1);
      caption(s, left + w / 2, y + h / 2 + 4, label);
      node(s, 'circle', { cx: left + w + 18, cy: y + h / 2, r: 3, fill: Palette.Amber, 'fill-opacity': 0.85 - 0.1 * (floors - i) });
    }
    node(s, 'circle', { cx: left + w + 18, cy: bottom - h / 2, r: 6, fill: Palette.Amber });
    node(s, 'path', { d: `M ${left + w + 4} 24 A 29 22 0 0 1 ${left + w + 62} 24 Z`, fill: Palette.Ember, 'fill-opacity': 0.95 });
    node(s, 'line', { x1: left + w + 12, y1: 24, x2: left + w + 33, y2: 42, stroke: Palette.Ash });
    node(s, 'line', { x1: left + w + 54, y1: 24, x2: left + w + 33, y2: 42, stroke: Palette.Ash });
    node(s, 'circle', { cx: left + w + 33, cy: 44, r: 4, fill: Palette.Bone });
  },
  Creature(parent) {
    const s = svg(parent);
    [70, 120, 170].forEach((d, i) => node(s, 'circle', { cx: 70, cy: 110, r: d / 2, fill: 'none', stroke: Palette.Ash,
      'stroke-opacity': 0.65 - i * 0.15, 'stroke-width': 1.5 }));
    node(s, 'ellipse', { cx: 150, cy: 110, rx: 55, ry: 28, fill: Palette.Bone, 'fill-opacity': 0.95 });
    node(s, 'circle', { cx: 150, cy: 110, r: 20, fill: Palette.Blood });
    node(s, 'rect', { x: 147, y: 93, width: 6, height: 34, rx: 3, fill: Palette.Ink });
    const grad = node(node(s, 'defs', {}), 'linearGradient', { id: 'cone', x1: 0, x2: 1, y1: 0, y2: 0 });
    node(grad, 'stop', { offset: 0, 'stop-color': Palette.Amber, 'stop-opacity': 0.6 });
    node(grad, 'stop', { offset: 1, 'stop-color': Palette.Amber, 'stop-opacity': 0 });
    node(s, 'path', { d: 'M 205 100 L 250 82 L 250 138 L 205 120 Z', fill: 'url(#cone)' });
    caption(s, 70, 214, S('Tutorial.Art.Hears'));
    caption(s, 205, 214, S('Tutorial.Art.Sees'));
  },
  Noise(parent) {
    const s = svg(parent);
    const loud = NOISE.GrateKick;
    const rows = [
      ['GrateKick', 'Tutorial.Art.Kick', Palette.Blood], ['Sprint', 'Tutorial.Art.Sprint', Palette.Ember],
      ['Walk', 'Tutorial.Art.Walk', Palette.Amber], ['CrouchWalk', 'Tutorial.Art.Crouch', Palette.Moss],
    ];
    for (const [kind, label, color] of rows) {
      const r = 112 * Math.sqrt(Math.min(1, NOISE[kind] / loud));
      node(s, 'circle', { cx: 125, cy: 126, r, fill: 'none', stroke: color, 'stroke-width': 2, 'stroke-opacity': 0.85 });
      caption(s, 125, 126 - r - 5, S(label), color);
    }
    node(s, 'circle', { cx: 125, cy: 126, r: 4, fill: Palette.Bone });
  },
  Tools(parent) {
    const s = svg(parent);
    const tiles = [['Light', 'Tutorial.Art.Light'], ['Flask', 'Tutorial.Art.Flask'], ['Vent', 'Tutorial.Art.Vent'],
      ['Locker', 'Tutorial.Art.Locker']];
    tiles.forEach(([name, label], i) => {
      const x = 8 + (i % 2) * 122;
      const y = 4 + Math.floor(i / 2) * 128;
      node(s, 'rect', { x, y, width: 112, height: 118, rx: 6, fill: Palette.Raised, stroke: Palette.StrokeDim, 'fill-opacity': 0.85 });
      caption(s, x + 56, y + 110, S(label));
      if (name === 'Light') {
        node(s, 'rect', { x: x + 16, y: y + 44, width: 36, height: 16, fill: Palette.Smoke });
        node(s, 'rect', { x: x + 50, y: y + 38, width: 10, height: 28, fill: Palette.Ash });
        node(s, 'path', { d: `M ${x + 60} ${y + 40} L ${x + 104} ${y + 26} L ${x + 104} ${y + 78} L ${x + 60} ${y + 64} Z`, fill: Palette.Amber, 'fill-opacity': 0.45 });
      } else if (name === 'Flask') {
        node(s, 'rect', { x: x + 50, y: y + 18, width: 12, height: 24, fill: Palette.Ash });
        node(s, 'circle', { cx: x + 56, cy: y + 62, r: 23, fill: Palette.Moss, stroke: Palette.Bone, 'stroke-opacity': 0.6 });
      } else if (name === 'Vent') {
        node(s, 'rect', { x: x + 24, y: y + 18, width: 64, height: 60, fill: Palette.Track, stroke: Palette.Ash, 'stroke-width': 2 });
        for (let k = 1; k <= 5; k++) node(s, 'rect', { x: x + 30, y: y + 18 + k * 10 - 4, width: 52, height: 4, fill: Palette.Ink });
      } else {
        node(s, 'rect', { x: x + 36, y: y + 8, width: 40, height: 82, fill: Palette.Smoke, stroke: Palette.Ash });
        for (let k = 1; k <= 3; k++) node(s, 'rect', { x: x + 44, y: y + 14 + k * 6, width: 24, height: 3, fill: Palette.Ink });
      }
    });
  },
  Teamwork(parent) {
    // played alone: a downed figure and the syringe that gets it up; a stairwell's fire doors shut in the ring
    const s = svg(parent);
    const g = node(s, 'g', { transform: 'translate(92 118) rotate(90)' });
    node(g, 'circle', { cx: 0, cy: -26, r: 9, fill: Palette.Ember });
    node(g, 'rect', { x: -9, y: -15, width: 18, height: 48, rx: 6, fill: Palette.Ember });
    const syringe = node(s, 'g', { transform: 'translate(70 52) rotate(-35)' });
    node(syringe, 'rect', { x: 0, y: -5, width: 34, height: 10, rx: 2, fill: 'none', stroke: Palette.Moss, 'stroke-width': 2.5 });
    node(syringe, 'rect', { x: 2, y: -3, width: 18, height: 6, fill: Palette.Moss });
    node(syringe, 'rect', { x: 34, y: -1, width: 16, height: 2, fill: Palette.Bone });
    node(syringe, 'rect', { x: -10, y: -1.5, width: 10, height: 3, fill: Palette.Moss });
    node(syringe, 'rect', { x: -13, y: -7, width: 3, height: 14, fill: Palette.Moss });
    caption(s, 92, 172, S('Tutorial.Art.Revive'), Palette.Moss);
    const r = 34;
    node(s, 'circle', { cx: 196, cy: 198, r, fill: 'none', stroke: Palette.Amber, 'stroke-width': 5 });
    node(s, 'rect', { x: 176, y: 180, width: 19, height: 36, fill: Palette.Ash });
    node(s, 'rect', { x: 197, y: 180, width: 19, height: 36, fill: Palette.Ash });
    node(s, 'rect', { x: 186, y: 196, width: 6, height: 2.5, fill: Palette.Ink });
    node(s, 'rect', { x: 200, y: 196, width: 6, height: 2.5, fill: Palette.Ink });
    caption(s, 196, 250, S('Tutorial.Art.Seal'));
  },
  Lobby(parent, ui) {
    const s = svg(parent);
    const meta = ui.game.world.meta;
    const rooms = meta.rooms.filter((r) => r.level === 'Lobby');
    let minX = Infinity;
    let minZ = Infinity;
    let maxX = -Infinity;
    let maxZ = -Infinity;
    for (const r of rooms) {
      minX = Math.min(minX, r.rect.x);
      minZ = Math.min(minZ, r.rect.z);
      maxX = Math.max(maxX, r.rect.x + r.rect.w);
      maxZ = Math.max(maxZ, r.rect.z + r.rect.d);
    }
    const scale = Math.min((250 - 12) / (maxX - minX), (262 - 40) / (maxZ - minZ));
    const at = (x, z) => [6 + (x - minX) * scale, 6 + (z - minZ) * scale];
    for (const r of rooms) {
      const [x, y] = at(r.rect.x, r.rect.z);
      node(s, 'rect', { x, y, width: r.rect.w * scale, height: r.rect.d * scale, fill: Palette.Raised, 'fill-opacity': 0.8, stroke: Palette.StrokeDim });
    }
    const anchors = meta.anchors.filter((a) => a.level === 'Lobby');
    const pads = anchors.filter((a) => a.kind === 'ReadyPad');
    const spawns = anchors.filter((a) => a.kind === 'PlayerSpawn');
    for (const t of anchors.filter((a) => a.kind === 'Terminal')) {
      const [x, y] = at(t.cframe[0], t.cframe[2]);
      node(s, 'circle', { cx: x, cy: y, r: 4.5, fill: Palette.Moss });
      caption(s, x + (x < 20 ? 30 : 0), y + 16, S(t.id.includes('Difficulty') ? 'Tutorial.Art.Console' : 'Tutorial.Art.Supply'), Palette.Moss);
    }
    if (pads.length) {
      const xs = pads.map((p) => p.cframe[0]);
      const zs = pads.map((p) => p.cframe[2]);
      const x0 = Math.min(...xs);
      const x1 = Math.max(...xs);
      const z0 = Math.min(...zs);
      const [bx, by] = at(x0 - 6, z0 - 4.5);
      node(s, 'rect', { x: bx, y: by, width: (x1 - x0 + 12) * scale, height: 9 * scale, rx: 3, fill: Palette.Amber, 'fill-opacity': 0.45 });
      const [lx, ly] = at((x0 + x1) / 2, z0 + 12);
      caption(s, lx, ly, S('Tutorial.Art.Bus'), Palette.Amber);
      if (spawns.length) {
        const sx = spawns.reduce((a, p) => a + p.cframe[0], 0) / spawns.length;
        const sz = spawns.reduce((a, p) => a + p.cframe[2], 0) / spawns.length;
        const [px, py] = at(sx, sz);
        node(s, 'circle', { cx: px, cy: py, r: 5, fill: Palette.Bone });
        caption(s, px, py + 16, S('Tutorial.Art.Start'), Palette.Bone);
        const tx = x0 - 7;
        const tz = (z0 + Math.max(...zs)) / 2;
        for (let k = 1; k <= 7; k++) {
          const [rx, ry] = at(sx + ((tx - sx) * k) / 8, sz + ((tz - sz) * k) / 8);
          node(s, 'circle', { cx: rx, cy: ry, r: 2.5, fill: Palette.Amber });
        }
      }
    }
  },
  Controls(parent, ui) {
    const env = ui.env;
    const device = env.device();
    const list = el('div', '', parent);
    Object.assign(list.style, { display: 'flex', flexDirection: 'column', gap: '2px', paddingTop: '4px' });
    for (const row of TutorialConfig.ControlRows) {
      const r = el('div', '', list);
      Object.assign(r.style, { display: 'flex', alignItems: 'center', height: '24px', gap: '8px' });
      // the glyph column only as wide as its widest key ("W A S D"), so the longest line fits the half page
      const slot = el('div', '', r);
      Object.assign(slot.style, { width: '76px', flex: '0 0 76px', display: 'flex', justifyContent: 'flex-end' });
      const text = row.action ? glyphFor(env, row.action, device) : S(`${row.glyph}.${device}`);
      el('span', `rg-key${device === 'KeyboardMouse' ? '' : ' round'}`, slot, text);
      const label = el('div', 'rg-body', r, S(row.label));
      Object.assign(label.style, { fontSize: '13px', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' });
    }
  },
};
