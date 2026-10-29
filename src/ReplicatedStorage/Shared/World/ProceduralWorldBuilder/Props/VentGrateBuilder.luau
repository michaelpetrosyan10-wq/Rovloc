--!strict
-- VentGrateBuilder: the screwed-shut louvred grate over every wall-vent opening (fixture kind "VentGrate").
--
-- One Model "Grate_<grateId>" per layout grate, rebuilt into Workspace.Runtime.<level> at every run and placed from the
-- `Grate_<id>` attachment VentShaftBuilder leaves on the wall's centre plane (LookVector into the room). Everything is
-- mounted on the room-side face of the wall (for a grate low over a pool basin, the inner face of the basin's coping):
--   * a galvanized flange frame around the 3.5 x 3.5 opening. Each side runs as far past the opening as the wall that
--     is really there allows (perpendicular walls, door casings, neighbouring openings, the floor, the ceiling). Its
--     sill is the PrimaryPart "Base". Over a pool the frame is a box collar reaching back to the wall above the deck;
--   * leaf "Panel": a border overlapping the frame and five tilted louvres that exactly fill the opening. The border and
--     the louvres collide in the Default group, so a vent crawler's VentCollider ball and players outside are stopped,
--     while the gaps between the louvres let light and sight through. The panel hangs on one vertical edge (the side
--     with room to swing it) from hinge knuckles whose pin runs along the panel's front face, so it swings out into
--     the room without ever cutting into the frame or the wall;
--   * four corner screws, leaves "Screw1".."Screw4", through the panel border into the frame.
-- Locked grates (the run plan's lockedGrates) are rusted shut: corroded metal, weld beads along the latch and head
-- seams, a rust streak bled down from a screw.
--
-- State: tag VentGrate; attributes GrateId, GrateState ("Locked" | "Closed"), Lockable, CriticalPath, NodeId,
-- FacingZoneId, LevelId (copied from the attachment). Two disabled prompts on Base.PromptPoint, just in front of the
-- panel: Unscrew (hold GameConfig.UnscrewSeconds, E / ButtonX) and Kick (instant, R / ButtonY); the model is tagged
-- Interactable. On a locked grate both prompts read "Rusted shut".
-- Anchors on Base: ExitAnchor (where a crawler leaving the duct is placed: 2.5 studs into the room at floor level, or at
-- the water surface over a pool, LookVector away from the wall) and EntryAnchor (1.5 studs behind the opening at bore
-- centre, LookVector into the duct).
--
-- Poses (pure; PropKit leaves, so they behave the same in Roblox and in the Lune harness). Each moving piece records
-- its end poses as Attachments on Base next to PropKit's "<leaf>Rest": PanelOpen, PanelKicked (+ PanelCentre, the rest
-- centre the throw is computed about) and Screw<i>Out (where a removed screw comes to rest).
--   setPanel(model, openness)  0 shut .. 1 swung 110 degrees out into the room about its hinge;
--   setScrews(model, progress) the screws back out along the panel normal, spinning, and drop out at the end (1 = out,
--                              lying on the floor, or sunk to the basin floor over a pool);
--   setKicked(model, t)        the panel tears off its hinges (the screws ripping out with it) and lands, warped and
--                              askew, on the floor in front of the opening (sunk to the basin floor over a pool).
-- Builders leave the initial state: panel shut, screws in. At most 22 parts per grate (68 grates rebuild every run).
--
-- VentGrateBuilder also exposes the pure layout planning other builders keep clear of: plan(layout), footprints(layout)
-- (what each grate's frame, swing, throw and exit need in front of the wall) and obstacles(layout) (floor-standing
-- props, triggers, platforms, pillars and basins as level-local boxes), with the 2D overlap test they share.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(script.Parent.Parent.Geometry)
local Palette = require(script.Parent.Parent.Palette)
local VentShaftBuilder = require(script.Parent.Parent.VentShaftBuilder)
local PropKit = require(script.Parent.PropKit)

local log = Log.new("VentGrates")

type Layout = LayoutSchema.LevelLayout
type Room = LayoutSchema.Room
type Side = LayoutSchema.Side

-- How far a piece reaches past each edge of the opening (left = toward -RightVector of the grate frame).
export type Reach = { left: number, right: number, up: number, down: number }

export type GratePlan = {
	grate: LayoutSchema.GrateSpec,
	room: Room,
	frame: CFrame, -- level-local: opening centre on the wall's centre plane, LookVector into the room
	face: number, -- distance from the centre plane to the room-side face the grate is mounted on
	floor: number, -- level-local Y a crawler leaving the grate stands on (the floor, or the water surface)
	rest: number, -- level-local Y loose pieces settle on (the floor, or the basin floor over a pool)
	overBasin: boolean,
	reach: Reach, -- frame flange past the opening edges
	border: Reach, -- panel border past the opening edges (never more than the frame)
	hinge: number, -- -1: the panel hangs on its left edge, +1: on its right edge
}

-- A level-local box standing on the floor plan: centre, first axis (unit, in XZ), half extents along that axis and the
-- perpendicular one (-uz, ux), and the height band it occupies.
export type Footprint = {
	cx: number,
	cz: number,
	ux: number,
	uz: number,
	hu: number,
	hv: number,
	y0: number,
	y1: number,
	kind: string, -- what it is ("Grate", "Anchor", "Trigger", "Platform", "Pillar", "Basin")
}

local W = Attributes.World
local Names = Instances.Names

local EPS = 1e-4
local HALF_BORE = WorldConfig.VentBore / 2
local WALL_HALF = WorldConfig.WallThickness / 2
local EXTERIOR_HALF = WorldConfig.ExteriorWallThickness / 2
local CEILING_PANEL = 0.4 -- the shell's ceiling panels hang this far under a room's height
local MAX_PARTS = 22

-- Frame and panel
local FRAME_DEPTH = 0.08 -- flange thickness off the wall face
local FRAME_REACH = 0.34 -- flange past the opening edge where the wall allows it
local BORDER_REACH = 0.22 -- panel border past the opening edge
local EDGE_GAP = 0.03 -- kept from walls, casings, the floor and the ceiling
local MIN_REACH = 0.06
local PANEL_GAP = 0.005 -- frame front to panel back
local PANEL_DEPTH = 0.25
local LOUVRES = 5
local LOUVRE_CHORD = 0.28
local LOUVRE_THICKNESS = 0.05
local LOUVRE_TILT = math.rad(40) -- room-side edge down
local KNUCKLE_DIAMETER = 0.13
local KNUCKLE_LENGTH = 1.1
local OPEN_ANGLE = math.rad(110)

-- Screws
local SCREW_DIAMETER = 0.13
local SCREW_PROUD = 0.035 -- head above the panel face
local SCREW_TRAVEL = 0.36 -- backs out this far (clear of the panel face)
local SCREW_TURNS = 9
local SCREW_BACKOUT = 0.75 -- fraction of setScrews spent backing out; the rest is the drop

-- Locked dressing
local BEAD_DIAMETER = 0.07
local STREAK_WIDTH = 0.1
local STREAK_LENGTH = 1.7

-- Throw
local KICK_OUT = 0.35 -- gap between the wall face and the near edge of the landed panel
local KICK_SHIFT = 0.8 -- landed panel shifted toward the hinge side
local KICK_YAW = math.rad(16)
local KICK_WARP = math.rad(7) -- a corner left raised off the floor: the panel lands warped
local KICK_HOP = 0.6 -- the panel pops up as it tears free

-- Anchors
local EXIT_OUT = 2.5
local ENTRY_IN = 1.5
local PROMPT_OUT = 0.6

-- Room the grate's moving pieces keep from the walls of the room, prop boxes and doorways
local WALK_DEPTH = 2.5 -- a doorway's walking lane reaches this far into each room
local DOOR_SIDE = 0.5 -- casing / rails / boards beside a door opening
local WINDOW_SIDE = 0.45 -- boards beside a window opening

local GALVANIZED = "MetalGalvanized"
local RUST = "MetalRust"
local SCREW_KEY = "TrimMetal"
local RUST_SCREW_KEY = "Iron"
local STREAK_COLOR = Color3.fromRGB(88, 48, 28)

-- Floor-standing pieces other builders put on layout anchors, as width (along the anchor's RightVector) x depth.
local ANCHOR_KEEPOUT: { [string]: Vector2 } = {
	PlayerSpawn = Vector2.new(3, 3),
	TrapCandidate = Vector2.new(3, 3),
	FlaskCandidate = Vector2.new(1, 1),
	BatteryCandidate = Vector2.new(1.4, 1.4),
	CreatureSpawn = Vector2.new(4, 4),
	CreatureScarePose = Vector2.new(4, 4),
	Locker = Vector2.new(3, 2.6),
	ParachuteCrate = Vector2.new(6, 5),
	FloodlightSwitch = Vector2.new(2.4, 1.6),
	LabCounter = Vector2.new(10.6, 4.1),
	Corpse = Vector2.new(6, 6),
	SmashedLocker = Vector2.new(3.6, 3.2),
	Clutter = Vector2.new(3, 3),
	ReadyPad = Vector2.new(5, 5),
	Terminal = Vector2.new(3, 2.6),
	-- Floor objectives (wall-mounted stations: centred on their wall-face anchor, so half the depth reaches out)
	FuseCandidate = Vector2.new(1.6, 1.6),
	MasterKeyCandidate = Vector2.new(1.2, 1.2),
	ReagentCandidate = Vector2.new(1, 1),
	ValveWheelCandidate = Vector2.new(2, 2),
	BoltCutterCandidate = Vector2.new(1.8, 1.8),
	BreakerPanel = Vector2.new(4.2, 7.2),
	FumeHood = Vector2.new(6.2, 9),
	Generator = Vector2.new(4.4, 6.6),
}
local ANCHOR_BAND = 4 -- an anchor's box spans this far above and below its point
-- Floor in front of an anchored prop that stays its own, as width along the anchor's RightVector x depth beyond its
-- front (along its LookVector): a hideable locker's door swings out about 2.9 studs, and when the Creature tears it
-- off it lands face up up to about 7.2 studs out from the row and 6 along it.
local ANCHOR_APRON: { [string]: Vector2 } = {
	Locker = Vector2.new(12.4, 7.4),
}

local INWARD: { [Side]: Vector3 } = {
	N = Vector3.new(0, 0, 1),
	S = Vector3.new(0, 0, -1),
	W = Vector3.new(1, 0, 0),
	E = Vector3.new(-1, 0, 0),
}

local VentGrateBuilder = {}

VentGrateBuilder.MaxParts = MAX_PARTS
VentGrateBuilder.OpenAngle = OPEN_ANGLE
VentGrateBuilder.ExitOut = EXIT_OUT
VentGrateBuilder.EntryIn = ENTRY_IN

--------------------------------------------------------------------------------
-- Footprints (level-local 2D boxes)
--------------------------------------------------------------------------------

local function footprint(
	cx: number,
	cz: number,
	ux: number,
	uz: number,
	hu: number,
	hv: number,
	y0: number,
	y1: number,
	kind: string
): Footprint
	return { cx = cx, cz = cz, ux = ux, uz = uz, hu = hu, hv = hv, y0 = y0, y1 = y1, kind = kind }
end

-- Axis-aligned box over a layout rect.
local function rectFootprint(r: LayoutSchema.Rect, y0: number, y1: number, kind: string): Footprint
	return footprint(r.x + r.w / 2, r.z + r.d / 2, 1, 0, r.w / 2, r.d / 2, y0, y1, kind)
end

-- The floor-plan box enclosing every corner of the box `size` at `cframe` (level-local), aligned with the box's own
-- horizontal axis (its RightVector, or its UpVector when the box lies on its side).
function VentGrateBuilder.footprintOf(cframe: CFrame, size: Vector3, kind: string): Footprint
	local axis = Vector3.new(cframe.RightVector.X, 0, cframe.RightVector.Z)
	if axis.Magnitude < 0.2 then
		axis = Vector3.new(cframe.UpVector.X, 0, cframe.UpVector.Z)
	end
	if axis.Magnitude < 0.2 then
		axis = Vector3.new(cframe.LookVector.X, 0, cframe.LookVector.Z)
	end
	axis = axis.Unit
	local other = Vector3.new(-axis.Z, 0, axis.X)
	local half = size / 2
	local u0, u1, v0, v1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge, math.huge, -math.huge
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local p = cframe * Vector3.new(sx * half.X, sy * half.Y, sz * half.Z)
				local u, v = p.X * axis.X + p.Z * axis.Z, p.X * other.X + p.Z * other.Z
				u0, u1 = math.min(u0, u), math.max(u1, u)
				v0, v1 = math.min(v0, v), math.max(v1, v)
				y0, y1 = math.min(y0, p.Y), math.max(y1, p.Y)
			end
		end
	end
	local cu, cv = (u0 + u1) / 2, (v0 + v1) / 2
	return footprint(
		axis.X * cu + other.X * cv,
		axis.Z * cu + other.Z * cv,
		axis.X,
		axis.Z,
		(u1 - u0) / 2,
		(v1 - v0) / 2,
		y0,
		y1,
		kind
	)
end

local function corners(f: Footprint): { Vector2 }
	local vx, vz = -f.uz, f.ux
	local out: { Vector2 } = {}
	for _, su in { -1, 1 } do
		for _, sv in { -1, 1 } do
			table.insert(
				out,
				Vector2.new(f.cx + f.ux * f.hu * su + vx * f.hv * sv, f.cz + f.uz * f.hu * su + vz * f.hv * sv)
			)
		end
	end
	return out
end

-- Half extents of `f`'s axis-aligned bounding box on the floor plan.
local function boundsHalf(f: Footprint): (number, number)
	local ax, az = math.abs(f.ux), math.abs(f.uz)
	return ax * f.hu + az * f.hv, az * f.hu + ax * f.hv
end

-- Whether two footprints overlap by more than `margin` (height bands, bounding boxes, then separating axes on the
-- floor plan).
function VentGrateBuilder.overlaps(a: Footprint, b: Footprint, margin: number?): boolean
	local m = margin or 0
	if math.min(a.y1, b.y1) - math.max(a.y0, b.y0) <= m then
		return false
	end
	local aex, aez = boundsHalf(a)
	local bex, bez = boundsHalf(b)
	if math.abs(a.cx - b.cx) >= aex + bex - m or math.abs(a.cz - b.cz) >= aez + bez - m then
		return false
	end
	local axes: { Vector2 } = {
		Vector2.new(a.ux, a.uz),
		Vector2.new(-a.uz, a.ux),
		Vector2.new(b.ux, b.uz),
		Vector2.new(-b.uz, b.ux),
	}
	local ca, cb = corners(a), corners(b)
	for _, axis in axes do
		local a0, a1, b0, b1 = math.huge, -math.huge, math.huge, -math.huge
		for _, p in ca do
			local d = p:Dot(axis)
			a0, a1 = math.min(a0, d), math.max(a1, d)
		end
		for _, p in cb do
			local d = p:Dot(axis)
			b0, b1 = math.min(b0, d), math.max(b1, d)
		end
		if math.min(a1, b1) - math.max(a0, b0) <= m then
			return false
		end
	end
	return true
end

--------------------------------------------------------------------------------
-- Rooms and walls
--------------------------------------------------------------------------------

-- Half the thickness of the wall along `side` of `room` at `along` (X on an N / S side, Z on a W / E side): a room
-- across the side means an interior wall, nothing means the thicker facade.
function VentGrateBuilder.wallHalfAt(layout: Layout, room: Room, side: Side, along: number): number
	local r = room.rect
	local px, pz
	if side == "N" then
		px, pz = along, r.z - 0.25
	elseif side == "S" then
		px, pz = along, r.z + r.d + 0.25
	elseif side == "W" then
		px, pz = r.x - 0.25, along
	else
		px, pz = r.x + r.w + 0.25, along
	end
	for _, other in layout.rooms do
		if other ~= room and LayoutSchema.rectContains(other.rect, px, pz) then
			return WALL_HALF
		end
	end
	return EXTERIOR_HALF
end

-- Whether `d` (a corner's distance in from one side of a room) clears that side's wall by `margin`. The wall is an
-- interior one or the thicker facade; only a corner between the two faces needs to know which.
local function clearOfSide(layout: Layout, room: Room, side: Side, along: number, d: number, margin: number): boolean
	if d < WALL_HALF + margin - EPS then
		return false
	end
	if d >= EXTERIOR_HALF + margin - EPS then
		return true
	end
	return d >= VentGrateBuilder.wallHalfAt(layout, room, side, along) + margin - EPS
end

-- Whether every corner of `f` stands inside `room`, clear of its walls by `margin`.
function VentGrateBuilder.insideRoom(layout: Layout, room: Room, f: Footprint, margin: number): boolean
	local r = room.rect
	for _, p in corners(f) do
		local x, z = p.X, p.Y
		local cx = math.clamp(x, r.x, r.x + r.w)
		local cz = math.clamp(z, r.z, r.z + r.d)
		if
			not clearOfSide(layout, room, "W", cz, x - r.x, margin)
			or not clearOfSide(layout, room, "E", cz, r.x + r.w - x, margin)
			or not clearOfSide(layout, room, "N", cx, z - r.z, margin)
			or not clearOfSide(layout, room, "S", cx, r.z + r.d - z, margin)
		then
			return false
		end
	end
	return true
end

-- Floor-standing things in `layout` that moving prop pieces keep clear of: the boxes of the props other builders put on
-- anchors (with the floor some of them need in front), FloorDebris piles, platforms, pillars and pool basins.
function VentGrateBuilder.obstacles(layout: Layout): { Footprint }
	local out: { Footprint } = {}
	for _, anchor in layout.anchors do
		local size = ANCHOR_KEEPOUT[anchor.kind]
		if not size then
			continue
		end
		local yaw = math.rad(anchor.yaw or 0)
		local cf = CFrame.new(anchor.pos) * CFrame.Angles(0, yaw, 0)
		local f = footprint(
			anchor.pos.X,
			anchor.pos.Z,
			cf.RightVector.X,
			cf.RightVector.Z,
			size.X / 2,
			size.Y / 2,
			anchor.pos.Y - ANCHOR_BAND,
			anchor.pos.Y + ANCHOR_BAND,
			"Anchor"
		)
		table.insert(out, f)
		local apron = ANCHOR_APRON[anchor.kind]
		if apron then
			local centre = anchor.pos + cf.LookVector * (size.Y + apron.Y) / 2
			table.insert(
				out,
				footprint(
					centre.X,
					centre.Z,
					cf.RightVector.X,
					cf.RightVector.Z,
					apron.X / 2,
					apron.Y / 2,
					anchor.pos.Y - ANCHOR_BAND,
					anchor.pos.Y + ANCHOR_BAND,
					"Anchor"
				)
			)
		end
	end
	for _, trigger in layout.triggers do
		if trigger.kind == "FloorDebris" then
			local y0 = trigger.y or 0
			table.insert(out, rectFootprint(trigger.rect, y0, y0 + trigger.height, "Trigger"))
		end
	end
	for _, platform in (layout.platforms or {}) :: { LayoutSchema.Platform } do
		table.insert(out, rectFootprint(platform.rect, platform.top - platform.thickness, platform.top, "Platform"))
	end
	for _, pillar in (layout.pillars or {}) :: { LayoutSchema.Pillar } do
		local half = pillar.size / 2 + 0.3 -- the pillar's base trim
		table.insert(out, footprint(pillar.x, pillar.z, 1, 0, half, half, 0, 100, "Pillar"))
	end
	for _, basin in (layout.basins or {}) :: { LayoutSchema.Basin } do
		table.insert(out, rectFootprint(basin.rect, -basin.depth, 0.5, "Basin"))
	end
	return out
end

-- The walking lane through every passable doorway of `layout`: its clear width, through the wall and WALK_DEPTH into
-- both rooms.
local function doorLanes(layout: Layout, rooms: { [string]: Room }): { Footprint }
	local out: { Footprint } = {}
	for _, door in layout.doors do
		if door.kind == "Boarded" then
			continue
		end
		local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
		if not (a and b) then
			continue
		end
		local edge = LayoutSchema.sharedEdge(a.rect, b.rect)
		if not edge then
			continue
		end
		local half = LayoutSchema.doorWidth(door) / 2
		local across = WALL_HALF + WALK_DEPTH
		local height = LayoutSchema.doorHeight(door)
		if edge.axis == "X" then
			table.insert(out, footprint(edge.coord, door.at, 1, 0, across, half, 0, height, "Door"))
		else
			table.insert(out, footprint(door.at, edge.coord, 1, 0, half, across, 0, height, "Door"))
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Planning
--------------------------------------------------------------------------------

-- The basin of `room` a grate on `node` opens over (VentShaftBuilder's probe), and the distance from the node to the
-- inner face of its coping.
local function basinUnder(
	layout: Layout,
	room: Room,
	node: LayoutSchema.VentNodeSpec,
	inward: Vector3
): (LayoutSchema.Basin?, number)
	local probe = WALL_HALF + Geometry.BasinWall / 2
	local x, z = node.x + inward.X * probe, node.z + inward.Z * probe
	for _, basin in (layout.basins or {}) :: { LayoutSchema.Basin } do
		local r = basin.rect
		if basin.room ~= room.id or not LayoutSchema.rectContains(r, x, z) then
			continue
		end
		local wall = Geometry.BasinWall
		local edge: number
		if inward.X > 0.5 then
			edge = r.x + wall - node.x
		elseif inward.X < -0.5 then
			edge = node.x - (r.x + r.w - wall)
		elseif inward.Z > 0.5 then
			edge = r.z + wall - node.z
		else
			edge = node.z - (r.z + r.d - wall)
		end
		return basin, math.max(edge, WALL_HALF)
	end
	return nil, WALL_HALF
end

type Interval = { lo: number, hi: number, shared: boolean }

-- Solid things on the room face of a grate's wall line, as intervals along the line's own axis (X for a wall of
-- constant Z, Z for a wall of constant X). `shared` marks another grate's opening (each grate gets half the pier).
local function wallObstacles(
	layout: Layout,
	rooms: { [string]: Room },
	room: Room,
	side: Side,
	grate: LayoutSchema.GrateSpec,
	nodes: { [string]: LayoutSchema.VentNodeSpec }
): { Interval }
	local r = room.rect
	local alongX = side == "N" or side == "S"
	local coord = if side == "N" then r.z elseif side == "S" then r.z + r.d elseif side == "W" then r.x else r.x + r.w
	local lo = if alongX then r.x else r.z
	local hi = if alongX then r.x + r.w else r.z + r.d
	local inward = INWARD[side]
	local depth = 1 -- probe the perpendicular walls a stud into the room
	local probeAcross = coord + (if alongX then inward.Z else inward.X) * depth
	local loSide: Side = if alongX then "W" else "N"
	local hiSide: Side = if alongX then "E" else "S"
	local out: { Interval } = {
		{ lo = -math.huge, hi = lo + VentGrateBuilder.wallHalfAt(layout, room, loSide, probeAcross), shared = false },
		{ lo = hi - VentGrateBuilder.wallHalfAt(layout, room, hiSide, probeAcross), hi = math.huge, shared = false },
	}
	local lineAxis = if alongX then "Z" else "X"
	for _, door in layout.doors do
		local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
		if not (a and b) then
			continue
		end
		local edge = LayoutSchema.sharedEdge(a.rect, b.rect)
		if edge and edge.axis == lineAxis and math.abs(edge.coord - coord) < 1e-3 then
			local half = LayoutSchema.doorWidth(door) / 2
			table.insert(out, { lo = door.at - half - DOOR_SIDE, hi = door.at + half + DOOR_SIDE, shared = false })
		end
	end
	for _, window in (layout.windows or {}) :: { LayoutSchema.Window } do
		local wr = rooms[window.room]
		if not wr then
			continue
		end
		local wCoord = if window.side == "N"
			then wr.rect.z
			elseif window.side == "S" then wr.rect.z + wr.rect.d
			elseif window.side == "W" then wr.rect.x
			else wr.rect.x + wr.rect.w
		local wAxis = if window.side == "N" or window.side == "S" then "Z" else "X"
		if wAxis == lineAxis and math.abs(wCoord - coord) < 1e-3 then
			local half = window.width / 2
			table.insert(
				out,
				{ lo = window.at - half - WINDOW_SIDE, hi = window.at + half + WINDOW_SIDE, shared = false }
			)
		end
	end
	local vents = layout.vents
	if vents then
		for _, other in vents.grates do
			local node = nodes[other.node]
			if other == grate or other.room ~= grate.room or not node then
				continue
			end
			local oCoord = if alongX then node.z else node.x
			if math.abs(oCoord - coord) < 1e-3 then
				local u = if alongX then node.x else node.z
				table.insert(out, { lo = u - HALF_BORE, hi = u + HALF_BORE, shared = true })
			end
		end
	end
	return out
end

-- Clear wall beside an opening [u0, u1] (line-axis coordinates) toward lower and higher coordinates.
local function lateralClearance(obstacles: { Interval }, u0: number, u1: number): (number, number)
	local below, above = math.huge, math.huge
	for _, o in obstacles do
		if o.hi <= u0 + EPS then
			local gap = u0 - o.hi
			below = math.min(below, if o.shared then gap / 2 else gap)
		elseif o.lo >= u1 - EPS then
			local gap = o.lo - u1
			above = math.min(above, if o.shared then gap / 2 else gap)
		else
			-- overlapping the opening (a layout error the validator reports): no room either side
			below, above = 0, 0
		end
	end
	return below, above
end

-- The panel's footprints over its swing (closed, part-way, open) for hinge side `hinge`, level-local.
local function swingFootprints(plan: GratePlan, hinge: number): { Footprint }
	local out: { Footprint } = {}
	local frame = plan.frame
	local b = plan.border
	local width = 2 * HALF_BORE + b.left + b.right
	local height = 2 * HALF_BORE + b.up + b.down
	local front = plan.face + FRAME_DEPTH + PANEL_GAP + PANEL_DEPTH
	local hingeU = if hinge < 0 then -(HALF_BORE + b.left) else HALF_BORE + b.right
	local yMid = (b.up - b.down) / 2
	for _, angle in { 0, math.rad(40), math.rad(80), OPEN_ANGLE } do
		-- leaf-local: X from the hinge across the panel, the panel behind its front-face hinge line
		local spin = if hinge < 0 then CFrame.new() else CFrame.Angles(0, math.pi, 0)
		local turn = CFrame.Angles(0, (if hinge < 0 then 1 else -1) * angle, 0)
		local zSign = if hinge < 0 then 1 else -1 -- leaf-local Z of "behind the front face"
		local centre = frame
			* CFrame.new(hingeU, yMid, -front)
			* spin
			* turn
			* CFrame.new(width / 2, 0, zSign * PANEL_DEPTH / 2)
		table.insert(
			out,
			VentGrateBuilder.footprintOf(centre, Vector3.new(width, height, PANEL_DEPTH + KNUCKLE_DIAMETER), "Grate")
		)
	end
	return out
end

-- Where the kicked panel's centre lands (level-local) for hinge side `hinge`: fallen forward onto its face in front of
-- the opening (its top edge away from the wall), shifted toward the hinge side, yawed and warped, its nearest corner
-- KICK_OUT in front of the wall face and its lowest point (the hinge knuckle and screw heads on its front face
-- included) on `plan.rest`.
local function landing(plan: GratePlan, hinge: number): (CFrame, Vector3)
	local b = plan.border
	local size = Vector3.new(2 * HALF_BORE + b.left + b.right, 2 * HALF_BORE + b.up + b.down, PANEL_DEPTH)
	local frame = plan.frame
	local yaw = CFrame.Angles(0, hinge * KICK_YAW, 0)
	local right = (yaw * frame.RightVector).Unit
	local away = (yaw * frame.LookVector).Unit
	-- face down: panel X along the (yawed) wall, its height pointing away from the wall, its back face up
	local lying = CFrame.fromMatrix(Vector3.zero, right, away, Vector3.yAxis)
	local warp = CFrame.fromAxisAngle((right + away).Unit, hinge * KICK_WARP)
	local orient = warp * lying
	-- what the panel rests on, about its centre (panel-local -Z is the front face): its box, the screw heads and the
	-- hinge knuckle standing proud of the front face
	local half = size / 2
	local cu, cv = (b.right - b.left) / 2, (b.up - b.down) / 2
	local points: { Vector3 } = {}
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				table.insert(points, Vector3.new(sx * half.X, sy * half.Y, sz * half.Z))
			end
			local su = if sx < 0 then -(HALF_BORE + b.left / 2) else HALF_BORE + b.right / 2
			local sv = if sy < 0 then -(HALF_BORE + b.down / 2) else HALF_BORE + b.up / 2
			table.insert(points, Vector3.new(su - cu, sv - cv, -(half.Z + SCREW_PROUD)))
		end
	end
	local knuckleU = (if hinge < 0 then -(HALF_BORE + b.left) else HALF_BORE + b.right) - cu
	local top = HALF_BORE + b.up - 0.25 - cv
	for _, y in { top - KNUCKLE_LENGTH, top } do
		table.insert(points, Vector3.new(knuckleU, y, -(half.Z + KNUCKLE_DIAMETER / 2)))
	end
	local low, near = math.huge, math.huge
	for _, point in points do
		local p = orient * point
		low = math.min(low, p.Y)
		near = math.min(near, p:Dot(frame.LookVector))
	end
	local spot = frame * Vector3.new(hinge * KICK_SHIFT, 0, -(plan.face + KICK_OUT - near))
	return CFrame.new(spot.X, plan.rest - low + 0.005, spot.Z) * orient, size
end

-- Pure planning for every grate of `layout`: frame, mounting face, flange and border reach per side, the floor in
-- front and the hinge side (the side whose swing and throw stay clear of walls, doorways and props, with the most wall
-- to swing the panel back against). VentGrateBuilder.plan keeps the result per layout.
local function computePlans(layout: Layout): { GratePlan }
	local plans: { GratePlan } = {}
	local vents = layout.vents
	if not vents then
		return plans
	end
	local rooms = LayoutSchema.indexRooms(layout)
	local nodes: { [string]: LayoutSchema.VentNodeSpec } = {}
	for _, node in vents.nodes do
		if not nodes[node.id] then
			nodes[node.id] = node
		end
	end
	local lanes = doorLanes(layout, rooms)
	local obstacles = VentGrateBuilder.obstacles(layout)
	local claimed: { [string]: boolean } = {}
	for _, grate in vents.grates do
		local node, room = nodes[grate.node], rooms[grate.room]
		if not (node and room) or claimed[grate.node] then
			continue -- VentShaftBuilder reports these and builds no attachment for them
		end
		local found = LayoutSchema.sideOfPoint(room.rect, node.x, node.z)
		if not found then
			continue
		end
		local side: Side = found :: Side
		claimed[grate.node] = true
		local inward = INWARD[side]
		local y = LayoutSchema.ventNodeY(node)
		local position = Vector3.new(node.x, y, node.z)
		local frame = CFrame.lookAt(position, position + inward)
		local basin, face = basinUnder(layout, room, node, inward)

		-- lateral clearance, mapped onto the grate frame's left / right
		local alongX = side == "N" or side == "S"
		local u = if alongX then node.x else node.z
		local below, above =
			lateralClearance(wallObstacles(layout, rooms, room, side, grate, nodes), u - HALF_BORE, u + HALF_BORE)
		local axisDir = if alongX then Vector3.xAxis else Vector3.zAxis
		local rightIsUp = frame.RightVector:Dot(axisDir) > 0
		local left = if rightIsUp then below else above
		local right = if rightIsUp then above else below
		local ceiling = LayoutSchema.roomHeight(layout, room) - CEILING_PANEL
		local floorUnder = if basin then -basin.depth else 0
		local function reachFor(clearance: number, where: string): number
			local available = clearance - EDGE_GAP
			if available < MIN_REACH then
				log.warn(
					"%s: grate %s has only %.2f studs of wall %s of its opening",
					layout.id,
					grate.id,
					clearance,
					where
				)
			end
			return math.clamp(available, MIN_REACH, FRAME_REACH)
		end
		local clear: Reach = {
			left = left,
			right = right,
			up = ceiling - (y + HALF_BORE),
			down = (y - HALF_BORE) - floorUnder,
		}
		local reach: Reach = {
			left = reachFor(clear.left, "left"),
			right = reachFor(clear.right, "right"),
			up = reachFor(clear.up, "above"),
			down = reachFor(clear.down, "below"),
		}
		local border: Reach = {
			left = math.min(BORDER_REACH, reach.left),
			right = math.min(BORDER_REACH, reach.right),
			up = math.min(BORDER_REACH, reach.up),
			down = math.min(BORDER_REACH, reach.down),
		}

		local plan: GratePlan = {
			grate = grate,
			room = room,
			frame = frame,
			face = face,
			floor = if basin then basin.waterLevel else 0,
			rest = floorUnder,
			overBasin = basin ~= nil,
			reach = reach,
			border = border,
			hinge = -1,
		}

		-- hinge side: fewest clashes of the swing and the throw with the room's walls, doorways and props; then the side
		-- with more wall beside the opening
		local best, bestScore = -1, math.huge
		for _, hinge in { -1, 1 } do
			local pieces = swingFootprints(plan, hinge)
			local landed, size = landing(plan, hinge)
			table.insert(pieces, VentGrateBuilder.footprintOf(landed, size, "Grate"))
			local clashes = 0
			for _, piece in pieces do
				if not VentGrateBuilder.insideRoom(layout, room, piece, 0) then
					clashes += 1
				end
				for _, lane in lanes do
					if VentGrateBuilder.overlaps(piece, lane, 0.01) then
						clashes += 1
					end
				end
				for _, obstacle in obstacles do
					if
						not (plan.overBasin and obstacle.kind == "Basin")
						and VentGrateBuilder.overlaps(piece, obstacle, 0.01)
					then
						clashes += 1
					end
				end
			end
			local wall = if hinge < 0 then clear.left else clear.right
			local score = clashes * 1000 - math.min(wall, 100)
			if score < bestScore - EPS then
				best, bestScore = hinge, score
			end
		end
		plan.hinge = best
		table.insert(plans, plan)
	end
	return plans
end

-- Layouts are static, so each one is planned once (at boot, by the static doors keeping clear of the grates) and the
-- plans are shared by every later run: treat them as read-only.
local planCache = setmetatable({} :: { [Layout]: { GratePlan } }, { __mode = "k" })

function VentGrateBuilder.plan(layout: Layout): { GratePlan }
	local cached = planCache[layout]
	if cached then
		return cached
	end
	local plans = table.freeze(computePlans(layout))
	planCache[layout] = plans
	return plans
end

-- What each grate needs kept clear in front of its wall (level-local): the frame, the panel over its whole swing, the
-- thrown panel and the lane a crawler leaves by.
function VentGrateBuilder.footprints(layout: Layout): { Footprint }
	local out: { Footprint } = {}
	for _, plan in VentGrateBuilder.plan(layout) do
		for _, piece in swingFootprints(plan, plan.hinge) do
			table.insert(out, piece)
		end
		local landed, size = landing(plan, plan.hinge)
		table.insert(out, VentGrateBuilder.footprintOf(landed, size, "Grate"))
		local r = plan.reach
		local lane = plan.frame * CFrame.new((r.right - r.left) / 2, 0, -(WALL_HALF + plan.face + EXIT_OUT + 1) / 2)
		table.insert(
			out,
			VentGrateBuilder.footprintOf(
				lane,
				Vector3.new(
					2 * HALF_BORE + r.left + r.right,
					2 * HALF_BORE + r.up + r.down,
					plan.face + EXIT_OUT + 1 - WALL_HALF
				),
				"Grate"
			)
		)
	end
	return out
end

--------------------------------------------------------------------------------
-- Pose helpers
--------------------------------------------------------------------------------

-- Rotation of `cf` as (axis, angle) with the angle in [-pi, pi].
local function axisAngle(cf: CFrame): (Vector3, number)
	local axis, angle = cf:ToAxisAngle()
	if angle > math.pi then
		angle -= 2 * math.pi
	end
	return axis, angle
end

-- The rotation part of `cf` scaled by `t` about its own axis.
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

-- World CFrame of the pose Attachment `name` on `model`'s Base, if any.
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

-- The transform that takes leaf `leaf` from its rest pivot to the pose recorded as `poseName`.
local function poseTransform(model: Model, leaf: string, poseName: string): CFrame?
	local rest = PropKit.leafRest(model, leaf)
	local target = posePoint(model, poseName)
	if not (rest and target) then
		return nil
	end
	return rest:ToObjectSpace(target)
end

-- Swings the panel: 0 shut, 1 open (110 degrees out into the room about its hinge).
function VentGrateBuilder.setPanel(model: Model, openness: number): boolean
	local open = poseTransform(model, "Panel", "PanelOpen")
	if not open then
		return false
	end
	return PropKit.poseLeaf(model, "Panel", partialRotation(open, math.clamp(openness, 0, 1)))
end

-- Screw `index` at `progress`: backing out along its axis while turning, then dropping to where it comes to rest.
local function screwTransform(model: Model, index: number, progress: number): CFrame?
	local name = "Screw" .. index
	local rest = PropKit.leafRest(model, name)
	local out = poseTransform(model, name, name .. "Out")
	if not (rest and out) then
		return nil
	end
	local p = math.clamp(progress, 0, 1)
	local turns = SCREW_TURNS * 2 * math.pi
	if p <= SCREW_BACKOUT then
		local q = p / SCREW_BACKOUT
		return CFrame.new(0, 0, -SCREW_TRAVEL * q) * CFrame.Angles(0, 0, turns * q)
	end
	local f = (p - SCREW_BACKOUT) / (1 - SCREW_BACKOUT)
	local backed = CFrame.new(0, 0, -SCREW_TRAVEL) * CFrame.Angles(0, 0, turns)
	-- falls: horizontal drift linear, height accelerating, tumbling into its resting orientation
	local up = rest:VectorToObjectSpace(Vector3.yAxis)
	local delta = out.Position - backed.Position
	local rise = delta:Dot(up)
	local flat = delta - up * rise
	local position = backed.Position + flat * f + up * (rise * f * f)
	local turn = partialRotation(backed.Rotation:Inverse() * out.Rotation, f)
	return CFrame.new(position) * backed.Rotation * turn
end

-- Unscrews the four corner screws: 0 in, 1 out (backed out, then fallen to the floor).
function VentGrateBuilder.setScrews(model: Model, progress: number): boolean
	local ok = true
	for i = 1, 4 do
		local transform = screwTransform(model, i, progress)
		if not (transform and PropKit.poseLeaf(model, "Screw" .. i, transform)) then
			ok = false
		end
	end
	return ok
end

-- Tears the panel off: 0 shut, 1 lying warped on the floor in front of the opening. The screws ride with the panel
-- (they rip out of the frame with it).
function VentGrateBuilder.setKicked(model: Model, t: number): boolean
	local rest = PropKit.leafRest(model, "Panel")
	local landed = posePoint(model, "PanelKicked")
	local centre = posePoint(model, "PanelCentre")
	if not (rest and landed and centre) then
		return false
	end
	local k = math.clamp(t, 0, 1)
	-- the throw is computed about the panel's centre: out first, then tipping over and dropping, with a short hop
	local offset = centre:ToObjectSpace(rest) -- centre -> pivot
	local landedCentre = landed * offset:Inverse()
	local delta = landedCentre.Position - centre.Position
	local drop = delta.Y
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local out = 1 - (1 - k) * (1 - k)
	local tip = smoothstep(k)
	local position = centre.Position + flat * out + Vector3.yAxis * (drop * tip + KICK_HOP * math.sin(math.pi * k))
	local rotation = centre.Rotation * partialRotation(centre.Rotation:Inverse() * landedCentre.Rotation, tip)
	local pivot = CFrame.new(position) * rotation * offset
	local transform = rest:ToObjectSpace(pivot)
	local ok = PropKit.poseLeaf(model, "Panel", transform)
	-- screws keep their place on the panel
	local world = pivot * rest:Inverse()
	for i = 1, 4 do
		local name = "Screw" .. i
		local screwRest = PropKit.leafRest(model, name)
		if not (screwRest and PropKit.poseLeaf(model, name, screwRest:ToObjectSpace(world * screwRest))) then
			ok = false
		end
	end
	return ok
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

type Builder = {
	model: Model,
	frame: CFrame, -- world: opening centre on the wall's centre plane, LookVector into the room
	random: Random,
}

-- A box [u0, u1] x [y0, y1] x [a0, a1] in the grate frame (u along RightVector, y up, a out into the room).
local function box(
	b: Builder,
	parent: Instance,
	name: string,
	u0: number,
	u1: number,
	y0: number,
	y1: number,
	a0: number,
	a1: number,
	key: string,
	options: Geometry.PartOptions?
): Part
	return Geometry.part(
		parent,
		name,
		b.frame * CFrame.new((u0 + u1) / 2, (y0 + y1) / 2, -(a0 + a1) / 2),
		Vector3.new(u1 - u0, y1 - y0, a1 - a0),
		key,
		options
	)
end

-- A cylinder between two grate-frame points.
local function rod(
	b: Builder,
	parent: Instance,
	name: string,
	from: Vector3,
	to: Vector3,
	diameter: number,
	key: string,
	options: Geometry.PartOptions?
): Part?
	return Geometry.cylinder(
		parent,
		name,
		b.frame * Vector3.new(from.X, from.Y, -from.Z),
		b.frame * Vector3.new(to.X, to.Y, -to.Z),
		diameter,
		key,
		options
	)
end

-- A worn variant of a palette colour (every grate is a little different).
local function worn(key: string, random: Random): Color3
	local base = Palette.get(key).color
	local shade = random:NextNumber(-0.06, 0.04)
	return Color3.new(
		math.clamp(base.R + shade, 0, 1),
		math.clamp(base.G + shade, 0, 1),
		math.clamp(base.B + shade * 1.2, 0, 1)
	)
end

local function attach(base: BasePart, name: string, world: CFrame): Attachment
	return Geometry.attachment(base, name, base.CFrame:ToObjectSpace(world))
end

local function buildGrate(plan: GratePlan, source: Attachment, parent: Instance, locked: boolean, random: Random): Model
	local frame = PropKit.attachmentWorld(source)
	local origin = frame.Position - plan.frame.Position -- level origin (the plan is level-local)
	local id = plan.grate.id
	local name = VentShaftBuilder.GratePrefix .. id
	local previous = parent:FindFirstChild(name)
	if previous then
		previous:Destroy()
	end
	local face = plan.face
	local model = PropKit.model(parent, name, frame * CFrame.new(0, 0, -face))
	local b: Builder = { model = model, frame = frame, random = random }
	local r, bd = plan.reach, plan.border
	local key = if locked then RUST else GALVANIZED
	local metal: Geometry.PartOptions = { castShadow = false, color = worn(key, random) }

	-- Frame. Over a pool the members reach back to the wall face, closing the slot above the coping.
	local a0 = if plan.overBasin then WALL_HALF else face
	local a1 = face + FRAME_DEPTH
	local uL, uR = -(HALF_BORE + r.left), HALF_BORE + r.right
	local base = box(b, model, "Base", uL, uR, -(HALF_BORE + r.down), -HALF_BORE, a0, a1, key, metal)
	model.PrimaryPart = base
	box(b, model, "FrameTop", uL, uR, HALF_BORE, HALF_BORE + r.up, a0, a1, key, metal)
	box(b, model, "FrameLeft", uL, -HALF_BORE, -HALF_BORE, HALF_BORE, a0, a1, key, metal)
	box(b, model, "FrameRight", HALF_BORE, uR, -HALF_BORE, HALF_BORE, a0, a1, key, metal)

	-- Panel, hung from a pin along its front face on the hinge edge
	local back = a1 + PANEL_GAP
	local front = back + PANEL_DEPTH
	local pL, pR = -(HALF_BORE + bd.left), HALF_BORE + bd.right
	local pD, pU = -(HALF_BORE + bd.down), HALF_BORE + bd.up
	local hinge = plan.hinge
	local hingeU = if hinge < 0 then pL else pR
	local spin = if hinge < 0 then CFrame.new() else CFrame.Angles(0, math.pi, 0)
	local pivot = frame * CFrame.new(hingeU, 0, -front) * spin
	local turn = (if hinge < 0 then 1 else -1) * OPEN_ANGLE
	local panel = PropKit.leaf(model, "Panel", pivot)
	attach(base, "PanelOpen", pivot * CFrame.Angles(0, turn, 0))
	local centreLocal = Vector3.new((pL + pR) / 2, (pD + pU) / 2, (back + front) / 2)
	local centre = frame * CFrame.new(centreLocal.X, centreLocal.Y, -centreLocal.Z)
	attach(base, "PanelCentre", centre)

	box(b, panel, "StileLeft", pL, -HALF_BORE, pD, pU, back, front, key, metal)
	box(b, panel, "StileRight", HALF_BORE, pR, pD, pU, back, front, key, metal)
	box(b, panel, "RailTop", -HALF_BORE, HALF_BORE, HALF_BORE, pU, back, front, key, metal)
	box(b, panel, "RailBottom", -HALF_BORE, HALF_BORE, pD, -HALF_BORE, back, front, key, metal)
	local pitch = 2 * HALF_BORE / LOUVRES
	local louvreOptions: Geometry.PartOptions = { color = metal.color }
	for i = 1, LOUVRES do
		local y = -HALF_BORE + pitch * (i - 0.5)
		Geometry.part(
			panel,
			"Louvre" .. i,
			frame * CFrame.new(0, y, -(back + front) / 2) * CFrame.Angles(-LOUVRE_TILT, 0, 0),
			Vector3.new(2 * HALF_BORE, LOUVRE_THICKNESS, LOUVRE_CHORD),
			key,
			louvreOptions
		)
	end

	-- Hinge knuckles on the pin: the upper one on the panel, the lower one on the frame side
	local hardware = if locked then RUST_SCREW_KEY else SCREW_KEY
	local hingeOptions: Geometry.PartOptions = { castShadow = false }
	local upper = rod(
		b,
		panel,
		"Knuckle",
		Vector3.new(hingeU, pU - 0.25 - KNUCKLE_LENGTH, front),
		Vector3.new(hingeU, pU - 0.25, front),
		KNUCKLE_DIAMETER,
		hardware,
		hingeOptions
	)
	local lower = rod(
		b,
		model,
		"KnuckleFrame",
		Vector3.new(hingeU, pD + 0.25, front),
		Vector3.new(hingeU, pD + 0.25 + KNUCKLE_LENGTH, front),
		KNUCKLE_DIAMETER,
		hardware,
		hingeOptions
	)
	for _, part in { upper, lower } do
		if part then
			PropKit.detail(part)
		end
	end

	-- Rusted shut: weld beads along the latch and head seams, a rust streak bled down from the top hinge-side screw
	if locked then
		local latchU = if hinge < 0 then pR - 0.05 else pL + 0.05
		local screwY0, screwY1 = -(HALF_BORE + bd.down / 2), HALF_BORE + bd.up / 2
		local beads = {
			rod(
				b,
				panel,
				"WeldLatch",
				Vector3.new(latchU, screwY0 + 0.14, front + 0.01),
				Vector3.new(latchU, screwY1 - 0.14, front + 0.01),
				BEAD_DIAMETER,
				RUST_SCREW_KEY,
				hingeOptions
			),
			rod(
				b,
				panel,
				"WeldHead",
				Vector3.new(-(HALF_BORE + bd.left / 2) + 0.14, pU - 0.05, front + 0.01),
				Vector3.new(HALF_BORE + bd.right / 2 - 0.14, pU - 0.05, front + 0.01),
				BEAD_DIAMETER,
				RUST_SCREW_KEY,
				hingeOptions
			),
		}
		for _, bead in beads do
			if bead then
				PropKit.detail(bead)
			end
		end
		local streakU = if hinge < 0 then -(HALF_BORE + bd.left / 2) else HALF_BORE + bd.right / 2
		local streakTop = screwY1 - 0.09
		local streak = box(
			b,
			panel,
			"RustStreak",
			streakU - STREAK_WIDTH / 2,
			streakU + STREAK_WIDTH / 2,
			math.max(screwY0 + 0.12, streakTop - STREAK_LENGTH),
			streakTop,
			front,
			front + 0.006,
			RUST,
			{ color = STREAK_COLOR, material = Enum.Material.Slate, transparency = 0.2 }
		)
		PropKit.detail(streak)
	end

	-- Corner screws through the border into the frame
	local screwOptions: Geometry.PartOptions = { castShadow = false }
	local landU = plan.hinge * KICK_SHIFT * 0.5
	local index = 0
	for _, sy in { -1, 1 } do
		for _, sx in { -1, 1 } do
			index += 1
			local su = if sx < 0 then -(HALF_BORE + bd.left / 2) else HALF_BORE + bd.right / 2
			local sv = if sy < 0 then -(HALF_BORE + bd.down / 2) else HALF_BORE + bd.up / 2
			local screwName = "Screw" .. index
			local screw = PropKit.leaf(model, screwName, frame * CFrame.new(su, sv, -front))
			local part = rod(
				b,
				screw,
				"Screw",
				Vector3.new(su, sv, face + 0.01),
				Vector3.new(su, sv, front + SCREW_PROUD),
				SCREW_DIAMETER,
				hardware,
				screwOptions
			)
			if part then
				PropKit.detail(part)
			end
			-- where it comes to rest once out: on the floor below its corner (sunk to the basin floor over a pool)
			local restY = plan.rest + SCREW_DIAMETER / 2 + 0.005
			local spot = frame
				* Vector3.new(
					su * 0.7 + landU + random:NextNumber(-0.25, 0.25),
					0,
					-(face + 0.5 + random:NextNumber(0, 0.9))
				)
			local lying = CFrame.new(spot.X, origin.Y + restY, spot.Z)
				* CFrame.Angles(0, random:NextNumber(0, 2 * math.pi), 0)
				* CFrame.Angles(0, math.pi / 2, 0)
			attach(base, screwName .. "Out", lying)
		end
	end

	-- Where the kicked panel lands, as a pose of its pivot
	local landedCentre = landing(plan, hinge)
	local landedWorld = CFrame.new(origin) * landedCentre
	attach(base, "PanelKicked", landedWorld * centre:ToObjectSpace(pivot))

	-- Interaction point and the crawler's way in and out
	local promptPoint = attach(base, "PromptPoint", frame * CFrame.new(0, 0, -(front + PROMPT_OUT)))
	local exitPosition = frame * Vector3.new(0, 0, -(face + EXIT_OUT))
	exitPosition = Vector3.new(exitPosition.X, origin.Y + plan.floor, exitPosition.Z)
	attach(base, "ExitAnchor", CFrame.lookAt(exitPosition, exitPosition + frame.LookVector))
	local entryPosition = frame * Vector3.new(0, 0, -(face - ENTRY_IN))
	attach(base, "EntryAnchor", CFrame.lookAt(entryPosition, entryPosition - frame.LookVector))

	-- State, prompts
	local state: Enums.GrateState = if locked then "Locked" else "Closed"
	PropKit.setAttributes(model, {
		[W.GrateId] = source:GetAttribute(W.GrateId),
		[W.GrateState] = state,
		[W.Lockable] = source:GetAttribute(W.Lockable),
		[W.CriticalPath] = source:GetAttribute(W.CriticalPath),
		[W.NodeId] = source:GetAttribute(W.NodeId),
		[W.FacingZoneId] = source:GetAttribute(W.FacingZoneId),
		[W.LevelId] = source:GetAttribute(W.LevelId),
	})
	model:AddTag(Tags.VentGrate)
	local objectKey = if locked then "Prompt.GrateLocked" else "Prompt.Grate"
	PropKit.prompt(promptPoint, {
		kind = "Unscrew",
		action = "Prompt.Unscrew",
		object = objectKey,
		hold = GameConfig.UnscrewSeconds,
	}, model)
	PropKit.prompt(promptPoint, {
		kind = "Kick",
		action = "Prompt.Kick",
		object = objectKey,
		hold = GameConfig.KickSeconds,
		key = Enum.KeyCode.R,
		gamepad = Enum.KeyCode.ButtonY,
	}, model)
	return model
end

-- Fixture "VentGrate": one grate per layout grate whose attachment the level has.
local function buildAll(ctx: PropKit.FixtureContext): number
	local layout = ctx.layout
	if not layout.vents or #layout.vents.grates == 0 then
		return 0
	end
	local levelRoot = ctx.levelRoot
	local vents = levelRoot and levelRoot:FindFirstChild(Names.Vents)
	local root = vents and vents:FindFirstChild(VentShaftBuilder.RootName)
	if not root then
		log.warn("%s: no %s; no grates built", layout.id, VentShaftBuilder.RootName)
		return 0
	end
	local locked = if ctx.plan then ctx.plan.lockedGrates else {}
	local built = 0
	for _, plan in VentGrateBuilder.plan(layout) do
		local id = plan.grate.id
		local source = root:FindFirstChild(VentShaftBuilder.GratePrefix .. id)
		if not (source and source:IsA("Attachment")) then
			log.warn("%s: grate %s has no %s%s attachment; skipped", layout.id, id, VentShaftBuilder.GratePrefix, id)
			continue
		end
		buildGrate(plan, source, ctx.parent, locked[id] == true, ctx.random)
		built += 1
	end
	return built
end

function VentGrateBuilder.register(registrar: PropKit.Registrar)
	registrar.fixture("VentGrate", buildAll)
end

return table.freeze(VentGrateBuilder)
