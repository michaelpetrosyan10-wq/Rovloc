# The Tall Man: the Creature's behaviour

The complete behaviour of the monster ("the Creature" in game text) as the website implements it, precise enough to
reproduce on Roblox without reading the JavaScript. Studs and seconds throughout. Every number is **Standard**; the
**Nightmare** value follows in brackets where it differs.

Where the code lives (web): `web/src/creature/` (`service.js` is the brain, `brain.js` the transition table, `states/*`
the states, `perception.js`, `hearing.js`, `pacing.js`, `locomotion.js`, `nav.js`, `config.js`), and the game's side in
`web/src/game/` (`mechanics/lockers.js` and `mechanics/hidespots.js` for the hiding spots, `mechanics/monsterFx.js` for the
warnings and the music, `coop/creature.js` for co-op, `objectives/spawns.js` for the start rule). The fairness rules are
asserted by `web/tools/creature-sim.mjs`.

---

## 1. Ground rules

1. **One clock.** Everything runs on the fixed **30 Hz** game tick. The brain thinks at **10 Hz** (every third tick;
   the brain's `dt` is the time since its last step, normally 0.1). Movement, warps and the catch advance every tick.
   Every timer reads the game clock (Roblox: `workspace:GetServerTimeNow()` on the server; the web: `loop.time`).
2. **Graphics never change gameplay.** No input to the brain depends on the quality tier, the render frame, the frame
   rate, the flicker state or any rendered pixel.
   - Light is the **baked** probe grid's base irradiance only (no scripted-group grids, no flicker factors).
   - Sight is raycasts against the collision geometry; the flicker warnings, the music and every sound are outputs.
   - The creature-sim asserts that 20 fps and 144 fps render loops give identical decisions and positions, tick for tick.
3. **Seeded randomness only.** Every random choice uses a seeded stream (`mulberry32`, seeded `(seed >>> 0) XOR
   FNV-1a-32(key)`). The brain's own stream is seeded `20251029` per run; the fake-outs use the run seed (section 9).
4. **Server authority.** The brain runs on one machine (the Roblox server; the web co-op host) and sees, hears, chases,
   teleports to and catches every player in play.
5. **No map extents.** Nothing assumes the footprint's size: every search is relative to the players or the Creature.

---

## 2. Body and metrics

| Metric | Value |
|---|---|
| Height standing / hunched | 11 / 9 (`meta.creature.height` / `hunchedHeight` when the rig exports them) |
| Root centre above the floor | 4.7 (HipHeight 3.4 + half the 2.6 root) |
| Eye above the root | Biped 3.1, Hunched 1.6, Swim 0.4, Stunned 2.4 (from `meta.creature.eyeHeight` when exported: Biped = eyeHeight − 4.7; Hunched = eyeHeight × 9/11 − 4.7), nudged 0.6 forward along the facing |
| Catch reach | 4 horizontal, 5 vertical (`meta.creature.reach` when exported) |
| Path agent | radius 2, no jumping, no climbing |
| Hunch | poseMode `Hunched` wherever the clearance (a portal's `clearance` within 3 studs of its opening, else the room's height) is under **12.5**, and while sniffing at a hiding spot |

**Speed cap.** Outside Scripted nothing ever moves faster than **18.5** (a sprinting player runs 19).
Every state's pace is `min(18.5, base × difficulty multiplier (1 [1.2]) × level speed scale (0.5..2))`.

| State | Base pace |
|---|---|
| Patrol (the Stalk) | 7 |
| InvestigateNoise | 9 |
| WallChase (the Chase) | 16.5 → 16.5 [18.5 capped] |
| Search | 8 |
| HidingResponse (approach) | min(chase, 9) |
| Teleport (the stalk after it) | 7 |
| Stunned | 3 |
| AquaticStalk / lunge | 6.5 / min(18.5, 18 × mult) |
| Scripted | whatever the script asks (16 by default) |

Player paces for reference: walk 11, sprint 19, crouch 5.5. Stamina 100 drains **7/s** sprinting (a full sprint
lasts about 14 s) and regenerates 14/s after 1.2 s.

---

## 3. Senses

### 3.1 Hearing

Every noise is a pulse `{position, kind, radius, priority, medium, level, ventNode, time, source}`. Radii (Standard):

| Kind | Radius | Priority | Medium |
|---|---|---|---|
| CrouchWalk | 5 | Low | Air |
| HideEnter (getting into a hiding spot) | 8 | Low | Air |
| SlowVentCrawl | 8 | Low | Vent |
| GrateUnscrew | 10 | Low | Air |
| Treading | 12 | Low | Water |
| HideEnterHurried (sprinting within the last 1 s) | 14 | Normal | Air |
| Walk | 22 | Normal | Air |
| FallingObject | 24 | Low | Air |
| ChatMessage (co-op text chat, if one exists) | 25 | Normal | Air |
| JumpLand (any landing after ≥ 0.32 s airborne, on foot) | 26 | Normal | Air |
| ObjectiveWork (a working hold, once a second) | 34 | Normal | Air |
| Gasp | 40 | High | Air |
| FlaskShatter | 50 | High | Air |
| Sprint | 60 | High | Air |
| Freestyle, Splash | 75 | High | Water |
| DoorSlam | 90 | Critical | Air |
| VentScurry | 90 | High | Vent |
| ObjectiveClunk | 110 | High | Air |
| GrateKick, FloorDebris, TrapSnap | 130 | Critical | Air |
| GeneratorStart | 170 | Critical | Air |

Locomotion pulses are sampled at 10 Hz: the louder of the MoveState's kind and the speed tier (≥ 15 Sprint, ≥ 7.5 Walk,
≥ 1 CrouchWalk), each kind no more often than its interval (Walk 0.45, Sprint 0.3, CrouchWalk 0.6 s).

