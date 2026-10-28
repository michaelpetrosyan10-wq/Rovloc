--!strict
-- PacingDirector: the Creature's tension curve, so hunts come in waves with breathers between them. One Pacing per
-- run, ticked by the Creature's brain (MonsterAIService).
--
-- Tension (0..1) rises while the Creature chases (ChaseRise/s), while its target is in sight (SightRise/s) and on near
-- misses: a player within NearMissDistance adds up to NearMissRise/s, more the closer they are (a Creature brushing
-- past a locker counts). It decays at Decay/s all the time, so a quiet spell drains it.
--
-- Phases.
--   BuildUp -> Peak   tension >= PeakEnter with a player within PeakProximity.
--   BuildUp -> Relax  a chase lasting maxChaseSeconds (the leash).
--   Peak -> Relax     a catch (NoteCatch), the leash, PeakMaxSeconds in Peak, or the players got away (tension fell
--                     to PeakExit with no chase on).
--   Relax -> BuildUp  after RelaxSeconds in Relax and once the catch cooldown is over; tension leaves Relax at most
--                     RelaxExitTension, so the next peak has to be built again.
-- In Relax rises count RelaxRiseScale of their value and tension decays at RelaxDecay instead. A catch from any phase
-- goes to Relax (and pins tension at 1: the climax). An airlock (NoteAirlock: a new level) starts a fresh BuildUp at
-- most AirlockTension.
--
-- Rules for the brain. CanHunt(now) is false during the catch cooldown (DifficultyConfig.catchCooldownSeconds after
-- NoteCatch), the airlock grace (postAirlockGraceSeconds after NoteAirlock) and all of Relax. ShouldBreakChase is true
-- once a chase has lasted maxChaseSeconds, or RelaxChaseSeconds while relaxing. HearingScale is the reach factor for
-- Hearing (quieter ears in Relax, sharper at Peak).
--
-- Time. Tick advances an internal clock by dt; every call that is handed `now` (server time) moves it forward to
-- `now` when it lags, so the cooldown and the Relax hold always compare like with like.
--
-- repositionPoint picks where the Creature withdraws to: of the candidates whose distance to the nearest player lies
-- in [minDistance, maxDistance] (every candidate when there are no players), the nearest to `from` that no player
-- can see (`visible` is asked nearest first and only until one passes, since it costs raycasts).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

export type PacingPhase = "BuildUp" | "Peak" | "Relax"

export type PacingInput = { chasing: boolean, seesTarget: boolean, nearestPlayerDistance: number? }

export type PacingSnapshot = { phase: PacingPhase, tension: number, cooldownUntil: number, graceUntil: number }

export type Pacing = {
	Tick: (self: Pacing, dt: number, input: PacingInput) -> PacingPhase,
	GetPhase: (self: Pacing) -> PacingPhase,
	NoteCatch: (self: Pacing, now: number) -> (),
	NoteAirlock: (self: Pacing, now: number) -> (), -- level change: grace
	CanHunt: (self: Pacing, now: number) -> boolean, -- false during catch cooldown / grace / Relax
	ShouldBreakChase: (self: Pacing, chaseSeconds: number) -> boolean, -- maxChaseSeconds (+ Relax forcing)
	HearingScale: (self: Pacing) -> number, -- 0.8 in Relax, 1 BuildUp, 1.15 Peak
	Snapshot: (self: Pacing) -> PacingSnapshot,
}

export type Tuning = {
	ChaseRise: number, -- tension per second while chasing
	SightRise: number, -- per second while the target is in sight
	NearMissRise: number, -- per second with a player at 0 studs, falling linearly to 0 at NearMissDistance
	NearMissDistance: number,
	Decay: number, -- per second, always (outside Relax)
	RelaxRiseScale: number, -- share of every rise that counts in Relax
	RelaxDecay: number, -- per second in Relax
	PeakEnter: number,
	PeakProximity: number, -- studs: a player this close (or closer) is "near"
	PeakExit: number,
	PeakMaxSeconds: number,
	RelaxSeconds: number,
	RelaxChaseSeconds: number, -- ShouldBreakChase threshold while relaxing
	RelaxExitTension: number,
	AirlockTension: number,
	HearingScale: { BuildUp: number, Peak: number, Relax: number },
	-- DifficultyConfig
	CatchCooldownSeconds: number,
	MaxChaseSeconds: number,
	AirlockGraceSeconds: number,
}

