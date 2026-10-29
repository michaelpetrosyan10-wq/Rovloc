// Audio: the WebAudio port of SoundSynthesizer + VoicePool + AudioBuses + AudioController.
//
// Mixer (AudioBuses). Master (safety compressor) <- Ambience (EQ) | Room (the environment chain: EQ -> Chorus ->
// Reverb -> Echo, gain) <- World / Monster / Player | Body (EQ) | UI. User volumes come from the settings (Body follows
// Player); presets duck other buses while they play. setEnvironment(preset) eases every slot of the chain (and the
// Ambience / Body EQs) to that AcousticPreset's values; the room the listener stands in picks it (a vent -> Vent,
// submerged -> Underwater, outside every room -> Outdoor), setEnvironmentOverride wins over both.
//
// Voices (SoundSynthesizer). play(name, opts) builds a voice from the SynthPresets recipe: every layer trigger is a
// grain (an AudioBufferSource on one of the 11 synthesized sources) with the recipe's speed / region slice / jitter /
// envelope / glide / grains / chance; each layer's effect chain is a shared group per preset layer (and an optional
// preset `space` group) that outlives its grains by the chain's tail, so reverbs and echoes ring out. Looped voices
// keep their bed layers running and re-trigger the other layers every `repeat` interval. 3D voices pan with the
// listener and attenuate InverseTapered between rollOff.min and rollOff.max (culled beyond it). Bus caps
// (Monster 6, World 16, Ambience 8, Player 12, Body 6, UI 6) and each preset's maxVoices hold, with priority stealing.
// Captioned presets fire `captioned` (the HUD shows it when captions are on).
//
// Ambience (AudioController). setAmbience(bed) crossfades the level drone and scatters its stingers (SynthPresets
// Beds) around the listener at seeded random intervals.

import { Presets, Beds, DefaultRollOff, Environments } from './presets.js';
import { buildSamples, SampleLengths, Seamless } from './samples.js';
import { buildChain, pitchOf, ramp, dbToGain } from './effects.js';
import { Signal } from '../signal.js';
import { Vector3 } from 'three';
import { Random } from '../math.js';

const BUSES = ['Ambience', 'World', 'Monster', 'Player', 'Body', 'UI'];
const ROOM_BUSES = new Set(['World', 'Monster', 'Player']);
const CAPS = { Monster: 6, World: 16, Ambience: 8, Player: 12, Body: 6, UI: 6 };
const SETTING_KEYS = { Master: 'MasterVolume', Ambience: 'AmbienceVolume', World: 'WorldVolume',
  Monster: 'MonsterVolume', Player: 'PlayerVolume', UI: 'UIVolume', Body: 'PlayerVolume' };
const ROBLOX_VOLUME = 0.5; // Sound.Volume 1 -> gain (Roblox's default Volume is 0.5)
const MAX_REVERBS = 6;
const LOOKAHEAD = 0.25;
const MIN_REGION = 0.004;
const ENV_FADE = 0.8;
const BED_FADE = 3;
const STINGER_HEIGHT = 4;
const RELEASE_SLACK = 0.5;

/** InverseTapered attenuation (VoicePool.attenuation). */
export function attenuation(distance, rollOff) {
  if (distance <= rollOff.min) return 1;
  if (distance >= rollOff.max) return 0;
  return (rollOff.min / distance) * (1 - (distance - rollOff.min) / Math.max(rollOff.max - rollOff.min, 1e-3));
}

function pick(rng, v) {
  if (typeof v === 'number') return v;
  if (!v) return 0;
  return v.max <= v.min ? v.min : rng.nextNumber(v.min, v.max);
}

function rollOffOf(preset) {
  return preset.rollOff || DefaultRollOff[preset.bus] || { min: 8, max: 120 };
}

function isBed(layer) {
  return layer.looped === true && layer.duration === undefined;
}

export function isLoopedPreset(preset) {
  return preset.looped === true || preset.layers.some(isBed);
}

