--!strict
-- IK: two-bone inverse kinematics and bone-aiming maths in plain Vector3 / CFrame terms. Pure: no instances, no
-- state, frame-rate independent, so every function here is specced (tests/Specs/ProceduralAnimator.spec.luau).
--
-- Two-bone chains (shoulder -> elbow -> wrist, hip -> knee -> ankle) are solved with the law of cosines. The bend
-- plane comes from a pole vector: the middle joint (elbow / knee) always lands on the pole's side of the line from
-- the chain's origin to its tip. Targets out of reach are clamped onto the reachable shell (a hair short of a fully
-- straight chain, so the bend direction never degenerates), and targets closer than the chain can fold are pushed
-- out to the minimum reach.
--
-- Bones are re-oriented with `boneRotation`: a bone lying along `restAxis` (its middle joint protruding toward
-- `restHint` when it bends) is turned to lie along `newAxis` protruding toward `newHint`. Applying the same hint to
-- both bones of a solved chain keeps the middle joint a pure hinge (no twist between the upper and lower bone).

local IK = {}

local EPSILON = 1e-6
-- Fraction of the full chain length a solve may reach: a perfectly straight chain has no bend plane.
local REACH_MARGIN = 0.999
-- Fraction of the folded length (|upper - lower|, or of the chain when the bones are equal) a solve may close to.
local FOLD_MARGIN = 0.05

IK.ReachMargin = REACH_MARGIN
IK.FoldMargin = FOLD_MARGIN

export type Solution = {
	mid: Vector3, -- the middle joint (elbow / knee)
	tip: Vector3, -- where the chain's end lands: the target, clamped into the chain's reach
	bend: Vector3, -- unit direction from the origin -> tip line toward the middle joint (the pole's side)
	reached: boolean, -- false when the target had to be clamped (too far or too close)
	distance: number, -- origin -> tip distance actually solved
}

-- Any unit vector perpendicular to `v` (which must not be zero).
function IK.perpendicular(v: Vector3): Vector3
	local unit = v.Unit
	-- Cross with the world axis least aligned with v.
	local axis = if math.abs(unit.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
	return unit:Cross(axis).Unit
end

-- The part of `v` perpendicular to the unit vector `axis`, normalized. When `v` is (nearly) parallel to the axis,
-- `fallback` (made perpendicular the same way) or any perpendicular is used instead.
function IK.orthogonalize(v: Vector3, axis: Vector3, fallback: Vector3?): Vector3
	local projected = v - axis * v:Dot(axis)
	if projected.Magnitude > 1e-4 then
		return projected.Unit
	end
	if fallback then
		local other = fallback - axis * fallback:Dot(axis)
		if other.Magnitude > 1e-4 then
			return other.Unit
		end
	end
	return IK.perpendicular(axis)
end

-- `target` pulled along the line from `origin` so its distance lies in [minReach, maxReach]. Returns the clamped
-- point and whether it is the target itself. A target on the origin is pushed out along `fallback`.
function IK.clampReach(
	origin: Vector3,
	target: Vector3,
	minReach: number,
	maxReach: number,
	fallback: Vector3
): (Vector3, boolean)
	local delta = target - origin
	local distance = delta.Magnitude
	local direction = if distance > EPSILON then delta / distance else fallback.Unit
	local clamped = math.clamp(distance, minReach, maxReach)
	if math.abs(clamped - distance) <= 1e-9 then
		return target, true
	end
	return origin + direction * clamped, false
end

-- Interior angle at the middle joint (radians; pi = straight) of a chain spanning `distance` between its ends.
function IK.jointAngle(upper: number, lower: number, distance: number): number
	local cosine = (upper * upper + lower * lower - distance * distance) / (2 * upper * lower)
	return math.acos(math.clamp(cosine, -1, 1))
end

-- Solves origin -> mid -> tip with bone lengths `upper` and `lower` so the tip lands on `target` (clamped into
-- reach) and the middle joint sits on the `pole` side of the origin -> tip line.
function IK.solveTwoBone(origin: Vector3, target: Vector3, upper: number, lower: number, pole: Vector3): Solution
	local maxReach = (upper + lower) * REACH_MARGIN
	local fold = math.abs(upper - lower)
	local minReach = math.max(fold, (upper + lower) * FOLD_MARGIN) * (1 + 1e-3)
	local fallback = if pole.Magnitude > EPSILON then IK.perpendicular(pole) else -Vector3.yAxis
	local tip, reached = IK.clampReach(origin, target, minReach, maxReach, fallback)
	local delta = tip - origin
	local distance = delta.Magnitude
	local direction = delta / distance
	local bend = IK.orthogonalize(if pole.Magnitude > EPSILON then pole.Unit else fallback, direction)
	local cosine = math.clamp((upper * upper + distance * distance - lower * lower) / (2 * upper * distance), -1, 1)
	local sine = math.sqrt(math.max(0, 1 - cosine * cosine))
	local mid = origin + direction * (upper * cosine) + bend * (upper * sine)
	return {
		mid = mid,
		tip = tip,
		bend = bend,
		reached = reached,
		distance = distance,
	}
end

-- A rotation-only CFrame whose +Y axis is `axis` and whose -Z axis leans toward `hint` (made perpendicular).
function IK.frame(axis: Vector3, hint: Vector3): CFrame
	local y = axis.Unit
	local front = IK.orthogonalize(hint, y)
	local z = -front
	local x = y:Cross(z)
	return CFrame.fromMatrix(Vector3.zero, x, y, z)
end

-- The rotation that turns a bone lying along `restAxis` (bending toward `restHint`) so it lies along `newAxis`
-- (bending toward `newHint`).
function IK.boneRotation(restAxis: Vector3, restHint: Vector3, newAxis: Vector3, newHint: Vector3): CFrame
	return IK.frame(newAxis, newHint) * IK.frame(restAxis, restHint):Inverse()
end

-- The smallest rotation taking the direction `from` onto the direction `to` (both non-zero).
function IK.aim(from: Vector3, to: Vector3): CFrame
	local a = from.Unit
	local b = to.Unit
	local cosine = math.clamp(a:Dot(b), -1, 1)
	if cosine > 1 - 1e-9 then
		return CFrame.identity
	end
	if cosine < -1 + 1e-9 then
		return CFrame.fromAxisAngle(IK.perpendicular(a), math.pi)
	end
	return CFrame.fromAxisAngle(a:Cross(b).Unit, math.acos(cosine))
end

-- A rotation's axis and angle with the angle folded into [0, pi] (the axis flips for the folded half).
local function shortestAxisAngle(rotation: CFrame): (Vector3, number)
	local axis, angle = rotation:ToAxisAngle()
	if axis.Magnitude < EPSILON then
		return Vector3.yAxis, 0
	end
	local unit = axis.Unit
	angle %= 2 * math.pi
	if angle > math.pi then
		return -unit, 2 * math.pi - angle
	end
	return unit, angle
end

-- `rotation` with its angle limited to `maxAngle` radians (same axis, shortest way round). Translation is dropped.
function IK.limitRotation(rotation: CFrame, maxAngle: number): CFrame
	local axis, angle = shortestAxisAngle(rotation)
	if angle <= maxAngle then
		return rotation.Rotation
	end
	return CFrame.fromAxisAngle(axis, math.max(0, maxAngle))
end

-- Angle (radians, 0..pi) of a rotation, ignoring its axis.
function IK.angleOf(rotation: CFrame): number
	local _, angle = shortestAxisAngle(rotation)
	return angle
end

return table.freeze(IK)
