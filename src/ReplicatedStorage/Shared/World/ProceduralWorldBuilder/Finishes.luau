--!strict
-- Finishes: what the shell's rooms are finished in, over the bare slabs, walls and ceilings SchoolShellBuilder cuts.
--
--   * Floors. Glossy where the floor would be polished or wet (Reflectance on the floor part: waxed linoleum, glazed
--     tile, marble lab floors, varnished gym boards, damp basement concrete), and painted with SurfaceArt where the
--     floor has a pattern: black-and-white checker down every corridor and across the big halls (the floor part turns
--     into the pale squares, a SurfaceGui adds the dark ones, a little transparent so the gloss still shows through),
--     a subtle two-tone vinyl tile in the classrooms and labs, and court lines on the gymnasium boards.
--   * Ceilings. Every plaster ceiling is a drop ceiling: a grid of tile seams, and in the ruined rooms (seeded per
--     room) a few tiles gone (black holes into the plenum, never where a fixture hangs) and brown water stains. The
--     first one or two holes of a room are real plates (planCeiling says where), so DecayBuilder can drop their tiles
--     on the floor below and hang wiring out of them.
--   * Wainscots. Two-tone walls in the rooms people walk through: a lower band (glazed tile down the corridors, the
--     colour of each wing; dark gloss paint in classrooms, wood panelling in offices, contrasting tile in restrooms,
--     locker rooms and labs) up to 3.2 studs, a chair rail on top of it and a rubber baseboard under painted bands. The
--     pieces are thin, non-colliding, never queried overlays on each wall face, cut back from every opening (door
--     casings and steel frames, grates and their frames, low windows, tower openings) and from the props that stand
--     against a wall (hideable lockers, the floodlight switch, terminals). SchoolShellBuilder works out the spans
--     (it owns the wall lines); this module plans their look and builds the pieces.
--   * Hazard plates. Yellow-and-black striped floor plates either side of every airlock fire door and the hallway gate.
--   * Wear. Every wall face a room sees carries the dirt of years (one low-resolution SurfaceGui per face): grime
--     gathered along the foot (on the wainscot band where there is one), soot under the ceiling, dirt in the inside
--     corners, brown water runs down from the ceiling and the odd crack. The chair rail and tile cap are bevelled
--     (a wedge whose slope faces the room), so the wainscot reads as moulding rather than a stack of boxes.
--   * Textures. Where Palette.variantFor gives a surface's key a generated MaterialVariant, the part wears it (Geometry
--     applies it); a textured checker or vinyl floor and a textured drop ceiling drop the painted squares and seams
--     their texture already shows. With no textures the look is the painted one.
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

-- One drop-ceiling plan: the grid, the missing tiles (grid cells; the first `dressed` are built as plates) and the
-- water stains (canvas Scale centre and stud size).
export type Cell = { i: number, j: number }
export type Stain = { x: number, y: number, w: number, d: number, transparency: number }
export type CeilingPlan = { cols: number, rows: number, holes: { Cell }, dressed: number, stains: { Stain } }

-- One wall face to weather (SchoolShellBuilder finds them; level-local heights).
export type WallFace = {
	part: BasePart,
	face: Enum.NormalId,
	layoutId: string,
	room: Room,
	y0: number, -- the box's bottom and top
	y1: number,
	ceiling: number, -- the room's ceiling underside (or its wall top where it is open to the sky)
	wainscot: boolean, -- a wainscot band covers the foot of this face
	cornerLo: number?, -- the face's low-u end meets an inside corner of the room this many studs in from its edge
	cornerHi: number?,
}

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

local GRIME = Color3.fromRGB(30, 26, 19)
local SOOT = Color3.fromRGB(16, 15, 13)
local RUN = Color3.fromRGB(62, 48, 28)
local CRACK = Color3.fromRGB(22, 20, 17)

Finishes.WearPixelsPerStud = 6
Finishes.WearDistance = 60
Finishes.GrimeHeight = 2.6 -- studs of dirt up a wall's foot
Finishes.SootDepth = 2.2 -- studs of soot down from the ceiling
Finishes.CornerWidth = 1.6

