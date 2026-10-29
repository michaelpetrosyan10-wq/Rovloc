--!strict
-- Level 3 · Gymnasium & Locker Rooms. The squad arrives in L3_AirlockEast from Stairwell_2_3 and must reach
-- L3_AirlockWest, which opens straight off the gym floor.
--
-- Plan (X west -> east, Z north -> south):
--   z   0..31  weight room, equipment store, coach office, laundry ...    z  31..45  north hall (barricaded at x = 127)
--   z  45..115 GYMNASIUM (x 12..122, 30 tall, bleachers N and S) | gym chase | locker rooms + showers | gym foyer
--   z 115..129 south hall (barricaded at x = 127)                         z 129..160 wrestling, dance, team rooms
-- The gym's doors to the east wing are chained shut (the halls are barricaded where the wings meet), so the way into
-- the gym is the low wall vent from the boys' locker room straight through L3_Chase_GymEast (critical, never
-- locked). Both locker rooms are lined with hideable lockers and joined by a second low duct under the lockers.
--
-- Everything except the gym has a 14-stud ceiling: the floor above (Level 4) hangs its pool basin over the east wing,
-- so nothing under x 128..214 may rise past that (spec-checked).
--
-- Anchor heights: props on the floor (y = 0), DripPipe under the ceiling, Locker = floor centre of a standing locker
-- whose door faces the yaw, PlayerSpawn at root height plus clearance (3.5), Creature placements at the rig's root
-- height (5). Yaw: 0 faces north (-Z), 90 west, 180 south, -90 east.

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

local PREFIX = "L3"
local HEIGHT = WorldConfig.Levels.Level3_Gymnasium.height
local LOW = 14 -- ceiling of every room except the gym

local FACE_N, FACE_W, FACE_S, FACE_E = 0, 90, 180, -90

local LIGHT_DEFAULTS: { [string]: LightDefaults } = {
	Fluorescent = { brightness = 0.55, range = 18, color = Color3.fromRGB(214, 232, 236) },
	Bulb = { brightness = 0.45, range = 14, color = Color3.fromRGB(255, 196, 140) },
	EmergencyRed = { brightness = 0.45, range = 16, color = Color3.fromRGB(255, 34, 18) },
	ClassroomGlow = { brightness = 1.1, range = 34, color = Color3.fromRGB(198, 220, 255) },
	Floodlight = { brightness = 0.6, range = 40, color = Color3.fromRGB(236, 240, 255) },
	ExitSign = { brightness = 0.3, range = 8, color = Color3.fromRGB(70, 255, 120) },
	BoilerGlow = { brightness = 0.9, range = 16, color = Color3.fromRGB(255, 118, 40) },
}

local GYM: Style =
	{ floor = "WoodGym", wall = "Brick", ceiling = "MetalGalvanized", surface = "Wood", acoustic = "Hall" }
