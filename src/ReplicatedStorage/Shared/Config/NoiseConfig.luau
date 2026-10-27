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

NoiseConfig.Kinds = table.freeze({
	CrouchWalk = { radius = 8, priority = "Low", medium = "Air", interval = 0.6 },
	SlowVentCrawl = { radius = 8, priority = "Low", medium = "Vent", interval = 0.7 },
	GrateUnscrew = { radius = 10, priority = "Low", medium = "Air", interval = 0.9 },
	Treading = { radius = 12, priority = "Low", medium = "Water", interval = 0.8 },
	Walk = { radius = 30, priority = "Normal", medium = "Air", interval = 0.45 },
	Gasp = { radius = 40, priority = "High", medium = "Air", interval = 0 },
	FlaskShatter = { radius = 50, priority = "High", medium = "Air", interval = 0 },
	Sprint = { radius = 65, priority = "High", medium = "Air", interval = 0.3 },
	Freestyle = { radius = 75, priority = "High", medium = "Water", interval = 0.35 },
	Splash = { radius = 75, priority = "High", medium = "Water", interval = 0 },
	VentScurry = { radius = 90, priority = "High", medium = "Vent", interval = 0.3 },
	GrateKick = { radius = 130, priority = "Critical", medium = "Air", interval = 0 },
	FloorDebris = { radius = 130, priority = "Critical", medium = "Air", interval = 0 },
	TrapSnap = { radius = 130, priority = "Critical", medium = "Air", interval = 0 },
	DoorSlam = { radius = 130, priority = "Critical", medium = "Air", interval = 0 },
	Scripted = { radius = 0, priority = "Low", medium = "Air", interval = 0 },
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

NoiseConfig.WaterSpeedTiers = table.freeze({
	{ minSpeed = 6.5, kind = "Freestyle" },
	{ minSpeed = 0.75, kind = "Treading" },
} :: { { minSpeed: number, kind: Enums.NoiseKind } })

-- Splash meter: water noise accumulates per player and decays; crossing the threshold invites a grab. After a
-- crossing the meter re-arms only once it has decayed below `rearmBelow` (hysteresis), so the sawtooth between the
-- strokes of one continuous swim never reads as a second crossing; a real calm spell is needed.
NoiseConfig.SplashMeter = table.freeze({
	perFreestylePulse = 1,
	perSplash = 2.5,
	perTreadingPulse = 0.1,
	decayPerSecond = 0.35,
	grabThreshold = 6,
	rearmBelow = 4,
})

-- Wall occlusion used by Hearing: each solid wall between source and listener scales the radius.
NoiseConfig.WallOcclusion = 0.6
NoiseConfig.MaxOccludingWalls = 3

-- Noise travelling through ducts uses VentGraph path length instead of straight-line distance.
NoiseConfig.VentPropagationMultiplier = 1.4

return table.freeze(NoiseConfig)
