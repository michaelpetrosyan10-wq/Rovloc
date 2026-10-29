--!strict
-- Level 0 · Boiler Basement (below grade). The squad drops in from the lobby into L0_DeliveryBay on the west wall
-- and must cross the pitch-black undercroft to L0_AirlockEast. No Creature activity here: the danger is the
-- randomized bear traps (RunDirector picks from the TrapCandidate anchors every run).
--
-- Plan (X west -> east, Z north -> south):
--   x   0..24   west service rooms (workshop, delivery bay = spawn, laundry)
--   z   0..30   north plant rooms (coal bunker, north boiler room, electrical) along the exterior wall
--   z  30..130  three pillared halls: west undercroft -> boiler hall (two boilers force a detour) -> east undercroft
--   z 130..160  south plant rooms (pump room, south boiler room, water heaters, a condemned store)
--   x 228..240  east stores around the stair airlock
-- The undercroft-to-boiler-hall wall only opens at its north and south ends, while the boiler hall opens east only
-- at its middle, past the two boilers, so the walk route snakes past the trap fields.
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

local PREFIX = "L0"
local HEIGHT = WorldConfig.Levels.Level0_Basement.height

local FACE_N, FACE_W, FACE_E = 0, 90, -90

local LIGHT_DEFAULTS: { [string]: LightDefaults } = {
	Fluorescent = { brightness = 0.55, range = 18, color = Color3.fromRGB(214, 232, 236) },
	Bulb = { brightness = 0.45, range = 14, color = Color3.fromRGB(255, 190, 128) },
	EmergencyRed = { brightness = 0.45, range = 16, color = Color3.fromRGB(255, 34, 18) },
	ClassroomGlow = { brightness = 1.1, range = 34, color = Color3.fromRGB(198, 220, 255) },
	Floodlight = { brightness = 2, range = 60, color = Color3.fromRGB(236, 240, 255) },
	ExitSign = { brightness = 0.3, range = 8, color = Color3.fromRGB(70, 255, 120) },
	BoilerGlow = { brightness = 0.8, range = 14, color = Color3.fromRGB(255, 112, 36) },
}

local HALL: Style = {
	floor = "ConcreteStained",
	wall = "ConcreteDark",
	ceiling = "ConcreteDark",
	surface = "Concrete",
	acoustic = "Basement",
}
local BOILER: Style =
	{ floor = "ConcreteStained", wall = "Brick", ceiling = "ConcreteDark", surface = "Concrete", acoustic = "Basement" }
local PLANT: Style =
	{ floor = "Concrete", wall = "ConcreteDark", ceiling = "ConcreteDark", surface = "Concrete", acoustic = "Basement" }
local STORE: Style =
	{ floor = "ConcreteStained", wall = "Brick", ceiling = "Concrete", surface = "Concrete", acoustic = "Room" }
local LAUNDRY: Style =
	{ floor = "TileWhite", wall = "PlasterSchool", ceiling = "Concrete", surface = "Tile", acoustic = "Room" }
local WORKSHOP: Style =
	{ floor = "ConcreteStained", wall = "WoodPanel", ceiling = "Concrete", surface = "Concrete", acoustic = "Room" }
local ELECTRICAL: Style =
	{ floor = "MetalGalvanized", wall = "ConcreteDark", ceiling = "Concrete", surface = "Metal", acoustic = "Room" }
local AIRLOCK: Style =
	{ floor = "Concrete", wall = "ConcreteDark", ceiling = "Concrete", surface = "Concrete", acoustic = "Stairwell" }

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
local pillars: { LayoutSchema.Pillar } = {}
local platforms: { LayoutSchema.Platform } = {}
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

-- The room holding (x, z) at least 0.25 studs inside its walls.
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

local function pillarGrid(roomId: string, xs: { number }, zs: { number }, size: number)
	for _, x in xs do
		for _, z in zs do
			table.insert(pillars, { room = roomId, x = x, z = z, size = size })
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

-- West service rooms
room("L0_Storage_NW", "Storage", 0, 0, 24, 30, STORE)
room("L0_Workshop", "Storage", 0, 30, 24, 32, WORKSHOP)
room("L0_DeliveryBay", "Storage", 0, 62, 24, 36, PLANT)
room("L0_Laundry", "Storage", 0, 98, 24, 32, LAUNDRY)
room("L0_Storage_SW", "Storage", 0, 130, 24, 30, STORE)

