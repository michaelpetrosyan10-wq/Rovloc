--!strict
-- The Creature ("the Tall Man", docs/MONSTER.md and docs/MONSTER-LOOK.md): rig dimensions, per-state speeds, senses,
-- the hiding, teleport and give-up rules and navigation. Seconds and studs. The numbers are Standard; Nightmare scales
-- them through DifficultyConfig (faster, keener senses, a longer chase, a shorter teleport cooldown), but nothing
-- outside a Scripted beat ever moves faster than SpeedCap, a sprinting player's pace less a margin. The website mirrors
-- these in web/src/creature/config.js.

local CreatureConfig = {}

CreatureConfig.Rig = table.freeze({
	Height = 11, -- standing, floor to the crown
	HunchedHeight = 9, -- bent under a 10-11 stud tunnel ceiling
	RootSize = Vector3.new(2.6, 2.6, 1.4),
	HipHeight = 3.4, -- root centre sits HipHeight + RootSize.Y / 2 above the floor
	ArmLength = 6.3, -- shoulder to the middle fingertip: the hands hang below the knees
	FingerLength = 1.3, -- long, tapering, black; no claws
	Reach = 4, -- how far from its root a catch reaches
	ShadowColor = Color3.fromRGB(12, 12, 15), -- the body: matte near-black with a faint sheen
	MaskColor = Color3.fromRGB(205, 194, 166), -- the porcelain mask: ivory, not white
	PupilColor = Color3.fromRGB(255, 244, 214), -- pinprick glows deep in the eye holes
})

CreatureConfig.Hitbox = table.freeze({
	Biped = Vector3.new(2.6, 11, 2.7),
	Hunched = Vector3.new(2.6, 9, 4.2),
	Quadruped = Vector3.new(2.8, 2.8, 6),
} :: { [string]: Vector3 })

-- Eye position above the root centre, per PoseMode (Perception, the stare, the reveal, the catch's eye line and the
-- jumpscare camera). Its eye is the one of the pose it stands in: hunched under a low clearance, never the standing
-- eye (10.34 over the floor) inside a tunnel's ceiling. Stunned: it claws at its mask, bent.
CreatureConfig.EyeHeightAboveRoot = table.freeze({
	Biped = 5.64,
	Hunched = 3.6,
	Quadruped = 0.5,
	Stunned = 4.6,
} :: { [string]: number })

CreatureConfig.Speeds = table.freeze({
	Dormant = 0,
	Patrol = 7, -- the Stalk: slower than a walking player (11)
	InvestigateNoise = 9,
	WallChase = 16.5, -- the Chase: a sprinter (19) gains on it, a walker (11) loses ground
	Search = 8,
	HidingResponse = 7,
	Teleport = 7, -- the stalk toward its target after it forms
	Stunned = 3, -- stumbling retreat
	Scripted = 16,
	VentChase = 17, -- legacy: the old duct crawl's pace (the animator scales a duct scrape by it); never the brain's
} :: { [string]: number })

-- The most any state but Scripted may move (a sprinting player runs 19).
CreatureConfig.SpeedCap = 18.5

