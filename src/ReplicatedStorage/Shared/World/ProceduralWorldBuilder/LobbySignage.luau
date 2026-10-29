--!strict
-- LobbySignage: the lobby's wayfinding, so a first-time player always sees where to go (LobbyBuilder calls build).
--
--   * Hanging signs: dented steel boards on two chains from the ceiling, stencilled from Strings (SurfaceArt, low
--     LightInfluence so the luminous paint still reads in the dim boiler light):
--       BUS — READY UP   over the doorway from the spawn room into the bus bay (facing the spawn room) and over the
--                        bus's rear emergency door (facing the way the squad comes);
--       DIFFICULTY       in front of the difficulty console;
--       SUPPLY / PERKS   over the supply room's door (facing the spawn room) and in front of the perk console.
--   * The lit path: photoluminescent egress chevrons (dim amber Neon, flat on the floor) every CHEVRON_SPACING studs
--     from the spawn point through the doorway to the bus's rear door: the route (route). Shorter runs of plain bone
--     paint lead the last few studs to the two optional stops (the supply room door, the difficulty console).
-- Every piece is cosmetic geometry (Geometry.makeCosmetic): never collides, never queried, casts no shadow. The whole set is one Model,
-- "Wayfinding", under Lobby.Props, about fifty parts.
--
-- Pure (tests/Specs/Onboarding.spec.luau): route, chevrons, signs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Strings = require(ReplicatedStorage.Shared.Strings)

local Geometry = require(script.Parent.Geometry)
local SurfaceArt = require(script.Parent.SurfaceArt)

type Layout = LayoutSchema.LevelLayout
type Room = LayoutSchema.Room
type Anchor = LayoutSchema.Anchor
type Door = LayoutSchema.Door

-- LobbyBuilder.BusInfo (passed in: this module sits under LobbyBuilder and never requires it).
export type Bus = { cframe: CFrame, length: number, width: number, entrance: Vector3 }

export type Chevron = { position: Vector3, direction: Vector3 } -- level-local, on the floor; direction horizontal

export type SignKind = "Bus" | "Difficulty" | "Supply"

export type Sign = {
	id: string,
	kind: SignKind,
	position: Vector3, -- level-local centre of the board
	facing: Vector3, -- horizontal unit: the side the words face
	ceiling: number, -- level-local height of the ceiling above it
	width: number,
}

export type Terminals = { Difficulty: string, Perks: string }

local CHEVRON_SPACING = 4.5
local CHEVRON_START = 3 -- studs from the spawn before the first chevron
local CHEVRON_END = 1.5 -- studs before the end of a run
local CHEVRON_ARM = 1.7
local CHEVRON_WIDTH = 0.34
local CHEVRON_THICKNESS = 0.04
local CHEVRON_HALF_ANGLE = math.rad(38)
local SIDE_RUN = 9 -- studs of chevrons before an optional stop
local DOOR_STEP = 3 -- studs either side of a doorway the route passes through
local SIGN_HEIGHT = 2.2
local SIGN_DEPTH = 0.18
local SIGN_OFF_WALL = 0.8
local SIGN_OVER_DOOR = 1.9 -- board centre above the door head
local SIGN_OVER_BUS = 1.7 -- board centre above the bus roof
local SIGN_OVER_CONSOLE = 7.2 -- board centre above the floor in front of a console
local CONSOLE_STEP = 0.9 -- studs in front of the console
local CONSOLE_FRONT = 3.2 -- where a player stands to use a console
local BUS_HEIGHT = 8.6
local CHAIN_DIAMETER = 0.12
local CHAIN_INSET = 0.6

local GLOW = Color3.fromRGB(150, 100, 36)
local BONE_PAINT = Color3.fromRGB(150, 142, 124)
local STENCIL = Color3.fromRGB(214, 168, 70)
local STENCIL_SUB = Color3.fromRGB(196, 188, 170)
local BORDER = Color3.fromRGB(196, 150, 64)
local GRIME = Color3.fromRGB(22, 18, 14)

local SIGN_WIDTHS: { [string]: number } = { Bus = 10, Difficulty = 7.5, Supply = 9 }
local SIGN_TEXT: { [SignKind]: { string } } = {
	Bus = { "LobbySign.Bus", "LobbySign.BusSub" },
	Difficulty = { "LobbySign.Difficulty", "LobbySign.DifficultySub" },
	Supply = { "LobbySign.Supply", "LobbySign.SupplySub" },
}

