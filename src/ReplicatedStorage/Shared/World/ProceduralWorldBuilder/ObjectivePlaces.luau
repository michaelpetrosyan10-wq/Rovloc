--!strict
-- ObjectivePlaces: pure layout maths over the floor objectives' anchors, shared by the specs and the web data notes.
--
--   places(layout)            every objective spot of a layout: the item candidates, the stations and the locks
--   hideSpots(layout)         where a player can get out of the Creature's way on that floor:
--                               Locker      a hideable locker (every floor)
--                               Barrel      a steel drum to climb into (tunnel floors)
--                               Cabinet     a tall slatted steel cabinet (tunnel floors)
--                               Vent        the mouth of a grate the director never locks
--                               DarkCorner  a room corner or a pillar no burning light reaches (an old basement
--                                           without tunnels, where nothing hunted; never on a tunnel floor)
--   nearestHide(layout, place) the closest hide spot the place can use, with its distance (straight line; lockers and
--                              vents only count in the place's own room or a room joined to it by a doorway; on a
--                              tunnel floor every locker, barrel and cabinet counts, by the walk to it, TunnelRules)
--   arrivalPoint(layout, room) where the squad arrives in a room: the centroid of its PlayerSpawn anchors
--   entryPoint(layout)         the arrival point of the layout's entry room
--   entries(layout)            every way a run may enter the floor: the entry room and every entry vestibule candidate
--                              (WorldConfig.Stairwells arriving on it), with their arrival points
--   walkDistance(layout, fromRoom, from, toRoom, to)
--                              studs walked between two floor points: straight lines across rooms (rooms are convex
--                              rects) from door to door, and crawled through the vents a squad can always use, in the
--                              worst case a run produces (every Gate shut, every lockable grate locked). math.huge
--                              when there is no way.
--   entryDistance(layout, place) walkDistance to the place from the nearest of the entries (whichever stairwell a
--                              run arrives by, it is never close)
--   quarter(pos)               which quarter of the footprint a point lies in (1 NW, 2 NE, 3 SW, 4 SE; split at its
--                              centre), for the pick spread rule
--   standingSpot(layout, anchor) where a careful player stands to take an item: beside it on its room's floor, in sight
--                              of it, TrapClear from every trap spot and walked to from a doorway without a foot on
--                              any trap's pan (the guard traps' fairness rule), with that walk; or nil
-- ObjectiveConfig.HideReach is how close a hiding spot must be; ObjectiveConfig.EntryClearance how far every item
-- candidate is walked from the entry; ObjectiveConfig.PickSpacing how far apart the items of one run lie.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local BearTrapBuilder = require(script.Parent.Props.BearTrapBuilder)
local DoorBuilder = require(script.Parent.Props.DoorBuilder)
local HideBuilder = require(script.Parent.Props.HideBuilder)
local PropKit = require(script.Parent.Props.PropKit)
local TunnelRules = require(script.Parent.TunnelRules)

type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor

export type HideKind = "Locker" | "Barrel" | "Cabinet" | "Vent" | "DarkCorner"

export type Place = { id: string, kind: Enums.AnchorKind, room: string, pos: Vector3 }

export type Hide = { kind: HideKind, id: string, room: string, pos: Vector3, distance: number }

local ObjectivePlaces = {}

ObjectivePlaces.CornerInset = 1.5

local STATION_KINDS: { [string]: boolean } = {
	BreakerPanel = true,
	ExitLock = true,
}

-- Every objective spot of `layout` in layout order: the floor's item candidates, its stations and its locks.
function ObjectivePlaces.places(layout: Layout): { Place }
	local spec = ObjectiveConfig.forLevel(layout.id)
	local item = if spec then spec.item else nil
	local out: { Place } = {}
	for _, anchor in layout.anchors do
		if (item and anchor.kind == item.candidate) or STATION_KINDS[anchor.kind] then
			table.insert(out, { id = anchor.id, kind = anchor.kind, room = anchor.room, pos = anchor.pos })
		end
	end
	return out
end

-- Rooms joined to `room` by a passable door or doorway (and the room itself).
local function neighbours(layout: Layout, room: string): { [string]: boolean }
	local out: { [string]: boolean } = { [room] = true }
	for _, door in layout.doors do
		if door.kind == "Boarded" or #door.rooms ~= 2 then
			continue
		end
		if door.rooms[1] == room then
			out[door.rooms[2]] = true
		elseif door.rooms[2] == room then
			out[door.rooms[1]] = true
		end
	end
	return out
end

local function litAt(layout: Layout, point: Vector3): boolean
	for _, room in layout.rooms do
		for _, light in (room.lights or {}) :: { LayoutSchema.Light } do
			local flat = Vector3.new(light.pos.X, 0, light.pos.Z)
			if not light.broken and (flat - point).Magnitude < light.range then
				return true
			end
		end
	end
	return false
end

-- Room corners (and the far sides of pillars) no burning light reaches.
local function darkCorners(layout: Layout): { Hide }
	local out: { Hide } = {}
	for _, room in layout.rooms do
		if room.kind == "Chase" or room.kind == "Airlock" or room.kind == "Stairwell" or room.kind == "Solid" then
			continue
		end
		local r = room.rect
		local inset = ObjectivePlaces.CornerInset
		for i, corner in
			{
				Vector3.new(r.x + inset, 0, r.z + inset),
				Vector3.new(r.x + r.w - inset, 0, r.z + inset),
				Vector3.new(r.x + inset, 0, r.z + r.d - inset),
				Vector3.new(r.x + r.w - inset, 0, r.z + r.d - inset),
			}
		do
			if not litAt(layout, corner) then
				table.insert(
					out,
					{ kind = "DarkCorner", id = room.id .. "#" .. i, room = room.id, pos = corner, distance = 0 }
				)
			end
		end
	end
	for i, pillar in (layout.pillars or {}) :: { LayoutSchema.Pillar } do
		local point = Vector3.new(pillar.x, 0, pillar.z)
		if not litAt(layout, point) then
			table.insert(out, {
				kind = "DarkCorner",
				id = string.format("%s#pillar%d", pillar.room, i),
				room = pillar.room,
				pos = point,
				distance = 0,
			})
		end
	end
	return out
