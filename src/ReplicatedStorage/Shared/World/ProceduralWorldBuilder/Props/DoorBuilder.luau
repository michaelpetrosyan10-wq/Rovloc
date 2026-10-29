--!strict
-- DoorBuilder: every door leaf in the school, from the `Door_<id>` attachments SchoolShellBuilder leaves at floor
-- level in the middle of each opening, on the wall's centre plane, LookVector from door.rooms[1] toward door.rooms[2]
-- (attrs DoorWidth, DoorHeight, DoorKind, ScriptedId?).
--
-- Static kind "OpenDoors" (once at boot, every layout including the Lobby, into <level>.Props): every ordinary door
-- (kind "Door") gets a wooden classroom door (stiles and rails around a small wired-glass window, kick plate, knob)
-- standing open about 95-110 degrees, a few hanging crooked off their lower hinge. Each one picks, from a seeded order,
-- the first swing room / hinge jamb / angle that keeps the leaf inside that room and clear of every doorway's walking
-- lane, the vent grates' swing and exit space, the props other builders stand on layout anchors, debris piles,
-- platforms, pillars, basins, the fixture doors' swing and the shell's own geometry; it prefers to swing into the
-- room rather than into a corridor. Colliding pieces are MonsterPassthrough (the Creature walks through, players bump
-- them); no prompts, no state.
--
-- Fixture kind "Doors" (rebuilt every run into Workspace.Runtime.<level>): Model "Door_<id>" per Ajar, Gate, Airlock
-- and RoofDoor door, with attributes DoorId, DoorKind, DoorState ("Open"), LevelId, DoorWidth, DoorHeight,
-- ScriptedId (when the door has one; tag ScriptedDoor), and FromLevel / ToLevel on airlocks (tag AirlockDoor) from
-- the stairwell the vestibule serves. Every leaf collides in the Default group, so a shut door really blocks.
--   * Ajar (the Level 1 ClassroomDoor): the classroom door, leaf "Leaf", left 35 degrees open. It swings out of the
--     room the Creature's scare pose is in, hinged on the jamb toward the pose, so the diagonal view into the room
--     stays open.
--   * Gate (the Level 1 HallwayGate): a steel roll-down security grille on the rooms[1] face. Housing box above the
--     opening ("Base"), side guide rails, and the grille as telescoping sections, leaf "Grille" (the bottom section
--     with the bottom bar, pull handle and padlock hasp) and "Grille2", "Grille3" above it: vertical bars and
--     horizontal slats, each section with an invisible collision plate between its bars (CanQuery off, so sight and
--     thrown flasks still pass through the gaps). Rest pose = fully down; built rolled up inside the housing. The
--     housing face and both rails are painted in yellow-and-black hazard stripes (SurfaceArt).
--   * Airlock: heavy red-painted steel double fire doors, leaves "LeftLeaf" / "RightLeaf" (as seen looking along their
--     swing), push bars, small wired windows, an astragal on the right leaf, in a wide steel frame (their hinge pins
--     sit far enough out that the push bars stay clear of the opening at 90 degrees), with a "FIRE DOOR -
--     KEEP CLOSED" sign above on the vestibule side. Rest = shut in the AirlockDoorWidth opening; built open 90 degrees
--     into the vestibule (into the corridor when the vestibule has no room for them). Both faces of the frame's jambs
--     and head are painted in yellow-and-black hazard stripes (SurfaceArt).
--   * RoofDoor (the Level 5 RoofStairDoor, and the Level 3 EquipmentStoreDoor the floor objective locks): a dented
--     steel door, leaf "Leaf", in a steel frame, with a "ROOF ACCESS" sign on the stairwell side when one of its rooms
--     is a stairwell. Rest = shut; built open (onto the roof).
-- Every leaf is surface-mounted on its swing-side face in front of the casing, hung from hinge knuckles whose pin runs
-- along its front face just outside the opening: open at 90 degrees or more it stands entirely outside the doorway's
-- clear width, and at no angle does it cut back into the casing or the wall.
--
-- Poses (pure; PropKit leaves). The fully open pose of each leaf is an Attachment "<leaf>Open" on Base, the torn-off
-- pose "<leaf>Smashed" (with "<leaf>Centre", the rest centre the throw is computed about).
--   setOpen(model, openness)   0 shut .. 1 fully open: a swing about the hinge for leaves, a vertical slide into the
--                              housing for the grille's sections.
--   setSmashed(model, t)       0 shut .. 1 smashed: a single leaf is torn off its hinges and thrown down flat into the
--                              room it swings into; both fire doors buckle half off their hinges; the grille's sections
--                              are torn out of their rails and dropped in a heap in front.
--   openTransform / smashedTransform(model, leaf, value) are the same poses for one leaf as a transform from its rest
--   pivot, and leafNames(model) lists the leaves: DoorService (server) and DoorController (clients) step a door's
--   motion through them, so both sides compute identical poses (Shared/Sequence/DoorMotion).
-- Budgets: static door <= 8 parts, Ajar / RoofDoor <= 12, Airlock <= 30, Gate <= 45.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(script.Parent.Parent.Geometry)
local PropKit = require(script.Parent.PropKit)
local SurfaceArt = require(script.Parent.Parent.SurfaceArt)
local VentGrateBuilder = require(script.Parent.VentGrateBuilder)

local log = Log.new("Doors")

type Layout = LayoutSchema.LevelLayout
type Room = LayoutSchema.Room
type Door = LayoutSchema.Door
type Footprint = VentGrateBuilder.Footprint

-- One door opening, level-local.
export type Site = {
	door: Door,
	frame: CFrame, -- opening centre at floor level on the wall's centre plane, LookVector rooms[1] -> rooms[2]
	width: number,
	height: number,
	rooms: { Room }, -- { rooms[1], rooms[2] }
	ceiling: number, -- lowest ceiling underside of the two rooms (level-local Y)
}

export type LeafStyle = "Wood" | "Fire" | "Steel"

