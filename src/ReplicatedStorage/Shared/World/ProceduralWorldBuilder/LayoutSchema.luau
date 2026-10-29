--!strict
-- Data contract for every level blueprint in Layouts/, plus the geometry helpers that builders and the validator
-- share, so "where is this door" has exactly one answer.
--
-- Coordinates are level-local studs: X 0..240 and Z 0..160 cover the school footprint, Y is height above that
-- level's floor. A Rect is its min corner (x, z) plus size (w along X, d along Z). Rooms tile the floor plan
-- without overlapping; walls are generated on room edges, and two rooms that touch share one wall.
-- Ducts live inside "Chase" rooms (5-stud service cavities between rooms), so they are literally inside the walls.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

export type Rect = { x: number, z: number, w: number, d: number }

export type Side = "N" | "S" | "E" | "W" -- N = min Z edge, S = max Z edge, W = min X edge, E = max X edge

export type Light = {
	id: string,
	kind: Enums.LightKind,
	pos: Vector3, -- level-local
	brightness: number,
	range: number,
	color: Color3?,
	flickerGroup: string?, -- lights in a group flicker together
	broken: boolean?, -- fixture is built but stays dark
	shadows: boolean?, -- default true (unshadowed lights shine through walls); false opts out
}

export type Room = {
	id: string,
	kind: Enums.RoomKind,
	rect: Rect,
	height: number?, -- ceiling height; defaults to the level height
	wallHeight: number?, -- shorter than height for parapets; defaults to height
	noCeiling: boolean?,
	floor: string?, -- Palette key
	wall: string?,
	ceiling: string?,
	surface: Enums.SurfaceKind?, -- footstep surface; defaults from the floor palette entry
	acoustic: Enums.AcousticPreset?,
	lights: { Light }?,
}

export type Door = {
	id: string,
	kind: Enums.DoorKind,
	rooms: { string }, -- exactly two room ids that share a wall
	at: number, -- centre along the shared edge: Z for an edge of constant X, X for an edge of constant Z
	width: number?, -- default WorldConfig.DoorWidth (Airlock: AirlockDoorWidth)
	height: number?, -- default WorldConfig.DoorHeight
	scriptedId: string?, -- ScriptedDoor DoorId (HallwayGate, RoofStairDoor, ClassroomDoor)
}

export type VentNodeSpec = {
	id: string,
	x: number,
	z: number,
	y: number?, -- duct centre above the floor; default WorldConfig.VentCenterHeight
}

export type VentEdgeSpec = {
	a: string,
	b: string,
	submerged: boolean?,
}

export type GrateSpec = {
	id: string,
	node: string, -- a VentNode lying on the wall shared by a Chase and `room`
	room: string, -- the room the grate opens into
	lockable: boolean, -- RunDirector may lock it
	criticalPath: boolean, -- part of the guaranteed route; never locked
}

export type VentNetwork = {
	nodes: { VentNodeSpec },
	edges: { VentEdgeSpec },
	grates: { GrateSpec },
}

