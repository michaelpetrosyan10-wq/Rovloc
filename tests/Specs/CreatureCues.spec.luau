--!strict
-- The Creature's moments for one player (docs/MONSTER.md 11): the chase music follows WallChase on me, the rattle the
-- stalking states, its gap is U(4.5, 8) s, the reveal's phantom fades in over 0.05 s and out over the last 0.09 of its
-- 0.36, and the torch stutter drops the beam to 12 % in seeded slots only while it runs.

local StarterPlayer = game:GetService("StarterPlayer")

local Controllers = StarterPlayer.StarterPlayerScripts.Controllers
local CreatureCuesController = require(Controllers.Gameplay.CreatureCuesController)
local Flashlight = require(Controllers.FirstPerson.FirstPersonController.Flashlight)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

return {
	["the chase music plays only while it chases me; the rattle while it stalks"] = function(t: Expect)
		t.truthy(CreatureCuesController.chased("WallChase", 42, 42), "chasing me")
		t.falsy(CreatureCuesController.chased("WallChase", 7, 42), "chasing a teammate")
		t.falsy(CreatureCuesController.chased("Search", 42, 42), "searching is no chase")
		t.falsy(CreatureCuesController.chased("WallChase", 42, nil), "no local player")
		for _, state in { "Patrol", "Teleport", "Search", "HidingResponse", "InvestigateNoise" } do
			t.truthy(CreatureCuesController.stalking(state), state .. " rattles")
		end
		for _, state in { "WallChase", "Dormant", "Scripted", "Stunned" } do
			t.falsy(CreatureCuesController.stalking(state), state .. " does not")
		end
		t.eq(CreatureCuesController.rattleGap(0), 4.5, "4.5 s at the least")
		t.eq(CreatureCuesController.rattleGap(1), 8, "8 at the most")
		t.eq(CreatureCuesController.rattleGap(2), 8, "clamped")
	end,

	["the reveal's phantom: in over 0.05 s, out over the last 0.09 of 0.36"] = function(t: Expect)
		t.eq(CreatureCuesController.PhantomSeconds, 0.36)
		t.eq(CreatureCuesController.PhantomAhead, 3.4)
		t.eq(CreatureCuesController.phantomWeight(-0.01), 0, "not yet")
		t.near(CreatureCuesController.phantomWeight(0.025), 0.5, 1e-9, "fading in")
		t.eq(CreatureCuesController.phantomWeight(0.1), 1, "full")
		t.near(CreatureCuesController.phantomWeight(0.36 - 0.045), 0.5, 1e-9, "fading out")
		t.eq(CreatureCuesController.phantomWeight(0.37), 0, "gone")
	end,

	["the torch stutter: seeded dropouts to 12 % while it runs, nothing after"] = function(t: Expect)
		local T0 = 1_700_000_000
		local dropped, kept = 0, 0
		for i = 0, 599 do
			local value = Flashlight.stutterFactor(T0 + i / 60, T0 + 10)
			t.truthy(value == 1 or math.abs(value - 0.12) < 1e-9, "on or dropped")
			t.eq(value, Flashlight.stutterFactor(T0 + i / 60, T0 + 10), "deterministic")
			if value < 1 then
				dropped += 1
			else
				kept += 1
			end
		end
		t.truthy(dropped > 150 and kept > 150, string.format("it stutters (%d dropped, %d lit)", dropped, kept))
		t.eq(Flashlight.stutterFactor(T0 + 11, T0 + 10), 1, "over: full beam")
		t.eq(Flashlight.stutterFactor(T0, -math.huge), 1, "never started")
	end,
}