-- One hinged leaf. Lengths in studs, angles in radians. Geometry is in the swing frame: the door frame turned so its
-- LookVector points into the room the leaf swings into.
export type Leaf = {
	name: string,
	style: LeafStyle,
	swing: number, -- +1: swings into rooms[2] (along the door frame's LookVector), -1: into rooms[1]
	hinge: number, -- -1: hinge on the swing frame's left jamb (-RightVector), +1: on the right jamb
	hingeU: number, -- hinge pin, along the swing frame's RightVector
	hingeOut: number, -- the pin this far outside the opening edge
	width: number, -- hinge edge to free edge
	thickness: number,
	bottom: number,
	top: number,
	front: number, -- the front face (and the hinge pin) this far out from the wall's centre plane
	angle: number, -- built pose
	full: number, -- fully open
	tilt: number, -- hanging crooked: the free side dropped this much in the leaf's plane (0 = hung true)
	lean: number, -- hanging crooked: the top leaning away from the doorway
}

local W = Attributes.World
local Names = Instances.Names

local EPS = 1e-4
local WALL_HALF = WorldConfig.WallThickness / 2
local CEILING_PANEL = 0.4

-- Casing (Geometry.doorTrims) dimensions the leaves keep clear of, and the steel frames built here to match
local TRIM_WIDTH = 0.35
local TRIM_PROUD = 0.15
local TRIM_REVEAL = 0.05
local TRIM_FRONT = WALL_HALF + TRIM_PROUD

-- Leaves
local LEAF_THICKNESS = 0.24
local LEAF_BACK = TRIM_FRONT + 0.04 -- back face of a shut leaf: clear of the casing
local HINGE_OUT = 0.3 -- hinge pin outside the opening edge (>= thickness + the casing reveal + a gap)
-- A fire door's pin sits further out, over its wide steel frame, so the push bar on its back face stays out of the
-- clear opening when the leaf stands open at 90 degrees (>= thickness + bar reach + the frame reveal).
local FIRE_HINGE_OUT = 0.62
local FIRE_FRAME_WIDTH = 0.7
local PUSH_BAR_STANDOFF = 0.1 -- gap between the back face and the bar
local PUSH_BAR_END = 0.3 -- the bar stops this short of the free edge
local LATCH_GAP = 0.06 -- the shut leaf stops short of the far casing's outer edge
local FLOOR_GAP = 0.03 -- under the gate's bottom bar
local LEAF_FLOOR_GAP = 0.12 -- under a hinged leaf: clear of the glass and litter on the floor it swings over
local HEAD_OVERLAP = 0.12 -- a shut leaf laps the head casing
local CEILING_GAP = 0.06
local MEETING_GAP = 0.03 -- between the two leaves of a double door
local KNUCKLE_DIAMETER = 0.14
local KNUCKLE_LENGTH = 0.75
local HANDLE_HEIGHT = 3.6
local HANDLE_REACH = 0.28 -- knob / lever out from each face
local HANDLE_INSET = 0.5 -- from the free edge

-- Static doors
local STATIC_MIN_ANGLE = math.rad(95)
local STATIC_MAX_ANGLE = math.rad(110)
local STATIC_FALLBACK_ANGLES: { number } = { math.rad(92), math.rad(90) }
local CROOKED_CHANCE = 0.12
local CROOKED_TILT_MIN = math.rad(2.5)
local CROOKED_TILT_MAX = math.rad(5)
local CROOKED_LEAN_MIN = math.rad(1.5)
local CROOKED_LEAN_MAX = math.rad(3)
local ROOM_MARGIN = 0.04
local LANE_DEPTH = 2.5 -- a doorway's walking lane reaches this far into each room

-- Fixture doors
local AJAR_ANGLE = math.rad(35)
local SWING_FULL_ANGLES: { number } = { math.rad(100), math.rad(95), math.rad(90) }
local AIRLOCK_ANGLE = math.rad(90)
local THROW_HOP = 0.8
local BUCKLE_HOP = 0.15

-- Gate
local GATE_SECTION_DEPTH = 0.18
local GATE_SECTION_GAP = 0.05
local GATE_OVERLAP = 0.1 -- sections overlap this much when down
local GATE_HOUSING_MAX = 3.5
local GATE_BARS = 8
local GATE_SLAT = 0.22
local GATE_BOTTOM_BAR = 0.32
local GATE_BAR_DIAMETER = 0.12
local GATE_RAIL_MAX = 0.5
local GATE_ENGAGE = 0.3 -- section ends running inside the rails
local GATE_HANDLE_REACH = 0.18
local GATE_HOUSING_CLEARANCE = 0.1 -- a rolled-up section stops this far under the housing's top
local GATE_MAX_SECTIONS = 5
local GATE_MAX_PARTS = 45
local GATE_FIXED_PARTS = 6 -- housing, two rails, motor box, the bottom section's handle and padlock
local GATE_SECTION_PARTS = 4 -- three slats and the collision plate
local GATE_MIN_BARS = 4

-- Signs
local SIGN_HEIGHT = 0.75
local SIGN_DEPTH = 0.06
local SIGN_GAP = 0.45 -- above the head casing
local SIGN_PIXELS = 48
local SIGN_LIGHT_CLEARANCE = 1.3 -- a wall fixture this close in front of a sign moves it to the other face

-- Palette
local WOOD_COLOR = Color3.fromRGB(84, 62, 43)
local FIRE_RED = Color3.fromRGB(112, 31, 27)
local STEEL_GREY = Color3.fromRGB(82, 86, 84)
local GLASS_COLOR = Color3.fromRGB(96, 110, 104)
local WIRE_COLOR = Color3.fromRGB(58, 60, 58)
local SIGN_RED = Color3.fromRGB(104, 26, 22)
local SIGN_GREEN = Color3.fromRGB(28, 62, 40)
local SIGN_TEXT = Color3.fromRGB(206, 196, 180)

-- The lowest a fixture door's leaf can sit (ajar / smashed poses are checked against it).
local FLOOR_TOLERANCE = 0.01

local DoorBuilder = {}

DoorBuilder.AjarAngle = AJAR_ANGLE
DoorBuilder.LeafBack = LEAF_BACK
DoorBuilder.TrimFront = TRIM_FRONT

--------------------------------------------------------------------------------
-- Sites
--------------------------------------------------------------------------------

local function roomCentre(room: Room): Vector2
	return LayoutSchema.rectCenter(room.rect)
end

local function ceilingOf(layout: Layout, room: Room): number
	if room.noCeiling then
		return math.huge
	end
	return LayoutSchema.roomHeight(layout, room) - CEILING_PANEL
end

-- The opening of `door` (the same frame SchoolShellBuilder gives its Door_<id> anchor), or nil when its rooms do not
-- share a wall.
function DoorBuilder.site(layout: Layout, rooms: { [string]: Room }, door: Door): Site?
	local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
	if not (a and b) then
		return nil
	end
	local edge = LayoutSchema.sharedEdge(a.rect, b.rect)
	if not edge then
		return nil
	end
	local ca, cb = roomCentre(a), roomCentre(b)
	local position: Vector3
	local direction: Vector3
	if edge.axis == "X" then
		position = Vector3.new(edge.coord, 0, door.at)
		direction = Vector3.new(if cb.X > ca.X then 1 else -1, 0, 0)
	else
		position = Vector3.new(door.at, 0, edge.coord)
		direction = Vector3.new(0, 0, if cb.Y > ca.Y then 1 else -1)
	end
	return {
		door = door,
		frame = CFrame.lookAt(position, position + direction),
		width = LayoutSchema.doorWidth(door),
		height = LayoutSchema.doorHeight(door),
		rooms = { a, b },
		ceiling = math.min(ceilingOf(layout, a), ceilingOf(layout, b)),
	}
end

-- The door frame turned to look into the room on side `swing` (+1 rooms[2], -1 rooms[1]).
local function swingFrame(frame: CFrame, swing: number): CFrame
	return if swing > 0 then frame else frame * CFrame.Angles(0, math.pi, 0)
end

-- The room on side `swing`.
local function swingRoom(site: Site, swing: number): Room
	return if swing > 0 then site.rooms[2] else site.rooms[1]
end

--------------------------------------------------------------------------------
-- Leaf geometry (pure)
--------------------------------------------------------------------------------

-- The hinge pin frame at rest (floor level): X across the leaf toward its free edge, Y up; turning about Y by
-- turnSign(leaf) * angle swings the leaf into its room.
local function hingeFrame(frame: CFrame, leaf: Leaf): CFrame
	local pin = swingFrame(frame, leaf.swing) * CFrame.new(leaf.hingeU, 0, -leaf.front)
	return if leaf.hinge < 0 then pin else pin * CFrame.Angles(0, math.pi, 0)
end

local function turnSign(leaf: Leaf): number
	return if leaf.hinge < 0 then 1 else -1
end

-- Leaf-local Z of "behind the front face" (toward the wall when shut).
local function behind(leaf: Leaf): number
	return if leaf.hinge < 0 then 1 else -1
end

-- The leaf's frame at `angle`, including the crooked hang (free side dropped about its bottom corner, top leaning
-- toward the front face, i.e. away from the doorway once open).
local function leafFrame(frame: CFrame, leaf: Leaf, angle: number): CFrame
	local pose = hingeFrame(frame, leaf) * CFrame.Angles(0, turnSign(leaf) * angle, 0)
	if leaf.tilt == 0 and leaf.lean == 0 then
		return pose
	end
	local lean = CFrame.new(0, leaf.bottom, 0)
		* CFrame.Angles(-behind(leaf) * leaf.lean, 0, 0)
		* CFrame.new(0, -leaf.bottom, 0)
	local tilt = CFrame.new(leaf.width, leaf.bottom, 0)
		* CFrame.Angles(0, 0, -leaf.tilt)
		* CFrame.new(-leaf.width, -leaf.bottom, 0)
	return pose * lean * tilt
end

-- A box of the leaf: [s0, s1] from the hinge edge, [y0, y1] up from the floor, [e0, e1] behind the front face.
local function leafBox(pose: CFrame, leaf: Leaf, s0: number, s1: number, y0: number, y1: number, e0: number, e1: number)
	local z = behind(leaf) * (e0 + e1) / 2
	return pose * CFrame.new((s0 + s1) / 2, (y0 + y1) / 2, z), Vector3.new(s1 - s0, y1 - y0, e1 - e0)
end

-- The leaf's hardware as a leaf box [s0, s1] x [y0, y1] x [e0, e1]: a knob spindle through both faces near the free
-- edge (wood and steel doors), or a crash bar across the back (push) face of a fire door.
local function hardwareBox(leaf: Leaf): (number, number, number, number, number, number)
	local y0, y1 = HANDLE_HEIGHT - 0.12, HANDLE_HEIGHT + 0.12
	if leaf.style == "Fire" then
		-- from just inside the frame reveal (clear of the jamb when shut) to short of the meeting edge
		local s0 = leaf.hingeOut - TRIM_REVEAL + 0.15
		return s0, leaf.width - PUSH_BAR_END, y0, y1, leaf.thickness + PUSH_BAR_STANDOFF, leaf.thickness + HANDLE_REACH
	end
	local s = leaf.width - HANDLE_INSET
	return s - 0.1, s + 0.1, y0, y1, -HANDLE_REACH, leaf.thickness + HANDLE_REACH
end

