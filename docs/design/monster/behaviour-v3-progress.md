# MV3 stage 1 progress

Worktree: /home/user/Rovloc/.claude/worktrees/mv3 (branch mv3)

## Done
- (run 1) read brief, spec, MONSTER.md 14-20, service.js, brain.js, presence.js, presence-sim.mjs
- (run 2) baseline captured + committed: web/tools/baselines/presence-v2.json (presence-sim --report, 9m37s)
- (run 2) Luau Lurk table written (spec 2.2 verbatim) + exportMeta Lurk; presence.js Easy + lurkConfig;
  lurk.js (pure core) and lurker.js (runtime) written, NOT yet wired into service.js

## Next
- wire service.js (beginRun seed, step tick/direct, gate in _summarize, onState in _enterState, noise hooks,
  snapshot gait/alarm/lurk, interaction + cued signals), brain.js NearMiss rows, states/nearmiss.js, patrol lurk mode,
  beats.js planKind + _planBeat(kind, walk, lead), index.js/hints.js heartRadius, monsterFx rattle, coop ccue
- npm run data (cpu wrapper), data-test, creature-sim SPEC rows
- presence-sim profiles + cadence/danger suites; tune
- docs, game-smoke, objective-run, report

## Commands that worked
- baseline: cd web && run-heavy cpu nice -n 10 node tools/presence-sim.mjs --report --json tools/baselines/presence-v2.json

## Numbers (baseline v2, 36 seeds objective downs; 12 seeds rest)
- Standard solo objective downs: Basement 0.69, Hallways 0.44; 2+ downs 8 % / 6 %
- careful floors with a down: 0 % / 0 %; careful done (objectives in 8 min): Basement 1.08, Hallways 2.42
- objective done: Basement 6.92, Hallways 6.67; chases solo Std: 5.0 / 3.8 (36 seeds) ; presence gap median 15.4 / 19.6

## Run 2 status (commit 419a489)
- wired: lurk.js (pure), lurker.js (runtime), nearmiss state, C4 director sniff, patrol lurk mode, coop ccue/cst g al,
  heartRadius, monsterFx rattle; npm run data done (17.5 min!) -> build has Lurk
- presence-sim: profiles walker/croucher/hider/mixed (+ objective=Sprinter, careful), --suite cadence|danger|all|legacy;
  LURK_TRACE=1 / LURK_DEBUG=1 env for traces; bots now hear what a player hears (hearsIt)
- lurk-test 65 rows pass
- danger sample (4/12 seeds): Std solo Sprinter downs 0.58 (base .69) / 0.17 (base .44); careful done ok
- cadence sample: Sprinter ~39 s, Walker ~34, Croucher 49, Hider 53, Mixed 44 (targets 15-20/26-34/50-70/40-75)
## Next
- creature-sim run + fixes; tune cadence; docs; report; luau check; game-smoke; objective-run

## Run 2 later (commit cbc7a45 + uncommitted Luau renames)
- creature-sim 68/68 green (2m31s); data-test green; lurk-test 65 rows
- Luau Removal.spec forbids substrings "Generator" and "Nudge" in scripts: Lurk.Nudge -> Lurk.Door, GeneratorStart lump dropped
- re-export only: `cd web && run-heavy cpu bash -c "npm run export && npm run bake"` (3.4 min, textures unchanged)
- cadence: runners ~40 s gaps (target 15-20 / 26-34): he cannot keep within earshot of a 15-19 stud/s player; warn cap
  2/180s limits approaches. Croucher/Hider in band-ish. Danger ok (downs <= baseline).
## Next: verify2, full presence --suite all, game-smoke, objective-run, report

## Run 2 final (e5c6e89): creature-sim 68/68, lurk-test 65, data-test, Luau (all but stylua; stylua fixed), game-smoke,
objective-run green; presence danger all PASS, cadence 22 PASS / 15 FAIL (runners). Report written: STAGE1-REPORT.md

## Code review (adversarial, no source changed)
- refute-code.md written: B1 C4 sniff lethal via gasp (probe refute/code-c4-gasp.txt), M1-M8, m1-m15.
- probes: refute/code-c4-gasp.mjs, refute/code-queries.mjs (max 15 path queries/step, 5.2 ms node), refute/code-lurkcfg.mjs

