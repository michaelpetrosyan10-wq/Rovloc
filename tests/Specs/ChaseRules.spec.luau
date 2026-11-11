--!strict
-- ChaseRules: every golden row holds, and §4.5's rules and its outcome table hold on all three arrivals and both
-- difficulties. The table's numbers, the course lengths, the rates' limits and the hold gaps are written here from
-- the spec's text, never read from ChaseConfig, so a wrong config cannot pass by agreeing with itself.
--
-- The scenarios are ChaseRules.botTrace's scripted runners: one standing at the gate at t0, running the centre line
-- at the clean pace. A mistake is a stall (time with no progress): a bump 15 ticks (0.5 s), a slow bar 24 (0.8 s);
-- "N s apart" and "N s later" are start to start. Mistakes are made at a fixture after the gap has settled
-- (8.3 [8.0] s), and a row's number is its worst case over those fixtures. A fall drops into the well at its entry
-- and climbs out at its exit 78 ticks (2.6 s) later.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ChaseConfig = require(ReplicatedStorage.Shared.Config.ChaseConfig)
local ChaseRules = require(ReplicatedStorage.Shared.Rules.ChaseRules)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Bot = ChaseRules.Bot
type BotEvent = ChaseRules.BotEvent
type State = ChaseRules.State

local DT = 1 / 30
local ARRIVALS = { "Middle", "North", "South" }
local DIFFICULTIES = { "Standard", "Nightmare" }
-- from §4.5's text
local HOLD_GAP = { Standard = 1.6, Nightmare = 1.2 }
local SPEED_CAP = { Standard = 21.3, Nightmare = 21.9 }
local OUTSIDE_CAP = 18.5 -- I4: the monster's top speed outside the two scripted chases
local SETTLE = { Standard = 8.3, Nightmare = 8.0 }
local FREE: { [string]: number } = { Standard = 3, Nightmare = 2 }

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

type Run = {
	outcome: string?,
	tick: number,
	minGap: number,
	settleTick: number?,
	catches: { { tick: number, slot: number, how: string } },
	looms: number,
	rejoin: number?,
	states: { State },
}