/**
 * A playing preset.
 */
class Voice {
  constructor(audio, name, preset, opts) {
    this.audio = audio;
    this.name = name;
    this.preset = preset;
    this.bus = opts.bus || preset.bus;
    this.priority = preset.priority ?? 50;
    this.volume = opts.volume ?? 1;
    this.speed = opts.speed ?? 1;
    this.looped = opts.loop ?? isLoopedPreset(preset);
    this.position = opts.position ? opts.position.clone() : null;
    this.follow = opts.follow || null;
    this.rollOff = rollOffOf(preset);
    this.rng = new Random(opts.seed ?? Math.floor(Math.random() * 1e9));
    this.startedAt = audio.ctx.currentTime;
    this.playing = true;
    this.stopping = false;
    this.ended = new Signal();
    /** @type {Array<{node: GainNode, panner: PannerNode|null, group: any}>} */
    this.layerIns = [];
    /** @type {Set<AudioBufferSourceNode>} */
    this.sources = new Set();
    this.nextCycleAt = null;
    this.fadeGain = 0;
    this.dist = 1;
    this._lastEnd = audio.ctx.currentTime;
  }

  get time() {
    return this.audio.ctx.currentTime - this.startedAt;
  }

  /** Fades the voice out over `fade` seconds and ends it. */
  stop(fade = 0.05) {
    if (!this.playing || this.stopping) return;
    this.stopping = true;
    const ctx = this.audio.ctx;
    const end = ctx.currentTime + Math.max(0.01, fade);
    for (const li of this.layerIns) {
      li.node.gain.cancelScheduledValues(ctx.currentTime);
      li.node.gain.setValueAtTime(li.node.gain.value, ctx.currentTime);
      li.node.gain.linearRampToValueAtTime(0, end);
    }
    for (const s of this.sources) {
      try {
        s.stop(end + 0.02);
      } catch { /* not started */ }
    }
    setTimeout(() => this._finish(), (fade + 0.1) * 1000);
  }

  /** Eases the voice volume to `volume` over `fade` seconds. */
  setVolume(volume, fade = 0.1) {
    this.volume = volume;
    this._applyGain(fade);
  }

  setPosition(position) {
    if (!this.position) this.position = position.clone();
    else this.position.copy(position);
  }

  _gain() {
    return this.volume * (this.position || this.follow ? this.dist : 1);
  }

  _applyGain(fade) {
    if (this.stopping) return;
    const ctx = this.audio.ctx;
    const g = this._gain();
    for (const li of this.layerIns) ramp(ctx, li.node.gain, g, fade);
  }

  _finish() {
    if (!this.playing) return;
    this.playing = false;
    for (const s of this.sources) {
      try {
        s.stop();
      } catch { /* already */ }
      s.disconnect();
    }
    this.sources.clear();
    for (const li of this.layerIns) {
      li.node.disconnect();
      if (li.panner) li.panner.disconnect();
      this.audio._releaseGroup(li.group);
    }
    this.layerIns.length = 0;
    this.audio._removeVoice(this);
    this.ended.fire();
  }
}

export class Audio {
  /**
   * @param {{settings: import('../settings.js').Settings, context?: BaseAudioContext}} deps `context` replaces the
   *   live AudioContext (an OfflineAudioContext renders presets for verification)
   */
  constructor(deps) {
    this.settings = deps.settings;
    /** @type {Signal<[string, string]>} (caption text, preset) */
    this.captioned = new Signal();
    this.ready = false;
    this.voices = [];
    this.groups = new Map();
    this.reverbCount = 0;
    this.environment = 'Room';
    this.envOverrides = new Map();
    this.zoneEnvironment = 'Room';
    this.bedName = null;
    this.bedVoice = null;
    this.stingerTimes = [];
    this.listener = { x: 0, y: 0, z: 0 };
    this.stingerRng = new Random(20251029);
    try {
      const Ctx = window.AudioContext || window.webkitAudioContext;
      this.ctx = deps.context || new Ctx({ latencyHint: 'interactive' });
    } catch (err) {
      console.warn('[audio] WebAudio unavailable', err);
      this.ctx = null;
      return;
    }
    this._buildMixer();
    this.samples = buildSamples(this.ctx);
    this.ready = true;
    this.settings.changed.connect((key) => {
      if (Object.values(SETTING_KEYS).includes(key)) this._applyVolumes(0.1);
    });
    this._applyVolumes(0);
    if (!deps.context) {
      const resume = () => this.resume();
      for (const ev of ['pointerdown', 'keydown', 'touchstart']) window.addEventListener(ev, resume, { passive: true });
    }
  }