A pulse is heard only on the Creature's level, with radius > 0.
- **Reach:** `radius × 1 × difficulty (1 [1.25]) × pacing scale (BuildUp 1, Peak 1.15, Relax 0.8)`.
- **Air:** straight distance; each wall between (count at most 3; two hits within 1.5 studs are one wall) multiplies the
  reach by 0.6.
- **Water:** straight distance, no walls.
- **Vent pulse heard from outside:** the Air route, or the leak out of an open grate (duct distance × 1.4 + the distance
  from the grate's mouth, with the walls between the mouth and the Creature), whichever is stronger.
- **Strength:** `1 − distance / reach`; heard when ≥ 0.
- **Where it believes the noise was:** High and Critical exactly; Low and Normal blurred horizontally by up to 15 % of
  the distance, seeded by the pulse's time.
- **Per tick:** the loudest heard noise (rank Low 1 < Normal 2 < High 3 < Critical 4, then strength) becomes `heard`.
- **Every heard noise:**
  - marks its room heard (the room id, the time, the rank, the position) for 60 s;
  - updates the memory of its source when that is the current target;
  - marks its source "loud" (High or Critical);
  - marks a swimmer (a Water noise of a swimming player).
- Scripted alerts (`alert(position, priority)`) are heard the next tick with strength 1, no falloff and no walls.

### 3.2 Sight

Evaluated every brain tick unless it is **blind**: hidden, fading (any warp), or startled by a pull-out (1.2 s).
- **Candidates:** every hunted player (Alive or Downed with a body, not ignored).
- **Never seen:**
  - MoveState Hiding;
  - in a duct or a crawlway;
  - Underwater, unless the Creature swims (PoseMode Swim or AquaticStalk).
- **Range:** torch on **70**; torch off in a lit pool **38**; torch off in the dark **20**.
  - Crouching or crawling downed: × 0.75.
  - Times the difficulty (1 [1.15]).
  - **Lit** means the baked probe irradiance at the player's root + 1 has luminance (0.2126 R + 0.7152 G + 0.0722 B)
    above **0.2**.
- **Cone:** half-angle **55°**, or **75°** when the player moves (their speed above 2 studs/s, measured from their root
  between brain ticks: `speed += (v − speed) × clamp01(dt × 6)`, a jump over 12 studs counts as 0).
  - Anything within the peripheral range is felt whatever the facing: 6, or 10 when moving.
  - During a LookAway the facing is the look-away direction and there is no peripheral sense.
- **Line:** a clear ray from its eye to the player's eye (root + 1.5 standing, 1.4 sprinting, 0 crouching, 1.3
  hiding, …).
- **Order:** by score = closeness (1 − d / (70 × sight multiplier)) + 0.35 in the cone + 0.2 (torch or lit) + 0.5 its
  current target − 0.25 downed, then by distance, then by user id.
- **Every sighting:**
  - refreshes `lastSeen[player]` and `lastSeenAny`;
  - refreshes the target's memory;
  - refreshes the chase's `seenAt` (when it is the target);
  - marks a swimmer on a pool level.

### 3.3 The stare (looking straight at it starts a chase)

Every brain tick, when the Creature is visible (not hidden, fade ≥ 0.5), awake, not Dormant / Scripted / Stunned, not
catching, and may hunt.
- **Who:** each hunted player Alive, not hiding, not in a duct.
- **Staring:** the eye-to-head distance is within the stare range, the angle between their view direction and the
  direction to its eye is **≤ 7°**, and the line is clear.
  - The range is **45** when their torch is on or the Creature stands lit (baked light at its eye − 2 above 0.2), else
    **18**.
- **Count:** while staring, their stare time grows by the brain's dt; otherwise it resets to 0.
- **Trigger:** at **1.0 s** the first such player is the stare trigger.
  - `lastSeenAny = now`, the `stared` event fires (their StareSting), and the brain starts a chase on them.
- A glance never counts: any tick off the cone resets it.

---

## 4. The pacing director (hunts come in waves)

- **Tension** (0..1).
  - It rises per second by:
    - 0.05 [0.06] while chasing;
    - 0.03 [0.035] while its target is in sight;
    - up to 0.15 for a player within 12 studs (linear, more the closer).
  - Relax counts rises at a quarter.
  - It decays 0.025 [0.02] per second, or 0.06 in Relax.
