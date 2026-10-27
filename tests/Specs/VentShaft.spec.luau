--!strict
-- VentShaftBuilder contracts on synthetic vent networks and on the real layouts: the 3.5 x 3.5 bore is clear
-- along every duct (of duct parts and, with the shell built, of every colliding part), the galvanized shell closes
-- the bore everywhere except toward connected ducts and grate openings, VentNode links are symmetric, grate
-- attachments sit in the wall plane facing into their room, VentShaft floors carry their segment attributes, and
-- submerged ducts hold visible, non-colliding water in the lower half of the bore. A duct sunk to a pool's
-- waterline (through the chase floor, its grates opening over the basin) stays clear once the shell is built.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local Palette = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Palette)
local SchoolShellBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.SchoolShellBuilder)
local VentShaftBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.VentShaftBuilder)
local ZoneGraph = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Layout = LayoutSchema.LevelLayout
type VentNodeSpec = LayoutSchema.VentNodeSpec

-- Plain-number axis-aligned box (faster than Vector3 math in the hot loops below).
type Box = { x0: number, y0: number, z0: number, x1: number, y1: number, z1: number }

type Seg = {
	id: string,
	edge: LayoutSchema.VentEdgeSpec,
	a: VentNodeSpec,
	b: VentNodeSpec,
	axis: string, -- "X" or "Z"
}

local W = Attributes.World
local R = LayoutSchema.rect

local HALF_BORE = WorldConfig.VentBore / 2
local SHELL = WorldConfig.VentShell
local HALF_OUTER = HALF_BORE + SHELL
local MID_SHELL = HALF_BORE + SHELL / 2
local WALL_HALF = WorldConfig.WallThickness / 2
local TOUCH = 1e-4

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

-- Hallway slice: a chase between two classrooms with an end grate into the hall, two side grates, two tees, a
-- straight joint and a (submerged) dead end.
local function hallwaySlice(): Layout
	return {
		id = "Level1_Hallways",
		height = 14,
		acoustic = "Corridor",
		ambience = "DroneHallways",
		entry = "L1_AirlockEast",
		exit = "S_East",
		rooms = {
			{ id = "L1_AirlockEast", kind = "Airlock", rect = R(228, 66, 12, 28) },
			{ id = "S_Hall", kind = "Corridor", rect = R(180, 66, 48, 28) },
			{ id = "S_West", kind = "Classroom", rect = R(180, 40, 20, 26) },
			{ id = "S_Chase", kind = "Chase", rect = R(200, 40, 5, 26) },
			{ id = "S_East", kind = "Classroom", rect = R(205, 40, 35, 26) },
			{ id = "S_Store", kind = "Storage", rect = R(180, 94, 60, 10) },
		},
		doors = {
			{ id = "D_Air", kind = "Airlock", rooms = { "L1_AirlockEast", "S_Hall" }, at = 80 },
			{ id = "D_Gate", kind = "Gate", rooms = { "S_Hall", "S_East" }, at = 216, scriptedId = "HallwayGate" },
			{ id = "D_West", kind = "Door", rooms = { "S_Hall", "S_West" }, at = 190 },
			{ id = "D_Board", kind = "Boarded", rooms = { "S_Hall", "S_Store" }, at = 200 },
			{ id = "D_Ajar", kind = "Ajar", rooms = { "S_Store", "L1_AirlockEast" }, at = 234 },
		},
		vents = {
			nodes = {
				{ id = "gW", x = 200, z = 52 },
				{ id = "j1", x = 202.5, z = 52 },
				{ id = "jN", x = 202.5, z = 45 },
				{ id = "jS", x = 202.5, z = 55.5 },
				{ id = "j2", x = 202.5, z = 59 },
				{ id = "gE", x = 205, z = 59 },
				{ id = "gH", x = 202.5, z = 66 },
			},
			edges = {
				{ a = "gW", b = "j1" },
				{ a = "j1", b = "jN", submerged = true },
				{ a = "j1", b = "jS" },
				{ a = "jS", b = "j2" },
				{ a = "j2", b = "gE" },
				{ a = "j2", b = "gH" },
			},
			grates = {
				{ id = "G_West", node = "gW", room = "S_West", lockable = true, criticalPath = false },
				{ id = "G_East", node = "gE", room = "S_East", lockable = false, criticalPath = true },
				{ id = "G_Hall", node = "gH", room = "S_Hall", lockable = false, criticalPath = true },
			},
		},
		anchors = {},
		triggers = {},
	}
end

-- Manifold slice: one chase with a dead end, a cross whose two branches are grates, two tees only 3 studs apart
-- with branches on opposite sides (closer than a junction box is wide) and a turn into a grate.
local function manifoldSlice(): Layout
	return {
		id = "Level2_ScienceHall",
		height = 14,
		acoustic = "Room",
		ambience = "DroneScience",
		entry = "B_Hall",
		exit = "B_Hall",
		rooms = {
			{ id = "B_Lab", kind = "Lab", rect = R(0, 0, 30, 40) },
			{ id = "B_Chase", kind = "Chase", rect = R(30, 0, 5, 40) },
			{ id = "B_Prep", kind = "Lab", rect = R(35, 0, 30, 20) },
			{ id = "B_Prep2", kind = "Lab", rect = R(35, 20, 30, 20) },
			{ id = "B_Hall", kind = "Corridor", rect = R(0, 40, 65, 10) },
		},
		doors = {
			{ id = "B_DoorLab", kind = "Door", rooms = { "B_Hall", "B_Lab" }, at = 15 },
			{ id = "B_DoorPrep2", kind = "Door", rooms = { "B_Hall", "B_Prep2" }, at = 50 },
		},
		vents = {
			nodes = {
				{ id = "D0", x = 32.5, z = 4 },
				{ id = "X1", x = 32.5, z = 10 },
				{ id = "gL1", x = 30, z = 10 },
				{ id = "gP1", x = 35, z = 10 },
				{ id = "T1", x = 32.5, z = 14 },
				{ id = "gL2", x = 30, z = 14 },
				{ id = "T2", x = 32.5, z = 17 },
				{ id = "gP2", x = 35, z = 17 },
				{ id = "L1", x = 32.5, z = 26 },
				{ id = "gP3", x = 35, z = 26 },
			},
			edges = {
				{ a = "D0", b = "X1" },
				{ a = "X1", b = "gL1" },
				{ a = "X1", b = "gP1" },
				{ a = "X1", b = "T1" },
				{ a = "T1", b = "gL2" },
				{ a = "T1", b = "T2" },
				{ a = "T2", b = "gP2" },
				{ a = "T2", b = "L1" },
				{ a = "L1", b = "gP3" },
			},
			grates = {
				{ id = "GL1", node = "gL1", room = "B_Lab", lockable = true, criticalPath = false },
				{ id = "GP1", node = "gP1", room = "B_Prep", lockable = false, criticalPath = true },
				{ id = "GL2", node = "gL2", room = "B_Lab", lockable = false, criticalPath = false },
				{ id = "GP2", node = "gP2", room = "B_Prep", lockable = true, criticalPath = false },
				{ id = "GP3", node = "gP3", room = "B_Prep2", lockable = false, criticalPath = true },
			},
		},
		anchors = {},
		triggers = {},
	}
