--!strict
-- Perception: what the Creature sees, and who is looking at it (docs/MONSTER.md 3.2 and 3.3; the website's
-- web/src/creature/perception.js). Pure rules over an injected line test; MonsterAIService builds the Viewer and the
-- Observations and calls scan() once per brain tick.
--
-- Eyes. The Creature's eye is its root + CreatureConfig.EyeHeightAboveRoot[PoseMode] in the root's own frame, nudged
-- EyeForward studs along the facing (inside the root's half depth, so the eye never pokes through a wall the root
-- touches). Its eye is the one of the pose it stands in: hunched under a low clearance, never the standing eye inside a
-- tunnel's ceiling. A player's eye is their root + CameraConfig.EyeHeightAboveRoot[MoveState]. Sight runs eye to eye
-- (SpatialQuery.lineClear with losParams: the Default group, every character and the Creature excluded); walls,
-- lockers, desks and debris block it.
--
-- Who can be seen: only a playing player (Alive or Downed). Never: MoveState Hiding; a player in a duct or a crawlway
-- (it never goes in after them).
-- How far: SightTorch with their torch on, SightLit with it off in a lit pool (the fixture light at their chest,
-- LightField, above LitIrradiance), SightDark with it off in the dark; crouched (or crawling downed) x CrouchFactor;
-- times the difficulty's sightRangeMultiplier. The view cone is SightHalfAngle (MovingHalfAngle while they move), and
-- anything within PeripheralRange (MovingPeripheralRange) is felt whatever the facing; while it looks away
-- (HidingResponse's LookAway) the peripheral sense is off. Then the line of sight.
-- The cone and the peripheral range are measured about its upright axis (the bearing from its facing, the distance
-- along the floor): it stands 11 studs tall and bends its long neck to look down, so whoever is at its feet, standing
-- or downed, is in front of it and felt, not under its field of view.
-- Score: closeness + InCone + Lit + Target - Downed; ties: nearer, then lower UserId.
--
-- The stare: stareAngle() is the angle between a player's view centre and the Creature's head; within Stare.HalfAngle,
-- within stareRange (LitRange when it stands lit or their torch is on, else DarkRange) and with a clear line it counts
-- toward the second that starts a chase.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Instances = require(ReplicatedStorage.Shared.Instances)

local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)

export type Sighting = {
	player: Player,
	eye: Vector3,
	distance: number,
	inCone: boolean,
	lit: boolean, -- their torch is on or they stand lit
	score: number,
}

-- One player as the rules need them (MonsterAIService gathers it).
export type Observation = {
	player: Player,
	eye: Vector3,
	playing: boolean,
	downed: boolean,
	moveState: Enums.MoveState,
	torch: boolean,
	lit: boolean, -- they stand in a lit pool (LightField)
	moving: boolean, -- their speed is above Senses.MovingSpeed
	inVent: boolean, -- in a duct or a crawlway
}

-- The Creature's side of a scan.
export type Viewer = {
	eye: Vector3,
	facing: Vector3,
	difficulty: Enums.Difficulty,
	targetUserId: number?,
	blindPeripheral: boolean?, -- looking away: no peripheral sense
	raycast: (from: Vector3, to: Vector3) -> boolean,
}

-- Someone looking: their eye, their view direction and their torch.
export type Looker = { eye: Vector3, look: Vector3, torch: boolean }

local C = Attributes.Creature
local SENSES = CreatureConfig.Senses
local STARE = CreatureConfig.Stare

-- Studs the eye sits ahead of the root along its facing: less than the root's half depth (RootSize.Z / 2), so the eye
-- never ends up inside a wall the root touches.
local EYE_FORWARD = 0.6
local SAME_SPOT = 1e-6

local ScoreWeights = table.freeze({
	Closeness = 1,
	InCone = 0.35,
	Lit = 0.2,
	Target = 0.5,
	Downed = -0.25,
})

local Perception = {}

Perception.EyeForward = EYE_FORWARD
Perception.ScoreWeights = ScoreWeights

--------------------------------------------------------------------------------
-- Pure rules
--------------------------------------------------------------------------------

