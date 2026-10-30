// match.js: the match policy (MatchAndDataService + MatchResetService + RunLifecycleService's transitions), single
// player.
//
//   Deploy(difficulty)  from Lobby / Countdown: one stock unit of each equipped perk is consumed (perks without
//                       stock are dropped), a fresh run seed is drawn (runSeed: random, or pinned by ?seed= / nextSeed),
//                       the run's routes and plan come from it and are applied to the world (props and grate locks), every
//                       system's beginRun runs, the player spawns at Level 0's first PlayerSpawn slot, Level 0 is
//                       entered, then InRun activates it.
//   Outcomes            Pending -> Escaped (Level 5's landing) / Dead (anything else when the run resolves). One
//                       evaluator, coalesced to the next tick, on every life change and escape: Wipe when nobody is
//                       Alive and nobody Downed holds a syringe charge, Escape when the same holds after an escape.
//   Resolution          RunEnded, the reward (CreditsPerLevelCleared x floors sealed + CreditsEscapeBonus; Escapes + 1
//                       and BestTime on an escape; once per run through LastRunId; nothing for a dev run), the summary
//                       to the results screen, Results.
//   Results             ResultsSeconds (+ 8 after an escape: the finale plays first) or Play Again, then Resetting
//                       (every system's endRun) and back to the Lobby; Play Again arrives Ready.

import { DifficultyConfig, GameConfig } from './config.js';
import { applyReward, rewardFor } from './profile.js';
import { normalizeSeed } from './worldData.js';

const ESCAPE_FINALE_SECONDS = 8;
const RUN_ID_ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789';

/**
 * @typedef {{outcome: 'Escaped'|'Dead', runSeconds: number, creditsEarned: number, bestTime: number|undefined,
 *   stats: Record<string, number>, levelsCleared: number, difficulty: string, escapees: number, squadSize: number,
 *   newBest: boolean, saved: boolean}} RunSummary
 */

export class Match {
  /** @param {import('./game.js').Game} game */
  constructor(game) {
    this.name = 'Match';
    this.game = game;
    /** @type {'Pending'|'Escaped'|'Dead'} */
    this.outcome = 'Pending';
    this.escapedAt = null;
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
   * host): the run's seed and id, this page's spawn slot; a late joiner's spec also names the level the squad is on and
   * the levels already cleared (they watch until the next airlock).
   * @param {string} difficulty
   * @param {{seed: number, runId: string, slot: number, level?: string, cleared?: string[], spectate?: boolean}} [spec]
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
      plan: game.world.plan(chosen, seed, routes),
      routes,
      perks,
      startedAt: env.now(),
      seed,
      devRun: this.devRun,
    };
    this.outcome = 'Pending';
    this.escapedAt = null;
    this.resolved = false;
    this.summary = null;
    this.playAgain = false;
    this.resultsEndsAt = null;
    game.setPhase('Deploying');
    await env.fade(1, 0.6);
    env.resetLighting();
    game.beginRun(run);
    const level = spec && spec.level ? spec.level : 'Level0_Basement';
    if (spec && Array.isArray(spec.cleared)) for (const l of spec.cleared) game.cleared.add(l);
    this.spawnAt(level, spec ? spec.slot : 0);
    game.enterLevel(level);
    run.startedAt = env.now();
    game.setPhase('InRun');
    game.activateLevel();
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

  /** Puts the player at a level's PlayerSpawn slot (CharacterService.SpawnCFrame) in its entry room on the run's routes. */
  spawnAt(level, slot) {
    const spawns = this.game.world.spawns(level, this.game.run ? this.game.run.routes : null);
    const s = spawns[Math.min(slot, spawns.length - 1)];
    if (s) this.game.env.teleport(s.cframe);
  }

  // ---------------------------------------------------------------------------------------------------- outcomes

  /** Level 5's escape (the landing). */
  markEscaped() {
    const game = this.game;
    if (!game.run || this.resolved || game.phase !== 'InRun' || this.outcome !== 'Pending') return false;
    this.outcome = 'Escaped';
    this.escapedAt = game.env.now();
    if (this._coop()) this._coop().runNet.localEscaped();
    this.requestEvaluation();
    return true;
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

  /** RunOutcomeEvaluator, coalesced to the next tick. */
  requestEvaluation() {
    if (!this.game.run || this.resolved) return;
    this.evaluateQueued = true;
  }

  /** MatchAndDataService.verdict (co-op: over the squad, coop/run.js; one participant: the solo rule). */
  verdict() {
    const squad = this._coop() ? this._coop().runNet.verdict() : null;
    if (squad) return squad;
    const life = this.game.life;
    if (this.outcome === 'Escaped') return 'Escape';
    if (life.state === 'Alive') return 'Continue';
    if (life.state === 'Downed' && life.syringeCharges > 0) return 'Continue';
    return 'Wipe';
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
    game.setPhase('RunEnded');
    const escaped = this.outcome === 'Escaped';
    const now = game.env.now();
    const seconds = escaped && this.escapedAt !== null ? Math.max(0, this.escapedAt - run.startedAt) : now - run.startedAt;
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
    };
    this.resultsEndsAt = now + GameConfig.ResultsSeconds + (escaped ? ESCAPE_FINALE_SECONDS : 0);
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

  /** Abandons the run from the pause menu: it resolves as a death. */
  abandon() {
    const game = this.game;
    if (game.phase !== 'InRun' || this.resolved) return;
    game.life.execute('Abandoned');
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