- **Phases:**
  - BuildUp → Peak: tension ≥ 0.7 [0.62] with a player within 40 [50].
  - BuildUp → Relax: a chase lasting the max chase (22 [28]).
  - Peak → Relax: a catch; the max chase; 55 [80] s in Peak; or tension ≤ 0.3 with no chase.
  - Relax → BuildUp: after 25 [15] s and once the catch cooldown is over; tension is cut to ≤ 0.35.
- **A catch:** tension 1, Relax, and a catch cooldown of **14.4 [8.8]** s.
- **A level's activation:** a fresh BuildUp, tension ≤ 0.15, and an airlock grace of **12 [6]** s.
- **May hunt** only outside the cooldown, the grace and Relax. Hunting gates chases, catches, stares, the
  saw-you-hide rule and teleports.

---

## 5. Levels, spawns and patrol loops

- **Run start.** It is placed Dormant on the basement (Level 0) at its spawn.
- **Each level's activation** (the basement too; Level 0 is hunted):
  - The pacing's airlock grace runs.
  - A stun or catch is called off.
  - Off its level, it is moved there **hidden** (a Reveal warp, section 7).
  - Dormant; it wakes into Patrol **4 s** later.
  - `lastSeenAny = now`; the first teleport no sooner than `now + 20 [12] + 45`.
- **The spawn hold (Levels 0, 2 and 3).**
  - **Candidates:** the level's PatrolWaypoint and CreatureSpawn anchors; a level with no PatrolWaypoint uses the
    derived patrol points.
  - **Rules:** **70..140 studs of walking** from the run route's entry; not visible from five eye points (4.6 high, the
    entry room's centre and corners inset 2) at heights 2.2 and 7.4; not in an objective room.
  - **Pick:** seeded `CreatureSpawn|<level>`.
  - **Hold:** shown there, facing the entry, Scripted, for the floor's grace **20 [12] s**.
  - **Early release:** a High or Critical player noise on the level (and an alert there when it lay within the
    noise's radius); a player within 30; or a player who can see its head from 70.
  - **Released:** it patrols.
- **The spawn anchor.** A CreatureSpawn in a room outside the level's main walkable component is ignored (today's
  basement spawn is in the boarded Condemned Store); the first patrol point is used instead.
- **Patrol loops:** the export's `patrolLoops`, else PatrolWaypoint anchors grouped by loop / order, else **derived**:
  - points at the obstacle-free spot nearest each room's centre;
  - in big rooms, a grid every 30 studs, inset 3;
  - excluding airlocks, ducts, stairwells, crawlways, pools and rooms outside the main component;
  - chained nearest-first (starting from the lowest x, then z) into loops of 6.
- **Walkable rooms and portals.** Rooms of kind Crawlway / Chase give it no floor; a portal flagged `crawlOnly`, or
  whose `clearance` is under 9 (its hunched height), is shut to it. The flags come from the layout door or the zone
  graph edge of the same portal; missing means clear.

---

## 6. The states

### 6.1 The transition table (every brain tick, first match wins)

| # | Condition | Goes to |
|---|---|---|
| 1 | a script holds it | Scripted |
| 2 | stunned | Stunned |
| 3 | not awake | Dormant |
| 4 | a catch, a grab or a ReachIn is running | stays |
| 5 | a warp is running | stays |
| 6 | it was Stunned (the stun ended) | Patrol, withdrawing |
| 7 | retreating in the water after a grab | AquaticStalk |
| 8 | in WallChase and (chase time ≥ **22 [28]** or may not hunt) | **gives up**: Patrol, fading out (section 7) |
| 9 | may not hunt | Patrol (withdrawing when it was in HidingResponse) |
| 10 | WallChase and it saw its quarry hide | HidingResponse |
| 11 | WallChase and someone in sight, or a stare trigger | WallChase |
| 12 | WallChase and (no sight of its target for **4 [5]** s, or the chase is done) | Search |
| 13 | WallChase otherwise | WallChase |
| 14 | HidingResponse not done | HidingResponse |
| 15 | HidingResponse done | WallChase if someone is in sight (or stares), else Search |
| 16 | it saw someone climb into a hiding spot | HidingResponse |
| 17 | a stare trigger | WallChase |
| 18 | someone in sight | AquaticStalk if a swimmer and it is in the water, else WallChase |
| 19 | a swimmer on the pool level (seen or heard within 6 s) | AquaticStalk |
| 20 | AquaticStalk | Patrol |
| 21 | Teleport not done | Teleport |
| 22 | heard a noise, outside InvestigateNoise and Search | InvestigateNoise |
| 23 | InvestigateNoise | stays; Patrol when done |
| 24 | Search: a High or Critical noise | InvestigateNoise |
| 25 | Search | stays; Patrol when done |
| 26 | a teleport is due (section 7.2) | Teleport |
| 27 | otherwise | Patrol |

**"In sight"** is any sighting. During the Teleport state's stalk, only sightings within **7** studs count.

On entering WallChase:
- The target is the stare trigger if any, else the target if seen, else the best sighting.
- The chase timer starts.
- A Screech plays at its eye (3D, volume 0.75).

On entering InvestigateNoise, the goal is the heard noise's believed position (its rank), or the memory.

