--!strict
-- Levels. The shared scene data (every timeline valid, the classroom scare's beats in order and keyed where the
-- server times them, the presets it names), the subject's camera maths (stumble, the drag onto the Creature), the
-- staged corner crouch pose, LevelKit's schedule and sight test, and the three level controllers on a fake clock with
-- every service injected:
--   Level 1  the blueprint geometry (the pose, the glass, the gate line, what lies past it, the hiding spots), the
--            trigger table for every way in (glass, the classroom, near with a sightline, slipping past through a
--            side room, past the gate or in its bypass vent; never from inside a duct), the whole scene on time
--            (staging, the FloorDebris noise and the Timeline, the back turned for the snap, both bursts, the vanish,
--            the hide, the dead bulbs, the gate landing at GateLand, the hidden move east and out of sight, the
--            seeded release and the alert), once per run, staging held while the corner is in sight, the busy
--            fallback (crunch + gate only), a scene cut short by leaving the level, the bulbs restored at the end.
--   Level 0  candidates, the seeded director (never the same beat twice, 25-50 s apart, deferred after a TrapSnap),
--            placement in the band and out of sight, the surge's bulbs, the falling object's noise.
--   Level 2  the restock rules and spot choice (free, far, unseen), the 45 s spacing, the one-time hint.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Creature = require(ReplicatedStorage.Shared.Animation.ProceduralAnimator.Profiles.Creature)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local NoiseConfig = require(ReplicatedStorage.Shared.Config.NoiseConfig)
local Scenes = require(ReplicatedStorage.Shared.Sequence.Scenes)
local Strings = require(ReplicatedStorage.Shared.Strings)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local Timeline = require(ReplicatedStorage.Shared.Sequence.Timeline)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)

local MonsterAIService = require(ServerScriptService.Services.Monster.MonsterAIService)
local Level0 = require(ServerScriptService.Services.Levels.Level0_BasementController)
local Level1 = require(ServerScriptService.Services.Levels.Level1_HallwaysController)
local Level2 = require(ServerScriptService.Services.Levels.Level2_ScienceHallController)
local LevelKit = require(ServerScriptService.Services.Levels.LevelKit)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Handle = MonsterAIService.ScriptedHandle

type Call = { name: string, at: number, value: any }

type Shot = {
	kind: Enums.OneShotKind,
	startAt: number,
	args: { [string]: Types.OneShotArg },
	subject: Instance?,
	at: number,
}

type L1World = {
	now: number,
	calls: { Call }, -- handle calls, gate locks, alerts, noises
	shots: { Shot },
	player: Player,
	eye: Vector3,
	feet: Vector3,
	zone: string?,
	onGlass: boolean,
	inVent: boolean,
	acquireOk: boolean,
	acquired: number,
	creature: CFrame?,
	hidden: boolean,
	sees: (from: Vector3, to: Vector3) -> boolean,
	glow: BasePart,
	spill: BasePart,
	gate: Model,
}

local L0: Enums.LevelId = "Level0_Basement"
local L1: Enums.LevelId = "Level1_Hallways"
local L2: Enums.LevelId = "Level2_ScienceHall"
local SEED = 4242
local LEAD = GameConfig.OneShotLead
local STEP = 0.01
local C = Scenes.ClassroomScare

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function runContext(seed: number): Types.RunContext
	return { runId = "spec", seed = seed, difficulty = "Standard", participants = {}, startedAt = 0 }
end

local function levelContext(levelId: Enums.LevelId, seed: number): Types.LevelContext
	return {
		levelId = levelId,
		run = runContext(seed),
		root = Instance.new("Model"),
		runtime = Instance.new("Folder"),
	}
end

local function localPoint(levelId: string, x: number, y: number, z: number): Vector3
	return WorldConfig.levelOrigin(levelId) + Vector3.new(x, y, z)
end

local function firstCall(calls: { Call }, name: string): Call?
	for _, call in calls do
		if call.name == name then
			return call
		end
	end
	return nil
end

local function countCalls(calls: { Call }, name: string): number
	local count = 0
	for _, call in calls do
		if call.name == name then
			count += 1
		end
	end
	return count
end

local function shotsOf(shots: { Shot }, kind: Enums.OneShotKind): { Shot }
	local out: { Shot } = {}
	for _, shot in shots do
		if shot.kind == kind then
			table.insert(out, shot)
		end
	end
	return out
end

local function newPlayer(userId: number, name: string): Player
	local player = Instance.new("Player")
	player.Name = name
	player.UserId = userId
	return player
end

