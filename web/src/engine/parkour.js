// parkour.js: the player's moves beyond walking (docs/design/game-spec-v2.md 3.1; invariants I8 and I9), stepped by
// player.js inside the fixed 30 Hz tick: the slide, the leap, hard landings and the look-back. The rules are the shared
// ones (game/rules/parkour.js, the port of ParkourRules over world.json meta.parkourConfig); nothing here reads the
// frame rate or the graphics tier, so every result is a function of the tick index.
//
//   Slide      a Crouch press while Sprinting on the ground at Slide.MinSpeed or more starts it (ParkourRules
//              slideStarts; the press is consumed: it does not toggle the crouch). MoveState Sliding for Slide.Seconds
//              (21 ticks), the body Slide.BodyHeight tall (the crouched capsule) with the crouched eye, its speed the
//              rules' profile (SpeedStart falling to SpeedEnd, sampled at each 1/60 s substep's middle, so the distance
//              is the rules' 10.5 on open floor), its heading turning toward the move input at most SteerRate degrees a
//              second; no jump. It ends after its time (Standing with StandHeight of headroom, else Crouching:
//              ParkourRules.slideEnd), or at once when the body leaves the ground, an override or a lock takes the
//              body, or the mode changes. The start emits the Slide noise once and the SlideScrape sound.
//   Leap       over a strip of the world (LeapStrip anchors, below). Inside the approach band (the Band studs before
//              the lip) a Jump press is held as a request for RequestHold seconds instead of a free jump; a press up
//              to Coyote seconds after running off the lip counts too (ParkourRules.jumpPress). At the first tick the
//              root stands in the strip (StripLength before the lip) or is past the lip within Coyote, with a live
//              request (or Leap assist, ParkourRules.assistOn of the LeapAssist setting and the device), horizontal
//              speed MinSpeed or more and a heading within MaxHeading of the leap (ParkourRules.canLeap), the leap
//              starts: MoveState Leaping, a motion override that places the root on ParkourRules.leap(t) from the
//              take-off point every substep (no collision, no input) for Seconds, then ExitSpeed along the leap and
//              normal physics. The LeapWhoosh sound plays; the landing is heard as any landing (below).
//   Landings   a landing on foot after JumpLandAirborne seconds or more in the air emits JumpLand; a fall of
//              HardLanding.Fall or more (from the highest point of the fall) is a hard landing instead
//              (ParkourRules.hardLanding): HardLanding.Seconds at SpeedFactor of the walk speed, a camera dip, the
//              HardLanding noise and sound. A fall never damages. Falls driven by a motion override other than the
//              leap (the vent rail, the parachute) and teleports are not falls.
//   Look-back  while LookBack is held (on foot only: no override, no lock), the view turns Degrees over the left
//              shoulder in Seconds and back on release; movement keeps its heading (the turn is the camera's alone).
//              Advanced on the tick and drawn between the last two tick states.
//
// A strip (stripsFrom: every LeapStrip anchor of world.json) stands at the near lip, at the strip's floor: the anchor's
// position is the lip's centre and its LookVector the leap direction; the strip runs StripLength back from the lip, the
// gap Leap.Gap beyond it and the pad Leap.PadDepth beyond that. Its `Width` attribute is the strip's width across the
// leap (a leap corridor's Street.Min when the anchor names none). addStrip() adds one (the tests' fixtures).

import * as THREE from 'three';
import { parkourRules } from '../game/rules/parkour.js';
import { Presets } from './audio/presets.js';

/** Feet within this of a strip's floor stand on it (the band and the strip are walked, not jumped into). */
const STRIP_FEET = 1.5;
/** How far up the slide's end looks for a ceiling (studs over the feet; more than StandHeight). */
const HEADROOM_REACH = 8;
/** The hard landing's camera dip (studs at its deepest). */
const DIP = 0.7;
/** The look-back turns over the left shoulder (yaw grows to the left). */
const LOOK_SIDE = 1;

const EQ = (LowGain, MidGain, HighGain) => ({ kind: 'Equalizer', props: { LowGain, MidGain, HighGain } });

