// namePrompt.js: the title screen's question, asked once (docs/design/game-spec-v2.md 3.4): "What do your friends call
// you?". What is typed is saved (the web's PlayerName setting, editable in Settings; NameAsked remembers it was asked)
// and goes through the name sanitizer (rules/names.js, the port of NameSanitizer) before the story or the monster says
// it: the sheet previews what they will call you, or that no name will be used (the nameless lines). In co-op the
// room's name starts from it; the host re-sanitizes every name it is sent.
//
//   const prompt = new NamePrompt(game, parent)
//   prompt.open(done)   shows the sheet over the title; done() once the player confirmed or chose no name
//   prompt.isOpen()

import { nameRules } from '../rules/names.js';
import { S } from '../strings/index.js';
import '../strings/story.js';
import { FocusGroup } from './nav.js';
import { Palette, el } from './style.js';

export class NamePrompt {
  /**
   * @param {import('../game.js').Game} game
   * @param {HTMLElement} parent the title screen's root
   */
  constructor(game, parent) {
    this.game = game;
    this.env = game.env;
    this.rules = nameRules(game.world.meta);
    this.done = null;
    this.root = el('div', 'rg-screen rg-hidden', parent);
    this.root.style.background = 'rgba(0,0,0,0.6)';
    this.root.style.zIndex = '2';
    const sheet = el('div', 'rg-sheet', this.root);
    Object.assign(sheet.style, { width: 'min(460px, 92vw)', padding: '18px 24px 20px', boxSizing: 'border-box',
      display: 'flex', flexDirection: 'column', gap: '10px' });
    el('div', 'rg-tape l', sheet);
    el('div', 'rg-tape r', sheet);
    const title = el('div', 'rg-title rg-outline', sheet, S('Name.Title'));
    title.style.fontSize = '24px';
    const hint = el('div', 'rg-body', sheet, S('Name.Hint'));
    Object.assign(hint.style, { fontSize: '14px', color: Palette.Ash });
    this.input = el('input', 'rg-body', sheet);
    Object.assign(this.input, { type: 'text', maxLength: 24, autocomplete: 'off', spellcheck: false });
    Object.assign(this.input.style, { fontSize: '20px', padding: '8px 10px', background: 'rgba(8,8,9,0.8)', color: Palette.Bone,
      border: `1px solid ${Palette.Stroke}`, borderRadius: '4px', outline: 'none' });
    this.preview = el('div', 'rg-caps', sheet, '');
    Object.assign(this.preview.style, { fontSize: '13px', color: Palette.Amber, minHeight: '16px' });
    const row = el('div', '', sheet);
    Object.assign(row.style, { display: 'flex', gap: '10px', justifyContent: 'flex-end' });
    this.group = new FocusGroup({ back: () => this.confirm(true) });
    const button = (label, primary, press) => {
      const b = el('button', `rg-btn${primary ? ' primary' : ''}`, row, label);
      this.group.add(b, press, 0);
      return b;
    };
    this.skipBtn = button(S('Name.Skip'), false, () => this.confirm(true));
    this.okBtn = button(S('Name.Ok'), true, () => this.confirm(false));
    this.input.addEventListener('input', () => this._preview());
    this.input.addEventListener('keydown', (e) => {
      e.stopPropagation();
      if (e.key === 'Enter') {
        e.preventDefault();
        this.confirm(false);
      } else if (e.key === 'Escape') {
        e.preventDefault();
        this.confirm(true);
      }
    });
  }

  isOpen() {
    return this.done !== null;
  }

  /** Whether the title has asked before (the question is asked once). */
  asked() {
    return !!this.env.setting('NameAsked');
  }

  /** Shows the question; `done` runs once it is answered. */
  open(done) {
    this.done = done;
    this.input.value = this.env.setting('PlayerName') || '';
    this._preview();
    this.root.classList.remove('rg-hidden');
    this.game.nav.push(this.group);
    this.group.focus(1);
    this.input.focus();
  }

  _preview() {
    const name = this.rules.sanitize(this.input.value);
    this.preview.textContent = name ? S('Name.Preview', name) : this.input.value.trim() ? S('Name.None') : '';
  }

  /** Saves the answer (`none`: no name) and goes on. */
  confirm(none) {
    if (!this.done) return;
    this.env.setSetting('PlayerName', none ? '' : this.input.value);
    this.env.setSetting('NameAsked', true);
    const done = this.done;
    this.done = null;
    this.input.blur();
    this.root.classList.add('rg-hidden');
    this.game.nav.remove(this.group);
    done();
  }
}
