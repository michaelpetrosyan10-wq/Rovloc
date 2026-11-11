--!strict
-- ChaseRules: the Last Run's chaser (spec v2 §4.5), pure, on the fixed 30 Hz tick. The authority (the Roblox server,
-- the web host) feeds it every runner's reported position each tick and draws the Creature at the rail coordinate it
-- returns; the website's port (web/src/game/rules/chase.js) replays the same goldens and traces (I11).
--
-- Everything is in clean-time seconds on a course (ChaseConfig: the course is an argument, the spec's three are the
-- defaults by arrival).
--   progress p   a runner's progress: the clean-time coordinate of the nearest point of the current or next segment
--                of the centre line (the next one wins unless it is Hysteresis studs farther), never decreasing,
--                except that a runner deeper than WellDepth below the deck is in the nearest well and held at its
--                entry e; climbing out, it resumes from its projection (the stair's landing is at the well's exit)
--   quarry       the active runner (reported, not caught, not left, not yet under the shutter) with the smallest p,
--                lowest slot first, re-picked every tick
--   chaser c     starts at -StartGap. The gap g = p(quarry) - c (the quarry's report against c that many ticks ago,
--                rewound at most MaxRewindTicks) picks the rate: SlowRate while g <= HoldGap, FastRate above it.
--                c advances by rate x dt, but never more than SpeedCap studs along the line in a tick
--   loom         while the quarry is in a well, c advances no further than e - LoomLip; after LoomSeconds over that
--                quarry it reaches in: caught
--   catch        g <= CatchGap on CatchTicks consecutive ticks with the quarry out of a well. Only the quarry is
--                ever caught; then the rail holds CatchHoldSeconds and takes the next quarry
--   the end      a runner whose p reaches the course's cleanTime is through; once no runner is active, the shutter
--                slams SlamDelaySeconds later if anyone is through (Success), else it is a Wipe
--
-- API (every function pure; nothing is mutated; states and events are plain JSON-serialisable tables):
--   ChaseRules.new(difficulty, arrival, runners, course?)     -> State
--   ChaseRules.step(state, inputs, dt, course?)               -> { state, events } (inputs[slot] = { x, z, y?, lag?,
--                                                                left? }; dt is the 30 Hz tick)
--   ChaseRules.replay(trace)                                  -> { Event } for a whole attempt; the last is "End"
--   ChaseRules.botTrace(course, bots, ticks)                  -> the per-tick inputs of scripted runners (the
--                                                                scenarios the specs, goldens and web bots share)
--   ChaseRules.afterAttempt(difficulty, attempt, outcome, respawns) -> what follows an attempt (§3.3)
--   ChaseRules.timeAt / distanceAt / pointAt / project / rate / quarryOf: the pieces, with goldens
--   ChaseRules.golden()                                       -> rows { name, fn, args, expect }

local ChaseConfig = require(script.Parent.Parent.Config.ChaseConfig)

type Course = ChaseConfig.Course
type Point = ChaseConfig.Point

export type Runner = {
	p: number?, -- clean-time progress; nil until the first report
	seg: number, -- the centre-line segment it projects onto (points[seg] to points[seg + 1])
	well: number, -- the well it is in (index into course.wells), 0 when none
	lag: number, -- ticks its latest report is behind
	caught: boolean,
	through: boolean,
	left: boolean,
}

export type State = {
	difficulty: string,
	arrival: string,
	tick: number,
	c: number,
	history: { number }, -- c at the end of the latest ticks, newest first (MaxRewindTicks + 1 entries at most)
	runners: { Runner },
	quarry: number, -- its slot, 0 when there is none
	closeTicks: number,
	loom: number, -- seconds the rail has loomed over the quarry in its well
	hold: number, -- seconds of the hold after a catch still to run
	slam: number?, -- seconds until the shutter slams, once nobody is active and someone is through
	cue: number, -- course cues already set off
	smashed: number, -- course fixtures already smashed (in course order)
	gap: number?, -- the quarry's gap this tick (nil while looming, holding or with no quarry)
	minGap: number?, -- the smallest gap so far
	speed: number, -- the chaser's speed along the line this tick, studs/s
	outcome: string?, -- "Success" or "Wipe"
}

export type Input = { x: number, z: number, y: number?, lag: number?, left: boolean? }

export type Event = { tick: number, kind: string, slot: number?, id: string?, value: number? }

export type Step = { state: State, events: { Event } }

export type BotEvent = { kind: string, at: number?, delay: number?, ticks: number?, well: string? }
export type Bot = { start: number?, lag: number?, events: { BotEvent }? }

export type Trace = { difficulty: string, arrival: string, ticks: { { Input } } }

export type Attempt = { next: string, spendRespawn: boolean, freeLeft: number }

local EPS = 1e-9

local ChaseRules = {}

local function spec(difficulty: string): ChaseConfig.DifficultySpec
	local s = (ChaseConfig.Difficulty :: any)[difficulty]
	if s == nil then
		error("ChaseRules: unknown difficulty " .. tostring(difficulty), 3)
	end
	return s
end

local function courseOf(arrival: string, course: Course?): Course
	if course then
		return course
	end
	local c = (ChaseConfig.Courses :: any)[arrival]
	if c == nil then
		error("ChaseRules: unknown arrival " .. tostring(arrival), 3)
	end
	return c
end

