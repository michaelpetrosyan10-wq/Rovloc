--!strict
-- FixtureGlow: the lit surfaces of a LevelLight fixture (fluorescent tubes, a bulb's filament, an emergency lamp's
-- lens, a floodlight's face, a firebox's embers, an exit sign's letters), shared by the builder that makes them
-- (SchoolShellBuilder.buildLight) and the one run-time writer that drives them (LightingController).
--
-- A glow surface is a BasePart child of the fixture part whose name starts with "Glow". Lit, it is Neon in the
-- fixture's lit colour (the light's own colour, whitened for tubes and bulbs: the tube burns whiter than the pool it
-- throws), so bloom haloes it. As its light fades the Neon darkens toward near-black; at zero it turns to dead milky
-- glass. An exit sign's letters are a SurfaceGui named "GlowGui" with LightInfluence 0, whose Brightness follows the
-- light the same way. Each burning kind also has a haze cone shape (`cone`): the visible shaft LightingController's
-- volumetrics hang under the nearest fixtures, brightening and dying with the glow (`coneBrightness`). Everything here
-- is pure (no instance lookups beyond the part handed in), so the specs can check the curve and the server build and
-- every client agree on what a fixture looks like at a given brightness.

local FixtureGlow = {}

FixtureGlow.PartPrefix = "Glow"
FixtureGlow.GuiName = "GlowGui"

-- Material of a lit glow surface, and of one whose light is out.
FixtureGlow.OnMaterial = Enum.Material.Neon
FixtureGlow.OffMaterial = Enum.Material.Glass

-- A dead tube or lens: grey, milky glass.
FixtureGlow.OffColor = Color3.fromRGB(96, 100, 98)
-- A lit surface's Neon colour as its light fades toward nothing.
FixtureGlow.DimColor = Color3.fromRGB(14, 15, 15)
-- Below this level a surface reads as off (dead glass instead of a black Neon).
FixtureGlow.OffLevel = 0.03
-- GlowGui brightness at full level (above 1 so the letters bloom like the tubes).
FixtureGlow.GuiBrightness = 1.8

-- How far each kind's glow is whitened from its light colour.
local WHITEN: { [string]: number } = {
	Fluorescent = 0.5,
	ClassroomGlow = 0.45,
	Bulb = 0.3,
	Floodlight = 0.4,
	EmergencyRed = 0.05,
	ExitSign = 0.15,
	BoilerGlow = 0,
}

local WHITE = Color3.new(1, 1, 1)

-- The colour a fixture of `kind` glows when its light (`lightColor`) burns at full brightness.
function FixtureGlow.litColor(kind: string, lightColor: Color3): Color3
	return lightColor:Lerp(WHITE, WHITEN[kind] or 0.3)
end

-- Glow level in [0, 1] of a fixture whose light burns at `brightness` and whose working brightness is `base`
-- (0 for a fixture built dark; an override that lights one counts as full at brightness 1).
function FixtureGlow.level(brightness: number, base: number): number
	if brightness ~= brightness or brightness <= 0 then
		return 0
	end
	local reference = if base > 0 then base else 1
	return math.clamp(brightness / reference, 0, 1)
end

-- Material and colour of a glow surface whose lit colour is `lit`, at `level`.
function FixtureGlow.look(lit: Color3, level: number): (Enum.Material, Color3)
	if level <= FixtureGlow.OffLevel then
		return FixtureGlow.OffMaterial, FixtureGlow.OffColor
	end
	-- a gentle gamma: a stuttering tube still reads lit through its shallow dips
	return FixtureGlow.OnMaterial, FixtureGlow.DimColor:Lerp(lit, math.clamp(level, 0, 1) ^ 0.8)
end

-- GlowGui brightness at `level`.
function FixtureGlow.guiBrightness(level: number): number
	if level <= FixtureGlow.OffLevel then
		return 0
	end
	return FixtureGlow.GuiBrightness * math.clamp(level, 0, 1)
end

-- Haze cones: the visible shaft a burning fixture throws through the level's haze (LightingController draws one under
-- each of the nearest fixtures its render budget allows, in the fixture's lit colour). `width0` at the lamp, `width1`
-- where the cone meets the floor, at most `length` studs long (aimed down, or along a floodlight's face), `strength`
-- the cone's brightness at full level.
export type ConeShape = {
	width0: number,
	width1: number,
	length: number,
	strength: number,
	aimed: boolean, -- along the fixture's front face (a floodlight) instead of straight down
}

local CONES: { [string]: ConeShape } = {
	Fluorescent = table.freeze({ width0 = 3.2, width1 = 9.5, length = 13, strength = 1, aimed = false }),
	ClassroomGlow = table.freeze({ width0 = 3, width1 = 9, length = 12, strength = 0.9, aimed = false }),
	Bulb = table.freeze({ width0 = 0.7, width1 = 7, length = 11, strength = 1.15, aimed = false }),
	Floodlight = table.freeze({ width0 = 1.8, width1 = 14, length = 26, strength = 1.3, aimed = true }),
	EmergencyRed = table.freeze({ width0 = 0.9, width1 = 5, length = 7, strength = 0.7, aimed = false }),
}

-- The haze cone of a fixture kind (nil: the kind throws none: exit signs, boiler embers).
function FixtureGlow.cone(kind: string): ConeShape?
	return CONES[kind]
end

-- Brightness of a haze cone at glow `level` in air whose shafts read at `haze` (LightingMood film.shafts). A gentle
-- curve like the tubes': a dipping tube's cone thins with it, a dead one leaves nothing.
function FixtureGlow.coneBrightness(shape: ConeShape, level: number, haze: number): number
	if level <= FixtureGlow.OffLevel then
		return 0
	end
	return shape.strength * math.max(0, haze) * math.clamp(level, 0, 1) ^ 0.8
end

function FixtureGlow.isGlowPart(instance: Instance): boolean
	return instance:IsA("BasePart") and string.sub(instance.Name, 1, #FixtureGlow.PartPrefix) == FixtureGlow.PartPrefix
end

function FixtureGlow.isGlowGui(instance: Instance): boolean
	return instance:IsA("SurfaceGui") and instance.Name == FixtureGlow.GuiName
end

-- Writes the look at `level` onto a glow part (only the properties that change).
function FixtureGlow.apply(part: BasePart, lit: Color3, level: number)
	local material, color = FixtureGlow.look(lit, level)
	if part.Material ~= material then
		part.Material = material
	end
	part.Color = color
end

return table.freeze(FixtureGlow)
