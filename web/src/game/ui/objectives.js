// objectives.js: what to do next, always one glance away (ObjectiveTracker).
//
//   Tracker   a compact sheet top-left (top-right on touch): OBJECTIVE, the goal, the floor's tip, and in a run the
//             radar's key with its charges (RADAR 1/3). Fully shown when the goal changes or when the radar is pressed
//             empty (openSheet: with the line "Radar empty. Batteries blink."), fading after TrackerHold seconds idle;
//             in the lobby it stays, with the optional lines (vote, perks) ticking off and a HOW TO PLAY button (H /
//             d-pad left / tap) that replays the walkthrough.
//   Goals     lobby: the bus -> a pad -> waiting -> the countdown; every floor: its objective (the title and each step
//             with its count, done steps ticked, the current one marked) until its exit unlocks, then "Get to the
//             <compass> stairwell" (the run's route; a floor that is only crossed shows the way to its stairwell from
//             the start); once its doors count down get in (or hold it from inside); Floor 1 after the gate slams: a
//             vent around it, crawl through (as the tip); the roof: out of the stair housing, find the parachutes, run
//             for them once the door is smashed, the gap with a pack on, the cord, landed.
//   Marker    a floating diamond over the lobby's current step (the bus's rear door, then the nearest free pad). The
//             Marker and the Pointer (a chevron round the crosshair toward a point) are the radar's too (ui/radar.js):
//             there is no other way to be shown where things are.
//   Stage card the stage's card (StageConfig's Card text: FLOOR 1 · HALLWAYS), the level's name and OBJECTIVE: <the
//             floor's objective> in the centre-top on each new level, held while the HUD is hidden (up to
//             FloorCardWait seconds).
// Hidden while the HUD is hidden, in the Cutscene / Menu contexts, under a Cutscene / Jumpscare lock, while the
// onboarding screens are up and while the player is not Alive on a level.

import * as THREE from 'three';
import { TutorialConfig } from '../config.js';
import { S } from '../strings/index.js';
import '../strings/kit.js';
import { glyphFor } from './nav.js';
import { Palette, el } from './style.js';

const T = TutorialConfig.Timing;
const SCAN = 0.25;
const STUDS_TO_METERS = 0.28;
const POINTER_RADIUS = 92;
const MARKER_LIFT = 6.5;
const BEYOND_MARGIN = 3;
const FADE_IN = 4;
const FADE_OUT = 2.5;
const VENT_STATES = new Set(['VentCrawling', 'VentScurrying']);
const ROOF_LEVEL = 'Level3_Roof';

/** ObjectiveTracker.levelObjective: the goal's line and tip on a level. */
export function levelObjective(input) {
  const floor = TutorialConfig.Floors[input.level];
  if (!floor) return null;
  const tip = floor.tip;
  if (input.airlock !== 'None') {
    if (input.insideAirlock) return { text: 'Objective.Airlock.Wait', tip: null };
    return { text: 'Objective.Airlock.Get', tip: null };
  }
  if (input.level === ROOF_LEVEL) {
    const p = input.parachute;
    if (p === 'Landed') return { text: 'Objective.Roof.Landed', tip: null };
    if (p === 'Freefall') return { text: 'Objective.Roof.Cord', tip: null };
    if (p === 'Canopy') return null;
    if (p === 'Packed') return { text: 'Objective.Roof.Jump', tip: null };
    if (input.roofDoor === 'Smashed') return { text: 'Objective.Roof.Run', tip };
    if (input.onRoof) return { text: 'Objective.Roof.Search', tip };
    return { text: 'Objective.Roof.Out', tip };
  }
  if (input.level === 'Level1_Hallways' && input.gateSlammed && !input.beyondGate) {
    if (input.inVent) return { text: 'Objective.GateVent', tip: null };
    return { text: 'Objective.Gate', tip };
  }
  // the run route's stair tower (East / West / NorthEast / ...), else the floor's side
  return { text: `Objective.Stairwell.${input.tower || floor.stairwell || 'East'}`, tip };
}

/** ObjectiveTracker.lobbyObjective */
export function lobbyObjective(input) {
  const optional = TutorialConfig.LobbySteps.filter((s) => s.optional)
    .map((s) => ({ text: s.text, done: s.id === 'Vote' ? input.voted : input.perks }));
  if (input.phase === 'Countdown' && input.ready) return { text: 'Objective.Lobby.Countdown', target: null, optional: [] };
  if (input.ready) return { text: 'Objective.Lobby.Waiting', target: null, optional };
  if (!input.onBus) return { text: 'Objective.Lobby.Bus', target: 'Bus', optional };
  return { text: 'Objective.Lobby.Ready', target: 'Pad', optional };
}

