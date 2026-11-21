# Monster v3 stage 1: adversarial code review

Worktree `/home/user/Rovloc/.claude/worktrees/mv3`, branch `mv3`, diff `d6e023a..e5c6e89` (27 files). I read the whole
diff, `STAGE1-REPORT.md` and `docs/MONSTER.md` section 14. I changed no source file. I ran two probes through the cpu
wrapper; their scripts and output are under `scratchpad/mv3/refute/code-*`.

## Verdict

One blocker: the director's sniff (C4), which is supposed to be "never lethal", kills a hider who gasps. A probe
reproduces it with no token held. There are eight major findings: two holes in the token economy, a co-op client that
hears his creeping steps at full volume, a floor change that settles the previous floor's interaction onto the new
one, the approach ignoring backstage and hiding, an owed hide thrown away before any plan is tried, a danger baseline
that compares two different bot models, and the report's own deviations living only in JavaScript constants. The
determinism core is sound. lurk.js reads no clock and no `Math.random`, every stream is keyed, the brain step is
3 x 30 Hz engine ticks, and `litAt` is baked. Per-tick cost is small. The probe measured at most 15 path queries per
director step, but the "40 per step" check counts the wrong thing.

---

## BLOCKER

### B1. The director's sniff (C4) kills through the gasp
- **Where:** `web/src/creature/lurker.js:604-607` (`gate` keeps a heard noise in `SEARCHES` with no token);
  `web/src/creature/states/search.js:131` (`exit` clears `ctx.directorSniff`); `web/src/creature/states/sniff.js:21,40`;
  `web/src/game/mechanics/lockers.js:690-698` (a Caught verdict plays the Gasp **noise**, priority High).
- **What happens:** C4 starts a Search. The hider fails the breath check, so the directed verdict is Caught and he only
  screeches. The locker module then emits a Gasp noise at the slits. Because the brain is in Search,
  `gate` leaves `summary.heard` alone even without a token. `decide` turns that into InvestigateNoise, and
  `search.exit` nulls `ctx.directorSniff`. InvestigateNoise inspects the same spot, this time not directed, gets
  Caught, and reaches in.
- **Evidence:** `refute/code-c4-gasp.txt` (seed 7, Basement, tokens forced to 0):
  `40.3 Patrol->Search tok=0.00`, `inspect#1 L0_Cabinet_23 directed=true`, `44.4 Search->InvestigateNoise tok=0.00`,
  `inspect#2 ... directed=false`, `caught: [{at: 48.9, kind: "Locker"}]`.
- **Why the sims miss it:** presence-sim's "every down inside a token-paid encounter" passes because the Hider bot never
  fails a breath check.
- **Fix:**
  - Put one choke point on catches: `_reachIn` and `_tryCatch` refuse unless
    `!this.lurker || t < lurker.state.team.encounterUntil`.
  - In `gate`, drop `!SEARCHES.has(st)` while `c.directorSniff` is set or within `Chase.DefenceWindow` of a director
    interaction's end.
  - Add a creature-sim case with an inspector that answers Caught and emits Gasp.

## MAJOR

### M1. A loud noise heard while a token is held: the investigation can catch but spends nothing
- **Where:** `lurker.js:621-637` (`onState` spends only on WallChase and HidingResponse); `states/sniff.js:40`.
- **Failure:** a token is held, so `gate` lets the noise through and he enters InvestigateNoise. His locker sniff can
  ReachIn a gasping hider, but no token is spent and `encounterUntil` stays `-Infinity`. The down falls outside any
  encounter, and the unspent token allows a chase as soon as `Chase.Rescue` ends. Spec 25.6 lists "a loud noise heard
  with a token" as a provocation.
- **Fix:** when InvestigateNoise is entered from Patrol on a player's noise, call `Lurk.spend` and
  `encounterUntil = Infinity`, and add an X record. B1's choke point then covers what is left.