-- Floor-plan boxes the leaf occupies at `angle` (level-local): its slab, and its hardware (which may reach into the
-- leaf's own doorway while the leaf is near shut).
local function leafFootprints(frame: CFrame, leaf: Leaf, angle: number): (Footprint, Footprint)
	local pose = leafFrame(frame, leaf, angle)
	local slab, slabSize = leafBox(pose, leaf, 0, leaf.width, leaf.bottom, leaf.top, 0, leaf.thickness)
	local hardware, hardwareSize = leafBox(pose, leaf, hardwareBox(leaf))
	return VentGrateBuilder.footprintOf(slab, slabSize, "Door"),
		VentGrateBuilder.footprintOf(hardware, hardwareSize, "Door")
end

-- Leaf-local points that bound everything on the leaf: the slab's corners, the hardware's and the hinge knuckles.
local function leafExtremes(leaf: Leaf): { Vector3 }
	local out: { Vector3 } = {}
	local z = behind(leaf)
	for _, s in { 0, leaf.width } do
		for _, y in { leaf.bottom, leaf.top } do
			for _, e in { 0, leaf.thickness } do
				table.insert(out, Vector3.new(s, y, z * e))
			end
		end
	end
	local s0, s1, y0, y1, e0, e1 = hardwareBox(leaf)
	for _, s in { s0, s1 } do
		for _, y in { y0, y1 } do
			for _, e in { e0, e1 } do
				table.insert(out, Vector3.new(s, y, z * e))
			end
		end
	end
	local r = KNUCKLE_DIAMETER / 2
	for _, y in { leaf.bottom + 1.2, leaf.top - 1.6 + KNUCKLE_LENGTH } do
		for _, d in { Vector3.new(-r, 0, 0), Vector3.new(r, 0, 0), Vector3.new(0, 0, -r), Vector3.new(0, 0, r) } do
			table.insert(out, Vector3.new(0, y, 0) + d)
		end
	end
	return out
end

-- Lowest point of the leaf's slab at `pose`.
local function slabLow(pose: CFrame, leaf: Leaf): number
	local low = math.huge
	for _, s in { 0, leaf.width } do
		for _, y in { leaf.bottom, leaf.top } do
			for _, e in { 0, leaf.thickness } do
				low = math.min(low, (pose * Vector3.new(s, y, behind(leaf) * e)).Y)
			end
		end
	end
	return low
end

-- A single leaf filling an opening of `width` from jamb `hinge` (a double door's leaf when `half`).
local function newLeaf(
	site: Site,
	name: string,
	style: LeafStyle,
	swing: number,
	hinge: number,
	angle: number,
	full: number,
	half: boolean
): Leaf
	local halfWidth = site.width / 2
	local out = if style == "Fire" then FIRE_HINGE_OUT else HINGE_OUT
	local width = if half then halfWidth + out - MEETING_GAP / 2 else site.width + 2 * out - LATCH_GAP
	return {
		name = name,
		style = style,
		swing = swing,
		hinge = hinge,
		hingeU = hinge * (halfWidth + out),
		hingeOut = out,
		width = width,
		thickness = LEAF_THICKNESS,
		bottom = LEAF_FLOOR_GAP,
		top = math.min(site.height + HEAD_OVERLAP, site.ceiling - CEILING_GAP),
		front = LEAF_BACK + LEAF_THICKNESS,
		angle = angle,
		full = full,
		tilt = 0,
		lean = 0,
	}
end

--------------------------------------------------------------------------------
-- Clearance (pure)
--------------------------------------------------------------------------------

-- Walking lanes through every passable opening of `layout`: the clear width, from LANE_DEPTH inside one room to
-- LANE_DEPTH inside the other.
local function lanes(sites: { Site }): { Footprint }
	local out: { Footprint } = {}
	for _, site in sites do
		if site.door.kind == "Boarded" then
			continue
		end
		local clear = site.width / 2 - TRIM_REVEAL - EPS
		local across = WALL_HALF + LANE_DEPTH
		table.insert(
			out,
			VentGrateBuilder.footprintOf(
				site.frame * CFrame.new(0, site.height / 2, 0),
				Vector3.new(2 * clear, site.height, 2 * across),
				"Lane"
			)
		)
	end
	return out
end

type Clearance = {
	layout: Layout,
	lanes: { Footprint },
	hard: { Footprint }, -- grates, fixture doors, leaves already placed
	soft: { Footprint }, -- props on anchors, debris, platforms, pillars, basins
	parts: PartGrid?,
}

-- Visible shell geometry bucketed on the floor plan (level-local footprints).
type PartGrid = { cells: { [number]: { Footprint } }, size: number }

local GRID_CELL = 8

local function cellKey(i: number, j: number): number
	return (i + 2048) * 4096 + (j + 2048)
end

local function footprintBounds(f: Footprint): (number, number, number, number)
	local ex = math.abs(f.ux) * f.hu + math.abs(f.uz) * f.hv
	local ez = math.abs(f.uz) * f.hu + math.abs(f.ux) * f.hv
	return f.cx - ex, f.cx + ex, f.cz - ez, f.cz + ez
end

-- Every visible BasePart under `root` (except `skip`) whose height band meets [y0, y1], as level-local boxes.
local function partGrid(root: Instance, skip: Instance?, origin: Vector3, y0: number, y1: number): PartGrid
	local grid: PartGrid = { cells = {}, size = GRID_CELL }
	for _, descendant in root:GetDescendants() do
		if not descendant:IsA("BasePart") or descendant.Transparency >= 0.99 then
			continue
		end
		if skip and descendant:IsDescendantOf(skip) then
			continue
		end
		local cf = descendant.CFrame
		local half = descendant.Size / 2
		local ex = math.abs(cf.RightVector.X) * half.X
			+ math.abs(cf.UpVector.X) * half.Y
			+ math.abs(cf.LookVector.X) * half.Z
		local ey = math.abs(cf.RightVector.Y) * half.X
			+ math.abs(cf.UpVector.Y) * half.Y
			+ math.abs(cf.LookVector.Y) * half.Z
		local ez = math.abs(cf.RightVector.Z) * half.X
			+ math.abs(cf.UpVector.Z) * half.Y
			+ math.abs(cf.LookVector.Z) * half.Z
		local p = cf.Position - origin
		if p.Y + ey <= y0 or p.Y - ey >= y1 then
			continue
		end
		local box: Footprint = {
			cx = p.X,
			cz = p.Z,
			ux = 1,
			uz = 0,
			hu = ex,
			hv = ez,
			y0 = p.Y - ey,
			y1 = p.Y + ey,
			kind = "Part",
		}
		for i = math.floor((p.X - ex) / GRID_CELL), math.floor((p.X + ex) / GRID_CELL) do
			for j = math.floor((p.Z - ez) / GRID_CELL), math.floor((p.Z + ez) / GRID_CELL) do
				local key = cellKey(i, j)
				local list = grid.cells[key]
				if not list then
					list = {}
					grid.cells[key] = list
				end
				table.insert(list, box)
			end
		end
	end
	return grid
end

local function hitsParts(grid: PartGrid, f: Footprint): boolean
	local x0, x1, z0, z1 = footprintBounds(f)
	local seen: { [Footprint]: boolean } = {}
	for i = math.floor(x0 / grid.size), math.floor(x1 / grid.size) do
		for j = math.floor(z0 / grid.size), math.floor(z1 / grid.size) do
			for _, box in (grid.cells[cellKey(i, j)] or {}) :: { Footprint } do
				if not seen[box] then
					seen[box] = true
					if VentGrateBuilder.overlaps(f, box, 0.005) then
						return true
					end
				end
			end
		end
	end
	return false
end

local function footprintCorners(f: Footprint): { Vector3 }
	local vx, vz = -f.uz, f.ux
	local out: { Vector3 } = {}
	for _, su in { -1, 1 } do
		for _, sv in { -1, 1 } do
			table.insert(
				out,
				Vector3.new(f.cx + f.ux * f.hu * su + vx * f.hv * sv, 0, f.cz + f.uz * f.hu * su + vz * f.hv * sv)
			)
		end
	end
	return out
end

-- Whether every corner of `f` stands inside `room`, or in the clear opening of `site` itself (where a door's knob or
-- push bar reaches while the leaf is near shut).
local function insideRoomOrOpening(layout: Layout, site: Site, room: Room, f: Footprint): boolean
	local clear = site.width / 2 - TRIM_REVEAL - EPS
	local depth = WALL_HALF + ROOM_MARGIN + 0.01
	for _, corner in footprintCorners(f) do
		local p = site.frame:PointToObjectSpace(corner)
		if math.abs(p.X) <= clear and math.abs(p.Z) <= depth then
			continue
		end
		local point: Footprint =
			{ cx = corner.X, cz = corner.Z, ux = 1, uz = 0, hu = 0, hv = 0, y0 = f.y0, y1 = f.y1, kind = f.kind }
		if not VentGrateBuilder.insideRoom(layout, room, point, ROOM_MARGIN) then
			return false
		end
	end
	return true
end

-- Whether `piece` of a leaf at `angle` stays out of the lanes (at `laneAngle` only, so an ajar leaf may stand in its
-- own doorway), the hard keep-outs, the soft ones unless `ignoreSoft`, and the shell's parts.
local function clearOf(
	clearance: Clearance,
	piece: Footprint,
	angle: number,
	laneAngle: number?,
	ignoreSoft: boolean
): boolean
	if laneAngle and math.abs(angle - laneAngle) < EPS then
		for _, lane in clearance.lanes do
			if VentGrateBuilder.overlaps(piece, lane, 0.005) then
				return false
			end
		end
	end
	for _, keep in clearance.hard do
		if VentGrateBuilder.overlaps(piece, keep, 0.005) then
			return false
		end
	end
	if not ignoreSoft then
		for _, keep in clearance.soft do
			if VentGrateBuilder.overlaps(piece, keep, 0.005) then
				return false
			end
		end
	end
	local parts = clearance.parts
	return not (parts and hitsParts(parts, piece))
end

-- Whether `leaf` fits at every angle in `angles`: its slab inside its room, its hardware inside the room or its own
-- doorway, both clear of everything `clearOf` tests, and nothing below the floor.
local function fits(
	clearance: Clearance,
	site: Site,
	leaf: Leaf,
	angles: { number },
	laneAngle: number?,
	ignoreSoft: boolean
): boolean
	local room = swingRoom(site, leaf.swing)
	for _, angle in angles do
		local slab, hardware = leafFootprints(site.frame, leaf, angle)
		if not VentGrateBuilder.insideRoom(clearance.layout, room, slab, ROOM_MARGIN) then
			return false
		end
		if not insideRoomOrOpening(clearance.layout, site, room, hardware) then
			return false
		end
		if
			not clearOf(clearance, slab, angle, laneAngle, ignoreSoft)
			or not clearOf(clearance, hardware, angle, laneAngle, ignoreSoft)
		then
			return false
		end
		if slabLow(leafFrame(site.frame, leaf, angle), leaf) < -FLOOR_TOLERANCE then
			return false
		end
	end
	return true
end

-- The angles a fixture leaf's swing is sampled at, from shut to `full`.
local function sweep(full: number): { number }
	return { 0, full * 0.25, full * 0.5, full * 0.75, full }
end

--------------------------------------------------------------------------------
-- Fixture planning (pure, from the layout only, so the static doors can keep clear of it)
--------------------------------------------------------------------------------

export type GatePlan = {
	sections: number,
	sectionHeight: number,
	housingHeight: number,
	bars: number, -- vertical bars per section
	rail: number, -- rail width beside each edge of the opening
	engage: number,
}

export type FixturePlan = {
	site: Site,
	leaves: { Leaf },
	gate: GatePlan?,
	signSwing: number?, -- face the sign is on (+1 rooms[2], -1 rooms[1]), nil when there is no room for it
}

local function clearanceFor(layout: Layout, sites: { Site }): Clearance
	local hard: { Footprint } = {}
	for _, f in VentGrateBuilder.footprints(layout) do
		table.insert(hard, f)
	end
	return {
		layout = layout,
		lanes = lanes(sites),
		hard = hard,
		soft = VentGrateBuilder.obstacles(layout),
		parts = nil,
	}
end

-- The anchor the Creature's scare pose sits on in either room of `site`, if any.
local function scareAnchor(layout: Layout, site: Site): LayoutSchema.Anchor?
	for _, anchor in layout.anchors do
		if
			anchor.kind == "CreatureScarePose" and (anchor.room == site.rooms[1].id or anchor.room == site.rooms[2].id)
		then
			return anchor
		end
	end
	return nil
end

-- Ajar / RoofDoor: one leaf, preferred swing and hinge first, the widest full-open angle that fits.
local function planSingle(
	clearance: Clearance,
	site: Site,
	style: LeafStyle,
	swings: { number },
	hinges: { number },
	angleOf: (full: number) -> number
): { Leaf }?
	for _, ignoreSoft in { false, true } do
		for _, swing in swings do
			for _, hinge in hinges do
				for _, full in SWING_FULL_ANGLES do
					local leaf = newLeaf(site, "Leaf", style, swing, hinge, angleOf(full), full, false)
					if fits(clearance, site, leaf, sweep(full), full, ignoreSoft) then
						return { leaf }
					end
				end
			end
		end
	end
	return nil
end

-- The gate's grille: as few telescoping sections as nest inside a housing as tall as fits under the ceiling, and as
-- many bars per section as the part budget leaves.
local function planGate(layout: Layout, site: Site, mountRoom: Room): GatePlan
	local height = site.height
	local housing = math.min(GATE_HOUSING_MAX, site.ceiling - 0.03 - height)
	local room = housing - GATE_HOUSING_CLEARANCE
	local sections = 1
	while (height + (sections - 1) * GATE_OVERLAP) / sections > room + EPS and sections < GATE_MAX_SECTIONS do
		sections += 1
	end
	local sectionHeight = (height + (sections - 1) * GATE_OVERLAP) / sections
	if sectionHeight > room + EPS then
		log.warn(
			"%s: gate %s has %.2f studs above its opening; its grille sections stand out of the housing",
			layout.id,
			site.door.id,
			housing
		)
	end
	local free = GATE_MAX_PARTS - GATE_FIXED_PARTS - sections * GATE_SECTION_PARTS
	local bars = math.clamp(math.floor(free / sections), GATE_MIN_BARS, GATE_BARS)
	-- rails as wide as the wall beside the opening allows on the mount face
	local frame = site.frame
	local right = frame.RightVector
	local r = mountRoom.rect
	local alongX = math.abs(right.X) > 0.5
	local centre = if alongX then frame.Position.X else frame.Position.Z
	local lo = if alongX then r.x else r.z
	local hi = if alongX then r.x + r.w else r.z + r.d
	local loSide: LayoutSchema.Side = if alongX then "W" else "N"
	local hiSide: LayoutSchema.Side = if alongX then "E" else "S"
	local across = if alongX then frame.Position.Z else frame.Position.X
	local inward = if alongX then r.z + r.d / 2 - across else r.x + r.w / 2 - across
	local probe = across + math.sign(inward)
	local below = centre - site.width / 2 - (lo + VentGrateBuilder.wallHalfAt(layout, mountRoom, loSide, probe))
	local above = (hi - VentGrateBuilder.wallHalfAt(layout, mountRoom, hiSide, probe)) - (centre + site.width / 2)
	local rail = math.clamp(math.min(below, above) - 0.02, 0.2, GATE_RAIL_MAX)
	return {
		sections = sections,
		sectionHeight = sectionHeight,
		housingHeight = housing,
		bars = bars,
		rail = rail,
		engage = math.min(GATE_ENGAGE, rail - 0.08),
	}
end

-- Width of the casing members around a fixture door's opening: the shell's trims, or the wide steel frame of a fire
-- door.
local function frameMember(site: Site): number
	return if site.door.kind == "Airlock" then FIRE_FRAME_WIDTH else TRIM_WIDTH
end

-- Bottom of the sign plate above `site`'s head casing.
local function signBottom(site: Site): number
	return site.height + frameMember(site) + SIGN_GAP - 0.25
end

-- Whether a wall fixture of `layout` hangs in front of the sign spot above `site` on face `swing`.
local function lightInFront(layout: Layout, site: Site, swing: number, y0: number, y1: number): boolean
	local frame = swingFrame(site.frame, swing)
	for _, room in layout.rooms do
		for _, light in (room.lights or {}) :: { LayoutSchema.Light } do
			local p = frame:PointToObjectSpace(light.pos)
			local out = -p.Z
			if
				out > 0
				and out < WALL_HALF + SIGN_LIGHT_CLEARANCE
				and math.abs(p.X) < site.width / 2 + 1.4
				and p.Y > y0 - 0.8
				and p.Y < y1 + 0.8
			then
				return true
			end
		end
	end
	return false
end

-- The face a sign above `site` goes on: `preferred` unless a wall fixture is in the way there (or it would not fit
-- under the ceiling).
local function signFace(layout: Layout, site: Site, preferred: number): number?
	local y0 = signBottom(site)
	local y1 = y0 + SIGN_HEIGHT
	if y1 > site.ceiling - 0.05 then
		return nil
	end
	for _, swing in { preferred, -preferred } do
		if not lightInFront(layout, site, swing, y0, y1) then
			return swing
		end
	end
	return preferred
end

-- The stairwell an airlock's vestibule serves.
local function stairwellOf(site: Site): WorldConfig.StairwellSpec?
	for _, spec in WorldConfig.Stairwells do
		for _, room in site.rooms do
			if spec.fromRoom == room.id or spec.toRoom == room.id then
				return spec
			end
		end
	end
	return nil
end

local function planFixture(layout: Layout, clearance: Clearance, site: Site): FixturePlan?
	local kind = site.door.kind
	if kind == "Ajar" then
		-- swing out of the scare room, hinged on the jamb toward the pose so the diagonal view in stays open
		local scare = scareAnchor(layout, site)
		local swings: { number } = { 1, -1 }
		local hinges: { number } = { -1, 1 }
		if scare then
			local inScareRoom = if scare.room == site.rooms[2].id then 1 else -1
			swings = { -inScareRoom, inScareRoom }
			local toward = swingFrame(site.frame, -inScareRoom):PointToObjectSpace(scare.pos).X
			hinges = if toward < 0 then { -1, 1 } else { 1, -1 }
		end
		local leaves = planSingle(clearance, site, "Wood", swings, hinges, function(_full: number): number
			return AJAR_ANGLE
		end)
		return if leaves then { site = site, leaves = leaves, gate = nil, signSwing = nil } else nil
	elseif kind == "RoofDoor" then
		local leaves = planSingle(clearance, site, "Steel", { 1, -1 }, { -1, 1 }, function(full: number): number
			return full
		end)
		if not leaves then
			return nil
		end
		-- Only the roof stair door carries the ROOF ACCESS sign; another steel door (the Level 3 equipment store) has
		-- none.
		local stair = if site.rooms[1].kind == "Stairwell"
			then -1
			elseif site.rooms[2].kind == "Stairwell" then 1
			else nil
		return {
			site = site,
			leaves = leaves,
			gate = nil,
			signSwing = if stair then signFace(layout, site, stair) else nil,
		}
	elseif kind == "Airlock" then
		local vestibule = if site.rooms[2].kind == "Airlock" then 1 elseif site.rooms[1].kind == "Airlock" then -1 else 1
		for _, ignoreSoft in { false, true } do
			for _, swing in { vestibule, -vestibule } do
				local left = newLeaf(site, "LeftLeaf", "Fire", swing, -1, AIRLOCK_ANGLE, AIRLOCK_ANGLE, true)
				local right = newLeaf(site, "RightLeaf", "Fire", swing, 1, AIRLOCK_ANGLE, AIRLOCK_ANGLE, true)
				local angles = sweep(AIRLOCK_ANGLE)
				if
					fits(clearance, site, left, angles, AIRLOCK_ANGLE, ignoreSoft)
					and fits(clearance, site, right, angles, AIRLOCK_ANGLE, ignoreSoft)
				then
					return {
						site = site,
						leaves = { left, right },
						gate = nil,
						signSwing = signFace(layout, site, vestibule),
					}
				end
			end
		end
		return nil
	elseif kind == "Gate" then
		return { site = site, leaves = {}, gate = planGate(layout, site, site.rooms[1]), signSwing = nil }
	end
	return nil
end

-- Plans every fixture door of `layout` from scratch (DoorBuilder.planFixtures keeps the result per layout).
local function computeFixtures(layout: Layout): { FixturePlan }
	local rooms = LayoutSchema.indexRooms(layout)
	local sites: { Site } = {}
	for _, door in layout.doors do
		local site = DoorBuilder.site(layout, rooms, door)
		if site then
			table.insert(sites, site)
		end
	end
	local clearance = clearanceFor(layout, sites)
	local plans: { FixturePlan } = {}
	for _, site in sites do
		local kind = site.door.kind
		if kind ~= "Ajar" and kind ~= "Gate" and kind ~= "Airlock" and kind ~= "RoofDoor" then
			continue
		end
		local plan = planFixture(layout, clearance, site)
		if plan then
			table.insert(plans, plan)
		else
			log.warn("%s: %s door %s has no room to swing; not built", layout.id, kind, site.door.id)
		end
	end
	return plans
end

-- Layouts are static, so each one is planned once (at boot, by the static doors keeping clear of the fixtures) and
-- the plans are shared by every later run: treat them as read-only.
local fixtureCache = setmetatable({} :: { [Layout]: { FixturePlan } }, { __mode = "k" })

-- Every fixture door of `layout` (Ajar, Gate, Airlock, RoofDoor) with its leaves; a door whose leaves fit nowhere is
-- left out (and reported).
function DoorBuilder.planFixtures(layout: Layout): { FixturePlan }
	local cached = fixtureCache[layout]
	if cached then
		return cached
	end
	local plans = table.freeze(computeFixtures(layout))
	fixtureCache[layout] = plans
	return plans
end

-- Floor-plan boxes a fixture door needs: its frame / rails / housing beside the opening and its leaves over their swing.
local function fixtureFootprints(plan: FixturePlan): { Footprint }
	local out: { Footprint } = {}
	local site = plan.site
	local frameDepth = if plan.gate then 1.5 else TRIM_FRONT
	local reach = if plan.gate then plan.gate.rail else frameMember(site)
	table.insert(
		out,
		VentGrateBuilder.footprintOf(
			site.frame * CFrame.new(0, site.height / 2, 0),
			Vector3.new(site.width + 2 * reach, site.height + 0.5, 2 * frameDepth),
			"Door"
		)
	)
	for _, leaf in plan.leaves do
		for _, angle in sweep(leaf.full) do
			local slab, hardware = leafFootprints(site.frame, leaf, angle)
			table.insert(out, slab)
			table.insert(out, hardware)
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Pose helpers
--------------------------------------------------------------------------------

local function axisAngle(cf: CFrame): (Vector3, number)
	local axis, angle = cf:ToAxisAngle()
	if angle > math.pi then
		angle -= 2 * math.pi
	end
	return axis, angle
end

local function partialRotation(cf: CFrame, t: number): CFrame
	local axis, angle = axisAngle(cf.Rotation)
	if math.abs(angle) < 1e-6 then
		return CFrame.new()
	end
	return CFrame.fromAxisAngle(axis, angle * t)
end

local function smoothstep(t: number): number
	return t * t * (3 - 2 * t)
end

local function posePoint(model: Model, name: string): CFrame?
	local base = model.PrimaryPart
	if not base then
		return nil
	end
	local attachment = base:FindFirstChild(name)
	if not (attachment and attachment:IsA("Attachment")) then
		return nil
	end
	return base.CFrame * attachment.CFrame
end

-- Leaves of `model` in a stable order (child Models with a rest pose).
local function leavesOf(model: Model): { Model }
	local out: { Model } = {}
	for _, child in model:GetChildren() do
		if child:IsA("Model") and PropKit.leafRest(model, child.Name) then
			table.insert(out, child)
		end
	end
	table.sort(out, function(a: Model, b: Model): boolean
		return a.Name < b.Name
	end)
	return out
end

-- The names of a fixture door's leaves, in a stable order (DoorService and the client DoorController pose them).
function DoorBuilder.leafNames(model: Model): { string }
	local out: { string } = {}
	for _, leaf in leavesOf(model) do
		table.insert(out, leaf.Name)
	end
	return out
end

-- Leaf `name`'s transform from its rest pivot at `openness` (0 shut .. 1 fully open): a swing about the hinge, or for
-- the grille's sections a vertical slide into the housing. Pure; nil when the leaf or its poses are missing.
function DoorBuilder.openTransform(model: Model, name: string, openness: number): CFrame?
	local rest = PropKit.leafRest(model, name)
	local open = posePoint(model, name .. "Open")
	if not (rest and open) then
		return nil
	end
	local t = math.clamp(openness, 0, 1)
	local full = rest:ToObjectSpace(open)
	if model:GetAttribute(W.DoorKind) == "Gate" then
		return CFrame.new(full.Position * t)
	end
	return partialRotation(full, t)
end

-- Leaf `name`'s transform from its rest pivot at smash progress `t` (0 shut .. 1 smashed): about the leaf's centre,
-- out first, then tipping over and dropping, with a short hop. Pure; nil when the leaf or its poses are missing.
function DoorBuilder.smashedTransform(model: Model, name: string, t: number): CFrame?
	local rest = PropKit.leafRest(model, name)
	local smashed = posePoint(model, name .. "Smashed")
	local centre = posePoint(model, name .. "Centre")
	if not (rest and smashed and centre) then
		return nil
	end
	local k = math.clamp(t, 0, 1)
	local hop = if model:GetAttribute(W.DoorKind) == "Airlock" then BUCKLE_HOP else THROW_HOP
	local offset = centre:ToObjectSpace(rest)
	local landed = smashed * offset:Inverse()
	local delta = landed.Position - centre.Position
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local out = 1 - (1 - k) * (1 - k)
	local tip = smoothstep(k)
	local position = centre.Position + flat * out + Vector3.yAxis * (delta.Y * tip + hop * math.sin(math.pi * k))
	local rotation = centre.Rotation * partialRotation(centre.Rotation:Inverse() * landed.Rotation, tip)
	return rest:ToObjectSpace(CFrame.new(position) * rotation * offset)
end

-- Opens (1) or shuts (0) every leaf of a fixture door: leaves swing about their hinge, the grille's sections slide
-- up into the housing.
function DoorBuilder.setOpen(model: Model, openness: number): boolean
	local ok = true
	for _, name in DoorBuilder.leafNames(model) do
		local transform = DoorBuilder.openTransform(model, name, openness)
		if not (transform and PropKit.poseLeaf(model, name, transform)) then
			ok = false
		end
	end
	return ok
end

-- Smashes a fixture door (0 shut .. 1 smashed): single leaves are torn off and thrown flat into the room they swing
-- into, fire doors buckle half off their hinges, grille sections are torn out and dropped in a heap.
function DoorBuilder.setSmashed(model: Model, t: number): boolean
	local ok = true
	for _, name in DoorBuilder.leafNames(model) do
		local transform = DoorBuilder.smashedTransform(model, name, t)
		if not (transform and PropKit.poseLeaf(model, name, transform)) then
			ok = false
		end
	end
	return ok
end

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

type Ctx = {
	frame: CFrame, -- world door frame
	origin: Vector3, -- level origin (world)
}

local function attach(base: BasePart, name: string, world: CFrame): Attachment
	return Geometry.attachment(base, name, base.CFrame:ToObjectSpace(world))
end

-- A box [u0, u1] x [y0, y1] x [a0, a1] in a (world) wall frame: u along RightVector, y up, a out along LookVector.
local function wallBox(
	parent: Instance,
	name: string,
	frame: CFrame,
	u0: number,
	u1: number,
	y0: number,
	y1: number,
	a0: number,
	a1: number,
	key: string?,
	options: Geometry.PartOptions?
): Part
	return Geometry.part(
		parent,
		name,
		frame * CFrame.new((u0 + u1) / 2, (y0 + y1) / 2, -(a0 + a1) / 2),
		Vector3.new(u1 - u0, y1 - y0, a1 - a0),
		key,
		options
	)
end

-- Steel casing matching Geometry.doorTrims (two jambs and the head, passthrough). Returns the head.
local function steelFrame(
	model: Model,
	frame: CFrame,
	width: number,
	height: number,
	ceiling: number,
	member: number
): Part
	local half = width / 2
	local a = TRIM_FRONT
	local top = math.min(height + member, ceiling - 0.02)
	local options: Geometry.PartOptions = { castShadow = false }
	local head = wallBox(
		model,
		"Base",
		frame,
		-half + TRIM_REVEAL,
		half - TRIM_REVEAL,
		height - TRIM_REVEAL,
		top,
		-a,
		a,
		"TrimMetal",
		options
	)
	local left =
		wallBox(model, "JambLeft", frame, -half - member, -half + TRIM_REVEAL, 0, top, -a, a, "TrimMetal", options)
	local right =
		wallBox(model, "JambRight", frame, half - TRIM_REVEAL, half + member, 0, top, -a, a, "TrimMetal", options)
	for _, part in { head, left, right } do
		Geometry.makePassthrough(part)
	end
	return head
end

-- Paints yellow-and-black hazard stripes over `faces` of `part` (frames and rails of the fire doors and the gate).
local function hazardStripes(part: BasePart, faces: { Enum.NormalId })
	for _, face in faces do
		local gui, pps = SurfaceArt.gui(part, face, { name = "Hazard", pixelsPerStud = 16, maxDistance = 90 })
		SurfaceArt.hazard(gui, SurfaceArt.faceStuds(part.Size, face), pps, 0.32, 0.45)
	end
end

-- A printed sign plate on the wall face of `frame` (LookVector out of that face), centred above the opening.
local function sign(model: Model, frame: CFrame, site: Site, key: string, plate: Color3): Part
	local y0 = signBottom(site)
	local width = math.min(site.width - 0.4, 4.6)
	local part = wallBox(
		model,
		"Sign",
		frame,
		-width / 2,
		width / 2,
		y0,
		y0 + SIGN_HEIGHT,
		WALL_HALF,
		WALL_HALF + SIGN_DEPTH,
		nil,
		{ material = Enum.Material.SmoothPlastic, color = plate, castShadow = false }
	)
	PropKit.detail(part)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Print"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = SIGN_PIXELS
	gui.LightInfluence = 1
	gui.MaxDistance = 80
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = Strings.get(key)
	label.TextColor3 = SIGN_TEXT
	label.TextScaled = true
	label.TextWrapped = true
	label.FontFace = Font.fromEnum(Enum.Font.Oswald)
	label.Parent = gui
	return part
end

type LeafLook = {
	collide: boolean, -- Default-group leaf (fixture) vs passthrough (static)
	random: Random,
}

-- The parts of one leaf at `pose` (its frame at the built angle) into `parent`: wood or fire doors get stiles and
-- rails around a wired-glass window, a kick plate and a handle; the steel roof door a plain dented slab.
-- Returns the parts that make up the leaf's body.
local function buildLeafParts(parent: Instance, pose: CFrame, leaf: Leaf, look: LeafLook): { BasePart }
	local body: { BasePart } = {}
	local details: { BasePart } = {}
	local t = leaf.thickness
	local w = leaf.width
	local bottom, top = leaf.bottom, leaf.top
	local function piece(
		name: string,
		s0: number,
		s1: number,
		y0: number,
		y1: number,
		e0: number,
		e1: number,
		key: string?,
		options: Geometry.PartOptions?,
		isBody: boolean
	): Part
		local cf, size = leafBox(pose, leaf, s0, s1, y0, y1, e0, e1)
		local part = Geometry.part(parent, name, cf, size, key, options)
		table.insert(if isBody then body else details, part)
		return part
	end
	local slabColor = if leaf.style == "Wood" then WOOD_COLOR elseif leaf.style == "Fire" then FIRE_RED else STEEL_GREY
	local shade = look.random:NextNumber(-0.025, 0.025)
	local color = Color3.new(
		math.clamp(slabColor.R + shade, 0, 1),
		math.clamp(slabColor.G + shade, 0, 1),
		math.clamp(slabColor.B + shade, 0, 1)
	)
	local material = if leaf.style == "Wood" then Enum.Material.Wood else Enum.Material.Metal
	local slab: Geometry.PartOptions = { material = material, color = color }

	if leaf.style == "Steel" then
		piece(leaf.name .. "_Slab", 0, w, bottom, top, 0, t, nil, slab, true)
		-- hammered from inside: two buckled patches bulging out of the front face
		local dent: Geometry.PartOptions = {
			material = Enum.Material.Metal,
			color = Color3.new(color.R * 0.82, color.G * 0.82, color.B * 0.82),
			castShadow = false,
		}
		for i = 1, 2 do
			local s = w * look.random:NextNumber(0.3, 0.7)
			local y = bottom
				+ (top - bottom)
					* (if i == 1 then look.random:NextNumber(0.25, 0.45) else look.random:NextNumber(0.55, 0.75))
			local size = Vector3.new(look.random:NextNumber(0.9, 1.5), look.random:NextNumber(0.8, 1.3), 0.08)
			local cf = pose
				* CFrame.new(s, y, -behind(leaf) * 0.02)
				* CFrame.Angles(
					look.random:NextNumber(-0.12, 0.12),
					look.random:NextNumber(-0.12, 0.12),
					look.random:NextNumber(-0.6, 0.6)
				)
			local part = Geometry.part(parent, string.format("%s_Dent%d", leaf.name, i), cf, size, nil, dent)
			table.insert(details, part)
		end
		piece(
			leaf.name .. "_KickPlate",
			0.3,
			w - 0.3,
			bottom + 0.05,
			bottom + 1.0,
			t,
			t + 0.02,
			"MetalGalvanized",
			{ castShadow = false },
			false
		)
	else
		-- stiles and rails around a small wired-glass window toward the latch side
		local winW = if leaf.style == "Wood" then 1.1 else 0.9
		local winH = if leaf.style == "Wood" then 2.4 else 1.6
		local winY0 = math.min(bottom + (top - bottom) * 0.53, top - winH - 0.8)
		local winY1 = winY0 + winH
		local winS0 = math.clamp(w * 0.6 - winW / 2, 0.6, w - winW - 0.6)
		local winS1 = winS0 + winW
		piece(leaf.name .. "_StileHinge", 0, winS0, bottom, top, 0, t, nil, slab, true)
		piece(leaf.name .. "_StileLatch", winS1, w, bottom, top, 0, t, nil, slab, true)
		piece(leaf.name .. "_RailTop", winS0, winS1, winY1, top, 0, t, nil, slab, true)
		piece(leaf.name .. "_RailBottom", winS0, winS1, bottom, winY0, 0, t, nil, slab, true)
		piece(
			leaf.name .. "_Glass",
			winS0,
			winS1,
			winY0,
			winY1,
			t / 2 - 0.03,
			t / 2 + 0.03,
			"Glass",
			{ color = GLASS_COLOR, transparency = 0.45, reflectance = 0.05, castShadow = false },
			true
		)
		piece(
			leaf.name .. "_Wire",
			winS0,
			winS1,
			winY0,
			winY1,
			t / 2 - 0.006,
			t / 2 + 0.006,
			nil,
			{ material = Enum.Material.DiamondPlate, color = WIRE_COLOR, transparency = 0.62, castShadow = false },
			false
		)
		-- kick plate on the push side (the back face)
		piece(
			leaf.name .. "_KickPlate",
			0.3,
			w - 0.3,
			bottom + 0.05,
			bottom + 1.0,
			t,
			t + 0.02,
			"MetalGalvanized",
			{ castShadow = false },
			false
		)
	end

	-- handle: a knob spindle (wood, steel) or a crash bar across the push side (fire door)
	local h0, h1, hy0, hy1, he0, he1 = hardwareBox(leaf)
	if leaf.style == "Fire" then
		piece(leaf.name .. "_PushBar", h0, h1, hy0, hy1, he0, he1, "TrimMetal", { castShadow = false }, false)
	else
		local spindle = (h0 + h1) / 2
		local a = pose * Vector3.new(spindle, HANDLE_HEIGHT, behind(leaf) * he0)
		local b = pose * Vector3.new(spindle, HANDLE_HEIGHT, behind(leaf) * he1)
		local knob =
			Geometry.cylinder(parent, leaf.name .. "_Handle", a, b, h1 - h0, "TrimMetal", { castShadow = false })
		if knob then
			table.insert(details, knob)
		end
	end

	for _, part in body do
		if not look.collide then
			Geometry.makePassthrough(part)
		end
	end
	for _, part in details do
		PropKit.detail(part)
	end
	return body
end

-- Hinge knuckles on the pin (fixture leaves).
local function knuckles(parent: Instance, pose: CFrame, leaf: Leaf)
	for i, y in { leaf.bottom + 1.2, leaf.top - 1.6 } do
		local part = Geometry.cylinder(
			parent,
			string.format("%s_Knuckle%d", leaf.name, i),
			pose * Vector3.new(0, y, 0),
			pose * Vector3.new(0, y + KNUCKLE_LENGTH, 0),
			KNUCKLE_DIAMETER,
			"TrimMetal",
			{ castShadow = false }
		)
		if part then
			PropKit.detail(part)
		end
	end
end

-- Where a torn-off single leaf lands (level-local leaf frame): flat on its face in the room it swings into, its foot
-- near the wall, yawed a little and propped on its knob; moved closer to the wall and turned until it fits inside the
-- room (the most compact pose, lengthwise along the wall, when nothing fits).
local function thrownPose(layout: Layout, site: Site, leaf: Leaf, random: Random): CFrame
	local room = swingRoom(site, leaf.swing)
	local frame = swingFrame(site.frame, leaf.swing)
	local length = leaf.top - leaf.bottom
	local spin = random:NextNumber(-1, 1)
	local side = random:NextNumber(-0.4, 0.4)
	local z = behind(leaf)
	local centreLocal = Vector3.new(leaf.width / 2, (leaf.bottom + leaf.top) / 2, z * leaf.thickness / 2)
	-- face down, the knob end resting on the knob: rolled about the leaf's long axis just enough
	local roll = math.atan2(HANDLE_REACH, leaf.width - HANDLE_INSET)
	local extremes = leafExtremes(leaf)
	local last = CFrame.identity
	for _, out in { 0.9, 0.5, 0.2 } do
		for _, yaw in { 0.12 * spin, 0.3 * spin, 0.9 * spin, math.pi / 2 * (if spin < 0 then -1 else 1) } do
			-- leaf X along the (yawed) wall, its height pointing away from the wall, its back face up
			local turn = CFrame.Angles(0, yaw, 0)
			local right = turn * frame.RightVector
			local away = turn * frame.LookVector
			local lying = CFrame.fromMatrix(Vector3.zero, right * z, away, Vector3.yAxis * z)
			local orient = lying * CFrame.Angles(0, -roll * z, 0)
			local low = math.huge
			for _, p in extremes do
				low = math.min(low, (orient * (p - centreLocal)).Y)
			end
			local spot = frame * Vector3.new(side, 0, -(leaf.front + out + length / 2))
			local centre = CFrame.new(spot.X, 0.01 - low, spot.Z) * orient
			local footprint =
				VentGrateBuilder.footprintOf(centre, Vector3.new(leaf.width, length, leaf.thickness), "Door")
			last = centre * CFrame.new(-centreLocal)
			if VentGrateBuilder.insideRoom(layout, room, footprint, ROOM_MARGIN) then
				return last
			end
		end
	end
	log.warn("%s: door %s has no floor to land on when smashed; it lands against a wall", layout.id, site.door.id)
	return last
end

-- Builds `leaf` of a fixture door as a PropKit leaf of `model` (shut, at rest) and records its open, centre and
-- smashed poses (`smashed` is a level-local leaf frame).
local function fixtureLeaf(model: Model, ctx: Ctx, leaf: Leaf, smashed: CFrame, random: Random)
	local base = model.PrimaryPart
	assert(base, "fixture door needs its Base first")
	local rest = leafFrame(ctx.frame, leaf, 0)
	local container = PropKit.leaf(model, leaf.name, rest)
	buildLeafParts(container, rest, leaf, { collide = true, random = random })
	knuckles(container, rest, leaf)
	attach(base, leaf.name .. "Open", leafFrame(ctx.frame, leaf, leaf.full))
	local centreLocal = Vector3.new(leaf.width / 2, (leaf.bottom + leaf.top) / 2, behind(leaf) * leaf.thickness / 2)
	attach(base, leaf.name .. "Centre", rest * CFrame.new(centreLocal))
	attach(base, leaf.name .. "Smashed", CFrame.new(ctx.origin) * smashed)
end

-- The buckled pose of a fire door leaf (level-local leaf frame): swung most of the way open, sagging off its top hinge,
-- leaning out of its frame, pushed into the room and dropped onto its lowest corner.
local function buckledPose(site: Site, leaf: Leaf, random: Random): CFrame
	local buckled = table.clone(leaf)
	buckled.tilt = math.rad(random:NextNumber(5, 8))
	buckled.lean = math.rad(random:NextNumber(9, 14))
	local swing = math.rad(random:NextNumber(55, 70))
	local pose = leafFrame(site.frame, buckled, swing)
	local push = swingFrame(site.frame, leaf.swing).LookVector * random:NextNumber(0.4, 0.7)
	return CFrame.new(push - Vector3.yAxis * (slabLow(pose, leaf) - 0.02)) * pose
end

--------------------------------------------------------------------------------
-- Fixture doors
--------------------------------------------------------------------------------

local function setDoorAttributes(model: Model, source: Attachment, site: Site, levelId: string)
	local scripted = source:GetAttribute(W.ScriptedId)
	local state: Enums.DoorState = "Open"
	PropKit.setAttributes(model, {
		[W.DoorId] = site.door.id,
		[W.DoorKind] = site.door.kind,
		[W.DoorState] = state,
		[W.LevelId] = levelId,
		[W.DoorWidth] = source:GetAttribute(W.DoorWidth) or site.width,
		[W.DoorHeight] = source:GetAttribute(W.DoorHeight) or site.height,
	})
	if type(scripted) == "string" then
		model:SetAttribute(W.ScriptedId, scripted)
		model:AddTag(Tags.ScriptedDoor)
	end
end

local function buildSwingDoor(model: Model, ctx: Ctx, plan: FixturePlan, layout: Layout, random: Random)
	local site = plan.site
	local kind = site.door.kind
	local frame = ctx.frame
	local base: BasePart
	if kind == "Ajar" then
		-- the shell built the casing; the fixed hinge leaves are a strip on the casing face behind the pin
		local leaf = plan.leaves[1]
		local pin = swingFrame(frame, leaf.swing)
		local u = leaf.hingeU
		local u0, u1 = if leaf.hinge < 0 then u - 0.07 else u, if leaf.hinge < 0 then u else u + 0.07
		base = wallBox(
			model,
			"Base",
			pin,
			u0,
			u1,
			leaf.bottom + 1.0,
			leaf.top - 0.6,
			TRIM_FRONT,
			leaf.front,
			"TrimMetal",
			{ castShadow = false }
		)
		PropKit.detail(base)
	else
		base = steelFrame(model, frame, site.width, site.height, site.ceiling, frameMember(site))
		if kind == "Airlock" then
			for _, name in { "Base", "JambLeft", "JambRight" } do
				local member = model:FindFirstChild(name)
				if member and member:IsA("BasePart") then
					hazardStripes(member, { Enum.NormalId.Front, Enum.NormalId.Back })
				end
			end
		end
	end
	model.PrimaryPart = base

	local leaves = plan.leaves
	for _, leaf in leaves do
		local smashed = if kind == "Airlock"
			then buckledPose(site, leaf, random)
			else thrownPose(layout, site, leaf, random)
		fixtureLeaf(model, ctx, leaf, smashed, random)
	end
	if kind == "Airlock" then
		-- astragal: a strip on the right leaf's front face lapping the meeting edge
		local right = leaves[2]
		local container = if right then model:FindFirstChild(right.name) else nil
		if right and container then
			local cf, size = leafBox(
				leafFrame(frame, right, 0),
				right,
				right.width - 0.12,
				right.width + 0.1,
				right.bottom + 0.05,
				right.top - 0.05,
				-0.04,
				0
			)
			local strip = Geometry.part(
				container,
				right.name .. "_Astragal",
				cf,
				size,
				nil,
				{ material = Enum.Material.Metal, color = FIRE_RED, castShadow = false }
			)
			PropKit.detail(strip)
		end
	end
	if plan.signSwing then
		local face = swingFrame(frame, plan.signSwing)
		if kind == "Airlock" then
			sign(model, face, site, "Prop.Airlock.Sign", SIGN_RED)
		elseif kind == "RoofDoor" then
			sign(model, face, site, "Prop.Roof.Sign", SIGN_GREEN)
		end
	end
	-- built state
	DoorBuilder.setOpen(model, if kind == "Ajar" then AJAR_ANGLE / leaves[1].full else 1)
end

-- The roll-down grille: housing ("Base"), rails, and telescoping sections.
local function buildGate(model: Model, ctx: Ctx, plan: FixturePlan, random: Random)
	local site = plan.site
	local gate = plan.gate
	assert(gate, "gate plan")
	local mount = ctx.frame * CFrame.Angles(0, math.pi, 0) -- LookVector into rooms[1]
	local half = site.width / 2
	local height = site.height
	local k = gate.sections
	local hs = gate.sectionHeight
	local depthOf = function(i: number): (number, number)
		local a0 = WALL_HALF + 0.05 + (k - i) * (GATE_SECTION_DEPTH + GATE_SECTION_GAP)
		return a0, a0 + GATE_SECTION_DEPTH
	end
	local _, outer = depthOf(1)
	local housingFront = outer + GATE_HANDLE_REACH + 0.06
	local steel: Geometry.PartOptions = { castShadow = false, color = STEEL_GREY, material = Enum.Material.Metal }
	local housing = wallBox(
		model,
		"Base",
		mount,
		-half - gate.rail,
		half + gate.rail,
		height,
		height + gate.housingHeight,
		WALL_HALF,
		housingFront,
		nil,
		steel
	)
	model.PrimaryPart = housing
	local rails = {
		wallBox(
			model,
			"RailLeft",
			mount,
			-half - gate.rail,
			-half,
			0,
			height,
			WALL_HALF,
			housingFront - 0.04,
			nil,
			steel
		),
		wallBox(
			model,
			"RailRight",
			mount,
			half,
			half + gate.rail,
			0,
			height,
			WALL_HALF,
			housingFront - 0.04,
			nil,
			steel
		),
	}
	for _, rail in rails do
		Geometry.makePassthrough(rail)
		hazardStripes(rail, { Enum.NormalId.Front })
	end
	hazardStripes(housing, { Enum.NormalId.Front })
	local motor = wallBox(
		model,
		"Motor",
		mount,
		half + gate.rail - 1.4,
		half + gate.rail - 0.15,
		height + 0.4,
		height + gate.housingHeight - 0.4,
		housingFront,
		housingFront + 0.35,
		"MetalRust",
		{ castShadow = false }
	)
	PropKit.detail(motor)

	local bars: Geometry.PartOptions = { color = STEEL_GREY, material = Enum.Material.Metal }
	local span0, span1 = -half - gate.engage, half + gate.engage
	for i = 1, k do
		local name = if i == 1 then "Grille" else "Grille" .. i
		local bottom = FLOOR_GAP + (i - 1) * (hs - GATE_OVERLAP)
		local a0, a1 = depthOf(i)
		local pivot = mount * CFrame.new(0, bottom, -(a0 + a1) / 2)
		local section = PropKit.leaf(model, name, pivot)
		local mid = (a0 + a1) / 2
		local slats: { { number } } = {
			{ bottom, bottom + (if i == 1 then GATE_BOTTOM_BAR else GATE_SLAT) },
			{ bottom + hs / 2 - GATE_SLAT / 2, bottom + hs / 2 + GATE_SLAT / 2 },
			{ bottom + hs - GATE_SLAT, bottom + hs },
		}
		for j, slat in slats do
			local slatName = if i == 1 and j == 1 then "BottomBar" else string.format("Slat%d", j)
			wallBox(section, slatName, mount, span0, span1, slat[1], slat[2], mid, a1, nil, bars)
		end
		for j = 1, gate.bars do
			local u = -half + 2 * half * (j - 0.5) / gate.bars
			Geometry.cylinder(
				section,
				string.format("Bar%d", j),
				mount * Vector3.new(u, bottom, -(a0 + GATE_BAR_DIAMETER / 2)),
				mount * Vector3.new(u, bottom + hs, -(a0 + GATE_BAR_DIAMETER / 2)),
				GATE_BAR_DIAMETER,
				nil,
				bars
			)
		end
		-- the gaps between bars are wider than a sideways player: a clear plate (Default group) holds them shut
		-- without hiding them
		wallBox(section, "Blocker", mount, -half, half, bottom, bottom + hs, mid - 0.02, mid + 0.02, nil, {
			transparency = 1,
			canCollide = true,
			canQuery = false,
			castShadow = false,
		})
		if i == 1 then
			local handle = Geometry.cylinder(
				section,
				"Handle",
				mount * Vector3.new(-0.45, bottom + GATE_BOTTOM_BAR / 2, -(a1 + GATE_HANDLE_REACH - 0.04)),
				mount * Vector3.new(0.45, bottom + GATE_BOTTOM_BAR / 2, -(a1 + GATE_HANDLE_REACH - 0.04)),
				0.08,
				"TrimMetal",
				{ castShadow = false }
			)
			local hasp = wallBox(
				section,
				"Padlock",
				mount,
				0.9,
				1.15,
				bottom + 0.02,
				bottom + GATE_BOTTOM_BAR - 0.02,
				a1,
				a1 + 0.12,
				"Iron",
				{ castShadow = false }
			)
			PropKit.detail(hasp)
			if handle then
				PropKit.detail(handle)
			end
		end
		-- open: slid up into the housing
		local openBottom = height + 0.05
		local base = model.PrimaryPart :: BasePart
		attach(base, name .. "Open", pivot + Vector3.yAxis * (openBottom - bottom))
		-- smashed: torn out of the rails and dropped flat in front, room face up (the handle clear of the floor), each
		-- higher section landing further out on top of the one below
		local centre = mount * CFrame.new(0, bottom + hs / 2, -mid)
		attach(base, name .. "Centre", centre)
		local out = outer + 0.6 + hs / 2 + (i - 1) * random:NextNumber(0.9, 1.3)
		local lying = CFrame.fromMatrix(Vector3.zero, -mount.RightVector, mount.LookVector, -Vector3.yAxis)
		local landedCentre = CFrame.new(mount * Vector3.new(random:NextNumber(-0.6, 0.6), 0, -out))
			* CFrame.new(0, (i - 1) * (GATE_SECTION_DEPTH + 0.06) + GATE_SECTION_DEPTH / 2 + 0.01, 0)
			* CFrame.Angles(0, random:NextNumber(-0.15, 0.15), 0)
			* lying
		attach(base, name .. "Smashed", landedCentre * centre:ToObjectSpace(pivot))
	end
	-- built rolled up
	DoorBuilder.setOpen(model, 1)
end

local function anchorRootOf(root: Instance?): Instance?
	local anchors = root and root:FindFirstChild(Names.Anchors)
	return anchors and anchors:FindFirstChild("AnchorRoot")
end

-- Fixture "Doors": the Ajar, Gate, Airlock and RoofDoor doors of one level.
local function buildFixtures(ctx: PropKit.FixtureContext): number
	local layout = ctx.layout
	local anchorRoot = anchorRootOf(ctx.levelRoot)
	if not anchorRoot then
		return 0
	end
	local built = 0
	for _, plan in DoorBuilder.planFixtures(layout) do
		local site = plan.site
		local id = site.door.id
		local source = anchorRoot:FindFirstChild("Door_" .. id)
		if not (source and source:IsA("Attachment")) then
			log.warn("%s: door %s has no Door_%s attachment; skipped", layout.id, id, id)
			continue
		end
		local name = "Door_" .. id
		local previous = ctx.parent:FindFirstChild(name)
		if previous then
			previous:Destroy()
		end
		local frame = PropKit.attachmentWorld(source)
		local model = PropKit.model(ctx.parent, name, frame)
		-- attributes first: the pose functions the build ends with dispatch on DoorKind
		setDoorAttributes(model, source, site, layout.id)
		local doorCtx: Ctx = { frame = frame, origin = frame.Position - site.frame.Position }
		if site.door.kind == "Gate" then
			buildGate(model, doorCtx, plan, ctx.random)
		else
			buildSwingDoor(model, doorCtx, plan, layout, ctx.random)
		end
		if site.door.kind == "Airlock" then
			model:AddTag(Tags.AirlockDoor)
			local stairwell = stairwellOf(site)
			if stairwell then
				model:SetAttribute(W.FromLevel, stairwell.from)
				model:SetAttribute(W.ToLevel, stairwell.to)
			end
		end
		built += 1
	end
	return built
end

--------------------------------------------------------------------------------
-- Static open doors
--------------------------------------------------------------------------------

-- The rooms people walk along rather than into.
local CIRCULATION: { [string]: boolean } = {
	Corridor = true,
	LobbyHall = true,
	Airlock = true,
	Stairwell = true,
	Roof = true,
}

-- Every ordinary door of the layout, open, into <level>.Props.
local function buildStatics(ctx: PropKit.StaticContext): number
	local layout = ctx.layout
	local anchorRoot = anchorRootOf(ctx.root)
	if not anchorRoot then
		return 0
	end
	local origin = WorldConfig.levelOrigin(layout.id)
	local rooms = LayoutSchema.indexRooms(layout)
	local sites: { Site } = {}
	for _, door in layout.doors do
		local site = DoorBuilder.site(layout, rooms, door)
		if site then
			table.insert(sites, site)
		end
	end
	local clearance = clearanceFor(layout, sites)
	for _, plan in DoorBuilder.planFixtures(layout) do
		for _, f in fixtureFootprints(plan) do
			table.insert(clearance.hard, f)
		end
	end
	local tallest = 0
	for _, site in sites do
		tallest = math.max(tallest, site.height + HEAD_OVERLAP)
	end
	clearance.parts = partGrid(ctx.root, ctx.parent, origin, LEAF_FLOOR_GAP, tallest)

	local random = ctx.random
	local built, skipped = 0, 0
	for _, site in sites do
		if site.door.kind ~= "Door" then
			continue
		end
		local source = anchorRoot:FindFirstChild("Door_" .. site.door.id)
		if not (source and source:IsA("Attachment")) then
			log.warn("%s: door %s has no Door_%s attachment; skipped", layout.id, site.door.id, site.door.id)
			skipped += 1
			continue
		end
		-- sized from the anchor
		local width = source:GetAttribute(W.DoorWidth)
		local height = source:GetAttribute(W.DoorHeight)
		if type(width) == "number" then
			site.width = width
		end
		if type(height) == "number" then
			site.height = height
		end

		-- seeded preferences (drawn the same way for every door, whatever fits)
		local a, b = site.rooms[1], site.rooms[2]
		local preferred: number
		if CIRCULATION[a.kind] and not CIRCULATION[b.kind] then
			preferred = 1
		elseif CIRCULATION[b.kind] and not CIRCULATION[a.kind] then
			preferred = -1
		else
			preferred = if random:NextNumber() < 0.5 then 1 else -1
		end
		local hingeFirst = if random:NextNumber() < 0.5 then -1 else 1
		local angle = random:NextNumber(STATIC_MIN_ANGLE, STATIC_MAX_ANGLE)
		local crooked = random:NextNumber() < CROOKED_CHANCE
		local tilt = random:NextNumber(CROOKED_TILT_MIN, CROOKED_TILT_MAX)
		local lean = random:NextNumber(CROOKED_LEAN_MIN, CROOKED_LEAN_MAX)

		local angles: { number } = { angle }
		for _, fallback in STATIC_FALLBACK_ANGLES do
			table.insert(angles, fallback)
		end
		local chosen: Leaf? = nil
		for _, ignoreSoft in { false, true } do
			for _, swing in { preferred, -preferred } do
				for _, hinge in { hingeFirst, -hingeFirst } do
					for _, theta in angles do
						for _, hang in (if crooked then { true, false } else { false }) :: { boolean } do
							local leaf = newLeaf(site, "Leaf", "Wood", swing, hinge, theta, theta, false)
							if hang then
								leaf.tilt = tilt
								leaf.lean = lean
							end
							if fits(clearance, site, leaf, { theta }, theta, ignoreSoft) then
								chosen = leaf
								break
							end
						end
						if chosen then
							break
						end
					end
					if chosen then
						break
					end
				end
				if chosen then
					break
				end
			end
			if chosen then
				break
			end
		end
		local leaf = chosen
		if not leaf then
			log.warn("%s: door %s has no room to stand open; not built", layout.id, site.door.id)
			skipped += 1
			continue
		end

		local frame = PropKit.attachmentWorld(source)
		local name = "Door_" .. site.door.id
		local model = PropKit.model(ctx.parent, name, frame)
		local pose = leafFrame(frame, leaf, leaf.angle)
		buildLeafParts(model, pose, leaf, { collide = false, random = random })
		PropKit.setAttributes(model, {
			[W.DoorId] = site.door.id,
			[W.DoorKind] = site.door.kind,
			[W.LevelId] = layout.id,
		})
		local slab, hardware = leafFootprints(site.frame, leaf, leaf.angle)
		table.insert(clearance.hard, slab)
		table.insert(clearance.hard, hardware)
		built += 1
	end
	if skipped > 0 then
		log.warn("%s: %d of %d doors left out", layout.id, skipped, built + skipped)
	end
	return built
end

function DoorBuilder.register(registrar: PropKit.Registrar)
	registrar.static("OpenDoors", buildStatics)
	registrar.fixture("Doors", buildFixtures)
end

return table.freeze(DoorBuilder)
