--!strict
-- ChaseConfig: the Last Run's numbers (spec v2 §4.5) and its course, as data in clean-time coordinates. ChaseRules
-- (Shared/Rules) runs the chaser on them; the roof layout builds the course from the same points and fixtures, and
-- the web reads both through exportMeta() (meta.chaseConfig), so the rail, the world and the page share one table.
-- Values in [brackets] in comments are Nightmare's.
--
-- Clean time. A clean runner covers the centre line at RunSpeed; every corner and every slide bar costs it a further
-- 0.15 s, spread over a slow zone (a corner's is CornerHalfSpan studs either side of it, a bar's is the bar itself).
-- A point's clean-time coordinate t is the time a clean runner standing at the gate at t0 reaches it, so the gate is
-- 0, the pen is negative (14 studs behind the gate is -0.74) and the shutter is the course's cleanTime: 32.8 s from
-- the middle arrival, 39.4 s from the north or south one.
--
-- A course (the same shape ChaseRules takes as an argument):
--   points     the centre line from the housing door through the gate to the shutter: { x, z, d, t } (d: studs from
--              the gate along the line, negative in the pen)
--   knots      the piecewise-linear map between d and t: { d, t }, both strictly increasing
--   fixtures   hurdles and slide bars on the line: { id, kind ("Hurdle" | "Bar"), d0, d1, t0, t1 } (a hurdle has
--              d0 = d1)
--   wells      the leaps' fall zones: { id, d0, d1, e, exit } (e = t at d0, the well's entry; exit = t at d1, where
--              its stair's landing meets the pad)
--   cues       the lightning cues the lead runner sets off: { id, t } (25 studs before each strip, and §7's start)
--   length     the shutter's d; cleanTime the shutter's t

export type Point = { x: number, z: number, d: number, t: number }
export type Knot = { d: number, t: number }
export type Fixture = { id: string, kind: string, d0: number, d1: number, t0: number, t1: number }
export type Well = { id: string, d0: number, d1: number, e: number, exit: number }
export type Cue = { id: string, t: number }
export type Course = {
	name: string,
	points: { Point },
	knots: { Knot },
	fixtures: { Fixture },
	wells: { Well },
	cues: { Cue },
	length: number,
	cleanTime: number,
}

export type DifficultySpec = {
	StartGap: number, -- tau0: the chaser starts this far (clean seconds) behind the gate at t0
	HoldGap: number, -- tau*: the gap the rail settles at
	SlowRate: number, -- rho while the gap is at most HoldGap (clean seconds per second)
	FastRate: number, -- rho while the gap is more than HoldGap
	SpeedCap: number, -- studs/s: the chaser never moves faster (I4)
	LoomSeconds: number, -- a quarry in a well is reached for after this long
	FreeAttempts: number, -- attempts per squad that cost no respawn (§3.3)
}

local RUN_SPEED = 19
local CORNER_SECONDS = 0.15
local BAR_SECONDS = 0.15
local CORNER_HALF_SPAN = 2
local CUE_LEAD = 25 -- studs before a strip that the lead runner sets off its lightning
local DOOR_X = 386 -- the housing doors open west at x 386
local GATE_X = 342
local NORTH_Z, MIDDLE_Z, SOUTH_Z = 28, 144, 260
local MIRROR_Z = 288 -- the south spur mirrors the north one about z 144

type Segment = { x: number, z: number }
type Zone = { d0: number, d1: number, seconds: number }
type FixtureSpec = { id: string, kind: string, x0: number, z0: number, x1: number, z1: number }
type WellSpec = { id: string, x0: number, z0: number, x1: number, z1: number, stripX: number, stripZ: number }

-- The main course from the merge point M (318, 144) to the shutter, shared by all three arrivals (§4.5's table).
local MAIN: { Segment } = {
	{ x = 296, z = 144 },
	{ x = 296, z = 84 },
	{ x = 224, z = 84 },
	{ x = 224, z = 204 },
	{ x = 144, z = 204 },
	{ x = 144, z = 88 },
	{ x = 40, z = 88 },
}

local MAIN_FIXTURES: { FixtureSpec } = {
	{ id = "H1", kind = "Hurdle", x0 = 306, z0 = 144, x1 = 306, z1 = 144 },
	{ id = "B1", kind = "Bar", x0 = 296, z0 = 116, x1 = 296, z1 = 112 },
	{ id = "H2", kind = "Hurdle", x0 = 224, z0 = 112, x1 = 224, z1 = 112 },
	{ id = "B2", kind = "Bar", x0 = 224, z0 = 146, x1 = 224, z1 = 150 },
	{ id = "H3", kind = "Hurdle", x0 = 224, z0 = 182, x1 = 224, z1 = 182 },
	{ id = "H4", kind = "Hurdle", x0 = 144, z0 = 172, x1 = 144, z1 = 172 },
	{ id = "H5", kind = "Hurdle", x0 = 144, z0 = 124, x1 = 144, z1 = 124 },
	{ id = "H6", kind = "Hurdle", x0 = 104, z0 = 88, x1 = 104, z1 = 88 },
	{ id = "B3", kind = "Bar", x0 = 42, z0 = 88, x1 = 40, z1 = 88 }, -- the tower's shutter, half down
}

-- Each leap: the well from x0 to x1 along the lane; stripX/Z is where its take-off strip begins.
local WELLS: { WellSpec } = {
	{ id = "L1", x0 = 268, z0 = 84, x1 = 256, z1 = 84, stripX = 272, stripZ = 84 },
	{ id = "L2", x0 = 190, z0 = 204, x1 = 178, z1 = 204, stripX = 194, stripZ = 204 },
}

local SECTION7 = { x = 144, z = 88 } -- the lead entering §7 sets off a cue

-- Distance along the polyline (with cumulative d at each vertex) of a point on it.
local function along(points: { Point }, x: number, z: number): number
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local minX, maxX = math.min(a.x, b.x), math.max(a.x, b.x)
		local minZ, maxZ = math.min(a.z, b.z), math.max(a.z, b.z)
		if x >= minX and x <= maxX and z >= minZ and z <= maxZ then
			return a.d + math.abs(x - a.x) + math.abs(z - a.z)
		end
	end
	error(string.format("ChaseConfig: (%s, %s) is not on the course", tostring(x), tostring(z)))
end

-- t at distance d through knots (linear between them; the pen and beyond extend at the clean pace).
local function timeOf(knots: { Knot }, d: number): number
	for i = 1, #knots - 1 do
		local a, b = knots[i], knots[i + 1]
		if d <= b.d then
			return a.t + (d - a.d) * (b.t - a.t) / (b.d - a.d)
		end
	end
	local last = knots[#knots]
	return last.t + (d - last.d) / RUN_SPEED
end

local function build(name: string, spine: { Segment }, extra: { FixtureSpec }): Course
	-- the centre line: housing door, gate, then the spine (axis-aligned segments only)
	local points: { Point } = {}
	local d = 0
	for i, p in spine do
		if i == 1 then
			table.insert(points, { x = DOOR_X, z = p.z, d = -(DOOR_X - GATE_X), t = 0 })
			table.insert(points, { x = p.x, z = p.z, d = 0, t = 0 })
		else
			local prev = spine[i - 1]
			d += math.abs(p.x - prev.x) + math.abs(p.z - prev.z)
			table.insert(points, { x = p.x, z = p.z, d = d, t = 0 })
		end
	end
	local length = d

	-- slow zones: every interior vertex is a corner, every bar is its own span
	type Zone = { d0: number, d1: number, seconds: number }
	local zones: { Zone } = {}
	for i = 3, #points - 1 do
		local corner = points[i].d
		table.insert(
			zones,
			{ d0 = corner - CORNER_HALF_SPAN, d1 = corner + CORNER_HALF_SPAN, seconds = CORNER_SECONDS }
		)
	end
	local specs: { FixtureSpec } = table.clone(extra)
	for _, f in MAIN_FIXTURES do
		table.insert(specs, f)
	end
	local fixtures: { Fixture } = {}
	for _, f in specs do
		local a, b = along(points, f.x0, f.z0), along(points, f.x1, f.z1)
		table.insert(fixtures, { id = f.id, kind = f.kind, d0 = math.min(a, b), d1 = math.max(a, b), t0 = 0, t1 = 0 })
		if f.kind == "Bar" then
			table.insert(zones, { d0 = math.min(a, b), d1 = math.max(a, b), seconds = BAR_SECONDS })
		end
	end
	table.sort(zones, function(a: Zone, b: Zone): boolean
		return a.d0 < b.d0
	end)
	table.sort(fixtures, function(a: Fixture, b: Fixture): boolean
		return a.d0 < b.d0
	end)

	-- the knots: clean pace between zones, each zone slowed by its seconds
	local knots: { Knot } = { { d = points[1].d, t = points[1].d / RUN_SPEED }, { d = 0, t = 0 } }
	local t = 0
	local cursor = 0
	for _, zone in zones do
		t += (zone.d0 - cursor) / RUN_SPEED
		table.insert(knots, { d = zone.d0, t = t })
		t += (zone.d1 - zone.d0) / RUN_SPEED + zone.seconds
		table.insert(knots, { d = zone.d1, t = t })
		cursor = zone.d1
	end
	t += (length - cursor) / RUN_SPEED
	if cursor < length then
		table.insert(knots, { d = length, t = t })
	end

	for _, p in points do
		p.t = timeOf(knots, p.d)
		table.freeze(p)
	end
	for _, f in fixtures do
		f.t0, f.t1 = timeOf(knots, f.d0), timeOf(knots, f.d1)
		table.freeze(f)
	end
	local wells: { Well } = {}
	local cues: { Cue } = {}
	for _, w in WELLS do
		local d0, d1 = along(points, w.x0, w.z0), along(points, w.x1, w.z1)
		table.insert(
			wells,
			table.freeze({ id = w.id, d0 = d0, d1 = d1, e = timeOf(knots, d0), exit = timeOf(knots, d1) })
		)
		table.insert(cues, table.freeze({ id = w.id, t = timeOf(knots, along(points, w.stripX, w.stripZ) - CUE_LEAD) }))
	end
	table.insert(cues, table.freeze({ id = "Section7", t = timeOf(knots, along(points, SECTION7.x, SECTION7.z)) }))
	for _, k in knots do
		table.freeze(k)
	end
	return table.freeze({
		name = name,
		points = table.freeze(points),
		knots = table.freeze(knots),
		fixtures = table.freeze(fixtures),
		wells = table.freeze(wells),
		cues = table.freeze(cues),
		length = length,
		cleanTime = timeOf(knots, length),
	})
end

-- A spur from a side gate at z to M (318, 144), then the main course; mirror maps z for the south spur.
local function spur(gateZ: number, mirror: boolean): ({ Segment }, { FixtureSpec })
	local function z(v: number): number
		return if mirror then MIRROR_Z - v else v
	end
	local spine: { Segment } = { { x = GATE_X, z = gateZ }, { x = 318, z = gateZ }, { x = 318, z = MIDDLE_Z } }
	for _, p in MAIN do
		table.insert(spine, p)
	end
	return spine,
		{
			{ id = "H0", kind = "Hurdle", x0 = 318, z0 = z(70), x1 = 318, z1 = z(70) },
			{ id = "B0", kind = "Bar", x0 = 318, z0 = z(108), x1 = 318, z1 = z(112) },
		}
end

local middleSpine: { Segment } = { { x = GATE_X, z = MIDDLE_Z } }
for _, p in MAIN do
	table.insert(middleSpine, p)
end
local northSpine, northFixtures = spur(NORTH_Z, false)
local southSpine, southFixtures = spur(SOUTH_Z, true)

local Difficulty = table.freeze({
	Standard = table.freeze({
		StartGap = 2.6,
		HoldGap = 1.6,
		SlowRate = 0.86,
		FastRate = 1.12,
		SpeedCap = 21.3,
		LoomSeconds = 8,
		FreeAttempts = 3,
	} :: DifficultySpec),
	Nightmare = table.freeze({
		StartGap = 2.4,
		HoldGap = 1.2,
		SlowRate = 0.93,
		FastRate = 1.15,
		SpeedCap = 21.9,
		LoomSeconds = 6,
		FreeAttempts = 2,
	} :: DifficultySpec),
})

local Courses = table.freeze({
	North = build("North", northSpine, northFixtures),
	Middle = build("Middle", middleSpine, {}),
	South = build("South", southSpine, southFixtures),
})

local ChaseConfig = {
	TickRate = 30,
	RunSpeed = RUN_SPEED, -- studs/s under adrenaline (sprint latched, no stamina drain)
	CornerSeconds = CORNER_SECONDS,
	BarSeconds = BAR_SECONDS,
	CornerHalfSpan = CORNER_HALF_SPAN,
	CueLead = CUE_LEAD,
	CatchGap = 0.25, -- clean seconds (about 4.7 studs)
	CatchTicks = 3, -- consecutive ticks at or under CatchGap
	LoomLip = 0.3, -- the chaser stands this far (clean seconds) behind a well's entry while its quarry is in it
	CatchHoldSeconds = 3.0, -- after a catch the chaser holds, then takes the next quarry
	SlamDelaySeconds = 0.5, -- the shutter slams this long after the last active runner is through or caught
	MaxRewindTicks = 12, -- lag compensation rewinds the rail at most 0.4 s
	Hysteresis = 1.5, -- studs: the next segment wins a runner's projection unless it is this much farther
	WellDepth = 2, -- studs below the deck: a runner deeper than this is in a well
	WellFloor = -10, -- the wells' floor (10 deep), where a scripted faller stands
	Difficulty = Difficulty,
	Courses = Courses,
}

-- What the web needs (meta.chaseConfig): every number above and the three courses, as plain tables.
function ChaseConfig.exportMeta(): { [string]: any }
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
	for key, value in ChaseConfig :: { [string]: any } do
		if type(value) ~= "function" then
			meta[key] = plain(value)
		end
	end
	return meta
end

return table.freeze(ChaseConfig)
