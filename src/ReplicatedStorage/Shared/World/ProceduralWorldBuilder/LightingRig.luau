--!strict
-- Server lighting baseline: a cold ambient fill, a light haze, a cool desaturated grade, bloom and a storm deck of
-- clouds. Lighting properties mirror the pins in default.project.json so a `rojo serve` session and a built
-- place look identical. Clients layer their own effects (panic grade, depth of field, lightning pulses) on top.
--
-- Lighting.LightingStyle and Lighting.PrioritizeLightingQuality (like the deprecated Technology) can only be
-- written by plugins and Open Cloud (API dump: Capabilities.Write = PluginOrOpenCloud); a game script that writes
-- either throws. They are pinned in default.project.json instead, which `rojo build` writes into the place and
-- `rojo serve` syncs through its plugin, so this module only ever reads them. The children are built before any
-- property is written and every write is guarded on its own, so one refused write can never cost the rest of
-- the rig (the haze, grade, bloom, sky and the cloud deck the client's lightning pulses).

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Util.Log)

local log = Log.new("LightingRig")

local LightingRig = {}

-- Child names clients look up (LightingController pulses these for lightning).
LightingRig.Names = table.freeze({
	Atmosphere = "Atmosphere",
	ColorCorrection = "BaseColorCorrection",
	Bloom = "Bloom",
	Sky = "Sky",
	Clouds = "Clouds",
})

-- Baseline values, also read by clients as the rest state their pulses decay back to.
-- Dark but readable: a cold blue-grey ambient fill lets shapes read at the edge of every lit pool (the player is
-- never staring into a void), haze gives long corridors depth, bloom makes the fixtures glow and the grade drains
-- some colour without turning the school grey. The darkness comes from contrast with the level lights
-- (LightingMood) and the flashlight, not from switching everything off.
LightingRig.Baseline = table.freeze({
	ClockTime = 0.5,
	Brightness = 0.5,
	Ambient = Color3.fromRGB(28, 30, 38),
	OutdoorAmbient = Color3.fromRGB(46, 50, 60),
	EnvironmentDiffuseScale = 0.3,
	EnvironmentSpecularScale = 0.55,
	ExposureCompensation = 0.25,
	ShadowSoftness = 0.25,
	AtmosphereDensity = 0.34,
	AtmosphereOffset = 0.08,
	AtmosphereHaze = 1.8,
	AtmosphereColor = Color3.fromRGB(44, 48, 56),
	AtmosphereDecay = Color3.fromRGB(22, 26, 30),
	GradeBrightness = 0,
	GradeContrast = 0.16,
	GradeSaturation = -0.22,
	GradeTint = Color3.fromRGB(232, 240, 255),
	BloomIntensity = 0.7,
	BloomSize = 30,
	BloomThreshold = 1.25,
	CloudCover = 0.93,
	CloudDensity = 0.78,
	CloudColor = Color3.fromRGB(38, 40, 46),
})

local Baseline = LightingRig.Baseline
local Names = LightingRig.Names

type PropertyWrite = { name: string, write: () -> () }

-- Every Lighting property the server writes, in order. Each is game-script writable (no capability gate).
local PROPERTY_WRITES: { PropertyWrite } = {
	{
		name = "ClockTime",
		write = function()
			Lighting.ClockTime = Baseline.ClockTime
		end,
	},
	{
		name = "Brightness",
		write = function()
			Lighting.Brightness = Baseline.Brightness
		end,
	},
	{
		name = "Ambient",
		write = function()
			Lighting.Ambient = Baseline.Ambient
		end,
	},
	{
		name = "OutdoorAmbient",
		write = function()
			Lighting.OutdoorAmbient = Baseline.OutdoorAmbient
		end,
	},
	{
		name = "EnvironmentDiffuseScale",
		write = function()
			Lighting.EnvironmentDiffuseScale = Baseline.EnvironmentDiffuseScale
		end,
	},
	{
		name = "EnvironmentSpecularScale",
		write = function()
			Lighting.EnvironmentSpecularScale = Baseline.EnvironmentSpecularScale
		end,
	},
	{
		name = "ExposureCompensation",
		write = function()
			Lighting.ExposureCompensation = Baseline.ExposureCompensation
		end,
	},
	{
		name = "GlobalShadows",
		write = function()
			Lighting.GlobalShadows = true
		end,
	},
	{
		name = "ShadowSoftness",
		write = function()
			Lighting.ShadowSoftness = Baseline.ShadowSoftness
		end,
	},
}

