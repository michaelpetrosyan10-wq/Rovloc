--!strict
-- Shared geometry for every builder: the part factory (with the build-wide yield counter), collision presets,
-- rectangle subtraction, split-slab walls (openings are cut by splitting a wall into boxes, never CSG), wall
-- junction resolution (no overlaps or gaps where walls meet), door trims, pillars and stair flights.
--
-- Wall-local coordinates: a wall lies on a line of constant X (axis "X", it runs along Z) or constant Z (axis
-- "Z", it runs along X) at `coord`. `u` runs along the wall, `y` is height and `a` ("across") is the signed
-- distance from the wall's centre line in world units along the line's normal (+X for axis "X", +Z for "Z").

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Palette = require(script.Parent.Palette)
local Tags = require(ReplicatedStorage.Shared.Tags)

export type Rect = LayoutSchema.Rect
export type Axis = "X" | "Z"

export type Opening = { u0: number, u1: number, y0: number, y1: number }

export type WallBox = { u0: number, u1: number, y0: number, y1: number }

export type WallSegment = {
	axis: Axis,
	coord: number,
	from: number, -- along range before junction resolution
	to: number,
	thickness: number,
	height: number, -- top, level-local Y
	start: number, -- along range after junction resolution (resolveJunctions writes these)
	finish: number,
	startMargin: number?, -- half-extent of the junction square at each end; openings must stay out of it
	finishMargin: number?,
}

export type Filler = {
	x0: number,
	x1: number,
	z0: number,
	z1: number,
	y0: number,
	y1: number,
	segment: number, -- index of the tallest arm, so the caller can pick its palette
}

export type PartOptions = {
	transparency: number?,
	canCollide: boolean?,
	canQuery: boolean?,
	castShadow: boolean?,
	shape: Enum.PartType?,
	material: Enum.Material?,
	color: Color3?,
	reflectance: number?,
}

local EPS = 1e-3

local Geometry = {}

Geometry.EPS = EPS

--------------------------------------------------------------------------------
-- Build-wide part counter + cooperative yielding
--------------------------------------------------------------------------------

local yieldEvery = 600
local sinceYield = 0
local created = 0

-- n <= 0 disables yielding (pure Lune runs, specs).
function Geometry.setYieldEvery(n: number)
	yieldEvery = n
	sinceYield = 0
end

function Geometry.getYieldEvery(): number
	return yieldEvery
end

-- Counts one created part and task.wait()s once every `yieldEvery` parts so a long build never trips the
-- script timeout or starves the scheduler.
function Geometry.yieldPoint()
	created += 1
	sinceYield += 1
	if yieldEvery > 0 and sinceYield >= yieldEvery then
		sinceYield = 0
		task.wait()
	end
end

function Geometry.partsCreated(): number
	return created
end

--------------------------------------------------------------------------------
-- Part factory
--------------------------------------------------------------------------------

local function configure(
	part: BasePart,
	name: string,
	cframe: CFrame,
	size: Vector3,
	key: string?,
	options: PartOptions?
)
	part.Name = name
	part.Anchored = true
	part.CanTouch = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Size = size
	part.CFrame = cframe
	local entry = Palette.get(key)
	part.Material = entry.material
	part.Color = entry.color
	if options then
		if options.material then
			part.Material = options.material
		end
		if options.color then
			part.Color = options.color
		end
		if options.transparency then
			part.Transparency = options.transparency
		end
		if options.reflectance then
			part.Reflectance = options.reflectance
		end
		if options.canCollide ~= nil then
			part.CanCollide = options.canCollide
		end
		if options.canQuery ~= nil then
			part.CanQuery = options.canQuery
		end
		if options.castShadow ~= nil then
			part.CastShadow = options.castShadow
		end
	end
end

function Geometry.part(
	parent: Instance,
	name: string,
	cframe: CFrame,
	size: Vector3,
	key: string?,
	options: PartOptions?
): Part
	local part = Instance.new("Part")
	if options and options.shape then
		part.Shape = options.shape
	end
	configure(part, name, cframe, size, key, options)
	part.Parent = parent
	Geometry.yieldPoint()
	return part
