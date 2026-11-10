--!strict
-- FloorNav: the Creature's floor pathfinding on a level's zone graph (docs/MONSTER.md 5 and 10; the website's
-- web/src/creature/nav.js, rule for rule). Built from the level's layout: its rooms and the door portals between them
-- (Doorway / Door / Ajar / RoofDoor / Gate / Airlock; Boarded doors are planked shut and give no portal).
--
-- The agent is CreatureConfig.PathAgent (radius 2, its hunched height 9, no jumping or climbing). A route is A* over
-- the portals (each door's opening on the shared wall, from LayoutSchema.sharedEdge and the door's `at` / width), then
-- string-pulled (the funnel algorithm) through each opening narrowed by the agent radius, entering and leaving it
-- square to the wall, so every waypoint keeps the agent clear of the jambs. Rooms are convex rectangles, so a straight
-- leg inside one never meets a wall. Fixture doors (the Hallway Gate, airlock doors, the roof door) are passable only
-- while open (the doorOpen hook); classroom doors stand open with MonsterPassthrough leaves, doorways are open arches.
--
-- Inside a room the Default-group fixtures of the layout stand in the way (its `platforms` taller than the walker steps
-- up and lower than its head: HVAC units, boilers, bleachers; and its `pillars`): every straight leg of the route is cut
-- where it crosses from room to room, and a piece that meets one of those footprints (grown by the agent radius) is
-- replaced by the shortest way round it inside its room (Dijkstra over the grown footprints' corners). Footprints
-- holding the start or the goal do not block.
--
-- Tunnels. The Creature never enters a crawlway or a duct: rooms of kind Crawlway / Chase (and a tunnel floor's Solid
-- fill) give it no floor, and a portal that is crawl-only (LayoutSchema.doorCrawlOnly) or lower than its hunched height
-- (LayoutSchema.doorClearance) is shut to it. clearanceAt: the head room at a point (its room's height, or a portal's
-- clearance within PORTAL_REACH of the opening); the brain hunches under CreatureConfig.HunchBelow.
-- pathLength(from, to) is the walking distance of a route (math.huge without one); samplePoints() is a lattice of free
-- floor points over the walkable rooms; reachable(from) tells which points a walk from `from` can get to through the
-- portals open now (a level may fall apart into parts joined only by locked airlocks or ducts).
--
-- Pools. A basin's water is no floor (the Creature enters and leaves the water only by a warp): a room a basin lies in
-- keeps only the deck round it, as up to four strips (west and east the room's full depth, north and south between
-- them; one narrower than MIN_DECK is left out), each a node of its own (`key`; `id` stays the room's), joined where
-- they meet. A door opens onto the strip it lies on, none onto the water. So no route crosses the pool.
--
-- Pure (tests/Specs/FloorNav.spec.luau): new, funnel, spaced, deckParts, crossesRect, aroundIn, sharedEdge.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BinaryHeap = require(ReplicatedStorage.Shared.Util.BinaryHeap)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

export type NavRoom = {
	id: string, -- the layout room's
	key: string, -- the node in the route graph: the room's id, or "<id>#<side>" for one strip of a pool's deck
	kind: string,
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	floorY: number,
	height: number,
}

export type Portal = {
	id: string,
	kind: string,
	a: string, -- room keys
	b: string,
	axis: "X" | "Z",
	coord: number,
	u0: number,
	u1: number,
	mid: Vector3,
	scripted: boolean,
	clearance: number,
}

export type Obstacle = { id: string, minX: number, maxX: number, minZ: number, maxZ: number }

export type Rect = { minX: number, maxX: number, minZ: number, maxZ: number }

export type Edge = { axis: "X" | "Z", coord: number, from: number, to: number }

export type Sample = { position: Vector3, room: string }

export type Route = { waypoints: { Vector3 } }

export type Nav = {
	levelId: string,
	rooms: { NavRoom },
	roomByKey: { [string]: NavRoom },
	partsOf: { [string]: { NavRoom } },
	portals: { Portal },
	portalsOf: { [string]: { Portal } },
	obstacles: { Obstacle },
	minClearance: number,
	open: (self: Nav, portal: Portal) -> boolean,
	roomAt: (self: Nav, p: Vector3) -> NavRoom?,
	nearestRoom: (self: Nav, p: Vector3) -> NavRoom?,
	clearanceAt: (self: Nav, p: Vector3) -> number,
	reachable: (self: Nav, from: Vector3) -> (point: Vector3) -> boolean,
	computePath: (self: Nav, from: Vector3, to: Vector3) -> Route?,
	pathLength: (self: Nav, from: Vector3, to: Vector3) -> number,
	samplePoints: (self: Nav, spacing: number?) -> { Sample },
}

local PASSABLE: { [string]: boolean } =
	{ Doorway = true, Door = true, Ajar = true, RoofDoor = true, Gate = true, Airlock = true }
local NO_FLOOR: { [string]: boolean } = { Chase = true, Crawlway = true, Solid = true }
local NO_SAMPLES: { [string]: boolean } =
	{ Airlock = true, Chase = true, Stairwell = true, Crawlway = true, Pool = true }
local SCRIPTED: { [string]: boolean } = { Gate = true, Airlock = true, RoofDoor = true }
local SAMPLE_INSET = 2.5
local PORTAL_REACH = 3 -- within this of a portal's opening its clearance counts
local EPS = 1e-3
local RADIUS = CreatureConfig.PathAgent.AgentRadius
local AGENT_HEIGHT = CreatureConfig.PathAgent.AgentHeight
local CLEARANCE = RADIUS + 0.25 -- a footprint grows by this for the agent
local WALL_CLEARANCE = RADIUS + WorldConfig.WallThickness / 2 -- a detour corner stays this far inside its room
local INTERIOR = 0.01 -- footprints shrink by this for the crossing test, so legs along their edges are clear
local MAX_SPLITS = 24
local SPACING = CreatureConfig.PathAgent.WaypointSpacing
local MIN_DECK = 2 -- a deck strip narrower than this beside a pool is no floor
local STEP_UP = 1.6 -- ledges the walker steps up
local CELL = 16 -- the room index's grid
local NO_ROOMS: { NavRoom } = {}
local NO_PORTALS: { Portal } = {}

local FloorNav = {}

FloorNav.PortalReach = PORTAL_REACH
FloorNav.StepUp = STEP_UP

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

-- The wall two touching rects share (axis "X": constant X, running along Z), with the stretch [from, to] along it.
function FloorNav.sharedEdge(a: Rect, b: Rect): Edge?
	local z0, z1 = math.max(a.minZ, b.minZ), math.min(a.maxZ, b.maxZ)
	local x0, x1 = math.max(a.minX, b.minX), math.min(a.maxX, b.maxX)
	if z1 - z0 > EPS then
		if math.abs(a.maxX - b.minX) < EPS then
			return { axis = "X", coord = a.maxX, from = z0, to = z1 }
		end
		if math.abs(a.minX - b.maxX) < EPS then
			return { axis = "X", coord = a.minX, from = z0, to = z1 }
		end
	end
	if x1 - x0 > EPS then
		if math.abs(a.maxZ - b.minZ) < EPS then
			return { axis = "Z", coord = a.maxZ, from = x0, to = x1 }
		end
		if math.abs(a.minZ - b.maxZ) < EPS then
			return { axis = "Z", coord = a.minZ, from = x0, to = x1 }
		end
	end
	return nil
end

local function insideRect(r: Rect, x: number, z: number): boolean
	return x > r.minX and x < r.maxX and z > r.minZ and z < r.maxZ
end

-- Whether the segment (ax, az) -> (bx, bz) runs through the inside of `r` (shrunk by INTERIOR).
function FloorNav.crossesRect(r: Rect, ax: number, az: number, bx: number, bz: number): boolean
	local t0, t1 = 0, 1
	local o = { ax, az }
	local d = { bx - ax, bz - az }
	local lo = { r.minX + INTERIOR, r.minZ + INTERIOR }
	local hi = { r.maxX - INTERIOR, r.maxZ - INTERIOR }
	for k = 1, 2 do
		if math.abs(d[k]) < 1e-9 then
			if o[k] <= lo[k] or o[k] >= hi[k] then
				return false
			end
			continue
		end
		local u = (lo[k] - o[k]) / d[k]
		local v = (hi[k] - o[k]) / d[k]
		if u > v then
			u, v = v, u
		end
		t0 = math.max(t0, u)
		t1 = math.min(t1, v)
		if t1 - t0 <= 1e-9 then
			return false
		end
	end
	return true
end

local function blocked(obstacles: { Obstacle }, ax: number, az: number, bx: number, bz: number): boolean
	for _, o in obstacles do
		if FloorNav.crossesRect(o, ax, az, bx, bz) then
			return true
		end
	end
	return false
end

-- The floor of `room` round the pools in it: { room } when no basin lies in it, else the deck strips round each basin.
function FloorNav.deckParts(room: NavRoom, basins: { Rect }): { NavRoom }
	local parts = { room }
	for _, b in basins do
		local nextParts: { NavRoom } = {}
		for _, p in parts do
			if
				not (
					b.minX < p.maxX - EPS
					and b.maxX > p.minX + EPS
					and b.minZ < p.maxZ - EPS
					and b.maxZ > p.minZ + EPS
				)
			then
				table.insert(nextParts, p)
				continue
			end
			local x0 = math.max(p.minX, b.minX)
			local x1 = math.min(p.maxX, b.maxX)
			local function strip(side: string, minX: number, maxX: number, minZ: number, maxZ: number)
				if maxX - minX >= MIN_DECK and maxZ - minZ >= MIN_DECK then
					table.insert(nextParts, {
						id = p.id,
						key = p.key .. "#" .. side,
						kind = p.kind,
						minX = minX,
						maxX = maxX,
						minZ = minZ,
						maxZ = maxZ,
						floorY = p.floorY,
						height = p.height,
					})
				end
			end
			strip("W", p.minX, x0, p.minZ, p.maxZ)
			strip("E", x1, p.maxX, p.minZ, p.maxZ)
			strip("N", x0, x1, p.minZ, math.max(p.minZ, b.minZ))
			strip("S", x0, x1, math.min(p.maxZ, b.maxZ), p.maxZ)
		end
		parts = nextParts
	end
	return parts
end

type Segment = { p: Vector3, q: Vector3 }

-- The two funnel segments crossing `portal` out of `room`: the opening narrowed by the agent radius, set back by the
-- radius into the room it leaves and out into the room it enters (so the route meets the wall square on).
local function crossing(portal: Portal, room: NavRoom): { Segment }
	local inward: number
	if portal.axis == "X" then
		inward = if room.minX < portal.coord - EPS then -1 else 1
	else
		inward = if room.minZ < portal.coord - EPS then -1 else 1
	end
	local u0 = portal.u0 + RADIUS
	local u1 = portal.u1 - RADIUS
	if u1 < u0 then
		local m = (portal.u0 + portal.u1) / 2
		u0, u1 = m, m
	end
	local y = portal.mid.Y
	local function at(offset: number, u: number): Vector3
		if portal.axis == "X" then
			return Vector3.new(portal.coord + offset, y, u)
		end
		return Vector3.new(u, y, portal.coord + offset)
	end
	local back = inward * RADIUS
	return { { p = at(back, u0), q = at(back, u1) }, { p = at(-back, u0), q = at(-back, u1) } }
end

-- Twice the signed area of the triangle a, b, c in the XZ plane (Recast's triarea2 on x / z).
local function triarea2(a: Vector3, b: Vector3, c: Vector3): number
	local ax, az = b.X - a.X, b.Z - a.Z
	local bx, bz = c.X - a.X, c.Z - a.Z
	return bx * az - ax * bz
end

local function same(a: Vector3, b: Vector3): boolean
	return math.abs(a.X - b.X) < 1e-6 and math.abs(a.Z - b.Z) < 1e-6
end

local function midpoint(s: Segment): Vector3
	return Vector3.new((s.p.X + s.q.X) / 2, s.p.Y, (s.p.Z + s.q.Z) / 2)
end

-- The simple stupid funnel algorithm (Mononen) over portal segments: the string-pulled route from `start` to `goal`
-- through every segment. Returns the points after the start, ending at the goal.
function FloorNav.funnel(start: Vector3, goal: Vector3, segments: { Segment }): { Vector3 }
	local lefts: { Vector3 } = { start }
	local rights: { Vector3 } = { start }
	local prev = start
	for i, s in segments do
		local nextPoint = if i < #segments then midpoint(segments[i + 1]) else goal
		local dx, dz = nextPoint.X - prev.X, nextPoint.Z - prev.Z
		local mid = midpoint(s)
		local function side(pt: Vector3): number
			return dx * (pt.Z - mid.Z) - dz * (pt.X - mid.X)
		end
		if side(s.p) > side(s.q) then
			table.insert(lefts, s.p)
			table.insert(rights, s.q)
		else
			table.insert(lefts, s.q)
			table.insert(rights, s.p)
		end
		prev = mid
	end
	table.insert(lefts, goal)
	table.insert(rights, goal)
	local path: { Vector3 } = {}
	local apex = start
	local left, right = lefts[1], rights[1]
	local apexIndex, leftIndex, rightIndex = 1, 1, 1
	local i = 2
	local guard = 0
	while i <= #lefts do
		guard += 1
		if guard > 4096 then
			break
		end
		local pl, pr = lefts[i], rights[i]
		local restarted = false
		if triarea2(apex, right, pr) <= 0 then
			if same(apex, right) or triarea2(apex, left, pr) > 0 then
				right = pr
				rightIndex = i
			else
				table.insert(path, left)
				apex = left
				apexIndex = leftIndex
				left, right = apex, apex
				leftIndex, rightIndex = apexIndex, apexIndex
				i = apexIndex + 1
				restarted = true
			end
		end
		if not restarted and triarea2(apex, left, pl) >= 0 then
			if same(apex, left) or triarea2(apex, right, pl) < 0 then
				left = pl
				leftIndex = i
			else
				table.insert(path, right)
				apex = right
				apexIndex = rightIndex
				left, right = apex, apex
				leftIndex, rightIndex = apexIndex, apexIndex
				i = apexIndex + 1
				restarted = true
			end
		end
		if not restarted then
			i += 1
		end
	end
	local out: { Vector3 } = {}
	for _, p in path do
		if not same(p, start) and (#out == 0 or not same(out[#out], p)) then
			table.insert(out, p)
		end
	end
	if #out == 0 or not same(out[#out], goal) then
		table.insert(out, goal)
	end
	return out
end

-- The route as a walker follows it: a waypoint every `spacing` studs along each leg, every turn kept.
function FloorNav.spaced(from: Vector3, points: { Vector3 }, spacing: number?): { Vector3 }
	local step = spacing or SPACING
	local out: { Vector3 } = {}
	local a = from
	for _, b in points do
		local length = math.sqrt((b.X - a.X) ^ 2 + (b.Z - a.Z) ^ 2)
		local steps = math.floor(length / step - 1e-6)
		for k = 1, steps do
			local t = k * step / length
			table.insert(out, Vector3.new(a.X + (b.X - a.X) * t, b.Y, a.Z + (b.Z - a.Z) * t))
		end
		table.insert(out, b)
		a = b
	end
	return out
end

-- The shortest way from `p` to `q` inside `room` round the footprints: the corners it turns at, in order (nil when
-- there is none). Rooms are convex, so a leg between two points kept off its walls never leaves it.
function FloorNav.aroundIn(room: Rect, obstacles: { Obstacle }, p: Vector3, q: Vector3): { Vector3 }?
	local minX, maxX = room.minX + WALL_CLEARANCE, room.maxX - WALL_CLEARANCE
	local minZ, maxZ = room.minZ + WALL_CLEARANCE, room.maxZ - WALL_CLEARANCE
	local near: { Obstacle } = {}
	for _, o in obstacles do
		if o.maxX > room.minX and o.minX < room.maxX and o.maxZ > room.minZ and o.minZ < room.maxZ then
			table.insert(near, o)
		end
	end
	local nodes: { Vector2 } = { Vector2.new(p.X, p.Z), Vector2.new(q.X, q.Z) }
	for _, o in near do
		for _, c in { { o.minX, o.minZ }, { o.maxX, o.minZ }, { o.maxX, o.maxZ }, { o.minX, o.maxZ } } do
			local x, z = c[1], c[2]
			if x < minX or x > maxX or z < minZ or z > maxZ then
				continue
			end
			local buried = false
			for _, other in near do
				if other ~= o and insideRect(other, x, z) then
					buried = true
				end
			end
			if not buried then
				table.insert(nodes, Vector2.new(x, z))
			end
		end
	end
	local n = #nodes
	local dist: { number } = table.create(n, math.huge)
	local prev: { number } = table.create(n, 0)
	local done: { boolean } = table.create(n, false)
	dist[1] = 0
	for _ = 1, n do
		local u = 0
		for i = 1, n do
			if not done[i] and (u == 0 or dist[i] < dist[u]) then
				u = i
			end
		end
		if u == 0 or dist[u] == math.huge or u == 2 then
			break
		end
		done[u] = true
		for v = 1, n do
			if done[v] or v == u then
				continue
			end
			local a, b = nodes[u], nodes[v]
			local d = dist[u] + (b - a).Magnitude
			if d >= dist[v] - 1e-9 or blocked(near, a.X, a.Y, b.X, b.Y) then
				continue
			end
			dist[v] = d
			prev[v] = u
		end
	end
	if dist[2] == math.huge then
		return nil
	end
	local way: { Vector3 } = {}
	local at = prev[2]
	while at > 1 do
		table.insert(way, 1, Vector3.new(nodes[at].X, p.Y, nodes[at].Y))
		at = prev[at]
	end
	return way
end

-- The parameter along a -> b where it leaves the rectangle of `room` (a inside).
local function exitParameter(room: Rect, a: Vector3, b: Vector3): number
	local t = math.huge
	local dx, dz = b.X - a.X, b.Z - a.Z
	if dx > 1e-9 then
		t = math.min(t, (room.maxX - a.X) / dx)
	elseif dx < -1e-9 then
		t = math.min(t, (room.minX - a.X) / dx)
	end
	if dz > 1e-9 then
		t = math.min(t, (room.maxZ - a.Z) / dz)
	elseif dz < -1e-9 then
		t = math.min(t, (room.minZ - a.Z) / dz)
	end
	return t
end

--------------------------------------------------------------------------------
-- The level's obstacles
--------------------------------------------------------------------------------

-- The layout's Default-group footprints inside rooms, in world space: platforms whose top is above what the walker
-- steps up and whose underside the agent cannot pass beneath, and the pillars.
function FloorNav.levelObstacles(layout: LayoutSchema.LevelLayout, origin: Vector3, agentHeight: number?): { Obstacle }
	local head = agentHeight or AGENT_HEIGHT
	local out: { Obstacle } = {}
	for _, p in layout.platforms or {} :: { LayoutSchema.Platform } do
		local r = p.rect
		if not (p.top > STEP_UP) then
			continue
		end
		if p.top - p.thickness >= head then
			continue
		end
		table.insert(out, {
			id = p.id,
			minX = origin.X + r.x,
			maxX = origin.X + r.x + r.w,
			minZ = origin.Z + r.z,
			maxZ = origin.Z + r.z + r.d,
		})
	end
	for i, p in layout.pillars or {} :: { LayoutSchema.Pillar } do
		local half = p.size / 2
		table.insert(out, {
			id = "Pillar_" .. i,
			minX = origin.X + p.x - half,
			maxX = origin.X + p.x + half,
			minZ = origin.Z + p.z - half,
			maxZ = origin.Z + p.z + half,
		})
	end
	return out
end

--------------------------------------------------------------------------------
-- The nav
--------------------------------------------------------------------------------

-- A level's nav. `doorOpen(doorId)` says whether a fixture door lets the Creature through now; `minClearance` is its
-- hunched height (lower portals are shut to it; default PathAgent.AgentHeight).
function FloorNav.new(
	layout: LayoutSchema.LevelLayout,
	origin: Vector3,
	doorOpen: (doorId: string) -> boolean,
	minClearance: number?
): Nav
	local nav = {} :: Nav
	nav.levelId = layout.id
	nav.minClearance = minClearance or AGENT_HEIGHT
	nav.rooms = {}
	nav.roomByKey = {}
	nav.partsOf = {}
	nav.portals = {}
	nav.portalsOf = {}
	local basins: { Rect } = {}
	for _, b in layout.basins or {} :: { LayoutSchema.Basin } do
		local r = b.rect
		table.insert(basins, {
			minX = origin.X + r.x,
			maxX = origin.X + r.x + r.w,
			minZ = origin.Z + r.z,
			maxZ = origin.Z + r.z + r.d,
		})
	end
	for _, room in layout.rooms do
		if NO_FLOOR[room.kind] then
			continue
		end
		local r = room.rect
		local nr: NavRoom = {
			id = room.id,
			key = room.id,
			kind = room.kind,
			minX = origin.X + r.x,
			maxX = origin.X + r.x + r.w,
			minZ = origin.Z + r.z,
			maxZ = origin.Z + r.z + r.d,
			floorY = origin.Y,
			height = LayoutSchema.roomHeight(layout, room),
		}
		local parts = FloorNav.deckParts(nr, basins)
		nav.partsOf[room.id] = parts
		for _, part in parts do
			table.insert(nav.rooms, part)
			nav.roomByKey[part.key] = part
			nav.portalsOf[part.key] = {}
		end
	end

	local function addPortal(
		id: string,
		kind: string,
		a: NavRoom,
		b: NavRoom,
		edge: Edge,
		u0: number,
		u1: number,
		scripted: boolean,
		clearance: number
	)
		local um = (u0 + u1) / 2
		local mid = if edge.axis == "X"
			then Vector3.new(edge.coord, a.floorY, um)
			else Vector3.new(um, a.floorY, edge.coord)
		local portal: Portal = {
			id = id,
			kind = kind,
			a = a.key,
			b = b.key,
			axis = edge.axis,
			coord = edge.coord,
			u0 = u0,
			u1 = u1,
			mid = mid,
			scripted = scripted,
			clearance = clearance,
		}
		table.insert(nav.portals, portal)
		table.insert(nav.portalsOf[a.key], portal)
		table.insert(nav.portalsOf[b.key], portal)
	end

	for _, door in layout.doors do
		if not PASSABLE[door.kind] then
			continue
		end
		local clearance = LayoutSchema.doorClearance(layout, door)
		-- crawl-only, or too low even hunched: never its way
		if LayoutSchema.doorCrawlOnly(layout, door) or clearance < nav.minClearance then
			continue
		end
		local width = LayoutSchema.doorWidth(door)
		for _, a in nav.partsOf[door.rooms[1]] or NO_ROOMS do
			for _, b in nav.partsOf[door.rooms[2]] or NO_ROOMS do
				local edge = FloorNav.sharedEdge(a, b)
				if not edge then
					continue
				end
				local at = door.at + (if edge.axis == "X" then origin.Z else origin.X)
				local u0 = math.max(at - width / 2, edge.from)
				local u1 = math.min(at + width / 2, edge.to)
				if u1 - u0 < EPS then
					continue
				end
				addPortal(door.id, door.kind, a, b, edge, u0, u1, SCRIPTED[door.kind] == true, clearance)
			end
		end
	end
	-- the strips of a deck join where they meet, round the pool's corners
	for _, parts in nav.partsOf do
		for i = 1, #parts do
			for j = i + 1, #parts do
				local edge = FloorNav.sharedEdge(parts[i], parts[j])
				if edge then
					local id = parts[i].key .. "|" .. parts[j].key
					addPortal(id, "Doorway", parts[i], parts[j], edge, edge.from, edge.to, false, math.huge)
				end
			end
		end
	end
	nav.obstacles = {}
	for _, o in FloorNav.levelObstacles(layout, origin, math.max(AGENT_HEIGHT, nav.minClearance)) do
		table.insert(nav.obstacles, {
			id = o.id,
			minX = o.minX - CLEARANCE,
			maxX = o.maxX + CLEARANCE,
			minZ = o.minZ - CLEARANCE,
			maxZ = o.maxZ + CLEARANCE,
		})
	end

	-- the room index: a grid of CELL squares, each listing the rooms overlapping it
	local grid: { [number]: { NavRoom } } = {}
	local function cellKey(cx: number, cz: number): number
		return (cx + 4096) * 8192 + (cz + 4096)
	end
	for _, room in nav.rooms do
		for cx = math.floor((room.minX - EPS) / CELL), math.floor((room.maxX + EPS) / CELL) do
			for cz = math.floor((room.minZ - EPS) / CELL), math.floor((room.maxZ + EPS) / CELL) do
				local key = cellKey(cx, cz)
				local list = grid[key]
				if not list then
					list = {}
					grid[key] = list
				end
				table.insert(list, room)
			end
		end
	end
	local samples: { Sample }? = nil

	function nav.open(_self: Nav, portal: Portal): boolean
		return not portal.scripted or doorOpen(portal.id)
	end

	function nav.roomAt(_self: Nav, p: Vector3): NavRoom?
		local list = grid[cellKey(math.floor(p.X / CELL), math.floor(p.Z / CELL))]
		if not list then
			return nil
		end
		for _, room in list do
			if
				p.X >= room.minX - EPS
				and p.X <= room.maxX + EPS
				and p.Z >= room.minZ - EPS
				and p.Z <= room.maxZ + EPS
			then
				return room
			end
		end
		return nil
	end

	function nav.nearestRoom(_self: Nav, p: Vector3): NavRoom?
		local best: NavRoom? = nil
		local bestD = math.huge
		for _, room in nav.rooms do
			local dx = math.max(room.minX - p.X, 0, p.X - room.maxX)
			local dz = math.max(room.minZ - p.Z, 0, p.Z - room.maxZ)
			local d = dx * dx + dz * dz
			if d < bestD then
				best, bestD = room, d
			end
		end
		return best
	end

	function nav.clearanceAt(self: Nav, p: Vector3): number
		local room = self:roomAt(p)
		local c = if room then room.height else math.huge
		local portals: { Portal } = if room then nav.portalsOf[room.key] else nav.portals
		for _, portal in portals do
			if not (portal.clearance < c) then
				continue
			end
			local along = if portal.axis == "X" then p.Z else p.X
			local across = if portal.axis == "X" then p.X else p.Z
			if
				math.abs(across - portal.coord) <= PORTAL_REACH
				and along >= portal.u0 - 1
				and along <= portal.u1 + 1
			then
				c = portal.clearance
			end
		end
		return c
	end

	function nav.reachable(self: Nav, from: Vector3): (point: Vector3) -> boolean
		local start = self:roomAt(from) or self:nearestRoom(from)
		if not start then
			return function(_point: Vector3): boolean
				return false
			end
		end
		local seen: { [string]: boolean } = { [start.key] = true }
		local stack = { start.key }
		while #stack > 0 do
			local key = table.remove(stack) :: string
			for _, portal in nav.portalsOf[key] or NO_PORTALS do
				if not self:open(portal) then
					continue
				end
				local nextKey = if portal.a == key then portal.b else portal.a
				if not seen[nextKey] then
					seen[nextKey] = true
					table.insert(stack, nextKey)
				end
			end
		end
		return function(point: Vector3): boolean
			local room = self:roomAt(point) or self:nearestRoom(point)
			return room ~= nil and seen[room.key] == true
		end
	end

	type Node = { k: string, portal: Portal, into: string, parent: Node? }

	-- A* over the portals: the portal list from `start` room to `goal` room, or nil.
	local function search(self: Nav, start: NavRoom, goal: NavRoom, from: Vector3, to: Vector3): { Portal }?
		local cost: { [string]: number } = {}
		local closed: { [string]: boolean } = {}
		local heap = BinaryHeap.new() :: BinaryHeap.Heap<Node>
		local function h(p: Vector3): number
			return math.sqrt((p.X - to.X) ^ 2 + (p.Z - to.Z) ^ 2)
		end
		for _, portal in nav.portalsOf[start.key] or NO_PORTALS do
			if not self:open(portal) then
				continue
			end
			local into = if portal.a == start.key then portal.b else portal.a
			local k = portal.id .. ">" .. into
			local c = math.sqrt((portal.mid.X - from.X) ^ 2 + (portal.mid.Z - from.Z) ^ 2)
			if cost[k] == nil or c < cost[k] then
				cost[k] = c
				heap:push({ k = k, portal = portal, into = into, parent = nil }, c + h(portal.mid))
			end
		end
		while heap:size() > 0 do
			local popped = heap:pop()
			if not popped then
				break
			end
			local node = popped :: Node
			if closed[node.k] then
				continue
			end
			closed[node.k] = true
			if node.into == goal.key then
				local route: { Portal } = {}
				local cursor: Node? = node
				while cursor do
					table.insert(route, 1, cursor.portal)
					cursor = cursor.parent
				end
				return route
			end
			local here = cost[node.k]
			for _, portal in nav.portalsOf[node.into] or NO_PORTALS do
				if portal == node.portal or not self:open(portal) then
					continue
				end
				local into = if portal.a == node.into then portal.b else portal.a
				local k = portal.id .. ">" .. into
				if closed[k] then
					continue
				end
				local c = here + (node.portal.mid - portal.mid).Magnitude
				if cost[k] == nil or c < cost[k] - 1e-9 then
					cost[k] = c
					heap:push({ k = k, portal = portal, into = into, parent = node }, c + h(portal.mid))
				end
			end
		end
		return nil
	end

	-- `a` -> `b` cut where it passes from one room's rectangle into the next: { a, crossings..., b }.
	local function splitByRooms(self: Nav, a: Vector3, b: Vector3): { Vector3 }
		local pieces = { a }
		local cursor = a
		local room = self:roomAt(a)
		for _ = 1, MAX_SPLITS do
			if not room or insideRect(room, b.X, b.Z) then
				break
			end
			local t = exitParameter(room, cursor, b)
			if not (t > EPS and t < 1 - EPS) then
				break
			end
			local at = cursor:Lerp(b, t)
			table.insert(pieces, at)
			room = self:roomAt(cursor:Lerp(b, math.min(1, t + 0.01)))
			cursor = at
		end
		table.insert(pieces, b)
		return pieces
	end

	-- The route `from` -> `points` with every piece that meets an obstacle footprint replaced by the way round it.
	local function detour(self: Nav, from: Vector3, points: { Vector3 }): { Vector3 }
		if #nav.obstacles == 0 or #points == 0 then
			return points
		end
		local goal = points[#points]
		local blockers: { Obstacle } = {}
		for _, o in nav.obstacles do
			if not (insideRect(o, from.X, from.Z) or insideRect(o, goal.X, goal.Z)) then
				table.insert(blockers, o)
			end
		end
		if #blockers == 0 then
			return points
		end
		local out: { Vector3 } = {}
		local a = from
		for _, b in points do
			if not blocked(blockers, a.X, a.Z, b.X, b.Z) then
				table.insert(out, b)
				a = b
				continue
			end
			local pieces = splitByRooms(self, a, b)
			for i = 1, #pieces - 1 do
				local p, q = pieces[i], pieces[i + 1]
				local last = i + 1 == #pieces
				local room = self:roomAt(Vector3.new((p.X + q.X) / 2, 0, (p.Z + q.Z) / 2))
				local way = if room and blocked(blockers, p.X, p.Z, q.X, q.Z)
					then FloorNav.aroundIn(room, blockers, p, q)
					else nil
				if way and room then
					for _, c in way do
						table.insert(out, Vector3.new(c.X, room.floorY, c.Z))
					end
				end
				if last then
					table.insert(out, b)
				elseif
					way
					or (
						i + 2 <= #pieces
						and room ~= nil
						and blocked(blockers, q.X, q.Z, pieces[i + 2].X, pieces[i + 2].Z)
					)
				then
					table.insert(out, q)
				end
			end
			a = b
		end
		return out
	end

	function nav.computePath(self: Nav, from: Vector3, to: Vector3): Route?
		local start = self:roomAt(from) or self:nearestRoom(from)
		local goal = self:roomAt(to) or self:nearestRoom(to)
		if not (start and goal) then
			return nil
		end
		local goalPoint = Vector3.new(to.X, goal.floorY, to.Z)
		if start == goal then
			return { waypoints = FloorNav.spaced(from, detour(self, from, { goalPoint })) }
		end
		local route = search(self, start, goal, from, to)
		if not route then
			return nil
		end
		local corridor: { Segment } = {}
		local room = start
		for _, portal in route do
			local nextKey = if portal.a == room.key then portal.b else portal.a
			for _, piece in crossing(portal, room) do
				table.insert(corridor, piece)
			end
			room = nav.roomByKey[nextKey]
		end
		local points = FloorNav.funnel(from, goalPoint, corridor)
		return { waypoints = FloorNav.spaced(from, detour(self, from, points)) }
	end

	function nav.pathLength(self: Nav, from: Vector3, to: Vector3): number
		local route = self:computePath(from, to)
		if not route then
			return math.huge
		end
		local length = 0
		local a = from
		for _, b in route.waypoints do
			length += math.sqrt((b.X - a.X) ^ 2 + (b.Z - a.Z) ^ 2)
			a = b
		end
		return length
	end

	function nav.samplePoints(_self: Nav, spacing: number?): { Sample }
		local cached = samples
		if cached then
			return cached
		end
		local step = spacing or 6
		local out: { Sample } = {}
		for _, room in nav.rooms do
			if NO_SAMPLES[room.kind] then
				continue
			end
			local minX, maxX = room.minX + SAMPLE_INSET, room.maxX - SAMPLE_INSET
			local minZ, maxZ = room.minZ + SAMPLE_INSET, room.maxZ - SAMPLE_INSET
			if minX > maxX or minZ > maxZ then
				continue
			end
			local nx = math.max(1, math.floor((maxX - minX) / step) + 1)
			local nz = math.max(1, math.floor((maxZ - minZ) / step) + 1)
			for i = 0, nx - 1 do
				for j = 0, nz - 1 do
					local x = if nx == 1 then (minX + maxX) / 2 else minX + (maxX - minX) * i / (nx - 1)
					local z = if nz == 1 then (minZ + maxZ) / 2 else minZ + (maxZ - minZ) * j / (nz - 1)
					local free = true
					for _, o in nav.obstacles do
						if insideRect(o, x, z) then
							free = false
							break
						end
					end
					if free then
						table.insert(out, { position = Vector3.new(x, room.floorY, z), room = room.id })
					end
				end
			end
		end
		samples = out
		return out
	end

	return nav
end

return table.freeze(FloorNav)
