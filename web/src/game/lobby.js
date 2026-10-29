// lobby.js: the pre-run lobby (LobbyService + PerkShopService + LobbyController), single player.
//
//   Ready     stepping onto a ReadyPad on the bus readies you, stepping off every pad clears it; R (keyboard) / Y
//             (gamepad) / the READY UP button toggle it from anywhere; Play Again arrives Ready.
//   Countdown once Ready, CountdownSeconds to deploy (a click every second, confirm / back sounds); unreadying
//             aborts it. At zero: Match.deploy(the voted difficulty).
//   Vote      the boiler-room terminal: Standard / Nightmare cards (what Nightmare changes, from DifficultyConfig);
//             Nightmare plays only with strictly more votes (solo: your vote decides; no vote plays Standard).
//   Perks     the supply-room terminal: credits, one row per perk (cost, owned stock, EQUIPPED), Buy (credits for one
//             unit, saved) and Equip / Unequip; each equipped perk uses up one owned unit when the run starts.
//   HUD       the banner top-centre (waiting / countdown with a draining bar), the squad panel (you, READY / NOT
//             READY, your vote, the difficulty, your credits), the device-aware hint, the touch READY UP button, the
//             pad lamps (moss when Ready).
// Consoles take the Menu input context and a free cursor; B / Escape / Close closes them, walking out of reach too.

import * as THREE from 'three';
import { DifficultyConfig, GameConfig, PerkIds, Perks, MaxPerkStock } from './config.js';
import { S } from './strings.js';
import { cfPos } from './util.js';
import { FocusGroup } from './ui/nav.js';
import { Palette, el, meter } from './ui/style.js';

const PAD_RADIUS = 4.4 / 2;
const PAD_BELOW = 1;
const PAD_ABOVE = 6.5;
const POLL = 0.1;
const TERMINAL_PROMPT_DISTANCE = 8;
const CLOSE_DISTANCE = TERMINAL_PROMPT_DISTANCE + 4;
const BUS_WIDTH = 9;
const BUS_HOOD = 5.6;
const BUS_MIN_LENGTH = 26;
const BUS_MAX_LENGTH = 36;
const REAR_APPROACH = 2.5;
const LAMP_READY = [150, 158, 132];
const LAMP_BLOCKED = [198, 58, 40];
const FADE_IN = 5;
const FADE_OUT = 3;

/** LobbyService.onPad */
export function onPad(position, centre, radius = PAD_RADIUS) {
  const rise = position.y - centre.y;
  if (rise < -PAD_BELOW || rise > PAD_ABOVE) return false;
  const dx = position.x - centre.x;
  const dz = position.z - centre.z;
  return dx * dx + dz * dz <= radius * radius;
}

export class Lobby {
  /** @param {import('./game.js').Game} game */
  constructor(game) {
    this.name = 'Lobby';
    this.game = game;
    this.env = game.env;
    this.ready = false;
    this.onPadId = null;
    /** @type {'Standard'|'Nightmare'|null} */
    this.vote = null;
    this.countdownEndsAt = null;
    this.lastRemaining = null;
    this.pollClock = 0;
    this.terminal = null;
    this.alpha = 0;
    this.shown = false;
    this.perksVisited = false;
    const world = game.world;
    this.pads = world.anchors('ReadyPad', 'Lobby').map((a) => ({ id: a.id, centre: cfPos(a.cframe), light: null }))
      .sort((a, b) => (a.id < b.id ? -1 : 1));
    this.bus = this._bus();
    this.prompts = [];
    this._build();
    this.env.onAction('Kick', (phase) => {
      if (phase === 'Begin' && this.shown && !this.terminal && this.env.context() !== 'Menu') this.toggleReady();
    });
  }

