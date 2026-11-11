--!strict
-- ParkourConfig: the moves and the envelope of the player's body (docs/design/game-spec-v2.md 3.1; invariants I8 and
-- I9). ParkourRules is the pure logic over them (the leap curve, the slide's profile, the request window, the hard
-- landing, the envelope checks). Studs, studs per second, seconds and degrees; the same on both difficulties.
--
--   Tick: the body steps on the 30 Hz tick in Substeps substeps; motion that is a function of time starts on a tick.
--   Hurdle: a free jump (apex JumpApex) over a bar Min..Max high and at most MaxDepth deep; the web's body steps up
--   StepUp and mounts JumpMount. Wall: an unclimbable wall is at least Min high. FreeJump: the longest free jump either
--   body makes stays under Max (the web's is about Web). Street: every street, alley and leap gap at least Min wide.
--   Slide: crouch while sprinting at MinSpeed or more on the ground: Seconds long, SpeedStart falling linearly to
--   SpeedEnd (Distance in all), the body BodyHeight tall and the eye EyeOffset, steering at most SteerRate; it ends
--   standing with StandHeight of headroom, else crouched. Bars leave Clear under them and stand solid from Clear to at
--   least SolidTop, at most MaxDepth deep; crouch-walking under one goes at CrouchSpeed.
--   Leap: a gap exactly Gap wide, landing level or at most LandingDrop lower; a StripLength take-off strip, a lit pad
--   at least PadDepth deep. Inside the Band studs before the strip's end a jump press is held as a request for
--   RequestHold; a press up to Coyote after running off the edge counts too. It starts at the first tick inside the
--   strip (or past the edge within Coyote) with a live request, at MinSpeed or faster, heading within MaxHeading of
--   the leap. Seconds long: a straight line from the take-off point to Overshoot past the far edge, height a
--   parabola of apex Apex, no collision, no input; ExitSpeed along the leap after it. Never blind: from SightEye over
--   the feet, SightDistance before the strip, SightRays rays reach the pad. The Roblox server accepts a leap seen in
--   the strip at ServerMinSpeed or faster, facing within ServerMaxHeading, and exempts the mover ServerExempt.
--   HardLanding: a fall of Fall or more slows the body to SpeedFactor for Seconds; never damage.
--   Plank, FireEscape: the city's walkable links. LookBack: the held look turns Degrees in Seconds.
--   RobloxEnvelope: the Humanoid's step-up and jump mount (the spec's estimates; RP02 measures them).

local ParkourConfig = {}

ParkourConfig.Tick = table.freeze({ Hz = 30, Substeps = 2 })

ParkourConfig.Hurdle =
	table.freeze({ Min = 2.4, Max = 2.8, MaxDepth = 3, JumpApex = 2.5, StepUp = 1.6, JumpMount = 4.1 })

ParkourConfig.Wall = table.freeze({ Min = 5.5 })

ParkourConfig.FreeJump = table.freeze({ Max = 10, Web = 8.4 })

ParkourConfig.Street = table.freeze({ Min = 12 })

ParkourConfig.Slide = table.freeze({
	MinSpeed = 15,
	Seconds = 0.7,
	SpeedStart = 17,
	SpeedEnd = 13,
	Distance = 10.5,
	BodyHeight = 3.7,
	EyeOffset = -1.5,
	SteerRate = 30,
	StandHeight = 5.2,
	Clear = 4.2,
	SolidTop = 9.7,
	MaxDepth = 6,
	CrouchSpeed = 5.5,
})

ParkourConfig.Leap = table.freeze({
	Gap = 12,
	LandingDrop = 2,
	StripLength = 4,
	PadDepth = 8,
	Band = 8,
	RequestHold = 0.3,
	Coyote = 0.1,
	MinSpeed = 15,
	MaxHeading = 35,
	Seconds = 0.6,
	Overshoot = 2,
	Apex = 2,
	ExitSpeed = 17,
	SightEye = 4.4,
	SightDistance = 20,
	SightRays = 5,
	ServerMinSpeed = 11,
	ServerMaxHeading = 60,
	ServerExempt = 0.9,
})

ParkourConfig.HardLanding = table.freeze({ Fall = 8, Seconds = 0.6, SpeedFactor = 0.4 })

ParkourConfig.Plank = table.freeze({ Width = 3, Thickness = 0.5, Length = 12 })

ParkourConfig.FireEscape = table.freeze({ Width = 4, RiserMax = 1, TreadMin = 1.25, Rail = 3.5 })

ParkourConfig.LookBack = table.freeze({ Degrees = 150, Seconds = 0.18 })

ParkourConfig.RobloxEnvelope = table.freeze({ StepUp = 2, JumpMount = 4.5 })

-- Every table above as plain data for the website (world.json meta.parkourConfig).
function ParkourConfig.exportMeta(): { [string]: any }
	local out: { [string]: any } = {}
	for key, value in ParkourConfig :: { [string]: any } do
		if type(value) == "table" then
			out[key] = table.clone(value)
		end
	end
	return out
end

return table.freeze(ParkourConfig)
