--!strict
-- SignageBuilder: the school's signs, posters and notes (static kind "Signage": once at boot, the same on every server,
-- into <level>.Props as one Model "Signs_<layoutId>").
--
--   * Room plates: an enamelled ROOM 108 / LAB 201 plate on the corridor wall beside the door of every numbered
--     classroom and lab.
--   * Wayfinding: STAIRS beside every airlock fire door (on the corridor side), a sign over the door of the rooms people
--     look for (MAIN OFFICE, BOILER ROOM - STAFF ONLY, GYMNASIUM, LOCKER ROOMS, POOL - NO DIVING) and SCIENCE WING
--     boards high on the science hall's corridors.
--   * Paper and paint (seeded per level): NO RUNNING IN THE HALLS posters, ASSEMBLY CANCELLED notices, HAVE YOU SEEN
--     THIS STUDENT? posters with a faded photo, CAUTION placards, QUARANTINE sheets taped beside storeroom doors, and
--     HELP US / DON'T LET IT HEAR YOU scrawled on the walls in something dark that ran. Paper hangs crooked, torn and
--     water-stained.
--   * WET FLOOR A-frames standing near the walls of the wet rooms.
-- Every piece is a thin Detail part (never collides, never queried, casts no shadow) carrying one SurfaceGui
-- (SurfaceArt: Frames and TextLabels, every word from Strings, lit by the scene). A sign only goes where
-- SetDressingBuilder.Kit lets dressing go (clear of doorways and their swings, grate fronts, landings, locker banks,
-- hideable lockers, switches, spawns and the dressing spots) and where its wall really is: inside the room's wall
-- faces, clear of every opening the shell cuts and what frames it, of the wall-mounted fixtures and of the other signs,
-- under the ceiling and above the wainscot's chair rail.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Strings = require(ReplicatedStorage.Shared.Strings)

local DecayBuilder = require(script.Parent.DecayBuilder)
local Finishes = require(script.Parent.Parent.Finishes)
local FurnitureBuilder = require(script.Parent.FurnitureBuilder)
local Geometry = require(script.Parent.Parent.Geometry)
local Palette = require(script.Parent.Parent.Palette)
local PropKit = require(script.Parent.PropKit)
local SchoolShellBuilder = require(script.Parent.Parent.SchoolShellBuilder)
local SetDressingBuilder = require(script.Parent.SetDressingBuilder)
local SurfaceArt = require(script.Parent.Parent.SurfaceArt)

type Layout = LayoutSchema.LevelLayout
type Room = LayoutSchema.Room
type Door = LayoutSchema.Door
type Piece = SetDressingBuilder.Piece
type LevelInfo = SetDressingBuilder.LevelInfo

local Kit = SetDressingBuilder.Kit
local W = Attributes.World

local EPS = 1e-3
local MIN_Y = Finishes.RailTop + 0.25 -- every wall sign clears the chair rail
local CEILING_GAP = 0.35
local WALL_END = 0.4 -- signs keep this far from a room's corners
local WALL_GAP = 0.004 -- back face off the wall face
local SPOT_TRIES = 14

export type Design =
	"RoomPlate"
	| "Wayfinding"
	| "Stairs"
	| "Poster"
	| "Notice"
	| "Missing"
	| "Caution"
	| "Quarantine"
	| "Scrawl"

type Style = {
	size: Vector2, -- width along the wall, height
	depth: number,
	key: string, -- palette of the backing
	y: number, -- bottom edge above the floor
	tilt: number, -- most degrees it hangs off true
	paper: boolean, -- yellows, tears and stains
	maxDistance: number,
}

local STYLES: { [string]: Style } = {
	RoomPlate = {
		size = Vector2.new(2.1, 0.8),
		depth = 0.05,
		key = "SignPlate",
		y = 5.1,
		tilt = 3,
		paper = false,
		maxDistance = 55,
	},
	Wayfinding = {
		size = Vector2.new(4.6, 1.1),
		depth = 0.06,
		key = "SignMetal", -- painted steel
		y = 10.6,
		tilt = 2,
		paper = false,
		maxDistance = 90,
	},
	Stairs = {
		size = Vector2.new(2.8, 0.9),
		depth = 0.05,
		key = "SignMetal",
		y = 7.3, -- over the smashed locker banks that line the corridor ends
		tilt = 1.5,
		paper = false,
		maxDistance = 80,
	},
	Poster = {
		size = Vector2.new(2.2, 3),
		depth = 0.02,
		key = "SignPaper",
		y = 4.2,
		tilt = 7,
		paper = true,
		maxDistance = 55,
	},
	Notice = {
		size = Vector2.new(1.8, 2.4),
		depth = 0.02,
		key = "SignPaper",
		y = 4.6,
		tilt = 5,
		paper = true,
		maxDistance = 50,
	},
	Missing = {
		size = Vector2.new(1.9, 2.6),
		depth = 0.02,
		key = "SignPaper",
		y = 4.5,
		tilt = 8,
		paper = true,
		maxDistance = 50,
	},
	Caution = {
		size = Vector2.new(1.7, 1.15),
		depth = 0.05,
		key = "HazardYellow",
		y = 5.4,
		tilt = 4,
		paper = false,
		maxDistance = 60,
	},
	Quarantine = {
		size = Vector2.new(3.4, 1.4),
		depth = 0.02,
		key = "SignPaper",
		y = 5.4,
		tilt = 6,
		paper = true,
		maxDistance = 60,
	},
	Scrawl = {
		size = Vector2.new(4.2, 1.9),
		depth = 0.02,
		key = "SignPaper",
		y = 4.3,
		tilt = 5,
		paper = false,
		maxDistance = 45,
	},
}

