--!strict
-- Finishes: what the shell's rooms are finished in, over the bare slabs, walls and ceilings SchoolShellBuilder cuts.
--
--   * Floors. Glossy where the floor would be polished or wet (Reflectance on the floor part: waxed linoleum, glazed
--     tile, marble lab floors, varnished gym boards, damp basement concrete), and painted with SurfaceArt where the
--     floor has a pattern: black-and-white checker down every corridor and across the big halls (the floor part turns
--     into the pale squares, a SurfaceGui adds the dark ones, a little transparent so the gloss still shows through),
--     a subtle two-tone vinyl tile in the classrooms and labs, and court lines on the gymnasium boards.
--   * Ceilings. Every plaster ceiling is a drop ceiling: a grid of tile seams, and in the ruined rooms (seeded per
--     room) a few tiles gone (black holes into the plenum, never where a fixture hangs) and brown water stains.
--   * Wainscots. Two-tone walls in the rooms people walk through: a lower band (glazed tile down the corridors, the
--     colour of each wing; dark gloss paint in classrooms, wood panelling in offices, contrasting tile in restrooms,
--     locker rooms and labs) up to 3.2 studs, a chair rail on top of it and a rubber baseboard under painted bands. The
--     pieces are thin, non-colliding, never queried overlays on each wall face, cut back from every opening (door
--     casings and steel frames, grates and their frames, low windows, tower openings) and from the props that stand
--     against a wall (hideable lockers, the floodlight switch, terminals). SchoolShellBuilder works out the spans
--     (it owns the wall lines); this module plans their look and builds the pieces.
--   * Hazard plates. Yellow-and-black striped floor plates either side of every airlock fire door and the hallway gate.
-- Everything is deterministic (seeded by layout and room ids) and built once at boot with the shell.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

local Geometry = require(script.Parent.Geometry)
local Palette = require(script.Parent.Palette)
local SurfaceArt = require(script.Parent.SurfaceArt)

type Room = LayoutSchema.Room
type Axis = Geometry.Axis

export type Checker = { cell: number, color: Color3, transparency: number }

export type FloorStyle = {
	key: string?, -- palette key the floor part is recoloured to (the pale squares of a checker)
	reflectance: number,
	checker: Checker?,
	court: boolean?, -- basketball court lines
}

export type WainscotStyle = {
	band: string, -- palette key of the lower band
	rail: string, -- chair rail
	base: string?, -- baseboard (nil: the band runs to the floor, as tile does)
}

export type Interval = { u0: number, u1: number }

-- A world-space box a ceiling hole must stay clear of (a fixture), projected on the ceiling plane.
export type Keepout = { x0: number, x1: number, z0: number, z1: number }

local EPS = 1e-3

local Finishes = {}

-- Wainscot heights (level-local Y above the floor) and depths (out from the wall face).
Finishes.BaseTop = 0.45
Finishes.BandTop = 3.2
Finishes.RailTop = 3.45
Finishes.BaseDepth = 0.12
Finishes.BandDepth = 0.06
Finishes.RailDepth = 0.14
Finishes.MinSpan = 0.8 -- shorter leftovers between openings are left bare
-- Most dark squares one checker SurfaceGui may hold (the cell grows until it fits).
Finishes.MaxSquares = 256

-- Drop-ceiling tiles (studs): long side along the room's long axis.
Finishes.CeilingTile = Vector2.new(4, 2)

local DARK_SQUARE = Color3.fromRGB(22, 22, 24)
local VCT_SQUARE = Color3.fromRGB(92, 86, 68)
local COURT_LINE = Color3.fromRGB(196, 176, 112)
local HOLE = Color3.fromRGB(7, 7, 8)
local STAIN = Color3.fromRGB(96, 76, 42)
local STAIN_RING = Color3.fromRGB(62, 48, 28)

local GLOSS: { [string]: number } = {
	Linoleum = 0.1,
	TileWhite = 0.12,
	TileGreen = 0.12,
	TileBlue = 0.12,
	PoolTile = 0.12,
	Lab = 0.14,
	WoodGym = 0.09,
	WoodPanel = 0.06,
	MetalGalvanized = 0.05,
}

-- Layouts whose bare concrete floors are damp.
local DAMP: { [string]: boolean } = { Level0_Basement = true, Lobby = true, Level4_FloodedPool = true }

