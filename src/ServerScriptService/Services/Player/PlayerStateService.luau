--!strict
-- PlayerStateService: the server's MoveState authority, the Stamina and Oxygen meters, and the LookRelay fan-out.
-- The only writer of Player.MoveState, the Stamina / Oxygen meter attributes and (server side) Humanoid.WalkSpeed.
--
-- Intents. MoveIntent carries the full intended posture {crouch, sprint, dive, seq} (level-encoded); a message whose
-- seq is not newer than the last one accepted from that player is ignored. A fresh character starts from a neutral
-- intent and accepts any seq again (clients may restart their counter per character).
--
-- MoveState (deriveState, pure). A held override wins, highest first: Scripted > Grabbed > Trapped > Hiding >
-- Parachuting > DownedCrawling (PushOverride / PopOverride, keyed by token; LifeStateService holds "LifeState" →
-- DownedCrawling). Otherwise the base mode decides (SetMode; OnFoot by default, P4 vents, P7 swimming), where
-- "can sprint" = sprint ∧ stamina > 0 ∧ not exhausted:
--   OnFoot  Crouching if crouch; Sprinting if can sprint ∧ moving (observed horizontal root speed ≥ 4 studs/s, or
--           Humanoid.MoveDirection longer than 0.1); else Standing.
--   Vent    VentScurrying if can sprint, else VentCrawling.
--   Swim    Underwater if dive; Freestyle if can sprint; else Treading.
-- Exhaustion (updateExhausted, pure) starts when stamina is empty while sprint is held and ends when sprint is released
-- or stamina is full. Without it a player who keeps holding sprint at 0 would re-enter a zero-length sprint (and
-- pulse Sprint-tier noise) every time regen begins; with it every transition of the rule happens at a moment the
-- server already handles (an intent, a meter crossing), so a client that mirrors deriveState / updateExhausted from
-- the replicated meter agrees with the server.
-- MoveState is written only when it changes (MoveStateChanged fires then), together with Humanoid.WalkSpeed from
-- GameConfig (DownedCrawling = DownedMoveSpeed; Hiding / Trapped / Grabbed / Scripted = 0; Parachuting = WalkSpeed).
-- Re-derived on every intent, mode or override change, life-state change, meter crossing, character spawn, and when
-- the 10 Hz motion sampler sees the moving flag flip.
--
-- Stamina (Types.Meter, max GameConfig.StaminaMax). Sprinting / VentScurrying / Freestyle / Treading drain at their
-- GameConfig rate; StaminaRegenDelay seconds after draining stops (or after a spend through AddStamina) it regenerates
-- at StaminaRegen until full. Each linear segment is written once (value, rate, at); the next crossing (empty, regen
-- start, full) is scheduled from the extrapolation, so hitting 0 drops a sprint the moment it happens.
-- Oxygen (max GameConfig.OxygenMax) sits full at rate 0 until P7 drives it with SetOxygenRate / AddOxygen; reaching
-- 0 fires OxygenDepleted (LifeStateService turns that into a Down).
-- The meters only run for run participants who are Alive or Downed while the run is live (Deploying / InRun).
-- Everyone else (lobby, late joiners, the dead) is held at the baseline: overrides still apply, else Standing, and
-- both meters full at rate 0.
--
-- Look. LookRelay {yaw, pitch} (int16-quantized radians) is stored per player (GetLook, LookChanged). At
-- GameConfig.ServerTickHz the server broadcasts one batched LookBroadcast {samples = {{userId, yaw, pitch}}} (still
-- quantized) to every client with only the samples that changed since the previous broadcast, plus a full keyframe
-- every LookKeyframeSeconds so a dropped unreliable packet or a late joiner catches up.
--
-- Syringe. LoadoutService.SyringeUsed with mode "Stamina" refills the stamina meter.
--
-- Pure rules (tests/Specs/PlayerState.spec.luau): deriveState, updateExhausted, resolveOverride, walkSpeedFor,
-- drainFor, isMoving, meterAt, planStamina, oxygenEmptyAt, acceptSeq, collectLookSamples. SetClock swaps the time source (specs drive a
-- fake clock through the meter crossings).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)

local LoadoutService = require(script.Parent.LoadoutService)

local log = Log.new("PlayerState")

local P = Attributes.Player

export type Mode = "OnFoot" | "Vent" | "Swim"

export type Intent = { crouch: boolean, sprint: boolean, dive: boolean }

export type DeriveInput = {
	mode: Mode,
	override: Enums.MoveState?, -- the winning override (resolveOverride), nil when none is held
	intent: Intent,
	stamina: number,
	exhausted: boolean, -- updateExhausted for this stamina and intent
	moving: boolean,
}

