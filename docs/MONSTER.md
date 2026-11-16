# The Tall Man: the Creature's behaviour

The complete behaviour of the monster ("the Creature" in game text) as the website implements it, precise enough to
reproduce on Roblox without reading the JavaScript. Studs and seconds throughout. Every number is **Standard**; the
**Nightmare** value follows in brackets where it differs.

The numbers are `CreatureConfig.luau`'s (and `DifficultyConfig`'s, `NoiseConfig`'s). The presence layer (sections 15 to
19: the director, the presence beats, the senses' additions, the chase's wind-up, pursuit and cap, the cut-off and
approach teleports, how far its sounds carry) is `CreatureConfig.Presence`, exported into `world.json`
`meta.creatureConfig` and read from there by the website. Where it differs from an older number (the chase's cap and
loss time, `DifficultyConfig.maxChaseSeconds` / `chaseLostSeconds`; the teleport's stalk rule, `Teleport.StalkNear`;
the rattle's and the heartbeat's radii, `Senses.RattleRadius` / `NearRadius`), this text and the website follow
`Presence`; the Roblox runtime keeps the older numbers until it is ported from this text.

Where the code lives (web): `web/src/creature/` (`service.js` is the brain, `brain.js` the transition table, `states/*`
the states, `presence.js` the director, `beats.js` the beats' geometry, `perception.js`, `hearing.js`, `pacing.js`,
`locomotion.js`, `nav.js`, `config.js`), and the game's side in
`web/src/game/` (`mechanics/lockers.js` and `mechanics/hidespots.js` for the hiding spots, `mechanics/monsterFx.js` for the
warnings and the music, `coop/creature.js` for co-op, `objectives/spawns.js` for the start rule, `ui/hints.js` for the first-time hints). The
fairness rules are asserted by `web/tools/creature-sim.mjs`; the presence targets (section 20) by
`web/tools/presence-sim.mjs`.

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
| Eye above the root | Biped 5.64, Hunched 3.6, Swim 0.4, Stunned 4.6 (`meta.creature.eyeHeightAboveRoot` when the rig exports it), nudged 0.6 forward along the facing. Its eye is the one of the poseMode it stands in (section 12): under a low clearance the hunched one, never the standing eye (10.34 over the floor) inside a tunnel's ceiling. Sight, the stare, the reveal, the catch's eye line and the hitbox all use it |
| Catch reach | 4 horizontal, 5 vertical (`meta.creature.reach` when exported) |
| Path agent | radius 2, height 9 (its hunched height: it passes under nothing lower), no jumping, no climbing; a pool's water is no floor (section 5) |
| Hunch | poseMode `Hunched` wherever the clearance (a portal's `clearance` within 3 studs of its opening, else the room's height) is under **12.5**, and while sniffing at a hiding spot. The clearance counts at its root and along its route ahead, **2 + pace × 0.5** studs (its head's lead plus what it walks while it bends), every tick: it is down before its head reaches a lintel |

**Speed cap.** Outside Scripted nothing ever moves faster than **18.5** (a sprinting player runs 19).
Every state's pace is `min(18.5, base × difficulty multiplier (1 [1.2]) × level speed scale (0.5..2))`.

| State | Base pace |
|---|---|
| Patrol (the Stalk) | 7; to a director's search hint 9 |
| InvestigateNoise | 9 |
| WallChase (the Chase) | 16.5 → 16.5 [18.5 capped] |
| Search | 8 |
| HidingResponse (approach) | min(chase, 9) |
| Teleport (the stalk after it) | 7 |
| Peek | 9 to its corner, 7 stepping out and back |
| Glimpse | 9 to its start, 12 across |
| Shadow | the player's pace, never under 7 nor over 11; 11 catching up |
| PassBy | 7 |
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
| Pickup (an item taken: a fuse, the keys, a battery, a flask) | 20 | Normal | Air |
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
- A lit torch's glow seen (section 17.1) is heard like a Normal noise of its holder at the lit spot.

### 3.2 Sight

Evaluated every brain tick unless it is **blind**: hidden, fading (any warp), or startled by a pull-out (1.2 s).
- **Candidates:** every hunted player (Alive or Downed with a body, not ignored).
- **Never seen:**
  - MoveState Hiding;
  - in a duct or a crawlway;
  - Underwater, unless the Creature swims (PoseMode Swim or AquaticStalk).
- **Range:** torch on **70**; torch off in a lit pool **38**; torch off in the dark **20**.
  - Crouching or crawling downed: × 0.75.
  - Standing still in the dark (torch off, not lit, not moving): × **0.5** (section 17.2).
  - Times the difficulty (1 [1.15]).
  - **Lit** means the baked probe irradiance at the player's root + 1 has luminance (0.2126 R + 0.7152 G + 0.0722 B)
    above **0.2**.
- **Cone:** half-angle **55°**, or **75°** when the player moves (their speed above 2 studs/s, measured from their root
  between brain ticks: `speed += (v − speed) × clamp01(dt × 6)`, a jump over 12 studs counts as 0).
  - The cone is measured about its upright axis, as a bearing from its facing: it bends its long neck to look down, so
    whoever is at its feet, standing or downed, is in front of it, not below its view.
  - Anything within the peripheral range (along the floor) is felt whatever the facing: 6, or 10 when moving.
  - During a LookAway the facing is the look-away direction and there is no peripheral sense.
- **Line:** a clear ray from its eye to the player's eye (root + 1.5 standing, 1.4 sprinting, 0 crouching, 1.3
  hiding, …).
