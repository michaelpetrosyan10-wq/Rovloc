// match.js: the match policy (MatchAndDataService + MatchResetService + RunLifecycleService's transitions), single
// player; co-op's squad side is coop/run.js.
//
//   Deploy(difficulty)  from Lobby / Countdown: one stock unit of each equipped perk is consumed (perks without
//                       stock are dropped), a fresh run seed is drawn (runSeed: random, or pinned by ?seed= / nextSeed),
//                       the run's routes and plan come from it and are applied to the world (props and grate locks), every
//                       system's beginRun runs, the run's first stage is entered (StageConfig's order: the stand-in of
//                       the Back Lot, then the school from its entry), then InRun activates it.
//   The run             stage after stage (game.advance): the run clock runs from the first playable stage's activation
//                       to the last one's end (the Basement to the wheels up). After the last stage the run ends:
//                       everyone still playing escaped (finishRun).
//   Outcomes            Pending -> Escaped (the run's end) / Dead (the run resolving otherwise). One evaluator,
//                       coalesced to the next tick, on every life change: Wipe when nobody is Alive or Downed and nobody
//                       has a respawn left (LivesRules.runEnds; co-op: over the squad, coop/run.js).
//   Resolution          RunEnded, the reward (CreditsPerLevelCleared x levels cleared + CreditsEscapeBonus on an
//                       escape; once per run through LastRunId; nothing for a dev run), the save (profile.js: the
//                       Sunrise seen, its best time), the summary to the results screen, Results.
//   Results             ResultsSeconds or Play Again, then Resetting (every system's endRun) and back to the Lobby;
//                       Play Again arrives Ready.

import { DifficultyConfig, GameConfig } from './config.js';
import { applyReward, rewardFor } from './profile.js';
import { normalizeSeed } from './worldData.js';

const RUN_ID_ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789';

/**
 * @typedef {{outcome: 'Escaped'|'Dead', runSeconds: number, creditsEarned: number, bestTime: number|undefined,
 *   stats: Record<string, number>, levelsCleared: number, difficulty: string, escapees: number, squadSize: number,
 *   newBest: boolean, saved: boolean, verdict: string, reached: string|null, cleared: string[]}} RunSummary
 */

export class Match {
  /** @param {import('./game.js').Game} game */
  constructor(game) {
    this.name = 'Match';
    this.game = game;
    /** @type {'Pending'|'Escaped'|'Dead'} */
    this.outcome = 'Pending';
    this.resolved = false;
    this.evaluateQueued = false;
    this.resultsEndsAt = null;
    this.playAgain = false;
    this.devRun = false;
    /** @type {RunSummary|null} */
    this.summary = null;
    this.deploying = false;
    /** @type {number|null} a fixed seed for the next runs (tests, the dev panel); null: random */
    this.nextSeed = null;
  }

  // ---------------------------------------------------------------------------------------------------- deploy

  /**
   * MatchAndDataService.Deploy. Returns false when a run exists or away from the lobby phases. Co-op (`spec`, from the
   * host): the run's seed and id, this page's spawn slot; a late joiner's spec also names the stage the squad is on and
   * the stages already cleared (they watch until the next stage).
   * @param {string} difficulty
   * @param {{seed: number, runId: string, slot: number, stage?: string, cleared?: string[], spectate?: boolean}} [spec]
   */
  async deploy(difficulty, spec) {
    const game = this.game;
    if (this.deploying || game.run || (game.phase !== 'Lobby' && game.phase !== 'Countdown')) return false;
    this.deploying = true;
    const env = game.env;
    const chosen = DifficultyConfig[difficulty] ? difficulty : 'Standard';
    const perks = game.profile.consumeLoadout();
    const seed = spec ? normalizeSeed(spec.seed) : this.runSeed();
    const routes = game.world.routes(seed);
    const run = {
      runId: spec && spec.runId ? spec.runId : newRunId(),
      difficulty: chosen,
      plan: game.world.plan(chosen, seed),
      routes,
      perks,
      startedAt: env.now(),
      seed,
      devRun: this.devRun,
      slot: spec ? spec.slot : 0,
      clockFrom: null,
      clockTo: null,
    };
    this.outcome = 'Pending';
    this.resolved = false;
    this.summary = null;
    this.playAgain = false;
    this.resultsEndsAt = null;
    game.setPhase('Deploying');
    await env.fade(1, 0.6);
    env.resetLighting();
    game.beginRun(run);
    const stage = spec && spec.stage ? spec.stage : game.stages.first();
    if (spec && Array.isArray(spec.cleared)) for (const s of spec.cleared) game.cleared.add(s);
    game.enterStage(stage, { spawn: true });
    run.startedAt = env.now();
    game.setPhase('InRun');
    game.activateStage();
    this.deploying = false;
    env.fade(0, 1.2);
    return true;
  }

