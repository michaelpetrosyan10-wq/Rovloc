--!strict
-- Locomotion: how the Creature gets anywhere. One Mover per Creature runs a plan: a queue of legs it steps every
-- frame (MonsterAIService's Heartbeat), so kinematic motion is smooth on every client.
--
-- Mediums. Floor (the Humanoid walks an unanchored root), Water (the root is anchored and glides under a pool's
-- surface, PoseMode Swim) and Vent (the root is anchored on the duct centreline, PoseMode Quadruped, exactly like a
-- crawling player's root). GoTo(point) plans whatever the change of medium needs: out of the ducts first through the
-- best open grate, then a walk to the pool deck and a slip into the water, or a swim to the deck edge and a climb out.
-- From a VentExitOnly pool (Level 4, CreatureConfig.Water) there is no climbing out: the way out is its own vent route,
-- a swim to the nearest pool grate and in; the ducts give no way back onto the land from there (a land goal is never
-- reached through a grate that opens into a sealed pool), so the plan ends in the duct and the brain moves the Creature
-- on unseen.
--
-- Legs.
--   Walk     PathfindingService on floors (CreatureConfig.PathAgent: radius 2, height 8, no jumping or climbing, the
--            MonsterPassthrough label costed so lockers, desks and open classroom doors are walked through; closed
--            ScriptedDoors and airlock doors collide in the Default group and are routed around or reported as no path).
--            Waypoints are followed with Humanoid:MoveTo; the route is recomputed on the repath interval when the goal
--            has moved, when the engine reports the path Blocked ahead, and after a stall. Close to a goal with a clear
--            straight line the Creature walks straight at it. Two failed computations fail the plan ("Failed"); no
--            progress for Repath.StuckSeconds forces a fresh route, and a second stall soon after reports "Stuck" (the
--            brain then repositions the Creature out of everyone's sight).
--   Swim     a straight glide under the surface, clamped inside the basin's water (SwimDepth below the surface), at
--            most the water pace (SetWaterSpeedCap: the AquaticStalk speed) unless the leg is a telegraphed lunge.
--   Transit  a short kinematic tween between two CFrames (crawling in or out of a grate mouth, slipping into or
--            climbing out of a pool), with the pose and medium it switches.
--   Rail     the root steps along a polyline of VentGraph points at the vent speed, facing its travel (or facing a
--            threat while it backs away), on the centreline.
--   Hold     stand still for a moment, optionally facing a direction (kick wind-up, peering).
--   Do       run a callback (kicking a grate) at its place in the plan.
-- Transit, Hold and Do are uninterruptible: a new plan asked for while one runs replaces the rest of the queue once it
-- ends, so the Creature never stops half inside a wall.
--
-- Engine calls (paths, MoveTo, Humanoid states, straight-line clearance) go through an Engine table so specs can
-- drive the planner without the engine; grate states and stand points come from a Grates table (VentNetworkService).

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)
local VentPathfinder = require(ReplicatedStorage.Shared.Vents.VentPathfinder)

local CreatureBody = require(script.Parent.CreatureBody)

export type Medium = "Floor" | "Water" | "Vent"
export type MoveStatus = "Idle" | "Moving" | "Failed" | "Stuck"

-- A pool deck edge (world, at deck height): from -> to along the coping, `outward` pointing onto the deck.
export type DeckEdge = { from: Vector3, to: Vector3, outward: Vector3 }

export type Basin = {
	id: string,
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	surfaceY: number,
	floorY: number,
	deckY: number,
	edges: { DeckEdge },
	ventExitOnly: boolean?, -- the Creature leaves it only through its own vent route (Level 4 fairness)
}

export type ComputedPath = { waypoints: { Vector3 }, path: Path? }

export type Engine = {
	computePath: (from: Vector3, to: Vector3) -> ComputedPath?, -- may yield
	moveTo: (humanoid: Humanoid, position: Vector3) -> (),
	configure: (humanoid: Humanoid) -> (),
	clear: (from: Vector3, to: Vector3, ignore: { Instance }) -> boolean, -- nothing solid on a straight walk
}

export type Grates = {
	state: (grateId: string) -> Enums.GrateState,
	standPoint: (grate: VentGraph.Grate) -> CFrame, -- room side of the opening, at floor (or water) level, facing the room
	kick: (grateId: string) -> (),
}

export type GoOptions = { arrive: number?, depth: number?, lunge: boolean? }

export type Mover = {
	SetLevel: (self: Mover, graph: VentGraph.Graph?, basins: { Basin }) -> (),
	SetSpeed: (self: Mover, speed: number) -> (),
	SetWaterSpeedCap: (self: Mover, speed: number?) -> (), -- the most any swim but a lunge moves (nil: no cap)
	SetRepathInterval: (self: Mover, seconds: number) -> (),
	GoTo: (self: Mover, position: Vector3, options: GoOptions?) -> (),
	EnterVent: (self: Mover, grate: VentGraph.Grate, kick: boolean) -> (),
	ExitVent: (self: Mover, grate: VentGraph.Grate?, toward: Vector3?) -> boolean,
	RailTo: (self: Mover, target: VentGraph.RailPoint) -> boolean,
	Retreat: (self: Mover, awayFrom: Vector3, hops: number) -> (),
	Hold: (self: Mover, seconds: number, face: Vector3?) -> (),
	Stop: (self: Mover) -> (),
	Reset: (self: Mover, medium: Medium?) -> (),
	Face: (self: Mover, direction: Vector3?) -> (),
	Step: (self: Mover, dt: number) -> (),
	Status: (self: Mover) -> MoveStatus,
	Medium: (self: Mover) -> Medium,
	Busy: (self: Mover) -> boolean,
	Goal: (self: Mover) -> Vector3?,
	RailPoint: (self: Mover) -> VentGraph.RailPoint?,
	Segment: (self: Mover) -> string?,
	NearestNode: (self: Mover) -> string?,
	BasinAt: (self: Mover, position: Vector3) -> Basin?,
	Destroy: (self: Mover) -> (),
}

type LegKind = "Walk" | "Swim" | "Transit" | "Rail" | "Hold" | "Do"

type Leg = {
	kind: LegKind,
	goal: Vector3?, -- Walk / Swim
	arrive: number,
	depth: number, -- Swim: least depth under the surface
	lunge: boolean, -- Swim: a telegraphed lunge (not held to the water pace)
	to: CFrame?, -- Transit
	from: CFrame?, -- Transit: where it started
	seconds: number, -- Transit / Hold
	elapsed: number,
	pose: Enums.PoseMode?, -- Transit: pose from its start
	exitPose: Enums.PoseMode?, -- Transit: pose once done
	enterMedium: Medium?, -- Transit: medium from its start
	exitMedium: Medium?, -- Transit: medium once done
	points: { Vector3 }, -- Rail
	index: number, -- Rail: next point
	backward: boolean, -- Rail: face against the travel
	face: Vector3?, -- Hold: direction; Rail backward: the point to keep facing
	run: (() -> ())?, -- Do
	started: boolean,
}

type WalkState = {
	goal: Vector3?,
	waypoints: { Vector3 },
	index: number,
	computing: boolean,
	request: number,
	computedAt: number,
	computedGoal: Vector3?,
	failures: number,
	repath: boolean,
	path: Path?,
	blocked: RBXScriptConnection?,
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
local DECK_IN = 2.5 -- deck stand point inside the coping
local WATER_IN = 2 -- water point inside the coping
local SLIP_SECONDS = 0.9
local CLIMB_SECONDS = 1.1
local SQUEEZE_SECONDS = 0.8
local FACE_SECONDS = 0.3
local KICK_RECOVER = 0.55
local RETREAT_DISTANCE = 9 -- inside DIRECT_RANGE: a stumble needs no route
local RETREAT_ANGLES: { number } = { 0, 35, -35, 70, -70 }
local SWIM_RETREAT = 12
local VERTICAL_TRAVEL = 0.95 -- |LookVector.Y| above this keeps the previous heading
local DEFAULT_REPATH = CreatureConfig.Repath.PatrolInterval

local ROOT_HEIGHT = CreatureBody.RootHeight

Locomotion.SwimDepth = SWIM_DEPTH
Locomotion.SqueezeSeconds = SQUEEZE_SECONDS
Locomotion.KickRecover = KICK_RECOVER

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
-- relative to the deck, and the room it lies in (its deck is wherever the room reaches past the basin by `minDeck`).
function Locomotion.makeBasin(
	id: string,
	origin: Vector3,
	rect: { x: number, z: number, w: number, d: number },
	room: { x: number, z: number, w: number, d: number },
	waterLevel: number,
	depth: number,
	minDeck: number?
): Basin
	local need = minDeck or 3
	local minX, maxX = origin.X + rect.x, origin.X + rect.x + rect.w
	local minZ, maxZ = origin.Z + rect.z, origin.Z + rect.z + rect.d
	local deckY = origin.Y
	local edges: { DeckEdge } = {}
	local inset = 2
	local function edge(from: Vector3, to: Vector3, outward: Vector3)
		table.insert(edges, { from = from, to = to, outward = outward })
	end
	if rect.x - room.x >= need then
		edge(Vector3.new(minX, deckY, minZ + inset), Vector3.new(minX, deckY, maxZ - inset), Vector3.new(-1, 0, 0))
	end
	if (room.x + room.w) - (rect.x + rect.w) >= need then
		edge(Vector3.new(maxX, deckY, minZ + inset), Vector3.new(maxX, deckY, maxZ - inset), Vector3.new(1, 0, 0))
	end
	if rect.z - room.z >= need then
		edge(Vector3.new(minX + inset, deckY, minZ), Vector3.new(maxX - inset, deckY, minZ), Vector3.new(0, 0, -1))
	end
	if (room.z + room.d) - (rect.z + rect.d) >= need then
		edge(Vector3.new(minX + inset, deckY, maxZ), Vector3.new(maxX - inset, deckY, maxZ), Vector3.new(0, 0, 1))
	end
	return {
		id = id,
		minX = minX,
		maxX = maxX,
		minZ = minZ,
		maxZ = maxZ,
		surfaceY = deckY + waterLevel,
		floorY = deckY - depth,
		deckY = deckY,
		edges = edges,
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

-- The deck crossing nearest `near`: the point on the coping, the deck stand point (root height on the deck) and
-- the water point just inside the coping. Nil when the basin has no deck.
function Locomotion.deckCrossing(basin: Basin, near: Vector3): (CFrame?, Vector3?)
	local best: DeckEdge? = nil
	local bestPoint = Vector3.zero
	local bestDistance = math.huge
	for _, edge in basin.edges do
		local _, point = VentGraph.closestOnSegment(edge.from, edge.to, Vector3.new(near.X, edge.from.Y, near.Z))
		local distance = horizontal(point, near)
		if distance < bestDistance then
			best, bestPoint, bestDistance = edge, point, distance
		end
	end
	if not best then
		return nil, nil
	end
	local outward = best.outward
	local deck = bestPoint + outward * DECK_IN
	local stand = CFrame.lookAt(deck + Vector3.new(0, ROOT_HEIGHT, 0), deck + Vector3.new(0, ROOT_HEIGHT, 0) + outward)
	local water = Vector3.new(bestPoint.X, basin.surfaceY - SWIM_DEPTH, bestPoint.Z) - outward * WATER_IN
	return stand, water
end

-- The cheapest route on the rail from `from` to `target` (both rail points): the polyline of node positions to walk,
-- ending at the target's own position, and its length. Nil when no duct joins them.
function Locomotion.railRoute(
	graph: VentGraph.Graph,
	from: VentGraph.RailPoint,
	target: VentGraph.RailPoint
): ({ Vector3 }?, number)
	local function ends(point: VentGraph.RailPoint): { { id: string, lead: number } }
		local a = graph.nodes[point.a]
		if not a then
			return {}
		end
		local out = { { id = point.a, lead = (point.position - a.position).Magnitude } }
		local b = point.b
		if b and graph.nodes[b] then
			table.insert(out, { id = b, lead = (point.position - graph.nodes[b].position).Magnitude })
		end
		return out
	end
	if from.b ~= nil and from.a == target.a and from.b == target.b then
		return { target.position }, (target.position - from.position).Magnitude
	end
	if from.b == nil and target.b == nil and from.a == target.a then
		return { graph.nodes[from.a].position, target.position },
			(from.position - graph.nodes[from.a].position).Magnitude
				+ (target.position - graph.nodes[from.a].position).Magnitude
	end
	local bestNodes: { string }? = nil
	local bestCost = math.huge
	for _, start in ends(from) do
		for _, goal in ends(target) do
			local nodes, cost = VentPathfinder.path(graph, start.id, goal.id)
			if nodes and start.lead + cost + goal.lead < bestCost then
				bestNodes, bestCost = nodes, start.lead + cost + goal.lead
			end
		end
	end
	local route = bestNodes
	if not route then
		return nil, math.huge
	end
	local points: { Vector3 } = {}
	for _, id in route do
		table.insert(points, graph.nodes[id].position)
	end
	table.insert(points, target.position)
	return points, bestCost
end

-- Moves along `points` from `position` by `budget` studs, starting at points[index]. Returns the new position, the
-- next index (past the end once finished) and the direction of the last movement (nil when it did not move).
function Locomotion.advance(
	points: { Vector3 },
	index: number,
	position: Vector3,
	budget: number
): (Vector3, number, Vector3?)
	local at = position
	local nextIndex = index
	local left = math.max(0, budget)
	local heading: Vector3? = nil
	while nextIndex <= #points do
		local target = points[nextIndex]
		local delta = target - at
		local distance = delta.Magnitude
		if distance > 1e-6 then
			heading = delta / distance
		end
		if distance <= left then
			at = target
			left -= distance
			nextIndex += 1
		else
			if distance > 1e-6 then
				at += delta / distance * left
			end
			break
		end
	end
	return at, nextIndex, heading
end

--------------------------------------------------------------------------------
-- Engine
--------------------------------------------------------------------------------

local function agentParameters(): { [string]: any }
	local agent = CreatureConfig.PathAgent
	return {
		AgentRadius = agent.AgentRadius,
		AgentHeight = agent.AgentHeight,
		AgentCanJump = agent.AgentCanJump,
		AgentCanClimb = agent.AgentCanClimb,
		WaypointSpacing = agent.WaypointSpacing,
		Costs = table.clone(agent.Costs),
	}
end

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

-- The real engine: PathfindingService, Humanoid:MoveTo and Monster-group rays at knee and chest height.
function Locomotion.defaultEngine(): Engine
	local parameters = agentParameters()
	return {
		computePath = function(from: Vector3, to: Vector3): ComputedPath?
			local path = PathfindingService:CreatePath(parameters)
			local ok = pcall(function()
				path:ComputeAsync(from, to)
			end)
			if not ok or path.Status ~= Enum.PathStatus.Success then
				path:Destroy()
				return nil
			end
			local points: { Vector3 } = {}
			for _, waypoint in path:GetWaypoints() do
				table.insert(points, waypoint.Position)
			end
			return { waypoints = points, path = path }
		end,
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
		to = nil,
		from = nil,
		seconds = 0,
		elapsed = 0,
		pose = nil,
		exitPose = nil,
		enterMedium = nil,
		exitMedium = nil,
		points = {},
		index = 1,
		backward = false,
		face = nil,
		run = nil,
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

-- A kinematic move to `to`: `pose` and `enterMedium` apply from its start, `exitPose` and `exitMedium` once done.
local function transitLeg(
	to: CFrame,
	seconds: number,
	pose: Enums.PoseMode?,
	enterMedium: Medium?,
	exitPose: Enums.PoseMode?,
	exitMedium: Medium?
): Leg
	local leg = newLeg("Transit")
	leg.to = to
	leg.seconds = seconds
	leg.pose = pose
	leg.enterMedium = enterMedium
	leg.exitPose = exitPose
	leg.exitMedium = exitMedium
	return leg
end

local function railLeg(points: { Vector3 }, backward: boolean, face: Vector3?): Leg
	local leg = newLeg("Rail")
	leg.points = points
	leg.backward = backward
	leg.face = face
	return leg
end

local function holdLeg(seconds: number, face: Vector3?): Leg
	local leg = newLeg("Hold")
	leg.seconds = seconds
	leg.face = face
	return leg
end

local function doLeg(run: () -> ()): Leg
	local leg = newLeg("Do")
	leg.run = run
	return leg
end

local BUSY_KINDS: { [string]: boolean } = { Transit = true, Hold = true, Do = true }

local function newWalk(): WalkState
	return {
		goal = nil,
		waypoints = {},
		index = 1,
		computing = false,
		request = 0,
		computedAt = -math.huge,
		computedGoal = nil,
		failures = 0,
		repath = true,
		path = nil,
		blocked = nil,
		issued = nil,
		issuedAt = -math.huge,
		clearAt = -math.huge,
		clearGoal = nil,
		clearResult = false,
		stalls = 0,
		stalledAt = -math.huge,
	}
end

function Locomotion.new(body: CreatureBody.Body, engine: Engine, grates: Grates, now: () -> number): Mover
	local graph: VentGraph.Graph? = nil
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
	local destroyed = false
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

	local function dropPath()
		local blocked = walk.blocked
		if blocked then
			blocked:Disconnect()
			walk.blocked = nil
		end
		local path = walk.path
		if path then
			walk.path = nil
			path:Destroy()
		end
	end

	local function stopWalking()
		walk.request += 1
		walk.computing = false
		dropPath()
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

	local function request(from: Vector3, goal: Vector3)
		walk.request += 1
		local id = walk.request
		walk.computing = true
		walk.repath = false
		walk.computedAt = now()
		walk.computedGoal = goal
		task.spawn(function()
			local result = engine.computePath(from, goal)
			if destroyed or id ~= walk.request then
				local stale = result and result.path
				if stale then
					stale:Destroy()
				end
				return
			end
			walk.computing = false
			if result and #result.waypoints > 0 then
				dropPath()
				walk.failures = 0
				walk.waypoints = result.waypoints
				walk.index = if #result.waypoints > 1 then 2 else 1
				local path = result.path
				if path then
					walk.path = path
					walk.blocked = path.Blocked:Connect(function(blockedIndex: number)
						if id == walk.request and blockedIndex >= walk.index then
							walk.repath = true
						end
					end)
				end
			else
				walk.failures += 1
				walk.repath = true
			end
		end)
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

	local function ensureFloor(leg: Leg)
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
	end

	local planTo: (goal: Vector3, options: GoOptions?) -> { Leg }
	local poolVentPlan: (basin: Basin, position: Vector3) -> { Leg }

	local function stepWalk(leg: Leg): boolean
		local humanoid = body.humanoid
		local goal = leg.goal
		if not (humanoid and goal) then
			return true
		end
		ensureFloor(leg)
		body:SetWalkSpeed(speed)
		local position = body:GetPosition()
		local t = now()
		if basinAt(position) then
			-- walked off the coping: it swims from here
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
		if not walk.computing and (walk.repath or (t - walk.computedAt >= repathInterval and drifted)) then
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

	local function stepTransit(leg: Leg, dt: number): boolean
		local to = leg.to
		if not to then
			return true
		end
		if not leg.started then
			leg.started = true
			stopWalking()
			leg.from = body:GetCFrame()
			body:SetAnchored(true)
			local pose = leg.pose
			if pose then
				body:SetPose(pose :: Enums.PoseMode)
			end
			local enter = leg.enterMedium
			if enter then
				medium = enter :: Medium
			end
		end
		leg.elapsed += dt
		local from = leg.from or to
		if leg.elapsed >= leg.seconds then
			body.root.CFrame = to
			local exitPose = leg.exitPose
			if exitPose then
				body:SetPose(exitPose :: Enums.PoseMode)
			end
			local exit = leg.exitMedium
			if exit then
				medium = exit :: Medium
				if exit == "Floor" then
					body:SetAnchored(false)
				end
			end
			return true
		end
		body.root.CFrame = from:Lerp(to, MathUtil.smoothstep(0, 1, leg.elapsed / leg.seconds))
		return false
	end

	local function stepRail(leg: Leg, dt: number): boolean
		if not leg.started then
			leg.started = true
			stopWalking()
		end
		if not body.anchored then
			body:SetAnchored(true)
		end
		body:SetPose("Quadruped")
		medium = "Vent"
		local position, index, heading = Locomotion.advance(leg.points, leg.index, body:GetPosition(), speed * dt)
		leg.index = index
		local facing: Vector3? = heading
		local threat = leg.face
		if leg.backward and threat then
			facing = threat - position
		elseif leg.backward and heading then
			facing = -heading
		end
		local look = if facing and facing.Magnitude > 1e-6 then facing.Unit else nil
		if look and math.abs(look.Y) < VERTICAL_TRAVEL then
			body.root.CFrame = CFrame.lookAt(position, position + Vector3.new(look.X, 0, look.Z))
		else
			body.root.CFrame = body.root.CFrame.Rotation + position
		end
		return index > #leg.points
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
		elseif leg.kind == "Transit" then
			return stepTransit(leg, dt)
		elseif leg.kind == "Rail" then
			return stepRail(leg, dt)
		elseif leg.kind == "Hold" then
			return stepHold(leg, dt)
		end
		leg.started = true
		local run = leg.run
		if run then
			run()
		end
		return true
	end

	local function railHere(): VentGraph.RailPoint?
		local level = graph
		if medium ~= "Vent" or not level then
			return nil
		end
		return VentGraph.nearest(level, body:GetPosition())
	end

	local function standCFrame(grate: VentGraph.Grate): (CFrame, Medium)
		local stand = grates.standPoint(grate)
		local basin = basinAt(stand.Position - Vector3.new(0, 0.6, 0))
		if basin then
			local point = Locomotion.clampToWater(basin, stand.Position)
			return CFrame.lookAt(point, point + stand.LookVector), "Water"
		end
		local root = stand.Position + Vector3.new(0, ROOT_HEIGHT, 0)
		return CFrame.lookAt(root, root + stand.LookVector), "Floor"
	end

	-- Legs that crawl from here out through `grate` (or the best grate toward `toward`), and the medium and point
	-- they end in. Nil when no grate is a way out.
	local function exitPlan(grate: VentGraph.Grate?, toward: Vector3?): ({ Leg }?, Medium, Vector3)
		local level = graph
		local here = railHere()
		local position = body:GetPosition()
		if not (level and here) then
			return nil, medium, position
		end
		local function routeTo(candidate: VentGraph.Grate): ({ Vector3 }?, number)
			local node = level.nodes[candidate.nodeId]
			if not node then
				return nil, math.huge
			end
			local mouth: VentGraph.RailPoint =
				{ a = candidate.nodeId, b = nil, t = 1, position = candidate.mouth, distance = 0 }
			return Locomotion.railRoute(level, here, mouth)
		end
		-- a goal on land is never reached by dropping back into a pool the Creature may not climb out of
		local landGoal = toward ~= nil and basinAt(toward :: Vector3) == nil
		local function intoSealedPool(candidate: VentGraph.Grate): boolean
			if not landGoal then
				return false
			end
			local basin = basinAt(standCFrame(candidate).Position)
			return basin ~= nil and basin.ventExitOnly == true
		end
		local chosen: VentGraph.Grate? = grate
		local kick = false
		local route: { Vector3 }? = nil
		if chosen then
			route = routeTo(chosen)
			local state = grates.state(chosen.id)
			kick = not (state == "Open" or state == "Kicked")
			if state == "Locked" or intoSealedPool(chosen) then
				route = nil
			end
		else
			local bestCost = math.huge
			local bestKickCost = math.huge
			local kickable: VentGraph.Grate? = nil
			local kickRoute: { Vector3 }? = nil
			for _, candidate in level.grates do
				local state = grates.state(candidate.id)
				if state == "Locked" or intoSealedPool(candidate) then
					continue
				end
				local points, cost = routeTo(candidate)
				if not points then
					continue
				end
				local stand = grates.standPoint(candidate)
				local total = cost + (if toward then horizontal(stand.Position, toward) else 0)
				if state == "Open" or state == "Kicked" then
					if total < bestCost then
						chosen, route, bestCost = candidate, points, total
					end
				elseif total < bestKickCost then
					kickable, kickRoute, bestKickCost = candidate, points, total
				end
			end
			if chosen == nil and kickable ~= nil then
				chosen, route, kick = kickable, kickRoute, true
			end
		end
		if not (chosen and route) then
			return nil, medium, position
		end
		local out = chosen :: VentGraph.Grate
		local plan: { Leg } = { railLeg(route, false, nil) }
		if kick then
			table.insert(
				plan,
				doLeg(function()
					grates.kick(out.id)
				end)
			)
			table.insert(plan, holdLeg(KICK_RECOVER, nil))
		end
		local stand, outside = standCFrame(out)
		local outsidePose: Enums.PoseMode = if outside == "Water" then "Swim" else "Biped"
		table.insert(plan, transitLeg(stand, SQUEEZE_SECONDS, nil, nil, outsidePose, outside :: Medium))
		return plan, outside :: Medium, stand.Position
	end

	-- The way out of a VentExitOnly pool: a swim to the nearest pool grate (one whose stand point is in this basin's
	-- water), a kick when it is shut, and in to its duct node. Empty when the pool has no usable grate (it stays in).
	poolVentPlan = function(basin: Basin, position: Vector3): { Leg }
		local level = graph
		if not level then
			return {}
		end
		local best: VentGraph.Grate? = nil
		local bestStand: CFrame? = nil
		local bestDistance = math.huge
		for _, candidate in level.grates do
			if not level.nodes[candidate.nodeId] or grates.state(candidate.id) == "Locked" then
				continue
			end
			local stand, outside = standCFrame(candidate)
			if outside ~= "Water" or basinAt(stand.Position) ~= basin then
				continue
			end
			local d = (stand.Position - position).Magnitude
			if d < bestDistance then
				best, bestStand, bestDistance = candidate, stand, d
			end
		end
		if not (best and bestStand) then
			return {}
		end
		local chosen = best :: VentGraph.Grate
		local stand = bestStand :: CFrame
		local state = grates.state(chosen.id)
		local intoWall = -stand.LookVector
		local plan: { Leg } = { swimLeg(stand.Position, 1, SWIM_DEPTH), holdLeg(FACE_SECONDS, intoWall) }
		if not (state == "Open" or state == "Kicked") then
			table.insert(
				plan,
				doLeg(function()
					grates.kick(chosen.id)
				end)
			)
			table.insert(plan, holdLeg(KICK_RECOVER, intoWall))
		end
		local flat = CreatureBody.flatDirection(intoWall) or Vector3.new(0, 0, -1)
		table.insert(
			plan,
			transitLeg(CFrame.lookAt(chosen.mouth, chosen.mouth + flat), SQUEEZE_SECONDS, "Quadruped", "Vent", nil, nil)
		)
		table.insert(plan, railLeg({ level.nodes[chosen.nodeId].position }, false, nil))
		return plan
	end

	planTo = function(goal: Vector3, options: GoOptions?): { Leg }
		local arrive = if options and options.arrive then options.arrive else 1.5
		local depth = if options and options.depth then options.depth else SWIM_DEPTH
		local plan: { Leg } = {}
		local from = medium
		local position = body:GetPosition()
		if from == "Vent" then
			local exits, outside, point = exitPlan(nil, goal)
			if not exits then
				return {}
			end
			for _, leg in exits do
				table.insert(plan, leg)
			end
			from = outside
			position = point
		end
		local goalBasin = basinAt(goal)
		if from == "Floor" and goalBasin then
			local stand, water = Locomotion.deckCrossing(goalBasin, goal)
			if stand and water then
				table.insert(plan, walkLeg(stand.Position - Vector3.new(0, ROOT_HEIGHT, 0), 1.2))
				table.insert(
					plan,
					transitLeg(CFrame.lookAt(water, water - stand.LookVector), SLIP_SECONDS, "Swim", "Water", nil, nil)
				)
				table.insert(plan, swimLeg(goal, arrive, depth))
			else
				table.insert(plan, walkLeg(goal, arrive))
			end
		elseif from == "Water" and not goalBasin then
			local basin = basinAt(position) or nearestBasin(position)
			if basin and basin.ventExitOnly then
				return poolVentPlan(basin, position)
			end
			local stand: CFrame?, water: Vector3? = nil, nil
			if basin then
				stand, water = Locomotion.deckCrossing(basin, goal)
			end
			if stand and water then
				table.insert(plan, swimLeg(water, 1, SWIM_DEPTH))
				table.insert(plan, transitLeg(stand, CLIMB_SECONDS, nil, nil, "Biped", "Floor"))
			end
			table.insert(plan, walkLeg(goal, arrive))
		elseif from == "Water" then
			table.insert(plan, swimLeg(goal, arrive, depth, options ~= nil and options.lunge == true))
		else
			table.insert(plan, walkLeg(goal, arrive))
		end
		return plan
	end

	local mover: Mover
	mover = {
		SetLevel = function(_self: Mover, levelGraph: VentGraph.Graph?, levelBasins: { Basin })
			graph = levelGraph
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

		EnterVent = function(_self: Mover, grate: VentGraph.Grate, kick: boolean)
			local level = graph
			local node = level and level.nodes[grate.nodeId]
			if not node then
				fail("Failed")
				return
			end
			local stand = grates.standPoint(grate)
			local intoWall = -stand.LookVector
			local plan = planTo(stand.Position, { arrive = 1.2 })
			table.insert(plan, holdLeg(FACE_SECONDS, intoWall))
			if kick then
				table.insert(
					plan,
					doLeg(function()
						grates.kick(grate.id)
					end)
				)
				table.insert(plan, holdLeg(KICK_RECOVER, intoWall))
			end
			local flat = CreatureBody.flatDirection(intoWall) or Vector3.new(0, 0, -1)
			table.insert(
				plan,
				transitLeg(
					CFrame.lookAt(grate.mouth, grate.mouth + flat),
					SQUEEZE_SECONDS,
					"Quadruped",
					"Vent",
					nil,
					nil
				)
			)
			table.insert(plan, railLeg({ node.position }, false, nil))
			install(plan)
		end,

		ExitVent = function(_self: Mover, grate: VentGraph.Grate?, toward: Vector3?): boolean
			if medium ~= "Vent" then
				return true
			end
			local plan = exitPlan(grate, toward)
			if not plan then
				return false
			end
			install(plan)
			return true
		end,

		RailTo = function(_self: Mover, target: VentGraph.RailPoint): boolean
			local level = graph
			local here = railHere()
			if not (level and here) then
				return false
			end
			local points = Locomotion.railRoute(level, here, target)
			if not points then
				return false
			end
			install({ railLeg(points, false, nil) })
			return true
		end,

		Retreat = function(_self: Mover, awayFrom: Vector3, hops: number)
			local position = body:GetPosition()
			local level = graph
			if medium == "Vent" and level then
				local node = VentGraph.nearestNode(level, position)
				if not node then
					return
				end
				local walkNodes = VentPathfinder.retreatPath(level, node, awayFrom, hops)
				local points: { Vector3 } = {}
				for _, id in walkNodes do
					table.insert(points, level.nodes[id].position)
				end
				install({ railLeg(points, true, awayFrom) })
				return
			end
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
			if current and BUSY_KINDS[current.kind] and current.started and current.kind == "Transit" then
				legs = { current }
			else
				legs = {}
				stopWalking()
			end
			queued = nil
			status = "Idle"
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

		Goal = function(_self: Mover): Vector3?
			local last = legs[#legs]
			if not last then
				return nil
			end
			if last.goal then
				return last.goal
			end
			local to = last.to
			if to then
				return to.Position
			end
			local points = last.points
			return points[#points]
		end,

		RailPoint = function(_self: Mover): VentGraph.RailPoint?
			return railHere()
		end,

		Segment = function(_self: Mover): string?
			local here = railHere()
			local level = graph
			if not (here and level) then
				return nil
			end
			local b = here.b
			return if b then VentGraph.segmentId(level, here.a, b) else nil
		end,

		NearestNode = function(_self: Mover): string?
			local level = graph
			return if level then VentGraph.nearestNode(level, body:GetPosition()) else nil
		end,

		BasinAt = function(_self: Mover, position: Vector3): Basin?
			return basinAt(position)
		end,

		Destroy = function(_self: Mover)
			destroyed = true
			legs = {}
			queued = nil
			walk.request += 1
			dropPath()
		end,
	}
	return mover
end

return table.freeze(Locomotion)