- **Order:** by score = closeness (1 − d / (70 × sight multiplier)) + 0.35 in the cone + 0.2 (torch or lit) + 0.5 its
  current target − 0.25 downed, then by distance, then by user id.
- **Every sighting:**
  - refreshes `lastSeen[player]` and `lastSeenAny`;
  - refreshes the target's memory (the place, and the way they were running when they moved faster than 2: the
    chase's pursuit, section 18.2);
  - refreshes the chase's `seenAt` (when it is the target);
  - fills the player's noticing (section 17.3);
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
  - BuildUp → Relax: a chase lasting the max chase (the chase's cap, **12 [45]**, section 18.3); the breather (the
    search after a chase is over, section 15.4).
  - Peak → Relax: a catch; the max chase; the breather; 55 [80] s in Peak; or tension ≤ 0.3 with no chase.
  - Relax → BuildUp: after the breather's **35 [15]** s (`CreatureConfig.Presence.Chase.Breather`, section 18.3) and
    once the catch cooldown is over; tension is cut to ≤ 0.35.
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
- **Pools.** A basin's water is no floor (it gets in and out only by a warp, 6.10): a room a basin lies in keeps only
  the deck round it, as up to four strips (west and east the room's full depth, north and south between them; a strip
  under 2 wide is left out), joined where they meet. A door opens onto the strip it lies on. No route crosses the
  water, so a pool that splits a deck in two leaves two decks joined only by the ways round it, if any.

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
| 8 | in WallChase and (chase time ≥ **12 [45]** or may not hunt) | **gives up**: Patrol, fading out (section 7) |
| 9 | may not hunt | Patrol (withdrawing when it was in HidingResponse) |
| 10 | WallChase and it saw its quarry hide | HidingResponse |
| 11 | WallChase and someone in sight, or a stare trigger | WallChase |
| 12 | WallChase and (no sight of its target for **4 [6]** s, counted only while it is not running to the last place it saw or heard them or on along their way; or the chase is done: its pursuit run, section 18.2) | Search |
| 13 | WallChase otherwise | WallChase |
| 14 | HidingResponse not done | HidingResponse |
| 15 | HidingResponse done | WallChase if someone is in sight (or stares), else Search |
| 16 | it saw someone climb into a hiding spot | HidingResponse |
| 17 | a stare trigger | WallChase |
| 18 | someone in sight | AquaticStalk if a swimmer and it is in the water, else WallChase |
| 19 | a swimmer on the pool level (seen or heard within 6 s) | AquaticStalk |
| 20 | AquaticStalk | Patrol |
| 21 | Teleport not done | Teleport |
| 22 | a presence beat (Peek, Glimpse, Shadow, PassBy) not done | stays |
| 23 | heard a noise, outside InvestigateNoise and Search | InvestigateNoise |
| 24 | InvestigateNoise | stays; Patrol when done |
| 25 | Search: a High or Critical noise | InvestigateNoise |
| 26 | Search | stays; Patrol when done (withdrawing, and a breather, when it followed a chase: section 15.4) |
| 27 | the director hands over a beat (section 15.3) | that beat |
| 28 | a teleport is due (section 7.2) | Teleport |
| 29 | otherwise | Patrol |

**"In sight"** is a sighting of a player it has **noticed** (section 17.3; while it chases, or watches a hiding spot,
any sighting). During the Teleport state's stalk, a noticed player within **40 [50]** (section 18.4). While a beat
plays (not a pass-by), only a sighting within **12** (section 16).

On entering WallChase:
- The target is the stare trigger if any, else the target if seen, else the best sighting.
- The chase timer starts.
- A Screech plays at its eye (3D, volume 0.75).
- The wind-up (section 18.1): out of anything but HidingResponse it holds **1.5 [0.7]** s facing them first (**2.8
  [2]** s when they stand within **20**), and catches nobody meanwhile.

On entering InvestigateNoise, the goal is the heard noise's believed position (its rank), or the memory.

On entering Search, the search point is the memory, else the watched spot's stand point, else where it is.

### 6.2 Dormant

Still, anchored, nobody targeted. In the water it keeps PoseMode Swim.

### 6.3 Patrol (the Stalk)

- **Pace and route:** 7 studs/s along its loops. It joins a loop at the nearest waypoint it can walk to and walks one
  lap (the last waypoint leads back to the first).
- **Junction pauses:** where the route turns 50° or more (loops of 3+), it pauses twice for U(0.6, 1.1) s each.
  - First it looks into the room's farthest corner that is not behind it (dot with the incoming direction ≥ −0.2).
  - Then it looks along the way on.
