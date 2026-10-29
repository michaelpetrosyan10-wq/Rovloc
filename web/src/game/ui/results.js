// results.js: the end-of-run screen (EscapeSummaryController).
//
// The run's summary opens a full-screen card: ESCAPED in bone white with a cold glow, landing with a lightning flash
// (FlashScale), or THE SCHOOL KEPT YOU / YOU DIDN'T MAKE IT in blood red with a failing-bulb flicker; the squad line
// (only for a squad) and the difficulty; the run time, the best time and NEW BEST TIME; the credits counting up; the
// stat rows; "This run was not saved." when it paid nothing. PLAY AGAIN (click / tap, gamepad A, Enter) and the
// auto-return countdown with a draining bar. While it is up the cursor is free, gameplay input is off (Menu context)
// and the HUD is hidden. It waits while a finale shot or a jumpscare owns the view (Cutscene context, Cutscene /
// Jumpscare / Parachute lock), at most 10 s, then fades in from black.

import { S } from '../strings.js';
import { formatTime } from '../util.js';
import { FocusGroup } from './nav.js';
import { Palette, el, meter } from './style.js';

const HOLD_MAX_SECONDS = 10;
const FADE_IN = 0.9;
const COUNT_UP_SECONDS = 1.6;
const CREDIT_DELAY = 0.8;
const FLASH_PEAK = 0.55;
const FLASH_DECAY = 6;
const HOLDING_LOCKS = new Set(['Cutscene', 'Jumpscare', 'Parachute']);
// (the Roblox card also lists Revives, teammates revived; played alone there is nobody to revive)
const STAT_ROWS = [
  ['TrapsTriggered', 'Results.TrapsTriggered'], ['VentsCrawled', 'Results.VentsCrawled'],
  ['FlasksThrown', 'Results.FlasksThrown'], ['Stuns', 'Results.Stuns'],
  ['LockersHidden', 'Results.LockersHidden'], ['FloorsCleared', 'Results.FloorsCleared'], ['TimesDowned', 'Results.TimesDowned'],
];

/** EscapeSummaryController.titleKind */
export function titleKind(outcome, escapees) {
  if (outcome === 'Escaped') return 'Escaped';
  return (escapees || 0) > 0 ? 'Dead' : 'Wiped';
}

/** EscapeSummaryController.countUp */
export function countUp(elapsed, total) {
  if (total <= 0 || elapsed <= 0) return 0;
  const t = Math.min(1, Math.max(0, elapsed / COUNT_UP_SECONDS));
  return t >= 1 ? total : Math.min(total, Math.floor(total * (1 - (1 - t) ** 3) + 0.5));
}

