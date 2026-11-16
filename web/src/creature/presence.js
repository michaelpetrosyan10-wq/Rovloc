// The presence layer (docs/MONSTER.md 15-19): the director above the Creature's own brain and its numbers.
//
// The numbers are CreatureConfig.Presence (src/ReplicatedStorage/Shared/Config/CreatureConfig.luau), exported into
// world.json meta.creatureConfig.Presence; presenceConfig(meta, difficulty) reads them for one difficulty (a
// {Standard, Nightmare} pair becomes the difficulty's number). Nothing here holds a copy.
//
// The Director (Alien: Isolation's two brains): it knows where the players are; the Creature only knows what its
// senses tell it. The director keeps a MENACE per player (0..1): it rises while the Creature is far from them
// (FarWalk walked), unseen by them and not after them, and drops to 0 at an encounter (a chase on them, a catch, a beat
// that reached them, them seeing it), which also starts a quiet spell on them (QuietSeconds: no hint, no beat). Its focus
// is the player with the highest menace out of their quiet spell; in co-op a player left alone for StarveSeconds goes
// first (the longest left alone), so it never tunnels one player while another is left for minutes. The service asks
// it, once per Interval, what to do about the focus (order()): a beat, a search hint, nothing. Pure: no clock, no world.

const DIFFICULTY_KEYS = new Set(['Standard', 'Nightmare']);

/** A {Standard, Nightmare} pair? */
function isPair(v) {
  return !!v && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length === 2 &&
    Object.keys(v).every((k) => DIFFICULTY_KEYS.has(k));
}

/** `value` with every {Standard, Nightmare} pair resolved for `difficulty`, frozen. */
function resolve(value, difficulty) {
  if (isPair(value)) return value[difficulty];
  if (Array.isArray(value)) return Object.freeze(value.map((v) => resolve(v, difficulty)));
  if (value && typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = resolve(v, difficulty);
    return Object.freeze(out);
  }
  return value;
}

/**
 * CreatureConfig.Presence for one difficulty (meta.creatureConfig.Presence).
 * @param {any} meta world.json @param {string} difficulty
 */
export function presenceConfig(meta, difficulty) {
  const config = meta && meta.creatureConfig && meta.creatureConfig.Presence;
  if (!config) throw new Error('the world carries no creatureConfig.Presence');
  return resolve(config, difficulty === 'Nightmare' ? 'Nightmare' : 'Standard');
}

/**
 * @typedef {{player: any, walk: number, sees: boolean, chased: boolean}} Reading what the director reads of one
 *   player this tick: its walking distance to them, whether they see it, whether it chases them
 */

export class Director {
  /** @param {any} config presenceConfig(...).Director */
  constructor(config) {
    this.config = config;
    /** @type {Map<any, {menace: number, quietUntil: number, pressuredAt: number}>} */
    this.players = new Map();
    this.nextHintAt = 0;
    this.nextBeatAt = 0;
    this.nextApproachAt = 0;
    this.focusPlayer = null;
    this.lean = null;
  }

  /**
   * A level's activation (or a run's start): every player starts at StartMenace (it comes looking for them once its
   * start hold lets it go); the first beat waits FirstBeat.
   */
  reset(now) {
    this.players.clear();
    this.nextHintAt = now;
    this.nextBeatAt = now + this.config.FirstBeat;
    this.nextApproachAt = now;
    this.focusPlayer = null;
    this.lean = null;
  }

  _entry(player, now) {
    let e = this.players.get(player);
    if (!e) {
      e = { menace: this.config.StartMenace, quietUntil: -Infinity, pressuredAt: now };
      this.players.set(player, e);
    }
    return e;
  }

  forget(player) {
    this.players.delete(player);
    if (this.focusPlayer === player) this.focusPlayer = null;
    if (this.lean === player) this.lean = null;
  }

  menaceOf(player) {
    const e = this.players.get(player);
    return e ? e.menace : 0;
  }