export type MeterEvent = "Empty" | "Regen" | "Full"

-- One linear meter segment starting now: `rate` per second until `nextAt` (server time), when `event` happens.
export type MeterPlan = { rate: number, nextAt: number?, event: MeterEvent? }

-- Time source and scheduler. The default reads Workspace:GetServerTimeNow() and schedules with task.delay.
export type Clock = {
	now: () -> number,
	delay: (seconds: number, callback: () -> ()) -> thread,
	cancel: (thread: thread) -> (),
}

-- A look as LookRelay carries it: int16-quantized radians (MathUtil.quantizeAngle).
export type QuantizedLook = { yaw: number, pitch: number }

type MotionSample = { position: Vector3, time: number }

type Record = {
	player: Player,
	lifeStateConnection: RBXScriptConnection?,
	mode: Mode,
	overrides: { [string]: Enums.MoveState },
	intent: Intent,
	lastSeq: number?,
	moving: boolean,
	exhausted: boolean,
	state: Enums.MoveState,
	active: boolean,
	-- Stamina segment as last written: `staminaValue` at `staminaAt`, changing at `staminaRate`.
	staminaValue: number,
	staminaRate: number,
	staminaAt: number,
	staminaDirty: boolean, -- a discrete change is waiting to be written
	drainEndedAt: number?, -- when stamina last stopped draining (regen starts StaminaRegenDelay later)
	staminaTimer: thread?,
	staminaTimerAt: number?,
	-- Oxygen segment as last written; the rate is whatever its owner (P7) set.
	oxygenValue: number,
	oxygenRate: number,
	oxygenAt: number,
	oxygenTimer: thread?,
	look: QuantizedLook?,
	samples: { MotionSample },
	speed: number,
}

local MODES: { Mode } = { "OnFoot", "Vent", "Swim" }

-- Highest priority first.
local OVERRIDE_PRIORITY: { Enums.MoveState } =
	{ "Scripted", "Grabbed", "Trapped", "Hiding", "Parachuting", "DownedCrawling" }

local OVERRIDE_RANK: { [string]: number } = {}
for index, state in OVERRIDE_PRIORITY do
	OVERRIDE_RANK[state] = #OVERRIDE_PRIORITY - index + 1
end

local WALK_SPEED: { [string]: number } = {
	Standing = GameConfig.WalkSpeed,
	Sprinting = GameConfig.SprintSpeed,
	Crouching = GameConfig.CrouchSpeed,
	VentCrawling = GameConfig.VentCrawlSpeed,
	VentScurrying = GameConfig.VentScurrySpeed,
	DownedCrawling = GameConfig.DownedMoveSpeed,
	Treading = GameConfig.TreadSpeed,
	Freestyle = GameConfig.FreestyleSpeed,
	Underwater = GameConfig.UnderwaterSpeed,
	Hiding = 0,
	Trapped = 0,
	Grabbed = 0,
	Parachuting = GameConfig.WalkSpeed,
	Scripted = 0,
}

local DRAIN: { [string]: number } = {
	Sprinting = GameConfig.StaminaSprintDrain,
	VentScurrying = GameConfig.StaminaScurryDrain,
	Freestyle = GameConfig.StaminaFreestyleDrain,
	Treading = GameConfig.StaminaTreadDrain,
}

local PLAYING: { [string]: boolean } = { Alive = true, Downed = true }

local STAMINA_MAX = GameConfig.StaminaMax
local OXYGEN_MAX = GameConfig.OxygenMax
local MOVING_SPEED = 4 -- observed horizontal studs/s that count as moving
local MOVING_DIRECTION = 0.1 -- Humanoid.MoveDirection magnitude that counts as moving
local METER_EPSILON = 1e-3 -- meter values this close to an end snap onto it
local TIMER_EPSILON = 1e-6 -- a re-planned crossing this close to the scheduled one keeps the timer
local SPEED_WINDOW = 3 -- motion samples averaged for the observed speed (about 0.2 s at 10 Hz)
local SPEED_STALE_SECONDS = 1 -- a gap longer than this between samples restarts the window
local LOOK_KEYFRAME_SECONDS = 2
local NEUTRAL_INTENT: Intent = table.freeze({ crouch = false, sprint = false, dive = false })
local BASELINE_STATE: Enums.MoveState = "Standing"

local PlayerStateService = {}

