--!strict
-- GrayLook (docs/design/game-spec-v2.md 5.1, 5.2): every stage is dark, cold and gray. No palette key is more
-- saturated than 0.25 except the few colours that do a job (named below, each with its reason); the keys 5.2 names
-- carry its colours and the warm keys it replaced are gone; every LightingMood colour (casts, grades, haze, decay,
-- moonlight, the Roblox fills) is a cold gray and every film drains to -0.35 or below; the tunnel regions' mains are
-- dark iron told apart by a band of their old hue. No black-and-white checkerboard survives anywhere: not in the
-- palette, Finishes, SurfaceArt, the texture set (TextureAssets, the MaterialVariants), the game's scripts, nor in the
-- built world, where a vinyl walkway carries at most one soft traffic lane.

local MaterialService = game:GetService("MaterialService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Enums = require(ReplicatedStorage.Shared.Enums)
local TextureAssets = require(ReplicatedStorage.Shared.Config.TextureAssets)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Finishes = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Finishes)
local LightingMood = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LightingMood)
local MaterialLibrary = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.MaterialLibrary)
local Palette = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Palette)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

-- The rule of 5.1: no key a school layout uses is more saturated than this.
local MAX_SATURATION = 0.25
-- Every film drains at least this much (5.2 "Film").
local FILM_SATURATION = -0.35

-- The colours that keep their colour because they do a job (5.1: guidance stays readable).
local ACCENTS: { [string]: string } = {
	HazardYellow = "the striped hazard plates either side of every fire door and the gate",
	Ember = "the boiler's blue pilot flame: a light, not a surface",
	BusPaint = "the lobby's school bus, the landmark the squad boards (no stage)",
}

local rgb = Color3.fromRGB

-- 5.2's new colours, key by key.
local STAGE_COLOURS: { [string]: Color3 } = {
	BlockGray = rgb(70, 72, 74),
	ConcreteStained = rgb(68, 70, 72),
	PipeLead = rgb(84, 86, 88),
	MetalRust = rgb(76, 74, 72),
	WoodPanel = rgb(62, 60, 58),
	VinylGray = rgb(88, 90, 92),
	PlasterAsh = rgb(104, 106, 108),
	WainscotSlate = rgb(58, 62, 66),
	ClassroomVCT = rgb(110, 112, 112),
}

-- The keys the gray look replaced or retired.
local RETIRED_KEYS = { "Brick", "PipeCopper", "PlasterGreen", "WainscotOxblood", "WainscotTeal", "CheckerLight" }

-- What a checkerboard leaves behind in source: its palette key, its texture, its painter and its planner.
local CHECKER_NAMES = { "CheckerLight", "CheckerTile", "SurfaceArt.checker", "checkerCounts", "MaxSquares" }

-- The dark iron of every tunnel main (5.2 Basement).
local DARK_IRON = rgb(58, 60, 62)

local function saturation(c: Color3): number
	local hi = math.max(c.R, c.G, c.B)
	if hi <= 0 then
		return 0
	end
	return (hi - math.min(c.R, c.G, c.B)) / hi
end

local function rgbText(c: Color3): string
	return string.format("(%d, %d, %d)", math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255))
end

