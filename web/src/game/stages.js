// stages.js: the run's stages (docs/design/game-spec-v2.md 0.1, 4.2) and the script that plays each one.
//
// The run is the world's stage list (world.json meta.stageConfig.order: BackLot, the four school levels, the two city
// levels, Runway, Bahamas), from the lobby to the results, keyed by stage id everywhere. StageScripts names the script
// that plays a stage; a stage with none yet is played by the StandIn below.
//
//   School    a level of the school (game.level is the stage): its level scripts, objectives, airlocks and the
//             Creature, as the four floors play today. Entered from a stand-in, the squad spawns at its entry.
//   StandIn   build scaffolding for a stage still to be built: its card (the stage table's Card text, or its name when
//             it has none), one honest line, a short hold (FloorCardIn + FloorCardHold, tutorialConfig's timing; the
//             Skip action ends it: alone at once, in a squad once more than half voted), the fade (FloorCardOut) and
//             on to the next stage. Every control is held (a Cutscene lock: nobody can be caught or hurt) and no level
//             is active. standIns() lists the stages still on it; game-smoke prints the list and data-test --release
//             fails while it is not empty, so a stand-in cannot ship by accident.
//
// levelAt(meta, p): the stage (a level or a set) whose box (meta.levels[id].aabb) holds p in x, y and z, the smallest
// first; null outside every stage's box. Co-op: the host ends a stand-in for everyone ({t: 'stageNext'}, coop/run.js);
// a client's Skip is a vote ({t: 'standInSkip'}).

import { S } from './strings/index.js';
import './strings/run.js';
import { glyphFor } from './ui/nav.js';
import { Palette, el } from './ui/style.js';
import { approach } from './util.js';

/** The script that plays each stage, by stage id (a stage not listed is played by the StandIn). */
export const StageScripts = Object.freeze({
  Level0_Basement: 'School',
  Level1_Hallways: 'School',
  Level2_Auditorium: 'School',
  Level3_Roof: 'School',
});

/** seconds the black takes to cover the view as a stand-in starts (the stage before it ends behind it) */
const FADE_IN_FLOOR = 0.3;

/**
 * The run's stage list over a world's meta.stageConfig.
 * @typedef {{id: string, kind: 'Set'|'Level', play: string[], card?: string, par: number, parReplay?: number,
 *   floor?: number}} Stage
 */
export class Stages {
  /** @param {{stageConfig: {order: Stage[], playable: string[], sneaking: string[]}, levels?: Record<string, any>}} meta */
  constructor(meta) {
    const config = meta && meta.stageConfig;
    if (!config || !Array.isArray(config.order) || !config.order.length) throw new Error('the world carries no stageConfig');
    this.meta = meta;
    /** @type {Stage[]} */
    this.order = config.order.slice();
    this.byId = new Map(this.order.map((s) => [s.id, s]));
    this.playable = new Set(Array.isArray(config.playable) ? config.playable : []);
    this.sneaking = new Set(Array.isArray(config.sneaking) ? config.sneaking : []);
  }

  /** The stage `id` (undefined for an unknown id). */
  get(id) {
    return this.byId.get(id);
  }

  /** The run's first stage. */
  first() {
    return this.order[0].id;
  }

  /** The stage after `id` in run order (null after the last and for an unknown id). */
  next(id) {
    const i = this.order.findIndex((s) => s.id === id);
    return i >= 0 && i + 1 < this.order.length ? this.order[i + 1].id : null;
  }

  /** The script that plays stage `id`: 'School', or 'StandIn' while it has none. */
  scriptOf(id) {
    return StageScripts[id] || 'StandIn';
  }

  /** Whether stage `id` is played on a level of the school (game.level is the stage). */
  isLevel(id) {
    return this.scriptOf(id) === 'School';
  }

  isPlayable(id) {
    return this.playable.has(id);
  }

