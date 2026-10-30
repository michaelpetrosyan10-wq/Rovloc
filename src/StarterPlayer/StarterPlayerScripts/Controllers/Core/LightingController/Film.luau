--!strict
-- LightingController/Film: the level-by-level film grade. Part of LightingController (the only writer of Lighting).
--
-- The server builds one rig for the whole game (LightingRig: Atmosphere, BaseColorCorrection, Bloom, SunRays) and
-- Lighting's baseline properties. On each client this eases every graded value toward the level the camera is on:
-- the film (LightingMood.film: the basement's thick amber haze and heavy bloom, the pool's cold steam, the roof's
-- storm) as Roblox renders it to match the browser build (LightingMood.render: the exposure, the contrast and
-- brightness that reproduce the web's dark-frame curve, a white base tint, the ambient and outdoor fills, the haze).
-- The player's Brightness setting (SetBrightness, -2..+2) offsets the exposure and scales both fills on top.
-- Writes are client-local, stop once the grade has settled, and start again when the camera changes level, the
-- setting changes or the server rebuilds the rig. Exposure and OutdoorAmbient are left alone while a lightning flash
-- owns them (the flash restores the rest values it captured, and the grade's own are re-applied as soon as the flash
-- is over).

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LightingMood = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LightingMood)
local LightingRig = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LightingRig)

type FilmGrade = LightingMood.Film
type Render = LightingMood.Render

local Film = {}

local RATE = 0.9 -- per second: a floor change re-grades over about three seconds
local SETTLED = 0.0015 -- below this distance from its target a grade snaps onto it

local Names = LightingRig.Names

local current: FilmGrade = LightingMood.BaseFilm
local target: FilmGrade = LightingMood.BaseFilm
local currentRender: Render = LightingMood.BaseRender
local targetRender: Render = LightingMood.BaseRender
local exposureOffset = 0
local fillScale = 1
local started = false
local settled = false
local skyStale = true
local rigAtmosphere: Instance? = nil

--------------------------------------------------------------------------------
-- Pure (specs: tests/Specs/ClientLighting.spec.luau)
--------------------------------------------------------------------------------

local function easing(dt: number): number
	return 1 - math.exp(-RATE * math.max(0, dt))
end

-- One easing step of the grade from `from` toward `to` over `dt` seconds.
function Film.step(from: FilmGrade, to: FilmGrade, dt: number): FilmGrade
	local a = easing(dt)
	local function mix(x: number, y: number): number
		return x + (y - x) * a
	end
	return {
		exposure = mix(from.exposure, to.exposure),
		contrast = mix(from.contrast, to.contrast),
		saturation = mix(from.saturation, to.saturation),
		lift = mix(from.lift, to.lift),
		bloomIntensity = mix(from.bloomIntensity, to.bloomIntensity),
		bloomSize = mix(from.bloomSize, to.bloomSize),
		bloomThreshold = mix(from.bloomThreshold, to.bloomThreshold),
		density = mix(from.density, to.density),
		offset = mix(from.offset, to.offset),
		haze = mix(from.haze, to.haze),
		glare = mix(from.glare, to.glare),
		hazeColor = from.hazeColor:Lerp(to.hazeColor, a),
		decay = from.decay:Lerp(to.decay, a),
		sunRays = mix(from.sunRays, to.sunRays),
		dofFar = mix(from.dofFar, to.dofFar),
		dofFocus = mix(from.dofFocus, to.dofFocus),
		dofRadius = mix(from.dofRadius, to.dofRadius),
		vignette = mix(from.vignette, to.vignette),
		shafts = mix(from.shafts, to.shafts),
		dust = mix(from.dust, to.dust),
		moon = mix(from.moon, to.moon),
	}
end

-- One easing step of the Roblox render from `from` toward `to` over `dt` seconds (the same rate as the film).
function Film.stepRender(from: Render, to: Render, dt: number): Render
	local a = easing(dt)
	local function mix(x: number, y: number): number
		return x + (y - x) * a
	end
	return {
		exposure = mix(from.exposure, to.exposure),
		contrast = mix(from.contrast, to.contrast),
		brightness = mix(from.brightness, to.brightness),
		tint = from.tint:Lerp(to.tint, a),
		ambient = from.ambient:Lerp(to.ambient, a),
		outdoorAmbient = from.outdoorAmbient:Lerp(to.outdoorAmbient, a),
		haze = mix(from.haze, to.haze),
		fixtureGain = mix(from.fixtureGain, to.fixtureGain),
		fixtureRange = mix(from.fixtureRange, to.fixtureRange),
		torch = mix(from.torch, to.torch),
	}
end

local function colorGap(a: Color3, b: Color3): number
	return math.max(math.abs(a.R - b.R), math.abs(a.G - b.G), math.abs(a.B - b.B))
end

