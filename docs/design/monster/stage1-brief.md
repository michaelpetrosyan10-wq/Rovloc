# Monster v3, stage 1: builder's brief

Spec: `scratchpad/mv3/monster-v3-spec.md` (revised after the player's review; part 12 lists what changed). Section
numbers below are the spec's. Website only (`web/`), plus the shared config. Every number is in `CreatureConfig.Lurk`
(spec 2.2); do not hard-code one.

**Goal.** The player asked (Nov 16 15:30): an interaction about every 15-20 s sprinting, 30 s walking, 60 s
crouching; the monster lurks in a radius; more fun; not harder than today. Stage 1 delivers that cadence **with
today's rig and today's sounds**. The holes come in stage 2.

## Build in this order (each step leaves the tree green)

1. **Baseline first, on the unchanged tree.** If `web/tools/presence-sim.mjs --report` does not print objectives done
   in 8 minutes per profile, add that column (no behaviour change). Then capture
   `web/tools/baselines/presence-v2.json` once (about 9 min, `nice -n 10`). Commit it alone.
2. **Config.** `src/ReplicatedStorage/Shared/Config/CreatureConfig.luau`: `tri()`, the whole `Lurk` table (2.2), the
   `Presence` changes (2.4), `exportMeta` gains `Lurk`. `web/src/creature/presence.js`: Easy keys, `resolve`,
   `lurkConfig`. `npm run data` in `web/`. creature-sim `SPEC` rows (8.3) in the same commit.
3. **Pure core** `web/src/creature/lurk.js` (no THREE, no clock, no random: 10): `integrate` (rate with `LullComp` and
   `Activity`, group rate, share, backstage), `settle` (carry, lull, group settle within 15, `HeardShare`,
   `HeardCost`, tell side), strain events (near miss -> backstage), `who` (starve 60, stint, score), `feasible`
   (class, strain, floor, timers incl. `lastType` and `SamePlayer`, warn cap, `TellHolds`, body, built), `weights`
   (Fit incl. `FitOf.Hiding/Work/Still`, progress, `spend` only for Sprint/Walk/loud), `bucket` (refill draw),
   `spend` (provocation only, repeat target, short refund), owed hide, `snapshot`. `web/tools/lurk-test.mjs` + JSON
   fixture in the golden-row format.
4. **Service wiring** (`service.js`, `brain.js`): `beginRun` seed; `integrate` in `step()`; `_direct` -> `decide`;
   the `interaction` signal and reach (4.0) with `X`, `NearMiss`, `Stray` records; classes Work/Still from
   `_onNoise` (`workAt`), lumps only within 12 of the maker; `Summary.token` / `alerted`; the defence rule and
   HidingResponse gate (5.6); the near miss state `states/nearmiss.js` (sting, swell, walk out / back away / dissolve
   last; squad 25 s); rescue; `noteSetPiece`.
5. **Movement and leash** (`states/patrol.js` lurk mode, 3.6, 5.5): hold; trail at 11 out of hearing (30 from every
   ear, unseen); creep <= 10 studs near an ear; longer moves wait for a slot; heavy whenever seen; hold points off
   route (10 from the next 5 s of travel), tell side 12 s, lure side 15 s; the lead point (5 s) for Sprint-class
   targets (4.0). `view.js`: gait `Creep` volume x0.25, `Run` plays the `Chase` cycle.
6. **Catalogue on today's rig**: H1, **H1b** (13, `CreatureStepChase*`), H2 (`_lurkCue`), H4 (`lockers.js` nudge, door
   ajar 0.15 for 120 s), F, **Reply** (4.17), S1/S2 from the lead point (`beats.js` `from`), **S3** (`planVantage`,
   Vantage hold in `states/peek.js`: target's stare off, torch 7° 0.5 s -> walk back), C1, C2, C3 (warn cap, tell
   hold), C4 (`searchSpots`; director C4 never lethal; window clip to breath left - 0.5, min 1.5), approach (limits of
   3.4 step 5 (b); no `TorchStutter`). `monsterFx.js` rattle states and radius.
7. **Heartbeat**: `heartRadius()` shared by `web/src/creature/index.js` and `web/src/game/ui/hints.js`: 15 quiet, 45
   alarmed, 8 s tail; `snapshot().alarm`.
