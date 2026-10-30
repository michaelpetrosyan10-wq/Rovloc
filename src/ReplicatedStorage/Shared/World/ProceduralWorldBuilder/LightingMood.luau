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
-- Pools, not floods: working fixtures burn hard (strong keys under each fixture) over a tighter reach, so the floor
-- between two pools falls off into shadow instead of a flat wash; the ambient fill (LightingRig) keeps those gaps
-- readable.
--
-- Each level is also graded like a film shot (`film`): how thick and what colour its haze is, how far it carries,
-- how hard the bloom catches the tubes, the base contrast / saturation / lift, the exposure trim, a far-focus depth of
-- field, the resting vignette, how strongly light shafts and dust show in its air and how much moonlight its boarded
-- windows let in. The client eases every value toward the film of the level the camera is on (LightingController).
-- Pure and deterministic (seeded by layout and light id), so every server builds the same school and the specs can
-- check the result without building anything.
--
-- The browser build (web/) renders all of the above (the layouts, `resolve`, every film, LightingRig.Baseline: its
-- export reads them) and is the look the game is graded to. Roblox draws the same data darker: its ColorCorrection
-- contrast pivots at mid-grey where the web's pivots in the dark frame, its Future falloff is steeper, the web trims
-- its exposure up and fills the gaps between pools with a stronger ambient. So each level also has a Roblox render
-- (`render`): the exposure, grade, ambient, haze, fixture and flashlight gains that reproduce the web's frame on
-- Roblox. The client writes those instead of the raw film and rig values (LightingController/Film); the shared data
-- above stays the web export's source. Derivation and the numbers per level: docs/LIGHTING-PARITY.md.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local LightingRig = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LightingRig)
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

-- One level's grade. Exposure is an EV trim over LightingRig.Baseline.ExposureCompensation; the colour-grade values
-- are the base ColorCorrection's (the area tint stays `LevelMood.grade`); the haze values are the Atmosphere's.
export type Film = {
	exposure: number,
	contrast: number,
	saturation: number,
	lift: number, -- base grade Brightness: a filmic lift of the blacks that keeps the shadows readable
	bloomIntensity: number,
	bloomSize: number,
	bloomThreshold: number,
	density: number,
	offset: number,
	haze: number,
	glare: number,
	hazeColor: Color3,
	decay: Color3,
	sunRays: number,
	dofFar: number, -- resting far blur (render budget permitting)
	dofFocus: number,
	dofRadius: number,
	vignette: number, -- resting vignette edge opacity
	shafts: number, -- visible light-shaft strength in this air (fixture haze cones, window rays, the torch cone)
	dust: number, -- dust-mote density multiplier
	moon: number, -- moonlight through the boarded windows (multiplier)
}

