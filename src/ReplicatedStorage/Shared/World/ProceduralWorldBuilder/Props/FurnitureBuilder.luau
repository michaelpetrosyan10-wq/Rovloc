--!strict
-- FurnitureBuilder: what the school's rooms were furnished with (static kind "Furniture": once at boot, the same on every
-- server, into <level>.Props as one Model "Furniture_<layoutId>").
--
--   * Classrooms: a chalkboard on the front wall (slate in an aluminium frame, a chalk tray, half-erased lessons and now
--     and then a warning chalked over them), the teacher's desk before it and rows of pupils' desks and chairs facing
--     it, left the way the school was left: some straight, some shoved aside, some tipped over, some gone.
--   * Halls (libraries, the music room, the cafeteria, lecture halls): long tables with chairs, the same way.
--   * Labs: a chalkboard. Offices: a desk, its chair and a steel filing cabinet against a wall.
--   * Corridors: a cork noticeboard with papers pinned to it.
-- Desk tops, table tops and chair seats are "Solid" (players bump into them, the Creature walks through); legs, frames
-- and boards are "Detail". Every group is planned before anything is built and only built where SetDressingBuilder.Kit
-- lets dressing go (clear of doorways and their swings, grate fronts, landings, spawns, lockers and every dressing
-- spot), inside a perimeter aisle and with aisles between the desk columns, so every doorway stays connected to every
-- other. Wall pieces go where WallPlanner says the wall is free; plan(layout).mounts tells SignageBuilder where they are.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Strings = require(ReplicatedStorage.Shared.Strings)

local Finishes = require(script.Parent.Parent.Finishes)
local PropKit = require(script.Parent.PropKit)
local SchoolShellBuilder = require(script.Parent.Parent.SchoolShellBuilder)
local SetDressingBuilder = require(script.Parent.SetDressingBuilder)
local SurfaceArt = require(script.Parent.Parent.SurfaceArt)
local WallPlanner = require(script.Parent.WallPlanner)

type Layout = LayoutSchema.LevelLayout
type Room = LayoutSchema.Room
type Piece = SetDressingBuilder.Piece
type Box = SetDressingBuilder.Box
type LevelInfo = SetDressingBuilder.LevelInfo
type Wall = WallPlanner.Wall
type Mount = WallPlanner.Mount

local Kit = SetDressingBuilder.Kit
local W = Attributes.World

export type Plan = {
	pieces: { Piece },
	painters: { [number]: (part: BasePart) -> () }, -- by piece index
	mounts: { Mount }, -- wall pieces (boards, noticeboards, cabinets)
	footprints: { Box }, -- level-local boxes of every group built
}

type State = {
	layout: Layout,
	info: LevelInfo,
	plan: Plan,
	used: { [string]: number }, -- parts planned per room
}

local FurnitureBuilder = {}

-- Part caps per room (the spec holds every room to these).
FurnitureBuilder.Budget = table.freeze({ Classroom = 58, Hall = 64, Office = 12, Lab = 3, Corridor = 2 })

local HALL_AREA = 1400 -- classrooms this big are halls: tables, not rows of desks
local AISLE = 3.4 -- between desk columns
local PERIMETER = 3 -- clear walkway along the side walls
local FRONT_CLEAR = 8.6 -- the teacher's end of a classroom
local BACK_CLEAR = 3.2
local ROW_PITCH = 5.2
local MAX_COLUMNS = 4
local MAX_ROWS = 3
local MAX_TABLES = 6

local BOARD_WIDTH = 10
local BOARD_HEIGHT = 3.4
local BOARD_BOTTOM = Finishes.RailTop + 0.35
local NOTICE_SIZE = Vector2.new(5.4, 3.1)
local NOTICE_BOTTOM = 4.2
local CABINET = Vector3.new(1.7, 4.3, 2)

local CHALK = Color3.fromRGB(214, 218, 206)
local INK = Color3.fromRGB(58, 62, 78)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function ry(degrees: number): CFrame
	return CFrame.Angles(0, math.rad(degrees), 0)
