--!strict
-- VentPathfinder. A*: on random small graphs its route is a real walk along ducts and as short as the shortest simple
-- path found by brute force (and none exists exactly when brute force finds none); blocked nodes are never entered
-- (the start is exempt, a blocked goal is unreachable); unknown nodes and from == to; equal-length routes resolve the
-- same way every time; on the real vent levels every pair matches an independent Dijkstra. Retreat: the walk starts
-- at `from`, follows ducts, has at most `hops` edges, moves strictly farther from the threat at every step (so it never
-- doubles back or revisits a node) and ends as far away as any such walk can (brute force), staying put when nothing
-- leads away.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)
local VentPathfinder = require(ReplicatedStorage.Shared.Vents.VentPathfinder)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Graph = VentGraph.Graph

local VENT_LEVELS: { Enums.LevelId } =
	{ "Level1_Hallways", "Level2_ScienceHall", "Level3_Gymnasium", "Level4_FloodedPool" }
local EPS = 1e-6

--------------------------------------------------------------------------------
-- Graphs
--------------------------------------------------------------------------------

local function emptyGraph(): Graph
	return { levelId = "Level1_Hallways", nodes = {}, grates = {}, grateAtNode = {}, segments = {} }
end

local function addNode(graph: Graph, id: string, position: Vector3)
	local nodes = graph.nodes :: { [string]: VentGraph.Node }
	nodes[id] = { id = id, position = position, links = {}, grateId = nil }
end

local function link(graph: Graph, a: string, b: string)
	local na, nb = graph.nodes[a], graph.nodes[b]
	if table.find(na.links, b) == nil then
		table.insert(na.links, b)
		table.insert(nb.links, a)
	end
end

-- `count` nodes scattered on a plane, each linked to one earlier node (a tree) plus `extra` random chords.
local function randomGraph(random: Random, count: number, extra: number, connected: boolean): Graph
	local graph = emptyGraph()
	for i = 1, count do
		addNode(
			graph,
			"n" .. i,
			Vector3.new(random:NextNumber(-40, 40), random:NextInteger(0, 1) * 4, random:NextNumber(-40, 40))
		)
	end
	for i = 2, count do
		if connected or random:NextNumber() < 0.7 then
			link(graph, "n" .. i, "n" .. random:NextInteger(1, i - 1))
		end
	end
	for _ = 1, extra do
		local a, b = random:NextInteger(1, count), random:NextInteger(1, count)
		if a ~= b then
			link(graph, "n" .. a, "n" .. b)
		end
	end
	return graph
end

local function ids(graph: Graph): { string }
	local out: { string } = {}
	for id in graph.nodes do
		table.insert(out, id)
	end
	table.sort(out)
	return out
end

local function walkLength(graph: Graph, walk: { string }): number
	local total = 0
	for i = 2, #walk do
		total += (graph.nodes[walk[i]].position - graph.nodes[walk[i - 1]].position).Magnitude
	end
	return total
end

local function isWalk(graph: Graph, walk: { string }): boolean
	for i = 2, #walk do
		if table.find(graph.nodes[walk[i - 1]].links, walk[i]) == nil then
			return false
		end
	end
	return true
end

-- The shortest simple path's length by exhaustive search (math.huge when there is none).
local function bruteShortest(graph: Graph, from: string, to: string, blocked: { [string]: boolean }?): number
	local best = math.huge
	local visited: { [string]: boolean } = { [from] = true }
	local function search(at: string, length: number)
		if length >= best then
			return
		end
		if at == to then
			best = length
			return
		end
		for _, other in graph.nodes[at].links do
			if visited[other] or (blocked and blocked[other]) then
				continue
			end
			visited[other] = true
			search(other, length + (graph.nodes[other].position - graph.nodes[at].position).Magnitude)
			visited[other] = nil
		end
	end
	search(from, 0)
	return best
end