- **The next loop:** the candidates are every loop it can walk to from where it stands (a waypoint of it reachable
  through the doors open now, or in a pool: a warp gets it there; every loop when none is), but the last one walked
  (unless there is only one), sorted by their nearest waypoint's distance. A level can fall apart into parts joined only
  by locked airlocks or ducts, and a warp can leave it in any of them; a loop out of reach would fail every leg where
  it stands.
  - **Relax:** the loop whose centre is farthest from the latest heard position (or the nearest loop if nothing was
    heard).
  - **Otherwise, the heard pull:** with probability **0.75** (BuildUp) / **0.6** (Peak), the loop with the largest pull,
    where pull = Σ over heard rooms on the loop (within 60 s) of `rank × (1 − age/60)`.
  - **Otherwise, the director's lean:** with a player to lean toward (section 15.2), the loop passing closest to them
    (its nearest waypoint).
  - **Otherwise:** a uniform pick among the nearest min(3, n).
- **The director's search hint** (section 15.3) breaks the lap: it walks to the hint at **9** (arrive 2), there looks
  into the room's far corner not behind it, then back the way it came (U(0.6, 1.1) s each), and picks its next loop.
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
- **The pursuit** (section 18.2): the memory point reached with nobody seen, when it saw them running it runs on along
  their way, once, and the end of that run becomes the memory.
- **Done:** when the memory point is reached (within 4) with nobody seen and the pursuit run (or there was none); or
  when the route fails while the target is unseen. While seen, a failed route is retried after 1 s.
- **Ends:**
  - **4 [6] s** without a sight of the target, the clock waiting while it runs to the memory point and on along their
    way → Search.
  - **12 [45] s** after it started (or a pacing breather) → it gives up.

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
- **Every watch has one (the fair outplay):** a first LookAway that would be skipped (below), after a long walk to
  the spot, comes instead as late as it still ends 0.6 s before the reach, and never sooner than its tell allows
  (0.7 s after it arrives).
- The tell: **0.7 s** before each, a low grunt (CreatureGrunt, 3D at its eye).
- The LookAway lasts **2.5 s**: action `LookAway`, sight facing the look-away direction, no peripheral sense.
- The look-away direction: perpendicular to the spot's facing, toward the more open side.
  - Probe clear lines from its eye at 4, 8, 12 and 16 studs each way; the longer clear run wins; ties go left.
  - The direction is tilted 0.35 back away from the spot, then normalized.
- A LookAway that would still run within 0.6 s of the reach is skipped.

**The ReachIn:** at `since + **30** [24]` s (since = when they got in); when it arrived too late for its first
LookAway to end 0.6 s before that, 0.6 s after that LookAway ends.
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
every 1 s. Its stare counts as noticing the target when it ends with a clear line to their eye within **40 [50]**.
Meanwhile a sighting of a noticed player within **40 [50]**, or a stare, starts a chase (with its wind-up); noises do
not interrupt it. It is done after 10 s, or when the target stops playing, hides or enters a duct. Then Patrol.

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
   - within **24.5** horizontally of the target (**70.5** + their **lead** for a target on the move: their speed above
     2 and a travel direction; the lead is the way they cover before it may appear, their speed × (the 0.6 s FadeOut +
     the 1.6 s Warning), about 42 for a sprinter);
   - not in the target's room when that room is a **keep-room** (any kind but Corridor / Tunnel / Gallery / Hallway);
   - with the appear point (floor + 4.7) at least **12** from every player's root;
   - with a walking distance (the nav route from the target's feet) of **12..24**; or, for a target on the move, an
     Ahead candidate (below) **24..70** walked past their lead (24 + lead .. 70 + lead: the cut-off, section 18.4);
   - in no player's view (above).
3. **Classify** each kept candidate with the target's **trail**: their root sampled every 0.5 s over the last 15 s,
   leaving out the last 1 s.
   - **Behind:** within 6 (horizontal) of a trail point, and the dot of their flat look with the direction to the
     candidate is under 0.25.
   - **Ahead:** otherwise, when the dot of their travel direction (last movement; their look when standing) with the
     direction to it is over 0.25.
   - **Behind** also when that look dot is under −0.25.
   - **Side:** otherwise.
4. **Choose:** roll the stream. Under **0.75 [1]** (the cut-off share) try Ahead, Side, Behind, in that order; else
   Behind, Ahead, Side. The first non-empty class wins; pick uniformly within it.
5. The root faces the target.

**Then:** the warp (7.1) with the warning and the stare. (The director's approach teleport, section 15.3, is the same
warp with the same warning, no stare, landing 45..80 walked from its player.)
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

**Refused while it is watching you** ("It's watching you. Lose it first."): it chases you (WallChase, you its
target) **and** has a clear line from its eye to yours within its full sight range (the torch range × the
difficulty's sight multiplier, section 3). A chased player who has broken the line (round a corner, behind a door
frame) may get in: seen within the last 1.5 s, HidingResponse (section 6.7); else only the sniff can find them (8.1).
Co-op: each player's own Creature line decides for them.

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
- **45 s:** shoved out to the spot's exit, unhurt (HideKick); with no clear spot to step out to, let go where they are.
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

The ReachIn's victim is hiding, so it is held to the chest line alone, with the hiding spot it reaches into (that
spot's own door and shell, which the catch tears open) left out of it: anything else between their chests, and there
is no catch.

The game may veto a catch (a cutscene, a player not playing).

**The moment:**
- The victim is locked.
- The two are set face to face, root to root at the kind's distance (`jumpscare.js` SPACING, far enough back for the
  rig's bow to bring the mask level with the victim's eye; `docs/MONSTER-LOOK.md`): Hallway 4.2 (min 3.4), Locker 4.4
  (min 3.6), Underwater 2.6 (min 2.0).
  - It closes in, or is eased back out to the minimum, along the line between them, but only as far as its body
    (radius 1, at its root's height ± 1) clears the walls: the root never ends in or behind a wall. The bow steps back
    the rest, on screen only.
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

- **Routes:** A* over the zone graph's open portals (never across a pool's water, section 5), string-pulled through
  each opening narrowed by the agent radius, and detoured round obstacle footprints inside rooms. Fixture doors are
  open only while open.
