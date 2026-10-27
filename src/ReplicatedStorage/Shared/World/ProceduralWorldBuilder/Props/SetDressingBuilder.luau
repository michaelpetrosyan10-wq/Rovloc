--!strict
-- SetDressingBuilder: the school's non-interactive dressing, built from the layouts' anchors and triggers.
--
-- Statics (server, once at boot, into <level>.Props; the same geometry on every server):
--   * LabCounter: chemistry lab islands. A cabinet base with doors on both faces, a dark epoxy worktop with a cup
--     sink and gooseneck faucet, gas taps, and a reagent shelf of jars and beakers (some smashed). The worktop is set
--     at the height of the FlaskCandidate anchors the layout stands on it, so every flask rests on the epoxy.
--   * SmashedLocker: a bank of 3-5 school lockers backed onto the wall behind the anchor: dented doors, doors torn off
--     or hanging from one hinge, sometimes one locker ripped out and dropped on its side, papers spilling out.
--   * DripPipe: an overhead pipe run under the room's ceiling through the anchor, a corroded leaking flange joint,
--     a "Drip" bead at the leak (tagged DripPipe, so AudioController gives it a looping drip voice) and a puddle on
--     the surface below. dripPoint() is the one answer to "where does the water fall from", shared with the
--     cosmetic drops.
--   * FloorDebris: broken glass, crushed cans, splinters (coal, plaster, jar lids where the trigger says so) strewn
--     over every FloorDebris and ScareStep trigger, flat and non-colliding, so players can see it in flashlight
--     light and pick their way round it.
-- Cosmetic anchors (client only, seeded per run):
--   * Corpse: a posed, decayed body of blocky parts in tattered school clothes (slumped against a wall, face down,
--     or curled on its side) over dried blood.
--   * Clutter: a seeded heap of papers, books, an overturned chair, a backpack, bottles and fallen ceiling tiles.
--   * DripPipe: falling drops (a default-texture ParticleEmitter) from dripPoint and faint ripple rings below.
--
-- Every builder plans its pieces before creating anything: shape, CFrame, size, palette and a collision role
-- ("Solid" pieces get Geometry.makePassthrough, so players bump into them and the Creature walks through; "Detail"
-- pieces get PropKit.detail; "Visible" pieces are seen and queried but never collide). A plan is checked against the
-- level's clearances: door openings and the arcs their leaves sweep, vent-grate fronts, airlocks and stair landings,
-- spawn points and the anchors gameplay props use, and (for solid pieces) the walking lane down every corridor.
-- Only a plan that fits is built. The same planning kit is exported (SetDressingBuilder.Kit) for the pool dressing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(script.Parent.Parent.Geometry)
local Palette = require(script.Parent.Parent.Palette)
local PropKit = require(script.Parent.PropKit)
local SchoolShellBuilder = require(script.Parent.Parent.SchoolShellBuilder)

local log = Log.new("SetDressing")

type Layout = LayoutSchema.LevelLayout
type Room = LayoutSchema.Room
type Rect = LayoutSchema.Rect
type Anchor = LayoutSchema.Anchor
type Trigger = LayoutSchema.Trigger

local W = Attributes.World

local EPS = 1e-3
local WALL_HALF = WorldConfig.WallThickness / 2
local EXTERIOR_HALF = WorldConfig.ExteriorWallThickness / 2
local HALF_BORE = WorldConfig.VentBore / 2

-- Clearances
local DOOR_TRIM = 0.35 -- the casing Geometry.doorTrims puts beside each jamb
local DOOR_PAD = 0.3
local PASSAGE_DEPTH = WALL_HALF + 1 -- the doorway itself: from the wall's centre plane this far into each room
local SWING_FLOOR = 0.3 -- door-swing arcs start above the floor (flat litter may lie under a leaf)
local GRATE_PAD = 0.45
local GRATE_FRONT = 3.5 -- clear floor in front of every grate, where crawlers climb out
local CORRIDOR_LANE = 3.3 -- solid dressing in a corridor stays within this of a long wall

-- Part budgets (hard caps per anchor / trigger)
local BUDGET = table.freeze({
	LabCounter = 26,
	SmashedLocker = 40,
	DripPipe = 16,
	FloorDebris = 24,
	Corpse = 26,
	Clutter = 20,
	DripCosmetic = 6,
})

