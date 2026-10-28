-- Executable checks that run outside Roblox (CI and machines without Studio).
--
--   lune run tools/lune/check.luau layouts      validate every level blueprint (overlaps, doors, ducts, solvability)
--   lune run tools/lune/check.luau world [out]  run the authoritative world build; report counts; optionally save an .rbxl
--   lune run tools/lune/check.luau specs        run tests/Specs through tests/SpecRunner
--   lune run tools/lune/check.luau lifecycle    boot the real ServerMain, then drive runs, levels and dev commands
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

-- Boots the real ServerMain (every service's Init / Start in ServerMain order), then drives the P1 server flow the
-- way a dev player does: runs on both difficulties, every level, dev commands through the DevCommand remote, the
-- ClientWorldReady ack, and run teardown. No physics and no characters (avatar builds need the engine).
local function runLifecycle(h)
	print("== lifecycle")
	local task = require("@lune/task")
	local game = h.game
	local RS = game:GetService("ReplicatedStorage")
	local Workspace = game:GetService("Workspace")
	local CollectionService = game:GetService("CollectionService")
	local Vector3 = roblox.Vector3

	local okBoot, bootErr = pcall(h.runScript, "ServerScriptService.ServerMain")
	if not okBoot then
		fail("ServerMain threw: %s", tostring(bootErr))
		return
	end
	local core = "ServerScriptService.Services.Core."
	local World = h.require(core .. "WorldService")
	local Lifecycle = h.require(core .. "RunLifecycleService")
	local LevelDirector = h.require(core .. "LevelDirector")
	local Noise = h.require(core .. "NoiseAndDirectorService")
	local Zone = h.require(core .. "ZoneService")
	local Character = h.require(core .. "CharacterService")
	local Audio = h.require(core .. "AudioService")
	local DevTools = h.require(core .. "DevToolsService")
	local Builder = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder")
	local Enums = h.require("ReplicatedStorage.Shared.Enums")

	local deadline = os.clock() + 120
	while not World.IsReady() and os.clock() < deadline do
		task.wait(0.05)
	end
	if not World.IsReady() then
		fail("the world never became ready")
		return
	end
	task.wait(0.2) -- RunLifecycleService.Start polls readiness
	if Lifecycle.GetPhase() ~= "Lobby" then
		fail("phase after boot is %s, expected Lobby", tostring(Lifecycle.GetPhase()))
	end
	local bootError = RS:GetAttribute("BootError")
	if bootError ~= nil then
		fail("BootError after boot: %s", tostring(bootError))
	end

	-- The loading curtain acks once it counts 97% of WorldPartCount BaseParts under School + Lobby.
	local counted = 0
	for _, name in { "School", "Lobby" } do
		local root = Workspace:FindFirstChild(name)
		if root then
			counted += Harness.countDescendants(root, function(d)
				return d:IsA("BasePart")
			end)
		else
			fail("Workspace.%s is missing", name)
		end
	end
	if counted ~= RS:GetAttribute("WorldPartCount") then
		fail("%d BaseParts under School + Lobby, WorldPartCount says %s", counted, tostring(RS:GetAttribute("WorldPartCount")))
	end

	-- Every spawn slot of every layout lands in that layout's entry room.
	for _, id in Enums.LayoutId do
		local layout = Builder.getLayout(id)
		for slot = 1, 4 do
			local cframe = Character.SpawnCFrame(id, slot)
			local zone = Zone.GetZoneAt(cframe.Position)
			if not (zone and zone:GetAttribute("ZoneId") == layout.entry and zone:GetAttribute("LevelId") == id) then
				fail("%s spawn slot %d (%s) is not in the entry room %s", id, slot, tostring(cframe.Position), layout.entry)
			end
		end
	end

	-- Remotes from a dev player.
	local player = roblox.Instance.new("Player")
	player.Name = "LifecycleProbe"
	player.UserId = 101
	player:SetAttribute("DevTools", true)
	local remotes = RS:FindFirstChild("Remotes")
	local function clientFires(remoteName, payload)
		local remote = remotes and remotes:FindFirstChild(remoteName)
		if not remote then
			fail("remote %s is missing", remoteName)
			return
		end
		local signal = h.signals["server:" .. remote.Name]
		if not signal then
			fail("nothing listens to %s", remoteName)
			return
		end
		signal:Fire(player, payload)
		task.wait()
	end
	local function lastNotify()
		for i = #h.fired, 1, -1 do
			local entry = h.fired[i]
			if entry.remote == "Notify" and entry.player == player then
				return entry.payload
			end
		end
		return nil
	end
	-- Commands run through DevToolsService.Execute (the DevCommand handler's body); the remote path itself is
	-- exercised once below, since Net rate-limits DevCommand to a burst of 6 at 2 per second.
	local function dev(command, args)
		local key, reply = DevTools.Execute(player, command, args or {})
		return key, reply[1]
	end

	clientFires("ClientWorldReady", { partCount = counted })
	if player:GetAttribute("WorldAcked") ~= true then
		fail("ClientWorldReady did not set WorldAcked")
	end
	-- Studio AutoDevRun: the first ack schedules a Standard dev run AutoRunDelay seconds later. Deploying builds every
	-- level's fixtures, so poll for InRun (up to 5 s past the delay) instead of betting on a fixed margin.
	task.wait(DevTools.AutoRunDelay)
	local deployDeadline = os.clock() + 5
	while Lifecycle.GetPhase() ~= "InRun" and os.clock() < deployDeadline do
		task.wait(0.05)
	end
	if Lifecycle.GetPhase() ~= "InRun" or RS:GetAttribute("DevRun") ~= true then
		fail("the Studio auto dev run did not start (phase %s)", tostring(Lifecycle.GetPhase()))
	end
	Lifecycle.EndRun()
	if RS:GetAttribute("DevRun") ~= false then
		fail("DevRun stayed set after the auto run ended")
	end
	clientFires("DevCommand", { command = "help", args = {} })
	local helpReply = lastNotify()
	if not (helpReply and helpReply.key == "Dev.Ok" and string.find(helpReply.args[1], "devrun", 1, true)) then
		fail("DevCommand over the remote did not answer on Notify")
	end
	clientFires("DevCommand", { command = 7, args = "bad" })
	if lastNotify() ~= helpReply then
		fail("a malformed DevCommand payload reached the handler")
	end

	for _, difficulty in { "Standard", "Nightmare" } do
		local key, reply = dev("devrun", { difficulty, "4242" })
		if key ~= "Dev.Ok" or Lifecycle.GetPhase() ~= "InRun" then
			fail("devrun %s: %s %s (phase %s)", difficulty, tostring(key), tostring(reply), tostring(Lifecycle.GetPhase()))
			continue
		end
		h.fireAttributeChanged(RS, "MatchPhase")
		task.wait()
		if RS:GetAttribute("Difficulty") ~= difficulty or RS:GetAttribute("RunSeed") ~= 4242 then
			fail("devrun %s did not publish its difficulty and seed", difficulty)
		end
		if RS:GetAttribute("CurrentLevel") ~= Enums.LevelId[1] or not LevelDirector.IsActive() then
			fail("devrun %s: Level0 is not the active level", difficulty)
		end
		local plan = Noise.GetPlan()
		if not plan then
			fail("devrun %s: no spawn plan", difficulty)
		else
			for _, prop in plan.props do
				local zone = Zone.GetZoneAt(prop.cframe.Position + Vector3.new(0, 0.5, 0))
				if not (zone and zone:GetAttribute("LevelId") == prop.levelId) then
					fail("%s %s at %s is outside its level's rooms", prop.kind, prop.anchorId, tostring(prop.cframe.Position))
				end
			end
		end
		for index, levelId in Enums.LevelId do
			local k = dev("level", { tostring(index - 1) })
			if k ~= "Dev.Ok" or RS:GetAttribute("CurrentLevel") ~= levelId or RS:GetAttribute("LevelPhase") ~= "Active" then
				fail("level %d did not activate %s", index - 1, levelId)
			end
			local before = #h.fired
			dev("plan")
			local sawPlan = false
			for i = before + 1, #h.fired do
				local entry = h.fired[i]
				if entry.remote == "DevOverlay" and entry.payload.kind == "Plan" then
					sawPlan = true
				end
			end
			if not sawPlan then
				fail("plan on %s sent no DevOverlay", levelId)
			end
			-- MonsterAIService: from Level 1 on, the Creature waits Dormant on the squad's level (ai reports it).
			if index >= 2 then
				local creature = CollectionService:GetTagged("Creature")[1]
				local _, mind = dev("ai")
				if
					not creature
					or creature:GetAttribute("LevelId") ~= levelId
					or creature:GetAttribute("MonsterState") ~= "Dormant"
					or not (mind and string.find(mind, levelId, 1, true))
				then
					fail("the Creature did not follow the squad to %s (ai: %s)", levelId, tostring(mind))
				end
			end
		end
		local _, last = dev("next")
		if last ~= "already on the last level" then
			fail("next on the roof replied %s", tostring(last))
		end
		-- A vent noise is tagged with the nearest VentNode of its level.
		for _, node in CollectionService:GetTagged("VentNode") do
			local position = (node.Parent.CFrame * node.CFrame).Position
			local event = Noise.Emit(position + Vector3.new(0.2, 0, 0), "VentScurry", { levelId = node:GetAttribute("LevelId") })
			if event.ventNodeId ~= node:GetAttribute("NodeId") then
				fail("vent noise at %s resolved to node %s", tostring(node:GetAttribute("NodeId")), tostring(event.ventNodeId))
			end
			break
		end
		local before = #h.fired
		Audio.PlayAt("GlassCrunch", Vector3.new(0, 5, 0))
		if not (h.fired[before + 1] and h.fired[before + 1].remote == "AudioCue") then
			fail("AudioService.PlayAt sent no AudioCue")
		end
		dev("endrun")
		if Lifecycle.GetPhase() ~= "Lobby" or RS:GetAttribute("RunId") ~= nil or RS:GetAttribute("CurrentLevel") ~= nil then
			fail("endrun left phase %s, RunId %s, CurrentLevel %s", tostring(Lifecycle.GetPhase()), tostring(RS:GetAttribute("RunId")), tostring(RS:GetAttribute("CurrentLevel")))
		end
		if Noise.GetPlan() ~= nil then
			fail("the spawn plan survived endrun")
		end
		local runtime = Workspace:FindFirstChild("Runtime")
		if runtime and #runtime:GetChildren() > 0 then
			fail("Workspace.Runtime was not cleared")
		end
		print(string.format("  ok   %s run: %d props planned, every level entered, torn down", difficulty, if plan then #plan.props else 0))
	end

	-- `level N` from the lobby starts a dev run there; non-dev players are refused.
	dev("level", { "5" })
	if Lifecycle.GetPhase() ~= "InRun" or RS:GetAttribute("CurrentLevel") ~= "Level5_Roof" then
		fail("level 5 from the lobby did not start a run on the roof")
	end
	dev("endrun")
	player:SetAttribute("DevTools", false)
	if (dev("devrun")) ~= "Dev.Denied" then
		fail("a player without DevTools was not refused")
	end
	for _, close in h.closeHandlers do
		close()
	end
	print("  ok   dev commands, remotes, acks and shutdown")
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
if command == "lifecycle" or command == "all" then
	runLifecycle(Harness.load(placePath, { server = true }))
end

if failures > 0 then
	print(string.format("%d failure(s)", failures))
	process.exit(1)
end
print("all checks passed")
