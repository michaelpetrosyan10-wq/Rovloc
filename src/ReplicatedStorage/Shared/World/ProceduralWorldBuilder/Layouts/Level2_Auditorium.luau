--!strict
-- Level 2 · the Auditorium storey, as an interim floor: the storey the theatre will fill (28 high, over the hallways,
-- under the roof), planned for now as a plain service floor so the climb runs basement -> hallways -> here -> roof.
-- The squad climbs out of the hallways into one of the three west stair vestibules (the run's route picks which) and
-- crosses to one of the three east ones; nothing is locked (ObjectiveConfig: ReachExit).
--
-- TunnelPlanner (seed below) lays a short ladder of service corridors between the two stair walls: a lane up each side
-- past the vestibules and three corridors across, with crawlways, barrels and cabinets, lights and patrol loops like
-- every tunnel floor, held to the same TunnelRules with this floor's thresholds (`rules` below).
--
-- Anchor heights: props on the floor (y = 0), PlayerSpawn at root height plus clearance (3.5), Creature placements
-- at the rig's root height (5). Yaw: 0 faces north (-Z), 90 west, 180 south, -90 east.

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

local PREFIX = "L2"
-- TunnelPlanner draws from Rng (the same plan in Lune and on Roblox); this seed passes every rule and spec
local SEED = 20261110
local HEIGHT = WorldConfig.Levels.Level2_Auditorium.height

local FACE_W, FACE_E = 90, -90

-- The stair vestibules and the tunnels their fire doors open onto stand tall enough for the door's KEEP CLOSED sign
-- over its head casing (DoorBuilder: about 11.7 studs up).
local VESTIBULE_HEIGHT = 13
local FIRE_DOOR_CLEARANCE = 12.6

local AIRLOCK: Style =
	{ floor = "Concrete", wall = "ConcreteDark", ceiling = "Concrete", surface = "Concrete", acoustic = "Stairwell" }

local rgb = Color3.fromRGB

local TOWERS_WEST = { WorldConfig.Towers.NorthWest, WorldConfig.Towers.West, WorldConfig.Towers.SouthWest }
local TOWERS_EAST = { WorldConfig.Towers.NorthEast, WorldConfig.Towers.East, WorldConfig.Towers.SouthEast }
local SLOT_NAMES = { "North", "", "South" }

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

local function room(id: string, kind: Enums.RoomKind, x: number, z: number, w: number, d: number, style: Style): Room
	local entry: Room = {
		id = id,
		kind = kind,
		rect = LayoutSchema.rect(x, z, w, d),
		height = VESTIBULE_HEIGHT,
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

local function trigger(id: string, kind: Enums.TriggerKind, x: number, z: number, w: number, d: number, height: number)
	table.insert(triggers, {
		id = id,
		kind = kind,
		room = roomAt(x + w / 2, z + d / 2),
		rect = LayoutSchema.rect(x, z, w, d),
		height = height,
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
-- Keep-rooms: the six stair vestibules
--------------------------------------------------------------------------------

local keep: { TunnelPlanner.KeepRoom } = {}

-- The three the squad climbs into (route candidates of Stairwell_1_2*), on the west wall
for i, tower in TOWERS_WEST do
	local id = "L2_Airlock" .. SLOT_NAMES[i] .. "West"
	table.insert(keep, {
		room = room(id, "Airlock", 0, tower.openingZ - 12, 14, 24, AIRLOCK),
		ports = {
			{
				side = "E",
				at = tower.openingZ,
				kind = "Airlock",
				id = "L2_Door_Airlock" .. SLOT_NAMES[i] .. "West",
				runHeight = FIRE_DOOR_CLEARANCE,
			},
		},
		region = "West",
	})
end
-- The three out (route candidates of Stairwell_2_3*), on the east wall
for i, tower in TOWERS_EAST do
	local id = "L2_Airlock" .. SLOT_NAMES[i] .. "East"
	table.insert(keep, {
		room = room(id, "Airlock", 386, tower.openingZ - 12, 14, 24, AIRLOCK),
		ports = {
			{
				side = "W",
				at = tower.openingZ,
				kind = "Airlock",
				id = "L2_Door_Airlock" .. SLOT_NAMES[i] .. "East",
				runHeight = FIRE_DOOR_CLEARANCE,
			},
		},
		region = "East",
	})
end

--------------------------------------------------------------------------------
-- The corridors
--------------------------------------------------------------------------------

local plan = TunnelPlanner.plan({
	levelId = "Level2_Auditorium",
	prefix = PREFIX,
	seed = SEED,
	height = HEIGHT,
	keepRooms = keep,
	entry = "L2_AirlockWest",
	exits = { "L2_AirlockNorthEast", "L2_AirlockEast", "L2_AirlockSouthEast" },
	gridX = { 34, 60, 120, 200, 280, 340, 366 },
	gridZ = { 28, 86, 144, 202, 260 },
	crawlSites = {
		{ 34, 86, 60, 86 },
		{ 340, 86, 366, 86 },
		{ 34, 202, 60, 202 },
		{ 340, 202, 366, 202 },
	},
	style = {
		width = { 7, 8 },
		height = { 11, 11.5 },
		galleryWidth = 9,
		galleryHeight = { 14, 14.5 },
		galleryShare = 0.2,
		galleryMin = 60,
		pitch = 80,
		jitter = 0,
		length = 2000,
		deadEnds = 2,
		crawlWidth = 4,
		crawlMouthsPass = true,
		alcoveWidth = 5,
		alcoveDepth = 6,
		alcoveHeight = 10,
		lightSpacing = { 16, 20 },
		deadShare = 0.3,
		flickerShare = 0.15,
		plateLampEvery = 2,
		wall = "ConcreteDark",
		floor = "ConcreteStained",
		ceiling = "ConcreteDark",
		acoustic = "Corridor",
		galleryAcoustic = "Hall",
		crawlAcoustic = "Vent",
	},
	rules = {
		maxLoop = 420,
		deadEndCount = 4,
		deadEndLength = 25,
		-- about a minute at walking pace (11 studs/s): an interim crossing
		crossing = { 400, 800 },
		crawlCrossingSeconds = 30,
		crawlways = { 3, 6 },
		crawlLength = 20,
		crawlHeight = TunnelRules.CrawlClearance,
		crawlReach = 160,
		hideReach = 40,
		objectiveHideReach = 25,
		regions = { 4, 6 },
	},
	regions = {
		{
			id = "West",
			medium = "MAINS",
			name = "West Stairs",
			x = 34,
			z = 144,
			areas = { { 0, 0, 80, 288 } },
			pipe = rgb(58, 60, 62),
			band = rgb(158, 158, 155),
			grime = rgb(26, 26, 28),
			paint = rgb(226, 222, 210),
			graffiti = { "KEEP MOVING", "STAIRS EAST" },
		},
		{
			id = "North",
			medium = "HEAT",
			name = "North Corridors",
			x = 200,
			z = 40,
			areas = { { 80, 0, 320, 115 } },
			pipe = rgb(58, 60, 62),
			band = rgb(158, 116, 111),
			grime = rgb(24, 24, 26),
			paint = rgb(232, 224, 200),
			graffiti = { "HE HEARS YOU RUN", "WALK. DON'T RUN" },
		},
		{
			id = "South",
			medium = "WATER",
			name = "South Corridors",
			x = 200,
			z = 240,
			areas = { { 80, 115, 320, 288 } },
			pipe = rgb(58, 60, 62),
			band = rgb(111, 138, 158),
			grime = rgb(23, 23, 25),
			paint = rgb(236, 232, 220),
			graffiti = { "LISTEN", "COUNT THE PLATES" },
			wet = true,
		},
		{
			id = "East",
			medium = "MAINS",
			name = "East Stairs",
			x = 366,
			z = 144,
			areas = { { 320, 0, 400, 288 } },
			pipe = rgb(58, 60, 62),
			band = rgb(125, 158, 111),
			grime = rgb(26, 26, 28),
			paint = rgb(240, 236, 220),
			graffiti = { "UP IS OUT", "ALMOST OUT" },
		},
	},
	attempts = 4,
	crossingTarget = 560,
	hideTargets = {
		Vector3.new(384, 0, WorldConfig.Towers.NorthEast.openingZ),
		Vector3.new(384, 0, WorldConfig.Towers.East.openingZ),
		Vector3.new(384, 0, WorldConfig.Towers.SouthEast.openingZ),
	},
	traps = 0,
	batteries = 6,
	clutter = 6,
	corpses = 1,
	drips = 3,
	debris = 3,
	scares = 0,
	creatureSpawns = 6,
	creatureBand = { 70, 160 },
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

--------------------------------------------------------------------------------
-- The vestibules: lights, the squad's spawns, a cabinet in each way out, the checkpoints
--------------------------------------------------------------------------------

local function lightsIn(roomId: string, x: number, z: number)
	local list = getRoom(roomId).lights
	if list then
		-- both fixtures fast to the ceiling (buildLight lifts none: a fixture set low hangs in the air)
		table.insert(list, {
			id = roomId .. "_Lamp",
			kind = "Fluorescent",
			pos = Vector3.new(x, VESTIBULE_HEIGHT - 0.4, z),
			brightness = 0.55,
			range = 18,
			color = rgb(214, 232, 236),
			flickerGroup = "Mains:" .. roomId,
			broken = true,
		})
		table.insert(list, {
			id = roomId .. "_Red",
			kind = "EmergencyRed",
			pos = Vector3.new(x, VESTIBULE_HEIGHT - 0.4, z - 8),
			brightness = 0.3,
			range = 16,
			color = rgb(255, 34, 18),
		})
	end
end

for i, tower in TOWERS_WEST do
	local z = tower.openingZ
	lightsIn("L2_Airlock" .. SLOT_NAMES[i] .. "West", 7, z)
	-- arrival from Stairwell_1_2 and its corner candidates: four spawns in each west vestibule, facing east
	for _, p in { { 4, z - 4 }, { 10, z - 4 }, { 4, z + 4 }, { 10, z + 4 } } do
		anchor("PlayerSpawn", p[1], 3.5, p[2], FACE_E)
	end
end
for i, tower in TOWERS_EAST do
	local z = tower.openingZ
	local id = "L2_Airlock" .. SLOT_NAMES[i] .. "East"
	lightsIn(id, 393, z)
	-- a steel cabinet by the far wall of each way out
	anchor("Cabinet", 398.6, 0, z + 9, FACE_W, string.format("%s_Cabinet_Stairs%d", PREFIX, i))
	trigger(
		"L2_Trigger_Checkpoint" .. (if SLOT_NAMES[i] == "" then "" else SLOT_NAMES[i] .. "East"),
		"Checkpoint",
		387,
		z - 11,
		12,
		22,
		11
	)
end

--------------------------------------------------------------------------------

local layout: LayoutSchema.LevelLayout = {
	id = "Level2_Auditorium",
	height = HEIGHT,
	acoustic = "Corridor",
	ambience = "DroneHallways",
	entry = "L2_AirlockWest",
	exit = "L2_AirlockEast",
	rooms = rooms,
	doors = doors,
	anchors = anchors,
	triggers = triggers,
	platforms = platforms,
	tunnels = plan.tunnels,
}

deepFreeze(layout)

return layout