end

-- Pool slice: a flooded duct sunk to the pool's waterline (its centre 1 stud below the deck, so it runs down
-- through the chase floor slab) along the north side of a natatorium, with two grates opening over the basin
-- (whose coping touches the wall), two tees and two dead ends. Every edge is submerged.
local function poolDuctSlice(): Layout
	local y = WorldConfig.WaterSurfaceOffset
	return {
		id = "Level4_FloodedPool",
		height = 20,
		acoustic = "Hall",
		ambience = "DronePool",
		entry = "W_Pool",
		exit = "W_Pool",
		rooms = {
			{ id = "W_Store", kind = "Storage", rect = R(0, -20, 60, 20) },
			{ id = "W_Chase", kind = "Chase", rect = R(0, 0, 60, 5) },
			{ id = "W_Pool", kind = "Pool", rect = R(0, 5, 60, 40) },
		},
		doors = {},
		basins = {
			{ id = "W_Basin", room = "W_Pool", rect = R(10, 5, 40, 40), depth = 8, waterLevel = y },
		},
		vents = {
			nodes = {
				{ id = "jW", x = 5, z = 2.5, y = y },
				{ id = "j1", x = 20, z = 2.5, y = y },
				{ id = "j2", x = 40, z = 2.5, y = y },
				{ id = "jE", x = 55, z = 2.5, y = y },
				{ id = "gP1", x = 20, z = 5, y = y },
				{ id = "gP2", x = 40, z = 5, y = y },
			},
			edges = {
				{ a = "jW", b = "j1", submerged = true },
				{ a = "j1", b = "j2", submerged = true },
				{ a = "j2", b = "jE", submerged = true },
				{ a = "j1", b = "gP1", submerged = true },
				{ a = "j2", b = "gP2", submerged = true },
			},
			grates = {
				{ id = "GP1", node = "gP1", room = "W_Pool", lockable = false, criticalPath = true },
				{ id = "GP2", node = "gP2", room = "W_Pool", lockable = true, criticalPath = false },
			},
		},
		anchors = {},
		triggers = {},
	}
end

local function fixtures(): { Layout }
	return { hallwaySlice(), manifoldSlice(), poolDuctSlice() }
end

local function realLayouts(): { Layout }
	local out: { Layout } = {}
	local folder = ReplicatedStorage.Shared.World.ProceduralWorldBuilder:FindFirstChild("Layouts")
	if not folder then
		return out
	end
	for _, id: Enums.LayoutId in Enums.LayoutId do
		local module = folder:FindFirstChild(id)
		if module and module:IsA("ModuleScript") then
			table.insert(out, (require(module) :: any) :: Layout)
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

local function withoutYield<T>(fn: () -> T): T
	local previous = Geometry.getYieldEvery()
	Geometry.setYieldEvery(0)
	local result = fn()
	Geometry.setYieldEvery(previous)
	return result
end

local function buildVents(layout: Layout): (Model, number)
	local root = Instance.new("Model")
	root.Name = layout.id
	local count = withoutYield(function(): number
		return VentShaftBuilder.build(layout, root)
	end)
	return root, count
end

local function buildWithShell(layout: Layout): Model
	return withoutYield(function(): Model
		local root = SchoolShellBuilder.createRoot(layout)
		SchoolShellBuilder.buildLevel(layout, root, SchoolShellBuilder.levelOptions(layout.id))
		VentShaftBuilder.build(layout, root)
		return root
	end)
end

local function child(parent: Instance, name: string): Instance
	local found = parent:FindFirstChild(name)
	assert(found, string.format("%s has no child %s", parent:GetFullName(), name))
	return found
end

local function childPartOf(parent: Instance, name: string): BasePart
	local found = child(parent, name)
	assert(found:IsA("BasePart"), name .. " is a part")
	return found
end

local function nodeRoot(root: Model): BasePart
	local found = child(child(root, "Vents"), VentShaftBuilder.RootName)
	assert(found:IsA("BasePart"), "VentNodeRoot is a part")
	return found
end

-- The galvanized metal of a level's vents (ducts and fittings; not the node root or the water in flooded ducts).
local function ventParts(root: Model): { BasePart }
	local out: { BasePart } = {}
	local vents = root:FindFirstChild("Vents")
	if not vents then
		return out
	end
	for _, name in { VentShaftBuilder.DuctsFolder, VentShaftBuilder.FittingsFolder } do
		local folder = vents:FindFirstChild(name)
		if folder then
			for _, d in folder:GetDescendants() do
				if d:IsA("BasePart") then
					table.insert(out, d)
				end
			end
		end
	end
	return out
end

