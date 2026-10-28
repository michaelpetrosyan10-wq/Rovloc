--!strict
-- MovementController: the locally predicted MoveState, its intents to the server, and the local WalkSpeed.
--
-- Derivation (deriveState, mirrored exactly by the server's PlayerStateService):
--   1. A held override wins: Scripted > Grabbed > Trapped > Hiding > Parachuting > DownedCrawling.
--   2. Otherwise by locomotion mode, with canSprint = sprint and stamina > 0 and not exhausted:
--        OnFoot  Crouching if crouch; Sprinting if canSprint and moving; else Standing
--        Vent    VentScurrying if canSprint; else VentCrawling
--        Swim    Underwater if dive; Freestyle if canSprint; else Treading
--   "Moving" is a horizontal speed of at least MovingSpeed or a Humanoid.MoveDirection longer than MoveDirectionMin.
--   Exhaustion latch (updateExhausted): set when stamina reaches 0 while sprint is held, cleared when sprint is
--   released or stamina is back to full. So running dry stops the sprint until the key is let go (or the meter is
--   full again) instead of stuttering on every sliver of regen. Both sides flip it on events they both see: intent
--   changes and the replicated meter's crossings.
-- The client predicts from its own inputs (Sprint hold, Crouch toggle, Dive hold) and the stamina meter extrapolated
-- from the server's attributes. Overrides are the server's (the replicated MoveState) except DownedCrawling, which
-- is predicted the moment LifeState reads Downed. The mode is the one the server's MoveState implies (or a hint
-- from a later phase that knows first, e.g. the vent entry).
--
-- Reconciliation: the prediction stands while it agrees with the replicated MoveState; once they disagree for longer
-- than ReconcileWindow the server's state is used until they agree again.
--
-- Intents: MoveIntent { crouch, sprint, dive, seq } (level-encoded; seq increases per message) on every input change
-- (at most every MinSendInterval, a change inside that window goes out when it opens), at least every Keepalive
-- while moving or while client and server disagree. Only sent while the server accepts it (InRun / Deploying,
-- Alive / Downed); an intent that could not go out is sent as soon as it can.
--
-- Local effects: Humanoid.WalkSpeed = speedFor(state) every frame (so a stale server write never overrides the
-- prediction for a frame), and Humanoid.JumpHeight is 0 while canJump says no (Downed, crawling, hiding, trapped,
-- grabbed, or a ControlLock held) and JumpHeight (CharacterService's 2.5) otherwise. While a ControlLock is held the
-- inputs are ignored (sprint reads released; the crouch toggle keeps its value).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local log = Log.new("Movement")

local P = Attributes.Player
local M = Attributes.Match

export type Mode = "OnFoot" | "Vent" | "Swim"

export type DeriveInputs = {
	mode: Mode,
	override: Enums.MoveState?, -- the highest held override, if any
	crouch: boolean,
	sprint: boolean,
	dive: boolean,
	stamina: number,
	moving: boolean,
	exhausted: boolean, -- the exhaustion latch (updateExhausted)
}

export type StepContext = {
	now: number, -- os.clock()
	serverNow: number, -- workspace:GetServerTimeNow()
	sprintHeld: boolean, -- InputController.IsHeld("Sprint") (self-heals a missed release)
	diveHeld: boolean,
}

export type Movement = {
	SetCharacter: (self: Movement, humanoid: Humanoid?, root: BasePart?) -> (),
	SetSprint: (self: Movement, held: boolean) -> (),
	SetDive: (self: Movement, held: boolean) -> (),
	ToggleCrouch: (self: Movement) -> (),
	SetModeHint: (self: Movement, mode: Mode?) -> (),
	Step: (self: Movement, dt: number, context: StepContext) -> Enums.MoveState,
	GetState: (self: Movement) -> Enums.MoveState,
	GetStaminaFraction: (self: Movement) -> number,
	IsMoving: (self: Movement) -> boolean,
	GetSpeed: (self: Movement) -> number,
	IsLocked: (self: Movement) -> boolean,
	IsExhausted: (self: Movement) -> boolean,
	Changed: Signal.Signal<Enums.MoveState, Enums.MoveState>,
}

local MovementController = {}

MovementController.MovingSpeed = 4
MovementController.MoveDirectionMin = 0.1
MovementController.ReconcileWindow = 0.3
MovementController.Keepalive = 0.5
MovementController.MinSendInterval = 0.13 -- MoveIntent's token bucket refills at 8/s
MovementController.JumpHeight = 2.5 -- CharacterService builds every Humanoid with this JumpHeight

-- Highest priority first.
MovementController.OverridePriority = table.freeze({
	"Scripted",
	"Grabbed",
	"Trapped",
	"Hiding",
	"Parachuting",
	"DownedCrawling",
} :: { Enums.MoveState })

local OVERRIDES: { [string]: boolean } = {}
for _, state: Enums.MoveState in MovementController.OverridePriority do
	OVERRIDES[state] = true
end

local SPEEDS: { [string]: number } = {
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
	Scripted = 0,
	Parachuting = GameConfig.WalkSpeed,
}

local MODES: { [string]: Mode } = {
	VentCrawling = "Vent",
	VentScurrying = "Vent",
	Treading = "Swim",
	Freestyle = "Swim",
	Underwater = "Swim",
}

-- Postures that cannot jump: crawling, hidden, held by a trap or the Creature.
local NO_JUMP: { [string]: boolean } = {
	VentCrawling = true,
	VentScurrying = true,
	DownedCrawling = true,
	Hiding = true,
	Trapped = true,
	Grabbed = true,
}

local SEND_PHASES: { Enums.MatchPhase } = { "InRun", "Deploying" }
local SEND_LIFE_STATES: { Enums.LifeState } = { "Alive", "Downed" }
local MAX_SEQ = 2 ^ 31

--------------------------------------------------------------------------------
-- Pure rules
--------------------------------------------------------------------------------

function MovementController.isOverride(state: Enums.MoveState): boolean
	return OVERRIDES[state] == true
end

-- The highest-priority override among `held` (nil when none is held).
function MovementController.topOverride(held: { Enums.MoveState }): Enums.MoveState?
	for _, state: Enums.MoveState in MovementController.OverridePriority do
		if table.find(held, state) ~= nil then
			return state
		end
	end
	return nil
end

function MovementController.isMoving(horizontalSpeed: number, moveDirectionMagnitude: number): boolean
	return horizontalSpeed >= MovementController.MovingSpeed
		or moveDirectionMagnitude > MovementController.MoveDirectionMin
end

function MovementController.deriveState(inputs: DeriveInputs): Enums.MoveState
	local override: Enums.MoveState? = inputs.override
	if override ~= nil then
		return override
	end
	local canSprint = inputs.sprint and inputs.stamina > 0 and not inputs.exhausted
	if inputs.mode == "Vent" then
		return if canSprint then "VentScurrying" else "VentCrawling"
	elseif inputs.mode == "Swim" then
		if inputs.dive then
			return "Underwater"
		end
		return if canSprint then "Freestyle" else "Treading"
	end
	if inputs.crouch then
		return "Crouching"
	end
	return if canSprint and inputs.moving then "Sprinting" else "Standing"
end

-- The exhaustion latch after this frame: set when stamina reaches 0 while sprint is held, cleared when sprint is
-- released or stamina is back to `max`, otherwise unchanged.
function MovementController.updateExhausted(
	exhausted: boolean,
	sprintHeld: boolean,
	stamina: number,
	max: number
): boolean
	if not sprintHeld then
		return false
	end
	if stamina <= 0 then
		return true
	end
	if stamina >= max then
		return false
	end
	return exhausted
end

-- Whether the player may jump in this posture.
function MovementController.canJump(state: Enums.MoveState, lifeState: string, locked: boolean): boolean
	return not locked and lifeState ~= "Downed" and NO_JUMP[state] ~= true
end

-- The server-confirmed MoveState attribute ("Standing" when missing or unknown).
function MovementController.readServerState(player: Player): Enums.MoveState
	local value = player:GetAttribute(P.MoveState)
	if Enums.has(Enums.MoveState, value) then
		return (value :: any) :: Enums.MoveState
	end
	return "Standing"
end

-- Humanoid.WalkSpeed for a MoveState (the server writes the same table).
function MovementController.speedFor(state: Enums.MoveState): number
	return SPEEDS[state] or GameConfig.WalkSpeed
end

-- The base locomotion mode a MoveState belongs to (overrides belong to OnFoot).
function MovementController.modeOf(state: Enums.MoveState): Mode
	return MODES[state] or "OnFoot"
end

-- (effective state, disagreement start). The prediction stands until it has disagreed with the server for longer
-- than `window`; from then on the server's state is used until the two agree again.
function MovementController.reconcile(
	predicted: Enums.MoveState,
	server: Enums.MoveState,
	disagreeSince: number?,
	now: number,
	window: number
): (Enums.MoveState, number?)
	if predicted == server then
		return predicted, nil
	end
	local since = disagreeSince or now
	if now - since > window then
		return server, since
	end
	return predicted, since
end

--------------------------------------------------------------------------------
-- Runtime
--------------------------------------------------------------------------------

function MovementController.new(player: Player): Movement
	local humanoid: Humanoid? = nil
	local root: BasePart? = nil
	local crouch = false
	local sprint = false
	local dive = false
	local modeHint: Mode? = nil
	local lastMode: Mode = "OnFoot"
	local state: Enums.MoveState = "Standing"
	local disagreeSince: number? = nil
	local staminaFraction = 1
	local moving = false
	local speed = 0
	local locked = false
	local exhausted = false

	local seq = 0
	local sentCrouch: boolean? = nil
	local sentSprint: boolean? = nil
	local sentDive: boolean? = nil
	local lastSentAt = -math.huge
	local dirty = true

	local changed: Signal.Signal<Enums.MoveState, Enums.MoveState> = Signal.new()

	local function canSend(): boolean
		local phase = ReplicatedStorage:GetAttribute(M.MatchPhase)
		local lifeState = player:GetAttribute(P.LifeState)
		return table.find(SEND_PHASES, phase :: any) ~= nil and table.find(SEND_LIFE_STATES, lifeState :: any) ~= nil
	end

	local function send(now: number, flagCrouch: boolean, flagSprint: boolean, flagDive: boolean)
		seq = if seq >= MAX_SEQ then 1 else seq + 1
		Net.Client.fire("MoveIntent", { crouch = flagCrouch, sprint = flagSprint, dive = flagDive, seq = seq })
		sentCrouch, sentSprint, sentDive = flagCrouch, flagSprint, flagDive
		lastSentAt = now
		dirty = false
	end

	local movement: Movement
	movement = {
		Changed = changed,
		SetCharacter = function(_self: Movement, nextHumanoid: Humanoid?, nextRoot: BasePart?)
			humanoid = nextHumanoid
			root = nextRoot
			crouch = false
			disagreeSince = nil
			dirty = true
		end,
		SetSprint = function(_self: Movement, held: boolean)
			if held and locked then
				return
			end
			sprint = held
			if held and crouch and moving then
				-- Sprinting out of a crouch stands up (the server derivation lets crouch win, so clear it here).
				crouch = false
			end
		end,
		SetDive = function(_self: Movement, held: boolean)
			if held and locked then
				return
			end
			dive = held
		end,
		ToggleCrouch = function(_self: Movement)
			if locked then
				return
			end
			crouch = not crouch
		end,
		SetModeHint = function(_self: Movement, mode: Mode?)
			modeHint = mode
		end,
		Step = function(_self: Movement, _dt: number, context: StepContext): Enums.MoveState
			local now = context.now
			local server: Enums.MoveState = MovementController.readServerState(player)
			local lifeState = Attributes.getString(player, P.LifeState, "Lobby")
			locked = Attributes.getString(player, P.ControlLock, "None") ~= "None"

			-- Held inputs self-heal against the input controller (a release lost to focus changes, a lock).
			if not context.sprintHeld or locked then
				sprint = false
			end
			if not context.diveHeld or locked then
				dive = false
			end

			local mode: Mode = modeHint or MovementController.modeOf(server)
			if mode ~= lastMode then
				lastMode = mode
				crouch = false
			end
			local override: Enums.MoveState? = nil
			if MovementController.isOverride(server) then
				override = server
			elseif lifeState == "Downed" then
				override = "DownedCrawling"
			end
			if override == "DownedCrawling" then
				crouch = false
			end

			local maxStamina = Attributes.getNumber(player, P.StaminaMax, GameConfig.StaminaMax)
			local stamina =
				Attributes.readMeter(player, P.Stamina, P.StaminaRate, P.StaminaAt, maxStamina, context.serverNow)
			staminaFraction = if maxStamina > 0 then MathUtil.clamp01(stamina / maxStamina) else 0
			exhausted = MovementController.updateExhausted(exhausted, sprint, stamina, maxStamina)

			local currentRoot = root
			local currentHumanoid = humanoid
			if currentRoot and currentRoot.Parent ~= nil then
				local velocity = currentRoot.AssemblyLinearVelocity
				speed = if currentRoot.Anchored then 0 else MathUtil.flat(velocity).Magnitude
			else
				speed = 0
			end
			local direction = if currentHumanoid then currentHumanoid.MoveDirection.Magnitude else 0
			moving = MovementController.isMoving(speed, direction)

			local predicted: Enums.MoveState = MovementController.deriveState({
				mode = mode,
				override = override,
				crouch = crouch,
				sprint = sprint,
				dive = dive,
				stamina = stamina,
				moving = moving,
				exhausted = exhausted,
			})
			local effective: Enums.MoveState
			effective, disagreeSince =
				MovementController.reconcile(predicted, server, disagreeSince, now, MovementController.ReconcileWindow)

			if effective ~= state then
				local previous: Enums.MoveState = state
				state = effective
				changed:Fire(effective, previous)
			end

			if currentHumanoid and currentHumanoid.Parent ~= nil and currentHumanoid.Health > 0 then
				local walkSpeed = MovementController.speedFor(effective)
				if math.abs(currentHumanoid.WalkSpeed - walkSpeed) > 1e-3 then
					currentHumanoid.WalkSpeed = walkSpeed
				end
				local canJump = MovementController.canJump(effective, lifeState, locked)
				local jumpHeight = if canJump then MovementController.JumpHeight else 0
				if currentHumanoid.JumpHeight ~= jumpHeight then
					currentHumanoid.JumpHeight = jumpHeight
				end
			end

			-- Intents
			if crouch ~= sentCrouch or sprint ~= sentSprint or dive ~= sentDive then
				dirty = true
			end
			local due = dirty
				or (
					(moving or disagreeSince ~= nil or predicted ~= server)
					and now - lastSentAt >= MovementController.Keepalive
				)
			if due and now - lastSentAt >= MovementController.MinSendInterval then
				if canSend() then
					xpcall(send, function(err: any)
						log.warnThrottled("send", 10, "MoveIntent failed: %s", tostring(err))
					end, now, crouch, sprint, dive)
				else
					dirty = true
				end
			end
			return effective
		end,
		GetState = function(_self: Movement): Enums.MoveState
			return state
		end,
		GetStaminaFraction = function(_self: Movement): number
			return staminaFraction
		end,
		IsMoving = function(_self: Movement): boolean
			return moving
		end,
		GetSpeed = function(_self: Movement): number
			return speed
		end,
		IsLocked = function(_self: Movement): boolean
			return locked
		end,
		IsExhausted = function(_self: Movement): boolean
			return exhausted
		end,
	}
	return movement
end

return table.freeze(MovementController)
