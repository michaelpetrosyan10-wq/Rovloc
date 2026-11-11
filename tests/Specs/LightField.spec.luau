--!strict
-- LightField: "lit" for the Creature's senses comes from the fixtures the server built (docs/MONSTER.md 3.2), never a
-- client's render: the falloff the bake and the web engine share, the light colour's linear luminance, which fixtures
-- count toward the base light (no power circuits, scripted groups, classroom glow, pool floodlights or broken bulbs),
-- the sum at a point with shadows, the LitIrradiance threshold, and collecting a level's LevelLight fixtures.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Tags = require(ReplicatedStorage.Shared.Tags)

local LightField = require(ServerScriptService.Services.Monster.MonsterAIService.LightField)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local W = Attributes.World

local function fixture(position: Vector3, brightness: number, range: number): LightField.Fixture
	return { position = position, brightness = brightness, range = range, luminance = 1 }
end

local spec = {}

spec["falloff: the web's window over a soft inverse square"] = function(t: Expect)
	t.eq(LightField.falloff(0, 20), 1, "full at the bulb")
	t.eq(LightField.falloff(20, 20), 0, "nothing at the range")
	t.eq(LightField.falloff(35, 20), 0, "nothing past it")
	t.eq(LightField.falloff(5, 0), 0, "no range, no light")
	for _, d in { 2, 5, 10, 15 } do
		local x = d / 20
		local expected = (1 - x * x) ^ 2 / (1 + LightField.FalloffK * d * d)
		t.near(LightField.falloff(d, 20), expected, 1e-12, "the shared formula at " .. d)
	end
	local previous = 1
	for d = 0, 20, 0.5 do
		local value = LightField.falloff(d, 20)
		t.truthy(value <= previous + 1e-12, "monotone at " .. d)
		previous = value
	end
end

spec["luminance: the light colour's linear luminance"] = function(t: Expect)
	t.near(LightField.colorLuminance(Color3.new(1, 1, 1)), 1, 1e-9, "white")
	t.eq(LightField.colorLuminance(Color3.new(0, 0, 0)), 0, "black")
	t.near(LightField.colorLuminance(Color3.new(0.5, 0.5, 0.5)), 0.21404, 1e-4, "sRGB 0.5 is 21 % linear")
	t.truthy(
		LightField.colorLuminance(Color3.new(0, 1, 0)) > LightField.colorLuminance(Color3.new(1, 0, 0)),
		"green weighs most"
	)
	t.truthy(LightField.colorLuminance(Color3.fromRGB(255, 214, 170)) > 0.6, "a warm bulb is still bright")
end

spec["include: the base light leaves out power circuits, scripted groups, glows and broken bulbs"] = function(t: Expect)
	t.truthy(LightField.include("Ceiling", nil, 1), "a plain fixture")
	t.truthy(LightField.include("Ceiling", "HallA", 1), "a flicker group of its own")
	t.falsy(LightField.include("Bulb", "Mains:North", 1), "a tunnel's mains (the power switch)")
	t.falsy(LightField.include("Bulb", "Circuit:3", 1), "a flickering circuit")
	t.falsy(LightField.include("Ceiling", "Scripted:Lab", 1), "a scripted group")
	t.falsy(LightField.include("ClassroomGlow", nil, 1), "the classroom glow")
	t.falsy(LightField.include("Ceiling", nil, 0), "a broken fixture")
end

spec["lit: the sum of the fixtures in range, shadows cut, above LitIrradiance"] = function(t: Expect)
	t.eq(LightField.Threshold, CreatureConfig.Senses.LitIrradiance, "the threshold is the config's")
	local point = Vector3.new(0, 4, 0)
	local near = fixture(Vector3.new(0, 10, 0), 1, 30)
	local far = fixture(Vector3.new(100, 10, 0), 1, 30)
	t.eq(LightField.luminanceAt({}, point), 0, "no fixtures, dark")
	t.eq(LightField.luminanceAt({ far }, point), 0, "out of range")
	local one = LightField.luminanceAt({ near }, point)
	t.near(one, LightField.falloff(6, 30), 1e-9, "brightness x falloff x luminance")
	t.near(LightField.luminanceAt({ near, near }, point), 2 * one, 1e-9, "two fixtures add up")
	local tinted: LightField.Fixture = { position = near.position, brightness = 1, range = 30, luminance = 0.5 }
	t.near(LightField.luminanceAt({ tinted }, point), one * 0.5, 1e-9, "a dim colour gives less")
	t.truthy(LightField.litAt({ near }, point), "under a bulb is lit")
	t.falsy(LightField.litAt({ fixture(Vector3.new(0, 10, 25), 1, 30) }, point), "at the edge of its pool is dark")
	local walls = function(_from: Vector3, _to: Vector3): boolean
		return false
	end
	t.eq(LightField.luminanceAt({ near }, point, walls), 0, "a wall in between casts a shadow")
	t.falsy(LightField.litAt({ near }, point, walls), "so it is dark")
	t.truthy(LightField.litAt({ near }, point, nil, 0.01), "a custom threshold")
end

spec["collect: a level's built fixtures with their light, the power circuits and other levels left out"] = function(
	t: Expect
)
	-- GetTagged only sees instances in the place
	local folder = Instance.new("Folder")
	folder.Name = "LightFieldSpec"
	folder.Parent = Workspace
	local function build(levelId: string, group: string?, base: number, withLight: boolean): BasePart
		local part = Instance.new("Part")
		part.Position = Vector3.new(10, 9, 20)
		part:SetAttribute(W.LevelId, levelId)
		part:SetAttribute(W.LightKind, "Ceiling")
		part:SetAttribute(W.BaseBrightness, base)
		if group then
			part:SetAttribute(W.FlickerGroup, group)
		end
		if withLight then
			local light = Instance.new("PointLight")
			light.Range = 24
			light.Color = Color3.new(1, 1, 1)
			light.Parent = part
		end
		part.Parent = folder
		part:AddTag(Tags.LevelLight)
		return part
	end
	local parts = {
		build("LightFieldSpec", nil, 1.5, true),
		build("LightFieldSpec", "Mains:A", 1, true),
		build("LightFieldSpec", nil, 0, true),
		build("LightFieldSpec", nil, 1, false),
		build("OtherLevel", nil, 1, true),
	}
	local fixtures = LightField.collect("LightFieldSpec")
	t.eq(#fixtures, 1, "only the plain, working, lit fixture of this level")
	local f = fixtures[1]
	if f then
		t.eq(f.brightness, 1.5, "its BaseBrightness")
		t.eq(f.range, 24, "its light's range")
		t.near(f.luminance, 1, 1e-9, "its colour")
		t.truthy((f.position - Vector3.new(10, 9, 20)).Magnitude < 1e-6, "at its part")
	end
	for _, part in parts do
		part:RemoveTag(Tags.LevelLight)
	end
	folder:Destroy()
end

return spec
