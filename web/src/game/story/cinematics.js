// cinematics.js: the cutscene player (docs/design/game-spec-v2.md 2.3, the one contract for all five cutscenes; I7,
// I8, I13), over StoryConfig's timelines (world.json meta.storyConfig) sampled by the port of CinematicTracks
// (rules/tracks.js).
//
// Playing. The authority (alone: this page; in a squad: the host) calls play(id, {onEnd}): the cut (Short once every
// member has seen the Full one and none asked for Full on replays, CinematicTracks.cutFor), the cast (the squad's slots
// in the seeded StoryCast order: P1, P2, ...), a start quantised to the next tick; it tells the squad ({t: 'storyPlay'}:
// the cut, the cast and how far into the timeline the host is, so a late page fast-forwards and a joiner sees it from
// its current time) and plays it here; once a second it says where it is ({t: 'storySync'}), and a page more than a
// tick off (a clock running behind under load) moves its start to match. Every page then runs the same timeline on its own clock: t = the ticks since
// the start / 30, so every pose is a function of the tick alone (I8: the same at 20 and 144 fps).
// What a page does with it:
//   * Control: a Cutscene lock and the Cutscene input context from the start (only Skip answers), the HUD hidden (its
//     sound captions kept, above the subtitles), the ambient storm off (the timeline's own weather only: its Rain, its
//     sounds); the Cinematic camera state (a camera override along the camera track)
//     while a shot's view is Cinematic, the page's own eye while it is Own; letterbox bars of Letterbox each; nobody
//     can be caught, downed or killed (I13: the catch hook and the lives refuse while one plays).
//   * Actors (story/actors.js): the cast in costume, the squad as themselves, the crawler, props; the Creature as the
//     Monster actor (the authority holds it through acquireScripted; a client sees the host's).
//   * Events: Sound (3D at its place, or at a party actor's bin), Shake (x MotionScale), Light (the scripted light
//     groups: Off / On / Flicker / Stutter), Prop (each scene registers its props' handlers: onProp), Rig (the actor's
//     rig swaps), Rain, Fade, Card; the day (renderer.setDay). Lines: each page composes its own text (names filled per
//     page: {you} is this page's player; the nameless twin when names are off or missing; solo skips the lines that
//     need P2), speaks it (engine/audio/tts.js; the monster's only with "Voice and subtitles"), ends it at its slot,
//     and shows its subtitle (ui/subtitles.js) for the slot.
//   * The skip vote (story/skipVote.js): a pass fades everyone to the last shot over Skip.Fade ({t: 'storySkip'}).
//   * Leaving and joining: a leaver's actor stays until the next cut, then is hidden; a joiner gets the timeline from
//     its current time.
//   * The end (the hand-over): the bars and the camera go, the lock is released, the scene's onEnd runs; the page marks
//     the cutscene seen (profile CutscenesSeen) when its Full cut played to the end or this player voted it away.
//
// To stage a new cutscene a package writes its timeline in StoryConfig (camera keys, actor tracks, events, lines:
// the data is the whole cutscene), registers the props its events name (cinematics.onProp(id, fn(state, args))), and
// calls cinematics.play(id, {onEnd}) on the authority at its moment; everything else is here.

import * as THREE from 'three';
import { Speech } from '../../engine/audio/tts.js';
import { nameRules } from '../rules/names.js';
import { cinematicTracks, items } from '../rules/tracks.js';
import { Subtitles } from '../ui/subtitles.js';
import { Fonts, Palette, el } from '../ui/style.js';
import { Actors } from './actors.js';
import { SkipVote } from './skipVote.js';
import { registerStorySounds } from './sounds.js';

const CAMERA_TOKEN = 'Cinematic';
const CAMERA_PRIORITY = 5;
const CONTEXT = 'Story';
const LOCK = 'Cutscene';
const EAR_VOLUME = 0.8;
const PA_VOLUME = 0.7;
/** a card fades in and out over this, or over a quarter of its length when that is shorter (it always holds) */
const CARD_FADE = 0.4;
const STUTTER_HZ = 14;
/** how often the host tells the squad where the timeline is (seconds) */
const SYNC_EVERY = 1;

const isNumber = (v) => typeof v === 'number' && Number.isFinite(v);