local LobbySignage = {}

LobbySignage.ChevronSpacing = CHEVRON_SPACING
LobbySignage.SignText = SIGN_TEXT

--------------------------------------------------------------------------------
-- Pure plan
--------------------------------------------------------------------------------

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function roomAt(layout: Layout, point: Vector3): Room?
	for _, room in layout.rooms do
		if LayoutSchema.rectContains(room.rect, point.X, point.Z, 0) then
			return room
		end
	end
	return nil
end

local function roomById(layout: Layout, id: string): Room?
	for _, room in layout.rooms do
		if room.id == id then
			return room
		end
	end
	return nil
end

local function centre(room: Room): Vector3
	return Vector3.new(room.rect.x + room.rect.w / 2, 0, room.rect.z + room.rect.d / 2)
end

-- The door between two rooms: its centre on the shared wall and the unit normal pointing from `from` into `to`.
local function crossing(layout: Layout, from: Room, to: Room): (Door?, Vector3, Vector3)
	for _, door in layout.doors do
		local a, b = door.rooms[1], door.rooms[2]
		if (a == from.id and b == to.id) or (a == to.id and b == from.id) then
			local edge = LayoutSchema.sharedEdge(from.rect, to.rect)
			if edge then
				local point = if edge.axis == "X"
					then Vector3.new(edge.coord, 0, door.at)
					else Vector3.new(door.at, 0, edge.coord)
				local toward = centre(to) - point
				local normal = if edge.axis == "X"
					then Vector3.new(if toward.X >= 0 then 1 else -1, 0, 0)
					else Vector3.new(0, 0, if toward.Z >= 0 then 1 else -1)
				return door, point, normal
			end
		end
	end
	return nil, Vector3.zero, Vector3.zero
end

local function spawnCentre(layout: Layout): Vector3?
	local sum = Vector3.zero
	local count = 0
	for _, anchor in layout.anchors do
		if anchor.kind == "PlayerSpawn" then
			sum += flat(anchor.pos)
			count += 1
		end
	end
	return if count > 0 then sum / count else nil
end

local function anchorById(layout: Layout, id: string): Anchor?
	for _, anchor in layout.anchors do
		if anchor.id == id then
			return anchor
		end
	end
	return nil
end

local function facingOf(anchor: Anchor): Vector3
	return CFrame.Angles(0, math.rad(anchor.yaw or 0), 0).LookVector
end

-- The lit path, level-local floor points: the spawn centroid, then either side of the doorway out of the spawn room
-- when the bus stands in another room, then the bus's entrance. Empty without spawns or a bus.
function LobbySignage.route(layout: Layout, bus: Bus?): { Vector3 }
	local points: { Vector3 } = {}
	local start = spawnCentre(layout)
	if not start or not bus then
		return points
	end
	table.insert(points, start)
	local entrance = flat(bus.entrance)
	local fromRoom = roomAt(layout, start)
	local busRoom = roomAt(layout, entrance)
	if fromRoom and busRoom and fromRoom ~= busRoom then
		local door, point, normal = crossing(layout, fromRoom, busRoom)
		if door then
			table.insert(points, point - normal * DOOR_STEP)
			table.insert(points, point + normal * DOOR_STEP)
		end
	end
	table.insert(points, entrance)
	return points
end

-- Chevrons along a polyline, one every `spacing` studs of path, starting `startGap` in and stopping `endGap` before
-- its end; each points along its own segment.
function LobbySignage.chevrons(points: { Vector3 }, spacing: number, startGap: number, endGap: number): { Chevron }
	local out: { Chevron } = {}
	if #points < 2 or spacing <= 0 then
		return out
	end
	local total = 0
	for i = 2, #points do
		total += (flat(points[i]) - flat(points[i - 1])).Magnitude
	end
	local distance = startGap
	local walked = 0
	local segment = 2
	while distance <= total - endGap + 1e-6 do
		while segment <= #points do
			local a, b = flat(points[segment - 1]), flat(points[segment])
			local length = (b - a).Magnitude
			if walked + length >= distance - 1e-9 and length > 1e-6 then
				local direction = (b - a) / length
				table.insert(out, { position = a + direction * (distance - walked), direction = direction })
				break
			end
			walked += length
			segment += 1
		end
		if segment > #points then
			break
		end
		distance += spacing
	end
	return out