local propertyNames: { string } = {}
for _, entry in PROPERTY_WRITES do
	table.insert(propertyNames, entry.name)
end
table.freeze(propertyNames)

-- Names of the Lighting properties apply() writes (specs check none of them is capability-gated).
LightingRig.PropertyNames = propertyNames

-- Pinned in default.project.json only: game scripts may read these but never write them.
LightingRig.ProjectPinned = table.freeze({ "Technology", "LightingStyle", "PrioritizeLightingQuality" })

local function terrain(): Terrain?
	return Workspace:FindFirstChildOfClass("Terrain")
end

-- Runs `fn`, logging (instead of raising) anything it throws. Returns whether it completed.
local function guarded(what: string, fn: () -> ()): boolean
	local ok = true
	xpcall(fn, function(err: any)
		ok = false
		log.warn("%s failed: %s", what, tostring(err))
	end)
	return ok
end

local function buildAtmosphere()
	local atmosphere = Instance.new("Atmosphere")
	atmosphere.Name = Names.Atmosphere
	atmosphere.Density = Baseline.AtmosphereDensity
	atmosphere.Offset = Baseline.AtmosphereOffset
	atmosphere.Haze = Baseline.AtmosphereHaze
	atmosphere.Glare = 0
	atmosphere.Color = Baseline.AtmosphereColor
	atmosphere.Decay = Baseline.AtmosphereDecay
	atmosphere.Parent = Lighting
end

local function buildGrade()
	local grade = Instance.new("ColorCorrectionEffect")
	grade.Name = Names.ColorCorrection
	grade.Brightness = Baseline.GradeBrightness
	grade.Contrast = Baseline.GradeContrast
	grade.Saturation = Baseline.GradeSaturation
	grade.TintColor = Baseline.GradeTint
	grade.Parent = Lighting
end

local function buildBloom()
	local bloom = Instance.new("BloomEffect")
	bloom.Name = Names.Bloom
	bloom.Intensity = Baseline.BloomIntensity
	bloom.Size = Baseline.BloomSize
	bloom.Threshold = Baseline.BloomThreshold
	bloom.Parent = Lighting
end

-- Storm night: no sun, moon or stars behind the cloud deck (default sky textures are left untouched).
local function buildSky()
	local sky = Instance.new("Sky")
	sky.Name = Names.Sky
	sky.CelestialBodiesShown = false
	sky.StarCount = 0
	sky.Parent = Lighting
end

local function buildClouds()
	local land = terrain()
	if not land then
		log.warn("Workspace has no Terrain; the storm cloud deck was skipped")
		return
	end
	for _, child in land:GetChildren() do
		if child:IsA("Clouds") then
			child:Destroy()
		end
	end
	local clouds = Instance.new("Clouds")
	clouds.Name = Names.Clouds
	clouds.Cover = Baseline.CloudCover
	clouds.Density = Baseline.CloudDensity
	clouds.Color = Baseline.CloudColor
	clouds.Enabled = true
	clouds.Parent = land
end

-- Rebuilds the server baseline from scratch (existing Lighting children are removed first). Returns the names of
-- the steps that failed (each is logged); an empty list means the whole rig is in place.
function LightingRig.apply(): { string }
	local failed: { string } = {}
	for _, child in Lighting:GetChildren() do
		child:Destroy()
	end

	local steps: { PropertyWrite } = {
		{ name = Names.Atmosphere, write = buildAtmosphere },
		{ name = Names.ColorCorrection, write = buildGrade },
		{ name = Names.Bloom, write = buildBloom },
		{ name = Names.Sky, write = buildSky },
		{ name = Names.Clouds, write = buildClouds },
	}
	for _, step in steps do
		if not guarded("building " .. step.name, step.write) then
			table.insert(failed, step.name)
		end
	end
	for _, entry in PROPERTY_WRITES do
		if not guarded("writing Lighting." .. entry.name, entry.write) then
			table.insert(failed, entry.name)
		end
	end
	return failed
end

-- The storm deck, if built (clients pulse it during lightning).
function LightingRig.clouds(): Clouds?
	local land = terrain()
	if not land then
		return nil
	end
	local found = land:FindFirstChild(Names.Clouds)
	return if found and found:IsA("Clouds") then found else nil
end

return table.freeze(LightingRig)