## Run 3 (second pass: refute-fairness F1..F12 + refute-code B1, M1..M8, m1..m15) started
- first job: runner cadence; then findings. Base commit e5c6e89.
- (run 3) director changes in lurker.js/lurk.js/service.js (uncommitted until the Luau config lands): the hop (unheard
  approach landing 30..90 walked, >40 from every ear: side 'Hop'), PlanAhead staging, last resort (Clock.LastResort),
  catch-up at 16 when out of each listener's reach, steps reach by listener gait (StepHeavySprinting 50; planning uses
  sprint memory 8 s; H1b uses the current gait), steps legs bounded by hearing not walk, RetryMoving 2, no retry after a
  hop, Team/TeamBody restored after unperceived starts, Variety weights, families, F4 warnings at settle, F5 quiet
  moment, F6 tell (Lurk.told with TellLead), chain window only for the last target, B1 choke point (_encounterOpen),
  M1 InvestigateNoise spends, M3 paid refund, M4 unsettled floor end, M5/M6, m-fixes.
- config iteration: scratchpad/mv3/run3/lurk-patch.json merged into build/world.json by run3/patch-lurk.mjs
  (world.json.orig = the backed-up build). MUST be written into CreatureConfig.luau + real export before commit.
- presence-sim: async runFloor + breath-check inspector (BREATH_KINDS, 1 in 3 gasps), creeper + sprinthider bots,
  walker/creeper sprint only when chased, measures (beats merged 10 s, silence, clock ratio, class/mode time, families,
  afterHeard, cold chases/catches, refused catches, vanishes), --suite baseline, --profiles/--solo, danger untuned seeds.
- numbers so far (6 seeds x 2 floors, solo Standard, beat gaps): Sprinter 23.7..25.3 (owed 18.7), Walker 29.6..30.6,
  Croucher 53.1, Creeper 47.8, Hider 45.0, Mixed 44.4, Sprint-hider 41.4. Was: Sprinter 38.9, Walker 36.1.
