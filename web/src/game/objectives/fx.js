// fx.js: the objectives' small effects, plain three.js objects in the world scene: smoke (acid fumes off the burning
// chain, the generator's exhaust) as soft camera-facing puffs that rise, swell and fade, lit by the baked probe where
// they start, and a short-lived glow light (the keypad turning green, the acid's sickly light). The puff texture is
// drawn once on a canvas (no assets). Everything is cleared at the end of a run.

import * as THREE from 'three';

const MAX_PUFFS = 90;

let texture = null;
function puffTexture() {
  if (texture) return texture;
  const c = document.createElement('canvas');
  c.width = c.height = 64;
  const g = c.getContext('2d');
  const grad = g.createRadialGradient(32, 32, 2, 32, 32, 31);
  grad.addColorStop(0, 'rgba(255,255,255,0.85)');
  grad.addColorStop(0.45, 'rgba(255,255,255,0.35)');
  grad.addColorStop(1, 'rgba(255,255,255,0)');
  g.fillStyle = grad;
  g.fillRect(0, 0, 64, 64);
  texture = new THREE.CanvasTexture(c);
  return texture;
}

export class ObjectiveFx {
  /** @param {import('../env.js').Env} env */
  constructor(env) {
    this.env = env;
    /** @type {{sprite: THREE.Sprite, born: number, life: number, rise: number, grow: number, drift: THREE.Vector3, alpha: number}[]} */
    this.puffs = [];
    /** @type {{at: THREE.Vector3, until: number, rate: number, next: number, opts: any}[]} */
    this.emitters = [];
    /** @type {{light: any, until: number, fade: number, brightness: number}[]} */
    this.lights = [];
    this.seed = 1;
  }

  _rand() {
    this.seed = (this.seed * 16807) % 2147483647;
    return this.seed / 2147483647;
  }

  /**
   * Smoke at a point: `seconds` of puffs at `rate` a second (or a burst of `count`), tinted `color` ([r, g, b] 0..1).
   * @param {THREE.Vector3} at
   * @param {{seconds?: number, rate?: number, count?: number, color?: number[], size?: number, rise?: number, life?: number, spread?: number}} opts
   */
  smoke(at, opts = {}) {
    const now = this.env.now();
    if (opts.count) for (let i = 0; i < opts.count; i++) this._puff(at, opts, now);
    if (opts.seconds) this.emitters.push({ at: at.clone(), until: now + opts.seconds, rate: opts.rate || 8, next: now, opts });
  }

  /** Stops every emitter at `at` (within a stud). */
  stopSmoke(at) {
    this.emitters = this.emitters.filter((e) => e.at.distanceTo(at) > 1);
  }

  _puff(at, opts, now) {
    if (this.puffs.length >= MAX_PUFFS) {
      const old = this.puffs.shift();
      this.env.removeFromScene(old.sprite);
      old.sprite.material.dispose();
    }
    const tint = new THREE.Color(...(opts.color || [0.55, 0.56, 0.5]));
    const lit = this.env.probeAt(at, new THREE.Color());
    const shade = Math.min(1, 0.35 + (lit.r + lit.g + lit.b) * 0.9);
    const mat = new THREE.SpriteMaterial({ map: puffTexture(), color: tint.multiplyScalar(shade), transparent: true,
      depthWrite: false, opacity: 0 });
    const sprite = new THREE.Sprite(mat);
    const spread = opts.spread ?? 0.4;
    sprite.position.set(at.x + (this._rand() - 0.5) * spread, at.y + (this._rand() - 0.5) * spread * 0.5,
      at.z + (this._rand() - 0.5) * spread);
    const size = (opts.size || 1) * (0.7 + this._rand() * 0.5);
    sprite.scale.set(size, size, size);
    sprite.renderOrder = 3;
    this.env.addToScene(sprite);
    this.puffs.push({
      sprite, born: now, life: (opts.life || 2.6) * (0.8 + this._rand() * 0.4), rise: opts.rise ?? 1.4,
      grow: 1.8 + this._rand(), drift: new THREE.Vector3((this._rand() - 0.5) * 0.6, 0, (this._rand() - 0.5) * 0.6),
      alpha: 0.55 + this._rand() * 0.25, base: size,
    });
  }

  /** A point light for `seconds` (fading over the last `fade`); returns its handle. */
  glow(at, color, brightness, range, seconds, fade = 0.4) {
    const light = this.env.addLight({ position: at.clone(), color, brightness, range });
    this.lights.push({ light, until: seconds === Infinity ? Infinity : this.env.now() + seconds, fade, brightness });
    return light;
  }

  clear() {
    for (const p of this.puffs) {
      this.env.removeFromScene(p.sprite);
      p.sprite.material.dispose();
    }
    this.puffs.length = 0;
    this.emitters.length = 0;
    for (const l of this.lights) l.light.remove();
    this.lights.length = 0;
  }

  frame() {
    const now = this.env.now();
    for (let i = this.emitters.length - 1; i >= 0; i--) {
      const e = this.emitters[i];
      while (e.next <= now && e.next <= e.until) {
        this._puff(e.at, e.opts, now);
        e.next += 1 / e.rate;
      }
      if (now > e.until) this.emitters.splice(i, 1);
    }
    for (let i = this.puffs.length - 1; i >= 0; i--) {
      const p = this.puffs[i];
      const t = (now - p.born) / p.life;
      if (t >= 1) {
        this.env.removeFromScene(p.sprite);
        p.sprite.material.dispose();
        this.puffs.splice(i, 1);
        continue;
      }
      const dt = 1 / 60;
      p.sprite.position.y += p.rise * dt * (1 - t * 0.5);
      p.sprite.position.addScaledVector(p.drift, dt);
      const s = p.base * (1 + p.grow * t);
      p.sprite.scale.set(s, s, s);
      p.sprite.material.opacity = p.alpha * Math.min(1, t * 6) * (1 - t);
    }
    for (let i = this.lights.length - 1; i >= 0; i--) {
      const l = this.lights[i];
      const left = l.until - now;
      if (left <= 0) {
        l.light.remove();
        this.lights.splice(i, 1);
      } else if (left < l.fade) l.light.set({ brightness: l.brightness * (left / l.fade) });
    }
  }
}
