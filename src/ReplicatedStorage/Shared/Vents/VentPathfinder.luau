--!strict
-- VentPathfinder: routes over a VentGraph (PathfindingService's navmesh cannot see inside a 3.5-stud duct).
--
-- path(graph, from, to, blocked?) is A* over the duct edges with a BinaryHeap open list. An edge costs its
-- straight-line length (VentGraph.edgeLength), and the heuristic is the straight-line distance to `to`, which never
-- overestimates (it is consistent), so the first time `to` leaves the open list its route is a shortest one. Edges
-- are two-way. `blocked` names nodes the route may not enter (a closed grate's node, a node the Creature must avoid);
-- the start node is always allowed (you are already there), a blocked goal is unreachable. Returns the node list
-- from `from` to `to` inclusive and its length, or (nil, math.huge) when there is no route or a node is unknown;
-- from == to is ({from}, 0). Neighbours are expanded in a fixed order (sorted ids, then link order) and the heap is
-- stable, so equal-length routes resolve the same way on every machine.
--
-- retreatPath(graph, from, awayFrom, hops) is where a stunned Creature backs off to: the walk of up to `hops` edges
-- from `from` that ends farthest (straight-line) from `awayFrom` (a flask's shatter point), never doubling back:
-- every step must lead away (leadsAway): its far node strictly farther from `awayFrom`, and the duct heading away
-- from it from the very start, so the distance never shrinks along the way (a step through the cloud to the far
-- side of the shatter is refused, even when it ends farther off). So it can neither turn back toward the threat nor
-- revisit a node. Those steps form an acyclic graph, so a breadth-first sweep finds every node such a walk can reach
-- within `hops` edges; the farthest one wins (ties: fewer edges, then the sweep's fixed order) and the sweep's tree
-- gives the walk. Returns the node list starting at `from` ({from} alone when no step leads away, a Creature cornered
-- in a dead end; {} for an unknown node).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BinaryHeap = require(ReplicatedStorage.Shared.Util.BinaryHeap)

local VentGraph = require(script.Parent.VentGraph)

type Graph = VentGraph.Graph

local TIE = 1e-9

local VentPathfinder = {}

-- Two-way adjacency (a link either end lists is a duct both ways) in a fixed order: built by walking the node ids in
-- sorted order and each node's links in their own order, so it is the same on every machine.
function VentPathfinder.adjacency(graph: Graph): { [string]: { string } }
	local ids: { string } = {}
	for id in graph.nodes do
		table.insert(ids, id)
	end
	table.sort(ids)
	local out: { [string]: { string } } = {}
	for _, id in ids do
		out[id] = {}
	end
	for _, id in ids do
		for _, other in graph.nodes[id].links do
			if other == id or out[other] == nil then
				continue
			end
			if table.find(out[id], other) == nil then
				table.insert(out[id], other)
			end
			if table.find(out[other], id) == nil then
				table.insert(out[other], id)
			end
		end
	end
	return out
end

local function distanceBetween(graph: Graph, a: string, b: string): number
	return (graph.nodes[a].position - graph.nodes[b].position).Magnitude
end

-- A* (see the header).
function VentPathfinder.path(
	graph: Graph,
	from: string,
	to: string,
	blocked: { [string]: boolean }?
): ({ string }?, number)
	local nodes = graph.nodes
	local goal = nodes[to]
	if nodes[from] == nil or goal == nil then
		return nil, math.huge
	end
	if from == to then
		return { from }, 0
	end
	if blocked and blocked[to] then
		return nil, math.huge
	end
	local adjacency = VentPathfinder.adjacency(graph)
	local cost: { [string]: number } = { [from] = 0 }
	local cameFrom: { [string]: string } = {}
	local closed: { [string]: boolean } = {}
	local open: BinaryHeap.Heap<string> = BinaryHeap.new()
	open:push(from, distanceBetween(graph, from, to))
	while open:size() > 0 do
		local current = open:pop()
		if current == nil then
			break
		end
		if closed[current] then
			continue
		end
		if current == to then
			local route: { string } = { to }
			local cursor = to
			while cursor ~= from do
				cursor = cameFrom[cursor]
				table.insert(route, 1, cursor)
			end
			return route, cost[to]
		end
		closed[current] = true
		local here = cost[current]
		for _, nextId in adjacency[current] do
			if closed[nextId] or (blocked and blocked[nextId]) then
				continue
			end
			local through = here + distanceBetween(graph, current, nextId)
			local known = cost[nextId]
			if known == nil or through < known - TIE then
				cost[nextId] = through
				cameFrom[nextId] = current
				open:push(nextId, through + (nodes[nextId].position - goal.position).Magnitude)
			end
		end
	end
	return nil, math.huge
end

-- Whether moving along a straight duct from `from` to `to` leads away from `awayFrom`: `to` is strictly farther,
-- and the distance does not shrink anywhere along the duct (it grows from the start: distance to a point is convex
-- along a segment, so a non-negative start is enough).
function VentPathfinder.leadsAway(from: Vector3, to: Vector3, awayFrom: Vector3): boolean
	return (to - awayFrom).Magnitude > (from - awayFrom).Magnitude and (to - from):Dot(from - awayFrom) >= 0
end

-- The retreat walk (see the header).
function VentPathfinder.retreatPath(graph: Graph, from: string, awayFrom: Vector3, hops: number): { string }
	local nodes = graph.nodes
	if nodes[from] == nil then
		return {}
	end
	-- the sweep ends on its own once no step leads farther away, so a huge `hops` is fine
	local limit = if hops == hops and hops > 0 then math.floor(hops) else 0
	local adjacency = VentPathfinder.adjacency(graph)
	local away: { [string]: number } = {}
	for id, node in nodes do
		away[id] = (node.position - awayFrom).Magnitude
	end
	local parent: { [string]: string } = {}
	local reached: { [string]: boolean } = { [from] = true }
	local best, bestDistance = from, away[from]
	local frontier: { string } = { from }
	for _ = 1, limit do
		local nextFrontier: { string } = {}
		for _, id in frontier do
			for _, other in adjacency[id] do
				if
					reached[other] or not VentPathfinder.leadsAway(nodes[id].position, nodes[other].position, awayFrom)
				then
					continue
				end
				reached[other] = true
				parent[other] = id
				table.insert(nextFrontier, other)
				if away[other] > bestDistance + TIE then
					best, bestDistance = other, away[other]
				end
			end
		end
		if #nextFrontier == 0 then
			break
		end
		frontier = nextFrontier
	end
	local walk: { string } = { best }
	local cursor = best
	while cursor ~= from do
		cursor = parent[cursor]
		table.insert(walk, 1, cursor)
	end
	return walk
end

return table.freeze(VentPathfinder)
