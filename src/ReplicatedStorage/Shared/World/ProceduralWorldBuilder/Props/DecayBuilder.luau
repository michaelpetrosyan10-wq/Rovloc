--!strict
-- DecayBuilder: what years of leaks and neglect did to the rooms (static kind "Decay": once at boot, the same on every
-- server, into <level>.Props as one Model "Decay_<layoutId>").
--
--   * Fallen ceiling: under every dressed hole of a drop ceiling (SchoolShellBuilder.ceilingFalls) the tile that came
--     down lies on the floor, cracked in two now and then, and wiring hangs out of the plenum above it.
--   * Plaster damage: in the plastered rooms the ruin seed picks, a patch of wall above the chair rail has come away:
--     the paint torn back in a pale ring, the hole into the lath (or the brick behind a corridor wall) shaded where the
--     plaster still overhangs it, flakes of paint curling off the wall and crumbs of plaster on the floor below.
--   * Standing water: dark, glossy puddles across the wet rooms (the basement, the pool level, the lobby, restrooms,
--     locker rooms and boiler rooms) and under the worst holes in a ceiling.
--   * Loose paper: sheets of print scattered down the corridors and across the classrooms and offices.
-- Everything here is "Detail" (no collision, no query, no shadow) and flat on the floor or close on a wall, so nothing
-- can block a route; it still goes only where SetDressingBuilder.Kit lets dressing go (never in a doorway, on a grate
-- front, a landing or a spawn) and keeps off the furniture. wallMounts(layout) tells SignageBuilder where the damage is.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

local Finishes = require(script.Parent.Parent.Finishes)
local FurnitureBuilder = require(script.Parent.FurnitureBuilder)
local Geometry = require(script.Parent.Parent.Geometry)
local Palette = require(script.Parent.Parent.Palette)
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
	painters: { [number]: (part: BasePart) -> () },
	mounts: { Mount },
}

type State = {
	layout: Layout,
	info: LevelInfo,
	plan: Plan,
	furniture: { Box },
}

local DecayBuilder = {}

-- Part caps per site.
DecayBuilder.Budget = table.freeze({ Fall = 4, Damage = 5, Puddle = 2, Paper = 1 })

local DAMP_LAYOUTS: { [string]: boolean } = { Level0_Basement = true, Level4_FloodedPool = true, Lobby = true }
local WET_KINDS: { [string]: boolean } = { Restroom = true, LockerRoom = true, Boiler = true, Pool = true }
local DRY_KINDS: { [string]: boolean } = { Airlock = true, Stairwell = true, Chase = true, Roof = true }
local DAMAGE_KINDS: { [string]: boolean } = { Corridor = true, Classroom = true, Office = true }
local PAPER_COUNT: { [string]: { number } } = {
	Corridor = { 2, 4 },
	Classroom = { 0, 2 },
	Office = { 1, 2 },
	Lab = { 0, 1 },
	Storage = { 0, 1 },
}

local LATH = Color3.fromRGB(96, 72, 46)
local LATH_GAP = Color3.fromRGB(18, 14, 11)
local BRICK = Color3.fromRGB(96, 52, 40)
local MORTAR = Color3.fromRGB(116, 110, 96)
local VOID_SHADE = Color3.fromRGB(8, 7, 6)
local PRINT = Color3.fromRGB(62, 64, 74)
local STAIN = Color3.fromRGB(110, 86, 48)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function between(random: Random, a: number, b: number): number
	return random:NextNumber(a, b)
end

local function ry(degrees: number): CFrame
	return CFrame.Angles(0, math.rad(degrees), 0)
end

local function scaled(color: Color3, f: number): Color3
	return Color3.new(math.clamp(color.R * f, 0, 1), math.clamp(color.G * f, 0, 1), math.clamp(color.B * f, 0, 1))
end

local function overlapsAny(info: LevelInfo, pieces: { Piece }, boxes: { Box }): boolean
	for _, piece in pieces do
		local a = Kit.localBox(info, piece)
		for _, b in boxes do
			if
				math.min(a.x1, b.x1) - math.max(a.x0, b.x0) > 0.01
				and math.min(a.z1, b.z1) - math.max(a.z0, b.z0) > 0.01
				and math.min(a.y1, b.y1) - math.max(a.y0, b.y0) > -0.05
			then
				return true
			end
		end
	end
	return false
end

