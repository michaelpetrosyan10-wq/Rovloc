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
	shadows: boolean?, -- default false (render budget)
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
-- Validation. Returns a list of human-readable problems; an empty list means the layout is buildable.
--------------------------------------------------------------------------------

local function pushf(errors: { string }, fmt: string, ...: any)
	table.insert(errors, string.format(fmt, ...))
end

local function isSchoolLevel(layout: LevelLayout): boolean
	return layout.id ~= "Lobby"
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

function LayoutSchema.validate(layout: LevelLayout): { string }
	local errors: { string } = {}
	local rooms = LayoutSchema.indexRooms(layout)
	local footprint = LayoutSchema.rect(0, 0, WorldConfig.FootprintSize.X, WorldConfig.FootprintSize.Y)
	local seenIds: { [string]: string } = {}

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
		for _, edge in vents.edges do
			local a, b = nodes[edge.a], nodes[edge.b]
			if not a or not b then
				pushf(errors, "vent edge %s-%s references a missing node", edge.a, edge.b)
				continue
			end
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
			if not LayoutSchema.sideOfPoint(room.rect, node.x, node.z) then
				pushf(errors, "grate %s node %s is not on a wall of room %s", grate.id, node.id, room.id)
			end
			local onChase = false
			for _, chase in chases do
				if
					LayoutSchema.sideOfPoint(chase.rect, node.x, node.z)
					and LayoutSchema.sharedEdge(chase.rect, room.rect)
				then
					onChase = true
				end
			end
			if not onChase then
				pushf(
					errors,
					"grate %s node %s is not on a wall shared by a chase and room %s",
					grate.id,
					node.id,
					room.id
				)
			end
			if grate.lockable and grate.criticalPath then
				pushf(errors, "grate %s cannot be both lockable and on the critical path", grate.id)
			end
		end
	end

	-- Anchors, triggers, basins, platforms, pillars, windows
	for _, anchor in layout.anchors do
		claimId(anchor.id, "anchor")
		local room = rooms[anchor.room]
		if not room then
			pushf(errors, "anchor %s references missing room %s", anchor.id, anchor.room)
		elseif not LayoutSchema.rectContains(room.rect, anchor.pos.X, anchor.pos.Z) then
			pushf(errors, "anchor %s lies outside room %s", anchor.id, anchor.room)
		end
	end
	for _, trigger in layout.triggers do
		claimId(trigger.id, "trigger")
		local room = rooms[trigger.room]
		if not room then
			pushf(errors, "trigger %s references missing room %s", trigger.id, trigger.room)
		elseif not LayoutSchema.rectInside(trigger.rect, room.rect) then
			pushf(errors, "trigger %s leaves room %s", trigger.id, trigger.room)
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
		end
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
			if
				not edge
				or opening.centerZ - opening.width / 2 < edge.from - EPS
				or opening.centerZ + opening.width / 2 > edge.to + EPS
			then
				pushf(
					errors,
					"room %s must touch the %s tower across Z %.0f +/- %.0f",
					roomId,
					spec.tower,
					opening.centerZ,
					opening.width / 2
				)
			end
		end
	end

	-- Solvability: the exit must be reachable with every lockable grate locked and every gate shut.
	if rooms[layout.entry] and rooms[layout.exit] then
		local seen = reachable(layout, layout.entry, true)
		if not seen["room:" .. layout.exit] then
			pushf(
				errors,
				"exit %s is unreachable from %s once lockable grates lock and gates shut",
				layout.exit,
				layout.entry
			)
		end
	end

	return errors
end

return table.freeze(LayoutSchema)
