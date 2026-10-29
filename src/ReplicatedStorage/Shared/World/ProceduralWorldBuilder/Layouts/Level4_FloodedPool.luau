--!strict
-- Level 4 · Flooded Olympic Pool. The squad arrives in L4_AirlockWest from Stairwell_3_4 and must reach
-- L4_AirlockEast on the far side of the natatorium.
--
-- Plan (X west -> east, Z north -> south):
--   z   0..25  staff room, laundry, filter room | pump room, chlorine store (filter/pump wall collapsed)
--   z  25..30  L4_Chase_Maintenance: a half-flooded service duct along the natatorium's north wall
--   z  30..130 changing rooms + showers + lifeguard office (x 0..90) | NATATORIUM (x 90..228, 28 tall)
--   z 130..160 plant room, spectator gallery, scoreboard room
-- The natatorium is almost all basin: deep murky water wall to wall (x 128..214), a 38-stud west deck and a 14-stud
-- east deck. The old spectator bridge across the pool has collapsed into 8-stud-wide slabs on their broken piers,
-- parted by step-over cracks, with one fallen span mid-pool (a 12-stud swim); a north spur runs to the maintenance
-- duct's jammed west hatch and a south spur into the deep end, and fallen roof slabs are rest islands, so the dry
-- route covers most of the hall and every swim between safe dry spots is short (see the pool section). The
-- maintenance duct is sunk to the pool's waterline: its centre sits at the water surface, so the murky water fills
-- the lower half of the bore (every duct edge is Submerged, VentShaftBuilder floods it, and a PoolWater volume covers
-- the flooded half). It runs through the chase floor into the void above the Level 3 ceilings, and its grates all
-- open low in the natatorium's north wall, straight over the water: the crawl is FallenSlab_A -> a short swim to
-- L4_Grate_M_PoolWest (behind the hatch the floor objective opens) -> half-flooded crawl east -> out at
-- L4_Grate_M_PoolEast beside the east deck. The two grates between them may be locked; they are the Creature's ways
-- in and out of the duct from the deep water.
--
-- The 9 Floodlight fixtures over the pool start dark (broken) in FlickerGroup "L4_Floodlights"; the emergency
-- FloodlightSwitch on the west deck (P7) brings them up through LightingController overrides.
--
-- Anchor heights: props on the floor or on the starting blocks they stand on, DripPipe under the ceiling,
-- PlayerSpawn at root height plus clearance (3.5), Creature placements at the rig's root height (5; the pool
-- spawn and the pool patrol are under water). Yaw: 0 faces north (-Z), 90 west, 180 south, -90 east.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)

type Room = LayoutSchema.Room

type Style = {
	floor: string,
	wall: string,
	ceiling: string,
	surface: Enums.SurfaceKind,
	acoustic: Enums.AcousticPreset,
}

type LightOptions = {
	id: string?,
	brightness: number?,
	range: number?,
	color: Color3?,
	flicker: string?,
	broken: boolean?,
}

type LightDefaults = { brightness: number, range: number, color: Color3 }

type DoorOptions = { id: string?, width: number?, height: number?, scriptedId: string? }

type GratePlan = {
	id: string,
	room: string, -- the room the grate opens into
	side: LayoutSchema.Side, -- which side of the chase the grate sits on
	at: number?, -- position along the chase for grates on its long sides
	lockable: boolean,
	critical: boolean,
}

type Stop = { coord: number, node: string }

local PREFIX = "L4"
local HEIGHT = WorldConfig.Levels.Level4_FloodedPool.height
local LOW = 14 -- ceiling of the rooms around the natatorium
local DUCT_ROOM = 6 -- the maintenance chase is a low service tunnel
local WATER = WorldConfig.WaterSurfaceOffset
local POOL_DEPTH = 10
local HALF_BORE = WorldConfig.VentBore / 2
local DUCT_Y = WATER -- the flooded duct's centre line: the water surface halves the bore

local FACE_N, FACE_W, FACE_S, FACE_E = 0, 90, 180, -90

local LIGHT_DEFAULTS: { [string]: LightDefaults } = {
	Fluorescent = { brightness = 0.55, range = 18, color = Color3.fromRGB(214, 232, 236) },
	Bulb = { brightness = 0.45, range = 14, color = Color3.fromRGB(255, 196, 140) },
	EmergencyRed = { brightness = 0.45, range = 16, color = Color3.fromRGB(255, 34, 18) },
	ClassroomGlow = { brightness = 1.1, range = 34, color = Color3.fromRGB(198, 220, 255) },
	Floodlight = { brightness = 2, range = 60, color = Color3.fromRGB(226, 238, 255) },
	ExitSign = { brightness = 0.3, range = 8, color = Color3.fromRGB(70, 255, 120) },
	BoilerGlow = { brightness = 0.7, range = 14, color = Color3.fromRGB(255, 118, 40) },
}