  /**
   * An encounter with `player` (a chase, a beat that reached them, them seeing it; a catch, `caught`): menace 0, a
   * quiet spell on them (QuietSeconds; QuietAfterCatch after a catch).
   */
  encounter(player, now, caught = false) {
    const e = this._entry(player, now);
    e.menace = 0;
    e.quietUntil = Math.max(e.quietUntil, now + (caught ? this.config.QuietAfterCatch : this.config.QuietSeconds));
    e.pressuredAt = now;
  }

  /**
   * One tick: every playing player's menace. Players not read this tick keep their numbers.
   * @param {number} now @param {number} dt @param {Reading[]} readings
   */
  update(now, dt, readings) {
    const c = this.config;
    for (const r of readings) {
      const e = this._entry(r.player, now);
      if (r.chased || r.sees) {
        this.encounter(r.player, now);
        continue;
      }
      if (r.walk <= c.FarWalk) e.pressuredAt = now;
      else e.menace = Math.min(1, e.menace + dt / c.MenaceSeconds);
    }
  }

  /**
   * The player it turns to now (null: none): one left alone for StarveSeconds (the longest) first, else the highest
   * menace out of their quiet spell (ties: the one left alone longest).
   * @param {number} now @param {any[]} candidates the players it may turn to (playing, on its level, not hidden away)
   */
  focus(now, candidates) {
    const c = this.config;
    let best = null;
    let bestKey = null;
    for (const p of candidates) {
      const e = this._entry(p, now);
      if (now < e.quietUntil) continue;
      const alone = now - e.pressuredAt;
      const starved = candidates.length > 1 && alone >= c.StarveSeconds;
      const key = [starved ? 1 : 0, starved ? alone : e.menace, alone];
      if (!bestKey || key[0] > bestKey[0] || (key[0] === bestKey[0] && (key[1] > bestKey[1] ||
        (key[1] === bestKey[1] && key[2] > bestKey[2])))) {
        best = p;
        bestKey = key;
      }
    }
    this.focusPlayer = best;
    // the patrol leans toward the focus, else (everyone in a quiet spell) the one with the highest menace
    let lean = best;
    if (!lean) {
      for (const p of candidates) if (!lean || this._entry(p, now).menace > this._entry(lean, now).menace) lean = p;
    }
    this.lean = lean;
    return best;
  }

  /** The player the patrol's next loop leans toward (the focus, else the highest menace), or null. */
  leaning() {
    return this.lean;
  }

  /**
   * What to do about the focus player now: 'Beat' (its menace reached BeatMenace, it is BeatWalkMin..BeatWalkMax
   * walked from them and the beats' cooldown is over), 'Hint' (menace HintMenace, farther than LeashWalk, the hints'
   * cooldown over), or null.
   * @param {number} now @param {any} player @param {number} walk its walking distance to them
   */
  order(now, player, walk) {
    const c = this.config;
    if (!player) return null;
    const menace = this.menaceOf(player);
    if (menace >= c.BeatMenace && walk >= c.BeatWalkMin && walk <= c.BeatWalkMax && now >= this.nextBeatAt) return 'Beat';
    if (menace >= c.HintMenace && walk > c.LeashWalk && now >= this.nextHintAt) return 'Hint';
    return null;
  }

  /** A hint was handed out (or none could be: try again after HintEvery). */
  hinted(now) {
    this.nextHintAt = now + this.config.HintEvery;
  }

  /** A beat started (or none fitted the geometry: the next try after BeatRetry). */
  beat(now, started) {
    this.nextBeatAt = now + (started ? this.config.BeatEvery : this.config.BeatRetry);
  }

  /** Whether an approach teleport may run now. */
  approachReady(now) {
    return now >= this.nextApproachAt;
  }

  approached(now) {
    this.nextApproachAt = now + this.config.ApproachCooldown;
  }

  snapshot(now) {
    const out = [];
    for (const [player, e] of this.players) {
      out.push({ userId: player && player.userId, menace: +e.menace.toFixed(3), quiet: Math.max(0, e.quietUntil - now),
        alone: now - e.pressuredAt });
    }
    return { focus: this.focusPlayer ? this.focusPlayer.userId : null, players: out };
  }
}