  /** Resumes the context (browsers start it suspended until a gesture). */
  resume() {
    if (this.ctx && this.ctx.state === 'suspended') this.ctx.resume().catch(() => {});
  }

  _buildMixer() {
    const ctx = this.ctx;
    this.master = ctx.createGain();
    const comp = ctx.createDynamicsCompressor();
    comp.threshold.value = -6;
    comp.ratio.value = 8;
    comp.attack.value = 0.003;
    comp.release.value = 0.15;
    this.master.connect(comp).connect(ctx.destination);
    this.room = ctx.createGain();
    const env = Environments.Room;
    this.envChain = buildChain(ctx, env.effects);
    this.room.connect(this.envChain.input);
    this.envChain.output.connect(this.master);
    this.reverbCount += this.envChain.reverbs;
    this.buses = {};
    this.duck = {};
    this.ducks = {};
    for (const b of BUSES) {
      const user = ctx.createGain();
      const duck = ctx.createGain();
      this.buses[b] = user;
      this.duck[b] = duck;
      this.ducks[b] = [];
      user.connect(duck);
      if (ROOM_BUSES.has(b)) duck.connect(this.room);
      else if (b === 'Ambience' || b === 'Body') {
        const eq = buildChain(ctx, [env[b === 'Ambience' ? 'ambience' : 'body']]);
        duck.connect(eq.input);
        eq.output.connect(this.master);
        this[`${b.toLowerCase()}Eq`] = eq;
      } else duck.connect(this.master);
    }
  }

  _applyVolumes(fade) {
    if (!this.ctx) return;
    ramp(this.ctx, this.master.gain, (this.settings.get('MasterVolume') ?? 1) * 0.8, fade);
    for (const b of BUSES) ramp(this.ctx, this.buses[b].gain, this.settings.get(SETTING_KEYS[b]) ?? 1, fade);
  }

  // ------------------------------------------------------------------ environment

  /** Eases the room acoustics to an AcousticPreset (Room, Corridor, Hall, Vent, Underwater, Outdoor, Stairwell, Basement, Lobby). */
  setEnvironment(name, fade = ENV_FADE) {
    if (!this.ctx) return;
    const spec = Environments[name] || Environments.Room;
    if (name === this.environment) return;
    this.environment = name;
    spec.effects.forEach((e, i) => {
      const slot = this.envChain.slots[i];
      if (slot) slot.set(e.props, fade);
    });
    if (this.ambienceEq) this.ambienceEq.slots[0].set(spec.ambience.props, fade);
    if (this.bodyEq) this.bodyEq.slots[0].set(spec.body.props, fade);
    ramp(this.ctx, this.room.gain, spec.gain, fade);
  }

  /** A later system's environment (vent transitions, cutscenes); the newest token wins; null releases. */
  setEnvironmentOverride(token, name) {
    if (name) this.envOverrides.set(token, name);
    else this.envOverrides.delete(token);
    this._refreshEnvironment();
  }

  /** The room / move-state environment (the engine sets it from the listener's zone). */
  setZoneEnvironment(name) {
    this.zoneEnvironment = name || 'Outdoor';
    this._refreshEnvironment();
  }

