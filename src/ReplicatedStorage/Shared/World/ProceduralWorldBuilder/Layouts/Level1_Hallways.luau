--!strict
-- Level 1 · the street-level hallways, turned into a maze by collapses, barricades and service corridors. The squad
-- climbs out of the basement into one of the three east stair vestibules (the run's route picks which) and must cross
-- to one of the three west ones, whose fire doors the janitor's master keys unlock.
--
-- The near side (east of the gate, x 290..400): the middle vestibule opens straight onto a short stretch of the old
-- checkerboard hallway (L1_Corridor_East, lockers smashed along its walls); the north and south vestibules come in
-- through the service corridors behind the locker banks and join it at its east end. Every way west runs down that
-- hallway, past Classroom 108: its door stands ajar, a pale glow spills from it onto broken glass (ScareStep
-- L1_Trigger_GlassStep), and the Creature crouches in the room's north-west corner facing the wall, so a squad walking
-- west sees it diagonally through the doorway from the glass. Then the scare, and the HallwayGate at the hallway's
-- west end slams shut: it seals east from west (the gate line x = 290 is a barrier the tunnels never cross, and no
-- crawlway cuts it). The only way on is the wall vent beside it (L1_Chase_Gate: two grates that never lock, one on
-- each side of the gate), a classic vent both runtimes support.
--
-- The far side (west of the gate) is TunnelPlanner's (seed below): the collapsed school folded into five lanes
-- walked in turn, then the exit corridor along the west wall:
--   the hub       (x 230..290, z 0..180) Offices & Records: from the gate's west hall north to lane N1
--   lane N1       (z 0..64)   Offices & Records, then Library Stacks: west, past the main office
--   lane N2       (z 64..112) Library Stacks: back east (N1 turns into it at its west end, x < 70)
--   lane M        (z 112..180) Collapsed Main Hall: west again (N2 turns into it at its east end, x 200..230)
--   lane S1       (z 180..227) Kitchen Service: east (M turns into it at its west end)
--   lane S2       (z 227..288) Kitchen Service: west, past the janitor's closet (S1 turns into it at its east end)
--   the exit run  (x 0..44)   Kitchen Service in the south, Library Stacks in the north: S2 joins it at its south end,
--                             and it runs north past the three stair vestibules (south z 260, middle 144, north 28)
-- Crawlways cut the lanes' barriers (shortcuts for whoever dares to crawl), so a culvert the Creature cannot enter is
-- never more than 60 studs' walk away. The master keys hang on a nail in one of twelve places past the gate: the
-- janitor's closet, the main office, and hooks in niches all over the far side.
--
-- Anchor heights: props rest on the floor (y = 0) or on a shelf (its top); the keys' nails are 4.6 up the wall;
-- DripPipe sits under the ceiling; PlayerSpawn is at HumanoidRootPart height plus clearance (3.5) and Creature
-- placements at the rig's root height (5). Yaw is degrees about +Y: 0 faces north (-Z), 90 west, 180 south, -90 east.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local TunnelPlanner = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.TunnelPlanner)
local TunnelRules = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.TunnelRules)

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
	cage: boolean?,
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
-- TunnelPlanner draws from Rng (the same plan in Lune and on Roblox); this seed, the first tried, passes every rule
-- and spec
local SEED = 20261104
local HEIGHT = WorldConfig.Levels.Level1_Hallways.height

local FACE_N, FACE_W, FACE_S, FACE_E = 0, 90, 180, -90

-- The stair vestibules and the tunnels their fire doors open onto stand tall enough for the door's KEEP CLOSED sign
-- over its head casing (DoorBuilder: about 11.7 studs up).
local VESTIBULE_HEIGHT = 13
local FIRE_DOOR_CLEARANCE = 12.6

-- The gate line: everything east of it is the near side (the scare), everything west the far side (the keys).
local GATE_X = 290
-- The checkerboard hallway's centre line (the middle stair tower's opening)
local HALL_Z = WorldConfig.Towers.East.openingZ

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
local OFFICE: Style =
	{ floor = "Carpet", wall = "PlasterSchool", ceiling = "PlasterSchool", surface = "Carpet", acoustic = "Room" }