-- Shortest distances from `from` to every node (plain O(V^2) Dijkstra).
local function dijkstra(graph: Graph, from: string): { [string]: number }
	local distance: { [string]: number } = { [from] = 0 }
	local done: { [string]: boolean } = {}
	while true do
		local current: string? = nil
		local best = math.huge
		for id, value in distance do
			if not done[id] and value < best then
				current, best = id, value
			end
		end
		if current == nil then
			break
		end
		done[current] = true
		local node = graph.nodes[current]
		for _, other in node.links do
			local through = best + (graph.nodes[other].position - node.position).Magnitude
			if through < (distance[other] or math.huge) then
				distance[other] = through
			end
		end
	end
	return distance
end

-- The farthest end distance any walk of at most `hops` edges can reach from `from` while every step leads away from
-- `awayFrom` (exhaustive).
local function bruteRetreat(graph: Graph, from: string, awayFrom: Vector3, hops: number): number
	local function away(id: string): number
		return (graph.nodes[id].position - awayFrom).Magnitude
	end
	local best = away(from)
	local function search(at: string, left: number)
		best = math.max(best, away(at))
		if left == 0 then
			return
		end
		for _, other in graph.nodes[at].links do
			if VentPathfinder.leadsAway(graph.nodes[at].position, graph.nodes[other].position, awayFrom) then
				search(other, left - 1)
			end
		end
	end
	search(from, hops)
	return best
end

local realGraphs: { [string]: Graph }? = nil

