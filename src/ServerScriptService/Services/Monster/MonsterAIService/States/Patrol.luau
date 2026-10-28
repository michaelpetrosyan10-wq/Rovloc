--!strict
-- Patrol: the Creature walks its level's patrol loops at Patrol speed.
--
--   * Loops come from the layout's PatrolWaypoint anchors (Brain.levelInfo): it joins a loop at the waypoint nearest
--     it, walks it in order (the last waypoint leads back to the first) for one lap, then picks the next loop.
--   * At a corner (the route turns by CornerDegrees or more) it stops: first it looks into the room's far corner,
--     then along the way it is about to go, a beat each.
--   * Choosing the next loop (chooseLoop): it may only use what it heard. The rooms it heard noises in lately pull it:
--     with the pacing's sweep chance (BuildUp sweeps most, Peak a little less, Relax never) it takes the loop through
--     the most and loudest of them; in Relax it takes the loop farthest from the last one instead, a breather;
--     otherwise one of the three loops nearest it.
--   * Withdrawing: entered with ctx.reposition (after a catch, a stun, a chase that ran too long) it first walks, at
--     InvestigateNoise speed, to a waypoint out of every player's sight (PacingDirector.repositionPoint), then patrols.
-- Inside a duct the first walk crawls out through the best open grate (Locomotion plans the way out).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

local Brain = require(script.Parent.Parent.Brain)

type Context = Brain.Context
type Loop = Brain.Loop

export type ChooseOptions = {
	current: string?, -- the loop just walked
	heardZones: { [string]: Brain.HeardZone },
	now: number,
	sweepChance: number,
	avoid: boolean, -- Relax: keep away from what it heard
	roll: () -> number, -- uniform in [0, 1)
}

type Run = {
	loop: Loop?,
	index: number,
	walked: number, -- waypoints reached on this loop
	looks: { Vector3 },
	arrived: boolean,
	withdrawTo: Vector3?,
	failures: number,
	lastLoop: string?,
}

local NAME: Enums.MonsterState = "Patrol"
local CORNER_DEGREES = 50
local LOOK_SECONDS = { min = 0.6, max = 1.1 }
local HEARD_TTL = 90
local ARRIVE = 2
local MAX_FAILURES = 3
local WITHDRAW_MIN = 35 -- from the nearest player
local WITHDRAW_MAX = 140

local Patrol = {}

Patrol.Name = NAME
Patrol.CornerDegrees = CORNER_DEGREES
Patrol.HeardTtl = HEARD_TTL
Patrol.SweepChance = table.freeze({ BuildUp = 0.6, Peak = 0.45, Relax = 0 } :: { [string]: number })

local runs: { [Context]: Run } = setmetatable({}, { __mode = "k" }) :: any

--------------------------------------------------------------------------------
-- Pure helpers
--------------------------------------------------------------------------------

-- The waypoint after `index` (the last leads back to the first).
function Patrol.nextIndex(loop: Loop, index: number): number
	local count = #loop.waypoints
	if count == 0 then
		return 1
	end
	return index % count + 1
end

-- The waypoint of `loop` nearest `position` (1 for an empty loop).
function Patrol.nearestIndex(loop: Loop, position: Vector3): number
	local best, bestDistance = 1, math.huge
	for index, waypoint in loop.waypoints do
		local distance = (waypoint.position - position).Magnitude
		if distance < bestDistance then
			best, bestDistance = index, distance
		end
	end
	return best
end

-- Degrees the route turns at `here` (0 = straight on, 180 = doubling back).
function Patrol.turnDegrees(previous: Vector3, here: Vector3, nextPoint: Vector3): number
	local incoming = MathUtil.flat(here - previous)
	local outgoing = MathUtil.flat(nextPoint - here)
	if incoming.Magnitude < 1e-4 or outgoing.Magnitude < 1e-4 then
		return 0
	end
	return math.deg(math.acos(math.clamp(incoming.Unit:Dot(outgoing.Unit), -1, 1)))
end