  /**
   * The seed of the run about to start (RunLifecycleService's RunSeed): `nextSeed` when a test or the dev panel set
   * one (it stays until cleared), else the page's `?seed=N`, else a fresh random one (crypto.getRandomValues), so every
   * run differs.
   */
  runSeed() {
    const fixed = normalizeSeed(this.nextSeed ?? urlSeed());
    if (fixed !== null) return fixed;
    const word = new Uint32Array(1);
    crypto.getRandomValues(word);
    return normalizeSeed(word[0]);
  }

  /** This page's spawn slot (the host's word in co-op; 0 alone). */
  slot() {
    const coop = this._coop();
    if (coop && coop.me) return coop.me.slot;
    return this.game.run ? this.game.run.slot : 0;
  }

  /** Puts the player at a level's PlayerSpawn slot (CharacterService.SpawnCFrame) in its entry room on the run's routes. */
  spawnAt(level, slot) {
    const s = this.spawnOf(level, slot);
    if (s) this.game.env.teleport(s.cframe);
  }

  /** A level's PlayerSpawn for `slot` on the run's routes (the last one for a slot past them), or null. */
  spawnOf(level, slot) {
    const spawns = this.game.world.spawns(level, this.game.run ? this.game.run.routes : null);
    return spawns[Math.min(slot, spawns.length - 1)] || null;
  }

  // ---------------------------------------------------------------------------------------------------- the run

  /** A stage's activation: the run clock starts at the first playable stage's. */
  stageActivated(stage) {
    const run = this.game.run;
    if (run && run.clockFrom === null && stage === this.game.stages.clockSpan().from) run.clockFrom = this.game.env.now();
  }

  /** A stage left for the next one (game.advance): the clock stops with the last playable stage. */
  stageCleared(stage) {
    const run = this.game.run;
    if (run && run.clockTo === null && stage === this.game.stages.clockSpan().to) run.clockTo = this.game.env.now();
  }

  /** The run's end after its last stage: every player still playing escaped (co-op: the host's word, coop/run.js). */
  finishRun() {
    const game = this.game;
    if (!game.run || this.resolved || game.phase !== 'InRun') return;
    const coop = this._coop();
    if (coop && coop.isClient()) return;
    if (game.life.playing()) this.outcome = 'Escaped';
    if (coop) coop.runNet.finished();
    const verdict = coop ? coop.runNet.finishVerdict() : this.outcome === 'Escaped' ? 'Escape' : 'Wipe';
    this._resolve(verdict);
    if (coop) coop.runNet.resolved(verdict);
  }

  /** The run's seconds: the clock's span (from the first playable stage to the last one's end, or to now). */
  runSeconds() {
    const run = this.game.run;
    if (!run) return 0;
    const from = run.clockFrom ?? run.startedAt;
    const to = run.clockTo ?? this.game.env.now();
    return Math.max(0, to - from);
  }

  /** How many escaped (co-op: the squad's escapees; alone: you or nobody). */
  _squadEscapees(escaped) {
    const coop = this._coop();
    if (!coop) return escaped ? 1 : 0;
    return coop.participants().filter((m) => m.outcome === 'Escaped').length;
  }

  /** The co-op room when one is open (null alone). */
  _coop() {
    const coop = this.game.coop;
    return coop && coop.active ? coop : null;
  }

  // ---------------------------------------------------------------------------------------------------- outcomes

  /** RunOutcomeEvaluator, coalesced to the next tick. */
  requestEvaluation() {
    if (!this.game.run || this.resolved) return;
    this.evaluateQueued = true;
  }

  /** MatchAndDataService.verdict: Wipe once the run ends by LivesRules.runEnds (co-op: over the squad, coop/run.js). */
  verdict() {
    const squad = this._coop() ? this._coop().runNet.verdict() : null;
    if (squad) return squad;
    return this.game.life.runEnds([this.game.life.member(1)]) ? 'Wipe' : 'Continue';
  }

  _evaluate() {
    this.evaluateQueued = false;
    const game = this.game;
    if (this.resolved || !game.run || game.phase !== 'InRun') return;
    // co-op: the host judges the squad; a client resolves when it says so (resolveFromHost)
    if (this._coop() && this._coop().isClient()) return;
    const v = this.verdict();
    if (v === 'Continue') return;
    this._resolve(v);
    if (this._coop()) this._coop().runNet.resolved(v);
  }