  /** The stages still played by the StandIn, in run order (empty once every stage has its script). */
  standIns() {
    return this.order.filter((s) => this.scriptOf(s.id) === 'StandIn').map((s) => s.id);
  }

  /** The results' chapters: every stage after the run's opening (its first stage), in order. */
  chapters() {
    return this.order.slice(1).map((s) => s.id);
  }

  /** The text of stage `id`'s card (the stage table's Card), or its name when it shows none. */
  cardText(id) {
    const stage = this.get(id);
    return stage && stage.card ? S(stage.card) : S(`Stage.Name.${id}`);
  }

  /** The playable stages the run clock spans: from the first one's activation to the last one's end. */
  clockSpan() {
    const list = this.order.filter((s) => this.playable.has(s.id)).map((s) => s.id);
    return { from: list[0] || null, to: list[list.length - 1] || null };
  }

  /** The stage (level or set) whose box holds `p`, or null. */
  levelAt(p) {
    return levelAt(this.meta, p);
  }
}

/**
 * The stage (a level or a set) whose box holds `p` (meta.levels[id].aabb [minX, minY, minZ, maxX, maxY, maxZ], in x, y
 * and z; the smallest box first where two hold it), or null when no stage's box does.
 * @param {{stageConfig: {order: {id: string}[]}, levels?: Record<string, {aabb?: number[]}>}} meta
 * @param {{x: number, y: number, z: number}} p
 */
export function levelAt(meta, p) {
  let best = null;
  let bestVolume = Infinity;
  for (const { id } of meta.stageConfig.order) {
    const info = meta.levels ? meta.levels[id] : null;
    const a = info && info.aabb;
    if (!a || a.length < 6) continue;
    if (p.x < a[0] || p.x > a[3] || p.y < a[1] || p.y > a[4] || p.z < a[2] || p.z > a[5]) continue;
    const volume = (a[3] - a[0]) * (a[4] - a[1]) * (a[5] - a[2]);
    if (volume < bestVolume) {
      best = id;
      bestVolume = volume;
    }
  }
  return best;
}

/** The StandIn: plays every stage that has no script yet (see the header). */
export class StandIn {
  /** @param {import('./game.js').Game} game */
  constructor(game) {
    this.name = 'StandIn';
    this.game = game;
    this.env = game.env;
    /** @type {{stage: string, startedAt: number, holdUntil: number, endsAt: number|null, votes: Set<string>}|null} */
    this.current = null;
    /** the card's text and the black behind it (0..1) */
    this.alpha = 0;
    this.black = 0;
    this.timing = game.world.meta.tutorialConfig.timing;
    const root = this.env.uiRoot();
    this.root = el('div', 'rg-screen rg-hidden', root);
    Object.assign(this.root.style, { zIndex: '38', background: Palette.Ink, opacity: '0', pointerEvents: 'none' });
    const col = el('div', '', this.root);
    this.col = col;
    Object.assign(col.style, { width: 'min(640px, 92vw)', display: 'flex', flexDirection: 'column', alignItems: 'center',
      gap: '10px', textAlign: 'center' });
    this.title = el('div', 'rg-title', col, '');
    Object.assign(this.title.style, { fontSize: 'clamp(26px, 5vw, 44px)', letterSpacing: '0.08em', lineHeight: '1.15' });
    const rule = el('div', '', col);
    Object.assign(rule.style, { height: '1px', width: '60%',
      background: `linear-gradient(90deg, transparent, ${Palette.Stroke}, transparent)` });
    this.line = el('div', 'rg-body', col, S('StandIn.Line'));
    Object.assign(this.line.style, { fontSize: '16px', color: Palette.Ash });
    this.skip = el('div', 'rg-caps', col, '');
    Object.assign(this.skip.style, { marginTop: '18px', color: Palette.Smoke });
    this.env.onAction('Skip', (phase) => {
      if (phase === 'Begin') this.pressSkip();
    });
  }

