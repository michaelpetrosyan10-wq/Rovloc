--!strict
-- TunnelRules: the measures and the rules of a tunnel floor (a layout TunnelPlanner made), as pure maths over the
-- layout data. TunnelPlanner measures its candidates with it, LayoutSchema.validate asserts the rules on every tunnel
-- layout, and the export derives the runtime's teleport points from it. It never requires LayoutSchema (LayoutSchema
-- requires it), so it works on the layout's plain tables and declares the tunnel data types LayoutSchema re-exports.
--
-- The walk graph: every passable door's centre on its wall (Boarded doors and Gates excluded) and the entry's arrival
-- point, joined in straight lines across each room (rooms are convex rects). Crawlways are rooms of kind Crawlway: "on
-- foot" leaves every door into one out; "crawling" keeps them and walks them at CrouchSpeed.
--
-- Rules (every number from TunnelRules.Defaults unless the layout's tunnels.rules overrides it):
--   connected   every keep-room and every stair vestibule is reachable on foot from the entry without a crawlway;
--   loops       every junction of the tunnel graph (three or more tunnel arms; a door off a corridor into a keep-room
--               is not a tunnel arm) lies on a loop of at most maxLoop studs (crawlways never count);
--   deadEnds    at most deadEndCount dead ends, each at most deadEndLength studs from its junction;
--   crossing    the shortest walk from the entry to the farthest exit vestibule is crossing[1]..crossing[2] studs;
--               with the crawlways (walked at CrouchSpeed) it still takes at least crawlCrossingSeconds;
--   crawlways   crawlways[1]..crawlways[2] of them, each at most crawlLength studs long with crawlHeight head room
--               at its mouths; a crawlway mouth within crawlReach studs walked of every tunnel point;
--   hides       a hiding spot (Locker, Barrel, Cabinet) within hideReach studs walked of every tunnel point and
--               within objectiveHideReach of every objective place (ObjectivePlaces' stations, locks and items);
--   regions     regions[1]..regions[2] regions with distinct names; every tunnel room in one; a junction plate at
--               every junction.

local TunnelRules = {}

--------------------------------------------------------------------------------
-- Types (LayoutSchema re-exports them)
--------------------------------------------------------------------------------

-- A node of the tunnel graph: a grid crossing the tunnels pass through, a keep-room's port (its door) or a dead end.
export type TunnelNodeKind = "Junction" | "Turn" | "Pass" | "End" | "Port"

export type TunnelNode = {
	id: string,
	x: number,
	z: number,
	kind: TunnelNodeKind,
	region: string?,
	room: string?, -- the room that holds the node's core square (a port: its keep-room)
	plate: string?, -- a junction's plate text ("J-07")
}

-- An edge of the tunnel graph: a corridor between two nodes, a crawlway, or the walk across a keep-room between two of
-- its ports.
export type TunnelEdgeKind = "Tunnel" | "Gallery" | "Crawlway" | "Room"

export type TunnelEdge = {
	a: string,
	b: string,
	length: number,
	kind: TunnelEdgeKind,
	room: string?,
}

-- A straight stretch of tunnel centreline inside one room (level-local XZ), for samples and teleport points.
export type TunnelSegment = {
	room: string,
	kind: "Tunnel" | "Gallery" | "Crawlway" | "Alcove",
	region: string,
	ax: number,
	az: number,
	bx: number,
	bz: number,
	width: number,
	height: number,
}

-- One region's identity: its name (stencilled at its entrances), pipe colours, graffiti and grime.
export type TunnelRegion = {
	id: string,
	name: string,
	pipe: Color3, -- service pipe paint
	band: Color3, -- the colour bands on the pipes
	grime: Color3, -- wall grime tint
	paint: Color3, -- graffiti paint
	graffiti: { string },
	wall: string?, -- palette keys of its tunnels (nil: the style's)
	floor: string?,
	wet: boolean?, -- puddles and drain grates
	medium: string?, -- what its mains carry, stencilled on their markers ("STEAM")
	rooms: { string },
	junctions: { string },
}

-- A landmark a builder paints or places: a junction plate, a region stencil, graffiti (arrows, tags, lore, tallies) or
-- a unique prop. `pos` is level-local, on the wall face (props: on the floor); `normal` points into the room.
export type LandmarkKind = "JunctionPlate" | "RegionSign" | "Arrow" | "Tag" | "Lore" | "Tally" | "Prop"

export type Landmark = {
	id: string,
	kind: LandmarkKind,
	region: string,
	room: string,
	pos: Vector3,
	normal: Vector3,
	text: string,
	width: number,
	height: number,
	yaw: number?, -- arrows: degrees the arrow points, measured in the wall plane (0 right, 90 up)
}

export type RuleSpec = {
	maxLoop: number,
	deadEndCount: number,
	deadEndLength: number,
	crossing: { number },
	crawlCrossingSeconds: number,
	crawlways: { number },
	crawlLength: number,
	crawlHeight: number,
	crawlReach: number,
	hideReach: number,
	objectiveHideReach: number,
	regions: { number },
}

export type TunnelData = {
	seed: number,
	entry: string, -- the entry room
	exits: { string }, -- the exit vestibules (route candidates)
	keepRooms: { string },
	regions: { TunnelRegion },
	nodes: { TunnelNode },
	edges: { TunnelEdge },
	segments: { TunnelSegment },
	landmarks: { Landmark },
	roomRegion: { [string]: string },
	rules: RuleSpec,
	stats: { [string]: number }?, -- the planner's own counts (runs, junctions, crawlways, hides, ...)
}

-- What TunnelRules needs of a layout (a LayoutSchema.LevelLayout fits).
type Rect = { x: number, z: number, w: number, d: number }
type RoomLike = { id: string, kind: string, rect: Rect, height: number? }
type DoorLike = { id: string, kind: string, rooms: { string }, at: number, width: number?, height: number? }
type AnchorLike = { id: string, kind: string, room: string, pos: Vector3 }
type VentNodeLike = { id: string, x: number, z: number }
type VentEdgeLike = { a: string, b: string }
type GrateLike = { id: string, node: string, room: string, lockable: boolean }
type VentsLike = { nodes: { VentNodeLike }, edges: { VentEdgeLike }, grates: { GrateLike } }
export type LayoutLike = {
	id: string,
	height: number,
	entry: string,
	rooms: { RoomLike },
	doors: { DoorLike },
	anchors: { AnchorLike },
	vents: VentsLike?,
	tunnels: TunnelData?,
}

export type Measures = {
	length: number, -- studs of tunnel and gallery centreline
	galleryLength: number,
	junctions: number,
	deadEnds: { { node: string, length: number } },
	loops: { [string]: number }, -- junction id -> its shortest loop
	longestLoop: number,
	crossing: number, -- studs on foot, entry -> farthest exit vestibule door
	crossingTo: { [string]: number }, -- per exit vestibule
	crawlCrossingSeconds: number,
	crawlways: number,
	crawlReach: number, -- worst tunnel point -> nearest crawlway mouth (on foot)
	hideReach: number, -- worst tunnel point -> nearest hiding spot (on foot)
	unreachable: { string }, -- keep-rooms / vestibules the entry cannot reach on foot
	samples: number,
}

--------------------------------------------------------------------------------
-- Numbers
--------------------------------------------------------------------------------

TunnelRules.WalkSpeed = 11
TunnelRules.CrouchSpeed = 5.5
TunnelRules.VentSpeed = 4.5 -- GameConfig.VentCrawlSpeed: the always-open vents are walked at this pace when timed
-- The web player's crouched body (feet to crown, web/src/engine/physics.js CrouchHeight); crawlways give it 0.6 more.
TunnelRules.CrouchHeight = 3.7
TunnelRules.CrawlClearance = TunnelRules.CrouchHeight + 0.6
-- The Creature stands upright under this much head room and hunches under less (its hunched height is 9).
TunnelRules.StandClearance = 12.5
TunnelRules.SampleStep = 2
TunnelRules.HideKinds = table.freeze({ Locker = true, Barrel = true, Cabinet = true })

TunnelRules.Defaults = table.freeze({
	maxLoop = 200,
	deadEndCount = 8,
	deadEndLength = 25,
	crossing = table.freeze({ 1100, 1500 }),
	crawlCrossingSeconds = 40,
	crawlways = table.freeze({ 3, 6 }),
	crawlLength = 20,
	crawlHeight = TunnelRules.CrawlClearance,
	crawlReach = 60,
	hideReach = 30,
	objectiveHideReach = 25,
	regions = table.freeze({ 4, 6 }),
} :: RuleSpec)

local EPS = 1e-3
local INF = math.huge

--------------------------------------------------------------------------------
-- Small geometry
--------------------------------------------------------------------------------

type Edge = { axis: "X" | "Z", coord: number, from: number, to: number }

local function sharedEdge(a: Rect, b: Rect): Edge?
	if math.abs(a.x + a.w - b.x) < EPS or math.abs(b.x + b.w - a.x) < EPS then
		local coord = if math.abs(a.x + a.w - b.x) < EPS then b.x else a.x
		local from, to = math.max(a.z, b.z), math.min(a.z + a.d, b.z + b.d)
		if to - from > EPS then
			return { axis = "X", coord = coord, from = from, to = to }
		end
	end
	if math.abs(a.z + a.d - b.z) < EPS or math.abs(b.z + b.d - a.z) < EPS then
		local coord = if math.abs(a.z + a.d - b.z) < EPS then b.z else a.z
		local from, to = math.max(a.x, b.x), math.min(a.x + a.w, b.x + b.w)
		if to - from > EPS then
			return { axis = "Z", coord = coord, from = from, to = to }
		end
	end
	return nil
end
TunnelRules.sharedEdge = sharedEdge

-- The level-local XZ point a door opens at (its centre on the shared wall).
function TunnelRules.doorPoint(a: Rect, b: Rect, at: number): Vector2?
	local edge = sharedEdge(a, b)
	if not edge then
		return nil
	end
	return if edge.axis == "X" then Vector2.new(edge.coord, at) else Vector2.new(at, edge.coord)
end

function TunnelRules.rules(layout: LayoutLike): RuleSpec
	local tunnels = layout.tunnels
	return if tunnels then tunnels.rules else TunnelRules.Defaults
end

--------------------------------------------------------------------------------
-- A binary heap of (distance, node index)
--------------------------------------------------------------------------------

type Heap = { d: { number }, n: { number }, size: number }

local function heapNew(): Heap
	return { d = {}, n = {}, size = 0 }
end

local function heapPush(h: Heap, dist: number, node: number)
	h.size += 1
	local i = h.size
	h.d[i], h.n[i] = dist, node
	while i > 1 do
		local p = i // 2
		if h.d[p] <= h.d[i] then
			break
		end
		h.d[p], h.d[i] = h.d[i], h.d[p]
		h.n[p], h.n[i] = h.n[i], h.n[p]
		i = p
	end
end

local function heapPop(h: Heap): (number, number)
	local dist, node = h.d[1], h.n[1]
	local last = h.size
	h.d[1], h.n[1] = h.d[last], h.n[last]
	h.d[last], h.n[last] = nil :: any, nil :: any
	h.size -= 1
	local i = 1
	while true do
		local l, r = i * 2, i * 2 + 1
		local m = i
		if l <= h.size and h.d[l] < h.d[m] then
			m = l
		end
		if r <= h.size and h.d[r] < h.d[m] then
			m = r
		end
		if m == i then
			break
		end
		h.d[m], h.d[i] = h.d[i], h.d[m]
		h.n[m], h.n[i] = h.n[i], h.n[m]
		i = m
	end
	return dist, node
end

--------------------------------------------------------------------------------
-- The walk graph
--------------------------------------------------------------------------------

export type WalkGraph = {
	pos: { Vector2 },
	links: { { { to: number, cost: number } } },
	members: { [string]: { number } }, -- room id -> its door nodes
	doorNode: { [string]: number },
	crawlMouths: { number }, -- door nodes opening into a crawlway
	rooms: { [string]: RoomLike },
}

local WALK_DOORS: { [string]: boolean } = { Doorway = true, Door = true, Ajar = true, Airlock = true, RoofDoor = true }

-- Grates a HatchValve keeps shut (ObjectivePlaces' rule: its grate is no way through until the objective opens it).
local function hatchShut(layout: LayoutLike, vents: VentsLike): { [string]: boolean }
	local nodes: { [string]: VentNodeLike } = {}
	for _, node in vents.nodes do
		nodes[node.id] = node
	end
	local out: { [string]: boolean } = {}
	for _, anchor in layout.anchors do
		if anchor.kind ~= "HatchValve" then
			continue
		end
		for _, grate in vents.grates do
			local node = nodes[grate.node]
			if node and math.abs(node.x - anchor.pos.X) < 2.5 and math.abs(node.z - anchor.pos.Z) < 1.5 then
				out[grate.id] = true
			end
		end
	end
	return out
end

-- The walk graph of `layout`. `crawl`: keep the crawlway doors (their links cost studs x WalkSpeed / CrouchSpeed when
-- `timed`); otherwise crawlways are shut. The vents a squad can always use (grates that never lock, none a hatch
-- keeps shut) are walked too, whatever `crawl` says: a floor's script may make one the only way on (Level 1's gate
-- bypass); timed, their ducts cost studs x WalkSpeed / VentSpeed.
function TunnelRules.walkGraph(layout: LayoutLike, crawl: boolean, timed: boolean?): WalkGraph
	local rooms: { [string]: RoomLike } = {}
	for _, room in layout.rooms do
		rooms[room.id] = room
	end
	local g: WalkGraph = { pos = {}, links = {}, members = {}, doorNode = {}, crawlMouths = {}, rooms = rooms }
	for _, door in layout.doors do
		if not WALK_DOORS[door.kind] or #door.rooms ~= 2 then
			continue
		end
		local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
		if not a or not b then
			continue
		end
		local crawlA, crawlB = a.kind == "Crawlway", b.kind == "Crawlway"
		if (crawlA or crawlB) and not crawl then
			continue
		end
		local p = TunnelRules.doorPoint(a.rect, b.rect, door.at)
		if not p then
			continue
		end
		table.insert(g.pos, p)
		table.insert(g.links, {})
		local index = #g.pos
		g.doorNode[door.id] = index
		for _, id in door.rooms do
			g.members[id] = g.members[id] or {}
			table.insert(g.members[id], index)
		end
		if crawlA or crawlB then
			table.insert(g.crawlMouths, index)
		end
	end
	-- the always-open vents: a node per duct node, linked along the ducts; each open grate's node joins its room
	local vents = layout.vents
	if vents then
		local shut = hatchShut(layout, vents)
		local ventIndex: { [string]: number } = {}
		for _, node in vents.nodes do
			table.insert(g.pos, Vector2.new(node.x, node.z))
			table.insert(g.links, {})
			ventIndex[node.id] = #g.pos
		end
		local duct = if timed then TunnelRules.WalkSpeed / TunnelRules.VentSpeed else 1
		for _, edge in vents.edges do
			local a, b = ventIndex[edge.a], ventIndex[edge.b]
			if a and b then
				local cost = (g.pos[a] - g.pos[b]).Magnitude * duct
				table.insert(g.links[a], { to = b, cost = cost })
				table.insert(g.links[b], { to = a, cost = cost })
			end
		end
		for _, grate in vents.grates do
			local index = ventIndex[grate.node]
			if index and not grate.lockable and not shut[grate.id] and rooms[grate.room] then
				g.members[grate.room] = g.members[grate.room] or {}
				table.insert(g.members[grate.room], index)
			end
		end
	end
	local slow = TunnelRules.WalkSpeed / TunnelRules.CrouchSpeed
	for id, list in g.members do
		local room = rooms[id]
		local factor = if timed and room and room.kind == "Crawlway" then slow else 1
		for i = 1, #list do
			for j = i + 1, #list do
				local a, b = list[i], list[j]
				local cost = (g.pos[a] - g.pos[b]).Magnitude * factor
				table.insert(g.links[a], { to = b, cost = cost })
				table.insert(g.links[b], { to = a, cost = cost })
			end
		end
	end
	return g
end

-- Shortest distances from the seeds ({ node, distance }) over `g`, stopping past `limit`.
function TunnelRules.distances(g: WalkGraph, seeds: { { number } }, limit: number?): { number }
	local dist: { number } = table.create(#g.pos, INF)
	local heap = heapNew()
	for _, seed in seeds do
		local node, d = seed[1], seed[2]
		if d < dist[node] then
			dist[node] = d
			heapPush(heap, d, node)
		end
	end
	local cap = limit or INF
	while heap.size > 0 do
		local d, node = heapPop(heap)
		if d > dist[node] + EPS or d > cap then
			continue
		end
		for _, link in g.links[node] do
			local nd = d + link.cost
			if nd < dist[link.to] - EPS then
				dist[link.to] = nd
				heapPush(heap, nd, link.to)
			end
		end
	end
	return dist
end

-- Seeds for a point `p` in room `room`: its straight line to each of the room's doors.
function TunnelRules.seedsAt(g: WalkGraph, room: string, p: Vector2, base: number?): { { number } }
	local out: { { number } } = {}
	for _, node in g.members[room] or {} :: { number } do
		table.insert(out, { node, (base or 0) + (g.pos[node] - p).Magnitude })
	end
	return out
end

-- The walking distance from the sources (distances `dist` over `g`) to point `p` in `room`; `direct` lists sources
-- in that very room (their positions), reached in a straight line.
function TunnelRules.reach(g: WalkGraph, dist: { number }, room: string, p: Vector2, direct: { Vector2 }?): number
	local best = INF
	for _, node in g.members[room] or {} :: { number } do
		local d = dist[node] + (g.pos[node] - p).Magnitude
		if d < best then
			best = d
		end
	end
	local list: { Vector2 } = direct or {}
	for _, q in list do
		local d = (q - p).Magnitude
		if d < best then
			best = d
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- Points
--------------------------------------------------------------------------------

-- Where the squad arrives in `room`: the centroid of its PlayerSpawn anchors (else its centre).
function TunnelRules.arrival(layout: LayoutLike, room: string): Vector2
	local sum, count = Vector2.zero, 0
	for _, anchor in layout.anchors do
		if anchor.kind == "PlayerSpawn" and anchor.room == room then
			sum += Vector2.new(anchor.pos.X, anchor.pos.Z)
			count += 1
		end
	end
	if count > 0 then
		return sum / count
	end
	for _, r in layout.rooms do
		if r.id == room then
			return Vector2.new(r.rect.x + r.rect.w / 2, r.rect.z + r.rect.d / 2)
		end
	end
	return Vector2.zero
end

export type Sample = { room: string, p: Vector2, region: string, kind: string }

-- Points every `step` studs along the tunnel and gallery centrelines (never crawlways or alcoves).
function TunnelRules.samples(layout: LayoutLike, step: number?): { Sample }
	local out: { Sample } = {}
	local tunnels = layout.tunnels
	if not tunnels then
		return out
	end
	local s = step or TunnelRules.SampleStep
	for _, seg in tunnels.segments do
		if seg.kind ~= "Tunnel" and seg.kind ~= "Gallery" then
			continue
		end
		local a, b = Vector2.new(seg.ax, seg.az), Vector2.new(seg.bx, seg.bz)
		local length = (b - a).Magnitude
		local n = math.max(1, math.ceil(length / s))
		for i = 0, n do
			table.insert(out, { room = seg.room, p = a:Lerp(b, i / n), region = seg.region, kind = seg.kind :: string })
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- The tunnel graph: loops and dead ends
--------------------------------------------------------------------------------

type TGraph =
	{ index: { [string]: number }, ids: { string }, adj: { { { to: number, length: number, edge: number } } } }

local function tunnelGraph(tunnels: TunnelData): TGraph
	local g: TGraph = { index = {}, ids = {}, adj = {} }
	for _, node in tunnels.nodes do
		table.insert(g.ids, node.id)
		table.insert(g.adj, {})
		g.index[node.id] = #g.ids
	end
	for i, edge in tunnels.edges do
		if edge.kind == "Crawlway" then
			continue
		end
		local a, b = g.index[edge.a], g.index[edge.b]
		if a and b then
			table.insert(g.adj[a], { to = b, length = edge.length, edge = i })
			table.insert(g.adj[b], { to = a, length = edge.length, edge = i })
		end
	end
	return g
end

-- The shortest loop through node `v` of graph `g` (math.huge when it lies on none), searching no further than
-- `limit`.
local function shortestLoop(g: TGraph, v: number, limit: number): number
	local best = INF
	for _, first in g.adj[v] do
		-- the shortest way back to v from `first.to` without the edge `first.edge`
		local dist: { [number]: number } = { [first.to] = first.length }
		local heap = heapNew()
		heapPush(heap, first.length, first.to)
		while heap.size > 0 do
			local d, node = heapPop(heap)
			if d > (dist[node] or INF) + EPS or d >= best or d > limit then
				continue
			end
			if node == v then
				best = math.min(best, d)
				break
			end
			for _, link in g.adj[node] do
				if link.edge == first.edge then
					continue
				end
				local nd = d + link.length
				if nd < (dist[link.to] or INF) - EPS then
					dist[link.to] = nd
					heapPush(heap, nd, link.to)
				end
			end
		end
	end
	return best
end
TunnelRules.shortestLoopIn = shortestLoop

--------------------------------------------------------------------------------
-- Measure
--------------------------------------------------------------------------------

local STATIONS: { [string]: boolean } = {
	BreakerPanel = true,
	FumeHood = true,
	Generator = true,
	StoreLock = true,
	HatchValve = true,
	CrateChain = true,
	ExitLock = true,
}
local NOT_ITEMS: { [string]: boolean } = { TrapCandidate = true, FlaskCandidate = true, BatteryCandidate = true }

-- The objective places of a layout: every item candidate (anchor kinds "<Item>Candidate" but traps, flasks and
-- batteries), every station and every exit lock.
local function objectivePoints(layout: LayoutLike): { AnchorLike }
	local out: { AnchorLike } = {}
	for _, anchor in layout.anchors do
		local kind: string = anchor.kind
		local item = string.sub(kind, -9) == "Candidate" and not NOT_ITEMS[kind]
		if item or STATIONS[kind] then
			table.insert(out, anchor)
		end
	end
	return out
end
TunnelRules.objectivePoints = objectivePoints

-- Every measure of a tunnel layout (see the header).
function TunnelRules.measure(layout: LayoutLike): Measures
	local tunnels = layout.tunnels :: TunnelData
	local rules = tunnels.rules
	local m: Measures = {
		length = 0,
		galleryLength = 0,
		junctions = 0,
		deadEnds = {},
		loops = {},
		longestLoop = 0,
		crossing = 0,
		crossingTo = {},
		crawlCrossingSeconds = 0,
		crawlways = 0,
		crawlReach = 0,
		hideReach = 0,
		unreachable = {},
		samples = 0,
	}
	for _, seg in tunnels.segments do
		local length = math.abs(seg.bx - seg.ax) + math.abs(seg.bz - seg.az)
		if seg.kind == "Tunnel" or seg.kind == "Gallery" then
			m.length += length
		end
		if seg.kind == "Gallery" then
			m.galleryLength += length
		end
	end
	for _, room in layout.rooms do
		if room.kind == "Crawlway" then
			m.crawlways += 1
		end
	end

	-- loops and dead ends on the tunnel graph
	local tg = tunnelGraph(tunnels)
	local isPort: { [number]: boolean } = {}
	for _, node in tunnels.nodes do
		if node.kind == "Port" then
			isPort[tg.index[node.id]] = true
		end
	end
	for i, id in tg.ids do
		local degree = 0
		for _, link in tg.adj[i] do
			if not isPort[link.to] then
				degree += 1
			end
		end
		if degree >= 3 and not isPort[i] then
			m.junctions += 1
			local loop = shortestLoop(tg, i, rules.maxLoop * 4)
			m.loops[id] = loop
			m.longestLoop = math.max(m.longestLoop, loop)
		end
	end
	for _, node in tunnels.nodes do
		if node.kind ~= "End" then
			continue
		end
		-- walk back to the first node with more than two ways
		local cursor = tg.index[node.id]
		local previous = 0
		local length = 0
		while cursor and #tg.adj[cursor] <= 2 do
			local nextNode: number? = nil
			for _, link in tg.adj[cursor] do
				if link.to ~= previous then
					nextNode = link.to
					length += link.length
					break
				end
			end
			if not nextNode then
				break
			end
			previous, cursor = cursor, nextNode :: number
			if length > 1000 then
				break
			end
		end
		table.insert(m.deadEnds, { node = node.id, length = length })
	end

	-- on foot (no crawlways): reachability and the crossing
	local foot = TunnelRules.walkGraph(layout, false)
	local entryPos = TunnelRules.arrival(layout, tunnels.entry)
	local fromEntry = TunnelRules.distances(foot, TunnelRules.seedsAt(foot, tunnels.entry, entryPos))
	local roomsById: { [string]: RoomLike } = {}
	for _, room in layout.rooms do
		roomsById[room.id] = room
	end
	local function roomReach(dist: { number }, room: string): number
		local best = INF
		for _, node in foot.members[room] or {} :: { number } do
			best = math.min(best, dist[node])
		end
		return best
	end
	for _, id in tunnels.keepRooms do
		if id ~= tunnels.entry and roomReach(fromEntry, id) == INF then
			table.insert(m.unreachable, id)
		end
	end
	for _, id in tunnels.exits do
		local d = roomReach(fromEntry, id)
		m.crossingTo[id] = d
		if d == INF then
			table.insert(m.unreachable, id)
		end
		m.crossing = math.max(m.crossing, d)
	end
	-- with the crawlways, timed
	local timedGraph = TunnelRules.walkGraph(layout, true, true)
	local timed = TunnelRules.distances(timedGraph, TunnelRules.seedsAt(timedGraph, tunnels.entry, entryPos))
	local worst = 0
	for _, id in tunnels.exits do
		local best = INF
		for _, node in timedGraph.members[id] or {} :: { number } do
			best = math.min(best, timed[node])
		end
		worst = math.max(worst, best)
	end
	m.crawlCrossingSeconds = worst / TunnelRules.WalkSpeed

	-- coverage: crawlway mouths and hiding spots, walked on foot
	local samples = TunnelRules.samples(layout)
	m.samples = #samples
	local crawlSeeds: { { number } } = {}
	local crawl = TunnelRules.walkGraph(layout, true)
	for _, mouth in crawl.crawlMouths do
		-- the mouth's position as a seed in the foot graph: every foot node of the rooms the mouth opens into
		local p = crawl.pos[mouth]
		for id, list in crawl.members do
			if table.find(list, mouth) and (roomsById[id] and roomsById[id].kind ~= "Crawlway") then
				for _, seed in TunnelRules.seedsAt(foot, id, p) do
					table.insert(crawlSeeds, seed)
				end
			end
		end
	end
	local mouthsByRoom: { [string]: { Vector2 } } = {}
	for _, mouth in crawl.crawlMouths do
		for id, list in crawl.members do
			if table.find(list, mouth) then
				mouthsByRoom[id] = mouthsByRoom[id] or {}
				table.insert(mouthsByRoom[id], crawl.pos[mouth])
			end
		end
	end
	local toCrawl = TunnelRules.distances(foot, crawlSeeds)
	local hideSeeds: { { number } } = {}
	local hidesByRoom: { [string]: { Vector2 } } = {}
	for _, anchor in layout.anchors do
		if TunnelRules.HideKinds[anchor.kind] then
			local p = Vector2.new(anchor.pos.X, anchor.pos.Z)
			for _, seed in TunnelRules.seedsAt(foot, anchor.room, p) do
				table.insert(hideSeeds, seed)
			end
			hidesByRoom[anchor.room] = hidesByRoom[anchor.room] or {}
			table.insert(hidesByRoom[anchor.room], p)
		end
	end
	local toHide = TunnelRules.distances(foot, hideSeeds)
	for _, s in samples do
		m.crawlReach = math.max(m.crawlReach, TunnelRules.reach(foot, toCrawl, s.room, s.p, mouthsByRoom[s.room]))
		m.hideReach = math.max(m.hideReach, TunnelRules.reach(foot, toHide, s.room, s.p, hidesByRoom[s.room]))
	end
	return m
end

-- The walk from every objective place of `layout` to its nearest hiding spot, on foot ({ anchor id -> studs }).
function TunnelRules.objectiveHides(layout: LayoutLike): { [string]: number }
	local foot = TunnelRules.walkGraph(layout, false)
	local hideSeeds: { { number } } = {}
	local hidesByRoom: { [string]: { Vector2 } } = {}
	for _, anchor in layout.anchors do
		if TunnelRules.HideKinds[anchor.kind] then
			local p = Vector2.new(anchor.pos.X, anchor.pos.Z)
			for _, seed in TunnelRules.seedsAt(foot, anchor.room, p) do
				table.insert(hideSeeds, seed)
			end
			hidesByRoom[anchor.room] = hidesByRoom[anchor.room] or {}
			table.insert(hidesByRoom[anchor.room], p)
		end
	end
	local toHide = TunnelRules.distances(foot, hideSeeds)
	local out: { [string]: number } = {}
	for _, anchor in objectivePoints(layout) do
		out[anchor.id] = TunnelRules.reach(
			foot,
			toHide,
			anchor.room,
			Vector2.new(anchor.pos.X, anchor.pos.Z),
			hidesByRoom[anchor.room]
		)
	end
	return out
end

--------------------------------------------------------------------------------
-- Problems (LayoutSchema.validate appends them for every layout with tunnels)
--------------------------------------------------------------------------------

function TunnelRules.problems(layout: LayoutLike): { string }
	local out: { string } = {}
	local tunnels = layout.tunnels
	if not tunnels then
		return out
	end
	local function push(fmt: string, ...: any)
		table.insert(out, string.format(fmt, ...))
	end
	local rules = tunnels.rules
	local m = TunnelRules.measure(layout)
	for _, id in m.unreachable do
		push("tunnels: %s cannot be reached on foot from the entry without a crawlway", id)
	end
	for id, loop in m.loops do
		if loop > rules.maxLoop + EPS then
			push("tunnels: junction %s lies on no loop of %d studs or less (shortest %.0f)", id, rules.maxLoop, loop)
		end
	end
	if #m.deadEnds > rules.deadEndCount then
		push("tunnels: %d dead ends (at most %d)", #m.deadEnds, rules.deadEndCount)
	end
	for _, dead in m.deadEnds do
		if dead.length > rules.deadEndLength + EPS then
			push("tunnels: dead end %s runs %.1f studs (at most %d)", dead.node, dead.length, rules.deadEndLength)
		end
	end
	if m.crossing < rules.crossing[1] or m.crossing > rules.crossing[2] then
		push(
			"tunnels: the crossing (entry -> farthest exit, on foot) is %.0f studs, not %d..%d",
			m.crossing,
			rules.crossing[1],
			rules.crossing[2]
		)
	end
	if m.crawlCrossingSeconds < rules.crawlCrossingSeconds then
		push(
			"tunnels: the crawlways cut the crossing to %.0f s (at least %d)",
			m.crawlCrossingSeconds,
			rules.crawlCrossingSeconds
		)
	end
	if m.crawlways < rules.crawlways[1] or m.crawlways > rules.crawlways[2] then
		push("tunnels: %d crawlways, not %d..%d", m.crawlways, rules.crawlways[1], rules.crawlways[2])
	end
	if m.crawlReach > rules.crawlReach + EPS then
		push(
			"tunnels: a tunnel point lies %.1f studs from the nearest crawlway (at most %d)",
			m.crawlReach,
			rules.crawlReach
		)
	end
	if m.hideReach > rules.hideReach + EPS then
		push(
			"tunnels: a tunnel point lies %.1f studs from the nearest hiding spot (at most %d)",
			m.hideReach,
			rules.hideReach
		)
	end
	for id, d in TunnelRules.objectiveHides(layout) do
		if d > rules.objectiveHideReach + EPS then
			push(
				"tunnels: objective place %s lies %.1f studs from a hiding spot (at most %d)",
				id,
				d,
				rules.objectiveHideReach
			)
		end
	end
	-- crawlways: length and head room
	local rooms: { [string]: RoomLike } = {}
	for _, room in layout.rooms do
		rooms[room.id] = room
	end
	for _, room in layout.rooms do
		if room.kind ~= "Crawlway" then
			continue
		end
		local length = math.max(room.rect.w, room.rect.d)
		if length > rules.crawlLength + EPS then
			push("tunnels: crawlway %s is %.1f studs long (at most %d)", room.id, length, rules.crawlLength)
		end
	end
	for _, door in layout.doors do
		local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
		if a and b and (a.kind == "Crawlway" or b.kind == "Crawlway") then
			local h = door.height or 10
			if math.abs(h - rules.crawlHeight) > 0.05 then
				push("tunnels: crawlway mouth %s is %.2f high, not %.2f", door.id, h, rules.crawlHeight)
			end
		end
	end
	-- regions and plates
	if #tunnels.regions < rules.regions[1] or #tunnels.regions > rules.regions[2] then
		push("tunnels: %d regions, not %d..%d", #tunnels.regions, rules.regions[1], rules.regions[2])
	end
	local names: { [string]: boolean } = {}
	for _, region in tunnels.regions do
		if names[region.name] then
			push("tunnels: two regions are called %q", region.name)
		end
		names[region.name] = true
	end
	for _, room in layout.rooms do
		if (room.kind == "Tunnel" or room.kind == "Gallery") and not tunnels.roomRegion[room.id] then
			push("tunnels: room %s has no region", room.id)
		end
	end
	local plates: { [string]: boolean } = {}
	for _, landmark in tunnels.landmarks do
		if landmark.kind == "JunctionPlate" then
			plates[landmark.text] = true
		end
	end
	for _, node in tunnels.nodes do
		if node.kind == "Junction" and not (node.plate and plates[node.plate]) then
			push("tunnels: junction %s has no plate", node.id)
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Teleport points (the export writes them as meta.teleportPoints)
--------------------------------------------------------------------------------

export type TeleportPoint = {
	pos: Vector3, -- level-local, on the floor
	facings: { number }, -- yaws (degrees, 0 = -Z, 90 = -X) along the tunnel at the point
	region: string,
	zone: string,
}

-- Points on the tunnel and gallery centrelines every `step` studs (default 6), never in a crawlway, an alcove or a
-- doorway (within `clear` studs of a door's centre on its wall).
function TunnelRules.teleportPoints(layout: LayoutLike, step: number?, clear: number?): { TeleportPoint }
	local out: { TeleportPoint } = {}
	local tunnels = layout.tunnels
	if not tunnels then
		return out
	end
	local s = step or 6
	local keepOut = clear or 3.5
	local rooms: { [string]: RoomLike } = {}
	for _, room in layout.rooms do
		rooms[room.id] = room
	end
	local doorPoints: { Vector2 } = {}
	for _, door in layout.doors do
		local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
		if a and b then
			local p = TunnelRules.doorPoint(a.rect, b.rect, door.at)
			if p then
				table.insert(doorPoints, p)
			end
		end
	end
	local function yawOf(dx: number, dz: number): number
		return math.floor(math.deg(math.atan2(-dx, -dz)) + 0.5) % 360
	end
	for _, seg in tunnels.segments do
		if seg.kind ~= "Tunnel" and seg.kind ~= "Gallery" then
			continue
		end
		local a, b = Vector2.new(seg.ax, seg.az), Vector2.new(seg.bx, seg.bz)
		local length = (b - a).Magnitude
		if length < EPS then
			continue
		end
		local dir = (b - a) / length
		local n = math.max(1, math.floor(length / s))
		local stepLength = length / n
		for i = 0, n do
			local p = a + dir * (i * stepLength)
			local blocked = false
			for _, q in doorPoints do
				if (q - p).Magnitude < keepOut then
					blocked = true
					break
				end
			end
			if not blocked then
				table.insert(out, {
					pos = Vector3.new(p.X, 0, p.Y),
					facings = { yawOf(dir.X, dir.Y), yawOf(-dir.X, -dir.Y) },
					region = seg.region,
					zone = seg.room,
				})
			end
		end
	end
	return out
end

return table.freeze(TunnelRules)
