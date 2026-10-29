--!strict
-- Level 1 · Main Hallways (street level). The squad climbs out of the basement into L1_AirlockEast and must reach
-- L1_AirlockWest.
--
-- Plan (X runs west -> east, Z runs north -> south):
--   z   0..26  north rooms (library, classrooms, music room)        z  26..40  north hall (barricaded at x = 120)
--   z  40..73  classrooms / restrooms / offices                     z  73..87  MAIN CORRIDOR (gate at x = 120)
--   z  87..120 classrooms / art room                                z 120..134 south hall (barricaded at x = 120)
--   z 134..160 cafeteria, kitchen, offices
-- Everything west of x = 120 is sealed from everything east of it except through the HallwayGate and the gate
-- bypass vent (L1_Chase_Gate). The scripted encounter runs east -> west: the pale glow spills from the ajar door of
-- L1_Classroom_108 (a second glow fixture just inside the door lights the corridor floor through the opening), the
-- corridor outside it is strewn with glass (ScareStep), and the Creature crouches in the room's north-west corner
-- facing the wall, so a squad walking west sees it diagonally through the ajar door while on the glass. Once the
-- gate slams the only way on is the wall vent beside it.
-- Two classroom chases east of the gate (L1_Chase_North behind the nurse's office, L1_Chase_South between
-- classrooms 134 and 136) give the Creature vents into the classrooms (108 included) and the halls; their grates
-- may be locked, never the gate bypass.
--
-- Anchor heights: props rest on the floor (y = 0); DripPipe sits at pipe height under the ceiling; PlayerSpawn is at
-- HumanoidRootPart height plus clearance (3.5) and Creature placements at the rig's root height (5). Yaw is degrees
-- about +Y: 0 faces north (-Z), 90 west, 180 south, -90 east.

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

local PREFIX = "L1"
local HEIGHT = WorldConfig.Levels.Level1_Hallways.height

local FACE_N, FACE_W, FACE_S, FACE_E = 0, 90, 180, -90

local LIGHT_DEFAULTS: { [string]: LightDefaults } = {
	Fluorescent = { brightness = 0.55, range = 18, color = Color3.fromRGB(214, 232, 236) },
	Bulb = { brightness = 0.45, range = 14, color = Color3.fromRGB(255, 196, 140) },
	EmergencyRed = { brightness = 0.45, range = 16, color = Color3.fromRGB(255, 34, 18) },
	ClassroomGlow = { brightness = 1.1, range = 34, color = Color3.fromRGB(198, 220, 255) },
	Floodlight = { brightness = 2, range = 60, color = Color3.fromRGB(236, 240, 255) },
	ExitSign = { brightness = 0.3, range = 8, color = Color3.fromRGB(70, 255, 120) },
	BoilerGlow = { brightness = 0.9, range = 16, color = Color3.fromRGB(255, 118, 40) },
}

