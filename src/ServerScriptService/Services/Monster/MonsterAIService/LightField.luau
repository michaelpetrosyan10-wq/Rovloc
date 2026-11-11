--!strict
-- LightField: "lit" for the Creature's senses (docs/MONSTER.md 3.2: a player in a lit pool is seen from SightLit, the
-- stare reaches LitRange when it stands lit). The light at a point comes from the fixtures the server built, never from
-- anything a client renders: no flicker, no graphics tier, no light budget, no power cut or scene override.
--
-- Fixtures: every LevelLight of the level (SchoolShellBuilder: LightKind, LevelId, BaseBrightness, FlickerGroup) with
-- its light's Range and Color, at its part. Like the website's baked probe grid (the base grid only: web/tools/bake),
-- the scripted groups a level switches as a whole are left out: a tunnel floor's power circuits ("Mains:" / "Circuit:"
-- groups, held down by the power switch), "Scripted:" groups and the classroom glow. A broken fixture (BaseBrightness
-- 0) gives nothing.
--
-- The light at a point (luminanceAt): the sum over the fixtures within their range of BaseBrightness x the falloff the
-- bake and the web engine share (a range window (1 - (d/R)^2)^2 over a soft inverse square 1 / (1 + 0.004 d^2)) x the
-- luminance of the light's linear colour (0.2126 R + 0.7152 G + 0.0722 B), each only where `lineClear` (when given)
-- sees the fixture. Lit when it is above CreatureConfig.Senses.LitIrradiance (0.2).
--
-- Pure (tests/Specs/LightField.spec.luau): falloff, colorLuminance, include, luminanceAt, litAt.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Tags = require(ReplicatedStorage.Shared.Tags)

export type Fixture = {
	position: Vector3,
	brightness: number,
	range: number,
	luminance: number, -- the light colour's linear luminance
}

local W = Attributes.World
local FALLOFF_K = 0.004
local POWER_PREFIXES: { string } = { "Mains:", "Circuit:", "Scripted:" }
local LIGHT_CLASSES: { string } = { "PointLight", "SpotLight", "SurfaceLight" }

local LightField = {}

LightField.FalloffK = FALLOFF_K
LightField.Threshold = CreatureConfig.Senses.LitIrradiance

-- The range falloff the bake and the web engine share.
function LightField.falloff(d: number, range: number): number
	if range <= 0 then
		return 0
	end
	local x = math.min(1, d / range)
	local w = 1 - x * x
	return w * w / (1 + FALLOFF_K * d * d)
end

local function linear(c: number): number
	return if c <= 0.04045 then c / 12.92 else ((c + 0.055) / 1.055) ^ 2.4
end

-- The linear luminance of an sRGB colour.
function LightField.colorLuminance(color: Color3): number
	return 0.2126 * linear(color.R) + 0.7152 * linear(color.G) + 0.0722 * linear(color.B)
end

-- Whether a fixture counts toward the base light (see the header).
function LightField.include(kind: string?, group: string?, brightness: number): boolean
	if brightness <= 0 then
		return false
	end
	if kind == "ClassroomGlow" then
		return false
	end
	if group then
		for _, prefix in POWER_PREFIXES do
			if string.sub(group, 1, #prefix) == prefix then
				return false
			end
		end
	end
	return true
end

-- The base light at `point` (see the header). `lineClear` (optional) is the shadow test.
function LightField.luminanceAt(
	fixtures: { Fixture },
	point: Vector3,
	lineClear: ((from: Vector3, to: Vector3) -> boolean)?
): number
	local sum = 0
	for _, f in fixtures do
		local d = (f.position - point).Magnitude
		if d >= f.range then
			continue
		end
		local contribution = f.brightness * LightField.falloff(d, f.range) * f.luminance
		if contribution < 0.003 then
			continue
		end
		if lineClear and not lineClear(point, f.position) then
			continue
		end
		sum += contribution
	end
	return sum
end

function LightField.litAt(
	fixtures: { Fixture },
	point: Vector3,
	lineClear: ((from: Vector3, to: Vector3) -> boolean)?,
	threshold: number?
): boolean
	return LightField.luminanceAt(fixtures, point, lineClear) > (threshold or LightField.Threshold)
end

-- The level's fixtures as the server built them (every LevelLight with LevelId `levelId`).
function LightField.collect(levelId: string): { Fixture }
	local out: { Fixture } = {}
	for _, fixture in CollectionService:GetTagged(Tags.LevelLight) do
		if not fixture:IsA("BasePart") or fixture:GetAttribute(W.LevelId) ~= levelId then
			continue
		end
		local kind = fixture:GetAttribute(W.LightKind)
		local group = fixture:GetAttribute(W.FlickerGroup)
		local base = fixture:GetAttribute(W.BaseBrightness)
		local brightness = if type(base) == "number" then base else 0
		if
			not LightField.include(
				if type(kind) == "string" then kind else nil,
				if type(group) == "string" then group else nil,
				brightness
			)
		then
			continue
		end
		local light: Light? = nil
		for _, child in fixture:GetChildren() do
			if table.find(LIGHT_CLASSES, child.ClassName) then
				light = child :: Light
				break
			end
		end
		if not light then
			continue
		end
		local range = (light :: any).Range
		table.insert(out, {
			position = fixture.Position,
			brightness = brightness,
			range = if type(range) == "number" then range else 0,
			luminance = LightField.colorLuminance(light.Color),
		})
	end
	return out
end

return table.freeze(LightField)