local function waterParts(root: Model): { BasePart }
	local out: { BasePart } = {}
	local vents = root:FindFirstChild("Vents")
	local folder = vents and vents:FindFirstChild(VentShaftBuilder.WaterFolder)
	if folder then
		for _, d in folder:GetDescendants() do
			if d:IsA("BasePart") then
				table.insert(out, d)
			end
		end
	end
	return out
end

local function collidingParts(root: Instance): { BasePart }
	local out: { BasePart } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and d.CanCollide then
			table.insert(out, d)
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Geometry helpers
--------------------------------------------------------------------------------

local function boxOf(part: BasePart): Box
	local cf = part.CFrame
	local half = part.Size / 2
	local rx, ry, rz = cf.RightVector, cf.UpVector, cf.LookVector
	local ex = math.abs(rx.X) * half.X + math.abs(ry.X) * half.Y + math.abs(rz.X) * half.Z
	local ey = math.abs(rx.Y) * half.X + math.abs(ry.Y) * half.Y + math.abs(rz.Y) * half.Z
	local ez = math.abs(rx.Z) * half.X + math.abs(ry.Z) * half.Y + math.abs(rz.Z) * half.Z
	local p = cf.Position
	return { x0 = p.X - ex, y0 = p.Y - ey, z0 = p.Z - ez, x1 = p.X + ex, y1 = p.Y + ey, z1 = p.Z + ez }
end

local function boxes(parts: { BasePart }): { Box }
	local out: { Box } = {}
	for _, part in parts do
		table.insert(out, boxOf(part))
	end
	return out
end

-- Overlap volume of two boxes. Faces closer than TOUCH count as touching, not overlapping: part positions are
-- float32, so two parts that share a face can disagree about it by a few millionths of a stud.
local function overlapVolume(a: Box, b: Box): number
	local dx = math.min(a.x1, b.x1) - math.max(a.x0, b.x0)
	local dy = math.min(a.y1, b.y1) - math.max(a.y0, b.y0)
	local dz = math.min(a.z1, b.z1) - math.max(a.z0, b.z0)
	if dx <= TOUCH or dy <= TOUCH or dz <= TOUCH then
		return 0
	end
	return dx * dy * dz
end

-- Inclusive containment (a point on a face counts), for "is this spot metal".
local function touches(box: Box, x: number, y: number, z: number): boolean
	return x >= box.x0 - TOUCH
		and x <= box.x1 + TOUCH
		and y >= box.y0 - TOUCH
		and y <= box.y1 + TOUCH
		and z >= box.z0 - TOUCH
		and z <= box.z1 + TOUCH
end

-- Strict containment, for "is this spot open bore".
local function inside(box: Box, x: number, y: number, z: number): boolean
	return x > box.x0 + TOUCH
		and x < box.x1 - TOUCH
		and y > box.y0 + TOUCH
		and y < box.y1 - TOUCH
		and z > box.z0 + TOUCH
		and z < box.z1 - TOUCH
end

local function anyTouches(list: { Box }, x: number, y: number, z: number): boolean
	for _, box in list do
		if touches(box, x, y, z) then
			return true
		end
	end
	return false
end

local function anyInside(list: { Box }, x: number, y: number, z: number): boolean
	for _, box in list do
		if inside(box, x, y, z) then
			return true
		end
	end
	return false
end

local function segments(layout: Layout): { Seg }
	local out: { Seg } = {}
	local vents = layout.vents
	if not vents then
		return out
	end
	local nodes: { [string]: VentNodeSpec } = {}
	for _, node in vents.nodes do
		nodes[node.id] = node
	end
	for _, edge in vents.edges do
		local a, b = nodes[edge.a], nodes[edge.b]
		if a and b then
			table.insert(out, {
				id = ZoneGraph.segmentId(edge.a, edge.b),
				edge = edge,
				a = a,
				b = b,
				axis = if math.abs(a.x - b.x) > 1e-3 then "X" else "Z",
			})
		end
	end
	return out
end

local function grateNodes(layout: Layout): { [string]: LayoutSchema.GrateSpec }
	local out: { [string]: LayoutSchema.GrateSpec } = {}
	local vents = layout.vents
	if vents then
		for _, grate in vents.grates do
			out[grate.node] = grate
		end
	end
	return out
end

local function degrees(layout: Layout): { [string]: number }
	local out: { [string]: number } = {}
	for _, seg in segments(layout) do
		out[seg.a.id] = (out[seg.a.id] or 0) + 1
		out[seg.b.id] = (out[seg.b.id] or 0) + 1
	end
	return out
end

local function alongOf(node: VentNodeSpec, axis: string): number
	return if axis == "X" then node.x else node.z
end

local function acrossOf(node: VentNodeSpec, axis: string): number
	return if axis == "X" then node.z else node.x
end

-- World box from along / across / height ranges of a duct on `axis`.
local function axisBox(
	origin: Vector3,
	axis: string,
	u0: number,
	u1: number,
	c0: number,
	c1: number,
	y0: number,
	y1: number
): Box
	if axis == "X" then
		return {
			x0 = origin.X + u0,
			x1 = origin.X + u1,
			y0 = origin.Y + y0,
			y1 = origin.Y + y1,
			z0 = origin.Z + c0,
			z1 = origin.Z + c1,
		}
	end
	return {
		x0 = origin.X + c0,
		x1 = origin.X + c1,
		y0 = origin.Y + y0,
		y1 = origin.Y + y1,
		z0 = origin.Z + u0,
		z1 = origin.Z + u1,
	}
end