type State = {
	tuning: Tuning,
	phase: PacingPhase,
	tension: number,
	clock: number,
	phaseSeconds: number,
	chaseSeconds: number,
	cooldownUntil: number,
	graceUntil: number,
}

local function tuningFor(difficulty: DifficultyConfig.DifficultySpec, nightmare: boolean): Tuning
	return table.freeze({
		ChaseRise = if nightmare then 0.06 else 0.05,
		SightRise = if nightmare then 0.035 else 0.03,
		NearMissRise = 0.15,
		NearMissDistance = 12,
		Decay = if nightmare then 0.02 else 0.025,
		RelaxRiseScale = 0.25,
		RelaxDecay = 0.06,
		PeakEnter = if nightmare then 0.62 else 0.7,
		PeakProximity = if nightmare then 50 else 40,
		PeakExit = 0.3,
		PeakMaxSeconds = if nightmare then 80 else 55,
		RelaxSeconds = if nightmare then 15 else 25,
		RelaxChaseSeconds = 3,
		RelaxExitTension = 0.35,
		AirlockTension = 0.15,
		HearingScale = table.freeze({ BuildUp = 1, Peak = 1.15, Relax = 0.8 }),
		CatchCooldownSeconds = difficulty.catchCooldownSeconds,
		MaxChaseSeconds = difficulty.maxChaseSeconds,
		AirlockGraceSeconds = difficulty.postAirlockGraceSeconds,
	})
end

local TUNING: { [string]: Tuning } = table.freeze({
	Standard = tuningFor(DifficultyConfig.Standard, false),
	Nightmare = tuningFor(DifficultyConfig.Nightmare, true),
})

local PacingDirector = {}

PacingDirector.Phases = table.freeze({ "BuildUp", "Peak", "Relax" } :: { PacingPhase })

-- The pacing knobs for `difficulty` (Standard for anything unknown).
function PacingDirector.tuning(difficulty: Enums.Difficulty): Tuning
	return TUNING[difficulty] or TUNING.Standard
end

-- Tension per second added by a player `distance` studs away (0 beyond NearMissDistance or when unknown).
function PacingDirector.nearMissRise(tuning: Tuning, distance: number?): number
	if distance == nil or not MathUtil.isFinite(distance) then
		return 0
	end
	local reach = tuning.NearMissDistance
	if distance >= reach then
		return 0
	end
	return tuning.NearMissRise * (1 - math.max(distance, 0) / reach)
end

--------------------------------------------------------------------------------
-- State machine
--------------------------------------------------------------------------------

local function sync(state: State, now: number)
	if MathUtil.isFinite(now) and now > state.clock then
		state.clock = now
	end
end

-- Switches phase. A chase carries on through BuildUp -> Peak (it is one chase); Relax starts the leash over.
local function enter(state: State, phase: PacingPhase)
	state.phase = phase
	state.phaseSeconds = 0
	if phase == "Relax" then
		state.chaseSeconds = 0
	end
end

local function near(state: State, distance: number?): boolean
	return distance ~= nil and MathUtil.isFinite(distance) and distance <= state.tuning.PeakProximity
end

local function tick(state: State, dt: number, input: PacingInput): PacingPhase
	local tuning = state.tuning
	local step = if MathUtil.isFinite(dt) and dt > 0 then dt else 0
	state.clock += step
	state.phaseSeconds += step
	state.chaseSeconds = if input.chasing then state.chaseSeconds + step else 0

	local rise = PacingDirector.nearMissRise(tuning, input.nearestPlayerDistance)
	if input.chasing then
		rise += tuning.ChaseRise
	end
	if input.seesTarget then
		rise += tuning.SightRise
	end
	local relaxing = state.phase == "Relax"
	if relaxing then
		rise *= tuning.RelaxRiseScale
	end
	local fall = if relaxing then tuning.RelaxDecay else tuning.Decay
	state.tension = math.clamp(state.tension + (rise - fall) * step, 0, 1)

	local phase = state.phase
	if phase == "BuildUp" then
		if state.chaseSeconds >= tuning.MaxChaseSeconds then
			enter(state, "Relax")
		elseif state.tension >= tuning.PeakEnter and near(state, input.nearestPlayerDistance) then
			enter(state, "Peak")
		end
	elseif phase == "Peak" then
		local lost = not input.chasing and state.tension <= tuning.PeakExit
		if state.chaseSeconds >= tuning.MaxChaseSeconds or state.phaseSeconds >= tuning.PeakMaxSeconds or lost then
			enter(state, "Relax")
		end
	elseif state.phaseSeconds >= tuning.RelaxSeconds and state.clock >= state.cooldownUntil then
		enter(state, "BuildUp")
		state.tension = math.min(state.tension, tuning.RelaxExitTension)
	end
	return state.phase