-- Room kinds that are weathered harder (service spaces) or not at all (shafts nobody sees).
local WEAR_STRENGTH: { [string]: number } = {
	Boiler = 0.78,
	Storage = 0.7,
	Chase = 0,
	Restroom = 0.66,
	LockerRoom = 0.64,
	Pool = 0.6,
	Airlock = 0.62,
	Stairwell = 0.62,
	Roof = 0.5,
}

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
		Geometry.applyKey(part, style.key)
	end
	part.Reflectance = style.reflectance
	local checker = style.checker
	if checker and Palette.variantFor(style.key or floorKey) then
		checker = nil -- the tile texture is the pattern
	end
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
type Probe = { CFrame: CFrame, Size: Vector3 }

local function blockedCells(part: Probe, cols: number, rows: number, keepouts: { Keepout }): { [number]: boolean }
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

-- Where the tiles of the drop ceiling `size` big at `cframe` over `room` are missing (clear of `keepouts`, the fixtures
-- hanging from it) and where it is stained. Pure and seeded per room, so SchoolShellBuilder.ceilingFalls() can find
-- the dressed holes again without building anything.
function Finishes.planCeiling(
	layoutId: string,
	room: Room,
	cframe: CFrame,
	size: Vector3,
	keepouts: { Keepout }
): CeilingPlan
	local cols, rows = Finishes.ceilingGrid(size.X, size.Z)
	local ruin = Finishes.ruin(layoutId, room.id)
	local random = MathUtil.seededRandom(1, layoutId .. ":" .. room.id .. ":ceiling")
	local missing = if ruin < 0.3 then 0 else math.floor(1 + (ruin - 0.3) / 0.7 * 7)
	local holes: { Cell } = {}
	if missing > 0 then
		local blocked = blockedCells({ CFrame = cframe, Size = size }, cols, rows, keepouts)
		local tries = 0
		while missing > 0 and tries < 60 do
			tries += 1
			local i, j = random:NextInteger(0, cols - 1), random:NextInteger(0, rows - 1)
			if blocked[j * cols + i] then
				continue
			end
			blocked[j * cols + i] = true
			table.insert(holes, { i = i, j = j })
			missing -= 1
		end
	end
	local stains: { Stain } = {}
	for _ = 1, 1 + math.floor(ruin * 3.5) do
		local sw = random:NextNumber(2.5, 6.5)
		local sd = sw * random:NextNumber(0.6, 1.1)
		table.insert(stains, {
			x = random:NextNumber(0.1, 0.9),
			y = random:NextNumber(0.1, 0.9),
			w = sw,
			d = sd,
			transparency = random:NextNumber(0.62, 0.8),
		})
	end
	local dressed = if #holes >= 5 then 2 elseif #holes >= 1 then 1 else 0
	return { cols = cols, rows = rows, holes = holes, dressed = dressed, stains = stains }
end

-- World centre of the underside of grid cell `cell` of a ceiling `size` big at `cframe` (local X / Z are the grid's
-- columns / rows, the same axes blockedCells measures).
function Finishes.cellCentre(cframe: CFrame, size: Vector3, plan: CeilingPlan, cell: Cell): Vector3
	local cw, cd = size.X / plan.cols, size.Z / plan.rows
	local lx = -size.X / 2 + (cell.i + 0.5) * cw
	local lz = -size.Z / 2 + (cell.j + 0.5) * cd
	return cframe:PointToWorldSpace(Vector3.new(lx, -size.Y / 2, lz))
end

