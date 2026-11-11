--!strict
-- EndingRules: the bell tower's standoff (spec v2 §4.6), pure. The authority (the Roblox server, the web host) judges
-- every shot with judgeShot and moves the monster with approach; the holder's page gates its own fire button with
-- canFire. The website's port is web/src/game/rules/ending.js (I11). Times are seconds from T_s.
--
--   the window     fire opens at FireOpens and closes at contact, ContactAt: 13.5 s; Nightmare moves every event
--                  after FireOpens to FireOpens + (t - FireOpens) x NightmareScale (10.0 s) and cuts NightmareCuts
--   the hit test   the camera's centre ray at the fire tick, RayLength long, no sway, against the Biped hitbox grown
--                  by the input's margin. The world in front of the box (or anywhere along a ray that misses it)
--                  blocks the shot: it does not fire and keeps the round. Teammates never block (the caller leaves
--                  them out of its raycast). It never reads a tier, a frame rate or a render (I5)
--   the authority  accepts a shot armed and inside the window, arriving within LateGrace of its end, from within
--                  OriginTolerance of the holder's head and within 25 degrees of a look relayed within LookWindow of
--                  it; anything else is Late or Rejected. Only a Hit or a clear Miss uses the round
--   the approach   each walk to its stop at the remaining distance / the remaining time, clamped to WalkMin..WalkMax,
--                  holding when already nearer; still beyond ContactDistance at ContactAt, it lunges; at CutAt a
--                  lightning cut puts it on the holder. A lowered gun brings it in at LoweredSpeed, a miss at
--                  MissedSpeed. Contact is Ending B (in the timeline, not before ContactAt); a Hit is Ending A
--
-- API (pure; plain JSON-serialisable values):
--   EndingRules.at(difficulty, t)                 a Standard timeline time on this difficulty
--   EndingRules.fireWindow(difficulty)            { opens, closes, seconds }
--   EndingRules.timeline(difficulty)              the scripted events in order: { at, kind, id?, length?, to?, stop? }
--   EndingRules.standoffStart({ arrived, taken?, allUp?, slammed })   T_s on the run's clock
--   EndingRules.fadeInSpot(x, z)                  the spot farthest from the holder (or the players' centre)
--   EndingRules.walkSpeed(remaining, timeLeft) / approach(difficulty, mode, t, distance, dt)
--   EndingRules.hitTest(ray, box, device, blockedAt?)       "Hit" | "Miss" | "Blocked"
--   EndingRules.rewind(oneWay, renderDelay)       how far back the monster's pose is read
--   EndingRules.judgeShot(difficulty, shot)       { verdict, usesRound }
--   EndingRules.canFire(difficulty, t, holder) / gunButton(held, released) / takeReady(held, fromLowered)
--   EndingRules.idleDrop(idle) / pickUpLineDue(t, held)
--   EndingRules.new(difficulty, distance) / step(state, input, dt) -> { state, events } / replay(trace)
--   EndingRules.golden()                          rows { name, fn, args, expect }

local EndingConfig = require(script.Parent.Parent.Config.EndingConfig)

export type Vec = { x: number, y: number, z: number }
export type Ray = { origin: Vec, dir: Vec }
export type Box = { x: number, y: number, z: number, fx: number, fz: number } -- centre and horizontal facing
export type Look = { t: number, x: number, y: number, z: number }
export type Shot = {
	clientTime: number,
	arrival: number,
	origin: Vec,
	head: Vec,
	dir: Vec,
	looks: { Look },
	device: string,
	box: Box,
	blockedAt: number?,
	takenAt: number?,
}
export type Verdict = { verdict: string, usesRound: boolean }
export type Holder = { takenAt: number, lowered: boolean, heldAtOpen: boolean }
export type Row = { at: number, kind: string, id: string?, length: number?, to: number?, stop: number? }
export type Window = { opens: number, closes: number, seconds: number }
export type Times = { arrived: number, taken: number?, allUp: number?, slammed: number }

export type State = {
	difficulty: string,
	t: number,
	distance: number,
	mode: string, -- "Timeline", "Lowered" or "Missed"
	round: boolean,
	next: number, -- the next timeline row to announce
	ending: string?, -- "A" or "B"
}
export type Input = { distance: number?, shot: string?, lowered: boolean? }
export type Event = { t: number, kind: string, id: string? }
export type Step = { state: State, events: { Event } }
export type Trace = { difficulty: string, distance: number, ticks: { Input } }

local EPS = 1e-9

local EndingRules = {}

local function nightmare(difficulty: string): boolean
	if difficulty == "Nightmare" then
		return true
	elseif difficulty == "Standard" then
		return false
	end
	error("EndingRules: unknown difficulty " .. tostring(difficulty), 3)
end

function EndingRules.at(difficulty: string, t: number): number
	if not nightmare(difficulty) or t <= EndingConfig.FireOpens then
		return t
	end
	return EndingConfig.FireOpens + (t - EndingConfig.FireOpens) * EndingConfig.NightmareScale
end

function EndingRules.fireWindow(difficulty: string): Window
	local closes = EndingRules.at(difficulty, EndingConfig.ContactAt)
	return { opens = EndingConfig.FireOpens, closes = closes, seconds = closes - EndingConfig.FireOpens }
end

function EndingRules.timeline(difficulty: string): { Row }
	local cut = nightmare(difficulty)
	local function at(t: number): number
		return EndingRules.at(difficulty, t)
	end
	local lines: { [string]: EndingConfig.Line } = {}
	for _, line in EndingConfig.Lines do
		lines[line.id] = line
	end
	local rows: { Row } = {}
	local function line(id: string)
		if cut and table.find(EndingConfig.NightmareCuts, id) ~= nil then
			return
		end
		table.insert(rows, { at = at(lines[id].at), kind = "Line", id = id, length = lines[id].length })
	end
	local function walk(i: number)
		local w = EndingConfig.Walks[i]
		table.insert(rows, { at = at(w.from), kind = "Walk", to = at(w.to), stop = w.stop })
	end
	table.insert(rows, { at = EndingConfig.WarningAt, kind = "Warning" })
	table.insert(rows, { at = EndingConfig.FadeInAt, kind = "FadeIn", length = EndingConfig.FadeInSeconds })
	table.insert(rows, { at = EndingConfig.StareAt, kind = "Stare" })
	line("Name")
	table.insert(rows, { at = EndingConfig.FireOpens, kind = "Fire" })
	walk(1)
	line("Plea")
	walk(2)
	line("YouHid")
	line("DoIt")
	walk(3)
	table.insert(rows, { at = at(EndingConfig.ContactAt), kind = "Contact" })
	table.insert(rows, { at = at(EndingConfig.CutAt), kind = "Cut" })
	return rows
end

-- T_s on the run's clock: max(first belfry arrival + ArrivalDelay, revolver taken + TakenDelay), and not before every
-- active runner is up (allUp, nil while someone is still on the stair) or StragglerWait after the shutter slammed.
function EndingRules.standoffStart(times: Times): number
	local start = times.arrived + EndingConfig.ArrivalDelay
	local taken, allUp = times.taken, times.allUp
	if taken ~= nil then
		start = math.max(start, taken + EndingConfig.TakenDelay)
	end
	local gather = times.slammed + EndingConfig.StragglerWait
	if allUp ~= nil then
		gather = math.min(gather, allUp)
	end
	return math.max(start, gather)
end

-- The fade-in spot farthest from (x, z), the first in EndingConfig.Spots' order on a tie.
function EndingRules.fadeInSpot(x: number, z: number): string
	local best, bestSq = "", -1
	for _, spot in EndingConfig.Spots do
		local dx, dz = spot.x - x, spot.z - z
		local sq = dx * dx + dz * dz
		if sq > bestSq + EPS then
			best, bestSq = spot.id, sq
		end
	end
	return best
end

-- A walk's speed: the remaining distance / the remaining time, clamped to WalkMin..WalkMax; 0 once there.
function EndingRules.walkSpeed(remaining: number, timeLeft: number): number
	if remaining <= EPS then
		return 0
	elseif timeLeft <= EPS then
		return EndingConfig.WalkMax
	end
	return math.clamp(remaining / timeLeft, EndingConfig.WalkMin, EndingConfig.WalkMax)
end

-- The monster's distance to the holder after a tick of dt that starts at t: mode "Timeline" (the walks, the lunge),
-- "Lowered" or "Missed". It never closes past a walk's stop or ContactDistance.
function EndingRules.approach(difficulty: string, mode: string, t: number, distance: number, dt: number): number
	local floor = EndingConfig.ContactDistance
	if distance <= floor + EPS then
		return distance
	end
	local speed = 0
	if mode == "Lowered" then
		speed = EndingConfig.LoweredSpeed
	elseif mode == "Missed" then
		speed = EndingConfig.MissedSpeed
	elseif t >= EndingRules.at(difficulty, EndingConfig.ContactAt) - EPS then
		speed = EndingConfig.LungeSpeed
	else
		for _, w in EndingConfig.Walks do
			local from, to = EndingRules.at(difficulty, w.from), EndingRules.at(difficulty, w.to)
			if t >= from - EPS and t < to - EPS then
				floor = w.stop
				speed = EndingRules.walkSpeed(distance - w.stop, to - t)
				break
			end
		end
	end
	return math.max(math.min(distance, floor), distance - speed * dt)
end

local function length(v: Vec): number
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

-- The camera's centre ray against the hitbox grown by the device's margin. blockedAt is the distance of the first
-- world hit along the ray (nil when there is none within RayLength).
function EndingRules.hitTest(ray: Ray, box: Box, device: string, blockedAt: number?): string
	local margin = (EndingConfig.Margins :: any)[device]
	if margin == nil then
		error("EndingRules: unknown input device " .. tostring(device), 2)
	end
	local n = length(ray.dir)
	local dx, dy, dz = ray.dir.x / n, ray.dir.y / n, ray.dir.z / n
	local ox, oy, oz = ray.origin.x - box.x, ray.origin.y - box.y, ray.origin.z - box.z
	-- the box's frame: right = (fz, -fx), up, forward = (fx, fz)
	local origin = { ox * box.fz - oz * box.fx, oy, ox * box.fx + oz * box.fz }
	local dir = { dx * box.fz - dz * box.fx, dy, dx * box.fx + dz * box.fz }
	local half = {
		EndingConfig.Hitbox.x / 2 + margin,
		EndingConfig.Hitbox.y / 2 + margin,
		EndingConfig.Hitbox.z / 2 + margin,
	}
	local near, far = 0, EndingConfig.RayLength
	local inside = true
	for axis = 1, 3 do
		local o, d, h = origin[axis], dir[axis], half[axis]
		if math.abs(d) < EPS then
			if math.abs(o) > h then
				inside = false
				break
			end
		else
			local t1, t2 = (-h - o) / d, (h - o) / d
			near = math.max(near, math.min(t1, t2))
			far = math.min(far, math.max(t1, t2))
			if near > far then
				inside = false
				break
			end
		end
	end
	local blocked = blockedAt ~= nil and blockedAt <= EndingConfig.RayLength
	if inside and not (blocked and (blockedAt :: number) <= near) then
		return "Hit"
	end
	return if blocked then "Blocked" else "Miss"
end

-- How far back the authority reads the monster's pose for a shot.
function EndingRules.rewind(oneWay: number, renderDelay: number): number
	return math.clamp(oneWay + renderDelay, 0, EndingConfig.MaxRewind)
end

-- The moment a holder who took the revolver at takenAt may fire: FireOpens, or ArmSeconds after a take during the
-- standoff.
local function armedAt(takenAt: number?): number
	if takenAt ~= nil and takenAt >= 0 then
		return math.max(EndingConfig.FireOpens, takenAt + EndingConfig.ArmSeconds)
	end
	return EndingConfig.FireOpens
end

-- The authority's verdict on a shot: "Rejected" (not armed, from too far from the head, or matching no look), "Late",
-- or the hit test's "Hit", "Miss" or "Blocked". Only a Hit or a Miss uses the round.
function EndingRules.judgeShot(difficulty: string, shot: Shot): Verdict
	local window = EndingRules.fireWindow(difficulty)
	local late = shot.clientTime > window.closes + EPS or shot.arrival > window.closes + EndingConfig.LateGrace + EPS
	local armed = shot.clientTime >= armedAt(shot.takenAt) - EPS
	local offset = { x = shot.origin.x - shot.head.x, y = shot.origin.y - shot.head.y, z = shot.origin.z - shot.head.z }
	local fromHead = length(offset) <= EndingConfig.OriginTolerance + EPS
	local n = length(shot.dir)
	local looked = false
	for _, look in shot.looks do
		local m = length(look :: any)
		local dot = shot.dir.x * look.x + shot.dir.y * look.y + shot.dir.z * look.z
		if math.abs(look.t - shot.clientTime) <= EndingConfig.LookWindow + EPS and m > 0 then
			looked = looked or dot >= EndingConfig.LookCos * n * m
		end
	end
	local verdict = if late
		then "Late"
		elseif not (armed and fromHead and looked) then "Rejected"
		else EndingRules.hitTest({ origin = shot.origin, dir = shot.dir }, shot.box, shot.device, shot.blockedAt)
	return { verdict = verdict, usesRound = verdict == "Hit" or verdict == "Miss" }
end

-- May the holder's fire button fire at t? Armed, inside the window, not lowered, and not a button already held when
-- fire opened.
function EndingRules.canFire(difficulty: string, t: number, holder: Holder): boolean
	return t >= armedAt(holder.takenAt) - EPS
		and t <= EndingRules.fireWindow(difficulty).closes + EPS
		and not holder.lowered
		and not holder.heldAtOpen
end

-- The Lower / Drop button: held LowerSeconds lowers the gun; released under DropTapSeconds drops it (to pass it on).
function EndingRules.gunButton(held: number, released: boolean): string
	if released then
		return if held < EndingConfig.DropTapSeconds then "Drop" else "None"
	end
	return if held >= EndingConfig.LowerSeconds - EPS then "Lower" else "None"
end

-- Has a take held long enough? From a lowered holder TakeLoweredSeconds, off the floor or the lockbox TakeSeconds.
function EndingRules.takeReady(held: number, fromLowered: boolean): boolean
	return held >= (if fromLowered then EndingConfig.TakeLoweredSeconds else EndingConfig.TakeSeconds) - EPS
end

-- An idle holder (no look, move or aim input this long during the standoff) drops the gun at their feet.
function EndingRules.idleDrop(idle: number): boolean
	return idle >= EndingConfig.IdleSeconds - EPS
end

-- "Go on. Pick it up, {name}.": due once nobody holds the revolver at PickUpLineAt.
function EndingRules.pickUpLineDue(t: number, held: boolean): boolean
	return not held and t >= EndingConfig.PickUpLineAt - EPS
end

-- The standoff from T_s with the monster distance away from the holder (after its fade-in).
function EndingRules.new(difficulty: string, distance: number): State
	nightmare(difficulty)
	local rows = EndingRules.timeline(difficulty)
	local first = 1
	while rows[first].at < 0 do
		first += 1
	end
	return { difficulty = difficulty, t = 0, distance = distance, mode = "Timeline", round = true, next = first }
end

local ANNOUNCED = { FadeIn = true, Stare = true, Line = true, Fire = true }

-- One tick: input.distance is the measured distance before the monster moves (the holder moves too), input.shot an
-- accepted shot's verdict ("Hit" or "Miss"), input.lowered the holder lowering the gun.
function EndingRules.step(state: State, input: Input, dt: number): Step
	local s = table.clone(state)
	local events: { Event } = {}
	if s.ending ~= nil then
		return { state = s, events = events }
	end
	local start = s.t
	s.t += dt
	local rows = EndingRules.timeline(s.difficulty)
	while s.next <= #rows and rows[s.next].at <= start + EPS do
		local row = rows[s.next]
		s.next += 1
		if ANNOUNCED[row.kind] then
			table.insert(events, { t = row.at, kind = row.kind, id = row.id })
		end
	end
	local distance = input.distance
	if distance ~= nil then
		s.distance = distance
	end
	if input.shot ~= nil and s.round then
		s.round = false
		if input.shot == "Hit" then
			s.ending = "A"
			table.insert(events, { t = start, kind = "EndingA" })
			return { state = s, events = events }
		end
		s.mode = "Missed"
		table.insert(events, { t = start, kind = "Missed" })
	end
	if input.lowered and s.mode == "Timeline" then
		s.mode = "Lowered"
		table.insert(events, { t = start, kind = "Lowered" })
	end
	s.distance = EndingRules.approach(s.difficulty, s.mode, start, s.distance, dt)
	local cut = s.t >= EndingRules.at(s.difficulty, EndingConfig.CutAt) - EPS
	if cut and s.distance > EndingConfig.ContactDistance + EPS then
		s.distance = EndingConfig.ContactDistance
		table.insert(events, { t = s.t, kind = "Cut" })
	end
	local close = s.distance <= EndingConfig.ContactDistance + EPS
	local due = s.mode ~= "Timeline" or s.t >= EndingRules.at(s.difficulty, EndingConfig.ContactAt) - EPS
	if close and due then
		s.ending = "B"
		table.insert(events, { t = s.t, kind = "EndingB" })
	end
	return { state = s, events = events }
end

-- A whole standoff from per-tick inputs on the 30 Hz tick, until an ending (or the trace runs out). Event times are
-- rounded to 0.001 s.
function EndingRules.replay(trace: Trace): { Event }
	local state = EndingRules.new(trace.difficulty, trace.distance)
	local log: { Event } = {}
	for _, input in trace.ticks do
		local result = EndingRules.step(state, input, 1 / EndingConfig.TickRate)
		state = result.state
		for _, e in result.events do
			table.insert(log, { t = math.floor(e.t * 1000 + 0.5) / 1000, kind = e.kind, id = e.id })
		end
		if state.ending ~= nil then
			break
		end
	end
	return log
end

export type GoldenRow = { name: string, fn: string, args: { any }, expect: any }

-- The golden rows (the export writes them for the web's port): what each function returns for its args, pinned in
-- EXPECT below. A function returns one value; numbers compare to 1e-9.
local EXPECT: { [string]: any } = {
	["Standard: the fire window"] = {
		closes = 15.5,
		opens = 2,
		seconds = 13.5,
	},
	["Standard: the timeline"] = {
		{
			at = -1.6,
			kind = "Warning",
		} :: any,
		{
			at = 0,
			kind = "FadeIn",
			length = 0.8,
		},
		{
			at = 0.8,
			kind = "Stare",
		},
		{
			at = 1,
			id = "Name",
			kind = "Line",
			length = 1,
		},
		{
			at = 2,
			kind = "Fire",
		},
		{
			at = 2,
			kind = "Walk",
			stop = 20,
			to = 5.5,
		},
		{
			at = 5.6,
			id = "Plea",
			kind = "Line",
			length = 3.2,
		},
		{
			at = 8.8,
			kind = "Walk",
			stop = 13,
			to = 10.5,
		},
		{
			at = 10.6,
			id = "YouHid",
			kind = "Line",
			length = 2.4,
		},
		{
			at = 13.2,
			id = "DoIt",
			kind = "Line",
			length = 1,
		},
		{
			at = 13.4,
			kind = "Walk",
			stop = 4,
			to = 15.5,
		},
		{
			at = 15.5,
			kind = "Contact",
		},
		{
			at = 17,
			kind = "Cut",
		},
	},
	["Standard: the standoff from 20, nobody shoots"] = {
		difficulty = "Standard",
		distance = 20,
		mode = "Timeline",
		next = 2,
		round = true,
		t = 0,
	},
	["Nightmare: the fire window"] = {
		closes = 12,
		opens = 2,
		seconds = 10,
	},
	["Nightmare: the timeline"] = {
		{
			at = -1.6,
			kind = "Warning",
		} :: any,
		{
			at = 0,
			kind = "FadeIn",
			length = 0.8,
		},
		{
			at = 0.8,
			kind = "Stare",
		},
		{
			at = 1,
			id = "Name",
			kind = "Line",
			length = 1,
		},
		{
			at = 2,
			kind = "Fire",
		},
		{
			at = 2,
			kind = "Walk",
			stop = 20,
			to = 4.592592592592593,
		},
		{
			at = 4.666666666666666,
			id = "Plea",
			kind = "Line",
			length = 3.2,
		},
		{
			at = 7.037037037037037,
			kind = "Walk",
			stop = 13,
			to = 8.296296296296296,
		},
		{
			at = 10.296296296296296,
			id = "DoIt",
			kind = "Line",
			length = 1,
		},
		{
			at = 10.444444444444445,
			kind = "Walk",
			stop = 4,
			to = 12,
		},
		{
			at = 12,
			kind = "Contact",
		},
		{
			at = 13.11111111111111,
			kind = "Cut",
		},
	},
	["Nightmare: the standoff from 20, nobody shoots"] = {
		difficulty = "Nightmare",
		distance = 20,
		mode = "Timeline",
		next = 2,
		round = true,
		t = 0,
	},
	["at: Standard is the timeline"] = 15.5,
	["at: Nightmare before fire opens"] = 1,
	["at: Nightmare's contact"] = 12,
	["at: Nightmare's cut"] = 13.11111111111111,
	["standoffStart: nobody has taken it, someone on the stair"] = 115,
	["standoffStart: the revolver taken late"] = 115,
	["standoffStart: everyone up early"] = 112,
	["standoffStart: a straggler on the stair"] = 119,
	["fadeInSpot: the centre ties, E first"] = "E",
	["fadeInSpot: the south-west corner"] = "E",
	["fadeInSpot: the north-east corner ties N and W, N first"] = "N",
	["fadeInSpot: by the west spot"] = "E",
	["walkSpeed: already there"] = 0,
	["walkSpeed: no time left"] = 9,
	["walkSpeed: clamped up to 2"] = 2,
	["walkSpeed: clamped down to 9"] = 9,
	["walkSpeed: on schedule"] = 3.5,
	["approach: still before the first walk"] = 25,
	["approach: the first walk at 2"] = 24.933333333333334,
	["approach: a walk never passes its stop"] = 20,
	["approach: a holder nearer than the stop is held"] = 15,
	["approach: between walks it stands"] = 12,
	["approach: the second walk at 9"] = 29.7,
	["approach: Nightmare's last walk"] = 12.8,
	["approach: the lunge at 15.5"] = 9.6,
	["approach: lowered, it walks in at 6"] = 9.8,
	["approach: missed, it closes at 9"] = 9.7,
	["approach: at contact distance it stops"] = 4,
	["hitTest: at the chest"] = "Hit",
	["hitTest: 2.2 wide misses with a mouse"] = "Miss",
	["hitTest: 2.2 wide hits with a gamepad"] = "Hit",
	["hitTest: 2.8 wide misses with a gamepad"] = "Miss",
	["hitTest: 2.8 wide hits on touch"] = "Hit",
	["hitTest: the world in front blocks"] = "Blocked",
	["hitTest: the world behind him does not"] = "Hit",
	["hitTest: a miss into the world is blocked"] = "Blocked",
	["hitTest: a miss into the sky"] = "Miss",
	["hitTest: 1.93 wide of him facing south misses"] = "Miss",
	["hitTest: 1.93 wide of him facing east hits"] = "Hit",
	["hitTest: from inside the box"] = "Hit",
	["hitTest: straight down beside him"] = "Miss",
	["hitTest: straight down onto him"] = "Hit",
	["hitTest: beyond the ray's 60"] = "Miss",
	["hitTest: an angled shot"] = "Hit",
	["rewind: latency plus render delay"] = 0.2,
	["rewind: at most 0.5"] = 0.5,
	["rewind: never forward"] = 0,
	["judgeShot: a hit"] = {
		usesRound = true,
		verdict = "Hit",
	},
	["judgeShot: a clear miss uses the round"] = {
		usesRound = true,
		verdict = "Miss",
	},
	["judgeShot: blocked keeps the round"] = {
		usesRound = false,
		verdict = "Blocked",
	},
	["judgeShot: fired after the window"] = {
		usesRound = false,
		verdict = "Late",
	},
	["judgeShot: arrived after the grace"] = {
		usesRound = false,
		verdict = "Late",
	},
	["judgeShot: the last moment at 200 ms"] = {
		usesRound = true,
		verdict = "Hit",
	},
	["judgeShot: Nightmare's window has closed"] = {
		usesRound = false,
		verdict = "Late",
	},
	["judgeShot: Nightmare's last moment"] = {
		usesRound = true,
		verdict = "Hit",
	},
	["judgeShot: before fire opens"] = {
		usesRound = false,
		verdict = "Rejected",
	},
	["judgeShot: picked up at 6, not yet armed"] = {
		usesRound = false,
		verdict = "Rejected",
	},
	["judgeShot: picked up at 6, armed"] = {
		usesRound = true,
		verdict = "Hit",
	},
	["judgeShot: from too far from the head"] = {
		usesRound = false,
		verdict = "Rejected",
	},
	["judgeShot: 30 degrees off every look"] = {
		usesRound = false,
		verdict = "Rejected",
	},
	["judgeShot: no look within 0.15 s"] = {
		usesRound = false,
		verdict = "Rejected",
	},
	["judgeShot: a flick"] = {
		usesRound = true,
		verdict = "Hit",
	},
	["canFire: before fire opens"] = false,
	["canFire: in the window"] = true,
	["canFire: picked up at 6, at 6.5"] = false,
	["canFire: picked up at 6, at 6.6"] = true,
	["canFire: lowered"] = false,
	["canFire: a button held when fire opened"] = false,
	["canFire: after Standard's contact"] = false,
	["canFire: after Nightmare's contact"] = false,
	["canFire: Nightmare at 11.9"] = true,
	["gunButton: held 1.5 lowers"] = "Lower",
	["gunButton: still holding"] = "None",
	["gunButton: a tap drops"] = "Drop",
	["gunButton: released too late to drop"] = "None",
	["takeReady: from a lowered holder at 1.2"] = true,
	["takeReady: from a lowered holder at 1.0"] = false,
	["takeReady: off the floor at 0.6"] = true,
	["takeReady: off the floor at 0.5"] = false,
	["idleDrop: 4 s idle"] = true,
	["idleDrop: 3.9 s idle"] = false,
	["pickUpLineDue: nobody holds it at 4"] = true,
	["pickUpLineDue: nobody holds it at 3.9"] = false,
	["pickUpLineDue: someone holds it"] = false,
	["step: the first tick announces the fade-in"] = {
		events = {
			{
				kind = "FadeIn",
				t = 0,
			},
		},
		state = {
			difficulty = "Standard",
			distance = 20,
			mode = "Timeline",
			next = 3,
			round = true,
			t = 0.03333333333333333,
		},
	},
	["step: a hit is Ending A"] = {
		events = {
			{
				kind = "FadeIn",
				t = 0,
			} :: any,
			{
				kind = "EndingA",
				t = 0,
			},
		},
		state = {
			difficulty = "Standard",
			distance = 20,
			ending = "A",
			mode = "Timeline",
			next = 3,
			round = false,
			t = 0.03333333333333333,
		},
	},
	["step: a clear miss"] = {
		events = {
			{
				kind = "FadeIn",
				t = 0,
			} :: any,
			{
				kind = "Missed",
				t = 0,
			},
		},
		state = {
			difficulty = "Standard",
			distance = 19.7,
			mode = "Missed",
			next = 3,
			round = false,
			t = 0.03333333333333333,
		},
	},
	["step: lowered"] = {
		events = {
			{
				kind = "FadeIn",
				t = 0,
			} :: any,
			{
				kind = "Lowered",
				t = 0,
			},
		},
		state = {
			difficulty = "Standard",
			distance = 19.8,
			mode = "Lowered",
			next = 3,
			round = true,
			t = 0.03333333333333333,
		},
	},
	["step: the holder's measured distance"] = {
		events = {
			{
				kind = "FadeIn",
				t = 0,
			},
		},
		state = {
			difficulty = "Standard",
			distance = 12,
			mode = "Timeline",
			next = 3,
			round = true,
			t = 0.03333333333333333,
		},
	},
	["step: contact at 15.5"] = {
		events = {
			{
				kind = "EndingB",
				t = 15.5,
			},
		},
		state = {
			difficulty = "Standard",
			distance = 4,
			ending = "B",
			mode = "Timeline",
			next = 12,
			round = true,
			t = 15.5,
		},
	},
	["step: no second round after a miss"] = {
		events = {},
		state = {
			difficulty = "Standard",
			distance = 19.7,
			mode = "Missed",
			next = 7,
			round = false,
			t = 4.033333333333333,
		},
	},
	["step: an ending is final"] = {
		events = {},
		state = {
			difficulty = "Standard",
			distance = 20,
			ending = "A",
			mode = "Timeline",
			next = 2,
			round = true,
			t = 0,
		},
	},
	["step: the lightning cut at 17"] = {
		events = {
			{
				kind = "Cut",
				t = 17,
			} :: any,
			{
				kind = "EndingB",
				t = 17,
			},
		},
		state = {
			difficulty = "Standard",
			distance = 4,
			ending = "B",
			mode = "Timeline",
			next = 13,
			round = true,
			t = 17,
		},
	},
	["replay: Standard, nobody shoots"] = {
		{
			kind = "FadeIn",
			t = 0,
		} :: any,
		{
			kind = "Stare",
			t = 0.8,
		},
		{
			id = "Name",
			kind = "Line",
			t = 1,
		},
		{
			kind = "Fire",
			t = 2,
		},
		{
			id = "Plea",
			kind = "Line",
			t = 5.6,
		},
		{
			id = "YouHid",
			kind = "Line",
			t = 10.6,
		},
		{
			id = "DoIt",
			kind = "Line",
			t = 13.2,
		},
		{
			kind = "EndingB",
			t = 15.5,
		},
	},
	["replay: Nightmare, nobody shoots"] = {
		{
			kind = "FadeIn",
			t = 0,
		} :: any,
		{
			kind = "Stare",
			t = 0.8,
		},
		{
			id = "Name",
			kind = "Line",
			t = 1,
		},
		{
			kind = "Fire",
			t = 2,
		},
		{
			id = "Plea",
			kind = "Line",
			t = 4.667,
		},
		{
			id = "DoIt",
			kind = "Line",
			t = 10.296,
		},
		{
			kind = "EndingB",
			t = 12,
		},
	},
	["replay: Standard, a hit at 5"] = {
		{
			kind = "FadeIn",
			t = 0,
		} :: any,
		{
			kind = "Stare",
			t = 0.8,
		},
		{
			id = "Name",
			kind = "Line",
			t = 1,
		},
		{
			kind = "Fire",
			t = 2,
		},
		{
			kind = "EndingA",
			t = 4.967,
		},
	},
	["replay: Nightmare, a hit at the last moment"] = {
		{
			kind = "FadeIn",
			t = 0,
		} :: any,
		{
			kind = "Stare",
			t = 0.8,
		},
		{
			id = "Name",
			kind = "Line",
			t = 1,
		},
		{
			kind = "Fire",
			t = 2,
		},
		{
			id = "Plea",
			kind = "Line",
			t = 4.667,
		},
		{
			id = "DoIt",
			kind = "Line",
			t = 10.296,
		},
		{
			kind = "EndingA",
			t = 11.867,
		},
	},
	["replay: Standard, lowered at 6"] = {
		{
			kind = "FadeIn",
			t = 0,
		} :: any,
		{
			kind = "Stare",
			t = 0.8,
		},
		{
			id = "Name",
			kind = "Line",
			t = 1,
		},
		{
			kind = "Fire",
			t = 2,
		},
		{
			id = "Plea",
			kind = "Line",
			t = 5.6,
		},
		{
			kind = "Lowered",
			t = 5.967,
		},
		{
			kind = "EndingB",
			t = 8.633,
		},
	},
	["replay: Standard, a clear miss at 4"] = {
		{
			kind = "FadeIn",
			t = 0,
		} :: any,
		{
			kind = "Stare",
			t = 0.8,
		},
		{
			id = "Name",
			kind = "Line",
			t = 1,
		},
		{
			kind = "Fire",
			t = 2,
		},
		{
			kind = "Missed",
			t = 3.967,
		},
		{
			id = "Plea",
			kind = "Line",
			t = 5.6,
		},
		{
			kind = "EndingB",
			t = 5.867,
		},
	},
	["replay: Standard, the holder walks into it at 8"] = {
		{
			kind = "FadeIn",
			t = 0,
		} :: any,
		{
			kind = "Stare",
			t = 0.8,
		},
		{
			id = "Name",
			kind = "Line",
			t = 1,
		},
		{
			kind = "Fire",
			t = 2,
		},
		{
			id = "Plea",
			kind = "Line",
			t = 5.6,
		},
		{
			id = "YouHid",
			kind = "Line",
			t = 10.6,
		},
		{
			id = "DoIt",
			kind = "Line",
			t = 13.2,
		},
		{
			kind = "EndingB",
			t = 15.5,
		},
	},
	["replay: Standard, the holder backs away"] = {
		{
			kind = "FadeIn",
			t = 0,
		} :: any,
		{
			kind = "Stare",
			t = 0.8,
		},
		{
			id = "Name",
			kind = "Line",
			t = 1,
		},
		{
			kind = "Fire",
			t = 2,
		},
		{
			id = "Plea",
			kind = "Line",
			t = 5.6,
		},
		{
			id = "YouHid",
			kind = "Line",
			t = 10.6,
		},
		{
			id = "DoIt",
			kind = "Line",
			t = 13.2,
		},
		{
			kind = "Cut",
			t = 17,
		},
		{
			kind = "EndingB",
			t = 17,
		},
	},
}

function EndingRules.golden(): { GoldenRow }
	local rows: { GoldenRow } = {}
	local function row(name: string, fn: string, args: { any })
		table.insert(rows, { name = name, fn = fn, args = args, expect = EXPECT[name] })
	end
	local dt = 1 / EndingConfig.TickRate
	local box: Box = { x = 22, y = 5.5, z = 75, fx = 0, fz = 1 }
	local turned: Box = { x = 22, y = 5.5, z = 75, fx = 1, fz = 0 }
	local function ray(dx: number, ox: number?, oy: number?, oz: number?): Ray
		return { origin = { x = 22 + (ox or 0), y = oy or 5, z = oz or 95 }, dir = { x = dx, y = 0, z = -1 } }
	end
	local function shot(overrides: { [string]: any }): Shot
		local s: { [string]: any } = {
			clientTime = 5,
			arrival = 5.1,
			origin = { x = 22, y = 5, z = 95 },
			head = { x = 22, y = 5, z = 95 },
			dir = { x = 0, y = 0, z = -1 },
			looks = { { t = 4.95, x = 0, y = 0, z = -1 } },
			device = "Mouse",
			box = box,
			takenAt = -3,
		}
		for k, v in overrides do
			s[k] = v
		end
		return (s :: any) :: Shot
	end
	local function ticks(n: number, at: { [number]: Input }): { Input }
		local out: { Input } = {}
		for i = 1, n do
			out[i] = at[i] or {}
		end
		return out
	end

	for _, d in { "Standard", "Nightmare" } do
		row(d .. ": the fire window", "fireWindow", { d })
		row(d .. ": the timeline", "timeline", { d })
		row(d .. ": the standoff from 20, nobody shoots", "new", { d, 20 })
	end
	row("at: Standard is the timeline", "at", { "Standard", 15.5 })
	row("at: Nightmare before fire opens", "at", { "Nightmare", 1.0 })
	row("at: Nightmare's contact", "at", { "Nightmare", 15.5 })
	row("at: Nightmare's cut", "at", { "Nightmare", 17.0 })

	row(
		"standoffStart: nobody has taken it, someone on the stair",
		"standoffStart",
		{ { arrived = 100, slammed = 95 } }
	)
	row(
		"standoffStart: the revolver taken late",
		"standoffStart",
		{ { arrived = 100, taken = 110, allUp = 104, slammed = 95 } }
	)
	row(
		"standoffStart: everyone up early",
		"standoffStart",
		{ { arrived = 100, taken = 101, allUp = 103, slammed = 95 } }
	)
	row("standoffStart: a straggler on the stair", "standoffStart", { { arrived = 100, taken = 101, slammed = 99 } })

	row("fadeInSpot: the centre ties, E first", "fadeInSpot", { 22, 88 })
	row("fadeInSpot: the south-west corner", "fadeInSpot", { 5, 72 })
	row("fadeInSpot: the north-east corner ties N and W, N first", "fadeInSpot", { 38, 104 })
	row("fadeInSpot: by the west spot", "fadeInSpot", { 10, 88 })

	row("walkSpeed: already there", "walkSpeed", { -1, 2 })
	row("walkSpeed: no time left", "walkSpeed", { 5, 0 })
	row("walkSpeed: clamped up to 2", "walkSpeed", { 1, 2 })
	row("walkSpeed: clamped down to 9", "walkSpeed", { 30, 2 })
	row("walkSpeed: on schedule", "walkSpeed", { 7, 2 })

	row("approach: still before the first walk", "approach", { "Standard", "Timeline", 1.0, 25, dt })
	row("approach: the first walk at 2", "approach", { "Standard", "Timeline", 2.0, 25, dt })
	row("approach: a walk never passes its stop", "approach", { "Standard", "Timeline", 5.4, 20.01, dt })
	row("approach: a holder nearer than the stop is held", "approach", { "Standard", "Timeline", 3.0, 15, dt })
	row("approach: between walks it stands", "approach", { "Standard", "Timeline", 7.0, 12, dt })
	row("approach: the second walk at 9", "approach", { "Standard", "Timeline", 9.0, 30, dt })
	row("approach: Nightmare's last walk", "approach", { "Nightmare", "Timeline", 10.5, 13, dt })
	row("approach: the lunge at 15.5", "approach", { "Standard", "Timeline", 15.5, 10, dt })
	row("approach: lowered, it walks in at 6", "approach", { "Standard", "Lowered", 3, 10, dt })
	row("approach: missed, it closes at 9", "approach", { "Standard", "Missed", 3, 10, dt })
	row("approach: at contact distance it stops", "approach", { "Standard", "Timeline", 3, 4, dt })

	row("hitTest: at the chest", "hitTest", { ray(0), box, "Mouse" })
	row("hitTest: 2.2 wide misses with a mouse", "hitTest", { ray(0, 2.2), box, "Mouse" })
	row("hitTest: 2.2 wide hits with a gamepad", "hitTest", { ray(0, 2.2), box, "Gamepad" })
	row("hitTest: 2.8 wide misses with a gamepad", "hitTest", { ray(0, 2.8), box, "Gamepad" })
	row("hitTest: 2.8 wide hits on touch", "hitTest", { ray(0, 2.8), box, "Touch" })
	row("hitTest: the world in front blocks", "hitTest", { ray(0), box, "Mouse", 10 })
	row("hitTest: the world behind him does not", "hitTest", { ray(0), box, "Mouse", 30 })
	row("hitTest: a miss into the world is blocked", "hitTest", { ray(0, 5), box, "Mouse", 40 })
	row("hitTest: a miss into the sky", "hitTest", { ray(0, 5), box, "Mouse" })
	row("hitTest: 1.93 wide of him facing south misses", "hitTest", { ray(0, 1.93), box, "Mouse" })
	row("hitTest: 1.93 wide of him facing east hits", "hitTest", { ray(0, 1.93), turned, "Mouse" })
	row("hitTest: from inside the box", "hitTest", { ray(0, 0, 5, 75), box, "Mouse" })
	row("hitTest: straight down beside him", "hitTest", {
		{ origin = { x = 26, y = 30, z = 75 }, dir = { x = 0, y = -1, z = 0 } },
		box,
		"Mouse",
	})
	row("hitTest: straight down onto him", "hitTest", {
		{ origin = { x = 22, y = 30, z = 75 }, dir = { x = 0, y = -1, z = 0 } },
		box,
		"Mouse",
	})
	row("hitTest: beyond the ray's 60", "hitTest", { ray(0, 0, 5, 140), box, "Touch" })
	row("hitTest: an angled shot", "hitTest", { ray(-0.1, 2), box, "Mouse" })

	row("rewind: latency plus render delay", "rewind", { 0.1, 0.1 })
	row("rewind: at most 0.5", "rewind", { 0.3, 0.3 })
	row("rewind: never forward", "rewind", { -0.1, 0 })

	row("judgeShot: a hit", "judgeShot", { "Standard", shot({}) })
	row("judgeShot: a clear miss uses the round", "judgeShot", {
		"Standard",
		shot({ dir = { x = 0.3, y = 0, z = -1 }, looks = { { t = 5, x = 0.3, y = 0, z = -1 } } }),
	})
	row("judgeShot: blocked keeps the round", "judgeShot", { "Standard", shot({ blockedAt = 8 }) })
	row("judgeShot: fired after the window", "judgeShot", { "Standard", shot({ clientTime = 15.6, arrival = 15.7 }) })
	row("judgeShot: arrived after the grace", "judgeShot", { "Standard", shot({ clientTime = 15.4, arrival = 15.9 }) })
	row("judgeShot: the last moment at 200 ms", "judgeShot", {
		"Standard",
		shot({ clientTime = 15.45, arrival = 15.65, looks = { { t = 15.4, x = 0, y = 0, z = -1 } } }),
	})
	row(
		"judgeShot: Nightmare's window has closed",
		"judgeShot",
		{ "Nightmare", shot({ clientTime = 12.1, arrival = 12.2 }) }
	)
	row("judgeShot: Nightmare's last moment", "judgeShot", {
		"Nightmare",
		shot({ clientTime = 11.9, arrival = 12.2, looks = { { t = 11.9, x = 0, y = 0, z = -1 } } }),
	})
	row("judgeShot: before fire opens", "judgeShot", {
		"Standard",
		shot({ clientTime = 1.9, arrival = 2.0, looks = { { t = 1.9, x = 0, y = 0, z = -1 } } }),
	})
	row("judgeShot: picked up at 6, not yet armed", "judgeShot", {
		"Standard",
		shot({ clientTime = 6.4, arrival = 6.5, takenAt = 6, looks = { { t = 6.4, x = 0, y = 0, z = -1 } } }),
	})
	row("judgeShot: picked up at 6, armed", "judgeShot", {
		"Standard",
		shot({ clientTime = 6.7, arrival = 6.8, takenAt = 6, looks = { { t = 6.7, x = 0, y = 0, z = -1 } } }),
	})
	row("judgeShot: from too far from the head", "judgeShot", {
		"Standard",
		shot({ origin = { x = 22, y = 5, z = 98.5 } }),
	})
	row("judgeShot: 30 degrees off every look", "judgeShot", {
		"Standard",
		shot({ looks = { { t = 5, x = 0.5, y = 0, z = -0.8660254037844386 } } }),
	})
	row("judgeShot: no look within 0.15 s", "judgeShot", {
		"Standard",
		shot({ looks = { { t = 4.8, x = 0, y = 0, z = -1 } } }),
	})
	row("judgeShot: a flick", "judgeShot", {
		"Standard",
		shot({ looks = { { t = 4.9, x = 1, y = 0, z = 0 }, { t = 5.05, x = 0.05, y = 0, z = -1 } } }),
	})

	local ready: Holder = { takenAt = -3, lowered = false, heldAtOpen = false }
	row("canFire: before fire opens", "canFire", { "Standard", 1.9, ready })
	row("canFire: in the window", "canFire", { "Standard", 2.0, ready })
	row(
		"canFire: picked up at 6, at 6.5",
		"canFire",
		{ "Standard", 6.5, { takenAt = 6, lowered = false, heldAtOpen = false } }
	)
	row(
		"canFire: picked up at 6, at 6.6",
		"canFire",
		{ "Standard", 6.6, { takenAt = 6, lowered = false, heldAtOpen = false } }
	)
	row("canFire: lowered", "canFire", { "Standard", 8, { takenAt = -3, lowered = true, heldAtOpen = false } })
	row(
		"canFire: a button held when fire opened",
		"canFire",
		{ "Standard", 3, { takenAt = -3, lowered = false, heldAtOpen = true } }
	)
	row("canFire: after Standard's contact", "canFire", { "Standard", 15.6, ready })
	row("canFire: after Nightmare's contact", "canFire", { "Nightmare", 12.1, ready })
	row("canFire: Nightmare at 11.9", "canFire", { "Nightmare", 11.9, ready })

	row("gunButton: held 1.5 lowers", "gunButton", { 1.5, false })
	row("gunButton: still holding", "gunButton", { 1.0, false })
	row("gunButton: a tap drops", "gunButton", { 0.2, true })
	row("gunButton: released too late to drop", "gunButton", { 0.5, true })
	row("takeReady: from a lowered holder at 1.2", "takeReady", { 1.2, true })
	row("takeReady: from a lowered holder at 1.0", "takeReady", { 1.0, true })
	row("takeReady: off the floor at 0.6", "takeReady", { 0.6, false })
	row("takeReady: off the floor at 0.5", "takeReady", { 0.5, false })
	row("idleDrop: 4 s idle", "idleDrop", { 4 })
	row("idleDrop: 3.9 s idle", "idleDrop", { 3.9 })
	row("pickUpLineDue: nobody holds it at 4", "pickUpLineDue", { 4.0, false })
	row("pickUpLineDue: nobody holds it at 3.9", "pickUpLineDue", { 3.9, false })
	row("pickUpLineDue: someone holds it", "pickUpLineDue", { 5, true })

	-- step: one tick from chosen states
	local fresh = EndingRules.new("Standard", 20)
	local late = table.clone(fresh)
	late.t, late.next, late.distance = 15.5 - dt, #EndingRules.timeline("Standard") - 1, 4
	local missed = table.clone(fresh)
	missed.t, missed.next, missed.mode, missed.round = 4, 7, "Missed", false
	local over = table.clone(fresh)
	over.ending = "A"
	local far = table.clone(fresh)
	far.t, far.next, far.distance = 17.0 - dt, #EndingRules.timeline("Standard"), 30
	row("step: the first tick announces the fade-in", "step", { fresh, {}, dt })
	row("step: a hit is Ending A", "step", { fresh, { shot = "Hit" }, dt })
	row("step: a clear miss", "step", { fresh, { shot = "Miss" }, dt })
	row("step: lowered", "step", { fresh, { lowered = true }, dt })
	row("step: the holder's measured distance", "step", { fresh, { distance = 12 }, dt })
	row("step: contact at 15.5", "step", { late, {}, dt })
	row("step: no second round after a miss", "step", { missed, { shot = "Hit" }, dt })
	row("step: an ending is final", "step", { over, { shot = "Hit" }, dt })
	row("step: the lightning cut at 17", "step", { far, {}, dt })

	-- whole standoffs
	local away: { [number]: Input } = {}
	for i = 391, 600 do
		away[i] = { distance = 40 }
	end
	row(
		"replay: Standard, nobody shoots",
		"replay",
		{ { difficulty = "Standard", distance = 20, ticks = ticks(480, {}) } }
	)
	row(
		"replay: Nightmare, nobody shoots",
		"replay",
		{ { difficulty = "Nightmare", distance = 34, ticks = ticks(370, {}) } }
	)
	row("replay: Standard, a hit at 5", "replay", {
		{ difficulty = "Standard", distance = 25, ticks = ticks(160, { [150] = { shot = "Hit" } }) },
	})
	row("replay: Nightmare, a hit at the last moment", "replay", {
		{ difficulty = "Nightmare", distance = 25, ticks = ticks(370, { [357] = { shot = "Hit" } }) },
	})
	row("replay: Standard, lowered at 6", "replay", {
		{ difficulty = "Standard", distance = 25, ticks = ticks(300, { [180] = { lowered = true } }) },
	})
	row("replay: Standard, a clear miss at 4", "replay", {
		{ difficulty = "Standard", distance = 25, ticks = ticks(200, { [120] = { shot = "Miss" } }) },
	})
	row("replay: Standard, the holder walks into it at 8", "replay", {
		{ difficulty = "Standard", distance = 25, ticks = ticks(480, { [240] = { distance = 3 } }) },
	})
	row("replay: Standard, the holder backs away", "replay", {
		{ difficulty = "Standard", distance = 25, ticks = ticks(520, away) },
	})
	return rows
end

return EndingRules
