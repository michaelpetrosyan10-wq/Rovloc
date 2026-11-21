# Monster v3 ("the Lurker"): implementation spec

Written 16 Nov 2026 for the builders of task #45. Design source: `docs/design/research/monster.md` section 3.
Bound to the code at the commit whose `web/build/world.json` was baked on Nov 16 18:58.
**Revised 16 Nov 2026** after the player's-lens review (`scratchpad/mv3/review-player.md`, findings P1 to P22). Part
12 lists every finding, accepted or rejected, and where the text changed. The stage 1 builder's one-page brief is
`scratchpad/mv3/stage1-brief.md`.

How to read the numbers. Every number carries its source:
- **[R 3.x]** `docs/design/research/monster.md`, that section.
- **[C]** a number that exists today in `src/ReplicatedStorage/Shared/Config/CreatureConfig.luau` (or the file named).
- **[M x]** `docs/MONSTER.md`, that section.
- **[W]** read from `web/build/world.json` (the baked world).
- **[P]** my own proposal. Every [P] is a starting value for the simulation to confirm, not a measured fact. A
  proposal of the review that this revision adopted is also marked [P] (part 12 names which).
- **[G]** `src/ReplicatedStorage/Shared/Config/GameConfig.luau`. **[Q]** `docs/design/requirements.md` section 6.

Nothing in this spec was run. No build, test or simulation was started for it. Every "today it does X" below was
read in the file named.

Three findings that change the research's plan (read these first):

1. **The "little holes" are crawlways, not ducts.** [W] The baked world has 33 rooms of kind `Crawlway`
   (Basement 11, Hallways 18, Auditorium 4): straight culverts 4 wide, 8 to 18 long, 4.8 high, each with exactly two
   crawl-only doorways (clearance 4.3, width 3) into walkable rooms; 66 such doorways in all. The duct network that
   `web/src/creature/ventgraph.js` reads exists on one floor only: the Hallways, 4 nodes and 2 grates. So "he uses
   the vents and low holes" is built on the **floor nav** (`web/src/creature/nav.js`, which today drops `Crawlway`
   rooms and crawl-only portals) first, and on `ventgraph.js` second. Section 5.4.
2. **Continuous sounds would drown the cadence.** Today his footfalls play whenever he walks and are tuned to be
   heard at 80 studs (`CreatureConfig.Footfalls.HeardTo` [C]), and `web/src/game/mechanics/monsterFx.js` plays
   `CreatureRattle` every U(4.5, 8) s whenever he is within 45 studs in any stalking state. With the research's leash
   of 25 to 55 walked he would be audible nearly all the time, and "one interaction every 30 s, 60 s when crouching"
   could not be told from the background. The spec adds a **quiet lurk** (he stands still, or creeps with soft
   steps, between interactions) and makes the rattle a director-issued sound. Section 3.6. This is [P]; the research
   does not cover it.
