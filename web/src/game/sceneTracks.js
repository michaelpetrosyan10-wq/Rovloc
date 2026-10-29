// sceneTracks.js: the scene timelines' track handlers (SequenceController's built-ins "sound" / "light",
// LevelScenesController's sceneCamera / scenePanic / nearSound / movingSound / lightScale, CreatureController's
// "creature" and ParachuteController's roof tracks), registered on the game's sequencer with every Scenes timeline.
// Everything a scene holds (the camera override, panic floors, voices, light overrides) is released when its
// timeline ends or is stopped, and at the end of the run (the sequencer stops every playback).
//
//   sound        events: the key's preset at the Play arg `arg` (a Vector3), 2D without one, at the track's volume
//   light        continuous: the light in `target` / the `arg` light at that brightness; released at the end
//   sceneCamera  events (subject only): "Flinch" pushes the Cutscene camera (the stumble over the player's own eye,
//                and, with args.focus, the view dragged onto args.head); "Release" hands the held look back
//   scenePanic   continuous (subject only): the panic floor
//   nearSound    events: a 2D preset for a listener within ClassroomScare.HushRadius of the `arg` point
//   movingSound  continuous 0..1: the `target` preset riding from args.from to args.to
//   lightScale   continuous: the `arg` light at that factor of its base brightness
//   creature     events: a Creature action (NeckSnap, DoorSmash, Reveal, Vanish) on the scripted Creature
//   roofShake / roofPanic / finaleFocus / finalePanic / finaleFade: the roof scenes (see ParachuteController)

import * as THREE from 'three';
import { Args, ClassroomScare, RoofDoor, flinch, pullWeight, pulled, timelines } from './scenes.js';
import { clamp01, frameAt, yawOf } from './util.js';

const BLEND_IN = 0.03;
const BLEND_OUT = 0.2;
const MOVER_FADE_IN = 0.4;
const MOVER_FADE_OUT = 0.8;