local CORRIDOR: Style =
	{ floor = "Linoleum", wall = "PlasterGreen", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Corridor" }
local CLASSROOM: Style =
	{ floor = "Linoleum", wall = "PlasterSchool", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local ART: Style = {
	floor = "ConcreteStained",
	wall = "PlasterSchool",
	ceiling = "PlasterSchool",
	surface = "Concrete",
	acoustic = "Room",
}
local LIBRARY: Style =
	{ floor = "Carpet", wall = "WoodPanel", ceiling = "PlasterSchool", surface = "Carpet", acoustic = "Room" }
local OFFICE: Style =
	{ floor = "Carpet", wall = "PlasterSchool", ceiling = "PlasterSchool", surface = "Carpet", acoustic = "Room" }
local MUSIC: Style =
	{ floor = "WoodPanel", wall = "WoodPanel", ceiling = "PlasterSchool", surface = "Wood", acoustic = "Hall" }
local RESTROOM: Style =
	{ floor = "TileWhite", wall = "TileWhite", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local KITCHEN: Style =
	{ floor = "TileWhite", wall = "TileGreen", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local CAFETERIA: Style =
	{ floor = "Linoleum", wall = "Brick", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Hall" }
local STORAGE: Style =
	{ floor = "ConcreteStained", wall = "ConcreteDark", ceiling = "Concrete", surface = "Concrete", acoustic = "Room" }
local AIRLOCK: Style =
	{ floor = "Concrete", wall = "ConcreteDark", ceiling = "Concrete", surface = "Concrete", acoustic = "Stairwell" }
local CHASE: Style =
	{ floor = "ConcreteDark", wall = "ConcreteDark", ceiling = "ConcreteDark", surface = "Metal", acoustic = "Vent" }

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
local ventNodes: { LayoutSchema.VentNodeSpec } = {}
local ventEdges: { LayoutSchema.VentEdgeSpec } = {}
local grates: { LayoutSchema.GrateSpec } = {}
local lightCount = 0

local function room(id: string, kind: Enums.RoomKind, x: number, z: number, w: number, d: number, style: Style): Room
	local entry: Room = {
		id = id,
		kind = kind,
		rect = LayoutSchema.rect(x, z, w, d),
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

-- A closed patrol loop: waypoint i leads to i + 1 and the last back to the first, each hop within one room or
-- through one doorway.
local function patrol(loop: string, points: { { number } })
	for i, p in points do
		anchor("PatrolWaypoint", p[1], 0, p[2], nil, string.format("%s_WP_%s_%02d", PREFIX, loop, i))
	end
end

local function trigger(id: string, kind: Enums.TriggerKind, x: number, z: number, w: number, d: number, height: number)
	table.insert(triggers, {
		id = id,
		kind = kind,
		room = roomAt(x + w / 2, z + d / 2),
		rect = LayoutSchema.rect(x, z, w, d),
		height = height,
	})
end

-- Evenly spaced windows on one side of a room; any that would face a stair tower are left out.
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
		local facesTower = not alongX and WorldConfig.facesTower(at - width / 2, at + width / 2, 2)
		if not facesTower then
			table.insert(
				windows,
				{ room = roomId, side = side, at = at, width = width, height = height, sill = sill, boarded = boarded }
			)
		end
	end
end

-- One straight duct along the middle of a chase, a junction under every side grate, end grates as terminals.
-- A duct never leaves its chase, so each chase room carries exactly one run.
local function chaseRun(chaseId: string, plans: { GratePlan }, submerged: boolean?)
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
			table.insert(ventNodes, { id = nodeId, x = if alongX then coord else cx, z = if alongX then cz else coord })
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
		table.insert(ventNodes, { id = nodeId, x = x, z = z })
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

-- Corridors
room("L1_NorthHall_West", "Corridor", 0, 26, 120, 14, CORRIDOR)
room("L1_NorthHall_East", "Corridor", 120, 26, 120, 14, CORRIDOR)
room("L1_Corridor_West", "Corridor", 12, 73, 108, 14, CORRIDOR)
room("L1_Corridor_East", "Corridor", 120, 73, 108, 14, CORRIDOR)
room("L1_SouthHall_West", "Corridor", 0, 120, 120, 14, CORRIDOR)
room("L1_SouthHall_East", "Corridor", 120, 120, 120, 14, CORRIDOR)
room("L1_CrossHall_NW", "Corridor", 40, 40, 14, 33, CORRIDOR)
room("L1_CrossHall_NE", "Corridor", 186, 40, 14, 33, CORRIDOR)
room("L1_CrossHall_SW", "Corridor", 40, 87, 14, 33, CORRIDOR)
room("L1_CrossHall_SE", "Corridor", 186, 87, 14, 33, CORRIDOR)

-- Stair vestibules
room("L1_AirlockWest", "Airlock", 0, 66, 12, 28, AIRLOCK)
room("L1_AirlockNorthWest", "Airlock", 0, 0, 12, 26, AIRLOCK)
room("L1_AirlockSouthWest", "Airlock", 0, 134, 12, 26, AIRLOCK)
room("L1_AirlockNorthEast", "Airlock", 228, 0, 12, 26, AIRLOCK)
room("L1_AirlockSouthEast", "Airlock", 228, 134, 12, 26, AIRLOCK)
room("L1_AirlockEast", "Airlock", 228, 66, 12, 28, AIRLOCK)

-- Between the north hall and the main corridor
room("L1_JanitorCloset_W", "Storage", 0, 40, 12, 26, STORAGE)
room("L1_Classroom_101", "Classroom", 12, 40, 28, 33, CLASSROOM)
room("L1_Classroom_103", "Classroom", 54, 40, 28, 33, CLASSROOM)
room("L1_TeachersLounge", "Office", 82, 40, 22, 33, OFFICE)
room("L1_Restroom_Boys", "Restroom", 104, 40, 16, 28, RESTROOM)
room("L1_Chase_Gate", "Chase", 104, 68, 32, 5, CHASE)
room("L1_Restroom_Girls", "Restroom", 120, 40, 16, 28, RESTROOM)
room("L1_NurseOffice", "Office", 136, 40, 17, 33, OFFICE)
room("L1_Chase_North", "Chase", 153, 40, 5, 33, CHASE)
room("L1_Classroom_108", "Classroom", 158, 40, 28, 33, CLASSROOM)
room("L1_Classroom_110", "Classroom", 200, 40, 28, 33, CLASSROOM)
room("L1_JanitorCloset_E", "Storage", 228, 40, 12, 26, STORAGE)

-- North exterior row
room("L1_Library", "Classroom", 12, 0, 44, 26, LIBRARY)
room("L1_Classroom_113", "Classroom", 56, 0, 28, 26, CLASSROOM)
room("L1_Classroom_115", "Classroom", 84, 0, 28, 26, CLASSROOM)
room("L1_BookStore", "Storage", 112, 0, 8, 26, STORAGE)
room("L1_RecordsStore", "Storage", 120, 0, 8, 26, STORAGE)
room("L1_Classroom_120", "Classroom", 128, 0, 28, 26, CLASSROOM)
room("L1_Classroom_122", "Classroom", 156, 0, 28, 26, CLASSROOM)
room("L1_MusicRoom", "Classroom", 184, 0, 44, 26, MUSIC)

-- Between the main corridor and the south hall
room("L1_Storage_131A", "Storage", 0, 94, 12, 26, STORAGE)
room("L1_Classroom_131", "Classroom", 12, 87, 28, 33, CLASSROOM)
room("L1_Classroom_133", "Classroom", 54, 87, 28, 33, CLASSROOM)
room("L1_ArtRoom", "Classroom", 82, 87, 38, 33, ART)
room("L1_Classroom_134", "Classroom", 120, 87, 33, 33, CLASSROOM)
room("L1_Chase_South", "Chase", 153, 87, 5, 33, CHASE)
room("L1_Classroom_136", "Classroom", 158, 87, 28, 33, CLASSROOM)
room("L1_Classroom_138", "Classroom", 200, 87, 28, 33, CLASSROOM)
room("L1_Storage_140A", "Storage", 228, 94, 12, 26, STORAGE)

-- South exterior row
room("L1_Cafeteria", "Classroom", 12, 134, 72, 26, CAFETERIA)
room("L1_Kitchen", "Storage", 84, 134, 36, 26, KITCHEN)
room("L1_MainOffice", "Office", 120, 134, 40, 26, OFFICE)
room("L1_PrincipalOffice", "Office", 160, 134, 24, 26, OFFICE)
room("L1_Classroom_142", "Classroom", 184, 134, 28, 26, CLASSROOM)
room("L1_Restroom_Staff", "Restroom", 212, 134, 16, 26, RESTROOM)

--------------------------------------------------------------------------------
-- Doors
--------------------------------------------------------------------------------

door("Airlock", "L1_AirlockEast", "L1_Corridor_East", 80, { id = "L1_Door_AirlockEast" })
door("Airlock", "L1_Corridor_West", "L1_AirlockWest", 80, { id = "L1_Door_AirlockWest" })
-- The corner stair vestibules open off the outer halls (the west ones inside the sealed west half)
door("Airlock", "L1_AirlockNorthEast", "L1_NorthHall_East", 234, { id = "L1_Door_AirlockNorthEast" })
door("Airlock", "L1_AirlockSouthEast", "L1_SouthHall_East", 234, { id = "L1_Door_AirlockSouthEast" })
door("Airlock", "L1_NorthHall_West", "L1_AirlockNorthWest", 6, { id = "L1_Door_AirlockNorthWest" })
door("Airlock", "L1_SouthHall_West", "L1_AirlockSouthWest", 6, { id = "L1_Door_AirlockSouthWest" })
door(
	"Gate",
	"L1_Corridor_East",
	"L1_Corridor_West",
	80,
	{ id = "L1_Door_HallwayGate", width = 12, scriptedId = "HallwayGate" }
)
door("Boarded", "L1_NorthHall_East", "L1_NorthHall_West", 33, { id = "L1_Door_NorthBarricade", width = 12 })
door("Boarded", "L1_SouthHall_East", "L1_SouthHall_West", 127, { id = "L1_Door_SouthBarricade", width = 12 })

-- Cross halls
door("Doorway", "L1_CrossHall_NW", "L1_NorthHall_West", 47, { width = 10 })
door("Doorway", "L1_CrossHall_NW", "L1_Corridor_West", 47, { width = 10 })
door("Doorway", "L1_CrossHall_NE", "L1_NorthHall_East", 193, { width = 10 })
door("Doorway", "L1_CrossHall_NE", "L1_Corridor_East", 193, { width = 10 })
door("Doorway", "L1_CrossHall_SW", "L1_Corridor_West", 47, { width = 10 })
door("Doorway", "L1_CrossHall_SW", "L1_SouthHall_West", 47, { width = 10 })
door("Doorway", "L1_CrossHall_SE", "L1_Corridor_East", 193, { width = 10 })
door("Doorway", "L1_CrossHall_SE", "L1_SouthHall_East", 193, { width = 10 })

-- North of the main corridor
door("Door", "L1_JanitorCloset_W", "L1_NorthHall_West", 6)
door("Door", "L1_Corridor_West", "L1_Classroom_101", 18)
door("Door", "L1_Corridor_West", "L1_Classroom_101", 34)
door("Door", "L1_NorthHall_West", "L1_Classroom_101", 26)
door("Door", "L1_Corridor_West", "L1_Classroom_103", 60)
door("Door", "L1_Corridor_West", "L1_Classroom_103", 76)
door("Door", "L1_Corridor_West", "L1_TeachersLounge", 93)
door("Door", "L1_NorthHall_West", "L1_Restroom_Boys", 112)
door("Door", "L1_NorthHall_East", "L1_Restroom_Girls", 128)
door("Door", "L1_Corridor_East", "L1_NurseOffice", 147)
door("Ajar", "L1_Corridor_East", "L1_Classroom_108", 172, { id = "L1_Door_Classroom108", scriptedId = "ClassroomDoor" })
door("Door", "L1_Corridor_East", "L1_Classroom_110", 206)
door("Door", "L1_Corridor_East", "L1_Classroom_110", 222)
door("Door", "L1_NorthHall_East", "L1_Classroom_110", 214)
door("Door", "L1_JanitorCloset_E", "L1_NorthHall_East", 234)

-- North exterior row
door("Doorway", "L1_NorthHall_West", "L1_Library", 18)
door("Doorway", "L1_NorthHall_West", "L1_Library", 42)
door("Door", "L1_NorthHall_West", "L1_Classroom_113", 70)
door("Door", "L1_NorthHall_West", "L1_Classroom_115", 98)
door("Door", "L1_NorthHall_West", "L1_BookStore", 116)
door("Door", "L1_NorthHall_East", "L1_RecordsStore", 124)
door("Door", "L1_NorthHall_East", "L1_Classroom_120", 142)
door("Door", "L1_NorthHall_East", "L1_Classroom_122", 170)
door("Door", "L1_NorthHall_East", "L1_MusicRoom", 198)
door("Door", "L1_NorthHall_East", "L1_MusicRoom", 220)

-- South of the main corridor
door("Door", "L1_Storage_131A", "L1_SouthHall_West", 6)
door("Door", "L1_Corridor_West", "L1_Classroom_131", 18)
door("Door", "L1_Corridor_West", "L1_Classroom_131", 34)
door("Door", "L1_SouthHall_West", "L1_Classroom_131", 26)
door("Door", "L1_Corridor_West", "L1_Classroom_133", 60)
door("Door", "L1_Corridor_West", "L1_Classroom_133", 76)
door("Door", "L1_Corridor_West", "L1_ArtRoom", 90)
door("Door", "L1_Corridor_West", "L1_ArtRoom", 112)
door("Door", "L1_SouthHall_West", "L1_ArtRoom", 101)
door("Door", "L1_Corridor_East", "L1_Classroom_134", 128)
door("Door", "L1_Corridor_East", "L1_Classroom_134", 146)
door("Door", "L1_Corridor_East", "L1_Classroom_136", 164)
door("Door", "L1_Corridor_East", "L1_Classroom_136", 180)
door("Door", "L1_Corridor_East", "L1_Classroom_138", 206)
door("Door", "L1_Corridor_East", "L1_Classroom_138", 222)
door("Door", "L1_SouthHall_East", "L1_Classroom_138", 214)
door("Door", "L1_Storage_140A", "L1_SouthHall_East", 234)

-- South exterior row
door("Doorway", "L1_SouthHall_West", "L1_Cafeteria", 20, { width = 8 })
door("Doorway", "L1_SouthHall_West", "L1_Cafeteria", 64, { width = 8 })
door("Door", "L1_SouthHall_West", "L1_Kitchen", 102)
door("Door", "L1_Cafeteria", "L1_Kitchen", 147)
door("Door", "L1_SouthHall_East", "L1_MainOffice", 140)
door("Door", "L1_MainOffice", "L1_PrincipalOffice", 147)
door("Door", "L1_SouthHall_East", "L1_Classroom_142", 198)
door("Door", "L1_SouthHall_East", "L1_Restroom_Staff", 220)

--------------------------------------------------------------------------------
-- The first wall vent: a service chase in the corridor's north wall, straddling the gate. Both corridor grates are
-- the guaranteed bypass; the restroom grates give the Creature (and the brave) a second way in and out.
--------------------------------------------------------------------------------

chaseRun("L1_Chase_Gate", {
	{
		id = "L1_Grate_CorridorEast",
		room = "L1_Corridor_East",
		side = "S",
		at = 130,
		lockable = false,
		critical = true,
	},
	{
		id = "L1_Grate_CorridorWest",
		room = "L1_Corridor_West",
		side = "S",
		at = 110,
		lockable = false,
		critical = true,
	},
	{
		id = "L1_Grate_RestroomBoys",
		room = "L1_Restroom_Boys",
		side = "N",
		at = 114,
		lockable = false,
		critical = false,
	},
	{
		id = "L1_Grate_RestroomGirls",
		room = "L1_Restroom_Girls",
		side = "N",
		at = 126,
		lockable = false,
		critical = false,
	},
})

-- Classroom vents east of the gate. Classroom 108's grate (beside the Creature's corner) never locks: it is the
-- Creature's way out of the scripted room.
chaseRun("L1_Chase_North", {
	{ id = "L1_Grate_N_NorthHall", room = "L1_NorthHall_East", side = "N", lockable = true, critical = false },
	{ id = "L1_Grate_N_Nurse", room = "L1_NurseOffice", side = "W", at = 62, lockable = true, critical = false },
	{
		id = "L1_Grate_N_Classroom108",
		room = "L1_Classroom_108",
		side = "E",
		at = 56,
		lockable = false,
		critical = false,
	},
})
chaseRun("L1_Chase_South", {
	{ id = "L1_Grate_S_Corridor", room = "L1_Corridor_East", side = "N", lockable = false, critical = false },
	{
		id = "L1_Grate_S_Classroom134",
		room = "L1_Classroom_134",
		side = "W",
		at = 100,
		lockable = true,
		critical = false,
	},
	{
		id = "L1_Grate_S_Classroom136",
		room = "L1_Classroom_136",
		side = "E",
		at = 108,
		lockable = true,
		critical = false,
	},
	{ id = "L1_Grate_S_SouthHall", room = "L1_SouthHall_East", side = "S", lockable = true, critical = false },
})

--------------------------------------------------------------------------------
-- Lights: pitch dark except the pale classroom glow, a few dying tubes and the exit signs.
--------------------------------------------------------------------------------

lightGrid("L1_NorthHall_West", "Fluorescent", 8, 1, "xxxxxfxx", { flicker = "L1_NorthHall" })
lightGrid("L1_NorthHall_East", "Fluorescent", 8, 1, "xxfxxxxx", { flicker = "L1_NorthHall" })
lightGrid("L1_Corridor_West", "Fluorescent", 9, 1, "x")
lightGrid("L1_Corridor_East", "Fluorescent", 9, 1, "x")
lightGrid("L1_SouthHall_West", "Fluorescent", 8, 1, "xxxfxxxx", { flicker = "L1_SouthHall" })
lightGrid("L1_SouthHall_East", "Fluorescent", 8, 1, "x")
lightGrid("L1_CrossHall_NW", "Fluorescent", 1, 3, "x")
lightGrid("L1_CrossHall_NE", "Fluorescent", 1, 3, "x")
lightGrid("L1_CrossHall_SW", "Fluorescent", 1, 3, "xfx", { flicker = "L1_CrossSW" })
lightGrid("L1_CrossHall_SE", "Fluorescent", 1, 3, "x")
for _, id in
	{
		"L1_Classroom_101",
		"L1_Classroom_103",
		"L1_Classroom_108",
		"L1_Classroom_110",
		"L1_Classroom_113",
		"L1_Classroom_115",
		"L1_Classroom_120",
		"L1_Classroom_122",
		"L1_Classroom_131",
		"L1_Classroom_133",
		"L1_Classroom_136",
		"L1_Classroom_138",
		"L1_Classroom_142",
		"L1_ArtRoom",
		"L1_Kitchen",
	} :: { string }
do
	lightGrid(id, "Fluorescent", 2, 2, "x")
end
lightGrid("L1_Classroom_134", "Fluorescent", 2, 2, "xfxx", { flicker = "L1_Classroom134", brightness = 0.35 })
lightGrid("L1_Library", "Fluorescent", 3, 2, "x")
lightGrid("L1_MusicRoom", "Fluorescent", 3, 2, "x")
lightGrid("L1_Cafeteria", "Fluorescent", 4, 2, "xxxxxxfx", { flicker = "L1_Cafeteria", brightness = 0.3 })
lightGrid("L1_MainOffice", "Fluorescent", 2, 1, "x")
lightGrid("L1_TeachersLounge", "Fluorescent", 1, 2, "x")
lightGrid("L1_NurseOffice", "Fluorescent", 1, 2, "x")
lightGrid("L1_Restroom_Boys", "Fluorescent", 1, 2, "x")
lightGrid("L1_Restroom_Girls", "Fluorescent", 1, 2, "fx", { flicker = "L1_RestroomGirls", brightness = 0.3 })
lightGrid("L1_Restroom_Staff", "Fluorescent", 1, 1, "x")
lightGrid("L1_PrincipalOffice", "Bulb", 1, 1, "x")
for _, id in
	{
		"L1_JanitorCloset_W",
		"L1_JanitorCloset_E",
		"L1_BookStore",
		"L1_RecordsStore",
		"L1_Storage_131A",
		"L1_Storage_140A",
	} :: { string }
do
	lightGrid(id, "Bulb", 1, 1, "x")
end

-- The pale glow from the ajar classroom (P6 bursts every ClassroomGlow in L1_Classroom_108 when the Creature turns):
-- the room light over the Creature's corner, and a narrow spill fixture just inside the ajar door whose downward
-- cone leaves the room under the door lintel and lays a pale pool on the corridor floor. Both cast shadows, so the
-- glow reaches the corridor only through the doorway.
light("L1_Classroom_108", "ClassroomGlow", 170, HEIGHT - 1.5, 52, { id = "L1_Light_ClassroomGlow" })
light(
	"L1_Classroom_108",
	"ClassroomGlow",
	172,
	HEIGHT - 1.5,
	70,
	{ id = "L1_Light_ClassroomGlowSpill", brightness = 0.6, range = 18 }
)

light("L1_AirlockEast", "EmergencyRed", 234, HEIGHT - 1, 80, { flicker = "L1_AirlockEast", brightness = 0.35 })
light("L1_AirlockWest", "EmergencyRed", 6, HEIGHT - 1, 80, { flicker = "L1_AirlockWest", brightness = 0.35 })
for _, spot in
	{
		{ "L1_AirlockNorthWest", 6, 13 },
		{ "L1_AirlockSouthWest", 6, 147 },
		{ "L1_AirlockNorthEast", 234, 13 },
		{ "L1_AirlockSouthEast", 234, 147 },
	} :: { { any } }
do
	light(spot[1], "EmergencyRed", spot[2], HEIGHT - 1, spot[3], { flicker = spot[1], brightness = 0.35 })
end
light("L1_Corridor_East", "ExitSign", 226.5, 11, 80)
light("L1_Corridor_West", "ExitSign", 13.5, 11, 80)
light("L1_Corridor_West", "EmergencyRed", 24, HEIGHT - 1.5, 74.5, { flicker = "L1_ExitWest", brightness = 0.3 })

--------------------------------------------------------------------------------
-- Anchors
--------------------------------------------------------------------------------

-- Arrival from Stairwell_0_1
scatter("PlayerSpawn", 3.5, { { 232, 74, FACE_W }, { 236, 74, FACE_W }, { 232, 86, FACE_W }, { 236, 86, FACE_W } })
-- Arrival from Stairwell_0_1_North / _South (the corner vestibules)
scatter("PlayerSpawn", 3.5, { { 232, 5, FACE_S }, { 236, 5, FACE_S }, { 232, 19, FACE_S }, { 236, 19, FACE_S } })
scatter("PlayerSpawn", 3.5, { { 232, 141, FACE_N }, { 236, 141, FACE_N }, { 232, 155, FACE_N }, { 236, 155, FACE_N } })

-- The scripted classroom: the Creature hunched in the far (north-west) corner, facing into the corner. From the
-- glass outside the ajar door a westbound squad looks diagonally through the doorway straight at it.
anchor("CreatureScarePose", 161.5, 5, 43.5, 45, "L1_ScarePose_Classroom108")
anchor("CreatureSpawn", 220, 5, 12, FACE_S, "L1_CreatureSpawn")

-- Ragdoll corpses
scatter("Corpse", 0, {
	{ 150, 85, 20 },
	{ 70, 85, 160 },
	{ 104, 77, -70 },
	{ 165, 37, 110 },
	{ 28, 148, 45 },
	{ 140, 104, -135 },
	{ 22, 8, 80 },
})

-- Smashed lockers lining the main corridor walls (kept clear of doors and the vent grates)
scatter("SmashedLocker", 0, {
	{ 141, 74.2, FACE_S },
	{ 156, 74.2, FACE_S },
	{ 165, 74.2, FACE_S },
	{ 179, 74.2, FACE_S },
	{ 214, 74.2, FACE_S },
	{ 139, 85.8, FACE_N },
	{ 83, 85.8, FACE_N },
	{ 172, 85.8, FACE_N },
	{ 212, 85.8, FACE_N },
	{ 26, 74.2, FACE_S },
	{ 68, 74.2, FACE_S },
	{ 86, 74.2, FACE_S },
	{ 100, 74.2, FACE_S },
	{ 26, 85.8, FACE_N },
	{ 68, 85.8, FACE_N },
	{ 101, 85.8, FACE_N },
})

-- Floor objective (MasterKeys): the janitor's master keys hang on a nail in one of ten rooms past the gate (the
-- anchor is the nail on the wall face, facing into the room); hideable lockers in each of those rooms or the hall
-- outside, and in classroom 101 a door away from the stairwell door, keep a hiding spot near every step; the exit
-- lock on the west stair airlock's fire door (the floor point on its corridor face, facing out of the door).
local KEY_HOOK_Y = 4.6
scatter("MasterKeyCandidate", KEY_HOOK_Y, {
	{ 11.5, 52, FACE_W }, -- janitor's closet
	{ 93, 40.5, FACE_S }, -- teachers' lounge
	{ 112.5, 20, FACE_E }, -- book store (the records)
	{ 11.5, 104, FACE_W }, -- the store by classroom 131
	{ 119.5, 150, FACE_W }, -- kitchen
	{ 56.5, 16, FACE_E }, -- classroom 113, by the teacher's desk
	{ 28, 134.5, FACE_S }, -- cafeteria, inside the hall doors
	{ 119.5, 104, FACE_W }, -- art room, by the supply shelves
	{ 28, 25.5, FACE_N }, -- library, by the issue desk
	{ 12.5, 110, FACE_E }, -- classroom 131
})
scatter("Locker", 0, {
	{ 2.05, 58, FACE_E }, -- janitor's closet
	{ 83.8, 52, FACE_E }, -- teachers' lounge
	{ 100, 38.2, FACE_N }, -- north hall, outside the lounge and the book store
	{ 2.05, 112, FACE_E }, -- the store by classroom 131
	{ 102, 157.95, FACE_N }, -- kitchen
	{ 13.8, 68, FACE_E }, -- classroom 101, a door away from the stairwell door
	{ 58.05, 6, FACE_E }, -- classroom 113
	{ 14.05, 140, FACE_E }, -- cafeteria
	{ 118.2, 112, FACE_W }, -- art room
	{ 34, 23.95, FACE_N }, -- library
	{ 13.8, 100, FACE_E }, -- classroom 131
})
anchor("ExitLock", 12.5, 0, 80, FACE_E, "L1_ExitLock")
anchor("ExitLock", 6, 0, 26.5, FACE_S, "L1_ExitLock_North")
anchor("ExitLock", 6, 0, 133.5, FACE_N, "L1_ExitLock_South")
-- A hideable locker by each corner exit's fire door, so its lock keeps a hiding spot within reach
scatter("Locker", 0, { { 15, 38.2, FACE_N } })

-- Burst overhead pipes
scatter("DripPipe", HEIGHT - 1.2, {
	{ 134, 84 },
	{ 160, 76 },
	{ 204, 83 },
	{ 30, 78 },
	{ 84, 82 },
	{ 210, 30 },
	{ 60, 128 },
	{ 100, 150 },
	{ 128, 50 },
})

scatter("BatteryCandidate", 0, {
	{ 16, 44 },
	{ 224, 44 },
	{ 150, 44 },
	{ 16, 22 },
	{ 124, 156 },
	{ 116, 156 },
	{ 234, 44 },
	{ 224, 4 },
	{ 182, 116 },
	{ 6, 116 },
})

scatter("Clutter", 0, {
	{ 26, 60, 15 },
	{ 68, 55, -30 },
	{ 210, 52, 75 },
	{ 20, 100, 120 },
	{ 70, 110, 200 },
	{ 100, 95, 10 },
	{ 135, 110, -60 },
	{ 172, 100, 35 },
	{ 214, 112, 160 },
	{ 40, 14, 5 },
	{ 50, 150, 90 },
	{ 96, 140, -15 },
	{ 150, 154, 45 },
	{ 210, 14, -100 },
	{ 165, 62, 0 },
	{ 113, 57, 30 },
})

-- Patrol loops (east half first: the Creature hunts the squad back toward the gate)
patrol("EN", { { 214, 80 }, { 214, 56 }, { 214, 33 }, { 193, 33 }, { 193, 56 }, { 193, 80 } })
patrol("ES", { { 196, 82 }, { 193, 104 }, { 193, 127 }, { 214, 127 }, { 214, 104 }, { 214, 84 } })
patrol("EC", { { 222, 78 }, { 172, 78 }, { 126, 78 }, { 150, 84 }, { 200, 84 } })
patrol("EF", { { 226, 33 }, { 226, 12 }, { 198, 12 }, { 198, 33 } })
patrol("WN", { { 26, 80 }, { 26, 56 }, { 26, 33 }, { 47, 33 }, { 47, 56 }, { 47, 80 } })
patrol("WS", { { 47, 84 }, { 47, 104 }, { 47, 127 }, { 26, 127 }, { 26, 104 }, { 26, 84 } })
patrol("WA", { { 90, 80 }, { 90, 100 }, { 112, 100 }, { 112, 80 } })
patrol("WC", { { 110, 78 }, { 70, 78 }, { 20, 78 }, { 40, 84 }, { 90, 84 } })
patrol("WF", { { 20, 127 }, { 20, 145 }, { 64, 145 }, { 64, 127 } })

--------------------------------------------------------------------------------
-- Triggers
--------------------------------------------------------------------------------

-- Broken glass and cans across the full corridor width outside the ajar classroom, over the band of the corridor
-- from which the Creature's corner is in sight through the doorway (x about 169.5..181.5 at standing eye height).
trigger("L1_Trigger_GlassStep", "ScareStep", 170, 73, 10, 14, 4)
trigger("L1_Trigger_DebrisWest", "FloorDebris", 60, 75, 6, 10, 4)
trigger("L1_Trigger_DebrisNorth", "FloorDebris", 150, 28, 6, 10, 4)
trigger("L1_Trigger_DebrisSouth", "FloorDebris", 70, 122, 6, 10, 4)
trigger("L1_Trigger_Checkpoint", "Checkpoint", 1, 67, 10, 26, 10)
trigger("L1_Trigger_CheckpointNorthWest", "Checkpoint", 1, 1, 10, 24, 10)
trigger("L1_Trigger_CheckpointSouthWest", "Checkpoint", 1, 135, 10, 24, 10)

--------------------------------------------------------------------------------
-- Boarded windows on the facade
--------------------------------------------------------------------------------

windowRow("L1_Library", "N", 4, 7, 6, 3.5, true)
windowRow("L1_Classroom_113", "N", 2, 7, 6, 3.5, true)
windowRow("L1_Classroom_115", "N", 2, 7, 6, 3.5, true)
windowRow("L1_Classroom_120", "N", 2, 7, 6, 3.5, true)
windowRow("L1_Classroom_122", "N", 2, 7, 6, 3.5, true)
windowRow("L1_MusicRoom", "N", 4, 7, 6, 3.5, true)
windowRow("L1_Cafeteria", "S", 5, 8, 6, 3.5, true)
windowRow("L1_Kitchen", "S", 2, 6, 4, 5, true)
windowRow("L1_MainOffice", "S", 2, 7, 6, 3.5, true)
windowRow("L1_PrincipalOffice", "S", 1, 7, 6, 3.5, true)
windowRow("L1_Classroom_142", "S", 2, 7, 6, 3.5, true)
windowRow("L1_Restroom_Staff", "S", 1, 4, 3, 7, true)
windowRow("L1_NorthHall_West", "W", 1, 6, 6, 3.5, true)
windowRow("L1_JanitorCloset_W", "W", 1, 4, 4, 5, true)
windowRow("L1_SouthHall_West", "W", 1, 6, 6, 3.5, true)
windowRow("L1_Storage_131A", "W", 1, 4, 4, 5, true)
windowRow("L1_NorthHall_East", "E", 1, 6, 6, 3.5, true)
windowRow("L1_JanitorCloset_E", "E", 1, 4, 4, 5, true)
windowRow("L1_Storage_140A", "E", 1, 4, 4, 5, true)
windowRow("L1_SouthHall_East", "E", 1, 6, 6, 3.5, true)

--------------------------------------------------------------------------------

local layout: LayoutSchema.LevelLayout = {
	id = "Level1_Hallways",
	height = HEIGHT,
	acoustic = "Corridor",
	ambience = "DroneHallways",
	entry = "L1_AirlockEast",
	exit = "L1_AirlockWest",
	rooms = rooms,
	doors = doors,
	vents = { nodes = ventNodes, edges = ventEdges, grates = grates },
	anchors = anchors,
	triggers = triggers,
	windows = windows,
}

deepFreeze(layout)

return layout