- **Waypoints:** a waypoint every 4 studs, reached within 2.5. Re-routed every 2 s (Patrol), 1 s (Investigate,
  Search) or 0.35 s (chases), when the goal has moved 2+ studs.
- **Stalls:** no progress of 1.2 studs for 2.5 s forces a fresh route. A second stall within 12 s reports Stuck.
- **Walls:** sliding along a wall never carries a step farther than its pace × the step's time (the push out of the
  wall can turn a step, never lengthen it).
- **Stuck:** only while nobody sees it, it is moved to the nearest patrol waypoint that is 6+ studs away and unseen,
  and the state restarts (a presence beat, a teleport's stalk or a hiding watch ends instead: its plan belonged to
  where it stood; a teleport entered again would replay its warp and warning at the same spot, a watch walk back into
  the same stall for as long as the hider stays in).

---

## 11. The player's feel (outputs)

- **Heartbeat and breathing:** within **45** of its eye (seen or not, when it is not hidden, Dormant or Scripted), a
  panic floor of `0.27 + 0.43 × smoothstep(45 → 6, distance)`: its real distance (section 19). Heartbeat starts at
  panic 0.25 and races at 0.62.
- **Torch static:** within **15**, the flashlight's EMF is `smoothstep(15 → 2.25, distance)`.
- **The chase music:** while the Creature chases this player (WallChase, they are its target):
  - the ChasePulse loop, fading in over 0.4 s;
  - the ChaseSting at its start;
  - a 1.4 s fade-out when it ends.
- **The stare:** StareSting for the starer.
- **The give-up:** GiveUpSwell for the one it chased; CreatureVanish where it vanished for the others.
- **The rattle:** while it stalks (Patrol, Teleport, Search, HidingResponse, InvestigateNoise, and the beats Peek,
  Glimpse, Shadow, PassBy) within **45** of the player's eye, CreatureRattle at its eye every U(4.5, 8) s (heard to 55).
- **First-time hints** (`ui/hints.js`, TutorialConfig): it within the heartbeat's radius (switch the torch off,
  crouch, hide), a teleport's warning within 40 (turn back, step aside, hide), it shadowing you (look back: a Shadow
  whose player is you, read from the target it publishes, section 12).
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
| CreatureRattle | stalking within 45 | its eye |
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
| `poseMode` | `Biped` \| `Hunched` (clearance < 12.5 at its root or just ahead on its way, or sniffing) \| `Swim` \| `Stunned` |
| `action` | `Stare` \| `ReachIn` \| `LookAway` \| `FadeOut` \| `FadeIn` \| `Jumpscare` \| null |
| `actionStartedAt` | game time the action began |
| `fade` | 0..1 visible |

The snapshot also names the player it is after (`getTarget()`, the co-op packet's target): its target, else, while it
plays a Peek, a Glimpse or a Shadow, that beat's player (it watches them: the rig's head follows them, and the
"Followed" hint reads it). The brain's own target (chases, sightings, the pacing) is not changed by it.

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
- **The puppet's pose and eye** (the web's clients; Roblox replicates the server's attributes): the same rules as the
  host's, section 2. It hunches by the same head-room rule, its look-ahead read along the host's positions ahead of
  the one drawn, then along its heading; its eye is the rig's for that pose, 0.6 forward.
- **Events to everyone:** a teleport's warning (the flicker and the hiss on every page; the torch stutter only on the
  target's page), the grunt, a give-up.
