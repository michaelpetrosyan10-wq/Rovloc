--!strict
-- Render budget tiers: the ceiling from the device and the player's graphics quality, and the FPS adaptation fed a
-- history of 1 s windows (drop after 5 s under 35, raise after 20 s above 55, resets in between, flap back-off).

local StarterPlayer = game:GetService("StarterPlayer")

local SpecRunner = require(script.Parent.Parent.SpecRunner)

local RenderBudgetController = require(StarterPlayer.StarterPlayerScripts.Controllers.Core.RenderBudgetController)

type Expect = SpecRunner.Expect
type TierState = RenderBudgetController.TierState

-- Feeds one-second windows at the given frame rates; returns the final state and the tiers it changed to.
local function run(state: TierState, history: { number }): (TierState, { string })
	local changes: { string } = {}
	local current = state
	for _, fps in history do
		local changed
		current, changed = RenderBudgetController.step(current, fps, 1)
		if changed then
			table.insert(changes, current.tier)
		end
	end
	return current, changes
end

local function rep(fps: number, seconds: number): { number }
	local out: { number } = {}
	for _ = 1, seconds do
		table.insert(out, fps)
	end
	return out
end

local function concat(...: { number }): { number }
	local out: { number } = {}
	for _, list in { ... } do
		for _, value in list do
			table.insert(out, value)
		end
	end
	return out
end

