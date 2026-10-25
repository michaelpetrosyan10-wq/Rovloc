--!strict
-- LocomotionNoiseSampler: turns how every character really moves into locomotion noise pulses.
--
-- The server never takes a client's word for how quiet it is. A pulse's kind is the louder (by NoiseConfig radius)
-- of two tiers:
--   * the MoveState tier: what the server-confirmed Player.MoveState says the character is doing, and
--   * the observed-speed tier: horizontal root speed the server itself measures from root position deltas over
--     time, looked up in NoiseConfig.SpeedTiers / VentSpeedTiers / WaterSpeedTiers for the state's medium
--     (VentCrawling / VentScurrying = in a vent, Treading / Freestyle / Underwater = in the water).
-- A character slower than its medium's slowest tier is standing still and makes no locomotion noise, whatever it
-- claims. States without footsteps (Hiding, Trapped, Grabbed, Parachuting, Scripted) are silent: the server put the
-- character there and anchors or carries it. Pulses from one character are spaced by at least the NoiseConfig
-- interval of the kind being pulsed.
--
-- This module also owns the splash-meter arithmetic (NoiseConfig.SplashMeter) that NoiseAndDirectorService applies
-- to every water noise.
--
-- The tier tables, speed tracking, pacing and meter maths are pure functions (tests/Specs/Noise.spec.luau feeds
-- them fake samples); step() is the only function that reads Players and characters.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local NoiseConfig = require(ReplicatedStorage.Shared.Config.NoiseConfig)

local log = Log.new("NoiseSampler")

-- Options for NoiseAndDirectorService.Emit (declared here so the sampler can build them without requiring it).
export type EmitOptions = {
	sourcePlayer: Player?,
	levelId: Enums.LevelId?,
	medium: Enums.NoiseMedium?,
	ventNodeId: string?,
	radiusMultiplier: number?,
}

export type Emitter = (position: Vector3, kind: Enums.NoiseKind, options: EmitOptions) -> ()

export type MotionSample = { position: Vector3, time: number }

-- Per-character motion state. `samples` is the recent root path (oldest first); `medium` the medium the samples
-- were taken in; `lastPulseAt` the time of the last locomotion pulse; `jumped` whether the last step was a teleport.
export type Track = {
	samples: { MotionSample },
	medium: Enums.NoiseMedium?,
	speed: number,
	lastPulseAt: number?,
	jumped: boolean,
	character: Model?,
}

-- Per-player splash meter: `value` at time `at`, decaying linearly; `crossed` while it sits above the threshold.
export type SplashMeter = { value: number, at: number, crossed: boolean }

type SpeedTier = { minSpeed: number, kind: Enums.NoiseKind }

local Sampler = {}

-- Root positions kept per character: speed is averaged over this many samples (about 0.3 s at 10 Hz).
Sampler.WindowSamples = 4
-- A single step longer than this (horizontal studs) is a teleport (spawn, level skip, vent exit), not movement,
-- unless the previous step was one too: sustained impossible speed is real movement and is heard.
Sampler.TeleportStep = 12
-- A gap between samples longer than this (seconds) restarts the speed window.
Sampler.StaleSeconds = 1
-- Splash meters never hold more than this multiple of the grab threshold, so a calm spell re-arms them in seconds.
Sampler.SplashCapFactor = 1.5

local PACE_EPSILON = 1e-6

local AIR: Enums.NoiseMedium = "Air"
local VENT: Enums.NoiseMedium = "Vent"
local WATER: Enums.NoiseMedium = "Water"

local MEDIUM_BY_STATE: { [string]: Enums.NoiseMedium } = {
	Standing = AIR,
	Sprinting = AIR,
	Crouching = AIR,
	DownedCrawling = AIR,
	VentCrawling = VENT,
	VentScurrying = VENT,
	Treading = WATER,
	Freestyle = WATER,
	Underwater = WATER,
}

