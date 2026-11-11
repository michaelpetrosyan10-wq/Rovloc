--!strict
-- ParkourRules: the parkour moves as pure functions (docs/design/game-spec-v2.md 3.1, ParkourConfig; invariants I8 and
-- I9). Every curve is a function of the time since its start, and a start lands on a 30 Hz tick, so the motion is the
-- same at any frame rate. The web's body and the Roblox client sample the same curves; the website's port is checked
-- against golden() (written to build/cache/golden.json by the export).
--
--   startTick     the time a move started at `time` begins: the next 30 Hz tick at or after it
--   leap          the leap at `t` seconds after its start, taking off `takeoff` studs before the near lip: `along` the
--                 leap direction (a straight line to Overshoot past the far edge, the side offset kept), `height` over
--                 the take-off (a parabola of apex Apex), `done` once Seconds have passed
--   leapLength    the studs a leap covers from a take-off `takeoff` before the lip
--   jumpPress     what a jump press does: a leap Request inside the approach band (the Band studs before the strip's
--                 end, or up to Coyote seconds after running off the edge), a free Jump elsewhere on the ground, None
--                 in the air
--   canLeap       whether a leap starts this tick (Leap), or why not: Outside (not in the strip nor just past the
--                 edge), Slow, Heading, NoRequest (no live request; leap assist makes one in the strip)
--   assistOn      the Leap assist setting for a device: Auto is on for touch and gamepad, off for the keyboard
--   serverLeap    the Roblox server's check of a leap: in the strip, observed speed and facing
--   slideStarts   whether a crouch press starts a slide (on the ground, sprinting, fast enough) or crouches
--   slide         the slide at `t`: its speed (SpeedStart falling linearly to SpeedEnd), the distance so far, done
--   slideEnd      how a slide ends: Standing with the headroom for it, else Crouching
--   hardLanding   a landing after a fall of `fall` studs: hard (slowed, HardLanding noise) from Fall; never damage
--   hurdleOk, wallOk, gapOk, slideBarOk, streetOk, freeJumpOk, landingOk  the envelope (I9)
--
-- Pure: no engine, no clock, no randomness; plain numbers and tables in and out.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConfig = require(ReplicatedStorage.Shared.Config.ParkourConfig)

export type LeapAsk = {
	inStrip: boolean,
	sinceEdge: number, -- seconds since the root left the lip (-1: still on this side)
	requestAge: number, -- seconds since the request was made (-1: none)
	speed: number, -- horizontal studs per second
	heading: number, -- degrees between the motion and the leap direction
	assist: boolean,
}

export type GoldenRow = { name: string, fn: string, args: { any }, expect: any }

local EPS = 1e-6
local LEAP = ParkourConfig.Leap
local SLIDE = ParkourConfig.Slide

local ParkourRules = {}

function ParkourRules.startTick(time: number): number
	local hz = ParkourConfig.Tick.Hz
	return math.ceil(time * hz - EPS) / hz
end

function ParkourRules.leapLength(takeoff: number): number
	return takeoff + LEAP.Gap + LEAP.Overshoot
end

function ParkourRules.leap(t: number, takeoff: number): { along: number, height: number, done: boolean }
	local u = math.clamp(t / LEAP.Seconds, 0, 1)
	return {
		along = ParkourRules.leapLength(takeoff) * u,
		height = 4 * LEAP.Apex * u * (1 - u),
		done = t >= LEAP.Seconds - EPS,
	}
end

function ParkourRules.jumpPress(onGround: boolean, toEdge: number, sinceEdge: number): string
	if onGround then
		return if toEdge >= 0 and toEdge <= LEAP.Band then "Request" else "Jump"
	end
	return if sinceEdge >= 0 and sinceEdge <= LEAP.Coyote + EPS then "Request" else "None"
end

