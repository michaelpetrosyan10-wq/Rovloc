--!strict
-- Stairwell airlocks. CheckpointAirlockService's rules (each level's exit vestibule, Idle -> Waiting, the seal verdict
-- table, who survives and who is left behind, the respawn health) and the live service on a fake clock over the real
-- Level 0 / 1 / 2 / 5 shells, checkpoint volumes and fire doors with hand-built characters: the straggler timer
-- starting on the first arrival (StragglerDeadline, the Notify), a Downed straggler not holding the squad, the doors
-- sealing through DoorService, the floor changing once they are shut (left-behind spectators, FloorsCleared,
-- FloorCleared, LevelDirector.Advance, 50% respawns at the next floor's entry, Sealed), the deadline sealing on
-- whoever made it, an empty vestibule resetting at the deadline, a dev level change resetting, a leaving straggler
-- sealing at once, the dev seal, and the roof staying Idle. AirlockController's banner maths.
-- (Characters are never really despawned or spawned here: CharacterService needs the engine to build avatars, so the
-- spec records the calls through SetCharacterHooks.)

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Net = require(ReplicatedStorage.Shared.Net)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)

local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local CheckpointAirlockService = require(ServerScriptService.Services.Match.CheckpointAirlockService)
local DoorService = require(ServerScriptService.Services.Mechanics.DoorService)
local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

local AirlockController = require(StarterPlayer.StarterPlayerScripts.Controllers.Match.AirlockController)

type Expect = SpecRunner.Expect
type Occupant = CheckpointAirlockService.Occupant

type Sent = { name: string, player: Player?, payload: any }

type FakeClock = {
	clock: CheckpointAirlockService.Clock,
	advance: (seconds: number) -> (),
	now: () -> number,
}

type Spawned = { player: Player, cframe: CFrame }

type Run = {
	clock: FakeClock,
	spawned: { Spawned },
	despawned: { Player },
	cleared: { { level: Enums.LevelId, survivors: { Player } } },
	sealed: { string },
}

local W = Attributes.World
local LEVELS: { Enums.LayoutId } = { "Level0_Basement", "Level1_Hallways", "Level2_ScienceHall", "Level5_Roof" }
local L0: Enums.LevelId = "Level0_Basement"
local L1: Enums.LevelId = "Level1_Hallways"
local L2: Enums.LevelId = "Level2_ScienceHall"
local L5: Enums.LevelId = "Level5_Roof"
local SEED = 7171
local LEAD = GameConfig.OneShotLead
local STRAGGLER = GameConfig.StragglerSeconds
local HIP_HEIGHT = 2
local ROOT_SIZE = Vector3.new(2, 2, 1)
local FAR = CFrame.new(0, -500, 0)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function quiet(fn: () -> ())
	local previous = Geometry.getYieldEvery()
	Geometry.setYieldEvery(0)
	local failure: any = nil
	xpcall(fn, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end)
	Geometry.setYieldEvery(previous)
	if failure ~= nil then
		error(failure, 0)
	end
end

local function fakeClock(start: number): FakeClock
	local now = start
	return {
		clock = {
			now = function(): number
				return now
			end,
		},
		advance = function(seconds: number)
			now += seconds
		end,
		now = function(): number
			return now
		end,
	}
end

-- The levels' shells, built once for this spec and kept out of the Workspace between tests (later specs expect a
-- Workspace without a school), then fresh fixtures in Workspace.Runtime.<level>, as WorldService builds them at
-- Deploying.
local world: { school: Model, lobby: Model }? = nil
local createdRuntime = false

local function freshFixtures()
	quiet(function()
		local built = world
		if built then
			built.school.Parent = Workspace
			built.lobby.Parent = Workspace
		else
			local result = Builder.BuildAuthoritative({ layouts = LEVELS, yieldEvery = 0 })
			world = { school = result.school, lobby = result.lobby }
		end
		createdRuntime = Instances.runtime() == nil
		for _, id in LEVELS do
			local folder = Instances.runtimeLevel(id, true)
			assert(folder, "runtime folder")
			for _, child in folder:GetChildren() do
				child:Destroy()
			end
			Builder.BuildFixtures(id, folder, nil, SEED)
		end
	end)
end

