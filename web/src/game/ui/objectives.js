// objectives.js: what to do next, always one glance away (ObjectiveTracker).
//
//   Tracker   a compact sheet top-left (top-right on touch): OBJECTIVE, the goal, the floor's tip, the key that asks
//             for directions. Fully shown when the goal changes or the Objective action is pressed (Tab / d-pad
//             right / GOAL), fading after TrackerHold seconds idle; in the lobby it stays, with the optional lines
//             (vote, perks) ticking off and a HOW TO PLAY button (H / d-pad left / tap) that replays the walkthrough.
//   Goals     lobby: the bus -> a pad -> waiting -> the countdown; every floor: its objective (the title and each step
//             with its count, done steps ticked, the current one marked; a running countdown keeps the sheet up) until
//             its exit unlocks, then "Get to the <compass> stairwell" (the run's route); once its doors count down get
//             in (or hold it from inside); Floor 1 after the gate slams: a vent around it, crawl through (as the tip);
//             the roof after the crate is cut: run for the parachutes once the door is smashed, the gap with a pack on,
//             the cord, landed.
//   Marker    a floating diamond over the lobby's current step (the bus's rear door, then the nearest free pad).
//   Directions the Objective action shows a chevron around the crosshair at the goal with its distance and the marker
//             over it for DirectionShow seconds, then cools down for DirectionCooldown. On an objective floor it points
//             at the ROOM of the nearest undone step's target (its centre, or its doorway nearest you; labelled with the
//             room's name), never at the item; it is first available NudgeDelay after arriving and cools down for
//             NudgeCooldown.
//   Floor card FLOOR 1 / MAIN HALLWAYS / OBJECTIVE: <the floor's objective> in the centre-top on each new level, held
//             while the HUD is hidden (up to FloorCardWait seconds).
// Hidden while the HUD is hidden, in the Cutscene / Menu contexts, under a Cutscene / Jumpscare lock, while the
// onboarding screens are up and while the player is not Alive on a level.

import * as THREE from 'three';
import { TutorialConfig } from '../config.js';
import { S } from '../strings.js';
import { cfPos } from '../util.js';
import { glyphFor } from './nav.js';
import { ObjectiveTuning } from '../objectives/config.js';
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