PlayerStateService.Name = "PlayerStateService"
PlayerStateService.OverridePriority = table.freeze(table.clone(OVERRIDE_PRIORITY))
PlayerStateService.Modes = table.freeze(table.clone(MODES))
PlayerStateService.OverrideToken = table.freeze({ LifeState = "LifeState" })
PlayerStateService.MovingSpeed = MOVING_SPEED
PlayerStateService.LookKeyframeSeconds = LOOK_KEYFRAME_SECONDS

local moveStateChanged: Signal.Signal<Player, Enums.MoveState, Enums.MoveState> = Signal.new()
local lookChanged: Signal.Signal<Player, number, number> = Signal.new()
local oxygenDepleted: Signal.Signal<Player> = Signal.new()

-- (player, new, old) after the server-confirmed MoveState changed.
PlayerStateService.MoveStateChanged = moveStateChanged
-- (player, yaw, pitch) in radians whenever a LookRelay changed the stored look.
PlayerStateService.LookChanged = lookChanged
-- The player's oxygen meter just reached 0.
PlayerStateService.OxygenDepleted = oxygenDepleted

local realClock: Clock = {
	now = function(): number
		return Workspace:GetServerTimeNow()
	end,
	delay = function(seconds: number, callback: () -> ()): thread
		return task.delay(seconds, callback)
	end,
	cancel = function(thread: thread)
		if coroutine.status(thread) == "suspended" then
			task.cancel(thread)
		end
	end,
}

local clock: Clock = realClock
local serviceTrove = Trove.new()
local records: { [Player]: Record } = {}
local participants: { [Player]: boolean } = {}
local runLive = false -- a run exists (BeginRun .. EndRun) and its phase is Deploying / InRun
local sentLooks: { [number]: QuantizedLook } = {}
local lastKeyframeAt = -math.huge
local initialized = false

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/PlayerState.spec.luau)
--------------------------------------------------------------------------------

-- Priority of an override state (higher wins); 0 for states that are not overrides.
function PlayerStateService.overrideRank(state: string): number
	return OVERRIDE_RANK[state] or 0
end

-- The winning override of a token -> state table, or nil when none is held.
function PlayerStateService.resolveOverride(overrides: { [string]: Enums.MoveState }): Enums.MoveState?
	local best: Enums.MoveState? = nil
	local bestRank = 0
	for _, state: Enums.MoveState in overrides do
		local rank = OVERRIDE_RANK[state] or 0
		if rank > bestRank then
			best = state
			bestRank = rank
		end
	end
	return best
end

-- The MoveState for a posture (see the header for the rules).
function PlayerStateService.deriveState(input: DeriveInput): Enums.MoveState
	local override: Enums.MoveState? = input.override
	if override then
		return override
	end
	local intent = input.intent
	local canSprint = intent.sprint and input.stamina > 0 and not input.exhausted
	local state: Enums.MoveState
	if input.mode == "Vent" then
		state = if canSprint then "VentScurrying" else "VentCrawling"
	elseif input.mode == "Swim" then
		if intent.dive then
			state = "Underwater"
		elseif canSprint then
			state = "Freestyle"
		else
			state = "Treading"
		end
	elseif intent.crouch then
		state = "Crouching"
	elseif canSprint and input.moving then
		state = "Sprinting"
	else
		state = "Standing"
	end
	return state
end

-- The exhaustion latch after observing `stamina` (of `max`) with sprint held or not: set while sprint is held at an
-- empty meter, kept while sprint stays held, cleared by releasing sprint or by a full meter.
function PlayerStateService.updateExhausted(
	exhausted: boolean,
	sprintHeld: boolean,
	stamina: number,
	max: number
): boolean
	if not sprintHeld or stamina >= max then
		return false
	end
	if stamina <= 0 then
		return true
	end
	return exhausted
end

-- Humanoid.WalkSpeed for a MoveState.
function PlayerStateService.walkSpeedFor(state: Enums.MoveState): number
	return WALK_SPEED[state] or GameConfig.WalkSpeed
end

-- Stamina drained per second in a MoveState (0 for states that do not drain).
function PlayerStateService.drainFor(state: Enums.MoveState): number
	return DRAIN[state] or 0
end

-- Whether a character counts as moving for the sprint rule.
function PlayerStateService.isMoving(observedSpeed: number, moveDirectionMagnitude: number): boolean
	return observedSpeed >= MOVING_SPEED or moveDirectionMagnitude > MOVING_DIRECTION
end

-- A meter's value at `now`: `value` at `at` changing at `rate`, clamped to [0, max]; values within METER_EPSILON of
-- either end snap onto it.
function PlayerStateService.meterAt(value: number, rate: number, at: number, max: number, now: number): number
	local current = math.clamp(value + rate * math.max(0, now - at), 0, max)
	if current < METER_EPSILON then
		return 0
	elseif current > max - METER_EPSILON then
		return max
	end
	return current
