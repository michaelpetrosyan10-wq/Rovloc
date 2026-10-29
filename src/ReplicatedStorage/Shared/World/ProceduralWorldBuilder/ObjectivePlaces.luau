--!strict
-- ObjectivePlaces: pure layout maths over the floor objectives' anchors, shared by the specs and the web data notes.
--
--   places(layout)            every objective spot of a layout: the item candidates, the stations and the locks
--   hideSpots(layout)         where a player can get out of the Creature's way on that floor:
--                               Locker      a hideable locker (every floor)
--                               Vent        the mouth of a grate the director never locks and no hatch shuts
--                               DarkCorner  a room corner or a pillar no burning light reaches (the basement, where
--                                           nothing hunts)
--                               DryFooting  out of the water (the pool, where the Creature cannot leave the water)
--                               Cover       a plant block to crouch behind, at least CoverHeight tall (the roof)
--   nearestHide(layout, place) the closest hide spot the place can use, with its distance (straight line; lockers and
--                              vents only count in the place's own room or a room joined to it by a doorway)
--   entryPoint(layout)         where the squad arrives: the centroid of the entry room's PlayerSpawn anchors
--   walkDistance(layout, fromRoom, from, toRoom, to)
--                              studs walked between two floor points: straight lines across rooms (rooms are convex
--                              rects) from door to door, and crawled through the vents a squad can always use, in the
--                              worst case a run produces (every Gate shut, every lockable grate locked, the grates a
--                              HatchValve shuts closed). math.huge when there is no way.
--   entryDistance(layout, place) walkDistance from the entry point to the place
--   quarter(pos)               which quarter of the footprint a point lies in (1 NW, 2 NE, 3 SW, 4 SE; split at its
--                              centre), for the pick spread rule
-- ObjectiveConfig.HideReach is how close a hiding spot must be; ObjectiveConfig.EntryClearance how far every item
-- candidate is walked from the entry; ObjectiveConfig.PickSpacing how far apart the items of one run lie.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local PoolWaterBuilder = require(script.Parent.Props.PoolWaterBuilder)

type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor

export type HideKind = "Locker" | "Vent" | "DarkCorner" | "DryFooting" | "Cover"

export type Place = { id: string, kind: Enums.AnchorKind, room: string, pos: Vector3 }

export type Hide = { kind: HideKind, id: string, room: string, pos: Vector3, distance: number }

local ObjectivePlaces = {}

ObjectivePlaces.CoverHeight = 3.5
ObjectivePlaces.CornerInset = 1.5
ObjectivePlaces.ClimbBand = table.freeze({ min = 0.1, max = 2.3 }) -- SwimController's climb-out band over the water

local STATION_KINDS: { [string]: boolean } = {
	BreakerPanel = true,
	FumeHood = true,
	Generator = true,
	StoreLock = true,
	HatchValve = true,
	CrateChain = true,
	ExitLock = true,
}

-- Every objective spot of `layout` in layout order: the floor's item candidates, its stations and its locks.
function ObjectivePlaces.places(layout: Layout): { Place }
	local spec = ObjectiveConfig.forLevel(layout.id)
	local out: { Place } = {}
	for _, anchor in layout.anchors do
		if (spec and anchor.kind == spec.item.candidate) or STATION_KINDS[anchor.kind] then
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
		if room.kind == "Chase" or room.kind == "Airlock" or room.kind == "Stairwell" then
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

-- Grates a HatchValve shuts (not a way out until the objective opens it).
local function hatched(layout: Layout): { [string]: boolean }
	local out: { [string]: boolean } = {}
	local vents = layout.vents
	if not vents then
		return out
	end
	local nodes: { [string]: LayoutSchema.VentNodeSpec } = {}
	for _, node in vents.nodes do
		nodes[node.id] = node
	end
	for _, anchor in layout.anchors do
		if anchor.kind ~= "HatchValve" then
			continue
		end
		for _, grate in vents.grates do
			local node = nodes[grate.node]
			if node and math.abs(node.x - anchor.pos.X) < 2.5 and math.abs(node.z - anchor.pos.Z) < 1.5 then
				out[grate.id] = true
			end
		end
	end
	return out
end

-- Every hide spot of `layout` (distance 0; nearestHide fills it in).
function ObjectivePlaces.hideSpots(layout: Layout): { Hide }
	local out: { Hide } = {}
	for _, anchor in layout.anchors do
		if anchor.kind == "Locker" then
			table.insert(out, { kind = "Locker", id = anchor.id, room = anchor.room, pos = anchor.pos, distance = 0 })
		end
	end
	local vents = layout.vents
	if vents then
		local nodes: { [string]: LayoutSchema.VentNodeSpec } = {}
		for _, node in vents.nodes do
			nodes[node.id] = node
		end
		local shut = hatched(layout)
		for _, grate in vents.grates do
			local node = nodes[grate.node]
			if node and not grate.lockable and not shut[grate.id] then
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
	if layout.id == "Level0_Basement" then
		for _, corner in darkCorners(layout) do
			table.insert(out, corner)
		end
	elseif layout.id == "Level5_Roof" then
		for _, platform in (layout.platforms or {}) :: { LayoutSchema.Platform } do
			if platform.top >= ObjectivePlaces.CoverHeight then
				local r = platform.rect
				table.insert(out, {
					kind = "Cover",
					id = platform.id,
					room = platform.room,
					pos = Vector3.new(r.x + r.w / 2, 0, r.z + r.d / 2),
					distance = 0,
				})
			end
		end
	end
	return out
end

local function platformById(layout: Layout, id: string): LayoutSchema.Platform?
	for _, platform in (layout.platforms or {}) :: { LayoutSchema.Platform } do
		if platform.id == id then
			return platform
		end
	end
	return nil
end

-- The closest hide spot `place` can use on `layout`, or nil when the floor has none in reach of it.
function ObjectivePlaces.nearestHide(layout: Layout, place: Place): Hide?
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
		if hide.kind == "Cover" then
			local platform = platformById(layout, hide.id)
			if platform then
				consider(hide, PoolWaterBuilder.pointGap(platform.rect, flat.X, flat.Z))
			end
		elseif hide.kind == "DarkCorner" then
			if hide.room == place.room then
				consider(hide, d)
			end
		elseif near[hide.room] then
			consider(hide, d)
		end
	end
	for _, basin in (layout.basins or {}) :: { LayoutSchema.Basin } do
		local groups =
			PoolWaterBuilder.dryGroups(layout, basin, ObjectivePlaces.ClimbBand.min, ObjectivePlaces.ClimbBand.max)
		local swim = PoolWaterBuilder.swimToDry(groups, flat.X, flat.Z)
		if basin.room == place.room then
			consider({ kind = "DryFooting", id = basin.id, room = basin.room, pos = place.pos, distance = 0 }, swim)
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- Walking distances (the fairness rules: never right at the door you came in by)
--------------------------------------------------------------------------------

-- Where the squad arrives on `layout`: the centroid of its entry room's PlayerSpawn anchors (the room's centre when
-- it has none).
function ObjectivePlaces.entryPoint(layout: Layout): Vector3
	local sum, count = Vector3.zero, 0
	for _, anchor in layout.anchors do
		if anchor.kind == "PlayerSpawn" and anchor.room == layout.entry then
			sum += Vector3.new(anchor.pos.X, 0, anchor.pos.Z)
			count += 1
		end
	end
	if count > 0 then
		return sum / count
	end
	local room = LayoutSchema.indexRooms(layout)[layout.entry]
	local centre = if room then LayoutSchema.rectCenter(room.rect) else Vector2.zero
	return Vector3.new(centre.X, 0, centre.Y)