  /** LobbyBuilder.bus: where the bus stands (centred on the pads, hood toward the side of the room with more space). */
  _bus() {
    const world = this.game.world;
    const pads = world.anchors('ReadyPad', 'Lobby');
    if (!pads.length) return null;
    const room = world.room(pads[0].room);
    if (!room) return null;
    const r = room.rect;
    const xs = pads.map((p) => p.cframe[0]);
    const zs = pads.map((p) => p.cframe[2]);
    const minX = Math.min(...xs);
    const maxX = Math.max(...xs);
    const minZ = Math.min(...zs);
    const maxZ = Math.max(...zs);
    const cx = (minX + maxX) / 2;
    const cz = (minZ + maxZ) / 2;
    const spreadX = maxX - minX;
    const spreadZ = maxZ - minZ;
    const alongX = Math.abs(spreadX - spreadZ) > 0.5 ? spreadX > spreadZ : r.w >= r.d;
    const roomLong = alongX ? r.w : r.d;
    let length = Math.min(BUS_MAX_LENGTH, Math.max(BUS_MIN_LENGTH, (alongX ? spreadX : spreadZ) + 16));
    length = Math.min(length, roomLong - BUS_HOOD - 4);
    const toward = alongX ? r.x + r.w - cx >= cx - r.x : r.z + r.d - cz >= cz - r.z;
    const sign = toward ? 1 : -1;
    const margin = 2 + 0.5;
    const lo = (alongX ? r.x : r.z) + margin;
    const hi = (alongX ? r.x + r.w : r.z + r.d) - margin;
    let centre = alongX ? cx : cz;
    const back = length / 2;
    const front = length / 2 + BUS_HOOD;
    const minA = centre - (sign > 0 ? back : front);
    const maxA = centre + (sign > 0 ? front : back);
    if (minA < lo) centre += lo - minA;
    else if (maxA > hi) centre -= maxA - hi;
    const pos = alongX ? new THREE.Vector3(centre, room.floorY, cz) : new THREE.Vector3(cx, room.floorY, centre);
    const axis = alongX ? new THREE.Vector3(sign, 0, 0) : new THREE.Vector3(0, 0, sign);
    const entrance = pos.clone().addScaledVector(axis, -(length / 2 + REAR_APPROACH));
    return { pos, axis, length, width: BUS_WIDTH, entrance };
  }

  /** LobbyBuilder.inBus */
  inBus(p) {
    const b = this.bus;
    if (!b) return false;
    const dx = p.x - b.pos.x;
    const dz = p.z - b.pos.z;
    const along = dx * b.axis.x + dz * b.axis.z;
    const across = Math.abs(-dx * b.axis.z + dz * b.axis.x);
    return Math.abs(along) <= b.length / 2 && across <= b.width / 2;
  }

  /** The voted difficulty (LobbyService.tally for a squad of one). */
  difficulty() {
    return this.vote === 'Nightmare' ? 'Nightmare' : 'Standard';
  }

  // ---------------------------------------------------------------------------------------------------- arrive

  /** The player is put in the lobby (first time, or back from a run; Play Again arrives Ready). */
  arrive(ready = false) {
    const env = this.env;
    const spawns = this.game.world.spawns('Lobby');
    if (spawns.length) env.teleport(spawns[0].cframe);
    if (this.game.traps) this.game.traps.noteTeleport();
    env.resetPlayerForRun();
    env.setLifeState('Lobby');
    env.setMetersActive(false);
    env.setFlashlight(false);
    env.setCurrentLevel('Lobby');
    this.game.profile.trimLoadout();
    this.onPadId = null;
    this.ready = false;
    this.countdownEndsAt = null;
    if (this.game.phase !== 'Lobby') this.game.setPhase('Lobby');
    this._terminalPrompts(true);
    if (ready) this.setReady(true);
  }

  _terminalPrompts(on) {
    for (const p of this.prompts) p.remove();
    this.prompts = [];
    if (!on) return;
    for (const info of this.game.world.entities('Terminal', 'Lobby')) {
      const spec = info.prompts[0];
      const isPerks = info.id.includes('Perks');
      const host = spec ? cfPos(spec.hostCFrame) : cfPos(info.pivot);
      this.prompts.push(this.env.addPrompt({
        position: host,
        text: S(isPerks ? 'Prompt.Terminal.Perks' : 'Prompt.Terminal.Difficulty'),
        objectText: S('Prompt.Terminal'),
        holdSeconds: 0,
        distance: spec ? spec.maxDistance : TERMINAL_PROMPT_DISTANCE,
        requiresLineOfSight: false,
        onTriggered: () => this.openTerminal(isPerks ? 'Perks' : 'Difficulty', host),
      }));
    }
  }

  // ---------------------------------------------------------------------------------------------------- ready

  setReady(value) {
    const phase = this.game.phase;
    if (phase !== 'Lobby' && phase !== 'Countdown') return false;
    if (this.ready === value) return true;
    this.ready = value;
    this._evaluate();
    return true;
  }

  toggleReady() {
    this.setReady(!this.ready);
  }

