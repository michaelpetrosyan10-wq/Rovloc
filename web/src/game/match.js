// match.js: the match policy (MatchAndDataService + MatchResetService + RunLifecycleService's transitions), single
// player.
//
//   Deploy(difficulty)  from Lobby / Countdown: one stock unit of each equipped perk is consumed (perks without
//                       stock are dropped), the run's plan is applied to the world (props and grate locks), every
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
  }

  // ---------------------------------------------------------------------------------------------------- deploy

  /** MatchAndDataService.Deploy. Returns false when a run exists or away from the lobby phases. */
  async deploy(difficulty) {
    const game = this.game;
    if (this.deploying || game.run || (game.phase !== 'Lobby' && game.phase !== 'Countdown')) return false;
    this.deploying = true;
    const env = game.env;
    const chosen = DifficultyConfig[difficulty] ? difficulty : 'Standard';
    const perks = game.profile.consumeLoadout();
    const run = {
      runId: newRunId(),
      difficulty: chosen,
      plan: game.world.plan(chosen),
      perks,
      startedAt: env.now(),
      seed: game.world.meta.seed || 0,
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
    game.beginRun(run);
    game.creature.setDifficulty(chosen, DifficultyConfig[chosen]);
    this.spawnAt('Level0_Basement', 0);
    game.enterLevel('Level0_Basement');
    run.startedAt = env.now();
    game.setPhase('InRun');
    game.activateLevel();
    this.deploying = false;
    env.fade(0, 1.2);
    return true;
  }

  /** Puts the player at a level's PlayerSpawn slot (CharacterService.SpawnCFrame). */
  spawnAt(level, slot) {
    const spawns = this.game.world.spawns(level);
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
    this.requestEvaluation();
    return true;
  }

  /** RunOutcomeEvaluator, coalesced to the next tick. */
  requestEvaluation() {
    if (!this.game.run || this.resolved) return;
    this.evaluateQueued = true;
  }

  /** MatchAndDataService.verdict for the one participant. */
  verdict() {
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
    const v = this.verdict();
    if (v !== 'Continue') this._resolve(v);
  }

  _resolve(verdict) {
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
      escapees: escaped ? 1 : 0,
      squadSize: 1,
      newBest,
      saved,
      verdict,
    };
    this.resultsEndsAt = now + GameConfig.ResultsSeconds + (escaped ? ESCAPE_FINALE_SECONDS : 0);
    this.resultsTotal = this.resultsEndsAt - now;
    game.setPhase('Results');
  }

  /** The results screen's Play Again. */
  pressPlayAgain() {
    if (this.game.phase !== 'Results') return;
    this.playAgain = true;
    this.reset();
  }

  /** Results -> Resetting -> Lobby (MatchResetService). */
  reset() {
    const game = this.game;
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
      this.reset();
    }
  }
}

function newRunId() {
  let id = '';
  for (let i = 0; i < 16; i++) id += RUN_ID_ALPHABET[Math.floor(Math.random() * RUN_ID_ALPHABET.length)];
  return `${Date.now().toString(36)}-${id}`;
}

