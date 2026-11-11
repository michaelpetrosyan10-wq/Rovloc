--!strict
-- LivesRules (docs/design/game-spec-v2.md 3.3): every golden row, then the spec's numbers asserted on their own
-- (written here from the spec's text, never read back from LivesConfig, so a wrong config cannot pass by agreeing with
-- itself), and the module and its config pure.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local LivesConfig = require(ReplicatedStorage.Shared.Config.LivesConfig)
local LivesRules = require(ReplicatedStorage.Shared.Rules.LivesRules)
local StageConfig = require(ReplicatedStorage.Shared.Config.StageConfig)
local RuleGolden = require(script.Parent.Parent.RuleGolden)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local S, N = "Standard", "Nightmare"

local function L(stage: number, run: number, syringe: number, downs: number, used: boolean): LivesRules.Lives
	return { stage = stage, run = run, syringe = syringe, downs = downs, getUpUsed = used }
end

return {
	["golden rows: every function answers its rows, at least 12 each, plain data"] = function(t: Expect)
		RuleGolden.check(t, LivesRules, "LivesRules")
	end,

	["pure: no engine, clock or randomness in the rules or their numbers"] = function(t: Expect)
		RuleGolden.checkPure(t, ReplicatedStorage.Shared.Rules.LivesRules)
		RuleGolden.checkPure(t, ReplicatedStorage.Shared.Config.LivesConfig)
	end,

	["the spec's down: crawl 2.5, bleed out 35 s; the first lethal hit downs, the next kills"] = function(t: Expect)
		for _, d in { S, N } do
			local c = LivesConfig.of(d)
			t.eq(c.CrawlSpeed, 2.5, d .. " crawl")
			t.eq(c.BleedoutSeconds, 35, d .. " bleed-out")
		end
		local fresh = LivesRules.stageActivated(S, LivesRules.newRun(S, false), "Level0_Basement")
		local first = LivesRules.lethal(fresh, "Alive", "Catch")
		t.eq(first.outcome, "Downed", "a stage's first catch downs")
		t.eq(LivesRules.lethal(first.lives, "Alive", "Damage").outcome, "Killed", "the next lethal hit kills")
		t.eq(LivesRules.lethal(first.lives, "Downed", "Catch").outcome, "Killed", "a catch while downed kills")
		t.eq(LivesRules.lethal(first.lives, "Downed", "BleedOut").outcome, "Killed", "the bleed-out kills")
		local nextStage = LivesRules.stageActivated(S, first.lives, "Level1_Hallways")
		t.eq(LivesRules.lethal(nextStage, "Alive", "Damage").outcome, "Downed", "downs are per stage")
	end,

	["the spec's get-up: from 3 s, hold 4 s up at 50 [6 s, 35], once per stage; 7 [9] s from the catch"] = function(
		t: Expect
	)
		local downed = L(1, 0, 0, 1, false)
		t.falsy(LivesRules.getUp(S, downed, 2.99, 10).allowed, "not before 3 s")
		t.falsy(LivesRules.getUp(S, downed, 3, 3.99).up, "Standard: 3.99 s of holding is short")
		local up = LivesRules.getUp(S, downed, 3, 4)
		t.truthy(up.up and up.health == 50, "Standard: 4 s, 50 health")
		t.falsy(LivesRules.getUp(N, downed, 10, 5.99).up, "Nightmare: 5.99 s is short")
		local hard = LivesRules.getUp(N, downed, 10, 6)
		t.truthy(hard.up and hard.health == 35, "Nightmare: 6 s, 35 health")
		t.falsy(LivesRules.getUp(S, L(1, 0, 0, 1, true), 30, 30).allowed, "once per stage")
		t.eq(LivesRules.getUpTime(S), 7)
		t.eq(LivesRules.getUpTime(N), 9)
		-- the catch's Relax (at least 25 [15] s, the cooldown 14.4 [8.8] s) always fits the get-up
		t.eq(LivesConfig.Standard.RelaxSeconds, 25)
		t.eq(LivesConfig.Nightmare.RelaxSeconds, 15)
		t.eq(LivesConfig.Standard.CatchCooldown, 14.4)
		t.eq(LivesConfig.Nightmare.CatchCooldown, 8.8)
		t.eq(DifficultyConfig.Standard.catchCooldownSeconds, 14.4, "the Creature's own cooldown agrees")
		t.eq(DifficultyConfig.Nightmare.catchCooldownSeconds, 8.8, "the Creature's own cooldown agrees")
		t.truthy(LivesRules.getUpTime(S) <= 25 and LivesRules.getUpTime(N) <= 15, "the get-up fits the Relax")
	end,

	["the spec's revive: 4 s, 50 health, on both difficulties"] = function(t: Expect)
		for _, d in { S, N } do
			t.falsy(LivesRules.revive(d, 3.99).up, d)
			local r = LivesRules.revive(d, 4)
			t.truthy(r.up and r.health == 50, d)
		end
	end,

	["the spec's respawns: 1 a stage [1 a run], +1 with the syringe; set back, never banked; spent in order"] = function(
		t: Expect
	)
		local std = LivesRules.newRun(S, true)
		t.eq(LivesRules.respawnsLeft(std), 1, "Standard before the first stage: the syringe's")
		local basement = LivesRules.stageActivated(S, std, "Level0_Basement")
		t.eq(basement.stage, 1, "a stage respawn at the Basement")
		t.eq(LivesRules.respawnsLeft(basement), 2, "stage + syringe")
		local again = LivesRules.stageActivated(S, basement, "Level1_Hallways")
		t.eq(again.stage, 1, "an unused stage respawn is not banked")
		local spent = LivesRules.spend(again)
		t.eq(spent.source, "stage", "the stage's first")
		t.eq(LivesRules.spend(spent.lives).source, "syringe", "the syringe's last")
		local night = LivesRules.stageActivated(N, LivesRules.newRun(N, true), "Level0_Basement")
		t.eq(night.stage, 0, "Nightmare has no stage respawn")
		t.eq(night.run, 1, "one for the run")
		local nightSpent = LivesRules.spend(night)
		t.eq(nightSpent.source, "run", "the run's before the syringe's")
		t.eq(LivesRules.spend(nightSpent.lives).source, "syringe")
		t.eq(LivesRules.spend(L(0, 0, 0, 0, false)).source, "none")
	end,

	["the stage respawn comes back on the seven playable stages only"] = function(t: Expect)
		local playable = {
			"Level0_Basement",
			"Level1_Hallways",
			"Level2_Auditorium",
			"Level3_Roof",
			"City1_Rooftops",
			"City2_Airport",
			"Runway",
		}
		for _, id in playable do
			t.eq(LivesRules.stageActivated(S, L(0, 0, 0, 1, true), id).stage, 1, id)
		end
		for _, id in { "BackLot", "Bahamas" } do
			t.eq(LivesRules.stageActivated(S, L(0, 0, 0, 1, true), id).stage, 0, id .. " is no playable stage")
		end
		t.eq(#StageConfig.Playable, 7, "seven playable stages")
	end,

	["the spec's respawn: 4 s of black, 50 [35] health, 10 [6] s ignored, at least 1 charge and half the torch"] = function(
		t: Expect
	)
		local std = LivesRules.respawn(S, 0, 10, 100)
		t.eq(std.blackout, 4)
		t.eq(std.health, 50)
		t.eq(std.grace, 10)
		t.eq(std.charges, 1)
		t.eq(std.torch, 50)
		local keep = LivesRules.respawn(S, 3, 90, 100)
		t.eq(keep.charges, 3, "charges kept")
		t.eq(keep.torch, 90, "the torch kept")
		local night = LivesRules.respawn(N, 2, 0, 150)
		t.eq(night.health, 35)
		t.eq(night.grace, 6)
		t.eq(night.torch, 75, "half of a lithium cell")
		local after = LivesRules.afterDeath(L(1, 0, 0, 1, true), 2)
		t.eq(after.action, "Respawn")
		t.falsy(after.lives.getUpUsed, "a respawn gives the stage's get-up back")
		t.eq(LivesConfig.Standard.MonsterClearance, 70)
		t.eq(LivesConfig.Standard.PlayerClearance, 45)
		t.eq(LivesConfig.Standard.TeleportDelay, 45)
	end,

	["the spec's scripted chases: 3 [2] free failures a squad, then the most respawns left pays, lowest slot first"] = function(
		t: Expect
	)
		local squad = { { slot = 2, left = 1 }, { slot = 1, left = 1 }, { slot = 3, left = 0 } }
		for failure = 1, 3 do
			t.truthy(LivesRules.chaseFailure(S, failure, squad).free, "Standard failure " .. failure)
		end
		local fourth = LivesRules.chaseFailure(S, 4, squad)
		t.falsy(fourth.free)
		t.eq(fourth.payer, 1, "a tie goes to the lowest slot")
		t.truthy(LivesRules.chaseFailure(N, 2, squad).free, "Nightmare: 2 free")
		t.eq(LivesRules.chaseFailure(N, 3, squad).payer, 1)
		t.truthy(LivesRules.chaseFailure(N, 3, { { slot = 1, left = 0 } }).runEnds, "with none left the run ends")
	end,

	["out of respawns: spectate in co-op, the run's end alone; back at 50 at the next entry"] = function(t: Expect)
		t.eq(LivesRules.afterDeath(L(0, 0, 0, 1, true), 1).action, "RunOver", "THE NIGHT TOOK YOU")
		t.eq(LivesRules.afterDeath(L(0, 0, 0, 1, true), 3).action, "Spectate")
		for _, d in { S, N } do
			local back = LivesRules.checkpointReturn(d, "Spectating")
			t.truthy(back.stand and back.health == 50, d)
			t.falsy(LivesRules.checkpointReturn(d, "Alive").stand, d)
		end
		t.truthy(LivesRules.runEnds({ { slot = 1, left = 0, lifeState = "Spectating" } }), "nobody left")
		t.falsy(LivesRules.runEnds({ { slot = 1, left = 0, lifeState = "Downed" } }), "a downed player keeps it going")
		t.falsy(LivesRules.runEnds({ { slot = 1, left = 1, lifeState = "Dead" } }), "a respawn left keeps it going")
	end,

	["the config's numbers are the spec's"] = function(t: Expect)
		local want: { [string]: { number } } = {
			Standard = { 4, 50, 1, 0, 1, 3, 50, 10, 4 },
			Nightmare = { 6, 35, 0, 1, 1, 2, 35, 6, 4 },
		}
		for d, row in want do
			local c = LivesConfig.of(d)
			local got = {
				c.GetUpHold,
				c.GetUpHealth,
				c.RespawnsPerStage,
				c.RespawnsPerRun,
				c.SyringeRespawns,
				c.ChaseFreeAttempts,
				c.RespawnHealth,
				c.RespawnGrace,
				c.ReviveHold,
			}
			for i, value in row do
				t.eq(got[i], value, string.format("%s %d", d, i))
			end
			t.eq(c.GetUpDelay, 3, d)
			t.eq(c.ReviveHealth, 50, d)
			t.eq(c.RespawnCharges, 1, d)
			t.eq(c.RespawnTorch, 0.5, d)
			t.eq(c.CheckpointHealth, 50, d)
			t.eq(c.PinSeconds, 10, d)
		end
		local exported = LivesConfig.exportMeta()
		t.eq(exported.Standard.GetUpHold, 4, "exportMeta carries the numbers")
		t.eq(exported.Nightmare.RespawnsPerRun, 1)
	end,
}
