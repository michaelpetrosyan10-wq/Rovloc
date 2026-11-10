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
	Swim = Vector3.new(3, 3, 10),
} :: { [string]: Vector3 })

-- Eye position above the root centre, per PoseMode (Perception, the stare, the reveal, the catch's eye line and the
-- jumpscare camera). Its eye is the one of the pose it stands in: hunched under a low clearance, never the standing
-- eye (10.34 over the floor) inside a tunnel's ceiling. Stunned: it claws at its mask, bent.
CreatureConfig.EyeHeightAboveRoot = table.freeze({
	Biped = 5.64,
	Hunched = 3.6,
	Quadruped = 0.5,
	Swim = 0.4,
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
	AquaticStalk = 6.5, -- Floor 4 fairness: slower than a freestyle swimmer (9), faster than one treading water (4)
	AquaticLunge = 18,
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
	NearRadius = 25, -- heartbeat and breathing within this, seen or not
	RattleRadius = 22, -- the low rattle while it stalks this close
})

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
	StalkNear = 7, -- ...unless they come this close
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
	FaceDistance = 1.6, -- a straight lunge's face distance (Vent, Underwater spacing)
	HoldDistance = 1.35, -- the victim's camera off the mask during the lock (docs/MONSTER-LOOK.md HOLD_DISTANCE)
	-- root to root (docs/MONSTER.md 9): far enough back for the bow to bring the mask level with the victim's eye; it
	-- eases back no nearer than the minimum, and only as far as its body clears the walls
	Spacing = table.freeze({ Hallway = 4.2, Locker = 4.4, Vent = 2.8, Underwater = 2.6 } :: { [string]: number }),
	MinSpacing = table.freeze({ Hallway = 3.4, Locker = 3.6, Vent = 2.3, Underwater = 2 } :: { [string]: number }),
})

-- The pool (Floor 4 fairness): every lunge is telegraphed (rising bubbles, a ripple ring and a low growl at its origin)
-- for TelegraphSeconds with the Creature held still, then may run for LungeWindow before a new telegraph is needed;
-- LungeCooldown after a lunge that missed. Any swim but a lunge is capped at the AquaticStalk pace. In or from the
-- water the telegraphed grab is its only catch. It enters and leaves the water only by FadeOut / FadeIn out of sight
-- (FadeOnly), never climbing out at the deck and never through the vents, and comes back out on land at least ExitMin
-- from every player. PoolGraceSeconds after any player first enters a pool room it leaves the pool rooms alone; after
-- any grab it retreats to the far end of the water for GrabRetreatSeconds.
CreatureConfig.Water = table.freeze({
	LungeRange = 9,
	TelegraphSeconds = 1.2,
	LungeWindow = 2.5,
	LungeCooldown = 2,
	FadeOnly = true,
	ExitMin = 30,
	PoolGraceSeconds = 20,
	GrabRetreatSeconds = 15,
	MurkRange = 10, -- a swimmer under the surface sees it only this close
})

-- DOORS-Jack fake-outs: about one hiding spot in FakeoutOneIn holds one (seeded per run), at most one per floor per
-- player.
CreatureConfig.FakeoutOneIn = 12

return table.freeze(CreatureConfig)