local WALK: Enums.NoiseKind = "Walk"
local SPRINT: Enums.NoiseKind = "Sprint"
local CROUCH_WALK: Enums.NoiseKind = "CrouchWalk"
local SLOW_VENT_CRAWL: Enums.NoiseKind = "SlowVentCrawl"
local VENT_SCURRY: Enums.NoiseKind = "VentScurry"
local TREADING: Enums.NoiseKind = "Treading"
local FREESTYLE: Enums.NoiseKind = "Freestyle"

-- What each moving state sounds like at the least. Standing means upright: moving upright is walking.
local TIER_BY_STATE: { [string]: Enums.NoiseKind } = {
	Standing = WALK,
	Sprinting = SPRINT,
	Crouching = CROUCH_WALK,
	DownedCrawling = CROUCH_WALK,
	VentCrawling = SLOW_VENT_CRAWL,
	VentScurrying = VENT_SCURRY,
	Treading = TREADING,
	Freestyle = FREESTYLE,
	Underwater = TREADING,
}

local SPEED_TIERS: { [string]: { SpeedTier } } = {
	Air = NoiseConfig.SpeedTiers,
	Vent = NoiseConfig.VentSpeedTiers,
	Water = NoiseConfig.WaterSpeedTiers,
}

local PRIORITY_RANK: { [string]: number } = { Low = 1, Normal = 2, High = 3, Critical = 4 }

local SPLASH = NoiseConfig.SplashMeter

local SPLASH_GAIN: { [string]: number } = {
	Freestyle = SPLASH.perFreestylePulse,
	Splash = SPLASH.perSplash,
	Treading = SPLASH.perTreadingPulse,
}

local SILENT_LIFE_STATES: { [string]: boolean } = { Lobby = true, Dead = true, Spectating = true }

--------------------------------------------------------------------------------
-- Tiers (pure)
--------------------------------------------------------------------------------

-- The medium a move state moves through, or nil for states that make no locomotion noise.
function Sampler.mediumFor(moveState: Enums.MoveState): Enums.NoiseMedium?
	return MEDIUM_BY_STATE[moveState]
end

-- The noise a move state makes while moving, or nil for silent states.
function Sampler.moveStateTier(moveState: Enums.MoveState): Enums.NoiseKind?
	return TIER_BY_STATE[moveState]
end

-- The noise observed horizontal `speed` (studs/s) makes in `medium`, or nil below the medium's slowest tier.
function Sampler.speedTier(medium: Enums.NoiseMedium, speed: number): Enums.NoiseKind?
	if not MathUtil.isFinite(speed) then
		return nil
	end
	local tiers: { SpeedTier }? = SPEED_TIERS[medium]
	if not tiers then
		return nil
	end
	for _, tier in tiers do
		if speed >= tier.minSpeed then
			return tier.kind
		end
	end
	return nil
end

-- The louder of two kinds: larger NoiseConfig radius, then higher priority; a tie keeps `a`.
function Sampler.louder(a: Enums.NoiseKind?, b: Enums.NoiseKind?): Enums.NoiseKind?
	if a == nil then
		return b
	end
	if b == nil then
		return a
	end
	local specA, specB = NoiseConfig.Kinds[a], NoiseConfig.Kinds[b]
	if not specB then
		return a
	end
	if not specA then
		return b
	end
	if specB.radius ~= specA.radius then
		return if specB.radius > specA.radius then b else a
	end
	if (PRIORITY_RANK[specB.priority] or 0) > (PRIORITY_RANK[specA.priority] or 0) then
		return b
	end
	return a
end

-- The locomotion noise of a character in `moveState` moving at horizontal `speed`: the louder of the move-state
-- tier and the observed-speed tier, or nil when the state is silent or the character is not moving.
function Sampler.classify(moveState: Enums.MoveState, speed: number): Enums.NoiseKind?
	local medium: Enums.NoiseMedium? = Sampler.mediumFor(moveState)
	if medium == nil then
		return nil
	end
	local observed: Enums.NoiseKind? = Sampler.speedTier(medium, speed)
	if observed == nil then
		return nil
	end
	return Sampler.louder(observed, Sampler.moveStateTier(moveState))
end