/** The parkour sounds (spec 5.5), SynthPresets recipes on the synthesized sources, on the Player bus. */
export const ParkourPresets = Object.freeze({
  SlideScrape: {
    bus: 'Player', maxVoices: 2, priority: 50,
    layers: [
      { duration: 0.7, looped: true, sample: 'Falling', region: { min: 0.1, max: 0.5 }, speed: 2.4, volume: 0.55,
        envelope: { attack: 0.02, hold: 0.45, release: 0.23 }, effects: [EQ(-14, 4, 2)] },
      { sample: 'FootstepsPlastic', region: { min: 0, max: 0.17 }, speed: 0.7, volume: 0.6,
        grains: { count: { min: 5, max: 7 }, spacing: { min: 0.08, max: 0.12 } }, effects: [EQ(-6, 4, -2)] },
    ],
  },
  LeapWhoosh: {
    bus: 'Player', maxVoices: 2, priority: 50,
    layers: [
      { duration: 0.6, looped: true, sample: 'Falling', region: { min: 0.2, max: 0.8 }, speed: 1.1, volume: 0.7,
        envelope: { attack: 0.15, hold: 0.2, release: 0.25 }, effects: [EQ(-8, 2, 4)] },
      { sample: 'Jump', speed: 0.9, volume: 0.6 },
    ],
  },
  HardLanding: {
    bus: 'Player', maxVoices: 2, priority: 60, caption: 'Caption.HardLanding', captionText: '[a hard landing]',
    layers: [
      { sample: 'JumpLand', speed: { min: 0.55, max: 0.62 }, volume: 1.4, effects: [EQ(8, 0, -10)] },
      { delay: 0.04, sample: 'Oof', speed: { min: 0.92, max: 1.02 }, volume: 0.55 },
      { delay: 0.02, sample: 'GetUp', speed: 1.2, volume: 0.5 },
    ],
  },
});
for (const [name, preset] of Object.entries(ParkourPresets)) if (!Presets[name]) Presets[name] = preset;

/**
 * @typedef {{id: string, level: string|null, lip: THREE.Vector3, dir: THREE.Vector3, side: THREE.Vector3, width: number}} Strip
 *   lip: the near lip's centre at the strip's floor; dir: the leap direction (unit, horizontal); side: dir turned right
 */

/** The world's leap strips (LeapStrip anchors). */
export function stripsFrom(meta, rules) {
  const out = [];
  for (const a of meta.anchors || []) {
    if (a.kind !== 'LeapStrip') continue;
    const cf = a.cframe;
    const width = a.attributes && Number.isFinite(a.attributes.Width) ? a.attributes.Width : rules.config.Street.Min;
    out.push(makeStrip(a.id, a.level || null, new THREE.Vector3(cf[0], cf[1], cf[2]), new THREE.Vector3(-cf[5], 0, -cf[11]), width));
  }
  return out;
}

/** A strip from its lip centre, leap direction (horizontal) and width. */
export function makeStrip(id, level, lip, direction, width) {
  const dir = new THREE.Vector3(direction.x, 0, direction.z).normalize();
  return { id, level, lip: lip.clone(), dir, side: new THREE.Vector3(-dir.z, 0, dir.x), width };
}

/**
 * Never blind (spec 3.1): from the eye of a sprinting player (feet + SightEye) SightDistance before the strip's start,
 * SightRays rays to the pad (its middle and four points across and along it, half a stud over it), each clear of the
 * world. Returns how many are clear.
 * @param {{raycast: Function}} world
 * @param {Strip} strip
 */
export function sightClear(world, strip, rules) {
  const L = rules.config.Leap;
  const eye = strip.lip.clone().addScaledVector(strip.dir, -(L.StripLength + L.SightDistance));
  eye.y += L.SightEye;
  const padNear = L.Gap;
  const points = [[0.5, 0], [0.2, -0.3], [0.2, 0.3], [0.8, -0.3], [0.8, 0.3]].slice(0, L.SightRays);
  let clear = 0;
  for (const [along, across] of points) {
    const to = strip.lip.clone().addScaledVector(strip.dir, padNear + along * L.PadDepth).addScaledVector(strip.side, across * strip.width);
    to.y += 0.5;
    const d = to.clone().sub(eye);
    const len = d.length();
    if (!world.raycast(eye, d.divideScalar(len), len - 0.05)) clear++;
  }
  return clear;
}

