--!strict
-- Ballistics: a thrown chemical flask's flight, shared by ChemicalProjectileService (the authority: stepped server
-- raycasts) and ChemicalThrowController (the thrower's prediction, the aim arc and every client's playback), so every
-- machine traces the same parabola from the same Launch.
--
-- Flight. position(t) = origin + velocity t + g t² / 2, with g = (0, -gravity, 0) and t the seconds since the flight
-- began (the Launch's startAt). A flask has no drag: its path is the parabola and nothing else.
-- Release. A throw leaves from the thrower's eye (the server: the root + CameraConfig.EyeHeightAboveRoot for the
-- MoveState; the client: its camera eye) plus ReleaseOffset in the throw's frame (right of, below and just ahead of
-- the eye, where the right hand lets go). pullBack keeps that point on the eye's side of anything solid in between,
-- so a flask is never released inside or behind a wall. Speed: GameConfig.FlaskThrowSpeed, x VentTossMultiplier while
-- crawling a duct (a short toss). Throws are refused in the states that hold the body or the hands (BlockedStates).
-- Steps. advance walks the parabola from one flight time to another in segments of at most `maxStep` seconds, casting
-- each one (the server: its raycast plus the pool's surface planes; a client: a cosmetic raycast). The first segment
-- that hits ends the flight there; reaching `maxSeconds` without a hit expires it. trace runs a whole flight (the aim
-- arc) and resample spaces dots evenly along the traced path.
-- Water. surfaceCrossing is where a segment crosses the top face of a PoolWater box, by plain maths (the volumes are
-- NoCollide and never queried), so a flask landing in the pool shatters at its surface.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

-- A cast's first contact along a segment: `fraction` of the way from its start (0..1).
export type Hit = {
	position: Vector3,
	normal: Vector3,
	fraction: number,
	kind: Enums.ProjectileHitKind,
	instance: Instance?,
}

-- Finds the first contact on the segment from -> to (nil when it is clear).
export type Cast = (from: Vector3, to: Vector3) -> Hit?

-- How a stretch of flight ended: `hit` (with `t` the flight time of the contact), or `expired` (t = maxSeconds), or
-- neither (still flying at `t`). `position` is where the flask is at `t`.
export type Advance = {
	hit: Hit?,
	t: number,
	position: Vector3,
	expired: boolean,
}

local GRAVITY = 64 -- studs/s²: a flask thrown level from the eye lands about 30 studs away, a lob reaches 60+
local RELEASE_OFFSET = Vector3.new(0.45, -0.3, -0.6) -- throw frame: X right, Y up, -Z along the throw
local VENT_TOSS_MULTIPLIER = 0.45
local PULL_BACK_SKIN = 0.15 -- studs kept between a pulled-back release point and what blocked it
local DEFAULT_STEP = 1 / 30 -- seconds per cast segment when the caller does not say
local MIN_STEP = 1 / 240
local MAX_SEGMENTS = 4096 -- per advance: a guard against a zero step, never reached in play

local BLOCKED: { Enums.MoveState } = { "Hiding", "Trapped", "Scripted", "Grabbed", "Parachuting" }
local DUCT: { Enums.MoveState } = { "VentCrawling", "VentScurrying" }

local Ballistics = {}

Ballistics.Gravity = GRAVITY
Ballistics.ReleaseOffset = RELEASE_OFFSET
Ballistics.VentTossMultiplier = VENT_TOSS_MULTIPLIER
Ballistics.PullBackSkin = PULL_BACK_SKIN
Ballistics.DefaultStep = DEFAULT_STEP
Ballistics.BlockedStates = table.freeze(table.clone(BLOCKED))

--------------------------------------------------------------------------------
-- Throws
--------------------------------------------------------------------------------

-- Whether a player in `moveState` may throw (not hidden, trapped, scripted, grabbed or parachuting).
function Ballistics.mayThrowIn(moveState: Enums.MoveState): boolean
	return table.find(BLOCKED, moveState) == nil
end

-- Whether `moveState` is crawling a duct (a throw there is a short toss).
function Ballistics.inDuct(moveState: Enums.MoveState): boolean
	return table.find(DUCT, moveState) ~= nil
end

-- The launch speed (studs/s) of a throw made in `moveState`.
function Ballistics.throwSpeed(moveState: Enums.MoveState): number
	local speed = GameConfig.FlaskThrowSpeed
	if Ballistics.inDuct(moveState) then
		return speed * VENT_TOSS_MULTIPLIER
	end
	return speed
end

-- The throw's frame at `eye`: -Z along `direction`, X to the thrower's right, Y up as far as the direction allows (a
-- straight-up or straight-down throw takes world X as its right).
function Ballistics.throwFrame(eye: Vector3, direction: Vector3): CFrame
	local forward = if direction.Magnitude > 1e-6 then direction.Unit else Vector3.new(0, 0, -1)
	local right = forward:Cross(Vector3.yAxis)
	if right.Magnitude < 1e-4 then
		right = Vector3.xAxis
	else
		right = right.Unit
	end
	local up = right:Cross(forward).Unit
	return CFrame.fromMatrix(eye, right, up, -forward)
end

-- Where a throw from `eye` along `direction` leaves the hand (before pullBack).
function Ballistics.releasePoint(eye: Vector3, direction: Vector3): Vector3
	return Ballistics.throwFrame(eye, direction):PointToWorldSpace(RELEASE_OFFSET)
end

-- The release point kept on the eye's side of an obstacle: `point` itself when the line from `eye` is clear
-- (`blockedAt` nil), else PullBackSkin short of where it was blocked (never behind the eye).
function Ballistics.pullBack(eye: Vector3, point: Vector3, blockedAt: Vector3?): Vector3
	if blockedAt == nil then
		return point
	end
	local offset = point - eye
	local length = offset.Magnitude
	if length < 1e-6 then
		return eye
	end
	local reach = math.clamp((blockedAt - eye):Dot(offset / length) - PULL_BACK_SKIN, 0, length)
	return eye + offset / length * reach
end

-- A throw's launch velocity: `direction` (any length) at `speed`.
function Ballistics.launchVelocity(direction: Vector3, speed: number): Vector3
	if direction.Magnitude < 1e-6 then
		return Vector3.zero
	end
	return direction.Unit * speed
end

--------------------------------------------------------------------------------
-- Flight
--------------------------------------------------------------------------------

-- Where the flask is `t` seconds into its flight.
function Ballistics.position(origin: Vector3, velocity: Vector3, gravity: number, t: number): Vector3
	return origin + velocity * t + Vector3.new(0, -0.5 * gravity * t * t, 0)
end

-- The flask's velocity `t` seconds into its flight.
function Ballistics.velocityAt(velocity: Vector3, gravity: number, t: number): Vector3
	return velocity + Vector3.new(0, -gravity * t, 0)
end

-- The flight time at which the flask is highest (0 when it is thrown level or downward).
function Ballistics.apexTime(velocity: Vector3, gravity: number): number
	if gravity <= 0 or velocity.Y <= 0 then
		return 0
	end
	return velocity.Y / gravity
end

-- Flies from flight time `fromT` to `toT` (clamped to `maxSeconds`) in segments of at most `maxStep` seconds, casting
-- each; the first contact ends the flight there.
function Ballistics.advance(
	origin: Vector3,
	velocity: Vector3,
	gravity: number,
	fromT: number,
	toT: number,
	maxSeconds: number,
	maxStep: number?,
	cast: Cast
): Advance
	local start = math.max(0, fromT)
	local finish = math.min(toT, maxSeconds)
	local step = math.max(maxStep or DEFAULT_STEP, MIN_STEP)
	local t = start
	local position = Ballistics.position(origin, velocity, gravity, t)
	local segments = 0
	while t < finish and segments < MAX_SEGMENTS do
		segments += 1
		local nextT = math.min(finish, t + step)
		local nextPosition = Ballistics.position(origin, velocity, gravity, nextT)
		local hit = cast(position, nextPosition)
		if hit then
			local fraction = math.clamp(hit.fraction, 0, 1)
			return { hit = hit, t = t + (nextT - t) * fraction, position = hit.position, expired = false }
		end
		t = nextT
		position = nextPosition
	end
	return { hit = nil, t = t, position = position, expired = t >= maxSeconds - 1e-9 }
end

-- A whole flight from the release: its contact (nil when it expires), the points it passed through (release first,
-- the contact or the last point last) and its duration.
function Ballistics.trace(
	origin: Vector3,
	velocity: Vector3,
	gravity: number,
	maxSeconds: number,
	step: number,
	cast: Cast
): (Hit?, { Vector3 }, number)
	local points: { Vector3 } = { origin }
	local stride = math.max(step, MIN_STEP)
	local t = 0
	local segments = 0
	while t < maxSeconds and segments < MAX_SEGMENTS do
		segments += 1
		local result = Ballistics.advance(origin, velocity, gravity, t, t + stride, maxSeconds, stride, cast)
		table.insert(points, result.position)
		if result.hit then
			return result.hit, points, result.t
		end
		t = result.t
	end
	return nil, points, math.min(t, maxSeconds)
end

-- `count` points evenly spaced by length along the polyline `points` (its first and last included).
function Ballistics.resample(points: { Vector3 }, count: number): { Vector3 }
	local out: { Vector3 } = {}
	if count <= 0 or #points == 0 then
		return out
	end
	if #points == 1 or count == 1 then
		for _ = 1, count do
			table.insert(out, points[1])
		end
		return out
	end
	local lengths: { number } = { 0 }
	for i = 2, #points do
		lengths[i] = lengths[i - 1] + (points[i] - points[i - 1]).Magnitude
	end
	local total = lengths[#points]
	local segment = 2
	for k = 0, count - 1 do
		local target = total * k / (count - 1)
		while segment < #points and lengths[segment] < target do
			segment += 1
		end
		local span = lengths[segment] - lengths[segment - 1]
		local alpha = if span > 1e-9 then (target - lengths[segment - 1]) / span else 1
		table.insert(out, points[segment - 1]:Lerp(points[segment], math.clamp(alpha, 0, 1)))
	end
	return out
end

--------------------------------------------------------------------------------
-- Water
--------------------------------------------------------------------------------

-- Where (0..1 along the segment) `from` -> `to` crosses the top face of the box `cframe` x `size` inside its
-- footprint, either way; nil when it does not.
function Ballistics.surfaceCrossing(cframe: CFrame, size: Vector3, from: Vector3, to: Vector3): number?
	if not (MathUtil.isFiniteVector(from) and MathUtil.isFiniteVector(to)) then
		return nil
	end
	local a = cframe:PointToObjectSpace(from)
	local b = cframe:PointToObjectSpace(to)
	local top = size.Y * 0.5
	local da, db = a.Y - top, b.Y - top
	if da * db > 0 or math.abs(b.Y - a.Y) < 1e-9 then
		return nil
	end
	local fraction = math.clamp(da / (a.Y - b.Y), 0, 1)
	local point = a:Lerp(b, fraction)
	if math.abs(point.X) > size.X * 0.5 or math.abs(point.Z) > size.Z * 0.5 then
		return nil
	end
	return fraction
end

return table.freeze(Ballistics)