/** ObjectiveTracker.levelObjective */
export function levelObjective(input) {
  const floor = TutorialConfig.Floors[input.level];
  if (!floor) return null;
  const tip = floor.tip;
  if (input.airlock !== 'None') {
    if (input.insideAirlock) return { text: 'Objective.Airlock.Wait', tip: null, target: null };
    return { text: 'Objective.Airlock.Get', tip: null, target: 'Exit' };
  }
  if (input.level === 'Level5_Roof') {
    const p = input.parachute;
    if (p === 'Landed') return { text: 'Objective.Roof.Landed', tip: null, target: null };
    if (p === 'Freefall') return { text: 'Objective.Roof.Cord', tip: null, target: null };
    if (p === 'Canopy') return null;
    if (p === 'Packed') return { text: 'Objective.Roof.Jump', tip: null, target: 'Gap' };
    if (input.roofDoor === 'Smashed') return { text: 'Objective.Roof.Run', tip, target: 'Crate' };
    if (input.onRoof) return { text: 'Objective.Roof.Search', tip, target: 'Crate' };
    return { text: 'Objective.Roof.Out', tip, target: 'RoofDoor' };
  }
  if (input.level === 'Level1_Hallways' && input.gateSlammed && !input.beyondGate) {
    if (input.inVent) return { text: 'Objective.GateVent', tip: null, target: null };
    return { text: 'Objective.Gate', tip, target: 'BypassVent' };
  }
  if (input.level === 'Level4_FloodedPool') return { text: 'Objective.PoolStairs', tip, target: 'Exit' };
  return { text: `Objective.Stairwell.${floor.stairwell || 'East'}`, tip, target: 'Exit' };
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

export class Objectives {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Objectives';
    this.game = game;
    this.env = game.env;
    this.clock = 0;
    this.scannedAt = -Infinity;
    this.activeAt = -Infinity;
    this.directionAt = -Infinity;
    this.lastText = null;
    this.trackerAlpha = 0;
    this.cardAlpha = 0;
    this.pointerAlpha = 0;
    this.markerAlpha = 0;
    this.cardLevel = null;
    this.cardDueAt = -Infinity;
    this.cardStartedAt = null;
    this.shownLevel = null;
    this.scan = { objective: null, lobby: null, target: null, inLobby: false };
    this._build();
    this.env.onAction('Objective', (phase) => this._objective(phase));
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
    // pointer (direction nudge)
    this.pointer = el('div', 'rg-layer', this.layer);
    this.arrow = el('div', '', this.pointer);
    Object.assign(this.arrow.style, { position: 'absolute', width: '0', height: '0', borderLeft: '9px solid transparent',
      borderRight: '9px solid transparent', borderBottom: `16px solid ${Palette.Bone}`, transformOrigin: '50% 60%' });
    this.pointerLabel = el('div', 'rg-caps rg-outline', this.pointer, '');
    Object.assign(this.pointerLabel.style, { position: 'absolute', transform: 'translate(-50%, -50%)', color: Palette.Bone });
    this.pointer.style.opacity = '0';
    // marker
    this.marker = el('div', '', this.layer);
    Object.assign(this.marker.style, { position: 'absolute', transform: 'translate(-50%, -100%)', textAlign: 'center',
      opacity: '0', pointerEvents: 'none' });
    this.markerLabel = el('div', 'rg-caps rg-outline', this.marker, '');
    Object.assign(this.markerLabel.style, { color: Palette.Amber, fontSize: '13px' });
    this.markerDistance = el('div', 'rg-caps rg-outline', this.marker, '');
    this.diamond = el('div', '', this.marker);
    Object.assign(this.diamond.style, { width: '14px', height: '14px', margin: '4px auto 0', transform: 'rotate(45deg)',
      border: `2px solid ${Palette.Amber}`, background: 'rgba(204,158,88,0.35)' });
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

  _objective(phase) {
    if (phase !== 'Begin' || !this._allowed()) return;
    this.activeAt = this.clock;
    const timing = this._nudgeTiming();
    if (timing.wait <= 0 && this.clock - this.directionAt >= timing.cooldown && this.scan.target) {
      this.directionAt = this.clock;
      this.env.play('UiClick');
    }
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
    const roofDoor = level === 'Level5_Roof' ? g.doors.find(level, 'RoofStairDoor') : null;
    const zone = g.world.roomAt(root, level);
    const airlock = g.airlock;
    const airlockState = airlock.level === level && airlock.deadline !== null ? (airlock.phase === 'Sealing' ? 'Sealing' : 'Waiting') : 'None';
    const parachute = g.parachute ? g.parachute.state : 'None';
    const objective = levelObjective({
      level,
      airlock: airlockState,
      insideAirlock: airlock.inside,
      gateSlammed: !!gate && (gate.state === 'Locked' || gate.state === 'Closed'),
      beyondGate: !!(gatePoint && exitPoint && beyond(gatePoint, exitPoint, root, BEYOND_MARGIN)),
      inVent: VENT_STATES.has(this.env.moveState()),
      roofDoor: roofDoor ? roofDoor.state : null,
      onRoof: !!zone && zone.id !== 'L5_RoofAccess' && !(g.parachute && g.parachute.inTower(root)),
      parachute,
    });
    this.scan.lobby = null;
    this.scan.inLobby = false;
    this.scan.label = null;
    this.scan.steps = null;
    this.scan.title = null;
    this.scan.floorNudge = null;
    // the floor objective: its title and steps until the exit unlocks, then the way to the stairwell
    const floor = g.floors ? g.floors.tracker(level) : null;
    if (floor && objective && airlockState === 'None') {
      this.scan.steps = floor.steps;
      if (!floor.unlocked) {
        this.scan.title = floor.title;
        const context = objective.text === 'Objective.Gate' || objective.text === 'Objective.GateVent' ? objective.text : null;
        objective.tip = context || objective.tip;
        if (!context) {
          objective.target = 'Floor';
          const nudge = g.floors.nudge(level, root);
          this.scan.floorNudge = nudge;
        }
      } else if (floor.exit) {
        this.scan.title = floor.exit;
        objective.target = 'Exit';
      }
    }
    this.scan.objective = objective;
    let target = null;
    const kind = objective ? objective.target : null;
    if (kind === 'Floor' && this.scan.floorNudge) {
      target = this.scan.floorNudge.point;
      this.scan.label = this.scan.floorNudge.label;
    }
    if (kind === 'Exit') target = exitPoint;
    else if (kind === 'BypassVent') {
      const grates = g.world.entities('VentGrate', level).filter((e) => e.attributes.CriticalPath).map((e) => cfPos(e.pivot));
      const near = grates.filter((p) => !(gatePoint && exitPoint && beyond(gatePoint, exitPoint, p, BEYOND_MARGIN)));
      target = nearest(near.length ? near : grates, root);
    } else if (kind === 'RoofDoor' && roofDoor) target = roofDoor.centre;
    else if (kind === 'Crate' && g.parachute) target = g.parachute.freePackPoint(root);
    else if (kind === 'Gap' && g.parachute) target = g.parachute.gapCentre();
    this.scan.target = target;
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
    this.scan = { objective: null, lobby: null, target: null, inLobby: false, title: null, steps: null, label: null };
  }

  /** The nudge's cooldown and when it is first available on this floor (an objective floor waits NudgeDelay). */
  _nudgeTiming() {
    const g = this.game;
    const floor = g.floors && g.level && g.phase === 'InRun' ? g.floors.floor(g.level) : null;
    if (!floor || this.scan.inLobby) return { cooldown: T.DirectionCooldown, wait: 0 };
    const readyAt = g.floors.nudgeReadyAt(g.level, ObjectiveTuning.NudgeDelay);
    return { cooldown: ObjectiveTuning.NudgeCooldown, wait: Math.max(0, readyAt - g.env.now()) };
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
        if (floor) {
          this.cardTitle.textContent = S(floor.title);
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
    const stepKey = steps ? steps.map((s) => `${s.done ? 1 : 0}${s.active ? 1 : 0}${s.timed ? '' : s.text}`).join('|') : '';
    // a running countdown (the door motor) keeps the tracker up
    if (steps && steps.some((s) => s.timed && s.active)) this.activeAt = this.clock;
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
    const timing = this._nudgeTiming();
    const remaining = Math.max(timing.wait, timing.cooldown - (this.clock - this.directionAt));
    const ready = remaining <= 0;
    this.keyCap.textContent = glyphFor(env, 'Objective', device);
    this.keyLabel.textContent = ready ? S('Objective.Direction') : S('Objective.DirectionWait', Math.ceil(remaining));
    this.keyCap.style.display = this.scan.target ? '' : 'none';
    this.keyLabel.style.display = this.scan.target ? '' : 'none';
    let trackerTarget = 0;
    if (text && canShow) {
      if (this.scan.inLobby) trackerTarget = 1;
      else {
        const since = this.clock - this.activeAt;
        trackerTarget = since <= T.TrackerHold ? 1 : Math.max(0, 1 - (since - T.TrackerHold) / T.TrackerFade);
      }
    }
    this.trackerAlpha += Math.sign(trackerTarget - this.trackerAlpha) *
      Math.min(Math.abs(trackerTarget - this.trackerAlpha), dt * (trackerTarget > this.trackerAlpha ? FADE_IN : FADE_OUT));
    this.tracker.style.opacity = String(this.trackerAlpha);
    this.tracker.style.display = this.trackerAlpha > 0.001 ? '' : 'none';
    this.tracker.style.pointerEvents = this.trackerAlpha > 0.5 && this.scan.inLobby ? 'auto' : 'none';

    // direction nudge + marker
    const target = this.scan.target;
    const nudging = canShow && target && this.clock - this.directionAt <= T.DirectionShow;
    const pTarget = nudging && !this.scan.inLobby ? 1 : 0;
    this.pointerAlpha += Math.sign(pTarget - this.pointerAlpha) * Math.min(Math.abs(pTarget - this.pointerAlpha), dt * FADE_IN);
    const root = env.rootPosition(_root);
    const distance = target ? target.distanceTo(root) : 0;
    const meters = Math.max(1, Math.floor(distance * STUDS_TO_METERS + 0.5));
    this.pointer.style.opacity = String(this.pointerAlpha);
    if (this.pointerAlpha > 0.001 && target) {
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
      this.pointerLabel.style.left = `${cx + x * 0.62}px`;
      this.pointerLabel.style.top = `${cy + y * 0.62}px`;
      const far = S('Objective.Distance', meters);
      this.pointerLabel.textContent = this.scan.label ? `${this.scan.label} · ${far}` : far;
    }
    let mTarget = 0;
    if (canShow && target) mTarget = this.scan.inLobby ? 1 : nudging ? 0.85 : 0;
    this.markerAlpha += Math.sign(mTarget - this.markerAlpha) * Math.min(Math.abs(mTarget - this.markerAlpha), dt * FADE_IN);
    if (this.markerAlpha > 0.001 && target) {
      _p.copy(target);
      _p.y += MARKER_LIFT + Math.sin(this.clock * 2.2) * 0.35;
      const s = env.project(_p);
      if (s) {
        this.marker.style.display = '';
        this.marker.style.left = `${s.x}px`;
        this.marker.style.top = `${s.y}px`;
        this.marker.style.opacity = String(this.markerAlpha);
        const kind = lobby ? lobby.target : objective ? objective.target : null;
        this.markerLabel.textContent = this.scan.label ? this.scan.label :
          S(kind === 'Bus' ? 'Objective.Marker.Bus' : kind === 'Pad' ? 'Objective.Marker.Pad' : 'Objective.Marker.Goal');
        this.markerDistance.textContent = S('Objective.Distance', meters);
        this.diamond.style.opacity = String(0.65 + 0.35 * Math.sin(this.clock * 3));
      } else this.marker.style.display = 'none';
    } else this.marker.style.display = 'none';
  }
}

const _root = new THREE.Vector3();
const _p = new THREE.Vector3();
const _local = new THREE.Vector3();
const _inv = new THREE.Matrix4();
