--!strict
-- ChemicalProjectileService: the Science Hall's volatile chemical flasks (spec, Level 2; ARCHITECTURE §4b rule 3,
-- §4c). The only writer of a player's HeldItem and HeldItemVariant and of a ChemicalItem's HeldByUserId. A thrown
-- flask has no server part: the server traces its flight with stepped raycasts and every client draws the same
-- parabola from the Launch (Shared/Util/Ballistics).
--
-- World flasks. Every ChemicalItem-tagged Model under Workspace.Runtime is tracked (CollectionService added /
-- removed, plus a scan at BeginRun: WorldService builds the run's props in its own BeginRun before this one), with
-- its look (the plan prop's variant, read back from the plan by AnchorId; flasks built by SpawnFlask know theirs).
-- The Pickup handler serves the prompts of tracked, untaken flasks: an Alive player whose hands are free holds it
-- for the prompt's 0.35 s (InteractionService times it; a second flask is refused with Hud.FlaskHandsFull). Taking
-- it writes the flask's HeldByUserId, plays the Pickup cue there and removes the prop from the world; the player's
-- HeldItem becomes "ChemicalFlask" and HeldItemVariant its variant. One flask at a time.
--
-- Throws (ItemThrow { direction }). Accepted when throwEligible holds: the run is live, the player holds a flask, is
-- Alive with a living body and no control lock, is not Hiding / Trapped / Scripted / Grabbed / Parachuting
-- (Ballistics.mayThrowIn), GameConfig.FlaskThrowCooldown has passed since their last throw, and `direction` is
-- within LookTolerance (25 degrees) of the look the server last heard (PlayerStateService.GetLook). The flask leaves
-- from the eye (the root + CameraConfig.EyeHeightAboveRoot for the MoveState) plus Ballistics.ReleaseOffset, pulled
-- back toward the eye (and the eye toward the root) when something solid is in between, at
-- GameConfig.FlaskThrowSpeed (x Ballistics.VentTossMultiplier, a short toss, while crawling a duct) under
-- Ballistics.Gravity. The hand empties at once, RunStats FlasksThrown counts it, and ProjectileEvent "Spawn" (the
-- Launch: id, origin, velocity, gravity, t0 = startAt, variant, thrower) goes to everyone.
--
-- Flight. Every Heartbeat each flask flies on from where it was to where server time says it is now, in cast segments
-- of at most StepSeconds: a raycast in the Projectiles group (walls, props and the CreatureHitbox; every character
-- excluded) and the PoolWater volumes' top faces by plain maths (Ballistics.surfaceCrossing). The first contact
-- shatters it there; GameConfig.FlaskMaxFlightSeconds without one expires it (ProjectileEvent "Resolve", hitKind
-- Expired: nothing happens).
--
-- Shatter. ProjectileEvent "Resolve" (hitPosition, hitNormal, hitKind World / Creature / Water, inVent) to everyone,
-- the FlaskShatter noise (sourceUserId = the thrower; the Vent medium and the duct's VentNode when it broke inside a
-- duct), the FlaskShatter cue at the point and the ChemHiss loop at the cloud for GameConfig.FlaskCloudSeconds, the
-- Shattered signal (point, thrower, inVent). A shatter is in a duct (inVent) when its point lies inside the square
-- bore (WorldConfig.VentBore) of the level's VentGraph: along a duct (up to half a bore past its ends, where elbows
-- and dead ends run on) or a grate's opening up to the room face of its wall (ductNode).
--
-- Clouds. Each shatter leaves a cloud CloudLift studs off the surface for GameConfig.FlaskCloudSeconds. It stuns the
-- Creature at most once (stunVerdict), checked at the shatter and then at GameConfig.ServerTickHz, so a Creature
-- that walks into a lingering cloud is stunned too:
--   * the Creature is on the cloud's level, not Hidden, and in a state a stun can interrupt (not already Stunned,
--     Scripted or Dormant; a cloud that meets a stunned Creature keeps its charge),
--   * and either the cloud broke inside a duct, the Creature is in one too (its InVent / VentSegmentId) and the
--     VentGraph hops between the cloud's node and the Creature's are at most GameConfig.FlaskVentHopRadius,
--   * or its CreatureHitbox is within GameConfig.FlaskCloudRadius of the cloud with a clear line from the cloud to
--     it (Default-group LOS, characters and the Creature excluded; any of its centre, its nearest point or its top
--     will do): gas never reaches through a wall.
-- A stun is MonsterAIService.Stun(GameConfig.StunSeconds, shatter point) (the Creature retreats away from it; in a
-- duct along VentPathfinder.retreatPath) and counts RunStats Stuns for the thrower.
--
-- The acid flask (Floor 2's objective, ObjectiveService). GiveAcid puts it in a free hand (HeldItem "AcidFlask"):
-- it is thrown exactly like a flask (the Launch carries item = "AcidFlask" so clients draw the acid) but breaks without
-- a stun cloud or a stun: AcidShattered(point, thrower) instead, and ObjectiveService decides whether it burnt the
-- chain. TakeAcid empties the hand (the Pour at the chained door). A flight that expires without contact, or a hand
-- emptied any other way (dying, spectating, the run ending), fires AcidLost(player): the acid is gone.
--
-- Item lifecycle. Downed players keep their flask (and cannot throw it); dying, spectating, the lobby, leaving and
-- the end of the run empty the hand. Give (dev / scripted) puts a flask in a playing player's free hand; SpawnFlask
-- builds a world flask during a run (Level 2's restock); CountAvailable counts the untaken ones on a level.
--
-- Dev commands: flask [spawn] [variant] (a flask in your hand, or a world flask at your feet), flasks (read-only:
-- world flasks per level, who holds one, flights and clouds).
--
-- Pure rules (tests/Specs/Chemical.spec.luau): withinLook, throwEligible, pickupEligible, stunnableState,
-- boxDistance, reachPoints, cloudReaches, stunVerdict, boreOffset, ductNode, snapNode, ventHops, creatureVentNode,
-- variantForColor. SetDependencies swaps the clock, the casts, the line of sight, the Creature, the vent graphs, the
-- Creature's brain and the ProjectileEvent sender, so specs fly flasks and stun on a fake clock.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Ballistics = require(ReplicatedStorage.Shared.Util.Ballistics)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)
local VentPathfinder = require(ReplicatedStorage.Shared.Vents.VentPathfinder)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local ChemicalFlaskBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.ChemicalFlaskBuilder)
local CreatureRigBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.CreatureRigBuilder)