end

-- The stamina segment starting at `now` from `value`, for a state draining `drain` per second, when draining last
-- stopped at `drainEndedAt` (nil = never drained, regen is due at once).
function PlayerStateService.planStamina(
	value: number,
	now: number,
	drain: number,
	drainEndedAt: number?,
	max: number
): MeterPlan
	if drain > 0 then
		if value <= METER_EPSILON then
			-- Empty in a draining state with nothing below it (Treading): flat at 0.
			return { rate = 0, nextAt = nil, event = nil }
		end
		return { rate = -drain, nextAt = now + value / drain, event = "Empty" }
	end
	local regen = GameConfig.StaminaRegen
	if value >= max - METER_EPSILON or regen <= 0 then
		return { rate = 0, nextAt = nil, event = nil }
	end
	local regenAt = if drainEndedAt ~= nil then drainEndedAt + GameConfig.StaminaRegenDelay else now
	if regenAt > now then
		return { rate = 0, nextAt = regenAt, event = "Regen" }
	end
	return { rate = regen, nextAt = now + (max - value) / regen, event = "Full" }
end

-- Server time an oxygen meter at `value` changing at `rate` reaches 0 (nil when it never does).
function PlayerStateService.oxygenEmptyAt(value: number, rate: number, now: number): number?
	if rate < 0 and value > METER_EPSILON then
		return now + value / -rate
	end
	return nil
end

-- Whether a MoveIntent numbered `seq` is newer than the last accepted one.
function PlayerStateService.acceptSeq(lastSeq: number?, seq: number): boolean
	return lastSeq == nil or seq > lastSeq
end

-- The LookBroadcast samples for `current` (userId -> quantized look): every look that differs from `sent` (or all of
-- them when `full`), sorted by userId. Updates `sent` to what this broadcast carries and forgets users that left.
function PlayerStateService.collectLookSamples(
	current: { [number]: QuantizedLook },
	sent: { [number]: QuantizedLook },
	full: boolean
): { Types.LookSample }
	local samples: { Types.LookSample } = {}
	for userId, look in current do
		local previous = sent[userId]
		if full or previous == nil or previous.yaw ~= look.yaw or previous.pitch ~= look.pitch then
			table.insert(samples, { userId = userId, yaw = look.yaw, pitch = look.pitch })
			sent[userId] = { yaw = look.yaw, pitch = look.pitch }
		end
	end
	for userId in table.clone(sent) do
		if current[userId] == nil then
			sent[userId] = nil
		end
	end
	table.sort(samples, function(a: Types.LookSample, b: Types.LookSample): boolean
		return a.userId < b.userId
	end)
	return samples
end

--------------------------------------------------------------------------------
-- Records
--------------------------------------------------------------------------------

local function isMode(value: unknown): boolean
	return type(value) == "string" and table.find(MODES, value :: any) ~= nil
end

local function lifePlaying(player: Player): boolean
	local value = player:GetAttribute(P.LifeState)
	return type(value) == "string" and PLAYING[value] == true
end

local function isActive(player: Player): boolean
	return runLive and participants[player] == true and lifePlaying(player)
end

local function cancelTimer(thread: thread?)
	if thread then
		clock.cancel(thread)
	end
end

local function writeBaselineMeters(record: Record, now: number)
	local player = record.player
	record.staminaValue, record.staminaRate, record.staminaAt = STAMINA_MAX, 0, now
	record.staminaDirty = false
	record.drainEndedAt = nil
	record.oxygenValue, record.oxygenRate, record.oxygenAt = OXYGEN_MAX, 0, now
	cancelTimer(record.staminaTimer)
	record.staminaTimer, record.staminaTimerAt = nil, nil
	cancelTimer(record.oxygenTimer)
	record.oxygenTimer = nil
	Attributes.set(player, P.StaminaMax, STAMINA_MAX)
	Attributes.writeMeter(player, P.Stamina, P.StaminaRate, P.StaminaAt, STAMINA_MAX, 0, now)
	Attributes.set(player, P.OxygenMax, OXYGEN_MAX)
	Attributes.writeMeter(player, P.Oxygen, P.OxygenRate, P.OxygenAt, OXYGEN_MAX, 0, now)
end

local function applyWalkSpeed(record: Record)
	local humanoid = Instances.characterHumanoid(record.player)
	if not humanoid then
		return
	end
	local speed = PlayerStateService.walkSpeedFor(record.state)
	if humanoid.WalkSpeed ~= speed then
		humanoid.WalkSpeed = speed
	end
end

