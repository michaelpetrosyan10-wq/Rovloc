// lobby.js: the squad lobby (LobbyService for a room), run by the host. Each page keeps its own bus, pads, consoles
// and perks (credits and perks are each player's own saved profile); what is shared goes through here.
//
//   Ready     a page's ready pad / READY UP sends {t: 'ready', on}; the host keeps the squad's flags.
//   Vote      the difficulty console's vote ({t: 'vote', d}); the squad's votes decide: Nightmare only with strictly more
//             votes than Standard (a tie or no vote plays Standard). The host may also just pick: its vote counts like
//             everyone's.
//   Countdown once every member is Ready (at least GameConfig.MinSquad), CountdownSeconds to deploy; anyone unreadying
//             or joining aborts it; every page shows it ({t: 'lobby', cd: seconds left | null, diff, votes}).
//   Deploy    at zero the host draws the run's seed and id and sends them ({t: 'deploy'}): every page deploys the same
//             run (its routes, plan and picks come from the seed) at its own spawn slot, consuming its own equipped perks.

import { GameConfig } from '../config.js';

const RUN_ID_ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789';

function newRunId() {
  const word = new Uint32Array(4);
  crypto.getRandomValues(word);
  let id = '';
  for (const w of word) for (let i = 0; i < 4; i++) id += RUN_ID_ALPHABET[(w >>> (i * 8)) % RUN_ID_ALPHABET.length];
  return `${Date.now().toString(36)}-${id}`;
}

export class LobbyNet {
  /** @param {import('./index.js').Coop} coop */
  constructor(coop) {
    this.coop = coop;
    this.game = coop.game;
    this.env = coop.game.env;
    /** host: when the countdown ends (game clock), or null */
    this.countdownEndsAt = null;
    /** the squad's tally as the host sent it */
    this.votes = { Standard: 0, Nightmare: 0 };
    this.chosen = 'Standard';
    this.deploying = false;
    this.handlers = {
      ready: (from, msg) => this._onReady(from, msg),
      vote: (from, msg) => this._onVote(from, msg),
      lobby: (from, msg) => this._onLobby(msg),
      deploy: (from, msg) => this._onDeploy(msg),
    };
  }

  reset() {
    this.countdownEndsAt = null;
    this.votes = { Standard: 0, Nightmare: 0 };
    this.chosen = 'Standard';
    this.deploying = false;
  }

  sessionEnding() {
    this.reset();
  }

  /** The difficulty the squad's votes pick. */
  difficulty() {
    return this.chosen;
  }

  /** Votes cast for a difficulty. */
  votesFor(d) {
    return this.votes[d] || 0;
  }

  /** [ready, total] for the lobby banner. */
  readyCount() {
    const list = this.coop.squad.list();
    return [list.filter((m) => m.ready).length, Math.max(GameConfig.MinSquad, list.length)];
  }

  // ---------------------------------------------------------------------------------------------------- this page

  /** This page's player readied / unreadied (the pad, R / Y, the touch button). */
  localReady(on) {
    const coop = this.coop;
    if (coop.isClient()) {
      coop.toHost({ t: 'ready', on: !!on });
      return;
    }
    if (coop.me) coop.me.ready = !!on;
    coop.touch();
    this._evaluate();
  }

  localVote(d) {
    const coop = this.coop;
    if (coop.isClient()) coop.toHost({ t: 'vote', d });
    else {
      if (coop.me) coop.me.vote = d;
      this._tally();
      this._send();
    }
  }

  // ---------------------------------------------------------------------------------------------------- host

  _inLobby() {
    const phase = this.game.phase;
    return phase === 'Lobby' || phase === 'Countdown';
  }

  _onReady(from, msg) {
    const m = this.coop.squad.get(from);
    if (!m || !this.coop.isHost()) return;
    m.ready = !!msg.on && this._inLobby();
    this.coop.touch();
    this._evaluate();
  }

  _onVote(from, msg) {
    const m = this.coop.squad.get(from);
    if (!m || !this.coop.isHost() || (msg.d !== 'Standard' && msg.d !== 'Nightmare')) return;
    m.vote = msg.d;
    this.coop.touch();
    this._tally();
    this._send();
  }

  _tally() {
    const votes = { Standard: 0, Nightmare: 0 };
    for (const m of this.coop.squad.list()) if (m.vote === 'Standard' || m.vote === 'Nightmare') votes[m.vote]++;
    this.votes = votes;
    this.chosen = votes.Nightmare > votes.Standard ? 'Nightmare' : 'Standard';
  }

