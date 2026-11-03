--!strict
-- Level 3 (the gymnasium and locker rooms). The Floor 3 scene data (the beat timelines exist, use real presets, and
-- the ball comes to rest), the controller's pure rules against the real blueprint (beat candidates in the showers, at
-- the lockers and on the court; the gym's footprint; the stalk speed table; picks that never repeat; placement in the
-- band and out of sight; the sweep's room and locker), and the controller on a fake clock with every service
-- injected: the Creature's pace on and off the court and back to normal when the level is left, the seeded beats (on
-- time, never twice running, the bang's noise, waiting out a breath check), the locker-room sweep after the dwell,
-- the prowl back to the court, and both held off while a breath check runs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Scenes = require(ReplicatedStorage.Shared.Sequence.Scenes)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local Timeline = require(ReplicatedStorage.Shared.Sequence.Timeline)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)

local Level3 = require(ServerScriptService.Services.Levels.Level3_GymnasiumController)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

type Shot = { kind: Enums.OneShotKind, startAt: number, args: { [string]: Types.OneShotArg } }

type World = {
	now: number,
	player: Player,
	root: Vector3,
	zone: string?,
	sees: boolean,
	creature: Vector3?,
	state: Enums.MonsterState,
	creatureLevel: string?,
	checking: boolean,
	shots: { Shot },
	noises: { { kind: Enums.NoiseKind, at: number } },
	scales: { number },
	alerts: { { position: Vector3, priority: Enums.NoisePriority, at: number } },
}

local L3: Enums.LevelId = "Level3_Gymnasium"
local SEED = 3131
local STEP = 0.1

local function layout(): LayoutSchema.LevelLayout
	local found = Builder.getLayout(L3)
	assert(found, "the Level 3 layout")
	return found
end

local function roomById(id: string): LayoutSchema.Room
	for _, room in layout().rooms do
		if room.id == id then
			return room
		end
	end
	error("no room " .. id)
end

local function centreOf(id: string, y: number): Vector3
	local rect = roomById(id).rect
	return WorldConfig.levelOrigin(L3) + Vector3.new(rect.x + rect.w / 2, y, rect.z + rect.d / 2)
end

local function inRoom(id: string, point: Vector3): boolean
	local p = point - WorldConfig.levelOrigin(L3)
	return LayoutSchema.rectContains(roomById(id).rect, p.X, p.Z, -0.5)
end

local function newWorld(): World
	local player = Instance.new("Player")
	player.Name = "Level3Spec"
	local world: World = {
		now = 100,
		player = player,
		root = centreOf("L3_LockerRoom_Boys", 3),
		zone = "L3_LockerRoom_Boys",
		sees = false,
		creature = centreOf("L3_Gymnasium", 5),
		state = "Dormant",
		creatureLevel = L3,
		checking = false,
		shots = {},
		noises = {},
		scales = {},
		alerts = {},
	}
	return world
end

local function install(world: World)
	Level3.SetDependencies({
		now = function(): number
			return world.now
		end,
		players = function(): { Player }
			return { world.player }
		end,
		rootOf = function(_player: Player): Vector3?
			return world.root
		end,
		eyeOf = function(_player: Player): Vector3?
			return world.root + Vector3.new(0, 1.5, 0)
		end,
		zoneOf = function(_player: Player): string?
			return world.zone
		end,
		lineClear = function(_from: Vector3, _to: Vector3): boolean
			return world.sees
		end,
		oneShot = function(kind: Enums.OneShotKind, startAt: number, args: { [string]: Types.OneShotArg }, _subject)
			table.insert(world.shots, { kind = kind, startAt = startAt, args = args })
		end,
		emit = function(_position: Vector3, kind: Enums.NoiseKind)
			table.insert(world.noises, { kind = kind, at = world.now })
		end,
		creature = function(): (Vector3?, Enums.MonsterState, string?)
			return world.creature, world.state, world.creatureLevel
		end,
		setSpeedScale = function(scale: number)
			table.insert(world.scales, scale)
		end,
		alert = function(position: Vector3, priority: Enums.NoisePriority)
			table.insert(world.alerts, { position = position, priority = priority, at = world.now })
		end,
		checking = function(): boolean
			return world.checking
		end,
	})
end

local function advance(world: World, to: number)
	while world.now < to - 1e-9 do
		world.now = math.min(to, world.now + STEP)
		Level3.Step(world.now)
	end
end

