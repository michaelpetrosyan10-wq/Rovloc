--!strict
-- Doors. DoorMotion's server-time maths (eases, holding `from` until startAt, snaps, OneShot args), DoorService's rules
-- (the state table, default motion times, eases, OneShot kinds, body boxes and the separating-axis test, leaf
-- bounds), and the live service on a fake clock over the real Level 0 / 1 / 2 / 5 fixtures: the index by ScriptedId
-- and DoorId with the run's initial states, an airlock locking shut (lead, eased swing, landing, cues, OneShot,
-- StateChanged, Locked refusing RequestOpen), the gate slamming (GateSlam, the DoorSlam noise), snaps, a smash torn
-- from an open door, and a closing fire door stopping short of a player and finishing once the doorway is clear.
-- DoorController's maths and its Apply / Render path posing a real door. (Replication, rendering and the engine's
-- part queries need Roblox: Workspace:GetPartBoundsInBox reports nothing here, so the body-box test carries it.)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local DoorMotion = require(ReplicatedStorage.Shared.Sequence.DoorMotion)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local Types = require(ReplicatedStorage.Shared.Types)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local DoorBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.DoorBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)

local DoorService = require(ServerScriptService.Services.Mechanics.DoorService)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

local DoorController = require(StarterPlayer.StarterPlayerScripts.Controllers.Gameplay.DoorController)

type Expect = SpecRunner.Expect
type Motion = DoorMotion.Motion
type Message = DoorMotion.Message

type Sent = { name: string, player: Player?, payload: any }

type FakeClock = {
	clock: DoorService.Clock,
	advance: (seconds: number) -> (),
	now: () -> number,
}

local W = Attributes.World
local LEVELS: { Enums.LayoutId } = { "Level0_Basement", "Level1_Hallways", "Level2_ScienceHall", "Level5_Roof" }
local L0: Enums.LevelId = "Level0_Basement"
local L1: Enums.LevelId = "Level1_Hallways"
local L2: Enums.LevelId = "Level2_ScienceHall"
local L5: Enums.LevelId = "Level5_Roof"
local SEED = 6161
local LEAD = GameConfig.OneShotLead
local EPS = 1e-3
local HIP_HEIGHT = 2
local ROOT_SIZE = Vector3.new(2, 2, 1)

local STATES: { Enums.DoorState } = { "Open", "Closed", "Locked", "Smashed" }
local SLAM: DoorController.ImpactKind = "Slam"

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

local function sentOf(sent: { Sent }, name: string, from: number?): { any }
	local out: { any } = {}
	for index = from or 1, #sent do
		local entry = sent[index]
		if entry.name == name then
			table.insert(out, entry.payload)
		end
	end
	return out
end

local function cuesOf(sent: { Sent }, preset: string, from: number?): { Types.AudioCuePayload }
	local out: { Types.AudioCuePayload } = {}
	for _, payload in sentOf(sent, "AudioCue", from) do
		if payload.preset == preset then
			table.insert(out, payload)
		end
	end
	return out
end

local nextUserId = 9400

local function fakePlayer(at: CFrame): (Player, BasePart, Humanoid)
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "DoorSpec" .. nextUserId
	local writable = player :: any
	writable.UserId = nextUserId
	local model = Instance.new("Model")
	model.Name = player.Name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = ROOT_SIZE
	root.CFrame = at
	root.Parent = model
	model.PrimaryPart = root
	local humanoid = Instance.new("Humanoid")
	humanoid.HipHeight = HIP_HEIGHT
	humanoid.MaxHealth = GameConfig.MaxHealth
	humanoid.Health = GameConfig.MaxHealth
	humanoid.Parent = model
	player.Character = model
	return player, root, humanoid
end

-- Runs `body` with fresh fixtures indexed by a live DoorService on a fake clock, always tearing it down.
local function inRun(players: { Player }, body: (clock: FakeClock) -> ())
	Net.Server.setup()
	DoorService.Init()
	freshFixtures()
	local clock = fakeClock(1000)
	DoorService.SetClock(clock.clock)
	local ctx: Types.RunContext = {
		runId = "doors-spec",
		seed = SEED,
		difficulty = "Standard",
		participants = players,
		startedAt = 1000,
	}
	DoorService.BeginRun(ctx)
	local failure: string? = nil
	xpcall(body, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end, clock)
	DoorService.EndRun()
	DoorService.SetClock(nil)
	for _, player in players do
		DoorService.OnPlayerRemoving(player)
	end
	clearFixtures()
	if failure ~= nil then
		error(failure, 0)
	end
end

-- Advances the clock in Heartbeat-sized steps (DoorService steps every frame), `seconds` in total.
local function run(clock: FakeClock, seconds: number)
	local steps = math.max(1, math.ceil(seconds / (1 / 60)))
	for _ = 1, steps do
		clock.advance(seconds / steps)
		DoorService.StepMotions()
	end
end

local function door(levelId: Enums.LevelId, id: string): Model
	local found = DoorService.Get(levelId, id)
	assert(found, levelId .. " has door " .. id)
	return found
end