On entering Search, the search point is the memory, else the watched spot's stand point, else where it is.

### 6.2 Dormant

Still, anchored, nobody targeted. In the water it keeps PoseMode Swim.

### 6.3 Patrol (the Stalk)

- **Pace and route:** 7 studs/s along its loops. It joins a loop at the nearest waypoint and walks one lap (the last
  waypoint leads back to the first).
- **Junction pauses:** where the route turns 50° or more (loops of 3+), it pauses twice for U(0.6, 1.1) s each.
  - First it looks into the room's farthest corner that is not behind it (dot with the incoming direction ≥ −0.2).
  - Then it looks along the way on.
- **The next loop:** the candidates are every loop but the last one walked (unless there is only one), sorted by their
  nearest waypoint's distance.
  - **Relax:** the loop whose centre is farthest from the latest heard position (or the nearest loop if nothing was
    heard).
  - **Otherwise, the heard pull:** with probability **0.75** (BuildUp) / **0.6** (Peak), the loop with the largest pull,
    where pull = Σ over heard rooms on the loop (within 60 s) of `rank × (1 − age/60)`.
  - **Otherwise:** a uniform pick among the nearest min(3, n).
- **Withdrawal:** entered "withdrawing", it first walks at 9 to the nearest patrol waypoint whose nearest player's eye
  is 35..140 studs away and which no player can see, then patrols.
- **Three failed legs** pick a new loop.

### 6.4 InvestigateNoise

- **Approach:** walks at 9 to the believed position (arrive 3; the room side of the nearest grate when the noise was
  inside a duct), for at most 30 s.
- **The search there:** runs U(**6, 10**) s.
  - A 1.4 s look back the way it came.
  - Then up to **2** hiding spots within 15 studs, nearest first, each with the sniff (section 8.1).
- **Re-targeting:** a noise at least as loud as the current one, or any noise while searching, re-targets it.
- **Done:** it is done when the steps or the time run out, after a running breath check finishes.

### 6.5 WallChase (the Chase)

- **Pace and goal:** 16.5 (capped 18.5), re-routing every 0.35 s.
  - The goal is the target's root while seen (arrive 1), else the memory (the last place seen or heard, arrive 2).
  - Within 10 studs with a clear straight line, it walks straight at the goal.
- **Catches:** every brain tick, every sighted player (the target first) is tested (section 10); the first that passes
  is caught (Hallway).
- **Target switch:** when the target is not seen and someone else is, it switches to the best sighting.
- **Done:** when the memory point is reached (within 4) with nobody seen; or when the route fails while the target
  is unseen. While seen, a failed route is retried after 1 s.
- **Ends:**
  - **4 [5] s** without a sight of the target → Search.
  - **22 [28] s** after it started (or a pacing breather) → it gives up.

### 6.6 Search

- **Approach:** walks at 8 to the search point (at most 15 s).
- **Duration:** U(**12, 18**) s in all.
- **The spots:** up to **4** hiding spots within **15** of the point, in a seeded random order. At each:
  - walk to its front (arrive 1.2);
  - hunch and hold 1.6 s facing it;
  - the sniff (section 8.1).
- **When no spots are left:** it turns on the spot (holds of 1.2 s, ±2.1 rad alternately) until the time is up.
- **Then:** Patrol.

### 6.7 HidingResponse (it saw you hide)

**The trigger: it saw them get in.** A hunted player whose MoveState turns to Hiding while seen within the last
**1.5 s**, with all of these true:
- it is awake;
- it is not warping, catching, scripted or stunned;
- it is not Dormant, Stunned, or already in HidingResponse;
- it may hunt;
- the spot is known.

The watch `{player, spot, front, since}` lasts 1.5 s for the brain to take it.

**The stand point:** the spot's front (its ExitAnchor: floor level, LookVector out of the spot) + LookVector ×
**1.6**.

**The approach:** at min(chase, 9). A failed or stuck route ends the state.

**The watch:** it faces the spot.

**LookAways:**
- The first comes U(**7, 10**) s after it arrives; each next one U(7, 10) s after the last ended.
- The tell: **0.7 s** before each, a low grunt (CreatureGrunt, 3D at its eye).
- The LookAway lasts **2.5 s**: action `LookAway`, sight facing the look-away direction, no peripheral sense.
- The look-away direction: perpendicular to the spot's facing, toward the more open side.
  - Probe clear lines from its eye at 4, 8, 12 and 16 studs each way; the longer clear run wins; ties go left.
  - The direction is tilted 0.35 back away from the spot, then normalized.
- A LookAway that would still run within 0.6 s of the reach is skipped.

**The ReachIn:** at `since + **30** [24]` s (since = when they got in), on arrival if later.
- Action `ReachIn`.
- **0.6 s** later, a **Locker** catch on the hider (section 10).

**The hider comes out** (no longer Hiding, still playing):
- **During a LookAway:** it notices nothing until the LookAway ends; then the state is done, with no exit catch.
  Whoever has broken the line by then is gone; anyone still in sight is chased (row 15).