  /** The stage being stood in for (null when none). */
  stage() {
    return this.current ? this.current.stage : null;
  }

  stageActivated(stage) {
    const g = this.game;
    if (g.stages.scriptOf(stage) !== 'StandIn') return;
    const now = this.env.now();
    const t = this.timing;
    this.current = { stage, startedAt: now, holdUntil: now + t.FloorCardIn + t.FloorCardHold, endsAt: null,
      votes: new Set() };
    g.lock('Cutscene');
    this.env.pushContext('StandIn', 'Cutscene');
    this.title.textContent = g.stages.cardText(stage);
    this.root.classList.remove('rg-hidden');
  }

  stageDeactivated(stage) {
    if (!this.current || this.current.stage !== stage) return;
    this._release();
  }

  _release() {
    this.current = null;
    this.game.unlock('Cutscene');
    this.env.popContext('StandIn');
  }

  /** This page's Skip: alone the hold ends now; in a squad it is this player's vote (the host counts). */
  pressSkip() {
    const c = this.current;
    if (!c || c.endsAt !== null) return;
    const coop = this.game.coop && this.game.coop.active ? this.game.coop : null;
    if (coop && coop.isClient()) coop.toHost({ t: 'standInSkip', s: c.stage });
    else this.vote(coop ? coop.localId : '', c.stage);
  }

  /** A skip vote for `stage` (the host's, or a client's through coop/run.js): more than half of the squad ends it. */
  vote(memberId, stage) {
    const c = this.current;
    if (!c || c.stage !== stage || c.endsAt !== null) return;
    c.votes.add(memberId);
    const coop = this.game.coop && this.game.coop.active ? this.game.coop : null;
    const size = coop ? Math.max(1, coop.participants().length) : 1;
    if (c.votes.size * 2 > size) this._end(this.env.now());
  }

  _end(now) {
    const c = this.current;
    c.endsAt = now + this.timing.FloorCardOut;
    c.holdUntil = Math.min(c.holdUntil, now);
  }

  tick(dt, now) {
    const c = this.current;
    const g = this.game;
    if (!c || g.phase !== 'InRun') return;
    if (c.endsAt === null && now >= c.holdUntil) this._end(now);
    // the host (or the one player) moves the run on; a client follows the host's word
    if (c.endsAt !== null && now >= c.endsAt && !(g.coop && g.coop.isClient())) {
      if (g.coop && g.coop.active) g.coop.runNet.stageDone(c.stage);
      else g.advance();
    }
  }

  /**
   * The black stays while stand-ins follow each other (and into the results, which open on black); the card's text
   * fades in over FloorCardIn and out over FloorCardOut; leaving for a level the black fades out over FloorCardOut.
   */
  frame(dt) {
    const c = this.current;
    const t = this.timing;
    const phase = this.game.phase;
    const black = c || (this.black > 0 && (phase === 'RunEnded' || phase === 'Results')) ? 1 : 0;
    this.black = approach(this.black, black, dt / (black ? FADE_IN_FLOOR : t.FloorCardOut));
    const text = c && c.endsAt === null ? 1 : 0;
    this.alpha = approach(this.alpha, text, dt / (text ? t.FloorCardIn : t.FloorCardOut));
    if (this.black <= 0.001 && this.alpha <= 0.001) {
      this.root.classList.add('rg-hidden');
      return;
    }
    this.root.classList.remove('rg-hidden');
    this.root.style.opacity = String(this.black);
    this.col.style.opacity = String(this.alpha);
    if (!c) return;
    const device = this.env.device();
    this.skip.textContent = device === 'Touch' ? S('StandIn.SkipTouch')
      : S('StandIn.Skip', glyphFor(this.env, 'Skip', device));
  }

  beginRun() {
    this.current = null;
  }

  endRun() {
    if (this.current) this._release();
    this.alpha = 0;
    this.black = 0;
    this.root.classList.add('rg-hidden');
  }
}
