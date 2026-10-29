// debris.js: floor debris is loud (NoiseAndDirectorService DebrisNoise). Entering a FloorDebris trigger volume (the
// player's root or the point under their feet, ZoneService's VolumeEntered edge) while the match is InRun makes one
// FloorDebris noise (130 studs, Critical) where they stand and one GlassCrunch cue there. Each volume then rests for
// COOLDOWN seconds, so stepping off and back on, or walking along its edge, does not machine-gun the Creature's
// hearing; a different volume crunches at once. The Floor 1 ScareStep glass stays with level1.js.

import * as THREE from 'three';

const KIND = 'FloorDebris';
const PRESET = 'GlassCrunch';
const COOLDOWN = 2;
const POLL = 0.1;
const ROOT_TO_FEET = 3;

export class Debris {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Debris';
    this.game = game;
    this.volumes = game.world.triggers(KIND);
    /** @type {Set<string>} volumes the player stands in */
    this.inside = new Set();
    /** @type {Map<string, number>} volume -> last crunch */
    this.last = new Map();
    this.clock = 0;
  }

  beginRun() {
    this.inside.clear();
    this.last.clear();
  }

  endRun() {
    this.inside.clear();
    this.last.clear();
  }

  tick(dt, now) {
    const game = this.game;
    this.clock += dt;
    if (this.clock < POLL) return;
    this.clock = 0;
    if (game.phase !== 'InRun' || !game.playing()) {
      this.inside.clear();
      return;
    }
    const root = game.env.rootPosition(_root);
    _feet.set(root.x, root.y - ROOT_TO_FEET, root.z);
    for (const v of this.volumes) {
      if (v.level !== game.level) continue;
      const within = game.world.inTrigger(v, root) || game.world.inTrigger(v, _feet);
      if (!within) {
        this.inside.delete(v.id);
        continue;
      }
      if (this.inside.has(v.id)) continue;
      this.inside.add(v.id);
      const previous = this.last.get(v.id);
      if (previous !== undefined && now - previous < COOLDOWN) continue;
      this.last.set(v.id, now);
      game.noise(root, KIND);
      game.playAt(PRESET, root);
    }
  }
}

const _root = new THREE.Vector3();
const _feet = new THREE.Vector3();