/** @param {import('./game.js').Game} game */
export function registerSceneTracks(game) {
  const { env, seq, world } = game;
  seq.addSpecs(timelines());
  const isSubject = (ctx) => !!ctx.args[Args.Subject];
  const vecArg = (ctx, name) => {
    const v = name ? ctx.args[name] : null;
    return v instanceof THREE.Vector3 ? v : null;
  };
  /**
   * Base brightness of a fixture light (its layout brightness: a scripted fixture that starts dark, like the pool
   * floodlights, strikes up to it), null when unknown or dark.
   */
  const baseOf = (lightId) => {
    let best = 0;
    for (const l of world.meta.lights) if (l.id === lightId) best = Math.max(best, l.baseBrightness || 0, l.brightness || 0);
    return best > 0 ? best : null;
  };

  seq.register('sound', {
    mode: 'Events',
    fire(ctx, track, key) {
      if (typeof key.value !== 'string') return;
      const at = vecArg(ctx, track.arg);
      env.play(key.value, { position: at || undefined, volume: track.volume ?? 1 });
    },
  });

  const lightHolds = new Map();
  seq.register('light', {
    mode: 'Continuous',
    apply(ctx, track, value) {
      const id = track.target || (track.arg ? ctx.args[track.arg] : null);
      if (typeof id !== 'string' || typeof value !== 'number') return;
      lightHolds.set(track, id);
      env.setLightOverride(id, value);
    },
    stop(ctx, track, completed) {
      const id = lightHolds.get(track);
      lightHolds.delete(track);
      if (id && !(completed && track.hold)) env.setLightOverride(id, null);
    },
  });

  // ---------------------------------------------------------------------------------------------- sceneCamera
  let camera = null;
  const endCamera = (id) => {
    if (!camera || (id && camera.id !== id)) return;
    const session = camera;
    camera = null;
    if (session.focus && session.lastView) {
      _dir.set(-session.lastView.elements[8], -session.lastView.elements[9], -session.lastView.elements[10]);
      env.setLook(yawOf(_dir), Math.asin(Math.max(-1, Math.min(1, _dir.y))));
    }
    env.setCameraOverride('Cutscene', null);
  };
  seq.register('sceneCamera', {
    mode: 'Events',
    fire(ctx, track, key) {
      if (!isSubject(ctx)) return;
      if (key.value === 'Flinch') {
        endCamera(null);
        const session = {
          id: ctx.id,
          startAt: ctx.startAt,
          focus: ctx.args[Args.Focus] === true,
          head: vecArg(ctx, Args.Head),
          scale: clamp01(env.setting('MotionScale') ?? 1),
          lastView: null,
        };
        camera = session;
        env.setCameraOverride('Cutscene', () => {
          const t = env.now() - session.startAt;
          const look = env.look();
          const eye = frameAt(env.eye(_eye), look.yaw, look.pitch, _eyeM);
          let view = eye;
          if (session.focus && session.head) view = pulled(eye, session.head, pullWeight(t), _view);
          session.lastView = (session.lastView || new THREE.Matrix4()).copy(view);
          return _out.multiplyMatrices(view, flinch(t, session.scale, _fl));
        }, { priority: 5, blendIn: BLEND_IN, blendOut: BLEND_OUT });
      } else if (key.value === 'Release') endCamera(ctx.id);
    },
    stop(ctx) {
      endCamera(ctx.id);
    },
  });

  let panicHeld = false;
  seq.register('scenePanic', {
    mode: 'Continuous',
    apply(ctx, track, value) {
      if (typeof value !== 'number' || !isSubject(ctx)) return;
      panicHeld = true;
      env.setPanicFloor('LevelScene', clamp01(value));
    },
    stop(ctx) {
      if (panicHeld && isSubject(ctx)) {
        panicHeld = false;
        env.setPanicFloor('LevelScene', null);
      }
    },
  });

  seq.register('nearSound', {
    mode: 'Events',
    fire(ctx, track, key) {
      const source = vecArg(ctx, track.arg);
      if (typeof key.value !== 'string' || !source) return;
      if (env.camera().position.distanceTo(source) > ClassroomScare.HushRadius) return;
      env.play(key.value, { volume: track.volume ?? 1 });
    },
  });

  const movers = new Map();
  seq.register('movingSound', {
    mode: 'Continuous',
    apply(ctx, track, value) {
      const from = vecArg(ctx, Args.From);
      const to = vecArg(ctx, Args.To);
      if (typeof value !== 'number' || !from || !to || !track.target) return;
      let mover = movers.get(track);
      if (!mover) {
        const position = from.clone();
        mover = { position, voice: env.play(track.target, { follow: () => position, volume: track.volume ?? 1, loop: true, fadeIn: MOVER_FADE_IN }) };
        movers.set(track, mover);
      }
      mover.position.lerpVectors(from, to, clamp01(value));
    },
    stop(ctx, track) {
      const mover = movers.get(track);
      movers.delete(track);
      if (mover && mover.voice) mover.voice.stop(MOVER_FADE_OUT);
    },
  });

  const scaleHolds = new Map();
  seq.register('lightScale', {
    mode: 'Continuous',
    apply(ctx, track, value) {
      if (typeof value !== 'number') return;
      let hold = scaleHolds.get(track);
      if (!hold) {
        const id = track.arg ? ctx.args[track.arg] : null;
        const base = typeof id === 'string' ? baseOf(id) : null;
        if (!base) return;
        hold = { id, base };
        scaleHolds.set(track, hold);
      }
      env.setLightOverride(hold.id, hold.base * Math.max(0, value));
    },
    stop(ctx, track) {
      const hold = scaleHolds.get(track);
      scaleHolds.delete(track);
      if (hold && !(game.lightsKeptLit && game.lightsKeptLit.has(hold.id))) env.setLightOverride(hold.id, null);
    },
  });

  seq.register('creature', {
    mode: 'Events',
    fire(ctx, track, key) {
      if (typeof key.value !== 'string') return;
      if (game.creatureHandle) game.creatureHandle.action(key.value);
    },
  });

  // ---------------------------------------------------------------------------------------------- roof tracks
  seq.register('roofShake', {
    mode: 'Events',
    fire(ctx, track, key) {
      const door = vecArg(ctx, track.arg);
      if (typeof key.value !== 'number' || !door) return;
      if (env.camera().position.distanceTo(door) > RoofDoor.ShakeRadius) return;
      env.shake(key.value * clamp01(env.setting('MotionScale') ?? 1), 0.6);
    },
  });
  let roofPanic = false;
  seq.register('roofPanic', {
    mode: 'Continuous',
    apply(ctx, track, value) {
      const door = vecArg(ctx, track.arg);
      if (typeof value !== 'number' || !door) return;
      const near = game.playing() && env.rootPosition(_root).distanceTo(door) <= RoofDoor.PanicRadius &&
        !(game.parachute && game.parachute.jumped());
      roofPanic = near;
      env.setPanicFloor('RoofDoor', near ? clamp01(value) : null);
    },
    stop() {
      if (roofPanic) env.setPanicFloor('RoofDoor', null);
      roofPanic = false;
    },
  });
  seq.register('finaleFocus', {
    mode: 'Continuous',
    apply(ctx, track, value) {
      if (typeof value === 'number' && game.parachute) game.parachute.setFinaleFocus(vecArg(ctx, Args.Head), value);
    },
    stop() {
      if (game.parachute) game.parachute.setFinaleFocus(null, 0);
    },
  });
  let finalePanic = false;
  seq.register('finalePanic', {
    mode: 'Continuous',
    apply(ctx, track, value) {
      if (typeof value !== 'number') return;
      finalePanic = true;
      env.setPanicFloor('Finale', clamp01(value));
    },
    stop() {
      if (finalePanic) env.setPanicFloor('Finale', null);
      finalePanic = false;
    },
  });
  seq.register('finaleFade', {
    mode: 'Continuous',
    apply(ctx, track, value) {
      if (typeof value !== 'number') return;
      env.fade(clamp01(value), 0);
    },
    stop(ctx, track, completed) {
      if (!(completed && track.hold)) env.fade(0, 0.4);
    },
  });
}

const _eye = new THREE.Vector3();
const _eyeM = new THREE.Matrix4();
const _view = new THREE.Matrix4();
const _out = new THREE.Matrix4();
const _fl = new THREE.Matrix4();
const _dir = new THREE.Vector3();
const _root = new THREE.Vector3();
