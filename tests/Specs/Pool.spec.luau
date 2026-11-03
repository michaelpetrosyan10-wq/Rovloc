--!strict
-- The flooded pool (Phase 7). WaterRules (shared by the server and the swimming client): water volumes and the
-- in / out hysteresis, the float height, when a head is under, the oxygen rate, the struggle's sequence numbers, rate
-- cap, decay and break-free. FloodedPoolService's rules (who may be grabbed, the drag's path and its clamps, the Swim
-- validator, splashes, flask reach, the freed swimmer's air) and the live service on a fake clock with injected
-- volumes, locks, support casts, Creature and senders, over the real PlayerStateService / LifeStateService meters:
-- entering and leaving the water (modes, the climb exemption, rising out with nothing underfoot), oxygen draining and
-- recovering and drowning to a Down, splashes, the ducts, the grab (refusals, the lock, the override, the lungful, the
-- cue, the warning to the squad, the drag rig's path), mashing free (rate cap, stale presses, the recoil), the flask
-- and floodlight releases, the Creature letting go, the drowning catch and its fallback, the run ending. CrawlRules'
-- swim entry. SwimController's and StruggleController's maths: membership, the stroke (float, dive, look-led
-- underwater swimming, the ceiling and the floor, the kick, the drag), the climb, the underwater view, the waterline,
-- stroke timing, exhales, the murk, the panic floor; the struggle's start / end, darkness, pull, yanks, shake and
-- reconciliation. (Physics, rendering, input and replication need Studio.)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)
local WaterRules = require(ReplicatedStorage.Shared.Util.WaterRules)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local ChemicalProjectileService = require(ServerScriptService.Services.Mechanics.ChemicalProjectileService)
local CrawlRules = require(ServerScriptService.Services.Vents.VentNetworkService.CrawlRules)
local FloodedPoolService = require(ServerScriptService.Services.Mechanics.FloodedPoolService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

local Gameplay = StarterPlayer.StarterPlayerScripts.Controllers.Gameplay
local StruggleController = require(Gameplay.StruggleController)
local SwimController = require(Gameplay.SwimController)

type Expect = SpecRunner.Expect
type Volume = WaterRules.Volume
type Timer = { at: number, callback: () -> (), thread: thread, cancelled: boolean }

type FakeClock = {
	clock: PlayerStateService.Clock,
	advance: (seconds: number) -> (),
	now: () -> number,
}

type FakeRig = { targets: { Vector3 }, destroyed: boolean }

type World = {
	clock: FakeClock,
	live: boolean,
	volumes: { Volume },
	inVent: { [Player]: boolean },
	supported: boolean,
	locks: { [Player]: { string } },
	lockModes: { string },
	exempts: { { player: Player, token: string, seconds: number } },
	creature: BasePart?,
	holds: boolean,
	stuns: { { seconds: number, from: Vector3 } },
	catchResult: boolean,
	catches: { Player },
	rigs: { FakeRig },
	cues: { { player: Player, payload: Types.PrivateCuePayload } },
	notices: { { player: Player, key: string, args: { string } } },
	noises: { { position: Vector3, kind: Enums.NoiseKind, player: Player } },
	sounds: { { preset: string, position: Vector3, except: Player? } },
	loops: { string },
	stings: { Player },
	players: { Player },
}

local P = Attributes.Player
local SURFACE = -1
local POOL = WaterRules.volumeOf("Spec_Pool", CFrame.new(0, -5.5, 0), Vector3.new(40, 9, 40), false, nil)
local DUCT = WaterRules.volumeOf("Spec_Duct", CFrame.new(0, -1.875, 30), Vector3.new(20, 1.75, 4), true, nil)
local HIP_HEIGHT = 2
local ROOT_SIZE = Vector3.new(2, 2, 1)
local TREAD_ROOT = WaterRules.floatRootY(SURFACE, "Treading")

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- A clock whose time only moves when the spec advances it; due callbacks run in time order.
local function fakeClock(start: number): FakeClock
	local now = start
	local timers: { Timer } = {}
	local clock: PlayerStateService.Clock = {
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
			local nextIndex: number? = nil
			for index, timer in timers do
				if timer.cancelled or timer.at > target then
					continue
				end
				if nextIndex == nil or timer.at < timers[nextIndex].at then
					nextIndex = index
				end
			end
			if nextIndex == nil then
				break
			end
			local timer = table.remove(timers, nextIndex)
			if timer then
				now = math.max(now, timer.at)
				timer.callback()
			end
		end
		now = target
	end
	return {
		clock = clock,
		advance = advance,
		now = function(): number
			return now
		end,
	}
end

local nextUserId = 9700

local function fakePlayer(at: Vector3): (Player, BasePart)
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "PoolSpec" .. nextUserId
	local writable = player :: any
	writable.UserId = nextUserId
	writable.DisplayName = "Swimmer" .. nextUserId
	local model = Instance.new("Model")
	model.Name = player.Name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = ROOT_SIZE
	root.CFrame = CFrame.new(at)
	-- Position is written too: the engine derives it from CFrame, the Lune harness does not (LifeStateService's
	-- downed gasp reads it).
	root.Position = at
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
	return player, root
end

local function place(root: BasePart, at: Vector3)
	root.CFrame = CFrame.new(at)
	root.Position = at
end

local function lockOf(world: World, player: Player): Enums.ControlLock
	local held = world.locks[player]
	if held and #held > 0 then
		return (held[#held] :: any) :: Enums.ControlLock
	end
	return "None"
end

local function cuesOf(world: World, phase: string): { Types.PrivateCuePayload }
	local out: { Types.PrivateCuePayload } = {}
	for _, entry in world.cues do
		if entry.payload.args.phase == phase then
			table.insert(out, entry.payload)
		end
	end
	return out
end

-- Runs `body` with `players` in a live run on a fake clock with every FloodedPoolService dependency faked (see
-- World), and always tears it down.
local function inPool(players: { Player }, body: (world: World) -> ())
	Net.Server.setup()
	LifeStateService.Init()
	FloodedPoolService.Init()
	local clock = fakeClock(5000)
	PlayerStateService.SetClock(clock.clock)
	LifeStateService.SetClock(clock.clock)
	local world: World = {
		clock = clock,
		live = true,
		volumes = { POOL, DUCT },
		inVent = {},
		supported = false,
		locks = {},
		lockModes = {},
		exempts = {},
		creature = nil,
		holds = true,
		stuns = {},
		catchResult = true,
		catches = {},
		rigs = {},
		cues = {},
		notices = {},
		noises = {},
		sounds = {},
		loops = {},
		stings = {},
		players = players,
	}
	FloodedPoolService.SetDependencies({
		now = clock.now,
		delay = clock.clock.delay,
		cancel = clock.clock.cancel,
		live = function(): boolean
			return world.live
		end,
		players = function(): { Player }
			return world.players
		end,
		rootOf = function(player: Player): BasePart?
			local character = player.Character
			local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
			return if root and root:IsA("BasePart") then root else nil
		end,
		volumes = function(): { Volume }
			return world.volumes
		end,
		inVent = function(player: Player): boolean
			return world.inVent[player] == true
		end,
		supported = function(_player: Player, _position: Vector3): boolean
			return world.supported
		end,
		lock = function(player: Player, reason: Enums.ControlLock, mode: Enums.LockMode)
			local held = world.locks[player] or {}
			table.insert(held, reason)
			world.locks[player] = held
			table.insert(world.lockModes, mode)
		end,
		unlock = function(player: Player, reason: Enums.ControlLock)
			local held = world.locks[player]
			if held then
				local index = table.find(held, reason)
				if index then
					table.remove(held, index)
				end
			end
		end,
		getLock = function(player: Player): Enums.ControlLock
			return lockOf(world, player)
		end,
		exempt = function(player: Player, token: string, seconds: number)
			table.insert(world.exempts, { player = player, token = token, seconds = seconds })
		end,
		creatureRoot = function(): BasePart?
			return world.creature
		end,
		creatureHolds = function(_player: Player): boolean
			return world.holds
		end,
		stun = function(seconds: number, from: Vector3)
			table.insert(world.stuns, { seconds = seconds, from = from })
		end,
		catchGrabbed = function(player: Player): boolean
			table.insert(world.catches, player)
			if world.catchResult then
				-- The jumpscare takes the body (an Anchor lock of its own).
				local held = world.locks[player] or {}
				table.insert(held, "Jumpscare")
				world.locks[player] = held
			end
			return world.catchResult
		end,
		attachDrag = function(_player: Player, _root: BasePart, from: Vector3): FloodedPoolService.DragRig?
			local fake: FakeRig = { targets = { from }, destroyed = false }
			table.insert(world.rigs, fake)
			local rig: FloodedPoolService.DragRig = {
				SetTarget = function(_self: FloodedPoolService.DragRig, position: Vector3, _facing: Vector3?)
					table.insert(fake.targets, position)
				end,
				Destroy = function(_self: FloodedPoolService.DragRig)
					fake.destroyed = true
				end,
			}
			return rig
		end,
		cue = function(player: Player, payload: Types.PrivateCuePayload)
			table.insert(world.cues, { player = player, payload = payload })
		end,
		notify = function(player: Player, key: string, args: { string })
			table.insert(world.notices, { player = player, key = key, args = args })
		end,
		emit = function(position: Vector3, kind: Enums.NoiseKind, player: Player)
			table.insert(world.noises, { position = position, kind = kind, player = player })
		end,
		playAt = function(preset: string, position: Vector3, except: Player?)
			table.insert(world.sounds, { preset = preset, position = position, except = except })
		end,
		playOn = function(preset: string, _attach: Instance): any
			table.insert(world.loops, preset)
			local handle = {
				id = #world.loops,
				preset = preset,
				looped = true,
				Stop = function(_self: any, _fade: number?)
					table.insert(world.loops, "stop:" .. preset)
				end,
				IsActive = function(_self: any): boolean
					return true
				end,
			}
			return handle
		end,
		playFor = function(player: Player, _preset: string)
			table.insert(world.stings, player)
		end,
	})
	local ctx: Types.RunContext = {
		runId = "pool-spec",
		seed = 41,
		difficulty = "Standard",
		participants = players,
		startedAt = 1000,
	}
	RunStatsService.BeginRun(ctx)
	PlayerStateService.BeginRun(ctx)
	LifeStateService.BeginRun(ctx)
	FloodedPoolService.BeginRun(ctx)
	local failure: string? = nil
	xpcall(body, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end, world)
	FloodedPoolService.EndRun()
	LifeStateService.EndRun()
	PlayerStateService.EndRun()
	RunStatsService.EndRun()
	for _, player in players do
		FloodedPoolService.OnPlayerRemoving(player)
		LifeStateService.OnPlayerRemoving(player)
		PlayerStateService.OnPlayerRemoving(player)
		NoiseAndDirectorService.OnPlayerRemoving(player)
		local character = player.Character
		if character then
			character.Parent = nil
		end
		player.Parent = nil
	end
	FloodedPoolService.SetDependencies(nil)
	PlayerStateService.SetClock(nil)
	LifeStateService.SetClock(nil)
	if failure ~= nil then
		error(failure, 0)
	end
end

-- One pool tick `seconds` from now (the clock moves first).
local function tick(world: World, seconds: number)
	world.clock.advance(seconds)
	FloodedPoolService.Poll(world.clock.now())
end

-- Puts `player` (root `root`) in the water treading, through one poll.
local function swimIn(world: World, root: BasePart)
	place(root, Vector3.new(root.CFrame.Position.X, TREAD_ROOT, root.CFrame.Position.Z))
	tick(world, 0.1)
end

local function dive(player: Player, seq: number, held: boolean)
	PlayerStateService.SubmitIntent(player, { crouch = false, sprint = false, dive = held, seq = seq })
end

local function oxygenRate(player: Player): number
	return Attributes.getNumber(player, P.OxygenRate, 0)
end

-- Presses the struggle `count` times, `spacing` seconds apart, from sequence `first`; returns the next sequence.
local function mash(world: World, player: Player, first: number, count: number, spacing: number): number
	local sequence = first
	for _ = 1, count do
		world.clock.advance(spacing)
		FloodedPoolService.SubmitPress(player, sequence)
		sequence += 1
	end
	return sequence
end

local function creaturePart(at: Vector3): BasePart
	local part = Instance.new("Part")
	part.Name = "HumanoidRootPart"
	part.CFrame = CFrame.new(at)
	return part
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["WaterRules: volumes, the in / out hysteresis and duct floods"] = function(t: Expect)
		t.near(POOL.surface, SURFACE, 1e-5, "the top face is the surface")
		t.near(POOL.bottom, -10, 1e-5)
		local volumes = { DUCT, POOL }
		t.eq(WaterRules.locate(volumes, Vector3.new(0, TREAD_ROOT, 0), nil), POOL, "a treading root is in")
		t.eq(WaterRules.locate(volumes, Vector3.new(0, -8, 0), nil), POOL, "deep under is in")
		t.eq(WaterRules.locate(volumes, Vector3.new(0, SURFACE + 0.4, 0), nil), POOL, "just over the surface enters")
		t.eq(WaterRules.locate(volumes, Vector3.new(0, SURFACE + 1, 0), nil), nil, "a foot over the surface does not")
		t.eq(WaterRules.locate(volumes, Vector3.new(0, SURFACE + 1, 0), POOL), POOL, "but a swimmer bobbing up stays")
		t.eq(WaterRules.locate(volumes, Vector3.new(0, SURFACE + 1.9, 0), POOL), nil, "climbing out leaves")
		t.eq(WaterRules.locate(volumes, Vector3.new(25, -2, 0), nil), nil, "outside the footprint")
		t.eq(WaterRules.locate(volumes, Vector3.new(0, 3, 0), nil), nil, "a walker on a deck at the surface's level")
		t.eq(
			WaterRules.locate(volumes, Vector3.new(0, 2.5, 0), nil),
			nil,
			"standing on a fragment awash at the surface"
		)
		t.eq(WaterRules.locate(volumes, Vector3.new(0, -1.5, 30), nil), nil, "the duct's flood is never swum")
		t.eq(WaterRules.locate(volumes, Vector3.new(0, -10.5, 0), nil), POOL, "on the pool floor")
		t.eq(WaterRules.locate(volumes, Vector3.new(0, -11, 0), nil), nil, "under the floor")
		t.eq(WaterRules.locate(volumes, Vector3.new(0 / 0, 0, 0), nil), nil, "non-finite")
		t.eq(WaterRules.volumeAround(volumes, Vector3.new(0, 0.5, 0), 2), POOL, "the camera's water")
		t.eq(WaterRules.volumeAround(volumes, Vector3.new(0, -1.5, 30), 2), nil, "not the duct's")
	end,

	["WaterRules: floating, heads under and the oxygen rate"] = function(t: Expect)
		local treadEye = WaterRules.floatRootY(SURFACE, "Treading") + WaterRules.eyeHeight("Treading")
		t.near(treadEye - SURFACE, WaterRules.EyeAbove.Treading, 1e-6, "treading keeps the eye up")
		local downedEye = WaterRules.floatRootY(SURFACE, "DownedCrawling") + WaterRules.eyeHeight("DownedCrawling")
		t.truthy(downedEye > SURFACE, "a downed swimmer floats face up")
		t.truthy(WaterRules.floatRootY(SURFACE, "DownedCrawling") - SURFACE < WaterRules.StayAbove, "and stays in")
		for _, state in { "Treading", "Freestyle" } do
			t.falsy(WaterRules.submerged(state, WaterRules.floatRootY(SURFACE, state), SURFACE), state .. " floats")
			t.truthy(WaterRules.submerged(state, SURFACE - 2, SURFACE), state .. " pushed under")
		end
		t.truthy(WaterRules.submerged("Underwater", SURFACE + 0.5, SURFACE), "a held dive is under at once")
		t.truthy(WaterRules.submerged("Grabbed", SURFACE + 0.5, SURFACE), "grabbed is always under")
		t.falsy(WaterRules.submerged("DownedCrawling", SURFACE - 3, SURFACE), "the downed never drown")
		local base = { inWater = true, submerged = false, grabbed = false, held = false, oxygen = 50, max = 100 }
		local function rate(changes: { [string]: any }): number
			local input = table.clone(base) :: any
			for key, value in changes do
				input[key] = value
			end
			return WaterRules.oxygenRate(input)
		end
		t.eq(rate({ submerged = true }), -GameConfig.OxygenDrain, "under: drains")
		t.eq(rate({ submerged = true, grabbed = true }), -GameConfig.OxygenDrainGrabbed, "grabbed: faster")
		t.eq(rate({ submerged = true, grabbed = true, held = true }), 0, "a jumpscare holds the meter")
		t.eq(rate({}), GameConfig.OxygenRegen, "at the surface: recovers")
		t.eq(rate({ inWater = false }), GameConfig.OxygenRegen, "out of the water too")
		t.eq(rate({ oxygen = 100 }), 0, "full: holds")
		t.eq(WaterRules.secondsLeft(18, 9), 2)
		t.eq(WaterRules.secondsLeft(18, 0), math.huge)
	end,

	["WaterRules: struggle presses (sequence, rate cap, decay, break-free)"] = function(t: Expect)
		local struggle = WaterRules.newStruggle(100)
		t.eq(WaterRules.press(struggle, 1, 100.05), "Counted")
		t.eq(WaterRules.press(struggle, 1, 100.1), "Stale", "the same sequence never counts twice")
		t.eq(WaterRules.press(struggle, 0, 100.15), "Stale", "nor an older one")
		t.eq(WaterRules.progressAt(struggle, 100.1), 1)
		local now = 100.1
		for sequence = 2, 30 do
			now += 0.02
			WaterRules.press(struggle, sequence, now)
		end
		t.eq(struggle.counted, GameConfig.StruggleMaxPressesPerSecond, "at most 12 in any second")
		t.eq(struggle.lastSequence, 30, "dropped presses still use their sequence numbers")
		t.eq(WaterRules.wouldCount(struggle, 31, now + 0.01), "TooFast")
		t.eq(WaterRules.wouldCount(struggle, 31, 101.2), "Counted", "a second later presses count again")
		local last = struggle.lastPressAt
		local held = WaterRules.progressAt(struggle, last)
		t.eq(held, GameConfig.StruggleMaxPressesPerSecond)
		t.near(WaterRules.progressAt(struggle, last + WaterRules.DecayDelay), held, 1e-6, "no decay for a moment")
		t.near(
			WaterRules.progressAt(struggle, last + WaterRules.DecayDelay + 2),
			held - 2 * WaterRules.DecayPerSecond,
			1e-6,
			"then it slips back"
		)
		t.eq(WaterRules.progressAt(struggle, now + 100), 0, "never below nothing")
		local free = WaterRules.newStruggle(0)
		local at = 0
		for sequence = 1, WaterRules.PressesToEscape do
			at += 0.1
			t.eq(WaterRules.press(free, sequence, at), "Counted")
		end
		t.truthy(WaterRules.escaped(free, at), "22 presses at a human pace break free")
		t.near(WaterRules.progressFraction(free, at), 1, 1e-6)
	end,

	["FloodedPoolService rules: who may be grabbed"] = function(t: Expect)
		local ok: FloodedPoolService.GrabCheck = {
			live = true,
			busy = false,
			lifeState = "Alive",
			swimming = true,
			inVent = false,
			controlLock = "None",
			hasBody = true,
		}
		local function verdict(changes: { [string]: any }): string
			local check = table.clone(ok) :: any
			for key, value in changes do
				check[key] = value
			end
			local allowed, reason = FloodedPoolService.grabCheck(check)
			return if allowed then "ok" else tostring(reason)
		end
		t.eq(verdict({}), "ok")
		t.eq(verdict({ live = false }), "NoRun")
		t.eq(verdict({ busy = true }), "Busy", "one victim at a time")
		t.eq(verdict({ lifeState = "Downed" }), "LifeState", "never the downed")
		t.eq(verdict({ hasBody = false }), "NoBody")
		t.eq(verdict({ inVent = true }), "InVent")
		t.eq(verdict({ swimming = false }), "NotSwimming")
		t.eq(verdict({ controlLock = "Trap" }), "Locked")
	end,

	["FloodedPoolService rules: the drag's path, the validator, splashes and flasks"] = function(t: Expect)
		local from = Vector3.new(4, TREAD_ROOT, 4)
		local creature = Vector3.new(4, -6, 0)
		local to = FloodedPoolService.dragTarget(from, creature, POOL, Vector3.new(0, 0, -1))
		t.near(to.Y, SURFACE - FloodedPoolService.HoldDepth, 1e-4, "held under")
		t.near(MathUtil.horizontalDistance(to, creature), 2.4, 1e-3, "just short of the Creature")
		t.truthy((to - creature).Unit:Dot((from - creature).Unit) > 0.5, "on the victim's side of it")
		local alone = FloodedPoolService.dragTarget(from, nil, POOL, Vector3.new(0, 0, -1))
		t.near(alone.Z, from.Z + 3, 1e-4, "straight back without a Creature")
		local corner =
			FloodedPoolService.dragTarget(Vector3.new(19.5, TREAD_ROOT, 19.5), nil, POOL, Vector3.new(0, 0, -1))
		t.truthy(corner.X <= 20 - 1.5 + 1e-4 and corner.Z <= 20 - 1.5 + 1e-4, "kept inside the walls")
		local shallow = WaterRules.volumeOf("Shallow", CFrame.new(0, -2, 0), Vector3.new(20, 2, 20), false, nil)
		local floor = FloodedPoolService.dragTarget(Vector3.new(0, -1.1, 0), nil, shallow, Vector3.new(1, 0, 0))
		t.truthy(floor.Y >= shallow.bottom + 1.6 - 1e-4, "never into the floor")
		t.eq(FloodedPoolService.dragPosition(from, to, 0), from)
		t.truthy((FloodedPoolService.dragPosition(from, to, 1) - to).Magnitude < 1e-4)
		local early = FloodedPoolService.dragPosition(from, to, 0.35)
		t.truthy(
			math.abs(early.Y - from.Y) / math.abs(to.Y - from.Y)
				> MathUtil.horizontalDistance(early, from) / MathUtil.horizontalDistance(to, from),
			"the legs go first: down before back"
		)

		local verdict, target = FloodedPoolService.swimVerdict(Vector3.new(0, SURFACE + 1, 0), SURFACE, false, nil)
		t.eq(verdict, "Ok", "bobbing up is fine")
		t.eq(target, nil)
		local good = Vector3.new(2, SURFACE - 0.5, 3)
		verdict, target = FloodedPoolService.swimVerdict(Vector3.new(0, SURFACE + 4, 0), SURFACE, false, good)
		t.eq(verdict, "Correct", "flying out with nothing underfoot")
		t.eq(target, good)
		verdict = FloodedPoolService.swimVerdict(Vector3.new(0, SURFACE + 4, 0), SURFACE, true, good)
		t.eq(verdict, "Ok", "climbing onto something")
		verdict, target = FloodedPoolService.swimVerdict(Vector3.new(0 / 0, 0, 0), SURFACE, false, good)
		t.eq(verdict, "Strike")
		t.eq(target, good)

		t.truthy(FloodedPoolService.entrySplash(FloodedPoolService.SplashSpeed), "a jump in splashes")
		t.falsy(FloodedPoolService.entrySplash(2), "slipping in does not")
		t.truthy(FloodedPoolService.shatterFrees(Vector3.new(10, 0, 0), false, Vector3.zero), "within the cloud")
		t.falsy(FloodedPoolService.shatterFrees(Vector3.new(30, 0, 0), false, Vector3.zero), "too far")
		t.falsy(FloodedPoolService.shatterFrees(Vector3.zero, true, Vector3.zero), "a duct shatter never reaches")
		t.eq(FloodedPoolService.freedOxygen(3), FloodedPoolService.FreedMinOxygen, "time to reach the surface")
		t.eq(FloodedPoolService.freedOxygen(80), nil)
		t.truthy(FloodedPoolService.GrabMinOxygen / GameConfig.OxygenDrainGrabbed >= 4, "every grab can be fought")
	end,

	["live: in and out of the water, modes, the climb and the Swim validator"] = function(t: Expect)
		local player, root = fakePlayer(Vector3.new(0, 3, 0))
		inPool({ player }, function(world: World)
			tick(world, 0.1)
			t.falsy(FloodedPoolService.IsSwimming(player), "over the water but standing high above it")
			t.eq(PlayerStateService.GetMode(player), "OnFoot")
			place(root, Vector3.new(0, SURFACE + 0.3, 0))
			tick(world, 0.5)
			t.truthy(FloodedPoolService.IsSwimming(player), "in the water")
			t.eq(PlayerStateService.GetMode(player), "Swim")
			t.eq(PlayerStateService.GetMoveState(player), "Treading")
			t.eq(FloodedPoolService.GetWater(player), POOL)
			t.eq(#world.noises, 0, "slipped in: no splash")
			-- Bobbing up a little keeps them in.
			place(root, Vector3.new(0, SURFACE + 1.2, 0))
			tick(world, 0.1)
			t.truthy(FloodedPoolService.IsSwimming(player), "a bob does not leave")
			-- Rising out with nothing underfoot: still swimming; the validator puts them back.
			place(root, Vector3.new(0, SURFACE + 3.5, 0))
			tick(world, 0.1)
			t.truthy(FloodedPoolService.IsSwimming(player), "flying out is not leaving")
			local verdict, target = FloodedPoolService.SwimValidator(player, root, 0.1)
			t.eq(verdict, "Correct")
			t.truthy(target ~= nil and (target :: Vector3).Y <= SURFACE + 1e-4, "back into the water")
			-- Climbing out onto the coping: support underfoot.
			place(root, Vector3.new(0, TREAD_ROOT, 0))
			tick(world, 0.1)
			world.supported = true
			place(root, Vector3.new(0, SURFACE + 1.2, 0))
			tick(world, 0.1)
			t.eq(world.exempts[#world.exempts].token, FloodedPoolService.ClimbToken, "the climb is exempted")
			place(root, Vector3.new(0, SURFACE + 3.6, 0))
			tick(world, 0.1)
			t.falsy(FloodedPoolService.IsSwimming(player), "climbed out")
			t.eq(PlayerStateService.GetMode(player), "OnFoot")
			t.eq(FloodedPoolService.SwimValidator(player, root, 0.1), "Ok", "out of the water: not judged")
			-- A jump back in splashes.
			world.supported = false
			place(root, Vector3.new(0, 3, 0))
			tick(world, 0.1)
			place(root, Vector3.new(0, SURFACE - 1, 0))
			tick(world, 0.1)
			t.eq(#world.noises, 1, "the splash noise")
			t.eq(world.noises[1].kind, "Splash")
			t.eq(world.noises[1].player, player)
			t.near(world.noises[1].position.Y, SURFACE, 1e-5, "at the surface")
			t.eq(world.sounds[#world.sounds].preset, "Splash")
			t.eq(world.sounds[#world.sounds].except, player, "the swimmer's own client plays theirs")
			-- Into a duct: the vents own the body.
			PlayerStateService.SetMode(player, "Vent")
			world.inVent[player] = true
			tick(world, 0.1)
			t.falsy(FloodedPoolService.IsSwimming(player))
			t.eq(PlayerStateService.GetMode(player), "Vent", "the vent mode is left alone")
			world.inVent[player] = nil
			PlayerStateService.SetMode(player, "OnFoot")
			tick(world, 0.1)
			t.truthy(FloodedPoolService.IsSwimming(player), "out of the duct into the water")
			world.live = false
			place(root, Vector3.new(30, 3, 0))
			tick(world, 0.1)
			t.truthy(FloodedPoolService.IsSwimming(player), "no run: nothing is polled")
			world.live = true
			tick(world, 0.1)
			t.falsy(FloodedPoolService.IsSwimming(player), "walked off the side onto the deck")
			t.eq(PlayerStateService.GetMode(player), "OnFoot")
		end)
	end,

	["live: oxygen drains under, recovers at the surface, and drowning downs"] = function(t: Expect)
		local player, root = fakePlayer(Vector3.new(0, 3, 0))
		inPool({ player }, function(world: World)
			swimIn(world, root)
			t.eq(oxygenRate(player), 0, "full and floating")
			dive(player, 1, true)
			t.eq(PlayerStateService.GetMoveState(player), "Underwater")
			tick(world, 0.1)
			t.eq(oxygenRate(player), -GameConfig.OxygenDrain, "holding the breath")
			world.clock.advance(4)
			t.near(PlayerStateService.GetOxygen(player), 100 - 4 * GameConfig.OxygenDrain, 1e-3)
			dive(player, 2, false)
			place(root, Vector3.new(0, SURFACE - 3, 0))
			tick(world, 0.1)
			t.eq(oxygenRate(player), -GameConfig.OxygenDrain, "still under on the way up")
			place(root, Vector3.new(0, TREAD_ROOT, 0))
			tick(world, 0.1)
			t.eq(oxygenRate(player), GameConfig.OxygenRegen, "surfaced: breathing again")
			world.clock.advance(3)
			tick(world, 0.1)
			t.eq(oxygenRate(player), 0, "full again")
			-- Out of air: a Down ("Drowned").
			dive(player, 3, true)
			tick(world, 0.1)
			local seconds = PlayerStateService.GetOxygen(player) / GameConfig.OxygenDrain
			world.clock.advance(seconds + 0.05)
			t.eq(LifeStateService.GetState(player), "Downed", "drowned")
			t.eq(PlayerStateService.GetMoveState(player), "DownedCrawling")
			tick(world, 0.1)
			t.eq(oxygenRate(player), GameConfig.OxygenRegen, "a downed swimmer floats and breathes")
		end)
	end,

	["live: the grab, its lock, override, lungful, cue, warning and drag"] = function(t: Expect)
		local victim, root = fakePlayer(Vector3.new(4, 3, 4))
		local friend = fakePlayer(Vector3.new(30, 3, 0))
		inPool({ victim, friend }, function(world: World)
			t.falsy(FloodedPoolService.TryGrab(victim), "not in the water")
			swimIn(world, root)
			world.locks[victim] = { "Trap" }
			t.falsy(FloodedPoolService.TryGrab(victim), "under another lock")
			world.locks[victim] = nil
			world.creature = creaturePart(Vector3.new(4, -6, 0))
			PlayerStateService.AddOxygen(victim, -90)
			local startedAt = world.clock.now()
			t.truthy(FloodedPoolService.TryGrab(victim), "grabbed")
			t.eq(FloodedPoolService.GetGrabbed(), victim)
			t.eq(lockOf(world, victim), "Drag")
			t.eq(world.lockModes[#world.lockModes], "ServerOwned", "the server owns the body")
			t.eq(PlayerStateService.GetMoveState(victim), "Grabbed")
			t.near(
				PlayerStateService.GetOxygen(victim),
				FloodedPoolService.GrabMinOxygen,
				1e-3,
				"a lungful to fight with"
			)
			t.eq(oxygenRate(victim), -GameConfig.OxygenDrainGrabbed)
			local starts = cuesOf(world, "Start")
			t.eq(#starts, 1, "the struggle cue")
			t.eq(starts[1].kind, "Struggle")
			t.eq(starts[1].args.needed, GameConfig.StrugglePressesToEscape)
			t.eq(world.notices[1].player, friend, "the squad is warned")
			t.eq(world.notices[1].key, FloodedPoolService.TeammateKey)
			t.eq(world.notices[1].args[1], victim.DisplayName)
			t.eq(#world.notices, 1, "not the victim")
			t.eq(world.loops[1], "StruggleThrash", "the thrashing for everyone")
			t.eq(world.stings[1], victim)
			t.falsy(FloodedPoolService.TryGrab(friend), "one at a time")
			-- The drag: down first, then back, over DragSeconds, then held.
			local rig = world.rigs[1]
			local to = FloodedPoolService.dragTarget(
				Vector3.new(4, TREAD_ROOT, 4),
				Vector3.new(4, -6, 0),
				POOL,
				root.CFrame.LookVector
			)
			FloodedPoolService.Step(startedAt + FloodedPoolService.DragSeconds / 2)
			local middle = rig.targets[#rig.targets]
			t.truthy(middle.Y < TREAD_ROOT and middle.Y > to.Y, "on the way down")
			FloodedPoolService.Step(startedAt + FloodedPoolService.DragSeconds)
			t.truthy((rig.targets[#rig.targets] - to).Magnitude < 0.6, "held in front of the Creature")
			t.eq(FloodedPoolService.SwimValidator(victim, root, 0.1), "Ok")
			-- Oxygen keeps draining at the grabbed rate through the poll.
			tick(world, 0.1)
			t.eq(oxygenRate(victim), -GameConfig.OxygenDrainGrabbed)
		end)
	end,

	["live: mashing free (stale and too-fast presses) and the recoil"] = function(t: Expect)
		local victim, root = fakePlayer(Vector3.new(0, 3, 0))
		inPool({ victim }, function(world: World)
			swimIn(world, root)
			t.eq(FloodedPoolService.SubmitPress(victim, 1), nil, "nobody is held")
			t.truthy(FloodedPoolService.TryGrab(victim))
			world.clock.advance(0.05)
			t.eq(FloodedPoolService.SubmitPress(victim, 1), "Counted")
			t.eq(FloodedPoolService.SubmitPress(victim, 1), "Stale")
			local sequence = 2
			local tooFast = 0
			for _ = 1, 20 do
				world.clock.advance(0.01)
				if FloodedPoolService.SubmitPress(victim, sequence) == "TooFast" then
					tooFast += 1
				end
				sequence += 1
			end
			t.eq(tooFast, 20 - (GameConfig.StruggleMaxPressesPerSecond - 1), "a macro is capped at 12/s")
			world.clock.advance(1)
			FloodedPoolService.Step(world.clock.now())
			local before = FloodedPoolService.GetStruggleProgress()
			t.truthy(before > 0 and before < 1)
			sequence = mash(world, victim, sequence, 30, 0.1)
			t.eq(FloodedPoolService.GetGrabbed(), nil, "broke free")
			t.eq(lockOf(world, victim), "None", "the lock is released")
			t.eq(PlayerStateService.GetMoveState(victim), "Treading", "the override is released")
			t.truthy(world.rigs[1].destroyed, "the rig is gone")
			t.eq(world.loops[#world.loops], "stop:StruggleThrash")
			t.eq(#world.stuns, 1, "the Creature recoils")
			t.eq(world.stuns[1].seconds, FloodedPoolService.RecoilSeconds)
			local ends = cuesOf(world, "End")
			t.eq(#ends, 1)
			t.eq(ends[1].args.outcome, "Escaped")
			t.truthy(PlayerStateService.GetOxygen(victim) >= FloodedPoolService.FreedMinOxygen - 1e-3)
			t.eq(FloodedPoolService.SubmitPress(victim, sequence), nil, "presses after the end are ignored")
		end)
	end,

	["live: flasks, the floodlights and the Creature letting go free the victim"] = function(t: Expect)
		local victim, root = fakePlayer(Vector3.new(0, 3, 0))
		inPool({ victim }, function(world: World)
			swimIn(world, root)
			local outcomes: { string } = {}
			local connection = FloodedPoolService.GrabEnded:Connect(function(_player: Player, outcome: string)
				table.insert(outcomes, outcome)
			end)
			-- A flask: only within the cloud and out of the ducts.
			t.truthy(FloodedPoolService.TryGrab(victim))
			local at = root.CFrame.Position
			ChemicalProjectileService.Shattered:Fire(
				at + Vector3.new(GameConfig.FlaskCloudRadius + 2, 0, 0),
				nil,
				false
			)
			t.eq(FloodedPoolService.GetGrabbed(), victim, "too far")
			ChemicalProjectileService.Shattered:Fire(at, nil, true)
			t.eq(FloodedPoolService.GetGrabbed(), victim, "in a duct")
			ChemicalProjectileService.Shattered:Fire(at + Vector3.new(4, 1, 0), nil, false)
			t.eq(FloodedPoolService.GetGrabbed(), nil, "the flask frees them")
			t.eq(outcomes[1], "Flask")
			t.eq(world.stuns[#world.stuns].seconds, GameConfig.StunSeconds)
			-- The floodlights.
			tick(world, 0.1)
			t.truthy(FloodedPoolService.TryGrab(victim))
			t.truthy(FloodedPoolService.ReleaseGrab("Floodlight"))
			t.eq(outcomes[2], "Floodlight")
			t.eq(#world.stuns, 2)
			t.falsy(FloodedPoolService.ReleaseGrab("Floodlight"), "nobody left to free")
			-- The Creature lets go (stunned by something else): after the grace, LetGo, no recoil.
			tick(world, 0.1)
			t.truthy(FloodedPoolService.TryGrab(victim))
			world.holds = false
			tick(world, FloodedPoolService.HoldGrace * 0.5)
			t.eq(FloodedPoolService.GetGrabbed(), victim, "a moment's grace")
			tick(world, FloodedPoolService.HoldGrace)
			t.eq(FloodedPoolService.GetGrabbed(), nil)
			t.eq(outcomes[3], "LetGo")
			t.eq(#world.stuns, 2, "no recoil for a let-go")
			-- The run ending.
			world.holds = true
			tick(world, 0.1)
			t.truthy(FloodedPoolService.TryGrab(victim))
			FloodedPoolService.EndRun()
			t.eq(outcomes[4], "Ended")
			t.eq(lockOf(world, victim), "None")
			connection:Disconnect()
		end)
	end,

	["live: drowning while held is the Underwater catch, else a drowned Down"] = function(t: Expect)
		local victim, root = fakePlayer(Vector3.new(0, 3, 0))
		inPool({ victim }, function(world: World)
			swimIn(world, root)
			t.truthy(FloodedPoolService.TryGrab(victim))
			local seconds = (100 - FloodedPoolService.DrownFloor) / GameConfig.OxygenDrainGrabbed
			world.clock.advance(seconds - 0.1)
			t.eq(#world.catches, 0, "not yet")
			world.clock.advance(0.15)
			t.eq(world.catches[1], victim, "the catch is asked for at the floor")
			t.eq(FloodedPoolService.GetGrabbed(), nil)
			t.eq(cuesOf(world, "End")[1].args.outcome, "Caught")
			t.near(PlayerStateService.GetOxygen(victim), FloodedPoolService.DrownFloor, 0.05, "the meter waits")
			tick(world, 0.1)
			t.eq(oxygenRate(victim), 0, "held by the jumpscare")
			t.eq(LifeStateService.GetState(victim), "Alive", "the jumpscare decides, not the meter")
			t.eq(#world.stuns, 0, "no recoil")
		end)
		local second, secondRoot = fakePlayer(Vector3.new(0, 3, 0))
		inPool({ second }, function(world: World)
			world.catchResult = false
			swimIn(world, secondRoot)
			t.truthy(FloodedPoolService.TryGrab(second))
			world.clock.advance((100 - FloodedPoolService.DrownFloor) / GameConfig.OxygenDrainGrabbed + 0.05)
			t.eq(cuesOf(world, "End")[1].args.outcome, "Drowned")
			t.eq(LifeStateService.GetState(second), "Downed", "no catch could start: drowned")
			t.eq(lockOf(world, second), "None")
		end)
	end,

	["CrawlRules: swimmers enter a pool grate from the water"] = function(t: Expect)
		local check: CrawlRules.EntryCheck = {
			live = true,
			participant = true,
			lifeState = "Alive",
			inVent = false,
			onFoot = false,
			swimming = true,
			moveState = "Treading",
			controlLock = "None",
			hasBody = true,
		}
		local function verdict(changes: { [string]: any }): string
			local input = table.clone(check) :: any
			for key, value in changes do
				input[key] = value
			end
			local allowed, reason = CrawlRules.canEnter(input)
			return if allowed then "ok" else tostring(reason)
		end
		t.eq(verdict({}), "ok", "treading")
		t.eq(verdict({ moveState = "Freestyle" }), "ok")
		t.eq(verdict({ moveState = "Underwater" }), "ok", "diving in")
		t.eq(verdict({ moveState = "Grabbed" }), "MoveState")
		t.eq(verdict({ swimming = false }), "Mode", "neither on foot nor swimming")
		t.eq(verdict({ onFoot = true, swimming = false, moveState = "Crouching" }), "ok", "on foot is unchanged")
		t.eq(verdict({ onFoot = true, swimming = false, moveState = "Treading" }), "MoveState")
		t.eq(verdict({ controlLock = "Drag" }), "Locked", "never while held")
		local wall = CFrame.lookAt(Vector3.new(0, SURFACE, 0), Vector3.new(0, SURFACE, 1))
		local mouth = WorldConfig.WallThickness / 2 + 1
		t.truthy(CrawlRules.inSwimMouthBox(wall, Vector3.new(0, TREAD_ROOT, mouth), SURFACE), "floating at the mouth")
		t.truthy(CrawlRules.inSwimMouthBox(wall, Vector3.new(1, SURFACE - 2, mouth), SURFACE), "diving at it")
		t.falsy(CrawlRules.inSwimMouthBox(wall, Vector3.new(0, SURFACE - 3, mouth), SURFACE), "too deep")
		t.falsy(CrawlRules.inSwimMouthBox(wall, Vector3.new(0, SURFACE + 1.5, mouth), SURFACE), "too high")
		t.falsy(CrawlRules.inSwimMouthBox(wall, Vector3.new(2, TREAD_ROOT, mouth), SURFACE), "beside it")
		t.falsy(CrawlRules.inSwimMouthBox(wall, Vector3.new(0, TREAD_ROOT, mouth + 3), SURFACE), "too far out")
		t.falsy(CrawlRules.inSwimMouthBox(wall, Vector3.new(0, TREAD_ROOT, -1), SURFACE), "behind the wall")
	end,

	["SwimController: membership and the stroke"] = function(t: Expect)
		local function member(changes: { [string]: any }): string
			local input: any = {
				engaged = false,
				alive = true,
				inVent = false,
				inWater = true,
				climbing = false,
				locked = false,
			}
			for key, value in changes do
				input[key] = value
			end
			return SwimController.membership(input)
		end
		t.eq(member({}), "Engage")
		t.eq(member({ engaged = true }), "Drive")
		t.eq(member({ engaged = true, locked = true }), "Hold", "the server's drag holds the body")
		t.eq(member({ engaged = true, inWater = false }), "Release")
		t.eq(member({ engaged = true, inWater = false, climbing = true }), "Drive", "a climb finishes")
		t.eq(member({ inWater = false }), "Idle")
		t.eq(member({ engaged = true, inVent = true }), "Release", "into a duct")
		t.eq(member({ engaged = true, alive = false }), "Release")

		local base: SwimController.StrokeInput = {
			state = "Treading",
			rootY = TREAD_ROOT,
			surface = SURFACE,
			bottom = -10,
			velocity = Vector3.zero,
			move = Vector3.zero,
			look = Vector3.new(0, 0, -1),
			speed = GameConfig.TreadSpeed,
			time = 0,
			rising = false,
			kick = 0,
		}
		local function stroke(changes: { [string]: any }): SwimController.Stroke
			local input = table.clone(base) :: any
			for key, value in changes do
				input[key] = value
			end
			return SwimController.stroke(input)
		end
		t.truthy(math.abs(stroke({}).velocity.Y) < 1, "floating: just the bob")
		t.truthy(stroke({ rootY = SURFACE - 3 }).velocity.Y > 3, "a treading swimmer pushed under bobs up")
		t.truthy(stroke({ rootY = SURFACE - 30 }).velocity.Y <= 6 + 1e-6, "no faster than RiseMax")
		t.truthy(stroke({ rootY = SURFACE + 1.5 }).velocity.Y < 0, "settles back down")
		local ahead = stroke({ move = Vector3.new(0, 0, -1) }).velocity
		t.near(MathUtil.flat(ahead).Magnitude, GameConfig.TreadSpeed, 1e-4, "at the state's WalkSpeed")
		local fast = stroke({ state = "Freestyle", speed = GameConfig.FreestyleSpeed, move = Vector3.new(1, 0, 0) })
		t.near(fast.velocity.X, GameConfig.FreestyleSpeed, 1e-4)

		local under = {
			state = "Underwater",
			rootY = SURFACE - 4,
			speed = GameConfig.UnderwaterSpeed,
			move = Vector3.new(0, 0, -1),
			look = MathUtil.vectorFromYawPitch(0, math.rad(-30)),
		}
		local down = stroke(under).velocity
		t.truthy(down.Y < -1, "forward follows the look down")
		t.truthy(MathUtil.flat(down).Magnitude <= GameConfig.UnderwaterSpeed + 1e-4, "level speed within WalkSpeed")
		local upLook = table.clone(under) :: any
		upLook.look = MathUtil.vectorFromYawPitch(0, math.rad(40))
		t.truthy(stroke(upLook).velocity.Y > 1, "and up")
		local duck = stroke({ state = "Underwater", rootY = TREAD_ROOT, speed = GameConfig.UnderwaterSpeed })
		t.truthy(duck.velocity.Y <= -4, "a duck dive takes them under")
		local hover = stroke({ state = "Underwater", rootY = SURFACE - 5, speed = GameConfig.UnderwaterSpeed })
		t.eq(hover.velocity.Y, 0, "deep enough: hovering")
		local rise = stroke({ state = "Underwater", rootY = SURFACE - 5, speed = 5, rising = true })
		t.truthy(rise.velocity.Y >= 5 - 1e-6, "Space swims up")
		local ceiling = stroke({ state = "Underwater", rootY = SURFACE - 1.2, speed = 5, rising = true })
		t.truthy(ceiling.velocity.Y < 1, "a diver never breaches")
		local floor = stroke({ state = "Underwater", rootY = -9.5, speed = 5, look = Vector3.new(0, -1, 0) })
		t.truthy(floor.velocity.Y >= 0, "never into the floor")
		t.truthy(stroke({ rootY = SURFACE - 4, kick = 7.5 }).velocity.Y >= 7.5, "the escape kick")
		local plunge = stroke({ velocity = Vector3.new(0, -40, 0) })
		t.truthy(plunge.accel > stroke({}).accel * 4, "the water brakes a plunge hard")
		t.truthy(plunge.accel <= 420, "but finitely")
	end,

	["SwimController: the climb, the underwater view, strokes, exhales, murk and panic"] = function(t: Expect)
		local root = Vector3.new(0, TREAD_ROOT, 0)
		local forward = Vector3.new(0, 0, -1)
		local target = SwimController.climbTarget(root, forward, 0, SURFACE, 3, SwimController.ClimbReach)
		t.truthy(target ~= nil, "the coping a stud over the water")
		local climb = target :: SwimController.ClimbTarget
		t.near(climb.stand.Y, 3, 1e-5, "standing on the deck")
		t.near(climb.stand.Z, -(SwimController.ClimbReach + 1.2), 1e-5, "past the edge")
		t.eq(
			SwimController.climbTarget(root, forward, SURFACE + 3, SURFACE, 3, SwimController.ClimbReach),
			nil,
			"too high"
		)
		t.eq(SwimController.climbTarget(root, forward, SURFACE, SURFACE, 3, SwimController.ClimbReach), nil, "awash")
		t.eq(SwimController.climbTarget(root, Vector3.zero, 0, SURFACE, 3, 1.9), nil, "facing nowhere")
		t.truthy((SwimController.climbPath(root, climb, 0) - root).Magnitude < 1e-5)
		t.truthy((SwimController.climbPath(root, climb, 1) - climb.stand).Magnitude < 1e-5)
		t.near(SwimController.climbPath(root, climb, 0.5).Y, climb.stand.Y + 0.15, 1e-5, "up over the edge first")

		t.eq(SwimController.underwaterAmount(-1), 0)
		t.eq(SwimController.underwaterAmount(1), 1)
		local half = SwimController.waterline(0.1, 400, true, 720)
		t.truthy(half.visible and half.y == 400, "the lens half under")
		t.eq(SwimController.waterline(0.1, 900, true, 720).y, 720, "clamped to the screen")
		t.falsy(SwimController.waterline(0.1, 400, false, 720).visible, "looking straight up or down")
		t.eq(SwimController.waterline(2, 400, true, 720).y, 0, "deep: all under")
		t.eq(SwimController.waterline(-2, 400, true, 720).y, 720, "high: all above")

		t.eq(SwimController.strokeInterval("Freestyle", 6), 0.55)
		t.eq(SwimController.strokeInterval("Treading", 0), 2.6, "idle treading is quiet and slow")
		t.eq(SwimController.strokeInterval("Underwater", 5), nil)
		t.eq(SwimController.strokeInterval("Standing", 5), nil)
		t.truthy(SwimController.exhaleDelay(0.2, 0.5) < SwimController.exhaleDelay(1, 0.5), "exhales quicken")
		t.truthy(SwimController.exhaleDelay(1, 1) <= SwimController.ExhaleMax + 1e-6)
		t.eq(SwimController.murk(0, 1), 1, "no murk in the air")
		t.truthy(SwimController.murk(1, 0.1) < SwimController.murk(1, 1), "the dark closes in as the air goes")
		t.eq(SwimController.panicFloor(0.9, true), nil)
		t.eq(SwimController.panicFloor(0.3, false), nil, "not at the surface")
		local floor = SwimController.panicFloor(0.3, true)
		t.truthy(floor ~= nil and floor > 0 and floor < 1)
		t.truthy((SwimController.panicFloor(0, true) :: number) > (floor :: number))
		t.eq(SwimController.bob("Treading", 0), 0)
	end,

	["StruggleController: start, end, darkness, pull, yanks, shake and reconciliation"] = function(t: Expect)
		local start = StruggleController.shouldStart
		t.truthy(start({ engaged = false, cueStarted = true, moveState = "Treading", controlLock = "None" }), "the cue")
		t.truthy(
			start({ engaged = false, cueStarted = false, moveState = "Grabbed", controlLock = "Drag" }),
			"late cue"
		)
		t.falsy(start({ engaged = false, cueStarted = false, moveState = "Grabbed", controlLock = "Jumpscare" }))
		t.falsy(start({ engaged = true, cueStarted = true, moveState = "Grabbed", controlLock = "Drag" }))
		local finish = StruggleController.shouldEnd
		t.truthy(finish({ engaged = true, cueEnded = true, grabbedFor = 1, notGrabbedFor = 0 }))
		t.truthy(
			finish({ engaged = true, cueEnded = false, grabbedFor = 3, notGrabbedFor = StruggleController.EndGrace })
		)
		t.falsy(finish({ engaged = true, cueEnded = false, grabbedFor = 3, notGrabbedFor = 0.2 }))
		for _, outcome in { "Escaped", "Flask", "Floodlight", "LetGo" } do
			t.truthy(StruggleController.isFreed(outcome), outcome)
		end
		t.falsy(StruggleController.isFreed("Caught"))
		t.falsy(StruggleController.isFreed("Drowned"))
		t.eq(StruggleController.darkness(1, 1), 0, "plenty of air")
		t.truthy(StruggleController.darkness(0.1, 0) > StruggleController.darkness(0.4, 0), "darker as it runs out")
		t.truthy(StruggleController.darkness(0, 1) <= 0.9, "never black")
		t.truthy(StruggleController.pullWeight(0, 1.2, 0) > StruggleController.pullWeight(2, 1.2, 0), "the drag pulls")
		t.truthy(StruggleController.pullWeight(2, 1.2, 1) > StruggleController.pullWeight(2, 1.2, 0), "a yank pulls")
		t.eq(StruggleController.tugEnvelope(-0.1), 0)
		t.eq(StruggleController.tugEnvelope(1), 0)
		t.truthy(StruggleController.tugEnvelope(0.06) > 0.5)
		local nextTug = StruggleController.nextTug(10, 0.5)
		t.truthy(nextTug >= 10 + StruggleController.TugMin and nextTug <= 10 + StruggleController.TugMax)
		local pitch, yaw, roll = StruggleController.shakeAngles(1.3, 7, 0)
		t.eq(pitch + yaw + roll, 0, "MotionScale 0: no shake")
		local p2 = StruggleController.shakeAngles(1.3, 7, 1)
		t.truthy(math.abs(p2) <= math.rad(2.6) + 1e-6)
		t.eq(StruggleController.reconcile(10, 9), 10, "close enough: the prediction stands")
		t.eq(StruggleController.reconcile(10, 6), 6, "presses were lost: the server's count")
	end,
}