-- A scripted handle that records every call (with the world's clock) and moves the world's Creature.
local function fakeHandle(world: L1World): Handle
	local function record(name: string, value: any)
		table.insert(world.calls, { name = name, at = world.now, value = value })
	end
	local handle: Handle
	handle = {
		MoveTo = function(_self: Handle, position: Vector3, _speed: number?)
			record("MoveTo", position)
		end,
		Teleport = function(_self: Handle, cframe: CFrame)
			world.creature = cframe
			record("Teleport", cframe)
		end,
		SetPose = function(_self: Handle, poseMode: Enums.PoseMode)
			record("SetPose", poseMode)
		end,
		SetHidden = function(_self: Handle, hidden: boolean)
			world.hidden = hidden
			record("SetHidden", hidden)
		end,
		Face = function(_self: Handle, position: Vector3)
			record("Face", position)
		end,
		Release = function(_self: Handle, nextState: Enums.MonsterState?)
			record("Release", nextState)
		end,
	}
	return handle
end

local function newL1World(): L1World
	local folder = Instance.new("Folder")
	local glow = Instance.new("Part")
	glow.Name = "L1_Light_ClassroomGlow"
	glow:SetAttribute("BaseBrightness", 1.1)
	glow.Parent = folder
	local spill = Instance.new("Part")
	spill.Name = "L1_Light_ClassroomGlowSpill"
	spill:SetAttribute("BaseBrightness", 0.6)
	spill.Parent = folder
	local world: L1World = {
		now = 100,
		calls = {},
		shots = {},
		player = newPlayer(9101, "Subject"),
		-- the east airlock, well away from the classroom
		eye = localPoint(L1, 232, 3.5 + 1.5, 80),
		feet = localPoint(L1, 232, 0, 80),
		zone = "L1_AirlockEast",
		onGlass = false,
		inVent = false,
		acquireOk = true,
		acquired = 0,
		creature = CFrame.new(localPoint(L1, 220, 5, 12)),
		hidden = false,
		sees = function(_from: Vector3, _to: Vector3): boolean
			return false
		end,
		glow = glow,
		spill = spill,
		gate = Instance.new("Model"),
	}
	return world
end

local function l1Dependencies(world: L1World): Level1.Dependencies
	local handle = fakeHandle(world)
	return {
		now = function(): number
			return world.now
		end,
		players = function(): { Player }
			return { world.player }
		end,
		eyeOf = function(_player: Player): Vector3?
			return world.eye
		end,
		feetOf = function(_player: Player): Vector3?
			return world.feet
		end,
		zoneOf = function(_player: Player): string?
			return world.zone
		end,
		onGlass = function(_player: Player): boolean
			return world.onGlass
		end,
		inVent = function(_player: Player): boolean
			return world.inVent
		end,
		lineClear = function(from: Vector3, to: Vector3): boolean
			return world.sees(from, to)
		end,
		acquire = function(_token: string): Handle?
			world.acquired += 1
			return if world.acquireOk then handle else nil
		end,
		alert = function(position: Vector3, priority: Enums.NoisePriority)
			table.insert(
				world.calls,
				{ name = "Alert", at = world.now, value = { position = position, priority = priority } }
			)
		end,
		creatureRoot = function(): CFrame?
			return world.creature
		end,
		creatureModel = function(): Model?
			return nil
		end,
		creatureHidden = function(): boolean
			return world.hidden
		end,
		gate = function(): Model?
			return world.gate
		end,
		lockGate = function(_gate: Model, seconds: number): boolean
			table.insert(world.calls, { name = "LockGate", at = world.now, value = seconds })
			return true
		end,
		oneShot = function(
			kind: Enums.OneShotKind,
			startAt: number,
			args: { [string]: Types.OneShotArg },
			subject: Instance?
		)
			table.insert(
				world.shots,
				{ kind = kind, startAt = startAt, args = args, subject = subject, at = world.now }
			)
		end,
		emit = function(position: Vector3, kind: Enums.NoiseKind, source: Player?)
			table.insert(
				world.calls,
				{ name = "Emit", at = world.now, value = { position = position, kind = kind, source = source } }
			)
		end,
		fixture = function(lightId: string): BasePart?
			if lightId == world.glow.Name then
				return world.glow
			elseif lightId == world.spill.Name then
				return world.spill
			end
			return nil
		end,
	}
end

local function advance(world: L1World, untilAt: number)
	while world.now < untilAt - 1e-9 do
		world.now += STEP
		Level1.Step(world.now)
	end
end

local function startL1(world: L1World)
	Level1.SetDependencies(l1Dependencies(world))
	Level1.BeginRun(runContext(SEED))
	Level1.Activate(levelContext(L1, SEED))
end

local function stopL1()
	Level1.EndRun()
	Level1.SetDependencies(nil)
end

local function sceneShot(world: L1World): Shot?
	for _, shot in world.shots do
		if shot.kind == "Timeline" then
			return shot
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["Scenes: every timeline is valid and every preset it names exists"] = function(t: Expect)
		local timelines = Scenes.timelines()
		t.truthy(timelines[C.Id] ~= nil, "the classroom scare")
		t.truthy(timelines[C.SkippedId] ~= nil, "the busy fallback")
		for _, kind: Scenes.BeatKind in Scenes.beatKinds() do
			for _, id in Scenes.beatIds(kind) do
				t.truthy(timelines[id] ~= nil, kind .. " plays " .. id)
			end
		end
		for id, spec in timelines do
			local errors = Timeline.validate(spec)
			t.eq(#errors, 0, id .. ": " .. table.concat(errors, "; "))
			for _, track in spec.tracks do
				local presetHolder = if track.kind == Scenes.Tracks.MovingSound then track.target else nil
				if presetHolder then
					t.truthy(SynthPresets.has(presetHolder), id .. " moves " .. presetHolder)
				end
				if track.kind == "sound" or track.kind == Scenes.Tracks.NearSound then
					for _, key in track.keys do
						t.truthy(SynthPresets.has(key.value :: string), id .. " plays " .. tostring(key.value))
					end
				end
				if track.kind == "creature" then
					for _, key in track.keys do
						t.truthy(Creature.isAction(key.value), id .. ": creature action " .. tostring(key.value))
					end
				end
			end
		end
		t.eq(#SynthPresets.validate(), 0, table.concat(SynthPresets.validate(), "; "))
		for _, name in { "PipeBang", "BoilerSurge", "CeilingDrag", "ChildWhisper", "ChildLaugh", "ObjectFall" } do
			t.truthy(SynthPresets.has(name), name)
			t.falsy(SynthPresets.isLooped(name) and name ~= "CeilingDrag", name .. " is a one-shot")
		end
		t.truthy(SynthPresets.isLooped("CeilingDrag"), "the drag loops until its track stops it")
		t.truthy(Strings.has(Level2.HintKey), "the flask hint has a string")
		local fall = NoiseConfig.Kinds.FallingObject
		t.eq(fall.priority, "Low", "a falling object is a Low noise")
		t.truthy(fall.radius > 0, "that something can hear")
	end,

	["Scenes: the classroom scare's beats run in order and its tracks key them where the server times them"] = function(
		t: Expect
	)
		local order = { 0, C.Snap, C.Hush, C.Burst, C.Vanish, C.Hide, C.CameraEnd, C.KillLights, C.GateLand }
		for index = 2, #order do
			t.truthy(order[index] > order[index - 1], "beat " .. index .. " follows beat " .. (index - 1))
		end
		t.truthy(C.Relocate > C.GateLand and C.Duration > C.GateLand, "the move and the timeline end after the slam")
		-- the snap lands on its stare before the hush; the glitch starts while the bulbs strobe and the body is hidden
		-- before the glitch ends, as the bulbs die
		local snap = Creature.NeckSnapTiming
		t.truthy(C.Snap + snap.settle <= C.Hush + 0.05, "the snap has settled by the hush")
		t.truthy(C.Vanish > C.Burst and C.Vanish < C.Burst + 0.42, "the vanish starts in the burst's stutter")
		t.truthy(C.Hide <= C.Vanish + Creature.ActionDurations.Vanish, "hidden as the glitch ends")
		t.truthy(C.ReleaseMin >= 6 and C.ReleaseMax <= 9, "it hunts 6-9 s after the slam")
		local spec = Scenes.timelines()[C.Id]
		local found: { [string]: number } = {}
		for _, track in spec.tracks do
			for _, key in track.keys do
				if type(key.value) == "string" then
					found[track.kind .. ":" .. (key.value :: string)] = key.t
				end
				if track.kind == Scenes.Tracks.SubjectCamera and key.value == "Release" then
					t.truthy(key.persist == true, "the camera release persists (a late start still ends)")
				end
			end
		end
		t.eq(found["sound:GlassCrunch"], 0, "the crunch opens it")
		t.eq(found["creature:NeckSnap"], C.Snap, "NeckSnap")
		t.eq(found["sound:NeckSnap"], C.Snap, "its crack")
		t.eq(found["nearSound:ScareHush"], C.Hush, "the hush")
		t.eq(found["sound:LightBurst"] ~= nil, true, "the bursts are heard")
		t.eq(found["sound:CreatureVanish"], C.Vanish, "the vanish")
		t.eq(found["sceneCamera:Release"], C.CameraEnd, "the view is handed back")
		t.truthy(C.Duration >= C.GateLand, "the timeline outlasts the slam")
	end,

	["Scenes: the stumble jolts down and settles, the drag holds on the face"] = function(t: Expect)
		t.truthy(Scenes.Flinch(0, 1) == CFrame.identity, "nothing before it starts")
		t.truthy(Scenes.Flinch(C.Flinch, 1) == CFrame.identity, "nothing once it is over")
		t.truthy(Scenes.Flinch(0.1, 0) == CFrame.identity, "MotionScale 0 keeps the camera still")
		local peak = Scenes.Flinch(0.09, 1)
		t.truthy(peak.LookVector.Y < -0.15, "a hard jolt down toward the feet")
		t.truthy(peak.Position.Y < -0.15, "the knees buckle")
		local half = Scenes.Flinch(0.09, 0.5)
		t.truthy(half.LookVector.Y > peak.LookVector.Y, "MotionScale scales it")
		local late = Scenes.Flinch(C.Flinch - 0.02, 1)
		t.truthy(math.abs(late.LookVector.Y) < 0.01, "settled by the end")

		t.eq(Scenes.PullWeight(0), 0, "the player's own look until the snap")
		t.eq(Scenes.PullWeight(C.Snap - 0.05), 0, "still theirs")
		local previous = 0
		for step = 0, 40 do
			local w = Scenes.PullWeight(C.Snap + step * 0.01)
			t.truthy(w >= previous - 1e-9 and w <= 1, "the drag only tightens")
			previous = w
		end
		t.near(Scenes.PullWeight(C.Snap + 0.4), 1, 1e-6, "locked on")
		t.near(Scenes.PullWeight(C.CameraEnd + 1), 1, 1e-6, "held until the release hands it back")

		local eye = CFrame.lookAt(Vector3.new(0, 5, 0), Vector3.new(0, 5, -10))
		local head = Vector3.new(10, 6, 0)
		t.truthy(Scenes.Pulled(eye, head, 0) == eye, "weight 0 is the player's look")
		local locked = Scenes.Pulled(eye, head, 1)
		t.truthy((locked.Position - eye.Position).Magnitude < 1e-6, "the eye stays where it is")
		t.truthy(locked.LookVector:Dot((head - eye.Position).Unit) > 0.999, "weight 1 stares at the face")
		t.truthy(Scenes.Pulled(eye, eye.Position, 1) == eye, "a target at the eye changes nothing")
	end,

	["Creature profile: a scripted hold in Hunched is the corner crouch"] = function(t: Expect)
		t.eq(Creature.resolveState("Scripted", "Hunched", false), "Dormant", "Scripted + Hunched")
		t.eq(Creature.resolveState("Scripted", "Biped", false), "Scripted", "Scripted + Biped")
		t.eq(Creature.resolveState("Patrol", "Hunched", false), "Patrol", "Hunched elsewhere only ducks")
		t.eq(Creature.resolveState("Scripted", "Quadruped", true), "VentCrawl", "the duct still wins")
	end,

	["LevelKit: the schedule runs on time, in order, and the sight test honours range and walls"] = function(t: Expect)
		local schedule = LevelKit.newSchedule()
		local ran: { string } = {}
		schedule:At(2, "b", function()
			table.insert(ran, "b")
		end)
		schedule:At(1, "a", function()
			table.insert(ran, "a")
			schedule:At(1.5, "a2", function()
				table.insert(ran, "a2")
			end)
		end)
		schedule:At(2, "c", function()
			table.insert(ran, "c")
		end)
		t.eq(table.concat(schedule:Pending(), ","), "a,b,c")
		t.eq(schedule:Run(0.5), 0, "nothing due")
		t.eq(schedule:Run(1.2), 1)
		t.eq(table.concat(ran, ","), "a")
		t.eq(schedule:Run(5), 3, "a2 (added by a), then b and c in the order they were added")
		t.eq(table.concat(ran, ","), "a,a2,b,c")
		t.truthy(schedule:IsEmpty())
		schedule:At(9, "x", function()
			table.insert(ran, "x")
		end)
		schedule:Clear()
		t.eq(schedule:Run(10), 0, "cleared")

		local eyes = { Vector3.new(0, 0, 0) }
		local open = function(_a: Vector3, _b: Vector3): boolean
			return true
		end
		local wall = function(_a: Vector3, _b: Vector3): boolean
			return false
		end
		t.truthy(LevelKit.seenBy(eyes, Vector3.new(0, 0, 50), open), "in the open")
		t.falsy(LevelKit.seenBy(eyes, Vector3.new(0, 0, 50), wall), "behind a wall")
		t.falsy(LevelKit.seenBy(eyes, Vector3.new(0, 0, 400), open), "too far")
		t.falsy(LevelKit.seenBy({}, Vector3.zero, open), "nobody looking")
	end,

	["Level 1: the blueprint gives the pose, the glass, the gate line and what lies past it"] = function(t: Expect)
		local layout = Builder.getLayout(L1)
		assert(layout, "Level 1 layout")
		local g = Level1.geometry(layout)
		t.truthy((g.pose.Position - localPoint(L1, 161.5, 5, 43.5)).Magnitude < 1e-3, "the pose anchor")
		local facing = g.pose.LookVector
		t.truthy(facing.X < -0.6 and facing.Z < -0.6, "facing into the north-west corner")
		t.eq(g.gateX, 120, "the gate's wall")
		t.eq(g.glassMinX, 170, "the glass band's west edge")
		t.eq(g.corridor, "L1_Corridor_East")
		for _, room in { "L1_AirlockWest", "L1_Corridor_West", "L1_Classroom_101", "L1_ArtRoom", "L1_Chase_Gate" } do
			t.truthy(g.beyond[room], room .. " lies past the gate")
		end
		for _, room in
			{ "L1_Corridor_East", "L1_Classroom_108", "L1_AirlockEast", "L1_NorthHall_East", "L1_Restroom_Girls" }
		do
			t.falsy(g.beyond[room], room .. " is on the near side")
		end
		t.eq(#g.lights, 2, "both glow fixtures")
		t.eq(g.lights[1].id, "L1_Light_ClassroomGlow")
		t.eq(g.lights[2].id, "L1_Light_ClassroomGlowSpill")
		t.truthy(#g.hidingSpots >= 6, "patrol spots to hide in")
		local origin = WorldConfig.levelOrigin(L1)
		for _, spot in g.hidingSpots do
			t.truthy(spot.X - origin.X > g.gateX + 16, "every hiding spot is well east of the gate")
		end
		t.truthy((g.alertPoint - localPoint(L1, 175, 0, 80)).Magnitude < 1e-3, "the alert is the middle of the glass")
	end,

	["Level 1: every way in sets it off, nothing from inside a duct or the near side does"] = function(t: Expect)
		local layout = Builder.getLayout(L1)
		assert(layout, "Level 1 layout")
		local g = Level1.geometry(layout)
		type Row = { sample: Level1.Sample, expected: string? }
		local function sample(fields: { [string]: any }): Level1.Sample
			return {
				onGlass = fields.onGlass == true,
				zone = fields.zone,
				localX = fields.localX,
				inVent = fields.inVent == true,
				distance = fields.distance,
				sightline = fields.sightline == true,
			}
		end
		local rows: { Row } = {
			{ sample = sample({ onGlass = true, zone = "L1_Corridor_East", localX = 175 }), expected = "Glass" },
			{ sample = sample({ zone = "L1_Classroom_108", localX = 160 }), expected = "Classroom" },
			{
				sample = sample({ zone = "L1_NorthHall_East", localX = 162, distance = 10, sightline = true }),
				expected = "Near",
			},
			{
				sample = sample({ zone = "L1_NorthHall_East", localX = 162, distance = 10, sightline = false }),
				expected = nil,
			},
			{
				sample = sample({ zone = "L1_Chase_North", inVent = true, distance = 6, sightline = true }),
				expected = nil,
			},
			{ sample = sample({ zone = "L1_Corridor_East", localX = 165 }), expected = "Slipped" },
			{ sample = sample({ zone = "L1_Corridor_East", localX = 190 }), expected = nil },
			{ sample = sample({ zone = "L1_Chase_Gate", inVent = true, localX = 128 }), expected = "Beyond" },
			{ sample = sample({ zone = "L1_Corridor_West", localX = 100 }), expected = "Beyond" },
			{ sample = sample({ zone = "L1_AirlockEast", localX = 234 }), expected = nil },
			{ sample = sample({ zone = nil }), expected = nil },
		}
		for index, row in rows do
			t.eq(Level1.triggerReason(row.sample, g), row.expected, "row " .. index)
		end
		local who, why = Level1.pickSubject({
			{ who = "late", reason = "Beyond" :: Level1.Reason },
			{ who = "glass", reason = "Glass" :: Level1.Reason },
			{ who = "room", reason = "Classroom" :: Level1.Reason },
		})
		t.eq(who, "glass", "the glass outranks the fallbacks")
		t.eq(why, "Glass")
		local nobody = Level1.pickSubject({} :: { { who: string, reason: Level1.Reason } })
		t.eq(nobody, nil)
		local root = Vector3.new(0, 5, 0)
		local turned = Level1.backTurn(root, Vector3.new(10, 6, 10))
		assert(turned, "a back turn")
		local facing = MathUtil.flat(turned - root).Unit
		t.truthy(facing:Dot(Vector3.new(-1, 0, -1).Unit) > 0.999, "its back is square to the eye")
		t.eq(Level1.backTurn(root, Vector3.new(0, 9, 0)), nil, "an eye straight above gives nothing to turn to")
		local delay = Level1.releaseDelay(SEED)
		t.truthy(delay >= C.ReleaseMin and delay <= C.ReleaseMax, "6-9 s")
		t.eq(Level1.releaseDelay(SEED), delay, "seeded")
	end,

	["Level 1: the scene plays on time, once, and leaves the gate shut and the bulbs dead for the run"] = function(
		t: Expect
	)
		local world = newL1World()
		startL1(world)
		local ok, err = pcall(function()
			t.eq(world.acquired, 1, "taken on Activate")
			t.eq(countCalls(world.calls, "Teleport"), 0, "not placed during the activation itself")
			advance(world, world.now + 0.05)
			local layout = Builder.getLayout(L1)
			assert(layout, "layout")
			local g = Level1.geometry(layout)
			local staged = firstCall(world.calls, "Teleport")
			assert(staged, "staged")
			t.truthy((staged.value :: CFrame).Position == g.pose.Position, "in the corner")
			t.eq((firstCall(world.calls, "SetPose") :: Call).value, "Hunched", "hunched")
			t.eq((firstCall(world.calls, "SetHidden") :: Call).value, false, "shown")
			t.truthy(Level1.IsStaged())

			-- walking the corridor: nothing yet
			world.zone = "L1_Corridor_East"
			world.eye = localPoint(L1, 200, 5, 80)
			advance(world, world.now + 2)
			t.eq(sceneShot(world), nil, "no scene east of the glass")

			-- onto the glass, in sight of the corner
			world.onGlass = true
			world.eye = localPoint(L1, 175, 5, 78)
			world.feet = localPoint(L1, 175, 0, 78)
			-- they can see into the corner; nobody can see the patrol spots east of here
			world.sees = function(_a: Vector3, to: Vector3): boolean
				return (to - g.pose.Position).Magnitude < 6
			end
			advance(world, world.now + 0.2)
			local shot = sceneShot(world)
			assert(shot, "the scene started")
			local s = shot.startAt
			t.near(s - shot.at, LEAD, 1e-6, "startAt = now + OneShotLead")
			t.eq(shot.args.id, C.Id)
			t.eq(shot.args.subject, world.player.UserId, "the subject")
			t.truthy(shot.args.feet == world.feet, "the crunch at their feet")
			t.eq(shot.args.focus, true, "they can see it")
			t.truthy(typeof(shot.args.head) == "Vector3" and typeof(shot.args.glow) == "Vector3", "positions")
			local noise = firstCall(world.calls, "Emit")
			assert(noise, "noise")
			t.eq(noise.value.kind, "FloorDebris", "the FloorDebris noise")
			t.eq(noise.value.source, world.player, "made by the subject")
			t.truthy(Level1.HasRun())

			advance(world, s + C.Duration + C.ReleaseMax + 1)
			local face = firstCall(world.calls, "Face")
			assert(face, "the back turned for the snap")
			t.near(face.at, s + C.Snap - C.FaceLead, STEP + 1e-6, "just before the snap")
			local root = g.pose.Position
			local away = MathUtil.flat((face.value :: Vector3) - root).Unit
			t.truthy(away:Dot(MathUtil.flat(root - world.eye).Unit) > 0.999, "its back square to the subject")

			local bursts = shotsOf(world.shots, "LightBurst")
			t.eq(#bursts, 2, "both bulbs burst")
			t.near(bursts[1].startAt, s + C.Burst, 1e-6, "the glow at Burst")
			t.near(bursts[2].startAt, s + C.Burst + C.SpillStagger, 1e-6, "the spill a beat later")
			t.eq(bursts[1].args.lightId, "L1_Light_ClassroomGlow")
			t.truthy(bursts[1].at <= bursts[1].startAt - LEAD + STEP, "announced a lead ahead")
			local vanish = shotsOf(world.shots, "CreatureVanish")
			t.eq(#vanish, 1, "one vanish")
			t.near(vanish[1].startAt, s + C.Vanish, 1e-6, "at Vanish")

			local hide: Call? = nil
			for _, call in world.calls do
				if call.name == "SetHidden" and call.value == true then
					hide = call
				end
			end
			assert(hide, "hidden")
			t.near(hide.at, s + C.Hide, STEP + 1e-6, "hidden as the bulbs die")

			t.eq(world.glow:GetAttribute("BaseBrightness"), 0, "the glow stays dead for the run")
			t.eq(world.spill:GetAttribute("BaseBrightness"), 0, "so does the spill")

			local gate = firstCall(world.calls, "LockGate")
			assert(gate, "the gate")
			t.eq(gate.value, Level1.GateSeconds, "slammed in 0.35 s")
			t.near(gate.at + LEAD + gate.value, s + C.GateLand, STEP + 1e-6, "it lands at GateLand")
			t.eq(countCalls(world.calls, "LockGate"), 1, "once")

			local moved: Call? = nil
			for _, call in world.calls do
				if call.name == "Teleport" and call ~= staged then
					moved = call
				end
			end
			assert(moved, "moved out of sight")
			t.truthy(moved.at > hide.at, "only once hidden")
			local spot = (moved.value :: CFrame).Position
			t.truthy(spot.X - WorldConfig.levelOrigin(L1).X > g.gateX + 16, "east of the gate")
			t.truthy((spot - world.eye).Magnitude >= Level1.HideDistance, "away from the squad")

			local release = firstCall(world.calls, "Release")
			assert(release, "released")
			t.eq(release.value, "Patrol", "to Patrol")
			t.near(release.at, s + C.GateLand + Level1.releaseDelay(SEED), STEP + 1e-6, "6-9 s after the slam")
			local alert = firstCall(world.calls, "Alert")
			assert(alert, "alerted")
			t.truthy(alert.at >= release.at, "after the release")
			t.truthy((alert.value.position - g.alertPoint).Magnitude < 1e-6, "to the glass")
			t.eq(alert.value.priority, "High")
			t.falsy(Level1.IsHolding(), "let go")

			-- once per run: standing on the glass again does nothing, nor does coming back to the level
			local before = #world.shots
			advance(world, world.now + 3)
			Level1.Deactivate()
			Level1.Activate(levelContext(L1, SEED))
			advance(world, world.now + 1)
			t.eq(#world.shots, before, "never twice")
			t.eq(world.acquired, 1, "never taken again")
		end)
		stopL1()
		t.eq(world.glow:GetAttribute("BaseBrightness"), 1.1, "the run's end restores the glow")
		t.eq(world.spill:GetAttribute("BaseBrightness"), 0.6, "and the spill")
		if not ok then
			error(err, 0)
		end
	end,

	["Level 1: staging waits while the corner is in sight; a busy Creature still gets the crunch and the gate"] = function(
		t: Expect
	)
		local world = newL1World()
		local layout = Builder.getLayout(L1)
		assert(layout, "layout")
		local g = Level1.geometry(layout)
		-- standing in the classroom doorway with a clear view of the corner
		world.zone = "L1_Corridor_East"
		world.eye = localPoint(L1, 190, 5, 80)
		world.sees = function(_a: Vector3, to: Vector3): boolean
			return (to - g.pose.Position).Magnitude < 4
		end
		startL1(world)
		local ok, err = pcall(function()
			advance(world, world.now + 2.5)
			t.eq(countCalls(world.calls, "Teleport"), 0, "never placed in front of anyone")
			world.sees = function(_a: Vector3, _b: Vector3): boolean
				return false
			end
			advance(world, world.now + 1.3)
			t.eq(countCalls(world.calls, "Teleport"), 1, "placed once nobody looks")
		end)
		stopL1()
		if not ok then
			error(err, 0)
		end

		local busy = newL1World()
		busy.acquireOk = false
		startL1(busy)
		local ok2, err2 = pcall(function()
			advance(busy, busy.now + 0.5)
			t.truthy(busy.acquired >= 2, "asked again while busy")
			busy.onGlass = true
			busy.zone = "L1_Corridor_East"
			busy.eye = localPoint(L1, 175, 5, 80)
			advance(busy, busy.now + 0.2)
			local shot = sceneShot(busy)
			assert(shot, "the crunch")
			t.eq(shot.args.id, C.SkippedId, "the crunch and stumble alone")
			advance(busy, shot.startAt + C.SkippedGateLand + C.ReleaseMax + 1)
			local gate = firstCall(busy.calls, "LockGate")
			assert(gate, "the gate still slams")
			t.near(gate.at + LEAD + gate.value, shot.startAt + C.SkippedGateLand, STEP + 1e-6, "soon after")
			t.eq(#shotsOf(busy.shots, "LightBurst"), 0, "no burst without the Creature")
			t.eq(firstCall(busy.calls, "Release"), nil, "nothing to let go")
			t.eq(busy.glow:GetAttribute("BaseBrightness"), 1.1, "the glow burns on")
		end)
		stopL1()
		if not ok2 then
			error(err2, 0)
		end
	end,

	["Level 1: leaving mid-scene finishes the world and parks the Creature"] = function(t: Expect)
		local world = newL1World()
		startL1(world)
		local ok, err = pcall(function()
			advance(world, world.now + 0.2)
			world.zone = "L1_Classroom_108"
			world.eye = localPoint(L1, 170, 5, 60)
			advance(world, world.now + 0.2)
			local shot = sceneShot(world)
			assert(shot, "started from inside the classroom")
			advance(world, shot.startAt + C.Snap + 0.1)
			Level1.Deactivate()
			local gate = firstCall(world.calls, "LockGate")
			assert(gate, "the gate shut at once")
			t.eq(gate.value, 0, "snapped")
			t.eq(world.glow:GetAttribute("BaseBrightness"), 0, "the bulbs are dead")
			local release = firstCall(world.calls, "Release")
			assert(release, "let go")
			t.eq(release.value, "Dormant", "parked for the next level")
			t.eq(#Level1.Pending(), 0, "nothing left to run")
			local count = #world.calls
			advance(world, world.now + 10)
			t.eq(#world.calls, count, "nothing ran after leaving")
		end)
		stopL1()
		if not ok then
			error(err, 0)
		end
	end,

	["Level 0: candidates, the seeded director's rules, placement and the surge's bulbs"] = function(t: Expect)
		local layout = Builder.getLayout(L0)
		assert(layout, "Level 0 layout")
		local set = Level0.candidates(layout)
		t.truthy(#set.ceiling > 40 and #set.ceiling == #set.floor and #set.floor == #set.voice, "a lattice per room")
		t.eq(#set.boilers, 4, "the four boiler glows")
		local origin = WorldConfig.levelOrigin(L0)
		for _, point in set.floor do
			local x, z = point.X - origin.X, point.Z - origin.Z
			t.falsy(x > 228 and z > 66 and z < 94, "never in the stair airlock")
		end

		local random = MathUtil.seededRandom(SEED, "spec")
		local previous: Scenes.BeatKind? = nil
		local seen: { [string]: boolean } = {}
		for _ = 1, 200 do
			local kind: Scenes.BeatKind = Level0.pickBeat(random, previous, Scenes.beatKinds()) :: Scenes.BeatKind
			t.truthy(kind ~= nil, "a beat")
			t.truthy(kind ~= previous, "never the same twice")
			seen[kind] = true
			previous = kind
		end
		for _, kind: Scenes.BeatKind in Scenes.beatKinds() do
			t.truthy(seen[kind], kind .. " comes up")
		end
		t.eq(Level0.pickBeat(random, "PipeBang", { "PipeBang" }), nil, "nothing else allowed")
		local a = MathUtil.seededRandom(7, "same")
		local b = MathUtil.seededRandom(7, "same")
		t.eq(Level0.pickBeat(a, nil, Scenes.beatKinds()), Level0.pickBeat(b, nil, Scenes.beatKinds()), "seeded")
		for _ = 1, 50 do
			local delay = Level0.nextDelay(random)
			t.truthy(delay >= 25 and delay <= 50, "25-50 s")
		end
		t.eq(Level0.dueAfterTrap(100, 95), 103, "8 s after a snap")
		t.eq(Level0.dueAfterTrap(100, 80), 100, "an old snap changes nothing")

		local listener = localPoint(L0, 64, 3, 80)
		local eyes = { listener + Vector3.new(0, 1.5, 0) }
		local hidden = function(_a: Vector3, _b: Vector3): boolean
			return false
		end
		local open = function(_a: Vector3, _b: Vector3): boolean
			return true
		end
		for _, kind: Scenes.BeatKind in Scenes.beatKinds() do
			local placement = Level0.place(kind, set, listener, eyes, hidden, random)
			if kind == "BoilerSurge" then
				-- the boilers stand 63+ studs from the west undercroft
				t.eq(placement, nil, "no boiler in the band from here")
				continue
			end
			assert(placement, kind .. " placed")
			local distance = MathUtil.horizontalDistance(placement.from, listener)
			t.truthy(distance >= 25 and distance <= 45, kind .. " in the band")
			if kind == "CeilingDrag" then
				local to = placement.to
				assert(to, "the drag moves")
				t.near(MathUtil.horizontalDistance(to, placement.from), Scenes.CeilingDragDistance, 1e-6, "16 studs")
				t.truthy(MathUtil.horizontalDistance(to, listener) > distance, "away from the listener")
			else
				t.eq(placement.to, nil, kind .. " stays put")
			end
			t.eq(Level0.place(kind, set, listener, eyes, open, random), nil, kind .. ": never where anyone can see")
		end
		local boiler = set.boilers[1]
		t.truthy(
			Level0.place("BoilerSurge", set, boiler + Vector3.new(30, 0, 0), {}, hidden, random) ~= nil,
			"a surge near one"
		)

		local fixtures: { Level0.LitFixture } = {}
		for index = 1, 6 do
			table.insert(fixtures, { id = "F" .. index, position = Vector3.new(index * 6, 0, 0) })
		end
		local lights = Level0.surgeLights(Vector3.zero, fixtures)
		t.eq(#lights, Scenes.SurgeLights, "at most four")
		t.eq(table.concat(lights, ","), "F1,F2,F3,F4", "nearest first")
		t.eq(#Level0.surgeLights(Vector3.new(500, 0, 0), fixtures), 0, "nothing out of reach")
	end,

	["Level 0: beats play every 25-50 s, never repeat, wait out a TrapSnap and make the fall heard"] = function(
		t: Expect
	)
		local now = 500
		local shots: { Shot } = {}
		local noises: { { position: Vector3, kind: Enums.NoiseKind, at: number } } = {}
		local player = newPlayer(9201, "Listener")
		local root = localPoint(L0, 140, 3, 70)
		local deps: Level0.Dependencies = {
			now = function(): number
				return now
			end,
			players = function(): { Player }
				return { player }
			end,
			rootOf = function(_p: Player): Vector3?
				return root
			end,
			eyeOf = function(_p: Player): Vector3?
				return root + Vector3.new(0, 1.5, 0)
			end,
			lineClear = function(_a: Vector3, _b: Vector3): boolean
				return false
			end,
			lights = function(): { Level0.LitFixture }
				return { { id = "L0_Bulb", position = localPoint(L0, 150, 10, 95) } }
			end,
			oneShot = function(
				kind: Enums.OneShotKind,
				startAt: number,
				args: { [string]: Types.OneShotArg },
				subject: Instance?
			)
				table.insert(shots, { kind = kind, startAt = startAt, args = args, subject = subject, at = now })
			end,
			emit = function(position: Vector3, kind: Enums.NoiseKind)
				table.insert(noises, { position = position, kind = kind, at = now })
			end,
		}
		Level0.SetDependencies(deps)
		Level0.BeginRun(runContext(SEED))
		Level0.Activate(levelContext(L0, SEED))
		local ok, err = pcall(function()
			local first = Level0.GetNextAt()
			t.truthy(first >= now + 25 and first <= now + 50, "the first beat 25-50 s in")
			local timelines = Scenes.timelines()
			local kinds: { string } = {}
			local times: { number } = {}
			local trapNoted = false
			while #shots < 24 and now < 5000 do
				now += 0.1
				if not trapNoted and #shots == 3 then
					-- a trap snaps two seconds before the next beat is due
					trapNoted = true
					local due = Level0.GetNextAt()
					Level0.NoteTrapSnap(due - 2)
					local before = #shots
					now = due - 0.05
					while now < due + 5.9 do
						now += 0.1
						Level0.Step(now)
					end
					t.eq(#shots, before, "nothing within 8 s of the snap")
				end
				Level0.Step(now)
				if #shots > #kinds then
					local shot = shots[#shots]
					t.eq(shot.kind, "Timeline")
					local id = shot.args.id :: string
					t.truthy(timelines[id] ~= nil, "a scene timeline: " .. id)
					t.near(shot.startAt, now + LEAD, 1e-6, "startAt = now + lead")
					table.insert(kinds, tostring(Level0.GetPrevious()))
					table.insert(times, now)
					if Level0.GetPrevious() == "BoilerSurge" then
						t.eq(shot.args.light1, "L0_Bulb", "the bulb by the boiler stutters")
					end
				end
			end
			t.eq(#shots, 24, "beats keep coming")
			now += 1
			Level0.Step(now)
			for index = 2, #kinds do
				t.truthy(kinds[index] ~= kinds[index - 1], "never the same beat twice in a row")
				local gap = times[index] - times[index - 1]
				t.truthy(gap >= 25 - 1e-6 and gap <= 50 + 8 + 0.2, "25-50 s apart (plus a trap's wait)")
			end
			local falls = 0
			for _, noise in noises do
				t.eq(noise.kind, "FallingObject", "only the fall makes noise")
				falls += 1
			end
			local fallBeats = 0
			for _, kind in kinds do
				if kind == "FallingObject" then
					fallBeats += 1
				end
			end
			t.eq(falls, fallBeats, "every fall is heard")
			Level0.Deactivate()
			local count = #shots
			now += 200
			Level0.Step(now)
			t.eq(#shots, count, "quiet once the squad has left")
		end)
		Level0.EndRun()
		Level0.SetDependencies(nil)
		if not ok then
			error(err, 0)
		end
	end,

	["Level 2: flasks are restocked out of sight, at most one per 45 s, and the hint shows once"] = function(t: Expect)
		t.truthy(Level2.restockDue(100, -math.huge, 1), "below two: restock")
		t.falsy(Level2.restockDue(100, -math.huge, 2), "two in play is enough")
		t.falsy(Level2.restockDue(100, 70, 0), "not within 45 s of the last")
		t.truthy(Level2.restockDue(115, 70, 0), "45 s later")

		local random = MathUtil.seededRandom(SEED, "spec2")
		local spots = { CFrame.new(0, 3, 0), CFrame.new(100, 3, 0), CFrame.new(200, 3, 0) }
		local never = function(_p: Vector3): boolean
			return false
		end
		local picked = Level2.pickSpot(spots, { Vector3.new(100, 3, 0) }, { Vector3.new(5, 3, 0) }, never, random)
		assert(picked, "a spot")
		t.truthy(picked.Position == Vector3.new(200, 3, 0), "free, and more than 30 studs from everyone")
		t.eq(
			Level2.pickSpot(spots, {}, {}, function(_p: Vector3): boolean
				return true
			end, random),
			nil,
			"never where anyone can see"
		)
		t.truthy(Level2.hintDue({ Vector3.new(0, 3, 0) }, { Vector3.new(6, 3, 6) }), "within 10 studs")
		t.falsy(Level2.hintDue({ Vector3.new(0, 3, 0) }, { Vector3.new(20, 3, 0) }), "too far")

		local layout = Builder.getLayout(L2)
		assert(layout, "Level 2 layout")
		local candidates: { Vector3 } = {}
		for _, anchor in layout.anchors do
			if anchor.kind == "FlaskCandidate" then
				table.insert(candidates, Builder.anchorCFrame(L2, anchor).Position)
			end
		end
		t.truthy(#candidates >= 4, "lab counter spots")
		local now = 800
		local available = 1
		local flasks: { Vector3 } = {}
		local spawned: { { cframe: CFrame, variant: number, at: number } } = {}
		local notified: { { player: Player, key: string } } = {}
		local player = newPlayer(9301, "Chemist")
		local root = candidates[1] + Vector3.new(0, 0, 0.5)
		local deps: Level2.Dependencies = {
			now = function(): number
				return now
			end,
			players = function(): { Player }
				return { player }
			end,
			rootOf = function(_p: Player): Vector3?
				return root
			end,
			eyeOf = function(_p: Player): Vector3?
				return root + Vector3.new(0, 1.5, 0)
			end,
			lineClear = function(_a: Vector3, _b: Vector3): boolean
				return false
			end,
			countAvailable = function(levelId: Enums.LevelId): number
				t.eq(levelId, L2)
				return available
			end,
			spawnFlask = function(levelId: Enums.LevelId, cframe: CFrame, variant: number): Model?
				t.eq(levelId, L2)
				table.insert(spawned, { cframe = cframe, variant = variant, at = now })
				return Instance.new("Model")
			end,
			flasks = function(): { Vector3 }
				return flasks
			end,
			notify = function(p: Player, key: string)
				table.insert(notified, { player = p, key = key })
			end,
		}
		Level2.SetDependencies(deps)
		Level2.BeginRun(runContext(SEED))
		Level2.Activate(levelContext(L2, SEED))
		local ok, err = pcall(function()
			Level2.Step(now)
			t.eq(#spawned, 1, "one flask at once")
			local first = spawned[1]
			t.truthy((first.cframe.Position - root).Magnitude > Level2.MinDistance, "far from the player")
			t.truthy(first.variant >= 1, "a look")
			-- still short (it was picked up): nothing until 45 s have passed
			for _ = 1, 40 do
				now += 1
				Level2.Step(now)
			end
			t.eq(#spawned, 1, "at most one per 45 s")
			for _ = 1, 6 do
				now += 1
				Level2.Step(now)
			end
			t.eq(#spawned, 2, "the next after 45 s")
			t.truthy(spawned[2].at - spawned[1].at >= Level2.Interval, "spaced")
			available = 2
			for _ = 1, 60 do
				now += 1
				Level2.Step(now)
			end
			t.eq(#spawned, 2, "two in play: no more")

			t.eq(#notified, 0, "no hint yet")
			flasks = { root + Vector3.new(4, 0, 4) }
			now += 0.2
			Level2.Step(now)
			t.eq(#notified, 1, "the hint")
			t.eq(notified[1].key, Level2.HintKey)
			t.eq(notified[1].player, player)
			for _ = 1, 20 do
				now += 0.2
				Level2.Step(now)
			end
			t.eq(#notified, 1, "once per run")
			t.truthy(Level2.HasHinted())
		end)
		Level2.EndRun()
		Level2.SetDependencies(nil)
		if not ok then
			error(err, 0)
		end
	end,
}