local function levelGraphs(): { [string]: Graph }
	local existing = realGraphs
	if existing then
		return existing
	end
	local host = Instance.new("Model")
	host.Name = "VentPathfinderSpec"
	local result = Builder.BuildAuthoritative({ parent = host :: Instance, layouts = VENT_LEVELS, yieldEvery = 0 })
	local graphs: { [string]: Graph } = {}
	for _, id in VENT_LEVELS do
		local graph = VentGraph.build(result.levels[id], id)
		assert(graph, id)
		graphs[id] = graph
	end
	realGraphs = graphs
	return graphs
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["A* is as short as brute force on random small graphs"] = function(t: Expect)
		local random = Random.new(4242)
		for round = 1, 40 do
			local graph = randomGraph(random, random:NextInteger(2, 9), random:NextInteger(0, 8), round % 3 ~= 0)
			local list = ids(graph)
			for _, from in list do
				for _, to in list do
					local route, cost = VentPathfinder.path(graph, from, to)
					local expected = bruteShortest(graph, from, to, nil)
					if expected == math.huge then
						t.eq(route, nil, string.format("round %d: %s -> %s has no route", round, from, to))
						t.eq(cost, math.huge)
						continue
					end
					assert(route, string.format("round %d: %s -> %s has a route", round, from, to))
					t.eq(route[1], from)
					t.eq(route[#route], to)
					t.truthy(isWalk(graph, route), "follows ducts")
					t.near(cost, walkLength(graph, route), EPS, "cost is the route's length")
					t.near(cost, expected, 1e-6, string.format("round %d: %s -> %s optimal", round, from, to))
				end
			end
		end
	end,

	["blocked nodes are never entered; the start is exempt, a blocked goal is unreachable"] = function(t: Expect)
		local random = Random.new(77)
		for round = 1, 40 do
			local graph = randomGraph(random, random:NextInteger(3, 9), random:NextInteger(1, 8), true)
			local list = ids(graph)
			local blocked: { [string]: boolean } = {}
			for _, id in list do
				if random:NextNumber() < 0.3 then
					blocked[id] = true
				end
			end
			for _, from in list do
				for _, to in list do
					local route, cost = VentPathfinder.path(graph, from, to, blocked)
					if from == to then
						t.truthy(route ~= nil and #route == 1 and cost == 0, "staying put is always fine")
						continue
					end
					if blocked[to] then
						t.eq(route, nil, "a blocked goal")
						continue
					end
					local expected = bruteShortest(graph, from, to, blocked)
					if expected == math.huge then
						t.eq(route, nil, string.format("round %d: walled off", round))
						continue
					end
					assert(route, "a route around the blocks")
					for i = 2, #route do
						t.falsy(blocked[route[i]], "never enters a blocked node")
					end
					t.near(cost, expected, 1e-6, "shortest around the blocks")
				end
			end
		end
	end,

	["unknown nodes, staying put, and fixed tie-breaking"] = function(t: Expect)
		local graph = emptyGraph()
		addNode(graph, "S", Vector3.new(0, 0, 0))
		addNode(graph, "L", Vector3.new(-5, 0, 5))
		addNode(graph, "R", Vector3.new(5, 0, 5))
		addNode(graph, "G", Vector3.new(0, 0, 10))
		link(graph, "S", "L")
		link(graph, "S", "R")
		link(graph, "L", "G")
		link(graph, "R", "G")
		local route, cost = VentPathfinder.path(graph, "S", "Nowhere")
		t.eq(route, nil)
		t.eq(cost, math.huge)
		route, cost = VentPathfinder.path(graph, "Nowhere", "S")
		t.eq(route, nil)
		t.eq(cost, math.huge)
		route, cost = VentPathfinder.path(graph, "S", "S")
		t.truthy(route ~= nil and route[1] == "S" and #route == 1)
		t.eq(cost, 0)
		local first = VentPathfinder.path(graph, "S", "G")
		assert(first, "a route")
		t.eq(#first, 3)
		for _ = 1, 5 do
			local again = VentPathfinder.path(graph, "S", "G")
			assert(again, "a route")
			t.eq(table.concat(again, ","), table.concat(first, ","), "equal routes resolve the same way")
		end
		local around = VentPathfinder.path(graph, "S", "G", { [first[2]] = true })
		assert(around, "the other side")
		t.truthy(around[2] ~= first[2], "blocking one side takes the other")
	end,

	["real levels: every route matches Dijkstra"] = function(t: Expect)
		for id, graph in levelGraphs() do
			local list = ids(graph)
			for _, from in list do
				local shortest = dijkstra(graph, from)
				for _, to in list do
					local route, cost = VentPathfinder.path(graph, from, to)
					local expected = shortest[to]
					if expected == nil then
						t.eq(route, nil, id .. " unreachable " .. to)
						continue
					end
					assert(route, string.format("%s: %s -> %s", id, from, to))
					t.truthy(isWalk(graph, route))
					t.near(cost, expected, 1e-4, string.format("%s: %s -> %s", id, from, to))
				end
			end
		end
	end,

	["leadsAway: farther at the end and never closer along the way"] = function(t: Expect)
		local threat = Vector3.new(3, 0, 0)
		t.falsy(VentPathfinder.leadsAway(Vector3.zero, Vector3.new(10, 0, 0), threat), "through the cloud")
		t.truthy(VentPathfinder.leadsAway(Vector3.new(4, 0, 0), Vector3.new(10, 0, 0), threat), "straight away")
		t.falsy(VentPathfinder.leadsAway(Vector3.new(10, 0, 0), Vector3.new(4, 0, 0), threat), "toward it")
		t.truthy(VentPathfinder.leadsAway(Vector3.new(3, 0, 0), Vector3.new(3, 0, 5), threat), "from on top of it")
		t.truthy(VentPathfinder.leadsAway(Vector3.new(4, 0, 0), Vector3.new(4, 0, 6), threat), "sideways off it")
		t.falsy(VentPathfinder.leadsAway(Vector3.new(4, 0, 0), Vector3.new(4, 0, 0), threat), "standing still")
	end,

	["retreat: away at every step, within hops, as far as any such walk"] = function(t: Expect)
		local random = Random.new(1337)
		for round = 1, 60 do
			local graph = randomGraph(random, random:NextInteger(1, 10), random:NextInteger(0, 10), true)
			local list = ids(graph)
			local from = list[random:NextInteger(1, #list)]
			local threat = graph.nodes[from].position
				+ Vector3.new(random:NextNumber(-12, 12), 0, random:NextNumber(-12, 12))
			local hops = random:NextInteger(0, 5)
			local walk = VentPathfinder.retreatPath(graph, from, threat, hops)
			t.truthy(#walk >= 1, "never empty for a known node")
			t.eq(walk[1], from, "starts where it is")
			t.truthy(#walk - 1 <= hops, string.format("round %d: %d edges for %d hops", round, #walk - 1, hops))
			t.truthy(isWalk(graph, walk), "follows ducts")
			local seen: { [string]: boolean } = {}
			for i, id in walk do
				t.falsy(seen[id], "never revisits")
				seen[id] = true
				if i > 1 then
					local previous = graph.nodes[walk[i - 1]].position
					local here = graph.nodes[id].position
					t.truthy((here - threat).Magnitude > (previous - threat).Magnitude, "every step ends farther away")
					-- sampled along the duct: never closer than where the step began
					for k = 1, 9 do
						local along = previous:Lerp(here, k / 10)
						t.truthy(
							(along - threat).Magnitude >= (previous - threat).Magnitude - 1e-9,
							"never closer along the way"
						)
					end
				end
			end
			local reached = (graph.nodes[walk[#walk]].position - threat).Magnitude
			t.near(reached, bruteRetreat(graph, from, threat, hops), 1e-6, "round " .. round .. " as far as possible")
		end
	end,

	["retreat: a dead end facing the threat stays put; zero hops stays; unknown nodes give nothing"] = function(
		t: Expect
	)
		local graph = emptyGraph()
		addNode(graph, "Dead", Vector3.new(0, 0, 0))
		addNode(graph, "Mid", Vector3.new(10, 0, 0))
		addNode(graph, "Far", Vector3.new(20, 0, 0))
		addNode(graph, "Side", Vector3.new(10, 0, 8))
		link(graph, "Dead", "Mid")
		link(graph, "Mid", "Far")
		link(graph, "Mid", "Side")
		-- the shatter between the dead end and the rest: backing off means staying in the dead end
		local cornered = VentPathfinder.retreatPath(graph, "Dead", Vector3.new(3, 0, 0), 4)
		t.eq(table.concat(cornered, ","), "Dead")
		local fleeing = VentPathfinder.retreatPath(graph, "Mid", Vector3.new(4, 0, 0), 4)
		t.eq(table.concat(fleeing, ","), "Mid,Far", "away down the run")
		local sideways = VentPathfinder.retreatPath(graph, "Mid", Vector3.new(25, 0, -10), 4)
		t.eq(table.concat(sideways, ","), "Mid,Dead", "the farthest end wins")
		t.eq(table.concat(VentPathfinder.retreatPath(graph, "Mid", Vector3.new(4, 0, 0), 0), ","), "Mid")
		t.eq(#VentPathfinder.retreatPath(graph, "Nowhere", Vector3.zero, 3), 0)
		local huge = VentPathfinder.retreatPath(graph, "Dead", Vector3.new(-1, 0, 0), math.huge)
		t.eq(huge[#huge], "Far", "an unbounded retreat stops where nothing leads farther")
	end,

	["retreat on the real levels stays on the rail and moves away"] = function(t: Expect)
		for id, graph in levelGraphs() do
			for _, from in ids(graph) do
				local threat = graph.nodes[from].position + Vector3.new(1, 0, 1)
				local walk = VentPathfinder.retreatPath(graph, from, threat, 3)
				t.eq(walk[1], from)
				t.truthy(#walk <= 4)
				t.truthy(isWalk(graph, walk), id .. " " .. from)
				t.near(
					(graph.nodes[walk[#walk]].position - threat).Magnitude,
					bruteRetreat(graph, from, threat, 3),
					1e-6,
					id .. " from " .. from
				)
			end
		end
	end,
}