end

local function between(random: Random, a: number, b: number): number
	return random:NextNumber(a, b)
end

local function tint(color: Color3, random: Random, amount: number): Color3
	local f = 1 + between(random, -amount, amount)
	return Color3.new(math.clamp(color.R * f, 0, 1), math.clamp(color.G * f, 0, 1), math.clamp(color.B * f, 0, 1))
end

-- Lifts (or drops) `pieces` rigidly so the lowest of them rests on world height `floorY`.
local function settle(pieces: { Piece }, floorY: number)
	local lowest = math.huge
	for _, piece in pieces do
		local lo = Kit.bounds(piece)
		lowest = math.min(lowest, lo.Y)
	end
	if lowest < math.huge then
		Kit.offset(pieces, Vector3.new(0, floorY + 0.005 - lowest, 0))
	end
end

-- Turns `pieces` about `pivot`'s local axes (radians), then settles them back on the floor.
local function overturn(pieces: { Piece }, pivot: CFrame, rotation: CFrame, floorY: number)
	Kit.transform(pieces, pivot * rotation * pivot:Inverse())
	settle(pieces, floorY)
end

local function append(list: { Piece }, more: { Piece })
	for _, piece in more do
		table.insert(list, piece)
	end
end

-- The cap of `room` (FurnitureBuilder.Budget by what the room is).
local function budgetOf(room: Room): number
	local budget = FurnitureBuilder.Budget
	if room.kind == "Classroom" then
		return if room.rect.w * room.rect.d >= HALL_AREA then budget.Hall else budget.Classroom
	elseif room.kind == "Lab" then
		return budget.Lab
	elseif room.kind == "Office" then
		return budget.Office
	elseif room.kind == "Corridor" then
		return budget.Corridor
	end
	return 0
end

