--!strict
-- ObjectiveFlow: the floor objectives played through ObjectiveService on the real fixtures of each floor, driven the
-- way players drive them (its InteractionService handlers: filter, canUse, onBegin, onCancel, onComplete), on a fake
-- clock: every floor's steps, its exit Locked before and Open after (ExitOpen gates the airlock), the missed acid
-- throw brewed again, the pour, the 45 s survive, carried items dropped on death and on leaving and taken on by a
-- teammate. Plus the pure pieces: ObjectiveState's encodings, tracker lines and nudge, the working-hold maths, the
-- Creature's spawn rule on every level (SpawnRule: the walking band, the entry's sight, the objective rooms) and the
-- Floor 4 numbers (the telegraphed lunge, the retreat, the water catch rules).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
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
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)

local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)
local RunDirector = require(ServerScriptService.Services.Core.NoiseAndDirectorService.RunDirector)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local VentNetworkService = require(ServerScriptService.Services.Vents.VentNetworkService)
local ChemicalProjectileService = require(ServerScriptService.Services.Mechanics.ChemicalProjectileService)
local DoorService = require(ServerScriptService.Services.Mechanics.DoorService)
local FloodedPoolService = require(ServerScriptService.Services.Mechanics.FloodedPoolService)
local LockerHidingService = require(ServerScriptService.Services.Mechanics.LockerHidingService)
local ParachuteService = require(ServerScriptService.Services.Mechanics.ParachuteService)
local ObjectiveService = require(ServerScriptService.Services.Levels.ObjectiveService)
local Brain = require(ServerScriptService.Services.Monster.MonsterAIService.Brain)
local SpawnRule = require(ServerScriptService.Services.Monster.MonsterAIService.SpawnRule)
local AquaticStalk = require(ServerScriptService.Services.Monster.MonsterAIService.States.AquaticStalk)
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
		Builder.BuildFixtures(levelId, folder, nil, 99)
		local picks = RunDirector.pickObjective(SEED, layout, floor)
		for index, anchor in picks do
			local plan: Types.PlannedProp = {
				kind = floor.item.prop,
				anchorId = anchor.id,
				levelId = levelId,
				cframe = Builder.anchorCFrame(levelId, anchor),
				variant = 1,
				slot = index,
			}
			Builder.BuildProp(plan, folder, Random.new(index))
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
		LockerHidingService.Init()
		LockerHidingService.BeginRun(ctx)
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
	LockerHidingService.EndRun()
	DoorService.EndRun()
	LifeStateService.EndRun()
	PlayerStateService.EndRun()
	RunStatsService.EndRun()
	for _, player in players do
		ChemicalProjectileService.OnPlayerRemoving(player)
		LockerHidingService.OnPlayerRemoving(player)
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

