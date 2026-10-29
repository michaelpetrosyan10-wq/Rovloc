--!strict
-- The Creature: rig dimensions, per-state speeds, senses and navigation. Difficulty multipliers apply on top.

local CreatureConfig = {}

CreatureConfig.Rig = table.freeze({
	Height = 8.5,
	RootSize = Vector3.new(2.6, 2.6, 1.4),
	HipHeight = 3.4, -- root centre sits HipHeight + RootSize.Y / 2 above the floor
	ArmLength = 4.6, -- elongated arms, shoulder to fingertip
	ClawLength = 0.5, -- six inches at the game's ~1 stud = 1 foot scale
	SkinColor = Color3.fromRGB(214, 210, 198),
	HairColor = Color3.fromRGB(12, 11, 12),
	EyeSocketColor = Color3.fromRGB(4, 4, 5),
	PupilColor = Color3.fromRGB(255, 244, 214),
	GrinColor = Color3.fromRGB(28, 9, 9),
	ToothColor = Color3.fromRGB(226, 220, 196),
})

CreatureConfig.Hitbox = table.freeze({
	Biped = Vector3.new(3, 8, 2),
	Hunched = Vector3.new(3, 6, 3),
	Quadruped = Vector3.new(2.8, 2.8, 6),
	Swim = Vector3.new(3, 3, 7),
} :: { [string]: Vector3 })

-- Eye position above the root centre, per PoseMode (used by Perception and the jumpscare camera).
CreatureConfig.EyeHeightAboveRoot = table.freeze({
	Biped = 3.1,
	Hunched = 1.6,
	Quadruped = 0.5,
	Swim = 0.4,
} :: { [string]: number })

CreatureConfig.Speeds = table.freeze({
	Dormant = 0,
	Patrol = 8,
	InvestigateNoise = 13,
	WallChase = 21,
	VentChase = 17,
	Stunned = 3, -- stumbling retreat
	AquaticStalk = 6.5, -- Floor 4 fairness: slower than a freestyle swimmer (9), faster than one treading water (4)
	AquaticLunge = 18,
	Scripted = 16,
} :: { [string]: number })

CreatureConfig.Senses = table.freeze({
	SightRange = 95,
	SightHalfAngle = 62, -- degrees either side of the facing direction
	PeripheralRange = 14, -- notices players this close regardless of facing
	DarknessSightMultiplier = 0.6, -- players without a lit flashlight are seen at this fraction of range
	HearingMultiplier = 1,
	MemorySeconds = 9, -- last-known-position lifetime after losing sight
	CatchDistance = 4.6,
	VentCatchDistance = 3.4,
	EmfRadius = 45,
})

-- PathfindingService agent for floor navigation. Doorways are 6x10 so this agent always fits.
CreatureConfig.PathAgent = table.freeze({
	AgentRadius = 2,
	AgentHeight = 8,
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
	FaceDistance = 1.6, -- camera distance from the face during the lock
})

-- The pool (Floor 4 fairness, mirrored by the web build): every lunge is telegraphed (rising bubbles, a ripple ring and
-- a low growl at its origin) for TelegraphSeconds with the Creature held still, then may run for LungeWindow before a
-- new telegraph is needed; LungeCooldown after a lunge that missed. Any swim but a lunge is capped at the AquaticStalk
-- pace. In or from the water the telegraphed grab is its only catch. It leaves a pool only through the pool's own vent
-- route (VentExitOnly) and comes back out on land unseen, at least PoolExitMin studs from every player. PoolGraceSeconds
-- after any player first enters a pool room it leaves the pool rooms alone; after any grab it retreats to the far end
-- of the water for GrabRetreatSeconds.
CreatureConfig.Water = table.freeze({
	LungeRange = 9,
	TelegraphSeconds = 1.2,
	LungeWindow = 2.5,
	LungeCooldown = 2,
	VentExitOnly = true,
	PoolExitMin = 30,
	PoolGraceSeconds = 20,
	GrabRetreatSeconds = 15,
})

return table.freeze(CreatureConfig)