### M2. Co-op clients hear his creeping steps at full volume and his H1b steps as a walk
- **Where:** `web/src/creature/view.js:720-722` reads `this.service.lurker.gait`.
- **Failure:** on a client, `beginRun` still builds a `Lurker`, but `service.tick` is replaced by `_puppetTick`, so its
  gait stays `'Heavy'` forever. The relayed `cst.g` lands in `CreatureNet._snapshot().gait`
  (`game/coop/creature.js:559`), and nothing reads it. The result:
  - Clients hear his creep steps at 1.0 instead of `Gait.CreepVolume` 0.25, so up to about 80 studs instead of 22.
  - H1b plays the walk voice.
  - The host's reach, stray and "silent lurker" accounting is wrong for every client.
- **Fix:**
  - In `_onFootstep`, use `const gait = this.service.snapshot().gait || 'Heavy'`: the host snapshot carries `gait`,
    and the client's patched snapshot carries `fx.gait`.
  - Read `CreepVolume` from a cached `lurkConfig`.
  - Do not construct a Lurker on a co-op client.

### M3. The short-chase refund pays out for free (chained) chases
- **Where:** `lurker.js:636-643`.
- **Failure:** a chase taken up again within an encounter (`chained`: `encounterUntil === Infinity` or within
  ChainSeconds) costs nothing. If it ends within `ShortSeconds` and never comes within `ShortNear`, it still refunds
  `ShortRefund` 0.5. Two short re-chases out of a Search (sighting at 30 studs, lost after LostSeconds 4) mint a whole
  token, so the bucket's rate no longer bounds chases.
- **Fix:** store `this.chase = { at, player, min, paid: !chained }` and refund only when `ch.paid`.

### M4. A floor change settles the old floor's interaction onto the new one
- **Where:** `lurker.js:173-176` calls `Lurk.activate(...)` and then `this._end('lost', t)`.
- **Failure:** the settle runs after the reset. Anyone who perceived the old interaction starts the new floor with:
  - `count` 1 and a second theta draw, with `lullIn` decremented;
  - `lastType` set to the old type (that type is barred first) and its `cooldownUntil` set;
  - `heardAt = t`, so `TellHolds` blocks C3 and the approach for 12 s;
  - `lastReachAt = t`;
  - strain plus the type's cost added on top of the `FloorStart` cut.
- **Fix:** call `this._end('lost', t)` before `Lurk.activate`, or settle with `reached: {}`. Also clear
  `this.readings`, `strayAt`, `straySeen`, `sniffDue` and `defenceUntil` in `activate`.

### M5. The approach teleport ignores backstage, hiding and duct players, and TeamBody
- **Where:** `lurker.js:786-789` and `_approachOk` at `820-836`.
- **Failure:** `who()` returns owed players who are backstage too, since their clock only runs at half rate.
  `_approachOk` checks no backstage state, no `cfg.Only[p.cls]` (Hiding allows C2/C4/H1/H2 only; Duct allows H3/H5/S4)
  and no `Clock.TeamBody`. The approach is planned before `feasible`, so all of those rules are skipped. Example: a
  still, backstage player 220+ walked away meets the closing test `(walk - 55) / 13 > 12` and gets a warned teleport.
  That defeats backstage, the hider's catalogue and the one-body-at-a-time rule.
- **Fix:** in `_approachOk`, return false when `p.backstage`, when `p.cls` is Hiding or Duct, or when
  `t - team.lastBodyStartAt < cfg.Clock.TeamBody`.

### M6. The owed hide is thrown away before any plan is tried
- **Where:** `lurker.js:779-784` sets `p.hideOwedAt = null` before the plans run.
- **Failure:** if C2, C4, H2 and H1 all fail their geometry on that step (common: C4 needs `speedOf('Search') x Setup`
  of walk), the hide is never paid and nothing retries it. This fits the report's failing check: "Hides that pay
  (Hider): 39 of 144 (target 48)".
