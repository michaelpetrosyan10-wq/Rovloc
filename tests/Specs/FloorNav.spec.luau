--!strict
-- FloorNav, the Creature's floor pathfinding on the zone graph (docs/MONSTER.md 5 and 10; web/src/creature/nav.js).
-- The geometry (shared walls, a segment through a footprint, the funnel, spacing, the deck strips round a pool, the
-- way round a footprint) and the real levels: every route stays on floor it may walk (never a crawlway, a duct or a
-- pool's water), crawl-only and low portals are shut to it, the patrol is reachable from where it spawns, it hunches
-- in the tunnels, and fixture doors follow their hook.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)

local Monster = ServerScriptService.Services.Monster.MonsterAIService
local Brain = require(Monster.Brain)
local FloorNav = require(Monster.FloorNav)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local EPS = 1e-6

local function open(_doorId: string): boolean
	return true
end

local function navOf(levelId: Enums.LevelId): (FloorNav.Nav, LayoutSchema.LevelLayout)
	local layout = Builder.getLayout(levelId)
	assert(layout, levelId .. " layout")
	return FloorNav.new(layout, WorldConfig.levelOrigin(levelId), open), layout
end

local function room(id: string, minX: number, maxX: number, minZ: number, maxZ: number): FloorNav.NavRoom
	return {
		id = id,
		key = id,
		kind = "Classroom",
		minX = minX,
		maxX = maxX,
		minZ = minZ,
		maxZ = maxZ,
		floorY = 0,
		height = 12,
	}
end

-- Whether the walk `from` -> each of `waypoints` ever crosses the inside of `r`.
local function routeCrosses(r: FloorNav.Rect, from: Vector3, waypoints: { Vector3 }): boolean
	local a = from
	for _, b in waypoints do
		if FloorNav.crossesRect(r, a.X, a.Z, b.X, b.Z) then
			return true
		end
		a = b
	end
	return false
end

local spec = {}

spec["geometry: the wall two rooms share, and a leg through a footprint"] = function(t: Expect)
	local a = { minX = 0, maxX = 10, minZ = 0, maxZ = 10 }
	local east = { minX = 10, maxX = 20, minZ = 4, maxZ = 30 }
	local edge = FloorNav.sharedEdge(a, east)
	assert(edge, "touching rooms share a wall")
	t.eq(edge.axis, "X", "a wall of constant X")
	t.eq(edge.coord, 10)
	t.eq(edge.from, 4, "the overlap only")
	t.eq(edge.to, 10)
	local south = FloorNav.sharedEdge(a, { minX = 2, maxX = 8, minZ = 10, maxZ = 14 })
	t.truthy(south and south.axis == "Z" and south.coord == 10 and south.from == 2 and south.to == 8, "a Z wall")
	t.eq(FloorNav.sharedEdge(a, { minX = 10, maxX = 20, minZ = 10, maxZ = 20 }), nil, "a corner is no wall")
	t.eq(FloorNav.sharedEdge(a, { minX = 11, maxX = 20, minZ = 0, maxZ = 10 }), nil, "a gap is no wall")
	local box = { minX = 4, maxX = 6, minZ = 4, maxZ = 6 }
	t.truthy(FloorNav.crossesRect(box, 0, 5, 10, 5), "straight through")
	t.falsy(FloorNav.crossesRect(box, 0, 0, 10, 0), "beside it")
	t.falsy(FloorNav.crossesRect(box, 0, 4, 10, 4), "along its edge is clear")
	t.truthy(FloorNav.crossesRect(box, 0, 0, 10, 10), "the diagonal")
	t.falsy(FloorNav.crossesRect(box, 0, 0, 3, 3), "stops short")
end