local function report(t: Expect, problems: { string }, what: string)
	t.eq(#problems, 0, what .. ":\n  " .. table.concat(problems, "\n  "))
end

-- Every module and script of the game (the specs and their runner are left out: they name what they check).
local function gameScripts(): { LuaSourceContainer }
	local tests = ServerScriptService:FindFirstChild("Tests")
	local out: { LuaSourceContainer } = {}
	for _, root: Instance in { ReplicatedFirst, ReplicatedStorage, ServerScriptService, StarterGui, StarterPlayer } do
		for _, d in root:GetDescendants() do
			if d:IsA("LuaSourceContainer") and not (tests and d:IsDescendantOf(tests)) then
				table.insert(out, d)
			end
		end
	end
	return out
end

-- A script's code: TextureAssets' upload log (the Textures workflow's history of every map it ever uploaded, kept in
-- a comment after the module returns) is history, not a reference, so it is left out.
local function codeOf(container: LuaSourceContainer): string?
	local ok, source = pcall(function(): string
		return (container :: any).Source
	end)
	if not ok or type(source) ~= "string" or source == "" then
		return nil
	end
	local log = string.find(source, "--[==[ upload-log", 1, true)
	return if log then string.sub(source, 1, log - 1) else source
end

local cachedWorld: Instance? = nil

-- Every layout's world (shell, finishes, static props), built once, detached.
local function world(): Instance
	local existing = cachedWorld
	if existing then
		return existing
	end
	local host = Instance.new("Model")
	host.Name = "GrayLookSpec"
	Builder.BuildAuthoritative({ parent = host :: Instance, layouts = table.clone(Enums.LayoutId), yieldEvery = 0 })
	cachedWorld = host
	return host
end

return {
	["every palette key is a cold gray, the named accents aside"] = function(t: Expect)
		local problems: { string } = {}
		for _, key in Palette.keys() do
			local c = Palette.get(key).color
			if ACCENTS[key] == nil and saturation(c) > MAX_SATURATION + 1e-6 then
				table.insert(problems, string.format("%s %s saturation %.2f", key, rgbText(c), saturation(c)))
			end
		end
		report(t, problems, "palette keys above the gray look's saturation")
		for key, reason in ACCENTS do
			t.truthy(Palette.has(key), key .. " is an accent the palette still has (" .. reason .. ")")
			t.truthy(saturation(Palette.get(key).color) > MAX_SATURATION, key .. " still needs its exemption")
		end
		for _, key in Palette.LayoutKeys do
			t.falsy(ACCENTS[key], key .. ": no key a layout names is exempt")
		end
	end,

	["5.2's surfaces carry its colours and the warm keys they replaced are gone"] = function(t: Expect)
		for key, colour in STAGE_COLOURS do
			t.truthy(Palette.has(key), key .. " exists")
			t.eq(rgbText(Palette.get(key).color), rgbText(colour), key)
		end
		for _, key in RETIRED_KEYS do
			t.falsy(Palette.has(key), key .. " is retired")
		end
		t.eq(Palette.get("BlockGray").material, Enum.Material.Brick, "painted block keeps its courses")
		t.eq(Palette.get("Ember").color, rgb(120, 170, 255), "the boiler burns a blue pilot flame")
	end,

	["every LightingMood colour is a cold gray and every film drains to the gray look"] = function(t: Expect)
		local problems: { string } = {}
		local function check(label: string, c: Color3?)
			if not c then
				return
			end
			if saturation(c) > MAX_SATURATION + 1e-6 then
				table.insert(problems, string.format("%s %s saturation %.2f", label, rgbText(c), saturation(c)))
			end
			if c.R > c.B + 1e-6 then
				table.insert(problems, string.format("%s %s is warm", label, rgbText(c)))
			end
		end
		local places: { { id: string? } } = { { id = nil } }
		for _, layout in Builder.layouts() do
			local id: string = layout.id
			table.insert(places, { id = id })
			local mood = LightingMood.levelMood(id)
			check(id .. " cast", mood.cast)
			check(id .. " bulbCast", mood.bulbCast)
			check(id .. " grade", mood.grade)
		end
		for _, place in places do
			local id = place.id
			local label = id or "outdoors"
			local film = LightingMood.film(id)
			check(label .. " haze", film.hazeColor)
			check(label .. " decay", film.decay)
			t.truthy(
				film.saturation <= FILM_SATURATION,
				string.format("%s film saturation %.2f", label, film.saturation)
			)
			local render = LightingMood.render(id)
			check(label .. " render tint", render.tint)
			check(label .. " render ambient", render.ambient)
			check(label .. " render outdoor ambient", render.outdoorAmbient)
		end
		check("base film haze", LightingMood.BaseFilm.hazeColor)
		check("base film decay", LightingMood.BaseFilm.decay)
		check("moonlight", LightingMood.Moonlight.color)
		report(t, problems, "LightingMood colours that are not a cold gray")
	end,

	["the tunnel regions' mains are dark iron, told apart by a band of their old hue"] = function(t: Expect)
		local regions = 0
		for _, layout in Builder.layouts() do
			local tunnels = layout.tunnels
			if not tunnels then
				continue
			end
			for _, region in tunnels.regions do
				regions += 1
				local label = layout.id .. " " .. region.id
				t.eq(rgbText(region.pipe), rgbText(DARK_IRON), label .. " main")
				t.truthy(saturation(region.band) <= 0.3 + 0.01, label .. " band at 30 % saturation at most")
				t.truthy(saturation(region.grime) <= MAX_SATURATION, label .. " grime is gray")
			end
		end
		t.truthy(regions >= 10, string.format("%d regions checked", regions))
	end,

	["no checkerboard in the palette, the finishes, the texture set or the game's scripts"] = function(t: Expect)
		t.eq(TextureAssets.CheckerTile, nil, "no CheckerTile texture is live")
		t.falsy(MaterialLibrary.has("CheckerTile"), "nor known to the library")
		local folder = MaterialService:FindFirstChild(MaterialLibrary.Folder)
		assert(folder, "the generated MaterialVariants are in MaterialService")
		for _, variant in folder:GetChildren() do
			t.falsy(string.find(variant.Name, "Checker", 1, true), variant.Name .. " is no checker texture")
		end
		t.eq((Finishes :: any).checkerCounts, nil, "Finishes plans no checker")
		local problems: { string } = {}
		local scripts = gameScripts()
		t.truthy(#scripts >= 200, string.format("scanned %d scripts", #scripts))
		for _, container in scripts do
			local code = codeOf(container)
			if not code then
				table.insert(problems, container:GetFullName() .. ": source unreadable here (tools/verify.sh runs it)")
				continue
			end
			for _, name in CHECKER_NAMES do
				if string.find(code, name, 1, true) then
					table.insert(problems, container:GetFullName() .. " names " .. name)
				end
			end
		end
		report(t, problems, "checkerboards left in the game's scripts")
	end,

	["the built world has no checkerboard: a floor carries at most one soft traffic lane"] = function(t: Expect)
		local problems: { string } = {}
		local lanes = 0
		for _, d in world():GetDescendants() do
			if string.find(d.Name, "Checker", 1, true) then
				table.insert(problems, d:GetFullName() .. " is named for a checker")
			end
			if d:IsA("BasePart") and string.find(d.MaterialVariant, "Checker", 1, true) then
				table.insert(problems, d:GetFullName() .. " wears " .. d.MaterialVariant)
			elseif d:IsA("Frame") and d.Name == "Square" then
				table.insert(problems, d:GetFullName() .. " is a checker square")
			elseif d:IsA("SurfaceGui") and d.Name == "Lane" then
				lanes += 1
				local frames = 0
				for _, item in d:GetDescendants() do
					if item:IsA("Frame") then
						frames += 1
					end
				end
				if frames ~= 1 or d.Face ~= Enum.NormalId.Top then
					table.insert(problems, string.format("%s: %d frames on %s", d:GetFullName(), frames, d.Face.Name))
				end
			end
		end
		report(t, problems, "checkerboards in the built world")
		t.truthy(lanes > 0, string.format("the vinyl walkways wear %d traffic lanes", lanes))
	end,
}
