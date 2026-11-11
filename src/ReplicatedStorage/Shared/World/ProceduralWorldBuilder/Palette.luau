--!strict
-- Material + colour grading for every surface the builders make. Layouts name entries by key (room floor / wall /
-- ceiling, platform material); builders use the extra keys below for trims, boards, water and set pieces.
-- The gray look (docs/design/game-spec-v2.md 5.1): every surface is a dark, cold gray, told apart by its material,
-- texture and lightness, never by a hue of its own; no key a school layout uses is more saturated than 0.25. The
-- only colours left are the ones that do a job: the hazard plates at the fire doors, the boiler's blue pilot flame
-- and the lobby's school bus (GrayLook.spec lists them by name).

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
	Concrete = entry(Enum.Material.Concrete, 91, 92, 93, "Concrete"),
	ConcreteDark = entry(Enum.Material.Concrete, 57, 58, 59, "Concrete"),
	ConcreteStained = entry(Enum.Material.Concrete, 68, 70, 72, "Concrete"),
	TileWhite = entry(Enum.Material.CeramicTiles, 146, 148, 150, "Tile"),
	TileGreen = entry(Enum.Material.CeramicTiles, 92, 94, 94, "Tile"),
	TileBlue = entry(Enum.Material.CeramicTiles, 88, 90, 93, "Tile"),
	Linoleum = entry(Enum.Material.Plastic, 99, 100, 100, "Tile"),
	WoodPanel = entry(Enum.Material.Wood, 62, 60, 58, "Wood"),
	PlasterSchool = entry(Enum.Material.Plaster, 119, 120, 121, "Concrete"),
	PlasterAsh = entry(Enum.Material.Plaster, 104, 106, 108, "Concrete"),
	BlockGray = entry(Enum.Material.Brick, 70, 72, 74, "Concrete"), -- painted concrete block
	MetalRust = entry(Enum.Material.CorrodedMetal, 76, 74, 72, "Metal"), -- mill scale
	MetalGalvanized = entry(Enum.Material.Metal, 112, 118, 120, "Metal"),
	RoofGravel = entry(Enum.Material.Pebble, 64, 64, 62, "Concrete"),
	Asphalt = entry(Enum.Material.Asphalt, 40, 40, 42, "Concrete"),
	Carpet = entry(Enum.Material.Carpet, 54, 52, 53, "Carpet"), -- charcoal with a hint of wine

	-- Builder-only keys
	Trim = entry(Enum.Material.Wood, 52, 52, 52, "Wood"),
	TrimMetal = entry(Enum.Material.Metal, 70, 72, 74, "Metal"),
	Plank = entry(Enum.Material.WoodPlanks, 78, 78, 78, "Wood"),
	PlankDark = entry(Enum.Material.WoodPlanks, 54, 54, 54, "Wood"),
	Glass = entry(Enum.Material.Glass, 120, 128, 132, "Glass"),
	Water = entry(Enum.Material.Glass, 34, 38, 40, "Water"),
	Soil = entry(Enum.Material.Ground, 42, 40, 38, "Grass"),
	Mud = entry(Enum.Material.Mud, 48, 46, 44, "Grass"),
	Sidewalk = entry(Enum.Material.Pavement, 84, 85, 86, "Concrete"),
	SlabEdge = entry(Enum.Material.Concrete, 96, 97, 98, "Concrete"), -- floor-slab band on the block facade
	Rubble = entry(Enum.Material.Slate, 68, 68, 66, "Concrete"),
	Iron = entry(Enum.Material.CorrodedMetal, 48, 49, 50, "Metal"),
	BusPaint = entry(Enum.Material.CorrodedMetal, 150, 112, 34, "Metal"),
	Rubber = entry(Enum.Material.Rubber, 26, 26, 26, "Concrete"),
	Ember = entry(Enum.Material.Glass, 120, 170, 255, "Metal"), -- the boiler's blue pilot flame
	Fixture = entry(Enum.Material.SmoothPlastic, 148, 150, 152, "Metal"),
	Screen = entry(Enum.Material.Glass, 24, 27, 29, "Glass"),
	SkylineConcrete = entry(Enum.Material.Concrete, 30, 31, 33, "Concrete"),
	SkylineSoot = entry(Enum.Material.Slate, 22, 22, 24, "Concrete"),
	SkylineWindow = entry(Enum.Material.Glass, 10, 11, 13, "Glass"),
	SkylineLit = entry(Enum.Material.Neon, 88, 98, 112, "Glass"),

	-- Interior finishes (Finishes): wainscots, chair rails, baseboards, vinyl floors
	Baseboard = entry(Enum.Material.Rubber, 28, 28, 29, "Concrete"), -- rubber cove base
	TileCap = entry(Enum.Material.CeramicTiles, 46, 50, 54, "Tile"), -- glazed bullnose cap over a tile wainscot
	WainscotSlate = entry(Enum.Material.CeramicTiles, 58, 62, 66, "Tile"), -- glazed corridor tile
	WainscotBlue = entry(Enum.Material.CeramicTiles, 64, 67, 71, "Tile"), -- restrooms and wet rooms
	WainscotGreen = entry(Enum.Material.CeramicTiles, 70, 72, 72, "Tile"), -- restrooms, locker rooms
	WainscotPaint = entry(Enum.Material.Plaster, 73, 74, 75, "Concrete"), -- classroom dado: dark gray gloss paint
	WainscotWood = entry(Enum.Material.Wood, 58, 56, 54, "Wood"), -- office panelling
	VinylGray = entry(Enum.Material.Plastic, 88, 90, 92, "Tile"), -- worn sheet vinyl down the corridors
	ClassroomVCT = entry(Enum.Material.Plastic, 110, 112, 112, "Tile"), -- speckled vinyl tile

	-- Signage and service runs
	SignPaper = entry(Enum.Material.SmoothPlastic, 186, 186, 182, "Metal"),
	SignPlate = entry(Enum.Material.SmoothPlastic, 42, 47, 54, "Metal"), -- enamelled room plate
	SignMetal = entry(Enum.Material.Metal, 132, 136, 132, "Metal"),
	HazardYellow = entry(Enum.Material.SmoothPlastic, 206, 162, 26, "Metal"),
	PipeIron = entry(Enum.Material.CorrodedMetal, 60, 61, 62, "Metal"),
	PipeLead = entry(Enum.Material.CorrodedMetal, 84, 86, 88, "Metal"),
	Conduit = entry(Enum.Material.Metal, 128, 132, 130, "Metal"),

	-- Wear, furniture and decay (Finishes, FurnitureBuilder, DecayBuilder)
	CeilingTile = entry(Enum.Material.Plaster, 117, 118, 119, "Concrete"), -- acoustic drop-ceiling tile
	CeilingVoid = entry(Enum.Material.SmoothPlastic, 7, 7, 8, "Concrete"), -- the plenum behind a missing tile
	DeskTop = entry(Enum.Material.Wood, 92, 90, 88, "Wood"), -- laminated school desk top
	DeskSteel = entry(Enum.Material.Metal, 52, 56, 54, "Metal"), -- tubular desk and chair frames
	ChairShell = entry(Enum.Material.Plastic, 60, 61, 62, "Wood"), -- moulded chair seats and backs
	Chalkboard = entry(Enum.Material.Slate, 34, 38, 38, "Concrete"),
	ChalkFrame = entry(Enum.Material.Metal, 104, 106, 100, "Metal"), -- aluminium board frame and chalk tray
	Cork = entry(Enum.Material.Cardboard, 96, 92, 88, "Wood"), -- noticeboard
	CabinetSteel = entry(Enum.Material.Metal, 74, 77, 80, "Metal"), -- filing cabinets, office desk carcasses
	PaperSheet = entry(Enum.Material.SmoothPlastic, 170, 170, 168, "Concrete"), -- loose paper on the floor
	Puddle = entry(Enum.Material.Glass, 14, 16, 14, "Water"), -- standing water: dark, glossy
	PlasterFlap = entry(Enum.Material.Plaster, 124, 126, 128, "Concrete"), -- paint and plaster peeling off a wall
	Lath = entry(Enum.Material.WoodPlanks, 66, 64, 62, "Wood"),
	Cable = entry(Enum.Material.Rubber, 20, 20, 20, "Concrete"), -- wiring hanging out of the ceiling
	LabWorktop = entry(Enum.Material.SmoothPlastic, 28, 30, 29, "Metal"), -- black epoxy resin bench top
}

-- Textured surfaces: palette key -> the generated texture that dresses it (tools/textures/manifest.json). Each
-- texture's manifest `bases` lists the materials of its keys; `python3 tools/textures/generate.py --check` verifies.
local textured: { [string]: string } = {
	PlasterSchool = "PaintedPlaster",
	PlasterAsh = "PaintedPlaster",
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
	BlockGray = "StainedBrick",
	Linoleum = "VinylTile",
	VinylGray = "VinylTile",
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
	"PlasterAsh",
	"BlockGray",
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
