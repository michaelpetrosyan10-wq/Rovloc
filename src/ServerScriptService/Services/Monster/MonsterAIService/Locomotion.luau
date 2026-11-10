--!strict
-- Locomotion: how the Creature gets anywhere (docs/MONSTER.md 10; the website's web/src/creature/locomotion.js). One
-- Mover per Creature runs a plan: a queue of legs it steps every frame (MonsterAIService's Heartbeat), so kinematic
-- motion is smooth on every client.
--
-- Mediums. Floor (the Humanoid walks an unanchored root) and Water (the root is anchored and glides under a pool's
-- surface, PoseMode Swim). It never enters a duct or a crawlway (there is no VentChase). GoTo(point) plans what the
-- change of medium needs: a pool is entered and left only by a Warp (the service's FadeOut, a placement out of
-- everyone's sight, a FadeIn), never by walking down the deck or climbing out.
--
-- Legs.
--   Walk     floor routes from engine.computePath (MonsterAIService's FloorNav: the zone graph's portals, agent radius 2,
--            never a crawl-only or low portal, never across a pool's water); waypoints followed with Humanoid:MoveTo,
--            recomputed on the repath interval when the goal moved and after a stall. Close to a goal with a clear
--            straight line it walks straight at it. Two failed computations fail the plan ("Failed"); no progress for
--            Repath.StuckSeconds forces a fresh route, and a second stall soon after reports "Stuck" (the brain then
--            repositions the Creature out of everyone's sight).
--   Swim     a straight glide under the surface, clamped inside the basin's water (SwimDepth below the surface), at
--            most the water pace (SetWaterSpeedCap: the AquaticStalk speed) unless the leg is a telegraphed lunge.
--   Warp     into or out of the water: hooks.warp(goal, medium) starts the service's fade relocation; the leg ends when
--            it is over (the body placed there, the medium switched).
--   Hold     stand still for a moment, optionally facing a direction.
-- Warp and Hold are uninterruptible: a new plan asked for while one runs replaces the rest of the queue once it ends.
--
-- Engine calls (routes, MoveTo, Humanoid states, straight-line clearance) go through an Engine table so specs can
-- drive the planner without the engine.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

local CreatureBody = require(script.Parent.CreatureBody)

export type Medium = "Floor" | "Water"
export type MoveStatus = "Idle" | "Moving" | "Failed" | "Stuck"

export type Basin = {
	id: string,
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	surfaceY: number,
	floorY: number,
	deckY: number,
	fadeOnly: boolean?, -- the Creature enters and leaves it only by a warp (Level 4 fairness)
}

export type ComputedPath = { waypoints: { Vector3 } }

export type Engine = {
	computePath: (from: Vector3, to: Vector3) -> ComputedPath?,
	moveTo: (humanoid: Humanoid, position: Vector3) -> (),
	configure: (humanoid: Humanoid) -> (),
	clear: (from: Vector3, to: Vector3, ignore: { Instance }) -> boolean, -- nothing solid on a straight walk
}

-- The service's fade relocation into or out of the water.
export type Hooks = {
	warp: (goal: Vector3, medium: Medium) -> boolean, -- starts it (false: none could start)
	warping: () -> boolean, -- one is still running
}

export type GoOptions = { arrive: number?, depth: number?, lunge: boolean? }

export type Mover = {
	SetLevel: (self: Mover, basins: { Basin }) -> (),
	SetSpeed: (self: Mover, speed: number) -> (),
	SetWaterSpeedCap: (self: Mover, speed: number?) -> (), -- the most any swim but a lunge moves (nil: no cap)
	SetRepathInterval: (self: Mover, seconds: number) -> (),
	GoTo: (self: Mover, position: Vector3, options: GoOptions?) -> (),
	Retreat: (self: Mover, awayFrom: Vector3) -> (),
	Hold: (self: Mover, seconds: number, face: Vector3?) -> (),
	Stop: (self: Mover) -> (),
	Reset: (self: Mover, medium: Medium?) -> (),
	Face: (self: Mover, direction: Vector3?) -> (),
	Step: (self: Mover, dt: number) -> (),
	Status: (self: Mover) -> MoveStatus,
	Medium: (self: Mover) -> Medium,
	Busy: (self: Mover) -> boolean,
	WarpPending: (self: Mover) -> boolean,
	Goal: (self: Mover) -> Vector3?,
	RouteAhead: (self: Mover) -> { Vector3 }, -- where the walker is heading: its MoveTo target, then the rest
	BasinAt: (self: Mover, position: Vector3) -> Basin?,
	Destroy: (self: Mover) -> (),
}

type LegKind = "Walk" | "Swim" | "Warp" | "Hold"

type Leg = {
	kind: LegKind,
	goal: Vector3?, -- Walk / Swim / Warp
	arrive: number,
	depth: number, -- Swim: least depth under the surface
	lunge: boolean, -- Swim: a telegraphed lunge (not held to the water pace)
	medium: Medium?, -- Warp: the medium it ends in
	seconds: number, -- Hold
	elapsed: number,
	face: Vector3?, -- Hold: direction
	started: boolean,
}

type WalkState = {
	goal: Vector3?,
	waypoints: { Vector3 },
	index: number,
	computedAt: number,
	computedGoal: Vector3?,
	failures: number,
	repath: boolean,
	issued: Vector3?,
	issuedAt: number,
	clearAt: number,
	clearGoal: Vector3?,
	clearResult: boolean,
	stalls: number,
	stalledAt: number,
}

local Locomotion = {}

local SWIM_DEPTH = 2.5 -- the root this far under the surface while swimming
local WATER_MARGIN = 1.5 -- from the basin walls and floor
local WAYPOINT_REACH = 2.5
local ARRIVE_VERTICAL = 6
local GOAL_JUMP = 4 -- a goal moved this far is a new goal (fresh route)
local GOAL_DRIFT = 2 -- a goal that moved this far since the last route is recomputed on the interval
local DIRECT_RANGE = 10
local CLEAR_RECHECK = 0.2
local REISSUE_SECONDS = 2
local MAX_PATH_FAILURES = 2
local STALL_WINDOW = 12 -- a second stall within this many seconds reports Stuck
local RETREAT_DISTANCE = 9 -- inside DIRECT_RANGE: a stumble needs no route
local RETREAT_ANGLES: { number } = { 0, 35, -35, 70, -70 }
local SWIM_RETREAT = 12
local DEFAULT_REPATH = CreatureConfig.Repath.PatrolInterval
local BUSY_KINDS: { [string]: boolean } = { Warp = true, Hold = true }

Locomotion.SwimDepth = SWIM_DEPTH
Locomotion.RetreatDistance = RETREAT_DISTANCE

local DISABLED_STATES: { Enum.HumanoidStateType } = {
	Enum.HumanoidStateType.Climbing,
	Enum.HumanoidStateType.Swimming,
	Enum.HumanoidStateType.Seated,
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.Jumping,
	Enum.HumanoidStateType.Flying,
}

--------------------------------------------------------------------------------
-- Pure helpers
--------------------------------------------------------------------------------

local function horizontal(a: Vector3, b: Vector3): number
	return MathUtil.horizontalDistance(a, b)
end

-- A pool basin in world space from its layout data: `rect` (level-local min corner + size), the water level and depth
-- relative to the deck. `_room` is the room it lies in (kept for the callers of the old shape).
function Locomotion.makeBasin(
	id: string,
	origin: Vector3,
	rect: { x: number, z: number, w: number, d: number },
	_room: { x: number, z: number, w: number, d: number },
	waterLevel: number,
	depth: number
): Basin
	local deckY = origin.Y
	return {
		id = id,
		minX = origin.X + rect.x,
		maxX = origin.X + rect.x + rect.w,
		minZ = origin.Z + rect.z,
		maxZ = origin.Z + rect.z + rect.d,
		surfaceY = deckY + waterLevel,
		floorY = deckY - depth,
		deckY = deckY,
	}
end

-- Is `position` in the basin's water (inside its walls, below the deck, above its floor)?
function Locomotion.inWater(basin: Basin, position: Vector3): boolean
	return position.X >= basin.minX
		and position.X <= basin.maxX
		and position.Z >= basin.minZ
		and position.Z <= basin.maxZ
		and position.Y < basin.deckY - 0.5
		and position.Y > basin.floorY - 1
end

-- `position` moved inside the basin's water: clear of its walls and floor, at least `depth` under the surface.
function Locomotion.clampToWater(basin: Basin, position: Vector3, depth: number?): Vector3
	local under = depth or SWIM_DEPTH
	local top = basin.surfaceY - under
	local bottom = math.min(basin.floorY + WATER_MARGIN, top)
	return Vector3.new(
		math.clamp(position.X, basin.minX + WATER_MARGIN, basin.maxX - WATER_MARGIN),
		math.clamp(position.Y, bottom, top),
		math.clamp(position.Z, basin.minZ + WATER_MARGIN, basin.maxZ - WATER_MARGIN)
	)
end

--------------------------------------------------------------------------------
-- Engine
--------------------------------------------------------------------------------

local function clearParams(ignore: { Instance }): RaycastParams
	local exclude = table.clone(ignore)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(exclude, character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.CollisionGroup = "Monster"
	params.RespectCanCollide = true
	params.IgnoreWater = true
	return params
end

-- The real engine: routes from `computePath` (the service's FloorNav), Humanoid:MoveTo and Monster-group rays at knee
-- and chest height.
function Locomotion.defaultEngine(computePath: (from: Vector3, to: Vector3) -> ComputedPath?): Engine
	return {
		computePath = computePath,
		moveTo = function(humanoid: Humanoid, position: Vector3)
			humanoid:MoveTo(position)
		end,
		configure = function(humanoid: Humanoid)
			for _, state in DISABLED_STATES do
				humanoid:SetStateEnabled(state, false)
			end
		end,
		clear = function(from: Vector3, to: Vector3, ignore: { Instance }): boolean
			local params = clearParams(ignore)
			for _, lift in { -2.5, 1 } do
				local start = from + Vector3.new(0, lift, 0)
				local finish = Vector3.new(to.X, from.Y + lift, to.Z)
				local delta = finish - start
				if delta.Magnitude > 1e-3 and Workspace:Raycast(start, delta, params) ~= nil then
					return false
				end
			end
			return true
		end,
	}
end

--------------------------------------------------------------------------------
-- Mover
--------------------------------------------------------------------------------

local function newLeg(kind: LegKind): Leg
	return {
		kind = kind,
		goal = nil,
		arrive = 1.5,
		depth = SWIM_DEPTH,
		lunge = false,
		medium = nil,
		seconds = 0,
		elapsed = 0,
		face = nil,
		started = false,
	}
end

local function walkLeg(goal: Vector3, arrive: number?): Leg
	local leg = newLeg("Walk")
	leg.goal = goal
	leg.arrive = arrive or 1.5
	return leg
end

local function swimLeg(goal: Vector3, arrive: number?, depth: number?, lunge: boolean?): Leg
	local leg = newLeg("Swim")
	leg.goal = goal
	leg.arrive = arrive or 1.5
	leg.depth = depth or SWIM_DEPTH
	leg.lunge = lunge == true
	return leg
end

local function warpLeg(goal: Vector3, medium: Medium): Leg
	local leg = newLeg("Warp")
	leg.goal = goal
	leg.medium = medium
	return leg
end

local function holdLeg(seconds: number, face: Vector3?): Leg
	local leg = newLeg("Hold")
	leg.seconds = seconds
	leg.face = face
	return leg
end

local function newWalk(): WalkState
	return {
		goal = nil,
		waypoints = {},
		index = 1,
		computedAt = -math.huge,
		computedGoal = nil,
		failures = 0,
		repath = true,
		issued = nil,
		issuedAt = -math.huge,
		clearAt = -math.huge,
		clearGoal = nil,
		clearResult = false,
		stalls = 0,
		stalledAt = -math.huge,
	}
end

function Locomotion.new(body: CreatureBody.Body, engine: Engine, hooks: Hooks?, now: () -> number): Mover
	local basins: { Basin } = {}
	local medium: Medium = "Floor"
	local legs: { Leg } = {}
	local queued: { Leg }? = nil
	local status: MoveStatus = "Idle"
	local speed = CreatureConfig.Speeds.Patrol
	local waterSpeed = math.huge
	local repathInterval = DEFAULT_REPATH
	local walk = newWalk()
	local stuck = CreatureBody.newStuckTracker(CreatureConfig.Repath.StuckSeconds)
	local configured = false
	local ignore: { Instance } = { body.model }

	local function basinAt(position: Vector3): Basin?
		for _, basin in basins do
			if Locomotion.inWater(basin, position) then
				return basin
			end
		end
		return nil
	end

	local function nearestBasin(position: Vector3): Basin?
		local best: Basin? = nil
		local bestDistance = math.huge
		for _, basin in basins do
			local centre = Vector3.new((basin.minX + basin.maxX) / 2, position.Y, (basin.minZ + basin.maxZ) / 2)
			local distance = horizontal(centre, position)
			if distance < bestDistance then
				best, bestDistance = basin, distance
			end
		end
		return best
	end

	local function stopWalking()
		walk.goal = nil
		walk.waypoints = {}
		walk.index = 1
		walk.failures = 0
		walk.repath = true
		walk.computedGoal = nil
		local humanoid = body.humanoid
		if walk.issued ~= nil and humanoid and not body.root.Anchored then
			engine.moveTo(humanoid, body:GetPosition())
		end
		walk.issued = nil
	end

	local function install(plan: { Leg })
		local current = legs[1]
		if current and BUSY_KINDS[current.kind] and current.started then
			queued = plan
		else
			if current and current.kind == "Walk" then
				local first = plan[1]
				if not (first and first.kind == "Walk") then
					stopWalking()
				end
			end
			legs = plan
			queued = nil
		end
		status = if #plan > 0 then "Moving" else "Idle"
	end

	local function fail(reason: MoveStatus)
		legs = {}
		queued = nil
		stopWalking()
		status = reason
	end

	local function issue(humanoid: Humanoid, target: Vector3)
		local t = now()
		local last = walk.issued
		if last == nil or (last - target).Magnitude > 0.5 or t - walk.issuedAt >= REISSUE_SECONDS then
			engine.moveTo(humanoid, target)
			walk.issued = target
			walk.issuedAt = t
		end
	end

	-- A route from here to `goal` (FloorNav is synchronous and cheap: no thread, no yield).
	local function request(from: Vector3, goal: Vector3)
		walk.repath = false
		walk.computedAt = now()
		walk.computedGoal = goal
		local result = engine.computePath(from, goal)
		if result and #result.waypoints > 0 then
			walk.failures = 0
			walk.waypoints = result.waypoints
			walk.index = 1
		else
			walk.failures += 1
			walk.repath = true
		end
	end

	-- A straight walk at `goal` is unobstructed (re-checked a few times a second).
	local function directClear(position: Vector3, goal: Vector3): boolean
		local t = now()
		local last = walk.clearGoal
		if last ~= nil and (last - goal).Magnitude < 1 and t - walk.clearAt < CLEAR_RECHECK then
			return walk.clearResult
		end
		walk.clearAt = t
		walk.clearGoal = goal
		walk.clearResult = engine.clear(position, goal, ignore)
		return walk.clearResult
	end

	local planTo: (goal: Vector3, options: GoOptions?) -> { Leg }

	local function stepWalk(leg: Leg): boolean
		local humanoid = body.humanoid
		local goal = leg.goal
		if not (humanoid and goal) then
			return true
		end
		if not leg.started then
			leg.started = true
			body:Face(nil)
		end
		if body.anchored then
			body:SetAnchored(false)
		end
		if body.pose == "Quadruped" or body.pose == "Swim" then
			body:SetPose("Biped")
		end
		medium = "Floor"
		body:SetWalkSpeed(speed)
		local position = body:GetPosition()
		local t = now()
		if basinAt(position) then
			-- fell off the coping: it swims from here (and leaves the water only by a warp)
			stopWalking()
			medium = "Water"
			body:SetAnchored(true)
			body:SetPose("Swim")
			local rest = table.clone(legs)
			table.remove(rest, 1)
			local replan = planTo(goal, { arrive = leg.arrive })
			for _, extra in rest do
				table.insert(replan, extra)
			end
			legs = replan
			return false
		end
		if horizontal(position, goal) <= leg.arrive and math.abs(position.Y - goal.Y) <= ARRIVE_VERTICAL then
			stopWalking()
			stuck:Reset()
			return true
		end
		local previous = walk.goal
		if previous == nil or (previous - goal).Magnitude > GOAL_JUMP then
			walk.goal = goal
			walk.waypoints = {}
			walk.index = 1
			walk.repath = true
		else
			walk.goal = goal
		end

		if stuck:Sample(position, t, true) then
			if t - walk.stalledAt > STALL_WINDOW then
				walk.stalls = 0
			end
			walk.stalls += 1
			walk.stalledAt = t
			if walk.stalls >= 2 then
				fail("Stuck")
				return false
			end
			walk.waypoints = {}
			walk.index = 1
			walk.repath = true
		end

		if horizontal(position, goal) <= DIRECT_RANGE and directClear(position, goal) then
			issue(humanoid, goal)
			return false
		end

		local drifted = walk.computedGoal == nil or ((walk.computedGoal :: Vector3) - goal).Magnitude >= GOAL_DRIFT
		if walk.repath or (t - walk.computedAt >= repathInterval and drifted) then
			if walk.failures >= MAX_PATH_FAILURES then
				fail("Failed")
				return false
			end
			request(position, goal)
		end

		local waypoints = walk.waypoints
		while walk.index <= #waypoints and horizontal(position, waypoints[walk.index]) <= WAYPOINT_REACH do
			walk.index += 1
		end
		if #waypoints > 0 then
			issue(humanoid, waypoints[walk.index] or goal)
		end
		return false
	end

	local function stepSwim(leg: Leg, dt: number): boolean
		local goal = leg.goal
		if not goal then
			return true
		end
		if not leg.started then
			leg.started = true
			stopWalking()
		end
		if not body.anchored then
			body:SetAnchored(true)
		end
		body:SetPose("Swim")
		medium = "Water"
		local position = body:GetPosition()
		local basin = basinAt(goal) or basinAt(position) or nearestBasin(position)
		local target = if basin then Locomotion.clampToWater(basin, goal, leg.depth) else goal
		local delta = target - position
		local distance = delta.Magnitude
		if distance <= leg.arrive then
			return true
		end
		local pace = if leg.lunge then speed else math.min(speed, waterSpeed)
		local step = math.min(distance, pace * dt)
		local nextPosition = position + delta / distance * step
		local flat = CreatureBody.flatDirection(delta)
		if flat then
			body.root.CFrame = CFrame.lookAt(nextPosition, nextPosition + flat)
		else
			body.root.CFrame = body.root.CFrame.Rotation + nextPosition
		end
		return false
	end

	local function stepWarp(leg: Leg): boolean
		local goal = leg.goal
		if not leg.started then
			leg.started = true
			stopWalking()
			local started = hooks ~= nil and goal ~= nil and hooks.warp(goal, leg.medium or "Floor")
			if not started then
				fail("Failed")
			end
			return false
		end
		if hooks and hooks.warping() then
			return false
		end
		medium = leg.medium or medium
		return true
	end

	local function stepHold(leg: Leg, dt: number): boolean
		if not leg.started then
			leg.started = true
			stopWalking()
			local face = leg.face
			if face then
				body:Face(face)
			end
		end
		leg.elapsed += dt
		return leg.elapsed >= leg.seconds
	end

	local function stepLeg(leg: Leg, dt: number): boolean
		if leg.kind == "Walk" then
			return stepWalk(leg)
		elseif leg.kind == "Swim" then
			return stepSwim(leg, dt)
		elseif leg.kind == "Warp" then
			return stepWarp(leg)
		end
		return stepHold(leg, dt)
	end

	planTo = function(goal: Vector3, options: GoOptions?): { Leg }
		local arrive = if options and options.arrive then options.arrive else 1.5
		local depth = if options and options.depth then options.depth else SWIM_DEPTH
		local goalBasin = basinAt(goal)
		if medium == "Floor" and goalBasin then
			-- into the water: fade out here, in under the surface out of everyone's sight
			return { warpLeg(Locomotion.clampToWater(goalBasin, goal, depth), "Water") }
		end
		if medium == "Water" and not goalBasin then
			-- out of the water: never climbing out at the deck; fade out under it and in on land out of sight
			return { warpLeg(goal, "Floor") }
		end
		if medium == "Water" then
			return { swimLeg(goal, arrive, depth, options ~= nil and options.lunge == true) }
		end
		return { walkLeg(goal, arrive) }
	end

	local mover: Mover
	mover = {
		SetLevel = function(_self: Mover, levelBasins: { Basin })
			basins = levelBasins
		end,

		SetSpeed = function(_self: Mover, value: number)
			speed = math.max(0, value)
		end,

		SetWaterSpeedCap = function(_self: Mover, value: number?)
			waterSpeed = if value and value > 0 then value else math.huge
		end,

		SetRepathInterval = function(_self: Mover, seconds: number)
			repathInterval = math.max(0.1, seconds)
		end,

		GoTo = function(_self: Mover, position: Vector3, options: GoOptions?)
			local plan = planTo(position, options)
			if #plan == 0 then
				fail("Failed")
				return
			end
			-- the same walk goal keeps its route (the Walk leg re-plans on its own as the goal drifts)
			local current = legs[1]
			local first = plan[1]
			if
				#plan == 1
				and current
				and current.kind == first.kind
				and (current.kind == "Walk" or current.kind == "Swim")
				and queued == nil
			then
				current.goal = first.goal
				current.arrive = first.arrive
				current.depth = first.depth
				current.lunge = first.lunge
				legs = { current }
				status = "Moving"
				return
			end
			install(plan)
		end,

		Retreat = function(_self: Mover, awayFrom: Vector3)
			local position = body:GetPosition()
			local away = CreatureBody.flatDirection(position - awayFrom)
				or CreatureBody.flatDirection(-body:GetCFrame().LookVector)
				or Vector3.new(0, 0, 1)
			if medium == "Water" then
				install({ swimLeg(position + away * SWIM_RETREAT, 1, SWIM_DEPTH) })
				return
			end
			-- stumble straight back, or veering off when a wall is right behind; flail in place when boxed in
			for _, degrees in RETREAT_ANGLES do
				local direction = CFrame.Angles(0, math.rad(degrees), 0):VectorToWorldSpace(away)
				local goal = position + direction * RETREAT_DISTANCE
				if engine.clear(position, goal, ignore) then
					install({ walkLeg(goal, 1.5) })
					return
				end
			end
			install({ holdLeg(RETREAT_DISTANCE / math.max(speed, 1), nil) })
		end,

		Hold = function(_self: Mover, seconds: number, face: Vector3?)
			install({ holdLeg(seconds, face) })
		end,

		Stop = function(_self: Mover)
			local current = legs[1]
			if current and current.kind == "Warp" and current.started then
				legs = { current }
			else
				legs = {}
				stopWalking()
			end
			queued = nil
			status = if #legs > 0 then "Moving" else "Idle"
		end,

		Reset = function(_self: Mover, newMedium: Medium?)
			legs = {}
			queued = nil
			stopWalking()
			stuck:Reset()
			walk.stalls = 0
			status = "Idle"
			medium = newMedium or (if basinAt(body:GetPosition()) then "Water" else "Floor")
		end,

		Face = function(_self: Mover, direction: Vector3?)
			body:Face(direction)
		end,

		Step = function(_self: Mover, dt: number)
			local humanoid = body.humanoid
			if not configured and humanoid then
				configured = true
				engine.configure(humanoid)
			end
			local leg = legs[1]
			if leg == nil and queued then
				legs = queued :: { Leg }
				queued = nil
				leg = legs[1]
			end
			if leg == nil then
				stuck:Sample(body:GetPosition(), now(), false)
				if status == "Moving" then
					status = "Idle"
				end
				return
			end
			if leg.kind ~= "Walk" then
				stuck:Sample(body:GetPosition(), now(), false)
			end
			local done = stepLeg(leg, dt)
			if done and legs[1] == leg then
				table.remove(legs, 1)
				local waiting = queued
				if waiting then
					legs = waiting
					queued = nil
				end
				if #legs == 0 then
					status = "Idle"
				end
			end
		end,

		Status = function(_self: Mover): MoveStatus
			return status
		end,

		Medium = function(_self: Mover): Medium
			return medium
		end,

		Busy = function(_self: Mover): boolean
			local current = legs[1]
			return current ~= nil and BUSY_KINDS[current.kind] == true or queued ~= nil
		end,

		WarpPending = function(_self: Mover): boolean
			for _, leg in legs do
				if leg.kind == "Warp" then
					return true
				end
			end
			for _, leg in queued or {} :: { Leg } do
				if leg.kind == "Warp" then
					return true
				end
			end
			return false
		end,

		Goal = function(_self: Mover): Vector3?
			local last = legs[#legs]
			return if last then last.goal else nil
		end,

		RouteAhead = function(_self: Mover): { Vector3 }
			local leg = legs[1]
			local issued = walk.issued
			if not leg or leg.kind ~= "Walk" or issued == nil then
				return {}
			end
			local out = { issued }
			local current = walk.waypoints[walk.index]
			if current and horizontal(current, issued) < 0.5 then
				for i = walk.index + 1, #walk.waypoints do
					table.insert(out, walk.waypoints[i])
				end
			end
			return out
		end,

		BasinAt = function(_self: Mover, position: Vector3): Basin?
			return basinAt(position)
		end,

		Destroy = function(_self: Mover)
			legs = {}
			queued = nil
		end,
	}
	return mover
end

-- The pose a medium stands in.
function Locomotion.poseFor(medium: Medium): Enums.PoseMode
	return if medium == "Water" then "Swim" else "Biped"
end

return table.freeze(Locomotion)