--------------------------------------------------------------------------------
-- Motion tracking and pacing (pure)
--------------------------------------------------------------------------------

function Sampler.newTrack(): Track
	return { samples = {}, medium = nil, speed = 0, lastPulseAt = nil, jumped = false, character = nil }
end

-- Forgets the recent path (the next sample starts a new speed window). Pacing is kept, so resets can never be
-- used to pulse sooner.
function Sampler.restartWindow(track: Track)
	table.clear(track.samples)
	track.speed = 0
	track.jumped = false
end

-- Adds a root position observed at `now` (seconds) and returns the horizontal speed (studs/s) averaged over the
-- window. Vertical motion (falls, jumps, stairs) never counts.
function Sampler.observe(track: Track, position: Vector3, now: number): number
	if not MathUtil.isFiniteVector(position) or not MathUtil.isFinite(now) then
		return track.speed
	end
	local samples = track.samples
	local newest = samples[#samples]
	if newest then
		local dt = now - newest.time
		if dt <= 0 then
			return track.speed
		end
		local step = MathUtil.horizontalDistance(position, newest.position)
		local teleported = step > Sampler.TeleportStep and not track.jumped
		if dt > Sampler.StaleSeconds or teleported then
			table.clear(samples)
			table.insert(samples, { position = position, time = now })
			track.speed = 0
			track.jumped = teleported
			return 0
		end
		track.jumped = step > Sampler.TeleportStep
	end
	table.insert(samples, { position = position, time = now })
	while #samples > Sampler.WindowSamples do
		table.remove(samples, 1)
	end
	local oldest, latest = samples[1], samples[#samples]
	local span = latest.time - oldest.time
	track.speed = if span > 0 then MathUtil.horizontalDistance(latest.position, oldest.position) / span else 0
	return track.speed
end

-- True when `interval` seconds (less `slack`) have passed since `lastAt`; always true for one-shot kinds.
function Sampler.intervalElapsed(lastAt: number?, now: number, kind: Enums.NoiseKind, slack: number): boolean
	if lastAt == nil then
		return true
	end
	local spec = NoiseConfig.Kinds[kind]
	local interval = if spec then spec.interval else 0
	if interval <= 0 then
		return true
	end
	return now - lastAt >= interval - slack - PACE_EPSILON
end

-- Claims a pulse of `kind` at `now` for this character: true (and records it) when at least `kind`'s interval has
-- passed since the character's previous locomotion pulse of any kind.
function Sampler.pace(track: Track, kind: Enums.NoiseKind, now: number): boolean
	if not Sampler.intervalElapsed(track.lastPulseAt, now, kind, 0) then
		return false
	end
	track.lastPulseAt = now
	return true
end

-- One observation of a character: records the root position and returns the kind to pulse now, if any.
function Sampler.sample(track: Track, position: Vector3, moveState: Enums.MoveState, now: number): Enums.NoiseKind?
	local medium: Enums.NoiseMedium? = Sampler.mediumFor(moveState)
	if medium ~= track.medium then
		-- Entering or leaving a vent, the water or a lock usually moves the root in one jump; never hear that jump.
		Sampler.restartWindow(track)
		track.medium = medium
	end
	local speed = Sampler.observe(track, position, now)
	local kind: Enums.NoiseKind? = Sampler.classify(moveState, speed)
	if kind ~= nil and Sampler.pace(track, kind, now) then
		return kind
	end
	return nil
end

--------------------------------------------------------------------------------
-- Splash meter (pure)
--------------------------------------------------------------------------------

function Sampler.newSplashMeter(now: number): SplashMeter
	return { value = 0, at = now, crossed = false }
end

-- How much one pulse of `kind` adds to a splash meter (0 for dry noises).
function Sampler.splashGain(kind: Enums.NoiseKind): number
	return SPLASH_GAIN[kind] or 0
end

-- The meter's value at `now` after decay.
function Sampler.splashValue(meter: SplashMeter, now: number): number
	local elapsed = math.max(0, now - meter.at)
	return math.max(0, meter.value - SPLASH.decayPerSecond * elapsed)
end

-- Adds `amount` at `now`. Returns true exactly when this add carried the meter up across the grab threshold; the
-- meter re-arms once it has decayed back below the threshold.
function Sampler.addSplash(meter: SplashMeter, amount: number, now: number): boolean
	local value = Sampler.splashValue(meter, now)
	if meter.crossed and value < SPLASH.grabThreshold then
		meter.crossed = false
	end
	if MathUtil.isFinite(amount) and amount > 0 then
		value = math.min(SPLASH.grabThreshold * Sampler.SplashCapFactor, value + amount)
	end
	meter.value = value
	meter.at = math.max(meter.at, now)
	if not meter.crossed and value >= SPLASH.grabThreshold then
		meter.crossed = true
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- Live sampling (reads Players and characters)
--------------------------------------------------------------------------------

local tracks: { [Player]: Track } = {}
local clock = 0

local function rootOf(character: Model?): (BasePart?, Humanoid?)
	if not character then
		return nil, nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not (root and root:IsA("BasePart")) then
		return nil, humanoid
	end
	return root, humanoid
end

local function levelOf(player: Player): Enums.LevelId?
	local value = player:GetAttribute(Attributes.Player.LevelId)
	if type(value) == "string" and Enums.has(Enums.LevelId, value) then
		return (value :: any) :: Enums.LevelId
	end
	return nil
end

-- The server-confirmed move state; a player nobody has classified yet is upright.
local function moveStateOf(player: Player): Enums.MoveState
	local value = player:GetAttribute(Attributes.Player.MoveState)
	if type(value) == "string" and Enums.has(Enums.MoveState, value) then
		return (value :: any) :: Enums.MoveState
	end
	return "Standing"
end

local function samplePlayer(player: Player, emit: Emitter)
	local character = player.Character
	local root, humanoid = rootOf(character)
	if not root or not humanoid or humanoid.Health <= 0 then
		tracks[player] = nil
		return
	end
	local lifeState = player:GetAttribute(Attributes.Player.LifeState)
	if type(lifeState) == "string" and SILENT_LIFE_STATES[lifeState] then
		tracks[player] = nil
		return
	end
	-- The lobby is the safe zone: nothing there is ever heard.
	if player:GetAttribute(Attributes.Player.LevelId) == "Lobby" then
		tracks[player] = nil
		return
	end

	local existing = tracks[player]
	local track: Track
	if existing and existing.character == character then
		track = existing
	else
		track = Sampler.newTrack()
		track.character = character
		tracks[player] = track
	end

	local moveState: Enums.MoveState = moveStateOf(player)
	local position = root.Position
	local kind: Enums.NoiseKind? = Sampler.sample(track, position, moveState, clock)
	if kind == nil then
		return
	end
	emit(position, kind, {
		sourcePlayer = player,
		levelId = levelOf(player),
		medium = Sampler.mediumFor(moveState),
	})
end

-- One sampler tick over every player's character. `dt` is the time since the previous tick; `emit` receives each
-- pulse (NoiseAndDirectorService passes its Emit).
function Sampler.step(dt: number, emit: Emitter)
	if MathUtil.isFinite(dt) and dt > 0 then
		clock += dt
	end
	local present: { [Player]: boolean } = {}
	for _, player in Players:GetPlayers() do
		present[player] = true
		xpcall(samplePlayer, function(err: any)
			log.warnThrottled("sample:" .. player.Name, 10, "sampling %s failed: %s", player.Name, tostring(err))
		end, player, emit)
	end
	for player in tracks do
		if not present[player] then
			tracks[player] = nil
		end
	end
end

-- Restarts `player`'s speed window. Server code that moves a character on purpose (vent exits, scripted
-- teleports) calls this so the jump is never heard as movement.
function Sampler.restartMotion(player: Player)
	local track = tracks[player]
	if track then
		Sampler.restartWindow(track)
	end
end

function Sampler.forget(player: Player)
	tracks[player] = nil
end

-- Drops every character's motion state (run start / end).
function Sampler.reset()
	table.clear(tracks)
end

return table.freeze(Sampler)