3. **Hearing must not double-count.** Today a heard noise sends him to investigate (`brain.js decide`: "heard a
   noise, outside InvestigateNoise and Search -> InvestigateNoise"). A sprint is heard at 60 [M 3.1]. With a 25 to 55
   leash he would hear every sprint and every objective hold, walk to the player and start a chase each time. In v3
   the **clock is his answer to continuous noise**; continuous noise pulls him in only while a chase token exists.
   Section 5.3. [P], derived from research 3.5 ("a chase needs a token and a trigger").

---

## 1. For the player

1. He is around much more. Sprint and something happens about every 15 to 20 seconds (counted the way a person
   really sprints: until the stamina runs out, then a walk). Walk: about every 30. Crouch: about once a minute. Stand
   still and silent, or hide: less often still. Now and then he goes quiet for longer, so it never feels like a
   timer.
2. Most of these are not attacks. You hear his heavy steps behind a wall, his feet running somewhere close, his breath
   on the other side of a locker row, a locker he is opening in the next room. You see his mask lean out of a
   doorway, him crossing ahead, or him standing at the dark end of a corridor, watching.
3. He stays in a radius around you (about 25 to 55 studs of walking on Standard) instead of wandering the whole floor.
4. Between these moments he is quiet on purpose, and so is your heartbeat: it starts only when he is really close
   (15 studs) or while something is happening. When you hear him, it is because he let you; when you see him move,
   you also hear him.
5. Chases are rare and on their own budget: on Standard about one every two and a half minutes for a player alone
   (the budget refills faster with more players: about one every 80 seconds for four). The same player is not the
   target of two chases running while a teammate counts.
6. When he sees you and has no chase "saved up", he screeches, the chase music stabs, he takes two steps at you,
   and backs away. A real scare, not a run.
7. After a big scare (a chase or that screech) he leaves you alone for 25 to 40 seconds.
8. Make a loud noise and he answers: a few heavy steps toward it. Throw a flask far off and he drifts to that side.
9. Hide right after he shows himself and he usually comes past your hiding spot. A sniff he was not led to by you
   never kills you.
10. A split squad shares him in turns: he stays with one group for about 45 seconds, then goes to the other.
11. He crawls through the low holes (the culverts) and, where a floor has one, the air duct (the second build).
    He is slower in there than you are, and you always hear him.
12. Everything he does can be answered: stop and listen, change your route, look back, hide, hold your breath,
    throw a flask. Hiding, backing off, crouching and switching the torch off never start a chase by themselves.
13. It is not harder than today: a careless sprinter is caught no more often per floor than in the game that ships
    now, and a careful player finishes a floor in about the same time. He speaks real words as soon as the recorded
    voices exist (the game is ready for them from the first build); until then he does not fake it.
14. On the beta a setting "Monster activity: Less / Normal / More" lets you tell us which pace is right.

---

## 2. Config

### 2.1 Conventions kept

`CreatureConfig.luau` today: frozen tables, Standard numbers, `pair(standard, nightmare)` for a number per difficulty,
`exportMeta()` returning `plain(...)` copies, read on the website by `presenceConfig(meta, difficulty)` in
`web/src/creature/presence.js` (its `resolve()` turns every `{Standard, Nightmare}` pair into one number).

Changes to the conventions:

- Add beside `pair`:
  ```lua
  -- A number per difficulty, Easy included. Easy is not selectable yet (Enums.Difficulty is Standard | Nightmare):
  -- its numbers ride here so that adding it later changes no rule.
  local function tri(easy: number, standard: number, nightmare: number): { [string]: number }
  	return table.freeze({ Easy = easy, Standard = standard, Nightmare = nightmare })
  end
  ```
- `presence.js`: `DIFFICULTY_KEYS = {'Easy', 'Standard', 'Nightmare'}`; `isPair(v)` is true for an object of 2 or 3
  keys that are all difficulty keys; `resolve(value, difficulty)` returns `value[difficulty] ?? value.Standard` (so
  an old pair resolves Easy to its Standard number). `presenceConfig` accepts `'Easy'`. Add
  `lurkConfig(meta, difficulty)` returning `resolve(meta.creatureConfig.Lurk, difficulty)`.
- `exportMeta()` gains `Lurk = plain(CreatureConfig.Lurk)`.
- Easy today: `Enums.Difficulty` (`src/ReplicatedStorage/Shared/Enums.luau` line 682) and `DifficultyConfig.luau`
  have no Easy. Until they do, "Easy" exists only as a column of `Lurk` and of the three changed `Presence` numbers;
  a run asked for with `Easy` uses Standard's `DifficultyConfig` row (speeds, senses) with the Easy lurk numbers. The
  sims run it; the lobby does not offer it. Open question 1.

**Decision on cadence per difficulty.** The interaction gaps are the same on Easy, Standard and Nightmare.
Difficulty changes danger (leash, chase budget, chase length, gates), never how often he makes himself felt.
Reason: [M 20] already states it for Nightmare ("Nightmare keeps Standard's presence (it adds danger, not
frequency)"), and the cadence is what the player asked for by name.

### 2.2 The table to add

Add after `CreatureConfig.Presence`. Comments are part of the file.

```lua
-- Monster v3, the Lurker (docs/MONSTER.md 22-27; design: docs/design/research/monster.md 3). A director above the
-- brain pays every player "interactions" on a clock driven by how they move, keeps him on a leash round them, backs
-- him off a player who has had enough (strain), and gates chases with a team token. The pure part is
-- Shared/Rules/LurkRules; the geometry is the runtime's. tri(easy, standard, nightmare).
CreatureConfig.Lurk = table.freeze({
	Interval = 1, -- the director reads the players and steps LurkRules this often (seconds)

	-- 3.1 A: the interaction clock. due += dt x LullComp x Activity / Gap[class]; an interaction is owed at due >= theta.
	Clock = table.freeze({
		Gap = table.freeze({ -- the mean seconds between interactions (lulls included) for a player who keeps to one class
			Sprint = 14, -- speed >= SprintSpeed. Tuned so a stamina-limited sprinter (63 % sprint, 37 % walk) measures
			-- 15..20 s: 1 / (0.63 / 14 + 0.37 / 30) = 17.4 s (2.3)
			Walk = 30, -- WalkSpeed <= speed < SprintSpeed
			Work = 40, -- upright, slower than WalkSpeed, an ObjectiveWork pulse of theirs within WorkWindow
			Still = 75, -- upright, slower than WalkSpeed, no Work: standing still and quiet is paid like hiding
			Crouch = 60, -- MoveState Crouching, slower than WalkSpeed
			Duct = 40, -- in a duct or a crawlway (vent interactions only)
			Hiding = 75, -- MoveState Hiding (pass-by and sniff first)
		}),
		SprintSpeed = 15, -- studs/s; NoiseConfig.SpeedTiers' Sprint tier
		WalkSpeed = 7.5, -- NoiseConfig.SpeedTiers' Walk tier
		WorkWindow = 2, -- seconds: an ObjectiveWork pulse from them this recently makes an upright slow player Work
		MixTau = 2.5, -- seconds: the rate follows the class with this time constant (a 5 s window's mean age)
		ThetaMin = 0.6, -- an interaction fires at due >= theta, theta uniform in ThetaMin..ThetaMax, redrawn after each
		ThetaMax = 1.4,
		LullEveryMin = 5, -- after every LullEveryMin..LullEveryMax interactions (drawn per player, theta stream)...
		LullEveryMax = 7,
		LullScale = 2, -- ...the next theta is multiplied by this: a lull
		LullComp = 7 / 6, -- the clock runs this much faster so the mean gap, lulls included, is Gap (mean theta 7/6)
		Activity = table.freeze({ Less = 1.4, Normal = 1, More = 0.75 }), -- the beta's setting: every Gap x this
		Carry = 0.5, -- after an interaction: due = min(due - theta, Carry), never below 0
		HeardShare = 0.6, -- a teammate farther than Coop.GroupRange from the target who also perceived it: due -= this
		HeardCost = 0.08, -- a player reached by hearing only pays min(Types[type].Cost, this) in strain
		FirstHeard = tri(25, 20, 20), -- the first interaction on a floor: owed this long after its activation
		FirstSeen = tri(50, 40, 40), -- no seen or close interaction sooner than this after a floor's activation
		SamePlayer = 10, -- no interaction starts that would reach a player within this of their last one
		Team = 6, -- never two interactions starting within this, squad-wide
		TeamBody = 15, -- never two body interactions starting within this, squad-wide
		Retry = 6, -- a type whose plan found no place, or that reached nobody: not tried again on that player for this
		Fallback = 3, -- owed this long with no plan fitting: far or running steps from where he is, or the approach
		PlanAhead = 6, -- a body interaction is planned this many seconds of clock early (due + rate x this >= theta),
		-- so his walk to its start overlaps the wait; it still starts only at due >= theta
		TellHolds = 12, -- no C3 and no approach aimed at a player within this after a heard interaction reached them
		WarnMax = 2, -- at most this many teleport warnings (C3 + approach) aimed at one player...
		WarnWindow = 180, -- ...in any this many seconds
		HideAfter = 20, -- a player who gets into a spot within this after an interaction reached them...
		HideOwedMin = 12, -- ...is owed one HideOwedMin..HideOwedMax s after getting in (not backstage)
		HideOwedMax = 20,
		LumpNear = 12, -- a noise lumps its maker's clock only when it sounds within this of them (a thrown flask does not)
		Lumps = table.freeze({ -- a player's own loud noise adds this to their due (NoiseKind -> lump)
			DoorSlam = 0.25,
			FlaskShatter = 0.25,
			Gasp = 0.25,
			Slide = 0.25,
			HardLanding = 0.25,
			ObjectiveClunk = 0.35,
			GrateKick = 0.35,
			FloorDebris = 0.35,
			TrapSnap = 0.35,
			GeneratorStart = 0.5,
		}),
	}),

	-- 3.1 B: strain (0..1), the pressure a player has just had.
	Strain = table.freeze({
		SeenRate = 0.04, -- per second while the player sees him
		NearRate = 0.06, -- per second while he is within NearWalk walked of them
		NearWalk = 15,
		ChaseRate = 0.05, -- per second while he chases them
		ChaseEntry = 0.5, -- a chase on them starting
		Catch = 1, -- a catch of them: strain is set to this
		DecayDelay = 5, -- nothing raised it for this long: it falls
		Decay = 0.02, -- per second
		CloseBelow = tri(0.4, 0.45, 0.55), -- tier 2 (close) interactions only under this
		SeenBelow = tri(0.6, 0.65, 0.75), -- tier 1 (seen) interactions only under this
		BackOff = 0.8, -- at or over this: backstage
		BackstageMin = 25, -- backstage lasts uniform BackstageMin..BackstageMax seconds...
		BackstageMax = 40,
		Release = 0.35, -- ...and until strain is at or under this
		BackstageRate = 0.5, -- a backstage player's clock runs at this share
		BackstageWalk = 60, -- he keeps this far walked from a backstage player (or is in a duct)
		FloorStart = 0.35, -- a floor's activation: strain is cut to at most this
	}),

	-- 3.2: the catalogue. Tier 0 heard, 1 seen, 2 close. Cost: strain added to each player it reached. Weight: the
	-- director's base weight. Cooldown: seconds before the same type on the same player. Body: he must be placed for
	-- it (one body interaction at a time). Setup: seconds he may take to reach its start. Min/Max: its length.
	Types = table.freeze({
		H1 = table.freeze({ Tier = 0, Cost = 0.04, Weight = 10, Cooldown = 20, Body = false, Setup = 8, Min = 4, Max = 6 }),
		H1b = table.freeze({ Tier = 0, Cost = 0.05, Weight = 8, Cooldown = 20, Body = false, Setup = 8, Min = 2, Max = 3 }),
		H2 = table.freeze({ Tier = 0, Cost = 0.07, Weight = 8, Cooldown = 30, Body = true, Setup = 8, Min = 2, Max = 3 }),
		H3 = table.freeze({ Tier = 0, Cost = 0.08, Weight = 8, Cooldown = 40, Body = true, Setup = 8, Min = 3, Max = 6 }),
		H4 = table.freeze({ Tier = 0, Cost = 0.06, Weight = 8, Cooldown = 30, Body = true, Setup = 8, Min = 1, Max = 2 }),
		H5 = table.freeze({ Tier = 0, Cost = 0.08, Weight = 4, Cooldown = 120, Body = true, Setup = 8, Min = 1, Max = 3 }),
		S1 = table.freeze({ Tier = 1, Cost = 0.12, Weight = 8, Cooldown = 45, Body = true, Setup = 20, Min = 1, Max = 2 }),
		S2 = table.freeze({ Tier = 1, Cost = 0.15, Weight = 8, Cooldown = 60, Body = true, Setup = 20, Min = 1.5, Max = 3 }),
		S3 = table.freeze({ Tier = 1, Cost = 0.15, Weight = 6, Cooldown = 60, Body = true, Setup = 20, Min = 2, Max = 6 }),
		S4 = table.freeze({ Tier = 1, Cost = 0.12, Weight = 5, Cooldown = 60, Body = true, Setup = 20, Min = 1.5, Max = 3 }),
		C1 = table.freeze({ Tier = 2, Cost = 0.2, Weight = 5, Cooldown = 90, Body = true, Setup = 20, Min = 10, Max = 20 }),
		C2 = table.freeze({ Tier = 2, Cost = 0.25, Weight = 5, Cooldown = 90, Body = true, Setup = 20, Min = 6, Max = 12 }),
		C3 = table.freeze({ Tier = 2, Cost = 0.3, Weight = 5, Cooldown = 60, Body = true, Setup = 20, Min = 1.6, Max = 11.6 }),
		C4 = table.freeze({ Tier = 2, Cost = 0.3, Weight = 3, Cooldown = 60, Body = true, Setup = 20, Min = 4, Max = 16 }),
		F = table.freeze({ Tier = 0, Cost = 0.05, Weight = 2, Cooldown = 60, Body = false, Setup = 8, Min = 1.5, Max = 2.5 }),
		-- not drawn by weight: the director's fallback move, and what a chase trigger becomes without a token
		Approach = table.freeze({ Tier = 0, Cost = 0.15, Weight = 0, Cooldown = 25, Body = true, Setup = 0, Min = 1.6, Max = 1.6 }),
		NearMiss = table.freeze({ Tier = 2, Cost = 0.35, Weight = 0, Cooldown = 0, Body = true, Setup = 0, Min = 2, Max = 6 }),
		-- the answer to a loud noise when no token is held (5.3): a few heavy steps toward it
		Reply = table.freeze({ Tier = 0, Cost = 0.04, Weight = 0, Cooldown = 0, Body = false, Setup = 0, Min = 1.5, Max = 3 }),
		-- records only (never planned): a chase's start, and anything of his perceived outside an interaction (4.0)
		X = table.freeze({ Tier = 3, Cost = 0, Weight = 0, Cooldown = 0, Body = true, Setup = 0, Min = 0, Max = 0 }),
		Stray = table.freeze({ Tier = 0, Cost = 0, Weight = 0, Cooldown = 0, Body = false, Setup = 0, Min = 0, Max = 0 }),
	}),
	-- 3.3: weights. base x Fit (the types that suit how the player moves) x progress x CloseScale.
	Fit = 2,
	FitOf = table.freeze({
		Sprint = table.freeze({ "S1", "S3", "H1b" }),
		Walk = table.freeze({ "C1", "S2", "H2" }),
		Work = table.freeze({ "C2", "H2", "H3", "C4" }),
		Still = table.freeze({ "C2", "H2", "H3", "C4" }),
		Crouch = table.freeze({ "C2", "H2", "H3", "C4" }),
		Hiding = table.freeze({ "C2", "C4" }),
	}),
	FirstHoleWeight = 3, -- S4's weight x this for a player who has not yet seen an S4 this run (stage 2)
	-- the only types a player in this class may get
	Only = table.freeze({
		Duct = table.freeze({ "H3", "H5", "S4" }),
		Hiding = table.freeze({ "C2", "C4", "H1", "H2" }),
	}),
	ProgressClose = 0.5, -- tier 2 weights x (ProgressClose + p), p = the floor's objectives done / total
	ProgressHeard = 1.5, -- tier 0 weights x (ProgressHeard - p)
	CloseScale = tri(0.7, 1, 1.2), -- tier 2 weights x this
	-- who: the score of a player who is owed one is (due - theta) x these
	Alone = 1.5, -- no teammate within AloneRange (squads of two or more)
	AloneRange = 25,
	Loud = 1.3, -- a High or Critical noise heard from them within LoudWindow
	LoudWindow = 20,
	Strained = 0.5, -- their strain over StrainedOver
	StrainedOver = 0.5,

	-- 3.4: the leash, in studs walked from the focus player.
	Leash = table.freeze({
		Min = tri(35, 25, 20),
		Max = tri(70, 55, 45),
		Clear = 15, -- never this close walked to anyone outside a close interaction or a chase
		Patience = 2, -- outside the band this many director steps in a row: a new hold point
		GoalEvery = 4, -- no new hold point sooner than this (a breach of Clear aside)
		CreepPace = 7, -- short quiet moves near players (CreatureConfig.Speeds.Patrol)
		CreepLeg = 10, -- a quiet move that passes within TrailClear of an ear is at most this long; longer waits for a slot
		TrailPace = 11, -- quiet moves with every ear TrailClear or more away (Beats.ShadowFast: keeps up with a walker)
		TrailClear = 30, -- straight, from every point of the leg to every player's ear (Audible.StepCreep 22 + 8)
		StepPace = 9, -- far steps (H1) and the fake tell (Presence.Director.HintPace)
		RunPace = 13, -- running steps (H1b): heard, under the chase pace 16.5 and the player's sprint 19
		ApproachRun = 12, -- the approach only when no route back into the band takes under this at RunPace
		Lead = 5, -- seconds: for a Sprint-class target every placement is measured from where they will be this far on
		OffRoute = 10, -- a hold point for a moving focus lies this far or more from their line of travel...
		OffRouteSeconds = 5, -- ...over the next this many seconds (side rooms first)
		LineSeconds = 1, -- a hold point with a clear line to a player for this long is left
	}),

	-- 3.5: chases on the squad's token bucket.
	Chase = table.freeze({
		Refill = tri(240, 150, 90), -- mean seconds per token for one player
		RefillMin = 0.6, -- each token's refill time is Refill x U(RefillMin, RefillMax) (stream Lurk|Refill)
		RefillMax = 1.4,
		PerPlayer = 0.3, -- refill rate x (1 + PerPlayer x (players - 1))
		Cap = tri(1, 1, 2),
		First = 90, -- the run's first token: this long after the first floor's activation
		ChainSeconds = 20, -- a chase taken up again within this of its end is the same chase (no second token)
		ShortSeconds = 6, -- a chase over within this, with him never within ShortNear straight of its target...
		ShortNear = 20,
		ShortRefund = 0.5, -- ...gives this much token back
		RepeatAfter = 2, -- the last token-paid encounter's target is not the next one's until RepeatAfter x Refill passed
		-- (or they are the only player who counts); meanwhile their triggers give the near miss
		NearMissEvery = tri(60, 45, 30), -- a player gets a near miss no sooner than this after their last
		NearMissSquad = 25, -- no two near misses within this, squad-wide (the second trigger: the silent slip-away)
		FeintSteps = 6, -- studs he comes at them after the screech before he turns away
		BackAwayPace = 9, -- the near miss's exit when no walk out of sight exists: he backs away facing them...
		BackAwaySeconds = 6, -- ...for at most this long
		Rescue = 20, -- a player going down: no interaction and no chase start on anyone for this long
		SpendAfter = 30, -- a full token held this long with no trigger: C3 and C1 weigh x SpendWeight...
		SpendWeight = 3,
		SpendLoud = 60, -- ...only for a player of class Sprint or Walk, or loud (High/Critical) within this
		DefenceWindow = 5, -- a defence during a director interaction or this long after it never starts an encounter
	}),

	-- 3.6: crawlways and ducts.
	Ducts = table.freeze({
		Pace = 6, -- crawling with no player in the same crawlway or duct
		SharedPace = 3.8, -- with one (a crawling player moves 4.5: GameConfig.VentCrawlSpeed)
		Fold = 1.2, -- seconds to fold in or out at a mouth (standing still)
		MouthClear = 12, -- he leaves at no mouth this close (straight) to a player...
		MouthSeenWalk = 30, -- ...nor one in a player's view, unless it is this far walked from everyone (a seen exit)
		SeenWindow = 3, -- he follows a player in only if he saw them go in within this (and holds a token)
		ChaseSeconds = 10, -- a crawl chase lasts this at most
		ExitHold = 3, -- the player out: he does not come out of that mouth for this long
		CatchStill = tri(1e6, 2, 2), -- a crawler stopped this long within CatchReach of him is caught (1e6: never)
		CatchReach = 3,
		HearRange = 25, -- H3: he crawls within this (straight) of the player
	}),

	-- 3.7: the squad.
	Coop = table.freeze({
		GroupRange = 15, -- players this close (straight) run one clock at the noisiest member's rate
		SpreadRate = 0.6, -- a player who is not the focus: their clock runs at this share
		Stint = 45, -- once he gives an interaction to a group, the focus stays with it this long...
		StintCount = 3, -- ...or this many interactions, unless another player passes Starve
		Starve = 60, -- squads of two or more: a player with no interaction for this long goes first
		StarveMax = 90, -- the target the sim holds: nobody longer than this without one
	}),

	-- 3.6: the heartbeat (web/src/creature/index.js nearFloor): its radius in the quiet lurk, and while he is alarmed
	Heart = table.freeze({
		Quiet = 15, -- Leash.Clear: between interactions the heartbeat starts only this close (straight)
		Alarmed = 45, -- Presence.Audio.NearRadius: during an interaction that reached them, a chase, a search, a watch
		Tail = 8, -- seconds the Alarmed radius stays after that ends
	}),

	-- 5.3: his answer to a loud noise when no token is held
	Reply = table.freeze({
		Within = 4, -- a High or Critical noise heard: the reply starts within this many seconds
		StepsMin = 3, -- heavy steps toward the noise at StepPace...
		StepsMax = 4,
		EndClear = 15, -- ...ending this far walked from everyone or more
		LureFar = 12, -- a noise sounding this far or more from its maker (a thrown flask)...
		LureHold = 15, -- ...moves the leash's hold point to its side for this long, token or not
	}),

	-- 4.4 and 4.13: the locker nudge and the director's sniff
	Nudge = table.freeze({ Open = 0.3, Shut = 1.2, Ajar = 0.15, AjarSeconds = 120 }),
	Sniff = table.freeze({ BreathMargin = 0.5, MinWindow = 1.5 }), -- a director C4's window: min(drawn, breath left - margin)

	-- 4.8: the vantage
	Vantage = table.freeze({ TorchAngle = 7, TorchSeconds = 0.5, TorchRange = 80 }),

	-- How far each of his sounds counts as heard (studs, straight, from where it plays to the player's ear): the
	-- distance at which its quietest variant stands 6 dB over the floor's beds (web/tools/audio-test.mjs measures it,
	-- as it does Footfalls.HeardTo). Reach, strain and the sims read these; the mix reads the presets' roll-offs.
	Audible = table.freeze({
		StepHeavy = 80, -- Footfalls.HeardTo
		StepCreep = 22,
		CreatureRattle = 25,
		WetBreath = 20,
		LockerDoor = 22,
		MetalCreak = 30,
		VentScrape = 40,
		VentBreathing = 25,
		CreatureGrowl = 35,
		TeleportHiss = 40,
		CreatureSniff = 15,
		Screech = 120,
	}),
	-- the director's cost cap (section 5.8): walking-distance queries (FloorNav.pathLength) per director step
	Budget = table.freeze({ PathQueries = 40, GeometryTries = 3 }),
	Gait = table.freeze({ CreepVolume = 0.25 }), -- his footfalls' volume while he creeps (x the profile's own)
	Reach = table.freeze({ HeardSeconds = 1, SeenSeconds = 0.3 }), -- perceived this long in all: it reached them

	Fake = table.freeze({
		OneIn = 10, -- at most one of a player's interactions in this many is a fake tell (F: his steps that stop)
		-- no empty teleport warning on any difficulty: a hiss where he is not breaks "every sound from where he is"
	}),

	-- 3.2 H5: the spoken line (the voice system fills it; LurkRules only rations it).
	Voice = table.freeze({
		PerPlayer = 120, -- one director-issued line per player per this many seconds at most
		PerTeam = 45,
		Enabled = 0, -- 0 until recorded lines exist: H5's weight counts as 0 and no event offer is made
		Offers = table.freeze({ "NearMiss", "PassBy", "Peek" }), -- lines offered inside these (not extra interactions)
	}),
})
```

### 2.3 Where each number comes from

| Group | Numbers | Source |
|---|---|---|
| `Clock.Gap` Walk 30, Work 40, Crouch 60, Duct 40, Hiding 75, `SprintSpeed` 15, `WalkSpeed` 7.5 | [R 3.1 A] (Work is the research's "Stand"); the two speeds are also `NoiseConfig.SpeedTiers` in `web/src/engine/config.js` |
| `Clock.Gap.Sprint` 14 | [P], tuned, not the research's 17. Nobody sprints without stopping: [G] `StaminaMax` 100, `StaminaSprintDrain` 7 (14.3 s of sprint), `StaminaRegen` 14 after `StaminaRegenDelay` 1.2 (8.3 s to refill) give a person about 63 % sprint and 37 % walk. With 17 that measures 1 / (0.63 / 17 + 0.37 / 30) = 20.2 s, and presence-sim's bot (`STAMINA_RECOVERED` 25: 3.6 s of sprint, 3.0 s of walk, 54.5 %) 21.2 s, both outside the player's "15 if sprinting" [Q, Nov 16 15:30]. With 14: a person 17.4 s, the bot 18.5 s, a stretch of pure sprint 14 s. The sprint number is tuned so a stamina-limited sprinter **measures** 15..20 s; the sim confirms it |
| `Clock.Gap.Still` 75, `WorkWindow` 2 | [Q] Nov 16 15:30 decision: "Standing still or hidden: slower still"; 75 = `Hiding` [P]; `WorkWindow` [P] |
| `MixTau` 2.5 | [P]: the research says "the time-weighted mix over the last 5 s"; a first-order filter with a 2.5 s time constant has the same mean age and needs one number of state |
| `HeardShare` 0.6, `FirstHeard` 20, `FirstSeen` 40, `SamePlayer` 10, `Team` 6 | [R 3.1 A]; Easy 25 / 50 [P] |
| `ThetaMin/Max` 0.6 / 1.4, `LullEveryMin/Max` 5 / 7, `LullScale` 2, `LullComp` 7/6 | [P]. The research's 0.8 / 1.2 gives a steady walker one thing every 24 to 36 s with no lull, a learnable rhythm (research 2.10: horror that never lets go stops being scary). A lull every 5..7 interactions (mean 6) makes the mean theta (6 + 1) / 6 = 7/6; the clock runs 7/6 faster so the long-run mean gap stays `Gap` |
| `Activity` 1.4 / 1 / 0.75 | [P]; the beta's setting (open question 6) |
| `HeardCost` 0.08 | [P]: a player who only heard a far screech or a hiss is not charged its full cost (0.35, 0.30), which would switch off their own seen and close interactions |
| `TellHolds` 12, `WarnMax` 2 per `WarnWindow` 180 | [P]: a heard tell stays true for 12 s; the teleport warning stays rare (the player's Nov 15 complaint, [Q]) |
| `HideAfter` 20, `HideOwedMin/Max` 12 / 20 | [P]; the stay limit shoves a hider out at 45 s [M 8.2], so a hide owed only at the 75 s gap gets nothing |
| `LumpNear` 12 | [P]: a thrown flask lures him away; it must not also speed up the thrower's own clock |
| `Carry` 0.5 | [P]. The research resets due to 0. With a reset, the time he needs to set an interaction up is added to every gap; with a capped carry-over the long-run gap is exactly Gap x theta. Section 3.2 |
| `TeamBody` 15 | [R 3.7] |
| `Retry` 6 | [C] `Presence.Director.BeatRetry` |
| `Fallback` 3 | [R 3.3] |
| `Lumps` 0.25 / 0.35 / 0.5 | [R 3.1 A] for DoorSlam, FlaskShatter, Gasp, ObjectiveClunk, GrateKick, GeneratorStart. Slide, HardLanding (0.25), FloorDebris, TrapSnap (0.35): [P], placed by their NoiseKind class. GeneratorStart is not a kind of today's website (`engine/config.js NoiseKinds`); the row is for the Roblox NoiseConfig |
| `Strain.*` rates, gates 0.45 / 0.65, 0.8, 25..40, 0.35, 0.5, 60 | [R 3.1 B]; Easy and Nightmare gates [P]; `Catch` 1 and `FloorStart` 0.35 [P] |
| `Types` Tier, Cost, Cooldown, Weight, Min, Max | [R 3.2] and [R 3.3], except: H1 4..6 s (research 3..5 s) [P], because his stalking footfalls are about 2 s apart [M 11] and two must be heard; F's cooldown 60 [P]; `Approach` and `NearMiss` rows [P]; `Setup` 8 / 20 [R 3.3] |
| `Fit` 2 and its lists, `ProgressClose` 0.5, `ProgressHeard` 1.5 | [R 3.3] |
| `CloseScale` | [P] |
| `Alone` 1.5, `Loud` 1.3, `Strained` 0.5 over 0.5 | [R 3.3]; `AloneRange` 25 and `LoudWindow` 20 are [C] `Teleport.Isolated` / `Teleport.LoudWindow` |
| `Leash.Min/Max` | [R 3.4] |
| `Leash.Clear` 15 | [R 3.4] |
| `Leash.Patience`, `GoalEvery`, `LineSeconds` | [P] |
| `Leash.CreepPace` 7, `StepPace` 9 | [R 3.4] ("on foot 7-9"), equal to [C] `Speeds.Patrol` and `Presence.Director.HintPace` |
| `Leash.TrailPace` 11 | [C] `Presence.Beats.ShadowFast` 11 (the most he walks shadowing). [G] `WalkSpeed` 11: at 7 or 9 a walker going one way leaves the band in about 4 s and the approach's 90 walked in about 16 s, so the leash would be held by teleports. 11 only while every ear is `TrailClear` away, so it is never heard |
| `Leash.TrailClear` 30, `CreepLeg` 10, `RunPace` 13, `ApproachRun` 12, `Lead` 5, `OffRoute` 10, `OffRouteSeconds` 5 | [P]. `RunPace` is under the chase's 16.5 [M 18] and the sprint's 19 [G] |
| `Chase.Refill`, `PerPlayer`, `Cap`, `First` | [R 3.5] |
| `Chase.RefillMin/Max` 0.6 / 1.4, `ShortSeconds` 6, `ShortNear` 20, `ShortRefund` 0.5, `RepeatAfter` 2, `NearMissSquad` 25, `BackAwayPace` 9, `BackAwaySeconds` 6, `SpendLoud` 60, `DefenceWindow` 5 | [P] (section 5.6) |
| `Coop.Stint` 45, `StintCount` 3, `Starve` 60 | [P]; `Starve` lowered from [C] `Presence.Director.StarveSeconds` 75 because a stint holds the focus |
| `Heart.Quiet` 15, `Alarmed` 45, `Tail` 8 | `Quiet` = `Leash.Clear` [P]; `Alarmed` = [C] `Presence.Audio.NearRadius` 45; `Tail` [P] |
| `Reply.*`, `Nudge.Ajar` 0.15, `AjarSeconds` 120, `Sniff.*`, `Vantage.*`, `FirstHoleWeight` 3, `Ducts.MouthSeenWalk` 30 | [P]; `Vantage.TorchAngle` 7 is the stare's cone [M 3.3]; `Nudge.Open` 0.3 and `Shut` 1.2 as in 4.4 |
| `Chase.ChainSeconds` 20 | `web/tools/presence-sim.mjs` `CHASE_CHAIN` |
| `Chase.NearMissEvery`, `FeintSteps` | [P] (the research says "two steps") |
| `Chase.Rescue` 20 | [R 3.7] |
| `Ducts.*` | [R 3.6]; `CatchStill` on Nightmare [P]; `HearRange` 25 [R 3.2 H3] |
| `Coop.GroupRange` 15, `SpreadRate` 0.6, `Starve` 75, `StarveMax` 90 | [R 3.7]; 75 is [C] `Presence.Director.StarveSeconds` |
| `Audible.StepHeavy` 80 | [C] `Footfalls.HeardTo` |
| every other `Audible`, `Gait.CreepVolume`, `Reach.*` | [P]. Section 4.0 gives the arithmetic behind each and the audio test that must confirm it |
| `Fake.OneIn` 10 | [R 3.2]. The research's other fake (a teleport flicker and hiss with no arrival) is dropped on every difficulty: the hiss would play where he is not, which the hard limits forbid |
| `Voice.PerPlayer` 120, `PerTeam` 45 | [R 3.2] |
| `Clock.PlanAhead` 6, `Chase.SpendAfter` 30, `SpendWeight` 3, `Budget.*`, `Audible.CreatureSniff` 15 | [P]. Sections 3.4, 5.6, 5.8 |
| `Types.C4.Max` 16 | [P]. The research's 4..8 s is the sniffing alone; the inspector itself may take up to 11 s [M 8.1], plus 1.6 s at each of two spots |
| `Types.H1b`, `Reply`, `X`, `Stray` rows; `NearMiss.Max` 6; `FitOf.Sprint` with H1b in C3's place; `FitOf.Work`, `Still`, `Hiding` | [P]. C3 leaves the sprinter's fit list because the teleport warning is capped (`WarnMax`); a sprinter's fit is now one seen type ahead (S1), one seen type that needs no timing (S3) and one heard type that keeps up (H1b) |

### 2.4 `CreatureConfig.Presence`: reused, replaced, removed

| Entry | v3 | Why |
|---|---|---|
| `Director.Interval` 1 | reused (equals `Lurk.Interval`; one of the two is deleted in stage 1: keep `Lurk.Interval`) | |
| `Director.FarWalk`, `MenaceSeconds`, `StartMenace`, `HintMenace`, `BeatMenace` | **removed** | menace is replaced by the clock |
| `Director.QuietSeconds`, `QuietAfterCatch` | **removed** | replaced by strain and backstage, sized by what happened |
| `Director.BeatEvery`, `BeatRetry`, `FirstBeat`, `BeatWalkMin`, `BeatWalkMax` | **removed** | replaced by `Clock.Team`, `TeamBody`, `Retry`, `FirstHeard`, `FirstSeen` and each type's own range |
| `Director.LeashWalk` 100, `HintMin` 30, `HintMax` 55, `HintEvery` 8 | **replaced** by `Leash.Max`, `Leash.Min`, `Leash.Max`, `Leash.GoalEvery` | the band is per difficulty now |
| `Director.StarveSeconds` 75 | **replaced** by `Coop.Starve` | |
| `Director.HintTries` 14, `HintPace` 9, `PatrolPace` 7 | reused by the leash's hold-point search | |
| `Director.AheadDot` 0.4 | **no longer ranks hold points** (5.5: off-route first); kept for plans that need "ahead" | an ahead hold point cannot be kept against a walker |
| `Director.ApproachWalk` 90, `ApproachMin` 45, `ApproachMax` 80, `ApproachTries` 60, `ApproachCooldown` 25 | reused unchanged, under v3's added limits (3.4 step 5 (b)) | the approach is the director's last fallback [R 3.3] |
| `Director.SeenRange` 80, `SeenHalfAngle` 50 | reused: "the player sees him" | |
| `Beats.*` geometry (Near, ReachWalk, BreakOff, SafeWalk, HideWalk, ApproachWalk, ApproachSeconds, Peek*, Corner*, Glimpse*, Cross*, Shadow*, Pass*) | reused unchanged, except the two below | |
| `Beats.ShadowMinSeconds` 15, `ShadowMaxSeconds` 25 | **changed** to 10 and 20 | [R 3.2 C1] |
| `Beats.Weights` | **removed** | replaced by `Lurk.Types[*].Weight` |
| `Detection.*` | reused unchanged | |
| `Chase.CapSeconds` pair(12, 45) | **changed** to tri(8, 12, 45) | [R 3.5] |
| `Chase.Breather` pair(35, 15) | **changed** to tri(40, 35, 15); Easy [P] | the pacing's Relax stays |
| `Chase.LostSeconds`, `Pursuit`, `Windup`, `SurpriseRange`, `SurpriseWindup` | reused unchanged | |
| `Teleport.*` | reused unchanged | |
| `Audio.RattleRadius` 45 | **removed** | the rattle is a director-issued sound (H2) and plays in hunting states only (section 3.6) |
| `Audio.NearRadius` 45 | **reused only while he is alarmed** (`Lurk.Heart.Alarmed`); in the quiet lurk the radius is `Lurk.Heart.Quiet` 15 (3.6) | kept at 45 always, the heartbeat would run for the whole floor: the leash holds him 25..55 walked, under 45 straight nearly always [M 11; `web/src/creature/index.js nearFloor`] |
| `FloorGrace` {Standard 20, Nightmare 12} | add `Easy = 25` [P] | |
| `DifficultyConfig.teleportCooldown` {60, 120} [40, 80] | **no longer read by the website** | the stalk teleport (C3) is issued by the clock with its 60 s cooldown; the Roblox runtime keeps it until its port |

`web/tools/creature-sim.mjs` holds a table `SPEC` of presence numbers written from MONSTER.md. The rows
`Director.HintMin`, `HintMax`, `HintEvery`, `LeashWalk`, `BeatEvery`, `QuietSeconds`, `QuietAfterCatch`,
`StarveSeconds` are deleted and the lurk rows of section 8.3 are added, in the same commit as the config change.

### 2.5 The three difficulties at a glance

| | Easy | Standard | Nightmare |
|---|---|---|---|
| Mean gap between interactions (sprint / walk / work / still / crouch / duct / hiding) | 14 / 30 / 40 / 75 / 60 / 40 / 75 | the same | the same |
| First heard / first seen on a floor | 25 / 50 s | 20 / 40 s | 20 / 40 s |
| Leash band, walked | 35..70 | 25..55 | 20..45 |
| Close interactions only under strain | 0.40 | 0.45 | 0.55 |
| Seen interactions only under strain | 0.60 | 0.65 | 0.75 |
| Weight of close interactions | x 0.7 | x 1 | x 1.2 |
| Chase token: mean seconds each (each one x U(0.6, 1.4)), cap | 240, 1 | 150, 1 | 90, 2 |
| Chase cap | 8 s | 12 s | 45 s |
| Breather after a chase or a catch (pacing's Relax) | 40 s | 35 s | 15 s |
| Near miss per player no sooner than (squad-wide 25 s apart) | 60 s | 45 s | 30 s |
| Caught in a crawlway or duct | never | stopped 2 s within 3 of him | the same |
| Fake tell (his steps that stop) | at most 1 interaction in 10 | the same | the same |
| Floor grace | 25 s | 20 s | 12 s |
| Speeds, senses, lives, traps, batteries | Standard's (`DifficultyConfig` has no Easy row) | as today | as today |


---

## 3. Per-player state and its update

All of section 3 is the pure core, `LurkRules` (section 10: a JavaScript module `web/src/creature/lurk.js` first,
written in the shape of a Luau port). It holds no clock, no world and no random stream: the service passes the time,
the readings and the random numbers in. The service (`MonsterAI`, `web/src/creature/service.js`) keeps one `Lurk`
object per run, created in `beginRun` beside `this.director`, reset in `activateLevel`, told in `forgetPlayer`.

### 3.1 What is kept

Per player (a `Map` keyed by the player handle, created on first read, deleted by `forgetPlayer`):

| Field | Meaning | At a floor's activation |
|---|---|---|
| `r` | the clock's rate now (per second), filtered toward `1 / Clock.Gap[class]` | `1 / Gap.Walk` [P] |
| `due` | how much he owes them (0..) | 0 |
| `theta` | the threshold of the next interaction | drawn U(ThetaMin, ThetaMax) |
| `owedSince` | when `due` first reached `theta` (null while under it) | null |
| `strain` | 0..1 | `min(strain, Strain.FloorStart)` |
| `raisedAt` | the last time anything raised strain | now |
| `backstage`, `backstageUntil` | the back-off (3.3) | false |
| `cls` | the movement class (3.5) | read |
| `lastReachAt` | the last time an interaction reached them | -Infinity |
| `lastType` | the type of the last interaction that targeted them | null |
| `cooldownUntil[type]` | per-type cooldown (`Types[type].Cooldown`) | cleared |
| `retryUntil[type]` | a type that found no place or reached nobody (`Clock.Retry`) | cleared |
| `nearMissAt` | their last near miss | -Infinity |
| `count`, `fakes` | interactions that reached them on this floor, and how many were F | 0, 0 |
| `lullIn` | interactions left before their next lull | drawn LullEveryMin..LullEveryMax (theta stream); kept across floors |
| `workAt` | their last `ObjectiveWork` pulse (for the Work class) | -Infinity |
| `heardAt`, `tellSide` | the last heard interaction that reached them, and the side of them it played on (for `TellHolds`) | -Infinity, null |
| `warns` | the times of teleport warnings aimed at them (C3, approach), the last `WarnWindow` s | [] |
| `hideOwedAt` | when an owed hide interaction falls due (5.2), or null | null |
| `alarmUntil` | the heartbeat uses `Heart.Alarmed` until this (3.6) | -Infinity |
| `seenHole` | they have seen an S4 this run (stage 2; kept across floors) | kept |

Team (one per run):

| Field | Meaning | At a floor's activation |
|---|---|---|
| `tokens` | the chase bucket, 0..`Chase.Cap` | kept (a run-wide budget); on the run's first activation `max(0, 1 - Chase.First x rate)` (5.6) |
| `floorAt` | the activation time | now |
| `firstHeardFired` | the floor's first interaction happened | false |
| `lastStartAt`, `lastBodyStartAt` | the last interaction's start, the last body interaction's start | -Infinity |
| `active` | the interaction running now (`{id, type, tier, body, target, startAt, endsBy, reached}`) or null | null |
| `rescueUntil` | no interaction or chase starts before this (a player went down) | -Infinity |
| `chaseEndAt` | the last chase's end (for `Chase.ChainSeconds`) | kept |
| `fullSince` | when the bucket last became full (for `Chase.SpendAfter`) | kept |
| `refillNext` | the seconds the token now filling takes (`Refill x U(RefillMin, RefillMax)`, stream `Lurk|Refill`) | drawn at the run's first activation; kept |
| `lastEncTarget`, `lastEncAt` | the target of the last token-paid encounter and its spend time (`RepeatAfter`) | kept |
| `nearMissAnyAt` | the last near miss on anyone (`NearMissSquad`) | -Infinity |
| `stintGroup`, `stintAt`, `stintCount` | the group (its players' ids) holding the focus, since when, how many interactions (5.1) | null, -Infinity, 0 |
| `lure` | `{point, until}`: a far noise's side for the hold point (5.3) | null |
| `focus`, `hold`, `goalAt`, `outside` | the leash (5.5) | null, null, now, 0 |

### 3.2 The clock (every brain tick)

The brain ticks at 10 Hz on the fixed 30 Hz game tick (`service.js tick()` -> `step(dt)`, `GameConfig.ServerTickHz`;
[M 1]); `dt` is the brain's own step (normally 0.1 s). `LurkRules.integrate(state, readings, dt)` runs inside
`step()` right after `_sense()`, before `_direct()`.

For each player who **counts** (huntable, on his level, Alive, no `Cutscene` lock, his brain not Scripted, Dormant or
asleep; anyone else's clock and strain are frozen, I13):

```
k     = 1 - exp(-dt / Clock.MixTau)
r     = r + (Clock.LullComp / (Clock.Gap[cls] * Clock.Activity[setting]) - r) * k   -- setting: the host's, Normal off the beta
rEff  = max(r of every counting player within Coop.GroupRange straight of them, on the same level)   -- them included
share = (backstage ? Strain.BackstageRate : 1) * (squad > 1 and not inFocusGroup ? Coop.SpreadRate : 1)
due   = min(due + rEff * share * dt, theta + 1)
if due >= theta and owedSince == null: owedSince = now
```

`inFocusGroup`: they are the leash's focus (5.5) or within `Coop.GroupRange` straight of the focus. The cap
`theta + 1` [P] keeps a long block (a chase, a cutscene inside a floor) from paying out a burst afterwards.

**Lumps.** `service.js _onNoise(event)` already receives every pulse before hearing filters it. Add: when
`event.sourceUserId` names a player who counts, `Clock.Lumps[event.kind]` exists **and the noise sounds within
`Clock.LumpNear` (12) of that player's root** [P], `due += lump` (same cap). A flask thrown far is a lure (5.3), not
a lump on the thrower. The lump does not depend on whether he heard it: the director knows; his own ears are 5.3.
The same hook records `workAt = now` for an `ObjectiveWork` pulse of theirs (the Work class, 3.5).

**When an interaction ends** (`LurkRules.settle(state, interaction, now, u)`, `u` a number from the player's theta
stream):
- its target, if it reached them, **and every other player it reached who stands within `Coop.GroupRange` (15)
  straight of the target** (they share one clock: [Q] Nov 16 15:30, "the loudest nearby player sets the pace for that
  area"): `due = min(max(due - theta, 0), Clock.Carry)`, then the next theta: `lullIn -= 1`; `theta = ThetaMin + u x
  (ThetaMax - ThetaMin)`, times `LullScale` when `lullIn` reached 0 (then `lullIn` is drawn again in
  `LullEveryMin..LullEveryMax` from the same stream); `owedSince = null`, `lastReachAt = now`, `count += 1`;
- every other player it reached (farther from the target): `due = max(0, due - Clock.HeardShare)`, `lastReachAt = now`;
- every player it reached: `strain += Types[type].Cost` when they saw it, `strain += min(Types[type].Cost,
  Clock.HeardCost)` when they only heard it [P];
- every player it reached by hearing: `heardAt = now`, `tellSide` = the side of their travel (left, right, behind,
  ahead: the sign of the cross and dot products of their travel with the way to where it played);
- the target, if it did not reach them: `retryUntil[type] = now + Clock.Retry`; `due` and `theta` stand;
- always: `cooldownUntil[type] = now + Types[type].Cooldown` on the target, `lastType = type`.

The records `X` (a chase's start) and `NearMiss` settle like any interaction (P20); `Stray` (4.0) settles every
player it reached with `HeardShare` only (it never pays a full theta and never counts toward `lullIn`).

**Why `Carry` and not a reset to 0** [P]. With `due = 0` after each interaction, the time he takes to set one up (2 to
20 s, `Types[*].Setup`) is added to every gap: a sprinter's 14 s would measure about 19. With the remainder carried
(at most 0.5 of a gap), lateness is paid back on the next one and the long-run mean gap is `Gap / LullComp x
E[theta with lulls] = Gap`; the cap keeps two from coming back to back.

**Arithmetic of a tight group** (not measured). Two sprinters within 15 of each other: each interaction settles both,
the group's clock runs at one sprinter's rate: one every 14 s for the pair, as solo. The first version (target pays
1.0, teammate 0.6) gave a pair one every 1.6 / (2 / 17) = 13.6 s and a four one every 11.9 s, faster than solo.

**The floor's first interaction.** Nothing fires before `floorAt + Clock.FirstHeard`. At that moment every counting
player's `due = max(due, theta)` (so it is owed) and the first interaction of the floor must be tier 0. Tier 1 and 2
are not feasible before `floorAt + Clock.FirstSeen`. `floorAt` is `activateLevel`'s time, which is also the start of
the spawn hold (`CreatureConfig.FloorGrace` 20 [12] [C]); so the first heard interaction comes as the hold ends on
Standard (20 s) and 8 s after it on Nightmare.

### 3.3 Strain and backstage (every brain tick)

The director's readings (`walk`, `sees`, `chased`) are taken once a second, as today (`service.js _direct`); between
two readings each brain tick applies the last one:

```
raised = false
if sees:                         strain += Strain.SeenRate * dt;  raised = true
if walk <= Strain.NearWalk:      strain += Strain.NearRate * dt;  raised = true
if chased:                       strain += Strain.ChaseRate * dt; raised = true
if raised: raisedAt = now
elif now - raisedAt >= Strain.DecayDelay: strain -= Strain.Decay * dt
strain = clamp(strain, 0, 1)
```

Events (each sets `raisedAt = now`): an interaction that reached them `+= Types[type].Cost` (or `HeardCost`, 3.2); a
chase on them starting `+= Strain.ChaseEntry`; a catch of them `strain = Strain.Catch`; a near miss on them `strain =
max(strain + Types.NearMiss.Cost, Strain.BackOff)` [P]: **a near miss always sends its target backstage**, so the
promise "after a big scare he leaves you alone" holds (the first version gave 0.35 + about 2 s seen x 0.04 = 0.43,
under the 0.8 of backstage); his stun by a flask that they saw `+= Types.Approach.Cost` [P].

**A backstage player's noise** does not pull him: `Summary.token` (5.3) is false for a noise whose maker is backstage
(their stare and coming within 12 still count) [P], so two chases cannot come seconds apart on Nightmare's two-token
bucket.

**Backstage.** When `strain >= Strain.BackOff` and they are not backstage: `backstage = true`, `backstageUntil = now +
U(BackstageMin, BackstageMax)` (their backstage stream). They leave it when `now >= backstageUntil` **and** `strain <=
Strain.Release`. While backstage: their clock runs at `BackstageRate` (3.2), only tier 0 types are feasible for them,
and the leash keeps him `Strain.BackstageWalk` walked or more from them (5.5).

Check of the numbers (arithmetic, not measured). A Standard chase ends at the latest at 12 s: `0.5 + 12 x 0.05 = 1.1`
(capped 1) even unseen, so every chase is followed by backstage. Easy's 8 s cap: `0.5 + 8 x 0.05 = 0.9`. A walker
taking one tier 1 interaction (0.15) every 30 s sheds `25 x 0.02 = 0.5` in between: never backstage. That walker's
only long quiet is therefore the lull of 3.2 (one gap in 5..7 doubled), plus backstage after a chase or near miss.

### 3.4 One director step (once per `Lurk.Interval`)

`service.js _direct(t)` keeps its gate (`t >= directAt`, awake, not scripted) and its readings, then calls
`LurkRules.decide(state, readings, now, u)` (pure; `u` a number from the `Lurk|Pick` stream), which returns at most one
**order**, then acts on it. In this order:

1. **Readings** (as today): per player `walk` (`nav.pathLength` from his feet to theirs), `sees` (`_seenBy`), `chased`
   (`state === 'WallChase'` and they are its target), plus the new `cls` (3.5), `alone` (no counting teammate within
   `AloneRange` straight; squads of two or more), `loud` (`_record(p).loudAt` within `LoudWindow`, a field the service
   already keeps), `hiding`, `duct`.
2. **Team gates.** No new interaction when: `active` is not null; `now < rescueUntil`; `now - lastStartAt < Clock.Team`;
   the brain is not in `Patrol` (it lurks only from Patrol: a chase, a search, a warp, a stun or a beat in progress
   blocks it); `!firstHeardFired && now < floorAt + Clock.FirstHeard`.
3. **Who** (5.1). The players who count, not owed nothing: `due >= theta`, or, for planning a body type,
   `due + rEff x Clock.PlanAhead >= theta`, or `hideOwedAt <= now` (5.2). A pending **Reply** (5.3) goes before all of
   these. None: go to 6.
4. **What** (5.2): the feasible types for that player, weighted, drawn in a seeded order without putting back; their
   geometry is asked in that order, at most `Budget.GeometryTries` per step; the first that fits is the plan. A plan
   found while `due < theta` (planned ahead) is a **setup**: he walks to its start and waits there, hidden, until `due
   >= theta`; then it starts. A type may not start when it would reach any player within `Clock.SamePlayer` (10) of
   that player's `lastReachAt` (a heard-only type is held until then, not dropped) [P].
5. **Fallback.** No plan, and `now - owedSince >= Clock.Fallback`, in this order:
   (a) **H1 or H1b from where he is** (4.1's rule without its move: he steps toward the next hold point; H1b when the
   target is of class Sprint or more than 55 walked away), when the target's ear is within `Audible.StepHeavy` (80)
   and the type passes every timer of 5.2, **`lastType` included: the fallback is not exempt from "never the same
   type twice running"**; H1 and H1b are two types, so they may alternate;
   (b) the **Approach** (the warned approach teleport, `_planApproach` / `_startApproach`) only when he is more than
   `Director.ApproachWalk` (90 [C]) walked from them **and** no route brings him back into the band within
   `Leash.ApproachRun` (12) s at `RunPace`, an approach may run (`service.js _approachAllowed`,
   `Director.ApproachCooldown` 25), the target has had fewer than `WarnMax` (2) warnings in the last `WarnWindow`
   (180) s, and no heard interaction reached them within `TellHolds` (12) s;
   (c) else nothing: the slot stays owed and the leash (step 6) closes in.
   The leash (5.5) keeps him within 55 walked (Standard) and now keeps up with a walker, so (a) almost always fits.
6. **Leash** (5.5), only when this step made no plan: one planning task per step (section 5.8).

### 3.5 The movement class (every brain tick, from data the service has)

| Read | Where it comes from today |
|---|---|
| `moveState` | `_moveStateOf(player)` (env `playerMoveState()`; a remote handle's `moveState()`), the codec's `MoveStates` |
| `speed` | `_record(player).speed`, measured from the root every brain tick in `_watchPlayers` (smoothed, `dt x 6`) |
| `duct` | `_inVent(player)` (the duct rail, `mode === 'Vent'`) **or** the root inside a room of kind `Crawlway` on his level (new `_inCrawlway(player)`: the level's Crawlway rects from `meta.rooms`, `{x, z, w, d}` world rect with `x..x+w`, `z..z+d` as `nav.js` reads them, and `floorY..floorY + height`; built once per level, at most 18 rects [W]) |

First match wins:

| Class | Rule |
|---|---|
| `Hiding` | `moveState === 'Hiding'` |
| `Duct` | `duct` |
| `Sprint` | `speed >= Clock.SprintSpeed` (15) |
| `Walk` | `speed >= Clock.WalkSpeed` (7.5) |
| `Crouch` | `moveState` is `Crouching` or `DownedCrawling` |
| `Work` | `now - workAt <= Clock.WorkWindow` (2): an `ObjectiveWork` pulse of theirs (34, Normal [M 3.1]) just sounded; also any upright player moving at 1 or more but slower than 7.5 |
| `Still` | anything else: upright, speed under 1, no Work (standing still and quiet, `Trapped`) |

`Still` replaces the first version's `Stand` (40 s), which paid standing still faster than crouch-walking and made
"stop and listen", the answer to far steps, cost more than moving on in a crouch. [Q] Nov 16 15:30: "Standing still
or hidden: slower still". [P]: `Still` = 75 s, the same as `Hiding`; `FitOf.Still` = `FitOf.Crouch`.

Player paces for reference ([M 2], `web/src/game/config.js`): walk 11 (class Walk), sprint 19 (Sprint), crouch 5.5
(Crouch), duct crawl 4.5 and scurry 9 (both Duct). A `Downed` player does not count (3.2).

### 3.6 Between interactions: the quiet lurk

Today he walks his patrol loops at 7 with his footfalls heard to 80 ([C] `Footfalls.HeardTo`), and `monsterFx.js`
plays `CreatureRattle` every U(4.5, 8) s within 45 of the page's player in every stalking state and beat
(`RATTLE_STATES`). With a 25..55 leash that is a continuous tell, and the cadence would drown in it. In v3:

- **Lurking is Patrol.** No new MonsterState: Patrol gets a lurk mode. While a focus exists (5.5) he does not walk
  loops: he walks to the leash's hold point (`ctx.hint`, the mechanism `Patrol` already has for the director's search
  hint, with its arrive 2 and its corner look) and **holds** there (stands, facing the way the focus will come), then
  the next hold point. With nobody counting (all backstage far away, or ignored) he walks the loops as today.
- **He mostly stands.** Between interactions he holds still at the hold point. When he moves, the move follows these
  rules, first match wins [P]:
  1. **Seen, he is heavy.** While any player has a clear line to him (`_seenBy` of anyone), his gait is `Heavy` (full
     volume, heard to 80), whatever he is doing. He never moves in a player's sight in near silence: the player asked
     for footsteps "so people know when hes around" [Q, Nov 15].
  2. **Out of hearing, he trails.** A leg whose every point stays `Leash.TrailClear` (30) or more straight from every
     player's ear, and out of everyone's view, is walked at `Leash.TrailPace` (11) with `gait: 'Creep'`. Nobody can hear
     it (creeping is heard to 22), and at 11 he keeps up with a walker (11, [G]) without a teleport. The route test
     samples the nav path's corners and its midpoints (at most 8 points per leg).
  3. **Near an ear, only short and quiet.** A leg that passes within 30 of an ear is walked at `CreepPace` (7), creeping,
     only when it is at most `Leash.CreepLeg` (10) studs long, or a player is within `Leash.Clear` (15) walked (he must
     get away). A longer one waits for that player's next slot and is made as the slot's H1 (far steps at 9) or H1b
     (running steps at 13): heard, and counted.
  4. **Falling behind.** More than `Leash.Max + 20` walked from the focus: when a slot of the focus is owed or comes
     within `PlanAhead`, he catches up as that slot's H1b (`RunPace` 13, heavy, counted); otherwise by rule 2 when it
     fits; otherwise he waits for the slot. Beyond 90 walked with no route back within `ApproachRun` (12) s: the
     approach, under 3.4 step 5 (b)'s limits.
  5. Anything of his that a player perceives outside an interaction anyway (a stray sighting, creeping heard within 22)
     is logged as `Stray` (4.0) and settles that player's clock by `HeardShare`.
- **The gait reaches the view.** `snapshot()` / `viewState()` gain `gait: 'Creep' | 'Heavy' | 'Run'`; `view.js`
  scales the footfall's volume by `Gait.CreepVolume` when `gait === 'Creep'` (its `_onFootstep` passes the volume to
  `footstepVoice`), and plays the rig's `Chase` cycle when `gait === 'Run'` (`profile.js` `Chase` has `footsteps.sprint
  = true`, so the voiced `CreatureStepChase<Surface>` keys play: `footstepVoice` in `view.js`). Co-op: `gait` rides on
  the `{t: 'cst'}` message (5.7).
- **The heartbeat follows the alarm, not the leash.** Today `web/src/creature/index.js senseNear` sets the panic floor
  (`nearFloor`, 0.27 at the edge rising to 0.7 within 6) whenever his eye is within `Presence.Audio.NearRadius` (45)
  straight and he is shown; the heartbeat starts at panic 0.25 [M 11]. With the leash at 25..55 walked that is nearly
  always, so the heartbeat would never stop, would stop meaning anything, and would tell his distance like a radar.
  v3: the radius is `Heart.Alarmed` (45) while the player's `alarmUntil > now`, else `Heart.Quiet` (15). `alarmUntil =
  now + Heart.Tail` (8) is set every tick while: an interaction that reached them runs, he chases them, he searches
  or investigates (`Search`, `InvestigateNoise`), he watches a hiding spot (`HidingResponse`), a teleport warning
  aimed at them runs, or a near miss on them runs. The service publishes it as `snapshot().alarm` (true when the
  page's player is alarmed) and, in co-op, as the `cst` field `al` per listener id (5.7). `index.js` and the
  first-time hint `CreatureNear` (`web/src/game/ui/hints.js`, which reads the same `Audio.NearRadius` today) read one
  shared function `heartRadius(snapshot, difficulty)`.
- **The rattle is the director's.** `monsterFx.js RATTLE_STATES` loses `Patrol`, `Peek`, `Glimpse`, `Shadow` and
  `PassBy`; it keeps `Teleport` (the stalk), `Search`, `HidingResponse`, `InvestigateNoise` and gains `NearMiss`. In
  Patrol the rattle plays only as H2's cue. `Audio.RattleRadius` goes; the remaining states use `Audible.CreatureRattle`
  (25) as their radius [P] (today 45: [C] `Presence.Audio.RattleRadius`).

### 3.7 Seeded streams and determinism (I8)

Every random number of v3 comes from `seededRandom(runSeed, key)` (`web/src/creature/util.js`: mulberry32 seeded
`seed XOR FNV-1a(key)`), never `Math.random`, never the frame:

| Key | Draws |
|---|---|
| `Lurk|Theta|<userId>` | each new `theta` of that player, and each new `lullIn` |
| `Lurk|Backstage|<userId>` | each backstage length of that player |
| `Lurk|Refill` | each token's refill time factor U(RefillMin, RefillMax) |
| `Lurk|Hide|<userId>` | each owed hide interaction's delay in `HideOwedMin..HideOwedMax` |
| `Lurk|Pick` | the type order of every plan, ties in who |
| `Lurk|Place` | choices among equal places inside a plan (H1's leg, H2's point, C4's first spot) |
| `Lurk|Length` | each interaction's length in `Min..Max` |

`runSeed` is new: `beginRun(opts)` takes `opts.seed` (the run's seed the game already has; the sims pass theirs),
else `RANDOM_SEED` (20251029, `service.js`), so a run without one plays as today. Per-player keys mean a teammate
joining or leaving never reshuffles another player's draws (the fake-out spots use the same idea, [M 8.3]).

Everything in section 3 runs on the brain tick, which is driven by the fixed game tick; nothing reads a render frame,
a tier or a pixel ([M 1.2], I10). So the same seed gives the same interaction log, and 20 fps and 144 fps play
identically; creature-sim's determinism case and tier-parity assert it (section 8).

---

## 4. The catalogue bound to the code

### 4.0 What every entry shares

**The record.** The service gains a Signal `interaction` (beside `stateChanged`, `teleportWarning`, ...). It fires
twice per interaction: `{phase: 'start', id, type, tier, body, target: userId, at}` and `{phase: 'end', id, type,
target, at, reached: {[userId]: 'heard' | 'seen' | 'both'}, outcome}` with `outcome` one of `done`, `broken` (a
player came within `Beats.BreakOff` 18 [C], or hid, or went into a duct), `chase` (it turned into a chase),
`stunned`, `lost` (setup failed or timed out). presence-sim and creature-sim listen to it; nothing in the game reads
it (the HUD never counts interactions, [R 3.8]). `snapshot().lurk` carries the lurk state for the dev overlay and the
sims (`LurkRules.snapshot`).

**Reached** (the test of "an interaction reached a player"; it must be perceivable). During the interaction, for each
player who counts:
- **heard:** the service registers every sound of his that the interaction plays (his footfalls from the animator's
  plants, and every cue in the lists below) with its key and position. A footfall counts when the player's ear is
  within `Audible.StepHeavy` (80) straight of it (`Audible.StepCreep` 22 while `gait === 'Creep'`); **two** counted
  footfalls reach them. A cue counts when their ear is within `Audible[key]` straight of where it plays, for at least
  `min(Reach.HeardSeconds, the cue's length)`.
- **seen:** `_seenBy(player)` (shown, within `Director.SeenRange` 80, inside `SeenHalfAngle` 50 of their look, a clear
  line to his eye or root [M 15.1]) true for `Reach.SeenSeconds` (0.3) in all.
The game's audio has no wall loss today (`web/src/engine/audio/`: distance roll-off only), so "heard" is straight
distance, as the player hears it.

**Records that are not planned** [P]. A chase's start is an interaction record of type `X` (its target, reached by the
screech), a near miss one of type `NearMiss`; both count in the gap measure (8.2). **`Stray`**: anything of his that
meets the reach rule while no interaction runs (a sighting he did not plan for, creeping steps heard within 22, the
catch-up run of 3.6 rule 4 when no slot was owed) is logged as type `Stray` and settles each player it reached by
`HeardShare` (3.2), so a stray sighting is not followed 3 s later by a planned one. The sim reports strays.

**The lead point** [P]. For a target of class `Sprint`, every placement below that is measured from "the player"
(S1's crossing, S2's and S3's stand point, H2's point, H1's leg, the leash's hold point) is measured from their **lead
point** instead: the floor lattice point nearest to `root + travel x speed x Leash.Lead` (5 s; about 95 studs at 19),
kept when its walk from the player is at most 1.5 x that straight distance and it is `nav.reachable`; else the lead is
halved once; else the player's own point. Their view tests (a clear line from their eye) still use their eye now and
at the lead point: a placement must pass both. The teleport already aims past a mover's lead this way ([M 7.2]:
speed x 2.2 s, about 42 for a sprinter). A sprinter covers 19 x 8 = 152 studs in an 8 s setup; without the lead point
H2, S1 and S2 are planned where the runner was.

**Every director-issued sound has variants** [P]. Each key the director issues (the cues of H1, H1b, H2, H4, C2, C4,
F, Reply, the near miss, C3 and the approach) has **at least 4 recordings**; `web/sounds/test.mjs` fails a director key
with fewer from stage 2 and reports it in stage 1. Rendered today (`web/build/audio/*/<Key>-<n>.mp3`): CreatureRattle 4,
CreatureSniff 4, CreatureStepWalk<Surface> 5 each, CreatureStepChase<Surface> 5 each, VentScrape 4, VentBreathing 5,
MetalCreak 3, LockerDoor 3, TorchStutter 3, WetBreath 2, TeleportHiss 2, Screech 2, ChaseSting 2, GiveUpSwell 2,
CreatureVanish 2. So LockerDoor, MetalCreak, TorchStutter, WetBreath, TeleportHiss, Screech, ChaseSting, GiveUpSwell
and CreatureVanish need more variants rendered from their recordings (`web/sounds`, the CC0 pipeline). The bank never
plays the same variant twice running (`web/src/engine/audio/bank.js`). H2 also varies its order by `Lurk|Place`:
rattle then breath, breath alone, rattle alone.

**Voice offers** (section 7). Inside three interactions the lurk director offers the voice director an event line:
`NearMiss` (as he turns away), `PassBy` (C2, beside a hider or as he passes), `Peek` (S2 and S3, as he withdraws).
They ride inside those interactions and are not counted as extra ones; `Voice.PerPlayer` and `PerTeam` ration them
with H5.

**Where the `Audible` numbers come from** [P until measured]. `Footfalls.HeardTo` 80 is measured: his quietest step
stands 7.3 to 9.7 dB over the Basement's drone and dread bed at 80 studs (`docs/SOUND.md` 12). Creeping at volume
0.25 is 12 dB lower; at about 6 dB per doubling of distance that is two doublings, 80 / 4 = 20, and the 1.3 to 3.7 dB
of spare margin moves it to about 22 (`StepCreep`). Every other entry is about half the distance at which its preset's
roll-off falls silent (`rollOff.max`: CreatureRattle 55 and TeleportHiss 70 in `web/src/creature/sounds.js`; WetBreath
50 and NailsOnMetal 40 in `web/src/game/story/sounds.js`; the rest in their SynthPresets entries), rounded down. Stage 1
extends `web/tools/audio-test.mjs` to measure each key it uses the way it measures the footfalls (the quietest variant,
through the game's engine, against the Basement's beds, 6 dB rule); a key that measures shorter than its table entry
gets the measured number (the sound is never raised past `docs/SOUND.md` 3's loudness rules to make the table true).

**Art on hold.** Every entry has a **today** version made only from the rig's existing states (`Patrol`,
`Investigate`, `Chase`, `VentCrawl`, `VentRetreat`, `Stunned`, `Dormant` in `profile.js States`), its pose modes
(`Biped`, `Hunched`, `Quadruped`), its actions (`Stare`, `ReachIn`, `LookAway`, `FadeOut`, `FadeIn`, `Jumpscare`,
`NeckSnap`, `Lunge`, `LockerRip`, `DoorSmash`, `Vanish`, `Reveal`) and voiced sound keys (`web/sounds/cast.json` status
`voiced`). Where better art would help, it is listed as **later (art)**; game-spec-v2 3.6 already requires a
MONSTER-LOOK table before any new action, so none of it is in stages 1 to 3.

Notation: "walked" is `FloorNav.pathLength`; "unseen" is `_inViewOfAnyone(point)` false (his head and chest out of
every player's 80° view with a clear line, [M 7.1]) unless a stricter `_visible` is named; "dark" is
`env.litAt(point + 1, Senses.LitIrradiance)` false.

### 4.1 H1 Far steps (tier 0)

- **Implements:** Patrol lurk mode, a new order `ctx.lurkMove = {point, pace: Leash.StepPace, gait: 'Heavy', until}`
  that `states/patrol.js` walks like `ctx.hint` (new branch, about 30 lines). The steps are the animator's own plants
  (`view.js _onFootstep`), nothing new.
- **Feasible:** he is unseen; the target's ear is within `Audible.StepHeavy` (80) straight of him now and of the leg's
  end; he is 30..70 walked from them [R 3.2] (the leash guarantees 25..55: when he is under 30, the leg must end 30 or
  more walked from them).
- **Placement:** the leg's end is the next leash hold point (5.5) when it is 8 to 25 walked away [P], else the floor
  lattice point (`nav.samplePoints(5)`) 10..20 walked from him [P] that keeps him unseen and between 30 and 70 walked
  from them, preferring a leg across their way (the cosine of their travel with the leg under 0.5), first by
  `Lurk|Place`.
- **Length:** `Types.H1` 4..6 s (`Lurk|Length`): about two to three footfalls at 9.
- **Sounds:** `CreatureStepWalk<Surface>` (voiced; `view.js` via `CreatureStepSurface`).
- **View:** the `Patrol` walk at 9, `gait: 'Heavy'`. Today's rig. Later (art): none needed.
- **Ends:** the leg's time, or arrival; then he holds (3.6).
- **The tell stays true** [P]: for `Clock.TellHolds` (12) s after far steps reached a player, his next hold point lies
  on the same side of that player (`tellSide`), and no C3 or approach is aimed at them (3.4 step 5).
- **Counterplay seen working:** stop and listen; the steps tell the side he is on, and for the next 12 s he is still
  there; take the other way.
- **Sim:** the `interaction` record; reached by two heard footfalls.

### 4.1b H1b Running steps (tier 0; stage 1)

- **Implements:** Patrol lurk mode, `ctx.lurkMove = {point, pace: Leash.RunPace, gait: 'Run', until}`: the view plays
  the rig's `Chase` cycle, so the voiced `CreatureStepChase<Surface>` keys play (3.6). He is never seen doing it.
- **Feasible:** he is unseen and stays unseen along the leg; the target's ear within `Audible.StepHeavy` (80) straight
  of him at the leg's start; the leg ends 30 or more walked from everyone [P] and out of everyone's view; the leg is
  `RunPace x Length` long at most (26..39 studs). It is the type that keeps up with a runner: it is also the
  catch-up of 3.6 rule 4.
- **Placement:** the lattice point toward the focus's lead point (4.0) that keeps him unseen and ends the leg 30..55
  walked from them, across their way first (`Lurk|Place`).
- **Length:** `Types.H1b` 2..3 s: about four to six fast footfalls.
- **Sounds:** `CreatureStepChase<Surface>` (voiced, 5 recordings each).
- **View:** the `Chase` cycle at 13, `gait: 'Run'`. Today's rig. No chase music: it is not a chase.
- **Ends:** the leg's time, or arrival; then he holds.
- **Counterplay seen working:** something is running close by and you cannot see it: stop, look, change the way; it
  is gone when the steps stop.
- **Sim:** reached by two heard footfalls.

### 4.2 H2 Behind the wall (tier 0, body)

- **Implements:** Patrol lurk mode: `ctx.lurkMove` to the point at `CreepPace`, `gait: 'Creep'`, then
  `mover.hold(length, facing the player)`; the cues are played by the service (`env.play(key, {position: eye})`) and
  registered for reach. New service method `_lurkCue(key, position, opts)` (plays, registers, and in co-op broadcasts,
  5.7).
- **Feasible:** a floor lattice point P with: `Leash.Clear` (15) or more walked from every player; 15..25 walked from
  the target [R 3.2, 10..25, raised to `Clear`]; at least one wall between his eye at P and their ear
  (`env.countOccluders(a, b, 3) >= 1`, the hearing's own wall count); their ear within `Audible.CreatureRattle` (25)
  straight of his eye at P; P unseen by everyone (`_visible(P)` false: no clear line from any eye at any angle, the
  stricter test, since he holds there); he reaches P within `Types.H2.Setup` (8) s at `CreepPace` (walk <= 56).
- **Placement:** of the lattice points within 25 straight of the target (on their floor, `|dy| < 6`), nearest him
  first, the first 10 asked (`beats.js EVALUATE`).
- **Length:** 2..3 s.
- **Sounds:** `CreatureRattle` (voiced, his throat) at his eye at the start, then `WetBreath` (voiced, his breath,
  `game/story/sounds.js`) 1 s later. Later (sound): NEW `CreatureNailsWall`, his nails dragged along plaster (his
  recordings only, `docs/SOUND.md` 3.7); until then no nails.
- **View:** standing (Patrol idle), facing them through the wall. Nobody can see it by construction.
- **Ends:** the length; or any player within `Clear` walked (he creeps off at once to the next hold point); or a chase
  trigger (5.3, 5.6).
- **Counterplay seen working:** keep still and quiet: he moves on and the creeping steps fade away (heard to 22). Make
  a loud noise with a token in the bucket and he comes round the wall (5.3).
- **Sim:** reached by either cue heard.

### 4.3 H3 In the vents (tier 0, body; stage 2)

- **Implements:** the new `Crawl` state (5.4): he crawls a crawlway or a duct leg near them.
- **Feasible:** a crawlway (a room of kind `Crawlway` on their floor; 33 in the world [W]) or a duct segment
  (`ventgraph.js`, the Hallways only [W]) with some point within `Ducts.HearRange` (25) straight of the target's ear;
  he can reach one of its mouths within `Setup` (8) s, unseen, and enter it unseen (the mouth not in anyone's view);
  no player inside that crawlway or duct (H3 is never a shared crawl); its far mouth leaves him 15 or more walked from
  everyone (`Clear`).
- **Placement:** the nearest such crawlway to him by walk, then the nearest duct; ducts through grates per 5.4.
- **Length:** 3..6 s of crawling (a culvert is 8..18 long [W]: 1.3..3 s at `Ducts.Pace` 6; he crawls it, waits
  inside up to the length, and leaves by either mouth that is clear of players by `Ducts.MouthClear` and unseen).
- **Sounds:** `VentScrape` and `VentBreathing` loops (voiced; `view.js _updateLoops` already plays them whenever the
  snapshot says `inVent`). Later (sound): NEW `DuctKnock`, a knuckle knock on sheet metal, his; until then the scrape.
- **View:** `VentCrawl` (quadruped, `profile.js`) via `snapshot().inVent = true` and `pose 'Quadruped'`: today's rig.
- **Ends:** the length; a player entering that crawlway (he leaves by the far mouth, 5.4).
- **Counterplay seen working:** do not take that hole now; wait, hear the scrape go away, then use it.
- **Sim:** reached by either loop heard (`VentScrape` / `VentBreathing` registered as cues for the crawl's duration).

### 4.4 H4 Environment (tier 0, body)

- **Implements:** Patrol lurk mode to a hiding spot's front, hunched (`body.setPose('Hunched')`, as `search.js` does at
  a spot), then a new `Lockers.nudge(spotId)` in `web/src/game/mechanics/lockers.js` (about 30 lines on its own
  `_startDoor`: the door opens to `Nudge.Open` 0.3 and swings back over `Nudge.Shut` 1.2 s to `Nudge.Ajar` 0.15, where
  it **stays ajar** until a player uses that spot or `Nudge.AjarSeconds` (120) pass [P]; `_startDoor` already pushes
  the `LockerDoor` cue at the door point). Reached through a new creature env hook `nudgeSpot(id)` (as
  `registerLockerInspector` is wired). Co-op: the `'nudge'` mechanics event carries the ajar state (5.7).
- **Feasible:** a hiding spot with a door (`DoorRest`; barrels have none) that nobody occupies
  (`_hideSpotOccupant`), whose front is 12..30 walked from the target [R 3.2], `Clear` or more walked from everyone,
  unseen (`_visible`), with their ear within `Audible.LockerDoor` (22) straight of the door point; reachable in 8 s.
- **Placement:** `env.hideSpots(level)` filtered, nearest him first.
- **Length:** 1..2 s.
- **Sounds:** `LockerDoor` (voiced, the locker's own) at the door. It is not the ambience's `DreadLockerRattle`
  (`DreadConfig.Ambience.Events`), so the two can be told apart; the ambience also plays its events 2.5 times further
  apart and at 0.4 volume while he is within 60 (`DuckRadius`, `DuckGapScale`, `DuckVolume`), so near him a locker is
  him. Later (sound): door creaks, a chair, a bulb at real props, when the props have hooks.
- **View:** hunched at the front (Patrol idle, `Hunched`); the door really moves. Today's rig.
- **Ends:** the nudge's end; then he creeps off.
- **Counterplay seen working:** go round that room; looking in later shows the door he moved, still ajar (a trace
  that he was there, true for two minutes).
- **Sim:** reached by `LockerDoor` heard.

### 4.5 H5 Spoken line (tier 0, body; the hook and its stub in stage 1, section 7)

- **Implements:** section 7's hook; `Voice.Enabled = 0` makes its weight 0 until recorded lines exist.
- **Feasible (when enabled):** as H2 (behind a wall, 10..35 walked [R 3.2], `Clear` kept) or a grate between them;
  the VoiceDirector accepts the offer (section 7).
- **Length / sounds / view:** the line's length; his recorded line at his head (Head channel), the subtitle; Patrol
  idle. **Today:** never drawn.
- **Sim:** reached when the line's audio is heard within its `Audible` (set when the voice files are measured).

### 4.6 S1 Glimpse (tier 1, body)

- **Implements:** `beats.js planGlimpse`, `states/glimpse.js` (unchanged).
- **Feasible:** `planGlimpse` (crossing J 30..70 ahead within 35°, its head in their view; ends A and B 6..16 from J
  out of everyone's sight; the player not cornered, a hiding spot within 25 walked, every stand point 25 walked from
  everyone [M 16]); strain under `SeenBelow`; after `FirstSeen`. For a Sprint-class target, J is measured from their
  lead point (4.0): `planGlimpse` takes an optional `from` point (about 10 lines in `beats.js`).
- **Length:** 1..2 s seen (walks to A at 9, crosses at 12, [C] `GlimpsePace`).
- **Sounds:** his footfalls at full volume while crossing (`gait: 'Heavy'`).
- **View:** `Patrol` walk; today's rig.
- **Ends:** at B; a player within 18 (it withdraws, [M 16]).
- **Counterplay seen working:** stop and wait: he crosses and is gone; change route.
- **Sim:** reached by `seen` (0.3 s) or heard steps.

### 4.7 S2 Peek (tier 1, body)

- **Implements:** `planPeek`, `states/peek.js` (unchanged).
- **Feasible:** `planPeek` [M 16.1]; strain under `SeenBelow`.
- **Length:** hold 1.5..3 s ([C] `PeekHoldMin/Max`).
- **Sounds:** none while he holds [P] (the silence is the scare); his steps creep (`gait: 'Creep'`) to the corner.
- **View:** `Patrol` idle facing them, head tracking them (`getTarget` publishes the beat's player); today's rig.
  Later (art): a lean round the corner (a new action; MONSTER-LOOK table first).
- **Ends:** hold over, back to the corner; a player within 18: he withdraws. As he withdraws, a `Peek` voice offer
  (4.0, section 7).
- **Counterplay seen working:** back off: he withdraws; stare 1 s and a chase starts (if a token exists) or the near
  miss (5.6).
- **Sim:** reached by `seen`. For a Sprint-class target S is measured from their lead point (4.0).

### 4.8 S3 Vantage (tier 1, body; stage 1)

Moved from stage 3 to stage 1 [P]: it is small on today's rig, it is one of the eerie ones (him standing at the
dark end of a corridor, watching), and it needs no timing against a runner, so a sprinter gets a seen interaction
that is not a teleport.

- **Implements:** a Peek with a different hold: `planPeek` called with `mode: 'Vantage'` (a new `planVantage` wrapper in
  `beats.js`: stand point 35..60 **walked** [R 3.2] and dark, else `planPeek`'s rules), `states/peek.js` gains a
  `Vantage` hold rule (about 30 lines).
- **Feasible:** as Peek, plus the stand point dark; strain under `SeenBelow`. A Sprint-class target: from the lead
  point (4.0).
- **Length:** 2..6 s.
- **The target's stare does not count while a vantage plays** [P] (other players' stares count as always): the
  first version's taught answer, "put the torch on him", stood 35..60 walked away, while the stare counts to 45 with
  the torch on at 1.0 s within 7° [M 3.3] and the torch's lit spot reaches only 30 [M 17.1]: between 30 and 45 the
  answer started a chase or a near miss.
- **Ends:** (a) the target looks straight at him with the torch on: his head within `Vantage.TorchAngle` (7°) of their
  look, a clear line, within `Vantage.TorchRange` (80), for `Vantage.TorchSeconds` (0.5 s) in all: he **steps back to
  his corner** at 7 (out of sight); only when the plan has no corner left, the `FadeOut` action (`CreatureVanish`
  where he stood, `monsterFx.js`) with `_giveUp`'s destination rule (45 or more from every eye, unseen, [M 7.1]);
  (b) they look away (his head out of their 50° for 0.5 s): he steps back to the corner; (c) 6 s: he steps back. A
  `Peek` voice offer as he steps back.
- **Sounds:** none; his footfalls `Heavy` as he steps back in view (3.6 rule 1).
- **View:** Patrol idle at the dark end; walk back. Today's rig.
- **Counterplay seen working:** put the torch on him and he backs into the dark; or back away.
- **Sim:** reached by `seen`.

### 4.9 S4 Hole crawl (tier 1, body; stage 2)

- **Implements:** the `Crawl` state (5.4) with a **fold-in** in the target's view: he walks to a crawlway mouth that
  their eye sees, folds in (stands still `Ducts.Fold` 1.2 s, `Hunched`, facing the hole), then crawls in
  (`Quadruped`, `inVent`).
- **Feasible:** a crawlway mouth 15..35 walked from the target [R 3.2] (and `Clear` kept), its floor point in their
  view (a clear line from their eye within 80, `headSeenBy` at the mouth with the hunched head), reachable unseen
  within 20 s up to a point 6 [P] from the mouth; the crawlway empty of players; the far mouth unseen and clear.
- **Weight:** x `FirstHoleWeight` (3) for a player with `seenHole` false (until each player has seen one this run) [P].
- **The seen exit** (also tier 1, counted as S4) [P]: he may come **out** of a mouth in a player's view when that
  mouth is `Ducts.MouthSeenWalk` (30) or more walked from everyone; `MouthClear` (12 straight) still holds. The
  player asked for the holes twice [Q, Nov 16]; a fold-in alone at 3 % of interactions would be seen about once
  every two floors.
- **Length:** 1.5..3 s seen.
- **Sounds:** `VentScrape` + `VentBreathing` once inside (view loops).
- **View:** today: `Hunched` for the fold, then `VentCrawl`; the animator blends states. Later (art): a real fold (legs
  last into the hole), his long fingers through grate slats.
- **Ends:** inside; he crawls out the far side (or waits, then out) per 5.4.
- **Counterplay seen working:** that hole is his: avoid it for a while; the scrape tells when he left.
- **Sim:** reached by `seen` during the fold.

### 4.10 C1 Shadow (tier 2, body)

- **Implements:** `planShadow`, `states/shadow.js`; length `Beats.ShadowMinSeconds/MaxSeconds` changed to 10..20 (2.4).
- **Feasible:** `planShadow` [M 16.3]: the player moving 3..14, him 30..70 walked behind them; strain under
  `CloseBelow`; after `FirstSeen`.
- **Sounds:** his footfalls in time with theirs (`gait: 'Heavy'`), and one `CreatureRattle` when he stops after they
  stop [P] (an "extra step").
- **View:** Patrol walk / idle; freezes under their look (existing). Today's rig.
- **Ends:** time; they hide or enter a duct; a long look is the stare (chase or near miss).
- **Counterplay seen working:** look back: he freezes; break the line or hide.
- **Sim:** reached by heard steps or `seen`.

### 4.11 C2 Pass-by (tier 2, body)

- **Implements:** `planPassBy`, `states/passby.js` (unchanged), plus one `CreatureSniff` cue at P [P].
- **Feasible:** `planPassBy` [M 16.4]: player moving no faster than 6; P 18..28 from them, 20 walked; strain under
  `CloseBelow`. In the `Hiding` class it is in `FitOf.Hiding` (x2) and first for an owed hide (5.2).
- **Length:** 6..12 s.
- **Sounds:** his steps at 7, `gait: 'Heavy'`; `CreatureSniff` (voiced, his sniff) 1.5 s at P; a `PassBy` voice offer
  at P (section 7).
- **View:** Patrol walk; today's rig.
- **Ends:** at E; a sighting of a noticed player (his own senses) who is not hiding and not defending (5.6): chase
  with a token, else the near miss.
- **Counterplay seen working:** hide or keep out of his cone in the dark: he walks on past.
- **Sim:** reached by heard steps / sniff, or `seen`.

### 4.12 C3 Warned teleport (tier 2, body)

- **Implements:** today's teleport (`_planTeleport`, `_teleportSpot`, `_startTeleport`, `states/teleport.js`, the warp
  machine `_stepWarp`), issued by the director instead of `_teleportDue`'s timer: `teleportReadyAt` keeps only its
  first-of-floor rule (grace + 45 s, [M 7.2 (4)]) and the catch / down / blocked gates; the U(60, 120) [U(40, 80)]
  cooldown is no longer read on the website (2.4).
- **Feasible:** `_planTeleport` finds a spot for the target (12..24 walked; ahead 24..70 past their lead for a mover);
  every gate of [M 7.2] except the timer; strain under `CloseBelow`; fewer than `Clock.WarnMax` (2) teleport warnings
  aimed at the target in the last `WarnWindow` (180) s; no heard interaction reached them within `TellHolds` (12) s.
  Approach and C3 together are one item in the type-share gate, at most 25 % of a profile's interactions (8.3).
- **Length:** 1.6 s warning + 10 s stalk (`Types.C3` 1.6..11.6).
- **Sounds:** the trio (lights stutter, `TeleportHiss` at the spot, `TorchStutter` on the target's page), `RevealSting`
  on the reveal (all voiced, I2).
- **View:** `FadeIn`, `Stare` (today).
- **Ends:** the stalk's end; a sighting of a noticed player within `StalkSight`: chase with a token, else near miss.
- **Counterplay seen working:** turn, sidestep, hide: the stalk passes.
- **Sim:** reached by the hiss heard (registered as a cue at the spot) or `seen`; the teleport test of section 8.

### 4.13 C4 Sniff (tier 2, body)

- **Implements:** `states/search.js` with an ordered spot list: new `ctx.searchSpots` (when set, `enter` uses it
  instead of the shuffled `hideSpotsNear`, and the deadline is `Types.C4.Max`); the breath check is `Sniff.inspect`
  with one option (below).
- **A director-issued C4 never spends a token and never downs anyone** [P]. Its `Caught` verdict is always the locker
  near miss: `Screech` at his eye, `Lockers.nudge` on that spot (the door rattles), and he leaves; no ReachIn. A breath
  check catches only inside an encounter the hider caused (seen getting in during a chase, or the search after a
  chase: 5.6). Hiding is the careful player's answer; a sniff he did not bring on himself must not kill him.
- **The window is fair to an early breath** [P]. The neighbour-first staging baits the breath early: from the first
  sniffing sound at the neighbour to the end of the window at his own door is 1.3 s (empty spot) + about 1 s + 0.9 s
  (warning) + U(3.5, 6) s [M 8.1], and a 7 s breath held from the first sound runs out inside the window in 88 % of
  draws. So for a director-issued C4, `Sniff.inspect` takes `{maxWindow: breathLeftAtWarning - Sniff.BreathMargin}`:
  the window is `max(Sniff.MinWindow, min(drawn, breath left at the warning - 0.5))`. Holding from the first sniff is
  then always enough (the review proposed refilling the breath meter instead: rejected, part 12).
- **Feasible:** the target is hiding (class `Hiding`), or stands within 10 of a free spot [P]; another spot with a
  front 3..10 from theirs [R 3.2]; both reachable within 20 s; strain under `CloseBelow`; never on a spot he saw them
  enter during an encounter (that is HidingResponse, 5.6).
- **Placement:** the neighbour first (`Lurk|Place` among equals), then theirs.
- **Length:** 4..16 s (2.3).
- **Sounds:** `CreatureSniff` at the slits (`lockers.js` already plays it during a check), the breath check's own cues.
- **View:** `Investigate` (Search) with `Hunched` at each spot; today's rig.
- **Ends:** both spots done; the verdict.
- **Counterplay seen working:** hold your breath when the sniffing reaches you: he moves on. Fail, and the door
  rattles under his screech: a scare, not a catch.
- **Sim:** reached by `CreatureSniff` heard; `outcome` records the verdict.

### 4.14 F Fake tell (tier 0; stage 1)

Moved from stage 3 to stage 1 [P]: today's sounds and walk, and it keeps far steps from becoming a sure sign.

- **Implements:** Patrol lurk mode, `ctx.lurkMove` toward the target at `StepPace`, `gait: 'Heavy'`, that stops after
  its length; he then holds still and silent at least 5 s [P].
- **Feasible:** as H1, the leg pointing toward them (cosine over 0.5) and ending `Clear` or more walked from everyone;
  never the floor's first interaction; never twice in a row on a player; at most `Fake.OneIn` (1 in 10) of a player's
  interactions (`fakes / count`); strain no gate.
- **Length:** 1.5..2.5 s.
- **Sounds:** `CreatureStepWalk<Surface>`; then nothing.
- **View:** Patrol walk then idle. Today's rig.
- **Counterplay:** none needed: it teaches that steps that stop may be nothing, which keeps H1 from being a sure sign.
- **Sim:** reached by two heard footfalls.

### 4.15 X Chase (tier 3)

- **Implements:** `states/wallchase.js`, unchanged, entered only with a token (5.6). Cap `Chase.CapSeconds` 8 / 12 / 45.
- **Sounds:** `Screech` (at his eye), `ChaseSting`, `ChasePulse`, `GiveUpSwell` (voiced).
- **Ends:** [M 6.5] / [M 18].
- **Counterplay:** outrun (19 against 16.5), break the line, hide, the flask.
- **Sim:** today's chase record (and `CHASE_CHAIN` 20 = `Chase.ChainSeconds`); its start is also an `X` interaction
  record (4.0) and counts in the gap measure.

### 4.16 The director's extra moves

- **Approach** (`Types.Approach`): today's approach teleport (`_planApproach` / `_startApproach`), the fallback of 3.4
  step 5 (b) only: more than 90 walked away, no route back within 12 s at 13, at most `WarnMax` (2) warnings per
  player per 180 s, not within `TellHolds` (12) s of a heard tell. Tier 0 in the clock (it is mostly heard: the hiss).
  The approach that **starts a stint** (5.1) lands where the arriving group hears its hiss: the landing within
  `Audible.TeleportHiss` (40) straight of a player of that group, still 45..80 walked [C] and out of view. The
  approach plays the lights' flicker and the hiss but **not** the target's `TorchStutter` [P] (C3 keeps it): a runner
  in a dark maze no longer gets his torch flickered every 25 to 40 s.
- **NearMiss** (`Types.NearMiss`, 5.6): a new state `states/nearmiss.js` (about 90 lines):
  1. `Screech` at his eye **and `ChaseSting` for the target** (the scare must not become readable as harmless; no
     `ChasePulse`, since no chase follows) [P]; the wind-up hold of `Chase.Windup` (1.5 [0.7]) facing them, the
     `NeckSnap` action [P] at its start (exists in `profile.js Actions`);
  2. `Chase.FeintSteps` (6) studs toward them at the chase pace (never nearer than 6 straight, no catch possible in
     this state);
  3. he turns away: `GiveUpSwell` for the target as he turns [P]; a `NearMiss` voice offer (section 7);
  4. he leaves, first that fits [P]: a walk out of their sight within 3 s (`repositionPoint`); else he **backs away
     facing them** at `Chase.BackAwayPace` (9) for at most `BackAwaySeconds` (6) until out of sight (the animator
     backpedals past about 105° between travel and facing: `animator.js` `backward`); from stage 2, a fold into a hole
     whose mouth is within 20 walked; the `FadeOut` with the give-up relocation **last**.
  Strain: the target goes backstage (3.3). Squad-wide, no two near misses within `Chase.NearMissSquad` (25) s: the
  second trigger gets the silent slip-away (5.6). Today's rig; later (art): a lunge that stops short.

### 4.17 Reply (tier 0; stage 1): his answer to a loud noise without a token

- **Implements:** Patrol lurk mode, `ctx.lurkMove` toward the noise at `StepPace` (9), `gait: 'Heavy'`, for
  `Reply.StepsMin..StepsMax` (3..4) footfalls, then he stops and holds, silent.
- **Feasible:** a one-off High or Critical noise (NoiseKinds priority, `web/src/engine/config.js`: DoorSlam
  Critical, FlaskShatter High; the kinds of `Clock.Lumps`) that his hearing registered, with no token
  (`Summary.token` false). A sprint's continuous footsteps (High, 60 [M 17.4]) are not a one-off noise: the clock
  already answers them (Gap.Sprint). He is not in an interaction or an encounter; the leg ends `Reply.EndClear` (15)
  or more walked from everyone and out of everyone's view; the noise's maker (if any) not backstage.
- **Starts:** within `Reply.Within` (4) s of the noise. It goes before other orders (3.4 step 3) and passes every
  team gate but `Clock.Team`; one at a time; at most one reply per player per `Types.H1.Cooldown` (20) s [P].
- **Settles:** like any interaction (3.2): the target is the noise's maker, else the nearest player who heard it.
- **Sounds:** `CreatureStepWalk<Surface>` (voiced).
- **Lure:** a noise that sounds `Reply.LureFar` (12) or more from its maker (a thrown flask, a slammed door far
  off) also sets `lure = {point, until: now + Reply.LureHold}` (15 s), token or not: the leash's next hold points lie
  on that side (5.5). With a token the noise draws him as today (5.3).
- **Counterplay seen working:** slam a door, throw a flask: he answers, and he goes where the flask landed.
- **Sim:** reached by two heard footfalls.

---

## 5. The director

### 5.1 Who

Of the players who count (3.2) and are owed (3.4 step 3):
1. squads of two or more: a player with `now - lastReachAt >= Coop.Starve` (60) goes first, the longest first;
2. **the stint** [P] (squads of two or more): once he gives an interaction to a group (the target and every counting
   player within `Coop.GroupRange` 15 of them), `stintGroup` is that group; while `now - stintAt < Coop.Stint` (45) and
   `stintCount < Coop.StintCount` (3), only players of `stintGroup` may be chosen (rule 1 aside). A stint ends early
   when nobody of the group is owed and someone outside it is owed by more than 0.5. Reason: with one body and two
   groups 150 studs apart, the first version flipped the focus on every order, every flip an approach teleport, and
   he never stayed the 20 s a body interaction needs (review, P12);
3. else the highest score `(due - theta) x (alone ? Alone : 1) x (loud ? Loud : 1) x (strain > StrainedOver ? Strained
   : 1)` (1.5, 1.3, 0.5 over 0.5; `alone` within `AloneRange` 25, `loud` within `LoudWindow` 20 [R 3.3]);
4. ties: the longest since `lastReachAt`, then the lowest `userId`.

Section 1 says it as the player sees it: a split squad shares him in turns.

### 5.2 What is feasible, and the weights

A type is feasible for the chosen player when all hold:
- **class:** the player's class is not `Duct` or `Hiding`, or the type is in `Only[class]` (`Duct`: H3, H5, S4;
  `Hiding`: C2, C4, H1, H2);
- **strain:** tier 0 always; tier 1 only with `strain < SeenBelow`; tier 2 only with `strain < CloseBelow`; a backstage
  player only tier 0;
- **floor:** tier 1 and 2 only after `floorAt + FirstSeen`; the floor's first interaction is tier 0;
- **timers:** `now >= cooldownUntil[type]`, `now >= retryUntil[type]`, `type !== lastType` (for every order, the
  fallback included); and it would reach no player within `Clock.SamePlayer` (10) of their `lastReachAt` (a heard-only
  type is held, not dropped);
- **teleport warnings** (C3, the approach): the target has had fewer than `WarnMax` (2) in the last `WarnWindow`
  (180) s, and `now - heardAt >= TellHolds` (12);
- **body:** a body type only when no body interaction is active and `now - lastBodyStartAt >= Clock.TeamBody`;
- **built:** H3 and S4 from stage 2; H5 only with `Voice.Enabled = 1`. Every other type, S3 and F included, from
  stage 1;
- **its own rule** (section 4: F's share and order rules, C3's teleport gates, each geometry test), asked last because
  it costs path queries.

**The owed hide** [P]. A player who gets into a spot within `Clock.HideAfter` (20) s after an interaction reached
them, and who is not backstage, gets `hideOwedAt = now + U(HideOwedMin, HideOwedMax)` (12..20 s, `Lurk|Hide|<id>`): at
that time they are owed one interaction whatever their `due` (it settles as usual). Its types: C2 and the non-lethal
C4 first (drawn between them by weight; tier 2 strain gate as usual), then H2 if neither fits. Later interactions in
the same hide come at the `Hiding` gap (75). The stay limit shoves a hider out at 45 s [M 8.2], so without this a hide
owed only at the 75 s gap got nothing: the first version's locker was dead air.

**Weight** = `Types[type].Weight x (type in FitOf[class] ? Fit : 1) x tierFactor x spend x hole`, where `tierFactor`
is `(ProgressClose + p) x CloseScale` for tier 2, `ProgressHeard - p` for tier 0 and 1 for tier 1; `p` = the floor's
objective steps done / total, 0..1 (a new creature env hook `floorProgress()`, answered from the floor's objective
tracker; 0 on a stage without one); `spend` is `Chase.SpendWeight` (3) for C3 and C1 when the bucket has been full for
`Chase.SpendAfter` (30) **and** the player is of class Sprint or Walk or was loud (High or Critical) within
`Chase.SpendLoud` (60) s, else 1 [P]: a quiet croucher, a still player or a hider is never pushed toward the
interactions that lead to a chase, so sneaking well is not punished; `hole` is `FirstHoleWeight` (3) for S4 while the
player's `seenHole` is false (stage 2), else 1.

**Order.** The feasible types (without the geometry) are drawn by weight without putting back, with the `Lurk|Pick`
stream (the way `beats.js planBeat` draws its beats); the geometry of each is asked in that order; at most
`Budget.GeometryTries` (3) geometries per step; the first that fits is the plan.

Check of the weights (arithmetic, every type feasible, H5 at 0, no Fit): at `p = 0` tier 0 has `(10 + 8 + 8 + 8 + 8 +
2) x 1.5 = 66` (H1, H1b, H2, H3, H4, F), tier 1 `8 + 8 + 6 + 5 = 27`, tier 2 `(5 + 5 + 5 + 3) x 0.5 = 9`: 65 / 26 /
9 %, near the research's first-third mix [R 3.3] (60 / 30 / 10). At `p = 1`: 22 / 27 / 27, that is 29 / 36 / 36 %
(research: 35 / 35 / 30). Feasibility shifts both; the sim measures the mix (section 8).

### 5.3 His ears and the token (no double count)

Today a heard noise sends him to look (`brain.js decide`, "heard a noise, outside InvestigateNoise and Search ->
InvestigateNoise"; the torch's glow is heard the same way, [M 17.1]). In v3 the clock is his answer to a player's
noise, so:

- `Summary` gains `token` (5.6: a token is in the bucket, or an encounter is running; false for a noise whose maker
  is backstage, 3.3) and `alerted` (the tick's loudest heard noise is a scripted `alert()`).
- `decide`: the row `s.heard > 0 && !SEARCHES.has(state) -> InvestigateNoise` becomes `s.heard > 0 && (s.token ||
  s.alerted) && !SEARCHES.has(state)`. Without a token he still hears (the heard rooms, the memory and `loudAt` are
  kept: `loud` weighs in 5.1) and the player's lumps raise their clock (3.2), and he does not walk over.
- **Without a token he still answers** [P]: a one-off High or Critical noise he heard gets the **Reply** (4.17)
  within 4 s: three or four heavy steps toward it, then silence. A noise that sounds 12 or more from its maker moves
  the leash's hold point to its side for 15 s (`lure`, 5.5), token or not. So luring him with noise works
  ([Q] Nov 16 15:20, "luring him with noise", part of "more fun"), and an empty bucket cannot be read from his
  behaviour: a slam is always answered; only what follows (a walk over and a look, or nothing) depends on the token.
- Inside an encounter (a chase, its search, a hiding watch) every row of today stays.
- Scripted alerts (a level scene's `alert(position, priority)`) are game-authored and keep today's rule.

### 5.4 Crawlways and ducts: his backstage (stages 1 and 2)

**The map.** 33 crawlways [W], each a straight culvert with exactly two crawl-only doorways into walkable rooms; one
duct network (Hallways: 4 nodes, 2 grates [W]) read by `ventgraph.js`. `nav.js` gives the Creature no floor in a
crawlway and shuts crawl-only portals (`NO_FLOOR`, `portalFlags`); that stays: the mover never routes through a hole.

**Crawl edges** (new, `web/src/creature/crawl.js`, pure): for each Crawlway room, its two crawl-only `layoutDoors`
give two **mouths**: the floor point 2 studs [P] into the walkable room in front of each doorway, and the culvert's
centreline between them (`length` = doorway to doorway). For each duct (`ventgraph.buildGraph`): each grate's
`mouth` (the rail point just inside the room face) and the rail between grates (`path(graph, from, to, blocked)`).
The director's walk estimates may add a crawl edge (walk to a mouth + the edge's length + walk from the other mouth):
that is how the leash and H3 / S4 placement "know" the holes; the mover itself never does.

**The `Crawl` state** (new, `states/crawl.js`, stage 2; Brain: like a beat, not interrupted by noises; a sighting
within 12 or a stare is handled as in a beat):
1. **Approach:** walk to mouth A (unseen, at `CreepPace`).
2. **Fold:** stand still `Ducts.Fold` (1.2) s, `Hunched`, facing the hole (S4 is this phase in someone's view).
3. **Crawl:** kinematic (`body.setAnchored(true)`, `body.placeAt` along the centreline each motion tick, as
   `body.js` already does for "the vent rail"), `body.setPose('Quadruped')`, `snapshot().inVent = true` (today
   hard-coded false), at `Ducts.Pace` (6), or `Ducts.SharedPace` (3.8) while any player is inside that crawlway or
   duct. The view plays `VentCrawl` and the `VentScrape` / `VentBreathing` loops (`view.js _updateLoops`).
4. **Wait** (optional, a backstage hold): inside, only while every player's ear is `Audible.VentBreathing` (25) or more
   straight from him (else he moves on: no silent camping beside a player).
5. **Exit:** by a mouth that is `Ducts.MouthClear` (12) or more straight from every player and in nobody's view, or in
   a player's view when it is `Ducts.MouthSeenWalk` (30) or more walked from everyone (the **seen exit**, counted as an
   S4 interaction, tier 1, under its strain gate) [P]; never the mouth a player left by within `Ducts.ExitHold` (3) s;
   neither fits: he waits inside (step 4's rule) or crawls back. Unfold 1.2 s, `Hunched`, then Patrol.

**Grates** (`vents.js` states): he passes an `Open` or `Kicked` grate; a `Closed` grate he pushes open
(`env.forceGrate(id, 'Open')`, `MetalCreak` at the grate, heard, [P]); a `Locked` grate never.

**Following a player in** (stage 2, the vent chase): only during a chase (a token spent), only when he saw them go in
within `Ducts.SeenWindow` (3) s, and only when they keep another way out ahead of them: a crawlway always has its far
mouth [W]; in a duct `ventgraph.retreatPath(graph, theirPoint, hisPoint, hops)` must return a route to another grate
that is not `Locked`. He crawls at `SharedPace` (3.8, under a crawler's 4.5 and a scurrier's 9). The chase in a hole
lasts at most `Ducts.ChaseSeconds` (10). The catch there: a player stopped (speed under 0.75 [P], the SlowVentCrawl
tier's floor in `engine/config.js VentSpeedTiers`) for `Ducts.CatchStill` (Standard 2 s; Easy never) within
`Ducts.CatchReach` (3) of him, with the chest line clear (rule 3 of [M 14]); kind `Vent` (`Jumpscare.Spacing.Vent` 2.8
exists [C]). A moving crawler is never caught. When they leave, he does not come out of that mouth for `ExitHold`.

Stage 1 uses none of this (H3 and S4 are not feasible yet): the leash and the catalogue work on the floor nav alone.

### 5.5 The leash

- **Focus:** the player of the last order (5.1); with no order yet, the counting player with the highest
  `due / theta` who is not backstage; solo, the player. A backstage focus moves the band to `BackstageWalk ..
  BackstageWalk + (Max - Min)` (Standard 60..90) [P].
- **Each step without a plan** (3.4 step 6): `walk` to the focus. `outside` counts the steps in a row with `walk`
  outside `Leash.Min..Max`. A new **hold point** is sought when `outside >= Patience` and `now >= goalAt`; or at once
  when any player is within `Leash.Clear` (15) walked and no tier 2 interaction, chase or encounter runs; or when a
  player has had a clear line to his eye at the hold point for `LineSeconds`. `goalAt = now + GoalEvery` after each.
- **The hold point:** today's `_hint(player, t)` with its numbers moved: floor points (the 5-stud lattice) within 6 of
  the focus's floor, `Min x 0.5 .. Max` horizontally, ranked in this order [P]:
  1. **Off the route of a moving focus.** For a focus moving faster than 3, a candidate must lie `Leash.OffRoute` (10)
     or more from the line of their travel over the next `OffRouteSeconds` (5) s (from the root to the lead point of
     4.0 for a sprinter, to `root + travel x speed x 5` otherwise); side rooms (a candidate in another room than any
     point of that line) first. The first version ranked "ahead of their way first" (`AheadDot` 0.4): a hold point
     ahead of a walker cannot be kept (he backs off at 7, the player comes on at 11), the 15-stud clearance broke and,
     with a token, his own senses started a chase the player did nothing to cause. "Ahead" is now only for a plan
     that needs it (S1, S2, C3).
  2. **The side the last tell named**: while `now - heardAt < TellHolds` (12) for the focus, candidates on `tellSide`
     first (4.1), so the steps a player heard stay true.
  3. **The lure's side**: while `lure` holds (5.3), candidates on the noise's side of the focus first.
  4. then dark ones first (lit: +20 in the rank [P]), then nearest him.
  Of the first `HintTries` (14), the first that is `Min..Max` walked from the focus, `Clear` or more walked from
  everyone, reachable now (`nav.reachable`) and in nobody's view (`_inViewOfAnyone`). A crawlway's inside counts as a
  hold point from stage 2 (5.4 step 4's rule). None: keep the old.
- **Getting there:** 3.6's movement rules: out of everyone's hearing at `TrailPace` (11), creeping; near an ear only
  short creeping legs (at most 10 studs at 7); a longer move near an ear waits for the next slot and is made as H1 or
  H1b; falling behind by more than `Max + 20` walked: H1b when a slot is owed within `PlanAhead`. A hold point more
  than `Director.ApproachWalk` (90) walked away with no route back within `ApproachRun` (12) s at 13: the approach, under
  3.4 step 5 (b)'s limits.
- **Between orders** he holds there, standing, facing the way the focus will come.

### 5.6 Chases on a team token bucket, and the near miss

**The bucket** (each brain tick while a floor is active; frozen in cutscenes and with no floor):
```
rate   = (1 / refillNext) * (1 + Chase.PerPlayer * (n - 1))      -- n: players Alive or Downed in the run
tokens = min(Chase.Cap, tokens + rate * dt)
-- each time tokens passes a whole number (a token completed): refillNext = Chase.Refill * U(RefillMin, RefillMax)
```
`refillNext` [P] is drawn from the `Lurk|Refill` stream: the mean is unchanged, but a player can no longer count 150 s
on the dot after a chase (the review: "for a sprinter chases come at 90, 240, 390 s on the dot"). At the run's first
floor activation: `tokens = max(0, 1 - Chase.First / Chase.Refill)` (Standard 0.4, Easy 0.625, Nightmare 0) with
`refillNext = Chase.Refill` for that first token, so the first token comes `First` (90) s in when solo (sooner with
more players). `fullSince` is set when `tokens` reaches `Cap`.

**Spending** (one token, `tokens -= 1`), only on a **provocation**:
- entering `WallChase` from a state that is not a chase, unless `now - chaseEndAt <= Chase.ChainSeconds` (20: the same
  chase taken up again, as presence-sim counts it today);
- entering `HidingResponse` from outside a chase (he saw someone climb in while he lurked, **outside a director
  interaction and its defence window**, below);
- a breath check's `Caught` verdict inside an encounter only (a director-issued C4 never spends: 4.13).
An **encounter** runs from the spend until the brain is back in Patrol, plus `ChainSeconds`; inside it every rule of
today applies (pursuit, search, hiding watch, ReachIn, catches). `Summary.token` is true when `tokens >= 1` or an
encounter runs, and false while `now < rescueUntil` (and for a backstage maker's noise, 3.3). The spend records
`lastEncTarget` and `lastEncAt`.

**A defence never starts an encounter; a provocation does** [P]. While a director-issued interaction plays and for
`Chase.DefenceWindow` (5) s after it, a player getting into a hiding spot, backing away, switching the torch off or
crouching never triggers `HidingResponse` or a chase: he ends the interaction and leaves (as he withdraws from a beat,
[M 16]), and if that player hid, their next interaction is the non-lethal C4 of 4.13 (the director sets
`cooldownUntil` of every other type to `now + 1` for one step [P]). The game's own first-time hint tells a new player
to "switch the torch off, crouch, hide" when he is near [M 11], and every beat keeps a hiding spot within 25 walked
[M 16]: doing exactly that in his sight must not spend the token on a hiding watch with a ReachIn at 30 s [M 6.7].
Provocations keep today's rule: a 1 s stare, coming within 12 of him (`Beats.Near`), a loud noise heard with a token,
and a noticed sighting during C2 or C3's stalk of a player who is not defending.

**The same player twice** [P]. The target of the last token-paid encounter cannot be the next one's target until
`Chase.RepeatAfter x Chase.Refill` (2 x 150 = 300 s on Standard) has passed since `lastEncAt`, or unless they are the
only player who counts; meanwhile their triggers give the near miss. One player cannot burn the squad's budget while
three work, and the chases spread.

**A chase thrown away gives some back** [P]. A chase that ends within `Chase.ShortSeconds` (6) s of its start with him
never within `Chase.ShortNear` (20) straight of its target returns `Chase.ShortRefund` (0.5) token. A player who stares
from 40 studs with a full meter to burn the token and buy a safe window gets half of it back: the next token is half a
refill away, not a whole one. Downs per floor stay bounded by the bucket (8.3 keeps today's chase and downs targets).

**Without a token** (`token` false), the triggers that start a chase today give:
- **a stare or a sighting of a noticed player** (rows "stared at" / "seen", and the Teleport stalk's `StalkSight`
  rule, [M 18.4]): the **near miss** (`NearMiss`, 4.16) when `now - nearMissAt >= Chase.NearMissEvery` and `now -
  nearMissAnyAt >= Chase.NearMissSquad` (25), else he slips away (`Patrol`, reposition: out of their sight) with no
  screech;
- **seeing someone climb into a spot** (row "saw them hide"): no HidingResponse; that player's next interaction is a C4
  if feasible (non-lethal, 4.13);
- **a breath check's `Caught`** (always, for a director-issued C4): the near miss at the spot: `Screech` at his eye,
  `Lockers.nudge` on that spot (the door rattles), and he leaves; no ReachIn.
So **every down happens inside a token-paid encounter that a provocation started**: downs per floor are bounded by the
bucket, and a careful player who only hides is never downed by a director-issued interaction.

**The near miss** always sends its target backstage (3.3): "after a big scare he leaves you alone" holds every time.
It plays `ChaseSting` at the screech and `GiveUpSwell` as he turns (4.16), so it stays a scare after the second one.
Up to one near miss every 45 s per player in a four could otherwise give one screech every 11 s; `NearMissSquad` keeps
them 25 s apart squad-wide.

**Rescue:** a player going `Downed` sets `rescueUntil = now + Chase.Rescue` (20): no interaction and no chase starts on
anyone until then [R 3.7].

Expected chases (arithmetic): Standard solo, first token at 90 s then one per 150 s on average: tokens at about 90,
240, 390 s, three in an 8-minute floor (research target 2..4); Easy: 90 and about 330 s (target 1..2); Nightmare, 90 s
each, cap 2: about 5 (target 3..7). Every token is spent only if a trigger comes: `SpendAfter` raises C3 and C1 (which
lead to triggers) when one waits, for a player who moves at a walk or faster or was loud; a quiet croucher's token
waits (target 0..2 chases a floor for the Croucher, 8.3).

### 5.7 Co-op: the host is the authority

The host (`MonsterAI` with its roster, [M 13]) computes everything of v3: the clocks, strain, the bucket, reach (from
the remote handles' root, eye and look, which it already reads), every plan. Clients compute nothing of v3.

| What | Message | New or reused |
|---|---|---|
| his body, state, pose (`Quadruped` included), `inVent` flag | the world packet's creature block (`net/codec.js`: flags bit `inVent` 4 and `PoseModes` already carry them) | reused; the host's snapshot must set `inVent` while he crawls |
| the exact state, the action, the gait, the heartbeat alarm | `{t: 'cst', st, a, ago}` (`game/coop/creature.js`) + new fields `g` (`'Creep'`/`'Heavy'`/`'Run'`) and `al` (the user ids whose `alarmUntil > now`, 3.6; sent when it changes) | reused + two fields |
| the "Monster activity" setting (beta) | the host's value is the run's (3.2); clients' own setting is ignored in a co-op run and the menu shows the host's | none new: the lobby's run options carry it |
| `NearMiss` and `Crawl` on the packet | `WIRE_STATE` gains `NearMiss: 'InvestigateNoise'`, `Crawl: 'Patrol'` (the exact name rides on `cst`) | reused map |
| a director-issued sound (H2's rattle and breath, C2's sniff, the near miss's screech, a grate pushed open) | NEW `{t: 'ccue', n: key, p: [x, y, z], v: volume, sd: seed}` host -> all clients; registered in `coop/events.js` (`to: 'client'`, run phases, rate 8/s); the client plays it at `p` with `opts.seed` (`audio.js` picks the same variant) | new |
| H4's locker nudge (and the door left ajar) | `{t: 'mech', k: 'locker', d: {id, ev: 'nudge'}}` (`coop/mechanics.js`, beside `'rip'`) -> `lockers.remoteNudge(id)`; the ajar door ends on every page when the spot is used or after 120 s (each page runs the same rule) | reused type, new event |
| C3's and the approach's warning | `{t: 'cwarn'}` | reused |
| a chase's give-up swell (also after a near miss) | `{t: 'cgive'}` | reused |
| the interaction record, the clocks | none: nothing on a page shows or counts them | — |

Today the chase's `Screech` plays only on the host's page (`service.js _enterState` -> `env.play`); v3 plays it
through `_lurkCue` too, so every page hears it (a fix, not a rule change).

### 5.8 Cost

- **Per brain tick (10 Hz):** `integrate` (3.2, 3.3) is a few dozen arithmetic operations per player (at most 4),
  the bucket two; reach for heard cues is one distance per registered sound per player. Budget [P]: 0.05 ms on the
  Potato Chromebook.
- **Per director step (1 Hz):** at most `Budget.PathQueries` (40) `FloorNav.pathLength` calls: the walks to each player
  (4, as today), then **one** planning task (one interaction plan with at most `GeometryTries` (3) geometries, or one
  hold-point search with at most `HintTries` (14)). The geometry's `walk` goes through a counting wrapper that answers
  Infinity once the step's budget is spent (the plan then fails and is retried later). Seen-reach needs `_seenBy` (two
  raycasts per player) at 10 Hz only while a body interaction runs. Budget [P]: 2 ms worst case per step, under 0.5 %
  of the frame time averaged over a second.
- creature-sim asserts the 40-query cap per step; presence-sim reports the mean and worst milliseconds per step in
  Node (reported, not asserted: machines differ).

---

## 6. Interplay and regressions

| System | Under v3 |
|---|---|
| **Hiding spots** ([M 8], game-spec-v2 3.6) | Unchanged rules (the sniff, the stay limit 35 / 45 s, fake-outs, the pull-out). A hider's class is `Hiding` (gap 75 s, only C2, C4, H1, H2; C2 and C4 fit); a hide right after an interaction is owed one 12..20 s in (5.2). HidingResponse needs a token and a provocation, never a defence during a director interaction (5.6). The breath check's `Caught` downs only inside an encounter the hider caused; a director C4's window is clipped to the breath left (4.13). H4 nudges only empty spots and leaves the door ajar. |
| **The heartbeat** ([M 11]; `web/src/creature/index.js`, `web/src/game/ui/hints.js`) | Radius 15 in the quiet lurk, 45 while alarmed, with an 8 s tail (3.6). The first-time hint `CreatureNear` uses the same radius. |
| **Lives** (`LivesRules`, game-spec-v2 3.3) | Unchanged. A down sets `rescueUntil` (20 s). Every down is inside a token-paid encounter started by a provocation (5.6). |
| **Radar** (I15) | Unchanged: a scan never shows him and is no noise. `RadarPing` is not a lump. |
| **Objectives** | Never blocked: no interaction stands within `Leash.Clear` walked of a player outside tier 2, and tier 2 keeps `Beats.SafeWalk` 25 [C]. `ObjectiveWork` (34, Normal) is no lump; `ObjectiveClunk` is (0.35). Progress `p` tilts the mix toward close interactions (5.2). The teleport's block during a survive countdown ([M 7.2 (7)]) also blocks C3 and the approach. |
| **Scripted set pieces** (the spawn hold, Classroom 108, the scare director, game-spec-v2 3.5) | While a script holds him (`Scripted`) the director makes no order and every clock and strain is frozen (3.2); the spawn hold is the floor's first 20 [12] s, inside `FirstHeard`. New hook `noteSetPiece(player, t)`: no lurk interaction starts for that player within 8 s after a set piece [P] (the scare director's own gate already keeps him 40 away). Set pieces are not interactions (I1, I3). |
| **Cutscenes and the prologue** (I13) | No floor is active: no director, no bucket refill. A player under a `Cutscene` lock does not count (3.2). |
| **Respawn grace** (I13) | An ignored player (`_ignores`) does not count, cannot be reached, cannot be a target. `relocateFrom` (the respawn's move) also resets the leash's `hold`. |
| **The stun flask** ([M 6.9]) | Unchanged stun (6 s, then Patrol withdrawing). It ends any interaction (`outcome: 'stunned'`), resets the leash's hold, and adds `Types.Approach.Cost` to the strain of every player who saw it. A chase it ends stays spent (the short-chase refund does not apply to a stun). A flask thrown and shattering 12 or more from the thrower is a lure (5.3) and no lump on the thrower (3.2). |
| **Difficulties** | Section 2.5. Cadence equal on all three; danger differs. `difficultySpec` (speeds, senses) has no Easy row: Easy uses Standard's. |
| **Graphics tiers** (I10) | Nothing in v3 reads a tier, a frame or light other than the baked probes (`env.litAt`); tier-parity runs the director (section 8). |

**Fairness rules of [M 14], one by one:**

1. Never faster than a sprinting player (19): **stays.** New paces: `CreepPace` 7, `StepPace` 9, `TrailPace` 11 (never
   heard or seen), `RunPace` 13, the near miss's back-away 9, `Ducts.Pace` 6, `SharedPace` 3.8, the near miss's feint at
   the chase pace (16.5 [18.5 capped]). In a hole a player is in he is never faster than 3.8 (the research's "never
   > 4.5 in a duct a player is in").
2. Teleports never in view, never within 12, warned 1.6 s, the bands: **stays** for C3 and the approach; new: at most
   2 warnings per player per 180 s, none within 12 s of a heard tell. No other v3 move places him unseen-to-seen: the
   crawl is a walk; the near miss's exit is a walk or a back-away first and today's give-up warp only last (its
   FadeOut may be watched: it is his real body dissolving; its destination is unseen and 45 from every eye); the
   vantage steps back to its corner and dissolves only when it has none.
3. No catch through a wall: **stays** (the crawl catch included).
4. The first teleport no sooner than the floor's grace + 45 s: **stays** for C3 (`teleportReadyAt`); the approach keeps
   its own grace rule ([M 15.3]).
5. Chase ends at 4 [6] s unseen, caps at 12 [45] s, winds up first, no catch in the wind-up: **stays**; Easy's cap 8.
6. LookAway, ReachIn at 30 s, pull-out no catch: **stays** inside an encounter; an encounter is started only by a
   provocation, never by a defence during a director interaction (5.6).
7. The pool: **stays** as written (game-spec-v2 3.6 deletes AquaticStalk with its own package; v3 does not touch it).
8. Determinism: **stays and grows**: the interaction log is part of it (3.7).
9. The presence layer: **changes.** Stand points 25 walked from every player, a hiding spot within 25, not cornered,
   a beat never a chase on its own: stay for S1, S2, S3, C1, C2. The hint's band (25..55 walked, never in view)
   becomes the leash's (`Leash.Min..Max` per difficulty, `Clear` 15 from everyone). The caps (hint 8 s, beat 35 [25] s,
   quiet spell 40 [35] / 45 [40] s, first beat 20 s) are replaced by `GoalEvery` 4 s, `Clock.Team` 6 s, `TeamBody` 15
   s, the per-type cooldowns, backstage, `FirstHeard` 20 s and `FirstSeen` 40 s; reason: the player asked for an
   interaction every 15 to 60 s, which a 35 s beat cap and a 40 s quiet spell cannot give. The approach's 25 s stays,
   with at most 2 warnings per player per 180 s; "a player left alone goes first" stays at 60 s (`Coop.Starve`, from
   75: a stint now holds the focus, 5.1).

---

## 7. The spoken-line hook (H5)

The voice system (game-spec-v2 3.4: `VoiceConfig`, `VoiceRules`, the authority's `VoiceDirector`; task #42, with the
recorded lines of task #49) does not exist yet in the code (no `VoiceConfig`, `VoiceRules` or `VoiceDirector` under
`src/` or `web/src`). v3 defines the one call the lurk director makes, so the voices drop in with no director change.

**The interface** (web: exported by `web/src/creature/lurk.js` as a type; the service holds `this.voice = null` until
the game sets it with `creature.setVoice(voiceDirector)`):

```
voice.offer({
  channel:  'Head' | 'Ear',      // Head: at his eye + 0.3, everyone within earshot; Ear: one listener (3.4 Channels)
  category: 'Calling' | 'Behind' // 3.4's categories that the lurk director now triggers (Head / Ear) for H5,
          | 'NearMiss' | 'PassBy' | 'Peek', // and the three event offers (below)
  listener: userId,              // the target; for Head the others within earshot hear it too
  speaker:  {eye: Vector3},      // his real head: the line plays there (I1)
  nameOf:   userId | null,       // whose name the line may say
  at:       t,                   // now (game clock)
  maxSeconds: 3,                 // Types.H5.Max
}) -> {lineId, key, seconds, named} | null
```

- **The lurk director** calls `offer` when H5 was drawn and its geometry fits (4.5). `null` (the voice director
  declines: a limit, a cutscene, no line ready) is a plan that found no place: `retryUntil.H5`. Otherwise the line's
  `seconds` is the interaction's length and its `key` is registered for reach like any cue (`Audible.Voice`, set when
  the files are measured).
- **Event offers** [P] (`Voice.Offers`): the lurk director also calls `offer` with `category` set to the moment, inside
  three interactions: `'NearMiss'` (Head, as he turns away, 4.16), `'PassBy'` (Head, at the pass-by's point P, beside
  a hider or a still player, 4.11), `'Peek'` (Head, as a peek or a vantage withdraws, 4.7, 4.8). They ride inside
  those interactions: an accepted offer is not an extra interaction, does not settle any clock, and counts against
  `Voice.PerPlayer` / `PerTeam` and 3.4's limits like H5. These are the moments v3 creates; the player asked twice for
  him to speak ("I want the monster to talk too real words", "Make sure he talks good English" [Q]), and the lead
  decided on Nov 16 19:45 that every line, the monster's included, is built now [Q]. The voice director owns the line
  tables for these three categories (task #42 / #49).
- **Categories.** Calling ("{name}... where'd you go?", "Come out, {name}. It's just me.", 3.4) on Head; Behind
  ("Don't turn around, {name}.", "I'm right behind you.", 3.4) on Ear. 3.4's own rolled triggers for these two
  (Calling: every 15 s at 0.35; Behind: its 8..26 rule) are **off** while the lurk director runs: H5 is their
  trigger, so lines never double up. 3.4's event categories (Heard, Sniff, Saw you hide, LookAway, Ready, Chase,
  Teleport, Stunned, Scripted) stay the voice director's; they play inside other interactions and are not counted as
  interactions.
- **The name rule** (3.4 and the Nov 16 13:12 decision in `docs/design/requirements.md`): the shared
  `NameSanitizer` (`src/ReplicatedStorage/Shared/Rules/NameSanitizer.luau`, exists); the named form with the stage's
  probability (Basement 0.3, Hallways 0.5, Auditorium 0.7, roof and city 0.9); never the same name to a listener within
  45 s; a name outside the pre-rendered set of common first names, or the setting "The monster says names: Off", gets
  the nameless twin.
- **Limits:** `Voice.PerPlayer` (one H5 per player per 120 s), `Voice.PerTeam` (one per 45 s), and every rule of 3.4
  (at least 8 s between lines a listener hears, at most 4 per rolling 60 s, none within 1.5 s of a stinger, reveal or
  catch, none in a stage's first 25 s, none in cutscenes).

**What H5 and the event offers do until recorded voices exist: nothing** (`Voice.Enabled = 0`: H5's weight counts
as 0, the draw is renormalised over the rest, and no event offer is made). But the hook, the offers and a stub voice
director ship in **stage 1** [P], so the lines play the day the voice files land, with no director change. Reasons for
staying silent until then:
1. The player asked for "real words" and "good English". The only voice on the website today is the browser's
   `speechSynthesis` (`web/src/engine/audio/tts.js`): a different, robotic voice on every Chromebook, or none, in which
   case 3.4's fallback is a murmur under a subtitle. Neither is a real word spoken.
2. A subtitle over a growl reads as fake and teaches players to ignore the line; the first time he speaks should be
   the real voice.
3. The cadence does not need it: H5's base weight is 4 of 93 (under 5 %); the heard share at the start of a floor
   stays about 65 % without it (5.2's check, which already counts H5 as 0).
4. The hook ships in stage 1 and is tested with a stub voice director (`web/tools/stubs/voice-stub.mjs`: a fixed table
   of line ids per category whose audio is missing: `offer` answers, the line's key is a silent placeholder, the sims
   run it with `Voice.Enabled` forced to 1 and check the limits and the name rule), so task #49's files only switch
   `Voice.Enabled` to 1. Acceptance with the stub (8.3): a Walker hears a line in 8 to 15 % of his interactions [P],
   never two within 45 s; asserted from stage 1 on the stub run, and again with the real files when they land.

---

## 8. The simulation plan

### 8.1 The scripted players (presence-sim)

| Player | Moves | Torch | Hides |
|---|---|---|---|
| **Sprinter** | today's objective bot: the floor's objective targets at a sprint whenever it has stamina (drain 7/s, regen 14/s after 1.2 s, no sprint under 25 until refilled: `presence-sim.mjs` constants) | on | never; chased it runs (today's flee) |
| **Walker** | the same targets, always at a walk (11) | on | never; chased it runs |
| **Croucher** | the same targets, always crouched (5.5) | off | today's careful-bot hiding (warned, chased, seen close) |
| **Hider** | from hiding spot to hiding spot toward the targets: in a spot U(30, 40) s (under the 45 s shove), then crouched to the next spot within 45 walked | off | always |
| **Mixed** | the targets, in 10 s blocks drawn per seed: sprint 30 %, walk 50 %, crouch 20 % [R 3.9] | on | as the careful bot |
| **Split pair** (stage 1) / **split four** (stage 3) | two players (or two pairs) on the same floor's targets kept 100 studs or more apart (each takes the half of the targets nearest its start), Mixed movement [P] | on | as the careful bot |
| **Lurer** (report only) | the Walker, plus: on hearing a Reply-worthy cue within 40, throws a flask (when held) 20 to 30 studs away from him | on | never |
| careful (today's) | kept for the downs measure ([M 20]) and the careful time measure (8.3) | | |

Each run logs every interaction (the service's `interaction` signal), every sound of his with its key, position and
time (the sim's engine stand-in already captures `env.play`), every sighting, the class each player was in every
second, strain, the bucket, chases, near misses and downs.

### 8.2 What counts as "an interaction reached a player"

The sim does not trust the service's own `reached`: it recomputes it from its logs with section 4.0's rule (two
footfalls with the ear within 80, or 22 creeping; a cue with the ear within its `Audible` for `min(1 s, its length)`;
or its own sighting rule, `SIGHT_HALF_ANGLE` 50 within `SIGHT_RANGE` 80 with a clear line, for 0.3 s), and asserts
both agree on at least 98 % of interactions [P] (the rest are edge timing). **The gap** of a player is the time between
the starts of two consecutive interactions that reached them by the sim's rule. **A chase's start (`X`) and a near
miss (`NearMiss`) are interaction records and count in the gap** [P]; so does a `Reply`. `Stray` records do not count
in the gap; they are reported on their own (8.3). A player's own noises and the ambience never count; neither do his
footfalls between interactions unless an interaction is running, except as `Stray` when they meet the reach rule.

### 8.3 The measures

On the Basement and the Hallways, 8 minutes a floor ([R 3.9] targets for Standard; each floor started as the game
starts it, as today). "presence" is `web/tools/presence-sim.mjs`, "creature" is `web/tools/creature-sim.mjs`.

| Measure | Threshold | Tool |
|---|---|---|
| gap, Sprinter | median 15..20 s, p90 <= 36 s (lulls included) | presence (cadence) |
| gap, Walker | median 26..34 s, p90 <= 62 s | presence (cadence) |
| gap, Croucher | median 50..70 s, p90 <= 110 s [P] | presence (cadence) |
| gap, Hider | median 40..75 s [P] (the owed hide shortens it), p90 <= 110 s [P] | presence (cadence) |
| lulls | each Walker floor has at least one gap of 1.6 x its median or more [P] | presence (cadence) |
| the clock is honest | each profile's median gap / its expected gap (1 / its time-averaged `1/Gap[class]`) in 0.85..1.2 [P] (the Hider excluded: the owed hide pays it early on purpose) | presence (cadence) |
| Easy and Nightmare cadence | the same bands as Standard (Walker, Mixed) | presence (cadence) |
| first interaction on a floor | <= 25 s, tier 0 | presence (cadence) |
| share by tier, a floor (all profiles) | heard 40..60 %, seen 25..40 %, close 10..25 % | presence (cadence) |
| last third against first third | close share at least 1.5 x | presence (cadence) |
| any single type | **for each profile**, <= 30 % of that profile's interactions (stage 1: <= 35 %, H3 and S4 missing [P]); the fallback counts as its type; the same type twice in a row on a player: never (fallback included) | presence (cadence) |
| teleport warnings | Approach + C3 counted as one item: <= 25 % of each profile's interactions; <= 2 aimed at one player in any 180 s on Standard [P] | presence (cadence), creature |
| strays | <= 1 per player per 2 minutes [P] | presence (cadence) |
| heartbeat | the panic floor on (the `CreatureNear` token set) under 35 % of a Walker's time [P] | presence (cadence) |
| chases per floor, solo | Standard 2..4 for Sprinter, Walker and Mixed; Croucher 0..2 [P]; Easy 1..2, Nightmare 3..7 [R 3.5]; pair Standard 2..6 [P] | presence (danger) |
| chase spread (co-op) | no player the target of more than half a floor's chases (pair and four, and split) [P] | presence (danger) |
| hides that pay | at least one hide in three (Hider profile) gets a C2 or C4 while the player is in the spot [P] | presence (cadence) |
| downs, Hider, outside a chase's encounter | 0 | presence (danger) |
| careful player's time | the careful bot's and the Croucher's objectives done in 8 minutes within 15 % of the v2 baseline (8.4) [P] | presence (danger) |
| voice (stub) | with the stub voice director: a Walker hears a line in 8..15 % of his interactions [P]; never two lines to one listener within 45 s; `PerPlayer` / `PerTeam` never broken | presence (cadence) |
| near misses squad-wide | never two within 25 s | presence (cadence) |
| downs, Sprinter (the objective bot), Standard solo, 36 seeds | 0.3..0.8 a floor ([M 20]) **and** the mean at most the v2 baseline's + 0.05 [P]; floors with 2 or more <= 20 % | presence (danger) |
| downs, careful bot, Standard solo | floors with a down < 25 % ([M 20]) | presence (danger) |
| downs, Croucher, Standard solo | < 0.25 a floor [R 3.8] | presence (danger) |
| downs, Easy | at most Standard's | presence (danger) |
| downs, Nightmare | today's targets ([M 20]: 0.7..5 [pair 0.5..4], careful < 40 %) | presence (danger) |
| every down inside a token-paid encounter | 100 % | presence (danger), creature |
| near misses a floor (a near miss on them; a pass-by within 30 walked with no chase; a shadow frozen by their look; a C4 they held their breath through; a chase on them that ended without a catch) | >= 2 per player for Sprinter, Walker, Mixed; >= 1 for Croucher, Hider [P] | presence (cadence) |
| strain >= 0.8 | < 15 % of the time | presence (cadence) |
| tier 1 or 2 started on a backstage player | never | presence, creature |
| leash | within `Leash.Min..Max` walked of the focus >= 60 % of the time | presence (cadence) |
| within 15 walked of anyone, no tier 2 and no chase | < 3 % of the time | presence (cadence) |
| every sound of his from where he is | 100 % (a cue within 1 stud of his eye or root as it plays; H4's at the nudged door within 3 of his root; the hiss at C3's planned spot, I1's one allowance) | presence, creature |
| teleports warned, none in view, none within 12 | 100 % (today's per-tick watch) | creature, presence |
| co-op (pair and four, Mixed, together) | two interactions start >= 6 s apart: always; each player's median gap <= their solo median / 0.7 and >= their solo median x 0.85 [P] (a tight group is not paid faster than solo); nobody > 90 s without one | presence (cadence) |
| co-op split (split pair stage 1, split four stage 3) | each player's median gap <= 2 x their solo median; nobody > 90 s without one; teleport warnings <= one third of each player's interactions [P] | presence (cadence) |
| holes (stage 2) | a moving crawler caught: 0; in a hole a player is in, his speed <= 4.5 | creature (vents), presence |
| speed | never > 19 outside Scripted | creature, presence (today's watch) |
| determinism | the same seed, the same interaction log; 20 and 144 fps identical | creature (determinism), tier-parity |
| cost | <= `Budget.PathQueries` (40) path queries per director step | creature |

**creature-sim.** Its `SPEC` table: delete `Director.HintMin`, `HintMax`, `HintEvery`, `LeashWalk`, `BeatEvery`,
`QuietSeconds`, `QuietAfterCatch`, `StarveSeconds`; add, read through `lurkConfig(meta, d)` with three columns (Easy,
Standard, Nightmare): `Clock.Gap.Sprint/Walk/Work/Still/Crouch/Duct/Hiding` (14/30/40/75/60/40/75 on all),
`Clock.ThetaMin/Max` 0.6 / 1.4, `Clock.LullComp` 7/6, `Clock.TellHolds` 12, `Clock.WarnMax` 2, `Clock.FirstHeard`
(25, 20, 20), `Clock.FirstSeen` (50, 40, 40), `Clock.SamePlayer` 10, `Clock.Team` 6, `Clock.TeamBody` 15,
`Heart.Quiet` 15, `Heart.Alarmed` 45, `Coop.Stint` 45, `Chase.NearMissSquad` 25, `Leash.TrailPace` 11, `Leash.RunPace` 13,
`Leash.Min` (35, 25, 20), `Leash.Max` (70, 55, 45), `Leash.Clear` 15, `Strain.BackOff` 0.8, `Strain.CloseBelow` (0.4,
0.45, 0.55), `Strain.SeenBelow` (0.6, 0.65, 0.75), `Chase.Refill` (240, 150, 90), `Chase.Cap` (1, 1, 2), `Chase.First`
90, `Chase.Rescue` 20, `Coop.Starve` 60, `Ducts.Pace` 6, `Ducts.SharedPace` 3.8; and through `presenceConfig`:
`Chase.CapSeconds` (8, 12, 45), `Chase.Breather` (40, 35, 15), `Beats.ShadowMinSeconds` 10, `ShadowMaxSeconds` 20.
New cases: the clock's equations against a scripted class trace (3.2: a sprinter's due reaches theta after `theta x
14 / LullComp` s, a worker's after `theta x 40 / LullComp`, a still player's after `theta x 75 / LullComp`); the lull
(every 5..7 interactions theta doubled); lumps, and no lump for a noise 12 or more from its maker; carry; the group
settle (two players within 15 both pay a full theta); heard-only strain at most 0.08; `SamePlayer`; strain rises,
decay and backstage entry and exit; a near miss always backstage; the bucket's first token at 90 s solo, the co-op
rate, the refill draw within 0.6..1.4 x, the short-chase refund; a stare without a token gives a near miss and no
catch; two near misses never within 25 s; a director C4's `Caught` never gives a ReachIn, with or without a token, and
its window never outlasts the breath left minus 0.5; getting into a spot in his sight during a director interaction
starts no HidingResponse, with a token; the last encounter's target is not the next one's within 300 s (two players);
`Rescue`; heard noises without a token start no InvestigateNoise and do give a Reply within 4 s; a far flask moves the
hold point to its side; an alert still does what it does today; H2 never in view and with a wall; H4 only empty spots,
the door left ajar; S3: the target's stare does not start a chase, the torch on him ends it with a walk back; teleport
warnings at most 2 per player per 180 s and none within 12 s of a heard tell; a hold point for a moving focus 10 or
more off their line; moves seen are `Heavy`; the heartbeat radius 15 in the quiet lurk and 45 alarmed; the query cap;
the interaction log identical at 20 and 144 fps. Stage 2 rewrites the "vents" case (today: "it never enters the ducts")
to 5.4's rules.

**lurk-test** (`web/tools/lurk-test.mjs`, new): the pure rows of `lurk.js` (integrate, settle, who, feasibility
filters, weights, bucket), from a JSON fixture in stage 1 and from `build/cache/golden.json` from stage 3 (section 10).

**audio-test**: the `Audible` distance of every key v3 uses (4.0).

### 8.4 Runtime budget (under about 12 minutes for the monster's tests)

Today presence-sim takes about 9 minutes (the lead's figure). Its grid is 3 floors x 2 difficulties x 2 player counts
x (objective bot on 36 seeds + careful bot on 12) = 576 runs, so about 0.95 s per 8-minute run (derived; a pair run
costs more: counted below as 1.5 runs, a four as 3 [P]). Proposal:

- **`--suite cadence`** (new): Sprinter, Walker, Croucher, Hider, Mixed; Basement and Hallways; Standard solo, 6 seeds
  (60 runs); Easy and Nightmare solo, Walker and Mixed, 6 seeds (48); Mixed in a pair and a four, Standard, 6 seeds
  (24 runs, 54 run-costs); the split pair, 6 seeds (12 runs, 18 run-costs); the Walker with the stub voice director
  (it is one of the Walker runs above, no extra). About 180 run-costs: about 2.9 minutes. The split four joins in
  stage 3 (6 seeds, 12 runs, 36 run-costs).
- **`--suite danger`** (today's grid, trimmed): the Basement and the Hallways only (the Auditorium is reported, not
  asserted, today: it moves to a `--report` run outside the gate); Standard solo objective 36 + careful 12 seeds (96
  runs); Standard pair 12 + 12 (72 run-costs); Nightmare solo 12 + 12 (48) and pair (72); Easy solo objective 12 x 2
  floors (24). About 312 run-costs: about 5 minutes. The Sprinter's cadence is also measured on these runs (it is the
  objective bot), which tightens its numbers for free.
- creature-sim budget 2 minutes [P] (its soak stays 240 s a level); lurk-test and data-test seconds.
- **Total** about 9.9 minutes run one after the other (about 10.5 with stage 3's split four); the two presence suites are independent processes (`nice -n
  10`) and may run side by side where two cores are free (about 7 minutes wall). Each suite prints its wall time; the
  gate fails a suite over 6 minutes [P].
- Before stage 1 changes anything: one `presence-sim --report --json web/tools/baselines/presence-v2.json` run on the
  unchanged tree (about 9 minutes, once) gives the v2 baseline the downs rule and the careful-time rule compare with.
  It must record, per profile and floor, the downs and the objectives done in 8 minutes (if today's report does not
  print objectives done, the builder adds that column before the baseline run; it changes no behaviour).

---

## 9. The build plan

Every stage ships with every gate green (`docs/design/game-spec-v2.md` 8.1; today 22 gates per commit a17775b:
verify, data, sounds, story, coop, creature and presence sims, tier parity, check, smoke, objective run, ...), on the
beta, and with `docs/MONSTER.md` updated in the same commit (new sections 22..27: the clock, strain, the catalogue,
the director, the holes, the report; 15.1, 15.3, 15.4 and 20 marked replaced).

### Stage 1: the cadence, with what exists

**Delivers:** the clock with the lull and the activity factor (3.2), the group settle and the heard-only cost, strain
and backstage (3.3), the director step with its fallback rules (3.4), the movement class with Work and Still (3.5),
the quiet lurk (he mostly stands; trails out of hearing at 11; heavy when seen; the heartbeat radius 15 / 45) and the
director's rattle (3.6), the tighter leash with off-route, tell-side and lure-side hold points (5.5), the lead point
for sprinters (4.0), heard tells from existing sounds (H1, H1b, H2, H4, F, Reply), the seen and close interactions
driven by the director (S1, S2, **S3**, C1, C2, C3, C4), the owed hide (5.2), the approach with its limits, the chase
token with the refill draw, the short-chase refund, the repeat-target rule, the defence rule and the near miss with its
sting, backstage and exits (5.6), his ears behind the token (5.3), stints (5.1), the H5 hook with the three event
offers and the stub voice director (section 7; `Voice.Enabled` stays 0), the beta's "Monster activity" setting, the
co-op messages it needs (5.7: `ccue`, `cst.g`, `cst.al`, the locker nudge, `WIRE_STATE`).

**Files:** `src/ReplicatedStorage/Shared/Config/CreatureConfig.luau` (`tri`, `Lurk`, the `Presence` changes of 2.4,
`exportMeta`); `web/src/creature/presence.js` (Easy keys, `lurkConfig`; the menace `Director` reduced to the approach's
cooldown or folded into `lurk.js`); `web/src/creature/lurk.js` (new, pure); `service.js` (`beginRun` seed, `step`
integrate, `_direct`, `_lurkCue`, reach, the `interaction` signal, strays, `_inCrawlway`, the token, defence and near
miss rules, the lead point, rescue, `noteSetPiece`, `snapshot` `gait` / `lurk` / `alarm`, `_teleportDue` without its
timer, the voice hook `setVoice`); `brain.js` (`token`, `alerted`, rows, `NearMiss`); `states/patrol.js` (lurk mode:
hold, trail, creep, H1, H1b, F, Reply legs), `states/nearmiss.js` (new), `states/search.js` (`searchSpots`),
`states/sniff.js` (the `Caught` rule via the context), `states/peek.js` (the Vantage hold); `beats.js` (the counting
walk, `from` points, `planVantage`); `view.js` (gait volume, `Run` plays the `Chase` cycle); `index.js` and
`game/ui/hints.js` (`heartRadius`); `env.js` (`nudgeSpot`, `floorProgress`); `game/mechanics/monsterFx.js` (rattle
states and radius; the approach without `TorchStutter`); `game/mechanics/lockers.js` (`nudge`, ajar door,
`remoteNudge`, the window clip of a director C4); `game/coop/creature.js`, `coop/events.js`, `coop/mechanics.js`;
`game/ui/title.js` and `game/strings/base.js` (the beta-only setting); `web/sounds` (more variants for the keys of
4.0); `web/tools/presence-sim.mjs`, `creature-sim.mjs`, `audio-test.mjs`, `lurk-test.mjs` (new) and its fixture,
`web/tools/stubs/voice-stub.mjs` (new), `web/sounds/test.mjs` (the variant report), `web/tools/baselines/presence-v2.json`
(new, captured first); `docs/MONSTER.md`.

**New tests:** lurk-test; creature-sim's new cases (8.3); presence-sim's cadence suite (with the split pair and the
stub voice) and the trimmed danger suite (with the careful time); audio-test's `Audible` measures; the sounds test's
variant report.

**Acceptance (Standard solo, Basement and Hallways):** Sprinter 15..20 s median (p90 <= 36), Walker 26..34 (p90 <=
62), Croucher 50..70 (p90 <= 110), Hider 40..75 (p90 <= 110), a lull on every Walker floor; first interaction <= 25 s;
chases 2..4 (Croucher 0..2); Sprinter downs 0.3..0.8 and <= baseline + 0.05; careful < 25 % floors with a down; Hider
downs outside a chase's encounter 0; careful and Croucher objectives in 8 minutes within 15 % of baseline; leash >= 60
%; within 15 walked without tier 2 or chase < 3 %; per profile no type over 35 %; Approach + C3 <= 25 % per profile and
<= 2 per player per 180 s; strays <= 1 per player per 2 minutes; heartbeat on under 35 % of a Walker's time; a hide in
three pays; strain >= 0.8 under 15 %; near misses squad-wide >= 25 s apart; stub voice 8..15 % of a Walker's
interactions, never two within 45 s; co-op pair together: team gaps >= 6 s, each median in 0.85..1/0.7 of solo, nobody
over 90 s; split pair: each median <= 2 x solo, nobody over 90 s, warnings <= a third; no player the target of more
than half a floor's chases; every sound from where he is; creature-sim, tier-parity, objective-run, game-smoke,
data-test green.

**Risks:** H1 / H1b as the fallback take too large a share (watch the per-profile type share; lower H1's weight);
`TrailPace` 11 out of hearing feels like he is everywhere (watch strays and the leash share; lower to 9 if strays
exceed the cap); the lead point for sprinters places plans in rooms the runner never enters (watch `lost` outcomes;
shorten `Lead`); chases under 2 a floor if triggers are rare (`SpendAfter`); the Reply teaching players that a slam is
safe (it settles the clock, so slams do not buy silence; watch the Lurer report); the first floor's spawn hold and
`FirstHeard` interplay; co-op cues arriving late on clients (a reliable message; the cue's `sd` keeps the variant
equal).

**The beta note** for this stage tells the player, in plain words, that the holes (him crawling through the little
holes) come in the next build, and what the "Monster activity" setting is for.

**The Roblox port mirrors later** (not started without the player's word: [Q] Nov 16 21:45; stage 1 changes no Roblox
runtime file, only the shared config): `CreatureConfig.Lurk` is already shared (I6); the Roblox brain has no presence layer
yet ([C] comments: "the Roblox runtime until its port"), so it ports the presence layer and v3 together from
`docs/MONSTER.md` 22..27: the clock and strain (`LurkRules`), the token rows of the transition table, the near miss,
Patrol's lurk mode, the reach rule, the director's rattle, the locker nudge (HideSpotService).

### Stage 2: the holes

**Delivers:** crawl edges (`crawl.js`), the `Crawl` state with the fold, H3, S4 (with the first-hole weight x3 and the
seen exit), crawlways and the Hallways duct as backstage hold points, grates (Open / Kicked passed, Closed pushed
open, Locked never), the vent chase (follow only with a token, seen within 3 s, another way out), the crawl catch
(stopped 2 s within 3; Easy never), `ExitHold`, `inVent` in the snapshot and the packet, the near miss's fold-in exit
(4.16), and the sounds test failing any director key under 4 variants.

**Files:** `web/src/creature/crawl.js` (new), `states/crawl.js` (new), `service.js` (crawl edges in the walk estimates,
the leash's hold points, the vent chase, the crawl catch, `snapshot().inVent`), `brain.js` (`Crawl` like a beat),
`lurk.js` (H3, S4 feasible), `body.js` only if the kinematic placement needs a quadruped floor height (it already has
anchored placement), `game/coop/creature.js` (`WIRE_STATE.Crawl`), `env.js` (`forceGrate` is there); tests.

**New tests:** creature-sim "vents" rewritten (a moving crawler never caught; he follows only per 5.4; 3.8 in a shared
hole; the catch only when stopped 2 s; never through a `Locked` grate; the exit hold; Easy never catches); "crawl"
(fold time, both mouths, exit clear of players by 12 and unseen, no waiting within 25 of a player); presence-sim: the
Croucher and Hider profiles use crawlways on their way where one is shorter [P], and the Duct class gap (median 32..48
s [P], from 40).

**Acceptance:** stage 1's numbers still hold; a moving crawler caught 0; speed in a shared hole <= 4.5; on a floor with
crawlways, H3 + S4 together are at least 10 % of a Walker's and of a Croucher's interactions [P]; every profile sees
an S4 (fold-in or seen exit) within the first 4 minutes of the first floor with crawlways, on at least 90 % of seeds
[P]; tier-parity with a crawl in its run. Reason: the player asked for the holes twice on Nov 16 [Q]; at the first
version's 3 % a walker (about 16 interactions a floor) would see a fold-in once every two floors.

**Risks:** the body's collision against a culvert 4.8 high and doorways 3 wide [W] (kinematic placement avoids the
walker's box); the rig's `VentCrawl` reading at a mouth (a hunch for 1.2 s may look like a stall: play-test); a
player who sits in a culvert to be safe (the Duct class still pays H3 / S4 every 40 s, and a hole is never a trap).

**The port mirrors later:** crawl edges from the same meta (rooms, `layoutDoors`), the crawl state, the vent chase and
crawl catch rules, the grate rule.

### Stage 3: the rest

**Delivers:** the voice switched on with task #49's recorded lines (`Voice.Enabled = 1`, when they exist and pass the
transcription check of [Q] "He talks good English"), co-op polish (four-player cadence and the split four asserted,
`Starve`, `Stint` and `SpreadRate` tuned on measured runs, every cue through `ccue`), Easy and Nightmare tuned on their
suites, the "Monster activity" column the player picked made the shipped numbers (open question 6), and
`LurkRules.luau` with golden rows (section 10). (S3, F and the H5 hook moved to stage 1.)

**Files:** `lurk.js`, `service.js`, `src/ReplicatedStorage/Shared/Rules/LurkRules.luau` (new, with `golden()` and its
`EXPECT`), `tests/Specs/LurkRules.spec.luau` (new), `web/tools/lurk-test.mjs` (replays `build/cache/golden.json`'s
`LurkRules` rows, as `radar-test.mjs` does RadarRules'), `CreatureConfig.luau` (tuned numbers), presence-sim's
four-player and split-four runs, docs.

**New tests:** the golden replay; four-player and split-four cadence; the voice share with the real lines.

**Acceptance:** all of section 8.3 at their final thresholds (any type <= 30 % per profile); Easy and Nightmare bands;
co-op four: each player >= 70 % of solo cadence; split four: 8.3's split row; with real lines a Walker hears one in
8..15 % of his interactions, never two within 45 s; `lurk-test` green on the golden rows; the whole monster test set
within 8.4's budget.

**Risks:** H5's renormalised weights shifting the mix once enabled (re-run the cadence suite with `Enabled = 1`); the
recorded lines' loudness against the Monster bus (the sounds test measures them as it does every key).

**The port mirrors later:** `LurkRules` is then shared code (the Roblox side requires the module directly); the S3,
F, H1b and Reply behaviour; the voice hook into the Roblox VoiceDirector (RemoteRegistry messages, game-spec-v2 3.7).

---

## 10. Pure shared module, or website JavaScript first?

**Decision: website JavaScript first, written in the port's shape; the Luau module and its golden rows in stage 3.**

- The pattern exists and is the target: `RadarRules.luau` / `LivesRules.luau` (pure, plain data, a `golden()` list of
  `{name, fn, args, expect}` rows pinned in the module's `EXPECT`), exported by `web/tools/export-world.luau` into
  `build/cache/golden.json`, ported to `web/src/game/rules/*.js` and replayed by `web/tools/radar-test.mjs` /
  `lives-test.mjs`; `tools/lune/golden.luau` re-pins rows. `LurkRules` will follow it.
- Not in stage 1, because: (1) nothing on Roblox would call it yet: the Roblox brain does not run the presence layer
  today (`CreatureConfig.luau`'s own comments: "the website's; the Roblox runtime until its port"), so a Luau module
  would have no consumer for two stages; (2) stage 1 is the tuning loop: the rule's shape (the carry, `PlanAhead`, the
  starve rule, the near-miss gates) will change several times on presence-sim's numbers, and every change written
  twice and re-pinned in `EXPECT` costs the builder hours with no parity gained; (3) the numbers are shared from day
  one anyway (`CreatureConfig.Lurk`, I6), which is what keeps the two platforms honest meanwhile; (4) game-spec-v2
  I11 lists the pure-twice directors (chase, takeoff, voice, scare); the monster's director is not among them, and
  [M] already ships the presence director as JS-only.
- **The port's shape from day one** (so the Luau translation is mechanical): `lurk.js` takes and returns plain data
  (numbers, strings, arrays of plain objects keyed by `userId`), no THREE, no clock (time is an argument), no random
  stream (each random draw is an argument `u` in 0..1), no geometry (feasibility from geometry arrives as booleans
  and walk numbers); its functions are `integrate`, `settle`, `who`, `feasible`, `weights`, `order`, `bucket`,
  `spend`, `snapshot`. The geometry (placements, reach, the leash's search) stays runtime code on each platform, as
  `beats.js` does today.
- Stage 1's `lurk-test` replays a JSON fixture of rows in exactly the golden format, so stage 3 only changes where
  the rows come from.

---

## 11. Open questions (each with the default to build on)

1. **Easy in the lobby?** `Enums.Difficulty` has only Standard and Nightmare. **Default:** Easy's numbers ship in
   `CreatureConfig.Lurk` and the sims run it; the lobby does not offer it until the player asks for an easier mode.
2. **H5 before recorded voices?** **Default:** off (`Voice.Enabled = 0`): no browser voice, no subtitle over a growl
   (section 7); the hook, the three event offers and a stub ship in stage 1; it switches on with task #49's files.
3. **May he push a Closed grate open?** **Default:** yes (`MetalCreak`, the grate stays open, honest and heard);
   never a `Locked` one; stage 2.
4. **What binds "not harder than today"?** The research proposes a sprinter's 0.5..1.2 downs a floor; [M 20] ships
   0.3..0.8. **Default:** today's band **and** the v2 baseline measured on the unchanged tree (mean + 0.05 at most);
   the research's higher band is rejected.
5. **How does the near miss leave?** **Default:** he walks out of their sight when a route exists that does so within
   3 s; else he backs away facing them at 9 for up to 6 s; from stage 2 he may fold into a hole within 20 walked; the
   give-up dissolve (`FadeOut`) only last. `ChaseSting` at the screech, `GiveUpSwell` as he turns; never a
   reappearance in view.
6. **Is the pace right?** The player called his numbers "only ideas" [Q, Nov 16 15:30] and the research ends with
   "ask: too much, too little, or right?". **Default:** on the beta only, a setting "Monster activity: Less / Normal /
   More" multiplies every `Clock.Gap` by `Clock.Activity` (1.4 / 1 / 0.75) [P] and nothing else (not danger, not the
   chase budget); the host's choice rules a co-op run. Ask the player which he plays on; the column he picks becomes
   the shipped numbers in stage 3. Not shown on the main site.

---

## 12. Review outcome

The player's-lens review (`scratchpad/mv3/review-player.md`) raised 22 findings. Each claim about code was checked in
the file it cites before it was accepted: `GameConfig.luau` (stamina, speeds), `web/tools/presence-sim.mjs`
(`STAMINA_RECOVERED` 25), `web/src/creature/index.js` (`nearFloor`, `NEAR_FLOOR_FAR` 0.27, radius from
`Presence.Audio.NearRadius`), `web/src/game/ui/hints.js` (the same radius), `docs/MONSTER.md` 3.3, 6.7, 7.2, 8.1, 8.2,
11, 16, 17, 18, `docs/design/requirements.md` 6 (the quotes and decisions), `web/src/creature/animator.js`
(backpedalling exists), `profile.js` (the `Chase` cycle's `sprint` footsteps), `web/build/audio` (variant counts).
"Partly" means the finding's problem is accepted and fixed, with a different mechanism for the part named.

| Id | Severity | Outcome | Why (one line) | Where it changed |
|---|---|---|---|---|
| P1 | blocker | accepted | Stamina limits a sprinter to about 63 % sprint, so 17 s measures 20..21 s, outside "15 if sprinting". | 2.2 `Gap.Sprint` 14; 2.3 row with the arithmetic; 2.5; 8.3 creature-sim SPEC |
| P2 | blocker | accepted | Against a runner only far steps and teleports could land; a sprinter's slots failed or were filled by teleports. | 4.0 lead point; 4.1b H1b running steps (new); S3 and F moved to stage 1 (4.8, 4.14, 5.2 built, 9); 3.4 step 5 fallback not exempt from `lastType`; 8.3 per-profile type cap, Approach + C3 one item <= 25 %; `FitOf.Sprint` H1b for C3 |
| P3 | major | partly | He was slower than a walker, so the leash was held by teleports and "ahead" hold points broke the clearance. Accepted (b), (c), (d) as written. (a) changed: repositioning out of everyone's hearing trails at 11 (`Beats.ShadowFast`), never heard; near an ear, moves wait for a slot and are made as H1/H1b; the approach only beyond 90 with no 12 s route at 13. Making every catch-up an audible run would have flooded the cadence with strays. | 3.6 movement rules; 5.5 hold point ranking and getting there; 3.4 step 5 (b); 2.2 `Leash.*`, `Clock.TellHolds`, `WarnMax`, `WarnWindow`; 8.3 warnings row |
| P4 | blocker | accepted | Verified: the heartbeat runs within 45 straight whenever he is shown, which the 25..55 leash makes nearly always. | 3.6 heartbeat; 2.2 `Heart`; 2.4 `Audio.NearRadius` row; 5.7 `cst.al`; 6 heartbeat row; 8.3 heartbeat row; section 1 item 4 |
| P5 | major | accepted | A steady walker got a flat 24..36 s rhythm with no lull; mean kept by `LullComp` 7/6 instead of dividing each Gap by 1.17 (same effect, Gap stays the felt mean). | 2.2 `ThetaMin/Max` 0.6/1.4, `Lull*`, `LullComp`; 3.2 settle; 2.3; 8.3 p90 and lull rows |
| P6 | major | accepted | The 150 s window after a chase was readable and farmable. | 5.6 refill draw, short-chase refund; 5.3 Reply (an empty bucket is not readable); 2.2 `Chase.*`; 8.3 unchanged chase and downs targets |
| P7 | major | accepted | A screech without music became harmless after two; 0.43 strain did not reach backstage; the exit was often a dissolve; four players could get a screech every 11 s. | 4.16 near miss (sting, swell, back-away, fold, dissolve last); 3.3 backstage rule; 5.6 `NearMissSquad`; 11 question 5 |
| P8 | blocker | partly | Accepted: a director C4 never spends a token or downs anyone; a breath check catches only in an encounter the hider caused; gate Hider downs 0. Rejected the breath-meter refill (a visible, unexplained jump of the HUD meter); replaced by clipping the window to the breath left minus 0.5, which keeps an early held breath enough. | 4.13; 5.6 spending and without-token rows; 6 hiding row; 8.3 Hider downs row |
| P9 | blocker | accepted | Hiding from a peek in his sight could spend the token on a hiding watch; without a token a slam or a thrown flask did nothing perceivable and the flask sped up the thrower's own clock. Scope kept: a noticed sighting during C2 or C3's stalk stays a provocation, since keeping out of his cone is that interaction's counterplay. | 5.6 defence rule; 4.17 Reply (new); 5.3; 3.2 `LumpNear`; 2.2 `Reply`, `DefenceWindow`; 4.11 |
| P10 | major | accepted | `SpendWeight` pushed the chase-leading interactions at the quietest player. | 5.2 weight `spend` condition; 2.2 `SpendLoud`; 5.6 expected chases; 8.3 Croucher 0..2 |
| P11 | major | accepted | Verified: the shove at 45 s [M 8.2] came before a 75 s gap, so most hides got nothing. | 5.2 owed hide; 2.2 `HideAfter`, `HideOwedMin/Max`, `FitOf.Hiding`; 3.1 `hideOwedAt`; 8.3 hides row and Hider band |
| P12 | major | accepted | One body flipped between two groups by teleport and served neither. | 5.1 stint; 2.2 `Coop.Stint`, `StintCount`, `Starve` 60; 4.16 the stint's approach heard; 5.6 repeat-target rule; 8.1 split pair (stage 1) and split four (stage 3); 8.3 split and spread rows; section 1 item 10 |
| P13 | minor | accepted, extended | `SamePlayer` was in no rule; a tight group was paid faster than solo. Beyond the finding: players within 15 of the target settle a full theta (one clock per area, [Q] Nov 16 15:30), which removes the faster group rate the `SamePlayer` rule alone would not. | 3.2 settle and tight-group arithmetic; 3.4 step 4; 5.2 timers; 2.2 `HeardCost`; 8.3 co-op lower bound; section 1 item 5 |
| P14 | major | accepted | Standing still was paid faster than crouching, against the lead's "Standing still or hidden: slower still". | 3.5 Work and Still; 2.2 `Gap.Work`, `Gap.Still`, `WorkWindow`, `FitOf`; 3.2 `workAt`; 2.5 |
| P15 | minor | accepted, phased | Verified counts: WetBreath, TeleportHiss, Screech, ChaseSting, GiveUpSwell, CreatureVanish 2; LockerDoor, MetalCreak, TorchStutter 3. The sounds test reports in stage 1 and fails from stage 2, so stage 1 still runs on today's sounds. | 4.0 variants; 9 stage 1 files, stage 2 delivers |
| P16 | major | accepted | At 3 % the holes the player asked for twice would go unnoticed. | 4.9 first-hole weight and the seen exit; 5.4 exit rule; 2.2 `FirstHoleWeight`, `MouthSeenWalk`; 9 stage 2 acceptance; 9 stage 1 beta note |
| P17 | major | accepted | The hook was last although the lead decided the lines are built now; v3's own moments had no voice event. | 7 event offers, hook and stub in stage 1; 4.0; 4.7, 4.8, 4.11, 4.16; 2.2 `Voice.Offers`; 8.3 voice row; 9 |
| P18 | major | partly | Accepted (a) heavy when seen, (c) strays logged and charged, (d) no torch stutter on the approach. (b) changed: he mostly stands, but a move out of everyone's hearing may trail at 11 between slots (moves near an ear wait for a slot, as asked); the strict form would bring back the teleports of P3. | 3.6 rules 1 to 5; 4.0 `Stray`; 4.16 approach; 8.3 strays row |
| P19 | major | accepted | "Not harder" was measured in downs only; a careful player's time was not. | 8.3 careful time row; 8.4 baseline records objectives done; 9 stage 1 acceptance |
| P20 | minor | accepted | Backstage did not stop a backstage player's own noise from pulling him; chases and near misses were not in the gap measure. | 3.3 backstage noise; 5.3 `token`; 4.0 records; 8.2 |
| P21 | minor | accepted | Three counterplay texts contradicted the rules. | 4.1 the tell stays true (12 s, same side); 4.4 the door stays ajar; 4.8 the target's stare off during a vantage, the torch ends it with a walk back |
| P22 | minor | accepted | His numbers were "only ideas" and he had no way to answer but another build. | 11 question 6; 2.2 `Clock.Activity`; 3.2 rate; 5.7; 9 stage 1 |

Rejected outright: none. Rejected in part: P8's breath refill, P3 (a)'s audible catch-up runs, P18 (b)'s "every move
over 10 studs only in a slot"; each is replaced by the mechanism named in its row.
