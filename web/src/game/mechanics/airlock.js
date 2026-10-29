// airlock.js: the stairwell airlock checkpoints (CheckpointAirlockService) and their banner (AirlockController).
//
// One airlock at a time: the current level's exit vestibule (the stairwell's fromRoom) with that level's Checkpoint
// volume and the fire door(s) between the vestibule and the level (airlock doors whose FromLevel is the level). The
// roof has none. At 10 Hz the player counts as inside while their root or the point under their feet is in the
// volume. Idle -> Waiting when a playing participant is inside (StragglerDeadline = now + StragglerSeconds on the
// exit doors); Waiting -> Sealing when every Alive participant is inside (solo: as soon as you are) or at the
// deadline with someone inside: the doors close Locked in SEAL_SECONDS (never on anyone); Waiting -> Idle at the
// deadline with nobody inside. Sealing -> Sealed once the doors are shut (or SEAL_TIMEOUT): the level is marked
// cleared and the run advances (the next floor activates), FloorsCleared + 1 and the floor's credits are told,
// sealed doors stay Locked for the run.
//
// Web: the player also counts as inside while they stand in the stair tower beyond the vestibule (WorldConfig.Towers,
// from the level's floor up to the next level's ceiling) or in the next level's entry vestibule: a lone survivor who
// runs on up the stairs while the doors close is past the seal, not left behind on the floor (the Roblox squad waits
// in the vestibule for each other). Alone, Waiting lasts one poll, so the squad's straggler toast is not sent.

import * as THREE from 'three';
import { GameConfig } from '../config.js';
import { S } from '../strings.js';
import { formatTime } from '../util.js';
import { Palette, el, meter } from '../ui/style.js';

const SEAL_SECONDS = 1.6;
const SEAL_TIMEOUT = 6;
const POLL = 0.1;
const URGENT_SECONDS = 5;
const ROOT_TO_FEET = 3;

export class Airlock {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Airlock';
    this.game = game;
    this.phase = 'Idle';
    this.level = null;
    this.volumes = [];
    this.doors = [];
    this.deadline = null;
    this.sealingSince = null;
    this.clock = 0;
    this.inside = false;
    this.banner = new AirlockBanner(game, this);
  }

  _reset(level) {
    this.level = level;
    this.phase = 'Idle';
    this.deadline = null;
    this.sealingSince = null;
    this.volumes = level ? this.game.world.checkpointVolumes(level) : [];
    this.tower = level ? towerBox(this.game.world.meta, level) : null;
    this.doors = level ? this.game.doors.exitDoors(level) : [];
    for (const d of this.doors) d.stragglerDeadline = null;
  }

  beginRun() {
    this._reset(null);
  }

  endRun() {
    this._reset(null);
  }

  /** Whether the player's root or feet stand in the level's checkpoint volume. */
  isInside() {
    const env = this.game.env;
    const root = env.rootPosition(_p);
    _f.set(root.x, root.y - ROOT_TO_FEET, root.z);
    for (const v of this.volumes) {
      if (this.game.world.inTrigger(v, root) || this.game.world.inTrigger(v, _f)) return true;
    }
    const t = this.tower;
    if (t && t.toRoom && this.game.world.inRoom(t.toRoom, root)) return true;
    return !!t && root.x >= t.minX && root.x <= t.maxX && root.z >= t.minZ && root.z <= t.maxZ && root.y >= t.minY &&
      root.y <= t.maxY;
  }

  _setDeadline(value) {
    this.deadline = value;
    for (const d of this.doors) d.stragglerDeadline = value;
  }

  /** Seals the current airlock now (dev `seal`). */
  seal() {
    if (this.phase !== 'Idle' && this.phase !== 'Waiting') return false;
    if (this.phase === 'Idle') this._setDeadline(this.game.env.now());
    this._seal();
    return true;
  }

  _seal() {
    this.phase = 'Sealing';
    this.sealingSince = this.game.env.now();
    for (const d of this.doors) this.game.doors.setState(d, 'Locked', SEAL_SECONDS);
  }

  _doorsShut() {
    return this.doors.every((d) => !this.game.doors.isMoving(d) && d.state === 'Locked');
  }

  _finalize() {
    const game = this.game;
    const from = this.level;
    const survivor = game.life.playing() && this.isInside();
    if (game.life.playing() && !survivor) {
      game.notify('Airlock.LeftBehind');
      game.life.setSpectating();
    }
    this._setDeadline(null);
    this.phase = 'Sealed';
    this.sealingSince = null;
    const to = game.advance();
    if (survivor) {
      game.stats.increment('FloorsCleared');
      game.notify('Checkpoint.Sealed');
      if (!game.run.devRun && !game.profile.readOnly) game.notify('Checkpoint.Reached', GameConfig.CreditsPerLevelCleared);
    }
    if (to && game.hints) game.hints.noteSeal(from);
  }

  tick(dt, now) {
    const game = this.game;
    if (!game.live() || game.phase !== 'InRun') return;
    if (game.level !== this.level) this._reset(game.level);
    if (!this.level || !game.world.exitRoom(this.level)) return;
    this.clock += dt;
    if (this.clock < POLL) return;
    this.clock = 0;
    this.inside = this.isInside();
    const playing = game.life.playing();
    if (this.phase === 'Idle') {
      if (this.inside && playing) {
        this.phase = 'Waiting';
        // (the Roblox squad hears "Hud.Straggler" here; played alone everyone is already in, so the doors start
        // sealing on this same poll and there is nobody to warn)
        this._setDeadline(now + GameConfig.StragglerSeconds);
      } else return;
    }
    if (this.phase === 'Waiting') {
      const anyInside = this.inside && playing;
      const allAliveInside = !(game.life.state === 'Alive' && !this.inside);
      if (!anyInside) {
        if (now >= this.deadline) {
          this._setDeadline(null);
          this.phase = 'Idle';
        }
        return;
      }
      if (allAliveInside || now >= this.deadline) this._seal();
      else return;
    }
    if (this.phase === 'Sealing') {
      if (this._doorsShut() || now - this.sealingSince >= SEAL_TIMEOUT) this._finalize();
    }
  }

  frame(dt, now) {
    this.banner.frame(dt, now);
  }
}