- **Pulled out by a teammate:** no catch; when it was watching them, it is startled (blind) for **1.2 s**; done.
- **Otherwise (stepped out under its nose):** within **6** horizontal and 5 vertical of its root, with a clear
  chest-to-chest line, it is a **Hallway catch**. Then done.

It is also done when the hider stops playing or the hider's spot changes.

**Hiding without being seen** gets only the sniff (Search and InvestigateNoise).

### 6.8 Teleport

See section 7.2. After the warp it **stalks** the target for **10 s** at 7 studs/s, re-aiming at their position
every 1 s. Meanwhile only a sighting within **7** studs, or a stare, starts a chase; noises do not interrupt it. It
is done after 10 s, or when the target stops playing, hides or enters a duct. Then Patrol.

### 6.9 Stunned

A flask cloud stuns it for StunSeconds **6** (a second cloud extends it).
- It stumbles back away from the cloud at 3:
  - 9 studs straight back, else at ±35° or ±70°, whichever line is clear;
  - when boxed in, a flail in place;
  - in the water, a 12-stud backward glide.
- No senses, no catches. Its poseMode reads `Stunned`.
- Afterwards: Patrol, withdrawing.
- **No stun while:** it is hidden, a script holds it, or it is asleep.
- A stun calls off a running catch and any warp.

### 6.10 AquaticStalk (Level 4, the pool)

- **Getting in and out:** it enters and leaves the water **only by a warp** (section 7). It never walks down the deck,
  never climbs out and never uses a vent.
- **Swimming:** 2.5 under the surface at **6.5** (a freestyle swimmer, 9, outswims it).
  - It goes toward the swimmer while seen, else the latest Water noise, else the memory.
  - Close under a swimmer it may not take, it circles: radius 6 at 0.6 rad/s.
- **The telegraphed lunge:** when a swimmer's splash meter has crossed its threshold (within the last 10 s) and they
  are within **9**:
  - it holds still for **1.2 s** while bubbles, a ripple ring and a low growl (CreatureGrowl, speed 0.72, volume 1.2)
    give away the origin;
  - then it lunges (min(18.5, 18 × mult)) for at most **2.5 s**;
  - within **4.5** it calls the pool grab;
  - a miss waits **2 s** before the next telegraph.
- **Grace:** for **20 s** after a player first stands in the pool room it neither sees nor hears anyone there.
- **After a grab is let go:** for **15 s** it retreats to the point of the basin farthest from the nearest player, and
  it does not lunge.
- **No other catch:** there is no Hallway catch on or from the water.
- **A leaving warp** that has not yet placed it is called off when a swimmer appears.

### 6.11 Scripted

A level scene holds it (`acquireScripted`): no senses, no decisions, no catches, no warps. The handle moves, places,
poses, hides, faces and releases it. Released hidden, it reveals itself by a Reveal warp. Released into a state it
cannot enter, it takes Patrol: VentChase becomes InvestigateNoise; Search, HidingResponse and Teleport become Patrol.

---

## 7. Warps (every FadeOut / FadeIn) and the teleport

### 7.1 The warp machine (advanced every tick; never while a script holds it; it stands still throughout)

| Phase | Lasts | What happens |
|---|---|---|
| FadeOut | 0.6 s | action `FadeOut`, fade 1 → 0 (CreatureVanish plays where it stands) |
| Hidden | until clear | body hidden; placed at the destination; waits until it may appear there |
| Warning | 1.6 s | **teleports only**: the `teleportWarning` event (section 7.3) |
| FadeIn | 0.8 s | shown; action `FadeIn`, fade 0 → 1; faces the target |
| Stare | 1.2 s | **teleports only**: action `Stare`, facing the target; ends early on a stare trigger |

**May appear at a spot** when the nearest player's root is at least **12** away (straight line, 3D), and:
- **teleport:** in no player's view (below);
- **into the water:** in no player's view, a submerged spot being seen only within **10** (murk);
- **any other warp:** not visible at all (no clear line from any player's eye to its head or chest, within 250).

**In a player's view:** for the root point P, either of `P + 3.1` (its head) and `P` (its chest):
- it is within **8** of their eye; or
- it lies within **80°** of their view direction, with a clear line, within 250.

All players in play count, ignored ones included.

**Destinations.**
- **Hidden phase:** a destination still watched after **3 s** is replaced by the warp's own pick (picks at most every
  3 s). After **12 s** hidden, any unseen land spot at least 12 from everyone will do, with no warning and no stare.
- **Warning phase:** if the spot fails the check at the warning's end, it picks a new spot and warns again, at most
  **2** retries. After that, any unseen spot ≥ 12 from everyone, unannounced.

| Warp | Start | Destination |
|---|---|---|
| Teleport | FadeOut where it is | the planned spot (7.2); re-picks re-run the placement on the same target |
| Give-up | FadeOut where it is | the land spot nearest where it vanished that is ≥ **45** from every player's eye and unseen |
| Pool in | FadeOut on land | the water point nearest the goal that may appear: the goal clamped into the water, else a 3 × 5 grid over the basin |
| Pool out | FadeOut under water | the land spot nearest the goal that is ≥ **30** from every player's eye and unseen |
| Reveal | already Hidden | where it was placed; after 3 s watched, the nearest unseen land spot |