end

-- The last `run` studs of the straight line from `from` to `to`, as a two-point polyline (shorter lines whole).
local function sideRun(from: Vector3, to: Vector3, run: number): { Vector3 }
	local delta = flat(to) - flat(from)
	local length = delta.Magnitude
	if length < 1e-6 then
		return {}
	end
	local start = if length > run then flat(to) - delta / length * run else flat(from)
	return { start, flat(to) }
end

-- Where a player stands to use a console (level-local), or nil when the layout has no such anchor.
function LobbySignage.consoleFront(layout: Layout, anchorId: string): Vector3?
	local anchor = anchorById(layout, anchorId)
	return if anchor then flat(anchor.pos) + facingOf(anchor) * CONSOLE_FRONT else nil
end

-- Every hanging sign: over the doorway to the bus room and over the bus's rear door (BUS), in front of the
-- difficulty console (DIFFICULTY), over the supply room door and in front of the perk console (SUPPLY / PERKS).
function LobbySignage.signs(layout: Layout, bus: Bus?, terminals: Terminals): { Sign }
	local out: { Sign } = {}
	local start = spawnCentre(layout)
	local fromRoom = if start then roomAt(layout, start) else roomById(layout, layout.entry)
	local function roomHeight(room: Room?): number
		return if room and room.height then room.height else layout.height
	end
	local function overDoor(id: string, kind: SignKind, to: Room)
		if not fromRoom or fromRoom == to then
			return
		end
		local door, point, normal = crossing(layout, fromRoom, to)
		if door then
			table.insert(out, {
				id = id,
				kind = kind,
				position = point
					- normal * SIGN_OFF_WALL
					+ Vector3.new(0, LayoutSchema.doorHeight(door) + SIGN_OVER_DOOR, 0),
				facing = -normal,
				ceiling = roomHeight(fromRoom),
				width = SIGN_WIDTHS[kind],
			})
		end
	end
	local function atConsole(id: string, kind: SignKind, anchorId: string)
		local anchor = anchorById(layout, anchorId)
		if not anchor then
			return
		end
		local facing = facingOf(anchor)
		table.insert(out, {
			id = id,
			kind = kind,
			position = flat(anchor.pos) + facing * CONSOLE_STEP + Vector3.new(0, SIGN_OVER_CONSOLE, 0),
			facing = facing,
			ceiling = roomHeight(roomAt(layout, anchor.pos)),
			width = SIGN_WIDTHS[kind],
		})
	end

	if bus then
		local busRoom = roomAt(layout, bus.entrance)
		if busRoom then
			overDoor("Sign_BusDoorway", "Bus", busRoom)
		end
		local back = -bus.cframe.XVector
		table.insert(out, {
			id = "Sign_BusRear",
			kind = "Bus",
			position = flat(bus.entrance) + Vector3.new(0, BUS_HEIGHT + SIGN_OVER_BUS, 0),
			facing = flat(back).Unit,
			ceiling = roomHeight(busRoom),
			width = SIGN_WIDTHS.Bus,
		})
	end
	atConsole("Sign_Difficulty", "Difficulty", terminals.Difficulty)
	local perks = anchorById(layout, terminals.Perks)
	local supplyRoom = if perks then roomAt(layout, perks.pos) else nil
	if supplyRoom then
		overDoor("Sign_SupplyDoor", "Supply", supplyRoom)
	end
	atConsole("Sign_Perks", "Supply", terminals.Perks)
	return out
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function detail(): Geometry.PartOptions
	return { canCollide = false, canQuery = false, castShadow = false }
end

local function buildChevron(model: Model, name: string, chevron: Chevron, origin: Vector3, glow: boolean): number
	local count = 0
	local tip = origin + chevron.position + Vector3.new(0, CHEVRON_THICKNESS / 2, 0)
	for index, side in { -1, 1 } do
		-- Each arm runs back from the tip, swept CHEVRON_HALF_ANGLE off the travel direction.
		local back = CFrame.fromAxisAngle(Vector3.yAxis, side * CHEVRON_HALF_ANGLE)
			:VectorToWorldSpace(-chevron.direction)
		local mid = tip + back * (CHEVRON_ARM / 2 - CHEVRON_WIDTH / 4)
		local options = detail()
		if glow then
			options.material = Enum.Material.Neon
			options.color = GLOW
		else
			options.material = Enum.Material.SmoothPlastic
			options.color = BONE_PAINT
		end
		local arm = Geometry.part(
			model,
			string.format("%s_%d", name, index),
			CFrame.lookAt(mid, mid + back),
			Vector3.new(CHEVRON_WIDTH, CHEVRON_THICKNESS, CHEVRON_ARM),
			"HazardYellow",
			options
		)
		Geometry.makeCosmetic(arm)
		count += 1
	end
	return count
