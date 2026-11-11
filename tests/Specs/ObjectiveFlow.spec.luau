--!strict
-- ObjectiveFlow: the floor objectives played through ObjectiveService on the real fixtures of each floor, driven the
-- way players drive them (its InteractionService handlers: filter, canUse, onBegin, onCancel, onComplete), on a fake
-- clock: every floor's steps, its exit Locked before and Open after (ExitOpen gates the airlock), the Auditorium
-- storey's open exit and its step done on leaving, carried items dropped on death and on leaving and taken on by a
-- teammate. Plus the pure pieces: ObjectiveState's encodings and tracker lines, the working-hold maths and the
-- Creature's spawn rule on every level (SpawnRule: the walking band, the entry's sight, the objective rooms).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Net = require(ReplicatedStorage.Shared.Net)
local NoiseConfig = require(ReplicatedStorage.Shared.Config.NoiseConfig)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local ObjectiveState = require(ReplicatedStorage.Shared.Util.ObjectiveState)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local RunDirector = require(ReplicatedStorage.Shared.World.RunDirector)

local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local ChemicalProjectileService = require(ServerScriptService.Services.Mechanics.ChemicalProjectileService)
local DoorService = require(ServerScriptService.Services.Mechanics.DoorService)
local HideSpotService = require(ServerScriptService.Services.Mechanics.HideSpotService)
local ObjectiveService = require(ServerScriptService.Services.Levels.ObjectiveService)
local SpawnRule = require(ServerScriptService.Services.Monster.MonsterAIService.SpawnRule)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local ZoneGraph = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph)

type Expect = SpecRunner.Expect

type World = {
	levelId: Enums.LevelId,
	folder: Folder,
	now: number,
	players: { Player },
	unlocked: { string },
	door: Model?, -- the exit fire door (found while its lock still hangs on it)
}

local W = Attributes.World
local P = Attributes.Player
local M = Attributes.Match
local T = ObjectiveConfig.Tuning
local SEED = 4242
local START = 5000
local EPS = 1e-6

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function quiet<R>(fn: () -> R): R
	local previous = Geometry.getYieldEvery()
	Geometry.setYieldEvery(0)
	local ok, result = pcall(fn)
	Geometry.setYieldEvery(previous)
	if not ok then
		error(result, 0)
	end
	return result
end

local nextUserId = 9400

local function fakePlayer(): Player
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "ObjectiveSpec" .. nextUserId
	local writable = player :: any
	writable.UserId = nextUserId
	local model = Instance.new("Model")
	model.Name = player.Name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = CFrame.new(0, 3, 0)
	root.Position = Vector3.new(0, 3, 0)
	root.Parent = model
	model.PrimaryPart = root
	local humanoid = Instance.new("Humanoid")
	humanoid.HipHeight = 2
	humanoid.MaxHealth = GameConfig.MaxHealth
	humanoid.Health = GameConfig.MaxHealth
	humanoid.Parent = model
	player.Character = model
	return player
end

local function spec(levelId: string): ObjectiveConfig.FloorSpec
	local found = ObjectiveConfig.forLevel(levelId)
	assert(found, levelId .. " has an objective")
	return found
end

-- Each level's shell, built once for this spec and kept out of the Workspace between tests (later specs expect a
-- Workspace without a school).
local shells: { [string]: { Instance } } = {}

local function showShell(levelId: Enums.LevelId, shown: boolean)
	local built = shells[levelId]
	if not built then
		local made: { Instance } = {}
		local result: any = quiet(function(): any
			return Builder.BuildAuthoritative({ layouts = { levelId }, yieldEvery = 0 })
		end)
		for _, key in { "school", "lobby" } do
			local instance = result[key]
			if typeof(instance) == "Instance" then
				table.insert(made, instance)
			end
		end
		shells[levelId] = made
		built = made
	end
	for _, instance in built do
		instance.Parent = if shown then game:GetService("Workspace") else nil
	end
end

