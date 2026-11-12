--!strict
-- Material + colour grading for every surface the builders make. Layouts name entries by key (room floor / wall /
-- ceiling, platform material); builders use the extra keys below for trims, boards, water and set pieces.
-- Colours are graded dark, desaturated and slightly green: the school has been rotting in the dark for years.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

local MaterialLibrary = require(script.Parent.MaterialLibrary)

local log = Log.new("Palette")

export type Entry = {
	material: Enum.Material,
	color: Color3,
	surface: Enums.SurfaceKind,
	-- Generated texture (a tools/textures/manifest.json id) that dresses this key once it is uploaded; see
	-- `textured` below. Untextured until then: the key keeps its plain material.
	variant: string?,
}

local function entry(material: Enum.Material, r: number, g: number, b: number, surface: Enums.SurfaceKind): Entry
	return { material = material, color = Color3.fromRGB(r, g, b), surface = surface }
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
	WoodPanel = entry(Enum.Material.Wood, 76, 56, 40, "Wood"),
	PlasterSchool = entry(Enum.Material.Plaster, 128, 122, 102, "Concrete"),
	PlasterGreen = entry(Enum.Material.Plaster, 82, 98, 80, "Concrete"),
	Brick = entry(Enum.Material.Brick, 92, 56, 44, "Concrete"),
	MetalRust = entry(Enum.Material.CorrodedMetal, 98, 70, 50, "Metal"),
	MetalGalvanized = entry(Enum.Material.Metal, 112, 118, 120, "Metal"),
	RoofGravel = entry(Enum.Material.Pebble, 64, 64, 62, "Concrete"),
	Asphalt = entry(Enum.Material.Asphalt, 40, 40, 42, "Concrete"),
	Carpet = entry(Enum.Material.Carpet, 72, 40, 42, "Carpet"),

	-- Builder-only keys
	Trim = entry(Enum.Material.Wood, 62, 48, 36, "Wood"),
	TrimMetal = entry(Enum.Material.Metal, 70, 72, 74, "Metal"),
	Plank = entry(Enum.Material.WoodPlanks, 94, 76, 54, "Wood"),
	PlankDark = entry(Enum.Material.WoodPlanks, 66, 52, 38, "Wood"),
	Glass = entry(Enum.Material.Glass, 120, 130, 128, "Glass"),
	Water = entry(Enum.Material.Glass, 38, 46, 30, "Water"),
	Soil = entry(Enum.Material.Ground, 46, 38, 30, "Grass"),
	Mud = entry(Enum.Material.Mud, 52, 44, 34, "Grass"),
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

	-- Interior finishes (Finishes): wainscots, chair rails, baseboards, linoleum and vinyl floors
	Baseboard = entry(Enum.Material.Rubber, 30, 29, 27, "Concrete"), -- rubber cove base
	TileCap = entry(Enum.Material.CeramicTiles, 44, 54, 48, "Tile"), -- glazed bullnose cap over a tile wainscot
	WainscotOxblood = entry(Enum.Material.CeramicTiles, 92, 44, 40, "Tile"), -- glazed corridor tile (Level 1)
	WainscotTeal = entry(Enum.Material.CeramicTiles, 46, 84, 82, "Tile"), -- Auditorium storey corridors (Level 2)
	WainscotBlue = entry(Enum.Material.CeramicTiles, 46, 72, 98, "Tile"), -- restrooms and wet rooms
	WainscotGreen = entry(Enum.Material.CeramicTiles, 54, 86, 68, "Tile"), -- restrooms, locker rooms
	WainscotPaint = entry(Enum.Material.Plaster, 70, 80, 62, "Concrete"), -- classroom dado: dark olive gloss paint
	WainscotWood = entry(Enum.Material.Wood, 70, 50, 34, "Wood"), -- office panelling
	LinoleumBeige = entry(Enum.Material.Plastic, 120, 114, 96, "Tile"), -- worn linoleum down the corridors and halls
	ClassroomVCT = entry(Enum.Material.Plastic, 132, 126, 106, "Tile"), -- speckled vinyl tile

	-- Signage and service runs
	SignPaper = entry(Enum.Material.SmoothPlastic, 196, 188, 162, "Metal"),
	SignPlate = entry(Enum.Material.SmoothPlastic, 34, 52, 74, "Metal"), -- enamelled room plate
	SignMetal = entry(Enum.Material.Metal, 132, 136, 132, "Metal"),
	HazardYellow = entry(Enum.Material.SmoothPlastic, 206, 162, 26, "Metal"),
	PipeIron = entry(Enum.Material.CorrodedMetal, 72, 58, 48, "Metal"),
	PipeCopper = entry(Enum.Material.CorrodedMetal, 112, 82, 58, "Metal"),
	Conduit = entry(Enum.Material.Metal, 128, 132, 130, "Metal"),

	-- Wear, furniture and decay (Finishes, FurnitureBuilder, DecayBuilder)
	CeilingTile = entry(Enum.Material.Plaster, 128, 122, 102, "Concrete"), -- acoustic drop-ceiling tile
	CeilingVoid = entry(Enum.Material.SmoothPlastic, 7, 7, 8, "Concrete"), -- the plenum behind a missing tile
	DeskTop = entry(Enum.Material.Wood, 112, 92, 66, "Wood"), -- laminated school desk top
	DeskSteel = entry(Enum.Material.Metal, 52, 56, 54, "Metal"), -- tubular desk and chair frames
	ChairShell = entry(Enum.Material.Plastic, 70, 62, 48, "Wood"), -- moulded chair seats and backs
	Chalkboard = entry(Enum.Material.Slate, 30, 44, 36, "Concrete"),
	ChalkFrame = entry(Enum.Material.Metal, 104, 106, 100, "Metal"), -- aluminium board frame and chalk tray
	Cork = entry(Enum.Material.Cardboard, 118, 88, 58, "Wood"), -- noticeboard
	CabinetSteel = entry(Enum.Material.Metal, 74, 80, 74, "Metal"), -- filing cabinets, office desk carcasses
	PaperSheet = entry(Enum.Material.SmoothPlastic, 176, 170, 148, "Concrete"), -- loose paper on the floor
	Puddle = entry(Enum.Material.Glass, 14, 16, 14, "Water"), -- standing water: dark, glossy
	PlasterFlap = entry(Enum.Material.Plaster, 136, 128, 106, "Concrete"), -- paint and plaster peeling off a wall
	Lath = entry(Enum.Material.WoodPlanks, 84, 62, 40, "Wood"),
	Cable = entry(Enum.Material.Rubber, 20, 20, 20, "Concrete"), -- wiring hanging out of the ceiling
	LabWorktop = entry(Enum.Material.SmoothPlastic, 28, 30, 29, "Metal"), -- black epoxy resin bench top
}