-- Removes the fixtures (and the runtime folders this spec created) and takes the shells out of the Workspace.
local function clearFixtures()
	for _, id in LEVELS do
		local folder = Instances.runtimeLevel(id, false)
		if folder then
			folder:Destroy()
		end
	end
	local runtime = Instances.runtime()
	if createdRuntime and runtime and #runtime:GetChildren() == 0 then
		runtime:Destroy()
	end
	local built = world
	if built then
		built.school.Parent = nil
		built.lobby.Parent = nil
	end
end

local function capture(body: (sent: { Sent }) -> ())
	local sent: { Sent } = {}
	local server = Net.Server :: any
	local fireAll, fire = server.fireAll, server.fire
	server.fireAll = function(name: string, payload: any)
		table.insert(sent, { name = name, player = nil, payload = payload })
		fireAll(name, payload)
	end
	server.fire = function(name: string, player: Player, payload: any)
		table.insert(sent, { name = name, player = player, payload = payload })
		fire(name, player, payload)
	end
	local failure: string? = nil
	xpcall(body, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end, sent)
	server.fireAll, server.fire = fireAll, fire
	if failure ~= nil then
		error(failure, 0)
	end
end

-- Notify keys sent to `player` (nil: to everyone) since `from`.
local function notified(sent: { Sent }, player: Player?): { string }
	local out: { string } = {}
	for _, entry in sent do
		if entry.name == "Notify" and entry.player == player then
			table.insert(out, entry.payload.key)
		end
	end
	return out
end

-- Moves a hand-built root. Position is written too: the engine derives it from CFrame, the Lune harness does not,
-- and LifeStateService's downed gasp cue reads it.
local function place(root: BasePart, cframe: CFrame)
	root.CFrame = cframe
	root.Position = cframe.Position
end

local nextUserId = 9700

local function fakePlayer(): (Player, BasePart)
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "AirlockSpec" .. nextUserId
	local writable = player :: any
	writable.UserId = nextUserId
	local model = Instance.new("Model")
	model.Name = player.Name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = ROOT_SIZE
	place(root, FAR)
	root.Parent = model
	model.PrimaryPart = root
	local humanoid = Instance.new("Humanoid")
	humanoid.HipHeight = HIP_HEIGHT
	humanoid.MaxHealth = GameConfig.MaxHealth
	humanoid.Health = GameConfig.MaxHealth
	humanoid.Parent = model
	player.Character = model
	return player, root
end

-- The Checkpoint volume in `level`'s exit vestibule (the run's route).
local function volumeOf(level: Enums.LevelId): BasePart
	local exit = LevelDirector.exitFor(level)
	local room = if exit then exit.fromRoom else nil
	for _, instance in CollectionService:GetTagged(Tags.CheckpointVolume) do
		if
			instance:IsA("BasePart")
			and instance:IsDescendantOf(Workspace)
			and instance:GetAttribute(W.LevelId) == level
			and instance:GetAttribute(W.ZoneId) == room
		then
			return instance
		end
	end
	error("no checkpoint volume on " .. level)
end

-- A standing root in the middle of `level`'s exit vestibule volume (feet on its floor).
local function insideOf(level: Enums.LevelId): CFrame
	local volume = volumeOf(level)
	local floor = volume.CFrame.Position.Y - volume.Size.Y / 2
	return CFrame.new(volume.CFrame.Position.X, floor + HIP_HEIGHT + ROOT_SIZE.Y / 2, volume.CFrame.Position.Z)
end

local function exitDoor(level: Enums.LevelId): Model
	local exit = LevelDirector.exitFor(level)
	for _, model in DoorService.Airlocks(level) do
		if
			model:GetAttribute(W.FromLevel) == level
			and model:GetAttribute(W.LevelId) == level
			and exit
			and model:GetAttribute(W.StairwellId) == exit.id
		then
			return model
		end
	end
	error("no exit door on " .. level)
end

-- The fire door of `level`'s entry vestibule on the run's route.
local function entryDoor(level: Enums.LevelId): Model?
	local entry = LevelDirector.entryFor(level)
	for _, model in DoorService.Airlocks(level) do
		if entry and model:GetAttribute(W.StairwellId) == entry.id and model:GetAttribute(W.LevelId) == level then
			return model
		end
	end
	return nil
end

-- Steps the doors through `seconds` of Heartbeats.
local function runDoors(clock: FakeClock, seconds: number)
	local steps = math.max(1, math.ceil(seconds * 60))
	for _ = 1, steps do
		clock.advance(seconds / steps)
		DoorService.StepMotions()
	end
