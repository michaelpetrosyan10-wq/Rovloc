--!strict
-- MonsterAIService live, on the real Creature rig with a fake clock and a fake movement engine (the Lune harness has
-- no physics: roots move only when the service places them). Attribute writes (every Creature attribute and the view
-- contract, StateSince on every change), waking into Patrol after a level activates (and the airlock grace keeping
-- noises from turning into investigations), alerts, stuns, the scripted handle (exclusive, poses, hiding and the
-- unseen reveal, a dead handle after Release), the stuck reposition, a hallway catch through JumpscareHandler (the
-- brain holds still while it plays, then withdraws on the cooldown), the dev commands, the spawn rule's grace, and the
-- fairness rules (docs/MONSTER.md 13): no catch through a wall, the 22 s give-up (a FadeOut, back far away and out of
-- sight), teleports never into view nor within 12 studs and never while the game blocks them, the HidingResponse's
-- LookAway escape, its ReachIn at 30 s, and a teammate's pull-out that is no catch.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local CreatureRigBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.CreatureRigBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)

local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local MonsterAIService = require(ServerScriptService.Services.Monster.MonsterAIService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local HidingResponse = require(ServerScriptService.Services.Monster.MonsterAIService.States.HidingResponse)
local Brain = require(ServerScriptService.Services.Monster.MonsterAIService.Brain)
local FloorNav = require(ServerScriptService.Services.Monster.MonsterAIService.FloorNav)
local CreatureBody = require(ServerScriptService.Services.Monster.MonsterAIService.CreatureBody)
local JumpscareHandler = require(ServerScriptService.Services.Monster.MonsterAIService.JumpscareHandler)
local Locomotion = require(ServerScriptService.Services.Monster.MonsterAIService.Locomotion)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local SpawnRule = require(ServerScriptService.Services.Monster.MonsterAIService.SpawnRule)

type Expect = SpecRunner.Expect

type Timer = { at: number, callback: () -> (), thread: thread, cancelled: boolean }

type Clock = {
	now: () -> number,
	advance: (seconds: number) -> (),
	clock: JumpscareHandler.Clock,
}

type World = {
	model: Model,
	root: BasePart,
	hitbox: BasePart,
	clock: Clock,
	moves: { Vector3 },
	changes: { string },
}

local C = Attributes.Creature
local NAMES = CreatureRigBuilder.PartNames
local LEVEL: Enums.LevelId = "Level1_Hallways"
local EPS = 1e-3
local TICK = 1 / GameConfig.ServerTickHz

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function fakeClock(start: number): Clock
	local now = start
	local timers: { Timer } = {}
	local clock: JumpscareHandler.Clock = {
		now = function(): number
			return now
		end,
		delay = function(seconds: number, callback: () -> ()): thread
			local thread = coroutine.create(function() end)
			table.insert(
				timers,
				{ at = now + math.max(0, seconds), callback = callback, thread = thread, cancelled = false }
			)
			return thread
		end,
		cancel = function(thread: thread)
			for _, timer in timers do
				if timer.thread == thread then
					timer.cancelled = true
				end
			end
		end,
	}
	local function advance(seconds: number)
		local target = now + seconds
		while true do
			local due: Timer? = nil
			for _, timer in timers do
				if not timer.cancelled and timer.at <= target and (due == nil or timer.at < (due :: Timer).at) then
					due = timer
				end
			end
			if not due then
				break
			end
			due.cancelled = true
			now = math.max(now, due.at)
			due.callback()
		end
		now = target
	end
	return {
		now = function(): number
			return now
		end,
		advance = advance,
		clock = clock,
	}
end

local function quietBuild(parent: Instance, cframe: CFrame): Model
	local previous = Geometry.getYieldEvery()
	Geometry.setYieldEvery(0)
	local ok, built = pcall(CreatureRigBuilder.build, parent, cframe)
	Geometry.setYieldEvery(previous)
	if not ok then
		error(built, 0)
	end
	return built :: Model
end

local function part(model: Model, name: string): BasePart
	local found = model:FindFirstChild(name)
	assert(found and found:IsA("BasePart"), model.Name .. " has " .. name)
	return found
end

local function near(a: Vector3, b: Vector3, epsilon: number?): boolean
	return (a - b).Magnitude <= (epsilon or EPS)
end

local nextUserId = 9700

local function fakePlayer(at: CFrame, dev: boolean): (Player, BasePart)
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "MonsterSpec" .. nextUserId
	local writable = player :: any
	writable.UserId = nextUserId
	player:SetAttribute("DevTools", dev)
	local model = Instance.new("Model")
	model.Name = player.Name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = at
	-- the harness only answers BasePart.Position once it was written (LifeStateService's gasp cue reads it)
	root.Position = at.Position
	root.Parent = model
	model.PrimaryPart = root
	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = GameConfig.MaxHealth
	humanoid.Health = GameConfig.MaxHealth
	humanoid.Parent = model
	player.Character = model
	return player, root
end

-- A fake engine: straight-line routes, MoveTo recorded (the root never moves on its own here).
local function fakeEngine(moves: { Vector3 }): Locomotion.Engine
	return {
		computePath = function(from: Vector3, to: Vector3): Locomotion.ComputedPath?
			return { waypoints = { from, to } }
		end,
		moveTo = function(_humanoid: Humanoid, position: Vector3)
			table.insert(moves, position)
		end,
		configure = function(_humanoid: Humanoid) end,
		clear = function(_from: Vector3, _to: Vector3, _ignore: { Instance }): boolean
			return true
		end,
	}
end

local function levelContext(run: Types.RunContext): Types.LevelContext
	return { levelId = LEVEL, run = run, root = Instance.new("Model"), runtime = Instance.new("Folder") }
end

-- Runs `body` in a run on `participants` with the Creature rig attached on Level 1 (in Workspace when `inWorld`),
-- and always tears everything down.
local function inRun(participants: { Player }, inWorld: boolean, body: (world: World, run: Types.RunContext) -> ())
	Net.Server.setup()
	MonsterAIService.Init()
	local clock = fakeClock(7000)
	MonsterAIService.SetClock(clock.now)
	JumpscareHandler.SetClock(clock.clock)
	LifeStateService.SetClock(clock.clock)
	local moves: { Vector3 } = {}
	MonsterAIService.SetEngine(fakeEngine(moves))
	local run: Types.RunContext = {
		runId = "monster-ai-spec",
		seed = 7,
		difficulty = "Standard",
		participants = participants,
		startedAt = 7000,
	}
	LifeStateService.BeginRun(run)
	local host: Instance = if inWorld then Workspace else Instance.new("Folder")
	local model = quietBuild(host, CFrame.new(0, 200, 0))
	model:SetAttribute(C.LevelId, LEVEL)
	model:SetAttribute(C.MonsterState, "Dormant")
	local changes: { string } = {}
	local connection = MonsterAIService.StateChanged:Connect(function(new: Enums.MonsterState, old: Enums.MonsterState)
		table.insert(changes, old .. ">" .. new)
	end)
	local failure: string? = nil
	xpcall(function()
		MonsterAIService.BeginRun(run)
		MonsterAIService.Attach(model)
		body({
			model = model,
			root = part(model, NAMES.Root),
			hitbox = part(model, NAMES.Hitbox),
			clock = clock,
			moves = moves,
			changes = changes,
		}, run)
	end, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end)
	connection:Disconnect()
	JumpscareHandler.Abort("SpecTeardown")
	MonsterAIService.EndRun()
	LifeStateService.EndRun()
	for _, player in participants do
		LifeStateService.OnPlayerRemoving(player)
		MonsterAIService.OnPlayerRemoving(player)
	end
	MonsterAIService.SetEngine(nil)
	MonsterAIService.SetLineClear(nil)
	MonsterAIService.RegisterHideSpots(nil)
	MonsterAIService.SetClock(nil)
	JumpscareHandler.SetClock(nil)
	LifeStateService.SetClock(nil)
	model:Destroy()
	if failure then
		error(failure, 0)
	end
end

-- Ticks the brain and the movement together for `seconds` of fake time.
local function run(world: World, seconds: number)
	local steps = math.max(1, math.floor(seconds / TICK + 0.5))
	for _ = 1, steps do
		world.clock.advance(TICK)
		MonsterAIService.StepMotion(TICK)
		MonsterAIService.Step(TICK)
	end
end

local function wake(world: World, runContext: Types.RunContext)
	LevelDirector.LevelActivated:Fire(LEVEL, levelContext(runContext))
	run(world, MonsterAIService.WakeDelay + 0.3)
end

local function attr(model: Model, key: string): any
	return model:GetAttribute(key)
end

local function spawnCFrame(): CFrame
	local layout = Builder.getLayout(LEVEL)
	assert(layout, "Level 1 layout")
	local info = Brain.levelInfo(layout)
	assert(info and info.spawn, "Level 1 spawn")
	return info.spawn :: CFrame
end

--------------------------------------------------------------------------------
-- Spec
--------------------------------------------------------------------------------

local spec = {}

spec["attributes: placed Dormant at its level's CreatureSpawn with every attribute written"] = function(t: Expect)
	inRun({}, false, function(world: World)
		local model = world.model
		t.eq(attr(model, C.MonsterState), "Dormant", "MonsterState")
		t.eq(attr(model, C.StateSince), 7000, "StateSince is the server time")
		-- standing still, it hunches where the head room at its root is under HunchBelow (a tunnel's ceiling)
		local nav = MonsterAIService.GetNav(LEVEL)
		assert(nav, "Level 1's nav")
		local headroom = nav:clearanceAt(spawnCFrame().Position)
		t.eq(
			attr(model, C.PoseMode),
			if headroom < CreatureConfig.HunchBelow then "Hunched" else "Biped",
			string.format("PoseMode under %.1f studs of head room", headroom)
		)
		t.eq(attr(model, C.TargetUserId), 0, "no target")
		t.eq(attr(model, C.InVent), false, "never in a duct")
		t.eq(attr(model, C.Action), "", "no action")
		t.eq(attr(model, C.Hidden), false, "Hidden")
		t.eq(attr(model, C.GrabbedUserId), 0, "no grab")
		t.eq(attr(model, C.LevelId), LEVEL, "LevelId")
		t.truthy(near(world.root.CFrame.Position, spawnCFrame().Position), "at the CreatureSpawn")
		t.truthy(world.root.Anchored, "held still while dormant")
		t.eq(MonsterAIService.GetState(), "Dormant", "GetState")
		t.eq(MonsterAIService.GetTarget(), nil, "GetTarget")
		t.eq(MonsterAIService.GetCreature(), model, "drives the attached rig")
		run(world, 3)
		t.eq(attr(model, C.MonsterState), "Dormant", "stays asleep until its level activates")
		MonsterAIService.Stun(6, Vector3.new(0, 0, 0))
		t.eq(attr(model, C.MonsterState), "Dormant", "a sleeping Creature is not stunned")
	end)
end

spec["wake: a level activation wakes it into Patrol; the airlock grace turns noises into breathers"] = function(
	t: Expect
)
	inRun({}, false, function(world: World, runContext: Types.RunContext)
		local model = world.model
		LevelDirector.LevelActivated:Fire(LEVEL, levelContext(runContext))
		run(world, MonsterAIService.WakeDelay - 0.5)
		t.eq(attr(model, C.MonsterState), "Dormant", "still waking")
		run(world, 1)
		t.eq(attr(model, C.MonsterState), "Patrol", "patrols after the wake delay")
		t.near(
			attr(model, C.StateSince),
			7000 + MonsterAIService.WakeDelay,
			TICK + EPS,
			"StateSince is the moment it woke"
		)
		run(world, 0.2)
		t.falsy(world.root.Anchored, "walking frees the root")
		t.truthy(#world.moves > 0, "the Humanoid was sent toward a waypoint")
		local since = attr(model, C.StateSince)
		MonsterAIService.Alert(world.root.CFrame.Position + Vector3.new(20, 0, 0), "Critical")
		run(world, 0.2)
		t.eq(attr(model, C.MonsterState), "Patrol", "the airlock grace: no investigation")
		t.eq(attr(model, C.StateSince), since, "no change, no new StateSince")
		run(world, 13)
		MonsterAIService.Alert(world.root.CFrame.Position + Vector3.new(20, 0, 0), "High")
		run(world, 0.2)
		t.eq(attr(model, C.MonsterState), "InvestigateNoise", "after the grace a noise is investigated")
		t.truthy(table.find(world.changes, "Dormant>Patrol") ~= nil, "StateChanged Dormant -> Patrol")
		t.truthy(table.find(world.changes, "Patrol>InvestigateNoise") ~= nil, "StateChanged Patrol -> Investigate")
	end)
end

spec["stun: blinded at once, no hunting, then a withdrawal into Patrol"] = function(t: Expect)
	inRun({}, false, function(world: World, runContext: Types.RunContext)
		local model = world.model
		wake(world, runContext)
		run(world, 13)
		MonsterAIService.Stun(GameConfig.StunSeconds, world.root.CFrame.Position + Vector3.new(0, 0, 6))
		t.eq(attr(model, C.MonsterState), "Stunned", "stunned immediately")
		t.eq(attr(model, C.StateSince), world.clock.now(), "StateSince")
		run(world, 1)
		MonsterAIService.Alert(world.root.CFrame.Position + Vector3.new(10, 0, 0), "Critical")
		run(world, 0.2)
		t.eq(attr(model, C.MonsterState), "Stunned", "a stunned Creature ignores noise")
		t.eq(attr(model, C.TargetUserId), 0, "and targets nobody")
		MonsterAIService.Stun(GameConfig.StunSeconds, Vector3.new(0 / 0, 0, 0))
		run(world, GameConfig.StunSeconds - 1)
		t.eq(attr(model, C.MonsterState), "Patrol", "recovered: withdraws and patrols")
	end)
end

spec["scripted: exclusive handle, poses, hiding, teleport; release reveals it unseen and kills the handle"] = function(
	t: Expect
)
	inRun({}, false, function(world: World, runContext: Types.RunContext)
		local model = world.model
		wake(world, runContext)
		local handle = MonsterAIService.AcquireScripted("Spec")
		assert(handle, "acquired")
		t.eq(attr(model, C.MonsterState), "Scripted", "Scripted")
		t.eq(MonsterAIService.AcquireScripted("Other"), nil, "exclusive")
		t.eq(MonsterAIService.AcquireScripted("Spec"), handle, "the same token gets its handle back")
		handle:SetPose("Hunched")
		t.eq(attr(model, C.PoseMode), "Hunched", "PoseMode follows the handle")
		t.truthy(near(world.hitbox.Size, CreatureConfig.Hitbox.Hunched), "the hitbox follows the pose")
		t.eq(attr(model, C.TargetUserId), 0, "a cutscene targets nobody")
		handle:SetHidden(true)
		t.eq(attr(model, C.Hidden), true, "Hidden")
		t.falsy(world.hitbox.CanQuery, "a hidden Creature's hitbox answers no queries")
		local pose = CFrame.new(150, 23, 40) * CFrame.Angles(0, math.rad(45), 0)
		handle:Teleport(pose)
		t.truthy(near(world.root.CFrame.Position, pose.Position), "teleported")
		t.truthy(world.root.Anchored, "held where the cutscene put it")
		t.eq(attr(model, C.PoseMode), "Hunched", "a teleport keeps the cutscene's pose")
		MonsterAIService.Alert(pose.Position + Vector3.new(5, 0, 0), "Critical")
		run(world, 1)
		t.eq(attr(model, C.MonsterState), "Scripted", "the brain is paused")
		handle:Release("Patrol")
		t.eq(attr(model, C.MonsterState), "Patrol", "released into Patrol")
		run(world, 0.2)
		t.eq(attr(model, C.Hidden), false, "reappears once nobody can see it")
		t.truthy(world.hitbox.CanQuery, "queryable again")
		handle:SetPose("Swim")
		t.eq(attr(model, C.PoseMode), "Biped", "a released handle does nothing")
		local again = MonsterAIService.AcquireScripted("Other")
		t.truthy(again ~= nil, "free to acquire again")
		if again then
			again:Release(nil)
		end
	end)
end

spec["stuck: a Creature that stops making progress is moved unseen to a patrol spot"] = function(t: Expect)
	inRun({}, false, function(world: World, runContext: Types.RunContext)
		wake(world, runContext)
		local start = world.root.CFrame.Position
		run(world, CreatureConfig.Repath.StuckSeconds * 2 + 1)
		local here = world.root.CFrame.Position
		t.truthy((here - start).Magnitude >= 5, "moved off the spot it was stuck on")
		local layout = Builder.getLayout(LEVEL)
		local info = if layout then Brain.levelInfo(layout) else nil
		assert(info, "Level 1 info")
		local onSpot = false
		for _, waypoint in info.waypoints do
			if near(here, waypoint.position + Vector3.new(0, CreatureBody.RootHeight, 0), 0.01) then
				onSpot = true
			end
		end
		t.truthy(onSpot, "onto a patrol waypoint at standing height")
		t.eq(attr(world.model, C.MonsterState), "Patrol", "and patrols on from there")
	end)
end

spec["catch: a hallway catch in reach plays through JumpscareHandler, then the Creature withdraws"] = function(
	t: Expect
)
	local spawnPosition = spawnCFrame().Position
	local floor = Vector3.new(spawnPosition.X, WorldConfig.levelElevation(LEVEL), spawnPosition.Z)
	local victim = fakePlayer(CFrame.new(floor + Vector3.new(3, 3, 0)), true)
	inRun({ victim }, true, function(world: World, runContext: Types.RunContext)
		local model = world.model
		wake(world, runContext)
		world.root.CFrame = CFrame.lookAt(world.root.CFrame.Position, world.root.CFrame.Position + Vector3.new(1, 0, 0))
		local caughtKind: string? = nil
		local connection = MonsterAIService.Caught:Connect(function(player: Player, kind: Enums.JumpscareKind)
			if player == victim then
				caughtKind = kind
			end
		end)
		local key = DevToolsService.Execute(victim, "hunt", {})
		t.eq(key, "Dev.Ok", "hunt answered")
		t.eq(attr(model, C.TargetUserId), victim.UserId, "targets the caller")
		run(world, 0.2)
		connection:Disconnect()
		t.eq(caughtKind, "Hallway", "caught in the hallway")
		t.truthy(JumpscareHandler.IsBusy(), "the jumpscare is playing")
		run(world, 0.5)
		t.eq(attr(model, C.MonsterState), "WallChase", "holds its state while the catch plays")
		run(world, CreatureConfig.Jumpscare.LungeSeconds + CreatureConfig.Jumpscare.HoldSeconds + 0.5)
		t.falsy(JumpscareHandler.IsBusy(), "the catch is over")
		t.eq(LifeStateService.GetState(victim), "Downed", "a first catch downs")
		t.eq(attr(model, C.MonsterState), "Patrol", "the cooldown: it withdraws")
		local _, reply = DevToolsService.Execute(victim, "ai", {})
		t.truthy(string.find(reply[1], "cooldown", 1, true) ~= nil, "the cooldown shows in ai: " .. reply[1])
	end)
end

spec["dev commands: ai shows and forces states, pause holds it, ignoreme hides you"] = function(t: Expect)
	local dev = fakePlayer(CFrame.new(150, 21, 80), true)
	dev:SetAttribute("LevelId", LEVEL)
	inRun({ dev }, false, function(world: World)
		local model = world.model
		local function ai(...: string): string
			local key, reply = DevToolsService.Execute(dev, "ai", { ... })
			t.eq(key, "Dev.Ok", "ai answered")
			return reply[1]
		end
		t.truthy(string.find(ai(), "Dormant", 1, true) ~= nil, "ai shows the state")
		t.truthy(string.find(ai("Bogus"), "usage", 1, true) ~= nil, "unknown words get the usage")
		t.truthy(string.find(ai("Scripted"), "AcquireScripted", 1, true) ~= nil, "Scripted is only for cutscenes")
		ai("Patrol")
		t.eq(attr(model, C.MonsterState), "Patrol", "ai Patrol wakes it")
		ai("InvestigateNoise")
		t.eq(attr(model, C.MonsterState), "InvestigateNoise", "ai InvestigateNoise searches where you stand")
		t.truthy(string.find(ai("HidingResponse"), "not in a hiding spot", 1, true) ~= nil, "it needs a hider")
		ai("Search")
		t.eq(attr(model, C.MonsterState), "Search", "ai Search searches where you stand")
		t.truthy(string.find(ai("AquaticStalk"), "no pool", 1, true) ~= nil, "no pool on Level 1")
		ai("pause")
		t.truthy(MonsterAIService.IsPaused(), "paused")
		local since = attr(model, C.StateSince)
		MonsterAIService.Alert(Vector3.new(100, 21, 80), "Critical")
		run(world, 1)
		t.eq(attr(model, C.StateSince), since, "a paused brain changes nothing")
		ai("resume")
		t.falsy(MonsterAIService.IsPaused(), "resumed")
		local _, ignore = DevToolsService.Execute(dev, "ignoreme", {})
		t.truthy(string.find(ignore[1], "ignores you", 1, true) ~= nil, "ignoreme on")
		local _, hunt = DevToolsService.Execute(dev, "hunt", {})
		t.truthy(string.find(hunt[1], "ignoring", 1, true) ~= nil, "an ignored player cannot be hunted")
		local _, back = DevToolsService.Execute(dev, "ignoreme", {})
		t.truthy(string.find(back[1], "notices", 1, true) ~= nil, "ignoreme off")
		ai("Dormant")
		t.eq(attr(model, C.MonsterState), "Dormant", "ai Dormant puts it to sleep")
		local _, tp = DevToolsService.Execute(dev, "ai", { "tp" })
		t.truthy(string.find(tp[1], "brought", 1, true) ~= nil, "ai tp: " .. tp[1])
		local distance = (world.root.CFrame.Position - CFrame.new(150, 21, 80).Position).Magnitude
		t.truthy(distance >= 15 and distance <= 65, "brought near the caller")
		t.eq(attr(model, C.MonsterState), "Patrol", "and patrolling")
	end)
end

spec["locomotion: walks fail after two routes are refused; the water is entered only by a warp"] = function(t: Expect)
	local folder = Instance.new("Folder")
	local model = quietBuild(folder, CFrame.new(0, 0, 0))
	local body = CreatureBody.attach(model)
	assert(body, "a body")
	local now = 0
	local engine = fakeEngine({})
	engine.computePath = function(_from: Vector3, _to: Vector3): Locomotion.ComputedPath?
		return nil
	end
	engine.clear = function(_from: Vector3, _to: Vector3, _ignore: { Instance }): boolean
		return false
	end
	local warps: { string } = {}
	local warpRunning = false
	local hooks: Locomotion.Hooks = {
		warp = function(_goal: Vector3, medium: Locomotion.Medium): boolean
			table.insert(warps, medium)
			warpRunning = true
			return true
		end,
		warping = function(): boolean
			return warpRunning
		end,
	}
	local mover = Locomotion.new(body, engine, hooks, function(): number
		return now
	end)
	mover:GoTo(Vector3.new(100, 0, 0), nil)
	t.eq(mover:Status(), "Moving", "on its way")
	for _ = 1, 5 do
		now += 0.1
		mover:Step(0.1)
	end
	t.eq(mover:Status(), "Failed", "no route: failed")
	mover:Reset("Floor")
	t.eq(mover:Status(), "Idle", "reset")
	local basin: Locomotion.Basin = {
		id = "Spec",
		minX = 20,
		maxX = 40,
		minZ = -10,
		maxZ = 10,
		surfaceY = -1,
		floorY = -6,
		deckY = 0,
		fadeOnly = true,
	}
	mover:SetLevel({ basin })
	mover:GoTo(Vector3.new(30, -3, 0), nil)
	now += 0.1
	mover:Step(0.1)
	t.eq(#warps, 1, "a goal in the water starts a warp, never a walk down the deck")
	t.eq(warps[1], "Water", "into the water")
	t.truthy(mover:Busy(), "the warp leg cannot be interrupted")
	warpRunning = false
	mover:Destroy()
	model:Destroy()
end

spec["spawns: on Level 2 it starts at the spawn rule's pick, waits its grace, and a loud noise ends it"] = function(
	t: Expect
)
	local player = fakePlayer(CFrame.new(0, -600, 0), false)
	inRun({ player }, false, function(world: World, runContext: Types.RunContext)
		local level: Enums.LevelId = "Level2_ScienceHall"
		local layout = Builder.getLayout(level)
		assert(layout, "Level 2 layout")
		local entry = LevelDirector.entryFor(level)
		local choice = SpawnRule.choose(runContext.seed, layout, nil, if entry then entry.toRoom else layout.entry)
		local candidate = choice.candidate
		assert(candidate, "a spawn")
		local levelCtx: Types.LevelContext =
			{ levelId = level, run = runContext, root = Instance.new("Model"), runtime = Instance.new("Folder") }
		LevelDirector.LevelActivated:Fire(level, levelCtx)
		run(world, 1)
		local at = WorldConfig.levelOrigin(level) + candidate.pos
		local here = world.root.CFrame.Position
		t.truthy(
			Vector3.new(here.X - at.X, 0, here.Z - at.Z).Magnitude < 0.5,
			"placed at " .. candidate.id .. ", not the level's CreatureSpawn"
		)
		t.eq(attr(world.model, C.Hidden), false, "shown once nobody sees it")
		run(world, ObjectiveConfig.graceFor("Standard") - 3)
		t.eq(attr(world.model, C.MonsterState), "Dormant", "it waits out its grace")
		NoiseAndDirectorService.Emit(at + Vector3.new(40, 0, 0), "Gasp", { sourcePlayer = player, levelId = level })
		run(world, 0.3)
		t.truthy(attr(world.model, C.MonsterState) ~= "Dormant", "a participant's loud noise ends the grace")
	end)
	LifeStateService.OnPlayerRemoving(player)
end

spec["spawns: without a noise the grace runs its full length"] = function(t: Expect)
	inRun({}, false, function(world: World, runContext: Types.RunContext)
		local level: Enums.LevelId = "Level3_Gymnasium"
		local levelCtx: Types.LevelContext =
			{ levelId = level, run = runContext, root = Instance.new("Model"), runtime = Instance.new("Folder") }
		LevelDirector.LevelActivated:Fire(level, levelCtx)
		run(world, ObjectiveConfig.graceFor("Standard") - 0.5)
		t.eq(attr(world.model, C.MonsterState), "Dormant", "still in its grace")
		run(world, 1)
		t.eq(attr(world.model, C.MonsterState), "Patrol", "then it patrols")
	end)
end

--------------------------------------------------------------------------------
-- Fairness (docs/MONSTER.md 13)
--------------------------------------------------------------------------------

local function flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-6 then f.Unit else Vector3.new(0, 0, -1)
end

-- Puts a fake player's root (3 studs over the floor) at `floor`.
local function placeAt(player: Player, floor: Vector3)
	local character = player.Character
	local root = character and character.PrimaryPart
	assert(root, player.Name .. " has a root")
	root.CFrame = CFrame.new(floor + Vector3.new(0, 3, 0))
	root.Position = floor + Vector3.new(0, 3, 0)
end

local function rootOf(player: Player): Vector3
	local character = player.Character
	local root = character and character.PrimaryPart
	assert(root, player.Name .. " has a root")
	return root.CFrame.Position
end

-- The way (+X, -X, +Z or -Z, in that order) along which the floor runs straight on from `from` for `reach` studs, every
-- stud of it in a walkable room the player can be seen in (never a crawlway), or nil: a tunnel runs one or two ways
-- from a point in it, and the rock between the tunnels has no floor.
local function floorRun(nav: FloorNav.Nav, from: Vector3, reach: number): Vector3?
	for _, way in { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) } do
		local clear = true
		for s = 1, reach do
			local room = nav:roomAt(from + way * s)
			if not room or room.kind == "Crawlway" or room.kind == "Solid" then
				clear = false
				break
			end
		end
		if clear then
			return way
		end
	end
	return nil
end

-- Walls: a sight line longer than `reach` studs is blocked.
local function wallsBeyond(reach: number)
	MonsterAIService.SetLineClear(function(from: Vector3, to: Vector3, _ignore: Instance?): boolean
		return (to - from).Magnitude <= reach
	end)
end

-- Runs until `done()` or `limit` seconds; returns the seconds it took (math.huge when it never happened).
local function runUntil(world: World, limit: number, done: () -> boolean): number
	local started = world.clock.now()
	while world.clock.now() - started < limit do
		run(world, TICK)
		if done() then
			return world.clock.now() - started
		end
	end
	return math.huge
end

spec["fairness: never a catch through a wall, eye to eye and chest to chest"] = function(t: Expect)
	local spawnPosition = spawnCFrame().Position
	local floor = Vector3.new(spawnPosition.X, WorldConfig.levelElevation(LEVEL), spawnPosition.Z)
	local victim = fakePlayer(CFrame.new(floor + Vector3.new(3, 3, 0)), true)
	inRun({ victim }, true, function(world: World, runContext: Types.RunContext)
		wake(world, runContext)
		world.root.CFrame = CFrame.lookAt(world.root.CFrame.Position, world.root.CFrame.Position + Vector3.new(1, 0, 0))
		local caughtKind: string? = nil
		local connection = MonsterAIService.Caught:Connect(function(player: Player, kind: Enums.JumpscareKind)
			if player == victim then
				caughtKind = kind
			end
		end)
		MonsterAIService.SetLineClear(function(_from: Vector3, _to: Vector3, _ignore: Instance?): boolean
			return false
		end)
		DevToolsService.Execute(victim, "hunt", {})
		run(world, 2)
		t.eq(caughtKind, nil, "a wall between them: no catch within reach")
		-- a counter 4 studs high just in front of them (80 % of the way): the eyes meet over it, the bodies do not
		local counterTop = rootOf(victim).Y + 1
		MonsterAIService.SetLineClear(function(from: Vector3, to: Vector3, _ignore: Instance?): boolean
			return from.Y + (to.Y - from.Y) * 0.8 > counterTop
		end)
		DevToolsService.Execute(victim, "hunt", {})
		run(world, 1)
		t.eq(caughtKind, nil, "no catch over a counter")
		t.eq(attr(world.model, C.MonsterState), "WallChase", "it still chases what it sees")
		MonsterAIService.SetLineClear(nil)
		run(world, 0.3)
		connection:Disconnect()
		t.eq(caughtKind, "Hallway", "the same reach in the open catches")
	end)
end

spec["fairness: a chase gives up at 22 s, fades out, and comes back 45+ studs away out of sight"] = function(t: Expect)
	local player = fakePlayer(CFrame.new(0, -600, 0), false)
	inRun({ player }, true, function(world: World, runContext: Types.RunContext)
		wake(world, runContext)
		run(world, 13) -- the airlock grace
		wallsBeyond(40)
		-- the spawn stands in a tunnel: the player stands 15 studs down it, the Creature facing them
		local nav = MonsterAIService.GetNav(LEVEL)
		assert(nav, "Level 1's nav")
		local start = world.root.CFrame.Position
		local along = floorRun(nav, start, 15)
		assert(along, "15 studs of tunnel floor from the spawn")
		world.root.CFrame = CFrame.lookAt(start, start + along)
		local floorY = start.Y - CreatureBody.RootHeight
		local ahead = start + along * 15
		placeAt(player, Vector3.new(ahead.X, floorY, ahead.Z))
		local gaveUpTarget: Player? = nil
		local connection = MonsterAIService.GaveUp:Connect(function(target: Player?, _at: Vector3)
			gaveUpTarget = target
		end)
		local toChase = runUntil(world, 2, function(): boolean
			return attr(world.model, C.MonsterState) == "WallChase"
		end)
		t.truthy(toChase < 2, "it sees them 15 studs ahead and chases")
		local chased = runUntil(world, 30, function(): boolean
			return attr(world.model, C.MonsterState) ~= "WallChase"
		end)
		t.near(chased, DifficultyConfig.Standard.maxChaseSeconds, 0.35, "it gives up at 22 s, still in sight")
		t.eq(attr(world.model, C.MonsterState), "Patrol", "and patrols on")
		t.eq(gaveUpTarget, player, "GaveUp names the one it chased")
		t.eq(attr(world.model, C.Action), "FadeOut", "it fades out where it stands")
		local hidden = runUntil(world, 2, function(): boolean
			return attr(world.model, C.Hidden) == true
		end)
		t.truthy(hidden < 1, "hidden once the fade is over")
		local back = runUntil(world, 15, function(): boolean
			return attr(world.model, C.Hidden) == false
		end)
		t.truthy(back < 15, "it comes back")
		connection:Disconnect()
		local here = world.root.CFrame.Position
		local eye = rootOf(player) + Vector3.new(0, 1.5, 0)
		t.truthy((here - eye).Magnitude >= CreatureConfig.GiveUp.MinDistance - 0.01, "at least 45 studs from them")
		t.truthy((here - eye).Magnitude > 40, "out of their sight (behind the walls)")
	end)
end

-- A floor point in a hallway (never a keep-room: a teleport never forms in the room you stand in) with several
-- teleport spots behind it (the player looks north, -Z), at least `away` studs from `from`.
local function standingWithRoomBehind(nav: FloorNav.Nav, from: Vector3, away: number): Vector3?
	local samples = nav:samplePoints(5)
	for i = 1, #samples, 3 do
		local p = samples[i].position
		local room = nav:roomAt(p + Vector3.new(0, 1, 0))
		if not room or room.kind ~= "Hallway" and room.kind ~= "Corridor" and room.kind ~= "Tunnel" then
			continue
		end
		if (Vector3.new(p.X, 0, p.Z) - Vector3.new(from.X, 0, from.Z)).Magnitude < away then
			continue
		end
		local behind = 0
		for j = 1, #samples, 2 do
			local q = samples[j].position
			local offset = Vector3.new(q.X - p.X, 0, q.Z - p.Z)
			if offset.Magnitude < 13 or offset.Magnitude > 22 or offset.Unit.Z < 0.2 then
				continue
			end
			local walk = nav:pathLength(p, q)
			if walk >= 13 and walk <= 23 then
				behind += 1
			end
		end
		if behind >= 4 then
			return p
		end
	end
	return nil
end

spec["fairness: a teleport lands 12..24 studs of walking away, never within 12 studs, never in view"] = function(
	t: Expect
)
	local player = fakePlayer(CFrame.new(0, -600, 0), true)
	inRun({ player }, true, function(world: World, runContext: Types.RunContext)
		wake(world, runContext)
		wallsBeyond(40)
		local nav = MonsterAIService.GetNav(LEVEL)
		assert(nav, "Level 1's nav")
		local chosen = standingWithRoomBehind(nav, world.root.CFrame.Position, 0)
		assert(chosen, "a spot to stand with room behind")
		local feet = chosen :: Vector3
		placeAt(player, feet)
		local warnings: { Vector3 } = {}
		local connection = MonsterAIService.TeleportWarning:Connect(
			function(at: Vector3, target: Player?, seconds: number)
				table.insert(warnings, at)
				t.eq(target, player, "the warning names its target")
				t.eq(seconds, CreatureConfig.Teleport.WarningSeconds, "1.6 s")
			end
		)
		local key, reply = DevToolsService.Execute(player, "ai", { "Teleport" })
		t.eq(key, "Dev.Ok", "ai Teleport answered")
		t.truthy(string.find(reply[1], "teleporting", 1, true) ~= nil, "a teleport was planned: " .. reply[1])
		local shownWhileHidden = false
		local ended = runUntil(world, 8, function(): boolean
			local fade = attr(world.model, C.Fade)
			if #warnings > 0 and attr(world.model, C.Hidden) == true and type(fade) == "number" and fade > 0 then
				shownWhileHidden = true
			end
			return #warnings > 0 and attr(world.model, C.Hidden) == false and attr(world.model, C.Fade) == 1
		end)
		connection:Disconnect()
		t.truthy(ended < 8, "it formed after the warning")
		t.eq(#warnings, 1, "one warning")
		t.falsy(shownWhileHidden, "invisible until the warning is over")
		t.eq(attr(world.model, C.MonsterState), "Teleport", "it stalks its target now")
		local here = world.root.CFrame.Position
		local theirs = rootOf(player)
		t.truthy((here - theirs).Magnitude >= CreatureConfig.Teleport.MinStraight - 0.01, "never within 12 studs")
		local floorHere = Vector3.new(here.X, feet.Y, here.Z)
		local walk = nav:pathLength(feet, floorHere)
		t.truthy(
			walk >= CreatureConfig.Teleport.MinWalk - 0.5,
			string.format("at least 12 studs of walking (%.1f)", walk)
		)
		t.truthy(walk <= CreatureConfig.Teleport.MaxWalk + 0.5, string.format("at most 24 (%.1f)", walk))
		local eye = theirs + Vector3.new(0, 1.5, 0)
		local look = Vector3.new(0, 0, -1)
		for _, lift in { 0, CreatureConfig.EyeHeightAboveRoot.Biped } do
			local q = here + Vector3.new(0, lift, 0)
			local angle = math.deg(math.acos(math.clamp(look:Dot((q - eye).Unit), -1, 1)))
			local blocked = (q - eye).Magnitude > 40
			t.truthy(
				angle > CreatureConfig.Teleport.ViewHalfAngle or blocked,
				string.format("out of view (%.0f deg)", angle)
			)
		end
	end)
end

spec["fairness: no teleport while the game blocks it (a survive countdown, the finale)"] = function(t: Expect)
	local player = fakePlayer(CFrame.new(0, -600, 0), false)
	inRun({ player }, true, function(world: World, runContext: Types.RunContext)
		wallsBeyond(40)
		local nav = MonsterAIService.GetNav(LEVEL)
		assert(nav, "Level 1's nav")
		local far = standingWithRoomBehind(nav, spawnCFrame().Position, 70)
		assert(far, "a hallway far from the Creature")
		placeAt(player, far)
		local blocked = true
		local unblock = MonsterAIService.RegisterTeleportBlock(function(): boolean
			return blocked
		end)
		LevelDirector.LevelActivated:Fire(LEVEL, levelContext(runContext))
		local grace = (CreatureConfig.FloorGrace.Standard or 20) + CreatureConfig.Teleport.FirstAfterGrace
		local early = runUntil(world, grace + 30, function(): boolean
			return attr(world.model, C.MonsterState) == "Teleport"
		end)
		t.eq(early, math.huge, "no teleport while blocked")
		blocked = false
		local after = runUntil(world, 20, function(): boolean
			return attr(world.model, C.MonsterState) == "Teleport"
		end)
		unblock()
		local snapshot = MonsterAIService.GetSnapshot()
		t.truthy(
			after < 20,
			string.format(
				"once the block lifts it teleports (%s: %s, warp %s, ready in %.0f s, unseen %.0f s)",
				snapshot.state,
				snapshot.reason,
				tostring(snapshot.warp),
				snapshot.teleportReadyAt - world.clock.now(),
				world.clock.now() - snapshot.lastSeenAny
			)
		)
	end)
end

-- A hiding spot on Level 1 near its spawn, its occupant, and the Creature standing off its front.
type Hide = { spot: Model, front: CFrame, occupied: { player: Player? } }

local function hideSpotFor(world: World, hider: Player): Hide
	local spawn = spawnCFrame()
	local floorY = WorldConfig.levelElevation(LEVEL)
	local out = flat(spawn.LookVector)
	local frontAt = Vector3.new(spawn.Position.X, floorY, spawn.Position.Z) + out * 4
	-- the front faces back toward the spawn: the Creature stands off it, between the spot and the spawn
	local front = CFrame.lookAt(frontAt, frontAt - out)
	local spot = Instance.new("Model")
	spot.Name = "SpecLocker"
	local occupied: { player: Player? } = { player = nil }
	MonsterAIService.RegisterHideSpots({
		spotsOn = function(_levelId: string): { Brain.HideSpot }
			return { { id = spot, kind = "Locker", front = front } }
		end,
		occupant = function(which: Instance): Player?
			return if which == spot then occupied.player else nil
		end,
		spotOf = function(player: Player): Instance?
			return if occupied.player == player then spot else nil
		end,
	})
	-- in the spot, a little behind its front
	placeAt(hider, frontAt + out * 1.2)
	PlayerStateService.PushOverride(hider, "SpecHide", "Hiding")
	occupied.player = hider
	local stand = HidingResponse.standPoint(front) + Vector3.new(0, CreatureBody.RootHeight, 0)
	world.root.CFrame = CFrame.lookAt(stand, stand + out)
	return { spot = spot, front = front, occupied = occupied }
end

local function leave(hide: Hide, hider: Player, to: Vector3)
	PlayerStateService.PopOverride(hider, "SpecHide")
	hide.occupied.player = nil
	placeAt(hider, to)
end

spec["fairness: it reaches into the hiding spot it saw you climb into 30 s after you got in"] = function(t: Expect)
	local hider = fakePlayer(CFrame.new(0, -600, 0), true)
	inRun({ hider }, true, function(world: World)
		local hide = hideSpotFor(world, hider)
		local caughtKind: string? = nil
		local connection = MonsterAIService.Caught:Connect(function(player: Player, kind: Enums.JumpscareKind)
			if player == hider then
				caughtKind = kind
			end
		end)
		local _, reply = DevToolsService.Execute(hider, "ai", { "HidingResponse" })
		t.eq(attr(world.model, C.MonsterState), "HidingResponse", "it waits at the spot: " .. reply[1])
		local reach = runUntil(world, 35, function(): boolean
			return attr(world.model, C.Action) == "ReachIn"
		end)
		t.near(reach, DifficultyConfig.Standard.reachInSeconds, 0.25, "the ReachIn at 30 s")
		t.eq(caughtKind, nil, "no catch before it")
		run(world, CreatureConfig.Hiding.ReachInLead + 0.2)
		connection:Disconnect()
		t.eq(caughtKind, "Locker", "it takes them out of the spot")
		PlayerStateService.PopOverride(hider, "SpecHide")
		hide.occupied.player = nil
	end)
	PlayerStateService.OnPlayerRemoving(hider)
end

spec["fairness: a LookAway (after its grunt) lets the hider slip out unseen"] = function(t: Expect)
	local hider = fakePlayer(CFrame.new(0, -600, 0), true)
	inRun({ hider }, true, function(world: World)
		local hide = hideSpotFor(world, hider)
		local caught = false
		local connection = MonsterAIService.Caught:Connect(function(player: Player, _kind: Enums.JumpscareKind)
			if player == hider then
				caught = true
			end
		end)
		local gruntAt: number? = nil
		local grunt = MonsterAIService.Grunted:Connect(function(_at: Vector3)
			gruntAt = world.clock.now()
		end)
		DevToolsService.Execute(hider, "ai", { "HidingResponse" })
		local looked = runUntil(world, 11, function(): boolean
			return attr(world.model, C.Action) == "LookAway"
		end)
		grunt:Disconnect()
		local H = CreatureConfig.Hiding
		t.truthy(looked >= H.LookAwayMin - 0.2 and looked <= H.LookAwayMax + 0.2, "a LookAway 7..10 s in")
		local lookAt = world.clock.now()
		t.truthy(gruntAt ~= nil, "the grunt is the tell")
		if gruntAt then
			t.near(lookAt - gruntAt, H.GruntLead, 0.15, "0.7 s before it turns away")
		end
		-- out of the spot and away behind the corner while it looks down the tunnel
		local away = HidingResponse.standPoint(hide.front) + flat(hide.front.LookVector) * -30
		wallsBeyond(20)
		leave(hide, hider, Vector3.new(away.X, WorldConfig.levelElevation(LEVEL), away.Z))
		run(world, H.LookAwaySeconds + 1)
		connection:Disconnect()
		t.falsy(caught, "slipped out: no catch")
		t.truthy(attr(world.model, C.MonsterState) ~= "HidingResponse", "it moves on")
		t.truthy(attr(world.model, C.Action) ~= "ReachIn", "and never reaches into the empty spot")
	end)
	PlayerStateService.OnPlayerRemoving(hider)
end

spec["fairness: stepping out under its nose is a catch; a teammate's pull-out is not"] = function(t: Expect)
	local hider = fakePlayer(CFrame.new(0, -600, 0), true)
	inRun({ hider }, true, function(world: World)
		local hide = hideSpotFor(world, hider)
		local caughtKind: string? = nil
		local connection = MonsterAIService.Caught:Connect(function(player: Player, kind: Enums.JumpscareKind)
			if player == hider then
				caughtKind = kind
			end
		end)
		DevToolsService.Execute(hider, "ai", { "HidingResponse" })
		run(world, 2)
		-- pulled out by a teammate and thrown clear: a startle, no catch
		local thrown = hide.front.Position + flat(hide.front.LookVector) * 1 + flat(hide.front.RightVector) * 6
		MonsterAIService.NotePulled(hider)
		leave(hide, hider, thrown)
		run(world, CreatureConfig.Hiding.PullStartle + 0.5)
		t.eq(caughtKind, nil, "a pull-out is no catch")
		t.truthy(attr(world.model, C.MonsterState) ~= "HidingResponse", "it moves on")
		t.truthy(attr(world.model, C.Action) ~= "ReachIn", "no reach into the empty spot")
		-- back in, and out again on its own right in front of it
		PlayerStateService.PushOverride(hider, "SpecHide", "Hiding")
		hide.occupied.player = hider
		placeAt(hider, hide.front.Position - flat(hide.front.LookVector) * 1.2)
		local stand = HidingResponse.standPoint(hide.front) + Vector3.new(0, CreatureBody.RootHeight, 0)
		world.root.CFrame = CFrame.lookAt(stand, stand - flat(hide.front.LookVector))
		DevToolsService.Execute(hider, "ai", { "HidingResponse" })
		run(world, 1)
		leave(hide, hider, hide.front.Position)
		run(world, 0.5)
		connection:Disconnect()
		t.eq(caughtKind, "Hallway", "stepping out while it watches is a catch")
	end)
	PlayerStateService.OnPlayerRemoving(hider)
end

return spec