local function add(state: State, pieces: { Piece }, painters: { [Piece]: (part: BasePart) -> () }?)
	local plan = state.plan
	for _, piece in pieces do
		table.insert(plan.pieces, piece)
		local painter = painters and painters[piece]
		if painter then
			plan.painters[#plan.pieces] = painter
		end
	end
end

-- A flat oval on the floor at world `centre` (its bottom on the floor), `a` x `b` across, turned `yaw` degrees.
local function oval(
	name: string,
	centre: Vector3,
	a: number,
	b: number,
	yaw: number,
	key: string,
	options: Geometry.PartOptions
): Piece
	local thickness = 0.02
	return {
		name = name,
		shape = "Cylinder",
		cframe = CFrame.new(centre + Vector3.new(0, thickness / 2, 0)) * ry(yaw) * CFrame.Angles(0, 0, math.rad(90)),
		size = Vector3.new(thickness, a, b),
		key = key,
		role = "Detail",
		options = options,
	}
end

--------------------------------------------------------------------------------
-- Fallen ceiling tiles and wiring
--------------------------------------------------------------------------------

local function planFalls(state: State)
	local info = state.info
	local floorY = info.origin.Y
	for index, fall in SchoolShellBuilder.ceilingFalls(state.layout) do
		local room = info.rooms[fall.room]
		if not room then
			continue
		end
		local random = MathUtil.seededRandom(1, string.format("%s:fall:%s:%d", state.layout.id, fall.room, index))
		local name = string.format("Fall_%s_%d", fall.room, index)
		local tileColor = scaled(Palette.get("CeilingTile").color, between(random, 0.8, 0.95))
		local landing =
			Vector3.new(fall.centre.X + between(random, -0.7, 0.7), floorY, fall.centre.Z + between(random, -0.7, 0.7))
		local yaw = between(random, -30, 30)
		local tilt = CFrame.Angles(math.rad(between(random, -5, 5)), 0, math.rad(between(random, -4, 4)))
		local debris: { Piece } = {}
		if random:NextNumber() < 0.45 then
			-- broken across: two halves, the second skewed off the first
			local half = Vector3.new(fall.size.X / 2 - 0.12, 0.1, fall.size.Y - 0.2)
			table.insert(
				debris,
				Kit.block(
					name .. "_TileA",
					CFrame.new(landing) * ry(yaw) * CFrame.new(-half.X / 2, 0.06, 0) * tilt,
					half,
					"CeilingTile",
					"Detail",
					{ color = tileColor }
				)
			)
			table.insert(
				debris,
				Kit.block(
					name .. "_TileB",
					CFrame.new(landing)
						* ry(yaw + between(random, 12, 35))
						* CFrame.new(half.X / 2 + 0.25, 0.06, between(random, -0.3, 0.3)),
					half,
					"CeilingTile",
					"Detail",
					{ color = scaled(tileColor, 0.92) }
				)
			)
		else
			table.insert(
				debris,
				Kit.block(
					name .. "_Tile",
					CFrame.new(landing + Vector3.new(0, 0.06, 0)) * ry(yaw) * tilt,
					Vector3.new(fall.size.X - 0.2, 0.1, fall.size.Y - 0.2),
					"CeilingTile",
					"Detail",
					{ color = tileColor }
				)
			)
		end
		for _, piece in debris do
			local lo = Kit.bounds(piece)
			Kit.offset({ piece }, Vector3.new(0, floorY + 0.004 - lo.Y, 0))
		end
		if
			Kit.fits(info, debris, { room = room.id, ground = 0, margin = 0.2 })
			and not overlapsAny(info, debris, state.furniture)
		then
			add(state, debris)
		end
		-- wiring out of the plenum: a dangling run, kinked part way down now and then
		if random:NextNumber() < 0.65 then
			local top = fall.centre
				+ Vector3.new(
					between(random, -0.35, 0.35) * fall.size.X,
					0.05,
					between(random, -0.35, 0.35) * fall.size.Y
				)
			local drop = between(random, 1.4, 3.2)
			local mid = top + Vector3.new(between(random, -0.5, 0.5), -drop, between(random, -0.5, 0.5))
			local wires: { Piece } = { Kit.cylinder(name .. "_Wire", top, mid, 0.08, "Cable", "Detail") }
			if random:NextNumber() < 0.45 then
				local tail = mid
					+ Vector3.new(between(random, -0.8, 0.8), -between(random, 0.5, 1.2), between(random, -0.8, 0.8))
				table.insert(wires, Kit.cylinder(name .. "_WireTail", mid, tail, 0.08, "Cable", "Detail"))
			end
			if Kit.fits(info, wires, { room = room.id, margin = 0.2 }) then
				add(state, wires)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Plaster damage
--------------------------------------------------------------------------------

local function paintDamage(part: BasePart, random: Random, brick: boolean, wallColor: Color3)
	local gui = SurfaceArt.gui(part, Enum.NormalId.Front, { name = "Damage", pixelsPerStud = 18, maxDistance = 70 })
	local peel = SurfaceArt.frame(gui, "Peel", 0, 0, 1, 1, scaled(wallColor, between(random, 1.12, 1.25)), 0.05, 1)
	peel.Rotation = between(random, -6, 6)
	local peelCorner = Instance.new("UICorner")
	peelCorner.CornerRadius = UDim.new(0.45, 0)
	peelCorner.Parent = peel
	local x0, y0 = between(random, 0.12, 0.2), between(random, 0.14, 0.24)
	local hole = if brick
		then SurfaceArt.stripes(gui, "Hole", x0, y0, 1 - x0 * 2, 1 - y0 * 2, 4, 0.78, BRICK, MORTAR, 0, 2)
		else SurfaceArt.stripes(gui, "Hole", x0, y0, 1 - x0 * 2, 1 - y0 * 2, 4, 0.55, LATH, LATH_GAP, 0, 2)
	hole.Rotation = between(random, -5, 5)
	local holeCorner = Instance.new("UICorner")
	holeCorner.CornerRadius = UDim.new(0.38, 0)
	holeCorner.Parent = hole
	local rim = Instance.new("UIStroke")
	rim.Color = scaled(wallColor, 0.45)
	rim.Thickness = 2
	rim.Transparency = 0.2
	rim.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	rim.Parent = hole
	if brick then
		for course = 0, 3 do
			local x = between(random, 0.2, 0.75)
			SurfaceArt.frame(hole, "Joint", x, course / 4, 0.025, 0.25, MORTAR, 0.1, 3)
		end
	end
	local shade = SurfaceArt.edgeBand(hole, "Shade", true, 0, 0, VOID_SHADE, 0.85, 4)
	shade.Size = UDim2.fromScale(1, 0.55)
	local shadeCorner = Instance.new("UICorner")
	shadeCorner.CornerRadius = UDim.new(0.38, 0)
	shadeCorner.Parent = shade
end

local function planDamage(state: State, room: Room, wallKey: string, random: Random)
	local info = state.info
	local ruin = Finishes.ruin(state.layout.id, room.id)
	local count = math.floor(ruin * 2.4)
		+ (if room.kind == "Corridor" and room.rect.w + room.rect.d >= 90 then 1 else 0)
	if count <= 0 then
		return
	end
	local walls = WallPlanner.walls(info, room)
	if #walls == 0 then
		return
	end
	local ceiling = SchoolShellBuilder.ceilingBottom(state.layout, room)
	local lowest = Finishes.RailTop + 0.45
	local wallColor = Palette.get(wallKey).color
	local brick = room.kind == "Corridor"
	local extra = table.clone(FurnitureBuilder.plan(state.layout).mounts)
	for site = 1, count do
		for _ = 1, 8 do
			local wall = walls[random:NextInteger(1, #walls)]
			local w, h = between(random, 2.2, 3.6), between(random, 1.6, 2.6)
			local yMax = ceiling - 0.8 - h
			if yMax < lowest then
				break
			end
			local y0 = between(random, lowest, math.min(yMax, lowest + 3))
			local y1 = y0 + h
			local runs = WallPlanner.free(wall, WallPlanner.taken(state.layout, wall, extra), y0 - 0.6, y1 + 0.6, w + 1)
			if #runs == 0 then
				continue
			end
			local run = runs[random:NextInteger(1, #runs)]
			local u = between(random, run.u0 + w / 2 + 0.5, run.u1 - w / 2 - 0.5)
			local name = string.format("Damage_%s_%d", room.id, site)
			local carrier = Kit.block(
				name,
				WallPlanner.cframe(info, wall, u, y0 + h / 2, 0.012),
				Vector3.new(w, h, 0.02),
				wallKey,
				"Detail",
				{ transparency = 1 }
			)
			local pieces: { Piece } = { carrier }
			for flap = 1, random:NextInteger(1, 2) do
				local fw, fh = between(random, 0.5, 1.1), between(random, 0.35, 0.75)
				local hinge = WallPlanner.cframe(
					info,
					wall,
					u + between(random, -0.3, 0.3) * w,
					y1 - h * between(random, 0.12, 0.3),
					0.02
				)
				table.insert(
					pieces,
					Kit.block(
						string.format("%s_Flap%d", name, flap),
						hinge
							* CFrame.Angles(math.rad(between(random, 18, 40)), 0, math.rad(between(random, -12, 12)))
							* CFrame.new(0, -fh / 2, -0.015),
						Vector3.new(fw, fh, 0.03),
						"PlasterFlap",
						"Detail",
						{ color = scaled(wallColor, between(random, 1.05, 1.2)) }
					)
				)
			end
			if not Kit.fits(info, pieces, { room = room.id, margin = -0.05 }) then
				continue
			end
			local crumbs: { Piece } = {}
			for crumb = 1, random:NextInteger(1, 2) do
				local s = between(random, 0.25, 0.5)
				local at =
					WallPlanner.floorPoint(info, wall, u + between(random, -0.4, 0.4) * w, between(random, 0.35, 0.9))
				table.insert(
					crumbs,
					Kit.block(
						string.format("%s_Crumb%d", name, crumb),
						CFrame.new(at + Vector3.new(0, s * 0.3, 0))
							* CFrame.Angles(between(random, 0, 1), between(random, 0, 6), between(random, 0, 1)),
						Vector3.new(s, s * 0.6, s * between(random, 0.6, 1)),
						"PlasterFlap",
						"Detail",
						{ color = scaled(wallColor, between(random, 0.8, 1.05)) }
					)
				)
			end
			for _, piece in crumbs do
				local lo = Kit.bounds(piece)
				Kit.offset({ piece }, Vector3.new(0, info.origin.Y + 0.004 - lo.Y, 0))
			end
			if
				Kit.fits(info, crumbs, { room = room.id, ground = 0, margin = 0.1 })
				and not overlapsAny(info, crumbs, state.furniture)
			then
				for _, piece in crumbs do
					table.insert(pieces, piece)
				end
			end
			local seed = MathUtil.hash(state.layout.id .. ":" .. name)
			add(state, pieces, {
				[carrier] = function(part: BasePart)
					paintDamage(part, Random.new(seed), brick, wallColor)
				end,
			})
			local mount = WallPlanner.mount(wall, u - w / 2 - 0.4, u + w / 2 + 0.4, y0 - 0.3, y1 + 0.3)
			table.insert(state.plan.mounts, mount)
			table.insert(extra, mount)
			break
		end
	end
end

--------------------------------------------------------------------------------
-- Puddles and paper
--------------------------------------------------------------------------------

local PUDDLE_OPTIONS: Geometry.PartOptions = { reflectance = 0.32, transparency = 0.1 }

local function planPuddles(state: State, room: Room, count: number, random: Random, near: Vector3?)
	local info = state.info
	local inner = info.inner[room.id]
	if not inner then
		return
	end
	for index = 1, count do
		for _ = 1, 6 do
			local centre = if near and index == 1
				then Vector3.new(
					near.X + between(random, -1.5, 1.5),
					info.origin.Y + 0.004,
					near.Z + between(random, -1.5, 1.5)
				)
				else info.origin + Vector3.new(
					between(random, inner.x + 2, inner.x + inner.w - 2),
					0.004,
					between(random, inner.z + 2, inner.z + inner.d - 2)
				)
			local a = between(random, 2.2, 5)
			local yaw = between(random, 0, 180)
			local name = string.format("Puddle_%s_%d", room.id, index)
			local pieces: { Piece } =
				{ oval(name, centre, a, a * between(random, 0.45, 0.8), yaw, "Puddle", PUDDLE_OPTIONS) }
			if random:NextNumber() < 0.5 then
				local offset = CFrame.Angles(0, math.rad(yaw), 0)
					:VectorToWorldSpace(Vector3.new(a * 0.45, 0.002, between(random, -0.3, 0.3)))
				local b = a * between(random, 0.3, 0.5)
				table.insert(
					pieces,
					oval(
						name .. "_Spill",
						centre + offset,
						b,
						b * between(random, 0.5, 0.9),
						yaw + between(random, -40, 40),
						"Puddle",
						PUDDLE_OPTIONS
					)
				)
			end
			if Kit.fits(info, pieces, { room = room.id, ground = 0, margin = 0.4 }) then
				add(state, pieces)
				break
			end
		end
	end
end

local function paintPaper(part: BasePart, random: Random)
	local gui = SurfaceArt.gui(part, Enum.NormalId.Top, { name = "Print", pixelsPerStud = 40, maxDistance = 40 })
	local paper = part.Color
	SurfaceArt.stripes(gui, "Lines", 0.12, 0.16, 0.76, 0.7, 4, 0.2, PRINT, paper, 0.25, 1)
	if random:NextNumber() < 0.4 then
		SurfaceArt.stain(gui, between(random, 0.3, 0.7), between(random, 0.3, 0.7), 0.5, 0.4, STAIN, 0.7, nil, 2)
	end
	SurfaceArt.grime(gui, Color3.fromRGB(70, 60, 40), between(random, 0.2, 0.45), random:NextNumber() < 0.5, 3)
end

local function planPaper(state: State, room: Room, random: Random)
	local range = PAPER_COUNT[room.kind]
	if not range then
		return
	end
	local info = state.info
	local inner = info.inner[room.id]
	if not inner then
		return
	end
	for index = 1, random:NextInteger(range[1], range[2]) do
		for _ = 1, 5 do
			local at = info.origin
				+ Vector3.new(
					between(random, inner.x + 1, inner.x + inner.w - 1),
					0.008 + index * 0.003,
					between(random, inner.z + 1, inner.z + inner.d - 1)
				)
			local paperColor = scaled(Palette.get("PaperSheet").color, between(random, 0.75, 1.02))
			local sheet = Kit.block(
				string.format("Paper_%s_%d", room.id, index),
				CFrame.new(at) * ry(between(random, 0, 360)) * CFrame.Angles(math.rad(between(random, -2, 2)), 0, 0),
				Vector3.new(0.78, 0.012, 1.02),
				"PaperSheet",
				"Detail",
				{ color = paperColor }
			)
			if Kit.fits(info, { sheet }, { room = room.id, ground = 0, margin = 0.3 }) then
				local seed = MathUtil.hash(state.layout.id .. ":" .. sheet.name)
				add(state, { sheet }, {
					[sheet] = function(part: BasePart)
						paintPaper(part, Random.new(seed))
					end,
				})
				break
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Plan and build
--------------------------------------------------------------------------------

local planCache: { [Layout]: Plan } = setmetatable({}, { __mode = "k" }) :: any

-- Everything decay does to `layout` (pure, seeded per layout; cached).
function DecayBuilder.plan(layout: Layout): Plan
	local cached = planCache[layout]
	if cached then
		return cached
	end
	local state: State = {
		layout = layout,
		info = Kit.info(layout),
		plan = { pieces = {}, painters = {}, mounts = {} },
		furniture = FurnitureBuilder.plan(layout).footprints,
	}
	planFalls(state)
	local falls: { [string]: Vector3 } = {}
	for _, fall in SchoolShellBuilder.ceilingFalls(layout) do
		falls[fall.room] = falls[fall.room] or fall.centre
	end
	for _, room in layout.rooms do
		local random = MathUtil.seededRandom(1, layout.id .. ":decay:" .. room.id)
		local wallKey = SchoolShellBuilder.wallKey(room)
		if DAMAGE_KINDS[room.kind] and string.sub(wallKey, 1, 7) == "Plaster" then
			planDamage(state, room, wallKey, random)
		end
		local ruin = Finishes.ruin(layout.id, room.id)
		local near = if ruin > 0.7 then falls[room.id] else nil
		if not DRY_KINDS[room.kind] and (DAMP_LAYOUTS[layout.id] or WET_KINDS[room.kind] or near) then
			planPuddles(state, room, if ruin > 0.6 then 2 else 1, random, near)
		end
		planPaper(state, room, random)
	end
	planCache[layout] = state.plan
	return state.plan
end

-- Where the plaster damage of `layout` is on its walls (for SignageBuilder).
function DecayBuilder.wallMounts(layout: Layout): { Mount }
	return DecayBuilder.plan(layout).mounts
end

local function buildDecay(ctx: PropKit.StaticContext): number
	local layout = ctx.layout
	local plan = DecayBuilder.plan(layout)
	if #plan.pieces == 0 then
		return 0
	end
	local info = Kit.info(layout)
	local model = PropKit.model(ctx.parent, "Decay_" .. layout.id, CFrame.new(info.origin))
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

function DecayBuilder.register(registrar: PropKit.Registrar)
	registrar.static("Decay", buildDecay)
end

return table.freeze(DecayBuilder)
