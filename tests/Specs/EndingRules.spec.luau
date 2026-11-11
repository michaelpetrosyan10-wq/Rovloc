--!strict
-- EndingRules: every golden row holds, and §4.6's standoff holds (I5): the fire window is 13.5 s [10.0], a hit inside
-- it is Ending A, no shot, a lowered gun and a clear miss are Ending B, and a blocked, late or rejected shot never uses
-- the round. The window, the margins and the authority's tolerances are written here from the spec's text, never read
-- from EndingConfig, so a wrong config cannot pass by agreeing with itself.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EndingConfig = require(ReplicatedStorage.Shared.Config.EndingConfig)
local EndingRules = require(ReplicatedStorage.Shared.Rules.EndingRules)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Input = EndingRules.Input
type Shot = EndingRules.Shot
type Box = EndingRules.Box

local DT = 1 / 30
-- from §4.6's text
type Window = { opens: number, closes: number, seconds: number }
local WINDOW: { [string]: Window } = {
	Standard = { opens = 2.0, closes = 15.5, seconds = 13.5 },
	Nightmare = { opens = 2.0, closes = 12.0, seconds = 10.0 },
}
local MARGIN: { [string]: number } = { Mouse = 0.6, Gamepad = 1.2, Touch = 1.8 }
local LINES: { [string]: number } = { Standard = 4, Nightmare = 3 }
local HALF_WIDTH = 2.6 / 2 -- the Biped hitbox, 2.6 x 11 x 2.7
local HALF_HEIGHT = 11 / 2

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

type Outcome = { ending: string?, at: number, round: boolean }

-- A standoff from T_s with the monster distance away; inputs[tick] for chosen ticks.
local function standoff(difficulty: string, distance: number, inputs: { [number]: Input }): Outcome
	local state = EndingRules.new(difficulty, distance)
	for tick = 1, 900 do
		state = EndingRules.step(state, inputs[tick] or {}, DT).state
		if state.ending ~= nil then
			break
		end
	end
	return { ending = state.ending, at = state.t, round = state.round }
end

local BOX: Box = { x = 0, y = 5.5, z = 0, fx = 0, fz = 1 }