- **The beats** travel as Patrol in the world packet and exactly (Peek, Glimpse, Shadow, PassBy) on the state message.
- **The director** reads every player (each one's menace, quiet spell and time left alone); in co-op its attention
  goes to a player left alone for 75 s first (section 15.2).
- **Events to their target only:** a reveal scare, a stare's sting.
- **Fake-outs** play only for the one who opened the spot; the spot is then safe on every page.
- **A pull-out** goes from the puller to the host, then to the hider's page, which throws them out; the host's brain
  is told it was a pull.
- **Catches of a remote player:** run on the host; the victim's page plays the moment and applies the outcome.

---

## 14. Fairness rules (asserted by `web/tools/creature-sim.mjs`)

1. Never faster than a sprinting player (19) outside Scripted, on Standard and Nightmare.
2. Never teleports into anyone's view, nor within 12 studs of anyone. Every teleport (the approach too):
   - is warned 1.6 s ahead;
   - is 12..24 studs of walking from its target at planning (Behind, Side); 24..70 past their lead Ahead of a target
     on the move (the cut-off); 45..80 for the director's approach (past their lead, and only ahead, for a target on
     the move).
3. Never catches through a wall: every catch has a clear chest-to-chest line (a ReachIn's own hiding spot aside).
4. The first teleport on a floor comes no sooner than the floor's grace + 45 s.
5. A chase ends after 4 [6] s without a sight once it has run to the last place it saw them and on (its pursuit; then
   Search), or at 12 [45] s whatever happens (it fades away); every fresh chase winds up 1.5 [0.7] s first and catches
   nobody while it does.
6. A LookAway lets a hider slip out and escape by breaking the line; stepping out under its nose is a catch; the
   ReachIn comes at 30 s; a teammate's pull-out is no catch.
7. The pool: the 20 s grace, a freestyle swimmer outswims it, every lunge is telegraphed, the 15 s retreat after a
   grab, and it never climbs out.
8. Determinism:
   - the same run gives the same path;
   - 20 and 144 fps render loops give identical decisions and positions;
   - no NaN, no stuck state, no state or warp held past its bound in a soak of every level.
9. The presence layer:
   - every beat starts with every player 25 or more walked from its stand points, a hiding spot within 25 walked of the
     player it plays to and that player not cornered (two ways out of their room); a beat is never a chase on its own
     (only a player within 12, or a stare);
   - a hint is never a player's own position (25..55 walked from them), never in anyone's view;
   - the director's caps: a hint no sooner than 8 s after the last, a beat no sooner than 35 [25] s, an approach no
     sooner than 25 s, a quiet spell of 40 [35] s on a player after an encounter and 45 [40] s after a catch, the first
     beat no sooner than 20 s into a floor; in co-op a player left alone 75 s goes first.

---

## 15. The director (a second brain above its own)

The director knows where the players are; the Creature itself still knows only what its senses tell it. The director
acts only through honest means: where its patrol goes, a search hint, the warned approach teleport, a presence beat,
and backing off. Numbers: `CreatureConfig.Presence.Director`.

### 15.1 Menace

Once a second (Interval **1**), for every hunted player on its level (not ignored), it reads:
- **walk:** the walking distance (its nav) from its feet to theirs;
- **sees:** the player sees it: it is shown (fade ≥ 0.5), within **80** of their eye, inside **50°** of their look
  (flat bearing; the screen's half width), with a clear line to its eye or its root;
- **chased:** it chases them now (WallChase, they are its target).

Each player keeps a **menace** (0..1), a **quiet spell** (until when) and the time they were last **pressured**:
- at a level's activation (and a run's start) everyone starts at **0.5**, pressured now, no quiet spell;
- **sees** or **chased**: an encounter (below);
- else **walk ≤ 70**: pressured now (menace held);
- else menace rises by `1 / 55 [40]` a second (full after 55 [40] s far).

**An encounter** with a player: menace 0, pressured now, and a quiet spell to at least now + **40 [35]** s (**45 [40]**
after a catch of them). Encounters: sees or chased (above); a chase on them starting or ending (its target); a catch
of them; a beat played to them ending once it **reached** them (they saw it, or it came within **30** walked of them,
read once a second with the menace; a beat that never reached them is no encounter: their menace stands); a
respawn's grace given to them.

### 15.2 Focus and lean

Of the players it may turn to (hunted, on its level, not hiding, not in a duct), out of their quiet spell:
- with two or more such players, one left alone (not pressured) for **75** s or more goes first (the longest alone);
- else the highest menace; ties: the one left alone longest.

That player is the **focus** (none when everyone is in a quiet spell). The patrol **leans** toward the focus, or, with
no focus, toward the highest menace among the players it may turn to (section 6.3).

### 15.3 Orders

Once a second, after the menace update, only while it patrols (state Patrol, no warp), may hunt, sees nobody and heard
nothing this tick, the focus player gets an order:
1. **A beat** when their menace is **0.5** or more, they are **30..140** walked away and the beats' cooldown is over
   (the first **20** s after an activation, then **35 [25]** s after a beat started, or **6** s after no beat fitted):
   the beat plan (section 16); none fitting, nothing this second.
2. **Else a search hint** when their menace is **0.2** or more, they are more than **100** walked away and the hints'
   cooldown is over (**8** s after the last try):
   - the hint: of the floor points (the 5-stud lattice) within 6 of their floor and **15..55** horizontally from their
     feet, ahead of their way first (the cosine of their travel, else their look, with the way to the point ≥ **0.4**),
     then nearest the Creature: the first of the first **14** that is **30..55** walked from them, reachable for it now,
     and in nobody's view (section 7.1's rule);
   - when the walk from it to the hint is over **90**, the **approach teleport** comes first, if its cooldown (**25** s)
     is over, the floor's grace (20 [12] s from its activation) is over, it is not within 25 s of a catch or a fall
     and the game does not block teleports: of the teleport
     candidates within 6 of their floor, 12..80 horizontally from them, ahead of their way first then nearest the
     middle of 45..80, the first **60** are asked; those **45..80** walked from them, 12 or more from everyone and in
     nobody's view pass; a seeded pick among the first three. For a target on the move (their speed above 2) only
     candidates **ahead** of their way count (behind a runner it would form where they have already gone), and both
     bands lie past their lead (section 7.2: 12..80 + lead horizontally, 45..80 + lead walked). It forms **facing
     away** from them. The warp is the
     teleport's (section 7.1: FadeOut, Hidden, the 1.6 s Warning with the lights, the hiss and the target's torch,
     FadeIn), with no stare; it patrols on, to the hint.
   - Patrol walks to the hint (section 6.3).