  /** Starts or aborts the countdown from the squad's flags. */
  _evaluate() {
    if (!this.coop.isHost() || !this._inLobby() || this.deploying) return;
    const list = this.coop.squad.list();
    const allReady = list.length >= GameConfig.MinSquad && list.every((m) => m.ready);
    const game = this.game;
    if (allReady && this.countdownEndsAt === null) {
      this.countdownEndsAt = this.env.now() + GameConfig.CountdownSeconds;
      game.lobby.countdownEndsAt = this.countdownEndsAt;
      game.setPhase('Countdown');
      this.env.play('UiConfirm');
      this._send();
    } else if (!allReady && this.countdownEndsAt !== null) {
      this.countdownEndsAt = null;
      game.lobby.countdownEndsAt = null;
      if (game.phase === 'Countdown') game.setPhase('Lobby');
      this.env.play('UiBack');
      this._send();
    }
  }

  _send() {
    const left = this.countdownEndsAt === null ? null : Math.max(0, this.countdownEndsAt - this.env.now());
    this.coop.broadcast({ t: 'lobby', cd: left, diff: this.chosen, votes: this.votes });
  }

  /** A newcomer: the countdown stops (the squad changed) and they get the lobby's state. */
  welcome(member, msg) {
    if (!this._inLobby()) return;
    if (this.countdownEndsAt !== null) {
      this.countdownEndsAt = null;
      this.game.lobby.countdownEndsAt = null;
      if (this.game.phase === 'Countdown') this.game.setPhase('Lobby');
      this.env.play('UiBack');
    }
    this._tally();
    msg.lobby = { cd: null, diff: this.chosen, votes: this.votes };
    this._send();
  }

  welcomed(msg) {
    if (msg.lobby) this._onLobby(msg.lobby);
    if (!this.game.run && this.game.phase !== 'Lobby' && this.game.phase !== 'Countdown') return;
    // tell the host where this page's pad stands (Play Again arrives Ready)
    if (this.game.lobby && this.game.lobby.ready) this.localReady(true);
  }

  memberLeft() {
    if (this.coop.isHost() && this._inLobby()) {
      this._tally();
      this._evaluate();
      this._send();
    }
  }

  _deploy() {
    const game = this.game;
    this.deploying = true;
    this.countdownEndsAt = null;
    const seed = game.match.runSeed();
    const runId = newRunId();
    const difficulty = this.chosen;
    this.coop.runNet.deployed();
    this.coop.broadcast({ t: 'deploy', seed, d: difficulty, id: runId });
    game.lobby.deployWith(difficulty, { seed, runId, slot: this.coop.me ? this.coop.me.slot : 0 }).finally(() => {
      this.deploying = false;
    });
    for (const m of this.coop.squad.list()) {
      m.ready = false;
      m.vote = null;
    }
    this.coop.touch();
  }

  // ---------------------------------------------------------------------------------------------------- client

  _onLobby(msg) {
    if (!this.coop.isClient()) return;
    const game = this.game;
    this.votes = msg.votes || { Standard: 0, Nightmare: 0 };
    this.chosen = msg.diff === 'Nightmare' ? 'Nightmare' : 'Standard';
    if (!this._inLobby() || game.run) return;
    if (msg.cd === null || msg.cd === undefined) {
      if (game.lobby.countdownEndsAt !== null) this.env.play('UiBack');
      game.lobby.countdownEndsAt = null;
      if (game.phase === 'Countdown') game.setPhase('Lobby');
    } else {
      if (game.lobby.countdownEndsAt === null) this.env.play('UiConfirm');
      game.lobby.countdownEndsAt = this.env.now() + msg.cd;
      if (game.phase === 'Lobby') game.setPhase('Countdown');
    }
  }

  _onDeploy(msg) {
    if (!this.coop.isClient()) return;
    const game = this.game;
    if (game.run) return;
    if (game.onboarding && game.onboarding.busy()) game.onboarding.closeForCoop();
    game.lobby.deployWith(msg.d === 'Nightmare' ? 'Nightmare' : 'Standard',
      { seed: msg.seed, runId: msg.id, slot: this.coop.me ? this.coop.me.slot : 0 });
  }

  tick() {
    if (!this.coop.isHost() || this.countdownEndsAt === null || this.deploying) return;
    if (!this._inLobby()) {
      this.countdownEndsAt = null;
      return;
    }
    if (this.env.now() >= this.countdownEndsAt - 0.05) this._deploy();
  }

  phaseChanged(phase) {
    if (!this.coop.isHost()) return;
    if (phase === 'Lobby' && !this.game.run) {
      this.countdownEndsAt = null;
      this._tally();
      this._send();
    }
  }
}
