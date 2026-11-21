# Monster v3, stage 1: report (third pass, final)

Worktree `/home/user/Rovloc/.claude/worktrees/mv3`, branch `mv3`. Second pass ended at `176f00a`
(`run9/STAGE1-REPORT.pass2.md`); the first part of the third pass (runs 6..9, the reveals planned ahead and the hop to a
vantage) is `33213d0` (`run10/STAGE1-REPORT.pass3a.md`); the last part (run 10) is `2f4af97` plus the final commit
(see PROGRESS.md). docs/MONSTER.md sections 29 and 30 describe every change. Website and shared config only.

## Verdict

- **Chases are back** on every difficulty: Standard Sprinter 2.2..2.8 a floor (second pass 1.3..1.7), Easy 1.7 / 2.2,
  Nightmare 3.1 / 4.0. The cause was not the tokens: a noise was shielded by *every* interaction of his on the maker
  (and 5 s after), which with an interaction every 15..30 s was most of the floor. Now only his quiet moments (a heard
  interaction or his sniff, and 5 s after) shield a noise; a seen one shields only until it has shown him to them.
- **Never harder than v2**: every downs figure under v2's on the same build and seeds, catches per chase start at or
  under v2's on all four sets, careful bot 0 downs on Standard, every down inside a token-paid encounter with a tell.
  But the Sprinter's downs (0.08..0.22) stay **under the 0.3 band**: see section 4, it is not reachable together with
  the other rules on the Hallways.
- **Co-op**: chases spread per floor (0 uneven floors of 72), an encounter's tail gives way to a starved teammate;
  nobody over 90 s in the pair (85 s); the four and the split pair reach 92 s / 91.2 s (target 90).
- **Seen**: pooled out of a hiding spot 25 % (band 25..40, the check reads 24.6 and fails by a hair); the Sprinter sees
  him with their own eyes in 26 % of what reaches them (Walker 30 %, both PASS >= 25 %), but the Sprinter's seen *tier*
  share fell to 22 % (third pass first part: 29 %): chases and investigations now cut some reveals short and take 7 %
  of the mix. The brief's first goal is only partly held.
- **The gate is still red**: 104 PASS / 20 FAIL (third pass first part 96 / 27; second pass 89 / 34).

## 1. Cadence (`presence-sim`, both suites, final tree; 12 seeds x Basement + Hallways, Standard solo)

| Profile | median gap | p90 | longest silence median / p95 | target median / p90 / silence p95 | clock ratio | saw him | seen tier (out of a spot) | 3rd pass part 1 median |
|---|---|---|---|---|---|---|---|---|
| Sprinter | 23.7 | 51.0 | 32.0 / **59.0** | 15..20 / 36 / 40 (brief: about 45) | 1.45 | **26 %** | 22 % | 21.2 |
| Walker | **29.0** | 55.8 | 35.0 / 63.0 | 26..34 / 62 / 68 | 1.04 | **30 %** | 38 % | 30.6 |
| Croucher | **51.0** | 74.5 | 67.9 / 101 | 50..70 / 110 / 140 | 0.88 | 9 % | 20 % | 48.6 |
| Creeper | **53.4** | 76.9 | 68.0 / 83 | 50..70 / 110 / 140 | 0.93 | 39 % | 24 % | 48.7 |
| Hider | **40.7** | 73.5 | 64.5 / 107 | 40..75 / 110 / 150 | (band only) | 1 % | 16 % | 40.3 |
| Sprint-hider | 28.4 | 70.0 | 30.9 / 41 | (none) | 0.82 | 10 % | 15 % | 29.9 |
| Mixed | 32.4 | 74.3 | 35.4 / 70 | (none) | 0.81 | 10 % | 16 % | 32.7 |
| Easy / Nightmare Walker | 30.1 / 29.7 | | | Standard's band | | | | 30.2 / 28.9 |