local AudioService = require(ServerScriptService.Services.Core.AudioService)
local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local WorldService = require(ServerScriptService.Services.Core.WorldService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local MonsterAIService = require(ServerScriptService.Services.Monster.MonsterAIService)
local VentNetworkService = require(ServerScriptService.Services.Vents.VentNetworkService)

local log = Log.new("Chemical")

local P = Attributes.Player
local M = Attributes.Match
local W = Attributes.World
local C = Attributes.Creature
local RIG = CreatureRigBuilder.PartNames

local ITEM: Enums.ItemId = "ChemicalFlask"
local ACID_ITEM: Enums.ItemId = "AcidFlask"
local NO_ITEM: Enums.ItemId = "None"
local PICKUP_KIND: Enums.PromptKind = "Pickup"
local SHATTER_NOISE: Enums.NoiseKind = "FlaskShatter"
local VENT_MEDIUM: Enums.NoiseMedium = "Vent"
local THROWN_STAT: Enums.StatKey = "FlasksThrown"
local STUN_STAT: Enums.StatKey = "Stuns"
local SPAWN_PHASE: Enums.ProjectilePhase = "Spawn"
local RESOLVE_PHASE: Enums.ProjectilePhase = "Resolve"
local EXPIRED: Enums.ProjectileHitKind = "Expired"
local SHATTER_PRESET = "FlaskShatter"
local HISS_PRESET = "ChemHiss"
local ACID_PRESET = "ObjAcidSizzle"
local PICKUP_PRESET = "Pickup"
local HANDS_FULL = "Hud.FlaskHandsFull" -- the refusal InteractionService shows a player who already holds a flask
local DEFAULT_LEVEL: Enums.LevelId = "Level2_ScienceHall"

local LOOK_TOLERANCE = 25 -- degrees between a throw's direction and the server's look
local STEP_SECONDS = 1 / 60 -- longest cast segment of a flight (a server hitch never skips a wall)
local CLOUD_LIFT = 0.6 -- studs between the shattered surface and the cloud's centre
local HALF_BORE = WorldConfig.VentBore / 2
local BORE_SKIN = 0.1 -- a contact on the bore's inner face is inside; the duct shell's outer face is 0.2 further
local FACE_MARGIN = 0.05 -- a grate opening's contact must be this far behind the room face to count as in the duct
local REACH_PULL = 0.25 -- the nearest-point LOS target is pulled this share toward the hitbox centre
local TOP_INSET = 0.3 -- studs below the hitbox top for the top LOS target
local GIVE_VARIANTS = 10000 -- Give without a variant draws one of this many looks

local LIVE_PHASES: { [string]: boolean } = { Deploying = true, InRun = true }
local UNSTUNNABLE: { Enums.MonsterState } = { "Stunned", "Scripted", "Dormant" }

-- Everything throwEligible looks at for one throw (gathered by RequestThrow; specs build it by hand).
export type ThrowCheck = {
	live: boolean, -- the run is live (Deploying / InRun)
	holding: boolean,
	lifeState: Enums.LifeState,
	moveState: Enums.MoveState,
	controlLock: Enums.ControlLock,
	hasBody: boolean, -- a living character with a root
	now: number, -- server time
	lastThrowAt: number?, -- server time of the player's previous throw
	direction: Vector3, -- the ItemThrow direction
	look: Vector3, -- the server's latest look (PlayerStateService.GetLook)
}

export type PickupCheck = {
	live: boolean,
	lifeState: Enums.LifeState,
	holding: boolean,
	taken: boolean, -- someone already took this flask
}

-- What stunVerdict knows of a cloud.
export type CloudView = {
	centre: Vector3,
	levelId: string?,
	ventNode: string?, -- the duct's VentNode when it broke inside one
	expiresAt: number,
	spent: boolean,
}

-- What stunVerdict knows of the Creature.
export type CreatureView = {
	levelId: string?,
	state: Enums.MonsterState,
	hidden: boolean,
	inVent: boolean,
	segmentId: string?,
	rootPosition: Vector3,
	hitboxCFrame: CFrame,
	hitboxSize: Vector3,
}

export type StunReason =
	"Spent"
	| "Expired"
	| "NoCreature"
	| "Level"
	| "Hidden"
	| "State"
	| "OutOfReach"
	| "Vent"
	| "Radius"

-- True when nothing solid lies between two points.
export type LineClear = (from: Vector3, to: Vector3) -> boolean

-- The first contact on a segment, ignoring `exclude`; `water` adds the PoolWater surfaces (flights; not releases).
export type Caster = (from: Vector3, to: Vector3, exclude: { Instance }, water: boolean) -> Ballistics.Hit?

-- The two members of MonsterAIService this service uses.
export type MonsterApi = {
	Stun: (seconds: number, from: Vector3) -> (),
	GetState: () -> Enums.MonsterState,
}

-- Fakes for specs (each nil field keeps the real one).
export type Dependencies = {
	now: (() -> number)?, -- server time
	cast: Caster?,
	lineClear: ((creature: Model?) -> LineClear)?,
	creature: (() -> Model?)?,
	graph: ((levelId: string) -> VentGraph.Graph?)?,
	monster: MonsterApi?,
	publish: ((payload: Types.ProjectileEventPayload) -> ())?,
}

-- A flask in flight. `t` is how far (seconds) the server has traced it.
export type Flight = {
	id: number,
	thrower: Player?,
	throwerUserId: number?,
	origin: Vector3,
	velocity: Vector3,
	gravity: number,
	startAt: number,
	t: number,
	levelId: Enums.LevelId,
	variant: number,
	exclude: { Instance },
	acid: boolean?, -- the objective's acid flask
}

export type Cloud = {
	id: number,
	point: Vector3, -- where it shattered
	centre: Vector3,
	levelId: Enums.LevelId,
	ventNode: string?,
	inVent: boolean,
	thrower: Player?,
	expiresAt: number,
	spent: boolean,
}

type Flask = {
	model: Model,
	levelId: Enums.LevelId?,
	variant: number,
	taken: boolean,
}

local ChemicalProjectileService = {}

ChemicalProjectileService.Name = "ChemicalProjectileService"
ChemicalProjectileService.LookTolerance = LOOK_TOLERANCE
ChemicalProjectileService.StepSeconds = STEP_SECONDS
ChemicalProjectileService.CloudLift = CLOUD_LIFT
ChemicalProjectileService.HandsFullHint = HANDS_FULL

local shattered: Signal.Signal<Vector3, Player?, boolean> = Signal.new()
local acidShattered: Signal.Signal<Vector3, Player?> = Signal.new()
local acidLost: Signal.Signal<Player?> = Signal.new()

-- (point, thrower) where a thrown acid flask broke (ObjectiveService: the chain on Floor 2's exit).
ChemicalProjectileService.AcidShattered = acidShattered
-- (player) an acid flask is gone without breaking anywhere: a flight that expired, a hand emptied.
ChemicalProjectileService.AcidLost = acidLost

-- (point, thrower, inVent) after a flask shattered (P7: a shatter near a grabbed player releases the grab).
ChemicalProjectileService.Shattered = shattered

local serviceTrove = Trove.new()
local deps: Dependencies = {}
local held: { [Player]: number } = {} -- player -> the held flask's variant
local lastThrowAt: { [Player]: number } = {}
local flasks: { [Model]: Flask } = {}
local flights: { [number]: Flight } = {}
local clouds: { Cloud } = {}
local waters: { [BasePart]: boolean } = {}
local adjacencyCache: { [VentGraph.Graph]: { [string]: { string } } } = setmetatable({}, { __mode = "k" }) :: any
local running = false
local live = false
local runSeed = 0
local nextFlightId = 0
local nextCloudId = 0
local spawnCount = 0
local giveCount = 0
local initialized = false

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/Chemical.spec.luau)
--------------------------------------------------------------------------------

-- Whether `direction` points within `maxDegrees` of `look` (both finite and non-zero).
function ChemicalProjectileService.withinLook(direction: Vector3, look: Vector3, maxDegrees: number): boolean
	if not (MathUtil.isFiniteVector(direction) and MathUtil.isFiniteVector(look)) then
		return false
	end
	if direction.Magnitude < 1e-6 or look.Magnitude < 1e-6 then
		return false
	end
	local cosine = math.clamp(direction.Unit:Dot(look.Unit), -1, 1)
	return math.deg(math.acos(cosine)) <= maxDegrees + 1e-9
end

-- Whether a throw may leave the hand, and why not.
function ChemicalProjectileService.throwEligible(check: ThrowCheck): (boolean, string?)
	if not check.live then
		return false, "NoRun"
	end
	if not check.holding then
		return false, "NotHolding"
	end
	if check.lifeState ~= "Alive" then
		return false, "LifeState"
	end
	if not check.hasBody then
		return false, "NoBody"
	end
	if check.controlLock ~= "None" then
		return false, "Locked"
	end
	if not Ballistics.mayThrowIn(check.moveState) then
		return false, "MoveState"
	end
	local last = check.lastThrowAt
	if last ~= nil and check.now - last < GameConfig.FlaskThrowCooldown then
		return false, "Cooldown"
	end
	if not ChemicalProjectileService.withinLook(check.direction, check.look, LOOK_TOLERANCE) then
		return false, "Look"
	end
	return true, nil
end

-- Whether a player may take a world flask, and why not (HandsFull is a Strings key the player is shown).
function ChemicalProjectileService.pickupEligible(check: PickupCheck): (boolean, string?)
	if not check.live then
		return false, "NoRun"
	end
	if check.taken then
		return false, "Taken"
	end
	if check.lifeState ~= "Alive" then
		return false, "LifeState"
	end
	if check.holding then
		return false, HANDS_FULL
	end
	return true, nil
end

-- Whether a stun may interrupt the Creature in `state` (not one it is already in, a cutscene's, or its sleep).
function ChemicalProjectileService.stunnableState(state: Enums.MonsterState): boolean
	return table.find(UNSTUNNABLE, state) == nil
end

-- Distance from `point` to the box `cframe` x `size` (0 inside it).
function ChemicalProjectileService.boxDistance(cframe: CFrame, size: Vector3, point: Vector3): number
	local localPoint = cframe:PointToObjectSpace(point)
	local half = size * 0.5
	local dx = math.max(math.abs(localPoint.X) - half.X, 0)
	local dy = math.max(math.abs(localPoint.Y) - half.Y, 0)
	local dz = math.max(math.abs(localPoint.Z) - half.Z, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- The points of a hitbox a cloud at `from` may reach it by: its centre, its nearest point to `from` (pulled a little
-- in, so a grazing line never decides it) and the middle of its top.
function ChemicalProjectileService.reachPoints(cframe: CFrame, size: Vector3, from: Vector3): { Vector3 }
	local half = size * 0.5
	local localPoint = cframe:PointToObjectSpace(from)
	local nearest = Vector3.new(
		math.clamp(localPoint.X, -half.X, half.X),
		math.clamp(localPoint.Y, -half.Y, half.Y),
		math.clamp(localPoint.Z, -half.Z, half.Z)
	)
	local top = Vector3.new(0, math.max(half.Y - TOP_INSET, 0), 0)
	return {
		cframe.Position,
		cframe:PointToWorldSpace(nearest * (1 - REACH_PULL)),
		cframe:PointToWorldSpace(top),
	}
end

-- Whether a cloud centred on `centre` reaches the hitbox: within `radius` of it, with a clear line to one of its
-- reachPoints.
function ChemicalProjectileService.cloudReaches(
	centre: Vector3,
	radius: number,
	hitboxCFrame: CFrame,
	hitboxSize: Vector3,
	lineClear: LineClear
): boolean
	if ChemicalProjectileService.boxDistance(hitboxCFrame, hitboxSize, centre) > radius then
		return false
	end
	for _, target in ChemicalProjectileService.reachPoints(hitboxCFrame, hitboxSize, centre) do
		if lineClear(centre, target) then
			return true
		end
	end
	return false
end

-- Whether `cloud` stuns the Creature now, and why (or why not). `hops` is the VentGraph distance between the
-- cloud's duct node and the Creature's (nil unless both are in the ducts and connected).
function ChemicalProjectileService.stunVerdict(
	cloud: CloudView,
	creature: CreatureView?,
	now: number,
	hops: number?,
	lineClear: LineClear
): (boolean, StunReason)
	if cloud.spent then
		return false, "Spent"
	end
	if now > cloud.expiresAt then
		return false, "Expired"
	end
	if creature == nil then
		return false, "NoCreature"
	end
	if creature.levelId ~= cloud.levelId then
		return false, "Level"
	end
	if creature.hidden then
		return false, "Hidden"
	end
	if not ChemicalProjectileService.stunnableState(creature.state) then
		return false, "State"
	end
	if cloud.ventNode ~= nil and creature.inVent and hops ~= nil and hops <= GameConfig.FlaskVentHopRadius then
		return true, "Vent"
	end
	if
		ChemicalProjectileService.cloudReaches(
			cloud.centre,
			GameConfig.FlaskCloudRadius,
			creature.hitboxCFrame,
			creature.hitboxSize,
			lineClear
		)
	then
		return true, "Radius"
	end
	return false, "OutOfReach"
end

-- Where `point` sits against the duct piece `a` -> `b`: its distance from the centreline across the square bore
-- (the larger of its two offsets), its position along the piece (from `a`) and the piece's length.
function ChemicalProjectileService.boreOffset(a: Vector3, b: Vector3, point: Vector3): (number, number, number)
	local axis = b - a
	local length = axis.Magnitude
	local offset = point - a
	if length < 1e-6 then
		return math.max(math.abs(offset.X), math.abs(offset.Y), math.abs(offset.Z)), 0, 0
	end
	local unit = axis / length
	local side = if math.abs(unit.Y) > 0.9 then Vector3.xAxis else unit:Cross(Vector3.yAxis).Unit
	local up = side:Cross(unit).Unit
	local across = math.max(math.abs(offset:Dot(side)), math.abs(offset:Dot(up)))
	return across, offset:Dot(unit), length
end

-- The VentNode nearest a rail point: a grate stub's node, else the nearer end of its duct.
function ChemicalProjectileService.snapNode(rail: VentGraph.RailPoint): string
	local b = rail.b
	if b == nil or rail.t <= 0.5 then
		return rail.a
	end
	return b
end

-- The VentNode of the duct `point` lies inside (see the header), or nil when it is not inside any duct of `graph`.
function ChemicalProjectileService.ductNode(graph: VentGraph.Graph, point: Vector3): string?
	if not MathUtil.isFiniteVector(point) then
		return nil
	end
	local reach = HALF_BORE + BORE_SKIN
	local inside = false
	for _, node in graph.nodes do
		for _, otherId in node.links do
			local other = graph.nodes[otherId]
			if other == nil then
				continue
			end
			local across, along, length = ChemicalProjectileService.boreOffset(node.position, other.position, point)
			if across <= reach and along >= -reach and along <= length + reach then
				inside = true
				break
			end
		end
		if inside then
			break
		end
	end
	if not inside then
		for _, grate in graph.grates do
			local node = graph.nodes[grate.nodeId]
			if node == nil then
				continue
			end
			local face = grate.wall.Position + grate.wall.LookVector * (WorldConfig.WallThickness / 2)
			local across, along, length = ChemicalProjectileService.boreOffset(node.position, face, point)
			if across <= reach and along >= -reach and along <= length - FACE_MARGIN then
				inside = true
				break
			end
		end
	end
	if not inside then
		return nil
	end
	local rail = VentGraph.nearest(graph, point)
	return if rail then ChemicalProjectileService.snapNode(rail) else nil
end

local function adjacencyOf(graph: VentGraph.Graph): { [string]: { string } }
	local cached = adjacencyCache[graph]
	if cached then
		return cached
	end
	local built = VentPathfinder.adjacency(graph)
	adjacencyCache[graph] = built
	return built
end

-- The fewest duct edges between nodes `from` and `to`, when that is at most `maxHops`; nil otherwise (or for an
-- unknown node).
function ChemicalProjectileService.ventHops(graph: VentGraph.Graph, from: string, to: string, maxHops: number): number?
	if graph.nodes[from] == nil or graph.nodes[to] == nil then
		return nil
	end
	if from == to then
		return 0
	end
	local adjacency = adjacencyOf(graph)
	local seen: { [string]: boolean } = { [from] = true }
	local frontier: { string } = { from }
	for hops = 1, math.max(0, math.floor(maxHops)) do
		local nextFrontier: { string } = {}
		for _, id in frontier do
			for _, neighbour in adjacency[id] or {} :: { string } do
				if neighbour == to then
					return hops
				end
				if not seen[neighbour] then
					seen[neighbour] = true
					table.insert(nextFrontier, neighbour)
				end
			end
		end
		if #nextFrontier == 0 then
			return nil
		end
		frontier = nextFrontier
	end
	return nil
end

-- The VentNode the Creature is at: the nearer end (to its root) of its VentSegmentId's duct, or, when that segment is
-- unknown, the node of its nearest rail point.
function ChemicalProjectileService.creatureVentNode(
	graph: VentGraph.Graph,
	segmentId: string?,
	rootPosition: Vector3
): string?
	if segmentId ~= nil and segmentId ~= "" then
		for key, value in graph.segments do
			if value ~= segmentId then
				continue
			end
			local a, b = string.match(key, "^(.-)|(.*)$")
			local nodeA = if a then graph.nodes[a] else nil
			local nodeB = if b then graph.nodes[b] else nil
			if a and b and nodeA and nodeB then
				local da = (nodeA.position - rootPosition).Magnitude
				local db = (nodeB.position - rootPosition).Magnitude
				if math.abs(da - db) < 1e-9 then
					return if a < b then a else b
				end
				return if da < db then a else b
			end
		end
	end
	local rail = VentGraph.nearest(graph, rootPosition)
	return if rail then ChemicalProjectileService.snapNode(rail) else nil
end

-- The flask variant whose liquid is `color` (the nearest of ChemicalFlaskBuilder's liquid colours), in 0..2.
function ChemicalProjectileService.variantForColor(color: Color3): number
	local best, bestDistance = 0, math.huge
	for variant = 0, 2 do
		local liquid = ChemicalFlaskBuilder.liquidColor(variant)
		local distance = (liquid.R - color.R) ^ 2 + (liquid.G - color.G) ^ 2 + (liquid.B - color.B) ^ 2
		if distance < bestDistance then
			best, bestDistance = variant, distance
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- Dependencies
--------------------------------------------------------------------------------

local function serverNow(): number
	local fake = deps.now
	return if fake then fake() else Workspace:GetServerTimeNow()
end

local function creatureModel(): Model?
	local fake = deps.creature
	if fake then
		return fake()
	end
	return WorldService.GetCreature() or Instances.creature()
end

local function monster(): MonsterApi
	return deps.monster or MonsterAIService
end

local function graphFor(levelId: string): VentGraph.Graph?
	local fake = deps.graph
	if fake then
		return fake(levelId)
	end
	return VentNetworkService.GetGraph(levelId)
end

local function publish(payload: Types.ProjectileEventPayload)
	local fake = deps.publish
	if fake then
		fake(payload)
		return
	end
	Net.Server.fireAll("ProjectileEvent", payload)
end

local function isCreaturePart(instance: Instance): boolean
	local creature = creatureModel()
	return creature ~= nil and instance:IsDescendantOf(creature)
end

local function defaultCast(from: Vector3, to: Vector3, exclude: { Instance }, water: boolean): Ballistics.Hit?
	local delta = to - from
	local length = delta.Magnitude
	if length < 1e-4 or not MathUtil.isFiniteVector(delta) then
		return nil
	end
	local best: Ballistics.Hit? = nil
	local result = Workspace:Raycast(from, delta, SpatialQuery.projectileParams(exclude))
	if result then
		best = {
			position = result.Position,
			normal = result.Normal,
			fraction = math.clamp((result.Position - from).Magnitude / length, 0, 1),
			kind = if isCreaturePart(result.Instance) then "Creature" else "World",
			instance = result.Instance,
		}
	end
	if water then
		for volume in waters do
			if volume.Parent == nil then
				continue
			end
			local fraction = Ballistics.surfaceCrossing(volume.CFrame, volume.Size, from, to)
			local current = best
			if fraction ~= nil and (current == nil or fraction < current.fraction) then
				local up = volume.CFrame.UpVector
				best = {
					position = from + delta * fraction,
					normal = if delta:Dot(up) > 0 then -up else up,
					fraction = fraction,
					kind = "Water",
					instance = volume :: Instance,
				}
			end
		end
	end
	return best
end

local function cast(from: Vector3, to: Vector3, exclude: { Instance }, water: boolean): Ballistics.Hit?
	local fake = deps.cast
	if fake then
		return fake(from, to, exclude, water)
	end
	return defaultCast(from, to, exclude, water)
end

-- Every player character (flights and lines of sight never stop on a player).
local function characters(): { Instance }
	local list: { Instance } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(list, character)
		end
	end
	return list
end

local function lineClearFor(creature: Model?): LineClear
	local fake = deps.lineClear
	if fake then
		return fake(creature)
	end
	local exclude = characters()
	if creature then
		table.insert(exclude, creature)
	end
	local params = SpatialQuery.losParams(exclude)
	return function(from: Vector3, to: Vector3): boolean
		return SpatialQuery.lineClear(from, to, params, nil)
	end
end

-- Swaps in fakes (nil restores every real dependency).
function ChemicalProjectileService.SetDependencies(fake: Dependencies?)
	deps = fake or {}
end

--------------------------------------------------------------------------------
-- Instance helpers
--------------------------------------------------------------------------------

local function present(player: Player?): Player?
	if player and player.Parent == Players then
		return player
	end
	return nil
end

local function livingRoot(player: Player): BasePart?
	local root = Instances.characterRoot(player)
	local humanoid = Instances.characterHumanoid(player)
	if root and humanoid and humanoid.Health > 0 then
		return root
	end
	return nil
end

local function asLevel(value: unknown): Enums.LevelId?
	if type(value) == "string" and Enums.has(Enums.LevelId, value) then
		return value :: Enums.LevelId
	end
	return nil
end

local function levelOf(model: Model): Enums.LevelId?
	return asLevel(model:GetAttribute(W.LevelId))
end

-- The level `player` is on: ZoneService's LevelId, else the run's current level, else the Science Hall.
local function playerLevel(player: Player): Enums.LevelId
	return asLevel(player:GetAttribute(P.LevelId))
		or asLevel(ReplicatedStorage:GetAttribute(M.CurrentLevel))
		or DEFAULT_LEVEL
end

local function inRuntime(instance: Instance): boolean
	local runtime = Instances.runtime()
	return runtime ~= nil and instance:IsDescendantOf(runtime)
end

local heldAcid: { [Player]: boolean } = {}

local function wholeVariant(variant: number): number
	if not MathUtil.isFinite(variant) then
		return 0
	end
	return math.floor(variant)
end

--------------------------------------------------------------------------------
-- Hands
--------------------------------------------------------------------------------

local function writeHeld(player: Player, variant: number?, acid: boolean?)
	if variant ~= nil then
		held[player] = variant
		if acid then
			heldAcid[player] = true
		else
			heldAcid[player] = nil
		end
		Attributes.set(player, P.HeldItem, if acid then ACID_ITEM else ITEM)
		Attributes.set(player, P.HeldItemVariant, variant)
	else
		held[player] = nil
		heldAcid[player] = nil
		Attributes.set(player, P.HeldItem, NO_ITEM)
		Attributes.set(player, P.HeldItemVariant, nil)
	end
end

local function empty(player: Player)
	local acid = heldAcid[player] == true
	if held[player] ~= nil or player:GetAttribute(P.HeldItem) ~= NO_ITEM then
		writeHeld(player, nil)
	end
	if acid then
		acidLost:Fire(player)
	end
end

--------------------------------------------------------------------------------
-- World flasks
--------------------------------------------------------------------------------

-- The variant the run's plan built `model` with (by its AnchorId), if it is a plan prop.
local function planVariant(model: Model): number?
	local anchorId = model:GetAttribute(W.AnchorId)
	local plan = NoiseAndDirectorService.GetPlan()
	if type(anchorId) ~= "string" or not plan then
		return nil
	end
	for _, prop in plan.props do
		if prop.kind == ChemicalFlaskBuilder.Kind and prop.anchorId == anchorId then
			return prop.variant
		end
	end
	return nil
end

-- The variant matching `model`'s liquid colour (a flask built outside the plan without a known variant).
local function liquidVariant(model: Model): number?
	local liquid = model:FindFirstChild("Liquid1", true)
	if liquid and liquid:IsA("BasePart") then
		return ChemicalProjectileService.variantForColor(liquid.Color)
	end
	return nil
end

-- Re-evaluates the flask's prompt against the Pickup handler (a flask outside the DataModel has no prompt anyone can
-- use). Protected: a refresh failure never leaves a flask half taken.
local function refreshPrompt(model: Model)
	if not model:IsDescendantOf(game) then
		return
	end
	xpcall(InteractionService.Refresh, function(err: any)
		log.warnThrottled("refresh", 10, "prompt refresh on %s failed: %s", model:GetFullName(), tostring(err))
	end, model)
end

-- Starts managing a world flask built by its prop builder (`variant` when the caller knows it). Tracking a flask
-- twice is harmless. False for a model that is not a ChemicalItem.
function ChemicalProjectileService.Track(model: Model, variant: number?): boolean
	if flasks[model] then
		return true
	end
	if not model:HasTag(Tags.ChemicalItem) then
		return false
	end
	flasks[model] = {
		model = model,
		levelId = levelOf(model),
		variant = wholeVariant(variant or planVariant(model) or liquidVariant(model) or 0),
		taken = model:GetAttribute(W.HeldByUserId) ~= nil,
	}
	refreshPrompt(model)
	return true
end

local function forget(model: Model)
	flasks[model] = nil
end

local function onFlaskTagged(instance: Instance)
	if running and instance:IsA("Model") and instance.Parent ~= nil and inRuntime(instance) then
		ChemicalProjectileService.Track(instance)
	end
end

local function onFlaskUntagged(instance: Instance)
	if instance:IsA("Model") then
		forget(instance)
	end
end

local function scanFlasks()
	for _, instance in CollectionService:GetTagged(Tags.ChemicalItem) do
		onFlaskTagged(instance)
	end
end

local function onWaterTagged(instance: Instance)
	if instance:IsA("BasePart") then
		waters[instance] = true
	end
end

local function onWaterUntagged(instance: Instance)
	if instance:IsA("BasePart") then
		waters[instance] = nil
	end
end

local function onPickupComplete(player: Player, prompt: ProximityPrompt, host: Instance)
	local record = if host:IsA("Model") then flasks[host] else nil
	if not record or record.taken or record.model.Parent == nil then
		return
	end
	if held[player] ~= nil or LifeStateService.GetState(player) ~= "Alive" then
		return
	end
	record.taken = true
	local model = record.model
	Attributes.set(model, W.HeldByUserId, player.UserId)
	local position = InteractionService.PromptPosition(prompt)
	writeHeld(player, record.variant)
	if position then
		AudioService.PlayAt(PICKUP_PRESET, position)
	end
	log.debug("%s took %s", player.Name, model.Name)
	flasks[model] = nil
	model:Destroy()
end

-- Pickup on a tracked, untaken flask: Alive players with a free hand.
ChemicalProjectileService.PickupHandler = table.freeze({
	kind = PICKUP_KIND,
	filter = function(host: Instance, _prompt: ProximityPrompt): boolean
		local record = if host:IsA("Model") then flasks[host] else nil
		return record ~= nil and not record.taken
	end,
	canUse = function(player: Player, _prompt: ProximityPrompt, host: Instance): (boolean, string?)
		local record = if host:IsA("Model") then flasks[host] else nil
		return ChemicalProjectileService.pickupEligible({
			live = live,
			lifeState = LifeStateService.GetState(player),
			holding = held[player] ~= nil,
			taken = record == nil or record.taken,
		})
	end,
	onComplete = onPickupComplete,
} :: InteractionService.Handler)

--------------------------------------------------------------------------------
-- Flights
--------------------------------------------------------------------------------

local function payloadOf(
	flight: Flight,
	phase: Enums.ProjectilePhase,
	position: Vector3?,
	normal: Vector3?,
	kind: Enums.ProjectileHitKind?,
	inVent: boolean?
): Types.ProjectileEventPayload
	return {
		id = flight.id,
		phase = phase,
		origin = flight.origin,
		velocity = flight.velocity,
		t0 = flight.startAt,
		gravity = flight.gravity,
		variant = flight.variant,
		throwerUserId = flight.throwerUserId,
		hitPosition = position,
		hitNormal = normal,
		hitKind = kind,
		inVent = inVent,
		item = if flight.acid then ACID_ITEM else nil,
	}
end

-- The Creature as stunVerdict sees it (nil without a hitbox).
local function viewOf(model: Model): CreatureView?
	local hitbox = model:FindFirstChild(RIG.Hitbox)
	if not (hitbox and hitbox:IsA("BasePart")) then
		return nil
	end
	local root = model:FindFirstChild(RIG.Root)
	local rootPart: BasePart = if root and root:IsA("BasePart") then root else hitbox
	local segment = model:GetAttribute(C.VentSegmentId)
	local levelId = model:GetAttribute(C.LevelId)
	return {
		levelId = if type(levelId) == "string" then levelId else nil,
		state = monster().GetState(),
		hidden = Attributes.getBool(model, C.Hidden, false),
		inVent = Attributes.getBool(model, C.InVent, false),
		segmentId = if type(segment) == "string" then segment else nil,
		rootPosition = rootPart.CFrame.Position,
		hitboxCFrame = hitbox.CFrame,
		hitboxSize = hitbox.Size,
	}
end

-- Stuns the Creature with `cloud` if the rules allow it now.
local function evaluate(cloud: Cloud, at: number)
	if cloud.spent or at > cloud.expiresAt then
		return
	end
	local model = creatureModel()
	local view = if model then viewOf(model) else nil
	local hops: number? = nil
	local cloudNode = cloud.ventNode
	if view and cloudNode and view.inVent and view.levelId == cloud.levelId then
		local graph = graphFor(cloud.levelId)
		local node = if graph
			then ChemicalProjectileService.creatureVentNode(graph, view.segmentId, view.rootPosition)
			else nil
		if graph and node then
			hops = ChemicalProjectileService.ventHops(graph, cloudNode, node, GameConfig.FlaskVentHopRadius)
		end
	end
	local stuns, reason = ChemicalProjectileService.stunVerdict(cloud, view, at, hops, lineClearFor(model))
	if not stuns then
		return
	end
	cloud.spent = true
	monster().Stun(GameConfig.StunSeconds, cloud.point)
	local thrower = present(cloud.thrower)
	if thrower then
		RunStatsService.Increment(thrower, STUN_STAT)
	end
	log.info("cloud %d stunned the Creature (%s)", cloud.id, reason)
end

local function shatter(flight: Flight, hit: Ballistics.Hit)
	flights[flight.id] = nil
	local point = hit.position
	local normal = if hit.normal.Magnitude > 1e-6 and MathUtil.isFiniteVector(hit.normal)
		then hit.normal.Unit
		else Vector3.yAxis
	local levelId: Enums.LevelId = flight.levelId
	local graph = graphFor(levelId)
	local ventNode = if graph then ChemicalProjectileService.ductNode(graph, point) else nil
	local inVent = ventNode ~= nil
	local centre = point + normal * CLOUD_LIFT
	local thrower = present(flight.thrower)
	local at = serverNow()

	publish(payloadOf(flight, RESOLVE_PHASE, point, normal, hit.kind, inVent))
	NoiseAndDirectorService.Emit(point, SHATTER_NOISE, {
		sourcePlayer = thrower,
		levelId = levelId,
		medium = if inVent then VENT_MEDIUM else nil,
		ventNodeId = ventNode,
	})
	AudioService.PlayAt(SHATTER_PRESET, point)
	if flight.acid then
		-- the acid: its own sizzle, no stun cloud (ObjectiveService judges the chain)
		AudioService.PlayAt(ACID_PRESET, point)
		log.debug("acid flask %d broke (%s)", flight.id, hit.kind)
		acidShattered:Fire(point, thrower)
		return
	end
	AudioService.PlayAt(HISS_PRESET, centre, { duration = GameConfig.FlaskCloudSeconds })

	nextCloudId += 1
	local cloud: Cloud = {
		id = nextCloudId,
		point = point,
		centre = centre,
		levelId = levelId,
		ventNode = ventNode,
		inVent = inVent,
		thrower = flight.thrower,
		expiresAt = at + GameConfig.FlaskCloudSeconds,
		spent = false,
	}
	table.insert(clouds, cloud)
	log.debug("flask %d shattered (%s%s)", flight.id, hit.kind, if inVent then ", in a duct" else "")
	shattered:Fire(point, thrower, inVent)
	evaluate(cloud, at)
end

local function expire(flight: Flight, position: Vector3)
	flights[flight.id] = nil
	publish(payloadOf(flight, RESOLVE_PHASE, position, nil, EXPIRED, false))
	if flight.acid then
		acidLost:Fire(present(flight.thrower))
	end
end

-- Flies every flask on to server time `at` (default now): the Heartbeat driver calls this every frame; specs drive
-- it by hand.
function ChemicalProjectileService.StepFlights(at: number?)
	local now = at or serverNow()
	local pending: { Flight } = {}
	for _, flight in flights do
		table.insert(pending, flight)
	end
	table.sort(pending, function(a: Flight, b: Flight): boolean
		return a.id < b.id
	end)
	for _, flight in pending do
		if flights[flight.id] ~= flight then
			continue
		end
		local exclude = flight.exclude
		local result = Ballistics.advance(
			flight.origin,
			flight.velocity,
			flight.gravity,
			flight.t,
			now - flight.startAt,
			GameConfig.FlaskMaxFlightSeconds,
			STEP_SECONDS,
			function(from: Vector3, to: Vector3): Ballistics.Hit?
				return cast(from, to, exclude, true)
			end
		)
		flight.t = result.t
		local hit = result.hit
		if hit then
			shatter(flight, hit)
		elseif result.expired then
			expire(flight, result.position)
		end
	end
end

-- Drops expired clouds and lets the rest stun a Creature that walked into them (GameConfig.ServerTickHz; specs call
-- it directly).
function ChemicalProjectileService.PollClouds(at: number?)
	local now = at or serverNow()
	for index = #clouds, 1, -1 do
		if now > clouds[index].expiresAt then
			table.remove(clouds, index)
		end
	end
	for _, cloud in table.clone(clouds) do
		evaluate(cloud, now)
	end
end

--------------------------------------------------------------------------------
-- Throws
--------------------------------------------------------------------------------

-- Throws `player`'s flask along `direction` (the ItemThrow handler's body). Returns whether it left the hand, and the
-- refusal reason when it did not.
function ChemicalProjectileService.RequestThrow(player: Player, direction: Vector3): (boolean, string?)
	local root = livingRoot(player)
	local yaw, pitch = PlayerStateService.GetLook(player)
	local moveState: Enums.MoveState = PlayerStateService.GetMoveState(player)
	local now = serverNow()
	local ok, reason = ChemicalProjectileService.throwEligible({
		live = live,
		holding = held[player] ~= nil,
		lifeState = LifeStateService.GetState(player),
		moveState = moveState,
		controlLock = CharacterService.GetLock(player),
		hasBody = root ~= nil,
		now = now,
		lastThrowAt = lastThrowAt[player],
		direction = direction,
		look = MathUtil.vectorFromYawPitch(yaw, pitch),
	})
	if not ok or root == nil then
		log.debug("%s: throw refused (%s)", player.Name, tostring(reason))
		return false, reason
	end

	-- The release: the eye (kept inside the body's room), then the hand just right of and below it.
	local exclude = characters()
	local rootPosition = root.CFrame.Position
	local eyeHeight = CameraConfig.EyeHeightAboveRoot[moveState] or CameraConfig.EyeHeightAboveRoot.Standing
	local eye = rootPosition + Vector3.new(0, eyeHeight, 0)
	local eyeBlock = cast(rootPosition, eye, exclude, false)
	eye = Ballistics.pullBack(rootPosition, eye, if eyeBlock then eyeBlock.position else nil)
	local unit = direction.Unit
	local release = Ballistics.releasePoint(eye, unit)
	local releaseBlock = cast(eye, release, exclude, false)
	local origin = Ballistics.pullBack(eye, release, if releaseBlock then releaseBlock.position else nil)

	local variant = held[player] :: number
	local acid = heldAcid[player] == true
	writeHeld(player, nil)
	lastThrowAt[player] = now
	RunStatsService.Increment(player, THROWN_STAT)

	nextFlightId += 1
	local flight: Flight = {
		id = nextFlightId,
		thrower = player,
		throwerUserId = player.UserId,
		origin = origin,
		velocity = Ballistics.launchVelocity(unit, Ballistics.throwSpeed(moveState)),
		gravity = Ballistics.Gravity,
		startAt = now,
		t = 0,
		levelId = playerLevel(player),
		variant = variant,
		exclude = exclude,
		acid = acid,
	}
	flights[flight.id] = flight
	publish(payloadOf(flight, SPAWN_PHASE, nil, nil, nil, nil))
	log.debug("%s threw flask %d (%s)", player.Name, flight.id, moveState)
	return true, nil
end

local function onThrow(player: Player, payload: any)
	local message = payload :: Types.ItemThrowPayload
	ChemicalProjectileService.RequestThrow(player, message.direction)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Puts a flask (of `variant`, else a fresh look) in a playing player's free hand during a run (dev / scripted).
-- False when there is no run, the player is not Alive or Downed, or already holds one.
function ChemicalProjectileService.Give(player: Player, variant: number?): boolean
	if not running or held[player] ~= nil or not LifeStateService.IsPlaying(player) then
		return false
	end
	local chosen: number
	if variant ~= nil and MathUtil.isFinite(variant) then
		chosen = math.floor(variant)
	else
		giveCount += 1
		chosen = MathUtil.seededRandom(runSeed, "ChemicalFlask:give:" .. giveCount):NextInteger(0, GIVE_VARIANTS - 1)
	end
	writeHeld(player, chosen)
	return true
end

-- Puts Floor 2's acid flask in a playing player's free hand (ObjectiveService). False without a run, when the player
-- is not Alive, or with their hands full.
function ChemicalProjectileService.GiveAcid(player: Player): boolean
	if not running or held[player] ~= nil or LifeStateService.GetState(player) ~= "Alive" then
		return false
	end
	writeHeld(player, 0, true)
	return true
end

-- Takes the acid flask out of `player`'s hand (poured), without AcidLost. False when they do not hold it.
function ChemicalProjectileService.TakeAcid(player: Player): boolean
	if heldAcid[player] ~= true then
		return false
	end
	writeHeld(player, nil)
	return true
end

-- Whether `player` holds the acid flask.
function ChemicalProjectileService.HoldsAcid(player: Player): boolean
	return heldAcid[player] == true
end

-- Whether `player`'s hands are free (no flask, no acid).
function ChemicalProjectileService.HandsFree(player: Player): boolean
	return held[player] == nil
end

-- Builds an untaken world flask of `variant` resting on `cframe` in Workspace.Runtime.<levelId> (Level 2's restock,
-- dev commands). Nil outside a run, for an unknown level or a non-finite place, or when the build fails.
function ChemicalProjectileService.SpawnFlask(levelId: Enums.LevelId, cframe: CFrame, variant: number): Model?
	if not running or not Enums.has(Enums.LevelId, levelId) or not MathUtil.isFiniteVector(cframe.Position) then
		return nil
	end
	local parent = Instances.runtimeLevel(levelId, true)
	if not parent then
		return nil
	end
	spawnCount += 1
	local plan: Types.PlannedProp = {
		kind = ChemicalFlaskBuilder.Kind,
		anchorId = string.format("Spawned%d", spawnCount),
		levelId = levelId,
		cframe = cframe,
		variant = wholeVariant(variant),
	}
	local built = Builder.BuildProp(plan, parent, MathUtil.seededRandom(runSeed, "ChemicalFlask:" .. plan.anchorId))
	if not (built and built:IsA("Model")) then
		return nil
	end
	ChemicalProjectileService.Track(built, plan.variant)
	return built
end

-- How many untaken world flasks are on `levelId`.
function ChemicalProjectileService.CountAvailable(levelId: Enums.LevelId): number
	local count = 0
	for model, record in flasks do
		if not record.taken and model.Parent ~= nil and record.levelId == levelId then
			count += 1
		end
	end
	return count
end

-- The variant of the flask `player` holds (nil when their hand is empty).
function ChemicalProjectileService.GetHeld(player: Player): number?
	return held[player]
end

-- The flasks in flight and the live clouds (read-only snapshots, oldest first).
function ChemicalProjectileService.GetFlights(): { Flight }
	local list: { Flight } = {}
	for _, flight in flights do
		table.insert(list, flight)
	end
	table.sort(list, function(a: Flight, b: Flight): boolean
		return a.id < b.id
	end)
	return list
end

function ChemicalProjectileService.GetClouds(): { Cloud }
	return table.clone(clouds)
end

--------------------------------------------------------------------------------
-- Dev commands
--------------------------------------------------------------------------------

local function flaskCommand(player: Player, args: { string }): string?
	if not running then
		return "no run in progress"
	end
	local spawn = args[1] ~= nil and string.lower(args[1]) == "spawn"
	local variantArg = if spawn then args[2] else args[1]
	local variant = if variantArg ~= nil then tonumber(variantArg) else nil
	if variantArg ~= nil and (variant == nil or not MathUtil.isFinite(variant :: number)) then
		return "usage: flask [spawn] [variant]"
	end
	if spawn then
		local root = livingRoot(player)
		local humanoid = Instances.characterHumanoid(player)
		if not (root and humanoid) then
			return player.Name .. " has no living character"
		end
		local look = root.CFrame.LookVector
		local ahead = MathUtil.flat(look)
		local forward = if ahead.Magnitude > 1e-3 then ahead.Unit else Vector3.new(0, 0, -1)
		local floor = root.CFrame.Position - Vector3.new(0, humanoid.HipHeight + root.Size.Y * 0.5, 0)
		local model = ChemicalProjectileService.SpawnFlask(
			playerLevel(player),
			CFrame.new(floor + forward * 3),
			if variant ~= nil then variant else spawnCount
		)
		return if model then model.Name .. " placed at your feet" else "could not build a flask here"
	end
	if held[player] ~= nil then
		return player.Name .. " already holds a flask"
	end
	if not ChemicalProjectileService.Give(player, variant) then
		return player.Name .. " cannot hold a flask now"
	end
	return string.format("%s holds a flask (variant %d)", player.Name, held[player] or 0)
end

local function flasksCommand(_player: Player, _args: { string }): string?
	local perLevel: { string } = {}
	for _, levelId: Enums.LevelId in Enums.LevelId do
		local count = ChemicalProjectileService.CountAvailable(levelId)
		if count > 0 then
			table.insert(perLevel, string.format("%s %d", levelId, count))
		end
	end
	local holders: { string } = {}
	for player in held do
		table.insert(holders, player.Name)
	end
	table.sort(holders)
	local flying = 0
	for _ in flights do
		flying += 1
	end
	return string.format(
		"world: %s | held: %s | %d in flight, %d clouds",
		if #perLevel > 0 then table.concat(perLevel, ", ") else "none",
		if #holders > 0 then table.concat(holders, ", ") else "nobody",
		flying,
		#clouds
	)
end

local function registerDevCommands()
	DevToolsService.Register(
		"flask",
		"flask [spawn] [variant]: a chemical flask in your hand (spawn: a world flask at your feet)",
		flaskCommand
	)
	DevToolsService.Register(
		"flasks",
		"flasks: world flasks per level, who holds one, flights and clouds",
		flasksCommand,
		true
	)
end

--------------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------------

local function onLifeStateChanged(player: Player, state: Enums.LifeState, _previous: Enums.LifeState)
	if state ~= "Alive" and state ~= "Downed" then
		empty(player)
	end
end

local function onPlayerAdded(player: Player)
	if held[player] == nil then
		writeHeld(player, nil)
	end
end

local function onPhaseChanged(phase: Enums.MatchPhase)
	live = running and LIVE_PHASES[phase] == true
end

local function clearRun()
	for player in table.clone(held) do
		heldAcid[player] = nil
		empty(player)
	end
	table.clear(held)
	table.clear(heldAcid)
	table.clear(lastThrowAt)
	table.clear(flights)
	table.clear(clouds)
	table.clear(flasks)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function ChemicalProjectileService.Init()
	if initialized then
		return
	end
	initialized = true
	Net.Server.on("ItemThrow", onThrow)
	serviceTrove:Add(InteractionService.Register(ChemicalProjectileService.PickupHandler))
	serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(Tags.ChemicalItem), onFlaskTagged)
	serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(Tags.ChemicalItem), onFlaskUntagged)
	serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(Tags.PoolWater), onWaterTagged)
	serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(Tags.PoolWater), onWaterUntagged)
	for _, instance in CollectionService:GetTagged(Tags.PoolWater) do
		onWaterTagged(instance)
	end
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(onPhaseChanged))
	serviceTrove:Add(LifeStateService.StateChanged:Connect(onLifeStateChanged))
	serviceTrove:Connect(Players.PlayerAdded, onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	registerDevCommands()
end

function ChemicalProjectileService.Start()
	local interval = 1 / GameConfig.ServerTickHz
	local accumulated = 0
	serviceTrove:Connect(RunService.Heartbeat, function(dt: number)
		if next(flights) ~= nil then
			xpcall(ChemicalProjectileService.StepFlights, function(err: any)
				log.warnThrottled("flight", 10, "flask flight step failed: %s", tostring(err))
			end)
		end
		accumulated += dt
		if accumulated < interval then
			return
		end
		accumulated = 0
		if #clouds > 0 then
			xpcall(ChemicalProjectileService.PollClouds, function(err: any)
				log.warnThrottled("cloud", 10, "cloud poll failed: %s", tostring(err))
			end)
		end
	end)
end

function ChemicalProjectileService.BeginRun(ctx: Types.RunContext)
	clearRun()
	runSeed = ctx.seed
	spawnCount = 0
	giveCount = 0
	running = true
	live = true
	for _, player in ctx.participants do
		writeHeld(player, nil) -- every run starts empty-handed
	end
	for _, instance in CollectionService:GetTagged(Tags.PoolWater) do
		onWaterTagged(instance)
	end
	scanFlasks()
end

function ChemicalProjectileService.EndRun()
	running = false
	live = false
	clearRun()
end

function ChemicalProjectileService.OnPlayerRemoving(player: Player)
	if heldAcid[player] then
		heldAcid[player] = nil
		acidLost:Fire(player)
	end
	held[player] = nil
	lastThrowAt[player] = nil
end

return ChemicalProjectileService