export class Parkour {
  /** @param {import('./player.js').Player} player */
  constructor(player) {
    this.player = player;
    const meta = player.world.meta;
    this.rules = parkourRules(meta);
    /** @type {Strip[]} */
    this.strips = stripsFrom(meta, this.rules);
    this.jumpLandAirborne = meta.noiseConfig && Number.isFinite(meta.noiseConfig.JumpLandAirborne) ? meta.noiseConfig.JumpLandAirborne : 0.32;
    /** @type {{heading: number, ticks: number}|null} the slide under way (heading: a yaw) */
    this.slide = null;
    /** @type {{strip: Strip, origin: THREE.Vector3, takeoff: number, substeps: number, start: number}|null} */
    this.leap = null;
    /** @type {{at: number, strip: Strip}|null} a held leap request */
    this.request = null;
    /** @type {{at: number, strip: Strip}|null} when the root crossed a strip's lip */
    this.edge = null;
    /** the strip the root was over last tick, and how far before its lip */
    this.last = null;
    /** @type {{start: number, until: number, factor: number}|null} a hard landing's slowdown */
    this.hard = null;
    /** the airborne track: when the body left the ground (the last grounded tick's end) and the highest feet since */
    this.airSince = null;
    this.peak = -Infinity;
    /** the look-back's share of its turn (0..1) at the last two ticks */
    this.lookPrev = 0;
    this.lookNow = 0;
  }

  /**
   * Adds a strip (a fixture; the world's come from its anchors): its lip's centre ({x, y, z}), the leap direction
   * ({x, z}) and its width.
   */
  addStrip(id, lip, direction, width) {
    const strip = makeStrip(id, null, new THREE.Vector3(lip.x, lip.y, lip.z), new THREE.Vector3(direction.x, 0, direction.z), width);
    this.strips.push(strip);
    return strip;
  }

  /** The never-blind test of a strip (sightClear): how many of the SightRays rays reach its pad. */
  sight(strip) {
    return sightClear(this.player.world, strip, this.rules);
  }

  /** Forgets every move under way (a teleport, a run's reset). */
  reset() {
    if (this.leap) this.player.setMotionOverride('Leap', null);
    this.slide = null;
    this.leap = null;
    this.request = null;
    this.edge = null;
    this.last = null;
    this.hard = null;
    this.airSince = null;
    this.peak = -Infinity;
    this.lookPrev = 0;
    this.lookNow = 0;
  }

  /** The strip the feet are over (laterally inside it, from Band before its lip to just past it), or null. */
  _strip(root, feetY) {
    const L = this.rules.config.Leap;
    let best = null;
    for (const s of this.strips) {
      const dx = root.x - s.lip.x;
      const dz = root.z - s.lip.z;
      const toEdge = -(dx * s.dir.x + dz * s.dir.z);
      const lateral = dx * s.side.x + dz * s.side.z;
      if (Math.abs(lateral) > s.width / 2 || toEdge > L.Band || toEdge < -L.Gap) continue;
      if (feetY > s.lip.y + STRIP_FEET || feetY < s.lip.y - L.Gap) continue;
      if (!best || Math.abs(toEdge) < Math.abs(best.toEdge)) best = { strip: s, toEdge };
    }
    return best;
  }

  /**
   * A Crouch press at the tick, before the body moves: it starts a slide when ParkourRules.slideStarts allows it
   * (`sprinting`: the MoveState was Sprinting) and is then consumed, as it is during a slide or a leap. Returns whether
   * it was used (false: it toggles the crouch as before).
   */
  crouchPress(sprinting) {
    const p = this.player;
    if (this.slide || this.leap) return true;
    if (!this._onFoot() || !this.rules.slideStarts(p.body.grounded, sprinting, p.speed)) return false;
    const v = p.body.velocity;
    const heading = Math.hypot(v.x, v.z) > 1e-3 ? Math.atan2(-v.x, -v.z) : p.yaw;
    this.slide = { heading, ticks: 0 };
    p.intent.crouch = false;
    p.slid.fire();
    p.emitNoise('Slide');
    p.playSound('SlideScrape');
    return true;
  }

