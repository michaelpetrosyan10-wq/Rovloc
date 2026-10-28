--!strict
-- VentNetworkService. Pure rules: the grate state table, which states serve the prompts, who may unscrew or kick,
-- forced changes, unscrew progress and motion easing (GrateRules); the wall frame, the mouth box, facing the wall,
-- entry and exit eligibility, crossing the room face, the entry / exit placements and the rail verdict (CrawlRules).
-- Geometry on the real Level 1 grates: the EntryAnchor drops the root onto the rail behind the opening, the mouth box
-- holds a crouched player in front of it, the ExitAnchor stands outside the mouth box, and the mouth stub crosses the
-- room face where the exit rule says.
-- Live, on hand-built characters over Level 1's own grates (built through VentGrateBuilder's fixture, the level in a
-- detached host): tracking and prompt service by state, the unscrew hold (begin / cancel / complete, the panel swing),
-- kicks (the cue lead, the throw), a locked grate's refusal, ForceGrate (relabelling, putting a torn-off panel back,
-- open-on-open), crawling in (modes, the move onto the centreline, stats, signals), the rail validator, crawling out
-- (the stand-up spot, modes back, the re-entry cooldown), a closed grate is no way out, a downed crawler stays in,
-- death / another system's move / EndRun release, and the dev commands. (CharacterService only moves characters it
-- spawned, so the specs move roots through SetMover; prompt events and overlap queries need the engine.)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Types = require(ReplicatedStorage.Shared.Types)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)
local VentGrateBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.VentGrateBuilder)