### 15.4 Backing off

After an encounter (a chase, a catch, a long stare, a beat) it backs off:
- **the quiet spell** on that player (15.1): no hint, no beat on them;
- **the breather:** a Search that followed a chase (or a watched hiding spot) is over → the pacing's Relax (section 4)
  and Patrol **withdrawing** (section 6.3);
- a catch: the pacing's catch cooldown and Relax (section 9), and the withdraw.

The result is a leash: most of the time it is 35 to 90 studs walked from the nearest player, close enough to be heard
and glimpsed, and the tension goes in waves (build, peak, release).

---

## 16. Presence beats

Choreography so the player **sees** it without a fight starting: Peek, Glimpse, Shadow, PassBy, each its own state.
The director plans one for its focus player (`beats.js`), in a seeded order by weight (PassBy **0.2**, Peek **0.3**,
Glimpse **0.3**, Shadow **0.2**; drawn without putting back); the first whose geometry fits plays. Numbers:
`CreatureConfig.Presence.Beats`.

**Safe and readable, every beat:**
- the player is not **cornered**: their room has two or more open ways out;
- a hiding spot's front within **25** walked of them;
- every stand point of the beat **25** or more walked from every player;
- it can walk to the beat's start within **100** walked, and it gets there within **20** s or the beat is off.

**While a beat plays** (not a pass-by) only a sighting within **12**, or a stare (section 3.3), starts a chase; noises
do not interrupt it. A player who comes within **18** of it (straight, root to root) ends the beat and it
**withdraws** (Patrol, withdrawing: section 6.3), so a player walking on toward a peek or a crossing
is not run into catch reach. A beat ends when its player stops playing, hides or enters a duct. It ends in Patrol.

