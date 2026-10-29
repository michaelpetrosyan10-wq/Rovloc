--!strict
-- PoolWaterBuilder: static "PoolDressing", the wreck of the natatorium around every pool basin (Level4_FloodedPool).
--
-- The water itself (the basin shell, its murky surface part and the PoolWater volume) is SchoolShellBuilder's; this
-- dresses it from the layout's basin and platform data:
--   * the collapsed walkways: where a bridge fragment breaks off toward the next one across open water, a slab chunk
--     hangs from the broken edge down into the water, rusted rebar sticks out of the break, the edge is cracked and
--     spalled lumps lie half sunk at its foot; across a step-over crack (StepOver or narrower) only rebar stubs and a
--     crack line show, so nothing fills the crack; the fallen roof slabs get rebar and rubble too;
--   * a low kerb (the lip, "Lip<i>") along every open-water edge of every walkway fragment, left open where the slab
--     faces the next piece of the route, so a walker feels the edge before the drop;
--   * lane ropes strung with floats (red near the walls), snapped and sagging, between the starting-block lanes;
--   * the starting blocks' grab bars, chips and stains (their tops stay clear: flasks stand on them); pool ladders
--     over the coping on the decks;
--   * the diving board snapped off the deep-end tower, its far half adrift, a handrail post wrenched over the drop;
--   * a toppled lifeguard chair on the deck, kickboards, a sunken chair and scum on the water;
--   * the deep-end drain grate; broken and missing tiles on the decks and the coping.
--
-- No-bypass rule: the layout's walkway decides every crossing; the dressing never shortens a swim. Every colliding
-- piece over open water has its highest point at least NoBypassDepth under the surface (a chunk that breaks the
-- surface is split there: the part under that line collides, the part above is seen but never collides), so nothing
-- new can be stood on between the fragments. The lips stand on their fragment, never over open water. Ropes, floats,
-- boards, ladders and debris on the water never collide. The deck chair collides (Creature passes).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

local Geometry = require(script.Parent.Parent.Geometry)
local PropKit = require(script.Parent.PropKit)
local SetDressingBuilder = require(script.Parent.SetDressingBuilder)

local log = Log.new("PoolDressing")

type Layout = LayoutSchema.LevelLayout
type Rect = LayoutSchema.Rect
type Basin = LayoutSchema.Basin
type Platform = LayoutSchema.Platform
type Piece = SetDressingBuilder.Piece
type LevelInfo = SetDressingBuilder.LevelInfo

local Kit = SetDressingBuilder.Kit
local W = Attributes.World

local EPS = 1e-3
local BUDGET = 260
local NO_BYPASS = 0.6 -- colliding dressing over open water keeps its top this far below the surface
local TILT_LIMIT = 40 -- degrees; the rule's alternative for a colliding chunk (this builder never relies on it)
local BREAK_REACH = 14 -- a fragment across a gap at most this wide is the next piece of the same walkway
local STEP_OVER = 1.5 -- a gap at most this wide is a crack the walkway steps over (no jump, no swim)
local LIP_WIDTH = 0.3
local LIP_HEIGHT = 0.3
local LIP_INSET = 0.03 -- from the fragment's edge
local LIP_OPENING = 0.5 -- the lip stops this far short of the stretch facing the next piece
local LIP_MIN = 0.8

export type Fragment = {
	id: string,
	rect: Rect,
	top: number,
	thickness: number,
}

export type Classified = {
	interior: Rect, -- open water (inside the coping)
	fragments: { Fragment }, -- awash walkway pieces standing in the basin
	towers: { Fragment }, -- tall platforms in the basin (diving tower)
	blocks: { Fragment }, -- starting blocks on the deck at the basin edge
	obstacles: { Rect }, -- every platform footprint in the basin (fragments, piers, towers)
}

export type BreakEdge = {
	fragment: Fragment,
	direction: Vector3, -- outward, level-local unit X or Z
	gap: number, -- open water to the next fragment
}

local PoolWaterBuilder = {}

PoolWaterBuilder.Budget = BUDGET
PoolWaterBuilder.NoBypassDepth = NO_BYPASS
PoolWaterBuilder.TiltLimit = TILT_LIMIT
PoolWaterBuilder.StepOver = STEP_OVER
PoolWaterBuilder.BreakReach = BREAK_REACH
PoolWaterBuilder.LipHeight = LIP_HEIGHT

--------------------------------------------------------------------------------
-- Helpers
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

local function between(random: Random, a: number, b: number): number
	return random:NextNumber(a, b)
end

local function chance(random: Random, p: number): boolean
	return random:NextNumber() < p
end

