--!strict
-- RadarRules (docs/design/game-spec-v2.md 3.2; invariant I15): every golden row, then the spec's numbers asserted on
-- their own (written here from the spec's text, never read back from RadarConfig), and the module and its config pure.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RadarConfig = require(ReplicatedStorage.Shared.Config.RadarConfig)
local RadarRules = require(ReplicatedStorage.Shared.Rules.RadarRules)
local StageConfig = require(ReplicatedStorage.Shared.Config.StageConfig)
local RuleGolden = require(script.Parent.Parent.RuleGolden)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local S, N = "Standard", "Nightmare"

local SNEAKING = { "Level0_Basement", "Level1_Hallways", "Level2_Auditorium", "City1_Rooftops", "City2_Airport" }

local function asker(overrides: { [string]: any }?): RadarRules.Asker
	local a: { [string]: any } = {
		charges = 1,
		lifeState = "Alive",
		moveState = "Standing",
		cutscene = false,
		stage = "Level0_Basement",
		squadScanLive = false,
	}
	for key, value in (overrides or {}) :: { [string]: any } do
		a[key] = value
	end
	return a :: any
end

return {
	["golden rows: every function answers its rows, at least 12 each, plain data"] = function(t: Expect)
		RuleGolden.check(t, RadarRules, "RadarRules")
	end,

	["pure: no engine, clock or randomness in the rules or their numbers"] = function(t: Expect)
		RuleGolden.checkPure(t, ReplicatedStorage.Shared.Rules.RadarRules)
		RuleGolden.checkPure(t, ReplicatedStorage.Shared.Config.RadarConfig)
	end,

	["the spec's charges: 3 held, 1 at the start; a scan costs one, 0.4 s raise, 8 [6] s"] = function(t: Expect)
		for _, d in { S, N } do
			t.eq(RadarRules.startCharges(d), 1, d)
			t.eq(RadarConfig.of(d).MaxCharges, 3, d)
			local scan = RadarRules.scan(d, 3, 10)
			t.eq(scan.charges, 2, d)
			t.near(scan.showAt, 10.4, 1e-9, d .. " raise")
			t.near(scan.endsAt - scan.showAt, if d == S then 8 else 6, 1e-9, d .. " length")
		end
	end,

	["the spec's arrival floor: every sneaking stage [the Basement and the Rooftops]; never elsewhere"] = function(
		t: Expect
	)
		for _, id in SNEAKING do
			t.eq(RadarRules.arrival(S, id, 0), 1, "Standard " .. id)
			local night = (id == "Level0_Basement" or id == "City1_Rooftops")
			t.eq(RadarRules.arrival(N, id, 0), if night then 1 else 0, "Nightmare " .. id)
			t.eq(RadarRules.arrival(S, id, 2), 2, "a floor, never a top-up")
		end
		for _, id in { "BackLot", "Level3_Roof", "Runway", "Bahamas" } do
			t.eq(RadarRules.arrival(S, id, 0), 0, id .. " is no sneaking stage")
		end
		t.eq(#StageConfig.Sneaking, 5, "five sneaking stages")
	end,

	["I15: on Standard every sneaking stage is reached with a charge; 5 [2] scans with no battery ever"] = function(
		t: Expect
	)
		for _, id in StageConfig.Sneaking do
			t.truthy(RadarRules.arrival(S, id, 0) >= 1, id)
		end
		t.eq(RadarRules.guaranteedScans(S), 5)
		t.eq(RadarRules.guaranteedScans(N), 2)
	end,

	["the spec's battery: +1 charge and +45 torch; with both full it stays"] = function(t: Expect)
		local b = RadarRules.battery(S, 1, 20, 100)
		t.truthy(b.taken and b.charges == 2 and b.torch == 65)
		t.falsy(RadarRules.battery(N, 3, 100, 100).taken, "both full: Full")
		t.truthy(RadarRules.battery(S, 3, 99, 100).taken, "the torch takes it")
		t.eq(RadarRules.battery(S, 2, 100, 100).charges, 3, "the charge takes it")
	end,

	["the spec's refusals: hiding, downed, seated, a cutscene, the roof, the runway, a live squad scan"] = function(
		t: Expect
	)
		t.eq(RadarRules.refusal(asker()), "Ok")
		t.eq(RadarRules.refusal(asker({ moveState = "Hiding" })), "Hiding")
		t.eq(RadarRules.refusal(asker({ lifeState = "Downed" })), "Downed")
		t.eq(RadarRules.refusal(asker({ moveState = "Seated" })), "Seated")
		t.eq(RadarRules.refusal(asker({ cutscene = true })), "Cutscene")
		t.eq(RadarRules.refusal(asker({ stage = "Level3_Roof" })), "Stage")
		t.eq(RadarRules.refusal(asker({ stage = "Runway" })), "Stage")
		t.eq(RadarRules.refusal(asker({ squadScanLive = true })), "Live")
		t.eq(RadarRules.refusal(asker({ charges = 0 })), "Empty", "no charge: the objective sheet")
	end,

	["the spec's batteries placed: 6 [4], +1 per extra player, at most 9 [7]"] = function(t: Expect)
		for players, want in { 6, 7, 8, 9 } do
			t.eq(RadarRules.batteriesPlaced(S, players), want, "Standard x" .. players)
		end
		for players, want in { 4, 5, 6, 7 } do
			t.eq(RadarRules.batteriesPlaced(N, players), want, "Nightmare x" .. players)
		end
		t.eq(RadarConfig.Candidates, 36)
		local p = RadarConfig.Placement
		t.truthy(p.EntryMin == 20 and p.EntryMax == 60 and p.StationReach == 40 and p.PairSpacing == 30, "placement")
		t.eq(p.Seeds, 16)
	end,

	["I15: a scan shows what the step needs and batteries within 50, never the Creature or a teammate"] = function(
		t: Expect
	)
		local shown = RadarRules.targets({
			openStep = "FindFuses",
			items = { { id = "F1", step = "FindFuses", carried = false, dropped = false } },
			stations = { { id = "Panel", step = "FitFuses", done = false } },
			exit = { id = "Exit", unlocked = false },
			batteries = { { id = "Near", distance = 50 }, { id = "Far", distance = 50.5 } },
			creature = { id = "Creature" },
			teammates = { { id = "Friend" } },
		})
		local ids: { string } = {}
		for _, target in shown do
			table.insert(ids, target.kind .. ":" .. target.id)
			t.truthy(target.kind ~= "Creature" and target.id ~= "Creature" and target.id ~= "Friend", target.id)
		end
		t.eq(table.concat(ids, ","), "Item:F1,Battery:Near")
		t.eq(RadarRules.metres(100), 28, "0.28 m a stud")
		t.eq(RadarConfig.PingRange, 30)
		t.eq(RadarConfig.BatteryTorch, 45)
		t.truthy(RadarConfig.LedOn == 0.2 and RadarConfig.LedPeriod == 2, "the LED blinks 0.2 s every 2 s")
	end,
}
