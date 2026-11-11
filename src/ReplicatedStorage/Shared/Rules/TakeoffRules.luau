--!strict
-- TakeoffRules: Wheels Up (spec v2 §4.9), pure, on the fixed 30 Hz tick. The pilot's page (or client) steps it with
-- the pilot's inputs; the authority steps it with the pilot's reported offsets and checks each report (validate), so
-- both resolve every row and his stand the same way. The website's port is web/src/game/rules/takeoff.js (I11).
--
-- Each tick, in order:
--   steering    the lateral speed moves toward steer x SteerSpeed by at most SteerSpeed / SteerRamp per second;
--               x moves by it and stops at +-MaxOffset (a reported x, on the authority, replaces the model)
--   thrust      v gains Accel (HangThrust of it while he hangs on the wing) up to TopSpeed; s gains v x dt
--   the stand   passing StandTrigger sets him on the centre line at StandS
--   obstacles   a row crossed with |x - gap| > (GapWidth - PlaneWidth) / 2 is a knock; crossing StandS with |x| <
--               StandHalfWidth + PlaneWidth / 2 is a knock and HangSeconds of HangThrust. A knock leaves
--               v = max(KnockFactor x v, v - KnockLoss)
--   rotate      a tick that starts at v >= RotateSpeed shows PULL UP!, and counts dt if pull-up is held; RotateHold
--               of it lifts off. Released (or slowed under RotateSpeed), the count starts again
--   his chase   for the first ChaseSeconds he is at ChaseSpeed x t - ChaseStart; a gap of TearGap or less to the
--               tail tears it off
--   the fence   s at RunwayEnd on the ground
--
-- API (pure; nothing is mutated; plain JSON-serialisable states and events):
--   TakeoffRules.new(difficulty, pattern)          -> State (pattern 1..3, see patternOf)
--   TakeoffRules.step(state, input, dt)            -> { state, events } (input = { steer?, pull?, x? })
--   TakeoffRules.replay(trace)                     -> { Event }, ending with "End"
--   TakeoffRules.pilot(state, plan)                -> the input of a scripted pilot (the specs', goldens' and bots')
--   TakeoffRules.validate(before, after, report)   -> "Ok" or what a pilot's report got wrong
--   TakeoffRules.patternOf(seed)                   -> the run's pattern (Rng stream "Takeoff|pattern")
--   TakeoffRules.afterAttempt(difficulty, attempt, outcome, respawns) -> what follows an attempt (§3.3)
--   TakeoffRules.golden()                          -> rows { name, fn, args, expect }

local Rng = require(script.Parent.Parent.Util.Rng)
local TakeoffConfig = require(script.Parent.Parent.Config.TakeoffConfig)

export type State = {
	difficulty: string,
	pattern: number,
	tick: number,
	s: number,
	v: number,
	x: number,
	vx: number,
	hold: number, -- seconds of pull-up counted
	cue: number, -- ticks since the PULL UP! cue came on (v >= RotateSpeed), 0 when off
	hang: number, -- seconds of half thrust left
	nextRow: number, -- the next row to cross
	standing: boolean, -- he stands at StandS
	passedStand: boolean,
	knocks: number,
	closest: number?, -- his closest gap to the tail while he chases
	closestTick: number?,
	outcome: string?, -- "Airborne", "TailTorn" or "Fence"
}

export type Input = { steer: number?, pull: boolean?, x: number? }

export type Event = { tick: number, kind: string, id: number?, value: number? }

export type Step = { state: State, events: { Event } }

export type Plan = { knocks: { number }?, hitHim: boolean?, steer: boolean?, pull: boolean?, pullDelay: number? }

export type Trace = { difficulty: string, pattern: number, ticks: { Input } }

export type Report = { s: number, v: number, x: number }

export type Attempt = { next: string, spendRespawn: boolean, freeLeft: number }

local EPS = 1e-9

local TakeoffRules = {}

local function spec(difficulty: string): TakeoffConfig.DifficultySpec
	local s = (TakeoffConfig.Difficulty :: any)[difficulty]
	if s == nil then
		error("TakeoffRules: unknown difficulty " .. tostring(difficulty), 3)
	end
	return s
end

local function gaps(pattern: number): { number }
	local list = TakeoffConfig.Patterns[pattern]
	if list == nil then
		error("TakeoffRules: unknown pattern " .. tostring(pattern), 3)
	end
	return list
end

local function rounded(x: number): number
	return math.floor(x * 1000 + 0.5) / 1000
end

-- The run's pattern for a run seed.
function TakeoffRules.patternOf(seed: number): number
	return Rng.seeded(seed, "Takeoff|pattern"):NextInteger(1, #TakeoffConfig.Patterns)
end

function TakeoffRules.new(difficulty: string, pattern: number): State
	spec(difficulty)
	gaps(pattern)
	return {
		difficulty = difficulty,
		pattern = pattern,
		tick = 0,
		s = 0,
		v = 0,
		x = 0,
		vx = 0,
		hold = 0,
		cue = 0,
		hang = 0,
		nextRow = 1,
		standing = false,
		passedStand = false,
		knocks = 0,
	}
end

local function knock(s: State, loss: number)
	s.v = math.max(TakeoffConfig.KnockFactor * s.v, s.v - loss)
	s.knocks += 1
end

function TakeoffRules.step(state: State, input: Input, dt: number): Step
	local s = table.clone(state)
	local events: { Event } = {}
	if s.outcome ~= nil then
		return { state = s, events = events }
	end
	local d = spec(s.difficulty)
	local rowGaps = gaps(s.pattern)
	s.tick += 1
	local t = s.tick / TakeoffConfig.TickRate
	-- the rotate rule reads the speed at the start of the tick
	local fast = s.v >= TakeoffConfig.RotateSpeed - EPS

	-- steering (or the pilot's reported offset)
	local reported = input.x
	if reported ~= nil then
		local x = math.clamp(reported, -TakeoffConfig.MaxOffset, TakeoffConfig.MaxOffset)
		s.vx = (x - s.x) / dt
		s.x = x
	else
		local want = math.clamp(input.steer or 0, -1, 1) * TakeoffConfig.SteerSpeed
		local step = TakeoffConfig.SteerSpeed / TakeoffConfig.SteerRamp * dt
		s.vx += math.clamp(want - s.vx, -step, step)
		local x = s.x + s.vx * dt
		if math.abs(x) > TakeoffConfig.MaxOffset then
			x = math.clamp(x, -TakeoffConfig.MaxOffset, TakeoffConfig.MaxOffset)
			s.vx = 0
		end
		s.x = x
	end

	-- thrust
	local accel = if s.hang > EPS then TakeoffConfig.Accel * TakeoffConfig.HangThrust else TakeoffConfig.Accel
	s.hang = math.max(0, s.hang - dt)
	s.v = math.min(TakeoffConfig.TopSpeed, s.v + accel * dt)
	local before = s.s
	s.s += s.v * dt

	-- his stand, then the rows and him crossed this tick
	if not s.standing and before < TakeoffConfig.StandTrigger and s.s >= TakeoffConfig.StandTrigger then
		s.standing = true
		table.insert(events, { tick = s.tick, kind = "Stand" })
	end
	local clear = (TakeoffConfig.GapWidth - TakeoffConfig.PlaneWidth) / 2
	while s.nextRow <= #TakeoffConfig.Rows and TakeoffConfig.Rows[s.nextRow] <= s.s do
		local row = s.nextRow
		s.nextRow += 1
		if math.abs(s.x - rowGaps[row]) > clear + EPS then
			knock(s, d.KnockLoss)
			table.insert(events, { tick = s.tick, kind = "Knock", id = row })
		end
	end
	if s.standing and not s.passedStand and s.s >= TakeoffConfig.StandS then
		s.passedStand = true
		if math.abs(s.x) < TakeoffConfig.StandHalfWidth + TakeoffConfig.PlaneWidth / 2 then
			knock(s, d.KnockLoss)
			s.hang = TakeoffConfig.HangSeconds
			table.insert(events, { tick = s.tick, kind = "HitHim" })
		end
	end

	-- rotate
	if fast then
		if s.cue == 0 then
			table.insert(events, { tick = s.tick, kind = "PullUp" })
		end
		s.cue += 1
	else
		s.cue = 0
	end
	s.hold = if input.pull and fast then s.hold + dt else 0
	if s.hold >= TakeoffConfig.RotateHold - EPS then
		s.outcome = "Airborne"
		table.insert(events, { tick = s.tick, kind = "Liftoff", value = rounded(s.s) })
		return { state = s, events = events }
	end

	-- his chase
	if t <= TakeoffConfig.ChaseSeconds + EPS then
		local gap = s.s + d.ChaseStart - TakeoffConfig.ChaseSpeed * t
		local closest = s.closest
		if closest == nil or gap < closest then
			s.closest, s.closestTick = gap, s.tick
		end
		if gap <= TakeoffConfig.TearGap then
			s.outcome = "TailTorn"
			table.insert(events, { tick = s.tick, kind = "TailTorn" })
			return { state = s, events = events }
		end
	end

	if s.s >= TakeoffConfig.RunwayEnd then
		s.outcome = "Fence"
		table.insert(events, { tick = s.tick, kind = "Fence" })
	end
	return { state = s, events = events }
end

-- A whole attempt from per-tick inputs. The log ends with { kind = "End", id = the number of knocks, value = his
-- closest gap to 0.001 }; Liftoff carries s to 0.001.
function TakeoffRules.replay(trace: Trace): { Event }
	local dt = 1 / TakeoffConfig.TickRate
	local state = TakeoffRules.new(trace.difficulty, trace.pattern)
	local log: { Event } = {}
	for _, input in trace.ticks do
		local result = TakeoffRules.step(state, input, dt)
		state = result.state
		for _, e in result.events do
			table.insert(log, e)
		end
		if state.outcome ~= nil then
			break
		end
	end
	local closest = state.closest
	table.insert(log, {
		tick = state.tick,
		kind = "End",
		id = state.knocks,
		value = if closest ~= nil then rounded(closest) else nil,
	})
	return log
end

-- The pilot's aim for each obstacle ahead: a row's gap centre, or for a row in plan.knocks a point 12 into the
-- obstacles on the side of the next gap (toward the centre line when that is the same gap); his stand is passed at
-- 18 on the side of the row before it (the right when that row's gap is central), or hit at 0 with plan.hitHim.
local function aimFor(state: State, plan: Plan): number
	local rowGaps = gaps(state.pattern)
	local rows = TakeoffConfig.Rows
	local standAhead = not state.passedStand and state.s < TakeoffConfig.StandS
	local row = state.nextRow
	if standAhead and (row > #rows or rows[row] > TakeoffConfig.StandS) then
		if plan.hitHim then
			return 0
		end
		local side = if rowGaps[row - 1] < 0 then -1 else 1
		return side * TakeoffConfig.Pilot.PassOffset
	end
	if row > #rows then
		return state.x
	end
	local gap = rowGaps[row]
	if table.find(plan.knocks or {}, row) == nil then
		return gap
	end
	local nextGap = rowGaps[row + 1] or gap
	local dir = if nextGap ~= gap then math.sign(nextGap - gap) elseif gap ~= 0 then -math.sign(gap) else 1
	return gap + TakeoffConfig.Pilot.KnockOffset * dir
end

-- A scripted pilot: steers for aimFor (as fast as it can stop in time, to 0.01 of full stick) unless plan.steer is
-- false, and holds pull-up from pullDelay ticks after the PULL UP! cue unless plan.pull is false.
function TakeoffRules.pilot(state: State, plan: Plan): Input
	local steer = 0
	if plan.steer ~= false then
		local dx = aimFor(state, plan) - state.x
		local brake = TakeoffConfig.SteerSpeed / TakeoffConfig.SteerRamp
		local want = math.min(TakeoffConfig.SteerSpeed, math.sqrt(2 * brake * math.abs(dx)))
		steer = math.floor(math.sign(dx) * want / TakeoffConfig.SteerSpeed * 100 + 0.5) / 100
	end
	local pull = plan.pull ~= false and state.cue >= (plan.pullDelay or 0)
	return { steer = steer, pull = pull }
end

-- The authority's check of a pilot's report against its own step from before to after (made with the reported x):
-- "Ok", or "Offset" (|x| beyond MaxOffset, or faster across than SteerSpeed), "Speed" or "Distance".
function TakeoffRules.validate(before: State, after: State, report: Report): string
	local dt = (after.tick - before.tick) / TakeoffConfig.TickRate
	if
		math.abs(report.x) > TakeoffConfig.MaxOffset + EPS
		or math.abs(report.x - before.x) > TakeoffConfig.SteerSpeed * dt + TakeoffConfig.ReportTolerance
	then
		return "Offset"
	elseif math.abs(report.v - after.v) > TakeoffConfig.ReportTolerance then
		return "Speed"
	elseif math.abs(report.s - after.s) > TakeoffConfig.ReportTolerance then
		return "Distance"
	end
	return "Ok"
end

-- What follows an attempt (§3.3): Airborne goes on to Sunrise; a failure within the free attempts retries for
-- nothing, beyond them it spends a squad respawn, and with none left the run is over.
function TakeoffRules.afterAttempt(difficulty: string, attempt: number, outcome: string, respawns: number): Attempt
	local free = spec(difficulty).FreeAttempts
	local freeLeft = math.max(0, free - attempt)
	if outcome == "Airborne" then
		return { next = "Sunrise", spendRespawn = false, freeLeft = freeLeft }
	elseif attempt <= free then
		return { next = "Retry", spendRespawn = false, freeLeft = freeLeft }
	elseif respawns > 0 then
		return { next = "Retry", spendRespawn = true, freeLeft = 0 }
	end
	return { next = "RunOver", spendRespawn = false, freeLeft = 0 }
end

export type GoldenRow = { name: string, fn: string, args: { any }, expect: any }

-- The golden rows (the export writes them for the web's port): what each function returns for its args, pinned in
-- EXPECT below. A function returns one value; numbers compare to 1e-9.
local EXPECT: { [string]: any } = {
	["patternOf: seed 0"] = 1,
	["patternOf: seed 1"] = 1,
	["patternOf: seed 2"] = 3,
	["patternOf: seed 3"] = 1,
	["patternOf: seed 4"] = 2,
	["patternOf: seed 5"] = 2,
	["patternOf: seed 20251029"] = 3,
	["new: Standard, pattern 1"] = {
		cue = 0,
		difficulty = "Standard",
		hang = 0,
		hold = 0,
		knocks = 0,
		nextRow = 1,
		passedStand = false,
		pattern = 1,
		s = 0,
		standing = false,
		tick = 0,
		v = 0,
		vx = 0,
		x = 0,
	},
	["new: Nightmare, pattern 3"] = {
		cue = 0,
		difficulty = "Nightmare",
		hang = 0,
		hold = 0,
		knocks = 0,
		nextRow = 1,
		passedStand = false,
		pattern = 3,
		s = 0,
		standing = false,
		tick = 0,
		v = 0,
		vx = 0,
		x = 0,
	},
	["step: the first tick"] = {
		events = {},
		state = {
			closest = 125.26944444444445,
			closestTick = 1,
			cue = 0,
			difficulty = "Standard",
			hang = 0,
			hold = 0,
			knocks = 0,
			nextRow = 1,
			passedStand = false,
			pattern = 1,
			s = 0.0027777777777777775,
			standing = false,
			tick = 1,
			v = 0.08333333333333333,
			vx = 0,
			x = 0,
		},
	},
	["step: steering ramps up"] = {
		events = {},
		state = {
			closest = 125.26944444444445,
			closestTick = 1,
			cue = 0,
			difficulty = "Standard",
			hang = 0,
			hold = 0,
			knocks = 0,
			nextRow = 1,
			passedStand = false,
			pattern = 1,
			s = 0.0027777777777777775,
			standing = false,
			tick = 1,
			v = 0.08333333333333333,
			vx = 2.1333333333333333,
			x = 0.07111111111111111,
		},
	},
	["step: steering stops at the edge"] = {
		events = {},
		state = {
			closest = 125.26944444444445,
			closestTick = 1,
			cue = 0,
			difficulty = "Standard",
			hang = 0,
			hold = 0,
			knocks = 0,
			nextRow = 1,
			passedStand = false,
			pattern = 1,
			s = 0.0027777777777777775,
			standing = false,
			tick = 1,
			v = 0.08333333333333333,
			vx = 0,
			x = 25,
		},
	},
	["step: a reported offset"] = {
		events = {},
		state = {
			closest = 125.26944444444445,
			closestTick = 1,
			cue = 0,
			difficulty = "Standard",
			hang = 0,
			hold = 0,
			knocks = 0,
			nextRow = 1,
			passedStand = false,
			pattern = 1,
			s = 0.0027777777777777775,
			standing = false,
			tick = 1,
			v = 0.08333333333333333,
			vx = 12,
			x = 0.4,
		},
	},
	["step: a reported offset is held inside the runway"] = {
		events = {},
		state = {
			closest = 125.26944444444445,
			closestTick = 1,
			cue = 0,
			difficulty = "Standard",
			hang = 0,
			hold = 0,
			knocks = 0,
			nextRow = 1,
			passedStand = false,
			pattern = 1,
			s = 0.0027777777777777775,
			standing = false,
			tick = 1,
			v = 0.08333333333333333,
			vx = 3.0000000000000426,
			x = 25,
		},
	},
	["step: passing 450 shows him"] = {
		events = {
			{
				kind = "Stand",
				tick = 569,
			},
		},
		state = {
			closest = 29.566666666666663,
			closestTick = 264,
			cue = 0,
			difficulty = "Standard",
			hang = 0,
			hold = 0,
			knocks = 0,
			nextRow = 5,
			passedStand = false,
			pattern = 1,
			s = 450.45833333333326,
			standing = true,
			tick = 569,
			v = 47.41666666666692,
			vx = 0,
			x = 6.466181756703548e-16,
		},
	},
	["step: row 1 cleared"] = {
		events = {},
		state = {
			closest = 31.733333333333377,
			closestTick = 224,
			cue = 0,
			difficulty = "Standard",
			hang = 0,
			hold = 0,
			knocks = 0,
			nextRow = 2,
			passedStand = false,
			pattern = 1,
			s = 70.00000000000006,
			standing = false,
			tick = 224,
			v = 18.66666666666667,
			vx = 0,
			x = -17.999999999999996,
		},
	},
	["step: row 1 knocked"] = {
		events = {
			{
				id = 1,
				kind = "Knock",
				tick = 224,
			},
		},
		state = {
			closest = 31.733333333333377,
			closestTick = 224,
			cue = 0,
			difficulty = "Standard",
			hang = 0,
			hold = 0,
			knocks = 1,
			nextRow = 2,
			passedStand = false,
			pattern = 1,
			s = 70.00000000000006,
			standing = false,
			tick = 224,
			v = 11.200000000000003,
			vx = 0,
			x = 0,
		},
	},
	["step: his stand passed"] = {
		events = {},
		state = {
			closest = 29.566666666666663,
			closestTick = 264,
			cue = 0,
			difficulty = "Standard",
			hang = 0,
			hold = 0,
			knocks = 0,
			nextRow = 7,
			passedStand = true,
			pattern = 1,
			s = 691.2916666666683,
			standing = true,
			tick = 705,
			v = 58.750000000000576,
			vx = 0,
			x = -17.999999999999996,
		},
	},
	["step: his stand hit"] = {
		events = {
			{
				kind = "HitHim",
				tick = 705,
			},
		},
		state = {
			closest = 29.566666666666663,
			closestTick = 264,
			cue = 0,
			difficulty = "Standard",
			hang = 2,
			hold = 0,
			knocks = 1,
			nextRow = 7,
			passedStand = true,
			pattern = 1,
			s = 691.2916666666683,
			standing = true,
			tick = 705,
			v = 50.750000000000576,
			vx = 0,
			x = 0,
		},
	},
	["step: half thrust while he hangs on"] = {
		events = {},
		state = {
			closest = 29.566666666666663,
			closestTick = 264,
			cue = 0,
			difficulty = "Standard",
			hang = 1.9666666666666666,
			hold = 0,
			knocks = 1,
			nextRow = 7,
			passedStand = true,
			pattern = 1,
			s = 692.9847222222239,
			standing = true,
			tick = 706,
			v = 50.79166666666724,
			vx = 0,
			x = -6.466181756703548e-16,
		},
	},
	["step: the PULL UP! cue"] = {
		events = {
			{
				kind = "PullUp",
				tick = 721,
			},
		},
		state = {
			closest = 29.566666666666663,
			closestTick = 264,
			cue = 1,
			difficulty = "Standard",
			hang = 0,
			hold = 0,
			knocks = 0,
			nextRow = 7,
			passedStand = true,
			pattern = 1,
			s = 723.0027777777798,
			standing = true,
			tick = 721,
			v = 60.08333333333395,
			vx = 13.866666666666667,
			x = -11.28,
		},
	},
	["step: lift-off"] = {
		events = {
			{
				kind = "Liftoff",
				tick = 750,
				value = 782.292,
			},
		},
		state = {
			closest = 29.566666666666663,
			closestTick = 264,
			cue = 30,
			difficulty = "Standard",
			hang = 0,
			hold = 0.9999999999999999,
			knocks = 0,
			nextRow = 7,
			outcome = "Airborne",
			passedStand = true,
			pattern = 1,
			s = 782.2916666666694,
			standing = true,
			tick = 750,
			v = 62.50000000000068,
			vx = -2.186666666666667,
			x = -0.06577777777777838,
		},
	},
	["step: released, the count starts again"] = {
		events = {},
		state = {
			closest = 29.566666666666663,
			closestTick = 264,
			cue = 20,
			difficulty = "Standard",
			hang = 0,
			hold = 0,
			knocks = 0,
			nextRow = 7,
			passedStand = true,
			pattern = 1,
			s = 761.5833333333358,
			standing = true,
			tick = 740,
			v = 61.666666666667325,
			vx = 13.866666666666667,
			x = -1.1466666666666676,
		},
	},
	["step: an outcome is final"] = {
		events = {},
		state = {
			closest = 29.566666666666663,
			closestTick = 264,
			cue = 30,
			difficulty = "Standard",
			hang = 0,
			hold = 0.9999999999999999,
			knocks = 0,
			nextRow = 7,
			outcome = "Airborne",
			passedStand = true,
			pattern = 1,
			s = 782.2916666666694,
			standing = true,
			tick = 750,
			v = 62.50000000000068,
			vx = -2.186666666666667,
			x = -0.06577777777777838,
		},
	},
	["step: after 16 s he gives up"] = {
		events = {},
		state = {
			closest = 29.566666666666663,
			closestTick = 264,
			cue = 0,
			difficulty = "Standard",
			hang = 0,
			hold = 0,
			knocks = 0,
			nextRow = 4,
			passedStand = false,
			pattern = 1,
			s = 322.0027777777773,
			standing = false,
			tick = 481,
			v = 40.08333333333338,
			vx = 0,
			x = 17.999999999999996,
		},
	},
	["step: he tears the tail off"] = {
		events = {
			{
				kind = "TailTorn",
				tick = 389,
			},
		},
		state = {
			closest = 3.9750000000000227,
			closestTick = 389,
			cue = 0,
			difficulty = "Standard",
			hang = 0,
			hold = 0,
			knocks = 2,
			nextRow = 3,
			outcome = "TailTorn",
			passedStand = false,
			pattern = 1,
			s = 163.2416666666667,
			standing = false,
			tick = 389,
			v = 16.949999999999932,
			vx = 0,
			x = 0,
		},
	},
	["step: the fence"] = {
		events = {
			{
				kind = "Fence",
				tick = 1041,
			},
		},
		state = {
			closest = 29.566666666666663,
			closestTick = 264,
			cue = 321,
			difficulty = "Standard",
			hang = 0,
			hold = 0,
			knocks = 0,
			nextRow = 13,
			outcome = "Fence",
			passedStand = true,
			pattern = 2,
			s = 1450.1666666666579,
			standing = true,
			tick = 1041,
			v = 70,
			vx = 0,
			x = 4.199331854470856e-15,
		},
	},
	["pilot: aims for row 1's gap"] = {
		pull = true,
		steer = -1,
	},
	["pilot: knocks row 1 toward the centre"] = {
		pull = true,
		steer = -1,
	},
	["pilot: knocks row 2 toward the next gap"] = {
		pull = true,
		steer = 1,
	},
	["pilot: knocks a central row toward the next gap"] = {
		pull = true,
		steer = 1,
	},
	["pilot: knocks a central row before a central row"] = {
		pull = true,
		steer = 1,
	},
	["pilot: passes him on row 6's side"] = {
		pull = true,
		steer = 0,
	},
	["pilot: passes him on the right after a central row"] = {
		pull = true,
		steer = 1,
	},
	["pilot: hits him"] = {
		pull = true,
		steer = 1,
	},
	["pilot: after his stand, row 7"] = {
		pull = true,
		steer = 0,
	},
	["pilot: past the last row it holds its line"] = {
		pull = true,
		steer = 0,
	},
	["pilot: no steering"] = {
		pull = true,
		steer = 0,
	},
	["pilot: never pulls up"] = {
		pull = false,
		steer = 0,
	},
	["pilot: pulls 6 s late, not yet"] = {
		pull = false,
		steer = 0,
	},
	["pilot: pulls 6 s late, now"] = {
		pull = true,
		steer = 0,
	},
	["validate: a true report"] = "Ok",
	["validate: off the runway"] = "Offset",
	["validate: across too fast"] = "Offset",
	["validate: a wrong speed"] = "Speed",
	["validate: a wrong distance"] = "Distance",
	["afterAttempt: airborne"] = {
		freeLeft = 2,
		next = "Sunrise",
		spendRespawn = false,
	},
	["afterAttempt: a free retry"] = {
		freeLeft = 2,
		next = "Retry",
		spendRespawn = false,
	},
	["afterAttempt: the last free retry"] = {
		freeLeft = 0,
		next = "Retry",
		spendRespawn = false,
	},
	["afterAttempt: a retry for a respawn"] = {
		freeLeft = 0,
		next = "Retry",
		spendRespawn = true,
	},
	["afterAttempt: no respawn left"] = {
		freeLeft = 0,
		next = "RunOver",
		spendRespawn = false,
	},
	["afterAttempt: Nightmare's last free retry"] = {
		freeLeft = 0,
		next = "Retry",
		spendRespawn = false,
	},
	["afterAttempt: Nightmare beyond the free ones"] = {
		freeLeft = 0,
		next = "Retry",
		spendRespawn = true,
	},
	["replay: Standard, clean, pattern 1"] = {
		{
			kind = "Stand",
			tick = 569,
		} :: any,
		{
			kind = "PullUp",
			tick = 721,
		},
		{
			kind = "Liftoff",
			tick = 750,
			value = 782.292,
		},
		{
			id = 0,
			kind = "End",
			tick = 750,
			value = 29.567,
		},
	},
	["replay: Nightmare, clean, pattern 2"] = {
		{
			kind = "Stand",
			tick = 569,
		} :: any,
		{
			kind = "PullUp",
			tick = 721,
		},
		{
			kind = "Liftoff",
			tick = 750,
			value = 782.292,
		},
		{
			id = 0,
			kind = "End",
			tick = 750,
			value = 21.567,
		},
	},
	["replay: Standard, row 1 hit, pattern 3"] = {
		{
			id = 1,
			kind = "Knock",
			tick = 224,
		} :: any,
		{
			kind = "Stand",
			tick = 630,
		},
		{
			kind = "PullUp",
			tick = 811,
		},
		{
			kind = "Liftoff",
			tick = 840,
			value = 827.851,
		},
		{
			id = 1,
			kind = "End",
			tick = 840,
			value = 8.585,
		},
	},
	["replay: Nightmare, row 1 hit, pattern 2"] = {
		{
			id = 1,
			kind = "Knock",
			tick = 224,
		} :: any,
		{
			kind = "TailTorn",
			tick = 304,
		},
		{
			id = 1,
			kind = "End",
			tick = 304,
			value = 3.933,
		},
	},
	["replay: Standard, no steering, pattern 1"] = {
		{
			id = 1,
			kind = "Knock",
			tick = 224,
		} :: any,
		{
			id = 2,
			kind = "Knock",
			tick = 365,
		},
		{
			kind = "TailTorn",
			tick = 389,
		},
		{
			id = 2,
			kind = "End",
			tick = 389,
			value = 3.975,
		},
	},
	["replay: Standard, hitting only him, pattern 3"] = {
		{
			kind = "Stand",
			tick = 569,
		} :: any,
		{
			kind = "HitHim",
			tick = 705,
		},
		{
			kind = "PullUp",
			tick = 847,
		},
		{
			kind = "Liftoff",
			tick = 876,
			value = 1009.625,
		},
		{
			id = 1,
			kind = "End",
			tick = 876,
			value = 29.567,
		},
	},
	["replay: Nightmare, hitting only him, pattern 1"] = {
		{
			kind = "Stand",
			tick = 569,
		} :: any,
		{
			kind = "HitHim",
			tick = 705,
		},
		{
			kind = "PullUp",
			tick = 871,
		},
		{
			kind = "Liftoff",
			tick = 900,
			value = 1047.458,
		},
		{
			id = 1,
			kind = "End",
			tick = 900,
			value = 21.567,
		},
	},
	["replay: Standard, never pulling up, pattern 2"] = {
		{
			kind = "Stand",
			tick = 569,
		} :: any,
		{
			kind = "PullUp",
			tick = 721,
		},
		{
			kind = "Fence",
			tick = 1041,
		},
		{
			id = 0,
			kind = "End",
			tick = 1041,
			value = 29.567,
		},
	},
	["replay: Standard, pulling up 6 s late, pattern 1"] = {
		{
			kind = "Stand",
			tick = 569,
		} :: any,
		{
			kind = "PullUp",
			tick = 721,
		},
		{
			kind = "Liftoff",
			tick = 930,
			value = 1191.167,
		},
		{
			id = 0,
			kind = "End",
			tick = 930,
			value = 29.567,
		},
	},
	["replay: Standard, him and rows 8 and 10, pattern 1"] = {
		{
			kind = "Stand",
			tick = 569,
		} :: any,
		{
			kind = "HitHim",
			tick = 705,
		},
		{
			id = 8,
			kind = "Knock",
			tick = 827,
		},
		{
			kind = "PullUp",
			tick = 943,
		},
		{
			id = 10,
			kind = "Knock",
			tick = 946,
		},
		{
			kind = "PullUp",
			tick = 1039,
		},
		{
			kind = "Liftoff",
			tick = 1068,
			value = 1364.292,
		},
		{
			id = 3,
			kind = "End",
			tick = 1068,
			value = 29.567,
		},
	},
}

function TakeoffRules.golden(): { GoldenRow }
	local rows: { GoldenRow } = {}
	local function row(name: string, fn: string, args: { any })
		table.insert(rows, { name = name, fn = fn, args = args, expect = EXPECT[name] })
	end
	local dt = 1 / TakeoffConfig.TickRate
	-- a scripted flight: the pilot's inputs until the outcome (or a tick limit), and the states it passed through
	local function fly(difficulty: string, pattern: number, plan: Plan, limit: number?): ({ Input }, { State })
		local state = TakeoffRules.new(difficulty, pattern)
		local inputs: { Input }, states: { State } = {}, { state }
		while state.outcome == nil and #inputs < (limit or 2400) do
			local input = TakeoffRules.pilot(state, plan)
			table.insert(inputs, input)
			state = TakeoffRules.step(state, input, dt).state
			table.insert(states, state)
		end
		return inputs, states
	end
	-- the state just before the first tick that ends with test(state) true
	local function before(difficulty: string, pattern: number, plan: Plan, test: (State) -> boolean): State
		local _, states = fly(difficulty, pattern, plan)
		for i = 2, #states do
			if test(states[i]) then
				return states[i - 1]
			end
		end
		error("TakeoffRules.golden: no such state")
	end
	local function with(state: State, fields: { [string]: any }): State
		local s: { [string]: any } = table.clone(state) :: any
		for k, v in fields do
			s[k] = v
		end
		return (s :: any) :: State
	end

	for _, seed in { 0, 1, 2, 3, 4, 5, 20251029 } do
		row("patternOf: seed " .. seed, "patternOf", { seed })
	end
	row("new: Standard, pattern 1", "new", { "Standard", 1 })
	row("new: Nightmare, pattern 3", "new", { "Nightmare", 3 })

	local start = TakeoffRules.new("Standard", 1)
	local clean: Plan = {}
	row("step: the first tick", "step", { start, { steer = 0, pull = false }, dt })
	row("step: steering ramps up", "step", { start, { steer = 1 }, dt })
	row("step: steering stops at the edge", "step", { with(start, { x = 24.9, vx = 16 }), { steer = 1 }, dt })
	row("step: a reported offset", "step", { start, { x = 0.4 }, dt })
	row("step: a reported offset is held inside the runway", "step", { with(start, { x = 24.9 }), { x = 30 }, dt })
	row("step: passing 450 shows him", "step", {
		before("Standard", 1, clean, function(s)
			return s.standing
		end),
		{ steer = 0, pull = true },
		dt,
	})
	local function crossing(plan: Plan, row1: number, pattern: number?): State
		return before("Standard", pattern or 1, plan, function(s)
			return s.nextRow > row1
		end)
	end
	local beforeRow1 = crossing(clean, 1)
	row("step: row 1 cleared", "step", { beforeRow1, TakeoffRules.pilot(beforeRow1, clean), dt })
	row("step: row 1 knocked", "step", { with(beforeRow1, { x = 0 }), { steer = 0, pull = true }, dt })
	local nearHim = before("Standard", 1, clean, function(s)
		return s.passedStand
	end)
	row("step: his stand passed", "step", { nearHim, TakeoffRules.pilot(nearHim, clean), dt })
	row("step: his stand hit", "step", { with(nearHim, { x = 0, vx = 0 }), { steer = 0, pull = true }, dt })
	local hanging = before("Standard", 1, { hitHim = true }, function(s)
		return s.passedStand
	end)
	row("step: half thrust while he hangs on", "step", {
		TakeoffRules.step(hanging, TakeoffRules.pilot(hanging, { hitHim = true }), dt).state,
		{ steer = 0, pull = true },
		dt,
	})
	local _, cleanStates = fly("Standard", 1, clean)
	row("step: the PULL UP! cue", "step", { cleanStates[721], { steer = 0, pull = false }, dt })
	row("step: lift-off", "step", { cleanStates[750], { steer = 0, pull = true }, dt })
	row("step: released, the count starts again", "step", { cleanStates[740], { steer = 0, pull = false }, dt })
	row("step: an outcome is final", "step", { cleanStates[#cleanStates], { steer = 1, pull = true }, dt })
	row("step: after 16 s he gives up", "step", { cleanStates[481], { steer = 0, pull = true }, dt })
	local _, caught = fly("Standard", 1, { steer = false })
	row("step: he tears the tail off", "step", { caught[#caught - 1], { steer = 0, pull = true }, dt })
	local _, fenced = fly("Standard", 2, { pull = false })
	row("step: the fence", "step", { fenced[#fenced - 1], { steer = 0, pull = false }, dt })

	-- the pilot
	local function at(pattern: number, nextRow: number, fields: { [string]: any }?): State
		local f = table.clone(fields or {})
		f.nextRow = nextRow
		return with(TakeoffRules.new("Standard", pattern), f)
	end
	row("pilot: aims for row 1's gap", "pilot", { at(1, 1), clean })
	row("pilot: knocks row 1 toward the centre", "pilot", { at(1, 1), { knocks = { 1 } } })
	row("pilot: knocks row 2 toward the next gap", "pilot", { at(1, 2, { x = -18 }), { knocks = { 2 } } })
	row("pilot: knocks a central row toward the next gap", "pilot", { at(1, 3), { knocks = { 3 } } })
	row("pilot: knocks a central row before a central row", "pilot", { at(2, 6), { knocks = { 6 } } })
	row("pilot: passes him on row 6's side", "pilot", { at(1, 7, { s = 600, x = -18 }), clean })
	row("pilot: passes him on the right after a central row", "pilot", { at(2, 7, { s = 600 }), clean })
	row("pilot: hits him", "pilot", { at(1, 7, { s = 600, x = -18 }), { hitHim = true } })
	row("pilot: after his stand, row 7", "pilot", { at(1, 7, { s = 700, passedStand = true }), clean })
	row(
		"pilot: past the last row it holds its line",
		"pilot",
		{ at(1, 13, { s = 1400, passedStand = true, x = 5 }), clean }
	)
	row("pilot: no steering", "pilot", { at(1, 1), { steer = false } })
	row("pilot: never pulls up", "pilot", { at(1, 7, { s = 700, cue = 40 }), { pull = false } })
	row("pilot: pulls 6 s late, not yet", "pilot", { at(1, 7, { s = 700, cue = 179 }), { pullDelay = 180 } })
	row("pilot: pulls 6 s late, now", "pilot", { at(1, 7, { s = 700, cue = 180 }), { pullDelay = 180 } })

	-- the authority's check
	local moved = TakeoffRules.step(start, { x = 0.5 }, dt).state
	row("validate: a true report", "validate", { start, moved, { s = moved.s, v = moved.v, x = 0.5 } })
	row("validate: off the runway", "validate", { start, moved, { s = moved.s, v = moved.v, x = 26 } })
	row("validate: across too fast", "validate", { start, moved, { s = moved.s, v = moved.v, x = 1 } })
	row("validate: a wrong speed", "validate", { start, moved, { s = moved.s, v = moved.v + 0.05, x = 0.5 } })
	row("validate: a wrong distance", "validate", { start, moved, { s = moved.s + 0.05, v = moved.v, x = 0.5 } })

	row("afterAttempt: airborne", "afterAttempt", { "Standard", 1, "Airborne", 0 })
	row("afterAttempt: a free retry", "afterAttempt", { "Standard", 1, "TailTorn", 0 })
	row("afterAttempt: the last free retry", "afterAttempt", { "Standard", 3, "Fence", 0 })
	row("afterAttempt: a retry for a respawn", "afterAttempt", { "Standard", 4, "Fence", 2 })
	row("afterAttempt: no respawn left", "afterAttempt", { "Standard", 4, "TailTorn", 0 })
	row("afterAttempt: Nightmare's last free retry", "afterAttempt", { "Nightmare", 2, "TailTorn", 0 })
	row("afterAttempt: Nightmare beyond the free ones", "afterAttempt", { "Nightmare", 3, "TailTorn", 1 })

	-- whole attempts (§4.9's table)
	local function scenario(name: string, difficulty: string, pattern: number, plan: Plan)
		local inputs = fly(difficulty, pattern, plan)
		row("replay: " .. name, "replay", { { difficulty = difficulty, pattern = pattern, ticks = inputs } })
	end
	scenario("Standard, clean, pattern 1", "Standard", 1, clean)
	scenario("Nightmare, clean, pattern 2", "Nightmare", 2, clean)
	scenario("Standard, row 1 hit, pattern 3", "Standard", 3, { knocks = { 1 } })
	scenario("Nightmare, row 1 hit, pattern 2", "Nightmare", 2, { knocks = { 1 } })
	scenario("Standard, no steering, pattern 1", "Standard", 1, { steer = false })
	scenario("Standard, hitting only him, pattern 3", "Standard", 3, { hitHim = true })
	scenario("Nightmare, hitting only him, pattern 1", "Nightmare", 1, { hitHim = true })
	scenario("Standard, never pulling up, pattern 2", "Standard", 2, { pull = false })
	scenario("Standard, pulling up 6 s late, pattern 1", "Standard", 1, { pullDelay = 180 })
	scenario("Standard, him and rows 8 and 10, pattern 1", "Standard", 1, { knocks = { 8, 10 }, hitHim = true })
	return rows
end

return TakeoffRules
