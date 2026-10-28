--!strict
-- LightingMood: turns each layout's light marks into the lighting the player actually sees.
--
-- The layouts mark every ceiling fixture lit, flickering or dead. Taken literally that left the school nearly pitch
-- black: only a dozen dim fixtures per level, so the world read as a few floating light tubes in a void. Horror
-- lighting is contrast, not darkness: pools of light with deep shadow between them, rooms readable at the edges,
-- the dark parts kept for the places the story needs them. So at build time, per level:
--   * a seeded share of the dead fixtures comes back to life (`revive`); a share of those flicker in a group per
--     room, so lit pools stutter and shift instead of sitting still;
--   * every working fixture is brightened and given a longer reach (`brightness`, `range`), capped per kind;
--   * rooms the level's story keeps dark (`keepDark`: the Floor 1 corridor outside the glowing classroom) keep
--     their layout marks untouched;
--   * kinds with a scripted owner keep their marks too: the pool floodlights stay off until the emergency switch, and
--     the classroom glow is the Floor 1 scare's own light;
--   * emergency reds and exit signs always burn: they are the player's wayfinding.
-- Pure and deterministic (seeded by layout and light id), so every server builds the same school and the specs can
-- check the result without building anything.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

export type LevelMood = {
	revive: number, -- share of layout-dead fixtures that come back (0..1)
	flicker: number, -- share of revived fixtures that flicker
	brightness: number, -- multiplier on every working fixture
	range: number, -- multiplier on every working fixture's range
	keepDark: { string }?, -- room ids whose marks are kept exactly
}

export type Resolved = {
	broken: boolean,
	brightness: number,
	range: number,
	flickerGroup: string?,
}

local MAX_RANGE = 60

-- Brightest a fixture of each kind may get after scaling.
local MAX_BRIGHTNESS: { [string]: number } = {
	Fluorescent = 1.8,
	Bulb = 2.2,
	EmergencyRed = 1.4,
	ExitSign = 1,
	BoilerGlow = 2.4,
	ClassroomGlow = 1.3,
	Floodlight = 4,
}

-- Kinds whose marks belong to a scripted owner (never revived or rescaled).
local SCRIPTED: { [string]: boolean } = {
	Floodlight = true, -- the pool's emergency switch (P7)
	ClassroomGlow = true, -- the Floor 1 scare (P6)
}

-- Kinds that always burn (wayfinding).
local ALWAYS_ON: { [string]: boolean } = {
	EmergencyRed = true,
	ExitSign = true,
}

local LEVELS: { [string]: LevelMood } = {
	Lobby = { revive = 1, flicker = 0.1, brightness = 2, range = 1.2 },
	Level0_Basement = { revive = 0.45, flicker = 0.35, brightness = 2.4, range = 1.35 },
	Level1_Hallways = {
		revive = 0.4,
		flicker = 0.4,
		brightness = 2.3,
		range = 1.3,
		-- The scare: the corridor outside Classroom 108 stays dark except for the glow spilling from its door.
		keepDark = { "L1_Corridor_East", "L1_Classroom_108" },
	},
	Level2_ScienceHall = { revive = 0.5, flicker = 0.3, brightness = 2.4, range = 1.3 },
	Level3_Gymnasium = { revive = 0.4, flicker = 0.35, brightness = 2.4, range = 1.35 },
	Level4_FloodedPool = { revive = 0.35, flicker = 0.45, brightness = 2.3, range = 1.3 },
	Level5_Roof = { revive = 0.5, flicker = 0.5, brightness = 2, range = 1.2 },
}

local DEFAULT: LevelMood = { revive = 0.4, flicker = 0.35, brightness = 2.3, range = 1.3 }

local LightingMood = {}

LightingMood.Levels = LEVELS
LightingMood.MaxBrightness = MAX_BRIGHTNESS

function LightingMood.levelMood(layoutId: string): LevelMood
	return LEVELS[layoutId] or DEFAULT
end

-- Deterministic 0..1 draw for (layout, light, purpose).
local function draw(layoutId: string, lightId: string, purpose: string): number
	return MathUtil.hash(layoutId .. ":" .. lightId .. ":" .. purpose) / 4294967296
end

local function isKeptDark(mood: LevelMood, roomId: string): boolean
	local keep = mood.keepDark
	return keep ~= nil and table.find(keep, roomId) ~= nil
end

-- The final state of one layout light in `roomId` of `layoutId`.
function LightingMood.resolve(layoutId: string, roomId: string, light: LayoutSchema.Light): Resolved
	local kind: Enums.LightKind = light.kind
	local mood = LightingMood.levelMood(layoutId)
	local unchanged: Resolved = {
		broken = light.broken == true,
		brightness = light.brightness,
		range = math.min(light.range, MAX_RANGE),
		flickerGroup = light.flickerGroup,
	}
	if SCRIPTED[kind] or isKeptDark(mood, roomId) then
		return unchanged
	end

	local broken = light.broken == true
	local flickerGroup = light.flickerGroup
	if ALWAYS_ON[kind] then
		broken = false
	elseif broken and draw(layoutId, light.id, "revive") < mood.revive then
		broken = false
		if flickerGroup == nil and draw(layoutId, light.id, "flicker") < mood.flicker then
			flickerGroup = roomId .. "_Mood"
		end
	end

	local cap = MAX_BRIGHTNESS[kind] or 2
	return {
		broken = broken,
		brightness = math.min(light.brightness * mood.brightness, cap),
		range = math.min(light.range * mood.range, MAX_RANGE),
		flickerGroup = flickerGroup,
	}
end

return table.freeze(LightingMood)
