--!strict
-- ExtraAnchors: the post-plan pass that gives a tunnel floor its radar batteries and stun flasks (docs/design/
-- game-spec-v2.md 3.2, 4.2, 4.3). A layout runs it after TunnelPlanner.plan and its own keep-room anchors, before it
-- freezes: it only adds and drops BatteryCandidate anchors and adds FlaskCandidate anchors, so the planned rooms, doors
-- and zone graph (and with them every hash a spec records) never change. It draws from its own Rng streams
-- ("ExtraAnchors|Batteries|<level>", "ExtraAnchors|Flasks|<level>"), never from the planner's.
--
-- Batteries (RadarConfig.Candidates of them, 36). RunDirector.pickBatteries places a run's 6 [4] + 1 per extra
-- player of them by four rules: one EntryMin..EntryMax walked from the entry, one within StationReach of the main
-- station, every pair PairSpacing apart, none in a dead end. The pass makes the four hold on every seed:
--   * every candidate stands in a Tunnel or Gallery run that is no dead end (a room with fewer than two ways in or
--     out on the placement rules' walk graph, TunnelRules.walkGraph with the crawlways), against a side wall (1.3 off
--     its face, as the planner lays them), clear of doorways, triggers, platforms and every other anchor;
--   * every pair of candidates is SPACING (PairSpacing + 2) walked apart, so whatever a run's shuffle takes keeps the
--     spacing;
--   * every way in (ObjectivePlaces.entries) has a candidate ENTRY_BAND walked from its arrival point, and every
--     main station (`stations`: the anchors of those kinds) one within STATION_REACH, both inside the rule's numbers
--     by a margin;
--   * the planner's own candidates stay where they keep these rules (in layout order), the rest are dropped; the
--     remainder is filled in farthest-point order (the candidate farthest walked from every one taken, ties in the
--     stream's shuffled order), which spreads them over the whole floor.
-- Flasks: the layout's named spots (keep-room shelves and benches, the mop carts: `flasks`), then `nicheFlasks` more
-- on a shelf over the drum of a hide niche (an Alcove holding one Barrel; inside `nicheAreas` when given), spread the
-- same farthest-first way. A niche flask stands on the back wall's shelf at NICHE_SHELF_Y, facing out of the niche;
-- CleaningShelfBuilder builds the shelf under every flask that no platform or cart carries.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local ObjectivePlaces = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ObjectivePlaces)
local RadarConfig = require(ReplicatedStorage.Shared.Config.RadarConfig)
local Rng = require(ReplicatedStorage.Shared.Util.Rng)
local TunnelRules = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.TunnelRules)

type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor
type Room = LayoutSchema.Room
type WalkGraph = TunnelRules.WalkGraph

export type FlaskSpot = {
	pos: Vector3, -- level-local resting point (the shelf, bench or tray top)
	yaw: number, -- degrees, facing out of the wall behind it
	ref: string?, -- the anchor that carries it (a mop cart)
}

export type Spec = {
	seed: number, -- the layout's seed (the streams add their own keys)
	stations: { Enums.AnchorKind }, -- main station kinds: a battery within reach of each such anchor
	flasks: { FlaskSpot },
	nicheFlasks: number,
	nicheAreas: { { number } }?, -- { x0, z0, x1, z1 } rects a niche flask's niche must lie in
}

export type Report = {
	batteries: number,
	kept: number, -- the planner's candidates kept
	dropped: { string }, -- the planner's candidates dropped (a dead end, or too near one kept)
	flasks: number,
}

