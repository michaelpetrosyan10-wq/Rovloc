--!strict
-- VentGraph on the real vent levels (Levels 1-4 built once with BuildAuthoritative into a detached host) and on
-- hand-built graphs and instances. Checked: one node per layout node at the level origin plus (x, ventNodeY, z); links
-- are exactly the layout's ducts, both ways; one grate per layout grate on its node, its wall facing into its room and
-- its mouth WallThickness / 2 + 0.3 out; every duct maps (both orders) to its VentShaft floor's SegmentId; nearest
-- projects onto edges and mouth stubs (t, position, distance), honours maxDistance and breaks ties by key; the small
-- queries (edgeLength, neighbours, nearestNode, segmentId, pointAt, grateOf); build's handling of odd instances
-- (missing nodes, one-way links, other levels, no root); built graphs are frozen.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Tags = require(ReplicatedStorage.Shared.Tags)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local VentShaftBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.VentShaftBuilder)
local ZoneGraph = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Graph = VentGraph.Graph
type Layout = LayoutSchema.LevelLayout

local W = Attributes.World

local VENT_LEVELS: { Enums.LevelId } =
	{ "Level1_Hallways", "Level2_ScienceHall", "Level3_Gymnasium", "Level4_FloodedPool" }
local ALL_LEVELS: { Enums.LevelId } =
	{ "Level0_Basement", "Level1_Hallways", "Level2_ScienceHall", "Level3_Gymnasium", "Level4_FloodedPool" }
local EPS = 1e-3
local MOUTH_OUT = WorldConfig.WallThickness / 2 + 0.3

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

type World = { levels: { [string]: Model }, graphs: { [string]: Graph } }

local cached: World? = nil

-- The vent levels, built once into a detached host (never Workspace: in Studio the specs run beside the live school).
local function world(): World
	local existing = cached
	if existing then
		return existing
	end
	local host = Instance.new("Model")
	host.Name = "VentGraphSpec"
	local result = Builder.BuildAuthoritative({ parent = host :: Instance, layouts = ALL_LEVELS, yieldEvery = 0 })
	local graphs: { [string]: Graph } = {}
	for _, id in VENT_LEVELS do
		local graph = VentGraph.build(result.levels[id], id)
		assert(graph, id .. " builds a graph")
		graphs[id] = graph
	end
	local built: World = { levels = result.levels, graphs = graphs }
	cached = built
	return built
end

local function layoutOf(id: string): Layout
	local layout = Builder.getLayout(id)
	assert(layout, "layout " .. id)
	return layout
end

local function near(a: Vector3, b: Vector3, epsilon: number?): boolean
	return (a - b).Magnitude <= (epsilon or EPS)
end

local function sortedCopy(list: { string }): { string }
	local copy = table.clone(list)
	table.sort(copy)
	return copy
end

local function countKeys<V>(map: { [string]: V }): number
	local count = 0
	for _ in map do
		count += 1
	end
	return count
end

-- Each duct once, as (a, b) with a < b.
local function edgesOf(graph: Graph): { { string } }
	local out: { { string } } = {}
	for id, node in graph.nodes do
		for _, other in node.links do
			if id < other then
				table.insert(out, { id, other })
			end
		end
	end
	table.sort(out, function(x: { string }, y: { string }): boolean
		return x[1] .. "|" .. x[2] < y[1] .. "|" .. y[2]
	end)
	return out
end

-- A hand-built graph: a straight run W - J - E with a branch J - N, and a grate on N opening north (-Z).
local function handGraph(): Graph
	local wall = CFrame.lookAt(Vector3.new(0, 2, -6), Vector3.new(0, 2, -7))
	return {
		levelId = "Level1_Hallways",
		nodes = {
			W = { id = "W", position = Vector3.new(-5, 2, 0), links = { "J" }, grateId = nil },
			J = { id = "J", position = Vector3.new(0, 2, 0), links = { "W", "E", "N" }, grateId = nil },
			E = { id = "E", position = Vector3.new(7, 2, 0), links = { "J" }, grateId = nil },
			N = { id = "N", position = Vector3.new(0, 2, -6), links = { "J" }, grateId = "G" },
		},
		grates = {
			G = {
				id = "G",
				nodeId = "N",
				facingZoneId = "Room",
				lockable = false,
				criticalPath = true,
				wall = wall,
				mouth = wall.Position + wall.LookVector * MOUTH_OUT,
			},
		},
		grateAtNode = { N = "G" },
		segments = { ["W|J"] = "W-J", ["J|W"] = "W-J", ["J|N"] = "J-N", ["N|J"] = "J-N" },
	}