-- One level's Roblox render: the values the client writes so the frame matches the web build's (see the header).
export type Render = {
	exposure: number, -- Lighting.ExposureCompensation (absolute EV): the web's rig + film + its exposure trim
	contrast: number, -- BaseColorCorrection.Contrast: Roblox's mid-grey contrast fitted to the web's S-curve
	brightness: number, -- BaseColorCorrection.Brightness: the offset that completes that fit (the film's lift in it)
	tint: Color3, -- BaseColorCorrection.TintColor: white, the level's colour is the area grade's alone (as on the web)
	ambient: Color3, -- Lighting.Ambient: the web's ambient fill under its mean ambient occlusion
	outdoorAmbient: Color3, -- Lighting.OutdoorAmbient: the web's outdoor fill plus the ambient on open ground
	haze: number, -- Atmosphere.Haze (the web's fog has no haze layer; Density stays the film's, ported 1:1)
	fixtureGain: number, -- Brightness multiplier of every fixture and moonlight spill of the level (falloff fit)
	fixtureRange: number, -- Range multiplier of every fixture of the level (falloff fit, still capped at MAX_RANGE)
	torch: number, -- Brightness multiplier of the flashlight cones while the camera is on the level
}

-- A level's departures from the base render (every field optional).
type RenderPatch = {
	exposure: number?,
	contrast: number?,
	brightness: number?,
	tint: Color3?,
	ambient: Color3?,
	outdoorAmbient: Color3?,
	haze: number?,
	fixtureGain: number?,
	fixtureRange: number?,
	torch: number?,
}

-- A level's departures from the base film (every field optional).
type FilmPatch = {
	exposure: number?,
	contrast: number?,
	saturation: number?,
	lift: number?,
	bloomIntensity: number?,
	bloomSize: number?,
	bloomThreshold: number?,
	density: number?,
	offset: number?,
	haze: number?,
	glare: number?,
	hazeColor: Color3?,
	decay: Color3?,
	sunRays: number?,
	dofFar: number?,
	dofFocus: number?,
	dofRadius: number?,
	vignette: number?,
	shafts: number?,
	dust: number?,
	moon: number?,
}

local MAX_RANGE = 60

-- Brightest a fixture of each kind may get after scaling.
local MAX_BRIGHTNESS: { [string]: number } = {
	Fluorescent = 2.1,
	Bulb = 2.5,
	EmergencyRed = 1.5,
	ExitSign = 1,
	BoilerGlow = 2.6,
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
		brightness = 2.2,
		range = 1.15,
		bulbCast = rgb(255, 172, 98),
		grade = rgb(255, 240, 222),
	},
	Level0_Basement = {
		revive = 0.45,
		flicker = 0.35,
		brightness = 2.75,
		range = 1.3,
		cast = rgb(236, 200, 136),
		bulbCast = rgb(255, 160, 84),
		grade = rgb(255, 236, 214),
	},
	Level1_Hallways = {
		revive = 0.4,
		flicker = 0.4,
		brightness = 2.65,
		range = 1.25,
		-- The scare: the corridor outside Classroom 108 stays dark except for the glow spilling from its door.
		keepDark = { "L1_Corridor_East", "L1_Classroom_108" },
		cast = rgb(168, 236, 196),
		bulbCast = rgb(240, 212, 150),
		grade = rgb(236, 255, 244),
	},
	Level2_ScienceHall = {
		revive = 0.5,
		flicker = 0.3,
		brightness = 2.75,
		range = 1.25,
		cast = rgb(160, 232, 222),
		bulbCast = rgb(236, 214, 160),
		grade = rgb(232, 252, 252),
	},
	Level3_Gymnasium = {
		revive = 0.4,
		flicker = 0.35,
		brightness = 2.75,
		range = 1.3,
		cast = rgb(196, 232, 176),
		bulbCast = rgb(240, 208, 146),
		grade = rgb(244, 255, 236),
	},
	Level4_FloodedPool = {
		revive = 0.35,
		flicker = 0.45,
		brightness = 2.65,
		range = 1.25,
		cast = rgb(146, 212, 242),
		bulbCast = rgb(214, 220, 214),
		grade = rgb(226, 244, 255),
	},
	Level5_Roof = {
		revive = 0.5,
		flicker = 0.5,
		brightness = 2.2,
		range = 1.15,
		cast = rgb(190, 206, 236),
		grade = rgb(234, 240, 255),
	},
}

local DEFAULT: LevelMood = { revive = 0.4, flicker = 0.35, brightness = 2.65, range = 1.25 }

-- The base film: a cold, hazy school night. Contrast up with the blacks lifted a touch (so the gaps between pools
-- read as dark grey-blue, not void), colour drained, bloom catching only what really burns (threshold above 1:
-- tubes, lenses, glossy highlights), far-focus depth of field that only softens the end of a long corridor.
local BASE_FILM: Film = table.freeze({
	exposure = 0.08,
	contrast = 0.2,
	saturation = -0.22,
	lift = 0.015,
	bloomIntensity = 0.85,
	bloomSize = 34,
	bloomThreshold = 1.12,
	density = 0.34,
	offset = 0.06,
	haze = 1.9,
	glare = 0.2,
	hazeColor = rgb(42, 48, 52),
	decay = rgb(20, 26, 28),
	sunRays = 0.03,
	dofFar = 0.14,
	dofFocus = 38,
	dofRadius = 44,
	vignette = 0.32,
	shafts = 1,
	dust = 1,
	moon = 1,
})