local function difficultySpec(difficulty: Enums.Difficulty): DifficultyConfig.DifficultySpec
	return if difficulty == "Nightmare" then DifficultyConfig.Nightmare else DifficultyConfig.Standard
end

-- The Creature's eye for a root frame and PoseMode (the contract's: Biped, Hunched, Quadruped, Stunned).
function Perception.creatureEyeAt(rootCFrame: CFrame, poseMode: string): Vector3
	local height = CreatureConfig.EyeHeightAboveRoot[poseMode] or CreatureConfig.EyeHeightAboveRoot.Biped
	return (rootCFrame * CFrame.new(0, height, -EYE_FORWARD)).Position
end

-- A player's eye point for a root position and MoveState.
function Perception.playerEyeAt(rootPosition: Vector3, moveState: string): Vector3
	local height = CameraConfig.EyeHeightAboveRoot[moveState] or CameraConfig.EyeHeightAboveRoot.Standing
	return rootPosition + Vector3.new(0, height, 0)
end

-- How far the Creature sees a player: by their torch, the light they stand in and their posture.
function Perception.sightRange(o: Observation, difficulty: Enums.Difficulty): number
	local range = if o.torch then SENSES.SightTorch elseif o.lit then SENSES.SightLit else SENSES.SightDark
	if o.moveState == "Crouching" or o.moveState == "DownedCrawling" then
		range *= SENSES.CrouchFactor
	end
	return range * difficultySpec(difficulty).sightRangeMultiplier
end

