--!strict
-- Level 5 · Roof. The squad comes up Stairwell_4_5 into the stair housing L5_RoofAccess on the east edge and runs
-- the length of the rain-slicked roof to the parachute crate at the west edge, then jumps through the gap in the
-- west parapet (L5_JumpGap, the exit room, holding the LevelExit volume).
--
-- Plan (X west -> east, Z north -> south): one open roof deck split into zones for acoustics, hearing and the AI:
--   L5_Roof_West (x 0..120, z 0..100), L5_Roof_SouthWest (x 4..120, z 100..160), L5_Roof_East (x 120..226) and
--   the two strips flanking the stair housing (x 226..240). The world builder never walls one Roof zone off from
--   another, so the Doorways between them are open portals spanning each shared edge. The perimeter is a parapet
--   (wallHeight = ParapetHeight) everywhere except L5_JumpGap, a 12-stud stretch of the west edge with wallHeight 0:
--   the jump point, clear of the west stair tower (Z 64..96) so the drop goes straight to the street. Two 4-stud
--   edge strips (L5_Roof_WestEdge_N/S) carry the parapet on either side of it.
-- HVAC units, a water tank, the boiler flue and skylight curbs are solid platforms to weave between.
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
local HEIGHT = 12 -- zone height over the open roof and the stair housing's ceiling (WorldConfig keeps 0: no slab above)
local PARAPET = WorldConfig.ParapetHeight

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
-- through one opening.
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

room("L5_Roof_West", "Roof", 0, 0, 120, 100, ROOF, OPEN_ROOF)
room("L5_Roof_SouthWest", "Roof", 4, 100, 116, 60, ROOF, OPEN_ROOF)
room("L5_Roof_WestEdge_N", "Roof", 0, 100, 4, 20, ROOF, OPEN_ROOF)
room("L5_JumpGap", "Roof", 0, 120, 4, 12, ROOF, { wallHeight = 0, noCeiling = true })
room("L5_Roof_WestEdge_S", "Roof", 0, 132, 4, 28, ROOF, OPEN_ROOF)
room("L5_Roof_East", "Roof", 120, 0, 106, 160, ROOF, OPEN_ROOF)
room("L5_Roof_NECorner", "Roof", 226, 0, 14, 66, ROOF, OPEN_ROOF)
room("L5_RoofAccess", "Stairwell", 226, 66, 14, 28, HOUSING)
room("L5_Roof_SECorner", "Roof", 226, 94, 14, 66, ROOF, OPEN_ROOF)

--------------------------------------------------------------------------------
-- Doors: the scripted roof stair door; everything else is an open portal between roof zones
--------------------------------------------------------------------------------

door("RoofDoor", "L5_RoofAccess", "L5_Roof_East", 80, { id = "L5_Door_RoofStair", scriptedId = "RoofStairDoor" })
door("Doorway", "L5_Roof_West", "L5_Roof_East", 50, { width = 98 })
door("Doorway", "L5_Roof_SouthWest", "L5_Roof_East", 130, { width = 58 })
door("Doorway", "L5_Roof_West", "L5_Roof_SouthWest", 62, { width = 114 })
door("Doorway", "L5_Roof_East", "L5_Roof_NECorner", 33, { width = 64 })
door("Doorway", "L5_Roof_East", "L5_Roof_SECorner", 127, { width = 64 })
door("Doorway", "L5_Roof_West", "L5_Roof_WestEdge_N", 2, { width = 3 })
door("Doorway", "L5_Roof_WestEdge_N", "L5_Roof_SouthWest", 110, { width = 18 })
door("Doorway", "L5_Roof_WestEdge_S", "L5_Roof_SouthWest", 146, { width = 26 })
door("Doorway", "L5_Roof_SouthWest", "L5_JumpGap", 126, { id = "L5_Door_JumpGap", width = 10 })
door("Doorway", "L5_Roof_WestEdge_N", "L5_JumpGap", 2, { width = 3 })
door("Doorway", "L5_JumpGap", "L5_Roof_WestEdge_S", 2, { width = 3 })

--------------------------------------------------------------------------------
-- Rooftop plant (solid blocks standing on the roof deck)
--------------------------------------------------------------------------------