-- The glazed tile band of each wing's corridors.
local CORRIDOR_BAND: { [string]: string } = {
	Level1_Hallways = "WainscotOxblood",
	Level2_ScienceHall = "WainscotTeal",
	Level3_Gymnasium = "WainscotTan",
	Level4_FloodedPool = "WainscotBlue",
}

local DROP_CEILING_KINDS: { [string]: boolean } = {
	Corridor = true,
	Classroom = true,
	Lab = true,
	Office = true,
	Restroom = true,
	LockerRoom = true,
	Storage = true,
	Gym = true,
}

--------------------------------------------------------------------------------
-- Pure planning
--------------------------------------------------------------------------------

-- How the floor of `room` (palette `floorKey`) on `layoutId` is finished; nil for a bare floor.
function Finishes.floorStyle(layoutId: string, room: Room, floorKey: string): FloorStyle?
	local area = room.rect.w * room.rect.d
	local checkerable = floorKey == "Linoleum" or floorKey == "TileWhite"
	if checkerable and (room.kind == "Corridor" or (floorKey == "Linoleum" and area >= 1800)) then
		return {
			key = "CheckerLight",
			reflectance = 0.12,
			checker = { cell = 3, color = DARK_SQUARE, transparency = 0.1 },
		}
	end
	if floorKey == "Linoleum" and (room.kind == "Classroom" or room.kind == "Lab" or room.kind == "Office") then
		return {
			key = "ClassroomVCT",
			reflectance = 0.1,
			checker = { cell = 2.5, color = VCT_SQUARE, transparency = 0.45 },
		}
	end
	if floorKey == "WoodGym" then
		return { reflectance = GLOSS.WoodGym, court = room.kind == "Gym" and area >= 4000 }
	end
	local gloss = GLOSS[floorKey]
	if gloss then
		return { reflectance = gloss }
	end
	if DAMP[layoutId] and (floorKey == "Concrete" or floorKey == "ConcreteStained") then
		return { reflectance = 0.04 }
	end
	return nil
end

-- Odd column and row counts for a checker of roughly `cell` squares over w x d, grown until its dark squares fit
-- MaxSquares. Odd counts put a dark square in every corner, so the pattern survives either canvas axis flipping.
function Finishes.checkerCounts(w: number, d: number, cell: number): (number, number)
	local size = cell
	local function odd(span: number): number
		local n = math.max(1, math.floor(span / size + 0.5))
		if n % 2 == 0 then
			n += if span / size > n then 1 else -1
		end
		return math.max(1, n)
	end
	for _ = 1, 40 do
		local cols, rows = odd(w), odd(d)
		if math.ceil(cols * rows / 2) <= Finishes.MaxSquares then
			return cols, rows
		end
		size *= 1.08
	end
	return 1, 1
end

-- Whether the ceiling of `room` (palette `ceilingKey`) is a drop ceiling.
function Finishes.dropCeiling(room: Room, ceilingKey: string): boolean
	return ceilingKey == "PlasterSchool" and DROP_CEILING_KINDS[room.kind] == true
end

-- How ruined a room's ceiling is, 0..1 (the Lobby is kept up).
function Finishes.ruin(layoutId: string, roomId: string): number
	if layoutId == "Lobby" then
		return 0
	end
	return MathUtil.hash(layoutId .. ":" .. roomId .. ":ruin") / 4294967296
end

-- Grid counts of a drop ceiling w x d: tiles CeilingTile big, the long side along the long axis.
function Finishes.ceilingGrid(w: number, d: number): (number, number)
	local tile = Finishes.CeilingTile
	local alongX = w >= d
	local cw = if alongX then tile.X else tile.Y
	local cd = if alongX then tile.Y else tile.X
	return math.max(1, math.floor(w / cw + 0.5)), math.max(1, math.floor(d / cd + 0.5))
end

