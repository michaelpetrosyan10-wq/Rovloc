--!strict
-- TakeoffConfig: Wheels Up's numbers (spec v2 §4.9): the 1-D takeoff run, steering, the obstacle rows and their three
-- authored patterns, knocks, his chase from behind and his stand ahead. TakeoffRules (Shared/Rules) runs them on the
-- 30 Hz tick; the Runway set builds its rows and his mark from the same tables, and the web reads them through
-- exportMeta() (meta.takeoffConfig). Values in [brackets] in comments are Nightmare's.
--
-- s is distance down the runway (the tail's), v speed, x the offset from the centre line (studs, + to the right).
-- Each obstacle row leaves one gap GapWidth wide, centred at a pattern's x; the plane, PlaneWidth wide, clears a row
-- when |x - gap| <= (GapWidth - PlaneWidth) / 2. Patterns list the gap centres of the twelve rows in order.

export type DifficultySpec = {
	KnockLoss: number, -- a knock leaves v = max(KnockFactor x v, v - KnockLoss)
	ChaseStart: number, -- he starts this far behind the tail at t = 0
	FreeAttempts: number, -- attempts per squad that cost no respawn (§3.3)
}

local TakeoffConfig = {
	TickRate = 30,
	Accel = 2.5, -- studs/s^2: the throttle is locked open
	TopSpeed = 70,
	RotateSpeed = 60, -- from here the HUD shouts PULL UP!
	RotateHold = 1.0, -- seconds of pull-up held at or above RotateSpeed to lift off
	SteerSpeed = 16, -- studs/s across the runway at full stick
	SteerRamp = 0.25, -- seconds from rest to full steering speed
	MaxOffset = 25, -- |x| limit
	PlaneWidth = 10,
	RunwayWidth = 60,
	RunwayEnd = 1450, -- the fence: not airborne by here and the plane ploughs through it
	VisibleRange = 200, -- red beacons and runway lights are unfogged from this far
	GapWidth = 22,
	MaxGapStep = 18, -- the next row's gap is at most this far aside
	Rows = table.freeze({ 70, 150, 250, 360, 470, 580, 800, 910, 1020, 1130, 1240, 1350 }),
	Patterns = table.freeze({
		table.freeze({ -18, -18, 0, 18, 0, -18, 0, 18, 0, -18, 0, 18 }),
		table.freeze({ 18, 18, 0, -18, -18, 0, 0, -18, 0, 18, 18, 0 }),
		table.freeze({ -18, -18, -18, 0, 18, 18, 0, 0, -18, -18, 0, 18 }),
	}),
	KnockFactor = 0.6,
	ChaseSpeed = 22, -- he runs at this from behind for the first ChaseSeconds
	ChaseSeconds = 16,
	TearGap = 4, -- the gap at which he tears the tail off
	StandTrigger = 450, -- passing here sets off the teleport trio, then the lightning shows him at StandS
	StandS = 690,
	StandHalfWidth = 11, -- he covers the centre gap: the plane hits him while |x| < StandHalfWidth + PlaneWidth / 2
	HangSeconds = 2, -- hitting him: a knock, then half thrust this long while he hangs on the wing
	HangThrust = 0.5,
	ReportTolerance = 0.01, -- studs and studs/s a pilot's report may differ from the authority's own step
	-- the scripted pilot of the specs, the goldens and takeoff-bot: a knock aims this far into a row's obstacles,
	-- his stand is passed this far off the centre line
	Pilot = table.freeze({ KnockOffset = 12, PassOffset = 18 }),
	Difficulty = table.freeze({
		Standard = table.freeze({ KnockLoss = 8, ChaseStart = 126, FreeAttempts = 3 } :: DifficultySpec),
		Nightmare = table.freeze({ KnockLoss = 10, ChaseStart = 118, FreeAttempts = 2 } :: DifficultySpec),
	}),
}

-- What the web needs (meta.takeoffConfig): every number and table above, as plain tables.
function TakeoffConfig.exportMeta(): { [string]: any }
	local function plain(value: any): any
		if type(value) ~= "table" then
			return value
		end
		local out = {}
		for k, v in value do
			out[k] = plain(v)
		end
		return out
	end
	local meta: { [string]: any } = {}
	for key, value in TakeoffConfig :: { [string]: any } do
		if type(value) ~= "function" then
			meta[key] = plain(value)
		end
	end
	return meta
end

return table.freeze(TakeoffConfig)
