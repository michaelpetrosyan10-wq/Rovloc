// lives.js: the port of Shared/Rules/LivesRules.luau (docs/design/game-spec-v2.md 3.3), function for function. Pure:
// plain data in and out, no engine, clock or randomness. The numbers are the world's own (world.json meta.livesConfig,
// both difficulties; meta.stageConfig.playable for the stages that hand out a stage respawn), never a copy here:
// livesRules(meta) binds a set of the functions to them. tools/lives-test.mjs replays every LivesRules row of
// build/cache/golden.json against this port.
//
//   newRun         a run's start: the run respawns, the syringe's one extra (no stage respawn before the first stage)
//   stageActivated a stage's activation: downs and the get-up reset; on a playable stage the stage respawn is set
//   lethal         a lethal hit (Catch, Damage, BleedOut): Downed the first time on a stage while Alive, else Killed
//   getUp          the lone get-up: from GetUpDelay after going down, held GetUpHold, once per stage
//   getUpTime      seconds from going down to standing by the get-up
//   revive         a teammate's revive: ReviveHold, up at ReviveHealth, at any time
//   respawnsLeft   stage + run + syringe
//   spend          one respawn, in order: the stage's, the run's, the syringe's
//   afterDeath     a respawn (spent; the get-up given back), spectating (co-op) or the run's end (solo)
//   respawn        what a respawn restores (health, at least RespawnCharges charges, at least RespawnTorch of the torch,
//                  the grace, the blackout)
//   chaseFailure   a failed scripted-chase attempt: free up to ChaseFreeAttempts, then the squad member with the most
//                  respawns left (lowest slot first) pays one; with none left the run ends
//   runEnds        nobody Alive or Downed and nobody with a respawn left
//   checkpointReturn  the next stage's entry stands a spectator (or the dead) up at CheckpointHealth
//
// A Lives record is {stage, run, syringe, downs, getUpUsed}; a squad member {slot, left, lifeState?} (slot 0 is nobody).

/**
 * @typedef {{stage: number, run: number, syringe: number, downs: number, getUpUsed: boolean}} Lives
 * @typedef {'Catch'|'Damage'|'BleedOut'} Lethal
 * @typedef {{slot: number, left: number, lifeState?: string}} Member
 */

/** A Luau array as JSON carries it: an empty table arrives as {} (JSON cannot tell it from an empty list). */
const items = (list) => (Array.isArray(list) ? list : []);

/**
 * The lives rules bound to a world's numbers.
 * @param {{livesConfig: {Standard: Record<string, number>, Nightmare: Record<string, number>},
 *   stageConfig: {playable: string[]}}} meta
 */
