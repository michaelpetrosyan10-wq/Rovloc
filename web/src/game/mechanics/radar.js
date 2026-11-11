// radar.js: the radar (docs/design/game-spec-v2.md 3.2; RadarRules through rules/radar.js over world.json
// meta.radarConfig), the Tab hint's replacement. What a page's player holds and what a scan shows; ui/radar.js draws it.
//
//   Charges   personal: StartCharges at the run's start; reaching a sneaking stage of the difficulty's ArrivalFloor
//             with none gives one (RadarRules.arrival, at the stage's activation); a battery adds one up to MaxCharges
//             (mechanics/batteries.js).
//   A press   the Radar action (Tab, d-pad right, RADAR). RadarRules.refusal decides: Ok spends one charge and starts a
//             scan; Empty opens the objective sheet with a dry click and "Radar empty. Batteries blink."; anything
//             else (Hiding, Downed, dead, seated, a cutscene, the roof or the runway, a squad scan still live) is
//             refused without cost. Only in a live run.
//   A scan    a RaiseSeconds raise, then ScanSeconds of markers (RadarRules.scan). It shows, at exact positions through
//             walls, what RadarRules.targets picks from the level's objective (FloorObjectives.radarTargets: the open
//             step's items still needed and any dropped one, the open step's stations, the exit once unlocked) and
//             the batteries within DotRange of this page's player; never the Creature, never a teammate. A soft
//             RadarPing plays in 3D at the scanner when the markers come up (heard within PingRange); it is never a
//             noise the Creature hears.
//   Co-op     a scan is a squad event: a page asks the host ({t: 'radarAsk'}); the host refuses one while a squad
//             scan is live, else tells every page ({t: 'radar', by, in, s}: the scanner, the raise left, the scan's
//             seconds) and each shows it with its own markers and chevron; the scanner's page spends the charge on the
//             host's word. Alone, the page is the host.

import * as THREE from 'three';
import { Presets } from '../../engine/audio/presets.js';
import { isNumber } from '../coop/events.js';
import { radarRules } from '../rules/radar.js';
import { S } from '../strings/index.js';
import '../strings/kit.js';
import { Signal } from '../util.js';

const RUN_PHASES = ['Deploying', 'InRun'];
/** The game clock is a sum of 1/30 s ticks: a scan's times are met within this. */
const CLOCK_EPS = 1e-6;
const EQ = (LowGain, MidGain, HighGain) => ({ kind: 'Equalizer', props: { LowGain, MidGain, HighGain } });

/** The radar's sounds (spec 5.5): a soft two-tone ping (3D, heard within PingRange) and a dry relay click. */
function radarPresets(pingRange) {
  return {
    RadarPing: {
      bus: 'World', maxVoices: 2, priority: 40, rollOff: { min: 4, max: pingRange },
      layers: [
        { duration: 0.35, looped: true, sample: 'VolumeSlider', speed: 3.3, volume: 0.32,
          envelope: { attack: 0.005, hold: 0.06, release: 0.28 }, effects: [EQ(-20, 0, 2)] },
        { delay: 0.14, duration: 0.45, looped: true, sample: 'VolumeSlider', speed: 4.4, volume: 0.28,
          envelope: { attack: 0.005, hold: 0.06, release: 0.38 }, effects: [EQ(-20, 0, 2)] },
      ],
    },
    RadarEmpty: {
      bus: 'UI', maxVoices: 2, priority: 40,
      layers: [
        { sample: 'FootstepsPlastic', region: { min: 0, max: 0.05 }, speed: 2.6, volume: 0.5, effects: [EQ(-18, 4, -4)] },
        { delay: 0.03, sample: 'VolumeSlider', speed: 0.8, volume: 0.25, effects: [EQ(-6, 0, -12)] },
      ],
    },
  };
}