platform("L5_HVAC_1", "L5_Roof_East", 140, 20, 16, 12, 6, 6, "MetalGalvanized")
platform("L5_HVAC_2", "L5_Roof_East", 176, 120, 20, 14, 7, 7, "MetalGalvanized")
platform("L5_HVAC_3", "L5_Roof_East", 150, 60, 12, 10, 5, 5, "MetalRust")
platform("L5_HVAC_4", "L5_Roof_West", 60, 30, 18, 12, 6, 6, "MetalGalvanized")
platform("L5_HVAC_5", "L5_Roof_West", 30, 70, 12, 12, 5, 5, "MetalRust")
platform("L5_WaterTank", "L5_Roof_SouthWest", 70, 120, 14, 14, 9, 9, "MetalRust")
platform("L5_SkylightCurb_A", "L5_Roof_East", 190, 30, 20, 10, 1.5, 1.5, "MetalGalvanized")
platform("L5_SkylightCurb_B", "L5_Roof_West", 80, 76, 20, 10, 1.5, 1.5, "MetalGalvanized")
platform("L5_BoilerFlue", "L5_Roof_West", 100, 8, 6, 6, 10, 10, "Brick")
platform("L5_RadioMast", "L5_Roof_East", 204, 100, 4, 4, 2, 2, "MetalRust")
-- A maintenance box near the jump: cover to crouch behind while the crate chain is cut, and a bolt-cutter candidate
-- lying on its lid
platform("L5_MaintBox", "L5_Roof_SouthWest", 18, 104, 6, 3, 3.6, 3.6, "MetalGalvanized")

--------------------------------------------------------------------------------
-- Lights
--------------------------------------------------------------------------------

light("L5_RoofAccess", "Bulb", 233, HEIGHT - 0.4, 80, { broken = true })
light("L5_RoofAccess", "EmergencyRed", 232, HEIGHT - 2, 72, { flicker = "L5_StairLamp", brightness = 0.3 })
light("L5_Roof_East", "Bulb", 224.5, 10.8, 80, { broken = true }) -- above the roof door's swing
light("L5_Roof_East", "EmergencyRed", 206, HEIGHT - 1, 102, { flicker = "L5_Beacon", brightness = 0.5, range = 20 })

--------------------------------------------------------------------------------
-- Anchors
--------------------------------------------------------------------------------

-- Arrival from Stairwell_4_5
scatter("PlayerSpawn", 3.5, { { 232, 84, FACE_W }, { 236, 84, FACE_W }, { 232, 90, FACE_W }, { 236, 90, FACE_W } })
-- The Creature comes up the stairs behind the squad; P8 holds it until it smashes the RoofStairDoor.
anchor("CreatureSpawn", 233, 5, 70, FACE_S, "L5_CreatureSpawn")
anchor("ParachuteCrate", 14, 0, 126, FACE_W, "L5_ParachuteCrate")

-- Floor objective (CutCrate): the bolt cutters at one of four spots (leaning against two HVAC units and the water
-- tank: the anchor is the deck point at the face, facing away from it; or lying on the maintenance box's lid); the
-- chain through the crate's packs (the anchor is the crate's own).
scatter("BoltCutterCandidate", 0, {
	{ 148.6, 65, FACE_W }, -- against HVAC_3's west face
	{ 186, 118.6, FACE_N }, -- against HVAC_2's north face
	{ 85.4, 127, FACE_E }, -- against the water tank's east face
})
anchor("BoltCutterCandidate", 21, 3.6, 105.5, FACE_N) -- on the maintenance box
anchor("CrateChain", 14, 0, 126, FACE_W, "L5_CrateChain")

scatter("BatteryCandidate", 0, {
	{ 233, 120 },
	{ 138, 18 },
	{ 174, 118 },
	{ 58, 28 },
	{ 28, 84 },
	{ 90, 140 },
	{ 232, 30 },
})
scatter("Corpse", 0, { { 20, 118, 100 }, { 180, 40, -30 } })
scatter("Clutter", 0, {
	{ 166, 90, 0 },
	{ 214, 140, 45 },
	{ 130, 100, 0 },
	{ 96, 50, 30 },
	{ 40, 50, -20 },
	{ 50, 145, 60 },
	{ 110, 150, 0 },
	{ 233, 140, 90 },
})

patrol("E", { { 215, 80 }, { 200, 18 }, { 130, 14 }, { 130, 146 }, { 200, 146 } })
patrol("W", { { 110, 24 }, { 20, 20 }, { 20, 90 }, { 110, 76 } })
patrol("SW", { { 110, 130 }, { 30, 110 }, { 30, 150 }, { 100, 150 } })
patrol("X", { { 130, 76 }, { 110, 78 }, { 40, 95 }, { 40, 106 }, { 110, 132 }, { 130, 130 } })
patrol("C", { { 220, 30 }, { 233, 30 }, { 233, 10 }, { 220, 10 } })

--------------------------------------------------------------------------------
-- Triggers
--------------------------------------------------------------------------------

trigger("L5_Trigger_LevelExit", "LevelExit", 0, 120, 4, 12, 10)
trigger("L5_Trigger_SkylightGlass", "FloorDebris", 192, 42, 8, 6, 4)

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
