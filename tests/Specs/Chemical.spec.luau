--!strict
-- Chemical flasks. Ballistics (the shared flight): the parabola, the release point and its pull-back, stepped casts
-- (hits, segment length, expiry), the traced arc and its beads, the pool's surface crossings. ChemicalProjectileService's
-- rules: the look tolerance, who may throw and pick up, which states a stun interrupts, the cloud's reach (radius and
-- a clear line), the duct bore and its grate openings, VentGraph hops, the Creature's vent node, variants by colour,
-- and every stun verdict. Live runs on a fake clock with injected casts, lines of sight, Creature, vent graph, brain and
-- ProjectileEvent sender: a world flask picked up (one at a time), thrown (look, cooldown, blocked states, the vent
-- toss), flown and shattered on the floor, in the pool (the real cast's water planes) and inside a duct; the cloud
-- stuns once, through a clear line only, a Creature walking into it later, never one already stunned, in the ducts by
-- hops; an expired flight; Downed keeps the flask, death and the end of the run empty the hand. ChemicalThrowController's
-- maths: the hand frames, the wind-up and swing, reconciliation, refusal, posing and wind-up rules, hints, the snap,
-- the cloud's rate and glow, shards, fades and the held / flying placements. (Rendering, input, the engine's raycasts
-- and replication need Studio.)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Ballistics = require(ReplicatedStorage.Shared.Util.Ballistics)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local ChemicalFlaskBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.ChemicalFlaskBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)