-- Builds `levelId`'s fixtures and the run's picked items into Workspace.Runtime.<level>, the way WorldService does.
local function buildFloor(levelId: Enums.LevelId): Folder
	showShell(levelId, true)
	local folder = Instances.runtimeLevel(levelId, true) :: Folder
	local layout = Builder.getLayout(levelId)
	assert(layout, levelId .. " layout")
	local floor = spec(levelId)
	quiet(function()
		Builder.BuildFixtures(levelId, folder, nil)
		local item = floor.item
		if item then
			for _, anchor in RunDirector.pickObjective(SEED, layout, floor) do
				local plan: Types.PlannedProp = {
					kind = item.prop,
					anchorId = anchor.id,
					levelId = levelId,
					cframe = Builder.anchorCFrame(levelId, anchor),
					variant = 1,
				}
				Builder.BuildProp(plan, folder)
			end
		end
		return true
	end)
	return folder
end

local function inRun(levelId: Enums.LevelId, count: number, body: (world: World) -> ())
	Net.Server.setup()
	local folder = buildFloor(levelId)
	local players: { Player } = {}
	for _ = 1, count do
		table.insert(players, fakePlayer())
	end
	local ctx: Types.RunContext = {
		runId = "objective-flow-spec",
		seed = SEED,
		difficulty = "Standard",
		participants = players,
		startedAt = START,
	}
	local world: World = { levelId = levelId, folder = folder, now = START, players = players, unlocked = {} }
	ObjectiveService.Init()
	-- the engine's prompt events do not exist outside Roblox: the specs call the handlers themselves
	local refresh = InteractionService.Refresh
	InteractionService.Refresh = function(_host: Instance) end
	ObjectiveService.SetClock(function(): number
		return world.now
	end)
	local connection = ObjectiveService.Unlocked:Connect(function(id: Enums.LevelId, _actor: Player?)
		table.insert(world.unlocked, id)
	end)
	local failure: string? = nil
	xpcall(function()
		RunStatsService.BeginRun(ctx)
		PlayerStateService.BeginRun(ctx)
		LifeStateService.BeginRun(ctx)
		DoorService.Init()
		DoorService.BeginRun(ctx)
		HideSpotService.Init()
		HideSpotService.BeginRun(ctx)
		ChemicalProjectileService.Init()
		ChemicalProjectileService.BeginRun(ctx)
		ObjectiveService.BeginRun(ctx)
		local levelCtx: Types.LevelContext =
			{ levelId = levelId, run = ctx, root = Instance.new("Model"), runtime = folder }
		LevelDirector.LevelActivated:Fire(levelId, levelCtx)
		body(world)
	end, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end)
	connection:Disconnect()
	ObjectiveService.EndRun()
	ObjectiveService.SetClock(nil)
	ChemicalProjectileService.EndRun()
	HideSpotService.EndRun()
	DoorService.EndRun()
	LifeStateService.EndRun()
	PlayerStateService.EndRun()
	RunStatsService.EndRun()
	for _, player in players do
		ChemicalProjectileService.OnPlayerRemoving(player)
		HideSpotService.OnPlayerRemoving(player)
		LifeStateService.OnPlayerRemoving(player)
		PlayerStateService.OnPlayerRemoving(player)
	end
	folder:Destroy()
	showShell(levelId, false)
	InteractionService.Refresh = refresh
	if failure ~= nil then
		error(failure, 0)
	end
end

local function advance(world: World, seconds: number)
	local target = world.now + seconds
	while world.now < target - 1e-9 do
		world.now = math.min(target, world.now + 0.1)
		ObjectiveService.Step(world.now)
	end
end

local function tagged(tag: string, levelId: string, objectiveId: string?): { Model }
	local out: { Model } = {}
	for _, instance in game:GetService("CollectionService"):GetTagged(tag) do
		if
			instance:IsA("Model")
			and instance:GetAttribute(W.LevelId) == levelId
			and (objectiveId == nil or instance:GetAttribute(W.ObjectiveId) == objectiveId)
			and instance:IsDescendantOf(game:GetService("Workspace"))
		then
			table.insert(out, instance)
		end
	end
	return out
end

local function one(tag: string, levelId: string, objectiveId: string): Model
	local found = tagged(tag, levelId, objectiveId)[1]
	assert(found, levelId .. " has its " .. objectiveId)
	return found
end

local function promptOf(model: Instance, kind: Enums.PromptKind, slot: number?): ProximityPrompt
	for _, d in model:GetDescendants() do
		if d:IsA("ProximityPrompt") and d:GetAttribute(W.PromptKind) == kind then
			if slot == nil or d:GetAttribute(W.Slot) == slot then
				return d
			end
		end
	end
	error(model.Name .. " has no " .. kind .. " prompt")
