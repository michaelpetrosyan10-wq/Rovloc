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
--   * emergency reds and exit signs always burn: they are the player's wayfinding;
--   * every wing has its own colour (`cast`): the tubes of the classroom floors burn a sickly green-teal, the
--     basement's tubes and bulbs a sodium amber, the pool's a cold cyan. The layout's light colour is pulled toward the
--     cast (scripted and wayfinding lights keep theirs), and `grade` is the gentle tint the client's colour grade
--     blends toward while the camera is on that level (LightingController).
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
	cast: Color3?, -- colour every fluorescent tube is pulled toward
	bulbCast: Color3?, -- colour every bare bulb is pulled toward
	grade: Color3?, -- client colour-grade tint while the camera is on the level
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

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- How far a light's own colour is pulled toward its level's cast.
local CAST_AMOUNT = 0.7

local LEVELS: { [string]: LevelMood } = {
	Lobby = {
		revive = 1,
		flicker = 0.1,
		brightness = 2,
		range = 1.2,
		bulbCast = rgb(255, 172, 98),
		grade = rgb(255, 240, 222),
	},
	Level0_Basement = {
		revive = 0.45,
		flicker = 0.35,
		brightness = 2.4,
		range = 1.35,
		cast = rgb(236, 200, 136),
		bulbCast = rgb(255, 160, 84),
		grade = rgb(255, 236, 214),
	},
	Level1_Hallways = {
		revive = 0.4,
		flicker = 0.4,
		brightness = 2.3,
		range = 1.3,
		-- The scare: the corridor outside Classroom 108 stays dark except for the glow spilling from its door.
		keepDark = { "L1_Corridor_East", "L1_Classroom_108" },
		cast = rgb(168, 236, 196),
		bulbCast = rgb(240, 212, 150),
		grade = rgb(236, 255, 244),
	},
	Level2_ScienceHall = {
		revive = 0.5,
		flicker = 0.3,
		brightness = 2.4,
		range = 1.3,
		cast = rgb(160, 232, 222),
		bulbCast = rgb(236, 214, 160),
		grade = rgb(232, 252, 252),
	},
	Level3_Gymnasium = {
		revive = 0.4,
		flicker = 0.35,
		brightness = 2.4,
		range = 1.35,
		cast = rgb(196, 232, 176),
		bulbCast = rgb(240, 208, 146),
		grade = rgb(244, 255, 236),
	},
	Level4_FloodedPool = {
		revive = 0.35,
		flicker = 0.45,
		brightness = 2.3,
		range = 1.3,
		cast = rgb(146, 212, 242),
		bulbCast = rgb(214, 220, 214),
		grade = rgb(226, 244, 255),
	},
	Level5_Roof = {
		revive = 0.5,
		flicker = 0.5,
		brightness = 2,
		range = 1.2,
		cast = rgb(190, 206, 236),
		grade = rgb(234, 240, 255),
	},
}

local DEFAULT: LevelMood = { revive = 0.4, flicker = 0.35, brightness = 2.3, range = 1.3 }

local LightingMood = {}

LightingMood.Levels = LEVELS
LightingMood.MaxBrightness = MAX_BRIGHTNESS
LightingMood.CastAmount = CAST_AMOUNT

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

-- The colour a `kind` light whose layout colour is `base` burns in `roomId` of `layoutId`: pulled toward the level's
-- cast, except scripted and wayfinding lights and the rooms the story keeps exactly as marked.
function LightingMood.cast(layoutId: string, roomId: string, kind: Enums.LightKind, base: Color3): Color3
	local mood = LightingMood.levelMood(layoutId)
	if SCRIPTED[kind] or ALWAYS_ON[kind] or isKeptDark(mood, roomId) then
		return base
	end
	local target = if kind == "Fluorescent" then mood.cast elseif kind == "Bulb" then mood.bulbCast else nil
	if not target then
		return base
	end
	return base:Lerp(target, CAST_AMOUNT)
end

local WHITE = Color3.new(1, 1, 1)

-- The colour-grade tint for a camera on `layoutId` (white, no tint, outside every building).
function LightingMood.grade(layoutId: string?): Color3
	if not layoutId then
		return WHITE
	end
	local mood = LEVELS[layoutId]
	return if mood and mood.grade then mood.grade else WHITE
end

return table.freeze(LightingMood)
