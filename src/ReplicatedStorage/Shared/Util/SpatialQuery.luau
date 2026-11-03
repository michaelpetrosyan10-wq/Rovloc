--!strict
-- Spatial query factories and the point tests that replace Touched. Collision-group-based queries never see
-- NoCollide parts, so volumes (zones, water, triggers) are always tested with plain math, never physics.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)

local SpatialQuery = {}

-- Line-of-sight rays: Default group, so lockers, desks and debris (MonsterPassthrough) block sight
-- while NoCollide volumes and cosmetics are ignored.
function SpatialQuery.losParams(exclude: { Instance }): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.CollisionGroup = "Default"
	params.IgnoreWater = true
	params.RespectCanCollide = false
	return params
end

-- Server flask simulation: hits walls, props and the CreatureHitbox; passes through players and corpses.
function SpatialQuery.projectileParams(exclude: { Instance }): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.CollisionGroup = "Projectiles"
	params.IgnoreWater = true
	return params
end

-- Solid world geometry only (noclip checks, spawn overlap checks, camera collision).
function SpatialQuery.worldParams(exclude: { Instance }): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.CollisionGroup = "Players"
	params.IgnoreWater = true
	params.RespectCanCollide = true
	return params
end

function SpatialQuery.overlapParams(exclude: { Instance }, collisionGroup: string): OverlapParams
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.CollisionGroup = collisionGroup
	params.RespectCanCollide = true
	return params
end

-- Is `point` inside the box described by `cframe` and `size`? Pure math: works for any collision group.
function SpatialQuery.pointInBox(cframe: CFrame, size: Vector3, point: Vector3): boolean
	local localPoint = cframe:PointToObjectSpace(point)
	local half = size * 0.5
	return math.abs(localPoint.X) <= half.X and math.abs(localPoint.Y) <= half.Y and math.abs(localPoint.Z) <= half.Z
end

function SpatialQuery.pointInPart(part: BasePart, point: Vector3): boolean
	return SpatialQuery.pointInBox(part.CFrame, part.Size, point)
end

-- Where the server considers a player's eyes to be (it never sees client-side poses).
function SpatialQuery.eyePoint(root: BasePart, moveState: string): Vector3
	local height = CameraConfig.EyeHeightAboveRoot[moveState] or CameraConfig.EyeHeightAboveRoot.Standing
	return root.Position + Vector3.new(0, height, 0)
end

-- Where the Creature's eyes are for a given PoseMode.
function SpatialQuery.creatureEye(root: BasePart, poseMode: string): Vector3
	local height = CreatureConfig.EyeHeightAboveRoot[poseMode] or CreatureConfig.EyeHeightAboveRoot.Biped
	return root.Position + Vector3.new(0, height, 0)
end

-- True when nothing solid blocks the segment. Hitting something inside `targetModel` also counts as clear.
function SpatialQuery.lineClear(
	origin: Vector3,
	target: Vector3,
	params: RaycastParams,
	targetModel: Instance?
): boolean
	local delta = target - origin
	if delta.Magnitude < 1e-3 then
		return true
	end
	local result = workspace:Raycast(origin, delta, params)
	if not result then
		return true
	end
	return targetModel ~= nil and result.Instance:IsDescendantOf(targetModel)
end

-- Counts solid surfaces between two points (for sound occlusion), up to `maxHits`.
function SpatialQuery.countOccluders(origin: Vector3, target: Vector3, params: RaycastParams, maxHits: number): number
	local hits = 0
	local current = origin
	local remaining = target - origin
	-- Work on a private copy so the caller's params are never mutated.
	local filter = table.clone(params.FilterDescendantsInstances)
	local scratch = RaycastParams.new()
	scratch.FilterType = params.FilterType
	scratch.CollisionGroup = params.CollisionGroup
	scratch.IgnoreWater = params.IgnoreWater
	scratch.RespectCanCollide = params.RespectCanCollide
	scratch.FilterDescendantsInstances = filter
	while hits < maxHits and remaining.Magnitude > 0.05 do
		local result = workspace:Raycast(current, remaining, scratch)
		if not result then
			break
		end
		hits += 1
		table.insert(filter, result.Instance)
		scratch.FilterDescendantsInstances = filter
		local advance = remaining.Unit * 0.05
		current = result.Position + advance
		remaining = target - current
	end
	return hits
end

return table.freeze(SpatialQuery)