-- Finishes the ceiling panel of `room` (palette `ceilingKey`): drop-ceiling seams, and in a ruined room missing
-- tiles (clear of `keepouts`, the fixtures hanging from it) and water stains. The dressed holes are thin void plates
-- under the panel (into its parent); the rest are painted. Returns the GuiObjects painted.
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
	Geometry.applyKey(part, "CeilingTile")
	local size = part.Size
	local plan = Finishes.planCeiling(layoutId, room, part.CFrame, size, keepouts)
	local cols, rows = plan.cols, plan.rows
	local gui, pps =
		SurfaceArt.gui(part, Enum.NormalId.Bottom, { name = "Finish", pixelsPerStud = 8, maxDistance = 150 })
	local base = part.Color
	local seam = Color3.new(base.R * 0.58, base.G * 0.58, base.B * 0.56)
	local thickness = math.max(1, math.floor(pps * 0.14 + 0.5))
	local painted = 0
	if not Palette.variantFor("CeilingTile") then
		painted += SurfaceArt.grid(gui, cols, rows, seam, 0.2, thickness)
	end

	local parent = part.Parent or part
	local cw, cd = size.X / cols, size.Z / rows
	for index, cell in plan.holes do
		if index <= plan.dressed then
			local centre = Finishes.cellCentre(part.CFrame, size, plan, cell)
			local plate = Geometry.part(
				parent,
				string.format("MissingTile_%s_%d", room.id, index),
				CFrame.new(centre - Vector3.new(0, 0.02, 0)),
				Vector3.new(cw - 0.1, 0.03, cd - 0.1),
				"CeilingVoid",
				{ castShadow = false }
			)
			Geometry.makeCosmetic(plate)
			continue
		end
		local i, j = cell.i, cell.j
		local hole = SurfaceArt.frame(gui, "MissingTile", i / cols, j / rows, 1 / cols, 1 / rows, HOLE, 0, 2)
		hole.Position = UDim2.new(i / cols, thickness, j / rows, thickness)
		hole.Size = UDim2.new(1 / cols, -thickness * 2, 1 / rows, -thickness * 2)
		painted += 1
	end
	for _, stain in plan.stains do
		SurfaceArt.stain(
			gui,
			stain.x,
			stain.y,
			stain.w / size.X,
			stain.d / size.Z,
			STAIN,
			stain.transparency,
			STAIN_RING,
			1
		)
		painted += 1
	end
	return painted
end

--------------------------------------------------------------------------------
-- Wear
--------------------------------------------------------------------------------

-- Whether `face` of an axis-aligned part draws its canvas with world +u (the wall's along axis: +X on Front / Back,
-- +Z on Left / Right) running toward canvas right. Seen from outside a face, the canvas's right is the viewer's right.
function Finishes.uRunsRight(face: Enum.NormalId): boolean
	return face == Enum.NormalId.Back or face == Enum.NormalId.Left
end

-- Weathers one wall face: grime at the foot (left to the wainscot band where there is one), soot under the ceiling,
-- dirt in its inside corners, water runs and the odd crack. Seeded by the part and face. Returns the GuiObjects made.
function Finishes.decorateWall(spec: WallFace): number
	local strength = WEAR_STRENGTH[spec.room.kind] or 0.56
	if strength <= 0 then
		return 0
	end
	local part = spec.part
	local studs = SurfaceArt.faceStuds(part.Size, spec.face)
	if studs.X < 1.2 or studs.Y < 1 then
		return 0
	end
	local onFloor = spec.y0 < 0.05
	local foot = onFloor and not spec.wainscot
	local topGap = spec.y1 - spec.ceiling
	local underCeiling = topGap > -0.2 and topGap < studs.Y - 1
	local cornerLo = if onFloor then spec.cornerLo else nil
	local cornerHi = if onFloor then spec.cornerHi else nil
	local ruin = Finishes.ruin(spec.layoutId, spec.room.id)
	local random = MathUtil.seededRandom(1, spec.layoutId .. ":" .. part.Name .. ":" .. spec.face.Name)
	local runs = if underCeiling and studs.X >= 2 then random:NextInteger(0, if ruin > 0.5 then 2 else 1) else 0
	local cracked = random:NextNumber() < 0.18 + ruin * 0.3 and studs.Y >= 3 and studs.X >= 2
	if not (foot or underCeiling or cornerLo or cornerHi or runs > 0 or cracked) then
		return 0
	end
	local gui, pps = SurfaceArt.gui(
		part,
		spec.face,
		{ name = "Wear", pixelsPerStud = Finishes.WearPixelsPerStud, maxDistance = Finishes.WearDistance }
	)
	local made = 0
	local top = math.max(0, topGap) * pps
	if foot then
		SurfaceArt.edgeBand(gui, "Grime", false, 0, Finishes.GrimeHeight * pps, GRIME, strength, 1)
		made += 1
	end
	if underCeiling then
		SurfaceArt.edgeBand(gui, "Soot", true, top, Finishes.SootDepth * pps, SOOT, strength * 0.7, 1)
		made += 1
	end
	local right = Finishes.uRunsRight(spec.face)
	if cornerLo then
		local inset = cornerLo * pps
		SurfaceArt.sideBand(gui, "Corner", not right, inset, Finishes.CornerWidth * pps, GRIME, strength * 0.75, 1)
		made += 1
	end
	if cornerHi then
		local inset = cornerHi * pps
		SurfaceArt.sideBand(gui, "Corner", right, inset, Finishes.CornerWidth * pps, GRIME, strength * 0.75, 1)
		made += 1
	end
	for _ = 1, runs do
		local length = math.min(random:NextNumber(3, 9), spec.ceiling - spec.y0)
		SurfaceArt.streak(
			gui,
			random:NextNumber(0.08, 0.92),
			top,
			random:NextNumber(0.25, 0.7) * pps,
			length * pps,
			RUN,
			random:NextNumber(0.3, 0.55),
			2
		)
		made += 1
	end
	if cracked then
		made += SurfaceArt.crack(
			gui,
			random,
			random:NextNumber(0.15, 0.85),
			random:NextNumber(0.15, 0.5),
			random:NextNumber(-60, 60),
			random:NextInteger(2, 4),
			random:NextNumber(0.6, 1.2) * pps,
			1,
			CRACK,
			3
		)
	end
	return made