- **Fix:** clear `hideOwedAt` only when `_start` succeeds for that player. On failure, keep it and set
  `retryUntil[type]` as usual. Optionally expire it after `HideOwedMax`.

### M7. The danger suite's "careful bot vs the v2 baseline" compares two different bots
- **Where:**
  - `web/tools/presence-sim.mjs:540-554`: `hearsIt` returns false when there is no lurker; the bots now hear only
    through `lurker.soundLog`.
  - The baseline `web/tools/baselines/presence-v2.json` was captured at `e820abb`, when the careful bot heard by
    straight distance (`HEAR_NEAR` 30).
  - The checks at `:1781` (careful floors with a down) and `:1783` (careful objectives within 15 % of baseline).
- **Failure:** "careful objectives 2.3 vs baseline 1.1" is mostly the change in the bot's hearing (report deviation
  11), not the monster. The report argues the two are comparable, but measures nothing to show it. Run against the v2
  creature, the current bot would never hear him (no lurker), so the baseline cannot be reproduced with the current
  sim.
- **Fix:**
  - Give `hearsIt` a v2 path: a sound log hooked on `env.play` positions for CreatureRattle and footfalls, which works
    without a lurker.
  - Re-capture `presence-v2.json` at `d6e023a` with the current bot code. Until then, mark these two checks as
    non-comparable rather than PASS.

### M8. The report's deviations live only in JavaScript constants the Roblox port would have to guess
- **Where (lurker.js):**
  - Constants at `:40-54`: `HEAVY_STRIDE` 14, `RUN_STEP` 0.5, `STRAY_AGAIN` 10, `BEAT_ENTER` 2, `MOVE_SLACK` 4,
    `HOLD_ARRIVE` 2, `TRAIL_STEP` 4, `TRAIL_MIN` 3, `SNIFF_FAR` 25, `H2_WALK` 45 (deviation 4), `REPLY_MIN` 6.
  - Inline numbers:
    - H1/F leg end bounds 30..70 and the H1b end at `StepHeavy` (`:1033-1034`, deviation 4);
    - the catch-up threshold `L.Max + 20` (`:1272`, deviation 6);
    - the set-piece hold `8` (`:774`);
    - the NearMiss/beat/approach `until` values of 30, 60 and 20;
    - `asked >= 10` and `>= 6`, `rank.slice(0, 6)`;
    - the Reply leg `* (StepPace / 9) * 0.5` (`:1188`);
    - "moving" as `rec.speed > 3` (`:1330`);
    - the `_lead` numbers `bestD > 8` and `1.5 *` (`:990-993`).
- **Where (states/nearmiss.js:12-16):** `FEINT_CLEAR` 6, `FEINT_SECONDS` 1.2, `OUT_SECONDS` 3, `OUT_MIN` 20,
  `OUT_MAX` 90.
- **Also:** the Reply's rate uses `Types.H1.Cooldown` (`:1182`) while `Types.Reply.Cooldown` is 0.
- **Fix:**
  - Move these into `CreatureConfig.Lurk`, for example `Reach.Stride`, `Reach.RunStep`, `Steps.EndMin/EndMax/RunEndMax`,
    `H2.WalkMax`, `Leash.CatchUpBehind`, `NearMiss.{FeintClear, FeintSeconds, OutSeconds, OutMin, OutMax}`,
    `Reply.Cooldown`, `Reply.LegMin`.
  - Add them to `LURK_SPEC` in creature-sim and to the data-test walk.

## MINOR

- **m1. Dead or misleading config.**
  - `Lurk.Reach.HeardSeconds` is unused: the reach rule is "2 footfalls" (`lurker.js:359-360, 413`).
  - `Clock.PlanAhead` is unused: `Lurk.owed(..., ahead)` is never called with `ahead`.
  - `Presence.Audio.NearRadius` has no reader any more.
  - `Lurk.Sniff.*`, `Coop.StarveMax` (sims only), and `Setup` for S1..C3 are unused.
  - `DifficultyConfig.teleportCooldown` (Luau and `web/src/creature/config.js:169,180`) is no longer read on the web,
    but the Roblox port would still pace teleports by it.
  - `lurk.BUILT` lists H4 and S3, which have no plan.
  - The `lurker.js:29-31` comment says C4 has no plan; it does (`_sniff`).
  - **Fix:** remove them or mark them `-- stage 2`. Delete `teleportCooldown` or document that v3 ignores it. Fix the
    comment.