local FILM_PATCHES: { [string]: FilmPatch } = {
	-- Warm, safe-ish, clearer air: the squad's last look at something like comfort.
	Lobby = {
		exposure = 0.1,
		contrast = 0.14,
		saturation = -0.12,
		bloomIntensity = 0.8,
		bloomSize = 32,
		bloomThreshold = 1.15,
		density = 0.28,
		offset = 0.1,
		haze = 1.4,
		hazeColor = rgb(60, 52, 44),
		decay = rgb(30, 24, 20),
		dofFar = 0.1,
		dofRadius = 50,
		vignette = 0.26,
		shafts = 0.8,
		dust = 0.8,
		moon = 0,
	},
	-- Sodium amber in thick, dusty air: the boilers' heat haze, heavy bloom on the bulbs.
	Level0_Basement = {
		exposure = 0.05,
		saturation = -0.18,
		bloomIntensity = 0.95,
		bloomSize = 36,
		bloomThreshold = 1.05,
		density = 0.42,
		offset = 0.04,
		haze = 2.4,
		glare = 0.35,
		hazeColor = rgb(62, 50, 36),
		decay = rgb(34, 24, 14),
		sunRays = 0,
		dofFar = 0.16,
		dofFocus = 34,
		dofRadius = 40,
		vignette = 0.36,
		shafts = 1.25,
		dust = 1.4,
		moon = 0, -- every basement window looks into a soil-filled light well
	},
	-- Sickly green tubes in a stale, medium haze.
	Level1_Hallways = {
		saturation = -0.24,
		hazeColor = rgb(42, 52, 48),
		decay = rgb(20, 28, 26),
	},
	-- Clinical teal, a little clearer, colder.
	Level2_ScienceHall = {
		exposure = 0.1,
		bloomIntensity = 0.9,
		bloomThreshold = 1.1,
		density = 0.32,
		haze = 1.7,
		hazeColor = rgb(38, 52, 54),
		decay = rgb(18, 28, 30),
		shafts = 0.95,
		dust = 0.9,
	},
	-- A big volume: more air between the walls, so more haze and the window rays carry further.
	Level3_Gymnasium = {
		bloomIntensity = 0.9,
		bloomSize = 38,
		bloomThreshold = 1.1,
		density = 0.38,
		haze = 2.1,
		hazeColor = rgb(46, 52, 42),
		decay = rgb(24, 28, 20),
		dofFocus = 44,
		dofRadius = 52,
		shafts = 1.15,
		dust = 1.2,
		moon = 1.15,
	},
	-- Cold cyan steam over black water: the densest haze, the wettest bloom, little dust in the damp.
	Level4_FloodedPool = {
		exposure = 0.12,
		contrast = 0.22,
		saturation = -0.16,
		bloomIntensity = 1,
		bloomSize = 40,
		bloomThreshold = 1,
		density = 0.46,
		offset = 0.02,
		haze = 2.6,
		glare = 0.3,
		hazeColor = rgb(40, 54, 62),
		decay = rgb(18, 30, 38),
		dofFar = 0.16,
		vignette = 0.34,
		shafts = 1.2,
		dust = 0.6,
		moon = 1.1,
	},
	-- Storm night in the open: rain haze, a far horizon, no dust in the wind.
	Level5_Roof = {
		exposure = 0.2,
		contrast = 0.16,
		bloomIntensity = 0.75,
		bloomSize = 30,
		bloomThreshold = 1.2,
		density = 0.36,
		offset = 0.12,
		haze = 2.2,
		glare = 0.1,
		hazeColor = rgb(40, 44, 54),
		decay = rgb(20, 24, 30),
		sunRays = 0.06,
		dofFar = 0.12,
		dofFocus = 48,
		dofRadius = 60,
		vignette = 0.3,
		shafts = 0.8,
		dust = 0,
		moon = 0,
	},
}

local function patched(patch: FilmPatch): Film
	local base = BASE_FILM
	return table.freeze({
		exposure = patch.exposure or base.exposure,
		contrast = patch.contrast or base.contrast,
		saturation = patch.saturation or base.saturation,
		lift = patch.lift or base.lift,
		bloomIntensity = patch.bloomIntensity or base.bloomIntensity,
		bloomSize = patch.bloomSize or base.bloomSize,
		bloomThreshold = patch.bloomThreshold or base.bloomThreshold,
		density = patch.density or base.density,
		offset = patch.offset or base.offset,
		haze = patch.haze or base.haze,
		glare = patch.glare or base.glare,
		hazeColor = patch.hazeColor or base.hazeColor,
		decay = patch.decay or base.decay,
		sunRays = patch.sunRays or base.sunRays,
		dofFar = patch.dofFar or base.dofFar,
		dofFocus = patch.dofFocus or base.dofFocus,
		dofRadius = patch.dofRadius or base.dofRadius,
		vignette = patch.vignette or base.vignette,
		shafts = patch.shafts or base.shafts,
		dust = patch.dust or base.dust,
		moon = patch.moon or base.moon,
	})
end

local FILMS: { [string]: Film } = {}
for layoutId, patch in FILM_PATCHES do
	FILMS[layoutId] = patched(patch)
end
-- Outside every building (the street, the sky, the parachute drop) the camera sees the roof's storm.
local OUTDOOR_FILM: Film = FILMS.Level5_Roof

