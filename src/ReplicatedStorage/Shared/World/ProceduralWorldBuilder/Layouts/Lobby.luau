--!strict
-- Lobby · the safe zone: an old boiler room with a bus bay where a wrecked school bus shell is the squad's staging
-- area. Built at WorldConfig.LobbyOrigin (its own coordinates, no footprint tiling); no vents, no Creature.
--
-- Plan (X west -> east, Z north -> south):
--   Lobby_BoilerRoom  x  0..60, z  0..48  spawn point (kind Boiler: LobbyBuilder stands its boiler set piece
--                                          against the wall with the most clearance, the north wall), with the
--                                          difficulty terminal past the boiler's firebox end
--   Lobby_BusBay      x 60..124, z 0..48  the bus shell, long axis along X; LobbyBuilder centres it on the four
--                                          ReadyPads down its aisle (about x 74..116, z 19..29)
--   Lobby_SupplyRoom  x  0..36, z 48..72  perk locker and the perk terminal
-- Warm, dim light only: caged bulbs here; LobbyBuilder adds the boiler's fire glow and the bulb inside the bus.
--
-- Anchor heights: pads, terminals and props on the floor (y = 0); PlayerSpawn at root height plus clearance (3.5).
-- Yaw: 0 faces north (-Z), 90 west, 180 south, -90 east.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
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

local PREFIX = "Lobby"
local HEIGHT = 20

local FACE_S, FACE_E = 180, -90

local LIGHT_DEFAULTS: { [string]: LightDefaults } = {
	Fluorescent = { brightness = 0.5, range = 18, color = Color3.fromRGB(236, 226, 200) },
	Bulb = { brightness = 0.55, range = 20, color = Color3.fromRGB(255, 184, 116) },
	EmergencyRed = { brightness = 0.45, range = 16, color = Color3.fromRGB(255, 34, 18) },
	ClassroomGlow = { brightness = 1.1, range = 34, color = Color3.fromRGB(198, 220, 255) },
	Floodlight = { brightness = 2, range = 60, color = Color3.fromRGB(236, 240, 255) },
	ExitSign = { brightness = 0.3, range = 8, color = Color3.fromRGB(70, 255, 120) },
	BoilerGlow = { brightness = 1.3, range = 32, color = Color3.fromRGB(255, 120, 44) },
}

local BOILER_ROOM: Style =
	{ floor = "ConcreteStained", wall = "Brick", ceiling = "ConcreteDark", surface = "Concrete", acoustic = "Lobby" }
local BUS_BAY: Style =
	{ floor = "Asphalt", wall = "ConcreteDark", ceiling = "ConcreteDark", surface = "Concrete", acoustic = "Lobby" }
local SUPPLY: Style =
	{ floor = "Concrete", wall = "WoodPanel", ceiling = "ConcreteDark", surface = "Wood", acoustic = "Lobby" }

--------------------------------------------------------------------------------
-- Blueprint helpers
--------------------------------------------------------------------------------

local rooms: { Room } = {}
local roomById: { [string]: Room } = {}
local doors: { LayoutSchema.Door } = {}
local anchors: { LayoutSchema.Anchor } = {}
local anchorCounts: { [string]: number } = {}
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
-- Rooms and doors
--------------------------------------------------------------------------------

room("Lobby_BoilerRoom", "Boiler", 0, 0, 60, 48, BOILER_ROOM)
room("Lobby_BusBay", "LobbyHall", 60, 0, 64, 48, BUS_BAY, 18)
room("Lobby_SupplyRoom", "LobbyHall", 0, 48, 36, 24, SUPPLY, 12)

door("Doorway", "Lobby_BoilerRoom", "Lobby_BusBay", 30, { id = "Lobby_Door_BusBay", width = 12 })
door("Door", "Lobby_BoilerRoom", "Lobby_SupplyRoom", 18, { id = "Lobby_Door_Supply" })

--------------------------------------------------------------------------------
-- Lights: warm and dim
--------------------------------------------------------------------------------

lightGrid("Lobby_BoilerRoom", "Bulb", 2, 2, "oofo", { flicker = "Lobby_Bulb" })
lightGrid("Lobby_BusBay", "Bulb", 3, 2, "oxoxoo", { brightness = 0.4 })
lightGrid("Lobby_SupplyRoom", "Bulb", 1, 1, "o", { brightness = 0.45, range = 16 })

--------------------------------------------------------------------------------
-- Anchors
--------------------------------------------------------------------------------

scatter("PlayerSpawn", 3.5, { { 20, 34, FACE_E }, { 24, 34, FACE_E }, { 20, 38, FACE_E }, { 24, 38, FACE_E } })

-- Ready-up pads down the bus aisle (one per squad slot)
for i, x in { 80, 88, 96, 104 } do
	anchor("ReadyPad", x, 0, 24, FACE_E, string.format("Lobby_ReadyPad_%d", i))
end

anchor("Terminal", 50, 0, 1.8, FACE_S, "Lobby_Terminal_Difficulty")
anchor("Terminal", 1.8, 0, 60, FACE_E, "Lobby_Terminal_Perks")

scatter("Clutter", 0, {
	{ 8, 8, 30 },
	{ 52, 40, -20 },
	{ 6, 44, 0 },
	{ 70, 6, 15 },
	{ 118, 44, 80 },
	{ 116, 6, -40 },
	{ 30, 68, 0 },
})

--------------------------------------------------------------------------------

local layout: LayoutSchema.LevelLayout = {
	id = "Lobby",
	height = HEIGHT,
	acoustic = "Lobby",
	ambience = "DroneLobby",
	entry = "Lobby_BoilerRoom",
	exit = "Lobby_BusBay",
	rooms = rooms,
	doors = doors,
	anchors = anchors,
	triggers = {},
}

deepFreeze(layout)

return layout