-- North plant rooms
room("L0_CoalBunker", "Boiler", 24, 0, 48, 30, BOILER)
room("L0_FurnitureStore", "Storage", 72, 0, 48, 30, STORE)
room("L0_BoilerRoom_North", "Boiler", 120, 0, 48, 30, BOILER)
room("L0_ElectricalRoom", "Storage", 168, 0, 36, 30, ELECTRICAL)
room("L0_Storage_NE", "Storage", 204, 0, 36, 30, STORE)

-- The three halls
room("L0_Undercroft_West", "Storage", 24, 30, 80, 100, HALL)
room("L0_BoilerHall", "Boiler", 104, 30, 72, 100, BOILER)
room("L0_Undercroft_East", "Storage", 176, 30, 52, 100, HALL)

-- East stores and the stair vestibule
room("L0_Store_E1", "Storage", 228, 30, 12, 36, STORE)
room("L0_AirlockEast", "Airlock", 228, 66, 12, 28, AIRLOCK)
room("L0_Store_E2", "Storage", 228, 94, 12, 36, STORE)

-- South plant rooms
room("L0_PumpRoom", "Boiler", 24, 130, 48, 30, PLANT)
room("L0_ArchiveStore", "Storage", 72, 130, 48, 30, STORE)
room("L0_BoilerRoom_South", "Boiler", 120, 130, 48, 30, BOILER)
room("L0_WaterHeaterRoom", "Boiler", 168, 130, 36, 30, PLANT)
room("L0_CondemnedStore", "Storage", 204, 130, 36, 30, STORE)

--------------------------------------------------------------------------------
-- Doors
--------------------------------------------------------------------------------

door("Doorway", "L0_DeliveryBay", "L0_Undercroft_West", 80, { width = 8 })
door("Door", "L0_Workshop", "L0_Undercroft_West", 46)
door("Door", "L0_Workshop", "L0_Storage_NW", 12)
door("Door", "L0_Laundry", "L0_Undercroft_West", 114)
door("Door", "L0_Laundry", "L0_Storage_SW", 12)

door("Doorway", "L0_Undercroft_West", "L0_CoalBunker", 48, { width = 8 })
door("Door", "L0_Undercroft_West", "L0_FurnitureStore", 88)
door("Doorway", "L0_BoilerHall", "L0_BoilerRoom_North", 144, { width = 8 })
door("Door", "L0_BoilerRoom_North", "L0_ElectricalRoom", 15)
door("Door", "L0_Undercroft_East", "L0_ElectricalRoom", 190)
door("Door", "L0_Undercroft_East", "L0_Storage_NE", 216)

door("Doorway", "L0_Undercroft_West", "L0_BoilerHall", 46, { width = 10 })
door("Doorway", "L0_Undercroft_West", "L0_BoilerHall", 114, { width = 10 })
door("Doorway", "L0_BoilerHall", "L0_Undercroft_East", 80, { width = 10 })

door("Door", "L0_Undercroft_East", "L0_Store_E1", 48)
door("Airlock", "L0_Undercroft_East", "L0_AirlockEast", 80, { id = "L0_Door_AirlockEast" })
door("Door", "L0_Undercroft_East", "L0_Store_E2", 112)

door("Doorway", "L0_Undercroft_West", "L0_PumpRoom", 48, { width = 8 })
door("Door", "L0_Undercroft_West", "L0_ArchiveStore", 88)
door("Doorway", "L0_BoilerHall", "L0_BoilerRoom_South", 144, { width = 8 })
door("Door", "L0_BoilerRoom_South", "L0_WaterHeaterRoom", 145)
door("Door", "L0_Undercroft_East", "L0_WaterHeaterRoom", 190)
door("Boarded", "L0_Undercroft_East", "L0_CondemnedStore", 216, { id = "L0_Door_Condemned" })

--------------------------------------------------------------------------------
-- Structure: pillar grids, boilers and plant (platforms are solid blocks standing on the floor)
--------------------------------------------------------------------------------

pillarGrid("L0_Undercroft_West", { 40, 56, 72, 88 }, { 38, 54, 70, 90, 106, 122 }, 2.5)
pillarGrid("L0_BoilerHall", { 112, 128, 152, 168 }, { 38, 54, 106, 122 }, 2.5)
pillarGrid("L0_Undercroft_East", { 192, 212 }, { 38, 54, 70, 90, 106, 122 }, 2.5)

