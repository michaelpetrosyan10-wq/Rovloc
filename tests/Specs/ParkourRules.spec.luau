--!strict
-- ParkourRules (docs/design/game-spec-v2.md 3.1; invariants I8 and I9): every golden row, then the spec's numbers
-- asserted on their own (written here from the spec's text, never read back from ParkourConfig), the curves sampled on
-- the tick at several frame rates, and the module and its config pure.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConfig = require(ReplicatedStorage.Shared.Config.ParkourConfig)
local ParkourRules = require(ReplicatedStorage.Shared.Rules.ParkourRules)
local RuleGolden = require(script.Parent.Parent.RuleGolden)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local function ask(overrides: { [string]: any }?): ParkourRules.LeapAsk
	local a: { [string]: any } = {
		inStrip = true,
		sinceEdge = -1,
		requestAge = 0.1,
		speed = 17,
		heading = 0,
		assist = false,
	}
	for key, value in (overrides or {}) :: { [string]: any } do
		a[key] = value
	end
	return a :: any
end

return {
	["golden rows: every function answers its rows, at least 12 each, plain data"] = function(t: Expect)
		RuleGolden.check(t, ParkourRules, "ParkourRules")
	end,

	["pure: no engine, clock or randomness in the rules or their numbers"] = function(t: Expect)
		RuleGolden.checkPure(t, ReplicatedStorage.Shared.Rules.ParkourRules)
		RuleGolden.checkPure(t, ReplicatedStorage.Shared.Config.ParkourConfig)
	end,

	["the spec's leap: 0.60 s, a straight line to 2.0 past the far edge of a 12 gap, apex +2.0"] = function(t: Expect)
		local start = ParkourRules.leap(0, 3)
		t.truthy(start.along == 0 and start.height == 0 and not start.done, "at take-off")
		local mid = ParkourRules.leap(0.3, 3)
		t.near(mid.height, 2, 1e-9, "the apex at half time")
		t.near(mid.along, (3 + 12 + 2) / 2, 1e-9, "half the line")
		local land = ParkourRules.leap(0.6, 3)
		t.truthy(land.done, "done at 0.60 s")
		t.near(land.along, 3 + 12 + 2, 1e-9, "2.0 past the far edge")
		t.near(land.height, 0, 1e-9, "back at the take-off height")
		t.falsy(ParkourRules.leap(0.59, 3).done)
		t.eq(ParkourRules.leapLength(0), 14)
		t.eq(ParkourConfig.Leap.ExitSpeed, 17)
	end,

	["the spec's request window: 8 studs before the strip's end, held 0.3 s, 0.10 s after the edge"] = function(
		t: Expect
	)
		t.eq(ParkourRules.jumpPress(true, 8, -1), "Request")
		t.eq(ParkourRules.jumpPress(true, 8.1, -1), "Jump", "a free jump outside the band")
		t.eq(ParkourRules.jumpPress(false, -1, 0.1), "Request", "0.10 s after running off")
		t.eq(ParkourRules.jumpPress(false, -1, 0.12), "None")
		t.eq(ParkourRules.canLeap(ask({ requestAge = 0.3 })), "Leap")
		t.eq(ParkourRules.canLeap(ask({ requestAge = 0.32 })), "NoRequest")
	end,

	["the spec's start: in the strip (or 0.10 s past the edge), at 15 or more, within 35 degrees"] = function(
		t: Expect
	)
		t.eq(ParkourRules.canLeap(ask()), "Leap")
		t.eq(ParkourRules.canLeap(ask({ speed = 14.99 })), "Slow")
		t.eq(ParkourRules.canLeap(ask({ speed = 15 })), "Leap")
		t.eq(ParkourRules.canLeap(ask({ heading = 35 })), "Leap")
		t.eq(ParkourRules.canLeap(ask({ heading = 35.1 })), "Heading")
		t.eq(ParkourRules.canLeap(ask({ inStrip = false, sinceEdge = 0.1 })), "Leap")
		t.eq(ParkourRules.canLeap(ask({ inStrip = false, sinceEdge = 0.11 })), "Outside")
		t.eq(ParkourRules.canLeap(ask({ requestAge = -1, assist = true })), "Leap", "leap assist")
	end,

	["the spec's leap assist: on for touch and gamepad, off for the keyboard; the server's check"] = function(
		t: Expect
	)
		t.truthy(ParkourRules.assistOn("Auto", "Touch"))
		t.truthy(ParkourRules.assistOn("Auto", "Gamepad"))
		t.falsy(ParkourRules.assistOn("Auto", "KeyboardMouse"))
		t.truthy(ParkourRules.assistOn("On", "KeyboardMouse"))
		t.falsy(ParkourRules.assistOn("Off", "Touch"))
		t.truthy(ParkourRules.serverLeap(true, 11, 60))
		t.falsy(ParkourRules.serverLeap(true, 10.9, 0))
		t.falsy(ParkourRules.serverLeap(true, 12, 61))
		t.eq(ParkourConfig.Leap.ServerExempt, 0.9)
	end,

	["the spec's slide: from 15 on the ground sprinting, 0.70 s, 17 falling to 13, 10.5 studs"] = function(t: Expect)
		t.truthy(ParkourRules.slideStarts(true, true, 15))
		t.falsy(ParkourRules.slideStarts(true, true, 14.9))
		t.falsy(ParkourRules.slideStarts(false, true, 19), "in the air")
		t.falsy(ParkourRules.slideStarts(true, false, 19), "not sprinting: a crouch")
		t.eq(ParkourRules.slide(0).speed, 17)
		local done = ParkourRules.slide(0.7)
		t.near(done.speed, 13, 1e-9)
		t.near(done.distance, 10.5, 1e-9)
		t.truthy(done.done)
		t.eq(ParkourRules.slideEnd(5.2), "Standing")
		t.eq(ParkourRules.slideEnd(4.2), "Crouching", "under a bar it ends crouched")
		t.eq(ParkourConfig.Slide.BodyHeight, 3.7)
		t.eq(ParkourConfig.Slide.EyeOffset, -1.5)
		t.eq(ParkourConfig.Slide.SteerRate, 30)
		t.eq(ParkourConfig.Slide.CrouchSpeed, 5.5)
	end,

	["the spec's hard landing: a fall of 8 or more, 0.6 s at 40 %, HardLanding; never damage"] = function(t: Expect)
		local hard = ParkourRules.hardLanding(8)
		t.truthy(hard.hard and hard.seconds == 0.6 and hard.speedFactor == 0.4 and hard.noise == "HardLanding")
		t.falsy(ParkourRules.hardLanding(7.9).hard)
		for _, fall in { 0, 5, 8, 12, 200 } do
			t.eq(ParkourRules.hardLanding(fall).damage, 0, "never damage: " .. fall)
		end
	end,

	["I9, the envelope: hurdles 2.4 to 2.8, walls 5.5, slide bars 4.2 under 9.7, gaps exactly 12"] = function(
		t: Expect
	)
		t.truthy(ParkourRules.hurdleOk(2.4, 3) and ParkourRules.hurdleOk(2.8, 1))
		t.falsy(ParkourRules.hurdleOk(2.3, 1) or ParkourRules.hurdleOk(2.9, 1) or ParkourRules.hurdleOk(2.6, 3.5))
		t.truthy(ParkourRules.wallOk(5.5) and not ParkourRules.wallOk(5.4))
		t.truthy(ParkourRules.slideBarOk(4.2, 9.7, 6))
		t.falsy(ParkourRules.slideBarOk(4.2, 9.6, 6) or ParkourRules.slideBarOk(4.4, 9.7, 6))
		t.truthy(ParkourRules.gapOk(12))
		t.falsy(ParkourRules.gapOk(11.9) or ParkourRules.gapOk(12.1))
		t.truthy(ParkourRules.streetOk(12) and not ParkourRules.streetOk(11.5))
		t.truthy(ParkourRules.freeJumpOk(8.4) and not ParkourRules.freeJumpOk(10))
		t.truthy(ParkourRules.landingOk(2) and not ParkourRules.landingOk(2.5))
		-- no free jump crosses a leap gap: the longest free jump stays under 10, the gap is 12
		t.truthy(ParkourConfig.FreeJump.Max < ParkourConfig.Leap.Gap)
		t.eq(ParkourConfig.Hurdle.JumpApex, 2.5)
		t.eq(ParkourConfig.Hurdle.StepUp, 1.6)
		t.eq(ParkourConfig.Leap.StripLength, 4)
		t.eq(ParkourConfig.Leap.PadDepth, 8)
		t.truthy(ParkourConfig.Leap.SightEye == 4.4 and ParkourConfig.Leap.SightDistance == 20)
		t.eq(ParkourConfig.Leap.SightRays, 5)
		t.truthy(ParkourConfig.Plank.Width == 3 and ParkourConfig.Plank.Length == 12)
		t.truthy(ParkourConfig.LookBack.Degrees == 150 and ParkourConfig.LookBack.Seconds == 0.18)
	end,

	["I8: a move starts on a 30 Hz tick and reads the same at 20, 30, 60 and 144 fps"] = function(t: Expect)
		t.near(ParkourRules.startTick(0.01), 1 / 30, 1e-12)
		t.near(ParkourRules.startTick(1 / 30), 1 / 30, 1e-12, "a press on a tick starts there")
		local start = ParkourRules.startTick(2.345)
		t.near(start * 30, math.round(start * 30), 1e-9, "on a tick")
		-- every frame rate's tick loop samples the curve at the same tick times, so the body is in the same place
		local reference: { number } = {}
		for tick = 0, 18 do
			reference[tick] = ParkourRules.leap(tick / 30, 2).along
		end
		for _, fps in { 20, 30, 60, 144 } do
			local accumulator, tick = 0, 0
			while tick < 18 do
				accumulator += 1 / fps
				while accumulator >= 1 / 30 - 1e-12 and tick < 18 do
					accumulator -= 1 / 30
					tick += 1
					t.eq(
						ParkourRules.leap(tick / 30, 2).along,
						reference[tick],
						string.format("%d fps, tick %d", fps, tick)
					)
				end
			end
		end
	end,
}