**Land spots** are the patrol waypoints plus a lattice every **5** studs over the walkable rooms: inset 2.5 from the
walls, clear of obstacle footprints, with no airlocks, ducts, stairwells, crawlways or pools. **Facing** is toward
the nearest player.

### 7.2 The teleport (THRESHOLD's jumpscare engine)

**Due** when every one of these holds, checked each brain tick:
1. state Patrol, awake, may hunt;
2. this tick: nothing seen, no stare, no hide watch, nothing heard, no swimmer, no catch, no warp, no stun, no script;
3. on foot (not in the water);
4. `now ≥ teleportReadyAt`, where `teleportReadyAt`:
   - is set at a level's activation to `now + FloorGrace (20 [12]) + 45`;
   - after each teleport, to `now + U(60, 120)` [U(40, 80)];
   - after a give-up, rises to at least `now + 30` [20] (half the low bound);
5. `now − lastSeenAny ≥ **25**` (nobody seen, nobody staring);
6. `now ≥ lastCatchAt + 25` and `now ≥ lastDownAt + 25` (any player going down, by any cause);
7. the game does not block it:
   - an objective's survive countdown is running (Floor 3's motor);
   - or, on the roof, the finale's phases Smash, Chase, FinaleWait, Finale and Done;
8. a plan exists. Otherwise the next try is 4 s later.

**The target:** the hunted players on its level, on foot, not hiding, not in a duct, not swimming. The pick is
weighted with the seeded stream; the weight starts at 1 and is multiplied:
- × **2** isolated (no other playing player within 25; only with two or more players);
- × **1.6** loud (a High or Critical noise heard from them within 20 s);
- × **1.5** not the last teleport's target.

**The spot:**
1. **Candidates:** `meta.teleportPoints[level]` (`{pos, facings, region, zone}`) when present, else the 5-stud land
   lattice.
2. Keep the candidates:
   - within 6 of the target's room floor;
   - within **24.5** horizontally of the target;
   - not in the target's room when that room is a **keep-room** (any kind but Corridor / Tunnel / Gallery / Hallway);
   - with the appear point (floor + 4.7) at least **12** from every player's root;
   - with a walking distance (the nav route from the target's feet) of **12..24**;
   - in no player's view (above).
3. **Classify** each kept candidate with the target's **trail**: their root sampled every 0.5 s over the last 15 s,
   leaving out the last 1 s.
   - **Behind:** within 6 (horizontal) of a trail point, and the dot of their flat look with the direction to the
     candidate is under 0.25.
   - **Ahead:** otherwise, when the dot of their travel direction (last movement; their look when standing) with the
     direction to it is over 0.25.
   - **Behind** also when that look dot is under −0.25.
   - **Side:** otherwise.
4. **Choose:** roll the stream. Under **0.6** try Behind, Ahead, Side, in that order; else Ahead, Behind, Side. The
   first non-empty class wins; pick uniformly within it.
5. The root faces the target.

**Then:** the warp (7.1) with the warning and the stare.
- **The reveal:** during FadeIn and Stare, the moment the target's view centre comes within **22°** of its eye (clear
  line, within 48), the `revealed` event fires once, the reveal scare on their screen (no damage).
- **After the warp:** the 10 s stalk (6.8).
- **Bookkeeping:** `lastSeenAny` is set to the warp's end, so the next one needs 25 unseen seconds again.

### 7.3 The warning (cosmetic outputs, all pages)