-- The wainscot of `room` (wall palette `wallKey`) on `layoutId`, or nil for bare walls.
function Finishes.wainscotStyle(layoutId: string, room: Room, wallKey: string): WainscotStyle?
	local kind = room.kind
	local corridorBand = CORRIDOR_BAND[layoutId] or "WainscotOxblood"
	if kind == "Corridor" then
		if wallKey == "Brick" or string.sub(wallKey, 1, 7) == "Plaster" then
			return { band = corridorBand, rail = "TileCap" }
		end
		return nil
	elseif kind == "Classroom" or kind == "Gym" or kind == "Storage" then
		if string.sub(wallKey, 1, 7) == "Plaster" then
			return { band = "WainscotPaint", rail = "Trim", base = "Baseboard" }
		elseif wallKey == "Brick" and kind == "Classroom" then
			return { band = corridorBand, rail = "TileCap" } -- the cafeteria
		end
		return nil
	elseif kind == "Office" then
		if string.sub(wallKey, 1, 7) == "Plaster" then
			return { band = "WainscotWood", rail = "Trim", base = "Baseboard" }
		end
		return nil
	elseif kind == "Lab" then
		if wallKey == "TileWhite" then
			return { band = "WainscotGreen", rail = "TileCap" }
		elseif wallKey == "TileGreen" or string.sub(wallKey, 1, 7) == "Plaster" then
			return { band = "WainscotTeal", rail = "TileCap" }
		end
		return nil
	elseif kind == "Restroom" or kind == "LockerRoom" then
		if wallKey == "TileWhite" then
			return { band = if kind == "Restroom" then "WainscotGreen" else "WainscotBlue", rail = "TileCap" }
		elseif wallKey == "TileBlue" then
			return { band = "WainscotBlue", rail = "TileCap" }
		end
		return nil
	end
	return nil
end

-- [lo, hi] minus every cut, as sorted disjoint intervals no shorter than MinSpan.
function Finishes.subtract(lo: number, hi: number, cuts: { Interval }): { Interval }
	local pieces: { Interval } = { { u0 = lo, u1 = hi } }
	for _, cut in cuts do
		local nextPieces: { Interval } = {}
		for _, piece in pieces do
			if cut.u1 <= piece.u0 + EPS or cut.u0 >= piece.u1 - EPS then
				table.insert(nextPieces, piece)
				continue
			end
			if cut.u0 - piece.u0 > EPS then
				table.insert(nextPieces, { u0 = piece.u0, u1 = cut.u0 })
			end
			if piece.u1 - cut.u1 > EPS then
				table.insert(nextPieces, { u0 = cut.u1, u1 = piece.u1 })
			end
		end
		pieces = nextPieces
	end
	local out: { Interval } = {}
	for _, piece in pieces do
		if piece.u1 - piece.u0 >= Finishes.MinSpan then
			table.insert(out, piece)
		end
	end
	table.sort(out, function(a: Interval, b: Interval): boolean
		return a.u0 < b.u0
	end)
	return out
end

--------------------------------------------------------------------------------
-- Floors
--------------------------------------------------------------------------------

-- Court lines over a gym floor part (centred, so either canvas flip draws the same court).
local function paintCourt(gui: SurfaceGui, size: Vector3, pps: number): number
	local w, d = size.X, size.Z
	local long, wide = math.min(w - 14, 84), math.min(d - 14, 46)
	if long < 30 or wide < 20 then
		return 0
	end
	local line = math.max(1, math.floor(pps * 0.22 + 0.5))
	local function box(name: string, cx: number, cz: number, bw: number, bd: number, round: boolean?)
		SurfaceArt.outline(
			gui,
			name,
			(cx - bw / 2) / w,
			(cz - bd / 2) / d,
			bw / w,
			bd / d,
			COURT_LINE,
			line,
			0.35,
			round
		)
	end
	local cx, cz = w / 2, d / 2
	box("Boundary", cx, cz, long, wide)
	local half = SurfaceArt.frame(gui, "HalfCourt", 0.5, (cz - wide / 2) / d, 0, wide / d, COURT_LINE, 0.35)
	half.Position = UDim2.new(0.5, -line / 2, (cz - wide / 2) / d, 0)
	half.Size = UDim2.new(0, line, wide / d, 0)
	box("CentreCircle", cx, cz, 12, 12, true)
	local keyLong, keyWide = 19, 12
	box("KeyWest", cx - long / 2 + keyLong / 2, cz, keyLong, keyWide)
	box("KeyEast", cx + long / 2 - keyLong / 2, cz, keyLong, keyWide)
	box("FreeThrowWest", cx - long / 2 + keyLong, cz, 12, 12, true)
	box("FreeThrowEast", cx + long / 2 - keyLong, cz, 12, 12, true)
	return 7
end