  /** Co-op client: the host resolved the run; this page pays its own player by their own outcome. */
  resolveFromHost(verdict, squad) {
    const game = this.game;
    if (this.resolved || !game.run) return;
    if (game.phase !== 'InRun' && game.phase !== 'Deploying') return;
    if (squad && squad.escaped) this.outcome = 'Escaped';
    this._resolve(verdict, squad);
  }

  /** Co-op: the host ended Results (or the room closed: `drop` leaves the run without results). */
  resetFromHost(drop = false) {
    const game = this.game;
    if (drop && game.phase === 'Lobby' && !game.run) return;
    if (drop && (game.phase === 'Lobby' || game.phase === 'Countdown')) {
      game.setPhase('Lobby');
      return;
    }
    this.reset(true);
  }

  _resolve(verdict, squad = null) {
    const game = this.game;
    const run = game.run;
    this.resolved = true;
    if (this.outcome === 'Pending') this.outcome = 'Dead';
    if (run.clockTo === null) run.clockTo = game.env.now();
    game.setPhase('RunEnded');
    const escaped = this.outcome === 'Escaped';
    const now = game.env.now();
    const seconds = this.runSeconds();
    const floors = game.stats.get('FloorsCleared');
    const credits = rewardFor(escaped, floors);
    let paid = 0;
    let saved = false;
    let newBest = false;
    if (!run.devRun && !game.profile.readOnly) {
      if (credits <= 0 && !escaped) saved = true;
      else {
        let result = { applied: false, newBest: false };
        const ok = game.profile.update((data) => {
          result = applyReward(data, { runId: run.runId, credits, escaped, difficulty: run.difficulty,
            time: escaped ? seconds : undefined });
          return result.applied;
        });
        if (ok && result.applied) {
          paid = credits;
          saved = true;
          newBest = result.newBest;
          game.stats.increment('CreditsEarned', credits);
        }
      }
    }
    this.summary = {
      outcome: escaped ? 'Escaped' : 'Dead',
      runSeconds: seconds,
      creditsEarned: paid,
      bestTime: game.profile.bestTime(run.difficulty),
      stats: { ...game.stats.values },
      levelsCleared: floors,
      difficulty: run.difficulty,
      escapees: squad ? squad.escapees : this._squadEscapees(escaped),
      squadSize: squad ? squad.squadSize : this._coop() ? Math.max(1, this._coop().participants().length) : 1,
      newBest,
      saved,
      verdict,
      reached: game.stage,
      cleared: [...game.cleared],
    };
    this.resultsEndsAt = now + GameConfig.ResultsSeconds;
    this.resultsTotal = this.resultsEndsAt - now;
    game.setPhase('Results');
  }

  /** The results screen's Play Again (co-op: the squad goes back together, coop/run.js). */
  pressPlayAgain() {
    if (this.game.phase !== 'Results') return;
    this.playAgain = true;
    if (this._coop()) {
      this._coop().runNet.playAgain();
      return;
    }
    this.reset();
  }

  /** Results -> Resetting -> Lobby (MatchResetService). Co-op: the host's word only (`fromHost`). */
  reset(fromHost = false) {
    const game = this.game;
    if (this._coop() && !fromHost) {
      if (this._coop().isHost()) this._coop().runNet.resetAll();
      return;
    }
    if (game.phase !== 'Results' && game.phase !== 'RunEnded' && game.phase !== 'InRun' && game.phase !== 'Deploying') {
      return;
    }
    const ready = this.playAgain;
    game.setPhase('Resetting');
    game.endRun();
    game.setPhase('Lobby');
    if (game.lobby) game.lobby.arrive(ready);
  }

  /** Abandons the run from the pause menu: it resolves as a death, the respawns given up. */
  abandon() {
    const game = this.game;
    if (game.phase !== 'InRun' || this.resolved) return;
    game.life.abandon();
    this.requestEvaluation();
  }

  // ---------------------------------------------------------------------------------------------------- drive

  tick(dt, now) {
    if (this.evaluateQueued) this._evaluate();
    if (this.game.phase === 'Results' && this.resultsEndsAt !== null && now >= this.resultsEndsAt) {
      if (!(this._coop() && this._coop().isClient())) this.reset();
    }
  }
}

function newRunId() {
  let id = '';
  for (let i = 0; i < 16; i++) id += RUN_ID_ALPHABET[Math.floor(Math.random() * RUN_ID_ALPHABET.length)];
  return `${Date.now().toString(36)}-${id}`;
}

/** The page's `?seed=N` (tests pin a run with it), or null. */
function urlSeed() {
  const m = typeof location !== 'undefined' ? /[?&]seed=(\d+)/.exec(location.search) : null;
  return m ? Number(m[1]) : null;
}