-- Where to look at a corner: into the farthest corner of the room that is not behind it, then the way it goes on.
function Patrol.cornerLooks(room: Brain.Room?, here: Vector3, incoming: Vector3, outgoing: Vector3): { Vector3 }
	local looks: { Vector3 } = {}
	local forward = MathUtil.flat(incoming)
	if room then
		local best: Vector3? = nil
		local bestDistance = -1
		for _, corner in
			{
				Vector3.new(room.minX, here.Y, room.minZ),
				Vector3.new(room.minX, here.Y, room.maxZ),
				Vector3.new(room.maxX, here.Y, room.minZ),
				Vector3.new(room.maxX, here.Y, room.maxZ),
			}
		do
			local offset = MathUtil.flat(corner - here)
			if offset.Magnitude < 1e-3 then
				continue
			end
			if forward.Magnitude > 1e-3 and offset.Unit:Dot(forward.Unit) < -0.2 then
				continue
			end
			if offset.Magnitude > bestDistance then
				best, bestDistance = offset.Unit, offset.Magnitude
			end
		end
		if best then
			table.insert(looks, best)
		end
	end
	local onward = MathUtil.flat(outgoing)
	if onward.Magnitude > 1e-3 then
		table.insert(looks, onward.Unit)
	end
	return looks
end

-- How strongly the noises it heard lately pull it toward `loop` (louder and fresher pull harder).
function Patrol.heardPull(loop: Loop, heardZones: { [string]: Brain.HeardZone }, now: number): number
	local pull = 0
	for zoneId, heard in heardZones do
		local age = now - heard.at
		if loop.zones[zoneId] and age >= 0 and age < HEARD_TTL then
			pull += heard.rank * (1 - age / HEARD_TTL)
		end
	end
	return pull
end

local function distanceTo(loop: Loop, position: Vector3): number
	local best = math.huge
	for _, waypoint in loop.waypoints do
		best = math.min(best, (waypoint.position - position).Magnitude)
	end
	return best
end

