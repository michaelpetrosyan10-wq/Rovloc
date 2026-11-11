--!strict
-- WorldDeterminism: the shared world is built from Shared/Util/Rng only, so the web's export (Lune) and every live
-- Roblox server and client build the same maps, props and dressing from the same seeds. A lint over the source of
-- every module that builds or plans the world refuses the engine's Random, math.random, math.noise and the engine-
-- Random helpers (MathUtil.seededRandom / shuffle / noise1), clocks, GUIDs and spatial queries (the harness answers
-- those with nothing, so a builder using one would silently diverge), and the engine's Lerp and HSV methods: each
-- engine rounds those in float32 its own way (Lune's Color3:Lerp does not even return a channel lerped to its own
-- value), and one ulp flips a part colour on the 8-bit grid or a point onto the other side of a seam. World code uses
-- MathUtil's lerpColor / lerpVector2 / lerpVector3 / lerpCFrame / toHSV / fromHSV (Luau's doubles), checked here.
--
-- Scanned (every ModuleScript under each):
--   ReplicatedStorage.Shared.World       the world builder (ProceduralWorldBuilder: TunnelPlanner, TunnelRules, the
--                                        layouts, every builder and prop), RunDirector, Volumetrics
--   ReplicatedStorage.Shared.Vents       VentGraph, VentPathfinder
--   ReplicatedStorage.Shared.Config      the configs the builders read
--   ReplicatedStorage.Shared.Rules       the pure rules (Lives, Radar, Parkour, ...)
--   ReplicatedStorage.Shared.Util.Rng    the generator itself

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Rng = require(ReplicatedStorage.Shared.Util.Rng)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

-- What world code must never call, as Lua patterns over comment-free source.
local BANNED: { { pattern: string, why: string } } = {
	{ pattern = "%f[%w_]Random%s*%.%s*new%f[^%w_]", why = "the engine's Random (use Rng)" },
	{ pattern = "%f[%w_]math%s*%.%s*random%f[^%w_]", why = "math.random (use Rng)" },
	{ pattern = "%f[%w_]math%s*%.%s*randomseed%f[^%w_]", why = "math.randomseed (use Rng)" },
	{ pattern = "%f[%w_]math%s*%.%s*noise%f[^%w_]", why = "math.noise (engine-dependent float noise)" },
	{ pattern = "%f[%w_]seededRandom%f[^%w_]", why = "MathUtil.seededRandom (the engine's Random; use Rng.seeded)" },
	{
		pattern = "%f[%w_]MathUtil%s*%.%s*shuffle%f[^%w_]",
		why = "MathUtil.shuffle (the engine's Random; use Rng.shuffle)",
	},
	{ pattern = "%f[%w_]noise1%f[^%w_]", why = "MathUtil.noise1 (math.noise)" },
	{ pattern = "%f[%w_]os%s*%.%s*time%f[^%w_]", why = "os.time (a clock)" },
	{ pattern = "%f[%w_]tick%s*%(", why = "tick (a clock)" },
	{ pattern = "%f[%w_]DateTime%f[^%w_]", why = "DateTime (a clock)" },
	{ pattern = "GenerateGUID", why = "GUIDs" },
	{ pattern = ":%s*Raycast%s*%(", why = "Workspace:Raycast (the harness answers nothing)" },
	{ pattern = ":%s*Blockcast%s*%(", why = "Workspace:Blockcast (the harness answers nothing)" },
	{ pattern = ":%s*Spherecast%s*%(", why = "Workspace:Spherecast (the harness answers nothing)" },
	{ pattern = ":%s*Shapecast%s*%(", why = "Workspace:Shapecast (the harness answers nothing)" },
	{ pattern = ":%s*GetPartBoundsIn%a+%s*%(", why = "spatial queries (the harness answers nothing)" },
	{ pattern = ":%s*GetPartsInPart%s*%(", why = "spatial queries (the harness answers nothing)" },
	{ pattern = ":%s*[Ll]erp%s*%(", why = "the engine's Lerp (each engine rounds it its own way: MathUtil.lerp*)" },
	{ pattern = ":%s*ToHSV%s*%(", why = "Color3:ToHSV (the engine's float maths: MathUtil.toHSV)" },
	{
		pattern = "%f[%w_]Color3%s*%.%s*fromHSV%f[^%w_]",
		why = "Color3.fromHSV (the engine's float maths: MathUtil.fromHSV)",
	},
}