local function transformOf(model: Model, leaf: string): CFrame
	local transform = PropKit.leafTransform(model, leaf)
	assert(transform, model.Name .. " leaf " .. leaf)
	return transform
end

local function angleOf(cframe: CFrame): number
	local _, angle = cframe:ToAxisAngle()
	return math.abs(MathUtil.wrapAngle(angle))
end

local function near(a: CFrame, b: CFrame, epsilon: number): boolean
	return (a.Position - b.Position).Magnitude <= epsilon and angleOf(a:ToObjectSpace(b)) <= epsilon
end

local function isShut(model: Model): boolean
	for _, name in DoorBuilder.leafNames(model) do
		if not near(transformOf(model, name), CFrame.new(), EPS) then
			return false
		end
	end
	return true
end

local function isAt(model: Model, openness: number): boolean
	for _, name in DoorBuilder.leafNames(model) do
		local expected = DoorBuilder.openTransform(model, name, openness)
		if not (expected and near(transformOf(model, name), expected, EPS)) then
			return false
		end
	end
	return true
end

-- A leaf's colliding box at `openness` (world).
local function leafBox(model: Model, leafName: string, openness: number): (CFrame, Vector3)
	local leaf = model:FindFirstChild(leafName)
	assert(leaf and leaf:IsA("Model"), leafName)
	local parts: { BasePart } = {}
	for _, descendant in leaf:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.CanCollide then
			table.insert(parts, descendant)
		end
	end
	local center, size = DoorService.localBounds(leaf.WorldPivot, parts)
	local rest = PropKit.leafRest(model, leafName)
	local transform = DoorBuilder.openTransform(model, leafName, openness)
	assert(center and size and rest and transform, "leaf box")
	return rest * transform * center, size
end