- commands: quick cadence: cd web && run-heavy cpu node tools/presence-sim.mjs --suite cadence --profiles objective,walker --solo --seeds 6 --report
- (run 3) Luau config written + real export (3.4 min); commits 105cf8d, 5bfa235. lurk-test 80 rows pass.
- running: run3/chain.sh (creature-sim, data-test, v2 baseline on run3/v2ref [d6e023a web/src + today's presence-sim,
  v2 creatureConfig from lune run v2config.luau], cadence suite, danger suite); results in run3/*.log, run3/chain.log.
- next: Luau check (verify.sh), game-smoke + objective-run (timing, alone), report, final commit.

## Run 4 (resumed 22:03; chain finished 19:34)
- chain: creature-sim 73 PASS; data-test FAIL only on the old Presence.Audio check (fixed in the uncommitted data-test.mjs);
  baseline recaptured (v2ref, build d6019cf53933487d); cadence: Sprinter 24.3 (clock 1.30), Walker 29.3 PASS, silences
  p95 98/100; danger: downs <= v2 everywhere, but catches/chase-start > v2 (Basement .17/.15, .23/.09), chases/floor 1.7 (<2)
- uncommitted: lurker.js (Spotted needs FirstSeen; hop under warn cap), data-test.mjs, presence-sim.mjs, presence-v2.json
- run 4 tuning (scratch run4/patch.json over run3/world.json.exported, now written to Luau + real export 22:5x):
  _steps planned against the predicted ear (Steps.Predict 3), hop waits for an approaching runner, hop near end first,
  HopEvery 5, HopCapQuiet 20 (the uncommitted "no hop at the warn cap" line was the 40-s silence bug: removed),
  heard approach first for unreachable movers, Carry 1, TrailOwed 0, FamilyRun 2 + FamilyWait 8 (lastType only on
  perceived), firstHeardFired on perceived, C3 stalk needs a tell, hiding watch keeps mayTarget; sim silence counts
  strays + chase ends; family check = FamilyRun on perceived. lurk-test 88 rows.
- 3-seed samples (Sprinter/Walker median): base 26.9/-, final config ~24.8/28.5 (noise +-2)
- running run4/chain.sh: lurk-test, data-test, creature-sim, cadence, danger, verify.sh -> run4/*.log, run4/chain.log

## Run 5 (resumed 22:34; run 4's chain had stopped in danger: creature-sim FAIL (approach walk 210 = sim never recorded
## the plan's lead + a respawn's speed spike as lead), cadence Sprinter 24.6)
- fixed: service._lead / lurker._earAt clamp speed at GameConfig.SprintSpeed; creature-sim records plan.lead (dup key)
- director: _early (Clock.Early: runner in reach owed within PlanAhead -> H1/H1b now), _stage also during SamePlayer hold,
  no hop/approach/C3 while seen (_seenByAnyone) + presence-sim warpSeen check (1 before, 0 after)
- config: BackstageRate 1, LullScale 1.6, LullComp 1.1, FamilyWait 6, HopCapQuiet 40, Clock.Early true; lurk-rows updated
- commit 764aee3 (creature-sim all pass, lurk-test 88 pass)
- harness: run5/q.sh NAME [profiles] [seeds] (patch run5/patch.json over run5/world.json.base, quick cadence);
  run5/agg.mjs (stats), run5/sil.mjs (silences)
- quick 6-seed Sprinter/Walker: base 24.6/28.2 -> 20.9/29.2 (silence p95 Sprinter 72 -> 57)
- (run 5) commits 1cec11b (hop band at cap, robust build hash, v2 baseline recaptured fbfd8e6f2d743b57 via run3/v2ref
  with world.json = current + v2 creatureConfig/creature), 176f00a (sniffed hider's gasp, creature-sim late-gasp case
  FAIL before / PASS after; sim told = perceived until record end)
- danger (pre-final): downs Basement .17/.11, Hallways .11/.14 (v2 .83/.50, .36/.42): not harder, below the 0.3 band;
  chases 1.3-1.7 (v2 5.1-5.5); catches/chase start Basement .10/.06 (v2 .15/.09), Hallways .08/.06 (v2 .067/.070)
- final chain: run5/chain.sh -> run5/chain.log, run5/f-*.log
- (run 5) FINAL chain on 176f00a: lurk-test 88 pass; data-test PASSED 105852; cadence 67 PASS / 20 FAIL (Sprinter 21.4,
  Walker 28.6, Croucher 51.5, Hider 45.8); danger: downs all below v2, below the 0.3 band; Luau ALL GATES GREEN;
  game-smoke and objective-run all checks passed. STAGE1-REPORT.md rewritten. DONE (report to the lead).

## Run 6 = THIRD PASS (started; base 176f00a). Goals: seen share 25-40 % (runner sees him 1 in 3-4), chases 2-4 /
## floor Std (Easy 1-2, NM 3-7), Sprinter downs 0.3-0.6 but <= v2, careful <= 0.25, Sprinter silence p95 <= 45,
## co-op nobody > 90 s, presence-sim both suites exit 0 (fix behaviour or fix wrong checks + MONSTER.md), then report.
- logs in scratchpad/mv3/run6
- (run 6) seen more, code (uncommitted): beats.js Peek/Glimpse "soon" planners (reveal points in the player's sight over
  Beats.NearTaus, nearest him, within NearApproach), states/peek+glimpse Wait phase (Beat.ready: their eye within
  RevealRange, in their half angle, clear line; WaitSeconds), soon plans hurry at NearPace 13; S1/S2 planned against the
  lead for any mover; after a hop the seen types first; lurker._crossing (S1 as a walk through their sight, rarely fits);
  BreakOff while hidden in a beat by walked distance (service._nearestWalkUnder); hop quiet along the runner's way
  (segmentFlat); presence-sim 'saw' column (perceived interactions in which they SAW him). Stats: LURK_STATS ended/dur/afterHop.
- iteration patch run6/patch.json (Beats Wait/Reveal/Near*, S1/S2 Weight 12, FitOf Sprint+S2, Walk+S1, Crouch+S2)
- quick 6-seed: Sprinter saw 0.27-0.29 (tier-seen 0.18-0.22), Walker saw 0.27-0.29; gaps 20-21 / 29-30

## Run 7 (resumed 03:08 after a machine restart; run 6's last job g7 (danger) was cut off; tree = 176f00a + run 6's
## uncommitted code: beats soon-planners, Wait phase, _crossing, Tail, Escalate, owedHide/waived flags, sim checks)
- harness: run7/full.sh NAME SUITE [args] (patch run7/patch.json over run6/world.json.base, full suite), q.sh, dq.sh
- run6 numbers (patch-main: Refill Std 60, First 60, S1/S2 Weight 12, Escalate 360, Tail 4): danger 36 seeds
  Basement downs .31/.44 (v2 .83/.50), Hallways .14/.19 (v2 .36/.42); chases 2.4-2.8; catch/start Basement untuned .16 (v2 .09)
  cadence solo: Sprinter 21.7/p90 42.6, sil95 57.6, tier seen 20 %, saw .27

## Run 8 (resumed 03:26; run 7 had only run c0 = full cadence on run7/patch.json: 66 PASS / 20 FAIL (Sprinter 21.9,
## sil95 57, seen 15 %, cold chases 5, warn cap 3, strain80 hiders 25-30 %, co-op longest 115-160))
- harness copied to run8/ (patch.mjs reads run8/patch.json over run6/world.json.base)
- (run 8, uncommitted code) S3 the vantage built (lurker._vantage/_stepVantage, BUILT S3, the target's stare ends it:
  service._watchPlayers vantageOn), Clock.Early seen types first (EarlySeen, walkers seen only), strain rates off during
  the director's own interaction on that player (readings.directed), told past doubt (Reach.TellSteps 3 / TellSeen 0.6:
  lurk.settle rec.told, p.toldAt), floor opens heard (no near miss before anything reached them; Clock.FirstLate 3 last
  resort for the first), repeats check = the director's rule over everything aimed at them in settle order
  (presence-sim), head height hunched in _crossing/_vantage line tests
- patch run8/patch.json (adds Vantage.*, S3 Weight 12, FitOf Walk +S3, EarlySeen, FirstLate 3, Escalate 240, Reach.Tell*)
- c2 (full cadence): 68 PASS / 19 FAIL; seen 17 %, Sprinter 23.1, cold chases 0, repeats 21, Hider 38.7 (<40)

## Run 9 (resumed 04:05 after a machine restart; run 8's q8 was cut off; tree = 176f00a + uncommitted run 6-8 code)
- harness run9/ (copy of run8's: patch.mjs reads run9/patch.json over run6/world.json.base; q.sh, dq.sh, full.sh)
- NOTE: all run 6-8 config lives only in run9/patch.json (Vantage, Beats Near*, Escalate...): must go into
  CreatureConfig.luau (+ the Presence Luau for Beats/Chase.CapSeconds) and a real export before the commit
- d0 = full danger on run8's patch (baseline for this run)
- (run 9 code) the hop to a vantage: lurker._hopVantage (hop landing where their route from them, first leg their way,
  brings them into sight of him after Vantage.HopAfter s; service._planApproach opts.accept/tries), _vantageAfterHop
  (S3 standing at the landing once the warp ends, wait Vantage.HopWait); used in _interact before the heard approach
  and in _stage. patch: Vantage.Hop 1, HopAfter 3.8, HopTurn 60, HopBand [40,120], HopStep 3, HopTries 16, HopWait 6
- d0 (danger, run8 patch): downs Basement .31/.31 (v2 .83/.50), Hallways .17/.22 (v2 .36/.42) FAIL <.3; chases 2.3-3.0;
  catch/start Basement untuned .12 (v2 .09) FAIL; Hallways careful done 1.7 (v2 2.7) FAIL; co-op Mixed/careful chase
  spread 31/40, 36/45 FAIL (abs +2 tolerance over 12 floors); rest PASS
- hop vantage bug fixed (Map keyed by Vector3 object -> key by coords); aClose by walked rest, Vantage.HopNear 22;
  lurk.settle: a type's Cooldown only when it reached its target (else Clock.Retry)
- quick 6 seeds Sprinter/Walker: q7 base 21.5/30.2 saw .23/.24 sil95 61.6 -> h10 (HopBand [70,160], HopTries 60,
  S3 Cooldown 40, HopEvery 3.5, HopLands 3, HopWait 4) 23.0/30.5 saw .29/.31 sil95 40 -> h11 (+Clock.SamePlayer 8)
  20.6/30.6 saw .29/.32 tier seen 29/43 sil95 47. Gap.Sprint 10 no help (h12). patch-h11.json = current.
- c1 = full cadence on h11
- c1 (full cadence, h11 config): 70 PASS / 19 FAIL (seen share PASS, saw Sprinter .29 Walker .32 PASS); new fails:
  warpSeen 1 (fix: _seenByAnyone over every playing player), co-op team start 3.3 s (fix: an interaction half
  perceived, a footfall or a moment's sight, keeps the Team timers); repeats 57 = the last resort's steps repeating the
  last type (fix: never lastType in the fallback); co-op silences = a hiding watch on one player (65 s) starves the rest
- h14: Lurk.Only.Hiding = C2, C4, H2 (no far steps to a hider): hides paid 51/134 (was 36/138), Mixed clock .89
- c2 = full cadence on patch-h14 + those fixes
- c2 (full cadence, Only.Hiding C2/C4/H2 + fixes): 69 PASS / 20 FAIL; hides paid PASS, repeats 5, warpSeen 0, pair
  team gap PASS; but Croucher downs .50 (c1 .00), Sprinter sil95 68 (c1 47): noise on 12 floors is large.
  kold/knew (croucher,creeper,hider x6): croucher downs 3 vs 6 of 12 -> Only.Hiding change DROPPED (safety first).
- Luau config ported (CreatureConfig.luau: Presence.Beats Near*/Wait/Reveal/Cross*, Chase.CapSeconds Std 10, Types
  S1/S2/S3 Weight 12, S3 Cooldown 40, FitOf, Escalate 240, Leash.HopEvery 3.5, Chase.Refill 150/50/40, First 60,
  Reach Tail/TellSteps/TellSeen, Clock Gap.Sprint 12, SamePlayer 8, EarlySeen, FirstLate 3, LastResort 28/50/50,
  TrailOwed 0.8, Vantage full incl. Hop*). FINAL config = run9/patch.json (= patch-h11). Next: real export, diff.
