--!strict
-- Hearing: whether the Creature hears a noise pulse, how strongly, and where it believes it came from. Pure rules
-- over an injected wall counter and grate test; MonsterAIService feeds it every NoiseEmitted pulse.
--
-- A pulse is heard only on the listener's level (event.levelId == listener.levelId), and only with a radius above 0.
-- Its reach is radius x CreatureConfig.Senses.HearingMultiplier x the difficulty's hearingMultiplier x
-- listener.scale (PacingDirector's HearingScale, 1 when absent), shrunk per route:
--   * Air: straight line; each wall between source and listener (listener.occluders, at most MaxOccludingWalls of
--     them count) multiplies the reach by NoiseConfig.WallOcclusion.
--   * Water: straight line, no occlusion (sound carries through the pool).
--   * Vent, listener in a vent: the distance is the rail distance through the ducts: from the pulse to its
--     ventNodeId, the VentPathfinder route to the listener's ventNode, then to the listener (two points on one duct
--     use their straight distance), x NoiseConfig.VentPropagationMultiplier (bends and joints cost extra, read as a
--     longer way round); no occlusion inside the metal. When the ducts do not connect, the Air route is used.
--   * Vent, listener outside the vents: the Air route through the walls, or a leak out of an open grate near the
--     listener, whichever reads stronger. A leak runs the rail from the pulse to the grate's mouth
--     (x VentPropagationMultiplier) and then straight to the listener, at full strength out of the opening: only walls
--     between the mouth and the listener occlude it, so a grate in another room still leaks through that room's walls.
-- Heard when the distance is within the reach; strength = 1 - distance / reach (1 at the source, 0 at the edge).
--
-- Localisation. Critical and High pulses are placed exactly. Low and Normal ones are blurred: the believed position
-- is moved horizontally by up to BlurFraction (15%) of the listener's straight-line distance to the source, in a
-- direction and by an amount seeded by the pulse's serverTime, so the same pulse always blurs the same way.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Instances = require(ReplicatedStorage.Shared.Instances)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local NoiseConfig = require(ReplicatedStorage.Shared.Config.NoiseConfig)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Types = require(ReplicatedStorage.Shared.Types)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)
local VentPathfinder = require(ReplicatedStorage.Shared.Vents.VentPathfinder)

local VentNetworkService = require(ServerScriptService.Services.Vents.VentNetworkService)