export type Anchor = {
	id: string,
	kind: Enums.AnchorKind,
	room: string,
	pos: Vector3, -- level-local
	yaw: number?, -- degrees about +Y
	ref: string?, -- another anchor of the layout this one belongs to (a coach's key's locker, a fuse's guard trap)
}

export type Trigger = {
	id: string,
	kind: Enums.TriggerKind,
	room: string,
	rect: Rect,
	height: number,
	y: number?, -- bottom above the floor, default 0
}

export type Basin = {
	id: string,
	room: string, -- a Pool room
	rect: Rect,
	depth: number, -- basin floor below the deck
	waterLevel: number, -- water surface relative to the deck (negative = below)
}

export type Platform = {
	id: string,
	room: string,
	rect: Rect,
	top: number, -- level-local Y of the walking surface
	thickness: number,
	material: string?,
}

export type Pillar = {
	room: string,
	x: number,
	z: number,
	size: number,
}

export type Window = {
	room: string,
	side: Side,
	at: number,
	width: number,
	height: number,
	sill: number,
	boarded: boolean,
}

export type LevelLayout = {
	id: Enums.LayoutId,
	height: number, -- default ceiling height
	acoustic: Enums.AcousticPreset,
	ambience: string, -- SynthPresets drone for the level bed
	entry: string, -- room id where the squad arrives
	exit: string, -- room id the squad must reach
	rooms: { Room },
	doors: { Door },
	vents: VentNetwork?,
	anchors: { Anchor },
	triggers: { Trigger },
	basins: { Basin }?,
	platforms: { Platform }?,
	pillars: { Pillar }?,
	windows: { Window }?,
}

export type SharedEdge = {
	axis: "X" | "Z", -- "X": edge lies at constant X (runs along Z); "Z": constant Z (runs along X)
	coord: number, -- the constant coordinate
	from: number, -- overlap start along the edge
	to: number, -- overlap end along the edge
}

local LayoutSchema = {}

local EPS = 1e-3

function LayoutSchema.rect(x: number, z: number, w: number, d: number): Rect
	return { x = x, z = z, w = w, d = d }
end

function LayoutSchema.rectCenter(r: Rect): Vector2
	return Vector2.new(r.x + r.w / 2, r.z + r.d / 2)
end

function LayoutSchema.rectContains(r: Rect, x: number, z: number, margin: number?): boolean
	local m = margin or 0
	return x >= r.x + m - EPS and x <= r.x + r.w - m + EPS and z >= r.z + m - EPS and z <= r.z + r.d - m + EPS
end

function LayoutSchema.rectInside(inner: Rect, outer: Rect): boolean
	return inner.x >= outer.x - EPS
		and inner.z >= outer.z - EPS
		and inner.x + inner.w <= outer.x + outer.w + EPS
		and inner.z + inner.d <= outer.z + outer.d + EPS
end

function LayoutSchema.rectOverlapArea(a: Rect, b: Rect): number
	local ox = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
	local oz = math.min(a.z + a.d, b.z + b.d) - math.max(a.z, b.z)
	if ox <= EPS or oz <= EPS then
		return 0
	end
	return ox * oz
end

-- The wall two rooms share, if they touch along a segment of positive length.
function LayoutSchema.sharedEdge(a: Rect, b: Rect): SharedEdge?
	local function overlap(a0: number, a1: number, b0: number, b1: number): (number, number)
		return math.max(a0, b0), math.min(a1, b1)
	end
	if math.abs(a.x + a.w - b.x) < EPS or math.abs(b.x + b.w - a.x) < EPS then
		local coord = if math.abs(a.x + a.w - b.x) < EPS then b.x else a.x
		local from, to = overlap(a.z, a.z + a.d, b.z, b.z + b.d)
		if to - from > EPS then
			return { axis = "X", coord = coord, from = from, to = to }
		end
	end
	if math.abs(a.z + a.d - b.z) < EPS or math.abs(b.z + b.d - a.z) < EPS then
		local coord = if math.abs(a.z + a.d - b.z) < EPS then b.z else a.z
		local from, to = overlap(a.x, a.x + a.w, b.x, b.x + b.w)
		if to - from > EPS then
			return { axis = "Z", coord = coord, from = from, to = to }
		end
	end
	return nil
end

-- Which side of `r` the point (x, z) lies on, if it lies on the rect boundary.
function LayoutSchema.sideOfPoint(r: Rect, x: number, z: number): Side?
	local onX = z >= r.z - EPS and z <= r.z + r.d + EPS
	local onZ = x >= r.x - EPS and x <= r.x + r.w + EPS
	if onX and math.abs(x - r.x) < EPS then
		return "W"
	elseif onX and math.abs(x - (r.x + r.w)) < EPS then
		return "E"
	elseif onZ and math.abs(z - r.z) < EPS then
		return "N"
	elseif onZ and math.abs(z - (r.z + r.d)) < EPS then
		return "S"
	end
	return nil
end

function LayoutSchema.roomHeight(layout: LevelLayout, room: Room): number
	return room.height or layout.height
end

function LayoutSchema.doorWidth(door: Door): number
	if door.width then
		return door.width
	end
	return if door.kind == "Airlock" then WorldConfig.AirlockDoorWidth else WorldConfig.DoorWidth
end

function LayoutSchema.doorHeight(door: Door): number
	return door.height or WorldConfig.DoorHeight
end

function LayoutSchema.ventNodeY(node: VentNodeSpec): number
	return node.y or WorldConfig.VentCenterHeight
end

-- Level-local -> world.
function LayoutSchema.toWorld(layoutId: string, x: number, y: number, z: number): Vector3
	return WorldConfig.levelOrigin(layoutId) + Vector3.new(x, y, z)
end

function LayoutSchema.indexRooms(layout: LevelLayout): { [string]: Room }
	local byId: { [string]: Room } = {}
	for _, room in layout.rooms do
		byId[room.id] = room
	end
	return byId
end

--------------------------------------------------------------------------------
-- Validation. Returns a list of human-readable problems; an empty list means the layout is buildable:
--   * ids are unique; rooms tile the footprint without overlapping (school levels);
--   * doors join two non-chase rooms across a shared wall they fit; grates sit on a wall a chase shares with a
--     real room, inside that shared stretch, under a lintel, and above the floor (below it only over a pool basin);
--   * openings on one wall line (doors, grates, windows, the stair-tower opening) keep a pier between them;
--   * ducts are level, axis-aligned, listed once, stay inside chases, and never cross or touch without a shared node;
--   * anchors and triggers stay inside their room's volume, lights inside their room; an anchor's ref names another
--     anchor of the layout;
--   * stairwell vestibules touch their tower; the exit stays reachable with every lockable grate locked and every
--     gate shut.
--------------------------------------------------------------------------------

local function pushf(errors: { string }, fmt: string, ...: any)
	table.insert(errors, string.format(fmt, ...))
end

local function isSchoolLevel(layout: LevelLayout): boolean
	return layout.id ~= "Lobby"
end

-- Solid wall the validator keeps between two openings on one wall (beside or above each other) and above a
-- grate opening (its lintel under the ceiling).
local PIER = 0.5
local HALF_BORE = WorldConfig.VentBore / 2
local HALF_OUTER = HALF_BORE + WorldConfig.VentShell

-- One opening cut through a wall line, in wall terms: `u` runs along the wall, `y` is height above the floor.
type WallOpening = { what: string, axis: "X" | "Z", coord: number, u0: number, u1: number, y0: number, y1: number }

-- Level-local box a duct (or the junction box at a node) occupies with its shell. `nodes` are the vent nodes the
-- duct ends at; a junction box lists its own node and the junctions it is linked to directly (VentShaftBuilder
-- fits two linked junctions closer together than a box width into one run, bores clear).
type DuctBox = {
	what: string,
	nodes: { string },
	x0: number,
	x1: number,
	y0: number,
	y1: number,
	z0: number,
	z1: number,
}

-- The wall line of a room side: constant X for W / E, constant Z for N / S.
local function sideLine(r: Rect, side: Side): ("X" | "Z", number)
	if side == "W" then
		return "X", r.x
	elseif side == "E" then
		return "X", r.x + r.w
	elseif side == "N" then
		return "Z", r.z
	end
	return "Z", r.z + r.d
end

-- Unit step from a room side into the room.
local function inwardOf(side: Side): (number, number)
	if side == "N" then
		return 0, 1
	elseif side == "S" then
		return 0, -1
	elseif side == "W" then
		return 1, 0
	end
	return -1, 0
end

local function boxesOverlap(a: DuctBox, b: DuctBox): boolean
	return math.min(a.x1, b.x1) - math.max(a.x0, b.x0) > 0.01
		and math.min(a.y1, b.y1) - math.max(a.y0, b.y0) > 0.01
		and math.min(a.z1, b.z1) - math.max(a.z0, b.z0) > 0.01
end

local function sharesNode(a: DuctBox, b: DuctBox): boolean
	for _, id in a.nodes do
		if table.find(b.nodes, id) then
			return true
		end
	end
	return false
end

local function stairwellRooms(layoutId: string): { [string]: WorldConfig.StairwellSpec }
	local out: { [string]: WorldConfig.StairwellSpec } = {}
	for _, spec in WorldConfig.Stairwells do
		if spec.from == layoutId then
			out[spec.fromRoom] = spec
		elseif spec.to == layoutId then
			out[spec.toRoom] = spec
		end
	end
	return out
end

-- Graph used for the solvability proof: rooms + vent nodes, joined by doors, grates and ducts.
-- `strict` treats every lockable grate as locked and every Gate / Boarded door as shut.
local function reachable(layout: LevelLayout, from: string, strict: boolean): { [string]: boolean }
	local adjacency: { [string]: { string } } = {}
	local function link(a: string, b: string)
		adjacency[a] = adjacency[a] or {}
		adjacency[b] = adjacency[b] or {}
		table.insert(adjacency[a], b)
		table.insert(adjacency[b], a)
	end
	for _, door in layout.doors do
		local passable = door.kind ~= "Boarded" and not (strict and door.kind == "Gate")
		if passable and #door.rooms == 2 then
			link("room:" .. door.rooms[1], "room:" .. door.rooms[2])
		end
	end
	local vents = layout.vents
	if vents then
		for _, edge in vents.edges do
			link("vent:" .. edge.a, "vent:" .. edge.b)
		end
		for _, grate in vents.grates do
			if not (strict and grate.lockable) then
				link("room:" .. grate.room, "vent:" .. grate.node)
			end
		end
	end
	local seen: { [string]: boolean } = { ["room:" .. from] = true }
	local queue = { "room:" .. from }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, nextId in (adjacency[current] or {}) :: { string } do
			if not seen[nextId] then
				seen[nextId] = true
				table.insert(queue, nextId)
			end
		end
	end
	return seen
end

-- Duct bodies for the proximity check (validate rule "ducts never cross or touch without a shared node") and for
-- the floor a chase gets where a duct sinks below it. Each buildable edge gives one box along its run: it stops at
-- a grate node (the duct ends in the wall there), runs on to a straight joint, runs half a bore plus the shell past
-- a dead end (its end cap), and stops a box half-width short of a junction or turn. Every junction or turn node
-- gives its own box, so a duct passing through a junction it is not linked to still shows up.
local function ductBoxes(vents: VentNetwork, nodes: { [string]: VentNodeSpec }): { DuctBox }
	local grateNodes: { [string]: boolean } = {}
	for _, grate in vents.grates do
		grateNodes[grate.node] = true
	end
	type Arms = { x: number, z: number, count: number }
	local arms: { [string]: Arms } = {}
	local neighbours: { [string]: { string } } = {}
	local valid: { VentEdgeSpec } = {}
	for _, edge in vents.edges do
		local a, b = nodes[edge.a], nodes[edge.b]
		if not a or not b or edge.a == edge.b then
			continue
		end
		local sameX, sameZ = math.abs(a.x - b.x) < EPS, math.abs(a.z - b.z) < EPS
		if sameX == sameZ or math.abs(LayoutSchema.ventNodeY(a) - LayoutSchema.ventNodeY(b)) > EPS then
			continue
		end
		table.insert(valid, edge)
		neighbours[edge.a] = neighbours[edge.a] or {}
		neighbours[edge.b] = neighbours[edge.b] or {}
		table.insert(neighbours[edge.a], edge.b)
		table.insert(neighbours[edge.b], edge.a)
		for _, id in { edge.a, edge.b } do
			local entry = arms[id] or { x = 0, z = 0, count = 0 }
			arms[id] = entry
			entry.count += 1
			if sameZ then
				entry.x += 1
			else
				entry.z += 1
			end
		end
	end
	local function isJunction(id: string): boolean
		local entry = arms[id]
		return entry ~= nil and entry.x > 0 and entry.z > 0
	end
	-- How far the body of a duct runs past (positive) or stops short of (negative) node `id`.
	local function endReach(id: string): number
		if grateNodes[id] then
			return 0
		end
		local entry = arms[id]
		if not entry or entry.count <= 1 then
			return HALF_OUTER
		end
		return if isJunction(id) then -HALF_OUTER else 0
	end
	local out: { DuctBox } = {}
	for _, edge in valid do
		local a, b = nodes[edge.a], nodes[edge.b]
		local y = LayoutSchema.ventNodeY(a)
		local alongX = math.abs(a.z - b.z) < EPS
		local ua, ub = if alongX then a.x else a.z, if alongX then b.x else b.z
		local s = if ub > ua then 1 else -1
		local from, to = ua - s * endReach(a.id), ub + s * endReach(b.id)
		local u0, u1 = math.min(from, to), math.max(from, to)
		if (to - from) * s <= EPS then
			continue
		end
		local c = if alongX then a.z else a.x
		table.insert(out, {
			what = string.format("duct %s-%s", edge.a, edge.b),
			nodes = { edge.a, edge.b },
			x0 = if alongX then u0 else c - HALF_OUTER,
			x1 = if alongX then u1 else c + HALF_OUTER,
			y0 = y - HALF_OUTER,
			y1 = y + HALF_OUTER,
			z0 = if alongX then c - HALF_OUTER else u0,
			z1 = if alongX then c + HALF_OUTER else u1,
		})
	end
	local boxed: { [string]: boolean } = {}
	for _, node in vents.nodes do
		local id = node.id
		if isJunction(id) and not grateNodes[id] and not boxed[id] and nodes[id] == node then
			boxed[id] = true
			local related = { id }
			for _, other in neighbours[id] do
				if isJunction(other) and not grateNodes[other] then
					table.insert(related, other)
				end
			end
			local y = LayoutSchema.ventNodeY(node)
			table.insert(out, {
				what = "junction " .. id,
				nodes = related,
				x0 = node.x - HALF_OUTER,
				x1 = node.x + HALF_OUTER,
				y0 = y - HALF_OUTER,
				y1 = y + HALF_OUTER,
				z0 = node.z - HALF_OUTER,
				z1 = node.z + HALF_OUTER,
			})
		end
	end
	return out
end

-- The lowest walkable or swimmable level under the level-local area `area` of `room`: a pool basin's floor where
-- the area overlaps the basin, the bore floor of a duct sunk below a chase's floor, otherwise the floor (0).
local function floorUnder(layout: LevelLayout, room: Room, area: Rect, ducts: { DuctBox }): number
	local floor = 0
	for _, basin in (layout.basins or {}) :: { Basin } do
		if basin.room == room.id and LayoutSchema.rectOverlapArea(basin.rect, area) > 0 then
			floor = math.min(floor, -basin.depth)
		end
	end
	if room.kind == "Chase" then
		for _, duct in ducts do
			local footprint = LayoutSchema.rect(duct.x0, duct.z0, duct.x1 - duct.x0, duct.z1 - duct.z0)
			if
				LayoutSchema.rectOverlapArea(footprint, area) > 0
				and LayoutSchema.rectOverlapArea(footprint, room.rect) > 0
			then
				floor = math.min(floor, duct.y0 + WorldConfig.VentShell)
			end
		end
	end
	return floor
end

function LayoutSchema.validate(layout: LevelLayout): { string }
	local errors: { string } = {}
	local rooms = LayoutSchema.indexRooms(layout)
	local footprint = LayoutSchema.rect(0, 0, WorldConfig.FootprintSize.X, WorldConfig.FootprintSize.Y)
	local seenIds: { [string]: string } = {}
	local openings: { WallOpening } = {}
	local ducts: { DuctBox } = {}

	local function claimId(id: string, what: string)
		if seenIds[id] then
			pushf(errors, "duplicate id %q (%s and %s)", id, seenIds[id], what)
		else
			seenIds[id] = what
		end
	end

	-- Rooms
	for i, room in layout.rooms do
		claimId(room.id, "room")
		if room.rect.w <= 0 or room.rect.d <= 0 then
			pushf(errors, "room %s has non-positive size", room.id)
		end
		if isSchoolLevel(layout) and not LayoutSchema.rectInside(room.rect, footprint) then
			pushf(errors, "room %s leaves the 240x160 footprint", room.id)
		end
		if room.wallHeight and room.wallHeight > LayoutSchema.roomHeight(layout, room) + EPS then
			pushf(errors, "room %s wallHeight exceeds its height", room.id)
		end
		for j = i + 1, #layout.rooms do
			local other = layout.rooms[j]
			if LayoutSchema.rectOverlapArea(room.rect, other.rect) > 0 then
				pushf(errors, "rooms %s and %s overlap", room.id, other.id)
			end
		end
		for _, light in (room.lights or {}) :: { Light } do
			claimId(light.id, "light")
			if not LayoutSchema.rectContains(room.rect, light.pos.X, light.pos.Z) then
				pushf(errors, "light %s lies outside room %s", light.id, room.id)
			end
			if light.pos.Y < 0 or light.pos.Y > LayoutSchema.roomHeight(layout, room) + EPS then
				pushf(errors, "light %s is outside room %s vertically", light.id, room.id)
			end
		end
	end

	-- School levels tile the whole footprint (no overlaps + full area = full tiling), so the facade and every
	-- floor are continuous. Dead space is modelled as Storage or Chase rooms.
	if isSchoolLevel(layout) then
		local area = 0
		for _, room in layout.rooms do
			area += room.rect.w * room.rect.d
		end
		local expected = footprint.w * footprint.d
		if math.abs(area - expected) > 0.5 then
			pushf(
				errors,
				"rooms cover %.1f of the %.0f stud^2 footprint; tile it completely (gaps or overlaps)",
				area,
				expected
			)
		end
	end

	if not rooms[layout.entry] then
		pushf(errors, "entry room %s is missing", layout.entry)
	end
	if not rooms[layout.exit] then
		pushf(errors, "exit room %s is missing", layout.exit)
	end

	-- Doors
	for _, door in layout.doors do
		claimId(door.id, "door")
		if #door.rooms ~= 2 then
			pushf(errors, "door %s must join exactly two rooms", door.id)
			continue
		end
		local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
		if not a or not b then
			pushf(errors, "door %s references a missing room", door.id)
			continue
		end
		if a.kind == "Chase" or b.kind == "Chase" then
			pushf(errors, "door %s opens into a chase; chases are reachable only through vents", door.id)
		end
		local edge = LayoutSchema.sharedEdge(a.rect, b.rect)
		if not edge then
			pushf(errors, "door %s: rooms %s and %s do not share a wall", door.id, a.id, b.id)
			continue
		end
		local half = LayoutSchema.doorWidth(door) / 2
		if door.at - half < edge.from + 0.5 - EPS or door.at + half > edge.to - 0.5 + EPS then
			pushf(
				errors,
				"door %s (at %.1f, width %.1f) does not fit the shared wall %.1f..%.1f",
				door.id,
				door.at,
				half * 2,
				edge.from,
				edge.to
			)
		end
		local minHeight = math.min(LayoutSchema.roomHeight(layout, a), LayoutSchema.roomHeight(layout, b))
		if LayoutSchema.doorHeight(door) > minHeight - 0.5 + EPS then
			pushf(errors, "door %s is taller than the lower of its rooms", door.id)
		end
		table.insert(openings, {
			what = "door " .. door.id,
			axis = edge.axis,
			coord = edge.coord,
			u0 = door.at - half,
			u1 = door.at + half,
			y0 = 0,
			y1 = LayoutSchema.doorHeight(door),
		})
	end

	-- Vents
	local vents = layout.vents
	if vents then
		local nodes: { [string]: VentNodeSpec } = {}
		local degree: { [string]: number } = {}
		for _, node in vents.nodes do
			claimId(node.id, "vent node")
			nodes[node.id] = node
			degree[node.id] = 0
		end
		local chases: { Room } = {}
		for _, room in layout.rooms do
			if room.kind == "Chase" then
				table.insert(chases, room)
			end
		end
		local grateNodes: { [string]: boolean } = {}
		for _, grate in vents.grates do
			grateNodes[grate.node] = true
		end
		local inset = WorldConfig.VentBore / 2 + WorldConfig.VentShell
		local function insideSomeChase(x: number, z: number): boolean
			for _, chase in chases do
				if LayoutSchema.rectContains(chase.rect, x, z, inset) then
					return true
				end
			end
			return false
		end
		local seenEdges: { [string]: boolean } = {}
		for _, edge in vents.edges do
			local a, b = nodes[edge.a], nodes[edge.b]
			if not a or not b then
				pushf(errors, "vent edge %s-%s references a missing node", edge.a, edge.b)
				continue
			end
			local key = if edge.a < edge.b then edge.a .. "|" .. edge.b else edge.b .. "|" .. edge.a
			if seenEdges[key] then
				pushf(errors, "vent edge %s-%s is listed twice", edge.a, edge.b)
				continue
			end
			seenEdges[key] = true
			degree[edge.a] += 1
			degree[edge.b] += 1
			local sameX, sameZ = math.abs(a.x - b.x) < EPS, math.abs(a.z - b.z) < EPS
			if sameX == sameZ then
				pushf(errors, "vent edge %s-%s must be axis-aligned and non-zero", edge.a, edge.b)
				continue
			end
			if math.abs(LayoutSchema.ventNodeY(a) - LayoutSchema.ventNodeY(b)) > EPS then
				pushf(errors, "vent edge %s-%s changes height; ducts are level within a network", edge.a, edge.b)
			end
			local length = math.max(math.abs(a.x - b.x), math.abs(a.z - b.z))
			local samples = math.floor(length)
			for s = 0, samples do
				local t = if samples == 0 then 0 else s / samples
				local x = a.x + (b.x - a.x) * t
				local z = a.z + (b.z - a.z) * t
				local distA = math.max(math.abs(x - a.x), math.abs(z - a.z))
				local distB = math.max(math.abs(x - b.x), math.abs(z - b.z))
				local nearGrate = (grateNodes[a.id] and distA < inset + EPS)
					or (grateNodes[b.id] and distB < inset + EPS)
				if not nearGrate and not insideSomeChase(x, z) then
					pushf(errors, "vent edge %s-%s leaves its chase near (%.1f, %.1f)", edge.a, edge.b, x, z)
					break
				end
			end
		end
		for id, count in degree do
			if count == 0 then
				pushf(errors, "vent node %s has no ducts", id)
			end
		end

		-- Ducts that share no node must not cross or touch: the A* graph only knows linked nodes, so two bores
		-- meeting anywhere else would be a crawlable junction the graph cannot see (or a duct walled into another).
		ducts = ductBoxes(vents, nodes)
		for i = 1, #ducts do
			for j = i + 1, #ducts do
				local a, b = ducts[i], ducts[j]
				if not sharesNode(a, b) and boxesOverlap(a, b) then
					pushf(
						errors,
						"%s and %s cross or touch without a shared vent node (near %.1f, %.1f)",
						a.what,
						b.what,
						(math.max(a.x0, b.x0) + math.min(a.x1, b.x1)) / 2,
						(math.max(a.z0, b.z0) + math.min(a.z1, b.z1)) / 2
					)
				end
			end
		end

		for _, grate in vents.grates do
			claimId(grate.id, "grate")
			local node, room = nodes[grate.node], rooms[grate.room]
			if not node or not room then
				pushf(errors, "grate %s references a missing node or room", grate.id)
				continue
			end
			if room.kind == "Chase" then
				pushf(errors, "grate %s must open into a real room, not a chase", grate.id)
			end
			local side = LayoutSchema.sideOfPoint(room.rect, node.x, node.z)
			if not side then
				pushf(errors, "grate %s node %s is not on a wall of room %s", grate.id, node.id, room.id)
			end
			local chase: Room? = nil
			local edge: SharedEdge? = nil
			for _, candidate in chases do
				local shared = LayoutSchema.sharedEdge(candidate.rect, room.rect)
				if
					shared
					and LayoutSchema.sideOfPoint(candidate.rect, node.x, node.z)
					and math.abs((if shared.axis == "X" then node.x else node.z) - shared.coord) < EPS
				then
					chase, edge = candidate, shared
					break
				end
			end
			if not chase or not edge or not side then
				pushf(
					errors,
					"grate %s node %s is not on a wall shared by a chase and room %s",
					grate.id,
					node.id,
					room.id
				)
			else
				local y = LayoutSchema.ventNodeY(node)
				local u = if edge.axis == "X" then node.z else node.x
				local u0, u1 = u - HALF_BORE, u + HALF_BORE
				-- the opening stays clear of the walls that meet the shared stretch at either end
				local margin = WorldConfig.WallThickness / 2
				if u0 < edge.from + margin - EPS or u1 > edge.to - margin + EPS then
					pushf(
						errors,
						"grate %s opening %.2f..%.2f runs past the wall %s shares with %s (%.1f..%.1f)",
						grate.id,
						u0,
						u1,
						room.id,
						chase.id,
						edge.from,
						edge.to
					)
				end
				-- a lintel under the lower ceiling of the two rooms
				local ceiling = math.min(LayoutSchema.roomHeight(layout, room), LayoutSchema.roomHeight(layout, chase))
				if y + HALF_BORE > ceiling - PIER + EPS then
					pushf(
						errors,
						"grate %s opening top %.2f leaves no %.1f-stud lintel under the %.1f ceiling of %s / %s",
						grate.id,
						y + HALF_BORE,
						PIER,
						ceiling,
						room.id,
						chase.id
					)
				end
				-- on the room side the opening must not dip into the floor: a grate may sink below the floor only
				-- where its whole width opens over a pool basin
				local dx, dz = inwardOf(side :: Side)
				local probe = WorldConfig.WallThickness / 2 + PIER
				local px, pz = node.x + dx * probe, node.z + dz * probe
				local strip = if edge.axis == "X"
					then LayoutSchema.rect(px - EPS, u0, 2 * EPS, u1 - u0)
					else LayoutSchema.rect(u0, pz - EPS, u1 - u0, 2 * EPS)
				local floor = 0
				for _, basin in (layout.basins or {}) :: { Basin } do
					if basin.room == room.id and LayoutSchema.rectInside(strip, basin.rect) then
						floor = math.min(floor, -basin.depth)
					end
				end
				if y - HALF_BORE < floor - EPS then
					pushf(
						errors,
						"grate %s opening bottom %.2f sinks below the floor of %s (%.1f)%s",
						grate.id,
						y - HALF_BORE,
						room.id,
						floor,
						if floor == 0 then "; only a grate wholly over a pool basin may sit that low" else ""
					)
				end
				table.insert(openings, {
					what = "grate " .. grate.id,
					axis = edge.axis,
					coord = edge.coord,
					u0 = u0,
					u1 = u1,
					y0 = y - HALF_BORE,
					y1 = y + HALF_BORE,
				})
			end
			if grate.lockable and grate.criticalPath then
				pushf(errors, "grate %s cannot be both lockable and on the critical path", grate.id)
			end
		end
	end

	-- Anchors, triggers, basins, platforms, pillars, windows. Anchors and triggers stay inside their room's volume:
	-- from the floor under them (a basin's floor over a pool, a sunken duct's bore floor in a chase) up to its
	-- ceiling height.
	for _, anchor in layout.anchors do
		claimId(anchor.id, "anchor")
		local room = rooms[anchor.room]
		if not room then
			pushf(errors, "anchor %s references missing room %s", anchor.id, anchor.room)
			continue
		end
		local x, y, z = anchor.pos.X, anchor.pos.Y, anchor.pos.Z
		if not LayoutSchema.rectContains(room.rect, x, z) then
			pushf(errors, "anchor %s lies outside room %s", anchor.id, anchor.room)
		end
		local floor = floorUnder(layout, room, LayoutSchema.rect(x - EPS, z - EPS, 2 * EPS, 2 * EPS), ducts)
		local top = LayoutSchema.roomHeight(layout, room)
		if y < floor - EPS or y > top + EPS then
			pushf(
				errors,
				"anchor %s at height %.2f is outside room %s vertically (%.1f..%.1f)",
				anchor.id,
				y,
				anchor.room,
				floor,
				top
			)
		end
	end
	for _, anchor in layout.anchors do
		local ref = anchor.ref
		if ref and (ref == anchor.id or seenIds[ref] ~= "anchor") then
			pushf(errors, "anchor %s refers to %s, which is not another anchor of the layout", anchor.id, ref)
		end
	end
	for _, trigger in layout.triggers do
		claimId(trigger.id, "trigger")
		local room = rooms[trigger.room]
		if not room then
			pushf(errors, "trigger %s references missing room %s", trigger.id, trigger.room)
			continue
		end
		if not LayoutSchema.rectInside(trigger.rect, room.rect) then
			pushf(errors, "trigger %s leaves room %s", trigger.id, trigger.room)
		end
		local bottom = trigger.y or 0
		local floor = floorUnder(layout, room, trigger.rect, ducts)
		local top = LayoutSchema.roomHeight(layout, room)
		if trigger.height <= 0 then
			pushf(errors, "trigger %s has no height", trigger.id)
		elseif bottom < floor - EPS or bottom + trigger.height > top + EPS then
			pushf(
				errors,
				"trigger %s (%.2f..%.2f) is outside room %s vertically (%.1f..%.1f)",
				trigger.id,
				bottom,
				bottom + trigger.height,
				trigger.room,
				floor,
				top
			)
		end
	end
	for _, basin in (layout.basins or {}) :: { Basin } do
		claimId(basin.id, "basin")
		local room = rooms[basin.room]
		if not room or room.kind ~= "Pool" then
			pushf(errors, "basin %s must sit in a Pool room", basin.id)
		elseif not LayoutSchema.rectInside(basin.rect, room.rect) then
			pushf(errors, "basin %s leaves room %s", basin.id, basin.room)
		end
		if basin.waterLevel > 0 or basin.waterLevel < -basin.depth then
			pushf(errors, "basin %s water level must lie between its floor and the deck", basin.id)
		end
	end
	for _, platform in (layout.platforms or {}) :: { Platform } do
		claimId(platform.id, "platform")
		local room = rooms[platform.room]
		if not room then
			pushf(errors, "platform %s references missing room %s", platform.id, platform.room)
		elseif not LayoutSchema.rectInside(platform.rect, room.rect) then
			pushf(errors, "platform %s leaves room %s", platform.id, platform.room)
		end
	end
	for _, pillar in (layout.pillars or {}) :: { Pillar } do
		local room = rooms[pillar.room]
		if not room or not LayoutSchema.rectContains(room.rect, pillar.x, pillar.z, pillar.size / 2) then
			pushf(errors, "pillar at (%.1f, %.1f) must sit inside room %s", pillar.x, pillar.z, pillar.room)
		end
	end
	for _, window in (layout.windows or {}) :: { Window } do
		local room = rooms[window.room]
		if not room then
			pushf(errors, "window references missing room %s", window.room)
			continue
		end
		local axis: "X" | "Z", coord: number = sideLine(room.rect, window.side)
		local from = if axis == "X" then room.rect.z else room.rect.x
		local span = if axis == "X" then room.rect.d else room.rect.w
		local half = window.width / 2
		local wallTop = room.wallHeight or LayoutSchema.roomHeight(layout, room)
		if
			window.at - half < from + PIER - EPS
			or window.at + half > from + span - PIER + EPS
			or window.sill < -EPS
			or window.sill + window.height > wallTop + EPS
		then
			pushf(
				errors,
				"window of %s on its %s side (at %.1f) does not fit the wall",
				window.room,
				window.side,
				window.at
			)
		end
		table.insert(openings, {
			what = string.format("window of %s at %.1f", window.room, window.at),
			axis = axis,
			coord = coord,
			u0 = window.at - half,
			u1 = window.at + half,
			y0 = window.sill,
			y1 = window.sill + window.height,
		})
	end

	-- Stairwell vestibules must sit against their tower and exist
	if isSchoolLevel(layout) then
		for roomId, spec in stairwellRooms(layout.id) do
			local room = rooms[roomId]
			if not room then
				pushf(errors, "stairwell %s needs room %s", spec.id, roomId)
				continue
			end
			local tower = WorldConfig.Towers[spec.tower]
			local towerRect =
				LayoutSchema.rect(tower.minX, tower.minZ, tower.maxX - tower.minX, tower.maxZ - tower.minZ)
			local edge = LayoutSchema.sharedEdge(room.rect, towerRect)
			local opening = WorldConfig.TowerOpening
			local centerZ = tower.openingZ
			if
				not edge
				or centerZ - opening.width / 2 < edge.from - EPS
				or centerZ + opening.width / 2 > edge.to + EPS
			then
				pushf(
					errors,
					"room %s must touch the %s tower across Z %.0f +/- %.0f",
					roomId,
					spec.tower,
					centerZ,
					opening.width / 2
				)
			else
				table.insert(openings, {
					what = string.format("%s tower opening", spec.tower),
					axis = edge.axis,
					coord = edge.coord,
					u0 = centerZ - opening.width / 2,
					u1 = centerZ + opening.width / 2,
					y0 = 0,
					y1 = opening.height,
				})
			end
		end
	end

	-- Openings on one wall line (doors, grates, windows, tower openings) keep a pier of solid wall between them,
	-- beside or above each other, so no two openings merge and every split-wall piece has a real size.
	local byLine: { [string]: { WallOpening } } = {}
	for _, opening in openings do
		local key = string.format("%s:%.3f", opening.axis, opening.coord)
		byLine[key] = byLine[key] or {}
		table.insert(byLine[key], opening)
	end
	for _, list in byLine do
		for i = 1, #list do
			for j = i + 1, #list do
				local a, b = list[i], list[j]
				local gapAlong = math.max(a.u0, b.u0) - math.min(a.u1, b.u1)
				local gapUp = math.max(a.y0, b.y0) - math.min(a.y1, b.y1)
				if gapAlong < PIER - EPS and gapUp < PIER - EPS then
					pushf(
						errors,
						"%s and %s overlap on the wall at %s = %.1f (keep a %.1f-stud pier between openings)",
						a.what,
						b.what,
						a.axis,
						a.coord,
						PIER
					)
				end
			end
		end
	end

	-- Solvability: the exit (and every exit vestibule candidate) must be reachable from the entry (and from every
	-- entry vestibule candidate) with every lockable grate locked and every gate shut.
	local entries: { string } = { layout.entry }
	local exits: { string } = { layout.exit }
	if isSchoolLevel(layout) then
		for roomId, spec in stairwellRooms(layout.id) do
			table.insert(if spec.from == layout.id then exits else entries, roomId)
		end
		table.sort(entries)
		table.sort(exits)
	end
	for _, entry in entries do
		if not rooms[entry] then
			continue
		end
		local seen = reachable(layout, entry, true)
		for _, exit in exits do
			if rooms[exit] and not seen["room:" .. exit] then
				pushf(errors, "exit %s is unreachable from %s once lockable grates lock and gates shut", exit, entry)
			end
		end
	end

	return errors
end

return table.freeze(LayoutSchema)