end

-- Every hide spot of `layout` (distance 0; nearestHide fills it in).
function ObjectivePlaces.hideSpots(layout: Layout): { Hide }
	local out: { Hide } = {}
	for _, anchor in layout.anchors do
		if anchor.kind == "Locker" or anchor.kind == "Barrel" or anchor.kind == "Cabinet" then
			local kind: HideKind = anchor.kind :: any
			table.insert(out, { kind = kind, id = anchor.id, room = anchor.room, pos = anchor.pos, distance = 0 })
		end
	end
	local vents = layout.vents
	if vents then
		local nodes: { [string]: LayoutSchema.VentNodeSpec } = {}
		for _, node in vents.nodes do
			nodes[node.id] = node
		end
		for _, grate in vents.grates do
			local node = nodes[grate.node]
			if node and not grate.lockable then
				table.insert(out, {
					kind = "Vent",
					id = grate.id,
					room = grate.room,
					pos = Vector3.new(node.x, LayoutSchema.ventNodeY(node), node.z),
					distance = 0,
				})
			end
		end
	end
	if layout.id == "Level0_Basement" and not layout.tunnels then
		for _, corner in darkCorners(layout) do
			table.insert(out, corner)
		end
	end
	return out
end

type TunnelHides = { graph: TunnelRules.WalkGraph, dist: { number }, hides: { Hide } }
local tunnelHideCache: { [Layout]: TunnelHides } = setmetatable({}, { __mode = "k" }) :: any

-- On a tunnel floor: the walk from `place` to its nearest locker, barrel or cabinet (on foot, crawlways shut).
local function nearestTunnelHide(layout: Layout, place: Place): Hide?
	local cached = tunnelHideCache[layout]
	if not cached then
		local graph = TunnelRules.walkGraph(layout :: any, false)
		local hides: { Hide } = {}
		for _, hide in ObjectivePlaces.hideSpots(layout) do
			if hide.kind == "Locker" or hide.kind == "Barrel" or hide.kind == "Cabinet" then
				table.insert(hides, hide)
			end
		end
		cached = { graph = graph, dist = {}, hides = hides }
		tunnelHideCache[layout] = cached
	end
	local c = cached :: TunnelHides
	local p = Vector2.new(place.pos.X, place.pos.Z)
	local dist = TunnelRules.distances(c.graph, TunnelRules.seedsAt(c.graph, place.room, p))
	local best: Hide? = nil
	for _, hide in c.hides do
		local q = Vector2.new(hide.pos.X, hide.pos.Z)
		local d = TunnelRules.reach(c.graph, dist, hide.room, q, if hide.room == place.room then { p } else nil)
		if best == nil or d < (best :: Hide).distance then
			best = { kind = hide.kind, id = hide.id, room = hide.room, pos = hide.pos, distance = d }
		end
	end
	return best
end

-- The closest hide spot `place` can use on `layout`, or nil when the floor has none in reach of it.
function ObjectivePlaces.nearestHide(layout: Layout, place: Place): Hide?
	if layout.tunnels then
		return nearestTunnelHide(layout, place)
	end
	local best: Hide? = nil
	local function consider(hide: Hide, distance: number)
		if best == nil or distance < (best :: Hide).distance then
			best = { kind = hide.kind, id = hide.id, room = hide.room, pos = hide.pos, distance = distance }
		end
	end
	local near = neighbours(layout, place.room)
	local flat = Vector3.new(place.pos.X, 0, place.pos.Z)
	for _, hide in ObjectivePlaces.hideSpots(layout) do
		local d = (Vector3.new(hide.pos.X, 0, hide.pos.Z) - flat).Magnitude
		if hide.kind == "DarkCorner" then
			if hide.room == place.room then
				consider(hide, d)
			end
		elseif near[hide.room] then
			consider(hide, d)
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- Walking distances (the fairness rules: never right at the door you came in by)
--------------------------------------------------------------------------------

-- Where the squad arrives in room `roomId` of `layout`: the centroid of the room's PlayerSpawn anchors (the room's
-- centre when it has none).
function ObjectivePlaces.arrivalPoint(layout: Layout, roomId: string): Vector3
	local sum, count = Vector3.zero, 0
	for _, anchor in layout.anchors do
		if anchor.kind == "PlayerSpawn" and anchor.room == roomId then
			sum += Vector3.new(anchor.pos.X, 0, anchor.pos.Z)
			count += 1
		end
	end
	if count > 0 then
		return sum / count
	end
	local room = LayoutSchema.indexRooms(layout)[roomId]
	local centre = if room then LayoutSchema.rectCenter(room.rect) else Vector2.zero
	return Vector3.new(centre.X, 0, centre.Y)
end

-- Where the squad arrives on `layout` by default: the arrival point of its entry room.
function ObjectivePlaces.entryPoint(layout: Layout): Vector3
	return ObjectivePlaces.arrivalPoint(layout, layout.entry)
end

export type Entry = { room: string, pos: Vector3 }