-- The floor's items, wherever they are (a carried one, or the coach's key out of sight, is not in the Workspace).
local function items(world: World): { Model }
	local out: { Model } = {}
	for _, instance in game:GetService("CollectionService"):GetTagged(Tags.ObjectiveItem) do
		if
			instance:IsA("Model")
			and instance:GetAttribute(W.LevelId) == world.levelId
			and instance:GetAttribute(W.ObjectiveId) == spec(world.levelId).item.prop
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
	["state: steps, carry and targets round-trip; tracker lines count and tick"] = function(t: Expect)
		local floor = spec("Level0_Basement")
		local encoded = ObjectiveState.encodeSteps(floor, { FindFuses = 2, FitFuses = 1 })
		t.eq(encoded, "FindFuses=2;FitFuses=1;ThrowBreaker=0")
		local decoded = ObjectiveState.decodeSteps(encoded)
		t.eq(decoded.FindFuses, 2)
		t.eq(decoded.ThrowBreaker, 0)
		local lines = ObjectiveState.stepLines(floor, { FindFuses = 3, FitFuses = 1 }, nil)
		t.eq(lines[1].text, "Fuses 3/3")
		t.truthy(lines[1].done, "found every fuse")
		t.truthy(lines[2].active and not lines[2].done, "fitting is the current step")
		t.eq(lines[2].text, "Fit the fuses 1/3")
		local gym = spec("Level3_Gymnasium")
		local timed = ObjectiveState.stepLines(gym, { FindCoachKey = 1, UnlockStore = 1, StartGenerator = 1 }, 12.2)
		t.eq(timed[4].text, "Survive while the door motor winds: 13s", "the countdown rounds up")
		t.truthy(timed[4].timed, "the countdown is running")
		local carry = ObjectiveState.encodeCarry({ "Fuse", "MasterKeys", "Reagent" }, { Fuse = 2, MasterKeys = 1 })
		t.eq(carry, "Fuse:2;MasterKeys:1")
		local entries = ObjectiveState.decodeCarry(carry)
		t.eq(#entries, 2)
		t.eq(ObjectiveState.carryLine(entries, true), "Carrying: Fuse ×2, Master keys, Acid flask")
		t.eq(ObjectiveState.carryLine({}, false), nil)
		local targets = ObjectiveState.decodeTargets(
			ObjectiveState.encodeTargets({ { room = "L2_ChemPrep_205", point = Vector3.new(1.25, 2, -3.5) } })
		)
		t.eq(#targets, 1)
		t.eq(targets[1].room, "L2_ChemPrep_205")
		t.truthy((targets[1].point - Vector3.new(1.25, 2, -3.5)).Magnitude < 0.01, "the point survives")
		t.eq(ObjectiveState.roomName("L2_ChemPrep_205"), "Chem Prep 205")
		t.eq(ObjectiveState.roomName("L0_Storage_NW"), "Storage NW")
		t.eq(ObjectiveState.roomName("L3_LockerRoom_Boys"), "Locker Room Boys")
	end,

	["nudge: the nearest target's room (its doorway from outside, its centre inside), never the item"] = function(
		t: Expect
	)
		local layout = Builder.getLayout("Level2_ScienceHall")
		assert(layout, "layout")
		local byId = LayoutSchema.indexRooms(layout)
		local origin = WorldConfig.levelOrigin(layout.id)
		local hood: LayoutSchema.Anchor? = nil
		for _, anchor in layout.anchors do
			if anchor.kind == "FumeHood" then
				hood = anchor
			end
		end
		assert(hood, "the fume hood anchor")
		local item = origin + hood.pos
		local entryRoom = byId[layout.entry]
		local c = LayoutSchema.rectCenter(entryRoom.rect)
		local from = origin + Vector3.new(c.X, 0, c.Y)
		local nudge = ObjectiveState.nudge(layout, { { room = hood.room, point = item } }, from)
		assert(nudge, "a nudge")
		t.eq(nudge.room, hood.room, "the room holding the target")
		t.eq(nudge.label, ObjectiveState.roomName(hood.room))
		t.truthy((nudge.point - item).Magnitude > 0.5, "not the item's spot")
		local doorways = ObjectiveState.doorways(layout, hood.room)
		local onDoorway = false
		for _, doorway in doorways do
			if
				(Vector3.new(doorway.X, 0, doorway.Z) - Vector3.new(nudge.point.X, 0, nudge.point.Z)).Magnitude < 0.01
			then
				onDoorway = true
			end
		end
		t.truthy(onDoorway, "from outside it points at a doorway of that room")
		local centre = ObjectiveState.roomCentre(layout, hood.room) :: Vector3
		local inside = ObjectiveState.nudge(layout, { { room = hood.room, point = item } }, centre)
		assert(inside, "a nudge inside")
		t.truthy(
			(Vector3.new(inside.point.X, 0, inside.point.Z) - Vector3.new(centre.X, 0, centre.Z)).Magnitude < 0.01,
			"inside the room it points at its centre"
		)
	end,

	["working holds: kept progress, the hold left, the chain hit, the drop spiral, the cord"] = function(t: Expect)
		t.near(ObjectiveService.workProgress(5, 2, nil, 10), 0.4, EPS, "kept progress")
		t.near(ObjectiveService.workProgress(5, 2, 9, 10), 0.6, EPS, "plus the running hold")
		t.eq(ObjectiveService.workProgress(5, 4, 0, 10), 1, "clamped")
		t.near(ObjectiveService.holdLeft(5, 2), 3, EPS)
		t.near(ObjectiveService.holdLeft(5, 5), 0.05, EPS, "never an instant prompt")
		t.truthy(ObjectiveService.chainHit(Vector3.new(0, 3, 0), Vector3.zero), "3 studs is a hit")
		t.falsy(ObjectiveService.chainHit(Vector3.new(0, 3.01, 0), Vector3.zero), "past it is a miss")
		t.eq(ObjectiveService.dropOffset(1), Vector3.zero, "the first item at the feet")
		t.truthy(ObjectiveService.dropOffset(3).Magnitude >= T.DropSpread, "the rest around them")
		t.eq(ObjectiveService.cordReach(1), 0, "the cord snaps home")
		t.truthy(ObjectiveService.cordReach(0.3) > 0, "yanked out with the hold")
	end,

	["config: noise kinds, harder Standard, Floor 4 numbers"] = function(t: Expect)
		t.eq(NoiseConfig.Kinds.ObjectiveWork.radius, 34)
		t.eq(NoiseConfig.Kinds.ObjectiveWork.priority, "Normal")
		t.eq(NoiseConfig.Kinds.ObjectiveClunk.radius, 110)
		t.eq(NoiseConfig.Kinds.ObjectiveClunk.priority, "High")
		t.eq(NoiseConfig.Kinds.GeneratorStart.radius, 170)
		t.eq(NoiseConfig.Kinds.GeneratorStart.priority, "Critical")
		t.near(DifficultyConfig.Standard.hearingMultiplier, 1.15, EPS)
		t.near(DifficultyConfig.Nightmare.hearingMultiplier, 1.4375, EPS)
		t.near(DifficultyConfig.Standard.catchCooldownSeconds, 14.4, EPS)
		t.near(DifficultyConfig.Nightmare.catchCooldownSeconds, 8.8, EPS)
		t.eq(DifficultyConfig.Standard.batteriesPerLevel, 2)
		t.eq(DifficultyConfig.Nightmare.batteriesPerLevel, 1)
		t.near(GameConfig.BatteryDrain, 0.6325, EPS)
		t.eq(CreatureConfig.Speeds.AquaticStalk, 6.5)
		t.eq(CreatureConfig.Speeds.AquaticLunge, 18)
		t.eq(AquaticStalk.LungeRange, 9)
		t.eq(CreatureConfig.Water.TelegraphSeconds, 1.2)
		t.eq(CreatureConfig.Water.LungeWindow, 2.5)
		t.eq(CreatureConfig.Water.LungeCooldown, 2)
		t.eq(CreatureConfig.Water.GrabRetreatSeconds, 15)
		t.eq(CreatureConfig.Water.PoolGraceSeconds, 20)
		t.eq(GameConfig.StrugglePressesToEscape, 14)
		t.eq(GameConfig.OxygenDrainGrabbed, 5)
		t.eq(FloodedPoolService.GrabMinOxygen, 40)
		t.eq(ObjectiveConfig.graceFor("Standard"), 20)
		t.eq(ObjectiveConfig.graceFor("Nightmare"), 12)
		t.truthy(CreatureConfig.Speeds.AquaticStalk < 9, "a freestyle swimmer outswims it")
		t.truthy(CreatureConfig.Speeds.AquaticStalk > 4, "one treading water does not")
	end,

	["pool: in or from the water the telegraphed grab is the only catch; it retreats after a grab"] = function(
		t: Expect
	)
		local check: Brain.CatchCheck = {
			horizontal = 2,
			vertical = 0,
			distance = 2,
			creatureInVent = false,
			targetInVent = false,
			lineClear = true,
			playing = true,
			hiding = false,
			canHunt = true,
			busy = false,
			hidden = false,
			stunned = false,
		}
		t.eq(Brain.catchKind(check), "Hallway", "on land, close: a hallway catch")
		check.creatureInWater = true
		t.eq(Brain.catchKind(check), nil, "from the water: none")
		check.creatureInWater = false
		check.targetSwimming = true
		t.eq(Brain.catchKind(check), nil, "a swimmer: none")
		local summary: Brain.Summary = {
			state = "WallChase",
			elapsed = 1,
			scripted = false,
			stunned = false,
			awake = true,
			catching = false,
			canHunt = true,
			inVent = false,
			sees = true,
			seesInVent = false,
			ventQuarry = false,
			heard = 0,
			investigating = 0,
			memoryAge = 0,
			breakChase = false,
			swimmer = true,
			inWater = true,
			retreating = false,
			stateDone = false,
		}
		t.eq(Brain.decide(summary).state, "AquaticStalk", "a swimmer in sight from the water is stalked, not chased")
		summary.retreating = true
		summary.canHunt = false
		t.eq(Brain.decide(summary).state, "AquaticStalk", "retreating after a grab")
		local layout = Builder.getLayout("Level4_FloodedPool")
		assert(layout, "pool layout")
		local info = Brain.levelInfo(layout)
		assert(info, "pool info")
		t.truthy(#info.basins > 0, "the pool has water")
		for _, basin in info.basins do
			t.eq(basin.ventExitOnly, true, basin.id .. " is left only through its vent route")
		end
	end,

	["pool: every lunge is telegraphed for 1.2 s, then runs its window at the lunge pace"] = function(t: Expect)
		local now = 100
		local telegraphs: { { origin: Vector3, seconds: number } } = {}
		local goTos: { { goal: Vector3, lunge: boolean } } = {}
		local stops = 0
		local grabbed: Player? = nil
		local speed = 0
		local swimmer = Instance.new("Player")
		local swimmerRoot = Vector3.new(6, 0, 0)
		local retreat: Vector3? = nil
		local mover = {
			Busy = function()
				return false
			end,
			Medium = function()
				return "Water"
			end,
			Stop = function()
				stops += 1
			end,
			SetSpeed = function(_self: any, value: number)
				speed = value
			end,
			SetRepathInterval = function() end,
			GoTo = function(_self: any, goal: Vector3, options: any)
				table.insert(goTos, { goal = goal, lunge = options ~= nil and options.lunge == true })
			end,
			BasinAt = function()
				return nil
			end,
		}
		local ctx: any = {
			mover = mover,
			body = {
				GetPosition = function()
					return Vector3.zero
				end,
				SetWalkSpeed = function() end,
				Face = function() end,
			},
			random = Random.new(1),
			now = function(): number
				return now
			end,
			difficulty = "Standard",
			target = swimmer,
			sightings = { { player = swimmer } },
			heard = nil,
			memory = nil,
			rootOf = function(): Vector3?
				return swimmerRoot
			end,
			swimming = function(): boolean
				return true
			end,
			grabArmed = function(): boolean
				return true
			end,
			poolGrabber = function()
				return function(_player: Player): boolean
					return true
				end
			end,
			setGrabbed = function(player: Player?)
				grabbed = player
			end,
			speedOf = function(): number
				return CreatureConfig.Speeds.AquaticStalk
			end,
			telegraph = function(origin: Vector3, seconds: number)
				table.insert(telegraphs, { origin = origin, seconds = seconds })
			end,
			poolRetreat = function(): Vector3?
				return retreat
			end,
		}
		AquaticStalk.enter(ctx, "Patrol")
		AquaticStalk.update(ctx, 0.1)
		t.eq(#telegraphs, 1, "the lunge is telegraphed first")
		t.eq(telegraphs[1].seconds, 1.2)
		t.truthy(AquaticStalk.telegraphing(ctx), "held still while it shows")
		t.eq(#goTos, 0, "no lunge yet")
		now += 1.1
		AquaticStalk.update(ctx, 0.1)
		t.eq(#goTos, 0, "still telegraphing at 1.1 s")
		now += 0.2
		AquaticStalk.update(ctx, 0.1)
		t.truthy(#goTos == 1 and goTos[1].lunge, "then the lunge")
		t.eq(speed, CreatureConfig.Speeds.AquaticLunge, "at the lunge pace")
		swimmerRoot = Vector3.new(3, 0, 0)
		now += 0.2
		AquaticStalk.update(ctx, 0.1)
		t.eq(grabbed, swimmer, "within reach it grabs")
		AquaticStalk.released(ctx)
		retreat = Vector3.new(-30, 0, 0)
		AquaticStalk.update(ctx, 0.1)
		t.truthy(goTos[#goTos].goal == retreat and not goTos[#goTos].lunge, "after a grab it retreats, no lunge")
		t.eq(#telegraphs, 1, "and no telegraph while retreating")
		retreat = nil
		AquaticStalk.update(ctx, 0.1)
		t.eq(#telegraphs, 1, "the lunge cooldown runs after a grab")
		now += AquaticStalk.LungeCooldown + 0.1
		AquaticStalk.update(ctx, 0.1)
		t.eq(#telegraphs, 2, "then the next lunge is telegraphed again")
		t.truthy(stops > 0, "held still")
	end,

	["spawns: on every level the pick is 70-140 studs walked, unseen from the entry, outside the objective rooms"] = function(
		t: Expect
	)
		local layouts = Builder.layouts()
		local graph = ZoneGraph.build(layouts)
		local plan = RunDirector.plan(SEED, "Standard", layouts, graph)
		for _, levelId: Enums.LevelId in Enums.LevelId do
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
		local layout = Builder.getLayout("Level2_ScienceHall")
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
			if door.kind ~= "Boarded" and table.find(door.rooms, layout.entry) then
				local doorway = ObjectiveState.doorways(layout, layout.entry)[1]
				if doorway then
					local origin = WorldConfig.levelOrigin(layout.id)
					local local2 = doorway - origin
					passed = sight(here, Vector3.new(local2.X, 4.6, local2.Z))
				end
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

	["floor 2: reagents, the mix, a missed throw brewed again, the chain burnt"] = function(t: Expect)
		inRun("Level2_ScienceHall", 1, function(world: World)
			local player = world.players[1]
			expectLocked(t, world)
			local hood = one(Tags.ObjectiveStation, world.levelId, "FumeHood")
			local mix = promptOf(hood, "Mix")
			t.eq(Attributes.getNumber(mix, W.BaseHold, -1), 0, "needs the reagents first")
			takeAll(t, world, player)
			t.eq(progress(world).FindReagents, 3)
			use(t, world, player, "Mix", hood, mix, "load the jars")
			t.eq(Attributes.getNumber(mix, W.BaseHold, -1), 5, "then a 5 s mix")
			-- let go half way: the mix keeps its progress
			local mixBegin = ObjectiveService.Handlers.Mix.onBegin
			assert(mixBegin, "Mix onBegin")
			mixBegin(player, mix, hood)
			advance(world, 2)
			local cancel = ObjectiveService.Handlers.Mix.onCancel
			assert(cancel, "Mix onCancel")
			cancel(player, mix, hood, "Released")
			t.near(Attributes.getNumber(mix, W.BaseHold, -1), 3, 0.11, "3 s left to mix")
			use(t, world, player, "Mix", hood, mix, "finish the mix")
			t.eq(progress(world).MixAcid, 1)
			local acid = ObjectiveService.GetAcidModel()
			assert(acid, "the acid flask stands at the hood")
			use(t, world, player, "Pickup", acid, promptOf(acid, "Pickup"), "the acid flask")
			t.truthy(ChemicalProjectileService.HoldsAcid(player), "in hand")
			t.eq(player:GetAttribute(P.HeldItem), "AcidFlask")
			-- thrown, it breaks well away from the chain
			ChemicalProjectileService.TakeAcid(player)
			local lock = exitLock(world)
			local centre = (PropKit.attachmentWorld(PropKit.findAttachment(lock, "ChainCentre") :: Attachment)).Position
			ChemicalProjectileService.AcidShattered:Fire(centre + Vector3.new(6, 0, 0), player)
			local _, unlocked, state = ObjectiveService.GetFloor(world.levelId)
			t.falsy(unlocked, "a miss leaves it chained")
			t.eq(state, "None", "the flask is gone")
			t.eq(progress(world).MixAcid, 0, "the mix reads undone")
			t.truthy(serves("Mix", hood, mix), "the hood brews another")
			t.eq(Attributes.getNumber(mix, W.BaseHold, -1), 5, "a full mix, the reagents still loaded")
			use(t, world, player, "Mix", hood, mix, "mix again")
			local again = ObjectiveService.GetAcidModel()
			assert(again, "another flask")
			use(t, world, player, "Pickup", again, promptOf(again, "Pickup"), "the second flask")
			ChemicalProjectileService.TakeAcid(player)
			ChemicalProjectileService.AcidShattered:Fire(centre + Vector3.new(0, 2, 0), player)
			t.falsy(ObjectiveService.ExitOpen(world.levelId), "it burns for a moment")
			advance(world, T.BurnSeconds + 0.1)
			t.eq(progress(world).BurnChain, 1, "the chain is eaten through")
			expectUnlocked(t, world)
		end)
	end,

	["floor 2: the acid poured at the door works too; a lost flask is a miss"] = function(t: Expect)
		inRun("Level2_ScienceHall", 1, function(world: World)
			local player = world.players[1]
			local hood = one(Tags.ObjectiveStation, world.levelId, "FumeHood")
			local mix = promptOf(hood, "Mix")
			takeAll(t, world, player)
			use(t, world, player, "Mix", hood, mix, "load")
			use(t, world, player, "Mix", hood, mix, "mix")
			local acid = ObjectiveService.GetAcidModel() :: Model
			use(t, world, player, "Pickup", acid, promptOf(acid, "Pickup"), "acid")
			ChemicalProjectileService.AcidLost:Fire(player)
			local _, _, state = ObjectiveService.GetFloor(world.levelId)
			t.eq(state, "None", "lost: brew again")
			ChemicalProjectileService.TakeAcid(player)
			use(t, world, player, "Mix", hood, mix, "mix again")
			local second = ObjectiveService.GetAcidModel() :: Model
			use(t, world, player, "Pickup", second, promptOf(second, "Pickup"), "acid again")
			advance(world, 0.2)
			local lock = exitLock(world)
			local pour = promptOf(lock, "Pour")
			t.falsy(serves("Locked", lock, promptOf(lock, "Locked")), "with the acid in hand the door offers the pour")
			use(t, world, player, "Pour", lock, pour, "pour")
			t.falsy(ChemicalProjectileService.HoldsAcid(player), "poured out")
			advance(world, T.BurnSeconds + 0.1)
			expectUnlocked(t, world)
		end)
	end,

	["floor 3: search the lockers, the store, the generator, survive 45 s"] = function(t: Expect)
		inRun("Level3_Gymnasium", 1, function(world: World)
			local player = world.players[1]
			expectLocked(t, world)
			local key = items(world)[1]
			assert(key, "the coach's key")
			t.eq(ObjectiveService.GetItemState(key), "World", "a world item")
			t.falsy(key:IsDescendantOf(game:GetService("Workspace")), "hanging out of sight until searched")
			local searches = ObjectiveService.GetSearchPrompts()
			local keyLocker: Model? = nil
			local layout = Builder.getLayout(world.levelId) :: LayoutSchema.LevelLayout
			local ref: string? = nil
			for _, anchor in layout.anchors do
				if anchor.id == key:GetAttribute(W.AnchorId) then
					ref = anchor.ref
				end
			end
			local empty: { prompt: ProximityPrompt, locker: Model }? = nil
			local keyed: { prompt: ProximityPrompt, locker: Model }? = nil
			for prompt, locker in searches do
				if locker:GetAttribute(W.AnchorId) == ref then
					keyed = { prompt = prompt, locker = locker }
					keyLocker = locker
				elseif empty == nil then
					empty = { prompt = prompt, locker = locker }
				end
				t.eq(prompt.KeyboardKeyCode, Enum.KeyCode.R, "Search is the Kick key, not Hide")
				t.eq(Attributes.getNumber(prompt, W.BaseHold, 0), T.SearchHold, "a 1 s search")
			end
			assert(empty and keyed and keyLocker, "a key locker and an empty one")
			use(t, world, player, "Search", empty.locker, empty.prompt, "an empty locker")
			t.truthy(LockerHidingService.IsSearchOpen(empty.locker), "it swings ajar")
			t.falsy(serves("Search", empty.locker, empty.prompt), "searched once")
			local hideFilter = LockerHidingService.HideHandler.filter
			assert(hideFilter, "the Hide filter")
			t.falsy(hideFilter(empty.locker, promptOf(empty.locker, "Hide")), "no hiding while it stands open")
			advance(world, T.SearchEmptySeconds + 0.1)
			t.falsy(LockerHidingService.IsSearchOpen(empty.locker), "and shuts again")
			use(t, world, player, "Search", keyed.locker, keyed.prompt, "the key's locker")
			t.truthy(key:IsDescendantOf(game:GetService("Workspace")), "the key shows")
			use(t, world, player, "Pickup", key, promptOf(key, "Pickup"), "the coach's key")
			t.eq(progress(world).FindCoachKey, 1)
			local store = one(Tags.ObjectiveStation, world.levelId, "StoreLock")
			local storeDoor = DoorService.Get(world.levelId, "EquipmentStoreDoor")
			assert(storeDoor, "the equipment store door")
			t.eq(DoorService.GetState(storeDoor), "Locked", "the store starts Locked")
			local generator = one(Tags.ObjectiveStation, world.levelId, "Generator")
			t.falsy(serves("Generator", generator, promptOf(generator, "Generator")), "the generator waits")
			use(t, world, player, "Unlock", store, promptOf(store, "Unlock"), "the store padlock")
			advance(world, T.LockOffSeconds + 0.1)
			t.eq(DoorService.GetState(storeDoor), "Open", "the store door swings open")
			use(t, world, player, "Generator", generator, promptOf(generator, "Generator"), "the pull start")
			t.eq(progress(world).StartGenerator, 1)
			local endsAt = ReplicatedStorage:GetAttribute(M.ObjectiveTimerEndsAt)
			t.truthy(type(endsAt) == "number", "the countdown is replicated")
			t.near(endsAt :: number, world.now + 45, 0.11, "45 s of door motor")
			advance(world, 44.7)
			expectLocked(t, world)
			advance(world, 0.5)
			t.eq(progress(world).WindMotor, 1, "the motor wound")
			expectUnlocked(t, world)
		end)
	end,

	["floor 4: the hatch blocks its grate; dive for the wheel, fit it, turn it (kept), the exit"] = function(t: Expect)
		inRun("Level4_FloodedPool", 1, function(world: World)
			local player = world.players[1]
			expectLocked(t, world)
			local valve = one(Tags.ObjectiveStation, world.levelId, "HatchValve")
			local grate = valve:GetAttribute(W.GrateId)
			if type(grate) == "string" then
				t.truthy(VentNetworkService.IsBlocked(grate), "the hatch keeps its grate shut")
			end
			local fit = promptOf(valve, "FitValve")
			t.eq(fit.ActionText, "Needs the valve wheel")
			ObjectiveService.Handlers.FitValve.onComplete(player, fit, valve)
			t.eq(progress(world).FitWheel or 0, 0, "no wheel, no fit")
			takeAll(t, world, player)
			t.eq(Attributes.getNumber(fit, W.BaseHold, -1), 3, "a 3 s fit")
			use(t, world, player, "FitValve", valve, fit, "fit the wheel")
			local turn = promptOf(valve, "TurnValve")
			local turnBegin = ObjectiveService.Handlers.TurnValve.onBegin
			assert(turnBegin, "TurnValve onBegin")
			turnBegin(player, turn, valve)
			advance(world, 2)
			local cancel = ObjectiveService.Handlers.TurnValve.onCancel
			assert(cancel, "TurnValve onCancel")
			cancel(player, turn, valve, "Released")
			t.near(Attributes.getNumber(turn, W.BaseHold, -1), 2, 0.11, "the turn keeps its progress")
			t.truthy(string.find(turn.ObjectText, "turned", 1, true) ~= nil, turn.ObjectText)
			use(t, world, player, "TurnValve", valve, turn, "turn the rest")
			t.eq(progress(world).TurnValve, 1)
			if type(grate) == "string" then
				t.falsy(VentNetworkService.IsBlocked(grate), "the grate is usable again")
			end
			expectUnlocked(t, world)
		end)
	end,

	["floor 5: the crate stays chained until the bolt cutters cut it"] = function(t: Expect)
		inRun("Level5_Roof", 1, function(world: World)
			local player = world.players[1]
			t.falsy(ParachuteService.IsCrateOpen(), "no pack while chained")
			t.falsy(ObjectiveService.ExitOpen(world.levelId), "the crate is the roof's lock")
			local crate = one(Tags.ExitLock, world.levelId, "CrateChain")
			local cut = promptOf(crate, "CutChain")
			t.truthy(serves("Locked", crate, promptOf(crate, "Locked")), "Locked — chained shut")
			t.falsy(serves("CutChain", crate, cut), "no cutters, no cut")
			takeAll(t, world, player)
			t.truthy(serves("CutChain", crate, cut), "the cutters")
			use(t, world, player, "CutChain", crate, cut, "cut the chain")
			t.truthy(ObjectiveService.ExitOpen(world.levelId), "cut")
			t.truthy(ParachuteService.IsCrateOpen(), "the packs are free")
			t.eq(world.unlocked[1], world.levelId, "the roof controller is told (the door smash)")
		end)
		t.truthy(ParachuteService.IsCrateOpen(), "the run's end opens the crate again")
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