-- The web's exposure on top of the rig and film (web/src/engine/lighting.js ExposureTrim): +0.25 EV everywhere and
-- +0.8 EV more in the lobby. Its torch is not trimmed (it keeps the brightness it was tuned with).
local WEB_EXPOSURE_TRIM: { [string]: number } = { base = 0.25, Lobby = 0.8 }
-- The web's contrast pivot (web/src/engine/renderer.js): the S-curve turns where this dark frame's lit surfaces are.
local WEB_CONTRAST_PIVOT = 0.16

-- The Roblox render of the base film. Every number is fitted to the web build (docs/LIGHTING-PARITY.md):
--   exposure      0.3 rig + film exposure + the web's trim;
--   contrast /    a least-squares fit of Roblox's linear contrast about 0.5 plus its additive Brightness to the
--   brightness    web's lift + S-curve about 0.16, over the night frame's display range 0..0.5 (worst error under
--                 3/255); the old 0.2 about mid-grey sent everything under ~0.07 to pure black;
--   ambient       the web's fill (4.5x the rig's Ambient in linear light) under its mean ambient occlusion (0.8):
--                 Roblox has no AO, so the flat fill sits at the web's average;
--   outdoor       the web's outdoor fill (2.2x the rig's OutdoorAmbient) plus its ambient on open ground (AO 0.85);
--   haze          0.4x the film's: the web's fog is the film's Density alone, Roblox's Haze adds a night-dark layer;
--   fixtures      Brightness and Range factors that fit Roblox's steeper falloff to the web's pools on each level's
--                 floors (mean, p10, p50 and p90 within 3/255 of the web in the parity model);
--   torch         the cones' Brightness fitted to the web's beam from 4 to 40 studs (the web's softer falloff throws
--                 further; the hotspot clips on both).
local BASE_RENDER: Render = table.freeze({
	exposure = 0.63,
	contrast = 0.145,
	brightness = 0.069,
	tint = rgb(255, 255, 255),
	ambient = rgb(51, 56, 70),
	outdoorAmbient = rgb(85, 93, 115),
	haze = 0.76,
	fixtureGain = 1.6,
	fixtureRange = 1.05,
	torch = 1.7,
})

local RENDER_PATCHES: { [string]: RenderPatch } = {
	-- The web lifts the safe lobby a further 0.8 EV and leaves its torch untrimmed, so the beam scales back here.
	Lobby = {
		exposure = 1.45,
		contrast = 0.1,
		brightness = 0.053,
		haze = 0.56,
		fixtureGain = 1.3,
		fixtureRange = 1.1,
		torch = 1.05,
	},
	-- Low bulbs and boilers close to the floor: the falloffs differ least, so the smallest gain.
	Level0_Basement = { exposure = 0.6, haze = 0.96, fixtureGain = 1.25, fixtureRange = 1.1 },
	Level1_Hallways = { exposure = 0.63, fixtureGain = 1.65 },
	Level2_ScienceHall = { exposure = 0.65, haze = 0.68, fixtureGain = 1.65 },
	-- The gym's high ceiling: longer throws, so more of the gain goes into reach.
	Level3_Gymnasium = { exposure = 0.63, haze = 0.84, fixtureGain = 1.5, fixtureRange = 1.1 },
	Level4_FloodedPool = { exposure = 0.67, contrast = 0.155, brightness = 0.074, haze = 1.04, fixtureGain = 1.65 },
	-- Open sky: the outdoor fill does the work; the few lamps need the most gain over their short reach.
	Level5_Roof = {
		exposure = 0.75,
		contrast = 0.115,
		brightness = 0.058,
		haze = 0.88,
		fixtureGain = 1.75,
		fixtureRange = 1,
	},
}

local function patchedRender(patch: RenderPatch): Render
	local base = BASE_RENDER
	return table.freeze({
		exposure = patch.exposure or base.exposure,
		contrast = patch.contrast or base.contrast,
		brightness = patch.brightness or base.brightness,
		tint = patch.tint or base.tint,
		ambient = patch.ambient or base.ambient,
		outdoorAmbient = patch.outdoorAmbient or base.outdoorAmbient,
		haze = patch.haze or base.haze,
		fixtureGain = patch.fixtureGain or base.fixtureGain,
		fixtureRange = patch.fixtureRange or base.fixtureRange,
		torch = patch.torch or base.torch,
	})
end

local RENDERS: { [string]: Render } = {}
for layoutId, patch in RENDER_PATCHES do
	RENDERS[layoutId] = patchedRender(patch)
