// Audio: the WebAudio port of SoundSynthesizer + VoicePool + AudioBuses + AudioController.
//
// Mixer (AudioBuses). Master (safety compressor, then a ceiling under -1.1 dBFS) <- Ambience (EQ) | Room (the environment chain: EQ -> Chorus ->
// Reverb -> Echo, gain) <- World / Monster / Player | Body (EQ) | UI. User volumes come from the settings (Body follows
// Player); presets duck other buses while they play. setEnvironment(preset) eases every slot of the chain (and the
// Ambience / Body EQs) to that AcousticPreset's values; the room the listener stands in picks it (a vent -> Vent,
// outside every room -> Outdoor), setEnvironmentOverride wins over both.
//
// Voices. play(name, opts) plays the preset `name`: its bus, roll-off, priority, voice limit, ducking and caption are
// the preset's (SynthPresets); what sounds is
//   * the name's recorded file when the sound bank has one (bank.js: web/sounds renders every sound from recordings):
//     one of its variants (never the same twice in a row), looped between its loop points when the voice loops, at the
//     voice's volume, straight into the bus; a file not decoded yet is decoded at once and starts when it is there;
//   * else the preset's layer recipe (SoundSynthesizer): every layer trigger is a grain (an AudioBufferSource on one
//     of the 11 synthesized sources) with the recipe's speed / region slice / jitter / envelope / glide / grains /
//     chance; each layer's effect chain is a shared group per preset layer (and an optional preset `space` group)
//     that outlives its grains by the chain's tail, so reverbs and echoes ring out. Looped voices keep their bed
//     layers running and re-trigger the other layers every `repeat` interval. So no name is ever silent.
// Either way 3D voices pan with the listener and attenuate InverseTapered between rollOff.min and rollOff.max (culled
// beyond it). Bus caps (Monster 6, World 16, Ambience 8, Player 12, Body 6, UI 6) and each preset's maxVoices hold,
// with priority stealing. Captioned presets fire `captioned` (the HUD shows it when captions are on).
//
// Ambience (AudioController). setAmbience(bed) crossfades the level drone and scatters its stingers (SynthPresets
// Beds) around the listener at seeded random intervals.

import { Presets, Beds, DefaultRollOff, Environments } from './presets.js';
import { buildSamples, SampleLengths, Seamless } from './samples.js';
import { buildChain, pitchOf, prewarmReverbs, ramp, dbToGain } from './effects.js';
import { attenuation } from './rolloff.js';
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
/** A one-shot whose file was still being decoded when it was asked for plays if it is there within this (seconds). */
const LATE = 0.3;
/** The output never peaks over this (-1.1 dBFS): the last stage after the safety compressor (never painful on earbuds). */
const CEILING = 0.88;
/** Under this the ceiling's curve is a straight line (the mix untouched); over it, it bends smoothly to CEILING. */
const CEILING_KNEE = 0.6;

/** The ceiling's transfer curve: unity under the knee, a tanh shoulder up to CEILING at full scale and beyond. */
function ceilingCurve(points = 4097) {
  const curve = new Float32Array(points);
  const room = CEILING - CEILING_KNEE;
  for (let i = 0; i < points; i++) {
    const x = (2 * i) / (points - 1) - 1;
    const a = Math.abs(x);
    const y = a <= CEILING_KNEE ? a : CEILING_KNEE + room * Math.tanh((a - CEILING_KNEE) / room);
    curve[i] = Math.sign(x) * y;
  }
  return curve;
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
    /** the sound bank's entry when the voice plays its recorded file (null: the preset's recipe) */
    this.file = null;
    /** the variant every client picks (opts.seed), or null: any but the last */
    this.pick = null;
    /** whether the bank holds this voice's file while it plays */
    this.held = false;
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
    if (this.held) this.audio.bank.hold(this.name, -1);
    this.held = false;
    this.audio._removeVoice(this);
    this.ended.fire();
  }
}