end

-- Runs `body` with `players` in a live run on a fake clock (stats, move / life states, levels, doors, the airlock),
-- recording spawns, despawns and the airlock's signals; always tears it all down.
local function inRun(players: { Player }, body: (run: Run) -> ())
	Net.Server.setup()
	DoorService.Init()
	CheckpointAirlockService.Init()
	freshFixtures()
	local clock = fakeClock(1000)
	local run: Run = { clock = clock, spawned = {}, despawned = {}, cleared = {}, sealed = {} }
	DoorService.SetClock(clock.clock)
	CheckpointAirlockService.SetClock(clock.clock)
	CheckpointAirlockService.SetCharacterHooks({
		despawn = function(player: Player)
			table.insert(run.despawned, player)
		end,
		spawn = function(player: Player, cframe: CFrame)
			table.insert(run.spawned, { player = player, cframe = cframe })
		end,
	})
	local clearedConnection = CheckpointAirlockService.FloorCleared:Connect(
		function(level: Enums.LevelId, survivors: { Player })
			table.insert(run.cleared, { level = level, survivors = survivors })
		end
	)
	local sealedConnection = CheckpointAirlockService.Sealed:Connect(function(from: Enums.LevelId, to: Enums.LevelId)
		table.insert(run.sealed, from .. ">" .. to)
	end)
	local ctx: Types.RunContext = {
		runId = "airlock-spec",
		seed = SEED,
		difficulty = "Standard",
		participants = players,
		startedAt = 1000,
	}
	RunStatsService.BeginRun(ctx)
	PlayerStateService.BeginRun(ctx)
	LifeStateService.BeginRun(ctx)
	LevelDirector.BeginRun(ctx)
	DoorService.BeginRun(ctx)
	CheckpointAirlockService.BeginRun(ctx)
	local failure: string? = nil
	xpcall(body, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end, run)
	CheckpointAirlockService.EndRun()
	DoorService.EndRun()
	LevelDirector.EndRun()
	LifeStateService.EndRun()
	PlayerStateService.EndRun()
	RunStatsService.EndRun()
	for _, player in players do
		CheckpointAirlockService.OnPlayerRemoving(player)
		DoorService.OnPlayerRemoving(player)
		LifeStateService.OnPlayerRemoving(player)
		PlayerStateService.OnPlayerRemoving(player)
	end
	clearedConnection:Disconnect()
	sealedConnection:Disconnect()
	CheckpointAirlockService.SetCharacterHooks(nil)
	CheckpointAirlockService.SetClock(nil)
	DoorService.SetClock(nil)
	clearFixtures()
	if failure ~= nil then
		error(failure, 0)
	end
end

local function names(players: { Player }): string
	local out: { string } = {}
	for _, player in players do
		table.insert(out, player.Name)
	end
	return table.concat(out, ",")
end