spec["funnel: string-pulled through the openings, spaced without losing a turn"] = function(t: Expect)
	-- two openings on a line: the pulled route is straight
	local straight = FloorNav.funnel(Vector3.new(0, 0, 5), Vector3.new(30, 0, 5), {
		{ p = Vector3.new(10, 0, 2), q = Vector3.new(10, 0, 8) },
		{ p = Vector3.new(20, 0, 2), q = Vector3.new(20, 0, 8) },
	})
	t.eq(#straight, 1, "nothing to turn round")
	t.truthy((straight[1] - Vector3.new(30, 0, 5)).Magnitude < EPS, "ends at the goal")
	-- a dog-leg: the route turns at the near corner of the offset opening
	local bent = FloorNav.funnel(Vector3.new(0, 0, 0), Vector3.new(20, 0, 0), {
		{ p = Vector3.new(10, 0, 6), q = Vector3.new(10, 0, 10) },
	})
	t.eq(#bent, 2, "one turn")
	t.truthy((bent[1] - Vector3.new(10, 0, 6)).Magnitude < EPS, "hugs the opening's near jamb")
	local spaced = FloorNav.spaced(Vector3.new(0, 0, 0), { Vector3.new(10, 0, 0), Vector3.new(10, 0, 3) }, 4)
	t.eq(#spaced, 4, "4, 8, the turn, the end")
	t.truthy((spaced[3] - Vector3.new(10, 0, 0)).Magnitude < EPS, "the turn is kept")
	for i = 2, #spaced do
		t.truthy((spaced[i] - spaced[i - 1]).Magnitude <= 4 + EPS, "no step longer than the spacing")
	end
end

spec["pools: a basin leaves the deck round it as strips, narrow ones dropped"] = function(t: Expect)
	local hall = room("Pool", 0, 40, 0, 30)
	local parts = FloorNav.deckParts(hall, { { minX = 10, maxX = 30, minZ = 5, maxZ = 25 } })
	t.eq(#parts, 4, "west, east, north and south")
	local keys: { [string]: boolean } = {}
	for _, part in parts do
		keys[part.key] = true
		t.eq(part.id, "Pool", "every strip keeps the room's id")
		t.falsy(
			FloorNav.crossesRect(
				{ minX = 10, maxX = 30, minZ = 5, maxZ = 25 },
				part.minX + 0.5,
				part.minZ + 0.5,
				part.maxX - 0.5,
				part.maxZ - 0.5
			),
			part.key .. " is dry"
		)
	end
	t.truthy(keys["Pool#W"] and keys["Pool#E"] and keys["Pool#N"] and keys["Pool#S"], "keyed by side")
	local wall = FloorNav.deckParts(hall, { { minX = 1, maxX = 40, minZ = 0, maxZ = 30 } })
	t.eq(#wall, 0, "wall to wall: a 1-stud ledge is no deck")
	t.eq(#FloorNav.deckParts(hall, {}), 1, "no basin, the whole room")
	t.eq(#FloorNav.deckParts(hall, { { minX = 50, maxX = 60, minZ = 0, maxZ = 5 } }), 1, "a basin elsewhere")
end

spec["obstacles: the shortest way round a footprint stays inside the room"] = function(t: Expect)
	local r = { minX = 0, maxX = 40, minZ = 0, maxZ = 20 }
	local pillar: FloorNav.Obstacle = { id = "P", minX = 18, maxX = 22, minZ = 6, maxZ = 14 }
	local way = FloorNav.aroundIn(r, { pillar }, Vector3.new(5, 0, 10), Vector3.new(35, 0, 10))
	assert(way and #way >= 1, "a way round")
	local walk = table.clone(way)
	for _, p in way do
		t.truthy(p.X > r.minX and p.X < r.maxX and p.Z > r.minZ and p.Z < r.maxZ, "inside the room")
	end
	table.insert(walk, Vector3.new(35, 0, 10))
	t.falsy(routeCrosses(pillar, Vector3.new(5, 0, 10), walk), "never through the pillar")
	t.truthy(routeCrosses(pillar, Vector3.new(5, 0, 10), { Vector3.new(35, 0, 10) }), "the straight leg would be")
	local clear = FloorNav.aroundIn(r, { pillar }, Vector3.new(5, 0, 2), Vector3.new(35, 0, 2))
	t.truthy(clear and #clear == 0, "a straight leg past it needs no corner")
end

spec["tunnels: no route ever walks a crawlway, and every crawl-only or low portal is shut"] = function(t: Expect)
	local nav, layout = navOf("Level0_Basement")
	local crawlRooms: { LayoutSchema.Room } = {}
	for _, r in layout.rooms do
		if r.kind == "Crawlway" then
			table.insert(crawlRooms, r)
		end
	end
	t.truthy(#crawlRooms > 0, "the basement has crawlways")
	for _, navRoom in nav.rooms do
		t.truthy(navRoom.kind ~= "Crawlway" and navRoom.kind ~= "Chase", navRoom.id .. " is floor it walks")
	end
	for _, portal in nav.portals do
		if nav:open(portal) then
			t.truthy(portal.clearance >= CreatureConfig.PathAgent.AgentHeight, portal.id .. " is tall enough")
		end
	end
	local origin = WorldConfig.levelOrigin("Level0_Basement")
	local crawlRects: { FloorNav.Rect } = {}
	for _, r in crawlRooms do
		local rect = r.rect
		table.insert(crawlRects, {
			minX = origin.X + rect.x,
			maxX = origin.X + rect.x + rect.w,
			minZ = origin.Z + rect.z,
			maxZ = origin.Z + rect.z + rect.d,
		})
		local inside = origin + Vector3.new(rect.x + rect.w / 2, 0, rect.z + rect.d / 2)
		t.eq(nav:roomAt(inside + Vector3.new(0, 1, 0)), nil, r.id .. " is no floor to it")
	end
	local samples = nav:samplePoints(12)
	t.truthy(#samples > 40, "a lattice over the basement")
	local step = math.max(1, math.floor(#samples / 30))
	local routes = 0
	for i = 1, #samples, step do
		for j = #samples, 1, -step * 3 do
			local route = nav:computePath(samples[i].position, samples[j].position)
			if not route then
				continue
			end
			routes += 1
			for _, rect in crawlRects do
				t.falsy(routeCrosses(rect, samples[i].position, route.waypoints), "a route through a crawlway")
			end
		end
	end
	t.truthy(routes > 20, "routes were walked (" .. routes .. ")")
	for _, sample in samples do
		t.truthy(nav:roomAt(sample.position + Vector3.new(0, 1, 0)) ~= nil, "every sample stands on its floor")
	end
end

spec["tunnels: it hunches under the tunnels' ceilings, and the patrol is reachable from its spawn"] = function(
	t: Expect
)
	local nav, layout = navOf("Level0_Basement")
	local info = Brain.levelInfo(layout)
	assert(info and info.spawn, "Level 0 knowledge with a CreatureSpawn")
	local spawn = (info.spawn :: CFrame).Position
	local reach = nav:reachable(spawn)
	t.truthy(#info.waypoints > 0, "the basement has patrol waypoints")
	local reached = 0
	for _, waypoint in info.waypoints do
		if reach(waypoint.position) then
			reached += 1
		end
	end
	t.eq(reached, #info.waypoints, "every patrol waypoint is walkable from the spawn")
	local low = 0
	for _, r in nav.rooms do
		if r.height < CreatureConfig.HunchBelow then
			local centre = Vector3.new((r.minX + r.maxX) / 2, r.floorY, (r.minZ + r.maxZ) / 2)
			t.truthy(nav:clearanceAt(centre) < CreatureConfig.HunchBelow, r.id .. " hunches it")
			low += 1
		end
	end
	t.truthy(low > 0, "some of the basement is lower than it stands")
	t.truthy(CreatureConfig.PathAgent.AgentHeight <= CreatureConfig.Rig.HunchedHeight, "routes fit it hunched")
	t.truthy(CreatureConfig.PathAgent.AgentHeight >= 9, "AgentHeight at least 9")
end

spec["pools: no route crosses Level 4's water, the decks join round it"] = function(t: Expect)
	local nav, layout = navOf("Level4_FloodedPool")
	local origin = WorldConfig.levelOrigin("Level4_FloodedPool")
	local basins: { LayoutSchema.Basin } = layout.basins or {}
	t.truthy(#basins > 0, "Level 4 has a basin")
	local water: { FloorNav.Rect } = {}
	for _, b in basins do
		table.insert(water, {
			minX = origin.X + b.rect.x,
			maxX = origin.X + b.rect.x + b.rect.w,
			minZ = origin.Z + b.rect.z,
			maxZ = origin.Z + b.rect.z + b.rect.d,
		})
	end
	local samples = nav:samplePoints(8)
	local routes = 0
	for i = 1, #samples, math.max(1, math.floor(#samples / 25)) do
		for j = 1, #samples, math.max(1, math.floor(#samples / 9)) do
			local route = nav:computePath(samples[i].position, samples[j].position)
			if route then
				routes += 1
				for _, rect in water do
					t.falsy(routeCrosses(rect, samples[i].position, route.waypoints), "a route across the water")
				end
			end
		end
	end
	t.truthy(routes > 20, "routes were walked (" .. routes .. ")")
	for _, sample in samples do
		for _, rect in water do
			local x, z = sample.position.X, sample.position.Z
			t.falsy(x > rect.minX and x < rect.maxX and z > rect.minZ and z < rect.maxZ, "no sample in the water")
		end
	end
end

spec["doors: fixture doors follow the hook, the rest stand open; another part of the level is math.huge"] = function(
	t: Expect
)
	local layout = Builder.getLayout("Level1_Hallways")
	assert(layout, "Level 1 layout")
	local shut: { [string]: boolean } = {}
	local nav = FloorNav.new(layout, WorldConfig.levelOrigin("Level1_Hallways"), function(doorId: string): boolean
		return not shut[doorId]
	end)
	local scripted = 0
	for _, portal in nav.portals do
		if portal.scripted then
			scripted += 1
			t.truthy(nav:open(portal), portal.id .. " open while its hook says so")
			shut[portal.id] = true
			t.falsy(nav:open(portal), portal.id .. " shut with its door")
			shut[portal.id] = nil
		elseif portal.clearance >= nav.minClearance then
			t.truthy(nav:open(portal), portal.id .. " stands open")
		end
	end
	t.truthy(scripted > 0, "Level 1 has fixture doors")
	local samples = nav:samplePoints(10)
	local a = samples[1].position
	t.eq(nav:pathLength(a, a), 0, "no walk to where it stands")
	local b = samples[#samples].position
	local length = nav:pathLength(a, b)
	t.truthy(length < math.huge, "across the floor")
	t.truthy(
		length >= (Vector3.new(b.X, 0, b.Z) - Vector3.new(a.X, 0, a.Z)).Magnitude - 1e-3,
		"never shorter than straight"
	)
	-- on every level (some fall apart into parts joined only by ducts or locked airlocks; every one with its fixture
	-- doors shut): reachable and pathLength agree, and a part it cannot walk to is math.huge
	for _, levelId: Enums.LevelId in Enums.LevelId do
		local levelLayout = Builder.getLayout(levelId)
		if not levelLayout then
			continue
		end
		local shutAll = FloorNav.new(levelLayout, WorldConfig.levelOrigin(levelId), function(_doorId: string): boolean
			return false
		end)
		local points = shutAll:samplePoints(10)
		if #points == 0 then
			continue
		end
		local from = points[1].position
		local reach = shutAll:reachable(from)
		for i = 1, #points, math.max(1, math.floor(#points / 40)) do
			local to = points[i].position
			local walk = shutAll:pathLength(from, to)
			if reach(to) then
				t.truthy(walk < math.huge, levelId .. ": reachable means a route")
			else
				t.eq(walk, math.huge, levelId .. ": no route to another part")
			end
		end
	end
end

return spec