  _refreshEnvironment() {
    let name = this.zoneEnvironment;
    for (const v of this.envOverrides.values()) name = v;
    this.setEnvironment(name, ENV_FADE);
  }

  // ------------------------------------------------------------------ groups

  /** The shared effect group for `key` (created idle on first use; a child group holds its parent). */
  _ensureGroup(key, effects, destination) {
    let g = this.groups.get(key);
    if (g) return g;
    let chainEffects = effects || [];
    const reverbs = chainEffects.filter((e) => e.kind === 'Reverb').length;
    if (reverbs && this.reverbCount + reverbs > MAX_REVERBS) {
      this._cutIdleReverbs();
      if (this.reverbCount + reverbs > MAX_REVERBS) chainEffects = chainEffects.filter((e) => e.kind !== 'Reverb');
    }
    const chain = buildChain(this.ctx, chainEffects);
    const parent = destination && destination.isGroup ? destination : null;
    chain.output.connect(parent ? parent.input : destination);
    this.reverbCount += chain.reverbs;
    g = { isGroup: true, key, chain, users: 0, idleSince: this.ctx.currentTime, input: chain.input, parent };
    if (parent) this._useGroup(parent);
    this.groups.set(key, g);
    return g;
  }

  _useGroup(g) {
    g.users++;
    g.idleSince = null;
  }

  _releaseGroup(g) {
    if (!g) return;
    g.users--;
    if (g.users <= 0) {
      g.users = 0;
      g.idleSince = this.ctx.currentTime;
    }
  }

  _cutIdleReverbs() {
    for (const g of [...this.groups.values()]) {
      if (g.users <= 0 && g.chain.reverbs > 0) this._freeGroup(g);
    }
  }

  _freeGroup(g) {
    g.chain.stop();
    try {
      g.chain.output.disconnect();
      g.chain.input.disconnect();
    } catch { /* already */ }
    this.reverbCount -= g.chain.reverbs;
    this.groups.delete(g.key);
    if (g.parent) this._releaseGroup(g.parent);
  }

  // ------------------------------------------------------------------ voices

  /**
   * Plays a preset. Returns a voice handle ({stop(fade), setVolume(v, fade), setPosition(p), playing, ended}) or null
   * when it was culled / refused.
   * @param {string} name SynthPresets name
   * @param {{position?: import('three').Vector3, follow?: () => import('three').Vector3, volume?: number,
   *   loop?: boolean, speed?: number, fadeIn?: number, bus?: string, seed?: number}} [opts]
   */
  play(name, opts = {}) {
    if (!this.ready) return null;
    const preset = Presets[name];
    if (!preset) {
      console.warn('[audio] unknown preset', name);
      return null;
    }
    const ctx = this.ctx;
    const rollOff = rollOffOf(preset);
    const looped = opts.loop ?? isLoopedPreset(preset);
    if (opts.position && !looped && this._distance(opts.position) > rollOff.max) return null;
    if (!this._admit(name, preset, opts.bus || preset.bus, looped)) return null;
    const voice = new Voice(this, name, preset, { ...opts, loop: looped });
    if (opts.follow) voice.position = opts.follow().clone();
    if (voice.position) voice.dist = attenuation(this._distance(voice.position), rollOff);
    const busNode = this.buses[voice.bus] || this.buses.World;
    const spaceDest = preset.space && preset.space.length
      ? this._ensureGroup(`${name}#space`, preset.space, busNode)
      : busNode;
    const fadeIn = opts.fadeIn || 0;
    preset.layers.forEach((layer, index) => {
      const group = this._ensureGroup(`${name}#${index}`, layer.effects, spaceDest);
      this._useGroup(group);
      const node = ctx.createGain();
      let panner = null;
      if (voice.position) {
        panner = ctx.createPanner();
        panner.panningModel = 'equalpower';
        panner.distanceModel = 'linear';
        panner.rolloffFactor = 0;
        panner.positionX.value = voice.position.x;
        panner.positionY.value = voice.position.y;
        panner.positionZ.value = voice.position.z;
        node.connect(panner).connect(group.input);
      } else node.connect(group.input);
      const g = voice._gain();
      if (fadeIn > 0) {
        node.gain.setValueAtTime(0, ctx.currentTime);
        node.gain.linearRampToValueAtTime(g, ctx.currentTime + fadeIn);
      } else node.gain.value = g;
      voice.layerIns.push({ node, panner, group });
    });
    this.voices.push(voice);
    this._schedule(voice, 0, true);
    if (preset.duck) for (const d of preset.duck) this._duck(d);
    if (preset.captionText) this.captioned.fire(preset.captionText, name);
    if (!looped) {
      const end = Math.max(voice._lastEnd - ctx.currentTime, 0.05);
      setTimeout(() => voice._finish(), (end + 0.15) * 1000);
    }
    return voice;
  }