platform("L0_Boiler_A", "L0_BoilerHall", 118, 62, 18, 36, 10, 10, "MetalRust")
platform("L0_Boiler_B", "L0_BoilerHall", 144, 62, 18, 36, 10, 10, "MetalRust")
platform("L0_Boiler_C", "L0_BoilerRoom_North", 132, 6, 24, 14, 8, 8, "MetalRust")
platform("L0_Boiler_D", "L0_BoilerRoom_South", 132, 140, 24, 14, 8, 8, "MetalRust")
platform("L0_WaterHeater_A", "L0_WaterHeaterRoom", 176, 140, 10, 10, 9, 9, "MetalGalvanized")
platform("L0_WaterHeater_B", "L0_WaterHeaterRoom", 176, 150, 10, 8, 9, 9, "MetalGalvanized")
platform("L0_CoalHeap", "L0_CoalBunker", 28, 4, 20, 10, 3, 3, "ConcreteDark")
platform("L0_Pump_A", "L0_PumpRoom", 32, 140, 8, 6, 4, 4, "MetalRust")
platform("L0_Pump_B", "L0_PumpRoom", 32, 150, 8, 6, 4, 4, "MetalRust")
platform("L0_Switchgear", "L0_ElectricalRoom", 172, 2, 28, 4, 8, 8, "MetalGalvanized")
platform("L0_Workbench", "L0_Workshop", 2, 52, 4, 8, 3, 3, "WoodPanel")
-- Steel shelving in the stores and a bank of washers in the laundry (fuse candidates lie on their tops)
platform("L0_Shelf_NW", "L0_Storage_NW", 2, 0, 8, 2.6, 4, 4, "MetalRust")
platform("L0_Shelf_SW", "L0_Storage_SW", 12, 157.4, 10, 2.6, 4, 4, "MetalRust")
platform("L0_Washers", "L0_Laundry", 0, 100, 7, 12, 3.2, 3.2, "MetalGalvanized")
platform("L0_Shelf_Furniture", "L0_FurnitureStore", 110, 0, 8, 2.6, 4, 4, "MetalRust")
platform("L0_Shelf_Archive", "L0_ArchiveStore", 100, 157.4, 10, 2.6, 4, 4, "MetalRust")
platform("L0_Shelf_E1", "L0_Store_E1", 237.4, 34, 2.6, 10, 4, 4, "MetalRust")

--------------------------------------------------------------------------------
-- Lights: the basement is pitch black. Pilot flames glow behind boiler doors; one red lamp marks the stairs.
--------------------------------------------------------------------------------

lightGrid("L0_Undercroft_West", "Bulb", 3, 3, "x")
lightGrid("L0_BoilerHall", "Bulb", 3, 3, "xxxxfxxxx", { flicker = "L0_HallBulb", brightness = 0.25 })
lightGrid("L0_Undercroft_East", "Bulb", 2, 3, "x")
for _, id in
	{
		"L0_Storage_NW",
		"L0_Workshop",
		"L0_Laundry",
		"L0_Storage_SW",
		"L0_CoalBunker",
		"L0_FurnitureStore",
		"L0_BoilerRoom_North",
		"L0_ElectricalRoom",
		"L0_Storage_NE",
		"L0_Store_E1",
		"L0_Store_E2",
		"L0_PumpRoom",
		"L0_ArchiveStore",
		"L0_BoilerRoom_South",
		"L0_WaterHeaterRoom",
		"L0_CondemnedStore",
	} :: { string }
do
	lightGrid(id, "Bulb", 1, 1, "x")
end
lightGrid("L0_DeliveryBay", "Bulb", 1, 2, "fx", { flicker = "L0_Spawn", brightness = 0.3 })
lightGrid("L0_AirlockEast", "Fluorescent", 1, 2, "x")

light("L0_BoilerHall", "BoilerGlow", 127, 2, 61, { flicker = "L0_Boilers" })
light("L0_BoilerHall", "BoilerGlow", 153, 2, 99, { flicker = "L0_Boilers" })
light("L0_BoilerRoom_North", "BoilerGlow", 144, 2, 21, { flicker = "L0_Boilers", brightness = 0.6 })
light("L0_BoilerRoom_South", "BoilerGlow", 144, 2, 139, { flicker = "L0_Boilers", brightness = 0.6 })
light("L0_Undercroft_East", "EmergencyRed", 226, HEIGHT - 3, 80, { flicker = "L0_Exit", brightness = 0.5 })
light("L0_Undercroft_East", "ExitSign", 226.5, 11, 80)
light("L0_AirlockEast", "EmergencyRed", 234, HEIGHT - 1, 80, { brightness = 0.3 })