end

local function serves(kind: Enums.PromptKind, host: Instance, prompt: ProximityPrompt): boolean
	local handler = ObjectiveService.Handlers[kind]
	local filter = handler.filter
	return filter ~= nil and filter(host, prompt)
end

-- One prompt used by `player` as InteractionService would: served, allowed, held for its BaseHold, completed.
local function use(
	t: Expect,
	world: World,
	player: Player,
	kind: Enums.PromptKind,
	host: Instance,
	prompt: ProximityPrompt,
	label: string
)
	local handler = ObjectiveService.Handlers[kind]
	t.truthy(serves(kind, host, prompt), label .. ": the prompt answers")
	local canUse = handler.canUse
	if canUse then
		local ok, reason = canUse(player, prompt, host)
		t.truthy(ok, label .. ": allowed (" .. tostring(reason) .. ")")
	end
	local hold = Attributes.getNumber(prompt, W.BaseHold, 0)
	local begin = handler.onBegin
	if hold > 0 and begin then
		begin(player, prompt, host)
		advance(world, hold)
	end
	handler.onComplete(player, prompt, host)
end

-- The floor's items, wherever they are (a carried one is not in the Workspace).
local function items(world: World): { Model }
	local out: { Model } = {}
	local item = spec(world.levelId).item
	if not item then
		return out
	end
	for _, instance in game:GetService("CollectionService"):GetTagged(Tags.ObjectiveItem) do
		if
			instance:IsA("Model")
			and instance:GetAttribute(W.LevelId) == world.levelId
			and instance:GetAttribute(W.ObjectiveId) == item.prop
		then
			table.insert(out, instance)
		end
	end
	return out
end

local function takeAll(t: Expect, world: World, player: Player)
	for _, item in items(world) do
		use(t, world, player, "Pickup", item, promptOf(item, "Pickup"), item.Name)
	end
end

local function exitDoor(world: World): Model
	local known = world.door
	if known then
		return known
	end
	local _, doors = ObjectiveService.GetExit(world.levelId)
	local door = doors[1]
	assert(door, "the route's exit door is tracked")
	world.door = door
	return door
end

-- The route's live exit lock (every exit candidate carries one; the jammed ones offer nothing).
local function exitLock(world: World): Model
	local lock = ObjectiveService.GetExit(world.levelId)
	assert(lock, world.levelId .. " has a live exit lock")
	return lock
end

local function progress(world: World): { [string]: number }
	local steps = ObjectiveService.GetFloor(world.levelId)
	return steps or {}
end

local function expectLocked(t: Expect, world: World)
	t.falsy(ObjectiveService.ExitOpen(world.levelId), "the exit is shut")
	t.eq(DoorService.GetState(exitDoor(world)), "Locked", "the exit fire door is Locked")
end