  _admit(name, preset, bus, looped) {
    const same = this.voices.filter((v) => v.name === name && !v.stopping);
    if (same.length >= (preset.maxVoices || 4)) {
      const victim = same.find((v) => !v.looped) || (looped ? same[0] : null);
      if (!victim) return false;
      victim.stop(0.06);
    }
    const onBus = this.voices.filter((v) => v.bus === bus && !v.stopping);
    if (onBus.length >= (CAPS[bus] || 12)) {
      const prio = preset.priority ?? 50;
      const victims = onBus.filter((v) => v.priority <= prio)
        .sort((a, b) => a.priority - b.priority || a._gain() - b._gain() || a.startedAt - b.startedAt);
      if (!victims.length) return false;
      victims[0].stop(0.06);
    }
    return true;
  }

  _removeVoice(v) {
    const i = this.voices.indexOf(v);
    if (i >= 0) this.voices.splice(i, 1);
  }

  /** Schedules a voice's layer triggers from voice time `from` (initial: beds too). */
  _schedule(voice, from, initial) {
    const preset = voice.preset;
    const base = voice.startedAt + from;
    preset.layers.forEach((layer, index) => {
      if (isBed(layer)) {
        if (initial) this._grain(voice, layer, index, base + (layer.delay || 0), true);
        return;
      }
      if (layer.chance !== undefined && voice.rng.next() >= layer.chance) return;
      let at = base + (layer.delay || 0) + (layer.delayJitter ? voice.rng.nextNumber(0, layer.delayJitter) : 0);
      const count = layer.grains ? Math.round(pick(voice.rng, layer.grains.count)) : 1;
      for (let k = 0; k < Math.max(1, count); k++) {
        this._grain(voice, layer, index, at, false);
        if (layer.grains) at += pick(voice.rng, layer.grains.spacing);
      }
    });
    if (voice.looped && preset.repeat) {
      const r = preset.repeat;
      voice.nextCycleAt = from + r.interval + (r.jitter ? voice.rng.nextNumber(-r.jitter, r.jitter) : 0);
    }
  }