/** ObjectiveTracker.beyond: past the gate on the way to the exit. */
function beyond(gate, exit, point, margin) {
  const ax = exit.x - gate.x;
  const az = exit.z - gate.z;
  const len = Math.hypot(ax, az);
  if (len < 1e-6) return false;
  return ((point.x - gate.x) * ax + (point.z - gate.z) * az) / len > margin;
}

function nearest(points, from) {
  let best = null;
  let bd = Infinity;
  for (const p of points) {
    const d = p.distanceTo(from);
    if (d < bd) {
      bd = d;
      best = p;
    }
  }
  return best;
}

/**
 * A floating marker over a world point: an icon in a diamond, a name and the straight distance in metres. `color` is
 * its accent (the lobby's amber, the radar's cold green); `dot` draws the small dot of a radar battery instead.
 */
export class Marker {
  constructor(layer, color, dot = false) {
    this.dot = dot;
    this.root = el('div', '', layer);
    Object.assign(this.root.style, { position: 'absolute', transform: 'translate(-50%, -100%)', textAlign: 'center',
      opacity: '0', pointerEvents: 'none', display: 'none' });
    this.label = el('div', 'rg-caps rg-outline', this.root);
    Object.assign(this.label.style, { color, fontSize: '13px', whiteSpace: 'nowrap', display: dot ? 'none' : '' });
    this.distance = el('div', 'rg-caps rg-outline', this.root);
    this.distance.style.display = dot ? 'none' : '';
    this.diamond = el('div', '', this.root);
    const size = dot ? 7 : 14;
    Object.assign(this.diamond.style, { width: `${size}px`, height: `${size}px`, margin: '4px auto 0', position: 'relative',
      transform: dot ? 'none' : 'rotate(45deg)', borderRadius: dot ? '50%' : '0', border: dot ? 'none' : `2px solid ${color}`,
      background: dot ? color : 'rgba(0,0,0,0.25)' });
    this.icon = el('div', '', this.diamond);
    Object.assign(this.icon.style, { position: 'absolute', left: '50%', top: '50%', width: '6px', height: '6px',
      transform: 'translate(-50%, -50%) rotate(-45deg)', background: color, display: 'none' });
  }

  /**
   * Shows the marker at `point` (lifted `lift` studs) with its text, or hides it off screen.
   * @param {import('../env.js').Env} env
   * @param {{label?: string, metres?: number, icon?: 'Item'|'Station'|'Exit'|null, alpha: number, pulse: number, lift?: number}} o
   */
  place(env, point, o) {
    _p.copy(point);
    _p.y += o.lift ?? MARKER_LIFT;
    const s = o.alpha > 0.001 ? env.project(_p) : null;
    if (!s) {
      this.hide();
      return;
    }
    this.root.style.display = '';
    this.root.style.left = `${s.x}px`;
    this.root.style.top = `${s.y}px`;
    this.root.style.opacity = String(o.alpha);
    if (!this.dot) {
      this.label.textContent = o.label || '';
      this.distance.textContent = S('Objective.Distance', Math.max(1, o.metres ?? 0));
      this.icon.style.display = o.icon ? '' : 'none';
      if (o.icon) {
        // the icon: a dot for an item, a square for a station, a triangle for the exit
        this.icon.style.borderRadius = o.icon === 'Item' ? '50%' : '0';
        this.icon.style.clipPath = o.icon === 'Exit' ? 'polygon(50% 0, 100% 100%, 0 100%)' : 'none';
      }
    }
    this.diamond.style.opacity = String(0.65 + 0.35 * o.pulse);
  }

  hide() {
    this.root.style.display = 'none';
  }

  remove() {
    this.root.remove();
  }
}

/** The chevron round the crosshair toward a world point, with a label (ObjectiveTracker's pointer). */
export class Pointer {
  constructor(layer, color) {
    this.root = el('div', 'rg-layer', layer);
    this.arrow = el('div', '', this.root);
    Object.assign(this.arrow.style, { position: 'absolute', width: '0', height: '0', borderLeft: '9px solid transparent',
      borderRight: '9px solid transparent', borderBottom: `16px solid ${color}`, transformOrigin: '50% 60%' });
    this.label = el('div', 'rg-caps rg-outline', this.root, '');
    Object.assign(this.label.style, { position: 'absolute', transform: 'translate(-50%, -50%)', color, whiteSpace: 'nowrap' });
    this.root.style.opacity = '0';
  }