local STORAGE: Style =
	{ floor = "ConcreteStained", wall = "ConcreteDark", ceiling = "Concrete", surface = "Concrete", acoustic = "Room" }
local AIRLOCK: Style =
	{ floor = "Concrete", wall = "ConcreteDark", ceiling = "Concrete", surface = "Concrete", acoustic = "Stairwell" }
local CHASE: Style =
	{ floor = "ConcreteDark", wall = "ConcreteDark", ceiling = "ConcreteDark", surface = "Metal", acoustic = "Vent" }

local rgb = Color3.fromRGB

--------------------------------------------------------------------------------
-- Blueprint helpers
--------------------------------------------------------------------------------

local rooms: { Room } = {}
local roomById: { [string]: Room } = {}
local doors: { LayoutSchema.Door } = {}
local anchors: { LayoutSchema.Anchor } = {}
local anchorCounts: { [string]: number } = {}
local triggers: { LayoutSchema.Trigger } = {}
local platforms: { LayoutSchema.Platform } = {}
local windows: { LayoutSchema.Window } = {}
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

-- The walkable room holding (x, z) at least 0.05 studs inside its walls (never solid ground or a chase).
local function roomAt(x: number, z: number): string
	for _, candidate in rooms do
		if
			candidate.kind ~= "Solid"
			and candidate.kind ~= "Chase"
			and LayoutSchema.rectContains(candidate.rect, x, z, 0.05)
		then
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
			cage = o.cage,
		})
	end
end

