--!strict
-- EscapeSummary. EscapeSummaryController's pure rules: which title a summary wears (ESCAPED / WIPED / DEAD), the stat
-- rows in order with their Strings lines, the auto-return countdown and its bar, the credits count-up (eased, whole,
-- exact at the end), the hold while a finale or jumpscare owns the view (and its cap), the squad / time / best lines,
-- and that every key the screen shows exists.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Strings = require(ReplicatedStorage.Shared.Strings)

local EscapeSummaryController = require(StarterPlayer.StarterPlayerScripts.Controllers.Match.EscapeSummaryController)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local spec = {}

spec["titles: escaped, wiped, dead"] = function(t: Expect)
	local titleKind = EscapeSummaryController.titleKind
	t.eq(titleKind("Escaped", 1), "Escaped")
	t.eq(titleKind("Escaped", nil), "Escaped")
	t.eq(titleKind("Dead", 0), "Wiped", "nobody got out")
	t.eq(titleKind("Dead", nil), "Wiped")
	t.eq(titleKind("Dead", 2), "Dead", "you died, others escaped")
	t.eq(titleKind("Disconnected", 1), "Dead")
	for _, kind: EscapeSummaryController.TitleKind in
		{ "Escaped", "Wiped", "Dead" } :: { EscapeSummaryController.TitleKind }
	do
		t.truthy(Strings.has(EscapeSummaryController.titleKey(kind)), kind .. " has a title string")
	end
	t.eq(EscapeSummaryController.titleKey("Escaped"), "Results.Escaped")
end

spec["stat rows: every stat in order, zero-filled, whole numbers"] = function(t: Expect)
	local rows = EscapeSummaryController.statRows({ TrapsTriggered = 3, VentsCrawled = 2.7, Stuns = -1, Unknown = 9 })
	t.eq(#rows, #EscapeSummaryController.StatRows)
	t.eq(rows[1].stat, "TrapsTriggered")
	t.eq(rows[1].value, 3)
	t.eq(rows[2].value, 2, "fractions are dropped")
	local byStat: { [string]: number } = {}
	for _, row in rows do
		byStat[row.stat] = row.value
		t.truthy(Strings.has(row.key), row.key .. " exists")
		t.truthy(
			string.find(Strings.get(row.key, row.value), tostring(row.value), 1, true),
			row.key .. " shows its count"
		)
	end
	t.eq(byStat.Stuns, 0, "negative counts read 0")
	t.eq(byStat.FlasksThrown, 0, "missing counts read 0")
	t.eq(byStat.Unknown, nil, "only known stats are shown")
	for _, stat in
		{ "TrapsTriggered", "VentsCrawled", "FlasksThrown", "Stuns", "Revives", "LockersHidden", "FloorsCleared" }
	do
		t.truthy(byStat[stat] ~= nil, stat .. " is on the summary")
	end
	t.eq(#EscapeSummaryController.statRows(nil), #EscapeSummaryController.StatRows)
end

spec["countdown: seconds left and the draining bar"] = function(t: Expect)
	local seconds, fraction = EscapeSummaryController.countdown(100, 112, 12)
	t.eq(seconds, 12)
	t.near(fraction, 1, 1e-9)
	seconds, fraction = EscapeSummaryController.countdown(105.5, 112, 12)
	t.eq(seconds, 7, "whole seconds round up")
	t.near(fraction, 6.5 / 12, 1e-9)
	seconds, fraction = EscapeSummaryController.countdown(130, 112, 12)
	t.eq(seconds, 0)
	t.eq(fraction, 0)
	local none, empty = EscapeSummaryController.countdown(100, nil, 12)
	t.eq(none, nil, "no deadline, no countdown")
	t.eq(empty, 0)
	local _, guarded = EscapeSummaryController.countdown(100, 101, 0)
	t.eq(guarded, 1, "a zero total never divides by zero")
end

spec["credits count up, eased, whole, exact at the end"] = function(t: Expect)
	local countUp = EscapeSummaryController.countUp
	t.eq(countUp(-1, 200), 0, "nothing before it starts")
	t.eq(countUp(0.5, 0), 0)
	local previous = 0
	for step = 1, 40 do
		local value = countUp(step * 0.05, 200)
		t.truthy(value >= previous, "never counts down")
		t.eq(value, math.floor(value), "whole credits")
		previous = value
	end
	t.eq(countUp(5, 200), 200, "lands exactly on the total")
	t.truthy(countUp(0.4, 200) > 200 * 0.4 / 1.6, "eases out: fast first")
end

spec["holds while a finale or jumpscare owns the view, at most HoldMaxSeconds"] = function(t: Expect)
	local holding = EscapeSummaryController.holding
	t.falsy(holding("Menu", "None", 0))
	t.falsy(holding("OnFoot", "None", 0))
	t.truthy(holding("Cutscene", "None", 1), "the finale shot")
	t.truthy(holding("OnFoot", "Parachute", 1), "still under the canopy")
	t.truthy(holding("OnFoot", "Jumpscare", 1), "the last catch")
	t.truthy(holding("OnFoot", "Cutscene", 1))
	t.falsy(holding("OnFoot", "Trap", 1), "an ordinary lock does not hold it")
	t.falsy(holding("Cutscene", "Parachute", EscapeSummaryController.HoldMaxSeconds), "never stuck")
end

spec["squad, time and best lines"] = function(t: Expect)
	t.eq(EscapeSummaryController.squadText(2, 4), Strings.get("Results.Squad", 2, 4))
	t.eq(EscapeSummaryController.squadText(9, 4), Strings.get("Results.Squad", 4, 4), "clamped to the squad")
	t.eq(EscapeSummaryController.squadText(nil, 4), nil)
	t.eq(EscapeSummaryController.squadText(1, 0), nil)
	t.eq(EscapeSummaryController.timeText(754), Strings.get("Results.Time", "12:34"))
	t.eq(EscapeSummaryController.bestText(61), Strings.get("Results.BestTime", "1:01"))
	t.eq(EscapeSummaryController.bestText(nil), nil, "no best time yet")
	t.eq(EscapeSummaryController.bestText(0), nil)
	for _, key in
		{
			"Results.PlayAgain",
			"Results.Waiting",
			"Results.Credits",
			"Results.NewBest",
			"Results.NotSaved",
			"Results.Returning",
			"Results.Squad",
			"Lobby.Difficulty.Standard",
			"Lobby.Difficulty.Nightmare",
		}
	do
		t.truthy(Strings.has(key), key .. " exists")
	end
	t.truthy(string.find(Strings.get("Results.Returning", 9), "9", 1, true) ~= nil, "the countdown shows its seconds")
end

return spec