-- Steps a scenario to its end, keeping every state.
local function run(difficulty: string, arrival: string, bots: { Bot }): Run
	local course = (ChaseConfig.Courses :: any)[arrival]
	local inputs = ChaseRules.botTrace(course, bots, 1500)
	local state = ChaseRules.new(difficulty, arrival, #bots)
	local result: Run = { tick = 0, minGap = math.huge, catches = {}, looms = 0, states = { state } }
	local looming = false
	for _, tick in inputs do
		local step = ChaseRules.step(state, tick, DT)
		state = step.state
		table.insert(result.states, state)
		for _, e in step.events do
			if e.kind == "Catch" then
				table.insert(result.catches, { tick = e.tick, slot = e.slot :: number, how = e.id :: string })
			elseif e.kind == "Loom" then
				result.looms += 1
			end
		end
		local gap = state.gap
		if gap ~= nil then
			result.minGap = math.min(result.minGap, gap)
			if result.settleTick == nil and gap <= HOLD_GAP[difficulty] then
				result.settleTick = state.tick
			end
			if looming and result.rejoin == nil then
				result.rejoin = gap
			end
		end
		looming = state.loom > 0
		if state.outcome ~= nil then
			break
		end
	end
	result.outcome = state.outcome
	result.tick = state.tick
	return result
end

local function fixtures(arrival: string, kind: string, from: number, room: number): { number }
	local course = (ChaseConfig.Courses :: any)[arrival]
	local out: { number } = {}
	for _, f in course.fixtures do
		if f.kind == kind and f.t0 > from and f.t0 + room < course.cleanTime then
			table.insert(out, f.t0)
		end
	end
	return out
end

local function stall(at: number, ticks: number): BotEvent
	return { kind = "Stall", at = at, ticks = ticks }
end

local function after(delay: number, ticks: number): BotEvent
	return { kind = "Stall", delay = delay, ticks = ticks }
end

-- The worst (smallest) gap of a mistake made at each fixture of a kind after the gap has settled; every one escapes.
local function worst(
	t: Expect,
	difficulty: string,
	arrival: string,
	kind: string,
	room: number,
	events: (number) -> { BotEvent }
): number
	local low = math.huge
	local list = fixtures(arrival, kind, SETTLE[difficulty], room)
	t.truthy(#list > 0, "a fixture to make the mistake at")
	for _, at in list do
		local r = run(difficulty, arrival, { { events = events(at) } })
		t.eq(r.outcome, "Success", string.format("%s %s: the mistake at %.2f escapes", difficulty, arrival, at))
		low = math.min(low, r.minGap)
	end
	return low
end

-- Every one of a mistake made at each fixture of a kind after the gap has settled is caught.
local function fatal(t: Expect, difficulty: string, arrival: string, kind: string, events: (number) -> { BotEvent })
	local list = fixtures(arrival, kind, SETTLE[difficulty], 3.5)
	t.truthy(#list > 0, "a fixture to make the mistake at")
	for _, at in list do
		local r = run(difficulty, arrival, { { events = events(at) } })
		t.eq(r.outcome, "Wipe", string.format("%s %s: the mistake at %.2f is caught", difficulty, arrival, at))
	end
end

local function checkTable(t: Expect, difficulty: string, row: { [string]: any })
	for _, arrival in ARRIVALS do
		local label = difficulty .. " " .. arrival
		-- clean: never caught; the gap settles at the hold gap after 8.3 [8.0] s and never drops below the row's floor
		local clean = run(difficulty, arrival, { {} })
		t.eq(clean.outcome, "Success", label .. ": a clean run escapes")
		t.eq(#clean.catches, 0, label .. ": nobody is caught")
		t.near((clean.settleTick :: number) * DT, SETTLE[difficulty], 0.05, label .. ": the gap settles")
		t.truthy(
			clean.minGap >= row.cleanFloor,
			string.format("%s: clean gap %.4f >= %.2f", label, clean.minGap, row.cleanFloor)
		)
		t.truthy(clean.minGap < HOLD_GAP[difficulty], label .. ": the clean gap reaches the hold gap")
		-- one bumped hurdle, one bar crouch-walked
		t.near(
			worst(t, difficulty, arrival, "Hurdle", 0, function(at)
				return { stall(at, 15) }
			end),
			row.bump,
			0.01,
			label .. ": one bump"
		)
		t.near(
			worst(t, difficulty, arrival, "Bar", 0, function(at)
				return { stall(at, 24) }
			end),
			row.bar,
			0.01,
			label .. ": one slow bar"
		)
		-- two bumps 2 s apart
		t.near(
			worst(t, difficulty, arrival, "Hurdle", 2.5, function(at)
				return { stall(at, 15), after(45, 15) }
			end),
			row.twoBumps,
			0.01,
			label .. ": two bumps 2 s apart"
		)
		-- a bump, then a slow bar 3 s later; two slow bars 3 s apart
		local bumpBar = function(at: number): { BotEvent }
			return { stall(at, 15), after(75, 24) }
		end
		local twoBars = function(at: number): { BotEvent }
			return { stall(at, 24), after(66, 24) }
		end
		if row.bumpBar == "caught" then
			fatal(t, difficulty, arrival, "Hurdle", bumpBar)
		else
			t.near(
				worst(t, difficulty, arrival, "Hurdle", 3.5, bumpBar),
				row.bumpBar,
				0.01,
				label .. ": a bump then a slow bar"
			)
		end
		if row.twoBars == "caught" then
			fatal(t, difficulty, arrival, "Bar", twoBars)
		else
			t.near(worst(t, difficulty, arrival, "Bar", 3.5, twoBars), row.twoBars, 0.01, label .. ": two slow bars")
		end
		-- the longest single stall survived, at every fixture after the gap settles; one tick more is caught somewhere
		local all: { number } = {}
		for _, kind in { "Hurdle", "Bar" } do
			for _, at in fixtures(arrival, kind, SETTLE[difficulty], 1.6) do
				table.insert(all, at)
			end
		end
		local caughtOnce = false
		for _, at in all do
			t.eq(
				run(difficulty, arrival, { { events = { stall(at, row.longest) } } }).outcome,
				"Success",
				label .. ": the longest stall"
			)
			caughtOnce = caughtOnce
				or run(difficulty, arrival, { { events = { stall(at, row.longest + 1) } } }).outcome == "Wipe"
		end
		t.truthy(caughtOnce, label .. ": a tick longer is caught")
		for _, well in { "L1", "L2" } do
			-- a fall, then clean: the Loom, the rejoin gap, escapes
			local fall = run(difficulty, arrival, { { events = { { kind = "Fall", well = well, ticks = 78 } } } })
			t.eq(fall.outcome, "Success", label .. " " .. well .. ": a fall escapes")
			t.eq(fall.looms, 1, label .. " " .. well .. ": it looms")
			t.near(fall.rejoin :: number, 0.93, 0.01, label .. " " .. well .. ": the rejoin gap")
			-- a fall, then a slow bar 2 s after rejoining
			local fallThenBar: { BotEvent } = { { kind = "Fall", well = well, ticks = 78 }, after(60, 24) }
			local fallBar = run(difficulty, arrival, { { events = fallThenBar } })
			t.eq(fallBar.outcome, "Success", label .. " " .. well .. ": a fall then a slow bar escapes")
			-- staying in the well: reached for at 8 [6] s
			local camp = run(difficulty, arrival, { { events = { { kind = "Fall", well = well, ticks = 100000 } } } })
			local fellAt = math.ceil(
				(ChaseConfig.Courses :: any)[arrival].wells[if well == "L1" then 1 else 2].e * 30 - 1e-9
			) + 1
			t.eq(#camp.catches, 1, label .. " " .. well .. ": the camper is caught")
			t.eq(camp.catches[1].how, "ReachIn", label .. " " .. well .. ": reached for")
			t.near(
				(camp.catches[1].tick - fellAt + 1) * DT,
				row.well,
				1e-6,
				label .. " " .. well .. ": caught in the well"
			)
		end
		-- standing at the gate
		local gate = run(difficulty, arrival, { { events = { { kind = "Stop", at = 0 } } } })
		t.eq(gate.outcome, "Wipe", label .. ": standing at the gate is a wipe")
		t.near(gate.catches[1].tick * DT, row.gate, 0.02, label .. ": caught at the gate")
	end
end

local function speedAndQuarry(t: Expect, difficulty: string, r: Run, label: string)
	for i = 2, #r.states do
		local before, now = r.states[i - 1], r.states[i]
		t.truthy(
			now.speed <= SPEED_CAP[difficulty] + 1e-9,
			string.format("%s: speed %.3f at tick %d", label, now.speed, now.tick)
		)
		if now.speed > OUTSIDE_CAP then
			local q = now.quarry
			local p = before.runners[q].p or now.runners[q].p
			t.truthy(
				p ~= nil and p - before.c > HOLD_GAP[difficulty],
				string.format("%s: fast only while more than the hold gap behind (tick %d)", label, now.tick)
			)
		end
		for _, runner in now.runners do
			local p = runner.p
			if p ~= nil and not (runner.caught or runner.through or runner.left) then
				t.truthy(
					now.c < p,
					string.format("%s: the rail is behind every active runner (tick %d)", label, now.tick)
				)
			end
		end
	end
	for _, catch in r.catches do
		local state = r.states[catch.tick + 1]
		t.eq(state.quarry, catch.slot, label .. ": only the quarry is caught")
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
		local meta = ChaseConfig.exportMeta()
		plain(t, meta, "meta")
		t.truthy(table.isfrozen(ChaseConfig), "frozen")
		t.eq(meta.Difficulty.Standard.SpeedCap, 21.3, "the numbers")
		t.eq(#meta.Courses.Middle.points, #ChaseConfig.Courses.Middle.points, "the courses")
		t.eq(meta.exportMeta, nil, "no functions")
	end,

	["golden: every row holds"] = function(t: Expect)
		local rows = ChaseRules.golden()
		t.truthy(#rows >= 60, "golden rows")
		local seen: { [string]: boolean } = {}
		local fns: { [string]: boolean } = {}
		local replays = 0
		for _, row in rows do
			t.falsy(seen[row.name], "a unique name: " .. row.name)
			seen[row.name] = true
			fns[row.fn] = true
			local fn = (ChaseRules :: any)[row.fn]
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
		for _, name in
			{
				"timeAt",
				"distanceAt",
				"pointAt",
				"project",
				"rate",
				"quarryOf",
				"new",
				"step",
				"replay",
				"botTrace",
				"wellOf",
				"afterAttempt",
			}
		do
			t.truthy(fns[name], "golden rows for " .. name)
		end
	end,

	["the course: §4.5's lengths, clean times and fixtures"] = function(t: Expect)
		-- 598 studs at 19 + 0.15 s for 6 corners and 3 bars; north and south +116 studs, 2 corners and 1 bar
		local middle, north, south = ChaseConfig.Courses.Middle, ChaseConfig.Courses.North, ChaseConfig.Courses.South
		t.eq(middle.length, 598, "the middle course")
		t.eq(north.length, 714, "the north course")
		t.eq(south.length, 714, "the south course")
		t.near(middle.cleanTime, 598 / 19 + 9 * 0.15, 1e-9, "32.8 s")
		t.near(north.cleanTime, 714 / 19 + 12 * 0.15, 1e-9, "39.4 s")
		t.near(south.cleanTime, north.cleanTime, 1e-9, "the south spur mirrors the north")
		local want = { H1 = 36, B1 = 74, H2 = 206, B2 = 240, H3 = 276, H4 = 410, H5 = 458, H6 = 534, B3 = 596 }
		for _, f in middle.fixtures do
			t.eq(f.d0, want[f.id], "middle fixture " .. f.id)
		end
		t.eq(#middle.fixtures, 9, "nine fixtures from the middle")
		local spur = { H0 = 66, B0 = 104 }
		for _, f in north.fixtures do
			t.eq(f.d0, spur[f.id] or (want[f.id] + 116), "north fixture " .. f.id)
		end
		t.eq(middle.wells[1].d0, 134, "L1's well from x 268")
		t.eq(middle.wells[1].d1, 146, "to x 256")
		t.eq(middle.wells[2].d0, 332, "L2's well from x 190")
		t.eq(middle.wells[2].d1, 344, "to x 178")
		-- the pen is negative: 14 studs behind the gate is -0.74
		t.near(ChaseRules.timeAt(middle, -14), -0.74, 0.005, "the pen")
		local p = ChaseRules.pointAt(north, 0)
		t.eq(p.x, 342, "north gate x")
		t.eq(p.z, 28, "north gate z")
		p = ChaseRules.pointAt(south, 0)
		t.eq(p.z, 260, "south gate z")
		p = ChaseRules.pointAt(middle, middle.length)
		t.eq(p.x, 40, "the shutter")
		t.eq(p.z, 88, "the shutter")
	end,

	["§4.5's table: Standard"] = function(t: Expect)
		checkTable(t, "Standard", {
			cleanFloor = 1.58,
			bump = 1.16,
			bar = 0.90,
			twoBumps = 0.94,
			bumpBar = 0.82,
			twoBars = 0.52,
			longest = 47, -- 1.57 s
			well = 8,
			gate = 2.53,
		})
	end,

	["§4.5's table: Nightmare"] = function(t: Expect)
		checkTable(t, "Nightmare", {
			cleanFloor = 1.17,
			bump = 0.73,
			bar = 0.45,
			twoBumps = 0.37,
			bumpBar = "caught",
			twoBars = "caught",
			longest = 30, -- 1.00 s
			well = 6,
			gate = 2.13,
		})
	end,

	["a clean run always escapes, from anywhere in the gather zone"] = function(t: Expect)
		for _, difficulty in DIFFICULTIES do
			for _, arrival in ARRIVALS do
				for _, start in { 0, -0.37, -0.74 } do
					local r = run(difficulty, arrival, { { start = start } })
					t.eq(r.outcome, "Success", string.format("%s %s from %.2f", difficulty, arrival, start))
					t.eq(#r.catches, 0, "never caught")
					speedAndQuarry(t, difficulty, r, difficulty .. " " .. arrival)
				end
				local squad = run(difficulty, arrival, { {}, { start = -0.25 }, { start = -0.5 }, { start = -0.74 } })
				t.eq(squad.outcome, "Success", difficulty .. " " .. arrival .. ": a clean squad")
				t.eq(#squad.catches, 0, "nobody in a clean squad is caught")
			end
		end
	end,

	["the chaser: at most 21.3 [21.9], above 18.5 only while more than the hold gap behind; only the quarry is caught"] = function(
		t: Expect
	)
		for _, difficulty in DIFFICULTIES do
			for _, arrival in ARRIVALS do
				local label = difficulty .. " " .. arrival
				local course = (ChaseConfig.Courses :: any)[arrival]
				local h2 = 0
				for _, f in course.fixtures do
					if f.id == "H2" then
						h2 = f.t0
					end
				end
				speedAndQuarry(
					t,
					difficulty,
					run(difficulty, arrival, { { events = { stall(h2, 15), after(75, 24) } } }),
					label
				)
				speedAndQuarry(
					t,
					difficulty,
					run(difficulty, arrival, { { events = { { kind = "Fall", well = "L1", ticks = 78 } } } }),
					label
				)
				local straggler = run(difficulty, arrival, {
					{},
					{ start = -0.3 },
					{ start = -0.6, events = { { kind = "Stop", at = 0 } } },
					{ start = -0.5, events = { { kind = "Stop", at = h2 } } },
				})
				speedAndQuarry(t, difficulty, straggler, label .. " squad")
				t.eq(#straggler.catches, 2, label .. ": the two who stop are caught")
				t.eq(straggler.catches[1].slot, 3, label .. ": the camper first")
				t.eq(straggler.catches[2].slot, 4, label .. ": then the one who stops at H2")
				t.eq(straggler.outcome, "Success", label .. ": the others escape")
			end
		end
	end,

	["a mid-pack faller never gets a clean runner caught"] = function(t: Expect)
		for _, difficulty in DIFFICULTIES do
			for _, arrival in ARRIVALS do
				for _, well in { "L1", "L2" } do
					for _, ticks in { 20, 78, 150, 100000 } do
						local r = run(difficulty, arrival, {
							{},
							{ start = -0.3, events = { { kind = "Fall", well = well, ticks = ticks } } },
							{ start = -0.6 },
						})
						local label = string.format("%s %s %s, %d ticks in the well", difficulty, arrival, well, ticks)
						for _, catch in r.catches do
							t.eq(catch.slot, 2, label .. ": only the faller can be caught")
						end
						t.eq(r.outcome, "Success", label .. ": the clean runners escape")
						speedAndQuarry(t, difficulty, r, label)
					end
				end
			end
		end
	end,

	["a report's lag is judged against the rail at its time, at most 0.4 s back"] = function(t: Expect)
		local function caughtAt(lag: number): number
			local r = run("Standard", "Middle", { { lag = lag, events = { { kind = "Stop", at = 0 } } } })
			return r.catches[1].tick
		end
		local onTime = caughtAt(0)
		t.truthy(caughtAt(7) > onTime, "a late report is caught later")
		t.eq(caughtAt(12), caughtAt(30), "rewound at most 12 ticks")
	end,

	["step is pure and a retry repeats its attempt"] = function(t: Expect)
		local course = ChaseConfig.Courses.Middle
		local bots: { Bot } = { {}, { start = -0.4, events = { { kind = "Fall", well = "L1", ticks = 78 } } } }
		local trace = { difficulty = "Standard", arrival = "Middle", ticks = ChaseRules.botTrace(course, bots, 1100) }
		local first = ChaseRules.replay(trace)
		deepEq(t, ChaseRules.replay(trace), first, "attempt 2")
		local state = ChaseRules.new("Standard", "Middle", 2)
		local copy = ChaseRules.new("Standard", "Middle", 2)
		ChaseRules.step(state, trace.ticks[1], DT)
		deepEq(t, state, copy, "the state passed in")
		t.throws(function()
			ChaseRules.new("Easy", "Middle", 1)
		end, "an unknown difficulty")
		t.throws(function()
			ChaseRules.new("Standard", "East", 1)
		end, "an unknown arrival")
		t.throws(function()
			ChaseRules.wellOf(course, "L9")
		end, "an unknown well")
	end,

	["attempts: 3 [2] free, then a squad respawn each, then the run ends"] = function(t: Expect)
		for difficulty, free in FREE do
			for attempt = 1, free do
				local a = ChaseRules.afterAttempt(difficulty, attempt, "Wipe", 0)
				t.eq(a.next, "Retry", difficulty .. ": a free retry")
				t.falsy(a.spendRespawn, "free")
				t.eq(a.freeLeft, free - attempt, "tries left")
			end
			t.eq(
				ChaseRules.afterAttempt(difficulty, free + 1, "Wipe", 1).spendRespawn,
				true,
				difficulty .. ": then a respawn"
			)
			t.eq(ChaseRules.afterAttempt(difficulty, free + 1, "Wipe", 0).next, "RunOver", difficulty .. ": none left")
			t.eq(ChaseRules.afterAttempt(difficulty, free + 3, "Success", 0).next, "Tower", difficulty .. ": through")
		end
		t.eq(ChaseRules.afterAttempt("Standard", 1, "Wipe", 0).freeLeft, 2, 'the HUD\'s "2 tries left"')
	end,
}