end

local function paintSign(board: BasePart, kind: SignKind)
	local gui = SurfaceArt.gui(board, Enum.NormalId.Front, {
		name = "Stencil",
		pixelsPerStud = 20,
		lightInfluence = 0.35,
		brightness = 1.3,
		maxDistance = 140,
	})
	local keys = SIGN_TEXT[kind]
	SurfaceArt.outline(gui, "Border", 0.02, 0.06, 0.96, 0.88, BORDER, 2, 0.25)
	SurfaceArt.text(gui, "Title", Strings.get(keys[1]), 0.05, 0.1, 0.9, 0.52, STENCIL, Enum.Font.Oswald, 3)
	SurfaceArt.text(gui, "Sub", Strings.get(keys[2]), 0.1, 0.62, 0.8, 0.26, STENCIL_SUB, Enum.Font.SpecialElite, 3)
	SurfaceArt.grime(gui, GRIME, 0.5, false, 4)
end

local function buildSign(model: Model, sign: Sign, origin: Vector3): number
	local position = origin + sign.position
	local frame = CFrame.lookAt(position, position + sign.facing)
	local board =
		Geometry.part(model, sign.id, frame, Vector3.new(sign.width, SIGN_HEIGHT, SIGN_DEPTH), "SignMetal", detail())
	Geometry.makeCosmetic(board)
	paintSign(board, sign.kind)
	local count = 1
	local ceilingY = origin.Y + sign.ceiling
	for index, side in { -1, 1 } do
		local top = frame:PointToWorldSpace(Vector3.new(side * (sign.width / 2 - CHAIN_INSET), SIGN_HEIGHT / 2, 0))
		if ceilingY > top.Y + 0.05 then
			local chain = Geometry.cylinder(
				model,
				string.format("%s_Chain%d", sign.id, index),
				top,
				Vector3.new(top.X, ceilingY, top.Z),
				CHAIN_DIAMETER,
				"PipeIron",
				detail()
			)
			if chain then
				Geometry.makeCosmetic(chain)
				count += 1
			end
		end
	end
	return count
end

-- Builds the signs and the floor arrows into Model "Wayfinding" under `parent`. Returns the parts built.
function LobbySignage.build(layout: Layout, parent: Instance, origin: Vector3, bus: Bus?, terminals: Terminals): number
	local model = Instance.new("Model")
	model.Name = "Wayfinding"
	local count = 0
	local route = LobbySignage.route(layout, bus)
	for index, chevron in LobbySignage.chevrons(route, CHEVRON_SPACING, CHEVRON_START, CHEVRON_END) do
		count += buildChevron(model, string.format("Arrow_%02d", index), chevron, origin, true)
	end
	local start = route[1]
	if start then
		local stops: { { name: string, point: Vector3? } } = {
			{ name = "ToConsole", point = LobbySignage.consoleFront(layout, terminals.Difficulty) },
		}
		local perks = anchorById(layout, terminals.Perks)
		local fromRoom = roomAt(layout, start)
		local supplyRoom = if perks then roomAt(layout, perks.pos) else nil
		if fromRoom and supplyRoom and fromRoom ~= supplyRoom then
			local door, point, normal = crossing(layout, fromRoom, supplyRoom)
			if door then
				table.insert(stops, { name = "ToSupply", point = point - normal * DOOR_STEP })
			end
		end
		for _, stop in stops do
			local point = stop.point
			if point then
				local run = sideRun(start, point, SIDE_RUN)
				for index, chevron in LobbySignage.chevrons(run, CHEVRON_SPACING, 0, CHEVRON_END) do
					count += buildChevron(model, string.format("%s_%02d", stop.name, index), chevron, origin, false)
				end
			end
		end
	end
	for _, sign in LobbySignage.signs(layout, bus, terminals) do
		count += buildSign(model, sign, origin)
	end
	model.Parent = parent
	return count
end

return table.freeze(LobbySignage)