end

local function noteCatch(state: State, now: number)
	sync(state, now)
	if MathUtil.isFinite(now) then
		state.cooldownUntil = math.max(state.cooldownUntil, now + state.tuning.CatchCooldownSeconds)
	end
	state.tension = 1
	enter(state, "Relax")
end

local function noteAirlock(state: State, now: number)
	sync(state, now)
	if MathUtil.isFinite(now) then
		state.graceUntil = math.max(state.graceUntil, now + state.tuning.AirlockGraceSeconds)
	end
	state.tension = math.min(state.tension, state.tuning.AirlockTension)
	state.chaseSeconds = 0
	enter(state, "BuildUp")
end

local function canHunt(state: State, now: number): boolean
	sync(state, now)
	local at = if MathUtil.isFinite(now) then now else state.clock
	return state.phase ~= "Relax" and at >= state.cooldownUntil and at >= state.graceUntil
end

local function shouldBreakChase(state: State, chaseSeconds: number): boolean
	if not (chaseSeconds == chaseSeconds) then
		return false
	end
	local tuning = state.tuning
	local limit = tuning.MaxChaseSeconds
	if state.phase == "Relax" then
		limit = math.min(limit, tuning.RelaxChaseSeconds)
	end
	return chaseSeconds >= limit
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- A fresh Pacing for a run on `difficulty`, starting in BuildUp at zero tension with no cooldown or grace running.
function PacingDirector.new(difficulty: Enums.Difficulty, now: number): Pacing
	local start = if MathUtil.isFinite(now) then now else 0
	local state: State = {
		tuning = PacingDirector.tuning(difficulty),
		phase = "BuildUp",
		tension = 0,
		clock = start,
		phaseSeconds = 0,
		chaseSeconds = 0,
		cooldownUntil = start,
		graceUntil = start,
	}
	local pacing: Pacing = {
		Tick = function(_self: Pacing, dt: number, input: PacingInput): PacingPhase
			return tick(state, dt, input)
		end,
		GetPhase = function(_self: Pacing): PacingPhase
			return state.phase
		end,
		NoteCatch = function(_self: Pacing, at: number)
			noteCatch(state, at)
		end,
		NoteAirlock = function(_self: Pacing, at: number)
			noteAirlock(state, at)
		end,
		CanHunt = function(_self: Pacing, at: number): boolean
			return canHunt(state, at)
		end,
		ShouldBreakChase = function(_self: Pacing, chaseSeconds: number): boolean
			return shouldBreakChase(state, chaseSeconds)
		end,
		HearingScale = function(_self: Pacing): number
			return state.tuning.HearingScale[state.phase]
		end,
		Snapshot = function(_self: Pacing): PacingSnapshot
			return {
				phase = state.phase,
				tension = state.tension,
				cooldownUntil = state.cooldownUntil,
				graceUntil = state.graceUntil,
			}
		end,
	}
	return pacing
end

type Candidate = { point: Vector3, distance: number, index: number }

-- Where to withdraw to (see the header), or nil when no candidate qualifies.
function PacingDirector.repositionPoint(
	candidates: { Vector3 },
	players: { Vector3 },
	from: Vector3,
	minDistance: number,
	maxDistance: number,
	visible: (Vector3) -> boolean
): Vector3?
	local eligible: { Candidate } = {}
	for index, point in candidates do
		if not MathUtil.isFiniteVector(point) then
			continue
		end
		if #players > 0 then
			local nearest = math.huge
			for _, player in players do
				nearest = math.min(nearest, (point - player).Magnitude)
			end
			if nearest < minDistance or nearest > maxDistance then
				continue
			end
		end
		table.insert(eligible, { point = point, distance = (point - from).Magnitude, index = index })
	end
	table.sort(eligible, function(a: Candidate, b: Candidate): boolean
		if a.distance ~= b.distance then
			return a.distance < b.distance
		end
		return a.index < b.index
	end)
	for _, candidate in eligible do
		if not visible(candidate.point) then
			return candidate.point
		end
	end
	return nil
end

return table.freeze(PacingDirector)