-- Runs `body` with Level 3 active on a fake clock; always tears down.
local function onLevel(body: (world: World) -> ())
	local world = newWorld()
	install(world)
	Level3.BeginRun({ runId = "l3-spec", seed = SEED, difficulty = "Standard", participants = {}, startedAt = 0 })
	Level3.Activate({
		levelId = L3,
		run = { runId = "l3-spec", seed = SEED, difficulty = "Standard", participants = {}, startedAt = 0 },
		root = Instance.new("Model"),
		runtime = Instance.new("Folder"),
	})
	local failure: string? = nil
	xpcall(body, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end, world)
	Level3.Deactivate()
	Level3.EndRun()
	Level3.SetDependencies(nil)
	if failure ~= nil then
		error(failure, 0)
	end
end

local function beatShots(world: World): { Shot }
	local out: { Shot } = {}
	for _, shot in world.shots do
		if shot.kind == "Timeline" then
			table.insert(out, shot)
		end
	end
	return out
end

local function kindOf(id: string): Scenes.GymBeatKind?
	for _, kind: Scenes.GymBeatKind in Scenes.gymBeatKinds() do
		if table.find(Scenes.gymBeatIds(kind), id) then
			return kind
		end
	end
	return nil
end

return {
	["Floor 3 scenes: every beat id has a valid timeline of real presets; the ball comes to rest"] = function(
		t: Expect
	)
		local timelines = Scenes.timelines()
		for _, kind: Scenes.GymBeatKind in Scenes.gymBeatKinds() do
			local ids = Scenes.gymBeatIds(kind)
			t.truthy(#ids >= 1, kind .. " has a timeline")
			for _, id in ids do
				local spec = timelines[id]
				assert(spec, id)
				t.eq(#Timeline.validate(spec), 0, id .. " is valid")
				for _, track in spec.tracks do
					t.eq(track.kind, "sound", id .. " plays positional sounds")
					t.eq(track.arg, Scenes.Args.At, id .. " at the beat's point")
					for _, key in track.keys do
						t.truthy(SynthPresets.has(key.value :: string), id .. " plays " .. tostring(key.value))
					end
				end
			end
		end
		local bounces = Scenes.BallBounces
		for index = 2, #bounces do
			t.truthy(bounces[index].t > bounces[index - 1].t, "in order")
			t.truthy(bounces[index].volume < bounces[index - 1].volume, "each one quieter")
			if index >= 3 then
				local gap = bounces[index].t - bounces[index - 1].t
				local before = bounces[index - 1].t - bounces[index - 2].t
				t.truthy(gap < before, "and sooner")
			end
		end
		for _, preset in { "ShowerDrip", "LockerSlam", "BallBounce", "LockerDoor" } do
			t.falsy(SynthPresets.isLooped(preset), preset .. " is a one-shot")
		end
		t.eq(#SynthPresets.validate(), 0, "every preset passes the recipe rules")
	end,

	["candidates, the gym's footprint, the stalk speed and the sweep's room against the blueprint"] = function(
		t: Expect
	)
		local blueprint = layout()
		local set = Level3.candidates(blueprint)
		t.truthy(#set.showers > 0 and #set.lockers > 0 and #set.court > 0, "every pool has points")
		for _, point in set.showers do
			t.truthy(
				inRoom("L3_Showers_Boys", point)
					or inRoom("L3_Showers_Girls", point)
					or inRoom("L3_Restroom_North", point),
				"a shower point in a shower room"
			)
		end
		for _, point in set.court do
			t.truthy(inRoom(Level3.GymRoom, point), "a court point on the court")
			t.truthy(Level3.inGym(blueprint, point))
		end
		local lockers = 0
		for _, anchor in blueprint.anchors do
			if anchor.kind == "Locker" or anchor.kind == "SmashedLocker" then
				lockers += 1
			end
		end
		t.eq(#set.lockers, lockers, "one point per locker door")
		t.falsy(Level3.inGym(blueprint, centreOf("L3_LockerRoom_Boys", 3)), "the changing rooms are off the court")

		t.eq(Level3.speedScaleFor(true, "Patrol"), Level3.GymSpeedScale)
		t.eq(Level3.speedScaleFor(true, "InvestigateNoise"), Level3.GymSpeedScale)
		t.eq(Level3.speedScaleFor(true, "WallChase"), Level3.GymSpeedScale)
		t.eq(Level3.speedScaleFor(true, "Stunned"), 1, "a stun is never faster")
		t.eq(Level3.speedScaleFor(true, "Scripted"), 1)
		t.eq(Level3.speedScaleFor(false, "WallChase"), 1, "off the court: as configured")
		t.truthy(Level3.GymSpeedScale > 1)

		local fronts = Level3.lockerFronts(blueprint)
		t.truthy(#fronts > 0)
		local boys = 0
		for _, spot in fronts do
			if spot.room == "L3_LockerRoom_Boys" then
				boys += 1
				t.truthy(inRoom("L3_LockerRoom_Boys", spot.front), "the floor before the door is in the room")
			end
		end
		t.truthy(boys > 0, "the boys' changing room has lockers")
		local front = Level3.lockerFront(fronts, "L3_LockerRoom_Boys", Random.new(4))
		assert(front, "a locker front")
		t.truthy(inRoom("L3_LockerRoom_Boys", front))
		t.eq(Level3.lockerFront(fronts, "L3_Gymnasium", Random.new(4)), nil, "no lockers on the court")

		t.eq(Level3.sweepRoom({}, 50), nil)
		t.eq(Level3.sweepRoom({ A = 45 }, 50), nil, "not long enough")
		t.eq(Level3.sweepRoom({ A = 30, B = 20 }, 50), "B", "the room occupied longest")
		t.eq(Level3.sweepRoom({ B = 20, A = 20 }, 50), "A", "ties by id")
	end,

	["picks never repeat, the delays are in range, placement stays in the band and out of sight"] = function(t: Expect)
		local random = Random.new(11)
		local previous: Scenes.GymBeatKind? = nil
		for _ = 1, 200 do
			local kind: Scenes.GymBeatKind? = Level3.pickBeat(random, previous, Scenes.gymBeatKinds())
			t.truthy(kind ~= nil, "a kind")
			t.truthy(kind ~= previous, "never the same twice running")
			previous = kind
			local delay = Level3.nextDelay(random)
			t.truthy(delay >= Level3.IntervalMin and delay <= Level3.IntervalMax)
		end
		t.eq(Level3.pickBeat(random, "BallBounce", { "BallBounce" }), nil, "nothing else to pick")

		local set = Level3.candidates(layout())
		local listener = centreOf("L3_LockerRoom_Boys", 3)
		local hidden = function(_a: Vector3, _b: Vector3): boolean
			return false
		end
		for _, kind: Scenes.GymBeatKind in Scenes.gymBeatKinds() do
			local band = Level3.Bands[kind]
			for _ = 1, 20 do
				local point = Level3.place(kind, set, listener, { listener }, hidden, random)
				if point then
					local distance = MathUtil.horizontalDistance(point, listener)
					t.truthy(distance >= band.min and distance <= band.max, kind .. " in its band")
				end
			end
			local seen = function(_a: Vector3, _b: Vector3): boolean
				return true
			end
			t.eq(Level3.place(kind, set, listener, { listener }, seen, random), nil, kind .. " never in sight")
		end
		t.truthy(
			Level3.place("LockerBang", set, listener, { listener }, hidden, random) ~= nil,
			"a locker bangs nearby"
		)
	end,

	["the Creature stalks fast on the court only, and is back to normal when the level is left"] = function(t: Expect)
		onLevel(function(world: World)
			world.state = "Patrol"
			advance(world, world.now + 0.3)
			t.eq(world.scales[#world.scales], Level3.GymSpeedScale, "on the court")
			t.eq(Level3.GetSpeedScale(), Level3.GymSpeedScale)
			local writes = #world.scales
			advance(world, world.now + 1)
			t.eq(#world.scales, writes, "written only on change")
			world.creature = centreOf("L3_LockerRoom_Girls", 5)
			advance(world, world.now + 0.3)
			t.eq(world.scales[#world.scales], 1, "off the court")
			world.creature = centreOf("L3_Gymnasium", 5)
			world.state = "Stunned"
			advance(world, world.now + 0.3)
			t.eq(world.scales[#world.scales], 1, "stunned: as configured")
			world.state = "WallChase"
			advance(world, world.now + 0.3)
			t.eq(world.scales[#world.scales], Level3.GymSpeedScale)
			world.creatureLevel = "Level4_FloodedPool"
			advance(world, world.now + 0.3)
			t.eq(world.scales[#world.scales], 1, "on another level")
			world.creatureLevel = L3
			advance(world, world.now + 0.3)
			Level3.Deactivate()
			t.eq(world.scales[#world.scales], 1, "the level left: back to normal")
		end)
	end,

	["seeded beats: on time, never the same twice running, the bang's noise, waiting out a breath check"] = function(
		t: Expect
	)
		onLevel(function(world: World)
			world.state = "Patrol"
			world.creature = centreOf("L3_Gymnasium", 5)
			local first = Level3.GetNextAt()
			t.truthy(first - world.now >= Level3.IntervalMin and first - world.now <= Level3.IntervalMax, "22-44 s in")
			advance(world, first - 0.2)
			t.eq(#beatShots(world), 0, "nothing early")
			advance(world, world.now + 400)
			local shots = beatShots(world)
			t.truthy(#shots >= 6, "beats keep coming")
			local previous: Scenes.GymBeatKind? = nil
			local bangs = 0
			for index, shot in shots do
				local kind: Scenes.GymBeatKind? = kindOf(shot.args.id :: string)
				t.truthy(kind ~= nil, "a Floor 3 beat id")
				t.truthy(kind ~= previous, "never twice running")
				previous = kind
				t.truthy(typeof(shot.args[Scenes.Args.At]) == "Vector3", "placed")
				if kind == "LockerBang" then
					bangs += 1
				end
				if index >= 2 then
					local gap = shot.startAt - shots[index - 1].startAt
					t.truthy(gap >= Level3.IntervalMin - 1e-6, "spaced out")
				end
			end
			local bangNoises = 0
			for _, noise in world.noises do
				if noise.kind == "FallingObject" then
					bangNoises += 1
				end
			end
			t.eq(bangNoises, bangs, "every bang is heard")
			t.eq(Level3.PlayedCount(), #shots)

			-- a breath check holds the beats off, and a little longer after it
			world.checking = true
			local held = #beatShots(world)
			advance(world, world.now + 120)
			t.eq(#beatShots(world), held, "silent while the Creature is at a locker")
			world.checking = false
			local released = world.now
			advance(world, released + Level3.CheckGap - 0.2)
			t.eq(#beatShots(world), held, "and for CheckGap after")
			advance(world, released + Level3.CheckGap + Level3.IntervalMax + Level3.Retry * 2)
			t.truthy(#beatShots(world) > held, "then they resume")
		end)
	end,

	["the sweep draws it to the changing room the squad has dwelt in; the prowl calls it back to the court"] = function(
		t: Expect
	)
		onLevel(function(world: World)
			-- out of the gym on patrol, the squad in the boys' changing room
			world.state = "Patrol"
			world.creature = centreOf("L3_NorthHall_West", 5)
			advance(world, world.now + Level3.SweepDwell - 1)
			t.eq(#world.alerts, 0, "no sweep before the dwell")
			advance(world, world.now + Level3.SweepMax + 2)
			local sweep = nil
			for _, alert in world.alerts do
				if inRoom("L3_LockerRoom_Boys", alert.position) then
					sweep = alert
					break
				end
			end
			assert(sweep, "a sweep into the room they are in")
			t.eq(sweep.priority, "Low")
			local sweeps = Level3.PressureCounts()
			t.truthy(sweeps >= 1)

			-- they leave the lockers for the north hall, away from the court; it prowls back to the gym
			world.zone = "L3_NorthHall_West"
			world.root = centreOf("L3_NorthHall_West", 3)
			local before = #world.alerts
			advance(world, world.now + Level3.ProwlMax + Level3.ProwlAway + 2)
			local prowled = false
			for index = before + 1, #world.alerts do
				if inRoom(Level3.GymRoom, world.alerts[index].position) then
					prowled = true
				end
			end
			t.truthy(prowled, "called back to the court")
			local _, prowls = Level3.PressureCounts()
			t.truthy(prowls >= 1)

			-- nobody pulls it anywhere while a breath check runs
			world.zone = "L3_LockerRoom_Boys"
			world.root = centreOf("L3_LockerRoom_Boys", 3)
			world.checking = true
			local during = #world.alerts
			advance(world, world.now + 200)
			t.eq(#world.alerts, during, "held off during the check")

			-- nor while it is busy (not patrolling)
			world.checking = false
			world.state = "InvestigateNoise"
			advance(world, world.now + 200)
			t.eq(#world.alerts, during, "only a patrolling Creature is steered")
		end)
	end,

	["the beat director's timing constants are the brief's"] = function(t: Expect)
		t.truthy(Level3.IntervalMin < Level3.IntervalMax)
		t.truthy(Level3.Bands.BallBounce.max > Level3.Bands.ShowerDrip.max, "the ball is the distant one")
		t.truthy(Level3.CheckGap >= 1 / GameConfig.ServerTickHz)
		t.eq(Level3.LevelId, L3)
		t.eq(Level3.Controller.LevelId, L3)
	end,
}