-- The longest sight range on a difficulty (the score's closeness scale).
function Perception.fullRange(difficulty: Enums.Difficulty): number
	return SENSES.SightTorch * difficultySpec(difficulty).sightRangeMultiplier
end

-- Inside the cone of `halfAngleDeg` around `facing`, or within `peripheral` of the eye, both about the upright axis:
-- the bearing from the flat facing and the distance along the floor.
function Perception.inViewCone(
	eye: Vector3,
	facing: Vector3,
	target: Vector3,
	halfAngleDeg: number,
	peripheral: number
): boolean
	local ox, oz = target.X - eye.X, target.Z - eye.Z
	local distance = math.sqrt(ox * ox + oz * oz)
	if distance <= peripheral or distance < SAME_SPOT then
		return true
	end
	local fl = math.sqrt(facing.X * facing.X + facing.Z * facing.Z)
	if fl < SAME_SPOT then
		return false
	end
	local dot = (facing.X * ox + facing.Z * oz) / (fl * distance)
	return dot >= math.cos(math.rad(halfAngleDeg)) - 1e-9
end

-- Why a player is out of the candidate set before any geometry is tested (nil = still a candidate).
function Perception.excluded(o: Observation): string?
	if not o.playing then
		return "NotPlaying"
	end
	if o.moveState == "Hiding" then
		return "Hiding"
	end
	if o.inVent then
		return "InVent"
	end
	return nil
end

function Perception.score(
	distance: number,
	range: number,
	inCone: boolean,
	lit: boolean,
	isTarget: boolean,
	downed: boolean
): number
	local closeness = if range > 0 then math.clamp(1 - distance / range, 0, 1) else 0
	local score = closeness * ScoreWeights.Closeness
	if inCone then
		score += ScoreWeights.InCone
	end
	if lit then
		score += ScoreWeights.Lit
	end
	if isTarget then
		score += ScoreWeights.Target
	end
	if downed then
		score += ScoreWeights.Downed
	end
	return score
end

-- The Sighting of one player, or nil (the line test runs last).
function Perception.judge(viewer: Viewer, o: Observation): Sighting?
	if Perception.excluded(o) ~= nil then
		return nil
	end
	local distance = (o.eye - viewer.eye).Magnitude
	if distance > Perception.sightRange(o, viewer.difficulty) then
		return nil
	end
	local half = if o.moving then SENSES.MovingHalfAngle else SENSES.SightHalfAngle
	local peripheral = if viewer.blindPeripheral
		then 0
		elseif o.moving then SENSES.MovingPeripheralRange
		else SENSES.PeripheralRange
	if not Perception.inViewCone(viewer.eye, viewer.facing, o.eye, half, peripheral) then
		return nil
	end
	if not viewer.raycast(viewer.eye, o.eye) then
		return nil
	end
	local inCone = Perception.inViewCone(viewer.eye, viewer.facing, o.eye, half, 0)
	local isTarget = viewer.targetUserId ~= nil and viewer.targetUserId == o.player.UserId
	local shown = o.torch or o.lit
	return {
		player = o.player,
		eye = o.eye,
		distance = distance,
		inCone = inCone,
		lit = shown,
		score = Perception.score(distance, Perception.fullRange(viewer.difficulty), inCone, shown, isTarget, o.downed),
	}
end

-- Sorts sightings best first (score, then distance, then UserId) in place and returns them.
function Perception.rank(sightings: { Sighting }): { Sighting }
	table.sort(sightings, function(a: Sighting, b: Sighting): boolean
		if a.score ~= b.score then
			return a.score > b.score
		end
		if a.distance ~= b.distance then
			return a.distance < b.distance
		end
		return a.player.UserId < b.player.UserId
	end)
	return sightings
end

-- Every observed player the viewer can see, best first.
function Perception.scan(viewer: Viewer, observations: { Observation }): { Sighting }
	local out: { Sighting } = {}
	for _, o in observations do
		local sighting = Perception.judge(viewer, o)
		if sighting then
			table.insert(out, sighting)
		end
	end
	return Perception.rank(out)
end

-- Degrees between a look direction from `eye` and the direction to `head` (180 when degenerate).
function Perception.stareAngle(eye: Vector3, look: Vector3, head: Vector3): number
	local offset = head - eye
	local d = offset.Magnitude
	local l = look.Magnitude
	if d < SAME_SPOT or l < SAME_SPOT then
		return 180
	end
	return math.deg(math.acos(math.clamp(look:Dot(offset) / (d * l), -1, 1)))
end

-- How far a stare reaches: LitRange when the Creature stands lit or the player's torch is on, else DarkRange.
function Perception.stareRange(torchOn: boolean, creatureLit: boolean): number
	return if torchOn or creatureLit then STARE.LitRange else STARE.DarkRange
end

-- Whether a look counts toward the stare this tick.
function Perception.staring(
	looker: Looker,
	head: Vector3,
	creatureLit: boolean,
	lineClear: (from: Vector3, to: Vector3) -> boolean,
	halfAngle: number?
): boolean
	if (looker.eye - head).Magnitude > Perception.stareRange(looker.torch, creatureLit) then
		return false
	end
	if Perception.stareAngle(looker.eye, looker.look, head) > (halfAngle or STARE.HalfAngle) then
		return false
	end
	return lineClear(looker.eye, head)
end

--------------------------------------------------------------------------------
-- Reading the world
--------------------------------------------------------------------------------

local function creatureRoot(creature: Model): BasePart?
	local primary = creature.PrimaryPart
	if primary then
		return primary
	end
	local root = creature:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- The contract's pose of a Creature model: PoseMode (Biped / Hunched / Quadruped), Stunned while its
-- MonsterState is.
function Perception.poseOf(creature: Model): string
	if creature:GetAttribute(C.MonsterState) == "Stunned" then
		return "Stunned"
	end
	local value = creature:GetAttribute(C.PoseMode)
	if type(value) == "string" and Enums.has(Enums.PoseMode, value) then
		return value
	end
	return "Biped"
end

-- root + EyeHeightAboveRoot[pose] (+ EyeForward along the facing); the model's pivot stands in for a missing root.
function Perception.creatureEye(creature: Model): Vector3
	local root = creatureRoot(creature)
	local frame = if root then root.CFrame else creature.WorldPivot
	return Perception.creatureEyeAt(frame, Perception.poseOf(creature))
end

-- root + CameraConfig.EyeHeightAboveRoot[MoveState]; nil without a character root.
function Perception.playerEye(player: Player): Vector3?
	local root = Instances.characterRoot(player)
	if not root then
		return nil
	end
	return Perception.playerEyeAt(root.CFrame.Position, PlayerStateService.GetMoveState(player))
end

return table.freeze(Perception)