--------------------------------------------------------------------------------
-- Anchors
--------------------------------------------------------------------------------

-- Arrival from the lobby (DevTools "level 0" and the run deploy land here)
scatter("PlayerSpawn", 3.5, { { 6, 76, FACE_E }, { 10, 76, FACE_E }, { 6, 84, FACE_E }, { 10, 84, FACE_E } })

-- The Creature lies Dormant behind the boarded door of the condemned store until the director wakes it.
anchor("CreatureSpawn", 222, 5, 148, FACE_N, "L0_CreatureSpawn")

-- Bear trap candidates over the walk route (>= 8 studs apart, clear of pillars and plant).
local trapPoints: { { number } } = {}
for _, x in { 32, 48, 64, 80, 96 } do
	for _, z in { 46, 62, 80, 98, 114 } do
		table.insert(trapPoints, { x, z })
	end
end
for _, p in
	{
		-- boiler hall: both detours, the gap between the boilers and the east doorway
		{ 112, 46 },
		{ 128, 46 },
		{ 144, 46 },
		{ 160, 46 },
		{ 112, 114 },
		{ 128, 114 },
		{ 144, 114 },
		{ 160, 114 },
		{ 110, 80 },
		{ 140, 80 },
		{ 170, 72 },
		{ 170, 88 },
		{ 144, 36 },
		{ 144, 124 },
		-- east undercroft: the approach to the airlock
		{ 184, 46 },
		{ 184, 62 },
		{ 184, 80 },
		{ 184, 98 },
		{ 184, 114 },
		{ 202, 46 },
		{ 202, 80 },
		{ 202, 114 },
		{ 220, 64 },
		{ 220, 96 },
		-- side rooms where batteries tempt detours
		{ 56, 20 },
		{ 96, 15 },
		{ 56, 148 },
		{ 90, 145 },
		{ 12, 40 },
		{ 12, 118 },
		{ 186, 18 },
		{ 196, 148 },
	} :: { { number } }
do
	table.insert(trapPoints, p)
end
scatter("TrapCandidate", 0, trapPoints)

scatter("BatteryCandidate", 0, {
	{ 8, 36 },
	{ 64, 6 },
	{ 110, 24 },
	{ 196, 8 },
	{ 6, 124 },
	{ 66, 156 },
	{ 78, 152 },
	{ 230, 10 },
	{ 234, 100 },
})

scatter("DripPipe", HEIGHT - 1.2, {
	{ 48, 72 },
	{ 136, 44 },
	{ 200, 100 },
	{ 12, 104 },
	{ 50, 136 },
	{ 126, 156 },
})

scatter("Corpse", 0, { { 14, 44, 60 }, { 206, 120, -20 } })

-- Floor objective (RestorePower): thirteen fuse candidates on benches and shelves, by the boilers, the pumps, the
-- switchgear and the water heaters, all over the basement (RunDirector uses three, in different rooms), each with a
-- bear-trap spot on its approach (its ref: the director arms the guard traps of the first two fuses it uses), each a
-- few studs from a dark corner of its room and well away from the delivery bay; the breaker panel on the electrical room's east wall (the anchor is the
-- floor point on the wall face, facing into the room); the exit lock on the stair airlock's fire door (the floor point
-- on the door's corridor face, facing out of the door).
local function fuse(x: number, y: number, z: number, guardX: number, guardZ: number)
	local n = (anchorCounts.FuseCandidate or 0) + 1
	local guard = anchor("TrapCandidate", guardX, 0, guardZ, nil, string.format("%s_TrapGuard_%02d", PREFIX, n))
	anchor("FuseCandidate", x, y, z, nil, nil, guard)
end
fuse(4, 3, 57, 9.5, 56) -- on the workshop bench
fuse(5, 4, 1.8, 7, 8) -- on the shelving in the north-west store
fuse(4, 3.2, 104, 10.5, 104) -- on the washers
fuse(37, 0, 148, 44, 148) -- wedged between the pumps
fuse(44, 3, 12.5, 45, 19.5) -- on the coal heap, past the coal dust
fuse(17, 4, 158.4, 17, 151) -- on the shelving in the south-west store
fuse(126, 0, 24, 132, 26) -- on the floor beside the north boiler
fuse(126, 0, 136, 132, 134) -- on the floor beside the south boiler
fuse(172, 0, 9, 176, 14) -- dropped in front of the switchgear
fuse(114, 4, 1.8, 110, 8) -- on the shelving in the furniture store
fuse(105, 4, 158.4, 100, 152) -- on the shelving in the archive store
fuse(190, 0, 145, 196, 140) -- on the floor by the water heaters
fuse(238.6, 4, 39, 234, 44) -- on the shelving in the east store by the stairs
anchor("BreakerPanel", 203.5, 0, 18, FACE_W, "L0_BreakerPanel")
anchor("ExitLock", 227.5, 0, 80, FACE_W, "L0_ExitLock")

