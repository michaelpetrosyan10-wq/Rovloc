--!strict
-- VentShaftBuilder: one level's galvanized ducts and its VentNode graph.
--
-- Every vent edge becomes a hollow, axis-aligned duct (floor, ceiling and two side walls) around an exact
-- WorldConfig.VentBore x VentBore bore with a WorldConfig.VentShell skin. Ducts are anchored Default-group parts,
-- so players outside collide with them and a vent crawler's VentCollider ball (the only part of a crawler that
-- collides, and only with Default) is contained by the walls. The interior is unlit. A duct floor shows its
-- sheet-metal joints, rust where water stood and the grime of every crawl (one SurfaceGui on its inner face).
--
-- What each node needs, from its arms (the ducts leaving it):
--   * grate node   the duct stops flush with the chase-side face of the wall the grate opening is cut through,
--                  so the 3.5 x 3.5 opening continues the bore into the room (no cap);
--   * dead end     the duct runs half a bore past the node and an end cap closes it;
--   * straight     two collinear ducts meet at the node centre (the bore just continues);
--   * junction     (a turn, tee or cross) one axis runs through: its duct continues across the node (or, at a turn,
--                  runs half a bore past it and is capped), with an opening cut in its side wall toward every
--                  branch; branches start at the through duct's outer face. The result is a junction box open
--                  toward every connected arm and closed elsewhere, built from the duct's own walls. Because
--                  openings are cut from whole wall runs, junctions closer together than a box width (two branches
--                  3 studs apart on opposite sides of a chase) still leave every bore clear.
--
-- The graph: one invisible VentNodeRoot part at the layout origin (identity rotation) in the level's Vents folder;
-- each node is an Attachment named by its id (tag VentNode; attrs NodeId, Links, LevelId, GrateId?) at the duct
-- centre; each grate also gets an Attachment `Grate_<grateId>` at the opening centre in the wall plane whose
-- LookVector points into the room (attrs GrateId, NodeId, FacingZoneId, Lockable, CriticalPath, LevelId).
-- Each duct's floor part is tagged VentShaft (attrs SegmentId "<a>-<b>", LevelId, AdjacentZones, Submerged).
--
-- Submerged ducts hold murky water: a visible, non-colliding, never-queried slab fills the lower half of the bore
-- along the whole duct (through the side-wall opening into the run a branch joins, and at a grate that opens over
-- a pool basin, on through the wall and the basin coping to the pool's own surface). The water is cosmetic; the
-- layout's PoolWater trigger volume is what gameplay tests against.
--
-- Edges that cannot be built as a level, axis-aligned duct (missing node, self loop, diagonal, height change) are
-- skipped with a warning and left out of Links, so the VentNode graph only ever holds crawlable ducts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(script.Parent.Geometry)
local Palette = require(script.Parent.Palette)
local SurfaceArt = require(script.Parent.SurfaceArt)
local ZoneGraph = require(script.Parent.ZoneGraph)

local log = Log.new("VentShafts")

type Layout = LayoutSchema.LevelLayout
type Room = LayoutSchema.Room
type VentNodeSpec = LayoutSchema.VentNodeSpec
type VentEdgeSpec = LayoutSchema.VentEdgeSpec
type GrateSpec = LayoutSchema.GrateSpec

-- Plain strings (string-literal unions widen when they round-trip through tables): an axis is "X" or "Z"; a
-- direction is "+X", "-X", "+Z" or "-Z".
type Axis = string
type Dir = string

type EdgePlan = {
	spec: VentEdgeSpec,
	a: VentNodeSpec,
	b: VentNodeSpec,
	axis: Axis,
	fromA: Dir, -- direction from a toward b
	fromB: Dir, -- direction from b toward a
	length: number, -- centre to centre
	segmentId: string,
}

type GrateSite = {
	grate: GrateSpec,
	room: Room,
	inward: Dir, -- from the wall plane into the room
}

type NodePlan = {
	node: VentNodeSpec,
	arms: { [Dir]: EdgePlan },
	armCount: number,
	grate: GrateSite?,
	starts: { [Dir]: number }, -- per arm: signed distance from the centre to where that arm's duct starts
	waterStarts: { [Dir]: number }, -- per arm: where a submerged duct's water starts (defaults to `starts`)
	cap: Dir?, -- side of the node an end cap closes
}

-- A gap cut into a duct side wall where a branch leaves: ducts along `axis` whose centre line sits at `cross`
-- (and height `y`) lose their `side` wall over [u0, u1] along the axis.
type Opening = { axis: Axis, cross: number, y: number, side: Dir, u0: number, u1: number }

type Builder = {
	layout: Layout,
	origin: Vector3,
	ducts: Folder,
	fittings: Folder,
	water: Folder?, -- created on the first submerged duct
	vents: Folder,
	count: number,
}

-- A level-local axis-aligned box.
export type Envelope = {
	segmentId: string,
	x0: number,
	x1: number,
	y0: number,
	y1: number,
	z0: number,
	z1: number,
}

local W = Attributes.World
local Names = Instances.Names

local EPS = Geometry.EPS
local BORE = WorldConfig.VentBore
local HALF_BORE = BORE / 2
local HALF_OUTER = HALF_BORE + WorldConfig.VentShell
local GRATE_WALL_HALF = WorldConfig.WallThickness / 2 -- grates sit in interior chase walls

local DUCT_KEY = "MetalGalvanized"
local ROOT_NAME = "VentNodeRoot"
local DUCTS_FOLDER = "Ducts"
local FITTINGS_FOLDER = "Fittings"
local WATER_FOLDER = "Water"
local GRATE_PREFIX = "Grate_"

-- Water in a submerged duct stands at the duct's centre line: it fills the lower half of the bore.
local WATER_DEPTH = HALF_BORE
local WATER_KEY = "Water"

local DIR_VECTOR: { [Dir]: Vector3 } = {
	["+X"] = Vector3.new(1, 0, 0),
	["-X"] = Vector3.new(-1, 0, 0),
	["+Z"] = Vector3.new(0, 0, 1),
	["-Z"] = Vector3.new(0, 0, -1),
}

local OPPOSITE: { [Dir]: Dir } = {
	["+X"] = "-X",
	["-X"] = "+X",
	["+Z"] = "-Z",
	["-Z"] = "+Z",
}

local AXIS_DIRS: { [Axis]: { Dir } } = {
	X = { "-X", "+X" },
	Z = { "-Z", "+Z" },
}

local OTHER_AXIS: { [Axis]: Axis } = { X = "Z", Z = "X" }

-- Compass name of a duct side (N = -Z, S = +Z, W = -X, E = +X), for part names.
local SIDE_NAME: { [Dir]: string } = { ["-Z"] = "N", ["+Z"] = "S", ["-X"] = "W", ["+X"] = "E" }

-- Wall side of the room the grate node lies on -> the direction from that wall into the room.
local INWARD: { [string]: Dir } = { N = "+Z", S = "-Z", W = "+X", E = "-X" }

local metalEntry = Palette.get(DUCT_KEY)
local metalOptions: Geometry.PartOptions = {
	castShadow = false,
	canCollide = true,
	material = metalEntry.material,
	color = metalEntry.color,
}

-- Same murky look as a pool basin's surface.
local waterOptions: Geometry.PartOptions = {
	transparency = 0.25,
	canCollide = false,
	canQuery = false,
	castShadow = false,
	reflectance = 0.08,
}

local VentShaftBuilder = {}

VentShaftBuilder.RootName = ROOT_NAME
VentShaftBuilder.GratePrefix = GRATE_PREFIX
VentShaftBuilder.DuctsFolder = DUCTS_FOLDER
VentShaftBuilder.FittingsFolder = FITTINGS_FOLDER
VentShaftBuilder.WaterFolder = WATER_FOLDER
VentShaftBuilder.WaterDepth = WATER_DEPTH

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function axisOf(dir: Dir): Axis
	return string.sub(dir, 2, 2)
end

local function sign(dir: Dir): number
	return if string.sub(dir, 1, 1) == "+" then 1 else -1
end

-- Coordinate of a node along `axis`, and across it (Z for an X duct, X for a Z duct).
local function along(node: VentNodeSpec, axis: Axis): number
	return if axis == "X" then node.x else node.z
end

local function across(node: VentNodeSpec, axis: Axis): number
	return if axis == "X" then node.z else node.x
end

-- Solid parts of [u0, u1] once every [gap0, gap1] is removed, in order.
local function subtractSpans(u0: number, u1: number, gaps: { { number } }): { { number } }
	local solids: { { number } } = { { u0, u1 } }
	for _, cut in gaps do
		local nextSolids: { { number } } = {}
		for _, span in solids do
			local s0, s1 = span[1], span[2]
			if cut[2] <= s0 + EPS or cut[1] >= s1 - EPS then
				table.insert(nextSolids, span)
				continue
			end
			if cut[1] - s0 > EPS then
				table.insert(nextSolids, { s0, cut[1] })
			end
			if s1 - cut[2] > EPS then
				table.insert(nextSolids, { cut[2], s1 })
			end
		end
		solids = nextSolids
	end
	table.sort(solids, function(a: { number }, b: { number }): boolean
		return a[1] < b[1]
	end)
	return solids
end

--------------------------------------------------------------------------------
-- Planning
--------------------------------------------------------------------------------

-- `quiet` skips the warnings (a second planning pass over a layout the build already reported on).
local function planEdges(
	layout: Layout,
	nodes: { [string]: VentNodeSpec },
	edges: { VentEdgeSpec },
	quiet: boolean?
): { EdgePlan }
	local plans: { EdgePlan } = {}
	local function skip(reason: string, spec: VentEdgeSpec)
		if not quiet then
			log.warn("%s: duct %s-%s %s; skipped", layout.id, spec.a, spec.b, reason)
		end
	end
	for _, spec in edges do
		local a, b = nodes[spec.a], nodes[spec.b]
		if not a or not b then
			skip("references a missing node", spec)
			continue
		end
		if a.id == b.id then
			skip("joins a node to itself", spec)
			continue
		end
		if math.abs(LayoutSchema.ventNodeY(a) - LayoutSchema.ventNodeY(b)) > EPS then
			skip("changes height", spec)
			continue
		end
		local dx, dz = b.x - a.x, b.z - a.z
		local alongX, alongZ = math.abs(dx) > EPS, math.abs(dz) > EPS
		if alongX == alongZ then
			skip("is not axis-aligned", spec)
			continue
		end
		local axis: Axis = if alongX then "X" else "Z"
		local delta = if alongX then dx else dz
		local fromA: Dir = (if delta > 0 then "+" else "-") .. axis
		table.insert(plans, {
			spec = spec,
			a = a,
			b = b,
			axis = axis,
			fromA = fromA,
			fromB = OPPOSITE[fromA],
			length = math.abs(delta),
			segmentId = ZoneGraph.segmentId(spec.a, spec.b),
		})
	end
	return plans
end

-- When the room side of the grate on `node` (just past the wall it is cut through) lies over a pool basin: how
-- far from the node, toward the room, the basin's open water starts (the inner face of its coping). Nil otherwise.
local function basinReach(layout: Layout, node: VentNodeSpec, inward: Dir): number?
	local dir = DIR_VECTOR[inward]
	local probe = GRATE_WALL_HALF + Geometry.BasinWall / 2
	local x, z = node.x + dir.X * probe, node.z + dir.Z * probe
	for _, basin in (layout.basins or {}) :: { LayoutSchema.Basin } do
		local r = basin.rect
		if not LayoutSchema.rectContains(r, x, z) then
			continue
		end
		local wall = Geometry.BasinWall
		local edge = if inward == "+X"
			then r.x + wall
			elseif inward == "-X" then r.x + r.w - wall
			elseif inward == "+Z" then r.z + wall
			else r.z + r.d - wall
		local reach = (edge - (if axisOf(inward) == "X" then node.x else node.z)) * sign(inward)
		return math.max(reach, GRATE_WALL_HALF)
	end
	return nil
end

local function grateSite(layout: Layout, grate: GrateSpec, node: VentNodeSpec, rooms: { [string]: Room }): GrateSite?
	local room = rooms[grate.room]
	if not room then
		log.warn("%s: grate %s opens into missing room %s", layout.id, grate.id, grate.room)
		return nil
	end
	local side = LayoutSchema.sideOfPoint(room.rect, node.x, node.z)
	if not side then
		log.warn("%s: grate %s node %s is not on a wall of %s", layout.id, grate.id, node.id, room.id)
		return nil
	end
	return { grate = grate, room = room, inward = INWARD[side] }
end

local function armsOn(plan: NodePlan, axis: Axis): number
	local count = 0
	for _, dir in AXIS_DIRS[axis] do
		if plan.arms[dir] then
			count += 1
		end
	end
	return count
end

-- The only arm a node has on `axis` (callers know there is exactly one).
local function soleArm(plan: NodePlan, axis: Axis): Dir
	local dirs = AXIS_DIRS[axis]
	return if plan.arms[dirs[1]] then dirs[1] else dirs[2]
end

-- How much of a chase run each axis carries at a junction: arms that lead on to another duct node (not a grate),
-- then total duct length.
local function runScore(plan: NodePlan, axis: Axis, grateNodes: { [string]: boolean }): (number, number)
	local runs, length = 0, 0
	for _, dir in AXIS_DIRS[axis] do
		local edge = plan.arms[dir]
		if edge then
			length += edge.length
			local far = if edge.a.id == plan.node.id then edge.b else edge.a
			if not grateNodes[far.id] then
				runs += 1
			end
		end
	end
	return runs, length
end

-- The axis whose duct runs across a junction. A tee keeps its two collinear arms as the run. At a turn or a cross
-- the axis that carries more of the chase run goes through, so the junction's closed sides are part of that run's
-- side walls (and any branch opening nearby can cut them); an arm to a grate is a branch whenever possible.
local function chooseThrough(plan: NodePlan, grateNodes: { [string]: boolean }): Axis
	local xArms, zArms = armsOn(plan, "X"), armsOn(plan, "Z")
	if xArms ~= zArms then
		return if xArms > zArms then "X" else "Z"
	end
	local xRuns, xLength = runScore(plan, "X", grateNodes)
	local zRuns, zLength = runScore(plan, "Z", grateNodes)
	if xRuns ~= zRuns then
		return if xRuns > zRuns then "X" else "Z"
	end
	if math.abs(xLength - zLength) > EPS then
		return if xLength > zLength then "X" else "Z"
	end
	return "X"
end

local function planNodes(
	layout: Layout,
	order: { VentNodeSpec },
	edges: { EdgePlan },
	sites: { [string]: GrateSite }
): ({ [string]: NodePlan }, { Opening })
	local plans: { [string]: NodePlan } = {}
	for _, node in order do
		plans[node.id] = {
			node = node,
			arms = {},
			armCount = 0,
			grate = sites[node.id],
			starts = {},
			waterStarts = {},
			cap = nil,
		}
	end
	local function addArm(plan: NodePlan, dir: Dir, edge: EdgePlan)
		if plan.arms[dir] then
			log.warn("%s: vent node %s has two ducts leaving toward %s", layout.id, plan.node.id, dir)
			return
		end
		plan.arms[dir] = edge
		plan.armCount += 1
	end
	for _, edge in edges do
		addArm(plans[edge.a.id], edge.fromA, edge)
		addArm(plans[edge.b.id], edge.fromB, edge)
	end
	local grateNodes: { [string]: boolean } = {}
	for nodeId in sites do
		grateNodes[nodeId] = true
	end

	local openings: { Opening } = {}
	for _, node in order do
		local plan = plans[node.id]
		local site = plan.grate
		if plan.armCount == 0 then
			continue
		end
		if site then
			-- grate end: the duct stops at the chase-side face of the wall the opening is cut through
			local chaseward = OPPOSITE[site.inward]
			if plan.armCount == 1 and plan.arms[chaseward] then
				plan.starts[chaseward] = GRATE_WALL_HALF
				-- over a pool the water runs on through the wall and the basin coping, up to the pool's own surface
				local reach = basinReach(layout, node, site.inward)
				if reach then
					plan.waterStarts[chaseward] = -reach
				end
				continue
			end
			log.warn(
				"%s: grate node %s needs exactly one duct leaving straight into the chase; fitted as a plain node",
				layout.id,
				node.id
			)
		end
		local xArms, zArms = armsOn(plan, "X"), armsOn(plan, "Z")
		if xArms == 0 or zArms == 0 then
			local axis: Axis = if xArms > 0 then "X" else "Z"
			if plan.armCount == 2 then
				-- straight joint: both ducts run to the centre
				for _, dir in AXIS_DIRS[axis] do
					plan.starts[dir] = 0
				end
			else
				-- dead end: the duct runs half a bore past the centre and is capped there
				local dir = soleArm(plan, axis)
				plan.starts[dir] = -HALF_BORE
				plan.cap = OPPOSITE[dir]
			end
			continue
		end

		-- junction: the through axis continues (or, with one arm, is capped past the centre like a dead end);
		-- branches start at its outer face and cut an opening into its side wall

		local through = chooseThrough(plan, grateNodes)
		if armsOn(plan, through) == 2 then
			for _, dir in AXIS_DIRS[through] do
				plan.starts[dir] = 0
			end
		else
			local dir = soleArm(plan, through)
			plan.starts[dir] = -HALF_BORE
			plan.cap = OPPOSITE[dir]
		end
		local u = along(node, through)
		for _, dir in AXIS_DIRS[OTHER_AXIS[through]] do
			if plan.arms[dir] then
				plan.starts[dir] = HALF_OUTER
				-- water reaches through the side-wall opening to the bore of the run it joins
				plan.waterStarts[dir] = HALF_BORE
				table.insert(openings, {
					axis = through,
					cross = across(node, through),
					y = LayoutSchema.ventNodeY(node),
					side = dir,
					u0 = u - HALF_BORE,
					u1 = u + HALF_BORE,
				})
			end
		end
	end
	return plans, openings
end

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

-- Level-local box [x0, x1] x [y0, y1] x [z0, z1] of galvanized metal.
local function metalBox(
	builder: Builder,
	parent: Instance,
	name: string,
	x0: number,
	x1: number,
	y0: number,
	y1: number,
	z0: number,
	z1: number
): Part?
	local part = Geometry.box(
		parent,
		name,
		builder.origin + Vector3.new(x0, y0, z0),
		builder.origin + Vector3.new(x1, y1, z1),
		DUCT_KEY,
		metalOptions
	)
	if part then
		builder.count += 1
	end
	return part
end

-- Box running [along0, along1] along `axis` and [cross0, cross1] across it.
local function axisBox(
	builder: Builder,
	parent: Instance,
	name: string,
	axis: Axis,
	along0: number,
	along1: number,
	cross0: number,
	cross1: number,
	y0: number,
	y1: number
): Part?
	if axis == "X" then
		return metalBox(builder, parent, name, along0, along1, y0, y1, cross0, cross1)
	end
	return metalBox(builder, parent, name, cross0, cross1, y0, y1, along0, along1)
end

local SEAM = Color3.fromRGB(34, 36, 36)
local RUST = Color3.fromRGB(92, 54, 28)
local DUCT_SEAM_PITCH = 4 -- studs between the sheet-metal joints of a duct run

-- The inside of a duct's floor sheet: the joints between its sheets, rust where water stood and grime ground in
-- by every crawl (one low-resolution SurfaceGui, symmetric under any flip of the canvas).
local function weatherDuct(floor: BasePart, axis: Axis, seed: string)
	local size = floor.Size
	local length = if axis == "X" then size.X else size.Z
	local joints = math.max(1, math.floor(length / DUCT_SEAM_PITCH + 0.5))
	local gui, pps = SurfaceArt.gui(floor, Enum.NormalId.Top, { name = "Wear", pixelsPerStud = 6, maxDistance = 40 })
	local thickness = math.max(1, math.floor(pps * 0.1 + 0.5))
	if axis == "X" then
		SurfaceArt.grid(gui, joints, 1, SEAM, 0.3, thickness, 1)
	else
		SurfaceArt.grid(gui, 1, joints, SEAM, 0.3, thickness, 1)
	end
	local random = MathUtil.seededRandom(1, seed .. ":wear")
	for _ = 1, random:NextInteger(0, 2) do
		local at = random:NextNumber(0.15, 0.85)
		local w, d = random:NextNumber(0.5, 0.9), random:NextNumber(0.1, 0.3)
		if axis == "X" then
			SurfaceArt.stain(gui, at, 0.5, d, w, RUST, random:NextNumber(0.45, 0.7), nil, 2)
		else
			SurfaceArt.stain(gui, 0.5, at, w, d, RUST, random:NextNumber(0.45, 0.7), nil, 2)
		end
	end
	SurfaceArt.grime(gui, Color3.fromRGB(20, 18, 16), random:NextNumber(0.25, 0.45), random:NextNumber() < 0.5, 3)
end

-- The four walls of one duct, its side walls split around every branch opening. Returns the floor part (nil when
-- the fittings at both ends already meet, so the duct has no length of its own).
local function buildDuct(builder: Builder, edge: EdgePlan, plans: { [string]: NodePlan }, openings: { Opening }): Part?
	local axis = edge.axis
	local s = sign(edge.fromA)
	local startAt = along(edge.a, axis) + s * (plans[edge.a.id].starts[edge.fromA] or 0)
	local finishAt = along(edge.b, axis) - s * (plans[edge.b.id].starts[edge.fromB] or 0)
	local length = (finishAt - startAt) * s
	if length <= EPS then
		if length < -EPS then
			log.warn(
				"%s: duct %s is shorter than the fittings at its ends; its ends overlap",
				builder.layout.id,
				edge.segmentId
			)
		end
		return nil
	end
	local u0, u1 = math.min(startAt, finishAt), math.max(startAt, finishAt)
	local c = across(edge.a, axis)
	local y = LayoutSchema.ventNodeY(edge.a)
	local name = edge.segmentId
	local floor = axisBox(
		builder,
		builder.ducts,
		name .. "_Floor",
		axis,
		u0,
		u1,
		c - HALF_OUTER,
		c + HALF_OUTER,
		y - HALF_OUTER,
		y - HALF_BORE
	)
	if floor then
		weatherDuct(floor, axis, builder.layout.id .. ":" .. name)
	end
	axisBox(
		builder,
		builder.ducts,
		name .. "_Ceiling",
		axis,
		u0,
		u1,
		c - HALF_OUTER,
		c + HALF_OUTER,
		y + HALF_BORE,
		y + HALF_OUTER
	)
	local crossAxis = OTHER_AXIS[axis]
	for _, side in AXIS_DIRS[crossAxis] do
		local gaps: { { number } } = {}
		for _, opening in openings do
			if
				opening.axis == axis
				and opening.side == side
				and math.abs(opening.cross - c) < EPS
				and math.abs(opening.y - y) < EPS
			then
				table.insert(gaps, { opening.u0, opening.u1 })
			end
		end
		local c0, c1 =
			if sign(side) < 0 then c - HALF_OUTER else c + HALF_BORE,
			if sign(side) < 0 then c - HALF_BORE else c + HALF_OUTER
		local spans = subtractSpans(u0, u1, gaps)
		for i, span in spans do
			local suffix = if #spans == 1 then "" else tostring(i)
			axisBox(
				builder,
				builder.ducts,
				string.format("%s_Wall%s%s", name, SIDE_NAME[side], suffix),
				axis,
				span[1],
				span[2],
				c0,
				c1,
				y - HALF_BORE,
				y + HALF_BORE
			)
		end
	end
	return floor
end

-- The murky water standing in the lower half of a submerged duct's bore, from where its water starts at each end
-- (see NodePlan.waterStarts) so neighbouring flooded ducts meet without overlapping.
local function buildWater(builder: Builder, edge: EdgePlan, plans: { [string]: NodePlan })
	local axis = edge.axis
	local s = sign(edge.fromA)
	local planA, planB = plans[edge.a.id], plans[edge.b.id]
	local startA = planA.waterStarts[edge.fromA] or planA.starts[edge.fromA] or 0
	local startB = planB.waterStarts[edge.fromB] or planB.starts[edge.fromB] or 0
	local from = along(edge.a, axis) + s * startA
	local to = along(edge.b, axis) - s * startB
	if (to - from) * s <= EPS then
		return
	end
	local folder: Folder = builder.water or Geometry.folder(builder.vents, WATER_FOLDER)
	builder.water = folder
	local u0, u1 = math.min(from, to), math.max(from, to)
	local c = across(edge.a, axis)
	local bottom = LayoutSchema.ventNodeY(edge.a) - HALF_BORE
	local x0, x1, z0, z1 = c - HALF_BORE, c + HALF_BORE, u0, u1
	if axis == "X" then
		x0, x1, z0, z1 = u0, u1, c - HALF_BORE, c + HALF_BORE
	end
	local part = Geometry.box(
		folder,
		edge.segmentId .. "_Water",
		builder.origin + Vector3.new(x0, bottom, z0),
		builder.origin + Vector3.new(x1, bottom + WATER_DEPTH, z1),
		WATER_KEY,
		waterOptions
	)
	if part then
		Geometry.makeFixture(part)
		builder.count += 1
	end
end

-- End cap over the whole duct section, half a bore beyond the node on the `plan.cap` side.
local function buildCap(builder: Builder, plan: NodePlan)
	local dir = plan.cap
	if not dir then
		return
	end
	local node = plan.node
	local axis = axisOf(dir)
	local u = along(node, axis)
	local s = sign(dir)
	local inner, outer = u + s * HALF_BORE, u + s * HALF_OUTER
	local c = across(node, axis)
	local y = LayoutSchema.ventNodeY(node)
	axisBox(
		builder,
		builder.fittings,
		node.id .. "_Cap",
		axis,
		math.min(inner, outer),
		math.max(inner, outer),
		c - HALF_OUTER,
		c + HALF_OUTER,
		y - HALF_OUTER,
		y + HALF_OUTER
	)
end

--------------------------------------------------------------------------------
-- Graph attachments
--------------------------------------------------------------------------------

local function nodeLinks(order: { VentNodeSpec }, edges: { EdgePlan }): { [string]: { string } }
	local links: { [string]: { string } } = {}
	for _, node in order do
		links[node.id] = {}
	end
	local function link(from: string, to: string)
		local list = links[from]
		if not table.find(list, to) then
			table.insert(list, to)
		end
	end
	for _, edge in edges do
		link(edge.a.id, edge.b.id)
		link(edge.b.id, edge.a.id)
	end
	return links
end

local function clearPrevious(vents: Instance)
	for _, name in { ROOT_NAME, DUCTS_FOLDER, FITTINGS_FOLDER, WATER_FOLDER } do
		local previous = vents:FindFirstChild(name)
		if previous then
			previous:Destroy()
		end
	end
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

-- Level-local boxes the ducts of `layout` occupy (pure, no instances): each buildable duct from end to end with
-- its shell, reaching half a bore plus the shell past every node it does not end at a grate (which covers junction
-- boxes and end caps) and through the wall to the wall's far face at a grate. The shell builder keeps the
-- structural slab out of these, so a duct may sit low in its chase (down to a pool's waterline) and stay clear.
function VentShaftBuilder.envelopes(layout: Layout): { Envelope }
	local out: { Envelope } = {}
	local vents = layout.vents
	if not vents then
		return out
	end
	local nodes: { [string]: VentNodeSpec } = {}
	for _, node in vents.nodes do
		if not nodes[node.id] then
			nodes[node.id] = node
		end
	end
	local grateNodes: { [string]: boolean } = {}
	for _, grate in vents.grates do
		grateNodes[grate.node] = true
	end
	local function reach(node: VentNodeSpec): number
		return if grateNodes[node.id] then GRATE_WALL_HALF else HALF_OUTER
	end
	for _, edge in planEdges(layout, nodes, vents.edges, true) do
		local axis = edge.axis
		local s = sign(edge.fromA)
		local ua = along(edge.a, axis) - s * reach(edge.a)
		local ub = along(edge.b, axis) + s * reach(edge.b)
		local u0, u1 = math.min(ua, ub), math.max(ua, ub)
		local c = across(edge.a, axis)
		local y = LayoutSchema.ventNodeY(edge.a)
		local x0, x1, z0, z1 = c - HALF_OUTER, c + HALF_OUTER, u0, u1
		if axis == "X" then
			x0, x1, z0, z1 = u0, u1, c - HALF_OUTER, c + HALF_OUTER
		end
		table.insert(out, {
			segmentId = edge.segmentId,
			x0 = x0,
			x1 = x1,
			y0 = y - HALF_OUTER,
			y1 = y + HALF_OUTER,
			z0 = z0,
			z1 = z1,
		})
	end
	return out
end

-- Builds `layout`'s ducts and VentNode graph into `levelModel`'s Vents folder (replacing an earlier build there).
-- Returns the number of parts created.
function VentShaftBuilder.build(layout: Layout, levelModel: Model): number
	local vents = layout.vents
	if not vents then
		return 0
	end
	local folder = Geometry.folder(levelModel, Names.Vents)
	clearPrevious(folder)

	local origin = WorldConfig.levelOrigin(layout.id)
	local rooms = LayoutSchema.indexRooms(layout)
	local nodes: { [string]: VentNodeSpec } = {}
	local order: { VentNodeSpec } = {}
	for _, node in vents.nodes do
		if nodes[node.id] then
			log.warn("%s: duplicate vent node %s ignored", layout.id, node.id)
			continue
		end
		nodes[node.id] = node
		table.insert(order, node)
	end

	-- Grates (the first grate listed on a node owns it)
	local sites: { [string]: GrateSite } = {}
	local grates: { GrateSite } = {}
	for _, grate in vents.grates do
		local node = nodes[grate.node]
		if not node then
			log.warn("%s: grate %s sits on missing node %s", layout.id, grate.id, grate.node)
			continue
		end
		local existing = sites[node.id]
		if existing then
			log.warn(
				"%s: node %s already carries grate %s; %s ignored",
				layout.id,
				node.id,
				existing.grate.id,
				grate.id
			)
			continue
		end
		local site = grateSite(layout, grate, node, rooms)
		if site then
			sites[node.id] = site
			table.insert(grates, site)
		end
	end

	local edges = planEdges(layout, nodes, vents.edges)
	local plans, openings = planNodes(layout, order, edges, sites)

	local builder: Builder = {
		layout = layout,
		origin = origin,
		ducts = Geometry.folder(folder, DUCTS_FOLDER),
		fittings = Geometry.folder(folder, FITTINGS_FOLDER),
		water = nil,
		vents = folder,
		count = 0,
	}

	-- Ducts, with their floors tagged as VentShaft segments; submerged ducts hold water
	for _, edge in edges do
		local floor = buildDuct(builder, edge, plans, openings)
		if floor then
			floor:AddTag(Tags.VentShaft)
			floor:SetAttribute(W.SegmentId, edge.segmentId)
			floor:SetAttribute(W.LevelId, layout.id)
			floor:SetAttribute(W.AdjacentZones, Attributes.joinList(ZoneGraph.adjacentZones(layout, edge.a, edge.b)))
			floor:SetAttribute(W.Submerged, edge.spec.submerged == true)
		end
		if edge.spec.submerged == true then
			buildWater(builder, edge, plans)
		end
	end

	-- End caps (dead ends and the far side of turns)
	for _, node in order do
		buildCap(builder, plans[node.id])
	end

	-- VentNodeRoot + attachments
	local root = Geometry.part(folder, ROOT_NAME, CFrame.new(origin), Vector3.new(1, 1, 1), nil, nil)
	Geometry.makeVolume(root)
	root:SetAttribute(W.LevelId, layout.id)
	builder.count += 1

	local links = nodeLinks(order, edges)
	for _, node in order do
		local attachment = Geometry.attachment(root, node.id, CFrame.new(node.x, LayoutSchema.ventNodeY(node), node.z))
		attachment:AddTag(Tags.VentNode)
		attachment:SetAttribute(W.NodeId, node.id)
		attachment:SetAttribute(W.Links, Attributes.joinList(links[node.id]))
		attachment:SetAttribute(W.LevelId, layout.id)
		local site = sites[node.id]
		if site then
			attachment:SetAttribute(W.GrateId, site.grate.id)
		end
	end

	for _, site in grates do
		local node = nodes[site.grate.node]
		local position = Vector3.new(node.x, LayoutSchema.ventNodeY(node), node.z)
		local attachment = Geometry.attachment(
			root,
			GRATE_PREFIX .. site.grate.id,
			CFrame.lookAt(position, position + DIR_VECTOR[site.inward])
		)
		attachment:SetAttribute(W.GrateId, site.grate.id)
		attachment:SetAttribute(W.NodeId, node.id)
		attachment:SetAttribute(W.FacingZoneId, site.room.id)
		attachment:SetAttribute(W.Lockable, site.grate.lockable)
		attachment:SetAttribute(W.CriticalPath, site.grate.criticalPath)
		attachment:SetAttribute(W.LevelId, layout.id)
	end

	return builder.count
end

return table.freeze(VentShaftBuilder)
