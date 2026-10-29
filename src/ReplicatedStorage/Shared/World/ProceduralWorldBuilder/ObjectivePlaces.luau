--!strict
-- ObjectivePlaces: pure layout maths over the floor objectives' anchors, shared by the specs and the web data notes.
--
--   places(layout)            every objective spot of a layout: the item candidates, the stations and the locks
--   hideSpots(layout)         where a player can get out of the Creature's way on that floor:
--                               Locker      a hideable locker (every floor)
--                               Vent        the mouth of a grate the director never locks and no hatch shuts
--                               DarkCorner  a room corner or a pillar no burning light reaches (the basement, where
--                                           nothing hunts)
--                               DryFooting  out of the water (the pool, where the Creature cannot leave the water)
--                               Cover       a plant block to crouch behind, at least CoverHeight tall (the roof)
--   nearestHide(layout, place) the closest hide spot the place can use, with its distance (straight line; lockers and
--                              vents only count in the place's own room or a room joined to it by a doorway)
-- ObjectiveConfig.HideReach is how close one must be.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)

local PoolWaterBuilder = require(script.Parent.Props.PoolWaterBuilder)

type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor

export type HideKind = "Locker" | "Vent" | "DarkCorner" | "DryFooting" | "Cover"

export type Place = { id: string, kind: Enums.AnchorKind, room: string, pos: Vector3 }

export type Hide = { kind: HideKind, id: string, room: string, pos: Vector3, distance: number }

local ObjectivePlaces = {}

ObjectivePlaces.CoverHeight = 3.5
ObjectivePlaces.CornerInset = 1.5
ObjectivePlaces.ClimbBand = table.freeze({ min = 0.1, max = 2.3 }) -- SwimController's climb-out band over the water

local STATION_KINDS: { [string]: boolean } = {
	BreakerPanel = true,
	FumeHood = true,
	Generator = true,
	StoreLock = true,
	HatchValve = true,
	CrateChain = true,
	ExitLock = true,
}

-- Every objective spot of `layout` in layout order: the floor's item candidates, its stations and its locks.
function ObjectivePlaces.places(layout: Layout): { Place }
	local spec = ObjectiveConfig.forLevel(layout.id)
	local out: { Place } = {}
	for _, anchor in layout.anchors do
		if (spec and anchor.kind == spec.item.candidate) or STATION_KINDS[anchor.kind] then
			table.insert(out, { id = anchor.id, kind = anchor.kind, room = anchor.room, pos = anchor.pos })
		end
	end
	return out
end

-- Rooms joined to `room` by a passable door or doorway (and the room itself).
local function neighbours(layout: Layout, room: string): { [string]: boolean }
	local out: { [string]: boolean } = { [room] = true }
	for _, door in layout.doors do
		if door.kind == "Boarded" or #door.rooms ~= 2 then
			continue
		end
		if door.rooms[1] == room then
			out[door.rooms[2]] = true
		elseif door.rooms[2] == room then
			out[door.rooms[1]] = true
		end
	end
	return out
end

local function litAt(layout: Layout, point: Vector3): boolean
	for _, room in layout.rooms do
		for _, light in (room.lights or {}) :: { LayoutSchema.Light } do
			local flat = Vector3.new(light.pos.X, 0, light.pos.Z)
			if not light.broken and (flat - point).Magnitude < light.range then
				return true
			end
		end
	end
	return false
end

-- Room corners (and the far sides of pillars) no burning light reaches.
local function darkCorners(layout: Layout): { Hide }
	local out: { Hide } = {}
	for _, room in layout.rooms do
		if room.kind == "Chase" or room.kind == "Airlock" or room.kind == "Stairwell" then
			continue
		end
		local r = room.rect
		local inset = ObjectivePlaces.CornerInset
		for i, corner in
			{
				Vector3.new(r.x + inset, 0, r.z + inset),
				Vector3.new(r.x + r.w - inset, 0, r.z + inset),
				Vector3.new(r.x + inset, 0, r.z + r.d - inset),
				Vector3.new(r.x + r.w - inset, 0, r.z + r.d - inset),
			}
		do
			if not litAt(layout, corner) then
				table.insert(
					out,
					{ kind = "DarkCorner", id = room.id .. "#" .. i, room = room.id, pos = corner, distance = 0 }
				)
			end
		end
	end
	for i, pillar in (layout.pillars or {}) :: { LayoutSchema.Pillar } do
		local point = Vector3.new(pillar.x, 0, pillar.z)
		if not litAt(layout, point) then
			table.insert(out, {
				kind = "DarkCorner",
				id = string.format("%s#pillar%d", pillar.room, i),
				room = pillar.room,
				pos = point,
				distance = 0,
			})
		end
	end
	return out