export class Radar {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Radar';
    this.game = game;
    this.env = game.env;
    this.rules = radarRules(game.world.meta);
    for (const [name, preset] of Object.entries(radarPresets(this.rules.config.PingRange))) {
      if (!Presets[name]) Presets[name] = preset;
    }
    this.difficulty = 'Standard';
    this.charges = 0;
    /** @type {{by: string, raiseAt: number, showAt: number, endsAt: number, pinged: boolean}|null} the squad's scan */
    this.scan = null;
    /** scans this page's player made this run, and the refusals of its presses (tests read them) */
    this.scans = 0;
    this.lastRefusal = null;
    /** @type {Signal<[number]>} the charges changed */
    this.changed = new Signal();
    /** @type {Signal<[string]>} a scan started (the scanner's member id; '' alone) */
    this.started = new Signal();
    this.env.onAction('Radar', (phase) => {
      if (phase === 'Begin') this.press();
    });
  }

  /** Co-op: the radar's messages (events.js: each with its rules). */
  bindCoop(coop) {
    this.coop = coop;
    coop.events.register('radarAsk', { to: 'host', phases: ['InRun'], life: ['Alive'], rate: 2,
      handle: (from) => this._hostScan(from) });
    coop.events.register('radar', { to: 'client', phases: RUN_PHASES,
      validate: (m) => typeof m.by === 'string' && isNumber(m.in) && isNumber(m.s) && m.in >= 0 && m.s > 0,
      handle: (from, m) => this._begin(m.by, m.in, m.s) });
  }

  _squad() {
    return !!(this.coop && this.coop.active);
  }

  _localId() {
    return this.coop && this.coop.active ? this.coop.localId : '';
  }

  // ---------------------------------------------------------------------------------------------------- run

  beginRun(run) {
    this.difficulty = run.difficulty;
    this.scan = null;
    this.scans = 0;
    this.lastRefusal = null;
    this._set(this.rules.startCharges(this.difficulty));
  }

  endRun() {
    this.scan = null;
  }

  stageActivated(stage) {
    this.scan = null;
    this._set(this.rules.arrival(this.difficulty, stage, this.charges));
  }

  _set(charges) {
    this.charges = charges;
    this.changed.fire(charges);
  }

  /** The charges held and the most a player holds. */
  max() {
    return this.rules.of(this.difficulty).MaxCharges;
  }

  /** A battery's +1 (to MaxCharges): mechanics/batteries.js, after RadarRules.battery took it. */
  setCharges(charges) {
    this._set(Math.max(0, Math.min(this.max(), charges)));
  }

  /** The tracker's line: RADAR 1/3. */
  chargesLine() {
    return S('Radar.Charges', this.charges, this.max());
  }

  /** Whether a squad scan is live (raising or showing). */
  live() {
    return !!this.scan && this.env.now() < this.scan.endsAt - CLOCK_EPS;
  }

  /** Whether the markers show now (past the raise). */
  showing() {
    return this.live() && this.env.now() >= this.scan.showAt - CLOCK_EPS;
  }

  // ---------------------------------------------------------------------------------------------------- the press

  /** The question RadarRules.refusal answers for this page's player now. */
  asker() {
    const g = this.game;
    return {
      charges: this.charges,
      lifeState: g.life.state,
      moveState: this.env.moveState(),
      cutscene: this.env.context() === 'Cutscene' || g.controlLock() === 'Cutscene',
      stage: g.stage || '',
      squadScanLive: this.live(),
    };
  }

  /** The Radar action: a scan, the empty sheet, or a refusal at no cost. Returns the refusal (Ok when it scanned). */
  press() {
    const g = this.game;
    if (!g.run || g.phase !== 'InRun') return null;
    const why = this.rules.refusal(this.asker());
    this.lastRefusal = why;
    if (why === 'Empty') {
      this.env.play('RadarEmpty');
      if (g.objectives) g.objectives.openSheet(S('Radar.Empty'));
      return why;
    }
    if (why !== 'Ok') return why;
    if (this._squad() && this.coop.isClient()) this.coop.toHost({ t: 'radarAsk' });
    else this._hostScan(this._localId());
    return why;
  }

  /** Host (or alone): a scan asked by member `by`, refused while one is live, else started on every page. */
  _hostScan(by) {
    if (this.live() || this.rules.config.NoScanStages.includes(this.game.stage)) return;
    const timing = this.rules.scan(this.difficulty, 1, 0);
    if (this._squad()) this.coop.everyone({ t: 'radar', by, in: timing.showAt, s: timing.endsAt - timing.showAt });
    else this._begin(by, timing.showAt, timing.endsAt - timing.showAt);
  }

  /** Every page: the squad's scan by `by`, its markers from `raise` seconds from now for `seconds`. */
  _begin(by, raise, seconds) {
    const now = this.env.now();
    this.scan = { by, raiseAt: now, showAt: now + raise, endsAt: now + raise + seconds, pinged: false };
    if (by === this._localId()) {
      this._set(this.rules.scan(this.difficulty, this.charges, now).charges);
      this.scans++;
    }
    this.started.fire(by);
  }

  /** Where the scanner stands (this page's player, or a teammate's last pose), or null. */
  _scannerAt(by) {
    if (by === this._localId()) return this.env.rootPosition(new THREE.Vector3());
    const m = this.coop ? this.coop.squad.get(by) : null;
    return m && m.pose ? new THREE.Vector3(m.pose.x, m.pose.y, m.pose.z) : null;
  }

  tick() {
    const s = this.scan;
    if (s && !s.pinged && this.env.now() >= s.showAt - CLOCK_EPS) {
      s.pinged = true;
      const at = this._scannerAt(s.by);
      if (at) this.game.playAt('RadarPing', at);
    }
  }

  // ---------------------------------------------------------------------------------------------------- what a scan shows

  /**
   * What the live scan shows this page now: [{kind, id, point, name}] (RadarRules.targets over the level's objective
   * and the batteries within DotRange of this page's player), or [] without a scan showing.
   */
  targets() {
    const g = this.game;
    if (!this.showing() || !g.level) return [];
    const view = g.floors ? g.floors.radarTargets(g.level) : null;
    const root = this.env.rootPosition(_root);
    const batteries = g.batteries ? g.batteries.live(g.level) : [];
    const points = new Map();
    const items = [];
    const stations = [];
    if (view) {
      for (const it of view.items) {
        points.set(it.id, it);
        items.push({ id: it.id, step: it.step, carried: it.carried, dropped: it.dropped });
      }
      for (const st of view.stations) {
        points.set(st.id, st);
        stations.push({ id: st.id, step: st.step, done: st.done });
      }
      if (view.exit) points.set(view.exit.id, view.exit);
    }
    for (const b of batteries) points.set(b.id, { point: b.point, name: S('Radar.Marker.Battery') });
    const picked = this.rules.targets({
      openStep: view ? view.openStep : '',
      items,
      stations,
      exit: view && view.exit ? { id: view.exit.id, unlocked: view.exit.unlocked } : { id: '', unlocked: false },
      batteries: batteries.map((b) => ({ id: b.id, distance: b.point.distanceTo(root) })),
    });
    return picked.map((t) => ({ kind: t.kind, id: t.id, point: points.get(t.id).point, name: points.get(t.id).name }));
  }
}

const _root = new THREE.Vector3();
