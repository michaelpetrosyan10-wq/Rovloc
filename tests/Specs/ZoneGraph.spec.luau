--!strict
-- ZoneGraph contracts on small synthetic layouts (node / edge counts, every portal kind, blocked-set reachability,
-- shortest paths, level solvability, duct adjacency) and on the real layouts: every school level stays solvable
-- with nothing blocked and in the worst case a run can produce (every gate shut, every lockable grate locked).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local ZoneGraph = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Layout = LayoutSchema.LevelLayout
type Graph = Types.ZoneGraphData

local R = LayoutSchema.rect
local L0: Enums.LayoutId = "Level0_Basement"
local L1: Enums.LayoutId = "Level1_Hallways"

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

-- The east end of a basement: a spawn hall and the airlock that climbs to Level 1 (Stairwell_0_1).
local function basementSlice(): Layout
	return {
		id = L0,
		height = 16,
		acoustic = "Basement",
		ambience = "DroneBasement",
		entry = "B_Spawn",
		exit = "L0_AirlockEast",
		rooms = {
			{ id = "B_Spawn", kind = "Boiler", rect = R(180, 66, 48, 28) },
			{ id = "L0_AirlockEast", kind = "Airlock", rect = R(228, 66, 12, 28) },
		},
		doors = { { id = "D_B", kind = "Airlock", rooms = { "B_Spawn", "L0_AirlockEast" }, at = 80 } },
		anchors = {},
		triggers = {},
	}
end