-- Finishes one floor piece of `room`. Returns the GuiObjects painted.
function Finishes.decorateFloor(part: BasePart, layoutId: string, room: Room, floorKey: string): number
	local style = Finishes.floorStyle(layoutId, room, floorKey)
	if not style then
		return 0
	end
	if style.key then
		Palette.apply(part, style.key)
	end
	part.Reflectance = style.reflectance
	local checker = style.checker
	if not (checker or style.court) then
		return 0
	end
	local gui, pps = SurfaceArt.gui(part, Enum.NormalId.Top, { name = "Finish", pixelsPerStud = 8, maxDistance = 170 })
	local painted = 0
	if checker then
		local cols, rows = Finishes.checkerCounts(part.Size.X, part.Size.Z, checker.cell)
		painted += SurfaceArt.checker(gui, cols, rows, checker.color, checker.transparency)
	end
	if style.court then
		painted += paintCourt(gui, part.Size, pps)
	end
	return painted
end

--------------------------------------------------------------------------------
-- Ceilings
--------------------------------------------------------------------------------

-- Cells (i, j) of a cols x rows grid over a part whose local X/Z span size that any keepout touches, under every
-- flip of the canvas axes (the engine's Bottom-face canvas orientation is not ours to assume).
local function blockedCells(part: BasePart, cols: number, rows: number, keepouts: { Keepout }): { [number]: boolean }
	local blocked: { [number]: boolean } = {}
	local size = part.Size
	local cw, cd = size.X / cols, size.Z / rows
	local function mark(i: number, j: number)
		for _, ii in { i, cols - 1 - i } do
			for _, jj in { j, rows - 1 - j } do
				blocked[jj * cols + ii] = true
			end
		end
	end
	for _, k in keepouts do
		local a = part.CFrame:PointToObjectSpace(Vector3.new(k.x0, part.CFrame.Position.Y, k.z0))
		local b = part.CFrame:PointToObjectSpace(Vector3.new(k.x1, part.CFrame.Position.Y, k.z1))
		local lx0, lx1 = math.min(a.X, b.X) + size.X / 2, math.max(a.X, b.X) + size.X / 2
		local lz0, lz1 = math.min(a.Z, b.Z) + size.Z / 2, math.max(a.Z, b.Z) + size.Z / 2
		local i0 = math.clamp(math.floor(lx0 / cw), 0, cols - 1)
		local i1 = math.clamp(math.floor(lx1 / cw), 0, cols - 1)
		local j0 = math.clamp(math.floor(lz0 / cd), 0, rows - 1)
		local j1 = math.clamp(math.floor(lz1 / cd), 0, rows - 1)
		for i = i0, i1 do
			for j = j0, j1 do
				mark(i, j)
			end
		end
	end
	return blocked
end

-- Finishes the ceiling panel of `room` (palette `ceilingKey`): drop-ceiling seams, and in a ruined room missing
-- tiles (clear of `keepouts`, the fixtures hanging from it) and water stains. Returns the GuiObjects painted.
function Finishes.decorateCeiling(
	part: BasePart,
	layoutId: string,
	room: Room,
	ceilingKey: string,
	keepouts: { Keepout }
): number
	if not Finishes.dropCeiling(room, ceilingKey) then
		return 0
	end
	local size = part.Size
	local cols, rows = Finishes.ceilingGrid(size.X, size.Z)
	local gui, pps =
		SurfaceArt.gui(part, Enum.NormalId.Bottom, { name = "Finish", pixelsPerStud = 8, maxDistance = 150 })
	local base = part.Color
	local seam = Color3.new(base.R * 0.58, base.G * 0.58, base.B * 0.56)
	local thickness = math.max(1, math.floor(pps * 0.14 + 0.5))
	local painted = SurfaceArt.grid(gui, cols, rows, seam, 0.2, thickness)

	local ruin = Finishes.ruin(layoutId, room.id)
	local random = MathUtil.seededRandom(1, layoutId .. ":" .. room.id .. ":ceiling")
	local missing = if ruin < 0.3 then 0 else math.floor(1 + (ruin - 0.3) / 0.7 * 7)
	if missing > 0 then
		local blocked = blockedCells(part, cols, rows, keepouts)
		local tries = 0
		while missing > 0 and tries < 60 do
			tries += 1
			local i, j = random:NextInteger(0, cols - 1), random:NextInteger(0, rows - 1)
			if blocked[j * cols + i] then
				continue
			end
			blocked[j * cols + i] = true
			local hole = SurfaceArt.frame(gui, "MissingTile", i / cols, j / rows, 1 / cols, 1 / rows, HOLE, 0, 2)
			hole.Position = UDim2.new(i / cols, thickness, j / rows, thickness)
			hole.Size = UDim2.new(1 / cols, -thickness * 2, 1 / rows, -thickness * 2)
			painted += 1
			missing -= 1
		end
	end
	local stains = 1 + math.floor(ruin * 3.5)
	for _ = 1, stains do
		local sw = random:NextNumber(2.5, 6.5)
		local sd = sw * random:NextNumber(0.6, 1.1)
		SurfaceArt.stain(
			gui,
			random:NextNumber(0.1, 0.9),
			random:NextNumber(0.1, 0.9),
			sw / size.X,
			sd / size.Z,
			STAIN,
			random:NextNumber(0.62, 0.8),
			STAIN_RING,
			1
		)
		painted += 1
	end
	return painted
end

--------------------------------------------------------------------------------
-- Wainscot pieces
--------------------------------------------------------------------------------

local OVERLAY: Geometry.PartOptions = { canCollide = false, canQuery = false, castShadow = false }

local function overlay(
	parent: Instance,
	name: string,
	origin: Vector3,
	axis: Axis,
	coord: number,
	u0: number,
	u1: number,
	y0: number,
	y1: number,
	face: number,
	dir: number,
	depth: number,
	key: string
): boolean
	if u1 - u0 < EPS then
		return false
	end
	local part = Geometry.wallBox(
		parent,
		name,
		origin,
		axis,
		coord,
		u0,
		u1,
		y0,
		y1,
		math.min(face, face + dir * depth),
		math.max(face, face + dir * depth),
		key,
		OVERLAY
	)
	if not part then
		return false
	end
	Geometry.makeCosmetic(part)
	return true
end

-- The pieces of one wainscot span along the wall line (axis, coord) between u0 and u1, on the face `face` (signed
-- across offset of the wall face) that looks along `dir` (+1 / -1) into the room. Ends flagged `insetLo` / `insetHi`
-- meet an inner corner: there each piece stops at the depth of its twin on the perpendicular wall, so corners neither
-- overlap nor z-fight. Returns the parts built.
function Finishes.wainscot(
	parent: Instance,
	name: string,
	origin: Vector3,
	axis: Axis,
	coord: number,
	face: number,
	dir: number,
	u0: number,
	u1: number,
	style: WainscotStyle,
	insetLo: boolean,
	insetHi: boolean
): number
	local count = 0
	local function piece(suffix: string, y0: number, y1: number, depth: number, key: string)
		local a = if insetLo then u0 + depth else u0
		local b = if insetHi then u1 - depth else u1
		if overlay(parent, name .. suffix, origin, axis, coord, a, b, y0, y1, face, dir, depth, key) then
			count += 1
		end
	end
	local bandBottom = 0
	if style.base then
		piece("_Base", 0, Finishes.BaseTop, Finishes.BaseDepth, style.base)
		bandBottom = Finishes.BaseTop
	end
	piece("_Band", bandBottom, Finishes.BandTop, Finishes.BandDepth, style.band)
	piece("_Rail", Finishes.BandTop, Finishes.RailTop, Finishes.RailDepth, style.rail)
	return count
end

--------------------------------------------------------------------------------
-- Hazard plates
--------------------------------------------------------------------------------

Finishes.HazardThickness = 0.015

-- A striped plate on the floor, wall-local [u0, u1] x [a0, a1] (across offsets from the wall line) at floor level.
function Finishes.hazardPlate(
	parent: Instance,
	name: string,
	origin: Vector3,
	axis: Axis,
	coord: number,
	u0: number,
	u1: number,
	a0: number,
	a1: number
): BasePart?
	local part = Geometry.wallBox(
		parent,
		name,
		origin,
		axis,
		coord,
		u0,
		u1,
		0,
		Finishes.HazardThickness,
		math.min(a0, a1),
		math.max(a0, a1),
		"HazardYellow",
		OVERLAY
	)
	if not part then
		return nil
	end
	Geometry.makeCosmetic(part)
	local gui, pps = SurfaceArt.gui(part, Enum.NormalId.Top, { name = "Stripes", pixelsPerStud = 14, maxDistance = 90 })
	SurfaceArt.hazard(gui, SurfaceArt.faceStuds(part.Size, Enum.NormalId.Top), pps, 0.4, 0.5)
	return part
end

return table.freeze(Finishes)
