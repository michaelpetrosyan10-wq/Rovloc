--!strict
-- Perception: what the Creature sees. Pure rules over injected raycasts; MonsterAIService's brain calls scan() once
-- per tick and reads the Sightings (best first).
--
-- Eyes (ARCHITECTURE §4b). The Creature's eye is its root + CreatureConfig.EyeHeightAboveRoot[PoseMode] in the
-- root's own frame, nudged EyeForward studs along the facing (where the pupils sit). The nudge stays inside the
-- root's half depth, so the eye can never poke through a wall or a closed grate the root is pressed against. A
-- player's EyePoint is their root + CameraConfig.EyeHeightAboveRoot[MoveState]. Sight runs eye to EyePoint only:
-- the server never sees client poses, so limbs are never tested. The default line test is SpatialQuery.lineClear
-- with SpatialQuery.losParams (Default group, every character and the Creature excluded), so walls, lockers, desks
-- and debris block sight and nothing is ever seen through them.
--
-- Who can be seen (judge). A player is a candidate only while LifeStateService says they are playing (Alive or
-- Downed: a Downed player is seen). Never seen: MoveState Hiding (a locker hides you completely); a player in a vent
-- unless the Creature is in a vent too and on the same duct edge or one sharing a node with it (a mouth stub counts
-- as its node); an Underwater player unless the Creature is swimming (PoseMode Swim or MonsterState AquaticStalk).
-- Then range: SightRange x the difficulty's sightRangeMultiplier for a player whose flashlight is on (lit), that
-- x DarknessSightMultiplier for one in the dark; then the view cone (SightHalfAngle either side of the facing, or
-- anything within PeripheralRange whatever the facing); then the line of sight.
--
-- Score (rank). closeness (1 at the eye, 0 at the full lit range) + InCone + Lit + Target (the current TargetUserId,
-- so the Creature does not flip between equally good targets) + Downed (negative: it prefers a standing victim
-- over finishing a downed one when both are in view). Ties: nearer first, then lower UserId.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Instances = require(ReplicatedStorage.Shared.Instances)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)

