--!strict
-- ZoneGraph: the walkable / crawlable topology of the whole school as pure data (no instances).
--
-- Nodes are rooms ("room:<layoutId>:<roomId>") and vent nodes ("vent:<layoutId>:<nodeId>"). Edges are portals:
--   doors       Doorway -> "Doorway"; Door / Ajar / RoofDoor -> "Door"; Gate -> "Gate"; Airlock -> "Airlock";
--               Boarded doors are planked shut and produce no edge. portalId = door id.
--   grates      room <-> the vent node the grate sits on, kind "Grate", portalId = grate id.
--   ducts       vent node <-> vent node, kind "Duct", portalId = "duct:<a>-<b>".
--   stairwells  WorldConfig.Stairwells fromRoom <-> toRoom across layouts, kind "Stair", portalId = stairwell id.
-- A BlockedSet names portal ids that are currently impassable (locked grates, shut gates, sealed airlocks).
--
-- Everything is deterministic: layouts, rooms, doors, grates, duct edges and stairwells are visited in list order,
-- adjacency lists keep edge insertion order, and the shortest-path queue breaks ties by insertion sequence.
-- Node centres are world space: a room's centre is its rect centre on its floor plane (level-local Y 0); a vent
-- node's centre is the duct centre. Edge lengths are straight lines through the portal point (door centre on the
-- floor, grate opening centre, tower opening at each floor; stair climbs count the walked slope of the flights).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local log = Log.new("ZoneGraph")

type Layout = LayoutSchema.LevelLayout
type Room = LayoutSchema.Room
type Rect = LayoutSchema.Rect
type VentNodeSpec = LayoutSchema.VentNodeSpec
type Graph = Types.ZoneGraphData
type ZoneNode = Types.ZoneNode
type ZoneEdge = Types.ZoneEdge

local EPS = 1e-3

-- Rooms whose rect lies within this many studs of a duct's chase count as adjacent to the duct.
local ADJACENT_RANGE = 1

-- How far a duct's metal reaches past its centre line (and past a capped end node): half the bore plus the shell.
local DUCT_HALF_OUTER = WorldConfig.VentBore / 2 + WorldConfig.VentShell

-- Walked distance per stud of rise on the steepest flight the stair towers build (1 stud rise per 1.6 run).
local STAIR_PATH_PER_RISE = math.sqrt(1 + 1.6 * 1.6)

local ZoneGraph = {}

ZoneGraph.AdjacentRange = ADJACENT_RANGE

--------------------------------------------------------------------------------
-- Ids
--------------------------------------------------------------------------------

function ZoneGraph.roomNodeId(layoutId: string, roomId: string): string
	return "room:" .. layoutId .. ":" .. roomId
end

function ZoneGraph.ventNodeId(layoutId: string, nodeId: string): string
	return "vent:" .. layoutId .. ":" .. nodeId
end

