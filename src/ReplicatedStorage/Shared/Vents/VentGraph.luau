--!strict
-- VentGraph: one level's duct network as pure data, read from the instances VentShaftBuilder leaves in the level
-- (Workspace.School.<level>.Vents). Used by the server (VentNetworkService: entry, exit, the rail validator; the
-- Creature's vent chase) and by the client (VentController's rail cursor), so both sides agree on the same rail.
--
-- What it reads:
--   * the level's VentNodeRoot part: one Attachment per VentNode (tag VentNode; attrs NodeId, Links, LevelId) at the
--     duct centreline. A node's position is the root's CFrame composed with the attachment's (Attachment.WorldCFrame
--     is not maintained outside the engine). Links name the nodes a duct joins it to; only links to nodes that exist
--     are kept, and every link is made two-way (a duct joins both of its ends);
--   * one `Grate_<id>` Attachment per grate (attrs GrateId, NodeId, FacingZoneId, Lockable, CriticalPath) at the
--     opening's centre on the wall's centre plane, LookVector into the room. Its world CFrame is the grate's `wall`;
--     its `mouth` is the point on the rail just inside the room face, MouthOut (WallThickness / 2 + 0.3) studs along
--     the LookVector. The grate's node carries its id (Node.grateId, grateAtNode);
--   * the VentShaft-tagged duct floors (attr SegmentId "<a>-<b>", in the layout's edge order): `segments` maps both
--     orders of a linked pair ("<a>|<b>" and "<b>|<a>") to that SegmentId. A duct whose fittings meet end to end has
--     no floor part of its own, and so no segment entry.
--
-- The rail is every duct edge (node to node, straight) plus one mouth stub per grate (its node to its mouth). A
-- RailPoint names where on it a position projects: edge points have `a` < `b` (string order) and `t` in [0, 1]
-- measured from `a`; stub points have `b` = nil, `a` = the grate's node and `t` measured from the node toward the
-- mouth. Ties between equally near pieces (a node shared by several edges) resolve to the smallest "<a>|<b>" key, so
-- the answer is the same on every machine.
--
-- Built graphs are frozen (they are cached and shared): treat every Graph as read-only. Every function here also
-- works on a hand-built Graph table with just the contract's fields.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local VentShaftBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.VentShaftBuilder)
local ZoneGraph = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph)

local log = Log.new("VentGraph")

export type Node = { id: string, position: Vector3, links: { string }, grateId: string? }

export type Grate = {
	id: string,
	nodeId: string,
	facingZoneId: string,
	lockable: boolean,
	criticalPath: boolean,
	wall: CFrame, -- Grate_<id> attachment world CFrame: opening centre on the wall centre plane, LookVector into the room
	mouth: Vector3, -- point on the rail just inside the room face (wall + LookVector * (WallThickness/2 + 0.3))
}

export type Graph = {
	levelId: string,
	nodes: { [string]: Node },
	grates: { [string]: Grate },
	grateAtNode: { [string]: string }, -- nodeId -> grateId
	segments: { [string]: string }, -- "<a>|<b>" (both orders) -> VentShaft SegmentId
}