function ParkourRules.canLeap(ask: LeapAsk): string
	local justPast = ask.sinceEdge >= 0 and ask.sinceEdge <= LEAP.Coyote + EPS
	if not ask.inStrip and not justPast then
		return "Outside"
	elseif ask.speed < LEAP.MinSpeed then
		return "Slow"
	elseif ask.heading > LEAP.MaxHeading then
		return "Heading"
	end
	local live = ask.requestAge >= 0 and ask.requestAge <= LEAP.RequestHold + EPS
	if live or (ask.assist and ask.inStrip) then
		return "Leap"
	end
	return "NoRequest"
end

function ParkourRules.assistOn(setting: string, device: string): boolean
	if setting == "On" then
		return true
	elseif setting == "Off" then
		return false
	end
	return device ~= "KeyboardMouse"
end

function ParkourRules.serverLeap(inStrip: boolean, observedSpeed: number, facing: number): boolean
	return inStrip and observedSpeed >= LEAP.ServerMinSpeed and facing <= LEAP.ServerMaxHeading
end

function ParkourRules.slideStarts(onGround: boolean, sprinting: boolean, speed: number): boolean
	return onGround and sprinting and speed >= SLIDE.MinSpeed
end

function ParkourRules.slide(t: number): { speed: number, distance: number, done: boolean }
	local s = math.clamp(t, 0, SLIDE.Seconds)
	local fall = (SLIDE.SpeedStart - SLIDE.SpeedEnd) / SLIDE.Seconds
	return {
		speed = SLIDE.SpeedStart - fall * s,
		distance = SLIDE.SpeedStart * s - fall * s * s / 2,
		done = t >= SLIDE.Seconds - EPS,
	}
end

function ParkourRules.slideEnd(headroom: number): string
	return if headroom >= SLIDE.StandHeight then "Standing" else "Crouching"
end

function ParkourRules.hardLanding(
	fall: number
): { hard: boolean, seconds: number, speedFactor: number, noise: string, damage: number }
	local c = ParkourConfig.HardLanding
	if fall >= c.Fall then
		return { hard = true, seconds = c.Seconds, speedFactor = c.SpeedFactor, noise = "HardLanding", damage = 0 }
	end
	return { hard = false, seconds = 0, speedFactor = 1, noise = "", damage = 0 }
end

function ParkourRules.hurdleOk(height: number, depth: number): boolean
	local c = ParkourConfig.Hurdle
	return height >= c.Min - EPS and height <= c.Max + EPS and depth <= c.MaxDepth + EPS
end

function ParkourRules.wallOk(height: number): boolean
	return height >= ParkourConfig.Wall.Min - EPS
end

function ParkourRules.gapOk(width: number): boolean
	return math.abs(width - LEAP.Gap) <= 1e-3
end

function ParkourRules.slideBarOk(clear: number, solidTop: number, depth: number): boolean
	return math.abs(clear - SLIDE.Clear) <= 1e-3 and solidTop >= SLIDE.SolidTop - EPS and depth <= SLIDE.MaxDepth + EPS
end

function ParkourRules.streetOk(width: number): boolean
	return width >= ParkourConfig.Street.Min - EPS
end

function ParkourRules.freeJumpOk(longest: number): boolean
	return longest < ParkourConfig.FreeJump.Max
end

function ParkourRules.landingOk(drop: number): boolean
	return drop >= -EPS and drop <= LEAP.LandingDrop + EPS
end

--------------------------------------------------------------------------------
-- Golden rows (every function's answers for the website's port to replay)
--------------------------------------------------------------------------------

local ROWS: { GoldenRow } = {}

local function row(name: string, fn: string, args: { any }, expect: any)
	table.insert(ROWS, { name = name, fn = fn, args = args, expect = expect })
end

