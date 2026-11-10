--!strict
-- Level 2 · the science wing. The squad climbs out of the hallways into one of the three west stair vestibules (the
-- run's route picks which) and must cross to one of the three east ones, whose fire doors are chained shut until the
-- squad burns the chain with acid mixed at the fume hood.
--
-- The labs and stores the objective needs are keep-rooms; TunnelPlanner (seed below) lays the wing's service maze
-- around them: the utility corridors behind the labs, the fume-duct galleries, the cold-storage tunnels. Barrier lines
-- fold the floor into one long walk of north-south lanes, and the two labs are the only way from one band to the next:
--   the prep corridor (x 0..44)    Prep Corridors: the three stair vestibules on the west wall, joined to band A only
--                                  at its middle (z 144)
--   band A  (x 44..150)            Cold Storage: up lane A1 (the specimen store off its south end, a cul-de-sac),
--                                  across its north end, down lane A2 to Chem Lab 203 (the only way on, at the south)
--   band B  (x 150..256)           Fume Ducts: up lane B1 from the lab, the chemical store off its north end, down lane
--                                  B2 to Bio Lab 209 (the only way on); Chem Prep 205 and its fume hood open off the lab
--   band C  (x 256..360)           Utility Corridors: up lane C1, down lane C2
--   the stair corridor (x 360..400) Chem Stores: C2 joins it at its south end, and it runs north past the three stair
--                                  vestibules (south z 260, middle 144, north 28)
-- Crawlways cut the lanes' barriers (shortcuts for whoever dares to crawl), so a culvert the Creature cannot enter is
-- never more than 60 studs' walk away. Fifteen reagent jars wait on lab worktops and in lab-like niches (five of each
-- kind), and the stun flasks on the benches and in tunnel caches.
--
-- Lab islands: each LabCounter anchor is the floor centre of a 10 x 3.5 worktop whose long axis runs along X (the
-- anchor's RightVector), top at WORKTOP; FlaskCandidate and ReagentCandidate anchors stand on those worktops (or on a
-- niche's shelf at the same height). Anchor heights otherwise: props on the floor (y = 0), DripPipe under the
-- ceiling, PlayerSpawn at root height plus clearance (3.5), Creature placements at the rig's root height (5). Yaw:
-- 0 faces north (-Z), 90 west, 180 south, -90 east.

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

local PREFIX = "L2"
-- TunnelPlanner draws from Rng (the same plan in Lune and on Roblox); this seed, the first tried, passes every rule
-- and spec
local SEED = 20261105
local HEIGHT = WorldConfig.Levels.Level2_ScienceHall.height
local WORKTOP = 3.2

local FACE_N, FACE_W, FACE_S, FACE_E = 0, 90, 180, -90

-- The stair vestibules and the tunnels their fire doors open onto stand tall enough for the door's KEEP CLOSED sign
-- over its head casing (DoorBuilder: about 11.7 studs up).
local VESTIBULE_HEIGHT = 13
local FIRE_DOOR_CLEARANCE = 12.6

local LIGHT_DEFAULTS: { [string]: LightDefaults } = {
	Fluorescent = { brightness = 0.55, range = 18, color = Color3.fromRGB(214, 232, 236) },
	Bulb = { brightness = 0.45, range = 14, color = Color3.fromRGB(255, 196, 140) },
	EmergencyRed = { brightness = 0.45, range = 16, color = Color3.fromRGB(255, 34, 18) },
	ClassroomGlow = { brightness = 1.1, range = 34, color = Color3.fromRGB(198, 220, 255) },
	Floodlight = { brightness = 2, range = 60, color = Color3.fromRGB(236, 240, 255) },
	ExitSign = { brightness = 0.3, range = 8, color = Color3.fromRGB(70, 255, 120) },
	BoilerGlow = { brightness = 0.9, range = 16, color = Color3.fromRGB(255, 118, 40) },
}

local CHEM_LAB: Style =
	{ floor = "Lab", wall = "TileGreen", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local BIO_LAB: Style =
	{ floor = "Lab", wall = "TileWhite", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local PREP: Style =
	{ floor = "Lab", wall = "PlasterGreen", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local CHEM_STORE: Style = {
	floor = "ConcreteStained",
	wall = "MetalGalvanized",
	ceiling = "Concrete",
	surface = "Concrete",
	acoustic = "Room",
}
local COLD_STORE: Style =
	{ floor = "TileWhite", wall = "TileWhite", ceiling = "Concrete", surface = "Tile", acoustic = "Room" }
local AIRLOCK: Style =
	{ floor = "Concrete", wall = "ConcreteDark", ceiling = "Concrete", surface = "Concrete", acoustic = "Stairwell" }

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

-- The room holding (x, z) at least 0.05 studs inside its walls (never solid ground).
local function roomAt(x: number, z: number): string
	for _, candidate in rooms do
		if candidate.kind ~= "Solid" and LayoutSchema.rectContains(candidate.rect, x, z, 0.05) then
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

-- A lab island at (x, z) (a 10 x 3.5 worktop along X) with flasks `offsets` studs along it from its centre.
local function island(x: number, z: number, flaskOffsets: { number })
	anchor("LabCounter", x, 0, z, FACE_N)
	for _, offset in flaskOffsets do
		anchor("FlaskCandidate", x + offset, WORKTOP, z)
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

local LAB_Z = 237 -- the labs' doors: the walk crosses each lab along this line

-- The three stair vestibules the squad climbs into (route candidates of Stairwell_1_2*), on the west wall
for _, v in
	{
		{ "L2_AirlockNorthWest", WorldConfig.Towers.NorthWest.openingZ, "L2_Door_AirlockNorthWest" },
		{ "L2_AirlockWest", WorldConfig.Towers.West.openingZ, "L2_Door_AirlockWest" },
		{ "L2_AirlockSouthWest", WorldConfig.Towers.SouthWest.openingZ, "L2_Door_AirlockSouthWest" },
	} :: { { any } }
do
	keepRoom(
		room(v[1], "Airlock", 0, v[2] - 12, 14, 24, AIRLOCK, VESTIBULE_HEIGHT),
		{ { side = "E", at = v[2], kind = "Airlock", id = v[3], runHeight = FIRE_DOOR_CLEARANCE } },
		"Prep"
	)
end
-- Band A: the specimen store off lane A1's south end
keepRoom(
	room("L2_SpecimenStore_225", "Storage", 44, 268, 32, 20, COLD_STORE, 11.5),
	{ { side = "N", at = 56, kind = "Door", id = "L2_Door_SpecimenStore" } },
	"Cold",
	"SPECIMENS"
)
-- The bridges: Chem Lab 203 (band A to band B) and Bio Lab 209 (band B to band C), each straddling its band's wall
keepRoom(room("L2_ChemLab_203", "Lab", 123, LAB_Z - 15, 48, 30, CHEM_LAB), {
	{ side = "W", at = LAB_Z, kind = "Door", id = "L2_Door_ChemLabWest" },
	{ side = "E", at = LAB_Z, kind = "Door", id = "L2_Door_ChemLabEast" },
}, "Cold", "CHEM LAB 203")
keepRoom(room("L2_BioLab_209", "Lab", 227, LAB_Z - 15, 48, 30, BIO_LAB), {
	{ side = "W", at = LAB_Z, kind = "Door", id = "L2_Door_BioLabWest" },
	{ side = "E", at = LAB_Z, kind = "Door", id = "L2_Door_BioLabEast" },
}, "Fume", "BIO LAB 209")
-- Chem Prep 205 opens off Bio Lab 209's north side: the fume hood against its north wall
keepRoom(room("L2_ChemPrep_205", "Lab", 235, LAB_Z - 15 - 26, 32, 26, PREP), {}, "Fume", "CHEM PREP 205")
-- Band B: the chemical store off the north end, where lane B1 turns into lane B2
keepRoom(
	room("L2_ChemStore_243", "Storage", 195, 0, 34, 18, CHEM_STORE, 11.5),
	{ { side = "S", at = 212, kind = "Door", id = "L2_Door_ChemStore" } },
	"Fume",
	"CHEM STORE"
)
-- The three stair vestibules out (route candidates of Stairwell_2_3*), on the east wall
for _, v in
	{
		{ "L2_AirlockNorthEast", WorldConfig.Towers.NorthEast.openingZ, "L2_Door_AirlockNorthEast" },
		{ "L2_AirlockEast", WorldConfig.Towers.East.openingZ, "L2_Door_AirlockEast" },
		{ "L2_AirlockSouthEast", WorldConfig.Towers.SouthEast.openingZ, "L2_Door_AirlockSouthEast" },
	} :: { { any } }
do
	-- (no stencil: the fire door's STAIRS sign is SignageBuilder's, beside it on the tunnel side)
	keepRoom(
		room(v[1], "Airlock", 386, v[2] - 12, 14, 24, AIRLOCK, VESTIBULE_HEIGHT),
		{ { side = "W", at = v[2], kind = "Airlock", id = v[3], runHeight = FIRE_DOOR_CLEARANCE } },
		"Stores"
	)
end

--------------------------------------------------------------------------------
-- The tunnels
--------------------------------------------------------------------------------

local plan = TunnelPlanner.plan({
	levelId = "Level2_ScienceHall",
	prefix = PREFIX,
	seed = SEED,
	height = HEIGHT,
	keepRooms = keep,
	entry = "L2_AirlockWest",
	exits = { "L2_AirlockNorthEast", "L2_AirlockEast", "L2_AirlockSouthEast" },
	barriers = {
		-- the prep corridor joins band A only at its middle
		{ x0 = 44, z0 = 0, x1 = 44, z1 = 112 },
		{ x0 = 44, z0 = 178, x1 = 44, z1 = 288 },
		-- each band's two lanes meet only at its north end; the bands meet only through the labs
		{ x0 = 95, z0 = 40, x1 = 95, z1 = 288 },
		{ x0 = 147, z0 = 0, x1 = 147, z1 = 288 },
		{ x0 = 199, z0 = 40, x1 = 199, z1 = 288 },
		{ x0 = 251, z0 = 0, x1 = 251, z1 = 288 },
		{ x0 = 303, z0 = 40, x1 = 303, z1 = 288 },
		-- the stair corridor: lane C2 joins it only at its south end
		{ x0 = 355, z0 = 0, x1 = 355, z1 = 230 },
	},
	gridX = { 30, 56, 82, 108, 134, 160, 186, 212, 238, 264, 290, 316, 342, 368 },
	gridZ = { 28, 52, 76, 100, 124, 144, 168, 192, 214, LAB_Z, 260 },
	crawlSites = {
		-- across the lanes' and bands' walls (shortcuts)
		{ 82, 52, 108, 52 },
		{ 82, 192, 108, 192 },
		{ 134, 124, 160, 124 },
		{ 186, 52, 212, 52 },
		{ 186, 192, 212, 192 },
		{ 238, 124, 264, 124 },
		{ 290, 52, 316, 52 },
		{ 290, 192, 316, 192 },
		-- the prep corridor and the stair corridor
		{ 30, 52, 56, 52 },
		{ 30, 168, 56, 168 },
		{ 30, 237, 56, 237 },
		{ 342, 52, 368, 52 },
		{ 342, 144, 368, 144 },
		{ 342, 237, 368, 237 },
	},
	style = {
		width = { 6, 7, 7, 8 },
		height = { 10.5, 11 },
		galleryWidth = 9,
		galleryHeight = { 13, 13.5 },
		galleryShare = 0.22,
		galleryMin = 40,
		pitch = 24,
		jitter = 3,
		length = 3400,
		deadEnds = 6,
		crawlWidth = 4,
		crawlAcrossBarriers = true,
		crawlMouthsPass = true,
		alcoveWidth = 5,
		alcoveDepth = 6,
		alcoveHeight = 10,
		lightSpacing = { 8, 11 },
		deadShare = 0.3,
		flickerShare = 0.12,
		plateLampEvery = 2,
		wall = "ConcreteDark",
		floor = "ConcreteStained",
		ceiling = "ConcreteDark",
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
		crawlways = { 3, 16 },
		crawlLength = 20,
		crawlHeight = TunnelRules.CrawlClearance,
		crawlReach = 60,
		hideReach = 30,
		objectiveHideReach = 25,
		regions = { 4, 6 },
	},
	regions = {
		{
			id = "Prep",
			medium = "DI WATER",
			name = "Prep Corridors",
			x = 28,
			z = 144,
			areas = { { 0, 0, 44, 288 } },
			pipe = rgb(64, 120, 96),
			band = rgb(226, 222, 206),
			grime = rgb(18, 24, 20),
			paint = rgb(236, 230, 210),
			graffiti = { "EYES FRONT", "WASH YOUR HANDS", "DON'T BREATHE IT", "3 JARS" },
			wall = "TileGreen",
			floor = "Lab",
		},
		{
			id = "Cold",
			medium = "BRINE",
			name = "Cold Storage",
			x = 96,
			z = 140,
			areas = { { 44, 0, 150, 288 } },
			pipe = rgb(70, 130, 170),
			band = rgb(236, 236, 230),
			grime = rgb(20, 26, 30),
			paint = rgb(240, 238, 228),
			graffiti = { "KEEP IT SHUT", "IT'S COLD IN HERE", "HE WAITS IN THE FROST", "LISTEN" },
			wall = "TileWhite",
			floor = "ConcreteStained",
			wet = true,
		},
		{
			id = "Fume",
			medium = "EXHAUST",
			name = "Fume Ducts",
			x = 203,
			z = 140,
			areas = { { 150, 0, 256, 288 } },
			pipe = rgb(132, 132, 112),
			band = rgb(214, 180, 40),
			grime = rgb(30, 30, 22),
			paint = rgb(232, 70, 48),
			graffiti = { "NO FLAME", "HOOD IS IN PREP", "MIX IT. BURN IT.", "DON'T LOOK AT HIS FACE" },
			wall = "MetalGalvanized",
			floor = "ConcreteDark",
		},
		{
			id = "Utility",
			medium = "STEAM",
			name = "Utility Corridors",
			x = 308,
			z = 140,
			areas = { { 256, 0, 360, 288 } },
			pipe = rgb(140, 36, 28),
			band = rgb(214, 206, 186),
			grime = rgb(40, 18, 12),
			paint = rgb(236, 226, 196),
			graffiti = { "HE HEARS YOU RUN", "WALK. DON'T RUN", "THROW THE FLASKS", "COUNT THE PLATES" },
			wall = "Brick",
			floor = "ConcreteStained",
		},
		{
			id = "Stores",
			medium = "ACID",
			name = "Chem Stores",
			x = 372,
			z = 144,
			areas = { { 360, 0, 400, 288 } },
			pipe = rgb(196, 160, 30),
			band = rgb(30, 28, 24),
			grime = rgb(34, 30, 14),
			paint = rgb(240, 236, 220),
			graffiti = { "BURN THE CHAIN", "ALMOST OUT", "STAIRS EAST", "UP IS OUT" },
			wall = "ConcreteDark",
			floor = "Concrete",
		},
	},
	attempts = 6,
	crossingTarget = 1800,
	items = {
		{ kind = "ReagentCandidate" :: Enums.AnchorKind, count = 5, shelf = WORKTOP },
		{ kind = "FlaskCandidate" :: Enums.AnchorKind, count = 6, shelf = WORKTOP },
	},
	hideTargets = {
		Vector3.new(384, 0, WorldConfig.Towers.NorthEast.openingZ),
		Vector3.new(384, 0, WorldConfig.Towers.East.openingZ),
		Vector3.new(384, 0, WorldConfig.Towers.SouthEast.openingZ),
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
	otherEntries = { "L2_AirlockNorthWest", "L2_AirlockSouthWest" },
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

-- Chem Prep 205's door into Bio Lab 209 (the walk to the hood goes through the lab)
table.insert(doors, {
	id = "L2_Door_ChemPrep",
	kind = "Door",
	rooms = { "L2_BioLab_209", "L2_ChemPrep_205" },
	at = 251,
})

--------------------------------------------------------------------------------
-- Keep-room furniture: the store shelving, the specimen racks
--------------------------------------------------------------------------------

platform("L2_Shelf_ChemStoreA", "L2_ChemStore_243", 196, 1, 14, 2.6, WORKTOP, WORKTOP, "MetalGalvanized")
platform("L2_Shelf_ChemStoreB", "L2_ChemStore_243", 214, 1, 12, 2.6, WORKTOP, WORKTOP, "MetalGalvanized")
platform("L2_Rack_SpecimenA", "L2_SpecimenStore_225", 45, 284.4, 13, 2.6, WORKTOP, WORKTOP, "MetalRust")
platform("L2_Rack_SpecimenB", "L2_SpecimenStore_225", 62, 284.4, 13, 2.6, WORKTOP, WORKTOP, "MetalRust")

--------------------------------------------------------------------------------
-- Lights: the labs and stores on their own mains, a fume alarm still pulsing, a darkroom safelight in the specimen
-- store, the vestibules' emergency reds
--------------------------------------------------------------------------------

-- every keep-room is its own steady mains circuit (a local group: a flicker, the Creature's teleport warning, touches
-- only that room)
local function mains(roomId: string): string
	return "Mains:" .. roomId
end

for i, p in { { 133, 229 }, { 161, 229 }, { 133, 245 }, { 161, 245 } } do
	light(
		"L2_ChemLab_203",
		"Fluorescent",
		p[1],
		HEIGHT - 0.4,
		p[2],
		{ flicker = mains("L2_ChemLab_203"), broken = i % 2 == 0 }
	)
end
for i, p in { { 237, 229 }, { 265, 229 }, { 237, 245 }, { 265, 245 } } do
	light(
		"L2_BioLab_209",
		"Fluorescent",
		p[1],
		HEIGHT - 0.4,
		p[2],
		{ flicker = mains("L2_BioLab_209"), broken = i ~= 2 }
	)
end
light("L2_ChemPrep_205", "Fluorescent", 251, HEIGHT - 0.4, LAB_Z - 28, { flicker = mains("L2_ChemPrep_205") })
light("L2_ChemPrep_205", "EmergencyRed", 261, HEIGHT - 1, LAB_Z - 37.5, { flicker = "L2_FumeAlarm", brightness = 0.4 })
light("L2_ChemStore_243", "Bulb", 212, 11.1, 9, { flicker = mains("L2_ChemStore_243"), cage = true })
light(
	"L2_SpecimenStore_225",
	"Bulb",
	60,
	11.1,
	277,
	{ flicker = mains("L2_SpecimenStore_225"), cage = true, broken = true }
)
light(
	"L2_SpecimenStore_225",
	"EmergencyRed",
	72,
	HEIGHT - 4,
	272,
	{ flicker = "L2_Safelight", brightness = 0.2, range = 12 }
)
for _, v in
	{
		{ "L2_AirlockNorthWest", 7, WorldConfig.Towers.NorthWest.openingZ },
		{ "L2_AirlockWest", 7, WorldConfig.Towers.West.openingZ },
		{ "L2_AirlockSouthWest", 7, WorldConfig.Towers.SouthWest.openingZ },
		{ "L2_AirlockNorthEast", 393, WorldConfig.Towers.NorthEast.openingZ },
		{ "L2_AirlockEast", 393, WorldConfig.Towers.East.openingZ },
		{ "L2_AirlockSouthEast", 393, WorldConfig.Towers.SouthEast.openingZ },
	} :: { { any } }
do
	-- both fixtures fast to the ceiling (buildLight lifts none: a fixture set low hangs in the air)
	light(v[1], "Fluorescent", v[2], VESTIBULE_HEIGHT - 0.4, v[3], { flicker = mains(v[1]), broken = true })
	light(v[1], "EmergencyRed", v[2], VESTIBULE_HEIGHT - 0.4, v[3] - 8, { brightness = 0.3 })
end

--------------------------------------------------------------------------------
-- Keep-room anchors
--------------------------------------------------------------------------------

-- Arrival from Stairwell_1_2 and its corner candidates: four spawns in each west vestibule, facing east
for _, z in
	{
		WorldConfig.Towers.NorthWest.openingZ,
		WorldConfig.Towers.West.openingZ,
		WorldConfig.Towers.SouthWest.openingZ,
	} :: { number }
do
	for _, p in { { 4, z - 4 }, { 10, z - 4 }, { 4, z + 4 }, { 10, z + 4 } } do
		anchor("PlayerSpawn", p[1], 3.5, p[2], FACE_E)
	end
end

-- Lab islands and the flasks left on them: two rows of two in each lab, an aisle along the doors' line between them;
-- one bench in the prep room
for _, x in { 135, 159 } do
	island(x, LAB_Z - 7, { -2.5 })
	island(x, LAB_Z + 7, { 2.5 })
end
for _, x in { 239, 263 } do
	island(x, LAB_Z - 7, { 2.5 })
	island(x, LAB_Z + 7, { -2.5 })
end
island(251, LAB_Z - 27, { -3, 3 })

-- Floor objective (BurnChain): fifteen labelled reagent jars, five of each kind (the candidates cycle through the kinds
-- in layout order: nitric, sulfuric, catalyst): the planner's five on niche shelves come first, then the labs' worktops
-- and the stores' shelves (RunDirector uses one of each kind, in three different rooms); the fume hood against Chem
-- Prep 205's north wall (the anchor is the floor point on the wall face, facing into the room); hideable lockers in
-- the rooms keep a hiding spot near every step; the chains on the three east stair vestibules' fire doors (the exit
-- locks: the floor point on each door's corridor face, facing out of the door).
for _, p in
	{
		{ 138, LAB_Z - 7 }, -- chem lab 203, the north-west island (clear of its flask)
		{ 156, LAB_Z + 7 }, -- chem lab 203, the south-east island
		{ 162, LAB_Z - 7 }, -- chem lab 203, the north-east island
		{ 242, LAB_Z + 7 }, -- bio lab 209, the south-west island
		{ 260, LAB_Z - 7 }, -- bio lab 209, the north-east island
		{ 266, LAB_Z + 7 }, -- bio lab 209, the south-east island
	} :: { { number } }
do
	anchor("ReagentCandidate", p[1], WORKTOP, p[2])
end
anchor("ReagentCandidate", 201, WORKTOP, 2.3) -- chem store, the west shelving
anchor("ReagentCandidate", 222, WORKTOP, 2.3) -- chem store, the east shelving
anchor("ReagentCandidate", 50, WORKTOP, 285.7) -- specimen store, the west rack
anchor("ReagentCandidate", 68, WORKTOP, 285.7) -- specimen store, the east rack
anchor("FumeHood", 251, 0, LAB_Z - 40.5, FACE_S, "L2_FumeHood")
anchor("Locker", 125.05, 0, LAB_Z + 11, FACE_E) -- chem lab 203, west wall
anchor("Locker", 168.95, 0, LAB_Z + 11, FACE_W) -- chem lab 203, east wall
anchor("Locker", 229.05, 0, LAB_Z + 11, FACE_E) -- bio lab 209, west wall
anchor("Locker", 272.95, 0, LAB_Z - 11, FACE_W) -- bio lab 209, east wall
anchor("Locker", 264.95, 0, LAB_Z - 33, FACE_W) -- chem prep 205, by the hood
anchor("Locker", 197.05, 0, 11, FACE_E) -- chem store, west wall
anchor("Locker", 226.95, 0, 11, FACE_W) -- chem store, east wall
anchor("Locker", 46.05, 0, 278, FACE_E) -- specimen store, west wall
anchor("Locker", 73.95, 0, 278, FACE_W) -- specimen store, east wall
anchor("ExitLock", 385.5, 0, WorldConfig.Towers.East.openingZ, FACE_W, "L2_ExitLock")
anchor("ExitLock", 385.5, 0, WorldConfig.Towers.NorthEast.openingZ, FACE_W, "L2_ExitLock_North")
anchor("ExitLock", 385.5, 0, WorldConfig.Towers.SouthEast.openingZ, FACE_W, "L2_ExitLock_South")
for i, z in
	{
		WorldConfig.Towers.NorthEast.openingZ,
		WorldConfig.Towers.East.openingZ,
		WorldConfig.Towers.SouthEast.openingZ,
	} :: { number }
do
	-- the stair vestibules: a steel cabinet by the far wall
	anchor("Cabinet", 398.6, 0, z + 9, FACE_W, string.format("%s_Cabinet_Stairs%d", PREFIX, i))
end

anchor("Corpse", 149, 0, LAB_Z + 12, -110)
anchor("Corpse", 58, 0, 280, 30)
anchor("DripPipe", 251, HEIGHT - 1.2, LAB_Z + 2)
anchor("Clutter", 245, 0, LAB_Z - 22, 30)
anchor("Clutter", 221, 0, 12, -15)
anchor("Clutter", 147, 0, LAB_Z + 1, 75)
anchor("BatteryCandidate", 205, 0, 14)
anchor("BatteryCandidate", 72, 0, 271)

--------------------------------------------------------------------------------
-- Triggers
--------------------------------------------------------------------------------

trigger("L2_Trigger_GlassLab203", "FloorDebris", 141, LAB_Z - 2, 8, 4, 4)
trigger("L2_Trigger_GlassLab209", "FloorDebris", 245, LAB_Z - 2, 8, 4, 4)
trigger("L2_Trigger_Checkpoint", "Checkpoint", 387, WorldConfig.Towers.East.openingZ - 11, 12, 22, 11)
trigger("L2_Trigger_CheckpointNorthEast", "Checkpoint", 387, WorldConfig.Towers.NorthEast.openingZ - 11, 12, 22, 11)
trigger("L2_Trigger_CheckpointSouthEast", "Checkpoint", 387, WorldConfig.Towers.SouthEast.openingZ - 11, 12, 22, 11)

--------------------------------------------------------------------------------
-- Boarded windows on the facade
--------------------------------------------------------------------------------

windowRow("L2_ChemStore_243", "N", 2, 4, 3, 7)
windowRow("L2_SpecimenStore_225", "S", 2, 4, 3, 7)

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
	anchors = anchors,
	triggers = triggers,
	platforms = platforms,
	windows = windows,
	tunnels = plan.tunnels,
}

deepFreeze(layout)

return layout