-- A shot straight down -z from 20 away, lateral offset dx, at client time at (arriving 0.1 s later), its look relayed.
local function shot(at: number, dx: number, fields: { [string]: any }?): Shot
	local s: { [string]: any } = {
		clientTime = at,
		arrival = at + 0.1,
		origin = { x = dx, y = 5, z = 20 },
		head = { x = dx, y = 5, z = 20 },
		dir = { x = 0, y = 0, z = -1 },
		looks = { { t = at, x = 0, y = 0, z = -1 } },
		device = "Mouse",
		box = BOX,
		takenAt = -5,
	}
	local extra: { [string]: any } = fields or {}
	for k, v in extra do
		s[k] = v
	end
	return (s :: any) :: Shot
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
		local meta = EndingConfig.exportMeta()
		plain(t, meta, "meta")
		t.truthy(table.isfrozen(EndingConfig), "frozen")
		t.eq(meta.Margins.Touch, 1.8, "the numbers")
		t.eq(#meta.Spots, 4, "the spots")
		t.eq(meta.exportMeta, nil, "no functions")
	end,

	["golden: every row holds"] = function(t: Expect)
		local rows = EndingRules.golden()
		local seen: { [string]: boolean } = {}
		local fns: { [string]: boolean } = {}
		local replays = 0
		for _, row in rows do
			t.falsy(seen[row.name], "a unique name: " .. row.name)
			seen[row.name] = true
			fns[row.fn] = true
			local fn = (EndingRules :: any)[row.fn]
			t.eq(type(fn), "function", row.name .. ": " .. row.fn)
			t.truthy(row.expect ~= nil, row.name .. ": an expectation")
			plain(t, row.args, row.name .. " args")
			plain(t, row.expect, row.name .. " expect")
			deepEq(t, fn(table.unpack(row.args, 1, #row.args)), row.expect, row.name)
			if row.fn == "replay" then
				replays += 1
			end
		end
		t.truthy(replays >= 6, "at least six whole standoffs")
		for _, name in
			{
				"at",
				"fireWindow",
				"timeline",
				"standoffStart",
				"fadeInSpot",
				"walkSpeed",
				"approach",
				"hitTest",
				"rewind",
				"judgeShot",
				"canFire",
				"gunButton",
				"takeReady",
				"idleDrop",
				"pickUpLineDue",
				"new",
				"step",
				"replay",
			}
		do
			t.truthy(fns[name], "golden rows for " .. name)
		end
	end,

	["the fire window is 13.5 s [10.0]"] = function(t: Expect)
		for difficulty, want in WINDOW do
			local w = EndingRules.fireWindow(difficulty)
			t.near(w.opens, want.opens, 1e-9, difficulty .. ": opens")
			t.near(w.closes, want.closes, 1e-9, difficulty .. ": closes")
			t.near(w.seconds, want.seconds, 1e-9, difficulty .. ": the window")
			local fire, contact
			for _, row in EndingRules.timeline(difficulty) do
				if row.kind == "Fire" then
					fire = row.at
				elseif row.kind == "Contact" then
					contact = row.at
				end
			end
			t.near(contact - fire, want.seconds, 1e-9, difficulty .. ": the timeline's window")
		end
		-- Nightmare's lines never overlap once "You hid" is cut; Standard keeps all four
		for difficulty, count in LINES do
			local lines = {}
			for _, row in EndingRules.timeline(difficulty) do
				if row.kind == "Line" then
					table.insert(lines, row)
				end
			end
			t.eq(#lines, count, difficulty .. ": lines")
			for i = 2, #lines do
				t.truthy(
					lines[i - 1].at + (lines[i - 1].length :: number) <= lines[i].at,
					difficulty .. ": no two lines overlap"
				)
			end
		end
	end,

	["no shot: contact at 15.5 [12.0], Ending B, from any fade-in distance"] = function(t: Expect)
		for difficulty, want in WINDOW do
			for _, distance in { 8, 13, 20, 27, 34 } do
				local o = standoff(difficulty, distance, {})
				t.eq(o.ending, "B", string.format("%s from %d: Ending B", difficulty, distance))
				t.near(o.at, want.closes, 0.05, string.format("%s from %d: contact", difficulty, distance))
				t.truthy(o.round, "the round unused")
			end
			-- the holder walking into it early: it holds until contact
			local early = standoff(difficulty, 25, { [150] = { distance = 3 } })
			t.near(early.at, want.closes, 0.05, difficulty .. ": the holder walks into it, contact still at the end")
			-- a holder backing away: the lunge, then the lightning cut by 17.0 [13.1]
			local away: { [number]: Input } = {}
			for i = math.ceil((want.closes - 0.5) * 30), 900 do
				away[i] = { distance = 60 }
			end
			local o = standoff(difficulty, 25, away)
			t.eq(o.ending, "B", difficulty .. ": the cut ends it")
			t.near(o.at, 2 + (17.0 - 2) * want.seconds / 13.5, 0.05, difficulty .. ": at the cut")
		end
	end,

	["a hit inside the window is Ending A; a lowered gun and a clear miss are Ending B"] = function(t: Expect)
		for difficulty, want in WINDOW do
			for tick = math.floor(want.opens * 30) + 1, math.floor(want.closes * 30) - 1, 17 do
				local o = standoff(difficulty, 25, { [tick] = { shot = "Hit" } })
				t.eq(o.ending, "A", string.format("%s: a hit at %.2f", difficulty, tick * DT))
				t.falsy(o.round, "the round is used")
				local verdict = EndingRules.judgeShot(difficulty, shot((tick - 1) * DT, 0))
				t.eq(verdict.verdict, "Hit", string.format("%s: judged a hit at %.2f", difficulty, (tick - 1) * DT))
				t.truthy(verdict.usesRound, "a hit uses the round")
			end
			-- lowered at 6: it walks in at 6
			local lowered = standoff(difficulty, 25, { [180] = { lowered = true } })
			t.eq(lowered.ending, "B", difficulty .. ": a lowered gun")
			t.truthy(lowered.round, "a lowered gun keeps the round")
			-- a clear miss at 4: it closes at 9
			local miss = EndingRules.judgeShot(difficulty, shot(4, 3))
			t.eq(miss.verdict, "Miss", difficulty .. ": a clear miss")
			t.truthy(miss.usesRound, "a miss uses the round")
			local missed = standoff(difficulty, 25, { [120] = { shot = "Miss" }, [130] = { shot = "Hit" } })
			t.eq(missed.ending, "B", difficulty .. ": after a miss there is no second round")
			t.truthy(missed.at < want.closes, difficulty .. ": it closes in before the window ends")
		end
	end,

	["a blocked, late or rejected shot never uses the round"] = function(t: Expect)
		for difficulty, want in WINDOW do
			local kept: { [string]: Shot } = {
				blocked = shot(5, 0, { blockedAt = 10 }),
				["late, fired after the window"] = shot(want.closes + 0.05, 0),
				["late, arriving after the 0.35 s grace"] = shot(
					want.closes - 0.1,
					0,
					{ arrival = want.closes + 0.36 }
				),
				["before fire opens"] = shot(1.9, 0),
				["picked up 0.5 s ago"] = shot(6.5, 0, { takenAt = 6 }),
				["3.2 from the holder's head"] = shot(5, 0, { head = { x = 0, y = 5, z = 23.2 } }),
				["26 degrees off the relayed look"] = shot(5, 0, {
					looks = { { t = 5, x = math.sin(math.rad(26)), y = 0, z = -math.cos(math.rad(26)) } },
				}),
				["no look within 0.15 s"] = shot(5, 0, { looks = { { t = 5.2, x = 0, y = 0, z = -1 } } }),
			}
			for name, s in kept do
				local v = EndingRules.judgeShot(difficulty, s)
				t.falsy(v.usesRound, difficulty .. ": " .. name .. " keeps the round")
				t.truthy(
					v.verdict == "Blocked" or v.verdict == "Late" or v.verdict == "Rejected",
					name .. ": " .. v.verdict
				)
			end
			-- the round kept, a later hit still ends it as A
			local o = standoff(difficulty, 25, { [200] = { shot = "Hit" } })
			t.eq(o.ending, "A", difficulty .. ": the round was kept for a later hit")
			local accepted: { [string]: Shot } = {
				["the last moment at 200 ms of latency"] = shot(
					want.closes - 0.05,
					0,
					{ arrival = want.closes + 0.15 }
				),
				["2.9 from the holder's head"] = shot(5, 0, { head = { x = 0, y = 5, z = 22.9 } }),
				["24 degrees off the relayed look"] = shot(5, 0, {
					looks = { { t = 5, x = math.sin(math.rad(24)), y = 0, z = -math.cos(math.rad(24)) } },
				}),
				["a flick: the look 0.14 s later"] = shot(5, 0, {
					looks = { { t = 4.9, x = 1, y = 0, z = 0 }, { t = 5.14, x = 0, y = 0, z = -1 } },
				}),
				["picked up 0.6 s ago"] = shot(6.6, 0, { takenAt = 6 }),
			}
			for name, s in accepted do
				t.eq(EndingRules.judgeShot(difficulty, s).verdict, "Hit", difficulty .. ": " .. name .. " is accepted")
			end
		end
		t.near(EndingRules.rewind(0.2, 0.1), 0.3, 1e-9, "the pose is rewound by latency plus render delay")
		t.near(EndingRules.rewind(0.4, 0.3), 0.5, 1e-9, "at most 0.5 s")
	end,

	["the hit test: the centre ray, 60 long, against the hitbox grown by 0.6 / 1.2 / 1.8"] = function(t: Expect)
		local function test(dx: number, dy: number, device: string, z: number?): string
			return EndingRules.hitTest(
				{ origin = { x = dx, y = 5.5 + dy, z = z or 20 }, dir = { x = 0, y = 0, z = -1 } },
				BOX,
				device
			)
		end
		for device, margin in MARGIN do
			t.eq(test(HALF_WIDTH + margin - 0.01, 0, device), "Hit", device .. ": just inside the margin")
			t.eq(test(HALF_WIDTH + margin + 0.01, 0, device), "Miss", device .. ": just outside it")
			t.eq(test(-(HALF_WIDTH + margin - 0.01), 0, device), "Hit", device .. ": the other side")
			t.eq(test(0, HALF_HEIGHT + margin - 0.01, device), "Hit", device .. ": over the head, inside")
			t.eq(test(0, HALF_HEIGHT + margin + 0.01, device), "Miss", device .. ": over the head, outside")
			t.eq(test(0, 0, device, 61.4 + margin), "Miss", device .. ": beyond 60")
			t.eq(test(0, 0, device, 61.3 - margin), "Hit", device .. ": within 60")
		end
		-- the same ray and pose give the same answer, whatever else is going on: the test reads nothing else
		t.eq(test(1.5, 0, "Mouse"), test(1.5, 0, "Mouse"), "deterministic")
		t.throws(function()
			test(0, 0, "Wheel")
		end, "an unknown device")
	end,

	["the holder: lowering, passing, picking up, an idle holder, the pick-up line"] = function(t: Expect)
		t.eq(EndingRules.gunButton(1.5, false), "Lower", "held 1.5 s lowers")
		t.eq(EndingRules.gunButton(1.4, false), "None", "not yet")
		t.eq(EndingRules.gunButton(0.29, true), "Drop", "a tap under 0.3 s drops it to pass it")
		t.eq(EndingRules.gunButton(0.31, true), "None", "too long for a tap")
		t.truthy(EndingRules.takeReady(0.6, false), "picked up in 0.6 s")
		t.falsy(EndingRules.takeReady(1.1, true), "taking from a lowered holder takes 1.2 s")
		t.truthy(EndingRules.takeReady(1.2, true), "taken from a lowered holder")
		t.truthy(EndingRules.idleDrop(4), "4 s idle drops it")
		t.falsy(EndingRules.idleDrop(3.9), "not before")
		t.truthy(EndingRules.pickUpLineDue(4.0, false), "nobody holds it at T_s + 4.0")
		t.falsy(EndingRules.pickUpLineDue(4.0, true), "someone holds it")
		local holder = { takenAt = -10, lowered = false, heldAtOpen = false }
		t.falsy(EndingRules.canFire("Standard", 1.99, holder), "it cannot fire before the standoff opens fire")
		t.truthy(EndingRules.canFire("Standard", 2.0, holder), "it can at 2.0")
		t.falsy(EndingRules.canFire("Standard", 5, { takenAt = -10, lowered = true, heldAtOpen = false }), "lowered")
		t.falsy(
			EndingRules.canFire("Standard", 5, { takenAt = -10, lowered = false, heldAtOpen = true }),
			"a held button"
		)
		t.falsy(
			EndingRules.canFire("Standard", 8.5, { takenAt = 8, lowered = false, heldAtOpen = false }),
			"taken 0.5 s ago"
		)
		t.truthy(
			EndingRules.canFire("Standard", 8.6, { takenAt = 8, lowered = false, heldAtOpen = false }),
			"0.6 s later"
		)
		-- T_s = max(first arrival + 12, revolver taken + 5), not before everyone is up or 20 s after the slam
		t.eq(EndingRules.standoffStart({ arrived = 50, taken = 60, allUp = 52, slammed = 45 }), 65, "taken late")
		t.eq(EndingRules.standoffStart({ arrived = 50, taken = 51, allUp = 52, slammed = 45 }), 62, "arrival + 12")
		t.eq(EndingRules.standoffStart({ arrived = 50, taken = 51, slammed = 48 }), 68, "a straggler: the slam + 20")
		t.eq(
			EndingRules.standoffStart({ arrived = 50, taken = 51, allUp = 66, slammed = 48 }),
			66,
			"the straggler arrives"
		)
		-- it fades in at whichever of E, N, S, W is farthest from the holder
		t.eq(EndingRules.fadeInSpot(9, 88), "E", "from the west spot, the east")
		t.eq(EndingRules.fadeInSpot(22, 100), "N", "from the south, the north")
		t.eq(EndingRules.fadeInSpot(34, 87), "W", "from the east, the west")
	end,

	["step is pure"] = function(t: Expect)
		local state = EndingRules.new("Nightmare", 20)
		local copy = EndingRules.new("Nightmare", 20)
		EndingRules.step(state, { shot = "Hit" }, DT)
		deepEq(t, state, copy, "the state passed in")
		t.throws(function()
			EndingRules.new("Easy", 20)
		end, "an unknown difficulty")
	end,
}