scatter("Clutter", 0, {
	{ 30, 36, 0 },
	{ 100, 36, 45 },
	{ 30, 124, 90 },
	{ 100, 124, 15 },
	{ 64, 100, -30 },
	{ 120, 54, 20 },
	{ 164, 106, 70 },
	{ 196, 40, -45 },
	{ 222, 120, 10 },
	{ 80, 10, 0 },
	{ 100, 150, 30 },
	{ 216, 20, 60 },
	{ 18, 140, 0 },
	{ 18, 10, 80 },
})

--------------------------------------------------------------------------------
-- Triggers
--------------------------------------------------------------------------------

trigger("L0_Trigger_DebrisJars", "FloorDebris", 60, 74, 8, 12, 4)
trigger("L0_Trigger_DebrisBoilerGap", "FloorDebris", 136, 72, 8, 16, 4)
trigger("L0_Trigger_DebrisGlass", "FloorDebris", 196, 100, 8, 8, 4)
trigger("L0_Trigger_DebrisCoal", "FloorDebris", 34, 16, 10, 8, 4)
trigger("L0_Trigger_Checkpoint", "Checkpoint", 229, 67, 10, 26, 12)

--------------------------------------------------------------------------------
-- Boarded windows high on the foundation walls (light wells to the street)
--------------------------------------------------------------------------------

local SILL, PANE_H, PANE_W = HEIGHT - 4.5, 3, 6
windowRow("L0_Storage_NW", "N", 1, PANE_W, PANE_H, SILL, true)
windowRow("L0_CoalBunker", "N", 2, PANE_W, PANE_H, SILL, true)
windowRow("L0_FurnitureStore", "N", 2, PANE_W, PANE_H, SILL, true)
windowRow("L0_BoilerRoom_North", "N", 2, PANE_W, PANE_H, SILL, true)
windowRow("L0_ElectricalRoom", "N", 1, PANE_W, PANE_H, SILL, true)
windowRow("L0_Storage_NE", "N", 1, PANE_W, PANE_H, SILL, true)
windowRow("L0_Storage_SW", "S", 1, PANE_W, PANE_H, SILL, true)
windowRow("L0_PumpRoom", "S", 2, PANE_W, PANE_H, SILL, true)
windowRow("L0_ArchiveStore", "S", 2, PANE_W, PANE_H, SILL, true)
windowRow("L0_BoilerRoom_South", "S", 2, PANE_W, PANE_H, SILL, true)
windowRow("L0_WaterHeaterRoom", "S", 1, PANE_W, PANE_H, SILL, true)
windowRow("L0_CondemnedStore", "S", 1, PANE_W, PANE_H, SILL, true)
windowRow("L0_Storage_NW", "W", 1, PANE_W, PANE_H, SILL, true)
windowRow("L0_Workshop", "W", 1, PANE_W, PANE_H, SILL, true)
windowRow("L0_Laundry", "W", 1, PANE_W, PANE_H, SILL, true)
windowRow("L0_Storage_SW", "W", 1, PANE_W, PANE_H, SILL, true)
windowRow("L0_Storage_NE", "E", 1, PANE_W, PANE_H, SILL, true)
windowRow("L0_Store_E1", "E", 1, PANE_W, PANE_H, SILL, true)
windowRow("L0_Store_E2", "E", 1, PANE_W, PANE_H, SILL, true)
windowRow("L0_CondemnedStore", "E", 1, PANE_W, PANE_H, SILL, true)

--------------------------------------------------------------------------------

local layout: LayoutSchema.LevelLayout = {
	id = "Level0_Basement",
	height = HEIGHT,
	acoustic = "Basement",
	ambience = "DroneBasement",
	entry = "L0_DeliveryBay",
	exit = "L0_AirlockEast",
	rooms = rooms,
	doors = doors,
	anchors = anchors,
	triggers = triggers,
	pillars = pillars,
	platforms = platforms,
	windows = windows,
}

deepFreeze(layout)

return layout