/** AirlockController: the straggler countdown banner (inside / outside / sealing). */
class AirlockBanner {
  constructor(game, airlock) {
    this.game = game;
    this.airlock = airlock;
    this.alpha = 0;
    const root = game.env.uiRoot();
    this.root = el('div', 'rg-panel', root);
    Object.assign(this.root.style, {
      position: 'absolute', left: '50%', top: '13%', transform: 'translateX(-50%)', width: 'min(460px, 92vw)',
      padding: '10px 18px 12px', textAlign: 'center', pointerEvents: 'none', opacity: '0', display: 'none',
    });
    this.text = el('div', 'rg-title', this.root, '');
    this.text.style.fontSize = '20px';
    this.bar = meter(this.root, Palette.Amber);
    this.bar.root.style.marginTop = '8px';
  }

  frame(dt, now) {
    const g = this.game;
    const a = this.airlock;
    const deadline = a.deadline;
    const lock = g.controlLock();
    const visible = g.env.hudVisible() && g.env.context() !== 'Cutscene' && lock !== 'Cutscene' && lock !== 'Jumpscare';
    const state = deadline === null || !Number.isFinite(deadline) ? 'Hidden' : a.phase === 'Sealing' ? 'Sealing' : 'Waiting';
    const want = state !== 'Hidden' && visible && g.live() ? 1 : 0;
    this.alpha += Math.sign(want - this.alpha) * Math.min(Math.abs(want - this.alpha), (want ? 5 : 3) * dt);
    if (this.alpha <= 0.001) {
      this.root.style.display = 'none';
      return;
    }
    this.root.style.display = '';
    this.root.style.opacity = String(this.alpha);
    const remaining = deadline === null ? 0 : Math.max(0, deadline - now);
    const inside = a.inside;
    if (state === 'Sealing') this.text.textContent = S('Airlock.Sealing');
    else if (state === 'Waiting') {
      this.text.textContent = S(inside ? 'Airlock.Waiting' : 'Airlock.GetIn', formatTime(Math.ceil(remaining)));
    }
    const urgent = state === 'Waiting' && !inside && remaining <= URGENT_SECONDS;
    this.text.style.color = state === 'Waiting' && !inside ? Palette.Ember : Palette.Bone;
    this.text.style.animation = urgent ? 'rg-pulse 0.5s infinite' : '';
    this.bar.set(Math.min(1, Math.max(0, remaining / GameConfig.StragglerSeconds)));
    this.bar.root.style.display = state === 'Waiting' ? '' : 'none';
  }
}

/** The stair tower leaving `level` (its box from the level's floor to the next level's ceiling), or null. */
function towerBox(meta, level) {
  const wc = meta.worldConfig || {};
  const stair = (meta.stairwells || []).find((s) => s.from === level);
  const tower = stair && wc.Towers ? wc.Towers[stair.tower] : null;
  const from = meta.levels[level];
  const to = stair ? meta.levels[stair.to] : null;
  if (!tower || !from || !to) return null;
  return {
    minX: tower.minX, maxX: tower.maxX, minZ: tower.minZ, maxZ: tower.maxZ,
    minY: from.elevation, maxY: to.elevation + (to.height || 14), toRoom: stair.toRoom,
  };
}

const _p = new THREE.Vector3();
const _f = new THREE.Vector3();
