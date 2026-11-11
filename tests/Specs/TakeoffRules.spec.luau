--!strict
-- TakeoffRules: every golden row holds, and §4.9's rules and its outcome table hold on all three patterns and both
-- difficulties. The table's numbers, the rows, the gap width and the steering limits are written here from the spec's
-- text, never read from TakeoffConfig, so a wrong config cannot pass by agreeing with itself.
--
-- The runs are TakeoffRules.pilot's scripted flights: it steers for each gap as fast as it can stop, holds pull-up
-- from the start (it counts from 60), and for a knocked row aims 12 into its obstacles toward the next gap.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SpecRunner = require(script.Parent.Parent.SpecRunner)
local TakeoffConfig = require(ReplicatedStorage.Shared.Config.TakeoffConfig)
local TakeoffRules = require(ReplicatedStorage.Shared.Rules.TakeoffRules)

type Expect = SpecRunner.Expect
type Plan = TakeoffRules.Plan
type State = TakeoffRules.State

local DT = 1 / 30
local DIFFICULTIES = { "Standard", "Nightmare" }
-- from §4.9's text
local ROWS = { 70, 150, 250, 360, 470, 580, 800, 910, 1020, 1130, 1240, 1350 }
local GAP = 22
local PLANE = 10
local MAX_STEP = 18
local FREE: { [string]: number } = { Standard = 3, Nightmare = 2 }
local CHASE_START: { [string]: number } = { Standard = 126, Nightmare = 118 }
local BOTH_ROWS: { Plan } = { { knocks = { 1, 2 } }, { steer = false } }

local function deepEq(t: Expect, got: any, want: any, path: string)
	if type(want) == "number" and type(got) == "number" then
		t.truthy(
			math.abs(got - want) <= 1e-9 * math.max(1, math.abs(want)),
			string.format("%s: %s ~= %s", path, tostring(got), tostring(want))
		)
	elseif type(want) == "table" and type(got) == "table" then
		for k, v in want do
			deepEq(t, got[k], v, path .. "." .. tostring(k))
		end
		for k in got do
			t.truthy(want[k] ~= nil, path .. "." .. tostring(k) .. " is not expected")
		end
	else
		t.eq(got, want, path)
	end
end

type Flight = { state: State, states: { State }, knocks: { number }, hitHim: boolean }

local function fly(difficulty: string, pattern: number, plan: Plan): Flight
	local state = TakeoffRules.new(difficulty, pattern)
	local flight: Flight = { state = state, states = { state }, knocks = {}, hitHim = false }
	while state.outcome == nil and state.tick < 2400 do
		local step = TakeoffRules.step(state, TakeoffRules.pilot(state, plan), DT)
		state = step.state
		table.insert(flight.states, state)
		for _, e in step.events do
			if e.kind == "Knock" then
				table.insert(flight.knocks, e.id :: number)
			elseif e.kind == "HitHim" then
				flight.hitHim = true
			end
		end
	end
	flight.state = state
	return flight
end

local function seconds(state: State): number
	return state.tick * DT
end

-- A plan for a set of obstacles to hit (13 is his stand).
local function planOf(set: { number }): Plan
	local knocks: { number } = {}
	local him = false
	for _, k in set do
		if k == 13 then
			him = true
		else
			table.insert(knocks, k)
		end
	end
	return { knocks = knocks, hitHim = him }
end

-- The flight hit exactly the obstacles of its set that it reached before lifting off.
local function hitAsPlanned(t: Expect, f: Flight, set: { number }, label: string)
	for _, k in f.knocks do
		t.truthy(table.find(set, k) ~= nil, label .. ": an unplanned knock on row " .. k)
	end
	for _, k in set do
		local reached = if k == 13 then f.state.passedStand else f.state.nextRow > k
		if reached then
			t.truthy(if k == 13 then f.hitHim else table.find(f.knocks, k) ~= nil, label .. ": hit " .. k)
		end
	end
end

