# Refuting "monster v3 stage 1 gives the player the cadence he asked for, is fun, and is not harder than today"

Role: the player's advocate. I did not build it. Tree: `/home/user/Rovloc/.claude/worktrees/mv3` at `e5c6e89` (nothing
changed there). Probes and raw outputs: `/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/mv3/refute/`.

**Verdict: the claim does not hold.** It fails on all three counts:

1. **The cadence.** Runners do not get it, and the long silences are as long as the "4 minutes" he complained about.
2. **"Not harder".** It is not shown. On the same build and the same seeds, v3 catches a careless sprinter more often
   than the v2 code does.
3. **Fairness.** The director's "never lethal" sniff kills a hider with no chase token and outside any encounter, on
   both floors.

## What I ran (three simulation runs, all through `run-heavy cpu`)

| run | what | command (from `refute/`) | output |
|---|---|---|---|
| 1 | v3 on **fresh seeds** (base 40009, never tuned on): Standard Sprinter 36 seeds x 2 floors; Walker, Croucher, a new **sprint-and-hide** mix, Easy Sprinter, Easy Walker 12 x 2 each; instrumented to log how each interaction was perceived (steps / cue / seen, distance, side, the bot's gait), the clock's class time, the bot's mode time | `PROBE_GRID=... node probe2.mjs --suite probe --seed-base 40009 --json run1.json` (probe2 = presence-sim + logging + `sprinthider` + a `probe` suite; nothing else changed) | `run1.json`, `run1-analysis.txt` (`node analyze.mjs run1.json`), `node analyze2.mjs run1.json` |
| 2 | **v2 code** (`git archive e820abb web/src web/tools`) on today's build with the v2 `CreatureConfig` restored in a scratch `world.json` (Lurk removed; Director menace/hint/beat keys, Shadow 15/25, Beats.Weights, Chase.CapSeconds/Breather pairs, Audio.RattleRadius, FloorGrace put back from the git diff). Check on the baseline's seeds, then on run 1's fresh seeds | `cd v2/web && node tools/presence-sim.mjs --report --seeds 12 --seed-base 1029 --floors L0 ...` and `--seeds 36 --seed-base 40009 --floors L0,L1 --difficulties Standard --players 1 --bots objective` | `run2-v2-check.*`, `run2-v2-fresh.*` |
| 3 | the director's sniff (C4) on a hider who fails the breath check, with 0 and 1 tokens, Basement and Hallways (`c4b.mjs`); co-op pairs of Sprinters and of Walkers, fresh seeds 12 x 2 | `node c4b.mjs <level> <tokens>`; `PROBE_GRID=... node probe2.mjs --suite probe ...` | `run3-c4.txt`, `run3-pair.json`, `run3-pair-analysis.txt` |

I also re-ran, without simulating, the earlier read-only probes over the builder's own `tmp/presence-all.json`. Their
outputs were byte-identical: `tails-presence-all.txt`, `chases-presence-all.txt`, `presence-compare.txt`. Before
run 1, a 90-second smoke floor checked that probe2 runs.

## Findings (most severe first)

### F1 [blocker]: the "never lethal" director sniff (C4) kills a hider, with no token and no encounter

- **Evidence.** In `run3-c4.txt` the director's C4 is started on a hidden player. The game's breath check is played
  out: a failed check gives "Caught" and the Gasp noise at the door, as `lockers.js _gasp` does.
- In all four cases the sniff ends in a catch:

  ```
  40.3 Patrol->Search enc=-Infinity tok=0.00
  inspect#1 L0_Cabinet_23 directed=true state=Search t=42.3
  44.4 Search->InvestigateNoise enc=-Infinity tok=0.00
  inspect#2 L0_Cabinet_23 directed=false state=InvestigateNoise t=46.2
  {"level":"Level0_Basement","tokensHeld":0,"caught":[{"at":48.9,"kind":"Locker"}] ...}
  ```

  The Hallways is the same: caught at 53.0 with 0 tokens and with 1. The sequence:
  1. The directed inspection is a scare, as built.
  2. The gasp it causes is heard while he is in `Search`.
  3. `lurker.js:604` only drops a heard noise when `!SEARCHES.has(st)`, so with no token he still goes
     `InvestigateNoise`.
  4. His own, non-directed sniff reaches in.
- After a gasp the player has about 4 s at `BreathRecoverPerSecond` 0.6. That is about 2.4 s of breath for the second
  check, so failing it is the expected result, not a stretch.
- **Why the gates missed it.** Neither presence-sim nor creature-sim registers a locker inspector (no
  `registerLockerInspector` in either). The breath check never runs, so "C4 never lethal", "downs Hider 0" and "every
  down inside a token-paid encounter" are untested against the game's lockers.
- **What the player loses.** Spec 1.9 promises: "A sniff he was not led to by you never kills you."
- **Change.**
  - After a director C4, and for `DefenceWindow` past its end, treat the hider's Gasp as part of the C4. It gives the
    Reply (heavy steps toward it) and never `InvestigateNoise`.
  - In general, apply the no-token rule in Search too: drop `!SEARCHES.has(st)` for noises made by the C4's target.
  - Add a locker inspector to presence-sim. Its Hider and Croucher bots fail one breath check in N, so the danger
    suite measures it.

### F2 [blocker]: "not harder" is not shown, and on like-for-like runs v3 is harder for a careless sprinter

**Evidence, all for the Standard solo Sprinter.**

| | Basement downs/floor | 2+ downs | Hallways downs/floor | 2+ downs |
|---|---|---|---|---|
| shipped baseline (`presence-v2.json`, seeds 1029.., captured 11:51 on the old build) | 0.69 | 8 % | 0.44 | 6 % |
| v3, report (same seeds, today's build) | 0.72 | 11 % | 0.47 | 0 % |
| **v2 code, today's build, baseline seeds** (run 2) | **0.50** | 3 % | | |
| **v2 code, today's build, fresh seeds 40009..** (run 2) | **0.64** | 6 % | **0.47** | 8 % |
| **v3, today's build, fresh seeds 40009..** (run 1) | **0.78** | **19 %** | **0.58** | 6 % |

- **Comparisons on the same build.** In all three, v3 is above v2 by 0.11 to 0.22 a floor. That is two to four times
  the gate's +0.05 allowance.
- **Per chase.** v3 has about half the chases, and each one is far deadlier.
  - Basement: 30 % of v3 chase starts end in a catch, against 11 % for v2 (28 of 92 against 23 of 215).
  - Hallways: 16 % against 8%.
- **The baseline comparison is not on the same footing.**
  - The v2 code with the v2 config on today's build reproduces only 3 of the baseline's 12 rows, and gives 0.50
    instead of 0.69 on the baseline's own 36 seeds.
  - The build was regenerated (`npm run data` at 12:10, 13:16 and 13:28) after the baseline was captured (11:51).
  - So the gate compares v3 on the new build against v2 on the old build. That gap alone is about 0.2 a floor, four
    times the allowance.
  - Caveat: I cannot rule out that my scratch v2 config differs from the real one somewhere. The diff I applied is
    the whole `CreatureConfig.luau` diff outside `Lurk`. That is the only uncertainty in the table.
  - The run-to-run spread (36 seeds, roughly ±0.15) is the code's own figure. The difference is suggestive (about
    1.5 sigma pooled), not proof. Either way, it is the opposite of "not harder holds on every measure".
- **Change.**
  - Recapture the v2 baseline on the build being judged, and record the build's hash in the baseline file.
  - Assert v3 ≤ v2 on both the tuning seeds and an untuned set (e.g. 40009 + 977 i).
  - Add "catches per chase start ≤ v2's" to the danger suite. Then find out why chases got deadlier; the two
    suspects are deviation 10 (a chained chase continues the encounter for free) and deviation 7 (see F5).

### F3 [blocker]: the cadence he asked for is not there for runners, and the silences are as long as his complaint

- **Medians, perceived gaps, fresh seeds** (`run1-analysis.txt`):

  | profile | median | p90 | target median | target p90 |
  |---|---|---|---|---|
  | Sprinter | 36.5 s | 82.8 s | 15..20 s | 36 s |
  | Walker | 34.9 s | 88.0 s | 26..34 s | 62 s |
  | Croucher | 59.1 s | | (meets its target) | |

- **Tails.** The report's median hides these.
  - Sprinter: on the median floor the longest silence is 97.7 s. 20 of 72 floors have a silence of 120 s or more;
    the worst is 196 s.
  - Walker: 12 of 24 floors have a silence of 120 s or more; the worst is 182 s.
- **Co-op.**
  - Builder's own data: pair 238.7 s, four 279.5 s, split 223.8 s; 28 of 48 four-player players have a silence of
    120 s or more (`tails-presence-all.txt`).
  - Run 3, Sprinter pairs: 22 of 48 players at 120 s or more, worst 234 s.
  - **He said "4 minutes too much". 280 s is 4.7 minutes.**
- **The clock is honest; delivery is not.**
  - From the bots' class time, the clock owes a Sprinter one interaction every 18.7 s. It delivers at 1.95 x that
    gap; the Walker at 1.44 x; the Croucher at 0.96 x.
  - Half the planned interactions reach nobody: 433 of 943 for the Sprinter (46 %).
  - The spec's "clock is honest" ratio check (8.3, 0.85..1.2) is not implemented, and the report never states this
    ratio.
- **Change.**
  - Add a longest-silence target per profile (p95 of the longest silence ≤ 2 x the target median; co-op "nobody over
    90 s" made binding).
  - Add a last-resort rule: a player at Sprint or Walk class with nothing perceived for 60 s (Crouch 100 s) gets the
    next move as a reach-by-construction move. That means an H1b whose leg ends within 50 straight of where they will
    be in 3 s, or the catch-up run ending in earshot, out of view.
  - F4 and F6 below remove two of the causes.

### F4 [major]: the teleport-warning cap is used up by warnings nobody perceived

- **Evidence.**
  - 285 of 386 C3/Approach warnings aimed at the Sprinter reached nobody (74 %): Walker 86 of 121, Easy Sprinter 104
    of 135.
  - On 64 of 72 Sprinter floors the 2-per-180-s cap was, at some point, full of warnings the player never perceived.
    On average that state lasted 153 s per 480-s floor.
  - `lurker.js:521` calls `noteWarn` when the warning fires, whatever it reached.
- **A worked example** (builder's run, Hallways Sprinter seed 4937):
  1. `26.3 Approach []`, `32.3 H1b []`, `52.1 Approach []`, `58.7 H1 []`: nothing reaches the player.
  2. Nothing is planned for 73 s.
  3. `131.9 X [1]`: the first thing he ever perceives on that floor is a chase, which catches him at 136 s.
- The report's section 5 calls the teleport "the only bridge" for runners, and this bridge is closed for a third of
  the floor by teleports the player never noticed.
- **Change.** Count a warning toward `WarnMax` only if its hiss or his forming reached the target. Move `noteWarn` to
  `settle` when `reached[target]`. An unperceived approach is then a silent reposition, still out of view and beyond
  12.
- **What it protects.** The player's Nov 15 dislike was of teleports he saw.

### F5 [major]: "harmless" heard interactions turn into chases, because he is placed in the runner's path

- **Evidence** (run 1, Standard Sprinter, 72 floors).
  - 78 of the 155 chases started within 5 s of the end of a planned non-chase interaction: H1b 16, Approach 21, H1
    14, S2 10, others 17.
  - 67 more such interactions became near misses.
  - 15 of the 49 catches came from these chases.
  - In the builder's tuned run, the most common pairs counted inside 5 s are `H1b>NearMiss` 14, `H1b>X` 11 and
    `H1>NearMiss` 8.
- **Cause.**
  - Deviation 7: hold points for a moving focus are ranked "nearest where they will be in 5 s", "so a runner comes to
    him".
  - The approach lands "within 40 straight of where they will be".
  - A runner then passes within `Beats.Near` 12, which counts as a provocation.
- **Change.**
  - Keep the spec's `OffRoute` 10 rule: hold points beside the line of travel, not on it.
  - Make a sighting within 12 during a tier-0 interaction, and for 5 s after it, no provocation. `DefenceWindow`
    covers only hiding today; extend it.
  - Assert "chases starting within 5 s of a heard interaction: 0".

### F6 [major]: downs that come with no warning

- **Evidence.**
  - Fresh seeds, Standard Sprinter: 19 of 49 catches came after more than 30 s in which the victim perceived nothing
    of him, strays included. 18 were caught within 8 s of the chase's start.
  - Builder's run: 13 of 37 solo downs came after more than 30 s with nothing, strays included (`cold.txt`). Examples:
    - Hallways Sprinter 4937: the chase is the first thing perceived on the floor, at 132 s; caught in 4 s.
    - Basement Walker 5914: 100 s of nothing, then caught 8 s into the chase.
- In v2 he was always audible: the rattle every 4.5..8 s within 45, steps to 80. v3 removed that on purpose, so a
  token chase can now start cold.
- The "first interaction ≤ 25 s, heard" check fails in the report (latest 131.9 s) but is not in the verdict.
- **Change.** A token chase may start only on a player who perceived something of him in the last 20 s. If they have
  not, the trigger gives a tell first (H1b or the rattle) and the chase waits for the next trigger.

### F7 [major]: the cadence is credited for things a runner probably cannot hear (generous reach rule)

- **The rule.** "Two footfalls with the ear within 80 straight" counts as perceived. It has no masking term and no
  wall term, and the sight rule has no light term.
- **Measured levels** (the gate's own audio-test, `tmp-integ2b/gates/audio-test.log`):
  - His quietest step at 80 studs: −30.4 LUFS. The beds: −37.7.
  - The player's own sprint step: −35.7 LUFS at 10 studs (roll-off min 7). At the ear that is about −32.4.
  - So at 80 studs his step is only about 2 dB over the sprinter's own footfalls, which fall three times a second.
    At 50 studs it is about 10 dB over (the inverse-tapered roll-off, `rolloff.js`).
- **Run 1, Sprinter.**
  - Footfalls are 50 % of everything perceived, and 28 % of the footfall perceptions are beyond 60 studs.
  - 42 % of all his perceptions happened while he was sprinting.
  - He *saw* the monster in only 8 % of them.
- **Change.**
  - Have audio-test measure his step against the listener's own gait at the ear.
  - Give `Audible.StepHeavy` per listener gait (about 50 for a sprinting listener, the 10 dB rule audio-test already
    uses).
  - Re-measure the runner cadence with it. The real gap is likely longer than 36 s.

### F8 [major]: the bots: who the numbers describe

- **Sprinter.** Class time is Sprint 53 % and Walk 43 %; spec 2.2's tuning assumed 63/37. 27 % of its floor is spent
  fleeing (`flee/Sprinting` 15 %, `flee/Standing` 12 %).
- **Walker.** It sprints 21 % of the time, while fleeing. The clock therefore expects 24 s, not 30.
- **Croucher.** It is in a locker 43 % of the floor and completes 1.0 objective in 8 minutes; the Walker completes
  5.3. Its "cadence holds" mostly rides on Hiding-class time (Gap 75). A player who crouches and does not hide is
  never measured.
- **Hider.** It completes 0.0..0.3 objectives a floor (`presence-all`), so it is not a playing player.
- **My sprint-and-hide mix** (sprints, hides when warned, chased or seen close; the closest bot to a real kid):
  - median gap 36.3 s; hidden 56 % of the floor; 4.0 objectives
  - 0.04 downs; worst silence 170 s
- **Change.**
  - Add to the gate a Croucher that never hides, and the sprint-and-hide mix.
  - Report class time, mode time and the clock ratio per profile.

### F9 [major]: what he asked for that stage 1 does not deliver, and the verdict does not say so

- **"make the monster appear more".**
  - The seen tier is 3..10 % of interactions in the report's table; the spec target is 25..40 %. There is no check for
    it.
  - Fresh seeds: he was seen in 8 % of a Sprinter's interactions.
  - The spec's tier-share and "last third vs first third" (escalation) measures are not implemented.
- **"crawl under the little holes".** Stage 2. Not built.
- **"talks good English / real words".** The H5 hook, the stub voice director and `setVoice` are not built
  (deviation 1), though spec 1.13 says "the game is ready for them from the first build". The "a Walker hears a line
  in 8..15 %" measure is absent.
- **"Monster activity" setting.** Not built.
- **Easy.** It exists only in the sims (`web/src/game/config.js:67`: `Difficulties = ['Standard', 'Nightmare']`), so
  the report's Easy rows do not help a player who finds it "too hard".
- **Unimplemented spec measures.** Clock honesty, near misses per floor, chase spread, Croucher downs < 0.25, tier
  share, escalation.
- **Change.** The verdict paragraph should list these plainly, next to "cadence missed for runners".

### F10 [minor]: repetition, and one event counted twice

- **What a Sprinter perceives, by family** (fresh seeds):

  | family | share |
  |---|---|
  | footsteps (H1, H1b, F, Reply) | 44 % |
  | chase starts | 20 % |
  | screech near misses | 14 % |
  | teleport hiss | 13 % |
  | seen | 8 % |

- The longest run of one family is 5: five footstep interactions in a row. "Never the same type twice" holds only
  because H1 and H1b alternate, and both are his footsteps.
- A third of a runner's "interactions" are chases or screeches: 2.15 chases and 1.46 near misses a floor.
- 45 of 698 Sprinter gaps are under 5 s, mostly a heard interaction followed by its own near miss or chase. That is
  one event to the player, counted as two. With follow-ups merged inside 10 s, the builder's Sprinter median is
  43.8 s, not 38.9 s (`tails-presence-all.txt`).
- **Change.** Apply "never the same twice" to sound families. Merge records within 10 s into one beat in the gap
  measure.

### F11 [minor]: strays: the cheapest way to his cadence is counted as a failure

- With strays counted (his footfalls or sightings perceived outside a planned interaction), the perceived gap median
  is about 20 s for runners on fresh seeds: Sprinter 20.4, Walker 20.1.
- The gate fails strays above 1 per 2 minutes, and the cadence ignores them.
- **Change.** Turn the trailing and catch-up contacts into paced tier-0 beats that count, rather than suppressing
  them. The tails in F3 still need the last-resort rule.

### F12 [minor]: the repeat-target rule is bypassed through heard noises (seen in Mixed pairs)

- **The bypass.** `mayTarget` (RepeatAfter, 2 x Refill = 300 s) gates only sightings and stares (`lurker.js:587`). A
  heard noise with a token goes to `InvestigateNoise` without it (`lurker.js:604`).
- **Builder's co-op Mixed rows.** 17 of 58 consecutive chases hit the same player again 45..300 s later, for example
  pair Basement 4937: X->1 at 101.3, 261.6 and 458.4. Player 1 took 40 chases against player 2's 20.
- **Run 3.** Sprinter and Walker pairs: 0 such repeats, chases evenly split (30/29 and 25/29). So it shows with hiding
  players only.
- The spec's chase-spread check is not implemented.
- **Change.** Apply `mayTarget` when `InvestigateNoise` turns into a chase. The repeat target gets the near miss
  instead. Add the chase-spread check.

## Checked and not refuted

- **Sounds from his position.** 0 off in the report. Steps are logged at his feet and the hiss at the warned spot,
  by design.
- **Chase after chase within 45 s.** Fresh Standard Sprinter: 0. Builder's run: 8, 7 of them on Nightmare (Breather
  15).
- **Co-op runner pairs.** Downs are low: 0.29 / 0.21 a player a floor, against v2 pairs at 0.43 / 0.31.
- **Speed cap.** Never over 19.

## Files

- Probes: `refute/probe2.mjs`, `refute/analyze.mjs`, `refute/analyze2.mjs`, `refute/c4b.mjs`, `refute/cold.mjs`;
  earlier `refute/tails.mjs`, `refute/chases.mjs`, `refute/presence-compare.mjs` (all re-verified).
- v2 reconstruction: `refute/v2/web` (`build/world.json` patched; `world.bin`, `audio` and `textures` link to the
  worktree's).
- Outputs:
  - `refute/run1-analysis.txt`, `refute/run1.json`
  - `refute/run2-v2-check.log`, `refute/run2-v2-fresh.log` and their `.json`
  - `refute/run3-c4.txt`, `refute/run3-pair-analysis.txt`
  - `refute/cold.txt`, `refute/tails-presence-all.txt`, `refute/chases-presence-all.txt`, `refute/presence-compare.txt`
