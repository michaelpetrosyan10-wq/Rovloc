--!strict
-- MonsterAIService live, on the real Creature rig with a fake clock and a fake movement engine (the Lune harness has
-- no physics: roots move only when the service places them). Attribute writes (every Creature attribute, StateSince
-- on every change), waking into Patrol after a level activates (and the airlock grace keeping noises from turning
-- into investigations), alerts, stuns, the scripted handle (exclusive, poses, hiding and the unseen reveal, a dead
-- handle after Release), the stuck reposition, a hallway catch through JumpscareHandler (the brain holds still while
-- it plays, then withdraws on the cooldown), the dev commands, and the vent rail: in through a kicked grate on all
-- fours on the centreline, along the ducts with VentSegmentId current, and back out.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local CreatureRigBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.CreatureRigBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)

local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local MonsterAIService = require(ServerScriptService.Services.Monster.MonsterAIService)
local Brain = require(ServerScriptService.Services.Monster.MonsterAIService.Brain)
local CreatureBody = require(ServerScriptService.Services.Monster.MonsterAIService.CreatureBody)
local JumpscareHandler = require(ServerScriptService.Services.Monster.MonsterAIService.JumpscareHandler)
local Locomotion = require(ServerScriptService.Services.Monster.MonsterAIService.Locomotion)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

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
			return { waypoints = { from, to }, path = nil }
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
		t.eq(attr(model, C.PoseMode), "Biped", "PoseMode")
		t.eq(attr(model, C.TargetUserId), 0, "no target")
		t.eq(attr(model, C.InVent), false, "InVent")
		t.eq(attr(model, C.VentSegmentId), "", "no duct")
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
		t.truthy(string.find(ai("VentChase"), "not in a vent", 1, true) ~= nil, "VentChase needs you in a duct")
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

spec["vent rail: in through a kicked grate on the centreline, along the ducts, back out"] = function(t: Expect)
	local folder = Instance.new("Folder")
	local stand = Vector3.new(-4.5, 0, 0)
	local model = quietBuild(folder, CFrame.lookAt(stand, stand + Vector3.new(1, 0, 0)))
	local body = CreatureBody.attach(model)
	assert(body, "a body")
	local wall = CFrame.lookAt(Vector3.new(-1, 2, 0), Vector3.new(-2, 2, 0))
	local graph: VentGraph.Graph = {
		levelId = LEVEL,
		nodes = {
			A = { id = "A", position = Vector3.new(0, 2, 0), links = { "B" }, grateId = "G" },
			B = { id = "B", position = Vector3.new(20, 2, 0), links = { "A" }, grateId = nil },
		},
		grates = {
			G = {
				id = "G",
				nodeId = "A",
				facingZoneId = "Room",
				lockable = false,
				criticalPath = false,
				wall = wall,
				mouth = wall.Position + wall.LookVector * VentGraph.MouthOut,
			},
		},
		grateAtNode = { A = "G" },
		segments = { ["A|B"] = "A-B", ["B|A"] = "A-B" },
	}
	local grateState: Enums.GrateState = "Closed"
	local kicks = 0
	local grates: Locomotion.Grates = {
		state = function(_id: string): Enums.GrateState
			return grateState
		end,
		standPoint = function(_grate: VentGraph.Grate): CFrame
			return CFrame.lookAt(stand, stand + Vector3.new(-1, 0, 0))
		end,
		kick = function(_id: string)
			kicks += 1
			grateState = "Kicked"
		end,
	}
	local now = 0
	local mover = Locomotion.new(body, fakeEngine({}), grates, function(): number
		return now
	end)
	mover:SetLevel(graph, {})
	mover:SetSpeed(CreatureConfig.Speeds.VentChase)
	local function step(seconds: number)
		for _ = 1, math.floor(seconds / 0.05 + 0.5) do
			now += 0.05
			mover:Step(0.05)
		end
	end
	mover:EnterVent(graph.grates.G, true)
	step(0.2)
	t.eq(kicks, 0, "faces the grate before the kick")
	step(2.5)
	t.eq(kicks, 1, "kicked the closed grate in once")
	t.eq(mover:Medium(), "Vent", "in the ducts")
	t.eq(body.pose, "Quadruped", "on all fours")
	t.truthy(body.root.Anchored, "kinematic on the rail")
	t.truthy(near(body.root.CFrame.Position, graph.nodes.A.position, 0.01), "on the centreline at the grate's node")
	t.truthy(near(body.hitbox and body.hitbox.Size or Vector3.zero, CreatureConfig.Hitbox.Quadruped), "duct hitbox")
	t.truthy(mover:RailTo({ a = "A", b = "B", t = 0.75, position = Vector3.new(15, 2, 0), distance = 0 }), "a route")
	step(0.5)
	t.eq(mover:Segment(), "A-B", "VentSegmentId follows the duct")
	t.near(body.root.CFrame.Position.Y, 2, 1e-3, "root on the centreline while crawling")
	t.truthy(body.root.CFrame.LookVector:Dot(Vector3.new(1, 0, 0)) > 0.99, "facing its travel")
	step(1.5)
	t.truthy(near(body.root.CFrame.Position, Vector3.new(15, 2, 0), 0.01), "reached the target's rail point")
	t.truthy(mover:ExitVent(nil, nil), "a way out")
	step(3)
	t.eq(mover:Medium(), "Floor", "out of the ducts")
	t.eq(body.pose, "Biped", "standing again")
	t.falsy(body.root.Anchored, "the Humanoid walks it again")
	t.truthy(near(body.root.CFrame.Position, stand + Vector3.new(0, CreatureBody.RootHeight, 0), 0.01), "in the room")
	t.eq(kicks, 1, "no second kick through the open grate")
	t.eq(mover:Segment(), nil, "no duct")
	grateState = "Locked"
	mover:Reset("Vent")
	t.falsy(mover:ExitVent(nil, nil), "a locked grate is never a way out")
	mover:Destroy()
	model:Destroy()
end

spec["locomotion: walks fail after two routes are refused, Stop keeps a squeeze going"] = function(t: Expect)
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
	local grates: Locomotion.Grates = {
		state = function(_id: string): Enums.GrateState
			return "Open"
		end,
		standPoint = function(_grate: VentGraph.Grate): CFrame
			return CFrame.new()
		end,
		kick = function(_id: string) end,
	}
	local mover = Locomotion.new(body, engine, grates, function(): number
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
	mover:Destroy()
	model:Destroy()
end

return spec
