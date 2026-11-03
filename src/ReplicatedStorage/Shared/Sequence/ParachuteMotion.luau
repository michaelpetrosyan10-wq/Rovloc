--!strict
-- ParachuteMotion: the roof jump's rules, shared by ParachuteService (the server's verdicts) and ParachuteController
-- (the jumper's own prediction), so both sides agree on when someone has left the roof, how a canopy flies, when it
-- opens by itself and when it is down. Pure: no services and no clock; callers pass positions and times.
--
-- The roof is Level5_Roof's deck: WorldConfig.FootprintSize from WorldConfig.SchoolOrigin at the level's elevation,
-- walled by a parapet everywhere but the jump gap (the layout's exit room, a stretch of the west edge). A root is off
-- the roof once it is LeaveClear studs past the exterior wall's outer face, or past the face and already dropping
-- under the deck. The stair towers outside the footprint are the stairwells, never the drop.
--
-- Freefall. Nothing slows a jumper until the canopy opens: the cord (ParachutePull) or, AutoDeployClearance studs over
-- the ground, by itself: the late, half-open canopy of the fair auto-deploy, which comes down at HardDescentSpeed for a
-- hard landing. A freefall that lasts FreefallMax (a client holding itself up) is opened by the server.
--
-- Canopy. A LinearVelocity holds the root at canopyVelocity: DescentSpeed down (GameConfig.ParachuteDescentSpeed) and
-- DriftSpeed out along the outward normal of the edge the jumper left (the storm wind carries them away from the
-- building, out over the landing field west of the school). The body faces back up at the ledge the whole way down, so
-- the canopy flies backward on the wind. canopyPosition(from, velocity, elapsed) is the canonical path the server's
-- validator holds a canopy to (descentVerdict): more than PathTolerance above it, or LateralTolerance off it sideways,
-- is put back on it. DeployGrace covers the opening, while the client is still braking.
--
-- Landing: the root within its standing height + LandingSlack over the ground under it (the street, the sidewalk, the
-- field, whatever is there). A packless jumper is dead FatalDrop studs under the deck.
--
-- The jumper's camera (ParachuteController): lookback (locked on the ledge they jumped from, a slow pendulum sway),
-- deployJolt (the opening shock) and landingDip (the knees taking the landing, deeper for a hard one), each scaled by
-- the MotionScale setting. edgeHint picks the warning a player near the jump gap sees.
--
-- Specs: tests/Specs/Parachute.spec.luau.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local RoofLayout = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Layouts.Level5_Roof)

export type DescentInput = {
	position: Vector3, -- the root now
	from: Vector3, -- the root where the canopy opened
	velocity: Vector3, -- the canopy's velocity (canopyVelocity)
	elapsed: number, -- seconds since it opened
	floorY: number, -- the lowest the root can be (the ground under it + the standing height)
}

export type Rect = { minX: number, maxX: number, minZ: number, maxZ: number }

local LEVEL: Enums.LevelId = "Level5_Roof"
local ORIGIN = WorldConfig.levelOrigin(LEVEL)
local DECK_Y = ORIGIN.Y
local FOOTPRINT: Rect = {
	minX = WorldConfig.SchoolOrigin.X,
	maxX = WorldConfig.SchoolOrigin.X + WorldConfig.FootprintSize.X,
	minZ = WorldConfig.SchoolOrigin.Z,
	maxZ = WorldConfig.SchoolOrigin.Z + WorldConfig.FootprintSize.Y,
}
local FACE = WorldConfig.ExteriorWallThickness / 2 -- the exterior wall's outer face, past the footprint's edge
local LEAVE_CLEAR = 2.2
local DROP_Y = 1.5 -- a root under DeckY + this (it stands about 3 over the deck) is falling
local DESCENT = GameConfig.ParachuteDescentSpeed
local HARD_DESCENT = 15
local DRIFT = 7
local AUTO_CLEARANCE = 32
local FATAL_DROP = 26
local FREEFALL_MAX = 3.5
local CANOPY_MAX = 30
local ROOT_HEIGHT = 3 -- an R15 root's centre over the floor it stands on (HipHeight 2 + half the root)
local LANDING_SLACK = 0.9
local PATH_TOLERANCE = 8
local LATERAL_TOLERANCE = 10
local DEPLOY_GRACE = 1.2
local PULL_GRACE = 0.6
local WARN_DISTANCE = 10
local LEDGE_AIM = 2.5 -- the lookback aims this far over the deck at the ledge
local TAU = 2 * math.pi

local function gapRect(): Rect
	for _, room in RoofLayout.rooms do
		if room.id == RoofLayout.exit then
			local r = room.rect
			return {
				minX = ORIGIN.X + r.x,
				maxX = ORIGIN.X + r.x + r.w,
				minZ = ORIGIN.Z + r.z,
				maxZ = ORIGIN.Z + r.z + r.d,
			}
		end
	end
	error("Level5_Roof has no exit room " .. RoofLayout.exit)
end

local GAP = gapRect()

local ParachuteMotion = {}

ParachuteMotion.LevelId = LEVEL
ParachuteMotion.DeckY = DECK_Y
ParachuteMotion.GroundY = WorldConfig.ParachuteLandingY
ParachuteMotion.Footprint = table.freeze(table.clone(FOOTPRINT))
ParachuteMotion.Gap = table.freeze(table.clone(GAP))
ParachuteMotion.OuterFace = FACE
ParachuteMotion.LeaveClear = LEAVE_CLEAR
ParachuteMotion.DescentSpeed = DESCENT
ParachuteMotion.HardDescentSpeed = HARD_DESCENT
ParachuteMotion.DriftSpeed = DRIFT
ParachuteMotion.AutoDeployClearance = AUTO_CLEARANCE
ParachuteMotion.FatalDrop = FATAL_DROP
ParachuteMotion.FreefallMax = FREEFALL_MAX
ParachuteMotion.CanopyMax = CANOPY_MAX
ParachuteMotion.RootHeight = ROOT_HEIGHT
ParachuteMotion.LandingSlack = LANDING_SLACK
ParachuteMotion.PathTolerance = PATH_TOLERANCE
ParachuteMotion.LateralTolerance = LATERAL_TOLERANCE
ParachuteMotion.DeployGrace = DEPLOY_GRACE
ParachuteMotion.PullGrace = PULL_GRACE
ParachuteMotion.WarnDistance = WARN_DISTANCE

--------------------------------------------------------------------------------
-- Where the roof ends
--------------------------------------------------------------------------------

local function rectDistance(rect: Rect, position: Vector3): number
	local dx = math.max(rect.minX - position.X, 0, position.X - rect.maxX)
	local dz = math.max(rect.minZ - position.Z, 0, position.Z - rect.maxZ)
	return math.sqrt(dx * dx + dz * dz)
end

-- Studs the point lies outside the school's footprint, horizontally (0 inside it).
function ParachuteMotion.outside(position: Vector3): number
	return rectDistance(FOOTPRINT, position)
end

-- Whether the point is inside one of the stair towers' footprints (the stairwells beside the school).
function ParachuteMotion.inTower(position: Vector3): boolean
	local origin = WorldConfig.SchoolOrigin
	for _, tower in WorldConfig.Towers do
		local x, z = position.X - origin.X, position.Z - origin.Z
		if x >= tower.minX and x <= tower.maxX and z >= tower.minZ and z <= tower.maxZ then
			return true
		end
	end
	return false
end

-- Whether a root at `position` has left the roof (see the header).
function ParachuteMotion.offRoof(position: Vector3): boolean
	if ParachuteMotion.inTower(position) then
		return false
	end
	local out = ParachuteMotion.outside(position)
	if out <= FACE then
		return false
	end
	return out >= FACE + LEAVE_CLEAR or position.Y < DECK_Y + DROP_Y
end

-- The point of the footprint's edge nearest `position` (horizontally), at deck height.
function ParachuteMotion.edgePoint(position: Vector3): Vector3
	local x = math.clamp(position.X, FOOTPRINT.minX, FOOTPRINT.maxX)
	local z = math.clamp(position.Z, FOOTPRINT.minZ, FOOTPRINT.maxZ)
	if x == position.X and z == position.Z then
		local west, east = x - FOOTPRINT.minX, FOOTPRINT.maxX - x
		local north, south = z - FOOTPRINT.minZ, FOOTPRINT.maxZ - z
		local nearest = math.min(west, east, north, south)
		if nearest == west then
			x = FOOTPRINT.minX
		elseif nearest == east then
			x = FOOTPRINT.maxX
		elseif nearest == north then
			z = FOOTPRINT.minZ
		else
			z = FOOTPRINT.maxZ
		end
	end
	return Vector3.new(x, DECK_Y, z)
end

-- The outward horizontal unit normal of the roof edge nearest `position` (diagonal past a corner).
function ParachuteMotion.outward(position: Vector3): Vector3
	local edge = ParachuteMotion.edgePoint(position)
	local away = MathUtil.flat(position - edge)
	if ParachuteMotion.outside(position) > 1e-3 and away.Magnitude > 1e-3 then
		return away.Unit
	end
	if edge.X == FOOTPRINT.minX then
		return Vector3.new(-1, 0, 0)
	elseif edge.X == FOOTPRINT.maxX then
		return Vector3.new(1, 0, 0)
	elseif edge.Z == FOOTPRINT.minZ then
		return Vector3.new(0, 0, -1)
	end
	return Vector3.new(0, 0, 1)
end

-- Where the jumper's lookback aims: just over the ledge nearest the point they left the roof from.
function ParachuteMotion.ledgeAim(leftFrom: Vector3): Vector3
	return ParachuteMotion.edgePoint(leftFrom) + Vector3.new(0, LEDGE_AIM, 0)
end

-- The warning (a Strings key) for a player on the roof at `position`, or nil: near the jump gap with a pack on, how to
-- go; without one, that the fall will kill them.
function ParachuteMotion.edgeHint(position: Vector3, hasPack: boolean): string?
	if ParachuteMotion.offRoof(position) or rectDistance(GAP, position) > WARN_DISTANCE then
		return nil
	end
	return if hasPack then "Hud.RoofLeap" else "Hud.RoofNoPack"
end

--------------------------------------------------------------------------------
-- The fall and the canopy
--------------------------------------------------------------------------------

-- The canopy's velocity: down at the descent speed (the auto-deploy's harder one when `auto`), drifting along
-- `direction` (flattened; no drift without one).
function ParachuteMotion.canopyVelocity(direction: Vector3, auto: boolean): Vector3
	local flat = MathUtil.flat(direction)
	local drift = if flat.Magnitude > 1e-3 then flat.Unit * DRIFT else Vector3.zero
	return drift + Vector3.new(0, -(if auto then HARD_DESCENT else DESCENT), 0)