export type Listener = {
	position: Vector3,
	levelId: string?,
	inVent: boolean,
	ventNode: string?,
	graph: VentGraph.Graph?,
	difficulty: Enums.Difficulty,
	-- walls between (default SpatialQuery.countOccluders)
	occluders: ((from: Vector3, to: Vector3) -> number)?,
	-- whether a grate lets sound out (default VentNetworkService.IsGrateOpen)
	grateOpen: ((grateId: string) -> boolean)?,
	-- extra reach factor (PacingDirector's HearingScale); 1 when absent
	scale: number?,
}

-- strength 0..1 (1 = at source)
export type Heard = { event: Types.NoiseEvent, position: Vector3, strength: number }

-- How a pulse reached the listener: its distance along that way and the reach it had there.
export type Route = { distance: number, reach: number }

local BLUR_FRACTION = 0.15
local BLUR_KEY = "HearingBlur"
local PRIORITY_RANK: { [string]: number } = { Low = 1, Normal = 2, High = 3, Critical = 4 }
local EXACT_RANK = 3 -- High and above are placed exactly
-- Studs a point may sit off a duct's centreline and still count as on that duct (crawler roots ride the centreline).
local ON_DUCT = 1

local Hearing = {}

Hearing.BlurFraction = BLUR_FRACTION

--------------------------------------------------------------------------------
-- Pure rules
--------------------------------------------------------------------------------

-- Low 1 < Normal 2 < High 3 < Critical 4 (0 for anything else).
function Hearing.priorityRank(priority: Enums.NoisePriority): number
	return PRIORITY_RANK[priority] or 0
end

local function difficultySpec(difficulty: Enums.Difficulty): DifficultyConfig.DifficultySpec
	if difficulty == "Nightmare" then
		return DifficultyConfig.Nightmare
	end
	return DifficultyConfig.Standard
end

-- The factor every reach is multiplied by: Senses.HearingMultiplier x difficulty x `scale` (non-finite or
-- negative scales count as 1).
function Hearing.multiplier(difficulty: Enums.Difficulty, scale: number?): number
	local extra = if scale ~= nil and MathUtil.isFinite(scale) and scale >= 0 then scale else 1
	return CreatureConfig.Senses.HearingMultiplier * difficultySpec(difficulty).hearingMultiplier * extra
end

-- Reach left after `walls` walls (only MaxOccludingWalls of them count).
function Hearing.occluded(reach: number, walls: number): number
	local counted = math.clamp(math.floor(walls), 0, NoiseConfig.MaxOccludingWalls)
	return reach * NoiseConfig.WallOcclusion ^ counted
end

-- 1 at the source, falling linearly to 0 at the reach; nil when the route is out of reach.
function Hearing.strengthOf(route: Route): number?
	if not (route.reach > 0) or route.distance > route.reach then
		return nil
	end
	return math.clamp(1 - route.distance / route.reach, 0, 1)
end

-- Whether `point` lies on the straight duct piece p0 -> p1 (within ON_DUCT of it).
local function onPiece(p0: Vector3, p1: Vector3, point: Vector3): boolean
	local _, closest = VentGraph.closestOnSegment(p0, p1, point)
	return (point - closest).Magnitude <= ON_DUCT
end

-- Whether both points lie on one straight piece leaving `nodeId` (a duct to a neighbour, or its grate's stub).
local function sharePiece(graph: VentGraph.Graph, nodeId: string, a: Vector3, b: Vector3): boolean
	local origin = graph.nodes[nodeId].position
	for _, other in VentGraph.neighbours(graph, nodeId) do
		local far = graph.nodes[other].position
		if onPiece(origin, far, a) and onPiece(origin, far, b) then
			return true
		end
	end
	local grate = VentGraph.grateOf(graph, nodeId)
	return grate ~= nil and onPiece(origin, grate.mouth, a) and onPiece(origin, grate.mouth, b)
end

-- Distance along the ducts from `fromPosition` (nearest node `fromNode`) to `toPosition` (nearest node `toNode`):
-- to the first node, the shortest route, then on from the last node. Two points on one straight piece (around one
-- node, or on the single duct joining two linked nodes) use their straight distance. Nil when the ducts do not
-- connect or a node is unknown.
function Hearing.railDistance(
	graph: VentGraph.Graph,
	fromPosition: Vector3,
	fromNode: string,
	toPosition: Vector3,
	toNode: string
): number?
	local from, to = graph.nodes[fromNode], graph.nodes[toNode]
	if from == nil or to == nil then
		return nil
	end
	local straight = (fromPosition - toPosition).Magnitude
	local lead = (fromPosition - from.position).Magnitude
	local tail = (toPosition - to.position).Magnitude
	if fromNode == toNode then
		return if sharePiece(graph, fromNode, fromPosition, toPosition) then straight else lead + tail
	end
	local route, length = VentPathfinder.path(graph, fromNode, toNode)
	if not route then
		return nil
	end
	if
		#route == 2
		and onPiece(from.position, to.position, fromPosition)
		and onPiece(from.position, to.position, toPosition)
	then
		return straight
	end
	return lead + length + tail
end

-- Where the listener believes the pulse came from (see the header).
function Hearing.believedPosition(event: Types.NoiseEvent, listenerPosition: Vector3): Vector3
	if Hearing.priorityRank(event.priority) >= EXACT_RANK then
		return event.position
	end
	return Hearing.blur(event.position, (event.position - listenerPosition).Magnitude, event.serverTime)
end

-- `position` moved horizontally by up to BlurFraction x `distance`, uniformly over that disc, seeded by `seed`.
function Hearing.blur(position: Vector3, distance: number, seed: number): Vector3
	if not (MathUtil.isFinite(distance) and distance > 0) then
		return position
	end
	local stableSeed = if MathUtil.isFinite(seed) then math.floor(seed * 1000) else 0
	local random = MathUtil.seededRandom(stableSeed, BLUR_KEY)
	local angle = random:NextNumber() * 2 * math.pi
	local radius = BLUR_FRACTION * distance * math.sqrt(random:NextNumber())
	return position + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
end

--------------------------------------------------------------------------------
-- Routes
--------------------------------------------------------------------------------

type Senses = {
	listener: Listener,
	reach: number, -- unoccluded reach
	occluders: (from: Vector3, to: Vector3) -> number,
	grateOpen: (grateId: string) -> boolean,
}

local function airRoute(senses: Senses, from: Vector3): Route
	local to = senses.listener.position
	return { distance = (from - to).Magnitude, reach = Hearing.occluded(senses.reach, senses.occluders(from, to)) }
end

local function ductRoute(senses: Senses, event: Types.NoiseEvent): Route?
	local listener = senses.listener
	local graph, fromNode, toNode = listener.graph, event.ventNodeId, listener.ventNode
	if graph == nil or fromNode == nil or toNode == nil then
		return nil
	end
	local distance = Hearing.railDistance(graph, event.position, fromNode, listener.position, toNode)
	if distance == nil then
		return nil
	end
	return { distance = distance * NoiseConfig.VentPropagationMultiplier, reach = senses.reach }
end

-- The strongest leak out of an open grate near the listener (nil when none reaches).
local function leakRoute(senses: Senses, event: Types.NoiseEvent): Route?
	local listener = senses.listener
	local graph, fromNode = listener.graph, event.ventNodeId
	if graph == nil or fromNode == nil then
		return nil
	end
	local best: Route? = nil
	local bestStrength = -1
	local ids: { string } = {}
	for id in graph.grates do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local grate = graph.grates[id]
		local outside = (grate.mouth - listener.position).Magnitude
		-- the rail only adds distance, so a mouth beyond the reach can never be heard through
		if outside > senses.reach or not senses.grateOpen(id) then
			continue
		end
		local inside = Hearing.railDistance(graph, event.position, fromNode, grate.mouth, grate.nodeId)
		if inside == nil then
			continue
		end
		local route: Route = {
			distance = inside * NoiseConfig.VentPropagationMultiplier + outside,
			reach = Hearing.occluded(senses.reach, senses.occluders(grate.mouth, listener.position)),
		}
		local strength = Hearing.strengthOf(route)
		if strength ~= nil and strength > bestStrength then
			best, bestStrength = route, strength
		end
	end
	return best
end

local function bestRoute(senses: Senses, event: Types.NoiseEvent): Route
	local listener = senses.listener
	local medium = event.medium
	if medium == "Water" then
		return { distance = (event.position - listener.position).Magnitude, reach = senses.reach }
	end
	if medium == "Vent" then
		if listener.inVent then
			return ductRoute(senses, event) or airRoute(senses, event.position)
		end
		local direct = airRoute(senses, event.position)
		local leak = leakRoute(senses, event)
		if leak == nil then
			return direct
		end
		local directStrength, leakStrength = Hearing.strengthOf(direct), Hearing.strengthOf(leak)
		if leakStrength ~= nil and (directStrength == nil or leakStrength > directStrength) then
			return leak
		end
		return direct
	end
	return airRoute(senses, event.position)
end

-- The default wall counter, built on its first use (Water pulses and pulses out of reach never cast a ray).
local function lazyOccluders(): (from: Vector3, to: Vector3) -> number
	local built: { (from: Vector3, to: Vector3) -> number } = {}
	return function(from: Vector3, to: Vector3): number
		if built[1] == nil then
			built[1] = Hearing.defaultOccluders()
		end
		return built[1](from, to)
	end
end

local function sensesOf(event: Types.NoiseEvent, listener: Listener): Senses
	return {
		listener = listener,
		reach = event.radius * Hearing.multiplier(listener.difficulty, listener.scale),
		occluders = listener.occluders or lazyOccluders(),
		grateOpen = listener.grateOpen or VentNetworkService.IsGrateOpen,
	}
end

--------------------------------------------------------------------------------
-- Defaults
--------------------------------------------------------------------------------

-- Walls between two points with the §4b sight rules (Default group, characters and the Creature excluded), up to
-- MaxOccludingWalls.
function Hearing.defaultOccluders(): (from: Vector3, to: Vector3) -> number
	local exclude: { Instance } = {}
	local creature = Instances.creature()
	if creature then
		table.insert(exclude, creature)
	end
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(exclude, character)
		end
	end
	local params = SpatialQuery.losParams(exclude)
	return function(from: Vector3, to: Vector3): number
		return SpatialQuery.countOccluders(from, to, params, NoiseConfig.MaxOccludingWalls)
	end
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- The way `event` reaches `listener` best (its distance and the reach it has there), whether or not it is heard.
function Hearing.route(event: Types.NoiseEvent, listener: Listener): Route
	return bestRoute(sensesOf(event, listener), event)
end

-- Whether `listener` hears `event` (see the header); the walls are only counted when the level and radius allow it.
function Hearing.perceive(event: Types.NoiseEvent, listener: Listener): Heard?
	if not (event.radius > 0) or event.levelId ~= listener.levelId then
		return nil
	end
	local senses = sensesOf(event, listener)
	-- every route is at least the straight line (triangle inequality) with at most the unoccluded reach
	if (event.position - listener.position).Magnitude > senses.reach then
		return nil
	end
	local strength = Hearing.strengthOf(bestRoute(senses, event))
	if strength == nil then
		return nil
	end
	return { event = event, position = Hearing.believedPosition(event, listener.position), strength = strength }
end

return table.freeze(Hearing)