- real export done (creatureConfig == run6 base + run9/patch.json exactly); lurk-test rows updated to the new config
  (+ told fn sets toldAt/prevToldAt, + 2 cooldown rows): 90 rows pass
- MONSTER.md 29 written (third pass + every check changed and why)
- final chain running: run9/chain.sh -> run9/chain.log, run9/f-*.log (lurk, creature-sim, data-test, presence all, verify)
- then: game-smoke, objective-run (timing, alone), report, commit

## Run 10 (resumed 08:03 after a restart; run 9 had: final chain (lurk 90, creature-sim/data-test pass after the doc
## fix: f-creature2/f-data2, presence 96 PASS / 27 FAIL, Luau ALL GREEN), e1/e2 quick danger (Refill 40/30, defence 3 s:
## no help), report rewritten as third pass, game-smoke cut off by the restart (browser closed))
- committed run 6-9 work as 33213d0 (milestone, gate still red)
- remaining: chases 2-4 / downs .3-.6, silences, co-op 90 s, the 27 failing checks (list in run9/f-presence.log)
- run10 harness: run10/{q,dq,full}.sh over run10/world.json.base (= real export at 33213d0) + run10/patch.json;
  run10/st.mjs LOG key (sums [stats] maps: noise, sight, spent, owedBy, ended...), run10/dz.mjs JSON (chases/raw/catch per start/downs)
