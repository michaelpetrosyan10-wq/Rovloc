-- Executable checks that run outside Roblox (CI and machines without Studio).
--
--   lune run tools/lune/check.luau layouts      validate every level blueprint (overlaps, doors, ducts, solvability)
--   lune run tools/lune/check.luau world [out]  run the authoritative world build; report counts; optionally save an .rbxl
--   lune run tools/lune/check.luau specs        run tests/Specs through tests/SpecRunner
--   lune run tools/lune/check.luau all          everything above
--
-- The place is built fresh with `rojo build` (test.project.json, so tests are included) before each run.

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Harness = require("./harness")

local LAYOUT_IDS = {
	"Lobby",
	"Level0_Basement",
	"Level1_Hallways",
	"Level2_ScienceHall",
	"Level3_Gymnasium",
	"Level4_FloodedPool",
	"Level5_Roof",
}

local command = process.args[1] or "all"
local tmpDir = process.env.TMPDIR or "/tmp"
local placePath = tmpDir .. "/rovloc-check.rbxl"

local project = if fs.isFile("test.project.json") then "test.project.json" else "default.project.json"
local build = process.exec("rojo", { "build", project, "-o", placePath })
if not build.ok then
	print(build.stderr)
	process.exit(2)
end

local failures = 0

local function fail(fmt, ...)
	failures += 1
	print("  FAIL " .. string.format(fmt, ...))
end

local function runLayouts(h)
	print("== layouts")
	local LayoutSchema = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema")
	for _, id in LAYOUT_IDS do
		local ok, layoutOrErr = pcall(h.require, "ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Layouts." .. id)
		if not ok then
			fail("%s failed to load: %s", id, tostring(layoutOrErr))
			continue
		end
		local errors = LayoutSchema.validate(layoutOrErr)
		if #errors == 0 then
			print(string.format("  ok   %s (%d rooms, %d doors, %d anchors)", id, #layoutOrErr.rooms, #layoutOrErr.doors, #layoutOrErr.anchors))
		else
			for _, message in errors do
				fail("%s: %s", id, message)
			end
		end
	end
end

local function runWorld(h, outPath)
	print("== world")
	local Builder = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder")
	local workspace = h.game:GetService("Workspace")
	local started = os.clock()
	local ok, result = pcall(Builder.BuildAuthoritative, { parent = workspace })
	if not ok then
		fail("BuildAuthoritative threw: %s", tostring(result))
		return
	end
	local parts = Harness.countDescendants(workspace, function(d)
		return d:IsA("BasePart")
	end)
	local lights = Harness.countDescendants(workspace, function(d)
		return d:IsA("Light")
	end)
	local nodes = {}
	local links = {}
	for _, d in workspace:GetDescendants() do
		if d:HasTag("VentNode") then
			local id = d:GetAttribute("NodeId")
			if type(id) ~= "string" then
				fail("VentNode %s has no NodeId", d:GetFullName())
			elseif nodes[id] then
				fail("duplicate VentNode id %s", id)
			else
				nodes[id] = d
				links[id] = {}
				for entry in string.gmatch(d:GetAttribute("Links") or "", "[^,]+") do
					links[id][entry] = true
				end
			end
		end
	end
	local nodeCount = 0
	for id, set in links do
		nodeCount += 1
		for other in set do
			if not links[other] then
				fail("VentNode %s links to missing node %s", id, other)
			elseif not links[other][id] then
				fail("VentNode link %s -> %s is not symmetric", id, other)
			end
		end
	end
	for _, d in workspace:GetDescendants() do
		if d:IsA("BasePart") and d.Anchored == false and not d:IsDescendantOf(workspace:FindFirstChild("Runtime") or workspace) then
			fail("unanchored world part %s", d:GetFullName())
		end
	end
	print(string.format("  built in %.2fs: %d parts, %d lights, %d vent nodes", os.clock() - started, parts, lights, nodeCount))
	for _, warning in h.warnings do
		print("  warn " .. warning)
	end
	if outPath then
		fs.writeFile(outPath, roblox.serializePlace(h.game))
		print("  saved " .. outPath)
	end
end

local function runSpecs(h)
	print("== specs")
	local okRunner, Runner = pcall(h.require, "ServerScriptService.Tests.SpecRunner")
	if not okRunner then
		fail("SpecRunner unavailable: %s", tostring(Runner))
		return
	end
	local specsFolder = h.path("ServerScriptService.Tests.Specs")
	local report = Runner.run(specsFolder, h.requireInstance)
	for _, line in report.lines do
		print("  " .. line)
	end
	failures += report.failed
end

if command == "layouts" or command == "all" then
	runLayouts(Harness.load(placePath, { server = true }))
end
if command == "world" or command == "all" then
	runWorld(Harness.load(placePath, { server = true }), process.args[2])
end
if command == "specs" or command == "all" then
	runSpecs(Harness.load(placePath, { server = true }))
end

if failures > 0 then
	print(string.format("%d failure(s)", failures))
	process.exit(1)
end
print("all checks passed")