  /** Points at `target` (a world point) from the camera with `text` beside it, at `alpha`. */
  place(env, target, text, alpha) {
    this.root.style.opacity = String(alpha);
    if (alpha <= 0.001 || !target) return;
    const cam = env.camera();
    _local.copy(target).applyMatrix4(_inv.copy(cam.matrixWorld).invert());
    const angle = Math.abs(_local.x) < 1e-6 && Math.abs(_local.z) < 1e-6 ? 0 : Math.atan2(_local.x, -_local.z);
    const rect = env.uiRoot().getBoundingClientRect();
    const cx = rect.width / 2;
    const cy = rect.height / 2;
    const x = Math.sin(angle) * POINTER_RADIUS;
    const y = -Math.cos(angle) * POINTER_RADIUS;
    this.arrow.style.left = `${cx + x - 9}px`;
    this.arrow.style.top = `${cy + y - 8}px`;
    this.arrow.style.transform = `rotate(${(angle * 180) / Math.PI}deg)`;
    this.label.style.left = `${cx + x * 0.62}px`;
    this.label.style.top = `${cy + y * 0.62}px`;
    this.label.textContent = text;
  }
}

export class Objectives {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Objectives';
    this.game = game;
    this.env = game.env;
    this.clock = 0;
    this.scannedAt = -Infinity;
    this.activeAt = -Infinity;
    this.lastText = null;
    this.trackerAlpha = 0;
    this.cardAlpha = 0;
    this.markerAlpha = 0;
    this.cardLevel = null;
    this.cardDueAt = -Infinity;
    this.cardStartedAt = null;
    this.shownLevel = null;
    /** a line the sheet shows under the goal until it fades (openSheet), or null */
    this.sheetLine = null;
    this.scan = { objective: null, lobby: null, target: null, inLobby: false };
    this._build();
    window.addEventListener('keydown', (e) => {
      if (e.code === 'KeyH' && !e.repeat) this._help();
    });
  }

  _build() {
    const root = this.env.uiRoot();
    this.layer = el('div', 'rg-layer', root);
    this.layer.style.zIndex = '11';
    // tracker
    this.tracker = el('div', 'rg-panel', this.layer);
    Object.assign(this.tracker.style, { position: 'absolute', left: '14px', top: '14px', width: '290px', padding: '10px 12px',
      opacity: '0', pointerEvents: 'none' });
    const head = el('div', '', this.tracker);
    Object.assign(head.style, { display: 'flex', justifyContent: 'space-between', alignItems: 'center' });
    el('div', 'rg-caps', head, S('Objective.Header'));
    const keyBox = el('div', '', head);
    Object.assign(keyBox.style, { display: 'flex', alignItems: 'center', gap: '6px' });
    this.keyCap = el('span', 'rg-key', keyBox, 'TAB');
    this.keyLabel = el('span', 'rg-caps', keyBox, '');
    this.line = el('div', 'rg-title', this.tracker, '');
    Object.assign(this.line.style, { fontSize: '17px', marginTop: '6px' });
    // the floor objective's steps: a tick box and the line with its count
    this.stepRows = [0, 1, 2, 3, 4, 5].map(() => {
      const row = el('div', '', this.tracker);
      Object.assign(row.style, { display: 'none', alignItems: 'center', gap: '8px', marginTop: '5px' });
      const box = el('div', '', row);
      Object.assign(box.style, { width: '11px', height: '11px', flex: 'none', border: `1px solid ${Palette.Ash}`,
        borderRadius: '2px', fontSize: '10px', lineHeight: '11px', textAlign: 'center', color: Palette.Ink });
      const label = el('div', 'rg-body', row, '');
      label.style.fontSize = '13px';
      return { row, box, label };
    });
    this.tip = el('div', 'rg-body', this.tracker, '');
    Object.assign(this.tip.style, { fontSize: '13px', color: Palette.Ash, marginTop: '4px' });
    this.extra = el('div', 'rg-body', this.tracker, '');
    Object.assign(this.extra.style, { fontSize: '13px', color: Palette.Bone, marginTop: '6px', display: 'none' });
    this.optional = [0, 1].map(() => {
      const row = el('div', '', this.tracker);
      Object.assign(row.style, { display: 'flex', alignItems: 'center', gap: '8px', marginTop: '6px' });
      const box = el('div', '', row);
      Object.assign(box.style, { width: '10px', height: '10px', border: `1px solid ${Palette.Ash}`, borderRadius: '2px' });
      const label = el('div', 'rg-body', row, '');
      label.style.fontSize = '13px';
      return { row, box, label };
    });
    this.help = el('button', 'rg-btn small', this.tracker, '');
    Object.assign(this.help.style, { marginTop: '10px', pointerEvents: 'auto', width: '100%' });
    this.helpKey = el('span', 'rg-glyph', this.help, 'H');
    el('span', '', this.help, S('Lobby.Help'));
    this.help.addEventListener('click', () => this._help());
    // floor card
    this.card = el('div', '', this.layer);
    Object.assign(this.card.style, { position: 'absolute', left: '50%', top: '24%', transform: 'translate(-50%, -50%)',
      textAlign: 'center', opacity: '0' });
    this.cardTitle = el('div', 'rg-title rg-outline', this.card, '');
    this.cardTitle.style.fontSize = '44px';
    this.cardTitle.style.letterSpacing = '0.08em';
    const rule = el('div', '', this.card);
    Object.assign(rule.style, { height: '1px', margin: '10px auto 0', width: '60%',
      background: `linear-gradient(90deg, transparent, ${Palette.Stroke}, transparent)` });
    this.cardName = el('div', 'rg-caps rg-outline', this.card, '');
    Object.assign(this.cardName.style, { fontSize: '15px', letterSpacing: '0.28em', marginTop: '8px' });
    this.cardGoal = el('div', 'rg-caps rg-outline', this.card, '');
    Object.assign(this.cardGoal.style, { fontSize: '13px', letterSpacing: '0.22em', marginTop: '10px', color: Palette.Amber });
    // the lobby's marker
    this.marker = new Marker(this.layer, Palette.Amber);
  }

  _allowed() {
    const g = this.game;
    if (!this.env.hudVisible() || (g.onboarding && g.onboarding.busy())) return false;
    const ctx = this.env.context();
    if (ctx === 'Cutscene' || ctx === 'Menu') return false;
    const lock = g.controlLock();
    return lock !== 'Cutscene' && lock !== 'Jumpscare';
  }

  _help() {
    if (this.scan.inLobby && this._allowed() && this.game.onboarding) this.game.onboarding.openWalkthrough('Hidden');
  }

  /** Brings the sheet back (the radar pressed empty), with `line` under the goal until it fades. */
  openSheet(line) {
    this.activeAt = this.clock;
    this.sheetLine = line || null;
  }

  // ---------------------------------------------------------------------------------------------------- scans

  _scanLobby() {
    const g = this.game;
    const lobby = g.lobby;
    const root = this.env.rootPosition(_root);
    const objective = lobbyObjective({
      phase: g.phase, ready: lobby.ready, onBus: lobby.inBus(root), voted: lobby.vote !== null,
      perks: g.profile.loadout.length > 0 || Object.keys(g.profile.data.PerkStock).length > 0 || lobby.perksVisited,
    });
    this.scan.lobby = objective;
    this.scan.objective = null;
    this.scan.inLobby = true;
    let target = null;
    if (objective.target === 'Bus' && lobby.bus) target = lobby.bus.entrance;
    else if (objective.target === 'Pad') target = nearest(lobby.pads.map((p) => p.centre), root);
    this.scan.target = target;
  }

  _scanLevel(level) {
    const g = this.game;
    const root = this.env.rootPosition(_root);
    const route = g.route(level);
    const exits = route ? route.exitDoorIds.map((id) => g.doors.get(id)).filter(Boolean).map((d) => d.centre) : [];
    const exitPoint = nearest(exits, root);
    const gate = level === 'Level1_Hallways' ? g.doors.find(level, 'HallwayGate') : null;
    const gatePoint = gate ? gate.centre : null;
    const roof = level === ROOF_LEVEL ? g.level3 : null;
    const roofDoor = roof ? roof.roofDoor() : null;
    const zone = g.world.roomAt(root, level);
    const airlock = g.airlock;
    const airlockState = airlock.level === level && airlock.deadline !== null ? (airlock.phase === 'Sealing' ? 'Sealing' : 'Waiting') : 'None';
    const objective = levelObjective({
      level,
      tower: route ? route.tower : null,
      airlock: airlockState,
      insideAirlock: airlock.inside,
      gateSlammed: !!gate && (gate.state === 'Locked' || gate.state === 'Closed'),
      beyondGate: !!(gatePoint && exitPoint && beyond(gatePoint, exitPoint, root, BEYOND_MARGIN)),
      inVent: VENT_STATES.has(this.env.moveState()),
      roofDoor: roofDoor ? roofDoor.state : null,
      onRoof: !!zone && zone.kind !== 'Stairwell' && (!roof || zone.id !== roof.housingRoom()) &&
        !(g.parachute && g.parachute.inTower(root)),
      parachute: g.parachute ? g.parachute.state : 'None',
    });
    this.scan.lobby = null;
    this.scan.inLobby = false;
    this.scan.target = null;
    this.scan.steps = null;
    this.scan.title = null;
    // the floor objective: its title and steps until the exit unlocks, then the way to the stairwell
    const floor = g.floors ? g.floors.tracker(level) : null;
    if (floor && objective && airlockState === 'None') {
      this.scan.steps = floor.steps;
      if (!floor.unlocked) {
        this.scan.title = floor.title;
        const context = objective.text === 'Objective.Gate' || objective.text === 'Objective.GateVent' ? objective.text : null;
        objective.tip = context || objective.tip;
      } else if (floor.exit) {
        this.scan.title = floor.exit;
      }
    }
    this.scan.objective = objective;
  }

  _rescan() {
    this.scannedAt = this.clock;
    const g = this.game;
    const life = g.life.state;
    if ((g.phase === 'Lobby' || g.phase === 'Countdown') && life !== 'Alive' && life !== 'Downed') {
      this._scanLobby();
      return;
    }
    if ((g.phase === 'InRun' || g.phase === 'Deploying') && g.level && life === 'Alive') {
      this._scanLevel(g.level);
      return;
    }
    this.scan = { objective: null, lobby: null, target: null, inLobby: false, title: null, steps: null };
  }

  // ---------------------------------------------------------------------------------------------------- frame

  _card(dt, canShow) {
    const g = this.game;
    const inRun = g.phase === 'InRun' || g.phase === 'Deploying';
    if (inRun && g.level && g.level !== this.shownLevel) {
      this.shownLevel = g.level;
      this.cardLevel = g.level;
      this.cardDueAt = this.clock;
      this.cardStartedAt = null;
      this.activeAt = this.clock;
    } else if (!inRun) this.shownLevel = null;
    if (this.cardLevel && this.cardStartedAt === null) {
      if (canShow) {
        const floor = TutorialConfig.Floors[this.cardLevel];
        const stage = g.stages.get(this.cardLevel);
        if (floor && stage && stage.card) {
          this.cardTitle.textContent = S(stage.card);
          this.cardName.textContent = S(floor.name);
          const goal = this.game.floors ? this.game.floors.floor(this.cardLevel) : null;
          this.cardGoal.textContent = goal ? S('Obj.Card', S(goal.spec.title)) : '';
          this.cardGoal.style.display = goal ? '' : 'none';
          this.cardStartedAt = this.clock;
        } else this.cardLevel = null;
      } else if (this.clock - this.cardDueAt > T.FloorCardWait) this.cardLevel = null;
    }
    let target = 0;
    if (this.cardStartedAt !== null) {
      const t = this.clock - this.cardStartedAt;
      if (t < T.FloorCardIn) target = t / T.FloorCardIn;
      else if (t < T.FloorCardIn + T.FloorCardHold) target = 1;
      else target = Math.max(0, 1 - (t - T.FloorCardIn - T.FloorCardHold) / T.FloorCardOut);
      if (t > T.FloorCardIn + T.FloorCardHold + T.FloorCardOut) {
        this.cardStartedAt = null;
        this.cardLevel = null;
      }
    }
    if (!canShow) target = 0;
    this.cardAlpha += Math.sign(target - this.cardAlpha) * Math.min(Math.abs(target - this.cardAlpha), dt * FADE_IN);
    this.card.style.opacity = String(this.cardAlpha);
  }

  frame(dt) {
    this.clock += dt;
    if (this.clock - this.scannedAt >= SCAN) this._rescan();
    const env = this.env;
    const canShow = this._allowed();
    this._card(dt, canShow);
    const device = env.device();
    const touch = device === 'Touch';
    this.tracker.style.left = touch ? 'auto' : '14px';
    this.tracker.style.right = touch ? '14px' : 'auto';
    this.tracker.style.top = touch ? '72px' : '14px';
    this.tracker.style.width = touch ? '250px' : '290px';
    const { lobby, objective, title, steps } = this.scan;
    const text = lobby ? lobby.text : objective ? objective.text : null;
    const tipKey = objective ? objective.tip : null;
    // a new goal or a step changing (a count, a tick) brings the tracker back
    const stepKey = steps ? steps.map((s) => `${s.done ? 1 : 0}${s.active ? 1 : 0}${s.text}`).join('|') : '';
    const shown = `${title || text}#${stepKey}`;
    if (shown !== this.lastText) {
      this.lastText = shown;
      this.activeAt = this.clock;
    }
    if (title) this.line.textContent = title;
    else if (text) this.line.textContent = S(text);
    this.stepRows.forEach((row, i) => {
      const step = steps ? steps[i] : null;
      row.row.style.display = step ? 'flex' : 'none';
      if (!step) return;
      row.label.textContent = step.text;
      row.label.style.color = step.done ? Palette.Moss : step.active ? Palette.Bone : Palette.Ash;
      row.box.style.background = step.done ? Palette.Moss : 'transparent';
      row.box.style.borderColor = step.active ? Palette.Amber : Palette.Ash;
      row.box.textContent = step.done ? '✓' : '';
    });
    this.tip.textContent = tipKey ? S(tipKey) : '';
    this.tip.style.display = tipKey ? '' : 'none';
    this.optional.forEach((row, i) => {
      const entry = lobby ? lobby.optional[i] : null;
      row.row.style.display = entry ? 'flex' : 'none';
      if (entry) {
        row.label.textContent = S(entry.text);
        row.label.style.color = entry.done ? Palette.Moss : Palette.Ash;
        row.box.style.background = entry.done ? Palette.Moss : 'transparent';
      }
    });
    this.help.style.display = this.scan.inLobby ? '' : 'none';
    this.helpKey.style.display = touch ? 'none' : '';
    this.helpKey.textContent = device === 'Gamepad' ? '◀' : 'H';
    // the radar's key and charges, in a run
    const radar = this.game.radar;
    const charges = !this.scan.inLobby && text && radar && this.game.run ? radar.chargesLine() : null;
    this.keyCap.textContent = glyphFor(env, 'Radar', device);
    this.keyLabel.textContent = charges || '';
    this.keyCap.style.display = charges ? '' : 'none';
    this.keyLabel.style.display = charges ? '' : 'none';
    let trackerTarget = 0;
    if (text && canShow) {
      if (this.scan.inLobby) trackerTarget = 1;
      else {
        const since = this.clock - this.activeAt;
        trackerTarget = since <= T.TrackerHold ? 1 : Math.max(0, 1 - (since - T.TrackerHold) / T.TrackerFade);
      }
    }
    if (trackerTarget <= 0 && this.trackerAlpha <= 0.001) this.sheetLine = null;
    this.extra.textContent = this.sheetLine || '';
    this.extra.style.display = this.sheetLine ? '' : 'none';
    this.trackerAlpha += Math.sign(trackerTarget - this.trackerAlpha) *
      Math.min(Math.abs(trackerTarget - this.trackerAlpha), dt * (trackerTarget > this.trackerAlpha ? FADE_IN : FADE_OUT));
    this.tracker.style.opacity = String(this.trackerAlpha);
    this.tracker.style.display = this.trackerAlpha > 0.001 ? '' : 'none';
    this.tracker.style.pointerEvents = this.trackerAlpha > 0.5 && this.scan.inLobby ? 'auto' : 'none';

    // the lobby's marker over its current step
    const target = this.scan.target;
    const mTarget = canShow && target && this.scan.inLobby ? 1 : 0;
    this.markerAlpha += Math.sign(mTarget - this.markerAlpha) * Math.min(Math.abs(mTarget - this.markerAlpha), dt * FADE_IN);
    if (this.markerAlpha > 0.001 && target) {
      const kind = lobby ? lobby.target : null;
      this.marker.place(env, target, {
        label: S(kind === 'Bus' ? 'Objective.Marker.Bus' : 'Objective.Marker.Pad'),
        metres: Math.floor(target.distanceTo(env.rootPosition(_root)) * STUDS_TO_METERS + 0.5),
        alpha: this.markerAlpha, pulse: Math.sin(this.clock * 3), lift: MARKER_LIFT + Math.sin(this.clock * 2.2) * 0.35,
      });
    } else this.marker.hide();
  }
}

const _root = new THREE.Vector3();
const _p = new THREE.Vector3();
const _local = new THREE.Vector3();
const _inv = new THREE.Matrix4();
