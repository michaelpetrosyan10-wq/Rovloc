// ui.js: co-op's screens, in the game's look (ui/style.js).
//
//   Friends   PLAY WITH FRIENDS on the title opens a taped sheet: your name (saved), HOST A GAME, a room-code field
//             with JOIN, BACK. Hosting shows the code big with COPY, then ENTER THE LOBBY; joining goes straight in.
//             Errors stay on the sheet ("Multiplayer can't connect on this network — single-player still works", no
//             such room, room full, another version). Keyboard / gamepad move between the buttons (FocusGroup);
//             touch taps them; the fields take the on-screen keyboard.
//   Lobby     the lobby's squad panel lists every player: name (you / HOST), READY / NOT READY, the link (Direct /
//             Relay / Linking) and ping, plus the room code to share.
//   HUD       in a run, the teammates top-right: name and status (ALIVE / DOWN / DEAD / WATCHING / IN THE STAIRWELL /
//             ESCAPED).
//   Message   a note over the title when a room ends ("The host left").

import { PoseFlags } from '../../net/codec.js';
import { FocusGroup } from '../ui/nav.js';
import { Palette, el } from '../ui/style.js';
import { C } from './strings.js';

const NAME_KEY = 'coop.name';
const MESSAGE_SECONDS = 8;

export class CoopUi {
  /** @param {import('./index.js').Coop} coop */
  constructor(coop) {
    this.coop = coop;
    this.game = coop.game;
    this.env = coop.game.env;
    this.open = false;
    this.busy = false;
    this.messageLeft = 0;
    this.lobbyKey = '';
    this.hudKey = '';
    this._buildFriends();
    this._buildHud();
    this._buildMessage();
    coop.squadChanged.connect(() => {
      this.lobbyKey = '';
      this.hudKey = '';
    });
  }

  // ---------------------------------------------------------------------------------------------------- friends

  _buildFriends() {
    const root = this.env.uiRoot();
    this.screen = el('div', 'rg-screen rg-hidden', root);
    this.screen.style.zIndex = '34';
    this.screen.style.background = 'rgba(0,0,0,0.55)';
    const sheet = el('div', 'rg-sheet', this.screen);
    Object.assign(sheet.style, { width: 'min(520px, 94vw)', padding: '16px 22px 18px', boxSizing: 'border-box',
      maxHeight: '92vh', overflow: 'auto' });
    el('div', 'rg-tape l', sheet);
    el('div', 'rg-tape r', sheet);
    el('div', 'rg-caps', sheet, C('Coop.Title'));
    el('div', 'rg-rule', sheet).style.margin = '8px 0 12px';
    const intro = el('div', 'rg-body', sheet, C('Coop.Intro'));
    Object.assign(intro.style, { fontSize: '14px', color: Palette.Ash, marginBottom: '12px' });
    this.group = new FocusGroup({ back: () => this.close() });

    // the form
    this.form = el('div', '', sheet);
    el('div', 'rg-caps', this.form, C('Coop.Name'));
    this.nameInput = this._input(this.form, 16);
    this.nameInput.value = this.env.saveGet(NAME_KEY, '') || '';
    this.nameInput.placeholder = 'Survivor';
    this.nameInput.style.margin = '6px 0 12px';
    this.hostBtn = el('button', 'rg-btn primary', this.form, C('Coop.Host'));
    this.hostBtn.style.width = '100%';
    this.group.add(this.hostBtn, () => this.pressHost(), 0);
    const row = el('div', '', this.form);
    Object.assign(row.style, { display: 'flex', gap: '10px', marginTop: '12px' });
    this.codeInput = this._input(row, 5);
    this.codeInput.placeholder = C('Coop.CodePlaceholder');
    Object.assign(this.codeInput.style, { flex: '1', textTransform: 'uppercase', letterSpacing: '0.3em', fontSize: '20px' });
    this.codeInput.addEventListener('keydown', (e) => {
      if (e.code === 'Enter' || e.code === 'NumpadEnter') this.pressJoin();
    });
    this.joinBtn = el('button', 'rg-btn', row, C('Coop.Join'));
    this.group.add(this.joinBtn, () => this.pressJoin(), 1);

    // the hosted room
    this.room = el('div', 'rg-hidden', sheet);
    el('div', 'rg-caps', this.room, C('Coop.RoomCode'));
    const codeRow = el('div', '', this.room);
    Object.assign(codeRow.style, { display: 'flex', alignItems: 'center', gap: '14px', margin: '6px 0' });
    this.codeText = el('div', 'rg-title', codeRow, '');
    Object.assign(this.codeText.style, { fontSize: 'clamp(40px, 11vw, 64px)', letterSpacing: '0.18em', color: Palette.Amber,
      userSelect: 'text' });
    this.copyBtn = el('button', 'rg-btn', codeRow, C('Coop.Copy'));
    this.group.add(this.copyBtn, () => this.copyCode(), 2);
    const share = el('div', 'rg-body', this.room, C('Coop.ShareHint'));
    Object.assign(share.style, { fontSize: '13px', color: Palette.Ash, marginBottom: '10px' });
    this.enterBtn = el('button', 'rg-btn primary', this.room, C('Coop.Enter'));
    this.enterBtn.style.width = '100%';
    this.group.add(this.enterBtn, () => this.enterLobby(), 3);

    this.status = el('div', 'rg-body', sheet, '');
    Object.assign(this.status.style, { fontSize: '14px', minHeight: '20px', margin: '12px 0 8px' });
    this.backBtn = el('button', 'rg-btn', sheet, C('Coop.Back'));
    this.backBtn.style.width = '100%';
    this.group.add(this.backBtn, () => this.close(), 4);
  }