end

-- Grime gathered along the foot of a wainscot band (and a water run reaching down onto it now and then).
local function weatherBand(part: BasePart, face: Enum.NormalId, seed: string)
	local studs = SurfaceArt.faceStuds(part.Size, face)
	if studs.X < 1 then
		return
	end
	local gui, pps = SurfaceArt.gui(
		part,
		face,
		{ name = "Wear", pixelsPerStud = Finishes.WearPixelsPerStud, maxDistance = Finishes.WearDistance }
	)
	local random = MathUtil.seededRandom(1, seed)
	SurfaceArt.edgeBand(gui, "Grime", false, 0, math.min(studs.Y, 1.6) * pps, GRIME, random:NextNumber(0.5, 0.68), 1)
	if studs.X >= 3 and random:NextNumber() < 0.3 then
		SurfaceArt.streak(
			gui,
			random:NextNumber(0.1, 0.9),
			0,
			random:NextNumber(0.25, 0.6) * pps,
			studs.Y * random:NextNumber(0.4, 0.9) * pps,
			RUN,
			random:NextNumber(0.25, 0.45),
			2
		)
	end
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
): Part?
	if u1 - u0 < EPS then
		return nil
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
		return nil
	end
	Geometry.makeCosmetic(part)
	return part
end

-- A bevelled moulding along the wall: a wedge whose slope faces the room and rises to the wall, full `depth` at its
-- underside (the ledge that throws a shadow line) and flush with the wall at its top. Its bounds are the same box a
-- plain overlay would fill.
local function bevel(
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
): WedgePart?
	if u1 - u0 < EPS or y1 - y0 < EPS then
		return nil
	end
	local centre = Geometry.wallPoint(origin, axis, coord, (u0 + u1) / 2, (y0 + y1) / 2, face + dir * depth / 2)
	local normal = if axis == "X" then Vector3.new(dir, 0, 0) else Vector3.new(0, 0, dir)
	local part = Geometry.wedge(
		parent,
		name,
		CFrame.lookAt(centre, centre + normal),
		Vector3.new(u1 - u0, y1 - y0, depth),
		key,
		OVERLAY
	)
	Geometry.makeCosmetic(part)
	return part
end

-- The face of a wall overlay that looks along `dir` into the room.
local function roomFace(axis: Axis, dir: number): Enum.NormalId
	if axis == "X" then
		return if dir > 0 then Enum.NormalId.Right else Enum.NormalId.Left
	end
	return if dir > 0 then Enum.NormalId.Back else Enum.NormalId.Front
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
	local function piece(suffix: string, y0: number, y1: number, depth: number, key: string): BasePart?
		local a = if insetLo then u0 + depth else u0
		local b = if insetHi then u1 - depth else u1
		local part: BasePart? = if suffix == "_Rail"
			then bevel(parent, name .. suffix, origin, axis, coord, a, b, y0, y1, face, dir, depth, key)
			else overlay(parent, name .. suffix, origin, axis, coord, a, b, y0, y1, face, dir, depth, key)
		if part then
			count += 1
		end
		return part
	end
	local bandBottom = 0
	if style.base then
		piece("_Base", 0, Finishes.BaseTop, Finishes.BaseDepth, style.base)
		bandBottom = Finishes.BaseTop
	end
	local band = piece("_Band", bandBottom, Finishes.BandTop, Finishes.BandDepth, style.band)
	if band then
		weatherBand(band, roomFace(axis, dir), name)
	end
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