-- b == nil means the point lies on a grate mouth stub (node a -> that grate's mouth), t along it
export type RailPoint = { a: string, b: string?, t: number, position: Vector3, distance: number }

local W = Attributes.World
local Names = Instances.Names

local MOUTH_OUT = WorldConfig.WallThickness / 2 + 0.3
local TIE = 1e-9 -- distances this close count as equal (then the smaller key wins)
local DEGENERATE = 1e-12 -- squared segment length below which a segment is a point

local VentGraph = {}

VentGraph.MouthOut = MOUTH_OUT

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- The key `segments` (and RailPoint tie-breaking) uses for the ordered pair (a, b).
function VentGraph.pairKey(a: string, b: string?): string
	return a .. "|" .. (b or "")
end

local pairKey = VentGraph.pairKey

-- The point of segment p0 -> p1 nearest `q`, and its parameter t in [0, 1] from p0.
function VentGraph.closestOnSegment(p0: Vector3, p1: Vector3, q: Vector3): (number, Vector3)
	local d = p1 - p0
	local lengthSquared = d:Dot(d)
	if lengthSquared < DEGENERATE then
		return 0, p0
	end
	local t = math.clamp((q - p0):Dot(d) / lengthSquared, 0, 1)
	return t, p0 + d * t
end

local closestOnSegment = VentGraph.closestOnSegment

local function linked(graph: Graph, a: string, b: string): boolean
	local na, nb = graph.nodes[a], graph.nodes[b]
	if na == nil or nb == nil or a == b then
		return false
	end
	return table.find(na.links, b) ~= nil or table.find(nb.links, a) ~= nil
end

-- The level's VentNodeRoot: `levelRoot` itself when it is one, else <levelRoot>.Vents.VentNodeRoot, else the first
-- part of that name anywhere under `levelRoot`.
local function findNodeRoot(levelRoot: Instance): BasePart?
	if levelRoot:IsA("BasePart") and levelRoot.Name == VentShaftBuilder.RootName then
		return levelRoot
	end
	local vents = levelRoot:FindFirstChild(Names.Vents)
	local direct = vents and vents:FindFirstChild(VentShaftBuilder.RootName)
	if direct and direct:IsA("BasePart") then
		return direct
	end
	for _, descendant in levelRoot:GetDescendants() do
		if descendant.Name == VentShaftBuilder.RootName and descendant:IsA("BasePart") then
			return descendant
		end
	end
	return nil
end

-- Whether an instance's LevelId attribute (when it has one) names `levelId`.
local function onLevel(instance: Instance, levelId: string): boolean
	local value = instance:GetAttribute(W.LevelId)
	return type(value) ~= "string" or value == levelId
end

local function sortedKeys<V>(map: { [string]: V }): { string }
	local keys: { string } = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

-- The graph of `levelId` from its level model (Workspace.School.<levelId>, or any instance holding its Vents
-- folder, or the VentNodeRoot part itself). Nil when the level has no VentNodeRoot or no VentNodes.
function VentGraph.build(levelRoot: Instance, levelId: string): Graph?
	local root = findNodeRoot(levelRoot)
	if not root then
		return nil
	end
	local origin = root.CFrame
	local nodes: { [string]: Node } = {}
	local listed: { [string]: { string } } = {}
	local prefix = VentShaftBuilder.GratePrefix
	local grateAttachments: { Attachment } = {}

	for _, child in root:GetChildren() do
		if not child:IsA("Attachment") then
			continue
		end
		if not child:HasTag(Tags.VentNode) then
			if string.sub(child.Name, 1, #prefix) == prefix and child:GetAttribute(W.GrateId) ~= nil then
				table.insert(grateAttachments, child)
			end
			continue
		end
		if not onLevel(child, levelId) then
			continue
		end
		local id = child:GetAttribute(W.NodeId)
		if type(id) ~= "string" or id == "" then
			log.warn("%s: VentNode %s has no NodeId; skipped", levelId, child.Name)
			continue
		end
		if nodes[id] then
			log.warn("%s: duplicate VentNode %s; the first is kept", levelId, id)
			continue
		end
		nodes[id] = { id = id, position = (origin * child.CFrame).Position, links = {}, grateId = nil }
		listed[id] = Attributes.getList(child, W.Links)
	end
	if next(nodes) == nil then
		return nil
	end

	-- Links: the attribute's order, restricted to real nodes; then every link made two-way.
	local ids = sortedKeys(nodes)
	for _, id in ids do
		local node = nodes[id]
		for _, other in listed[id] do
			if other ~= id and nodes[other] ~= nil and table.find(node.links, other) == nil then
				table.insert(node.links, other)
			end
		end
	end
	for _, id in ids do
		for _, other in nodes[id].links do
			local back = nodes[other].links
			if table.find(back, id) == nil then
				table.insert(back, id)
			end
		end
	end

	-- Grates (the first grate attachment on a node owns it)
	local grates: { [string]: Grate } = {}
	local grateAtNode: { [string]: string } = {}
	for _, attachment in grateAttachments do
		if not onLevel(attachment, levelId) then
			continue
		end
		local grateId = attachment:GetAttribute(W.GrateId)
		local nodeId = attachment:GetAttribute(W.NodeId)
		if type(grateId) ~= "string" or grateId == "" or type(nodeId) ~= "string" then
			log.warn("%s: %s lacks GrateId / NodeId; skipped", levelId, attachment.Name)
			continue
		end
		local node = nodes[nodeId]
		if not node then
			log.warn("%s: grate %s sits on missing node %s; skipped", levelId, grateId, nodeId)
			continue
		end
		if grates[grateId] or grateAtNode[nodeId] then
			log.warn("%s: grate %s duplicates a grate id or node; skipped", levelId, grateId)
			continue
		end
		local wall = origin * attachment.CFrame
		grates[grateId] = {
			id = grateId,
			nodeId = nodeId,
			facingZoneId = Attributes.getString(attachment, W.FacingZoneId, ""),
			lockable = Attributes.getBool(attachment, W.Lockable, false),
			criticalPath = Attributes.getBool(attachment, W.CriticalPath, false),
			wall = wall,
			mouth = wall.Position + wall.LookVector * MOUTH_OUT,
		}
		grateAtNode[nodeId] = grateId
		node.grateId = grateId
	end

	-- Segments: the duct floors under the Vents folder, matched to linked pairs in either order.
	local present: { [string]: boolean } = {}
	local ductsRoot: Instance = root.Parent or levelRoot
	for _, descendant in ductsRoot:GetDescendants() do
		if descendant:IsA("BasePart") and descendant:HasTag(Tags.VentShaft) and onLevel(descendant, levelId) then
			local segmentId = descendant:GetAttribute(W.SegmentId)
			if type(segmentId) == "string" then
				present[segmentId] = true
			end
		end
	end
	local segments: { [string]: string } = {}
	for _, id in ids do
		for _, other in nodes[id].links do
			local forward, backward = ZoneGraph.segmentId(id, other), ZoneGraph.segmentId(other, id)
			local segmentId = if present[forward] then forward elseif present[backward] then backward else nil
			if segmentId then
				segments[pairKey(id, other)] = segmentId
			end
		end
	end

	for _, node in nodes do
		table.freeze(node.links)
		table.freeze(node)
	end
	for _, grate in grates do
		table.freeze(grate)
	end
	local graph: Graph = {
		levelId = levelId,
		nodes = table.freeze(nodes),
		grates = table.freeze(grates),
		grateAtNode = table.freeze(grateAtNode),
		segments = table.freeze(segments),
	}
	return table.freeze(graph)
end

--------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------

-- The VentShaft SegmentId of the duct between linked nodes `a` and `b` (either order), or nil.
function VentGraph.segmentId(graph: Graph, a: string, b: string): string?
	return graph.segments[pairKey(a, b)]
end

-- Straight-line length of the duct between `a` and `b`; math.huge when they are not linked.
function VentGraph.edgeLength(graph: Graph, a: string, b: string): number
	if not linked(graph, a, b) then
		return math.huge
	end
	return (graph.nodes[a].position - graph.nodes[b].position).Magnitude
end

-- The closest point on any duct edge or mouth stub to `position` (see the header for a / b / t). Nil when the graph
-- has no rail, or when the closest point is farther than `maxDistance`.
function VentGraph.nearest(graph: Graph, position: Vector3, maxDistance: number?): RailPoint?
	local best: RailPoint? = nil
	local bestKey = ""
	local function consider(a: string, b: string?, from: Vector3, to: Vector3)
		local t, point = closestOnSegment(from, to, position)
		local distance = (position - point).Magnitude
		local key = pairKey(a, b)
		local current = best
		if
			current == nil
			or distance < current.distance - TIE
			or (distance <= current.distance + TIE and key < bestKey)
		then
			best = { a = a, b = b, t = t, position = point, distance = distance }
			bestKey = key
		end
	end
	local nodes = graph.nodes
	for id, node in nodes do
		for _, other in node.links do
			local otherNode = nodes[other]
			if otherNode == nil or other == id then
				continue
			end
			-- each edge once: from its smaller end, or from whichever end lists it when only one does
			if id > other and table.find(otherNode.links, id) ~= nil then
				continue
			end
			if id < other then
				consider(id, other, node.position, otherNode.position)
			else
				consider(other, id, otherNode.position, node.position)
			end
		end
	end
	for _, grate in graph.grates do
		local node = nodes[grate.nodeId]
		if node then
			consider(grate.nodeId, nil, node.position, grate.mouth)
		end
	end
	local found = best
	if found and maxDistance ~= nil and found.distance > maxDistance then
		return nil
	end
	return found
end

-- The nodes `nodeId` is linked to (a fresh list; empty for an unknown node).
function VentGraph.neighbours(graph: Graph, nodeId: string): { string }
	local node = graph.nodes[nodeId]
	if not node then
		return {}
	end
	local out = table.clone(node.links)
	for id, other in graph.nodes do
		if id ~= nodeId and table.find(other.links, nodeId) ~= nil and table.find(out, id) == nil then
			table.insert(out, id)
		end
	end
	return out
end

-- The node nearest `position` in a straight line (ties: the smaller id), or nil for an empty graph.
function VentGraph.nearestNode(graph: Graph, position: Vector3): string?
	local bestId: string? = nil
	local bestDistance = math.huge
	for id, node in graph.nodes do
		local distance = (node.position - position).Magnitude
		local currentId = bestId
		if currentId == nil or distance < bestDistance - TIE or (distance <= bestDistance + TIE and id < currentId) then
			bestId = id
			bestDistance = distance
		end
	end
	return bestId
end

-- The world position of rail parameter `t` on edge a -> b (t from `a`), or on the mouth stub of the grate on node
-- `a` when `b` is nil. Nil when the edge or stub does not exist.
function VentGraph.pointAt(graph: Graph, a: string, b: string?, t: number): Vector3?
	local from = graph.nodes[a]
	if not from then
		return nil
	end
	local to: Vector3
	if b == nil then
		local grateId = graph.grateAtNode[a]
		local grate = if grateId then graph.grates[grateId] else nil
		if not grate then
			return nil
		end
		to = grate.mouth
	else
		if not linked(graph, a, b) then
			return nil
		end
		to = graph.nodes[b].position
	end
	return from.position:Lerp(to, math.clamp(t, 0, 1))
end

-- The grate whose mouth stub starts at `nodeId`, if any.
function VentGraph.grateOf(graph: Graph, nodeId: string): Grate?
	local grateId = graph.grateAtNode[nodeId]
	return if grateId then graph.grates[grateId] else nil
end

return table.freeze(VentGraph)