Emitted at the start of the Warning phase with the spot's floor point.
- **The lights:** the flicker groups of the fixtures within **20** of the spot stutter for 1.6 s.
  - Fallback: the nearest within 32. At most 6 groups. Scripted groups, kept-lit lights and lights more than 20 off
    vertically are skipped.
  - The factor each frame: `b = floor((t + seed) × 11 + 1.6 × sin((t + seed) × 7.3)) mod 3` → 0.9 / 0.05 / 0.25.
  - The factor is 0 in the last 0.25 s; the override is released at the end.
  - A group the floor holds (the basement's power cut, its switch-on) takes the lower of the hold and the stutter: a
    dark circuit stays dark, and the release hands it back to the hold.
- **The hiss:** TeleportHiss at the spot + 4 (3D).
- **The torch:** on the target's screen only, the flashlight's static stutters (1 or 0.35 at about 9 Hz) for 1.6 s,
  with TorchStutter.

---

## 8. Hiding spots

**Kinds.** Entities tagged `Hideable` with `HideKind` `Locker` | `Barrel` | `Cabinet` (missing: Locker). Today's lockers
are tagged `HideableLocker`. All kinds share the interaction:
- the attachments are ExitAnchor, HideAnchor and PeekAnchor, plus a Hide prompt (a 0.25 s hold);
- a spot without a door (no DoorRest) has nothing that swings.

**Getting in** is heard: HideEnter (8), or HideEnterHurried (14) after sprinting within the last 1 s. The noise is at
the door.

### 8.1 The sniff (it did not see you get in)

Search and InvestigateNoise stand at a spot's front, hunched, and ask the game's inspector.
- **An empty spot** answers Empty after 1.3 s.
- **An occupied spot** runs the breath check:
  - the warning comes 0.9 s after the check starts (after the hider has settled);
  - then a window of a seeded U(3.5, 6) s.
- **Breath:** max 7 s; drains 1/s while held; recovers 0.6/s.
- **Caught** when:
  - a held breath runs out;
  - or, inside the window, they let go with under 30 % left;
  - or, inside the window, they are not holding for more than 0.5 s.
- **Safe:** holding through the window is HiddenSafe; the Creature leaving the door (out of its sniffing states, or
  more than 8 away) ends it safe.
- **Caught →** the gasp (the Gasp noise, 40), then a **ReachIn**: the action, then a Locker catch 0.6 s later.
- The inspector may take up to 11 s; the state waits for it.

### 8.2 The stay limit (DOORS' Hide)

From getting in:
- **35 s:** the warning knock (HideWarn) and a hint.
- **45 s:** shoved out to the spot's exit, unhurt (HideKick).
- A running breath check holds the shove until it ends.

### 8.3 Fake-outs (DOORS' Jack)

- **Which spots:** spot `id` is a fake-out this run when `seededRandom(runSeed, "Fakeout|" + id).next() < 1/12`. Each
  id has its own stream, so adding spots never reshuffles the rest. About 1 spot in 12.
- **At most one per floor per player:** a per-player budget, one per level.
- **What happens:** on getting into an armed spot within the budget, 0.12 s after the door starts to open (that is,
  0.32 s after the prompt), the player alone gets the reveal scare and the FakeoutShriek, and nothing else.
- **Then safe:** the spot is ordinary for the rest of the run, for everyone (co-op shares it).

### 8.4 The pull-out (co-op, THRESHOLD's throw)

- **The prompt:** a "Pull out" prompt (a 1.2 s hold, the Hide prompt's distance) shows on a spot a teammate hides in.
- **Who may pull:** the puller must be Alive, on foot, not hiding, and within 7 of the spot's exit.
- **The throw:** the hider is thrown out beside the puller, at the puller's x / z and the exit's floor height, facing
  away from the spot. When that spot is not clear, they go to the spot's own exit.
- **The brain is told it was a pull:** no exit catch, and a 1.2 s startle if it was watching them.

---

## 9. The catch

**May catch** (every brain tick in WallChase; directly for the 6-stud exit rule and the ReachIn) only when all hold:
- it may hunt and is not busy, hidden, stunned or warping;
- neither it nor the victim is in the water;
- the victim is playing, not hiding, not in a duct;
- there is a clear line eye to eye **and** a clear line chest to chest: its root + 1 to their root + 0.5. Never
  through a wall;
- the victim is within reach: 4 horizontal (6 for the exit rule) and 5 vertical.

The game may veto a catch (a cutscene, a player not playing).

**The moment** (unchanged from today):
- The victim is locked.
- The two are set face to face, it at the kind's distance: Hallway 2.4 (min 1.9), Locker 3.0 (min 2.4), Underwater
  2.6 (min 2.0).
- 0.2 s later the lunge (0.45 s), then the hold (1.4 s).
- At 2.05 s the outcome:
  - **Downed** for an Alive victim never downed this run;
  - otherwise **Executed** (a second catch, or a catch of a downed player).
- Action `Jumpscare` throughout.
- Afterwards the pacing notes the catch (cooldown 14.4 [8.8] s and Relax), so a chase ends by fading away, and no
  teleport comes within 25 s.
- A catch that has not ended after 6.05 s is called off.

**Downed** players are revived by teammates (unchanged); bleed-out, then the second catch executes.

---

## 10. Movement, stalls and repositioning

- **Routes:** A* over the zone graph's open portals, string-pulled through each opening narrowed by the agent radius,
  and detoured round obstacle footprints inside rooms. Fixture doors are open only while open.
- **Waypoints:** a waypoint every 4 studs, reached within 2.5. Re-routed every 2 s (Patrol), 1 s (Investigate,
  Search) or 0.35 s (chases), when the goal has moved 2+ studs.
- **Stalls:** no progress of 1.2 studs for 2.5 s forces a fresh route. A second stall within 12 s reports Stuck.
- **Stuck:** only while nobody sees it, it is moved to the nearest patrol waypoint that is 6+ studs away and unseen,
  and the state restarts.

---

## 11. The player's feel (outputs)

- **Heartbeat and breathing:** within **25** of its eye (seen or not, when it is not hidden, Dormant or Scripted), a
  panic floor of `0.27 + 0.43 × smoothstep(25 → 6, distance)`. Heartbeat starts at panic 0.25 and races at 0.62.
- **Torch static:** within **15**, the flashlight's EMF is `smoothstep(15 → 2.25, distance)`.
- **The chase music:** while the Creature chases this player (WallChase, they are its target):
  - the ChasePulse loop, fading in over 0.4 s;
  - the ChaseSting at its start;
  - a 1.4 s fade-out when it ends.
- **The stare:** StareSting for the starer.
- **The give-up:** GiveUpSwell for the one it chased; CreatureVanish where it vanished for the others.
- **The rattle:** while it stalks (Patrol, Teleport, Search, HidingResponse, InvestigateNoise) within 22 of the
  player's eye, CreatureRattle at its eye every U(4.5, 8) s.
- **Footfalls:** heavy, about 2 s apart when stalking (the animator).

| Sound | When | Where |
|---|---|---|
| Screech | a chase starts; a stun | its eye (3D) |
| ChaseSting / ChasePulse | a chase on you starts / runs | you |
| StareSting | your stare started the chase | you |
| GiveUpSwell | the chase on you gave up | you |
| CreatureVanish | every FadeOut | where it stood (+5) |
| TeleportHiss | a teleport's warning | the spot (+4) |
| TorchStutter | a warning aimed at you | you |
| RevealSting | a reveal (until the rig's own reveal scare plays it) | you |
| FakeoutShriek | a fake-out | you |
| CreatureGrunt | 0.7 s before a LookAway | its eye |
| CreatureRattle | stalking within 22 | its eye |
| HideWarn / HideKick | 35 s in a spot / shoved out or pulled | you |
| CreatureGrowl | a pool lunge's telegraph | the lunge origin |
| JumpscareSting + Screech | a catch | the victim / its face |

---

## 12. The view contract (what the rig animates)

Published every frame (`snapshot()` / `viewState()`):

| Field | Meaning |
|---|---|
| `state` | the MonsterState |
| `speed` | its root's measured horizontal speed (smoothed; a placement reads 0) |
| `poseMode` | `Biped` \| `Hunched` (clearance < 12.5, or sniffing) \| `Swim` \| `Stunned` |
| `action` | `Stare` \| `ReachIn` \| `LookAway` \| `FadeOut` \| `FadeIn` \| `Jumpscare` \| null |
| `actionStartedAt` | game time the action began |
| `fade` | 0..1 visible |

---

## 13. Co-op

- **One brain:** on the host (Roblox: the server).
- **Remote players:** handles with the same reads:
  - their root, from their newest pose;
  - their look direction, from the pose's yaw and pitch, so the stare and the views count every player's real look;
  - MoveState, life and downs, duct, swim, torch, and the hiding spot they occupy.
- **The world packet:** carries position, yaw, state, pose, hidden and target at the state rate. The exact state and
  the action (with its age) also go reliably on every change, so a client's puppet publishes the same contract fields.
- **Snaps:** positions are never interpolated across a hidden sample. A teleport (it always moves while hidden) snaps.
- **Events to everyone:** a teleport's warning (the flicker and the hiss on every page; the torch stutter only on the
  target's page), the grunt, a give-up.
- **Events to their target only:** a reveal scare, a stare's sting.
- **Fake-outs** play only for the one who opened the spot; the spot is then safe on every page.
- **A pull-out** goes from the puller to the host, then to the hider's page, which throws them out; the host's brain
  is told it was a pull.
- **Catches of a remote player:** run on the host; the victim's page plays the moment and applies the outcome.

---

## 14. Fairness rules (asserted by `web/tools/creature-sim.mjs`)

1. Never faster than a sprinting player (19) outside Scripted, on Standard and Nightmare.
2. Never teleports into anyone's view, nor within 12 studs of anyone. Every teleport:
   - is warned 1.6 s ahead;
   - is 12..24 studs of walking from its target at planning.
3. Never catches through a wall: every catch has a clear chest-to-chest line.
4. The first teleport on a floor comes no sooner than the floor's grace + 45 s.
5. A chase ends after 4 s without a sight (Search), or at 22 [28] s whatever happens (it fades away).
6. A LookAway lets a hider slip out and escape by breaking the line; stepping out under its nose is a catch; the
   ReachIn comes at 30 s; a teammate's pull-out is no catch.
7. The pool: the 20 s grace, a freestyle swimmer outswims it, every lunge is telegraphed, the 15 s retreat after a
   grab, and it never climbs out.
8. Determinism:
   - the same run gives the same path;
   - 20 and 144 fps render loops give identical decisions and positions;
   - no NaN, no stuck state, no state or warp held past its bound in a soak of every level.

---

## 15. Map data it reads (the tunnel maps)

| Data | Use |
|---|---|
| Entities tagged `Hideable` + `HideKind` | hiding spots (ExitAnchor / HideAnchor / PeekAnchor, Hide prompt) |
| `layoutDoors[].clearance` / `crawlOnly`, `zoneGraph.edges[].clearance` / `crawlOnly` | shut portals (crawl-only or under 9), hunching (under 12.5) |
| `rooms[].height`, kind `Crawlway` / `Chase` | hunching; no floor |
| `meta.teleportPoints[level]` `{pos, facings, region, zone}` | teleport candidates (`zone` names the room; its facing is toward the target, `facings` unused) |
| `patrolLoops`, PatrolWaypoint anchors | the Stalk's loops (derived from the rooms when absent) |
| CreatureSpawn anchor | its start (ignored outside the main walkable component) |
| `meta.creature` `height`, `hunchedHeight`, `eyeHeight`, `reach` | the metrics in section 2 |
| `basins` | the pool |
| probe grids (base irradiance) | "lit" |