The candidate points are the floor lattice (every 5 studs, within 6 of the player's floor), nearest the Creature
first; only the first **10** are walked (pathfinding asked).

### 16.1 Peek

- **The stand point S:** **30..70** horizontally from the player, within **45°** of their way (their travel, else their
  look), with a clear line from their eye to its head there (within 80).
- **The corner W:** **5..14** from S, at least as far from the player as S less 2, where nobody sees its head or chest
  (any facing), at most **20** walked from S.
- **It plays:** walks to W at **9**; steps out to S at **7** (within 2, or as far as it got in 6 s); holds **U(1.5, 3)** s
  facing the player; walks back to W; done.

### 16.2 Glimpse

- **The crossing J:** **30..70** horizontally ahead (within **35°** of their way), its head in their view (a clear line
  within 80).
- **Its ends:** A and B, **6..16** from J, out of everyone's sight; A on the player's left of the line from them to J,
  B on their right (each more than 3 off it); A and B on opposite sides of J (the cosine of the two ways from J under
  −0.5); each at most **20** walked from J.
- **It plays:** walks to A at **9**; crosses A → J → B at **12**; done.

### 16.3 Shadow

- **When:** the player is moving faster than **3** and no faster than **14** (a sprinter, 19, would leave its 11
  behind, never seeing it; for them the beats ahead fit), it is **30..70** walked from them, behind them (the
  cosine of their travel with the way to it under −0.3), and not in their view facing them.
- **It plays** for **U(15, 25)** s, re-planned every 0.5 s:
  - their look within **25°** of its head with a clear line (within 80): it **freezes**, facing them (a long look is
    the stare, section 3.3, that starts a chase);
  - closer than **30** walked: it stands, facing them;
  - else it walks to the point **40** back along their trail (their root every 0.5 s over 15 s) at their pace, never
    under 7 nor over **11**; farther than **50** walked, at 11.
- **Then:** Patrol, withdrawing.

### 16.4 Pass-by

- **Only for a player moving no faster than 6** (working an objective, crouching, standing, hidden): a player on the run
  would run into it; for them the director's other beats (ahead of them, in view) fit.
- **The way through:** a point P **18..28** horizontally from the player and **20** or more walked from them, at most
  **128** walked from it; then a point E **20..40** from P (at most 50 walked), on the far side from where it comes
  (the cosine of the way P → E with the way it comes to P over 0.2), **30** or more from the player; its whole walk
  (to P, then to E) keeps **20** walked off them (held by the bound (walk(player, X) + walk(player, Y) − walk(X, Y)) / 2
  for each leg X → Y).
- **It plays:** walks to P, then to E, at **7**, with its own senses throughout (a sighting of a noticed player starts a
  chase): hiding, or keeping out of its cone in the dark, and watching it go past is the answer.

---

## 17. Detection

Numbers: `CreatureConfig.Presence.Detection` (and NoiseConfig for the noises).

### 17.1 The torch's glow

Every **0.5** s, for each hunted player with their torch on, not hiding, not in a duct, whom it does not see this tick:
- **the lit spot:** along their look from their eye, the first surface within **30** (its collision), else 30 along;
  pulled 0.3 back toward them;
- seen when the spot is within **90** of its eye (× the difficulty's sight multiplier), inside its view cone (55°,
  flat bearing) and the line is clear;
- seen, it is heard like a **Normal** noise of that player at the spot (strength 1): it goes to look (InvestigateNoise).

### 17.2 Standing still in the dark

A player with their torch off, not in a lit pool and not moving (speed 2 or less) is seen at **0.5 ×** the range
(section 3.2): 20 → 10 (crouched 7.5).

### 17.3 Noticing

Every brain tick, each player's **noticing** (0..1):
- in sight: + `dt / (2 [1.8] × share)` where `share = clamp01((distance − 8) / (70 × sight multiplier − 8))`; within
  **8** at once (1);
- out of sight: − **0.6** a second.

A sighting starts a chase (rows 11, 15, 18 of the table) only of a player it has **noticed** (noticing 1), except while
it chases or watches a hiding spot already. A glimpse across its cone far off does not start a chase; staying in its
sight does. Its stare after a teleport notices its target (section 6.8).

### 17.4 Noises

Sprinting (60, High) and landings (26, 60 after a hard fall) carry farther than walking (22); hiding-spot doors (8 /
14), **items taken** (Pickup, 20, Normal: a fuse, the keys, a battery, a flask) and the breaker (110) are noises it
investigates (section 3.1).

---

## 18. Chases with teeth

The pace stays 16.5 [18.5 capped]: a sprinting player (19) is faster. Numbers: `CreatureConfig.Presence.Chase` and
`.Teleport`.

### 18.1 The wind-up

A chase entered from anything but HidingResponse: the Screech, and it holds **1.5 [0.7]** s facing the target before
it runs; **2.8 [2]** s when the target stands within **20** (straight) as it starts: a player met round a corner gets
the time to turn. It screeches, it does not reach: no catch until the wind-up is over (a player who bolts past it is
still in its path, a few steps ahead); from then on catches are tried every tick.

### 18.2 The pursuit

Each sighting of the target while they move faster than 2 remembers their travel (flat, unit). Unseen, it runs to the
last place it saw them; there, once per sighting, when it remembers their travel, it runs on: of the floor lattice
within 6 of that place's floor and within **18 [24]** (0.6 × the pursuit) of the point **30 [40]** along their travel,
the best (score: along − 0.5 × the distance off the point; along more than 5) of the first 8 by score that it can walk
to within 45 [60]; that point becomes the memory. Reached with nobody seen, the chase is done (Search there).

### 18.3 The cap

It loses its quarry after **4 [6]** s without a sight (not counting its run to the last place it saw them and its
pursuit) and gives up at **12 [45]** s whatever happens; then the hunt eases off for the breather, **35 [15]** s at
least (the pacing's Relax, section 4; also after a catch). On Standard a chase is a short, sharp scare a player with
stamina can outrun (a sprint lasts about 14 s) and a spent one survives by breaking its line of sight or hiding; on
Nightmare it lasts 45 s, so a player must break its line of sight **and** get out of its path or hide, not only outrun
it down a straight corridor.

### 18.4 The cut-off teleport

- **Ahead first:** a teleport tries Ahead of its target's way first **0.75 [1]** of the time (section 7.2; on Nightmare
  always: formed behind a sprinter it is left behind before its stalk can see them), and a target on
  the move may be cut off **24..70** walked ahead of where they will be when it may appear (past their lead, section
  7.2; out of their view, with the full 1.6 s warning): they run on toward
  the flicker and the hiss. The answer to the warning is to turn, sidestep or hide.
- **After its stare** it has noticed its target when it can see their eye within **40 [50]**; in the stalk a sighting
  of a noticed player within **40 [50]** starts the chase.
- The catch, the downed state and the lives rules are unchanged.

---

## 19. Being heard

Its footfalls (the animator's plants, heard to 70), its breath and the mask's rattle (CreatureRattle while it stalks or
plays a beat within **45**, heard to 55) always play from where it really is; the heartbeat and breathing's panic floor
follows its real distance within **45** (section 11). Numbers: `CreatureConfig.Presence.Audio`.

---

## 20. The presence report (`web/tools/presence-sim.mjs`)

Scripted players on the real floors (the Basement, the Hallways, the interim Auditorium), 12 seeds each (the objective
player's downs on 36: on 12 a floor's mean moves by about 0.25 between seed sets), Standard and Nightmare, alone and in
pairs (each player catchable), 8 minutes per floor, each floor started as the game starts it (the start hold):
- **the objective player:** the floor's objective targets at a sprint whenever it has stamina, torch always on, never
  hides; chased it runs (a point 30..60 off, far from it and round a corner from it where there is one, whose way does
  not run back toward it over its first 25 studs; a new one every 3 s, never one that runs back toward it more than the
  way it is on); seeing it within 45 it turns away; hearing it within 25 it looks;
- **the careful player:** the same targets at a walk with looks back; crouched with the torch off when it hears it near;
  hides (out of its sight, by a way that keeps 12 off it; with no spot it runs, upright, to break the line, or, only
  heard close and unseen, keeps still in the dark) when warned, chased, seen or closed in on; slips out of a watched
  spot during a LookAway; a spot refuses it as the game does (section 8: chased with a clear line from its eye), so it
  runs on to break the line first;
- **both** notice a teleport's warning aimed at them or within 40 (the torch, the hiss, the lights): as it forms
  (1.8 s after the cue began) they look at the warned spot for up to 1.5 s, still going their way.

It measures sightings (it shown, within 80, inside 50° of their look, a clear line; each player's longest stretch
without one is reported, not a target: the careful player's own play keeps it from seeing it), the walking distance once a
second, pass-bys (within 30 walked with no chase), chases (one taken up again out of its search or hiding watch within
20 s is the same chase) and how they ended, presence events (a sighting, a pass-by or a chase) and downs; and a
teleport test: a straight-line sprinter and a hider who breaks the line and hides within 8 s.

**Targets (asserted on the Basement and the Hallways):**

| | Standard solo | Standard pair | Nightmare solo | Nightmare pair |
|---|---|---|---|---|
| first presence event within | 75 s | 75 s | 75 s | 75 s |
| presence events: median gap / longest | 75 / 150 s | 75 / 150 s | 75 / 150 s | 75 / 150 s |
| within 90 walked of the nearest player | ≥ 50 % | ≥ 50 % | ≥ 50 % | ≥ 50 % |
| within 20 walked, no chase, no beat | < 5 % | < 5 % | < 6 % | < 6 % |
| chases per 8-minute floor | 2..5 | 2..7 | 2..8 | 2..9 |
| objective player's downs per floor (each, 36 seeds) | 0.3..0.8 | 0.15..0.8 | 0.7..5 | 0.5..4 |
| objective player: floors with 2 or more downs (each) | ≤ 20 % | ≤ 20 % | | |
| careful player: floors with a down | < 25 % | < 35 % | < 40 % | < 40 % |

Standard solo is the measure of the game: "not too hard" for a careless player (one who sprints everywhere with the
torch on and never hides) is caught 0.3 to 0.8 times a floor, and spends both the get-up and the respawn on at most
one floor in five. The others differ only where it cannot apply as it is: a pair has two quarries (1..3.5
chases a player), each careless player of a pair is caught no more often than alone (measured lower: the two share its
chases), and a pair's floor counts a down of either player for the careful one; Nightmare keeps Standard's presence (it adds danger, not frequency),
closes in and starts more chases (faster, keener senses; a chased player hides only once out of its sight, section 8), and its chase runs at the cap (18.5), only just slower than a sprint (19), with one get-up
a floor, so a player who never hides is meant to lose a Nightmare floor: its fairness is the careful player's and the
hider's.

And on both difficulties: a straight-line sprinter is caught after a teleport (the one asked for: the director's
approaches, which form facing away with no stare, are not it) at least once; a player who breaks the
line and hides within 8 s is never caught by the teleport's encounter; never faster than a sprinting player.

---

## 21. Map data it reads (the tunnel maps)

| Data | Use |
|---|---|
| Entities tagged `Hideable` + `HideKind` | hiding spots (ExitAnchor / HideAnchor / PeekAnchor, Hide prompt) |
| `layoutDoors[].clearance` / `crawlOnly`, `zoneGraph.edges[].clearance` / `crawlOnly` | shut portals (crawl-only or under 9), hunching (under 12.5) |
| `rooms[].height`, kind `Crawlway` / `Chase` | hunching; no floor |
| `meta.teleportPoints[level]` `{pos, facings, region, zone}` | teleport candidates (`zone` names the room; its facing is toward the target, `facings` unused) |
| `patrolLoops`, PatrolWaypoint anchors | the Stalk's loops (derived from the rooms when absent) |
| CreatureSpawn anchor | its start (ignored outside the main walkable component) |
| `meta.creature` `height`, `hunchedHeight`, `eyeHeightAboveRoot` (else `eyeHeight`), `reach` | the metrics in section 2 |
| `basins` | the pool (its water is no floor for routes: section 5) |
| probe grids (base irradiance) | "lit" |
