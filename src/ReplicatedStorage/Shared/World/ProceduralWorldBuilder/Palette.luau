--!strict
-- Material + colour grading for every surface the builders make. Layouts name entries by key (room floor / wall /
-- ceiling, platform material); builders use the extra keys below for trims, boards, water and set pieces.
-- Colours are graded dark, desaturated and slightly green: the school has been rotting in the dark for years.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)

local log = Log.new("Palette")

export type Entry = {
	material: Enum.Material,
	color: Color3,
	surface: Enums.SurfaceKind,
}

local function entry(material: Enum.Material, r: number, g: number, b: number, surface: Enums.SurfaceKind): Entry
	return table.freeze({ material = material, color = Color3.fromRGB(r, g, b), surface = surface })
end

local entries: { [string]: Entry } = {
	-- Keys layouts use
	Concrete = entry(Enum.Material.Concrete, 92, 92, 88, "Concrete"),
	ConcreteDark = entry(Enum.Material.Concrete, 58, 58, 56, "Concrete"),
	ConcreteStained = entry(Enum.Material.Concrete, 74, 72, 60, "Concrete"),
	TileWhite = entry(Enum.Material.CeramicTiles, 150, 150, 138, "Tile"),
	TileGreen = entry(Enum.Material.CeramicTiles, 84, 104, 86, "Tile"),
	TileBlue = entry(Enum.Material.CeramicTiles, 70, 92, 110, "Tile"),
	Linoleum = entry(Enum.Material.Plastic, 104, 102, 88, "Tile"),
	WoodGym = entry(Enum.Material.WoodPlanks, 120, 92, 60, "Wood"),
	WoodPanel = entry(Enum.Material.Wood, 76, 56, 40, "Wood"),
	PlasterSchool = entry(Enum.Material.Plaster, 128, 122, 102, "Concrete"),
	PlasterGreen = entry(Enum.Material.Plaster, 82, 98, 80, "Concrete"),
	Brick = entry(Enum.Material.Brick, 92, 56, 44, "Concrete"),
	MetalRust = entry(Enum.Material.CorrodedMetal, 98, 70, 50, "Metal"),
	MetalGalvanized = entry(Enum.Material.Metal, 112, 118, 120, "Metal"),
	RoofGravel = entry(Enum.Material.Pebble, 64, 64, 62, "Concrete"),
	Asphalt = entry(Enum.Material.Asphalt, 40, 40, 42, "Concrete"),
	PoolTile = entry(Enum.Material.CeramicTiles, 70, 104, 102, "Tile"),
	Carpet = entry(Enum.Material.Carpet, 72, 40, 42, "Carpet"),
	Lab = entry(Enum.Material.Marble, 82, 88, 84, "Tile"),

	-- Builder-only keys
	Trim = entry(Enum.Material.Wood, 62, 48, 36, "Wood"),
	TrimMetal = entry(Enum.Material.Metal, 70, 72, 74, "Metal"),
	Plank = entry(Enum.Material.WoodPlanks, 94, 76, 54, "Wood"),
	PlankDark = entry(Enum.Material.WoodPlanks, 66, 52, 38, "Wood"),
	Glass = entry(Enum.Material.Glass, 120, 130, 128, "Glass"),
	Water = entry(Enum.Material.Glass, 38, 46, 30, "Water"),
	Soil = entry(Enum.Material.Ground, 46, 38, 30, "Grass"),
	Mud = entry(Enum.Material.Mud, 52, 44, 34, "Grass"),
	DeadGrass = entry(Enum.Material.Grass, 70, 66, 44, "Grass"),
	Sidewalk = entry(Enum.Material.Pavement, 84, 84, 80, "Concrete"),
	SlabEdge = entry(Enum.Material.Concrete, 98, 96, 90, "Concrete"), -- floor-slab band on the brick facade
	Rubble = entry(Enum.Material.Slate, 70, 68, 64, "Concrete"),
	Iron = entry(Enum.Material.CorrodedMetal, 54, 44, 38, "Metal"),
	BusPaint = entry(Enum.Material.CorrodedMetal, 150, 112, 34, "Metal"),
	Rubber = entry(Enum.Material.Rubber, 26, 26, 26, "Concrete"),
	Ember = entry(Enum.Material.Glass, 255, 120, 40, "Metal"),
	Fixture = entry(Enum.Material.SmoothPlastic, 150, 152, 146, "Metal"),
	Screen = entry(Enum.Material.Glass, 20, 34, 28, "Glass"),
	SkylineConcrete = entry(Enum.Material.Concrete, 30, 31, 33, "Concrete"),
	SkylineSoot = entry(Enum.Material.Slate, 22, 22, 24, "Concrete"),
	SkylineWindow = entry(Enum.Material.Glass, 10, 11, 13, "Glass"),
	SkylineLit = entry(Enum.Material.Neon, 110, 74, 36, "Glass"),
}

-- Keys every layout may reference; the spec asserts they all exist.
local layoutKeys: { string } = {
	"Concrete",
	"ConcreteDark",
	"ConcreteStained",
	"TileWhite",
	"TileGreen",
	"TileBlue",
	"Linoleum",
	"WoodGym",
	"WoodPanel",
	"PlasterSchool",
	"PlasterGreen",
	"Brick",
	"MetalRust",
	"MetalGalvanized",
	"RoofGravel",
	"Asphalt",
	"PoolTile",
	"Carpet",
	"Lab",
}

table.freeze(layoutKeys)
table.freeze(entries)

local FALLBACK = "Concrete"

local warned: { [string]: boolean } = {}

local Palette = {}

Palette.LayoutKeys = layoutKeys
Palette.Fallback = FALLBACK

function Palette.has(key: string): boolean
	return entries[key] ~= nil
end

-- Returns the entry for `key`, or Concrete (with one warning per unknown key) when it does not exist.
function Palette.get(key: string?): Entry
	if key then
		local found = entries[key]
		if found then
			return found
		end
		if not warned[key] then
			warned[key] = true
			log.warn("unknown palette key %q; using %s", key, FALLBACK)
		end
	end
	return entries[FALLBACK]
end

-- Applies material + colour to a part.
function Palette.apply(part: BasePart, key: string?)
	local value = Palette.get(key)
	part.Material = value.material
	part.Color = value.color
end

-- Every key, sorted (dev tooling and specs).
function Palette.keys(): { string }
	local out: { string } = {}
	for key in entries do
		table.insert(out, key)
	end
	table.sort(out)
	return out
end

return table.freeze(Palette)