-- The open bore of a duct: from node centre to node centre, half a bore past a dead end, and all the way through
-- the wall at a grate (the opening is cut through the whole wall thickness). `shrink` keeps touching faces out.
local function boreBox(layout: Layout, seg: Seg, shrink: number): Box
	local grates = grateNodes(layout)
	local degree = degrees(layout)
	local function extension(node: VentNodeSpec): number
		if grates[node.id] then
			return WALL_HALF
		elseif degree[node.id] == 1 then
			return HALF_BORE
		end
		return 0
	end
	local ua, ub = alongOf(seg.a, seg.axis), alongOf(seg.b, seg.axis)
	local s = if ub > ua then 1 else -1
	local u0 = ua - s * extension(seg.a)
	local u1 = ub + s * extension(seg.b)
	local c = acrossOf(seg.a, seg.axis)
	local y = LayoutSchema.ventNodeY(seg.a)
	return axisBox(
		WorldConfig.levelOrigin(layout.id),
		seg.axis,
		math.min(u0, u1) + shrink,
		math.max(u0, u1) - shrink,
		c - HALF_BORE + shrink,
		c + HALF_BORE - shrink,
		y - HALF_BORE + shrink,
		y + HALF_BORE - shrink
	)
end

local function assertBoresClear(t: Expect, layout: Layout, parts: { BasePart }, what: string)
	local partBoxes = boxes(parts)
	for _, seg in segments(layout) do
		local bore = boreBox(layout, seg, 1e-3)
		for i, box in partBoxes do
			local volume = overlapVolume(bore, box)
			if volume > 1e-6 then
				t.fail(
					string.format(
						"%s %s: %s intrudes %.4f stud^3 into the bore of %s",
						what,
						layout.id,
						parts[i]:GetFullName(),
						volume,
						seg.id
					)
				)
			end
		end
	end
end

local RING: { { number } } = {
	{ MID_SHELL, 0 },
	{ -MID_SHELL, 0 },
	{ 0, MID_SHELL },
	{ 0, -MID_SHELL },
	{ MID_SHELL, MID_SHELL },
	{ MID_SHELL, -MID_SHELL },
	{ -MID_SHELL, MID_SHELL },
	{ -MID_SHELL, -MID_SHELL },
}

-- Every point in the middle of the shell ring around every duct's centre line is either metal, the open bore of
-- a connected duct (a branch or the run it joins), or inside the wall at a grate opening.
local function assertEnclosed(t: Expect, layout: Layout, metal: { BasePart }, what: string)
	local origin = WorldConfig.levelOrigin(layout.id)
	local grates = grateNodes(layout)
	local metalBoxes = boxes(metal)
	local bores: { Box } = {}
	for _, seg in segments(layout) do
		table.insert(bores, boreBox(layout, seg, 0))
	end
	for _, seg in segments(layout) do
		local ua, ub = alongOf(seg.a, seg.axis), alongOf(seg.b, seg.axis)
		local c = acrossOf(seg.a, seg.axis)
		local y = LayoutSchema.ventNodeY(seg.a)
		-- only the metal and bores near this duct matter
		local region = axisBox(
			origin,
			seg.axis,
			math.min(ua, ub) - HALF_OUTER - 0.1,
			math.max(ua, ub) + HALF_OUTER + 0.1,
			c - HALF_OUTER - 0.1,
			c + HALF_OUTER + 0.1,
			y - HALF_OUTER - 0.1,
			y + HALF_OUTER + 0.1
		)
		local nearMetal: { Box } = {}
		for _, box in metalBoxes do
			if overlapVolume(region, box) > 0 then
				table.insert(nearMetal, box)
			end
		end
		local nearBores: { Box } = {}
		for _, box in bores do
			if overlapVolume(region, box) > 0 then
				table.insert(nearBores, box)
			end
		end
		local steps = math.max(1, math.ceil(math.abs(ub - ua) / 0.25))
		local failures = 0
		for i = 0, steps do
			local u = ua + (ub - ua) * i / steps
			local inWall = (grates[seg.a.id] ~= nil and math.abs(u - ua) <= WALL_HALF + 1e-3)
				or (grates[seg.b.id] ~= nil and math.abs(u - ub) <= WALL_HALF + 1e-3)
			if inWall then
				continue
			end
			for _, offset in RING do
				local cc, yy = c + offset[1], y + offset[2]
				local x = origin.X + (if seg.axis == "X" then u else cc)
				local z = origin.Z + (if seg.axis == "X" then cc else u)
				local wy = origin.Y + yy
				if not anyTouches(nearMetal, x, wy, z) and not anyInside(nearBores, x, wy, z) then
					failures += 1
					if failures <= 3 then
						t.fail(
							string.format(
								"%s %s: the shell of %s is open at (%.2f, %.2f, %.2f)",
								what,
								layout.id,
								seg.id,
								x,
								wy,
								z
							)
						)
					end
				end
			end
		end
	end
end

local function rectContains2D(rect: LayoutSchema.Rect, origin: Vector3, box: Box): boolean
	local e = 1e-3
	return box.x0 >= origin.X + rect.x - e
		and box.x1 <= origin.X + rect.x + rect.w + e
		and box.z0 >= origin.Z + rect.z - e
		and box.z1 <= origin.Z + rect.z + rect.d + e
end

local function assertInsideChases(t: Expect, layout: Layout, metal: { BasePart }, what: string)
	local origin = WorldConfig.levelOrigin(layout.id)
	for _, part in metal do
		local box = boxOf(part)
		local ok = false
		for _, room in layout.rooms do
			if room.kind == "Chase" and rectContains2D(room.rect, origin, box) then
				ok = true
				break
			end
		end
		t.truthy(ok, string.format("%s %s: %s leaves the chases", what, layout.id, part.Name))
	end
end

local function attachmentWorld(attachment: Attachment): CFrame
	local parent = attachment.Parent
	assert(parent and parent:IsA("BasePart"), "attachment parent is a part")
	return parent.CFrame * attachment.CFrame
end

local function expectedLinks(layout: Layout): { [string]: { [string]: boolean } }
	local out: { [string]: { [string]: boolean } } = {}
	for _, node in (layout.vents :: LayoutSchema.VentNetwork).nodes do
		out[node.id] = {}
	end
	for _, seg in segments(layout) do
		out[seg.a.id][seg.b.id] = true
		out[seg.b.id][seg.a.id] = true
	end
	return out
end