  _evaluate() {
    const game = this.game;
    if (this.ready && this.countdownEndsAt === null && game.phase === 'Lobby') {
      this.countdownEndsAt = this.env.now() + GameConfig.CountdownSeconds;
      game.setPhase('Countdown');
      this.env.play('UiConfirm');
    } else if (!this.ready && this.countdownEndsAt !== null) {
      this.countdownEndsAt = null;
      if (game.phase === 'Countdown') game.setPhase('Lobby');
      this.env.play('UiBack');
    }
  }

  async _deploy() {
    const difficulty = this.difficulty();
    this.countdownEndsAt = null;
    this.closeTerminal(true);
    this._terminalPrompts(false);
    this.ready = false;
    this._lights(false);
    const ok = await this.game.match.deploy(difficulty);
    if (!ok && this.game.phase === 'Countdown') this.game.setPhase('Lobby');
  }

  // ---------------------------------------------------------------------------------------------------- terminals

  openTerminal(kind, at) {
    if (this.game.phase !== 'Lobby' && this.game.phase !== 'Countdown') return;
    this.env.play('UiClick');
    this.terminal = { kind, at: at.clone() };
    if (kind === 'Perks') this.perksVisited = true;
    this.screen.classList.remove('rg-hidden');
    this.diffView.style.display = kind === 'Difficulty' ? '' : 'none';
    this.shopView.style.display = kind === 'Perks' ? '' : 'none';
    this.screenTitle.textContent = S(kind === 'Perks' ? 'Lobby.ShopTitle' : 'Lobby.DifficultyTitle');
    this.status.textContent = '';
    this.env.pushContext('LobbyTerminal', 'Menu');
    this.env.setCursorFree('LobbyTerminal', true);
    this.env.setMenuEnabled(false);
    this._refreshScreen();
    this.game.nav.push(kind === 'Perks' ? this.shopGroup : this.diffGroup);
    (kind === 'Perks' ? this.shopGroup : this.diffGroup).focus(0);
  }

  closeTerminal(silent = false) {
    if (!this.terminal) return;
    const kind = this.terminal.kind;
    this.terminal = null;
    this.screen.classList.add('rg-hidden');
    this.game.nav.remove(kind === 'Perks' ? this.shopGroup : this.diffGroup);
    this.env.popContext('LobbyTerminal');
    this.env.setCursorFree('LobbyTerminal', false);
    this.env.setMenuEnabled(true);
    this.env.requestPointerLock();
    if (!silent) this.env.play('UiBack');
  }

  _castVote(difficulty) {
    this.vote = difficulty;
    this.env.play('UiConfirm');
    this._refreshScreen();
  }

  _buy(perk) {
    const [ok, key] = this.game.profile.purchase(perk);
    this.status.textContent = ok ? S(key, S(`Perk.${perk}`)) : S(key);
    this.status.style.color = ok ? Palette.Moss : Palette.Ember;
    this.env.play(ok ? 'UiConfirm' : 'UiBack');
    this._refreshScreen();
  }

  _toggleEquip(perk) {
    const equipped = this.game.profile.loadout.includes(perk);
    const [ok, key] = this.game.profile.setEquipped(perk, !equipped);
    if (!ok) {
      this.status.textContent = S(key);
      this.status.style.color = Palette.Ember;
    }
    this.env.play(ok ? 'UiClick' : 'UiBack');
    this._refreshScreen();
  }

  // ---------------------------------------------------------------------------------------------------- view