Share by tier, out of a hiding spot, every profile: heard 55 / seen 25 / close 13 % (chase starts 7 %).
Co-op (Mixed, together): pair median 33.3 (solo 32.4), longest **85 s**; four median 43.6, longest **92 s**; split pair
median 36.9, longest **91.2 s** (target: nobody over 90 s). Third pass part 1: 109 / 142 / 80.6.

## 2. Danger (`presence-sim`, danger suite; v2 baseline fbfd8e6f2d743b57 recaptured on this build, same seeds)

| | chases / floor | downs / floor v3 (v2) | catches per chase start v3 (v2) | careful objectives v3 (v2) |
|---|---|---|---|---|
| Basement Std solo Sprinter, tuning seeds (36) | **2.2** | 0.22 (0.83) | 0.09 (0.15) | 1.9 (1.4) |
| Basement Std solo Sprinter, untuned (36) | **2.8** | 0.22 (0.50) | 0.07 (0.09) | |
| Hallways Std solo Sprinter, tuning | **2.5** | 0.08 (0.36) | 0.03 (0.07) | 1.6 (2.7) FAIL |
| Hallways Std solo Sprinter, untuned | **2.8** | 0.11 (0.42) | 0.03 (0.07) | |
| Std pair Sprinter (Basement / Hallways) | 2.4 / 2.3 | 0.17 / 0.13 | | |
| Easy solo Sprinter | 1.7 / 2.2 | 0.00 / 0.08 | | |
| Nightmare solo Sprinter | **3.1 / 4.0** | 1.33 / 1.17 | | |
| careful bot, floors with a down (Std / NM) | | 0 % / 0 % ; 25 % / 8 % | | |