  /**
   * The jump press against the strips (ParkourRules.jumpPress) and the leap's start (ParkourRules.canLeap), at the
   * tick before the body moves. `press`: a Jump press since the last tick; `held`: Jump is held. Returns whether the
   * body makes a free jump this tick.
   */
  beforeMove(now, press, held) {
    const p = this.player;
    const L = this.rules.config.Leap;
    if (this.slide && (!this._onFoot() || p.isLocked())) this.slide = null;
    if (this.leap) return false;
    const body = p.body;
    const near = p.mode === 'OnFoot' ? this._strip(body.position, body.feetY) : null;
    // the lip crossed since the last tick (the root on the near side then, past it now)
    if (near && near.toEdge < 0 && this.last && this.last.strip === near.strip && this.last.toEdge >= 0) {
      this.edge = { at: now, strip: near.strip };
    }
    if (body.grounded && (!near || near.toEdge >= 0)) this.edge = null;
    this.last = near;
    const sinceEdge = this.edge && near && this.edge.strip === near.strip ? now - this.edge.at : -1;
    if (this.request && now - this.request.at > L.RequestHold + 1e-6) this.request = null;
    let jump = false;
    if (press) {
      const verdict = this.rules.jumpPress(body.grounded, near ? near.toEdge : Infinity, sinceEdge);
      if (verdict === 'Request') this.request = { at: now, strip: near.strip };
      else jump = verdict === 'Jump' && !this.slide;
    } else if (held) {
      jump = !this.slide && !(near && this.rules.jumpPress(true, near.toEdge, -1) === 'Request');
    }
    if (near && this._onFoot() && !p.isLocked() && !this.slide) {
      const feetOn = Math.abs(body.feetY - near.strip.lip.y) <= STRIP_FEET;
      const inStrip = near.toEdge >= 0 && near.toEdge <= L.StripLength && feetOn;
      const v = body.velocity;
      const speed = Math.hypot(v.x, v.z);
      const heading = speed > 1e-6
        ? THREE.MathUtils.radToDeg(Math.acos(Math.max(-1, Math.min(1, (v.x * near.strip.dir.x + v.z * near.strip.dir.z) / speed)))) : 180;
      const request = this.request && this.request.strip === near.strip ? now - this.request.at : -1;
      const verdict = this.rules.canLeap({ inStrip, sinceEdge, requestAge: request, speed, heading, assist: this._assist() });
      if (verdict === 'Leap') {
        this._startLeap(near);
        return false;
      }
    }
    return jump;
  }

  _assist() {
    const p = this.player;
    return this.rules.assistOn(p.settings.get('LeapAssist'), p.input.device);
  }

  _onFoot() {
    const p = this.player;
    return p.mode === 'OnFoot' && !p.getOverride() && p.lifeState !== 'Downed' && p.isAlive();
  }

  _startLeap(near) {
    const p = this.player;
    const L = this.rules.config.Leap;
    this.request = null;
    this.edge = null;
    this.leap = { strip: near.strip, origin: p.body.position.clone(), takeoff: near.toEdge, substeps: 0 };
    const leap = this.leap;
    const body = p.body;
    p.setMotionOverride('Leap', (sub) => {
      leap.substeps++;
      const t = leap.substeps * sub;
      const s = this.rules.leap(t, leap.takeoff);
      const dir = leap.strip.dir;
      body.position.set(leap.origin.x + dir.x * s.along, leap.origin.y + s.height, leap.origin.z + dir.z * s.along);
      body.grounded = false;
      if (s.done) {
        body.velocity.set(dir.x * L.ExitSpeed, 0, dir.z * L.ExitSpeed);
        p.setMotionOverride('Leap', null);
        this.leap = null;
      } else {
        const u = t / L.Seconds;
        const across = this.rules.leapLength(leap.takeoff) / L.Seconds;
        body.velocity.set(dir.x * across, (4 * L.Apex * (1 - 2 * u)) / L.Seconds, dir.z * across);
      }
    }, 1000);
    p.leapt.fire(near.strip, near.toEdge);
    p.playSound('LeapWhoosh');
  }

