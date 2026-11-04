--!strict
-- Level 3 · the gymnasium and the undercroft round it: boiler runs, team corridors, the tunnels under the bleachers,
-- the equipment vaults and the maintenance shafts. The squad comes up into one of the three east stair vestibules
-- (L3_AirlockEast in the middle, the route picks which) and must leave by one of the three west ones, whose fire doors'
-- motors are dead until the gym's generator winds them.
--
-- The map is TunnelPlanner's (seed below): the keep-rooms here, then the tunnels it lays round them over the whole
-- 400 x 288 footprint. Barrier lines fold the floor into four bands (each split down the middle by a barrier open at
-- one end, so a band is walked up one side and down the other), and the bands meet only where the floor's script
-- needs the squad to go:
--   band D (x 300..400)  Boiler Run: the three entry vestibules on the east wall (north z 28, middle 144, south 260);
--                        its middle barrier (x 350) is open at the north
--   the locker rooms     the boys' and girls' locker rooms straddle the D | C wall (x 300): the only way on is through
--                        one of them, past the lockers that may hold the coach's key (their showers, the coach's
--                        office and the team room sit between and beside them)
--   band C (x 200..300)  Team Corridors (the east side, by the locker rooms), then Under the Bleachers (the west side,
--                        along the gym's south wall); its middle barrier (x 250) is open at the south
--   the gym              the gymnasium (x 140..260, against the north facade) straddles the C | B wall (x 200): the
--                        only way on is across the court, through its two south doorways, with the Creature quicker
--                        on the boards (Level3_GymnasiumController); the equipment store opens off its west wall (the
--                        generator inside, the store door locked until the coach's key opens its padlock)
--   band B (x 100..200)  Under the Bleachers on its east side, the Equipment Vaults on its west side (open at the
--                        south), which meets band A only at the north (z 28)
--   band A (x 0..100)    Maintenance Shafts: down its east side, back up its west side past the three exit vestibules
--                        (south z 260, middle 144, north 28)
-- The shortest walk from the middle entry to the farthest exit is about 1,750 studs (2.7 minutes at walking pace).
-- Crawlways cut short rungs and some barriers, so a culvert the Creature cannot enter is never more than 60 studs' walk
-- away; under the gym, nothing rises past the Level 4 pool basin above (the basin-clearance spec).
--
-- Anchor heights: props rest on the floor (y = 0) or on a bench (its top); DripPipe sits under the ceiling; Locker =
-- the floor centre of a standing locker whose door faces the yaw; PlayerSpawn is at HumanoidRootPart height plus
-- clearance (3.5) and Creature placements at the rig's root height (5). Yaw is degrees about +Y: 0 faces north (-Z),
-- 90 west, 180 south, -90 east.

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

local PREFIX = "L3"
local SEED = 20261122
local HEIGHT = WorldConfig.Levels.Level3_Gymnasium.height
local LOW = 14 -- every room but the gym (the vestibules, the locker rooms and their annexes, the store)

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
local LOCKERS: Style =
	{ floor = "TileBlue", wall = "TileWhite", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local SHOWERS: Style =
	{ floor = "TileWhite", wall = "TileBlue", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
local OFFICE: Style =
	{ floor = "Carpet", wall = "WoodPanel", ceiling = "PlasterSchool", surface = "Carpet", acoustic = "Room" }
local TEAM: Style =
	{ floor = "Carpet", wall = "PlasterSchool", ceiling = "PlasterSchool", surface = "Carpet", acoustic = "Room" }
local STORE: Style =
	{ floor = "ConcreteStained", wall = "ConcreteDark", ceiling = "Concrete", surface = "Concrete", acoustic = "Room" }
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
-- Keep-rooms (the rooms the game needs; the planner tunnels around them) and the rooms joined to them
--------------------------------------------------------------------------------

local keep: { TunnelPlanner.KeepRoom } = {}
local function keepRoom(r: Room, ports: { TunnelPlanner.Port }, region: string?, sign: string?)
	table.insert(keep, { room = r, ports = ports, region = region, sign = sign })
end
-- Rooms the planner only steps round (reached by the layout's own doors from a keep-room)
local exclusions: { LayoutSchema.Rect } = {}
local function annex(r: Room)
	table.insert(exclusions, r.rect)
end

-- The gymnasium against the north facade: the only way from band C to band B, through its two south doorways (one
-- each side of the C | B wall at x 200)
keepRoom(room("L3_Gymnasium", "Gym", 140, 0, 120, 80, GYM), {
	{ side = "S", at = 188, kind = "Doorway", width = 8, id = "L3_Door_GymSouthWest" },
	{ side = "S", at = 214, kind = "Doorway", width = 8, id = "L3_Door_GymSouthEast" },
}, "Bleachers", "GYMNASIUM")
-- The equipment store off the gym's west wall: its steel door (DoorBuilder "RoofDoor": a single dented leaf) is the
-- floor objective's StoreDoor, locked until the coach's key opens its padlock (the StoreLock, gym side)
annex(room("L3_EquipmentStore", "Storage", 116, 36, 24, 32, STORE, LOW))
door(
	"RoofDoor",
	"L3_Gymnasium",
	"L3_EquipmentStore",
	52,
	{ id = "L3_Door_EquipmentStore", width = 8, scriptedId = "EquipmentStoreDoor" }
)

-- The locker block straddling the D | C wall (x 300): the boys' and the girls' locker rooms (each a way through, west
-- and east doors), their showers, the coach's office and the team room between them
annex(room("L3_Showers_Boys", "Restroom", 280, 90, 48, 18, SHOWERS, LOW))
keepRoom(room("L3_LockerRoom_Boys", "LockerRoom", 280, 108, 48, 32, LOCKERS, LOW), {
	{ side = "W", at = 122, kind = "Door", id = "L3_Door_LockerBoysWest" },
	{ side = "E", at = 122, kind = "Door", id = "L3_Door_LockerBoysEast" },
}, "Team", "BOYS")
annex(room("L3_CoachOffice", "Office", 290, 140, 28, 18, OFFICE, 12))
annex(room("L3_TeamRoom", "Classroom", 290, 158, 28, 18, TEAM, 12))
keepRoom(room("L3_LockerRoom_Girls", "LockerRoom", 280, 176, 48, 32, LOCKERS, LOW), {
	{ side = "W", at = 192, kind = "Door", id = "L3_Door_LockerGirlsWest" },
	{ side = "E", at = 192, kind = "Door", id = "L3_Door_LockerGirlsEast" },
}, "Team", "GIRLS")
annex(room("L3_Showers_Girls", "Restroom", 280, 208, 48, 18, SHOWERS, LOW))
door("Doorway", "L3_LockerRoom_Boys", "L3_Showers_Boys", 304, { id = "L3_Door_ShowersBoys", width = 6 })
door("Door", "L3_LockerRoom_Boys", "L3_CoachOffice", 304, { id = "L3_Door_CoachOffice" })
door("Door", "L3_CoachOffice", "L3_TeamRoom", 310, { id = "L3_Door_TeamRoomOffice" })
door("Door", "L3_TeamRoom", "L3_LockerRoom_Girls", 304, { id = "L3_Door_TeamRoom" })
door("Doorway", "L3_LockerRoom_Girls", "L3_Showers_Girls", 304, { id = "L3_Door_ShowersGirls", width = 6 })

-- Side rooms off the tunnels, each a landmark with somewhere to hide: the trophy hall north of the team corridors and
-- the mat store at the boiler run's south end
local HALL: Style =
	{ floor = "Linoleum", wall = "Brick", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Corridor" }
local MATS: Style =
	{ floor = "Carpet", wall = "PlasterSchool", ceiling = "PlasterSchool", surface = "Carpet", acoustic = "Room" }
keepRoom(
	room("L3_TrophyHall", "Corridor", 264, 24, 30, 44, HALL, LOW),
	{ { side = "S", at = 270, kind = "Door", id = "L3_Door_TrophyHall" } },
	"Team",
	"TROPHIES"
)
keepRoom(
	room("L3_MatStore", "Storage", 304, 236, 42, 44, MATS, LOW),
	{ { side = "N", at = 337, kind = "Door", id = "L3_Door_MatStore" } },
	"Boiler",
	"MAT STORE"
)

-- The stair vestibules: the entries against the east towers (from Stairwell_2_3 and its corner candidates), the exits
-- (route candidates, each fire door with the floor's Keypad ExitLock) against the west towers
for _, v in
	{
		{ "L3_AirlockNorthEast", 16, 28, "L3_Door_AirlockNorthEast" },
		{ "L3_AirlockEast", 132, 144, "L3_Door_AirlockEast" },
		{ "L3_AirlockSouthEast", 248, 260, "L3_Door_AirlockSouthEast" },
	} :: { { any } }
do
	-- (no stencil: the fire door's STAIRS sign is SignageBuilder's, beside it on the tunnel side)
	keepRoom(
		room(v[1], "Airlock", 386, v[2], 14, 24, AIRLOCK, LOW),
		{ { side = "W", at = v[3], kind = "Airlock", id = v[4] } },
		"Boiler"
	)
end
for _, v in
	{
		{ "L3_AirlockNorthWest", 16, 28, "L3_Door_AirlockNorthWest" },
		{ "L3_AirlockWest", 132, 144, "L3_Door_AirlockWest" },
		{ "L3_AirlockSouthWest", 248, 260, "L3_Door_AirlockSouthWest" },
	} :: { { any } }
do
	keepRoom(
		room(v[1], "Airlock", 0, v[2], 14, 24, AIRLOCK, LOW),
		{ { side = "E", at = v[3], kind = "Airlock", id = v[4] } },
		"Shafts"
	)
end

--------------------------------------------------------------------------------
-- The tunnels
--------------------------------------------------------------------------------

local plan = TunnelPlanner.plan({
	levelId = "Level3_Gymnasium",
	prefix = PREFIX,
	seed = SEED,
	height = HEIGHT,
	keepRooms = keep,
	entry = "L3_AirlockEast",
	exits = { "L3_AirlockNorthWest", "L3_AirlockWest", "L3_AirlockSouthWest" },
	exclusions = exclusions,
	barriers = {
		{ x0 = 50, z0 = 0, x1 = 50, z1 = 250 }, -- band A's middle, open at the south
		{ x0 = 100, z0 = 40, x1 = 100, z1 = 288 }, -- A | B, open at the north
		{ x0 = 150, z0 = 80, x1 = 150, z1 = 250 }, -- band B's middle (south of the gym), open at the south
		{ x0 = 200, z0 = 0, x1 = 200, z1 = 288 }, -- B | C: only across the gym
		{ x0 = 256, z0 = 80, x1 = 256, z1 = 250 }, -- band C's middle (south of the gym), open at the south
		{ x0 = 300, z0 = 0, x1 = 300, z1 = 288 }, -- C | D: only through a locker room
		{ x0 = 350, z0 = 40, x1 = 350, z1 = 288 }, -- band D's middle, open at the north
		-- each stair vestibule's line stops at its rail (the stub is the crossing's side arm, so the plate, the arrows
		-- and the graffiti go on the rail and the stub's walls keep room for the STAIRS sign)
		{ x0 = 37, z0 = 24, x1 = 37, z1 = 32 },
		{ x0 = 37, z0 = 140, x1 = 37, z1 = 148 },
		{ x0 = 37, z0 = 256, x1 = 37, z1 = 264 },
		{ x0 = 363, z0 = 24, x1 = 363, z1 = 32 },
		{ x0 = 363, z0 = 140, x1 = 363, z1 = 148 },
		{ x0 = 363, z0 = 256, x1 = 363, z1 = 264 },
	},
	gridX = { 30, 44, 62, 86, 106, 128, 162, 188, 214, 244, 270, 292, 312, 337, 356, 370 },
	crawlSites = {
		{ 44, 52, 62, 52 },
		{ 30, 144, 44, 144 },
		{ 44, 238, 62, 238 },
		{ 86, 52, 106, 52 },
		{ 86, 168, 106, 168 },
		{ 86, 260, 106, 260 },
		{ 162, 238, 188, 238 },
		{ 188, 100, 214, 100 },
		{ 188, 192, 214, 192 },
		{ 244, 100, 270, 100 },
		{ 244, 144, 270, 144 },
		{ 244, 238, 270, 238 },
		{ 337, 52, 356, 52 },
		{ 337, 144, 356, 144 },
		{ 356, 144, 370, 144 },
		{ 337, 216, 356, 216 },
		{ 356, 238, 370, 238 },
	},
	gridZ = { 28, 52, 76, 100, 122, 144, 168, 192, 216, 238, 260 },
	style = {
		width = { 6, 7, 7, 8 },
		height = { 10.5, 11 },
		galleryWidth = 9,
		galleryHeight = { 14, 15 },
		galleryShare = 0.16,
		galleryMin = 40,
		pitch = 24,
		jitter = 3,
		length = 3300,
		deadEnds = 4,
		crawlWidth = 4,
		crawlAcrossBarriers = true,
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
		acoustic = "Basement",
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
		-- the 400 x 288 floor's walk is too long for six culverts to keep one within 60 studs of everywhere (the
		-- side rooms' doors and the vestibules' stubs each want one near)
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
			id = "Shafts",
			medium = "DRAIN",
			name = "Maintenance Shafts",
			x = 50,
			z = 150,
			areas = { { 0, 0, 100, 288 } },
			pipe = rgb(54, 92, 58),
			band = rgb(214, 196, 64),
			grime = rgb(18, 22, 14),
			paint = rgb(236, 232, 214),
			graffiti = { "WEST IS OUT", "THE MOTOR WINDS", "DON'T LOOK BACK", "45 SECONDS" },
			wall = "ConcreteStained",
			wet = true,
		},
		{
			id = "Vaults",
			medium = "GAS",
			name = "Equipment Vaults",
			x = 125,
			z = 150,
			areas = { { 100, 0, 150, 288 } },
			pipe = rgb(176, 136, 24),
			band = rgb(30, 28, 24),
			grime = rgb(36, 30, 14),
			paint = rgb(232, 70, 48),
			graffiti = { "THE GENERATOR IS LOUD", "HIDE BEFORE YOU PULL", "IT HEARS THE MOTOR", "NO BALLS ALLOWED" },
			wall = "Brick",
		},
		{
			id = "Bleachers",
			medium = "AIR",
			name = "Under the Bleachers",
			x = 200,
			z = 110,
			areas = { { 150, 80, 236, 288 } },
			pipe = rgb(48, 48, 50),
			band = rgb(150, 146, 136),
			grime = rgb(14, 13, 12),
			paint = rgb(226, 222, 206),
			graffiti = { "DON'T CROSS THE COURT", "HE'S FASTER ON THE FLOOR", "STAY UNDER", "COUNT THE SEATS" },
			wall = "ConcreteDark",
		},
		{
			id = "Team",
			medium = "WATER",
			name = "Team Corridors",
			x = 270,
			z = 150,
			-- the corridors behind the locker rooms and the one under the bleachers' east rake
			areas = { { 236, 0, 300, 288 } },
			pipe = rgb(36, 78, 128),
			band = rgb(220, 220, 214),
			grime = rgb(16, 24, 26),
			paint = rgb(240, 236, 220),
			graffiti = { "GO TEAM", "KEY'S IN A LOCKER", "SEARCH THEM ALL", "HE CHECKS THE LOCKERS" },
			wall = "PlasterSchool",
			wet = true,
		},
		{
			id = "Boiler",
			medium = "STEAM",
			name = "Boiler Run",
			x = 350,
			z = 150,
			areas = { { 300, 0, 400, 288 } },
			pipe = rgb(132, 30, 24),
			band = rgb(214, 206, 186),
			grime = rgb(40, 18, 12),
			paint = rgb(236, 226, 196),
			graffiti = { "HE HEARS YOU RUN", "DON'T LOOK AT HIS FACE", "STEAM ON", "WALK. DON'T RUN" },
			wall = "Brick",
		},
	},
	attempts = 6,
	crossingTarget = 1780,
	-- the vestibules' and the keep-rooms' doors (their stubs): a hide near each
	hideTargets = {
		Vector3.new(16, 0, 28),
		Vector3.new(16, 0, 144),
		Vector3.new(16, 0, 260),
		Vector3.new(188, 0, 82),
		Vector3.new(214, 0, 82),
		Vector3.new(337, 0, 90),
	},
	traps = 0,
	batteries = 12,
	clutter = 20,
	corpses = 4,
	drips = 9,
	debris = 7,
	scares = 4,
	creatureSpawns = 6,
	creatureBand = { 70, 140 },
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
-- Furniture: the bleachers (stepped, solid to the floor), the locker-room benches, the store's racks
--------------------------------------------------------------------------------

-- North bleachers along the whole north wall; south bleachers either side of the two south doorways
for tier = 1, 4 do
	local top = 7.5 - 1.5 * tier
	local depth = 2.5
	platform(
		string.format("L3_Bleacher_N%d", tier),
		"L3_Gymnasium",
		150,
		depth * (tier - 1),
		100,
		depth,
		top,
		top,
		"WoodPanel"
	)
	platform(
		string.format("L3_Bleacher_SW%d", tier),
		"L3_Gymnasium",
		146,
		80 - depth * tier,
		32,
		depth,
		top,
		top,
		"WoodPanel"
	)
	platform(
		string.format("L3_Bleacher_SE%d", tier),
		"L3_Gymnasium",
		222,
		80 - depth * tier,
		32,
		depth,
		top,
		top,
		"WoodPanel"
	)
end
platform("L3_Bench_Boys1", "L3_LockerRoom_Boys", 288, 123.25, 12, 1.5, 1.6, 1.6, "WoodPanel")
platform("L3_Bench_Boys2", "L3_LockerRoom_Boys", 308, 123.25, 12, 1.5, 1.6, 1.6, "WoodPanel")
platform("L3_Bench_Girls1", "L3_LockerRoom_Girls", 288, 191.25, 12, 1.5, 1.6, 1.6, "WoodPanel")
platform("L3_Bench_Girls2", "L3_LockerRoom_Girls", 308, 191.25, 12, 1.5, 1.6, 1.6, "WoodPanel")
platform("L3_Rack_Store", "L3_EquipmentStore", 117, 37, 16, 2.6, 4, 4, "MetalRust")
platform("L3_MatStack_Store", "L3_EquipmentStore", 117, 59, 8, 7, 2.4, 2.4, "WoodPanel")
platform("L3_Desk_Coach", "L3_CoachOffice", 292, 142, 6, 3, 2.6, 2.6, "WoodPanel")
platform("L3_TrophyCase_N", "L3_TrophyHall", 266, 25, 26, 2, 7, 7, "WoodPanel")
platform("L3_TrophyCase_E", "L3_TrophyHall", 291.5, 30, 2, 20, 7, 7, "WoodPanel")
platform("L3_MatPile_A", "L3_MatStore", 306, 262, 12, 16, 2, 2, "Carpet")
platform("L3_MatPile_B", "L3_MatStore", 321, 266, 11, 12, 3, 3, "Carpet")
platform("L3_VaultHorse", "L3_MatStore", 334, 246, 8, 4, 4, 4, "WoodPanel")
platform("L3_Table_Team", "L3_TeamRoom", 298, 164, 12, 5, 2.6, 2.6, "WoodPanel")

--------------------------------------------------------------------------------
-- Keep-room lights: one sputtering high-bay over the court, dead tubes, the locker rooms on their own steady mains
--------------------------------------------------------------------------------

-- every keep-room is its own steady mains circuit (a local group: a flicker, the Creature's teleport warning, touches
-- only that room)
local function mains(roomId: string): string
	return "Mains:" .. roomId
end
do
	-- the court's high-bays: a 5 x 2 grid, all dead but one that sputters ("L3_GymHighBay")
	local n = 0
	for _, x in { 152, 176, 200, 224, 248 } do
		for _, z in { 26, 54 } do
			n += 1
			light("L3_Gymnasium", "Floodlight", x, HEIGHT - 0.6, z, {
				flicker = if n == 6 then "L3_GymHighBay" else nil,
				broken = n ~= 6,
			})
		end
	end
end
light("L3_Gymnasium", "EmergencyRed", 200, 12, 79.4, { brightness = 0.4, range = 18 })
light("L3_Gymnasium", "ExitSign", 186, 10.6, 79.4)
light("L3_Gymnasium", "ExitSign", 214, 10.6, 79.4)
light("L3_EquipmentStore", "Bulb", 126, LOW - 0.6, 52, { flicker = mains("L3_EquipmentStore"), cage = true })
light(
	"L3_EquipmentStore",
	"Bulb",
	120,
	LOW - 0.6,
	62,
	{ flicker = mains("L3_EquipmentStore"), broken = true, cage = true }
)
for _, id in { "L3_LockerRoom_Boys", "L3_LockerRoom_Girls" } do
	local r = getRoom(id).rect
	local cz = r.z + r.d / 2
	light(id, "Fluorescent", 292, LOW - 0.4, cz, { flicker = mains(id), broken = true })
	light(id, "Fluorescent", 304, LOW - 0.4, cz, { flicker = mains(id) })
	light(id, "Fluorescent", 316, LOW - 0.4, cz, { flicker = mains(id), broken = true })
end
light("L3_Showers_Boys", "Fluorescent", 304, LOW - 0.4, 99, { flicker = mains("L3_Showers_Boys"), broken = true })
light("L3_Showers_Girls", "Fluorescent", 304, LOW - 0.4, 217, { flicker = "Circuit:L3_ShowersGirls", brightness = 0.3 })
light("L3_CoachOffice", "Bulb", 296, 3.4, 143.5, { flicker = mains("L3_CoachOffice"), brightness = 0.22, range = 10 }) -- a forgotten desk lamp
light("L3_TeamRoom", "Fluorescent", 304, 11.6, 167, { flicker = mains("L3_TeamRoom"), broken = true })
light("L3_TrophyHall", "Fluorescent", 279, LOW - 0.4, 40, { flicker = mains("L3_TrophyHall") })
light("L3_TrophyHall", "Fluorescent", 279, LOW - 0.4, 58, { flicker = mains("L3_TrophyHall"), broken = true })
light("L3_MatStore", "Bulb", 325, LOW - 0.6, 250, { flicker = mains("L3_MatStore"), cage = true })
light("L3_MatStore", "Bulb", 315, LOW - 0.6, 270, { flicker = mains("L3_MatStore"), broken = true, cage = true })
for _, v in
	{
		{ "L3_AirlockNorthEast", 393, 28 },
		{ "L3_AirlockEast", 393, 144 },
		{ "L3_AirlockSouthEast", 393, 260 },
		{ "L3_AirlockNorthWest", 7, 28 },
		{ "L3_AirlockWest", 7, 144 },
		{ "L3_AirlockSouthWest", 7, 260 },
	} :: { { any } }
do
	light(v[1], "Fluorescent", v[2], LOW - 0.6, v[3], { flicker = mains(v[1]), broken = true })
	light(v[1], "EmergencyRed", v[2], LOW - 3, v[3] - 8, { brightness = 0.3 })
end

--------------------------------------------------------------------------------
-- Keep-room anchors
--------------------------------------------------------------------------------

-- Arrival from Stairwell_2_3 and its corner candidates (the east vestibules)
for _, z in { 28, 144, 260 } do
	for _, p in { { 392, z - 5 }, { 396, z - 5 }, { 392, z + 5 }, { 396, z + 5 } } do
		anchor("PlayerSpawn", p[1], 3.5, p[2], FACE_W)
	end
end

-- Hideable lockers lining the two locker rooms (backs to the long walls, clear of the doors): every one may hold the
-- coach's key (searchable) and every one hides a player
local LOCKER_XS = { 283, 286, 289, 292, 295, 298, 310, 313, 316, 319, 322, 325 }
local LOCKER_INSET = 1.8 -- a locker's floor centre off its wall line
for _, id in { "L3_LockerRoom_Boys", "L3_LockerRoom_Girls" } do
	local r = getRoom(id).rect
	for _, x in LOCKER_XS do
		anchor("Locker", x, 0, r.z + LOCKER_INSET, FACE_S)
	end
	for _, x in { 283, 286, 289, 319, 322, 325 } do
		anchor("Locker", x, 0, r.z + r.d - LOCKER_INSET, FACE_N)
	end
end

-- Floor objective (GymGenerator): the coach's key hangs inside any one of the locker-room lockers (each candidate's ref
-- is its locker; the anchor is the hook on the locker's back wall at chest height, facing out through its door); the
-- generator stands in the equipment store, its pull start toward the door; the store door's padlock (the floor point on
-- the door's gym face, facing out of the door); the exit locks on the three west vestibules' fire doors (the floor point
-- on each door's tunnel face, facing out of the door).
local KEY_HOOK_Y = 4.6
local KEY_BACK = 1.1 -- the hook sits this far behind the locker's floor centre, toward its back wall
local LOCKER_ROOMS: { [string]: boolean } = { L3_LockerRoom_Boys = true, L3_LockerRoom_Girls = true }
for _, locker in table.clone(anchors) do
	if locker.kind ~= "Locker" or not LOCKER_ROOMS[locker.room] then
		continue
	end
	local yaw = locker.yaw or FACE_S
	local back = if yaw == FACE_S then -KEY_BACK else KEY_BACK -- facing south, the back wall is to the north
	anchor("CoachKeyCandidate", locker.pos.X, KEY_HOOK_Y, locker.pos.Z + back, yaw, nil, locker.id)
end
anchor("Generator", 124, 0, 52, FACE_E, "L3_Generator")
anchor("StoreLock", 140.5, 0, 52, FACE_E, "L3_StoreLock")
anchor("ExitLock", 14.5, 0, 144, FACE_E, "L3_ExitLock")
anchor("ExitLock", 14.5, 0, 28, FACE_E, "L3_ExitLock_North")
anchor("ExitLock", 14.5, 0, 260, FACE_E, "L3_ExitLock_South")

-- The 45 s while the door motor winds: hideable lockers in the store and along the gym's west wall either side of the
-- store door, and one by each exit's fire door (inside its vestibule) so every lock keeps a locker within reach
anchor("Locker", 117.8, 0, 45, FACE_E) -- the store, west wall
anchor("Locker", 117.8, 0, 48, FACE_E)
anchor("Locker", 136, 0, 66.2, FACE_N) -- the store, south wall
for _, z in { 18, 21, 24, 40, 43, 64, 67 } do
	anchor("Locker", 141.8, 0, z, FACE_E) -- the gym's west wall
end
for i, z in { 28, 144, 260 } do
	anchor("Locker", 12.2, 0, z + 7.5, FACE_W, string.format("%s_Locker_Exit%d", PREFIX, i))
	-- and one inside each entry vestibule beside its fire door (the arrival's first hiding spot)
	anchor("Locker", 387.8, 0, z + 7.5, FACE_E, string.format("%s_Locker_Entry%d", PREFIX, i))
end

-- banks of lockers torn open: the old team lockers down the trophy hall's west wall (a corridor, so the wreckage keeps
-- to its wall and the hall's lane stays clear)
for _, z in { 30, 39.5, 49, 58 } do
	anchor("SmashedLocker", 265.8, 0, z, FACE_E)
end
-- the side rooms: lockers to duck into, a battery, their clutter
anchor("Locker", 292.2, 0, 60, FACE_W) -- the trophy hall
anchor("Locker", 292.2, 0, 63, FACE_W)
anchor("Locker", 344.2, 0, 270, FACE_W) -- the mat store
anchor("Locker", 344.2, 0, 273, FACE_W)
anchor("BatteryCandidate", 310, 0, 244)
anchor("Clutter", 280, 0, 48, 15)
anchor("Corpse", 318, 0, 252, 40)
anchor("Clutter", 170, 0, 40, 30)
anchor("Clutter", 232, 0, 30, -20)
anchor("Clutter", 300, 0, 172, 10)
anchor("Clutter", 128, 0, 60, 45)
anchor("Corpse", 196, 0, 46, 60)
anchor("BatteryCandidate", 128, 0, 64)
anchor("BatteryCandidate", 316, 0, 146)
anchor("BatteryCandidate", 252, 0, 70)

--------------------------------------------------------------------------------
-- Triggers
--------------------------------------------------------------------------------

trigger("L3_Trigger_DebrisCourt", "FloorDebris", 196, 36, 8, 8, 4)
trigger("L3_Trigger_DebrisShowers", "FloorDebris", 300, 212, 6, 6, 4)
trigger("L3_Trigger_Checkpoint", "Checkpoint", 1, 133, 12, 22, 11)
trigger("L3_Trigger_CheckpointNorthWest", "Checkpoint", 1, 17, 12, 22, 11)
trigger("L3_Trigger_CheckpointSouthWest", "Checkpoint", 1, 249, 12, 22, 11)

--------------------------------------------------------------------------------
-- Boarded clerestory windows high on the gym's facade wall
--------------------------------------------------------------------------------

for i = 1, 6 do
	table.insert(windows, {
		room = "L3_Gymnasium",
		side = "N",
		at = 140 + 120 * (i - 0.5) / 6,
		width = 9,
		height = 6,
		sill = 18,
		boarded = true,
	})
end

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
	anchors = anchors,
	triggers = triggers,
	platforms = platforms,
	windows = windows,
	tunnels = plan.tunnels,
}

deepFreeze(layout)

return layout