-- Textured surfaces: palette key -> the generated texture that dresses it (tools/textures/manifest.json). Each
-- texture's manifest `bases` lists the materials of its keys; `python3 tools/textures/generate.py --check` verifies.
local textured: { [string]: string } = {
	PlasterSchool = "PaintedPlaster",
	PlasterGreen = "PaintedPlaster",
	WainscotPaint = "PaintedPlaster",
	Concrete = "StainedConcrete",
	ConcreteDark = "StainedConcrete",
	ConcreteStained = "StainedConcrete",
	SlabEdge = "StainedConcrete",
	CeilingTile = "CeilingTile",
	MetalRust = "RustedMetal",
	Iron = "RustedMetal",
	PipeIron = "RustedMetal",
	BusPaint = "RustedMetal",
	TrimMetal = "RustedMetal",
	MetalGalvanized = "GalvanizedMetal",
	Conduit = "GalvanizedMetal",
	WoodPanel = "WornWood",
	Plank = "WornWood",
	PlankDark = "WornWood",
	Trim = "WornWood",
	WainscotWood = "WornWood",
	TileWhite = "PoolMosaic",
	TileGreen = "PoolMosaic",
	TileBlue = "PoolMosaic",
	WainscotBlue = "PoolMosaic",
	WainscotGreen = "PoolMosaic",
	WainscotTeal = "PoolMosaic",
	Brick = "StainedBrick",
	Linoleum = "VinylTile",
	LinoleumBeige = "VinylTile",
	ClassroomVCT = "VinylTile",
	LabWorktop = "LabWorktop",
	Rubber = "RubberMat",
	Baseboard = "RubberMat",
	RoofGravel = "RoofGravel",
}

