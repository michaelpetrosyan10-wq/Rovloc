--!strict
-- MaterialLibrary + Palette texturing: with TextureAssets empty every surface stays exactly as it was (plain
-- material, palette colour, no MaterialVariant); with textures uploaded the textured keys take their variant
-- (only when it is in MaterialService and matches the part's material) with the colour compensated for the map,
-- re-applying another key clears it, and overlays / images resolve. The shipped TextureAssets and the place's
-- MaterialService must agree.

local MaterialService = game:GetService("MaterialService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local MaterialLibrary = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.MaterialLibrary)
local Palette = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Palette)
local TextureAssets = require(ReplicatedStorage.Shared.Config.TextureAssets)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local PLASTER_REF = Color3.new(0.8, 0.77, 0.69)

-- A stand-in MaterialService holding the variants a filled TextureAssets would ship.
local function variantRoot(pairs: { { texture: string, base: Enum.Material } }): Folder
	local root = Instance.new("Folder")
	root.Name = "MaterialServiceStandIn"
	local folder = Instance.new("Folder")
	folder.Name = MaterialLibrary.Folder
	folder.Parent = root
	for _, pair in pairs do
		local variant = Instance.new("MaterialVariant")
		variant.Name = MaterialLibrary.variantName(pair.texture, pair.base)
		variant.BaseMaterial = pair.base
		variant.Parent = folder
	end
	return root
end

local filled: MaterialLibrary.Assets = {
	PaintedPlaster = { ColorMap = 101, NormalMap = 102, RoughnessMap = 103, reference = PLASTER_REF },
	RustedMetal = { ColorMap = 201, NormalMap = 202, MetalnessMap = 204, reference = Color3.new(0.74, 0.74, 0.72) },
	StainedConcrete = { NormalMap = 302 }, -- normal map up, colour map not yet: stays off
	WallGrime = { ColorMap = 901 },
}

-- Runs fn with the library on `assets` / `root` (restoring the shipped ones after) and no Geometry yields.
local function using(assets: MaterialLibrary.Assets, root: Instance, fn: () -> ())
	local previous = Geometry.getYieldEvery()
	Geometry.setYieldEvery(0)
	MaterialLibrary.use(assets, root)
	local failure: any = nil
	xpcall(fn, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end)
	MaterialLibrary.use()
	Geometry.setYieldEvery(previous)
	if failure ~= nil then
		error(failure, 0)
	end
end

local function withFilled(fn: () -> ())
	using(
		filled,
		variantRoot({
			{ texture = "PaintedPlaster", base = Enum.Material.Plaster },
			{ texture = "RustedMetal", base = Enum.Material.CorrodedMetal },
			{ texture = "RustedMetal", base = Enum.Material.Metal },
			{ texture = "StainedConcrete", base = Enum.Material.Concrete },
		}),
		fn
	)
end

local function near3(t: Expect, actual: Color3, expected: Color3, message: string)
	t.near(actual.R, expected.R, 1e-4, message .. " (R)")
	t.near(actual.G, expected.G, 1e-4, message .. " (G)")
	t.near(actual.B, expected.B, 1e-4, message .. " (B)")
end

return {
	["empty TextureAssets: no key is textured and every part stays plain"] = function(t: Expect)
		using({}, MaterialService, function()
			for _, key in Palette.keys() do
				t.eq(Palette.variantFor(key), nil, key .. " has no variant")
				local entry = Palette.get(key)
				local part = Instance.new("Part")
				Palette.apply(part, key)
				t.eq(part.MaterialVariant, "", key .. ": no MaterialVariant")
				t.eq(part.Material, entry.material, key .. ": material untouched")
				near3(t, part.Color, entry.color, key .. ": palette colour untouched")
				near3(t, Palette.colorFor(key), entry.color, key .. ": colorFor is the palette colour")
			end
			local built =
				Geometry.part(Instance.new("Folder"), "Wall", CFrame.new(), Vector3.new(4, 10, 1), "PlasterSchool")
			t.eq(built.MaterialVariant, "", "Geometry parts stay plain")
			t.eq(MaterialLibrary.image("WallGrime"), nil, "no overlay image")
			t.eq(MaterialLibrary.overlay(built, Enum.NormalId.Front, "WallGrime", 8, 3), nil, "no overlay instance")
			t.eq(#built:GetChildren(), 0, "nothing added to the part")
		end)
	end,

	["the shipped TextureAssets and MaterialService agree"] = function(t: Expect)
		MaterialLibrary.use()
		local folder = MaterialService:FindFirstChild(MaterialLibrary.Folder)
		t.truthy(folder and folder:IsA("Folder"), "MaterialService holds the generated variants folder")
		local live = 0
		for _, key in Palette.keys() do
			local entry = Palette.get(key)
			if entry.variant and MaterialLibrary.has(entry.variant) then
				live += 1
				t.eq(
					Palette.variantFor(key),
					MaterialLibrary.variantName(entry.variant, entry.material),
					key .. ": an uploaded texture has its variant for the key's material in MaterialService"
				)
			else
				t.eq(Palette.variantFor(key), nil, key .. ": untextured")
			end
		end
		local count = 0
		for _, child in (folder and folder:GetChildren() or {}) :: { Instance } do
			count += 1
			t.truthy(child:IsA("MaterialVariant"), child.Name .. " is a MaterialVariant")
			if child:IsA("MaterialVariant") then
				local texture = string.match(child.Name, "^Rovloc(%w+)_%w+$")
				t.truthy(texture and MaterialLibrary.has(texture), child.Name .. " belongs to an uploaded texture")
				t.eq(
					child.Name,
					MaterialLibrary.variantName(texture or "", child.BaseMaterial),
					child.Name .. " is named after its base material"
				)
			end
		end
		t.truthy(count == 0 or live > 0, "variants ship only with uploaded textures")
		for texture, entry in TextureAssets do
			t.truthy(
				entry.ColorMap ~= nil or entry.reference == nil,
				texture .. ": a reference comes with a colour map"
			)
		end
	end,

	["filled TextureAssets: textured keys take their variant with the colour compensated"] = function(t: Expect)
		withFilled(function()
			local plaster = Palette.get("PlasterSchool")
			t.eq(Palette.variantFor("PlasterSchool"), "RovlocPaintedPlaster_Plaster", "plaster walls are dressed")
			t.eq(Palette.variantFor("PlasterGreen"), "RovlocPaintedPlaster_Plaster", "every key of the texture")
			t.eq(Palette.variantFor("MetalRust"), "RovlocRustedMetal_CorrodedMetal", "per base material: corroded")
			t.eq(Palette.variantFor("TrimMetal"), "RovlocRustedMetal_Metal", "per base material: metal")
			t.eq(Palette.variantFor("Concrete"), nil, "a normal map alone does not switch a texture on")
			t.eq(Palette.variantFor("Glass"), nil, "untextured keys stay plain")
			t.eq(Palette.variantFor("NoSuchKey"), nil, "unknown keys answer nil")

			local part = Instance.new("Part")
			Palette.apply(part, "PlasterSchool")
			t.eq(part.MaterialVariant, "RovlocPaintedPlaster_Plaster", "apply dresses the part")
			t.eq(part.Material, plaster.material, "in the key's own material")
			local expected = Color3.new(
				plaster.color.R / PLASTER_REF.R,
				plaster.color.G / PLASTER_REF.G,
				plaster.color.B / PLASTER_REF.B
			)
			near3(t, part.Color, expected, "colour = palette / reference")
			near3(t, Palette.colorFor("PlasterSchool"), expected, "colorFor agrees")

			Palette.apply(part, "Concrete")
			t.eq(part.MaterialVariant, "", "re-applying an untextured key clears the variant")
			near3(t, part.Color, Palette.get("Concrete").color, "and restores the plain colour")

			local folder = Instance.new("Folder")
			local wall = Geometry.part(folder, "Wall", CFrame.new(), Vector3.new(4, 10, 1), "PlasterSchool")
			t.eq(wall.MaterialVariant, "RovlocPaintedPlaster_Plaster", "Geometry dresses the parts it builds")
			local neon = Geometry.part(folder, "Glow", CFrame.new(), Vector3.one, "PlasterSchool", {
				material = Enum.Material.Neon,
			})
			t.eq(neon.MaterialVariant, "", "an overridden material is never dressed")
			local locker = Geometry.part(folder, "Locker", CFrame.new(), Vector3.one, "TrimMetal", {
				color = Color3.fromRGB(60, 80, 70),
			})
			t.eq(locker.MaterialVariant, "RovlocRustedMetal_Metal", "custom-coloured metal is dressed")
			near3(
				t,
				locker.Color,
				MaterialLibrary.tint("RustedMetal", Color3.fromRGB(60, 80, 70)),
				"its own colour is compensated"
			)
		end)
	end,

	["a variant missing from MaterialService or on another material leaves the part plain"] = function(t: Expect)
		using(filled, variantRoot({ { texture = "PaintedPlaster", base = Enum.Material.Concrete } }), function()
			t.eq(Palette.variantFor("PlasterSchool"), nil, "a variant for the wrong base material does not count")
			t.eq(Palette.variantFor("MetalRust"), nil, "no variant instance, no texture")
			local part = Instance.new("Part")
			Palette.apply(part, "MetalRust")
			t.eq(part.MaterialVariant, "", "the part stays plain")
		end)
	end,

	["tint caps at white and ignores textures without a reference"] = function(t: Expect)
		withFilled(function()
			near3(t, MaterialLibrary.tint("PaintedPlaster", Color3.new(1, 1, 1)), Color3.new(1, 1, 1), "never above 1")
			near3(
				t,
				MaterialLibrary.tint("WallGrime", Color3.new(0.2, 0.3, 0.4)),
				Color3.new(0.2, 0.3, 0.4),
				"no reference"
			)
			near3(t, MaterialLibrary.tint("Unknown", Color3.new(0.2, 0.3, 0.4)), Color3.new(0.2, 0.3, 0.4), "unknown")
		end)
	end,

	["images and overlays resolve once uploaded"] = function(t: Expect)
		withFilled(function()
			t.eq(MaterialLibrary.image("PaintedPlaster"), "rbxassetid://101", "default map is the colour map")
			t.eq(MaterialLibrary.image("PaintedPlaster", "RoughnessMap"), "rbxassetid://103", "named map")
			t.eq(MaterialLibrary.image("RustedMetal", "MetalnessMap"), "rbxassetid://204", "metalness")
			t.eq(MaterialLibrary.image("RustedMetal", "RoughnessMap"), nil, "a map not uploaded")
			t.eq(MaterialLibrary.image("FloorDirt"), nil, "a texture not uploaded")
			local part = Instance.new("Part")
			local overlay = MaterialLibrary.overlay(part, Enum.NormalId.Front, "WallGrime", 8, 2.5, 0.1)
			t.truthy(overlay ~= nil, "an uploaded overlay is laid")
			if overlay then
				t.eq(overlay.Parent, part, "on the part")
				t.eq(overlay.Face, Enum.NormalId.Front, "on the face asked for")
				t.eq(overlay.Texture, "rbxassetid://901", "showing the overlay image")
				t.near(overlay.StudsPerTileU, 8, 1e-6, "tiling along U")
				t.near(overlay.StudsPerTileV, 2.5, 1e-6, "one strip high")
				t.near(overlay.Transparency, 0.1, 1e-6, "transparency")
			end
			t.eq(
				MaterialLibrary.overlay(part, Enum.NormalId.Top, "FloorDirt", 8, 8),
				nil,
				"a missing overlay adds nothing"
			)
		end)
	end,
}