-- Paper and paint each level puts up (design, count, where).
type Where = "Hall" | "Service" | "Wet"
type Request = { design: Design, count: number, where: Where }

local LEVEL_PAPERS: { [string]: { Request } } = {
	Level0_Basement = {
		{ design = "Caution", count = 2, where = "Service" },
		{ design = "Quarantine", count = 1, where = "Service" },
		{ design = "Scrawl", count = 2, where = "Hall" },
		{ design = "Missing", count = 1, where = "Hall" },
	},
	Level1_Hallways = {
		{ design = "Poster", count = 2, where = "Hall" },
		{ design = "Notice", count = 1, where = "Hall" },
		{ design = "Missing", count = 3, where = "Hall" },
		{ design = "Scrawl", count = 2, where = "Hall" },
	},
	Level2_ScienceHall = {
		{ design = "Poster", count = 1, where = "Hall" },
		{ design = "Missing", count = 2, where = "Hall" },
		{ design = "Caution", count = 2, where = "Service" },
		{ design = "Quarantine", count = 1, where = "Service" },
		{ design = "Scrawl", count = 1, where = "Hall" },
	},
	Level3_Gymnasium = {
		{ design = "Poster", count = 2, where = "Hall" },
		{ design = "Missing", count = 2, where = "Hall" },
		{ design = "Notice", count = 1, where = "Hall" },
		{ design = "Scrawl", count = 1, where = "Hall" },
	},
	Level4_FloodedPool = {
		{ design = "Caution", count = 2, where = "Wet" },
		{ design = "Poster", count = 1, where = "Hall" },
		{ design = "Missing", count = 1, where = "Hall" },
		{ design = "Scrawl", count = 1, where = "Hall" },
	},
}

-- WET FLOOR A-frames per level.
local WET_FLOOR: { [string]: number } = {
	Level0_Basement = 1,
	Level1_Hallways = 1,
	Level3_Gymnasium = 2,
	Level4_FloodedPool = 3,
}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local INK = rgb(30, 26, 22)
local CREAM = rgb(226, 214, 178)
local SCHOOL_GREEN = rgb(30, 62, 46)
local BOILER_RED = rgb(104, 28, 24)
local POOL_BLUE = rgb(28, 60, 100)
local STAIN = rgb(132, 104, 56)
local STAIN_RING = rgb(96, 72, 40)
local SCRAWL_INK = rgb(82, 16, 12)
local OLD_PAPER = rgb(166, 142, 96)

--------------------------------------------------------------------------------
-- Walls
--------------------------------------------------------------------------------