- found: noise provocations were blocked by ANY director interaction on the maker (+defence); token often idle (2.75 spends/fl)
- code (uncommitted): _directedOn = quiet (tier 0 / C4) interactions only, a seen one only until it told them; co-op
  yield (gate: running encounter tail HidingResponse/Search/InvestigateNoise -> canHunt false when another counting
  player starved Coop.Starve); co-op staged hop keeps Clock.Team; stats noise/sight/spent/yields; presence-sim opener =
  first perceived incl. a heard stray
- tried+reverted: beat gaps as chase spans (moved every profile's median down)
- configs: Cap Std 2 (+chases, crouchers' downs .25 FAIL); CapSeconds 12 (catch/start above v2); Refill 35/30 Cap 1 (c3:
  Sprinter 2.6 chases .38 downs w/ CapSeconds 12); Gap.Crouch 66 puts Croucher/Creeper in band; Escalate 480 no help
- d1 = danger on Refill 35/30, Cap 1, CapSeconds 10, Gap.Crouch 66, Escalate 480
- a1/a2 (full both suites, candidates): 104 PASS / 20 FAIL each (was 96 / 27); results swing a lot run to run
- FINAL config = committed 33213d0 + Refill 150/35/25 + Gap.Crouch 66 (Luau + real export; build creatureConfig == that exactly)
- commit 2f4af97 (milestone); final chain run10/chain.sh -> run10/chain.log, run10/f-*.log; then game-smoke, objective-run, report
- chain on 2f4af97: lurk 91 pass, creature-sim all passed, data-test PASSED 105852, presence 102 PASS / 21 FAIL
  (f-presence.log), Luau ALL GATES GREEN
- found: the report's sight used a standing eye (crouching bot) -> a warp "in view" and a co-op 3.3 s start that the
  service rightly saw as unseen; fixed (report reach + warp watch use svc._playerEye); MONSTER.md 30 notes it
- running: f-presence2 (both suites on the eye fix); then game-smoke, objective-run (timing), report, commit
- FINAL (run 10): presence f-presence2 104 PASS / 20 FAIL; game-smoke all checks passed; objective-run all checks
  passed; STAGE1-REPORT.md rewritten (old one in run10/STAGE1-REPORT.pass3a.md); final commit below. DONE (report to lead).
a3ea8eb Monster v3 third pass: the report's sight from the player's real eye (a crouch's lower one) in its reach and its teleport-in-view watch; MONSTER.md 30 notes it

## Run 11 = FOURTH PASS (started; base a3ea8eb). Lead's rulings R1..R6 (apply in presence-sim + MONSTER.md 31 "Stage 1
## acceptance, as ruled"), real fixes F1 first interaction <= 25 s heard, F2 careful bot not re-chased out of a search
## (objectives >= v2 both floors), F3 seen pooled >= 25 (Sprinter too), F4 co-op <= 90 s, F5 sim reads the service's
## record (repeats, hides paid). Then both suites exit 0, tests, report, commit.
- harness run11/{q,dq,full}.sh over run11/world.json.base (= the real export at a3ea8eb) + run11/patch.json ({} now)
- (run 11, 13:10) uncommitted at resume: _opening (lurker: floor opening = steps at once / heard approach / hop, opening
  retry RetryMoving, openedAt in lurk.js; near miss waits for openedAt), LURK_DEBUG_FIRST print in presence-sim
- (run 11) presence-sim rulings applied: R1 downs <= v2; R2 STAGE1 table (Sprinter median <=25, p90 55, sil95 60,
  clock <=1.5) + later(2,...) for 15..20; R3 strain80 outside a hiding watch on them (strainAlive); R4 leash only when
  focus not Sprinting; R5 escalation 1.3 gating, later(3, 1.5); R6 clock 0.8..1.2 Sprint-hider/Mixed; final line has
  "(N PASS, M FAIL)" (gating only). F5: repeats read rec.prevType/prevTypes (lurk state snapshot at start) over
  service reached; hides paid = C2/C4 with service reached[k] overlapping the hide window.
- (run 11) F2 code (lurker): this.slipped (hid unseen inside running encounter) -> chainOk false, sightings/watch/noise
  of a slipped player gated as outside (token + _toldNow = tell after the slip), onState chained=false for them, cleared
  on spend/activate. F1 code: _openEarly (steps need 3/2 from FirstHeard-PlanAhead, on foot), _opening reordered
  (steps need 3, heard approach, steps 2/1, last-resort steps, approach in hop band, hop). MONSTER.md 31 rulings written.
- harness: run11/snap.sh NAME [args] = snapshot src+tools, run presence-sim via wrapper (no edit leaks). a2 = both
  suites with F1+F2+rulings (LURK_DEBUG_FIRST=1) -> run11/a2.log
- (run 11) a2 (F1 early+reorder, F2 slip-on-hide, rulings): 110 PASS / 14 FAIL. Sprinter 20.4 / p90 53 / sil95 58 PASS,
  seen pooled PASS, danger all PASS but careful Hallways 1.7. New fails: Croucher 48.8 / Hider 39.6 below band, clocks
  Croucher .80 Sprint-hider .74 Mixed .76, Sprinter warnings 3/180, Sprint-hider strain 19 %, Croucher+Creeper downs .33,
  first 83 s (hider: opening had no fit -> now falls through), 1 repeat, hides paid 40/141, leash 42 %, co-op four 118 s.
- t1 trace: careful re-chases = HidingResponse loop (out during LookAway, seen at its end, hides again in sight) + Search.
  Fix: slip also when out of the watched spot during a LookAway (this.watching, s.lookAway) and on HidingResponse->Search;
  gate treats a slipped watch as not hunting. t2 (careful, 12 seeds): done Basement 1.9, Hallways 2.3 (v2 1.4 / 2.7), no
  Search re-chases left, near misses up. Co-op: last resort capped at Coop.Starve when >1 counting (F4).
- a3 = both suites with all of the above -> run11/a3.log
- a3 (slip on look-away, opening fall-through, co-op last resort): 110 PASS / 14 FAIL; danger ALL PASS (careful Hallways
  2.3 vs v2 2.7, Basement 1.9 vs 1.4). Cadence fails: Hider 39.8, Croucher clock .80, Mixed .79, Sprinter warn 3 (sim
  reach), strain80 Sprint-hider 20 / Mixed 19, croucher+creeper downs .25, first 83 (hider), 1 repeat (hop after
  approach), hides paid 46/143, leash 41, co-op pair 93 / four 118 / split 92.
- found (t3 LURK_DEBUG_STEPS): a move's first footfall played in the lurk's Creep gait though its plan counted it heavy:
  fixed (_start sets this.gait = plan.gait). Also: hop lands HopCapQuiet farther when lastType is an approach (repeat);
  warnings check reads the service's record (r.reached, settle time) like F5, sim reach printed beside.
- a4 = both suites + patch.json {C2 Cooldown 60, Strain Decay .03 DecayDelay 3, Leash TrailPace 13} (patch only, not in
  Luau yet!), LURK_DEBUG_SIL=85 prints co-op silence windows.
- a4 (patch C2 60 / Decay .03 Delay 3 / TrailPace 13 + gait fix, warn record, hop quiet after approach): 112 / 12.
  Fixed: repeats 0, hides paid, strain80, warnings. But croucher downs .42, Mixed .42, careful Basement a down, Easy
  Hallways downs .42 > Std, escalation 1.10 (fail), careful Hallways 2.3 fail, leash 44, co-op four 119 / split 107.
  -> reverted Decay/Delay/TrailPace. New code: tell flag (gate's Trail not clock-chosen in the sim), opening approach
  hearWithin x Reach.OpenMargin + steps right after, starved co-op player takes the focus (_focus), Strain.PeakDecay
  (decay x2.5 at >= BackOff), Leash.RankHim (hold points ranked near him too).
- a5 = both suites, patch {C2 Cooldown 60, Strain.PeakDecay 2.5, Leash.RankHim 0.5, Reach.OpenMargin 0.6}
- a5 (patch C2 60, PeakDecay 2.5, RankHim .5, OpenMargin .6): 113 / 11. careful Hallways 2.2 (v2 2.7). careful bot
  hides ~20x a floor, perceives ~13: FOUND the hop's warning was aimed at its target (torch stutter + TorchStutter
  sound in the real game, index.js warnLocal) though the hop is meant unheard; the careful bot hid on each. Fixed in
  service (_warp Warning: target null for side 'Hop'). Also: opening steps planned with reach x OpenMargin (need 3),
  approach tag in records (LURK_DEBUG_WARN).
- a6 = both suites with that (same patch)
- a6 (hop warning untargeted): 114 / 10. careful Hallways 3.4 (v2 2.7), Basement 2.1 (1.4): F2 MET. Co-op pair/split
  pass, four 96. But danger Basement untuned Sprinter downs .53 (v2 .50), catch/start .19 (v2 .09); Croucher median 45 /
  clock .79 / strays 1.33, Hider 37.5, first 37, leash 44.
- then: RankHim reverted (code + patch), opening legs nearly straight (no 'bent'), silent hop lands off the runner's
  route (accept: Leash.OffRoute over OffRouteSeconds). a7 = both suites, patch {C2 60, PeakDecay 2.5, OpenMargin .6}
- a7 (hop off-route, RankHim reverted): 117 / 7: Hider 40.0 (edge), first 37, 1 repeat, leash 43, four 104, Basement
  untuned catch/start .13 (v2 .09), Easy Hallways downs .17 > Std .06. careful 3.4 / 2.1 PASS.
- t4 trace (walker Hallways 3960): he is Dormant until FloorGrace 20 (the early opening only helps after an early
  release); at 20 he was 285 walked off; opening approach (24 margin) and the off-route hop found nothing -> fallbacks:
  hop beside the way first else anywhere; opening approach at margin, then steps 2/1, then approach at the full hiss.
  _focus: starved player taken even when backstage.
- Luau now holds: C2 Cooldown 60, Strain.PeakDecay 2.5, Reach.OpenMargin 0.6, Gap.Hiding 80, Gap.Crouch 70 (NOT yet
  exported: real export after the runs). a8 = both suites, patch = the same numbers.
- a8 (Gap.Crouch 70, Gap.Hiding 80, hop fallbacks): 113 / 11 (noise: Hider 39.2, Sprinter clock 1.51, Croucher clock
  .84, cold chase 1, repeat 1 (hop heard after approach), leash 43, four 103, first 32.4, Basement untuned catch/start
  .14, pair Basement chases 1.8, Easy Hallways downs .17).
- then: no hop while lastType is an approach (_hopOk 'again', _hopVantage), opening drops the one-footfall guess
  before the approach (t5 trace: H11 at 101/98/94 from ear), comments fixed; creature-sim: hop warning aimed at nobody
  (15b) + case 11a1 slip; LURK_SPEC Gap.Crouch 70 / Hiding 80 + OpenMargin, PeakDecay, C2 Cooldown; lurk-rows Gap rows +
  4 new rows (95 pass).
- real export running (16:0x) -> then final both suites f1 on the real build.

## Run 12 (resumed 18:09 after a restart; run 11's real export was cut off in the bake at 16:33; tree = a3ea8eb + run 11
## uncommitted code). Re-running the real export -> run11/export.log; then f1 = both suites on the real build.
- (run 12) export done (rc 0; creatureConfig == base + patch exactly); run11/world.json.base = this export, patch.json {}; f1 = both suites on it (run11/f1.log)
- f1 (real export of run 11 config, current code): 111 PASS / 13 FAIL: Sprinter median 25.0/p90 55.3 + clock 1.54 + warn 3,
  Croucher clock .84, Sprint-hider cold chase 1, first 32.4 (Hallways openings at 20.1 miss), leash 43, four 157,
  Basement untuned downs .56 (v2 .50) + catch/start .21, Nightmare Basement chases 2.8, Hallways catch/start .09 (.07),
  Easy Hallways downs .25
- (run 12 code) the silent opening hop in the grace (_openEarly: steps [3,2] else _hopOk(..., opening) -> _hop, steps at
  once; service._approachAllowed(t, inGrace)); leash keep-up (quiet moves at focus speed + Leash.KeepUp, Creep gait,
  TrailPace..CatchUpPace; 'Run' gait only when behind). Luau has Leash.KeepUp 2 (not exported yet).
- e1 = both suites, patch {KeepUp 2, Coop.Starve 45, Presence.Chase.CapSeconds Easy 6 / Std 8} (run11/e1.log)
- e1: 118 PASS / 6 FAIL (first 32.4, leash 43, four 122, split 107, Hallways untuned downs .44 (v2 .42) + catch/start .13)
- found: the sim (and the game's spawns.js) holds him at his spawn SpawnTuning.Grace 20 s: the early opening never ran.
  New ObjectiveConfig.Spawn.Hold / SpawnTuning.Hold {Easy 19, Standard 14, Nightmare 12} (= FirstHeard - PlanAhead;
  Grace stays the roof door's); spawns.js + presence-sim use Hold. (Easy had NO hold in the sim before: NaN.)
  q1 (solo cadence): firsts mostly 15..20 s, 2 floors late (Hallways croucher 2006 32.4, mixed 4937 28.7).
- a missed opening on a lone player keeps no Team timer (lurker._end: lone)
- co-op: who() locked on one unreachable player 55 s (trace t9: who1 each second, all others owed): _interact now
  passes a player whose turn found nothing over for Clock.Retry (whoSkip -> info.skip in lurk.who); starved co-op
  player (Coop.Starve) gets _opening's order ('starved'); Coop.Starve back to 60 (45 did not help)
- patch now {KeepUp 2, CapSeconds Easy 6 / Std 8}; q3 = mixed co-op cadence quick
- e2 (hold 14, lone opening, starved order, whoSkip; leash-follow NOT in it): 115 / 9: Croucher 43.7 / Hider 37.4 /
  Croucher clock .81 (cadence shifted by the hold), first 32.4, leash 41, four 126, split 122, Hallways untuned downs .44
  (v2 .42) + catch/start .13. Basement now fine (catches 4/98, 9/111: the early-floor catches at 45..53 s are gone).
- found: the sim missed a sound logged in the tick its interaction ended (the approach's hiss as the warp forms): the
  service counted the hiss, the sim did not -> drainSounds() before a record closes (F5 class). Also leash: a walking
  focus is followed from behind (toward = band middle behind them), a running one waited for ahead as before.
- e3 = both suites, patch + Presence.Chase.Windup Standard 2.0 (was 1.5)
- e3 (+leash follow, drain fix, whoSkip, Windup Std 2.0): 113 / 11. Danger: ALL pass except careful Hallways 2.3 (v2 2.7)
  -> Windup 2.0 + Cap 8/6 KEEP (Hallways downs/catch now pass). Leash follow made leash 35 % and Sprinter sil95 94.8:
  REVERTED. Co-op split 204 s: the starved player's approach blocked by the other's ApproachCooldown (25 s, global) ->
  _starved/_starvedOther: nobody else's approach or hop while one starves; theirs waits for no cooldown.
- FirstHeard Std/NM 20 -> 18, Hold Std 14 -> 12 (Luau + JS); Luau now: CapSeconds tri(6,8,45), Windup pair(2,0.7),
  FirstHeard tri(25,18,18), Leash.KeepUp 2, Spawn.Hold; creature-sim pins updated; lurk-test 97 rows (who skip rows).
- t11 = leash diagnosis snapshot (where he is when above the band)

## Run 13 (resumed 23:08; run 12 had e4 = 118 PASS / 6 FAIL: Hider 38.0, Sprinter warn 3, Sprint-hider strain 17,
## leash 41, co-op four 111, split 160). Committed the run 11-12 work as 7909446 (milestone; Luau has KeepUp/FirstHeard/
## CapSeconds/Windup/Hold but the build is base+patch.json, real export still to do).
- found (h1/h2 traces): a hider who sprinted into a spot was a "runner" for SprintMemory -> LastResort.Sprint 28 s while
  hidden -> gaps ~35. Fix: _lastResort runner only when their class is Sprint/Walk/Still.
- found (w2 trace): Sprinter's 3rd warning = a hop SEEN forming (0.4 s) at the warn cap. Fix: _planApproach
  opts.unseenWay (no clear line from their eye's way, mid + end), used by _hop and _hopVantage when full.