end

function Geometry.wedge(
	parent: Instance,
	name: string,
	cframe: CFrame,
	size: Vector3,
	key: string?,
	options: PartOptions?
): WedgePart
	local part = Instance.new("WedgePart")
	configure(part, name, cframe, size, key, options)
	part.Parent = parent
	Geometry.yieldPoint()
	return part
end

-- Axis-aligned box between two world corners; nil when degenerate.
function Geometry.box(
	parent: Instance,
	name: string,
	minCorner: Vector3,
	maxCorner: Vector3,
	key: string?,
	options: PartOptions?
): Part?
	local lo = minCorner:Min(maxCorner)
	local hi = minCorner:Max(maxCorner)
	local size = hi - lo
	if size.X < EPS or size.Y < EPS or size.Z < EPS then
		return nil
	end
	return Geometry.part(parent, name, CFrame.new((lo + hi) / 2), size, key, options)
end

-- Cylinder whose axis runs from `a` to `b` (Part.Shape Cylinder runs along local X).
function Geometry.cylinder(
	parent: Instance,
	name: string,
	a: Vector3,
	b: Vector3,
	diameter: number,
	key: string?,
	options: PartOptions?
): Part?
	local delta = b - a
	local length = delta.Magnitude
	if length < EPS then
		return nil
	end
	local axis = delta / length
	local helper = if math.abs(axis.Y) > 0.95 then Vector3.xAxis else Vector3.yAxis
	local up = (helper - axis * helper:Dot(axis)).Unit
	local cframe = CFrame.fromMatrix((a + b) / 2, axis, up)
	local merged: PartOptions = {
		shape = Enum.PartType.Cylinder,
		transparency = options and options.transparency,
		canCollide = options and options.canCollide,
		canQuery = options and options.canQuery,
		castShadow = options and options.castShadow,
		material = options and options.material,
		color = options and options.color,
		reflectance = options and options.reflectance,
	}
	return Geometry.part(parent, name, cframe, Vector3.new(length, diameter, diameter), key, merged)
end

function Geometry.attachment(parent: Instance, name: string, cframe: CFrame): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.CFrame = cframe
	attachment.Parent = parent
	return attachment
end

function Geometry.folder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

--------------------------------------------------------------------------------
-- Collision presets
--------------------------------------------------------------------------------

-- Zone / trigger / anchor-root volumes: invisible, never collided, never queried (tested with math).
function Geometry.makeVolume(part: BasePart)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.CollisionGroup = CollisionGroups.NoCollide
end