-- Adds a planned group to `room`'s furniture, unless it would take the room past its budget. Returns whether it did.
local function addGroup(
	state: State,
	room: Room,
	pieces: { Piece },
	painters: { [Piece]: (part: BasePart) -> () }?
): boolean
	local used = state.used[room.id] or 0
	if used + #pieces > budgetOf(room) then
		return false
	end
	state.used[room.id] = used + #pieces
	local plan = state.plan
	for _, piece in pieces do
		table.insert(plan.pieces, piece)
		local painter = painters and painters[piece]
		if painter then
			plan.painters[#plan.pieces] = painter
		end
		table.insert(plan.footprints, Kit.localBox(state.info, piece))
	end
	return true
end

-- Whether a floor group fits its room (on the floor, clear of every zone and the walls by the perimeter margin).
local function fitsFloor(state: State, room: Room, pieces: { Piece }, margin: number?): boolean
	return Kit.fits(state.info, pieces, { room = room.id, ground = 0, margin = margin or 0.4 })
end

--------------------------------------------------------------------------------
-- Pieces (local frames: LookVector is the way a sitter faces, Y up, the floor at y 0)
--------------------------------------------------------------------------------

local function deskPieces(frame: CFrame, name: string, random: Random): { Piece }
	local top = { color = tint(Color3.fromRGB(112, 92, 66), random, 0.12) }
	return {
		Kit.box(
			frame,
			name .. "_Top",
			Vector3.new(-1.2, 2.35, -0.85),
			Vector3.new(1.2, 2.5, 0.85),
			"DeskTop",
			"Solid",
			top
		),
		Kit.box(
			frame,
			name .. "_LegL",
			Vector3.new(-1.14, 0, -0.75),
			Vector3.new(-1.04, 2.35, 0.75),
			"DeskSteel",
			"Detail"
		),
		Kit.box(
			frame,
			name .. "_LegR",
			Vector3.new(1.04, 0, -0.75),
			Vector3.new(1.14, 2.35, 0.75),
			"DeskSteel",
			"Detail"
		),
	}
end

local function chairPieces(frame: CFrame, name: string, random: Random): { Piece }
	local shell = { color = tint(Color3.fromRGB(70, 62, 48), random, 0.15) }
	return {
		Kit.box(
			frame,
			name .. "_Seat",
			Vector3.new(-0.7, 1.38, -0.65),
			Vector3.new(0.7, 1.5, 0.65),
			"ChairShell",
			"Solid",
			shell
		),
		Kit.box(
			frame,
			name .. "_Back",
			Vector3.new(-0.7, 1.5, 0.55),
			Vector3.new(0.7, 3, 0.67),
			"ChairShell",
			"Detail",
			shell
		),
		Kit.box(
			frame,
			name .. "_SideL",
			Vector3.new(-0.7, 0, -0.6),
			Vector3.new(-0.62, 1.38, 0.62),
			"DeskSteel",
			"Detail"
		),
		Kit.box(
			frame,
			name .. "_SideR",
			Vector3.new(0.62, 0, -0.6),
			Vector3.new(0.7, 1.38, 0.62),
			"DeskSteel",
			"Detail"
		),
	}
end

-- A teacher's or office desk: a wide top on two panelled ends with a modesty panel toward the visitor (local -Z).
local function bigDeskPieces(frame: CFrame, name: string, random: Random): { Piece }
	local top = { color = tint(Color3.fromRGB(96, 74, 50), random, 0.1) }
	return {
		Kit.box(
			frame,
			name .. "_Top",
			Vector3.new(-2.2, 2.4, -1.1),
			Vector3.new(2.2, 2.58, 1.1),
			"DeskTop",
			"Solid",
			top
		),
		Kit.box(frame, name .. "_EndL", Vector3.new(-2.1, 0, -1), Vector3.new(-1.95, 2.4, 1), "CabinetSteel", "Detail"),
		Kit.box(frame, name .. "_EndR", Vector3.new(1.95, 0, -1), Vector3.new(2.1, 2.4, 1), "CabinetSteel", "Detail"),
		Kit.box(
			frame,
			name .. "_Modesty",
			Vector3.new(-1.95, 0.6, -1),
			Vector3.new(1.95, 2.4, -0.88),
			"CabinetSteel",
			"Detail"
		),
	}
end

local function tablePieces(frame: CFrame, name: string, random: Random): { Piece }
	local top = { color = tint(Color3.fromRGB(104, 84, 58), random, 0.1) }
	return {
		Kit.box(frame, name .. "_Top", Vector3.new(-3, 2.4, -1.3), Vector3.new(3, 2.58, 1.3), "DeskTop", "Solid", top),
		Kit.box(frame, name .. "_EndL", Vector3.new(-2.75, 0, -1.1), Vector3.new(-2.6, 2.4, 1.1), "Trim", "Detail"),
		Kit.box(frame, name .. "_EndR", Vector3.new(2.6, 0, -1.1), Vector3.new(2.75, 2.4, 1.1), "Trim", "Detail"),
	}
end

-- A chair at `frame` as the room left it: upright, knocked askew, on its side or on its back.
local function looseChair(frame: CFrame, name: string, random: Random, floorY: number, toppleChance: number): { Piece }
	local roll = random:NextNumber()
	if roll < toppleChance then
		local pieces = chairPieces(frame * ry(between(random, -60, 60)), name, random)
		local rotation = if random:NextNumber() < 0.5
			then CFrame.Angles(0, 0, math.rad(if random:NextNumber() < 0.5 then 90 else -90))
			else CFrame.Angles(math.rad(90), 0, 0)
		overturn(pieces, frame, rotation, floorY)
		return pieces
	end
	return chairPieces(frame * ry(between(random, -14, 14)), name, random)
end

--------------------------------------------------------------------------------
-- Wall pieces
--------------------------------------------------------------------------------

-- The widest free stretch over [y0, y1] among `walls`, at least `width` wide: (wall, u0, u1).
local function widestRun(state: State, walls: { Wall }, y0: number, y1: number, width: number): (Wall?, number, number)
	local best: Wall? = nil
	local bestU0, bestU1 = 0, 0
	for _, wall in walls do
		for _, run in WallPlanner.free(wall, WallPlanner.taken(state.layout, wall, state.plan.mounts), y0, y1, width) do
			if run.u1 - run.u0 > bestU1 - bestU0 + 1e-3 then
				best, bestU0, bestU1 = wall, run.u0, run.u1
			end
		end
	end
	return best, bestU0, bestU1
end

local function paintChalk(part: BasePart, random: Random)
	local gui, pps = SurfaceArt.gui(part, Enum.NormalId.Front, { name = "Chalk", pixelsPerStud = 14, maxDistance = 70 })
	for _ = 1, random:NextInteger(1, 3) do
		local smudge = SurfaceArt.frame(
			gui,
			"Smudge",
			between(random, 0.05, 0.6),
			between(random, 0.08, 0.5),
			between(random, 0.25, 0.45),
			between(random, 0.25, 0.45),
			CHALK,
			between(random, 0.86, 0.93),
			1
		)
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.4, 0)
		corner.Parent = smudge
	end
	local warning = random:NextNumber() < 0.45
	local rows = if warning then random:NextInteger(2, 3) else random:NextInteger(4, 6)
	local thickness = math.max(1, math.floor(pps * 0.07 + 0.5))
	for row = 1, rows do
		local stroke = SurfaceArt.frame(
			gui,
			"Lesson",
			between(random, 0.05, 0.14),
			0.1 + (row - 1) * 0.12 + between(random, -0.015, 0.015),
			between(random, 0.25, 0.7),
			0,
			CHALK,
			between(random, 0.25, 0.5),
			2
		)
		stroke.Size = UDim2.new(stroke.Size.X.Scale, 0, 0, thickness)
		stroke.Rotation = between(random, -1.5, 1.5)
	end
	if warning then
		local key = if random:NextNumber() < 0.5 then "Prop.Sign.Hide" else "Prop.Sign.Help"
		local label =
			SurfaceArt.text(gui, "Text", Strings.get(key), 0.12, 0.45, 0.76, 0.4, CHALK, Enum.Font.PatrickHand, 3)
		label.TextTransparency = between(random, 0.05, 0.2)
		label.Rotation = between(random, -4, 4)
	end