local SCANNED: { string } = { "World", "Vents", "Config", "Rules", "Util.Rng" }

-- `source` with comments and the contents of string literals blanked (newlines kept, so line numbers hold).
local function codeOnly(source: string): string
	local out: { string } = {}
	local i, n = 1, #source
	local function blank(text: string): string
		return (string.gsub(text, "[^\n]", " "))
	end
	while i <= n do
		local c = string.sub(source, i, i)
		if string.sub(source, i, i + 1) == "--" then
			local level = string.match(source, "^%[(=*)%[", i + 2)
			local stop: number
			if level then
				local close = string.find(source, "]" .. level .. "]", i + 4 + #level, true)
				stop = if close then close + #level + 1 else n
			else
				stop = (string.find(source, "\n", i, true) or n + 1) - 1
			end
			table.insert(out, blank(string.sub(source, i, stop)))
			i = stop + 1
		elseif c == '"' or c == "'" or c == "`" then
			local j = i + 1
			while j <= n do
				local d = string.sub(source, j, j)
				if d == "\\" then
					j += 2
				elseif d == c or d == "\n" then
					break
				else
					j += 1
				end
			end
			table.insert(out, c .. blank(string.sub(source, i + 1, j - 1)) .. c)
			i = j + 1
		elseif c == "[" and string.match(source, "^%[=*%[", i) then
			local level = string.match(source, "^%[(=*)%[", i) :: string
			local close = string.find(source, "]" .. level .. "]", i + 2 + #level, true)
			local stop = if close then close + #level + 1 else n
			table.insert(out, blank(string.sub(source, i, stop)))
			i = stop + 1
		else
			table.insert(out, c)
			i += 1
		end
	end
	return table.concat(out)
end

-- Every banned call in `source`: "line N: why".
local function violations(source: string): { string }
	local code = codeOnly(source)
	local out: { string } = {}
	for _, rule in BANNED do
		local start = 1
		while true do
			local first, last = string.find(code, rule.pattern, start)
			if not first then
				break
			end
			local _, lines = string.gsub(string.sub(code, 1, first), "\n", "")
			table.insert(out, string.format("line %d: %s", lines + 1, rule.why))
			start = (last :: number) + 1
		end
	end
	return out
end

local function scannedModules(): { ModuleScript }
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	assert(shared, "ReplicatedStorage.Shared")
	local out: { ModuleScript } = {}
	for _, path in SCANNED do
		local node: Instance = shared
		for segment in string.gmatch(path, "[^%.]+") do
			local nextNode = node:FindFirstChild(segment)
			assert(nextNode, "ReplicatedStorage.Shared." .. path)
			node = nextNode
		end
		if node:IsA("ModuleScript") then
			table.insert(out, node)
		end
		for _, d in node:GetDescendants() do
			if d:IsA("ModuleScript") then
				table.insert(out, d)
			end
		end
	end
	return out
end

return {
	["the lint sees through comments and strings, and catches every banned call"] = function(t: Expect)
		t.eq(#violations('-- Random.new(1) in a comment\nlocal s = "math.random()"\n'), 0, "comments and strings")
		t.eq(#violations("--[[ math.noise(1)\n Random.new() ]]\nlocal x = 1\n"), 0, "block comments")
		t.eq(#violations("local s = [[\nRandom.new(1)\n]]\n"), 0, "long strings")
		t.eq(#violations("local RandomName = 1\nlocal myRandom = MyRandom.new()\n"), 0, "other names")
		t.eq(
			#violations("local c = MathUtil.lerpColor(a, b, 0.5)\nlocal h, s, v = MathUtil.toHSV(c)\n"),
			0,
			"MathUtil's world maths"
		)
		t.eq(#violations("local back = MathUtil.fromHSV(h, s, v)\nlocal Lerped = 1\n"), 0, "MathUtil.fromHSV")
		local found = violations("local a = 1\nlocal r = Random.new(4)\nlocal n = math.noise(1, 2)\n")
		t.eq(#found, 2, "two banned calls")
		t.truthy(string.find(table.concat(found, ";"), "line 2", 1, true) ~= nil, "Random.new on line 2")
		t.truthy(string.find(table.concat(found, ";"), "line 3", 1, true) ~= nil, "math.noise on line 3")
		for _, line in
			{
				"local x = math.random(1, 2)",
				"local x = MathUtil.seededRandom(1, 'k')",
				"MathUtil.shuffle(list, r)",
				"local v = MathUtil.noise1(t, 3)",
				"local now = os.time()",
				"local now = tick()",
				"local g = HttpService:GenerateGUID(false)",
				"local hit = Workspace:Raycast(a, b)",
				"local parts = Workspace:GetPartBoundsInBox(cf, size)",
				"local d = DateTime.now()",
				"local c = paint:Lerp(GRIME, 0.5)",
				"local p = a : Lerp(b, t)",
				"local cf = CFrame.new():Lerp(goal, 0.25)",
				"local cf = from:lerp(goal, 0.25)",
				"local h, s, v = color:ToHSV()",
				"local c = Color3.fromHSV(0.1, 0.5, 0.5)",
			}
		do
			t.eq(#violations(line .. "\n"), 1, line)
		end
	end,

	["world modules draw from Rng and compute in Luau: no engine Random, noise, clocks, queries, Lerp, HSV"] = function(
		t: Expect
	)
		local modules = scannedModules()
		t.truthy(#modules >= 60, string.format("scanned %d world modules", #modules))
		local problems: { string } = {}
		for _, module in modules do
			local ok, source = pcall(function(): string
				return module.Source
			end)
			if not ok or source == "" then
				table.insert(
					problems,
					module:GetFullName() .. ": source unreadable here (the lint runs in Lune: tools/verify.sh)"
				)
				continue
			end
			for _, problem in violations(source) do
				table.insert(problems, module:GetFullName() .. " " .. problem)
			end
		end
		t.eq(#problems, 0, "\n  " .. table.concat(problems, "\n  "))
	end,

	["MathUtil's world maths: Luau's doubles, exact at both ends, the engine's results to float32"] = function(
		t: Expect
	)
		-- a channel lerped to its own value stays on it, and the reagent liquid's .5 tie (60 -> 30 at 0.35 is 49.5)
		-- rounds up as the exact value does (Lune's Color3:Lerp comes back at 49.4999970: 49)
		local jar, amber = Color3.fromRGB(97, 132, 60), Color3.fromRGB(97, 132, 30)
		local liquid = MathUtil.lerpColor(jar, amber, 0.35)
		t.eq(liquid.R, jar.R, "a channel lerped to its own value")
		t.eq(liquid.G, jar.G, "a channel lerped to its own value")
		t.eq(MathUtil.color8(liquid), Color3.fromRGB(97, 132, 50), "the tie rounds as the exact value does")
		-- the Tall Man's streak cut at the mouth slit (SLIT_Y -0.34): stored as float32 it lies just under the slit,
		-- as the exact value does (Lune's Vector2:Lerp lands just over it)
		local from, to = Vector2.new(0.151, -0.29), Vector2.new(0.146, -0.4)
		local cut = MathUtil.lerpVector2(from, to, (-0.34 - from.Y) / (to.Y - from.Y))
		t.truthy(cut.Y < -0.34 and cut.Y > -0.3400001, string.format("the slit cut at %.10f", cut.Y))

		local random = Rng.seeded(20251029, "WorldDeterminism:maths")
		local function angles(): CFrame
			local turn = 2 * math.pi
			return CFrame.Angles(random:NextNumber(0, turn), random:NextNumber(0, turn), random:NextNumber(0, turn))
		end
		local worstColor, worstVector, worstFrame, worstHSV = 0, 0, 0, 0
		for _ = 1, 400 do
			local a = Color3.new(random:NextNumber(), random:NextNumber(), random:NextNumber())
			local b = Color3.new(random:NextNumber(), random:NextNumber(), random:NextNumber())
			local f = random:NextNumber()
			t.eq(MathUtil.lerpColor(a, b, 0), a, "lerpColor at 0")
			t.eq(MathUtil.lerpColor(a, b, 1), b, "lerpColor at 1")
			local mine, engine = MathUtil.lerpColor(a, b, f), a:Lerp(b, f)
			worstColor = math.max(worstColor, math.abs(mine.R - engine.R), math.abs(mine.G - engine.G))
			worstColor = math.max(worstColor, math.abs(mine.B - engine.B))

			local p = Vector3.new(random:NextNumber(-50, 50), random:NextNumber(-50, 50), random:NextNumber(-50, 50))
			local q = Vector3.new(random:NextNumber(-50, 50), random:NextNumber(-50, 50), random:NextNumber(-50, 50))
			t.eq(MathUtil.lerpVector3(p, q, 0), p, "lerpVector3 at 0")
			t.eq(MathUtil.lerpVector3(p, q, 1), q, "lerpVector3 at 1")
			worstVector = math.max(worstVector, (MathUtil.lerpVector3(p, q, f) - p:Lerp(q, f)).Magnitude)
			local p2, q2 = Vector2.new(p.X, p.Y), Vector2.new(q.X, q.Z)
			t.eq(MathUtil.lerpVector2(p2, q2, 1), q2, "lerpVector2 at 1")
			worstVector = math.max(worstVector, (MathUtil.lerpVector2(p2, q2, f) - p2:Lerp(q2, f)).Magnitude)

			local ca, cb = CFrame.new(p) * angles(), CFrame.new(q) * angles()
			t.eq(MathUtil.lerpCFrame(ca, cb, 0), ca, "lerpCFrame at 0")
			t.eq(MathUtil.lerpCFrame(ca, cb, 1), cb, "lerpCFrame at 1")
			local mineFrame, engineFrame = MathUtil.lerpCFrame(ca, cb, f), ca:Lerp(cb, f)
			local mc, ec = { mineFrame:GetComponents() }, { engineFrame:GetComponents() }
			for i = 1, 12 do
				worstFrame = math.max(worstFrame, math.abs(mc[i] - ec[i]) / (if i <= 3 then 50 else 1))
			end

			local h, sat, v = MathUtil.toHSV(a)
			local eh, es, ev = a:ToHSV()
			worstHSV = math.max(worstHSV, math.abs(h - eh), math.abs(sat - es), math.abs(v - ev))
			local back, engineBack = MathUtil.fromHSV(h, sat, v), Color3.fromHSV(eh, es, ev)
			worstHSV = math.max(worstHSV, math.abs(back.R - a.R), math.abs(back.G - a.G), math.abs(back.B - a.B))
			worstHSV = math.max(worstHSV, math.abs(engineBack.R - back.R), math.abs(engineBack.B - back.B))
		end
		t.truthy(worstColor < 1e-6, string.format("lerpColor is Color3:Lerp to float32 (%.2e)", worstColor))
		t.truthy(worstVector < 1e-4, string.format("lerpVector2 / 3 are the engine's to float32 (%.2e)", worstVector))
		t.truthy(worstFrame < 1e-5, string.format("lerpCFrame is CFrame:Lerp to float32 (%.2e)", worstFrame))
		t.truthy(worstHSV < 1e-5, string.format("toHSV / fromHSV are the engine's to float32 (%.2e)", worstHSV))

		-- slerp: half of a quarter turn is an eighth, about the same axis; the shorter arc either way round
		local half = MathUtil.lerpCFrame(CFrame.new(), CFrame.Angles(0, math.rad(90), 0), 0.5)
		local axis, angle = half:ToAxisAngle()
		t.near(math.abs(angle), math.rad(45), 1e-5, "half a quarter turn")
		t.truthy(math.abs(axis.Y) > 0.99999, "about the same axis")
		local back = MathUtil.lerpCFrame(CFrame.Angles(0, math.rad(170), 0), CFrame.Angles(0, math.rad(-170), 0), 0.5)
		t.truthy(math.abs(back.LookVector.Z - 1) < 1e-5, "through 180 degrees, the 20-degree way round")
		-- HSV: the primaries, a grey (hue 0) and a hue past 1 wrapping round
		local r, g, b = MathUtil.toHSV(Color3.new(1, 0, 0))
		t.eq(r, 0, "red's hue")
		t.eq(g, 1, "red's saturation")
		t.eq(b, 1, "red's value")
		local gh, gs, gv = MathUtil.toHSV(Color3.new(0.5, 0.5, 0.5))
		t.eq(gh, 0, "a grey's hue")
		t.eq(gs, 0, "a grey's saturation")
		t.eq(gv, 0.5, "a grey's value")
		t.eq(MathUtil.fromHSV(0.5, 1, 1), Color3.new(0, 1, 1), "cyan")
		t.eq(MathUtil.fromHSV(1.5, 1, 1), Color3.new(0, 1, 1), "a hue past 1 wraps round")
		t.eq(MathUtil.fromHSV(-0.5, 1, 1), Color3.new(0, 1, 1), "a hue under 0 wraps round")
		t.eq(MathUtil.fromHSV(0, 0, 0.25), Color3.new(0.25, 0.25, 0.25), "no saturation: a grey")
	end,
}