local NATATORIUM: Style =
	{ floor = "PoolTile", wall = "TileBlue", ceiling = "MetalGalvanized", surface = "Tile", acoustic = "Hall" }
local CHANGING: Style =
	{ floor = "TileBlue", wall = "TileWhite", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local SHOWERS: Style =
	{ floor = "TileWhite", wall = "TileBlue", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local CORRIDOR: Style =
	{ floor = "TileWhite", wall = "PlasterSchool", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Corridor" }
local OFFICE: Style =
	{ floor = "Linoleum", wall = "PlasterSchool", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local PLANT: Style =
	{ floor = "Concrete", wall = "ConcreteDark", ceiling = "ConcreteDark", surface = "Concrete", acoustic = "Basement" }
local CHEMICALS: Style = {
	floor = "ConcreteStained",
	wall = "MetalGalvanized",
	ceiling = "ConcreteDark",
	surface = "Concrete",
	acoustic = "Room",
}
local BOILERS: Style =
	{ floor = "ConcreteStained", wall = "Brick", ceiling = "ConcreteDark", surface = "Concrete", acoustic = "Basement" }
local GALLERY: Style =
	{ floor = "Linoleum", wall = "PlasterSchool", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Hall" }
local STORAGE: Style =
	{ floor = "ConcreteStained", wall = "ConcreteDark", ceiling = "Concrete", surface = "Concrete", acoustic = "Room" }
local AIRLOCK: Style =
	{ floor = "Concrete", wall = "ConcreteDark", ceiling = "Concrete", surface = "Concrete", acoustic = "Stairwell" }
local CHASE: Style =
	{ floor = "ConcreteDark", wall = "ConcreteDark", ceiling = "ConcreteDark", surface = "Water", acoustic = "Vent" }

--------------------------------------------------------------------------------
-- Blueprint helpers
--------------------------------------------------------------------------------

local rooms: { Room } = {}
local roomById: { [string]: Room } = {}
local doors: { LayoutSchema.Door } = {}
local anchors: { LayoutSchema.Anchor } = {}
local anchorCounts: { [string]: number } = {}
local triggers: { LayoutSchema.Trigger } = {}
local windows: { LayoutSchema.Window } = {}
local platforms: { LayoutSchema.Platform } = {}
local basins: { LayoutSchema.Basin } = {}
local ventNodes: { LayoutSchema.VentNodeSpec } = {}
local ventEdges: { LayoutSchema.VentEdgeSpec } = {}
local grates: { LayoutSchema.GrateSpec } = {}
local lightCount = 0

local function room(
	id: string,
	kind: Enums.RoomKind,
	x: number,
	z: number,
	w: number,
	d: number,
	style: Style,
	height: number?
): Room
	local entry: Room = {
		id = id,
		kind = kind,
		rect = LayoutSchema.rect(x, z, w, d),
		height = height,
		floor = style.floor,
		wall = style.wall,
		ceiling = style.ceiling,
		surface = style.surface,
		acoustic = style.acoustic,
		lights = {},
	}
	table.insert(rooms, entry)
	roomById[id] = entry
	return entry
end

local function getRoom(id: string): Room
	local found = roomById[id]
	if not found then
		error(string.format("%s layout: unknown room %s", PREFIX, id), 2)
	end
	return found
end

-- The non-chase room holding (x, z) at least 0.25 studs inside its walls.
local function roomAt(x: number, z: number): string
	for _, candidate in rooms do
		if candidate.kind ~= "Chase" and LayoutSchema.rectContains(candidate.rect, x, z, 0.25) then
			return candidate.id
		end
	end
	error(string.format("%s layout: no room holds (%.1f, %.1f)", PREFIX, x, z), 2)
end

local function light(roomId: string, kind: Enums.LightKind, x: number, y: number, z: number, options: LightOptions?)
	local o: LightOptions = options or {}
	local defaults = LIGHT_DEFAULTS[kind]
	lightCount += 1
	local list = getRoom(roomId).lights
	if list then
		table.insert(list, {
			id = o.id or string.format("%s_Light_%03d", PREFIX, lightCount),
			kind = kind,
			pos = Vector3.new(x, y, z),
			brightness = o.brightness or defaults.brightness,
			range = o.range or defaults.range,
			color = o.color or defaults.color,
			flickerGroup = o.flicker,
			broken = o.broken,
		})
	end
end

-- nx * nz ceiling fixtures spread evenly over a room. `pattern` is read cyclically, one character per fixture:
-- "x" = broken, "o" = lit (dim, steady), "f" = lit and flickering with options.flicker.
local function lightGrid(
	roomId: string,
	kind: Enums.LightKind,
	nx: number,
	nz: number,
	pattern: string,
	options: LightOptions?
)
	local target = getRoom(roomId)
	local rect = target.rect
	local y = (target.height or HEIGHT) - 0.4
	local o: LightOptions = options or {}
	local index = 0
	for i = 1, nx do
		for j = 1, nz do
			index += 1
			local p = ((index - 1) % #pattern) + 1
			local mark = string.sub(pattern, p, p)
			light(roomId, kind, rect.x + rect.w * (i - 0.5) / nx, y, rect.z + rect.d * (j - 0.5) / nz, {
				brightness = o.brightness,
				range = o.range,
				color = o.color,
				flicker = if mark == "f" then o.flicker else nil,
				broken = mark == "x",
			})
		end
	end
end

local function door(kind: Enums.DoorKind, a: string, b: string, at: number?, options: DoorOptions?)
	local o: DoorOptions = options or {}
	local roomA, roomB = getRoom(a), getRoom(b)
	local position: number
	if at then
		position = at
	else
		local edge = LayoutSchema.sharedEdge(roomA.rect, roomB.rect)
		position = if edge then (edge.from + edge.to) / 2 else 0
	end
	table.insert(doors, {
		id = o.id or string.format("%s_Door_%02d", PREFIX, #doors + 1),
		kind = kind,
		rooms = { a, b },
		at = position,
		width = o.width,
		height = o.height,
		scriptedId = o.scriptedId,
	})
end

local function anchor(kind: Enums.AnchorKind, x: number, y: number, z: number, yaw: number?, id: string?)
	local n = (anchorCounts[kind] or 0) + 1
	anchorCounts[kind] = n
	table.insert(anchors, {
		id = id or string.format("%s_%s_%02d", PREFIX, kind, n),
		kind = kind,
		room = roomAt(x, z),
		pos = Vector3.new(x, y, z),
		yaw = yaw,
	})
end

-- Each point is { x, z } or { x, z, yaw }.
local function scatter(kind: Enums.AnchorKind, y: number, points: { { number } })
	for _, p in points do
		anchor(kind, p[1], y, p[2], p[3])
	end
end

-- A closed patrol loop at height `y`: waypoint i leads to i + 1 and the last back to the first, each hop within one
-- room or through one doorway.
local function patrol(loop: string, y: number, points: { { number } })
	for i, p in points do
		anchor("PatrolWaypoint", p[1], y, p[2], nil, string.format("%s_WP_%s_%02d", PREFIX, loop, i))
	end
end

local function trigger(
	id: string,
	kind: Enums.TriggerKind,
	x: number,
	z: number,
	w: number,
	d: number,
	height: number,
	y: number?,
	roomId: string?
)
	table.insert(triggers, {
		id = id,
		kind = kind,
		room = if roomId then getRoom(roomId).id else roomAt(x + w / 2, z + d / 2),
		rect = LayoutSchema.rect(x, z, w, d),
		height = height,
		y = y,
	})
end

-- Evenly spaced windows on one side of a room; any that would face a stair tower are left out.
local TOWER_MIN_Z = WorldConfig.Towers.West.minZ - 2
local TOWER_MAX_Z = WorldConfig.Towers.West.maxZ + 2
local function windowRow(
	roomId: string,
	side: LayoutSchema.Side,
	count: number,
	width: number,
	height: number,
	sill: number,
	boarded: boolean
)
	local rect = getRoom(roomId).rect
	local alongX = side == "N" or side == "S"
	local from = if alongX then rect.x else rect.z
	local span = if alongX then rect.w else rect.d
	for i = 1, count do
		local at = from + span * (i - 0.5) / count
		local facesTower = not alongX and at + width / 2 > TOWER_MIN_Z and at - width / 2 < TOWER_MAX_Z
		if not facesTower then
			table.insert(
				windows,
				{ room = roomId, side = side, at = at, width = width, height = height, sill = sill, boarded = boarded }
			)
		end
	end
end

local function platform(
	id: string,
	roomId: string,
	x: number,
	z: number,
	w: number,
	d: number,
	top: number,
	thickness: number,
	material: string
)
	getRoom(roomId)
	table.insert(platforms, {
		id = id,
		room = roomId,
		rect = LayoutSchema.rect(x, z, w, d),
		top = top,
		thickness = thickness,
		material = material,
	})
end

-- One straight duct along the middle of a chase, a junction under every side grate, end grates as terminals.
-- A duct never leaves its chase, so each chase room carries exactly one run. `y` is the duct centre above the floor
-- (default WorldConfig.VentCenterHeight).
local function chaseRun(chaseId: string, plans: { GratePlan }, submerged: boolean?, y: number?)
	local rect = getRoom(chaseId).rect
	local alongX = rect.w > rect.d
	local cx, cz = rect.x + rect.w / 2, rect.z + rect.d / 2
	local stops: { Stop } = {}
	local stubs: { { string } } = {}
	local function stop(coord: number, existing: string?): string
		for _, s in stops do
			if math.abs(s.coord - coord) < 1e-3 then
				return s.node
			end
		end
		local nodeId = existing or string.format("%s_J%02d", chaseId, #stops + 1)
		if not existing then
			table.insert(
				ventNodes,
				{ id = nodeId, x = if alongX then coord else cx, z = if alongX then cz else coord, y = y }
			)
		end
		table.insert(stops, { coord = coord, node = nodeId })
		return nodeId
	end
	for _, plan in plans do
		local along = plan.at or 0
		local isEnd = if alongX then plan.side == "W" or plan.side == "E" else plan.side == "N" or plan.side == "S"
		local x, z = 0, 0
		if alongX then
			if plan.side == "N" then
				x, z = along, rect.z
			elseif plan.side == "S" then
				x, z = along, rect.z + rect.d
			elseif plan.side == "W" then
				x, z = rect.x, cz
			else
				x, z = rect.x + rect.w, cz
			end
		else
			if plan.side == "W" then
				x, z = rect.x, along
			elseif plan.side == "E" then
				x, z = rect.x + rect.w, along
			elseif plan.side == "N" then
				x, z = cx, rect.z
			else
				x, z = cx, rect.z + rect.d
			end
		end
		local nodeId = plan.id .. "_Node"
		table.insert(ventNodes, { id = nodeId, x = x, z = z, y = y })
		table.insert(grates, {
			id = plan.id,
			node = nodeId,
			room = plan.room,
			lockable = plan.lockable,
			criticalPath = plan.critical,
		})
		if isEnd then
			stop(if alongX then x else z, nodeId)
		else
			table.insert(stubs, { nodeId, stop(along) })
		end
	end
	table.sort(stops, function(a: Stop, b: Stop): boolean
		return a.coord < b.coord
	end)
	for i = 1, #stops - 1 do
		table.insert(ventEdges, { a = stops[i].node, b = stops[i + 1].node, submerged = submerged })
	end
	for _, stub in stubs do
		table.insert(ventEdges, { a = stub[1], b = stub[2], submerged = submerged })
	end
end

local function deepFreeze(value: unknown)
	if type(value) == "table" then
		local t = value :: { [unknown]: unknown }
		if not table.isfrozen(t) then
			table.freeze(t)
			for _, child in t do
				deepFreeze(child)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Rooms
--------------------------------------------------------------------------------

-- North service row
room("L4_StaffRoom", "Office", 0, 0, 40, 25, OFFICE, LOW)
room("L4_Laundry", "Storage", 40, 0, 50, 25, SHOWERS, LOW)
room("L4_FilterRoom", "Boiler", 90, 0, 50, 25, PLANT, LOW)
room("L4_PumpRoom", "Boiler", 140, 0, 50, 25, PLANT, LOW)
room("L4_ChlorineStore", "Storage", 190, 0, 50, 25, CHEMICALS, LOW)

-- West wing: changing rooms off the pool corridor
room("L4_Storage_W1", "Storage", 0, 25, 12, 41, STORAGE, LOW)
room("L4_ChangingRoom_Boys", "LockerRoom", 12, 25, 44, 48, CHANGING, LOW)
room("L4_Showers_Boys", "Restroom", 56, 25, 34, 28, SHOWERS, LOW)
room("L4_LifeguardOffice", "Office", 56, 53, 34, 20, OFFICE, LOW)
room("L4_AirlockWest", "Airlock", 0, 66, 12, 28, AIRLOCK, LOW)
room("L4_Corridor_West", "Corridor", 12, 73, 78, 14, CORRIDOR, LOW)
room("L4_Storage_W2", "Storage", 0, 94, 12, 36, STORAGE, LOW)
room("L4_ChangingRoom_Girls", "LockerRoom", 12, 87, 44, 43, CHANGING, LOW)
room("L4_FirstAid", "Office", 56, 87, 34, 20, OFFICE, LOW)
room("L4_Showers_Girls", "Restroom", 56, 107, 34, 23, SHOWERS, LOW)

-- The natatorium and its flooded maintenance duct
room("L4_Chase_Maintenance", "Chase", 90, 25, 138, 5, CHASE, DUCT_ROOM)
room("L4_Natatorium", "Pool", 90, 30, 138, 100, NATATORIUM)

-- East end
room("L4_Storage_E1", "Storage", 228, 25, 12, 41, STORAGE, LOW)
room("L4_AirlockEast", "Airlock", 228, 66, 12, 28, AIRLOCK, LOW)
room("L4_Storage_E2", "Storage", 228, 94, 12, 36, STORAGE, LOW)

-- South row
room("L4_PlantRoom", "Boiler", 0, 130, 90, 30, BOILERS, LOW)
room("L4_SpectatorGallery", "Corridor", 90, 130, 110, 30, GALLERY, LOW)
room("L4_ScoreboardRoom", "Storage", 200, 130, 40, 30, STORAGE, LOW)

--------------------------------------------------------------------------------
-- Doors
--------------------------------------------------------------------------------

door("Airlock", "L4_AirlockWest", "L4_Corridor_West", 80, { id = "L4_Door_AirlockWest" })
door("Airlock", "L4_Natatorium", "L4_AirlockEast", 80, { id = "L4_Door_AirlockEast" })
door("Doorway", "L4_Corridor_West", "L4_Natatorium", 80, { width = 8 })

door("Door", "L4_Corridor_West", "L4_ChangingRoom_Boys", 34)
door("Door", "L4_Corridor_West", "L4_LifeguardOffice", 73)
door("Door", "L4_Corridor_West", "L4_ChangingRoom_Girls", 34)
door("Door", "L4_Corridor_West", "L4_FirstAid", 73)
door("Doorway", "L4_ChangingRoom_Boys", "L4_Showers_Boys", 40)
door("Doorway", "L4_Showers_Boys", "L4_Natatorium", 42)
door("Door", "L4_LifeguardOffice", "L4_Natatorium", 63)
door("Doorway", "L4_ChangingRoom_Girls", "L4_Showers_Girls", 118)
door("Doorway", "L4_Showers_Girls", "L4_Natatorium", 118)
door("Door", "L4_FirstAid", "L4_Natatorium", 97)
door("Door", "L4_Storage_W1", "L4_ChangingRoom_Boys", 45)
door("Door", "L4_Storage_W2", "L4_ChangingRoom_Girls", 112)
door("Door", "L4_StaffRoom", "L4_ChangingRoom_Boys", 26)
door("Door", "L4_Laundry", "L4_ChangingRoom_Boys", 48)
door("Door", "L4_Laundry", "L4_FilterRoom", 12)
door("Boarded", "L4_FilterRoom", "L4_PumpRoom", 12, { id = "L4_Door_PumpCollapse" })
door("Door", "L4_PumpRoom", "L4_ChlorineStore", 12)
door("Door", "L4_ChlorineStore", "L4_Storage_E1", 234)
door("Door", "L4_Storage_E1", "L4_Natatorium", 48)
door("Door", "L4_Storage_E2", "L4_Natatorium", 112)
door("Door", "L4_Storage_E2", "L4_ScoreboardRoom", 234)
door("Door", "L4_SpectatorGallery", "L4_Natatorium", 108, { width = 8 })
door("Boarded", "L4_SpectatorGallery", "L4_ScoreboardRoom", 145, { id = "L4_Door_GalleryCollapse" })
door("Door", "L4_PlantRoom", "L4_ChangingRoom_Girls", 34)
door("Door", "L4_PlantRoom", "L4_SpectatorGallery", 145)

--------------------------------------------------------------------------------
-- The pool: one deep basin wall to wall, the collapsed bridge, debris and the deck furniture
--------------------------------------------------------------------------------

table.insert(basins, {
	id = "L4_Basin_Pool",
	room = "L4_Natatorium",
	rect = LayoutSchema.rect(128, 30, 86, 100),
	depth = POOL_DEPTH,
	waterLevel = WATER,
})

-- The collapsed spectator bridge, a walkway the squad can trust: 8-stud-wide deck slabs awash just over the surface,
-- each standing on its broken piers (Bridge_1 and Bridge_4 also rest on the coping), parted only by step-over cracks
-- (CRACK: no jump), except where one span fell into the deep water mid-pool: a 12-stud swim. Two spurs of fallen
-- walkway branch off it, cracked the same way: north to FallenSlab_A off the maintenance duct's west grate (the jammed
-- hatch), south into the deep end to FallenSlab_B, which meets the diving tower's concrete footing, itself flush with
-- the east deck's coping. FallenSlab_C and _D, fallen from the roof, are rest islands in the open water. So the dry
-- route covers most of the hall, no swim between two safe dry spots is longer than about 25 studs (the swim legs
-- below), and every valve-wheel spot on the pool floor is 12 studs or less of swim from a dry spot.
-- Every support runs from the basin floor up to the underside of what it carries.
local CRACK = 1.2 -- a step-over crack between two walkway slabs (the body never loses the floor crossing it)
local function onPiers(
	id: string,
	x: number,
	z: number,
	w: number,
	d: number,
	top: number,
	thickness: number,
	material: string,
	piers: { { number } }
)
	platform(id, "L4_Natatorium", x, z, w, d, top, thickness, material)
	local underside = top - thickness
	for i, pier in piers do
		platform(
			if i == 1 then id .. "_Pier" else string.format("%s_Pier%d", id, i),
			"L4_Natatorium",
			pier[1],
			pier[2],
			pier[3],
			pier[4],
			underside,
			underside + POOL_DEPTH,
			"ConcreteDark"
		)
	end
end
-- The bridge, west to east along z 76..84; the fallen span leaves open water from x 164 to 176.
local BRIDGE_Z, BRIDGE_D = 76, 8
onPiers("L4_Bridge_1", 128, BRIDGE_Z, 18, BRIDGE_D, 0, 1.2, "Concrete", { { 131, 78.5, 3, 3 }, { 141, 78.5, 3, 3 } })
onPiers(
	"L4_Bridge_2",
	146 + CRACK,
	BRIDGE_Z,
	164 - 146 - CRACK,
	BRIDGE_D,
	-0.2,
	1,
	"Concrete",
	{ { 150, 78.5, 3, 3 }, { 160, 78.5, 3, 3 } }
)
onPiers("L4_Bridge_3", 176, BRIDGE_Z, 18, BRIDGE_D, -0.3, 1, "Concrete", { { 178, 78.5, 3, 3 }, { 187, 78.5, 3, 3 } })
onPiers(
	"L4_Bridge_4",
	194 + CRACK,
	BRIDGE_Z,
	214 - 194 - CRACK,
	BRIDGE_D,
	0,
	1.2,
	"Concrete",
	{ { 203, 78.5, 3, 3 }, { 209, 78.5, 3, 3 } }
)
-- North spur off Bridge_1 to the duct's west grate.
onPiers("L4_Walk_N1", 138, 62, 8, BRIDGE_Z - CRACK - 62, -0.3, 1, "Concrete", { { 140.5, 66.5, 3, 3 } })
onPiers("L4_Walk_N2", 138, 48, 8, 62 - CRACK - 48, -0.5, 1, "Concrete", { { 140.5, 52.5, 3, 3 } })
onPiers("L4_FallenSlab_A", 138, 39, 14, 48 - CRACK - 39, -0.6, 1.2, "ConcreteStained", { { 144.5, 40.5, 5, 4 } })
-- South spur off Bridge_3 into the deep end.
local SOUTH_Z = BRIDGE_Z + BRIDGE_D + CRACK
onPiers("L4_Walk_S1", 186, SOUTH_Z, 8, 98 - SOUTH_Z, -0.3, 1, "Concrete", { { 188.5, 90, 3, 3 } })
onPiers("L4_Walk_S2", 186, 98 + CRACK, 8, 112 - 98 - CRACK, -0.5, 1, "Concrete", { { 188.5, 104, 3, 3 } })
onPiers(
	"L4_FallenSlab_B",
	186,
	112 + CRACK,
	203 - CRACK - 186,
	121 - 112 - CRACK,
	-0.4,
	1,
	"ConcreteStained",
	{ { 191, 115, 5, 4 } }
)
-- The diving tower's concrete footing, awash round its foot from FallenSlab_B to the east coping.
platform("L4_TowerBase", "L4_Natatorium", 203, 114, 11, 13, -0.4, POOL_DEPTH - 0.4, "ConcreteDark")
-- Rest islands: roof slabs fallen into the open water.
onPiers("L4_FallenSlab_C", 156, 104, 8, 7, -0.5, 1, "ConcreteStained", { { 158.5, 106, 4, 3 } })
onPiers("L4_FallenSlab_D", 174, 44, 8, 7, -0.6, 1.2, "ConcreteStained", { { 176.5, 46, 4, 3 } })
-- The diving tower stands in the deep end, off the duct's east grate.
platform("L4_DivingTower", "L4_Natatorium", 207, 118, 6, 6, 10, POOL_DEPTH + 10, "Concrete")
for i, z in { 40, 52, 64, 96, 108, 120 } do
	platform(string.format("L4_StartBlock_%d", i), "L4_Natatorium", 124, z, 3, 3, 1.5, 1.5, "PoolTile")
end

--------------------------------------------------------------------------------
-- The flooded maintenance duct (every edge Submerged), sunk to the waterline. Every grate opens over the basin: a
-- grate this low over the dry deck or into the service rooms would open into their floor.
--------------------------------------------------------------------------------

local DUCT_WEST, DUCT_EAST = 150, 208 -- the two critical grates (centres along the north wall)

chaseRun("L4_Chase_Maintenance", {
	{
		id = "L4_Grate_M_PoolWest",
		room = "L4_Natatorium",
		side = "S",
		at = DUCT_WEST,
		lockable = false,
		critical = true,
	},
	{ id = "L4_Grate_M_PoolMidW", room = "L4_Natatorium", side = "S", at = 166, lockable = true, critical = false },
	{ id = "L4_Grate_M_PoolMidE", room = "L4_Natatorium", side = "S", at = 190, lockable = true, critical = false },
	{
		id = "L4_Grate_M_PoolEast",
		room = "L4_Natatorium",
		side = "S",
		at = DUCT_EAST,
		lockable = false,
		critical = true,
	},
}, true, DUCT_Y)

--------------------------------------------------------------------------------
-- Lights
--------------------------------------------------------------------------------

local floodlight = 0
for _, x in { 140, 171, 202 } do
	for _, z in { 45, 80, 115 } do
		floodlight += 1
		light("L4_Natatorium", "Floodlight", x, HEIGHT - 0.6, z, {
			id = string.format("L4_Floodlight_%02d", floodlight),
			flicker = "L4_Floodlights",
			broken = true,
		})
	end
end
lightGrid("L4_Natatorium", "Bulb", 2, 4, "x")
light("L4_Natatorium", "EmergencyRed", 225, LOW - 2, 80, { flicker = "L4_ExitEast", brightness = 0.5, range = 20 })
light("L4_Natatorium", "ExitSign", 226.5, 11, 80)
light("L4_Natatorium", "EmergencyRed", 93, LOW - 2, 80, { flicker = "L4_DeckWest", brightness = 0.3 })

lightGrid("L4_Corridor_West", "Fluorescent", 5, 1, "xxfxx", { flicker = "L4_Corridor", brightness = 0.3 })
for _, id in
	{
		"L4_ChangingRoom_Boys",
		"L4_ChangingRoom_Girls",
		"L4_StaffRoom",
		"L4_Laundry",
		"L4_FirstAid",
		"L4_SpectatorGallery",
	} :: { string }
do
	lightGrid(id, "Fluorescent", 2, 2, "x")
end
lightGrid("L4_Showers_Boys", "Fluorescent", 1, 2, "x")
lightGrid("L4_Showers_Girls", "Fluorescent", 1, 2, "fx", { flicker = "L4_ShowersGirls", brightness = 0.25 })
lightGrid("L4_LifeguardOffice", "Bulb", 1, 1, "o", { brightness = 0.2, range = 10 })
for _, id in
	{
		"L4_FilterRoom",
		"L4_PumpRoom",
		"L4_ChlorineStore",
		"L4_Storage_W1",
		"L4_Storage_W2",
		"L4_Storage_E1",
		"L4_Storage_E2",
		"L4_ScoreboardRoom",
	} :: { string }
do
	lightGrid(id, "Bulb", 1, 1, "x")
end
lightGrid("L4_PlantRoom", "Bulb", 3, 1, "x")
light("L4_PlantRoom", "BoilerGlow", 20, 2, 150, { flicker = "L4_PoolHeater" })
light("L4_AirlockWest", "EmergencyRed", 6, LOW - 1, 80, { flicker = "L4_AirlockWest", brightness = 0.35 })
light("L4_AirlockEast", "EmergencyRed", 234, LOW - 1, 80, { flicker = "L4_AirlockEast", brightness = 0.35 })

--------------------------------------------------------------------------------
-- Anchors
--------------------------------------------------------------------------------

-- Arrival from Stairwell_3_4
scatter("PlayerSpawn", 3.5, { { 4, 74, FACE_E }, { 8, 74, FACE_E }, { 4, 86, FACE_E }, { 8, 86, FACE_E } })
-- The Creature waits on the pool floor (AquaticStalk).
anchor("CreatureSpawn", 171, WATER - 4, 100, FACE_N, "L4_CreatureSpawn")
anchor("FloodlightSwitch", 91.5, 4, 70, FACE_E, "L4_FloodlightSwitch")

-- Floor objective (ValveWheel): the valve wheel lies on the deep pool floor at one of three spots, each 12 studs or
-- less of swim from dry footing (the south spur, FallenSlab_C, the tower's footing); the hatch valve is the jammed
-- watertight hatch over the duct's west grate on the inner face of the north coping, its valve socket half under the
-- water (the anchor is the grate's centre at the waterline, facing into the hall), a short swim from FallenSlab_A; the
-- exit lock on the east stair airlock's fire door. On this floor the Creature cannot leave the water, so dry footing is
-- the hiding spot near every step.
scatter("ValveWheelCandidate", -POOL_DEPTH, {
	{ 180, 106 },
	{ 202, 104 },
	{ 166, 121 },
})
anchor("HatchValve", 150, WATER, 31, FACE_S, "L4_HatchValve")
anchor("ExitLock", 227.5, 0, 80, FACE_W, "L4_ExitLock")

-- Flasks left on the starting blocks and the decks
scatter("FlaskCandidate", 1.5, { { 125.5, 41.5 }, { 125.5, 65.5 }, { 125.5, 109.5 } })
scatter("FlaskCandidate", 0, { { 220, 60 }, { 220, 120 }, { 100, 112 } })

scatter("BatteryCandidate", 0, {
	{ 60, 70 },
	{ 86, 90 },
	{ 4, 4 },
	{ 186, 4 },
	{ 236, 4 },
	{ 234, 126 },
	{ 196, 156 },
	{ 4, 156 },
	{ 86, 126 },
})

anchor("Corpse", 154, -0.2, 80, 35)
scatter("Corpse", 0, { { 70, 30, 120 }, { 150, 150, -60 } })
scatter("DripPipe", LOW - 1.2, { { 30, 50 }, { 50, 80 }, { 40, 145 }, { 70, 118 }, { 110, 12 } })
anchor("DripPipe", 110, HEIGHT - 1.2, 50)
scatter("Clutter", 0, {
	{ 100, 50, 0 },
	{ 112, 96, 30 },
	{ 104, 124, -15 },
	{ 222, 100, 90 },
	{ 30, 40, 10 },
	{ 30, 110, -20 },
	{ 70, 95, 0 },
	{ 120, 145, 45 },
	{ 170, 150, 0 },
	{ 60, 150, 60 },
	{ 160, 12, 0 },
	{ 215, 12, 30 },
})

patrol("DW", 0, { { 95, 36 }, { 122, 36 }, { 122, 124 }, { 95, 124 } })
patrol("DE", 0, { { 218, 36 }, { 225, 80 }, { 218, 124 }, { 216, 80 } })
patrol("POOL", WATER - 3, { { 156, 56 }, { 200, 56 }, { 200, 100 }, { 156, 96 } })
patrol("WR", 0, { { 30, 80 }, { 34, 60 }, { 73, 40 }, { 100, 42 }, { 100, 80 }, { 80, 80 } })
patrol("WS", 0, { { 34, 84 }, { 34, 100 }, { 73, 118 }, { 100, 118 }, { 100, 84 }, { 80, 84 } })

--------------------------------------------------------------------------------
-- Triggers
--------------------------------------------------------------------------------

-- The flooded lower half of the maintenance duct's bore: from the bore floor up to the water surface, along the run
-- (whose capped ends reach half a bore past the end grates) and on through the branches to the chase's south wall.
-- Everything else inside this box is duct shell or slab, so any point a crawler can reach in it is in the water.
local chaseRect = getRoom("L4_Chase_Maintenance").rect
local boreNorth = chaseRect.z + chaseRect.d / 2 - HALF_BORE
trigger(
	"L4_Water_MaintenanceDuct",
	"PoolWater",
	DUCT_WEST - HALF_BORE,
	boreNorth,
	DUCT_EAST - DUCT_WEST + 2 * HALF_BORE,
	chaseRect.z + chaseRect.d - boreNorth,
	HALF_BORE,
	DUCT_Y - HALF_BORE,
	"L4_Chase_Maintenance"
)
trigger("L4_Trigger_DebrisCorridor", "FloorDebris", 40, 75, 6, 10, 4)
trigger("L4_Trigger_DebrisShowers", "FloorDebris", 64, 30, 6, 6, 4)
trigger("L4_Trigger_Checkpoint", "Checkpoint", 229, 67, 10, 26, 10)

--------------------------------------------------------------------------------
-- Boarded windows on the facade
--------------------------------------------------------------------------------

windowRow("L4_StaffRoom", "N", 2, 7, 6, 3.5, true)
windowRow("L4_Laundry", "N", 2, 5, 3, 8, true)
windowRow("L4_FilterRoom", "N", 2, 5, 3, 8, true)
windowRow("L4_PumpRoom", "N", 2, 5, 3, 8, true)
windowRow("L4_ChlorineStore", "N", 2, 5, 3, 8, true)
windowRow("L4_PlantRoom", "S", 3, 5, 3, 8, true)
windowRow("L4_SpectatorGallery", "S", 5, 9, 7, 3, true)
windowRow("L4_ScoreboardRoom", "S", 2, 6, 4, 6, true)
windowRow("L4_StaffRoom", "W", 1, 7, 6, 3.5, true)
windowRow("L4_Storage_W1", "W", 1, 4, 4, 5, true)
windowRow("L4_Storage_W2", "W", 1, 4, 4, 5, true)
windowRow("L4_PlantRoom", "W", 1, 5, 3, 8, true)
windowRow("L4_ChlorineStore", "E", 1, 5, 3, 8, true)
windowRow("L4_Storage_E1", "E", 1, 4, 4, 5, true)
windowRow("L4_Storage_E2", "E", 1, 4, 4, 5, true)
windowRow("L4_ScoreboardRoom", "E", 1, 6, 4, 6, true)

--------------------------------------------------------------------------------

local layout: LayoutSchema.LevelLayout = {
	id = "Level4_FloodedPool",
	height = HEIGHT,
	acoustic = "Hall",
	ambience = "DronePool",
	entry = "L4_AirlockWest",
	exit = "L4_AirlockEast",
	rooms = rooms,
	doors = doors,
	vents = { nodes = ventNodes, edges = ventEdges, grates = grates },
	anchors = anchors,
	triggers = triggers,
	basins = basins,
	platforms = platforms,
	windows = windows,
}

deepFreeze(layout)

return layout