end

-- The canonical canopy path: `elapsed` seconds along `velocity` from `from`, never under `floorY`.
function ParachuteMotion.canopyPosition(from: Vector3, velocity: Vector3, elapsed: number, floorY: number): Vector3
	local point = from + velocity * math.max(0, elapsed)
	if point.Y < floorY then
		return Vector3.new(point.X, floorY, point.Z)
	end
	return point
end

-- Whether a freefalling root `rootY` over ground at `groundY` is low enough for the canopy to open by itself.
function ParachuteMotion.autoDeployDue(rootY: number, groundY: number): boolean
	return rootY - groundY <= AUTO_CLEARANCE
end

-- Whether a root `rootY` over ground at `groundY` is down (`rootHeight`: its standing height, default RootHeight).
function ParachuteMotion.landed(rootY: number, groundY: number, rootHeight: number?): boolean
	return rootY - groundY <= (rootHeight or ROOT_HEIGHT) + LANDING_SLACK
end

-- Whether a packless faller at `rootY` is past saving.
function ParachuteMotion.fatal(rootY: number): boolean
	return rootY <= DECK_Y - FATAL_DROP
end

-- The validator's verdict on a canopy (see the header): "Ok", or "Correct" with the point on the canonical path to
-- put the root back on.
function ParachuteMotion.descentVerdict(input: DescentInput): (Types.MovementVerdict, Vector3?)
	if input.elapsed < DEPLOY_GRACE then
		return "Ok", nil
	end
	local expected = ParachuteMotion.canopyPosition(input.from, input.velocity, input.elapsed, input.floorY)
	local position = input.position
	if position.Y > expected.Y + PATH_TOLERANCE then
		return "Correct", expected
	end
	if MathUtil.horizontalDistance(position, expected) > LATERAL_TOLERANCE then
		return "Correct", Vector3.new(expected.X, math.max(input.floorY, math.min(position.Y, expected.Y)), expected.Z)
	end
	return "Ok", nil