  _input(parent, max) {
    const input = el('input', '', parent);
    input.type = 'text';
    input.maxLength = max;
    input.autocomplete = 'off';
    input.spellcheck = false;
    Object.assign(input.style, { width: '100%', boxSizing: 'border-box', minHeight: '44px', padding: '0 12px',
      background: 'rgba(8,8,9,0.85)', color: Palette.Bone, border: `1px solid ${Palette.StrokeDim}`, borderRadius: '5px',
      fontFamily: 'inherit', fontSize: '16px', outline: 'none', pointerEvents: 'auto' });
    return input;
  }

  /** The title's PLAY WITH FRIENDS. */
  openFriends() {
    if (this.open) return;
    this.open = true;
    this.screen.classList.remove('rg-hidden');
    this.form.classList.remove('rg-hidden');
    this.room.classList.add('rg-hidden');
    this._setStatus('', false);
    this.game.nav.push(this.group);
    this.group.focus(0);
  }

  close() {
    if (!this.open || this.busy) return;
    this.open = false;
    this.screen.classList.add('rg-hidden');
    this.game.nav.remove(this.group);
    // backing out of a hosted room before entering the lobby closes it
    if (this.coop.active && this.game.onboarding && this.game.onboarding.busy()) this.coop.leave(false);
  }

  _name() {
    const name = (this.nameInput.value || '').trim().replace(/\s+/g, ' ').slice(0, 16) || 'Survivor';
    this.env.saveSet(NAME_KEY, name);
    return name;
  }

  _setStatus(text, error) {
    this.status.textContent = text;
    this.status.style.color = error ? Palette.Ember : Palette.Ash;
  }

  _error(err, code) {
    const c = err && err.code;
    if (c === 'unreachable') return C('Coop.Unreachable');
    if (c === 'nohost') return C('Coop.NoHost', code);
    if (c === 'full') return C('Coop.Full', code);
    if (c === 'version') return C('Coop.Version', code);
    if (c === 'badcode') return C('Coop.BadCode');
    return C('Coop.Failed', err && err.message ? err.message : String(err));
  }

  async pressHost() {
    if (this.busy) return;
    this.busy = true;
    this.env.play('UiClick');
    this._setStatus(C('Coop.Hosting'), false);
    try {
      const code = await this.coop.host(this._name());
      this.codeText.textContent = code;
      this.form.classList.add('rg-hidden');
      this.room.classList.remove('rg-hidden');
      this._setStatus(C('Coop.RoomOpen', code), false);
      this.group.focus(3);
    } catch (err) {
      this._setStatus(this._error(err), true);
    } finally {
      this.busy = false;
    }
  }

