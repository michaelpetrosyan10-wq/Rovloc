--!strict
-- Core services' pure logic. Collision: the highest mode on a character's stack wins (Normal < Vent < Locked), each
-- mode maps body parts and the VentCollider ball to the right groups, and Init lands the whole CollisionGroups
-- matrix in PhysicsService. Locks: the ControlLock shown is the highest-priority held reason and any Anchor lock
-- anchors. Avatars: layered clothing and head accessories are filtered out. Spawning: spawn slots sit on the entry
-- room's PlayerSpawn anchors and wrap sideways. Zones: point-in-box math, the per-level spatial hash, last-zone
-- preference and trigger-volume lookup. Lifecycle: the phase graph, seed normalization, level order, dev-command
-- parsing, and run-stat counters that survive EndRun until the next BeginRun.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local CollisionService = require(ServerScriptService.Services.Core.CollisionService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local ZoneService = require(ServerScriptService.Services.Core.ZoneService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local function box(name: string, cframe: CFrame, size: Vector3, levelId: string, tag: string): Part
	local part = Instance.new("Part")
	part.Name = name
	part.CFrame = cframe
	part.Size = size
	part:SetAttribute("LevelId", levelId)
	part:SetAttribute("ZoneId", name)
	part:AddTag(tag)
	return part
end

local function fakePlayer(userId: number): Player
	return ({ UserId = userId, Name = "CoreSpec" .. userId } :: any) :: Player
end

local function runContext(seed: number): Types.RunContext
	return {
		runId = "spec-" .. seed,
		seed = seed,
		difficulty = "Standard",
		participants = {},
		startedAt = Workspace:GetServerTimeNow(),
	}
end

return {
	["collision: the highest mode on the stack wins"] = function(t: Expect)
		t.eq(CollisionService.resolveMode({}), "Normal")
		t.eq(CollisionService.resolveMode({ crawl = "Vent" }), "Vent")
		t.eq(CollisionService.resolveMode({ crawl = "Vent", scare = "Locked" }), "Locked")
		t.eq(CollisionService.resolveMode({ base = "Normal", crawl = "Vent" }), "Vent")
		t.eq(CollisionService.resolveMode({ a = "Normal", b = "Normal" }), "Normal")
	end,

	["collision: each mode maps body parts and the vent collider"] = function(t: Expect)
		local function check(name: string, mode: Enums.CollisionMode, group: string, canCollide: boolean?)
			local actualGroup, actualCollide = CollisionService.groupFor(name, mode)
			t.eq(actualGroup, group, name .. " in " .. mode)
			t.eq(actualCollide, canCollide, name .. " CanCollide in " .. mode)
		end
		check("UpperTorso", "Normal", "Players", nil)
		check("UpperTorso", "Vent", "NoCollide", nil)
		check("UpperTorso", "Locked", "NoCollide", nil)
		check("VentCollider", "Normal", "NoCollide", false)
		check("VentCollider", "Vent", "VentCollider", true)
		check("VentCollider", "Locked", "NoCollide", false)
		-- In a duct only the ball touches the world, and nothing touches a locked character.
		t.truthy(CollisionGroups.collides((CollisionService.groupFor("VentCollider", "Vent")), "Default"))
		for _, group: CollisionGroups.GroupName in CollisionGroups.All do
			t.falsy(
				CollisionGroups.collides((CollisionService.groupFor("Head", "Locked")), group),
				"Locked vs " .. group
			)
		end
	end,

	["collision: Init applies the full matrix to PhysicsService"] = function(t: Expect)
		CollisionService.Init()
		local mismatches = CollisionService.VerifyMatrix()
		t.eq(#mismatches, 0, table.concat(mismatches, "; "))
	end,

	["collision: a character's parts follow its mode stack"] = function(t: Expect)
		local model = Instance.new("Model")
		local torso = Instance.new("Part")
		torso.Name = "UpperTorso"
		torso.Parent = model
		local ball = Instance.new("Part")
		ball.Name = CollisionService.VentColliderName
		ball.CanCollide = false
		ball.Parent = model

		CollisionService.TrackCharacter(model)
		t.eq(torso.CollisionGroup, "Players")
		t.eq(ball.CollisionGroup, "NoCollide")
		CollisionService.PushMode(model, "crawl", "Vent")
		t.eq(CollisionService.GetMode(model), "Vent")
		t.eq(torso.CollisionGroup, "NoCollide")
		t.eq(ball.CollisionGroup, "VentCollider")
		t.truthy(ball.CanCollide, "the ball collides in a duct")
		CollisionService.PushMode(model, "scare", "Locked")
		t.eq(ball.CollisionGroup, "NoCollide")
		t.falsy(ball.CanCollide)
		CollisionService.PopMode(model, "scare")
		t.eq(CollisionService.GetMode(model), "Vent", "a lock ending in a duct falls back to Vent")
		t.eq(ball.CollisionGroup, "VentCollider")
		CollisionService.PopMode(model, "crawl")
		t.eq(CollisionService.GetMode(model), "Normal")
		t.eq(torso.CollisionGroup, "Players")

		local group = Instance.new("Model")
		local a = Instance.new("Part")
		a.Parent = group
		CollisionService.ApplyGroup(group, "MonsterPassthrough")
		t.eq(a.CollisionGroup, "MonsterPassthrough")
		CollisionService.UntrackCharacter(model)
		t.falsy(CollisionService.IsTracked(model))
	end,

	["locks: the highest-priority reason shows and any Anchor lock anchors"] = function(t: Expect)
		local free = CharacterService.summarizeLocks({})
		t.eq(free.reason, "None")
		t.falsy(free.locked)
		t.falsy(free.anchored)

		local trapped = CharacterService.summarizeLocks({ Trap = { "Anchor" } })
		t.eq(trapped.reason, "Trap")
		t.truthy(trapped.locked)
		t.truthy(trapped.anchored)

		local scared = CharacterService.summarizeLocks({ Locker = { "Anchor" }, Jumpscare = { "Anchor" } })
		t.eq(scared.reason, "Jumpscare")

		local dragged = CharacterService.summarizeLocks({ Drag = { "ServerOwned" } })
		t.eq(dragged.reason, "Drag")
		t.truthy(dragged.locked)
		t.falsy(dragged.anchored, "ServerOwned keeps the root simulated")

		local mixed = CharacterService.summarizeLocks({ Drag = { "ServerOwned" }, Airlock = { "Anchor" } })
		t.eq(mixed.reason, "Drag")
		t.truthy(mixed.anchored)

		local released = CharacterService.summarizeLocks({ Trap = {} })
		t.eq(released.reason, "None", "empty stacks are released locks")
		t.falsy(released.locked)
	end,

	["locks: every reason has a priority, None lowest and Cutscene highest"] = function(t: Expect)
		local priority = CharacterService.LockPriority
		for _, reason: Enums.ControlLock in Enums.ControlLock do
			t.truthy(priority[reason] ~= nil, reason .. " has a priority")
			if reason ~= "None" then
				t.truthy(priority[reason] > priority.None, reason .. " outranks None")
			end
			if reason ~= "Cutscene" then
				t.truthy(priority.Cutscene > priority[reason], "Cutscene outranks " .. reason)
			end
		end
	end,

	["avatars: layered clothing and head accessories are removed"] = function(t: Expect)
		local entries: { CharacterService.AccessoryEntry } = {
			{ AssetId = 1, AccessoryType = Enum.AccessoryType.Hat, IsLayered = false },
			{ AssetId = 2, AccessoryType = Enum.AccessoryType.Hair, IsLayered = false },
			{ AssetId = 3, AccessoryType = Enum.AccessoryType.Back, IsLayered = false },
			{ AssetId = 4, AccessoryType = Enum.AccessoryType.Jacket, IsLayered = true },
			{ AssetId = 5, AccessoryType = Enum.AccessoryType.Waist, IsLayered = false },
			{ AssetId = 6, AccessoryType = Enum.AccessoryType.Face, IsLayered = false },
			{ AssetId = 7, AccessoryType = Enum.AccessoryType.Eyelash, IsLayered = false },
		}
		local kept = CharacterService.filterAccessories(entries, true, true)
		t.eq(#kept, 2)
		t.eq(kept[1].AssetId, 3)
		t.eq(kept[2].AssetId, 5)
		t.eq(#CharacterService.filterAccessories(entries, false, false), #entries)
		t.eq(#CharacterService.filterAccessories(entries, true, false), #entries - 1)
	end,

	["spawning: slots sit on the entry room's PlayerSpawn anchors"] = function(t: Expect)
		for _, layoutId: Enums.LayoutId in Enums.LayoutId do
			local layout = Builder.getLayout(layoutId)
			if not layout then
				t.fail("no layout " .. layoutId)
				return
			end
			local entry = LayoutSchema.indexRooms(layout)[layout.entry]
			t.truthy(entry, layoutId .. " entry room exists")
			local origin = WorldConfig.levelOrigin(layoutId)
			local seen: { [string]: boolean } = {}
			for slot = 1, 4 do
				local position = CharacterService.SpawnCFrame(layoutId, slot).Position
				local localPosition = position - origin
				t.truthy(
					LayoutSchema.rectContains(entry.rect, localPosition.X, localPosition.Z),
					string.format("%s slot %d lies in %s", layoutId, slot, layout.entry)
				)
				t.near(localPosition.Y, CharacterService.SpawnHeight, 0.01, layoutId .. " spawn height")
				local key = string.format("%.2f,%.2f", position.X, position.Z)
				t.falsy(seen[key], layoutId .. " slots are distinct")
				seen[key] = true
			end
		end
		local first = CharacterService.SpawnCFrame("Lobby", 1)
		local spawnCount = 0
		for _, anchor in (Builder.getLayout("Lobby") :: LayoutSchema.LevelLayout).anchors do
			if anchor.kind == "PlayerSpawn" and anchor.room == "Lobby_BoilerRoom" then
				spawnCount += 1
			end
		end
		local wrapped = CharacterService.SpawnCFrame("Lobby", spawnCount + 1)
		t.near((wrapped.Position - first.Position).Magnitude, WorldConfig.SpawnSpacing, 0.01, "slots wrap sideways")
	end,

	["zones: point-in-box handles rotation and edges"] = function(t: Expect)
		local size = Vector3.new(10, 4, 2)
		t.truthy(ZoneService.pointInBox(CFrame.new(), size, Vector3.new(5, 2, 1)), "corner is inside")
		t.falsy(ZoneService.pointInBox(CFrame.new(), size, Vector3.new(5.01, 0, 0)))
		local turned = CFrame.Angles(0, math.rad(90), 0)
		t.truthy(ZoneService.pointInBox(turned, size, Vector3.new(0, 0, 4.5)), "long axis turned onto Z")
		t.falsy(ZoneService.pointInBox(turned, size, Vector3.new(4.5, 0, 0)))
		local minX, minZ, maxX, maxZ = ZoneService.horizontalBounds(turned, size)
		t.near(minX, -1, 1e-6)
		t.near(maxX, 1, 1e-6)
		t.near(minZ, -5, 1e-6)
		t.near(maxZ, 5, 1e-6)
	end,

	["zones: the index finds rooms per level and prefers the last zone"] = function(t: Expect)
		local west = box("West", CFrame.new(10, 5, 10), Vector3.new(20, 10, 20), "Level0_Basement", Tags.Zone)
		local east = box("East", CFrame.new(30, 5, 10), Vector3.new(20, 10, 20), "Level0_Basement", Tags.Zone)
		local above = box("Above", CFrame.new(10, 25, 10), Vector3.new(20, 10, 20), "Level1_Hallways", Tags.Zone)
		local debris = box("Debris", CFrame.new(30, 1, 10), Vector3.new(4, 2, 4), "Level0_Basement", Tags.FloorDebris)
		local water = box("Water", CFrame.new(30, 1, 10), Vector3.new(8, 2, 8), "Level0_Basement", Tags.PoolWater)
		local index = ZoneService.buildIndex({ west, east, above }, { debris, water, west })

		t.eq(ZoneService.locate(index, Vector3.new(5, 3, 5), nil, nil), west)
		t.eq(ZoneService.locate(index, Vector3.new(35, 3, 5), nil, "Level0_Basement"), east)
		t.eq(
			ZoneService.locate(index, Vector3.new(5, 25, 5), nil, "Level0_Basement"),
			above,
			"falls back to other levels"
		)
		t.eq(ZoneService.locate(index, Vector3.new(5, 15, 5), nil, nil), nil, "the slab between levels is no room")
		t.eq(ZoneService.locate(index, Vector3.new(20, 3, 10), east, nil), east, "a shared wall keeps the last zone")
		t.eq(ZoneService.locate(index, Vector3.new(20, 3, 10), west, nil), west)
		t.eq(ZoneService.locate(index, Vector3.new(500, 3, 10), nil, nil), nil)

		local inside = ZoneService.volumesAt(index, { Vector3.new(30, 4, 10), Vector3.new(30, 0.5, 10) })
		t.eq(inside[debris], Tags.FloorDebris, "the feet point catches floor triggers")
		t.eq(inside[water], Tags.PoolWater)
		t.eq(inside[west], nil, "zones are not trigger volumes")
		local none = ZoneService.volumesAt(index, { Vector3.new(30, 4, 10) })
		t.eq(next(none), nil)
	end,

	["lifecycle: the phase graph allows exactly the match flow"] = function(t: Expect)
		local can = RunLifecycleService.canTransition
		t.truthy(can("Booting", "Lobby"))
		t.falsy(can("Booting", "InRun"))
		t.truthy(can("Lobby", "Deploying"), "dev runs skip the countdown")
		t.truthy(can("Countdown", "Lobby"), "a countdown can abort")
		t.truthy(can("Deploying", "InRun"))
		t.falsy(can("InRun", "Lobby"), "a run always resets before the lobby")
		t.truthy(can("InRun", "RunEnded"))
		t.truthy(can("RunEnded", "Results"))
		t.truthy(can("Results", "Resetting"))
		t.truthy(can("Resetting", "Lobby"))
		t.truthy(can("InRun", "InRun"))
		for _, start: Enums.MatchPhase in Enums.MatchPhase do
			local seen: { [string]: boolean } = { [start] = true }
			local frontier: { Enums.MatchPhase } = { start }
			while #frontier > 0 do
				local phase: Enums.MatchPhase = table.remove(frontier) :: Enums.MatchPhase
				for _, target: Enums.MatchPhase in Enums.MatchPhase do
					if not seen[target] and can(phase, target) then
						seen[target] = true
						table.insert(frontier, target)
					end
				end
			end
			t.truthy(seen.Lobby, start .. " reaches the lobby")
		end
	end,

	["lifecycle: seeds are positive integers"] = function(t: Expect)
		t.eq(RunLifecycleService.normalizeSeed(nil), nil)
		t.eq(RunLifecycleService.normalizeSeed(0 / 0), nil)
		t.eq(RunLifecycleService.normalizeSeed(math.huge), nil)
		t.eq(RunLifecycleService.normalizeSeed(42), 42)
		t.eq(RunLifecycleService.normalizeSeed(42.9), 42)
		for _, raw in { 0, -1, -42.5, 2 ^ 31, 2 ^ 40, 1 } do
			local seed = RunLifecycleService.normalizeSeed(raw) :: number
			t.truthy(seed >= 1 and seed <= 2147483646 and seed % 1 == 0, "seed from " .. tostring(raw))
		end
		local a = RunLifecycleService.seedFromEntropy("abc")
		t.eq(a, RunLifecycleService.seedFromEntropy("abc"), "deterministic")
		t.truthy(a ~= RunLifecycleService.seedFromEntropy("abd"))
		t.truthy(a >= 1 and a <= 2147483646)
	end,

	["levels: run order ends on the roof"] = function(t: Expect)
		local levelId: Enums.LevelId? = Enums.LevelId[1]
		local visited = 0
		while levelId do
			visited += 1
			t.eq(levelId, Enums.LevelId[visited])
			levelId = LevelDirector.nextLevel(levelId)
		end
		t.eq(visited, #Enums.LevelId)
		t.eq(LevelDirector.nextLevel("Level5_Roof"), nil)
	end,

	["dev tools: command arguments parse in any order and case"] = function(t: Expect)
		local default = DevToolsService.parseDevRunArgs({})
		t.eq(default.difficulty, "Standard")
		t.eq(default.seed, nil)
		local nightmare = DevToolsService.parseDevRunArgs({ "nightmare", "1234" })
		t.eq(nightmare.difficulty, "Nightmare")
		t.eq(nightmare.seed, 1234)
		local swapped = DevToolsService.parseDevRunArgs({ "77", "STANDARD" })
		t.eq(swapped.difficulty, "Standard")
		t.eq(swapped.seed, 77)

		t.eq(DevToolsService.parseLevel("0"), "Level0_Basement")
		t.eq(DevToolsService.parseLevel("5"), "Level5_Roof")
		t.eq(DevToolsService.parseLevel("6"), nil)
		t.eq(DevToolsService.parseLevel("-1"), nil)
		t.eq(DevToolsService.parseLevel("1.5"), nil)
		t.eq(DevToolsService.parseLevel("level2"), "Level2_ScienceHall")
		t.eq(DevToolsService.parseLevel("LEVEL4_FLOODEDPOOL"), "Level4_FloodedPool")
		t.eq(DevToolsService.parseLevel("pool"), nil)
		t.eq(DevToolsService.parseLevel(nil), nil)

		t.eq(DevToolsService.parseNoiseKind("sprint"), "Sprint")
		t.eq(DevToolsService.parseNoiseKind("GrateKick"), "GrateKick")
		t.eq(DevToolsService.parseNoiseKind("nope"), nil)
	end,

	["run stats: counters reset on BeginRun and survive EndRun"] = function(t: Expect)
		local player = fakePlayer(4242)
		RunStatsService.EndRun()
		RunStatsService.BeginRun(runContext(1))
		RunStatsService.Increment(player, "TrapsTriggered")
		RunStatsService.Increment(player, "TrapsTriggered", 3)
		RunStatsService.Increment(player, "VentsCrawled", 0 / 0)
		t.eq(RunStatsService.Get(player, "TrapsTriggered"), 4)
		t.eq(RunStatsService.Get(player, "VentsCrawled"), 0, "non-finite amounts are ignored")
		local snapshot = RunStatsService.Snapshot(player)
		for _, key: Enums.StatKey in Enums.StatKey do
			t.truthy(snapshot[key] ~= nil, "snapshot has " .. key)
		end
		t.eq(snapshot.TrapsTriggered, 4)

		RunStatsService.EndRun()
		t.falsy(RunStatsService.IsRunning())
		RunStatsService.Increment(player, "TrapsTriggered")
		t.eq(RunStatsService.Get(player, "TrapsTriggered"), 4, "kept (and frozen) after EndRun")
		t.truthy(RunStatsService.RunSeconds() >= 0)

		RunStatsService.BeginRun(runContext(2))
		t.eq(RunStatsService.Get(player, "TrapsTriggered"), 0, "a new run starts from zero")
		RunStatsService.EndRun()
	end,
}