local function assertLinksSymmetric(t: Expect, layout: Layout, root: Model, what: string)
	local base = nodeRoot(root)
	local links: { [string]: { [string]: boolean } } = {}
	for _, d in base:GetChildren() do
		if d:IsA("Attachment") and d:HasTag(Tags.VentNode) then
			local id = Attributes.getString(d, W.NodeId, "")
			links[id] = {}
			for _, other in Attributes.getList(d, W.Links) do
				links[id][other] = true
			end
		end
	end
	local expected = expectedLinks(layout)
	for id, set in expected do
		local actual = links[id]
		t.truthy(actual, string.format("%s %s: VentNode %s exists", what, layout.id, id))
		if not actual then
			continue
		end
		for other in set do
			t.truthy(actual[other], string.format("%s %s: %s links %s", what, layout.id, id, other))
		end
		for other in actual do
			t.truthy(set[other], string.format("%s %s: %s has no duct to %s", what, layout.id, id, other))
			t.truthy(
				links[other] and links[other][id],
				string.format("%s: link %s -> %s is symmetric", what, id, other)
			)
		end
	end
end

local function shaftFloors(root: Model): { [string]: { BasePart } }
	local out: { [string]: { BasePart } } = {}
	for _, part in ventParts(root) do
		if part:HasTag(Tags.VentShaft) then
			local id = Attributes.getString(part, W.SegmentId, "")
			out[id] = out[id] or {}
			table.insert(out[id], part)
		end
	end
	return out
end