  async pressJoin() {
    if (this.busy) return;
    const typed = this.codeInput.value;
    this.busy = true;
    this.env.play('UiClick');
    this._setStatus(C('Coop.Joining', typed.toUpperCase()), false);
    try {
      await this.coop.join(typed, this._name());
      this.busy = false;
      this._setStatus('', false);
      this.enterLobby();
    } catch (err) {
      this._setStatus(this._error(err, typed.toUpperCase()), true);
    } finally {
      this.busy = false;
    }
  }

  copyCode() {
    const code = this.codeText.textContent;
    const done = () => {
      this.copyBtn.textContent = C('Coop.Copied');
      setTimeout(() => {
        this.copyBtn.textContent = C('Coop.Copy');
      }, 1500);
    };
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(code).then(done, () => this._selectCode());
      else this._selectCode();
    } catch {
      this._selectCode();
    }
  }

  _selectCode() {
    const range = document.createRange();
    range.selectNodeContents(this.codeText);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }

  /** Into the lobby (the room is open): the title closes as PLAY does. */
  enterLobby() {
    this.open = false;
    this.screen.classList.add('rg-hidden');
    this.game.nav.remove(this.group);
    const ob = this.game.onboarding;
    if (ob && ob.busy()) ob.pressPlay();
  }

  // ---------------------------------------------------------------------------------------------------- message

  _buildMessage() {
    const root = this.env.uiRoot();
    this.message = el('div', 'rg-panel rg-hidden', root);
    Object.assign(this.message.style, { position: 'absolute', left: '50%', top: '18%', transform: 'translateX(-50%)',
      padding: '14px 22px', zIndex: '40', textAlign: 'center', maxWidth: '86vw', pointerEvents: 'none' });
    this.messageText = el('div', 'rg-title', this.message, '');
    this.messageText.style.fontSize = '20px';
    this.messageText.style.color = Palette.Ember;
  }

  /** A note over the title (the room ended). */
  showMessage(text) {
    if (!text) return;
    this.messageText.textContent = text;
    this.message.classList.remove('rg-hidden');
    this.messageLeft = MESSAGE_SECONDS;
  }

  // ---------------------------------------------------------------------------------------------------- lobby list

  _lobbyList() {
    const lobby = this.game.lobby;
    if (!lobby || !lobby.squad) return null;
    if (!this.lobbyBox) {
      this.lobbyBox = el('div', '', null);
      this.lobbyBox.style.margin = '8px 0 4px';
      const first = lobby.squad.children[1] || null;
      lobby.squad.insertBefore(this.lobbyBox, first);
      this.soloRow = lobby.readyTag ? lobby.readyTag.parentElement : null;
    }
    return this.lobbyBox;
  }

  _renderLobby() {
    const box = this._lobbyList();
    if (!box) return;
    const coop = this.coop;
    const active = coop.active && !!coop.me;
    if (this.soloRow) this.soloRow.style.display = active ? 'none' : 'flex';
    box.style.display = active ? '' : 'none';
    if (!active) return;
    // each client's link to the host and its ping, as the host measures them (the host's own row has neither)
    const rows = coop.squad.list().map((m) => {
      const link = m.host ? '' : m.link === 'direct' ? C('Coop.Direct') : m.link === 'relay' ? C('Coop.Relay') : C('Coop.Linking');
      const ping = !m.host && m.ping !== null && m.ping !== undefined ? C('Coop.Ping', m.ping) : '';
      return { m, link, ping };
    });
    const code = coop.session ? coop.session.code : '';
    const key = JSON.stringify([code, rows.map((r) => [r.m.id, r.m.name, r.m.ready, r.m.host, r.link, r.ping])]);
    if (key === this.lobbyKey) return;
    this.lobbyKey = key;
    box.textContent = '';
    const codeLine = el('div', 'rg-caps', box, C('Coop.InRoom', code));
    Object.assign(codeLine.style, { color: Palette.Amber, marginBottom: '6px', userSelect: 'text', pointerEvents: 'auto' });
    for (const { m, link, ping } of rows) {
      const row = el('div', '', box);
      Object.assign(row.style, { display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: '6px',
        margin: '4px 0' });
      const left = el('div', '', row);
      left.style.minWidth = '0';
      const name = el('div', 'rg-body', left, m.local ? C('Coop.You', m.name) : m.name);
      Object.assign(name.style, { fontSize: '14px', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' });
      const sub = el('div', 'rg-caps', left, [m.host ? C('Coop.HostTag') : '', link, ping].filter(Boolean).join(' · '));
      sub.style.fontSize = '10px';
      sub.dataset.link = m.local ? 'self' : m.link;
      const chip = el('span', 'rg-chip', row, C(m.ready ? 'Lobby.Ready' : 'Lobby.Unready'));
      chip.style.background = m.ready ? 'rgba(150,158,132,0.25)' : 'rgba(40,37,35,0.9)';
      chip.style.color = m.ready ? Palette.Moss : Palette.Ash;
    }
  }

  // ---------------------------------------------------------------------------------------------------- HUD

  _buildHud() {
    const root = this.env.uiRoot();
    this.hud = el('div', 'rg-panel', root);
    Object.assign(this.hud.style, { position: 'absolute', right: '18px', top: '64px', padding: '8px 12px', minWidth: '170px',
      pointerEvents: 'none', zIndex: '9', display: 'none' });
    el('div', 'rg-caps', this.hud, C('Coop.Squad')).style.marginBottom = '4px';
    this.hudRows = el('div', '', this.hud);
  }

  /** A teammate's status word in the HUD. */
  _status(m) {
    if (m.outcome === 'Escaped') return ['Coop.Status.Escaped', Palette.Moss];
    const life = m.local ? this.game.life.state : m.life;
    if (life === 'Downed') return ['Coop.Status.Downed', Palette.Ember];
    if (life === 'Dead') return ['Coop.Status.Dead', Palette.Blood];
    if (life === 'Spectating') return ['Coop.Status.Spectating', Palette.Ash];
    if (life === 'Lobby') return ['Coop.Status.Lobby', Palette.Ash];
    const inAirlock = m.local ? !!(this.game.airlock && this.game.airlock.inside) : !!(m.pose && m.pose.flags & PoseFlags.Airlock);
    if (inAirlock) return ['Coop.Status.Airlock', Palette.Amber];
    return ['Coop.Status.Alive', Palette.Bone];
  }

  _renderHud() {
    const coop = this.coop;
    const game = this.game;
    const show = coop.active && !!game.run && game.live() && this.env.hudVisible() && coop.squad.list().length > 1 &&
      !(game.onboarding && game.onboarding.busy());
    this.hud.style.display = show ? '' : 'none';
    if (!show) return;
    const rows = coop.squad.list().filter((m) => m.participant).map((m) => [m, ...this._status(m)]);
    const key = rows.map(([m, s]) => `${m.id}:${m.name}:${s}`).join('|');
    if (key === this.hudKey) return;
    this.hudKey = key;
    this.hudRows.textContent = '';
    for (const [m, s, color] of rows) {
      const row = el('div', '', this.hudRows);
      Object.assign(row.style, { display: 'flex', justifyContent: 'space-between', gap: '12px', margin: '2px 0' });
      const name = el('div', 'rg-body', row, m.local ? C('Coop.You', m.name) : m.name);
      name.style.fontSize = '13px';
      const st = el('div', 'rg-caps', row, C(s));
      st.style.color = color;
      st.dataset.status = s;
    }
  }

  frame(dt) {
    if (this.messageLeft > 0) {
      this.messageLeft -= dt;
      if (this.messageLeft <= 0) this.message.classList.add('rg-hidden');
    }
    const phase = this.game.phase;
    if (phase === 'Lobby' || phase === 'Countdown' || this.lobbyBox) this._renderLobby();
    this._renderHud();
  }

  sessionEnding() {
    this.lobbyKey = '';
    this.hudKey = '';
  }
}
