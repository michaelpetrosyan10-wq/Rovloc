--!strict
-- Level 2 · Science Hall. The squad arrives in L2_AirlockWest from Stairwell_1_2 and must reach L2_AirlockEast.
--
-- Plan (X west -> east, Z north -> south), on the same structural grid as Level 1:
--   z   0..26  north rooms (science library, staff room, chemical store)    z  26..40  north hall
--   z  40..73  chem labs + prep rooms                                       z  73..87  main corridor
--   z  87..120 bio / physics labs, specimen store, darkroom                 z 120..134 south hall
--   z 134..160 lecture hall, botany room, classrooms
-- The main corridor collapsed at x = 120 (a boarded barricade), so the squad detours through the cross halls and
-- the outer halls, or takes the vents. Every pair of labs is separated by a 5-stud fume-extract chase whose duct
-- opens into both labs and both halls; L2_Chase_B behind the prep rooms is the guaranteed (critical) crawl past the
-- barricade, the rest are fair game for the RunDirector to lock.
--
-- Lab islands: each LabCounter anchor is the floor centre of a 10 x 3.5 worktop whose long axis runs along X (the
-- anchor's RightVector), top at WORKTOP; FlaskCandidate anchors stand on those worktops.
-- Anchor heights otherwise: props on the floor (y = 0), DripPipe under the ceiling, PlayerSpawn at root height plus
-- clearance (3.5), Creature placements at the rig's root height (5). Yaw: 0 faces north (-Z), 90 west, 180 south,
-- -90 east.

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

local PREFIX = "L2"
local HEIGHT = WorldConfig.Levels.Level2_ScienceHall.height
local WORKTOP = 3.2

local FACE_N, FACE_E = 0, -90

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
local CHEM_LAB: Style =
	{ floor = "Lab", wall = "TileGreen", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local BIO_LAB: Style =
	{ floor = "Lab", wall = "TileWhite", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local PHYSICS_LAB: Style =
	{ floor = "Linoleum", wall = "PlasterSchool", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local PREP: Style =
	{ floor = "Lab", wall = "PlasterGreen", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local DARKROOM: Style =
	{ floor = "ConcreteDark", wall = "ConcreteDark", ceiling = "ConcreteDark", surface = "Concrete", acoustic = "Room" }
local CLASSROOM: Style =
	{ floor = "Linoleum", wall = "PlasterSchool", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local LIBRARY: Style =
	{ floor = "Carpet", wall = "WoodPanel", ceiling = "PlasterSchool", surface = "Carpet", acoustic = "Room" }
local LECTURE: Style =
	{ floor = "Carpet", wall = "WoodPanel", ceiling = "PlasterSchool", surface = "Carpet", acoustic = "Hall" }
local BOTANY: Style =
	{ floor = "TileGreen", wall = "PlasterGreen", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local OFFICE: Style =
	{ floor = "Carpet", wall = "PlasterSchool", ceiling = "PlasterSchool", surface = "Carpet", acoustic = "Room" }
local RESTROOM: Style =
	{ floor = "TileWhite", wall = "TileWhite", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local STORAGE: Style =
	{ floor = "ConcreteStained", wall = "ConcreteDark", ceiling = "Concrete", surface = "Concrete", acoustic = "Room" }
local CHEM_STORE: Style = {
	floor = "ConcreteStained",
	wall = "MetalGalvanized",
	ceiling = "Concrete",
	surface = "Concrete",
	acoustic = "Room",
}
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

-- columns x rows lab islands evenly set out over a room, with flask candidates at `flaskOffsets` along each
-- worktop (studs from its centre, along X).
local function labIslands(roomId: string, columns: number, rows: number, flaskOffsets: { number })
	local rect = getRoom(roomId).rect
	for i = 1, columns do
		for j = 1, rows do
			local fx = if columns == 1 then 0.5 else 0.3 + 0.4 * (i - 1) / (columns - 1)
			local fz = if rows == 1 then 0.5 else 0.35 + 0.35 * (j - 1) / (rows - 1)
			local x, z = rect.x + rect.w * fx, rect.z + rect.d * fz
			anchor("LabCounter", x, 0, z, FACE_N)
			for _, offset in flaskOffsets do
				anchor("FlaskCandidate", x + offset, WORKTOP, z)
			end
		end
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
room("L2_NorthHall", "Corridor", 0, 26, 240, 14, CORRIDOR)
room("L2_SouthHall", "Corridor", 0, 120, 240, 14, CORRIDOR)
room("L2_Corridor_West", "Corridor", 12, 73, 108, 14, CORRIDOR)
room("L2_Corridor_East", "Corridor", 120, 73, 108, 14, CORRIDOR)
room("L2_CrossHall_NW", "Corridor", 81, 40, 14, 33, CORRIDOR)
room("L2_CrossHall_NE", "Corridor", 150, 40, 14, 33, CORRIDOR)
room("L2_CrossHall_SW", "Corridor", 81, 87, 14, 33, CORRIDOR)
room("L2_CrossHall_SE", "Corridor", 150, 87, 14, 33, CORRIDOR)

-- Stair vestibules
room("L2_AirlockWest", "Airlock", 0, 66, 12, 28, AIRLOCK)
room("L2_AirlockEast", "Airlock", 228, 66, 12, 28, AIRLOCK)

-- Chem wing (north of the main corridor)
room("L2_Storage_201A", "Storage", 0, 40, 12, 26, STORAGE)
room("L2_ChemLab_201", "Lab", 12, 40, 32, 33, CHEM_LAB)
room("L2_Chase_A", "Chase", 44, 40, 5, 33, CHASE)
room("L2_ChemLab_203", "Lab", 49, 40, 32, 33, CHEM_LAB)
room("L2_ChemPrep_205", "Lab", 95, 40, 25, 33, PREP)
room("L2_Chase_B", "Chase", 120, 40, 5, 33, CHASE)
room("L2_BioPrep_207", "Lab", 125, 40, 25, 33, PREP)
room("L2_BioLab_209", "Lab", 164, 40, 32, 33, BIO_LAB)
room("L2_Chase_C", "Chase", 196, 40, 5, 33, CHASE)
room("L2_BioLab_211", "Lab", 201, 40, 27, 33, BIO_LAB)
room("L2_Storage_211A", "Storage", 228, 40, 12, 26, STORAGE)

-- Bio / physics wing (south of the main corridor)
room("L2_Storage_221A", "Storage", 0, 94, 12, 26, STORAGE)
room("L2_BioLab_221", "Lab", 12, 87, 32, 33, BIO_LAB)
room("L2_Chase_D", "Chase", 44, 87, 5, 33, CHASE)
room("L2_BioLab_223", "Lab", 49, 87, 32, 33, BIO_LAB)
room("L2_SpecimenStore_225", "Storage", 95, 87, 25, 33, PREP)
room("L2_Chase_E", "Chase", 120, 87, 5, 33, CHASE)
room("L2_DarkRoom_227", "Lab", 125, 87, 25, 33, DARKROOM)
room("L2_PhysicsLab_229", "Lab", 164, 87, 32, 33, PHYSICS_LAB)
room("L2_Chase_F", "Chase", 196, 87, 5, 33, CHASE)
room("L2_ChemLab_231", "Lab", 201, 87, 27, 33, CHEM_LAB)
room("L2_Storage_231A", "Storage", 228, 94, 12, 26, STORAGE)

-- North exterior row
room("L2_Classroom_241", "Classroom", 0, 0, 30, 26, CLASSROOM)
room("L2_Restroom_North", "Restroom", 30, 0, 16, 26, RESTROOM)
room("L2_ScienceLibrary", "Classroom", 46, 0, 60, 26, LIBRARY)
room("L2_StaffRoom", "Office", 106, 0, 28, 26, OFFICE)
room("L2_Chase_G", "Chase", 134, 0, 5, 26, CHASE)
room("L2_ChemStore_243", "Storage", 139, 0, 36, 26, CHEM_STORE)
room("L2_Classroom_245", "Classroom", 175, 0, 35, 26, CLASSROOM)
room("L2_HeadOfScience", "Office", 210, 0, 30, 26, OFFICE)

-- South exterior row
room("L2_LectureHall", "Classroom", 0, 134, 64, 26, LECTURE)
room("L2_Restroom_South", "Restroom", 64, 134, 16, 26, RESTROOM)
room("L2_Chase_H", "Chase", 80, 134, 5, 26, CHASE)
room("L2_BotanyRoom_247", "Lab", 85, 134, 55, 26, BOTANY)
room("L2_Classroom_249", "Classroom", 140, 134, 36, 26, CLASSROOM)
room("L2_Classroom_251", "Classroom", 176, 134, 30, 26, CLASSROOM)
room("L2_EquipmentStore", "Storage", 206, 134, 34, 26, STORAGE)

--------------------------------------------------------------------------------
-- Doors
--------------------------------------------------------------------------------

door("Airlock", "L2_AirlockWest", "L2_Corridor_West", 80, { id = "L2_Door_AirlockWest" })
door("Airlock", "L2_Corridor_East", "L2_AirlockEast", 80, { id = "L2_Door_AirlockEast" })
door("Boarded", "L2_Corridor_West", "L2_Corridor_East", 80, { id = "L2_Door_CorridorCollapse", width = 12 })

door("Doorway", "L2_CrossHall_NW", "L2_NorthHall", 88, { width = 10 })
door("Doorway", "L2_CrossHall_NW", "L2_Corridor_West", 88, { width = 10 })
door("Doorway", "L2_CrossHall_NE", "L2_NorthHall", 157, { width = 10 })
door("Doorway", "L2_CrossHall_NE", "L2_Corridor_East", 157, { width = 10 })
door("Doorway", "L2_CrossHall_SW", "L2_Corridor_West", 88, { width = 10 })
door("Doorway", "L2_CrossHall_SW", "L2_SouthHall", 88, { width = 10 })
door("Doorway", "L2_CrossHall_SE", "L2_Corridor_East", 157, { width = 10 })
door("Doorway", "L2_CrossHall_SE", "L2_SouthHall", 157, { width = 10 })

door("Door", "L2_Storage_201A", "L2_NorthHall", 6)
door("Door", "L2_Corridor_West", "L2_ChemLab_201", 28)
door("Door", "L2_NorthHall", "L2_ChemLab_201", 20)
door("Door", "L2_Corridor_West", "L2_ChemLab_203", 65)
door("Door", "L2_NorthHall", "L2_ChemLab_203", 73)
door("Door", "L2_CrossHall_NW", "L2_ChemPrep_205", 64)
door("Door", "L2_Corridor_West", "L2_ChemPrep_205", 108)
door("Door", "L2_CrossHall_NE", "L2_BioPrep_207", 64)
door("Door", "L2_Corridor_East", "L2_BioPrep_207", 137)
door("Door", "L2_Corridor_East", "L2_BioLab_209", 180)
door("Door", "L2_NorthHall", "L2_BioLab_209", 172)
door("Door", "L2_Corridor_East", "L2_BioLab_211", 214)
door("Door", "L2_NorthHall", "L2_BioLab_211", 220)
door("Door", "L2_Storage_211A", "L2_NorthHall", 234)

door("Door", "L2_Storage_221A", "L2_SouthHall", 6)
door("Door", "L2_Corridor_West", "L2_BioLab_221", 28)
door("Door", "L2_SouthHall", "L2_BioLab_221", 20)
door("Door", "L2_Corridor_West", "L2_BioLab_223", 65)
door("Door", "L2_SouthHall", "L2_BioLab_223", 73)
door("Door", "L2_CrossHall_SW", "L2_SpecimenStore_225", 96)
door("Door", "L2_Corridor_West", "L2_SpecimenStore_225", 108)
door("Door", "L2_CrossHall_SE", "L2_DarkRoom_227", 96)
door("Door", "L2_Corridor_East", "L2_DarkRoom_227", 137)
door("Door", "L2_Corridor_East", "L2_PhysicsLab_229", 180)
door("Door", "L2_SouthHall", "L2_PhysicsLab_229", 172)
door("Door", "L2_Corridor_East", "L2_ChemLab_231", 214)
door("Door", "L2_SouthHall", "L2_ChemLab_231", 220)
door("Door", "L2_Storage_231A", "L2_SouthHall", 234)

door("Door", "L2_NorthHall", "L2_Classroom_241", 15)
door("Door", "L2_NorthHall", "L2_Restroom_North", 38)
door("Doorway", "L2_NorthHall", "L2_ScienceLibrary", 60, { width = 8 })
door("Doorway", "L2_NorthHall", "L2_ScienceLibrary", 92, { width = 8 })
door("Door", "L2_NorthHall", "L2_StaffRoom", 120)
door("Door", "L2_NorthHall", "L2_ChemStore_243", 157)
door("Door", "L2_NorthHall", "L2_Classroom_245", 192)
door("Door", "L2_NorthHall", "L2_HeadOfScience", 225)

door("Doorway", "L2_SouthHall", "L2_LectureHall", 16, { width = 8 })
door("Doorway", "L2_SouthHall", "L2_LectureHall", 48, { width = 8 })
door("Door", "L2_SouthHall", "L2_Restroom_South", 72)
door("Door", "L2_SouthHall", "L2_BotanyRoom_247", 112)
door("Door", "L2_SouthHall", "L2_Classroom_249", 158)
door("Door", "L2_SouthHall", "L2_Classroom_251", 191)
door("Door", "L2_SouthHall", "L2_EquipmentStore", 223)

--------------------------------------------------------------------------------
-- Vents: one fume-extract chase between every pair of labs, plus service chases in the outer rows.
--------------------------------------------------------------------------------

chaseRun("L2_Chase_A", {
	{ id = "L2_Grate_A_NorthHall", room = "L2_NorthHall", side = "N", lockable = true, critical = false },
	{ id = "L2_Grate_A_Corridor", room = "L2_Corridor_West", side = "S", lockable = false, critical = false },
	{ id = "L2_Grate_A_Lab201", room = "L2_ChemLab_201", side = "W", at = 52, lockable = true, critical = false },
	{ id = "L2_Grate_A_Lab203", room = "L2_ChemLab_203", side = "E", at = 62, lockable = false, critical = false },
})
-- The guaranteed crawl past the collapsed corridor: chem prep (west side) -> main corridor (east side).
chaseRun("L2_Chase_B", {
	{ id = "L2_Grate_B_NorthHall", room = "L2_NorthHall", side = "N", lockable = true, critical = false },
	{ id = "L2_Grate_B_Corridor", room = "L2_Corridor_East", side = "S", lockable = false, critical = true },
	{ id = "L2_Grate_B_ChemPrep", room = "L2_ChemPrep_205", side = "W", at = 56, lockable = false, critical = true },
	{ id = "L2_Grate_B_BioPrep", room = "L2_BioPrep_207", side = "E", at = 50, lockable = true, critical = false },
})
chaseRun("L2_Chase_C", {
	{ id = "L2_Grate_C_NorthHall", room = "L2_NorthHall", side = "N", lockable = true, critical = false },
	{ id = "L2_Grate_C_Corridor", room = "L2_Corridor_East", side = "S", lockable = false, critical = false },
	{ id = "L2_Grate_C_Lab209", room = "L2_BioLab_209", side = "W", at = 56, lockable = true, critical = false },
	{ id = "L2_Grate_C_Lab211", room = "L2_BioLab_211", side = "E", at = 50, lockable = true, critical = false },
})
chaseRun("L2_Chase_D", {
	{ id = "L2_Grate_D_Corridor", room = "L2_Corridor_West", side = "N", lockable = false, critical = false },
	{ id = "L2_Grate_D_SouthHall", room = "L2_SouthHall", side = "S", lockable = true, critical = false },
	{ id = "L2_Grate_D_Lab221", room = "L2_BioLab_221", side = "W", at = 104, lockable = true, critical = false },
	{ id = "L2_Grate_D_Lab223", room = "L2_BioLab_223", side = "E", at = 96, lockable = false, critical = false },
})
chaseRun("L2_Chase_E", {
	{ id = "L2_Grate_E_Corridor", room = "L2_Corridor_East", side = "N", lockable = true, critical = false },
	{ id = "L2_Grate_E_SouthHall", room = "L2_SouthHall", side = "S", lockable = true, critical = false },
	{
		id = "L2_Grate_E_Specimen",
		room = "L2_SpecimenStore_225",
		side = "W",
		at = 104,
		lockable = false,
		critical = false,
	},
	{ id = "L2_Grate_E_DarkRoom", room = "L2_DarkRoom_227", side = "E", at = 98, lockable = true, critical = false },
})
chaseRun("L2_Chase_F", {
	{ id = "L2_Grate_F_Corridor", room = "L2_Corridor_East", side = "N", lockable = false, critical = false },
	{ id = "L2_Grate_F_SouthHall", room = "L2_SouthHall", side = "S", lockable = true, critical = false },
	{ id = "L2_Grate_F_Physics", room = "L2_PhysicsLab_229", side = "W", at = 104, lockable = true, critical = false },
	{ id = "L2_Grate_F_Lab231", room = "L2_ChemLab_231", side = "E", at = 96, lockable = true, critical = false },
})
chaseRun("L2_Chase_G", {
	{ id = "L2_Grate_G_NorthHall", room = "L2_NorthHall", side = "S", lockable = false, critical = false },
	{ id = "L2_Grate_G_StaffRoom", room = "L2_StaffRoom", side = "W", at = 13, lockable = true, critical = false },
	{ id = "L2_Grate_G_ChemStore", room = "L2_ChemStore_243", side = "E", at = 18, lockable = true, critical = false },
})
chaseRun("L2_Chase_H", {
	{ id = "L2_Grate_H_SouthHall", room = "L2_SouthHall", side = "N", lockable = false, critical = false },
	{ id = "L2_Grate_H_Restroom", room = "L2_Restroom_South", side = "W", at = 147, lockable = true, critical = false },
	{ id = "L2_Grate_H_Botany", room = "L2_BotanyRoom_247", side = "E", at = 150, lockable = true, critical = false },
})

--------------------------------------------------------------------------------
-- Lights: dead tubes, a fume-hood alarm still pulsing, a dying grow lamp.
--------------------------------------------------------------------------------

lightGrid("L2_NorthHall", "Fluorescent", 16, 1, "xxxxxxxfxxxxxxxx", { flicker = "L2_NorthHall", brightness = 0.35 })
lightGrid("L2_SouthHall", "Fluorescent", 16, 1, "xxxxxxxxxxxfxxxx", { flicker = "L2_SouthHall", brightness = 0.35 })
lightGrid("L2_Corridor_West", "Fluorescent", 9, 1, "x")
lightGrid("L2_Corridor_East", "Fluorescent", 9, 1, "xxxxfxxxx", { flicker = "L2_CorridorEast", brightness = 0.3 })
for _, id in { "L2_CrossHall_NW", "L2_CrossHall_NE", "L2_CrossHall_SW", "L2_CrossHall_SE" } :: { string } do
	lightGrid(id, "Fluorescent", 1, 3, "x")
end
for _, id in
	{
		"L2_ChemLab_201",
		"L2_ChemLab_203",
		"L2_BioLab_209",
		"L2_BioLab_211",
		"L2_BioLab_221",
		"L2_BioLab_223",
		"L2_PhysicsLab_229",
		"L2_ChemLab_231",
		"L2_Classroom_245",
		"L2_Classroom_249",
	} :: { string }
do
	lightGrid(id, "Fluorescent", 2, 3, "x")
end
for _, id in
	{
		"L2_ChemPrep_205",
		"L2_BioPrep_207",
		"L2_SpecimenStore_225",
		"L2_Classroom_241",
		"L2_Classroom_251",
		"L2_StaffRoom",
		"L2_HeadOfScience",
		"L2_Restroom_North",
		"L2_Restroom_South",
	} :: { string }
do
	lightGrid(id, "Fluorescent", 1, 2, "x")
end
lightGrid("L2_ScienceLibrary", "Fluorescent", 4, 2, "x")
lightGrid("L2_LectureHall", "Fluorescent", 4, 2, "xxxxxfxx", { flicker = "L2_Lecture", brightness = 0.3 })
lightGrid("L2_BotanyRoom_247", "Bulb", 3, 2, "xxxxfx", {
	flicker = "L2_GrowLamp",
	brightness = 0.35,
	range = 16,
	color = Color3.fromRGB(196, 120, 255),
})
for _, id in
	{
		"L2_Storage_201A",
		"L2_Storage_211A",
		"L2_Storage_221A",
		"L2_Storage_231A",
		"L2_EquipmentStore",
		"L2_ChemStore_243",
		"L2_DarkRoom_227",
	} :: { string }
do
	lightGrid(id, "Bulb", 1, 1, "x")
end
light("L2_ChemLab_203", "EmergencyRed", 77, HEIGHT - 1, 46, { flicker = "L2_FumeAlarm", brightness = 0.4 })
light(
	"L2_DarkRoom_227",
	"EmergencyRed",
	131,
	HEIGHT - 1.5,
	112,
	{ flicker = "L2_Safelight", brightness = 0.2, range = 12 }
)
light("L2_AirlockWest", "EmergencyRed", 6, HEIGHT - 1, 80, { flicker = "L2_AirlockWest", brightness = 0.35 })
light("L2_AirlockEast", "EmergencyRed", 234, HEIGHT - 1, 80, { flicker = "L2_AirlockEast", brightness = 0.35 })
light("L2_Corridor_West", "ExitSign", 13.5, 11, 80)
light("L2_Corridor_East", "ExitSign", 226.5, 11, 80)

--------------------------------------------------------------------------------
-- Anchors
--------------------------------------------------------------------------------

-- Arrival from Stairwell_1_2
scatter("PlayerSpawn", 3.5, { { 4, 74, FACE_E }, { 8, 74, FACE_E }, { 4, 86, FACE_E }, { 8, 86, FACE_E } })
anchor("CreatureSpawn", 180, 5, 104, FACE_N, "L2_CreatureSpawn")

-- Lab islands and the flasks left on them
labIslands("L2_ChemLab_201", 2, 2, { 2.5 })
labIslands("L2_ChemLab_203", 2, 2, { -2.5 })
labIslands("L2_ChemLab_231", 1, 2, { 3 })
labIslands("L2_ChemPrep_205", 1, 1, { -2.5, 2.5 })
labIslands("L2_ChemStore_243", 1, 2, { -3, 3 })
labIslands("L2_BioPrep_207", 1, 1, { 0 })
labIslands("L2_BioLab_209", 2, 2, { 3 })
labIslands("L2_BioLab_211", 1, 2, { -3 })
labIslands("L2_BioLab_221", 2, 2, { -3 })
labIslands("L2_BioLab_223", 2, 2, { 3 })
labIslands("L2_PhysicsLab_229", 2, 2, {})

scatter("BatteryCandidate", 0, {
	{ 6, 50 },
	{ 128, 6 },
	{ 234, 6 },
	{ 100, 4 },
	{ 236, 156 },
	{ 145, 116 },
	{ 234, 116 },
	{ 4, 4 },
	{ 6, 156 },
})

scatter("Corpse", 0, { { 70, 70, 30 }, { 190, 84, -110 }, { 40, 152, 75 } })
scatter("DripPipe", HEIGHT - 1.2, { { 40, 78 }, { 196, 82 }, { 140, 30 }, { 100, 46 } })
scatter("Clutter", 0, {
	{ 16, 70, 10 },
	{ 60, 46, -40 },
	{ 110, 46, 85 },
	{ 140, 64, 0 },
	{ 194, 68, 30 },
	{ 222, 44, -15 },
	{ 30, 92, 60 },
	{ 76, 116, 0 },
	{ 110, 112, 45 },
	{ 135, 92, -60 },
	{ 192, 116, 15 },
	{ 222, 110, 90 },
	{ 80, 12, 0 },
	{ 30, 150, 20 },
	{ 120, 150, -30 },
	{ 168, 22, 10 },
})

patrol("NW", { { 28, 80 }, { 28, 70 }, { 20, 44 }, { 20, 33 }, { 88, 33 }, { 88, 56 }, { 88, 80 } })
patrol("NE", { { 180, 80 }, { 180, 70 }, { 172, 44 }, { 172, 33 }, { 157, 33 }, { 157, 56 }, { 157, 80 } })
patrol("NX", { { 214, 80 }, { 214, 70 }, { 220, 44 }, { 220, 33 }, { 172, 35 }, { 172, 45 }, { 180, 69 }, { 180, 78 } })
patrol("SW", { { 28, 84 }, { 28, 90 }, { 20, 116 }, { 20, 127 }, { 88, 127 }, { 88, 104 }, { 88, 84 } })
patrol("SE", { { 180, 84 }, { 180, 90 }, { 172, 116 }, { 172, 127 }, { 157, 127 }, { 157, 104 }, { 157, 84 } })
patrol("PR", { { 108, 80 }, { 108, 70 }, { 98, 64 }, { 88, 64 }, { 88, 76 } })
patrol("NH", { { 10, 33 }, { 120, 33 }, { 230, 33 }, { 175, 35 }, { 60, 35 } })
patrol("SH", { { 10, 127 }, { 120, 127 }, { 230, 127 }, { 175, 125 }, { 60, 125 } })
patrol("LH", { { 16, 127 }, { 16, 140 }, { 48, 140 }, { 48, 127 } })

--------------------------------------------------------------------------------
-- Triggers
--------------------------------------------------------------------------------

trigger("L2_Trigger_GlassCorridor", "FloorDebris", 170, 75, 6, 10, 4)
trigger("L2_Trigger_GlassLab203", "FloorDebris", 60, 66, 8, 5, 4)
trigger("L2_Trigger_DebrisNorthHall", "FloorDebris", 100, 28, 6, 10, 4)
trigger("L2_Trigger_DebrisSouthHall", "FloorDebris", 140, 122, 6, 10, 4)
trigger("L2_Trigger_Checkpoint", "Checkpoint", 229, 67, 10, 26, 10)

--------------------------------------------------------------------------------
-- Boarded windows on the facade
--------------------------------------------------------------------------------

windowRow("L2_Classroom_241", "N", 2, 7, 6, 3.5, true)
windowRow("L2_Restroom_North", "N", 1, 4, 3, 7, true)
windowRow("L2_ScienceLibrary", "N", 4, 7, 6, 3.5, true)
windowRow("L2_StaffRoom", "N", 2, 7, 6, 3.5, true)
windowRow("L2_ChemStore_243", "N", 2, 4, 3, 7, true)
windowRow("L2_Classroom_245", "N", 2, 7, 6, 3.5, true)
windowRow("L2_HeadOfScience", "N", 2, 7, 6, 3.5, true)
windowRow("L2_LectureHall", "S", 4, 7, 6, 3.5, true)
windowRow("L2_Restroom_South", "S", 1, 4, 3, 7, true)
windowRow("L2_BotanyRoom_247", "S", 4, 9, 8, 2.5, true)
windowRow("L2_Classroom_249", "S", 2, 7, 6, 3.5, true)
windowRow("L2_Classroom_251", "S", 2, 7, 6, 3.5, true)
windowRow("L2_EquipmentStore", "S", 2, 4, 3, 7, true)
windowRow("L2_Classroom_241", "W", 1, 7, 6, 3.5, true)
windowRow("L2_NorthHall", "W", 1, 6, 6, 3.5, true)
windowRow("L2_Storage_201A", "W", 1, 4, 4, 5, true)
windowRow("L2_Storage_221A", "W", 1, 4, 4, 5, true)
windowRow("L2_SouthHall", "W", 1, 6, 6, 3.5, true)
windowRow("L2_LectureHall", "W", 1, 7, 6, 3.5, true)
windowRow("L2_HeadOfScience", "E", 1, 7, 6, 3.5, true)
windowRow("L2_NorthHall", "E", 1, 6, 6, 3.5, true)
windowRow("L2_Storage_211A", "E", 1, 4, 4, 5, true)
windowRow("L2_Storage_231A", "E", 1, 4, 4, 5, true)
windowRow("L2_SouthHall", "E", 1, 6, 6, 3.5, true)
windowRow("L2_EquipmentStore", "E", 1, 4, 3, 7, true)

--------------------------------------------------------------------------------

local layout: LayoutSchema.LevelLayout = {
	id = "Level2_ScienceHall",
	height = HEIGHT,
	acoustic = "Corridor",
	ambience = "DroneScience",
	entry = "L2_AirlockWest",
	exit = "L2_AirlockEast",
	rooms = rooms,
	doors = doors,
	vents = { nodes = ventNodes, edges = ventEdges, grates = grates },
	anchors = anchors,
	triggers = triggers,
	windows = windows,
}

deepFreeze(layout)

return layout