end

-- A chalkboard on the widest free stretch of the room's walls. Returns that wall (the room's front, whether or not the
-- board fitted there) and whether the board went up.
local function planBoard(state: State, room: Room, random: Random): (Wall?, boolean)
	local walls = WallPlanner.walls(state.info, room)
	local ceiling = SchoolShellBuilder.ceilingBottom(state.layout, room)
	local y0, y1 = BOARD_BOTTOM - 0.2, BOARD_BOTTOM + BOARD_HEIGHT + 0.2
	if y1 > ceiling - 0.6 then
		return nil, false
	end
	local wall, u0, u1 = widestRun(state, walls, y0, y1, 6.6)
	if not wall then
		return nil, false
	end
	local width = math.min(BOARD_WIDTH, u1 - u0 - 0.6)
	local u = (u0 + u1) / 2 + between(random, -1, 1) * math.max(0, (u1 - u0 - width) / 2 - 0.3)
	local yc = BOARD_BOTTOM + BOARD_HEIGHT / 2
	local info = state.info
	local frame = Kit.block(
		"Board_" .. room.id .. "_Frame",
		WallPlanner.cframe(info, wall, u, yc, 0.055),
		Vector3.new(width + 0.3, BOARD_HEIGHT + 0.3, 0.1),
		"ChalkFrame",
		"Detail"
	)
	local slate = Kit.block(
		"Board_" .. room.id .. "_Slate",
		WallPlanner.cframe(info, wall, u, yc, 0.135),
		Vector3.new(width, BOARD_HEIGHT, 0.06),
		"Chalkboard",
		"Detail"
	)
	local tray = Kit.block(
		"Board_" .. room.id .. "_Tray",
		WallPlanner.cframe(info, wall, u, BOARD_BOTTOM - 0.2, 0.2),
		Vector3.new(width - 0.4, 0.1, 0.3),
		"ChalkFrame",
		"Detail"
	)
	local pieces = { frame, slate, tray }
	if not Kit.fits(info, pieces, { room = room.id, margin = -0.05 }) then
		return wall, false -- the room still faces this way
	end
	local seed = MathUtil.hash(state.layout.id .. ":" .. room.id .. ":chalk")
	local placed = addGroup(state, room, pieces, {
		[slate] = function(part: BasePart)
			paintChalk(part, Random.new(seed))
		end,
	})
	if placed then
		table.insert(state.plan.mounts, WallPlanner.mount(wall, u - width / 2 - 0.3, u + width / 2 + 0.3, y0, y1))
	end
	return wall, placed
