--!strict
-- Level 0 · the maintenance level (below grade): steam tunnels, pipe galleries, coal chutes and drains. The squad
-- drops in from the lobby into L0_DeliveryBay on the west wall and must cross the maze to one of the three stair
-- vestibules on the east wall (the run's route picks which; the others are jammed). The power is out: the tunnels are
-- dark but for red emergency lamps until the squad finds three fuses and throws the breaker in the electrical room
-- (the mains then stutter back on). The Creature hunts down here too, and the bear traps lie in wait.
--
-- The map is TunnelPlanner's (seed below): the keep-rooms here, then the tunnels it lays around them, over the whole
-- 400 x 288 footprint. Barrier lines fold the floor into one long walk: four bands, each split down the middle by a
-- barrier open only at its north end (z 28), so a band is walked up one side and down the other; band 1 joins band 2
-- at the south (z 238 and below), band 2 joins band 3 only through the boiler room, band 3 joins band 4 at z 192 and
-- below. The shortest walk from the bay to the farthest stairs is about 1,900 studs (2.9 minutes at walking pace).
-- The regions follow the bands (each region's `areas`):
--   band 1 (x 0..126)    Coal Chutes: the bay (south-west), the coal bunker, the storage cage
--   band 2 (x 126..231)  Red Steam Run: the workshop; then through the boiler room (the only way on to band 3: a
--                        landmark you must walk through)
--   band 3 (x 231..336)  Yellow Gas Line (the west side, the north and the electrical room with the breaker panel),
--                        then Blue Water Main (the east side's south half, the pump room off its south end)
--   band 4 (x 336..400)  Flood Drains: up the west side, back down the east side past the three stair vestibules
--                        (north z 28, middle z 144, south z 260)
-- Eleven crawlways cut through the bands' middle barriers (bands 1 and 2 at z 76, 192 and 238, band 3 at z 76 and
-- 192, band 4 at z 52, 144 and 216), so a culvert the Creature cannot enter is never more than 60 studs' walk away
-- (the planner keeps every tunnel within reach of one); each also skips a band's turn, a shortcut for whoever dares
-- to crawl.
--
-- The squad arrives by the coal chute from the Back Lot (its mouth in the delivery bay's west wall, a CutsceneMark the
-- prologue lands on). The workshop's wall phone rings for one player once a run (spec 3.5). The stun flasks are Gus
-- Pruitt's cleaning chemicals; after the planner and the keep-rooms ExtraAnchors adds the floor's 36 battery candidates
-- and 8 flask spots (the storage cage's shelves twice, the workbench, the boiler room's shelf, four tunnel niches).

-- Anchor heights: props rest on the floor (y = 0) or on a shelf / bench (its top); DripPipe sits under the ceiling;
-- PlayerSpawn is at HumanoidRootPart height plus clearance (3.5) and Creature placements at the rig's root height (5).
-- Yaw is degrees about +Y: 0 faces north (-Z), 90 west, 180 south, -90 east.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local ExtraAnchors = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ExtraAnchors)
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

local PREFIX = "L0"
-- TunnelPlanner draws from Rng (the same plan in Lune and on Roblox); this seed, the first tried, passes every rule
-- and spec
local SEED = 20261103
local HEIGHT = WorldConfig.Levels.Level0_Basement.height

local FACE_N, FACE_W, FACE_S, FACE_E = 0, 90, 180, -90
-- The stair vestibules and the tunnels their fire doors open onto stand tall enough for the door's KEEP CLOSED sign
-- over its head casing (DoorBuilder: about 11.7 studs up).
local VESTIBULE_HEIGHT = 13
local FIRE_DOOR_CLEARANCE = 12.6

local LIGHT_DEFAULTS: { [string]: LightDefaults } = {
	Fluorescent = { brightness = 0.55, range = 18, color = Color3.fromRGB(214, 232, 236) },
	Bulb = { brightness = 0.45, range = 14, color = Color3.fromRGB(201, 203, 205) },
	EmergencyRed = { brightness = 0.45, range = 16, color = Color3.fromRGB(255, 34, 18) },
	ClassroomGlow = { brightness = 1.1, range = 34, color = Color3.fromRGB(198, 220, 255) },
	ExitSign = { brightness = 0.3, range = 8, color = Color3.fromRGB(222, 224, 226) },
	BoilerGlow = { brightness = 0.8, range = 14, color = Color3.fromRGB(155, 156, 157) },
}

local BOILER: Style = {
	floor = "ConcreteStained",
	wall = "BlockGray",
	ceiling = "ConcreteDark",
	surface = "Concrete",
	acoustic = "Basement",
}
local PLANT: Style =
	{ floor = "Concrete", wall = "ConcreteDark", ceiling = "ConcreteDark", surface = "Concrete", acoustic = "Basement" }
local STORE: Style =
	{ floor = "ConcreteStained", wall = "BlockGray", ceiling = "Concrete", surface = "Concrete", acoustic = "Room" }
local WORKSHOP: Style =
	{ floor = "ConcreteStained", wall = "WoodPanel", ceiling = "Concrete", surface = "Concrete", acoustic = "Room" }
local ELECTRICAL: Style =
	{ floor = "MetalGalvanized", wall = "ConcreteDark", ceiling = "Concrete", surface = "Metal", acoustic = "Room" }
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

-- Band 1: the arrival bay (the lobby drop lands here) and the coal bunker west of the west rail; the storage cage east
-- of the east rail
keepRoom(
	room("L0_DeliveryBay", "Storage", 22, 248, 26, 24, PLANT, 12),
	{ { side = "E", at = 260, kind = "Doorway", width = 8, id = "L0_Door_DeliveryBay" } },
	"Coal",
	"GOODS IN"
)
keepRoom(
	room("L0_CoalBunker", "Boiler", 22, 156, 26, 24, BOILER, 12),
	{ { side = "E", at = 168, kind = "Doorway", width = 6, id = "L0_Door_CoalBunker" } },
	"Coal",
	"COAL"
)
keepRoom(
	room("L0_StorageCage", "Storage", 96, 64, 22, 24, STORE, 11.5),
	{ { side = "W", at = 76, kind = "Door", id = "L0_Door_StorageCage" } },
	"Coal",
	"STORES"
)
-- Band 2: the workshop west of its west rail; the boiler room between bands 2 and 3 (the only way across)
keepRoom(
	room("L0_Workshop", "Storage", 132, 88, 24, 24, WORKSHOP, 11.5),
	{ { side = "E", at = 100, kind = "Door", id = "L0_Door_Workshop" } },
	"Steam",
	"WORKSHOP"
)
keepRoom(room("L0_BoilerRoom", "Boiler", 204, 226, 40, 24, BOILER, 16), {
	{ side = "W", at = 238, kind = "Doorway", width = 8, id = "L0_Door_BoilerWest" },
	{ side = "E", at = 238, kind = "Doorway", width = 8, id = "L0_Door_BoilerEast" },
}, "Steam", "BOILER ROOM")
-- Band 3: the electrical room (the breaker panel) east of its east side; the pump room off that side's south end
keepRoom(
	room("L0_ElectricalRoom", "Storage", 306, 88, 24, 24, ELECTRICAL, 12),
	{ { side = "W", at = 100, kind = "Door", id = "L0_Door_Electrical" } },
	"Gas",
	"ELECTRICAL"
)
keepRoom(
	room("L0_PumpRoom", "Boiler", 306, 234, 24, 24, PLANT, 12),
	{ { side = "N", at = 318, kind = "Door", id = "L0_Door_PumpRoom" } },
	"Water",
	"PUMPS"
)
-- Band 4: the three stair vestibules (route candidates) against the east towers
for _, v in
	{
		{ "L0_AirlockNorthEast", 16, 28, "L0_Door_AirlockNorthEast" },
		{ "L0_AirlockEast", 132, 144, "L0_Door_AirlockEast" },
		{ "L0_AirlockSouthEast", 248, 260, "L0_Door_AirlockSouthEast" },
	} :: { { any } }
do
	-- (no stencil: the fire door's STAIRS sign is SignageBuilder's, beside it on the tunnel side; the run the fire door
	-- opens onto stands tall enough for its KEEP CLOSED sign over the head casing)
	keepRoom(
		room(v[1], "Airlock", 386, v[2], 14, 24, AIRLOCK, VESTIBULE_HEIGHT),
		{ { side = "W", at = v[3], kind = "Airlock", id = v[4], runHeight = FIRE_DOOR_CLEARANCE } },
		"Drains"
	)
end

--------------------------------------------------------------------------------
-- The tunnels
--------------------------------------------------------------------------------

local exclusions: { LayoutSchema.Rect } = {}

local plan = TunnelPlanner.plan({
	levelId = "Level0_Basement",
	prefix = PREFIX,
	seed = SEED,
	height = HEIGHT,
	keepRooms = keep,
	entry = "L0_DeliveryBay",
	exits = { "L0_AirlockNorthEast", "L0_AirlockEast", "L0_AirlockSouthEast" },
	exclusions = exclusions,
	barriers = {
		-- each band's two sides meet only at the north row (z 28); bands 1 / 2 meet at the south rows (z 238+),
		-- bands 2 / 3 only through the boiler room, bands 3 / 4 at z 192+
		{ x0 = 72, z0 = 40, x1 = 72, z1 = 288 },
		{ x0 = 126, z0 = 0, x1 = 126, z1 = 226 },
		{ x0 = 180, z0 = 40, x1 = 180, z1 = 288 },
		{ x0 = 231, z0 = 0, x1 = 231, z1 = 288 },
		{ x0 = 264, z0 = 40, x1 = 264, z1 = 288 },
		{ x0 = 336, z0 = 0, x1 = 336, z1 = 180 },
		{ x0 = 367, z0 = 40, x1 = 367, z1 = 288 },
	},
	gridX = { 36, 60, 84, 108, 144, 168, 192, 216, 252, 276, 300, 318, 355, 370 },
	gridZ = { 28, 52, 76, 100, 122, 144, 168, 192, 216, 238, 260 },
	crawlSites = {
		{ 60, 76, 84, 76 },
		{ 60, 192, 84, 192 },
		{ 60, 238, 84, 238 },
		{ 168, 76, 192, 76 },
		{ 168, 192, 192, 192 },
		{ 168, 238, 192, 238 },
		{ 252, 76, 276, 76 },
		{ 252, 192, 276, 192 },
		{ 355, 52, 370, 52 },
		{ 355, 144, 370, 144 },
		{ 355, 216, 370, 216 },
	},
	style = {
		width = { 6, 7, 7, 8 },
		height = { 10.5, 11 },
		galleryWidth = 9,
		galleryHeight = { 14, 15 },
		galleryShare = 0.18,
		galleryMin = 40,
		pitch = 24,
		jitter = 3,
		length = 2700,
		deadEnds = 6,
		crawlWidth = 4,
		crawlAcrossBarriers = true,
		alcoveWidth = 5,
		alcoveDepth = 6,
		alcoveHeight = 10,
		lightSpacing = { 8, 11 },
		deadShare = 0.28,
		flickerShare = 0.1,
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
		-- the 400 x 288 floor's walk is too long for six culverts to keep one within 60 studs of everywhere
		crawlways = { 3, 12 },
		crawlLength = 20,
		crawlHeight = TunnelRules.CrawlClearance,
		crawlReach = 60,
		hideReach = 30,
		objectiveHideReach = 25,
		regions = { 4, 6 },
	},
	regions = {
		{
			id = "Coal",
			medium = "AIR",
			name = "Coal Chutes",
			x = 60,
			z = 160,
			areas = { { 0, 0, 126, 288 } },
			pipe = rgb(58, 60, 62),
			band = rgb(155, 155, 158),
			grime = rgb(13, 13, 15),
			paint = rgb(226, 222, 206),
			graffiti = { "HE HEARS YOU RUN", "KEEP LOW", "DON'T RUN", "COUNT THE PLATES" },
			wall = "ConcreteDark",
		},
		{
			id = "Steam",
			medium = "STEAM",
			name = "Red Steam Run",
			x = 180,
			z = 130,
			areas = { { 126, 0, 231, 288 } },
			pipe = rgb(58, 60, 62),
			band = rgb(158, 113, 111),
			grime = rgb(24, 24, 26),
			paint = rgb(236, 226, 196),
			graffiti = { "DON'T LOOK AT HIS FACE", "WALK. DON'T RUN", "HE WAS HERE", "STEAM ON" },
			wall = "BlockGray",
		},
		{
			id = "Gas",
			medium = "GAS",
			name = "Yellow Gas Line",
			x = 264,
			z = 60,
			areas = { { 231, 0, 264, 288 }, { 264, 0, 336, 130 } },
			pipe = rgb(58, 60, 62),
			band = rgb(158, 146, 111),
			grime = rgb(30, 30, 32),
			paint = rgb(232, 70, 48),
			graffiti = { "3 FUSES", "NO FLAME", "BREAKER IS EAST", "SHUT IT OFF" },
			wall = "ConcreteStained",
		},
		{
			id = "Water",
			medium = "WATER",
			name = "Blue Water Main",
			x = 290,
			z = 200,
			areas = { { 264, 130, 336, 288 } },
			pipe = rgb(58, 60, 62),
			band = rgb(111, 132, 158),
			grime = rgb(22, 22, 24),
			paint = rgb(240, 236, 220),
			graffiti = { "HIDE IN THE DRUMS", "HE WAITS", "IT CAN'T FIT", "LISTEN" },
			wall = "Concrete",
			wet = true,
		},
		{
			id = "Drains",
			medium = "DRAIN",
			name = "Flood Drains",
			x = 367,
			z = 150,
			areas = { { 336, 0, 400, 288 } },
			pipe = rgb(58, 60, 62),
			band = rgb(111, 158, 116),
			grime = rgb(20, 20, 22),
			paint = rgb(236, 232, 214),
			graffiti = { "DON'T LOOK BACK", "ALMOST OUT", "STAIRS EAST", "UP IS OUT" },
			wall = "ConcreteStained",
			wet = true,
		},
	},
	attempts = 6,
	crossingTarget = 1820,
	items = { { kind = "FuseCandidate" :: Enums.AnchorKind, count = 6, shelf = 3.2, guard = true } },
	hideTargets = {
		Vector3.new(384, 0, 28),
		Vector3.new(384, 0, 144),
		Vector3.new(384, 0, 260),
	},
	traps = 22,
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
-- Keep-room furniture: plant blocks (platforms stand on the floor), shelves and benches
--------------------------------------------------------------------------------

platform("L0_CoalHeap", "L0_CoalBunker", 23, 157, 10, 12, 3, 3, "ConcreteDark")
platform("L0_Crates_Bay", "L0_DeliveryBay", 23, 249, 5, 5, 3, 3, "WoodPanel")
platform("L0_Shelf_CageA", "L0_StorageCage", 97, 64.6, 10, 2.6, 4, 4, "MetalRust")
platform("L0_Shelf_CageB", "L0_StorageCage", 115.4, 70, 2.6, 12, 4, 4, "MetalRust")
platform("L0_Workbench", "L0_Workshop", 133, 96, 4, 8, 3, 3, "WoodPanel")
platform("L0_Shelf_Workshop", "L0_Workshop", 140, 88.6, 10, 2.6, 4, 4, "MetalRust")
platform("L0_Boiler_A", "L0_BoilerRoom", 208, 228, 12, 8, 10, 10, "MetalRust")
platform("L0_Boiler_B", "L0_BoilerRoom", 228, 228, 12, 8, 10, 10, "MetalRust")
platform("L0_Pump_A", "L0_PumpRoom", 307, 248, 7, 6, 4, 4, "MetalRust")
platform("L0_Pump_B", "L0_PumpRoom", 320, 248, 7, 6, 4, 4, "MetalRust")
platform("L0_Switchgear", "L0_ElectricalRoom", 325, 89, 4, 18, 8, 8, "MetalGalvanized")

--------------------------------------------------------------------------------
-- Keep-room lights: steady mains (held down while the power is out), boiler pilots, the reds that never die
--------------------------------------------------------------------------------

-- every keep-room is its own steady mains circuit (a local group: a flicker, the Creature's teleport warning, touches
-- only that room), held down with the tunnels' circuits until the breaker is thrown
local function mains(roomId: string): string
	return "Mains:" .. roomId
end
light("L0_DeliveryBay", "Bulb", 35, 11.2, 254, { flicker = "L0_Spawn", brightness = 0.35, cage = true })
light("L0_DeliveryBay", "Bulb", 35, 11.2, 266, { flicker = mains("L0_DeliveryBay"), broken = true, cage = true })
light("L0_DeliveryBay", "EmergencyRed", 46.6, 9, 260, { brightness = 0.4 })
light("L0_CoalBunker", "Bulb", 35, 11.2, 168, { flicker = mains("L0_CoalBunker"), cage = true })
light("L0_StorageCage", "Bulb", 107, 10.8, 76, { flicker = mains("L0_StorageCage"), cage = true })
light("L0_Workshop", "Bulb", 144, 10.8, 100, { flicker = mains("L0_Workshop"), cage = true })
light("L0_Workshop", "Fluorescent", 144, 11.1, 106, { flicker = mains("L0_Workshop"), broken = true })
light("L0_BoilerRoom", "Fluorescent", 214, 15.4, 243, { flicker = mains("L0_BoilerRoom"), broken = true })
light("L0_BoilerRoom", "Fluorescent", 224, 15.4, 243, { flicker = mains("L0_BoilerRoom") })
light("L0_BoilerRoom", "Fluorescent", 234, 15.4, 243, { flicker = mains("L0_BoilerRoom") })
light("L0_BoilerRoom", "BoilerGlow", 214, 2, 236.4, { flicker = "L0_Boilers" })
light("L0_BoilerRoom", "BoilerGlow", 234, 2, 236.4, { flicker = "L0_Boilers", brightness = 0.6 })
light("L0_BoilerRoom", "EmergencyRed", 224, 13, 249.4, { brightness = 0.4 })
light("L0_PumpRoom", "Bulb", 318, 11.2, 242, { flicker = mains("L0_PumpRoom"), cage = true })
light("L0_ElectricalRoom", "Fluorescent", 316, 11.4, 100, { flicker = mains("L0_ElectricalRoom") })
light("L0_ElectricalRoom", "EmergencyRed", 316, 9, 110.6, { brightness = 0.5 })
for _, v in { { "L0_AirlockNorthEast", 28 }, { "L0_AirlockEast", 144 }, { "L0_AirlockSouthEast", 260 } } :: { { any } } do
	-- both fixtures fast to the ceiling (buildLight lifts none: a fixture set low hangs in the air)
	light(v[1], "Fluorescent", 393, VESTIBULE_HEIGHT - 0.4, v[2], { flicker = mains(v[1]), broken = true })
	light(v[1], "EmergencyRed", 393, VESTIBULE_HEIGHT - 0.4, v[2] - 8, { brightness = 0.3 })
end

--------------------------------------------------------------------------------
-- Keep-room anchors
--------------------------------------------------------------------------------

-- Arrival from the lobby (DevTools "level 0" and the run deploy land here)
for _, p in { { 30, 256 }, { 36, 256 }, { 30, 264 }, { 36, 264 } } do
	anchor("PlayerSpawn", p[1], 3.5, p[2], FACE_E)
end

-- Floor objective (RestorePower): fuse candidates in the keep-rooms (the coal heap, the cage's shelving, the workbench,
-- by the boilers and the pumps, the switchgear), each with a bear-trap spot on its approach (its ref: the director arms
-- the guard traps of the first two fuses it uses), plus the planner's six in tunnel guard bays (on back-wall shelves,
-- the trap in the bay's mouth). Every guard leaves a way round it: a careful player always reaches a spot beside the
-- fuse clear of every trap spot (ObjectivePlaces.standingSpot). The breaker panel stands on the electrical room's
-- north wall (the floor point on the wall face, facing into the room); the exit locks on the three stair airlocks'
-- fire doors (the floor point on each door's corridor face, facing out of the door).
local function fuse(x: number, y: number, z: number, guardX: number, guardZ: number)
	local n = (anchorCounts.FuseCandidate or 0) + 1
	local guard = anchor("TrapCandidate", guardX, 0, guardZ, nil, string.format("%s_TrapGuard_%02d", PREFIX, n))
	anchor("FuseCandidate", x, y, z, nil, nil, guard)
end
fuse(31.5, 3, 163, 39.1, 164.7) -- on the coal heap's front, taken from the floor before it
fuse(116.7, 4, 72, 109.1, 73.1) -- on the cage's side shelving, its near end
fuse(116.7, 4, 80, 109.1, 78.8) -- on the cage's side shelving, its far end
fuse(135, 3, 100, 142.8, 100) -- on the workshop bench
fuse(212, 0, 248.5, 207.3, 243) -- at the foot of the first boiler
fuse(242.5, 0, 230, 240, 237.5) -- wedged behind the second boiler (its trap at the turn into the gap)
fuse(318, 0, 256.5, 318.5, 249.3) -- past the pumps (its trap in the gap between them, a lane past it by the first)
fuse(322.5, 0, 100, 315.3, 100) -- dropped in front of the switchgear
anchor("BreakerPanel", 316, 0, 88.5, FACE_S, "L0_BreakerPanel")
anchor("ExitLock", 385.5, 0, 144, FACE_W, "L0_ExitLock")
anchor("ExitLock", 385.5, 0, 28, FACE_W, "L0_ExitLock_North")
anchor("ExitLock", 385.5, 0, 260, FACE_W, "L0_ExitLock_South")

-- Lockers in the keep-rooms (backs to a wall, about two studs off its line), so every objective step keeps a hiding
-- spot within reach
anchor("Locker", 24.05, 0, 176, FACE_E) -- coal bunker, west wall
anchor("Locker", 100, 0, 85.95, FACE_N) -- storage cage, south wall
anchor("Locker", 150, 0, 109.95, FACE_N) -- workshop, south wall
anchor("Locker", 206.05, 0, 246, FACE_E) -- boiler room, west wall
anchor("Locker", 241.95, 0, 246, FACE_W) -- boiler room, east wall
anchor("Locker", 327.95, 0, 252, FACE_W) -- pump room, east wall
anchor("Locker", 327.95, 0, 108, FACE_W) -- electrical room, by the panel
for i, z in { 28, 144, 260 } do
	-- the stair vestibules: a steel cabinet by the far wall
	anchor("Cabinet", 398.6, 0, z + 9, FACE_W, string.format("%s_Cabinet_Stairs%d", PREFIX, i))
end

anchor("Clutter", 26, 0, 268, 30)
anchor("Clutter", 100, 0, 68, 45)
anchor("Clutter", 136, 0, 108, 10)
anchor("Corpse", 40, 0, 176, 60)
anchor("DripPipe", 224, HEIGHT - 1.2, 245)

-- The workshop's wall phone (spec 3.5): on the west wall past the bench, the handset at shoulder height
anchor("WallPhone", 132.55, 4.6, 107, FACE_E, "L0_WallPhone")
-- The coal chute's mouth in the delivery bay's west wall: where the prologue drops the squad in (spec 4.1)
anchor("CutsceneMark", 22.6, 0, 260, FACE_E, "L0_Mark_ChuteMouth")

--------------------------------------------------------------------------------
-- Triggers
--------------------------------------------------------------------------------

trigger("L0_Trigger_DebrisCoal", "FloorDebris", 34, 158, 6, 8, 4)
trigger("L0_Trigger_DebrisBoiler", "FloorDebris", 219, 238, 10, 6, 4)
trigger("L0_Trigger_Checkpoint", "Checkpoint", 387, 133, 12, 22, 11)
trigger("L0_Trigger_CheckpointNorthEast", "Checkpoint", 387, 17, 12, 22, 11)
trigger("L0_Trigger_CheckpointSouthEast", "Checkpoint", 387, 249, 12, 22, 11)

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
	platforms = platforms,
	tunnels = plan.tunnels,
}

-- The floor's 36 battery candidates and 8 flask spots (spec 4.2): the storage cage's shelf twice, the workbench, the
-- boiler room's wall shelf (CleaningShelfBuilder), four shelves over the drums of tunnel niches
ExtraAnchors.apply(layout, {
	seed = SEED,
	stations = { "BreakerPanel" },
	flasks = {
		{ pos = Vector3.new(100, 4, 65.9), yaw = FACE_S },
		{ pos = Vector3.new(104.5, 4, 65.9), yaw = FACE_S },
		{ pos = Vector3.new(135, 3, 103.2), yaw = FACE_E },
		{ pos = Vector3.new(226, 4.2, 248.95), yaw = FACE_N },
	},
	nicheFlasks = 4,
})

deepFreeze(layout)

return layout