  /** One grain of a layer at context time `when`. */
  _grain(voice, layer, index, when, bed) {
    const ctx = this.ctx;
    const buffer = this.samples[layer.sample];
    if (!buffer) return;
    const length = buffer.duration;
    const estimate = SampleLengths[layer.sample] || length;
    const rng = voice.rng;
    const rate = Math.max(0.02, Math.min(20, pick(rng, layer.speed) * voice.speed * pitchOf(layer.effects)));
    let volume = layer.volume * ROBLOX_VOLUME;
    if (layer.volumeJitter) volume *= 1 + rng.nextNumber(-layer.volumeJitter, layer.volumeJitter);
    const src = ctx.createBufferSource();
    src.buffer = buffer;
    src.playbackRate.value = rate;
    let start = 0;
    let end = length;
    if (layer.region) {
      const scale = estimate > 0 && layer.region.max > length ? length / Math.max(estimate, layer.region.max) : 1;
      let a = Math.max(0, Math.min(layer.region.min, layer.region.max) * scale);
      let b = Math.max(layer.region.min, layer.region.max) * scale;
      if (layer.regionJitter) {
        const j = rng.nextNumber(-layer.regionJitter, layer.regionJitter);
        a += j;
        b += j;
      }
      b = Math.min(Math.max(b, MIN_REGION), length);
      a = Math.min(Math.max(0, a), b - MIN_REGION);
      start = a;
      end = b;
    }
    const looped = !!layer.looped;
    if (looped) {
      src.loop = true;
      if (layer.region || !Seamless.has(layer.sample)) {
        src.loopStart = start;
        src.loopEnd = end;
      }
    }
    const offset = Math.min(end - MIN_REGION, start + (layer.timePosition || 0) % Math.max(end - start, MIN_REGION));
    const env = ctx.createGain();
    const e = layer.envelope;
    const attack = e ? Math.max(0.001, e.attack) : 0.002;
    const release = e ? Math.max(0.005, e.release) : 0.02;
    const t0 = Math.max(when, ctx.currentTime);
    env.gain.setValueAtTime(0, t0);
    env.gain.linearRampToValueAtTime(volume, t0 + attack);
    let natural = looped ? Infinity : (end - offset) / rate;
    let cut = layer.duration !== undefined ? layer.duration : null;
    if (e && e.hold !== undefined) cut = Math.min(cut ?? Infinity, attack + e.hold);
    let stopAt = null;
    if (cut !== null && cut < natural) {
      env.gain.setValueAtTime(volume, t0 + Math.max(attack, cut));
      env.gain.linearRampToValueAtTime(0, t0 + Math.max(attack, cut) + release);
      stopAt = t0 + Math.max(attack, cut) + release + 0.01;
    } else if (Number.isFinite(natural)) {
      const tail = Math.min(release, natural * 0.3);
      env.gain.setValueAtTime(volume, t0 + Math.max(attack, natural - tail));
      env.gain.linearRampToValueAtTime(0, t0 + natural);
      stopAt = t0 + natural + 0.01;
    }
    if (layer.glide) {
      src.playbackRate.setValueAtTime(rate, t0);
      src.playbackRate.linearRampToValueAtTime(Math.max(0.02, rate * layer.glide.to), t0 + Math.max(0.01, layer.glide.time));
    }
    const li = voice.layerIns[index];
    if (!li) return;
    src.connect(env).connect(li.node);
    src.start(t0, offset);
    if (stopAt !== null) src.stop(stopAt);
    voice.sources.add(src);
    src.onended = () => {
      voice.sources.delete(src);
      env.disconnect();
    };
    if (!bed && stopAt !== null) voice._lastEnd = Math.max(voice._lastEnd, stopAt + (li.group.chain.tail || 0));
  }

  _duck(d) {
    const node = this.duck[d.bus];
    if (!node) return;
    const ctx = this.ctx;
    const t = ctx.currentTime;
    node.gain.cancelScheduledValues(t);
    node.gain.setValueAtTime(node.gain.value, t);
    node.gain.linearRampToValueAtTime(d.gain, t + d.attack);
    node.gain.setValueAtTime(d.gain, t + d.attack + d.hold);
    node.gain.linearRampToValueAtTime(1, t + d.attack + d.hold + d.release);
  }