-- Lab counters (Level2_ScienceHall: each LabCounter anchor is the floor centre of a 10 x 3.5 worktop whose long axis
-- runs along the anchor's RightVector; FlaskCandidate anchors stand on it at worktop height).
local COUNTER_LENGTH = 10
local COUNTER_DEPTH = 3.5
local DEFAULT_WORKTOP = 3.2 -- used only when no counter in the layout carries a flask to read the height from
local TOP_THICKNESS = 0.25
local PLINTH = 0.3
local CARCASS_INSET = 0.16
local LEAF = 0.06
local LEAF_WIDTH = 2.2 -- cupboard doors at both ends of each face; the knee space between them is panelled
local SINK_WIDTH = 1.3
local SINK_Z0, SINK_Z1 = -0.85, 0.4
local FLASK_CLEAR = 0.85 -- worktop items keep this far from a flask's foot
local FLASK_HEIGHT = 1.6

-- Smashed lockers (bank-local: X along the wall, -Z into the room, the wall face at z = 0)
local LOCKER_WIDTH = 1.25
local LOCKER_DEPTH = 1.5
local LOCKER_HEIGHT = 6.2
local LOCKER_PLINTH = 0.3
local LOCKER_CROWN = 0.55
local LOCKER_PANEL = 0.06
local DOOR_BOTTOM = LOCKER_PLINTH + 0.06
local DOOR_TOP = LOCKER_HEIGHT - 0.06

-- Drip pipes
local PIPE_DIAMETER = 0.6
local PIPE_DROP = 0.95 -- pipe centre below the ceiling underside (its flanges clear a fluorescent tube above)
local FLANGE_DIAMETER = 1.0
local FLANGE_THICKNESS = 0.16
local FLANGE_GAP = 0.06 -- the leak between the two flanges
local DRIP_BEAD = 0.16
local PIPE_HALF_SPAN = { 9, 13 }

-- Water
local WATER_COLOR = Palette.get("Water").color

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

-- "Solid": collides (players), Creature passes (Geometry.makePassthrough). "Visible": seen, queried and shadowed but
-- never collides. "Detail": PropKit.detail (no collision, no query, no shadow).
export type Role = "Solid" | "Visible" | "Detail"
export type Shape = "Block" | "Wedge" | "Cylinder" | "Ball"

export type Piece = {
	name: string,
	shape: Shape,
	cframe: CFrame, -- world
	size: Vector3,
	key: string, -- Palette key
	options: Geometry.PartOptions?,
	role: Role,
	label: string?, -- Strings key printed on the piece (SurfaceGui) on the face looking along labelNormal
	labelNormal: Vector3?,
}

-- An axis-aligned level-local box that dressing must stay out of.
export type Zone = {
	kind: string,
	x0: number,
	x1: number,
	z0: number,
	z1: number,
	y0: number,
	y1: number,
	solidOnly: boolean, -- applies only to Solid pieces (walking lanes)
	owner: string?, -- the anchor whose own dressing this zone reserves (that dressing ignores it)
}

export type Box = { x0: number, x1: number, z0: number, z1: number, y0: number, y1: number }

type RoomCache = {
	zones: { Zone },
	pillars: { Box },
	platforms: { Box },
	water: { Box }, -- open water (basin interiors) from the floor of the basin to its surface
}

export type LevelInfo = {
	layout: Layout,
	origin: Vector3,
	rooms: { [string]: Room },
	inner: { [string]: Rect }, -- room rects shrunk to their wall faces
	zones: { Zone },
	pillars: { Box },
	platforms: { Box },
	water: { Box },
	byRoom: { [string]: RoomCache },
}

export type FitOptions = {
	owner: string?, -- skip zones this owner reserved
	ignore: { [string]: boolean }?, -- zone kinds to skip
	room: string?, -- keep every piece inside this room's walls
	margin: number?, -- clearance from the walls (default 0.3)
	ground: number?, -- level-local Y the pieces rest on: obstacles above it reject, its surface must carry them
	contacts: { Box }?, -- level-local footprints that must be carried (default every piece's footprint)
}

type WallSide = {
	side: LayoutSchema.Side,
	axis: "X" | "Z", -- "Z": the wall runs along X at constant Z; "X": runs along Z at constant X
	line: number, -- wall centre line
	face: number, -- inner face coordinate
	normal: Vector3, -- into the room
}

export type Span = {
	frame: CFrame, -- level-local, on the floor at the wall face behind the anchor, LookVector into the room
	half: number, -- free half-width along the wall either side of the anchor
	wall: WallSide,
}

local SetDressingBuilder = {}
local Kit = {}

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function rx(degrees: number): CFrame
	return CFrame.Angles(math.rad(degrees), 0, 0)
end

local function ry(degrees: number): CFrame
	return CFrame.Angles(0, math.rad(degrees), 0)
end

local function rz(degrees: number): CFrame
	return CFrame.Angles(0, 0, math.rad(degrees))
end

-- Turns a part's X axis vertical: cylinders become discs, thin wedges lie flat as triangles.
local FLAT = rz(90)

local function between(random: Random, a: number, b: number): number
	return random:NextNumber(a, b)
end

local function chance(random: Random, p: number): boolean
	return random:NextNumber() < p
end

local function pick<T>(random: Random, list: { T }): T
	return list[random:NextInteger(1, #list)]
end

local function shuffled<T>(random: Random, list: { T }): { T }
	local out = table.clone(list)
	MathUtil.shuffle(out, random)
	return out
end

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local function tint(color: Color3, random: Random, amount: number): Color3
	local f = 1 + between(random, -amount, amount)
	return Color3.new(math.clamp(color.R * f, 0, 1), math.clamp(color.G * f, 0, 1), math.clamp(color.B * f, 0, 1))
end

local function paint(color: Color3, material: Enum.Material?, transparency: number?): Geometry.PartOptions
	return { color = color, material = material, transparency = transparency }
end

local function glass(color: Color3, transparency: number): Geometry.PartOptions
	return { color = color, material = Enum.Material.Glass, transparency = transparency, reflectance = 0.12 }
end

local function levelLocal(anchor: Anchor): CFrame
	return SchoolShellBuilder.anchorLocalCFrame(anchor)
end

local function boxOverlap(a: Box, b: Box, tolerance: number?): boolean
	local t = tolerance or 0.01
	return math.min(a.x1, b.x1) - math.max(a.x0, b.x0) > t
		and math.min(a.z1, b.z1) - math.max(a.z0, b.z0) > t
		and math.min(a.y1, b.y1) - math.max(a.y0, b.y0) > t
end

local function rectBox(r: Rect, y0: number, y1: number): Box
	return { x0 = r.x, x1 = r.x + r.w, z0 = r.z, z1 = r.z + r.d, y0 = y0, y1 = y1 }
end

-- The anchor's facing snapped to the nearest axis (lockers and walls are axis-aligned).
local function snappedLook(yaw: number): Vector3
	local look = ry(yaw).LookVector
	if math.abs(look.X) > math.abs(look.Z) then
		return Vector3.new(if look.X > 0 then 1 else -1, 0, 0)
	end
	return Vector3.new(0, 0, if look.Z > 0 then 1 else -1)
end

-- Degrees of yaw whose LookVector is `normal`.
local function yawOf(normal: Vector3): number
	return math.deg(math.atan2(-normal.X, -normal.Z))
end

--------------------------------------------------------------------------------
-- Pieces
--------------------------------------------------------------------------------

function Kit.block(
	name: string,
	cframe: CFrame,
	size: Vector3,
	key: string,
	role: Role,
	options: Geometry.PartOptions?
): Piece
	return { name = name, shape = "Block", cframe = cframe, size = size, key = key, role = role, options = options }
end

-- An axis-aligned box in `frame`'s space between two local corners.
function Kit.box(
	frame: CFrame,
	name: string,
	lo: Vector3,
	hi: Vector3,
	key: string,
	role: Role,
	options: Geometry.PartOptions?
): Piece
	local a, b = lo:Min(hi), lo:Max(hi)
	return Kit.block(name, frame * CFrame.new((a + b) / 2), b - a, key, role, options)
end

function Kit.wedge(
	name: string,
	cframe: CFrame,
	size: Vector3,
	key: string,
	role: Role,
	options: Geometry.PartOptions?
): Piece
	return { name = name, shape = "Wedge", cframe = cframe, size = size, key = key, role = role, options = options }
end

function Kit.ball(
	name: string,
	centre: Vector3,
	diameter: number,
	key: string,
	role: Role,
	options: Geometry.PartOptions?
): Piece
	return {
		name = name,
		shape = "Ball",
		cframe = CFrame.new(centre),
		size = Vector3.one * diameter,
		key = key,
		role = role,
		options = options,
	}
end

-- A cylinder whose axis runs from world point `a` to `b` (Part.Shape Cylinder runs along local X).
function Kit.cylinder(
	name: string,
	a: Vector3,
	b: Vector3,
	diameter: number,
	key: string,
	role: Role,
	options: Geometry.PartOptions?
): Piece
	local delta = b - a
	local length = math.max(delta.Magnitude, EPS * 10)
	local axis = if delta.Magnitude > EPS then delta / delta.Magnitude else Vector3.xAxis
	local helper = if math.abs(axis.Y) > 0.95 then Vector3.xAxis else Vector3.yAxis
	local up = (helper - axis * helper:Dot(axis)).Unit
	return {
		name = name,
		shape = "Cylinder",
		cframe = CFrame.fromMatrix((a + b) / 2, axis, up),
		size = Vector3.new(length, diameter, diameter),
		key = key,
		role = role,
		options = options,
	}
end

-- A flat disc lying on the plane through world point `centre` (its bottom face), `thickness` tall.
function Kit.disc(
	name: string,
	centre: Vector3,
	diameter: number,
	thickness: number,
	key: string,
	role: Role,
	options: Geometry.PartOptions?
): Piece
	return {
		name = name,
		shape = "Cylinder",
		cframe = CFrame.new(centre + Vector3.new(0, thickness / 2, 0)) * FLAT,
		size = Vector3.new(thickness, diameter, diameter),
		key = key,
		role = role,
		options = options,
	}
end

-- World-space bounding box of a piece (conservative for wedges and cylinders).
function Kit.bounds(piece: Piece): (Vector3, Vector3)
	local cf = piece.cframe
	local half = piece.size / 2
	if piece.shape == "Ball" then
		local r = math.min(half.X, half.Y, half.Z)
		return cf.Position - Vector3.one * r, cf.Position + Vector3.one * r
	end
	local rx_, ry_, rz_ = cf.RightVector, cf.UpVector, cf.LookVector
	local extent = Vector3.new(
		math.abs(rx_.X) * half.X + math.abs(ry_.X) * half.Y + math.abs(rz_.X) * half.Z,
		math.abs(rx_.Y) * half.X + math.abs(ry_.Y) * half.Y + math.abs(rz_.Y) * half.Z,
		math.abs(rx_.Z) * half.X + math.abs(ry_.Z) * half.Y + math.abs(rz_.Z) * half.Z
	)
	return cf.Position - extent, cf.Position + extent
end

-- Level-local bounding box of a piece.
function Kit.localBox(info: LevelInfo, piece: Piece): Box
	local lo, hi = Kit.bounds(piece)
	lo -= info.origin
	hi -= info.origin
	return { x0 = lo.X, x1 = hi.X, z0 = lo.Z, z1 = hi.Z, y0 = lo.Y, y1 = hi.Y }
end

-- Moves every piece rigidly by `delta` (world, applied before the pieces' own rotation).
function Kit.offset(pieces: { Piece }, delta: Vector3)
	for _, piece in pieces do
		piece.cframe = piece.cframe + delta
	end
end

-- Applies `transform` (world) to every piece.
function Kit.transform(pieces: { Piece }, transform: CFrame)
	for _, piece in pieces do
		piece.cframe = transform * piece.cframe
	end
end

local function surfaceLabel(part: BasePart, key: string, normal: Vector3)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Label"
	local cf = part.CFrame
	local faces: { { face: Enum.NormalId, normal: Vector3 } } = {
		{ face = Enum.NormalId.Front, normal = cf.LookVector },
		{ face = Enum.NormalId.Back, normal = -cf.LookVector },
		{ face = Enum.NormalId.Right, normal = cf.RightVector },
		{ face = Enum.NormalId.Left, normal = -cf.RightVector },
		{ face = Enum.NormalId.Top, normal = cf.UpVector },
		{ face = Enum.NormalId.Bottom, normal = -cf.UpVector },
	}
	local best, bestDot = Enum.NormalId.Front, -math.huge
	for _, entry in faces do
		local dot = entry.normal:Dot(normal)
		if dot > bestDot then
			best, bestDot = entry.face, dot
		end
	end
	gui.Face = best
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 1
	gui.MaxDistance = 40
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.24)
	label.Size = UDim2.fromScale(0.84, 0.16)
	label.BackgroundColor3 = rgb(122, 104, 42)
	label.BackgroundTransparency = 0.15
	label.BorderSizePixel = 0
	label.TextColor3 = rgb(26, 22, 14)
	label.FontFace = Font.fromEnum(Enum.Font.SpecialElite)
	label.TextScaled = true
	label.Text = Strings.get(key)
	label.Parent = gui
	gui.Parent = part
end

-- Creates every piece under `parent` (Geometry factory, then the role's collision preset). Returns the parts.
function Kit.realize(parent: Instance, pieces: { Piece }): { BasePart }
	local out: { BasePart } = {}
	for _, piece in pieces do
		local base = piece.options
		local options: Geometry.PartOptions = {
			shape = if piece.shape == "Cylinder"
				then Enum.PartType.Cylinder
				elseif piece.shape == "Ball" then Enum.PartType.Ball
				else nil,
			transparency = base and base.transparency,
			material = base and base.material,
			color = base and base.color,
			reflectance = base and base.reflectance,
			castShadow = base and base.castShadow,
		}
		local part: BasePart = if piece.shape == "Wedge"
			then Geometry.wedge(parent, piece.name, piece.cframe, piece.size, piece.key, options)
			else Geometry.part(parent, piece.name, piece.cframe, piece.size, piece.key, options)
		if piece.role == "Solid" then
			Geometry.makePassthrough(part)
		elseif piece.role == "Detail" then
			PropKit.detail(part)
		else
			part.CanCollide = false
			part.CanQuery = true
		end
		local key = piece.label
		if key then
			surfaceLabel(part, key, piece.labelNormal or part.CFrame.LookVector)
		end
		table.insert(out, part)
	end
	return out
end

--------------------------------------------------------------------------------
-- Layout data
--------------------------------------------------------------------------------

local layoutCache: { [string]: Layout } = {}

-- The layout module for `layoutId` (Layouts/<id>), loaded once. Cosmetic builders and dripPoint() only get an
-- anchor, so they find its level here.
local function loadLayout(layoutId: string): Layout?
	local cached = layoutCache[layoutId]
	if cached then
		return cached
	end
	local folder = script.Parent.Parent:FindFirstChild("Layouts")
	local module = if folder then folder:FindFirstChild(layoutId) else nil
	if not (module and module:IsA("ModuleScript")) then
		return nil
	end
	local loaded: Layout? = nil
	xpcall(function()
		loaded = (require(module) :: any) :: Layout
	end, function(err: any)
		log.error("layout %s failed to load: %s", layoutId, tostring(err))
	end)
	local layout = loaded
	if layout then
		layoutCache[layoutId] = layout
	end
	return layout
end

-- The layout a cosmetic anchor belongs to, from the world CFrame the builder was handed (origin = cframe - pos).
local function layoutOfAnchor(anchor: Anchor, cframe: CFrame): Layout?
	local origin = cframe.Position - anchor.pos
	for _, id: Enums.LayoutId in Enums.LayoutId do
		if (WorldConfig.levelOrigin(id) - origin).Magnitude < 0.05 then
			local layout = loadLayout(id)
			if layout then
				for _, entry in layout.anchors do
					if entry.id == anchor.id then
						return layout
					end
				end
			end
			return nil
		end
	end
	return nil
end

local function innerRects(layout: Layout): { [string]: Rect }
	local sides = SchoolShellBuilder.exteriorSides(layout)
	local out: { [string]: Rect } = {}
	for _, room in layout.rooms do
		local s = sides[room.id]
		local function inset(side: string): number
			return if s ~= nil and s[side] == true then EXTERIOR_HALF else WALL_HALF
		end
		local r = room.rect
		local x0, x1 = r.x + inset("W"), r.x + r.w - inset("E")
		local z0, z1 = r.z + inset("N"), r.z + r.d - inset("S")
		out[room.id] = { x = x0, z = z0, w = math.max(0, x1 - x0), d = math.max(0, z1 - z0) }
	end
	return out
end

local function sideBehind(room: Room, inner: Rect, normal: Vector3): WallSide
	local r = room.rect
	if normal.Z > 0.5 then
		return { side = "N", axis = "Z", line = r.z, face = inner.z, normal = normal }
	elseif normal.Z < -0.5 then
		return { side = "S", axis = "Z", line = r.z + r.d, face = inner.z + inner.d, normal = normal }
	elseif normal.X > 0.5 then
		return { side = "W", axis = "X", line = r.x, face = inner.x, normal = normal }
	end
	return { side = "E", axis = "X", line = r.x + r.w, face = inner.x + inner.w, normal = normal }
end

local function along(wall: WallSide, x: number, z: number): number
	return if wall.axis == "Z" then x else z
end

local function across(wall: WallSide, x: number, z: number): number
	return if wall.axis == "Z" then z else x
end

-- Lab counter flasks: FlaskCandidate anchors standing on the worktop of `anchor`, in counter-local space.
local function counterFlasks(layout: Layout, anchor: Anchor): { Vector3 }
	local frame = levelLocal(anchor)
	local out: { Vector3 } = {}
	for _, other in layout.anchors do
		if other.kind ~= "FlaskCandidate" or other.room ~= anchor.room then
			continue
		end
		local p = frame:PointToObjectSpace(other.pos)
		if
			math.abs(p.X) <= COUNTER_LENGTH / 2 - 0.2
			and math.abs(p.Z) <= COUNTER_DEPTH / 2 - 0.2
			and p.Y > 1
			and p.Y < 6
		then
			table.insert(out, p)
		end
	end
	return out
end

-- Worktop height above the counter's floor: the height of the flasks it carries (the layout's WORKTOP); counters
-- without flasks match the other counters of the layout.
local function counterTop(layout: Layout, anchor: Anchor): number
	local flasks = counterFlasks(layout, anchor)
	if #flasks > 0 then
		return flasks[1].Y
	end
	for _, other in layout.anchors do
		if other.kind == "LabCounter" then
			local list = counterFlasks(layout, other)
			if #list > 0 then
				return list[1].Y
			end
		end
	end
	return DEFAULT_WORKTOP
end

-- The free stretch of wall behind a SmashedLocker anchor: doors (with their casings), grates, low windows, hideable
-- lockers, pillars, plant and the neighbouring banks all stop it. Pure layout maths, shared by the bank builder and
-- the clearance zone that keeps other dressing off the bank.
local function lockerSpan(layout: Layout, rooms: { [string]: Room }, inner: { [string]: Rect }, anchor: Anchor): Span?
	local room = rooms[anchor.room]
	local face = inner[anchor.room]
	if not (room and face) then
		return nil
	end
	local wall = sideBehind(room, face, snappedLook(anchor.yaw or 0))
	local u = along(wall, anchor.pos.X, anchor.pos.Z)
	local lo = (if wall.axis == "Z" then face.x else face.z) + 0.1
	local hi = (if wall.axis == "Z" then face.x + face.w else face.z + face.d) - 0.1
	local blocked: { { number } } = {}
	local reach = LOCKER_DEPTH + CORRIDOR_LANE + 0.5
	local function inBand(c0: number, c1: number): boolean
		local a0 = math.min(wall.face, wall.face + (if wall.side == "N" or wall.side == "W" then reach else -reach))
		local a1 = math.max(wall.face, wall.face + (if wall.side == "N" or wall.side == "W" then reach else -reach))
		return math.min(c1, a1) - math.max(c0, a0) > EPS
	end
	for _, door in layout.doors do
		if door.rooms[1] ~= room.id and door.rooms[2] ~= room.id then
			continue
		end
		local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
		local edge = if a and b then LayoutSchema.sharedEdge(a.rect, b.rect) else nil
		if edge and edge.axis == wall.axis and math.abs(edge.coord - wall.line) < EPS then
			local half = LayoutSchema.doorWidth(door) / 2 + DOOR_TRIM + 0.35
			table.insert(blocked, { door.at - half, door.at + half })
		end
	end
	local vents = layout.vents
	if vents then
		local nodes: { [string]: LayoutSchema.VentNodeSpec } = {}
		for _, node in vents.nodes do
			nodes[node.id] = node
		end
		for _, grate in vents.grates do
			local node = nodes[grate.node]
			if grate.room == room.id and node and LayoutSchema.sideOfPoint(room.rect, node.x, node.z) == wall.side then
				local c = along(wall, node.x, node.z)
				table.insert(blocked, { c - HALF_BORE - 0.6, c + HALF_BORE + 0.6 })
			end
		end
	end
	for _, window in (layout.windows or {}) :: { LayoutSchema.Window } do
		if window.room == room.id and window.side == wall.side and window.sill < LOCKER_HEIGHT + LOCKER_CROWN + 0.4 then
			table.insert(blocked, { window.at - window.width / 2 - 0.25, window.at + window.width / 2 + 0.25 })
		end
	end
	for _, other in layout.anchors do
		if other == anchor or other.room ~= room.id then
			continue
		end
		local c = across(wall, other.pos.X, other.pos.Z)
		local o = along(wall, other.pos.X, other.pos.Z)
		if other.kind == "SmashedLocker" and snappedLook(other.yaw or 0):FuzzyEq(wall.normal, 1e-3) then
			if math.abs(c - across(wall, anchor.pos.X, anchor.pos.Z)) < 1.5 then
				local mid = (o + u) / 2
				table.insert(blocked, { mid - 0.1, mid + 0.1 })
			end
		elseif other.kind == "Locker" and inBand(c - 1.5, c + 1.5) then
			table.insert(blocked, { o - 1.7, o + 1.7 })
		end
	end
	for _, pillar in (layout.pillars or {}) :: { LayoutSchema.Pillar } do
		if pillar.room == room.id then
			local c = across(wall, pillar.x, pillar.z)
			if inBand(c - pillar.size / 2, c + pillar.size / 2) then
				local o = along(wall, pillar.x, pillar.z)
				table.insert(blocked, { o - pillar.size / 2 - 0.3, o + pillar.size / 2 + 0.3 })
			end
		end
	end
	for _, platform in (layout.platforms or {}) :: { LayoutSchema.Platform } do
		if platform.room == room.id and platform.top > 0.1 then
			local r = platform.rect
			local c0 = if wall.axis == "Z" then r.z else r.x
			local c1 = c0 + (if wall.axis == "Z" then r.d else r.w)
			if inBand(c0, c1) then
				local o0 = if wall.axis == "Z" then r.x else r.z
				local o1 = o0 + (if wall.axis == "Z" then r.w else r.d)
				table.insert(blocked, { o0 - 0.3, o1 + 0.3 })
			end
		end
	end
	for _, interval in blocked do
		if interval[1] <= u and interval[2] >= u then
			return nil
		end
		if interval[2] < u then
			lo = math.max(lo, interval[2])
		else
			hi = math.min(hi, interval[1])
		end
	end
	local half = math.min(u - lo, hi - u)
	if half <= 0 then
		return nil
	end
	local position = if wall.axis == "Z"
		then Vector3.new(u, anchor.pos.Y, wall.face)
		else Vector3.new(wall.face, anchor.pos.Y, u)
	return { frame = CFrame.lookAt(position, position + wall.normal), half = half, wall = wall }
end

--------------------------------------------------------------------------------
-- Level info: clearance zones, obstacles, supports (cached per layout table)
--------------------------------------------------------------------------------

type AnchorClear = { half: number, back: number?, front: number?, y0: number, y1: number, owned: boolean? }

-- Space kept clear around anchors that gameplay uses (heights relative to the anchor; back / front extend the box
-- behind / ahead of the anchor's facing instead of `half`).
local ANCHOR_CLEAR: { [string]: AnchorClear } = {
	PlayerSpawn = { half = 3, y0 = -4, y1 = 4 },
	CreatureSpawn = { half = 2.5, y0 = -5.5, y1 = 4 },
	CreatureScarePose = { half = 3, y0 = -5.5, y1 = 4 },
	TrapCandidate = { half = 1.4, y0 = -0.3, y1 = 1.5 },
	BatteryCandidate = { half = 1.2, y0 = -0.3, y1 = 1.5 },
	FlaskCandidate = { half = FLASK_CLEAR, y0 = 0, y1 = FLASK_HEIGHT },
	Locker = { half = 1.6, back = 1.5, front = 4.1, y0 = -0.3, y1 = 8 },
	ParachuteCrate = { half = 3.5, y0 = -0.3, y1 = 5 },
	FloodlightSwitch = { half = 1.6, back = 1, front = 3.2, y0 = -4.3, y1 = 3.5 },
	ReadyPad = { half = 3, y0 = -0.3, y1 = 7 },
	Terminal = { half = 2.2, back = 1.5, front = 3.2, y0 = -0.3, y1 = 6 },
	Corpse = { half = 2.6, y0 = -0.3, y1 = 3, owned = true },
	Clutter = { half = 2, y0 = -0.3, y1 = 2.5, owned = true },
}

-- Statics are fixed; the client dressing (corpses, clutter) arranges itself around them, so statics ignore the
-- spots reserved for it.
local STATIC_IGNORE: { [string]: boolean } = { CorpseSpot = true, ClutterSpot = true }

local ZONE_KIND: { [string]: string } = {
	Corpse = "CorpseSpot",
	Clutter = "ClutterSpot",
}

local function addZone(
	list: { Zone },
	kind: string,
	x0: number,
	x1: number,
	z0: number,
	z1: number,
	y0: number,
	y1: number,
	solidOnly: boolean?,
	owner: string?
)
	table.insert(list, {
		kind = kind,
		x0 = math.min(x0, x1),
		x1 = math.max(x0, x1),
		z0 = math.min(z0, z1),
		z1 = math.max(z0, z1),
		y0 = y0,
		y1 = y1,
		solidOnly = solidOnly == true,
		owner = owner,
	})
end

-- A wall-local box (u along the wall, a across it from the centre line) as a zone.
local function wallZone(
	list: { Zone },
	kind: string,
	axis: "X" | "Z",
	coord: number,
	u0: number,
	u1: number,
	a0: number,
	a1: number,
	y0: number,
	y1: number
)
	if axis == "X" then
		addZone(list, kind, coord + a0, coord + a1, u0, u1, y0, y1)
	else
		addZone(list, kind, u0, u1, coord + a0, coord + a1, y0, y1)
	end
end

-- An anchor-oriented box (x across the facing, z along it) as a zone.
local function anchorZone(
	list: { Zone },
	kind: string,
	frame: CFrame,
	x0: number,
	x1: number,
	z0: number,
	z1: number,
	y0: number,
	y1: number,
	owner: string?
)
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, corner in { Vector3.new(x0, 0, z0), Vector3.new(x1, 0, z0), Vector3.new(x0, 0, z1), Vector3.new(x1, 0, z1) } do
		local p = frame:PointToWorldSpace(corner)
		lo, hi = lo:Min(p), hi:Max(p)
	end
	addZone(list, kind, lo.X, hi.X, lo.Z, hi.Z, frame.Position.Y + y0, frame.Position.Y + y1, false, owner)
end

-- How far either side of the wall a door's leaf may sweep (or its approach is kept clear), and the zone kind:
-- "DoorSwing" for the ordinary classroom doors DoorBuilder stands open once at boot (it fits each leaf round the
-- statics already built, so the furniture a layout stands on fixed anchors may stay), "FixtureSwing" for the leaves
-- that move during a run, "DoorApproach" for openings without a leaf.
local function swingDepth(door: LayoutSchema.Door): (number, string)
	local width = LayoutSchema.doorWidth(door)
	if door.kind == "Door" then
		return WALL_HALF + width + 0.4, "DoorSwing"
	elseif door.kind == "Ajar" or door.kind == "RoofDoor" then
		return WALL_HALF + width + 0.4, "FixtureSwing"
	elseif door.kind == "Airlock" then
		return WALL_HALF + width / 2 + 0.6, "FixtureSwing"
	end
	return WALL_HALF + 2.5, "DoorApproach" -- doorways, rolling gates, boarded openings: keep the approach clear
end

local function buildZones(layout: Layout, rooms: { [string]: Room }, inner: { [string]: Rect }): { Zone }
	local zones: { Zone } = {}
	-- Doors: the opening itself, then the arc a leaf sweeps (or the approach to an open doorway)
	for _, door in layout.doors do
		local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
		local edge = if a and b then LayoutSchema.sharedEdge(a.rect, b.rect) else nil
		if not edge then
			continue
		end
		local half = LayoutSchema.doorWidth(door) / 2 + DOOR_TRIM + DOOR_PAD
		local height = LayoutSchema.doorHeight(door) + 0.5
		local u0, u1 = door.at - half, door.at + half
		wallZone(zones, "DoorPassage", edge.axis, edge.coord, u0, u1, -PASSAGE_DEPTH, PASSAGE_DEPTH, -1, height)
		local swing, swingKind = swingDepth(door)
		wallZone(zones, swingKind, edge.axis, edge.coord, u0, u1, -swing, swing, SWING_FLOOR, height)
	end
	-- Vent grates: the opening and the floor in front of it on the room side
	local vents = layout.vents
	if vents then
		local nodes: { [string]: LayoutSchema.VentNodeSpec } = {}
		for _, node in vents.nodes do
			nodes[node.id] = node
		end
		for _, grate in vents.grates do
			local node, room = nodes[grate.node], rooms[grate.room]
			if not (node and room) then
				continue
			end
			local side = LayoutSchema.sideOfPoint(room.rect, node.x, node.z)
			if not side then
				continue
			end
			local y = LayoutSchema.ventNodeY(node)
			local reach = WALL_HALF + GRATE_FRONT
			local inward = if side == "N" or side == "W" then 1 else -1
			local axis: "X" | "Z" = if side == "N" or side == "S" then "Z" else "X"
			local coord = if axis == "Z" then node.z else node.x
			local u = if axis == "Z" then node.x else node.z
			wallZone(
				zones,
				"Grate",
				axis,
				coord,
				u - HALF_BORE - GRATE_PAD,
				u + HALF_BORE + GRATE_PAD,
				math.min(0, inward * reach),
				math.max(0, inward * reach),
				math.min(0, y - HALF_BORE - 0.5) - 0.5,
				y + HALF_BORE + 0.6
			)
		end
	end
	-- Airlocks and stair landings, whole; the walking lane down every corridor (solid dressing only)
	for _, room in layout.rooms do
		local r = inner[room.id]
		local height = LayoutSchema.roomHeight(layout, room)
		if room.kind == "Airlock" or room.kind == "Stairwell" then
			addZone(
				zones,
				"Landing",
				room.rect.x,
				room.rect.x + room.rect.w,
				room.rect.z,
				room.rect.z + room.rect.d,
				-1,
				height + 1
			)
		elseif room.kind == "Corridor" and r then
			if r.w >= r.d and r.d > CORRIDOR_LANE * 2 then
				addZone(zones, "Lane", r.x, r.x + r.w, r.z + CORRIDOR_LANE, r.z + r.d - CORRIDOR_LANE, -0.5, 8, true)
			elseif r.d > r.w and r.w > CORRIDOR_LANE * 2 then
				addZone(zones, "Lane", r.x + CORRIDOR_LANE, r.x + r.w - CORRIDOR_LANE, r.z, r.z + r.d, -0.5, 8, true)
			end
		end
	end
	-- Anchors gameplay uses, and the footprints of the statics built from anchors
	for _, anchor in layout.anchors do
		local frame = levelLocal(anchor)
		local clear = ANCHOR_CLEAR[anchor.kind]
		if clear then
			local kind = ZONE_KIND[anchor.kind] or anchor.kind
			local owner = if clear.owned then anchor.id else nil
			if clear.front or clear.back then
				anchorZone(
					zones,
					kind,
					frame,
					-clear.half,
					clear.half,
					-(clear.front or clear.half),
					clear.back or clear.half,
					clear.y0,
					clear.y1,
					owner
				)
			else
				anchorZone(
					zones,
					kind,
					frame,
					-clear.half,
					clear.half,
					-clear.half,
					clear.half,
					clear.y0,
					clear.y1,
					owner
				)
			end
		elseif anchor.kind == "LabCounter" then
			-- The island, and the arc its cupboard doors may hang open through (flat litter may lie under a leaf)
			local top = counterTop(layout, anchor)
			local hl, hd = COUNTER_LENGTH / 2 + 0.2, COUNTER_DEPTH / 2 + 0.2
			anchorZone(zones, "Counter", frame, -hl, hl, -hd, hd, -0.3, top + 2.3, anchor.id)
			local reach = hd + LEAF_WIDTH
			anchorZone(zones, "CounterSwing", frame, -hl, hl, -reach, reach, SWING_FLOOR, top, anchor.id)
		elseif anchor.kind == "SmashedLocker" then
			local span = lockerSpan(layout, rooms, inner, anchor)
			if span then
				local half = math.min(span.half, LOCKER_HEIGHT / 2 + 0.6)
				anchorZone(
					zones,
					"LockerBank",
					span.frame,
					-half,
					half,
					-CORRIDOR_LANE,
					0,
					-0.3,
					LOCKER_HEIGHT + LOCKER_CROWN + 0.3,
					anchor.id
				)
			end
		end
	end
	return zones
end

local infoCache: { [Layout]: LevelInfo } = setmetatable({}, { __mode = "k" }) :: any

-- Clearances, obstacles and supports of one layout (cached).
function Kit.info(layout: Layout): LevelInfo
	local cached = infoCache[layout]
	if cached then
		return cached
	end
	local rooms = LayoutSchema.indexRooms(layout)
	local inner = innerRects(layout)
	local pillars: { Box } = {}
	for _, pillar in (layout.pillars or {}) :: { LayoutSchema.Pillar } do
		local room = rooms[pillar.room]
		local top = if room then SchoolShellBuilder.ceilingBottom(layout, room) else layout.height
		local h = pillar.size / 2 + 0.3 -- the base trims stand proud of the column
		table.insert(
			pillars,
			{ x0 = pillar.x - h, x1 = pillar.x + h, z0 = pillar.z - h, z1 = pillar.z + h, y0 = 0, y1 = top }
		)
	end
	local platforms: { Box } = {}
	for _, platform in (layout.platforms or {}) :: { LayoutSchema.Platform } do
		table.insert(platforms, rectBox(platform.rect, platform.top - platform.thickness, platform.top))
	end
	local water: { Box } = {}
	for _, basin in (layout.basins or {}) :: { LayoutSchema.Basin } do
		table.insert(water, rectBox(Geometry.insetRect(basin.rect, Geometry.BasinWall), -basin.depth, basin.waterLevel))
	end
	local info: LevelInfo = {
		layout = layout,
		origin = WorldConfig.levelOrigin(layout.id),
		rooms = rooms,
		inner = inner,
		zones = buildZones(layout, rooms, inner),
		pillars = pillars,
		platforms = platforms,
		water = water,
		byRoom = {},
	}
	infoCache[layout] = info
	return info
end

-- Zones, pillars, platforms and water touching one room (a room-sized window over the level lists).
local function roomCache(info: LevelInfo, roomId: string): RoomCache?
	local cached = info.byRoom[roomId]
	if cached then
		return cached
	end
	local room = info.rooms[roomId]
	if not room then
		return nil
	end
	local window = rectBox(room.rect, -1e4, 1e4)
	window.x0 -= 1
	window.z0 -= 1
	window.x1 += 1
	window.z1 += 1
	local function within(list: { any }): { any }
		local out = {}
		for _, entry in list do
			if boxOverlap(entry :: Box, window, -1) then
				table.insert(out, entry)
			end
		end
		return out
	end
	local entry: RoomCache = {
		zones = within(info.zones) :: { Zone },
		pillars = within(info.pillars) :: { Box },
		platforms = within(info.platforms) :: { Box },
		water = within(info.water) :: { Box },
	}
	info.byRoom[roomId] = entry
	return entry
end

-- True when the level-local footprint point (x, z) is carried at height `ground` in `cache`'s room: a platform top
-- there, or the floor (y 0) where no pool water is.
local function carried(cache: RoomCache, room: Room, x: number, z: number, ground: number): boolean
	for _, platform in cache.platforms do
		if x >= platform.x0 - EPS and x <= platform.x1 + EPS and z >= platform.z0 - EPS and z <= platform.z1 + EPS then
			if math.abs(platform.y1 - ground) <= 0.2 then
				return true
			end
		end
	end
	if math.abs(ground) > 0.2 then
		return false
	end
	if not LayoutSchema.rectContains(room.rect, x, z) then
		return false
	end
	for _, pool in cache.water do
		if x > pool.x0 + EPS and x < pool.x1 - EPS and z > pool.z0 + EPS and z < pool.z1 - EPS then
			return false
		end
	end
	return true
end

-- Whether `pieces` (world) clear every zone (and, with options.room, stay in that room on carried ground).
function Kit.fits(info: LevelInfo, pieces: { Piece }, options: FitOptions?): boolean
	local o: FitOptions = options or {}
	local roomId = o.room
	local room = if roomId then info.rooms[roomId] else nil
	local inner = if roomId then info.inner[roomId] else nil
	local cache = if roomId then roomCache(info, roomId) else nil
	local zones: { Zone } = if cache then cache.zones else info.zones
	local margin = o.margin or 0.3
	local ground = o.ground
	local ignore = o.ignore
	for _, piece in pieces do
		local box = Kit.localBox(info, piece)
		for _, zone in zones do
			if zone.solidOnly and piece.role ~= "Solid" then
				continue
			end
			if (o.owner and zone.owner == o.owner) or (ignore and ignore[zone.kind]) then
				continue
			end
			if boxOverlap(box, zone :: any) then
				return false
			end
		end
		if inner then
			if
				box.x0 < inner.x + margin
				or box.x1 > inner.x + inner.w - margin
				or box.z0 < inner.z + margin
				or box.z1 > inner.z + inner.d - margin
			then
				return false
			end
		end
		if cache and ground then
			for _, pillar in cache.pillars do
				if boxOverlap(box, pillar) then
					return false
				end
			end
			for _, platform in cache.platforms do
				if platform.y1 > ground + 0.15 and boxOverlap(box, platform) then
					return false
				end
			end
		end
	end
	if room and cache and ground then
		local contacts = o.contacts
		local list: { Box } = {}
		if contacts then
			list = contacts
		else
			for _, piece in pieces do
				table.insert(list, Kit.localBox(info, piece))
			end
		end
		for _, footprint in list do
			local cx, cz = (footprint.x0 + footprint.x1) / 2, (footprint.z0 + footprint.z1) / 2
			for _, point in
				{
					{ footprint.x0, footprint.z0 },
					{ footprint.x1, footprint.z0 },
					{ footprint.x0, footprint.z1 },
					{ footprint.x1, footprint.z1 },
					{ cx, cz },
				} :: { { number } }
			do
				if not carried(cache, room, point[1], point[2], ground) then
					return false
				end
			end
		end
	end
	return true
end

-- Whether two pieces' bounding boxes overlap.
local function piecesOverlap(info: LevelInfo, a: { Piece }, b: { Piece }): boolean
	for _, p in a do
		local pa = Kit.localBox(info, p)
		for _, q in b do
			if boxOverlap(pa, Kit.localBox(info, q), 0.005) then
				return true
			end
		end
	end
	return false
end

-- Lowest point of a set of pieces (world Y).
local function lowest(pieces: { Piece }): number
	local y = math.huge
	for _, piece in pieces do
		local lo = Kit.bounds(piece)
		y = math.min(y, lo.Y)
	end
	return y
end

local function stamp(model: Model, info: LevelInfo, values: { [string]: any })
	model:SetAttribute(W.LevelId, info.layout.id)
	PropKit.setAttributes(model, values)
end

--------------------------------------------------------------------------------
-- Lab counters
--------------------------------------------------------------------------------

local CASEWORK: { { body: Color3, leaf: Color3, material: Enum.Material } } = {
	{ body = rgb(70, 54, 40), leaf = rgb(82, 64, 46), material = Enum.Material.Wood },
	{ body = rgb(62, 70, 66), leaf = rgb(72, 80, 76), material = Enum.Material.Metal },
	{ body = rgb(78, 74, 62), leaf = rgb(88, 84, 70), material = Enum.Material.Metal },
}

local EPOXY = paint(rgb(28, 30, 29), Enum.Material.SmoothPlastic)
local STEEL = { color = rgb(96, 100, 98), material = Enum.Material.Metal, reflectance = 0.08 }
local BRASS = paint(rgb(104, 88, 52), Enum.Material.Metal)
local VOID = paint(rgb(16, 16, 15), Enum.Material.SmoothPlastic)

local REAGENTS: { { color: Color3, transparency: number, d: number, h: number } } = {
	{ color = rgb(74, 48, 30), transparency = 0.15, d = 0.34, h = 0.72 }, -- brown reagent bottle
	{ color = rgb(80, 96, 70), transparency = 0.35, d = 0.55, h = 0.58 }, -- murky jar
	{ color = rgb(132, 140, 136), transparency = 0.55, d = 0.46, h = 0.5 }, -- beaker
	{ color = rgb(58, 70, 84), transparency = 0.3, d = 0.3, h = 0.85 }, -- tall cobalt bottle
}

-- The island's body keeps the footprint the layout gives it, even where an ordinary classroom door's swing box
-- reaches it (DoorBuilder hangs that leaf round the built island); a cupboard door hanging open must clear everything.
local COUNTER_IGNORE: { [string]: boolean } = { CorpseSpot = true, ClutterSpot = true, DoorSwing = true }
local COUNTER_PROBE_IGNORE: { [string]: boolean } =
	{ FlaskCandidate = true, CorpseSpot = true, ClutterSpot = true, DoorSwing = true }

-- One lab island. Counter-local frame: X along the worktop (the anchor's RightVector), Y up, -Z the anchor's facing.
local function planCounter(info: LevelInfo, anchor: Anchor, random: Random): { Piece }
	local layout = info.layout
	local flasks = counterFlasks(layout, anchor)
	local top = counterTop(layout, anchor)
	if #flasks > 0 then
		for _, flask in flasks do
			if math.abs(flask.Y - top) > 0.05 then
				log.warn("%s: flask at %.2f does not match the worktop at %.2f", anchor.id, flask.Y, top)
			end
		end
	end
	local frame = CFrame.new(info.origin) * levelLocal(anchor)
	local halfD = COUNTER_DEPTH / 2
	local base = top - TOP_THICKNESS

	-- Trim an end that would reach into a doorway, grate front or landing (never past the flasks it carries).
	local minNeg, minPos = 2.2, 2.2
	for _, flask in flasks do
		if flask.X < 0 then
			minNeg = math.max(minNeg, -flask.X + 1)
		else
			minPos = math.max(minPos, flask.X + 1)
		end
	end
	local function endClear(x0: number, x1: number): boolean
		local probe =
			{ Kit.box(frame, "Probe", Vector3.new(x0, 0, -halfD), Vector3.new(x1, top, halfD), "Concrete", "Solid") }
		return Kit.fits(info, probe, { owner = anchor.id, ignore = COUNTER_PROBE_IGNORE })
	end
	local x0, x1 = -COUNTER_LENGTH / 2, COUNTER_LENGTH / 2
	while x1 > minPos and not endClear(x1 - 0.5, x1) do
		x1 -= 0.25
	end
	while -x0 > minNeg and not endClear(x0, x0 + 0.5) do
		x0 += 0.25
	end
	local mid = (x0 + x1) / 2
	local pieces: { Piece } = {}
	local function add(piece: Piece)
		table.insert(pieces, piece)
	end
	local style = pick(random, CASEWORK)

	-- Cabinet base
	add(
		Kit.box(
			frame,
			"Plinth",
			Vector3.new(x0 + 0.3, 0, -halfD + 0.35),
			Vector3.new(x1 - 0.3, PLINTH, halfD - 0.35),
			"Rubber",
			"Solid"
		)
	)
	add(
		Kit.box(
			frame,
			"Carcass",
			Vector3.new(x0 + 0.12, PLINTH, -halfD + CARCASS_INSET),
			Vector3.new(x1 - 0.12, base, halfD - CARCASS_INSET),
			"WoodPanel",
			"Solid",
			paint(style.body, style.material)
		)
	)

	-- Cupboard doors: one at each end of each face, hinged on the outer end. At most one hangs open or is gone (dark
	-- cavity); a door with no room to hang open was torn off instead.
	local leafY0, leafY1 = PLINTH + 0.06, base - 0.08
	local leafH = leafY1 - leafY0
	local carcassLength = (x1 - 0.12) - (x0 + 0.12)
	local leafW = math.min(LEAF_WIDTH, (carcassLength - 0.5) / 2)
	local brokenSlot = if chance(random, 0.55) then random:NextInteger(1, 4) else 0
	local labelSlot = if chance(random, 0.4) then pick(random, { 1, 2 }) else 0
	local slot = 0
	for _, side in { -1, 1 } do
		local faceZ = side * (halfD - CARCASS_INSET)
		local normal = Vector3.new(0, 0, side)
		for _, hingeSign in { -1, 1 } do
			slot += 1
			local hingeX = if hingeSign < 0 then x0 + 0.2 else x1 - 0.2
			local toFree = Vector3.new(-hingeSign, 0, 0)
			local state = if slot == brokenSlot then (if chance(random, 0.6) then "Open" else "Missing") else "Shut"
			local angle = if state == "Open" then between(random, 62, 112) else between(random, 0, 5)
			local a = math.rad(angle)
			local dir = toFree * math.cos(a) + normal * math.sin(a)
			local hinge = Vector3.new(hingeX, (leafY0 + leafY1) / 2, faceZ)
			local centre = hinge + dir * (leafW / 2) + normal * (LEAF / 2 + 0.005)
			local leaf = Kit.block(
				"Leaf" .. slot,
				CFrame.fromMatrix(frame:PointToWorldSpace(centre), frame:VectorToWorldSpace(dir), frame.UpVector),
				Vector3.new(leafW, leafH, LEAF),
				"WoodPanel",
				"Solid",
				paint(tint(style.leaf, random, 0.06), style.material)
			)
			if state == "Open" and not Kit.fits(info, { leaf }, { owner = anchor.id, ignore = STATIC_IGNORE }) then
				state = "Missing"
			end
			if state ~= "Shut" then
				local free = hingeX + toFree.X * leafW
				add(
					Kit.box(
						frame,
						"Cavity" .. slot,
						Vector3.new(math.min(hingeX, free) + 0.03, leafY0 + 0.03, faceZ),
						Vector3.new(math.max(hingeX, free) - 0.03, leafY1 - 0.03, faceZ + side * 0.02),
						"Rubber",
						"Detail",
						VOID
					)
				)
			end
			if state == "Missing" then
				continue
			end
			if slot == labelSlot and state == "Shut" then
				leaf.label = "Prop.Lab.Hazard"
				leaf.labelNormal = frame:VectorToWorldSpace(normal)
			end
			add(leaf)
		end
	end

	-- Sink: as far from the flasks as the worktop allows
	local candidates = { x0 + 1.25, x0 + (x1 - x0) * 0.3, mid, x1 - (x1 - x0) * 0.3, x1 - 1.25 }
	local sinkX, bestScore = mid, -math.huge
	for _, x in shuffled(random, candidates) do
		local score = 6
		for _, flask in flasks do
			score = math.min(score, math.abs(flask.X - x))
		end
		if score > bestScore + 0.25 then
			sinkX, bestScore = x, score
		end
	end
	local hx0, hx1 = sinkX - SINK_WIDTH / 2, sinkX + SINK_WIDTH / 2

	-- Epoxy worktop around the sink hole
	add(Kit.box(frame, "Top_1", Vector3.new(x0, base, -halfD), Vector3.new(hx0, top, halfD), "Rubber", "Solid", EPOXY))
	add(Kit.box(frame, "Top_2", Vector3.new(hx1, base, -halfD), Vector3.new(x1, top, halfD), "Rubber", "Solid", EPOXY))
	add(
		Kit.box(
			frame,
			"Top_3",
			Vector3.new(hx0, base, -halfD),
			Vector3.new(hx1, top, SINK_Z0),
			"Rubber",
			"Solid",
			EPOXY
		)
	)
	add(
		Kit.box(frame, "Top_4", Vector3.new(hx0, base, SINK_Z1), Vector3.new(hx1, top, halfD), "Rubber", "Solid", EPOXY)
	)
	add(
		Kit.box(
			frame,
			"Sink",
			Vector3.new(hx0, base - 0.2, SINK_Z0),
			Vector3.new(hx1, top - 0.22, SINK_Z1),
			"TrimMetal",
			"Solid",
			STEEL
		)
	)

	-- Gooseneck faucet behind the sink, turned a little on its riser
	local turn = math.rad(between(random, -28, 28))
	local riserZ = SINK_Z1 + 0.22
	local function swivel(dz: number, y: number): Vector3
		return frame:PointToWorldSpace(Vector3.new(sinkX + math.sin(turn) * dz, top + y, riserZ + math.cos(turn) * dz))
	end
	add(Kit.cylinder("FaucetRiser", swivel(0, 0), swivel(0, 1.08), 0.13, "TrimMetal", "Detail", STEEL))
	add(Kit.cylinder("FaucetNeck", swivel(0, 1.04), swivel(-0.42, 1.34), 0.11, "TrimMetal", "Detail", STEEL))
	add(Kit.cylinder("FaucetSpout", swivel(-0.4, 1.36), swivel(-0.68, 1.06), 0.1, "TrimMetal", "Detail", STEEL))

	-- Reagent shelf along the back edge, gas taps on its uprights
	local shelfZ0, shelfZ1 = halfD - 0.55, halfD - 0.08
	local ux0, ux1 = x0 + 0.5, x1 - 0.5
	for i, ux in { ux0, ux1 } do
		add(
			Kit.box(
				frame,
				"ShelfPost" .. i,
				Vector3.new(ux - 0.06, top, shelfZ0),
				Vector3.new(ux + 0.06, top + 1.85, shelfZ1),
				"WoodPanel",
				"Solid",
				paint(style.body, style.material)
			)
		)
		add(
			Kit.cylinder(
				"GasTap" .. i,
				frame:PointToWorldSpace(Vector3.new(ux + (if i == 1 then 0.06 else -0.06), top + 0.42, shelfZ0 + 0.12)),
				frame:PointToWorldSpace(Vector3.new(ux + (if i == 1 then 0.36 else -0.36), top + 0.42, shelfZ0 + 0.12)),
				0.1,
				"TrimMetal",
				"Detail",
				BRASS
			)
		)
	end
	local boardY = top + 1.1
	add(
		Kit.box(
			frame,
			"ShelfBoard",
			Vector3.new(ux0, boardY, shelfZ0),
			Vector3.new(ux1, boardY + 0.08, shelfZ1),
			"WoodPanel",
			"Solid",
			paint(style.body, style.material)
		)
	)

	-- Jars and beakers: on the board and under it on the worktop; one may lie smashed
	local spots: { number } = {}
	local smashed = chance(random, 0.75)
	for i = 1, 3 do
		local placed = false
		for _ = 1, 8 do
			local x = between(random, ux0 + 0.45, ux1 - 0.45)
			local ok = math.abs(x - ux0) > 0.6 and math.abs(x - ux1) > 0.6
			for _, other in spots do
				ok = ok and math.abs(other - x) > 0.75
			end
			if ok then
				table.insert(spots, x)
				local onBoard = i ~= 2 or chance(random, 0.5)
				local y = if onBoard then boardY + 0.08 else top
				local kind = pick(random, REAGENTS)
				local z = (shelfZ0 + shelfZ1) / 2
				local height = if smashed and i == 3 then 0.2 else kind.h
				local foot = frame:PointToWorldSpace(Vector3.new(x, y, z))
				local head = frame:PointToWorldSpace(Vector3.new(x, y + height, z))
				add(
					Kit.cylinder(
						if height < kind.h then "BrokenJar" else "Jar" .. i,
						foot,
						head,
						kind.d,
						"Glass",
						"Detail",
						glass(kind.color, kind.transparency)
					)
				)
				placed = true
				break
			end
		end
		if not placed then
			smashed = false
		end
	end

	-- Shards of the smashed jar and a dried spill on the worktop, clear of the sink and every flask's foot
	local function clearOfFlasks(x: number, z: number, reach: number): boolean
		for _, flask in flasks do
			if math.abs(flask.X - x) < FLASK_CLEAR + reach and math.abs(flask.Z - z) < FLASK_CLEAR + reach then
				return false
			end
		end
		return math.abs(x - sinkX) > SINK_WIDTH / 2 + reach + 0.15
	end
	local litter = (if smashed then 2 else 0) + 1
	for i = 1, litter do
		for _ = 1, 10 do
			local isSpill = i == litter
			local reach = if isSpill then 0.55 else 0.3
			local x = between(random, x0 + reach + 0.1, x1 - reach - 0.1)
			local z = if isSpill
				then between(random, -halfD + reach + 0.1, -0.2)
				else between(random, 0.5, shelfZ0 - 0.1)
			if clearOfFlasks(x, z, reach) then
				if isSpill then
					local d = between(random, 0.7, 1.05)
					add(
						Kit.disc(
							"Spill",
							frame:PointToWorldSpace(Vector3.new(x, top, z)),
							d,
							0.015,
							"Rubber",
							"Detail",
							paint(rgb(46, 50, 30), Enum.Material.SmoothPlastic, 0.2)
						)
					)
				else
					local cf = frame * CFrame.new(x, top + 0.016, z) * ry(between(random, 0, 360)) * FLAT
					add(
						Kit.wedge(
							"Shard" .. i,
							cf,
							Vector3.new(0.03, between(random, 0.22, 0.4), between(random, 0.25, 0.45)),
							"Glass",
							"Detail",
							glass(rgb(120, 130, 126), 0.35)
						)
					)
				end
				break
			end
		end
	end
	return pieces
end

local function buildLabCounters(ctx: PropKit.StaticContext): number
	local counters = PropKit.anchorsOf(ctx.layout, "LabCounter")
	if #counters == 0 then
		return 0
	end
	local info = Kit.info(ctx.layout)
	local seed = ctx.random:NextInteger(1, 2_000_000_000)
	local built = 0
	for _, anchor in counters do
		local random = MathUtil.seededRandom(seed, anchor.id)
		local pieces = planCounter(info, anchor, random)
		if not Kit.fits(info, pieces, { owner = anchor.id, ignore = COUNTER_IGNORE }) then
			log.warn("%s reaches into a clearance zone", anchor.id)
		end
		local model =
			PropKit.model(ctx.parent, "LabCounter_" .. anchor.id, CFrame.new(info.origin) * levelLocal(anchor))
		Kit.realize(model, pieces)
		stamp(model, info, {
			[W.AnchorId] = anchor.id,
			[W.AnchorKind] = anchor.kind,
			[W.ZoneId] = anchor.room,
		})
		built += 1
	end
	return built
end

--------------------------------------------------------------------------------
-- Smashed lockers
--------------------------------------------------------------------------------

local LOCKER_PAINT: { Color3 } = { rgb(64, 82, 72), rgb(58, 70, 86), rgb(92, 60, 50), rgb(88, 88, 82), rgb(96, 84, 52) }
local INTERIOR = paint(rgb(34, 36, 34), Enum.Material.Metal)
local PAPER: { Color3 } = { rgb(148, 140, 116), rgb(132, 128, 108), rgb(156, 150, 128), rgb(126, 132, 124) }
local BOOK: { Color3 } = { rgb(72, 38, 34), rgb(40, 52, 70), rgb(52, 66, 44), rgb(90, 76, 46), rgb(56, 52, 60) }

local function paperSheet(name: string, cframe: CFrame, random: Random): Piece
	return Kit.block(
		name,
		cframe,
		Vector3.new(0.72, 0.012, 0.95),
		"Fixture",
		"Detail",
		paint(pick(random, PAPER), Enum.Material.SmoothPlastic)
	)
end

-- A school-locker door as a closed slab whose middle was punched in (two halves meeting at a crease), with its vent
-- louvres. `frame` is the door's own frame at its centre, -Z out of the locker.
local function dentedDoor(
	name: string,
	frame: CFrame,
	width: number,
	height: number,
	color: Color3,
	material: Enum.Material,
	random: Random
): { Piece }
	local crease = between(random, -0.15, 0.15) * height
	local lowH = height / 2 + crease
	local highH = height - lowH
	local dent = between(random, 2.5, 8)
	local low = frame * CFrame.new(0, -height / 2, 0) * rx(-dent) * CFrame.new(0, lowH / 2, 0)
	local high = frame * CFrame.new(0, height / 2, 0) * rx(dent) * CFrame.new(0, -highH / 2, 0)
	local options = paint(color, material)
	return {
		Kit.block(name .. "Low", low, Vector3.new(width, lowH, LOCKER_PANEL), "MetalGalvanized", "Solid", options),
		Kit.block(name .. "High", high, Vector3.new(width, highH, LOCKER_PANEL), "MetalGalvanized", "Solid", options),
		Kit.block(
			name .. "Vents",
			high * CFrame.new(0, highH / 2 - 0.42, -LOCKER_PANEL / 2 - 0.007),
			Vector3.new(width - 0.42, 0.42, 0.012),
			"Rubber",
			"Detail",
			paint(rgb(24, 24, 22), Enum.Material.Metal)
		),
	}
end

type LockerState = "Shut" | "Hanging" | "Torn" | "Missing" | "Empty"

local function planLockers(info: LevelInfo, anchor: Anchor, random: Random, attempt: number): { Piece }?
	local span = lockerSpan(info.layout, info.rooms, info.inner, anchor)
	if not span then
		return nil
	end
	local maxCount = math.min(5, math.floor((span.half * 2 + EPS) / LOCKER_WIDTH))
	if maxCount < 2 then
		return nil
	end
	local count = math.min(maxCount, random:NextInteger(3, 5))
	local width = count * LOCKER_WIDTH
	local frame = CFrame.new(info.origin) * span.frame
	local color = pick(random, LOCKER_PAINT)
	local pieces: { Piece } = {}
	local function add(piece: Piece)
		table.insert(pieces, piece)
	end
	local body = paint(color, Enum.Material.Metal)
	local D, H = LOCKER_DEPTH, LOCKER_HEIGHT

	-- Bank shell: back panel, recessed plinth, sloped crown, dividers
	add(
		Kit.box(
			frame,
			"Back",
			Vector3.new(-width / 2, 0, -0.08),
			Vector3.new(width / 2, H, -0.02),
			"MetalGalvanized",
			"Solid",
			body
		)
	)
	add(
		Kit.box(
			frame,
			"Plinth",
			Vector3.new(-width / 2 + 0.02, 0, -(D - 0.12)),
			Vector3.new(width / 2 - 0.02, LOCKER_PLINTH, -0.08),
			"Rubber",
			"Solid"
		)
	)
	add(
		Kit.wedge(
			"Crown",
			frame * CFrame.new(0, H + LOCKER_CROWN / 2, -(D + 0.02) / 2 - 0.02),
			Vector3.new(width + 0.04, LOCKER_CROWN, D + 0.02),
			"MetalGalvanized",
			"Solid",
			body
		)
	)
	for i = 0, count do
		local x = -width / 2 + i * LOCKER_WIDTH
		add(
			Kit.box(
				frame,
				"Divider" .. i,
				Vector3.new(x - LOCKER_PANEL / 2, LOCKER_PLINTH, -D),
				Vector3.new(x + LOCKER_PANEL / 2, H, -0.08),
				"MetalGalvanized",
				"Solid",
				body
			)
		)
	end

	-- What the Creature did to each locker. Later attempts tone it down until the bank fits its clearances.
	local states: { LockerState } = {}
	local toppled = if attempt == 1
			and count >= 4
			and span.half >= H / 2 + 0.25
			and chance(random, 0.5)
		then random:NextInteger(1, count)
		else 0
	local openCount = 0
	for i = 1, count do
		local state: LockerState
		if i == toppled then
			state = "Empty"
		else
			local roll = random:NextNumber()
			state = if roll < 0.42
				then "Shut"
				elseif roll < 0.64 then "Hanging"
				elseif roll < 0.76 then "Torn"
				else "Missing"
			if attempt >= 2 and (state == "Hanging" or state == "Torn") then
				state = "Missing"
			end
			if toppled > 0 and state == "Torn" then
				state = "Missing"
			end
		end
		if state ~= "Shut" then
			openCount += 1
		end
		table.insert(states, state)
	end
	if openCount == 0 then
		states[random:NextInteger(1, count)] = "Missing"
	elseif openCount == count then
		for i, state in states do
			if state ~= "Empty" then
				states[i] = "Shut"
				break
			end
		end
	end

	local doorW, doorH = LOCKER_WIDTH - 0.1, DOOR_TOP - DOOR_BOTTOM
	local openSlots: { number } = {}
	for i, state in states do
		local cx = -width / 2 + (i - 0.5) * LOCKER_WIDTH
		local material = if chance(random, 0.3) then Enum.Material.CorrodedMetal else Enum.Material.Metal
		local doorColor = tint(color, random, 0.08)
		if state == "Shut" then
			local doorFrame = frame * CFrame.new(cx, (DOOR_BOTTOM + DOOR_TOP) / 2, -D - 0.035)
			for _, piece in dentedDoor("Door" .. i, doorFrame, doorW, doorH, doorColor, material, random) do
				add(piece)
			end
			continue
		end
		if state ~= "Empty" then
			table.insert(openSlots, cx)
			add(
				Kit.box(
					frame,
					"Shelf" .. i,
					Vector3.new(cx - LOCKER_WIDTH / 2 + 0.04, H - 1.25, -D + 0.08),
					Vector3.new(cx + LOCKER_WIDTH / 2 - 0.04, H - 1.2, -0.1),
					"MetalGalvanized",
					"Solid",
					INTERIOR
				)
			)
		end
		if state == "Hanging" then
			-- Hanging from its bottom hinge: swung out, the free edge sagging
			local hingeSign = if chance(random, 0.5) then 1 else -1
			local hinge = Vector3.new(cx + hingeSign * (LOCKER_WIDTH / 2 - 0.05), DOOR_BOTTOM, -D - 0.035)
			local a = math.rad(between(random, 65, 115))
			local sag =
				math.rad(between(random, 5, math.deg(math.asin(math.clamp((DOOR_BOTTOM - 0.06) / doorW, 0, 1)))))
			local toFree = Vector3.new(-hingeSign, 0, 0) * math.cos(a) + Vector3.new(0, 0, -1) * math.sin(a)
			local right = toFree * math.cos(sag) - Vector3.yAxis * math.sin(sag)
			local up = Vector3.yAxis * math.cos(sag) + toFree * math.sin(sag)
			local centre = hinge + right * (doorW / 2) + up * (doorH / 2)
			add(
				Kit.block(
					"Door" .. i,
					CFrame.fromMatrix(
						frame:PointToWorldSpace(centre),
						frame:VectorToWorldSpace(right),
						frame:VectorToWorldSpace(up)
					),
					Vector3.new(doorW, doorH, LOCKER_PANEL),
					"MetalGalvanized",
					"Solid",
					paint(doorColor, material)
				)
			)
		elseif state == "Torn" then
			-- Ripped off and dropped flat in front of the bank, along the wall
			local cf = frame
				* CFrame.new(cx + between(random, -0.5, 0.5), 0.05, -D - 0.68)
				* ry(between(random, -5, 5))
				* rz(between(random, -3, 3))
			add(
				Kit.block(
					"Door" .. i,
					cf,
					Vector3.new(doorH, LOCKER_PANEL, doorW),
					"MetalGalvanized",
					"Solid",
					paint(doorColor, material)
				)
			)
		end
	end

	-- A locker torn out of the bank and dropped on its side in front of it, door facing the room
	if toppled > 0 then
		local cx = -width / 2 + (toppled - 0.5) * LOCKER_WIDTH
		local shift = math.clamp(cx + between(random, -0.6, 0.6), -span.half + H / 2 + 0.1, span.half - H / 2 - 0.1)
		local lieFrame = frame
			* CFrame.new(shift, 0, -D - 0.14 - D / 2)
			* ry(between(random, -6, 6))
			* rz(between(random, -3, 3))
			* CFrame.fromMatrix(Vector3.zero, Vector3.yAxis, -Vector3.xAxis)
		local lying = {
			Kit.block("Toppled", lieFrame, Vector3.new(LOCKER_WIDTH, H, D), "MetalGalvanized", "Solid", body),
			Kit.block(
				"ToppledDoor",
				lieFrame * CFrame.new(0, 0.1, -D / 2 - 0.035) * rx(between(random, -4, 4)),
				Vector3.new(doorW, doorH, LOCKER_PANEL),
				"MetalGalvanized",
				"Solid",
				paint(tint(color, random, 0.08), Enum.Material.CorrodedMetal)
			),
		}
		local drop = lowest(lying) - (info.origin.Y + anchor.pos.Y)
		Kit.offset(lying, Vector3.new(0, -drop, 0))
		for _, piece in lying do
			add(piece)
		end
	end
	if not Kit.fits(info, pieces, { owner = anchor.id, ignore = STATIC_IGNORE }) then
		return nil
	end

	-- Papers (and a book) spilled from the open lockers: each sheet only where it fits
	local sheets = random:NextInteger(4, 7)
	local placed = 0
	for _ = 1, sheets * 3 do
		if placed >= sheets or #openSlots == 0 then
			break
		end
		local x = pick(random, openSlots) + between(random, -1.1, 1.1)
		local z = -D - between(random, 0.12, 1.9)
		local y = 0.008 + placed * 0.004
		local sheet = paperSheet(
			"Paper" .. placed + 1,
			frame * CFrame.new(x, y, z) * ry(between(random, 0, 360)) * rx(between(random, -2, 2)),
			random
		)
		if
			Kit.fits(info, { sheet }, { owner = anchor.id, ignore = STATIC_IGNORE })
			and not piecesOverlap(info, { sheet }, pieces)
		then
			table.insert(pieces, sheet)
			placed += 1
		end
	end
	if #openSlots > 0 then
		local x = pick(random, openSlots)
		local book = Kit.block(
			"Book",
			frame
				* CFrame.new(x + between(random, -0.6, 0.6), 0.09, -D - between(random, 0.4, 1.2))
				* ry(between(random, 0, 360)),
			Vector3.new(0.78, 0.16, 1.02),
			"Fixture",
			"Detail",
			paint(pick(random, BOOK), Enum.Material.Fabric)
		)
		if
			Kit.fits(info, { book }, { owner = anchor.id, ignore = STATIC_IGNORE })
			and not piecesOverlap(info, { book }, pieces)
		then
			table.insert(pieces, book)
		end
	end
	return pieces
end

local function buildSmashedLockers(ctx: PropKit.StaticContext): number
	local anchors = PropKit.anchorsOf(ctx.layout, "SmashedLocker")
	if #anchors == 0 then
		return 0
	end
	local info = Kit.info(ctx.layout)
	local seed = ctx.random:NextInteger(1, 2_000_000_000)
	local built = 0
	for _, anchor in anchors do
		local pieces: { Piece }? = nil
		for attempt = 1, 3 do
			pieces = planLockers(info, anchor, MathUtil.seededRandom(seed + attempt, anchor.id), attempt)
			if pieces then
				break
			end
		end
		local list = pieces
		if not list then
			log.warn("%s: no room for a locker bank", anchor.id)
			continue
		end
		local span = lockerSpan(info.layout, info.rooms, info.inner, anchor)
		local pivot = if span
			then CFrame.new(info.origin) * span.frame
			else CFrame.new(info.origin) * levelLocal(anchor)
		local model = PropKit.model(ctx.parent, "SmashedLocker_" .. anchor.id, pivot)
		Kit.realize(model, list)
		stamp(model, info, {
			[W.AnchorId] = anchor.id,
			[W.AnchorKind] = anchor.kind,
			[W.ZoneId] = anchor.room,
		})
		built += 1
	end
	return built
end

--------------------------------------------------------------------------------
-- Drip pipes
--------------------------------------------------------------------------------

type PipeRun = {
	axis: Vector3, -- level-local unit vector the run follows (X or Z)
	y: number, -- level-local Y of the pipe centre line
	from: number, -- along `axis`, level-local
	to: number,
	at: number, -- the leaking joint (the anchor)
	cross: number, -- the other horizontal coordinate
	wallFrom: boolean, -- the run ends in a wall (else it turns up into the ceiling)
	wallTo: boolean,
	ceiling: number, -- level-local Y of the ceiling underside
	hangers: { number }, -- along `axis`, clear of the ceiling fixtures
}

-- Approximate fixture boxes of a room's lights (as SchoolShellBuilder.buildLight places them under the ceiling).
local function lightBoxes(room: Room, ceiling: number): { Box }
	local out: { Box } = {}
	for _, light in (room.lights or {}) :: { LayoutSchema.Light } do
		local p = light.pos
		local hx, hy, hz, drop = 1.4, 1.4, 1.4, 0.8
		if light.kind == "Fluorescent" or light.kind == "ClassroomGlow" then
			hx, hy, hz, drop = 2, 0.125, 0.45, 0.125
		elseif light.kind == "Bulb" then
			hx, hy, hz, drop = 0.35, 0.35, 0.35, 0.6
		end
		local y = math.min(p.Y, ceiling - drop)
		table.insert(out, {
			x0 = p.X - hx - 0.3,
			x1 = p.X + hx + 0.3,
			z0 = p.Z - hz - 0.3,
			z1 = p.Z + hz + 0.3,
			y0 = y - hy - 0.1,
			y1 = y + hy + 0.1,
		})
	end
	return out
end

local function planRun(info: LevelInfo, anchor: Anchor, random: Random?): PipeRun?
	local room = info.rooms[anchor.room]
	local inner = info.inner[anchor.room]
	if not (room and inner) then
		return nil
	end
	local ceiling = SchoolShellBuilder.ceilingBottom(info.layout, room)
	local y = ceiling - PIPE_DROP
	-- What the pipe and its flanges must miss, and what anything rising into the ceiling (elbows, hangers) must miss
	local pipeY0, pipeY1 = y - FLANGE_DIAMETER / 2 - 0.05, y + FLANGE_DIAMETER / 2 + 0.05
	local riseY0, riseY1 = y - PIPE_DIAMETER / 2, ceiling + 0.3
	local obstacles: { Box } = lightBoxes(room, ceiling)
	for _, pillar in info.pillars do
		table.insert(obstacles, pillar)
	end
	for _, platform in info.platforms do
		table.insert(obstacles, platform)
	end
	local wantHalf = if random then between(random, PIPE_HALF_SPAN[1], PIPE_HALF_SPAN[2]) else PIPE_HALF_SPAN[1]
	local axes: { Vector3 } = if inner.w >= inner.d
		then { Vector3.xAxis, Vector3.zAxis }
		else { Vector3.zAxis, Vector3.xAxis }
	local reach = FLANGE_DIAMETER / 2 + 0.1
	for _, axis in axes do
		local alongX = axis.X > 0.5
		local at = if alongX then anchor.pos.X else anchor.pos.Z
		local cross = if alongX then anchor.pos.Z else anchor.pos.X
		local lo = (if alongX then inner.x else inner.z) + 0.02
		local hi = (if alongX then inner.x + inner.w else inner.z + inner.d) - 0.02
		local crossLo = if alongX then inner.z else inner.x
		local crossHi = crossLo + (if alongX then inner.d else inner.w)
		if cross - reach < crossLo or cross + reach > crossHi then
			continue
		end
		local pipeBlocks: { { number } } = {}
		local riseBlocks: { { number } } = {}
		for _, o in obstacles do
			local c0, c1 = if alongX then o.z0 else o.x0, if alongX then o.z1 else o.x1
			if math.min(c1, cross + reach) - math.max(c0, cross - reach) <= 0 then
				continue
			end
			local a0, a1 = if alongX then o.x0 else o.z0, if alongX then o.x1 else o.z1
			if math.min(o.y1, pipeY1) - math.max(o.y0, pipeY0) > 0 then
				table.insert(pipeBlocks, { a0, a1 })
			end
			if math.min(o.y1, riseY1) - math.max(o.y0, riseY0) > 0 then
				table.insert(riseBlocks, { a0, a1 })
			end
		end
		local from, to = math.max(lo, at - wantHalf), math.min(hi, at + wantHalf)
		local blockedAt = false
		for _, b in pipeBlocks do
			if b[1] <= at + reach and b[2] >= at - reach then
				blockedAt = true
				break
			end
			if b[2] < at then
				from = math.max(from, b[2] + 0.2)
			else
				to = math.min(to, b[1] - 0.2)
			end
		end
		if blockedAt then
			continue
		end
		local function riseBlock(u: number): { number }?
			for _, b in riseBlocks do
				if u >= b[1] - 0.45 and u <= b[2] + 0.45 then
					return b
				end
			end
			return nil
		end
		local wallFrom, wallTo = from <= lo + EPS, to >= hi - EPS
		-- An end that turns up into the ceiling must miss the fixtures up there
		for _ = 1, 8 do
			local b = if wallFrom then nil else riseBlock(from)
			if not b then
				break
			end
			from = b[2] + 0.5
		end
		for _ = 1, 8 do
			local b = if wallTo then nil else riseBlock(to)
			if not b then
				break
			end
			to = b[1] - 0.5
		end
		if to - from < 4 or from > at - reach or to < at + reach then
			continue
		end
		local hangers: { number } = {}
		for _, t in { 0.3, 0.72 } do
			local base = from + (to - from) * t
			if math.abs(base - at) < 1 then
				base += if base < at then -1.2 else 1.2
			end
			for _, nudge in { 0, 0.6, -0.6, 1.2, -1.2, 1.8, -1.8 } do
				local u = base + nudge
				if u >= from + 0.4 and u <= to - 0.4 and math.abs(u - at) >= 0.8 and not riseBlock(u) then
					table.insert(hangers, u)
					break
				end
			end
		end
		return {
			axis = axis,
			y = y,
			from = from,
			to = to,
			at = at,
			cross = cross,
			wallFrom = wallFrom,
			wallTo = wallTo,
			ceiling = ceiling,
			hangers = hangers,
		}
	end
	return nil
end

-- Level-local Y of the surface the drips land on: pool water, a platform or worktop, else the floor.
local function dripSurface(info: LevelInfo, anchor: Anchor): (number, boolean)
	local x, z = anchor.pos.X, anchor.pos.Z
	for _, pool in info.water do
		if x > pool.x0 and x < pool.x1 and z > pool.z0 and z < pool.z1 then
			return pool.y1, true
		end
	end
	local surface = 0
	for _, platform in info.platforms do
		if
			x >= platform.x0
			and x <= platform.x1
			and z >= platform.z0
			and z <= platform.z1
			and platform.y1 < anchor.pos.Y
		then
			surface = math.max(surface, platform.y1)
		end
	end
	for _, other in info.layout.anchors do
		if other.kind == "LabCounter" and other.room == anchor.room then
			local p = levelLocal(other):PointToObjectSpace(Vector3.new(x, 0, z))
			if math.abs(p.X) <= COUNTER_LENGTH / 2 and math.abs(p.Z) <= COUNTER_DEPTH / 2 then
				surface = math.max(surface, counterTop(info.layout, other))
			end
		end
	end
	return surface, false
end

local function dripPointIn(info: LevelInfo, anchor: Anchor): Vector3
	local room = info.rooms[anchor.room]
	if not room then
		return info.origin + anchor.pos
	end
	local y = SchoolShellBuilder.ceilingBottom(info.layout, room) - PIPE_DROP - FLANGE_DIAMETER / 2 - DRIP_BEAD / 2
	return info.origin + Vector3.new(anchor.pos.X, y, anchor.pos.Z)
end

-- World position water drips from at a DripPipe anchor of `layoutId`: under the leaking flange joint of the pipe
-- run hung below that room's ceiling (pure; the static pipe and the client's drops both use it).
function SetDressingBuilder.dripPoint(layoutId: string, anchor: Anchor): Vector3
	local layout = loadLayout(layoutId)
	if not layout then
		return WorldConfig.levelOrigin(layoutId) + anchor.pos
	end
	return dripPointIn(Kit.info(layout), anchor)
end

local function planPipe(info: LevelInfo, anchor: Anchor, random: Random): { Piece }?
	local run = planRun(info, anchor, random)
	if not run then
		return nil
	end
	local origin = info.origin
	local function point(u: number, y: number): Vector3
		if run.axis.X > 0.5 then
			return origin + Vector3.new(u, y, run.cross)
		end
		return origin + Vector3.new(run.cross, y, u)
	end
	local rusty = chance(random, 0.5)
	local pipeKey = if rusty then "MetalRust" else "MetalGalvanized"
	local pieces: { Piece } = {}
	local function add(piece: Piece)
		table.insert(pieces, piece)
	end
	local y = run.y
	local joint = run.at
	local fromEnd = if run.wallFrom then run.from - 0.3 else run.from
	local toEnd = if run.wallTo then run.to + 0.3 else run.to
	add(
		Kit.cylinder(
			"PipeA",
			point(fromEnd, y),
			point(joint - FLANGE_GAP / 2 - FLANGE_THICKNESS + 0.02, y),
			PIPE_DIAMETER,
			pipeKey,
			"Solid"
		)
	)
	add(
		Kit.cylinder(
			"PipeB",
			point(joint + FLANGE_GAP / 2 + FLANGE_THICKNESS - 0.02, y),
			point(toEnd, y),
			PIPE_DIAMETER,
			pipeKey,
			"Solid"
		)
	)
	-- The corroded joint: two bolted flanges sprung apart by the gap the water leaks through
	add(
		Kit.cylinder(
			"FlangeA",
			point(joint - FLANGE_GAP / 2 - FLANGE_THICKNESS, y),
			point(joint - FLANGE_GAP / 2, y),
			FLANGE_DIAMETER,
			"Iron",
			"Solid"
		)
	)
	add(
		Kit.cylinder(
			"FlangeB",
			point(joint + FLANGE_GAP / 2, y + 0.03),
			point(joint + FLANGE_GAP / 2 + FLANGE_THICKNESS, y + 0.05),
			FLANGE_DIAMETER,
			"Iron",
			"Solid"
		)
	)
	add(
		Kit.block(
			"RustStreak",
			CFrame.lookAt(
				point(joint, y - PIPE_DIAMETER / 2 - 0.012),
				point(joint, y - PIPE_DIAMETER / 2 - 0.012) + run.axis
			),
			Vector3.new(0.22, 0.03, between(random, 1.6, 2.6)),
			"Iron",
			"Detail",
			paint(rgb(70, 44, 28), Enum.Material.CorrodedMetal)
		)
	)
	-- Ends: into the wall, or an elbow up through the ceiling
	for _, entry in { { run.from, run.wallFrom, "A" }, { run.to, run.wallTo, "B" } } :: { { any } } do
		local u, intoWall, tag = entry[1] :: number, entry[2] :: boolean, entry[3] :: string
		if not intoWall then
			add(Kit.ball("Elbow" .. tag, point(u, y), PIPE_DIAMETER * 1.12, pipeKey, "Solid"))
			add(
				Kit.cylinder("Riser" .. tag, point(u, y), point(u, run.ceiling + 0.25), PIPE_DIAMETER, pipeKey, "Solid")
			)
		end
	end
	-- Hangers from the ceiling
	for i, t in { 0.3, 0.72 } do
		local u = run.from + (run.to - run.from) * t
		if math.abs(u - joint) < 1 then
			u += if u < joint then -1.2 else 1.2
		end
		u = math.clamp(u, run.from + 0.4, run.to - 0.4)
		add(
			Kit.cylinder(
				"Hanger" .. i,
				point(u, y + PIPE_DIAMETER / 2 - 0.02),
				point(u, run.ceiling + 0.05),
				0.08,
				"TrimMetal",
				"Detail"
			)
		)
	end
	return pieces
end

local function planPuddle(info: LevelInfo, anchor: Anchor, random: Random, centre: Vector3): { Piece }
	local pieces: { Piece } = {}
	for _, scale in { 1, 0.7, 0.45 } do
		pieces = {
			Kit.disc(
				"WetStain",
				centre + Vector3.new(between(random, -0.2, 0.2), 0.004, between(random, -0.2, 0.2)),
				between(random, 2.6, 3.6) * scale,
				0.02,
				"ConcreteDark",
				"Detail",
				paint(rgb(30, 32, 28), Enum.Material.SmoothPlastic, 0.55)
			),
			Kit.disc(
				"Puddle",
				centre + Vector3.new(0, 0.004, 0),
				between(random, 1.4, 2) * scale,
				0.03,
				"Water",
				"Detail",
				{ transparency = 0.3, reflectance = 0.18 }
			),
			Kit.disc(
				"PuddleLobe",
				centre + Vector3.new(between(random, -0.7, 0.7) * scale, 0.004, between(random, -0.7, 0.7) * scale),
				between(random, 0.8, 1.3) * scale,
				0.036,
				"Water",
				"Detail",
				{ transparency = 0.3, reflectance = 0.18 }
			),
		}
		if Kit.fits(info, pieces, { owner = anchor.id, ignore = STATIC_IGNORE }) then
			return pieces
		end
	end
	return {}
end

local function buildDripPipes(ctx: PropKit.StaticContext): number
	local anchors = PropKit.anchorsOf(ctx.layout, "DripPipe")
	if #anchors == 0 then
		return 0
	end
	local info = Kit.info(ctx.layout)
	local seed = ctx.random:NextInteger(1, 2_000_000_000)
	local built = 0
	for _, anchor in anchors do
		local random = MathUtil.seededRandom(seed, anchor.id)
		local pipe = planPipe(info, anchor, random)
		if not pipe then
			log.warn("%s: no clear ceiling run for a pipe", anchor.id)
			continue
		end
		local drip = dripPointIn(info, anchor)
		local surface, onWater = dripSurface(info, anchor)
		if not onWater then
			for _, piece in planPuddle(info, anchor, random, Vector3.new(drip.X, info.origin.Y + surface, drip.Z)) do
				table.insert(pipe, piece)
			end
		end
		local model = PropKit.model(ctx.parent, "DripPipe_" .. anchor.id, CFrame.new(drip))
		Kit.realize(model, pipe)
		local bead = Geometry.part(model, "Drip", CFrame.new(drip), Vector3.one * DRIP_BEAD, "Water", {
			shape = Enum.PartType.Ball,
			transparency = 0.25,
			reflectance = 0.3,
		})
		PropKit.detail(bead)
		bead:AddTag(Tags.DripPipe)
		PropKit.setAttributes(bead, {
			[W.LevelId] = ctx.layout.id,
			[W.AnchorId] = anchor.id,
			[W.ZoneId] = anchor.room,
		})
		stamp(model, info, {
			[W.AnchorId] = anchor.id,
			[W.AnchorKind] = anchor.kind,
			[W.ZoneId] = anchor.room,
		})
		built += 1
	end
	return built
end

--------------------------------------------------------------------------------
-- Floor debris
--------------------------------------------------------------------------------

type DebrisKind = "Glass" | "Can" | "Flat" | "Splinter" | "Coal" | "Plaster" | "Lid" | "Frame"

-- What lies on a trigger, by what its id says it is (weights per kind).
local function debrisMix(trigger: Trigger): { [DebrisKind]: number }
	local id = trigger.id
	if trigger.kind == "ScareStep" then
		return { Glass = 5, Can = 2, Flat = 1.5, Splinter = 1.5 }
	elseif string.find(id, "Coal", 1, true) then
		return { Coal = 5, Splinter = 3, Glass = 1 }
	elseif string.find(id, "Jars", 1, true) then
		return { Glass = 6, Lid = 2, Can = 1 }
	elseif string.find(id, "Skylight", 1, true) then
		return { Glass = 7, Frame = 2 }
	elseif string.find(id, "Glass", 1, true) then
		return { Glass = 6, Can = 1, Splinter = 2 }
	end
	return { Glass = 3, Can = 2, Flat = 1, Splinter = 3, Plaster = 2 }
end

local CAN_COLORS: { Color3 } =
	{ rgb(110, 40, 36), rgb(46, 82, 52), rgb(120, 122, 118), rgb(52, 62, 96), rgb(140, 110, 42) }
local DEBRIS_ORDER: { DebrisKind } = { "Glass", "Can", "Flat", "Splinter", "Coal", "Plaster", "Lid", "Frame" }

-- One debris item lying at level-local floor point (x, y, z), world space.
local function debrisPiece(
	origin: Vector3,
	kind: DebrisKind,
	index: number,
	x: number,
	y: number,
	z: number,
	random: Random
): Piece
	local base = CFrame.new(origin + Vector3.new(x, y, z)) * ry(between(random, 0, 360))
	local name = kind .. index
	if kind == "Glass" then
		local a, b = between(random, 0.25, 0.75), between(random, 0.3, 0.95)
		return Kit.wedge(
			name,
			base * CFrame.new(0, 0.02, 0) * rx(between(random, -4, 4)) * FLAT,
			Vector3.new(0.035, a, b),
			"Glass",
			"Detail",
			{ material = Enum.Material.Glass, color = rgb(132, 144, 140), transparency = 0.25, reflectance = 0.3 }
		)
	elseif kind == "Can" then
		-- On its side, a little crumpled toward one end
		local axis = base:VectorToWorldSpace(Vector3.new(1, math.sin(math.rad(between(random, -4, 4))), 0))
		local centre = origin + Vector3.new(x, y + 0.13, z)
		return Kit.cylinder(
			name,
			centre - axis * 0.22,
			centre + axis * 0.22,
			0.26,
			"TrimMetal",
			"Detail",
			paint(pick(random, CAN_COLORS), Enum.Material.Metal)
		)
	elseif kind == "Flat" then
		local d = between(random, 0.3, 0.38)
		return Kit.disc(
			name,
			origin + Vector3.new(x, y, z),
			d,
			between(random, 0.07, 0.11),
			"TrimMetal",
			"Detail",
			paint(pick(random, CAN_COLORS), Enum.Material.Metal)
		)
	elseif kind == "Splinter" then
		return Kit.block(
			name,
			base * CFrame.new(0, 0.03, 0) * rx(between(random, -3, 3)),
			Vector3.new(between(random, 0.06, 0.14), 0.05, between(random, 0.6, 1.6)),
			pick(random, { "Plank", "PlankDark", "Trim" }),
			"Detail"
		)
	elseif kind == "Coal" then
		-- Any tumble keeps a lump under 0.6 tall (its diagonal is 1.7 * s)
		local s = between(random, 0.16, 0.34)
		return Kit.block(
			name,
			base
				* CFrame.new(0, s * 0.35, 0)
				* CFrame.Angles(math.rad(between(random, 0, 45)), 0, math.rad(between(random, 0, 45))),
			Vector3.new(s, s * 0.7, s * 1.2),
			"Rubber",
			"Detail",
			paint(rgb(22, 22, 22), Enum.Material.Slate)
		)
	elseif kind == "Plaster" then
		local s = between(random, 0.25, 0.6)
		return Kit.block(
			name,
			base * CFrame.new(0, s * 0.2, 0) * rz(between(random, -12, 12)),
			Vector3.new(s, s * 0.35, s * 0.8),
			"PlasterSchool",
			"Detail"
		)
	elseif kind == "Lid" then
		return Kit.disc(
			name,
			origin + Vector3.new(x, y, z),
			between(random, 0.34, 0.46),
			0.06,
			"TrimMetal",
			"Detail",
			paint(rgb(86, 82, 70), Enum.Material.Metal)
		)
	end
	return Kit.block(
		name,
		base * CFrame.new(0, 0.05, 0) * rx(between(random, -4, 4)),
		Vector3.new(0.1, 0.1, between(random, 0.9, 1.6)),
		"TrimMetal",
		"Detail"
	)
end

local function planDebris(info: LevelInfo, trigger: Trigger, random: Random): { Piece }
	local r = trigger.rect
	local floor = trigger.y or 0
	local area = r.w * r.d
	local count = math.clamp(math.floor(area / 3.6), 10, BUDGET.FloorDebris)
	local mix = debrisMix(trigger)
	local total = 0
	for _, kind: DebrisKind in DEBRIS_ORDER do
		total += mix[kind] or 0
	end
	local pieces: { Piece } = {}
	local tries = 0
	while #pieces < count and tries < count * 12 do
		tries += 1
		local roll = random:NextNumber() * total
		local kind: DebrisKind = "Glass"
		for _, candidate: DebrisKind in DEBRIS_ORDER do
			roll -= mix[candidate] or 0
			if roll <= 0 then
				kind = candidate
				break
			end
		end
		local x = between(random, r.x + 0.25, r.x + r.w - 0.25)
		local z = between(random, r.z + 0.25, r.z + r.d - 0.25)
		local piece = debrisPiece(info.origin, kind, #pieces + 1, x, floor, z, random)
		-- Settle it: resting on the floor, never sunk into it
		Kit.offset({ piece }, Vector3.new(0, info.origin.Y + floor + 0.004 - lowest({ piece }), 0))
		local box = Kit.localBox(info, piece)
		if box.x0 < r.x + 0.05 or box.x1 > r.x + r.w - 0.05 or box.z0 < r.z + 0.05 or box.z1 > r.z + r.d - 0.05 then
			continue
		end
		if
			Kit.fits(info, { piece }, { room = trigger.room, margin = 0.05, ground = floor, ignore = STATIC_IGNORE })
			and not piecesOverlap(info, { piece }, pieces)
		then
			table.insert(pieces, piece)
		end
	end
	return pieces
end

local function buildFloorDebris(ctx: PropKit.StaticContext): number
	local info = Kit.info(ctx.layout)
	local seed = ctx.random:NextInteger(1, 2_000_000_000)
	local built = 0
	for _, trigger in ctx.layout.triggers do
		if trigger.kind ~= "FloorDebris" and trigger.kind ~= "ScareStep" then
			continue
		end
		local pieces = planDebris(info, trigger, MathUtil.seededRandom(seed, trigger.id))
		local r = trigger.rect
		local model = PropKit.model(
			ctx.parent,
			"FloorDebris_" .. trigger.id,
			CFrame.new(info.origin + Vector3.new(r.x + r.w / 2, trigger.y or 0, r.z + r.d / 2))
		)
		Kit.realize(model, pieces)
		stamp(model, info, {
			[W.TriggerId] = trigger.id,
			[W.TriggerKind] = trigger.kind,
			[W.ZoneId] = trigger.room,
		})
		built += 1
	end
	return built
end

--------------------------------------------------------------------------------
-- Corpses (cosmetic)
--------------------------------------------------------------------------------

type Pose = {
	root: CFrame,
	waist: CFrame,
	neck: CFrame,
	shoulder: { CFrame }, -- [1] right (+X), [2] left
	elbow: { CFrame },
	wrist: { CFrame },
	hip: { CFrame },
	knee: { CFrame },
	ankle: { CFrame },
}

type PoseKind = "Slumped" | "FaceDown" | "Curled"

local LYING_POSES: { PoseKind } = { "FaceDown", "Curled" }

local BODY = table.freeze({
	pelvis = Vector3.new(1.3, 0.62, 0.72),
	torso = Vector3.new(1.45, 1.9, 0.78),
	head = Vector3.new(0.78, 0.92, 0.84),
	upperArm = Vector3.new(0.42, 1.25, 0.42),
	foreArm = Vector3.new(0.36, 1.15, 0.36),
	hand = Vector3.new(0.3, 0.42, 0.16),
	thigh = Vector3.new(0.56, 1.6, 0.58),
	shin = Vector3.new(0.48, 1.5, 0.5),
	foot = Vector3.new(0.48, 0.32, 0.92),
	shoulderX = 0.95,
	shoulderY = 1.72,
	hipX = 0.36,
	hipY = -0.12, -- seated, the thighs lie level with the seat of the pelvis
})

local SHIRTS: { Color3 } = { rgb(120, 114, 96), rgb(46, 52, 68), rgb(74, 40, 42), rgb(58, 72, 60), rgb(86, 82, 72) }
local TROUSERS: { Color3 } = { rgb(40, 40, 44), rgb(58, 54, 50), rgb(36, 40, 52), rgb(66, 56, 44) }
local SKIN: { Color3 } = { rgb(102, 98, 76), rgb(92, 84, 66), rgb(86, 92, 70), rgb(98, 88, 74) }
local BONE = rgb(150, 142, 118)
local BLOOD: { Color3 } = { rgb(52, 22, 18), rgb(44, 20, 16), rgb(58, 28, 20) }

local function posePieces(pose: Pose, random: Random): { Piece }
	local shirt = pick(random, SHIRTS)
	local trousers = pick(random, TROUSERS)
	local skin = pick(random, SKIN)
	local cloth = Enum.Material.Fabric
	local flesh = Enum.Material.SmoothPlastic
	local pieces: { Piece } = {}
	local function add(name: string, cf: CFrame, size: Vector3, color: Color3, material: Enum.Material)
		table.insert(pieces, Kit.block(name, cf, size, "Fixture", "Detail", paint(tint(color, random, 0.07), material)))
	end
	local root = pose.root
	add("Pelvis", root, BODY.pelvis, trousers, cloth)
	local waist = root * CFrame.new(0, BODY.pelvis.Y / 2, 0) * pose.waist
	local torso = waist * CFrame.new(0, BODY.torso.Y / 2, 0)
	add("Torso", torso, BODY.torso, shirt, cloth)
	local neck = waist * CFrame.new(0, BODY.torso.Y, 0) * pose.neck
	local head = neck * CFrame.new(0, BODY.head.Y / 2 + 0.04, 0.02)
	add("Head", head, BODY.head, skin, flesh)
	add(
		"Hair",
		head * CFrame.new(0, BODY.head.Y / 2 - 0.08, 0.06),
		Vector3.new(0.82, 0.22, 0.8),
		rgb(36, 30, 24),
		cloth
	)
	add(
		"Sockets",
		head * CFrame.new(0, 0.1, -BODY.head.Z / 2 - 0.006),
		Vector3.new(0.52, 0.17, 0.012),
		rgb(18, 14, 12),
		flesh
	)
	-- Rotted through the shirt: a dark tear with two ribs across it, and a torn hem flap
	local tearX = between(random, -0.3, 0.3)
	add(
		"Tear",
		torso * CFrame.new(tearX, 0.2, -BODY.torso.Z / 2 - 0.006),
		Vector3.new(0.62, 0.72, 0.012),
		rgb(46, 28, 24),
		flesh
	)
	for i = 1, 2 do
		add(
			"Rib" .. i,
			torso * CFrame.new(tearX, 0.04 + i * 0.22, -BODY.torso.Z / 2 - 0.02),
			Vector3.new(0.56, 0.07, 0.03),
			BONE,
			flesh
		)
	end
	add(
		"Hem",
		torso
			* CFrame.new(between(random, -0.35, 0.35), -BODY.torso.Y / 2 - 0.16, -BODY.torso.Z / 2 + 0.05)
			* rx(between(random, 8, 22)),
		Vector3.new(between(random, 0.4, 0.7), 0.38, 0.03),
		shirt,
		cloth
	)
	for side = 1, 2 do
		local sx = if side == 1 then 1 else -1
		local tag = if side == 1 then "R" else "L"
		local shoulder = waist * CFrame.new(sx * BODY.shoulderX, BODY.shoulderY, 0) * pose.shoulder[side]
		add("UpperArm" .. tag, shoulder * CFrame.new(0, -BODY.upperArm.Y / 2, 0), BODY.upperArm, shirt, cloth)
		local elbow = shoulder * CFrame.new(0, -BODY.upperArm.Y, 0) * pose.elbow[side]
		local wrist = elbow * CFrame.new(0, -BODY.foreArm.Y, 0) * pose.wrist[side]
		if chance(random, 0.2) then
			-- Picked to the bone below the elbow
			add(
				"ForeArm" .. tag,
				elbow * CFrame.new(0, -BODY.foreArm.Y / 2, 0),
				Vector3.new(0.17, BODY.foreArm.Y, 0.17),
				BONE,
				flesh
			)
			add("Hand" .. tag, wrist * CFrame.new(0, -BODY.hand.Y / 2, 0), Vector3.new(0.24, 0.38, 0.1), BONE, flesh)
		else
			add("ForeArm" .. tag, elbow * CFrame.new(0, -BODY.foreArm.Y / 2, 0), BODY.foreArm, skin, flesh)
			add("Hand" .. tag, wrist * CFrame.new(0, -BODY.hand.Y / 2, 0), BODY.hand, skin, flesh)
		end
		local hip = root * CFrame.new(sx * BODY.hipX, BODY.hipY, 0) * pose.hip[side]
		add("Thigh" .. tag, hip * CFrame.new(0, -BODY.thigh.Y / 2, 0), BODY.thigh, trousers, cloth)
		local knee = hip * CFrame.new(0, -BODY.thigh.Y, 0) * pose.knee[side]
		add("Shin" .. tag, knee * CFrame.new(0, -BODY.shin.Y / 2, 0), BODY.shin, trousers, cloth)
		local ankle = knee * CFrame.new(0, -BODY.shin.Y, 0) * pose.ankle[side]
		add(
			"Shoe" .. tag,
			ankle * CFrame.new(0, -BODY.foot.Y / 2 + 0.02, -0.2),
			BODY.foot,
			rgb(30, 26, 24),
			Enum.Material.Leather
		)
	end
	return pieces
end

local function newPose(kind: PoseKind, random: Random): Pose
	local function r(a: number, b: number): number
		return between(random, a, b)
	end
	if kind == "Slumped" then
		-- Sat against a wall (+Z behind), chin on chest, legs out or one knee drawn up with its foot flat on the floor
		local tilt = r(8, 14)
		local lean = r(8, 20)
		local back = tilt + lean
		local raised = random:NextInteger(0, 2) -- 0: both out; 1/2: that leg drawn up
		local hip: { CFrame } = {}
		local knee: { CFrame } = {}
		local ankle: { CFrame } = {}
		for side = 1, 2 do
			-- The shin falls back to the floor what the thigh rose, so the heel rests level with the seat; a drawn-up
			-- foot flexes down to stand flat
			local splay = r(6, 18) * (if side == 1 then -1 else 1)
			local up = raised == side
			local rise = math.rad(if up then r(30, 48) else r(1, 8))
			local drop = math.asin(math.clamp(BODY.thigh.Y * math.sin(rise) / BODY.shin.Y, 0, 1))
			table.insert(hip, ry(splay) * rx(90 - tilt + math.deg(rise)))
			table.insert(knee, rx(-math.deg(rise + drop)))
			table.insert(ankle, if up then rx(-(90 - math.deg(drop)) + r(-4, 4)) else rx(-r(5, 25)))
		end
		return {
			root = rx(tilt),
			waist = rx(lean) * rz(r(-7, 7)),
			neck = rx(-r(28, 46)) * rz(r(-22, 22)),
			shoulder = { rx(-back + r(18, 34)) * rz(r(8, 18)), rx(-back + r(18, 34)) * rz(-r(8, 18)) },
			elbow = { rx(r(25, 60)), rx(r(25, 60)) },
			wrist = { rx(r(0, 20)), rx(r(0, 20)) },
			hip = hip,
			knee = knee,
			ankle = ankle,
		}
	elseif kind == "FaceDown" then
		-- Face down (head toward -Z), head turned onto one cheek, one arm flung past the head, a knee bent with its
		-- foot in the air, toes pointed back along the floor
		local reach = random:NextInteger(1, 2)
		local function shoulder(side: number): CFrame
			local s = if side == 1 then 1 else -1
			return if reach == side then rz(s * r(140, 165)) * rx(r(0, 6)) else rz(s * r(12, 30)) * rx(r(3, 9))
		end
		local function elbow(side: number): CFrame
			local s = if side == 1 then 1 else -1
			return rz(-s * r(10, 50))
		end
		local bent = random:NextInteger(1, 2)
		return {
			root = rx(-90) * ry(r(-4, 4)),
			waist = ry(r(-4, 4)) * rz(r(-5, 5)),
			neck = rx(r(4, 12)) * ry(if chance(random, 0.5) then r(70, 85) else -r(70, 85)),
			shoulder = { shoulder(1), shoulder(2) },
			elbow = { elbow(1), elbow(2) },
			wrist = { rz(r(-10, 10)), rz(r(-10, 10)) },
			hip = { rz(r(4, 12)), rz(-r(4, 12)) },
			knee = {
				if bent == 1 then rx(-r(25, 55)) else rx(-r(0, 8)),
				if bent == 2 then rx(-r(25, 55)) else rx(-r(0, 8)),
			},
			ankle = { rx(-r(65, 85)), rx(-r(65, 85)) },
		}
	end
	-- Curled on its left side (right side up), knees to the chest, hands at the face. The shoulders are broader than
	-- the hips, so the body lies tipped head-up onto its lower shoulder.
	return {
		root = rz(90 - r(11, 15)) * rx(r(-4, 4)),
		waist = rx(-r(22, 36)),
		neck = rx(-r(25, 40)) * rz(-r(0, 10)),
		shoulder = { rx(r(55, 80)) * rz(-r(18, 30)), rx(r(60, 85)) },
		elbow = { rx(r(80, 115)), rx(r(85, 120)) },
		wrist = { rx(r(0, 20)), rx(r(0, 20)) },
		hip = { rx(r(95, 115)) * rz(-r(3, 8)), rx(r(92, 112)) },
		knee = { rx(-r(105, 125)), rx(-r(100, 125)) },
		ankle = { rx(-r(5, 25)), rx(-r(5, 25)) },
	}
end

local function piece(pieces: { Piece }, name: string): Piece?
	for _, entry in pieces do
		if entry.name == name then
			return entry
		end
	end
	return nil
end

-- How high the pelvis and torso undersides may rest once the body is settled on its lowest point: sat on the floor,
-- lying flat, or on its side on shoulder and hip.
local REST_LIMIT: { [PoseKind]: { pelvis: number, torso: number } } = {
	Slumped = { pelvis = 0.3, torso = math.huge },
	FaceDown = { pelvis = 0.3, torso = 0.3 },
	Curled = { pelvis = 0.35, torso = 0.7 },
}

-- Builds a pose in corpse space (origin on the ground, -Z the facing) settled on y = 0 (and, slumped, backed onto
-- the wall at z = 0). Nil when this draw is not physically plausible (propped up off the floor on a limb).
local function restPose(kind: PoseKind, random: Random): { Piece }?
	local pieces = posePieces(newPose(kind, random), random)
	Kit.offset(pieces, Vector3.new(0, 0.01 - lowest(pieces), 0))
	local pelvis = piece(pieces, "Pelvis")
	local torso = piece(pieces, "Torso")
	if not (pelvis and torso) then
		return nil
	end
	local limit = REST_LIMIT[kind]
	if (Kit.bounds(pelvis)).Y > limit.pelvis or (Kit.bounds(torso)).Y > limit.torso then
		return nil
	end
	if kind == "Slumped" then
		local back = -math.huge
		for _, entry in pieces do
			local _, hi = Kit.bounds(entry)
			back = math.max(back, hi.Z)
		end
		Kit.offset(pieces, Vector3.new(0, 0, -back - 0.03))
	end
	return pieces
end

-- Dried blood under the body: pools under the torso and hips and one smear.
local function bloodPieces(pieces: { Piece }, random: Random): { Piece }
	local out: { Piece } = {}
	local spots: { { string | number } } = { { "Torso", 1.9, 3 }, { "Pelvis", 1.2, 2 }, { "Head", 0.8, 1.2 } }
	for i, spot in spots do
		local entry = piece(pieces, spot[1] :: string)
		if entry then
			local p = entry.cframe.Position
			local d = between(random, spot[2] :: number, spot[3] :: number)
			table.insert(
				out,
				Kit.disc(
					"Blood" .. i,
					Vector3.new(p.X + between(random, -0.3, 0.3), 0.002 + i * 0.004, p.Z + between(random, -0.3, 0.3)),
					d,
					0.012,
					"Fixture",
					"Detail",
					paint(pick(random, BLOOD), Enum.Material.SmoothPlastic, 0.1)
				)
			)
		end
	end
	local torso = piece(pieces, "Torso")
	if torso then
		local p = torso.cframe.Position
		local length = between(random, 1.4, 2.4)
		local angle = between(random, 0, 360)
		local cf = CFrame.new(p.X, 0.02, p.Z) * ry(angle) * CFrame.new(0, 0, -length / 2 - 0.4)
		table.insert(
			out,
			Kit.block(
				"Smear",
				cf,
				Vector3.new(between(random, 0.35, 0.6), 0.012, length),
				"Fixture",
				"Detail",
				paint(pick(random, BLOOD), Enum.Material.SmoothPlastic, 0.25)
			)
		)
	end
	return out
end

-- A spot a pose may be tried at: level-local ground position and yaw.
type BodySpot = { position: Vector3, yaw: number }
-- A pose kind and the spots it is tried at, in order.
type PoseTry = { kind: PoseKind, spots: { BodySpot } }

-- Where a lying body may go round its anchor, nearest first: the anchor itself, then rings out to 4.8 studs (a door's
-- swing, a grate front or a locker bank may crowd the exact spot).
local LYING_SHIFTS: { Vector3 } = { Vector3.zero }
for ring = 1, 6 do
	for k = 0, 7 do
		local angle = (k + (ring % 2) * 0.5) * math.pi / 4
		table.insert(LYING_SHIFTS, Vector3.new(math.cos(angle), 0, math.sin(angle)) * (ring * 0.8))
	end
end
local LYING_TURNS: { number } = { 0, 90, -90, 180, 45, -45, 135, -135 }
-- How far a body sat against a wall may slide along it from the point behind its anchor, nearest first.
local WALL_SLIDES: { number } = { 0, 0.8, -0.8, 1.6, -1.6, 2.4, -2.4, 3.2, -3.2 }
-- The pieces a body rests its weight on (with the blood pools, they must lie on carried floor).
local CONTACTS: { string } = { "Pelvis", "Torso", "ShoeR", "ShoeL" }

-- Copies of `pieces` moved by `frame` (corpse space to world).
local function placedCopy(pieces: { Piece }, frame: CFrame): { Piece }
	local out: { Piece } = table.create(#pieces)
	for i, entry in pieces do
		local copy = table.clone(entry)
		copy.cframe = frame * entry.cframe
		out[i] = copy
	end
	return out
end

local function buildCorpse(anchor: Anchor, cframe: CFrame, parent: Instance, random: Random)
	local layout = layoutOfAnchor(anchor, cframe)
	if not layout then
		return
	end
	local info = Kit.info(layout)
	local room = info.rooms[anchor.room]
	local inner = info.inner[anchor.room]
	if not (room and inner) then
		return
	end
	local ground = anchor.pos.Y
	local yaw = anchor.yaw or 0
	-- Sat with its back to a wall within reach, slid along it until it fits
	local walls: { WallSide } = {}
	for _, normal in { Vector3.xAxis, -Vector3.xAxis, Vector3.zAxis, -Vector3.zAxis } do
		local wall = sideBehind(room, inner, normal)
		local distance = (across(wall, anchor.pos.X, anchor.pos.Z) - wall.face)
			* (if wall.side == "N" or wall.side == "W" then 1 else -1)
		if distance >= 0 and distance <= 2.6 then
			table.insert(walls, wall)
		end
	end
	local seated: { BodySpot } = {}
	for _, wall in shuffled(random, walls) do
		local base = if wall.axis == "Z"
			then Vector3.new(anchor.pos.X, ground, wall.face)
			else Vector3.new(wall.face, ground, anchor.pos.Z)
		local tangent = if wall.axis == "Z" then Vector3.xAxis else Vector3.zAxis
		for _, slide in WALL_SLIDES do
			table.insert(seated, { position = base + tangent * slide, yaw = yawOf(wall.normal) })
		end
	end
	-- Lying at the anchor, or as near it as the room allows
	local lyingSpots: { BodySpot } = {}
	for _, shift in LYING_SHIFTS do
		for _, turn in LYING_TURNS do
			table.insert(lyingSpots, { position = anchor.pos + shift, yaw = yaw + turn })
		end
	end
	local flip = random:NextInteger(1, 2)
	local first: PoseKind, second: PoseKind = LYING_POSES[flip], LYING_POSES[3 - flip]
	local function try(kind: PoseKind, spots: { BodySpot }): PoseTry
		return { kind = kind, spots = spots }
	end
	local order: { PoseTry } = if #seated > 0 and chance(random, 0.65)
		then { try("Slumped", seated), try(first, lyingSpots), try(second, lyingSpots) }
		else { try(first, lyingSpots), try("Slumped", seated), try(second, lyingSpots) }
	local ignore = { ClutterSpot = true }
	for _, entry in order do
		if #entry.spots == 0 then
			continue
		end
		-- One plausible pose of this kind (a few draws), tried at every spot in turn
		local body: { Piece }? = nil
		for _ = 1, 4 do
			body = restPose(entry.kind, random)
			if body then
				break
			end
		end
		if not body then
			continue
		end
		local blood = bloodPieces(body, random)
		local all = table.clone(body)
		local supports: { number } = {}
		for _, name in CONTACTS do
			for i, part in body do
				if part.name == name then
					table.insert(supports, i)
				end
			end
		end
		for _, part in blood do
			table.insert(all, part)
			table.insert(supports, #all)
		end
		for _, spot in entry.spots do
			local frame = CFrame.new(info.origin + spot.position) * ry(spot.yaw)
			local placed = placedCopy(all, frame)
			local contacts: { Box } = {}
			for _, index in supports do
				table.insert(contacts, Kit.localBox(info, placed[index]))
			end
			local fits = Kit.fits(info, placed, {
				owner = anchor.id,
				ignore = ignore,
				room = anchor.room,
				margin = if entry.kind == "Slumped" then 0 else 0.15,
				ground = ground,
				contacts = contacts,
			})
			if fits then
				local model = PropKit.model(parent, "Corpse_" .. anchor.id, frame)
				Kit.realize(model, placed)
				model:AddTag(Tags.Corpse)
				PropKit.setAttributes(model, {
					[W.AnchorId] = anchor.id,
					[W.LevelId] = layout.id,
					[W.ZoneId] = anchor.room,
				})
				return
			end
		end
	end
	log.warn("%s: no pose fits", anchor.id)
end

--------------------------------------------------------------------------------
-- Clutter (cosmetic)
--------------------------------------------------------------------------------

type ItemKind =
	"Paper"
	| "Book"
	| "OpenBook"
	| "Chair"
	| "Backpack"
	| "Bottle"
	| "Tile"
	| "Beaker"
	| "Ball"
	| "Box"
	| "Chunk"

local CHAIR_SHELL: { Color3 } = { rgb(70, 76, 84), rgb(92, 62, 46), rgb(64, 74, 58), rgb(82, 80, 72) }
local BAGS: { Color3 } = { rgb(46, 54, 74), rgb(84, 40, 40), rgb(44, 58, 46), rgb(70, 66, 58), rgb(30, 30, 32) }
local BOTTLES: { Color3 } = { rgb(52, 78, 52), rgb(78, 52, 30), rgb(110, 118, 114) }

-- An item in item space (on the ground at y = 0, around the origin).
local function itemPieces(kind: ItemKind, room: Room, random: Random): { Piece }
	local function block(name: string, cf: CFrame, size: Vector3, key: string, options: Geometry.PartOptions?): Piece
		return Kit.block(name, cf, size, key, "Detail", options)
	end
	if kind == "Paper" then
		return { paperSheet("Paper", CFrame.new(0, 0.008, 0) * rx(between(random, -2, 2)), random) }
	elseif kind == "Book" then
		return {
			block(
				"Book",
				CFrame.new(0, 0.08, 0),
				Vector3.new(0.78, 0.16, 1.02),
				"Fixture",
				paint(pick(random, BOOK), Enum.Material.Fabric)
			),
		}
	elseif kind == "OpenBook" then
		local cover = paint(pick(random, BOOK), Enum.Material.Fabric)
		local splay = between(random, 5, 12)
		return {
			block(
				"PageL",
				CFrame.new(0, 0.04, 0) * rz(splay) * CFrame.new(-0.38, 0, 0),
				Vector3.new(0.74, 0.06, 1),
				"Fixture",
				cover
			),
			block(
				"PageR",
				CFrame.new(0, 0.04, 0) * rz(-splay) * CFrame.new(0.38, 0, 0),
				Vector3.new(0.74, 0.06, 1),
				"Fixture",
				cover
			),
		}
	elseif kind == "Chair" then
		-- A school chair knocked over: built upright, then laid on its back or its side
		local shell = paint(pick(random, CHAIR_SHELL), Enum.Material.SmoothPlastic)
		local frameMetal = paint(rgb(60, 62, 62), Enum.Material.Metal)
		local list: { Piece } = {
			block("Seat", CFrame.new(0, 1.5, 0), Vector3.new(1.3, 0.1, 1.25), "Fixture", shell),
			block("Backrest", CFrame.new(0, 2.32, 0.6) * rx(-8), Vector3.new(1.25, 0.72, 0.08), "Fixture", shell),
		}
		for i, leg in
			{ { -0.55, -0.52, 1.46 }, { 0.55, -0.52, 1.46 }, { -0.55, 0.55, 2.7 }, { 0.55, 0.55, 2.7 } } :: { { number } }
		do
			table.insert(
				list,
				Kit.cylinder(
					"Leg" .. i,
					Vector3.new(leg[1], 0, leg[2]),
					Vector3.new(leg[1], leg[3], leg[2] + (if leg[3] > 2 then 0.08 else 0)),
					0.1,
					"TrimMetal",
					"Detail",
					frameMetal
				)
			)
		end
		local fall = if chance(random, 0.5) then rx(-90 - between(random, 0, 10)) else rz(90 + between(random, -8, 8))
		Kit.transform(list, fall)
		Kit.offset(list, Vector3.new(0, -lowest(list) + 0.005, 0))
		return list
	elseif kind == "Backpack" then
		local bag = paint(pick(random, BAGS), Enum.Material.Fabric)
		local list: { Piece } = {
			block("Pack", CFrame.new(0, 0.55, 0), Vector3.new(1.05, 1.1, 0.5), "Fixture", bag),
			block("Pocket", CFrame.new(0, 0.4, -0.32), Vector3.new(0.8, 0.55, 0.18), "Fixture", bag),
			block(
				"Strap",
				CFrame.new(0.28, 0.6, 0.29) * rx(6),
				Vector3.new(0.14, 0.95, 0.08),
				"Fixture",
				paint(rgb(28, 28, 28), Enum.Material.Fabric)
			),
		}
		Kit.transform(list, rx(-90 + between(random, -12, 12)) * rz(between(random, -10, 10)))
		Kit.offset(list, Vector3.new(0, -lowest(list) + 0.005, 0))
		return list
	elseif kind == "Bottle" or kind == "Beaker" then
		local isBeaker = kind == "Beaker"
		local d = if isBeaker then 0.45 else 0.28
		local h = if isBeaker then 0.55 else 0.85
		local color = if isBeaker then rgb(130, 138, 134) else pick(random, BOTTLES)
		if chance(random, 0.6) then
			return {
				Kit.cylinder(
					kind,
					Vector3.new(-h / 2, d / 2, 0),
					Vector3.new(h / 2, d / 2, 0),
					d,
					"Glass",
					"Detail",
					glass(color, 0.35)
				),
			}
		end
		return { Kit.cylinder(kind, Vector3.zero, Vector3.new(0, h, 0), d, "Glass", "Detail", glass(color, 0.35)) }
	elseif kind == "Tile" then
		local w, d = between(random, 1, 1.9), between(random, 0.8, 1.5)
		local lift = between(random, 0, 9)
		return {
			block(
				"Tile",
				CFrame.new(0, 0.06 + math.sin(math.rad(lift)) * w / 2, 0) * rz(lift),
				Vector3.new(w, 0.1, d),
				SchoolShellBuilder.ceilingKey(room)
			),
		}
	elseif kind == "Chunk" then
		local s = between(random, 0.5, 0.9)
		return {
			block(
				"Chunk",
				CFrame.new(0, s * 0.2, 0) * rz(between(random, -10, 10)),
				Vector3.new(s, s * 0.45, s * 1.3),
				if room.kind == "Roof" then "Brick" else "Rubble"
			),
		}
	elseif kind == "Ball" then
		local d = between(random, 0.9, 1.15)
		return {
			Kit.ball(
				"Ball",
				Vector3.new(0, d / 2, 0),
				d,
				"Rubber",
				"Detail",
				paint(rgb(104, 60, 40), Enum.Material.Rubber)
			),
		}
	end
	-- A crushed cardboard box with a torn-open flap
	local s = Vector3.new(between(random, 1.2, 1.6), between(random, 0.8, 1.1), between(random, 1, 1.4))
	local card = paint(rgb(96, 78, 52), Enum.Material.Cardboard)
	local list: { Piece } = {
		block("Carton", CFrame.new(0, s.Y / 2, 0) * rz(between(random, -6, 6)), s, "Fixture", card),
		block(
			"Flap",
			CFrame.new(0, s.Y + 0.02, s.Z / 2) * rx(-between(random, 40, 110)) * CFrame.new(0, 0, s.Z / 4),
			Vector3.new(s.X - 0.05, 0.03, s.Z / 2),
			"Fixture",
			card
		),
	}
	Kit.offset(list, Vector3.new(0, -lowest(list) + 0.005, 0))
	return list
end

-- The kinds one clutter heap is made of (in placement order), within the part budget.
local function clutterList(room: Room, random: Random): { ItemKind }
	local list: { ItemKind } = {}
	local parts = 0
	local function push(kind: ItemKind, count: number, cost: number)
		for _ = 1, count do
			if parts + cost > BUDGET.Clutter then
				return
			end
			table.insert(list, kind)
			parts += cost
		end
	end
	local hasCeiling = not room.noCeiling and room.kind ~= "Chase"
	if chance(random, 0.55) then
		push("Chair", 1, 6)
	end
	if chance(random, 0.6) then
		push("Backpack", 1, 3)
	end
	local kind = room.kind
	if kind == "Lab" then
		push("Beaker", random:NextInteger(1, 2), 1)
	elseif kind == "Gym" or kind == "Pool" or kind == "LockerRoom" then
		push("Ball", 1, 1)
	elseif kind == "Storage" or kind == "Boiler" or kind == "LobbyHall" then
		push("Box", 1, 2)
	end
	if hasCeiling then
		push("Tile", random:NextInteger(1, 3), 1)
	else
		push("Chunk", random:NextInteger(1, 3), 1)
	end
	push("OpenBook", if chance(random, 0.5) then 1 else 0, 2)
	push("Book", random:NextInteger(1, 2), 1)
	push("Bottle", random:NextInteger(1, 2), 1)
	push("Paper", random:NextInteger(3, 6), 1)
	return list
end

local function buildClutter(anchor: Anchor, cframe: CFrame, parent: Instance, random: Random)
	local layout = layoutOfAnchor(anchor, cframe)
	if not layout then
		return
	end
	local info = Kit.info(layout)
	local room = info.rooms[anchor.room]
	if not room then
		return
	end
	local ground = anchor.pos.Y
	local radius = between(random, 2, 6)
	local placed: { Piece } = {}
	local ignore = { ClutterSpot = true }
	for index, kind: ItemKind in clutterList(room, random) do
		for _ = 1, 14 do
			local r = radius * math.sqrt(random:NextNumber())
			local angle = between(random, 0, math.pi * 2)
			local spot = info.origin + anchor.pos + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r)
			local item = itemPieces(kind, room, random)
			Kit.transform(item, CFrame.new(spot) * ry(between(random, 0, 360)))
			if
				Kit.fits(info, item, { ignore = ignore, room = anchor.room, margin = 0.35, ground = ground })
				and not piecesOverlap(info, item, placed)
			then
				for _, entry in item do
					entry.name = string.format("%s_%d", entry.name, index)
					table.insert(placed, entry)
				end
				break
			end
		end
	end
	if #placed == 0 then
		return
	end
	local model = PropKit.model(parent, "Clutter_" .. anchor.id, CFrame.new(info.origin + anchor.pos))
	Kit.realize(model, placed)
	PropKit.setAttributes(model, {
		[W.AnchorId] = anchor.id,
		[W.LevelId] = layout.id,
		[W.ZoneId] = anchor.room,
	})
end

--------------------------------------------------------------------------------
-- Drips (cosmetic)
--------------------------------------------------------------------------------

local function buildDripCosmetic(anchor: Anchor, cframe: CFrame, parent: Instance, random: Random)
	local layout = layoutOfAnchor(anchor, cframe)
	if not layout then
		return
	end
	local info = Kit.info(layout)
	if not planRun(info, anchor, nil) then
		return -- no pipe was built here either
	end
	local drip = dripPointIn(info, anchor)
	local surface = dripSurface(info, anchor)
	local surfaceY = info.origin.Y + surface
	local fall = math.max(0.5, drip.Y - surfaceY)
	local gravity = Workspace.Gravity
	local model = PropKit.model(parent, "Drips_" .. anchor.id, CFrame.new(drip))
	local host = Geometry.part(model, "Emitter", CFrame.new(drip), Vector3.one * 0.2, "Water", {
		transparency = 1,
		canCollide = false,
		canQuery = false,
		castShadow = false,
	})
	PropKit.detail(host)
	local lifetime = math.sqrt(2 * fall / gravity)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Drops"
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Rate = between(random, 0.7, 1.8)
	emitter.Lifetime = NumberRange.new(lifetime * 0.97, lifetime)
	emitter.Speed = NumberRange.new(0.2, 0.6)
	emitter.SpreadAngle = Vector2.new(2, 2)
	emitter.Acceleration = Vector3.new(0, -gravity, 0)
	emitter.Drag = 0
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.07),
		NumberSequenceKeypoint.new(1, 0.05),
	})
	emitter.Squash = NumberSequence.new(1.4)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 0.35),
	})
	local water =
		Color3.new(math.min(1, WATER_COLOR.R * 2.6), math.min(1, WATER_COLOR.G * 2.6), math.min(1, WATER_COLOR.B * 2.6))
	emitter.Color = ColorSequence.new(water)
	emitter.LightInfluence = 1
	emitter.LightEmission = 0.05
	emitter.Orientation = Enum.ParticleOrientation.VelocityParallel
	emitter.Parent = host
	-- Ripple rings: a pale ring under each dark centre, stacked just above the puddle (or the pool surface)
	local base = Vector3.new(drip.X, surfaceY + 0.045, drip.Z)
	local outer = between(random, 1.3, 1.6)
	local inner = between(random, 0.55, 0.75)
	local pale = { material = Enum.Material.Glass, color = rgb(150, 160, 150), transparency = 0.72, reflectance = 0.2 }
	local dark = { material = Enum.Material.Glass, color = WATER_COLOR, transparency = 0.25, reflectance = 0.15 }
	local rings = {
		Kit.disc("RingOuter", base, outer, 0.008, "Water", "Detail", pale),
		Kit.disc("RingOuterCore", base + Vector3.new(0, 0.008, 0), outer - 0.08, 0.008, "Water", "Detail", dark),
		Kit.disc("RingInner", base + Vector3.new(0, 0.016, 0), inner, 0.008, "Water", "Detail", pale),
		Kit.disc("RingInnerCore", base + Vector3.new(0, 0.024, 0), inner - 0.07, 0.008, "Water", "Detail", dark),
	}
	Kit.realize(model, rings)
	PropKit.setAttributes(model, {
		[W.AnchorId] = anchor.id,
		[W.LevelId] = layout.id,
		[W.ZoneId] = anchor.room,
	})
end

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

SetDressingBuilder.Budget = BUDGET
SetDressingBuilder.Kit = table.freeze(Kit)

function SetDressingBuilder.register(registrar: PropKit.Registrar)
	registrar.static("LabCounter", buildLabCounters)
	registrar.static("SmashedLocker", buildSmashedLockers)
	registrar.static("DripPipe", buildDripPipes)
	registrar.static("FloorDebris", buildFloorDebris)
	registrar.cosmetic("Corpse", buildCorpse)
	registrar.cosmetic("Clutter", buildClutter)
	registrar.cosmetic("DripPipe", buildDripCosmetic)
end

return table.freeze(SetDressingBuilder)
