--!strict
-- TunnelPlanner: a floor's maze of maintenance tunnels, generated around its keep-rooms. Deterministic: the same spec
-- (and seed) always gives the same map, so a floor's map is fixed while every run still picks its own items and exit.
-- docs/MAPS.md is the authoring guide; TunnelRules holds the measures and the rules every result must pass.
--
-- In:  the footprint, the keep-rooms (hand-made rooms the game needs, each with ports: the doors tunnels attach to),
--      the entry room and the exit vestibules (route candidates), exclusion rects, barriers (wall lines no tunnel
--      crosses: they shape the floor into a long walk), the style (tunnel width and height, gallery share, pitch,
--      crawlways, dead ends, light spacing) and the regions (a name, a seed point and a look each).
-- Out: LayoutSchema rooms (kinds Tunnel, Gallery, Crawlway and Solid fill), open doorways, platforms (item shelves),
--      lights (caged bulbs, emergency reds), anchors (hides, waypoints with loops, creature spawns, traps, items,
--      batteries, dressing) and triggers, plus `tunnels` (TunnelRules.TunnelData: the graph, segments, regions and
--      landmarks) for the builders, the validator and the export.
--
-- How:
--   1. A jittered grid of crossings over the footprint (with a line through every port), minus the crossings and
--      corridors that hit a keep-room, an exclusion or a barrier. Each port joins the grid by a straight stub.
--   2. Thinning: from the full grid, corridors are removed in a seeded order while the graph stays connected, every
--      junction keeps a loop of at most rules.maxLoop studs, dead ends are pruned and the crossing (entry to the
--      farthest exit) stays under rules.crossing[2]; down to style.length studs. `attempts` seeds are tried and the
--      one closest to the target crossing and length wins.
--   3. Short dead ends (an alcove-sized corridor off a junction) for hides and items, then regions (the author's
--      areas, else the nearest seed point by walking distance), straight runs (one room each; at a crossing one run owns the core square, the others open into its
--      sides through doorways), galleries (the longest runs, taller and wider) and widths.
--   4. Crawlways (removed corridors short enough, re-cut as culverts the Creature cannot enter) picked greedily so a
--      mouth lies within rules.crawlReach of every tunnel point; alcoves beside the runs; hiding spots (a barrel or a
--      cabinet in an alcove, a dead end or a corner) picked greedily to cover every tunnel point within
--      rules.hideReach and every item within rules.objectiveHideReach; item shelves in alcoves (a guarded item's in a
--      wider, deeper bay with its bear-trap spot in the mouth toward the side the squad comes along the run from, so
--      the walk straight in springs it and a careful player steps round its far side to the shelf).
--   5. Solid fill over the rest of the footprint (rect cover), lights every style.lightSpacing (deadShare dead) wired
--      in local circuits of up to four bulbs, each its own group: steady "Mains:<prefix>_<region>_<nn>", a share of
--      bad ones flickering "Circuit:<prefix>_<region>_<nn>" (the power switch holds both down), junction
--      plates (J-01... by walking distance from the entry) with a red emergency lamp at every few, region stencils at
--      region entrances, graffiti, patrol loops, creature spawns, traps and dressing anchors.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Rng = require(ReplicatedStorage.Shared.Util.Rng)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local TunnelRules = require(script.Parent.TunnelRules)

type Rng = Rng.Rng
type Rect = LayoutSchema.Rect
type Room = LayoutSchema.Room
type Door = LayoutSchema.Door
type Anchor = LayoutSchema.Anchor
type Trigger = LayoutSchema.Trigger
type Light = LayoutSchema.Light
type Platform = LayoutSchema.Platform
type Side = LayoutSchema.Side