export class Audio {
  /**
   * @param {{settings: import('../settings.js').Settings, context?: BaseAudioContext,
   *   bank?: import('./bank.js').SoundBank}} deps `context` replaces the live AudioContext (an OfflineAudioContext
   *   renders voices for verification); `bank`: the recorded sounds (without one every name plays its recipe)
   */
  constructor(deps) {
    this.settings = deps.settings;
    /** @type {import('./bank.js').SoundBank|null} the recorded sounds (useBank) */
    this.bank = deps.bank || null;
    /** @type {Signal<[string, string]>} (caption text, preset) */
    this.captioned = new Signal();
    this.ready = false;
    this.voices = [];
    this.pausedMix = false;
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
      // the rooms' reverbs prepared in idle time, so walking into a new acoustic space never hitches the frame
      prewarmReverbs(this.ctx, Object.values(Environments).flatMap((env) => (env.effects || []).filter((e) => e.kind === 'Reverb')
        .map((e) => e.props || {})));
      const resume = () => this.resume();
      for (const ev of ['pointerdown', 'keydown', 'touchstart']) window.addEventListener(ev, resume, { passive: true });
    }
  }

  /** The recorded sounds: from now on a name the bank has plays its file. */
  useBank(bank) {
    this.bank = bank;
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
    // the compressor's automatic makeup gain can lift a peak over full scale: a waveshaper with a soft shoulder
    // holds every sample under CEILING (it passes input clamped to +-1 as +-CEILING)
    const ceiling = ctx.createWaveShaper();
    ceiling.curve = ceilingCurve();
    ceiling.oversample = 'none';
    this.master.connect(comp).connect(ceiling).connect(ctx.destination);
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
    for (const b of BUSES) {
      const hush = this.pausedMix && b !== 'UI' ? 0 : 1;
      ramp(this.ctx, this.buses[b].gain, (this.settings.get(SETTING_KEYS[b]) ?? 1) * hush, fade);
    }
  }

  /**
   * The pause menu: the game's buses fade out (a crawl loop or the Creature's steps no longer
   * play on under a frozen game) and back in on resume; the menu's own UI sounds keep playing.
   */
  setPausedMix(on) {
    if (!!on === !!this.pausedMix) return;
    this.pausedMix = !!on;
    this._applyVolumes(0.15);
  }

  // ------------------------------------------------------------------ environment

  /** Eases the room acoustics to an AcousticPreset (Room, Corridor, Hall, Vent, Outdoor, Stairwell, Basement, Lobby). */
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
    const fadeIn = opts.fadeIn || 0;
    const file = this.bank ? this.bank.entry(name) : null;
    if (file) {
      // the recorded file, straight into the bus (its body and space are in the recording)
      voice.file = file;
      voice.pick = Number.isInteger(opts.seed) ? opts.seed : null;
      this._input(voice, busNode, null, fadeIn);
    } else {
      const spaceDest = preset.space && preset.space.length
        ? this._ensureGroup(`${name}#space`, preset.space, busNode)
        : busNode;
      preset.layers.forEach((layer, index) => {
        const group = this._ensureGroup(`${name}#${index}`, layer.effects, spaceDest);
        this._useGroup(group);
        this._input(voice, group.input, group, fadeIn);
      });
    }
    this.voices.push(voice);
    if (file) this._startFile(voice);
    else this._schedule(voice, 0, true);
    if (preset.duck) for (const d of preset.duck) this._duck(d);
    if (preset.captionText) this.captioned.fire(preset.captionText, name);
    if (!looped && !file) {
      const end = Math.max(voice._lastEnd - ctx.currentTime, 0.05);
      setTimeout(() => voice._finish(), (end + 0.15) * 1000);
    }
    return voice;
  }

  /** One input of a voice (its gain, and its panner when it is placed) into `destination`. */
  _input(voice, destination, group, fadeIn) {
    const ctx = this.ctx;
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
      node.connect(panner).connect(destination);
    } else node.connect(destination);
    const g = voice._gain();
    if (fadeIn > 0) {
      node.gain.setValueAtTime(0, ctx.currentTime);
      node.gain.linearRampToValueAtTime(g, ctx.currentTime + fadeIn);
    } else node.gain.value = g;
    voice.layerIns.push({ node, panner, group });
  }

  /** Starts a file voice now, or as soon as its file is decoded (a one-shot only if that is soon enough). */
  _startFile(voice) {
    const begin = () => {
      if (!voice.playing || voice.stopping) return;
      this.bank.hold(voice.name, 1);
      voice.held = true;
      this._fileGrain(voice, this.ctx.currentTime);
    };
    if (this.bank.decoded.has(voice.name)) {
      begin();
      return;
    }
    const asked = this.ctx.currentTime;
    this.bank.load(voice.name).then((buffers) => {
      if (buffers && (voice.looped || this.ctx.currentTime - asked <= LATE)) begin();
      else voice._finish();
    });
  }

  /**
   * One play of a file voice's recording at context time `when`: a loop runs between its loop points; a looped voice
   * of a one-shot recording plays it again every `repeat` interval (a pulse: a heartbeat, a drip), each time another
   * variant; anything else plays once and ends the voice.
   */
  _fileGrain(voice, when) {
    const buffer = this.bank.take(voice.name, voice.pick);
    if (!buffer) {
      voice._finish();
      return;
    }
    const ctx = this.ctx;
    const src = ctx.createBufferSource();
    src.buffer = buffer;
    src.playbackRate.value = Math.max(0.02, Math.min(20, voice.speed));
    const loop = voice.file.l;
    const repeat = voice.preset.repeat;
    const t0 = Math.max(when, ctx.currentTime);
    src.connect(voice.layerIns[0].node);
    if (voice.looped && (loop || !repeat)) {
      src.loop = true;
      if (loop) {
        src.loopStart = loop[0];
        src.loopEnd = loop[1];
      }
      src.start(t0, loop ? loop[0] : 0);
    } else if (loop) src.start(t0, loop[0], loop[1] - loop[0]);
    else src.start(t0);
    voice.sources.add(src);
    src.onended = () => {
      voice.sources.delete(src);
      src.disconnect();
      if (!voice.looped && voice.sources.size === 0) voice._finish();
    };
    if (voice.looped && !loop && repeat) {
      voice.nextCycleAt = t0 - voice.startedAt + repeat.interval + (repeat.jitter ? voice.rng.nextNumber(-repeat.jitter, repeat.jitter) : 0);
    }
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

  /** Schedules a voice's layer triggers from voice time `from` (initial: beds too); a file voice's next pulse. */
  _schedule(voice, from, initial) {
    if (voice.file) {
      this._fileGrain(voice, voice.startedAt + from);
      return;
    }
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

  /** Crossfades the ambience bed (a Drone preset; null = silence) and its stingers. */
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

  /** Every name on the old path: a preset the sound bank has no recorded file for (it plays its recipe). */
  get recipeNames() {
    return Object.keys(Presets).filter((name) => !this.bank || !this.bank.has(name)).sort();
  }
}

export { Presets, Beds, Environments, attenuation, dbToGain };