local function door(kind: Enums.DoorKind, a: string, b: string, at: number, options: DoorOptions?)
	local o: DoorOptions = options or {}
	getRoom(a)
	getRoom(b)
	table.insert(doors, {
		id = o.id or string.format("%s_Door_%02d", PREFIX, #doors + 1),
		kind = kind,
		rooms = { a, b },
		at = at,
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

-- Evenly spaced boarded windows on one facade side of a room; any that would face a stair tower are left out.
local function windowRow(
	roomId: string,
	side: LayoutSchema.Side,
	count: number,
	width: number,
	height: number,
	sill: number
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
				{ room = roomId, side = side, at = at, width = width, height = height, sill = sill, boarded = true }
			)
		end
	end
end

-- One straight duct along the middle of a chase, a junction under every side grate, end grates as terminals.
-- A duct never leaves its chase, so each chase room carries exactly one run.
local function chaseRun(chaseId: string, plans: { GratePlan })
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
		table.insert(ventEdges, { a = stops[i].node, b = stops[i + 1].node })
	end
	for _, stub in stubs do
		table.insert(ventEdges, { a = stub[1], b = stub[2] })
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
-- Keep-rooms (the rooms the game needs; the planner tunnels around them)
--------------------------------------------------------------------------------

local keep: { TunnelPlanner.KeepRoom } = {}
local function keepRoom(r: Room, ports: { TunnelPlanner.Port }, region: string?, sign: string?)
	table.insert(keep, { room = r, ports = ports, region = region, sign = sign })
end

-- The near side: the three stair vestibules the squad climbs into (route candidates of Stairwell_0_1*), the
-- checkerboard hallway the middle one opens onto, and the scare classroom off the hallway's north side
local hallEast = room("L1_Corridor_East", "Corridor", GATE_X, HALL_Z - 7, 386 - GATE_X, 14, CORRIDOR)
keepRoom(hallEast, {
	{ side = "N", at = 370, kind = "Doorway", width = 8, id = "L1_Door_HallNorth" },
	{ side = "S", at = 370, kind = "Doorway", width = 8, id = "L1_Door_HallSouth" },
}, "Lockers")
keepRoom(room("L1_AirlockEast", "Airlock", 386, HALL_Z - 12, 14, 24, AIRLOCK, VESTIBULE_HEIGHT), {}, "Lockers")
for _, v in
	{
		{ "L1_AirlockNorthEast", WorldConfig.Towers.NorthEast.openingZ, "L1_Door_AirlockNorthEast" },
		{ "L1_AirlockSouthEast", WorldConfig.Towers.SouthEast.openingZ, "L1_Door_AirlockSouthEast" },
	} :: { { any } }
do
	keepRoom(
		room(v[1], "Airlock", 386, v[2] - 12, 14, 24, AIRLOCK, VESTIBULE_HEIGHT),
		{ { side = "W", at = v[2], kind = "Airlock", id = v[3], runHeight = FIRE_DOOR_CLEARANCE } },
		"Lockers"
	)
end
-- Classroom 108: the ajar door sits 14 studs along its south wall, the glass spans the hallway outside it, the
-- Creature crouches 3.5 studs out of its north-west corner (the old plan's sightlines, moved here whole)
local CLASS_X, CLASS_Z = 318, HALL_Z - 7 - 33
keepRoom(room("L1_Classroom_108", "Classroom", CLASS_X, CLASS_Z, 28, 33, CLASSROOM), {}, "Lockers", "108")

-- The far side: the gate's west hall (a short stretch of the old hallway past the gate, its west end caved in to a
-- rubble passage), the main office and the janitor's closet, and the three exit vestibules on the west wall
local hallWest = room("L1_Corridor_West", "Corridor", 262, HALL_Z - 7, GATE_X - 262, 14, CORRIDOR)
keepRoom(hallWest, { { side = "W", at = HALL_Z, kind = "Doorway", width = 8, id = "L1_Door_HallWest" } }, "Offices")
keepRoom(
	room("L1_MainOffice", "Office", 136, 0, 40, 18, OFFICE, 12),
	{ { side = "S", at = 160, kind = "Door", id = "L1_Door_MainOffice" } },
	"Offices",
	"MAIN OFFICE"
)
keepRoom(
	room("L1_JanitorCloset", "Storage", 98, 270, 20, 18, STORAGE, 11.5),
	{ { side = "N", at = 108, kind = "Door", id = "L1_Door_JanitorCloset" } },
	"Kitchen",
	"JANITOR"
)
for _, v in
	{
		{ "L1_AirlockNorthWest", WorldConfig.Towers.NorthWest.openingZ, "L1_Door_AirlockNorthWest" },
		{ "L1_AirlockWest", WorldConfig.Towers.West.openingZ, "L1_Door_AirlockWest" },
		{ "L1_AirlockSouthWest", WorldConfig.Towers.SouthWest.openingZ, "L1_Door_AirlockSouthWest" },
	} :: { { any } }
do
	-- (no stencil: the fire door's STAIRS sign is SignageBuilder's, beside it on the tunnel side)
	keepRoom(
		room(v[1], "Airlock", 0, v[2] - 12, 14, 24, AIRLOCK, VESTIBULE_HEIGHT),
		{ { side = "E", at = v[2], kind = "Airlock", id = v[3], runHeight = FIRE_DOOR_CLEARANCE } }
	)
end

-- The gate's bypass vent: a service chase in the hallway's north wall, straddling the gate
local chase = room("L1_Chase_Gate", "Chase", GATE_X - 16, HALL_Z - 12, 32, 5, CHASE)

--------------------------------------------------------------------------------
-- The tunnels
--------------------------------------------------------------------------------

local plan = TunnelPlanner.plan({
	levelId = "Level1_Hallways",
	prefix = PREFIX,
	seed = SEED,
	height = HEIGHT,
	keepRooms = keep,
	entry = "L1_AirlockEast",
	exits = { "L1_AirlockNorthWest", "L1_AirlockWest", "L1_AirlockSouthWest" },
	exclusions = { chase.rect },
	links = {
		-- the middle vestibule opens straight onto the hallway; the gate joins the hallway's two halves
		{ a = "L1_AirlockEast", b = "L1_Corridor_East" },
		{ a = "L1_Corridor_East", b = "L1_Corridor_West" },
	},
	barriers = {
		-- the gate line: nothing but the hallway (and its vent) crosses it
		{ x0 = GATE_X, z0 = 0, x1 = GATE_X, z1 = 288 },
		-- the far side's lanes: N1 | N2 (open at the west end), N2 | M (open at the east end), M | S1 (open at the west
		-- end), S1 | S2 (open at the east end); the hub's west wall; the exit run's east wall (open at the south)
		{ x0 = 70, z0 = 64, x1 = 230, z1 = 64 },
		{ x0 = 44, z0 = 114, x1 = 200, z1 = 114 },
		{ x0 = 70, z0 = 180, x1 = GATE_X, z1 = 180 },
		{ x0 = 44, z0 = 223, x1 = 258, z1 = 223 },
		{ x0 = 230, z0 = 64, x1 = 230, z1 = 180 },
		{ x0 = 44, z0 = 0, x1 = 44, z1 = 230 },
		-- collapses and barricades across one row of a lane at a time: the walk zigzags between the rows
		{ x0 = 121, z0 = 0, x1 = 121, z1 = 40 },
		{ x0 = 230, z0 = 40, x1 = 230, z1 = 64 },
		{ x0 = 95, z0 = 64, x1 = 95, z1 = 91 },
		{ x0 = 147, z0 = 91, x1 = 147, z1 = 114 },
		{ x0 = 121, z0 = 114, x1 = 121, z1 = 156 },
		{ x0 = 173, z0 = 134, x1 = 173, z1 = 180 },
		{ x0 = 95, z0 = 180, x1 = 95, z1 = 200 },
		{ x0 = 199, z0 = 200, x1 = 199, z1 = 223 },
	},
	gridX = { 30, 54, 82, 108, 134, 160, 186, 214, 246, 272, 322, 346, 370 },
	gridZ = { 28, 52, 78, 104, 124, 144, 168, 190, 210, 236, 260 },
	crawlSites = {
		-- across the lanes' barriers (shortcuts), two or three per barrier
		{ 134, 52, 134, 78 },
		{ 214, 52, 214, 78 },
		{ 82, 104, 82, 124 },
		{ 186, 104, 186, 124 },
		{ 134, 168, 134, 190 },
		{ 214, 168, 214, 190 },
		{ 82, 210, 82, 236 },
		{ 160, 210, 160, 236 },
		{ 246, 210, 246, 236 },
		-- into the exit run, and the hub's south end
		{ 30, 52, 54, 52 },
		{ 30, 144, 54, 144 },
		{ 30, 236, 54, 236 },
		{ 246, 124, 272, 124 },
		{ 246, 52, 272, 52 },
		-- the near side's service corridors
		{ 346, 52, 370, 52 },
		{ 346, 78, 370, 78 },
		{ 346, 190, 370, 190 },
		{ 346, 236, 370, 236 },
	},
	style = {
		width = { 7, 8, 8, 9 },
		height = { 11, 12 },
		galleryWidth = 10,
		galleryHeight = { 13, 13.5 },
		galleryShare = 0.2,
		galleryMin = 40,
		pitch = 26,
		jitter = 3,
		length = 4000,
		deadEnds = 6,
		crawlWidth = 4,
		crawlAcrossBarriers = true,
		crawlMouthsPass = true,
		alcoveWidth = 5,
		alcoveDepth = 6,
		alcoveHeight = 10,
		lightSpacing = { 9, 12 },
		deadShare = 0.3,
		flickerShare = 0.12,
		plateLampEvery = 2,
		wall = "PlasterGreen",
		floor = "Linoleum",
		ceiling = "PlasterSchool",
		acoustic = "Corridor",
		galleryAcoustic = "Hall",
		crawlAcoustic = "Vent",
	},
	rules = {
		maxLoop = 200,
		deadEndCount = 8,
		deadEndLength = 25,
		-- about 2.5-3 minutes at walking pace (11 studs/s)
		crossing = { 1650, 1980 },
		crawlCrossingSeconds = 40,
		crawlways = { 3, 18 },
		crawlLength = 20,
		crawlHeight = TunnelRules.CrawlClearance,
		crawlReach = 60,
		hideReach = 30,
		objectiveHideReach = 25,
		regions = { 4, 6 },
	},
	regions = {
		{
			id = "Lockers",
			medium = "HEAT",
			name = "Locker Banks",
			x = 340,
			z = 144,
			areas = { { GATE_X, 0, 400, 288 } },
			pipe = rgb(70, 96, 74),
			band = rgb(214, 206, 170),
			grime = rgb(20, 26, 20),
			paint = rgb(232, 228, 210),
			graffiti = { "DON'T GO IN 108", "IT WATCHES THE GLASS", "WALK SOFT", "LOCKERS ARE EMPTY" },
			wall = "PlasterGreen",
			floor = "Linoleum",
			-- the locker banks: their niches hold hideable lockers
			hides = { "Locker" },
		},
		{
			id = "Offices",
			medium = "PHONE",
			name = "Offices & Records",
			x = 250,
			z = 60,
			areas = { { 230, 0, GATE_X, 180 }, { 160, 0, 230, 64 } },
			pipe = rgb(126, 102, 70),
			band = rgb(40, 34, 28),
			grime = rgb(30, 26, 20),
			paint = rgb(224, 60, 48),
			graffiti = { "KEYS ON A NAIL", "OFFICE IS NORTH", "SIGN OUT", "NO HALL PASS" },
			wall = "PlasterSchool",
			floor = "Carpet",
		},
		{
			id = "Library",
			medium = "DATA",
			name = "Library Stacks",
			x = 120,
			z = 80,
			areas = { { 44, 0, 160, 64 }, { 44, 64, 230, 112 } },
			pipe = rgb(96, 60, 92),
			band = rgb(220, 200, 160),
			grime = rgb(24, 18, 14),
			paint = rgb(236, 230, 200),
			graffiti = { "QUIET", "HE HEARS THE PAGES", "OVERDUE", "SHH" },
			wall = "WoodPanel",
			floor = "Carpet",
		},
		{
			id = "MainHall",
			medium = "WATER",
			name = "Collapsed Main Hall",
			x = 130,
			z = 146,
			areas = { { 44, 112, 230, 180 } },
			pipe = rgb(40, 70, 118),
			band = rgb(226, 226, 220),
			grime = rgb(22, 22, 24),
			paint = rgb(240, 236, 220),
			graffiti = { "THE ROOF CAME DOWN", "DON'T LOOK UP", "IT CAME THROUGH HERE", "CLIMB" },
			wall = "Brick",
			floor = "ConcreteStained",
			wet = true,
		},
		{
			id = "Kitchen",
			medium = "GAS",
			name = "Kitchen Service",
			x = 160,
			z = 240,
			areas = { { 44, 180, GATE_X, 288 }, { 0, 0, 44, 288 } },
			pipe = rgb(176, 136, 24),
			band = rgb(30, 28, 24),
			grime = rgb(34, 30, 16),
			paint = rgb(232, 70, 48),
			graffiti = { "LUNCH IS CANCELLED", "NO FLAME", "STAIRS WEST", "ALMOST OUT" },
			wall = "TileGreen",
			floor = "TileWhite",
		},
	},
	attempts = 6,
	crossingTarget = 1780,
	items = {
		{
			kind = "MasterKeyCandidate" :: Enums.AnchorKind,
			count = 10,
			shelf = 4.6,
			wall = true,
			areas = { { 0, 0, GATE_X - 8, 288 } },
		},
	},
	hideTargets = {
		Vector3.new(16, 0, WorldConfig.Towers.NorthWest.openingZ),
		Vector3.new(16, 0, WorldConfig.Towers.West.openingZ),
		Vector3.new(16, 0, WorldConfig.Towers.SouthWest.openingZ),
		Vector3.new(264, 0, HALL_Z),
	},
	traps = 0,
	batteries = 10,
	clutter = 22,
	corpses = 5,
	drips = 9,
	debris = 8,
	scares = 0,
	creatureSpawns = 6,
	creatureBand = { 70, 140 },
	otherEntries = { "L1_AirlockNorthEast", "L1_AirlockSouthEast" },
})

for _, r in plan.rooms do
	table.insert(rooms, r)
	roomById[r.id] = r
end
for _, d in plan.doors do
	table.insert(doors, d)
end
for _, a in plan.anchors do
	table.insert(anchors, a)
end
for _, t in plan.triggers do
	table.insert(triggers, t)
end
for _, p in plan.platforms do
	table.insert(platforms, p)
end

--------------------------------------------------------------------------------
-- The hallway's own doors: the middle vestibule's fire door, the ajar classroom door, the gate
--------------------------------------------------------------------------------

door("Airlock", "L1_AirlockEast", "L1_Corridor_East", HALL_Z, { id = "L1_Door_AirlockEast" })
door(
	"Ajar",
	"L1_Corridor_East",
	"L1_Classroom_108",
	CLASS_X + 14,
	{ id = "L1_Door_Classroom108", scriptedId = "ClassroomDoor" }
)
door(
	"Gate",
	"L1_Corridor_East",
	"L1_Corridor_West",
	HALL_Z,
	{ id = "L1_Door_HallwayGate", width = 12, scriptedId = "HallwayGate" }
)

-- The bypass vent: a grate into the hallway ten studs east of the gate and one into the west hall ten studs west of
-- it, the duct between them in the wall. Neither ever locks (the critical path); the director has nothing here to
-- lock.
chaseRun("L1_Chase_Gate", {
	{
		id = "L1_Grate_CorridorEast",
		room = "L1_Corridor_East",
		side = "S",
		at = GATE_X + 10,
		lockable = false,
		critical = true,
	},
	{
		id = "L1_Grate_CorridorWest",
		room = "L1_Corridor_West",
		side = "S",
		at = GATE_X - 10,
		lockable = false,
		critical = true,
	},
})

--------------------------------------------------------------------------------
-- Keep-room furniture: the office counter, the janitor's shelving
--------------------------------------------------------------------------------

platform("L1_Shelf_Janitor", "L1_JanitorCloset", 99, 284.6, 12, 2.4, 4.2, 4.2, "MetalRust")
platform("L1_Counter_Office", "L1_MainOffice", 140, 10, 14, 2.6, 3.4, 3.4, "WoodPanel")

--------------------------------------------------------------------------------
-- Lights: the hallway dark but for the classroom's glow (LightingMood keeps it so), keep-rooms on their own mains,
-- the vestibules' emergency reds
--------------------------------------------------------------------------------

-- every keep-room is its own steady mains circuit (a local group: a flicker, the Creature's teleport warning, touches
-- only that room)
local function mains(roomId: string): string
	return "Mains:" .. roomId
end

-- The hallway's dead tubes (LightingMood keeps them dark for the scare) and an exit sign at each end
for i = 1, 6 do
	local x = GATE_X + (386 - GATE_X) * (i - 0.5) / 6
	light(
		"L1_Corridor_East",
		"Fluorescent",
		x,
		HEIGHT - 0.4,
		HALL_Z,
		{ flicker = mains("L1_Corridor_East"), broken = true }
	)
end
light("L1_Corridor_East", "ExitSign", 384.5, 11, HALL_Z)
light("L1_Corridor_West", "Fluorescent", 276, HEIGHT - 0.4, HALL_Z, { flicker = mains("L1_Corridor_West") })
light("L1_Corridor_West", "EmergencyRed", 264, HEIGHT - 1.5, HALL_Z + 6.4, { brightness = 0.35 })

-- The pale glow from the ajar classroom (the scare bursts every ClassroomGlow in L1_Classroom_108 when the Creature
-- turns): the room light over the Creature's corner, and a narrow spill fixture just inside the ajar door whose
-- downward cone leaves the room under the door lintel and lays a pale pool on the hallway floor. Both cast shadows,
-- so the glow reaches the hallway only through the doorway.
light("L1_Classroom_108", "ClassroomGlow", CLASS_X + 12, HEIGHT - 1.5, CLASS_Z + 12, { id = "L1_Light_ClassroomGlow" })
light(
	"L1_Classroom_108",
	"ClassroomGlow",
	CLASS_X + 14,
	HEIGHT - 1.5,
	CLASS_Z + 30,
	{ id = "L1_Light_ClassroomGlowSpill", brightness = 0.6, range = 18 }
)
for i, p in { { 8, 24 }, { 20, 24 } } do
	light(
		"L1_Classroom_108",
		"Fluorescent",
		CLASS_X + p[1],
		HEIGHT - 0.4,
		CLASS_Z + p[2],
		{ flicker = mains("L1_Classroom_108"), broken = i == 1 }
	)
end

light("L1_MainOffice", "Fluorescent", 148, 11.6, 9, { flicker = mains("L1_MainOffice") })
light("L1_MainOffice", "Fluorescent", 166, 11.6, 9, { flicker = mains("L1_MainOffice"), broken = true })
light("L1_JanitorCloset", "Bulb", 108, 11.1, 279, { flicker = mains("L1_JanitorCloset"), cage = true })

for _, v in
	{
		{ "L1_AirlockNorthEast", 393, WorldConfig.Towers.NorthEast.openingZ },
		{ "L1_AirlockEast", 393, HALL_Z },
		{ "L1_AirlockSouthEast", 393, WorldConfig.Towers.SouthEast.openingZ },
		{ "L1_AirlockNorthWest", 7, WorldConfig.Towers.NorthWest.openingZ },
		{ "L1_AirlockWest", 7, WorldConfig.Towers.West.openingZ },
		{ "L1_AirlockSouthWest", 7, WorldConfig.Towers.SouthWest.openingZ },
	} :: { { any } }
do
	-- both fixtures fast to the ceiling (buildLight lifts none: a fixture set low hangs in the air)
	light(v[1], "Fluorescent", v[2], VESTIBULE_HEIGHT - 0.4, v[3], { flicker = mains(v[1]), broken = true })
	light(v[1], "EmergencyRed", v[2], VESTIBULE_HEIGHT - 0.4, v[3] - 8, { brightness = 0.3 })
end

--------------------------------------------------------------------------------
-- Keep-room anchors
--------------------------------------------------------------------------------

-- Arrival from Stairwell_0_1 and its corner candidates: four spawns in each east vestibule, facing west
for _, z in
	{
		WorldConfig.Towers.NorthEast.openingZ,
		HALL_Z,
		WorldConfig.Towers.SouthEast.openingZ,
	} :: { number }
do
	for _, p in { { 390, z - 4 }, { 396, z - 4 }, { 390, z + 4 }, { 396, z + 4 } } do
		anchor("PlayerSpawn", p[1], 3.5, p[2], FACE_W)
	end
end

-- The scripted classroom: the Creature hunched in the far (north-west) corner, facing into the corner. From the glass
-- outside the ajar door a westbound squad looks diagonally through the doorway straight at it.
anchor("CreatureScarePose", CLASS_X + 3.5, 5, CLASS_Z + 3.5, 45, "L1_ScarePose_Classroom108")

-- Floor objective (MasterKeys): the janitor's master keys hang on a nail in one of twelve places past the gate (the
-- anchor is the nail on the wall face, facing into the room): two in the janitor's closet, two in the main office,
-- and the planner's ten on hooks in niches all over the far side; hideable lockers in the two rooms keep a hiding
-- spot near every step. The exit locks on the three west stair vestibules' fire doors (the floor point on each door's
-- corridor face, facing out of the door).
local KEY_HOOK_Y = 4.6
anchor("MasterKeyCandidate", 117.5, KEY_HOOK_Y, 279, FACE_W) -- janitor's closet, east wall
anchor("MasterKeyCandidate", 102, KEY_HOOK_Y, 270.5, FACE_S) -- janitor's closet, beside the door
anchor("MasterKeyCandidate", 136.5, KEY_HOOK_Y, 8, FACE_E) -- main office, behind the counter
anchor("MasterKeyCandidate", 175.5, KEY_HOOK_Y, 12, FACE_W) -- main office, the key cabinet's wall
anchor("Locker", 115.95, 0, 284, FACE_W) -- janitor's closet
anchor("Locker", 173.95, 0, 4, FACE_W) -- main office, by the key cabinet
anchor("Locker", 138.05, 0, 14, FACE_E) -- main office, behind the counter
anchor("Locker", 284, 0, HALL_Z + 7 - 2.05, FACE_N) -- the gate's west hall, out of the vent
anchor("ExitLock", 14.5, 0, WorldConfig.Towers.West.openingZ, FACE_E, "L1_ExitLock")
anchor("ExitLock", 14.5, 0, WorldConfig.Towers.NorthWest.openingZ, FACE_E, "L1_ExitLock_North")
anchor("ExitLock", 14.5, 0, WorldConfig.Towers.SouthWest.openingZ, FACE_E, "L1_ExitLock_South")
for i, z in
	{
		WorldConfig.Towers.NorthWest.openingZ,
		WorldConfig.Towers.West.openingZ,
		WorldConfig.Towers.SouthWest.openingZ,
	} :: { number }