local function metalAt(metal: { Box }, origin: Vector3, x: number, y: number, z: number): boolean
	return anyTouches(metal, origin.X + x, origin.Y + y, origin.Z + z)
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["fixtures are valid vent networks"] = function(t: Expect)
		for _, layout in fixtures() do
			for _, problem in LayoutSchema.validate(layout) do
				local lower = string.lower(problem)
				t.falsy(
					string.find(lower, "vent", 1, true) or string.find(lower, "grate", 1, true),
					layout.id .. ": " .. problem
				)
			end
		end
	end,

	["VentNodeRoot sits invisible at the layout origin with one VentNode per node"] = function(t: Expect)
		for _, layout in fixtures() do
			local root = buildVents(layout)
			local base = nodeRoot(root)
			local origin = WorldConfig.levelOrigin(layout.id)
			t.truthy(base.Anchored, "anchored")
			t.eq(base.Transparency, 1, "invisible")
			t.falsy(base.CanCollide, "no collision")
			t.falsy(base.CanQuery, "no queries")
			t.falsy(base.CanTouch, "no touch")
			t.falsy(base.CastShadow, "no shadow")
			t.eq(base.CollisionGroup, CollisionGroups.NoCollide, "NoCollide")
			t.near((base.CFrame.Position - origin).Magnitude, 0, 1e-4, "at the layout origin")
			t.near(base.CFrame.LookVector:Dot(Vector3.new(0, 0, -1)), 1, 1e-6, "identity rotation")
			t.near(base.CFrame.UpVector:Dot(Vector3.new(0, 1, 0)), 1, 1e-6, "identity rotation (up)")
			t.eq(base:GetAttribute(W.LevelId), layout.id)
			local grates = grateNodes(layout)
			for _, node in (layout.vents :: LayoutSchema.VentNetwork).nodes do
				local attachment = child(base, node.id)
				assert(attachment:IsA("Attachment"), node.id .. " is an attachment")
				t.truthy(attachment:HasTag(Tags.VentNode), node.id .. " tagged VentNode")
				t.eq(attachment:GetAttribute(W.NodeId), node.id)
				t.eq(attachment:GetAttribute(W.LevelId), layout.id)
				local position = attachmentWorld(attachment).Position
				local expected = origin + Vector3.new(node.x, LayoutSchema.ventNodeY(node), node.z)
				t.near((position - expected).Magnitude, 0, 1e-4, node.id .. " at the duct centre")
				local grate = grates[node.id]
				t.eq(attachment:GetAttribute(W.GrateId), if grate then grate.id else nil, node.id .. " GrateId")
			end
		end
	end,

	["links are symmetric and follow the ducts"] = function(t: Expect)
		for _, layout in fixtures() do
			local root = buildVents(layout)
			assertLinksSymmetric(t, layout, root, "fixture")
		end
		local root = buildVents(hallwaySlice())
		local j1 = child(nodeRoot(root), "j1")
		t.eq(j1:GetAttribute(W.Links), "gW,jN,jS", "links in duct order")
	end,

	["grate attachments sit in the wall plane and face into their room"] = function(t: Expect)
		for _, layout in fixtures() do
			local root = buildVents(layout)
			local base = nodeRoot(root)
			local origin = WorldConfig.levelOrigin(layout.id)
			local rooms = LayoutSchema.indexRooms(layout)
			local vents = layout.vents :: LayoutSchema.VentNetwork
			local nodes: { [string]: VentNodeSpec } = {}
			for _, node in vents.nodes do
				nodes[node.id] = node
			end
			for _, grate in vents.grates do
				local attachment = child(base, VentShaftBuilder.GratePrefix .. grate.id)
				assert(attachment:IsA("Attachment"), "grate attachment")
				t.falsy(attachment:HasTag(Tags.VentNode), "grate attachments are not graph nodes")
				local node = nodes[grate.node]
				local world = attachmentWorld(attachment)
				local expected = origin + Vector3.new(node.x, LayoutSchema.ventNodeY(node), node.z)
				t.near((world.Position - expected).Magnitude, 0, 1e-4, grate.id .. " at the opening centre")
				local look = world.LookVector
				t.near(look.Y, 0, 1e-6, grate.id .. " looks level")
				t.near(math.max(math.abs(look.X), math.abs(look.Z)), 1, 1e-6, grate.id .. " looks along an axis")
				local room = rooms[grate.room]
				local front = world.Position + look * 1 - origin
				local back = world.Position - look * 1 - origin
				t.truthy(LayoutSchema.rectContains(room.rect, front.X, front.Z), grate.id .. " faces into its room")
				local behindChase = false
				for _, r in layout.rooms do
					if r.kind == "Chase" and LayoutSchema.rectContains(r.rect, back.X, back.Z) then
						behindChase = true
					end
				end
				t.truthy(behindChase, grate.id .. " has its chase behind it")
				t.eq(attachment:GetAttribute(W.GrateId), grate.id)
				t.eq(attachment:GetAttribute(W.NodeId), grate.node)
				t.eq(attachment:GetAttribute(W.FacingZoneId), grate.room)
				t.eq(attachment:GetAttribute(W.Lockable), grate.lockable)
				t.eq(attachment:GetAttribute(W.CriticalPath), grate.criticalPath)
				t.eq(attachment:GetAttribute(W.LevelId), layout.id)
			end
		end
	end,

	["no duct part intrudes into the 3.5 x 3.5 bore along any edge"] = function(t: Expect)
		for _, layout in fixtures() do
			local root = buildVents(layout)
			assertBoresClear(t, layout, ventParts(root), "fixture")
		end
	end,

	["the galvanized shell closes the bore except toward connected ducts and grates"] = function(t: Expect)
		for _, layout in fixtures() do
			local root = buildVents(layout)
			assertEnclosed(t, layout, ventParts(root), "fixture")
		end
	end,

	["junctions are open toward their arms and closed elsewhere"] = function(t: Expect)
		for _, layout in fixtures() do
			local root = buildVents(layout)
			local metal = boxes(ventParts(root))
			local origin = WorldConfig.levelOrigin(layout.id)
			local grates = grateNodes(layout)
			local arms: { [string]: { [string]: boolean } } = {}
			for _, seg in segments(layout) do
				local function arm(from: VentNodeSpec, to: VentNodeSpec)
					arms[from.id] = arms[from.id] or {}
					local dx, dz = to.x - from.x, to.z - from.z
					local key = if math.abs(dx) > math.abs(dz)
						then (if dx > 0 then "+X" else "-X")
						else (if dz > 0 then "+Z" else "-Z")
					arms[from.id][key] = true
				end
				arm(seg.a, seg.b)
				arm(seg.b, seg.a)
			end
			local dirs: { [string]: Vector3 } = {
				["+X"] = Vector3.new(1, 0, 0),
				["-X"] = Vector3.new(-1, 0, 0),
				["+Z"] = Vector3.new(0, 0, 1),
				["-Z"] = Vector3.new(0, 0, -1),
			}
			for _, node in (layout.vents :: LayoutSchema.VentNetwork).nodes do
				if grates[node.id] then
					continue
				end
				local y = LayoutSchema.ventNodeY(node)
				local nodeArms = arms[node.id] or {}
				for key, dir in dirs do
					local closed = (Vector3.new(node.x, y, node.z) + dir * MID_SHELL)
					local open = (Vector3.new(node.x, y, node.z) + dir * (HALF_OUTER + 0.05))
					if nodeArms[key] then
						t.falsy(
							metalAt(metal, origin, open.X, open.Y, open.Z),
							string.format("%s %s: open toward %s", layout.id, node.id, key)
						)
					else
						t.truthy(
							metalAt(metal, origin, closed.X, closed.Y, closed.Z),
							string.format("%s %s: closed toward %s", layout.id, node.id, key)
						)
					end
				end
				t.truthy(metalAt(metal, origin, node.x, y - MID_SHELL, node.z), node.id .. " has a floor")
				t.truthy(metalAt(metal, origin, node.x, y + MID_SHELL, node.z), node.id .. " has a ceiling")
				t.falsy(metalAt(metal, origin, node.x, y, node.z), node.id .. " centre is open")
			end
		end
	end,

	["grate ends stop flush with the wall, dead ends are capped half a bore past the node"] = function(t: Expect)
		local layout = hallwaySlice()
		local root = buildVents(layout)
		local metal = boxes(ventParts(root))
		local origin = WorldConfig.levelOrigin(layout.id)
		local y = WorldConfig.VentCenterHeight
		-- G_West (x = 200, room to the west): metal reaches the chase-side wall face at x = 200.5, never into the wall
		t.truthy(metalAt(metal, origin, 200.5 + 0.01, y - MID_SHELL, 52), "duct floor reaches the wall face")
		t.falsy(metalAt(metal, origin, 200.5 - 0.01, y - MID_SHELL, 52), "no duct inside the wall")
		t.falsy(metalAt(metal, origin, 200.5 + 0.01, y, 52), "no cap at a grate")
		-- G_Hall (z = 66, the hall to the south): wall face at z = 65.5
		t.truthy(metalAt(metal, origin, 202.5, y + MID_SHELL, 65.5 - 0.01), "duct ceiling reaches the wall face")
		t.falsy(metalAt(metal, origin, 202.5, y + MID_SHELL, 65.5 + 0.01), "the duct stops at the wall face")
		-- jN (dead end at z = 45, duct arriving from +Z): bore clear to z = 45 - 1.75, cap beyond it
		t.falsy(metalAt(metal, origin, 202.5, y, 45 - HALF_BORE + 0.02), "bore runs half a bore past the node")
		t.truthy(metalAt(metal, origin, 202.5, y, 45 - HALF_BORE - SHELL / 2), "end cap")
		t.falsy(metalAt(metal, origin, 202.5, y, 45 - HALF_OUTER - 0.02), "nothing beyond the cap")
		local cap = child(child(child(root, "Vents"), VentShaftBuilder.FittingsFolder), "jN_Cap")
		t.truthy(cap:IsA("BasePart"), "the cap is a part")
	end,

	["VentShaft floors carry SegmentId, LevelId, AdjacentZones and Submerged"] = function(t: Expect)
		for _, layout in fixtures() do
			local root = buildVents(layout)
			local floors = shaftFloors(root)
			local origin = WorldConfig.levelOrigin(layout.id)
			local count = 0
			for _, list in floors do
				count += #list
			end
			t.eq(count, #segments(layout), layout.id .. ": one VentShaft floor per duct")
			for _, seg in segments(layout) do
				local list = floors[seg.id]
				t.truthy(list and #list == 1, layout.id .. ": exactly one floor for " .. seg.id)
				if not list then
					continue
				end
				local floor = list[1]
				t.eq(floor:GetAttribute(W.LevelId), layout.id, seg.id .. " LevelId")
				t.eq(
					floor:GetAttribute(W.AdjacentZones),
					Attributes.joinList(ZoneGraph.adjacentZones(layout, seg.a, seg.b)),
					seg.id .. " AdjacentZones"
				)
				t.eq(floor:GetAttribute(W.Submerged), seg.edge.submerged == true, seg.id .. " Submerged")
				local box = boxOf(floor)
				local y = LayoutSchema.ventNodeY(seg.a)
				t.near(box.y1, origin.Y + y - HALF_BORE, 1e-4, seg.id .. " floor top is the bore bottom")
				t.near(box.y1 - box.y0, SHELL, 1e-4, seg.id .. " floor is one shell thick")
			end
		end
		local floors = shaftFloors((buildVents(hallwaySlice())))
		t.eq(floors["j1-jN"][1]:GetAttribute(W.Submerged), true, "the submerged edge is flagged")
		-- j1-jN runs z 45..52 of a chase spanning z 40..66: the hall beyond its south end wall is out of range
		t.eq(floors["j1-jN"][1]:GetAttribute(W.AdjacentZones), "S_West,S_East", "adjacent rooms")
	end,

	["duct parts are anchored galvanized Default-group metal without shadows"] = function(t: Expect)
		local entry = Palette.get("MetalGalvanized")
		for _, layout in fixtures() do
			local parts = ventParts((buildVents(layout)))
			t.truthy(#parts > 0, "parts were built")
			for _, part in parts do
				t.truthy(part.Anchored, part.Name .. " anchored")
				t.eq(part.CollisionGroup, CollisionGroups.Default, part.Name .. " Default group")
				t.truthy(part.CanCollide, part.Name .. " collides")
				t.truthy(part.CanQuery, part.Name .. " blocks sight")
				t.falsy(part.CastShadow, part.Name .. " casts no shadow")
				t.eq(part.Transparency, 0, part.Name .. " opaque")
				t.eq(part.Material, entry.material, part.Name .. " material")
				t.eq(part.Color, entry.color, part.Name .. " colour")
			end
		end
	end,

	["duct parts never overlap and stay inside their chases"] = function(t: Expect)
		for _, layout in fixtures() do
			local parts = ventParts((buildVents(layout)))
			local list = boxes(parts)
			for i = 1, #list do
				for j = i + 1, #list do
					local volume = overlapVolume(list[i], list[j])
					t.truthy(
						volume < 1e-6,
						string.format("%s: %s overlaps %s", layout.id, parts[i].Name, parts[j].Name)
					)
				end
			end
			assertInsideChases(t, layout, parts, "fixture")
		end
	end,

	["with the shell built every bore stays clear through the walls"] = function(t: Expect)
		for _, layout in fixtures() do
			local root = buildWithShell(layout)
			assertBoresClear(t, layout, collidingParts(root), "fixture + shell")
		end
	end,

	["build returns its part count and a rebuild replaces the previous network"] = function(t: Expect)
		local layout = manifoldSlice()
		local root, count = buildVents(layout)
		local function partsUnderVents(): number
			local n = 0
			for _, d in child(root, "Vents"):GetDescendants() do
				if d:IsA("BasePart") then
					n += 1
				end
			end
			return n
		end
		t.eq(partsUnderVents(), count, "returned count = parts created")
		local again = withoutYield(function(): number
			return VentShaftBuilder.build(layout, root)
		end)
		t.eq(again, count, "same count on rebuild")
		t.eq(partsUnderVents(), count, "the previous network was replaced, not duplicated")
		local roots = 0
		for _, d in child(root, "Vents"):GetChildren() do
			if d.Name == VentShaftBuilder.RootName then
				roots += 1
			end
		end
		t.eq(roots, 1, "one VentNodeRoot")
	end,

	["submerged ducts hold murky water in the lower half of the bore, and only they do"] = function(t: Expect)
		local entry = Palette.get("Water")
		for _, layout in fixtures() do
			local root = buildVents(layout)
			local origin = WorldConfig.levelOrigin(layout.id)
			local water = waterParts(root)
			local byName: { [string]: BasePart } = {}
			for _, part in water do
				byName[part.Name] = part
				t.truthy(part.Anchored, part.Name .. " anchored")
				t.falsy(part.CanCollide, part.Name .. " never collides")
				t.falsy(part.CanQuery, part.Name .. " is never queried")
				t.falsy(part.CanTouch, part.Name .. " has no touch")
				t.falsy(part.CastShadow, part.Name .. " casts no shadow")
				t.eq(part.CollisionGroup, CollisionGroups.NoCollide, part.Name .. " NoCollide")
				t.near(part.Transparency, 0.25, 1e-6, part.Name .. " murky, not invisible")
				t.eq(part.Material, entry.material, part.Name .. " material")
			end
			local flooded = 0
			for _, seg in segments(layout) do
				local part = byName[seg.id .. "_Water"]
				if seg.edge.submerged ~= true then
					t.falsy(part, layout.id .. ": dry duct " .. seg.id .. " holds no water")
					continue
				end
				flooded += 1
				t.truthy(part, layout.id .. ": submerged duct " .. seg.id .. " holds water")
				if not part then
					continue
				end
				local box = boxOf(part)
				local y = LayoutSchema.ventNodeY(seg.a)
				local c = acrossOf(seg.a, seg.axis)
				t.near(box.y0, origin.Y + y - HALF_BORE, 1e-4, seg.id .. " water stands on the bore floor")
				t.near(box.y1 - box.y0, VentShaftBuilder.WaterDepth, 1e-4, seg.id .. " water depth")
				t.near(VentShaftBuilder.WaterDepth, HALF_BORE, 1e-6, "the lower half of the bore")
				local c0 = if seg.axis == "X" then box.z0 - origin.Z else box.x0 - origin.X
				local c1 = if seg.axis == "X" then box.z1 - origin.Z else box.x1 - origin.X
				t.near(c0, c - HALF_BORE, 1e-4, seg.id .. " water fills the bore's width")
				t.near(c1, c + HALF_BORE, 1e-4, seg.id .. " water fills the bore's width")
			end
			t.eq(#water, flooded, layout.id .. ": one water part per submerged duct")
			-- water never overlaps itself or the metal, and fills every flooded duct end to end
			local waterBoxes = boxes(water)
			for i = 1, #waterBoxes do
				for j = i + 1, #waterBoxes do
					t.truthy(
						overlapVolume(waterBoxes[i], waterBoxes[j]) < 1e-6,
						string.format("%s: %s overlaps %s", layout.id, water[i].Name, water[j].Name)
					)
				end
			end
			for _, metal in boxes(ventParts(root)) do
				for i, box in waterBoxes do
					t.truthy(overlapVolume(metal, box) < 1e-6, layout.id .. ": metal intrudes into " .. water[i].Name)
				end
			end
			local grates = grateNodes(layout)
			for _, seg in segments(layout) do
				if seg.edge.submerged ~= true then
					continue
				end
				local ua, ub = alongOf(seg.a, seg.axis), alongOf(seg.b, seg.axis)
				local c = acrossOf(seg.a, seg.axis)
				local y = LayoutSchema.ventNodeY(seg.a) - HALF_BORE / 2
				local steps = math.max(1, math.ceil(math.abs(ub - ua) / 0.25))
				for i = 0, steps do
					local u = ua + (ub - ua) * i / steps
					local inWall = (grates[seg.a.id] ~= nil and math.abs(u - ua) <= WALL_HALF + 1e-3)
						or (grates[seg.b.id] ~= nil and math.abs(u - ub) <= WALL_HALF + 1e-3)
					if inWall then
						continue
					end
					local x = origin.X + (if seg.axis == "X" then u else c)
					local z = origin.Z + (if seg.axis == "X" then c else u)
					t.truthy(
						anyTouches(waterBoxes, x, origin.Y + y, z),
						string.format("%s %s: dry at (%.2f, %.2f)", layout.id, seg.id, x - origin.X, z - origin.Z)
					)
				end
			end
		end
	end,

	["a flooded duct at the waterline runs through the slab and opens over the pool"] = function(t: Expect)
		local layout = poolDuctSlice()
		local root = buildWithShell(layout)
		local origin = WorldConfig.levelOrigin(layout.id)
		local y = WorldConfig.WaterSurfaceOffset
		local solid: { Box } = boxes(collidingParts(root))
		local function solidAt(x: number, yy: number, z: number): boolean
			return anyInside(solid, origin.X + x, origin.Y + yy, origin.Z + z)
		end
		-- the chase floor is carved around the duct, which dips through it
		t.falsy(solidAt(30, -1.9, 2.5), "no slab in the bore where the duct dips through the floor")
		t.truthy(solidAt(30, y - HALF_BORE - SHELL / 2, 2.5), "the duct floor closes the bore from below")
		t.truthy(solidAt(30, -1, 0.3), "the slab still stands beside the duct")
		-- the coping is open under each grate down to the bore floor, and still solid either side of it
		for _, x in { 20, 40 } do
			t.falsy(solidAt(x, y, 5.6), string.format("coping open at the grate at x = %d", x))
			t.falsy(solidAt(x, y - HALF_BORE + 0.1, 5.6), "coping open down to the bore floor")
			t.truthy(solidAt(x, y - HALF_BORE - 0.2, 5.6), "coping solid under the opening")
			t.truthy(solidAt(x + HALF_BORE + 0.2, y, 5.6), "coping solid beside the opening")
		end
		-- the duct's water runs through the wall and the coping, up to the pool's own surface
		local water = boxes(waterParts(root))
		local pool = childPartOf(child(root, "Shell"), "W_Basin_Surface")
		local poolBox = boxOf(pool)
		t.near(poolBox.y1 - origin.Y, y, 1e-4, "pool surface at the waterline")
		t.truthy(anyTouches(water, origin.X + 20, origin.Y + y - 0.5, origin.Z + 5.9), "water through the coping")
		local reach = -math.huge
		for _, box in water do
			if box.x0 < origin.X + 20 and box.x1 > origin.X + 20 then
				reach = math.max(reach, box.z1 - origin.Z)
			end
		end
		t.near(reach, 5 + Geometry.BasinWall, 1e-4, "duct water stops where the pool surface starts")
		for _, box in water do
			t.truthy(overlapVolume(box, poolBox) < 1e-6, "duct water never overlaps the pool surface")
		end
	end,

	["a layout without vents builds nothing"] = function(t: Expect)
		local layout = hallwaySlice()
		layout.vents = nil
		local root, count = buildVents(layout)
		t.eq(count, 0)
		local vents = root:FindFirstChild("Vents")
		t.truthy(vents == nil or #vents:GetChildren() == 0, "no vent instances")
	end,

	["real layouts: clear bores, closed shells, symmetric links and a floor per duct"] = function(t: Expect)
		for _, layout in realLayouts() do
			if not layout.vents then
				continue
			end
			local root = buildWithShell(layout)
			local metal = ventParts(root)
			assertLinksSymmetric(t, layout, root, "real")
			assertBoresClear(t, layout, collidingParts(root), "real")
			assertEnclosed(t, layout, metal, "real")
			assertInsideChases(t, layout, metal, "real")
			local floors = shaftFloors(root)
			for _, seg in segments(layout) do
				local list = floors[seg.id]
				t.truthy(list and #list == 1, layout.id .. ": one VentShaft floor for " .. seg.id)
			end
			local base = nodeRoot(root)
			for _, grate in layout.vents.grates do
				local attachment = base:FindFirstChild(VentShaftBuilder.GratePrefix .. grate.id)
				t.truthy(attachment and attachment:IsA("Attachment"), layout.id .. ": attachment for " .. grate.id)
			end
		end
	end,
}