local function message(overrides: { [string]: any }, motion: { [string]: any }?): Message
	local base: Message = {
		doorId = "L1_Door_Classroom108",
		levelId = L1,
		motionId = 1,
		state = "Closed",
		held = false,
		motion = {
			mode = "Swing",
			from = 1,
			to = 0,
			startAt = 1000,
			seconds = 1,
			ease = "InOut",
			smashFrom = 0,
		},
	}
	for key, value in overrides do
		(base :: any)[key] = value
	end
	for key, value in (motion or {}) :: { [string]: any } do
		(base.motion :: any)[key] = value
	end
	return base
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["motion: eases run 0 to 1; a motion holds `from` until startAt, eases, lands on `to`; zero seconds snaps"] = function(
		t: Expect
	)
		for _, ease: DoorMotion.Ease in DoorMotion.Eases do
			t.near(DoorMotion.ease(ease, 0), 0, 1e-9, ease .. " starts at 0")
			t.near(DoorMotion.ease(ease, 1), 1, 1e-9, ease .. " ends at 1")
			t.near(DoorMotion.ease(ease, -2), 0, 1e-9, ease .. " clamps below")
			t.near(DoorMotion.ease(ease, 3), 1, 1e-9, ease .. " clamps above")
			local last = 0
			for step = 1, 20 do
				local value = DoorMotion.ease(ease, step / 20)
				t.truthy(value >= last - 1e-12, ease .. " never runs backwards")
				last = value
			end
		end
		t.near(DoorMotion.ease("InOut", 0.5), 0.5, 1e-9, "smoothstep is symmetric")
		t.near(DoorMotion.ease("In", 0.5), 0.25, 1e-9, "a drop accelerates")

		local motion: Motion =
			{ mode = "Swing", from = 1, to = 0, startAt = 50, seconds = 2, ease = "Linear", smashFrom = 0 }
		t.eq(DoorMotion.endsAt(motion), 52)
		local value, done = DoorMotion.valueAt(motion, 49)
		t.eq(value, 1, "holds from before startAt")
		t.falsy(done)
		t.eq((DoorMotion.valueAt(motion, 50)), 1, "starts at from")
		t.near((DoorMotion.valueAt(motion, 51)), 0.5, 1e-9, "half way at half time")
		value, done = DoorMotion.valueAt(motion, 52)
		t.eq(value, 0, "lands on to")
		t.truthy(done, "and is done")
		t.eq((DoorMotion.valueAt(motion, 900)), 0, "stays there")
		local snap: Motion =
			{ mode = "Swing", from = 1, to = 0, startAt = 50, seconds = 0, ease = "InOut", smashFrom = 0 }
		value, done = DoorMotion.valueAt(snap, 50)
		t.eq(value, 0, "a snap is at `to` from its startAt")
		t.truthy(done)
		t.eq((DoorMotion.valueAt(snap, 49.9)), 1, "but not before")
	end,

	["motion: OneShot args round-trip; malformed args are refused"] = function(t: Expect)
		local original = message({ held = true, state = "Locked", motionId = 7 }, { smashFrom = 0.25, ease = "In" })
		local args = DoorMotion.toArgs(original)
		for _, value in args do
			local kind = typeof(value)
			t.truthy(
				kind == "string" or kind == "number" or kind == "boolean",
				"every arg is a OneShotArg (" .. kind .. ")"
			)
		end
		local decoded = DoorMotion.fromArgs(args, 1000)
		assert(decoded, "decodes")
		t.eq(decoded.doorId, original.doorId)
		t.eq(decoded.levelId, original.levelId)
		t.eq(decoded.motionId, 7)
		t.eq(decoded.state, "Locked")
		t.eq(decoded.held, true)
		t.eq(decoded.motion.mode, "Swing")
		t.eq(decoded.motion.from, 1)
		t.eq(decoded.motion.to, 0)
		t.eq(decoded.motion.seconds, 1)
		t.eq(decoded.motion.ease, "In")
		t.eq(decoded.motion.smashFrom, 0.25)
		t.eq(decoded.motion.startAt, 1000, "startAt is the OneShot's")

		local function refused(key: string, value: any): boolean
			local broken = table.clone(args) :: { [string]: any }
			broken[key] = value
			return DoorMotion.fromArgs(broken, 1000) == nil
		end
		t.truthy(refused("doorId", 4), "door id")
		t.truthy(refused("levelId", nil), "level id")
		t.truthy(refused("motionId", "x"), "motion id")
		t.truthy(refused("mode", "Spin"), "mode")
		t.truthy(refused("ease", "Bounce"), "ease")
		t.truthy(refused("state", "Ajar"), "state")
		t.truthy(refused("from", 1.5), "from above 1")
		t.truthy(refused("to", -0.1), "to below 0")
		t.truthy(refused("to", math.huge), "non-finite to")
		t.truthy(refused("seconds", -1), "negative seconds")
		t.truthy(refused("seconds", DoorMotion.MaxSeconds + 1), "absurd seconds")
		t.truthy(refused("smashFrom", 2), "smashFrom")
		t.eq(DoorMotion.fromArgs(args, math.huge), nil, "a non-finite startAt")
		local plain = table.clone(args) :: { [string]: any }
		plain.smashFrom = nil
		plain.held = nil
		local relaxed = DoorMotion.fromArgs(plain, 1000)
		t.truthy(relaxed ~= nil and relaxed.motion.smashFrom == 0 and relaxed.held == false, "optional args default")
	end,

	["rules: the state table (Open swings open, Closed / Locked share the shut pose, Smashed is final)"] = function(
		t: Expect
	)
		local expected: { [string]: { [string]: string } } = {
			Open = { Open = "Refuse", Closed = "Swing 0", Locked = "Swing 0", Smashed = "Smash" },
			Closed = { Open = "Swing 1", Closed = "Refuse", Locked = "StateOnly", Smashed = "Smash" },
			Locked = { Open = "Swing 1", Closed = "StateOnly", Locked = "Refuse", Smashed = "Smash" },
			Smashed = { Open = "Refuse", Closed = "Refuse", Locked = "Refuse", Smashed = "Refuse" },
		}
		for _, current: Enums.DoorState in STATES do
			for _, nextState: Enums.DoorState in STATES do
				local plan, target = DoorService.plan(current, nextState)
				local text = if target then plan .. " " .. tostring(target) else plan
				t.eq(text, expected[current][nextState], current .. " -> " .. nextState)
			end
		end
		t.eq(DoorService.InitialStates.Airlock, "Open", "airlocks start open")
		t.eq(DoorService.InitialStates.Gate, "Open", "the gate starts rolled up")
		t.eq(DoorService.InitialStates.Ajar, "Open", "the classroom door starts ajar")
		t.eq(DoorService.InitialStates.RoofDoor, "Closed", "the roof door starts shut")
	end,

	["rules: default motion times scale with travel; eases and OneShot kinds per kind"] = function(t: Expect)
		t.near(DoorService.defaultSeconds("Airlock", "Swing", 1, 0), 1.6, 1e-9, "a fire door closes in 1.6 s")
		t.near(DoorService.defaultSeconds("Airlock", "Swing", 0, 1), 1.6, 1e-9, "and opens in 1.6 s")
		t.near(DoorService.defaultSeconds("Airlock", "Swing", 0.5, 0), 0.8, 1e-9, "half the travel, half the time")
		t.near(DoorService.defaultSeconds("Gate", "Swing", 1, 0), 0.35, 1e-9, "the grille drops fast")
		t.near(DoorService.defaultSeconds("Gate", "Swing", 0, 1), 2.8, 1e-9, "and winds up slowly")
		t.near(DoorService.defaultSeconds("RoofDoor", "Swing", 1, 0), 0.9, 1e-9)
		t.truthy(DoorService.defaultSeconds("Ajar", "Swing", 0.01, 0) >= 0.1, "never a zero-length default")
		t.eq(DoorService.defaultSeconds("Gate", "Smash", 0, 1), DoorService.SmashSeconds, "smashes take SmashSeconds")
		t.eq(DoorService.easeFor("Gate", "Swing", true), "In", "the grille falls under its weight")
		t.eq(DoorService.easeFor("Gate", "Swing", false), "InOut")
		t.eq(DoorService.easeFor("Airlock", "Swing", true), "InOut", "a door closer")
		t.eq(DoorService.easeFor("Airlock", "Smash", false), "Linear", "the smash pose shapes itself")
		t.eq(DoorService.oneShotKind("Gate", "Swing", true), "GateSlam", "the gate's close is a GateSlam")
		t.eq(DoorService.oneShotKind("Gate", "Swing", false), "Door")
		t.eq(DoorService.oneShotKind("RoofDoor", "Smash", false), "DoorSmash")
		t.eq(DoorService.oneShotKind("Airlock", "Swing", true), "Door")
		for _, kind in DoorController.OneShotKinds do
			t.truthy(Enums.has(Enums.OneShotKind, kind), kind .. " is a OneShotKind")
		end
		for _, preset in { "FireDoorSwing", "FireDoorLatch", "DoorCreak", "GateSlam", "DoorSmash", "MetalCreak" } do
			t.truthy(SynthPresets.has(preset), preset .. " is a preset")
		end
	end,

	["rules: body boxes stand on the floor; boxes overlap only when they touch"] = function(t: Expect)
		local root = CFrame.new(10, 3, -4) * CFrame.Angles(0, math.rad(30), 0)
		local cframe, size = DoorService.characterBox(root, ROOT_SIZE, HIP_HEIGHT)
		t.near(cframe.Position.Y - size.Y / 2, 0, 1e-6, "from the feet")
		t.truthy(size.Y > 5, "to above the head")
		t.near(cframe.Position.X, 10, 1e-6, "over the root")
		t.near(MathUtil.yawPitchFromVector(cframe.LookVector), math.rad(30), 1e-6, "turned with the root")
		local tilted = DoorService.characterBox(root * CFrame.Angles(math.rad(40), 0, 0), ROOT_SIZE, HIP_HEIGHT)
		t.near(tilted.UpVector.Y, 1, 1e-6, "always upright")

		local unit = Vector3.new(2, 2, 2)
		t.truthy(DoorService.boxesOverlap(CFrame.new(), unit, CFrame.new(1.9, 0, 0), unit), "touching faces")
		t.falsy(DoorService.boxesOverlap(CFrame.new(), unit, CFrame.new(2.1, 0, 0), unit), "apart along X")
		t.falsy(DoorService.boxesOverlap(CFrame.new(), unit, CFrame.new(0, 0, -2.5), unit), "apart along Z")
		t.truthy(DoorService.boxesOverlap(CFrame.new(), Vector3.new(10, 10, 10), CFrame.new(1, 1, 1), unit), "inside")
		-- a box turned 45 degrees reaches 1.414 out with its corner: 2.3 apart it pokes into a face that a square box
		-- at the same distance would clear, 2.5 apart it clears too
		local turned = CFrame.new(2.3, 0, 0) * CFrame.Angles(0, math.rad(45), 0)
		t.truthy(DoorService.boxesOverlap(CFrame.new(), unit, turned, unit), "a turned box's corner in a face")
		t.falsy(DoorService.boxesOverlap(CFrame.new(), unit, CFrame.new(2.3, 0, 0), unit), "square, it clears")
		local farther = CFrame.new(2.5, 0, 0) * CFrame.Angles(0, math.rad(45), 0)
		t.falsy(DoorService.boxesOverlap(CFrame.new(), unit, farther, unit), "a turned box beyond its corner")
		-- two thin bars crossing at right angles
		local slab = Vector3.new(4, 0.2, 0.2)
		local crossed = CFrame.new(0, 0.25, 0) * CFrame.Angles(0, math.rad(90), 0)
		t.falsy(DoorService.boxesOverlap(CFrame.new(), slab, crossed, slab), "crossed bars a hair apart")
		local touching = CFrame.new(0, 0.15, 0) * CFrame.Angles(0, math.rad(90), 0)
		t.truthy(DoorService.boxesOverlap(CFrame.new(), slab, touching, slab), "crossed bars touching")
	end,

	["rules: leaf bounds and sweep samples"] = function(t: Expect)
		local a = Instance.new("Part")
		a.Size = Vector3.new(2, 4, 0.5)
		a.CFrame = CFrame.new(1, 2, 0)
		local b = Instance.new("Part")
		b.Size = Vector3.new(1, 1, 1)
		b.CFrame = CFrame.new(3, 0.5, 0)
		local pivot = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(90), 0)
		local center, size = DoorService.localBounds(pivot, { a, b })
		assert(center and size, "bounds")
		local placed = pivot * center
		t.near(placed.Position.X, 1.75, 1e-6, "centred between the parts")
		t.near(placed.Position.Y, 2, 1e-6)
		t.near(size.Y, 4, 1e-6, "full height")
		t.near(size.Z, 3.5, 1e-6, "the pivot's turned axes")
		t.eq((DoorService.localBounds(CFrame.new(), {})), nil, "no parts, no box")
		local values = DoorService.sweepValues(1, 0.5, 4)
		t.eq(#values, 5, "start plus samples")
		t.eq(values[1], 1)
		t.eq(values[5], 0.5)
		t.near(values[3], 0.75, 1e-9)
	end,

	["live: the run's fixtures are indexed by ScriptedId and DoorId, in their initial states"] = function(t: Expect)
		inRun({}, function(_clock: FakeClock)
			local gate = door(L1, "HallwayGate")
			t.eq(gate, door(L1, "L1_Door_HallwayGate"), "the same door by DoorId")
			t.eq(gate:GetAttribute(W.DoorKind), "Gate")
			local classroom = door(L1, "ClassroomDoor")
			t.eq(classroom:GetAttribute(W.DoorKind), "Ajar")
			local roof = door(L5, "RoofStairDoor")
			t.eq(DoorService.Get(L1, "RoofStairDoor"), nil, "per level")
			t.eq(DoorService.Get(L1, "NoSuchDoor"), nil, "unknown ids")

			t.eq(DoorService.GetState(gate), "Open", "the gate is rolled up")
			t.truthy(isAt(gate, 1), "fully up")
			t.eq(DoorService.GetState(classroom), "Open", "the classroom door is ajar")
			t.truthy(DoorMotion.opennessOf(classroom) > 0.2, "left standing ajar")
			t.truthy(DoorMotion.opennessOf(classroom) < 0.6, "not swung wide")
			t.eq(DoorService.GetState(roof), "Closed", "the roof door starts shut")
			t.eq(roof:GetAttribute(W.DoorState), "Closed", "and says so")
			t.truthy(isShut(roof), "its leaf is in the frame")
			t.falsy(DoorService.IsMoving(roof), "snapped, not moving")

			local forL1 = DoorService.ForLevel(L1)
			t.eq(#forL1, 8, "six fire doors (three entry, three exit candidates), the gate and the classroom door")
			for index = 2, #forL1 do
				local previous = forL1[index - 1]:GetAttribute(W.DoorId) :: string
				local current = forL1[index]:GetAttribute(W.DoorId) :: string
				t.truthy(previous < current, "sorted by DoorId")
			end
			local airlocks = DoorService.Airlocks(L1)
			t.eq(
				#airlocks,
				12,
				"Level 1's stairwells (three candidates each): the basement's exits, its entries, exits and Level 2's entries"
			)
			local into, outOf = 0, 0
			for _, model in airlocks do
				t.eq(model:GetAttribute(W.DoorKind), "Airlock")
				-- the run's route uses one stairwell per floor pair; the others are jammed shut from the start
				local jammed = model:GetAttribute(W.Jammed) == true
				t.eq(DoorService.GetState(model), if jammed then "Locked" else "Open", model.Name .. " initial state")
				t.truthy(isAt(model, if jammed then 0 else 1), model.Name .. " stands fully open, or shut when jammed")
				if model:GetAttribute(W.ToLevel) == L1 then
					into += 1
				end
				if model:GetAttribute(W.FromLevel) == L1 then
					outOf += 1
				end
			end
			t.eq(into, 6, "both sides of the three stairwells up from the basement")
			t.eq(outOf, 6, "both sides of the three stairwells up to Level 2")
			t.eq(#DoorService.Airlocks(L0), 6, "the basement: its exits and Level 1's entries")
			t.eq(
				#DoorService.Airlocks(L2),
				9,
				"Level 2: Level 1's exits, its entries and its exits (Level 3 is not built)"
			)
			t.eq(#DoorService.Airlocks(L5), 0, "the roof has no fire doors")
		end)
	end,

	["live: a fire door locks shut on the clock; Locked refuses RequestOpen, scripts still open it"] = function(
		t: Expect
	)
		inRun({}, function(clock: FakeClock)
			local model = door(L1, "L1_Door_AirlockWest")
			local changes: { string } = {}
			local connection = DoorService.StateChanged:Connect(
				function(changed: Model, previous: Enums.DoorState, nextState: Enums.DoorState)
					if changed == model then
						table.insert(changes, previous .. ">" .. nextState)
					end
				end
			)
			capture(function(sent: { Sent })
				t.truthy(DoorService.SetState(model, "Locked", 1.6), "locks")
				t.eq(DoorService.GetState(model), "Locked")
				t.eq(model:GetAttribute(W.DoorState), "Locked", "the attribute follows")
				t.eq(table.concat(changes, ","), "Open>Locked", "StateChanged (door, previous, next)")
				local shots = sentOf(sent, "OneShot")
				t.eq(#shots, 1, "one OneShot")
				local shot = shots[1] :: Types.OneShotEvent
				t.eq(shot.kind, "Door", "a fire door's motion is a Door OneShot")
				t.eq(shot.subject, model, "about the door")
				t.near(shot.startAt, clock.now() + LEAD, 1e-9, "after the OneShot lead")
				local decoded = DoorMotion.fromArgs(shot.args, shot.startAt)
				assert(decoded, "well-formed args")
				t.eq(decoded.doorId, "L1_Door_AirlockWest")
				t.eq(decoded.levelId, L1)
				t.eq(decoded.state, "Locked")
				t.eq(decoded.motion.from, 1)
				t.eq(decoded.motion.to, 0)
				t.eq(decoded.motion.seconds, 1.6)
				t.eq(decoded.motionId, 1)
				t.eq(#cuesOf(sent, "FireDoorSwing"), 1, "it swings with the closer")
				local latch = cuesOf(sent, "FireDoorLatch")
				t.eq(#latch, 1, "and is scheduled to latch")
				local swingCue = cuesOf(sent, "FireDoorSwing")[1]
				t.near(latch[1].startAt - swingCue.startAt, 1.6, 1e-6, "at the end of the swing")
				t.truthy(DoorService.IsMoving(model), "moving")

				run(clock, LEAD * 0.5)
				t.truthy(isAt(model, 1), "nothing moves before the lead runs out")
				run(clock, LEAD * 0.5 + 0.8)
				local half = DoorMotion.opennessOf(model)
				t.near(half, 0.5, 0.05, "half shut half way (smoothstep)")
				run(clock, 0.8 + 0.05)
				t.truthy(isShut(model), "shut at the end")
				t.falsy(DoorService.IsMoving(model), "landed")
				t.eq(#sentOf(sent, "OneShot"), 1, "no other OneShot on the way")

				t.falsy(DoorService.SetState(model, "Locked"), "re-locking is a no-op")
				t.falsy(DoorService.RequestOpen(model), "a locked door refuses gameplay")
				t.truthy(DoorService.SetState(model, "Closed"), "unlocking")
				t.falsy(DoorService.IsMoving(model), "Closed and Locked share the shut pose")
				t.eq(#sentOf(sent, "OneShot"), 1, "so nothing is announced")
				t.truthy(DoorService.RequestOpen(model, 0), "a closed door opens on request")
				t.truthy(isAt(model, 1), "0 seconds snaps it open at once")
				t.eq(#cuesOf(sent, "FireDoorSwing"), 1, "silently")
				t.truthy(DoorService.SetState(model, "Locked", 0), "snap locked")
				t.truthy(DoorService.SetState(model, "Open"), "a script may still open a locked door")
				t.eq(DoorService.GetState(model), "Open")
				local last = sentOf(sent, "OneShot")
				local opening = DoorMotion.fromArgs(last[#last].args, last[#last].startAt)
				assert(opening, "opening args")
				t.near(opening.motion.seconds, 1.6, 1e-9, "the default full travel")
				t.truthy(opening.motionId > decoded.motionId, "motion ids increase")
				run(clock, LEAD + 1.7)
				t.truthy(isAt(model, 1), "open again")
				t.eq(table.concat(changes, ","), "Open>Locked,Locked>Closed,Closed>Open,Open>Locked,Locked>Open")
			end)
			connection:Disconnect()
			t.falsy(DoorService.SetState(Instance.new("Model"), "Open"), "an unknown door")
			t.falsy(DoorService.RequestOpen(Instance.new("Model")), "an unknown door")
		end)
	end,

	["live: the gate slams with GateSlam and the DoorSlam noise; a smash is final"] = function(t: Expect)
		inRun({}, function(clock: FakeClock)
			local gate = door(L1, "HallwayGate")
			local noises: { Types.NoiseEvent } = {}
			local connection = NoiseAndDirectorService.NoiseEmitted:Connect(function(event: Types.NoiseEvent)
				table.insert(noises, event)
			end)
			capture(function(sent: { Sent })
				t.truthy(DoorService.SetState(gate, "Locked", 0.35), "slams")
				local shots = sentOf(sent, "OneShot")
				t.eq((shots[1] :: Types.OneShotEvent).kind, "GateSlam", "the gate's close is a GateSlam")
				local slam = cuesOf(sent, "GateSlam")
				t.eq(#slam, 1, "one slam")
				t.eq(#cuesOf(sent, "FireDoorSwing") + #cuesOf(sent, "DoorCreak"), 0, "no hinge sounds on a grille")
				local decoded = DoorMotion.fromArgs(shots[1].args, shots[1].startAt)
				assert(decoded, "args")
				t.eq(decoded.motion.ease, "In", "dropping")
				run(clock, LEAD + 0.2)
				t.eq(#noises, 0, "no noise before it lands")
				run(clock, 0.2)
				t.truthy(isShut(gate), "down")
				local slams = 0
				for _, event in noises do
					if event.kind == "DoorSlam" then
						slams += 1
						t.eq(event.levelId, L1, "on its level")
					end
				end
				t.eq(slams, 1, "one DoorSlam noise when it lands")

				local roof = door(L5, "RoofStairDoor")
				t.truthy(DoorService.SetState(roof, "Smashed"), "smashed")
				local smashShots = sentOf(sent, "OneShot")
				t.eq((smashShots[#smashShots] :: Types.OneShotEvent).kind, "DoorSmash")
				t.eq(#cuesOf(sent, "DoorSmash"), 1, "torn apart")
				run(clock, LEAD + DoorService.SmashSeconds + 0.05)
				for _, name in DoorBuilder.leafNames(roof) do
					local expected = DoorBuilder.smashedTransform(roof, name, 1)
					assert(expected, "smashed pose")
					t.truthy(near(transformOf(roof, name), expected, EPS), name .. " lies smashed")
				end
				t.falsy(DoorService.SetState(roof, "Open"), "nothing reopens a smashed door")
				t.falsy(DoorService.SetState(roof, "Locked"), "or locks it")
				t.falsy(DoorService.RequestOpen(roof), "or opens it on request")
				t.eq(DoorService.GetState(roof), "Smashed")
			end)
			connection:Disconnect()

			-- smashed while standing ajar: the leaf starts from where it stood, ends where a shut one would
			local classroom = door(L1, "ClassroomDoor")
			local ajar = DoorMotion.opennessOf(classroom)
			local start = DoorMotion.transforms(classroom, "Smash", 0, ajar)
			local finish = DoorMotion.transforms(classroom, "Smash", 1, ajar)
			for _, name in DoorBuilder.leafNames(classroom) do
				local open = DoorBuilder.openTransform(classroom, name, ajar)
				local smashed = DoorBuilder.smashedTransform(classroom, name, 1)
				assert(open and smashed, "poses")
				t.truthy(near(start[name], open, EPS), "the smash starts from the ajar pose")
				t.truthy(near(finish[name], smashed, EPS), "and lands on the smashed pose")
			end
			t.truthy(DoorService.SetState(classroom, "Smashed", 0), "a snap smash")
			for _, name in DoorBuilder.leafNames(classroom) do
				local smashed = DoorBuilder.smashedTransform(classroom, name, 1)
				assert(smashed, "pose")
				t.truthy(near(transformOf(classroom, name), smashed, EPS), "smashed at once")
			end
		end)
	end,

	["live: a closing fire door stops short of a player in its swing and finishes once the doorway is clear"] = function(
		t: Expect
	)
		local player, root, humanoid = fakePlayer(CFrame.new(0, -500, 0))
		inRun({ player }, function(clock: FakeClock)
			local model = door(L1, "L1_Door_AirlockWest")
			-- stand where the left leaf passes at 20% open, feet on the floor
			local box = leafBox(model, "LeftLeaf", 0.2)
			local floor = model.WorldPivot.Position.Y
			local spot = CFrame.new(box.Position.X, floor + HIP_HEIGHT + ROOT_SIZE.Y / 2, box.Position.Z)
			root.CFrame = spot
			local bodyCFrame, bodySize = DoorService.characterBox(spot, ROOT_SIZE, HIP_HEIGHT)
			capture(function(sent: { Sent })
				t.truthy(DoorService.SetState(model, "Locked", 1.6), "sealing")
				run(clock, LEAD + 1.6 + 0.3)
				t.truthy(DoorService.IsHeld(model), "held short of the player")
				t.truthy(DoorService.IsMoving(model), "still owed its swing")
				local held = DoorMotion.opennessOf(model)
				t.truthy(held > 0.2 and held < 1, string.format("stopped part way (%.2f)", held))
				for _, name in DoorBuilder.leafNames(model) do
					local cframe, size = leafBox(model, name, held)
					t.falsy(DoorService.boxesOverlap(cframe, size, bodyCFrame, bodySize), name .. " never touches them")
				end
				local shots = sentOf(sent, "OneShot")
				t.eq(#shots, 2, "the swing, then the hold")
				local hold = DoorMotion.fromArgs(shots[2].args, shots[2].startAt)
				assert(hold, "hold args")
				t.truthy(hold.held, "a held OneShot")
				t.near(hold.motion.to, held, 1e-4, "parks the clients' leaves where the server's stopped")
				t.eq(hold.motion.seconds, 0)
				t.truthy(#sentOf(sent, "AudioStop") >= 1, "the latch that was scheduled is called off")

				run(clock, 3)
				t.near(DoorMotion.opennessOf(model), held, 1e-6, "it waits while they stand there")
				t.eq(#sentOf(sent, "OneShot"), 2, "quietly")

				humanoid.Health = 0
				run(clock, DoorService.ClearSeconds * 0.5)
				t.truthy(DoorService.IsHeld(model), "a body that is no longer alive counts as gone only after the wait")
				humanoid.Health = GameConfig.MaxHealth
				run(clock, 2 / GameConfig.ServerTickHz)
				t.truthy(DoorService.IsHeld(model), "alive again: still waiting, the wait starts over")

				root.CFrame = CFrame.new(0, -500, 0)
				run(clock, DoorService.ClearSeconds * 0.5)
				t.truthy(DoorService.IsHeld(model), "the doorway must stay clear for ClearSeconds")
				run(clock, DoorService.ClearSeconds + 2 / GameConfig.ServerTickHz) -- it rechecks at the server tick rate
				t.falsy(DoorService.IsHeld(model), "then it sets off again")
				local resumed = sentOf(sent, "OneShot")
				t.eq(#resumed, 3, "announced")
				local again = DoorMotion.fromArgs(resumed[3].args, resumed[3].startAt)
				assert(again, "resume args")
				t.falsy(again.held)
				t.near(again.motion.from, held, 1e-4, "from where it stopped")
				t.eq(again.motion.to, 0)
				t.near(again.motion.seconds, 1.6 * held, 0.02, "at the pace it had")
				t.eq(#cuesOf(sent, "FireDoorLatch"), 2, "a fresh latch for the new landing")
				run(clock, LEAD + again.motion.seconds + 0.05)
				t.truthy(isShut(model), "shut")
				t.falsy(DoorService.IsMoving(model), "done")
				t.eq(DoorService.GetState(model), "Locked", "the state never wavered")
			end)
		end)
	end,

	["client: DoorController plays the server's motion, honours startAt, drops stale messages, parks holds"] = function(
		t: Expect
	)
		t.truthy(DoorController.accept(nil, 1), "the first message")
		t.truthy(DoorController.accept(3, 4), "a newer one")
		t.falsy(DoorController.accept(4, 4), "a repeat")
		t.falsy(DoorController.accept(5, 4), "an older one")

		local held = message({ held = true }, { from = 0.6, to = 0.6, seconds = 0 })
		local settle = DoorController.renderMotion(held, 0.75, 2000)
		t.eq(settle.from, 0.75, "a hold settles from what the client shows")
		t.eq(settle.to, 0.6, "onto the held pose")
		t.eq(settle.startAt, 2000, "at once")
		t.eq(settle.seconds, DoorController.HoldBlend)
		t.eq(DoorController.renderMotion(held, nil, 2000).seconds, 0, "with nothing shown it just parks")
		local plain = message({})
		t.eq(DoorController.renderMotion(plain, 0.3, 2000), plain.motion, "other messages play as sent")

		local closing = message({}, { from = 1, to = 0, startAt = 10, seconds = 1.6 })
		local slam = DoorController.impactFor("GateSlam", "Gate", closing)
		t.truthy(slam ~= nil and slam.kind == "Slam" and slam.at == 11.6, "the gate lands with a slam")
		local latch = DoorController.impactFor("Door", "Airlock", closing)
		t.truthy(latch ~= nil and latch.kind == "Latch", "a fire door latches")
		t.eq(DoorController.impactFor("Door", "Ajar", closing), nil, "a classroom door just shuts")
		local smash =
			DoorController.impactFor("DoorSmash", "RoofDoor", message({}, { mode = "Smash", from = 0, to = 1 }))
		t.truthy(smash ~= nil and smash.kind == "Smash" and smash.at > 1000, "a smash, just after it starts")
		t.eq(DoorController.impactFor("Door", "Airlock", message({}, { from = 0, to = 1 })), nil, "opening")
		t.eq(DoorController.impactFor("Door", "Airlock", message({ held = true })), nil, "a hold")
		local amplitude, seconds = DoorController.impactShake("Slam", 0)
		t.near(amplitude, DoorController.Impacts[SLAM].amplitude, 1e-9, "full at the gate")
		t.truthy(seconds > 0)
		local farther = DoorController.impactShake("Slam", DoorController.Impacts[SLAM].radius / 2)
		t.near(farther, amplitude / 4, 1e-9, "quadratic falloff")
		t.eq((DoorController.impactShake("Slam", DoorController.Impacts[SLAM].radius)), 0, "nothing at the radius")
		t.eq((DoorController.impactShake("Latch", math.huge)), 0, "nothing far away")

		freshFixtures()
		local folder = Instances.runtimeLevel(L1, false)
		assert(folder, "Level 1 fixtures")
		local model = folder:FindFirstChild("Door_L1_Door_Classroom108")
		assert(model and model:IsA("Model"), "the classroom door")
		local from = DoorMotion.opennessOf(model)
		local shut = message({ motionId = 2 }, { from = from, to = 0, startAt = 3000, seconds = 1 })
		t.truthy(DoorController.Apply(model, shut, "Door", 2999.9), "plays")
		t.truthy(isAt(model, from), "holds its start pose until startAt")
		t.truthy(DoorController.IsPlaying(model))
		DoorController.Render(3000.5)
		t.near(DoorMotion.opennessOf(model), from * 0.5, 0.01, "half way at half time")
		DoorController.Render(3001)
		t.truthy(isShut(model), "lands on the server's end pose")
		t.falsy(DoorController.IsPlaying(model), "and stops rendering")
		t.falsy(DoorController.Apply(model, message({ motionId = 1 }, { from = 0, to = 1 }), "Door", 3002), "stale")
		t.truthy(isShut(model), "a stale message moves nothing")
		local late = message({ motionId = 3 }, { from = 0, to = 1, startAt = 3010, seconds = 1 })
		t.truthy(DoorController.Apply(model, late, "Door", 3020), "a late message")
		t.truthy(isAt(model, 1), "snaps to its end pose")
		t.falsy(DoorController.IsPlaying(model), "with nothing left to render")
		local closingAgain = message({ motionId = 4 }, { from = 1, to = 0, startAt = 3030, seconds = 1 })
		DoorController.Apply(model, closingAgain, "Door", 3030)
		DoorController.Render(3030.5)
		local parked = message({ motionId = 5, held = true }, { from = 0.7, to = 0.7, startAt = 3030.5, seconds = 0 })
		DoorController.Apply(model, parked, "Door", 3030.5)
		DoorController.Render(3030.5 + DoorController.HoldBlend)
		t.truthy(isAt(model, 0.7), "a hold parks the leaves on the server's pose")
		t.falsy(DoorController.IsPlaying(model), "and waits there")
		DoorController.OnRunEnded()
		clearFixtures()
	end,
}
