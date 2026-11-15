// skipVote.js: the cutscene skip vote (docs/design/game-spec-v2.md 2.3, 3.7; I7: the host owns it).
//
// Hold Skip 1.0 s (Enter, the gamepad's Skip button, the SKIP button; never Space or B), offered from 5 s in until the
// last shot. A hold is this page's vote: alone it is the host's own; in a squad a client sends it ({t: 'storyVote'})
// and the host counts. It passes when more than half the players have voted and every player who has not seen this
// cutscene has voted (a first-timer's veto; CinematicTracks.skipPasses); the Fall only once every member has seen it.
// Solo: at once. The host tells the squad the tally ({t: 'storyVotes'}) and, on a pass, the cut ({t: 'storySkip'}).

import { S } from '../strings/index.js';
import '../strings/story.js';
import { glyphFor } from '../ui/nav.js';
import { Fonts, Palette, el } from '../ui/style.js';

export class SkipVote {
  /** @param {import('./cinematics.js').Cinematics} cinematics */
  constructor(cinematics) {
    this.cin = cinematics;
    this.game = cinematics.game;
    this.env = cinematics.env;
    this.holding = false;
    this.held = 0;
    this.voted = false;
    /** host: who voted for the cutscene playing (member ids; '' alone) */
    this.votes = new Set();
    /** the tally shown on every page: {n, of, waits} */
    this.tally = null;
    this.root = el('div', 'rg-layer', this.env.uiRoot());
    Object.assign(this.root.style, { zIndex: '43', display: 'none', justifyContent: 'flex-end', alignItems: 'flex-start',
      padding: '14px 22px' });
    this.box = el('div', 'rg-caps rg-outline', this.root, '');
    Object.assign(this.box.style, { display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: '4px',
      color: Palette.Ash, fontFamily: Fonts.Strong, fontSize: '12px' });
    this.label = el('div', '', this.box, '');
    this.bar = el('div', '', this.box);
    Object.assign(this.bar.style, { width: '120px', height: '3px', background: Palette.Track });
    this.fill = el('div', '', this.bar);
    Object.assign(this.fill.style, { width: '0%', height: '100%', background: Palette.Bone });
    this.note = el('div', '', this.box, '');
    this.env.onAction('Skip', (phase) => this.press(phase));
  }

  /** A new cutscene: nobody has voted. */
  reset() {
    this.votes.clear();
    this.voted = false;
    this.held = 0;
    this.holding = false;
    this.tally = null;
  }

  press(phase) {
    if (phase === 'Begin') this.holding = true;
    else if (phase === 'End' || phase === 'Cancel') {
      this.holding = false;
      this.held = 0;
    }
  }

  /** The hold, on the tick. */
  tick(dt, t) {
    const c = this.cin.current;
    if (!c || this.voted) return;
    const offered = this.cin.tracks.skipOffered(c.id, c.cut, t) && !c.skipping;
    if (!offered || !this.holding) {
      if (!this.holding) this.held = 0;
      return;
    }
    this.held += dt;
    if (this.held >= this.cin.tracks.story.Skip.Hold - 1e-6) {
      this.voted = true;
      this.vote();
    }
  }

  /** This page's vote: the host's own, or sent to it. */
  vote() {
    const c = this.cin.current;
    if (!c) return;
    const coop = this.cin.coop();
    if (coop && coop.isClient()) coop.toHost({ t: 'storyVote', r: c.run });
    else this.cast(coop ? coop.localId : '', c.run);
  }

  /** Host (or alone): `memberId` voted to skip cutscene run `run`. */
  cast(memberId, run) {
    const c = this.cin.current;
    if (!c || c.run !== run || c.skipping) return;
    if (!this.cin.tracks.skipOffered(c.id, c.cut, this.cin.time())) return;
    this.votes.add(memberId);
    this.evaluate();
  }

  /** Host: the tally and, when it passes, the cut to the last shot. */
  evaluate() {
    const c = this.cin.current;
    if (!c || c.skipping) return;
    const coop = this.cin.coop();
    const players = coop ? Math.max(1, coop.participants().length) : 1;
    const present = coop ? new Set(coop.participants().map((m) => m.id)) : new Set(['']);
    const voters = [...this.votes].filter((id) => present.has(id));
    const unseen = this.cin.unseen(c.id).filter((id) => present.has(id));
    const passes = this.cin.tracks.skipPasses(c.id, players, voters, unseen);
    const waits = !passes && voters.length * 2 > players;
    this.showTally({ n: voters.length, of: players, waits, seenOnly: this.cin.timeline(c.id).skip === 'SeenOnly' });
    if (coop && coop.isHost()) coop.broadcast({ t: 'storyVotes', r: c.run, n: voters.length, of: players, w: waits });
    if (passes) this.cin.skipPassed();
  }

  showTally(tally) {
    this.tally = tally;
  }

  /** A member left: their vote goes with them (the host counts again). */
  memberLeft(id) {
    if (this.votes.delete(id)) this.evaluate();
  }

  frame() {
    const c = this.cin.current;
    const t = c ? this.cin.time() : 0;
    const offered = !!c && !c.skipping && this.cin.tracks.skipOffered(c.id, c.cut, t);
    this.root.style.display = offered ? 'flex' : 'none';
    if (!offered) return;
    const device = this.env.device();
    const text = device === 'Touch' ? S('Story.SkipTouch') : S('Story.Skip', glyphFor(this.env, 'Skip', device));
    if (this.label.textContent !== text) this.label.textContent = text;
    const share = this.voted ? 1 : Math.min(1, this.held / this.cin.tracks.story.Skip.Hold);
    this.fill.style.width = `${(share * 100).toFixed(0)}%`;
    const tally = this.tally;
    const note = !tally || tally.of <= 1 ? '' : tally.waits ? S(tally.seenOnly ? 'Story.SkipFirstTime' : 'Story.SkipWaits')
      : S('Story.SkipVotes', tally.n, tally.of);
    if (this.note.textContent !== note) this.note.textContent = note;
  }
}