return {
	["the ceiling comes from graphics quality, else the device class"] = function(t: Expect)
		t.eq(RenderBudgetController.qualityTier(0), nil, "Automatic")
		t.eq(RenderBudgetController.qualityTier(1), "Low")
		t.eq(RenderBudgetController.qualityTier(3), "Low")
		t.eq(RenderBudgetController.qualityTier(4), "Medium")
		t.eq(RenderBudgetController.qualityTier(6), "Medium")
		t.eq(RenderBudgetController.qualityTier(7), "High")
		t.eq(RenderBudgetController.qualityTier(10), "High")
		t.eq(RenderBudgetController.ceilingFor(true, false, 0), "Medium", "phones start at Medium")
		t.eq(RenderBudgetController.ceilingFor(false, true, 0), "High", "consoles")
		t.eq(RenderBudgetController.ceilingFor(false, false, 0), "High", "desktops")
		t.eq(RenderBudgetController.ceilingFor(true, false, 9), "High", "a phone player who asked for high quality")
		t.eq(RenderBudgetController.ceilingFor(false, false, 2), "Low", "a desktop player who asked for low quality")
	end,

	["five seconds under 35 FPS drops one tier; four do not"] = function(t: Expect)
		local start = RenderBudgetController.newState("High")
		local _, none = run(start, rep(30, 4))
		t.eq(#none, 0)
		local dropped, changes = run(start, rep(30, 5))
		t.eq(dropped.tier, "Medium")
		t.eq(table.concat(changes, ","), "Medium")
		local _, twice = run(start, rep(20, 10))
		t.eq(table.concat(twice, ","), "Medium,Low", "a second five seconds drops again")
		local floor, more = run(RenderBudgetController.newState("Low"), rep(10, 30))
		t.eq(floor.tier, "Low")
		t.eq(#more, 0, "Low is the floor")
	end,

	["a window in the 35-55 band resets the clocks"] = function(t: Expect)
		local start = RenderBudgetController.newState("High")
		local _, changes = run(start, concat(rep(30, 4), { 45 }, rep(30, 4)))
		t.eq(#changes, 0, "interrupted slow periods never add up")
		local low = RenderBudgetController.newState("High")
		low.tier = "Low"
		local _, raises = run(low, concat(rep(60, 19), { 50 }, rep(60, 19)))
		t.eq(#raises, 0, "interrupted fast periods never add up")
	end,

	["twenty seconds above 55 FPS raises one tier, never past the ceiling"] = function(t: Expect)
		local state = RenderBudgetController.newState("Medium")
		state.tier = "Low"
		local raised, changes = run(state, rep(60, 20))
		t.eq(raised.tier, "Medium")
		t.eq(table.concat(changes, ","), "Medium")
		local capped, more = run(raised, rep(60, 120))
		t.eq(capped.tier, "Medium", "Medium is this device's ceiling")
		t.eq(#more, 0)
	end,

	["a tier dropped soon after a raise needs longer to come back"] = function(t: Expect)
		local state = RenderBudgetController.newState("High")
		state.tier = "Medium"
		-- Raise, then the higher tier struggles straight away: flapping.
		local flapped, changes = run(state, concat(rep(60, 20), rep(25, 5)))
		t.eq(table.concat(changes, ","), "High,Medium")
		t.eq(flapped.raiseAfter, 40, "the next raise needs twice as long")
		local _, early = run(flapped, rep(60, 39))
		t.eq(#early, 0, "39 s is not enough now")
		local back = run(flapped, rep(60, 40))
		t.eq(back.tier, "High")
		-- A drop long after the raise is not flapping.
		local stable = RenderBudgetController.newState("High")
		stable.tier = "Medium"
		local settled = run(stable, concat(rep(60, 20), rep(45, 60), rep(25, 5)))
		t.eq(settled.tier, "Medium")
		t.eq(settled.raiseAfter, 20)
		-- Holding one tier for a long time forgives earlier flapping.
		local forgiven = run(flapped, rep(45, 200))
		t.eq(forgiven.raiseAfter, 20)
	end,

	["lowering the quality ceiling clamps the tier"] = function(t: Expect)
		local state = RenderBudgetController.newState("High")
		local clamped = RenderBudgetController.withCeiling(state, "Low")
		t.eq(clamped.tier, "Low")
		t.eq(clamped.ceiling, "Low")
		local kept = RenderBudgetController.withCeiling(RenderBudgetController.newState("Low"), "High")
		t.eq(kept.tier, "Low", "raising the ceiling alone does not raise the tier")
		t.eq(kept.ceiling, "High")
	end,

	["budgets grow with the tier"] = function(t: Expect)
		local low = RenderBudgetController.budgetFor("Low")
		local medium = RenderBudgetController.budgetFor("Medium")
		local high = RenderBudgetController.budgetFor("High")
		for _, budget in { low, medium, high } do
			t.eq(RenderBudgetController.budgetFor(budget.tier), budget)
			t.truthy(budget.animNear < budget.animFar, budget.tier .. " LOD bands")
			t.truthy(budget.particleScale > 0 and budget.particleScale <= 1)
			t.truthy(budget.remoteFlashlights >= 1 and budget.remoteFlashlights <= 3, "at most three teammates")
		end
		t.truthy(low.lights < medium.lights and medium.lights < high.lights)
		t.truthy(low.animFar < medium.animFar and medium.animFar < high.animFar)
		t.truthy(
			low.remoteFlashlights <= medium.remoteFlashlights and medium.remoteFlashlights <= high.remoteFlashlights
		)
		t.falsy(low.shadows)
		t.truthy(high.shadows and high.dof)
		for _, budget in { low, medium, high } do
			t.truthy(budget.shadowLights <= budget.lights, budget.tier .. " shadows only rendered fixtures")
			t.truthy(budget.windowShadows <= budget.windowLights, budget.tier .. " shadows only lit windows")
			t.truthy(budget.dust <= budget.shafts, budget.tier .. " dust only drifts in shafts")
		end
		for _, key in { "shadowLights", "windowLights", "windowShadows", "shafts", "dust" } do
			local lowValue = (low :: any)[key] :: number
			local mediumValue = (medium :: any)[key] :: number
			local highValue = (high :: any)[key] :: number
			t.truthy(lowValue <= mediumValue and mediumValue <= highValue, key .. " grows with the tier")
		end
		-- a weak device keeps its frame rate: nothing shadowed, no shafts, no dust, no torch haze
		t.eq(low.shadowLights, 0)
		t.eq(low.windowShadows, 0)
		t.eq(low.shafts, 0)
		t.eq(low.dust, 0)
		t.falsy(low.flashlightHaze)
		t.truthy(low.windowLights > 0, "the windows still read on Low")
		t.truthy(high.shadowLights + high.windowShadows <= high.lights, "High casts no more shadows than before")
		t.truthy(medium.shadowLights + medium.windowShadows <= medium.lights, "nor does Medium")
		t.eq(RenderBudgetController.GetBudget().tier, RenderBudgetController.GetState().tier)
	end,
}
