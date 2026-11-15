// prologue.js: the short prologue on the Back Lot (docs/design/game-spec-v2.md 4.1; match phase Prologue; I13), from
// the opening's hand-over to the Basement.
//
//   1. Out of the bin. Each player is in their own bin (a bin per slot: BinStart slot + 1), hidden and held, looking out
//      of the lid's gap. "Push the lid" (the bin's PushLid prompt, hold LidHold) plays a ClimbOut-second climb-out over
//      the front rim to the bin's ClimbOut spot; after AutoClimbOut seconds in the bin it happens by itself.
//   2. The lot at night: rain, the red strobe, the gate chained, the shutter down. The way on is the coal-chute hatch.
//   3. The chute. "Climb in" (the hatch's ClimbIn prompt, hold ClimbHold, inside the ChuteHatch trigger) puts that
//      player into a black wait ("You slide into the dark…"). When every Alive player is in, ChuteWait seconds after
//      the first, or MaxSeconds after the hand-over (CinematicTracks.chuteCutAt), everyone gets the same ChuteCut-second
//      cut: long fingers push the hatch shut, a bolt drops; anyone still outside is placed in it.
//   4. Landing. The run advances (game.advance: the phase turns InRun and the Basement activates); the squad stands at
//      its spawn in the delivery bay by the chute's mouth. The run clock starts there (match.js).
// No hiding rules, no noise and no monster in the lot: the phase is not live (no damage, no noise, no catch) and the
// Creature waits hidden and Dormant at its Basement spawn. A joiner during the prologue starts in their own bin.
// Authority (I7): alone this page; in a squad the host counts who is in the chute ({t: 'climbIn'}) and calls the cut
// ({t: 'chuteCut'}); each page's climb-out is its own (its lid is shown on every page: {t: 'lid'}).

import * as THREE from 'three';
import { S } from '../strings/index.js';
import '../strings/story.js';
import { Fonts, Palette, el } from '../ui/style.js';
import { inVolume } from '../util.js';

const STAGE = 'BackLot';
const LOCK = 'Prologue';
const CAMERA_TOKEN = 'Prologue';
const CAMERA_PRIORITY = 4;
const ROOT = 3;
const STAND_EYE = 1.5;
/** the eye in a bin: at the lid's gap, just over the front wall (from the bin's PromptPoint, h - 0.6 up, 0.6 in) */
const GAP_EYE = new THREE.Vector3(0, 0.72, -0.1);
const HATCH_OPEN = (100 * Math.PI) / 180;
/** how far round the ChuteHatch trigger "Climb in" still answers (the prompt reaches a little past the box) */
const HATCH_REACH = 3;

const _m = new THREE.Matrix4();
const _q = new THREE.Quaternion();
const _e = new THREE.Euler();
const _v = new THREE.Vector3();

const isNumber = (v) => typeof v === 'number' && Number.isFinite(v);