-- Golden values are plain JSON: finite numbers, strings, booleans, arrays without holes, string-keyed tables.
local function plain(t: Expect, value: any, path: string)
	local kind = type(value)
	if kind == "number" then
		t.truthy(value == value and math.abs(value) < math.huge, path .. ": a finite number")
	elseif kind == "table" then
		local count, strings = 0, 0
		for k, v in value do
			count += 1
			if type(k) == "string" then
				strings += 1
			end
			plain(t, v, path .. "." .. tostring(k))
		end
		t.truthy(strings == count or (strings == 0 and count == #value), path .. ": an array or a string-keyed table")
	else
		t.truthy(kind == "string" or kind == "boolean", path .. ": a JSON value, not a " .. kind)
	end
end

return {
	["exportMeta: the config as plain JSON, frozen"] = function(t: Expect)
		local meta = TakeoffConfig.exportMeta()
		plain(t, meta, "meta")
		t.truthy(table.isfrozen(TakeoffConfig), "frozen")
		t.eq(meta.Rows[12], 1350, "the numbers")
		t.eq(#meta.Patterns, 3, "the patterns")
		t.eq(meta.exportMeta, nil, "no functions")
	end,

	["golden: every row holds"] = function(t: Expect)
		local rows = TakeoffRules.golden()
		local seen: { [string]: boolean } = {}
		local fns: { [string]: boolean } = {}
		local replays = 0
		for _, row in rows do
			t.falsy(seen[row.name], "a unique name: " .. row.name)
			seen[row.name] = true
			fns[row.fn] = true
			local fn = (TakeoffRules :: any)[row.fn]
			t.eq(type(fn), "function", row.name .. ": " .. row.fn)
			t.truthy(row.expect ~= nil, row.name .. ": an expectation")
			plain(t, row.args, row.name .. " args")
			plain(t, row.expect, row.name .. " expect")
			deepEq(t, fn(table.unpack(row.args, 1, #row.args)), row.expect, row.name)
			if row.fn == "replay" then
				replays += 1
			end
		end
		t.truthy(replays >= 6, "at least six whole attempts")
		for _, name in { "patternOf", "new", "step", "replay", "pilot", "validate", "afterAttempt" } do
			t.truthy(fns[name], "golden rows for " .. name)
		end
	end,

	["the rows: every gap 22 wide, the next at most 18 aside, rows 1 and 2 block the centre, row 7 is central"] = function(
		t: Expect
	)
		t.eq(#TakeoffConfig.Rows, #ROWS, "twelve rows")
		for i, s in ROWS do
			t.eq(TakeoffConfig.Rows[i], s, "row " .. i)
		end
		t.eq(TakeoffConfig.GapWidth, GAP, "gaps are 22 wide")
		t.eq(TakeoffConfig.PlaneWidth, PLANE, "the plane is 10 wide")
		t.eq(#TakeoffConfig.Patterns, 3, "three authored patterns")
		local used: { [number]: boolean } = {}
		for p, gaps in TakeoffConfig.Patterns do
			t.eq(#gaps, #ROWS, "pattern " .. p .. ": a gap per row")
			for i, x in gaps do
				t.truthy(
					x == -18 or x == 0 or x == 18,
					string.format("pattern %d row %d: centred at -18, 0 or +18", p, i)
				)
				-- the gap lies on the 60-wide runway and the plane fits it inside +-25
				t.truthy(math.abs(x) + GAP / 2 <= 30 and math.abs(x) <= 25, "on the runway")
				if i > 1 then
					t.truthy(
						math.abs(x - gaps[i - 1]) <= MAX_STEP,
						string.format("pattern %d row %d: at most 18 aside", p, i)
					)
				end
			end
			t.truthy(gaps[1] ~= 0 and gaps[2] ~= 0, "pattern " .. p .. ": rows 1 and 2 block the centre")
			t.eq(gaps[7], 0, "pattern " .. p .. ": the row after his stand is central")
		end
		for seed = 0, 63 do
			local p = TakeoffRules.patternOf(seed)
			t.truthy(p >= 1 and p <= 3, "a pattern")
			used[p] = true
		end
		t.truthy(used[1] and used[2] and used[3], "the run seed picks every pattern")
	end,

	["steering: 18 studs in 1.4 s; the tightest rows are 1.57 s apart at top speed"] = function(t: Expect)
		local state = TakeoffRules.new("Standard", 1)
		local ticks = 0
		while state.x < 18 - 2 do -- full stick, then let go: the ramp down covers the last 2
			state = TakeoffRules.step(state, { steer = 1 }, DT).state
			ticks += 1
		end
		while state.vx > 1e-9 do
			state = TakeoffRules.step(state, { steer = 0 }, DT).state
			ticks += 1
		end
		t.truthy(state.x >= 18 - 0.6 and state.x <= 18 + 0.6, string.format("steered %.2f", state.x))
		t.truthy(ticks * DT <= 1.4 + DT, string.format("in %.3f s", ticks * DT))
		-- the fastest run there is (no knock, never airborne) crosses consecutive rows at least 1.57 s apart
		local fastest = fly("Standard", 1, { pull = false })
		local crossed: { number } = {}
		for i = 2, #fastest.states do
			if fastest.states[i].nextRow > fastest.states[i - 1].nextRow then
				table.insert(crossed, fastest.states[i].tick)
			end
		end
		t.eq(#crossed, #ROWS, "every row crossed")
		local tightest = math.huge
		for i = 2, #crossed do
			tightest = math.min(tightest, (crossed[i] - crossed[i - 1]) * DT)
		end
		t.near(tightest, 110 / 70, 0.034, "the tightest pair, at top speed")
		t.truthy(tightest > ticks * DT, "a clean pilot always has time")
		-- x stays within +-25 and moves at most 16 studs/s
		state = TakeoffRules.new("Standard", 1)
		for _ = 1, 120 do
			local after = TakeoffRules.step(state, { steer = 1 }, DT).state
			t.truthy(math.abs(after.x) <= 25 + 1e-9, "within the runway")
			t.truthy(math.abs(after.x - state.x) <= 16 * DT + 1e-9, "at most 16 across")
			state = after
		end
	end,

	["a clean takeoff lifts off at 25.0 s, 782 studs, on both difficulties and every pattern"] = function(t: Expect)
		for _, difficulty in DIFFICULTIES do
			for pattern = 1, 3 do
				local label = string.format("%s pattern %d", difficulty, pattern)
				local f = fly(difficulty, pattern, {})
				t.eq(f.state.outcome, "Airborne", label .. ": airborne")
				t.eq(#f.knocks, 0, label .. ": no knock")
				t.falsy(f.hitHim, label .. ": passes him")
				t.near(seconds(f.state), 25.0, 0.02, label .. ": wheels up")
				t.near(f.state.s, 782, 1, label .. ": 782 studs")
				local closest = if difficulty == "Standard" then 29.6 else 21.6
				t.near(f.state.closest :: number, closest, 0.05, label .. ": his closest")
				t.near((f.state.closestTick :: number) * DT, 8.8, 0.05, label .. ": at 8.8 s")
			end
		end
	end,

	["§4.9's table: Standard"] = function(t: Expect)
		for pattern = 1, 3 do
			local label = "Standard pattern " .. pattern
			local row1 = fly("Standard", pattern, { knocks = { 1 } })
			t.eq(row1.state.outcome, "Airborne", label .. ": row 1 hit, airborne")
			t.near(row1.state.closest :: number, 8.6, 0.05, label .. ": he rakes the rudder")
			t.near(seconds(row1.state), 28.0, 0.02, label .. ": up at 28.0 s")
			t.near(row1.state.s, 828, 1, label .. ": 828 studs")
			for _, plan in BOTH_ROWS do
				local f = fly("Standard", pattern, plan)
				t.eq(f.state.outcome, "TailTorn", label .. ": rows 1 and 2 hit")
				t.near(seconds(f.state), 13.0, 0.05, label .. ": caught at 13.0 s")
			end
			local latest3 = 0
			for a = 1, 13 do
				for b = a + 1, 13 do
					for c = b + 1, 13 do
						local set = { a, b, c }
						if not (a == 1 and b == 2) then
							local f = fly("Standard", pattern, planOf(set))
							hitAsPlanned(t, f, set, label)
							t.eq(f.state.outcome, "Airborne", label .. ": 3 knocks " .. table.concat(set, ","))
							latest3 = math.max(latest3, f.state.s)
						end
					end
				end
			end
			t.truthy(latest3 <= 1365, string.format("%s: 3 knocks airborne by 1,365 (%.1f)", label, latest3))
			t.truthy(latest3 > 1355, label .. ": the latest is near 1,365")
			local latest2 = 0
			for a = 2, 13 do
				for b = a + 1, 13 do
					local f = fly("Standard", pattern, planOf({ a, b }))
					t.eq(f.state.outcome, "Airborne", label .. ": 2 knocks")
					latest2 = math.max(latest2, f.state.s)
				end
			end
			t.near(latest2, 1184, 1, label .. ": 2 knocks without row 1, airborne by 1,184")
			local him = fly("Standard", pattern, { hitHim = true })
			t.truthy(him.hitHim, label .. ": hit him")
			t.near(seconds(him.state), 29.2, 0.02, label .. ": hitting only him, up at 29.2 s")
			t.near(him.state.s, 1010, 1, label .. ": at 1,010")
			local never = fly("Standard", pattern, { pull = false })
			t.eq(never.state.outcome, "Fence", label .. ": never pulling up")
			t.near(seconds(never.state), 34.7, 0.02, label .. ": off the end at 34.7 s")
			local late = fly("Standard", pattern, { pullDelay = 180 })
			t.eq(late.state.outcome, "Airborne", label .. ": 6 s late, still up")
			t.near(late.state.s, 1191, 1, label .. ": at 1,191")
		end
	end,

	["§4.9's table: Nightmare"] = function(t: Expect)
		for pattern = 1, 3 do
			local label = "Nightmare pattern " .. pattern
			local row1 = fly("Nightmare", pattern, { knocks = { 1 } })
			t.eq(row1.state.outcome, "TailTorn", label .. ": row 1 hit is caught")
			t.near(seconds(row1.state), 10.1, 0.05, label .. ": at 10.1 s")
			for _, plan in BOTH_ROWS do
				t.eq(fly("Nightmare", pattern, plan).state.outcome, "TailTorn", label .. ": rows 1 and 2 hit")
			end
			local latest2 = 0
			for a = 2, 13 do
				for b = a + 1, 13 do
					local f = fly("Nightmare", pattern, planOf({ a, b }))
					hitAsPlanned(t, f, { a, b }, label)
					t.eq(f.state.outcome, "Airborne", label .. ": 2 knocks without row 1, always airborne")
					latest2 = math.max(latest2, f.state.s)
				end
			end
			t.near(latest2, 1274, 1, label .. ": by 1,274")
			local him = fly("Nightmare", pattern, { hitHim = true })
			t.near(seconds(him.state), 30.0, 0.02, label .. ": hitting only him, up at 30.0 s")
			t.near(him.state.s, 1048, 1, label .. ": at 1,048")
			local never = fly("Nightmare", pattern, { pull = false })
			t.eq(never.state.outcome, "Fence", label .. ": never pulling up")
			t.near(seconds(never.state), 34.7, 0.02, label .. ": off the end at 34.7 s")
			local late = fly("Nightmare", pattern, { pullDelay = 180 })
			t.near(late.state.s, 1191, 1, label .. ": 6 s late, up at 1,191")
		end
	end,

	["his chase: 22 studs/s from 126 [118] behind for 16 s; the tail goes at a gap of 4"] = function(t: Expect)
		for difficulty, start in CHASE_START do
			local f = fly(difficulty, 1, { steer = false })
			for _, state in f.states do
				local t0 = state.tick * DT
				if state.tick > 0 and t0 <= 16 and state.outcome ~= "TailTorn" then
					t.truthy(state.s + start - 22 * t0 > 4, difficulty .. ": the tail holds while the gap is over 4")
				end
			end
			local last = f.state
			t.truthy(last.s + start - 22 * last.tick * DT <= 4, difficulty .. ": torn off at 4")
		end
		-- a knock never ends the run by itself: after 16 s he no longer chases
		local f = fly("Standard", 1, { knocks = { 9, 10, 11 } })
		t.eq(f.state.outcome, "Airborne", "late knocks only cost runway")
	end,

	["the authority resolves the same run from the pilot's reports, and catches a false one"] = function(t: Expect)
		for _, plan: Plan in { {}, { knocks = { 3, 8 } }, { hitHim = true } } do
			local f = fly("Standard", 2, plan)
			local authority = TakeoffRules.new("Standard", 2)
			for i = 2, #f.states do
				local pilot = f.states[i]
				local nextState = TakeoffRules.step(
					authority,
					{ x = pilot.x, pull = TakeoffRules.pilot(f.states[i - 1], plan).pull },
					DT
				).state
				t.eq(
					TakeoffRules.validate(authority, nextState, { s = pilot.s, v = pilot.v, x = pilot.x }),
					"Ok",
					"a true report"
				)
				authority = nextState
			end
			t.eq(authority.outcome, f.state.outcome, "the same outcome")
			t.eq(authority.knocks, f.state.knocks, "the same knocks")
			t.eq(authority.tick, f.state.tick, "on the same tick")
		end
		local start = TakeoffRules.new("Standard", 1)
		local nextState = TakeoffRules.step(start, { x = 0 }, DT).state
		t.eq(
			TakeoffRules.validate(start, nextState, { s = nextState.s, v = nextState.v + 1, x = 0 }),
			"Speed",
			"a faster report"
		)
		t.eq(
			TakeoffRules.validate(start, nextState, { s = nextState.s, v = nextState.v, x = 25.5 }),
			"Offset",
			"off the runway"
		)
	end,

	["step is pure and a retry repeats its attempt"] = function(t: Expect)
		local state = TakeoffRules.new("Nightmare", 3)
		local copy = TakeoffRules.new("Nightmare", 3)
		TakeoffRules.step(state, { steer = 1, pull = true }, DT)
		deepEq(t, state, copy, "the state passed in")
		local inputs = {}
		local s = state
		while s.outcome == nil do
			local input = TakeoffRules.pilot(s, { knocks = { 4 } })
			table.insert(inputs, input)
			s = TakeoffRules.step(s, input, DT).state
		end
		local trace = { difficulty = "Nightmare", pattern = 3, ticks = inputs }
		deepEq(t, TakeoffRules.replay(trace), TakeoffRules.replay(trace), "attempt 2")
		t.throws(function()
			TakeoffRules.new("Easy", 1)
		end, "an unknown difficulty")
		t.throws(function()
			TakeoffRules.new("Standard", 4)
		end, "an unknown pattern")
	end,

	["attempts: 3 [2] free, then a squad respawn each, then the run ends"] = function(t: Expect)
		for difficulty, free in FREE do
			for attempt = 1, free do
				local a = TakeoffRules.afterAttempt(difficulty, attempt, "Fence", 0)
				t.eq(a.next, "Retry", difficulty .. ": a free retry")
				t.falsy(a.spendRespawn, "free")
			end
			t.eq(
				TakeoffRules.afterAttempt(difficulty, free + 1, "TailTorn", 1).spendRespawn,
				true,
				difficulty .. ": a respawn"
			)
			t.eq(
				TakeoffRules.afterAttempt(difficulty, free + 1, "TailTorn", 0).next,
				"RunOver",
				difficulty .. ": none left"
			)
			t.eq(TakeoffRules.afterAttempt(difficulty, 1, "Airborne", 0).next, "Sunrise", difficulty .. ": wheels up")
		end
	end,
}
