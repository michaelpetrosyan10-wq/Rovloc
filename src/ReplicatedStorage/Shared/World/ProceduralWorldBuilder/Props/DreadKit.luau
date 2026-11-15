--!strict
-- DreadKit: the reusable dread dressing. What the surroundings say, without ever showing it: something very tall came
-- through here and the people in this building ran (docs/design/game-spec-v2.md 2.1, 2.8; DreadConfig).
--
--   He was here   long claw gouges high on the walls (8 to 11 studs up where the room allows, else just under its
--                 ceiling: he stoops in the low runs) and across the ceilings of the runs he walks; door frames he
--                 forced: the lintel bowed out and the plaster cracked from its corners; a trail of pale porcelain dust
--                 and shards (the mask's material) down his patrol loops, and one larger fragment
--   They ran      backpacks, single shoes and phones with cracked, still faintly lit screens dropped along the runs;
--                 chairs and desks knocked over; a barricade of desks pushed back from the inside of a door that did
--                 not hold; a locker door torn off; a trophy case smashed; two coats left on their hooks
--   Writing       scrawled lines (DreadConfig.Writing: marker, chalk, 1989 paint, scratched), tally marks, the lockdown
--                 notice, a child's drawing of the tall man; wall clocks, every one stopped at 3:31
--   Decay         water stains spreading from ceiling corners (each with a drip and a puddle), black mould, paint
--                 peeled in long strips, cobwebs, dead flies on a sill; dead fixtures' wiring hanging out with a spark
--                 now and then; soot round the bulbs of the circuits it marks dying (their flicker group and style are
--                 attributes the website's lighting reads: how an already-flickering circuit flickers, never its light)
--
-- DreadKit.plan(layout, options) places all of it from the layout's own rooms, walls, doors, lights and patrol loops
-- (PatrolWaypoint anchors, or options.routes), drawing only from the world Rng (Shared/Util/Rng) keyed by the layout,
-- so the same world comes out on Roblox and in the web's export. options.density (0..1) scales every count. Another
-- stage calls it the same way (DreadBuilder does for DreadConfig.Levels):
--
--   local plan = DreadKit.plan(layout, { density = 0.8 })
--   DreadKit.build(parentFolder, layout, plan)
--
-- The rules every piece keeps: it never collides, is never queried or touched and casts no shadow (cosmetic, I3); it
-- stays out of every clearance SetDressingBuilder.Kit keeps (doorways and the arcs their leaves sweep, grate fronts,
-- landings, spawns, gameplay anchors) and out of DreadKit.clearances (every hiding spot's niche, every other anchor's
-- reach); it keeps to its room and off the furniture, the signs' and the decay's wall spots and the junction plates.
-- At most DreadConfig.Budget.Parts parts per floor, of them at most Budget.Signature signature parts (no Detail
-- attribute: drawn on every tier, Potato included); everything else is Detail 1..3. Decals are preferred to geometry.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local DreadConfig = require(ReplicatedStorage.Shared.Config.DreadConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Rng = require(ReplicatedStorage.Shared.Util.Rng)
local Tags = require(ReplicatedStorage.Shared.Tags)

local DecayBuilder = require(script.Parent.DecayBuilder)
local DreadArt = require(script.Parent.DreadArt)
local FurnitureBuilder = require(script.Parent.FurnitureBuilder)
local Geometry = require(script.Parent.Parent.Geometry)
local Palette = require(script.Parent.Parent.Palette)
local PropKit = require(script.Parent.PropKit)
local SchoolShellBuilder = require(script.Parent.Parent.SchoolShellBuilder)
local SetDressingBuilder = require(script.Parent.SetDressingBuilder)
local WallPlanner = require(script.Parent.WallPlanner)

type Rng = Rng.Rng
type Layout = LayoutSchema.LevelLayout
type Room = LayoutSchema.Room
type Anchor = LayoutSchema.Anchor
type Piece = SetDressingBuilder.Piece
type Box = SetDressingBuilder.Box
type LevelInfo = SetDressingBuilder.LevelInfo
type Wall = WallPlanner.Wall
type Mount = WallPlanner.Mount
type Span = WallPlanner.Span

local Kit = SetDressingBuilder.Kit
local W = Attributes.World

-- Detail levels
local LOOK, MEDIUM, SMALL = 1, 2, 3

export type Options = {
	density: number?, -- 0..1 (default 1)
	kinds: { string }?, -- only these kinds of item (default every kind)
	routes: { { Vector3 } }?, -- the walking loops to dress (level-local points); default: the PatrolWaypoint loops
}

-- One placed thing: its pieces (world), their painters by piece index, and what the build stamps on them.
export type Item = {
	kind: string,
	pieces: { Piece },
	painters: { [number]: (part: BasePart) -> () },
	tags: { [number]: string },
	attributes: { [number]: { [string]: any } },
}

export type Plan = {
	layoutId: string,
	density: number,
	items: { Item },
	parts: number,
	signature: number,
	decals: number,
	counts: { [string]: number }, -- items per kind
	mounts: { Mount }, -- the kit's wall spots (SignageBuilder keeps clear of them)
	texts: { string }, -- every line of writing placed
}

-- A box dressing keeps out of (level-local).
export type Clearance = Box & { kind: string }

type State = {
	layout: Layout,
	info: LevelInfo,
	density: number,
	plan: Plan,
	random: Rng,
	walls: { [string]: { Wall } },
	taken: { Mount }, -- wall spots of other builders and of the kit
	clear: { Clearance },
	boxes: { Box }, -- the kit's floor footprints and the furniture's
	routeRooms: { Room },
	routePoints: { { room: Room, x: number, z: number } },
	keepRooms: { Room },
	stubs: { [string]: boolean }, -- rooms opening onto a vestibule or a stairwell (their walls carry the STAIRS signs)
	kinds: { [string]: boolean }?, -- the kinds allowed (nil: all)
	serial: number,
}

local DreadKit = {}

DreadKit.Budget = DreadConfig.Budget

-- Rooms the kit dresses: where players walk (never the ground between runs, crawlways, ducts, gaps or landings).
local WALK_KINDS: { [string]: boolean } = {
	Tunnel = true,
	Gallery = true,
	Corridor = true,
	Classroom = true,
	Office = true,
	Storage = true,
	Boiler = true,
	Restroom = true,
	LobbyHall = true,
}
local RUN_KINDS: { [string]: boolean } = { Tunnel = true, Gallery = true, Corridor = true }
local KEEP_KINDS: { [string]: boolean } =
	{ Classroom = true, Office = true, Storage = true, Boiler = true, Restroom = true, LobbyHall = true }

-- Hiding spots: the niche in front of each (across, behind, in front, height).
local HIDE_CLEAR = { half = 2.8, back = 3.2, front = 4.8, top = 9 }
-- Every other anchor's reach (a prompt, a pickup, a spawn): a box this wide round it.
local ANCHOR_REACH = { half = 2, top = 8 }
local REACH_SKIP: { [string]: boolean } = { PatrolWaypoint = true, Clutter = true, Corpse = true, DripPipe = true }
local HIDE_KINDS: { [string]: boolean } = { Barrel = true, Cabinet = true, Locker = true }

local WALL_OUT = 0.035 -- decal hosts stand this far off the wall face
local HOST_DEPTH = 0.02
-- His claw marks: the strokes start where his hands reach (up to GOUGE_TOP over the floor, or the ceiling of a low run)
-- and drag down to GOUGE_LOW at the least.
local GOUGE_LOW, GOUGE_TOP = 4.6, 11

local PORCELAIN = Color3.fromRGB(234, 230, 220)
local PORCELAIN_DUST = Color3.fromRGB(214, 210, 200)
local PHONE_GLOW = Color3.fromRGB(58, 74, 96)
local BAG_COLORS: { Color3 } = {
	Color3.fromRGB(38, 52, 104),
	Color3.fromRGB(30, 92, 88),
	Color3.fromRGB(84, 52, 110),
	Color3.fromRGB(150, 64, 40),
}
local SHOE_COLORS: { Color3 } =
	{ Color3.fromRGB(220, 218, 210), Color3.fromRGB(34, 34, 38), Color3.fromRGB(64, 84, 120) }
local COAT_COLORS: { Color3 } = { Color3.fromRGB(26, 30, 40), Color3.fromRGB(40, 42, 32), Color3.fromRGB(44, 30, 30) }
local LOCKER_PAINT: { Color3 } = { Color3.fromRGB(64, 82, 72), Color3.fromRGB(58, 70, 86), Color3.fromRGB(88, 88, 82) }

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function between(random: Rng, a: number, b: number): number
	return random:NextNumber(a, b)
end

local function pick<T>(random: Rng, list: { T }): T
	return list[random:NextInteger(1, #list)]
end

local function shuffled<T>(random: Rng, list: { T }): { T }
	local out = table.clone(list)
	Rng.shuffle(out, random)
	return out
end

local function ry(degrees: number): CFrame
	return CFrame.Angles(0, math.rad(degrees), 0)
end

local function count(state: State, base: number): number
	return math.floor(base * state.density + 0.5)
end

local function boxOverlap(a: Box, b: Box, gap: number?): boolean
	local g = gap or 0
	return math.min(a.x1, b.x1) - math.max(a.x0, b.x0) > -g
		and math.min(a.z1, b.z1) - math.max(a.z0, b.z0) > -g
		and math.min(a.y1, b.y1) - math.max(a.y0, b.y0) > -g
end

local function detail(piece: Piece, level: number?): Piece
	piece.detail = level
	return piece
end

local function host(name: string, cframe: CFrame, w: number, h: number, key: string, level: number?): Piece
	return detail(
		Kit.block(name, cframe, Vector3.new(w, h, HOST_DEPTH), key, "Detail", { transparency = 1, castShadow = false }),
		level
	)
end

local function nextName(state: State, kind: string): string
	state.serial += 1
	return string.format("Dread%s_%s_%03d", kind, state.layout.id, state.serial)
end

--------------------------------------------------------------------------------
-- Clearances
--------------------------------------------------------------------------------

local clearCache: { [Layout]: { Clearance } } = setmetatable({}, { __mode = "k" }) :: any

-- The boxes the kit keeps out of beyond SetDressingBuilder.Kit's zones: each hiding spot's niche (the hider steps in
-- and out there) and a reach round every other gameplay anchor (pickups, prompts, spawns, traps).
function DreadKit.clearances(layout: Layout): { Clearance }
	local cached = clearCache[layout]
	if cached then
		return cached
	end
	local out: { Clearance } = {}
	for _, anchor in layout.anchors do
		if REACH_SKIP[anchor.kind] then
			continue
		end
		local frame = SchoolShellBuilder.anchorLocalCFrame(anchor)
		local x0, x1, z0, z1, top
		if HIDE_KINDS[anchor.kind] then
			x0, x1, z0, z1, top = -HIDE_CLEAR.half, HIDE_CLEAR.half, -HIDE_CLEAR.front, HIDE_CLEAR.back, HIDE_CLEAR.top
		else
			x0, x1, z0, z1, top =
				-ANCHOR_REACH.half, ANCHOR_REACH.half, -ANCHOR_REACH.half, ANCHOR_REACH.half, ANCHOR_REACH.top
		end
		local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
		for _, corner in
			{ Vector3.new(x0, 0, z0), Vector3.new(x1, 0, z0), Vector3.new(x0, 0, z1), Vector3.new(x1, 0, z1) }
		do
			local p = frame:PointToWorldSpace(corner)
			lo, hi = lo:Min(p), hi:Max(p)
		end
		table.insert(out, {
			kind = anchor.kind :: string,
			x0 = lo.X,
			x1 = hi.X,
			z0 = lo.Z,
			z1 = hi.Z,
			y0 = anchor.pos.Y - 0.5,
			y1 = anchor.pos.Y + top,
		})
	end
	clearCache[layout] = out
	return out
end

-- Whether `pieces` fit: inside `room`, clear of every zone and clearance, of the furniture and the kit's own things.
-- `ground` (level-local floor height) checks what the pieces rest on.
local function fits(state: State, pieces: { Piece }, room: Room, ground: number?, margin: number?): boolean
	if not Kit.fits(state.info, pieces, { room = room.id, ground = ground, margin = margin or 0.25 }) then
		return false
	end
	for _, piece in pieces do
		local box = Kit.localBox(state.info, piece)
		for _, zone in state.clear do
			if boxOverlap(box, zone, 0.05) then
				return false
			end
		end
		if ground then
			for _, other in state.boxes do
				if boxOverlap(box, other, 0.1) then
					return false
				end
			end
		end
	end
	return true
end

local function claim(state: State, pieces: { Piece })
	for _, piece in pieces do
		table.insert(state.boxes, Kit.localBox(state.info, piece))
	end
end

--------------------------------------------------------------------------------
-- The plan's ledger
--------------------------------------------------------------------------------

-- Adds `item` if the budgets allow it. Returns whether it was added.
local function add(state: State, item: Item): boolean
	local plan = state.plan
	if state.kinds and not state.kinds[item.kind] then
		return false
	end
	local parts, signature, decals = 0, 0, 0
	for index, piece in item.pieces do
		parts += 1
		if piece.detail == nil then
			signature += 1
		end
		if item.painters[index] then
			decals += 1
		end
	end
	if plan.parts + parts > DreadConfig.Budget.Parts or plan.signature + signature > DreadConfig.Budget.Signature then
		return false
	end
	plan.parts += parts
	plan.signature += signature
	plan.decals += decals
	plan.counts[item.kind] = (plan.counts[item.kind] or 0) + 1
	table.insert(plan.items, item)
	return true
end

local function item(kind: string, pieces: { Piece }): Item
	return { kind = kind, pieces = pieces, painters = {}, tags = {}, attributes = {} }
end

--------------------------------------------------------------------------------
-- Routes and rooms
--------------------------------------------------------------------------------

-- The patrol loops of `layout`: its PatrolWaypoint anchors grouped by loop ("<prefix>_WP_<Region>_<nn>"), in order
-- (level-local points): the routes the kit dresses unless told others.
function DreadKit.patrolLoops(layout: Layout): { { Vector3 } }
	local groups: { [string]: { Anchor } } = {}
	local names: { string } = {}
	for _, anchor in layout.anchors do
		if anchor.kind == "PatrolWaypoint" then
			local loop = string.match(anchor.id, "^(.*)_%d+$") or anchor.id
			if not groups[loop] then
				groups[loop] = {}
				table.insert(names, loop)
			end
			table.insert(groups[loop], anchor)
		end
	end
	table.sort(names)
	local out: { { Vector3 } } = {}
	for _, name in names do
		local list = groups[name]
		table.sort(list, function(a: Anchor, b: Anchor): boolean
			return a.id < b.id
		end)
		local points: { Vector3 } = {}
		for _, anchor in list do
			table.insert(points, anchor.pos)
		end
		table.insert(out, points)
	end
	return out
end

local function roomAt(rooms: { Room }, x: number, z: number): Room?
	for _, room in rooms do
		if LayoutSchema.rectContains(room.rect, x, z, -0.5) then
			return room
		end
	end
	return nil
end

-- Points every few studs along every straight leg of the loops, each with the walkable room it falls in.
local function sampleRoutes(state: State, loops: { { Vector3 } }, walk: { Room })
	local seen: { [string]: boolean } = {}
	for _, loop in loops do
		for i, a in loop do
			local b = loop[i % #loop + 1]
			if #loop < 2 or (math.abs(a.X - b.X) > 0.5 and math.abs(a.Z - b.Z) > 0.5) then
				continue -- only straight legs: a diagonal hop is not a run anyone walks
			end
			local length = (b - a).Magnitude
			local steps = math.max(1, math.floor(length / 4))
			for s = 0, steps - 1 do
				local p = a + (b - a) * (s / steps)
				local room = roomAt(walk, p.X, p.Z)
				if room and RUN_KINDS[room.kind] then
					table.insert(state.routePoints, { room = room, x = p.X, z = p.Z })
					if not seen[room.id] then
						seen[room.id] = true
						table.insert(state.routeRooms, room)
					end
				end
			end
		end
	end
end

local function wallsOf(state: State, room: Room): { Wall }
	local cached = state.walls[room.id]
	if cached then
		return cached
	end
	local walls = WallPlanner.walls(state.info, room)
	state.walls[room.id] = walls
	return walls
end

-- The long side walls of a run (the ones a player walks beside), else every wall.
local function sideWalls(state: State, room: Room): { Wall }
	local out: { Wall } = {}
	for _, wall in wallsOf(state, room) do
		if wall.u1 - wall.u0 >= 8 then
			table.insert(out, wall)
		end
	end
	return out
end

-- What `wall` already carries: openings, wall fixtures, other builders' mounts and the kit's, junction plates and
-- stencils painted on it.
local function takenOn(state: State, wall: Wall): { Span }
	local out = WallPlanner.taken(state.layout, wall, state.taken)
	local tunnels = state.layout.tunnels
	if tunnels then
		for _, mark in tunnels.landmarks do
			if mark.room == wall.room.id and mark.normal:Dot(wall.normal) > 0.9 then
				local u = if wall.axis == "Z" then mark.pos.X else mark.pos.Z
				table.insert(out, {
					u0 = u - mark.width / 2 - 0.6,
					u1 = u + mark.width / 2 + 0.6,
					y0 = mark.pos.Y - mark.height / 2 - 0.5,
					y1 = mark.pos.Y + mark.height / 2 + 0.5,
				})
			end
		end
	end
	return out
end

type WallSpot = { wall: Wall, u: number, y: number, cframe: CFrame }

-- A free spot `w` x `h` on `wall` with its centre between heights `yLo` and `yHi`, `out` studs off the face.
local function wallSpot(
	state: State,
	wall: Wall,
	w: number,
	h: number,
	yLo: number,
	yHi: number,
	out: number,
	random: Rng
): WallSpot?
	local ceiling = SchoolShellBuilder.ceilingBottom(state.layout, wall.room)
	local yMax = math.min(yHi, ceiling - 0.25 - h / 2)
	if yMax < yLo then
		return nil
	end
	local y = between(random, yLo, yMax)
	local runs = WallPlanner.free(wall, takenOn(state, wall), y - h / 2 - 0.3, y + h / 2 + 0.3, w + 0.8)
	if #runs == 0 then
		return nil
	end
	local run = pick(random, runs)
	local u = between(random, run.u0 + w / 2 + 0.4, run.u1 - w / 2 - 0.4)
	return { wall = wall, u = u, y = y, cframe = WallPlanner.cframe(state.info, wall, u, y, out) }
end

local function mountAt(state: State, spot: WallSpot, w: number, h: number)
	local mount = WallPlanner.mount(
		spot.wall,
		spot.u - w / 2 - 0.4,
		spot.u + w / 2 + 0.4,
		spot.y - h / 2 - 0.3,
		spot.y + h / 2 + 0.3
	)
	table.insert(state.taken, mount)
	table.insert(state.plan.mounts, mount)
end

-- Tries `tries` spots on the walls of `rooms` for one wall thing; `make` builds the pieces at a spot (or nil).
local function onWalls(
	state: State,
	rooms: { Room },
	w: number,
	h: number,
	yLo: number,
	yHi: number,
	out: number,
	tries: number,
	make: (spot: WallSpot) -> Item?
): Item?
	if #rooms == 0 then
		return nil
	end
	local random = state.random
	for _ = 1, tries do
		local room = pick(random, rooms)
		local walls = sideWalls(state, room)
		if #walls == 0 or state.stubs[room.id] then
			continue
		end
		local spot = wallSpot(state, pick(random, walls), w, h, yLo, yHi, out, random)
		if not spot then
			continue
		end
		local made = make(spot)
		if made and fits(state, made.pieces, room, nil, -0.05) and add(state, made) then
			mountAt(state, spot, w, h)
			return made
		end
	end
	return nil
end

local function wallColor(room: Room): Color3
	return Palette.get(SchoolShellBuilder.wallKey(room)).color
end

local function seedOf(state: State, name: string): number
	return MathUtil.hash(state.layout.id .. ":" .. name)
end

-- A floor point near the route (on a route leg), pulled toward a wall of its run by `toWall` of the half width.
local function routeFloorPoint(state: State, toWall: number, room: Room?): { room: Room, x: number, z: number }?
	local points = state.routePoints
	if room then
		points = {}
		for _, point in state.routePoints do
			if point.room == room then
				table.insert(points, point)
			end
		end
		if #points == 0 then
			local c = LayoutSchema.rectCenter(room.rect)
			points = { { room = room, x = c.X, z = c.Y } }
		end
	end
	if #points == 0 then
		return nil
	end
	local random = state.random
	local p = pick(random, points)
	local inner = state.info.inner[p.room.id]
	if not inner then
		return nil
	end
	local side = if random:NextNumber() < 0.5 then -1 else 1
	if inner.w >= inner.d then
		local half = inner.d / 2
		return { room = p.room, x = p.x + between(random, -2, 2), z = inner.z + half + side * half * toWall }
	end
	local half = inner.w / 2
	return { room = p.room, x = inner.x + half + side * half * toWall, z = p.z + between(random, -2, 2) }
end

-- A floor point in a keep-room, near one of its walls.
local function roomFloorPoint(state: State, room: Room): (number?, number?)
	local inner = state.info.inner[room.id]
	if not inner then
		return nil, nil
	end
	local random = state.random
	return between(random, inner.x + 1.5, inner.x + inner.w - 1.5),
		between(random, inner.z + 1.5, inner.z + inner.d - 1.5)
end

local function onFloor(state: State, pieces: { Piece }, x: number, z: number, yaw: number): { Piece }
	local frame = CFrame.new(state.info.origin + Vector3.new(x, 0, z)) * ry(yaw)
	Kit.transform(pieces, frame)
	return pieces
end

local function placeOnFloor(state: State, room: Room, made: Item, x: number, z: number, yaw: number): boolean
	onFloor(state, made.pieces, x, z, yaw)
	if fits(state, made.pieces, room, 0) and add(state, made) then
		claim(state, made.pieces)
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- He was here
--------------------------------------------------------------------------------

local function gougeItem(state: State, spot: WallSpot, w: number, h: number, level: number?): Item
	local name = nextName(state, "Gouge")
	local made = item("Gouge", { host(name, spot.cframe, w, h, "PlasterFlap", level) })
	local color, seed = wallColor(spot.wall.room), seedOf(state, name)
	local lean = between(state.random, 20, 36) * (if state.random:NextNumber() < 0.5 then -1 else 1)
	local strokes = 4
	made.painters[1] = function(part: BasePart)
		DreadArt.gouges(part, color, seed, strokes, lean)
	end
	return made
end

-- High on the walls of the runs he walks: his hands as he goes (in the low runs, just under the ceiling).
local function planGouges(state: State, number: number, level: number?, rooms: { Room }?)
	for _ = 1, number do
		local w, h = between(state.random, 2.6, 3.4), between(state.random, 4.4, 5.6)
		onWalls(
			state,
			rooms or state.routeRooms,
			w,
			h,
			GOUGE_LOW + h / 2,
			GOUGE_TOP - h / 2,
			WALL_OUT,
			10,
			function(spot)
				return gougeItem(state, spot, w, h, level)
			end
		)
	end
end

-- Down his loops, evenly: every run of the loops in turn gets a gouge on one of its long walls, a run as long as
-- GOUGE_EVERY more than once, until `number` are up.
local GOUGE_EVERY = 40

local function planGougeRuns(state: State, number: number)
	local target = (state.plan.counts.Gouge or 0) + number
	local rooms = shuffled(state.random, state.routeRooms)
	for pass = 1, 6 do
		for _, room in rooms do
			if (state.plan.counts.Gouge or 0) >= target then
				return
			end
			local length = math.max(room.rect.w, room.rect.d)
			if pass == 1 or length >= GOUGE_EVERY * pass then
				planGouges(state, 1, LOOK, { room })
			end
		end
	end
end

-- Across the ceilings of the runs he walks.
local function planCeilingGouges(state: State, number: number)
	local random = state.random
	for _ = 1, number * 4 do
		if (state.plan.counts.CeilingGouge or 0) >= number then
			return
		end
		local p = routeFloorPoint(state, 0)
		if not p then
			return
		end
		local inner = state.info.inner[p.room.id]
		if not inner then
			continue
		end
		local along = inner.w >= inner.d
		local length = between(random, 4.5, 7)
		local width = math.min(between(random, 2, 2.8), (if along then inner.d else inner.w) - 1)
		local y = SchoolShellBuilder.ceilingBottom(state.layout, p.room) - 0.03
		local centre = state.info.origin + Vector3.new(p.x, y, p.z)
		-- a ceiling host: its Front face looks down, its long side along the run
		local cframe = CFrame.lookAt(centre, centre - Vector3.yAxis, if along then Vector3.zAxis else Vector3.xAxis)
		local name = nextName(state, "CeilingGouge")
		local made = item("CeilingGouge", { host(name, cframe, length, width, "PlasterFlap", LOOK) })
		local color = Palette.get(SchoolShellBuilder.ceilingKey(p.room)).color
		local seed = seedOf(state, name)
		local lean = between(random, -10, 10)
		made.painters[1] = function(part: BasePart)
			DreadArt.gouges(part, color, seed, 4, lean)
		end
		if fits(state, made.pieces, p.room, nil, -0.05) then
			add(state, made)
		end
	end
end

-- Door frames he forced, on the run side of doorways off his loops: both jambs gripped and the plaster cracked out
-- from them where he hauled himself through stooping (gouges over cracks, 6 to 9.5 studs up), and where the wall above
-- the opening has room, its head casing bowed out into the run.
local function planForcedFrames(state: State, number: number, signature: boolean)
	local rooms: { [string]: Room } = {}
	for _, room in state.routeRooms do
		rooms[room.id] = room
	end
	local random = state.random
	local done = 0
	for _, door in shuffled(random, state.layout.doors) do
		if done >= number then
			return
		end
		if door.kind ~= "Door" and door.kind ~= "Doorway" and door.kind ~= "Ajar" then
			continue
		end
		local run = rooms[door.rooms[1]] or rooms[door.rooms[2]]
		local other = if run and run.id == door.rooms[1]
			then state.info.rooms[door.rooms[2]]
			else state.info.rooms[door.rooms[1]]
		if not (run and other) or not WALK_KINDS[other.kind] or state.stubs[run.id] then
			continue
		end
		local edge = LayoutSchema.sharedEdge(run.rect, other.rect)
		if not edge then
			continue
		end
		local wall: Wall? = nil
		for _, candidate in wallsOf(state, run) do
			if candidate.axis == edge.axis and math.abs(candidate.line - edge.coord) < 0.01 then
				wall = candidate
			end
		end
		if not wall then
			continue
		end
		local width, height = LayoutSchema.doorWidth(door), LayoutSchema.doorHeight(door)
		local ceiling = SchoolShellBuilder.ceilingBottom(state.layout, run)
		local name = nextName(state, "ForcedFrame")
		local level = if signature and done == 0 then nil else LOOK
		local pieces: { Piece } = {}
		local spots: { WallSpot } = {}
		local w, h = 1.8, math.min(3.6, ceiling - 6.2)
		if h < 2.2 then
			continue
		end
		local cy = 6 + h / 2
		local spans = takenOn(state, wall)
		local clear = true
		for i, side in { -1, 1 } do
			local u = door.at + side * (width / 2 + 1.15 + w / 2)
			for _, span in spans do
				local opening = span.u0 < door.at and span.u1 > door.at -- the doorway's own pad
				if
					not opening
					and span.u1 > u - w / 2
					and span.u0 < u + w / 2
					and span.y1 > cy - h / 2
					and span.y0 < cy + h / 2
				then
					clear = false
				end
			end
			if u - w / 2 < wall.u0 + 0.3 or u + w / 2 > wall.u1 - 0.3 then
				clear = false
			end
			local spot: WallSpot =
				{ wall = wall, u = u, y = cy, cframe = WallPlanner.cframe(state.info, wall, u, cy, WALL_OUT) }
			table.insert(spots, spot)
			table.insert(pieces, host(string.format("%s_Grip%d", name, i), spot.cframe, w, h, "PlasterFlap", level))
		end
		if not clear then
			continue
		end
		local headroom = ceiling >= height + 1.4
		if headroom then
			-- the head casing bowed out into the run: two halves turned out about their outer ends
			local headY = height + 0.62
			for _, side in { -1, 1 } do
				local outer = WallPlanner.cframe(state.info, wall, door.at + side * (width / 2 + 0.35), headY, 0.1)
				local length = width / 2 + 0.35
				local piece = Kit.block(
					string.format("%s_Head%s", name, if side < 0 then "L" else "R"),
					outer * CFrame.Angles(0, math.rad(side * 9), 0) * CFrame.new(-side * length / 2, 0, 0),
					Vector3.new(length, 0.3, 0.14),
					"Trim",
					"Detail",
					{ color = Color3.fromRGB(58, 46, 34), castShadow = false }
				)
				table.insert(pieces, detail(piece, MEDIUM))
			end
		end
		local made = item("ForcedFrame", pieces)
		local color = wallColor(run)
		for i, side in { -1, 1 } do
			local seed = seedOf(state, string.format("%s_%d", name, i))
			local lean = side * between(random, 8, 18)
			made.painters[i] = function(part: BasePart)
				DreadArt.cracks(part, seed, 0, color)
				DreadArt.gouges(part, color, seed, 3, lean)
			end
		end
		if fits(state, pieces, run, nil, -0.05) and add(state, made) then
			for _, spot in spots do
				mountAt(state, spot, w, h)
			end
			done += 1
		end
	end
end

-- Pale porcelain dust and shards down his loops (the torch catches them); `shard`: one larger curved fragment.
local function porcelainPieces(random: Rng, name: string, large: boolean): { Piece }
	local pieces: { Piece } = {}
	local glossy: Geometry.PartOptions =
		{ color = PORCELAIN, material = Enum.Material.SmoothPlastic, reflectance = 0.25, castShadow = false }
	if large then
		-- a curve of the mask's cheek: two plates meeting at an angle, lying on the floor
		table.insert(
			pieces,
			Kit.block(
				name .. "_Cheek",
				CFrame.new(0, 0.07, 0) * CFrame.Angles(0, 0, math.rad(14)),
				Vector3.new(0.9, 0.05, 0.7),
				"Fixture",
				"Detail",
				glossy
			)
		)
		table.insert(
			pieces,
			Kit.block(
				name .. "_Brow",
				CFrame.new(0.72, 0.13, 0.05) * CFrame.Angles(0, math.rad(12), math.rad(-22)),
				Vector3.new(0.6, 0.05, 0.55),
				"Fixture",
				"Detail",
				glossy
			)
		)
		return pieces
	end
	table.insert(
		pieces,
		detail(
			Kit.disc(name .. "_Dust", Vector3.new(0, 0.003, 0), between(random, 1.1, 2), 0.01, "Fixture", "Detail", {
				color = PORCELAIN_DUST,
				material = Enum.Material.SmoothPlastic,
				transparency = 0.45,
				castShadow = false,
			}),
			MEDIUM
		)
	)
	for i = 1, 2 do
		local s = between(random, 0.18, 0.36)
		table.insert(
			pieces,
			detail(
				Kit.wedge(
					string.format("%s_Shard%d", name, i),
					CFrame.new(between(random, -0.6, 0.6), 0.03, between(random, -0.6, 0.6))
						* ry(between(random, 0, 360))
						* CFrame.Angles(0, 0, math.rad(90)),
					Vector3.new(0.04, s, s * between(random, 0.6, 1.3)),
					"Fixture",
					"Detail",
					glossy
				),
				SMALL
			)
		)
	end
	return pieces
end

local function planTrail(state: State, number: number, large: number, room: Room?)
	local random = state.random
	local trails = (state.plan.counts.PorcelainTrail or 0) + number
	local shards = (state.plan.counts.MaskShard or 0) + large
	for _ = 1, (number + large) * 4 do
		local isLarge = (state.plan.counts.MaskShard or 0) < shards
		if not isLarge and (state.plan.counts.PorcelainTrail or 0) >= trails then
			return
		end
		local p = routeFloorPoint(state, between(random, 0, 0.55), room)
		if not p then
			return
		end
		local kind = if isLarge then "MaskShard" else "PorcelainTrail"
		local made = item(kind, porcelainPieces(random, nextName(state, kind), isLarge))
		placeOnFloor(state, p.room, made, p.x, p.z, between(random, 0, 360))
	end
end

--------------------------------------------------------------------------------
-- They ran
--------------------------------------------------------------------------------

local function backpackPieces(random: Rng, name: string, level: number?): { Piece }
	local color = pick(random, BAG_COLORS)
	local cloth: Geometry.PartOptions = { color = color, material = Enum.Material.Fabric, castShadow = false }
	local trim: Geometry.PartOptions =
		{ color = Color3.fromRGB(22, 22, 24), material = Enum.Material.Fabric, castShadow = false }
	-- lying on its back, its face up: the body, the front pocket, the zip round it, two straps flung out from the top
	local tilt = CFrame.Angles(0, 0, math.rad(between(random, -6, 6)))
	return {
		detail(
			Kit.block(
				name .. "_Bag",
				CFrame.new(0, 0.24, 0) * tilt,
				Vector3.new(1.1, 0.48, 1.5),
				"ChairShell",
				"Detail",
				cloth
			),
			level
		),
		detail(
			Kit.block(
				name .. "_Pocket",
				CFrame.new(0, 0.55, 0.25) * tilt,
				Vector3.new(0.82, 0.18, 0.72),
				"ChairShell",
				"Detail",
				cloth
			),
			level
		),
		detail(
			Kit.block(
				name .. "_Zip",
				CFrame.new(0, 0.5, -0.14) * tilt,
				Vector3.new(0.86, 0.06, 0.07),
				"Rubber",
				"Detail",
				trim
			),
			level or MEDIUM
		),
		detail(
			Kit.block(
				name .. "_StrapL",
				CFrame.new(-0.3, 0.05, -1.1) * ry(between(random, 10, 30)),
				Vector3.new(0.13, 0.05, 1.0),
				"Rubber",
				"Detail",
				trim
			),
			level or SMALL
		),
		detail(
			Kit.block(
				name .. "_StrapR",
				CFrame.new(0.32, 0.05, -1.05) * ry(between(random, -30, -8)),
				Vector3.new(0.13, 0.05, 0.95),
				"Rubber",
				"Detail",
				trim
			),
			SMALL
		),
	}
end

local function shoePieces(random: Rng, name: string): { Piece }
	local color = pick(random, SHOE_COLORS)
	return {
		detail(
			Kit.block(
				name .. "_Sole",
				CFrame.new(0, 0.06, 0),
				Vector3.new(0.42, 0.12, 1.05),
				"Rubber",
				"Detail",
				{ color = Color3.fromRGB(200, 196, 186), castShadow = false }
			),
			MEDIUM
		),
		detail(
			Kit.block(
				name .. "_Upper",
				CFrame.new(0, 0.24, 0.15),
				Vector3.new(0.38, 0.26, 0.7),
				"ChairShell",
				"Detail",
				{ color = color, material = Enum.Material.Fabric, castShadow = false }
			),
			SMALL
		),
	}
end

local function phonePieces(name: string, level: number?): { Piece }
	return {
		detail(
			Kit.block(
				name .. "_Case",
				CFrame.new(0, 0.025, 0),
				Vector3.new(0.4, 0.05, 0.8),
				"Rubber",
				"Detail",
				{ color = Color3.fromRGB(16, 16, 18), castShadow = false }
			),
			level
		),
		detail(
			Kit.block(
				name .. "_Screen",
				CFrame.new(0, 0.055, 0) * CFrame.Angles(math.rad(-90), 0, 0),
				Vector3.new(0.34, 0.68, 0.01),
				"Screen",
				"Detail",
				{ color = PHONE_GLOW, material = Enum.Material.Neon, castShadow = false }
			),
			level
		),
	}
end

local function paperPieces(random: Rng, name: string): { Piece }
	local out: { Piece } = {}
	for i = 1, random:NextInteger(2, 3) do
		table.insert(
			out,
			detail(
				Kit.block(
					string.format("%s_Sheet%d", name, i),
					CFrame.new(between(random, -0.9, 0.9), 0.008 + i * 0.004, between(random, -0.9, 0.9))
						* ry(between(random, 0, 360)),
					Vector3.new(0.78, 0.012, 1.02),
					"PaperSheet",
					"Detail",
					{ castShadow = false }
				),
				SMALL
			)
		)
	end
	return out
end

-- One dropped thing (or a little spill of them) beside a run of his loops.
local function planDropped(state: State, kind: string, number: number, level: number?, room: Room?)
	local random = state.random
	local target = (state.plan.counts[kind] or 0) + number
	for _ = 1, number * 5 do
		if (state.plan.counts[kind] or 0) >= target then
			return
		end
		local p = routeFloorPoint(state, between(random, 0.35, 0.75), room)
		if not p then
			return
		end
		local name = nextName(state, kind)
		local made: Item
		if kind == "Backpack" then
			made = item(kind, backpackPieces(random, name, level))
		elseif kind == "Shoe" then
			made = item(kind, shoePieces(random, name))
		elseif kind == "Phone" then
			made = item(kind, phonePieces(name, level))
			local seed = seedOf(state, name)
			made.painters[2] = function(part: BasePart)
				DreadArt.screen(part, seed)
			end
		else
			made = item(kind, paperPieces(random, name))
		end
		placeOnFloor(state, p.room, made, p.x, p.z, between(random, 0, 360))
	end
end

-- A classroom chair on its back.
local function chairPieces(name: string, color: Color3, level: number): { Piece }
	local shell: Geometry.PartOptions = { color = color, castShadow = false }
	local steel: Geometry.PartOptions = { color = Color3.fromRGB(52, 56, 54), castShadow = false }
	-- upright, then tipped onto its back about the back's foot
	local pieces: { Piece } = {
		Kit.block(name .. "_Seat", CFrame.new(0, 1.55, 0), Vector3.new(1.4, 0.12, 1.4), "ChairShell", "Detail", shell),
		Kit.block(name .. "_Back", CFrame.new(0, 2.5, 0.68), Vector3.new(1.4, 1.2, 0.1), "ChairShell", "Detail", shell),
	}
	for i, corner in { Vector2.new(-0.6, -0.6), Vector2.new(0.6, -0.6), Vector2.new(-0.6, 0.6), Vector2.new(0.6, 0.6) } do
		table.insert(
			pieces,
			Kit.cylinder(
				string.format("%s_Leg%d", name, i),
				Vector3.new(corner.X, 0, corner.Y),
				Vector3.new(corner.X * 0.92, 1.5, corner.Y * 0.92),
				0.09,
				"DeskSteel",
				"Detail",
				steel
			)
		)
	end
	Kit.transform(pieces, CFrame.new(0, 0, 0.75) * CFrame.Angles(math.rad(90), 0, 0) * CFrame.new(0, 0, -0.75))
	local lo = math.huge
	for _, piece in pieces do
		local a = Kit.bounds(piece)
		lo = math.min(lo, a.Y)
	end
	Kit.offset(pieces, Vector3.new(0, 0.005 - lo, 0))
	for i, piece in pieces do
		detail(piece, if i <= 2 then level else math.max(level, MEDIUM))
	end
	return pieces
end

-- A student desk on its side.
local function deskPieces(name: string, level: number?): { Piece }
	local pieces = {
		Kit.block(
			name .. "_Top",
			CFrame.new(0, 2.45, 0),
			Vector3.new(2.4, 0.14, 1.7),
			"DeskTop",
			"Detail",
			{ castShadow = false }
		),
		Kit.block(
			name .. "_EndL",
			CFrame.new(-1.1, 1.2, 0),
			Vector3.new(0.1, 2.35, 1.4),
			"DeskSteel",
			"Detail",
			{ castShadow = false }
		),
		Kit.block(
			name .. "_EndR",
			CFrame.new(1.1, 1.2, 0),
			Vector3.new(0.1, 2.35, 1.4),
			"DeskSteel",
			"Detail",
			{ castShadow = false }
		),
	}
	Kit.transform(pieces, CFrame.Angles(0, 0, math.rad(90)))
	local lo = math.huge
	for _, piece in pieces do
		local a = Kit.bounds(piece)
		lo = math.min(lo, a.Y)
	end
	Kit.offset(pieces, Vector3.new(0, 0.005 - lo, 0))
	for i, piece in pieces do
		detail(piece, if i == 1 then level else (if level then math.max(level, MEDIUM) else MEDIUM))
	end
	return pieces
end

local function planKnockedOver(state: State, number: number, rooms: { Room }?)
	local random = state.random
	local candidates = rooms or state.keepRooms
	if #candidates == 0 then
		return
	end
	local target = (state.plan.counts.KnockedOver or 0) + number
	for _ = 1, number * 6 do
		if (state.plan.counts.KnockedOver or 0) >= target then
			return
		end
		local room = pick(random, candidates)
		local x, z = roomFloorPoint(state, room)
		if not (x and z) then
			continue
		end
		local name = nextName(state, "KnockedOver")
		local pieces = if random:NextNumber() < 0.8
			then chairPieces(name, Color3.fromRGB(70, 62, 48), LOOK)
			else deskPieces(name, LOOK)
		placeOnFloor(state, room, item("KnockedOver", pieces), x, z, between(random, 0, 360))
	end
end

-- The desks they pushed against a door from the inside, shoved back into the room when it gave: beside the door's
-- swing, never in it, two desks and a chair skewed away from the wall.
local function planBarricade(state: State, roomIds: { string }, signature: boolean)
	for _, roomId in roomIds do
		local room = state.info.rooms[roomId]
		if not room then
			continue
		end
		for _, door in state.layout.doors do
			if not (door.rooms[1] == roomId or door.rooms[2] == roomId) then
				continue
			end
			local other = state.info.rooms[if door.rooms[1] == roomId then door.rooms[2] else door.rooms[1]]
			local edge = if other then LayoutSchema.sharedEdge(room.rect, other.rect) else nil
			if not edge then
				continue
			end
			local inner = state.info.inner[roomId]
			local wall: Wall? = nil
			for _, candidate in wallsOf(state, room) do
				if candidate.axis == edge.axis and math.abs(candidate.line - edge.coord) < 0.01 then
					wall = candidate
				end
			end
			if not (wall and inner) then
				continue
			end
			local width = LayoutSchema.doorWidth(door)
			for _, side in { 1, -1 } do
				for step = 0, 10 do
					local u = door.at + side * (width * 1.5 + 2 + step)
					local base = WallPlanner.floorPoint(state.info, wall, u, 2.2 + (step % 2) * 0.8)
					local yaw = math.deg(math.atan2(-wall.normal.X, -wall.normal.Z))
					local name = nextName(state, "Barricade")
					local level = if signature then nil else LOOK
					local first = deskPieces(name .. "_A", level)
					local second = deskPieces(name .. "_B", LOOK)
					Kit.transform(second, CFrame.new(-side * 1.1, 0, -1.9) * ry(side * 28))
					local chair = chairPieces(name .. "_C", Color3.fromRGB(70, 62, 48), MEDIUM)
					Kit.transform(chair, CFrame.new(side * 1.7, 0, -0.9) * ry(-side * 60))
					local pieces: { Piece } = first
					for _, piece in second do
						table.insert(pieces, piece)
					end
					for _, piece in chair do
						table.insert(pieces, piece)
					end
					local made = item("Barricade", pieces)
					Kit.transform(pieces, CFrame.new(base) * ry(yaw + side * 12))
					if fits(state, pieces, room, 0) and add(state, made) then
						claim(state, pieces)
						return
					end
				end
			end
		end
	end
end

-- A locker door torn off and dropped beside a run.
local function planLockerDoors(state: State, number: number)
	local random = state.random
	for _ = 1, number * 5 do
		if (state.plan.counts.LockerDoor or 0) >= number then
			return
		end
		local p = routeFloorPoint(state, between(random, 0.4, 0.7))
		if not p then
			return
		end
		local name = nextName(state, "LockerDoor")
		local door = detail(
			Kit.block(
				name,
				CFrame.new(0, 0.04, 0)
					* CFrame.Angles(math.rad(-90), 0, 0)
					* CFrame.Angles(0, 0, math.rad(between(random, -4, 4))),
				Vector3.new(1.2, 5.6, 0.06),
				"CabinetSteel",
				"Detail",
				{ color = pick(random, LOCKER_PAINT), castShadow = false }
			),
			MEDIUM
		)
		local made = item("LockerDoor", { door })
		local number_ = random:NextInteger(101, 348)
		made.painters[1] = function(part: BasePart)
			DreadArt.louvres(part, number_)
		end
		placeOnFloor(state, p.room, made, p.x, p.z, between(random, 0, 360))
	end
end

-- A wall trophy case smashed open: its body and shelf, glass teeth left in the frame, a trophy and glass on the floor.
local function planTrophyCase(state: State, rooms: { Room })
	local random = state.random
	local w, h, depth = 3.4, 2.6, 0.7
	onWalls(state, rooms, w, h, 4.2, 4.6, depth / 2 + 0.02, 40, function(spot)
		local name = nextName(state, "TrophyCase")
		local frame = spot.cframe
		local wood: Geometry.PartOptions = { color = Color3.fromRGB(64, 44, 30), castShadow = false }
		local glass: Geometry.PartOptions = {
			color = Color3.fromRGB(150, 170, 168),
			material = Enum.Material.Glass,
			transparency = 0.55,
			castShadow = false,
		}
		local pieces: { Piece } = {
			Kit.block(
				name .. "_Back",
				frame * CFrame.new(0, 0, depth / 2 - 0.05),
				Vector3.new(w, h, 0.1),
				"Trim",
				"Detail",
				wood
			),
			Kit.block(
				name .. "_Shelf",
				frame * CFrame.new(0, -0.2, 0),
				Vector3.new(w - 0.2, 0.08, depth - 0.1),
				"Trim",
				"Detail",
				wood
			),
			detail(
				Kit.wedge(
					name .. "_GlassL",
					frame * CFrame.new(-w / 2 + 0.35, h / 2 - 0.45, -depth / 2) * CFrame.Angles(0, 0, math.rad(180)),
					Vector3.new(0.02, 0.8, 0.6),
					"Glass",
					"Detail",
					glass
				),
				MEDIUM
			),
			detail(
				Kit.wedge(
					name .. "_GlassR",
					frame * CFrame.new(w / 2 - 0.3, -h / 2 + 0.4, -depth / 2),
					Vector3.new(0.02, 0.7, 0.5),
					"Glass",
					"Detail",
					glass
				),
				MEDIUM
			),
			detail(
				Kit.block(
					name .. "_Rim",
					frame * CFrame.new(0, -h / 2 + 0.05, 0),
					Vector3.new(w, 0.1, depth),
					"Trim",
					"Detail",
					wood
				),
				MEDIUM
			),
		}
		-- the trophy knocked down and the glass beneath
		local floor = WallPlanner.floorPoint(state.info, spot.wall, spot.u + between(random, -0.8, 0.8), 1.2)
		local cup = Color3.fromRGB(170, 140, 60)
		table.insert(
			pieces,
			detail(
				Kit.cylinder(
					name .. "_Cup",
					floor + Vector3.new(-0.3, 0.3, 0),
					floor + Vector3.new(0.5, 0.36, 0.2),
					0.55,
					"Fixture",
					"Detail",
					{ color = cup, material = Enum.Material.Metal, reflectance = 0.2, castShadow = false }
				),
				MEDIUM
			)
		)
		table.insert(
			pieces,
			detail(
				Kit.block(
					name .. "_Base",
					CFrame.new(floor + Vector3.new(-0.7, 0.22, 0.1)) * ry(30),
					Vector3.new(0.45, 0.45, 0.45),
					"Trim",
					"Detail",
					wood
				),
				SMALL
			)
		)
		for i = 1, 3 do
			local at = floor + Vector3.new(between(random, -1.2, 1.2), 0.012, between(random, -0.6, 0.6))
			table.insert(
				pieces,
				detail(
					Kit.wedge(
						string.format("%s_Shard%d", name, i),
						CFrame.new(at) * ry(between(random, 0, 360)) * CFrame.Angles(0, 0, math.rad(90)),
						Vector3.new(0.02, between(random, 0.2, 0.4), between(random, 0.2, 0.5)),
						"Glass",
						"Detail",
						glass
					),
					SMALL
				)
			)
		end
		return item("TrophyCase", pieces)
	end)
end

-- Two coats left on their hooks in a dark corner: in the dark they are two people standing very still.
local function planCoats(state: State, rooms: { Room })
	local random = state.random
	local w, h = 3.8, 4.6
	onWalls(state, rooms, w, h, 3.9, 4.1, 0.05, 14, function(spot)
		local name = nextName(state, "Coats")
		local frame = spot.cframe -- y at the coats' middle; LookVector into the room
		local pieces: { Piece } = {
			Kit.block(
				name .. "_Rail",
				frame * CFrame.new(0, 2.15, -0.1),
				Vector3.new(w - 0.2, 0.14, 0.14),
				"TrimMetal",
				"Detail",
				{ castShadow = false }
			),
		}
		for i, x in { -0.95, 0.95 } do
			local color = pick(random, COAT_COLORS)
			local cloth: Geometry.PartOptions = { color = color, material = Enum.Material.Fabric, castShadow = false }
			local drop = between(random, 0, 0.25)
			table.insert(
				pieces,
				Kit.block(
					string.format("%s_Shoulders%d", name, i),
					frame * CFrame.new(x, 1.6 - drop, -0.32),
					Vector3.new(1.55, 0.42, 0.5),
					"ChairShell",
					"Detail",
					cloth
				)
			)
			table.insert(
				pieces,
				Kit.block(
					string.format("%s_Coat%d", name, i),
					frame
						* CFrame.new(x, 0 - drop, -0.3)
						* CFrame.Angles(math.rad(-3), 0, math.rad(between(random, -2, 2))),
					Vector3.new(1.3, 3.1, 0.42),
					"ChairShell",
					"Detail",
					cloth
				)
			)
			table.insert(
				pieces,
				Kit.ball(
					string.format("%s_Hood%d", name, i),
					(frame * CFrame.new(x, 2.0 - drop, -0.36)).Position,
					0.85,
					"ChairShell",
					"Detail",
					cloth
				)
			)
		end
		return item("Coats", pieces)
	end)
end

--------------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------------

local function planWriting(state: State, rooms: { Room }, runRooms: { Room }, preferred: { Room })
	local lines = DreadConfig.Writing[state.layout.id]
	if not lines then
		return
	end
	local number = math.max(1, math.ceil(#lines * state.density))
	for index = 1, math.min(number, #lines) do
		local entry = lines[index]
		local letters = utf8.len(entry.text) or #entry.text
		local h = if entry.hand == "Scratched" then 1.0 else between(state.random, 1.4, 1.8)
		h = math.min(h, 9 / (letters * 0.54))
		local w = math.max(2.4, letters * h * 0.54)
		local make = function(spot: WallSpot): Item?
			local name = nextName(state, "Writing")
			local made = item("Writing", { host(name, spot.cframe, w, h, "PlasterFlap", nil) })
			local color, seed = wallColor(spot.wall.room), seedOf(state, name)
			made.painters[1] = function(part: BasePart)
				DreadArt.writing(part, entry, color, seed)
			end
			made.attributes[1] = { DreadText = entry.text }
			return made
		end
		local station = preferred[index]
		local placed = if station then onWalls(state, { station }, w, h, 3.3, 5.2, WALL_OUT, 8, make) else nil
		local candidates = if entry.year < 2000 then runRooms else rooms
		placed = placed or onWalls(state, candidates, w, h, 3.3, 5.2, WALL_OUT, 16, make)
		if placed then
			table.insert(state.plan.texts, entry.text)
		end
	end
end

local function planTally(state: State, number: number)
	for _ = 1, number do
		local groups = state.random:NextInteger(3, 6)
		local w, h = groups * 0.75 + 0.7, 0.9
		onWalls(state, state.routeRooms, w, h, 1.6, 3.2, WALL_OUT, 10, function(spot)
			local name = nextName(state, "Tally")
			local made = item("Tally", { host(name, spot.cframe, w, h, "PlasterFlap", LOOK) })
			local color, seed = wallColor(spot.wall.room), seedOf(state, name)
			made.painters[1] = function(part: BasePart)
				DreadArt.tally(part, seed, groups, color)
			end
			return made
		end)
	end
end

local function planClocks(state: State, rooms: { Room }, number: number)
	local used: { [Room]: boolean } = {}
	for _ = 1, number do
		local free: { Room } = {}
		for _, room in rooms do
			if not used[room] then
				table.insert(free, room)
			end
		end
		local d = 1.7
		local placed = onWalls(state, free, d, d, 7.2, 8.4, 0, 12, function(spot)
			local name = nextName(state, "Clock")
			local face = spot.cframe
			local rim = Kit.cylinder(
				name .. "_Rim",
				face.Position,
				face.Position + face.LookVector * 0.16,
				d,
				"Fixture",
				"Detail",
				{ color = Color3.fromRGB(32, 32, 34), castShadow = false }
			)
			local dial = host(name .. "_Face", face * CFrame.new(0, 0, -0.18), d * 0.86, d * 0.86, "Fixture", nil)
			local made = item("Clock", { rim, dial })
			made.painters[2] = function(part: BasePart)
				DreadArt.clock(part)
			end
			made.attributes[2] = { DreadRoom = spot.wall.room.id }
			return made
		end)
		if placed then
			local roomId = placed.attributes[2].DreadRoom
			used[state.info.rooms[roomId]] = true
		end
	end
end

local function planPaperOnWall(state: State, rooms: { Room }, kind: string, number: number)
	for _ = 1, number do
		local w, h = 1.7, 2.2
		onWalls(state, rooms, w, h, 4.2, 5.4, 0.03, 12, function(spot)
			local name = nextName(state, kind)
			local sheet = Kit.block(
				name,
				spot.cframe * CFrame.Angles(0, 0, math.rad(between(state.random, -5, 5))),
				Vector3.new(w, h, 0.02),
				"SignPaper",
				"Detail",
				{ castShadow = false }
			)
			local made = item(kind, { sheet })
			local seed = seedOf(state, name)
			made.painters[1] = if kind == "Notice"
				then function(part: BasePart)
					DreadArt.notice(part, seed)
				end
				else function(part: BasePart)
					DreadArt.drawing(part, seed)
				end
			return made
		end)
	end
end

--------------------------------------------------------------------------------
-- Decay that feels wrong
--------------------------------------------------------------------------------

-- A water stain spreading from a ceiling corner, a drip falling from the ceiling in front of it, a puddle below.
local function planStains(state: State, rooms: { Room }, number: number)
	local random = state.random
	local target = (state.plan.counts.WaterStain or 0) + number
	for _ = 1, number * 4 do
		if (state.plan.counts.WaterStain or 0) >= target then
			return
		end
		local room = pick(random, rooms)
		local walls = sideWalls(state, room)
		if #walls == 0 then
			continue
		end
		local wall = pick(random, walls)
		local ceiling = SchoolShellBuilder.ceilingBottom(state.layout, room)
		local w, h = between(random, 2.6, 3.8), math.min(ceiling - 1, between(random, 3, 4.5))
		local left = random:NextNumber() < 0.5
		-- spreading down from where the wall meets the ceiling
		local y = ceiling - 0.05 - h / 2
		local runs = WallPlanner.free(wall, takenOn(state, wall), y - h / 2, y + h / 2, w + 0.6)
		if #runs == 0 then
			continue
		end
		local run = pick(random, runs)
		local u = between(random, run.u0 + 0.3 + w / 2, run.u1 - 0.3 - w / 2)
		local name = nextName(state, "WaterStain")
		local spot: WallSpot =
			{ wall = wall, u = u, y = y, cframe = WallPlanner.cframe(state.info, wall, u, y, WALL_OUT) }
		local stain = host(name, spot.cframe, w, h, "PlasterFlap", LOOK)
		-- the drip hangs from the ceiling a little out from the wall, over its puddle
		local dripU = u + (if left then -1 else 1) * w * 0.3
		local floor = WallPlanner.floorPoint(state.info, wall, dripU, 1.5)
		local bead = detail(
			Kit.ball(name .. "_Drip", floor + Vector3.new(0, ceiling - 0.12, 0), 0.14, "Water", "Detail", {
				color = Color3.fromRGB(150, 160, 150),
				material = Enum.Material.Glass,
				transparency = 0.3,
				castShadow = false,
			}),
			SMALL
		)
		local puddle = detail(
			Kit.disc(
				name .. "_Puddle",
				floor + Vector3.new(0, 0.004, 0),
				between(random, 1, 1.8),
				0.02,
				"Puddle",
				"Detail",
				{ reflectance = 0.3, transparency = 0.1, castShadow = false }
			),
			MEDIUM
		)
		local made = item("WaterStain", { stain, bead, puddle })
		local seed = seedOf(state, name)
		made.painters[1] = function(part: BasePart)
			DreadArt.stain(part, seed, left)
		end
		made.tags[2] = Tags.DreadDrip
		if fits(state, { stain, bead }, room, nil, -0.05) and fits(state, { puddle }, room, 0) and add(state, made) then
			claim(state, { puddle })
			mountAt(state, spot, w, h)
		end
	end
end

local function planWallDecay(state: State, rooms: { Room }, kind: string, number: number)
	local random = state.random
	for _ = 1, number do
		local w, h, yLo, yHi, level
		if kind == "Mould" then
			w, h, yLo, yHi, level = between(random, 1.6, 2.8), between(random, 1.4, 2.4), 1.2, 7, MEDIUM
		elseif kind == "Peel" then
			w, h, yLo, yHi, level = between(random, 0.7, 1.1), between(random, 3.5, 5.5), 3.6, 6.5, MEDIUM
		else
			w, h, yLo, yHi, level = between(random, 1.6, 2.4), between(random, 1.4, 2), 6, 12, SMALL
		end
		onWalls(state, rooms, w, h, yLo, yHi, WALL_OUT, 8, function(spot)
			local name = nextName(state, kind)
			local pieces: { Piece } = { host(name, spot.cframe, w, h, "PlasterFlap", level) }
			local made = item(kind, pieces)
			local seed, color = seedOf(state, name), wallColor(spot.wall.room)
			if kind == "Mould" then
				made.painters[1] = function(part: BasePart)
					DreadArt.mould(part, seed)
				end
			elseif kind == "Peel" then
				made.painters[1] = function(part: BasePart)
					DreadArt.peel(part, seed, color)
				end
				-- the strip itself, curling away from the wall at its top
				local hinge = spot.cframe * CFrame.new(0, h / 2 - 0.1, 0)
				table.insert(
					pieces,
					detail(
						Kit.block(
							name .. "_Strip",
							hinge * CFrame.Angles(math.rad(between(random, 22, 38)), 0, 0) * CFrame.new(0, -0.9, -0.01),
							Vector3.new(w * 0.55, 1.8, 0.02),
							"PlasterFlap",
							"Detail",
							{ color = color, castShadow = false }
						),
						SMALL
					)
				)
			else
				local left = random:NextNumber() < 0.5
				made.painters[1] = function(part: BasePart)
					DreadArt.cobweb(part, seed, left)
				end
			end
			return made
		end)
	end
end

-- Dead fixtures on his loops: the wiring hanging out of the mount, a spark from its end now and then.
local function planHangingWire(state: State, number: number)
	local random = state.random
	local dead: { { room: Room, light: LayoutSchema.Light } } = {}
	for _, room in state.routeRooms do
		for _, light in (room.lights or {}) :: { LayoutSchema.Light } do
			if light.broken then
				table.insert(dead, { room = room, light = light })
			end
		end
	end
	for _, entry in shuffled(random, dead) do
		if (state.plan.counts.HangingWire or 0) >= number then
			return
		end
		local name = nextName(state, "HangingWire")
		local top = state.info.origin
			+ entry.light.pos
			+ Vector3.new(between(random, -0.3, 0.3), -0.15, between(random, -0.3, 0.3))
		local mid = top + Vector3.new(between(random, -0.4, 0.4), -between(random, 1, 1.6), between(random, -0.4, 0.4))
		local tail = mid
			+ Vector3.new(between(random, -0.3, 0.3), -between(random, 0.4, 0.8), between(random, -0.3, 0.3))
		local pieces = {
			detail(Kit.cylinder(name .. "_Wire", top, mid, 0.07, "Cable", "Detail", { castShadow = false }), MEDIUM),
			detail(
				Kit.cylinder(
					name .. "_End",
					mid,
					tail,
					0.06,
					"Cable",
					"Detail",
					{ color = Color3.fromRGB(120, 70, 40), castShadow = false }
				),
				SMALL
			),
		}
		local made = item("HangingWire", pieces)
		made.tags[2] = Tags.DreadSpark
		if fits(state, pieces, entry.room, nil, 0.1) then
			add(state, made)
		end
	end
end

-- Already-flickering circuits on his loops marked dying: soot round one of their bulbs, and the circuit's flicker group
-- and style stamped on it (the website's lighting gives those circuits their dying flicker; the light never changes).
local function planDying(state: State, number: number)
	local random = state.random
	local seen: { [string]: boolean } = {}
	local candidates: { { room: Room, light: LayoutSchema.Light } } = {}
	for _, room in state.routeRooms do
		for _, light in (room.lights or {}) :: { LayoutSchema.Light } do
			local group = light.flickerGroup
			if group and string.sub(group, 1, 8) == "Circuit:" and not light.broken and not seen[group] then
				seen[group] = true
				table.insert(candidates, { room = room, light = light })
			end
		end
	end
	for _, entry in shuffled(random, candidates) do
		if (state.plan.counts.DyingFixture or 0) >= number then
			return
		end
		local name = nextName(state, "DyingFixture")
		local y = SchoolShellBuilder.ceilingBottom(state.layout, entry.room) - 0.03
		local centre = state.info.origin + Vector3.new(entry.light.pos.X, y, entry.light.pos.Z)
		local cframe = CFrame.lookAt(centre, centre - Vector3.yAxis, Vector3.zAxis)
		local soot = host(name, cframe, 2.6, 2.6, "PlasterFlap", SMALL)
		local made = item("DyingFixture", { soot })
		local seed = seedOf(state, name)
		made.painters[1] = function(part: BasePart)
			DreadArt.soot(part, seed)
		end
		made.tags[1] = Tags.DyingFixture
		made.attributes[1] = {
			FlickerGroup = entry.light.flickerGroup,
			DyingStyle = if entry.light.kind == "Fluorescent" then "Tube" else "Pulse",
		}
		if fits(state, { soot }, entry.room, nil, -0.3) then
			add(state, made)
		end
	end
end

-- Dead flies along a window's sill.
local function planFlies(state: State, number: number)
	local windows = state.layout.windows
	if not windows then
		return
	end
	for _, window in shuffled(state.random, windows) do
		if (state.plan.counts.Flies or 0) >= number then
			return
		end
		local room = state.info.rooms[window.room]
		if not room then
			continue
		end
		-- the wall the window is in: N and S are the room's Z edges (the first two walls), W and E its X edges
		local walls = wallsOf(state, room)
		local wall = walls[({ N = 1, S = 2, W = 3, E = 4 } :: { [string]: number })[window.side]]
		if not wall then
			continue
		end
		local name = nextName(state, "Flies")
		-- on the bottom of the opening, just inside the wall's face (in front of the boards, if it is boarded)
		local spot = WallPlanner.cframe(state.info, wall, window.at, window.sill + 0.015, -0.17)
		local sill = host(
			name,
			spot * CFrame.Angles(math.rad(90), 0, 0),
			math.min(2.4, window.width - 0.4),
			0.3,
			"PlasterFlap",
			SMALL
		)
		local made = item("Flies", { sill })
		local seed = seedOf(state, name)
		made.painters[1] = function(part: BasePart)
			DreadArt.flies(part, seed)
		end
		if fits(state, { sill }, room, nil, -0.35) then
			add(state, made)
		end
	end
end

--------------------------------------------------------------------------------
-- Stations
--------------------------------------------------------------------------------

-- The story's stations: the longest runs of the floor (his loops' first), at least STATION_SPACING apart, where the
-- signs gather so they read together down a long sightline: claw marks on both walls, a line of writing, his trail
-- of porcelain and something one of them dropped running.
local STATION_SPACING = 40

local function pickStations(state: State, runs: { Room }, number: number): { Room }
	local onRoute: { [Room]: boolean } = {}
	for _, room in state.routeRooms do
		onRoute[room] = true
	end
	local ranked: { { room: Room, score: number } } = {}
	for _, room in runs do
		if not state.stubs[room.id] then
			local length = math.max(room.rect.w, room.rect.d)
			table.insert(ranked, { room = room, score = length + (if onRoute[room] then 30 else 0) })
		end
	end
	table.sort(ranked, function(a, b): boolean
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.room.id < b.room.id
	end)
	local out: { Room } = {}
	for _, entry in ranked do
		if #out >= number then
			break
		end
		local c = LayoutSchema.rectCenter(entry.room.rect)
		local apart = true
		for _, other in out do
			local o = LayoutSchema.rectCenter(other.rect)
			if (c - o).Magnitude < STATION_SPACING then
				apart = false
			end
		end
		if apart then
			table.insert(out, entry.room)
		end
	end
	return out
end

local function planStations(state: State, stations: { Room }, signatureStations: number)
	local kinds = { "Backpack", "Phone", "Shoe" }
	for i, room in stations do
		local level = if i <= signatureStations then nil else LOOK
		planGouges(state, 2, level, { room })
		planTrail(state, 3, 0, room)
		planDropped(state, kinds[(i - 1) % #kinds + 1], 1, if i <= 2 then nil else LOOK, room)
	end
end

-- Every keep-room (the workshop, the boiler rooms, the office, the classroom) and every school hallway shows what
-- happened in it: his hand down a wall, a chair or a desk knocked over, water coming through the ceiling.
local function planKeepRooms(state: State, rooms: { Room })
	for _, room in rooms do
		planGouges(state, 1, LOOK, { room })
		planKnockedOver(state, 1, { room })
		planStains(state, { room }, 1)
	end
end

--------------------------------------------------------------------------------
-- Plan and build
--------------------------------------------------------------------------------

local planCache: { [Layout]: { [string]: Plan } } = setmetatable({}, { __mode = "k" }) :: any

-- Everything the kit does to `layout` at `options.density` (pure: seeded by the layout's id; cached).
function DreadKit.plan(layout: Layout, options: Options?): Plan
	local o: Options = options or {}
	local density = math.clamp(o.density or 1, 0, 1)
	local key = string.format("%.3f|%s", density, if o.kinds then table.concat(o.kinds, ",") else "*")
	local cachedByKey = planCache[layout]
	if cachedByKey and cachedByKey[key] and not o.routes then
		return cachedByKey[key]
	end
	local taken = table.clone(FurnitureBuilder.plan(layout).mounts)
	for _, mount in DecayBuilder.wallMounts(layout) do
		table.insert(taken, mount)
	end
	local boxes = table.clone(FurnitureBuilder.plan(layout).footprints)
	local state: State = {
		layout = layout,
		info = Kit.info(layout),
		density = density,
		plan = {
			layoutId = layout.id,
			density = density,
			items = {},
			parts = 0,
			signature = 0,
			decals = 0,
			counts = {},
			mounts = {},
			texts = {},
		},
		random = Rng.seeded(1, layout.id .. ":dread"),
		walls = {},
		taken = taken,
		clear = DreadKit.clearances(layout),
		boxes = boxes,
		routeRooms = {},
		routePoints = {},
		keepRooms = {},
		stubs = {},
		kinds = nil,
		serial = 0,
	}
	if o.kinds then
		local allowed: { [string]: boolean } = {}
		for _, kind in o.kinds do
			allowed[kind] = true
		end
		state.kinds = allowed
	end
	for _, door in layout.doors do
		local a, b = state.info.rooms[door.rooms[1]], state.info.rooms[door.rooms[2]]
		if a and b then
			local landing = function(room: Room): boolean
				return room.kind == "Airlock" or room.kind == "Stairwell"
			end
			if landing(a) then
				state.stubs[b.id] = true
			elseif landing(b) then
				state.stubs[a.id] = true
			end
		end
	end
	local walk: { Room } = {}
	local runs: { Room } = {}
	for _, room in layout.rooms do
		if WALK_KINDS[room.kind] then
			table.insert(walk, room)
			if RUN_KINDS[room.kind] then
				table.insert(runs, room)
			end
			if KEEP_KINDS[room.kind] then
				table.insert(state.keepRooms, room)
			end
		end
	end
	sampleRoutes(state, o.routes or DreadKit.patrolLoops(layout), walk)
	if #state.routeRooms == 0 then
		-- a stage without loops: its runs (or, with none, its rooms) stand in for them
		local stand: { Room } = if #runs > 0 then runs else walk
		for _, room in stand do
			table.insert(state.routeRooms, room)
			local c = LayoutSchema.rectCenter(room.rect)
			table.insert(state.routePoints, { room = room, x = c.X, z = c.Y })
		end
	end
	local anyRooms = if #state.keepRooms > 0 then state.keepRooms else state.routeRooms
	local hallRooms: { Room } = table.clone(state.keepRooms)
	for _, room in layout.rooms do
		if room.kind == "Corridor" then
			table.insert(hallRooms, room)
		end
	end
	local wallRooms = table.clone(state.keepRooms)
	for _, room in state.routeRooms do
		table.insert(wallRooms, room)
	end

	-- signature first (the story on every tier), then the Detail that thickens it
	local stations = pickStations(state, if #runs > 0 then runs else wallRooms, count(state, 9))
	planWriting(state, wallRooms, if #runs > 0 then runs else wallRooms, stations)
	planClocks(state, anyRooms, math.max(1, count(state, 3)))
	planPaperOnWall(state, wallRooms, "Notice", math.max(1, count(state, 2)))
	planPaperOnWall(state, wallRooms, "Drawing", count(state, 1))
	planStations(state, stations, count(state, 3))
	planForcedFrames(state, count(state, 1), true)
	planCoats(state, wallRooms)
	planBarricade(
		state,
		if state.layout.id == "Level1_Hallways" then { "L1_MainOffice", "L1_Classroom_108" } else {},
		true
	)
	planTrail(state, 0, count(state, 1))
	planDropped(state, "Phone", count(state, 2), nil)
	planDropped(state, "Backpack", count(state, 1), nil)
	planTrophyCase(state, if state.layout.id == "Level1_Hallways" then hallRooms else {})

	planKeepRooms(state, hallRooms)
	planDying(state, count(state, DreadConfig.Light.DyingPerFloor))
	planHangingWire(state, count(state, 5))
	planFlies(state, count(state, 1))
	planTally(state, count(state, 2))
	planWallDecay(state, wallRooms, "Cobweb", count(state, 8))
	planGougeRuns(state, count(state, 44))
	planCeilingGouges(state, count(state, 6))
	planForcedFrames(state, count(state, 2), false)
	planStains(state, wallRooms, count(state, 10))
	planDropped(state, "Backpack", count(state, 3), LOOK)
	planDropped(state, "Shoe", count(state, 4), nil)
	planDropped(state, "Phone", count(state, 2), MEDIUM)
	planKnockedOver(state, count(state, 2))
	planLockerDoors(state, count(state, 3))
	planWallDecay(state, wallRooms, "Mould", count(state, 8))
	planWallDecay(state, wallRooms, "Peel", count(state, 5))
	planTrail(state, count(state, 14), 0)
	planDropped(state, "Papers", count(state, 6), nil)

	if not o.routes then
		local byKey = planCache[layout] or {}
		planCache[layout] = byKey
		byKey[key] = state.plan
	end
	return state.plan
end

-- The options DreadConfig.Levels gives `layoutId` (nil: the stage is not dressed by DreadBuilder).
function DreadKit.levelOptions(layoutId: string): Options?
	local level = DreadConfig.Levels[layoutId]
	if not level then
		return nil
	end
	return { density = level.density, kinds = level.kinds }
end

-- The kit's wall spots on `layout` as DreadBuilder dresses it (SignageBuilder keeps its signs off them).
function DreadKit.wallMounts(layout: Layout): { Mount }
	local options = DreadKit.levelOptions(layout.id)
	if not options then
		return {}
	end
	return DreadKit.plan(layout, options).mounts
end

-- Drips and sparks: the website draws its own particles at the tagged parts; on Roblox the emitters below do.
local function dripEmitter(part: BasePart)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Drip"
	emitter.Rate = 0.9
	emitter.Lifetime = NumberRange.new(0.7, 0.9)
	emitter.Speed = NumberRange.new(0, 0)
	emitter.Acceleration = Vector3.new(0, -24, 0)
	emitter.Size = NumberSequence.new(0.06)
	emitter.Color = ColorSequence.new(Color3.fromRGB(170, 180, 175))
	emitter.LightInfluence = 1
	emitter.Parent = part
end

local function sparkEmitter(part: BasePart)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Sparks"
	emitter.Rate = 0.5
	emitter.Lifetime = NumberRange.new(0.25, 0.5)
	emitter.Speed = NumberRange.new(4, 9)
	emitter.SpreadAngle = Vector2.new(60, 60)
	emitter.Acceleration = Vector3.new(0, -40, 0)
	emitter.Size = NumberSequence.new(0.07)
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 190, 110))
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Parent = part
end

-- Builds `plan` into `parent` as one Model "Dread_<layoutId>". Returns the parts built.
function DreadKit.build(parent: Instance, layout: Layout, plan: Plan): number
	if #plan.items == 0 then
		return 0
	end
	local info = Kit.info(layout)
	local model = PropKit.model(parent, "Dread_" .. layout.id, CFrame.new(info.origin))
	model:SetAttribute(W.LevelId, layout.id)
	local built = 0
	for _, entry in plan.items do
		local parts = Kit.realize(model, entry.pieces, nil)
		for index, part in parts do
			local painter = entry.painters[index]
			if painter then
				painter(part)
			end
			local tag = entry.tags[index]
			if tag then
				part:AddTag(tag)
				if tag == Tags.DreadDrip then
					dripEmitter(part)
				elseif tag == Tags.DreadSpark then
					sparkEmitter(part)
				end
			end
			local attributes = entry.attributes[index]
			if attributes then
				PropKit.setAttributes(part, attributes)
			end
			part:SetAttribute("DreadKind", entry.kind)
		end
		built += #parts
	end
	return built
end

return table.freeze(DreadKit)
