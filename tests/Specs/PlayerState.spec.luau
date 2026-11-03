--!strict
-- PlayerStateService: the MoveState derivation table per mode, override priority, exhaustion, walk speeds and drains,
-- the stamina / oxygen meter maths and their scheduled crossings (a fake clock runs a vent sprint until the meter
-- empties, the forced drop to crawling, the regen delay and the refill), intents ordered by seq, the lobby baseline,
-- LookRelay quantization and the batched LookBroadcast.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Types = require(ReplicatedStorage.Shared.Types)
local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local LoadoutService = require(ServerScriptService.Services.Player.LoadoutService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Intent = PlayerStateService.Intent
type DeriveInput = PlayerStateService.DeriveInput

type Timer = { at: number, callback: () -> (), thread: thread, cancelled: boolean }

export type FakeClock = {
	clock: PlayerStateService.Clock,
	advance: (seconds: number) -> (),
	now: () -> number,
}

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

local nextUserId = 7100

local function fakePlayer(): (Player, Humanoid)
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "PlayerStateSpec" .. nextUserId
	local writable = player :: any
	writable.UserId = nextUserId
	local model = Instance.new("Model")
	local humanoid = Instance.new("Humanoid")
	humanoid.Health = GameConfig.MaxHealth
	humanoid.WalkSpeed = 16
	humanoid.Parent = model
	player.Character = model
	return player, humanoid
end

local function context(players: { Player }): Types.RunContext
	return { runId = "player-state-spec", seed = 1, difficulty = "Standard", participants = players, startedAt = 1000 }
end

local function intent(crouch: boolean, sprint: boolean, dive: boolean): Intent
	return { crouch = crouch, sprint = sprint, dive = dive }
end

local function input(
	mode: PlayerStateService.Mode,
	posture: Intent,
	stamina: number,
	moving: boolean,
	override: Enums.MoveState?
): DeriveInput
	return { mode = mode, override = override, intent = posture, stamina = stamina, exhausted = false, moving = moving }
end

-- Runs `body` with `player` as an Alive participant of a run on a fake clock, and always tears the run down.
local function inRun(body: (player: Player, humanoid: Humanoid, clock: FakeClock) -> ())
	local clock = fakeClock(1000)
	PlayerStateService.SetClock(clock.clock)
	local player, humanoid = fakePlayer()
	player:SetAttribute("LifeState", "Alive")
	PlayerStateService.BeginRun(context({ player }))
	local failure: string? = nil
	xpcall(body, function(err: any)
		failure = tostring(err)
	end, player, humanoid, clock)
	PlayerStateService.EndRun()
	PlayerStateService.OnPlayerRemoving(player)
	PlayerStateService.SetClock(nil)
	if failure ~= nil then
		error(failure, 0)
	end
end

local function meter(player: Player): (number, number, number)
	return player:GetAttribute("Stamina") :: number,
		player:GetAttribute("StaminaRate") :: number,
		player:GetAttribute("StaminaAt") :: number
end

return {
	["derive: on foot, crouch beats sprint, sprint needs stamina and motion"] = function(t: Expect)
		local derive = PlayerStateService.deriveState
		t.eq(derive(input("OnFoot", intent(false, false, false), 100, false)), "Standing")
		t.eq(derive(input("OnFoot", intent(false, false, false), 100, true)), "Standing", "walking is Standing")
		t.eq(derive(input("OnFoot", intent(true, false, false), 100, true)), "Crouching")
		t.eq(derive(input("OnFoot", intent(true, true, false), 100, true)), "Crouching", "crouch beats sprint")
		t.eq(derive(input("OnFoot", intent(false, true, false), 100, true)), "Sprinting")
		t.eq(derive(input("OnFoot", intent(false, true, false), 100, false)), "Standing", "no sprint standing still")
		t.eq(derive(input("OnFoot", intent(false, true, false), 0, true)), "Standing", "no sprint on empty")
		t.eq(derive(input("OnFoot", intent(false, false, true), 100, true)), "Standing", "dive means nothing on foot")
		local tired = input("OnFoot", intent(false, true, false), 50, true)
		tired.exhausted = true
		t.eq(derive(tired), "Standing", "no sprint while exhausted")
	end,

	["derive: vent and swim modes"] = function(t: Expect)
		local derive = PlayerStateService.deriveState
		t.eq(derive(input("Vent", intent(false, false, false), 100, false)), "VentCrawling")
		t.eq(derive(input("Vent", intent(false, true, false), 100, false)), "VentScurrying", "no motion test in ducts")
		t.eq(derive(input("Vent", intent(false, true, false), 0, true)), "VentCrawling")
		t.eq(derive(input("Vent", intent(true, false, false), 100, true)), "VentCrawling", "crouch means nothing")
		t.eq(derive(input("Swim", intent(false, false, false), 100, false)), "Treading")
		t.eq(derive(input("Swim", intent(false, true, false), 100, false)), "Freestyle")
		t.eq(derive(input("Swim", intent(false, true, false), 0, false)), "Treading")
		t.eq(derive(input("Swim", intent(false, true, true), 100, false)), "Underwater", "dive beats sprint")
		t.eq(derive(input("Swim", intent(false, false, true), 0, false)), "Underwater")
	end,

	["derive: overrides win, highest priority first"] = function(t: Expect)
		local resolve = PlayerStateService.resolveOverride
		t.eq(resolve({}), nil)
		t.eq(resolve({ life = "DownedCrawling" }), "DownedCrawling")
		t.eq(resolve({ life = "DownedCrawling", trap = "Trapped" }), "Trapped")
		t.eq(resolve({ chute = "Parachuting", locker = "Hiding" }), "Hiding")
		t.eq(resolve({ trap = "Trapped", grab = "Grabbed" }), "Grabbed")
		t.eq(resolve({ grab = "Grabbed", cut = "Scripted", life = "DownedCrawling" }), "Scripted")
		local order = PlayerStateService.OverridePriority
		for index = 1, #order - 1 do
			t.truthy(
				PlayerStateService.overrideRank(order[index]) > PlayerStateService.overrideRank(order[index + 1]),
				order[index] .. " outranks " .. order[index + 1]
			)
		end
		t.eq(PlayerStateService.overrideRank("Sprinting"), 0, "base states are not overrides")
		local derive = PlayerStateService.deriveState
		t.eq(derive(input("Vent", intent(false, true, false), 100, true, "Grabbed")), "Grabbed")
		t.eq(derive(input("OnFoot", intent(false, true, false), 100, true, "DownedCrawling")), "DownedCrawling")
	end,

	["exhaustion: set at empty with sprint held, cleared by release or a full meter"] = function(t: Expect)
		local update = PlayerStateService.updateExhausted
		local max = GameConfig.StaminaMax
		t.falsy(update(false, true, 40, max), "sprinting with stamina left")
		t.truthy(update(false, true, 0, max), "empty with sprint held")
		t.truthy(update(true, true, 30, max), "still held while regenerating")
		t.falsy(update(true, false, 30, max), "released")
		t.falsy(update(true, true, max, max), "full again")
		t.falsy(update(false, false, 0, max), "empty but not sprinting")
	end,

	["speeds and drains per state"] = function(t: Expect)
		local speed = PlayerStateService.walkSpeedFor
		t.eq(speed("Standing"), GameConfig.WalkSpeed)
		t.eq(speed("Sprinting"), GameConfig.SprintSpeed)
		t.eq(speed("Crouching"), GameConfig.CrouchSpeed)
		t.eq(speed("VentCrawling"), GameConfig.VentCrawlSpeed)
		t.eq(speed("VentScurrying"), GameConfig.VentScurrySpeed)
		t.eq(speed("DownedCrawling"), GameConfig.DownedMoveSpeed)
		t.eq(speed("Treading"), GameConfig.TreadSpeed)
		t.eq(speed("Freestyle"), GameConfig.FreestyleSpeed)
		t.eq(speed("Underwater"), GameConfig.UnderwaterSpeed)
		t.eq(speed("Parachuting"), GameConfig.WalkSpeed)
		local held: { Enums.MoveState } = { "Hiding", "Trapped", "Grabbed", "Scripted" }
		for _, state: Enums.MoveState in held do
			t.eq(speed(state), 0, state .. " holds still")
		end
		local drain = PlayerStateService.drainFor
		t.eq(drain("Sprinting"), GameConfig.StaminaSprintDrain)
		t.eq(drain("VentScurrying"), GameConfig.StaminaScurryDrain)
		t.eq(drain("Freestyle"), GameConfig.StaminaFreestyleDrain)
		t.eq(drain("Treading"), GameConfig.StaminaTreadDrain)
		local resting: { Enums.MoveState } = { "Standing", "Crouching", "VentCrawling", "DownedCrawling", "Underwater" }
		for _, state: Enums.MoveState in resting do
			t.eq(drain(state), 0, state .. " does not drain")
		end
		t.truthy(PlayerStateService.isMoving(4, 0))
		t.truthy(PlayerStateService.isMoving(0, 0.5), "input direction counts before the root speeds up")
		t.falsy(PlayerStateService.isMoving(3.9, 0.05))
	end,

	["meters: extrapolation clamps and snaps"] = function(t: Expect)
		local at = PlayerStateService.meterAt
		t.eq(at(50, -10, 100, 100, 102), 30)
		t.eq(at(50, -10, 100, 100, 110), 0, "clamped at empty")
		t.eq(at(50, 10, 100, 100, 110), 100, "clamped at full")
		t.eq(at(50, -10, 100, 100, 99), 50, "never extrapolates backwards")
		t.eq(at(50, -10, 100, 100, 104.99995), 0, "snaps onto empty")
		t.eq(at(99.9995, 0, 100, 100, 100), 100, "snaps onto full")
		t.eq(PlayerStateService.oxygenEmptyAt(70, -7, 10), 20)
		t.eq(PlayerStateService.oxygenEmptyAt(70, 0, 10), nil)
		t.eq(PlayerStateService.oxygenEmptyAt(0, -7, 10), nil, "already empty")
	end,

	["stamina plan: drain to empty, regen after the delay, rise to full"] = function(t: Expect)
		local plan = PlayerStateService.planStamina
		local max = GameConfig.StaminaMax
		local drain = GameConfig.StaminaSprintDrain
		local sprint = plan(80, 10, drain, nil, max)
		t.eq(sprint.rate, -drain)
		t.eq(sprint.event, "Empty")
		t.near(sprint.nextAt :: number, 10 + 80 / drain, 1e-9)
		local resting = plan(40, 10, 0, 9.5, max)
		t.eq(resting.rate, 0, "regen waits for the delay")
		t.eq(resting.event, "Regen")
		t.near(resting.nextAt :: number, 9.5 + GameConfig.StaminaRegenDelay, 1e-9)
		local regen = plan(40, 20, 0, 9.5, max)
		t.eq(regen.rate, GameConfig.StaminaRegen)
		t.eq(regen.event, "Full")
		t.near(regen.nextAt :: number, 20 + 60 / GameConfig.StaminaRegen, 1e-9)
		local fresh = plan(40, 20, 0, nil, max)
		t.eq(fresh.rate, GameConfig.StaminaRegen, "never drained: regen right away")
		local full = plan(max, 20, 0, 19, max)
		t.eq(full.rate, 0)
		t.eq(full.nextAt, nil)
		local treadingEmpty = plan(0, 20, GameConfig.StaminaTreadDrain, nil, max)
		t.eq(treadingEmpty.rate, 0, "an empty meter in a draining state stays flat")
		t.eq(treadingEmpty.nextAt, nil)
	end,

	["service: a vent sprint empties the meter, drops to crawling at 0, then regenerates"] = function(t: Expect)
		inRun(function(player: Player, humanoid: Humanoid, clock: FakeClock)
			local changes: { string } = {}
			local connection = PlayerStateService.MoveStateChanged:Connect(
				function(who: Player, new: Enums.MoveState, old: Enums.MoveState)
					if who == player then
						table.insert(changes, old .. ">" .. new)
					end
				end
			)
			t.eq(player:GetAttribute("MoveState"), "Standing")
			t.eq(humanoid.WalkSpeed, GameConfig.WalkSpeed, "server WalkSpeed applied")
			t.eq(player:GetAttribute("StaminaMax"), GameConfig.StaminaMax)
			PlayerStateService.SetMode(player, "Vent")
			t.eq(PlayerStateService.GetMode(player), "Vent")
			t.eq(player:GetAttribute("MoveState"), "VentCrawling")
			t.eq(humanoid.WalkSpeed, GameConfig.VentCrawlSpeed)
			t.truthy(PlayerStateService.SubmitIntent(player, { crouch = false, sprint = true, dive = false, seq = 1 }))
			t.eq(player:GetAttribute("MoveState"), "VentScurrying")
			t.eq(humanoid.WalkSpeed, GameConfig.VentScurrySpeed)
			local value, rate, at = meter(player)
			t.eq(value, GameConfig.StaminaMax)
			t.eq(rate, -GameConfig.StaminaScurryDrain)
			t.eq(at, 1000)
			clock.advance(2)
			t.near(PlayerStateService.GetStamina(player), 100 - 2 * GameConfig.StaminaScurryDrain, 1e-6)
			t.eq(player:GetAttribute("MoveState"), "VentScurrying")
			local emptyIn = GameConfig.StaminaMax / GameConfig.StaminaScurryDrain
			clock.advance(emptyIn - 2 + 0.01)
			t.eq(player:GetAttribute("MoveState"), "VentCrawling", "forced off the sprint at 0")
			t.eq(PlayerStateService.GetStamina(player), 0)
			value, rate, at = meter(player)
			t.eq(value, 0)
			t.eq(rate, 0, "flat during the regen delay")
			t.near(at, 1000 + emptyIn, 1e-6)
			t.truthy(PlayerStateService.IsExhausted(player), "sprint still held at 0")
			clock.advance(GameConfig.StaminaRegenDelay + 1)
			local _, regenRate = meter(player)
			t.eq(regenRate, GameConfig.StaminaRegen, "regenerating after the delay")
			t.eq(player:GetAttribute("MoveState"), "VentCrawling", "exhausted: holding sprint does not scurry")
			t.truthy(PlayerStateService.GetStamina(player) > 0)
			PlayerStateService.SubmitIntent(player, { crouch = false, sprint = false, dive = false, seq = 2 })
			t.falsy(PlayerStateService.IsExhausted(player), "released")
			PlayerStateService.SubmitIntent(player, { crouch = false, sprint = true, dive = false, seq = 3 })
			t.eq(player:GetAttribute("MoveState"), "VentScurrying", "a fresh press scurries again")
			PlayerStateService.SubmitIntent(player, { crouch = false, sprint = false, dive = false, seq = 4 })
			clock.advance(GameConfig.StaminaRegenDelay + GameConfig.StaminaMax / GameConfig.StaminaRegen + 1)
			value, rate = meter(player)
			t.eq(value, GameConfig.StaminaMax, "full")
			t.eq(rate, 0, "rate back to 0 at full")
			connection:Disconnect()
			t.eq(
				table.concat(changes, ","),
				"Standing>VentCrawling,VentCrawling>VentScurrying,VentScurrying>VentCrawling,"
					.. "VentCrawling>VentScurrying,VentScurrying>VentCrawling"
			)
		end)
	end,

	["service: intents apply in seq order and reset with a new character"] = function(t: Expect)
		inRun(function(player: Player)
			PlayerStateService.SetMode(player, "Vent")
			t.truthy(PlayerStateService.SubmitIntent(player, { crouch = false, sprint = true, dive = false, seq = 5 }))
			t.falsy(
				PlayerStateService.SubmitIntent(player, { crouch = false, sprint = false, dive = false, seq = 4 }),
				"older seq ignored"
			)
			t.falsy(
				PlayerStateService.SubmitIntent(player, { crouch = false, sprint = false, dive = false, seq = 5 }),
				"repeated seq ignored"
			)
			t.eq(player:GetAttribute("MoveState"), "VentScurrying")
			t.truthy(PlayerStateService.GetIntent(player).sprint)
			PlayerStateService.Init()
			CharacterService.CharacterSpawned:Fire(player, player.Character :: Model)
			t.falsy(PlayerStateService.GetIntent(player).sprint, "a new body starts neutral")
			t.eq(player:GetAttribute("MoveState"), "VentCrawling")
			t.truthy(
				PlayerStateService.SubmitIntent(player, { crouch = false, sprint = true, dive = false, seq = 1 }),
				"a restarted counter is accepted"
			)
		end)
	end,

	["service: override stack drives MoveState and WalkSpeed"] = function(t: Expect)
		inRun(function(player: Player, humanoid: Humanoid)
			PlayerStateService.PushOverride(player, "trap", "Trapped")
			t.eq(player:GetAttribute("MoveState"), "Trapped")
			t.eq(humanoid.WalkSpeed, 0)
			PlayerStateService.PushOverride(player, "LifeState", "DownedCrawling")
			t.eq(player:GetAttribute("MoveState"), "Trapped", "Trapped outranks DownedCrawling")
			PlayerStateService.PushOverride(player, "cutscene", "Scripted")
			t.eq(player:GetAttribute("MoveState"), "Scripted")
			PlayerStateService.PushOverride(player, "bogus", "Sprinting")
			t.eq(PlayerStateService.GetOverride(player), "Scripted", "a base state is refused as an override")
			PlayerStateService.PopOverride(player, "cutscene")
			t.eq(player:GetAttribute("MoveState"), "Trapped")
			PlayerStateService.PopOverride(player, "trap")
			t.eq(player:GetAttribute("MoveState"), "DownedCrawling")
			t.eq(humanoid.WalkSpeed, GameConfig.DownedMoveSpeed)
			PlayerStateService.PopOverride(player, "LifeState")
			PlayerStateService.PopOverride(player, "LifeState")
			t.eq(player:GetAttribute("MoveState"), "Standing")
			t.eq(humanoid.WalkSpeed, GameConfig.WalkSpeed)
			PlayerStateService.SetMode(player, "Swim")
			t.eq(player:GetAttribute("MoveState"), "Treading")
			PlayerStateService.SetMode(player, "Ladder" :: any)
			t.eq(PlayerStateService.GetMode(player), "Swim", "unknown modes are refused")
		end)
	end,

	["service: spends delay regen, refills and the syringe fill the meter, oxygen depletion fires"] = function(
		t: Expect
	)
		inRun(function(player: Player, _humanoid: Humanoid, clock: FakeClock)
			PlayerStateService.Init()
			PlayerStateService.AddStamina(player, -30)
			local value, rate = meter(player)
			t.eq(value, 70)
			t.eq(rate, 0, "a spend restarts the regen delay")
			clock.advance(GameConfig.StaminaRegenDelay + 0.5)
			t.near(PlayerStateService.GetStamina(player), 70 + 0.5 * GameConfig.StaminaRegen, 1e-6)
			PlayerStateService.RefillStamina(player)
			t.eq(PlayerStateService.GetStamina(player), GameConfig.StaminaMax)
			PlayerStateService.AddStamina(player, -60)
			LoadoutService.SyringeUsed:Fire(player, "Stamina")
			t.eq(PlayerStateService.GetStamina(player), GameConfig.StaminaMax, "the stamina syringe refills")

			local depleted = 0
			local connection = PlayerStateService.OxygenDepleted:Connect(function(who: Player)
				if who == player then
					depleted += 1
				end
			end)
			t.eq(player:GetAttribute("OxygenMax"), GameConfig.OxygenMax)
			PlayerStateService.SetOxygenRate(player, -GameConfig.OxygenDrain)
			t.eq(player:GetAttribute("OxygenRate"), -GameConfig.OxygenDrain)
			clock.advance(GameConfig.OxygenMax / GameConfig.OxygenDrain - 1)
			t.eq(depleted, 0)
			t.near(PlayerStateService.GetOxygen(player), GameConfig.OxygenDrain, 1e-6)
			PlayerStateService.AddOxygen(player, 7)
			clock.advance(1.5)
			t.eq(depleted, 0, "the breath pushed the crossing back")
			clock.advance(1)
			t.eq(depleted, 1, "OxygenDepleted at 0")
			t.eq(PlayerStateService.GetOxygen(player), 0)
			clock.advance(10)
			t.eq(depleted, 1, "fires once per crossing")
			connection:Disconnect()
		end)
	end,

	["service: outside a run (or not playing) the baseline holds"] = function(t: Expect)
		local player = fakePlayer()
		PlayerStateService.Refresh(player)
		t.eq(player:GetAttribute("MoveState"), "Standing")
		t.eq(player:GetAttribute("Stamina"), GameConfig.StaminaMax)
		t.eq(player:GetAttribute("StaminaRate"), 0)
		t.eq(player:GetAttribute("Oxygen"), GameConfig.OxygenMax)
		t.eq(player:GetAttribute("OxygenRate"), 0)
		PlayerStateService.SubmitIntent(player, { crouch = true, sprint = false, dive = false, seq = 1 })
		t.eq(player:GetAttribute("MoveState"), "Standing", "no posture outside a run")
		PlayerStateService.AddStamina(player, -40)
		t.eq(PlayerStateService.GetStamina(player), GameConfig.StaminaMax, "meters do not run in the lobby")
		PlayerStateService.PushOverride(player, "cutscene", "Scripted")
		t.eq(player:GetAttribute("MoveState"), "Scripted", "overrides still apply")
		PlayerStateService.PopOverride(player, "cutscene")
		PlayerStateService.OnPlayerRemoving(player)

		inRun(function(runner: Player)
			PlayerStateService.SetMode(runner, "Vent")
			PlayerStateService.SubmitIntent(runner, { crouch = false, sprint = true, dive = false, seq = 1 })
			t.eq(runner:GetAttribute("StaminaRate"), -GameConfig.StaminaScurryDrain)
			runner:SetAttribute("LifeState", "Dead")
			PlayerStateService.Refresh(runner)
			t.eq(runner:GetAttribute("StaminaRate"), 0, "the dead are held at the baseline")
			t.eq(runner:GetAttribute("Stamina"), GameConfig.StaminaMax)
			t.eq(runner:GetAttribute("MoveState"), "Standing")
		end)
	end,

	["look: quantized relay round-trips and fires LookChanged"] = function(t: Expect)
		local player = fakePlayer()
		local seen: { number } = {}
		local connection = PlayerStateService.LookChanged:Connect(function(who: Player, yaw: number, pitch: number)
			if who == player then
				table.insert(seen, yaw)
				table.insert(seen, pitch)
			end
		end)
		t.eq(select("#", PlayerStateService.GetLook(player)), 2)
		local yaw0, pitch0 = PlayerStateService.GetLook(player)
		t.eq(yaw0, 0)
		t.eq(pitch0, 0)
		local step = math.pi / 32767
		for _, angle in { 0, 1.2345, -2.9, math.pi * 0.999, math.rad(-80) } do
			local quantized = MathUtil.quantizeAngle(angle)
			PlayerStateService.SubmitLook(player, quantized, MathUtil.quantizeAngle(angle / 2))
			local yaw, pitch = PlayerStateService.GetLook(player)
			t.near(yaw, angle, step, "yaw " .. angle)
			t.near(pitch, angle / 2, step, "pitch " .. angle)
		end
		local count = #seen
		PlayerStateService.SubmitLook(
			player,
			MathUtil.quantizeAngle(math.rad(-80)),
			MathUtil.quantizeAngle(math.rad(-40))
		)
		t.eq(#seen, count, "an unchanged look fires nothing")
		t.eq(count, 10, "five changes, two angles each")
		connection:Disconnect()
		PlayerStateService.OnPlayerRemoving(player)
	end,

	["look: broadcasts batch only changed samples, keyframes resend all"] = function(t: Expect)
		local collect = PlayerStateService.collectLookSamples
		local sent: { [number]: PlayerStateService.QuantizedLook } = {}
		local first = collect({ [3] = { yaw = 10, pitch = -5 }, [1] = { yaw = 0, pitch = 0 } }, sent, false)
		t.eq(#first, 2, "everything is new")
		t.eq(first[1].userId, 1, "sorted by userId")
		t.eq(first[2].yaw, 10)
		t.eq(#collect({ [3] = { yaw = 10, pitch = -5 }, [1] = { yaw = 0, pitch = 0 } }, sent, false), 0, "no change")
		local moved = collect({ [3] = { yaw = 11, pitch = -5 }, [1] = { yaw = 0, pitch = 0 } }, sent, false)
		t.eq(#moved, 1)
		t.eq(moved[1].userId, 3)
		t.eq(moved[1].yaw, 11)
		t.eq(#collect({ [3] = { yaw = 11, pitch = -5 }, [1] = { yaw = 0, pitch = 0 } }, sent, true), 2, "keyframe")
		t.eq(#collect({ [1] = { yaw = 0, pitch = 0 } }, sent, false), 0, "a departed user sends nothing")
		t.eq(sent[3], nil, "and is forgotten")
		t.eq(
			#collect({ [3] = { yaw = 11, pitch = -5 }, [1] = { yaw = 0, pitch = 0 } }, sent, false),
			1,
			"rejoin resends"
		)
	end,
}