local function setState(record: Record, state: Enums.MoveState, now: number)
	local previous: Enums.MoveState = record.state
	-- A boolean, not a direct comparison: refining one union by another widens both to string.
	local changed = state ~= previous
	if not changed then
		return
	end
	if PlayerStateService.drainFor(previous) > 0 and PlayerStateService.drainFor(state) <= 0 then
		record.drainEndedAt = now
	end
	record.state = state
	Attributes.set(record.player, P.MoveState, state)
	moveStateChanged:Fire(record.player, state, previous)
end

local refresh: (record: Record) -> ()

local function scheduleStamina(record: Record, at: number?)
	local scheduled = record.staminaTimerAt
	if at ~= nil and scheduled ~= nil and math.abs(at - scheduled) <= TIMER_EPSILON and record.staminaTimer then
		return
	end
	cancelTimer(record.staminaTimer)
	record.staminaTimer, record.staminaTimerAt = nil, nil
	if at == nil then
		return
	end
	record.staminaTimerAt = at
	record.staminaTimer = clock.delay(math.max(0, at - clock.now()), function()
		record.staminaTimer, record.staminaTimerAt = nil, nil
		if records[record.player] == record then
			refresh(record)
		end
	end)
end

local function staminaNow(record: Record, now: number): number
	return PlayerStateService.meterAt(record.staminaValue, record.staminaRate, record.staminaAt, STAMINA_MAX, now)
end

local function oxygenNow(record: Record, now: number): number
	return PlayerStateService.meterAt(record.oxygenValue, record.oxygenRate, record.oxygenAt, OXYGEN_MAX, now)
end

local function planAndWriteStamina(record: Record, now: number)
	local value = staminaNow(record, now)
	local plan = PlayerStateService.planStamina(
		value,
		now,
		PlayerStateService.drainFor(record.state),
		record.drainEndedAt,
		STAMINA_MAX
	)
	if plan.rate ~= record.staminaRate or record.staminaDirty then
		record.staminaValue, record.staminaRate, record.staminaAt = value, plan.rate, now
		record.staminaDirty = false
		Attributes.writeMeter(record.player, P.Stamina, P.StaminaRate, P.StaminaAt, value, plan.rate, now)
	end
	scheduleStamina(record, plan.nextAt)
end

local function scheduleOxygen(record: Record, now: number)
	cancelTimer(record.oxygenTimer)
	record.oxygenTimer = nil
	local emptyAt = PlayerStateService.oxygenEmptyAt(oxygenNow(record, now), record.oxygenRate, now)
	if emptyAt == nil then
		return
	end
	record.oxygenTimer = clock.delay(math.max(0, emptyAt - now), function()
		record.oxygenTimer = nil
		if records[record.player] ~= record or not record.active then
			return
		end
		if oxygenNow(record, clock.now()) <= 0 then
			oxygenDepleted:Fire(record.player)
		else
			scheduleOxygen(record, clock.now())
		end
	end)
end

local function writeOxygen(record: Record, value: number, rate: number, now: number)
	record.oxygenValue, record.oxygenRate, record.oxygenAt = value, rate, now
	Attributes.writeMeter(record.player, P.Oxygen, P.OxygenRate, P.OxygenAt, value, rate, now)
	scheduleOxygen(record, now)
end

refresh = function(record: Record)
	local player = record.player
	local now = clock.now()
	local active = isActive(player)
	local override: Enums.MoveState? = PlayerStateService.resolveOverride(record.overrides)
	if not active then
		if record.active then
			record.active = false
			writeBaselineMeters(record, now)
		end
		record.exhausted = false
		setState(record, override or BASELINE_STATE, now)
		applyWalkSpeed(record)
		return
	end
	-- An inactive record always holds the baseline (full meters at rate 0), so activation starts from there.
	record.active = true
	local stamina = staminaNow(record, now)
	record.exhausted = PlayerStateService.updateExhausted(record.exhausted, record.intent.sprint, stamina, STAMINA_MAX)
	local state: Enums.MoveState = PlayerStateService.deriveState({
		mode = record.mode,
		override = override,
		intent = record.intent,
		stamina = stamina,
		exhausted = record.exhausted,
		moving = record.moving,
	})
	setState(record, state, now)
	applyWalkSpeed(record)
	planAndWriteStamina(record, now)
end