row("startTick 0", "startTick", { 0 }, 0)
row("startTick 0.01", "startTick", { 0.01 }, 0.03333333333333333)
row("startTick 0.03333333333333333", "startTick", { 0.03333333333333333 }, 0.03333333333333333)
row("startTick 0.034", "startTick", { 0.034 }, 0.06666666666666667)
row("startTick 0.05", "startTick", { 0.05 }, 0.06666666666666667)
row("startTick 0.06666666666666667", "startTick", { 0.06666666666666667 }, 0.06666666666666667)
row("startTick 0.1", "startTick", { 0.1 }, 0.1)
row("startTick 0.5", "startTick", { 0.5 }, 0.5)
row("startTick 1", "startTick", { 1 }, 1)
row("startTick 1.0166", "startTick", { 1.0166 }, 1.0333333333333334)
row("startTick 2.98", "startTick", { 2.98 }, 3)
row("startTick 10.0001", "startTick", { 10.0001 }, 10.033333333333333)
row("leapLength 0", "leapLength", { 0 }, 14)
row("leapLength 0.5", "leapLength", { 0.5 }, 14.5)
row("leapLength 1", "leapLength", { 1 }, 15)
row("leapLength 2", "leapLength", { 2 }, 16)
row("leapLength 3", "leapLength", { 3 }, 17)
row("leapLength 4", "leapLength", { 4 }, 18)
row("leapLength -0.5", "leapLength", { -0.5 }, 13.5)
row("leapLength -1.5", "leapLength", { -1.5 }, 12.5)
row("leapLength 3.25", "leapLength", { 3.25 }, 17.25)
row("leapLength 1.75", "leapLength", { 1.75 }, 15.75)
row("leapLength 0.1", "leapLength", { 0.1 }, 14.1)
row("leapLength 2.6", "leapLength", { 2.6 }, 16.6)
row("leap t -0.1 takeoff 2", "leap", { -0.1, 2 }, { along = 0, done = false, height = 0 })
row("leap t 0 takeoff 2", "leap", { 0, 2 }, { along = 0, done = false, height = 0 })
row(
	"leap t 0.1 takeoff 2",
	"leap",
	{ 0.1, 2 },
	{ along = 2.666666666666667, done = false, height = 1.1111111111111112 }
)
row("leap t 0.15 takeoff 0", "leap", { 0.15, 0 }, { along = 3.5, done = false, height = 1.5 })
row("leap t 0.3 takeoff 4", "leap", { 0.3, 4 }, { along = 9, done = false, height = 2 })
row("leap t 0.3 takeoff 0", "leap", { 0.3, 0 }, { along = 7, done = false, height = 2 })
row("leap t 0.45 takeoff 4", "leap", { 0.45, 4 }, { along = 13.5, done = false, height = 1.5 })
row("leap t 0.5 takeoff 1", "leap", { 0.5, 1 }, { along = 12.5, done = false, height = 1.111111111111111 })
row("leap t 0.6 takeoff 2", "leap", { 0.6, 2 }, { along = 16, done = true, height = 0 })
row("leap t 0.6 takeoff 0", "leap", { 0.6, 0 }, { along = 14, done = true, height = 0 })
row("leap t 0.7 takeoff 2", "leap", { 0.7, 2 }, { along = 16, done = true, height = 0 })
row(
	"leap t 0.03333333333333333 takeoff 3",
	"leap",
	{ 0.03333333333333333, 3 },
	{ along = 0.9444444444444445, done = false, height = 0.4197530864197531 }
)
row(
	"leap t 0.2 takeoff -0.5",
	"leap",
	{ 0.2, -0.5 },
	{ along = 4.500000000000001, done = false, height = 1.777777777777778 }
)
row("leap t 0.59 takeoff 1", "leap", { 0.59, 1 }, { along = 14.75, done = false, height = 0.1311111111111115 })
row("jumpPress on the ground far from a strip", "jumpPress", { true, 999, -1 }, "Jump")
row("jumpPress at the band's start", "jumpPress", { true, 8, -1 }, "Request")
row("jumpPress just outside the band", "jumpPress", { true, 8.01, -1 }, "Jump")
row("jumpPress in the band", "jumpPress", { true, 4, -1 }, "Request")
row("jumpPress at the lip", "jumpPress", { true, 0, -1 }, "Request")
row("jumpPress past the lip on the ground", "jumpPress", { true, -0.5, -1 }, "Jump")
row("jumpPress in the air, never off an edge", "jumpPress", { false, 999, -1 }, "None")
row("jumpPress just off the edge", "jumpPress", { false, -0.2, 0 }, "Request")
row("jumpPress 0.05 s off the edge", "jumpPress", { false, -1, 0.05 }, "Request")
row("jumpPress 0.10 s off the edge", "jumpPress", { false, -1.5, 0.1 }, "Request")
row("jumpPress 0.11 s off the edge", "jumpPress", { false, -1.6, 0.11 }, "None")
row("jumpPress a long fall", "jumpPress", { false, -5, 1 }, "None")
row("jumpPress on the ground in the band, the edge long ago", "jumpPress", { true, 2, 3 }, "Request")
row("jumpPress in the band at 7.99", "jumpPress", { true, 7.99, -1 }, "Request")
row(
	"canLeap a live request in the strip",
	"canLeap",
	{ { assist = false, heading = 10, inStrip = true, requestAge = 0.1, sinceEdge = -1, speed = 18 } },
	"Leap"
)
row(
	"canLeap the request at 0.30 s",
	"canLeap",
	{ { assist = false, heading = 35, inStrip = true, requestAge = 0.3, sinceEdge = -1, speed = 15 } },
	"Leap"
)
row(
	"canLeap the request at 0.31 s",
	"canLeap",
	{ { assist = false, heading = 0, inStrip = true, requestAge = 0.31, sinceEdge = -1, speed = 18 } },
	"NoRequest"
)
row(
	"canLeap no request",
	"canLeap",
	{ { assist = false, heading = 0, inStrip = true, requestAge = -1, sinceEdge = -1, speed = 18 } },
	"NoRequest"
)
row(
	"canLeap assist makes the request in the strip",
	"canLeap",
	{ { assist = true, heading = 20, inStrip = true, requestAge = -1, sinceEdge = -1, speed = 17 } },
	"Leap"
)
row(
	"canLeap assist does not leap off the strip",
	"canLeap",
	{ { assist = true, heading = 0, inStrip = false, requestAge = -1, sinceEdge = 0.05, speed = 17 } },
	"NoRequest"
)
row(
	"canLeap too slow",
	"canLeap",
	{ { assist = false, heading = 0, inStrip = true, requestAge = 0.1, sinceEdge = -1, speed = 14.9 } },
	"Slow"
)
row(
	"canLeap too far off the line",
	"canLeap",
	{ { assist = false, heading = 35.5, inStrip = true, requestAge = 0.1, sinceEdge = -1, speed = 19 } },
	"Heading"
)
row(
	"canLeap before the strip",
	"canLeap",
	{ { assist = false, heading = 0, inStrip = false, requestAge = 0.1, sinceEdge = -1, speed = 19 } },
	"Outside"
)
row(
	"canLeap just past the edge with a request",
	"canLeap",
	{ { assist = false, heading = 5, inStrip = false, requestAge = 0.05, sinceEdge = 0.08, speed = 16 } },
	"Leap"
)
row(
	"canLeap too long past the edge",
	"canLeap",
	{ { assist = false, heading = 5, inStrip = false, requestAge = 0.05, sinceEdge = 0.15, speed = 16 } },
	"Outside"
)
row(
	"canLeap assist too slow",
	"canLeap",
	{ { assist = true, heading = 0, inStrip = true, requestAge = -1, sinceEdge = -1, speed = 12 } },
	"Slow"
)
row(
	"canLeap assist off the line",
	"canLeap",
	{ { assist = true, heading = 50, inStrip = true, requestAge = -1, sinceEdge = -1, speed = 19 } },
	"Heading"
)
row(
	"canLeap exactly 15 and 35 with assist",
	"canLeap",
	{ { assist = true, heading = 35, inStrip = true, requestAge = -1, sinceEdge = -1, speed = 15 } },
	"Leap"
)
row("assistOn Auto KeyboardMouse", "assistOn", { "Auto", "KeyboardMouse" }, false)
row("assistOn Auto Gamepad", "assistOn", { "Auto", "Gamepad" }, true)
row("assistOn Auto Touch", "assistOn", { "Auto", "Touch" }, true)
row("assistOn On KeyboardMouse", "assistOn", { "On", "KeyboardMouse" }, true)
row("assistOn On Gamepad", "assistOn", { "On", "Gamepad" }, true)
row("assistOn On Touch", "assistOn", { "On", "Touch" }, true)
row("assistOn Off KeyboardMouse", "assistOn", { "Off", "KeyboardMouse" }, false)
row("assistOn Off Gamepad", "assistOn", { "Off", "Gamepad" }, false)
row("assistOn Off Touch", "assistOn", { "Off", "Touch" }, false)
row("assistOn an unknown setting is Auto (keyboard)", "assistOn", { "", "KeyboardMouse" }, false)
row("assistOn an unknown setting is Auto (touch)", "assistOn", { "Maybe", "Touch" }, true)
row("assistOn Auto on an unknown device", "assistOn", { "Auto", "VR" }, true)
row("serverLeap strip true speed 11 facing 60", "serverLeap", { true, 11, 60 }, true)
row("serverLeap strip true speed 10.9 facing 0", "serverLeap", { true, 10.9, 0 }, false)
row("serverLeap strip true speed 20 facing 61", "serverLeap", { true, 20, 61 }, false)
row("serverLeap strip false speed 20 facing 0", "serverLeap", { false, 20, 0 }, false)
row("serverLeap strip true speed 15 facing 30", "serverLeap", { true, 15, 30 }, true)
row("serverLeap strip true speed 11 facing 0", "serverLeap", { true, 11, 0 }, true)
row("serverLeap strip true speed 25 facing 59.9", "serverLeap", { true, 25, 59.9 }, true)
row("serverLeap strip false speed 11 facing 60", "serverLeap", { false, 11, 60 }, false)
row("serverLeap strip true speed 0 facing 0", "serverLeap", { true, 0, 0 }, false)
row("serverLeap strip true speed 17 facing 60.01", "serverLeap", { true, 17, 60.01 }, false)
row("serverLeap strip true speed 12 facing 45", "serverLeap", { true, 12, 45 }, true)
row("serverLeap strip false speed 0 facing 90", "serverLeap", { false, 0, 90 }, false)
row("slideStarts ground true sprint true speed 15", "slideStarts", { true, true, 15 }, true)
row("slideStarts ground true sprint true speed 14.99", "slideStarts", { true, true, 14.99 }, false)
row("slideStarts ground true sprint false speed 19", "slideStarts", { true, false, 19 }, false)
row("slideStarts ground false sprint true speed 19", "slideStarts", { false, true, 19 }, false)
row("slideStarts ground true sprint true speed 19", "slideStarts", { true, true, 19 }, true)
row("slideStarts ground false sprint false speed 0", "slideStarts", { false, false, 0 }, false)
row("slideStarts ground true sprint true speed 0", "slideStarts", { true, true, 0 }, false)
row("slideStarts ground true sprint false speed 15", "slideStarts", { true, false, 15 }, false)
row("slideStarts ground false sprint true speed 15", "slideStarts", { false, true, 15 }, false)
row("slideStarts ground true sprint true speed 17", "slideStarts", { true, true, 17 }, true)
row("slideStarts ground true sprint true speed 30", "slideStarts", { true, true, 30 }, true)
row("slideStarts ground false sprint false speed 19", "slideStarts", { false, false, 19 }, false)
row("slide t -0.1", "slide", { -0.1 }, { distance = 0, done = false, speed = 17 })
row("slide t 0", "slide", { 0 }, { distance = 0, done = false, speed = 17 })
row("slide t 0.1", "slide", { 0.1 }, { distance = 1.6714285714285717, done = false, speed = 16.428571428571427 })
row("slide t 0.2", "slide", { 0.2 }, { distance = 3.285714285714286, done = false, speed = 15.857142857142858 })
row("slide t 0.35", "slide", { 0.35 }, { distance = 5.6, done = false, speed = 15 })
row("slide t 0.5", "slide", { 0.5 }, { distance = 7.785714285714286, done = false, speed = 14.142857142857142 })
row("slide t 0.6", "slide", { 0.6 }, { distance = 9.17142857142857, done = false, speed = 13.571428571428571 })
row("slide t 0.69", "slide", { 0.69 }, { distance = 10.369714285714284, done = false, speed = 13.057142857142857 })
row("slide t 0.7", "slide", { 0.7 }, { distance = 10.499999999999998, done = true, speed = 13 })
row("slide t 0.8", "slide", { 0.8 }, { distance = 10.499999999999998, done = true, speed = 13 })
row(
	"slide t 0.03333333333333333",
	"slide",
	{ 0.03333333333333333 },
	{ distance = 0.5634920634920635, done = false, speed = 16.80952380952381 }
)
row("slide t 2", "slide", { 2 }, { distance = 10.499999999999998, done = true, speed = 13 })
row("slideEnd headroom 0", "slideEnd", { 0 }, "Crouching")
row("slideEnd headroom 3.7", "slideEnd", { 3.7 }, "Crouching")
row("slideEnd headroom 4.2", "slideEnd", { 4.2 }, "Crouching")
row("slideEnd headroom 5.19", "slideEnd", { 5.19 }, "Crouching")
row("slideEnd headroom 5.2", "slideEnd", { 5.2 }, "Standing")
row("slideEnd headroom 5.21", "slideEnd", { 5.21 }, "Standing")
row("slideEnd headroom 9.7", "slideEnd", { 9.7 }, "Standing")
row("slideEnd headroom 100", "slideEnd", { 100 }, "Standing")
row("slideEnd headroom 4.3", "slideEnd", { 4.3 }, "Crouching")
row("slideEnd headroom 5", "slideEnd", { 5 }, "Crouching")
row("slideEnd headroom 6", "slideEnd", { 6 }, "Standing")
row("slideEnd headroom 3.69", "slideEnd", { 3.69 }, "Crouching")
row("hardLanding fall 0", "hardLanding", { 0 }, { damage = 0, hard = false, noise = "", seconds = 0, speedFactor = 1 })
row("hardLanding fall 1", "hardLanding", { 1 }, { damage = 0, hard = false, noise = "", seconds = 0, speedFactor = 1 })
row(
	"hardLanding fall 2.5",
	"hardLanding",
	{ 2.5 },
	{ damage = 0, hard = false, noise = "", seconds = 0, speedFactor = 1 }
)
row("hardLanding fall 4", "hardLanding", { 4 }, { damage = 0, hard = false, noise = "", seconds = 0, speedFactor = 1 })
row(
	"hardLanding fall 7.99",
	"hardLanding",
	{ 7.99 },
	{ damage = 0, hard = false, noise = "", seconds = 0, speedFactor = 1 }
)
row(
	"hardLanding fall 8",
	"hardLanding",
	{ 8 },
	{ damage = 0, hard = true, noise = "HardLanding", seconds = 0.6, speedFactor = 0.4 }
)
row(
	"hardLanding fall 8.01",
	"hardLanding",
	{ 8.01 },
	{ damage = 0, hard = true, noise = "HardLanding", seconds = 0.6, speedFactor = 0.4 }
)
row(
	"hardLanding fall 12",
	"hardLanding",
	{ 12 },
	{ damage = 0, hard = true, noise = "HardLanding", seconds = 0.6, speedFactor = 0.4 }
)
row(
	"hardLanding fall 30",
	"hardLanding",
	{ 30 },
	{ damage = 0, hard = true, noise = "HardLanding", seconds = 0.6, speedFactor = 0.4 }
)
row(
	"hardLanding fall 100",
	"hardLanding",
	{ 100 },
	{ damage = 0, hard = true, noise = "HardLanding", seconds = 0.6, speedFactor = 0.4 }
)
row(
	"hardLanding fall 0.2",
	"hardLanding",
	{ 0.2 },
	{ damage = 0, hard = false, noise = "", seconds = 0, speedFactor = 1 }
)
row("hardLanding fall 6", "hardLanding", { 6 }, { damage = 0, hard = false, noise = "", seconds = 0, speedFactor = 1 })
row("hurdleOk 2.4 deep 1", "hurdleOk", { 2.4, 1 }, true)
row("hurdleOk 2.8 deep 3", "hurdleOk", { 2.8, 3 }, true)
row("hurdleOk 2.39 deep 1", "hurdleOk", { 2.39, 1 }, false)
row("hurdleOk 2.81 deep 1", "hurdleOk", { 2.81, 1 }, false)
row("hurdleOk 2.6 deep 3.01", "hurdleOk", { 2.6, 3.01 }, false)
row("hurdleOk 2.6 deep 0.5", "hurdleOk", { 2.6, 0.5 }, true)
row("hurdleOk 2.5 deep 2", "hurdleOk", { 2.5, 2 }, true)
row("hurdleOk 1.6 deep 1", "hurdleOk", { 1.6, 1 }, false)
row("hurdleOk 4.1 deep 1", "hurdleOk", { 4.1, 1 }, false)
row("hurdleOk 2.7 deep 3", "hurdleOk", { 2.7, 3 }, true)
row("hurdleOk 2.4 deep 3.1", "hurdleOk", { 2.4, 3.1 }, false)
row("hurdleOk 0 deep 0", "hurdleOk", { 0, 0 }, false)
row("wallOk 5.5", "wallOk", { 5.5 }, true)
row("wallOk 5.49", "wallOk", { 5.49 }, false)
row("wallOk 6", "wallOk", { 6 }, true)
row("wallOk 12", "wallOk", { 12 }, true)
row("wallOk 4.1", "wallOk", { 4.1 }, false)
row("wallOk 4.5", "wallOk", { 4.5 }, false)
row("wallOk 0", "wallOk", { 0 }, false)
row("wallOk 30", "wallOk", { 30 }, true)
row("wallOk 5.5001", "wallOk", { 5.5001 }, true)
row("wallOk 5.45", "wallOk", { 5.45 }, false)
row("wallOk 10", "wallOk", { 10 }, true)
row("wallOk 2.8", "wallOk", { 2.8 }, false)
row("gapOk 12", "gapOk", { 12 }, true)
row("gapOk 11.999", "gapOk", { 11.999 }, true)
row("gapOk 12.0005", "gapOk", { 12.0005 }, true)
row("gapOk 11.99", "gapOk", { 11.99 }, false)
row("gapOk 12.01", "gapOk", { 12.01 }, false)
row("gapOk 8.4", "gapOk", { 8.4 }, false)
row("gapOk 10", "gapOk", { 10 }, false)
row("gapOk 13", "gapOk", { 13 }, false)
row("gapOk 24", "gapOk", { 24 }, false)
row("gapOk 0", "gapOk", { 0 }, false)
row("gapOk 12.002", "gapOk", { 12.002 }, false)
row("gapOk 11.9995", "gapOk", { 11.9995 }, true)
row("slideBarOk clear 4.2 solid 9.7 deep 6", "slideBarOk", { 4.2, 9.7, 6 }, true)
row("slideBarOk clear 4.2 solid 12 deep 2", "slideBarOk", { 4.2, 12, 2 }, true)
row("slideBarOk clear 4.1 solid 9.7 deep 6", "slideBarOk", { 4.1, 9.7, 6 }, false)
row("slideBarOk clear 4.3 solid 9.7 deep 6", "slideBarOk", { 4.3, 9.7, 6 }, false)
row("slideBarOk clear 4.2 solid 9.6 deep 6", "slideBarOk", { 4.2, 9.6, 6 }, false)
row("slideBarOk clear 4.2 solid 9.7 deep 6.1", "slideBarOk", { 4.2, 9.7, 6.1 }, false)
row("slideBarOk clear 4.2 solid 20 deep 0.5", "slideBarOk", { 4.2, 20, 0.5 }, true)
row("slideBarOk clear 3.7 solid 9.7 deep 1", "slideBarOk", { 3.7, 9.7, 1 }, false)
row("slideBarOk clear 5.2 solid 10 deep 1", "slideBarOk", { 5.2, 10, 1 }, false)
row("slideBarOk clear 4.2005 solid 9.7 deep 6", "slideBarOk", { 4.2005, 9.7, 6 }, true)
row("slideBarOk clear 4.2 solid 9.69 deep 3", "slideBarOk", { 4.2, 9.69, 3 }, false)
row("slideBarOk clear 4.2 solid 9.7 deep 0", "slideBarOk", { 4.2, 9.7, 0 }, true)
row("streetOk 12", "streetOk", { 12 }, true)
row("streetOk 11.99", "streetOk", { 11.99 }, false)
row("streetOk 16", "streetOk", { 16 }, true)
row("streetOk 24", "streetOk", { 24 }, true)
row("streetOk 6", "streetOk", { 6 }, false)
row("streetOk 0", "streetOk", { 0 }, false)
row("streetOk 12.5", "streetOk", { 12.5 }, true)
row("streetOk 11", "streetOk", { 11 }, false)
row("streetOk 100", "streetOk", { 100 }, true)
row("streetOk 11.9999999", "streetOk", { 11.9999999 }, true)
row("streetOk 13", "streetOk", { 13 }, true)
row("streetOk 8", "streetOk", { 8 }, false)
row("freeJumpOk 8.4", "freeJumpOk", { 8.4 }, true)
row("freeJumpOk 9.99", "freeJumpOk", { 9.99 }, true)
row("freeJumpOk 10", "freeJumpOk", { 10 }, false)
row("freeJumpOk 10.01", "freeJumpOk", { 10.01 }, false)
row("freeJumpOk 0", "freeJumpOk", { 0 }, true)
row("freeJumpOk 6.2", "freeJumpOk", { 6.2 }, true)
row("freeJumpOk 9.5", "freeJumpOk", { 9.5 }, true)
row("freeJumpOk 12", "freeJumpOk", { 12 }, false)
row("freeJumpOk 4.5", "freeJumpOk", { 4.5 }, true)
row("freeJumpOk 9.999", "freeJumpOk", { 9.999 }, true)
row("freeJumpOk 11", "freeJumpOk", { 11 }, false)
row("freeJumpOk 7", "freeJumpOk", { 7 }, true)
row("landingOk 0", "landingOk", { 0 }, true)
row("landingOk 1", "landingOk", { 1 }, true)
row("landingOk 2", "landingOk", { 2 }, true)
row("landingOk 2.01", "landingOk", { 2.01 }, false)
row("landingOk -0.5", "landingOk", { -0.5 }, false)
row("landingOk 1.99", "landingOk", { 1.99 }, true)
row("landingOk 3", "landingOk", { 3 }, false)
row("landingOk 12", "landingOk", { 12 }, false)
row("landingOk 0.5", "landingOk", { 0.5 }, true)
row("landingOk -0.0001", "landingOk", { -0.0001 }, false)
row("landingOk 2.0000001", "landingOk", { 2.0000001 }, true)
row("landingOk 8", "landingOk", { 8 }, false)

-- The golden rows: { name, fn, args, expect } with expect what ParkourRules[fn](table.unpack(args)) returns.
function ParkourRules.golden(): { GoldenRow }
	return ROWS
end

return table.freeze(ParkourRules)
