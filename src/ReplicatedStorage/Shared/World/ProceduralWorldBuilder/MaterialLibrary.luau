--!strict
-- MaterialLibrary: the generated PBR textures in game.
--
-- tools/textures generates seamless colour / normal / roughness / metalness maps; the Textures workflow uploads
-- them to the owner's Roblox account and writes two files: Config/TextureAssets (the image ids per texture and map)
-- and src/MaterialService/RovlocTextures.model.json, which Rojo builds into MaterialService as one MaterialVariant
-- per texture and base material (variant maps can only be set by Studio / Rojo, never by a game script, so the
-- variants ship in the place and this module only picks them). A texture is live when TextureAssets holds its
-- ColorMap AND its variant for the part's material is in MaterialService; anything else answers nil and the
-- surface keeps its plain material, which is how the game looked before textures (and looks with TextureAssets
-- empty). Server and client read the same replicated MaterialService, so both agree.
--
-- The colour map multiplies the part's Color. Every map is authored around a light base layer (`reference` in
-- TextureAssets), so `tint` divides a palette colour by it: the base layer lands on the palette's grade and the
-- grime, grout and rust keep their relative depth on top.
--
-- Overlays (WallGrime, FloorDirt, RustStreaks, Cracks) are alpha colour maps for Texture instances: `overlay`
-- lays one on a part face when its image is uploaded.

local MaterialService = game:GetService("MaterialService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TextureAssets = require(ReplicatedStorage.Shared.Config.TextureAssets)

export type MapKind = "ColorMap" | "NormalMap" | "RoughnessMap" | "MetalnessMap"
export type Assets = { [string]: TextureAssets.Entry }

local FOLDER = "RovlocTextures" -- manifest.json variantFolder: the model file's instance in MaterialService
local PREFIX = "Rovloc" -- manifest.json variantPrefix

local MaterialLibrary = {}

MaterialLibrary.Folder = FOLDER

local assets: Assets = TextureAssets
local root: Instance = MaterialService
local found: { [string]: boolean } = {} -- variant names confirmed in the folder (misses are re-checked)

-- Points the library at another asset table and variant root (specs); `use()` with no arguments restores the
-- shipped TextureAssets and MaterialService.
function MaterialLibrary.use(withAssets: Assets?, withRoot: Instance?)
	assets = withAssets or TextureAssets
	root = withRoot or MaterialService
	table.clear(found)
end

-- Name of the MaterialVariant for `texture` on `base` (the model file uses the same rule).
function MaterialLibrary.variantName(texture: string, base: Enum.Material): string
	return PREFIX .. texture .. "_" .. base.Name
end

-- Whether `texture`'s colour map is uploaded.
function MaterialLibrary.has(texture: string): boolean
	local entry = assets[texture]
	return entry ~= nil and entry.ColorMap ~= nil
end

-- The MaterialVariant name to give a part of material `base` dressed in `texture`, or nil when the texture is not
-- live for that material.
function MaterialLibrary.variantFor(texture: string, base: Enum.Material): string?
	if not MaterialLibrary.has(texture) then
		return nil
	end
	local name = MaterialLibrary.variantName(texture, base)
	if found[name] then
		return name
	end
	local folder = root:FindFirstChild(FOLDER)
	local variant = folder and folder:FindFirstChild(name)
	if variant and variant:IsA("MaterialVariant") and variant.BaseMaterial == base then
		found[name] = true
		return name
	end
	return nil
end

-- Part colour that makes `texture`'s base layer show as `color`: color / reference per channel, capped at 1.
-- Unchanged when the texture has no reference.
function MaterialLibrary.tint(texture: string, color: Color3): Color3
	local entry = assets[texture]
	local reference = entry and entry.reference
	if not reference then
		return color
	end
	return Color3.new(
		math.min(1, color.R / math.max(reference.R, 1e-3)),
		math.min(1, color.G / math.max(reference.G, 1e-3)),
		math.min(1, color.B / math.max(reference.B, 1e-3))
	)
end

-- "rbxassetid://<id>" of one uploaded map of `texture` (default its ColorMap), or nil.
function MaterialLibrary.image(texture: string, map: MapKind?): string?
	local entry = assets[texture]
	if not entry then
		return nil
	end
	local kind: MapKind = map or "ColorMap"
	local id: number? = if kind == "ColorMap"
		then entry.ColorMap
		elseif kind == "NormalMap" then entry.NormalMap
		elseif kind == "RoughnessMap" then entry.RoughnessMap
		else entry.MetalnessMap
	if not id then
		return nil
	end
	return "rbxassetid://" .. tostring(id)
end

-- Lays the overlay `texture` (an alpha colour map) on `face` of `part` as a Texture repeating every studsU x
-- studsV studs, or returns nil (and adds nothing) when the overlay is not uploaded. Strip overlays (WallGrime:
-- damp rising from the bottom edge; RustStreaks: rust running down from the top edge) tile along U only: give
-- them a part, or a face, as tall as the strip and studsV = that height, so the strip shows exactly once.
function MaterialLibrary.overlay(
	part: BasePart,
	face: Enum.NormalId,
	texture: string,
	studsU: number,
	studsV: number,
	transparency: number?
): Texture?
	local image = MaterialLibrary.image(texture)
	if not image then
		return nil
	end
	local overlay = Instance.new("Texture")
	overlay.Name = "Overlay_" .. texture
	overlay.Face = face
	overlay.Texture = image
	overlay.StudsPerTileU = studsU
	overlay.StudsPerTileV = studsV
	overlay.Transparency = transparency or 0
	overlay.Parent = part
	return overlay
end

return table.freeze(MaterialLibrary)