end

local function paintNotices(part: BasePart, random: Random)
	local gui = SurfaceArt.gui(part, Enum.NormalId.Front, { name = "Notices", pixelsPerStud = 16, maxDistance = 60 })
	local papers = { Color3.fromRGB(184, 176, 150), Color3.fromRGB(176, 160, 112), Color3.fromRGB(150, 168, 172) }
	local count = random:NextInteger(3, 5)
	for i = 1, count do
		local w, h = between(random, 0.16, 0.26), between(random, 0.3, 0.48)
		local x = (i - 1) / count + between(random, 0, 1 / count - w)
		local paper =
			SurfaceArt.frame(gui, "Paper", x, between(random, 0.06, 0.94 - h), w, h, papers[(i % 3) + 1], 0.05, 1)
		paper.Rotation = between(random, -7, 7)
		if random:NextNumber() < 0.7 then
			SurfaceArt.stripes(paper, "Print", 0.12, 0.14, 0.76, 0.7, 4, 0.22, INK, papers[(i % 3) + 1], 0.2, 2)
		end
	end
	SurfaceArt.grime(gui, Color3.fromRGB(40, 30, 18), between(random, 0.3, 0.5), false, 4)
end

-- A cork noticeboard on a corridor wall.
local function planNoticeboard(state: State, room: Room, random: Random)
	local walls = WallPlanner.walls(state.info, room)
	local y0, y1 = NOTICE_BOTTOM - 0.2, NOTICE_BOTTOM + NOTICE_SIZE.Y + 0.2
	if y1 > SchoolShellBuilder.ceilingBottom(state.layout, room) - 0.6 then
		return
	end
	local order = table.clone(walls)
	MathUtil.shuffle(order, random)
	for _, wall in order do
		local runs = WallPlanner.free(wall, WallPlanner.taken(state.layout, wall, state.plan.mounts), y0, y1, 6.2)
		if #runs == 0 then
			continue
		end
		local run = runs[random:NextInteger(1, #runs)]
		local u = between(random, run.u0 + NOTICE_SIZE.X / 2 + 0.2, run.u1 - NOTICE_SIZE.X / 2 - 0.2)
		local yc = NOTICE_BOTTOM + NOTICE_SIZE.Y / 2
		local frame = Kit.block(
			"Notice_" .. room.id .. "_Frame",
			WallPlanner.cframe(state.info, wall, u, yc, 0.06),
			Vector3.new(NOTICE_SIZE.X + 0.25, NOTICE_SIZE.Y + 0.25, 0.12),
			"Trim",
			"Detail"
		)
		local cork = Kit.block(
			"Notice_" .. room.id .. "_Cork",
			WallPlanner.cframe(state.info, wall, u, yc, 0.145),
			Vector3.new(NOTICE_SIZE.X, NOTICE_SIZE.Y, 0.05),
			"Cork",
			"Detail"
		)
		local pieces = { frame, cork }
		if not Kit.fits(state.info, pieces, { room = room.id, margin = -0.05 }) then
			continue
		end
		local seed = MathUtil.hash(state.layout.id .. ":" .. room.id .. ":notices")
		if
			not addGroup(state, room, pieces, {
				[cork] = function(part: BasePart)
					paintNotices(part, Random.new(seed))
				end,
			})
		then
			return
		end
		local half = NOTICE_SIZE.X / 2 + 0.15
		table.insert(state.plan.mounts, WallPlanner.mount(wall, u - half, u + half, y0, y1))
		return
	end
end

local function paintCabinet(part: BasePart, random: Random)
	local gui, pps =
		SurfaceArt.gui(part, Enum.NormalId.Front, { name = "Drawers", pixelsPerStud = 12, maxDistance = 50 })
	local seam = Color3.fromRGB(26, 28, 26)
	SurfaceArt.grid(gui, 1, 4, seam, 0.15, math.max(1, math.floor(pps * 0.06 + 0.5)))
	for i = 0, 3 do
		SurfaceArt.frame(gui, "Handle", 0.36, i / 4 + 0.07, 0.28, 0.03, Color3.fromRGB(150, 150, 140), 0.1, 2)
	end
	SurfaceArt.grime(gui, Color3.fromRGB(66, 40, 22), between(random, 0.3, 0.55), false, 3)
end

-- A steel filing cabinet backed onto a free stretch of an office wall.
local function planCabinet(state: State, room: Room, random: Random)
	local walls = WallPlanner.walls(state.info, room)
	local order = table.clone(walls)
	MathUtil.shuffle(order, random)
	for _, wall in order do
		local runs = WallPlanner.free(wall, WallPlanner.taken(state.layout, wall, state.plan.mounts), 0, CABINET.Y, 2.4)
		if #runs == 0 then
			continue
		end
		local run = runs[random:NextInteger(1, #runs)]
		local u = between(random, run.u0 + CABINET.X / 2 + 0.1, run.u1 - CABINET.X / 2 - 0.1)
		local cabinet = Kit.block(
			"Cabinet_" .. room.id,
			WallPlanner.cframe(state.info, wall, u, CABINET.Y / 2, CABINET.Z / 2 + 0.03) * ry(between(random, -3, 3)),
			CABINET,
			"CabinetSteel",
			"Solid",
			{ color = tint(Color3.fromRGB(74, 80, 74), random, 0.12) }
		)
		if not Kit.fits(state.info, { cabinet }, { room = room.id, ground = 0, margin = -0.05 }) then
			continue
		end
		local seed = MathUtil.hash(state.layout.id .. ":" .. room.id .. ":cabinet")
		if
			not addGroup(state, room, { cabinet }, {
				[cabinet] = function(part: BasePart)
					paintCabinet(part, Random.new(seed))
				end,
			})
		then
			return
		end
		local half = CABINET.X / 2 + 0.2
		table.insert(state.plan.mounts, WallPlanner.mount(wall, u - half, u + half, 0, CABINET.Y + 0.3))
		return
	end
end

--------------------------------------------------------------------------------
-- Rooms
--------------------------------------------------------------------------------

-- Rows of desks and chairs facing `front`, and the teacher's desk before the board.
local function planRows(state: State, room: Room, front: Wall, random: Random)
	local info = state.info
	local floorY = info.origin.Y
	local depth = WallPlanner.depth(info, front)
	local mid = (front.u0 + front.u1) / 2

	-- The teacher's desk, off to one side of the board, facing the class.
	local side = if random:NextNumber() < 0.5 then -1 else 1
	for _, offset in { side * between(random, 2.5, 4.5), -side * between(random, 2.5, 4.5) } do
		local at = WallPlanner.floorPoint(info, front, mid + offset, 4.4)
		local frame = CFrame.lookAt(at, at + front.normal) * ry(between(random, -6, 6))
		local pieces = bigDeskPieces(frame, "TeacherDesk_" .. room.id, random)
		if fitsFloor(state, room, pieces) and addGroup(state, room, pieces) then
			break
		end
	end

	local width = front.u1 - front.u0 - PERIMETER * 2
	local cols = math.clamp(math.floor((width + AISLE) / (2.4 + AISLE)), 0, MAX_COLUMNS)
	local span = depth - FRONT_CLEAR - BACK_CLEAR
	local rows = math.clamp(math.floor((span + ROW_PITCH - 3.4) / ROW_PITCH), 0, MAX_ROWS)
	local spread = cols * 2.4 + (cols - 1) * AISLE
	for row = 0, rows - 1 do
		for col = 0, cols - 1 do
			local roll = random:NextNumber()
			if roll < 0.2 then
				continue -- carried off, burned, who knows
			end
			local u = mid - spread / 2 + 1.2 + col * (2.4 + AISLE)
			local d = FRONT_CLEAR + 0.85 + row * ROW_PITCH
			local at = WallPlanner.floorPoint(info, front, u, d)
			local base = CFrame.lookAt(at, at - front.normal) -- pupils face the board
			local name = string.format("Desk_%s_%d_%d", room.id, row, col)
			local pieces: { Piece }
			if roll < 0.62 then
				local frame = base
					* CFrame.new(between(random, -0.2, 0.2), 0, between(random, -0.2, 0.2))
					* ry(between(random, -7, 7))
				pieces = deskPieces(frame, name, random)
				append(
					pieces,
					looseChair(frame * CFrame.new(0, 0, between(random, 1.6, 1.9)), name .. "_Chair", random, floorY, 0)
				)
			elseif roll < 0.84 then
				local frame = base
					* CFrame.new(between(random, -0.3, 0.3), 0, between(random, -0.5, 0.5))
					* ry(between(random, -20, 20))
				pieces = deskPieces(frame, name, random)
				local chair = frame * CFrame.new(between(random, -0.4, 0.4), 0, between(random, 2, 2.4))
				append(pieces, looseChair(chair * ry(between(random, -35, 35)), name .. "_Chair", random, floorY, 0.3))
			else
				local frame = base * ry(between(random, -12, 12))
				pieces = deskPieces(frame, name, random)
				overturn(
					pieces,
					frame,
					CFrame.Angles(math.rad(if random:NextNumber() < 0.5 then 90 else -90), 0, 0),
					floorY
				)
				append(pieces, looseChair(frame * CFrame.new(0, 0, 2.3), name .. "_Chair", random, floorY, 0.8))
			end
			if fitsFloor(state, room, pieces) then
				addGroup(state, room, pieces)
			end
		end
	end
end

-- Long tables with chairs down both sides, in a grid along `front`'s wall.
local function planTables(state: State, room: Room, front: Wall, hasBoard: boolean, random: Random)
	local info = state.info
	local floorY = info.origin.Y
	local depth = WallPlanner.depth(info, front)
	local d0 = if hasBoard then 8.6 else 4.4
	local alongPitch, depthPitch = 6 + AISLE, 2.6 + 2.8 + AISLE
	local width = front.u1 - front.u0 - PERIMETER * 2
	local cols = math.max(0, math.floor((width + AISLE) / alongPitch))
	local rows = math.max(0, math.floor((depth - d0 - BACK_CLEAR + AISLE) / depthPitch))
	local cells: { { number } } = {}
	for row = 0, rows - 1 do
		for col = 0, cols - 1 do
			table.insert(cells, { row, col })
		end
	end
	MathUtil.shuffle(cells, random)
	local spread = cols * 6 + (cols - 1) * AISLE
	local mid = (front.u0 + front.u1) / 2
	local placed = 0
	for _, cell in cells do
		if placed >= MAX_TABLES then
			break
		end
		local row, col = cell[1], cell[2]
		local u = mid - spread / 2 + 3 + col * alongPitch
		local d = d0 + 1.4 + 1.3 + row * depthPitch
		local at = WallPlanner.floorPoint(info, front, u, d)
		local frame = CFrame.lookAt(at, at - front.normal) * ry(between(random, -8, 8))
		local name = string.format("Table_%s_%d_%d", room.id, row, col)
		local pieces = tablePieces(frame, name, random)
		if random:NextNumber() < 0.15 then
			overturn(
				pieces,
				frame,
				CFrame.Angles(math.rad(if random:NextNumber() < 0.5 then 90 else -90), 0, 0),
				floorY
			)
		end
		for i, spot in { { -1.5, -1 }, { 1.5, -1 }, { -1.5, 1 }, { 1.5, 1 } } do
			if random:NextNumber() < 0.45 then
				continue
			end
			local x, z = spot[1] + between(random, -0.3, 0.3), spot[2] * between(random, 1.9, 2.4)
			local chair = frame * CFrame.new(x, 0, z) * ry(if spot[2] < 0 then 180 else 0)
			append(pieces, looseChair(chair, name .. "_Chair" .. i, random, floorY, 0.2))
		end
		if fitsFloor(state, room, pieces) and addGroup(state, room, pieces) then
			placed += 1
		end
	end
end

-- An office: a desk with its chair somewhere in the room, a filing cabinet on a wall.
local function planOffice(state: State, room: Room, random: Random)
	local info = state.info
	local inner = info.inner[room.id]
	if not inner then
		return
	end
	planCabinet(state, room, random)
	for _ = 1, 8 do
		local x = between(random, inner.x + 4, inner.x + inner.w - 4)
		local z = between(random, inner.z + 4, inner.z + inner.d - 4)
		local at = info.origin + Vector3.new(x, 0, z)
		local frame = CFrame.new(at) * ry(random:NextInteger(0, 3) * 90 + between(random, -8, 8))
		local pieces = bigDeskPieces(frame, "OfficeDesk_" .. room.id, random)
		local chair = frame
			* CFrame.new(between(random, -0.6, 0.6), 0, between(random, 1.9, 2.5))
			* ry(between(random, -30, 30))
		append(pieces, looseChair(chair, "OfficeDesk_" .. room.id .. "_Chair", random, info.origin.Y, 0.25))
		if fitsFloor(state, room, pieces) and addGroup(state, room, pieces) then
			return
		end
	end
end

local planCache: { [Layout]: Plan } = setmetatable({}, { __mode = "k" }) :: any

-- Everything `layout`'s rooms are furnished with (pure, seeded per layout; cached).
function FurnitureBuilder.plan(layout: Layout): Plan
	local cached = planCache[layout]
	if cached then
		return cached
	end
	local state: State = {
		layout = layout,
		info = Kit.info(layout),
		plan = { pieces = {}, painters = {}, mounts = {}, footprints = {} },
		used = {},
	}
	if layout.id ~= "Lobby" and layout.id ~= "Level5_Roof" then
		for _, room in layout.rooms do
			local random = MathUtil.seededRandom(1, layout.id .. ":furniture:" .. room.id)
			if room.kind == "Classroom" then
				local front, hasBoard = planBoard(state, room, random)
				if front then
					if room.rect.w * room.rect.d >= HALL_AREA then
						planTables(state, room, front, hasBoard, random)
					else
						planRows(state, room, front, random)
					end
				end
			elseif room.kind == "Lab" then
				planBoard(state, room, random)
			elseif room.kind == "Office" then
				planOffice(state, room, random)
			elseif room.kind == "Corridor" then
				planNoticeboard(state, room, random)
			end
		end
	end
	planCache[layout] = state.plan
	return state.plan
end

local function buildFurniture(ctx: PropKit.StaticContext): number
	local layout = ctx.layout
	local plan = FurnitureBuilder.plan(layout)
	if #plan.pieces == 0 then
		return 0
	end
	local info = Kit.info(layout)
	local model = PropKit.model(ctx.parent, "Furniture_" .. layout.id, CFrame.new(info.origin))
	model:SetAttribute(W.LevelId, layout.id)
	local parts = Kit.realize(model, plan.pieces)
	for index, painter in plan.painters do
		local part = parts[index]
		if part then
			painter(part)
		end
	end
	return #parts
end

function FurnitureBuilder.register(registrar: PropKit.Registrar)
	registrar.static("Furniture", buildFurniture)
end

return table.freeze(FurnitureBuilder)