8. **Co-op** (5.7): `ccue`, `cst.g`, `cst.al`, the locker nudge event, `WIRE_STATE`; stints (5.1).
9. **Voice hook** (7): `setVoice`, H5 offers, the three event offers, `web/tools/stubs/voice-stub.mjs`;
   `Voice.Enabled` stays 0 in the game.
10. **Beta setting** "Monster activity: Less / Normal / More" (`game/ui/title.js` settings, `game/strings/base.js`),
    beta build only, host's value in co-op.
11. **Sounds test** (`web/sounds/test.mjs`): report director keys with fewer than 4 variants (do not fail yet).
12. **Sims and docs**: presence-sim profiles (Sprinter, Walker, Croucher, Hider, Mixed, split pair, stub voice) and
    measures (8.3), `--suite cadence` and the trimmed `--suite danger` (8.4); creature-sim cases (8.3); audio-test
    `Audible` keys; `docs/MONSTER.md` 22..27, 15.x and 20 marked replaced. Beta note: the holes come next; what the
    setting is for.

## Acceptance (Standard solo, Basement and Hallways, unless named)

| Measure | Pass |
|---|---|
| gap median (p90) | Sprinter 15..20 s (<= 36); Walker 26..34 (<= 62); Croucher 50..70 (<= 110); Hider 40..75 (<= 110); a lull on every Walker floor |
| first interaction | <= 25 s, heard |
| type mix | per profile no type > 35 %; never the same type twice running; Approach + C3 <= 25 % per profile, <= 2 per player per 180 s |
| strays / heartbeat | strays <= 1 per player per 2 min; panic floor on < 35 % of a Walker's time |
| chases a floor | 2..4 Sprinter, Walker, Mixed; Croucher 0..2; no player the target of > half (co-op) |
| downs | Sprinter 0.3..0.8 and <= baseline + 0.05, floors with 2+ <= 20 %; careful < 25 % floors with a down; Croucher < 0.25; Hider outside a chase's encounter 0; every down inside a token-paid encounter |
| careful time | careful bot and Croucher objectives in 8 min within 15 % of baseline |
| hiding | >= 1 hide in 3 gets C2 or C4 (Hider) |
| strain / leash | strain >= 0.8 < 15 % of time; in band >= 60 %; within 15 walked without tier 2 or chase < 3 % |
| near miss / voice stub | near misses squad-wide >= 25 s apart; stub: a line in 8..15 % of a Walker's interactions, never two within 45 s |
| co-op | pair together: starts >= 6 s apart, each median 0.85..1.43 x solo, nobody > 90 s; split pair: median <= 2 x solo, nobody > 90 s, warnings <= 1/3 |
| fairness | every sound from where he is; teleports warned, never in view, never within 12; speed <= 19; same seed same log; 20 = 144 fps; <= 40 path queries per director step |
| gates | lurk-test, creature-sim, presence cadence + danger (each suite under 6 min), tier-parity, objective-run, game-smoke, data-test, sounds, coop green |

## Tests to add or change
New: `web/tools/lurk-test.mjs` + fixture; `web/tools/stubs/voice-stub.mjs`; presence-sim `--suite cadence` and
`--suite danger` (Auditorium to `--report`), new profiles and measures; creature-sim's new cases (spec 8.3 list);
audio-test `Audible` keys; sounds test variant report. Changed: creature-sim `SPEC` rows (delete the old Director
rows, add the Lurk rows); presence-sim's chase counting also emits `X` records.

## Do not touch
- No Roblox runtime file (the port waits for the player's word, Nov 16 21:45); only `CreatureConfig.luau` under `src/`.
  No `LurkRules.luau` yet (stage 3).
- No crawl state, crawl edges, ducts or grates (stage 2); `nav.js` keeps crawlways closed to him.
- No new rig action or art (MONSTER-LOOK first); no browser TTS, no subtitle-only lines; `Voice.Enabled` stays 0.
- Chase pace, cap, wind-up, catches, the stare, the hiding stay limit, fake-outs, the pull-out, lives: unchanged.
- No Easy in the lobby or in `Enums.Difficulty`. Nothing reads a graphics tier, a frame or a pixel; the director's
  cost stays inside 5.8 (Potato Chromebook, 60 FPS).
- Heavy runs (presence suites) one at a time under `nice -n 10`: the machine has 4 CPUs shared with other jobs.
