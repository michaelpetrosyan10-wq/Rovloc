// opening.js: the opening on the Back Lot (docs/design/game-spec-v2.md 2.4, 4.1): the Back Lot stage's first part.
//
// Deploying places the squad at the bin marks: each page's player in its slot's bin (BinStart, slot + 1), hidden in it
// and held (the prologue's bin state). Then the authority plays the Opening timeline (story/cinematics.js: Full the
// first time, 78.0 s; Short, 26.0 s, once every member has seen it and nobody asked for Full): the overcast day on the
// lot, the party walking out of the staff doors with Danny, the crawler, the latch at his face, the dark and the
// Tall Man unfolding where he stood, the run to the bins, the bin, the school going dark, the time cut to night, and
// first person inside your bin. At its end every page hands over to the prologue (story/prologue.js).
//
// The set pieces it moves (Prop events): the staff doors' lockdown Shutter (up by day, crashing down in S13), the
// school's two rows of windows (Windows1, Windows2: lit by day, dark floor by floor), each bin's Lid (opened and
// slammed as its actor dives in). The Creature (the Monster actor) is held by the authority while it plays and left
// hidden and Dormant at its Basement spawn at the end (4.1: no monster in the lot).

import * as THREE from 'three';

const SHUTTER_UP = 8.6;
const SHUTTER_DROP = 0.45;
const LID_OPEN = (70 * Math.PI) / 180;
const LID_SWING = 0.25;
const PANE_LIT = new THREE.Color(0.93, 0.95, 0.98);
const PANE_DARK = new THREE.Color(0.02, 0.022, 0.025);
const STAGE = 'BackLot';

const _m = new THREE.Matrix4();

export class Opening {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Opening';
    this.game = game;
    this.env = game.env;
    const meta = game.world.meta;
    /** bin entities by slot (1..4) */
    this.bins = new Map();
    for (const e of meta.entities || []) if (e.type === 'Bin' && e.attributes && e.attributes.Slot) this.bins.set(Number(e.attributes.Slot), e);
    this.shutter = (meta.entities || []).find((e) => e.id === 'Shutter') || null;
    /** the window glow panes (the facade's two rows of window lights, scripted groups BL_Windows_1 and _2) */
    this.windows = { Windows1: [], Windows2: [] };
    this.lit = new THREE.MeshBasicMaterial({ color: PANE_LIT });
    this.dark = new THREE.MeshBasicMaterial({ color: PANE_DARK });
    for (const l of meta.lights || []) {
      const row = l.flickerGroup === 'Scripted:BL_Windows_1' ? 'Windows1' : l.flickerGroup === 'Scripted:BL_Windows_2' ? 'Windows2' : null;
      if (!row || !l.fixtureCFrame) continue;
      const size = l.fixtureSize || [3.6, 6, 0.1];
      const pane = new THREE.Mesh(new THREE.PlaneGeometry(size[0] - 0.4, size[1] - 0.4), this.lit);
      // the pane faces the lot (+Z), just proud of the card
      pane.position.set(l.fixtureCFrame[0], l.fixtureCFrame[1], l.fixtureCFrame[2] + 0.04);
      pane.visible = false;
      this.windows[row].push(pane);
      this.env.addToScene(pane);
    }
    /** running tweens: the shutter, the lids */
    this.tweens = new Map();
  }

  /** Wires the scene's props into the cutscene player (start.js, once both exist). */
  bind(cinematics) {
    cinematics.onProp('Shutter', (state) => this._shutter(state));
    cinematics.onProp('Windows1', (state) => this._windows('Windows1', state));
    cinematics.onProp('Windows2', (state) => this._windows('Windows2', state));
    cinematics.onProp('Lid', (state, args) => {
      if (args.slot) this.lid(args.slot, state === 'Open');
    });
    // every page's opening hands over to its prologue at its end (the host's word started it on a client)
    cinematics.onEnded('Opening', (reason) => this._ended(reason));
  }

  // ---------------------------------------------------------------------------------------------------- the stage

  stageActivated(stage) {
    if (stage !== STAGE || this.game.stages.scriptOf(stage) !== 'Prologue') return;
    const g = this.game;
    const coop = g.coop && g.coop.active ? g.coop : null;
    g.prologue.enterBin();
    // a joiner gets the cutscene from where the squad is (cinematics: welcomed), or the prologue
    if (coop && coop.isClient()) {
      if (!g.cinematics.joinPending()) g.prologue.joinPending();
      return;
    }
    this.play();
  }

  /** Authority: the opening for everyone. */
  play() {
    const g = this.game;
    g.cinematics.play('Opening', { monsterRest: this._creatureRest() });
  }

  _ended(reason) {
    if (reason !== 'End') return;
    this.game.prologue.begin();
  }

  /** Where the Creature waits during the prologue: hidden, Dormant, at its first Basement spawn. */
  _creatureRest() {
    const spawn = (this.game.world.meta.anchors || []).find((a) => a.kind === 'CreatureSpawn' && a.level === 'Level0_Basement');
    return spawn ? spawn.cframe : null;
  }

  stageDeactivated(stage) {
    if (stage !== STAGE) return;
    this._reset();
  }

  endRun() {
    this._reset();
  }

  _reset() {
    for (const row of Object.values(this.windows)) for (const p of row) p.visible = false;
    this.tweens.clear();
    if (this.shutter) this.env.setEntityPivot(this.shutter.id, this.shutter.pivot);
    for (const slot of this.bins.keys()) this.lid(slot, false, true);
  }

  // ---------------------------------------------------------------------------------------------------- the props

  _shutter(state) {
    if (!this.shutter) return;
    const up = state === 'Up';
    this.tweens.set('Shutter', { from: up ? 0 : SHUTTER_UP, to: up ? SHUTTER_UP : 0, at: this.env.now(),
      seconds: up ? 0 : SHUTTER_DROP, apply: (v) => {
        const p = this.shutter.pivot.slice();
        p[1] += v;
        this.env.setEntityPivot(this.shutter.id, p);
      } });
  }

  /** A row of windows lit (the school's lights on) or dark (the lockdown): unlit panes over the cards. */
  _windows(row, state) {
    for (const p of this.windows[row]) {
      p.material = state === 'Lit' ? this.lit : this.dark;
      p.visible = true;
    }
  }

  /** Opens or shuts bin `slot`'s lid (swung over LID_SWING; `instant` sets it). */
  lid(slot, open, instant = false) {
    const bin = this.bins.get(slot);
    if (!bin) return;
    const key = `Lid${slot}`;
    const running = this.tweens.get(key);
    const from = running ? running.value ?? running.to : open ? 0 : LID_OPEN;
    this.tweens.set(key, { from, to: open ? LID_OPEN : 0, at: this.env.now(), seconds: instant ? 0 : LID_SWING,
      apply: (v) => this.env.setNodeTransform(bin.id, 'Lid', _m.makeRotationX(v)) });
  }

  frame() {
    const now = this.env.now();
    for (const [key, tw] of this.tweens) {
      const u = tw.seconds > 0 ? Math.min(1, Math.max(0, (now - tw.at) / tw.seconds)) : 1;
      const eased = u * u * (3 - 2 * u);
      tw.value = tw.from + (tw.to - tw.from) * eased;
      tw.apply(tw.value);
      if (u >= 1) this.tweens.delete(key);
    }
  }
}