local function expectUnlocked(t: Expect, world: World)
	t.truthy(ObjectiveService.ExitOpen(world.levelId), "the exit opens")
	t.eq(world.unlocked[1], world.levelId, "Unlocked fires")
	advance(world, T.DoorDelay + 0.2)
	t.eq(DoorService.GetState(exitDoor(world)), "Open", "the exit fire door swings open")
	t.eq(ReplicatedStorage:GetAttribute(M.ObjectiveUnlocked), true, "the tracker is told")
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["state: steps and carry round-trip; tracker lines count and tick"] = function(t: Expect)
		local floor = spec("Level0_Basement")
		local encoded = ObjectiveState.encodeSteps(floor, { FindFuses = 2, FitFuses = 1 })
		t.eq(encoded, "FindFuses=2;FitFuses=1;ThrowBreaker=0")
		local decoded = ObjectiveState.decodeSteps(encoded)
		t.eq(decoded.FindFuses, 2)
		t.eq(decoded.ThrowBreaker, 0)
		local lines = ObjectiveState.stepLines(floor, { FindFuses = 3, FitFuses = 1 })
		t.eq(lines[1].text, "Fuses 3/3")
		t.truthy(lines[1].done, "found every fuse")
		t.truthy(lines[2].active and not lines[2].done, "fitting is the current step")
		t.eq(lines[2].text, "Fit the fuses 1/3")
		local reach = ObjectiveState.stepLines(spec("Level2_Auditorium"), {})
		t.eq(#reach, 1, "the Auditorium storey's one step")
		t.truthy(reach[1].active and not reach[1].done, "reaching the exit is the current step")
		local carry = ObjectiveState.encodeCarry({ "Fuse", "MasterKeys" }, { Fuse = 2, MasterKeys = 1 })
		t.eq(carry, "Fuse:2;MasterKeys:1")
		local entries = ObjectiveState.decodeCarry(carry)
		t.eq(#entries, 2)
		t.eq(ObjectiveState.carryLine(entries), "Carrying: Fuse ×2, Master keys")
		t.eq(ObjectiveState.carryLine({}), nil)
	end,

	["working holds: kept progress, the hold left, the drop spiral"] = function(t: Expect)
		t.near(ObjectiveService.workProgress(5, 2, nil, 10), 0.4, EPS, "kept progress")
		t.near(ObjectiveService.workProgress(5, 2, 9, 10), 0.6, EPS, "plus the running hold")
		t.eq(ObjectiveService.workProgress(5, 4, 0, 10), 1, "clamped")
		t.near(ObjectiveService.holdLeft(5, 2), 3, EPS)
		t.near(ObjectiveService.holdLeft(5, 5), 0.05, EPS, "never an instant prompt")
		t.eq(ObjectiveService.dropOffset(1), Vector3.zero, "the first item at the feet")
		t.truthy(ObjectiveService.dropOffset(3).Magnitude >= T.DropSpread, "the rest around them")
	end,

	["config: noise kinds, harder Standard, the roof's grace"] = function(t: Expect)
		t.eq(NoiseConfig.Kinds.ObjectiveWork.radius, 34)
		t.eq(NoiseConfig.Kinds.ObjectiveWork.priority, "Normal")
		t.eq(NoiseConfig.Kinds.ObjectiveClunk.radius, 110)
		t.eq(NoiseConfig.Kinds.ObjectiveClunk.priority, "High")
		-- the Tall Man's radii (NoiseConfig, docs/MONSTER.md 3.1) are the Standard reach; Nightmare hears 1.25 x
		t.near(DifficultyConfig.Standard.hearingMultiplier, 1, EPS)
		t.near(DifficultyConfig.Nightmare.hearingMultiplier, 1.25, EPS)
		t.near(DifficultyConfig.Standard.catchCooldownSeconds, 14.4, EPS)
		t.near(DifficultyConfig.Nightmare.catchCooldownSeconds, 8.8, EPS)
		t.eq(DifficultyConfig.Standard.batteriesPerLevel, 2)
		t.eq(DifficultyConfig.Nightmare.batteriesPerLevel, 1)
		t.near(GameConfig.BatteryDrain, 0.6325, EPS)
		t.eq(ObjectiveConfig.graceFor("Standard"), 20)
		t.eq(ObjectiveConfig.graceFor("Nightmare"), 12)
	end,

	["spawns: on every level the pick is 70-140 studs walked, unseen from the entry, outside the objective rooms"] = function(
		t: Expect
	)
		local layouts = Builder.layouts()
		local graph = ZoneGraph.build(layouts)
		local plan = RunDirector.plan(SEED, "Standard", layouts, graph)
		for _, levelId: Enums.LevelId in WorldConfig.LevelOrder do
			local layout = Builder.getLayout(levelId)
			if not layout or levelId == "Level0_Basement" then
				continue
			end
			local picks = if plan.objectives then plan.objectives[levelId] else nil
			local entry = LevelDirector.entryFor(levelId)
			local entryRoom = if entry then entry.toRoom else layout.entry
			local choice = SpawnRule.choose(SEED, layout, picks, entryRoom)
			local candidate = choice.candidate
			t.truthy(candidate ~= nil, levelId .. ": a spawn is always chosen")
			if not candidate then
				continue
			end
			local objectiveRooms = SpawnRule.objectiveRooms(layout, picks)
			if SpawnRule.handles(levelId) then
				t.falsy(choice.fallback, levelId .. ": a candidate in the band exists")
				t.truthy(
					candidate.walk >= ObjectiveConfig.Spawn.MinDistance
						and candidate.walk <= ObjectiveConfig.Spawn.MaxDistance,
					string.format("%s: %s is %.1f studs walked", levelId, candidate.id, candidate.walk)
				)
				t.falsy(candidate.visible, levelId .. ": unseen from the entry")
				t.falsy(objectiveRooms[candidate.room] == true, levelId .. ": outside the objective rooms")
				local again = SpawnRule.choose(SEED, layout, picks, entryRoom)
				t.eq((again.candidate :: SpawnRule.Candidate).id, candidate.id, levelId .. ": seeded")
				local seen: { [string]: boolean } = {}
				for seed = 1, 40 do
					local other = SpawnRule.choose(seed, layout, picks, entryRoom).candidate
					if other then
						seen[other.id] = true
					end
				end
				local distinct = 0
				for _ in seen do
					distinct += 1
				end
				t.truthy(distinct > 1 or #choice.candidates == 1, levelId .. ": runs differ")
			elseif not choice.fallback then
				t.truthy(candidate.inBand and not candidate.visible and not candidate.inObjectiveRoom, levelId)
			end
			for _, c in SpawnRule.evaluate(layout, picks, entryRoom) do
				local inside = c.walk < math.huge
				t.truthy(inside or not c.inBand, c.id .. ": a band candidate is reachable")
			end
		end
	end,

	["spawns: the layout's sight stops at walls and passes doorways"] = function(t: Expect)
		local layout = Builder.getLayout("Level1_Hallways")
		assert(layout, "layout")
		local sight = SpawnRule.layoutSight(layout)
		local rooms = LayoutSchema.indexRooms(layout)
		local entry = rooms[layout.entry]
		local c = LayoutSchema.rectCenter(entry.rect)
		local here = Vector3.new(c.X, 4.6, c.Y)
		t.truthy(sight(here, here + Vector3.new(0.5, 0, 0.5)), "inside one room")
		t.falsy(sight(here, Vector3.new(-50, 4.6, -50)), "out of the building")
		-- through a door of the entry room: its two rooms' centres see each other through the opening
		local passed = false
		for _, door in layout.doors do
			local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
			local edge = if a and b then LayoutSchema.sharedEdge(a.rect, b.rect) else nil
			if door.kind ~= "Boarded" and edge and table.find(door.rooms, layout.entry) then
				local doorway = if edge.axis == "X"
					then Vector3.new(edge.coord, 4.6, door.at)
					else Vector3.new(door.at, 4.6, edge.coord)
				passed = sight(here, doorway)
				break
			end
		end
		t.truthy(passed, "a line out through the doorway is clear")
		local eyes = SpawnRule.entryEyes(layout, layout.entry)
		t.eq(#eyes, 5, "the centre and four inset corners")
	end,

	["floor 0: fuses into the panel, the main breaker, the power, the exit"] = function(t: Expect)
		inRun("Level0_Basement", 1, function(world: World)
			local player = world.players[1]
			expectLocked(t, world)
			t.eq(ReplicatedStorage:GetAttribute(M.PowerOffLevel), "Level0_Basement", "the power is out")
			t.eq(ReplicatedStorage:GetAttribute(M.ObjectiveLevel), "Level0_Basement", "the tracker follows the floor")
			local panel = one(Tags.ObjectiveStation, world.levelId, "BreakerPanel")
			local fit1 = promptOf(panel, "FitFuse", 1)
			t.eq(Attributes.getNumber(fit1, W.BaseHold, -1), 0, "without a fuse the slot says so (instant)")
			t.truthy(string.find(fit1.ActionText, "Find a fuse first", 1, true) ~= nil, fit1.ActionText)
			t.falsy(serves("Breaker", panel, promptOf(panel, "Breaker")), "the breaker waits for the fuses")
			takeAll(t, world, player)
			t.eq(progress(world).FindFuses, 3, "three fuses found")
			t.eq(player:GetAttribute(P.Carrying), "Fuse:3", "carried")
			t.eq(Attributes.getNumber(fit1, W.BaseHold, -1), 2, "now the slot takes a 2 s fit")
			t.falsy(serves("FitFuse", panel, promptOf(panel, "FitFuse", 2)), "the slots fill in order")
			for slot = 1, 3 do
				use(t, world, player, "FitFuse", panel, promptOf(panel, "FitFuse", slot), "slot " .. slot)
			end
			t.eq(progress(world).FitFuses, 3, "three fitted")
			t.eq(player:GetAttribute(P.Carrying), "", "nothing left in hand")
			expectLocked(t, world)
			use(t, world, player, "Breaker", panel, promptOf(panel, "Breaker"), "the breaker")
			t.eq(progress(world).ThrowBreaker, 1)
			t.truthy(type(ReplicatedStorage:GetAttribute(M.PowerOnAt)) == "number", "the lights start coming on")
			expectUnlocked(t, world)
			advance(world, T.PowerOnSeconds + 0.5)
			t.eq(ReplicatedStorage:GetAttribute(M.PowerOffLevel), nil, "the power is back")
		end)
	end,

	["floor 1: the master keys, the padlock, the exit"] = function(t: Expect)
		inRun("Level1_Hallways", 2, function(world: World)
			local carrier, other = world.players[1], world.players[2]
			expectLocked(t, world)
			local lock = exitLock(world)
			local unlockPrompt = promptOf(lock, "Unlock")
			local lockedPrompt = promptOf(lock, "Locked")
			t.truthy(serves("Locked", lock, lockedPrompt), "Locked — needs the master keys")
			t.falsy(serves("Unlock", lock, unlockPrompt), "no keys, no Unlock")
			takeAll(t, world, carrier)
			t.falsy(serves("Locked", lock, lockedPrompt), "the keys turn the prompt to Unlock")
			t.truthy(serves("Unlock", lock, unlockPrompt), "Unlock")
			local canUse = ObjectiveService.Handlers.Unlock.canUse
			assert(canUse, "Unlock canUse")
			local ok, reason = canUse(other, unlockPrompt, lock)
			t.falsy(ok, "only the carrier unlocks it")
			t.eq(reason, "Obj.TeammateHas")
			use(t, world, carrier, "Unlock", lock, unlockPrompt, "the padlock")
			expectUnlocked(t, world)
			t.eq(carrier:GetAttribute(P.Carrying), "", "the keys stay in the lock")
		end)
	end,

	["floor 2: the Auditorium storey's exit is open; reaching it is done when the squad moves on"] = function(
		t: Expect
	)
		inRun("Level2_Auditorium", 1, function(world: World)
			t.truthy(ObjectiveService.ExitOpen(world.levelId), "no lock: open from the start")
			t.eq(#items(world), 0, "nothing to find")
			t.eq(ReplicatedStorage:GetAttribute(M.ObjectiveLevel), world.levelId, "the tracker follows the floor")
			t.eq(progress(world).ReachExit or 0, 0, "not reached yet")
			LevelDirector.LevelDeactivated:Fire(world.levelId)
			t.eq(progress(world).ReachExit, 1, "done once the squad has left the storey")
		end)
	end,

	["carry: a carrier who dies or leaves drops everything; a teammate takes it on"] = function(t: Expect)
		inRun("Level0_Basement", 2, function(world: World)
			local first, second = world.players[1], world.players[2]
			local fuse = items(world)[1]
			use(t, world, first, "Pickup", fuse, promptOf(fuse, "Pickup"), "a fuse")
			t.eq(ObjectiveService.GetItemState(fuse), "Carried")
			t.falsy(serves("Pickup", fuse, promptOf(fuse, "Pickup")), "a carried item has no prompt")
			LifeStateService.SetSpectating(first)
			t.eq(ObjectiveService.GetItemState(fuse), "World", "dropped where they fell")
			t.truthy(fuse:IsDescendantOf(game:GetService("Workspace")), "back in the world")
			t.eq(first:GetAttribute(P.Carrying), "", "nothing carried")
			t.truthy(serves("Pickup", fuse, promptOf(fuse, "Pickup")), "anyone can take it")
			use(t, world, second, "Pickup", fuse, promptOf(fuse, "Pickup"), "the teammate")
			t.eq(second:GetAttribute(P.Carrying), "Fuse:1")
			ObjectiveService.OnPlayerRemoving(second)
			t.eq(ObjectiveService.GetItemState(fuse), "World", "leaving drops it too")
			t.eq(progress(world).FindFuses, 1, "a dropped fuse is not found twice")
		end)
	end,
}