for key, texture in textured do
	local value = entries[key]
	assert(value, "textured key without a palette entry: " .. key)
	value.variant = texture
end
for _, value in entries do
	table.freeze(value)
end

-- Keys every layout may reference; the spec asserts they all exist.
local layoutKeys: { string } = {
	"Concrete",
	"ConcreteDark",
	"ConcreteStained",
	"TileWhite",
	"TileGreen",
	"TileBlue",
	"Linoleum",
	"WoodPanel",
	"PlasterSchool",
	"PlasterGreen",
	"Brick",
	"MetalRust",
	"MetalGalvanized",
	"RoofGravel",
	"Asphalt",
	"Carpet",
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

-- The MaterialVariant that dresses `key`'s surface: the name of its generated texture's variant for the key's
-- material when that texture's colour map is uploaded (TextureAssets) and the variant is in MaterialService; nil
-- otherwise, and then the surface keeps its plain material exactly as it looked before textures existed.
function Palette.variantFor(key: string): string?
	local value = entries[key]
	if not value or not value.variant then
		return nil
	end
	return MaterialLibrary.variantFor(value.variant, value.material)
end

-- Colour a part of `key` stores: `color` (default: the key's palette colour) as it is for an untextured key, or
-- compensated for the variant's colour map when the key is textured, so the dressed surface keeps the grade. On the
-- 8-bit grid a part keeps its colour on (MathUtil.color8), so this is exactly what the part reads back.
function Palette.colorFor(key: string, color: Color3?): Color3
	local value = Palette.get(key)
	local base = color or value.color
	if value.variant and Palette.variantFor(key) then
		return MathUtil.color8(MaterialLibrary.tint(value.variant, base))
	end
	return MathUtil.color8(base)
end

-- Colours `part` (already given its material) `color` (default: `key`'s palette colour) and, when the variant of `key`
-- is live for the part's material, dresses it in that MaterialVariant with the colour compensated for its colour map.
-- The colour is written once, on the 8-bit grid (MathUtil.color8), and never read back from the part: Roblox keeps
-- BasePart.Color in 8 bits and Lune keeps floats, so a colour read back and reworked would differ between the live
-- server and the web's export. Returns whether the variant dressed it; an untextured key, an overridden material or no
-- uploaded texture leaves MaterialVariant untouched. Unknown / nil keys resolve like `get`.
function Palette.dress(part: BasePart, key: string?, color: Color3?): boolean
	local value = entries[key or FALLBACK] or entries[FALLBACK]
	local base = color or value.color
	local texture = value.variant
	local name = if texture then MaterialLibrary.variantFor(texture, part.Material) else nil
	if texture and name then
		part.MaterialVariant = name
		part.Color = MathUtil.color8(MaterialLibrary.tint(texture, base))
		return true
	end
	part.Color = MathUtil.color8(base)
	return false
end

-- Applies material + colour (and the key's texture when it is live) to a part, clearing a variant a previous key
-- left on it.
function Palette.apply(part: BasePart, key: string?)
	local value = Palette.get(key)
	part.Material = value.material
	if not Palette.dress(part, key) and part.MaterialVariant ~= "" then
		part.MaterialVariant = ""
	end
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
