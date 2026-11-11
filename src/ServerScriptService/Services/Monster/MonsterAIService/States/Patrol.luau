--!strict
-- Patrol (the Stalk, docs/MONSTER.md 6.3): the Creature walks its level's patrol loops (the junction graph; derived
-- from the rooms where a level has no waypoints) at the Patrol pace, 7 studs/s: slower than a walking player.
--
--   * It joins a loop at the waypoint nearest it that it can walk to, walks it in order (the last waypoint leads back
--     to the first) for one lap, then picks the next loop.
--   * At a junction (the route turns by CornerDegrees or more, loops of 3+) it pauses: head tilted, listening: first it
--     looks into the room's far corner, then along the way it is about to go, a beat each.
--   * Choosing the next loop: the rooms it heard noises in during the last HeardTtl seconds pull it: with the pacing's
--     sweep chance (BuildUp 0.75, Peak 0.6, Relax never) it takes the loop through the most and loudest of them; in
--     Relax it takes the loop farthest from the latest one instead; otherwise one of the three loops nearest it. Only
--     loops it can walk to count (ctx.reachable: a level may fall apart into parts joined only by locked airlocks or
--     ducts, and a warp may leave it in any of them); a loop it cannot reach would fail every leg where it stands.
--   * Withdrawing: entered with ctx.reposition (after a catch or a stun) it first walks, at InvestigateNoise speed, to a
--     waypoint out of every player's sight 35..140 studs from them, then patrols. (A chase that gives up fades out
--     instead: the service's warp, before Patrol starts.)
--   * Three failed legs pick a new loop.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)

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
local LOOK_MIN, LOOK_MAX = 0.6, 1.1
local HEARD_TTL = 60
local ARRIVE = 2
local MAX_FAILURES = 3
local WITHDRAW_MIN = 35 -- from the nearest player
local WITHDRAW_MAX = 140

local Patrol = {}

Patrol.Name = NAME
Patrol.CornerDegrees = CORNER_DEGREES
Patrol.HeardTtl = HEARD_TTL
Patrol.WithdrawMin = WITHDRAW_MIN
Patrol.WithdrawMax = WITHDRAW_MAX
Patrol.SweepChance = table.freeze({ BuildUp = 0.75, Peak = 0.6, Relax = 0 } :: { [string]: number })

local runs: { [Context]: Run } = setmetatable({}, { __mode = "k" }) :: any

-- The waypoint after `index` (1-based; the last leads back to the first).
function Patrol.nextIndex(loop: Loop, index: number): number
	local count = #loop.waypoints
	if count == 0 then
		return 1
	end
	return index % count + 1
end

-- The waypoint of `loop` nearest `position` (of those `reachable` passes, when any does).
function Patrol.nearestIndex(loop: Loop, position: Vector3, reachable: ((Vector3) -> boolean)?): number
	local any = false
	if reachable then
		for _, waypoint in loop.waypoints do
			if reachable(waypoint.position) then
				any = true
				break
			end
		end
	end
	local best, bestDistance = 1, math.huge
	for i, waypoint in loop.waypoints do
		if any and reachable and not reachable(waypoint.position) then
			continue
		end
		local d = (waypoint.position - position).Magnitude
		if d < bestDistance then
			best, bestDistance = i, d
		end
	end
	return best
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Degrees the route turns at `here` (0 = straight on).
function Patrol.turnDegrees(previous: Vector3, here: Vector3, nextPoint: Vector3): number
	local incoming = flat(here - previous)
	local outgoing = flat(nextPoint - here)
	if incoming.Magnitude < 1e-4 or outgoing.Magnitude < 1e-4 then
		return 0
	end
	return math.deg(math.acos(math.clamp(incoming.Unit:Dot(outgoing.Unit), -1, 1)))
end

-- Where to look at a corner: into the farthest corner of the room not behind it, then the way on.
function Patrol.cornerLooks(room: Brain.Room?, here: Vector3, incoming: Vector3, outgoing: Vector3): { Vector3 }
	local looks: { Vector3 } = {}
	local forward = flat(incoming)
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
			local offset = flat(corner - here)
			local len = offset.Magnitude
			if len < 1e-3 then
				continue
			end
			if forward.Magnitude > 1e-3 and offset.Unit:Dot(forward.Unit) < -0.2 then
				continue
			end
			if len > bestDistance then
				best, bestDistance = offset.Unit, len
			end
		end
		if best then
			table.insert(looks, best)
		end
	end
	local onward = flat(outgoing)
	if onward.Magnitude > 1e-3 then
		table.insert(looks, onward.Unit)
	end
	return looks
end

-- How strongly the noises heard lately pull toward `loop`.
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

-- The next loop to walk (nil when the level has none).
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
		if age >= 0 and age < HEARD_TTL and (latest == nil or heard.at > (latest :: Brain.HeardZone).at) then
			latest = heard
		end
	end
	if options.avoid then
		if latest then
			local best = candidates[1]
			local bestDistance = -1
			for _, loop in candidates do
				local d = (loop.centre - latest.position).Magnitude
				if d > bestDistance then
					best, bestDistance = loop, d
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

local function pickLoop(ctx: Context, run: Run)
	local level = ctx.level
	if not level then
		run.loop = nil
		return
	end
	local position = ctx.body:GetPosition()
	-- the loops it can walk to from here (all of them when it can reach none: the mover then stalls and the service
	-- moves it unseen)
	local reachable = ctx.reachable()
	local walkable: { Loop } = {}
	for _, loop in level.loops do
		local ok = reachable == nil
		if reachable then
			for _, waypoint in loop.waypoints do
				if reachable(waypoint.position) then
					ok = true
					break
				end
			end
		end
		if ok then
			table.insert(walkable, loop)
		end
	end
	local loop = Patrol.chooseLoop(if #walkable > 0 then walkable else level.loops, position, {
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
		run.index = Patrol.nearestIndex(loop, position, reachable)
		ctx.mover:GoTo(loop.waypoints[run.index].position, { arrive = ARRIVE })
	end
end

local function setSpeed(ctx: Context, state: Enums.MonsterState)
	ctx.mover:SetSpeed(ctx.speedOf(state))
	ctx.body:SetWalkSpeed(ctx.speedOf(state))
end

local function arrive(ctx: Context, run: Run, loop: Loop)
	local count = #loop.waypoints
	local here = loop.waypoints[run.index]
	local previous = loop.waypoints[(run.index - 2) % count + 1]
	local following = loop.waypoints[Patrol.nextIndex(loop, run.index)]
	run.arrived = true
	run.walked += 1
	if count >= 3 and Patrol.turnDegrees(previous.position, here.position, following.position) >= CORNER_DEGREES then
		local room = if ctx.level then ctx.level.rooms[here.zoneId] else nil
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
		mover:Hold(ctx.random:NextNumber(LOOK_MIN, LOOK_MAX), look)
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