export class Cinematics {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Cinematics';
    this.game = game;
    this.env = game.env;
    const meta = game.world.meta;
    this.tracks = cinematicTracks(meta);
    this.names = nameRules(meta);
    this.story = this.tracks.story;
    this.tickSeconds = 1 / this.story.TickRate;
    registerStorySounds();
    this.actors = new Actors(game);
    this.skip = new SkipVote(this);
    this.speech = new Speech(this.env.engine.audio);
    this.subtitles = new Subtitles(game);
    /** @type {any} the cutscene playing here (null when none) */
    this.current = null;
    /** @type {Map<string, (state: string, args: any) => void>} the scenes' props, by id */
    this.propHandlers = new Map();
    /** @type {Map<string, (reason: string) => void>} the scenes' hand-overs, by timeline id (every page's) */
    this.endHandlers = new Map();
    this.runs = 0;
    /** a client's cutscene waiting for this page's stage (the host's word came while it was still deploying, or a
     * joiner's welcome): played by joinPending */
    this.pendingJoin = null;
    this.camera = { position: new THREE.Vector3(), lookAt: new THREE.Vector3(), fov: 60 };
    /** the anchors of the CutsceneMarks, by id */
    this.marks = new Map();
    for (const a of meta.anchors || []) if (a.kind === 'CutsceneMark') this.marks.set(a.id, a);
    /** BinStart anchors by slot (the party actors' bins) */
    this.bins = new Map();
    for (const a of meta.anchors || []) if (a.kind === 'BinStart') this.bins.set(Number(a.attributes && a.attributes.Slot), a);
    this._buildUi();
  }

  _buildUi() {
    const root = this.env.uiRoot();
    this.ui = el('div', 'rg-layer', root);
    this.ui.style.zIndex = '40';
    this.ui.style.display = 'none';
    const bar = (top) => {
      const b = el('div', '', this.ui);
      Object.assign(b.style, { position: 'absolute', left: '0', right: '0', height: '0', background: '#000',
        [top ? 'top' : 'bottom']: '0' });
      return b;
    };
    this.barTop = bar(true);
    this.barBottom = bar(false);
    this.black = el('div', '', this.ui);
    Object.assign(this.black.style, { position: 'absolute', inset: '0', background: '#000', opacity: '0' });
    this.card = el('div', 'rg-title rg-outline', this.ui, '');
    Object.assign(this.card.style, { position: 'absolute', left: '0', right: '0', bottom: '22vh', textAlign: 'center',
      fontFamily: Fonts.Title, letterSpacing: '0.12em', fontSize: 'clamp(18px, 3vw, 30px)', color: Palette.Bone, opacity: '0' });
  }

  // ---------------------------------------------------------------------------------------------------- reads

  /** The co-op room when one is open (null alone). */
  coop() {
    const c = this.game.coop;
    return c && c.active ? c : null;
  }

  timeline(id) {
    return this.tracks.timeline(id);
  }

  /** Whether a cutscene plays here (I13's safe moment). */
  active() {
    return this.current !== null;
  }

  /** The playing shot's view: 'Cinematic' (the camera track) or 'Own' (each page's own eye); null when none plays. */
  view() {
    const c = this.current;
    return c ? c.view || null : null;
  }

  /** The playing cutscene's time, on the tick (0 before its start). */
  time() {
    const c = this.current;
    if (!c) return 0;
    const ticks = Math.round((this.env.now() - c.startAt) / this.tickSeconds);
    return Math.min(c.length, Math.max(0, ticks * this.tickSeconds));
  }

  /** The playing cutscene's time at this rendered frame (smooth; display only). */
  renderTime() {
    const c = this.current;
    if (!c) return 0;
    return Math.min(c.length, Math.max(0, this.env.renderNow() - c.startAt));
  }

  /** What this page's player is called, sanitized ('' for the nameless twin). */
  localName() {
    const coop = this.coop();
    const raw = coop && coop.me ? coop.me.name : this.env.setting('PlayerName') || '';
    return this.names.sanitize(raw);
  }

  /** Whether this page's player has seen `id`'s Full cut. */
  seen(id) {
    return this.game.profile.cutsceneSeen(id);
  }

  /** Whether this page asks for Full cuts on replays. */
  wantsFull() {
    return this.env.setting('ReplayCutscenes') === 'Full';
  }

  /** Authority: the members (ids; '' alone) who have not seen `id`. */
  unseen(id) {
    const coop = this.coop();
    if (!coop) return this.seen(id) ? [] : [''];
    return coop.participants().filter((m) => (m.local ? !this.seen(id) : !(m.storySeen && m.storySeen[id]))).map((m) => m.id);
  }

  // ---------------------------------------------------------------------------------------------------- scenes

  /** A scene's prop: fn(state, args) whenever a Prop event with this id takes effect. Returns an unsubscribe. */
  onProp(id, fn) {
    this.propHandlers.set(id, fn);
    return () => {
      if (this.propHandlers.get(id) === fn) this.propHandlers.delete(id);
    };
  }

  /** A scene's hand-over: fn(reason) when cutscene `id` ends on this page ('End', or 'Abort' when the run ended under it). */
  onEnded(id, fn) {
    this.endHandlers.set(id, fn);
    return () => {
      if (this.endHandlers.get(id) === fn) this.endHandlers.delete(id);
    };
  }

  /**
   * Authority (alone, or the host): plays cutscene `id` for everyone (its scene's onEnded runs on every page at its
   * end). `monsterRest` is where the Creature it held is left (hidden, Dormant) at the end; `lead` delays the start.
   * @param {string} id
   * @param {{monsterRest?: number[]|null, lead?: number}} [opts]
   */
  play(id, opts = {}) {
    const coop = this.coop();
    if (coop && coop.isClient()) return null;
    const timeline = this.timeline(id);
    if (!timeline) return null;
    const run = this.game.run;
    const members = coop ? coop.participants() : null;
    const cut = this.tracks.cutFor(id, members
      ? members.map((m) => (m.local ? { seenFull: this.seen(id), wantsFull: this.wantsFull() }
        : { seenFull: !!(m.storySeen && m.storySeen[id]), wantsFull: !!m.storyFull }))
      : [{ seenFull: this.seen(id), wantsFull: this.wantsFull() }]);
    const slots = members ? members.map((m) => m.slot) : [run ? run.slot : 0];
    const order = this.tracks.cast(run ? run.seed : 0, slots);
    const cast = order.map((slot) => {
      const m = members ? members.find((x) => x.slot === slot) : null;
      return { slot, id: m ? m.id : '', name: m ? this.names.sanitize(m.name) : this.localName() };
    });
    const startAt = this.tracks.quantise(this.env.now() + (opts.lead || 0), this.tickSeconds);
    this.runs += 1;
    const key = `${run ? run.runId : 'run'}:${this.runs}`;
    if (coop) coop.broadcast({ t: 'storyPlay', r: key, id, cut, el: this.env.now() - startAt, cast });
    this.begin({ run: key, id, cut, startAt, cast, monsterRest: opts.monsterRest || null });
    return key;
  }

  /**
   * Plays a cutscene here (the authority's own, or the host's word). `spec.cast`: [{slot, id, name}] in cast order.
   * @param {{run: string, id: string, cut: string, startAt: number, cast: {slot: number, id: string, name: string}[],
   *   monsterRest?: number[]|null}} spec
   */
  begin(spec) {
    if (this.current) this.end('Abort');
    const timeline = this.timeline(spec.id);
    if (!timeline) return;
    const coop = this.coop();
    const castBy = {};
    const binding = {};
    spec.cast.forEach((c, i) => {
      const actor = `P${i + 1}`;
      castBy[actor] = { slot: c.slot, id: c.id, name: c.name };
      binding[actor] = c.slot + 1;
    });
    const players = Math.max(1, spec.cast.length);
    // the cast's names (sanitized by the authority) and this page's own for {you}
    const names = { you: this.localName() };
    spec.cast.forEach((c, i) => {
      names[`P${i + 1}`] = c.name;
    });
    const origin = timeline.origin ? this.marks.get(timeline.origin) : null;
    const length = this.tracks.length(spec.id, spec.cut);
    const t0 = Math.max(0, Math.round((this.env.now() - spec.startAt) / this.tickSeconds) * this.tickSeconds);
    this.current = { ...spec, length, castBy, binding, players, names, timeline, origin, last: t0 - 1e-6,
      speaking: [], props: new Map(), lights: new Map(), rain: null, voices: [], skipping: null,
      gone: new Set(), leaving: new Set(), voted: false, monster: null, rainVoice: null };
    this.skip.reset();
    this.game.lock(LOCK);
    this.env.pushContext(CONTEXT, 'Cutscene');
    this.env.setHudVisible(false, 0.3, { captions: true });
    this.env.setStormEnabled(false);
    if (coop) coop.avatars.hold(true);
    if (origin) this.actors.build(timeline, origin.cframe, castBy);
    const authority = !coop || coop.isHost();
    const monster = items(timeline.actors).some((tr) => tr.kind === 'Monster');
    if (authority && monster) this.current.monster = this.game.creature.acquireScripted('Cinematic');
    this.ui.style.display = '';
    this._applyStates(t0);
  }

  // ---------------------------------------------------------------------------------------------------- the tick

  tick(dt, now) {
    const c = this.current;
    if (!c) return;
    const t = this.time();
    this.skip.tick(dt, t);
    if (c.skipping && now >= c.skipping.at) {
      // the fade is black: on to the last shot
      c.startAt = this.tracks.quantise(now, this.tickSeconds) - c.skipping.to;
      c.last = c.skipping.to - 1e-6;
      c.skipping = null;
      for (const s of c.speaking) s.handle.cancel();
      c.speaking.length = 0;
      this.subtitles.clear();
      this._applyStates(this.time());
      return;
    }
    if (t > c.last) {
      this._fire(c, c.last, t);
      c.last = t;
    }
    this._applyStates(t);
    // the Creature on the tick, along its track
    if (c.monster) {
      const sample = this.tracks.sample(c.id, c.cut, t, c.binding);
      for (const track of items(c.timeline.actors)) {
        if (track.kind === 'Monster') this.actors.tickMonster(c.monster, sample.actors[track.actor], now);
      }
    }
    for (let i = c.speaking.length - 1; i >= 0; i--) {
      if (t >= c.speaking[i].endsAt - 1e-6) {
        c.speaking[i].handle.cancel();
        c.speaking.splice(i, 1);
      }
    }
    const coop = this.coop();
    if (coop && coop.isHost() && now >= (c.syncAt ?? 0)) {
      c.syncAt = now + SYNC_EVERY;
      coop.broadcast({ t: 'storySync', r: c.run, el: now - c.startAt });
    }
    if (t >= c.length - 1e-6) this.end('End');
  }

  /** A client: the host's timeline was `el` in when it said so; a page more than a tick off moves its start to it. */
  _onSync(m) {
    const c = this.current;
    if (!c || c.run !== m.r || c.skipping) return;
    const coop = this.coop();
    const rtt = coop && coop.session && isNumber(coop.session.rttToHost) ? coop.session.rttToHost / 1000 : 0;
    const startAt = this.env.now() - m.el - rtt / 2;
    if (Math.abs(startAt - c.startAt) <= this.tickSeconds) return;
    c.startAt = this.tracks.quantise(startAt, this.tickSeconds);
  }

  /** One-shot events and lines in (t0, t1]. */
  _fire(c, t0, t1) {
    for (const e of this.tracks.events(c.id, c.cut, t0, t1, c.players)) {
      if (e.kind === 'Sound') this._sound(c, e.args);
      else if (e.kind === 'Shake') this.env.shake(e.args.amplitude * this._motionScale(), e.args.seconds);
    }
    for (const line of this.tracks.lines(c.id, c.cut, t0, t1, c.players)) this._line(c, line);
  }

  _motionScale() {
    const v = this.env.setting('MotionScale');
    return isNumber(v) ? v : 1;
  }

  _sound(c, args) {
    let position;
    if (args.actor) {
      const slot = c.binding[args.actor];
      const bin = slot ? this.bins.get(slot) : null;
      if (!bin) return;
      position = new THREE.Vector3(bin.cframe[0], bin.cframe[1] + 3, bin.cframe[2]);
    } else if (args.pos) position = this.actors.worldOf(args.pos);
    const voice = this.env.play(args.preset, { position, volume: args.volume ?? 1 });
    if (voice && isNumber(args.seconds)) c.voices.push({ voice, endsAt: this.env.now() + args.seconds });
  }

  /** A line: composed for this page, spoken (or murmured), subtitled for its slot. */
  _line(c, entry) {
    const line = items(c.timeline.lines).find((l) => l.id === entry.id);
    if (!line) return;
    const sayNames = this.env.setting('SayNames') !== false;
    const text = this.names.compose(line, c.names, sayNames);
    if (!text) return;
    const party = /^P\d$/.test(line.speaker);
    const speaker = party ? null : this.story.Speakers[line.speaker];
    const label = party ? (c.names[line.speaker] || '') : speaker ? speaker.label : line.speaker;
    const ear = line.channel === 'Ear';
    this.subtitles.show({ speaker: label, struck: !!(speaker && speaker.struck), text, ear, bearing: null, seconds: entry.slot });
    if (party || line.channel === 'Subtitle' || !speaker) return;
    if (speaker.struck && this.env.setting('MonsterVoice') === 'SubtitlesOnly') return;
    const voice = speaker.voice.web;
    const level = ear ? EAR_VOLUME : line.channel === 'PA' ? PA_VOLUME : 1;
    const volume = (this.env.setting('VoiceVolume') ?? 1) * level;
    const role = line.speaker === 'Gus' || line.speaker === 'TallJanitor' ? 'Older' : 'Young';
    const position = ear || line.channel === 'PA' ? null : this._speakerAt(c, line.speaker);
    const handle = this.speech.speak({ text, pitch: voice.pitch, rate: line.rate ?? voice.rate, volume, seconds: entry.slot,
      role, position, muffled: line.style === 'Muffled' });
    c.speaking.push({ handle, endsAt: entry.at + entry.slot });
  }

  /** Where a speaking actor's head is (its rig's actor: the Tall Man speaks from where Danny stood). */
  _speakerAt(c, speaker) {
    const sample = this.tracks.sample(c.id, c.cut, this.time(), c.binding);
    const s = sample.actors[speaker] || sample.actors.Danny;
    if (!s) return null;
    return this.actors.worldOf(s.pos).add(new THREE.Vector3(0, 5, 0));
  }

  /** The states the sample holds at t: light groups, props, rain, the day. */
  _applyStates(t) {
    const c = this.current;
    if (!c) return;
    const sample = this.tracks.sample(c.id, c.cut, t, c.binding);
    for (const [group, mode] of Object.entries(sample.lights)) {
      if (c.lights.get(group) === mode) continue;
      c.lights.set(group, mode);
      const id = this.env.lightGroupId(group);
      if (!id) continue;
      if (mode === 'Off') this.env.setGroupFactor(id, 0);
      else if (mode === 'On') this.env.setGroupFactor(id, 1);
      else if (mode === 'Flicker') this.env.setGroupFactor(id, null);
    }
    for (const [key, state] of Object.entries(sample.props)) {
      if (c.props.get(key) === state) continue;
      c.props.set(key, state);
      const [id, actor] = key.split(':');
      const fn = this.propHandlers.get(id);
      if (fn) fn(state, { actor: actor || null, slot: actor ? c.binding[actor] || null : null });
    }
    if (sample.rain !== c.rain) {
      c.rain = sample.rain;
      if (c.rainVoice) c.rainVoice.stop(1.5);
      c.rainVoice = sample.rain ? this.env.play('Rain', { loop: true, fadeIn: 2 }) : null;
    }
    const set = c.timeline.set && this.story.Sets[c.timeline.set];
    this.env.setDay(sample.day.amount, sample.day.tint, set ? set.day : null);
    const now = this.env.now();
    for (let i = c.voices.length - 1; i >= 0; i--) {
      if (now >= c.voices[i].endsAt) {
        c.voices[i].voice.stop(0.4);
        c.voices.splice(i, 1);
      }
    }
  }

  // ---------------------------------------------------------------------------------------------------- the frame

  frame(dt) {
    this.skip.frame();
    this.subtitles.frame();
    const c = this.current;
    if (!c) return;
    const t = this.renderTime();
    const sample = this.tracks.sample(c.id, c.cut, t, c.binding);
    // a shot change hides the actors of members who left (they stay until the next cut)
    if (sample.shot !== c.shot) {
      c.shot = sample.shot;
      for (const actor of c.leaving) c.gone.add(actor);
      c.leaving.clear();
    }
    this.actors.draw(sample, dt, c.gone);
    c.view = sample.view;
    // the camera: the track's while the shot is Cinematic, the page's own eye while it is Own
    if (sample.view === 'Cinematic' && sample.camera && c.origin) {
      this.actors.worldOf(sample.camera.eye, this.camera.position);
      this.actors.worldOf(sample.camera.target, this.camera.lookAt);
      this.camera.fov = sample.camera.fov;
      this.env.setCameraOverride(CAMERA_TOKEN, () => this.camera, { priority: CAMERA_PRIORITY, blendIn: 0, blendOut: 0 });
    } else this.env.setCameraOverride(CAMERA_TOKEN, null);
    // stuttering light groups (cosmetic: a flicker the timeline asks for)
    for (const [group, mode] of c.lights) {
      if (mode !== 'Stutter') continue;
      const id = this.env.lightGroupId(group);
      const k = Math.floor(t * STUTTER_HZ);
      const r = Math.abs(Math.sin(k * 12.9898 + id * 78.233) * 43758.5453) % 1;
      if (id) this.env.setGroupFactor(id, r < 0.45 ? 0.05 : 0.4 + r * 0.6);
    }
    // the bars, the black, the card
    const bars = `${(this.story.Letterbox * 100).toFixed(1)}vh`;
    this.barTop.style.height = bars;
    this.barBottom.style.height = bars;
    this.subtitles.setLift(this.story.Letterbox);
    let black = sample.fade;
    if (c.skipping) black = Math.max(black, Math.min(1, 1 - (c.skipping.at - this.env.now()) / this.story.Skip.Fade));
    this.black.style.opacity = black.toFixed(3);
    const card = sample.card;
    if (card) {
      if (this.card.textContent !== card.text) this.card.textContent = card.text;
      const fade = Math.min(CARD_FADE, card.seconds / 4);
      const a = Math.min(1, card.age / fade, (card.seconds - card.age) / fade);
      this.card.style.opacity = Math.max(0, a).toFixed(3);
    } else this.card.style.opacity = '0';
  }

  // ---------------------------------------------------------------------------------------------------- the skip

  /** Authority: the vote passed: everyone fades to the last shot. */
  skipPassed() {
    const c = this.current;
    if (!c || c.skipping) return;
    const coop = this.coop();
    if (coop && coop.isHost()) coop.broadcast({ t: 'storySkip', r: c.run });
    this._skip();
  }

  _skip() {
    const c = this.current;
    if (!c || c.skipping) return;
    c.skipping = { at: this.env.now() + this.story.Skip.Fade, to: this.tracks.skipTarget(c.id, c.cut) };
    if (this.skip.voted) c.voted = true;
  }

  // ---------------------------------------------------------------------------------------------------- the end

  /** The hand-over (or an abort): everything this cutscene held is let go. */
  end(reason) {
    const c = this.current;
    if (!c) return;
    this.current = null;
    for (const s of c.speaking) s.handle.cancel();
    for (const v of c.voices) v.voice.stop(0.4);
    if (c.rainVoice) c.rainVoice.stop(2);
    this.speech.stop();
    this.subtitles.clear();
    this.subtitles.setLift(0);
    for (const group of c.lights.keys()) {
      const id = this.env.lightGroupId(group);
      if (id) this.env.setGroupFactor(id, null);
    }
    this.env.setDay(0);
    this.env.setStormEnabled(true);
    this.actors.dispose();
    if (c.monster) {
      if (c.monsterRest) c.monster.teleport(c.monsterRest);
      c.monster.setHidden(true);
      c.monster.release('Dormant');
    }
    this.env.setCameraOverride(CAMERA_TOKEN, null);
    this.ui.style.display = 'none';
    this.black.style.opacity = '0';
    this.card.style.opacity = '0';
    this.skip.reset();
    const coop = this.coop();
    if (coop) coop.avatars.hold(false);
    this.env.popContext(CONTEXT);
    this.game.unlock(LOCK);
    this.env.setHudVisible(true, 0.6);
    if (reason === 'End' && (c.cut === 'Full' || c.voted)) this.game.profile.markCutsceneSeen(c.id);
    const handler = this.endHandlers.get(c.id);
    if (handler) handler(reason);
  }

  endRun() {
    this.pendingJoin = null;
    this.end('Abort');
  }

  // ---------------------------------------------------------------------------------------------------- co-op

  /** The story's messages (coop/events.js) and the room's hooks (a leaver's actor, a joiner's timeline). */
  bindCoop(coop) {
    const ev = coop.events;
    const PHASES = ['Prologue', 'InRun'];
    // the host's word can arrive while this page is still deploying: kept until its stage is up (joinPending)
    ev.register('storyPlay', { to: 'client', phases: ['Deploying', ...PHASES],
      validate: (m) => typeof m.r === 'string' && typeof m.id === 'string' && !!this.timeline(m.id) && (m.cut === 'Full' ||
        m.cut === 'Short') && isNumber(m.el) && Array.isArray(m.cast) && m.cast.every((c) => isNumber(c.slot)),
      handle: (from, m) => this._onPlay(m) });
    ev.register('storyVote', { to: 'host', phases: PHASES, rate: 2,
      validate: (m) => typeof m.r === 'string', handle: (from, m) => this.skip.cast(from, m.r) });
    ev.register('storyVotes', { to: 'client', phases: PHASES,
      validate: (m) => typeof m.r === 'string' && isNumber(m.n) && isNumber(m.of),
      handle: (from, m) => {
        if (this.current && this.current.run === m.r) this.skip.showTally({ n: m.n, of: m.of, waits: !!m.w,
          seenOnly: this.timeline(this.current.id).skip === 'SeenOnly' });
      } });
    ev.register('storySync', { to: 'client', phases: PHASES,
      validate: (m) => typeof m.r === 'string' && isNumber(m.el), handle: (from, m) => this._onSync(m) });
    ev.register('storySkip', { to: 'client', phases: PHASES,
      validate: (m) => typeof m.r === 'string', handle: (from, m) => {
        if (this.current && this.current.run === m.r) this._skip();
      } });
    ev.register('storySeen', { to: 'host', rate: 4,
      validate: (m) => !!m.s && typeof m.s === 'object' && typeof m.f === 'boolean',
      handle: (from, m) => {
        const member = coop.squad.get(from);
        if (!member) return;
        member.storySeen = {};
        for (const id of this.story.Order) if (m.s[id] === true) member.storySeen[id] = true;
        member.storyFull = m.f;
      } });
    coop.addModule({
      sessionStarted: () => this.reportSeen(),
      memberLeft: (member) => this._memberLeft(member),
      welcome: (member, msg) => {
        const c = this.current;
        if (c) msg.story = { r: c.run, id: c.id, cut: c.cut, el: this.env.now() - c.startAt, cast: c.cast };
      },
      welcomed: (msg) => {
        this.reportSeen();
        if (msg.story) this.pendingJoin = this._spec(msg.story);
      },
    });
  }

  /** Tells the host what this page has seen and whether it wants Full cuts (each page's own say). */
  reportSeen() {
    const coop = this.coop();
    if (!coop || !coop.isClient()) return;
    const seen = {};
    for (const id of this.story.Order) seen[id] = this.seen(id);
    coop.toHost({ t: 'storySeen', s: seen, f: this.wantsFull() });
  }

  _onPlay(m) {
    const spec = this._spec(m);
    if (this.game.phase === 'Deploying') this.pendingJoin = spec;
    else this.begin(spec);
  }

  /** The host's word as this page's timeline: its start on this page's clock, taken when the word arrives. */
  _spec(m) {
    const coop = this.coop();
    // the host's clock was m.el into the timeline when it sent this; half the round trip has passed since
    const rtt = coop && coop.session && isNumber(coop.session.rttToHost) ? coop.session.rttToHost / 1000 : 0;
    const startAt = this.tracks.quantise(this.env.now() - m.el - rtt / 2, this.tickSeconds);
    const cast = m.cast.map((c) => ({ slot: c.slot, id: String(c.id || ''), name: this.names.sanitize(String(c.name || '')) }));
    return { run: m.r, id: m.id, cut: m.cut, startAt, cast };
  }

  /** A client's page once its stage is up: the cutscene from where the squad is; false when none waits. */
  joinPending() {
    const spec = this.pendingJoin;
    this.pendingJoin = null;
    if (!spec) return false;
    this.begin(spec);
    return true;
  }

  _memberLeft(member) {
    const c = this.current;
    if (c) {
      for (const [actor, who] of Object.entries(c.castBy)) if (who.id === member.id) c.leaving.add(actor);
    }
    this.skip.memberLeft(member.id);
  }
}