local ChemicalProjectileService = require(ServerScriptService.Services.Mechanics.ChemicalProjectileService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

local ChemicalThrowController = require(StarterPlayer.StarterPlayerScripts.Controllers.Gameplay.ChemicalThrowController)

type Expect = SpecRunner.Expect
type Graph = VentGraph.Graph
type Hit = Ballistics.Hit
type Caster = ChemicalProjectileService.Caster
type CloudView = ChemicalProjectileService.CloudView
type CreatureView = ChemicalProjectileService.CreatureView
type ThrowCheck = ChemicalProjectileService.ThrowCheck
type Payload = Types.ProjectileEventPayload

local P = Attributes.Player
local W = Attributes.World
local C = Attributes.Creature
local SCIENCE: Enums.LevelId = "Level2_ScienceHall"
local HIP_HEIGHT = 2
local ROOT_SIZE = Vector3.new(2, 2, 1)
local HALF_BORE = WorldConfig.VentBore / 2
local EPS = 1e-5 -- Vector3 and CFrame are single precision

local BLOCKED: { Enums.MoveState } = { "Hiding", "Trapped", "Scripted", "Grabbed", "Parachuting" }
local FREE: { Enums.MoveState } = {
	"Standing",
	"Sprinting",
	"Crouching",
	"VentCrawling",
	"VentScurrying",
	"DownedCrawling",
	"Treading",
	"Freestyle",
	"Underwater",
}
local NOT_ALIVE: { Enums.LifeState } = { "Lobby", "Downed", "Dead", "Spectating" }

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Runs `fn` with Geometry's cooperative yielding off (specs never task.wait), restoring it afterwards.
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

local function near(a: Vector3, b: Vector3, epsilon: number): boolean
	return (a - b).Magnitude <= epsilon
end

local function verdict(ok: boolean, reason: string?): string
	return if ok then "ok" else tostring(reason)
end

-- A floor at `height` that only stops what comes down onto it.
local function floorCast(height: number): Caster
	return function(from: Vector3, to: Vector3, _exclude: { Instance }, _water: boolean): Hit?
		if from.Y < height or to.Y > height or math.abs(from.Y - to.Y) < 1e-12 then
			return nil
		end
		local fraction = (from.Y - height) / (from.Y - to.Y)
		return {
			position = from:Lerp(to, fraction),
			normal = Vector3.yAxis,
			fraction = fraction,
			kind = "World",
			instance = nil,
		}
	end
end

local function noCast(_from: Vector3, _to: Vector3, _exclude: { Instance }, _water: boolean): Hit?
	return nil
end

-- A hand-built duct network on one level: A(0,2,0) - B(20,2,0) - C(20,2,20) - D(40,2,20) - E(60,2,20), and F
-- linked to nothing; a grate on A whose wall faces -X (its room lies west of x = -2).
local function ductGraph(): Graph
	local graph: Graph = {
		levelId = SCIENCE,
		nodes = {},
		grates = {},
		grateAtNode = {},
		segments = {},
	}
	local nodes = graph.nodes :: { [string]: VentGraph.Node }
	local function node(id: string, position: Vector3)
		nodes[id] = { id = id, position = position, links = {}, grateId = nil }
	end
	node("A", Vector3.new(0, 2, 0))
	node("B", Vector3.new(20, 2, 0))
	node("C", Vector3.new(20, 2, 20))
	node("D", Vector3.new(40, 2, 20))
	node("E", Vector3.new(60, 2, 20))
	node("F", Vector3.new(200, 2, 200))
	local segments = graph.segments :: { [string]: string }
	local function link(a: string, b: string)
		table.insert(nodes[a].links, b)
		table.insert(nodes[b].links, a)
		segments[a .. "|" .. b] = a .. "-" .. b
		segments[b .. "|" .. a] = a .. "-" .. b
	end
	link("A", "B")
	link("B", "C")
	link("C", "D")
	link("D", "E")
	-- The grate on A: the opening's centre on its wall's centre plane at x = -2.5, looking west into the room.
	local wall = CFrame.lookAt(Vector3.new(-2.5, 2, 0), Vector3.new(-10, 2, 0))
	local grates = graph.grates :: { [string]: VentGraph.Grate }
	grates.G1 = {
		id = "G1",
		nodeId = "A",
		facingZoneId = "Lab",
		lockable = false,
		criticalPath = false,
		wall = wall,
		mouth = wall.Position + wall.LookVector * VentGraph.MouthOut,
	}
	(graph.grateAtNode :: { [string]: string }).A = "G1"
	return graph
end

local nextUserId = 9400

local function fakePlayer(at: CFrame): (Player, BasePart, Humanoid)
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "ChemicalSpec" .. nextUserId
	local writable = player :: any
	writable.UserId = nextUserId
	local model = Instance.new("Model")
	model.Name = player.Name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = ROOT_SIZE
	root.CFrame = at
	-- Position is written too: the engine derives it from CFrame, the Lune harness does not (LifeStateService's
	-- downed gasp reads it).
	root.Position = at.Position
	root.Parent = model
	model.PrimaryPart = root
	local humanoid = Instance.new("Humanoid")
	humanoid.HipHeight = HIP_HEIGHT
	humanoid.MaxHealth = GameConfig.MaxHealth
	humanoid.Health = GameConfig.MaxHealth
	humanoid.Parent = model
	player.Parent = Players
	model.Parent = Workspace
	player.Character = model
	return player, root, humanoid
end

-- A stand-in Creature: a root and a biped CreatureHitbox (3 x 8 x 2) standing at `at`, on the Science Hall.
local function fakeCreature(at: Vector3): (Model, BasePart)
	local model = Instance.new("Model")
	model.Name = "SpecCreature"
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = CFrame.new(at + Vector3.new(0, 3, 0))
	root.Parent = model
	local hitbox = Instance.new("Part")
	hitbox.Name = "CreatureHitbox"
	hitbox.Size = Vector3.new(3, 8, 2)
	hitbox.CFrame = CFrame.new(at + Vector3.new(0, 4, 0))
	hitbox.Parent = model
	model:SetAttribute(C.LevelId, SCIENCE)
	return model, hitbox
end

local function moveCreature(model: Model, at: Vector3)
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	local hitbox = model:FindFirstChild("CreatureHitbox") :: BasePart
	root.CFrame = CFrame.new(at + Vector3.new(0, 3, 0))
	hitbox.CFrame = CFrame.new(at + Vector3.new(0, 4, 0))
end

type World = {
	clock: number,
	events: { Payload },
	stuns: { { seconds: number, from: Vector3 } },
	shatters: { { point: Vector3, thrower: Player?, inVent: boolean } },
	state: Enums.MonsterState,
	clear: boolean,
	cast: Caster?,
	creature: Model?,
	graph: Graph?,
}

-- Runs `body` with `players` in a live run on a fake clock with every dependency faked (see World), and always
-- tears it down.
local function inRun(players: { Player }, body: (world: World) -> ())
	Net.Server.setup()
	ChemicalProjectileService.Init()
	local world: World = {
		clock = 5000,
		events = {},
		stuns = {},
		shatters = {},
		state = "Patrol",
		clear = true,
		cast = floorCast(0),
		creature = nil,
		graph = ductGraph(),
	}
	ChemicalProjectileService.SetDependencies({
		now = function(): number
			return world.clock
		end,
		cast = function(from: Vector3, to: Vector3, exclude: { Instance }, water: boolean): Hit?
			local current = world.cast
			return if current then current(from, to, exclude, water) else nil
		end,
		lineClear = function(_creature: Model?): ChemicalProjectileService.LineClear
			return function(_from: Vector3, _to: Vector3): boolean
				return world.clear
			end
		end,
		creature = function(): Model?
			return world.creature
		end,
		graph = function(_levelId: string): Graph?
			return world.graph
		end,
		monster = {
			Stun = function(seconds: number, from: Vector3)
				table.insert(world.stuns, { seconds = seconds, from = from })
			end,
			GetState = function(): Enums.MonsterState
				return world.state
			end,
		},
		publish = function(payload: Payload)
			table.insert(world.events, payload)
		end,
	})
	local connection = ChemicalProjectileService.Shattered:Connect(function(point: Vector3, thrower: Player?, inVent)
		table.insert(world.shatters, { point = point, thrower = thrower, inVent = inVent })
	end)
	local ctx: Types.RunContext = {
		runId = "chemical-spec",
		seed = 77,
		difficulty = "Standard",
		participants = players,
		startedAt = 1000,
	}
	RunStatsService.BeginRun(ctx)
	PlayerStateService.BeginRun(ctx)
	LifeStateService.BeginRun(ctx)
	ChemicalProjectileService.BeginRun(ctx)
	for _, player in players do
		player:SetAttribute(P.LevelId, SCIENCE)
	end
	local failure: string? = nil
	xpcall(body, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end, world)
	connection:Disconnect()
	ChemicalProjectileService.EndRun()
	LifeStateService.EndRun()
	PlayerStateService.EndRun()
	RunStatsService.EndRun()
	for _, player in players do
		ChemicalProjectileService.OnPlayerRemoving(player)
		LifeStateService.OnPlayerRemoving(player)
		PlayerStateService.OnPlayerRemoving(player)
		NoiseAndDirectorService.OnPlayerRemoving(player)
		local character = player.Character
		if character then
			character.Parent = nil
		end
		player.Parent = nil
	end
	ChemicalProjectileService.SetDependencies(nil)
	if failure ~= nil then
		error(failure, 0)
	end
end

local function lookAt(player: Player, yaw: number, pitch: number)
	PlayerStateService.SubmitLook(player, MathUtil.quantizeAngle(yaw), MathUtil.quantizeAngle(pitch))
end

-- The direction the server's quantized look points (what a client relaying that look throws along).
local function serverLook(player: Player): Vector3
	local yaw, pitch = PlayerStateService.GetLook(player)
	return MathUtil.vectorFromYawPitch(yaw, pitch)
end

local function last(world: World): Payload?
	return world.events[#world.events]
end

local function baseThrow(overrides: { [string]: any }?): ThrowCheck
	local check: ThrowCheck = {
		live = true,
		holding = true,
		lifeState = "Alive",
		moveState = "Standing",
		controlLock = "None",
		hasBody = true,
		now = 100,
		lastThrowAt = nil,
		direction = Vector3.new(0, 0, -1),
		look = Vector3.new(0, 0, -1),
	}
	if overrides then
		for key, value in overrides do
			(check :: any)[key] = value
		end
	end
	return check
end

local function cloudView(overrides: { [string]: any }?): CloudView
	local cloud: CloudView = {
		centre = Vector3.new(0, 0.6, 0),
		levelId = SCIENCE,
		ventNode = nil,
		expiresAt = 107,
		spent = false,
	}
	if overrides then
		for key, value in overrides do
			(cloud :: any)[key] = value
		end
	end
	return cloud
end

local function creatureView(overrides: { [string]: any }?): CreatureView
	local view: CreatureView = {
		levelId = SCIENCE,
		state = "Patrol",
		hidden = false,
		inVent = false,
		segmentId = nil,
		rootPosition = Vector3.new(6, 3, 0),
		hitboxCFrame = CFrame.new(6, 4, 0),
		hitboxSize = Vector3.new(3, 8, 2),
	}
	if overrides then
		for key, value in overrides do
			(view :: any)[key] = value
		end
	end
	return view
end

local function clearLine(_from: Vector3, _to: Vector3): boolean
	return true
end

local function blockedLine(_from: Vector3, _to: Vector3): boolean
	return false
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["ballistics: the parabola, its velocity and apex"] = function(t: Expect)
		local origin = Vector3.new(1, 5, -2)
		local velocity = Vector3.new(10, 20, -30)
		local g = 64
		t.truthy(near(Ballistics.position(origin, velocity, g, 0), origin, EPS), "t = 0 is the release")
		local p = Ballistics.position(origin, velocity, g, 0.5)
		t.truthy(near(p, Vector3.new(1 + 5, 5 + 10 - 8, -2 - 15), 1e-9), "x + vt - g t^2 / 2")
		local v = Ballistics.velocityAt(velocity, g, 0.25)
		t.truthy(near(v, Vector3.new(10, 4, -30), 1e-9), "gravity only bends the vertical")
		local apex = Ballistics.apexTime(velocity, g)
		t.near(apex, 20 / 64, 1e-12)
		t.near(Ballistics.velocityAt(velocity, g, apex).Y, 0, 1e-9, "level at the apex")
		t.eq(Ballistics.apexTime(Vector3.new(5, -1, 0), g), 0, "a downward throw has no apex ahead")
		t.truthy(near(Ballistics.launchVelocity(Vector3.new(0, 0, -3), 70), Vector3.new(0, 0, -70), 1e-9))
		t.truthy(Ballistics.launchVelocity(Vector3.zero, 70) == Vector3.zero)
	end,

	["ballistics: who may throw, and how hard"] = function(t: Expect)
		for _, state: Enums.MoveState in BLOCKED do
			t.falsy(Ballistics.mayThrowIn(state), state .. " holds the body or the hands")
		end
		for _, state: Enums.MoveState in FREE do
			t.truthy(Ballistics.mayThrowIn(state), state)
		end
		t.eq(#Ballistics.BlockedStates, #BLOCKED)
		t.near(Ballistics.throwSpeed("Standing"), GameConfig.FlaskThrowSpeed, EPS)
		t.near(Ballistics.throwSpeed("Sprinting"), GameConfig.FlaskThrowSpeed, EPS)
		t.near(Ballistics.throwSpeed("VentCrawling"), GameConfig.FlaskThrowSpeed * 0.45, EPS, "a short toss in a duct")
		t.near(Ballistics.throwSpeed("VentScurrying"), GameConfig.FlaskThrowSpeed * 0.45, EPS)
		t.near(Ballistics.VentTossMultiplier, 0.45, EPS)
	end,

	["ballistics: the release is right of, below and ahead of the eye, pulled back from walls"] = function(t: Expect)
		local eye = Vector3.new(4, 5, 6)
		local directions: { Vector3 } = {
			Vector3.new(0, 0, -1),
			Vector3.new(1, 0.4, 0).Unit,
			Vector3.new(-0.3, -0.6, 0.7).Unit,
			Vector3.new(0, 1, 0),
			Vector3.new(0, -1, 0),
		}
		for _, direction in directions do
			local frame = Ballistics.throwFrame(eye, direction)
			t.truthy(near(frame.Position, eye, EPS), "the frame sits at the eye")
			t.near(frame.LookVector:Dot(direction), 1, 1e-6, "it looks along the throw")
			t.near(frame.RightVector:Dot(frame.UpVector), 0, 1e-6, "orthonormal")
			t.near(frame.RightVector.Magnitude, 1, 1e-6)
			local offset = frame:PointToObjectSpace(Ballistics.releasePoint(eye, direction))
			t.truthy(near(offset, Ballistics.ReleaseOffset, 1e-6), "the offset in the throw's frame")
			if math.abs(direction.Y) < 0.9 then
				t.truthy(frame.UpVector.Y > 0, "up stays up")
			end
		end
		local level = Ballistics.releasePoint(eye, Vector3.new(0, 0, -1)) - eye
		t.truthy(level.X > 0 and level.Y < 0 and level.Z < 0, "right, down, ahead when looking down -Z")

		local point = eye + Vector3.new(0.45, -0.3, -0.6)
		t.truthy(Ballistics.pullBack(eye, point, nil) == point, "a clear line keeps the release")
		local blockedAt = eye:Lerp(point, 0.5)
		local pulled = Ballistics.pullBack(eye, point, blockedAt)
		t.near((pulled - eye).Magnitude, (blockedAt - eye).Magnitude - Ballistics.PullBackSkin, 1e-6, "short of it")
		t.near((pulled - eye).Unit:Dot((point - eye).Unit), 1, 1e-6, "on the same line")
		t.truthy(near(Ballistics.pullBack(eye, point, eye), eye, 1e-9), "never behind the eye")
		t.truthy(near(Ballistics.pullBack(eye, eye, blockedAt), eye, 1e-9), "a release at the eye stays there")
	end,

	["ballistics: stepped flight hits where the parabola meets the floor, in short segments, or expires"] = function(
		t: Expect
	)
		local origin = Vector3.new(0, 5, 0)
		local velocity = Vector3.new(0, 0, -40)
		local g = 64
		local casts = 0
		local longest = 0
		local floor = floorCast(0)
		local function cast(from: Vector3, to: Vector3): Hit?
			casts += 1
			longest = math.max(longest, (to - from).Magnitude)
			return floor(from, to, {}, true)
		end
		local result = Ballistics.advance(origin, velocity, g, 0, 10, 3, 1 / 60, cast)
		local expected = math.sqrt(2 * 5 / g)
		local hit = result.hit
		t.truthy(hit ~= nil, "it lands")
		t.near(result.t, expected, 1e-3, "at the analytic landing time")
		t.near(result.position.Y, 0, EPS, "on the floor")
		t.near(result.position.Z, -40 * expected, 0.05)
		t.falsy(result.expired)
		local fastest = Ballistics.velocityAt(velocity, g, expected).Magnitude
		t.truthy(longest <= fastest / 60 + 1e-6, "no segment is longer than the step allows")
		t.truthy(casts >= math.floor(expected * 60), "every stretch is cast")

		-- Split into frames, the same landing.
		local tFrom = 0
		local split: Ballistics.Advance? = nil
		for frame = 1, 120 do
			local step = Ballistics.advance(origin, velocity, g, tFrom, frame / 60, 3, 1 / 60, cast)
			tFrom = step.t
			if step.hit then
				split = step
				break
			end
		end
		t.truthy(split ~= nil and math.abs((split :: Ballistics.Advance).t - result.t) < 1e-9, "frame by frame alike")

		local open = Ballistics.advance(origin, Vector3.new(0, 30, 0), g, 0, 10, 3, 1 / 30, function(): Hit?
			return nil
		end)
		t.truthy(open.expired, "nothing hit in the maximum flight time")
		t.near(open.t, 3, 1e-9)
		local idle = Ballistics.advance(origin, velocity, g, 0.5, 0.2, 3, 1 / 60, cast)
		t.near(idle.t, 0.5, 1e-12, "a stretch backwards does not move")
		t.falsy(idle.expired)
	end,

	["ballistics: the traced arc and its evenly spaced beads"] = function(t: Expect)
		local floor = floorCast(0)
		local hit, points, duration = Ballistics.trace(
			Vector3.new(0, 4, 0),
			Vector3.new(20, 15, 0),
			64,
			3,
			1 / 24,
			function(from: Vector3, to: Vector3): Hit?
				return floor(from, to, {}, true)
			end
		)
		t.truthy(hit ~= nil, "a lob comes down on the floor")
		t.truthy(near(points[1], Vector3.new(0, 4, 0), EPS), "from the release")
		t.near(points[#points].Y, 0, EPS, "to the landing")
		t.truthy(duration > 0.4 and duration < 1, "about two thirds of a second")
		local beads = Ballistics.resample(points, 9)
		t.eq(#beads, 9)
		t.truthy(near(beads[1], points[1], EPS) and near(beads[9], points[#points], EPS), "both ends kept")
		local gaps: { number } = {}
		for i = 2, #beads do
			table.insert(gaps, (beads[i] - beads[i - 1]).Magnitude)
		end
		for _, gap in gaps do
			t.near(gap, gaps[1], gaps[1] * 0.08, "even spacing along the path")
		end
		t.eq(#Ballistics.resample({}, 4), 0)
		t.eq(#Ballistics.resample({ Vector3.one }, 3), 3, "a single point repeats")
		t.eq(#Ballistics.resample(points, 0), 0)
		local _, unbroken = Ballistics.trace(Vector3.zero, Vector3.new(0, 10, 0), 64, 0.5, 0.1, function(): Hit?
			return nil
		end)
		t.truthy(#unbroken >= 6, "every step leaves a point")
		t.truthy(near(unbroken[#unbroken], Vector3.new(0, -3, 0), EPS), "an expired trace stops at the limit")
	end,

	["ballistics: the pool's surface stops a flask at the top face of its volume"] = function(t: Expect)
		local box = CFrame.new(10, -2, 0)
		local size = Vector3.new(20, 4, 10) -- top at y = 0, x 0..20, z -5..5
		local down = Ballistics.surfaceCrossing(box, size, Vector3.new(5, 1, 0), Vector3.new(7, -1, 0))
		t.near(down or -1, 0.5, 1e-9, "half way down the segment")
		local up = Ballistics.surfaceCrossing(box, size, Vector3.new(5, -1, 0), Vector3.new(5, 3, 0))
		t.near(up or -1, 0.25, 1e-9, "from below too")
		t.eq(Ballistics.surfaceCrossing(box, size, Vector3.new(-5, 1, 0), Vector3.new(-3, -1, 0)), nil, "off the pool")
		t.eq(Ballistics.surfaceCrossing(box, size, Vector3.new(5, 1, 0), Vector3.new(6, 0.5, 0)), nil, "above it")
		t.eq(Ballistics.surfaceCrossing(box, size, Vector3.new(5, 1, 6), Vector3.new(5, -1, 6)), nil, "past its side")
		local tilted = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(45), 0)
		local square = Vector3.new(4, 2, 4)
		t.truthy(Ballistics.surfaceCrossing(tilted, square, Vector3.new(0, 2, 2.5), Vector3.new(0, 0, 2.5)) ~= nil)
		t.eq(
			Ballistics.surfaceCrossing(tilted, square, Vector3.new(2.5, 2, 2.5), Vector3.new(2.5, 0, 2.5)),
			nil,
			"a rotated footprint"
		)
		t.eq(
			Ballistics.surfaceCrossing(box, size, Vector3.new(math.sqrt(-1), 1, 0), Vector3.new(5, -1, 0)),
			nil,
			"non-finite"
		)
	end,

	["rules: throws leave within the look tolerance, Alive, free, unlocked, after the cooldown"] = function(t: Expect)
		local forward = Vector3.new(0, 0, -1)
		local function turned(degrees: number): Vector3
			return CFrame.Angles(0, math.rad(degrees), 0):VectorToWorldSpace(forward)
		end
		t.truthy(ChemicalProjectileService.withinLook(forward, forward, 25))
		t.truthy(ChemicalProjectileService.withinLook(turned(24.9), forward, 25))
		t.falsy(ChemicalProjectileService.withinLook(turned(25.2), forward, 25))
		t.falsy(ChemicalProjectileService.withinLook(-forward, forward, 25))
		t.falsy(ChemicalProjectileService.withinLook(Vector3.zero, forward, 25), "no direction")
		t.falsy(ChemicalProjectileService.withinLook(Vector3.new(math.huge, 0, 0), forward, 25), "non-finite")
		t.eq(ChemicalProjectileService.LookTolerance, 25)

		t.eq(verdict(ChemicalProjectileService.throwEligible(baseThrow())), "ok")
		t.eq(verdict(ChemicalProjectileService.throwEligible(baseThrow({ live = false }))), "NoRun")
		t.eq(verdict(ChemicalProjectileService.throwEligible(baseThrow({ holding = false }))), "NotHolding")
		for _, state: Enums.LifeState in NOT_ALIVE do
			local check = baseThrow({ lifeState = state })
			t.eq(verdict(ChemicalProjectileService.throwEligible(check)), "LifeState", state .. " cannot throw")
		end
		t.eq(verdict(ChemicalProjectileService.throwEligible(baseThrow({ hasBody = false }))), "NoBody")
		t.eq(verdict(ChemicalProjectileService.throwEligible(baseThrow({ controlLock = "Cutscene" }))), "Locked")
		for _, state: Enums.MoveState in BLOCKED do
			local check = baseThrow({ moveState = state })
			t.eq(verdict(ChemicalProjectileService.throwEligible(check)), "MoveState", state)
		end
		for _, state: Enums.MoveState in { "VentCrawling", "Treading", "Sprinting" } :: { Enums.MoveState } do
			t.eq(verdict(ChemicalProjectileService.throwEligible(baseThrow({ moveState = state }))), "ok", state)
		end
		local cooldown = GameConfig.FlaskThrowCooldown
		t.eq(
			verdict(ChemicalProjectileService.throwEligible(baseThrow({ lastThrowAt = 100 - cooldown + 0.01 }))),
			"Cooldown"
		)
		t.eq(verdict(ChemicalProjectileService.throwEligible(baseThrow({ lastThrowAt = 100 - cooldown }))), "ok")
		t.eq(verdict(ChemicalProjectileService.throwEligible(baseThrow({ direction = turned(40) }))), "Look")
	end,

	["rules: an Alive player with a free hand takes an untaken flask"] = function(t: Expect)
		local function check(overrides: { [string]: any }?): ChemicalProjectileService.PickupCheck
			local value: ChemicalProjectileService.PickupCheck =
				{ live = true, lifeState = "Alive", holding = false, taken = false }
			for key, field in (overrides or {}) :: { [string]: any } do
				(value :: any)[key] = field
			end
			return value
		end
		t.eq(verdict(ChemicalProjectileService.pickupEligible(check())), "ok")
		t.eq(verdict(ChemicalProjectileService.pickupEligible(check({ live = false }))), "NoRun")
		t.eq(verdict(ChemicalProjectileService.pickupEligible(check({ taken = true }))), "Taken")
		for _, state: Enums.LifeState in NOT_ALIVE do
			t.eq(verdict(ChemicalProjectileService.pickupEligible(check({ lifeState = state }))), "LifeState", state)
		end
		local ok, reason = ChemicalProjectileService.pickupEligible(check({ holding = true }))
		t.falsy(ok, "one flask at a time")
		t.eq(reason, ChemicalProjectileService.HandsFullHint)
		t.truthy(reason ~= nil and Strings.has(reason), "the refusal is a Strings key the player is shown")
	end,

	["rules: the cloud reaches a hitbox within its radius along a clear line only"] = function(t: Expect)
		local box = CFrame.new(10, 4, 0) * CFrame.Angles(0, math.rad(30), 0)
		local size = Vector3.new(3, 8, 2)
		t.eq(ChemicalProjectileService.boxDistance(box, size, box.Position), 0, "inside")
		t.near(ChemicalProjectileService.boxDistance(CFrame.new(), Vector3.new(2, 2, 2), Vector3.new(4, 0, 0)), 3, EPS)
		t.near(
			ChemicalProjectileService.boxDistance(CFrame.new(), Vector3.new(2, 2, 2), Vector3.new(4, 5, 0)),
			5,
			EPS,
			"to a corner edge"
		)
		local points = ChemicalProjectileService.reachPoints(box, size, Vector3.new(0, 1, 0))
		t.eq(#points, 3, "centre, nearest and top")
		for _, point in points do
			t.eq(ChemicalProjectileService.boxDistance(box, size, point), 0, "every target lies in the hitbox")
		end
		t.truthy(near(points[1], box.Position, EPS))
		t.truthy(points[3].Y > box.Position.Y + 3, "the top target is high on it")

		local radius = GameConfig.FlaskCloudRadius
		local centre = Vector3.new(0, 1, 0)
		t.truthy(ChemicalProjectileService.cloudReaches(centre, radius, box, size, clearLine))
		t.falsy(ChemicalProjectileService.cloudReaches(centre, radius, box, size, blockedLine), "through a wall: no")
		local seen = 0
		local function onlyTop(_from: Vector3, to: Vector3): boolean
			seen += 1
			return to.Y > 6
		end
		t.truthy(ChemicalProjectileService.cloudReaches(centre, radius, box, size, onlyTop), "over a desk to its head")
		t.eq(seen, 3, "the centre and the nearest point were tried first")
		local far = CFrame.new(radius + 5, 4, 0)
		t.falsy(ChemicalProjectileService.cloudReaches(centre, radius, far, size, clearLine), "out of range")
		local edge = Vector3.new(far.Position.X - size.X / 2 - radius + 0.01, 4, 0)
		t.truthy(
			ChemicalProjectileService.cloudReaches(edge, radius, far, size, clearLine),
			"the radius reaches to the hitbox's face, not its centre"
		)
	end,

	["rules: stun verdicts"] = function(t: Expect)
		local function check(
			cloud: CloudView,
			creature: CreatureView?,
			hops: number?,
			line: ChemicalProjectileService.LineClear
		): string
			local _, reason = ChemicalProjectileService.stunVerdict(cloud, creature, 100, hops, line)
			return reason
		end
		t.eq(check(cloudView(), creatureView(), nil, clearLine), "Radius")
		t.eq(check(cloudView(), creatureView(), nil, blockedLine), "OutOfReach", "never through a wall")
		t.eq(check(cloudView({ spent = true }), creatureView(), nil, clearLine), "Spent", "once per cloud")
		t.eq(check(cloudView({ expiresAt = 99 }), creatureView(), nil, clearLine), "Expired")
		t.eq(check(cloudView(), nil, nil, clearLine), "NoCreature")
		t.eq(check(cloudView(), creatureView({ levelId = "Level3_Gymnasium" }), nil, clearLine), "Level")
		t.eq(check(cloudView(), creatureView({ hidden = true }), nil, clearLine), "Hidden")
		for _, state: Enums.MonsterState in { "Stunned", "Scripted", "Dormant" } :: { Enums.MonsterState } do
			t.falsy(ChemicalProjectileService.stunnableState(state), state)
			t.eq(check(cloudView(), creatureView({ state = state }), nil, clearLine), "State", state)
		end
		for _, state: Enums.MonsterState in
			{ "Patrol", "InvestigateNoise", "WallChase", "VentChase", "AquaticStalk" } :: { Enums.MonsterState }
		do
			t.truthy(ChemicalProjectileService.stunnableState(state), state)
		end
		local far = creatureView({ hitboxCFrame = CFrame.new(60, 4, 0), rootPosition = Vector3.new(60, 3, 0) })
		t.eq(check(cloudView(), far, nil, clearLine), "OutOfReach", "beyond the radius")
		local ducted = cloudView({ ventNode = "B" })
		local crawling = creatureView({ inVent = true, hitboxCFrame = CFrame.new(60, 4, 0) })
		local radius = GameConfig.FlaskVentHopRadius
		t.eq(check(ducted, crawling, radius, blockedLine), "Vent", "down the duct, round its bends")
		t.eq(check(ducted, crawling, 0, blockedLine), "Vent")
		t.eq(check(ducted, crawling, nil, blockedLine), "OutOfReach", "too many hops (or no route)")
		t.eq(check(cloudView(), crawling, 1, blockedLine), "OutOfReach", "a room cloud uses the radius")
		t.eq(check(ducted, far, 1, blockedLine), "OutOfReach", "a Creature out of the ducts uses the radius")
		local ok = ChemicalProjectileService.stunVerdict(cloudView(), creatureView(), 100, nil, clearLine)
		t.truthy(ok)
	end,

	["rules: the duct bore, its grate openings and the nearest node"] = function(t: Expect)
		local graph = ductGraph()
		local across, along, length =
			ChemicalProjectileService.boreOffset(Vector3.zero, Vector3.new(10, 0, 0), Vector3.new(4, 1, -1.5))
		t.near(across, 1.5, EPS, "the larger offset across the square bore")
		t.near(along, 4, EPS)
		t.near(length, 10, EPS)
		local riser = ChemicalProjectileService.boreOffset(Vector3.zero, Vector3.new(0, 10, 0), Vector3.new(1, 3, 0.5))
		t.near(riser, 1, EPS, "vertical ducts too")

		t.eq(ChemicalProjectileService.ductNode(graph, Vector3.new(4, 2, 0)), "A", "on the centreline, near A")
		t.eq(ChemicalProjectileService.ductNode(graph, Vector3.new(14, 2 - HALF_BORE, 0)), "B", "the duct floor")
		t.eq(ChemicalProjectileService.ductNode(graph, Vector3.new(10, 2 + HALF_BORE, HALF_BORE)), "A", "a corner")
		t.eq(
			ChemicalProjectileService.ductNode(graph, Vector3.new(10, 2 + HALF_BORE + WorldConfig.VentShell, 0)),
			nil,
			"the shell's outer face is outside"
		)
		t.eq(ChemicalProjectileService.ductNode(graph, Vector3.new(21.5, 2, -1.5)), "B", "inside the elbow's corner")
		t.eq(ChemicalProjectileService.ductNode(graph, Vector3.new(60 + HALF_BORE, 2, 20)), "E", "the dead end's cap")
		t.eq(ChemicalProjectileService.ductNode(graph, Vector3.new(60 + HALF_BORE + 1, 2, 20)), nil, "past it")
		t.eq(ChemicalProjectileService.ductNode(graph, Vector3.new(10, 8, 0)), nil, "the room above")
		-- The grate opening on A runs west through its wall (room face at x = -3).
		t.eq(ChemicalProjectileService.ductNode(graph, Vector3.new(-2.8, 2 - HALF_BORE, 0.5)), "A", "in the opening")
		t.eq(ChemicalProjectileService.ductNode(graph, Vector3.new(-3.2, 2 - HALF_BORE, 0)), nil, "the room's floor")
		t.eq(ChemicalProjectileService.ductNode(graph, Vector3.new(math.sqrt(-1), 2, 0)), nil, "non-finite")

		t.eq(
			ChemicalProjectileService.snapNode({ a = "A", b = "B", t = 0.4, position = Vector3.zero, distance = 0 }),
			"A"
		)
		t.eq(
			ChemicalProjectileService.snapNode({ a = "A", b = "B", t = 0.6, position = Vector3.zero, distance = 0 }),
			"B"
		)
		t.eq(
			ChemicalProjectileService.snapNode({ a = "A", b = nil, t = 0.9, position = Vector3.zero, distance = 0 }),
			"A"
		)
	end,

	["rules: vent hops and the Creature's node"] = function(t: Expect)
		local graph = ductGraph()
		local hops = ChemicalProjectileService.ventHops
		t.eq(hops(graph, "A", "A", 2), 0)
		t.eq(hops(graph, "A", "B", 2), 1)
		t.eq(hops(graph, "A", "C", 2), 2)
		t.eq(hops(graph, "C", "A", 2), 2, "both ways")
		t.eq(hops(graph, "A", "D", 2), nil, "three hops is out of reach")
		t.eq(hops(graph, "A", "D", 3), 3)
		t.eq(hops(graph, "A", "F", 10), nil, "no route")
		t.eq(hops(graph, "A", "Z", 10), nil, "unknown node")
		t.eq(hops(graph, "A", "B", 0), nil, "a zero radius only reaches its own node")

		local node = ChemicalProjectileService.creatureVentNode
		t.eq(node(graph, "B-C", Vector3.new(20, 2, 4)), "B", "the nearer end of its segment")
		t.eq(node(graph, "B-C", Vector3.new(20, 2, 16)), "C")
		t.eq(node(graph, "nowhere", Vector3.new(38, 2, 20)), "D", "an unknown segment: the nearest rail point")
		t.eq(node(graph, nil, Vector3.new(2, 2, 0)), "A")
		t.eq(node(graph, "", Vector3.new(59, 2, 20)), "E")
	end,

	["rules: a flask's variant from its liquid"] = function(t: Expect)
		for variant = 0, 2 do
			t.eq(ChemicalProjectileService.variantForColor(ChemicalFlaskBuilder.liquidColor(variant)), variant)
		end
		local greenish = ChemicalFlaskBuilder.liquidColor(0):Lerp(Color3.new(1, 1, 1), 0.1)
		t.eq(ChemicalProjectileService.variantForColor(greenish), 0, "a lit or dimmed liquid still matches")
		t.eq(
			ChemicalProjectileService.variantForColor(ChemicalFlaskBuilder.liquidColor(7)),
			7 % 3,
			"colours repeat every three variants"
		)
	end,

	["live: a world flask is taken by one free, Alive hand and leaves the world"] = function(t: Expect)
		quiet(function()
			local player = fakePlayer(CFrame.new(0, 3, 0))
			local other = fakePlayer(CFrame.new(4, 3, 0))
			inRun({ player, other }, function(_world: World)
				t.eq(player:GetAttribute(P.HeldItem), "None", "the hand starts empty")
				local handler = ChemicalProjectileService.PickupHandler
				local canUse = handler.canUse :: (Player, ProximityPrompt, Instance) -> (boolean, string?)

				-- SpawnFlask builds a tracked, served world flask on the level (kept, not destroyed, then taken out of
				-- the world: InteractionService still files its host, and Lune cannot read destroyed instances).
				local spawned = ChemicalProjectileService.SpawnFlask(SCIENCE, CFrame.new(0, 0, -3), 1)
				assert(spawned, "SpawnFlask builds a world flask during a run")
				t.truthy(spawned:IsDescendantOf(Workspace), "in the level's runtime folder")
				t.truthy(spawned:HasTag(Tags.ChemicalItem) and spawned:HasTag(Tags.Interactable))
				local spawnedPrompt = PropKit.findPrompt(spawned, "Pickup")
				assert(spawnedPrompt, "flasks carry a Pickup prompt")
				t.truthy(InteractionService.matches(handler, spawned, spawnedPrompt), "a tracked flask is served")
				t.eq(ChemicalProjectileService.CountAvailable(SCIENCE), 1)
				t.eq(ChemicalProjectileService.CountAvailable("Level4_FloodedPool"), 0, "per level")
				t.eq(ChemicalProjectileService.SpawnFlask(SCIENCE, CFrame.new(math.huge, 0, 0), 1), nil, "non-finite")
				spawned.Parent = nil
				t.eq(ChemicalProjectileService.CountAvailable(SCIENCE), 0, "a flask out of the world is not available")

				-- Plan-built flasks (here outside the DataModel, so the prompt service never files them).
				local folder = Instance.new("Folder")
				local function planFlask(index: number, variant: number): (Model, ProximityPrompt)
					local plan: Types.PlannedProp = {
						kind = ChemicalFlaskBuilder.Kind,
						anchorId = "SpecFlask" .. index,
						levelId = SCIENCE,
						cframe = CFrame.new(index * 2, 0, -3),
						variant = variant,
					}
					local built = Builder.BuildProp(plan, folder, Random.new(index))
					assert(built and built:IsA("Model"), "the flask builder builds a Model")
					t.truthy(ChemicalProjectileService.Track(built))
					local found = PropKit.findPrompt(built, "Pickup")
					assert(found, "flasks carry a Pickup prompt")
					return built, found
				end
				local first, prompt = planFlask(1, 1)
				local second, secondPrompt = planFlask(2, 5)
				t.eq(ChemicalProjectileService.CountAvailable(SCIENCE), 2)
				local stray = Instance.new("Model")
				stray:AddTag(Tags.Interactable)
				stray:AddTag(Tags.ChemicalItem)
				local strayPrompt = Instance.new("ProximityPrompt")
				strayPrompt:SetAttribute(W.PromptKind, "Pickup")
				strayPrompt.Parent = stray
				t.falsy(InteractionService.matches(handler, stray, strayPrompt), "an untracked one is not served")
				t.falsy(ChemicalProjectileService.Track(Instance.new("Model")), "only ChemicalItems are tracked")
				stray:Destroy()
				t.eq(verdict(canUse(player, prompt, first)), "ok")

				handler.onComplete(player, prompt, first)
				t.eq(player:GetAttribute(P.HeldItem), "ChemicalFlask")
				t.eq(
					player:GetAttribute(P.HeldItemVariant),
					ChemicalProjectileService.variantForColor(ChemicalFlaskBuilder.liquidColor(1)),
					"the flask's own look (read back from its liquid outside a plan)"
				)
				local readable = pcall(function(): Instance?
					return first.Parent
				end)
				-- (Lune refuses every access to a destroyed instance; the engine reads Parent nil.)
				t.truthy(not readable or first.Parent == nil, "the prop leaves the world")
				t.eq(ChemicalProjectileService.CountAvailable(SCIENCE), 1)
				t.truthy(ChemicalProjectileService.GetHeld(player) ~= nil)
				t.eq(verdict(canUse(player, secondPrompt, second)), ChemicalProjectileService.HandsFullHint)
				local before = player:GetAttribute(P.HeldItemVariant)
				handler.onComplete(player, secondPrompt, second)
				t.eq(player:GetAttribute(P.HeldItemVariant), before, "a second flask is never taken")
				t.truthy(second.Parent ~= nil)
				t.eq(verdict(canUse(other, secondPrompt, second)), "ok", "a teammate with a free hand may")
				t.falsy(ChemicalProjectileService.Give(player, 2), "Give never fills a full hand")
				LifeStateService.Down(other, "Spec")
				t.eq(verdict(canUse(other, secondPrompt, second)), "LifeState", "a downed teammate may not")

				-- A flask someone already took (HeldByUserId) is never offered again.
				local taken = planFlask(3, 2)
				ChemicalProjectileService.OnPlayerRemoving(other)
				local copy = taken:Clone()
				copy:SetAttribute(W.HeldByUserId, other.UserId)
				copy.Parent = folder
				t.truthy(ChemicalProjectileService.Track(copy))
				local copyPrompt = PropKit.findPrompt(copy, "Pickup") :: ProximityPrompt
				t.falsy(InteractionService.matches(handler, copy, copyPrompt), "taken: not served")
				t.eq(ChemicalProjectileService.CountAvailable(SCIENCE), 2, "the second and the third")
				folder:Destroy()
			end)
			t.eq(player:GetAttribute(P.HeldItem), "None", "the end of the run empties the hand")
			t.eq(player:GetAttribute(P.HeldItemVariant), nil)
			t.falsy(ChemicalProjectileService.Give(player, 1), "no flasks outside a run")
			t.eq(ChemicalProjectileService.SpawnFlask(SCIENCE, CFrame.new(), 0), nil)
		end)
	end,

	["live: a throw leaves the eye along the look, flies and shatters on the floor; its cloud stuns once"] = function(
		t: Expect
	)
		quiet(function()
			local player, root = fakePlayer(CFrame.new(0, 3, 0))
			inRun({ player }, function(world: World)
				local creature = fakeCreature(Vector3.new(0, 0, -300))
				world.creature = creature
				lookAt(player, 0, 0)
				local forward = serverLook(player)
				t.eq(verdict(ChemicalProjectileService.RequestThrow(player, forward)), "NotHolding")
				t.truthy(ChemicalProjectileService.Give(player, 2))
				local aside = CFrame.Angles(0, math.rad(40), 0):VectorToWorldSpace(forward)
				t.eq(verdict(ChemicalProjectileService.RequestThrow(player, aside)), "Look", "not where they look")
				t.eq(#world.events, 0)

				t.eq(verdict(ChemicalProjectileService.RequestThrow(player, forward)), "ok")
				t.eq(player:GetAttribute(P.HeldItem), "None", "the hand empties at once")
				t.eq(RunStatsService.Get(player, "FlasksThrown"), 1)
				local launch = last(world)
				assert(launch, "a Launch went out")
				t.eq(launch.phase, "Spawn")
				t.eq(launch.variant, 2)
				t.eq(launch.throwerUserId, player.UserId)
				t.near(launch.t0, world.clock, EPS, "it flies from now")
				t.near(launch.gravity, Ballistics.Gravity, EPS)
				local eye = root.CFrame.Position + Vector3.new(0, CameraConfig.EyeHeightAboveRoot.Standing, 0)
				t.truthy(near(launch.origin, Ballistics.releasePoint(eye, forward), 1e-6), "from the hand by the eye")
				t.truthy(near(launch.velocity, forward * GameConfig.FlaskThrowSpeed, 1e-6), "at the throw speed")

				ChemicalProjectileService.StepFlights(world.clock + 0.1)
				t.eq(#world.events, 1, "still in the air")
				t.eq(#ChemicalProjectileService.GetFlights(), 1)
				ChemicalProjectileService.StepFlights(world.clock + 2)
				local resolve = last(world)
				assert(resolve and resolve.phase == "Resolve", "the flight resolved")
				t.eq(resolve.hitKind, "World")
				t.eq(resolve.inVent, false)
				local point = resolve.hitPosition :: Vector3
				t.near(point.Y, 0, 1e-6, "on the floor")
				local fall = launch.origin.Y
				local landing = math.sqrt(2 * fall / Ballistics.Gravity)
				t.near(
					point.Z,
					launch.origin.Z - GameConfig.FlaskThrowSpeed * landing,
					0.05,
					"where the arc comes down"
				)
				t.truthy(near(resolve.hitNormal :: Vector3, Vector3.yAxis, EPS))
				t.eq(#world.shatters, 1, "Shattered fired")
				t.eq(world.shatters[1].thrower, player)
				t.eq(world.shatters[1].inVent, false)
				t.eq(#world.stuns, 0, "the Creature is far away")
				local clouds = ChemicalProjectileService.GetClouds()
				t.eq(#clouds, 1)
				t.truthy(near(clouds[1].centre, point + Vector3.yAxis * ChemicalProjectileService.CloudLift, EPS))
				t.near(clouds[1].expiresAt, world.clock + GameConfig.FlaskCloudSeconds, EPS)
				local heard = NoiseAndDirectorService.RecentNoises(0)
				local noise = heard[#heard]
				t.truthy(noise and noise.kind == "FlaskShatter" and noise.sourceUserId == player.UserId, "it is heard")

				-- The Creature walks into the lingering cloud: stunned once, from the shatter point.
				world.clock += 1
				moveCreature(creature, point + Vector3.new(4, 0, 0))
				world.clear = false
				ChemicalProjectileService.PollClouds(world.clock)
				t.eq(#world.stuns, 0, "never through a wall")
				world.state = "Stunned"
				world.clear = true
				ChemicalProjectileService.PollClouds(world.clock)
				t.eq(#world.stuns, 0, "already stunned: the cloud keeps its charge")
				world.state = "WallChase"
				ChemicalProjectileService.PollClouds(world.clock)
				t.eq(#world.stuns, 1, "stunned on walking in")
				t.near(world.stuns[1].seconds, GameConfig.StunSeconds, EPS)
				t.truthy(near(world.stuns[1].from, point, EPS), "it retreats away from the shatter")
				t.eq(RunStatsService.Get(player, "Stuns"), 1, "credited to the thrower")
				ChemicalProjectileService.PollClouds(world.clock + 0.1)
				t.eq(#world.stuns, 1, "once per cloud")
				world.clock += GameConfig.FlaskCloudSeconds
				ChemicalProjectileService.PollClouds(world.clock)
				t.eq(#ChemicalProjectileService.GetClouds(), 0, "the cloud thins away")

				-- The cooldown, then a second flask onto the waiting Creature: stunned at the shatter.
				t.truthy(ChemicalProjectileService.Give(player, 0))
				world.clock += 0.5
				t.eq(verdict(ChemicalProjectileService.RequestThrow(player, forward)), "ok", "past the cooldown")
				t.truthy(ChemicalProjectileService.Give(player, 0))
				t.eq(verdict(ChemicalProjectileService.RequestThrow(player, forward)), "Cooldown")
				ChemicalProjectileService.StepFlights(world.clock + 2)
				t.eq(#world.stuns, 2, "a cloud on the Creature stuns it at once")
				t.eq(#world.shatters, 2)
			end)
		end)
	end,

	["live: blocked states, the vent toss, an in-duct shatter stunning by hops, an expired flight"] = function(
		t: Expect
	)
		quiet(function()
			local player = fakePlayer(CFrame.new(0, 3, 0))
			inRun({ player }, function(world: World)
				lookAt(player, 0, 0)
				local forward = serverLook(player)
				t.truthy(ChemicalProjectileService.Give(player, 4))
				for _, state: Enums.MoveState in { "Hiding", "Trapped", "Grabbed" } :: { Enums.MoveState } do
					PlayerStateService.PushOverride(player, "ChemicalSpec", state)
					t.eq(verdict(ChemicalProjectileService.RequestThrow(player, forward)), "MoveState", state)
				end
				PlayerStateService.PopOverride(player, "ChemicalSpec")

				-- Crawling the duct A-B (the root on its centreline): a short toss that breaks on the duct floor.
				PlayerStateService.SetMode(player, "Vent")
				t.eq(PlayerStateService.GetMoveState(player), "VentCrawling")
				local character = player.Character :: Model
				local root = character:FindFirstChild("HumanoidRootPart") :: BasePart
				root.CFrame = CFrame.new(6, 2, 0)
				root.Position = root.CFrame.Position
				lookAt(player, -math.pi / 2, 0) -- along +X, down the duct toward B
				local along = serverLook(player)
				world.cast = floorCast(2 - HALF_BORE)
				local creature = fakeCreature(Vector3.new(40, 0.25, 20))
				creature:SetAttribute(C.InVent, true)
				creature:SetAttribute(C.VentSegmentId, "C-D")
				moveCreature(creature, Vector3.new(24, 0.25, 20)) -- in C-D, nearest C: one hop from B
				world.creature = creature
				world.clear = false
				t.eq(verdict(ChemicalProjectileService.RequestThrow(player, along)), "ok")
				local launch = last(world) :: Payload
				t.near(launch.velocity.Magnitude, GameConfig.FlaskThrowSpeed * Ballistics.VentTossMultiplier, 1e-6)
				ChemicalProjectileService.StepFlights(world.clock + 1)
				local resolve = last(world) :: Payload
				t.eq(resolve.phase, "Resolve")
				t.eq(resolve.inVent, true, "it broke inside the duct")
				t.eq(world.shatters[#world.shatters].inVent, true)
				t.eq(#world.stuns, 1, "down the duct and round the bend, without a straight line")
				local heard = NoiseAndDirectorService.RecentNoises(0)
				local noise = heard[#heard]
				t.truthy(noise and noise.medium == "Vent" and noise.ventNodeId == "B", "it rings through the ducts")

				-- Three hops away: out of reach.
				world.clock += GameConfig.FlaskThrowCooldown + 0.1
				moveCreature(creature, Vector3.new(58, 0.25, 20))
				creature:SetAttribute(C.VentSegmentId, "D-E")
				t.truthy(ChemicalProjectileService.Give(player, 4))
				t.eq(verdict(ChemicalProjectileService.RequestThrow(player, along)), "ok")
				ChemicalProjectileService.StepFlights(world.clock + 1)
				t.eq((last(world) :: Payload).inVent, true)
				t.eq(#world.stuns, 1, "too many hops for the gas")
				PlayerStateService.SetMode(player, "OnFoot")

				-- Thrown at the sky with nothing to hit: it expires, and nothing happens.
				world.cast = noCast
				world.clock += GameConfig.FlaskThrowCooldown + 0.1
				lookAt(player, 0, math.rad(60))
				t.truthy(ChemicalProjectileService.Give(player, 4))
				local shatters = #world.shatters
				t.eq(verdict(ChemicalProjectileService.RequestThrow(player, serverLook(player))), "ok")
				ChemicalProjectileService.StepFlights(world.clock + GameConfig.FlaskMaxFlightSeconds - 0.1)
				t.eq((last(world) :: Payload).phase, "Spawn", "still flying just before the limit")
				ChemicalProjectileService.StepFlights(world.clock + GameConfig.FlaskMaxFlightSeconds + 0.1)
				local expired = last(world) :: Payload
				t.eq(expired.phase, "Resolve")
				t.eq(expired.hitKind, "Expired")
				t.eq(#world.shatters, shatters, "no shatter, no cloud")
				t.eq(#ChemicalProjectileService.GetFlights(), 0)
			end)
		end)
	end,

	["live: the real cast stops a flask on the pool's surface"] = function(t: Expect)
		quiet(function()
			local pool = Instance.new("Part")
			pool.Name = "SpecPool"
			pool.Size = Vector3.new(60, 6, 60)
			pool.CFrame = CFrame.new(0, -3, -30) -- surface at y = 0
			pool:AddTag(Tags.PoolWater)
			pool.Parent = Workspace
			local player = fakePlayer(CFrame.new(0, 3, 0))
			inRun({ player }, function(world: World)
				world.cast = nil
				ChemicalProjectileService.SetDependencies({
					now = function(): number
						return world.clock
					end,
					lineClear = function(_creature: Model?): ChemicalProjectileService.LineClear
						return clearLine
					end,
					creature = function(): Model?
						return nil
					end,
					graph = function(_levelId: string): Graph?
						return nil
					end,
					publish = function(payload: Payload)
						table.insert(world.events, payload)
					end,
				})
				lookAt(player, 0, 0)
				t.truthy(ChemicalProjectileService.Give(player, 1))
				t.eq(verdict(ChemicalProjectileService.RequestThrow(player, serverLook(player))), "ok")
				ChemicalProjectileService.StepFlights(world.clock + 2)
				local resolve = last(world) :: Payload
				t.eq(resolve.hitKind, "Water", "the surface plane, by maths")
				t.near((resolve.hitPosition :: Vector3).Y, 0, 1e-6)
				t.truthy(near(resolve.hitNormal :: Vector3, Vector3.yAxis, EPS), "facing up at a flask from above")
			end)
			pool:Destroy()
		end)
	end,

	["live: Downed keeps the flask but cannot throw it; death empties the hand"] = function(t: Expect)
		quiet(function()
			local player = fakePlayer(CFrame.new(0, 3, 0))
			inRun({ player }, function(_world: World)
				lookAt(player, 0, 0)
				t.truthy(ChemicalProjectileService.Give(player, 3))
				LifeStateService.Down(player, "Spec")
				t.eq(LifeStateService.GetState(player), "Downed")
				t.eq(ChemicalProjectileService.GetHeld(player), 3, "Downed keeps it")
				t.eq(player:GetAttribute(P.HeldItem), "ChemicalFlask")
				t.eq(verdict(ChemicalProjectileService.RequestThrow(player, serverLook(player))), "LifeState")
				LifeStateService.Execute(player, "Spec")
				t.eq(ChemicalProjectileService.GetHeld(player), nil, "dead hands hold nothing")
				t.eq(player:GetAttribute(P.HeldItem), "None")
				t.falsy(ChemicalProjectileService.Give(player, 1), "nor can they be given one")
			end)
		end)
	end,

	["client: hand frames, wind-up, swing and reconciliation"] = function(t: Expect)
		local eye = CFrame.new(3, 5, 1) * CFrame.fromOrientation(math.rad(-10), math.rad(35), 0)
		local carry = ChemicalThrowController.handTarget(eye, 0, 0)
		local drawn = ChemicalThrowController.handTarget(eye, 1, 0)
		local swung = ChemicalThrowController.handTarget(eye, 1, 1)
		local heading = CFrame.new(eye.Position) * CFrame.fromOrientation(0, math.rad(35), 0)
		local c = heading:PointToObjectSpace(carry.Position)
		local d = heading:PointToObjectSpace(drawn.Position)
		local s = heading:PointToObjectSpace(swung.Position)
		t.truthy(c.X > 0.3 and c.Y < -0.4 and c.Z < -0.8, "carried low on the right, ahead")
		t.truthy(d.X > 0.5 and math.abs(d.Y) < 0.4 and d.Z > -0.4, "drawn back beside the head")
		t.truthy(s.Z < c.Z and s.Y < 0, "swung through ahead and down")
		t.truthy(drawn.LookVector.Y > carry.LookVector.Y, "the wrist cocks back")
		local half = ChemicalThrowController.handTarget(eye, 0.5, 0)
		t.truthy((half.Position - carry.Position).Magnitude < (drawn.Position - carry.Position).Magnitude)

		t.eq(ChemicalThrowController.windupAmount(0), 0)
		t.eq(ChemicalThrowController.windupAmount(10), 1)
		t.truthy(ChemicalThrowController.windupAmount(ChemicalThrowController.MinWindup) > 0.3, "a tap draws back")
		t.eq(ChemicalThrowController.followAmount(0), 0)
		t.eq(ChemicalThrowController.followAmount(5), 1)
		t.truthy(ChemicalThrowController.followAmount(0.1) > 0.1 / 0.28, "the swing eases out")

		t.eq(ChemicalThrowController.reconcileWeight(0), 1, "the whole gap at adoption")
		t.eq(ChemicalThrowController.reconcileWeight(ChemicalThrowController.ReconcileSeconds), 0, "none after")
		local previous = 1
		for step = 1, 10 do
			local weight = ChemicalThrowController.reconcileWeight(step * ChemicalThrowController.ReconcileSeconds / 10)
			t.truthy(weight <= previous, "it only shrinks")
			previous = weight
		end
		local timeout = ChemicalThrowController.PredictionTimeout
		t.truthy(ChemicalThrowController.refusedAfter(timeout + 0.01, true), "still holding: refused")
		t.falsy(ChemicalThrowController.refusedAfter(timeout + 0.01, false), "the hand emptied: accepted")
		t.falsy(ChemicalThrowController.refusedAfter(timeout - 0.01, true), "not yet")
	end,

	["client: who poses the hands and winds up, hints, snaps, clouds, shards, fades"] = function(t: Expect)
		for _, state: Enums.MoveState in BLOCKED do
			t.falsy(ChemicalThrowController.shouldPose(state, "Alive"), state .. ": another system has the hands")
		end
		t.truthy(ChemicalThrowController.shouldPose("Standing", "Alive"))
		t.truthy(ChemicalThrowController.shouldPose("DownedCrawling", "Downed"), "a downed player still holds it")
		t.falsy(ChemicalThrowController.shouldPose("Standing", "Dead"))
		t.falsy(ChemicalThrowController.shouldPose("Standing", "Spectating"))

		local function windUp(overrides: { [string]: any }?): boolean
			local check: ChemicalThrowController.WindUpCheck = {
				holding = true,
				lifeState = "Alive",
				moveState = "Standing",
				locked = false,
				winding = false,
				awaiting = false,
				sinceLastThrow = nil,
			}
			for key, value in (overrides or {}) :: { [string]: any } do
				(check :: any)[key] = value
			end
			return ChemicalThrowController.canWindUp(check)
		end
		t.truthy(windUp())
		t.truthy(windUp({ moveState = "VentCrawling" }), "a toss in the duct")
		t.falsy(windUp({ holding = false }))
		t.falsy(windUp({ lifeState = "Downed" }))
		t.falsy(windUp({ locked = true }))
		t.falsy(windUp({ winding = true }))
		t.falsy(windUp({ awaiting = true }), "one throw at a time")
		t.falsy(windUp({ moveState = "Hiding" }))
		t.falsy(windUp({ sinceLastThrow = GameConfig.FlaskThrowCooldown - 0.05 }), "the cooldown")
		t.truthy(windUp({ sinceLastThrow = GameConfig.FlaskThrowCooldown }))

		for _, device in { "KeyboardMouse", "Gamepad", "Touch" } do
			local key = ChemicalThrowController.hintKey(device)
			t.truthy(Strings.has(key), device .. " has a hint")
			t.truthy(string.find(key, device, 1, true) ~= nil, "for that device")
		end
		t.eq(ChemicalThrowController.hintKey("Unknown"), ChemicalThrowController.hintKey("KeyboardMouse"))
		t.truthy(Strings.has("Hud.FlaskHandsFull"))

		local tolerance = ChemicalThrowController.SnapTolerance
		t.truthy(ChemicalThrowController.snapNeeded(nil, Vector3.zero), "nothing played here")
		t.falsy(ChemicalThrowController.snapNeeded(Vector3.new(tolerance - 0.1, 0, 0), Vector3.zero), "close enough")
		t.truthy(ChemicalThrowController.snapNeeded(Vector3.new(tolerance + 0.1, 0, 0), Vector3.zero), "replayed")

		local seconds = GameConfig.FlaskCloudSeconds
		t.truthy(ChemicalThrowController.cloudRate(0, seconds, 1, false) > 0, "it pours out")
		t.truthy(
			ChemicalThrowController.cloudRate(0.5, seconds, 1, false)
				> ChemicalThrowController.cloudRate(3, seconds, 1, false),
			"and thins"
		)
		t.eq(ChemicalThrowController.cloudRate(seconds - 0.5, seconds, 1, false), 0, "stops before the end")
		t.eq(ChemicalThrowController.cloudRate(-1, seconds, 1, false), 0)
		t.truthy(
			ChemicalThrowController.cloudRate(1, seconds, 1, true)
				< ChemicalThrowController.cloudRate(1, seconds, 1, false),
			"smaller in a duct"
		)
		t.near(
			ChemicalThrowController.cloudRate(1, seconds, 0.4, false),
			0.4 * ChemicalThrowController.cloudRate(1, seconds, 1, false),
			1e-9,
			"scaled by the render budget"
		)
		t.eq(ChemicalThrowController.cloudGlow(0, seconds), 0)
		t.eq(ChemicalThrowController.cloudGlow(1, seconds), 1, "glowing")
		t.truthy(ChemicalThrowController.cloudGlow(seconds - 0.4, seconds) < 0.5, "fading out")
		t.eq(ChemicalThrowController.cloudGlow(seconds, seconds), 0)

		t.eq(ChemicalThrowController.shardCount(1), 10)
		t.eq(ChemicalThrowController.shardCount(0.4), 4)
		t.eq(ChemicalThrowController.shardCount(0), 3, "always a few")
		t.eq(ChemicalThrowController.fadeAlpha(0, 1, 0.4), 1)
		t.near(ChemicalThrowController.fadeAlpha(0.8, 1, 0.4), 0.5, 1e-9)
		t.eq(ChemicalThrowController.fadeAlpha(1, 1, 0.4), 0)
	end,

	["client: a held flask's Grip sits in the fist; a flying one is centred on its flight point"] = function(t: Expect)
		quiet(function()
			local folder = Instance.new("Folder")
			local model = ChemicalFlaskBuilder.buildVisual(folder, CFrame.identity, 2)
			local grip = PropKit.findAttachment(model, "Grip")
			assert(grip, "the visual has a Grip")
			local gripRest = PropKit.attachmentWorld(grip)
			t.truthy(near(gripRest.Position, ChemicalFlaskBuilder.GripOffset.Position, EPS), "Grip at GripOffset")
			local hand = CFrame.new(5, 4, -2) * CFrame.Angles(0.3, 1.1, -0.2)
			local pivot = ChemicalThrowController.heldPivot(hand)
			local gripWorld = pivot * gripRest
			local fist = hand * ChemicalThrowController.HandGrip
			t.truthy(near(gripWorld.Position, fist.Position, EPS), "the neck in the fist")
			t.near(gripWorld.UpVector:Dot(fist.UpVector), 1, EPS, "upright along the hand")
			for _, part in model:GetDescendants() do
				if part:IsA("BasePart") then
					t.falsy(part.CanCollide or part.CanQuery or part.CanTouch, part.Name .. " is cosmetic")
				end
			end
			local point = Vector3.new(1, 2, 3)
			for _, age in { 0, 0.3, 1.7 } do
				local flying = ChemicalThrowController.flightPivot(point, Vector3.new(1, 0.2, -0.5), age)
				t.truthy(near((flying * ChemicalThrowController.FlaskCentre).Position, point, EPS), "centred")
			end
			local still = ChemicalThrowController.flightPivot(point, Vector3.zero, 0)
			t.truthy(near((still * ChemicalThrowController.FlaskCentre).Position, point, EPS), "any axis")
			folder:Destroy()
		end)
	end,
}