  _build() {
    const root = this.env.uiRoot();
    this.hud = el('div', 'rg-layer', root);
    this.hud.style.zIndex = '12';
    this.hud.style.opacity = '0';
    // banner
    this.banner = el('div', 'rg-panel', this.hud);
    Object.assign(this.banner.style, { position: 'absolute', left: '50%', top: '13%', transform: 'translateX(-50%)',
      width: 'min(440px, 92vw)', padding: '10px 16px 12px', textAlign: 'center' });
    this.bannerText = el('div', 'rg-title', this.banner, '');
    this.bannerText.style.fontSize = '19px';
    this.bar = meter(this.banner, Palette.Amber);
    this.bar.root.style.marginTop = '8px';
    // squad panel
    this.squad = el('div', 'rg-panel', this.hud);
    Object.assign(this.squad.style, { position: 'absolute', left: '22px', top: '50%', transform: 'translateY(-50%)',
      width: '240px', padding: '12px 14px' });
    el('div', 'rg-caps', this.squad, S('Lobby.Squad'));
    const row = el('div', '', this.squad);
    Object.assign(row.style, { display: 'flex', justifyContent: 'space-between', alignItems: 'center', margin: '8px 0 4px' });
    el('div', 'rg-body', row, S('Lobby.You', 'Survivor')).style.fontSize = '14px';
    this.readyTag = el('span', 'rg-chip', row, '');
    this.voteLine = el('div', 'rg-caps', this.squad, '');
    el('div', 'rg-rule', this.squad).style.margin = '10px 0';
    this.diffLine = el('div', 'rg-body', this.squad, '');
    this.diffLine.style.fontSize = '14px';
    this.creditLine = el('div', 'rg-caps', this.squad, '');
    this.creditLine.style.marginTop = '6px';
    this.creditLine.style.color = Palette.Amber;
    // hint
    this.hint = el('div', 'rg-title rg-outline', this.hud, '');
    Object.assign(this.hint.style, { position: 'absolute', left: '50%', bottom: '64px', transform: 'translateX(-50%)',
      width: 'min(640px, 92vw)', textAlign: 'center', fontSize: '17px' });
    // touch ready button
    this.readyBtn = el('button', 'rg-btn primary', this.hud, S('Lobby.ReadyButton'));
    Object.assign(this.readyBtn.style, { position: 'absolute', right: '28px', bottom: '160px', width: '120px', height: '96px',
      borderRadius: '50%', pointerEvents: 'auto', display: 'none' });
    this.readyBtn.addEventListener('click', () => this.toggleReady());

    // console screen
    this.screen = el('div', 'rg-screen rg-hidden', root);
    this.screen.style.zIndex = '25';
    this.screen.style.background = 'rgba(0,0,0,0.45)';
    const sheet = el('div', 'rg-sheet', this.screen);
    Object.assign(sheet.style, { width: 'min(560px, 94vw)', maxHeight: '90vh', overflow: 'auto', padding: '16px 22px 18px', boxSizing: 'border-box' });
    el('div', 'rg-tape l', sheet);
    el('div', 'rg-tape r', sheet);
    this.screenTitle = el('div', 'rg-caps', sheet, '');
    el('div', 'rg-rule', sheet).style.margin = '8px 0 12px';
    // difficulty
    this.diffView = el('div', '', sheet);
    this.diffGroup = new FocusGroup({ back: () => this.closeTerminal() });
    this.cards = {};
    for (const d of ['Standard', 'Nightmare']) {
      const card = el('button', 'rg-btn', this.diffView);
      Object.assign(card.style, { display: 'flex', flexDirection: 'column', alignItems: 'flex-start', width: '100%',
        textTransform: 'none', letterSpacing: '0', padding: '12px 14px', margin: '0 0 10px', textAlign: 'left', gap: '4px' });
      const name = el('div', 'rg-title', card, S(`Lobby.Difficulty.${d}`));
      name.style.fontSize = '22px';
      name.style.color = d === 'Nightmare' ? Palette.Ember : Palette.Bone;
      const lines = d === 'Nightmare' ? [S('Lobby.Difficulty.NightmareHint'), ...nightmareLines()] : [S('Lobby.Difficulty.StandardHint')];
      for (const l of lines) {
        const line = el('div', 'rg-body', card, l);
        Object.assign(line.style, { fontSize: '13px', color: Palette.Ash });
      }
      const foot = el('div', '', card);
      Object.assign(foot.style, { display: 'flex', gap: '10px', marginTop: '4px' });
      const votes = el('span', 'rg-caps', foot, '');
      const mine = el('span', 'rg-chip', foot, S('Lobby.YourVote'));
      mine.style.background = 'rgba(150,158,132,0.25)';
      mine.style.color = Palette.Moss;
      this.cards[d] = { card, votes, mine };
      this.diffGroup.add(card, () => this._castVote(d));
    }
    const rule = el('div', 'rg-body', this.diffView, S('Lobby.VoteRule'));
    Object.assign(rule.style, { fontSize: '12px', color: Palette.Ash, margin: '2px 0 10px' });
    // shop
    this.shopView = el('div', '', sheet);
    this.shopGroup = new FocusGroup({ back: () => this.closeTerminal() });
    this.shopCredits = el('div', 'rg-title', this.shopView, '');
    Object.assign(this.shopCredits.style, { fontSize: '20px', color: Palette.Amber, marginBottom: '10px' });
    this.rows = {};
    PerkIds.forEach((perk, i) => {
      const box = el('div', 'rg-panel', this.shopView);
      Object.assign(box.style, { padding: '10px 12px', marginBottom: '8px' });
      const top = el('div', '', box);
      Object.assign(top.style, { display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', gap: '8px' });
      el('div', 'rg-title', top, S(`Perk.${perk}`)).style.fontSize = '17px';
      const tag = el('span', 'rg-chip', top, S('Lobby.Equipped'));
      tag.style.background = 'rgba(150,158,132,0.25)';
      tag.style.color = Palette.Moss;
      const desc = el('div', 'rg-body', box, S(`Perk.${perk}.Desc`));
      Object.assign(desc.style, { fontSize: '13px', color: Palette.Ash, margin: '4px 0 8px' });
      const actions = el('div', '', box);
      Object.assign(actions.style, { display: 'flex', alignItems: 'center', gap: '8px' });
      const owned = el('span', 'rg-caps', actions, '');
      owned.style.flex = '1';
      const buy = el('button', 'rg-btn small', actions, '');
      const equip = el('button', 'rg-btn small', actions, '');
      this.shopGroup.add(buy, () => this._buy(perk), i);
      this.shopGroup.add(equip, () => this._toggleEquip(perk), i);
      this.rows[perk] = { tag, owned, buy, equip };
    });
    const equipHint = el('div', 'rg-body', this.shopView, S('Lobby.EquipHint'));
    Object.assign(equipHint.style, { fontSize: '12px', color: Palette.Ash, margin: '2px 0 8px' });
    this.status = el('div', 'rg-body', sheet, '');
    Object.assign(this.status.style, { fontSize: '13px', minHeight: '18px', margin: '4px 0' });
    const close = el('button', 'rg-btn', sheet, S('Lobby.Close'));
    close.style.width = '100%';
    this.diffGroup.add(close, () => this.closeTerminal(), 10);
    this.shopGroup.add(close, () => this.closeTerminal(), 10);
  }

  _refreshScreen() {
    for (const d of ['Standard', 'Nightmare']) {
      const c = this.cards[d];
      c.votes.textContent = S('Lobby.Votes', this.vote === d ? 1 : 0);
      c.mine.style.display = this.vote === d ? '' : 'none';
      c.card.style.borderColor = this.difficulty() === d ? (d === 'Nightmare' ? Palette.Ember : Palette.Moss) : '';
    }
    const p = this.game.profile;
    this.shopCredits.textContent = S('Lobby.Credits', p.credits);
    for (const perk of PerkIds) {
      const r = this.rows[perk];
      const spec = Perks[perk];
      const stock = p.stock(perk);
      const equipped = p.loadout.includes(perk);
      r.tag.style.display = equipped ? '' : 'none';
      r.owned.textContent = `${S('Lobby.Owned', stock)}  ·  ${S('Lobby.Credits', spec.cost)}`;
      r.buy.textContent = S('Lobby.Buy', spec.cost);
      r.buy.toggleAttribute('disabled', !(p.credits >= spec.cost && stock < MaxPerkStock) || p.readOnly);
      r.equip.textContent = S(equipped ? 'Lobby.Unequip' : 'Lobby.Equip');
      r.equip.toggleAttribute('disabled', !(equipped || stock >= 1));
    }
  }

  _lights(on) {
    for (const pad of this.pads) {
      const lit = on && pad.id === this.onPadId;
      if (lit && !pad.light) {
        pad.light = this.env.addLight({ position: pad.centre.clone().add(new THREE.Vector3(0, 1, 0)),
          color: this.ready ? LAMP_READY : LAMP_BLOCKED, brightness: 1.2, range: 8 });
      } else if (!lit && pad.light) {
        pad.light.remove();
        pad.light = null;
      }
      if (pad.light) pad.light.set({ color: this.ready ? LAMP_READY : LAMP_BLOCKED });
    }
  }

  // ---------------------------------------------------------------------------------------------------- drive

  phaseChanged(phase) {
    if (phase !== 'Lobby' && phase !== 'Countdown') {
      this.closeTerminal(true);
      this._lights(false);
    }
  }

  tick(dt, now) {
    const game = this.game;
    const phase = game.phase;
    if (phase !== 'Lobby' && phase !== 'Countdown') return;
    this.pollClock += dt;
    if (this.pollClock >= POLL) {
      this.pollClock = 0;
      const root = this.env.rootPosition(_root);
      let pad = null;
      let best = Infinity;
      for (const p of this.pads) {
        if (!onPad(root, p.centre)) continue;
        const d = Math.hypot(root.x - p.centre.x, root.z - p.centre.z);
        if (d < best) {
          best = d;
          pad = p.id;
        }
      }
      const before = this.onPadId;
      this.onPadId = pad;
      if (pad && !before) this.setReady(true);
      else if (before && !pad && this.ready) this.setReady(false);
      if (this.terminal && root.distanceTo(this.terminal.at) > CLOSE_DISTANCE) this.closeTerminal();
      this._lights(true);
    }
    if (this.countdownEndsAt !== null && phase === 'Countdown') {
      const remaining = Math.max(0, this.countdownEndsAt - now);
      if (this.lastRemaining !== null && Math.ceil(remaining) < Math.ceil(this.lastRemaining)) this.env.play('UiClick');
      this.lastRemaining = remaining;
      if (remaining <= 0.05 && this.ready) this._deploy();
    } else {
      this.lastRemaining = null;
    }
  }

  frame(dt, now) {
    const game = this.game;
    const shown = (game.phase === 'Lobby' || game.phase === 'Countdown') && !(game.onboarding && game.onboarding.busy());
    this.shown = shown;
    const want = shown ? 1 : 0;
    this.alpha += Math.sign(want - this.alpha) * Math.min(Math.abs(want - this.alpha), (shown ? FADE_IN : FADE_OUT) * dt);
    this.hud.style.opacity = String(this.alpha);
    this.hud.style.display = this.alpha > 0.001 ? '' : 'none';
    if (!shown) return;
    const counting = this.countdownEndsAt !== null;
    if (counting) {
      const remaining = Math.max(0, this.countdownEndsAt - now);
      this.bannerText.textContent = S('Lobby.Countdown', Math.ceil(remaining));
      this.bar.set(remaining / GameConfig.CountdownSeconds);
      this.bar.root.style.display = '';
    } else {
      this.bannerText.textContent = S('Lobby.WaitingForSquad', this.ready ? 1 : 0, GameConfig.MinSquad);
      this.bar.root.style.display = 'none';
    }
    this.readyTag.textContent = S(this.ready ? 'Lobby.Ready' : 'Lobby.Unready');
    this.readyTag.style.background = this.ready ? 'rgba(150,158,132,0.25)' : 'rgba(40,37,35,0.9)';
    this.readyTag.style.color = this.ready ? Palette.Moss : Palette.Ash;
    this.voteLine.textContent = this.vote ? S(`Lobby.Difficulty.${this.vote}`) : S('Lobby.NoVote');
    this.diffLine.textContent = S('Lobby.DifficultyCurrent', S(`Lobby.Difficulty.${this.difficulty()}`));
    this.creditLine.textContent = S('Lobby.Credits', this.game.profile.credits);
    const device = this.env.device();
    const state = this.ready ? 'Ready' : 'ReadyUp';
    const suffix = device === 'Gamepad' || device === 'Touch' ? device : 'KeyboardMouse';
    this.hint.textContent = S(`Lobby.Hint.${state}.${suffix}`);
    this.readyBtn.style.display = device === 'Touch' && !this.terminal ? '' : 'none';
    this.readyBtn.textContent = S(this.ready ? 'Lobby.UnreadyButton' : 'Lobby.ReadyButton');
    if (this.terminal) this._refreshScreen();
  }
}

/** LobbyController.nightmareLines */
function nightmareLines() {
  const s = DifficultyConfig.Standard;
  const n = DifficultyConfig.Nightmare;
  const pct = (m) => Math.round((m - 1) * 100);
  return [
    S('Lobby.Nightmare.Speed', pct(n.creatureSpeedMultiplier), pct(n.hearingMultiplier)),
    S('Lobby.Nightmare.Traps', n.trapCount, s.trapCount),
    S('Lobby.Nightmare.Batteries', n.batteriesPerLevel, s.batteriesPerLevel),
    S('Lobby.Nightmare.Grates', Math.round(n.lockedGrateFraction * 100), Math.round(s.lockedGrateFraction * 100)),
    S('Lobby.Nightmare.Credits', n.creditMultiplier),
  ];
}

const _root = new THREE.Vector3();