do
	-- the stair vestibules: a steel cabinet by the far wall
	anchor("Cabinet", 1.4, 0, z + 9, FACE_E, string.format("%s_Cabinet_Stairs%d", PREFIX, i))
end

-- Smashed locker banks along the hallway walls (clear of its doorways, the vent grate and the glass)
local NORTH_WALL, SOUTH_WALL = HALL_Z - 7 + 1.2, HALL_Z + 7 - 1.2
scatter("SmashedLocker", 0, {
	{ 315, NORTH_WALL, FACE_S },
	{ 350, NORTH_WALL, FACE_S },
	{ 270, NORTH_WALL, FACE_S },
	{ 306, SOUTH_WALL, FACE_N },
	{ 322, SOUTH_WALL, FACE_N },
	{ 346, SOUTH_WALL, FACE_N },
	{ 354, SOUTH_WALL, FACE_N },
	{ 270, SOUTH_WALL, FACE_N },
})

scatter("DripPipe", HEIGHT - 1.2, { { 344, HALL_Z }, { 310, HALL_Z - 3 }, { 276, HALL_Z } })
scatter("Clutter", 0, {
	{ 377, HALL_Z - 4, 20 },
	{ 104, 276, 10 },
	{ 150, 6, -20 },
})
scatter("BatteryCandidate", 0, { { 360, HALL_Z + 5 }, { 112, 284 } })

