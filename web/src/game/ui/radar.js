// radar.js: the radar on the HUD (docs/design/game-spec-v2.md 3.2; the radar itself is mechanics/radar.js).
//
//   Pips     three pips beside the battery bar, bottom left (top left on touch): the charges held, through a run.
//   Ring     while a scan is up: a cold-green ring round the crosshair, filling over the raise and draining over the
//            scan's seconds.
//   Markers  what the scan shows (Radar.targets, from the frame the raise ends to the frame the scan ends, refreshed
//            every RESCAN seconds between), each a cold-green diamond with its icon (an item, a station, the exit), its
//            name and its straight distance in metres (RadarRules.metres), the batteries in reach as small dots; and the
//            chevron round the crosshair toward the nearest diamond. Every page draws its own (co-op: one squad scan, a
//            chevron each). Never the Creature, never a teammate.
// Hidden while the HUD is hidden, in the Cutscene / Menu contexts and under a Cutscene / Jumpscare lock.

import * as THREE from 'three';
import { S } from '../strings/index.js';
import '../strings/kit.js';
import { Marker, Pointer } from './objectives.js';
import { Palette, el } from './style.js';

const RESCAN = 0.1;
const RING = 168;
const FADE = 6;
const PIP = 9;

export class RadarHud {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'RadarHud';
    this.game = game;
    this.env = game.env;
    this.clock = 0;
    this.scannedAt = -Infinity;
    /** the scan whose markers the HUD shows (null while none shows) */
    this.showingScan = null;
    this.alpha = 0;
    /** @type {Array<{kind: string, id: string, point: any, name: string}>} the markers shown now */
    this.shown = [];
    const root = this.env.uiRoot();
    this.layer = el('div', 'rg-layer', root);
    this.layer.style.zIndex = '11';
    // the pips
    this.pips = el('div', '', root);
    Object.assign(this.pips.style, { position: 'absolute', left: '198px', bottom: '27px', display: 'none', gap: '5px',
      alignItems: 'center', pointerEvents: 'none', zIndex: '9' });
    this.pipDots = [0, 1, 2].map(() => {
      const d = el('div', '', this.pips);
      Object.assign(d.style, { width: `${PIP}px`, height: `${PIP}px`, borderRadius: '50%', border: `1.5px solid ${Palette.Radar}` });
      return d;
    });
    // the ring round the crosshair
    this.ringWrap = el('div', '', this.layer);
    Object.assign(this.ringWrap.style, { position: 'absolute', left: '50%', top: '50%', width: `${RING}px`, height: `${RING}px`,
      transform: 'translate(-50%, -50%)', opacity: '0' });
    this.ring = this.env.ring(this.ringWrap, RING, 2, Palette.Radar);
    this.pointer = new Pointer(this.layer, Palette.Radar);
    /** @type {Marker[]} */
    this.markers = [];
    /** @type {Marker[]} */
    this.dots = [];
    /** the markers and dots placed this frame (each hidden while its point is behind the camera) */
    this.count = { markers: 0, dots: 0 };
  }

  _allowed() {
    const g = this.game;
    if (!this.env.hudVisible()) return false;
    const ctx = this.env.context();
    if (ctx === 'Cutscene' || ctx === 'Menu') return false;
    const lock = g.controlLock();
    return lock !== 'Cutscene' && lock !== 'Jumpscare';
  }

  /** The pool's `i`-th marker (or dot), made on first use. */
  _marker(pool, i, dot) {
    while (pool.length <= i) pool.push(new Marker(this.layer, Palette.Radar, dot));
    return pool[i];
  }

  frame(dt) {
    this.clock += dt;
    const g = this.game;
    const radar = g.radar;
    const env = this.env;
    const canShow = this._allowed();
    // the pips
    const life = g.life.state;
    const pips = canShow && !!g.run && g.live() && (life === 'Alive' || life === 'Downed');
    this.pips.style.display = pips ? 'flex' : 'none';
    const touch = env.device() === 'Touch';
    this.pips.style.bottom = touch ? 'auto' : '27px';
    this.pips.style.top = touch ? '108px' : 'auto';
    if (pips) {
      this.pipDots.forEach((d, i) => {
        d.style.display = i < radar.max() ? '' : 'none';
        d.style.background = i < radar.charges ? Palette.Radar : 'transparent';
      });
    }
    // the scan: the ring, the markers, the chevron
    const live = canShow && radar.live();
    const want = live ? 1 : 0;
    this.alpha += Math.sign(want - this.alpha) * Math.min(Math.abs(want - this.alpha), dt * FADE);
    this.ringWrap.style.opacity = String(this.alpha);
    if (radar.scan && live) {
      const now = env.now();
      const s = radar.scan;
      // the raise fills it, the scan drains it
      this.ring.setProgress(now < s.showAt ? (now - s.raiseAt) / Math.max(1e-6, s.showAt - s.raiseAt)
        : Math.max(0, (s.endsAt - now) / (s.endsAt - s.showAt)));
    }
    // the targets refresh every RESCAN seconds, and at once when a scan's markers come up or go: they show from the
    // frame the raise ends to the frame the scan ends, whatever the refresh's phase
    const showing = live && radar.showing() ? radar.scan : null;
    if (showing !== this.showingScan || this.clock - this.scannedAt >= RESCAN) {
      this.showingScan = showing;
      this.scannedAt = this.clock;
      this.shown = showing ? radar.targets() : [];
    }
    const root = env.rootPosition(_root);
    let nearest = null;
    let best = Infinity;
    let m = 0;
    let d = 0;
    const pulse = Math.sin(this.clock * 3);
    for (const t of this.shown) {
      if (t.kind === 'Battery') {
        this._marker(this.dots, d++, true).place(env, t.point, { alpha: this.alpha, pulse, lift: 1.2 });
        continue;
      }
      const dist = t.point.distanceTo(root);
      const metres = radar.rules.metres(dist);
      this._marker(this.markers, m++, false).place(env, t.point, { label: t.name, metres, icon: t.kind, alpha: this.alpha,
        pulse, lift: 1.6 });
      if (dist < best) {
        best = dist;
        nearest = { t, metres };
      }
    }
    this.count = { markers: m, dots: d };
    for (let i = m; i < this.markers.length; i++) this.markers[i].hide();
    for (let i = d; i < this.dots.length; i++) this.dots[i].hide();
    this.pointer.place(env, nearest ? nearest.t.point : null, nearest ? `${nearest.t.name} · ${S('Objective.Distance', Math.max(1, nearest.metres))}` : '',
      nearest ? this.alpha : 0);
  }

  endRun() {
    this.shown = [];
    this.showingScan = null;
  }
}

const _root = new THREE.Vector3();