Every down inside a token-paid encounter (0 outside, 0 refused); hiding within 8 s of a warning escapes 12/12 on both
difficulties; never faster than 18.5; near misses (8.3's broad count) Sprinter 2.8, Walker 2.6 a floor, more than the
chases. Croucher and Creeper downs 0.13 (< 0.25).

## 3. What changed in this part (docs/MONSTER.md 30)

- `lurker._directedOn`: only a quiet moment (tier 0, C4, and DefenceWindow after one) shields a noise; a seen or close
  interaction only until its tell reached them.
- Co-op yield (`lurker.gate` / `_starving`): a hiding watch, a search or an investigation inside an encounter gives way
  (the breather: Patrol, withdrawing on foot) when another counting player has had nothing for `Coop.Starve`.
- `lurk.mayTarget`: nobody holds more than ceil(n / 2) of a floor's token-paid encounters (`team.encCount`), on top of
  the RepeatAfter wait.
- `_stage`: a staged hop keeps `Clock.Team` in co-op.
- Config (Luau + real export, the build's creatureConfig equals the tuned one): `Lurk.Chase.Refill` 150 / **35** / **25**
  (was 150 / 50 / 40), `Lurk.Clock.Gap.Crouch` **66** (60).
- Tried and dropped: Standard token cap 2 (Croucher downs 0.25), `Presence.Chase.CapSeconds` 11..12 (catch per start
  over v2's), FirstHeard 15, Coop.Starve 50, Escalate 480, C4 weight 5, S1/S3 fitted to crouchers, beat gaps measured
  from a chase's end (moved every profile's median).
- Sims only: `[stats]` maps noise / sight / spent / yields (LURK_STATS), `LURK_DEBUG_TWICE`, LURK_DEBUG warp print.

### Checks changed and why (no threshold moved)
- **Chase spread (co-op)**: was pooled over 12 floors, player 1 against 2, with an absolute +2; the spec's rule is per
  floor. Now: no floor where one player holds more than ceil(n / 2) of its token-paid encounters (0 of 72 uneven).
- **The floor's opening**: the first perceived interaction, or a stray of his *heard* before it (the director counts
  that as reaching them; a far-off stray sighting opens nothing). Before, strays were ignored, so a heard stray then a
  near miss read as "opened by a near miss".
- **Seen, in the report's reach and in the "no teleport in view" watch**: from the player's real eye (a crouch's lower
  one, as the camera and the service use). The standing eye had counted a warp the service rightly started out of a
  crouching player's view as "in view", and a hop nobody saw as an interaction start 3.3 s before the next.
- lurk-test rows follow the new numbers and the spread rule (91 rows); creature-sim's written-down numbers follow
  (Gap.Crouch 66, Refill 150 / 35 / 25).

## 4. What is not reached (20 checks) and why

- **Sprinter's downs 0.3..0.8** (0.08..0.22): with catches per chase start held at or under v2's (Hallways v2 0.067 /
  0.070) and chases capped at 4 a floor, the Hallways cannot reach 0.3 (4 x 0.07 = 0.28); the Basement could only by
  making each chase deadlier than v2's (CapSeconds 12 gave 0.38 downs at 0.15 per start). The three rules conflict; I
  kept the two that protect the player (not harder per chase, chases 2..4). The run-to-run spread of downs on 36 floors
  is about +-0.1 (the same config read 0.31, 0.14, 0.22 on the Basement).
- **Sprinter cadence**: median 23.7 (15..20), p90 51, silence p95 59 (40; brief 45), clock 1.45. A runner is out of his
  reach most of the floor (about 30 hops a floor, most landing out of everyone's hearing); chases and their searches now
  take time in which nothing else reaches them. Part 1 of this pass read 21.2 / 68.
- **Seen share**: pooled 25 % (24.6, fails); per profile Sprinter 22, Croucher 20, Creeper 24, Hider 16, Sprint-hider
  15, Mixed 16 (Walker 38). The hide-heavy profiles sit at high strain after their encounters (strain over SeenBelow
  blocks seen types).
- **Strain >= 0.8** Sprint-hider 22 %, Mixed 29 % (15 %): a hiding watch holds him at their spot (strain 1) up to its
  30 s reach-in; cutting the watch would take THRESHOLD's reach-in away.
- **Clock honesty** Sprint-hider 0.82, Mixed 0.81 (0.85..1.2): over-delivered by encounters and owed hides.
- **Escalation** x1.30 (1.5); **first interaction <= 25 s** (latest 58 s; two Creeper floors open with a near miss when
  the creeper walks into him at 13 s); **repeats** 11 (sim and service disagree on a few reaches, 99 % agree); **hides paid** 40 / 139 (46);
  **leash** 40 % (60: he lags runners and walkers); **co-op four / split** 92 / 91.2 s (90); **careful objectives,
  Hallways** 1.6 (v2 2.7: the careful bot is chased 3..4 times a floor, mostly re-chases from his search after its
  noise or its flight).

## 5. Commands and last lines (final tree)

- `node tools/lurk-test.mjs` -> `[lurk] all 91 rows pass`
- `run-heavy cpu node tools/creature-sim.mjs` -> `[sim] all passed`
- `run-heavy cpu node tools/data-test.mjs` -> `PASSED: 105852 checks`
- `run-heavy cpu nice -n 5 node tools/presence-sim.mjs --json run10/f-presence2.json` (both suites) -> 104 PASS,
  20 FAIL, `[presence] FAILED`
- Luau: `LUAU_LSP=... LUAU_DEFS=... API_DUMP=... TMPDIR=... run-heavy cpu bash tools/verify.sh` -> `ALL GATES GREEN`
- `run-heavy timing node tools/game-smoke.mjs` -> `all checks passed` (0 FAIL)
- `run-heavy timing node tools/objective-run.mjs --seeds 1029,2718,4242` -> `all checks passed`
- re-export: `cd web && run-heavy cpu bash -c "npm run export && npm run bake"`
- logs: `scratchpad/mv3/run10/f-*.log`, `run10/chain.log`; quick harness `run10/{q,dq,full}.sh`, `st.mjs`, `dz.mjs`