local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local CollisionService = require(ServerScriptService.Services.Core.CollisionService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local MovementAuthority = require(ServerScriptService.Services.Player.MovementAuthority)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local VentNetworkService = require(ServerScriptService.Services.Vents.VentNetworkService)
local CrawlRules = require(ServerScriptService.Services.Vents.VentNetworkService.CrawlRules)
local GrateRules = require(ServerScriptService.Services.Vents.VentNetworkService.GrateRules)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Graph = VentGraph.Graph

local W = Attributes.World

local LEVEL: Enums.LevelId = "Level1_Hallways"
local SEED = 4242
local WALL_HALF = WorldConfig.WallThickness / 2
local HALF_BORE = WorldConfig.VentBore / 2
local HIP_HEIGHT = 2
local ROOT_SIZE = Vector3.new(2, 2, 1)
local ROOT_HEIGHT = HIP_HEIGHT + ROOT_SIZE.Y / 2
local POSE_EPSILON = 2e-3
local EPS = 1e-3

local STATES: { Enums.GrateState } = { "Closed", "Unscrewing", "Open", "Kicked", "Locked" }
local EVENTS: { GrateRules.GrateEvent } = { "UnscrewBegin", "UnscrewCancel", "UnscrewComplete", "Kick" }
local LIFE_STATES: { Enums.LifeState } = { "Lobby", "Alive", "Downed", "Dead", "Spectating" }

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function verdict(ok: boolean, reason: string?): string
	return if ok then "ok" else tostring(reason)
end

local function near(a: Vector3, b: Vector3, epsilon: number?): boolean
	return (a - b).Magnitude <= (epsilon or EPS)
end

local function cframeNear(a: CFrame, b: CFrame, epsilon: number): boolean
	if not near(a.Position, b.Position, epsilon) then
		return false
	end
	return a.LookVector:Dot(b.LookVector) >= 1 - epsilon and a.UpVector:Dot(b.UpVector) >= 1 - epsilon
end

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

-- A wall frame at an arbitrary place and heading (LookVector into the room).
local function sampleWall(): CFrame
	return CFrame.new(40, 20, -12) * CFrame.Angles(0, math.rad(37), 0)
end

-- A point in `wall`'s frame: x along the wall, y up, z out into the room.
local function inWall(wall: CFrame, x: number, y: number, z: number): Vector3
	return wall * Vector3.new(x, y, -z)
end

-- A hand-built graph for rail verdicts: one straight duct along X.
local function railGraph(): Graph
	return {
		levelId = LEVEL,
		nodes = {
			A = { id = "A", position = Vector3.new(0, 2, 0), links = { "B" }, grateId = nil },
			B = { id = "B", position = Vector3.new(20, 2, 0), links = { "A" }, grateId = nil },
		},
		grates = {},
		grateAtNode = {},
		segments = {},
	}
end

--------------------------------------------------------------------------------
-- Level 1 (shell, ducts and grates), built once
--------------------------------------------------------------------------------

type World = {
	level: Model,
	graph: Graph,
	grates: { Model }, -- every built grate, by id
	locked: { [string]: boolean },
}

local cached: World? = nil

local function grateFixture(): PropKit.FixtureBuilder
	local found: PropKit.FixtureBuilder? = nil
	VentGrateBuilder.register({
		prop = function(_kind: string, _builder: Types.PropBuilder) end,
		fixture = function(kind: string, builder: PropKit.FixtureBuilder)
			if kind == "VentGrate" then
				found = builder
			end
		end,
		static = function(_kind: string, _builder: PropKit.StaticBuilder) end,
		rig = function(_kind: string, _builder: Types.RigBuilder) end,
		cosmetic = function(_kind: any, _builder: PropKit.CosmeticAnchorBuilder) end,
	})
	assert(found, "VentGrateBuilder registers its fixture")
	return found
end

local function world(): World
	local existing = cached
	if existing then
		return existing
	end
	local host = Instance.new("Model")
	host.Name = "VentNetworkSpec"
	local result = Builder.BuildAuthoritative({ parent = host :: Instance, layouts = { LEVEL }, yieldEvery = 0 })
	local level = result.levels[LEVEL]
	local graph = VentGraph.build(level, LEVEL)
	assert(graph, "Level 1 has a vent graph")
	local layout = Builder.getLayout(LEVEL)
	assert(layout and layout.vents, "Level 1 has vents")
	local locked: { [string]: boolean } = {}
	for _, grate in layout.vents.grates do
		if grate.lockable and not grate.criticalPath and next(locked) == nil then
			locked[grate.id] = true
		end
	end
	local folder = Instance.new("Folder")
	folder.Name = LEVEL
	folder.Parent = host
	local plan: Types.SpawnPlan =
		{ seed = SEED, difficulty = "Standard", props = {}, lockedGrates = locked, rerolls = 0 }
	grateFixture()({
		layout = layout,
		levelRoot = level,
		parent = folder,
		plan = plan,
		random = MathUtil.seededRandom(SEED, "VentNetworkSpec"),
	})
	local grates: { Model } = {}
	for _, child in folder:GetChildren() do
		if child:IsA("Model") then
			table.insert(grates, child)
		end
	end
	table.sort(grates, function(a: Model, b: Model): boolean
		return a.Name < b.Name
	end)
	assert(#grates == #layout.vents.grates, "one grate model per layout grate")
	VentNetworkService.SetLevelRoot(LEVEL, level)
	local built: World = { level = level, graph = graph, grates = grates, locked = locked }
	cached = built
	return built
end

local function grateId(model: Model): string
	return Attributes.getString(model, W.GrateId, "")
end

-- The first built grate matching `want` (by plan lock), in name order.
local function pickGrate(built: World, lockedOne: boolean, skip: { [Model]: boolean }?): Model
	for _, model in built.grates do
		if (built.locked[grateId(model)] == true) == lockedOne and not (skip and skip[model]) then
			return model
		end
	end
	error("no such grate")
end

local function anchorOf(model: Model, name: string): CFrame
	local attachment = PropKit.findAttachment(model, name)
	assert(attachment, model.Name .. " has " .. name)
	return PropKit.attachmentWorld(attachment)
end

local function promptOf(model: Model, kind: Enums.PromptKind): ProximityPrompt
	local prompt = PropKit.findPrompt(model, kind)
	assert(prompt, model.Name .. " has a " .. kind .. " prompt")
	return prompt
end

local function wallOf(built: World, model: Model): CFrame
	local grate = built.graph.grates[grateId(model)]
	assert(grate, "the graph knows " .. model.Name)
	return grate.wall
end

local function leafTransform(model: Model, leaf: string): CFrame
	local transform = PropKit.leafTransform(model, leaf)
	assert(transform, model.Name .. " has a " .. leaf)
	return transform
end

-- The panel's transform at a pose recorded on Base (PanelOpen, PanelKicked), as setPanel(1) / setKicked(1) put it.
local function recordedPose(model: Model, poseName: string): CFrame
	local rest = PropKit.leafRest(model, "Panel")
	assert(rest, "the panel's rest")
	return rest:ToObjectSpace(anchorOf(model, poseName))
end

local function place(root: BasePart, cframe: CFrame)
	root.CFrame = cframe
	root.Position = cframe.Position
end

local nextUserId = 9400

local function fakePlayer(at: CFrame): (Player, BasePart, Model)
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "VentSpec" .. nextUserId
	local writable = player :: any
	writable.UserId = nextUserId
	player:SetAttribute("DevTools", true)
	local model = Instance.new("Model")
	model.Name = player.Name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = ROOT_SIZE
	place(root, at)
	root.Parent = model
	model.PrimaryPart = root
	local ball = Instance.new("Part")
	ball.Name = CollisionService.VentColliderName
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.one * WorldConfig.VentColliderDiameter
	ball.CFrame = at
	ball.Parent = model
	local humanoid = Instance.new("Humanoid")
	humanoid.HipHeight = HIP_HEIGHT
	humanoid.MaxHealth = GameConfig.MaxHealth
	humanoid.Health = GameConfig.MaxHealth
	humanoid.Parent = model
	player.Character = model
	return player, root, model
end

local intentSeq = 0

local function crouch(player: Player, held: boolean)
	intentSeq += 1
	PlayerStateService.SubmitIntent(player, { crouch = held, sprint = false, dive = false, seq = intentSeq })
end

local function look(player: Player, direction: Vector3)
	local yaw, pitch = MathUtil.yawPitchFromVector(direction)
	PlayerStateService.SubmitLook(player, MathUtil.quantizeAngle(yaw), MathUtil.quantizeAngle(pitch))
end

-- A crouched root standing in front of `model`'s opening, `out` studs past the room face.
local function inFront(built: World, model: Model, out: number): CFrame
	local wall = wallOf(built, model)
	local floorY = anchorOf(model, "ExitAnchor").Position.Y
	local point = wall.Position + wall.LookVector * (WALL_HALF + out)
	return CFrame.lookAt(Vector3.new(point.X, floorY + ROOT_HEIGHT, point.Z), point - wall.LookVector)
end

type Moves = { { player: Player, cframe: CFrame } }

-- Runs `body` in a live run for `players`, with crawlers moved by writing their roots (every move recorded).
local function inRun(built: World, players: { Player }, body: (moves: Moves) -> ())
	Net.Server.setup()
	VentNetworkService.Init()
	local moves: Moves = {}
	VentNetworkService.SetMover(function(player: Player, cframe: CFrame): boolean
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not (root and root:IsA("BasePart")) then
			return false
		end
		place(root, cframe)
		table.insert(moves, { player = player, cframe = cframe })
		return true
	end)
	local ctx: Types.RunContext = {
		runId = "vent-network-spec",
		seed = SEED,
		difficulty = "Standard",
		participants = players,
		startedAt = 1000,
	}
	RunStatsService.BeginRun(ctx)
	PlayerStateService.BeginRun(ctx)
	LifeStateService.BeginRun(ctx)
	VentNetworkService.BeginRun(ctx)
	for _, model in built.grates do
		assert(VentNetworkService.Track(model), "tracks " .. model.Name)
	end
	local failure: string? = nil
	xpcall(function()
		body(moves)
	end, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end)
	VentNetworkService.EndRun()
	LifeStateService.EndRun()
	PlayerStateService.EndRun()
	RunStatsService.EndRun()
	for _, player in players do
		VentNetworkService.OnPlayerRemoving(player)
		LifeStateService.OnPlayerRemoving(player)
		PlayerStateService.OnPlayerRemoving(player)
	end
	VentNetworkService.SetMover(nil)
	-- every grate back to its built state for the next live spec
	for _, model in built.grates do
		VentGrateBuilder.setKicked(model, 0)
		VentGrateBuilder.setPanel(model, 0)
		VentGrateBuilder.setScrews(model, 0)
		model:SetAttribute(W.GrateState, if built.locked[grateId(model)] then "Locked" else "Closed")
		for _, prompt in model:GetDescendants() do
			if prompt:IsA("ProximityPrompt") then
				prompt.ObjectText =
					Strings.get(if built.locked[grateId(model)] then "Prompt.GrateLocked" else "Prompt.Grate")
			end
		end
	end
	if failure ~= nil then
		error(failure, 0)
	end
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["grate rules: the state table"] = function(t: Expect)
		local expected: { [string]: { [string]: string } } = {
			Closed = { UnscrewBegin = "Unscrewing", Kick = "Kicked" },
			Unscrewing = { UnscrewCancel = "Closed", UnscrewComplete = "Open" },
		}
		for _, state: Enums.GrateState in STATES do
			for _, event: GrateRules.GrateEvent in EVENTS do
				local row = expected[state]
				local want = if row then row[event] else nil
				t.eq(GrateRules.nextState(state, event), want, state .. " + " .. event)
			end
		end
		for _, state: Enums.GrateState in STATES do
			local open = state == "Open" or state == "Kicked"
			t.eq(GrateRules.isOpen(state), open, state .. " passable")
			t.eq(GrateRules.servesPrompts(state), not open, state .. " serves the prompts")
		end
	end,

	["grate rules: who may unscrew and kick"] = function(t: Expect)
		local function unscrew(state: Enums.GrateState?, lifeState: Enums.LifeState, channelling: boolean): string
			return verdict(
				GrateRules.unscrewEligible({ state = state, lifeState = lifeState, channelling = channelling })
			)
		end
		local function kick(state: Enums.GrateState?, lifeState: Enums.LifeState): string
			return verdict(GrateRules.kickEligible({ state = state, lifeState = lifeState }))
		end
		t.eq(unscrew("Closed", "Alive", false), "ok")
		t.eq(unscrew("Unscrewing", "Alive", true), "ok", "finishing your own hold")
		t.eq(unscrew("Unscrewing", "Alive", false), "Busy", "someone else is at it")
		t.eq(unscrew("Open", "Alive", false), "Open")
		t.eq(unscrew("Kicked", "Alive", false), "Open")
		t.eq(unscrew(nil, "Alive", false), "Removed")
		t.eq(kick("Closed", "Alive"), "ok")
		t.eq(kick("Unscrewing", "Alive"), "Busy")
		t.eq(kick("Open", "Alive"), "Open")
		t.eq(kick("Kicked", "Alive"), "Open")
		t.eq(kick(nil, "Alive"), "Removed")
		for _, lifeState: Enums.LifeState in LIFE_STATES do
			t.eq(unscrew("Locked", lifeState, false), GrateRules.LockedReason, "locked refuses " .. lifeState)
			t.eq(kick("Locked", lifeState), GrateRules.LockedReason)
			if lifeState ~= "Alive" then
				t.eq(unscrew("Closed", lifeState, false), "LifeState", lifeState)
				t.eq(kick("Closed", lifeState), "LifeState", lifeState)
			end
		end
		t.truthy(Strings.has(GrateRules.LockedReason), "the refusal is a Strings key the player is shown")
	end,

	["grate rules: forced changes, unscrew progress, motions"] = function(t: Expect)
		for _, from: Enums.GrateState in STATES do
			for _, to: Enums.GrateState in STATES do
				local want = if to == "Unscrewing"
					then "NotForcible"
					elseif from == to then "Same"
					elseif GrateRules.isOpen(from) and GrateRules.isOpen(to) then "AlreadyOpen"
					else "Apply"
				t.eq(GrateRules.forceVerdict(from, to), want, from .. " -> " .. to)
			end
		end
		t.eq(GrateRules.forceVerdict("Closed", "Bogus" :: any), "NotForcible")
		t.eq(GrateRules.unscrewProgress(100, 100, 3.5), 0)
		t.near(GrateRules.unscrewProgress(101.75, 100, 3.5), 0.5, 1e-9)
		t.eq(GrateRules.unscrewProgress(110, 100, 3.5), 1, "clamped")
		t.eq(GrateRules.unscrewProgress(99, 100, 3.5), 0, "clamped")
		t.eq(GrateRules.unscrewProgress(100, 100, 0), 1, "an instant hold is done")
		local motion: GrateRules.Motion =
			{ from = 0, to = 1, delay = 0.2, seconds = 0.6, elapsed = 0.1, ease = "Linear" }
		local value, done = GrateRules.motionValue(motion)
		t.eq(value, 0, "holds before its delay")
		t.falsy(done)
		motion.elapsed = 0.5
		value, done = GrateRules.motionValue(motion)
		t.near(value, 0.5, 1e-9, "linear midway")
		t.falsy(done)
		motion.ease = "Out"
		value = GrateRules.motionValue(motion)
		t.near(value, 0.75, 1e-9, "eased out midway")
		motion.elapsed = 0.8
		value, done = GrateRules.motionValue(motion)
		t.near(value, 1, 1e-9)
		t.truthy(done)
		local back: GrateRules.Motion = { from = 1, to = 0.25, delay = 0, seconds = 1, elapsed = 0.5, ease = "Linear" }
		t.near((GrateRules.motionValue(back)), 0.625, 1e-9, "runs backwards too")
	end,

	["crawl rules: the mouth box and facing the wall"] = function(t: Expect)
		local wall = sampleWall()
		local floorY = wall.Position.Y - WorldConfig.VentCenterHeight
		local function root(x: number, z: number, above: number): Vector3
			local p = inWall(wall, x, 0, WALL_HALF + z)
			return Vector3.new(p.X, floorY + above, p.Z)
		end
		local probe = inWall(wall, 0.3, -0.2, 1.1)
		local local3 = CrawlRules.wallSpace(wall, probe)
		t.truthy(near(local3, Vector3.new(0.3, -0.2, 1.1)), "wallSpace round-trips")
		t.truthy(CrawlRules.inMouthBox(wall, root(0, 1, ROOT_HEIGHT), floorY, ROOT_HEIGHT), "crouched in front")
		t.truthy(CrawlRules.inMouthBox(wall, root(0, 0, ROOT_HEIGHT), floorY, ROOT_HEIGHT), "at the room face")
		t.falsy(CrawlRules.inMouthBox(wall, root(0, -0.05, ROOT_HEIGHT), floorY, ROOT_HEIGHT), "inside the wall")
		t.truthy(CrawlRules.inMouthBox(wall, root(0, 2.39, ROOT_HEIGHT), floorY, ROOT_HEIGHT), "2.4 out")
		t.falsy(CrawlRules.inMouthBox(wall, root(0, 2.41, ROOT_HEIGHT), floorY, ROOT_HEIGHT), "too far out")
		t.truthy(CrawlRules.inMouthBox(wall, root(1.59, 1, ROOT_HEIGHT), floorY, ROOT_HEIGHT), "1.6 aside")
		t.falsy(CrawlRules.inMouthBox(wall, root(-1.61, 1, ROOT_HEIGHT), floorY, ROOT_HEIGHT), "too far aside")
		local low = ROOT_HEIGHT - CrawlRules.CrouchBelow
		local high = ROOT_HEIGHT + CrawlRules.CrouchAbove
		t.truthy(CrawlRules.inMouthBox(wall, root(0, 1, low + 0.01), floorY, ROOT_HEIGHT), "crouched low")
		t.falsy(CrawlRules.inMouthBox(wall, root(0, 1, low - 0.01), floorY, ROOT_HEIGHT), "below a crouch")
		t.truthy(CrawlRules.inMouthBox(wall, root(0, 1, high - 0.01), floorY, ROOT_HEIGHT), "on a kicked panel")
		t.falsy(CrawlRules.inMouthBox(wall, root(0, 1, high + 0.01), floorY, ROOT_HEIGHT), "jumping")
		t.falsy(CrawlRules.inMouthBox(wall, Vector3.new(0 / 0, 0, 0), floorY, ROOT_HEIGHT), "not finite")

		local into = -wall.LookVector
		local yaw, pitch = MathUtil.yawPitchFromVector(into)
		t.truthy(CrawlRules.facesWall(wall, yaw, pitch), "looking straight in")
		t.truthy(CrawlRules.facesWall(wall, yaw, math.rad(-50)), "looking down at a low vent")
		t.truthy(CrawlRules.facesWall(wall, yaw + math.rad(60), 0), "60 degrees off (0.5)")
		t.falsy(CrawlRules.facesWall(wall, yaw + math.rad(70), 0), "70 degrees off (0.34)")
		t.falsy(CrawlRules.facesWall(wall, yaw + math.pi, 0), "back to the wall")
		t.falsy(CrawlRules.facesWall(wall, yaw, math.rad(-80)), "staring at the floor")
		t.falsy(CrawlRules.facesWall(wall, 0 / 0, 0), "not finite")
		t.eq(CrawlRules.rootHeight(2, 2), 3)
	end,

	["crawl rules: who may crawl in and out"] = function(t: Expect)
		local function entry(overrides: { [string]: any }?): string
			local check: CrawlRules.EntryCheck = {
				live = true,
				participant = true,
				lifeState = "Alive",
				inVent = false,
				onFoot = true,
				moveState = "Crouching",
				controlLock = "None",
				hasBody = true,
			}
			for key, value in (overrides or {}) :: { [string]: any } do
				(check :: any)[key] = value
			end
			return verdict(CrawlRules.canEnter(check))
		end
		t.eq(entry(), "ok")
		t.eq(entry({ live = false }), "NoRun")
		t.eq(entry({ participant = false }), "NotParticipant")
		t.eq(entry({ inVent = true }), "InVent")
		t.eq(entry({ hasBody = false }), "NoBody")
		t.eq(entry({ controlLock = "Trap" }), "Locked")
		t.eq(entry({ onFoot = false }), "Mode")
		for _, lifeState: Enums.LifeState in LIFE_STATES do
			if lifeState ~= "Alive" then
				t.eq(entry({ lifeState = lifeState }), "LifeState", lifeState)
			end
		end
		for _, moveState: Enums.MoveState in Enums.MoveState do
			if moveState ~= "Crouching" then
				t.eq(entry({ moveState = moveState }), "MoveState", moveState .. " cannot crawl in")
			end
		end
		local function exit(overrides: { [string]: any }?): string
			local check: CrawlRules.ExitCheck =
				{ live = true, lifeState = "Alive", controlLock = "None", hasBody = true }
			for key, value in (overrides or {}) :: { [string]: any } do
				(check :: any)[key] = value
			end
			return verdict(CrawlRules.canExit(check))
		end
		t.eq(exit(), "ok")
		t.eq(exit({ lifeState = "Downed" }), "ok", "a downed crawler drags themselves out")
		t.eq(exit({ lifeState = "Dead" }), "LifeState")
		t.eq(exit({ live = false }), "NoRun")
		t.eq(exit({ controlLock = "Jumpscare" }), "Locked")
		t.eq(exit({ hasBody = false }), "NoBody")
	end,

	["crawl rules: crossing the room face, placements, rail verdicts"] = function(t: Expect)
		local wall = sampleWall()
		local edge = CrawlRules.ExitDepth
		t.eq(edge, WALL_HALF - 0.1)
		t.falsy(CrawlRules.crossedFace(wall, inWall(wall, 0, 0, edge - 0.01)), "not yet")
		t.truthy(CrawlRules.crossedFace(wall, inWall(wall, 0, 0, edge + 0.01)), "crossed")
		t.truthy(CrawlRules.crossedFace(wall, inWall(wall, 1.7, -1.7, 1)), "anywhere in the bore's square")
		t.falsy(CrawlRules.crossedFace(wall, inWall(wall, HALF_BORE + 0.05, 0, 1)), "beside the opening")
		t.falsy(CrawlRules.crossedFace(wall, inWall(wall, 0, HALF_BORE + 0.05, 1)), "above it")
		t.falsy(CrawlRules.crossedFace(wall, inWall(wall, 0, 0, CrawlRules.ExitReach + 0.05)), "out in the room")
		t.falsy(CrawlRules.crossedFace(wall, inWall(wall, 0, 0, -1)), "behind the wall")

		local entryAnchor = CFrame.lookAt(Vector3.new(3, 7, 4), Vector3.new(3, 7, 9))
		local entry = CrawlRules.entryCFrame(entryAnchor, 6.25)
		t.truthy(near(entry.Position, Vector3.new(3, 6.25, 4)), "onto the centreline")
		t.truthy(near(entry.LookVector, entryAnchor.LookVector), "facing into the duct")

		local exitAnchor = CFrame.lookAt(Vector3.new(10, 18, 0), Vector3.new(10, 18, 5))
		local candidates = CrawlRules.exitCandidates(exitAnchor)
		t.eq(#candidates, 3)
		t.truthy(cframeNear(candidates[1], exitAnchor, EPS), "the anchor first")
		t.truthy(near(candidates[2].Position, exitAnchor.Position - exitAnchor.RightVector * 0.75), "then left")
		t.truthy(near(candidates[3].Position, exitAnchor.Position + exitAnchor.RightVector * 0.75), "then right")
		local box, size = CrawlRules.standingBox(exitAnchor)
		t.truthy(near(size, CrawlRules.StandSize))
		t.near(box.Position.Y - size.Y / 2, exitAnchor.Position.Y + CrawlRules.StandLift, 1e-6, "clear of the floor")
		local stood = CrawlRules.exitRootCFrame(exitAnchor, ROOT_HEIGHT)
		t.truthy(near(stood.Position, exitAnchor.Position + Vector3.new(0, ROOT_HEIGHT, 0)), "root over the floor")
		t.truthy(near(stood.LookVector, exitAnchor.LookVector), "facing into the room")

		local graph = railGraph()
		local ok, target, rail = CrawlRules.railVerdict(graph, Vector3.new(5, 3.2, 0), nil)
		t.eq(ok, "Ok", "1.2 off the rail")
		t.eq(target, nil)
		t.truthy(rail ~= nil and near(rail.position, Vector3.new(5, 2, 0)))
		local corrected, back = CrawlRules.railVerdict(graph, Vector3.new(5, 2, 3), Vector3.new(1, 2, 0))
		t.eq(corrected, "Correct", "3 off")
		t.truthy(back ~= nil and near(back, Vector3.new(5, 2, 0)), "back onto the nearest rail point")
		local struck, last = CrawlRules.railVerdict(graph, Vector3.new(5, 2, 9), Vector3.new(1, 2, 0))
		t.eq(struck, "Strike", "9 off")
		t.truthy(last ~= nil and near(last, Vector3.new(1, 2, 0)), "back to the last good point")
		local _, fallback = CrawlRules.railVerdict(graph, Vector3.new(5, 2, 9), nil)
		t.truthy(fallback ~= nil and near(fallback, Vector3.new(5, 2, 0)), "no good point yet: the nearest")
		t.eq((CrawlRules.railVerdict(graph, Vector3.new(0 / 0, 0, 0), nil)), "Strike", "not finite")
		local empty: Graph = { levelId = LEVEL, nodes = {}, grates = {}, grateAtNode = {}, segments = {} }
		t.eq((CrawlRules.railVerdict(empty, Vector3.zero, nil)), "Ok", "nothing to judge against")
	end,

	["level 1 geometry: entry onto the rail, the mouth box, the exit outside it, the stub crossing the face"] = function(
		t: Expect
	)
		quiet(function()
			local built = world()
			local graph = built.graph
			for _, model in built.grates do
				local id = grateId(model)
				local grate = graph.grates[id]
				assert(grate, id)
				local wall = grate.wall
				local nodeY = graph.nodes[grate.nodeId].position.Y
				local entry = CrawlRules.entryCFrame(anchorOf(model, "EntryAnchor"), nodeY)
				local rail = VentGraph.nearest(graph, entry.Position)
				assert(rail, id .. " entry on a rail")
				t.near(rail.distance, 0, 1e-3, id .. " entry lands on the centreline")
				t.truthy(entry.LookVector:Dot(-wall.LookVector) > 0.99, id .. " facing into the duct")
				t.falsy(CrawlRules.crossedFace(wall, entry.Position), id .. " entry is behind the face")
				local exitAnchor = anchorOf(model, "ExitAnchor")
				t.truthy(exitAnchor.LookVector:Dot(wall.LookVector) > 0.99, id .. " exit faces the room")
				local standing = CrawlRules.exitRootCFrame(exitAnchor, ROOT_HEIGHT).Position
				t.falsy(
					CrawlRules.inMouthBox(wall, standing, exitAnchor.Position.Y, ROOT_HEIGHT),
					id .. " a player who just came out is not in the mouth box"
				)
				t.truthy(
					CrawlRules.inMouthBox(wall, inFront(built, model, 1).Position, exitAnchor.Position.Y, ROOT_HEIGHT),
					id .. " a crouched player in front is"
				)
				local node = graph.nodes[grate.nodeId].position
				t.falsy(CrawlRules.crossedFace(wall, node), id .. " the grate node is in the wall")
				t.truthy(CrawlRules.crossedFace(wall, grate.mouth), id .. " the mouth is past the face")
			end
		end)
	end,

	["live: grates are tracked with their state; prompts are served by state; locked ones refuse"] = function(
		t: Expect
	)
		quiet(function()
			local built = world()
			local player = fakePlayer(CFrame.new(0, 200, 0))
			inRun(built, { player }, function()
				for _, model in built.grates do
					local id = grateId(model)
					local want: Enums.GrateState = if built.locked[id] then "Locked" else "Closed"
					t.eq(VentNetworkService.GetGrateState(id), want, id)
					t.eq(VentNetworkService.GetGrateModel(id), model)
					t.falsy(VentNetworkService.IsGrateOpen(id))
					t.eq((InteractionService.Resolve(promptOf(model, "Unscrew"))), VentNetworkService.UnscrewHandler)
					t.eq((InteractionService.Resolve(promptOf(model, "Kick"))), VentNetworkService.KickHandler)
				end
				t.eq(VentNetworkService.GetGrateState("NoSuchGrate"), "Closed", "an unbuilt grate reads shut")
				t.eq(VentNetworkService.GetGrateModel("NoSuchGrate"), nil)
				local lockedModel = pickGrate(built, true)
				local canUse = VentNetworkService.UnscrewHandler.canUse
				local kickCanUse = VentNetworkService.KickHandler.canUse
				assert(canUse and kickCanUse, "both handlers judge players")
				local unscrewPrompt = promptOf(lockedModel, "Unscrew")
				t.eq(verdict(canUse(player, unscrewPrompt, lockedModel)), "Prompt.GrateLocked")
				t.eq(verdict(kickCanUse(player, promptOf(lockedModel, "Kick"), lockedModel)), "Prompt.GrateLocked")
				local open = pickGrate(built, false)
				t.eq(verdict(canUse(player, promptOf(open, "Unscrew"), open)), "ok")
				local holdSeconds = VentNetworkService.UnscrewHandler.holdSeconds
				assert(holdSeconds, "a hold length per player")
				t.eq(holdSeconds(player, unscrewPrompt, lockedModel), GameConfig.UnscrewSeconds, "no screwdriver")
				player:SetAttribute(Attributes.Player.Loadout, "RustyScrewdriver")
				t.truthy(
					holdSeconds(player, unscrewPrompt, lockedModel) < GameConfig.UnscrewSeconds,
					"the Rusty Screwdriver is quicker"
				)
				player:SetAttribute(Attributes.Player.Loadout, nil)
			end)
		end)
	end,

	["live: the unscrew hold begins, cancels and completes; the panel swings open"] = function(t: Expect)
		quiet(function()
			local built = world()
			local player = fakePlayer(CFrame.new(0, 200, 0))
			local model = pickGrate(built, false)
			local id = grateId(model)
			local changes: { string } = {}
			local connection = VentNetworkService.GrateChanged:Connect(
				function(changed: string, state: Enums.GrateState, by: Player?)
					if changed == id then
						table.insert(changes, state .. ":" .. (if by then by.Name else "-"))
					end
				end
			)
			inRun(built, { player }, function()
				local prompt = promptOf(model, "Unscrew")
				local handler = VentNetworkService.UnscrewHandler
				local onBegin, onCancel = handler.onBegin, handler.onCancel
				assert(onBegin and onCancel, "the hold is server-timed")
				onBegin(player, prompt, model)
				t.eq(VentNetworkService.GetGrateState(id), "Unscrewing")
				t.eq(model:GetAttribute(W.GrateState), "Unscrewing")
				t.eq((InteractionService.Resolve(prompt)), handler, "the running hold keeps its prompt")
				local kickCanUse = VentNetworkService.KickHandler.canUse
				assert(kickCanUse, "kick judges")
				t.eq(verdict(kickCanUse(player, promptOf(model, "Kick"), model)), "Busy", "no kicking mid-unscrew")
				onCancel(player, prompt, model, "Released")
				t.eq(VentNetworkService.GetGrateState(id), "Closed", "letting go closes it again")
				VentNetworkService.StepMotions(1)
				t.truthy(cframeNear(leafTransform(model, "Screw1"), CFrame.new(), POSE_EPSILON), "screws in")

				onBegin(player, prompt, model)
				handler.onComplete(player, prompt, model)
				t.eq(VentNetworkService.GetGrateState(id), "Open")
				t.truthy(VentNetworkService.IsGrateOpen(id))
				t.eq((InteractionService.Resolve(prompt)), nil, "an open grate offers nothing")
				t.eq((InteractionService.Resolve(promptOf(model, "Kick"))), nil)
				VentNetworkService.StepMotions(GrateRules.PanelSeconds / 2)
				local halfway = leafTransform(model, "Panel")
				t.falsy(cframeNear(halfway, CFrame.new(), POSE_EPSILON), "swinging")
				VentNetworkService.StepMotions(1)
				t.truthy(cframeNear(leafTransform(model, "Panel"), recordedPose(model, "PanelOpen"), POSE_EPSILON))
				local screwRest = PropKit.leafRest(model, "Screw1")
				assert(screwRest, "screw rest")
				local screwOut = screwRest:ToObjectSpace(anchorOf(model, "Screw1Out"))
				t.truthy(
					cframeNear(leafTransform(model, "Screw1"), screwOut, POSE_EPSILON),
					"the screws lie on the floor"
				)
			end)
			connection:Disconnect()
			local name = player.Name
			t.eq(
				table.concat(changes, ","),
				string.format("Unscrewing:%s,Closed:%s,Unscrewing:%s,Open:%s", name, name, name, name)
			)
		end)
	end,

	["live: a kick waits for the cue lead, then throws the panel; ForceGrate relabels, resets and refuses"] = function(
		t: Expect
	)
		quiet(function()
			local built = world()
			local player = fakePlayer(CFrame.new(0, 200, 0))
			local model = pickGrate(built, false)
			local id = grateId(model)
			inRun(built, { player }, function()
				local kickPrompt = promptOf(model, "Kick")
				VentNetworkService.KickHandler.onComplete(player, kickPrompt, model)
				t.eq(VentNetworkService.GetGrateState(id), "Kicked")
				t.eq(model:GetAttribute(W.GrateState), "Kicked")
				VentNetworkService.StepMotions(GameConfig.OneShotLead / 2)
				t.truthy(cframeNear(leafTransform(model, "Panel"), CFrame.new(), POSE_EPSILON), "still in the lead")
				VentNetworkService.StepMotions(1)
				t.truthy(
					cframeNear(leafTransform(model, "Panel"), recordedPose(model, "PanelKicked"), POSE_EPSILON),
					"landed"
				)
				t.eq((InteractionService.Resolve(kickPrompt)), nil, "nothing left to do")

				VentNetworkService.ForceGrate(id, "Open")
				t.eq(VentNetworkService.GetGrateState(id), "Kicked", "open on open changes nothing")
				VentNetworkService.ForceGrate(id, "Unscrewing")
				t.eq(VentNetworkService.GetGrateState(id), "Kicked", "Unscrewing cannot be forced")
				VentNetworkService.ForceGrate(id, "Locked")
				t.eq(VentNetworkService.GetGrateState(id), "Locked")
				t.truthy(cframeNear(leafTransform(model, "Panel"), CFrame.new(), POSE_EPSILON), "back on its hinges")
				t.eq(kickPrompt.ObjectText, Strings.get("Prompt.GrateLocked"), "relabelled rusted shut")
				t.eq((InteractionService.Resolve(kickPrompt)), VentNetworkService.KickHandler, "served again")
				VentNetworkService.ForceGrate(id, "Closed")
				t.eq(kickPrompt.ObjectText, Strings.get("Prompt.Grate"), "unlocked")
				VentNetworkService.ForceGrate(id, "Open")
				VentNetworkService.StepMotions(1)
				t.truthy(cframeNear(leafTransform(model, "Panel"), recordedPose(model, "PanelOpen"), POSE_EPSILON))
				VentNetworkService.ForceGrate(id, "Closed")
				VentNetworkService.StepMotions(1)
				t.truthy(cframeNear(leafTransform(model, "Panel"), CFrame.new(), POSE_EPSILON), "swung shut")
				t.truthy(cframeNear(leafTransform(model, "Screw2"), CFrame.new(), POSE_EPSILON), "screwed back in")
				VentNetworkService.ForceGrate(id, "Kicked")
				t.eq(VentNetworkService.GetGrateState(id), "Kicked", "a scripted kick")
				VentNetworkService.ForceGrate("NoSuchGrate", "Open")
			end)
		end)
	end,

	["live: crouch in, ride the rail, crawl out; the cooldown stops an instant re-entry"] = function(t: Expect)
		quiet(function()
			local built = world()
			local model = pickGrate(built, false)
			local id = grateId(model)
			local graph = built.graph
			local wall = wallOf(built, model)
			local player, root, character = fakePlayer(inFront(built, model, 1))
			local log: { string } = {}
			local connections = {
				VentNetworkService.Entered:Connect(function(who: Player, through: string)
					table.insert(log, "in:" .. who.Name .. ":" .. through)
				end),
				VentNetworkService.Exited:Connect(function(who: Player, through: string)
					table.insert(log, "out:" .. who.Name .. ":" .. through)
				end),
			}
			inRun(built, { player }, function(moves: Moves)
				VentNetworkService.ForceGrate(id, "Open")
				look(player, -wall.LookVector)
				VentNetworkService.Poll()
				t.falsy(VentNetworkService.IsInVent(player), "standing up: no")
				crouch(player, true)
				t.eq(PlayerStateService.GetMoveState(player), "Crouching")
				look(player, wall.LookVector)
				VentNetworkService.Poll()
				t.falsy(VentNetworkService.IsInVent(player), "looking away: no")
				look(player, -wall.LookVector)
				VentNetworkService.Poll()
				t.truthy(VentNetworkService.IsInVent(player), "crouched at an open grate, looking in")

				local grate = graph.grates[id]
				local nodeY = graph.nodes[grate.nodeId].position.Y
				local expected = CrawlRules.entryCFrame(anchorOf(model, "EntryAnchor"), nodeY)
				t.eq(#moves, 1)
				t.truthy(cframeNear(moves[1].cframe, expected, EPS), "moved onto the centreline")
				t.eq(PlayerStateService.GetMode(player), "Vent")
				t.eq(PlayerStateService.GetMoveState(player), "VentCrawling")
				t.eq(CollisionService.GetMode(character), "Vent", "the ball is the only collider")
				t.eq(RunStatsService.Get(player, "VentsCrawled"), 1)
				t.eq(VentNetworkService.GetEntryGrate(player), id)
				local occupants = VentNetworkService.OccupantsOf(LEVEL)
				t.truthy(#occupants == 1 and occupants[1] == player)
				t.eq(#VentNetworkService.OccupantsOf("Level2_ScienceHall"), 0)
				local rail = VentNetworkService.GetRailPoint(player)
				t.truthy(rail ~= nil and rail.distance < 1e-3, "on the rail")

				-- The rail validator.
				t.eq(table.find(MovementAuthority.GetValidatorNames(), VentNetworkService.ValidatorName) ~= nil, true)
				local onRail = root.CFrame.Position
				t.eq((VentNetworkService.RailValidator(player, root, 0.1)), "Ok")
				place(root, CFrame.new(onRail + Vector3.new(0, -2.5, 0)))
				local corrected, back = VentNetworkService.RailValidator(player, root, 0.1)
				t.eq(corrected, "Correct", "2.5 below the rail")
				t.truthy(back ~= nil and near(back, onRail), "back onto the rail")
				place(root, CFrame.new(onRail + Vector3.new(0, 30, 0)))
				local struck, last = VentNetworkService.RailValidator(player, root, 0.1)
				t.eq(struck, "Strike", "far off the rail")
				t.truthy(last ~= nil and near(last, onRail), "back to the last good rail point")

				-- Out through the grate it came in by.
				local out = wall.Position + wall.LookVector * (CrawlRules.ExitDepth - 0.05)
				place(root, CFrame.new(out))
				VentNetworkService.Poll()
				t.truthy(VentNetworkService.IsInVent(player), "not across the face yet")
				out = wall.Position + wall.LookVector * (CrawlRules.ExitDepth + 0.05)
				place(root, CFrame.new(out))
				VentNetworkService.Poll()
				t.falsy(VentNetworkService.IsInVent(player), "out")
				t.eq(#moves, 2)
				local exitRoot = CrawlRules.exitRootCFrame(anchorOf(model, "ExitAnchor"), ROOT_HEIGHT)
				t.truthy(cframeNear(moves[2].cframe, exitRoot, EPS), "stood up at the ExitAnchor")
				t.eq(PlayerStateService.GetMode(player), "OnFoot")
				t.eq(PlayerStateService.GetMoveState(player), "Crouching", "still holding crouch")
				t.eq(CollisionService.GetMode(character), "Normal")

				place(root, inFront(built, model, 1))
				look(player, -wall.LookVector)
				VentNetworkService.Poll()
				t.falsy(VentNetworkService.IsInVent(player), "the cooldown holds them out")
				t.eq(RunStatsService.Get(player, "VentsCrawled"), 1)
			end)
			for _, connection in connections do
				connection:Disconnect()
			end
			t.eq(table.concat(log, ","), "in:" .. player.Name .. ":" .. id .. ",out:" .. player.Name .. ":" .. id)
		end)
	end,

	["live: a closed grate is no way out; downed crawlers stay; death, a far move and EndRun release"] = function(
		t: Expect
	)
		quiet(function()
			local built = world()
			local first = pickGrate(built, false)
			local second = pickGrate(built, false, { [first] = true })
			local wall = wallOf(built, first)
			local a, rootA, characterA = fakePlayer(inFront(built, first, 1))
			local b, rootB = fakePlayer(inFront(built, second, 1))
			local c, _, characterC = fakePlayer(inFront(built, first, 0.8))
			local releases: { string } = {}
			local connection = VentNetworkService.Released:Connect(function(who: Player, reason: string)
				table.insert(releases, who.Name .. ":" .. reason)
			end)
			inRun(built, { a, b, c }, function()
				VentNetworkService.ForceGrate(grateId(first), "Kicked")
				VentNetworkService.ForceGrate(grateId(second), "Open")
				for _, player in { a, b, c } do
					crouch(player, true)
				end
				look(a, -wall.LookVector)
				look(c, -wall.LookVector)
				look(b, -wallOf(built, second).LookVector)
				VentNetworkService.Poll()
				for _, player in { a, b, c } do
					t.truthy(VentNetworkService.IsInVent(player), player.Name .. " crawled in")
				end
				t.eq(#VentNetworkService.OccupantsOf(LEVEL), 3)

				-- the grate is shut behind them: no way out there
				VentNetworkService.ForceGrate(grateId(first), "Closed")
				place(rootA, CFrame.new(wall.Position + wall.LookVector * (CrawlRules.ExitDepth + 0.05)))
				VentNetworkService.Poll()
				t.truthy(VentNetworkService.IsInVent(a), "a closed grate is no exit")

				-- downed in a duct: still crawling, still a ball
				LifeStateService.Down(a, "Spec")
				t.eq(LifeStateService.GetState(a), "Downed")
				t.truthy(VentNetworkService.IsInVent(a), "a downed crawler stays in the duct")
				t.eq(CollisionService.GetMode(characterA), "Vent")
				t.eq(PlayerStateService.GetMoveState(a), "DownedCrawling")

				-- dead: released where they lie
				LifeStateService.Execute(a, "Spec")
				t.falsy(VentNetworkService.IsInVent(a), "the dead leave the vents")
				t.eq(CollisionService.GetMode(characterA), "Normal")

				-- another system moves a crawler far off the rail: out of the duct
				CharacterService.Moved:Fire(c, characterC, CFrame.new(0, 300, 0))
				t.falsy(VentNetworkService.IsInVent(c), "moved off the rail")
				t.eq(PlayerStateService.GetMode(c), "OnFoot")

				-- a nearby move (a correction) keeps them in
				local railPoint = VentNetworkService.GetRailPoint(b)
				assert(railPoint, "b is on the rail")
				local character = b.Character
				assert(character, "b has a body")
				CharacterService.Moved:Fire(b, character, CFrame.new(railPoint.position + Vector3.new(0, 1, 0)))
				t.truthy(VentNetworkService.IsInVent(b), "a correction is not a release")
				t.truthy(rootB.Parent ~= nil)
			end)
			connection:Disconnect()
			t.eq(
				table.concat(releases, ","),
				string.format("%s:Dead,%s:Moved,%s:RunEnded", a.Name, c.Name, b.Name),
				"EndRun released the last one"
			)
			t.falsy(VentNetworkService.IsInVent(b))
		end)
	end,

	["live: dev commands force grates and list them"] = function(t: Expect)
		quiet(function()
			local built = world()
			local model = pickGrate(built, false)
			local id = grateId(model)
			local player = fakePlayer(inFront(built, model, 1))
			inRun(built, { player }, function()
				local function dev(command: string, args: { string }): string
					local _, answer = DevToolsService.Execute(player, command, args)
					return answer[1]
				end
				local reply: string
				local key, first = DevToolsService.Execute(player, "vent", { "lock" })
				t.eq(key, "Dev.Ok")
				t.eq(first[1], id .. ": Closed -> Locked", "the nearest grate by default")
				reply = dev("vent", { "open", id })
				t.eq(reply, id .. ": Locked -> Open")
				reply = dev("vent", { "kick", "nearest" })
				t.eq(reply, id .. ": Open -> Open (AlreadyOpen)")
				reply = dev("vent", { "close", string.lower(id) })
				t.eq(reply, id .. ": Open -> Closed", "any case, any unique part of an id")
				reply = dev("vent", { "close", "Grate" })
				t.truthy(string.find(reply, "grates match", 1, true) ~= nil, "ambiguous")
				reply = dev("vent", { "close", "zzz" })
				t.eq(reply, 'no grate matches "zzz"')
				reply = dev("vent", { "smash" })
				t.truthy(string.find(reply, "usage", 1, true) ~= nil)
				reply = dev("vents", {})
				t.truthy(string.find(reply, LEVEL .. ":", 1, true) ~= nil, "a line per level")
				t.truthy(string.find(reply, id .. "=Closed", 1, true) ~= nil, "each grate with its state")
				t.truthy(string.find(reply, "crawling: nobody", 1, true) ~= nil)
				reply = dev("vents", { "2" })
				t.eq(reply, "no grates this run", "Level 2 was not built here")
				reply = dev("vents", { "bogus" })
				t.eq(reply, 'unknown level "bogus"')
			end)
		end)
	end,
}