local function occupant(lifeState: Enums.LifeState, inside: boolean): Occupant
	return { lifeState = lifeState, inside = inside }
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["rules: every floor but the roof has an exit vestibule at the bottom of its stairwell up"] = function(t: Expect)
		for _, stairwell in WorldConfig.Stairwells do
			local route: { [string]: string } = {}
			route[stairwell.from] = stairwell.id
			t.eq(CheckpointAirlockService.exitRoom(stairwell.from, route), stairwell.fromRoom, stairwell.id)
			t.eq(
				AirlockController.exitRoom(stairwell.from, route),
				stairwell.fromRoom,
				"the client agrees on " .. stairwell.id
			)
		end
		t.eq(CheckpointAirlockService.exitRoom(L0), "L0_AirlockEast")
		t.eq(CheckpointAirlockService.exitRoom(L1), "L1_AirlockWest")
		t.eq(CheckpointAirlockService.exitRoom(L5), nil, "the roof has no exit airlock")
		for _, level: Enums.LevelId in Enums.LevelId do
			local layout = Builder.getLayout(level)
			assert(layout, level)
			local room = CheckpointAirlockService.exitRoom(level)
			if room then
				t.eq(room, layout.exit, level .. "'s exit vestibule is its layout exit")
				local vestibules: { [string]: boolean } = {}
				for _, stairwell in WorldConfig.stairwellCandidates(level) do
					vestibules[stairwell.fromRoom] = true
				end
				local checkpoints = 0
				for _, trigger in layout.triggers do
					if trigger.kind == "Checkpoint" then
						checkpoints += 1
						t.truthy(vestibules[trigger.room], level .. "'s checkpoint is in an exit vestibule")
					end
				end
				t.eq(checkpoints, 3, level .. " has a checkpoint per exit candidate")
			end
		end
	end,

	["rules: the first playing participant inside starts the straggler timer"] = function(t: Expect)
		t.falsy(CheckpointAirlockService.startsWaiting({}), "nobody")
		t.falsy(CheckpointAirlockService.startsWaiting({ occupant("Alive", false), occupant("Downed", false) }))
		t.truthy(CheckpointAirlockService.startsWaiting({ occupant("Alive", false), occupant("Alive", true) }))
		t.truthy(CheckpointAirlockService.startsWaiting({ occupant("Downed", true) }), "a downed crawler counts")
		t.falsy(CheckpointAirlockService.startsWaiting({ occupant("Dead", true) }), "a corpse does not")
		t.falsy(CheckpointAirlockService.startsWaiting({ occupant("Spectating", true), occupant("Lobby", true) }))
	end,

	["rules: seal when every Alive participant is inside or at the deadline; reset an empty vestibule"] = function(
		t: Expect
	)
		local before, after = 10, 20
		local function verdict(occupants: { Occupant }, now: number): string
			return CheckpointAirlockService.sealVerdict(occupants, now, 20)
		end
		t.eq(verdict({ occupant("Alive", true), occupant("Alive", true) }, before), "Seal", "everyone is in")
		t.eq(verdict({ occupant("Alive", true), occupant("Alive", false) }, before), "Wait", "a straggler")
		t.eq(verdict({ occupant("Alive", true), occupant("Alive", false) }, after), "Seal", "time is up")
		t.eq(verdict({ occupant("Alive", true), occupant("Downed", false) }, before), "Seal", "a downed straggler")
		t.eq(
			verdict({ occupant("Downed", true), occupant("Alive", false) }, before),
			"Wait",
			"downed inside, alive out"
		)
		t.eq(verdict({ occupant("Downed", true) }, before), "Seal", "nobody alive to wait for")
		t.eq(verdict({ occupant("Alive", true), occupant("Dead", false) }, before), "Seal", "the dead do not hold it")
		t.eq(verdict({ occupant("Alive", true), occupant("Spectating", false) }, before), "Seal")
		t.eq(verdict({ occupant("Alive", false), occupant("Alive", false) }, before), "Wait", "they stepped back out")
		t.eq(verdict({ occupant("Alive", false) }, after), "Reset", "nobody inside at the deadline")
		t.eq(verdict({ occupant("Downed", false), occupant("Dead", true) }, after), "Reset")
		t.eq(verdict({}, before), "Wait")
		t.eq(verdict({}, after), "Reset")
	end,

	["rules: playing participants inside survive, outside are left behind; respawns at half health"] = function(
		t: Expect
	)
		local survivors, behind = CheckpointAirlockService.splitSurvivors({
			occupant("Alive", true),
			occupant("Alive", false),
			occupant("Downed", true),
			occupant("Downed", false),
			occupant("Dead", true),
			occupant("Spectating", false),
		})
		t.eq(table.concat(survivors :: { any }, ","), "1,3", "Alive and Downed inside")
		t.eq(table.concat(behind :: { any }, ","), "2,4", "Alive and Downed outside")
		t.eq(
			CheckpointAirlockService.respawnHealth(),
			GameConfig.MaxHealth * GameConfig.CheckpointRespawnHealthFraction,
			"50% HP"
		)
		t.eq(GameConfig.StragglerSeconds, 20, "a 20-second straggler timer")
	end,

	["live: the squad seals in; the floor changes once the doors shut; stragglers come back on the next floor"] = function(
		t: Expect
	)
		local a, rootA = fakePlayer()
		local b, rootB = fakePlayer()
		local c, rootC = fakePlayer()
		inRun({ a, b, c }, function(run: Run)
			local clock = run.clock
			local door = exitDoor(L0)
			local entry = entryDoor(L1)
			assert(entry, "Level 1's entry fire door")
			capture(function(sent: { Sent })
				CheckpointAirlockService.Poll()
				t.eq(CheckpointAirlockService.GetPhase(), "Idle", "nobody at the stairwell")
				t.eq(door:GetAttribute(W.StragglerDeadline), nil)

				place(rootA, insideOf(L0))
				CheckpointAirlockService.Poll()
				t.eq(CheckpointAirlockService.GetPhase(), "Waiting", "the first arrival starts the timer")
				t.eq(CheckpointAirlockService.GetDeadline(), clock.now() + STRAGGLER)
				t.eq(door:GetAttribute(W.StragglerDeadline), clock.now() + STRAGGLER, "on the exit fire door")
				t.eq(entry:GetAttribute(W.StragglerDeadline), nil, "and only there")
				local everyone = notified(sent, nil)
				t.eq(everyone[1], "Hud.Straggler", "everyone is told")
				t.truthy(Strings.has("Hud.Straggler"), "a Strings key")
				t.eq(DoorService.GetState(door), "Open", "still open while waiting")

				clock.advance(5)
				place(rootB, insideOf(L0) * CFrame.new(2, 0, 0))
				CheckpointAirlockService.Poll()
				t.eq(CheckpointAirlockService.GetPhase(), "Waiting", "one is still out")

				LifeStateService.Down(c, "Spec")
				t.eq(LifeStateService.GetState(c), "Downed")
				CheckpointAirlockService.Poll()
				t.eq(CheckpointAirlockService.GetPhase(), "Sealing", "a downed straggler does not hold the squad")
				t.eq(DoorService.GetState(door), "Locked", "the fire door seals")
				t.truthy(DoorService.IsMoving(door), "closing")
				CheckpointAirlockService.Poll()
				t.eq(CheckpointAirlockService.GetPhase(), "Sealing", "until the doors are shut")
				t.eq(LevelDirector.GetCurrentLevel(), L0, "the floor has not changed yet")

				runDoors(clock, LEAD + CheckpointAirlockService.SealSeconds + 0.05)
				t.falsy(DoorService.IsMoving(door), "shut")
				CheckpointAirlockService.Poll()
				t.eq(CheckpointAirlockService.GetPhase(), "Sealed")
				t.eq(LevelDirector.GetCurrentLevel(), L1, "the run moved on")
				t.eq(door:GetAttribute(W.StragglerDeadline), nil, "the deadline is cleared")
				t.eq(DoorService.GetState(door), "Locked", "and the door stays locked")

				t.eq(RunStatsService.Get(a, "FloorsCleared"), 1, "survivors clear the floor")
				t.eq(RunStatsService.Get(b, "FloorsCleared"), 1)
				t.eq(RunStatsService.Get(c, "FloorsCleared"), 0, "the straggler does not")
				t.eq(#run.cleared, 1, "FloorCleared")
				t.eq(run.cleared[1].level, L0)
				t.eq(#run.cleared[1].survivors, 2)
				t.truthy(table.find(run.cleared[1].survivors, a) and table.find(run.cleared[1].survivors, b), "A and B")
				t.eq(names(run.despawned), c.Name, "the straggler's body is despawned")
				t.eq(table.concat(notified(sent, c), ","), "Airlock.LeftBehind,Checkpoint.Respawned", "and told")
				t.eq(table.concat(notified(sent, a), ","), "Checkpoint.Sealed", "survivors are told")
				t.eq(LifeStateService.GetState(c), "Alive", "back for the next floor")
				t.eq(LifeStateService.GetHealth(c), GameConfig.MaxHealth * 0.5, "at half health")
				t.eq(#run.spawned, 1, "one respawn")
				t.eq(run.spawned[1].player, c)
				t.eq(run.spawned[1].cframe, CharacterService.SpawnCFrame(L1, 3), "in Level 1's entry vestibule, slot 3")
				t.eq(table.concat(run.sealed, ","), "Level0_Basement>Level1_Hallways", "Sealed(from, to)")

				CheckpointAirlockService.Poll()
				t.eq(CheckpointAirlockService.GetPhase(), "Idle", "watching Level 1's exit now")
				t.eq(DoorService.GetState(door), "Locked", "no backtracking")

				-- Level 1: the deadline seals on whoever made it
				place(rootA, FAR)
				place(rootB, FAR)
				place(rootC, insideOf(L1))
				CheckpointAirlockService.Poll()
				t.eq(CheckpointAirlockService.GetPhase(), "Waiting")
				local deadline = CheckpointAirlockService.GetDeadline()
				t.eq(exitDoor(L1):GetAttribute(W.StragglerDeadline), deadline)
				clock.advance(STRAGGLER - 0.1)
				CheckpointAirlockService.Poll()
				t.eq(CheckpointAirlockService.GetPhase(), "Waiting", "not before the deadline")
				clock.advance(0.2)
				CheckpointAirlockService.Poll()
				t.eq(CheckpointAirlockService.GetPhase(), "Sealing", "the timer ran out")
				runDoors(clock, LEAD + CheckpointAirlockService.SealSeconds + 0.05)
				CheckpointAirlockService.Poll()
				t.eq(LevelDirector.GetCurrentLevel(), L2, "on to Level 2")
				t.eq(LifeStateService.GetState(a), "Alive", "A, left behind, is back")
				t.eq(RunStatsService.Get(c, "FloorsCleared"), 1, "C made it this time")
				t.eq(RunStatsService.Get(a, "FloorsCleared"), 1)
				t.eq(#run.spawned, 3, "A and B respawn")
				t.eq(run.spawned[2].cframe, CharacterService.SpawnCFrame(L2, 1), "slot 1 on Level 2")
				t.eq(run.spawned[3].cframe, CharacterService.SpawnCFrame(L2, 2), "slot 2 on Level 2")
				t.eq(
					table.concat(run.sealed, ","),
					"Level0_Basement>Level1_Hallways,Level1_Hallways>Level2_ScienceHall"
				)
			end)
		end)
	end,

	["live: an empty vestibule resets at the deadline; a level skip resets; a leaving straggler seals at once"] = function(
		t: Expect
	)
		local a, rootA = fakePlayer()
		local b, rootB = fakePlayer()
		inRun({ a, b }, function(run: Run)
			local clock = run.clock
			local door = exitDoor(L0)
			place(rootA, insideOf(L0))
			CheckpointAirlockService.Poll()
			t.eq(CheckpointAirlockService.GetPhase(), "Waiting")
			place(rootA, FAR)
			CheckpointAirlockService.Poll()
			t.eq(CheckpointAirlockService.GetPhase(), "Waiting", "stepping back out keeps the timer running")
			clock.advance(STRAGGLER + 0.5)
			CheckpointAirlockService.Poll()
			t.eq(CheckpointAirlockService.GetPhase(), "Idle", "nobody inside at the deadline: back to Idle")
			t.eq(door:GetAttribute(W.StragglerDeadline), nil, "the countdown is gone")
			t.eq(CheckpointAirlockService.GetDeadline(), nil)
			t.eq(DoorService.GetState(door), "Open", "the doors never sealed")

			place(rootA, insideOf(L0))
			CheckpointAirlockService.Poll()
			t.eq(CheckpointAirlockService.GetPhase(), "Waiting", "the next arrival starts it again")
			t.truthy(LevelDirector.EnterLevel(L1), "a dev level skip")
			CheckpointAirlockService.Poll()
			t.eq(CheckpointAirlockService.GetPhase(), "Idle", "resets for the new level")
			t.eq(door:GetAttribute(W.StragglerDeadline), nil, "the old countdown is cleared")
			t.eq(DoorService.GetState(door), "Open")

			place(rootA, insideOf(L1))
			place(rootB, FAR)
			CheckpointAirlockService.Poll()
			t.eq(CheckpointAirlockService.GetPhase(), "Waiting", "B is still out")
			CheckpointAirlockService.OnPlayerRemoving(b)
			t.eq(CheckpointAirlockService.GetPhase(), "Sealing", "B left: everyone left is inside, sealed at once")
			runDoors(clock, LEAD + CheckpointAirlockService.SealSeconds + 0.05)
			CheckpointAirlockService.Poll()
			t.eq(LevelDirector.GetCurrentLevel(), L2)
			t.eq(#run.cleared, 1)
			t.eq(names(run.cleared[1].survivors), a.Name, "only A")
			t.eq(#run.despawned, 0, "B was not left behind: B left")
			t.eq(#run.spawned, 0, "and is not respawned")
		end)
	end,

	["live: the dev seal works from Idle, not twice; the roof never seals"] = function(t: Expect)
		local a = fakePlayer()
		inRun({ a }, function(run: Run)
			local clock = run.clock
			local door = exitDoor(L0)
			capture(function(sent: { Sent })
				t.truthy(CheckpointAirlockService.Seal(), "seal now")
				t.eq(CheckpointAirlockService.GetPhase(), "Sealing")
				t.eq(DoorService.GetState(door), "Locked")
				t.eq(door:GetAttribute(W.StragglerDeadline), clock.now(), "as if the timer ran out just now")
				t.falsy(CheckpointAirlockService.Seal(), "not twice")
				runDoors(clock, LEAD + CheckpointAirlockService.SealSeconds + 0.05)
				CheckpointAirlockService.Poll()
				t.eq(LevelDirector.GetCurrentLevel(), L1)
				t.eq(names(run.despawned), a.Name, "A was outside: left behind")
				t.eq(#run.spawned, 1, "and respawned on Level 1")
				t.eq(LifeStateService.GetState(a), "Alive")
				t.eq(table.concat(notified(sent, a), ","), "Airlock.LeftBehind,Checkpoint.Respawned")
			end)
			t.truthy(LevelDirector.EnterLevel(L5), "the roof")
			CheckpointAirlockService.Poll()
			t.eq(CheckpointAirlockService.GetPhase(), "Idle")
			t.falsy(CheckpointAirlockService.Seal(), "the roof has no exit airlock")
			clock.advance(60)
			CheckpointAirlockService.Poll()
			t.eq(CheckpointAirlockService.GetPhase(), "Idle", "and stays Idle")
		end)
	end,

	["client: the banner counts down inside, hurries the ones outside, says Sealing, hides in cutscenes"] = function(
		t: Expect
	)
		t.eq(AirlockController.bannerState(nil, false), "Hidden", "no deadline, no banner")
		t.eq(AirlockController.bannerState(nil, true), "Hidden", "a sealed door alone shows nothing")
		t.eq(AirlockController.bannerState(1020, false), "Waiting")
		t.eq(AirlockController.bannerState(1020, true), "Sealing")
		t.eq(AirlockController.bannerState(math.huge, false), "Hidden", "a broken deadline")
		t.eq(AirlockController.bannerText("Waiting", true, 13.2), Strings.get("Airlock.Waiting", "0:14"))
		t.eq(
			AirlockController.bannerText("Waiting", true, 13.2),
			"Waiting for the squad " .. utf8.char(0x2014) .. " 0:14"
		)
		t.eq(AirlockController.bannerText("Waiting", false, 13.2), Strings.get("Airlock.GetIn", "0:14"))
		t.eq(AirlockController.bannerText("Waiting", false, -3), Strings.get("Airlock.GetIn", "0:00"), "never below 0")
		t.eq(AirlockController.bannerText("Sealing", false, 0), Strings.get("Airlock.Sealing"))
		t.eq(AirlockController.bannerText("Hidden", true, 5), "")
		for _, key in { "Airlock.Waiting", "Airlock.GetIn", "Airlock.Sealing", "Airlock.LeftBehind" } do
			t.truthy(Strings.has(key), key)
		end
		t.near(AirlockController.remainingFraction(STRAGGLER), 1, 1e-9, "full when it starts")
		t.near(AirlockController.remainingFraction(STRAGGLER / 2), 0.5, 1e-9)
		t.eq(AirlockController.remainingFraction(-1), 0, "empty at the deadline")
		t.truthy(AirlockController.urgent("Waiting", false, 3), "outside in the last seconds")
		t.falsy(AirlockController.urgent("Waiting", true, 3), "inside, no rush")
		t.falsy(AirlockController.urgent("Waiting", false, AirlockController.UrgentSeconds + 1), "not yet")
		t.falsy(AirlockController.urgent("Sealing", false, 0))
		t.truthy(AirlockController.visible(true, "OnFoot", "None"))
		t.falsy(AirlockController.visible(false, "OnFoot", "None"), "the HUD is hidden")
		t.falsy(AirlockController.visible(true, "Cutscene", "None"), "a cutscene")
		t.falsy(AirlockController.visible(true, "OnFoot", "Cutscene"), "a cutscene lock")
		t.falsy(AirlockController.visible(true, "OnFoot", "Jumpscare"), "a jumpscare")
		t.truthy(AirlockController.visible(true, "Trapped", "Trap"), "caught in a trap you still see it")
	end,
}