export class Results {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Results';
    this.game = game;
    this.env = game.env;
    this.pending = null;
    this.showing = false;
    this.receivedAt = 0;
    this.shownAt = 0;
    this.alpha = 0;
    this.flash = 0;
    this.clock = 0;
    this.pressed = false;
    this._build();
  }

  _build() {
    const root = this.env.uiRoot();
    this.root = el('div', 'rg-screen rg-hidden', root);
    this.root.style.zIndex = '40';
    this.root.style.background = 'rgb(8,8,9)';
    this.vignette = el('div', 'rg-layer', this.root);
    this.flashEl = el('div', 'rg-layer', this.root);
    this.flashEl.style.background = 'rgb(214,226,240)';
    this.flashEl.style.opacity = '0';
    const col = el('div', '', this.root);
    this.col = col;
    Object.assign(col.style, { position: 'relative', width: 'min(560px, 94vw)', maxHeight: '94vh', overflow: 'auto',
      display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '6px', textAlign: 'center' });
    this.title = el('div', 'rg-title', col, '');
    Object.assign(this.title.style, { fontSize: 'clamp(40px, 8vw, 58px)', lineHeight: '1.1' });
    this.rule = el('div', 'rg-rule', col);
    this.rule.style.width = '60%';
    this.squad = el('div', 'rg-caps', col, '');
    this.difficulty = el('div', 'rg-caps', col, '');
    this.time = el('div', 'rg-title', col, '');
    this.time.style.fontSize = '22px';
    this.time.style.marginTop = '10px';
    this.best = el('div', 'rg-body', col, '');
    this.best.style.color = Palette.Ash;
    this.newBest = el('div', 'rg-chip', col, S('Results.NewBest'));
    this.newBest.style.background = 'rgba(204,158,88,0.25)';
    this.newBest.style.color = Palette.Amber;
    this.credits = el('div', 'rg-title', col, '');
    Object.assign(this.credits.style, { fontSize: '20px', color: Palette.Amber, marginTop: '8px' });
    this.rows = el('div', '', col);
    Object.assign(this.rows.style, { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '4px 26px', margin: '10px 0' });
    this.rowEls = STAT_ROWS.map(() => {
      const r = el('div', 'rg-body', this.rows, '');
      Object.assign(r.style, { fontSize: '14px', color: Palette.Bone, textAlign: 'left' });
      return r;
    });
    this.note = el('div', 'rg-body', col, S('Results.NotSaved'));
    Object.assign(this.note.style, { fontSize: '13px', color: Palette.Ember });
    this.group = new FocusGroup({});
    this.button = el('button', 'rg-btn primary', col, '');
    this.button.style.width = '300px';
    this.button.style.marginTop = '10px';
    this.buttonKey = el('span', 'rg-glyph', this.button, 'ENTER');
    this.buttonText = el('span', '', this.button, S('Results.PlayAgain'));
    this.group.add(this.button, () => this._press());
    this.countdown = el('div', 'rg-caps', col, '');
    this.countdown.style.marginTop = '8px';
    this.bar = meter(col, Palette.Bone, 260);
  }

  _press() {
    if (this.pressed) return;
    this.pressed = true;
    this.env.play('UiConfirm');
    this.buttonText.textContent = S('Results.Waiting');
    this.game.match.pressPlayAgain();
  }

  phaseChanged(phase) {
    if (phase === 'Results' && this.game.match.summary) {
      this.pending = this.game.match.summary;
      this.receivedAt = this.clock;
      this.showing = false;
      this.pressed = false;
    } else if (phase === 'Resetting' || phase === 'Lobby') {
      this._close();
    }
  }

  _open() {
    const s = this.pending;
    const kind = titleKind(s.outcome, s.escapees);
    this.kind = kind;
    this.showing = true;
    this.shownAt = this.clock;
    this.root.classList.remove('rg-hidden');
    this.root.style.opacity = '0';
    this.alpha = 0;
    this.title.textContent = S(kind === 'Escaped' ? 'Results.Escaped' : kind === 'Dead' ? 'Results.Dead' : 'Results.Wiped');
    this.title.style.color = kind === 'Escaped' ? Palette.Bone : Palette.Blood;
    this.title.style.textShadow = kind === 'Escaped' ? '0 0 22px rgba(160,190,220,0.45)' : '0 0 2px rgba(8,8,9,0.9)';
    this.title.style.animation = kind === 'Escaped' ? '' : 'rg-flicker 5s infinite';
    this.vignette.style.background = kind === 'Escaped'
      ? 'radial-gradient(ellipse at center, rgba(0,0,0,0) 40%, rgba(18,34,46,0.9) 130%)'
      : `radial-gradient(ellipse at center, rgba(0,0,0,0) 40%, ${Palette.Blood} 150%)`;
    this.squad.textContent = S('Results.Squad', s.escapees, s.squadSize);
    this.squad.style.display = s.squadSize > 1 ? '' : 'none'; // "1 of 1 escaped" says nothing alone
    this.difficulty.textContent = S(`Lobby.Difficulty.${s.difficulty}`);
    this.time.textContent = S('Results.Time', formatTime(s.runSeconds));
    this.best.textContent = s.bestTime ? S('Results.BestTime', formatTime(s.bestTime)) : '';
    this.newBest.style.display = s.newBest ? '' : 'none';
    STAT_ROWS.forEach(([stat, key], i) => (this.rowEls[i].textContent = S(key, Math.max(0, Math.floor(s.stats[stat] || 0)))));
    this.note.style.display = s.saved ? 'none' : '';
    this.buttonText.textContent = S('Results.PlayAgain');
    if (kind === 'Escaped') this.flash = FLASH_PEAK * Math.min(1, Math.max(0, this.env.setting('FlashScale') ?? 1));
    const env = this.env;
    env.setCursorFree('Results', true);
    env.pushContext('Results', 'Menu');
    env.setHudVisible(false, 0.4);
    env.setMenuEnabled(false);
    env.setAmbienceEnabled(false);
    this.game.nav.push(this.group);
    this.group.focus(0);
  }

  _close() {
    this.pending = null;
    if (!this.showing) return;
    this.showing = false;
    this.root.classList.add('rg-hidden');
    const env = this.env;
    this.game.nav.remove(this.group);
    env.setCursorFree('Results', false);
    env.popContext('Results');
    env.setHudVisible(true, 0.6);
    env.setMenuEnabled(true);
    env.setAmbienceEnabled(true);
    env.fade(0, 0.8);
    env.requestPointerLock();
  }

  frame(dt, now) {
    this.clock += dt;
    if (this.pending && !this.showing) {
      const waited = this.clock - this.receivedAt;
      const holding = waited < HOLD_MAX_SECONDS && (this.env.context() === 'Cutscene' || HOLDING_LOCKS.has(this.game.controlLock()));
      if (!holding) this._open();
    }
    if (!this.showing) return;
    const s = this.pending;
    this.alpha = Math.min(1, this.alpha + dt * FADE_IN);
    this.root.style.opacity = String(this.alpha);
    this.flash = Math.max(0, this.flash - this.flash * FLASH_DECAY * dt - dt * 0.05);
    this.flashEl.style.opacity = String(this.flash);
    if (s) this.credits.textContent = S('Results.Credits', countUp(this.clock - this.shownAt - CREDIT_DELAY, s.creditsEarned));
    const m = this.game.match;
    const remaining = m.resultsEndsAt !== null ? Math.max(0, m.resultsEndsAt - now) : 0;
    this.countdown.textContent = S('Results.Returning', Math.ceil(remaining));
    this.bar.set(m.resultsTotal ? remaining / m.resultsTotal : 0);
    const device = this.env.device();
    this.buttonKey.style.display = device === 'Touch' ? 'none' : '';
    this.buttonKey.textContent = device === 'Gamepad' ? 'A' : 'ENTER';
  }
}