local HALL: Style =
	{ floor = "Linoleum", wall = "Brick", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Corridor" }
local FOYER: Style =
	{ floor = "TileWhite", wall = "Brick", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Hall" }
local LOCKERS: Style =
	{ floor = "TileBlue", wall = "TileWhite", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local SHOWERS: Style =
	{ floor = "TileWhite", wall = "TileBlue", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local WEIGHTS: Style =
	{ floor = "ConcreteDark", wall = "Brick", ceiling = "PlasterSchool", surface = "Concrete", acoustic = "Room" }
local MATS: Style =
	{ floor = "Carpet", wall = "PlasterSchool", ceiling = "PlasterSchool", surface = "Carpet", acoustic = "Room" }
local DANCE: Style =
	{ floor = "WoodPanel", wall = "PlasterSchool", ceiling = "PlasterSchool", surface = "Wood", acoustic = "Room" }
local OFFICE: Style =
	{ floor = "Carpet", wall = "WoodPanel", ceiling = "PlasterSchool", surface = "Carpet", acoustic = "Room" }
local SERVICE: Style =
	{ floor = "TileWhite", wall = "PlasterSchool", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
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
local platforms: { LayoutSchema.Platform } = {}
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

local function anchor(
	kind: Enums.AnchorKind,
	x: number,
	y: number,
	z: number,
	yaw: number?,
	id: string?,
	ref: string?
): string
	local n = (anchorCounts[kind] or 0) + 1
	anchorCounts[kind] = n
	local anchorId = id or string.format("%s_%s_%02d", PREFIX, kind, n)
	table.insert(anchors, {
		id = anchorId,
		kind = kind,
		room = roomAt(x, z),
		pos = Vector3.new(x, y, z),
		yaw = yaw,
		ref = ref,
	})
	return anchorId
end

-- Each point is { x, z } or { x, z, yaw }.
local function scatter(kind: Enums.AnchorKind, y: number, points: { { number } })
	for _, p in points do
		anchor(kind, p[1], y, p[2], p[3])
	end
end

-- A row of standing lockers at constant z, one per x, doors facing `yaw`.
local function lockerRow(z: number, xs: { number }, yaw: number)
	for _, x in xs do
		anchor("Locker", x, 0, z, yaw)
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

-- Halls (split where the gym wing meets the locker wing)
room("L3_NorthHall_West", "Corridor", 0, 31, 127, 14, HALL, LOW)
room("L3_NorthHall_East", "Corridor", 127, 31, 113, 14, HALL, LOW)
room("L3_SouthHall_West", "Corridor", 0, 115, 127, 14, HALL, LOW)
room("L3_SouthHall_East", "Corridor", 127, 115, 113, 14, HALL, LOW)

-- West end: the gym and the exit vestibule
room("L3_Storage_W1", "Storage", 0, 45, 12, 21, STORAGE, LOW)
room("L3_AirlockWest", "Airlock", 0, 66, 12, 28, AIRLOCK, LOW)
room("L3_Storage_W2", "Storage", 0, 94, 12, 21, STORAGE, LOW)
room("L3_Gymnasium", "Gym", 12, 45, 110, 70, GYM)

-- Locker wing
room("L3_Chase_GymEast", "Chase", 122, 45, 5, 70, CHASE, LOW)
room("L3_LockerRoom_Boys", "LockerRoom", 127, 45, 50, 33, LOCKERS, LOW)
room("L3_Chase_Lockers", "Chase", 127, 78, 69, 5, CHASE, LOW)
room("L3_LockerRoom_Girls", "LockerRoom", 127, 83, 50, 32, LOCKERS, LOW)
room("L3_Showers_Boys", "Restroom", 177, 45, 19, 33, SHOWERS, LOW)
room("L3_Showers_Girls", "Restroom", 177, 83, 19, 32, SHOWERS, LOW)
room("L3_GymFoyer", "Corridor", 196, 45, 32, 70, FOYER, LOW)

-- East end: the arrival vestibule
room("L3_Storage_E1", "Storage", 228, 45, 12, 21, STORAGE, LOW)
room("L3_AirlockEast", "Airlock", 228, 66, 12, 28, AIRLOCK, LOW)
room("L3_Storage_E2", "Storage", 228, 94, 12, 21, STORAGE, LOW)

-- North exterior row
room("L3_WeightRoom", "Storage", 0, 0, 48, 31, WEIGHTS, LOW)
room("L3_EquipmentStore", "Storage", 48, 0, 36, 31, STORAGE, LOW)
room("L3_TrainerRoom", "Office", 84, 0, 28, 31, SERVICE, LOW)
room("L3_CoachOffice", "Office", 112, 0, 28, 31, OFFICE, LOW)
room("L3_AthleticDirector", "Office", 140, 0, 24, 31, OFFICE, LOW)
room("L3_LaundryRoom", "Storage", 164, 0, 32, 31, SERVICE, LOW)
room("L3_Restroom_North", "Restroom", 196, 0, 20, 31, SHOWERS, LOW)
room("L3_Storage_N", "Storage", 216, 0, 24, 31, STORAGE, LOW)

-- South exterior row
room("L3_WrestlingRoom", "Gym", 0, 129, 60, 31, MATS, LOW)
room("L3_DanceStudio", "Gym", 60, 129, 52, 31, DANCE, LOW)
room("L3_TeamRoom", "Classroom", 112, 129, 36, 31, OFFICE, LOW)
room("L3_MatStore", "Storage", 148, 129, 28, 31, STORAGE, LOW)
room("L3_ConcessionStand", "Storage", 176, 129, 32, 31, SERVICE, LOW)
room("L3_TicketOffice", "Office", 208, 129, 32, 31, OFFICE, LOW)

--------------------------------------------------------------------------------
-- Doors
--------------------------------------------------------------------------------

door("Airlock", "L3_AirlockEast", "L3_GymFoyer", 80, { id = "L3_Door_AirlockEast" })
door("Airlock", "L3_Gymnasium", "L3_AirlockWest", 80, { id = "L3_Door_AirlockWest" })
door("Boarded", "L3_NorthHall_East", "L3_NorthHall_West", 38, { id = "L3_Door_NorthBarricade", width = 12 })
door("Boarded", "L3_SouthHall_East", "L3_SouthHall_West", 122, { id = "L3_Door_SouthBarricade", width = 12 })

-- Locker wing
door("Doorway", "L3_GymFoyer", "L3_NorthHall_East", 212, { width = 10 })
door("Doorway", "L3_GymFoyer", "L3_SouthHall_East", 212, { width = 10 })
door("Door", "L3_GymFoyer", "L3_Storage_E1", 55)
door("Door", "L3_GymFoyer", "L3_Storage_E2", 105)
door("Door", "L3_NorthHall_East", "L3_LockerRoom_Boys", 152)
door("Doorway", "L3_LockerRoom_Boys", "L3_Showers_Boys", 62)
door("Door", "L3_SouthHall_East", "L3_LockerRoom_Girls", 152)
door("Doorway", "L3_LockerRoom_Girls", "L3_Showers_Girls", 99)

-- Gym (double doors in the corners, clear of the bleachers)
door("Doorway", "L3_NorthHall_West", "L3_Gymnasium", 18, { width = 8 })
door("Doorway", "L3_NorthHall_West", "L3_Gymnasium", 116, { width = 8 })
door("Doorway", "L3_SouthHall_West", "L3_Gymnasium", 18, { width = 8 })
door("Doorway", "L3_SouthHall_West", "L3_Gymnasium", 116, { width = 8 })
door("Door", "L3_Gymnasium", "L3_Storage_W1", 58)
door("Door", "L3_Gymnasium", "L3_Storage_W2", 102)

-- North exterior row
door("Doorway", "L3_NorthHall_West", "L3_WeightRoom", 24, { width = 8 })
-- The equipment store's steel door is a fixture (DoorBuilder "RoofDoor" kind, a single dented steel leaf): the
-- floor objective keeps it locked until the coach's key opens it (the StoreLock below).
door(
	"RoofDoor",
	"L3_NorthHall_West",
	"L3_EquipmentStore",
	66,
	{ id = "L3_Door_EquipmentStore", width = 8, scriptedId = "EquipmentStoreDoor" }
)
door("Door", "L3_NorthHall_West", "L3_TrainerRoom", 98)
door("Door", "L3_NorthHall_West", "L3_CoachOffice", 120)
door("Door", "L3_NorthHall_East", "L3_AthleticDirector", 152)
door("Door", "L3_NorthHall_East", "L3_LaundryRoom", 180)
door("Door", "L3_NorthHall_East", "L3_Restroom_North", 206)
door("Door", "L3_NorthHall_East", "L3_Storage_N", 228)

-- South exterior row
door("Doorway", "L3_SouthHall_West", "L3_WrestlingRoom", 30, { width = 8 })
door("Doorway", "L3_SouthHall_West", "L3_DanceStudio", 86, { width = 8 })
door("Door", "L3_SouthHall_West", "L3_TeamRoom", 119)
door("Door", "L3_SouthHall_East", "L3_MatStore", 162, { width = 8 })
door("Door", "L3_SouthHall_East", "L3_ConcessionStand", 192)
door("Door", "L3_SouthHall_East", "L3_TicketOffice", 224)

--------------------------------------------------------------------------------
-- Low wall vents
--------------------------------------------------------------------------------

-- Gym chase: the boys' locker grate and the gym grate share one junction, a straight crawl through the wall.
chaseRun("L3_Chase_GymEast", {
	{ id = "L3_Grate_GE_NorthHall", room = "L3_NorthHall_West", side = "N", lockable = true, critical = false },
	{ id = "L3_Grate_GE_SouthHall", room = "L3_SouthHall_West", side = "S", lockable = true, critical = false },
	{ id = "L3_Grate_GE_Gym1", room = "L3_Gymnasium", side = "W", at = 56, lockable = true, critical = false },
	{ id = "L3_Grate_GE_Gym2", room = "L3_Gymnasium", side = "W", at = 66, lockable = false, critical = true },
	{ id = "L3_Grate_GE_Gym3", room = "L3_Gymnasium", side = "W", at = 104, lockable = false, critical = false },
	{ id = "L3_Grate_GE_Boys", room = "L3_LockerRoom_Boys", side = "E", at = 66, lockable = false, critical = true },
	{ id = "L3_Grate_GE_Girls", room = "L3_LockerRoom_Girls", side = "E", at = 100, lockable = true, critical = false },
})
-- Locker chase between the two locker rooms, out to the showers and the foyer.
chaseRun("L3_Chase_Lockers", {
	{ id = "L3_Grate_LK_Boys1", room = "L3_LockerRoom_Boys", side = "N", at = 138, lockable = true, critical = false },
	{ id = "L3_Grate_LK_Boys2", room = "L3_LockerRoom_Boys", side = "N", at = 165, lockable = false, critical = false },
	{ id = "L3_Grate_LK_ShowerB", room = "L3_Showers_Boys", side = "N", at = 186, lockable = true, critical = false },
	{
		id = "L3_Grate_LK_Girls1",
		room = "L3_LockerRoom_Girls",
		side = "S",
		at = 145,
		lockable = true,
		critical = false,
	},
	{
		id = "L3_Grate_LK_Girls2",
		room = "L3_LockerRoom_Girls",
		side = "S",
		at = 170,
		lockable = false,
		critical = false,
	},
	{ id = "L3_Grate_LK_ShowerG", room = "L3_Showers_Girls", side = "S", at = 189, lockable = true, critical = false },
	{ id = "L3_Grate_LK_Foyer", room = "L3_GymFoyer", side = "E", lockable = true, critical = false },
})

--------------------------------------------------------------------------------
-- Structure: bleachers (stepped, solid to the floor) and locker-room benches
--------------------------------------------------------------------------------

for tier = 1, 4 do
	local top = 7.5 - 1.5 * tier
	local depth = 2.5
	platform(
		string.format("L3_Bleacher_N%d", tier),
		"L3_Gymnasium",
		24,
		45 + depth * (tier - 1),
		86,
		depth,
		top,
		top,
		"WoodPanel"
	)
	platform(
		string.format("L3_Bleacher_S%d", tier),
		"L3_Gymnasium",
		24,
		115 - depth * tier,
		86,
		depth,
		top,
		top,
		"WoodPanel"
	)
end
platform("L3_Bench_Boys1", "L3_LockerRoom_Boys", 137, 61, 12, 1.5, 1.6, 1.6, "WoodPanel")
platform("L3_Bench_Boys2", "L3_LockerRoom_Boys", 157, 61, 12, 1.5, 1.6, 1.6, "WoodPanel")
platform("L3_Bench_Girls1", "L3_LockerRoom_Girls", 137, 98, 12, 1.5, 1.6, 1.6, "WoodPanel")
platform("L3_Bench_Girls2", "L3_LockerRoom_Girls", 157, 98, 12, 1.5, 1.6, 1.6, "WoodPanel")
platform("L3_WeightRack", "L3_WeightRoom", 4, 4, 20, 3, 4, 4, "MetalRust")

--------------------------------------------------------------------------------
-- Lights: one sputtering high-bay in the gym, dead tubes everywhere else, a forgotten desk lamp.
--------------------------------------------------------------------------------

lightGrid("L3_Gymnasium", "Floodlight", 4, 2, "xxxxxfxx", { flicker = "L3_GymHighBay" })
for _, id in { "L3_NorthHall_West", "L3_SouthHall_West", "L3_SouthHall_East" } :: { string } do
	lightGrid(id, "Fluorescent", 7, 1, "x")
end
lightGrid("L3_NorthHall_East", "Fluorescent", 7, 1, "xxxfxxx", { flicker = "L3_NorthHall", brightness = 0.3 })
lightGrid("L3_LockerRoom_Boys", "Fluorescent", 3, 2, "x")
lightGrid("L3_LockerRoom_Girls", "Fluorescent", 3, 2, "xxxxfx", { flicker = "L3_LockerGirls", brightness = 0.3 })
lightGrid("L3_Showers_Boys", "Fluorescent", 1, 2, "x")
lightGrid("L3_Showers_Girls", "Fluorescent", 1, 2, "x")
lightGrid("L3_GymFoyer", "Fluorescent", 2, 3, "x")
for _, id in
	{
		"L3_WeightRoom",
		"L3_EquipmentStore",
		"L3_TrainerRoom",
		"L3_AthleticDirector",
		"L3_LaundryRoom",
		"L3_Restroom_North",
		"L3_WrestlingRoom",
		"L3_DanceStudio",
		"L3_TeamRoom",
		"L3_ConcessionStand",
		"L3_TicketOffice",
	} :: { string }
do
	lightGrid(id, "Fluorescent", 2, 1, "x")
end
for _, id in
	{ "L3_Storage_W1", "L3_Storage_W2", "L3_Storage_E1", "L3_Storage_E2", "L3_Storage_N", "L3_MatStore" } :: { string }
do
	lightGrid(id, "Bulb", 1, 1, "x")
end
light("L3_CoachOffice", "Bulb", 130, 3.2, 8, { brightness = 0.22, range = 10 })
light("L3_AirlockEast", "EmergencyRed", 234, LOW - 1, 80, { flicker = "L3_AirlockEast", brightness = 0.35 })
light("L3_AirlockWest", "EmergencyRed", 6, LOW - 1, 80, { flicker = "L3_AirlockWest", brightness = 0.35 })
light("L3_Gymnasium", "ExitSign", 13.5, 11, 80)
light("L3_GymFoyer", "ExitSign", 226.5, 11, 80)

--------------------------------------------------------------------------------
-- Anchors
--------------------------------------------------------------------------------

-- Arrival from Stairwell_2_3
scatter("PlayerSpawn", 3.5, { { 232, 74, FACE_W }, { 236, 74, FACE_W }, { 232, 86, FACE_W }, { 236, 86, FACE_W } })
anchor("CreatureSpawn", 60, 5, 80, FACE_W, "L3_CreatureSpawn")

-- Hideable lockers (kept clear of doors and grate openings)
lockerRow(46.8, { 132, 135, 138, 141, 144, 147, 158, 161, 164, 167 }, FACE_S)
lockerRow(76.2, { 131, 143, 146, 149, 152, 155 }, FACE_N)
lockerRow(113.2, { 132, 135, 138, 141, 144, 147, 158, 161, 164, 167 }, FACE_N)
lockerRow(84.8, { 131, 134, 152, 155, 158, 161 }, FACE_S)
lockerRow(43.2, { 186, 189, 192, 195 }, FACE_N)
lockerRow(116.8, { 186, 189, 192, 195 }, FACE_S)

-- Floor objective (GymGenerator): the coach's key hangs inside one of six locker-room lockers (each candidate's ref is
-- its locker; the anchor is the hook on the locker's back wall at chest height, facing out through its door); the
-- generator stands free in the equipment store, its pull start toward the door; the store door's padlock (the floor
-- point on the door's corridor face, facing out of the door); hideable lockers in the store, outside its door and in
-- the two stores off the gym beside the stairwell door, where the squad hides while the door motor winds; the exit
-- lock on the west stair airlock's fire door.
local KEY_HOOK_Y = 4.6
local KEY_BACK = 1.1 -- the hook sits this far behind the locker's floor centre, toward its back wall
local function lockerAt(x: number, z: number): string
	for _, a in anchors do
		if a.kind == "Locker" and math.abs(a.pos.X - x) < 1e-3 and math.abs(a.pos.Z - z) < 1e-3 then
			return a.id
		end
	end
	error(string.format("%s layout: no locker at (%.1f, %.1f)", PREFIX, x, z), 2)
end
for _, spot in
	{
		{ 138, 46.8, FACE_S },
		{ 164, 46.8, FACE_S },
		{ 146, 76.2, FACE_N },
		{ 138, 113.2, FACE_N },
		{ 164, 113.2, FACE_N },
		{ 158, 84.8, FACE_S },
	} :: { { number } }
do
	local x, z, yaw = spot[1], spot[2], spot[3]
	local back = if yaw == FACE_S then -KEY_BACK else KEY_BACK -- facing south, the back wall is to the north
	anchor("CoachKeyCandidate", x, KEY_HOOK_Y, z + back, yaw, nil, lockerAt(x, z))
end
anchor("Generator", 66, 0, 13, FACE_S, "L3_Generator")
anchor("StoreLock", 66, 0, 31.5, FACE_S, "L3_StoreLock")
scatter("Locker", 0, {
	{ 82.2, 8, FACE_W }, -- equipment store
	{ 82.2, 11, FACE_W },
	{ 76, 32.8, FACE_S }, -- north hall, outside the store
	{ 5.5, 64.7, FACE_N }, -- the two stores off the gym either side of the stairwell door
	{ 5.5, 95.3, FACE_S },
})
anchor("ExitLock", 12.5, 0, 80, FACE_E, "L3_ExitLock")

scatter(
	"SmashedLocker",
	0,
	{ { 60, 43.2, FACE_N }, { 90, 43.2, FACE_N }, { 60, 116.8, FACE_S }, { 96, 116.8, FACE_S } }
)

scatter("BatteryCandidate", 0, {
	{ 4, 26 },
	{ 136, 4 },
	{ 80, 4 },
	{ 192, 4 },
	{ 172, 156 },
	{ 236, 156 },
	{ 6, 50 },
	{ 234, 110 },
	{ 190, 112 },
})

scatter("Corpse", 0, { { 60, 70, 0 }, { 186, 50, -45 }, { 100, 40, 150 } })
scatter("DripPipe", LOW - 1.2, { { 186, 60 }, { 186, 100 }, { 180, 15 }, { 205, 20 } })
scatter("Clutter", 0, {
	{ 40, 70, 0 },
	{ 90, 95, 45 },
	{ 70, 62, 120 },
	{ 30, 98, -30 },
	{ 145, 70, 10 },
	{ 165, 90, -20 },
	{ 210, 60, 30 },
	{ 215, 100, 60 },
	{ 60, 20, 0 },
	{ 30, 145, 90 },
	{ 90, 150, 15 },
	{ 190, 145, -45 },
	{ 125, 20, 0 },
	{ 130, 145, 30 },
})

patrol("GYM", { { 20, 60 }, { 66, 60 }, { 116, 60 }, { 116, 100 }, { 66, 100 }, { 20, 100 } })
patrol("GC", { { 66, 70 }, { 90, 80 }, { 66, 90 }, { 40, 80 } })
patrol("GN", { { 18, 62 }, { 18, 38 }, { 116, 38 }, { 114, 62 } })
patrol("GS", { { 18, 98 }, { 18, 122 }, { 116, 122 }, { 114, 98 } })
patrol("LB", { { 152, 38 }, { 150, 52 }, { 170, 70 }, { 186, 62 }, { 165, 54 } })
patrol("LG", { { 152, 122 }, { 150, 108 }, { 170, 90 }, { 186, 99 }, { 165, 106 } })
patrol("FY", { { 212, 55 }, { 220, 80 }, { 212, 105 }, { 204, 80 } })
patrol("NE", { { 140, 38 }, { 230, 38 }, { 180, 40 } })
patrol("SE", { { 140, 122 }, { 230, 122 }, { 180, 120 } })
patrol("NW", { { 10, 38 }, { 120, 38 }, { 60, 40 } })
patrol("SW", { { 10, 122 }, { 120, 122 }, { 60, 120 } })

--------------------------------------------------------------------------------
-- Triggers
--------------------------------------------------------------------------------

trigger("L3_Trigger_DebrisCourt", "FloorDebris", 60, 76, 8, 8, 4)
trigger("L3_Trigger_DebrisShowers", "FloorDebris", 180, 102, 6, 6, 4)
trigger("L3_Trigger_DebrisNorthHall", "FloorDebris", 140, 33, 6, 10, 4)
trigger("L3_Trigger_Checkpoint", "Checkpoint", 1, 67, 10, 26, 10)

--------------------------------------------------------------------------------
-- Boarded windows on the facade
--------------------------------------------------------------------------------

windowRow("L3_WeightRoom", "N", 3, 7, 6, 3.5, true)
windowRow("L3_EquipmentStore", "N", 2, 5, 3, 8, true)
windowRow("L3_TrainerRoom", "N", 2, 7, 6, 3.5, true)
windowRow("L3_CoachOffice", "N", 2, 7, 6, 3.5, true)
windowRow("L3_AthleticDirector", "N", 1, 7, 6, 3.5, true)
windowRow("L3_LaundryRoom", "N", 2, 5, 3, 8, true)
windowRow("L3_Restroom_North", "N", 1, 4, 3, 8, true)
windowRow("L3_Storage_N", "N", 1, 5, 3, 8, true)
windowRow("L3_WrestlingRoom", "S", 3, 7, 6, 3.5, true)
windowRow("L3_DanceStudio", "S", 3, 7, 6, 3.5, true)
windowRow("L3_TeamRoom", "S", 2, 7, 6, 3.5, true)
windowRow("L3_MatStore", "S", 1, 5, 3, 8, true)
windowRow("L3_ConcessionStand", "S", 2, 7, 6, 3.5, true)
windowRow("L3_TicketOffice", "S", 2, 7, 6, 3.5, true)
windowRow("L3_WeightRoom", "W", 1, 7, 6, 3.5, true)
windowRow("L3_NorthHall_West", "W", 1, 6, 6, 3.5, true)
windowRow("L3_Storage_W1", "W", 1, 4, 4, 5, true)
windowRow("L3_Storage_W2", "W", 1, 4, 4, 5, true)
windowRow("L3_SouthHall_West", "W", 1, 6, 6, 3.5, true)
windowRow("L3_WrestlingRoom", "W", 1, 7, 6, 3.5, true)
windowRow("L3_Storage_N", "E", 1, 5, 3, 8, true)
windowRow("L3_NorthHall_East", "E", 1, 6, 6, 3.5, true)
windowRow("L3_Storage_E1", "E", 1, 4, 4, 5, true)
windowRow("L3_Storage_E2", "E", 1, 4, 4, 5, true)
windowRow("L3_SouthHall_East", "E", 1, 6, 6, 3.5, true)
windowRow("L3_TicketOffice", "E", 1, 7, 6, 3.5, true)

--------------------------------------------------------------------------------

local layout: LayoutSchema.LevelLayout = {
	id = "Level3_Gymnasium",
	height = HEIGHT,
	acoustic = "Hall",
	ambience = "DroneGym",
	entry = "L3_AirlockEast",
	exit = "L3_AirlockWest",
	rooms = rooms,
	doors = doors,
	vents = { nodes = ventNodes, edges = ventEdges, grates = grates },
	anchors = anchors,
	triggers = triggers,
	platforms = platforms,
	windows = windows,
}

deepFreeze(layout)

return layout
