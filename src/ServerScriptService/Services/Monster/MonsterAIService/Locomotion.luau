--!strict
-- Locomotion: how the Creature gets anywhere (docs/MONSTER.md 10; the website's web/src/creature/locomotion.js). One
-- Mover per Creature runs a plan: a queue of legs it steps every frame (MonsterAIService's Heartbeat), so kinematic
-- motion is smooth on every client.
--
-- The Humanoid walks an unanchored root. It never enters a duct or a crawlway (there is no VentChase).
--
-- Legs.
--   Walk     floor routes from engine.computePath (MonsterAIService's FloorNav: the zone graph's portals, agent radius 2,
--            never a crawl-only or low portal); waypoints followed with Humanoid:MoveTo,
--            recomputed on the repath interval when the goal moved and after a stall. Close to a goal with a clear
--            straight line it walks straight at it. Two failed computations fail the plan ("Failed"); no progress for
--            Repath.StuckSeconds forces a fresh route, and a second stall soon after reports "Stuck" (the brain then
--            repositions the Creature out of everyone's sight).
--   Hold     stand still for a moment, optionally facing a direction.
-- Hold is uninterruptible: a new plan asked for while one runs replaces the rest of the queue once it ends.
--
-- Engine calls (routes, MoveTo, Humanoid states, straight-line clearance) go through an Engine table so specs can
-- drive the planner without the engine.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

local CreatureBody = require(script.Parent.CreatureBody)

export type MoveStatus = "Idle" | "Moving" | "Failed" | "Stuck"

export type ComputedPath = { waypoints: { Vector3 } }

export type Engine = {
	computePath: (from: Vector3, to: Vector3) -> ComputedPath?,
	moveTo: (humanoid: Humanoid, position: Vector3) -> (),
	configure: (humanoid: Humanoid) -> (),
	clear: (from: Vector3, to: Vector3, ignore: { Instance }) -> boolean, -- nothing solid on a straight walk
}

export type GoOptions = { arrive: number? }

export type Mover = {
	SetSpeed: (self: Mover, speed: number) -> (),
	SetRepathInterval: (self: Mover, seconds: number) -> (),
	GoTo: (self: Mover, position: Vector3, options: GoOptions?) -> (),
	Retreat: (self: Mover, awayFrom: Vector3) -> (),
	Hold: (self: Mover, seconds: number, face: Vector3?) -> (),
	Stop: (self: Mover) -> (),
	Reset: (self: Mover) -> (),
	Face: (self: Mover, direction: Vector3?) -> (),
	Step: (self: Mover, dt: number) -> (),
	Status: (self: Mover) -> MoveStatus,
	Busy: (self: Mover) -> boolean,
	Goal: (self: Mover) -> Vector3?,
	RouteAhead: (self: Mover) -> { Vector3 }, -- where the walker is heading: its MoveTo target, then the rest
	Destroy: (self: Mover) -> (),
}

type LegKind = "Walk" | "Hold"

type Leg = {
	kind: LegKind,
	goal: Vector3?, -- Walk
	arrive: number,
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
local DEFAULT_REPATH = CreatureConfig.Repath.PatrolInterval
local BUSY_KINDS: { [string]: boolean } = { Hold = true }

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

function Locomotion.new(body: CreatureBody.Body, engine: Engine, now: () -> number): Mover
	local legs: { Leg } = {}
	local queued: { Leg }? = nil
	local status: MoveStatus = "Idle"
	local speed = CreatureConfig.Speeds.Patrol
	local repathInterval = DEFAULT_REPATH
	local walk = newWalk()
	local stuck = CreatureBody.newStuckTracker(CreatureConfig.Repath.StuckSeconds)
	local configured = false
	local ignore: { Instance } = { body.model }

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
		if body.pose == "Quadruped" then
			body:SetPose("Biped")
		end
		body:SetWalkSpeed(speed)
		local position = body:GetPosition()
		local t = now()
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
		end
		return stepHold(leg, dt)
	end

	local mover: Mover
	mover = {
		SetSpeed = function(_self: Mover, value: number)
			speed = math.max(0, value)
		end,

		SetRepathInterval = function(_self: Mover, seconds: number)
			repathInterval = math.max(0.1, seconds)
		end,

		GoTo = function(_self: Mover, position: Vector3, options: GoOptions?)
			local arrive = if options and options.arrive then options.arrive else 1.5
			-- the same walk goal keeps its route (the Walk leg re-plans on its own as the goal drifts)
			local current = legs[1]
			if current and current.kind == "Walk" and queued == nil then
				current.goal = position
				current.arrive = arrive
				legs = { current }
				status = "Moving"
				return
			end
			install({ walkLeg(position, arrive) })
		end,

		Retreat = function(_self: Mover, awayFrom: Vector3)
			local position = body:GetPosition()
			local away = CreatureBody.flatDirection(position - awayFrom)
				or CreatureBody.flatDirection(-body:GetCFrame().LookVector)
				or Vector3.new(0, 0, 1)
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
			legs = {}
			stopWalking()
			queued = nil
			status = "Idle"
		end,

		Reset = function(_self: Mover)
			legs = {}
			queued = nil
			stopWalking()
			stuck:Reset()
			walk.stalls = 0
			status = "Idle"
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

		Busy = function(_self: Mover): boolean
			local current = legs[1]
			return current ~= nil and BUSY_KINDS[current.kind] == true or queued ~= nil
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

		Destroy = function(_self: Mover)
			legs = {}
			queued = nil
		end,
	}
	return mover
end

return table.freeze(Locomotion)