end
local OUTDOOR_RENDER: Render = RENDERS.Level5_Roof

-- The Brightness setting (SettingsSchema, -2..+2 steps around the render): per step, this much exposure (EV) and this
-- share of the ambient fill, so a dark monitor can lift the shadows without flattening the pools.
local BRIGHTNESS_STEP = table.freeze({ exposure = 0.2, ambient = 0.15 })

-- The flashlight's wide cone reaches the SpotLight maximum on Roblox (the web's 48 studs carry further under its
-- softer falloff; the fit puts the outer cone at 60 on every level).
local TORCH_OUTER_RANGE = MAX_RANGE

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

LightingMood.BaseFilm = BASE_FILM
LightingMood.OutdoorFilm = OUTDOOR_FILM

-- The film grade for a camera on `layoutId` (the outdoor storm outside every building; the base film for a layout
-- without its own).
function LightingMood.film(layoutId: string?): Film
	if not layoutId then
		return OUTDOOR_FILM
	end
	return FILMS[layoutId] or BASE_FILM
end

LightingMood.BaseRender = BASE_RENDER
LightingMood.OutdoorRender = OUTDOOR_RENDER
LightingMood.WebExposureTrim = table.freeze(WEB_EXPOSURE_TRIM)
LightingMood.WebContrastPivot = WEB_CONTRAST_PIVOT
LightingMood.BrightnessStep = BRIGHTNESS_STEP
LightingMood.TorchOuterRange = TORCH_OUTER_RANGE
LightingMood.MaxRange = MAX_RANGE

-- The Roblox render for a camera on `layoutId` (the outdoor storm's outside every building; the base render for a
-- layout without its own film).
function LightingMood.render(layoutId: string?): Render
	if not layoutId then
		return OUTDOOR_RENDER
	end
	return RENDERS[layoutId] or BASE_RENDER
end

-- The exposure (EV) the web renders `layoutId` at: the rig's, the film's trim and the web's own trim.
function LightingMood.webExposure(layoutId: string?): number
	local trim = WEB_EXPOSURE_TRIM.base + (if layoutId then WEB_EXPOSURE_TRIM[layoutId] or 0 else 0)
	return LightingRig.Baseline.ExposureCompensation + LightingMood.film(layoutId).exposure + trim
end

-- The web's grade of a display value `x` (0..1): the film's lift, then contrast as two power curves meeting at the
-- pivot with slope 1 + contrast (web/src/engine/renderer.js).
function LightingMood.webGrade(x: number, film: Film): number
	local c = math.clamp(x + film.lift, 0, 1)
	local k = math.max(0.2, 1 + film.contrast)
	local pivot = WEB_CONTRAST_PIVOT
	if c < pivot then
		return pivot * (c / pivot) ^ k
	end
	return 1 - (1 - pivot) * ((1 - c) / (1 - pivot)) ^ k
end

-- Roblox's ColorCorrectionEffect on a display value `x`: contrast about mid-grey, then the additive brightness.
function LightingMood.robloxGrade(x: number, contrast: number, brightness: number): number
	return math.clamp((x - 0.5) * (1 + contrast) + 0.5 + brightness, 0, 1)
end

-- The Brightness setting's `step` as an exposure offset (EV) and an ambient multiplier.
function LightingMood.brightnessAdjust(step: number): (number, number)
	local value = if step == step then step else 0
	return value * BRIGHTNESS_STEP.exposure, math.max(0, 1 + value * BRIGHTNESS_STEP.ambient)
end

-- `color` (an ambient fill) with its light scaled by `scale` (in linear light, kept in range).
function LightingMood.scaleFill(color: Color3, scale: number): Color3
	if scale == 1 then
		return color
	end
	local k = math.max(0, scale) ^ (1 / 2.2)
	return Color3.new(math.min(1, color.R * k), math.min(1, color.G * k), math.min(1, color.B * k))
end

-- Moonlight through the boarded windows (a level's `film.moon` scales its brightness).
LightingMood.Moonlight = table.freeze({
	color = rgb(150, 174, 226),
	brightness = 2.4, -- a shadowed spill: only the gaps between the planks let it through
	unshadowedShare = 0.32, -- an unshadowed spill lights its whole cone, so it burns at about the planks' open share
	range = 26,
	angle = 64,
	pitch = math.rad(38), -- how steeply the moonlight falls through a window
	skew = 0.28, -- the sideways lean of every ray (the moon sits off to one side of the school)
})

return table.freeze(LightingMood)