local function pick<T>(random: Random, list: { T }): T
	return list[random:NextInteger(1, #list)]
end

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local function paint(color: Color3, material: Enum.Material?, transparency: number?): Geometry.PartOptions
	return { color = color, material = material, transparency = transparency }
end

local function inflate(r: Rect, by: number): Rect
	return { x = r.x - by, z = r.z - by, w = r.w + by * 2, d = r.d + by * 2 }
end

local function pointIn(r: Rect, x: number, z: number): boolean
	return x >= r.x and x <= r.x + r.w and z >= r.z and z <= r.z + r.d
end

local function rectsOverlap(a: Rect, b: Rect): boolean
	return LayoutSchema.rectOverlapArea(a, b) > 0
end

-- Footprint (level-local rect) of a set of world pieces.
local function footprint(info: LevelInfo, pieces: { Piece }): Rect
	local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
	for _, piece in pieces do
		local box = Kit.localBox(info, piece)
		x0, z0 = math.min(x0, box.x0), math.min(z0, box.z0)
		x1, z1 = math.max(x1, box.x1), math.max(z1, box.z1)
	end
	return { x = x0, z = z0, w = x1 - x0, d = z1 - z0 }
end

local function lowest(pieces: { Piece }): number
	local y = math.huge
	for _, piece in pieces do
		local lo = Kit.bounds(piece)
		y = math.min(y, lo.Y)
	end
	return y
end

--------------------------------------------------------------------------------
-- Classification (pure layout maths; the spec checks the same data)
--------------------------------------------------------------------------------

-- Sorts the platforms of a basin's room into walkway fragments, towers and starting blocks.
function PoolWaterBuilder.classify(layout: Layout, basin: Basin): Classified
	local interior = Geometry.insetRect(basin.rect, Geometry.BasinWall)
	local out: Classified = { interior = interior, fragments = {}, towers = {}, blocks = {}, obstacles = {} }
	for _, platform in (layout.platforms or {}) :: { Platform } do
		if platform.room ~= basin.room then
			continue
		end
		local r = platform.rect
		local entry: Fragment = { id = platform.id, rect = r, top = platform.top, thickness = platform.thickness }
		local inBasin = LayoutSchema.rectInside(r, basin.rect)
		if inBasin then
			table.insert(out.obstacles, r)
			if platform.thickness <= 3 and platform.top >= basin.waterLevel - 0.8 and platform.top <= 0.5 then
				table.insert(out.fragments, entry)
			elseif platform.top >= 4 then
				table.insert(out.towers, entry)
			end
		elseif
			not rectsOverlap(r, interior)
			and platform.top >= 0.8
			and platform.top <= 2.5
			and r.w <= 4.5
			and r.d <= 4.5
			and rectsOverlap(inflate(r, 4), basin.rect)
		then
			table.insert(out.blocks, entry)
		end
	end
	return out
end

-- The sides of walkway fragments that broke off toward another fragment across open water.
function PoolWaterBuilder.breakEdges(classified: Classified): { BreakEdge }
	local out: { BreakEdge } = {}
	for _, f in classified.fragments do
		for _, direction in { Vector3.xAxis, -Vector3.xAxis, Vector3.zAxis, -Vector3.zAxis } do
			local alongX = math.abs(direction.X) > 0.5
			local sign = if alongX then direction.X else direction.Z
			local fa0 = if alongX then f.rect.x else f.rect.z
			local fa1 = fa0 + (if alongX then f.rect.w else f.rect.d)
			local fc0 = if alongX then f.rect.z else f.rect.x
			local fc1 = fc0 + (if alongX then f.rect.d else f.rect.w)
			local best = math.huge
			for _, g in classified.fragments do
				if g == f then
					continue
				end
				local ga0 = if alongX then g.rect.x else g.rect.z
				local ga1 = ga0 + (if alongX then g.rect.w else g.rect.d)
				local gc0 = if alongX then g.rect.z else g.rect.x
				local gc1 = gc0 + (if alongX then g.rect.d else g.rect.w)
				if math.min(fc1, gc1) - math.max(fc0, gc0) < 2 then
					continue
				end
				local gap = if sign > 0 then ga0 - fa1 else fa0 - ga1
				if gap > EPS and gap <= BREAK_REACH then
					best = math.min(best, gap)
				end
			end
			if best < math.huge then
				table.insert(out, { fragment = f, direction = direction, gap = best })
			end
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- The route across the water (pure layout maths; the specs and the fairness report read the same answers)
--------------------------------------------------------------------------------

export type DryGroup = {
	rects: { Rect }, -- every dry spot joined to the others by step-overs
	deck: boolean, -- holds part of the hall's deck
}

export type SwimLeg = { a: number, b: number, length: number } -- groups a and b, open water between them

-- Horizontal distance between two rects (0 when they touch or overlap).
function PoolWaterBuilder.rectGap(a: Rect, b: Rect): number
	local dx = math.max(0, a.x - (b.x + b.w), b.x - (a.x + a.w))
	local dz = math.max(0, a.z - (b.z + b.d), b.z - (a.z + a.d))
	return math.sqrt(dx * dx + dz * dz)
end

-- Horizontal distance from (x, z) to a rect (0 inside it).
function PoolWaterBuilder.pointGap(r: Rect, x: number, z: number): number
	local dx = math.max(0, r.x - x, x - (r.x + r.w))
	local dz = math.max(0, r.z - z, z - (r.z + r.d))
	return math.sqrt(dx * dx + dz * dz)
end

-- Safe dry spots of a basin's hall: the deck (the hall's floor outside the basin) and every platform in the basin a
-- swimmer can climb onto and stand on (its top `climbMin` to `climbMax` over the water), joined into groups wherever
-- a step-over (StepOver or less) separates them. Group 1 holds the deck when the hall has one.
function PoolWaterBuilder.dryGroups(layout: Layout, basin: Basin, climbMin: number, climbMax: number): { DryGroup }
	local rooms = LayoutSchema.indexRooms(layout)
	local room = rooms[basin.room]
	local rects: { Rect } = {}
	local decks: { [number]: boolean } = {}
	if room then
		for _, piece in Geometry.subtractRects(room.rect, { basin.rect }) do
			table.insert(rects, piece)
			decks[#rects] = true
		end
	end
	for _, platform in (layout.platforms or {}) :: { Platform } do
		local above = platform.top - basin.waterLevel
		if
			platform.room == basin.room
			and LayoutSchema.rectOverlapArea(platform.rect, basin.rect) > 0
			and above >= climbMin - EPS
			and above <= climbMax + EPS
		then
			table.insert(rects, platform.rect)
		end
	end
	-- union-find over step-over joins
	local parent: { number } = {}
	for i = 1, #rects do
		parent[i] = i
	end
	local function find(i: number): number
		while parent[i] ~= i do
			parent[i] = parent[parent[i]]
			i = parent[i]
		end
		return i
	end
	for i = 1, #rects do
		for j = i + 1, #rects do
			if PoolWaterBuilder.rectGap(rects[i], rects[j]) <= STEP_OVER + EPS then
				parent[find(i)] = find(j)
			end
		end
	end
	local byRoot: { [number]: DryGroup } = {}
	local out: { DryGroup } = {}
	for i, r in rects do
		local root = find(i)
		local found: DryGroup? = byRoot[root]
		local group: DryGroup
		if found then
			group = found
		else
			group = { rects = {}, deck = false }
			byRoot[root] = group
			table.insert(out, group)
		end
		table.insert(group.rects, r)
		group.deck = group.deck or decks[i] == true
	end
	return out
end

-- Open water between two dry groups (the shortest gap between any of their spots).
function PoolWaterBuilder.groupGap(a: DryGroup, b: DryGroup): number
	local best = math.huge
	for _, ra in a.rects do
		for _, rb in b.rects do
			best = math.min(best, PoolWaterBuilder.rectGap(ra, rb))
		end
	end
	return best
end

-- The swim legs that join every dry group with the shortest swims (a minimum spanning tree over the groups), longest
-- last. Its last leg is the longest swim anyone ever has to make between two safe dry spots.
function PoolWaterBuilder.swimLegs(groups: { DryGroup }): { SwimLeg }
	local candidates: { SwimLeg } = {}
	for i = 1, #groups do
		for j = i + 1, #groups do
			table.insert(candidates, { a = i, b = j, length = PoolWaterBuilder.groupGap(groups[i], groups[j]) })
		end
	end
	table.sort(candidates, function(p: SwimLeg, q: SwimLeg): boolean
		return p.length < q.length
	end)
	local parent: { number } = {}
	for i = 1, #groups do
		parent[i] = i
	end
	local function find(i: number): number
		while parent[i] ~= i do
			i = parent[i]
		end
		return i
	end
	local out: { SwimLeg } = {}
	for _, leg in candidates do
		local ra, rb = find(leg.a), find(leg.b)
		if ra ~= rb then
			parent[ra] = rb
			table.insert(out, leg)
		end
	end
	return out
end

-- Horizontal swim from (x, z) to the nearest safe dry spot.
function PoolWaterBuilder.swimToDry(groups: { DryGroup }, x: number, z: number): number
	local best = math.huge
	for _, group in groups do
		for _, r in group.rects do
			best = math.min(best, PoolWaterBuilder.pointGap(r, x, z))
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- Collapsed walkways
--------------------------------------------------------------------------------

local CONCRETE = "ConcreteStained"
local REBAR = paint(rgb(70, 44, 30), Enum.Material.CorrodedMetal)
local SPALL = paint(rgb(72, 70, 62), Enum.Material.Slate)
local CRACK = paint(rgb(26, 26, 24), Enum.Material.SmoothPlastic)

-- Level-local frame on the top of a fragment's edge: -Z outward, X along the edge.
local function edgeFrame(info: LevelInfo, f: Fragment, direction: Vector3, u: number): CFrame
	local r = f.rect
	local p: Vector3
	if direction.X > 0.5 then
		p = Vector3.new(r.x + r.w, f.top, u)
	elseif direction.X < -0.5 then
		p = Vector3.new(r.x, f.top, u)
	elseif direction.Z > 0.5 then
		p = Vector3.new(u, f.top, r.z + r.d)
	else
		p = Vector3.new(u, f.top, r.z)
	end
	return CFrame.lookAt(info.origin + p, info.origin + p + direction)
end

local function edgeRange(f: Fragment, direction: Vector3): (number, number)
	if math.abs(direction.X) > 0.5 then
		return f.rect.z, f.rect.z + f.rect.d
	end
	return f.rect.x, f.rect.x + f.rect.w
end

-- A slab chunk hanging from the broken edge into the water, split where its top crosses the no-bypass line.
local function hangingChunk(
	info: LevelInfo,
	edge: BreakEdge,
	waterY: number,
	random: Random,
	u0: number,
	u1: number
): { Piece }
	local f = edge.fragment
	local width = u1 - u0
	local frame = edgeFrame(info, f, edge.direction, (u0 + u1) / 2)
	local theta = math.rad(between(random, 32, 56))
	local length = math.min(between(random, 2.4, 3.4), edge.gap * 0.32 / math.cos(theta))
	local thick = math.min(f.thickness * 0.85, 1)
	local hingeY = -0.12
	local s = Vector3.new(0, -math.sin(theta), -math.cos(theta)) -- down the slab, outward
	local up = Vector3.new(0, math.cos(theta), -math.sin(theta))
	local function segment(name: string, a: number, b: number, role: SetDressingBuilder.Role): Piece
		local centre = Vector3.new(between(random, -0.05, 0.05), hingeY, 0.05) + s * ((a + b) / 2) - up * (thick / 2)
		local cf = CFrame.fromMatrix(frame:PointToWorldSpace(centre), frame.RightVector, frame:VectorToWorldSpace(up))
		return Kit.block(name, cf, Vector3.new(width, thick, b - a), CONCRETE, role)
	end
	-- The slab's top surface is at f.top + hingeY - t * sin(theta) a distance t down the slab.
	local limit = waterY - NO_BYPASS - 0.02
	local split = (f.top + hingeY - limit) / math.sin(theta)
	if split >= length - 0.3 then
		return { segment("Chunk", 0, length, "Visible") }
	end
	split = math.max(split, 0)
	local out = { segment("ChunkUnder", split, length, "Solid") }
	if split > 0.05 then
		table.insert(out, segment("Chunk", 0, split + 0.02, "Visible"))
	end
	return out
end

local function rebar(info: LevelInfo, f: Fragment, direction: Vector3, u: number, random: Random, index: number): Piece
	local frame = edgeFrame(info, f, direction, u)
	local y = -between(random, 0.18, math.max(0.25, f.thickness - 0.2))
	local bend = math.rad(between(random, 5, 48))
	local sway = between(random, -0.25, 0.25)
	local length = between(random, 0.8, 2)
	local a = frame:PointToWorldSpace(Vector3.new(0, y, 0.2))
	local b =
		frame:PointToWorldSpace(Vector3.new(sway * length, y - math.sin(bend) * length, 0.2 - math.cos(bend) * length))
	return Kit.cylinder("Rebar" .. index, a, b, 0.11, "Iron", "Detail", REBAR)
end

-- A lump spalled off the edge, half sunk at the waterline just off it (never stood on: it does not collide).
local function rubble(
	info: LevelInfo,
	f: Fragment,
	direction: Vector3,
	u: number,
	waterY: number,
	random: Random,
	index: number
): Piece
	local frame = edgeFrame(info, f, direction, u)
	local size = Vector3.new(between(random, 0.7, 1.4), between(random, 0.45, 0.8), between(random, 0.55, 1))
	local cf = frame
		* CFrame.new(between(random, -0.3, 0.3), waterY - f.top - between(random, 0, 0.15), -between(random, 0.4, 0.9))
		* CFrame.Angles(
			math.rad(between(random, -25, 25)),
			math.rad(between(random, 0, 360)),
			math.rad(between(random, -25, 25))
		)
	return Kit.block("Rubble" .. index, cf, size, "Rubble", "Detail", SPALL)
end

local function crackLine(
	info: LevelInfo,
	f: Fragment,
	direction: Vector3,
	u: number,
	random: Random,
	index: number
): Piece
	local frame = edgeFrame(info, f, direction, u)
	local length = between(random, 1.4, 2.8)
	local cf = frame * CFrame.new(0, 0.01, length / 2 + 0.02) * ry(between(random, -25, 25))
	return Kit.block("Crack" .. index, cf, Vector3.new(0.07, 0.02, length), "Rubber", "Detail", CRACK)
end

local function planWalkways(info: LevelInfo, classified: Classified, basin: Basin, random: Random): { Piece }
	local pieces: { Piece } = {}
	local waterY = basin.waterLevel
	local edges = PoolWaterBuilder.breakEdges(classified)
	local broken: { [Fragment]: boolean } = {}
	for i, edge in edges do
		local f = edge.fragment
		broken[f] = true
		local e0, e1 = edgeRange(f, edge.direction)
		local length = e1 - e0
		if edge.gap <= STEP_OVER + EPS then
			-- A step-over crack: stubs of rebar and the crack line only, nothing reaching into the crack
			table.insert(
				pieces,
				rebar(info, f, edge.direction, between(random, e0 + 0.3, e1 - 0.3), random, i * 10 + 1)
			)
			table.insert(pieces, crackLine(info, f, edge.direction, between(random, e0 + 0.8, e1 - 0.8), random, i))
			continue
		end
		local width = length * between(random, 0.45, 0.7)
		local c = between(random, e0 + width / 2 + 0.4, e1 - width / 2 - 0.4)
		for _, piece in hangingChunk(info, edge, waterY, random, c - width / 2, c + width / 2) do
			piece.name = piece.name .. i
			table.insert(pieces, piece)
		end
		for k = 1, random:NextInteger(2, 3) do
			table.insert(
				pieces,
				rebar(info, f, edge.direction, between(random, e0 + 0.3, e1 - 0.3), random, i * 10 + k)
			)
		end
		-- Spalling on the stretch of edge the chunk left bare
		local left, right = c - width / 2 - e0, e1 - (c + width / 2)
		local u = if left > right
			then between(random, e0 + 0.6, c - width / 2 - 0.4)
			else between(random, c + width / 2 + 0.4, e1 - 0.6)
		table.insert(pieces, rubble(info, f, edge.direction, u, waterY, random, i))
		table.insert(pieces, crackLine(info, f, edge.direction, between(random, e0 + 0.8, e1 - 0.8), random, i))
	end
	-- Fallen slabs (no walkway either side): rebar and spalling round the edges
	for i, f in classified.fragments do
		if broken[f] then
			continue
		end
		local sides: { Vector3 } = { Vector3.xAxis, -Vector3.xAxis, Vector3.zAxis, -Vector3.zAxis }
		MathUtil.shuffle(sides, random)
		for k = 1, 2 do
			local direction = sides[k]
			local e0, e1 = edgeRange(f, direction)
			table.insert(
				pieces,
				rebar(info, f, direction, between(random, e0 + 0.4, e1 - 0.4), random, 100 + i * 10 + k)
			)
			table.insert(
				pieces,
				rubble(info, f, direction, between(random, e0 + 1, e1 - 1), waterY, random, 100 + i * 10 + k)
			)
		end
	end
	return pieces
end

-- The stretches of side `direction` of fragment `f` that face open water: not the stretch facing another piece in
-- the basin within BreakReach (the next slab of the route, a footing), and not a side lying on the coping.
function PoolWaterBuilder.openSides(classified: Classified, f: Fragment, direction: Vector3): { { number } }
	local interior = classified.interior
	local r = f.rect
	local alongX = math.abs(direction.X) > 0.5 -- the side faces along X (it runs along Z)
	local sign = if alongX then direction.X else direction.Z
	local line = if alongX then (if sign > 0 then r.x + r.w else r.x) else (if sign > 0 then r.z + r.d else r.z)
	local i0 = if alongX then interior.x else interior.z
	local i1 = i0 + (if alongX then interior.w else interior.d)
	if line <= i0 + EPS or line >= i1 - EPS then
		return {}
	end
	local e0, e1 = edgeRange(f, direction)
	local cuts: { { number } } = {}
	for _, o in classified.obstacles do
		if o == r then
			continue
		end
		local oa0 = if alongX then o.x else o.z
		local oa1 = oa0 + (if alongX then o.w else o.d)
		local oc0 = if alongX then o.z else o.x
		local oc1 = oc0 + (if alongX then o.d else o.w)
		local gap = if sign > 0 then oa0 - line else line - oa1
		if gap > -EPS and gap <= BREAK_REACH and math.min(e1, oc1) - math.max(e0, oc0) > EPS then
			table.insert(cuts, { math.max(e0, oc0) - LIP_OPENING, math.min(e1, oc1) + LIP_OPENING })
		end
	end
	table.sort(cuts, function(a: { number }, b: { number }): boolean
		return a[1] < b[1]
	end)
	local out: { { number } } = {}
	local cursor = e0 + LIP_INSET
	for _, cut in cuts do
		if cut[1] - cursor >= LIP_MIN then
			table.insert(out, { cursor, cut[1] })
		end
		cursor = math.max(cursor, cut[2])
	end
	if e1 - LIP_INSET - cursor >= LIP_MIN then
		table.insert(out, { cursor, e1 - LIP_INSET })
	end
	return out
end

-- Low kerbs along every walkway fragment's open-water edges (they collide; the Creature passes).
local function planLips(info: LevelInfo, classified: Classified): { Piece }
	local pieces: { Piece } = {}
	local count = 0
	for _, f in classified.fragments do
		for _, direction in { Vector3.xAxis, -Vector3.xAxis, Vector3.zAxis, -Vector3.zAxis } do
			for _, stretch in PoolWaterBuilder.openSides(classified, f, direction) do
				count += 1
				local frame = edgeFrame(info, f, direction, (stretch[1] + stretch[2]) / 2)
				local cf = frame * CFrame.new(0, LIP_HEIGHT / 2, LIP_INSET + LIP_WIDTH / 2)
				table.insert(
					pieces,
					Kit.block(
						"Lip" .. count,
						cf,
						Vector3.new(stretch[2] - stretch[1], LIP_HEIGHT, LIP_WIDTH),
						CONCRETE,
						"Solid"
					)
				)
			end
		end
	end
	return pieces
end

--------------------------------------------------------------------------------
-- Lane ropes
--------------------------------------------------------------------------------

local FLOAT_COLORS: { Color3 } = { rgb(54, 72, 104), rgb(150, 146, 132), rgb(54, 72, 104), rgb(126, 108, 50) }
local FLOAT_RED = rgb(120, 52, 46)
local WALL_RED = 5 -- floats this close to the end walls are red
local FLOAT_SPACING = 4.5 -- closest float pitch along a rope
local FLOAT_CAP = 56 -- floats across every lane rope (part budget)
local FLOAT_LENGTH = 0.9

-- One unbroken stretch of lane rope: from p0 to p1 (world), s0..s1 along the lane axis (level-local).
type RopeSpan = { tag: string, p0: Vector3, p1: Vector3, s0: number, s1: number, lane: number }

-- Lane lines between and beside the starting blocks, running away from the deck they stand on.
local function laneLines(classified: Classified): (boolean, { number })
	local interior = classified.interior
	local blocks = classified.blocks
	if #blocks == 0 then
		local alongX = interior.w >= interior.d
		local span = if alongX then interior.d else interior.w
		local lines: { number } = {}
		local count = math.floor(span / 9)
		for i = 1, count - 1 do
			table.insert(lines, (if alongX then interior.z else interior.x) + span * i / count)
		end
		return alongX, lines
	end
	-- Blocks along an X-facing edge (constant x) mean lanes run along X.
	local cx, cz = 0, 0
	for _, block in blocks do
		cx += block.rect.x + block.rect.w / 2
		cz += block.rect.z + block.rect.d / 2
	end
	cx /= #blocks
	cz /= #blocks
	local nearX = math.min(math.abs(cx - interior.x), math.abs(cx - (interior.x + interior.w)))
	local nearZ = math.min(math.abs(cz - interior.z), math.abs(cz - (interior.z + interior.d)))
	local alongX = nearX <= nearZ
	local centres: { number } = {}
	for _, block in blocks do
		table.insert(centres, if alongX then block.rect.z + block.rect.d / 2 else block.rect.x + block.rect.w / 2)
	end
	table.sort(centres)
	local spacing = math.huge
	for i = 2, #centres do
		spacing = math.min(spacing, centres[i] - centres[i - 1])
	end
	if spacing == math.huge then
		spacing = 12
	end
	local lo = if alongX then interior.z else interior.x
	local hi = lo + (if alongX then interior.d else interior.w)
	local raw: { number } = {}
	for i, c in centres do
		table.insert(raw, c - spacing / 2)
		table.insert(raw, c + spacing / 2)
		if i > 1 and c - centres[i - 1] <= spacing * 1.5 then
			table.insert(raw, (c + centres[i - 1]) / 2)
		end
	end
	table.sort(raw)
	local lines: { number } = {}
	for _, value in raw do
		if value > lo + 5 and value < hi - 5 and (#lines == 0 or value - lines[#lines] > 1) then
			table.insert(lines, value)
		end
	end
	return alongX, lines
end

local function planRopes(info: LevelInfo, classified: Classified, basin: Basin, random: Random): { Piece }
	local pieces: { Piece } = {}
	local interior = classified.interior
	local alongX, lines = laneLines(classified)
	local waterY = basin.waterLevel
	local a0 = (if alongX then interior.x else interior.z) + 0.3
	local a1 = (if alongX then interior.x + interior.w else interior.z + interior.d) - 0.3
	local function point(a: number, c: number, y: number): Vector3
		return info.origin + (if alongX then Vector3.new(a, y, c) else Vector3.new(c, y, a))
	end
	local gone = if #lines > 3 then random:NextInteger(1, #lines) else 0
	local spans: { RopeSpan } = {}
	local total = 0
	for index, c in lines do
		if index == gone then
			continue -- this rope has sunk without trace
		end
		-- Clear stretches of the line, broken wherever a fragment, pier or tower stands in it
		local blocked: { { number } } = {}
		for _, r in classified.obstacles do
			local c0 = if alongX then r.z else r.x
			local c1 = c0 + (if alongX then r.d else r.w)
			if c >= c0 - 0.7 and c <= c1 + 0.7 then
				local o0 = if alongX then r.x else r.z
				table.insert(blocked, { o0 - 0.9, o0 + (if alongX then r.w else r.d) + 0.9 })
			end
		end
		table.sort(blocked, function(p: { number }, q: { number }): boolean
			return p[1] < q[1]
		end)
		local stretches: { { number } } = {}
		local cursor = a0
		for _, interval in blocked do
			if interval[1] > cursor + 3 then
				table.insert(stretches, { cursor, interval[1] })
			end
			cursor = math.max(cursor, interval[2])
		end
		if a1 > cursor + 3 then
			table.insert(stretches, { cursor, a1 })
		end
		-- Snap each long stretch once: two pieces with a gap between their frayed ends
		local runs: { { number } } = {}
		for _, stretch in stretches do
			local length = stretch[2] - stretch[1]
			if length > 18 and chance(random, 0.75) then
				local cut = between(random, stretch[1] + length * 0.3, stretch[2] - length * 0.3)
				local gap = between(random, 1.5, 4)
				table.insert(runs, { stretch[1], cut - gap / 2, 1 })
				table.insert(runs, { cut + gap / 2, stretch[2], 2 })
			else
				table.insert(runs, { stretch[1], stretch[2], 0 })
			end
		end
		for k, run in runs do
			local s0, s1, freeEnd = run[1], run[2], run[3]
			-- A free end sags under the surface; an anchored end sits at it
			local sag0 = if freeEnd == 2 or (s0 > a0 + 0.5 and freeEnd ~= 1) then between(random, 0.3, 0.8) else 0
			local sag1 = if freeEnd == 1 or (s1 < a1 - 0.5 and freeEnd ~= 2) then between(random, 0.3, 0.8) else 0
			local drift = between(random, -0.5, 0.5)
			table.insert(spans, {
				tag = string.format("%d_%d", index, k),
				p0 = point(s0, c + (if sag0 > 0 then drift else 0), waterY - sag0),
				p1 = point(s1, c + (if sag1 > 0 then -drift else 0), waterY - sag1),
				s0 = s0,
				s1 = s1,
				lane = index,
			})
			total += s1 - s0
		end
	end
	-- Floats strung evenly along every span (as close as the float allowance lets them), red near the walls
	local spacing = math.max(FLOAT_SPACING, total / FLOAT_CAP)
	for _, span in spans do
		table.insert(
			pieces,
			Kit.cylinder(
				"Rope" .. span.tag,
				span.p0,
				span.p1,
				0.12,
				"Rubber",
				"Detail",
				paint(rgb(90, 86, 72), Enum.Material.Fabric)
			)
		)
		local length = span.s1 - span.s0
		local count = math.max(1, math.floor(length / spacing))
		local step = length / count
		for f = 1, count do
			local along = (f - 0.5) * step
			local u = span.s0 + along
			local color = if u - a0 < WALL_RED or a1 - u < WALL_RED
				then FLOAT_RED
				else FLOAT_COLORS[(span.lane + f) % #FLOAT_COLORS + 1]
			local half = FLOAT_LENGTH / 2 / length
			table.insert(
				pieces,
				Kit.cylinder(
					string.format("Float%s_%d", span.tag, f),
					span.p0:Lerp(span.p1, math.max(0, along / length - half)),
					span.p0:Lerp(span.p1, math.min(1, along / length + half)),
					0.42,
					"Rubber",
					"Detail",
					paint(color, Enum.Material.SmoothPlastic)
				)
			)
		end
	end
	return pieces
end

--------------------------------------------------------------------------------
-- Deck furniture: starting blocks, ladders, diving board, lifeguard chair
--------------------------------------------------------------------------------

local STEEL = { color = rgb(104, 108, 106), material = Enum.Material.Metal, reflectance = 0.06 }
local TOWER_RAIL = 2.8 -- handrail height on the diving tower
local ALGAE = paint(rgb(54, 64, 40), Enum.Material.SmoothPlastic, 0.2)

-- The direction from a rect toward the basin interior (the side it faces the water on).
local function facing(r: Rect, interior: Rect): Vector3
	local cx, cz = r.x + r.w / 2, r.z + r.d / 2
	local best, dir = math.huge, Vector3.xAxis
	local options: { { number | Vector3 } } = {
		{ math.abs(interior.x - (r.x + r.w)), Vector3.xAxis },
		{ math.abs((interior.x + interior.w) - r.x), -Vector3.xAxis },
		{ math.abs(interior.z - (r.z + r.d)), Vector3.zAxis },
		{ math.abs((interior.z + interior.d) - r.z), -Vector3.zAxis },
	}
	for _, option in options do
		local distance = option[1] :: number
		local d = option[2] :: Vector3
		local inside = if math.abs(d.X) > 0.5
			then cz > interior.z and cz < interior.z + interior.d
			else cx > interior.x and cx < interior.x + interior.w
		if inside and distance < best then
			best, dir = distance, d
		end
	end
	return dir
end

local function planBlocks(info: LevelInfo, classified: Classified, random: Random): { Piece }
	local pieces: { Piece } = {}
	for i, block in classified.blocks do
		local r = block.rect
		local dir = facing(r, classified.interior)
		local centre = info.origin + Vector3.new(r.x + r.w / 2, block.top, r.z + r.d / 2)
		local half = if math.abs(dir.X) > 0.5 then r.w / 2 else r.d / 2
		local frame = CFrame.lookAt(centre, centre + dir) * CFrame.new(0, 0, -half) -- on the pool-side top edge
		local span = (if math.abs(dir.X) > 0.5 then r.d else r.w) - 0.6
		table.insert(
			pieces,
			Kit.cylinder(
				"GrabBar" .. i,
				frame:PointToWorldSpace(Vector3.new(-span / 2, -0.16, -0.1)),
				frame:PointToWorldSpace(Vector3.new(span / 2, -0.16, -0.1)),
				0.11,
				"MetalGalvanized",
				"Detail",
				STEEL
			)
		)
		table.insert(
			pieces,
			Kit.block(
				"Stain" .. i,
				frame * CFrame.new(between(random, -0.5, 0.5), -block.top / 2 - 0.1, -0.008),
				Vector3.new(between(random, 0.6, 1.4), block.top * 0.7, 0.012),
				"Rubber",
				"Detail",
				ALGAE
			)
		)
		if chance(random, 0.5) then
			local corner = if chance(random, 0.5) then 1 else -1
			table.insert(
				pieces,
				Kit.wedge(
					"Chip" .. i,
					frame * CFrame.new(corner * (span / 2), -0.18, 0.2) * ry(corner * 90),
					Vector3.new(0.5, 0.36, 0.4),
					"PoolTile",
					"Detail",
					paint(rgb(58, 60, 54), Enum.Material.Slate)
				)
			)
		end
	end
	return pieces
end

-- One pool ladder hooked over the coping of `side` at `u`: rails up off the deck, over the coping, down the wall.
local function ladderPieces(
	info: LevelInfo,
	basin: Basin,
	interior: Rect,
	side: Vector3,
	u: number,
	index: number
): { Piece }
	local pieces: { Piece } = {}
	local alongX = math.abs(side.X) > 0.5
	-- side points from the deck into the water; the wall face is the interior edge on the deck side
	local face = if alongX
		then (if side.X > 0 then interior.x else interior.x + interior.w)
		else (if side.Z > 0 then interior.z else interior.z + interior.d)
	local inward = if alongX then side.X else side.Z
	local function point(a: number, y: number, c: number): Vector3
		return info.origin + (if alongX then Vector3.new(a, y, c) else Vector3.new(c, y, a))
	end
	local deck = face - inward * (Geometry.BasinWall + 0.35)
	local water = face + inward * 0.4
	local top = 2.4
	for k, offset in { -0.8, 0.8 } do
		local c = u + offset
		table.insert(
			pieces,
			Kit.cylinder(
				string.format("Rail%d_%dPost", index, k),
				point(deck, 0, c),
				point(deck, top, c),
				0.16,
				"MetalGalvanized",
				"Detail",
				STEEL
			)
		)
		table.insert(
			pieces,
			Kit.cylinder(
				string.format("Rail%d_%dBow", index, k),
				point(deck, top, c),
				point(water, top - 0.2, c),
				0.16,
				"MetalGalvanized",
				"Detail",
				STEEL
			)
		)
		table.insert(
			pieces,
			Kit.cylinder(
				string.format("Rail%d_%dLeg", index, k),
				point(water, top - 0.2, c),
				point(water, basin.waterLevel - 2.6, c),
				0.16,
				"MetalGalvanized",
				"Detail",
				STEEL
			)
		)
	end
	for k, y in { basin.waterLevel + 0.6, basin.waterLevel - 0.5, basin.waterLevel - 1.6 } do
		table.insert(
			pieces,
			Kit.cylinder(
				string.format("Rung%d_%d", index, k),
				point(water + inward * 0.05, y, u - 0.8),
				point(water + inward * 0.05, y, u + 0.8),
				0.12,
				"MetalGalvanized",
				"Detail",
				STEEL
			)
		)
	end
	return pieces
end

local function planLadders(info: LevelInfo, classified: Classified, basin: Basin, random: Random): { Piece }
	local pieces: { Piece } = {}
	local interior = classified.interior
	local room = info.rooms[basin.room]
	local inner = info.inner[basin.room]
	if not (room and inner) then
		return pieces
	end
	-- Deck sides of the basin, widest deck first
	local sides: { { Vector3 | number } } = {
		{ Vector3.xAxis, basin.rect.x - inner.x },
		{ -Vector3.xAxis, inner.x + inner.w - (basin.rect.x + basin.rect.w) },
		{ Vector3.zAxis, basin.rect.z - inner.z },
		{ -Vector3.zAxis, inner.z + inner.d - (basin.rect.z + basin.rect.d) },
	}
	table.sort(sides, function(a: { Vector3 | number }, b: { Vector3 | number }): boolean
		return (a[2] :: number) > (b[2] :: number)
	end)
	local keepOff: { Rect } = {}
	for _, r in classified.obstacles do
		table.insert(keepOff, inflate(r, 2.5))
	end
	for _, block in classified.blocks do
		table.insert(keepOff, inflate(block.rect, 2))
	end
	local made = 0
	for _, entry in sides do
		local side, deckWidth = entry[1] :: Vector3, entry[2] :: number
		if deckWidth < 3 or made >= 3 then
			continue
		end
		local alongX = math.abs(side.X) > 0.5
		local lo = (if alongX then interior.z else interior.x) + 6
		local hi = (if alongX then interior.z + interior.d else interior.x + interior.w) - 6
		local placed: { number } = {}
		local wanted = if made == 0 then 2 else 1
		local candidates: { number } = {}
		local u = lo
		while u <= hi do
			table.insert(candidates, u)
			u += 2
		end
		MathUtil.shuffle(candidates, random)
		for _, c in candidates do
			if #placed >= wanted or made >= 3 then
				break
			end
			local far = true
			for _, other in placed do
				far = far and math.abs(other - c) > 25
			end
			if not far then
				continue
			end
			local ladder = ladderPieces(info, basin, interior, side, c, made + 1)
			local area = footprint(info, ladder)
			local clear = true
			for _, r in keepOff do
				clear = clear and not rectsOverlap(area, r)
			end
			if clear and Kit.fits(info, ladder, { ignore = { ClutterSpot = true, CorpseSpot = true } }) then
				for _, piece in ladder do
					table.insert(pieces, piece)
				end
				table.insert(placed, c)
				made += 1
			end
		end
	end
	return pieces
end

local function planDivingBoard(info: LevelInfo, classified: Classified, basin: Basin, random: Random): { Piece }
	local pieces: { Piece } = {}
	local tower = classified.towers[1]
	if not tower then
		return pieces
	end
	local interior = classified.interior
	local r = tower.rect
	local cx, cz = r.x + r.w / 2, r.z + r.d / 2
	-- Point the board at the most open water
	local bestDir, bestRun = Vector3.xAxis, -1
	for _, dir in { -Vector3.xAxis, Vector3.xAxis, -Vector3.zAxis, Vector3.zAxis } do
		local half = if math.abs(dir.X) > 0.5 then r.w / 2 else r.d / 2
		local run = 0
		while run < 40 do
			local x, z = cx + dir.X * (half + run + 1), cz + dir.Z * (half + run + 1)
			if not pointIn(interior, x, z) then
				break
			end
			local hit = false
			for _, o in classified.obstacles do
				if o ~= r and pointIn(inflate(o, 0.5), x, z) then
					hit = true
				end
			end
			if hit then
				break
			end
			run += 1
		end
		if run > bestRun then
			bestDir, bestRun = dir, run
		end
	end
	local half = if math.abs(bestDir.X) > 0.5 then r.w / 2 else r.d / 2
	local edge = info.origin + Vector3.new(cx, tower.top, cz) + bestDir * half
	local frame = CFrame.lookAt(edge, edge + bestDir) -- -Z out over the water, on the tower's top edge
	local board = paint(rgb(122, 116, 96), Enum.Material.SmoothPlastic)
	local visible: SetDressingBuilder.Role = "Visible"
	table.insert(
		pieces,
		Kit.box(
			frame,
			"BoardMount",
			Vector3.new(-0.6, 0, 0.5),
			Vector3.new(0.6, 0.45, 1.6),
			"MetalGalvanized",
			visible,
			STEEL
		)
	)
	local stub = 1.4 + between(random, 0, 0.6)
	local stubFrame = frame * CFrame.new(0, 0.56, (1.8 - stub) / 2) * rx(-3)
	table.insert(
		pieces,
		Kit.block("BoardStub", stubFrame, Vector3.new(1.6, 0.22, 1.8 + stub), "Fixture", visible, board)
	)
	table.insert(
		pieces,
		Kit.wedge(
			"BoardSnap",
			stubFrame * CFrame.new(between(random, -0.3, 0.3), 0, -(1.8 + stub) / 2 - 0.25) * ry(180),
			Vector3.new(between(random, 0.7, 1.2), 0.22, 0.5),
			"Fixture",
			visible,
			board
		)
	)
	-- The broken-off half, adrift at the foot of the tower, one end under
	local drift = frame * CFrame.new(between(random, -2, 2), 0, -stub - between(random, 3, 6))
	local adrift = CFrame.new(Vector3.new(drift.Position.X, info.origin.Y + basin.waterLevel + 0.05, drift.Position.Z))
		* CFrame.fromMatrix(Vector3.zero, frame.RightVector, Vector3.yAxis)
		* ry(between(random, -30, 30))
		* rx(between(random, 12, 20))
	table.insert(
		pieces,
		Kit.block("BoardAdrift", adrift, Vector3.new(1.6, 0.22, between(random, 4.5, 5.5)), "Fixture", visible, board)
	)
	-- Handrails along the two sides of the tower top (a post at each end, a rail across), one front post wrenched
	-- out over the drop
	local depth = if math.abs(bestDir.X) > 0.5 then r.w else r.d
	local width = if math.abs(bestDir.X) > 0.5 then r.d else r.w
	local bent = random:NextInteger(1, 2)
	for k, sx in { -1, 1 } do
		local x = sx * (width / 2 - 0.3)
		local backFoot = frame:PointToWorldSpace(Vector3.new(x, 0, depth - 0.4))
		local frontFoot = frame:PointToWorldSpace(Vector3.new(x, 0, 0.45))
		local lean = if k == bent
			then rz(-sx * between(random, 18, 34)) * rx(-between(random, 6, 16))
			else CFrame.identity
		local backTop = backFoot + frame.UpVector * TOWER_RAIL
		local frontTop = frontFoot + frame:VectorToWorldSpace(lean.UpVector) * TOWER_RAIL
		for _, entry in { { "A", backFoot, backTop }, { "B", frontFoot, frontTop } } :: { { any } } do
			table.insert(
				pieces,
				Kit.cylinder(
					string.format("TowerPost%d%s", k, entry[1] :: string),
					entry[2] :: Vector3,
					entry[3] :: Vector3,
					0.14,
					"MetalGalvanized",
					visible,
					STEEL
				)
			)
		end
		table.insert(pieces, Kit.cylinder("TowerRail" .. k, backTop, frontTop, 0.12, "MetalGalvanized", visible, STEEL))
	end
	return pieces
end

-- The tall lifeguard chair, upright in chair space (feet on y = 0, facing -Z), then knocked onto its side or back.
local function lifeguardChair(random: Random): { Piece }
	local frameMetal = paint(rgb(96, 98, 94), Enum.Material.Metal)
	local wood = paint(rgb(110, 92, 64), Enum.Material.WoodPlanks)
	local pieces: { Piece } = {}
	for i, leg in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } :: { { number } } do
		table.insert(
			pieces,
			Kit.cylinder(
				"Leg" .. i,
				Vector3.new(leg[1] * 0.95, 0, leg[2] * 0.85),
				Vector3.new(leg[1] * 0.75, 4.6, leg[2] * 0.65),
				0.18,
				"MetalGalvanized",
				"Solid",
				frameMetal
			)
		)
	end
	table.insert(
		pieces,
		Kit.block("Seat", CFrame.new(0, 4.69, 0), Vector3.new(1.9, 0.18, 1.4), "Fixture", "Solid", wood)
	)
	table.insert(
		pieces,
		Kit.block(
			"Backrest",
			CFrame.new(0, 5.45, 0.72) * rx(-10),
			Vector3.new(1.9, 1.3, 0.12),
			"Fixture",
			"Solid",
			wood
		)
	)
	table.insert(
		pieces,
		Kit.block("Footrest", CFrame.new(0, 2.6, -0.92), Vector3.new(1.75, 0.12, 0.5), "Fixture", "Solid", wood)
	)
	for k, y in { 1.2, 2.4, 3.6 } do
		local spread = 0.95 - 0.2 * y / 4.6
		table.insert(
			pieces,
			Kit.cylinder(
				"Rung" .. k,
				Vector3.new(-spread, y, 0.85 - 0.2 * y / 4.6),
				Vector3.new(spread, y, 0.85 - 0.2 * y / 4.6),
				0.12,
				"MetalGalvanized",
				"Solid",
				frameMetal
			)
		)
	end
	local fall = if chance(random, 0.5) then rz(if chance(random, 0.5) then 90 else -90) else rx(84)
	Kit.transform(pieces, fall * ry(between(random, -6, 6)))
	Kit.offset(pieces, Vector3.new(0, -lowest(pieces) + 0.005, 0))
	return pieces
end

local function planChair(info: LevelInfo, classified: Classified, basin: Basin, random: Random): { Piece }
	local inner = info.inner[basin.room]
	if not inner then
		return {}
	end
	local layout = info.layout
	local route: { Rect } = {}
	-- Keep the way from the deck onto every walkway fragment that touches the coping clear, deck wall to coping
	for _, f in classified.fragments do
		local r = f.rect
		if math.abs(r.x - basin.rect.x) < 1.5 or math.abs(r.x + r.w - (basin.rect.x + basin.rect.w)) < 1.5 then
			table.insert(route, { x = inner.x, z = r.z - 2.5, w = inner.w, d = r.d + 5 })
		elseif math.abs(r.z - basin.rect.z) < 1.5 or math.abs(r.z + r.d - (basin.rect.z + basin.rect.d)) < 1.5 then
			table.insert(route, { x = r.x - 2.5, z = inner.z, w = r.w + 5, d = inner.d })
		end
	end
	local spots: { Vector3 } = {}
	for _, anchor in layout.anchors do
		if anchor.room == basin.room and (anchor.kind == "Clutter" or anchor.kind == "Corpse") then
			table.insert(spots, anchor.pos)
		end
	end
	local best: { Piece }? = nil
	local bestScore = -math.huge
	local centreZ = basin.rect.z + basin.rect.d / 2
	local centreX = basin.rect.x + basin.rect.w / 2
	local x = inner.x + 3
	while x <= inner.x + inner.w - 3 do
		local z = inner.z + 3
		while z <= inner.z + inner.d - 3 do
			local point = Vector3.new(x, 0, z)
			local ok = not pointIn(inflate(basin.rect, 2.5), x, z)
			for _, r in route do
				ok = ok and not pointIn(inflate(r, 3.5), x, z)
			end
			for _, block in classified.blocks do
				ok = ok and not pointIn(inflate(block.rect, 4), x, z)
			end
			for _, spot in spots do
				ok = ok and (Vector3.new(spot.X, 0, spot.Z) - point).Magnitude > 8.5
			end
			if ok then
				-- Lifeguards sit by the water near mid-length of the pool
				local edge = math.min(
					math.abs(x - basin.rect.x),
					math.abs(x - (basin.rect.x + basin.rect.w)),
					math.abs(z - basin.rect.z),
					math.abs(z - (basin.rect.z + basin.rect.d))
				)
				local score = -edge - 0.15 * math.min(math.abs(z - centreZ), math.abs(x - centreX))
				if score > bestScore then
					local chair = lifeguardChair(random)
					local toWater = Vector3.new(centreX - x, 0, centreZ - z)
					local yaw = math.deg(math.atan2(-toWater.X, -toWater.Z))
					Kit.transform(chair, CFrame.new(info.origin + point) * ry(yaw))
					local area = footprint(info, chair)
					local clear = not rectsOverlap(area, inflate(basin.rect, 0.8))
					for _, r in route do
						clear = clear and not rectsOverlap(area, r)
					end
					if
						clear
						and Kit.fits(
							info,
							chair,
							{ room = basin.room, margin = 0.5, ground = 0, ignore = { ClutterSpot = true } }
						)
					then
						best, bestScore = chair, score
					end
				end
			end
			z += 3
		end
		x += 3
	end
	return best or {}
end

--------------------------------------------------------------------------------
-- On and under the water
--------------------------------------------------------------------------------

local KICKBOARDS: { Color3 } = { rgb(54, 76, 104), rgb(124, 108, 50), rgb(110, 56, 50), rgb(70, 92, 74) }
local SCUM = paint(rgb(50, 58, 34), Enum.Material.SmoothPlastic, 0.25)

-- A random open-water point clear of every platform (and of grate fronts), or nil.
local function openWater(classified: Classified, random: Random, inset: number, keep: number): Vector3?
	local interior = classified.interior
	for _ = 1, 30 do
		local x = between(random, interior.x + inset, interior.x + interior.w - inset)
		local z = between(random, interior.z + inset, interior.z + interior.d - inset)
		local ok = true
		for _, r in classified.obstacles do
			ok = ok and not pointIn(inflate(r, keep), x, z)
		end
		if ok then
			return Vector3.new(x, 0, z)
		end
	end
	return nil
end

local function planFloating(info: LevelInfo, classified: Classified, basin: Basin, random: Random): { Piece }
	local pieces: { Piece } = {}
	local waterY = info.origin.Y + basin.waterLevel
	local ignore = { ClutterSpot = true, CorpseSpot = true }
	local function place(list: { Piece }): boolean
		if Kit.fits(info, list, { ignore = ignore }) then
			for _, piece in list do
				table.insert(pieces, piece)
			end
			return true
		end
		return false
	end
	for i = 1, 4 do
		local spot = openWater(classified, random, 2, 1.2)
		if spot then
			local cf = CFrame.new(info.origin.X + spot.X, waterY + 0.02, info.origin.Z + spot.Z)
				* ry(between(random, 0, 360))
				* rx(between(random, -5, 5))
				* rz(between(random, -4, 4))
			place({
				Kit.block(
					"Kickboard" .. i,
					cf,
					Vector3.new(1.4, 0.18, 2.2),
					"Fixture",
					"Detail",
					paint(pick(random, KICKBOARDS), Enum.Material.SmoothPlastic)
				),
			})
		end
	end
	-- A plastic deck chair, upside down and half sunk
	local spot = openWater(classified, random, 4, 2)
	if spot then
		local shell = paint(rgb(118, 116, 104), Enum.Material.SmoothPlastic)
		local frame = CFrame.new(info.origin.X + spot.X, waterY - 0.15, info.origin.Z + spot.Z)
			* ry(between(random, 0, 360))
			* rx(between(random, 150, 170))
		place({
			Kit.block("FloatChairSeat", frame, Vector3.new(1.5, 0.12, 1.4), "Fixture", "Detail", shell),
			Kit.block(
				"FloatChairBack",
				frame * CFrame.new(0, 0.6, 0.72) * rx(-12),
				Vector3.new(1.5, 1.2, 0.1),
				"Fixture",
				"Detail",
				shell
			),
			Kit.block(
				"FloatChairLegs",
				frame * CFrame.new(0, -0.7, -0.55),
				Vector3.new(1.4, 1.3, 0.1),
				"Fixture",
				"Detail",
				shell
			),
			Kit.block(
				"FloatChairLegsBack",
				frame * CFrame.new(0, -0.7, 0.55),
				Vector3.new(1.4, 1.3, 0.1),
				"Fixture",
				"Detail",
				shell
			),
		})
	end
	-- Scum rafts on the surface
	for i = 1, 6 do
		local at = openWater(classified, random, 1, 0.6)
		if at then
			local base = Vector3.new(info.origin.X + at.X, waterY + 0.004, info.origin.Z + at.Z)
			if i <= 4 then
				place({ Kit.disc("Scum" .. i, base, between(random, 1.5, 4), 0.02, "Rubber", "Detail", SCUM) })
			else
				local cf = CFrame.new(base + Vector3.new(0, 0.01, 0)) * ry(between(random, 0, 180))
				place({
					Kit.block(
						"Scum" .. i,
						cf,
						Vector3.new(between(random, 1.2, 2.4), 0.02, between(random, 2.5, 5)),
						"Rubber",
						"Detail",
						SCUM
					),
				})
			end
		end
	end
	return pieces
end

local function planDrain(info: LevelInfo, classified: Classified, basin: Basin): { Piece }
	local interior = classified.interior
	local centre = Vector3.new(interior.x + interior.w / 2, 0, interior.z + interior.d / 2)
	local tower = classified.towers[1]
	if tower then
		local t = Vector3.new(tower.rect.x + tower.rect.w / 2, 0, tower.rect.z + tower.rect.d / 2)
		centre = t:Lerp(centre, 0.3)
	end
	-- Nudge off any pier or tower foot
	local spot = centre
	for ring = 0, 8 do
		local found = false
		for k = 0, math.max(0, ring * 4 - 1) do
			local angle = if ring == 0 then 0 else k / (ring * 4) * math.pi * 2
			local p = centre + Vector3.new(math.cos(angle), 0, math.sin(angle)) * (ring * 2.5)
			local ok = pointIn(Geometry.insetRect(interior, 2), p.X, p.Z)
			for _, r in classified.obstacles do
				ok = ok and not pointIn(inflate(r, 2), p.X, p.Z)
			end
			if ok then
				spot, found = p, true
				break
			end
		end
		if found then
			break
		end
	end
	local floor = info.origin + Vector3.new(spot.X, -basin.depth, spot.Z)
	local iron = paint(rgb(30, 32, 30), Enum.Material.CorrodedMetal)
	local pieces: { Piece } = {
		Kit.block(
			"DrainFrame",
			CFrame.new(floor + Vector3.new(0, 0.03, 0)),
			Vector3.new(2.6, 0.06, 2.6),
			"Iron",
			"Detail",
			paint(rgb(14, 14, 14), Enum.Material.SmoothPlastic)
		),
	}
	for i = 1, 4 do
		local z = -1.05 + (i - 1) * 0.7
		table.insert(
			pieces,
			Kit.block(
				"DrainSlat" .. i,
				CFrame.new(floor + Vector3.new(0, 0.1, z)),
				Vector3.new(2.4, 0.08, 0.2),
				"Iron",
				"Detail",
				iron
			)
		)
	end
	return pieces
end

local function planTiles(info: LevelInfo, classified: Classified, basin: Basin, random: Random): { Piece }
	local pieces: { Piece } = {}
	local inner = info.inner[basin.room]
	if not inner then
		return pieces
	end
	local deckRect = basin.rect
	local function deckSpot(): Vector3?
		for _ = 1, 30 do
			local x = between(random, inner.x + 1, inner.x + inner.w - 1)
			local z = between(random, inner.z + 1, inner.z + inner.d - 1)
			local edge = math.min(math.abs(x - deckRect.x), math.abs(x - (deckRect.x + deckRect.w)))
			if not pointIn(inflate(deckRect, 0.3), x, z) and edge < 7 then
				return Vector3.new(x, 0, z)
			end
		end
		return nil
	end
	local screed = paint(rgb(62, 60, 52), Enum.Material.Concrete)
	local fitsOptions =
		{ room = basin.room, margin = 0.3, ground = 0, ignore = { ClutterSpot = true, CorpseSpot = true } }
	for i = 1, 5 do
		local spot = deckSpot()
		if spot then
			local cf = CFrame.new(info.origin + spot + Vector3.new(0, 0.008, 0)) * ry(between(random, 0, 90))
			local patch = {
				Kit.block(
					"TileGap" .. i,
					cf,
					Vector3.new(between(random, 0.8, 2), 0.016, between(random, 0.6, 1.6)),
					"ConcreteStained",
					"Detail",
					screed
				),
			}
			if Kit.fits(info, patch, fitsOptions) then
				table.insert(pieces, patch[1])
				local loose = cf
					* CFrame.new(between(random, -1.4, 1.4), 0.03, between(random, -1.4, 1.4))
					* ry(between(random, 0, 90))
					* rx(between(random, 0, 14))
				local tile = {
					Kit.block(
						"LooseTile" .. i,
						loose,
						Vector3.new(0.6, 0.05, if chance(random, 0.5) then 0.6 else 0.35),
						"PoolTile",
						"Detail"
					),
				}
				if i <= 4 and Kit.fits(info, tile, fitsOptions) then
					table.insert(pieces, tile[1])
				end
			end
		end
	end
	-- Bare render where tiles fell off the coping's inner face, between the waterline and the deck
	local interior = classified.interior
	for i = 1, 3 do
		local sideX = chance(random, 0.6)
		local cf: CFrame
		if sideX then
			local west = chance(random, 0.5)
			local x = if west then interior.x + 0.008 else interior.x + interior.w - 0.008
			cf = CFrame.new(
				info.origin
					+ Vector3.new(x, basin.waterLevel / 2, between(random, interior.z + 3, interior.z + interior.d - 3))
			) * ry(90)
		else
			local north = chance(random, 0.5)
			local z = if north then interior.z + 0.008 else interior.z + interior.d - 0.008
			cf = CFrame.new(
				info.origin
					+ Vector3.new(between(random, interior.x + 3, interior.x + interior.w - 3), basin.waterLevel / 2, z)
			)
		end
		local patch = {
			Kit.block(
				"CopingScar" .. i,
				cf,
				Vector3.new(between(random, 0.8, 1.8), math.abs(basin.waterLevel) * 0.6, 0.016),
				"ConcreteStained",
				"Detail",
				screed
			),
		}
		if Kit.fits(info, patch, { ignore = { ClutterSpot = true, CorpseSpot = true } }) then
			table.insert(pieces, patch[1])
		end
	end
	return pieces
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

-- Whether a level-local box stands wholly on a walkway fragment's top (a lip), not over open water.
local function onFragment(classified: Classified, box: SetDressingBuilder.Box): boolean
	for _, f in classified.fragments do
		local r = f.rect
		if box.x0 >= r.x - EPS and box.x1 <= r.x + r.w + EPS and box.z0 >= r.z - EPS and box.z1 <= r.z + r.d + EPS then
			return true
		end
	end
	return false
end
PoolWaterBuilder.onFragment = onFragment

-- Safety net for the no-bypass rule: a colliding piece over open water whose top is not deep enough stops colliding.
local function enforceNoBypass(info: LevelInfo, pieces: { Piece }, basin: Basin, classified: Classified)
	local interior = classified.interior
	local limit = basin.waterLevel - NO_BYPASS
	for _, piece in pieces do
		if piece.role ~= "Solid" then
			continue
		end
		local box = Kit.localBox(info, piece)
		local over = math.min(box.x1, interior.x + interior.w) - math.max(box.x0, interior.x) > EPS
			and math.min(box.z1, interior.z + interior.d) - math.max(box.z0, interior.z) > EPS
		if over and box.y1 > limit + EPS and not onFragment(classified, box) then
			log.warn("%s would rise to %.2f over the water; made non-colliding", piece.name, box.y1)
			piece.role = "Visible"
		end
	end
end

local function buildPool(ctx: PropKit.StaticContext): number
	local layout = ctx.layout
	local basins = (layout.basins or {}) :: { Basin }
	if #basins == 0 then
		return 0
	end
	local info = Kit.info(layout)
	local seed = ctx.random:NextInteger(1, 2_000_000_000)
	local built = 0
	for _, basin in basins do
		local classified = PoolWaterBuilder.classify(layout, basin)
		local random = MathUtil.seededRandom(seed, basin.id)
		local pieces: { Piece } = {}
		local groups: { { Piece } } = {
			planWalkways(info, classified, basin, random),
			planLips(info, classified),
			planLadders(info, classified, basin, random),
			planRopes(info, classified, basin, random),
			planBlocks(info, classified, random),
			planDivingBoard(info, classified, basin, random),
			planChair(info, classified, basin, random),
			planFloating(info, classified, basin, random),
			planDrain(info, classified, basin),
			planTiles(info, classified, basin, random),
		}
		for _, group in groups do
			if #pieces + #group > BUDGET then
				log.warn("%s: dressing group of %d parts dropped (budget %d)", basin.id, #group, BUDGET)
				continue
			end
			for _, piece in group do
				table.insert(pieces, piece)
			end
		end
		enforceNoBypass(info, pieces, basin, classified)
		local r = basin.rect
		local model = PropKit.model(
			ctx.parent,
			"PoolDressing_" .. basin.id,
			CFrame.new(info.origin + Vector3.new(r.x + r.w / 2, basin.waterLevel, r.z + r.d / 2))
		)
		Kit.realize(model, pieces)
		PropKit.setAttributes(model, {
			[W.LevelId] = layout.id,
			[W.ZoneId] = basin.room,
			[W.TriggerId] = basin.id,
		})
		built += 1
	end
	return built
end

function PoolWaterBuilder.register(registrar: PropKit.Registrar)
	registrar.static("PoolDressing", buildPool)
end

return table.freeze(PoolWaterBuilder)
