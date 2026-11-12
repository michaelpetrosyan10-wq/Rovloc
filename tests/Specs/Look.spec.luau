--!strict
-- Look (docs/design/game-spec-v2.md 5.1, 5.2): the school keeps its own colours in the dark. The player asked for two
-- things and this checks both. No black-and-white checkerboard anywhere: not in the palette, Finishes, SurfaceArt,
-- the texture set (TextureAssets, the MaterialVariants), the game's scripts, nor in the built world, where a
-- linoleum walkway carries at most one soft traffic lane and no floor is tiled in two tones. And the school is not all
-- gray: the surfaces named below keep a colour of their own, and the basement burns its amber a third short of full,
-- as bright as before, so its brick, pipes, concrete and steel are not one copper wash.

local MaterialService = game:GetService("MaterialService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Enums = require(ReplicatedStorage.Shared.Enums)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local TextureAssets = require(ReplicatedStorage.Shared.Config.TextureAssets)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Finishes = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Finishes)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local LightingMood = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LightingMood)
local MaterialLibrary = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.MaterialLibrary)
local Palette = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Palette)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local rgb = Color3.fromRGB

-- A surface counts as coloured from this HSV saturation up.
local COLOURED = 0.15

-- The surfaces that must keep a colour of their own, each with the hue range (degrees) its colour lives in.
type Coloured = { what: string, lo: number, hi: number }
local MUST_BE_COLOURED: { [string]: Coloured } = {
	Brick = { what = "the basement's and the facade's red brick", lo = 0, hi = 30 },
	PipeCopper = { what = "the copper branch pipes", lo = 15, hi = 40 },
	MetalRust = { what = "rusted steel", lo = 15, hi = 40 },
	WoodPanel = { what = "the wood panelling and workshop walls", lo = 15, hi = 40 },
	PlasterGreen = { what = "the hallways' green plaster", lo = 90, hi = 150 },
	TileGreen = { what = "the green glazed tile", lo = 90, hi = 150 },
	WainscotOxblood = { what = "the Hallways' oxblood corridor tile", lo = 0, hi = 20 },
	WainscotTeal = { what = "the Auditorium storey's teal corridor tile", lo = 160, hi = 200 },
	TileBlue = { what = "the blue pool and restroom tile", lo = 190, hi = 230 },
	Carpet = { what = "the wine-red carpet", lo = 340, hi = 360 },
	LinoleumBeige = { what = "the corridors' worn beige linoleum", lo = 30, hi = 60 },
}

-- Names that would lie about their colour: the all-gray pass's keys and the checkerboard's pale squares.
local RETIRED_KEYS = { "BlockGray", "PipeLead", "PlasterAsh", "WainscotSlate", "VinylGray", "CheckerLight" }

-- What a checkerboard leaves behind in source: its palette key, its texture, its painter and its planner.
local CHECKER_NAMES = { "CheckerLight", "CheckerTile", "SurfaceArt.checker", "checkerCounts", "MaxSquares" }

-- The basement's full amber before it was pulled back: the fixtures' colours (layout or shell colour pulled toward the
-- old cast by CastAmount), the boiler glow, and the film's grade, haze and decay.
local OLD_BULB_CAST = rgb(255, 160, 84)
local OLD_TUBE_CAST = rgb(236, 200, 136)
local SHELL_BULB = rgb(255, 196, 140) -- the tunnels' caged bulbs carry the shell's default colour
local ROOM_BULB = rgb(255, 190, 128) -- the basement layout's own bulbs
local TUBE = rgb(214, 232, 236)
local OLD_BOILER_GLOW = rgb(255, 112, 36)
local OLD_GRADE = rgb(255, 236, 214)
local OLD_HAZE = rgb(62, 50, 36)
local OLD_DECAY = rgb(34, 24, 14)
-- The share of its saturation the basement's amber keeps: two thirds (pulled back by a third).
local AMBER_KEPT = 2 / 3

local function hsv(c: Color3): (number, number)
	local hi = math.max(c.R, c.G, c.B)
	local lo = math.min(c.R, c.G, c.B)
	if hi <= 0 or hi == lo then
		return 0, 0
	end
	local d = hi - lo
	local h
	if hi == c.R then
		h = ((c.G - c.B) / d) % 6
	elseif hi == c.G then
		h = (c.B - c.R) / d + 2
	else
		h = (c.R - c.G) / d + 4
	end
	return h * 60, d / hi
end

-- Linear (Rec. 709) luminance of an sRGB colour: what the baked light the monster and the hide rules read sums.
local function luminance(c: Color3): number
	local function lin(x: number): number
		return if x <= 0.04045 then x / 12.92 else ((x + 0.055) / 1.055) ^ 2.4
	end
	return 0.2126 * lin(c.R) + 0.7152 * lin(c.G) + 0.0722 * lin(c.B)
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
	host.Name = "LookSpec"
	Builder.BuildAuthoritative({ parent = host :: Instance, layouts = table.clone(Enums.LayoutId), yieldEvery = 0 })
	cachedWorld = host
	return host
end