-- Client-only dressing: visible, but collides with nothing and is never queried.
function Geometry.makeCosmetic(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.CollisionGroup = CollisionGroups.NoCollide
end

-- Light fixtures: visible, non-colliding, no shadows.
function Geometry.makeFixture(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.CollisionGroup = CollisionGroups.NoCollide
end

-- Trims and small furniture the Creature walks through (players still collide with them).
function Geometry.makePassthrough(part: BasePart)
	part.CollisionGroup = CollisionGroups.MonsterPassthrough
	local modifier = Instance.new("PathfindingModifier")
	modifier.Label = Tags.MonsterPassthrough
	modifier.PassThrough = true
	modifier.Parent = part
	part:AddTag(Tags.MonsterPassthrough)
end

--------------------------------------------------------------------------------
-- Rectangles
--------------------------------------------------------------------------------

function Geometry.rect(x: number, z: number, w: number, d: number): Rect
	return { x = x, z = z, w = w, d = d }
end

function Geometry.insetRect(r: Rect, inset: number): Rect
	return { x = r.x + inset, z = r.z + inset, w = math.max(0, r.w - inset * 2), d = math.max(0, r.d - inset * 2) }
end

function Geometry.rectIntersection(a: Rect, b: Rect): Rect?
	local x0 = math.max(a.x, b.x)
	local x1 = math.min(a.x + a.w, b.x + b.w)
	local z0 = math.max(a.z, b.z)
	local z1 = math.min(a.z + a.d, b.z + b.d)
	if x1 - x0 <= EPS or z1 - z0 <= EPS then
		return nil
	end
	return { x = x0, z = z0, w = x1 - x0, d = z1 - z0 }
end

-- `base` minus every hole, as disjoint rectangles (north / south strips full width, west / east strips between).
function Geometry.subtractRects(base: Rect, holes: { Rect }): { Rect }
	local pieces: { Rect } = { base }
	for _, hole in holes do
		local nextPieces: { Rect } = {}
		for _, piece in pieces do
			local cut = Geometry.rectIntersection(piece, hole)
			if not cut then
				table.insert(nextPieces, piece)
				continue
			end
			local px1, pz1 = piece.x + piece.w, piece.z + piece.d
			local cx1, cz1 = cut.x + cut.w, cut.z + cut.d
			if cut.z - piece.z > EPS then
				table.insert(nextPieces, { x = piece.x, z = piece.z, w = piece.w, d = cut.z - piece.z })
			end
			if pz1 - cz1 > EPS then
				table.insert(nextPieces, { x = piece.x, z = cz1, w = piece.w, d = pz1 - cz1 })
			end
			if cut.x - piece.x > EPS then
				table.insert(nextPieces, { x = piece.x, z = cut.z, w = cut.x - piece.x, d = cut.d })
			end
			if px1 - cx1 > EPS then
				table.insert(nextPieces, { x = cx1, z = cut.z, w = px1 - cx1, d = cut.d })
			end
		end
		pieces = nextPieces
	end
	return pieces
end

function Geometry.rectArea(r: Rect): number
	return r.w * r.d
end

--------------------------------------------------------------------------------
-- Split-slab walls
--------------------------------------------------------------------------------

local function subtractInterval(solids: { { number } }, lo: number, hi: number): { { number } }
	local out: { { number } } = {}
	for _, span in solids do
		local s0, s1 = span[1], span[2]
		if hi <= s0 + EPS or lo >= s1 - EPS then
			table.insert(out, span)
			continue
		end
		if lo - s0 > EPS then
			table.insert(out, { s0, lo })
		end
		if s1 - hi > EPS then
			table.insert(out, { hi, s1 })
		end
	end
	return out
end

-- Splits the wall rectangle [u0, u1] x [y0, y1] around every opening into solid boxes that neither overlap nor
-- leave gaps. Columns with identical solid spans merge, so a door gives 3 boxes and a low grate 4.
function Geometry.splitWall(u0: number, u1: number, y0: number, y1: number, openings: { Opening }): { WallBox }
	local clipped: { Opening } = {}
	for _, opening in openings do
		local a, b = math.max(opening.u0, u0), math.min(opening.u1, u1)
		local c, d = math.max(opening.y0, y0), math.min(opening.y1, y1)
		if b - a > EPS and d - c > EPS then
			table.insert(clipped, { u0 = a, u1 = b, y0 = c, y1 = d })
		end
	end
	local breaks: { number } = { u0, u1 }
	for _, opening in clipped do
		table.insert(breaks, opening.u0)
		table.insert(breaks, opening.u1)
	end
	table.sort(breaks)
	local unique: { number } = {}
	for _, value in breaks do
		if #unique == 0 or value - unique[#unique] > EPS then
			table.insert(unique, value)
		end
	end

	local boxes: { WallBox } = {}
	local previous: { WallBox } = {}
	for i = 1, #unique - 1 do
		local a, b = unique[i], unique[i + 1]
		local mid = (a + b) / 2
		local solids: { { number } } = { { y0, y1 } }
		for _, opening in clipped do
			if opening.u0 <= mid and opening.u1 >= mid then
				solids = subtractInterval(solids, opening.y0, opening.y1)
			end
		end
		local current: { WallBox } = {}
		for _, span in solids do
			local extended = false
			for _, box in previous do
				if
					math.abs(box.u1 - a) < EPS
					and math.abs(box.y0 - span[1]) < EPS
					and math.abs(box.y1 - span[2]) < EPS
				then
					box.u1 = b
					table.insert(current, box)
					extended = true
					break
				end
			end
			if not extended then
				local box: WallBox = { u0 = a, u1 = b, y0 = span[1], y1 = span[2] }
				table.insert(boxes, box)
				table.insert(current, box)
			end
		end
		previous = current
	end
	return boxes
end

-- World position of a wall-local point.
function Geometry.wallPoint(origin: Vector3, axis: Axis, coord: number, u: number, y: number, a: number): Vector3
	if axis == "X" then
		return origin + Vector3.new(coord + a, y, u)
	end
	return origin + Vector3.new(u, y, coord + a)
end

-- Axis-aligned wall-local box [u0,u1] x [y0,y1] x [a0,a1] as a part.
function Geometry.wallBox(
	parent: Instance,
	name: string,
	origin: Vector3,
	axis: Axis,
	coord: number,
	u0: number,
	u1: number,
	y0: number,
	y1: number,
	a0: number,
	a1: number,
	key: string?,
	options: PartOptions?
): Part?
	return Geometry.box(
		parent,
		name,
		Geometry.wallPoint(origin, axis, coord, u0, y0, a0),
		Geometry.wallPoint(origin, axis, coord, u1, y1, a1),
		key,
		options
	)
end

-- A CFrame at a wall-local point whose X axis runs along the wall and Y axis up. Its Z axis is the wall normal
-- (+Z world for axis "Z", -X world for axis "X"), so rotations about local Z tilt a piece within the wall plane.
function Geometry.wallCFrame(origin: Vector3, axis: Axis, coord: number, u: number, y: number, a: number): CFrame
	local position = Geometry.wallPoint(origin, axis, coord, u, y, a)
	if axis == "X" then
		return CFrame.fromMatrix(position, Vector3.zAxis, Vector3.yAxis)
	end
	return CFrame.new(position)
end

--------------------------------------------------------------------------------
-- Wall junctions
--------------------------------------------------------------------------------

type Arm = { index: number, segment: WallSegment }

type Junction = {
	x: number,
	z: number,
	n: { Arm }, -- walls leaving the point toward -Z
	s: { Arm }, -- toward +Z
	w: { Arm }, -- toward -X
	e: { Arm }, -- toward +X
}

local function maxThickness(arms: { Arm }): number
	local best = 0
	for _, arm in arms do
		best = math.max(best, arm.segment.thickness)
	end
	return best
end

local function maxHeight(arms: { Arm }): (number, number?)
	local best, index = -math.huge, nil
	for _, arm in arms do
		if arm.segment.height > best then
			best, index = arm.segment.height, arm.index
		end
	end
	return best, index
end

local function keyOf(x: number, z: number): string
	return string.format("%.3f|%.3f", x, z)
end

-- Resolves every point where wall segments meet so their boxes tile the junction square exactly once:
--   * a straight E-W run through the point owns the square; N/S stems stop at its faces;
--   * otherwise a straight N-S run owns it; E/W stems stop at its faces;
--   * at an L corner the E-W arm extends over the square and the N-S arm stops at its face.
-- Writes `start` / `finish` on every segment and returns filler posts for squares whose owner is shorter than
-- another arm (so taller walls never show a notch at a junction).
function Geometry.resolveJunctions(segments: { WallSegment }): { Filler }
	for _, segment in segments do
		segment.start = segment.from
		segment.finish = segment.to
		segment.startMargin = 0
		segment.finishMargin = 0
	end
	local junctions: { [string]: Junction } = {}
	local order: { string } = {}
	local function junctionAt(x: number, z: number): Junction
		local key = keyOf(x, z)
		local found = junctions[key]
		if found then
			return found
		end
		local fresh: Junction = { x = x, z = z, n = {}, s = {}, w = {}, e = {} }
		junctions[key] = fresh
		table.insert(order, key)
		return fresh
	end
	for index, segment in segments do
		local arm: Arm = { index = index, segment = segment }
		if segment.axis == "X" then
			table.insert(junctionAt(segment.coord, segment.from).s, arm)
			table.insert(junctionAt(segment.coord, segment.to).n, arm)
		else
			table.insert(junctionAt(segment.from, segment.coord).e, arm)
			table.insert(junctionAt(segment.to, segment.coord).w, arm)
		end
	end

	local fillers: { Filler } = {}
	local function addFiller(x0: number, x1: number, z0: number, z1: number, y0: number, y1: number, index: number?)
		if index and y1 - y0 > EPS and x1 - x0 > EPS and z1 - z0 > EPS then
			table.insert(fillers, { x0 = x0, x1 = x1, z0 = z0, z1 = z1, y0 = y0, y1 = y1, segment = index })
		end
	end

	for _, key in order do
		local j = junctions[key]
		local hasEW = #j.e > 0 or #j.w > 0
		local hasNS = #j.n > 0 or #j.s > 0
		if not (hasEW and hasNS) then
			continue -- collinear joint or a free end: nothing to resolve
		end
		local tEW = math.max(maxThickness(j.e), maxThickness(j.w))
		local tNS = math.max(maxThickness(j.n), maxThickness(j.s))
		local hAll, tallest = maxHeight(j.n)
		for _, list in { j.s, j.e, j.w } do
			local h, index = maxHeight(list)
			if h > hAll then
				hAll, tallest = h, index
			end
		end
		local x0, x1 = j.x - tNS / 2, j.x + tNS / 2
		local z0, z1 = j.z - tEW / 2, j.z + tEW / 2
		-- Openings never reach into the junction square: whoever owns it keeps it solid.
		for _, arm in j.e do
			arm.segment.startMargin = math.max(arm.segment.startMargin or 0, tNS / 2)
		end
		for _, arm in j.w do
			arm.segment.finishMargin = math.max(arm.segment.finishMargin or 0, tNS / 2)
		end
		for _, arm in j.s do
			arm.segment.startMargin = math.max(arm.segment.startMargin or 0, tEW / 2)
		end
		for _, arm in j.n do
			arm.segment.finishMargin = math.max(arm.segment.finishMargin or 0, tEW / 2)
		end

		if #j.e > 0 and #j.w > 0 then
			-- E-W run owns the square; trim N/S stems
			for _, arm in j.n do
				arm.segment.finish = math.min(arm.segment.finish, j.z - tEW / 2)
			end
			for _, arm in j.s do
				arm.segment.start = math.max(arm.segment.start, j.z + tEW / 2)
			end
			local hW = maxHeight(j.w)
			local hE = maxHeight(j.e)
			addFiller(x0, j.x, z0, z1, hW, hAll, tallest)
			addFiller(j.x, x1, z0, z1, hE, hAll, tallest)
		elseif #j.n > 0 and #j.s > 0 then
			-- N-S run owns the square; trim E/W stems
			for _, arm in j.w do
				arm.segment.finish = math.min(arm.segment.finish, j.x - tNS / 2)
			end
			for _, arm in j.e do
				arm.segment.start = math.max(arm.segment.start, j.x + tNS / 2)
			end
			local hN = maxHeight(j.n)
			local hS = maxHeight(j.s)
			addFiller(x0, x1, z0, j.z, hN, hAll, tallest)
			addFiller(x0, x1, j.z, z1, hS, hAll, tallest)
		else
			-- L corner: the E-W arm extends over the square, the N-S arm stops at its face
			for _, arm in j.w do
				arm.segment.finish = math.max(arm.segment.finish, j.x + tNS / 2)
			end
			for _, arm in j.e do
				arm.segment.start = math.min(arm.segment.start, j.x - tNS / 2)
			end
			for _, arm in j.n do
				arm.segment.finish = math.min(arm.segment.finish, j.z - tEW / 2)
			end
			for _, arm in j.s do
				arm.segment.start = math.max(arm.segment.start, j.z + tEW / 2)
			end
			local hEW = math.max((maxHeight(j.e)), (maxHeight(j.w)))
			addFiller(x0, x1, z0, z1, hEW, hAll, tallest)
		end
	end
	return fillers
end

--------------------------------------------------------------------------------
-- Trims, pillars, stairs
--------------------------------------------------------------------------------

local TRIM_WIDTH = 0.35
local TRIM_PROUD = 0.15 -- how far trims stand off each wall face
local TRIM_REVEAL = 0.05 -- trims cover the cut edge of the wall so the reveal never z-fights

-- Door casing (two jambs + head) around the opening [u0, u1] x [0, top] of a wall `thickness` thick.
-- The opening stays clear for the Creature: the casing is MonsterPassthrough with a pass-through modifier.
function Geometry.doorTrims(
	parent: Instance,
	name: string,
	origin: Vector3,
	axis: Axis,
	coord: number,
	u0: number,
	u1: number,
	top: number,
	thickness: number,
	key: string?
): number
	local a = thickness / 2 + TRIM_PROUD
	local count = 0
	local pieces: { { number } } = {
		{ u0 - TRIM_WIDTH, u0 + TRIM_REVEAL, 0, top + TRIM_WIDTH },
		{ u1 - TRIM_REVEAL, u1 + TRIM_WIDTH, 0, top + TRIM_WIDTH },
		{ u0 + TRIM_REVEAL, u1 - TRIM_REVEAL, top - TRIM_REVEAL, top + TRIM_WIDTH },
	}
	for i, piece in pieces do
		local part = Geometry.wallBox(
			parent,
			string.format("%s_Trim%d", name, i),
			origin,
			axis,
			coord,
			piece[1],
			piece[2],
			piece[3],
			piece[4],
			-a,
			a,
			key,
			{ castShadow = false }
		)
		if part then
			Geometry.makePassthrough(part)
			count += 1
		end
	end
	return count
end

-- Square structural column with passthrough base + capital trims. Returns parts created.
function Geometry.pillar(
	parent: Instance,
	name: string,
	origin: Vector3,
	x: number,
	z: number,
	size: number,
	height: number,
	key: string?,
	trimKey: string?
): number
	local half = size / 2
	local count = 0
	if
		Geometry.box(
			parent,
			name,
			origin + Vector3.new(x - half, 0, z - half),
			origin + Vector3.new(x + half, height, z + half),
			key
		)
	then
		count += 1
	end
	local trimHalf = half + 0.3
	local trims: { { number } } = { { 0, 0.8 }, { height - 0.6, height } }
	for i, span in trims do
		local part = Geometry.box(
			parent,
			string.format("%s_Trim%d", name, i),
			origin + Vector3.new(x - trimHalf, span[1], z - trimHalf),
			origin + Vector3.new(x + trimHalf, span[2], z + trimHalf),
			trimKey or key,
			{ castShadow = false }
		)
		if part then
			Geometry.makePassthrough(part)
			count += 1
		end
	end
	return count
end

export type FlightSpec = {
	parent: Instance,
	name: string,
	start: Vector3, -- world: centre of the flight's bottom edge, at the height of the surface it climbs from
	direction: Vector3, -- horizontal, axis-aligned unit vector the flight climbs toward
	width: number,
	risers: number,
	rise: number, -- per step, <= 1 so Humanoids walk up it
	run: number, -- per step
	underside: number, -- solid depth below each tread's riser
	floor: number?, -- world Y the blocks never extend below (the surface under the first flight)
	key: string?,
}

-- A straight flight of solid step blocks. Step i (1-based) has its tread at start.Y + i * rise and covers
-- [ (i-1) * run, i * run ] along `direction`; the last tread is flush with the landing it arrives at.
function Geometry.stairFlight(spec: FlightSpec): number
	local count = 0
	local alongX = math.abs(spec.direction.X) > 0.5
	for i = 1, spec.risers do
		local top = spec.start.Y + i * spec.rise
		local bottom = top - spec.rise - spec.underside
		if spec.floor then
			bottom = math.max(bottom, spec.floor)
		end
		if top - bottom < EPS then
			continue
		end
		local center = spec.start + spec.direction * ((i - 0.5) * spec.run)
		local size = if alongX
			then Vector3.new(spec.run, top - bottom, spec.width)
			else Vector3.new(spec.width, top - bottom, spec.run)
		Geometry.part(
			spec.parent,
			string.format("%s_Step%02d", spec.name, i),
			CFrame.new(center.X, (top + bottom) / 2, center.Z),
			size,
			spec.key
		)
		count += 1
	end
	return count
end

return table.freeze(Geometry)
