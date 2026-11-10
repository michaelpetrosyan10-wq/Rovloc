--!strict
-- Level 4 · the flooded Olympic pool and the plant tunnels round it: the pump gallery, the pipe galleries, the filter
-- tunnels, the chlorine run and the overflow drains. The squad comes up into one of the three west stair vestibules
-- (L4_AirlockWest in the middle, the route picks which) and must reach one of the three east ones; the natatorium
-- against the south facade is the only way across, so every route east crosses the pool.
--
-- The map is TunnelPlanner's (seed below): the keep-rooms here, then the tunnels it lays round them over the whole
-- 400 x 288 footprint. Barrier lines fold the floor; the natatorium and its flooded maintenance duct (the chase along
-- its north wall), with the barrier from the duct to the north facade (x 259), part the west from the east, and no
-- crawlway crosses that line (the culverts are pinned), so there is no dry bypass:
--   west (x 0..259)   Pump Gallery (x 0..60, the entry vestibules), Pipe Galleries (x 60..140) and Filter Tunnels
--                     (x 140..259 north of the duct, and the strip beside the pool's west wall), folded by barriers at
--                     x 60 (open at the north), 140 (open at the south) and 165 (open at the north); the natatorium's
--                     two west doors open off the last of them
--   the natatorium    the pool hall: the west deck, the collapsed bridge with its short swim, the spurs, the rest slabs,
--                     the diving tower's footing and the east deck; its one dry way on is the door in the east deck's
--                     north wall
--   east (x 259..400) Chlorine Run (north of the duct, east of the pool line) and the Overflow Drains along the east
--                     wall past the three exit vestibules (north z 28, middle 144, south 260), the barrier at x 350 open
--                     at the north
-- The shortest walk from the middle entry to the farthest exit is about 1,500 studs, plus the pool's swim and its
-- wading (about 2.5 minutes).
--
-- The natatorium is the old hall, every fairness rule kept (the same pieces relative to the hall): it is almost all
-- basin, deep murky water wall to wall (x 228..314), a 38-stud west deck and a 14-stud east deck. The old spectator
-- bridge has collapsed into 8-stud-wide slabs on their broken piers, parted by step-over cracks, with one fallen span
-- mid-pool (a 12-stud swim); a north spur runs to the maintenance duct's jammed west hatch and a south spur into the
-- deep end, and fallen roof slabs are rest islands, so the dry route covers most of the hall and every swim between safe
-- dry spots is short. The maintenance duct is sunk to the pool's waterline: its centre sits at the water surface, so
-- the murky water fills the lower half of the bore (every duct edge is Submerged, VentShaftBuilder floods it, and a
-- PoolWater volume covers the flooded half); its grates all open low in the natatorium's north wall, straight over the
-- water. The west grate is behind the hatch the floor objective opens (the hatch valve: FallenSlab_A, a short swim,
-- the valve half under the water); after it the duct is a half-flooded crawl east to the grate beside the east deck.
--
-- The 9 Floodlight fixtures over the pool start dark (broken) in FlickerGroup "L4_Floodlights"; the emergency
-- FloodlightSwitch on the west deck brings them up through the lighting overrides.
--
-- Anchor heights: props on the floor or on the starting blocks they stand on, DripPipe under the ceiling,
-- PlayerSpawn at root height plus clearance (3.5), Creature placements at the rig's root height (5). Yaw: 0 faces
-- north (-Z), 90 west, 180 south, -90 east.

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
-- TunnelPlanner draws from Rng (the same plan in Lune and on Roblox); this seed, the first tried, passes every rule
-- and spec
local SEED = 20261130
local HEIGHT = WorldConfig.Levels.Level4_FloodedPool.height
local LOW = 14 -- the stair vestibules
-- The tunnels the stair vestibules' fire doors open onto stand tall enough for the door's KEEP CLOSED sign over its
-- head casing (DoorBuilder: about 11.7 studs up).
local FIRE_DOOR_CLEARANCE = 12.6
local DUCT_ROOM = 6 -- the maintenance chase is a low service tunnel
local WATER = WorldConfig.WaterSurfaceOffset
local POOL_DEPTH = 10
local HALF_BORE = WorldConfig.VentBore / 2
local DUCT_Y = WATER -- the flooded duct's centre line: the water surface halves the bore

-- The natatorium's pieces are placed relative to the old hall's corner (90, 30): the hall now stands at (190, 188),
-- against the south facade.
local OX, OZ = 100, 158
local function px(x: number): number
	return x + OX
end
local function pz(z: number): number
	return z + OZ
end

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
local AIRLOCK: Style =
	{ floor = "Concrete", wall = "ConcreteDark", ceiling = "Concrete", surface = "Concrete", acoustic = "Stairwell" }
local PLANT: Style =
	{ floor = "Concrete", wall = "ConcreteDark", ceiling = "ConcreteDark", surface = "Concrete", acoustic = "Basement" }
local CHASE: Style =
	{ floor = "ConcreteDark", wall = "ConcreteDark", ceiling = "ConcreteDark", surface = "Water", acoustic = "Vent" }

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

-- The walkable room holding (x, z) at least 0.05 studs inside its walls (never solid ground or the chase).
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

local function anchor(kind: Enums.AnchorKind, x: number, y: number, z: number, yaw: number?, id: string?): string
	local n = (anchorCounts[kind] or 0) + 1
	anchorCounts[kind] = n
	local anchorId = id or string.format("%s_%s_%02d", PREFIX, kind, n)
	table.insert(anchors, {
		id = anchorId,
		kind = kind,
		room = roomAt(x, z),
		pos = Vector3.new(x, y, z),
		yaw = yaw,
	})
	return anchorId
end

-- Each point is { x, z } or { x, z, yaw }.
local function scatter(kind: Enums.AnchorKind, y: number, points: { { number } })
	for _, p in points do
		anchor(kind, p[1], y, p[2], p[3])
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
-- Keep-rooms (the rooms the game needs; the planner tunnels around them) and the rooms joined to them
--------------------------------------------------------------------------------

local keep: { TunnelPlanner.KeepRoom } = {}
local function keepRoom(r: Room, ports: { TunnelPlanner.Port }, region: string?, sign: string?)
	table.insert(keep, { room = r, ports = ports, region = region, sign = sign })
end
local exclusions: { LayoutSchema.Rect } = {}

-- The natatorium against the south facade: two doors from the filter tunnels onto the west deck, and the east deck's
-- door in its north wall (beside the duct's east end) on to the chlorine run, the one dry way east
keepRoom(room("L4_Natatorium", "Pool", px(90), pz(30), 138, 100, NATATORIUM), {
	{ side = "W", at = 210, kind = "Doorway", width = 8, id = "L4_Door_NatatoriumWest" },
	{ side = "W", at = 260, kind = "Door", id = "L4_Door_NatatoriumSouthWest" },
	{ side = "N", at = 321, kind = "Door", id = "L4_Door_NatatoriumEast" },
}, "Filters", "POOL")
-- The pump room off the filter tunnels: the pool's filter pumps and its heater, a landmark with lockers
keepRoom(room("L4_PumpRoom", "Boiler", 190, 116, 48, 40, PLANT, LOW), {
	{ side = "W", at = 144, kind = "Door", id = "L4_Door_PumpRoomWest" },
	{ side = "S", at = 204, kind = "Door", id = "L4_Door_PumpRoomSouth" },
}, "Filters", "PUMP ROOM")
-- The pool staff's room off the filter tunnels (lockers, the lifeguards' first-aid kit)
local STAFF: Style =
	{ floor = "Linoleum", wall = "PlasterSchool", ceiling = "PlasterSchool", surface = "Tile", acoustic = "Room" }
keepRoom(
	room("L4_StaffRoom", "Office", 186, 60, 44, 36, STAFF, LOW),
	{ { side = "W", at = 76, kind = "Door", id = "L4_Door_StaffRoom" } },
	"Filters",
	"POOL STAFF"
)
-- The flooded maintenance duct along the natatorium's north wall (a chase: reached only through its grates)
room("L4_Chase_Maintenance", "Chase", px(90), pz(25), 124, 5, CHASE, DUCT_ROOM)
table.insert(exclusions, getRoom("L4_Chase_Maintenance").rect)

-- The stair vestibules: the entries against the west towers (from Stairwell_3_4 and its corner candidates), the exits
-- (route candidates, each fire door with the floor's Keypad ExitLock, the hatch interlock) against the east towers
for _, v in
	{
		{ "L4_AirlockNorthWest", 16, 28, "L4_Door_AirlockNorthWest" },
		{ "L4_AirlockWest", 132, 144, "L4_Door_AirlockWest" },
		{ "L4_AirlockSouthWest", 248, 260, "L4_Door_AirlockSouthWest" },
	} :: { { any } }
do
	-- (no stencil: the fire door's STAIRS sign is SignageBuilder's, beside it on the tunnel side)
	keepRoom(
		room(v[1], "Airlock", 0, v[2], 14, 24, AIRLOCK, LOW),
		{ { side = "E", at = v[3], kind = "Airlock", id = v[4], runHeight = FIRE_DOOR_CLEARANCE } },
		"Pumps"
	)
end
for _, v in
	{
		{ "L4_AirlockNorthEast", 16, 28, "L4_Door_AirlockNorthEast" },
		{ "L4_AirlockEast", 132, 144, "L4_Door_AirlockEast" },
		{ "L4_AirlockSouthEast", 248, 260, "L4_Door_AirlockSouthEast" },
	} :: { { any } }
do
	keepRoom(
		room(v[1], "Airlock", 386, v[2], 14, 24, AIRLOCK, LOW),
		{ { side = "W", at = v[3], kind = "Airlock", id = v[4], runHeight = FIRE_DOOR_CLEARANCE } },
		"Drains"
	)
end

--------------------------------------------------------------------------------
-- The tunnels
--------------------------------------------------------------------------------

local plan = TunnelPlanner.plan({
	levelId = "Level4_FloodedPool",
	prefix = PREFIX,
	seed = SEED,
	height = HEIGHT,
	keepRooms = keep,
	entry = "L4_AirlockWest",
	exits = { "L4_AirlockNorthEast", "L4_AirlockEast", "L4_AirlockSouthEast" },
	exclusions = exclusions,
	barriers = {
		{ x0 = 60, z0 = 40, x1 = 60, z1 = 288 }, -- Pump Gallery | Pipe Galleries, open at the north
		{ x0 = 140, z0 = 0, x1 = 140, z1 = 250 }, -- Pipe Galleries | Filter Tunnels, open at the south
		{ x0 = 165, z0 = 40, x1 = 165, z1 = 288 }, -- the Filter Tunnels' fold, open at the north
		{ x0 = 259, z0 = 0, x1 = 259, z1 = 183 }, -- the pool line: west and east meet only across the natatorium
		{ x0 = 350, z0 = 40, x1 = 350, z1 = 288 }, -- the Overflow Drains' fold, open at the north
		-- each stair vestibule's line stops at its rail (the stub is the crossing's side arm, so the plate, the arrows
		-- and the graffiti go on the rail and the stub's walls keep room for the STAIRS sign)
		{ x0 = 40, z0 = 24, x1 = 40, z1 = 32 },
		{ x0 = 40, z0 = 140, x1 = 40, z1 = 148 },
		{ x0 = 40, z0 = 256, x1 = 40, z1 = 264 },
		{ x0 = 363, z0 = 24, x1 = 363, z1 = 32 },
		{ x0 = 363, z0 = 140, x1 = 363, z1 = 148 },
		{ x0 = 363, z0 = 256, x1 = 363, z1 = 264 },
	},
	gridX = { 30, 50, 72, 96, 128, 152, 178, 204, 230, 246, 272, 296, 321, 340, 356, 370 },
	gridZ = { 28, 52, 76, 100, 122, 144, 166, 188, 210, 236, 260 },
	-- pinned culverts (none across the pool line: no dry bypass of the natatorium)
	crawlSites = {
		{ 50, 52, 72, 52 },
		{ 30, 144, 50, 144 },
		{ 50, 236, 72, 236 },
		{ 72, 100, 96, 100 },
		{ 128, 188, 152, 188 },
		{ 152, 260, 178, 260 },
		{ 152, 166, 178, 166 },
		{ 152, 52, 178, 52 },
		{ 204, 52, 230, 52 },
		{ 272, 52, 296, 52 },
		{ 296, 144, 321, 144 },
		{ 340, 52, 356, 52 },
		{ 340, 144, 356, 144 },
		{ 356, 144, 370, 144 },
		{ 356, 260, 370, 260 },
	},
	style = {
		width = { 6, 7, 7, 8 },
		height = { 10.5, 11 },
		galleryWidth = 9,
		galleryHeight = { 14, 16 },
		galleryShare = 0.2,
		galleryMin = 40,
		pitch = 24,
		jitter = 3,
		length = 3800,
		deadEnds = 3,
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
		-- about 2.5 minutes with the pool's swim and wading (the walk alone a little under)
		crossing = { 1400, 1980 },
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
			id = "Pumps",
			medium = "WATER",
			name = "Pump Gallery",
			x = 30,
			z = 150,
			areas = { { 0, 0, 60, 288 } },
			pipe = rgb(36, 78, 128),
			band = rgb(220, 220, 214),
			grime = rgb(16, 24, 26),
			paint = rgb(240, 236, 220),
			graffiti = { "HE SWIMS", "STAY OUT OF THE WATER", "LISTEN", "THE POOL IS EAST" },
			wall = "Concrete",
			wet = true,
		},
		{
			id = "Pipes",
			medium = "STEAM",
			name = "Pipe Galleries",
			x = 100,
			z = 150,
			areas = { { 60, 0, 140, 288 } },
			pipe = rgb(132, 30, 24),
			band = rgb(214, 206, 186),
			grime = rgb(40, 18, 12),
			paint = rgb(236, 226, 196),
			graffiti = { "HE HEARS YOU RUN", "DON'T LOOK AT HIS FACE", "HEATER ON", "WALK. DON'T RUN" },
			wall = "Brick",
		},
		{
			id = "Filters",
			medium = "FILTER",
			name = "Filter Tunnels",
			x = 200,
			z = 100,
			areas = { { 140, 0, 259, 288 } },
			pipe = rgb(48, 48, 50),
			band = rgb(150, 146, 136),
			grime = rgb(14, 13, 12),
			paint = rgb(226, 222, 206),
			graffiti = { "FIND THE WHEEL", "IT'S ON THE BOTTOM", "HOLD YOUR BREATH", "SWIM FAST" },
			wall = "ConcreteDark",
			wet = true,
		},
		{
			id = "Chlorine",
			medium = "GAS",
			name = "Chlorine Run",
			x = 300,
			z = 80,
			areas = { { 259, 0, 350, 288 } },
			pipe = rgb(176, 136, 24),
			band = rgb(30, 28, 24),
			grime = rgb(36, 30, 14),
			paint = rgb(232, 70, 48),
			graffiti = { "NO NAKED FLAME", "THE HATCH OPENS IT", "CHLORINE", "DON'T BREATHE IT" },
			wall = "ConcreteStained",
		},
		{
			id = "Drains",
			medium = "DRAIN",
			name = "Overflow Drains",
			x = 370,
			z = 150,
			areas = { { 350, 0, 400, 288 } },
			pipe = rgb(54, 92, 58),
			band = rgb(214, 196, 64),
			grime = rgb(18, 22, 14),
			paint = rgb(236, 232, 214),
			graffiti = { "ALMOST OUT", "STAIRS EAST", "UP IS OUT", "DON'T LOOK BACK" },
			wall = "ConcreteStained",
			wet = true,
		},
	},
	attempts = 6,
	crossingTarget = 1560,
	hideTargets = {
		Vector3.new(384, 0, 28),
		Vector3.new(384, 0, 144),
		Vector3.new(384, 0, 260),
		Vector3.new(188, 0, 210),
		Vector3.new(188, 0, 260),
		Vector3.new(321, 0, 186),
	},
	traps = 0,
	batteries = 12,
	clutter = 20,
	corpses = 4,
	drips = 10,
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
-- The pool: one deep basin wall to wall, the collapsed bridge, debris and the deck furniture
--------------------------------------------------------------------------------

table.insert(basins, {
	id = "L4_Basin_Pool",
	room = "L4_Natatorium",
	rect = LayoutSchema.rect(px(128), pz(30), 86, 100),
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
-- Every support runs from the basin floor up to the underside of what it carries. (Coordinates below are the old hall's,
-- moved by px / pz.)
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
	platform(id, "L4_Natatorium", px(x), pz(z), w, d, top, thickness, material)
	local underside = top - thickness
	for i, pier in piers do
		platform(
			if i == 1 then id .. "_Pier" else string.format("%s_Pier%d", id, i),
			"L4_Natatorium",
			px(pier[1]),
			pz(pier[2]),
			pier[3],
			pier[4],
			underside,
			underside + POOL_DEPTH,
			"ConcreteDark"
		)
	end
end
-- The bridge, west to east along z 76..84 (old hall); the fallen span leaves open water from x 164 to 176.
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
platform("L4_TowerBase", "L4_Natatorium", px(203), pz(114), 11, 13, -0.4, POOL_DEPTH - 0.4, "ConcreteDark")
-- Rest islands: roof slabs fallen into the open water.
onPiers("L4_FallenSlab_C", 156, 104, 8, 7, -0.5, 1, "ConcreteStained", { { 158.5, 106, 4, 3 } })
onPiers("L4_FallenSlab_D", 174, 44, 8, 7, -0.6, 1.2, "ConcreteStained", { { 176.5, 46, 4, 3 } })
-- The diving tower stands in the deep end, off the duct's east grate.
platform("L4_DivingTower", "L4_Natatorium", px(207), pz(118), 6, 6, 10, POOL_DEPTH + 10, "Concrete")
for i, z in { 40, 52, 64, 96, 108, 120 } do
	platform(string.format("L4_StartBlock_%d", i), "L4_Natatorium", px(124), pz(z), 3, 3, 1.5, 1.5, "PoolTile")
end
platform("L4_StaffTable", "L4_StaffRoom", 204, 74, 10, 5, 2.6, 2.6, "WoodPanel")
platform("L4_StaffCounter", "L4_StaffRoom", 187, 61, 14, 2.4, 3, 3, "WoodPanel")
-- The pump room's filter pumps and the pool heater (the heater's glow below)
platform("L4_Pump_A", "L4_PumpRoom", 196, 120, 8, 6, 4, 4, "MetalRust")
platform("L4_Pump_B", "L4_PumpRoom", 210, 120, 8, 6, 4, 4, "MetalRust")
platform("L4_FilterTank", "L4_PumpRoom", 226, 120, 10, 10, 8, 8, "MetalGalvanized")
platform("L4_PoolHeater", "L4_PumpRoom", 224, 142, 12, 8, 6, 6, "MetalRust")
-- Lifeguard chairs and a stack of lane-rope reels on the west deck
platform("L4_LifeguardChair_N", "L4_Natatorium", px(112), pz(36), 3, 3, 4.5, 4.5, "MetalGalvanized")
platform("L4_LifeguardChair_S", "L4_Natatorium", px(112), pz(118), 3, 3, 4.5, 4.5, "MetalGalvanized")
platform("L4_ReelStack", "L4_Natatorium", px(96), pz(118), 6, 4, 2.6, 2.6, "MetalRust")

--------------------------------------------------------------------------------
-- The flooded maintenance duct (every edge Submerged), sunk to the waterline. Every grate opens over the basin: a
-- grate this low over the dry deck would open into its floor.
--------------------------------------------------------------------------------

local DUCT_WEST, DUCT_EAST = px(150), px(208) -- the two critical grates (centres along the north wall)

chaseRun("L4_Chase_Maintenance", {
	{
		id = "L4_Grate_M_PoolWest",
		room = "L4_Natatorium",
		side = "S",
		at = DUCT_WEST,
		lockable = false,
		critical = true,
	},
	{ id = "L4_Grate_M_PoolMidW", room = "L4_Natatorium", side = "S", at = px(166), lockable = true, critical = false },
	{ id = "L4_Grate_M_PoolMidE", room = "L4_Natatorium", side = "S", at = px(190), lockable = true, critical = false },
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
-- Keep-room lights
--------------------------------------------------------------------------------

local floodlight = 0
for _, x in { 140, 171, 202 } do
	for _, z in { 45, 80, 115 } do
		floodlight += 1
		light("L4_Natatorium", "Floodlight", px(x), HEIGHT - 0.6, pz(z), {
			id = string.format("L4_Floodlight_%02d", floodlight),
			flicker = "L4_Floodlights",
			broken = true,
		})
	end
end
for _, x in { 109, 221 } do
	for _, z in { 42, 68, 94, 120 } do
		light("L4_Natatorium", "Bulb", px(x), HEIGHT - 0.4, pz(z), { broken = true })
	end
end
light("L4_Natatorium", "EmergencyRed", px(225), 12, pz(37), { flicker = "L4_DeckEast", brightness = 0.5, range = 20 })
light("L4_Natatorium", "ExitSign", px(224.5), 11, pz(31.2))
light("L4_Natatorium", "EmergencyRed", px(93), 12, pz(52), { flicker = "L4_DeckWest", brightness = 0.3 })
light("L4_Natatorium", "EmergencyRed", px(93), 12, pz(102), { flicker = "L4_DeckWest", brightness = 0.3 })
light("L4_StaffRoom", "Fluorescent", 208, LOW - 0.4, 70, { flicker = "Mains:L4_StaffRoom" })
light("L4_StaffRoom", "Fluorescent", 208, LOW - 0.4, 86, { flicker = "Mains:L4_StaffRoom", broken = true })
light("L4_PumpRoom", "Bulb", 206, LOW - 0.6, 136, { flicker = "Mains:L4_PumpRoom", cage = true })
light("L4_PumpRoom", "Bulb", 222, LOW - 0.6, 136, { flicker = "Mains:L4_PumpRoom", broken = true, cage = true })
light("L4_PumpRoom", "BoilerGlow", 230, 2, 141.4, { flicker = "L4_PoolHeater" })
for _, v in
	{
		{ "L4_AirlockNorthWest", 7, 28 },
		{ "L4_AirlockWest", 7, 144 },
		{ "L4_AirlockSouthWest", 7, 260 },
		{ "L4_AirlockNorthEast", 393, 28 },
		{ "L4_AirlockEast", 393, 144 },
		{ "L4_AirlockSouthEast", 393, 260 },
	} :: { { any } }
do
	-- both fixtures fast to the ceiling (buildLight lifts none: a fixture set low hangs in the air)
	light(v[1], "Fluorescent", v[2], LOW - 0.6, v[3], { flicker = "Mains:" .. v[1], broken = true })
	light(v[1], "EmergencyRed", v[2], LOW - 0.4, v[3] - 8, { brightness = 0.3 })
end

--------------------------------------------------------------------------------
-- Keep-room anchors
--------------------------------------------------------------------------------

-- Arrival from Stairwell_3_4 and its corner candidates (the west vestibules; their fire doors are in the east wall)
for _, z in { 28, 144, 260 } do
	for _, p in { { 4, z - 5 }, { 8, z - 5 }, { 4, z + 5 }, { 8, z + 5 } } do
		anchor("PlayerSpawn", p[1], 3.5, p[2], FACE_E)
	end
end
anchor("FloodlightSwitch", px(91.5), 4, pz(70), FACE_E, "L4_FloodlightSwitch")

-- Floor objective (ValveWheel): the valve wheel lies on the deep pool floor at one of eight spots all over the basin,
-- never under a walkway and each 12 studs or less of swim from dry footing (the spurs, the bridge, the fallen slabs,
-- the tower's footing, the decks); the hatch valve is the jammed watertight hatch over the duct's west grate on the
-- inner face of the north coping, its valve socket half under the water (the anchor is the grate's centre at the
-- waterline, facing into the hall), a short swim from FallenSlab_A; the exit locks on the three east vestibules' fire
-- doors (the floor point on each door's tunnel face, facing out of the door). On the pool the Creature cannot leave the
-- water, so dry footing is the hiding spot near every pool-floor step.
for _, p in
	{
		{ 180, 106 },
		{ 202, 104 },
		{ 166, 121 },
		{ 152, 55 }, -- off the north spur
		{ 178, 58 }, -- south of FallenSlab_D
		{ 156, 92 }, -- south of the bridge, between it and FallenSlab_C
		{ 208, 50 }, -- off the east deck's coping
		{ 134, 110 }, -- off the west deck's coping
	}
do
	anchor("ValveWheelCandidate", px(p[1]), -POOL_DEPTH, pz(p[2]))
end
anchor("HatchValve", DUCT_WEST, WATER, pz(31), FACE_S, "L4_HatchValve")
anchor("ExitLock", 385.5, 0, 144, FACE_W, "L4_ExitLock")
anchor("ExitLock", 385.5, 0, 28, FACE_W, "L4_ExitLock_North")
anchor("ExitLock", 385.5, 0, 260, FACE_W, "L4_ExitLock_South")
for i, z in { 28, 144, 260 } do
	-- a hideable locker beside each fire door (inside the vestibule), at the exits and at the arrivals
	anchor("Locker", 387.8, 0, z + 7.5, FACE_E, string.format("%s_Locker_Exit%d", PREFIX, i))
	anchor("Locker", 12.2, 0, z + 7.5, FACE_W, string.format("%s_Locker_Entry%d", PREFIX, i))
end
-- Lockers in the staff room (against its east wall)
scatter("Locker", 0, { { 228.2, 66, FACE_W }, { 228.2, 69, FACE_W }, { 228.2, 72, FACE_W } })
anchor("BatteryCandidate", 222, 0, 92)
anchor("Clutter", 196, 0, 88, -10)
-- Lockers in the pump room (against its south wall, by the west door: the plant staff's)
scatter("Locker", 0, { { 192.5, 154.2, FACE_N }, { 195.5, 154.2, FACE_N } })
scatter("BatteryCandidate", 0, { { 234, 152 } })
anchor("Clutter", 214, 0, 148, 20)
anchor("DripPipe", 214, LOW - 1.2, 132)
-- Pool lockers against the decks' back walls
scatter("Locker", 0, {
	{ px(91.8), pz(40), FACE_E },
	{ px(91.8), pz(43), FACE_E },
	{ px(91.8), pz(86), FACE_E },
	{ px(91.8), pz(89), FACE_E },
	{ px(226.2), pz(60), FACE_W },
	{ px(226.2), pz(100), FACE_W },
})

-- Flasks left on the starting blocks and the decks
scatter("FlaskCandidate", 1.5, { { px(125.5), pz(41.5) }, { px(125.5), pz(65.5) }, { px(125.5), pz(109.5) } })
scatter("FlaskCandidate", 0, { { px(220), pz(60) }, { px(220), pz(120) }, { px(100), pz(112) } })

scatter("BatteryCandidate", 0, { { px(98), pz(34) }, { px(222), pz(126) }, { px(120), pz(80) } })
anchor("Corpse", px(154), -0.2, pz(80), 35)
anchor("Corpse", px(100), 0, pz(60), 120)
scatter(
	"Clutter",
	0,
	{ { px(100), pz(50), 0 }, { px(112), pz(96), 30 }, { px(104), pz(124), -15 }, { px(222), pz(100), 90 } }
)
anchor("DripPipe", px(110), HEIGHT - 1.2, pz(50))
anchor("DripPipe", px(200), HEIGHT - 1.2, pz(95))

-- Patrol over the decks (the tunnels' loops are the planner's); the pool's own loop under the water
local function patrol(loop: string, y: number, points: { { number } })
	for i, p in points do
		anchor("PatrolWaypoint", px(p[1]), y, pz(p[2]), nil, string.format("%s_WP_%s_%02d", PREFIX, loop, i))
	end
end
patrol("DW", 0, { { 95, 36 }, { 120, 36 }, { 120, 124 }, { 95, 124 } })
patrol("POOL", WATER - 3, { { 156, 56 }, { 200, 56 }, { 200, 100 }, { 156, 96 } })

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
trigger("L4_Trigger_DebrisDeck", "FloorDebris", px(100), pz(66), 6, 8, 4)
trigger("L4_Trigger_Checkpoint", "Checkpoint", 387, 133, 12, 22, 11)
trigger("L4_Trigger_CheckpointNorthEast", "Checkpoint", 387, 17, 12, 22, 11)
trigger("L4_Trigger_CheckpointSouthEast", "Checkpoint", 387, 249, 12, 22, 11)

--------------------------------------------------------------------------------
-- Boarded windows high in the natatorium's facade wall
--------------------------------------------------------------------------------

for i = 1, 6 do
	table.insert(windows, {
		room = "L4_Natatorium",
		side = "S",
		at = px(90) + 138 * (i - 0.5) / 6,
		width = 10,
		height = 8,
		sill = 14,
		boarded = true,
	})
end

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
	tunnels = plan.tunnels,
}

deepFreeze(layout)

return layout