-- The east end of a hallway floor: the arrival airlock, a hall, a gated classroom (the exit), a second classroom,
-- a planked store reached through an ajar door, and a chase whose duct bypasses the gate:
--   G_Hall (hall) -> gH -> j2 -> gE -> G_East (exit classroom)        critical, never locks
--   G_West (west classroom) -> gW -> j1 -> jS -> j2                   lockable
--   jN is a dead end; j1 / j2 are tees; jS is a straight joint.
local function hallwaySlice(): Layout
	return {
		id = L1,
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

-- Rooms around a chase at every distance that matters to adjacentZones (no tiling needed for that query).
local function adjacencyLayout(): Layout
	return {
		id = L1,
		height = 14,
		acoustic = "Room",
		ambience = "DroneHallways",
		entry = "R_Touch",
		exit = "R_Touch",
		rooms = {
			{ id = "R_Touch", kind = "Classroom", rect = R(0, 10, 10, 20) }, -- shares the chase's west wall
			{ id = "C", kind = "Chase", rect = R(10, 10, 5, 20) },
			{ id = "R_Gap", kind = "Office", rect = R(15.8, 12, 5, 6) }, -- 0.8 studs east of the chase
			{ id = "R_Far", kind = "Office", rect = R(16.5, 20, 5, 5) }, -- 1.5 studs east: too far
			{ id = "R_EastLow", kind = "Office", rect = R(15, 26, 5, 4) }, -- shares the south end of C's east wall
			{ id = "R_Corner", kind = "Storage", rect = R(15, 30, 5, 5) }, -- meets C only at a corner
			{ id = "R_North", kind = "Corridor", rect = R(8, 5, 10, 5) }, -- shares the chase's north wall
			{ id = "C2", kind = "Chase", rect = R(10, 30, 5, 10) }, -- a second chase continuing south
			{ id = "R_South", kind = "Storage", rect = R(10, 40, 5, 5) }, -- beyond C2's south wall
			{ id = "R_Open", kind = "Gym", rect = R(45, 45, 20, 10) }, -- far away, no chase
		},
		doors = {},
		anchors = {},
		triggers = {},
	}
end

local function room(layoutId: string, roomId: string): string
	return ZoneGraph.roomNodeId(layoutId, roomId)
end

local function vent(layoutId: string, nodeId: string): string
	return ZoneGraph.ventNodeId(layoutId, nodeId)
end

local function countKeys(map: { [string]: any }): number
	local n = 0
	for _ in map do
		n += 1
	end
	return n
end

local function findEdge(graph: Graph, portalId: string): Types.ZoneEdge?
	for _, edge in graph.edges do
		if edge.portalId == portalId then
			return edge
		end
	end
	return nil
end

local function pathText(path: { string }?): string
	return if path then table.concat(path, " > ") else "(none)"
end

local function sameList(t: Expect, actual: { string }, expected: { string }, what: string)
	t.eq(table.concat(actual, ","), table.concat(expected, ","), what)
end

-- Real layouts, loaded only when their modules exist (other agents may still be writing them).
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
-- Specs
--------------------------------------------------------------------------------

return {
	["ids follow the room:/vent:/duct: formats"] = function(t: Expect)
		t.eq(ZoneGraph.roomNodeId("Level2_ScienceHall", "L2_Lab"), "room:Level2_ScienceHall:L2_Lab")
		t.eq(ZoneGraph.ventNodeId("Level2_ScienceHall", "J01"), "vent:Level2_ScienceHall:J01")
		t.eq(ZoneGraph.segmentId("a", "b"), "a-b")
		t.eq(ZoneGraph.ductPortalId("a", "b"), "duct:a-b")
	end,

	["nodes: every room and vent node, centred in world space"] = function(t: Expect)
		local graph = ZoneGraph.build({ basementSlice(), hallwaySlice() })
		t.eq(countKeys(graph.nodes), 2 + 6 + 7, "rooms of both layouts + vent nodes")
		local hall = graph.nodes[room(L1, "S_Hall")]
		t.truthy(hall, "hall node")
		t.eq(hall.kind, "Room")
		t.eq(hall.layoutId, L1)
		t.eq(hall.roomKind, "Corridor")
		t.near((hall.center - Vector3.new(204, 18, 80)).Magnitude, 0, 1e-6, "room centre on its floor, world space")
		local j2 = graph.nodes[vent(L1, "j2")]
		t.eq(j2.kind, "VentNode")
		t.eq(j2.roomKind, nil)
		t.near(
			(j2.center - Vector3.new(202.5, 18 + WorldConfig.VentCenterHeight, 59)).Magnitude,
			0,
			1e-6,
			"duct centre"
		)
		local spawn = graph.nodes[room(L0, "B_Spawn")]
		t.near((spawn.center - Vector3.new(204, 0, 80)).Magnitude, 0, 1e-6, "basement room centre")
		for id, _ in graph.nodes do
			t.truthy(graph.adjacency[id], "adjacency list for " .. id)
		end
	end,

	["edges: doors, grates, ducts and stairs with the right kinds and portal ids"] = function(t: Expect)
		local graph = ZoneGraph.build({ basementSlice(), hallwaySlice() })
		local expected: { { string } } = {
			{ "D_B", "Airlock", room(L0, "B_Spawn"), room(L0, "L0_AirlockEast") },
			{ "D_Air", "Airlock", room(L1, "L1_AirlockEast"), room(L1, "S_Hall") },
			{ "D_Gate", "Gate", room(L1, "S_Hall"), room(L1, "S_East") },
			{ "D_West", "Door", room(L1, "S_Hall"), room(L1, "S_West") },
			{ "D_Ajar", "Door", room(L1, "S_Store"), room(L1, "L1_AirlockEast") },
			{ "G_West", "Grate", room(L1, "S_West"), vent(L1, "gW") },
			{ "G_East", "Grate", room(L1, "S_East"), vent(L1, "gE") },
			{ "G_Hall", "Grate", room(L1, "S_Hall"), vent(L1, "gH") },
			{ "duct:gW-j1", "Duct", vent(L1, "gW"), vent(L1, "j1") },
			{ "duct:j1-jN", "Duct", vent(L1, "j1"), vent(L1, "jN") },
			{ "duct:j1-jS", "Duct", vent(L1, "j1"), vent(L1, "jS") },
			{ "duct:jS-j2", "Duct", vent(L1, "jS"), vent(L1, "j2") },
			{ "duct:j2-gE", "Duct", vent(L1, "j2"), vent(L1, "gE") },
			{ "duct:j2-gH", "Duct", vent(L1, "j2"), vent(L1, "gH") },
			{ "Stairwell_0_1", "Stair", room(L0, "L0_AirlockEast"), room(L1, "L1_AirlockEast") },
		}
		t.eq(#graph.edges, #expected, "edge count (the boarded door has no edge)")
		for i, row in expected do
			local edge = graph.edges[i]
			t.eq(edge.portalId, row[1], "edge " .. i .. " portal")
			t.eq(edge.kind, row[2], row[1] .. " kind")
			t.eq(edge.a, row[3], row[1] .. " a")
			t.eq(edge.b, row[4], row[1] .. " b")
			t.truthy(edge.length > 0, row[1] .. " has a length")
		end
		t.falsy(findEdge(graph, "D_Board"), "boarded doors never connect")
		-- Stairwell_1_2 needs Level2, which is not in this graph
		t.falsy(findEdge(graph, "Stairwell_1_2"), "stairs only join layouts that are both present")
		-- adjacency lists both ends, in edge order
		local hallEdges: { string } = {}
		for _, edge in graph.adjacency[room(L1, "S_Hall")] do
			table.insert(hallEdges, edge.portalId)
		end
		sameList(t, hallEdges, { "D_Air", "D_Gate", "D_West", "G_Hall" }, "hall adjacency")
	end,

	["edge lengths run through the portal point"] = function(t: Expect)
		local graph = ZoneGraph.build({ basementSlice(), hallwaySlice() })
		local air = findEdge(graph, "D_Air")
		local gate = findEdge(graph, "D_Gate")
		local grate = findEdge(graph, "G_Hall")
		local duct = findEdge(graph, "duct:j2-gH")
		local stair = findEdge(graph, "Stairwell_0_1")
		assert(air and gate and grate and duct and stair, "edges exist")
		t.near(air.length, 6 + 24, 1e-6, "airlock door: centre -> doorway -> centre")
		t.near(gate.length, math.sqrt(12 ^ 2 + 14 ^ 2) + math.sqrt(6.5 ^ 2 + 13 ^ 2), 1e-6, "gate")
		t.near(grate.length, math.sqrt(1.5 ^ 2 + 2 ^ 2 + 14 ^ 2), 1e-6, "grate: room centre -> opening")
		t.near(duct.length, 7, 1e-6, "duct: node to node")
		t.near(stair.length, 6 + 18 * math.sqrt(1 + 1.6 ^ 2) + 6, 1e-6, "stair: rooms -> tower -> walked climb")
	end,

	["reachability respects the blocked set"] = function(t: Expect)
		local graph = ZoneGraph.build({ basementSlice(), hallwaySlice() })
		local entry = room(L1, "L1_AirlockEast")
		local open = ZoneGraph.reachable(graph, entry, {})
		t.truthy(open[entry], "includes the start")
		t.truthy(open[room(L1, "S_East")], "exit through the gate")
		t.truthy(open[room(L1, "S_Store")], "store through the ajar door")
		t.truthy(open[room(L0, "B_Spawn")], "reachability crosses stairwells")
		t.falsy(open[room(L1, "S_Chase")], "chases are never walked into")

		local sealed = ZoneGraph.reachable(graph, entry, { D_Gate = true, G_Hall = true, D_West = true, D_Ajar = true })
		t.truthy(sealed[room(L1, "S_Hall")], "hall still reachable")
		t.falsy(sealed[room(L1, "S_East")], "gate shut and both vent routes cut")
		t.falsy(sealed[room(L1, "S_Store")], "boarded door never lets anyone through")
		t.falsy(sealed[vent(L1, "gH")], "a blocked grate blocks its vent")

		local ducted = ZoneGraph.reachable(graph, entry, { D_Gate = true, ["duct:j2-gE"] = true })
		t.truthy(ducted[vent(L1, "j2")], "into the duct")
		t.falsy(ducted[room(L1, "S_East")], "a blocked duct segment cuts the route")

		t.eq(countKeys(ZoneGraph.reachable(graph, "room:Nowhere:Nothing", {})), 0, "unknown start reaches nothing")
	end,

	["shortest path prefers the shorter route and detours around blocks"] = function(t: Expect)
		local graph = ZoneGraph.build({ basementSlice(), hallwaySlice() })
		local entry, exit = room(L1, "L1_AirlockEast"), room(L1, "S_East")

		local path, length = ZoneGraph.shortestPath(graph, entry, exit, {})
		t.eq(pathText(path), pathText({ entry, room(L1, "S_Hall"), exit }), "through the gate")
		local gateRoute = (findEdge(graph, "D_Air") :: Types.ZoneEdge).length
			+ (findEdge(graph, "D_Gate") :: Types.ZoneEdge).length
		t.near(length, gateRoute, 1e-6, "length is the sum of its edges")

		local ventPath, ventLength = ZoneGraph.shortestPath(graph, entry, exit, { D_Gate = true })
		t.eq(
			pathText(ventPath),
			pathText({
				entry,
				room(L1, "S_Hall"),
				vent(L1, "gH"),
				vent(L1, "j2"),
				vent(L1, "gE"),
				exit,
			}),
			"gate shut: the critical vent"
		)
		local expected = 0
		for _, id in { "D_Air", "G_Hall", "duct:j2-gH", "duct:j2-gE", "G_East" } do
			expected += (findEdge(graph, id) :: Types.ZoneEdge).length
		end
		t.near(ventLength, expected, 1e-6, "vent route length")
		t.truthy(ventLength > length, "the detour is longer")

		local westPath = ZoneGraph.shortestPath(graph, entry, exit, { D_Gate = true, G_Hall = true })
		t.eq(
			pathText(westPath),
			pathText({
				entry,
				room(L1, "S_Hall"),
				room(L1, "S_West"),
				vent(L1, "gW"),
				vent(L1, "j1"),
				vent(L1, "jS"),
				vent(L1, "j2"),
				vent(L1, "gE"),
				exit,
			}),
			"hall grate shut: round through the west classroom"
		)

		local none, infinite = ZoneGraph.shortestPath(graph, entry, exit, { D_Gate = true, G_East = true })
		t.eq(none, nil, "no route")
		t.eq(infinite, math.huge, "no route has infinite length")

		local same, zero = ZoneGraph.shortestPath(graph, entry, entry, {})
		t.eq(pathText(same), entry, "a node reaches itself")
		t.eq(zero, 0)

		local across, _ = ZoneGraph.shortestPath(graph, room(L0, "B_Spawn"), exit, {})
		t.eq(
			pathText(across),
			pathText({ room(L0, "B_Spawn"), room(L0, "L0_AirlockEast"), entry, room(L1, "S_Hall"), exit }),
			"up the stairwell"
		)
	end,

	["level solvability: gates, lockable grates and the critical vent"] = function(t: Expect)
		local layout = hallwaySlice()
		local graph = ZoneGraph.build({ basementSlice(), layout })
		t.truthy(ZoneGraph.isLevelSolvable(graph, layout, {}), "nothing blocked")
		local worst = ZoneGraph.worstCaseBlocked(layout)
		t.truthy(worst.D_Gate, "worst case shuts the gate")
		t.truthy(worst.G_West, "worst case locks the lockable grate")
		t.falsy(worst.G_East, "critical grates never lock")
		t.falsy(worst.D_Air, "airlocks are not gates")
		t.truthy(ZoneGraph.isLevelSolvable(graph, layout, worst), "the critical vent bypasses the gate")
		t.falsy(ZoneGraph.isLevelSolvable(graph, layout, { D_Gate = true, G_East = true }), "no way into the exit")
		t.falsy(ZoneGraph.isLevelSolvable(graph, layout, { D_Gate = true, ["duct:j2-gE"] = true }), "duct cut")
		t.truthy(ZoneGraph.isLevelSolvable(graph, layout, { D_Gate = true, G_Hall = true }), "west grate route")
		t.falsy(
			ZoneGraph.isLevelSolvable(graph, layout, { D_Gate = true, G_Hall = true, G_West = true }),
			"every vent mouth shut"
		)
		t.falsy(ZoneGraph.isLevelSolvable(graph, layout, { D_Air = true }), "the arrival airlock sealed")
		local basement = basementSlice()
		t.truthy(ZoneGraph.isLevelSolvable(graph, basement, {}), "basement")
		local missing = hallwaySlice()
		missing.exit = "S_Nowhere"
		t.falsy(ZoneGraph.isLevelSolvable(graph, missing, {}), "a missing exit room is never solvable")
		local absent = ZoneGraph.build({ basement })
		t.falsy(ZoneGraph.isLevelSolvable(absent, layout, {}), "a layout missing from the graph is never solvable")
	end,

	["adjacent zones: rooms whose walls the duct's chase runs inside"] = function(t: Expect)
		local hall = hallwaySlice()
		local vents = hall.vents :: LayoutSchema.VentNetwork
		local byId: { [string]: LayoutSchema.VentNodeSpec } = {}
		for _, node in vents.nodes do
			byId[node.id] = node
		end
		-- j1-jS runs z 52..55.5 in a chase spanning z 40..66: S_Hall lies beyond the chase's south end wall, 10 studs
		-- past the duct, so only the classrooms either side of the chase hear it.
		sameList(t, ZoneGraph.adjacentZones(hall, byId.j1, byId.jS), { "S_West", "S_East" }, "hallway chase")
		sameList(t, ZoneGraph.adjacentZones(hall, byId.j2, byId.gH), { "S_Hall", "S_West", "S_East" }, "grate stub")

		local layout = adjacencyLayout()
		local function node(id: string, x: number, z: number): LayoutSchema.VentNodeSpec
			return { id = id, x = x, z = z }
		end
		sameList(
			t,
			ZoneGraph.adjacentZones(layout, node("a", 12.5, 12), node("b", 12.5, 28)),
			{ "R_Touch", "R_Gap", "R_EastLow", "R_North" },
			"touching or within 1 stud along a wall; never corners, far rooms or chases"
		)
		sameList(
			t,
			ZoneGraph.adjacentZones(layout, node("a", 12.5, 20), node("b", 12.5, 35)),
			{ "R_Touch", "R_Gap", "R_EastLow", "R_Corner" },
			"a duct through two chases collects the rooms of both, but not end rooms it stops short of"
		)
		sameList(
			t,
			ZoneGraph.adjacentZones(layout, node("a", 12.5, 12), node("b", 12.5, 38)),
			{ "R_Touch", "R_Gap", "R_EastLow", "R_Corner", "R_North", "R_South" },
			"a duct reaching both end walls hears the rooms beyond them"
		)
		-- A short stub at one end of a long chase: rooms beside the chase's far stretch are not adjacent to it.
		sameList(
			t,
			ZoneGraph.adjacentZones(layout, node("a", 12.5, 12), node("b", 12.5, 16)),
			{ "R_Touch", "R_Gap", "R_North" },
			"a stub only hears the rooms along its own stretch of the chase"
		)
		sameList(
			t,
			ZoneGraph.adjacentZones(layout, node("a", 12.5, 36), node("b", 12.5, 38)),
			{ "R_Corner", "R_South" },
			"a stub in the second chase"
		)
		-- The span reaches the duct's outer half-width plus AdjacentRange past each node, and no further.
		local reach = WorldConfig.VentBore / 2 + WorldConfig.VentShell + ZoneGraph.AdjacentRange
		local justIn = ZoneGraph.adjacentZones(layout, node("a", 12.5, 10 + reach - 0.05), node("b", 12.5, 16))
		local justOut = ZoneGraph.adjacentZones(layout, node("a", 12.5, 10 + reach + 0.05), node("b", 12.5, 16))
		t.truthy(table.find(justIn, "R_North") ~= nil, "end room within range of the capped end")
		t.falsy(table.find(justOut, "R_North") ~= nil, "end room out of range of the capped end")
		sameList(
			t,
			ZoneGraph.adjacentZones(layout, node("a", 50, 50), node("b", 60, 50)),
			{ "R_Open" },
			"outside any chase: the rooms around the duct itself"
		)
		local first = ZoneGraph.adjacentZones(layout, node("a", 12.5, 20), node("b", 12.5, 35))
		local reversed = ZoneGraph.adjacentZones(layout, node("b", 12.5, 35), node("a", 12.5, 20))
		sameList(t, reversed, first, "direction does not matter")
	end,

	["adjacent zones on the real layouts stay near their duct segment"] = function(t: Expect)
		local reach = WorldConfig.VentBore / 2 + WorldConfig.VentShell + ZoneGraph.AdjacentRange
		for _, layout in realLayouts() do
			local vents = layout.vents
			if not vents then
				continue
			end
			local rooms = LayoutSchema.indexRooms(layout)
			local nodes: { [string]: LayoutSchema.VentNodeSpec } = {}
			for _, n in vents.nodes do
				nodes[n.id] = n
			end
			for _, edge in vents.edges do
				local a, b = nodes[edge.a], nodes[edge.b]
				if not a or not b then
					continue
				end
				local x0, x1 = math.min(a.x, b.x), math.max(a.x, b.x)
				local z0, z1 = math.min(a.z, b.z), math.max(a.z, b.z)
				for _, id in ZoneGraph.adjacentZones(layout, a, b) do
					local r = rooms[id].rect
					local gx = math.max(0, x0 - (r.x + r.w), r.x - x1)
					local gz = math.max(0, z0 - (r.z + r.d), r.z - z1)
					-- across the chase a room sits at most one chase width away; along it, within reach
					t.truthy(
						math.min(gx, gz) <= reach + 1e-3 and math.max(gx, gz) <= 8,
						string.format(
							"%s duct %s-%s lists %s %.1f studs away",
							layout.id,
							edge.a,
							edge.b,
							id,
							math.max(gx, gz)
						)
					)
				end
			end
		end
	end,

	["build is deterministic"] = function(t: Expect)
		local a = ZoneGraph.build({ basementSlice(), hallwaySlice() })
		local b = ZoneGraph.build({ basementSlice(), hallwaySlice() })
		t.eq(#a.edges, #b.edges)
		for i, edge in a.edges do
			local other = b.edges[i]
			t.eq(other.portalId, edge.portalId, "edge order " .. i)
			t.eq(other.a, edge.a)
			t.eq(other.b, edge.b)
			t.eq(other.length, edge.length)
		end
		for id, node in a.nodes do
			t.truthy(b.nodes[id], id)
			t.eq(b.nodes[id].center, node.center, id .. " centre")
		end
		local pa, la = ZoneGraph.shortestPath(a, room(L0, "B_Spawn"), room(L1, "S_East"), { D_Gate = true })
		local pb, lb = ZoneGraph.shortestPath(b, room(L0, "B_Spawn"), room(L1, "S_East"), { D_Gate = true })
		t.eq(pathText(pa), pathText(pb), "same path")
		t.eq(la, lb, "same length")
	end,

	["real layouts: every school level is solvable, open and in the worst case"] = function(t: Expect)
		local layouts = realLayouts()
		if #layouts == 0 then
			return
		end
		local graph = ZoneGraph.build(layouts)
		local expectedNodes = 0
		local everyWorst: Types.BlockedSet = {}
		local byId: { [string]: Layout } = {}
		for _, layout in layouts do
			byId[layout.id] = layout
			expectedNodes += #layout.rooms + (if layout.vents then #layout.vents.nodes else 0)
			if layout.id == "Lobby" then
				continue
			end
			t.truthy(ZoneGraph.isLevelSolvable(graph, layout, {}), layout.id .. " solvable with nothing blocked")
			local worst = ZoneGraph.worstCaseBlocked(layout)
			t.truthy(
				ZoneGraph.isLevelSolvable(graph, layout, worst),
				layout.id .. " solvable with every gate shut and every lockable grate locked"
			)
			for id in worst do
				everyWorst[id] = true
			end
			local grates: { LayoutSchema.GrateSpec } = if layout.vents then layout.vents.grates else {}
			for _, grate in grates do
				local edge = findEdge(graph, grate.id)
				t.truthy(edge and edge.kind == "Grate", layout.id .. " grate edge " .. grate.id)
			end
		end
		t.eq(countKeys(graph.nodes), expectedNodes, "one node per room and vent node")
		for _, spec in WorldConfig.Stairwells do
			if byId[spec.from] and byId[spec.to] then
				local edge = findEdge(graph, spec.id)
				t.truthy(edge and edge.kind == "Stair", "stair edge " .. spec.id)
			end
		end
		local first, last = byId.Level0_Basement, byId.Level5_Roof
		if first and last then
			local start = room(first.id, first.entry)
			local goal = room(last.id, last.exit)
			t.truthy(ZoneGraph.reachable(graph, start, everyWorst)[goal], "basement spawn to the roof edge, worst case")
			local path = ZoneGraph.shortestPath(graph, start, goal, everyWorst)
			t.truthy(path, "a shortest escape route exists")
		end
	end,
}