  _distance(p) {
    const dx = p.x - this.listener.x;
    const dy = p.y - this.listener.y;
    const dz = p.z - this.listener.z;
    return Math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  // ------------------------------------------------------------------ ambience

  /** Crossfades the ambience bed (a Drone preset, or UnderwaterBed; null = silence) and its stingers. */
  setAmbience(name, fade = BED_FADE) {
    if (name === this.bedName) return;
    this.bedName = name;
    if (this.bedVoice) this.bedVoice.stop(fade);
    this.bedVoice = name ? this.play(name, { loop: true, fadeIn: fade }) : null;
    const stingers = (name && Beds[name]) || [];
    const now = this.ctx ? this.ctx.currentTime : 0;
    this.stingerTimes = stingers.map((s) => now + this.stingerRng.nextNumber(s.interval.min, s.interval.max));
  }

  /** Per frame: listener, 3D voices, looped re-triggers, stingers, idle groups. */
  update(dt, position, forward, up) {
    if (!this.ready) return;
    const ctx = this.ctx;
    const L = ctx.listener;
    this.listener.x = position.x;
    this.listener.y = position.y;
    this.listener.z = position.z;
    if (L.positionX) {
      const t = ctx.currentTime;
      L.positionX.setTargetAtTime(position.x, t, 0.02);
      L.positionY.setTargetAtTime(position.y, t, 0.02);
      L.positionZ.setTargetAtTime(position.z, t, 0.02);
      L.forwardX.setTargetAtTime(forward.x, t, 0.02);
      L.forwardY.setTargetAtTime(forward.y, t, 0.02);
      L.forwardZ.setTargetAtTime(forward.z, t, 0.02);
      L.upX.setTargetAtTime(up.x, t, 0.02);
      L.upY.setTargetAtTime(up.y, t, 0.02);
      L.upZ.setTargetAtTime(up.z, t, 0.02);
    } else if (L.setPosition) {
      L.setPosition(position.x, position.y, position.z);
      L.setOrientation(forward.x, forward.y, forward.z, up.x, up.y, up.z);
    }
    const now = ctx.currentTime;
    for (const v of this.voices.slice()) {
      if (!v.playing || v.stopping) continue;
      if (v.follow) {
        const p = v.follow();
        if (p) v.setPosition(p);
      }
      if (v.position) {
        const dist = attenuation(this._distance(v.position), v.rollOff);
        if (Math.abs(dist - v.dist) > 0.01) {
          v.dist = dist;
          v._applyGain(0.05);
        }
        for (const li of v.layerIns) {
          if (!li.panner) continue;
          li.panner.positionX.setTargetAtTime(v.position.x, now, 0.03);
          li.panner.positionY.setTargetAtTime(v.position.y, now, 0.03);
          li.panner.positionZ.setTargetAtTime(v.position.z, now, 0.03);
        }
      }
      if (v.looped && v.nextCycleAt !== null && v.time + LOOKAHEAD >= v.nextCycleAt) {
        const at = v.nextCycleAt;
        v.nextCycleAt = null;
        this._schedule(v, at, false);
      }
    }
    // stingers
    if (this.bedName && Beds[this.bedName]) {
      const list = Beds[this.bedName];
      for (let i = 0; i < list.length; i++) {
        if (now < this.stingerTimes[i]) continue;
        const s = list[i];
        this.stingerTimes[i] = now + this.stingerRng.nextNumber(s.interval.min, s.interval.max);
        let pos;
        if (s.distance) {
          const a = this.stingerRng.nextNumber(0, Math.PI * 2);
          const d = this.stingerRng.nextNumber(s.distance.min, s.distance.max);
          pos = new Vector3(position.x + Math.cos(a) * d, position.y + STINGER_HEIGHT, position.z + Math.sin(a) * d);
        }
        this.play(s.preset, { position: pos, volume: s.volume ?? 1 });
      }
    }
    for (const g of this.groups.values()) {
      if (g.users <= 0 && g.idleSince !== null && now - g.idleSince > g.chain.tail + RELEASE_SLACK) this._freeGroup(g);
    }
  }

  /** Stops every voice (optionally only one bus). */
  stopAll(fade = 0.3, bus = null) {
    for (const v of this.voices.slice()) if (!bus || v.bus === bus) v.stop(fade);
  }

  /** Every preset name. */
  get presetNames() {
    return Object.keys(Presets);
  }
}

export { Presets, Beds, Environments, dbToGain };
