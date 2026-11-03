--!strict
-- SpawnRule: where the Creature starts on Levels 2 and 3 (ObjectiveConfig.Spawn; the web build's spawns.js mirrors it).
-- Pure: layouts, the run's objective picks and a sight test in, a verdict out.
--
-- Candidates: the level's PatrolWaypoint and CreatureSpawn anchors that pass all three rules:
--   * MinDistance..MaxDistance studs of walking from the entry (ObjectivePlaces.walkDistance from the run's entry room's
--     arrival point, ObjectivePlaces.arrivalPoint: its PlayerSpawn anchors' centroid; LevelDirector.entryFor names it);
--   * not visible from the entry: no clear line from any of five eye points of the entry room (its centre and its
--     corners inset EntryInset, at EntryEyeHeight) to the anchor at any of AnchorHeights over its floor;
--   * not inside an objective room: a room holding one of the floor's picked items or one of its stations.
-- Pick: one by the run seed (stream "CreatureSpawn|<level>"), in anchor id order. Fallback, never silent: with no
-- candidate the one nearest the band among the unseen ones outside the objective rooms (then any unseen one, then
-- any reachable one) is used, and `fallback` says so.
--
-- layoutSight(layout) is the default sight test: a straight line in the layout's own coordinates is clear while it
-- stays inside the rooms and only crosses from one room to the next through a doorway (any door but a boarded one
-- counts as open), so it is the same in Studio, in the Lune specs and on any client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local ObjectivePlaces = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ObjectivePlaces)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

type Layout = LayoutSchema.LevelLayout

export type Sight = (from: Vector3, to: Vector3) -> boolean -- layout-local points; true = a clear line

export type Candidate = {
	id: string,
	room: string,
	pos: Vector3, -- layout-local floor point
	walk: number,
	visible: boolean,
	inObjectiveRoom: boolean,
	inBand: boolean,
}

type Opening = { axis: string, coord: number, lo: number, hi: number }

export type Choice = { candidate: Candidate?, fallback: boolean, candidates: { Candidate } }

local SpawnRule = {}

local SPEC = ObjectiveConfig.Spawn
local STEP = 0.5 -- studs between the samples of a sight line
local DOOR_MARGIN = 0.4 -- a sight line must pass this far inside a doorway's jambs
local STATIONS: { [string]: boolean } = {
	BreakerPanel = true,
	FumeHood = true,
	Generator = true,
	StoreLock = true,
	HatchValve = true,
	CrateChain = true,
}

-- Whether the spawn rule places the Creature on `levelId`.
function SpawnRule.handles(levelId: string): boolean
	return table.find(SPEC.Levels, levelId) ~= nil
end

-- The rooms holding the floor's picked items or its stations.
function SpawnRule.objectiveRooms(layout: Layout, picks: Types.ObjectivePicks?): { [string]: boolean }
	local rooms: { [string]: boolean } = {}
	local picked: { [string]: boolean } = {}
	local anchors: { string } = if picks then picks.anchors else {}
	for _, id in anchors do
		picked[id] = true
	end
	for _, anchor in layout.anchors do
		if picked[anchor.id] or STATIONS[anchor.kind] then
			rooms[anchor.room] = true
		end
	end
	return rooms
end

-- The entry room's five eye points (layout-local).
function SpawnRule.entryEyes(layout: Layout, entryRoom: string?): { Vector3 }
	local room = LayoutSchema.indexRooms(layout)[entryRoom or layout.entry]
	if not room then
		return {}
	end
	local r = room.rect
	local y = SPEC.EntryEyeHeight
	local i = SPEC.EntryInset
	return {
		Vector3.new(r.x + r.w / 2, y, r.z + r.d / 2),
		Vector3.new(r.x + i, y, r.z + i),
		Vector3.new(r.x + r.w - i, y, r.z + i),
		Vector3.new(r.x + i, y, r.z + r.d - i),
		Vector3.new(r.x + r.w - i, y, r.z + r.d - i),
	}
end

local function doorWidth(door: LayoutSchema.Door): number
	return door.width or (if door.kind == "Airlock" then WorldConfig.AirlockDoorWidth else WorldConfig.DoorWidth)
end

-- The layout's own sight test (see the header).
function SpawnRule.layoutSight(layout: Layout): Sight
	local rooms = layout.rooms
	local byId = LayoutSchema.indexRooms(layout)
	local openings: { [string]: { Opening } } = {}
	local function key(a: string, b: string): string
		return if a < b then a .. "|" .. b else b .. "|" .. a
	end
	for _, door in layout.doors do
		if door.kind == "Boarded" or #door.rooms ~= 2 then
			continue
		end
		local a, b = byId[door.rooms[1]], byId[door.rooms[2]]
		local edge = if a and b then LayoutSchema.sharedEdge(a.rect, b.rect) else nil
		if edge then
			local half = doorWidth(door) / 2 - DOOR_MARGIN
			local k = key(door.rooms[1], door.rooms[2])
			openings[k] = openings[k] or {}
			table.insert(
				openings[k],
				{ axis = edge.axis :: string, coord = edge.coord, lo = door.at - half, hi = door.at + half }
			)
		end
	end
	local function roomOf(x: number, z: number, prefer: string?): string?
		if prefer then
			local room = byId[prefer]
			if room and LayoutSchema.rectContains(room.rect, x, z) then
				return prefer
			end
		end
		for _, room in rooms do
			if LayoutSchema.rectContains(room.rect, x, z) then
				return room.id
			end
		end
		return nil
	end
	local function through(a: string, b: string, x0: number, z0: number, x1: number, z1: number): boolean
		local list: { Opening } = openings[key(a, b)] or {}
		for _, opening in list do
			local t: number
			if opening.axis == "X" then
				if math.abs(x1 - x0) < 1e-6 then
					t = 0.5
				else
					t = math.clamp((opening.coord - x0) / (x1 - x0), 0, 1)
				end
				local z = z0 + (z1 - z0) * t
				if z >= opening.lo and z <= opening.hi then
					return true
				end
			else
				if math.abs(z1 - z0) < 1e-6 then
					t = 0.5
				else
					t = math.clamp((opening.coord - z0) / (z1 - z0), 0, 1)
				end
				local x = x0 + (x1 - x0) * t
				if x >= opening.lo and x <= opening.hi then
					return true
				end
			end
		end
		return false
	end
	return function(from: Vector3, to: Vector3): boolean
		local length = MathUtil.flat(to - from).Magnitude
		local samples = math.max(1, math.ceil(length / STEP))
		local current = roomOf(from.X, from.Z, nil)
		if not current then
			return false
		end
		local px, pz = from.X, from.Z
		for i = 1, samples do
			local t = i / samples
			local x = from.X + (to.X - from.X) * t
			local z = from.Z + (to.Z - from.Z) * t
			local here = roomOf(x, z, current)
			if not here then
				return false
			end
			if here ~= current then
				if not through(current, here, px, pz, x, z) then
					return false
				end
				current = here
			end
			px, pz = x, z
		end
		return true
	end
end

-- Every PatrolWaypoint / CreatureSpawn anchor of `layout` with its verdicts, in id order.
function SpawnRule.evaluate(
	layout: Layout,
	picks: Types.ObjectivePicks?,
	entryRoom: string?,
	sight: Sight?
): { Candidate }
	local entry = entryRoom or layout.entry
	local from = ObjectivePlaces.arrivalPoint(layout, entry)
	local lineClear = sight or SpawnRule.layoutSight(layout)
	local eyes = SpawnRule.entryEyes(layout, entry)
	local objective = SpawnRule.objectiveRooms(layout, picks)
	local out: { Candidate } = {}
	for _, anchor in layout.anchors do
		if anchor.kind ~= "PatrolWaypoint" and anchor.kind ~= "CreatureSpawn" then
			continue
		end
		local p = anchor.pos
		local walk = ObjectivePlaces.walkDistance(layout, entry, from, anchor.room, p)
		local visible = false
		for _, height in SPEC.AnchorHeights do
			local target = Vector3.new(p.X, p.Y + height, p.Z)
			for _, eye in eyes do
				if lineClear(eye, target) then
					visible = true
					break
				end
			end
			if visible then
				break
			end
		end
		table.insert(out, {
			id = anchor.id,
			room = anchor.room,
			pos = p,
			walk = walk,
			visible = visible,
			inObjectiveRoom = objective[anchor.room] == true,
			inBand = walk >= SPEC.MinDistance and walk <= SPEC.MaxDistance,
		})
	end
	table.sort(out, function(a: Candidate, b: Candidate): boolean
		return a.id < b.id
	end)
	return out
end

local function gap(c: Candidate): number
	return math.max(0, SPEC.MinDistance - c.walk, c.walk - SPEC.MaxDistance)
end

-- The run's pick on `layout` (see the header).
function SpawnRule.choose(
	seed: number,
	layout: Layout,
	picks: Types.ObjectivePicks?,
	entryRoom: string?,
	sight: Sight?
): Choice
	local all = SpawnRule.evaluate(layout, picks, entryRoom, sight)
	local ok: { Candidate } = {}
	for _, c in all do
		if c.inBand and not c.visible and not c.inObjectiveRoom then
			table.insert(ok, c)
		end
	end
	if #ok > 0 then
		local random = MathUtil.seededRandom(seed, SPEC.Stream .. layout.id)
		return { candidate = ok[random:NextInteger(1, #ok)], fallback = false, candidates = ok }
	end
	local function pool(keep: (Candidate) -> boolean): { Candidate }
		local out: { Candidate } = {}
		for _, c in all do
			if c.walk < math.huge and keep(c) then
				table.insert(out, c)
			end
		end
		return out
	end
	local list = pool(function(c: Candidate): boolean
		return not c.visible and not c.inObjectiveRoom
	end)
	if #list == 0 then
		list = pool(function(c: Candidate): boolean
			return not c.visible
		end)
	end
	if #list == 0 then
		list = pool(function(_c: Candidate): boolean
			return true
		end)
	end
	table.sort(list, function(a: Candidate, b: Candidate): boolean
		local ga, gb = gap(a), gap(b)
		if ga ~= gb then
			return ga < gb
		end
		return a.id < b.id
	end)
	return { candidate = list[1], fallback = true, candidates = {} }
end

return table.freeze(SpawnRule)
