--!strict
-- Server lighting baseline: a dense dark haze, a desaturated green-blue grade, subtle bloom and a storm deck of
-- clouds. Lighting properties mirror the pins in default.project.json so a `rojo serve` session and a built
-- place look identical. Clients layer their own effects (panic grade, depth of field, lightning pulses) on top.

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
LightingRig.Baseline = table.freeze({
	ClockTime = 0.5,
	Brightness = 0,
	Ambient = Color3.new(0, 0, 0),
	OutdoorAmbient = Color3.new(0.02, 0.02, 0.025),
	EnvironmentDiffuseScale = 0,
	EnvironmentSpecularScale = 0.15,
	ExposureCompensation = -0.25,
	ShadowSoftness = 0.35,
	AtmosphereDensity = 0.42,
	AtmosphereOffset = 0.12,
	AtmosphereHaze = 2.6,
	AtmosphereColor = Color3.fromRGB(30, 33, 36),
	AtmosphereDecay = Color3.fromRGB(14, 17, 18),
	GradeBrightness = -0.03,
	GradeContrast = 0.12,
	GradeSaturation = -0.45,
	GradeTint = Color3.fromRGB(226, 246, 244),
	BloomIntensity = 0.35,
	BloomSize = 28,
	BloomThreshold = 1.6,
	CloudCover = 0.93,
	CloudDensity = 0.78,
	CloudColor = Color3.fromRGB(38, 40, 46),
})

local Baseline = LightingRig.Baseline
local Names = LightingRig.Names

local function terrain(): Terrain?
	return Workspace:FindFirstChildOfClass("Terrain")
end

-- Rebuilds the server baseline from scratch (existing Lighting children are removed first).
function LightingRig.apply()
	for _, child in Lighting:GetChildren() do
		child:Destroy()
	end

	Lighting.ClockTime = Baseline.ClockTime
	Lighting.Brightness = Baseline.Brightness
	Lighting.Ambient = Baseline.Ambient
	Lighting.OutdoorAmbient = Baseline.OutdoorAmbient
	Lighting.EnvironmentDiffuseScale = Baseline.EnvironmentDiffuseScale
	Lighting.EnvironmentSpecularScale = Baseline.EnvironmentSpecularScale
	Lighting.ExposureCompensation = Baseline.ExposureCompensation
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = Baseline.ShadowSoftness
	Lighting.LightingStyle = Enum.LightingStyle.Realistic
	Lighting.PrioritizeLightingQuality = true

	local atmosphere = Instance.new("Atmosphere")
	atmosphere.Name = Names.Atmosphere
	atmosphere.Density = Baseline.AtmosphereDensity
	atmosphere.Offset = Baseline.AtmosphereOffset
	atmosphere.Haze = Baseline.AtmosphereHaze
	atmosphere.Glare = 0
	atmosphere.Color = Baseline.AtmosphereColor
	atmosphere.Decay = Baseline.AtmosphereDecay
	atmosphere.Parent = Lighting

	local grade = Instance.new("ColorCorrectionEffect")
	grade.Name = Names.ColorCorrection
	grade.Brightness = Baseline.GradeBrightness
	grade.Contrast = Baseline.GradeContrast
	grade.Saturation = Baseline.GradeSaturation
	grade.TintColor = Baseline.GradeTint
	grade.Parent = Lighting

	local bloom = Instance.new("BloomEffect")
	bloom.Name = Names.Bloom
	bloom.Intensity = Baseline.BloomIntensity
	bloom.Size = Baseline.BloomSize
	bloom.Threshold = Baseline.BloomThreshold
	bloom.Parent = Lighting

	-- Storm night: no sun, moon or stars behind the cloud deck (default sky textures are left untouched).
	local sky = Instance.new("Sky")
	sky.Name = Names.Sky
	sky.CelestialBodiesShown = false
	sky.StarCount = 0
	sky.Parent = Lighting

	local land = terrain()
	if land then
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
	else
		log.warn("Workspace has no Terrain; the storm cloud deck was skipped")
	end
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