type Wall = {
	room: Room,
	axis: "X" | "Z", -- "Z": the wall runs along X at constant Z; "X": along Z at constant X
	line: number, -- the wall line (the room rect's edge)
	face: number, -- the room-side face, across the line
	normal: Vector3, -- into the room
	u0: number,
	u1: number,
}

type Block = { u0: number, u1: number, y0: number, y1: number }

type State = {
	layout: Layout,
	info: LevelInfo,
	blocks: { [string]: { Block } }, -- per wall line: openings and their frames
	placed: { [string]: { Block } }, -- per room wall: signs already up
	pieces: { Piece },
	painters: { (part: BasePart) -> () },
}

local function lineKey(axis: "X" | "Z", coord: number): string
	return string.format("%s|%.3f", axis, coord)
end

local function wallsOf(info: LevelInfo, room: Room): { Wall }
	local inner = info.inner[room.id]
	local r = room.rect
	if not inner then
		return {}
	end
	return {
		{
			room = room,
			axis = "Z",
			line = r.z,
			face = inner.z,
			normal = Vector3.zAxis,
			u0 = inner.x,
			u1 = inner.x + inner.w,
		},
		{
			room = room,
			axis = "Z",
			line = r.z + r.d,
			face = inner.z + inner.d,
			normal = -Vector3.zAxis,
			u0 = inner.x,
			u1 = inner.x + inner.w,
		},
		{
			room = room,
			axis = "X",
			line = r.x,
			face = inner.x,
			normal = Vector3.xAxis,
			u0 = inner.z,
			u1 = inner.z + inner.d,
		},
		{
			room = room,
			axis = "X",
			line = r.x + r.w,
			face = inner.x + inner.w,
			normal = -Vector3.xAxis,
			u0 = inner.z,
			u1 = inner.z + inner.d,
		},
	}
end

-- The wall of `room` on the line (axis, coord), if it has one.
local function wallOn(info: LevelInfo, room: Room, axis: "X" | "Z", coord: number): Wall?
	for _, wall in wallsOf(info, room) do
		if wall.axis == axis and math.abs(wall.line - coord) < EPS then
			return wall
		end
	end
	return nil
end

-- What a sign keeps clear of along each wall line: every opening the shell cuts, padded by its casing, frame,
-- boards or grate frame (a fire door's sign plate above its head too), and what FurnitureBuilder and DecayBuilder
-- mount on the walls.
local function openingBlocks(layout: Layout): { [string]: { Block } }
	local out: { [string]: { Block } } = {}
	for _, item in SchoolShellBuilder.openings(layout) do
		local o = item.opening
		local pad, below, above = 0.5, 0.4, 0.6
		local door = item.door
		if door then
			pad = if door.kind == "Airlock" or door.kind == "Gate" then 1.1 else 0.75
			above = if door.kind == "Airlock" or door.kind == "RoofDoor" or door.kind == "Gate" then 2.4 else 0.6
		elseif item.kind == "Grate" then
			pad, below, above = 0.65, 0.6, 0.7
		end
		local key = lineKey(item.axis, item.coord)
		local list = out[key]
		if not list then
			list = {}
			out[key] = list
		end
		table.insert(list, { u0 = o.u0 - pad, u1 = o.u1 + pad, y0 = o.y0 - below, y1 = o.y1 + above })
	end
	-- the chalkboards, noticeboards and cabinets already up, and the plaster that has come away
	local mounts = table.clone(FurnitureBuilder.plan(layout).mounts)
	for _, mount in DecayBuilder.wallMounts(layout) do
		table.insert(mounts, mount)
	end
	for _, mount in mounts do
		local key = lineKey(mount.axis, mount.line)
		local list = out[key]
		if not list then
			list = {}
			out[key] = list
		end
		table.insert(list, { u0 = mount.u0, u1 = mount.u1, y0 = mount.y0, y1 = mount.y1 })
	end
	return out
end

-- Wall-mounted fixtures of `wall`'s room on that wall (exit signs, emergency lamps, firebox glows).
local function fixtureBlocks(wall: Wall): { Block }
	local out: { Block } = {}
	for _, light in (wall.room.lights or {}) :: { LayoutSchema.Light } do
		local p = light.pos
		local across = if wall.axis == "Z" then p.Z else p.X
		local wallMounted = light.kind == "EmergencyRed" or light.kind == "ExitSign" or light.kind == "BoilerGlow"
		if wallMounted or math.abs(across - wall.face) < 1.8 then
			local u = if wall.axis == "Z" then p.X else p.Z
			table.insert(out, { u0 = u - 1.7, u1 = u + 1.7, y0 = p.Y - 1.4, y1 = p.Y + 1.4 })
		end
	end
	return out
end

local function overlaps(list: { Block }, b: Block, gap: number): boolean
	for _, o in list do
		if o.u1 > b.u0 - gap and o.u0 < b.u1 + gap and o.y1 > b.y0 - gap and o.y0 < b.y1 + gap then
			return true
		end
	end
	return false
end

-- A Detail piece for a sign of `style` centred at `u` with its bottom edge at `y0` on `wall`, tilted `tilt` degrees,
-- if the spot is free. Records the spot on success.
local function tryWall(
	state: State,
	wall: Wall,
	u: number,
	y0: number,
	style: Style,
	tilt: number,
	name: string,
	options: Geometry.PartOptions?
): Piece?
	local w, h = style.size.X, style.size.Y
	if u - w / 2 < wall.u0 + WALL_END or u + w / 2 > wall.u1 - WALL_END then
		return nil
	end
	local ceiling = SchoolShellBuilder.ceilingBottom(state.layout, wall.room)
	if y0 < MIN_Y or y0 + h > ceiling - CEILING_GAP then
		return nil
	end
	local spot: Block = { u0 = u - w / 2, u1 = u + w / 2, y0 = y0, y1 = y0 + h }
	if overlaps(state.blocks[lineKey(wall.axis, wall.line)] or {}, spot, 0.05) then
		return nil
	end
	if overlaps(fixtureBlocks(wall), spot, 0.05) then
		return nil
	end
	local wallKey = wall.room.id .. lineKey(wall.axis, wall.line)
	local placed = state.placed[wallKey]
	if placed and overlaps(placed, spot, 0.35) then
		return nil
	end
	local offset = wall.face
		+ (if wall.axis == "Z" then wall.normal.Z else wall.normal.X) * (style.depth / 2 + WALL_GAP)
	local centre = if wall.axis == "Z" then Vector3.new(u, y0 + h / 2, offset) else Vector3.new(offset, y0 + h / 2, u)
	local world = state.info.origin + centre
	local cframe = CFrame.lookAt(world, world + wall.normal) * CFrame.Angles(0, 0, math.rad(tilt))
	local merged: Geometry.PartOptions = { castShadow = false }
	if options then
		merged.color = options.color
		merged.material = options.material
		merged.transparency = options.transparency
	end
	local piece = Kit.block(name, cframe, Vector3.new(w, h, style.depth), style.key, "Detail", merged)
	if not Kit.fits(state.info, { piece }, { room = wall.room.id, margin = -0.05 }) then
		return nil
	end
	local list: { Block } = placed or {}
	state.placed[wallKey] = list
	table.insert(list, spot)
	return piece
end

local function addPiece(state: State, piece: Piece, painter: (part: BasePart) -> ())
	table.insert(state.pieces, piece)
	table.insert(state.painters, painter)
end

--------------------------------------------------------------------------------
-- Painters
--------------------------------------------------------------------------------

local function printGui(part: BasePart, style: Style): (SurfaceGui, number)
	return SurfaceArt.gui(
		part,
		Enum.NormalId.Front,
		{ name = "Print", pixelsPerStud = 20, maxDistance = style.maxDistance }
	)
end

-- An enamelled plate: a thin border, the words, grime gathered at the bottom.
local function paintPlate(part: BasePart, style: Style, text: string, ink: Color3)
	local gui = printGui(part, style)
	SurfaceArt.outline(gui, "Border", 0.03, 0.07, 0.94, 0.86, ink, 1, 0.2)
	SurfaceArt.text(gui, "Text", text, 0.06, 0.1, 0.88, 0.8, ink, Enum.Font.GothamBold, 2)
	SurfaceArt.grime(gui, rgb(20, 18, 14), 0.45, false, 3)
end

-- What time does to paper: water stains, a corner torn away to the wall behind, grime.
local function weather(gui: SurfaceGui, random: Random, wallColor: Color3, size: Vector2)
	for _ = 1, random:NextInteger(0, 2) do
		local d = random:NextNumber(0.25, 0.6)
		SurfaceArt.stain(
			gui,
			random:NextNumber(0.2, 0.8),
			random:NextNumber(0.2, 0.85),
			d,
			d * size.X / size.Y * random:NextNumber(0.7, 1.2),
			STAIN,
			random:NextNumber(0.6, 0.78),
			STAIN_RING,
			4
		)
	end
	if random:NextNumber() < 0.45 then
		local corner = random:NextInteger(0, 3)
		local tear = SurfaceArt.frame(gui, "Tear", corner % 2, if corner >= 2 then 1 else 0, 0, 0, wallColor, 0, 5)
		local side = random:NextNumber(0.28, 0.42)
		tear.AnchorPoint = Vector2.new(0.5, 0.5)
		tear.Size = UDim2.fromScale(side, side * size.X / size.Y)
		tear.Rotation = 45 + random:NextNumber(-18, 18)
	end
	SurfaceArt.grime(gui, rgb(70, 54, 30), random:NextNumber(0.25, 0.45), false, 6)
end

local function paintPoster(part: BasePart, style: Style, text: string, random: Random, wallColor: Color3)
	local gui = printGui(part, style)
	local accents = { rgb(150, 36, 30), rgb(32, 70, 120), rgb(44, 96, 52) }
	SurfaceArt.frame(gui, "Header", 0.06, 0.05, 0.88, 0.15, accents[random:NextInteger(1, #accents)], 0.05, 1)
	SurfaceArt.text(gui, "Text", text, 0.08, 0.25, 0.84, 0.45, INK, Enum.Font.GothamBlack, 2)
	for i, y in { 0.76, 0.82, 0.88 } do
		SurfaceArt.frame(gui, "Rule", 0.12, y, if i == 3 then 0.48 else 0.76, 0.012, INK, 0.45, 1)
	end
	weather(gui, random, wallColor, style.size)
end

local function paintNotice(part: BasePart, style: Style, text: string, random: Random, wallColor: Color3)
	local gui = printGui(part, style)
	SurfaceArt.text(gui, "Text", text, 0.08, 0.06, 0.84, 0.22, INK, Enum.Font.SpecialElite, 2)
	for i = 0, 7 do
		SurfaceArt.frame(gui, "Typed", 0.09, 0.36 + i * 0.065, random:NextNumber(0.45, 0.82), 0.018, INK, 0.55, 1)
	end
	local stamp = SurfaceArt.outline(gui, "Stamp", 0.4, 0.62, 0.48, 0.2, rgb(150, 30, 26), 2, 0.3, true, 3)
	stamp.Rotation = random:NextNumber(-20, -8)
	weather(gui, random, wallColor, style.size)
end

local function paintMissing(part: BasePart, style: Style, text: string, random: Random, wallColor: Color3)
	local gui = printGui(part, style)
	SurfaceArt.text(gui, "Text", text, 0.06, 0.03, 0.88, 0.17, INK, Enum.Font.GothamBlack, 2)
	local photo = SurfaceArt.frame(gui, "Photo", 0.2, 0.23, 0.6, 0.42, rgb(72, 72, 74), 0, 1)
	photo.ClipsDescendants = true
	local head = SurfaceArt.stain(photo, 0.5, 0.36, 0.34, 0.36, rgb(34, 34, 36), 0, nil, 2)
	head.Name = "Head"
	local shoulders = SurfaceArt.stain(photo, 0.5, 0.98, 0.84, 0.62, rgb(34, 34, 36), 0, nil, 2)
	shoulders.Name = "Shoulders"
	for i = 0, 3 do
		SurfaceArt.frame(gui, "Line", 0.12, 0.71 + i * 0.06, random:NextNumber(0.5, 0.76), 0.016, INK, 0.5, 1)
	end
	weather(gui, random, wallColor, style.size)
end

local function paintCaution(part: BasePart, style: Style)
	local gui, pps = printGui(part, style)
	local bandStuds = Vector2.new(style.size.X, style.size.Y * 0.2)
	for i, top in { 0, 0.8 } do
		local frame = SurfaceArt.frame(gui, if i == 1 then "BandTop" else "BandBottom", 0, top, 1, 0.2, INK, 0, 1)
		frame.ClipsDescendants = true
		SurfaceArt.hazard(frame, bandStuds, pps, 0.14)
	end
	SurfaceArt.text(gui, "Text", Strings.get("Prop.Sign.Caution"), 0.06, 0.24, 0.88, 0.52, INK, Enum.Font.Oswald, 3)
	SurfaceArt.grime(gui, rgb(40, 30, 18), 0.35, false, 4)
end

local function paintQuarantine(part: BasePart, style: Style, random: Random, wallColor: Color3)
	local gui = printGui(part, style)
	local red = rgb(156, 26, 22)
	SurfaceArt.frame(gui, "BandTop", 0, 0, 1, 0.17, red, 0, 1)
	SurfaceArt.frame(gui, "BandBottom", 0, 0.83, 1, 0.17, red, 0, 1)
	SurfaceArt.text(gui, "Text", Strings.get("Prop.Sign.Quarantine"), 0.05, 0.22, 0.9, 0.56, INK, Enum.Font.Oswald, 2)
	for _, x in { 0.02, 0.98 } do
		local tape = SurfaceArt.frame(gui, "Tape", x, 0.02, 0, 0, rgb(196, 182, 140), 0.3, 6)
		tape.AnchorPoint = Vector2.new(0.5, 0.5)
		tape.Size = UDim2.fromScale(0.16, 0.12)
		tape.Rotation = if x < 0.5 then -35 else 35
	end
	weather(gui, random, wallColor, style.size)
end

-- Words scrawled straight onto the wall, the paint run in drips below them.
local function paintScrawl(part: BasePart, style: Style, text: string, random: Random)
	local gui = printGui(part, style)
	local words = SurfaceArt.text(gui, "Text", text, 0.02, 0.02, 0.96, 0.6, SCRAWL_INK, Enum.Font.PermanentMarker, 2)
	words.TextTransparency = 0.1
	words.Rotation = random:NextNumber(-4, 4)
	for _ = 1, random:NextInteger(4, 7) do
		local drip = SurfaceArt.frame(
			gui,
			"Drip",
			random:NextNumber(0.08, 0.92),
			random:NextNumber(0.42, 0.56),
			random:NextNumber(0.006, 0.012),
			random:NextNumber(0.15, 0.4),
			SCRAWL_INK,
			0,
			1
		)
		local fade = Instance.new("UIGradient")
		fade.Rotation = 90
		fade.Transparency = NumberSequence.new(0.1, 1)
		fade.Parent = drip
	end
end

local function paintWetFloor(part: BasePart, size: Vector2)
	local gui, pps = SurfaceArt.gui(part, Enum.NormalId.Front, { name = "Print", pixelsPerStud = 20, maxDistance = 55 })
	SurfaceArt.text(gui, "Caution", Strings.get("Prop.Sign.Caution"), 0.08, 0.06, 0.84, 0.2, INK, Enum.Font.Oswald, 2)
	SurfaceArt.text(gui, "Text", Strings.get("Prop.Sign.WetFloor"), 0.08, 0.3, 0.84, 0.3, INK, Enum.Font.GothamBlack, 2)
	local band = SurfaceArt.frame(gui, "Band", 0, 0.86, 1, 0.1, INK, 0, 1)
	band.ClipsDescendants = true
	SurfaceArt.hazard(band, Vector2.new(size.X, size.Y * 0.1), pps, 0.12)
	SurfaceArt.grime(gui, rgb(40, 32, 20), 0.3, false, 4)
end

--------------------------------------------------------------------------------
-- Placement
--------------------------------------------------------------------------------

local function paperOptions(random: Random): Geometry.PartOptions
	local fresh = Palette.get("SignPaper").color
	return { color = fresh:Lerp(OLD_PAPER, random:NextNumber(0, 0.55)) }
end

local function wallColor(room: Room): Color3
	return Palette.get(SchoolShellBuilder.wallKey(room)).color
end

local function tilt(random: Random, style: Style): number
	return random:NextNumber(-style.tilt, style.tilt)
end

-- The room number in an id like L1_Classroom_108 or L2_ChemLab_201.
local function roomNumber(room: Room): number?
	local digits = string.match(room.id, "_(%d+)$")
	return if digits then tonumber(digits) else nil
end

-- Places a `design` sign beside door `door` on the wall of `room` (the side the sign faces), at bottom `y0`.
local function besideDoor(
	state: State,
	room: Room,
	door: Door,
	style: Style,
	y0: number,
	random: Random,
	name: string,
	options: Geometry.PartOptions?,
	reach: number?
): Piece?
	local rooms = state.info.rooms
	local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
	local edge = if a and b then LayoutSchema.sharedEdge(a.rect, b.rect) else nil
	if not edge then
		return nil
	end
	local wall = wallOn(state.info, room, edge.axis, edge.coord)
	if not wall then
		return nil
	end
	local half = LayoutSchema.doorWidth(door) / 2 + (reach or 0.8) + style.size.X / 2
	local first = if random:NextNumber() < 0.5 then 1 else -1
	local order: { number } = { first, -first }
	for _, s in order do
		local piece = tryWall(state, wall, door.at + s * half, y0, style, tilt(random, style), name, options)
		if piece then
			return piece
		end
	end
	return nil
end

-- A spot for `style` on the other walls of `room` as close as it gets to door `door` (within NEAR_DOOR studs): the
-- side walls of a corridor end too narrow for a sign beside its door.
local NEAR_DOOR = 16

local function nearDoor(
	state: State,
	room: Room,
	door: Door,
	style: Style,
	random: Random,
	name: string,
	options: Geometry.PartOptions?
): Piece?
	local rooms = state.info.rooms
	local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
	local edge = if a and b then LayoutSchema.sharedEdge(a.rect, b.rect) else nil
	if not edge then
		return nil
	end
	local px = if edge.axis == "X" then edge.coord else door.at
	local pz = if edge.axis == "X" then door.at else edge.coord
	local w = style.size.X
	for _, wall in wallsOf(state.info, room) do
		if wall.axis == edge.axis and math.abs(wall.line - edge.coord) < EPS then
			continue -- the door's own wall
		end
		local along = if wall.axis == "Z" then px else pz
		local across = math.abs((if wall.axis == "Z" then pz else px) - wall.face)
		if across > NEAR_DOOR then
			continue
		end
		local inward = if along - wall.u0 < wall.u1 - along then 1 else -1
		for offset = 1.2 + w / 2, NEAR_DOOR, 1.2 do
			local piece =
				tryWall(state, wall, along + inward * offset, style.y, style, tilt(random, style), name, options)
			if piece then
				return piece
			end
		end
	end
	return nil
end

-- A free spot for `style` on a random wall of `room` (seeded tries). Returns the piece.
local function anywhere(
	state: State,
	room: Room,
	style: Style,
	random: Random,
	name: string,
	options: Geometry.PartOptions?,
	yJitter: number?
): Piece?
	local walls = wallsOf(state.info, room)
	local total = 0
	for _, wall in walls do
		total += math.max(0, wall.u1 - wall.u0)
	end
	if total <= 0 then
		return nil
	end
	for _ = 1, SPOT_TRIES do
		local pick = random:NextNumber(0, total)
		local wall = walls[1]
		for _, candidate in walls do
			local length = math.max(0, candidate.u1 - candidate.u0)
			if pick <= length then
				wall = candidate
				break
			end
			pick -= length
		end
		local w = style.size.X
		local lo, hi = wall.u0 + WALL_END + w / 2, wall.u1 - WALL_END - w / 2
		if hi <= lo then
			continue
		end
		local y0 = style.y + random:NextNumber(-(yJitter or 0.3), yJitter or 0.4)
		local piece = tryWall(state, wall, random:NextNumber(lo, hi), y0, style, tilt(random, style), name, options)
		if piece then
			return piece
		end
	end
	return nil
end

local function roomsWhere(layout: Layout, where: Where): { Room }
	local out: { Room } = {}
	for _, room in layout.rooms do
		local kind = room.kind
		local area = room.rect.w * room.rect.d
		local ok = false
		if where == "Hall" then
			ok = kind == "Corridor" or ((kind == "Storage" or kind == "Boiler") and area >= 2000)
		elseif where == "Service" then
			ok = kind == "Boiler" or kind == "Storage" or kind == "Lab"
		else
			ok = kind == "Restroom" or kind == "LockerRoom" or kind == "Pool" or kind == "Corridor"
		end
		if ok then
			table.insert(out, room)
		end
	end
	return out
end

local function shuffled<T>(list: { T }, random: Random): { T }
	local out = table.clone(list)
	MathUtil.shuffle(out, random)
	return out
end

-- The rooms a sign over their door names.
local function wayfinding(room: Room): (string?, Color3)
	local kind = room.kind
	if kind == "Boiler" then
		return "Prop.Sign.Boiler", BOILER_RED
	elseif kind == "Gym" and room.rect.w * room.rect.d >= 4000 then
		return "Prop.Sign.Gym", SCHOOL_GREEN
	elseif kind == "LockerRoom" then
		return "Prop.Sign.Lockers", SCHOOL_GREEN
	elseif kind == "Pool" then
		return "Prop.Sign.Pool", POOL_BLUE
	elseif kind == "Office" and string.find(room.id, "MainOffice", 1, true) then
		return "Prop.Sign.Office", SCHOOL_GREEN
	end
	return nil, SCHOOL_GREEN
end

local function isPassage(door: Door): boolean
	return door.kind == "Door" or door.kind == "Doorway" or door.kind == "Ajar"
end

--------------------------------------------------------------------------------
-- Plan
--------------------------------------------------------------------------------

local function planRoomPlates(state: State, random: Random)
	local rooms = state.info.rooms
	local done: { [string]: boolean } = {}
	for _, door in state.layout.doors do
		if not isPassage(door) then
			continue
		end
		for index = 1, 2 do
			local room, other = rooms[door.rooms[index]], rooms[door.rooms[3 - index]]
			if not (room and other) or done[room.id] or other.kind ~= "Corridor" then
				continue
			end
			if room.kind ~= "Classroom" and room.kind ~= "Lab" then
				continue
			end
			local number = roomNumber(room)
			if not number then
				continue
			end
			local style = STYLES.RoomPlate
			local text = Strings.get(if room.kind == "Lab" then "Prop.Sign.Lab" else "Prop.Sign.Room", number)
			local piece = besideDoor(state, other, door, style, style.y, random, "Plate_" .. room.id)
			if piece then
				done[room.id] = true
				addPiece(state, piece, function(part: BasePart)
					paintPlate(part, style, text, CREAM)
				end)
			end
		end
	end
end

local function planWayfinding(state: State, random: Random)
	local rooms = state.info.rooms
	local done: { [string]: boolean } = {}
	for _, door in state.layout.doors do
		local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
		if not (a and b) then
			continue
		end
		if door.kind == "Airlock" then
			-- STAIRS beside the fire door, on the side away from the vestibule
			local outside = if a.kind == "Airlock" then b else a
			local style = STYLES.Stairs
			local piece = besideDoor(
				state,
				outside,
				door,
				style,
				style.y,
				random,
				"Stairs_" .. door.id,
				{ color = SCHOOL_GREEN },
				1.3
			)
			if not piece then
				piece = nearDoor(state, outside, door, style, random, "Stairs_" .. door.id, { color = SCHOOL_GREEN })
			end
			if piece then
				local text = Strings.get("Prop.Sign.Stairs")
				addPiece(state, piece, function(part: BasePart)
					paintPlate(part, style, text, CREAM)
				end)
			end
			continue
		end
		local edge = LayoutSchema.sharedEdge(a.rect, b.rect)
		if not (edge and isPassage(door)) then
			continue
		end
		for index = 1, 2 do
			local target, other = if index == 1 then a else b, if index == 1 then b else a
			local key, plate = wayfinding(target)
			if not key or done[target.id] or other.kind == "Chase" or other.kind == target.kind then
				continue
			end
			local style = STYLES.Wayfinding
			local wall = wallOn(state.info, other, edge.axis, edge.coord)
			if not wall then
				continue
			end
			-- over the door if the head leaves room under the ceiling, else beside it
			local y0 = LayoutSchema.doorHeight(door) + 0.75
			local piece = tryWall(state, wall, door.at, y0, style, tilt(random, style), "Way_" .. target.id, {
				color = plate,
			})
			if not piece then
				piece = besideDoor(state, other, door, style, 7.2, random, "Way_" .. target.id, { color = plate })
			end
			if piece then
				done[target.id] = true
				local text = Strings.get(key)
				addPiece(state, piece, function(part: BasePart)
					paintPlate(part, style, text, CREAM)
				end)
			end
		end
	end
	-- The science wing names itself along its corridors.
	if state.layout.id == "Level2_ScienceHall" then
		local style = STYLES.Wayfinding
		local placed = 0
		for _, room in shuffled(roomsWhere(state.layout, "Hall"), random) do
			if placed >= 2 then
				break
			end
			local piece = anywhere(state, room, style, random, "Way_Science" .. placed, { color = SCHOOL_GREEN }, 0.0)
			if piece then
				placed += 1
				local text = Strings.get("Prop.Sign.Science")
				addPiece(state, piece, function(part: BasePart)
					paintPlate(part, style, text, CREAM)
				end)
			end
		end
	end
end

-- A QUARANTINE sheet taped beside the door of a storeroom or lab, on the outside.
local function planQuarantine(state: State, random: Random, index: number): boolean
	local rooms = state.info.rooms
	local style = STYLES.Quarantine
	for _, door in shuffled(state.layout.doors, random) do
		if not (isPassage(door) or door.kind == "Boarded") then
			continue
		end
		for i = 1, 2 do
			local inside, outside = rooms[door.rooms[i]], rooms[door.rooms[3 - i]]
			if not (inside and outside) then
				continue
			end
			if not (inside.kind == "Storage" or inside.kind == "Lab") or outside.kind == "Chase" then
				continue
			end
			if outside.kind == "Storage" or outside.kind == "Lab" then
				continue
			end
			local piece = besideDoor(
				state,
				outside,
				door,
				style,
				style.y,
				random,
				string.format("Quarantine_%d", index),
				paperOptions(random)
			)
			if piece then
				local tint = wallColor(outside)
				addPiece(state, piece, function(part: BasePart)
					paintQuarantine(part, style, random, tint)
				end)
				return true
			end
		end
	end
	return false
end

local function planPapers(state: State, random: Random)
	local requests = LEVEL_PAPERS[state.layout.id]
	if not requests then
		return
	end
	local scrawls = 0
	for _, request in requests do
		local style = STYLES[request.design]
		for n = 1, request.count do
			if request.design == "Quarantine" then
				planQuarantine(state, random, n)
				continue
			end
			local name = string.format("%s_%d", request.design, n)
			local options: Geometry.PartOptions? = if style.paper then paperOptions(random) else nil
			if request.design == "Scrawl" then
				options = { transparency = 1 }
			end
			for _, room in shuffled(roomsWhere(state.layout, request.where), random) do
				local piece = anywhere(state, room, style, random, name, options)
				if not piece then
					continue
				end
				local tint = wallColor(room)
				local design = request.design
				if design == "Poster" then
					local text = Strings.get("Prop.Sign.NoRunning")
					addPiece(state, piece, function(part: BasePart)
						paintPoster(part, style, text, random, tint)
					end)
				elseif design == "Notice" then
					local text = Strings.get("Prop.Sign.Assembly")
					addPiece(state, piece, function(part: BasePart)
						paintNotice(part, style, text, random, tint)
					end)
				elseif design == "Missing" then
					local text = Strings.get("Prop.Sign.Missing")
					addPiece(state, piece, function(part: BasePart)
						paintMissing(part, style, text, random, tint)
					end)
				elseif design == "Caution" then
					addPiece(state, piece, function(part: BasePart)
						paintCaution(part, style)
					end)
				else
					scrawls += 1
					local text = Strings.get(if scrawls % 2 == 1 then "Prop.Sign.Help" else "Prop.Sign.Hide")
					addPiece(state, piece, function(part: BasePart)
						paintScrawl(part, style, text, random)
					end)
				end
				break
			end
		end
	end
end

-- WET FLOOR A-frames: two yellow boards leaning together, standing near a wall of a wet room, never on water.
local BOARD = Vector2.new(1.15, 2.05)
local BOARD_LEAN = math.rad(13)

local function planWetFloors(state: State, random: Random)
	local count = WET_FLOOR[state.layout.id] or 0
	local placed = 0
	local candidates = shuffled(roomsWhere(state.layout, "Wet"), random)
	if state.layout.id == "Level0_Basement" then
		candidates = shuffled(roomsWhere(state.layout, "Hall"), random)
	end
	local info = state.info
	for _, room in candidates do
		if placed >= count then
			break
		end
		local walls = wallsOf(info, room)
		for _ = 1, SPOT_TRIES do
			local wall = walls[random:NextInteger(1, #walls)]
			local lo, hi = wall.u0 + 1.5, wall.u1 - 1.5
			if hi <= lo then
				continue
			end
			local u = random:NextNumber(lo, hi)
			local out = random:NextNumber(0.9, 1.6)
			local across = wall.face + (if wall.axis == "Z" then wall.normal.Z else wall.normal.X) * out
			local base = info.origin
				+ (if wall.axis == "Z" then Vector3.new(u, 0, across) else Vector3.new(across, 0, u))
			local frame = CFrame.lookAt(base, base + wall.normal)
				* CFrame.Angles(0, math.rad(random:NextNumber(-30, 30)), 0)
			local apex = BOARD.Y * math.cos(BOARD_LEAN)
			local pieces: { Piece } = {}
			for i, lean in { BOARD_LEAN, -BOARD_LEAN } do
				local cframe = frame
					* CFrame.new(0, apex, 0)
					* CFrame.Angles(lean, 0, 0)
					* CFrame.new(0, -BOARD.Y / 2, 0)
				table.insert(
					pieces,
					Kit.block(
						string.format("WetFloor_%d_%d", placed + 1, i),
						cframe,
						Vector3.new(BOARD.X, BOARD.Y, 0.06),
						"HazardYellow",
						"Detail",
						{ castShadow = false }
					)
				)
			end
			if Kit.fits(info, pieces, { room = room.id, margin = 0.3, ground = 0 }) then
				placed += 1
				addPiece(state, pieces[1], function(part: BasePart)
					paintWetFloor(part, BOARD)
				end)
				addPiece(state, pieces[2], function(_part: BasePart) end)
				break
			end
		end
	end
end

-- Static "Signage" for one level. Returns the parts built.
local function buildSignage(ctx: PropKit.StaticContext): number
	local layout = ctx.layout
	local info = Kit.info(layout)
	local state: State = {
		layout = layout,
		info = info,
		blocks = openingBlocks(layout),
		placed = {},
		pieces = {},
		painters = {},
	}
	local random = MathUtil.seededRandom(1, layout.id .. ":signage")
	planRoomPlates(state, random)
	planWayfinding(state, random)
	planPapers(state, random)
	planWetFloors(state, random)
	if #state.pieces == 0 then
		return 0
	end
	local model = PropKit.model(ctx.parent, "Signs_" .. layout.id, CFrame.new(info.origin))
	model:SetAttribute(W.LevelId, layout.id)
	local parts = Kit.realize(model, state.pieces)
	for i, part in parts do
		state.painters[i](part)
	end
	return #parts
end

local SignageBuilder = {}

SignageBuilder.Styles = STYLES

function SignageBuilder.register(registrar: PropKit.Registrar)
	registrar.static("Signage", buildSignage)
end

return table.freeze(SignageBuilder)