-- It walks hunched (PoseMode Hunched) where the clearance (a lintel, a tunnel's ceiling, a room) is under this, at its
-- root or along its way just ahead.
CreatureConfig.HunchBelow = 12.5

CreatureConfig.Senses = table.freeze({
	-- sight range by the player's light: torch on, torch off in a lit pool, torch off in the dark; crouched x0.75
	SightTorch = 70,
	SightLit = 38,
	SightDark = 20,
	CrouchFactor = 0.75,
	-- the fixture light (luminance) at the player's chest above which they stand in a lit pool (LightField)
	LitIrradiance = 0.2,
	-- the view cone, about its upright axis: wider when the player moves; anything this close along the floor is felt
	-- whatever the facing
	SightHalfAngle = 55,
	MovingHalfAngle = 75,
	PeripheralRange = 6,
	MovingPeripheralRange = 10,
	MovingSpeed = 2, -- studs/s: above this a player moves
	HearingMultiplier = 1,
	MemorySeconds = 9, -- last-known-position lifetime after losing sight
	CatchDistance = 4, -- catch reach (Rig.Reach)
	CatchVertical = 5,
	EmfRadius = 15, -- torch static within this
	NearRadius = 25, -- heartbeat and breathing within this, seen or not (superseded by Presence.Audio.NearRadius,
	-- docs/MONSTER.md 19: the website's; the Roblox runtime until its port)
	RattleRadius = 22, -- the low rattle while it stalks this close (superseded by Presence.Audio.RattleRadius,
	-- docs/MONSTER.md 19: the website's; the Roblox runtime until its port)
})

-- Its footsteps (SynthPresets CreatureStepWalk* / CreatureStepChase*: its own sounds, never a player's). RollOffMin and
-- RollOffMax are their 3D distances (full level within Min, silent from Max); HeardTo is how far away its quietest
-- footfall must still stand at least 6 dB over the floor's ambience (the sound audit and web/tools/audio-test.mjs
-- measure it, every variant): his footsteps are loud so that everyone knows when he is around. RollOffMin 28 puts
-- him 6.9 dB louder at HeardTo than 14 did (InverseTapered: -13.5 dB there, not -20.4).
CreatureConfig.Footfalls = table.freeze({ RollOffMin = 28, RollOffMax = 160, HeardTo = 80 })

-- Looking straight at it: a player whose view centre stays within HalfAngle of its head for Seconds, within LitRange
-- (it stands lit, or their torch is on) or DarkRange, with a clear line, starts a chase. RevealHalfAngle: the target
-- turning to look at it as it forms after a teleport gets the reveal scare.
CreatureConfig.Stare = table.freeze({ HalfAngle = 7, Seconds = 1, LitRange = 45, DarkRange = 18, RevealHalfAngle = 22 })

CreatureConfig.Search = table.freeze({ MinSeconds = 12, MaxSeconds = 18, Radius = 15, Spots = 4 })

CreatureConfig.Investigate = table.freeze({ MinSeconds = 6, MaxSeconds = 10, Spots = 2 })

-- The saw-you-hide rule (HidingResponse) and the hiding spots' own limit (HideSpotService).
CreatureConfig.Hiding = table.freeze({
	SeenWindow = 1.5, -- seen this recently when they got in: it saw them hide
	StandOff = 2.6, -- where it stands, out from the spot's front
	LookAwayMin = 7,
	LookAwayMax = 10,
	LookAwaySeconds = 2.5,
	GruntLead = 0.7, -- the low grunt this long before each LookAway
	ReachInSeconds = 30,
	ReachInLead = 0.6, -- the ReachIn action runs this long before the catch
	CatchRange = 6, -- stepping out within this while it is not looking away is a catch
	PullStartle = 1.2, -- a teammate's pull-out startles it (blind) this long
	KickOutSeconds = 45,
	KickOutWarning = 35,
	PullSeconds = 1.2, -- the Pull out prompt's hold
	PullReach = 7, -- the puller stands within this of the spot's exit
	HurriedWindow = 1, -- sprinting this recently before getting in is a hurried (louder) entry
})

-- The teleport (THRESHOLD's jumpscare engine, docs/MONSTER.md 7.2).
CreatureConfig.Teleport = table.freeze({
	UnseenSeconds = 25, -- nobody seen this long
	FirstAfterGrace = 45, -- the first one comes this long after the floor's grace
	AfterCatch = 25, -- never within this of a catch or a player going down
	MinWalk = 12,
	MaxWalk = 24,
	MinStraight = 12, -- never this close (straight line) to anyone
	BehindShare = 0.6,
	Isolated = 25, -- a target this far from every teammate weighs more
	LoudWindow = 20, -- heard from this recently weighs more
	WarningSeconds = 1.6,
	FlickerRadius = 20,
	FadeOutSeconds = 0.6,
	FadeInSeconds = 0.8,
	StareSeconds = 1.2,
	StalkSeconds = 10, -- after the stare it stalks the target; sight alone does not start a chase meanwhile...
	StalkNear = 7, -- ...unless they come this close (superseded by Presence.Teleport.StalkSight, docs/MONSTER.md 18.4:
	-- the website's; the Roblox runtime until its port)
	ViewHalfAngle = 80, -- a player "sees" a point inside this cone of their look with a clear line
	Retries = 2,
})

-- A chase that gives up: it FadeOuts and comes back out of sight at least this far from everyone (MaxDistance is no
-- bound at all: finite only so the web export's JSON can carry it).
CreatureConfig.GiveUp = table.freeze({ MinDistance = 45, MaxDistance = 1e6 })

-- The floor's grace after it is first released on a level (the spawn hold), by difficulty.
CreatureConfig.FloorGrace = table.freeze({ Standard = 20, Nightmare = 12 } :: { [string]: number })

-- The floor nav's agent (MonsterAIService/FloorNav): its hunched height, so it passes under nothing lower and never
-- into a crawlway (4.3); no jumping or climbing.
CreatureConfig.PathAgent = table.freeze({
	AgentRadius = 2,
	AgentHeight = 9,
	AgentCanJump = false,
	AgentCanClimb = false,
	WaypointSpacing = 4,
	Costs = table.freeze({ MonsterPassthrough = 1.5 } :: { [string]: number }),
})

CreatureConfig.Repath = table.freeze({
	ChaseInterval = 0.35,
	PatrolInterval = 2,
	StuckSeconds = 2.5, -- no progress for this long triggers an out-of-sight reposition
})

CreatureConfig.Jumpscare = table.freeze({
	LungeSeconds = 0.45,
	HoldSeconds = 1.4,
	FaceDistance = 1.6, -- a straight lunge's face distance (Vent spacing)
	HoldDistance = 1.35, -- the victim's camera off the mask during the lock (docs/MONSTER-LOOK.md HOLD_DISTANCE)
	-- root to root (docs/MONSTER.md 9): far enough back for the bow to bring the mask level with the victim's eye; it
	-- eases back no nearer than the minimum, and only as far as its body clears the walls
	Spacing = table.freeze({ Hallway = 4.2, Locker = 4.4, Vent = 2.8 } :: { [string]: number }),
	MinSpacing = table.freeze({ Hallway = 3.4, Locker = 3.6, Vent = 2.3 } :: { [string]: number }),
})

-- DOORS-Jack fake-outs: about one hiding spot in FakeoutOneIn holds one (seeded per run), at most one per floor per
-- player.
CreatureConfig.FakeoutOneIn = 12

-- A number per difficulty.
local function pair(standard: number, nightmare: number): { [string]: number }
	return table.freeze({ Standard = standard, Nightmare = nightmare })
end

-- The presence layer (docs/MONSTER.md 15-19): the director that keeps the Tall Man near the players, the presence
-- beats, the senses' additions, the chase's wind-up, pursuit and cap, the cut-off teleport and how far its sounds
-- carry. The website runs it (meta.creatureConfig.Presence); the Roblox port follows from the spec. A {Standard,
-- Nightmare} pair is a number per difficulty. Where it differs from the tables above (the chase's cap and the time it
-- loses its quarry in, DifficultyConfig.maxChaseSeconds / chaseLostSeconds; the breather after a chase or a catch,
-- PacingDirector's RelaxSeconds; the teleport's stalk, Teleport.StalkNear; the rattle and the heartbeat,
-- Senses.RattleRadius / NearRadius), the website takes these; each superseded entry names its replacement.
CreatureConfig.Presence = table.freeze({
	Director = table.freeze({
		Interval = 1, -- it reads the players and re-plans once a second
		FarWalk = 70, -- a player's menace rises while it is farther than this walked from them, unseen, not after them
		MenaceSeconds = pair(55, 40), -- far this long: menace full (0..1)
		StartMenace = 0.5, -- every player's menace as a level activates
		HintMenace = 0.2, -- a search hint once the focus player's menace reaches this...
		LeashWalk = 100, -- ...and it is farther than this walked from them
		HintMin = 30, -- the hint: a point this far walked from them (never where they stand)...
		HintMax = 55, -- ...out of everyone's view, ahead of the way they go first
		HintTries = 14, -- floor points asked (nearest it first)
		HintEvery = 8, -- no new hint sooner than this
		HintPace = 9, -- it walks to a hint (and to a beat's start) at this pace
		PatrolPace = 7, -- the Stalk's pace (a pass-by, a peek's step out, a shadow at the least)
		AheadDot = 0.4, -- "ahead of the way they go": the cosine with their travel at least this
		ApproachWalk = 90, -- the walk to a hint longer than this: the approach teleport first
		ApproachMin = 45, -- it lands this far walked from them...
		ApproachMax = 80,
		ApproachTries = 60,
		ApproachCooldown = 25,
		QuietSeconds = pair(40, 35), -- after an encounter with a player (a chase, a beat, them seeing it)
		QuietAfterCatch = pair(45, 40), -- after a catch of a player
		StarveSeconds = 75, -- co-op: a player left alone this long goes first
		BeatMenace = 0.5, -- a beat once the focus player's menace reaches this...
		BeatWalkMin = 30, -- ...and it is this far walked from them
		BeatWalkMax = 140,
		BeatEvery = pair(35, 25), -- between two beats
		BeatRetry = 6, -- no beat fitted the floor: the next try
		FirstBeat = 20, -- the first beat on a floor no sooner than this after its activation
		SeenRange = 80, -- a player sees it: within this...
		SeenHalfAngle = 50, -- ...inside this of their look (the screen's half width), with a clear line
	}),
	Beats = table.freeze({
		Near = 12, -- while a beat plays only a player this close (or a stare) starts a chase (not a pass-by)
		ReachWalk = 30, -- a beat reached its player (an encounter) once they saw it or it came this close walked
		BreakOff = 18, -- a player this close (straight) ends a beat (not a pass-by): it withdraws
		SafeWalk = 25, -- every stand point of a beat this far walked from every player at least
		HideWalk = 25, -- a hiding spot within this walked of the player a beat plays to
		ApproachWalk = 100, -- it can walk to the beat's start within this
		ApproachSeconds = 20, -- and gets there within this, or the beat is off
		PeekMin = 30, -- Peek: the stand point this far from the player...
		PeekMax = 70,
		PeekCone = 45, -- ...within this of the way they face or go
		CornerMin = 5, -- the corner it steps out from, this far from the stand point, out of everyone's sight
		CornerMax = 14,
		PeekHoldMin = 1.5, -- it stands in view this long
		PeekHoldMax = 3,
		GlimpseMin = 30, -- Glimpse: the crossing this far ahead...
		GlimpseMax = 70,
		GlimpseCone = 35, -- ...within this of the way they face or go
		CrossMin = 6, -- its two ends this far from the crossing, out of everyone's sight
		CrossMax = 16,
		GlimpsePace = 12,
		ShadowMin = 30, -- Shadow: it stops closer than this walked...
		ShadowMax = 50, -- ...and hurries farther than this
		ShadowStart = 70, -- it starts within this walked behind them
		ShadowGap = 40, -- how far back along their trail it walks to
		ShadowBehind = 0.3, -- "behind": the cosine of their travel with the way to it under minus this
		ShadowMoving = 3, -- only a player moving faster than this is shadowed
		ShadowFast = 11, -- its pace catching up (and the most it ever walks shadowing)
		ShadowRunning = 14, -- a player moving faster than this (a sprint) is not shadowed: they would leave it behind
		ShadowMinSeconds = 15,
		ShadowMaxSeconds = 25,
		FreezeAngle = 25, -- their view within this of its head (a clear line): it freezes
		PassMoving = 6, -- Pass-by: only for a player moving no faster than this (one on the run would run into it)
		PassNear = 18, -- the point it passes through, this far from the player...
		PassFar = 28,
		PassWalk = 20, -- ...and this far walked at least
		PassOn = 20, -- it walks on this far past that point...
		PassOnMax = 40,
		PassClear = 30, -- ...to a point this far from the player at least
		Weights = table.freeze({ PassBy = 0.2, Peek = 0.3, Glimpse = 0.3, Shadow = 0.2 }),
	}),
	Detection = table.freeze({
		GlowEvery = 0.5, -- a lit torch's glow is looked for this often
		Beam = 30, -- the spot a torch lights: this far along the look, or the first surface
		GlowRange = 90, -- it sees that spot from this far (x the difficulty's sight multiplier), inside its cone
		StillDarkFactor = 0.5, -- standing still in the dark (torch off, unlit): its sight range x this
		NoticeNear = 8, -- noticing: within this a player in sight is noticed at once...
		NoticeSeconds = pair(2, 1.8), -- ...at its full sight range after this; in between, in proportion
		NoticeDecay = 0.6, -- out of sight the noticing drains this much a second
	}),
	Chase = table.freeze({
		CapSeconds = pair(12, 45), -- a chase gives up after this, whatever happens (it fades away)
		LostSeconds = pair(4, 6), -- its quarry unseen this long: it searches
		Pursuit = pair(30, 40), -- from the last place it saw them it runs on this far the way they fled
		Windup = pair(1.5, 0.7), -- a fresh chase screeches and holds this long before it runs (no catch meanwhile)...
		SurpriseRange = 20, -- ...and this long when its target stands this close as it starts (met round a corner)
		SurpriseWindup = pair(2.8, 2),
		Breather = pair(35, 15), -- after a chase or a catch the hunt eases off (the pacing's Relax) at least this long
	}),
	Teleport = table.freeze({
		CutOffShare = pair(0.75, 1), -- a teleport tries ahead of the target's way first this share of the time (Nightmare:
		-- always; formed behind a sprinter it is left behind before it can stalk, and a floor can open with no presence)
		CutOffMin = 24, -- a moving target is cut off this far walked ahead...
		CutOffMax = 70, -- ...at most (else Teleport.MinWalk..MaxWalk)
		StalkSight = pair(40, 50), -- after its stare a player it has noticed within this is chased
	}),
	Audio = table.freeze({
		RattleRadius = 45, -- the rattle in its throat while it stalks this close
		NearRadius = 45, -- the heartbeat and breathing within this, seen or not
	}),
})

-- A frozen table as plain, unfrozen data.
local function plain(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = plain(v)
	end
	return out
end

-- The numbers the website reads or mirrors, as plain data (world.json meta.creatureConfig): the presence layer
-- (presence.js reads it) and the tables web/src/creature/config.js mirrors (the data test compares them).
function CreatureConfig.exportMeta(): { [string]: any }
	return {
		Presence = plain(CreatureConfig.Presence),
		Speeds = plain(CreatureConfig.Speeds),
		SpeedCap = CreatureConfig.SpeedCap,
		HunchBelow = CreatureConfig.HunchBelow,
		Senses = plain(CreatureConfig.Senses),
		Stare = plain(CreatureConfig.Stare),
		Search = plain(CreatureConfig.Search),
		Investigate = plain(CreatureConfig.Investigate),
		Teleport = plain(CreatureConfig.Teleport),
		FloorGrace = plain(CreatureConfig.FloorGrace),
		FakeoutOneIn = CreatureConfig.FakeoutOneIn,
	}
end

return table.freeze(CreatureConfig)