- **m2. Dead code left from the presence layer.**
  - `states/patrol.js:365-395`, the hint branch, and its header lines 17-19: `ctx.hint` is never set now.
  - `service.js:483, 877`; `lurker.js:914`.
  - `service.js:123` `TELEPORT_RETRY`; `nextTeleportTry` (`:328, :2456`, written, never read); the unused `t`
    parameter of `_giveUp`.
  - `lurker.js:98` `stepMs`, `:1407` `lookedAt`, `:1425` `feetOf` (no callers).
  - `lurk.js:115-116` `setPieceAt` (never set, so the check at `lurker.js:774` is dead) and `seenHole`.
  - `lurker.js:54`: the REPLY_MIN line carries two orphan comments of deleted constants.
  - **Fix:** delete them.
- **m3. The give-up's teleport hold is gone.** The removed `service.js` `_giveUp` lines (old `d6e023a:1126-1127`,
  `teleportReadyAt = max(..., t + teleportCooldown[0] / 2)`) were not replaced. Now only the breather holds off C3
  after a chase gives up. On Nightmare the hold drops from 20 s to 15 s.
  - **Fix:** a config hold, for example `Lurk.Chase.GiveUpTeleportHold`, applied in `_giveUp`.
- **m4. `gate` can blame the wrong player.** At `lurker.js:580-587`, the Patrol rule recomputes `summary.sees` as
  "some sighting within Beats.Near and noticed", but `who` takes `c.sightings[0].player`. In co-op, the token,
  `mayTarget`, backstage and near-miss tests can then run on a farther player, not the one who provoked him. The chase
  target is chosen the same way.
  - **Fix:** use the sighting that satisfied the predicate and hand it on as the target.
- **m5. Stale readings.** The `_leash` close test (`lurker.js:1240`) and `onStun` (`:670`) read every entry in
  `this.readings` without checking counts or level. Entries for players off the level or in the respawn grace never
  refresh, and a downed player at walk ~0 keeps `close` true, so a hold point is re-planned every step.
  - **Fix:** filter by `this.state.players[id]?.counts` and clear `readings` on activate.
- **m6. A HidingResponse's X record uses the Screech's reach.** At `lurker.js:633`, players within 120 pay
  HeardShare and strain for a screech that never plays in a hiding watch, and the hidden target is recorded as
  `'both'` (seen).
  - **Fix:** use the reach only for WallChase; record the target as `'heard'` for HidingResponse.
- **m7. The starve rule is degenerate at floor start.** `activate` sets `lastReachAt = -Infinity`, so `who()`
  (`lurk.js:455-458`) sees every owed player as starved by Infinity. The tie goes to the first key, so userId 1 (the
  host) always gets the floor's first interaction. It also applies to late joiners.
  - **Fix:** `since = now - Math.max(p.lastReachAt, team.floorAt)`.
- **m8. The path-query budget counts only `lurker.walk`.** Uncounted: `_leash`'s `nav.computePath` (`:1267`),
  `_planApproach` (`service.js:1333`, up to `ApproachTries` 60), `_teleportSpot` (`service.js:1221`, one query per
  candidate, unbounded) and the beats' `hideWalk`. The check "at most 40 per step" measures only part of the cost.
  - **Measured:** counting every `computePath`, the probe saw at most 15 per step and 5.2 ms at most in node
    (`refute/code-queries.txt`). A school Chromebook is several times slower.
  - **Fix:** count in a nav wrapper, and add a retry hold when `_planApproach` fails.