local INF = math.huge
local BATTERY_COUNT = RadarConfig.Candidates
local PLACEMENT = RadarConfig.Placement
local SPACING = PLACEMENT.PairSpacing + 2
local ENTRY_BAND = { PLACEMENT.EntryMin + 4, PLACEMENT.EntryMax - 4 }
local STATION_REACH = PLACEMENT.StationReach - 6
local WALL_OFFSET = 1.3 -- a battery's distance off the wall face (TunnelPlanner's spotsAlong)
local STEP = 3 -- studs between candidate spots along a run
local RUN_END = 3 -- spots keep this far from a run's ends
local DOOR_CLEAR = 2.5 -- beyond a doorway's half width
local ANCHOR_CLEAR = 3
local CART_CLEAR = 7.5 -- a mop cart reaches this far along its wall (its bucket and sign)
local NICHE_SHELF_Y = 6.1 -- above the drum and its lifted lid (HideBuilder: 4.7 tall)
local NICHE_WALL = 0.55 -- the flask's foot off the niche's back wall
local WALL_HALF = 0.5

-- Anchor kinds a battery spot ignores (the run's centreline marks)
local IGNORED: { [string]: boolean } = { PatrolWaypoint = true, CreatureSpawn = true }

local ExtraAnchors = {}

ExtraAnchors.Spacing = SPACING
ExtraAnchors.EntryBand = table.freeze(table.clone(ENTRY_BAND))
ExtraAnchors.StationReach = STATION_REACH
ExtraAnchors.NicheShelfY = NICHE_SHELF_Y

-- The rooms of `layout` that are dead ends on `g`: fewer than two ways in or out (RunDirector.deadEndRooms' rule).
function ExtraAnchors.deadEnds(layout: Layout, g: WalkGraph): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, room in layout.rooms do
		local ways = g.members[room.id]
		if room.kind ~= "Solid" and room.kind ~= "Chase" and (ways == nil or #ways < 2) then
			out[room.id] = true
		end
	end
	return out
end

local function flat(v: Vector3): Vector2
	return Vector2.new(v.X, v.Z)
end

type Spot = { room: string, p: Vector2, pos: Vector3 }

-- Studs walked from `from` (distances over g) to a spot, with the straight line when both share a room.
local function walkTo(g: WalkGraph, dist: { number }, fromRoom: string, fromP: Vector2, spot: Spot): number
	return TunnelRules.reach(g, dist, spot.room, spot.p, if spot.room == fromRoom then { fromP } else nil)
end

local function distancesFrom(g: WalkGraph, room: string, p: Vector2): { number }
	return TunnelRules.distances(g, TunnelRules.seedsAt(g, room, p))
end

-- Every battery spot the floor offers: along both side walls of every Tunnel and Gallery run that is no dead end,
-- STEP apart, clear of doorways, triggers, platforms and anchors.
local function batterySpots(layout: Layout, dead: { [string]: boolean }): { Spot }
	local out: { Spot } = {}
	local blocks: { { x0: number, z0: number, x1: number, z1: number } } = {}
	for _, trigger in layout.triggers do
		local r = trigger.rect
		table.insert(blocks, { x0 = r.x - 1, z0 = r.z - 1, x1 = r.x + r.w + 1, z1 = r.z + r.d + 1 })
	end
	local platforms: { LayoutSchema.Platform } = layout.platforms or {}
	for _, platform in platforms do
		local r = platform.rect
		table.insert(blocks, { x0 = r.x - 1, z0 = r.z - 1, x1 = r.x + r.w + 1, z1 = r.z + r.d + 1 })
	end
	local rooms = LayoutSchema.indexRooms(layout)
	local doorPoints: { [string]: { { p: Vector2, half: number } } } = {}
	for _, door in layout.doors do
		local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
		local p = if a and b then TunnelRules.doorPoint(a.rect, b.rect, door.at) else nil
		if p then
			for _, id in door.rooms do
				doorPoints[id] = doorPoints[id] or {}
				table.insert(doorPoints[id], { p = p, half = LayoutSchema.doorWidth(door) / 2 })
			end
		end
	end
	for _, room in layout.rooms do
		if (room.kind ~= "Tunnel" and room.kind ~= "Gallery") or dead[room.id] then
			continue
		end
		local r = room.rect
		local alongX = r.w >= r.d
		local lo = (if alongX then r.x else r.z) + RUN_END
		local hi = (if alongX then r.x + r.w else r.z + r.d) - RUN_END
		local width = if alongX then r.d else r.w
		local centre = if alongX then r.z + r.d / 2 else r.x + r.w / 2
		local across = width / 2 - WALL_HALF - WALL_OFFSET
		if hi < lo or across <= 0 then
			continue
		end
		local u = lo
		while u <= hi + 1e-6 do
			for _, side in { -1, 1 } do
				local c = centre + side * across
				local x, z = if alongX then u else c, if alongX then c else u
				local p = Vector2.new(x, z)
				local clear = true
				local doors: { { p: Vector2, half: number } } = doorPoints[room.id] or {}
				for _, door in doors do
					if (door.p - p).Magnitude < door.half + DOOR_CLEAR then
						clear = false
						break
					end
				end
				for _, b in blocks do
					if clear and x > b.x0 and x < b.x1 and z > b.z0 and z < b.z1 then
						clear = false
					end
				end
				if clear then
					for _, anchor in layout.anchors do
						local reach = if anchor.kind == "MopCart" then CART_CLEAR else ANCHOR_CLEAR
						if not IGNORED[anchor.kind] and (flat(anchor.pos) - p).Magnitude < reach then
							clear = false
							break
						end
					end
				end
				if clear then
					table.insert(out, { room = room.id, p = p, pos = Vector3.new(x, 0, z) })
				end
			end
			u += STEP
		end
	end
	return out
end

-- The room of `layout` holding (x, z) (never solid ground), or nil.
local function roomAt(layout: Layout, x: number, z: number): string?
	for _, room in layout.rooms do
		if room.kind ~= "Solid" and LayoutSchema.rectContains(room.rect, x, z, 0.05) then
			return room.id
		end
	end
	return nil
end

-- Takes from `pool` the spot maximising its walk from every spot taken (`minWalk`), at least `spacing`; ties in pool
-- order. Updates minWalk from the new spot. Returns nil when none keeps the spacing.
local function takeFarthest(
	pool: { Spot },
	minWalk: { number },
	spacing: number,
	accept: ((index: number) -> boolean)?
): Spot?
	local best, bestWalk = 0, -INF
	for i = 1, #pool do
		if minWalk[i] >= spacing and minWalk[i] > bestWalk and (accept == nil or accept(i)) then
			best, bestWalk = i, minWalk[i]
		end
	end
	if best == 0 then
		return nil
	end
	return pool[best]
end

local function noteTaken(g: WalkGraph, pool: { Spot }, minWalk: { number }, taken: Spot)
	local dist = distancesFrom(g, taken.room, taken.p)
	for i, spot in pool do
		local d = walkTo(g, dist, taken.room, taken.p, spot)
		if d < minWalk[i] then
			minWalk[i] = d
		end
	end
end

local function anchorPlaces(layout: Layout, kinds: { Enums.AnchorKind }): { Spot }
	local out: { Spot } = {}
	for _, anchor in layout.anchors do
		if table.find(kinds, anchor.kind) then
			table.insert(out, { room = anchor.room, p = flat(anchor.pos), pos = anchor.pos })
		end
	end
	return out
end

local function addBatteries(layout: Layout, spec: Spec, g: WalkGraph, dead: { [string]: boolean }, report: Report)
	local random = Rng.seeded(spec.seed, "ExtraAnchors|Batteries|" .. layout.id)
	local prefix = string.match(layout.entry, "^([^_]+)_") or "L"
	-- the planner's candidates first: kept while they keep the rules, in layout order
	local kept: { Spot } = {}
	local keptDist: { { number } } = {}
	local others: { Anchor } = {}
	for _, anchor in layout.anchors do
		if anchor.kind ~= "BatteryCandidate" then
			table.insert(others, anchor)
			continue
		end
		local spot: Spot = { room = anchor.room, p = flat(anchor.pos), pos = anchor.pos }
		local ok = not dead[anchor.room]
		for k, other in kept do
			if ok and walkTo(g, keptDist[k], other.room, other.p, spot) < SPACING then
				ok = false
			end
		end
		if ok then
			table.insert(kept, spot)
			table.insert(keptDist, distancesFrom(g, spot.room, spot.p))
			table.insert(others, anchor)
		else
			table.insert(report.dropped, anchor.id)
		end
	end
	table.clear(layout.anchors)
	table.move(others, 1, #others, 1, layout.anchors)
	report.kept = #kept

	local pool = Rng.shuffle(batterySpots(layout, dead), random)
	local minWalk: { number } = table.create(#pool, INF)
	for _, spot in kept do
		noteTaken(g, pool, minWalk, spot)
	end
	local added: { Spot } = {}
	local count = #kept
	local function take(spot: Spot)
		table.insert(added, spot)
		count += 1
		noteTaken(g, pool, minWalk, spot)
	end

	-- every way in: a candidate in the entry band
	for _, entry in ObjectivePlaces.entries(layout) do
		local p = flat(entry.pos)
		local dist = distancesFrom(g, entry.room, p)
		local function inBand(spot: Spot): boolean
			local d = walkTo(g, dist, entry.room, p, spot)
			return d >= ENTRY_BAND[1] and d <= ENTRY_BAND[2]
		end
		local served = false
		for _, spot in kept do
			served = served or inBand(spot)
		end
		for _, spot in added do
			served = served or inBand(spot)
		end
		if not served then
			local spot = takeFarthest(pool, minWalk, SPACING, function(i: number): boolean
				return inBand(pool[i])
			end)
			if spot then
				take(spot)
			end
		end
	end
	-- every main station: a candidate within reach
	for _, station in anchorPlaces(layout, spec.stations) do
		local dist = distancesFrom(g, station.room, station.p)
		local function near(spot: Spot): boolean
			return walkTo(g, dist, station.room, station.p, spot) <= STATION_REACH
		end
		local served = false
		for _, spot in kept do
			served = served or near(spot)
		end
		for _, spot in added do
			served = served or near(spot)
		end
		if not served then
			local spot = takeFarthest(pool, minWalk, SPACING, function(i: number): boolean
				return near(pool[i])
			end)
			if spot then
				take(spot)
			end
		end
	end
	-- the rest, farthest first
	while count < BATTERY_COUNT do
		local spot = takeFarthest(pool, minWalk, SPACING, nil)
		if not spot then
			break
		end
		take(spot)
	end
	for i, spot in added do
		table.insert(layout.anchors, {
			id = string.format("%s_BatteryCandidate_X%02d", prefix, i),
			kind = "BatteryCandidate",
			room = spot.room,
			pos = Vector3.new(math.floor(spot.p.X * 100 + 0.5) / 100, 0, math.floor(spot.p.Y * 100 + 0.5) / 100),
			yaw = random:NextInteger(-180, 179),
		})
	end
	report.batteries = count
end

-- The hide niches of `layout` that hold one Barrel, as flask shelf spots (the back wall's shelf over the drum), and
-- each spot's yaw (out of the niche).
local function nicheSpots(layout: Layout, spec: Spec, dead: { [string]: boolean }): ({ Spot }, { [Spot]: number })
	local held: { [string]: { Anchor } } = {}
	for _, anchor in layout.anchors do
		held[anchor.room] = held[anchor.room] or {}
		table.insert(held[anchor.room], anchor)
	end
	local out: { Spot } = {}
	local yaws: { [Spot]: number } = {}
	for _, room in layout.rooms do
		local list = held[room.id]
		if not (dead[room.id] and string.find(room.id, "Alcove", 1, true) and list and #list == 1) then
			continue
		end
		local drum = list[1]
		local r = room.rect
		local cx, cz = r.x + r.w / 2, r.z + r.d / 2
		local inside = spec.nicheAreas == nil
		local areas: { { number } } = spec.nicheAreas or {}
		for _, area in areas do
			inside = inside or (cx >= area[1] and cx <= area[3] and cz >= area[2] and cz <= area[4])
		end
		if drum.kind ~= "Barrel" or not inside or LayoutSchema.roomHeight(layout, room) < NICHE_SHELF_Y + 2 then
			continue
		end
		-- the drum faces out of the niche (its yaw), so the back wall is behind it
		local yaw = drum.yaw or 0
		local look = Vector3.new(-math.sin(math.rad(yaw)), 0, -math.cos(math.rad(yaw)))
		local pos: Vector3
		if math.abs(look.X) > 0.5 then
			local back = if look.X > 0 then r.x + WALL_HALF else r.x + r.w - WALL_HALF
			pos = Vector3.new(back + look.X * NICHE_WALL, NICHE_SHELF_Y, drum.pos.Z)
		else
			local back = if look.Z > 0 then r.z + WALL_HALF else r.z + r.d - WALL_HALF
			pos = Vector3.new(drum.pos.X, NICHE_SHELF_Y, back + look.Z * NICHE_WALL)
		end
		local spot: Spot = { room = room.id, p = flat(pos), pos = pos }
		table.insert(out, spot)
		yaws[spot] = yaw
	end
	return out, yaws
end

local function addFlasks(layout: Layout, spec: Spec, g: WalkGraph, dead: { [string]: boolean }, report: Report)
	local prefix = string.match(layout.entry, "^([^_]+)_") or "L"
	local n = 0
	local function add(pos: Vector3, yaw: number, ref: string?, room: string?)
		n += 1
		local id = string.format("%s_FlaskCandidate_%02d", prefix, n)
		local holder = room or roomAt(layout, pos.X, pos.Z)
		if not holder then
			error(string.format("ExtraAnchors: no room holds flask spot %s (%.1f, %.1f)", id, pos.X, pos.Z), 3)
		end
		table.insert(
			layout.anchors,
			{ id = id, kind = "FlaskCandidate", room = holder, pos = pos, yaw = yaw, ref = ref }
		)
	end
	for _, spot in spec.flasks do
		add(spot.pos, spot.yaw, spot.ref, nil)
	end
	if spec.nicheFlasks > 0 then
		local random = Rng.seeded(spec.seed, "ExtraAnchors|Flasks|" .. layout.id)
		local spots, yaws = nicheSpots(layout, spec, dead)
		local pool = Rng.shuffle(spots, random)
		local minWalk: { number } = table.create(#pool, INF)
		for _, anchor in layout.anchors do
			if anchor.kind == "FlaskCandidate" then
				noteTaken(g, pool, minWalk, { room = anchor.room, p = flat(anchor.pos), pos = anchor.pos })
			end
		end
		for _ = 1, spec.nicheFlasks do
			local spot = takeFarthest(pool, minWalk, 0, nil)
			if not spot then
				break
			end
			noteTaken(g, pool, minWalk, spot)
			minWalk[table.find(pool, spot) :: number] = -1
			add(spot.pos, yaws[spot], nil, spot.room)
		end
	end
	report.flasks = n
end

-- Runs the pass on `layout` (its anchors still mutable): the floor's battery candidates and its flask spots.
function ExtraAnchors.apply(layout: Layout, spec: Spec): Report
	local g = TunnelRules.walkGraph(layout :: any, true)
	local dead = ExtraAnchors.deadEnds(layout, g)
	local report: Report = { batteries = 0, kept = 0, dropped = {}, flasks = 0 }
	addBatteries(layout, spec, g, dead, report)
	addFlasks(layout, spec, g, dead, report)
	return report
end

return table.freeze(ExtraAnchors)