end

-- A VentNodeRoot part built by hand: `nodes` = { id, position (root-local), links attribute, level? }.
local function handRoot(
	nodes: { { id: string, at: Vector3, links: string, level: string? } },
	grates: { { id: string, node: string, at: CFrame } }
): Model
	local level = Instance.new("Model")
	local vents = Instance.new("Folder")
	vents.Name = "Vents"
	vents.Parent = level
	local root = Instance.new("Part")
	root.Name = VentShaftBuilder.RootName
	root.CFrame = CFrame.new(100, 50, -20)
	root.Parent = vents
	for _, spec in nodes do
		local attachment = Instance.new("Attachment")
		attachment.Name = spec.id
		attachment.CFrame = CFrame.new(spec.at)
		attachment:AddTag(Tags.VentNode)
		attachment:SetAttribute(W.NodeId, spec.id)
		attachment:SetAttribute(W.Links, spec.links)
		attachment:SetAttribute(W.LevelId, spec.level or "Level2_ScienceHall")
		attachment.Parent = root
	end
	for _, spec in grates do
		local attachment = Instance.new("Attachment")
		attachment.Name = VentShaftBuilder.GratePrefix .. spec.id
		attachment.CFrame = spec.at
		attachment:SetAttribute(W.GrateId, spec.id)
		attachment:SetAttribute(W.NodeId, spec.node)
		attachment:SetAttribute(W.FacingZoneId, "Lab")
		attachment:SetAttribute(W.Lockable, true)
		attachment:SetAttribute(W.CriticalPath, false)
		attachment:SetAttribute(W.LevelId, "Level2_ScienceHall")
		attachment.Parent = root
	end
	return level
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["real levels: one node per layout node, at the level origin + (x, ventNodeY, z)"] = function(t: Expect)
		local built = world()
		for _, id in VENT_LEVELS do
			local graph = built.graphs[id]
			local layout = layoutOf(id)
			local vents = layout.vents
			assert(vents, id .. " has vents")
			t.eq(graph.levelId, id)
			t.eq(countKeys(graph.nodes), #vents.nodes, id .. " node count")
			local origin = WorldConfig.levelOrigin(id)
			for _, spec in vents.nodes do
				local node = graph.nodes[spec.id]
				assert(node, id .. " has node " .. spec.id)
				t.eq(node.id, spec.id)
				local expected = origin + Vector3.new(spec.x, LayoutSchema.ventNodeY(spec), spec.z)
				t.truthy(near(node.position, expected), spec.id .. " at " .. tostring(node.position))
			end
		end
	end,

	["real levels: links are exactly the layout's ducts, both ways"] = function(t: Expect)
		local built = world()
		for _, id in VENT_LEVELS do
			local graph = built.graphs[id]
			local vents = layoutOf(id).vents
			assert(vents, id)
			local expected: { [string]: { string } } = {}
			for _, spec in vents.nodes do
				expected[spec.id] = {}
			end
			for _, edge in vents.edges do
				table.insert(expected[edge.a], edge.b)
				table.insert(expected[edge.b], edge.a)
			end
			for nodeId, list in expected do
				local node = graph.nodes[nodeId]
				t.eq(
					table.concat(sortedCopy(node.links), ","),
					table.concat(sortedCopy(list), ","),
					id .. " links of " .. nodeId
				)
				for _, other in node.links do
					t.truthy(table.find(graph.nodes[other].links, nodeId) ~= nil, "two-way " .. nodeId .. "-" .. other)
				end
			end
		end
	end,

	["real levels: grates sit on their nodes, face into their rooms, mouths 0.3 inside the room face"] = function(
		t: Expect
	)
		local built = world()
		for _, id in VENT_LEVELS do
			local graph = built.graphs[id]
			local layout = layoutOf(id)
			local vents = layout.vents
			assert(vents, id)
			local rooms = LayoutSchema.indexRooms(layout)
			local origin = WorldConfig.levelOrigin(id)
			t.eq(countKeys(graph.grates), #vents.grates, id .. " grate count")
			for _, spec in vents.grates do
				local grate = graph.grates[spec.id]
				assert(grate, id .. " has grate " .. spec.id)
				t.eq(grate.nodeId, spec.node)
				t.eq(grate.facingZoneId, spec.room)
				t.eq(grate.lockable, spec.lockable)
				t.eq(grate.criticalPath, spec.criticalPath)
				t.eq(graph.grateAtNode[spec.node], spec.id)
				t.eq(graph.nodes[spec.node].grateId, spec.id)
				t.eq(VentGraph.grateOf(graph, spec.node), grate)
				t.truthy(near(grate.wall.Position, graph.nodes[spec.node].position), spec.id .. " wall on its node")
				local look = grate.wall.LookVector
				t.near(math.abs(look.Y), 0, 1e-4, "level look")
				local room = rooms[spec.room]
				local inside = grate.wall.Position + look * 2 - origin
				local behind = grate.wall.Position - look * 2 - origin
				t.truthy(LayoutSchema.rectContains(room.rect, inside.X, inside.Z), spec.id .. " looks into its room")
				t.falsy(LayoutSchema.rectContains(room.rect, behind.X, behind.Z), spec.id .. " backs onto the chase")
				t.truthy(near(grate.mouth, grate.wall.Position + look * MOUTH_OUT), spec.id .. " mouth")
			end
			for nodeId, node in graph.nodes do
				if graph.grateAtNode[nodeId] == nil then
					t.eq(node.grateId, nil, nodeId .. " carries no grate")
				end
			end
		end
	end,

	["real levels: every duct maps both ways to its VentShaft floor's SegmentId"] = function(t: Expect)
		local built = world()
		for _, id in VENT_LEVELS do
			local graph = built.graphs[id]
			local vents = layoutOf(id).vents
			assert(vents, id)
			local floors: { [string]: boolean } = {}
			for _, descendant in built.levels[id]:GetDescendants() do
				if descendant:HasTag(Tags.VentShaft) then
					floors[Attributes.getString(descendant, W.SegmentId, "")] = true
				end
			end
			for _, edge in vents.edges do
				local segmentId = ZoneGraph.segmentId(edge.a, edge.b)
				t.truthy(floors[segmentId], id .. " has a floor for " .. segmentId)
				t.eq(VentGraph.segmentId(graph, edge.a, edge.b), segmentId)
				t.eq(VentGraph.segmentId(graph, edge.b, edge.a), segmentId, "either order")
			end
			t.eq(countKeys(graph.segments), 2 * #vents.edges, id .. " both orders of every duct")
			t.eq(VentGraph.segmentId(graph, "nope", "nada"), nil)
		end
	end,

	["real levels: nearest projects onto every duct and mouth stub"] = function(t: Expect)
		local built = world()
		local lift = Vector3.new(0, 0.6, 0)
		for _, id in VENT_LEVELS do
			local graph = built.graphs[id]
			for _, edge in edgesOf(graph) do
				local a, b = graph.nodes[edge[1]].position, graph.nodes[edge[2]].position
				for _, fraction in { 0.25, 0.5, 0.75 } do
					local onRail = a:Lerp(b, fraction)
					local rail = VentGraph.nearest(graph, onRail + lift)
					assert(rail, "a rail point")
					t.eq(rail.a, edge[1], id .. " edge start")
					t.eq(rail.b, edge[2], id .. " edge end")
					t.near(rail.t, fraction, 1e-4, "t from a")
					t.truthy(near(rail.position, onRail), "the foot of the perpendicular")
					t.near(rail.distance, 0.6, 1e-4)
					t.eq(VentGraph.nearest(graph, onRail + lift, 0.5), nil, "beyond maxDistance")
					t.truthy(VentGraph.nearest(graph, onRail + lift, 0.7) ~= nil, "within maxDistance")
				end
			end
			for grateId, grate in graph.grates do
				local node = graph.nodes[grate.nodeId].position
				local halfway = node:Lerp(grate.mouth, 0.5)
				local rail = VentGraph.nearest(graph, halfway + Vector3.new(0, 0.3, 0))
				assert(rail, "a stub point")
				t.eq(rail.a, grate.nodeId, grateId .. " stub from its node")
				t.eq(rail.b, nil, "stubs have no b")
				t.near(rail.t, 0.5, 1e-4)
				t.truthy(near(rail.position, halfway))
				local beyond = VentGraph.nearest(graph, grate.mouth + grate.wall.LookVector * 1.5)
				assert(beyond, "past the mouth")
				t.eq(beyond.b, nil)
				t.near(beyond.t, 1, 1e-6, "clamped to the mouth")
				t.near(beyond.distance, 1.5, 1e-4)
				local fromPoint = VentGraph.pointAt(graph, grate.nodeId, nil, 0.5)
				t.truthy(fromPoint ~= nil and near(fromPoint, halfway), "pointAt on the stub")
			end
		end
	end,

	["real levels: a point on a node resolves to the smallest key among the pieces meeting there"] = function(
		t: Expect
	)
		local built = world()
		for _, id in VENT_LEVELS do
			local graph = built.graphs[id]
			for nodeId, node in graph.nodes do
				local keys: { string } = {}
				for _, other in node.links do
					table.insert(
						keys,
						if nodeId < other then VentGraph.pairKey(nodeId, other) else VentGraph.pairKey(other, nodeId)
					)
				end
				if graph.grateAtNode[nodeId] then
					table.insert(keys, VentGraph.pairKey(nodeId, nil))
				end
				table.sort(keys)
				local rail = VentGraph.nearest(graph, node.position)
				assert(rail, "a rail point at " .. nodeId)
				t.near(rail.distance, 0, 1e-6)
				t.eq(VentGraph.pairKey(rail.a, rail.b), keys[1], id .. " tie at " .. nodeId)
				t.eq(VentGraph.nearestNode(graph, node.position + Vector3.new(0.1, 0, 0)), nodeId)
			end
		end
	end,

	["real levels: edge lengths, neighbours and the basement without vents"] = function(t: Expect)
		local built = world()
		for _, id in VENT_LEVELS do
			local graph = built.graphs[id]
			for _, edge in edgesOf(graph) do
				local length = (graph.nodes[edge[1]].position - graph.nodes[edge[2]].position).Magnitude
				t.near(VentGraph.edgeLength(graph, edge[1], edge[2]), length, 1e-6)
				t.near(VentGraph.edgeLength(graph, edge[2], edge[1]), length, 1e-6)
			end
			for nodeId, node in graph.nodes do
				t.eq(
					table.concat(sortedCopy(VentGraph.neighbours(graph, nodeId)), ","),
					table.concat(sortedCopy(node.links), ",")
				)
			end
		end
		t.eq(VentGraph.build(built.levels.Level0_Basement, "Level0_Basement"), nil, "no ducts in the basement")
		t.eq(VentGraph.build(Instance.new("Folder"), "Level1_Hallways"), nil, "no VentNodeRoot")
	end,

	["built graphs are frozen"] = function(t: Expect)
		local graph = world().graphs.Level1_Hallways
		t.truthy(table.isfrozen(graph))
		t.truthy(table.isfrozen(graph.nodes))
		t.truthy(table.isfrozen(graph.grates))
		t.truthy(table.isfrozen(graph.grateAtNode))
		t.truthy(table.isfrozen(graph.segments))
		for _, node in graph.nodes do
			t.truthy(table.isfrozen(node) and table.isfrozen(node.links), node.id)
		end
		for _, grate in graph.grates do
			t.truthy(table.isfrozen(grate), grate.id)
		end
		local list = VentGraph.neighbours(graph, next(graph.nodes) :: string)
		table.insert(list, "mine") -- a fresh list, safe to change
		t.truthy(#list > 0)
	end,

	["hand-built graph: queries"] = function(t: Expect)
		local graph = handGraph()
		t.eq(VentGraph.edgeLength(graph, "W", "J"), 5)
		t.eq(VentGraph.edgeLength(graph, "J", "E"), 7)
		t.eq(VentGraph.edgeLength(graph, "W", "E"), math.huge, "not linked")
		t.eq(VentGraph.edgeLength(graph, "W", "W"), math.huge, "no self duct")
		t.eq(VentGraph.edgeLength(graph, "W", "Missing"), math.huge)
		t.eq(table.concat(VentGraph.neighbours(graph, "J"), ","), "W,E,N")
		t.eq(#VentGraph.neighbours(graph, "Missing"), 0)
		t.eq(VentGraph.segmentId(graph, "J", "W"), "W-J")
		t.eq(VentGraph.segmentId(graph, "J", "E"), nil, "a duct without a floor part")
		t.eq(VentGraph.nearestNode(graph, Vector3.new(6, 9, 1)), "E")
		t.eq(VentGraph.nearestNode(graph, Vector3.new(-2.5, 2, 0)), "J", "equidistant: the smaller id")
		local empty: Graph = { levelId = "x", nodes = {}, grates = {}, grateAtNode = {}, segments = {} }
		t.eq(VentGraph.nearestNode(empty, Vector3.zero), nil)
		t.eq(VentGraph.nearest(empty, Vector3.zero), nil, "no rail")

		local onEast = VentGraph.nearest(graph, Vector3.new(3.5, 3, 0.5))
		assert(onEast, "east duct")
		t.eq(onEast.a, "E", "edge ends in string order")
		t.eq(onEast.b, "J")
		t.near(onEast.t, 0.5, 1e-6, "t measured from a (E)")
		t.truthy(near(onEast.position, Vector3.new(3.5, 2, 0)))
		t.near(onEast.distance, math.sqrt(1.25), 1e-6)

		local mouth = graph.grates.G.mouth
		local stub = VentGraph.nearest(graph, Vector3.new(0.2, 2, -6.5))
		assert(stub, "the stub")
		t.eq(stub.a, "N")
		t.eq(stub.b, nil)
		t.near(stub.t, 0.5 / MOUTH_OUT, 1e-6)
		local pointed = VentGraph.pointAt(graph, "N", nil, 1)
		t.truthy(pointed ~= nil and near(pointed, mouth), "the stub's end is the mouth")
		local middle = VentGraph.pointAt(graph, "W", "J", 0.5)
		t.truthy(middle ~= nil and near(middle, Vector3.new(-2.5, 2, 0)))
		t.eq(VentGraph.pointAt(graph, "W", "E", 0.5), nil, "no such duct")
		t.eq(VentGraph.pointAt(graph, "W", nil, 0.5), nil, "W has no grate")
		t.eq(VentGraph.grateOf(graph, "J"), nil)
	end,

	["hand-built graph: a one-way link is still a duct"] = function(t: Expect)
		local graph = handGraph()
		local nodes = graph.nodes :: { [string]: VentGraph.Node }
		nodes.E = { id = "E", position = Vector3.new(7, 2, 0), links = {}, grateId = nil }
		local rail = VentGraph.nearest(graph, Vector3.new(6, 2.2, 0))
		assert(rail, "east duct")
		t.eq(rail.a, "E")
		t.eq(rail.b, "J")
		t.eq(VentGraph.edgeLength(graph, "E", "J"), 7, "either end listing it is enough")
		t.eq(table.concat(VentGraph.neighbours(graph, "E"), ","), "J", "neighbours include who lists it")
	end,

	["build: links made two-way, strays dropped, other levels and orphan grates skipped"] = function(t: Expect)
		local level = handRoot({
			{ id = "A", at = Vector3.new(0, 2, 0), links = "B,Ghost" },
			{ id = "B", at = Vector3.new(10, 2, 0), links = "" },
			{ id = "C", at = Vector3.new(10, 2, 8), links = "B,C" },
			{ id = "Far", at = Vector3.new(0, 2, 30), links = "A", level = "Level3_Gymnasium" },
		}, {
			{ id = "GA", node = "A", at = CFrame.lookAt(Vector3.new(0, 2, 0), Vector3.new(-1, 2, 0)) },
			{ id = "GLost", node = "Nowhere", at = CFrame.new(5, 2, 5) },
		})
		local graph = VentGraph.build(level, "Level2_ScienceHall")
		assert(graph, "a graph")
		t.eq(countKeys(graph.nodes), 3, "Far belongs to another level")
		t.eq(table.concat(graph.nodes.A.links, ","), "B", "the link to a missing node is dropped")
		t.eq(table.concat(sortedCopy(graph.nodes.B.links), ","), "A,C", "links become two-way")
		t.eq(table.concat(graph.nodes.C.links, ","), "B", "no self link")
		local root = (level:FindFirstChild("Vents") :: Instance):FindFirstChild(VentShaftBuilder.RootName) :: BasePart
		t.truthy(near(graph.nodes.B.position, root.CFrame * Vector3.new(10, 2, 0)), "root-relative positions")
		t.eq(countKeys(graph.grates), 1, "the grate on a missing node is skipped")
		local grate = graph.grates.GA
		t.eq(grate.facingZoneId, "Lab")
		t.eq(grate.lockable, true)
		t.eq(grate.criticalPath, false)
		t.truthy(near(grate.wall.LookVector, Vector3.new(-1, 0, 0)))
		t.truthy(near(grate.mouth, root.CFrame * Vector3.new(-MOUTH_OUT, 2, 0)))
		t.eq(graph.nodes.A.grateId, "GA")
		t.eq(countKeys(graph.segments), 0, "no duct floors")
		local fromRoot = VentGraph.build(root, "Level2_ScienceHall")
		t.truthy(fromRoot ~= nil and countKeys(fromRoot.nodes) == 3, "the VentNodeRoot itself works too")
		t.eq(VentGraph.build(handRoot({}, {}), "Level2_ScienceHall"), nil, "a root without nodes")
	end,
}
