--!strict
-- Lockers. LockerMotion (schedules, the lungs, the calm threshold, the fairness margin), LockerHidingService's pure
-- rules (canHide, canExit, the judge's verdict table, exit spots, peek length) and the whole service on a fake clock
-- with every dependency injected and a real built locker: climbing in (lock, override, torch off, the door's open /
-- shut motions and poses, the body moved inside, settled, RunStats), teammates refused, the chased refused, every
-- breath-check outcome (held through, a late start, a calm breath and a re-hold, a gasp on release, running out, the
-- Creature walking off), the gasp as noise and sound, the catch's hand-over (the rip, the locks released, the locker
-- smashed for good, the victim put down outside afterwards), a catch that did not take, an empty peek, the lungs
-- giving out with nobody at the door, getting out (refused under a check or with every spot blocked) and the release.
-- Then LockerController's pure camera / prompt maths.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local AudioService = require(ServerScriptService.Services.Core.AudioService)
local DoorMotion = require(ReplicatedStorage.Shared.Sequence.DoorMotion)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LockerMotion = require(ReplicatedStorage.Shared.Sequence.LockerMotion)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Strings = require(ReplicatedStorage.Shared.Strings)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local Types = require(ReplicatedStorage.Shared.Types)

local LockerBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.LockerBuilder)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)