- **m9. Tests that were loosened or cannot fail.**
  - `presence-sim.mjs:1647`: the Easy and Nightmare Walker are checked against `median[1] * 1.15`, yet the check is
    named "keeps Standard's band". Easy measured 34.5 against a band of 26..34.
  - `objective-run.mjs:430`: `|| met.nearMiss` passes a forced encounter that turned into a near miss, even though the
    harness had set the tokens to Cap. A near miss there means the setup failed.
  - `lurk-test` `backstageTiers`: `every` is vacuously true on an empty list.
  - The lull check (gap >= 1.6 x median on every Walker floor) passes from random spread alone.
  - **Fix:** remove the x1.15 or give it a reason; fail on a near miss in objective-run; assert the list is non-empty;
    check for a lull through the `lullIn` reset, carried on the interaction's end event.
- **m10. Allocations in the per-tick path.**
  - `monsterFx.js:204` deep-resolves `lurkConfig` on every 30 Hz tick while he hunts beyond 25 studs. That is 37 µs
    per call in node, 5x `presenceConfig` (`refute/code-lurkcfg.mjs`).
  - `hints.js:182` does the same.
  - `lurker.tick` builds a new `this.draw()` closure per player per tick (`:222, :232, :236`) and new group arrays.
  - **Fix:** cache `lurkConfig` per difficulty, as `index.js` does, and keep the draw closures in a Map.
- **m11. Co-op `cst` churn.** The gait flips between Creep and Heavy every time a sighting flickers
  (`lurker.js:510`), and each flip sends a reliable `cst`.
  - **Fix:** hold the gait for 0.5 s, or put it on the world packet.
- **m12. The Luau port needs a fixed type order.** `feasible` and `order` iterate `Object.keys(cfg.Types)`, which is
  the export's sorted key order. Luau dictionary iteration is unordered.
  - **Fix:** write "sorted type names" into `lurk.js`'s header and the Luau config comment.
- **m13. The near miss and the token spend can target a player in a cutscene.** `gate` never checks
  `this._counts(who)`, so `strainEvent` and `backstage` change while that player's clock is frozen.
  - **Fix:** require `_counts(who)` before a near miss or a spend.
- **m14. The director's geometry draws from the brain's shared stream.** `_planBeat`'s `roll`, `_teleportSpot` and
  `_planApproach` draw from `ctx.random`, which is seeded with the fixed `RANDOM_SEED`, not the run seed, and which
  every state also draws from. A state change shifts the director's picks; objective-run's seed 2718 already showed
  this.
  - **Fix:** pass a `Lurk|Beat` or `Lurk|Teleport` stream into these planners.
- **m15. Near-miss vanishes in view are not counted.** `states/nearmiss.js:93` dissolves him *because* he is visible
  (GiveUp). That is allowed as "last", but no sim counts how often it happens.
  - **Fix:** count `nearMissFx('vanish')` in presence-sim and report it beside the teleport warnings.

## Checked and found sound
- Determinism:
  - lurk.js is pure.
  - The streams are `seededRandom(seed, 'Lurk|<key>')`.
  - The brain step is a fixed 3 x 30 Hz engine tick (`service.tick` accumulates exact 1/30 steps).
  - No `Math.random`, `Date`, `performance` or `process` reads in lurk.js, lurker.js or nearmiss.js.
  - `litAt` reads baked probes.
  - The ties in `who()` are broken by `lastReachAt` and then userId.
- Settle and stream use are order-insensitive: they use per-player streams and aggregate the rest.
- None of the per-player records grows with time: `warns` is filtered, and the other maps are keyed by player or type.
- The speed caps hold: `paceOf` and `speedOf` cap every pace, and the sims measured at most 18.5.
- The reply, the lure, the stun ending the interaction, and a beat interrupted by a chase (`_end('chase')` before the
  X record) behave as described.
- I13: `_counts` freezes the clock and strain under the Cutscene lock or `scripted`; `direct` stops while scripted;
  lumps need `counts`.