export function livesRules(meta) {
  const config = meta && meta.livesConfig;
  if (!config || !config.Standard || !config.Nightmare) throw new Error('the world carries no livesConfig');
  const playable = new Set(items(meta.stageConfig && meta.stageConfig.playable));

  /** LivesConfig.of: Standard's numbers for anything but "Nightmare". */
  const of = (difficulty) => (difficulty === 'Nightmare' ? config.Nightmare : config.Standard);

  /** @param {Lives} lives @returns {Lives} */
  const copy = (lives) => ({
    stage: lives.stage,
    run: lives.run,
    syringe: lives.syringe,
    downs: lives.downs,
    getUpUsed: lives.getUpUsed,
  });

  /** @returns {Lives} */
  function newRun(difficulty, syringe) {
    const c = of(difficulty);
    return {
      stage: 0,
      run: c.RespawnsPerRun,
      syringe: syringe ? c.SyringeRespawns : 0,
      downs: 0,
      getUpUsed: false,
    };
  }

  /** @returns {Lives} */
  function stageActivated(difficulty, lives, stageId) {
    const out = copy(lives);
    out.downs = 0;
    out.getUpUsed = false;
    if (playable.has(stageId)) out.stage = of(difficulty).RespawnsPerStage;
    return out;
  }

  /** @param {Lives} lives @param {string} lifeState @param {Lethal} hit */
  function lethal(lives, lifeState, hit) {
    const out = copy(lives);
    if (lifeState === 'Alive' && hit !== 'BleedOut' && lives.downs === 0) {
      out.downs += 1;
      return { outcome: 'Downed', lives: out };
    }
    return { outcome: 'Killed', lives: out };
  }

  /** @param {Lives} lives */
  function getUp(difficulty, lives, downedFor, held) {
    const c = of(difficulty);
    const allowed = !lives.getUpUsed && downedFor >= c.GetUpDelay;
    const up = allowed && held >= c.GetUpHold;
    return { allowed, up, health: up ? c.GetUpHealth : 0 };
  }

  function getUpTime(difficulty) {
    const c = of(difficulty);
    return c.GetUpDelay + c.GetUpHold;
  }

  function revive(difficulty, held) {
    const c = of(difficulty);
    const up = held >= c.ReviveHold;
    return { up, health: up ? c.ReviveHealth : 0 };
  }

  /** @param {Lives} lives */
  function respawnsLeft(lives) {
    return lives.stage + lives.run + lives.syringe;
  }

  /** @param {Lives} lives @returns {{source: 'stage'|'run'|'syringe'|'none', lives: Lives}} */
  function spend(lives) {
    const out = copy(lives);
    if (out.stage > 0) {
      out.stage -= 1;
      return { source: 'stage', lives: out };
    } else if (out.run > 0) {
      out.run -= 1;
      return { source: 'run', lives: out };
    } else if (out.syringe > 0) {
      out.syringe -= 1;
      return { source: 'syringe', lives: out };
    }
    return { source: 'none', lives: out };
  }

  /** @param {Lives} lives @returns {{action: 'Respawn'|'Spectate'|'RunOver', source: string, lives: Lives}} */
  function afterDeath(lives, squadSize) {
    if (respawnsLeft(lives) > 0) {
      const spent = spend(lives);
      const out = spent.lives;
      out.downs = 0;
      out.getUpUsed = false;
      return { action: 'Respawn', source: spent.source, lives: out };
    }
    return { action: squadSize <= 1 ? 'RunOver' : 'Spectate', source: 'none', lives: copy(lives) };
  }

  function respawn(difficulty, charges, torch, torchMax) {
    const c = of(difficulty);
    return {
      health: c.RespawnHealth,
      charges: Math.max(charges, c.RespawnCharges),
      torch: Math.max(torch, c.RespawnTorch * torchMax),
      grace: c.RespawnGrace,
      blackout: c.RespawnBlackout,
    };
  }

  /** @param {Member[]} squad */
  function chaseFailure(difficulty, failures, squad) {
    if (failures <= of(difficulty).ChaseFreeAttempts) return { free: true, payer: 0, runEnds: false };
    let payer = null;
    for (const member of items(squad)) {
      if (member.left > 0) {
        const best = payer;
        if (best === null || member.left > best.left || (member.left === best.left && member.slot < best.slot)) {
          payer = member;
        }
      }
    }
    if (payer === null) return { free: false, payer: 0, runEnds: true };
    return { free: false, payer: payer.slot, runEnds: false };
  }

  /** @param {Member[]} squad */
  function runEnds(squad) {
    for (const member of items(squad)) {
      if (member.lifeState === 'Alive' || member.lifeState === 'Downed' || member.left > 0) return false;
    }
    return true;
  }

  function checkpointReturn(difficulty, lifeState) {
    if (lifeState === 'Spectating' || lifeState === 'Dead') return { stand: true, health: of(difficulty).CheckpointHealth };
    return { stand: false, health: 0 };
  }

  return Object.freeze({
    of,
    newRun,
    stageActivated,
    lethal,
    getUp,
    getUpTime,
    revive,
    respawnsLeft,
    spend,
    afterDeath,
    respawn,
    chaseFailure,
    runEnds,
    checkpointReturn,
  });
}