local function newRecord(player: Player): Record
	local now = clock.now()
	local record: Record = {
		player = player,
		lifeStateConnection = nil,
		mode = "OnFoot",
		overrides = {},
		intent = table.clone(NEUTRAL_INTENT),
		lastSeq = nil,
		moving = false,
		exhausted = false,
		state = BASELINE_STATE,
		active = false,
		staminaValue = STAMINA_MAX,
		staminaRate = 0,
		staminaAt = now,
		staminaDirty = false,
		drainEndedAt = nil,
		staminaTimer = nil,
		staminaTimerAt = nil,
		oxygenValue = OXYGEN_MAX,
		oxygenRate = 0,
		oxygenAt = now,
		oxygenTimer = nil,
		look = nil,
		samples = {},
		speed = 0,
	}
	records[player] = record
	Attributes.set(player, P.MoveState, BASELINE_STATE)
	writeBaselineMeters(record, now)
	record.lifeStateConnection = player:GetAttributeChangedSignal(P.LifeState):Connect(function()
		if records[player] == record then
			refresh(record)
		end
	end)
	return record
end

local function recordOf(player: Player): Record
	return records[player] or newRecord(player)
end

local function forget(player: Player)
	local record = records[player]
	if not record then
		return
	end
	records[player] = nil
	cancelTimer(record.staminaTimer)
	cancelTimer(record.oxygenTimer)
	local connection = record.lifeStateConnection
	record.lifeStateConnection = nil
	if connection then
		connection:Disconnect()
	end
end

-- Back to the run-independent defaults: on foot, no overrides, neutral intent.
local function resetForRun(record: Record)
	record.mode = "OnFoot"
	table.clear(record.overrides)
	record.intent = table.clone(NEUTRAL_INTENT)
	record.lastSeq = nil
	record.moving = false
	record.exhausted = false
	table.clear(record.samples)
	record.speed = 0
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Replaces the time source (specs pass a fake clock; nil restores server time + task.delay).
function PlayerStateService.SetClock(fake: Clock?)
	clock = fake or realClock
end

-- Re-derives `player`'s MoveState and meters now (LifeStateService calls this after every life-state write).
function PlayerStateService.Refresh(player: Player)
	refresh(recordOf(player))
end

function PlayerStateService.GetMoveState(player: Player): Enums.MoveState
	local record = records[player]
	return if record then record.state else BASELINE_STATE
end

-- Sets the base locomotion mode (P4 vents, P7 swimming). Unknown modes are refused.
function PlayerStateService.SetMode(player: Player, mode: Mode)
	if not isMode(mode) then
		log.warn("SetMode(%s): unknown mode %s", player.Name, tostring(mode))
		return
	end
	local record = recordOf(player)
	if record.mode == mode then
		return
	end
	record.mode = mode
	table.clear(record.samples)
	refresh(record)
end

function PlayerStateService.GetMode(player: Player): Mode
	local record = records[player]
	return if record then record.mode else "OnFoot"
end