return {
	["the school is not all gray: its named surfaces keep their own colour"] = function(t: Expect)
		local problems: { string } = {}
		for key, rule in MUST_BE_COLOURED do
			if not Palette.has(key) then
				table.insert(problems, key .. " (" .. rule.what .. ") is missing")
				continue
			end
			local c = Palette.get(key).color
			local h, s = hsv(c)
			if s < COLOURED then
				table.insert(
					problems,
					string.format("%s %s (%s) is gray: saturation %.2f", key, rgbText(c), rule.what, s)
				)
			elseif h < rule.lo or h > rule.hi then
				table.insert(
					problems,
					string.format(
						"%s %s (%s): hue %.0f outside %d..%d",
						key,
						rgbText(c),
						rule.what,
						h,
						rule.lo,
						rule.hi
					)
				)
			end
		end
		report(t, problems, "surfaces that lost their colour")
		local coloured = 0
		for _, key in Palette.LayoutKeys do
			local _, s = hsv(Palette.get(key).color)
			if s >= COLOURED then
				coloured += 1
			end
		end
		t.truthy(
			coloured * 2 >= #Palette.LayoutKeys,
			string.format("%d of the %d layout keys are coloured (at least half)", coloured, #Palette.LayoutKeys)
		)
		for _, key in RETIRED_KEYS do
			t.falsy(Palette.has(key), key .. " is retired: its name would lie about the colour")
		end
	end,

	["the tunnel regions keep pipes of their own colour"] = function(t: Expect)
		local regions = 0
		for _, layout in Builder.layouts() do
			local tunnels = layout.tunnels
			if not tunnels then
				continue
			end
			local colouredPipes = 0
			for _, region in tunnels.regions do
				regions += 1
				local _, s = hsv(region.pipe)
				if s >= COLOURED then
					colouredPipes += 1
				end
			end
			t.truthy(
				colouredPipes * 2 > #tunnels.regions,
				string.format("%s: %d of %d regions run coloured pipe", layout.id, colouredPipes, #tunnels.regions)
			)
		end
		t.truthy(regions >= 10, string.format("%d regions checked", regions))
	end,

	["the basement burns its amber a third short of full, exactly as bright"] = function(t: Expect)
		local id = "Level0_Basement"
		local film = LightingMood.film(id)
		local rows: { { label: string, now: Color3, full: Color3 } } = {
			{
				label = "tunnel bulb",
				now = LightingMood.cast(id, "AnyRoom", "Bulb", SHELL_BULB),
				full = MathUtil.lerpColor(SHELL_BULB, OLD_BULB_CAST, LightingMood.CastAmount),
			},
			{
				label = "room bulb",
				now = LightingMood.cast(id, "AnyRoom", "Bulb", ROOM_BULB),
				full = MathUtil.lerpColor(ROOM_BULB, OLD_BULB_CAST, LightingMood.CastAmount),
			},
			{
				label = "tube",
				now = LightingMood.cast(id, "AnyRoom", "Fluorescent", TUBE),
				full = MathUtil.lerpColor(TUBE, OLD_TUBE_CAST, LightingMood.CastAmount),
			},
			{ label = "grade", now = LightingMood.grade(id), full = OLD_GRADE },
			{ label = "haze", now = film.hazeColor, full = OLD_HAZE },
			{ label = "decay", now = film.decay, full = OLD_DECAY },
		}
		for _, layout in Builder.layouts() do
			if layout.id ~= id then
				continue
			end
			for _, room in layout.rooms do
				local lights: { LayoutSchema.Light } = room.lights or {}
				for _, light in lights do
					if light.kind == "BoilerGlow" then
						local colour = light.color :: Color3
						table.insert(rows, { label = "boiler glow " .. light.id, now = colour, full = OLD_BOILER_GLOW })
					end
				end
			end
		end
		t.truthy(#rows > 6, "the basement's boiler glows are checked too")
		for _, row in rows do
			local hue, s = hsv(row.now)
			local fullHue, fullS = hsv(row.full)
			local label = "basement " .. row.label .. " " .. rgbText(row.now)
			t.truthy(row.now.R > row.now.B, label .. " is still warm")
			t.truthy(
				math.abs(hue - fullHue) <= 4,
				string.format("%s keeps the amber's hue (%.0f, was %.0f)", label, hue, fullHue)
			)
			t.truthy(
				math.abs(s / fullS - AMBER_KEPT) <= 0.05,
				string.format("%s keeps %.2f of the full amber's saturation (%.2f of %.2f)", label, s / fullS, s, fullS)
			)
			local ratio = luminance(row.now) / luminance(row.full)
			t.truthy(
				math.abs(ratio - 1) <= 0.01,
				string.format("%s is as bright as the full amber (%.3f of its luminance)", label, ratio)
			)
		end
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
			elseif d:IsA("SurfaceGui") and d.Name == "Finish" and d.Face == Enum.NormalId.Top then
				table.insert(problems, d:GetFullName() .. " paints a pattern over a floor")
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
		t.truthy(lanes > 0, string.format("the linoleum walkways wear %d traffic lanes", lanes))
	end,
}