end

type WalkNode = { pos: Vector2, links: { { to: string, length: number } } }
type WalkGraph = { nodes: { [string]: WalkNode }, members: { [string]: { string } } }

local walkCache: { [Layout]: WalkGraph } = setmetatable({}, { __mode = "k" }) :: any

local function flat(v: Vector3): Vector2
	return Vector2.new(v.X, v.Z)
end

-- The floor plan as portals: every passable door's centre on its wall and every vent node, joined across each room
-- (straight lines, every pair of the room's portals) and along the ducts. Worst case: Gate doors shut, lockable
-- grates locked, hatch-shut grates closed.
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
		local shut = hatched(layout)
		for _, grate in vents.grates do
			if not grate.lockable and not shut[grate.id] and nodes["vent:" .. grate.node] then
				member(grate.room, "vent:" .. grate.node)
			end
		end
	end
	for _, list in members do
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
		local current: string? = nil
		for id, d in distance do
			if not settled[id] and (current == nil or d < distance[current :: string]) then
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

-- Studs walked from the entry point of `layout` to `place`.
function ObjectivePlaces.entryDistance(layout: Layout, place: Place): number
	return ObjectivePlaces.walkDistance(layout, layout.entry, ObjectivePlaces.entryPoint(layout), place.room, place.pos)
end

-- The quarter of the footprint `pos` lies in: 1 north-west, 2 north-east, 3 south-west, 4 south-east.
function ObjectivePlaces.quarter(pos: Vector3): number
	local size = WorldConfig.FootprintSize
	local east = if pos.X >= size.X / 2 then 1 else 0
	local south = if pos.Z >= size.Y / 2 then 2 else 0
	return 1 + east + south
end

return table.freeze(ObjectivePlaces)