-- Holds `state` for `player` under `token` (replacing that token's previous state). Only override states
-- (OverridePriority) are accepted.
function PlayerStateService.PushOverride(player: Player, token: string, state: Enums.MoveState)
	if type(token) ~= "string" or token == "" then
		log.warn("PushOverride(%s): invalid token %s", player.Name, tostring(token))
		return
	end
	if PlayerStateService.overrideRank(state) <= 0 then
		log.warn("PushOverride(%s, %s): %s is not an override state", player.Name, token, tostring(state))
		return
	end
	local record = recordOf(player)
	if record.overrides[token] == state then
		return
	end
	record.overrides[token] = state
	refresh(record)
end

-- Releases the override held under `token` (no-op when none is).
function PlayerStateService.PopOverride(player: Player, token: string)
	local record = records[player]
	if not record or record.overrides[token] == nil then
		return
	end
	record.overrides[token] = nil
	refresh(record)
end

-- The winning override for `player` (nil when none is held).
function PlayerStateService.GetOverride(player: Player): Enums.MoveState?
	local record = records[player]
	return if record then PlayerStateService.resolveOverride(record.overrides) else nil
end

-- Applies a MoveIntent (the Net handler's body). Returns false when the message was older than the last one.
function PlayerStateService.SubmitIntent(player: Player, payload: Types.MoveIntentPayload): boolean
	local record = recordOf(player)
	if not PlayerStateService.acceptSeq(record.lastSeq, payload.seq) then
		return false
	end
	record.lastSeq = payload.seq
	local intent = record.intent
	if intent.crouch == payload.crouch and intent.sprint == payload.sprint and intent.dive == payload.dive then
		return true
	end
	record.intent = { crouch = payload.crouch, sprint = payload.sprint, dive = payload.dive }
	refresh(record)
	return true
end

-- Whether `player` emptied their stamina with sprint held and has not released sprint (or refilled) since.
function PlayerStateService.IsExhausted(player: Player): boolean
	local record = records[player]
	return record ~= nil and record.exhausted
end

function PlayerStateService.GetIntent(player: Player): Intent
	local record = records[player]
	return table.clone(if record then record.intent else NEUTRAL_INTENT)
end

function PlayerStateService.GetStamina(player: Player): number
	local record = records[player]
	return if record then staminaNow(record, clock.now()) else STAMINA_MAX
end

-- Adds `delta` (negative spends) to `player`'s stamina. A spend restarts the regen delay. Only while the meters run.
function PlayerStateService.AddStamina(player: Player, delta: number)
	if not MathUtil.isFinite(delta) or delta == 0 then
		return
	end
	local record = recordOf(player)
	if not isActive(player) then
		return
	end
	local now = clock.now()
	record.staminaValue = math.clamp(staminaNow(record, now) + delta, 0, STAMINA_MAX)
	record.staminaAt = now
	record.staminaDirty = true
	if delta < 0 then
		record.drainEndedAt = now
	end
	refresh(record)
end

-- Fills `player`'s stamina (the Adrenaline Syringe's stamina mode). Only while the meters run.
function PlayerStateService.RefillStamina(player: Player)
	local record = recordOf(player)
	if not isActive(player) then
		return
	end
	record.staminaValue = STAMINA_MAX
	record.staminaAt = clock.now()
	record.staminaDirty = true
	refresh(record)
end

function PlayerStateService.GetOxygen(player: Player): number
	local record = records[player]
	return if record then oxygenNow(record, clock.now()) else OXYGEN_MAX
end

-- Sets the oxygen meter's rate per second (negative drains, 0 holds). P7 drives drowning with it. Only while the
-- meters run.
function PlayerStateService.SetOxygenRate(player: Player, rate: number)
	if not MathUtil.isFinite(rate) then
		return
	end
	local record = recordOf(player)
	if not isActive(player) or record.oxygenRate == rate then
		return
	end
	local now = clock.now()
	writeOxygen(record, oxygenNow(record, now), rate, now)
end

-- Adds `delta` to `player`'s oxygen (a breath at the surface, a struggle cost). Only while the meters run.
function PlayerStateService.AddOxygen(player: Player, delta: number)
	if not MathUtil.isFinite(delta) or delta == 0 then
		return
	end
	local record = recordOf(player)
	if not isActive(player) then
		return
	end
	local now = clock.now()
	local before = oxygenNow(record, now)
	local after = math.clamp(before + delta, 0, OXYGEN_MAX)
	writeOxygen(record, after, record.oxygenRate, now)
	if before > 0 and after <= 0 then
		oxygenDepleted:Fire(player)
	end
end

-- Stores a LookRelay sample (int16-quantized yaw / pitch, the remote's encoding).
function PlayerStateService.SubmitLook(player: Player, yaw: number, pitch: number)
	if not (MathUtil.isFinite(yaw) and MathUtil.isFinite(pitch)) then
		return
	end
	local record = recordOf(player)
	local quantizedYaw = math.clamp(math.round(yaw), -32767, 32767)
	local quantizedPitch = math.clamp(math.round(pitch), -32767, 32767)
	local look = record.look
	if look and look.yaw == quantizedYaw and look.pitch == quantizedPitch then
		return
	end
	record.look = { yaw = quantizedYaw, pitch = quantizedPitch }
	lookChanged:Fire(player, MathUtil.dequantizeAngle(quantizedYaw), MathUtil.dequantizeAngle(quantizedPitch))
end

-- `player`'s latest look in radians (yaw, pitch); 0, 0 before any LookRelay arrived.
function PlayerStateService.GetLook(player: Player): (number, number)
	local record = records[player]
	local look = if record then record.look else nil
	if not look then
		return 0, 0
	end
	return MathUtil.dequantizeAngle(look.yaw), MathUtil.dequantizeAngle(look.pitch)
end

-- Horizontal root speed (studs/s) the motion sampler last observed for `player`.
function PlayerStateService.GetObservedSpeed(player: Player): number
	local record = records[player]
	return if record then record.speed else 0
end

--------------------------------------------------------------------------------
-- Sampling + broadcast
--------------------------------------------------------------------------------

local function sampleMotion(record: Record, now: number)
	local root = Instances.characterRoot(record.player)
	local humanoid = Instances.characterHumanoid(record.player)
	if not root or not humanoid or humanoid.Health <= 0 then
		table.clear(record.samples)
		record.speed = 0
		if record.moving then
			record.moving = false
			refresh(record)
		end
		return
	end
	local samples = record.samples
	local newest = samples[#samples]
	if newest and now - newest.time > SPEED_STALE_SECONDS then
		table.clear(samples)
	end
	table.insert(samples, { position = root.Position, time = now })
	while #samples > SPEED_WINDOW do
		table.remove(samples, 1)
	end
	local oldest, latest = samples[1], samples[#samples]
	local span = latest.time - oldest.time
	record.speed = if span > 0 then MathUtil.horizontalDistance(latest.position, oldest.position) / span else 0
	local moving = PlayerStateService.isMoving(record.speed, humanoid.MoveDirection.Magnitude)
	if moving ~= record.moving then
		record.moving = moving
		refresh(record)
	end
end

local function broadcastLooks(now: number)
	local current: { [number]: QuantizedLook } = {}
	for player, record in records do
		local look = record.look
		if look and player.Parent == Players then
			current[player.UserId] = look
		end
	end
	local full = now - lastKeyframeAt >= LOOK_KEYFRAME_SECONDS
	if full then
		lastKeyframeAt = now
	end
	local samples = PlayerStateService.collectLookSamples(current, sentLooks, full)
	if #samples == 0 then
		return
	end
	local payload: Types.LookBroadcastPayload = { samples = samples }
	Net.Server.fireAll("LookBroadcast", payload)
end

local function tick()
	local now = os.clock()
	for _, record in records do
		if record.active then
			sampleMotion(record, now)
		end
	end
	broadcastLooks(now)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function refreshAll()
	for _, record in table.clone(records) do
		refresh(record)
	end
end

local function onCharacterSpawned(player: Player, _model: Model)
	local record = recordOf(player)
	record.intent = table.clone(NEUTRAL_INTENT)
	record.lastSeq = nil
	record.moving = false
	table.clear(record.samples)
	record.speed = 0
	applyWalkSpeed(record)
	refresh(record)
end

local function onMoved(player: Player, _model: Model, _cframe: CFrame)
	local record = records[player]
	if record then
		table.clear(record.samples)
	end
end

function PlayerStateService.Init()
	if initialized then
		return
	end
	initialized = true
	serviceTrove:Connect(Players.PlayerAdded, function(player: Player)
		recordOf(player)
	end)
	serviceTrove:Add(CharacterService.CharacterSpawned:Connect(onCharacterSpawned))
	serviceTrove:Add(CharacterService.Moved:Connect(onMoved))
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(function(phase: Enums.MatchPhase)
		local live = RunLifecycleService.GetRun() ~= nil and (phase == "Deploying" or phase == "InRun")
		if live ~= runLive then
			runLive = live
			refreshAll()
		end
	end))
	serviceTrove:Add(LoadoutService.SyringeUsed:Connect(function(player: Player, mode: Enums.SyringeMode)
		if mode == "Stamina" then
			PlayerStateService.RefillStamina(player)
		end
	end))
	Net.Server.on("MoveIntent", function(player: Player, payload: any)
		PlayerStateService.SubmitIntent(player, payload :: Types.MoveIntentPayload)
	end)
	Net.Server.on("LookRelay", function(player: Player, payload: any)
		local look = payload :: Types.LookRelayPayload
		PlayerStateService.SubmitLook(player, look.yaw, look.pitch)
	end)
end

function PlayerStateService.Start()
	for _, player in Players:GetPlayers() do
		recordOf(player)
	end
	local interval = 1 / GameConfig.ServerTickHz
	local accumulated = 0
	serviceTrove:Connect(RunService.Heartbeat, function(dt: number)
		accumulated += dt
		if accumulated < interval then
			return
		end
		accumulated = 0
		xpcall(tick, function(err: any)
			log.warnThrottled("tick", 10, "player state tick failed: %s", tostring(err))
		end)
	end)
end

function PlayerStateService.BeginRun(ctx: Types.RunContext)
	table.clear(participants)
	for _, player in ctx.participants do
		participants[player] = true
		recordOf(player)
	end
	runLive = true
	for _, record in table.clone(records) do
		resetForRun(record)
		-- Every run starts from full meters (EndRun already left everyone at the baseline; this covers a run that
		-- began without one).
		if record.active then
			record.active = false
			writeBaselineMeters(record, clock.now())
		end
		refresh(record)
	end
end

function PlayerStateService.EndRun()
	runLive = false
	table.clear(participants)
	for _, record in table.clone(records) do
		resetForRun(record)
		refresh(record)
	end
	-- Everyone re-sends their look to everyone on the next broadcast (fresh characters in the lobby).
	table.clear(sentLooks)
end

function PlayerStateService.OnPlayerRemoving(player: Player)
	participants[player] = nil
	forget(player)
end

return PlayerStateService