-- The next loop to walk (nil when the level has none). See the header for the rules.
function Patrol.chooseLoop(loops: { Loop }, from: Vector3, options: ChooseOptions): Loop?
	local candidates: { Loop } = {}
	for _, loop in loops do
		if #loop.waypoints > 0 and (loop.id ~= options.current or #loops == 1) then
			table.insert(candidates, loop)
		end
	end
	if #candidates == 0 then
		return nil
	end
	table.sort(candidates, function(a: Loop, b: Loop): boolean
		local da, db = distanceTo(a, from), distanceTo(b, from)
		if da ~= db then
			return da < db
		end
		return a.id < b.id
	end)
	local latest: Brain.HeardZone? = nil
	for _, heard in options.heardZones do
		local age = options.now - heard.at
		if age >= 0 and age < HEARD_TTL and (latest == nil or heard.at > latest.at) then
			latest = heard
		end
	end
	if options.avoid then
		local quiet = latest
		if quiet then
			local best: Loop = candidates[1]
			local bestDistance = -1
			for _, loop in candidates do
				local distance = (loop.centre - quiet.position).Magnitude
				if distance > bestDistance then
					best, bestDistance = loop, distance
				end
			end
			return best
		end
		return candidates[1]
	end
	if latest and options.roll() < options.sweepChance then
		local best: Loop? = nil
		local bestPull = 0
		for _, loop in candidates do
			local pull = Patrol.heardPull(loop, options.heardZones, options.now)
			if pull > bestPull then
				best, bestPull = loop, pull
			end
		end
		if best then
			return best
		end
	end
	local pick = math.min(#candidates, 1 + math.floor(options.roll() * math.min(3, #candidates)))
	return candidates[pick]
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local function runOf(ctx: Context): Run
	local run = runs[ctx]
	if not run then
		run = {
			loop = nil,
			index = 1,
			walked = 0,
			looks = {},
			arrived = false,
			withdrawTo = nil,
			failures = 0,
			lastLoop = nil,
		}
		runs[ctx] = run
	end
	return run
end

local function lookSeconds(ctx: Context): number
	return ctx.random:NextNumber(LOOK_SECONDS.min, LOOK_SECONDS.max)
end

local function pickLoop(ctx: Context, run: Run)
	local level = ctx.level
	if not level then
		run.loop = nil
		return
	end
	local position = ctx.body:GetPosition()
	local loop = Patrol.chooseLoop(level.loops, position, {
		current = run.lastLoop,
		heardZones = ctx.heardZones,
		now = ctx.now(),
		sweepChance = Patrol.SweepChance[ctx.phase] or 0,
		avoid = ctx.phase == "Relax",
		roll = function(): number
			return ctx.random:NextNumber()
		end,
	})
	run.loop = loop
	run.walked = 0
	run.failures = 0
	run.looks = {}
	run.arrived = false
	if loop then
		run.lastLoop = loop.id
		run.index = Patrol.nearestIndex(loop, position)
		ctx.mover:GoTo(loop.waypoints[run.index].position, { arrive = ARRIVE })
	end
end

local function setSpeed(ctx: Context, state: Enums.MonsterState)
	ctx.mover:SetSpeed(ctx.speedOf(state))
	ctx.body:SetWalkSpeed(ctx.speedOf(state))
end

-- Reached waypoint `run.index`: queue the corner looks (if it turns here), then walk on.
local function arrive(ctx: Context, run: Run, loop: Loop)
	local count = #loop.waypoints
	local here = loop.waypoints[run.index]
	local previous = loop.waypoints[(run.index - 2) % count + 1]
	local following = loop.waypoints[Patrol.nextIndex(loop, run.index)]
	run.arrived = true
	run.walked += 1
	if count >= 3 and Patrol.turnDegrees(previous.position, here.position, following.position) >= CORNER_DEGREES then
		local level = ctx.level
		local room = if level then level.rooms[here.zoneId] else nil
		run.looks = Patrol.cornerLooks(
			room,
			here.position,
			here.position - previous.position,
			following.position - here.position
		)
	end
end

local function walkOn(ctx: Context, run: Run, loop: Loop)
	run.arrived = false
	if run.walked >= #loop.waypoints then
		pickLoop(ctx, run)
		return
	end
	run.index = Patrol.nextIndex(loop, run.index)
	ctx.mover:GoTo(loop.waypoints[run.index].position, { arrive = ARRIVE })
end

function Patrol.enter(ctx: Context, _from: Enums.MonsterState)
	local run = runOf(ctx)
	run.loop = nil
	run.looks = {}
	run.withdrawTo = nil
	ctx.mover:SetRepathInterval(CreatureConfig.Repath.PatrolInterval)
	ctx.body:SetPose("Biped")
	if ctx.reposition then
		ctx.reposition = false
		local point = ctx.repositionPoint(WITHDRAW_MIN, WITHDRAW_MAX)
		if point then
			run.withdrawTo = point
			setSpeed(ctx, "InvestigateNoise")
			ctx.mover:GoTo(point, { arrive = ARRIVE })
			return
		end
	end
	setSpeed(ctx, NAME)
	pickLoop(ctx, run)
end

function Patrol.update(ctx: Context, _dt: number)
	local run = runOf(ctx)
	local mover = ctx.mover
	if mover:Busy() then
		return
	end
	local status = mover:Status()
	if run.withdrawTo then
		if status == "Moving" then
			return
		end
		run.withdrawTo = nil
		setSpeed(ctx, NAME)
		pickLoop(ctx, run)
		return
	end
	local loop = run.loop
	if not loop then
		pickLoop(ctx, run)
		return
	end
	if status == "Moving" then
		return
	end
	if status == "Failed" or status == "Stuck" then
		run.failures += 1
		if run.failures >= MAX_FAILURES then
			pickLoop(ctx, run)
		else
			run.walked += 1
			walkOn(ctx, run, loop)
		end
		return
	end
	if not run.arrived then
		arrive(ctx, run, loop)
	end
	local look = table.remove(run.looks, 1)
	if look then
		mover:Hold(lookSeconds(ctx), look)
		return
	end
	walkOn(ctx, run, loop)
end

function Patrol.exit(ctx: Context, _to: Enums.MonsterState)
	local run = runOf(ctx)
	run.withdrawTo = nil
	run.looks = {}
	ctx.body:Face(nil)
end

return table.freeze(Patrol)