local LockerHidingService = require(ServerScriptService.Services.Mechanics.LockerHidingService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

local LockerController = require(StarterPlayer.StarterPlayerScripts.Controllers.Gameplay.LockerController)

type Expect = SpecRunner.Expect

type Call = { name: string, at: number, value: any }

type Shot = { kind: Enums.OneShotKind, startAt: number, args: { [string]: Types.OneShotArg }, subject: Instance? }

type Cue = { player: Player, payload: Types.PrivateCuePayload }

type World = {
	now: number,
	calls: { Call },
	shots: { Shot },
	cues: { Cue },
	notes: { string },
	sounds: { string },
	noises: { { kind: Enums.NoiseKind, source: Player? } },
	life: Enums.LifeState,
	move: Enums.MoveState,
	body: CFrame?,
	clear: boolean,
	state: Enums.MonsterState,
	creature: Vector3?,
	chaser: Player?,
	victim: Player?,
	model: Model,
	player: Player,
}

local W = Attributes.World
local LEAD = GameConfig.OneShotLead
local STEP = 0.02
local ROOT_HEIGHT = 3
local GYM: Enums.LevelId = "Level3_Gymnasium"

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local nextUserId = 7300

local function newPlayer(): Player
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "LockerSpec" .. nextUserId
	local writable = player :: any
	writable.UserId = nextUserId
	return player
end

local function buildLocker(): Model
	local folder = Instance.new("Folder")
	folder.Name = "SpecLockers"
	return LockerBuilder.buildLocker(folder, {
		cframe = CFrame.new(40, 0, 40),
		anchorId = "Spec_Locker_01",
		levelId = GYM,
		zoneId = "L3_LockerRoom_Boys",
		number = 1,
		wallGap = nil,
		paint = Color3.fromRGB(58, 86, 84),
	}, Random.new(3))
end

local function anchor(model: Model, name: string): CFrame
	local found = PropKit.findAttachment(model, name)
	assert(found, model.Name .. " has " .. name)
	return PropKit.attachmentWorld(found)
end

local function record(world: World, name: string, value: any)
	table.insert(world.calls, { name = name, at = world.now, value = value })
end

local function count(world: World, name: string): number
	local total = 0
	for _, call in world.calls do
		if call.name == name then
			total += 1
		end
	end
	return total
end

local function lastCall(world: World, name: string): Call?
	for index = #world.calls, 1, -1 do
		if world.calls[index].name == name then
			return world.calls[index]
		end
	end
	return nil
end

local function shotsOf(world: World, phase: string): { Shot }
	local out: { Shot } = {}
	for _, shot in world.shots do
		if shot.args[LockerMotion.Args.Phase] == phase then
			table.insert(out, shot)
		end
	end
	return out
end

local function cuesOf(world: World, phase: string): { Types.PrivateCuePayload }
	local out: { Types.PrivateCuePayload } = {}
	for _, cue in world.cues do
		if cue.payload.args[LockerMotion.CueArgs.Phase] == phase then
			table.insert(out, cue.payload)
		end
	end
	return out
end

local function played(world: World, preset: string): number
	local total = 0
	for _, name in world.sounds do
		if name == preset then
			total += 1
		end
	end
	return total
end

local function doorAngle(model: Model): number
	local transform = PropKit.leafTransform(model, LockerBuilder.DoorLeaf)
	assert(transform, "door leaf")
	local _, angle = transform:ToAxisAngle()
	return math.abs(MathUtil.wrapAngle(angle))
end

local function advance(world: World, to: number)
	while world.now < to - 1e-9 do
		world.now = math.min(to, world.now + STEP)
		LockerHidingService.Step(world.now)
	end
end

local function install(world: World)
	LockerHidingService.SetDependencies({
		now = function(): number
			return world.now
		end,
		teleport = function(player: Player, cframe: CFrame): boolean
			record(world, "Teleport", cframe)
			if player == world.player then
				world.body = cframe
			end
			return true
		end,
		lock = function(player: Player)
			record(world, "Lock", player)
		end,
		unlock = function(player: Player)
			record(world, "Unlock", player)
		end,
		pushOverride = function(player: Player)
			record(world, "PushOverride", player)
		end,
		popOverride = function(player: Player)
			record(world, "PopOverride", player)
		end,
		lifeState = function(_player: Player): Enums.LifeState
			return world.life
		end,
		moveState = function(_player: Player): Enums.MoveState
			return world.move
		end,
		controlLock = function(_player: Player): Enums.ControlLock
			return "None"
		end,
		body = function(_player: Player): (CFrame?, number)
			return world.body, ROOT_HEIGHT
		end,
		clear = function(_cframe: CFrame, _locker: Model): boolean
			return world.clear
		end,
		oneShot = function(kind: Enums.OneShotKind, startAt: number, args: { [string]: Types.OneShotArg }, subject)
			table.insert(world.shots, { kind = kind, startAt = startAt, args = args, subject = subject })
		end,
		cue = function(player: Player, payload: Types.PrivateCuePayload)
			table.insert(world.cues, { player = player, payload = payload })
		end,
		notify = function(_player: Player, key: string)
			table.insert(world.notes, key)
		end,
		playAt = function(
			preset: string,
			_position: Vector3,
			_options: AudioService.CueOptions?
		): AudioService.CueHandle?
			table.insert(world.sounds, preset)
			local stopped = false
			local handle: AudioService.CueHandle = {
				id = #world.sounds,
				preset = preset,
				looped = SynthPresets.isLooped(preset),
				Stop = function(_self: AudioService.CueHandle, _fade: number?)
					stopped = true
					record(world, "StopSound", preset)
				end,
				IsActive = function(_self: AudioService.CueHandle): boolean
					return not stopped
				end,
			}
			return handle
		end,
		emit = function(_position: Vector3, kind: Enums.NoiseKind, source: Player?, _levelId: string?)
			table.insert(world.noises, { kind = kind, source = source })
		end,
		monsterState = function(): Enums.MonsterState
			return world.state
		end,
		creatureAt = function(): Vector3?
			return world.creature
		end,
		chaser = function(): Player?
			return world.chaser
		end,
		victim = function(): Player?
			return world.victim
		end,
		stat = function(player: Player, key: Enums.StatKey)
			record(world, "Stat", { player = player, key = key })
		end,
		refresh = function(host: Instance)
			record(world, "Refresh", host)
		end,
		torchOff = function(player: Player)
			record(world, "TorchOff", player)
		end,
	})
end

-- Runs `body` with a tracked locker and a player standing in front of it, on a fake clock; always tears down.
local function withLocker(body: (world: World) -> ())
	local model = buildLocker()
	local player = newPlayer()
	local exit = anchor(model, "ExitAnchor")
	local world: World = {
		now = 10,
		calls = {},
		shots = {},
		cues = {},
		notes = {},
		sounds = {},
		noises = {},
		life = "Alive",
		move = "Standing",
		body = exit * CFrame.new(0, ROOT_HEIGHT, 0),
		clear = true,
		state = "Patrol",
		creature = nil,
		chaser = nil,
		victim = nil,
		model = model,
		player = player,
	}
	install(world)
	LockerHidingService.BeginRun({
		runId = "locker-spec",
		seed = 99,
		difficulty = "Standard",
		participants = { player },
		startedAt = 0,
	})
	local failure: string? = nil
	xpcall(function()
		assert(LockerHidingService.Track(model), "the built locker is tracked")
		body(world)
	end, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end)
	LockerHidingService.EndRun()
	LockerHidingService.SetDependencies(nil)
	model:Destroy()
	if failure ~= nil then
		error(failure, 0)
	end
end

-- Hides the world's player and lets the door shut behind them.
local function hideAndSettle(world: World)
	assert(LockerHidingService.Hide(world.player, world.model), "hidden")
	advance(world, world.now + LockerMotion.OpenSeconds + LockerMotion.StepInSeconds + LockerMotion.CloseSeconds + 0.5)
	assert(LockerHidingService.GetState(world.model) == "Hidden", "settled")
end

-- The Creature at the door, peeking: Inspect runs in its own thread the way InvestigateNoise calls it. When the
-- verdict is Caught and `catches`, the thread "takes" the occupant (the fake JumpscareHandler victim) the way
-- tryCatch would, before the service looks.
local function peek(world: World, catches: boolean): { verdict: Types.LockerVerdict? }
	world.state = "InvestigateNoise"
	world.creature = anchor(world.model, "ExitAnchor").Position
	local out: { verdict: Types.LockerVerdict? } = { verdict = nil }
	local thread = coroutine.create(function()
		local verdict: Types.LockerVerdict = LockerHidingService.Inspect(world.model)
		out.verdict = verdict
		if verdict == "Caught" and catches then
			world.victim = world.player
		end
	end)
	local ok, err = coroutine.resume(thread)
	assert(ok, tostring(err))
	return out
end

local function resultOf(world: World): (string?, string?)
	local results = cuesOf(world, LockerMotion.CuePhases.Result)
	local last = results[#results]
	if not last then
		return nil, nil
	end
	local verdict = last.args[LockerMotion.CueArgs.Verdict]
	local reason = last.args[LockerMotion.CueArgs.Reason]
	return if type(verdict) == "string" then verdict else nil, if type(reason) == "string" then reason else nil
end

local function windowOf(world: World): Types.PrivateCuePayload
	local windows = cuesOf(world, LockerMotion.CuePhases.Window)
	local window = windows[#windows]
	assert(window, "a Window cue")
	return window
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["LockerMotion: schedules in order, the lungs drain and recover exactly, the peek always fits one breath"] = function(
		t: Expect
	)
		local enter = LockerMotion.enterSchedule(5)
		t.eq(enter.openAt, 5)
		t.near(enter.moveAt, 5 + LockerMotion.OpenSeconds, 1e-9)
		t.near(enter.closeAt, enter.moveAt + LockerMotion.StepInSeconds, 1e-9)
		t.near(enter.settledAt, enter.closeAt + LockerMotion.CloseSeconds, 1e-9)
		local exit = LockerMotion.exitSchedule(5)
		t.near(exit.closeAt, exit.moveAt + LockerMotion.StepOutSeconds, 1e-9)

		local full = LockerMotion.fullBreath(0)
		t.eq(full.value, GameConfig.BreathHoldMaxSeconds, "full lungs = the longest hold")
		local holding = LockerMotion.setHeld(full, true, 1)
		t.eq(LockerMotion.setHeld(holding, true, 3), holding, "the same hold keeps its record")
		t.near(LockerMotion.breathAt(holding, 3), GameConfig.BreathHoldMaxSeconds - 2, 1e-9, "one second per second")
		t.near(LockerMotion.emptyAt(holding) :: number, 1 + GameConfig.BreathHoldMaxSeconds, 1e-9)
		t.eq(LockerMotion.breathAt(holding, 100), 0, "never below empty")
		local breathing = LockerMotion.setHeld(holding, false, 5)
		t.near(breathing.value, GameConfig.BreathHoldMaxSeconds - 4, 1e-9, "the value at the release")
		t.eq(LockerMotion.emptyAt(breathing), nil)
		t.near(LockerMotion.breathAt(breathing, 6), 3 + GameConfig.BreathRecoverPerSecond, 1e-9, "recovers")
		t.eq(LockerMotion.breathAt(breathing, 1000), GameConfig.BreathHoldMaxSeconds, "never above full")

		t.truthy(LockerMotion.calm(LockerMotion.CalmFraction * LockerMotion.BreathMax), "the threshold itself is calm")
		t.falsy(LockerMotion.calm(LockerMotion.CalmFraction * LockerMotion.BreathMax - 0.01))
		t.truthy(
			LockerMotion.WarnSeconds + LockerMotion.PeekMax < GameConfig.BreathHoldMaxSeconds,
			"holding from the warning outlasts the longest peek"
		)
		t.truthy(LockerMotion.EmptyPeekSeconds < LockerMotion.PeekMin)
	end,

	["judge: every outcome of a breath check"] = function(t: Expect)
		local function view(breath: LockerMotion.Breath): LockerHidingService.CheckView
			return { startedAt = 10, windowStart = 11, windowEnd = 15, breath = breath }
		end
		local grace = LockerMotion.ReholdGrace
		type Row = {
			breath: LockerMotion.Breath,
			now: number,
			verdict: Types.LockerVerdict?,
			reason: string?,
			at: number?,
		}
		local rows: { Row } = {
			-- warned but not at the slits yet: nothing to judge
			{ breath = { value = 7, held = false, at = 0 }, now = 10.9, verdict = nil },
			-- holding from the warning through the window
			{ breath = { value = 6.8, held = true, at = 10.2 }, now = 14, verdict = nil },
			{
				breath = { value = 6.8, held = true, at = 10.2 },
				now = 15,
				verdict = "HiddenSafe",
				reason = "Held",
				at = 15,
			},
			-- never held: heard once the grace is over
			{ breath = { value = 7, held = false, at = 0 }, now = 11 + grace - 0.01, verdict = nil },
			{
				breath = { value = 7, held = false, at = 0 },
				now = 12,
				verdict = "Caught",
				reason = "Breathing",
				at = 11 + grace,
			},
			-- a quiet breath inside the window, held again in time
			{ breath = { value = 4, held = true, at = 12.4 }, now = 13, verdict = nil },
			-- a quiet breath held too long
			{
				breath = { value = 4, held = false, at = 12 },
				now = 13,
				verdict = "Caught",
				reason = "Breathing",
				at = 12 + grace,
			},
			-- letting go with too little left: a gasp at the release
			{ breath = { value = 1, held = false, at = 12 }, now = 12, verdict = "Caught", reason = "Gasp", at = 12 },
			-- a low release before the window is no gasp (it is not at the slits yet), but the window still needs a hold
			{ breath = { value = 1, held = false, at = 10.5 }, now = 11.2, verdict = nil },
			-- running out while it is at the door (warned or peeking)
			{
				breath = { value = 3, held = true, at = 8 },
				now = 11.5,
				verdict = "Caught",
				reason = "OutOfBreath",
				at = 11,
			},
			{
				breath = { value = 2.5, held = true, at = 8 },
				now = 10.7,
				verdict = "Caught",
				reason = "OutOfBreath",
				at = 10.5,
			},
			-- running out after the window closed is safe
			{
				breath = { value = 6, held = true, at = 10 },
				now = 16.5,
				verdict = "HiddenSafe",
				reason = "Held",
				at = 15,
			},
			-- the grace reaching past the end of the window: safe
			{
				breath = { value = 5, held = false, at = 14.8 },
				now = 15.4,
				verdict = "HiddenSafe",
				reason = "Held",
				at = 15,
			},
		}
		for index, row in rows do
			local verdict, reason, at = LockerHidingService.judge(view(row.breath), row.now)
			t.eq(verdict, row.verdict, "row " .. index .. " verdict")
			t.eq(reason, row.reason, "row " .. index .. " reason")
			if row.at then
				t.near(at :: number, row.at, 1e-9, "row " .. index .. " decided at")
			end
		end
	end,

	["canHide / canExit, exit spots, the peek's length"] = function(t: Expect)
		local function check(overrides: { [string]: any }): LockerHidingService.HideCheck
			local base: { [string]: any } = {
				live = true,
				lifeState = "Alive",
				hasBody = true,
				controlLock = "None",
				moveState = "Standing",
				hiding = false,
				lockerState = "Free",
				chasedBy = false,
			}
			for key, value in overrides do
				base[key] = value
			end
			return (base :: any) :: LockerHidingService.HideCheck
		end
		t.truthy((LockerHidingService.canHide(check({}))))
		t.truthy((LockerHidingService.canHide(check({ moveState = "Crouching" }))))
		t.truthy((LockerHidingService.canHide(check({ moveState = "Sprinting" }))))
		local refusals: { { overrides: { [string]: any }, reason: string } } = {
			{ overrides = { live = false }, reason = "NotLive" },
			{ overrides = { lifeState = "Downed" }, reason = "LifeState" },
			{ overrides = { hasBody = false }, reason = "NoBody" },
			{ overrides = { hiding = true }, reason = "Hiding" },
			{ overrides = { lockerState = "Hidden" }, reason = LockerHidingService.OccupiedHint },
			{ overrides = { lockerState = "Entering" }, reason = LockerHidingService.OccupiedHint },
			{ overrides = { lockerState = "Smashed" }, reason = LockerHidingService.OccupiedHint },
			{ overrides = { controlLock = "Trap" }, reason = "Locked" },
			{ overrides = { moveState = "VentCrawling" }, reason = "Posture" },
			{ overrides = { moveState = "Treading" }, reason = "Posture" },
			{ overrides = { chasedBy = true }, reason = LockerHidingService.SeenHint },
		}
		for _, row in refusals do
			local ok, reason = LockerHidingService.canHide(check(row.overrides))
			t.falsy(ok, row.reason)
			t.eq(reason, row.reason)
		end
		for _, key in
			{ LockerHidingService.OccupiedHint, LockerHidingService.SeenHint, LockerHidingService.BlockedHint }
		do
			t.truthy(Strings.has(key), key .. " is a Strings key")
		end

		local exitOk = {
			lockerState = "Hidden" :: LockerHidingService.LockerState,
			occupant = true,
			checking = false,
			spotFound = true,
		}
		t.truthy((LockerHidingService.canExit(exitOk)))
		t.eq(
			select(
				2,
				LockerHidingService.canExit({
					lockerState = "Hidden",
					occupant = false,
					checking = false,
					spotFound = true,
				})
			),
			"NotOccupant"
		)
		t.eq(
			select(
				2,
				LockerHidingService.canExit({
					lockerState = "Entering",
					occupant = true,
					checking = false,
					spotFound = true,
				})
			),
			"Moving"
		)
		t.eq(
			select(
				2,
				LockerHidingService.canExit({
					lockerState = "Hidden",
					occupant = true,
					checking = true,
					spotFound = true,
				})
			),
			"Checking"
		)
		t.eq(
			select(
				2,
				LockerHidingService.canExit({
					lockerState = "Hidden",
					occupant = true,
					checking = false,
					spotFound = false,
				})
			),
			LockerHidingService.BlockedHint
		)

		local exitAnchor = CFrame.new(5, 0, 5) * CFrame.Angles(0, math.rad(90), 0)
		local spots = LockerHidingService.exitCandidates(exitAnchor)
		t.eq(#spots, 4)
		t.truthy(spots[1] == exitAnchor, "the anchor first")
		t.near((spots[2].Position - exitAnchor.Position).Magnitude, LockerHidingService.ExitSide, 1e-6, "a step aside")
		t.near(
			(spots[4].Position - exitAnchor.Position):Dot(exitAnchor.LookVector),
			LockerHidingService.ExitFurther,
			1e-6
		)
		for _, spot in spots do
			t.truthy(spot.LookVector:Dot(exitAnchor.LookVector) > 0.999, "facing away from the locker")
		end
		local root = LockerHidingService.rootCFrameAt(exitAnchor, 3)
		t.near(root.Position.Y, 3, 1e-6)

		local source = Random.new(5)
		for _ = 1, 200 do
			local seconds = LockerHidingService.peekSeconds(source)
			t.truthy(seconds >= LockerMotion.PeekMin and seconds <= LockerMotion.PeekMax, "3.5-6 s")
		end
		t.eq(LockerHidingService.peekSeconds(Random.new(9)), LockerHidingService.peekSeconds(Random.new(9)), "seeded")
		for _, preset in { "LockerDoor", "LockerRip", "CreatureSniff", "Gasp", "BreathExhale" } do
			t.truthy(SynthPresets.has(preset), preset)
		end
	end,

	["climbing in: locked, overridden, the door opens, the body goes in, the door shuts, settled"] = function(
		t: Expect
	)
		withLocker(function(world: World)
			local model = world.model
			local hide = anchor(model, "HideAnchor")
			t.eq(LockerHidingService.GetState(model), "Free")
			t.eq(model:GetAttribute(W.DoorOpen), false)
			local handler = LockerHidingService.HideHandler
			local filter = handler.filter
			assert(filter, "filter")
			t.truthy(filter(model, Instance.new("ProximityPrompt")), "serves a free locker")

			local started = world.now
			t.truthy(LockerHidingService.Hide(world.player, model))
			t.eq(model:GetAttribute(W.OccupantUserId), world.player.UserId, "OccupantUserId")
			t.eq(model:GetAttribute(W.DoorOpen), true, "DoorOpen from the start of the opening")
			t.eq(count(world, "Lock"), 1, "Anchor lock")
			t.eq(count(world, "PushOverride"), 1, "Hiding override")
			t.eq(count(world, "TorchOff"), 1, "torch off")
			t.eq(LockerHidingService.GetLockerOf(world.player), model)
			local enter = shotsOf(world, "Enter")[1]
			assert(enter, "an Enter door motion")
			t.eq(enter.kind, "Door")
			t.eq(enter.subject, model)
			t.eq(enter.args[LockerMotion.Args.Occupant], world.player.UserId)
			t.near(enter.startAt, started + LEAD, 1e-9)
			local message = DoorMotion.fromArgs(enter.args, enter.startAt)
			assert(message, "DoorMotion args")
			t.eq(message.motion.mode, "Swing")
			t.eq(message.motion.to, 1)
			t.eq(played(world, "LockerDoor"), 1, "the door's sound")

			local schedule = LockerMotion.enterSchedule(enter.startAt)
			advance(world, schedule.moveAt + 0.01)
			t.near(doorAngle(model), LockerBuilder.DoorOpenAngle, 1e-3, "fully open when the body moves")
			local moved = lastCall(world, "Teleport")
			assert(moved, "moved inside")
			local into = moved.value :: CFrame
			t.truthy(
				(into.Position - (hide.Position + Vector3.new(0, ROOT_HEIGHT, 0))).Magnitude < 1e-4,
				"on the HideAnchor"
			)
			t.truthy(into.LookVector:Dot(hide.LookVector) > 0.999, "facing out through the slits")
			t.eq(LockerHidingService.GetState(model), "Entering")

			advance(world, schedule.settledAt + 0.05)
			t.eq(LockerHidingService.GetState(model), "Hidden")
			t.near(doorAngle(model), 0, 1e-4, "shut")
			t.eq(model:GetAttribute(W.DoorOpen), false, "DoorOpen once the shut landed")
			t.eq(#shotsOf(world, "Shut"), 1, "one shut motion")
			local stat = lastCall(world, "Stat")
			assert(stat, "stat")
			t.eq(stat.value.key, "LockersHidden")
			t.truthy(
				filter(model, Instance.new("ProximityPrompt")),
				"an occupied locker keeps its prompt (refused below)"
			)

			-- a teammate is refused, and so is a second locker for the same player
			local mate = newPlayer()
			local canUse = handler.canUse
			assert(canUse, "canUse")
			local ok, reason = canUse(mate, Instance.new("ProximityPrompt"), model)
			t.falsy(ok)
			t.eq(reason, LockerHidingService.OccupiedHint)
			t.falsy(LockerHidingService.Hide(world.player, model), "already hiding")
		end)
	end,

	["a chased player cannot hide; nor a crawler"] = function(t: Expect)
		withLocker(function(world: World)
			world.chaser = world.player
			t.falsy(LockerHidingService.Hide(world.player, world.model))
			world.chaser = nil
			world.move = "VentCrawling"
			t.falsy(LockerHidingService.Hide(world.player, world.model))
			world.move = "Standing"
			t.truthy(LockerHidingService.Hide(world.player, world.model))
		end)
	end,

	["holding through the peek: HiddenSafe, the Creature's breathing at the slits, no gasp"] = function(t: Expect)
		withLocker(function(world: World)
			hideAndSettle(world)
			local inspectAt = world.now
			local result = peek(world, true)
			t.eq(result.verdict, nil, "the inspector waits")
			t.truthy(LockerHidingService.IsChecking())
			local window = windowOf(world)
			t.near(window.args[LockerMotion.CueArgs.WarnAt] :: number, inspectAt, 1e-9, "warned at once")
			t.near(window.startAt, inspectAt + LockerMotion.WarnSeconds, 1e-9, "the window after the warning")
			local length = (window.endsAt :: number) - window.startAt
			t.truthy(length >= LockerMotion.PeekMin and length <= LockerMotion.PeekMax, "a 3.5-6 s peek")
			t.eq(played(world, "CreatureSniff"), 1, "it breathes at the slits")
			t.falsy(LockerHidingService.RequestExit(world.player), "no leaving while it is at the door")

			advance(world, inspectAt + 0.4)
			t.truthy(LockerHidingService.SetHeld(world.player, true))
			local meters = cuesOf(world, LockerMotion.CuePhases.Meter)
			t.eq(meters[#meters].args[LockerMotion.CueArgs.Held], true, "the server's lungs go to the client")
			advance(world, window.endsAt :: number + 0.05)
			t.eq(result.verdict, "HiddenSafe")
			t.eq((resultOf(world)), "HiddenSafe")
			t.eq(played(world, "Gasp"), 0)
			t.eq(#world.noises, 0)
			t.eq(count(world, "StopSound"), 1, "the breathing at the slits stops")
			t.eq(LockerHidingService.GetState(world.model), "Hidden", "still hidden")
			t.falsy(LockerHidingService.IsChecking())
		end)
	end,

	["a quiet breath held again in time is safe; held too long it is heard"] = function(t: Expect)
		withLocker(function(world: World)
			hideAndSettle(world)
			local start = world.now
			local result = peek(world, false)
			local window = windowOf(world)
			advance(world, start + 0.5)
			LockerHidingService.SetHeld(world.player, true)
			advance(world, window.startAt + 1)
			LockerHidingService.SetHeld(world.player, false) -- plenty left: a quiet breath out
			advance(world, window.startAt + 1 + LockerMotion.ReholdGrace * 0.6)
			LockerHidingService.SetHeld(world.player, true)
			advance(world, window.endsAt :: number + 0.05)
			t.eq(result.verdict, "HiddenSafe", "re-held within the grace")

			advance(world, world.now + 10)
			local second = peek(world, false)
			local again = windowOf(world)
			advance(world, world.now + 0.3)
			LockerHidingService.SetHeld(world.player, true)
			advance(world, again.startAt + 0.8)
			LockerHidingService.SetHeld(world.player, false)
			advance(world, again.startAt + 0.8 + LockerMotion.ReholdGrace + 0.05)
			t.eq(second.verdict, "Caught")
			t.eq(select(2, resultOf(world)), "Breathing")
		end)
	end,

	["never holding: heard after the grace, a gasp and its noise, the catch takes over and rips the door off"] = function(
		t: Expect
	)
		withLocker(function(world: World)
			hideAndSettle(world)
			local result = peek(world, true)
			local window = windowOf(world)
			advance(world, window.startAt + LockerMotion.ReholdGrace + 0.05)
			t.eq(result.verdict, "Caught")
			t.eq(select(2, resultOf(world)), "Breathing")
			t.eq(played(world, "Gasp"), 1, "a loud gasp at the slits")
			t.eq(#world.noises, 1)
			t.eq(world.noises[1].kind, "Gasp")
			t.eq(world.noises[1].source, world.player, "made by the occupant")

			-- the catch took the occupant: torn door, locks released, the locker smashed
			local model = world.model
			t.eq(LockerHidingService.GetState(model), "Smashed")
			t.eq(model:GetAttribute(W.OccupantUserId), nil)
			t.eq(model:GetAttribute(W.DoorOpen), true)
			t.eq(count(world, "Unlock"), 1, "the Locker lock released (the catch holds the body)")
			t.eq(count(world, "PopOverride"), 1, "the Hiding override released")
			t.eq(LockerHidingService.GetLockerOf(world.player), nil)
			local rip = shotsOf(world, "Rip")[1]
			assert(rip, "the rip")
			t.eq(rip.kind, "LockerRip")
			t.eq(rip.subject, model)
			t.eq(played(world, "LockerRip"), 1)
			local filter = LockerHidingService.HideHandler.filter
			assert(filter, "filter")
			t.falsy(filter(model, Instance.new("ProximityPrompt")), "never usable again this run")
			local rest = PropKit.leafTransform(model, LockerBuilder.DoorLeaf) :: CFrame
			advance(world, rip.startAt + LockerMotion.RipSeconds + 0.05)
			local torn = PropKit.leafTransform(model, LockerBuilder.DoorLeaf) :: CFrame
			t.truthy((torn.Position - rest.Position).Magnitude > 1, "the door lies away from its hinge")

			-- the catch ends with the victim downed: put down outside the locker
			world.life = "Downed"
			local before = count(world, "Teleport")
			LockerHidingService.CatchFinished(world.player, "Locker", "Downed")
			t.eq(count(world, "Teleport"), before + 1, "out to the exit spot")
			local out = (lastCall(world, "Teleport") :: Call).value :: CFrame
			local exit = anchor(model, "ExitAnchor")
			t.truthy((out.Position - (exit.Position + Vector3.new(0, ROOT_HEIGHT, 0))).Magnitude < 1e-4)
			LockerHidingService.CatchFinished(world.player, "Locker", "Downed")
			t.eq(count(world, "Teleport"), before + 1, "only once")
		end)
	end,

	["a gasp on release with the lungs nearly spent; running out at the door"] = function(t: Expect)
		withLocker(function(world: World)
			hideAndSettle(world)
			LockerHidingService.SetHeld(world.player, true)
			advance(world, world.now + 4.5) -- held long before it came
			local result = peek(world, false)
			local window = windowOf(world)
			advance(world, window.startAt + 0.2)
			LockerHidingService.SetHeld(world.player, false)
			t.eq(result.verdict, "Caught")
			t.eq(select(2, resultOf(world)), "Gasp")
			t.eq(LockerHidingService.GetState(world.model), "Hidden", "no catch followed: still hidden")
			t.eq(#world.noises, 1, "the gasp is still a noise (it will come back)")

			advance(world, world.now + 12)
			LockerHidingService.SetHeld(world.player, true)
			advance(world, world.now + 5)
			local second = peek(world, false)
			advance(world, world.now + 3)
			t.eq(second.verdict, "Caught")
			t.eq(select(2, resultOf(world)), "OutOfBreath")
		end)
	end,

	["the Creature walking off ends the check safe; an empty locker is Empty after a short peek"] = function(t: Expect)
		withLocker(function(world: World)
			local empty = peek(world, false)
			advance(world, world.now + LockerMotion.EmptyPeekSeconds - 0.1)
			t.eq(empty.verdict, nil, "it looks for a moment")
			advance(world, world.now + 0.2)
			t.eq(empty.verdict, "Empty")
			t.eq(#world.cues, 0, "nobody to cue")

			hideAndSettle(world)
			local result = peek(world, false)
			advance(world, world.now + 0.5)
			world.state = "Stunned"
			advance(world, world.now + 0.05)
			t.eq(result.verdict, "HiddenSafe")
			t.eq(select(2, resultOf(world)), "Left")

			local moved = peek(world, false)
			advance(world, world.now + 0.3)
			world.creature = (world.creature :: Vector3) + Vector3.new(30, 0, 0)
			advance(world, world.now + 0.05)
			t.eq(moved.verdict, "HiddenSafe", "it walked away from the door")
		end)
	end,

	["the lungs give out with nobody at the door: a gasp all the same"] = function(t: Expect)
		withLocker(function(world: World)
			hideAndSettle(world)
			LockerHidingService.SetHeld(world.player, true)
			advance(world, world.now + GameConfig.BreathHoldMaxSeconds + 0.1)
			t.eq(played(world, "Gasp"), 1)
			t.eq(#world.noises, 1)
			t.near(LockerHidingService.GetBreath(world.player) :: number, 0.1 * GameConfig.BreathRecoverPerSecond, 0.05)
		end)
	end,

	["getting out: to a clear spot, the door opens and shuts, the locker is free; blocked is refused"] = function(
		t: Expect
	)
		withLocker(function(world: World)
			hideAndSettle(world)
			world.clear = false
			local ok, reason = LockerHidingService.RequestExit(world.player)
			t.falsy(ok)
			t.eq(reason, LockerHidingService.BlockedHint)
			t.eq(world.notes[#world.notes], LockerHidingService.BlockedHint, "told why")
			world.clear = true
			t.truthy(LockerHidingService.RequestExit(world.player))
			local exitShot = shotsOf(world, "Exit")[1]
			assert(exitShot, "an Exit door motion")
			t.eq(exitShot.args[LockerMotion.Args.Occupant], world.player.UserId)
			local schedule = LockerMotion.exitSchedule(exitShot.startAt)
			advance(world, schedule.moveAt + 0.01)
			local out = (lastCall(world, "Teleport") :: Call).value :: CFrame
			local exit = anchor(world.model, "ExitAnchor")
			t.truthy((out.Position - (exit.Position + Vector3.new(0, ROOT_HEIGHT, 0))).Magnitude < 1e-4, "on the exit")
			t.truthy(out.LookVector:Dot(exit.LookVector) > 0.999, "facing away from the locker")
			t.eq(world.model:GetAttribute(W.OccupantUserId), nil)
			t.eq(count(world, "Unlock"), 1)
			t.eq(count(world, "PopOverride"), 1)
			t.eq(LockerHidingService.GetLockerOf(world.player), nil)
			advance(world, schedule.settledAt + 0.05)
			t.eq(LockerHidingService.GetState(world.model), "Free")
			t.eq(world.model:GetAttribute(W.DoorOpen), false)
			t.near(doorAngle(world.model), 0, 1e-4)
			t.truthy(LockerHidingService.Hide(world.player, world.model), "usable again")
		end)
	end,

	["a release lets the occupant out at once; the run's end lets every inspector go"] = function(t: Expect)
		withLocker(function(world: World)
			hideAndSettle(world)
			t.truthy(LockerHidingService.Release(world.player))
			t.eq(LockerHidingService.GetLockerOf(world.player), nil)
			t.eq(count(world, "Unlock"), 1)
			t.eq(count(world, "PopOverride"), 1)
			t.eq(world.model:GetAttribute(W.OccupantUserId), nil)
			advance(world, world.now + 2)
			t.eq(LockerHidingService.GetState(world.model), "Free")

			hideAndSettle(world)
			local result = peek(world, false)
			LockerHidingService.EndRun()
			t.eq(result.verdict, "Empty", "the waiting inspector is answered")
			t.eq(count(world, "Unlock"), 2, "and the occupant let go")
		end)
	end,

	["LockerController: doors in order, the camera in and out, the prompt's stages"] = function(t: Expect)
		t.truthy(LockerController.accept(nil, 1))
		t.truthy(LockerController.accept(3, 4))
		t.falsy(LockerController.accept(4, 4))
		t.falsy(LockerController.accept(5, 4))

		local out = math.rad(30)
		t.near(LockerController.clampYaw(out + 0.2, out), out + 0.2, 1e-9, "free within the slits")
		t.near(LockerController.clampYaw(out + 2, out), out + LockerController.YawLimit, 1e-9, "clamped")
		t.near(LockerController.clampYaw(out - 2, out), out - LockerController.YawLimit, 1e-9)

		local peekCFrame = CFrame.lookAt(Vector3.new(0, 4.7, 0), Vector3.new(0, 4.7, -10))
		local from = CFrame.lookAt(Vector3.new(0, 4.5, -4), Vector3.new(0, 4.5, 0))
		local schedule = LockerMotion.enterSchedule(10)
		t.truthy(LockerController.enterView(schedule, from, peekCFrame, 9.9) == from, "starts where the eye was")
		local atDoor = LockerController.enterView(schedule, from, peekCFrame, schedule.moveAt)
		t.truthy(atDoor.LookVector:Dot(-peekCFrame.LookVector) > 0.999, "facing in at the door")
		local justAfter = LockerController.enterView(schedule, from, peekCFrame, schedule.moveAt + 1e-4)
		t.truthy((justAfter.Position - atDoor.Position).Magnitude < 0.01, "no jump when it starts backing in")
		t.truthy(justAfter.LookVector:Dot(atDoor.LookVector) > 0.999)
		local settled = LockerController.enterView(schedule, from, peekCFrame, schedule.closeAt)
		t.truthy(settled == peekCFrame, "behind the slits as the door shuts")

		local exitEye = CFrame.lookAt(Vector3.new(0, 4.5, -3.5), Vector3.new(0, 4.5, -10))
		local leaving = LockerMotion.exitSchedule(20)
		t.truthy(LockerController.exitView(leaving, peekCFrame, exitEye, 19) == peekCFrame)
		local outside = LockerController.exitView(leaving, peekCFrame, exitEye, leaving.closeAt)
		t.truthy((outside.Position - exitEye.Position).Magnitude < 1e-4, "out on the exit spot")

		local window: LockerController.Window =
			{ warnAt = 10, startAt = 10.9, endsAt = 15, verdict = nil, resultAt = nil }
		t.eq(LockerController.promptStage(nil, 12), "Idle")
		t.eq(LockerController.promptStage(window, 9), "Idle")
		t.eq(LockerController.promptStage(window, 10.2), "Warn")
		t.eq(LockerController.promptStage(window, 12), "Window")
		t.near(LockerController.ringProgress(window, 10.45), 0.5, 1e-9, "the ring fills toward the window")
		t.near(LockerController.ringProgress(window, 10.9), 1, 1e-9)
		t.near(LockerController.ringProgress(window, 15), 0, 1e-9, "and drains with the peek")
		window.verdict = "HiddenSafe"
		window.resultAt = 15
		t.eq(LockerController.promptStage(window, 15.5), "Result")
		t.eq(LockerController.promptStage(window, 20), "Idle")

		t.truthy(LockerController.meterColor(1) ~= LockerController.meterColor(0.1), "the meter warns")
		t.truthy(LockerController.meterColor(0.2) ~= LockerController.meterColor(0.4))
		t.truthy(LockerController.sway(1.3, false, 1, 0, 1) == CFrame.identity, "MotionScale 0: still")
		local free = LockerController.sway(1.3, false, 1, 1, 1)
		local holding = LockerController.sway(1.3, true, 1, 1, 1)
		local _, freeAngle = free:ToAxisAngle()
		local _, heldAngle = holding:ToAxisAngle()
		t.truthy(math.abs(heldAngle) <= math.abs(freeAngle) + 1e-9, "a held breath steadies the view")
	end,
}