export class Prologue {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Prologue';
    this.game = game;
    this.env = game.env;
    const meta = game.world.meta;
    this.p = meta.storyConfig ? meta.storyConfig.Prologue : null;
    /** BinStart anchors and bin entities by slot (1..4) */
    this.starts = new Map();
    for (const a of meta.anchors || []) if (a.kind === 'BinStart') this.starts.set(Number(a.attributes && a.attributes.Slot), a);
    this.bins = new Map();
    for (const e of meta.entities || []) if (e.type === 'Bin' && e.attributes && e.attributes.Slot) this.bins.set(Number(e.attributes.Slot), e);
    this.hatch = (meta.entities || []).find((e) => e.id === 'ChuteHatch') || null;
    this.trigger = (meta.triggers || []).find((t) => t.kind === 'ChuteHatch') || null;
    this.inside = (meta.anchors || []).find((a) => a.id === 'BL_Mark_HatchInside') || null;
    this.hatchMark = (meta.anchors || []).find((a) => a.id === 'BL_Mark_Hatch') || null;
    /** @type {null|'Bin'|'Climbing'|'Lot'|'Chute'|'Cut'} this page's player */
    this.state = null;
    this.slot = 1;
    this.handOver = null;
    this.climbAt = null;
    this.cutAt = null;
    this.lidPrompt = null;
    this.climbPrompt = null;
    /** authority: who is in the chute (member ids; '' alone) and when the first went in; the cut called */
    this.inChute = new Set();
    this.firstIn = null;
    this.cutCalled = false;
    this.camera = { position: new THREE.Vector3(), quaternion: new THREE.Quaternion() };
    /** teammates' lids open while they climb out, shut at `at` */
    this.lidCloses = [];
    this.tally = null;
    this.rain = null;
    this.hatchOpen = 0;
    this.hatchTarget = 0;
    this._buildUi();
  }

  _buildUi() {
    this.ui = el('div', 'rg-layer', this.env.uiRoot());
    Object.assign(this.ui.style, { zIndex: '39', background: '#000', opacity: '0', display: 'none', alignItems: 'center',
      justifyContent: 'center', flexDirection: 'column', gap: '10px' });
    this.line = el('div', 'rg-title rg-outline', this.ui, '');
    Object.assign(this.line.style, { fontFamily: Fonts.Title, fontSize: 'clamp(18px, 2.6vw, 26px)', color: Palette.Bone });
    this.count = el('div', 'rg-caps', this.ui, '');
    this.count.style.color = Palette.Ash;
  }

  coop() {
    const c = this.game.coop;
    return c && c.active ? c : null;
  }

  /** Whether this page's run is in the prologue (I13's safe moment). */
  active() {
    return this.state !== null;
  }

  // ---------------------------------------------------------------------------------------------------- the bin

  /** This page's player into its own bin (the deploy's placement), hidden and held, looking out of the gap. */
  enterBin() {
    const coop = this.coop();
    this.slot = (coop && coop.me ? coop.me.slot : this.game.run ? this.game.run.slot : 0) + 1;
    const start = this.starts.get(this.slot) || this.starts.get(1);
    if (!start) return;
    const c = start.cframe;
    this.env.teleport([c[0], c[1] + ROOT, c[2], ...c.slice(3)]);
    this.env.setLook(0, -0.05);
    this.env.pushOverride(LOCK, 'Hiding');
    this.game.lock(LOCK);
    this.state = 'Bin';
    this.handOver = null;
    this.climbAt = null;
  }

  /** The hand-over: the prologue starts on this page (its bin's prompt, the 20 s, the rain). */
  begin() {
    if (this.state === null) this.enterBin();
    const now = this.env.now();
    this.handOver = now;
    this.climbAt = this.game.cinematics.tracks.climbOutAt(now);
    this.inChute.clear();
    this.firstIn = null;
    this.cutCalled = false;
    this.cutAt = null;
    this.hatchOpen = 0;
    this.hatchTarget = 0;
    if (!this.rain) this.rain = this.env.play('Rain', { loop: true, fadeIn: 1.5 });
    const bin = this.bins.get(this.slot);
    const spec = bin ? bin.prompts.find((p) => p.attributes && p.attributes.PromptKind === 'PushLid') : null;
    if (bin && !this.lidPrompt) {
      this.lidPrompt = this.env.addPrompt({ entity: bin.id, attachment: spec ? spec.host : 'PromptPoint',
        text: S('Prologue.PushLid'), objectText: S('Prompt.Bin'), holdSeconds: this.p.LidHold, distance: 8,
        requiresLineOfSight: false, anyFacing: true, net: 'local', onTriggered: () => this.climbOut() });
    }
    this.env.setHudVisible(true, 0.4);
  }

  /** Out over the front rim (by the prompt, or by itself at AutoClimbOut). */
  climbOut() {
    if (this.state !== 'Bin' || this.handOver === null) return;
    this.state = 'Climbing';
    const now = this.env.now();
    this.climbStart = now;
    this.climbEnd = now + this.p.ClimbOut;
    if (this.lidPrompt) this.lidPrompt.setEnabled(false);
    this.game.opening.lid(this.slot, true);
    this.env.play('LidCreak', { position: this._binTop(_v.clone()) });
    const coop = this.coop();
    if (coop && coop.isClient()) coop.toHost({ t: 'lidUp', s: this.slot });
    else if (coop) coop.broadcast({ t: 'lid', s: this.slot });
  }

  _binTop(out) {
    const start = this.starts.get(this.slot);
    return out.set(start.cframe[0], start.cframe[1] + 4, start.cframe[2]);
  }

  /** The eye inside this page's bin: at its lid's gap, looking out over the front wall. */
  _binEye(out) {
    const bin = this.bins.get(this.slot);
    const at = bin ? this.env.attachmentWorld(bin.id, 'PromptPoint') : null;
    if (at) return out.setFromMatrixPosition(at).add(GAP_EYE);
    return this._binTop(out).add(new THREE.Vector3(0, 0.2, -1.4));
  }

  _climbOutSpot(out) {
    const bin = this.bins.get(this.slot);
    const at = bin ? this.env.attachmentWorld(bin.id, 'ClimbOut') : null;
    if (at) return out.setFromMatrixPosition(at);
    const start = this.starts.get(this.slot);
    return out.set(start.cframe[0], start.cframe[1] - 0.5, start.cframe[2] - 4);
  }

  _onLot() {
    const spot = this._climbOutSpot(_v.clone());
    // facing the facade (the hatch is that way)
    this.env.teleport([spot.x, spot.y + ROOT, spot.z, 1, 0, 0, 0, 1, 0, 0, 0, 1]);
    this.env.popOverride(LOCK);
    this.game.unlock(LOCK);
    this.state = 'Lot';
    this.game.opening.lid(this.slot, false);
    if (this.hatch && !this.climbPrompt) {
      this.climbPrompt = this.env.addPrompt({ entity: this.hatch.id, attachment: 'ClimbIn', text: S('Prologue.ClimbIn'),
        objectText: S('Prompt.Chute'), holdSeconds: this.p.ClimbHold, distance: 8, requiresLineOfSight: false, net: 'local',
        onTriggered: () => this.climbIn() });
    }
    this.env.hint(S('Prologue.Find'), 4);
  }

  // ---------------------------------------------------------------------------------------------------- the chute

  /** Whether this page's player stands at the hatch (inside its ChuteHatch trigger). */
  atHatch() {
    if (!this.trigger) return true;
    const root = this.env.rootPosition(new THREE.Vector3());
    const feet = root.clone();
    feet.y -= ROOT;
    return inVolume(this.trigger.cframe, this.trigger.size, root, HATCH_REACH) ||
      inVolume(this.trigger.cframe, this.trigger.size, feet, HATCH_REACH);
  }

  /** "Climb in": into the black wait; the authority counts it. */
  climbIn() {
    if (this.state !== 'Lot' || !this.atHatch()) return;
    this._intoChute();
    const coop = this.coop();
    if (coop && coop.isClient()) coop.toHost({ t: 'climbIn' });
    else this._counted(coop ? coop.localId : '');
  }

  _intoChute() {
    this.state = 'Chute';
    if (this.climbPrompt) this.climbPrompt.setEnabled(false);
    if (this.inside) {
      const c = this.inside.cframe;
      this.env.teleport([c[0], c[1] + ROOT, c[2], ...c.slice(3)]);
    }
    this.env.pushOverride(LOCK, 'Hiding');
    this.game.lock(LOCK);
    this.hatchTarget = 1;
    this.env.play('ChuteSlide');
    this.line.textContent = S('Prologue.Dark');
  }

  /** Authority: `id` is in the chute; the cut when everyone Alive is. */
  _counted(id) {
    if (this.handOver === null || this.cutCalled) return;
    this.inChute.add(id);
    if (this.firstIn === null) this.firstIn = this.env.now();
    this._tally();
  }

  /** Authority: the members who must be in (everyone Alive in the squad, or this page's player). */
  _expected() {
    const coop = this.coop();
    if (!coop) return [''];
    return coop.participants().filter((m) => (m.local ? this.game.life.state : m.life) === 'Alive').map((m) => m.id);
  }

  _tally() {
    const expected = this._expected();
    const n = expected.filter((id) => this.inChute.has(id)).length;
    this.tally = { n, of: expected.length };
    const coop = this.coop();
    if (coop && coop.isHost()) coop.broadcast({ t: 'chuteIn', n, of: expected.length });
  }

  /** Authority, on the tick: the cut's moment (CinematicTracks.chuteCutAt). */
  _authority(now) {
    if (this.handOver === null || this.cutCalled) return;
    const expected = this._expected();
    const allIn = expected.length > 0 && expected.every((id) => this.inChute.has(id));
    const due = this.game.cinematics.tracks.chuteCutAt(this.handOver, this.firstIn ?? -1, allIn ? now : -1);
    if (now < due - 1e-6) return;
    this.cutCalled = true;
    const coop = this.coop();
    if (coop && coop.isHost()) coop.broadcast({ t: 'chuteCut' });
    this.playCut();
  }

  /** The cut every page plays: the hatch pushed shut, the bolt; then (the authority) on to the Basement. */
  playCut() {
    if (this.state === 'Cut') return;
    if (this.state === 'Bin' || this.state === 'Climbing' || this.state === 'Lot') {
      // still outside: placed in it
      if (this.state !== 'Lot') {
        this.env.popOverride(LOCK);
        this.game.unlock(LOCK);
      }
      this._intoChute();
    }
    this.state = 'Cut';
    const now = this.env.now();
    this.cutAt = now;
    this.cutEnd = now + this.p.ChuteCut;
    this.boltAt = now + this.p.ChuteCut * 0.72;
    this.bolted = false;
    this.hatchTarget = 0;
    if (this.lidPrompt) this.lidPrompt.setEnabled(false);
    if (this.climbPrompt) this.climbPrompt.setEnabled(false);
  }

  _finish() {
    const g = this.game;
    const coop = this.coop();
    if (coop && coop.isClient()) return;
    if (coop) coop.runNet.stageDone(STAGE);
    else g.advance();
  }

  // ---------------------------------------------------------------------------------------------------- drive

  tick(dt, now) {
    for (let i = this.lidCloses.length - 1; i >= 0; i--) {
      if (now < this.lidCloses[i].at) continue;
      this.game.opening.lid(this.lidCloses[i].slot, false);
      this.lidCloses.splice(i, 1);
    }
    if (this.state === null || this.game.cinematics.active()) return;
    if (this.state === 'Bin' && this.climbAt !== null && now >= this.climbAt - 1e-6) this.climbOut();
    if (this.state === 'Climbing' && now >= this.climbEnd - 1e-6) this._onLot();
    if (this.state === 'Cut') {
      if (!this.bolted && now >= this.boltAt) {
        this.bolted = true;
        if (this.hatchMark) this.env.play('BoltDrop', { position: new THREE.Vector3(...this.hatchMark.cframe.slice(0, 3)) });
      }
      if (now >= this.cutEnd - 1e-6 && !this.finished) {
        this.finished = true;
        this._finish();
      }
      return;
    }
    const coop = this.coop();
    if (!coop || coop.isHost()) this._authority(now);
  }

  frame(dt) {
    const s = this.state;
    if (s === null) return;
    const cin = this.game.cinematics;
    // the hatch's doors
    this.hatchOpen += Math.sign(this.hatchTarget - this.hatchOpen) * Math.min(Math.abs(this.hatchTarget - this.hatchOpen),
      dt / (this.hatchTarget > this.hatchOpen ? 0.5 : 0.35));
    if (this.hatch) {
      const a = this.hatchOpen * HATCH_OPEN;
      this.env.setNodeTransform(this.hatch.id, 'DoorL', _m.makeRotationZ(a));
      this.env.setNodeTransform(this.hatch.id, 'DoorR', _m.makeRotationZ(-a));
    }
    // a cutscene's own shots (the opening's S15: first person inside your bin) see from the bin too
    if (cin.active() && !(s === 'Bin' && cin.view() === 'Own')) {
      this.env.setCameraOverride(CAMERA_TOKEN, null);
      return;
    }
    const now = this.env.renderNow();
    if (s === 'Bin' || s === 'Climbing') {
      const top = this._binTop(new THREE.Vector3());
      const inside = this._binEye(new THREE.Vector3());
      const look = this.env.look();
      _q.setFromEuler(_e.set(look.pitch, look.yaw, 0, 'YXZ'));
      let position = inside;
      if (s === 'Climbing') {
        const u = Math.min(1, Math.max(0, (now - this.climbStart) / this.p.ClimbOut));
        const out = this._climbOutSpot(new THREE.Vector3());
        out.y += ROOT + STAND_EYE;
        const rim = new THREE.Vector3((inside.x + out.x) / 2, top.y + 1.1, (inside.z + out.z) / 2);
        position = u < 0.55 ? inside.clone().lerp(rim, smooth(u / 0.55)) : rim.clone().lerp(out, smooth((u - 0.55) / 0.45));
      }
      this.camera.position.copy(position);
      this.camera.quaternion.copy(_q);
      this.env.setCameraOverride(CAMERA_TOKEN, () => ({ position: this.camera.position, quaternion: this.camera.quaternion }),
        { priority: CAMERA_PRIORITY, blendIn: 0, blendOut: 0 });
    } else if (s === 'Cut' && this.hatchMark) {
      const h = this.hatchMark.cframe;
      this.camera.position.set(h[0] + 3, h[1] + 4.2, h[2] + 9);
      const target = new THREE.Vector3(h[0], h[1] + 0.6, h[2] - 3);
      this.env.setCameraOverride(CAMERA_TOKEN, () => ({ position: this.camera.position, lookAt: target }),
        { priority: CAMERA_PRIORITY, blendIn: 0, blendOut: 0 });
    } else this.env.setCameraOverride(CAMERA_TOKEN, null);
    // the chute's black wait (the cut shows the hatch through it)
    const black = s === 'Chute' ? 1 : s === 'Cut' ? (now < this.cutEnd - 0.25 ? 0 : 1) : 0;
    this.ui.style.display = black > 0 ? 'flex' : 'none';
    this.ui.style.opacity = String(black);
    const t = this.tally;
    this.count.textContent = s === 'Chute' && t && t.of > 1 ? S('Prologue.Waiting', t.n, t.of) : '';
  }

  // ---------------------------------------------------------------------------------------------------- stages

  stageDeactivated(stage) {
    if (stage === STAGE) this._clear();
  }

  endRun() {
    this._clear();
  }

  _clear() {
    if (this.state === null && !this.lidPrompt && !this.climbPrompt) return;
    if (this.state === 'Bin' || this.state === 'Climbing' || this.state === 'Chute' || this.state === 'Cut') {
      this.env.popOverride(LOCK);
      this.game.unlock(LOCK);
    }
    this.state = null;
    this.finished = false;
    this.handOver = null;
    if (this.lidPrompt) this.lidPrompt.remove();
    if (this.climbPrompt) this.climbPrompt.remove();
    this.lidPrompt = null;
    this.climbPrompt = null;
    if (this.rain) this.rain.stop(2);
    this.rain = null;
    this.tally = null;
    this.lidCloses.length = 0;
    this.env.setCameraOverride(CAMERA_TOKEN, null);
    this.ui.style.display = 'none';
    this.hatchOpen = 0;
    this.hatchTarget = 0;
    if (this.hatch) {
      this.env.setNodeTransform(this.hatch.id, 'DoorL', _m.identity());
      this.env.setNodeTransform(this.hatch.id, 'DoorR', _m.identity());
    }
  }

  // ---------------------------------------------------------------------------------------------------- co-op

  bindCoop(coop) {
    const ev = coop.events;
    ev.register('climbIn', { to: 'host', phases: ['Prologue'], life: ['Alive'], rate: 2,
      handle: (from) => this._counted(from) });
    ev.register('chuteIn', { to: 'client', phases: ['Prologue'], validate: (m) => isNumber(m.n) && isNumber(m.of),
      handle: (from, m) => {
        this.tally = { n: m.n, of: m.of };
      } });
    ev.register('chuteCut', { to: 'client', phases: ['Prologue'], handle: () => this.playCut() });
    ev.register('lidUp', { to: 'host', phases: ['Prologue'], rate: 2, validate: (m) => isNumber(m.s) && m.s >= 1 && m.s <= 4,
      handle: (from, m) => coop.broadcast({ t: 'lid', s: m.s }) });
    ev.register('lid', { to: 'client', phases: ['Prologue'], validate: (m) => isNumber(m.s) && m.s >= 1 && m.s <= 4,
      handle: (from, m) => {
        if (m.s === this.slot) return;
        this.game.opening.lid(m.s, true);
        this.env.play('LidCreak', { position: new THREE.Vector3(...this.starts.get(m.s).cframe.slice(0, 3)) });
        this.lidCloses.push({ slot: m.s, at: this.env.now() + this.p.ClimbOut });
      } });
    coop.addModule({
      welcome: (member, msg) => {
        if (this.handOver !== null && !this.cutCalled) msg.prologue = { el: this.env.now() - this.handOver };
      },
      welcomed: (msg) => {
        this.pendingJoin = msg.prologue || null;
      },
      memberLeft: () => {
        if (this.handOver !== null && !this.cutCalled) this._tally();
      },
    });
  }

  /** A joiner's page: into its own bin, the prologue from its own start (false when the squad is not in it). */
  joinPending() {
    const join = this.pendingJoin;
    this.pendingJoin = null;
    if (!join) return false;
    this.begin();
    return true;
  }
}

function smooth(u) {
  const v = Math.min(1, Math.max(0, u));
  return v * v * (3 - 2 * v);
}