end

--------------------------------------------------------------------------------
-- The jumper's camera
--------------------------------------------------------------------------------

-- The locked lookback from `eye` at `target` `t` seconds into the descent: a slow pendulum roll, a little yaw and
-- pitch drift under the canopy. A target straight above is nudged so the view never degenerates.
function ParachuteMotion.lookback(eye: Vector3, target: Vector3, t: number, scale: number): CFrame
	local aim = target
	if MathUtil.flat(aim - eye).Magnitude < 0.5 then
		aim += Vector3.new(0, 0, 0.5)
	end
	local amount = MathUtil.clamp01(scale)
	local roll = math.rad(2.4) * math.sin(t * TAU * 0.14) * amount
	local yaw = math.rad(1.2) * math.sin(t * TAU * 0.085 + 1.3) * amount
	local pitch = math.rad(0.8) * math.sin(t * TAU * 0.11 + 0.4) * amount
	return CFrame.lookAt(eye, aim) * CFrame.Angles(pitch, yaw, roll)
end

-- The opening shock `t` seconds after the canopy opened (applied in eye space): the head snapped down and the body
-- yanked up into the harness, a bounce, settled by 0.9 s.
function ParachuteMotion.deployJolt(t: number, scale: number): CFrame
	local amount = MathUtil.clamp01(scale)
	if t <= 0 or t >= 0.9 or amount <= 0 then
		return CFrame.identity
	end
	local attack = MathUtil.smoothstep(0, 0.05, t)
	local envelope = attack * math.exp(-6 * t) * amount
	local pitch = -math.rad(11) * envelope * math.cos(t * 14)
	local roll = math.rad(3) * envelope * math.sin(t * 23)
	return CFrame.new(0, -0.5 * envelope, 0) * CFrame.Angles(pitch, 0, roll)
end

-- The knees taking the landing `t` seconds after touching down (eye space): down and back up, deeper and slower for a
-- hard landing, with a lurch to the side.
function ParachuteMotion.landingDip(t: number, hard: boolean, scale: number): CFrame
	local amount = MathUtil.clamp01(scale)
	local length = if hard then 1.2 else 0.7
	if t <= 0 or t >= length or amount <= 0 then
		return CFrame.identity
	end
	local u = t / length
	local envelope = MathUtil.smoothstep(0, 0.12, u) * (1 - MathUtil.smoothstep(0.3, 1, u)) * amount
	local depth = if hard then 1.6 else 0.8
	local pitch = -math.rad(if hard then 13 else 6) * envelope
	local roll = if hard then math.rad(5) * envelope * math.sin(t * 9) else 0
	return CFrame.new(0, -depth * envelope, 0) * CFrame.Angles(pitch, 0, roll)
end

return table.freeze(ParachuteMotion)