export type Port = {
	side: Side, -- the keep-room wall the tunnel leaves by
	at: number, -- centre along that wall (Z on W / E, X on N / S); a grid line runs through it
	kind: Enums.DoorKind?, -- default "Door"
	width: number?,
	height: number?,
	id: string?,
	-- the run it opens onto is at least this tall (a fire door's KEEP CLOSED sign hangs over its head casing)
	runHeight: number?,
}

export type KeepRoom = {
	room: Room,
	ports: { Port },
	region: string?, -- the region it belongs to (default: the nearest seed)
	sign: string?, -- stencilled beside each of its doors
}

export type RegionSpec = {
	id: string, -- short: names patrol loops and lights ("Coal")
	name: string, -- "Coal Chutes"
	x: number, -- the seed point: tunnels belong to the nearest by walking distance
	z: number,
	areas: { { number } }?, -- rects { x0, z0, x1, z1 }: crossings inside belong to this region, whatever the seeds
	pipe: Color3,
	band: Color3,
	grime: Color3,
	paint: Color3,
	graffiti: { string },
	wall: string?,
	floor: string?,
	wet: boolean?,
	medium: string?, -- what its mains carry (stencilled on the pipe markers)
	-- what its hide niches hold: "Barrel", "Cabinet", "Locker" (a hideable locker against the niche's back wall, the
	-- hider stepping out at the front); nil: barrels and cabinets
	hides: { string }?,
}

export type Barrier = { x0: number, z0: number, x1: number, z1: number } -- an axis-aligned wall line

export type Style = {
	width: { number }, -- tunnel widths to pick from (studs, rect width; the walls take 0.5 each side)
	height: { number }, -- tunnel heights to pick from
	galleryWidth: number,
	galleryHeight: { number },
	galleryShare: number, -- share of the tunnel length that is gallery
	galleryMin: number, -- shortest run that may be a gallery
	pitch: number, -- grid spacing (junctions every pitch .. 2 pitch)
	jitter: number, -- grid line jitter (studs)
	length: number, -- target tunnel length (studs) the thinning stops at
	deadEnds: number, -- short dead ends to add
	crawlWidth: number,
	crawlAcrossBarriers: boolean?, -- crawlways may cut through a barrier (shortcuts; rules.crawlCrossingSeconds holds)
	crawlMouthsPass: boolean?, -- the thinning keeps two tunnel arms at every crawlway mouth (never a dead end's tip)
	alcoveWidth: number, -- item niches (a shelf on the back wall)
	alcoveDepth: number,
	alcoveHeight: number,
	-- a guarded item's bay (its bear trap in the mouth, toward the side the squad comes from): wide enough to step round
	-- the trap by its far side, deep enough that the item's prompt first answers in its mouth (default GUARD_ALCOVE)
	guardAlcoveWidth: number?,
	guardAlcoveDepth: number?,
	hideAlcoveWidth: number?, -- hide niches: a barrel or cabinet stands free in one (default 10)
	hideAlcoveDepth: number?, -- (default 7)
	lightSpacing: { number },
	deadShare: number, -- share of the bulbs that are dead
	flickerShare: number, -- share of the circuits that flicker
	plateLampEvery: number, -- a red emergency lamp at every n-th junction plate
	wall: string,
	floor: string,
	ceiling: string,
	acoustic: Enums.AcousticPreset,
	galleryAcoustic: Enums.AcousticPreset,
	crawlAcoustic: Enums.AcousticPreset,
}

export type ItemSpec = {
	kind: Enums.AnchorKind,
	count: number,
	shelf: number, -- shelf top above the floor (the item rests on it); with `wall`, the hook's height
	-- a TrapCandidate on its approach (the item's ref): in the mouth of a guard bay (style.guardAlcoveWidth x
	-- guardAlcoveDepth) toward the side the squad comes along the run from, so the walk straight in round the near jamb
	-- springs it while a careful player steps round its far side and takes the item from beside the shelf
	guard: boolean?,
	-- hung on a hook on the niche's back wall at `shelf` (the anchor is the hook's wall point, facing out of the niche)
	-- instead of resting on a shelf
	wall: boolean?,
	-- rects { x0, z0, x1, z1 } the item niches must lie in (their centre); nil: anywhere
	areas: { { number } }?,
}

-- Two keep-rooms joined directly by a door the layout adds itself (a vestibule opening straight into a hall, a gate
-- between two halls): the planner walks from every node of one (its ports; the entry's arrival point) to every node
-- of the other.
export type Link = { a: string, b: string }

export type PlanSpec = {
	levelId: Enums.LayoutId,
	prefix: string,
	seed: number,
	height: number, -- the level height (Solid fill rooms)
	keepRooms: { KeepRoom },
	entry: string,
	exits: { string },
	exclusions: { Rect }?,
	barriers: { Barrier }?,
	gridX: { number }?, -- explicit grid lines (else generated at style.pitch); port lines are always added
	gridZ: { number }?,
	-- crawlway sites pinned by the author: grid corridors { x0, z0, x1, z1 } between two crossings (may cut through a
	-- barrier); nil lets the planner pick them (greedy coverage)
	crawlSites: { { number } }?,
	style: Style,
	regions: { RegionSpec },
	rules: TunnelRules.RuleSpec?,
	attempts: number?,
	crossingTarget: number?,
	items: { ItemSpec }?,
	hideTargets: { Vector3 }?, -- more points that need a hide within rules.objectiveHideReach (tunnel side)
	traps: number, -- TrapCandidate spots besides the guards
	batteries: number,
	clutter: number,
	corpses: number,
	drips: number,
	debris: number,
	scares: number,
	creatureSpawns: number,
	creatureBand: { number }, -- walked from the entry
	-- the other ways in (entry vestibule keep-rooms besides `entry`): items keep 60 studs walked from each, and the
	-- creature spawns are shared out so each of them, and the entry, keeps its own in the band walked from it
	otherEntries: { string }?,
	links: { Link }?,
	lore: { { text: string, near: string } }?, -- lore lines placed near a feature ("Crawlway", "Exit", a room id)
}

export type Plan = {
	rooms: { Room },
	doors: { Door },
	anchors: { Anchor },
	triggers: { Trigger },
	platforms: { Platform },
	tunnels: TunnelRules.TunnelData,
	portRooms: { [string]: string }, -- port door id -> the tunnel room on its far side
	stats: { [string]: number },
}

local TunnelPlanner = {}

local EPS = 1e-3
local INF = math.huge
local WALL = WorldConfig.WallThickness
local EXTERIOR = WorldConfig.ExteriorWallThickness
local NODE_CLEAR = 2 -- free stone kept between a crossing's square and a keep-room
local ALCOVE_GAP = 1.5 -- free stone kept around an alcove
local CRAWL_HEIGHT = TunnelRules.CrawlClearance + 0.5 -- room height: its doors are CrawlClearance high
local PATROL_HOP = 110 -- longest walk between a patrol loop's waypoints
local CIRCUIT_FIXTURES = 4 -- bulbs wired to one local light group (one circuit)
-- the hide props' footprints (HideBuilder.Footprints: X across the front, Y front to back) and the gap a freestanding
-- one keeps from its niche's back wall
local HIDE_FOOTPRINT: { [string]: Vector2 } = { Barrel = Vector2.new(3.3, 3.3), Cabinet = Vector2.new(3.3, 2.4) }
local HIDE_BACK_GAP = 0.6
local LOCKER_OFFSET = 2.05 -- a hideable locker's anchor stands this far off the line of the wall behind it
-- A guarded item's bay, width x depth, and its trap spot: GUARD_IN into the bay from its mouth and GUARD_ASIDE off its
-- centre line toward the near side (the side its run is walked along from the ways in: GUARD_SIDE_MARGIN studs sooner
-- than the other, on foot and through the crawlways alike; a bay with no such side holds no guarded item). The item
-- rests on its shelf so far back that its Pickup prompt first answers in the mouth: the walk in from the run, round the
-- near jamb, sets its foot on the pan (2.2 square at any yaw: 1.1 to 1.56 from its centre) just as the prompt answers.
-- Across the bay's 8 inside the walls, a body on the near side cannot pass the pan and the far side keeps a lane over 3
-- studs wide for a careful player, who takes the item from beside the shelf well clear.
local GUARD_ALCOVE = Vector2.new(9, 8)
local GUARD_IN = 0.7
local GUARD_ASIDE = 2.4
local GUARD_SIDE_MARGIN = 6
local PORT_BERTH = 11 -- niches keep this far (past their half width) from a keep-room's door along the run
local FIRE_DOOR_BERTH = WorldConfig.AirlockDoorWidth + 4 -- a vestibule door's swing, then its STAIRS sign
local PLATE_Y = 6.2
local SIGN_Y = 7.4

TunnelPlanner.CrawlRoomHeight = CRAWL_HEIGHT

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function rect(x0: number, z0: number, x1: number, z1: number): Rect
	return { x = math.min(x0, x1), z = math.min(z0, z1), w = math.abs(x1 - x0), d = math.abs(z1 - z0) }
end

local function overlaps(a: Rect, b: Rect, pad: number?): boolean
	local p = pad or 0
	return math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x) > -p + EPS
		and math.min(a.z + a.d, b.z + b.d) - math.max(a.z, b.z) > -p + EPS
end

local function inside(inner: Rect, outer: Rect): boolean
	return inner.x >= outer.x - EPS
		and inner.z >= outer.z - EPS
		and inner.x + inner.w <= outer.x + outer.w + EPS
		and inner.z + inner.d <= outer.z + outer.d + EPS
end

-- A sort key for a measured length: `x` on a grid of EPS. Lengths within float noise of each other share a key (then
-- the caller breaks the tie by id); unlike an "equal within EPS" comparator it is transitive, so table.sort orders the
-- same way in every Luau build whatever its algorithm.
local function sortKey(x: number): number
	return math.floor(x / EPS + 0.5)
end

local function pick<T>(random: Rng, list: { T }): T
	return list[random:NextInteger(1, #list)]
end

local function round2(x: number): number
	return math.floor(x * 2 + 0.5) / 2
end

-- Yaw (degrees about +Y) that faces along (dx, dz): 0 faces -Z, 90 faces -X.
local function yawOf(dx: number, dz: number): number
	return math.deg(math.atan2(-dx, -dz))
end

--------------------------------------------------------------------------------
-- Graph
--------------------------------------------------------------------------------

type GNode = {
	id: number,
	x: number,
	z: number,
	gx: number?, -- grid indices (nil for ports and the entry)
	gz: number?,
	port: { keep: KeepRoom, port: Port, doorId: string }?,
	entry: boolean?,
	terminal: boolean,
	region: number,
}

type GEdge = {
	id: number,
	a: number,
	b: number,
	length: number,
	axis: "X" | "Z" | "R", -- R: a walk across a keep-room
	kind: "Grid" | "Stub" | "Room",
	alive: boolean,
	crawl: boolean?, -- re-cut as a crawlway (never walked: the thinning keeps its two crossings)
	barred: boolean?, -- crosses a barrier: never walked, only ever a crawlway (style.crawlAcrossBarriers)
	gap: boolean?, -- joins two bands through a barrier's gap
}

type Graph = {
	nodes: { GNode },
	edges: { GEdge },
	adj: { { number } }, -- node -> edge ids
	at: { [string]: number }, -- "gx,gz" -> node id
	xs: { number },
	zs: { number },
}

local function other(e: GEdge, v: number): number
	return if e.a == v then e.b else e.a
end

local function degree(g: Graph, v: number): number
	local n = 0
	for _, id in g.adj[v] do
		if g.edges[id].alive then
			n += 1
		end
	end
	return n
end

-- Live tunnel arms at `v` (port stubs and walks across keep-rooms do not count): a junction has three or more.
local function tunnelDegree(g: Graph, v: number): number
	local n = 0
	for _, id in g.adj[v] do
		local e = g.edges[id]
		if e.alive and e.kind == "Grid" then
			n += 1
		end
	end
	return n
end

local function addEdge(g: Graph, a: number, b: number, kind: "Grid" | "Stub" | "Room"): GEdge
	local na, nb = g.nodes[a], g.nodes[b]
	local axis: "X" | "Z" | "R" = if kind == "Room" then "R" elseif math.abs(na.z - nb.z) < EPS then "X" else "Z"
	local e: GEdge = {
		id = #g.edges + 1,
		a = a,
		b = b,
		length = math.sqrt((na.x - nb.x) ^ 2 + (na.z - nb.z) ^ 2),
		axis = axis,
		kind = kind,
		alive = true,
	}
	table.insert(g.edges, e)
	table.insert(g.adj[a], e.id)
	table.insert(g.adj[b], e.id)
	return e
end

local function addNode(g: Graph, x: number, z: number): GNode
	local node: GNode = { id = #g.nodes + 1, x = x, z = z, terminal = false, region = 1 }
	table.insert(g.nodes, node)
	table.insert(g.adj, {})
	return node
end

-- Grid lines from lo to hi through every forced coordinate, about `pitch` apart, jittered.
local function gridLines(
	lo: number,
	hi: number,
	forced: { number },
	pitch: number,
	jitter: number,
	random: Rng
): { number }
	local fixed: { number } = {}
	for _, f in forced do
		if f >= lo - EPS and f <= hi + EPS then
			local dup = false
			for _, g in fixed do
				if math.abs(g - f) < 1 then
					dup = true
				end
			end
			if not dup then
				table.insert(fixed, f)
			end
		end
	end
	table.sort(fixed)
	local anchors: { number } = {}
	if #fixed == 0 or fixed[1] - lo > pitch * 0.5 then
		table.insert(anchors, lo)
	end
	for _, f in fixed do
		table.insert(anchors, f)
	end
	if #fixed == 0 or hi - fixed[#fixed] > pitch * 0.5 then
		table.insert(anchors, hi)
	end
	local out: { number } = {}
	for i = 1, #anchors - 1 do
		local a, b = anchors[i], anchors[i + 1]
		table.insert(out, a)
		local n = math.max(1, math.floor((b - a) / pitch + 0.5))
		for k = 1, n - 1 do
			local base = a + (b - a) * k / n
			local j = (random:NextNumber() * 2 - 1) * jitter
			table.insert(out, math.floor(base + j + 0.5))
		end
	end
	table.insert(out, anchors[#anchors])
	return out
end

-- Whether the corridor a-b crosses a barrier (`anywhere`: crosses the barrier's line, gaps included).
local function crossesBarrier(
	barriers: { Barrier },
	ax: number,
	az: number,
	bx: number,
	bz: number,
	anywhere: boolean?
): boolean
	for _, b in barriers do
		if math.abs(b.x0 - b.x1) < EPS then
			-- a wall at constant X spanning z0..z1: a horizontal corridor crosses it
			local x = b.x0
			local z0, z1 = math.min(b.z0, b.z1), math.max(b.z0, b.z1)
			local within = anywhere or (az >= z0 and az <= z1)
			if math.abs(az - bz) < EPS and math.min(ax, bx) < x and math.max(ax, bx) > x and within then
				return true
			end
		else
			local z = b.z0
			local x0, x1 = math.min(b.x0, b.x1), math.max(b.x0, b.x1)
			local within = anywhere or (ax >= x0 and ax <= x1)
			if math.abs(ax - bx) < EPS and math.min(az, bz) < z and math.max(az, bz) > z and within then
				return true
			end
		end
	end
	return false
end

local function onBarrier(barriers: { Barrier }, x: number, z: number): boolean
	for _, b in barriers do
		if math.abs(b.x0 - b.x1) < EPS then
			if math.abs(x - b.x0) < 1 and z >= math.min(b.z0, b.z1) - 1 and z <= math.max(b.z0, b.z1) + 1 then
				return true
			end
		elseif math.abs(z - b.z0) < 1 and x >= math.min(b.x0, b.x1) - 1 and x <= math.max(b.x0, b.x1) + 1 then
			return true
		end
	end
	return false
end

local function portPoint(keep: KeepRoom, port: Port): (number, number, number, number)
	local r = keep.room.rect
	if port.side == "W" then
		return r.x, port.at, -1, 0
	elseif port.side == "E" then
		return r.x + r.w, port.at, 1, 0
	elseif port.side == "N" then
		return port.at, r.z, 0, -1
	end
	return port.at, r.z + r.d, 0, 1
end

-- The full candidate graph: grid crossings and corridors clear of the keep-rooms, exclusions and barriers; port stubs;
-- walks across keep-rooms between their ports; the entry point.
local function buildGraph(spec: PlanSpec, random: Rng): Graph
	local size = WorldConfig.FootprintSize
	local style = spec.style
	local maxWidth = math.max(style.galleryWidth, table.unpack(style.width))
	local half = maxWidth / 2
	local barriers = spec.barriers or {}
	local blocked: { Rect } = {}
	for _, keep in spec.keepRooms do
		table.insert(blocked, keep.room.rect)
	end
	for _, r in spec.exclusions or {} :: { Rect } do
		table.insert(blocked, r)
	end
	local forcedX: { number } = {}
	local forcedZ: { number } = {}
	for _, keep in spec.keepRooms do
		for _, port in keep.ports do
			if port.side == "N" or port.side == "S" then
				table.insert(forcedX, port.at)
			else
				table.insert(forcedZ, port.at)
			end
		end
	end
	local margin = half + 2
	local g: Graph = { nodes = {}, edges = {}, adj = {}, at = {}, xs = {}, zs = {} }
	local function explicit(base: { number }, forced: { number }): { number }
		local out = table.clone(base)
		for _, f in forced do
			local near = false
			for _, x in out do
				if math.abs(x - f) < 1 then
					near = true
				end
			end
			if not near then
				table.insert(out, f)
			end
		end
		table.sort(out)
		return out
	end
	g.xs = if spec.gridX
		then explicit(spec.gridX, forcedX)
		else gridLines(margin, size.X - margin, forcedX, style.pitch, style.jitter, random)
	g.zs = if spec.gridZ
		then explicit(spec.gridZ, forcedZ)
		else gridLines(margin, size.Y - margin, forcedZ, style.pitch, style.jitter, random)
	local function free(r: Rect): boolean
		for _, b in blocked do
			if overlaps(r, b, NODE_CLEAR) then
				return false
			end
		end
		return true
	end
	for i, x in g.xs do
		for j, z in g.zs do
			local core = rect(x - half, z - half, x + half, z + half)
			if free(core) and not onBarrier(barriers, x, z) then
				local node = addNode(g, x, z)
				node.gx, node.gz = i, j
				g.at[i .. "," .. j] = node.id
			end
		end
	end
	for i = 1, #g.xs do
		for j = 1, #g.zs do
			local here = g.at[i .. "," .. j]
			if not here then
				continue
			end
			for _, step in { { 1, 0 }, { 0, 1 } } do
				local there = g.at[(i + step[1]) .. "," .. (j + step[2])]
				if not there then
					continue
				end
				local a, b = g.nodes[here], g.nodes[there]
				local corridor = rect(
					math.min(a.x, b.x) - (if step[2] == 1 then half else 0),
					math.min(a.z, b.z) - (if step[1] == 1 then half else 0),
					math.max(a.x, b.x) + (if step[2] == 1 then half else 0),
					math.max(a.z, b.z) + (if step[1] == 1 then half else 0)
				)
				if free(corridor) then
					local e = addEdge(g, here, there, "Grid")
					if crossesBarrier(barriers, a.x, a.z, b.x, b.z) then
						e.barred = true
						e.alive = false
					elseif crossesBarrier(barriers, a.x, a.z, b.x, b.z, true) then
						e.gap = true
					end
				end
			end
		end
	end
	-- ports: a stub from the port straight out to the first free crossing on its line
	local keepNodes: { [string]: { number } } = {}
	for _, keep in spec.keepRooms do
		local portNodes: { number } = {}
		keepNodes[keep.room.id] = portNodes
		for index, port in keep.ports do
			local px, pz, dx, dz = portPoint(keep, port)
			local node = addNode(g, px, pz)
			node.terminal = true
			node.port = {
				keep = keep,
				port = port,
				doorId = port.id or string.format("%s_Door_%s_%d", spec.prefix, keep.room.id, index),
			}
			local best: number? = nil
			local bestDistance = INF
			for _, candidate in g.nodes do
				if not candidate.gx then
					continue
				end
				local along = (candidate.x - px) * dx + (candidate.z - pz) * dz
				local across = math.abs((candidate.x - px) * dz) + math.abs((candidate.z - pz) * dx)
				if across < EPS and along > half + 0.5 and along < bestDistance then
					best, bestDistance = candidate.id, along
				end
			end
			if not best then
				error(string.format("TunnelPlanner: port %d of %s finds no crossing on its line", index, keep.room.id))
			end
			local target = g.nodes[best :: number]
			local stub = rect(
				math.min(px, target.x) - (if dx == 0 then half else 0),
				math.min(pz, target.z) - (if dz == 0 then half else 0),
				math.max(px, target.x) + (if dx == 0 then half else 0),
				math.max(pz, target.z) + (if dz == 0 then half else 0)
			)
			for _, b in blocked do
				if b ~= keep.room.rect and LayoutSchema.rectOverlapArea(stub, b) > 0 then
					error(
						string.format(
							"TunnelPlanner: the stub from port %d of %s runs into another room",
							index,
							keep.room.id
						)
					)
				end
			end
			if crossesBarrier(barriers, px, pz, target.x, target.z) then
				error(
					string.format(
						"TunnelPlanner: the stub from port %d of %s crosses a barrier (its first crossing is blocked)",
						index,
						keep.room.id
					)
				)
			end
			addEdge(g, node.id, best :: number, "Stub")
			table.insert(portNodes, node.id)
		end
		for i = 1, #portNodes do
			for j = i + 1, #portNodes do
				addEdge(g, portNodes[i], portNodes[j], "Room")
			end
		end
		if keep.room.id == spec.entry then
			local c = LayoutSchema.rectCenter(keep.room.rect)
			local node = addNode(g, c.X, c.Y)
			node.entry = true
			node.terminal = true
			for _, p in portNodes do
				addEdge(g, node.id, p, "Room")
			end
			keepNodes[keep.room.id] = table.clone(portNodes)
			table.insert(keepNodes[keep.room.id], node.id)
		end
	end
	-- keep-rooms joined directly by a door of the layout's own: walks across both
	for _, link in spec.links or {} :: { Link } do
		local a, b = keepNodes[link.a], keepNodes[link.b]
		if not a or not b or #a == 0 or #b == 0 then
			error(string.format("TunnelPlanner: link %s - %s needs two keep-rooms with ports", link.a, link.b))
		end
		for _, u in a do
			for _, v in b do
				addEdge(g, u, v, "Room")
			end
		end
	end
	return g
end

--------------------------------------------------------------------------------
-- Graph measures used while thinning
--------------------------------------------------------------------------------

type Heap = { d: { number }, n: { number }, size: number }

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

-- Shortest distances from `from` over alive edges (skipping edge `skip`), up to `limit`.
local function dijkstra(g: Graph, from: number, limit: number?, skip: number?): { [number]: number }
	local dist: { [number]: number } = { [from] = 0 }
	local heap: Heap = { d = {}, n = {}, size = 0 }
	heapPush(heap, 0, from)
	local cap = limit or INF
	while heap.size > 0 do
		local d, v = heapPop(heap)
		if d > (dist[v] or INF) + EPS or d > cap then
			continue
		end
		for _, id in g.adj[v] do
			local e = g.edges[id]
			if not e.alive or id == skip then
				continue
			end
			local u = other(e, v)
			local nd = d + e.length
			if nd < (dist[u] or INF) - EPS then
				dist[u] = nd
				heapPush(heap, nd, u)
			end
		end
	end
	return dist
end

local function shortestLoop(g: Graph, v: number, limit: number): number
	local best = INF
	for _, id in g.adj[v] do
		local e = g.edges[id]
		if not e.alive then
			continue
		end
		local u = other(e, v)
		local dist = dijkstra(g, u, limit - e.length, id)
		local back = dist[v]
		if back then
			best = math.min(best, back + e.length)
		end
	end
	return best
end

-- The live corridor between two neighbouring crossings (the shortest when there are several).
local function edgeBetween(g: Graph, a: number, b: number): GEdge
	local best: GEdge? = nil
	for _, id in g.adj[a] do
		local e = g.edges[id]
		if e.alive and other(e, a) == b and (best == nil or e.length < (best :: GEdge).length) then
			best = e
		end
	end
	if not best then
		error(string.format("TunnelPlanner: no live corridor between crossings %d and %d", a, b))
	end
	return best :: GEdge
end

-- The crossings on the shortest live walk from one crossing to another (both ends included).
local function nodePath(g: Graph, from: number, to: number): { number }
	local dist: { [number]: number } = { [from] = 0 }
	local previous: { [number]: number } = {}
	local heap: Heap = { d = {}, n = {}, size = 0 }
	heapPush(heap, 0, from)
	while heap.size > 0 do
		local d, v = heapPop(heap)
		if v == to then
			break
		end
		if d > (dist[v] or INF) + EPS then
			continue
		end
		for _, id in g.adj[v] do
			local e = g.edges[id]
			if e.alive then
				local u = other(e, v)
				local nd = d + e.length
				if nd < (dist[u] or INF) - EPS then
					dist[u] = nd
					previous[u] = v
					heapPush(heap, nd, u)
				end
			end
		end
	end
	local path = { to }
	local v = to
	while v ~= from do
		local p = previous[v]
		if not p then
			return { from } -- cut off (never on a connected graph)
		end
		v = p
		table.insert(path, 1, v)
	end
	return path
end

local function entryNode(g: Graph): number
	for _, node in g.nodes do
		if node.entry then
			return node.id
		end
	end
	error("TunnelPlanner: the entry keep-room is missing")
end

local function exitNodes(g: Graph, spec: PlanSpec): { number }
	local out: { number } = {}
	for _, node in g.nodes do
		local port = node.port
		if port and table.find(spec.exits, port.keep.room.id) then
			table.insert(out, node.id)
		end
	end
	return out
end

-- The crossing: the entry's walk to its farthest exit (math.huge when one is cut off).
local function crossing(g: Graph, spec: PlanSpec): number
	local dist = dijkstra(g, entryNode(g))
	local worst = 0
	for _, id in exitNodes(g, spec) do
		worst = math.max(worst, dist[id] or INF)
	end
	return worst
end

local function aliveLength(g: Graph): number
	local total = 0
	for _, e in g.edges do
		if e.alive and e.kind ~= "Room" then
			total += e.length
		end
	end
	return total
end

local function connected(g: Graph): boolean
	local start = entryNode(g)
	local seen: { [number]: boolean } = { [start] = true }
	local queue = { start }
	local head = 1
	while head <= #queue do
		local v = queue[head]
		head += 1
		for _, id in g.adj[v] do
			local e = g.edges[id]
			if e.alive then
				local u = other(e, v)
				if not seen[u] then
					seen[u] = true
					table.insert(queue, u)
				end
			end
		end
	end
	for _, node in g.nodes do
		if degree(g, node.id) > 0 and not seen[node.id] then
			return false
		end
		if node.terminal and not seen[node.id] then
			return false
		end
	end
	return true
end

-- Multi-source shortest distances over live edges from the crawlway sites' crossings.
local function mouthDistances(g: Graph): { [number]: number }
	local dist: { [number]: number } = {}
	local heap: Heap = { d = {}, n = {}, size = 0 }
	for _, e in g.edges do
		if e.crawl then
			for _, v in { e.a, e.b } do
				if (dist[v] or INF) > 0 then
					dist[v] = 0
					heapPush(heap, 0, v)
				end
			end
		end
	end
	while heap.size > 0 do
		local d, v = heapPop(heap)
		if d > (dist[v] or INF) + EPS then
			continue
		end
		for _, id in g.adj[v] do
			local e = g.edges[id]
			if not e.alive then
				continue
			end
			local u = other(e, v)
			local nd = d + e.length
			if nd < (dist[u] or INF) - EPS then
				dist[u] = nd
				heapPush(heap, nd, u)
			end
		end
	end
	return dist
end

-- The farthest point of live corridor `e` from a crawlway site.
local function edgeReach(e: GEdge, dist: { [number]: number }): number
	local da, db = dist[e.a] or INF, dist[e.b] or INF
	if da == INF and db == INF then
		return INF
	end
	return (math.min(da, db + e.length) + math.min(db, da + e.length) + e.length) / 2
end

-- Whether every live corridor (stubs too) lies within `reach` of a crawlway site.
local function covered(g: Graph, reach: number): boolean
	local dist = mouthDistances(g)
	for _, e in g.edges do
		if e.alive and e.kind ~= "Room" and edgeReach(e, dist) > reach then
			return false
		end
	end
	return true
end

-- The crawlway sites: grid corridors short enough to re-cut as crawlways, picked greedily so their crossings reach
-- (within `reach`, on the full grid) as many crossings as they can, the ports' first crossings counting most, at least
-- 30 studs apart.
local function chooseCrawls(
	g: Graph,
	spec: PlanSpec,
	rules: TunnelRules.RuleSpec,
	reach: number,
	random: Rng
): { GEdge }
	local maxEdge = rules.crawlLength + math.min(table.unpack(spec.style.width))
	local weight: { [number]: number } = {}
	for _, node in g.nodes do
		if node.gx then
			weight[node.id] = 1
		end
	end
	for _, e in g.edges do
		if e.kind == "Stub" then
			local inner = if g.nodes[e.a].port then e.b else e.a
			weight[inner] = 30
		elseif e.gap then
			weight[e.a] = math.max(weight[e.a] or 0, 12)
			weight[e.b] = math.max(weight[e.b] or 0, 12)
		end
	end
	-- draws in node order (never the table's hash order), so every Luau build draws the same weight for each node
	local weighted: { number } = {}
	for v in weight do
		table.insert(weighted, v)
	end
	table.sort(weighted)
	for _, v in weighted do
		weight[v] = weight[v] * random:NextNumber(0.75, 1.25)
	end
	local candidates: { GEdge } = {}
	for _, e in g.edges do
		if e.kind == "Grid" and e.length <= maxEdge and (not e.barred or spec.style.crawlAcrossBarriers) then
			table.insert(candidates, e)
		end
	end
	Rng.shuffle(candidates, random)
	local cover: { [GEdge]: { [number]: number } } = {}
	local coverOrder: { [GEdge]: { number } } = {}
	for _, e in candidates do
		local da = dijkstra(g, e.a, reach, e.id)
		local db = dijkstra(g, e.b, reach, e.id)
		local set: { [number]: number } = table.clone(da)
		for v, d in db do
			set[v] = math.min(set[v] or INF, d)
		end
		cover[e] = set
		-- the covered nodes in node order: the gains below sum in the same order in every Luau build
		local nodes: { number } = {}
		for v in set do
			table.insert(nodes, v)
		end
		table.sort(nodes)
		coverOrder[e] = nodes
	end
	local chosen: { GEdge } = {}
	local done: { [number]: boolean } = {}
	local want = rules.crawlways[2]
	while #chosen < want do
		local best: GEdge? = nil
		local bestGain = 0
		for _, e in candidates do
			local near = false
			for _, c in chosen do
				local ma = g.nodes[c.a]
				local na = g.nodes[e.a]
				if math.abs(ma.x - na.x) + math.abs(ma.z - na.z) < 30 or e == c then
					near = true
					break
				end
			end
			if near then
				continue
			end
			local gain = 0
			for _, v in coverOrder[e] do
				if not done[v] then
					gain += weight[v] or 0
				end
			end
			if gain > bestGain then
				best, bestGain = e, gain
			end
		end
		if not best then
			break
		end
		table.insert(chosen, best :: GEdge)
		for v in cover[best :: GEdge] do
			done[v] = true
		end
	end
	return chosen
end

-- Thins the graph (see the header). Returns the crossing it ends at (math.huge when the crawlway sites cannot cover
-- the ports).
local function thin(g: Graph, spec: PlanSpec, rules: TunnelRules.RuleSpec, random: Rng): number
	-- crawlway sites first: corridors re-cut low, their crossings kept; every corridor stays within reach of one
	-- (door points cut the corners of the crossings, so the walk the rules measure is a little shorter than this one)
	local reach = rules.crawlReach + 1
	local sites: { GEdge } = {}
	if spec.crawlSites then
		for _, site in spec.crawlSites :: { { number } } do
			local found: GEdge? = nil
			for _, e in g.edges do
				local a, b = g.nodes[e.a], g.nodes[e.b]
				if e.kind == "Grid" then
					local same = math.abs(a.x - site[1]) < EPS
						and math.abs(a.z - site[2]) < EPS
						and math.abs(b.x - site[3]) < EPS
						and math.abs(b.z - site[4]) < EPS
					local swapped = math.abs(b.x - site[1]) < EPS
						and math.abs(b.z - site[2]) < EPS
						and math.abs(a.x - site[3]) < EPS
						and math.abs(a.z - site[4]) < EPS
					if same or swapped then
						found = e
					end
				end
			end
			if not found then
				error(
					string.format(
						"TunnelPlanner: crawl site (%g, %g)-(%g, %g) is not a grid corridor",
						site[1],
						site[2],
						site[3],
						site[4]
					)
				)
			end
			table.insert(sites, found :: GEdge)
		end
	else
		sites = chooseCrawls(g, spec, rules, reach, random)
	end
	for _, e in sites do
		e.alive = false
		e.crawl = true
		g.nodes[e.a].terminal = true
		g.nodes[e.b].terminal = true
	end
	local function pruneFrom(seeds: { number }, removed: { GEdge })
		local queue = table.clone(seeds)
		local head = 1
		while head <= #queue do
			local v = queue[head]
			head += 1
			if g.nodes[v].terminal or degree(g, v) ~= 1 then
				continue
			end
			for _, other_id in g.adj[v] do
				local f = g.edges[other_id]
				if f.alive then
					f.alive = false
					table.insert(removed, f)
					table.insert(queue, other(f, v))
				end
			end
		end
	end
	-- cut away whatever lies out of reach of every site
	while true do
		local dist = mouthDistances(g)
		local cut: { GEdge } = {}
		for _, e in g.edges do
			if e.alive and e.kind == "Grid" and edgeReach(e, dist) > reach then
				table.insert(cut, e)
			end
		end
		if #cut == 0 then
			break
		end
		local ends: { number } = {}
		for _, e in cut do
			e.alive = false
			table.insert(ends, e.a)
			table.insert(ends, e.b)
		end
		pruneFrom(ends, {})
	end
	-- crossings left hanging from the start (their other corridors barred or blocked) go too
	do
		local ends: { number } = {}
		for _, node in g.nodes do
			if degree(g, node.id) == 1 then
				table.insert(ends, node.id)
			end
		end
		pruneFrom(ends, {})
	end
	if not connected(g) or not covered(g, reach) then
		return INF
	end
	-- the cut may leave a junction without its loop: take away one of its arms (one the graph can spare) until every
	-- junction is on a loop again or a crossing, nothing more
	for _ = 1, 64 do
		local bad: number? = nil
		for _, node in g.nodes do
			if tunnelDegree(g, node.id) >= 3 and shortestLoop(g, node.id, rules.maxLoop) > rules.maxLoop then
				bad = node.id
				break
			end
		end
		if not bad then
			break
		end
		local fixed = false
		for _, id in g.adj[bad :: number] do
			local e = g.edges[id]
			if not e.alive or e.kind ~= "Grid" then
				continue
			end
			local removed: { GEdge } = { e }
			e.alive = false
			pruneFrom({ e.a, e.b }, removed)
			if connected(g) and covered(g, reach) then
				fixed = true
				break
			end
			for _, f in removed do
				f.alive = true
			end
		end
		if not fixed then
			return INF
		end
	end

	local order: { number } = {}
	for _, e in g.edges do
		if e.kind == "Grid" and e.alive then
			table.insert(order, e.id)
		end
	end
	Rng.shuffle(order, random)
	local total = aliveLength(g)
	local loopReach = rules.maxLoop / 2 + 1
	for _, id in order do
		if total <= spec.style.length then
			break
		end
		local e = g.edges[id]
		if not e.alive then
			continue
		end
		local removed: { GEdge } = { e }
		e.alive = false
		pruneFrom({ e.a, e.b }, removed)
		local ok = connected(g)
		if ok and spec.style.crawlMouthsPass then
			-- a crawlway's mouth stays on a through tunnel (two arms at least): never the tip of a long dead end
			for _, f in removed do
				for _, v in { f.a, f.b } do
					local node = g.nodes[v]
					if node.terminal and not node.port and not node.entry and tunnelDegree(g, v) < 2 then
						ok = false
					end
				end
			end
		end
		if ok then
			-- every junction near the cut keeps a short loop
			local touched: { [number]: boolean } = {}
			for _, f in removed do
				touched[f.a] = true
				touched[f.b] = true
			end
			for _, node in g.nodes do
				if not ok then
					break
				end
				if tunnelDegree(g, node.id) < 3 then
					continue
				end
				local near = false
				for v in touched do
					local t = g.nodes[v]
					if math.abs(t.x - node.x) + math.abs(t.z - node.z) <= loopReach * 1.5 then
						near = true
						break
					end
				end
				if near and shortestLoop(g, node.id, rules.maxLoop) > rules.maxLoop then
					ok = false
				end
			end
		end
		if ok and not covered(g, reach) then
			ok = false
		end
		if ok and crossing(g, spec) > rules.crossing[2] then
			ok = false
		end
		if ok then
			for _, f in removed do
				total -= f.length
			end
		else
			for _, f in removed do
				f.alive = true
			end
		end
	end
	return crossing(g, spec)
end

--------------------------------------------------------------------------------
-- Runs (one straight room each)
--------------------------------------------------------------------------------

type Dir = "N" | "S" | "E" | "W"

type Run = {
	id: number,
	axis: "X" | "Z",
	nodes: { number }, -- in order of increasing coordinate
	edges: { number },
	width: number,
	height: number,
	gallery: boolean,
	rect: Rect,
	roomId: string,
	region: number,
	length: number,
}

local function dirOf(g: Graph, from: number, e: GEdge): Dir
	local a, b = g.nodes[from], g.nodes[other(e, from)]
	if e.axis == "X" then
		return if b.x > a.x then "E" else "W"
	end
	return if b.z > a.z then "S" else "N"
end

local DIRS: { string } = { "N", "E", "S", "W" }

local function arms(g: Graph, v: number): { [string]: number }
	local out: { [string]: number } = {}
	for _, id in g.adj[v] do
		local e = g.edges[id]
		if e.alive and e.kind ~= "Room" then
			out[dirOf(g, v, e)] = id
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Solid fill: the rest of the footprint as few rects as a greedy cover makes
--------------------------------------------------------------------------------

local function fillRects(occupied: { Rect }, w: number, d: number): { Rect }
	local xsSet: { [number]: boolean } = { [0] = true, [w] = true }
	local zsSet: { [number]: boolean } = { [0] = true, [d] = true }
	for _, r in occupied do
		xsSet[r.x], xsSet[r.x + r.w] = true, true
		zsSet[r.z], zsSet[r.z + r.d] = true, true
	end
	local xs: { number }, zs: { number } = {}, {}
	for x in xsSet do
		if x >= -EPS and x <= w + EPS then
			table.insert(xs, x)
		end
	end
	for z in zsSet do
		if z >= -EPS and z <= d + EPS then
			table.insert(zs, z)
		end
	end
	table.sort(xs)
	table.sort(zs)
	local nx, nz = #xs - 1, #zs - 1
	local used: { boolean } = table.create(nx * nz, false)
	local function cell(i: number, j: number): number
		return (j - 1) * nx + i
	end
	for _, r in occupied do
		local i0, i1, j0, j1 = 0, 0, 0, 0
		for i = 1, nx do
			if math.abs(xs[i] - r.x) < EPS then
				i0 = i
			end
			if math.abs(xs[i + 1] - (r.x + r.w)) < EPS then
				i1 = i
			end
		end
		for j = 1, nz do
			if math.abs(zs[j] - r.z) < EPS then
				j0 = j
			end
			if math.abs(zs[j + 1] - (r.z + r.d)) < EPS then
				j1 = j
			end
		end
		for i = i0, i1 do
			for j = j0, j1 do
				if i >= 1 and j >= 1 then
					used[cell(i, j)] = true
				end
			end
		end
	end
	local out: { Rect } = {}
	for j = 1, nz do
		for i = 1, nx do
			if used[cell(i, j)] then
				continue
			end
			local i1 = i
			while i1 + 1 <= nx and not used[cell(i1 + 1, j)] do
				i1 += 1
			end
			local j1 = j
			while j1 + 1 <= nz do
				local free = true
				for k = i, i1 do
					if used[cell(k, j1 + 1)] then
						free = false
						break
					end
				end
				if not free then
					break
				end
				j1 += 1
			end
			for k = i, i1 do
				for l = j, j1 do
					used[cell(k, l)] = true
				end
			end
			table.insert(out, rect(xs[i], zs[j], xs[i1 + 1], zs[j1 + 1]))
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Plan
--------------------------------------------------------------------------------

function TunnelPlanner.plan(spec: PlanSpec): Plan
	local style = spec.style
	local rules: TunnelRules.RuleSpec = spec.rules or TunnelRules.Defaults
	local prefix = spec.prefix
	local size = WorldConfig.FootprintSize
	local attempts = spec.attempts or 4
	local target = spec.crossingTarget or (rules.crossing[1] + rules.crossing[2]) / 2

	-- 1-2. the graph, thinned: the attempt closest to the target crossing and length wins
	local best: Graph? = nil
	local bestScore = INF
	local bestCrossing = 0
	for attempt = 1, attempts do
		local random = Rng.seeded(spec.seed, string.format("%s:grid:%d", prefix, attempt))
		local g = buildGraph(spec, random)
		local walk = thin(g, spec, rules, random)
		local length = aliveLength(g)
		local score = math.abs(walk - target) / 60 + math.abs(length - style.length) / 400
		if walk < rules.crossing[1] or walk > rules.crossing[2] then
			score += 100
		end
		if walk == INF then
			score = INF
		end
		if best == nil or score < bestScore then
			best, bestScore, bestCrossing = g, score, walk
		end
	end
	if not best or bestCrossing == INF then
		error(
			string.format(
				"TunnelPlanner: %s found no layout its crawlway sites can cover in %d attempts",
				prefix,
				attempts
			)
		)
	end
	local g = best :: Graph
	local random = Rng.seeded(spec.seed, prefix .. ":dress")
	local entryId = entryNode(g)

	-- 3a. short dead ends off junctions and corners (a corridor to an unused crossing)
	local deadEnds: { number } = {}
	do
		local candidates: { GEdge } = {}
		local mouthDist = mouthDistances(g)
		for _, e in g.edges do
			if e.kind ~= "Grid" or e.alive or e.crawl or e.barred then
				continue
			end
			local root = if degree(g, e.a) > 0 then e.a else e.b
			if (mouthDist[root] or INF) + e.length > rules.crawlReach - 2 then
				continue
			end
			local da, db = degree(g, e.a), degree(g, e.b)
			if (da == 0) ~= (db == 0) and e.length <= rules.deadEndLength then
				table.insert(candidates, e)
			end
		end
		Rng.shuffle(candidates, random)
		local placed: { GNode } = {}
		for _, e in candidates do
			if #deadEnds >= style.deadEnds then
				break
			end
			local tip = if degree(g, e.a) == 0 then g.nodes[e.a] else g.nodes[e.b]
			local root = g.nodes[other(e, tip.id)]
			if tunnelDegree(g, root.id) < 2 or root.port or shortestLoop(g, root.id, rules.maxLoop) > rules.maxLoop then
				continue
			end
			local far = true
			for _, p in placed do
				if math.abs(p.x - tip.x) + math.abs(p.z - tip.z) < spec.style.pitch * 3 then
					far = false
				end
			end
			-- the tip's crossing must not sit beside another live corridor (it would share a wall)
			for _, id in g.adj[tip.id] do
				local f = g.edges[id]
				if f.alive then
					far = false
				end
			end
			if far then
				e.alive = true
				table.insert(deadEnds, tip.id)
				table.insert(placed, tip)
			end
		end
	end

	-- 3b. regions: crossings inside a region's areas belong to it; the rest to the nearest seed point by walking
	-- distance (a region never jumps a barrier), the straight-line nearest when nothing walks there; keep-rooms may
	-- name theirs
	local regionIndex: { [string]: number } = {}
	for i, region in spec.regions do
		regionIndex[region.id] = i
	end
	do
		local owner: { [number]: number } = {}
		local fixed: { [number]: boolean } = {}
		local dist: { [number]: number } = {}
		local heap: Heap = { d = {}, n = {}, size = 0 }
		for _, node in g.nodes do
			for i, region in spec.regions do
				if owner[node.id] then
					break
				end
				for _, a in region.areas or {} :: { { number } } do
					if node.x >= a[1] and node.x <= a[3] and node.z >= a[2] and node.z <= a[4] then
						owner[node.id] = i
						fixed[node.id] = true
						dist[node.id] = 0
						heapPush(heap, 0, node.id)
						break
					end
				end
			end
		end
		for i, region in spec.regions do
			local start: number? = nil
			local startD = INF
			for _, node in g.nodes do
				if degree(g, node.id) > 0 and not (fixed[node.id] and owner[node.id] ~= i) then
					local d = (region.x - node.x) ^ 2 + (region.z - node.z) ^ 2
					if d < startD then
						start, startD = node.id, d
					end
				end
			end
			if start and not fixed[start] then
				owner[start] = i
				dist[start] = 0
				heapPush(heap, 0, start)
			end
		end
		while heap.size > 0 do
			local d, v = heapPop(heap)
			if d > (dist[v] or INF) + EPS then
				continue
			end
			for _, id in g.adj[v] do
				local e = g.edges[id]
				local u = other(e, v)
				if not e.alive or fixed[u] then
					continue
				end
				local nd = d + e.length
				if nd < (dist[u] or INF) - EPS then
					dist[u] = nd
					owner[u] = owner[v]
					heapPush(heap, nd, u)
				end
			end
		end
		for _, node in g.nodes do
			local bestRegion = owner[node.id]
			if not bestRegion then
				local bestD = INF
				for i, region in spec.regions do
					local d = (region.x - node.x) ^ 2 + (region.z - node.z) ^ 2
					if d < bestD then
						bestRegion, bestD = i, d
					end
				end
			end
			node.region = bestRegion or 1
			local port = node.port
			if port and port.keep.region and regionIndex[port.keep.region] then
				node.region = regionIndex[port.keep.region]
			end
		end
	end

	-- 3c. runs: maximal straight corridors; at an X crossing the axis with the longer arms passes through
	local through: { [number]: "X" | "Z" | false } = {}
	for _, node in g.nodes do
		local a = arms(g, node.id)
		local vertical = a.N ~= nil and a.S ~= nil
		local horizontal = a.E ~= nil and a.W ~= nil
		if vertical and horizontal then
			local lx = g.edges[a.E :: number].length + g.edges[a.W :: number].length
			local lz = g.edges[a.N :: number].length + g.edges[a.S :: number].length
			through[node.id] = if lx > lz then "X" else "Z"
		elseif vertical then
			through[node.id] = "Z"
		elseif horizontal then
			through[node.id] = "X"
		else
			through[node.id] = false
		end
	end
	-- a straight run also ends where the next crossing ahead belongs to another region, so each run (one room) keeps
	-- to one region and its stencil marks the change
	local split: { [number]: boolean } = {}
	for _, node in g.nodes do
		local axis = through[node.id]
		if axis then
			local a = arms(g, node.id)
			local ahead = if axis == "X" then a.E else a.S
			local behind = if axis == "X" then a.W else a.N
			if ahead and behind then
				local next = g.nodes[other(g.edges[ahead], node.id)]
				local previous = g.nodes[other(g.edges[behind], node.id)]
				if next.region ~= node.region and previous.region == node.region then
					split[node.id] = true
				end
			end
		end
	end
	local runOfEdge: { [number]: Run } = {}
	local runs: { Run } = {}
	for _, e in g.edges do
		if not e.alive or e.kind == "Room" or runOfEdge[e.id] then
			continue
		end
		local axis: "X" | "Z" = e.axis :: any
		local nodes: { number } = { e.a, e.b }
		local edges: { number } = { e.id }
		-- extend both ways while the run passes straight through
		for _, endIndex in { 1, 2 } do
			while true do
				local v = if endIndex == 1 then nodes[1] else nodes[#nodes]
				if through[v] ~= axis or split[v] then
					break
				end
				local nextEdge: number? = nil
				for _, id in g.adj[v] do
					local f = g.edges[id]
					if f.alive and f.axis == axis and not table.find(edges, id) then
						nextEdge = id
					end
				end
				if not nextEdge then
					break
				end
				local f = g.edges[nextEdge :: number]
				local u = other(f, v)
				if endIndex == 1 then
					table.insert(nodes, 1, u)
					table.insert(edges, 1, f.id)
				else
					table.insert(nodes, u)
					table.insert(edges, f.id)
				end
			end
		end
		-- order by increasing coordinate
		local first, last = g.nodes[nodes[1]], g.nodes[nodes[#nodes]]
		if (axis == "X" and first.x > last.x) or (axis == "Z" and first.z > last.z) then
			local rn, re = {}, {}
			for i = #nodes, 1, -1 do
				table.insert(rn, nodes[i])
			end
			for i = #edges, 1, -1 do
				table.insert(re, edges[i])
			end
			nodes, edges = rn, re
		end
		local length = 0
		for _, id in edges do
			length += g.edges[id].length
		end
		local run: Run = {
			id = #runs + 1,
			axis = axis,
			nodes = nodes,
			edges = edges,
			width = pick(random, style.width),
			height = pick(random, style.height),
			gallery = false,
			rect = rect(0, 0, 0, 0),
			roomId = "",
			region = 1,
			length = length,
		}
		table.insert(runs, run)
		for _, id in edges do
			runOfEdge[id] = run
		end
	end

	-- galleries: the longest runs clear of the keep-rooms' doors, up to the share
	do
		local total = 0
		for _, run in runs do
			total += run.length
		end
		local sorted = table.clone(runs)
		table.sort(sorted, function(a: Run, b: Run): boolean
			local la, lb = sortKey(a.length), sortKey(b.length)
			if la ~= lb then
				return la > lb
			end
			return a.id < b.id
		end)
		local share = 0
		for _, run in sorted do
			if share >= style.galleryShare * total or run.length < style.galleryMin then
				break
			end
			local touchesPort = g.nodes[run.nodes[1]].port ~= nil or g.nodes[run.nodes[#run.nodes]].port ~= nil
			if touchesPort then
				continue
			end
			run.gallery = true
			run.width = style.galleryWidth
			run.height = pick(random, style.galleryHeight)
			share += run.length
		end
	end
	-- a run that ends at a port is at least as wide as the door (plus its jambs) and tall enough for it
	for _, run in runs do
		for _, v in { run.nodes[1], run.nodes[#run.nodes] } do
			local port = g.nodes[v].port
			if port then
				local kind = port.port.kind or "Door"
				local doorWidth = port.port.width
					or (if kind == "Airlock" then WorldConfig.AirlockDoorWidth else WorldConfig.DoorWidth)
				run.width = math.max(run.width, doorWidth + 1)
				local doorHeight = port.port.height or WorldConfig.DoorHeight
				run.height = math.max(run.height, doorHeight + 0.5, port.port.runHeight or 0)
			end
		end
	end
	-- regions of runs: the majority of their crossings (ties: the first), a split crossing counting for the run behind
	for _, run in runs do
		local counts: { number } = {}
		for index, v in run.nodes do
			if index == 1 and split[v] and through[v] == run.axis and #run.nodes > 1 then
				continue
			end
			local r = g.nodes[v].region
			counts[r] = (counts[r] or 0) + 1
		end
		local bestR, bestC = g.nodes[run.nodes[1]].region, 0
		for r = 1, #spec.regions do
			if (counts[r] or 0) > bestC then
				bestR, bestC = r, counts[r] or 0
			end
		end
		run.region = bestR
	end

	-- 3d. the owner of every crossing's core square, then each run's rect
	local runsAt: { [number]: { Run } } = {}
	for _, run in runs do
		for _, v in run.nodes do
			runsAt[v] = runsAt[v] or {}
			table.insert(runsAt[v], run)
		end
	end
	local owner: { [number]: Run } = {}
	for _, node in g.nodes do
		local list = runsAt[node.id]
		if not list or node.port then
			continue
		end
		local axis = through[node.id]
		local chosen: Run? = nil
		for _, run in list do
			if axis and run.axis == axis then
				local inner = run.nodes[1] ~= node.id and run.nodes[#run.nodes] ~= node.id
				if inner then
					chosen = run
				end
			end
		end
		if not chosen then
			for _, run in list do
				if chosen == nil or run.width > (chosen :: Run).width + EPS then
					chosen = run
				end
			end
		end
		owner[node.id] = chosen :: Run
	end
	local function coreHalf(v: number): number
		local o = owner[v]
		return if o then o.width / 2 else 0
	end
	for _, run in runs do
		local first, last = g.nodes[run.nodes[1]], g.nodes[run.nodes[#run.nodes]]
		local function endCoord(node: GNode, sign: number): number
			local c = if run.axis == "X" then node.x else node.z
			if node.port then
				return c
			end
			if owner[node.id] == run then
				return c + sign * run.width / 2
			end
			return c - sign * coreHalf(node.id)
		end
		local lo, hi = endCoord(first, -1), endCoord(last, 1)
		local half = run.width / 2
		if run.axis == "X" then
			run.rect = rect(lo, first.z - half, hi, first.z + half)
		else
			run.rect = rect(first.x - half, lo, first.x + half, hi)
		end
		run.roomId = string.format("%s_%s%03d", prefix, if run.gallery then "Gallery" else "Tunnel", run.id)
	end

	local occupied: { Rect } = {}
	for _, keep in spec.keepRooms do
		table.insert(occupied, keep.room.rect)
	end
	for _, r in spec.exclusions or {} :: { Rect } do
		table.insert(occupied, r)
	end
	for _, run in runs do
		if run.rect.w <= EPS or run.rect.d <= EPS then
			error(string.format("TunnelPlanner: run %d collapsed (%s)", run.id, prefix))
		end
		table.insert(occupied, run.rect)
	end

	-- the tunnel graph's sample points (for coverage while placing crawlways and hides): every 3 studs along live
	-- corridors, each tied to its run
	type Point = { x: number, z: number, run: Run?, node: number? }
	local points: { Point } = {}
	local pointLinks: { { { to: number, cost: number } } } = {}
	local nodePoint: { [number]: number } = {}
	local function addPoint(p: Point): number
		table.insert(points, p)
		table.insert(pointLinks, {})
		return #points
	end
	local function linkPoints(a: number, b: number, cost: number)
		table.insert(pointLinks[a], { to = b, cost = cost })
		table.insert(pointLinks[b], { to = a, cost = cost })
	end
	for _, node in g.nodes do
		if degree(g, node.id) > 0 then
			nodePoint[node.id] = addPoint({ x = node.x, z = node.z, node = node.id, run = owner[node.id] })
		end
	end
	for _, e in g.edges do
		if not e.alive then
			continue
		end
		if e.kind == "Room" then
			linkPoints(nodePoint[e.a], nodePoint[e.b], e.length)
			continue
		end
		local a, b = g.nodes[e.a], g.nodes[e.b]
		local n = math.max(1, math.ceil(e.length / 3))
		local previous = nodePoint[e.a]
		for k = 1, n - 1 do
			local t = k / n
			local id = addPoint({ x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t, run = runOfEdge[e.id] })
			linkPoints(previous, id, e.length / n)
			previous = id
		end
		linkPoints(previous, nodePoint[e.b], e.length / n)
	end
	-- `extra`: more links to follow from a point than its own (the crawlways, for a squad that crawls)
	type PointLinks = { [number]: { { to: number, cost: number } } }
	local function pointDistances(seeds: { { number } }, limit: number, extra: PointLinks?): { [number]: number }
		local dist: { [number]: number } = {}
		local heap: Heap = { d = {}, n = {}, size = 0 }
		for _, s in seeds do
			if s[2] < (dist[s[1]] or INF) then
				dist[s[1]] = s[2]
				heapPush(heap, s[2], s[1])
			end
		end
		local function relax(d: number, l: { to: number, cost: number })
			local nd = d + l.cost
			if nd < (dist[l.to] or INF) - EPS then
				dist[l.to] = nd
				heapPush(heap, nd, l.to)
			end
		end
		while heap.size > 0 do
			local d, v = heapPop(heap)
			if d > (dist[v] or INF) + EPS or d > limit then
				continue
			end
			for _, l in pointLinks[v] do
				relax(d, l)
			end
			for _, l in (if extra then extra[v] else nil) or {} :: { { to: number, cost: number } } do
				relax(d, l)
			end
		end
		return dist
	end
	-- the nearest sample point on a run to (x, z)
	local function nearestPoint(x: number, z: number, run: Run?): (number, number)
		local bestId, bestD = 1, INF
		for id, p in points do
			if run and p.run ~= run then
				continue
			end
			local d = math.abs(p.x - x) + math.abs(p.z - z)
			if d < bestD then
				bestId, bestD = id, d
			end
		end
		return bestId, bestD
	end
	local tunnelPoints: { number } = {}
	local isTunnelPoint: { [number]: boolean } = {}
	for id, p in points do
		local node = p.node
		if not (node and g.nodes[node].port) and not (node and g.nodes[node].entry) then
			table.insert(tunnelPoints, id)
			isTunnelPoint[id] = true
		end
	end
	-- the walk from every way in, on foot (no crawlway): the entry, then each of otherEntries (from its ports)
	local entrySeeds: { { { number } } } = { { { nodePoint[entryId], 0 } } }
	for _, roomId in spec.otherEntries or {} :: { string } do
		local seeds: { { number } } = {}
		for _, node in g.nodes do
			if node.port and node.port.keep.room.id == roomId and nodePoint[node.id] then
				table.insert(seeds, { nodePoint[node.id], 0 })
			end
		end
		if #seeds > 0 then
			table.insert(entrySeeds, seeds)
		end
	end
	local fromEntries: { { [number]: number } } = {}
	for _, seeds in entrySeeds do
		table.insert(fromEntries, pointDistances(seeds, INF))
	end
	local fromEntry = fromEntries[1]

	-- 4a. crawlways: the sites the thinning kept, re-cut low and narrow between their two crossings' cores
	type Crawl = { e: GEdge, rect: Rect, roomId: string, a: number, b: number }
	local crawls: { Crawl } = {}
	local crawlMouths: { [Crawl]: { number } } = {}
	local crawlEstimate = 0
	for _, e in g.edges do
		if not e.crawl then
			continue
		end
		local a, b = g.nodes[e.a], g.nodes[e.b]
		local ha, hb = coreHalf(e.a), coreHalf(e.b)
		local half = style.crawlWidth / 2
		local r: Rect
		if e.axis == "X" then
			local x0, x1 = math.min(a.x, b.x), math.max(a.x, b.x)
			local h0 = if a.x < b.x then ha else hb
			local h1 = if a.x < b.x then hb else ha
			r = rect(x0 + h0, a.z - half, x1 - h1, a.z + half)
		else
			local z0, z1 = math.min(a.z, b.z), math.max(a.z, b.z)
			local h0 = if a.z < b.z then ha else hb
			local h1 = if a.z < b.z then hb else ha
			r = rect(a.x - half, z0 + h0, a.x + half, z1 - h1)
		end
		local c: Crawl = { e = e, rect = r, roomId = "", a = e.a, b = e.b }
		table.insert(crawls, c)
		crawlMouths[c] = { nodePoint[e.a], nodePoint[e.b] }
	end
	do
		local seeds: { { number } } = {}
		for i, c in crawls do
			c.roomId = string.format("%s_Crawlway%02d", prefix, i)
			table.insert(occupied, c.rect)
			for _, m in crawlMouths[c] do
				table.insert(seeds, { m, 0 })
			end
		end
		local reachMap = pointDistances(seeds, INF)
		for _, id in tunnelPoints do
			crawlEstimate = math.max(crawlEstimate, reachMap[id] or INF)
		end
	end
	local crawlCandidates = #crawls
	-- the walk from every way in for a squad that takes the crawlways too (each joins its two crossings)
	local crawlLinks: PointLinks = {}
	for _, c in crawls do
		local m = crawlMouths[c]
		if m[1] and m[2] then
			crawlLinks[m[1]] = crawlLinks[m[1]] or {}
			crawlLinks[m[2]] = crawlLinks[m[2]] or {}
			table.insert(crawlLinks[m[1]], { to = m[2], cost = c.e.length })
			table.insert(crawlLinks[m[2]], { to = m[1], cost = c.e.length })
		end
	end
	local fromEntriesCrawling: { { [number]: number } } = {}
	for _, seeds in entrySeeds do
		table.insert(fromEntriesCrawling, pointDistances(seeds, INF, crawlLinks))
	end

	-- 4b. alcoves: niches beside the runs, clear of the crossings, doors and other rooms
	type Alcove = {
		run: Run,
		rect: Rect,
		side: number,
		u: number,
		roomId: string,
		use: string?,
		-- a shelf niche, a guarded shelf niche (a bay: its trap at the mouth), or a hide niche (wider and deeper: the
		-- prop stands free)
		class: "Item" | "Guard" | "Hide",
		width: number,
		depth: number,
		nx: number,
		nz: number,
		point: number, -- its own sample point inside
		runPoint: number, -- the run's sample point at its mouth
	}
	local alcoves: { Alcove } = {}
	local alcoveCandidates: { Alcove } = {}
	local function nicheCandidates(class: "Item" | "Guard" | "Hide", width: number, depth: number)
		for _, run in runs do
			local r = run.rect
			local u0 = if run.axis == "X" then r.x else r.z
			local u1 = if run.axis == "X" then r.x + r.w else r.z + r.d
			for _, side in { -1, 1 } do
				-- the crossings along the run with a corridor leaving through this side (the niche keeps clear of it),
				-- and the keep-rooms' doors (a wider berth: their swing, their signs)
				local armed: { { number } } = {}
				local maxWidth = math.max(style.galleryWidth, table.unpack(style.width))
				for _, v in run.nodes do
					local node = g.nodes[v]
					local a = arms(g, v)
					local arm = if run.axis == "X"
						then (if side < 0 then a.N else a.S)
						else (if side < 0 then a.W else a.E)
					local c = if run.axis == "X" then node.x else node.z
					if node.port then
						table.insert(armed, { c, PORT_BERTH })
					elseif arm then
						table.insert(armed, { c, maxWidth / 2 + ALCOVE_GAP })
					end
				end
				local u = u0 + width / 2 + 3
				while u <= u1 - width / 2 - 3 do
					local nearNode = false
					for _, c in armed do
						if math.abs(c[1] - u) < width / 2 + c[2] then
							nearNode = true
						end
					end
					if not nearNode then
						local niche: Rect
						local nx, nz = 0, 0
						if run.axis == "X" then
							local z = if side < 0 then r.z - depth else r.z + r.d
							niche = rect(u - width / 2, z, u + width / 2, z + depth)
							nz = side
						else
							local x = if side < 0 then r.x - depth else r.x + r.w
							niche = rect(x, u - width / 2, x + depth, u + width / 2)
							nx = side
						end
						local ok = inside(niche, rect(1, 1, size.X - 1, size.Y - 1))
						if ok then
							for _, o in occupied do
								if o ~= run.rect and overlaps(niche, o, ALCOVE_GAP) then
									ok = false
									break
								end
							end
						end
						if ok then
							-- the niche's own sample point, joined to the run's centreline through its mouth
							local mx = if run.axis == "X" then u else r.x + r.w / 2
							local mz = if run.axis == "X" then r.z + r.d / 2 else u
							local onRun = nearestPoint(mx, mz, run)
							local inner = addPoint({ x = niche.x + niche.w / 2, z = niche.z + niche.d / 2, run = run })
							linkPoints(
								onRun,
								inner,
								run.width / 2
									+ depth / 2
									+ math.abs((if run.axis == "X" then points[onRun].x else points[onRun].z) - u)
							)
							table.insert(alcoveCandidates, {
								run = run,
								rect = niche,
								side = side,
								u = u,
								roomId = "",
								class = class,
								width = width,
								depth = depth,
								nx = nx,
								nz = nz,
								point = inner,
								runPoint = onRun,
							})
						end
					end
					u += 2
				end
			end
		end
	end
	-- the item niches the floor's items need: plain shelves, guard bays (a floor without guarded items keeps only the
	-- plain ones)
	local guarded, plain = false, false
	for _, item in spec.items or {} :: { ItemSpec } do
		if item.guard then
			guarded = true
		else
			plain = true
		end
	end
	if plain or not guarded then
		nicheCandidates("Item", style.alcoveWidth, style.alcoveDepth)
	end
	if guarded then
		nicheCandidates("Guard", style.guardAlcoveWidth or GUARD_ALCOVE.X, style.guardAlcoveDepth or GUARD_ALCOVE.Y)
	end
	nicheCandidates("Hide", style.hideAlcoveWidth or 10, style.hideAlcoveDepth or 7)
	local function claimAlcove(c: Alcove, use: string): Alcove?
		for _, a in alcoves do
			if overlaps(a.rect, c.rect, ALCOVE_GAP + 1) then
				return nil
			end
		end
		for _, cr in crawls do
			if overlaps(cr.rect, c.rect, ALCOVE_GAP) then
				return nil
			end
		end
		c.use = use
		table.insert(alcoves, c)
		c.roomId = string.format("%s_Alcove%02d", prefix, #alcoves)
		table.insert(occupied, c.rect)
		return c
	end
	local function alcovePoint(c: Alcove): number
		return c.point
	end

	-- 4c. items in alcoves on shelves: spread, far enough from the entry, and only where hide niches near enough could
	-- serve them (the hides come next and must keep one within rules.objectiveHideReach)
	type ItemSpot = { kind: Enums.AnchorKind, alcove: Alcove, spec: ItemSpec }
	-- which way along its run (-1 / 1 on the run's axis) a guard bay is walked to from the nearest way in, or nil when
	-- both sides are about as near (no side the careless come from) or the squad comes from the other side once it
	-- takes the crawlways (the side must hold either way)
	local function entrySide(c: Alcove): number?
		local run = c.run
		local r = run.rect
		local reachOut = c.width / 2 + 2
		local side: number? = nil
		for _, maps in { fromEntries, fromEntriesCrawling } do
			local near: { number } = {}
			for i, sign in { -1, 1 } do
				local u = c.u + sign * reachOut
				local x = if run.axis == "X" then u else r.x + r.w / 2
				local z = if run.axis == "X" then r.z + r.d / 2 else u
				local id = nearestPoint(x, z, run)
				near[i] = INF
				for _, dist in maps do
					near[i] = math.min(near[i], dist[id] or INF)
				end
			end
			if near[1] == INF or near[2] == INF or math.abs(near[1] - near[2]) < GUARD_SIDE_MARGIN then
				return nil
			end
			local here = if near[1] < near[2] then -1 else 1
			if side and side ~= here then
				return nil
			end
			side = here
		end
		return side
	end
	local itemSpots: { ItemSpot } = {}
	-- (the planner's walk to an item: to its niche's own sample point, short of the shelf at the back)
	local function itemReach(c: Alcove): number
		return rules.objectiveHideReach - 3 - c.depth / 2
	end
	do
		local taken: { Alcove } = {}
		local served: { [Alcove]: boolean } = {}
		for _, c in alcoveCandidates do
			if c.class == "Hide" then
				continue
			end
			local reach = itemReach(c)
			local near = pointDistances({ { c.point, 0 } }, reach)
			local count = 0
			for _, h in alcoveCandidates do
				if
					h.class == "Hide"
					and (near[h.point] or INF) <= reach
					and not overlaps(h.rect, c.rect, ALCOVE_GAP + 1)
				then
					count += 1
				end
			end
			served[c] = count >= 3
		end
		local function inAreas(c: Alcove, areas: { { number } }?): boolean
			if not areas then
				return true
			end
			local cx, cz = c.rect.x + c.rect.w / 2, c.rect.z + c.rect.d / 2
			for _, a in areas do
				if cx >= a[1] and cx <= a[3] and cz >= a[2] and cz <= a[4] then
					return true
				end
			end
			return false
		end
		for _, item in spec.items or {} :: { ItemSpec } do
			local class = if item.guard then "Guard" else "Item"
			for _ = 1, item.count do
				local bestA: Alcove? = nil
				local bestScoreA = -INF
				for _, c in alcoveCandidates do
					if c.use or c.class ~= class or not served[c] or not inAreas(c, item.areas) then
						continue
					end
					if item.guard and not entrySide(c) then
						continue
					end
					local entryD = INF
					for _, dist in fromEntries do
						entryD = math.min(entryD, dist[c.runPoint] or INF)
					end
					if entryD < 60 or (fromEntry[c.runPoint] or INF) == INF then
						continue
					end
					local spread = INF
					for _, t in taken do
						spread = math.min(spread, math.abs(t.rect.x - c.rect.x) + math.abs(t.rect.z - c.rect.z))
					end
					local score = math.min(spread, 200) + random:NextNumber() * 8
					if score > bestScoreA then
						bestA, bestScoreA = c, score
					end
				end
				if not bestA then
					break
				end
				local claimed = claimAlcove(bestA :: Alcove, "Item")
				if claimed then
					table.insert(taken, claimed)
					table.insert(itemSpots, { kind = item.kind, alcove = claimed, spec = item })
				else
					(bestA :: Alcove).use = "Blocked"
				end
			end
		end
	end

	-- 4d. hides: barrels and cabinets (in alcoves, at dead ends, in corners) covering every tunnel point
	-- exit: the side (prop space -X "Left" / +X "Right") a freestanding hide's hider steps out to; nil: the front
	type Hide = {
		kind: "Barrel" | "Cabinet" | "Locker",
		x: number,
		z: number,
		yaw: number,
		room: () -> string,
		point: number,
		exit: ("Left" | "Right")?,
	}
	local hides: { Hide } = {}
	do
		local coverReach = rules.hideReach - 2.5
		local hideCovered: { [number]: boolean } = {}
		-- the points a hide must serve, each with its reach: the item niches (by their depth), the hide targets (as a
		-- plain item niche's)
		local mustCover: { number } = {}
		local mustReach: { number } = {}
		for _, s in itemSpots do
			table.insert(mustCover, alcovePoint(s.alcove))
			table.insert(mustReach, itemReach(s.alcove))
		end
		local targetReach = rules.objectiveHideReach - 3 - style.alcoveDepth / 2
		local targets: { Vector3 } = spec.hideTargets or {}
		for _, p in targets do
			local id = nearestPoint(p.X, p.Z, nil)
			table.insert(mustCover, id)
			table.insert(mustReach, targetReach)
		end
		local farthest = targetReach
		for _, reach in mustReach do
			farthest = math.max(farthest, reach)
		end
		type HideCandidate = { make: () -> Hide?, point: number, cover: { [number]: number }, fallback: boolean? }
		local candidates: { HideCandidate } = {}
		-- dead-end tips
		for _, tip in deadEnds do
			local node = g.nodes[tip]
			local run = owner[tip]
			if not run then
				continue
			end
			local edgeId = 0
			for _, id in g.adj[tip] do
				if g.edges[id].alive then
					edgeId = id
				end
			end
			local back = g.nodes[other(g.edges[edgeId], tip)]
			local dx, dz = node.x - back.x, node.z - back.z
			local l = math.sqrt(dx * dx + dz * dz)
			dx, dz = dx / l, dz / l
			-- the drum stands free of the end wall
			local reach = run.width / 2 - WALL / 2 - HIDE_BACK_GAP - HIDE_FOOTPRINT.Barrel.Y / 2
			local x = node.x + dx * reach
			local z = node.z + dz * reach
			local point = nodePoint[tip]
			table.insert(candidates, {
				point = point,
				cover = {},
				make = function(): Hide?
					return {
						kind = "Barrel",
						x = x,
						z = z,
						yaw = yawOf(-dx, -dz),
						room = function(): string
							return run.roomId
						end,
						point = point,
					}
				end,
			})
		end
		-- hide niches: the barrel or cabinet stands free in the middle, a little off the back wall, its front to the run;
		-- the hider climbs in from the front and steps out to one side (two clear sides besides the front)
		for _, c in alcoveCandidates do
			if c.use or c.class ~= "Hide" then
				continue
			end
			local point = alcovePoint(c)
			table.insert(candidates, {
				point = point,
				cover = {},
				make = function(): Hide?
					local claimed = claimAlcove(c, "Hide")
					if not claimed then
						c.use = "Blocked"
						return nil
					end
					local cx = claimed.rect.x + claimed.rect.w / 2
					local cz = claimed.rect.z + claimed.rect.d / 2
					local kinds = (spec.regions[claimed.run.region] or spec.regions[1]).hides
					if kinds and #kinds > 0 and kinds[random:NextInteger(1, #kinds)] == "Locker" then
						-- a hideable locker backed onto the niche's back wall (the locker anchors' 2.05 off the line)
						local inset = claimed.depth / 2 - LOCKER_OFFSET
						return {
							kind = "Locker",
							x = cx + claimed.nx * inset,
							z = cz + claimed.nz * inset,
							yaw = yawOf(-claimed.nx, -claimed.nz),
							room = function(): string
								return claimed.roomId
							end,
							point = point,
						}
					end
					local kind: "Barrel" | "Cabinet" = if random:NextNumber() < 0.5 then "Barrel" else "Cabinet"
					local back = claimed.depth / 2 - WALL / 2 - HIDE_BACK_GAP - HIDE_FOOTPRINT[kind].Y / 2
					return {
						kind = kind,
						x = cx + claimed.nx * back,
						z = cz + claimed.nz * back,
						yaw = yawOf(-claimed.nx, -claimed.nz),
						room = function(): string
							return claimed.roomId
						end,
						point = point,
						exit = if random:NextNumber() < 0.5 then "Left" else "Right",
					}
				end,
			})
		end
		-- steel cabinets standing against the side walls of the wider runs (a fallback where no alcove fits)
		for _, run in runs do
			if run.width < 7 then
				continue
			end
			local r = run.rect
			local lo = if run.axis == "X" then r.x else r.z
			local hi = if run.axis == "X" then r.x + r.w else r.z + r.d
			local u = lo + 4
			while u <= hi - 4 do
				local nearNode = false
				for _, v in run.nodes do
					local node = g.nodes[v]
					local c = if run.axis == "X" then node.x else node.z
					if math.abs(c - u) < run.width / 2 + 4.5 then
						nearNode = true
					end
				end
				if not nearNode then
					for _, side in { -1, 1 } do
						local wallC: number
						if run.axis == "X" then
							wallC = if side < 0 then r.z else r.z + r.d
						else
							wallC = if side < 0 then r.x else r.x + r.w
						end
						local t = if wallC < EPS or wallC > (if run.axis == "X" then size.Y else size.X) - EPS
							then EXTERIOR
							else WALL
						local inset = -side * (t / 2 + 0.95)
						local x = if run.axis == "X" then u else wallC + inset
						local z = if run.axis == "X" then wallC + inset else u
						local yaw = if run.axis == "X"
							then (if side < 0 then 180 else 0)
							else (if side < 0 then -90 else 90)
						local point = nearestPoint(x, z, run)
						local uu = u
						table.insert(candidates, {
							point = point,
							cover = {},
							make = function(): Hide?
								-- never two in one stretch, never across a crawlway or alcove mouth
								for _, h in hides do
									if math.abs(h.x - x) + math.abs(h.z - z) < 8 then
										return nil
									end
								end
								for _, a in alcoves do
									if overlaps(a.rect, rect(x - 2, z - 2, x + 2, z + 2), 0.5) then
										return nil
									end
								end
								for _, c in crawls do
									if overlaps(c.rect, rect(x - 2, z - 2, x + 2, z + 2), 0.5) then
										return nil
									end
								end
								local _ = uu
								return {
									kind = "Cabinet",
									x = x,
									z = z,
									yaw = yaw,
									room = function(): string
										return run.roomId
									end,
									point = point,
								}
							end,
							fallback = true,
						})
					end
				end
				u += 6
			end
		end
		for _, c in candidates do
			c.cover = pointDistances({ { c.point, 0 } }, math.max(coverReach, farthest))
		end
		local function covers(c: HideCandidate, id: number, reach: number): boolean
			local d = c.cover[id]
			return d ~= nil and d <= reach
		end
		local mustDone: { [number]: boolean } = {}
		local used: { [HideCandidate]: boolean } = {}
		local guard = 0
		while guard < 200 do
			guard += 1
			local bestC: HideCandidate? = nil
			local bestGain = 0
			for _, c in candidates do
				if used[c] then
					continue
				end
				local gain = 0
				for id, d in c.cover do
					if d <= coverReach and isTunnelPoint[id] and not hideCovered[id] then
						gain += 1
					end
				end
				for i, id in mustCover do
					if not mustDone[i] and covers(c, id, mustReach[i]) then
						gain += 25
					end
				end
				if c.fallback and gain > 0 then
					gain *= 0.3 -- a niche serves better: the prop stands free there and keeps the corridor clear
				end
				if gain > bestGain then
					bestC, bestGain = c, gain
				end
			end
			if not bestC then
				break
			end
			local c = bestC :: HideCandidate
			used[c] = true
			local hide = c.make()
			if hide then
				table.insert(hides, hide)
				for id, d in c.cover do
					if d <= coverReach then
						hideCovered[id] = true
					end
				end
				for i, id in mustCover do
					if covers(c, id, mustReach[i]) then
						mustDone[i] = true
					end
				end
			end
		end
	end

	-- 5a. rooms
	local rooms: { Room } = {}
	local doors: { Door } = {}
	local anchors: { Anchor } = {}
	local triggers: { Trigger } = {}
	local platforms: { Platform } = {}
	local roomRegion: { [string]: string } = {}
	local portRooms: { [string]: string } = {}
	local regions = spec.regions
	local function regionOf(index: number): RegionSpec
		return regions[index] or regions[1]
	end
	local function tunnelRoom(id: string, kind: Enums.RoomKind, r: Rect, height: number, region: RegionSpec): Room
		local acoustic: Enums.AcousticPreset = if kind == "Gallery"
			then style.galleryAcoustic
			elseif kind == "Crawlway" then style.crawlAcoustic
			else style.acoustic
		local room: Room = {
			id = id,
			kind = kind,
			rect = r,
			height = height,
			floor = region.floor or style.floor,
			wall = region.wall or style.wall,
			ceiling = style.ceiling,
			surface = "Concrete",
			acoustic = acoustic,
			lights = {},
		}
		table.insert(rooms, room)
		roomRegion[id] = region.id
		return room
	end
	local roomOfRun: { [Run]: Room } = {}
	for _, run in runs do
		roomOfRun[run] = tunnelRoom(
			run.roomId,
			if run.gallery then "Gallery" else "Tunnel",
			run.rect,
			run.height,
			regionOf(run.region)
		)
	end
	local roomById: { [string]: Room } = {}
	for _, room in rooms do
		roomById[room.id] = room
	end
	for _, c in crawls do
		local region = regionOf(g.nodes[c.a].region)
		local room = tunnelRoom(c.roomId, "Crawlway", c.rect, CRAWL_HEIGHT, region)
		roomById[room.id] = room
	end
	for _, c in alcoves do
		local room = tunnelRoom(c.roomId, "Tunnel", c.rect, style.alcoveHeight, regionOf(c.run.region))
		roomById[room.id] = room
	end

	-- 5b. doors: at every crossing each run that does not own the core opens into its owner; ports; crawlways; alcoves
	local function doorBetween(
		id: string,
		kind: Enums.DoorKind,
		a: Room,
		b: Room,
		height: number?,
		width: number?,
		crawlOnly: boolean?
	)
		local edge = LayoutSchema.sharedEdge(a.rect, b.rect)
		if not edge then
			error(string.format("TunnelPlanner: %s and %s do not touch for door %s", a.id, b.id, id))
		end
		local span = edge.to - edge.from
		local w = math.min(width or (span - 1), span - 1)
		local minH = math.min(a.height or spec.height, b.height or spec.height)
		local h = math.min(height or (minH - 0.5), minH - 0.5)
		local door: Door = {
			id = id,
			kind = kind,
			rooms = { a.id, b.id },
			at = (edge.from + edge.to) / 2,
			width = w,
			height = h,
			crawlOnly = crawlOnly,
			clearance = h,
		}
		table.insert(doors, door)
		return door
	end
	local doorCount = 0
	local function nextDoorId(): string
		doorCount += 1
		return string.format("%s_Tunnel_Door%03d", prefix, doorCount)
	end
	for _, node in g.nodes do
		local list = runsAt[node.id]
		if not list then
			continue
		end
		if node.port then
			local run = list[1]
			local keep = node.port.keep
			local port = node.port.port
			local kind: Enums.DoorKind = port.kind or "Door"
			local width = port.width or (if kind == "Airlock" then WorldConfig.AirlockDoorWidth else nil)
			local door = doorBetween(
				node.port.doorId,
				kind,
				roomOfRun[run],
				keep.room,
				port.height or WorldConfig.DoorHeight,
				width
			)
			-- a keep-room's real door keeps its default width (the run is wide enough for it)
			if kind ~= "Doorway" and not port.width then
				door.width = nil
			end
			portRooms[node.port.doorId] = run.roomId
			continue
		end
		local o = owner[node.id]
		for _, run in list do
			if run ~= o then
				doorBetween(nextDoorId(), "Doorway", roomOfRun[run], roomOfRun[o])
			end
		end
	end
	for _, c in crawls do
		local room = roomById[c.roomId]
		local ends: { Run } = { owner[c.a], owner[c.b] }
		for _, run in ends do
			doorBetween(nextDoorId(), "Doorway", room, roomOfRun[run], TunnelRules.CrawlClearance, nil, true)
		end
	end
	for _, c in alcoves do
		doorBetween(nextDoorId(), "Doorway", roomById[c.roomId], roomOfRun[c.run], nil, c.width - 1)
	end

	-- 5c. solid fill
	local fills = fillRects(occupied, size.X, size.Y)
	for i, r in ipairs(fills) do
		table.insert(rooms, {
			id = string.format("%s_Solid%03d", prefix, i),
			kind = "Solid",
			rect = r,
			-- the walls against it rise as high as the room on their other side (none above a tunnel's ceiling)
			height = 1,
			wall = style.wall,
			floor = style.floor,
		})
	end

	-- helpers over the result
	local function roomAt(x: number, z: number): string
		for _, room in rooms do
			if room.kind ~= "Solid" and LayoutSchema.rectContains(room.rect, x, z, 0.05) then
				return room.id
			end
		end
		for _, keep in spec.keepRooms do
			if LayoutSchema.rectContains(keep.room.rect, x, z, 0.05) then
				return keep.room.id
			end
		end
		error(string.format("TunnelPlanner: no tunnel room holds (%.1f, %.1f)", x, z))
	end
	local anchorCounts: { [string]: number } = {}
	local function anchor(
		kind: Enums.AnchorKind,
		x: number,
		y: number,
		z: number,
		yaw: number?,
		id: string?,
		ref: string?
	): Anchor
		local n = (anchorCounts[kind] or 0) + 1
		anchorCounts[kind] = n
		local a: Anchor = {
			id = id or string.format("%s_%s_T%02d", prefix, kind, n),
			kind = kind,
			room = roomAt(x, z),
			pos = Vector3.new(x, y, z),
			yaw = yaw,
			ref = ref,
		}
		table.insert(anchors, a)
		return a
	end

	-- 5d. lights: caged bulbs along every run (deadShare of them dead), wired in local circuits
	local lightIndex = 0
	local function addLight(
		room: Room,
		kind: Enums.LightKind,
		x: number,
		y: number,
		z: number,
		options: { [string]: any }
	)
		lightIndex += 1
		local list = room.lights :: { Light }
		table.insert(list, {
			id = string.format("%s_TLight_%03d", prefix, lightIndex),
			kind = kind,
			pos = Vector3.new(x, y, z),
			brightness = options.brightness,
			range = options.range,
			color = options.color,
			flickerGroup = options.flicker,
			broken = options.broken,
			cage = options.cage,
		})
	end
	-- every run's bulbs are wired in local circuits of up to CIRCUIT_FIXTURES neighbours, each its own group (so a
	-- flicker, the Creature's teleport warning, touches only the bulbs near it): "Mains:<prefix>_<region>_<nn>" burns
	-- steady, a bad circuit (flickerShare of them) "Circuit:<prefix>_<region>_<nn>" flickers; the power switch holds
	-- both down until the breaker is thrown
	local lightRandom = Rng.seeded(spec.seed, prefix .. ":lights")
	local circuitCount = 0
	for _, run in runs do
		local room = roomOfRun[run]
		local r = run.rect
		local u0 = if run.axis == "X" then r.x else r.z
		local u1 = if run.axis == "X" then r.x + r.w else r.z + r.d
		local region = regionOf(run.region)
		local spots: { number } = {}
		local u = u0 + lightRandom:NextNumber(3, 7)
		while u < u1 - 2 do
			table.insert(spots, u)
			u += lightRandom:NextNumber(style.lightSpacing[1], style.lightSpacing[2])
		end
		local circuits = math.max(1, math.ceil(#spots / CIRCUIT_FIXTURES))
		local names: { string } = {}
		for k = 1, circuits do
			circuitCount += 1
			local bad = lightRandom:NextNumber() < style.flickerShare
			names[k] =
				string.format("%s:%s_%s_%02d", if bad then "Circuit" else "Mains", prefix, region.id, circuitCount)
		end
		for i, at in spots do
			local x = if run.axis == "X" then at else r.x + r.w / 2
			local z = if run.axis == "X" then r.z + r.d / 2 else at
			addLight(room, "Bulb", x, run.height - 0.4, z, {
				brightness = if run.gallery then 0.5 else 0.42,
				range = if run.gallery then 16 else 13,
				broken = lightRandom:NextNumber() < style.deadShare,
				flicker = names[math.min(circuits, math.floor((i - 1) * circuits / #spots) + 1)],
				cage = true,
			})
		end
	end

	-- 5e. junctions: plates (by walking order from the entry), emergency reds at some
	type Junction = { node: GNode, distance: number, plate: string }
	local junctions: { Junction } = {}
	for _, node in g.nodes do
		if node.port or node.entry then
			continue
		end
		local a = arms(g, node.id)
		local count = 0
		for _ in a do
			count += 1
		end
		if count >= 3 then
			table.insert(junctions, { node = node, distance = fromEntry[nodePoint[node.id]] or INF, plate = "" })
		end
	end
	table.sort(junctions, function(x: Junction, y: Junction): boolean
		local dx, dy = sortKey(x.distance), sortKey(y.distance)
		if dx ~= dy then
			return dx < dy
		end
		return x.node.id < y.node.id
	end)
	local landmarks: { TunnelRules.Landmark } = {}
	local function landmark(
		kind: TunnelRules.LandmarkKind,
		region: RegionSpec,
		room: string,
		pos: Vector3,
		normal: Vector3,
		text: string,
		w: number,
		h: number,
		yaw: number?
	)
		table.insert(landmarks, {
			id = string.format("%s_%s_%02d", prefix, kind, #landmarks + 1),
			kind = kind,
			region = region.id,
			room = room,
			pos = pos,
			normal = normal,
			text = text,
			width = w,
			height = h,
			yaw = yaw,
		})
	end
	-- the inner face of a run's wall on its `side` (-1: low coordinate, +1: high) at `u` along it
	local function wallFace(run: Run, side: number, u: number, y: number): (Vector3, Vector3)
		local r = run.rect
		if run.axis == "X" then
			local z = if side < 0 then r.z else r.z + r.d
			local t = if z < EPS or z > size.Y - EPS then EXTERIOR else WALL
			return Vector3.new(u, y, z - side * (t / 2 + 0.02)), Vector3.new(0, 0, -side)
		end
		local x = if side < 0 then r.x else r.x + r.w
		local t = if x < EPS or x > size.X - EPS then EXTERIOR else WALL
		return Vector3.new(x - side * (t / 2 + 0.02), y, u), Vector3.new(-side, 0, 0)
	end
	-- spans along each run's side walls that openings (doors) or other paint already take
	local busy: { [string]: { { number } } } = {}
	local function busyKey(run: Run, side: number): string
		return run.roomId .. (if side < 0 then "-" else "+")
	end
	local function markBusy(run: Run, side: number, u0: number, u1: number)
		local key = busyKey(run, side)
		busy[key] = busy[key] or {}
		table.insert(busy[key], { u0, u1 })
	end
	local function isFree(run: Run, side: number, u0: number, u1: number): boolean
		local r = run.rect
		local lo = if run.axis == "X" then r.x else r.z
		local hi = if run.axis == "X" then r.x + r.w else r.z + r.d
		if u0 < lo + 1 or u1 > hi - 1 then
			return false
		end
		for _, span in busy[busyKey(run, side)] or {} :: { { number } } do
			if u1 > span[1] - 0.5 and u0 < span[2] + 0.5 then
				return false
			end
		end
		return true
	end
	-- doors along runs' sides are busy
	for _, door in doors do
		for _, run in runs do
			local room = roomOfRun[run]
			if door.rooms[1] ~= room.id and door.rooms[2] ~= room.id then
				continue
			end
			local otherId = if door.rooms[1] == room.id then door.rooms[2] else door.rooms[1]
			local otherRoom = roomById[otherId]
			if not otherRoom then
				for _, keep in spec.keepRooms do
					if keep.room.id == otherId then
						otherRoom = keep.room
					end
				end
			end
			if not otherRoom then
				continue
			end
			local edge = LayoutSchema.sharedEdge(room.rect, otherRoom.rect)
			if not edge then
				continue
			end
			local r = run.rect
			local side: number? = nil
			if run.axis == "X" and edge.axis == "Z" then
				side = if math.abs(edge.coord - r.z) < EPS then -1 else 1
			elseif run.axis == "Z" and edge.axis == "X" then
				side = if math.abs(edge.coord - r.x) < EPS then -1 else 1
			end
			if side then
				local half = (door.width or WorldConfig.DoorWidth) / 2
				markBusy(run, side, door.at - half - 0.6, door.at + half + 0.6)
			end
		end
	end
	-- a vestibule's fire door swings into the end of its run, and its STAIRS sign (SignageBuilder) needs the side walls
	-- just past the swing: no junction plate there, nor the emergency lamp over one (wall lamps block a sign's spot)
	local berths: { [Run]: { { number } } } = {}
	for _, node in g.nodes do
		local port = node.port
		if not (port and port.port.kind == "Airlock") then
			continue
		end
		local run = (runsAt[node.id] or {})[1]
		if not run then
			continue
		end
		local c = if run.axis == "X" then node.x else node.z
		local inward = if c <= (if run.axis == "X" then run.rect.x else run.rect.z) + EPS then 1 else -1
		local far = c + inward * FIRE_DOOR_BERTH
		berths[run] = berths[run] or {}
		table.insert(berths[run], { math.min(c, far), math.max(c, far) })
	end
	local function plateFree(run: Run, side: number, u0: number, u1: number): boolean
		for _, span in berths[run] or {} :: { { number } } do
			if u1 > span[1] and u0 < span[2] then
				return false
			end
		end
		return isFree(run, side, u0, u1)
	end
	for i, j in junctions do
		j.plate = string.format("J-%02d", i)
		j.node.region = j.node.region
		local o = owner[j.node.id]
		local a = arms(g, j.node.id)
		local region = regionOf(j.node.region)
		-- a wall of the core square with no corridor leaving it, else the owner's side wall past the core
		local placed = false
		local sides: { { any } } = if o.axis == "X" then { { "N", -1 }, { "S", 1 } } else { { "W", -1 }, { "E", 1 } }
		local c = if o.axis == "X" then j.node.x else j.node.z
		for _, entry in sides do
			local dir: Dir, side: number = entry[1], entry[2]
			if a[dir] == nil and plateFree(o, side, c - 1.4, c + 1.4) then
				local pos, normal = wallFace(o, side, c, PLATE_Y)
				landmark("JunctionPlate", region, o.roomId, pos, normal, j.plate, 2.4, 1.2)
				markBusy(o, side, c - 1.4, c + 1.4)
				placed = true
				break
			end
		end
		if not placed then
			for _, offset in { 1, -1 } do
				if placed then
					break
				end
				for _, entry in sides do
					local side: number = entry[2]
					local u = c + offset * (o.width / 2 + 2.6)
					if plateFree(o, side, u - 1.4, u + 1.4) then
						local pos, normal = wallFace(o, side, u, PLATE_Y)
						landmark("JunctionPlate", region, o.roomId, pos, normal, j.plate, 2.4, 1.2)
						markBusy(o, side, u - 1.4, u + 1.4)
						placed = true
						break
					end
				end
			end
		end
		if not placed then
			-- hang it from the owner's ceiling over the crossing, facing along the run
			local pos = Vector3.new(j.node.x, o.height - 1.6, j.node.z)
			local normal = if o.axis == "X" then Vector3.new(1, 0, 0) else Vector3.new(0, 0, 1)
			landmark("JunctionPlate", region, o.roomId, pos, normal, j.plate, 2.4, 1.2)
		end
		if i % style.plateLampEvery == 1 or style.plateLampEvery <= 1 then
			local lm = landmarks[#landmarks]
			local p = lm.pos + lm.normal * 0.6
			local lampY = math.min(o.height - 0.8, PLATE_Y + 2.2)
			addLight(roomOfRun[o], "EmergencyRed", p.X, lampY, p.Z, {
				brightness = 0.45,
				range = 18,
				color = Color3.fromRGB(255, 34, 18),
			})
		end
	end

	-- 5f. region stencils where a corridor crosses into another region (on the new region's side)
	local signed: { [string]: boolean } = {}
	for _, e in g.edges do
		if not e.alive or e.kind ~= "Grid" then
			continue
		end
		local ra, rb = g.nodes[e.a].region, g.nodes[e.b].region
		if ra == rb then
			continue
		end
		for _, pair in { { e.a, e.b }, { e.b, e.a } } do
			local into = g.nodes[pair[2]]
			local from = g.nodes[pair[1]]
			local region = regionOf(into.region)
			local key = region.id .. ":" .. e.id
			if signed[key] then
				continue
			end
			local run = runOfEdge[e.id]
			local dirU = if run.axis == "X" then (into.x - from.x) else (into.z - from.z)
			local sign = if dirU > 0 then 1 else -1
			local cInto = if run.axis == "X" then into.x else into.z
			local u = cInto - sign * (coreHalf(into.id) + 4.2)
			for _, side in { -1, 1 } do
				if isFree(run, side, u - 3.2, u + 3.2) then
					local pos, normal = wallFace(run, side, u, SIGN_Y)
					landmark("RegionSign", region, run.roomId, pos, normal, string.upper(region.name), 6, 1.6)
					markBusy(run, side, u - 3.2, u + 3.2)
					signed[key] = true
					break
				end
			end
		end
	end
	-- keep-room names beside their doors (tunnel side)
	for _, node in g.nodes do
		local port = node.port
		if not port or not port.keep.sign then
			continue
		end
		local run = (runsAt[node.id] or {})[1]
		if not run then
			continue
		end
		local c = if run.axis == "X" then node.x else node.z
		local sign = if c <= (if run.axis == "X" then run.rect.x else run.rect.z) + EPS then 1 else -1
		local u = c + sign * 4.5
		for _, side in { -1, 1 } do
			if isFree(run, side, u - 2.8, u + 2.8) then
				local pos, normal = wallFace(run, side, u, SIGN_Y - 0.6)
				landmark(
					"RegionSign",
					regionOf(node.region),
					run.roomId,
					pos,
					normal,
					port.keep.sign :: string,
					5.2,
					1.3
				)
				markBusy(run, side, u - 2.8, u + 2.8)
				break
			end
		end
	end

	-- 5g. graffiti: lore lines, tallies, tags and arrows toward the exits
	local graffitiRandom = Rng.seeded(spec.seed, prefix .. ":graffiti")
	local function paintOn(
		run: Run,
		kind: TunnelRules.LandmarkKind,
		text: string,
		w: number,
		h: number,
		y: number,
		yaw: number?
	): boolean
		local r = run.rect
		local lo = if run.axis == "X" then r.x else r.z
		local hi = if run.axis == "X" then r.x + r.w else r.z + r.d
		for _ = 1, 8 do
			local side = if graffitiRandom:NextNumber() < 0.5 then -1 else 1
			local u = graffitiRandom:NextNumber(lo + w / 2 + 1, math.max(lo + w / 2 + 1, hi - w / 2 - 1))
			if isFree(run, side, u - w / 2, u + w / 2) then
				local pos, normal = wallFace(run, side, u, y)
				landmark(kind, regionOf(run.region), run.roomId, pos, normal, text, w, h, yaw)
				markBusy(run, side, u - w / 2, u + w / 2)
				return true
			end
		end
		return false
	end
	-- arrows: at some junctions, on the arm that leads toward the nearest exit
	do
		local exitSeeds: { { number } } = {}
		for _, id in exitNodes(g, spec) do
			table.insert(exitSeeds, { nodePoint[id], 0 })
		end
		local toExit = pointDistances(exitSeeds, INF)
		for i, j in junctions do
			if i % 2 == 0 then
				continue
			end
			local bestArm: string? = nil
			local bestD = INF
			local jArms = arms(g, j.node.id)
			for _, dir in DIRS do
				local id = jArms[dir]
				if id then
					local u = other(g.edges[id], j.node.id)
					local d = toExit[nodePoint[u]] or INF
					if d < bestD - EPS then
						bestArm, bestD = dir, d
					end
				end
			end
			if not bestArm then
				continue
			end
			local e = g.edges[jArms[bestArm :: string]]
			local run = runOfEdge[e.id]
			local dirSign = if bestArm == "E" or bestArm == "S" then 1 else -1
			local c = if run.axis == "X" then j.node.x else j.node.z
			local u = c + dirSign * (coreHalf(j.node.id) + 5)
			for _, side in { -1, 1 } do
				if isFree(run, side, u - 1.6, u + 1.6) then
					local pos, normal = wallFace(run, side, u, 4.6)
					-- the arrow points along the run toward the exit, drawn in the wall plane: +1 right as seen
					local rightX, rightZ = -normal.Z, normal.X
					local along = if run.axis == "X" then Vector2.new(dirSign, 0) else Vector2.new(0, dirSign)
					local yaw = if along.X * rightX + along.Y * rightZ > 0 then 0 else 180
					landmark("Arrow", regionOf(run.region), run.roomId, pos, normal, "EXIT", 3.2, 1.4, yaw)
					markBusy(run, side, u - 1.6, u + 1.6)
					break
				end
			end
		end
	end
	-- lore and tallies per region
	for index, region in regions do
		local regionRuns: { Run } = {}
		for _, run in runs do
			if run.region == index and run.length >= 14 then
				table.insert(regionRuns, run)
			end
		end
		if #regionRuns == 0 then
			continue
		end
		for k, text in region.graffiti do
			local run = regionRuns[((k * 7 + index) % #regionRuns) + 1]
			paintOn(run, "Lore", text, math.clamp(#text * 0.42, 3, 7.5), 1.8, graffitiRandom:NextNumber(3.6, 5.6))
		end
		for k = 1, 2 do
			local run = regionRuns[((k * 5 + index * 3) % #regionRuns) + 1]
			paintOn(
				run,
				"Tally",
				string.rep("I", graffitiRandom:NextInteger(4, 9)),
				2.4,
				1.2,
				graffitiRandom:NextNumber(2.4, 4.2)
			)
			local tagRun = regionRuns[((k * 11 + index) % #regionRuns) + 1]
			paintOn(tagRun, "Tag", region.id, 3.4, 1.6, graffitiRandom:NextNumber(2.2, 5))
		end
	end
	-- crawlway mouths: "IT CAN'T FIT" beside one end of each
	for _, c in crawls do
		local o = owner[c.a]
		local mouth = points[(crawlMouths[c] :: { number })[1]]
		local cc = if o.axis == "X" then mouth.x else mouth.z
		for _, side in { -1, 1 } do
			local u = cc + side * (style.crawlWidth / 2 + 2.6)
			local placed = false
			for _, wallSide in { -1, 1 } do
				if isFree(o, wallSide, u - 2.2, u + 2.2) then
					local pos, normal = wallFace(o, wallSide, u, 5.2)
					landmark("Lore", regionOf(o.region), o.roomId, pos, normal, "IT CAN'T FIT", 4.4, 1.5)
					markBusy(o, wallSide, u - 2.2, u + 2.2)
					placed = true
					break
				end
			end
			if placed then
				break
			end
		end
	end

	-- 6. anchors: hides, items (with guard traps), waypoints, spawns, traps, batteries, dressing; triggers
	for _, hide in hides do
		local tag = if hide.kind == "Locker" then "T" else "" -- (the keep-rooms' lockers are the layout's own)
		local id = string.format("%s_%s_%s%02d", prefix, hide.kind, tag, (anchorCounts[hide.kind] or 0) + 1)
		anchor(hide.kind, hide.x, 0, hide.z, hide.yaw, id).exit = hide.exit
	end
	local trapPoints: { Vector2 } = {}
	local function trapFree(x: number, z: number): boolean
		for _, p in trapPoints do
			if (p - Vector2.new(x, z)).Magnitude < 6.5 then
				return false
			end
		end
		return true
	end
	local itemCount: { [string]: number } = {}
	for _, s in itemSpots do
		local c = s.alcove
		local r = c.rect
		-- a shelf on the alcove's back wall; the item on it
		local backX = if c.nx > 0 then r.x + r.w - WALL / 2 elseif c.nx < 0 then r.x + WALL / 2 else nil
		local backZ = if c.nz > 0 then r.z + r.d - WALL / 2 elseif c.nz < 0 then r.z + WALL / 2 else nil
		local cx, cz
		if s.spec.wall then
			-- a hook on the back wall's face, at the niche's middle
			cx = if backX then backX else r.x + r.w / 2
			cz = if backZ then backZ else r.z + r.d / 2
		else
			local shelfDepth = 1.4
			local shelf: Rect
			if backX then
				local x0 = if c.nx > 0 then backX - shelfDepth else backX
				shelf = rect(x0, r.z + 1, x0 + shelfDepth, r.z + r.d - 1)
			else
				local z0 = if c.nz > 0 then (backZ :: number) - shelfDepth else backZ :: number
				shelf = rect(r.x + 1, z0, r.x + r.w - 1, z0 + shelfDepth)
			end
			table.insert(platforms, {
				id = string.format("%s_Shelf_%s", prefix, c.roomId),
				room = c.roomId,
				rect = shelf,
				top = s.spec.shelf,
				thickness = 0.3,
				material = "MetalRust",
			})
			cx, cz = shelf.x + shelf.w / 2, shelf.z + shelf.d / 2
		end
		local guardId: string? = nil
		if s.spec.guard then
			-- on the approach: just inside the bay's mouth (in the niche, with the item), toward the side the squad comes
			-- along the run from: walked straight in round the near jamb, it springs; a careful player steps round its far
			-- side to the shelf
			local run = c.run
			local rr = run.rect
			local mouth = if run.axis == "X"
				then (if c.nz > 0 then rr.z + rr.d else rr.z)
				else (if c.nx > 0 then rr.x + rr.w else rr.x)
			local aside = (entrySide(c) or 0) * GUARD_ASIDE
			local gx, gz
			if run.axis == "X" then
				gx = c.u + aside
				gz = mouth + c.nz * GUARD_IN
			else
				gz = c.u + aside
				gx = mouth + c.nx * GUARD_IN
			end
			itemCount[s.kind] = (itemCount[s.kind] or 0) + 1
			local n = itemCount[s.kind]
			local guard = anchor("TrapCandidate", gx, 0, gz, nil, string.format("%s_TrapGuard_T%02d", prefix, n))
			guardId = guard.id
			table.insert(trapPoints, Vector2.new(gx, gz))
		end
		local itemId = string.format("%s_%s_T%02d", prefix, s.kind, (anchorCounts[s.kind] or 0) + 1)
		local placed = anchor(s.kind, cx, s.spec.shelf, cz, yawOf(-c.nx, -c.nz), itemId, guardId)
		placed.room = c.roomId
	end
	-- patrol loops: per region, its junctions in a nearest-neighbour tour
	for index, region in regions do
		local list: { GNode } = {}
		for _, j in junctions do
			if j.node.region == index then
				table.insert(list, j.node)
			end
		end
		if #list < 3 then
			-- a region with fewer than three junctions makes up its loop with its turns and passes
			for _, node in g.nodes do
				if
					node.region == index
					and degree(g, node.id) == 2
					and not node.port
					and not node.entry
					and #list < 3
				then
					table.insert(list, node)
				end
			end
		end
		if #list < 2 then
			continue
		end
		local tour: { GNode } = { list[1] }
		local left: { GNode } = {}
		for i = 2, #list do
			table.insert(left, list[i])
		end
		while #left > 0 do
			local last = tour[#tour]
			local dist = pointDistances({ { nodePoint[last.id], 0 } }, INF)
			local bestI, bestD = 1, INF
			for i, node in left do
				local d = dist[nodePoint[node.id]] or INF
				if d < bestD then
					bestI, bestD = i, d
				end
			end
			table.insert(tour, table.remove(left, bestI) :: GNode)
		end
		-- long hops (the walk to the next junction, the way back to the first) get the crossings between as waypoints
		local route: { GNode } = {}
		for k, node in tour do
			table.insert(route, node)
			local path = nodePath(g, node.id, tour[(k % #tour) + 1].id)
			local cumulative: { number } = { 0 }
			for i = 2, #path do
				cumulative[i] = cumulative[i - 1] + edgeBetween(g, path[i - 1], path[i]).length
			end
			local last = 0
			local passed: number? = nil -- the last crossing walked by since the last waypoint
			for i = 2, #path - 1 do
				local here = g.nodes[path[i]]
				local crossingHere = here.gx ~= nil and not here.port
				if cumulative[i + 1] - last > PATROL_HOP then
					if crossingHere then
						table.insert(route, here)
						last = cumulative[i]
						passed = nil
						continue
					elseif passed then
						-- through a keep-room (its doors are no waypoints): the crossing before it
						table.insert(route, g.nodes[path[passed]])
						last = cumulative[passed]
						passed = nil
					end
				end
				if crossingHere then
					passed = i
				end
			end
		end
		for k, node in route do
			anchor("PatrolWaypoint", node.x, 0, node.z, nil, string.format("%s_WP_%s_%02d", prefix, region.id, k))
		end
	end
	-- creature spawns: points on the tunnels in the band walked from the entry (with a margin either side), spread out
	do
		local band = spec.creatureBand
		local sources = fromEntries
		local share = math.ceil(spec.creatureSpawns / #sources)
		local picked: { Point } = {}
		for _, dist in sources do
			local candidates: { Point } = {}
			for _, id in tunnelPoints do
				local d = dist[id] or INF
				local p = points[id]
				if d >= band[1] + 5 and d <= band[2] - 5 and p.run and not table.find(picked, p) then
					table.insert(candidates, p)
				end
			end
			local wanted = math.min(spec.creatureSpawns, #picked + share)
			while #picked < wanted and #candidates > 0 do
				local bestI, bestScore2 = 1, -INF
				for i, p in candidates do
					local spread = INF
					for _, q in picked do
						spread = math.min(spread, math.abs(p.x - q.x) + math.abs(p.z - q.z))
					end
					local score = math.min(spread, 150) + (if p.node then 4 else 0)
					if score > bestScore2 then
						bestI, bestScore2 = i, score
					end
				end
				table.insert(picked, table.remove(candidates, bestI) :: Point)
			end
		end
		for k, p in picked do
			local run = p.run :: Run
			-- facing along the tunnel
			local face = if run.axis == "X" then -90 else 180
			anchor(
				"CreatureSpawn",
				round2(p.x),
				5,
				round2(p.z),
				face,
				string.format("%s_CreatureSpawn_%02d", prefix, k)
			)
		end
	end
	-- traps: on corridors that lie on a loop (never the only way), clear of doorways, at least 6.5 apart
	do
		local onLoop: { [number]: boolean } = {}
		for _, e in g.edges do
			if e.alive and e.kind == "Grid" then
				onLoop[e.id] = dijkstra(g, e.a, 400, e.id)[e.b] ~= nil
			end
		end
		local slots: { Vector2 } = {}
		for _, e in g.edges do
			if not (e.alive and onLoop[e.id]) then
				continue
			end
			local run = runOfEdge[e.id]
			if run.gallery and random:NextNumber() < 0.5 then
				continue
			end
			local a, b = g.nodes[e.a], g.nodes[e.b]
			local ha, hb = coreHalf(e.a) + 3, coreHalf(e.b) + 3
			local length = e.length
			if length - ha - hb < 2 then
				continue
			end
			local t = (ha + random:NextNumber() * (length - ha - hb)) / length
			local offset = (random:NextNumber() * 2 - 1) * math.max(0, run.width / 2 - 2)
			local x = a.x + (b.x - a.x) * t + (if e.axis == "Z" then offset else 0)
			local z = a.z + (b.z - a.z) * t + (if e.axis == "X" then offset else 0)
			table.insert(slots, Vector2.new(x, z))
		end
		Rng.shuffle(slots, random)
		local placed = 0
		for _, p in slots do
			if placed >= spec.traps then
				break
			end
			if trapFree(p.X, p.Y) and (fromEntry[nearestPoint(p.X, p.Y, nil)] or 0) > 30 then
				anchor("TrapCandidate", round2(p.X), 0, round2(p.Y))
				table.insert(trapPoints, p)
				placed += 1
			end
		end
	end
	-- batteries, drips, clutter, corpses: spread over the runs
	local function spotsAlong(count: number, wallSide: boolean, y: number, kind: Enums.AnchorKind, faceWall: boolean?)
		local done = 0
		local guard = 0
		while done < count and guard < count * 20 do
			guard += 1
			local run = runs[random:NextInteger(1, #runs)]
			if run.length < 12 then
				continue
			end
			local r = run.rect
			local lo = if run.axis == "X" then r.x else r.z
			local hi = if run.axis == "X" then r.x + r.w else r.z + r.d
			local u = random:NextNumber(lo + 3, hi - 3)
			local side = if random:NextNumber() < 0.5 then -1 else 1
			local across = if wallSide then side * (run.width / 2 - 1.3) else 0
			local x = if run.axis == "X" then u else r.x + r.w / 2 + across
			local z = if run.axis == "X" then r.z + r.d / 2 + across else u
			local yaw = if faceWall
				then (if run.axis == "X" then (if side < 0 then 0 else 180) else (if side < 0 then 90 else -90))
				else random:NextNumber(-180, 180)
			anchor(kind, round2(x), y, round2(z), math.floor(yaw + 0.5))
			done += 1
		end
	end
	spotsAlong(spec.batteries, true, 0, "BatteryCandidate")
	spotsAlong(spec.clutter, true, 0, "Clutter")
	-- corpses slumped against the walls of the galleries and the widest tunnels
	do
		local wide: { Run } = {}
		for _, run in runs do
			if run.width >= 8 and run.length >= 20 then
				table.insert(wide, run)
			end
		end
		local done = 0
		local guard = 0
		while done < spec.corpses and #wide > 0 and guard < 40 do
			guard += 1
			local run = wide[random:NextInteger(1, #wide)]
			local r = run.rect
			local lo = if run.axis == "X" then r.x else r.z
			local hi = if run.axis == "X" then r.x + r.w else r.z + r.d
			local u = random:NextNumber(lo + 6, hi - 6)
			local side = if random:NextNumber() < 0.5 then -1 else 1
			-- slumped against a bare stretch of wall: never across a doorway, a niche or a crawlway's mouth
			if not isFree(run, side, u - 3.5, u + 3.5) then
				continue
			end
			markBusy(run, side, u - 3.5, u + 3.5)
			local across = side * (run.width / 2 - 1.6)
			local x = if run.axis == "X" then u else r.x + r.w / 2 + across
			local z = if run.axis == "X" then r.z + r.d / 2 + across else u
			local yaw = if run.axis == "X" then (if side < 0 then 180 else 0) else (if side < 0 then -90 else 90)
			anchor("Corpse", round2(x), 0, round2(z), yaw)
			done += 1
		end
	end
	do
		local done = 0
		for _, run in runs do
			if done >= spec.drips then
				break
			end
			if run.length >= 36 and not run.gallery and random:NextNumber() < 0.5 then
				-- the leak hangs on the run's centre line, as near its middle as the ceiling bulbs allow
				local r = run.rect
				local lo = if run.axis == "X" then r.x else r.z
				local hi = if run.axis == "X" then r.x + r.w else r.z + r.d
				local lights = roomOfRun[run].lights :: { Light }
				local spot: number? = nil
				for step = 0, math.floor((hi - lo) / 2 - 8) * 2 do
					local u = (lo + hi) / 2 + (if step % 2 == 0 then 1 else -1) * math.ceil(step / 2) * 0.5
					local clear = true
					for _, l in lights do
						local lu = if run.axis == "X" then l.pos.X else l.pos.Z
						if math.abs(lu - u) < 3.5 then
							clear = false
							break
						end
					end
					if clear then
						spot = u
						break
					end
				end
				if spot then
					local x = if run.axis == "X" then spot :: number else r.x + r.w / 2
					local z = if run.axis == "X" then r.z + r.d / 2 else spot :: number
					anchor("DripPipe", round2(x), run.height - 1.2, round2(z))
					done += 1
				end
			end
		end
	end
	-- debris and scare steps across some runs
	local triggerCount = 0
	local function triggerAcross(kind: Enums.TriggerKind, count: number)
		local done = 0
		local guard = 0
		while done < count and guard < count * 20 do
			guard += 1
			local run = runs[random:NextInteger(1, #runs)]
			if run.length < 16 or run.gallery then
				continue
			end
			local r = run.rect
			local lo = if run.axis == "X" then r.x else r.z
			local hi = if run.axis == "X" then r.x + r.w else r.z + r.d
			local long = if kind == "ScareStep" then 8 else 5
			if hi - lo < long + 8 then
				continue
			end
			local u = round2(random:NextNumber(lo + 4, hi - long - 4))
			local tr = if run.axis == "X"
				then rect(u, r.z + 0.6, u + long, r.z + r.d - 0.6)
				else rect(r.x + 0.6, u, r.x + r.w - 0.6, u + long)
			if (fromEntry[nearestPoint(tr.x + tr.w / 2, tr.z + tr.d / 2, run)] or 0) < 40 then
				continue
			end
			triggerCount += 1
			table.insert(triggers, {
				id = string.format("%s_Trigger_%s%02d", prefix, kind, done + 1),
				kind = kind,
				room = run.roomId,
				rect = tr,
				height = if kind == "FloorDebris" then 4 else 6,
			})
			done += 1
		end
	end
	triggerAcross("FloorDebris", spec.debris)
	triggerAcross("ScareStep", spec.scares)

	-- 7. the tunnel data
	local tNodes: { TunnelRules.TunnelNode } = {}
	local tEdges: { TunnelRules.TunnelEdge } = {}
	local nodeName: { [number]: string } = {}
	local plateOf: { [number]: string } = {}
	for _, j in junctions do
		plateOf[j.node.id] = j.plate
	end
	local deadSet: { [number]: boolean } = {}
	for _, id in deadEnds do
		deadSet[id] = true
	end
	for _, node in g.nodes do
		if degree(g, node.id) == 0 and not node.terminal then
			continue
		end
		local name = if node.port
			then "Port:" .. node.port.doorId
			elseif node.entry then "Entry"
			else string.format("N%d_%d", node.gx or 0, node.gz or 0)
		nodeName[node.id] = name
		local count = 0
		for _ in arms(g, node.id) do
			count += 1
		end
		local kind: TunnelRules.TunnelNodeKind = if node.port or node.entry
			then "Port"
			elseif deadSet[node.id] then "End"
			elseif count >= 3 then "Junction"
			elseif count == 2 and through[node.id] then "Pass"
			elseif count == 2 then "Turn"
			else "End"
		local o = owner[node.id]
		table.insert(tNodes, {
			id = name,
			x = node.x,
			z = node.z,
			kind = kind,
			region = regionOf(node.region).id,
			room = if o then o.roomId elseif node.port then node.port.keep.room.id else spec.entry,
			plate = plateOf[node.id],
		})
	end
	for _, e in g.edges do
		if not e.alive then
			continue
		end
		local run = runOfEdge[e.id]
		table.insert(tEdges, {
			a = nodeName[e.a],
			b = nodeName[e.b],
			length = e.length,
			kind = if e.kind == "Room" then "Room" elseif run and run.gallery then "Gallery" else "Tunnel",
			room = if run then run.roomId else nil,
		})
	end
	for _, c in crawls do
		table.insert(tEdges, {
			a = nodeName[c.a],
			b = nodeName[c.b],
			length = c.e.length,
			kind = "Crawlway",
			room = c.roomId,
		})
	end
	local segments: { TunnelRules.TunnelSegment } = {}
	for _, run in runs do
		local first, last = g.nodes[run.nodes[1]], g.nodes[run.nodes[#run.nodes]]
		table.insert(segments, {
			room = run.roomId,
			kind = if run.gallery then "Gallery" else "Tunnel",
			region = regionOf(run.region).id,
			ax = if run.axis == "X" then math.max(first.x, run.rect.x + 0.5) else first.x,
			az = if run.axis == "Z" then math.max(first.z, run.rect.z + 0.5) else first.z,
			bx = if run.axis == "X" then math.min(last.x, run.rect.x + run.rect.w - 0.5) else last.x,
			bz = if run.axis == "Z" then math.min(last.z, run.rect.z + run.rect.d - 0.5) else last.z,
			width = run.width,
			height = run.height,
		})
	end
	for _, c in crawls do
		local r = c.rect
		local alongX = r.w >= r.d
		table.insert(segments, {
			room = c.roomId,
			kind = "Crawlway",
			region = roomRegion[c.roomId],
			ax = if alongX then r.x else r.x + r.w / 2,
			az = if alongX then r.z + r.d / 2 else r.z,
			bx = if alongX then r.x + r.w else r.x + r.w / 2,
			bz = if alongX then r.z + r.d / 2 else r.z + r.d,
			width = style.crawlWidth,
			height = CRAWL_HEIGHT,
		})
	end
	for _, c in alcoves do
		local r = c.rect
		table.insert(segments, {
			room = c.roomId,
			kind = "Alcove",
			region = roomRegion[c.roomId],
			ax = r.x + r.w / 2,
			az = r.z + r.d / 2,
			bx = r.x + r.w / 2,
			bz = r.z + r.d / 2,
			width = c.width,
			height = style.alcoveHeight,
		})
	end
	local tRegions: { TunnelRules.TunnelRegion } = {}
	for index, region in regions do
		local regionRooms: { string } = {}
		for _, room in rooms do
			if roomRegion[room.id] == region.id then
				table.insert(regionRooms, room.id)
			end
		end
		for _, keep in spec.keepRooms do
			local port = keep.ports[1]
			local reg = keep.region
			if reg == region.id then
				table.insert(regionRooms, keep.room.id)
				roomRegion[keep.room.id] = region.id
			elseif not reg and port then
				-- the region of its first port's node
				for _, node in g.nodes do
					if node.port and node.port.keep == keep and node.region == index then
						table.insert(regionRooms, keep.room.id)
						roomRegion[keep.room.id] = region.id
						break
					end
				end
			end
		end
		local regionJunctions: { string } = {}
		for _, j in junctions do
			if j.node.region == index then
				table.insert(regionJunctions, j.plate)
			end
		end
		table.insert(tRegions, {
			id = region.id,
			name = region.name,
			pipe = region.pipe,
			band = region.band,
			grime = region.grime,
			paint = region.paint,
			graffiti = region.graffiti,
			wall = region.wall,
			floor = region.floor,
			wet = region.wet,
			medium = region.medium,
			rooms = regionRooms,
			junctions = regionJunctions,
		})
	end
	local keepIds: { string } = {}
	for _, keep in spec.keepRooms do
		table.insert(keepIds, keep.room.id)
	end
	local tunnels: TunnelRules.TunnelData = {
		seed = spec.seed,
		entry = spec.entry,
		exits = spec.exits,
		keepRooms = keepIds,
		regions = tRegions,
		nodes = tNodes,
		edges = tEdges,
		segments = segments,
		landmarks = landmarks,
		roomRegion = roomRegion,
		rules = rules,
	}
	local runLength = 0
	for _, run in runs do
		runLength += run.length
	end
	local stats = {
		crossing = bestCrossing,
		length = runLength,
		runs = #runs,
		junctions = #junctions,
		crawlways = #crawls,
		alcoves = #alcoves,
		hides = #hides,
		deadEnds = #deadEnds,
		solids = #fills,
		triggers = triggerCount,
		crawlEstimate = crawlEstimate,
		crawlCandidates = crawlCandidates,
	}
	tunnels.stats = stats
	return {
		rooms = rooms,
		doors = doors,
		anchors = anchors,
		triggers = triggers,
		platforms = platforms,
		tunnels = tunnels,
		portRooms = portRooms,
		stats = stats,
	}
end

return table.freeze(TunnelPlanner)