--------------------------------------------------------------------------------
-- Triggers
--------------------------------------------------------------------------------

-- Broken glass and cans across the full hallway width outside the ajar classroom, over the band of the hallway from
-- which the Creature's corner is in sight through the doorway (x about 11.5..23.5 east of the classroom's west wall
-- at standing eye height).
trigger("L1_Trigger_GlassStep", "ScareStep", CLASS_X + 12, HALL_Z - 7, 10, 14, 4)
trigger("L1_Trigger_DebrisHall", "FloorDebris", 300, HALL_Z - 5, 6, 10, 4)
trigger("L1_Trigger_Checkpoint", "Checkpoint", 1, WorldConfig.Towers.West.openingZ - 11, 12, 22, 11)
trigger("L1_Trigger_CheckpointNorthWest", "Checkpoint", 1, WorldConfig.Towers.NorthWest.openingZ - 11, 12, 22, 11)
trigger("L1_Trigger_CheckpointSouthWest", "Checkpoint", 1, WorldConfig.Towers.SouthWest.openingZ - 11, 12, 22, 11)

--------------------------------------------------------------------------------
-- Boarded windows on the facade
--------------------------------------------------------------------------------

windowRow("L1_MainOffice", "N", 3, 7, 6, 3.5)
windowRow("L1_JanitorCloset", "S", 1, 4, 4, 5)

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
	platforms = platforms,
	windows = windows,
	tunnels = plan.tunnels,
}

deepFreeze(layout)

return layout