-- Every room a run may enter `layout` by: its entry room and every entry vestibule candidate (the upper rooms of the
-- stairwells that arrive on it), each with its arrival point, in that order.
function ObjectivePlaces.entries(layout: Layout): { Entry }
	local out: { Entry } = { { room = layout.entry, pos = ObjectivePlaces.entryPoint(layout) } }
	for _, spec in WorldConfig.Stairwells do
		if spec.to == layout.id and spec.toRoom ~= layout.entry then
			table.insert(out, { room = spec.toRoom, pos = ObjectivePlaces.arrivalPoint(layout, spec.toRoom) })
		end
	end
	return out
end

type WalkNode = { pos: Vector2, links: { { to: string, length: number } } }
type WalkGraph = { nodes: { [string]: WalkNode }, members: { [string]: { string } } }

local walkCache: { [Layout]: WalkGraph } = setmetatable({}, { __mode = "k" }) :: any

local function flat(v: Vector3): Vector2
	return Vector2.new(v.X, v.Z)
end

-- The floor plan as portals: every passable door's centre on its wall and every vent node, joined across each room
-- (straight lines, every pair of the room's portals) and along the ducts. Worst case: Gate doors shut, lockable
-- grates locked.
local function walkGraph(layout: Layout): WalkGraph
	local cached = walkCache[layout]
	if cached then
		return cached
	end
	local nodes: { [string]: WalkNode } = {}
	local members: { [string]: { string } } = {}
	local function node(id: string, pos: Vector2)
		if not nodes[id] then
			nodes[id] = { pos = pos, links = {} }
		end
	end
	local function member(room: string, id: string)
		members[room] = members[room] or {}
		table.insert(members[room], id)
	end
	local function link(a: string, b: string)
		local length = (nodes[a].pos - nodes[b].pos).Magnitude
		table.insert(nodes[a].links, { to = b, length = length })
		table.insert(nodes[b].links, { to = a, length = length })
	end
	local rooms = LayoutSchema.indexRooms(layout)
	for _, door in layout.doors do
		if door.kind == "Boarded" or door.kind == "Gate" or #door.rooms ~= 2 then
			continue
		end
		local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
		local edge = if a and b then LayoutSchema.sharedEdge(a.rect, b.rect) else nil
		if not edge then
			continue
		end
		local id = "door:" .. door.id
		node(id, if edge.axis == "X" then Vector2.new(edge.coord, door.at) else Vector2.new(door.at, edge.coord))
		member(door.rooms[1], id)
		member(door.rooms[2], id)
	end
	local vents = layout.vents
	if vents then
		for _, spec in vents.nodes do
			node("vent:" .. spec.id, Vector2.new(spec.x, spec.z))
		end
		for _, edge in vents.edges do
			if nodes["vent:" .. edge.a] and nodes["vent:" .. edge.b] then
				link("vent:" .. edge.a, "vent:" .. edge.b)
			end
		end
		for _, grate in vents.grates do
			if not grate.lockable and nodes["vent:" .. grate.node] then
				member(grate.room, "vent:" .. grate.node)
			end
		end
	end
	-- rooms in id order (never the table's hash order), so the link lists are the same in every Luau build
	local roomIds: { string } = {}
	for room in members do
		table.insert(roomIds, room)
	end
	table.sort(roomIds)
	for _, room in roomIds do
		local list = members[room]
		for i = 1, #list do
			for j = i + 1, #list do
				link(list[i], list[j])
			end
		end
	end
	local graph: WalkGraph = { nodes = nodes, members = members }
	walkCache[layout] = graph
	return graph
end

-- Studs walked between `from` (in room `fromRoom`) and `to` (in `toRoom`) on `layout` (see the header).
function ObjectivePlaces.walkDistance(
	layout: Layout,
	fromRoom: string,
	from: Vector3,
	toRoom: string,
	to: Vector3
): number
	local a, b = flat(from), flat(to)
	if fromRoom == toRoom then
		return (a - b).Magnitude
	end
	local graph = walkGraph(layout)
	local distance: { [string]: number } = {}
	local settled: { [string]: boolean } = {}
	for _, id in graph.members[fromRoom] or {} :: { string } do
		local d = (graph.nodes[id].pos - a).Magnitude
		if distance[id] == nil or d < distance[id] then
			distance[id] = d
		end
	end
	local goal: { [string]: boolean } = {}
	for _, id in graph.members[toRoom] or {} :: { string } do
		goal[id] = true
	end
	local best = math.huge
	while true do
		-- the nearest unsettled node, ties to the smaller id (never the table's hash order)
		local current: string? = nil
		for id, d in distance do
			if settled[id] then
				continue
			end
			local nearest = current
			if nearest == nil or d < distance[nearest] or (d == distance[nearest] and id < nearest) then
				current = id
			end
		end
		if current == nil or distance[current] >= best then
			break
		end
		settled[current] = true
		local here = distance[current]
		if goal[current] then
			best = math.min(best, here + (graph.nodes[current].pos - b).Magnitude)
		end
		for _, l in graph.nodes[current].links do
			local candidate = here + l.length
			if not settled[l.to] and (distance[l.to] == nil or candidate < distance[l.to]) then
				distance[l.to] = candidate
			end
		end
	end
	return best
end

-- Studs walked to `place` from the nearest way in to `layout` (ObjectivePlaces.entries: the entry room and every entry
-- vestibule candidate), so no run's entry is close to it.
function ObjectivePlaces.entryDistance(layout: Layout, place: Place): number
	local best = math.huge
	for _, entry in ObjectivePlaces.entries(layout) do
		best = math.min(best, ObjectivePlaces.walkDistance(layout, entry.room, entry.pos, place.room, place.pos))
	end
	return best
end

-- The quarter of the footprint `pos` lies in: 1 north-west, 2 north-east, 3 south-west, 4 south-east.
function ObjectivePlaces.quarter(pos: Vector3): number
	local size = WorldConfig.FootprintSize
	local east = if pos.X >= size.X / 2 then 1 else 0
	local south = if pos.Z >= size.Y / 2 then 2 else 0
	return 1 + east + south
end

--------------------------------------------------------------------------------
-- Guarded items: the careless walk onto the guard, the careful player's spot beside the item
--------------------------------------------------------------------------------

export type Stand = {
	pos: Vector3, -- level-local, on the floor
	reach: number, -- flat studs to the item
	trapClear: number, -- flat studs to the nearest trap spot
	-- the walk there (level-local X, Z): from just inside a doorway of the item's room, every turn, then the spot; each
	-- leg is straight and keeps the body clear and the foot off every pan
	path: { Vector2 },
}

-- The careless walk to an item: in by the doorway the squad arrives by and the shortest way on to where the item's
-- Pickup prompt first answers, with an eye for nothing but the item. A guard trap lies on it. (The squad is taken to
-- come on foot, crawlways shut; the layouts and TunnelPlanner keep the doorway and the side it is come to from the same
-- for a squad that crawls, which Objectives.spec holds them to.)
export type Approach = {
	door: string, -- the arrival doorway: of the item's room's doorways, the one walked to first from the floor's ways in
	-- the walk for each way that doorway's open leaf may hang (an ordinary door's: on the far face, or on this room's
	-- beside either jamb; a doorway has none), each in level-local (X, Z) points: the start (ApproachRun out in the
	-- room the doorway opens from, the way the squad comes: back along a stub run, or along the middle of a run the
	-- room opens off), every bend round the jambs and whatever stands in the room, then the first point where the prompt
	-- answers
	walks: { { Vector2 } },
	guardGap: number, -- the farthest any of them passes from the centre of the item's guard trap (math.huge: no guard)
}

-- An item is taken standing beside it: on the floor of its room, StandNear..StandReach flat studs off it (well inside
-- its Pickup prompt's PromptReach), the body (BodyRadius) clear of the walls and of everything standing on the floor,
-- TrapClear flat studs from the centre of every TrapCandidate (whichever the run arms: a guard, another fuse's, the
-- seeded rest) and in sight of it from the eye (StandEye over the floor).
ObjectivePlaces.StandNear = 1.6
ObjectivePlaces.StandReach = 4
ObjectivePlaces.TrapClear = 2.5 -- a trap's pan, a body and a margin
ObjectivePlaces.BodyRadius = 1 -- the web's capsule; an R15 root is two studs across
ObjectivePlaces.StandEye = 4.5 -- the root's 3 over the floor plus the standing eye's 1.5
ObjectivePlaces.StepHeight = 1.6 -- a box no taller is stepped onto, not walked round
ObjectivePlaces.BodyHeight = 5.2
-- The walk to the spot never sets a foot on a pan: a trap is built at a random yaw, so its 2.2-stud square pan reaches
-- up to half its diagonal from the centre.
ObjectivePlaces.PanReach = math.sqrt(2) * BearTrapBuilder.TriggerSize.X / 2
-- A foot within half the pan's side of the centre is on it whatever the yaw: the careless walk passes that close.
ObjectivePlaces.PanCore = BearTrapBuilder.TriggerSize.X / 2
-- How far from the root (StandEye - 1.5 over the floor) an item's Pickup prompt answers, through anything.
ObjectivePlaces.PromptReach = PropKit.PromptDistance
-- How far out in the room beyond the arrival doorway the careless walk starts: straight out, or along it, down the
-- middle of the room (at most this far off the doorway's wall).
ObjectivePlaces.ApproachRun = 8

local STAND_GRID = 0.25 -- the walk's grid (studs)
local ITEM_LIFT = 0.25 -- the item's prompt point over its anchor
local ROOT_HEIGHT = ObjectivePlaces.StandEye - 1.5
local LEAF_MARGIN = 0.3 -- an open leaf's thickness, its handles and a crooked hang's lean
local SIGHT_STEP = 0.1 -- the careless walk's legs are tested this finely
local RIM_POINTS = 36 -- where the prompt's reach is tried round its rim when the nearest point of it is blocked
-- What stands on the floor at the anchors of these kinds, for the body to walk round and the eye to look past (width
-- along the anchor's RightVector, height, depth along its LookVector; the box centred on the anchor's floor point):
-- the hideable locker (LockerBuilder's outer box), the barrel and the cabinet (HideBuilder), and the breaker panel
-- (BreakerPanelBuilder's cabinet on its wall with its door swung open: 3.4 out from the wall face).
local BLOCKERS: { [string]: Vector3 } = {
	Locker = Vector3.new(2.9, 7.7, 2.6),
	Barrel = Vector3.new(HideBuilder.Footprints.Barrel.X, 4.2, HideBuilder.Footprints.Barrel.Y),
	Cabinet = Vector3.new(HideBuilder.Footprints.Cabinet.X, 7.8, HideBuilder.Footprints.Cabinet.Y),
	BreakerPanel = Vector3.new(4.2, 6.6, 7.2),
}

-- A box on the floor plan: centre, its local X axis (ux, uz), half extents along X and along its local Z, a height
-- band.
type Box = { cx: number, cz: number, ux: number, uz: number, hu: number, hv: number, y0: number, y1: number }

local function anchorBox(anchor: Anchor, size: Vector3): Box
	local yaw = math.rad(anchor.yaw or 0)
	return {
		cx = anchor.pos.X,
		cz = anchor.pos.Z,
		ux = math.cos(yaw),
		uz = -math.sin(yaw),
		hu = size.X / 2,
		hv = size.Z / 2,
		y0 = anchor.pos.Y,
		y1 = anchor.pos.Y + size.Y,
	}
end

local function rectBox(r: LayoutSchema.Rect, y0: number, y1: number): Box
	return { cx = r.x + r.w / 2, cz = r.z + r.d / 2, ux = 1, uz = 0, hu = r.w / 2, hv = r.d / 2, y0 = y0, y1 = y1 }
end

local function boxLocal(b: Box, x: number, z: number): (number, number)
	local dx, dz = x - b.cx, z - b.cz
	return dx * b.ux + dz * b.uz, dz * b.ux - dx * b.uz
end

-- Flat gap from (x, z) to the box (0 inside it).
local function boxGap(b: Box, x: number, z: number): number
	local u, v = boxLocal(b, x, z)
	local gu, gv = math.max(math.abs(u) - b.hu, 0), math.max(math.abs(v) - b.hv, 0)
	return math.sqrt(gu * gu + gv * gv)
end

-- Whether the segment a -> c passes through the box (slabs in the box's own frame).
local function segmentHits(b: Box, a: Vector3, c: Vector3): boolean
	local au, av = boxLocal(b, a.X, a.Z)
	local cu, cv = boxLocal(b, c.X, c.Z)
	local t0, t1 = 0, 1
	for _, slab in { { au, cu, -b.hu, b.hu }, { a.Y, c.Y, b.y0, b.y1 }, { av, cv, -b.hv, b.hv } } do
		local p0, p1, lo, hi = slab[1], slab[2], slab[3], slab[4]
		local d = p1 - p0
		if math.abs(d) < 1e-9 then
			if p0 < lo or p0 > hi then
				return false
			end
		else
			local ta, tb = (lo - p0) / d, (hi - p0) / d
			if ta > tb then
				ta, tb = tb, ta
			end
			t0, t1 = math.max(t0, ta), math.min(t1, tb)
			if t0 > t1 then
				return false
			end
		end
	end
	return true
end

-- The floor of `room` inside its walls (the footprint's own edges carry the thicker exterior wall).
local function floorRect(room: LayoutSchema.Room): LayoutSchema.Rect
	local size = WorldConfig.FootprintSize
	local r = room.rect
	local function inset(onEdge: boolean): number
		return (if onEdge then WorldConfig.ExteriorWallThickness else WorldConfig.WallThickness) / 2
	end
	local x0 = r.x + inset(r.x <= 0.01)
	local x1 = r.x + r.w - inset(r.x + r.w >= size.X - 0.01)
	local z0 = r.z + inset(r.z <= 0.01)
	local z1 = r.z + r.d - inset(r.z + r.d >= size.Y - 0.01)
	return { x = x0, z = z0, w = math.max(0, x1 - x0), d = math.max(0, z1 - z0) }
end

-- Whether (x, z) lies in `r` at least `margin` inside its edges (to float32 rounding: points come as Vector2s).
local function within(r: LayoutSchema.Rect, x: number, z: number, margin: number): boolean
	return x >= r.x + margin - 1e-4
		and x <= r.x + r.w - margin + 1e-4
		and z >= r.z + margin - 1e-4
		and z <= r.z + r.d - margin + 1e-4
end

-- A passable doorway of a room: the door, the room it opens into and the wall line they share.
type Way = { door: LayoutSchema.Door, other: LayoutSchema.Room, edge: LayoutSchema.SharedEdge }

local function doorways(layout: Layout, rooms: { [string]: LayoutSchema.Room }, room: LayoutSchema.Room): { Way }
	local out: { Way } = {}
	for _, door in layout.doors do
		if door.kind == "Boarded" or #door.rooms ~= 2 or (door.rooms[1] ~= room.id and door.rooms[2] ~= room.id) then
			continue
		end
		local other = rooms[if door.rooms[1] == room.id then door.rooms[2] else door.rooms[1]]
		local edge = if other then LayoutSchema.sharedEdge(room.rect, other.rect) else nil
		if other and edge then
			table.insert(out, { door = door, other = other, edge = edge })
		end
	end
	return out
end

-- What a body meets on the floor of `room`: its floor inside the walls, what it walks round (`solid`: plant taller than
-- a step, pillars, the blockers on its anchors), what hides an item from the eye (`sight`), where the open leaf of each
-- ordinary door may stand (`leaves`: one box beside each jamb on this room's face, both solid and in the way of the
-- eye), its doorways and every trap spot of the floor (`traps`, any room: a pan is a pan).
type Leaf = { door: string, jamb: number, box: Box }
type RoomModel = {
	floor: LayoutSchema.Rect,
	solid: { Box },
	sight: { Box },
	leaves: { Leaf },
	traps: { Vector2 },
	ways: { Way },
}

local function roomModel(layout: Layout, rooms: { [string]: LayoutSchema.Room }, room: LayoutSchema.Room): RoomModel
	local model: RoomModel = {
		floor = floorRect(room),
		solid = {},
		sight = {},
		leaves = {},
		traps = {},
		ways = doorways(layout, rooms, room),
	}
	for _, platform in (layout.platforms or {}) :: { LayoutSchema.Platform } do
		if platform.room == room.id then
			local box = rectBox(platform.rect, platform.top - platform.thickness, platform.top)
			table.insert(model.sight, box)
			if box.y1 > ObjectivePlaces.StepHeight and box.y0 < ObjectivePlaces.BodyHeight then
				table.insert(model.solid, box)
			end
		end
	end
	for _, pillar in (layout.pillars or {}) :: { LayoutSchema.Pillar } do
		if pillar.room == room.id then
			local half = pillar.size / 2 + 0.3 -- the base trim
			local box = { cx = pillar.x, cz = pillar.z, ux = 1, uz = 0, hu = half, hv = half, y0 = 0, y1 = math.huge }
			table.insert(model.solid, box)
			table.insert(model.sight, box)
		end
	end
	-- an ordinary door stands open (DoorBuilder: 90 to 110 degrees) off either jamb, on either face of its wall: on
	-- this room's face its leaf fences off the floor beside the opening, out past its width
	for _, way in model.ways do
		local door, edge = way.door, way.edge
		if door.kind ~= "Door" then
			continue
		end
		local width = LayoutSchema.doorWidth(door)
		local out, aside = DoorBuilder.staticLeafReach(width)
		local centre = if edge.axis == "X" then room.rect.x + room.rect.w / 2 else room.rect.z + room.rect.d / 2
		local v0 = edge.coord
		local v1 = edge.coord + (if centre > edge.coord then 1 else -1) * (out + LEAF_MARGIN)
		for _, away in { -1, 1 } do
			local jamb = door.at + away * width / 2
			local u0, u1 = jamb, jamb + away * (aside + LEAF_MARGIN)
			local r: LayoutSchema.Rect = if edge.axis == "X"
				then LayoutSchema.rect(math.min(v0, v1), math.min(u0, u1), math.abs(v1 - v0), math.abs(u1 - u0))
				else LayoutSchema.rect(math.min(u0, u1), math.min(v0, v1), math.abs(u1 - u0), math.abs(v1 - v0))
			table.insert(
				model.leaves,
				{ door = door.id, jamb = away, box = rectBox(r, 0, LayoutSchema.doorHeight(door)) }
			)
		end
	end
	for _, other in layout.anchors do
		local size = BLOCKERS[other.kind]
		if size and other.room == room.id then
			local box = anchorBox(other, size)
			table.insert(model.solid, box)
			table.insert(model.sight, box)
		elseif other.kind == "TrapCandidate" then
			table.insert(model.traps, Vector2.new(other.pos.X, other.pos.Z))
		end
	end
	return model
end

-- Where a careful player stands to take the item on `anchor`: walked to from one of its room's doorways with no foot
-- ever on a trap's pan (PanReach of a TrapCandidate), clear of every trap by TrapClear, the item in sight and within
-- StandNear..StandReach. Of those spots, the one with the most room to spare (from the traps, the walls and solids and
-- the reach limits; then the nearest the item). nil when there is none.
function ObjectivePlaces.standingSpot(layout: Layout, anchor: Anchor): Stand?
	local rooms = LayoutSchema.indexRooms(layout)
	local room = rooms[anchor.room]
	if not room then
		return nil
	end
	local body = ObjectivePlaces.BodyRadius
	local model = roomModel(layout, rooms, room)
	local floor = model.floor
	-- whichever jamb an ordinary door's leaf hangs from, the spot and the walk keep clear of it
	for _, leaf in model.leaves do
		table.insert(model.solid, leaf.box)
		table.insert(model.sight, leaf.box)
	end
	local function trapGap(x: number, z: number): number
		local best = math.huge
		local p = Vector2.new(x, z)
		for _, trap in model.traps do
			best = math.min(best, (trap - p).Magnitude)
		end
		return best
	end
	-- the gap from the body's centre to the walls and to the nearest solid
	local function solidGap(x: number, z: number): number
		local best = math.min(x - floor.x, floor.x + floor.w - x, z - floor.z, floor.z + floor.d - z)
		for _, box in model.solid do
			best = math.min(best, boxGap(box, x, z))
		end
		return best
	end

	-- the walk: grid cells whose body is clear and whose foot is off every pan, flooded from the doorways
	local cols = math.floor(floor.w / STAND_GRID)
	local rows = math.floor(floor.d / STAND_GRID)
	local function centre(i: number, j: number): (number, number)
		return floor.x + (i + 0.5) * STAND_GRID, floor.z + (j + 0.5) * STAND_GRID
	end
	local walkable: { [number]: boolean } = {}
	for j = 0, rows - 1 do
		for i = 0, cols - 1 do
			local x, z = centre(i, j)
			if trapGap(x, z) > ObjectivePlaces.PanReach and solidGap(x, z) >= body then
				walkable[j * cols + i] = true
			end
		end
	end
	local from: { [number]: number } = {} -- the cell each reached cell was stepped to from (a seed: itself)
	local queue: { number } = {}
	for _, way in model.ways do
		local edge = way.edge
		local half = LayoutSchema.doorWidth(way.door) / 2
		-- the cells a body stepping through the opening reaches first: along it, and in from the wall's line
		for j = 0, rows - 1 do
			for i = 0, cols - 1 do
				local cell = j * cols + i
				if not walkable[cell] or from[cell] then
					continue
				end
				local x, z = centre(i, j)
				local along = if edge.axis == "X" then z else x
				local into = math.abs((if edge.axis == "X" then x else z) - edge.coord)
				if math.abs(along - way.door.at) <= half - body + 1e-6 and into <= body + WorldConfig.WallThickness then
					from[cell] = cell
					table.insert(queue, cell)
				end
			end
		end
	end
	local head = 1
	while head <= #queue do
		local cell = queue[head]
		head += 1
		local i, j = cell % cols, cell // cols
		for _, step in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
			local ni, nj = i + step[1], j + step[2]
			if ni >= 0 and ni < cols and nj >= 0 and nj < rows then
				local next = nj * cols + ni
				if walkable[next] and not from[next] then
					from[next] = cell
					table.insert(queue, next)
				end
			end
		end
	end

	-- the spots beside the item, clear of every trap, the item in sight: the one with the most to spare
	local item = anchor.pos + Vector3.new(0, ITEM_LIFT, 0)
	local best: Stand? = nil
	local bestCell, bestSlack = -1, -math.huge
	for _, cell in queue do
		local x, z = centre(cell % cols, cell // cols)
		local reach = (Vector2.new(x, z) - Vector2.new(item.X, item.Z)).Magnitude
		local clear = trapGap(x, z)
		if
			reach < ObjectivePlaces.StandNear
			or reach > ObjectivePlaces.StandReach
			or clear < ObjectivePlaces.TrapClear
		then
			continue
		end
		local slack = math.min(
			clear - ObjectivePlaces.TrapClear,
			solidGap(x, z) - body,
			ObjectivePlaces.StandReach - reach,
			reach - ObjectivePlaces.StandNear
		)
		if slack < bestSlack or (slack == bestSlack and best ~= nil and reach >= (best :: Stand).reach) then
			continue
		end
		local eye = Vector3.new(x, ObjectivePlaces.StandEye, z)
		local seen = true
		for _, box in model.sight do
			if segmentHits(box, eye, item) then
				seen = false
				break
			end
		end
		if seen then
			best = { pos = Vector3.new(x, 0, z), reach = reach, trapClear = clear, path = {} }
			bestCell, bestSlack = cell, slack
		end
	end
	local stand = best
	if not stand then
		return nil
	end
	-- the walk back from the spot to its seed, kept at its turns
	local cells: { number } = { bestCell }
	while from[cells[#cells]] ~= cells[#cells] do
		table.insert(cells, from[cells[#cells]])
	end
	for index = #cells, 1, -1 do
		local cell = cells[index]
		local before, after = cells[index + 1], cells[index - 1]
		if before and after and (cell - before) == (after - cell) then
			continue -- straight on
		end
		local x, z = centre(cell % cols, cell // cols)
		table.insert(stand.path, Vector2.new(x, z))
	end
	return stand
end

-- Studs walked to `p` (level-local X, Z) in room `roomId` from the nearest of the floor's ways in: on foot, crawlways
-- shut, on a tunnel floor (TunnelRules' walk graph); walkDistance elsewhere.
type Arrivals = { graph: TunnelRules.WalkGraph, dist: { number } }
local arrivalCache: { [Layout]: Arrivals } = setmetatable({}, { __mode = "k" }) :: any

local function arrivalDistance(layout: Layout, roomId: string, p: Vector2): number
	if not layout.tunnels then
		local place: Place = { id = "", kind = "TrapCandidate", room = roomId, pos = Vector3.new(p.X, 0, p.Y) }
		return ObjectivePlaces.entryDistance(layout, place)
	end
	local cached = arrivalCache[layout]
	if not cached then
		local graph = TunnelRules.walkGraph(layout :: any, false)
		local seeds: { { number } } = {}
		for _, entry in ObjectivePlaces.entries(layout) do
			for _, seed in TunnelRules.seedsAt(graph, entry.room, flat(entry.pos)) do
				table.insert(seeds, seed)
			end
		end
		cached = { graph = graph, dist = TunnelRules.distances(graph, seeds) }
		arrivalCache[layout] = cached
	end
	local c = cached :: Arrivals
	return TunnelRules.reach(c.graph, c.dist, roomId, p)
end

-- The careless walk to the item on `anchor` (see Approach): in by its room's arrival doorway from ApproachRun out in
-- the room beyond (of the points that far back along a stub run, or along the middle of the run a niche opens off, the
-- one walked to first from the floor's ways in), then the shortest way round the jambs and whatever stands in the room
-- (the body a BodyRadius clear) to the nearest point where the item's prompt answers; once for each way the doorway's
-- leaf may hang. nil for a room with no doorway or no way in, or an item out of the prompt's reach of the floor.
function ObjectivePlaces.carelessWalk(layout: Layout, anchor: Anchor): Approach?
	local rooms = LayoutSchema.indexRooms(layout)
	local room = rooms[anchor.room]
	if not room then
		return nil
	end
	local body = ObjectivePlaces.BodyRadius
	local wall = WorldConfig.WallThickness
	local rise = anchor.pos.Y + ITEM_LIFT - ROOT_HEIGHT
	local reach2 = ObjectivePlaces.PromptReach ^ 2 - rise * rise
	if reach2 <= 0 then
		return nil
	end
	local reach = math.sqrt(reach2)
	local item = Vector2.new(anchor.pos.X, anchor.pos.Z)
	local model = roomModel(layout, rooms, room)

	-- the arrival doorway, and the walk's start beyond it
	local arrival: Way? = nil
	local start = Vector2.zero
	local nearest = math.huge
	for _, way in model.ways do
		if way.door.kind == "Gate" or LayoutSchema.doorCrawlOnly(layout, way.door) then
			continue
		end
		local edge = way.edge
		local centre = LayoutSchema.rectCenter(way.other.rect)
		local sign = if (if edge.axis == "X" then centre.X else centre.Y) > edge.coord then 1 else -1
		local mouth = if edge.axis == "X"
			then Vector2.new(edge.coord, way.door.at)
			else Vector2.new(way.door.at, edge.coord)
		local out = if edge.axis == "X" then Vector2.new(sign, 0) else Vector2.new(0, sign)
		local along = if edge.axis == "X" then Vector2.new(0, 1) else Vector2.new(1, 0)
		local beyond = floorRect(way.other)
		local run = ObjectivePlaces.ApproachRun
		-- along the room beyond, the squad comes down its middle (a run's centreline), never further out than `run`
		local middle = math.abs((if edge.axis == "X" then centre.X else centre.Y) - edge.coord)
		local step = out * math.clamp(middle, wall / 2 + body, run)
		for _, p in { mouth + out * run, mouth + step + along * run, mouth + step - along * run } do
			local x = math.clamp(p.X, beyond.x + body, beyond.x + beyond.w - body)
			local z = math.clamp(p.Y, beyond.z + body, beyond.z + beyond.d - body)
			local d = arrivalDistance(layout, way.other.id, Vector2.new(x, z))
			if d < nearest then
				arrival, start, nearest = way, Vector2.new(x, z), d
			end
		end
	end
	local way = arrival
	if not way then
		return nil
	end

	-- the floor the walk may use: the room and the room beyond inside their walls and the doorway between its jambs,
	-- a body clear of all of them and of what stands in the room
	local edge = way.edge
	local floor, beyond = model.floor, floorRect(way.other)
	local half = LayoutSchema.doorWidth(way.door) / 2 - body
	local across = wall / 2 + body
	local gap: LayoutSchema.Rect = if edge.axis == "X"
		then LayoutSchema.rect(edge.coord - across, way.door.at - half, 2 * across, 2 * half)
		else LayoutSchema.rect(way.door.at - half, edge.coord - across, 2 * half, 2 * across)
	-- the shortest walk with `solid` standing in the room, or nil
	local function shortest(solid: { Box }): { Vector2 }?
		local function free(x: number, z: number): boolean
			if not (within(floor, x, z, body) or within(beyond, x, z, body) or within(gap, x, z, 0)) then
				return false
			end
			for _, box in solid do
				if boxGap(box, x, z) < body - 1e-4 then
					return false
				end
			end
			return true
		end
		local function clear(a: Vector2, b: Vector2): boolean
			local steps = math.max(1, math.ceil((b - a).Magnitude / SIGHT_STEP))
			for k = 0, steps do
				local t = k / steps
				if not free(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t) then
					return false
				end
			end
			return true
		end
		-- the bends a shortest walk can take: the doorway's jambs and the corners of what stands in the room
		local nodes: { Vector2 } = { start }
		for _, x in { gap.x, gap.x + gap.w } do
			for _, z in { gap.z, gap.z + gap.d } do
				table.insert(nodes, Vector2.new(x, z))
			end
		end
		for _, box in solid do
			for _, su in { -1, 1 } do
				for _, sv in { -1, 1 } do
					local u, v = su * (box.hu + body + 0.02), sv * (box.hv + body + 0.02)
					local x, z = box.cx + u * box.ux - v * box.uz, box.cz + u * box.uz + v * box.ux
					if free(x, z) then
						table.insert(nodes, Vector2.new(x, z))
					end
				end
			end
		end
		local dist: { [number]: number } = { [1] = 0 }
		local prev: { [number]: number } = {}
		local settled: { [number]: boolean } = {}
		local total, last, lastNode = math.huge, start, 1
		while true do
			-- the nearest unsettled node, ties to the lower index (never the table's hash order)
			local current, here = 0, math.huge
			for index, d in dist do
				if not settled[index] and (d < here or (d == here and index < current)) then
					current, here = index, d
				end
			end
			if current == 0 or here >= total then
				break
			end
			settled[current] = true
			local p = nodes[current]
			local toItem = (item - p).Magnitude
			if toItem <= reach then
				total, last, lastNode = here, p, current
				break
			end
			-- the nearest point the prompt answers at, else the nearest clear one round the rim
			local nearestRim = item + (p - item) * (reach / toItem)
			if clear(p, nearestRim) then
				if here + toItem - reach < total then
					total, last, lastNode = here + toItem - reach, nearestRim, current
				end
			else
				for k = 0, RIM_POINTS - 1 do
					local angle = k * 2 * math.pi / RIM_POINTS
					local rim = item + Vector2.new(math.cos(angle), math.sin(angle)) * reach
					local length = (rim - p).Magnitude
					if here + length < total and clear(p, rim) then
						total, last, lastNode = here + length, rim, current
					end
				end
			end
			for index, v in nodes do
				local candidate = here + (v - p).Magnitude
				if
					not settled[index]
					and candidate < (dist[index] or math.huge)
					and candidate < total
					and clear(p, v)
				then
					dist[index] = candidate
					prev[index] = current
				end
			end
		end
		if total == math.huge then
			return nil
		end
		local path: { Vector2 } = {}
		local index: number? = lastNode
		while index do
			table.insert(path, 1, nodes[index])
			index = prev[index]
		end
		if (last - path[#path]).Magnitude > 1e-6 then
			table.insert(path, last)
		end
		return path
	end

	-- one walk per way the arrival doorway's leaf may hang (the other doors' leaves stand beside both their jambs)
	local fixed: { Box } = table.clone(model.solid)
	local hangs: { Box? } = { false :: any }
	for _, leaf in model.leaves do
		if leaf.door == way.door.id then
			table.insert(hangs, leaf.box)
		else
			table.insert(fixed, leaf.box)
		end
	end
	local guard: Vector2? = nil
	for _, other in layout.anchors do
		if other.id == anchor.ref and other.kind == "TrapCandidate" then
			guard = Vector2.new(other.pos.X, other.pos.Z)
		end
	end
	local walks: { { Vector2 } } = {}
	local guardGap = if guard then 0 else math.huge
	for _, hang in hangs do
		local solid = table.clone(fixed)
		if hang then
			table.insert(solid, hang)
		end
		local path = shortest(solid)
		if not path then
			return nil
		end
		table.insert(walks, path)
		if guard then
			local g = guard :: Vector2
			local near = (path[1] - g).Magnitude
			for i = 1, #path - 1 do
				local a, b = path[i], path[i + 1]
				local ab = b - a
				local t = if ab.Magnitude > 1e-9 then math.clamp((g - a):Dot(ab) / ab:Dot(ab), 0, 1) else 0
				near = math.min(near, (a + ab * t - g).Magnitude)
			end
			guardGap = math.max(guardGap, near)
		end
	end
	return { door = way.door.id, walks = walks, guardGap = guardGap }
end

return table.freeze(ObjectivePlaces)