  /**
   * The slide's motion for one substep (`k`: the substep's index in the slide), the wish's heading the steering
   * target (null: no move input). Returns the horizontal velocity the body is driven at.
   */
  slideWish(k, sub, wishHeading, out) {
    const S = this.rules.config.Slide;
    const slide = this.slide;
    if (wishHeading !== null) {
      let diff = wishHeading - slide.heading;
      diff = Math.atan2(Math.sin(diff), Math.cos(diff));
      const turn = THREE.MathUtils.degToRad(S.SteerRate) * sub;
      slide.heading += Math.max(-turn, Math.min(turn, diff));
    }
    const speed = this.rules.slide((k + 0.5) * sub).speed;
    return out.set(-Math.sin(slide.heading) * speed, 0, -Math.cos(slide.heading) * speed);
  }

  /** The walk speed's share while a hard landing slows the body (1 otherwise). */
  speedFactor(now) {
    return this.hard && now < this.hard.until ? this.hard.factor : 1;
  }

  /**
   * After the body moved this tick: the slide's end, the airborne track and the landing, the look-back. `driven`: a
   * motion override other than the leap moved the body this tick.
   */
  afterMove(now, dt, driven) {
    const p = this.player;
    const body = p.body;
    if (this.slide) {
      this.slide.ticks++;
      const done = this.rules.slide(this.slide.ticks * dt).done;
      if (!body.grounded || done) {
        const standing = !body.grounded || this.rules.slideEnd(this.headroom()) === 'Standing';
        p.intent.crouch = !standing;
        this.slide = null;
      }
    }
    if (this.hard && now >= this.hard.until) this.hard = null;
    // falls: on foot, by gravity or the leap (another driver or no gravity is not a fall)
    if (p.mode !== 'OnFoot' || !body.gravity || driven) {
      this.airSince = null;
      this.peak = -Infinity;
    } else if (!body.grounded) {
      if (this.airSince === null) {
        this.airSince = now - dt;
        this.peak = p.tickPrevious.y - (body.position.y - body.feetY);
      }
      this.peak = Math.max(this.peak, body.feetY);
    } else if (this.airSince !== null) {
      const air = now - this.airSince;
      const fall = this.peak - body.feetY;
      this.airSince = null;
      this.peak = -Infinity;
      const h = this.rules.hardLanding(fall);
      if (h.hard) {
        this.hard = { start: now, until: now + h.seconds, factor: h.speedFactor };
        p.emitNoise(h.noise);
        p.playSound('HardLanding');
        p.hardLanded.fire(fall);
      } else if (air >= this.jumpLandAirborne - 1e-6) {
        p.emitNoise('JumpLand');
      }
    }
    // the look-back
    const LB = this.rules.config.LookBack;
    const held = p.input.isHeld('LookBack') && this._onFoot() && !p.isLocked();
    this.lookPrev = this.lookNow;
    const step = dt / LB.Seconds;
    this.lookNow = held ? Math.min(1, this.lookNow + step) : Math.max(0, this.lookNow - step);
  }

  /** Studs from the feet to the lowest thing overhead (HEADROOM_REACH when nothing is). */
  headroom() {
    return this.player.body.headroomHeight(HEADROOM_REACH);
  }

  /** The look-back's yaw offset of the view this frame (radians), between the last two ticks. */
  lookYaw(alpha) {
    const share = this.lookPrev + (this.lookNow - this.lookPrev) * alpha;
    return LOOK_SIDE * THREE.MathUtils.degToRad(this.rules.config.LookBack.Degrees) * share;
  }

  /** The hard landing's camera dip this frame (studs, negative), a function of the game clock. */
  dip(time) {
    const h = this.hard;
    if (!h) return 0;
    const u = (time - h.start) / (h.until - h.start);
    return u <= 0 || u >= 1 ? 0 : -DIP * Math.sin(Math.PI * u);
  }
}