-- VentShaft SegmentId of the duct between vent nodes `a` and `b` (in the layout's edge order).
function ZoneGraph.segmentId(a: string, b: string): string
	return a .. "-" .. b
end

-- Portal id of that duct in a BlockedSet.
function ZoneGraph.ductPortalId(a: string, b: string): string
	return "duct:" .. ZoneGraph.segmentId(a, b)
end

local DOORWAY: Types.PortalKind = "Doorway"
local DOOR: Types.PortalKind = "Door"
local GATE: Types.PortalKind = "Gate"
local AIRLOCK: Types.PortalKind = "Airlock"

local DOOR_PORTALS: { [string]: Types.PortalKind } = {
	Doorway = DOORWAY,
	Door = DOOR,
	Ajar = DOOR,
	RoofDoor = DOOR,
	Gate = GATE,
	Airlock = AIRLOCK,
}

-- Portal kind of a door, or nil when the door never lets anyone through (Boarded).
function ZoneGraph.doorPortalKind(kind: Enums.DoorKind): Types.PortalKind?
	return DOOR_PORTALS[kind]
end

--------------------------------------------------------------------------------
-- Geometry helpers
--------------------------------------------------------------------------------

local function roomCenter(origin: Vector3, room: Room): Vector3
	local r = room.rect
	return origin + Vector3.new(r.x + r.w / 2, 0, r.z + r.d / 2)
end

local function ventCenter(origin: Vector3, node: VentNodeSpec): Vector3
	return origin + Vector3.new(node.x, LayoutSchema.ventNodeY(node), node.z)
end

-- Overlap length of [a0, a1] and [b0, b1] (negative when they are apart).
local function overlap(a0: number, a1: number, b0: number, b1: number): number
	return math.min(a1, b1) - math.max(a0, b0)
end

-- Gap between [a0, a1] and [b0, b1] (0 when they touch or overlap).
local function gap(a0: number, a1: number, b0: number, b1: number): number
	return math.max(0, b0 - a1, a0 - b1)
end

-- True when `room` lies within `range` of `chase` along a shared stretch of wall: their projections overlap on
-- one axis and the gap on the other is at most `range`. Rooms that only meet the chase at a corner are not
-- adjacent (the duct never runs through their walls).
local function besideRect(room: Rect, chase: Rect, range: number): boolean
	local overlapX = overlap(room.x, room.x + room.w, chase.x, chase.x + chase.w)
	local overlapZ = overlap(room.z, room.z + room.d, chase.z, chase.z + chase.d)
	local gapX = gap(room.x, room.x + room.w, chase.x, chase.x + chase.w)
	local gapZ = gap(room.z, room.z + room.d, chase.z, chase.z + chase.d)
	return (overlapZ > EPS and gapX <= range + EPS) or (overlapX > EPS and gapZ <= range + EPS)
end

-- True when `room` lies beside the stretch of `chase` the duct segment (x0..x1, z0..z1) actually occupies: along
-- the chase's long axis (both axes for a square chase) the room's projection overlaps the segment's span widened by
-- `reach` (the duct's outer half-width plus the adjacency range). A room beside the far end of a long chase is
-- therefore not adjacent to a short duct at the other end, and a room at the chase's end wall is adjacent only to
-- a duct that reaches within range of that wall.
local function besideSpan(
	room: Rect,
	chase: Rect,
	x0: number,
	x1: number,
	z0: number,
	z1: number,
	reach: number
): boolean
	if chase.w >= chase.d - EPS and overlap(room.x, room.x + room.w, x0 - reach, x1 + reach) <= EPS then
		return false
	end
	if chase.d >= chase.w - EPS and overlap(room.z, room.z + room.d, z0 - reach, z1 + reach) <= EPS then
		return false
	end
	return true
end

-- True when the duct segment (x0..x1, z0..z1, axis-aligned or a point) runs through `rect` for a positive length
-- (a point segment: lies inside it). Boundaries count as inside.
local function segmentInside(rect: Rect, x0: number, x1: number, z0: number, z1: number): boolean
	local ox = overlap(x0, x1, rect.x, rect.x + rect.w)
	local oz = overlap(z0, z1, rect.z, rect.z + rect.d)
	if ox < -EPS or oz < -EPS then
		return false
	end
	local spanX, spanZ = x1 - x0, z1 - z0
	if spanX <= EPS and spanZ <= EPS then
		return true
	end
	if spanX >= spanZ then
		return ox > EPS
	end
	return oz > EPS
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function doorPortal(origin: Vector3, a: Room, b: Room, door: LayoutSchema.Door): Vector3?
	local edge = LayoutSchema.sharedEdge(a.rect, b.rect)
	if not edge then
		return nil
	end
	if edge.axis == "X" then
		return origin + Vector3.new(edge.coord, 0, door.at)
	end
	return origin + Vector3.new(door.at, 0, edge.coord)
end

-- World point of the tower opening a stairwell leaves / enters `layoutId` through (on that level's floor).
local function towerPortal(spec: WorldConfig.StairwellSpec, layoutId: string): Vector3
	local tower = WorldConfig.Towers[spec.tower]
	local x = if tower then (if spec.tower == "East" then tower.minX else tower.maxX) else 0
	return WorldConfig.levelOrigin(layoutId) + Vector3.new(x, 0, WorldConfig.TowerOpening.centerZ)
end

-- Builds the graph of every layout in `layouts` (any subset; stairwells join two layouts only when both are given).
function ZoneGraph.build(layouts: { Layout }): Graph
	local nodes: { [string]: ZoneNode } = {}
	local edges: { ZoneEdge } = {}
	local adjacency: { [string]: { ZoneEdge } } = {}
	local byId: { [string]: Layout } = {}

	local function addNode(node: ZoneNode)
		if nodes[node.id] then
			log.warn("duplicate zone node %s ignored", node.id)
			return
		end
		nodes[node.id] = node
		adjacency[node.id] = {}
	end

	local function addEdge(a: string, b: string, kind: Types.PortalKind, portalId: string, length: number)
		if not nodes[a] or not nodes[b] then
			log.warn("%s portal %s joins a missing node (%s, %s)", kind, portalId, a, b)
			return
		end
		if a == b then
			log.warn("%s portal %s joins %s to itself; ignored", kind, portalId, a)
			return
		end
		local edge: ZoneEdge = { a = a, b = b, kind = kind, portalId = portalId, length = length }
		table.insert(edges, edge)
		table.insert(adjacency[a], edge)
		table.insert(adjacency[b], edge)
	end

	for _, layout in layouts do
		if byId[layout.id] then
			log.warn("layout %s given twice; the second copy is ignored", layout.id)
			continue
		end
		byId[layout.id] = layout
		local origin = WorldConfig.levelOrigin(layout.id)
		local rooms = LayoutSchema.indexRooms(layout)

		for _, room in layout.rooms do
			addNode({
				id = ZoneGraph.roomNodeId(layout.id, room.id),
				kind = "Room",
				layoutId = layout.id,
				center = roomCenter(origin, room),
				roomKind = room.kind,
			})
		end

		local vents = layout.vents
		local ventNodes: { [string]: VentNodeSpec } = {}
		if vents then
			for _, node in vents.nodes do
				ventNodes[node.id] = node
				addNode({
					id = ZoneGraph.ventNodeId(layout.id, node.id),
					kind = "VentNode",
					layoutId = layout.id,
					center = ventCenter(origin, node),
				})
			end
		end

		for _, door in layout.doors do
			local portalKind: Types.PortalKind? = DOOR_PORTALS[door.kind]
			if portalKind == nil then
				continue
			end
			if #door.rooms ~= 2 then
				log.warn("%s: door %s must join exactly two rooms", layout.id, door.id)
				continue
			end
			local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
			if not a or not b then
				log.warn("%s: door %s references a missing room", layout.id, door.id)
				continue
			end
			local portal = doorPortal(origin, a, b, door)
			if not portal then
				log.warn("%s: door %s rooms do not share a wall", layout.id, door.id)
				continue
			end
			local ca, cb = roomCenter(origin, a), roomCenter(origin, b)
			addEdge(
				ZoneGraph.roomNodeId(layout.id, a.id),
				ZoneGraph.roomNodeId(layout.id, b.id),
				portalKind :: Types.PortalKind,
				door.id,
				(ca - portal).Magnitude + (portal - cb).Magnitude
			)
		end

		if vents then
			for _, grate in vents.grates do
				local node, room = ventNodes[grate.node], rooms[grate.room]
				if not node or not room then
					log.warn("%s: grate %s references a missing node or room", layout.id, grate.id)
					continue
				end
				addEdge(
					ZoneGraph.roomNodeId(layout.id, room.id),
					ZoneGraph.ventNodeId(layout.id, node.id),
					"Grate",
					grate.id,
					(roomCenter(origin, room) - ventCenter(origin, node)).Magnitude
				)
			end
			for _, edge in vents.edges do
				local a, b = ventNodes[edge.a], ventNodes[edge.b]
				if not a or not b then
					log.warn("%s: duct %s-%s references a missing node", layout.id, edge.a, edge.b)
					continue
				end
				addEdge(
					ZoneGraph.ventNodeId(layout.id, a.id),
					ZoneGraph.ventNodeId(layout.id, b.id),
					"Duct",
					ZoneGraph.ductPortalId(edge.a, edge.b),
					(ventCenter(origin, a) - ventCenter(origin, b)).Magnitude
				)
			end
		end
	end

	for _, spec in WorldConfig.Stairwells do
		local lower, upper = byId[spec.from], byId[spec.to]
		if not lower or not upper then
			continue
		end
		local lowerRoom = LayoutSchema.indexRooms(lower)[spec.fromRoom]
		local upperRoom = LayoutSchema.indexRooms(upper)[spec.toRoom]
		if not lowerRoom or not upperRoom then
			log.warn("stairwell %s needs rooms %s and %s", spec.id, spec.fromRoom, spec.toRoom)
			continue
		end
		local pa, pb = towerPortal(spec, spec.from), towerPortal(spec, spec.to)
		local ca = roomCenter(WorldConfig.levelOrigin(spec.from), lowerRoom)
		local cb = roomCenter(WorldConfig.levelOrigin(spec.to), upperRoom)
		local climb = math.abs(pb.Y - pa.Y) * STAIR_PATH_PER_RISE
		local across = Vector2.new(pb.X - pa.X, pb.Z - pa.Z).Magnitude
		addEdge(
			ZoneGraph.roomNodeId(spec.from, spec.fromRoom),
			ZoneGraph.roomNodeId(spec.to, spec.toRoom),
			"Stair",
			spec.id,
			(ca - pa).Magnitude + climb + across + (pb - cb).Magnitude
		)
	end

	return { nodes = nodes, edges = edges, adjacency = adjacency }
end

--------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------

local function otherEnd(edge: ZoneEdge, from: string): string
	return if edge.a == from then edge.b else edge.a
end

-- Breadth-first flood from `from`, never crossing a blocked portal; `layoutId` keeps it inside one layout.
local function flood(graph: Graph, from: string, blocked: Types.BlockedSet?, layoutId: string?): { [string]: boolean }
	local seen: { [string]: boolean } = {}
	local start = graph.nodes[from]
	if not start or (layoutId ~= nil and start.layoutId ~= layoutId) then
		return seen
	end
	local block: Types.BlockedSet = blocked or {}
	seen[from] = true
	local queue: { string } = { from }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, edge in (graph.adjacency[current] or {}) :: { ZoneEdge } do
			if block[edge.portalId] then
				continue
			end
			local nextId = otherEnd(edge, current)
			if seen[nextId] then
				continue
			end
			local node = graph.nodes[nextId]
			if not node or (layoutId ~= nil and node.layoutId ~= layoutId) then
				continue
			end
			seen[nextId] = true
			table.insert(queue, nextId)
		end
	end
	return seen
end

-- Every node reachable from `from` without crossing a blocked portal (includes `from` itself when it exists).
function ZoneGraph.reachable(graph: Graph, from: string, blocked: Types.BlockedSet?): { [string]: boolean }
	return flood(graph, from, blocked, nil)
end

type QueueEntry = { id: string, distance: number, seq: number }

local function before(a: QueueEntry, b: QueueEntry): boolean
	if a.distance ~= b.distance then
		return a.distance < b.distance
	end
	return a.seq < b.seq
end

local function push(heap: { QueueEntry }, entry: QueueEntry)
	table.insert(heap, entry)
	local i = #heap
	while i > 1 do
		local parent = i // 2
		if not before(heap[i], heap[parent]) then
			break
		end
		heap[i], heap[parent] = heap[parent], heap[i]
		i = parent
	end
end

local function pop(heap: { QueueEntry }): QueueEntry
	local top = heap[1]
	local last = table.remove(heap) :: QueueEntry
	local count = #heap
	if count > 0 then
		heap[1] = last
		local i = 1
		while true do
			local left, right = i * 2, i * 2 + 1
			local smallest = i
			if left <= count and before(heap[left], heap[smallest]) then
				smallest = left
			end
			if right <= count and before(heap[right], heap[smallest]) then
				smallest = right
			end
			if smallest == i then
				break
			end
			heap[i], heap[smallest] = heap[smallest], heap[i]
			i = smallest
		end
	end
	return top
end

-- Shortest route by edge length from `from` to `to` that never crosses a blocked portal. Returns the node ids
-- along it (both ends included) and its length, or nil and math.huge when `to` cannot be reached.
function ZoneGraph.shortestPath(
	graph: Graph,
	from: string,
	to: string,
	blocked: Types.BlockedSet?
): ({ string }?, number)
	if not graph.nodes[from] or not graph.nodes[to] then
		return nil, math.huge
	end
	if from == to then
		return { from }, 0
	end
	local block: Types.BlockedSet = blocked or {}
	local distance: { [string]: number } = { [from] = 0 }
	local previous: { [string]: string } = {}
	local settled: { [string]: boolean } = {}
	local heap: { QueueEntry } = {}
	local seq = 0
	push(heap, { id = from, distance = 0, seq = seq })
	while #heap > 0 do
		local entry = pop(heap)
		local current = entry.id
		if settled[current] then
			continue
		end
		settled[current] = true
		if current == to then
			break
		end
		for _, edge in (graph.adjacency[current] or {}) :: { ZoneEdge } do
			if block[edge.portalId] then
				continue
			end
			local nextId = otherEnd(edge, current)
			if settled[nextId] or not graph.nodes[nextId] then
				continue
			end
			local candidate = entry.distance + edge.length
			local known = distance[nextId]
			if known == nil or candidate < known - 1e-9 then
				distance[nextId] = candidate
				previous[nextId] = current
				seq += 1
				push(heap, { id = nextId, distance = candidate, seq = seq })
			end
		end
	end
	local total = distance[to]
	if total == nil then
		return nil, math.huge
	end
	local reversed: { string } = { to }
	local cursor = to
	while cursor ~= from do
		cursor = previous[cursor]
		table.insert(reversed, cursor)
	end
	local path: { string } = {}
	for i = #reversed, 1, -1 do
		table.insert(path, reversed[i])
	end
	return path, total
end

-- True when the layout's exit room is reachable from its entry room inside that layout (stairs to other levels
-- never count) without crossing a blocked portal.
function ZoneGraph.isLevelSolvable(graph: Graph, layout: Layout, blocked: Types.BlockedSet?): boolean
	local entry = ZoneGraph.roomNodeId(layout.id, layout.entry)
	local exit = ZoneGraph.roomNodeId(layout.id, layout.exit)
	if not graph.nodes[entry] or not graph.nodes[exit] then
		return false
	end
	return flood(graph, entry, blocked, layout.id)[exit] == true
end

-- The worst case a run can produce on `layout`: every Gate door shut and every Lockable grate locked.
function ZoneGraph.worstCaseBlocked(layout: Layout): Types.BlockedSet
	local blocked: Types.BlockedSet = {}
	for _, door in layout.doors do
		if door.kind == "Gate" then
			blocked[door.id] = true
		end
	end
	local vents = layout.vents
	if vents then
		for _, grate in vents.grates do
			if grate.lockable then
				blocked[grate.id] = true
			end
		end
	end
	return blocked
end

-- Ids (in layout room order) of the non-Chase rooms whose walls the duct segment a-b runs inside: rooms whose rect
-- lies within AdjacentRange studs of a chase the segment runs through, along the stretch of that chase the
-- segment occupies (its span plus the duct's outer half-width plus AdjacentRange). A segment that runs through no
-- chase (a malformed layout) reports the non-Chase rooms within AdjacentRange of the segment itself.
function ZoneGraph.adjacentZones(layout: Layout, a: VentNodeSpec, b: VentNodeSpec): { string }
	local x0, x1 = math.min(a.x, b.x), math.max(a.x, b.x)
	local z0, z1 = math.min(a.z, b.z), math.max(a.z, b.z)
	local chases: { Rect } = {}
	for _, room in layout.rooms do
		if room.kind == "Chase" and segmentInside(room.rect, x0, x1, z0, z1) then
			table.insert(chases, room.rect)
		end
	end
	local reach = DUCT_HALF_OUTER + ADJACENT_RANGE
	local out: { string } = {}
	for _, room in layout.rooms do
		if room.kind == "Chase" then
			continue
		end
		local near = false
		if #chases > 0 then
			for _, chase in chases do
				if
					besideRect(room.rect, chase, ADJACENT_RANGE)
					and besideSpan(room.rect, chase, x0, x1, z0, z1, reach)
				then
					near = true
					break
				end
			end
		else
			local r = room.rect
			near = gap(r.x, r.x + r.w, x0, x1) <= ADJACENT_RANGE + EPS
				and gap(r.z, r.z + r.d, z0, z1) <= ADJACENT_RANGE + EPS
		end
		if near then
			table.insert(out, room.id)
		end
	end
	return out
end

return table.freeze(ZoneGraph)