-- How far apart two grades are: the largest difference of any value, each over its own scale (0 when identical).
function Film.distance(a: FilmGrade, b: FilmGrade): number
	return math.max(
		math.abs(a.exposure - b.exposure),
		math.abs(a.contrast - b.contrast),
		math.abs(a.saturation - b.saturation),
		math.abs(a.lift - b.lift),
		math.abs(a.bloomIntensity - b.bloomIntensity),
		math.abs(a.bloomSize - b.bloomSize) / 50,
		math.abs(a.bloomThreshold - b.bloomThreshold),
		math.abs(a.density - b.density),
		math.abs(a.offset - b.offset),
		math.abs(a.haze - b.haze) / 4,
		math.abs(a.glare - b.glare),
		colorGap(a.hazeColor, b.hazeColor),
		colorGap(a.decay, b.decay),
		math.abs(a.sunRays - b.sunRays),
		math.abs(a.dofFar - b.dofFar),
		math.abs(a.dofFocus - b.dofFocus) / 100,
		math.abs(a.dofRadius - b.dofRadius) / 100,
		math.abs(a.vignette - b.vignette),
		math.abs(a.shafts - b.shafts),
		math.abs(a.dust - b.dust),
		math.abs(a.moon - b.moon)
	)
end

-- How far apart two renders are, like `distance`.
function Film.renderDistance(a: Render, b: Render): number
	return math.max(
		math.abs(a.exposure - b.exposure),
		math.abs(a.contrast - b.contrast),
		math.abs(a.brightness - b.brightness),
		colorGap(a.tint, b.tint),
		colorGap(a.ambient, b.ambient),
		colorGap(a.outdoorAmbient, b.outdoorAmbient),
		math.abs(a.haze - b.haze) / 4,
		math.abs(a.fixtureGain - b.fixtureGain),
		math.abs(a.fixtureRange - b.fixtureRange),
		math.abs(a.torch - b.torch)
	)
end

--------------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------------

local function rigChild(name: string, className: string): Instance?
	local found = Lighting:FindFirstChild(name)
	return if found and found:IsA(className) then found else nil
end

local function writeSky(render: Render)
	Lighting.ExposureCompensation = render.exposure + exposureOffset
	Lighting.OutdoorAmbient = LightingMood.scaleFill(render.outdoorAmbient, fillScale)
end

local function write(grade: FilmGrade, render: Render, withSky: boolean)
	local atmosphere = rigChild(Names.Atmosphere, "Atmosphere")
	if atmosphere then
		local air = atmosphere :: Atmosphere
		air.Density = grade.density
		air.Offset = grade.offset
		air.Haze = render.haze
		air.Glare = grade.glare
		air.Color = grade.hazeColor
		air.Decay = grade.decay
	end
	local base = rigChild(Names.ColorCorrection, "ColorCorrectionEffect")
	if base then
		local cc = base :: ColorCorrectionEffect
		cc.Contrast = render.contrast
		cc.Saturation = grade.saturation
		cc.Brightness = render.brightness
		cc.TintColor = render.tint
	end
	local bloomChild = rigChild(Names.Bloom, "BloomEffect")
	if bloomChild then
		local bloom = bloomChild :: BloomEffect
		bloom.Intensity = grade.bloomIntensity
		bloom.Size = grade.bloomSize
		bloom.Threshold = grade.bloomThreshold
	end
	local raysChild = rigChild(Names.SunRays, "SunRaysEffect")
	if raysChild then
		(raysChild :: SunRaysEffect).Intensity = grade.sunRays
	end
	Lighting.Ambient = LightingMood.scaleFill(render.ambient, fillScale)
	if withSky then
		writeSky(render)
	end
end

--------------------------------------------------------------------------------
-- Runtime (driven by LightingController's frame)
--------------------------------------------------------------------------------

-- Eases toward the film and render of `layoutId` (nil: outdoors) and writes the rig. `flashing`: a lightning flash
-- owns the exposure and the outdoor fill this frame.
function Film.Update(dt: number, layoutId: string?, flashing: boolean)
	local wanted = LightingMood.film(layoutId)
	local wantedRender = LightingMood.render(layoutId)
	if wanted ~= target or wantedRender ~= targetRender then
		target = wanted
		targetRender = wantedRender
		settled = false
	end
	local atmosphere = Lighting:FindFirstChild(Names.Atmosphere)
	if atmosphere ~= rigAtmosphere then
		-- the server (re)built the rig: its fresh instances carry the baseline, so write the whole grade again
		rigAtmosphere = atmosphere
		settled = false
		skyStale = true
	end
	if flashing then
		skyStale = true
	end
	if settled then
		if skyStale and not flashing then
			skyStale = false
			writeSky(currentRender)
		end
		return
	end
	if not started then
		started = true
		-- the first frame lands on the level's grade instead of easing in from the baseline
		current = target
		currentRender = targetRender
	else
		current = Film.step(current, target, dt)
		currentRender = Film.stepRender(currentRender, targetRender, dt)
	end
	if Film.distance(current, target) < SETTLED and Film.renderDistance(currentRender, targetRender) < SETTLED then
		current = target
		currentRender = targetRender
		settled = true
	end
	write(current, currentRender, not flashing)
	if not flashing then
		skyStale = false
	end
end

-- The Brightness setting's step (-2..+2): an exposure offset and a scale on both ambient fills, written on the next
-- frame (and kept through lightning: a flash restores what it captured, then the grade writes this again).
function Film.SetBrightness(step: number)
	local offset, scale = LightingMood.brightnessAdjust(step)
	if offset == exposureOffset and scale == fillScale then
		return
	end
	exposureOffset = offset
	fillScale = scale
	settled = false
	skyStale = true
end

-- The grade on screen right now (PanicVFX reads its resting depth of field and vignette from it).
function Film.Current(): FilmGrade
	return current
end

-- The Roblox render on screen right now (the flashlight reads its gain from it).
function Film.CurrentRender(): Render
	return currentRender
end

return table.freeze(Film)
