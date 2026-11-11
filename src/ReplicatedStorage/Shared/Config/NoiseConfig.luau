--!strict
-- Decibel model: every noise pulse has a stud radius and a priority. The spec's numbers are canonical.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)

export type NoiseSpec = {
	radius: number,
	priority: Enums.NoisePriority,
	medium: Enums.NoiseMedium,
	interval: number, -- seconds between pulses while the action continues (0 = one-shot)
}

local NoiseConfig = {}

-- The Tall Man's ears (docs/MONSTER.md 3.1): it hears a sprint from far away, a walk from the next junction, a crouch
-- only when it is all but on you.
NoiseConfig.Kinds = table.freeze({
	CrouchWalk = { radius = 5, priority = "Low", medium = "Air", interval = 0.6 },
	SlowVentCrawl = { radius = 8, priority = "Low", medium = "Vent", interval = 0.7 },
	GrateUnscrew = { radius = 10, priority = "Low", medium = "Air", interval = 0.9 },
	Walk = { radius = 22, priority = "Normal", medium = "Air", interval = 0.45 },
	Gasp = { radius = 40, priority = "High", medium = "Air", interval = 0 },
	FlaskShatter = { radius = 50, priority = "High", medium = "Air", interval = 0 },
	Sprint = { radius = 60, priority = "High", medium = "Air", interval = 0.3 },
	-- any landing after a fall of JumpLandAirborne seconds or more, on foot
	JumpLand = { radius = 26, priority = "Normal", medium = "Air", interval = 0 },
	-- climbing into a hiding spot (a locker, a barrel, a cabinet): quietly, or hurried (sprinting a moment before)
	HideEnter = { radius = 8, priority = "Low", medium = "Air", interval = 0 },
	HideEnterHurried = { radius = 14, priority = "Normal", medium = "Air", interval = 0 },
	VentScurry = { radius = 90, priority = "High", medium = "Vent", interval = 0.3 },
	GrateKick = { radius = 130, priority = "Critical", medium = "Air", interval = 0 },
	FloorDebris = { radius = 130, priority = "Critical", medium = "Air", interval = 0 },
	TrapSnap = { radius = 130, priority = "Critical", medium = "Air", interval = 0 },
	DoorSlam = { radius = 90, priority = "Critical", medium = "Air", interval = 0 },
	-- Something knocked loose (a scripted Level 0 ambience beat): a quiet clatter, heard like any other noise.
	FallingObject = { radius = 24, priority = "Low", medium = "Air", interval = 0 },
	Scripted = { radius = 0, priority = "Low", medium = "Air", interval = 0 },
	-- co-op text chat (the website's; Roblox chat is never heard)
	ChatMessage = { radius = 25, priority = "Normal", medium = "Air", interval = 0 },
	-- Floor objectives (ObjectiveConfig): a working hold (keys in a lock) at its start and once a second while it runs;
	-- a loud single action (the main breaker, an exit unlocking).
	ObjectiveWork = { radius = 34, priority = "Normal", medium = "Air", interval = 0 },
	ObjectiveClunk = { radius = 110, priority = "High", medium = "Air", interval = 0 },
	-- Parkour (docs/design/game-spec-v2.md 3.1): a slide, once; a fall of ParkourConfig HardLanding.Fall or more
	Slide = { radius = 60, priority = "High", medium = "Air", interval = 0 },
	HardLanding = { radius = 60, priority = "High", medium = "Air", interval = 0 },
	-- The Auditorium (4.4): the strike lamp, the film's score while it plays, a projector running
	LampStrike = { radius = 130, priority = "Critical", medium = "Air", interval = 0 },
	FilmScore = { radius = 90, priority = "Normal", medium = "Air", interval = 0 },
	ProjectorRun = { radius = 30, priority = "Normal", medium = "Air", interval = 0 },
	-- The airport (4.8): the hangar door's motor starting, then running (every 4 s), and the plane's engines
	MotorStart = { radius = 130, priority = "Critical", medium = "Air", interval = 0 },
	MotorRun = { radius = 90, priority = "Normal", medium = "Air", interval = 4 },
	EngineStart = { radius = 170, priority = "Critical", medium = "Air", interval = 0 },
} :: { [string]: NoiseSpec })

-- Observed horizontal speed (studs/s) above which a moving character is at least this loud,
-- whatever move state it claims. Checked highest first.
NoiseConfig.SpeedTiers = table.freeze({
	{ minSpeed = 15, kind = "Sprint" },
	{ minSpeed = 7.5, kind = "Walk" },
	{ minSpeed = 1, kind = "CrouchWalk" },
} :: { { minSpeed: number, kind: Enums.NoiseKind } })

NoiseConfig.VentSpeedTiers = table.freeze({
	{ minSpeed = 6.5, kind = "VentScurry" },
	{ minSpeed = 0.75, kind = "SlowVentCrawl" },
} :: { { minSpeed: number, kind: Enums.NoiseKind } })

-- A landing heard as JumpLand: airborne at least this long, on foot.
NoiseConfig.JumpLandAirborne = 0.32

-- Wall occlusion used by Hearing: each solid wall between source and listener scales the radius.
NoiseConfig.WallOcclusion = 0.6
NoiseConfig.MaxOccludingWalls = 3

-- Noise travelling through ducts uses VentGraph path length instead of straight-line distance.
NoiseConfig.VentPropagationMultiplier = 1.4

-- Every noise and the hearing tables as plain data for the website (world.json meta.noiseConfig).
function NoiseConfig.exportMeta(): { [string]: any }
	local kinds: { [string]: any } = {}
	for kind, spec in NoiseConfig.Kinds do
		kinds[kind] = table.clone(spec)
	end
	local function tiers(list: { { minSpeed: number, kind: Enums.NoiseKind } }): { any }
		local out: { any } = {}
		for _, tier in list do
			table.insert(out, table.clone(tier))
		end
		return out
	end
	return {
		Kinds = kinds,
		SpeedTiers = tiers(NoiseConfig.SpeedTiers),
		VentSpeedTiers = tiers(NoiseConfig.VentSpeedTiers),
		JumpLandAirborne = NoiseConfig.JumpLandAirborne,
		WallOcclusion = NoiseConfig.WallOcclusion,
		MaxOccludingWalls = NoiseConfig.MaxOccludingWalls,
		VentPropagationMultiplier = NoiseConfig.VentPropagationMultiplier,
	}
end

return table.freeze(NoiseConfig)
