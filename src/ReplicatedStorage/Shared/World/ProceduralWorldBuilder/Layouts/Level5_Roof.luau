--!strict
-- Level 5 · Roof. The squad comes up one of the three east stair towers (Stairwell_4_5 and its corner candidates)
-- into its stair housing on the east edge (L5_RoofAccessNorth / L5_RoofAccess / L5_RoofAccessSouth, against the towers'
-- openings at z 28 / 144 / 260) and must cross the rain-slicked roof to the parachute crate by the west edge, then jump
-- through the gap in the west parapet (L5_JumpGap, the exit room, holding the LevelExit volume).
--
-- The roof is open (no ceiling, a parapet all round but the gap) and its plant makes a maze of it: ductwork, louvred
-- screen walls and plant blocks wall it into nine cells (three columns: the Plant Deck x 244..360, the Middle Roof
-- x 124..244, the West Roof x 0..124; three rows: z 0..96, 96..192, 192..288) with a 16-stud opening only where the
-- way goes on, so the run from the housings to the gap winds through most of the roof (about 850 studs, 75 s at
-- walking pace): from the housings' lane (L5_Roof_East, x 360..386) into the north or the south plant cell, through
-- the central plant cell, west into the middle column's centre, south, west into the south-west cell, north through the
-- west cell to the apron in front of the gap (L5_Roof_GapApron) with the crate at its west end. Two more openings (the
-- north and the south cells of the middle and plant columns) make loops to circle the Creature round. Inside the cells
-- HVAC units, a cooling tower, a water tank, a plant room, the boiler flue and skylight curbs are solid blocks to weave
-- between and crouch behind (Cover: ObjectivePlaces). The cells are the roof's zones: the world builder never walls one
-- Roof zone off from another, so the Doorways between them are open portals (the maze's openings) and the plant stands
-- along the closed stretches of their edges.
--
-- Lights: almost none; the storm's lightning lights the run. A red beacon blinks on the radio mast.
-- Anchor heights: props on the roof deck (y = 0), PlayerSpawn at root height plus clearance (3.5), Creature
-- placements at the rig's root height (5). Yaw: 0 faces north (-Z), 90 west, 180 south, -90 east.

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

type RoomOptions = { height: number?, wallHeight: number?, noCeiling: boolean? }

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

local PREFIX = "L5"
local HEIGHT = 12 -- zone height over the open roof and the stair housings' ceiling (WorldConfig keeps 0: no slab above)
local PARAPET = WorldConfig.ParapetHeight
local SIZE = WorldConfig.FootprintSize
local EDGE = WorldConfig.ExteriorWallThickness / 2 + 0.25 -- plant keeps this far in from the parapet's line
local DUCT = 5.5 -- ductwork and screen walls: higher than anyone climbs (a jump plus a step)
local WALL_T = 3 -- their thickness

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

local ROOF: Style =
	{ floor = "RoofGravel", wall = "Brick", ceiling = "Concrete", surface = "Concrete", acoustic = "Outdoor" }
local HOUSING: Style =
	{ floor = "Concrete", wall = "ConcreteDark", ceiling = "Concrete", surface = "Concrete", acoustic = "Stairwell" }

local OPEN_ROOF: RoomOptions = { wallHeight = PARAPET, noCeiling = true }

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
	options: RoomOptions?
): Room
	local o: RoomOptions = options or {}
	local entry: Room = {
		id = id,
		kind = kind,
		rect = LayoutSchema.rect(x, z, w, d),
		height = o.height,
		wallHeight = o.wallHeight,
		noCeiling = o.noCeiling,
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
		if LayoutSchema.rectContains(candidate.rect, x, z, 0.25) then
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

-- A door between `a` and `b`; without `at`, an open portal spanning their whole shared edge.
local function door(kind: Enums.DoorKind, a: string, b: string, at: number?, options: DoorOptions?)
	local o: DoorOptions = options or {}
	local roomA, roomB = getRoom(a), getRoom(b)
	local edge = LayoutSchema.sharedEdge(roomA.rect, roomB.rect)
	assert(edge, string.format("%s layout: %s and %s share no edge", PREFIX, a, b))
	table.insert(doors, {
		id = o.id or string.format("%s_Door_%02d", PREFIX, #doors + 1),
		kind = kind,
		rooms = { a, b },
		at = at or (edge.from + edge.to) / 2,
		width = o.width or (if at then nil else edge.to - edge.from - 1),
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

-- A closed patrol loop: waypoint i leads to i + 1 and the last back to the first, each hop within one cell or through
-- one opening.
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

local platformCount: { [string]: number } = {}
-- A solid block standing on the roof deck over the rect x0..x1, z0..z1 (in its cell, which it names).
local function plant(name: string, x0: number, z0: number, x1: number, z1: number, top: number, material: string)
	local roomId = roomAt((x0 + x1) / 2, (z0 + z1) / 2)
	local n = (platformCount[name] or 0) + 1
	platformCount[name] = n
	table.insert(platforms, {
		id = if n == 1 then string.format("%s_%s", PREFIX, name) else string.format("%s_%s%d", PREFIX, name, n),
		room = roomId,
		rect = LayoutSchema.rect(x0, z0, x1 - x0, z1 - z0),
		top = top,
		thickness = top,
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
-- Rooms: the nine cells, the apron before the gap, the gap, the housings' lane, the stair housings and the corners
--------------------------------------------------------------------------------

local GAP_Z0, GAP_Z1 = 84, 96 -- the jump gap: clear of the west stair towers (Z 12..44 and 128..160)

room("L5_Roof_NorthWest", "Roof", 0, 0, 124, GAP_Z0, ROOF, OPEN_ROOF)
room("L5_JumpGap", "Roof", 0, GAP_Z0, 4, GAP_Z1 - GAP_Z0, ROOF, { wallHeight = 0, noCeiling = true })
room("L5_Roof_GapApron", "Roof", 4, GAP_Z0, 120, GAP_Z1 - GAP_Z0, ROOF, OPEN_ROOF)
room("L5_Roof_West", "Roof", 0, 96, 124, 96, ROOF, OPEN_ROOF)
room("L5_Roof_SouthWest", "Roof", 0, 192, 124, 96, ROOF, OPEN_ROOF)
room("L5_Roof_North", "Roof", 124, 0, 120, 96, ROOF, OPEN_ROOF)
room("L5_Roof_Centre", "Roof", 124, 96, 120, 96, ROOF, OPEN_ROOF)
room("L5_Roof_South", "Roof", 124, 192, 120, 96, ROOF, OPEN_ROOF)
room("L5_Roof_NorthPlant", "Roof", 244, 0, 116, 96, ROOF, OPEN_ROOF)
room("L5_Roof_Plant", "Roof", 244, 96, 116, 96, ROOF, OPEN_ROOF)
room("L5_Roof_SouthPlant", "Roof", 244, 192, 116, 96, ROOF, OPEN_ROOF)
room("L5_Roof_East", "Roof", 360, 0, 26, SIZE.Y, ROOF, OPEN_ROOF)
room("L5_Roof_NECorner", "Roof", 386, 0, 14, 16, ROOF, OPEN_ROOF)
room("L5_RoofAccessNorth", "Stairwell", 386, 16, 14, 24, HOUSING)
room("L5_Roof_EastCornerN", "Roof", 386, 40, 14, 92, ROOF, OPEN_ROOF)
room("L5_RoofAccess", "Stairwell", 386, 132, 14, 24, HOUSING)
room("L5_Roof_EastCornerS", "Roof", 386, 156, 14, 92, ROOF, OPEN_ROOF)
room("L5_RoofAccessSouth", "Stairwell", 386, 248, 14, 24, HOUSING)
room("L5_Roof_SECorner", "Roof", 386, 272, 14, 16, ROOF, OPEN_ROOF)

--------------------------------------------------------------------------------
-- Doors: the scripted roof stair doors; everything else is an open portal between roof zones (the maze's openings)
--------------------------------------------------------------------------------

door("RoofDoor", "L5_RoofAccess", "L5_Roof_East", 144, { id = "L5_Door_RoofStair", scriptedId = "RoofStairDoor" })
door(
	"RoofDoor",
	"L5_RoofAccessNorth",
	"L5_Roof_East",
	28,
	{ id = "L5_Door_RoofStairNorth", scriptedId = "RoofStairDoorNorth" }
)
door(
	"RoofDoor",
	"L5_RoofAccessSouth",
	"L5_Roof_East",
	260,
	{ id = "L5_Door_RoofStairSouth", scriptedId = "RoofStairDoorSouth" }
)
-- the housings' lane and the corners beside the housings
for _, corner in { "L5_Roof_NECorner", "L5_Roof_EastCornerN", "L5_Roof_EastCornerS", "L5_Roof_SECorner" } do
	door("Doorway", "L5_Roof_East", corner)
end
-- the jump: the apron opens on the gap; the gap's ends meet the edge of the north-west cell
door("Doorway", "L5_Roof_GapApron", "L5_JumpGap", (GAP_Z0 + GAP_Z1) / 2, { id = "L5_Door_JumpGap", width = 10 })
door("Doorway", "L5_Roof_NorthWest", "L5_JumpGap", 2, { width = 3 })
door("Doorway", "L5_Roof_NorthWest", "L5_Roof_GapApron")
-- the maze's openings (16 studs each), in the order the way runs, then the two loops
local OPENING = 16
for _, o in
	{
		{ "L5_Roof_East", "L5_Roof_NorthPlant", 48 },
		{ "L5_Roof_East", "L5_Roof_SouthPlant", 240 },
		{ "L5_Roof_NorthPlant", "L5_Roof_Plant", 308 },
		{ "L5_Roof_Plant", "L5_Roof_SouthPlant", 338 },
		{ "L5_Roof_Plant", "L5_Roof_Centre", 144 },
		{ "L5_Roof_Centre", "L5_Roof_North", 158 },
		{ "L5_Roof_Centre", "L5_Roof_South", 218 },
		{ "L5_Roof_South", "L5_Roof_SouthWest", 258 },
		{ "L5_Roof_SouthWest", "L5_Roof_West", 48 },
		{ "L5_Roof_West", "L5_Roof_GapApron", 98 },
		{ "L5_Roof_North", "L5_Roof_NorthPlant", 28 },
		{ "L5_Roof_South", "L5_Roof_SouthPlant", 268 },
	} :: { { any } }
do
	door("Doorway", o[1], o[2], o[3], { width = OPENING })
end

--------------------------------------------------------------------------------
-- Rooftop plant (solid blocks standing on the roof deck): first the walls of the maze along the cells' closed edges
-- (ductwork on its stands, louvred screens round the plant), then the units inside the cells
--------------------------------------------------------------------------------

local HALF = OPENING / 2
-- the housings' lane's west side (inside the plant cells): open only into the north and the south plant cells
plant("Ductwork_East", 360 - WALL_T, EDGE, 360, 48 - HALF, DUCT, "MetalGalvanized")
plant("Ductwork_East", 360 - WALL_T, 48 + HALF, 360, 96, DUCT, "MetalGalvanized")
plant("Screen_East", 360 - WALL_T, 96, 360, 192, DUCT, "MetalRust")
plant("Ductwork_East", 360 - WALL_T, 192, 360, 240 - HALF, DUCT, "MetalGalvanized")
plant("Ductwork_East", 360 - WALL_T, 240 + HALF, 360, SIZE.Y - EDGE, DUCT, "MetalGalvanized")
-- the plant column's west side (inside the plant cells)
plant("Screen_Plant", 244, EDGE, 244 + WALL_T, 28 - HALF, DUCT, "MetalRust")
plant("Screen_Plant", 244, 28 + HALF, 244 + WALL_T, 96, DUCT, "MetalRust")
plant("Ductwork_Plant", 244, 96, 244 + WALL_T, 144 - HALF, DUCT, "MetalGalvanized")
plant("Ductwork_Plant", 244, 144 + HALF, 244 + WALL_T, 192, DUCT, "MetalGalvanized")
plant("Screen_Plant", 244, 192, 244 + WALL_T, 268 - HALF, DUCT, "MetalRust")
plant("Screen_Plant", 244, 268 + HALF, 244 + WALL_T, SIZE.Y - EDGE, DUCT, "MetalRust")
-- the plant column's rows (inside the central and the south plant cells)
plant("Ductwork_PlantN", 244 + WALL_T, 96, 308 - HALF, 96 + WALL_T, DUCT, "MetalGalvanized")
plant("Ductwork_PlantN", 308 + HALF, 96, 360 - WALL_T, 96 + WALL_T, DUCT, "MetalGalvanized")
plant("Ductwork_PlantS", 244 + WALL_T, 192, 338 - HALF, 192 + WALL_T, DUCT, "MetalGalvanized")
plant("Ductwork_PlantS", 338 + HALF, 192, 360 - WALL_T, 192 + WALL_T, DUCT, "MetalGalvanized")
-- the middle column's west side (inside the middle cells): open only into the south-west cell
plant("Ductwork_Middle", 124, EDGE, 124 + WALL_T, 96, DUCT, "MetalGalvanized")
plant("Screen_Middle", 124, 96, 124 + WALL_T, 192, DUCT, "MetalRust")
plant("Ductwork_Middle", 124, 192, 124 + WALL_T, 258 - HALF, DUCT, "MetalGalvanized")
plant("Ductwork_Middle", 124, 258 + HALF, 124 + WALL_T, SIZE.Y - EDGE, DUCT, "MetalGalvanized")
-- the middle column's rows (inside the centre and the south cells)
plant("Screen_MiddleN", 124 + WALL_T, 96, 158 - HALF, 96 + WALL_T, DUCT, "MetalRust")
plant("Screen_MiddleN", 158 + HALF, 96, 244, 96 + WALL_T, DUCT, "MetalRust")
plant("Screen_MiddleS", 124 + WALL_T, 192, 218 - HALF, 192 + WALL_T, DUCT, "MetalRust")
plant("Screen_MiddleS", 218 + HALF, 192, 244, 192 + WALL_T, DUCT, "MetalRust")
-- the west column's rows (inside the west and the south-west cells)
plant("Ductwork_WestN", EDGE, 96, 98 - HALF, 96 + WALL_T, DUCT, "MetalGalvanized")
plant("Ductwork_WestN", 98 + HALF, 96, 124, 96 + WALL_T, DUCT, "MetalGalvanized")
plant("Ductwork_WestS", EDGE, 192, 48 - HALF, 192 + WALL_T, DUCT, "MetalGalvanized")
plant("Ductwork_WestS", 48 + HALF, 192, 124, 192 + WALL_T, DUCT, "MetalGalvanized")

-- Units inside the cells
plant("HVAC_1", 272, 28, 300, 50, 7, "MetalGalvanized") -- north plant cell
plant("CoolingTower", 318, 60, 334, 76, 12, "MetalRust")
plant("HVAC_2", 276, 122, 296, 136, 7, "MetalGalvanized") -- central plant cell
plant("RadioMast", 318, 150, 322, 154, 2, "MetalRust")
plant("SkylightCurb_A", 300, 166, 324, 176, 1.5, "MetalGalvanized")
plant("HVAC_3", 268, 220, 292, 236, 6, "MetalGalvanized") -- south plant cell
plant("ToolLocker", 322, 252, 325, 258, 5, "MetalRust")
plant("WaterTank", 168, 28, 184, 44, 9, "MetalRust") -- north cell
plant("BoilerFlue", 212, 10, 218, 16, 10, "Brick")
plant("HVAC_4", 140, 60, 158, 72, 6, "MetalGalvanized")
plant("PlantRoom", 162, 124, 200, 164, 9, "Brick") -- centre cell: the plant room, walked round
plant("HVAC_5", 150, 220, 170, 234, 6, "MetalGalvanized") -- south cell
plant("SkylightCurb_B", 186, 248, 210, 258, 1.5, "MetalGalvanized")
plant("HVAC_6", 60, 230, 80, 244, 6, "MetalGalvanized") -- south-west cell
plant("Ductwork_SW", 30, 212, 33, 262, DUCT, "MetalGalvanized")
plant("HVAC_7", 40, 160, 56, 172, 6, "MetalGalvanized") -- west cell
plant("Ductwork_W", 70, 124, 110, 127, DUCT, "MetalGalvanized")
plant("HVAC_8", 60, 30, 78, 44, 6, "MetalGalvanized") -- north-west cell
-- A maintenance box by the jump: cover to crouch behind while the crate's chain is cut, a bolt-cutter candidate on its
-- lid
plant("MaintBox", 18, 70, 24, 73, 3.6, "MetalGalvanized")

--------------------------------------------------------------------------------
-- Lights
--------------------------------------------------------------------------------

for _, spot in { { "L5_RoofAccessNorth", 28 }, { "L5_RoofAccess", 144 }, { "L5_RoofAccessSouth", 260 } } :: { { any } } do
	local z: number = spot[2]
	light(spot[1], "Bulb", 393, HEIGHT - 0.4, z, { broken = true })
	light(spot[1], "EmergencyRed", 392, HEIGHT - 2, z - 8, { flicker = "L5_StairLamp", brightness = 0.3 })
	light("L5_Roof_East", "Bulb", 385.5, 10.8, z, { broken = true }) -- above the roof door's swing
end
light("L5_Roof_Plant", "EmergencyRed", 320, HEIGHT - 1, 152, { flicker = "L5_Beacon", brightness = 0.5, range = 20 })

--------------------------------------------------------------------------------
-- Anchors
--------------------------------------------------------------------------------

-- Arrival from Stairwell_4_5 and its corner candidates (each housing's south half), and the Creature behind each roof
-- door (its north half): it comes up the stairs behind the squad, and the roof controller holds it until it smashes
-- the door
for _, spot in { { "", 144 }, { "North", 28 }, { "South", 260 } } :: { { any } } do
	local z: number = spot[2]
	scatter(
		"PlayerSpawn",
		3.5,
		{ { 391, z + 4, FACE_W }, { 395, z + 4, FACE_W }, { 391, z + 9, FACE_W }, { 395, z + 9, FACE_W } }
	)
	anchor("CreatureSpawn", 393, 5, z - 7, FACE_S, "L5_CreatureSpawn" .. spot[1])
end
anchor("ParachuteCrate", 14, 0, (GAP_Z0 + GAP_Z1) / 2, FACE_W, "L5_ParachuteCrate")

-- Floor objective (CutCrate): the bolt cutters at one of ten spots all over the roof (leaning against the HVAC units,
-- the water tank, the plant room, the cooling tower, the boiler flue or the tool locker: the anchor is the deck point
-- at the face, facing away from it; or lying on the maintenance box's lid), each right beside cover; the chain through
-- the crate's packs (the anchor is the crate's own).
scatter("BoltCutterCandidate", 0, {
	{ 286, 51.4, FACE_S }, -- against HVAC_1's south face
	{ 316.6, 68, FACE_W }, -- against the cooling tower's west face
	{ 274.6, 129, FACE_W }, -- against HVAC_2's west face
	{ 320.6, 255, FACE_W }, -- against the tool locker's west face
	{ 185.4, 36, FACE_E }, -- against the water tank's east face
	{ 181, 122.6, FACE_N }, -- against the plant room's north face
	{ 160, 218.6, FACE_N }, -- against HVAC_5's north face
	{ 81.4, 237, FACE_E }, -- against HVAC_6's east face
	{ 48, 158.6, FACE_N }, -- against HVAC_7's north face
})
anchor("BoltCutterCandidate", 21, 3.6, 71.5, FACE_N) -- on the maintenance box
anchor("CrateChain", 14, 0, (GAP_Z0 + GAP_Z1) / 2, FACE_W, "L5_CrateChain")

scatter("BatteryCandidate", 0, {
	{ 393, 120 },
	{ 300, 20 },
	{ 280, 180 },
	{ 200, 60 },
	{ 140, 150 },
	{ 230, 270 },
	{ 20, 250 },
	{ 100, 140 },
})
scatter("Corpse", 0, { { 20, 60, 100 }, { 300, 110, -30 } })
scatter("Clutter", 0, {
	{ 330, 30, 0 },
	{ 372, 200, 45 },
	{ 260, 150, 0 },
	{ 214, 140, 30 },
	{ 150, 40, -20 },
	{ 100, 270, 60 },
	{ 110, 220, 0 },
	{ 30, 120, 90 },
	{ 90, 60, 15 },
})

-- Patrol loops through the maze, each over two neighbouring cells (each hop within a cell or through one of its
-- openings)
patrol("E", { { 373, 20 }, { 373, 100 }, { 373, 200 }, { 373, 268 } })
patrol("PN", { { 330, 20 }, { 290, 70 }, { 308, 86 }, { 308, 110 }, { 330, 120 } })
patrol("PS", { { 264, 150 }, { 338, 180 }, { 338, 206 }, { 300, 270 }, { 264, 210 } })
patrol("MN", { { 200, 20 }, { 150, 40 }, { 158, 84 }, { 158, 110 }, { 210, 110 } })
patrol("MS", { { 140, 180 }, { 218, 180 }, { 218, 206 }, { 200, 270 }, { 140, 258 } })
patrol("WS", { { 100, 258 }, { 48, 270 }, { 48, 206 }, { 48, 180 }, { 100, 170 } })
patrol("WN", { { 98, 120 }, { 98, 90 }, { 40, 90 } })
patrol("NW", { { 100, 60 }, { 40, 40 }, { 60, 88 } })

--------------------------------------------------------------------------------
-- Triggers
--------------------------------------------------------------------------------

trigger("L5_Trigger_LevelExit", "LevelExit", 0, GAP_Z0, 4, GAP_Z1 - GAP_Z0, 10)
trigger("L5_Trigger_SkylightGlass", "FloorDebris", 302, 177, 8, 6, 4)

--------------------------------------------------------------------------------

local layout: LayoutSchema.LevelLayout = {
	id = "Level5_Roof",
	height = HEIGHT,
	acoustic = "Outdoor",
	ambience = "DroneRoof",
	entry = "L5_RoofAccess",
	exit = "L5_JumpGap",
	rooms = rooms,
	doors = doors,
	anchors = anchors,
	triggers = triggers,
	platforms = platforms,
}

deepFreeze(layout)

return layout