end

-- Grates a HatchValve shuts (not a way out until the objective opens it).
local function hatched(layout: Layout): { [string]: boolean }
	local out: { [string]: boolean } = {}
	local vents = layout.vents
	if not vents then
		return out
	end
	local nodes: { [string]: LayoutSchema.VentNodeSpec } = {}
	for _, node in vents.nodes do
		nodes[node.id] = node
	end
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

-- Every hide spot of `layout` (distance 0; nearestHide fills it in).
function ObjectivePlaces.hideSpots(layout: Layout): { Hide }
	local out: { Hide } = {}
	for _, anchor in layout.anchors do
		if anchor.kind == "Locker" then
			table.insert(out, { kind = "Locker", id = anchor.id, room = anchor.room, pos = anchor.pos, distance = 0 })
		end
	end
	local vents = layout.vents
	if vents then
		local nodes: { [string]: LayoutSchema.VentNodeSpec } = {}
		for _, node in vents.nodes do
			nodes[node.id] = node
		end
		local shut = hatched(layout)
		for _, grate in vents.grates do
			local node = nodes[grate.node]
			if node and not grate.lockable and not shut[grate.id] then
				table.insert(out, {
					kind = "Vent",
					id = grate.id,
					room = grate.room,
					pos = Vector3.new(node.x, LayoutSchema.ventNodeY(node), node.z),
					distance = 0,
				})
			end
		end
	end
	if layout.id == "Level0_Basement" then
		for _, corner in darkCorners(layout) do
			table.insert(out, corner)
		end
	elseif layout.id == "Level5_Roof" then
		for _, platform in (layout.platforms or {}) :: { LayoutSchema.Platform } do
			if platform.top >= ObjectivePlaces.CoverHeight then
				local r = platform.rect
				table.insert(out, {
					kind = "Cover",
					id = platform.id,
					room = platform.room,
					pos = Vector3.new(r.x + r.w / 2, 0, r.z + r.d / 2),
					distance = 0,
				})
			end
		end
	end
	return out
end

local function platformById(layout: Layout, id: string): LayoutSchema.Platform?
	for _, platform in (layout.platforms or {}) :: { LayoutSchema.Platform } do
		if platform.id == id then
			return platform
		end
	end
	return nil
end

-- The closest hide spot `place` can use on `layout`, or nil when the floor has none in reach of it.
function ObjectivePlaces.nearestHide(layout: Layout, place: Place): Hide?
	local best: Hide? = nil
	local function consider(hide: Hide, distance: number)
		if best == nil or distance < (best :: Hide).distance then
			best = { kind = hide.kind, id = hide.id, room = hide.room, pos = hide.pos, distance = distance }
		end
	end
	local near = neighbours(layout, place.room)
	local flat = Vector3.new(place.pos.X, 0, place.pos.Z)
	for _, hide in ObjectivePlaces.hideSpots(layout) do
		local d = (Vector3.new(hide.pos.X, 0, hide.pos.Z) - flat).Magnitude
		if hide.kind == "Cover" then
			local platform = platformById(layout, hide.id)
			if platform then
				consider(hide, PoolWaterBuilder.pointGap(platform.rect, flat.X, flat.Z))
			end
		elseif hide.kind == "DarkCorner" then
			if hide.room == place.room then
				consider(hide, d)
			end
		elseif near[hide.room] then
			consider(hide, d)
		end
	end
	for _, basin in (layout.basins or {}) :: { LayoutSchema.Basin } do
		local groups =
			PoolWaterBuilder.dryGroups(layout, basin, ObjectivePlaces.ClimbBand.min, ObjectivePlaces.ClimbBand.max)
		local swim = PoolWaterBuilder.swimToDry(groups, flat.X, flat.Z)
		if basin.room == place.room then
			consider({ kind = "DryFooting", id = basin.id, room = basin.room, pos = place.pos, distance = 0 }, swim)
		end
	end
	return best
end

return table.freeze(ObjectivePlaces)