-- The clean-time coordinate of distance d along the course (beyond either end at the clean pace).
function ChaseRules.timeAt(course: Course, d: number): number
	local knots = course.knots
	if d <= knots[1].d then
		return knots[1].t + (d - knots[1].d) / ChaseConfig.RunSpeed
	end
	for i = 2, #knots do
		local b = knots[i]
		if d <= b.d then
			local a = knots[i - 1]
			return a.t + (d - a.d) * (b.t - a.t) / (b.d - a.d)
		end
	end
	local last = knots[#knots]
	return last.t + (d - last.d) / ChaseConfig.RunSpeed
end

-- The distance along the course of clean-time coordinate t (the inverse of timeAt).
function ChaseRules.distanceAt(course: Course, t: number): number
	local knots = course.knots
	if t <= knots[1].t then
		return knots[1].d + (t - knots[1].t) * ChaseConfig.RunSpeed
	end
	for i = 2, #knots do
		local b = knots[i]
		if t <= b.t then
			local a = knots[i - 1]
			return a.d + (t - a.t) * (b.d - a.d) / (b.t - a.t)
		end
	end
	local last = knots[#knots]
	return last.d + (t - last.t) * ChaseConfig.RunSpeed
end

-- The centre-line point at distance d (clamped to the line's ends).
function ChaseRules.pointAt(course: Course, d: number): { x: number, z: number }
	local points = course.points
	if d <= points[1].d then
		return { x = points[1].x, z = points[1].z }
	end
	for i = 2, #points do
		local b = points[i]
		if d <= b.d then
			local a = points[i - 1]
			local u = (d - a.d) / (b.d - a.d)
			return { x = a.x + (b.x - a.x) * u, z = a.z + (b.z - a.z) * u }
		end
	end
	local last = points[#points]
	return { x = last.x, z = last.z }
end

-- Distance along the line and distance off it of (x, z) projected onto segment i.
local function onSegment(points: { Point }, i: number, x: number, z: number): (number, number)
	local a, b = points[i], points[i + 1]
	local dx, dz = b.x - a.x, b.z - a.z
	local u = math.clamp(((x - a.x) * dx + (z - a.z) * dz) / (dx * dx + dz * dz), 0, 1)
	local ex, ez = x - (a.x + dx * u), z - (a.z + dz * u)
	return a.d + (b.d - a.d) * u, math.sqrt(ex * ex + ez * ez)
end

-- The projection of (x, z) from segment seg: { seg, d }. It moves to the next segment unless that one is more than
-- Hysteresis farther, and never back.
function ChaseRules.project(course: Course, seg: number, x: number, z: number): { seg: number, d: number }
	local points = course.points
	local along, off = onSegment(points, seg, x, z)
	if seg + 1 < #points then
		local nextAlong, nextOff = onSegment(points, seg + 1, x, z)
		if nextOff <= off + ChaseConfig.Hysteresis then
			return { seg = seg + 1, d = nextAlong }
		end
	end
	return { seg = seg, d = along }
end

-- The rail's rate for gap g.
function ChaseRules.rate(difficulty: string, gap: number): number
	local s = spec(difficulty)
	return if gap > s.HoldGap then s.FastRate else s.SlowRate
end

local function active(r: Runner): boolean
	return r.p ~= nil and not (r.caught or r.through or r.left)
end

-- The quarry's slot: the active runner with the smallest progress, lowest slot first; 0 when none is active.
function ChaseRules.quarryOf(runners: { Runner }): number
	local best, bestP = 0, math.huge
	for slot, r in runners do
		local p = r.p
		if active(r) and p ~= nil and p < bestP then
			best, bestP = slot, p
		end
	end
	return best
end

function ChaseRules.new(difficulty: string, arrival: string, runners: number, course: Course?): State
	local s = spec(difficulty)
	courseOf(arrival, course)
	local list: { Runner } = {}
	for i = 1, runners do
		list[i] = { seg = 1, well = 0, lag = 0, caught = false, through = false, left = false }
	end
	return {
		difficulty = difficulty,
		arrival = arrival,
		tick = 0,
		c = -s.StartGap,
		history = { -s.StartGap },
		runners = list,
		quarry = 0,
		closeTicks = 0,
		loom = 0,
		hold = 0,
		cue = 0,
		smashed = 0,
		speed = 0,
	}
end

local function copyState(state: State): State
	local s = table.clone(state)
	s.history = table.clone(state.history)
	local runners: { Runner } = {}
	for i, r in state.runners do
		runners[i] = table.clone(r)
	end
	s.runners = runners
	return s
end

-- The well nearest distance d along the line.
local function nearestWell(course: Course, d: number): number
	local best, bestOff = 0, math.huge
	for i, w in course.wells do
		local off = if d < w.d0 then w.d0 - d elseif d > w.d1 then d - w.d1 else 0
		if off < bestOff then
			best, bestOff = i, off
		end
	end
	return best
end

local function updateRunner(course: Course, r: Runner, input: Input)
	local proj = ChaseRules.project(course, r.seg, input.x, input.z)
	r.seg = proj.seg
	r.lag = math.clamp(math.floor(input.lag or 0), 0, ChaseConfig.MaxRewindTicks)
	if (input.y or 0) < -ChaseConfig.WellDepth and #course.wells > 0 then
		r.well = nearestWell(course, proj.d)
		r.p = course.wells[r.well].e
		return
	end
	r.well = 0
	local p = ChaseRules.timeAt(course, proj.d)
	local prev = r.p
	r.p = if prev == nil or p > prev then p else prev
end

-- c advanced by rate x dt (no further than limit), with at most SpeedCap studs along the line per tick.
local function advance(
	course: Course,
	c: number,
	rate: number,
	dt: number,
	cap: number,
	limit: number?
): (number, number)
	local target = c + rate * dt
	if limit ~= nil and target > limit then
		target = math.max(c, limit)
	end
	local d0 = ChaseRules.distanceAt(course, c)
	local d1 = ChaseRules.distanceAt(course, target)
	if d1 - d0 > cap * dt then
		d1 = d0 + cap * dt
		target = ChaseRules.timeAt(course, d1)
	end
	return target, (d1 - d0) / dt
end

local function push(s: State, c: number)
	s.c = c
	table.insert(s.history, 1, c)
	while #s.history > ChaseConfig.MaxRewindTicks + 1 do
		table.remove(s.history)
	end
end

local function catch(s: State, slot: number, how: string, events: { Event })
	s.runners[slot].caught = true
	s.hold = ChaseConfig.CatchHoldSeconds
	s.closeTicks = 0
	s.loom = 0
	table.insert(events, { tick = s.tick, kind = "Catch", slot = slot, id = how })
end

function ChaseRules.step(state: State, inputs: { Input }, dt: number, course: Course?): Step
	local s = copyState(state)
	local events: { Event } = {}
	if s.outcome ~= nil then
		return { state = s, events = events }
	end
	local route = courseOf(s.arrival, course)
	local d = spec(s.difficulty)
	s.tick += 1

	-- runners: progress, wells, the shutter
	local prior: { [number]: number } = {}
	for slot, r in s.runners do
		if r.caught or r.left then
			continue
		end
		local before = r.p
		if before ~= nil then
			prior[slot] = before
		end
		local input = inputs[slot]
		if input == nil then
			continue
		end
		if input.left then
			r.left = true
			table.insert(events, { tick = s.tick, kind = "Left", slot = slot })
			continue
		end
		updateRunner(route, r, input)
		local p = r.p
		if not r.through and p ~= nil and p >= route.cleanTime then
			r.through = true
			table.insert(events, { tick = s.tick, kind = "Through", slot = slot })
		end
	end

	-- lightning cues: the lead runner (through runners count)
	local lead = -math.huge
	for _, r in s.runners do
		local p = r.p
		if p ~= nil and not (r.caught or r.left) and p > lead then
			lead = p
		end
	end
	while s.cue < #route.cues and route.cues[s.cue + 1].t <= lead do
		s.cue += 1
		table.insert(events, { tick = s.tick, kind = "Cue", id = route.cues[s.cue].id })
	end

	-- the quarry
	local q = ChaseRules.quarryOf(s.runners)
	if q ~= s.quarry then
		s.closeTicks = 0
		s.loom = 0
		if q ~= 0 then
			table.insert(events, { tick = s.tick, kind = "Quarry", slot = q })
		end
	end
	s.quarry = q

	-- the rail
	s.gap = nil
	if s.hold > EPS then
		s.hold = math.max(0, s.hold - dt)
		s.speed = 0
		push(s, s.c)
	elseif q ~= 0 then
		local r = s.runners[q]
		local p = r.p :: number
		-- the rate is the gap at the start of the tick (the quarry's previous progress against the rail before it moves)
		local rate = ChaseRules.rate(s.difficulty, (prior[q] or p) - s.history[math.min(r.lag + 1, #s.history)])
		if r.well > 0 then
			if s.loom == 0 then
				table.insert(events, { tick = s.tick, kind = "Loom", slot = q })
			end
			s.loom += dt
			local c, speed = advance(route, s.c, rate, dt, d.SpeedCap, route.wells[r.well].e - ChaseConfig.LoomLip)
			s.speed = speed
			push(s, c)
			if s.loom >= d.LoomSeconds - EPS then
				catch(s, q, "ReachIn", events)
			end
		else
			s.loom = 0
			local c, speed = advance(route, s.c, rate, dt, d.SpeedCap)
			s.speed = speed
			push(s, c)
			local gap = p - s.history[math.min(r.lag + 1, #s.history)]
			s.gap = gap
			local low = s.minGap
			if low == nil or gap < low then
				s.minGap = gap
			end
			s.closeTicks = if gap <= ChaseConfig.CatchGap then s.closeTicks + 1 else 0
			if s.closeTicks >= ChaseConfig.CatchTicks then
				catch(s, q, "Gap", events)
			end
		end
	else
		s.speed = 0
		push(s, s.c)
	end

	-- fixtures the rail has reached switch to Smashed
	while s.smashed < #route.fixtures and route.fixtures[s.smashed + 1].t0 <= s.c do
		s.smashed += 1
		table.insert(events, { tick = s.tick, kind = "Smash", id = route.fixtures[s.smashed].id })
	end

	-- the end of the attempt
	local anyActive, anyThrough = false, false
	for _, r in s.runners do
		anyActive = anyActive or active(r)
		anyThrough = anyThrough or r.through
	end
	if not anyActive then
		if not anyThrough then
			s.outcome = "Wipe"
			table.insert(events, { tick = s.tick, kind = "Wipe" })
		else
			local slam = s.slam
			if slam == nil then
				s.slam = ChaseConfig.SlamDelaySeconds
			elseif slam - dt <= EPS then
				s.slam = 0
				s.outcome = "Success"
				table.insert(events, { tick = s.tick, kind = "Slam" })
			else
				s.slam = slam - dt
			end
		end
	end
	return { state = s, events = events }
end

local function rounded(x: number): number
	return math.floor(x * 1000 + 0.5) / 1000
end

-- A whole attempt from per-tick inputs (ChaseConfig's course for the trace's arrival, the 30 Hz tick). The log ends
-- with { kind = "End", id = outcome or "Unfinished", value = the smallest gap, to 0.001 }.
function ChaseRules.replay(trace: Trace): { Event }
	local dt = 1 / ChaseConfig.TickRate
	local runners = if #trace.ticks > 0 then #trace.ticks[1] else 0
	local state = ChaseRules.new(trace.difficulty, trace.arrival, runners)
	local log: { Event } = {}
	for _, inputs in trace.ticks do
		local result = ChaseRules.step(state, inputs, dt)
		state = result.state
		for _, e in result.events do
			table.insert(log, e)
		end
		if state.outcome ~= nil then
			break
		end
	end
	local minGap = state.minGap
	table.insert(log, {
		tick = state.tick,
		kind = "End",
		id = state.outcome or "Unfinished",
		value = if minGap ~= nil then rounded(minGap) else nil,
	})
	return log
end

-- Scripted runners on the centre line, for the specs, the goldens and the web's bots. A bot stands at clean-time
-- coordinate start (default 0, the gate) at t0 and runs at the clean pace, working through its events in order:
--   { kind = "Stall", ticks, at? | delay? }   no progress for that many ticks, from reaching coordinate at, or delay
--                                             ticks after the previous event ended
--   { kind = "Fall", well, ticks }            on reaching the well's entry it drops in (10 below the deck) for that
--                                             many ticks, then stands on the landing at the well's exit
--   { kind = "Stop", at? | delay? }           stands still from then on (a camper)
-- Positions are rounded to 0.001 studs. lag stamps every report that many ticks late.
function ChaseRules.botTrace(course: Course, bots: { Bot }, ticks: number): { { Input } }
	local hz = ChaseConfig.TickRate
	type Run = {
		base: number,
		moved: number,
		index: number,
		busy: number,
		ended: number,
		well: ChaseConfig.Well?,
		stopped: boolean,
	}
	local runs: { Run } = {}
	for i, bot in bots do
		runs[i] = { base = bot.start or 0, moved = 0, index = 1, busy = 0, ended = 0, stopped = false }
	end
	local function at(q: number, y: number?, lag: number?): Input
		local point = ChaseRules.pointAt(course, ChaseRules.distanceAt(course, math.min(q, course.cleanTime)))
		return { x = rounded(point.x), z = rounded(point.z), y = y, lag = lag }
	end
	local out: { { Input } } = {}
	for tick = 1, ticks do
		local row: { Input } = {}
		for i, bot in bots do
			local run = runs[i]
			local events: { BotEvent } = bot.events or {}
			local q = run.base + run.moved / hz
			if run.busy == 0 and not run.stopped then
				local ev = events[run.index]
				local due = ev ~= nil
					and (
						(ev.at ~= nil and q >= ev.at - EPS)
						or (ev.delay ~= nil and tick - run.ended > ev.delay)
						or (
							ev.kind == "Fall"
							and ev.at == nil
							and q >= ChaseRules.wellOf(course, ev.well or "").e - EPS
						)
					)
				if ev ~= nil and due then
					if ev.kind == "Stop" then
						run.stopped = true
					else
						run.busy = ev.ticks or 0
						run.well = if ev.kind == "Fall" then ChaseRules.wellOf(course, ev.well or "") else nil
					end
				end
			end
			if run.stopped then
				row[i] = at(q, nil, bot.lag)
			elseif run.busy > 0 then
				run.busy -= 1
				local well = run.well
				if well ~= nil then
					row[i] = at((well.e + well.exit) / 2, ChaseConfig.WellFloor, bot.lag)
				else
					row[i] = at(q, nil, bot.lag)
				end
				if run.busy == 0 then
					run.index += 1
					run.ended = tick
					if well ~= nil then
						run.base, run.moved = well.exit, 0
					end
					run.well = nil
				end
			else
				run.moved += 1
				row[i] = at(run.base + run.moved / hz, nil, bot.lag)
			end
		end
		out[tick] = row
	end
	return out
end

-- The course's well with this id.
function ChaseRules.wellOf(course: Course, id: string): ChaseConfig.Well
	for _, w in course.wells do
		if w.id == id then
			return w
		end
	end
	error("ChaseRules: no well " .. id, 2)
end

-- What follows an attempt (§3.3): Success goes to the tower; a wipe within the free attempts retries for nothing,
-- beyond them it spends a squad respawn, and with none left the run is over. freeLeft is the HUD's "tries left".
function ChaseRules.afterAttempt(difficulty: string, attempt: number, outcome: string, respawns: number): Attempt
	local free = spec(difficulty).FreeAttempts
	local freeLeft = math.max(0, free - attempt)
	if outcome == "Success" then
		return { next = "Tower", spendRespawn = false, freeLeft = freeLeft }
	elseif attempt <= free then
		return { next = "Retry", spendRespawn = false, freeLeft = freeLeft }
	elseif respawns > 0 then
		return { next = "Retry", spendRespawn = true, freeLeft = 0 }
	end
	return { next = "RunOver", spendRespawn = false, freeLeft = 0 }
end

export type GoldenRow = { name: string, fn: string, args: { any }, expect: any }

-- A small course for the golden rows of the course functions: a pen, one corner, a hurdle, a bar, a well and a cue,
-- at 25 studs per clean second on the straights (fast enough that the speed cap binds).
local TEST_COURSE: Course = {
	name = "Test",
	points = {
		{ x = 100, z = 0, d = -10, t = -0.4 },
		{ x = 90, z = 0, d = 0, t = 0 },
		{ x = 50, z = 0, d = 40, t = 1.675 },
		{ x = 50, z = 40, d = 80, t = 3.35 },
	},
	knots = {
		{ d = -10, t = -0.4 },
		{ d = 0, t = 0 },
		{ d = 38, t = 1.52 },
		{ d = 42, t = 1.83 },
		{ d = 80, t = 3.35 },
	},
	fixtures = {
		{ id = "H", kind = "Hurdle", d0 = 20, d1 = 20, t0 = 0.8, t1 = 0.8 },
		{ id = "B", kind = "Bar", d0 = 50, d1 = 52, t0 = 2.15, t1 = 2.23 },
	},
	wells = { { id = "W", d0 = 60, d1 = 70, e = 2.55, exit = 2.95 } },
	cues = { { id = "W", t = 1.4 } },
	length = 80,
	cleanTime = 3.35,
}

-- The golden rows (the export writes them for the web's port): what each function returns for its args, pinned in
-- EXPECT below. A function returns one value; numbers compare to 1e-9.
local EXPECT: { [string]: any } = {
	["timeAt: before the door"] = -0.9263157894736842,
	["timeAt: in the pen"] = -0.2,
	["timeAt: in the corner's slow zone"] = 1.675,
	["timeAt: the shutter"] = 3.35,
	["timeAt: beyond the shutter"] = 4.35,
	["distanceAt: before the door"] = -21.4,
	["distanceAt: in the corner's slow zone"] = 39.03225806451613,
	["distanceAt: the shutter"] = 80,
	["distanceAt: beyond the shutter"] = 92.35,
	["pointAt: before the door"] = {
		x = 100,
		z = 0,
	},
	["pointAt: on the first straight"] = {
		x = 70,
		z = 0,
	},
	["pointAt: after the corner"] = {
		x = 50,
		z = 20,
	},
	["pointAt: beyond the shutter"] = {
		x = 50,
		z = 40,
	},
	["project: the next segment is too far"] = {
		d = -5,
		seg = 1,
	},
	["project: the next segment within the hysteresis"] = {
		d = 0,
		seg = 2,
	},
	["project: round the corner"] = {
		d = 41,
		seg = 3,
	},
	["project: the last segment, past its end"] = {
		d = 80,
		seg = 3,
	},
	["rate: Standard at the hold gap"] = 0.86,
	["rate: Standard above it"] = 1.12,
	["rate: Nightmare below it"] = 0.93,
	["rate: Nightmare above it"] = 1.15,
	["quarryOf: nobody has reported"] = 0,
	["quarryOf: the smallest progress"] = 2,
	["quarryOf: a tie goes to the lower slot"] = 1,
	["quarryOf: caught, through and left runners are not chased"] = 4,
	["new: Standard from the middle, two runners"] = {
		arrival = "Middle",
		c = -2.6,
		closeTicks = 0,
		cue = 0,
		difficulty = "Standard",
		history = {
			-2.6,
		},
		hold = 0,
		loom = 0,
		quarry = 0,
		runners = {
			{
				caught = false,
				lag = 0,
				left = false,
				seg = 1,
				through = false,
				well = 0,
			} :: any,
			{
				caught = false,
				lag = 0,
				left = false,
				seg = 1,
				through = false,
				well = 0,
			},
		},
		smashed = 0,
		speed = 0,
		tick = 0,
	},
	["new: Nightmare from the north, alone"] = {
		arrival = "North",
		c = -2.4,
		closeTicks = 0,
		cue = 0,
		difficulty = "Nightmare",
		history = {
			-2.4,
		},
		hold = 0,
		loom = 0,
		quarry = 0,
		runners = {
			{
				caught = false,
				lag = 0,
				left = false,
				seg = 1,
				through = false,
				well = 0,
			},
		},
		smashed = 0,
		speed = 0,
		tick = 0,
	},
	["replay: Standard, middle, clean"] = {
		{
			kind = "Quarry",
			slot = 1,
			tick = 1,
		} :: any,
		{
			id = "H1",
			kind = "Smash",
			tick = 121,
		},
		{
			id = "L1",
			kind = "Cue",
			tick = 175,
		},
		{
			id = "B1",
			kind = "Smash",
			tick = 178,
		},
		{
			id = "H2",
			kind = "Smash",
			tick = 392,
		},
		{
			id = "B2",
			kind = "Smash",
			tick = 445,
		},
		{
			id = "L2",
			kind = "Cue",
			tick = 506,
		},
		{
			id = "H3",
			kind = "Smash",
			tick = 507,
		},
		{
			id = "H4",
			kind = "Smash",
			tick = 727,
		},
		{
			id = "H5",
			kind = "Smash",
			tick = 803,
		},
		{
			id = "Section7",
			kind = "Cue",
			tick = 810,
		},
		{
			id = "H6",
			kind = "Smash",
			tick = 928,
		},
		{
			kind = "Through",
			slot = 1,
			tick = 985,
		},
		{
			kind = "Slam",
			tick = 1000,
		},
		{
			id = "Success",
			kind = "End",
			tick = 1000,
			value = 1.585,
		},
	},
	["replay: Nightmare, north, clean"] = {
		{
			kind = "Quarry",
			slot = 1,
			tick = 1,
		} :: any,
		{
			id = "H0",
			kind = "Smash",
			tick = 158,
		},
		{
			id = "B0",
			kind = "Smash",
			tick = 210,
		},
		{
			id = "H1",
			kind = "Smash",
			tick = 290,
		},
		{
			id = "B1",
			kind = "Smash",
			tick = 355,
		},
		{
			id = "L1",
			kind = "Cue",
			tick = 372,
		},
		{
			id = "H2",
			kind = "Smash",
			tick = 576,
		},
		{
			id = "B2",
			kind = "Smash",
			tick = 630,
		},
		{
			id = "H3",
			kind = "Smash",
			tick = 691,
		},
		{
			id = "L2",
			kind = "Cue",
			tick = 703,
		},
		{
			id = "H4",
			kind = "Smash",
			tick = 912,
		},
		{
			id = "H5",
			kind = "Smash",
			tick = 988,
		},
		{
			id = "Section7",
			kind = "Cue",
			tick = 1007,
		},
		{
			id = "H6",
			kind = "Smash",
			tick = 1112,
		},
		{
			kind = "Through",
			slot = 1,
			tick = 1182,
		},
		{
			kind = "Slam",
			tick = 1197,
		},
		{
			id = "Success",
			kind = "End",
			tick = 1197,
			value = 1.177,
		},
	},
	["replay: Standard, south, one bumped hurdle"] = {
		{
			kind = "Quarry",
			slot = 1,
			tick = 1,
		} :: any,
		{
			id = "H0",
			kind = "Smash",
			tick = 167,
		},
		{
			id = "B0",
			kind = "Smash",
			tick = 221,
		},
		{
			id = "H1",
			kind = "Smash",
			tick = 302,
		},
		{
			id = "B1",
			kind = "Smash",
			tick = 367,
		},
		{
			id = "L1",
			kind = "Cue",
			tick = 372,
		},
		{
			id = "H2",
			kind = "Smash",
			tick = 596,
		},
		{
			id = "B2",
			kind = "Smash",
			tick = 657,
		},
		{
			id = "L2",
			kind = "Cue",
			tick = 718,
		},
		{
			id = "H3",
			kind = "Smash",
			tick = 719,
		},
		{
			id = "H4",
			kind = "Smash",
			tick = 939,
		},
		{
			id = "H5",
			kind = "Smash",
			tick = 1015,
		},
		{
			id = "Section7",
			kind = "Cue",
			tick = 1022,
		},
		{
			id = "H6",
			kind = "Smash",
			tick = 1139,
		},
		{
			kind = "Through",
			slot = 1,
			tick = 1197,
		},
		{
			kind = "Slam",
			tick = 1212,
		},
		{
			id = "Success",
			kind = "End",
			tick = 1212,
			value = 1.163,
		},
	},
	["replay: Nightmare, middle, a bump then a slow bar 3 s later"] = {
		{
			kind = "Quarry",
			slot = 1,
			tick = 1,
		} :: any,
		{
			id = "H1",
			kind = "Smash",
			tick = 113,
		},
		{
			id = "B1",
			kind = "Smash",
			tick = 169,
		},
		{
			id = "L1",
			kind = "Cue",
			tick = 175,
		},
		{
			id = "H2",
			kind = "Smash",
			tick = 382,
		},
		{
			id = "B2",
			kind = "Smash",
			tick = 440,
		},
		{
			id = "Gap",
			kind = "Catch",
			slot = 1,
			tick = 458,
		},
		{
			kind = "Wipe",
			tick = 458,
		},
		{
			id = "Wipe",
			kind = "End",
			tick = 458,
			value = 0.159,
		},
	},
	["replay: Standard, middle, a fall then clean"] = {
		{
			kind = "Quarry",
			slot = 1,
			tick = 1,
		} :: any,
		{
			id = "H1",
			kind = "Smash",
			tick = 121,
		},
		{
			id = "L1",
			kind = "Cue",
			tick = 175,
		},
		{
			id = "B1",
			kind = "Smash",
			tick = 178,
		},
		{
			kind = "Loom",
			slot = 1,
			tick = 227,
		},
		{
			id = "H2",
			kind = "Smash",
			tick = 452,
		},
		{
			id = "B2",
			kind = "Smash",
			tick = 505,
		},
		{
			id = "L2",
			kind = "Cue",
			tick = 566,
		},
		{
			id = "H3",
			kind = "Smash",
			tick = 567,
		},
		{
			id = "H4",
			kind = "Smash",
			tick = 787,
		},
		{
			id = "H5",
			kind = "Smash",
			tick = 863,
		},
		{
			id = "Section7",
			kind = "Cue",
			tick = 870,
		},
		{
			id = "H6",
			kind = "Smash",
			tick = 988,
		},
		{
			kind = "Through",
			slot = 1,
			tick = 1045,
		},
		{
			kind = "Slam",
			tick = 1060,
		},
		{
			id = "Success",
			kind = "End",
			tick = 1060,
			value = 0.936,
		},
	},
	["replay: Nightmare, middle, staying in a well"] = {
		{
			kind = "Quarry",
			slot = 1,
			tick = 1,
		} :: any,
		{
			id = "H1",
			kind = "Smash",
			tick = 113,
		},
		{
			id = "B1",
			kind = "Smash",
			tick = 169,
		},
		{
			id = "L1",
			kind = "Cue",
			tick = 175,
		},
		{
			id = "H2",
			kind = "Smash",
			tick = 380,
		},
		{
			id = "B2",
			kind = "Smash",
			tick = 433,
		},
		{
			id = "H3",
			kind = "Smash",
			tick = 495,
		},
		{
			id = "L2",
			kind = "Cue",
			tick = 506,
		},
		{
			kind = "Loom",
			slot = 1,
			tick = 553,
		},
		{
			id = "ReachIn",
			kind = "Catch",
			slot = 1,
			tick = 732,
		},
		{
			kind = "Wipe",
			tick = 732,
		},
		{
			id = "Wipe",
			kind = "End",
			tick = 732,
			value = 1.179,
		},
	},
	["replay: Standard, middle, standing at the gate"] = {
		{
			kind = "Quarry",
			slot = 1,
			tick = 1,
		} :: any,
		{
			id = "Gap",
			kind = "Catch",
			slot = 1,
			tick = 76,
		},
		{
			kind = "Wipe",
			tick = 76,
		},
		{
			id = "Wipe",
			kind = "End",
			tick = 76,
			value = 0.187,
		},
	},
	["replay: Standard, middle, standing at the gate, reports 7 ticks late"] = {
		{
			kind = "Quarry",
			slot = 1,
			tick = 1,
		} :: any,
		{
			id = "Gap",
			kind = "Catch",
			slot = 1,
			tick = 81,
		},
		{
			kind = "Wipe",
			tick = 81,
		},
		{
			id = "Wipe",
			kind = "End",
			tick = 81,
			value = 0.184,
		},
	},
	["replay: Standard, middle, four runners, the straggler caught"] = {
		{
			kind = "Quarry",
			slot = 4,
			tick = 1,
		} :: any,
		{
			id = "Gap",
			kind = "Catch",
			slot = 4,
			tick = 76,
		},
		{
			kind = "Quarry",
			slot = 3,
			tick = 77,
		},
		{
			id = "L1",
			kind = "Cue",
			tick = 175,
		},
		{
			id = "H1",
			kind = "Smash",
			tick = 222,
		},
		{
			id = "B1",
			kind = "Smash",
			tick = 280,
		},
		{
			id = "H2",
			kind = "Smash",
			tick = 478,
		},
		{
			id = "L2",
			kind = "Cue",
			tick = 506,
		},
		{
			id = "B2",
			kind = "Smash",
			tick = 526,
		},
		{
			id = "H3",
			kind = "Smash",
			tick = 581,
		},
		{
			id = "H4",
			kind = "Smash",
			tick = 778,
		},
		{
			id = "Section7",
			kind = "Cue",
			tick = 810,
		},
		{
			id = "H5",
			kind = "Smash",
			tick = 845,
		},
		{
			id = "H6",
			kind = "Smash",
			tick = 956,
		},
		{
			kind = "Through",
			slot = 1,
			tick = 985,
		},
		{
			kind = "Through",
			slot = 2,
			tick = 991,
		},
		{
			kind = "Through",
			slot = 3,
			tick = 997,
		},
		{
			kind = "Slam",
			tick = 1012,
		},
		{
			id = "Success",
			kind = "End",
			tick = 1012,
			value = 0.187,
		},
	},
	["replay: Nightmare, middle, a mid-pack faller"] = {
		{
			kind = "Quarry",
			slot = 3,
			tick = 1,
		} :: any,
		{
			id = "H1",
			kind = "Smash",
			tick = 113,
		},
		{
			id = "L1",
			kind = "Cue",
			tick = 175,
		},
		{
			id = "B1",
			kind = "Smash",
			tick = 176,
		},
		{
			kind = "Quarry",
			slot = 2,
			tick = 244,
		},
		{
			kind = "Loom",
			slot = 2,
			tick = 244,
		},
		{
			id = "H2",
			kind = "Smash",
			tick = 449,
		},
		{
			id = "B2",
			kind = "Smash",
			tick = 502,
		},
		{
			id = "L2",
			kind = "Cue",
			tick = 506,
		},
		{
			id = "H3",
			kind = "Smash",
			tick = 564,
		},
		{
			id = "H4",
			kind = "Smash",
			tick = 784,
		},
		{
			id = "Section7",
			kind = "Cue",
			tick = 810,
		},
		{
			id = "H5",
			kind = "Smash",
			tick = 860,
		},
		{
			kind = "Through",
			slot = 1,
			tick = 985,
		},
		{
			id = "H6",
			kind = "Smash",
			tick = 985,
		},
		{
			kind = "Through",
			slot = 3,
			tick = 1003,
		},
		{
			kind = "Through",
			slot = 2,
			tick = 1054,
		},
		{
			kind = "Slam",
			tick = 1069,
		},
		{
			id = "Success",
			kind = "End",
			tick = 1069,
			value = 0.934,
		},
	},
	["step: the first tick at the gate"] = {
		events = {
			{
				kind = "Quarry",
				slot = 1,
				tick = 1,
			},
		},
		state = {
			arrival = "Middle",
			c = -2.562666666666667,
			closeTicks = 0,
			cue = 0,
			difficulty = "Standard",
			gap = 2.59598245614035,
			history = {
				-2.562666666666667,
				-2.6,
			},
			hold = 0,
			loom = 0,
			minGap = 2.59598245614035,
			quarry = 1,
			runners = {
				{
					caught = false,
					lag = 0,
					left = false,
					p = 0.03331578947368323,
					seg = 2,
					through = false,
					well = 0,
				},
			},
			smashed = 0,
			speed = 21.279999999999788,
			tick = 1,
		},
	},
	["step: the held gap"] = {
		events = {},
		state = {
			arrival = "Middle",
			c = 11.73533333333331,
			closeTicks = 0,
			cue = 1,
			difficulty = "Standard",
			gap = 1.598004166666687,
			history = {
				11.73533333333331,
				11.697999999999977,
				11.669333333333311,
				11.631999999999978,
				11.603333333333312,
				11.56599999999998,
				11.537333333333313,
				11.49999999999998,
				11.462666666666648,
				11.433999999999982,
				11.396666666666649,
				11.367999999999983,
				11.33066666666665,
			},
			hold = 0,
			loom = 0,
			minGap = 1.5853339912280369,
			quarry = 1,
			runners = {
				{
					caught = false,
					lag = 0,
					left = false,
					p = 13.333337499999997,
					seg = 5,
					through = false,
					well = 0,
				},
			},
			smashed = 3,
			speed = 21.279999999999575,
			tick = 400,
		},
	},
	["step: a lightning cue"] = {
		events = {
			{
				id = "L1",
				kind = "Cue",
				tick = 175,
			},
		},
		state = {
			arrival = "Middle",
			c = 3.933333333333331,
			closeTicks = 0,
			cue = 1,
			difficulty = "Standard",
			gap = 2.020614035087722,
			history = {
				3.933333333333331,
				3.8959999999999977,
				3.8586666666666645,
				3.8213333333333313,
				3.783999999999998,
				3.746666666666665,
				3.7093333333333316,
				3.6719999999999984,
				3.634666666666665,
				3.597333333333332,
				3.5599999999999987,
				3.5226666666666655,
				3.4853333333333323,
			},
			hold = 0,
			loom = 0,
			minGap = 1.9040026315789498,
			quarry = 1,
			runners = {
				{
					caught = false,
					lag = 0,
					left = false,
					p = 5.953947368421053,
					seg = 4,
					through = false,
					well = 0,
				},
			},
			smashed = 1,
			speed = 21.28,
			tick = 175,
		},
	},
	["step: a hurdle smashed"] = {
		events = {
			{
				id = "H1",
				kind = "Smash",
				tick = 121,
			},
		},
		state = {
			arrival = "Middle",
			c = 1.9173333333333367,
			closeTicks = 0,
			cue = 0,
			difficulty = "Standard",
			gap = 2.115982456140348,
			history = {
				1.9173333333333367,
				1.8800000000000032,
				1.8426666666666698,
				1.8053333333333363,
				1.768000000000003,
				1.7306666666666695,
				1.693333333333336,
				1.6560000000000026,
				1.6186666666666691,
				1.5813333333333357,
				1.5440000000000023,
				1.5066666666666688,
				1.4693333333333354,
			},
			hold = 0,
			loom = 0,
			minGap = 2.115982456140348,
			quarry = 1,
			runners = {
				{
					caught = false,
					lag = 0,
					left = false,
					p = 4.033315789473685,
					seg = 3,
					through = false,
					well = 0,
				},
			},
			smashed = 1,
			speed = 21.28,
			tick = 121,
		},
	},
	["step: through the shutter"] = {
		events = {
			{
				kind = "Through",
				slot = 1,
				tick = 985,
			},
		},
		state = {
			arrival = "Middle",
			c = 31.19799999999967,
			closeTicks = 0,
			cue = 3,
			difficulty = "Standard",
			history = {
				31.19799999999967,
				31.19799999999967,
				31.169333333333004,
				31.13199999999967,
				31.103333333333005,
				31.065999999999672,
				31.02866666666634,
				30.999999999999673,
				30.96266666666634,
				30.933999999999674,
				30.89666666666634,
				30.867999999999675,
				30.830666666666342,
			},
			hold = 0,
			loom = 0,
			minGap = 1.5853339912280369,
			quarry = 0,
			runners = {
				{
					caught = false,
					lag = 0,
					left = false,
					p = 32.82368421052632,
					seg = 8,
					through = true,
					well = 0,
				},
			},
			slam = 0.5,
			smashed = 8,
			speed = 0,
			tick = 985,
		},
	},
	["step: the shutter slams"] = {
		events = {
			{
				kind = "Slam",
				tick = 1000,
			},
		},
		state = {
			arrival = "Middle",
			c = 31.19799999999967,
			closeTicks = 0,
			cue = 3,
			difficulty = "Standard",
			history = {
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
			},
			hold = 0,
			loom = 0,
			minGap = 1.5853339912280369,
			outcome = "Success",
			quarry = 0,
			runners = {
				{
					caught = false,
					lag = 0,
					left = false,
					p = 32.82368421052632,
					seg = 8,
					through = true,
					well = 0,
				},
			},
			slam = 0,
			smashed = 8,
			speed = 0,
			tick = 1000,
		},
	},
	["step: an outcome is final"] = {
		events = {},
		state = {
			arrival = "Middle",
			c = 31.19799999999967,
			closeTicks = 0,
			cue = 3,
			difficulty = "Standard",
			history = {
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
				31.19799999999967,
			},
			hold = 0,
			loom = 0,
			minGap = 1.5853339912280369,
			outcome = "Success",
			quarry = 0,
			runners = {
				{
					caught = false,
					lag = 0,
					left = false,
					p = 32.82368421052632,
					seg = 8,
					through = true,
					well = 0,
				},
			},
			slam = 0,
			smashed = 8,
			speed = 0,
			tick = 1000,
		},
	},
	["step: the third close tick catches; alone, that is a wipe"] = {
		events = {
			{
				id = "Gap",
				kind = "Catch",
				slot = 1,
				tick = 76,
			} :: any,
			{
				kind = "Wipe",
				tick = 76,
			},
		},
		state = {
			arrival = "Middle",
			c = -0.18733333333333585,
			closeTicks = 0,
			cue = 0,
			difficulty = "Standard",
			gap = 0.18733333333333585,
			history = {
				-0.18733333333333585,
				-0.21600000000000252,
				-0.2446666666666692,
				-0.27333333333333587,
				-0.30200000000000254,
				-0.3306666666666692,
				-0.3593333333333359,
				-0.38800000000000257,
				-0.41666666666666924,
				-0.4453333333333359,
				-0.4740000000000026,
				-0.5026666666666693,
				-0.5313333333333359,
			},
			hold = 3,
			loom = 0,
			minGap = 0.18733333333333585,
			outcome = "Wipe",
			quarry = 1,
			runners = {
				{
					caught = true,
					lag = 0,
					left = false,
					p = 0,
					seg = 2,
					through = false,
					well = 0,
				},
			},
			smashed = 0,
			speed = 16.340000000000146,
			tick = 76,
		},
	},
	["step: the gap opens again"] = {
		events = {},
		state = {
			arrival = "Middle",
			c = -0.21600000000000252,
			closeTicks = 0,
			cue = 0,
			difficulty = "Standard",
			gap = 0.8475789473684237,
			history = {
				-0.21600000000000252,
				-0.2446666666666692,
				-0.27333333333333587,
				-0.30200000000000254,
				-0.3306666666666692,
				-0.3593333333333359,
				-0.38800000000000257,
				-0.41666666666666924,
				-0.4453333333333359,
				-0.4740000000000026,
				-0.5026666666666693,
				-0.5313333333333359,
				-0.5600000000000025,
			},
			hold = 0,
			loom = 0,
			minGap = 0.2446666666666692,
			quarry = 1,
			runners = {
				{
					caught = false,
					lag = 0,
					left = false,
					p = 0.6315789473684211,
					seg = 2,
					through = false,
					well = 0,
				},
			},
			smashed = 0,
			speed = 16.339999999999932,
			tick = 75,
		},
	},
	["step: the loom begins"] = {
		events = {
			{
				kind = "Loom",
				slot = 1,
				tick = 227,
			},
		},
		state = {
			arrival = "Middle",
			c = 5.8746666666666805,
			closeTicks = 0,
			cue = 1,
			difficulty = "Standard",
			history = {
				5.8746666666666805,
				5.837333333333347,
				5.800000000000013,
				5.7626666666666795,
				5.725333333333346,
				5.688000000000012,
				5.6506666666666785,
				5.613333333333345,
				5.576000000000011,
				5.5386666666666775,
				5.501333333333344,
				5.46400000000001,
				5.4266666666666765,
			},
			hold = 0,
			loom = 0.03333333333333333,
			minGap = 1.6959824561403387,
			quarry = 1,
			runners = {
				{
					caught = false,
					lag = 0,
					left = false,
					p = 7.502631578947368,
					seg = 4,
					through = false,
					well = 1,
				},
			},
			smashed = 2,
			speed = 12.426277372263002,
			tick = 227,
		},
	},
	["step: it reaches in"] = {
		events = {
			{
				id = "ReachIn",
				kind = "Catch",
				slot = 1,
				tick = 732,
			} :: any,
			{
				kind = "Wipe",
				tick = 732,
			},
		},
		state = {
			arrival = "Middle",
			c = 18.073684210526313,
			closeTicks = 0,
			cue = 2,
			difficulty = "Nightmare",
			history = {
				18.073684210526313,
				18.073684210526313,
				18.073684210526313,
				18.073684210526313,
				18.073684210526313,
				18.073684210526313,
				18.073684210526313,
				18.073684210526313,
				18.073684210526313,
				18.073684210526313,
				18.073684210526313,
				18.073684210526313,
				18.073684210526313,
			},
			hold = 3,
			loom = 0,
			minGap = 1.1790006578947612,
			outcome = "Wipe",
			quarry = 1,
			runners = {
				{
					caught = true,
					lag = 0,
					left = false,
					p = 18.373684210526314,
					seg = 6,
					through = false,
					well = 2,
				},
			},
			smashed = 5,
			speed = 0,
			tick = 732,
		},
	},
	["step: holding after a catch"] = {
		events = {
			{
				kind = "Quarry",
				slot = 3,
				tick = 77,
			},
		},
		state = {
			arrival = "Middle",
			c = -0.18733333333333585,
			closeTicks = 0,
			cue = 0,
			difficulty = "Standard",
			history = {
				-0.18733333333333585,
				-0.18733333333333585,
				-0.21600000000000252,
				-0.2446666666666692,
				-0.27333333333333587,
				-0.30200000000000254,
				-0.3306666666666692,
				-0.3593333333333359,
				-0.38800000000000257,
				-0.41666666666666924,
				-0.4453333333333359,
				-0.4740000000000026,
				-0.5026666666666693,
			},
			hold = 2.966666666666667,
			loom = 0,
			minGap = 0.18733333333333585,
			quarry = 3,
			runners = {
				{
					caught = false,
					lag = 0,
					left = false,
					p = 2.5666256578947357,
					seg = 3,
					through = false,
					well = 0,
				} :: any,
				{
					caught = false,
					lag = 0,
					left = false,
					p = 2.4960526315789475,
					seg = 3,
					through = false,
					well = 0,
				},
				{
					caught = false,
					lag = 0,
					left = false,
					p = 2.1666842105263147,
					seg = 2,
					through = false,
					well = 0,
				},
				{
					caught = true,
					lag = 0,
					left = false,
					p = 0,
					seg = 2,
					through = false,
					well = 0,
				},
			},
			smashed = 0,
			speed = 0,
			tick = 77,
		},
	},
	["step: a late report against the rail's history"] = {
		events = {},
		state = {
			arrival = "Middle",
			c = -1.158666666666667,
			closeTicks = 0,
			cue = 0,
			difficulty = "Standard",
			gap = 1.368,
			history = {
				-1.158666666666667,
				-1.1873333333333336,
				-1.2160000000000002,
				-1.2446666666666668,
				-1.2733333333333334,
				-1.302,
				-1.3306666666666667,
				-1.368,
				-1.4053333333333335,
				-1.442666666666667,
				-1.4800000000000004,
				-1.5173333333333339,
				-1.5546666666666673,
			},
			hold = 0,
			loom = 0,
			minGap = 1.368,
			quarry = 1,
			runners = {
				{
					caught = false,
					lag = 7,
					left = false,
					p = 0,
					seg = 2,
					through = false,
					well = 0,
				},
			},
			smashed = 0,
			speed = 16.34000000000004,
			tick = 40,
		},
	},
	["step: a runner leaves"] = {
		events = {
			{
				kind = "Left",
				slot = 2,
				tick = 100,
			},
		},
		state = {
			arrival = "Middle",
			c = -0.18733333333333585,
			closeTicks = 0,
			cue = 0,
			difficulty = "Standard",
			history = {
				-0.18733333333333585,
				-0.18733333333333585,
				-0.18733333333333585,
				-0.18733333333333585,
				-0.18733333333333585,
				-0.18733333333333585,
				-0.18733333333333585,
				-0.18733333333333585,
				-0.18733333333333585,
				-0.18733333333333585,
				-0.18733333333333585,
				-0.18733333333333585,
				-0.18733333333333585,
			},
			hold = 2.200000000000003,
			loom = 0,
			minGap = 0.18733333333333585,
			quarry = 3,
			runners = {
				{
					caught = false,
					lag = 0,
					left = false,
					p = 3.3333157894736845,
					seg = 3,
					through = false,
					well = 0,
				} :: any,
				{
					caught = false,
					lag = 0,
					left = true,
					p = 3.1000000000000005,
					seg = 3,
					through = false,
					well = 0,
				},
				{
					caught = false,
					lag = 0,
					left = false,
					p = 2.933315789473685,
					seg = 3,
					through = false,
					well = 0,
				},
				{
					caught = true,
					lag = 0,
					left = false,
					p = 0,
					seg = 2,
					through = false,
					well = 0,
				},
			},
			smashed = 0,
			speed = 0,
			tick = 100,
		},
	},
	["step: a missing report keeps the runner"] = {
		events = {},
		state = {
			arrival = "Middle",
			c = 4.866666666666672,
			closeTicks = 0,
			cue = 1,
			difficulty = "Standard",
			gap = 1.7666491228070127,
			history = {
				4.866666666666672,
				4.829333333333338,
				4.792000000000004,
				4.754666666666671,
				4.717333333333337,
				4.680000000000003,
				4.64266666666667,
				4.605333333333336,
				4.568000000000002,
				4.530666666666669,
				4.493333333333335,
				4.456000000000001,
				4.418666666666668,
			},
			hold = 0,
			loom = 0,
			minGap = 1.7666491228070127,
			quarry = 1,
			runners = {
				{
					caught = false,
					lag = 0,
					left = false,
					p = 6.633315789473684,
					seg = 4,
					through = false,
					well = 0,
				},
			},
			smashed = 2,
			speed = 21.280000000000427,
			tick = 200,
		},
	},
	["step: the speed cap on a fast course"] = {
		events = {
			{
				kind = "Quarry",
				slot = 1,
				tick = 1,
			},
		},
		state = {
			arrival = "Test",
			c = -2.562666666666667,
			closeTicks = 0,
			cue = 0,
			difficulty = "Standard",
			gap = 2.562666666666667,
			history = {
				-2.562666666666667,
				-2.6,
			},
			hold = 0,
			loom = 0,
			minGap = 2.562666666666667,
			quarry = 1,
			runners = {
				{
					caught = false,
					lag = 0,
					left = false,
					p = 0,
					seg = 2,
					through = false,
					well = 0,
				},
			},
			smashed = 0,
			speed = 21.28,
			tick = 1,
		},
	},
	["botTrace: a clean runner"] = {
		{
			{
				x = 89.167,
				z = 0,
			},
		} :: any,
		{
			{
				x = 88.333,
				z = 0,
			},
		},
		{
			{
				x = 87.5,
				z = 0,
			},
		},
	},
	["botTrace: a stall on reaching a coordinate"] = {
		{
			{
				x = 91.667,
				z = 0,
			},
		} :: any,
		{
			{
				x = 90.833,
				z = 0,
			},
		},
		{
			{
				x = 90,
				z = 0,
			},
		},
		{
			{
				x = 90,
				z = 0,
			},
		},
		{
			{
				x = 90,
				z = 0,
			},
		},
		{
			{
				x = 89.167,
				z = 0,
			},
		},
	},
	["botTrace: a stall some ticks after the last"] = {
		{
			{
				x = 90,
				z = 0,
			},
		} :: any,
		{
			{
				x = 89.167,
				z = 0,
			},
		},
		{
			{
				x = 88.333,
				z = 0,
			},
		},
		{
			{
				x = 88.333,
				z = 0,
			},
		},
		{
			{
				x = 87.5,
				z = 0,
			},
		},
		{
			{
				x = 86.667,
				z = 0,
			},
		},
	},
	["botTrace: a fall into the well"] = {
		{
			{
				x = 50,
				z = 19.583,
			},
		} :: any,
		{
			{
				x = 50,
				z = 20.417,
			},
		},
		{
			{
				x = 50,
				y = -10,
				z = 25,
			},
		},
		{
			{
				x = 50,
				y = -10,
				z = 25,
			},
		},
		{
			{
				x = 50,
				z = 30.833,
			},
		},
		{
			{
				x = 50,
				z = 31.667,
			},
		},
	},
	["botTrace: a camper"] = {
		{
			{
				x = 89.167,
				z = 0,
			},
		} :: any,
		{
			{
				x = 88.333,
				z = 0,
			},
		},
		{
			{
				x = 88.333,
				z = 0,
			},
		},
		{
			{
				x = 88.333,
				z = 0,
			},
		},
	},
	["botTrace: late reports"] = {
		{
			{
				lag = 3,
				x = 89.167,
				z = 0,
			} :: any,
			{
				x = 89.167,
				z = 0,
			},
		} :: any,
		{
			{
				lag = 3,
				x = 88.333,
				z = 0,
			} :: any,
			{
				x = 88.333,
				z = 0,
			},
		},
	},
	["wellOf: by id"] = {
		d0 = 60,
		d1 = 70,
		e = 2.55,
		exit = 2.95,
		id = "W",
	},
	["afterAttempt: through"] = {
		freeLeft = 2,
		next = "Tower",
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
}

function ChaseRules.golden(): { GoldenRow }
	local rows: { GoldenRow } = {}
	local function row(name: string, fn: string, args: { any })
		table.insert(rows, { name = name, fn = fn, args = args, expect = EXPECT[name] })
	end
	local dt = 1 / ChaseConfig.TickRate
	local test = TEST_COURSE
	local function fixture(arrival: string, id: string): number
		for _, f in (ChaseConfig.Courses :: any)[arrival].fixtures do
			if f.id == id then
				return f.t0
			end
		end
		error("ChaseRules.golden: no fixture " .. id)
	end
	-- a scenario's trace, cut at the tick its attempt ends
	local function scenario(difficulty: string, arrival: string, bots: { Bot }): Trace
		local course = (ChaseConfig.Courses :: any)[arrival]
		local trace: Trace =
			{ difficulty = difficulty, arrival = arrival, ticks = ChaseRules.botTrace(course, bots, 1500) }
		local log = ChaseRules.replay(trace)
		local ticks: { { Input } } = {}
		for i = 1, log[#log].tick do
			ticks[i] = trace.ticks[i]
		end
		trace.ticks = ticks
		return trace
	end
	-- the states a scenario passes through (states[1] is the start, states[i + 1] follows ticks[i])
	local function states(trace: Trace): { State }
		local list = { ChaseRules.new(trace.difficulty, trace.arrival, #trace.ticks[1]) }
		for i, inputs in trace.ticks do
			list[i + 1] = ChaseRules.step(list[i], inputs, dt).state
		end
		return list
	end
	-- a step row from tick i of a scenario
	local function stepRow(name: string, trace: Trace, i: number, inputs: { Input }?)
		row(name, "step", { states(trace)[i], inputs or trace.ticks[i], dt })
	end
	local function firstTick(trace: Trace, when: (State, State) -> boolean): number
		local list = states(trace)
		for i = 2, #list do
			if when(list[i - 1], list[i]) then
				return i - 1
			end
		end
		error("ChaseRules.golden: no such tick")
	end

	row("timeAt: before the door", "timeAt", { test, -20 })
	row("timeAt: in the pen", "timeAt", { test, -5 })
	row("timeAt: in the corner's slow zone", "timeAt", { test, 40 })
	row("timeAt: the shutter", "timeAt", { test, 80 })
	row("timeAt: beyond the shutter", "timeAt", { test, 99 })
	row("distanceAt: before the door", "distanceAt", { test, -1 })
	row("distanceAt: in the corner's slow zone", "distanceAt", { test, 1.6 })
	row("distanceAt: the shutter", "distanceAt", { test, 3.35 })
	row("distanceAt: beyond the shutter", "distanceAt", { test, 4 })
	row("pointAt: before the door", "pointAt", { test, -20 })
	row("pointAt: on the first straight", "pointAt", { test, 20 })
	row("pointAt: after the corner", "pointAt", { test, 60 })
	row("pointAt: beyond the shutter", "pointAt", { test, 200 })
	row("project: the next segment is too far", "project", { test, 1, 95, 2 })
	row("project: the next segment within the hysteresis", "project", { test, 1, 91, 0.5 })
	row("project: round the corner", "project", { test, 2, 50.5, 1 })
	row("project: the last segment, past its end", "project", { test, 3, 52, 60 })
	row("rate: Standard at the hold gap", "rate", { "Standard", 1.6 })
	row("rate: Standard above it", "rate", { "Standard", 1.61 })
	row("rate: Nightmare below it", "rate", { "Nightmare", 1.0 })
	row("rate: Nightmare above it", "rate", { "Nightmare", 2 })
	local function runner(fields: { [string]: any }): Runner
		local r: { [string]: any } = { seg = 1, well = 0, lag = 0, caught = false, through = false, left = false }
		for k, v in fields do
			r[k] = v
		end
		return (r :: any) :: Runner
	end
	row("quarryOf: nobody has reported", "quarryOf", { { runner({}) } })
	row("quarryOf: the smallest progress", "quarryOf", { { runner({ p = 3 }), runner({ p = 1 }), runner({ p = 2 }) } })
	row("quarryOf: a tie goes to the lower slot", "quarryOf", { { runner({ p = 1 }), runner({ p = 1 }) } })
	row("quarryOf: caught, through and left runners are not chased", "quarryOf", {
		{
			runner({ p = 0, caught = true }),
			runner({ p = 0.5, through = true }),
			runner({ p = 0.2, left = true }),
			runner({ p = 4 }),
		},
	})
	row("new: Standard from the middle, two runners", "new", { "Standard", "Middle", 2 })
	row("new: Nightmare from the north, alone", "new", { "Nightmare", "North", 1 })

	-- whole attempts: §4.5's runs, a co-op straggler, a mid-pack faller and a lagged report
	local clean = scenario("Standard", "Middle", { {} })
	local cleanNorth = scenario("Nightmare", "North", { {} })
	local bump =
		scenario("Standard", "South", { { events = { { kind = "Stall", at = fixture("South", "H2"), ticks = 15 } } } })
	local bumpThenBar: { BotEvent } = {
		{ kind = "Stall", at = fixture("Middle", "H2"), ticks = 15 },
		{ kind = "Stall", delay = 75, ticks = 24 },
	}
	local bumpBar = scenario("Nightmare", "Middle", { { events = bumpThenBar } })
	local fall = scenario("Standard", "Middle", { { events = { { kind = "Fall", well = "L1", ticks = 78 } } } })
	local camper = scenario("Nightmare", "Middle", { { events = { { kind = "Fall", well = "L2", ticks = 1000 } } } })
	local gate = scenario("Standard", "Middle", { { events = { { kind = "Stop", at = 0 } } } })
	local lagged = scenario("Standard", "Middle", { { lag = 7, events = { { kind = "Stop", at = 0 } } } })
	local squad = scenario("Standard", "Middle", {
		{},
		{ start = -0.2 },
		{ start = -0.4 },
		{ start = -0.6, events = { { kind = "Stall", at = 0, ticks = 60 } } },
	})
	local midPack = scenario("Nightmare", "Middle", {
		{},
		{ start = -0.3, events = { { kind = "Fall", well = "L1", ticks = 78 } } },
		{ start = -0.6 },
	})
	row("replay: Standard, middle, clean", "replay", { clean })
	row("replay: Nightmare, north, clean", "replay", { cleanNorth })
	row("replay: Standard, south, one bumped hurdle", "replay", { bump })
	row("replay: Nightmare, middle, a bump then a slow bar 3 s later", "replay", { bumpBar })
	row("replay: Standard, middle, a fall then clean", "replay", { fall })
	row("replay: Nightmare, middle, staying in a well", "replay", { camper })
	row("replay: Standard, middle, standing at the gate", "replay", { gate })
	row("replay: Standard, middle, standing at the gate, reports 7 ticks late", "replay", { lagged })
	row("replay: Standard, middle, four runners, the straggler caught", "replay", { squad })
	row("replay: Nightmare, middle, a mid-pack faller", "replay", { midPack })

	-- single ticks
	stepRow("step: the first tick at the gate", clean, 1)
	stepRow("step: the held gap", clean, 400)
	stepRow(
		"step: a lightning cue",
		clean,
		firstTick(clean, function(a, b)
			return b.cue > a.cue
		end)
	)
	stepRow(
		"step: a hurdle smashed",
		clean,
		firstTick(clean, function(a, b)
			return b.smashed > a.smashed
		end)
	)
	stepRow(
		"step: through the shutter",
		clean,
		firstTick(clean, function(a, b)
			return b.runners[1].through and not a.runners[1].through
		end)
	)
	stepRow("step: the shutter slams", clean, #clean.ticks)
	row("step: an outcome is final", "step", { states(clean)[#clean.ticks + 1], clean.ticks[#clean.ticks], dt })
	stepRow("step: the third close tick catches; alone, that is a wipe", gate, #gate.ticks)
	local close = firstTick(gate, function(_, b)
		return b.closeTicks == 1
	end)
	stepRow("step: the gap opens again", gate, close + 1, { { x = 330, z = 144 } })
	stepRow(
		"step: the loom begins",
		fall,
		firstTick(fall, function(_, b)
			return b.loom > 0
		end)
	)
	stepRow("step: it reaches in", camper, #camper.ticks)
	stepRow("step: holding after a catch", squad, firstTick(squad, function(a, b)
		return b.runners[4].caught and not a.runners[4].caught
	end) + 1)
	stepRow("step: a late report against the rail's history", lagged, 40)
	stepRow("step: a runner leaves", squad, 100, {
		squad.ticks[100][1],
		{ x = 0, z = 0, left = true },
		squad.ticks[100][3],
		squad.ticks[100][4],
	})
	stepRow("step: a missing report keeps the runner", clean, 200, {})
	row("step: the speed cap on a fast course", "step", {
		ChaseRules.new("Standard", "Test", 1, test),
		{ { x = 90, z = 0 } },
		dt,
		test,
	})

	-- the scripted runners
	row("botTrace: a clean runner", "botTrace", { test, { {} }, 3 })
	row("botTrace: a stall on reaching a coordinate", "botTrace", {
		test,
		{ { start = -0.1, events = { { kind = "Stall", at = 0, ticks = 2 } } } },
		6,
	})
	local twoStalls: { BotEvent } = { { kind = "Stall", at = 0, ticks = 1 }, { kind = "Stall", delay = 2, ticks = 1 } }
	local lateAndOnTime: { Bot } = { { lag = 3 }, {} }
	row("botTrace: a stall some ticks after the last", "botTrace", {
		test,
		{ { events = twoStalls } },
		6,
	})
	row("botTrace: a fall into the well", "botTrace", {
		test,
		{ { start = 2.5, events = { { kind = "Fall", well = "W", ticks = 2 } } } },
		6,
	})
	row("botTrace: a camper", "botTrace", { test, { { events = { { kind = "Stop", at = 0.05 } } } }, 4 })
	row("botTrace: late reports", "botTrace", { test, lateAndOnTime, 2 })
	row("wellOf: by id", "wellOf", { test, "W" })

	row("afterAttempt: through", "afterAttempt", { "Standard", 1, "Success", 0 })
	row("afterAttempt: a free retry", "afterAttempt", { "Standard", 1, "Wipe", 0 })
	row("afterAttempt: the last free retry", "afterAttempt", { "Standard", 3, "Wipe", 0 })
	row("afterAttempt: a retry for a respawn", "afterAttempt", { "Standard", 4, "Wipe", 2 })
	row("afterAttempt: no respawn left", "afterAttempt", { "Standard", 4, "Wipe", 0 })
	row("afterAttempt: Nightmare's last free retry", "afterAttempt", { "Nightmare", 2, "Wipe", 0 })
	row("afterAttempt: Nightmare beyond the free ones", "afterAttempt", { "Nightmare", 3, "Wipe", 1 })
	return rows
end

return ChaseRules