local FlashlightService = require(ServerScriptService.Services.Player.FlashlightService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local VentNetworkService = require(ServerScriptService.Services.Vents.VentNetworkService)

export type SightContext = {
	difficulty: Enums.Difficulty,
	creatureInVent: boolean,
	creatureSegment: string?,
	-- returns true when the line is clear (default: SpatialQuery.lineClear with losParams)
	raycast: ((from: Vector3, to: Vector3) -> boolean)?,
}

export type Sighting = {
	player: Player,
	eye: Vector3,
	distance: number,
	inCone: boolean,
	lit: boolean,
	score: number,
}

-- One player as the rules need them (observe() reads it from the player services).
export type Observation = {
	player: Player,
	eye: Vector3,
	playing: boolean,
	downed: boolean,
	moveState: Enums.MoveState,
	lit: boolean,
	inVent: boolean,
	rail: VentGraph.RailPoint?, -- where on the duct rail a player in a vent is
}

-- The Creature's side of a scan (viewer() reads it from the model and the context).
export type Viewer = {
	eye: Vector3,
	facing: Vector3,
	difficulty: Enums.Difficulty,
	inVent: boolean,
	ventNodes: { string }?, -- the duct edge's end nodes (one for a mouth stub) under the Creature; nil = unknown
	aquatic: boolean,
	targetUserId: number?,
	raycast: (from: Vector3, to: Vector3) -> boolean,
}

local C = Attributes.Creature
local SENSES = CreatureConfig.Senses

-- Studs the eye sits ahead of the root along its facing: the pupils' place on the hunched face, and less than the
-- root's half depth (RootSize.Z / 2), so the eye never ends up inside a wall the root touches.
local EYE_FORWARD = 0.6
local SAME_SPOT = 1e-6
-- How far from the rail the Creature's root may be when its VentSegmentId is unknown and its duct edge is found by
-- projecting the root onto the rail instead.
local RAIL_SNAP = 4

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
	if difficulty == "Nightmare" then
		return DifficultyConfig.Nightmare
	end
	return DifficultyConfig.Standard
end

-- The Creature's eye for a root frame and PoseMode (see the header).
function Perception.creatureEyeAt(rootCFrame: CFrame, poseMode: string): Vector3
	local height = CreatureConfig.EyeHeightAboveRoot[poseMode] or CreatureConfig.EyeHeightAboveRoot.Biped
	return (rootCFrame * CFrame.new(0, height, -EYE_FORWARD)).Position
end

-- A player's EyePoint for a root position and MoveState.
function Perception.playerEyeAt(rootPosition: Vector3, moveState: string): Vector3
	local height = CameraConfig.EyeHeightAboveRoot[moveState] or CameraConfig.EyeHeightAboveRoot.Standing
	return rootPosition + Vector3.new(0, height, 0)
end

-- How far the Creature sees a player: full range when their flashlight is lit, DarknessSightMultiplier of it in
-- the dark; both scaled by the difficulty.
function Perception.visibleRange(lit: boolean, difficulty: Enums.Difficulty): number
	local range = SENSES.SightRange * difficultySpec(difficulty).sightRangeMultiplier
	return if lit then range else range * SENSES.DarknessSightMultiplier
end

-- Whether `target` is inside the cone of `halfAngleDeg` around `facing` from `eye`, or within `peripheral` studs
-- of the eye whatever the facing. A zero facing has no cone (only the peripheral sphere counts).
function Perception.inViewCone(
	eye: Vector3,
	facing: Vector3,
	target: Vector3,
	halfAngleDeg: number,
	peripheral: number
): boolean
	local offset = target - eye
	local distance = offset.Magnitude
	if distance <= peripheral or distance < SAME_SPOT then
		return true
	end
	if facing.Magnitude < SAME_SPOT then
		return false
	end
	return facing.Unit:Dot(offset / distance) >= math.cos(math.rad(halfAngleDeg)) - 1e-9
end

-- The duct edge (its two end nodes) whose VentShaft SegmentId is `segmentId`, or nil when no edge carries it.
function Perception.segmentNodes(graph: VentGraph.Graph, segmentId: string): { string }?
	local ids: { string } = {}
	for id in graph.nodes do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		for _, other in graph.nodes[id].links do
			if graph.segments[VentGraph.pairKey(id, other)] == segmentId then
				return { id, other }
			end
		end
	end
	return nil
end

-- The nodes of the duct piece under `position` (an edge's two ends, or a mouth stub's one node), nil off the rail.
function Perception.railNodes(graph: VentGraph.Graph, position: Vector3): { string }?
	local rail = VentGraph.nearest(graph, position, RAIL_SNAP)
	if not rail then
		return nil
	end
	local b = rail.b
	return if b then { rail.a, b } else { rail.a }
end

-- Same or adjacent duct: the rail piece a player is on shares a node with the Creature's edge.
function Perception.ventsAdjacent(creatureNodes: { string }, rail: VentGraph.RailPoint): boolean
	if table.find(creatureNodes, rail.a) ~= nil then
		return true
	end
	local b = rail.b
	return b ~= nil and table.find(creatureNodes, b) ~= nil
end

-- Why a player is out of the candidate set before any geometry is tested (nil = still a candidate).
function Perception.excluded(viewer: Viewer, observation: Observation): string?
	if not observation.playing then
		return "NotPlaying"
	end
	if observation.moveState == "Hiding" then
		return "Hiding"
	end
	if observation.moveState == "Underwater" and not viewer.aquatic then
		return "Underwater"
	end
	if observation.inVent then
		local nodes = viewer.ventNodes
		local rail = observation.rail
		if not viewer.inVent or nodes == nil or rail == nil or not Perception.ventsAdjacent(nodes, rail) then
			return "InVent"
		end
	end
	return nil
end

function Perception.score(
	distance: number,
	fullRange: number,
	inCone: boolean,
	lit: boolean,
	isTarget: boolean,
	downed: boolean
): number
	local closeness = if fullRange > 0 then math.clamp(1 - distance / fullRange, 0, 1) else 0
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

-- The Sighting of one player, or nil when the Creature cannot see them (see the header for the order of tests;
-- the raycast runs last, only for players every cheaper rule lets through).
function Perception.judge(viewer: Viewer, observation: Observation): Sighting?
	if Perception.excluded(viewer, observation) ~= nil then
		return nil
	end
	local distance = (observation.eye - viewer.eye).Magnitude
	if distance > Perception.visibleRange(observation.lit, viewer.difficulty) then
		return nil
	end
	if
		not Perception.inViewCone(
			viewer.eye,
			viewer.facing,
			observation.eye,
			SENSES.SightHalfAngle,
			SENSES.PeripheralRange
		)
	then
		return nil
	end
	if not viewer.raycast(viewer.eye, observation.eye) then
		return nil
	end
	local inCone = Perception.inViewCone(viewer.eye, viewer.facing, observation.eye, SENSES.SightHalfAngle, 0)
	local isTarget = viewer.targetUserId ~= nil and viewer.targetUserId == observation.player.UserId
	return {
		player = observation.player,
		eye = observation.eye,
		distance = distance,
		inCone = inCone,
		lit = observation.lit,
		score = Perception.score(
			distance,
			Perception.visibleRange(true, viewer.difficulty),
			inCone,
			observation.lit,
			isTarget,
			observation.downed
		),
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

local function poseModeOf(creature: Model): Enums.PoseMode
	local value = creature:GetAttribute(C.PoseMode)
	for _, mode: Enums.PoseMode in Enums.PoseMode do
		if value == mode then
			return mode
		end
	end
	return "Biped"
end

-- root + EyeHeightAboveRoot[PoseMode] (+ EyeForward along the facing); the model's pivot stands in for a missing root.
function Perception.creatureEye(creature: Model): Vector3
	local root = creatureRoot(creature)
	local frame = if root then root.CFrame else creature.WorldPivot
	return Perception.creatureEyeAt(frame, poseModeOf(creature))
end

-- root + CameraConfig.EyeHeightAboveRoot[MoveState]; nil without a character root.
function Perception.playerEye(player: Player): Vector3?
	local root = Instances.characterRoot(player)
	if not root then
		return nil
	end
	return Perception.playerEyeAt(root.CFrame.Position, PlayerStateService.GetMoveState(player))
end

-- Everything judge() needs about `player`, read from the player services; nil without a character root.
function Perception.observe(player: Player): Observation?
	local eye = Perception.playerEye(player)
	if not eye then
		return nil
	end
	local inVent = VentNetworkService.IsInVent(player)
	return {
		player = player,
		eye = eye,
		playing = LifeStateService.IsPlaying(player),
		downed = LifeStateService.GetState(player) == "Downed",
		moveState = PlayerStateService.GetMoveState(player),
		lit = FlashlightService.IsOn(player),
		inVent = inVent,
		rail = if inVent then VentNetworkService.GetRailPoint(player) else nil,
	}
end

-- Line of sight with the §4b rules: Default group, every character (the scanned players' too) and the Creature
-- excluded.
local function defaultRaycast(creature: Model, players: { Player }): (from: Vector3, to: Vector3) -> boolean
	local exclude: { Instance } = { creature }
	local seen: { [Instance]: boolean } = { [creature] = true }
	local function addCharacter(player: Player)
		local character = player.Character
		if character and not seen[character] then
			seen[character] = true
			table.insert(exclude, character)
		end
	end
	for _, player in Players:GetPlayers() do
		addCharacter(player)
	end
	for _, player in players do
		addCharacter(player)
	end
	local params = SpatialQuery.losParams(exclude)
	return function(from: Vector3, to: Vector3): boolean
		return SpatialQuery.lineClear(from, to, params, nil)
	end
end

-- The duct edge under the Creature: its VentSegmentId's edge when the graph knows it, else the rail piece its root
-- projects onto (ducts whose fittings meet end to end carry no SegmentId).
local function creatureVentNodes(creature: Model, ctx: SightContext): { string }?
	if not ctx.creatureInVent then
		return nil
	end
	local levelId = creature:GetAttribute(C.LevelId)
	if type(levelId) ~= "string" then
		return nil
	end
	local graph = VentNetworkService.GetGraph(levelId)
	if not graph then
		return nil
	end
	local segment = ctx.creatureSegment
	local nodes = if segment then Perception.segmentNodes(graph, segment) else nil
	if nodes then
		return nodes
	end
	local root = creatureRoot(creature)
	return if root then Perception.railNodes(graph, root.CFrame.Position) else nil
end

-- The Creature's side of a scan, read from its model (root, PoseMode, MonsterState, TargetUserId, LevelId).
function Perception.viewer(creature: Model, ctx: SightContext, players: { Player }?): Viewer
	local root = creatureRoot(creature)
	local frame = if root then root.CFrame else creature.WorldPivot
	local target = creature:GetAttribute(C.TargetUserId)
	local poseMode = poseModeOf(creature)
	local state = creature:GetAttribute(C.MonsterState)
	return {
		eye = Perception.creatureEyeAt(frame, poseMode),
		facing = frame.LookVector,
		difficulty = ctx.difficulty,
		inVent = ctx.creatureInVent,
		ventNodes = creatureVentNodes(creature, ctx),
		aquatic = poseMode == "Swim" or state == "AquaticStalk",
		targetUserId = if type(target) == "number" and target > 0 then target else nil,
		raycast = ctx.raycast or defaultRaycast(creature, players or {}),
	}
end

-- Every player in `players` the Creature can see now, best first.
function Perception.scan(creature: Model, players: { Player }, ctx: SightContext): { Sighting }
	local viewer = Perception.viewer(creature, ctx, players)
	local sightings: { Sighting } = {}
	for _, player in players do
		local observation = Perception.observe(player)
		if not observation then
			continue
		end
		local sighting = Perception.judge(viewer, observation)
		if sighting then
			table.insert(sightings, sighting)
		end
	end
	return Perception.rank(sightings)
end

return table.freeze(Perception)
