--!strict
-- Volumetrics: the moonlight windows. Every boarded or glazed window above street grade can spill cool moonlight
-- (LightingMood.Moonlight) into its room; this module says where each opening is and which way the moon shines
-- through it. The web export (web/tools/export-world.luau) writes windowSpecs for every layout; the bake bakes a
-- moonlight spill through each one (web/tools/bake/light.mjs) and keeps the specs in meta.windows. Pure: no
-- instances, no clocks.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local LightingMood = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LightingMood)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Volumetrics = {}

local Moon = LightingMood.Moonlight

local UP = Vector3.new(0, 1, 0)

export type WindowSpec = {
	id: string,
	layoutId: string,
	center: Vector3, -- world: the middle of the opening, on the wall line
	inward: Vector3, -- unit, horizontal, into the room
	tangent: Vector3, -- unit, horizontal, along the wall
	width: number,
	height: number,
	direction: Vector3, -- unit: the way the moonlight travels through it
	floorY: number, -- world Y of the floor in front of it
}

local INWARD: { [string]: Vector3 } = {
	N = Vector3.new(0, 0, 1),
	S = Vector3.new(0, 0, -1),
	W = Vector3.new(1, 0, 0),
	E = Vector3.new(-1, 0, 0),
}

-- The way moonlight travels in through a window whose room lies along `inward`: down at the moon's pitch, leaning
-- sideways by its skew (the same turn for every wall, so the rays of one facade run parallel).
function Volumetrics.moonDirection(inward: Vector3): Vector3
	local flat = Vector3.new(inward.X, 0, inward.Z)
	if flat.Magnitude < 1e-6 then
		return -Vector3.yAxis
	end
	local tangent = UP:Cross(flat.Unit)
	local across = (flat.Unit + tangent * Moon.skew).Unit
	return (across * math.cos(Moon.pitch) - Vector3.yAxis * math.sin(Moon.pitch)).Unit
end

-- Every window of `layout` the moon can reach (boarded or glazed; not those below street grade, which look into a
-- soil-filled light well), in world space.
function Volumetrics.windowSpecs(layout: LayoutSchema.LevelLayout): { WindowSpec }
	local out: { WindowSpec } = {}
	local windows = (layout.windows or {}) :: { LayoutSchema.Window }
	if #windows == 0 then
		return out
	end
	local layoutId: string = layout.id
	local rooms = LayoutSchema.indexRooms(layout)
	local origin = WorldConfig.levelOrigin(layout.id)
	local grade = if layout.id == "Lobby"
		then -math.huge
		else WorldConfig.GroundY - WorldConfig.levelElevation(layout.id)
	for index, window in windows do
		local room = rooms[window.room]
		local inward = INWARD[window.side]
		if not room or not inward or window.sill + window.height <= grade then
			continue
		end
		local rect = room.rect
		local x, z
		if window.side == "N" then
			x, z = window.at, rect.z
		elseif window.side == "S" then
			x, z = window.at, rect.z + rect.d
		elseif window.side == "W" then
			x, z = rect.x, window.at
		else
			x, z = rect.x + rect.w, window.at
		end
		table.insert(out, {
			id = string.format("%s:%d", layout.id, index),
			layoutId = layoutId,
			center = origin + Vector3.new(x, window.sill + window.height / 2, z),
			inward = inward,
			tangent = UP:Cross(inward),
			width = window.width,
			height = window.height,
			direction = Volumetrics.moonDirection(inward),
			floorY = origin.Y,
		})
	end
	return out
end

return table.freeze(Volumetrics)
