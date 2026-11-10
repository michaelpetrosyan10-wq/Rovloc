--!strict
-- MonsterAIService: the Creature's brain ("the Tall Man"; docs/MONSTER.md is the spec, the website's
-- web/src/creature/service.js the reference). The only writer of the Creature's attributes (MonsterState, StateSince,
-- PoseMode, TargetUserId, Hidden, GrabbedUserId, LevelId and the view contract's Action, ActionAt, Fade; WorldService
-- only seeds LevelId / MonsterState when it builds the rig). Server-authoritative: it sees, hears, chases, teleports to
-- and catches every participant in play (co-op 1-4).
--
-- Brain, at GameConfig.ServerTickHz during InRun:
--   watch     every player's trail (where they came from: the teleport's "behind"), speed, life (a fresh Downed blocks
--             teleports for Teleport.AfterCatch), hiding (someone it saw within Hiding.SeenWindow climbing into a
--             spot: the saw-you-hide rule) and stare (looking straight at its head for Stare.Seconds starts a chase).
--   perceive  Perception.scan over the run's playing participants (ignored dev players left out; nothing while it is
--             hidden, fading or startled), every NoiseEmitted pulse since the last tick through Hearing.perceive (the
--             pacing's HearingScale), plus scripted Alerts. "Lit" is the fixture light at a point (LightField), never
--             anything a client renders. It remembers the target's last seen or heard position, the rooms it heard
--             noises in (the Stalk leans toward them), a swimmer on the pool level and who was loud lately (a teleport
--             target weighs more).
--   pace      PacingDirector.Tick (chasing, target in sight, nearest player).
--   decide    Brain.decide over a Summary (the transition table); entering a state runs the old state's exit and the
--             new one's enter; the current state updates once per tick (not while a catch, a ReachIn or a warp runs).
--   act       the states drive Locomotion on the level's FloorNav (the zone graph: never a crawlway, a duct or a pool's
--             water; hunched under low clearances), stepped every Heartbeat so kinematic motion is smooth.
--
-- Warps: every FadeOut / FadeIn relocation (a teleport, a chase giving up, the pool entered or left, a concealed
-- Creature revealing itself) runs through one machine: FadeOut (0.6 s) -> Hidden (placed at the destination; waits
-- until no player can see it there, or picks another spot) -> Warning (teleports only: 1.6 s; the lights near the spot
-- stutter (OneShot TeleportWarning), the target's torch stutters (PrivateCue Scare TorchStutter), a hiss rises) ->
-- FadeIn (0.8 s) -> Stare (teleports only: 1.2 s, the reveal check). The brain holds its state while a warp runs.
--
-- The view contract (docs/MONSTER.md 12): PoseMode (Hunched wherever the clearance at its root or just ahead on its
-- route is under HunchBelow, and while sniffing), Action (Stare, ReachIn, LookAway, FadeOut, FadeIn, Jumpscare; "" for
-- none), ActionAt (server time) and Fade (0..1 visible). CreatureController animates them.
--
-- Catches go through JumpscareHandler (Hallway on floors, Locker through a ReachIn, Underwater through CatchGrabbed).
-- While a catch runs the brain leaves the body alone; when it finishes the movement is re-synced, the pacing notes the
-- catch (cooldown, Relax) and the Creature withdraws out of sight. A mover that stalls for good is put back at the
-- nearest standing spot nobody can see, and only while nobody can see the Creature either.
--
-- Levels. Every level's activation (the basement too): PacingDirector.NoteAirlock (grace), the Creature is moved hidden
-- to that level's CreatureSpawn if it is elsewhere, fades in once nobody can see it, and wakes into Patrol WakeDelay
-- seconds later; the first teleport waits FloorGrace + Teleport.FirstAfterGrace. A level controller that acquired it
-- (AcquireScripted) in its Activate keeps it. On Levels 0, 2 and 3 (SpawnRule, ObjectiveConfig.Spawn) it starts at the
-- run's seeded pick among the level's PatrolWaypoint / CreatureSpawn anchors 70-140 studs walked from the entry, out of
-- sight of it and outside the objective rooms, and its grace there is ObjectiveConfig.graceFor(difficulty), ended early
-- by a participant's High / Critical noise on the level, by a participant within ReleaseNear, or by one with a clear
-- line to its head within ReleaseSight.
--
-- Hooks: RegisterLockerInspector and RegisterHideSpots (HideSpotService: the breath check, the hiding spots of a level,
-- who is in which), NotePulled (a teammate's pull-out: no catch, a startle), RegisterPoolGrabber (FloodedPoolService;
-- CatchGrabbed finishes a held swimmer who ran out of air), RegisterTeleportBlock (an objective's survive countdown,
-- the roof's finale), AcquireScripted (cutscenes; SetScriptedTarget), Stun (flasks), Alert (scripted noises),
-- SetSpeedScale (level tuning: Level 3's gym), Reveal (a fake-out's scare).
--
-- Dev commands (DevToolsService): ai [state|pause|resume|tp], hunt, ignoreme.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local TunnelRules = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.TunnelRules)
local Types = require(ReplicatedStorage.Shared.Types)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)
local VentGrateBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.VentGrateBuilder)

local AudioService = require(ServerScriptService.Services.Core.AudioService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local PacingDirector = require(ServerScriptService.Services.Core.NoiseAndDirectorService.PacingDirector)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local WorldService = require(ServerScriptService.Services.Core.WorldService)
local FlashlightService = require(ServerScriptService.Services.Player.FlashlightService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local VentNetworkService = require(ServerScriptService.Services.Vents.VentNetworkService)

local Brain = require(script.Brain)
local CreatureBody = require(script.CreatureBody)
local FloorNav = require(script.FloorNav)
local Hearing = require(script.Hearing)
local JumpscareHandler = require(script.JumpscareHandler)
local LightField = require(script.LightField)
local Locomotion = require(script.Locomotion)
local Perception = require(script.Perception)
local SpawnRule = require(script.SpawnRule)

local AquaticStalk = require(script.States.AquaticStalk)
local Dormant = require(script.States.Dormant)
local HidingResponse = require(script.States.HidingResponse)
local InvestigateNoise = require(script.States.InvestigateNoise)
local Patrol = require(script.States.Patrol)
local Scripted = require(script.States.Scripted)
local Search = require(script.States.Search)
local Stunned = require(script.States.Stunned)
local Teleport = require(script.States.Teleport)
local WallChase = require(script.States.WallChase)

-- The service's internals live in one table (I): a module chunk may hold at most 200 locals.
local I = {}

local log = Log.new("MonsterAI")

I.C = Attributes.Creature
I.P = Attributes.Player
I.W = Attributes.World

export type ScriptedHandle = {
	MoveTo: (self: ScriptedHandle, position: Vector3, speed: number?) -> (),
	Teleport: (self: ScriptedHandle, cframe: CFrame) -> (),
	SetPose: (self: ScriptedHandle, poseMode: Enums.PoseMode) -> (),
	SetHidden: (self: ScriptedHandle, hidden: boolean) -> (),
	Face: (self: ScriptedHandle, position: Vector3) -> (),
	Release: (self: ScriptedHandle, nextState: Enums.MonsterState?) -> (),
}

export type Clock = () -> number

-- A hiding spot as the brain knows it (its model, kind and front).
export type HideSpotEntry = Brain.HideSpot

-- HideSpotService's view of the hiding spots for the brain.
export type HideSpots = {
	spotsOn: (levelId: string) -> { Brain.HideSpot },
	occupant: (spot: Instance) -> Player?,
	spotOf: (player: Player) -> Instance?,
}

-- What a scan of the Creature says (dev, specs).
export type Snapshot = {
	state: Enums.MonsterState,
	reason: string,
	awake: boolean,
	warp: string?, -- "<kind>/<phase>" while a warp runs
	action: Enums.CreatureAction?,
	fade: number,
	poseMode: string,
	teleports: number,
	teleportReadyAt: number,
	lastSeenAny: number,
	levelId: Enums.LevelId?,
	position: Vector3?,
}

type Catching = { player: Player, kind: Enums.JumpscareKind, at: number }
type Hold = { token: string, handle: ScriptedHandle }
type Reach = { player: Player, spot: Instance, at: number }
type TrailPoint = { t: number, p: Vector3 }
type Record = {
	trail: { TrailPoint },
	trailAt: number,
	last: Vector3?,
	lastAt: number,
	speed: number,
	travel: Vector3?,
	stare: number,
	hiding: boolean,
	life: Enums.LifeState?,
	loudAt: number,
}
type WarpKind = "Teleport" | "GiveUp" | "Pool" | "Reveal"
type WarpPhase = "FadeOut" | "Hidden" | "Warning" | "FadeIn" | "Stare"
type Warp = {
	kind: WarpKind,
	phase: WarpPhase,
	phaseAt: number,
	startedAt: number,
	to: CFrame?,
	pick: (() -> CFrame?)?,
	warning: boolean,
	stare: boolean,
	plan: Brain.TeleportPlan?,
	retries: number,
	placed: boolean,
	revealed: boolean,
	pickedAt: number,
}
type WarpOptions = {
	kind: WarpKind,
	to: CFrame?,
	pick: (() -> CFrame?)?,
	warning: boolean?,
	stare: boolean?,
	plan: Brain.TeleportPlan?,
	startHidden: boolean?,
}
type TeleportCandidate = { position: Vector3, room: string }

function I.stateModule(
	name: Enums.MonsterState,
	enter: (ctx: Brain.Context, from: Enums.MonsterState) -> (),
	update: (ctx: Brain.Context, dt: number) -> (),
	exit: (ctx: Brain.Context, to: Enums.MonsterState) -> ()
): Brain.StateModule
	return { Name = name, enter = enter, update = update, exit = exit }
end

I.DORMANT = I.stateModule("Dormant", Dormant.enter, Dormant.update, Dormant.exit)
I.PATROL = I.stateModule("Patrol", Patrol.enter, Patrol.update, Patrol.exit)

local STATES: { [string]: Brain.StateModule } = {
	Dormant = I.DORMANT,
	Patrol = I.PATROL,
	InvestigateNoise = I.stateModule(
		"InvestigateNoise",
		InvestigateNoise.enter,
		InvestigateNoise.update,
		InvestigateNoise.exit
	),
	WallChase = I.stateModule("WallChase", WallChase.enter, WallChase.update, WallChase.exit),
	Search = I.stateModule("Search", Search.enter, Search.update, Search.exit),
	HidingResponse = I.stateModule("HidingResponse", HidingResponse.enter, HidingResponse.update, HidingResponse.exit),
	Teleport = I.stateModule("Teleport", Teleport.enter, Teleport.update, Teleport.exit),
	Stunned = I.stateModule("Stunned", Stunned.enter, Stunned.update, Stunned.exit),
	AquaticStalk = I.stateModule("AquaticStalk", AquaticStalk.enter, AquaticStalk.update, AquaticStalk.exit),
	Scripted = I.stateModule("Scripted", Scripted.enter, Scripted.update, Scripted.exit),
}

I.T = CreatureConfig.Teleport
I.H = CreatureConfig.Hiding
I.SENSES = CreatureConfig.Senses
I.WATER = CreatureConfig.Water
I.SPAWN = ObjectiveConfig.Spawn
I.TICK = 1 / GameConfig.ServerTickHz
I.WAKE_DELAY = 4 -- seconds after a level activates before the Creature starts its patrol
I.SWIMMER_MEMORY = 6
I.GRAB_ARMED_SECONDS = 10
I.GRAB_GRACE = 1 -- seconds a grabbed player may read as not Grabbed before the grab counts as over
I.CATCH_TIMEOUT = GameConfig.OneShotLead
	+ CreatureConfig.Jumpscare.LungeSeconds
	+ CreatureConfig.Jumpscare.HoldSeconds
	+ 4
I.HEARD_ZONE_TTL = Patrol.HeardTtl
I.NOISE_QUEUE_LIMIT = 64
I.SIGHT_RANGE_LIMIT = 250 -- visibility checks for players farther than this are skipped
I.UNSTICK_MIN = 6 -- an unstick teleport lands at least this far away
I.DUCT_SNAP = 1.5 -- a believed noise position this close to a duct centreline is inside the duct
I.EXACT_RANK = Hearing.priorityRank("High")
I.LOUD_RANK = I.EXACT_RANK
I.DEV_FORCE_SECONDS = 30
I.DEV_HUNT_SECONDS = 45
I.TP_MIN = 18
I.TP_MAX = 60
I.SPOT_PRESET = "Screech"
I.SPOT_VOLUME = 0.75
I.STUN_PRESET = "Screech"
I.GRUNT_PRESET = "CreatureGrunt"
I.VANISH_PRESET = "CreatureVanish"
I.HISS_PRESET = "TeleportHiss"
I.TELEGRAPH_PRESET = "CreatureGrowl"
I.MIN_SPEED_SCALE = 0.5
I.MAX_SPEED_SCALE = 2
local SWIM_STATES: { [string]: boolean } = { Treading = true, Freestyle = true, Underwater = true, Grabbed = true }
local LOUD: { [string]: boolean } = { High = true, Critical = true }
I.EXIT_ANCHOR = "ExitAnchor"
I.TRAIL_SECONDS = 15
I.TRAIL_EVERY = 0.5
I.TRAIL_SKIP = 1 -- the last second of a trail is not "behind" yet
I.PLAYER_FLOOR = 3 -- a player's root centre over the floor
I.PULL_MEMORY = 2.5
I.TELEPORT_RETRY = 4
I.SAMPLE_SPACING = 5
local TUNNEL_KINDS: { [string]: boolean } = { Corridor = true, Tunnel = true, Gallery = true, Hallway = true }
I.WARP_WAIT = 3 -- a spot still in view this long after it was picked is swapped for another
I.WARP_GIVE_UP = 12 -- hidden this long: any spot out of sight will do
I.NEAR_EYE = 8 -- a point this close to a player's eye counts as in their view
I.HEAD_LEAD = 2 -- the hunch counts the head room this far ahead (its head's lead on its root) ...
I.HUNCH_LEAD_SECONDS = 0.5 -- ... plus what its pace covers while it bends
I.HEADROOM_STEP = 1
local STAGE_LIFTS: { number } = { -1, 0, 1 } -- the walker's body (its root box) from the root
I.BODY_RADIUS = 1 -- the root box as a capsule
I.SPEED_DAMP = 10
local LOOKAWAY_PROBES: { number } = { 4, 8, 12, 16 }
I.VANISH_LIFT = 5
I.HISS_LIFT = 4
I.ACTION_NONE = ""

local MonsterAIService = {}

MonsterAIService.Name = "MonsterAIService"
MonsterAIService.WakeDelay = I.WAKE_DELAY

local stateChanged: Signal.Signal<Enums.MonsterState, Enums.MonsterState> = Signal.new()
local caught: Signal.Signal<Player, Enums.JumpscareKind> = Signal.new()
local lungeTelegraph: Signal.Signal<Vector3, number> = Signal.new()
local teleportWarning: Signal.Signal<Vector3, Player?, number> = Signal.new()
local revealed: Signal.Signal<Player, string> = Signal.new()
local stared: Signal.Signal<Player> = Signal.new()
local gaveUp: Signal.Signal<Player?, Vector3> = Signal.new()
local grunted: Signal.Signal<Vector3> = Signal.new()

-- (new, old) on every MonsterState change.
MonsterAIService.StateChanged = stateChanged
-- (victim, kind) when a catch starts.
MonsterAIService.Caught = caught
-- (origin, seconds) when a pool lunge is telegraphed (the clients show the bubbles and the ripple ring there).
MonsterAIService.LungeTelegraph = lungeTelegraph
-- (floor point, target, seconds) a teleport's warning starts: the lights there stutter, a hiss rises.
MonsterAIService.TeleportWarning = teleportWarning
-- (target, kind) the target looked at it as it formed: their reveal scare ("Teleport").
MonsterAIService.Revealed = revealed
-- (player) someone's held stare started a chase.
MonsterAIService.Stared = stared
-- (player or nil, position) a chase ran out and it faded away.
MonsterAIService.GaveUp = gaveUp
-- (position) the low grunt before a LookAway.
MonsterAIService.Grunted = grunted

local serviceTrove = Trove.new()
local initialized = false

local clock: Clock = function(): number
	return Workspace:GetServerTimeNow()
end
I.customLineClear = nil :: ((from: Vector3, to: Vector3, ignore: Instance?) -> boolean)?
local customEngine: Locomotion.Engine? = nil
local customLights: { [string]: { LightField.Fixture } }? = nil

-- the run
local running = false
local difficulty: Enums.Difficulty = "Standard"
local speedScale = 1 -- SetSpeedScale (level tuning); every pace but a scripted one
local participants: { Player } = {}
local pacing: PacingDirector.Pacing? = nil
local runSeed = 0

-- the Creature
local creature: Model? = nil
local body: CreatureBody.Body? = nil
local mover: Locomotion.Mover? = nil
local ctx: Brain.Context? = nil
local creatureLevel: Enums.LevelId? = nil
local levelInfos: { [string]: Brain.LevelInfo } = {}
local navs: { [string]: FloorNav.Nav } = {}
local lights: { [string]: { LightField.Fixture } } = {}
local teleportPointCache: { [string]: { TeleportCandidate } } = {}
local doorModels: { [string]: Instance } = {}

-- the mind
local state: Enums.MonsterState = "Dormant"
local stateSince = 0
local current: Brain.StateModule = I.DORMANT
local lastReason = "placed"
local awake = false
local wakeAt: number? = nil
local paused = false
local chaseStarted: number? = nil
local chaseSeenAt = 0
local stunUntil = 0
local devHuntUntil = 0
local catching: Catching? = nil
local pendingReach: Reach? = nil
local grabbed: Player? = nil
local grabbedHeldAt = 0
local scripted: Hold? = nil
local noiseQueue: { Types.NoiseEvent } = {}
local alerts: { Brain.HeardNoise } = {}
local lastSeen: { [Player]: number } = {}
local splashArmed: { [Player]: number } = {}
local records: { [Player]: Record } = {}
local pulled: { [Player]: number } = {}
local swimmerAt = -math.huge
local swimmerPlayer: Player? = nil
local ignored: { [number]: boolean } = {}
local graceLevel: Enums.LevelId? = nil -- the spawn rule's grace holds the Creature on this level
local poolEnteredAt: number? = nil -- when a participant first stood in a pool room on this level
local poolRetreatUntil = -math.huge -- it retreats in the water after a grab until then
local telegraphSeq = 0
local oneShotSeq = 0

-- the view contract
local action: Enums.CreatureAction? = nil
local actionAt = 0
local speedMeasured = 0
local lastRoot: Vector3? = nil
local placements = 0
local lastPlacements = 0
local clearance = math.huge
local publishedFade = -1

-- warps, teleports, the hiding rule
local warp: Warp? = nil
local lookAway: Vector3? = nil
local stareTrigger: Player? = nil
local hideWatch: Brain.HideWatch? = nil
local startleUntil = -math.huge
local lastSeenAny = 0
local teleportReadyAt = math.huge
local nextTeleportTry = 0
local lastTeleportTarget: Player? = nil
local lastCatchAt = -math.huge
local lastDownAt = -math.huge
local teleports = 0
local creatureLit = false

-- hooks
local lockerInspector: Types.LockerInspector? = nil
local poolGrabber: Types.PoolGrabber? = nil
local hideSpots: HideSpots? = nil
local teleportBlocks: { () -> boolean } = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

function I.now(): number
	return clock()
end

function I.protected(label: string, fn: () -> ())
	xpcall(fn, function(err: any)
		log.warnThrottled(label, 10, "%s failed: %s\n%s", label, tostring(err), debug.traceback())
	end)
end

function I.levelInfoFor(levelId: string): Brain.LevelInfo?
	local cached = levelInfos[levelId]
	if cached then
		return cached
	end
	local layout = Builder.getLayout(levelId)
	local info = if layout then Brain.levelInfo(layout) else nil
	if info then
		levelInfos[levelId] = info
	end
	return info
end

-- A fixture door (a gate, an airlock door, the roof door) lets the Creature through only while it stands open.
function I.doorOpen(doorId: string): boolean
	local model: Instance? = doorModels[doorId]
	if not (model and model.Parent) then
		model = nil
		for _, tag in { Tags.AirlockDoor, Tags.ScriptedDoor } do
			for _, candidate in CollectionService:GetTagged(tag) do
				if candidate:GetAttribute(I.W.DoorId) == doorId then
					model = candidate
					break
				end
			end
			if model then
				break
			end
		end
		if not model then
			return true
		end
		doorModels[doorId] = model
	end
	local doorState = (model :: Instance):GetAttribute(I.W.DoorState)
	return doorState == nil or doorState == "Open" or doorState == "Smashed"
end

function I.navFor(levelId: string?): FloorNav.Nav?
	if not levelId then
		return nil
	end
	local cached = navs[levelId]
	if cached then
		return cached
	end
	local layout = Builder.getLayout(levelId)
	if not layout then
		return nil
	end
	local nav = FloorNav.new(layout, WorldConfig.levelOrigin(levelId), I.doorOpen, CreatureConfig.Rig.HunchedHeight)
	navs[levelId] = nav
	return nav
end

function I.lightsFor(levelId: string?): { LightField.Fixture }
	if not levelId then
		return {}
	end
	local custom = customLights
	if custom then
		return custom[levelId] or {}
	end
	local cached = lights[levelId]
	if cached then
		return cached
	end
	local collected = LightField.collect(levelId)
	if #collected > 0 then
		lights[levelId] = collected
	end
	return collected
end

function I.rootOf(player: Player): Vector3?
	local root = Instances.characterRoot(player)
	return if root then root.CFrame.Position else nil
end

function I.moveStateOf(player: Player): Enums.MoveState
	return PlayerStateService.GetMoveState(player)
end

function I.lifeOf(player: Player): Enums.LifeState
	return LifeStateService.GetState(player)
end

-- A player's view direction (unit), from their LookRelay.
function I.lookOf(player: Player): Vector3
	local yaw, pitch = PlayerStateService.GetLook(player)
	return MathUtil.vectorFromYawPitch(yaw, pitch)
end

-- Alive or Downed with a character (a player who left is no longer playing: LifeStateService forgets them).
function I.playing(player: Player): boolean
	return LifeStateService.IsPlaying(player) and Instances.characterRoot(player) ~= nil
end

function I.huntable(player: Player): boolean
	return not ignored[player.UserId] and I.playing(player)
end

function I.huntablePlayers(): { Player }
	local out: { Player } = {}
	for _, player in participants do
		if I.huntable(player) then
			table.insert(out, player)
		end
	end
	return out
end

function I.playingPlayers(): { Player }
	local out: { Player } = {}
	for _, player in participants do
		if I.playing(player) then
			table.insert(out, player)
		end
	end
	return out
end

function I.swimmingPlayer(player: Player): boolean
	return PlayerStateService.GetMode(player) == "Swim" or SWIM_STATES[I.moveStateOf(player)] == true
end

-- In a duct, or crouched in a crawlway of the Creature's level: it never goes in after them (or sees them there).
function I.inVent(player: Player): boolean
	if VentNetworkService.IsInVent(player) then
		return true
	end
	local info = ctx and ctx.level
	local root = I.rootOf(player)
	if not (info and root) then
		return false
	end
	local room = Brain.roomAt(info, root)
	return room ~= nil and room.kind == "Crawlway"
end

function I.playerEye(player: Player): Vector3?
	local root = I.rootOf(player)
	return if root then Perception.playerEyeAt(root, I.moveStateOf(player)) else nil
end

-- The contract's poseMode: Stunned, Swim, Hunched (posed so, or under a low clearance), else Biped.
function I.poseMode(): string
	if state == "Stunned" then
		return "Stunned"
	end
	local b = body
	local pose = if b then b.pose else "Biped"
	if pose == "Swim" or pose == "Hunched" then
		return pose
	end
	return if clearance < CreatureConfig.HunchBelow then "Hunched" else "Biped"
end

-- Its eye: where the rig's eyes are in the pose it stands in (a tunnel's ceiling is under its standing eye).
function I.creatureEye(): Vector3
	local b = body
	if not b then
		return Vector3.zero
	end
	return Perception.creatureEyeAt(b:GetCFrame(), I.poseMode())
end

-- How high its head stands over a root at `point` on land: hunched where the head room there is low.
function I.headLift(point: Vector3): number
	local eyes = CreatureConfig.EyeHeightAboveRoot
	local m = mover
	if m and m:BasinAt(point) then
		return eyes.Biped
	end
	local nav = I.navFor(creatureLevel)
	return if nav and nav:clearanceAt(point) < CreatureConfig.HunchBelow then eyes.Hunched else eyes.Biped
end

function I.exclusions(extra: Instance?): { Instance }
	local exclude: { Instance } = {}
	local model = creature
	if model then
		table.insert(exclude, model)
	end
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(exclude, character)
		end
	end
	if extra then
		table.insert(exclude, extra)
	end
	return exclude
end

-- A sight line (Default group, characters and the Creature excluded; `ignore` too when given).
function I.lineClear(from: Vector3, to: Vector3, ignore: Instance?): boolean
	local custom = I.customLineClear
	if custom then
		return custom(from, to, ignore)
	end
	return SpatialQuery.lineClear(from, to, SpatialQuery.losParams(I.exclusions(ignore)))
end

-- Could a player see the Creature with its root at `point` (its head or its chest): any clear line, any facing.
function I.visible(point: Vector3): boolean
	local head = I.headLift(point)
	for _, player in I.playingPlayers() do
		local eye = I.playerEye(player)
		if not eye or (eye - point).Magnitude > I.SIGHT_RANGE_LIMIT then
			continue
		end
		for _, lift in { head, 0 } do
			if I.lineClear(eye, point + Vector3.new(0, lift, 0)) then
				return true
			end
		end
	end
	return false
end

-- Whether a player sees the Creature with its root at `point`: inside their view cone (Teleport.ViewHalfAngle of their
-- look) with a clear line to its head or its chest, or right at their eye. Under a pool's surface only a player within
-- the murk range sees it. Every player in play counts, ignored ones included.
function I.inViewOfAnyone(point: Vector3): boolean
	local m = mover
	local murky = m ~= nil and m:BasinAt(point) ~= nil
	local head = I.headLift(point)
	for _, player in I.playingPlayers() do
		local eye = I.playerEye(player)
		if not eye then
			continue
		end
		local look = I.lookOf(player)
		for _, lift in { head, 0 } do
			local q = point + Vector3.new(0, lift, 0)
			local d = (eye - q).Magnitude
			if d <= I.NEAR_EYE then
				return true
			end
			if d > I.SIGHT_RANGE_LIMIT or (murky and d > I.WATER.MurkRange) then
				continue
			end
			if Perception.stareAngle(eye, look, q) <= I.T.ViewHalfAngle and I.lineClear(eye, q) then
				return true
			end
		end
	end
	return false
end

-- The straight distance from `point` to the nearest playing player's root (math.huge with none).
function I.nearestPlayerDistanceTo(point: Vector3): number
	local best = math.huge
	for _, player in I.playingPlayers() do
		local root = I.rootOf(player)
		if root then
			best = math.min(best, (root - point).Magnitude)
		end
	end
	return best
end

function I.nearestRoot(here: Vector3): Vector3?
	local best: Vector3? = nil
	local bestDistance = math.huge
	for _, player in I.playingPlayers() do
		local root = I.rootOf(player)
		if root and (root - here).Magnitude < bestDistance then
			best, bestDistance = root, (root - here).Magnitude
		end
	end
	return best
end

function I.playerEyes(): { Vector3 }
	local out: { Vector3 } = {}
	for _, player in I.playingPlayers() do
		local eye = I.playerEye(player)
		if eye then
			table.insert(out, eye)
		end
	end
	return out
end

-- Root positions the Creature can stand at on its level: every patrol waypoint (under water where the waypoint is).
function I.standingSpots(info: Brain.LevelInfo): { Vector3 }
	local m = mover
	local out: { Vector3 } = {}
	for _, waypoint in info.waypoints do
		local point = waypoint.position
		if m and m:BasinAt(point) then
			table.insert(out, point)
		else
			table.insert(out, point + Vector3.new(0, CreatureBody.RootHeight, 0))
		end
	end
	return out
end

-- Root positions over the whole floor: the waypoints, then the nav's lattice (land only).
function I.landSpots(info: Brain.LevelInfo): { Vector3 }
	local m = mover
	local out: { Vector3 } = {}
	for _, point in I.standingSpots(info) do
		if not (m and m:BasinAt(point)) then
			table.insert(out, point)
		end
	end
	local nav = I.navFor(info.levelId)
	if nav then
		for _, sample in nav:samplePoints(I.SAMPLE_SPACING) do
			table.insert(out, sample.position + Vector3.new(0, CreatureBody.RootHeight, 0))
		end
	end
	return out
end

function I.sees(player: Player): boolean
	local c = ctx
	if not c then
		return false
	end
	for _, sighting in c.sightings do
		if sighting.player == player then
			return true
		end
	end
	return false
end

function I.grateStandPoint(grate: VentGraph.Grate): CFrame
	local model = VentNetworkService.GetGrateModel(grate.id)
	local anchor = if model then PropKit.findAttachment(model, I.EXIT_ANCHOR) else nil
	if anchor then
		return PropKit.attachmentWorld(anchor)
	end
	local wall = grate.wall
	local out = wall.Position + wall.LookVector * (WorldConfig.WallThickness / 2 + VentGrateBuilder.ExitOut)
	local floor = Vector3.new(out.X, wall.Position.Y - WorldConfig.VentCenterHeight, out.Z)
	local facing = CreatureBody.flatDirection(wall.LookVector) or Vector3.new(0, 0, -1)
	return CFrame.lookAt(floor, floor + facing)
end

-- A floor point for a believed position: a point inside a duct becomes the room side of the grate nearest it.
function I.floorPointNear(position: Vector3): Vector3
	local graph = if creatureLevel then VentNetworkService.GetGraph(creatureLevel) else nil
	if not graph or VentGraph.nearest(graph, position, I.DUCT_SNAP) == nil then
		return position
	end
	local best: VentGraph.Grate? = nil
	local bestDistance = math.huge
	for _, grate in graph.grates do
		local distance = (grate.mouth - position).Magnitude
		if distance < bestDistance then
			best, bestDistance = grate, distance
		end
	end
	return if best then I.grateStandPoint(best).Position else position
end

-- The hiding spots of its level within `radius` of `point`.
function I.hideSpotsNear(point: Vector3, radius: number): { Brain.HideSpot }
	local provider = hideSpots
	local out: { Brain.HideSpot } = {}
	if not (provider and creatureLevel) then
		return out
	end
	for _, spot in provider.spotsOn(creatureLevel) do
		if (spot.front.Position - point).Magnitude <= radius then
			table.insert(out, spot)
		end
	end
	return out
end

function I.hideSpotFront(spot: Instance): CFrame?
	local provider = hideSpots
	if not (provider and creatureLevel) then
		return nil
	end
	for _, entry in provider.spotsOn(creatureLevel) do
		if entry.id == spot then
			return entry.front
		end
	end
	return nil
end

function I.hideSpotOccupant(spot: Instance): Player?
	local provider = hideSpots
	return if provider then provider.occupant(spot) else nil
end

function I.hideSpotOf(player: Player): Instance?
	local provider = hideSpots
	return if provider then provider.spotOf(player) else nil
end

-- The bodies see each other: chest to chest (never a catch through a wall). `through` is the hiding spot a ReachIn
-- reaches into: its own door and shell are no wall (the catch tears its door off).
function I.bodyClear(player: Player, through: Instance?): boolean
	local root = I.rootOf(player)
	local b = body
	if not (root and b) then
		return false
	end
	local here = b:GetPosition()
	return I.lineClear(here + Vector3.new(0, 1, 0), root + Vector3.new(0, 0.5, 0), through)
end

function I.recordOf(player: Player): Record
	local r = records[player]
	if not r then
		r = {
			trail = {},
			trailAt = -math.huge,
			last = nil,
			lastAt = 0,
			speed = 0,
			travel = nil,
			stare = 0,
			hiding = false,
			life = nil,
			loudAt = -math.huge,
		}
		records[player] = r
	end
	return r
end

-- The level the Creature is on holds this player (a room of it under their feet).
function I.onLevel(player: Player): boolean
	local root = I.rootOf(player)
	local nav = I.navFor(creatureLevel)
	if not (root and nav) then
		return false
	end
	local room = nav:roomAt(root)
	return room ~= nil and math.abs(root.Y - I.PLAYER_FLOOR - room.floorY) < 8
end

--------------------------------------------------------------------------------
-- The view contract and the attributes
--------------------------------------------------------------------------------

function I.setAction(name: Enums.CreatureAction?)
	if action == name and name ~= nil then
		return
	end
	action = name
	actionAt = I.now()
	local model = creature
	if model then
		Attributes.set(model, I.C.Action, name or I.ACTION_NONE)
		Attributes.set(model, I.C.ActionAt, actionAt)
	end
end

-- How visible it is: the warp's FadeOut / FadeIn ramps, 0 hidden, 1 shown.
function I.fadeAt(t: number): number
	local w = warp
	if w then
		if w.phase == "FadeOut" then
			return math.clamp(1 - (t - w.phaseAt) / I.T.FadeOutSeconds, 0, 1)
		elseif w.phase == "FadeIn" then
			return math.clamp((t - w.phaseAt) / I.T.FadeInSeconds, 0, 1)
		elseif w.phase == "Hidden" or w.phase == "Warning" then
			return 0
		end
	end
	local b = body
	return if b and b.hidden then 0 else 1
end

function I.publish()
	local model, b, c = creature, body, ctx
	if not (model and b and c) then
		return
	end
	local target = c.target
	Attributes.set(model, I.C.MonsterState, state)
	Attributes.set(model, I.C.StateSince, stateSince)
	Attributes.set(model, I.C.PoseMode, if I.poseMode() == "Hunched" then "Hunched" else b.pose)
	Attributes.set(model, I.C.TargetUserId, if target then target.UserId else 0)
	Attributes.set(model, I.C.InVent, false)
	Attributes.set(model, I.C.Hidden, b.hidden)
	Attributes.set(model, I.C.GrabbedUserId, if grabbed then (grabbed :: Player).UserId else 0)
	Attributes.set(model, I.C.Action, action or I.ACTION_NONE)
	Attributes.set(model, I.C.ActionAt, actionAt)
	if creatureLevel then
		Attributes.set(model, I.C.LevelId, creatureLevel)
	end
end

-- The attributes that change with movement, every frame (the rest are written each brain tick).
function I.publishMotion(t: number)
	local model, b = creature, body
	if not (model and b) then
		return
	end
	Attributes.set(model, I.C.PoseMode, if I.poseMode() == "Hunched" then "Hunched" else b.pose)
	local fade = math.floor(I.fadeAt(t) * 100 + 0.5) / 100
	if fade ~= publishedFade then
		publishedFade = fade
		Attributes.set(model, I.C.Fade, fade)
	end
end

--------------------------------------------------------------------------------
-- Body placement
--------------------------------------------------------------------------------

-- Puts the root at `cframe` (anchored, held), in the medium that point is in.
function I.placeBody(cframe: CFrame)
	local b, m = body, mover
	if not (b and m) then
		return
	end
	m:Reset("Floor")
	b:Face(nil)
	b:SetAnchored(true)
	b:PlaceAt(cframe)
	placements += 1
	local water = m:BasinAt(cframe.Position) ~= nil
	m:Reset(if water then "Water" else "Floor")
	if water then
		b:SetPose("Swim")
	elseif b.pose == "Swim" or b.pose == "Quadruped" then
		b:SetPose("Biped")
	end
	clearance = I.headroom(cframe.Position)
end

-- Hidden where it stands until nobody can see it there; then it fades in (a "Reveal" warp).
function I.hide()
	local b = body
	if not b then
		return
	end
	I.startWarp({
		kind = "Reveal",
		startHidden = true,
		to = b:GetCFrame(),
		pick = function(): CFrame?
			return I.unseenSpot(0)
		end,
	})
end

function I.cancelWarp()
	if not warp then
		return
	end
	warp = nil
	if action == "FadeOut" or action == "FadeIn" or action == "Stare" then
		I.setAction(nil)
	end
end

function I.forgetMind()
	local c = ctx
	if c then
		c.target = nil
		c.memory = nil
		c.investigation = nil
		c.searchFrom = nil
		c.hiding = nil
		c.teleportPlan = nil
		c.heard = nil
		c.sightings = {}
		c.reposition = false
		c.stateDone = false
		table.clear(c.heardZones)
	end
	noiseQueue = {}
	alerts = {}
	table.clear(lastSeen)
	table.clear(records)
	table.clear(pulled)
	hideWatch = nil
	stareTrigger = nil
	pendingReach = nil
	lookAway = nil
	swimmerPlayer = nil
	swimmerAt = -math.huge
	poolRetreatUntil = -math.huge
	chaseStarted = nil
end

-- The CreatureSpawn of `levelId` by the run's arrival: on the roof the one in the access housing the route arrives by
-- (L5_CreatureSpawnNorth / South, or the middle L5_CreatureSpawn), elsewhere the level's own.
function I.arrivalSpawn(levelId: Enums.LevelId, info: Brain.LevelInfo): CFrame?
	local layout = Builder.getLayout(levelId)
	local entry = LevelDirector.entryFor(levelId)
	if not (layout and entry) then
		return info.spawn
	end
	for _, anchor in layout.anchors do
		if anchor.kind ~= "CreatureSpawn" then
			continue
		end
		local slot = string.match(anchor.id, "(North)$") or string.match(anchor.id, "(South)$") or "Middle"
		if slot == entry.slot then
			return CFrame.new(WorldConfig.levelOrigin(levelId) + anchor.pos)
				* CFrame.Angles(0, math.rad(anchor.yaw or 0), 0)
		end
	end
	return info.spawn
end

function I.setLevel(levelId: Enums.LevelId)
	local c, m = ctx, mover
	if not (c and m) then
		return
	end
	local info = I.levelInfoFor(levelId)
	creatureLevel = levelId
	c.level = info
	m:SetLevel(if info then info.basins else {})
	table.clear(doorModels)
end

-- Moves the Creature onto `levelId` at its CreatureSpawn (hidden until nobody can see it when `conceal`).
function I.relocate(levelId: Enums.LevelId, conceal: boolean)
	local c = ctx
	if not c then
		return
	end
	I.setLevel(levelId)
	I.forgetMind()
	I.cancelWarp()
	poolEnteredAt = nil
	local info = c.level
	local spawn = if info then I.arrivalSpawn(levelId, info) else nil
	if not spawn and info and info.waypoints[1] then
		spawn = CFrame.new(I.standingSpots(info)[1])
	end
	if spawn then
		I.placeBody(spawn)
	end
	if conceal then
		local b = body
		if scripted and b then
			b:SetHidden(true)
		else
			I.hide()
		end
	end
end

--------------------------------------------------------------------------------
-- Warps (every FadeOut / FadeIn relocation)
--------------------------------------------------------------------------------

I.startWarp = function(opts: WarpOptions)
	local t = I.now()
	warp = {
		kind = opts.kind,
		phase = if opts.startHidden then "Hidden" else "FadeOut",
		phaseAt = t,
		startedAt = t,
		to = opts.to,
		pick = opts.pick,
		warning = opts.warning == true,
		stare = opts.stare == true,
		plan = opts.plan,
		retries = 0,
		placed = false,
		revealed = false,
		pickedAt = if opts.to then t else -math.huge,
	}
	lookAway = nil
	local m, b = mover, body
	if m then
		m:Stop()
	end
	if not b then
		return
	end
	if opts.startHidden then
		b:SetHidden(true)
		I.setAction(nil)
	else
		b:SetHidden(false)
		I.setAction("FadeOut")
		AudioService.PlayAt(I.VANISH_PRESET, b:GetPosition() + Vector3.new(0, I.VANISH_LIFT, 0))
	end
end

-- Whether the Creature may appear at `cframe` now: nobody sees the spot, nobody within MinStraight of it.
function I.clearToAppear(cframe: CFrame, kind: WarpKind): boolean
	local p = cframe.Position
	if I.nearestPlayerDistanceTo(p) < I.T.MinStraight then
		return false
	end
	if kind == "Teleport" then
		return not I.inViewOfAnyone(p)
	end
	local m = mover
	if m and m:BasinAt(p) then
		return not I.inViewOfAnyone(p)
	end
	return not I.visible(p)
end

function I.faceTarget(w: Warp)
	local b = body
	local plan = w.plan
	local root = if plan then I.rootOf(plan.target) else nil
	if b and root then
		b:Face(root - b:GetPosition())
	end
end

function I.beginFadeIn(t: number)
	local w, b = warp, body
	if not (w and b) then
		return
	end
	b:SetHidden(false)
	w.phase = "FadeIn"
	w.phaseAt = t
	I.setAction("FadeIn")
	I.faceTarget(w)
end

function I.endWarp()
	local w = warp
	warp = nil
	if action == "FadeIn" or action == "Stare" or action == "FadeOut" then
		I.setAction(nil)
	end
	local b, m = body, mover
	if b then
		b:SetHidden(false)
	end
	if m and b then
		m:Reset(if m:BasinAt(b:GetPosition()) then "Water" else "Floor")
	end
	if w and w.kind == "Teleport" then
		lastSeenAny = math.max(lastSeenAny, I.now())
	end
end

-- The reveal scare for `player` (a teleport's, or a hiding spot's fake-out): PrivateCue Scare.
function I.sendScare(player: Player, scare: Enums.ScareKind, key: string?, value: Types.OneShotArg?)
	if player.Parent ~= Players then
		return
	end
	local args: { [string]: Types.OneShotArg } = { scare = scare }
	if key and value ~= nil then
		args[key] = value
	end
	local payload: Types.PrivateCuePayload = { kind = "Scare", startAt = I.now(), endsAt = nil, args = args }
	Net.Server.fire("PrivateCue", player, payload)
end

-- The target looks at it as it forms (within Stare.RevealHalfAngle, a clear line): their reveal scare, once.
function I.checkReveal(w: Warp)
	local plan = w.plan
	if w.revealed or not plan then
		return
	end
	local target = plan.target
	local eye = I.playerEye(target)
	if not eye or not I.playing(target) then
		return
	end
	local head = I.creatureEye()
	if (eye - head).Magnitude > I.T.MaxWalk * 2 then
		return
	end
	if Perception.stareAngle(eye, I.lookOf(target), head) > CreatureConfig.Stare.RevealHalfAngle then
		return
	end
	if not I.lineClear(eye, head) then
		return
	end
	w.revealed = true
	I.sendScare(target, "Reveal", "kind", "Teleport")
	revealed:Fire(target, "Teleport")
end

-- One warp step (every motion step).
function I.stepWarp(t: number)
	local w = warp
	local b = body
	if not (w and b) then
		return
	end
	if w.phase == "FadeOut" then
		if t - w.phaseAt < I.T.FadeOutSeconds then
			return
		end
		b:SetHidden(true)
		I.setAction(nil)
		w.phase = "Hidden"
		w.phaseAt = t
		return
	end
	if w.phase == "Hidden" then
		if not w.to then
			-- a destination: the warp's own pick (throttled), or once this has gone on too long any spot out of sight
			local late = t - w.startedAt > I.WARP_GIVE_UP
			local pick = w.pick
			if not late and pick and t - w.pickedAt >= I.WARP_WAIT then
				w.to = pick()
				w.pickedAt = t
			end
			if not w.to and late and t - w.pickedAt >= 1 then
				w.to = I.unseenSpot(I.T.MinStraight)
				w.pickedAt = t
				w.warning = false
				w.stare = false
			end
			if not w.to then
				return
			end
			w.placed = false
			w.phaseAt = t
		end
		local to = w.to :: CFrame
		if not w.placed then
			I.placeBody(to)
			w.placed = true
		end
		if not I.clearToAppear(to, w.kind) then
			-- still watched there: another spot shortly
			if t - w.phaseAt >= I.WARP_WAIT then
				w.to = nil
			end
			return
		end
		if w.warning then
			w.phase = "Warning"
			w.phaseAt = t
			local floor = to.Position - Vector3.new(0, CreatureBody.RootHeight, 0)
			local plan = w.plan
			local target = if plan then plan.target else nil
			oneShotSeq += 1
			local event: Types.OneShotEvent = {
				seq = oneShotSeq,
				kind = "TeleportWarning",
				subject = nil,
				startAt = t,
				args = {
					spot = floor,
					seconds = I.T.WarningSeconds,
					radius = I.T.FlickerRadius,
					target = if target then target.UserId else 0,
				},
			}
			Net.Server.fireAll("OneShot", event)
			AudioService.PlayAt(I.HISS_PRESET, floor + Vector3.new(0, I.HISS_LIFT, 0))
			if target then
				I.sendScare(target, "TorchStutter", "seconds", I.T.WarningSeconds)
			end
			teleportWarning:Fire(floor, target, I.T.WarningSeconds)
			return
		end
		I.beginFadeIn(t)
		return
	end
	if w.phase == "Warning" then
		if t - w.phaseAt < I.T.WarningSeconds then
			return
		end
		local to = w.to
		if not to or not I.clearToAppear(to, w.kind) then
			-- watched now: another spot (and another warning), or after Retries any spot out of sight, unannounced
			w.retries += 1
			local pick = w.pick
			if w.retries > I.T.Retries then
				w.warning = false
				w.stare = false
				w.to = I.unseenSpot(I.T.MinStraight)
			else
				w.to = if pick then pick() else nil
			end
			w.pickedAt = t
			w.placed = false
			w.phase = "Hidden"
			w.phaseAt = t
			return
		end
		I.beginFadeIn(t)
		return
	end
	if w.phase == "FadeIn" then
		if w.stare then
			I.checkReveal(w)
		end
		if t - w.phaseAt < I.T.FadeInSeconds then
			return
		end
		if w.stare then
			w.phase = "Stare"
			w.phaseAt = t
			I.setAction("Stare")
			return
		end
		I.endWarp()
		return
	end
	-- the Stare
	I.checkReveal(w)
	I.faceTarget(w)
	if t - w.phaseAt >= I.T.StareSeconds or stareTrigger ~= nil then
		I.endWarp()
	end
end

-- A root CFrame out of everyone's sight at least `minDistance` from them (nearest to it first), or nil.
I.unseenSpot = function(minDistance: number): CFrame?
	local c, b = ctx, body
	local info = c and c.level
	if not (info and b) then
		return nil
	end
	local here = b:GetPosition()
	local point =
		PacingDirector.repositionPoint(I.landSpots(info), I.playerEyes(), here, minDistance, math.huge, I.visible)
	if not point then
		return nil
	end
	local toward = I.nearestRoot(point)
	local facing = (if toward then CreatureBody.flatDirection(toward - point) else nil)
		or CreatureBody.flatDirection(b:GetCFrame().LookVector)
		or Vector3.new(0, 0, -1)
	return CFrame.lookAt(point, point + facing)
end

-- A point under the water of `basin`, nearest `goal`, that no swimmer close by would see.
function I.waterSpot(basin: Locomotion.Basin?, goal: Vector3): CFrame?
	if not basin then
		return nil
	end
	local depth = Locomotion.SwimDepth
	local candidates: { Vector3 } = { Locomotion.clampToWater(basin, goal, depth) }
	for _, x in { basin.minX, (basin.minX + basin.maxX) / 2, basin.maxX } do
		for _, k in { 0, 0.25, 0.5, 0.75, 1 } do
			local z = basin.minZ + (basin.maxZ - basin.minZ) * k
			table.insert(candidates, Locomotion.clampToWater(basin, Vector3.new(x, basin.surfaceY - depth, z), depth))
		end
	end
	table.sort(candidates, function(a: Vector3, b: Vector3): boolean
		return (a - goal).Magnitude < (b - goal).Magnitude
	end)
	for _, p in candidates do
		local facing = CreatureBody.flatDirection(goal - p) or Vector3.new(0, 0, -1)
		local cf = CFrame.lookAt(p, p + facing)
		if I.clearToAppear(cf, "Pool") then
			return cf
		end
	end
	return nil
end

-- A land spot out of the pool (ExitMin from everyone, out of sight), nearest `goal`.
function I.landSpot(goal: Vector3): CFrame?
	local c = ctx
	local info = c and c.level
	if not info then
		return nil
	end
	local point =
		PacingDirector.repositionPoint(I.landSpots(info), I.playerEyes(), goal, I.WATER.ExitMin, math.huge, I.visible)
	if not point then
		return nil
	end
	local toward = I.nearestRoot(point)
	local facing = (if toward then CreatureBody.flatDirection(toward - point) else nil) or Vector3.new(0, 0, -1)
	return CFrame.lookAt(point, point + facing)
end

-- Warps for the Mover (into / out of a pool): a fade out here and in at the destination, out of sight.
function I.warpForMover(goal: Vector3, medium: Locomotion.Medium): boolean
	local m = mover
	if warp or not ctx or not m then
		return false
	end
	if medium == "Water" then
		local basin = m:BasinAt(goal)
		I.startWarp({
			kind = "Pool",
			pick = function(): CFrame?
				return I.waterSpot(basin, goal)
			end,
		})
	else
		I.startWarp({
			kind = "Pool",
			pick = function(): CFrame?
				return I.landSpot(goal)
			end,
		})
	end
	return true
end

function I.setTarget(player: Player?)
	local c = ctx
	if not c or c.target == player then
		return
	end
	c.target = player
	local memory = c.memory
	if memory and memory.player ~= player then
		c.memory = nil
	end
end

-- A chase that ran out: it fades out where it stands and comes back far from everyone, out of sight.
function I.giveUp(t: number)
	local c, b = ctx, body
	if not (c and b) then
		return
	end
	local target = c.target
	local here = b:GetPosition()
	if target then
		I.sendScare(target, "GiveUp")
	end
	gaveUp:Fire(target, here)
	I.setTarget(nil)
	c.memory = nil
	c.reposition = false
	local g = CreatureConfig.GiveUp
	I.startWarp({
		kind = "GiveUp",
		pick = function(): CFrame?
			local info = c.level
			local bb = body
			if not (info and bb) then
				return nil
			end
			local from = bb:GetPosition()
			local point = PacingDirector.repositionPoint(
				I.landSpots(info),
				I.playerEyes(),
				from,
				g.MinDistance,
				g.MaxDistance,
				I.visible
			)
			if not point then
				return nil
			end
			local facing = CreatureBody.flatDirection(from - point) or Vector3.new(0, 0, -1)
			return CFrame.lookAt(point, point + facing)
		end,
	})
	local low = Brain.difficultySpec(difficulty).teleportCooldown[1]
	teleportReadyAt = math.max(teleportReadyAt, t + low / 2)
end

--------------------------------------------------------------------------------
-- Teleports
--------------------------------------------------------------------------------

function I.teleportBlocked(): boolean
	for _, blocked in teleportBlocks do
		local ok, result = pcall(blocked)
		if ok and result == true then
			return true
		end
	end
	return false
end

-- The players a teleport may go for: hunted, on its level, on foot (not hiding, in a duct or crawlway, or swimming).
function I.teleportTargets(): { Player }
	local out: { Player } = {}
	for _, player in I.huntablePlayers() do
		if
			not I.inVent(player)
			and not I.swimmingPlayer(player)
			and I.moveStateOf(player) ~= "Hiding"
			and I.onLevel(player)
		then
			table.insert(out, player)
		end
	end
	return out
end

-- Teleport candidates: the level's tunnel centreline points (TunnelRules.teleportPoints) when it has tunnels, else
-- the nav's lattice: { position (floor), room }.
function I.teleportCandidates(nav: FloorNav.Nav): { TeleportCandidate }
	local level = creatureLevel
	if not level then
		return {}
	end
	local cached = teleportPointCache[level]
	if cached then
		return cached
	end
	local out: { TeleportCandidate } = {}
	local layout = Builder.getLayout(level)
	if layout and layout.tunnels then
		local origin = WorldConfig.levelOrigin(level)
		for _, point in TunnelRules.teleportPoints(layout :: any) do
			local at = origin + point.pos
			local room = nav:roomAt(at)
			if room then
				table.insert(out, { position = Vector3.new(at.X, room.floorY, at.Z), room = point.zone or room.id })
			end
		end
	end
	if #out == 0 then
		for _, sample in nav:samplePoints(I.SAMPLE_SPACING) do
			table.insert(out, { position = sample.position, room = sample.room })
		end
	end
	teleportPointCache[level] = out
	return out
end

-- The spot near `target` (docs/MONSTER.md 7.2), or nil.
function I.teleportSpot(target: Player, nav: FloorNav.Nav): Brain.TeleportPlan?
	local c = ctx
	local root = I.rootOf(target)
	if not (c and root) then
		return nil
	end
	local room = nav:roomAt(root)
	if not room then
		return nil
	end
	local feet = Vector3.new(root.X, room.floorY, root.Z)
	local keepRoom = if TUNNEL_KINDS[room.kind] then nil else room.id
	local rec = I.recordOf(target)
	local t = I.now()
	local trail: { Vector3 } = {}
	for _, entry in rec.trail do
		if t - entry.t >= I.TRAIL_SKIP then
			table.insert(trail, entry.p)
		end
	end
	local look = I.lookOf(target)
	type Bucketed = { appear: Vector3, walk: number }
	local buckets: { [string]: { Bucketed } } = { Behind = {}, Ahead = {}, Side = {} }
	for _, cand in I.teleportCandidates(nav) do
		local p = cand.position
		if math.abs(p.Y - room.floorY) > 6 then
			continue
		end
		if MathUtil.horizontalDistance(p, root) > I.T.MaxWalk + 0.5 then
			continue
		end
		if keepRoom and cand.room == keepRoom then
			continue
		end
		local appear = p + Vector3.new(0, CreatureBody.RootHeight, 0)
		if I.nearestPlayerDistanceTo(appear) < I.T.MinStraight then
			continue
		end
		local walk = nav:pathLength(feet, p)
		if walk < I.T.MinWalk or walk > I.T.MaxWalk then
			continue
		end
		if I.inViewOfAnyone(appear) then
			continue
		end
		table.insert(buckets[Teleport.classify(p, root, trail, look, rec.travel)], { appear = appear, walk = walk })
	end
	local behindFirst = c.random:NextNumber() < I.T.BehindShare
	local order: { string } = if behindFirst then { "Behind", "Ahead", "Side" } else { "Ahead", "Behind", "Side" }
	for _, side in order do
		local list = buckets[side]
		if #list == 0 then
			continue
		end
		local chosen = list[math.floor(c.random:NextNumber() * #list) + 1]
		local facing = CreatureBody.flatDirection(root - chosen.appear) or Vector3.new(0, 0, -1)
		return {
			target = target,
			spot = CFrame.lookAt(chosen.appear, chosen.appear + facing),
			side = side,
			walk = chosen.walk,
		}
	end
	return nil
end

-- The target (weighted) and the spot for a teleport, or nil.
function I.planTeleport(): Brain.TeleportPlan?
	local c = ctx
	local nav = I.navFor(creatureLevel)
	if not (c and nav) then
		return nil
	end
	local targets = I.teleportTargets()
	if #targets == 0 then
		return nil
	end
	local t = I.now()
	local inPlay = I.playingPlayers()
	local weights: { number } = {}
	for _, player in targets do
		local root = I.rootOf(player)
		local isolated = #inPlay >= 2
		for _, other in inPlay do
			local r = if other == player then nil else I.rootOf(other)
			if r and root and (r - root).Magnitude <= I.T.Isolated then
				isolated = false
			end
		end
		local loud = t - I.recordOf(player).loudAt <= I.T.LoudWindow
		table.insert(
			weights,
			Teleport.targetWeight({ isolated = isolated, loud = loud, lastTarget = player == lastTeleportTarget })
		)
	end
	local target = Teleport.pickWeighted(targets, weights, c.random:NextNumber())
	return if target then I.teleportSpot(target, nav) else nil
end

-- The teleport is due now: every condition of docs/MONSTER.md 7.2 holds and a plan exists (ctx.teleportPlan).
function I.teleportDue(t: number): boolean
	local c, m = ctx, mover
	if not (c and m and c.level) or state ~= "Patrol" or warp then
		return false
	end
	if t < teleportReadyAt or t < nextTeleportTry then
		return false
	end
	if t - lastSeenAny < I.T.UnseenSeconds then
		return false
	end
	if t < lastCatchAt + I.T.AfterCatch or t < lastDownAt + I.T.AfterCatch then
		return false
	end
	if m:Medium() ~= "Floor" or I.teleportBlocked() then
		return false
	end
	local plan = I.planTeleport()
	if not plan then
		nextTeleportTry = t + I.TELEPORT_RETRY
		return false
	end
	c.teleportPlan = plan
	return true
end

-- Teleport.enter: the warp to the planned spot (FadeOut here, the warning there, FadeIn, the stare).
function I.startTeleport(plan: Brain.TeleportPlan): boolean
	local c = ctx
	if not c or warp then
		return false
	end
	local t = I.now()
	local cooldown = Brain.difficultySpec(difficulty).teleportCooldown
	teleportReadyAt = t + c.random:NextNumber(cooldown[1], cooldown[2])
	lastTeleportTarget = plan.target
	teleports += 1
	I.startWarp({
		kind = "Teleport",
		to = plan.spot,
		warning = true,
		stare = true,
		plan = plan,
		pick = function(): CFrame?
			local nav = I.navFor(creatureLevel)
			local again = if nav and I.playing(plan.target) then I.teleportSpot(plan.target, nav) else nil
			return if again then again.spot else nil
		end,
	})
	log.debug("teleport %s %s (%.0f studs walked)", plan.side, plan.target.Name, plan.walk)
	return true
end

--------------------------------------------------------------------------------
-- The pool (Level 4 fairness)
--------------------------------------------------------------------------------

-- Whether `point` stands in a pool room (a basin's water, or a room of kind Pool) of the Creature's level.
function I.inPoolRoomAt(point: Vector3?): boolean
	local c, m = ctx, mover
	local info = c and c.level
	if not (point and info and m) or #info.basins == 0 then
		return false
	end
	if m:BasinAt(point) then
		return true
	end
	local room = Brain.roomAt(info, point)
	return room ~= nil and room.kind == "Pool"
end

function I.inPoolRoom(player: Player): boolean
	return I.swimmingPlayer(player) or I.inPoolRoomAt(I.rootOf(player))
end

-- The pool grace starts the first time a participant stands in a pool room on this level.
function I.updatePoolGrace(t: number)
	local c = ctx
	if poolEnteredAt ~= nil or not (c and c.level) or #(c.level :: Brain.LevelInfo).basins == 0 then
		return
	end
	for _, player in I.playingPlayers() do
		if I.inPoolRoom(player) then
			poolEnteredAt = t
			log.info("the pool grace runs (%ds)", I.WATER.PoolGraceSeconds)
			return
		end
	end
end

-- The grace after first entering the pool room, or the retreat after a grab: the pool rooms are left alone.
function I.poolQuiet(t: number): boolean
	local entered = poolEnteredAt
	return (entered ~= nil and t < entered + I.WATER.PoolGraceSeconds) or t < poolRetreatUntil
end

-- While it retreats after a grab: the point of its pool farthest from the nearest player (else nil).
function I.poolRetreatPoint(): Vector3?
	local b, m = body, mover
	if not (b and m) or I.now() >= poolRetreatUntil or m:Medium() ~= "Water" then
		return nil
	end
	local here = b:GetPosition()
	local basin = m:BasinAt(here)
	if not basin then
		return nil
	end
	local from = I.nearestRoot(here) or here
	local best: Vector3? = nil
	local bestDistance = -1
	for _, x in { basin.minX, (basin.minX + basin.maxX) / 2, basin.maxX } do
		for _, z in { basin.minZ, (basin.minZ + basin.maxZ) / 2, basin.maxZ } do
			local point = Locomotion.clampToWater(basin, Vector3.new(x, basin.surfaceY - Locomotion.SwimDepth, z))
			local d = MathUtil.horizontalDistance(point, from)
			if d > bestDistance then
				best, bestDistance = point, d
			end
		end
	end
	return best
end

-- A lunge is coming: a low growl at its origin, and the clients' bubbles and ripple ring (OneShot LungeTelegraph).
function I.telegraph(origin: Vector3, seconds: number)
	AudioService.PlayAt(I.TELEGRAPH_PRESET, origin, { volume = 1.2 })
	telegraphSeq += 1
	local event: Types.OneShotEvent = {
		seq = telegraphSeq,
		kind = "LungeTelegraph",
		subject = nil,
		startAt = I.now(),
		args = { origin = origin, seconds = seconds },
	}
	Net.Server.fireAll("OneShot", event)
	lungeTelegraph:Fire(origin, seconds)
end

-- Teleports to the nearest standing spot (>= UNSTICK_MIN away) nobody can see, only while nobody sees it here.
function I.relocateUnseen(): boolean
	local c, b = ctx, body
	local info = c and c.level
	if not (info and b) then
		return false
	end
	local here = b:GetPosition()
	if I.visible(here) then
		return false
	end
	local spots: { Vector3 } = {}
	for _, spot in I.standingSpots(info) do
		if (spot - here).Magnitude >= I.UNSTICK_MIN then
			table.insert(spots, spot)
		end
	end
	local point = PacingDirector.repositionPoint(spots, I.playerEyes(), here, 0, math.huge, I.visible)
	if not point then
		return false
	end
	local facing = CreatureBody.flatDirection(b:GetCFrame().LookVector) or Vector3.new(0, 0, -1)
	I.placeBody(CFrame.lookAt(point, point + facing))
	log.debug("the Creature was stuck; moved unseen to %s", tostring(point))
	return true
end

--------------------------------------------------------------------------------
-- Targets and catches
--------------------------------------------------------------------------------

function I.canHuntNow(): boolean
	local p = pacing
	local t = I.now()
	return t < devHuntUntil or (p ~= nil and p:CanHunt(t))
end

function I.catchKindFor(player: Player): Enums.JumpscareKind?
	local b, m = body, mover
	local target = I.rootOf(player)
	if not (b and m and target) then
		return nil
	end
	local here = b:GetPosition()
	local eye = I.playerEye(player) or target
	return Brain.catchKind({
		horizontal = MathUtil.horizontalDistance(here, target),
		vertical = math.abs(here.Y - target.Y),
		reach = CreatureConfig.Rig.Reach,
		targetInVent = I.inVent(player),
		creatureInWater = m:Medium() == "Water",
		targetSwimming = I.swimmingPlayer(player),
		lineClear = I.lineClear(I.creatureEye(), eye),
		bodyClear = I.bodyClear(player, nil),
		playing = I.huntable(player),
		hiding = I.moveStateOf(player) == "Hiding",
		canHunt = I.canHuntNow(),
		busy = catching ~= nil or JumpscareHandler.IsBusy(),
		hidden = b.hidden,
		stunned = I.now() < stunUntil,
		warping = warp ~= nil,
	})
end

-- A catch's staging step from root `from` to `to`, cut short where its body would meet the Monster geometry: easing it
-- back from a close victim never puts the root in or behind a wall (the rig's bow steps back the rest, on screen).
function I.stageTo(from: CFrame, to: CFrame): CFrame
	local a, b = from.Position, to.Position
	local length = math.sqrt((b.X - a.X) ^ 2 + (b.Z - a.Z) ^ 2)
	if length < 1e-3 then
		return to
	end
	local dir = Vector3.new((b.X - a.X) / length, 0, (b.Z - a.Z) / length)
	local free = length
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = I.exclusions(nil)
	params.CollisionGroup = "Monster"
	params.RespectCanCollide = true
	for _, lift in STAGE_LIFTS do
		local hit = Workspace:Raycast(a + Vector3.new(0, lift, 0), dir * (length + I.BODY_RADIUS), params)
		if hit then
			free = math.min(free, math.max(0, hit.Distance - I.BODY_RADIUS))
		end
	end
	if free >= length - 1e-3 then
		return to
	end
	return to.Rotation + Vector3.new(a.X + dir.X * free, b.Y, a.Z + dir.Z * free)
end

function I.tryCatch(player: Player, kind: Enums.JumpscareKind): boolean
	local model, m = creature, mover
	if not (model and m) or catching ~= nil or JumpscareHandler.IsBusy() or not I.canHuntNow() then
		return false
	end
	if ignored[player.UserId] or I.now() < stunUntil or warp then
		return false
	end
	if not JumpscareHandler.Catch(model, player, kind) then
		return false
	end
	catching = { player = player, kind = kind, at = I.now() }
	lastCatchAt = I.now()
	m:Stop()
	lookAway = nil
	I.setAction("Jumpscare")
	caught:Fire(player, kind)
	return true
end

-- The ReachIn: the action now, the Locker catch ReachInLead later (if it still may).
function I.reachIn(player: Player, spot: Instance)
	if pendingReach or catching then
		return
	end
	lookAway = nil
	I.setAction("ReachIn")
	pendingReach = { player = player, spot = spot, at = I.now() + I.H.ReachInLead }
end

function I.stepReach(t: number)
	local r = pendingReach
	if not r or t < r.at then
		return
	end
	pendingReach = nil
	-- never through a wall: nothing but the spot it reaches into stands between its chest and theirs
	local ok = I.playing(r.player) and I.bodyClear(r.player, r.spot) and I.tryCatch(r.player, "Locker")
	if not ok and action == "ReachIn" then
		I.setAction(nil)
	end
end

--------------------------------------------------------------------------------
-- States
--------------------------------------------------------------------------------

function I.enterState(nextState: Enums.MonsterState, t: number)
	local c, b = ctx, body
	local previous: Enums.MonsterState = state
	if not c or nextState == previous then
		return
	end
	current.exit(c, nextState)
	if Brain.isChase(nextState) and not Brain.isChase(previous) then
		chaseStarted = t
		chaseSeenAt = t
		if b and not b.hidden then
			AudioService.PlayAt(I.SPOT_PRESET, I.creatureEye(), { volume = I.SPOT_VOLUME })
		end
	elseif not Brain.isChase(nextState) then
		chaseStarted = nil
	end
	if action == "LookAway" or action == "ReachIn" then
		I.setAction(nil)
	end
	lookAway = nil
	state = nextState
	stateSince = t
	c.stateDone = false
	current = STATES[nextState] or I.PATROL
	current.enter(c, previous)
	I.publish()
	stateChanged:Fire(nextState, previous)
end

function I.bestSeen(): Player?
	local c = ctx
	local first = if c then c.sightings[1] else nil
	return if first then first.player else nil
end

function I.remember(player: Player, position: Vector3, t: number)
	local c = ctx
	if c and c.target == player then
		c.memory = { player = player, position = position, at = t }
	end
end

function I.chase(player: Player?, t: number)
	I.setTarget(player)
	local position = if player then I.rootOf(player) else nil
	if player and position then
		I.remember(player, position, t)
	end
	chaseSeenAt = t
end

-- Gets the hand-offs ready, then enters the decided state.
function I.transition(decision: Brain.Decision, t: number)
	local c, b = ctx, body
	if not (c and b) then
		return
	end
	lastReason = decision.reason
	if decision.reposition then
		c.reposition = true
	end
	local nextState: Enums.MonsterState = decision.state
	if nextState == state then
		local trigger = stareTrigger
		if nextState == "WallChase" and trigger and not (c.target and I.sees(c.target)) then
			I.chase(trigger, t)
		end
		return
	end
	if decision.giveUp then
		I.giveUp(t)
	end
	if nextState == "WallChase" then
		local target = c.target
		I.chase(stareTrigger or (if target and I.sees(target) then target else I.bestSeen()), t)
	elseif nextState == "AquaticStalk" then
		I.setTarget(swimmerPlayer)
	elseif nextState == "InvestigateNoise" then
		local heard = c.heard
		local memory = c.memory
		local position: Vector3
		local rank = I.EXACT_RANK
		local fromNoise = heard ~= nil and (decision.reason == "heard" or memory == nil)
		if fromNoise and heard then
			position, rank = heard.position, heard.rank
		elseif memory then
			position = memory.position
		else
			position = b:GetPosition()
		end
		c.investigation = { position = I.floorPointNear(position), rank = rank, at = t }
	elseif nextState == "Search" then
		local watched = c.hiding
		local memory = c.memory
		if memory then
			c.searchFrom = I.floorPointNear(memory.position)
		elseif watched then
			c.searchFrom = HidingResponse.standPoint(watched.front)
		else
			c.searchFrom = b:GetPosition()
		end
	elseif nextState == "HidingResponse" then
		local watch = hideWatch
		c.hiding = watch
		hideWatch = nil
		if watch then
			I.setTarget(watch.player)
			c.memory = { player = watch.player, position = watch.front.Position, at = t }
		end
	end
	I.enterState(nextState, t)
end

-- Who it looks at this tick: the chase's target (switching to whoever it can see when the target is out of sight), a
-- swimmer, or outside the chases whoever it sees best.
function I.updateTarget()
	local c = ctx
	if not c then
		return
	end
	local target = c.target
	if state == "WallChase" then
		if not (target and I.sees(target)) then
			local other = I.bestSeen()
			if other then
				I.setTarget(other)
			end
		end
	elseif state == "AquaticStalk" then
		local swimmer = swimmerPlayer
		if swimmer and target ~= swimmer and not (target and I.sees(target)) then
			I.setTarget(swimmer)
		end
	elseif state == "Patrol" or state == "InvestigateNoise" or state == "Search" then
		I.setTarget(I.bestSeen())
	elseif state ~= "HidingResponse" and state ~= "Teleport" then
		I.setTarget(nil)
	end
end

--------------------------------------------------------------------------------
-- Senses
--------------------------------------------------------------------------------

function I.playerByUserId(userId: number?): Player?
	if userId == nil then
		return nil
	end
	for _, participant in participants do
		if participant.UserId == userId then
			return participant
		end
	end
	return nil
end

function I.noteHeard(noise: Brain.HeardNoise, best: Brain.HeardNoise?, t: number): Brain.HeardNoise?
	local c = ctx
	if not c then
		return best
	end
	local zone = noise.zoneId
	if zone then
		c.heardZones[zone] = { at = t, rank = noise.rank, position = noise.position }
	end
	local source = I.playerByUserId(noise.sourceUserId)
	if source and I.huntable(source) then
		if noise.rank >= I.LOUD_RANK then
			I.recordOf(source).loudAt = t
		end
		if noise.medium == "Water" and I.swimmingPlayer(source) then
			swimmerAt = t
			swimmerPlayer = source
		end
		I.remember(source, noise.position, t)
	end
	if best == nil or noise.rank > best.rank or (noise.rank == best.rank and noise.strength > best.strength) then
		return noise
	end
	return best
end

-- `player` just got into a hiding spot: it saw them do it when it saw them within Hiding.SeenWindow.
function I.noteHid(player: Player, t: number)
	local c = ctx
	if not c or not awake or warp or catching or scripted or t < stunUntil then
		return
	end
	if state == "Dormant" or state == "Stunned" or state == "HidingResponse" then
		return
	end
	if not I.huntable(player) or not I.canHuntNow() then
		return
	end
	local seenAt = lastSeen[player]
	if seenAt == nil or t - seenAt > I.H.SeenWindow then
		return
	end
	local spot = I.hideSpotOf(player)
	local front = if spot then I.hideSpotFront(spot) else nil
	if not (spot and front) then
		return
	end
	hideWatch = { player = player, spot = spot, front = front, since = t }
end

-- Every player's trail, speed, life, hiding (the saw-you-hide rule) and stare.
function I.watchPlayers(t: number, dt: number)
	local c, b = ctx, body
	if not (c and b) then
		return
	end
	local shown = not b.hidden and I.fadeAt(t) >= 0.5
	local head = I.creatureEye()
	local canStare = shown
		and awake
		and state ~= "Dormant"
		and state ~= "Scripted"
		and state ~= "Stunned"
		and catching == nil
		and I.canHuntNow()
	if canStare then
		creatureLit = LightField.litAt(I.lightsFor(creatureLevel), head - Vector3.new(0, 2, 0), function(a, z)
			return I.lineClear(a, z)
		end)
	end
	for _, player in participants do
		local r = I.recordOf(player)
		local root = I.rootOf(player)
		local life: Enums.LifeState = I.lifeOf(player)
		if r.life ~= nil and r.life ~= "Downed" and life == "Downed" then
			lastDownAt = t
		end
		r.life = life
		if not root then
			r.stare = 0
			continue
		end
		-- speed and trail
		local last = r.last
		if last then
			local step = MathUtil.horizontalDistance(root, last)
			local span = math.max(1e-3, t - r.lastAt)
			local v = if step < 12 then step / span else 0
			r.speed += (v - r.speed) * math.clamp(dt * 6, 0, 1)
			if step > 0.05 and step < 12 then
				r.travel = Vector3.new(root.X - last.X, 0, root.Z - last.Z).Unit
			elseif r.speed < 0.5 then
				r.travel = nil
			end
		end
		r.last = root
		r.lastAt = t
		if t - r.trailAt >= I.TRAIL_EVERY then
			r.trailAt = t
			table.insert(r.trail, { t = t, p = root })
			while #r.trail > 0 and t - r.trail[1].t > I.TRAIL_SECONDS do
				table.remove(r.trail, 1)
			end
		end
		-- the saw-you-hide rule
		local hiding = I.moveStateOf(player) == "Hiding"
		if hiding and not r.hiding then
			I.noteHid(player, t)
		end
		r.hiding = hiding
		-- the stare
		if not canStare or hiding or not I.huntable(player) or I.inVent(player) or life ~= "Alive" then
			r.stare = 0
			continue
		end
		local eye = I.playerEye(player)
		local looker: Perception.Looker? = if eye
			then { eye = eye, look = I.lookOf(player), torch = FlashlightService.IsOn(player) }
			else nil
		if
			looker
			and Perception.staring(looker, head, creatureLit, function(a: Vector3, z: Vector3): boolean
				return I.lineClear(a, z)
			end)
		then
			r.stare += dt
			if r.stare >= CreatureConfig.Stare.Seconds and stareTrigger == nil then
				r.stare = 0
				stareTrigger = player
				lastSeenAny = t
				I.sendScare(player, "Stare")
				stared:Fire(player)
			end
		else
			r.stare = 0
		end
	end
end

function I.sense(t: number)
	local c, m, p, b = ctx, mover, pacing, body
	if not (c and m and p and b) then
		return
	end
	local blind = b.hidden or warp ~= nil or t < startleUntil
	local target = c.target
	local viewer: Perception.Viewer = {
		eye = I.creatureEye(),
		facing = lookAway or b:GetCFrame().LookVector,
		blindPeripheral = lookAway ~= nil,
		difficulty = difficulty,
		aquatic = b.pose == "Swim" or state == "AquaticStalk",
		targetUserId = if target then target.UserId else nil,
		raycast = function(a: Vector3, z: Vector3): boolean
			return I.lineClear(a, z)
		end,
	}
	local observations: { Perception.Observation } = {}
	if not blind then
		local fixtures = I.lightsFor(creatureLevel)
		for _, player in I.huntablePlayers() do
			local eye = I.playerEye(player)
			local root = I.rootOf(player)
			if not (eye and root) then
				continue
			end
			local life = I.lifeOf(player)
			table.insert(observations, {
				player = player,
				eye = eye,
				playing = life == "Alive" or life == "Downed",
				downed = life == "Downed",
				moveState = I.moveStateOf(player),
				torch = FlashlightService.IsOn(player),
				lit = LightField.litAt(fixtures, root + Vector3.new(0, 1, 0), function(a: Vector3, z: Vector3): boolean
					return I.lineClear(a, z)
				end),
				moving = I.recordOf(player).speed > I.SENSES.MovingSpeed,
				inVent = I.inVent(player),
			})
		end
	end
	local quiet = I.poolQuiet(t)
	local sightings: { Perception.Sighting } = {}
	for _, sighting in Perception.scan(viewer, observations) do
		if not (quiet and I.inPoolRoom(sighting.player)) then
			table.insert(sightings, sighting)
		end
	end
	c.sightings = sightings
	if #sightings > 0 then
		lastSeenAny = t
	end
	for _, sighting in sightings do
		local player = sighting.player
		lastSeen[player] = t
		if player == c.target then
			chaseSeenAt = t
		end
		local position = I.rootOf(player)
		if position then
			I.remember(player, position, t)
		end
		if c.level and #(c.level :: Brain.LevelInfo).basins > 0 and I.swimmingPlayer(player) then
			swimmerAt = t
			swimmerPlayer = player
		end
	end

	local graph = if creatureLevel then VentNetworkService.GetGraph(creatureLevel) else nil
	local listener: Hearing.Listener = {
		position = I.creatureEye(),
		levelId = creatureLevel,
		inVent = false,
		ventNode = nil,
		graph = graph,
		difficulty = difficulty,
		occluders = nil,
		grateOpen = nil,
		scale = p:HearingScale(),
	}
	local best: Brain.HeardNoise? = nil
	local events = noiseQueue
	noiseQueue = {}
	for _, event in events do
		local sourceId = event.sourceUserId
		if sourceId and ignored[sourceId] then
			continue
		end
		if quiet and (event.medium == "Water" or I.inPoolRoomAt(event.position)) then
			continue
		end
		local heard = Hearing.perceive(event, listener)
		if not heard then
			continue
		end
		local level = c.level
		local room = if level then Brain.roomAt(level, heard.position) else nil
		best = I.noteHeard({
			position = heard.position,
			rank = Hearing.priorityRank(event.priority),
			priority = event.priority,
			medium = event.medium,
			kind = event.kind,
			sourceUserId = sourceId,
			zoneId = if room then room.id else nil,
			strength = heard.strength,
			at = t,
		}, best, t)
	end
	local pending = alerts
	alerts = {}
	for _, alert in pending do
		if not (quiet and I.inPoolRoomAt(alert.position)) then
			best = I.noteHeard(alert, best, t)
		end
	end
	c.heard = best
	for zone, heard in c.heardZones do
		if t - heard.at > I.HEARD_ZONE_TTL then
			c.heardZones[zone] = nil
		end
	end
	for player, at in pulled do
		if t - at > I.PULL_MEMORY then
			pulled[player] = nil
		end
	end
end

function I.nearestPlayerDistance(): number?
	local b = body
	if not b then
		return nil
	end
	local here = b:GetPosition()
	local best: number? = nil
	for _, player in I.huntablePlayers() do
		local position = I.rootOf(player)
		if position then
			local distance = (position - here).Magnitude
			if best == nil or distance < (best :: number) then
				best = distance
			end
		end
	end
	return best
end

function I.summarize(t: number): Brain.Summary
	local c, m, p = ctx, mover, pacing
	assert(c and m and p, "summarize needs a Creature")
	local spec = Brain.difficultySpec(difficulty)
	local devHunt = t < devHuntUntil
	local seesAny = #c.sightings > 0
	-- the stalk after a teleport: sight alone starts no chase, only a stare or coming close
	if state == "Teleport" and Teleport.stalking(c) then
		seesAny = false
		for _, sighting in c.sightings do
			if sighting.distance <= I.T.StalkNear then
				seesAny = true
			end
		end
	end
	local chaseSeconds = if chaseStarted then t - (chaseStarted :: number) else 0
	local level = c.level
	local canHunt = devHunt or p:CanHunt(t)
	local investigation = c.investigation
	local heard = c.heard
	local summary: Brain.Summary = {
		state = state,
		elapsed = t - stateSince,
		scripted = scripted ~= nil,
		stunned = t < stunUntil,
		awake = awake,
		catching = catching ~= nil or grabbed ~= nil or pendingReach ~= nil,
		warping = warp ~= nil,
		canHunt = canHunt,
		sees = seesAny,
		stared = stareTrigger ~= nil,
		hidingWatch = hideWatch ~= nil,
		heard = if heard then heard.rank else 0,
		investigating = if investigation and state == "InvestigateNoise" then investigation.rank else 0,
		chaseSeconds = if devHunt then 0 else chaseSeconds,
		lostSeconds = if state == "WallChase" then t - chaseSeenAt else 0,
		maxChase = spec.maxChaseSeconds,
		chaseLost = spec.chaseLostSeconds,
		swimmer = level ~= nil and #level.basins > 0 and t - swimmerAt <= I.SWIMMER_MEMORY,
		inWater = m:Medium() == "Water",
		retreating = t < poolRetreatUntil,
		teleportDue = false,
		stateDone = c.stateDone,
	}
	if
		state == "Patrol"
		and canHunt
		and awake
		and not summary.sees
		and not summary.stared
		and not summary.hidingWatch
		and summary.heard == 0
		and not summary.swimmer
		and not summary.catching
		and not summary.warping
		and not summary.stunned
		and not summary.scripted
	then
		summary.teleportDue = I.teleportDue(t)
	end
	return summary
end

--------------------------------------------------------------------------------
-- Upkeep
--------------------------------------------------------------------------------

function I.updateGrab(t: number)
	local victim = grabbed
	local c, p = ctx, pacing
	if not (victim and c and p) then
		return
	end
	local holding = victim.Parent == Players and I.moveStateOf(victim) == "Grabbed"
	if holding then
		grabbedHeldAt = t
	end
	if
		victim.Parent ~= Players
		or not LifeStateService.IsPlaying(victim)
		or (not holding and t - grabbedHeldAt > I.GRAB_GRACE)
	then
		grabbed = nil
		p:NoteCatch(t)
		lastCatchAt = t
		c.reposition = true
		-- Level 4 fairness: off to the far end of the water for a while, and that swimmer's splashing starts over
		poolRetreatUntil = t + I.WATER.GrabRetreatSeconds
		splashArmed[victim] = nil
		AquaticStalk.released(c)
	end
end

-- A mover that stalled for good is moved unseen to a standing spot and the state starts over from there; while
-- someone watches it, it keeps trying where it stands.
function I.handleMover()
	local m, c = mover, ctx
	if not (m and c) or m:Status() ~= "Stuck" then
		return
	end
	if I.relocateUnseen() then
		current.enter(c, state)
	else
		m:Reset(m:Medium())
	end
end

function I.settleCatch(outcome: string)
	local c, b, m, p = ctx, body, mover, pacing
	local active = catching
	catching = nil
	if action == "Jumpscare" or action == "ReachIn" then
		I.setAction(nil)
	end
	if not (c and b and m and p and active) then
		return
	end
	-- the handler moved and re-anchored the root: take the body and the movement from where it really is
	b.anchored = b.root.Anchored
	b:Reassert()
	m:Reset(m:Medium())
	local t = I.now()
	if outcome ~= "Aborted" then
		p:NoteCatch(t)
		lastCatchAt = t
	end
	-- a dev hunt ends with its catch: the cooldown applies like any other
	devHuntUntil = 0
	c.reposition = true
	if c.target == active.player then
		I.setTarget(nil)
		c.memory = nil
	end
end

function I.onCatchFinished(victim: Player, _kind: Enums.JumpscareKind, outcome: string)
	local active = catching
	if active and active.player == victim then
		I.settleCatch(outcome)
	end
end

-- Ends the spawn rule's grace early (see the header): someone close, or someone who can see its head.
function I.updateSpawnGrace(t: number)
	local b = body
	if graceLevel == nil or awake or not b or creatureLevel ~= graceLevel then
		return
	end
	local here = b:GetPosition()
	local head = I.creatureEye()
	for _, player in I.huntablePlayers() do
		local root = I.rootOf(player)
		if root and (root - here).Magnitude <= I.SPAWN.ReleaseNear then
			wakeAt = t
			lastReason = "grace: someone came close"
			return
		end
		local eye = I.playerEye(player)
		if not b.hidden and eye and (eye - head).Magnitude <= I.SPAWN.ReleaseSight and I.lineClear(eye, head) then
			wakeAt = t
			lastReason = "grace: seen"
			return
		end
	end
end

--------------------------------------------------------------------------------
-- Brain tick + motion
--------------------------------------------------------------------------------

-- One brain tick (the Heartbeat driver runs it at ServerTickHz during InRun; specs call it directly).
function MonsterAIService.Step(dt: number)
	local c, b, m, p, model = ctx, body, mover, pacing, creature
	if not (running and c and b and m and p and model) then
		return
	end
	local t = I.now()
	if paused then
		noiseQueue = {}
		alerts = {}
		I.publish()
		return
	end
	local active = catching
	if active and t - active.at > I.CATCH_TIMEOUT then
		if not JumpscareHandler.Abort("Timeout") then
			I.settleCatch("Aborted")
		end
	end
	I.stepReach(t)
	I.updateGrab(t)
	if scripted then
		noiseQueue = {}
		alerts = {}
		I.publish()
		return
	end
	I.updatePoolGrace(t)
	I.updateSpawnGrace(t)
	m:SetWaterSpeedCap(c.speedOf("AquaticStalk"))
	I.watchPlayers(t, dt)
	I.sense(t)
	-- leaving the water, not yet gone: a swimmer turns it back (the warp is called off where it still is)
	local w = warp
	if w and w.kind == "Pool" and not w.placed and m:Medium() == "Water" and t - swimmerAt <= I.SWIMMER_MEMORY then
		I.cancelWarp()
		b:SetHidden(false)
		m:Reset("Water")
	end
	local target = c.target
	c.phase = p:Tick(dt, {
		chasing = Brain.isChase(state),
		seesTarget = target ~= nil and I.sees(target),
		nearestPlayerDistance = I.nearestPlayerDistance(),
	})
	local wake = wakeAt
	if not awake and wake and t >= wake then
		awake = true
		wakeAt = nil
		graceLevel = nil
	end
	local summary = I.summarize(t)
	c.canHunt = summary.canHunt
	I.transition(Brain.decide(summary), t)
	I.updateTarget()
	stareTrigger = nil
	local watch = hideWatch
	if watch and state ~= "HidingResponse" and t - watch.since > I.H.SeenWindow then
		hideWatch = nil
	end
	if catching == nil and pendingReach == nil and warp == nil then
		I.handleMover()
		current.update(c, dt)
	end
	I.publish()
end

-- The head room it walks under (the contract's poseMode, and its eye: Hunched below HunchBelow): the lowest nav
-- clearance at its root and along the way it walks, HEAD_LEAD + its pace x HUNCH_LEAD_SECONDS ahead, so it is down
-- before its head reaches a lintel or a tunnel's ceiling. math.huge off the floor.
I.headroom = function(root: Vector3): number
	local m, b = mover, body
	local nav = if m and m:Medium() == "Floor" then I.navFor(creatureLevel) else nil
	if not (nav and m and b) then
		return math.huge
	end
	local c = nav:clearanceAt(root)
	local walker = b.humanoid
	local pace = if walker then math.max(0, walker.WalkSpeed) else 0
	local left = I.HEAD_LEAD + pace * I.HUNCH_LEAD_SECONDS
	local from = root
	for _, to in m:RouteAhead() do
		local leg = MathUtil.horizontalDistance(from, to)
		local span = math.min(leg, left)
		local s = I.HEADROOM_STEP
		while leg > 0 and s < span + I.HEADROOM_STEP do
			local k = math.min(s, span) / leg
			c = math.min(
				c,
				nav:clearanceAt(Vector3.new(from.X + (to.X - from.X) * k, from.Y, from.Z + (to.Z - from.Z) * k))
			)
			s += I.HEADROOM_STEP
		end
		left -= leg
		if left <= 0 then
			break
		end
		from = to
	end
	return c
end

-- One movement step (every Heartbeat during InRun; specs call it directly). Nothing moves while a catch runs.
function MonsterAIService.StepMotion(dt: number)
	local m, b = mover, body
	if not (running and m and b) or paused then
		return
	end
	local t = I.now()
	if catching == nil and scripted == nil then
		I.stepWarp(t)
	end
	-- it stands still while it fades out, is gone, or forms (a warp), and while a catch plays
	if catching == nil and warp == nil then
		m:Step(dt)
	end
	-- the contract's speed (a placement reads as still) and the head room (Hunched under a low lintel)
	local root = b:GetPosition()
	local last = lastRoot
	if last and placements == lastPlacements and dt > 0 then
		local v = MathUtil.horizontalDistance(root, last) / dt
		speedMeasured += (v - speedMeasured) * math.clamp(dt * I.SPEED_DAMP, 0, 1)
	else
		speedMeasured = 0
	end
	if speedMeasured < 0.05 then
		speedMeasured = 0
	end
	lastRoot = root
	lastPlacements = placements
	clearance = I.headroom(root)
	I.publishMotion(t)
end

--------------------------------------------------------------------------------
-- Context
--------------------------------------------------------------------------------

-- Which points it can walk to from where it stands now (through the portals open now; a point in a pool counts, it
-- gets in by a warp): a test, or nil off the floor.
function I.reachableTest(): ((point: Vector3) -> boolean)?
	local m, b = mover, body
	local nav = if m and m:Medium() == "Floor" then I.navFor(creatureLevel) else nil
	if not (nav and m and b) then
		return nil
	end
	local walk = nav:reachable(b:GetPosition())
	local mm = m :: Locomotion.Mover
	return function(point: Vector3): boolean
		return mm:BasinAt(point) ~= nil or walk(point)
	end
end

-- Down the tunnel, away from the spot it watches: the more open of its two sides (a level-headed look).
function I.lookAwayDirection(front: CFrame): Vector3
	local look = front.LookVector
	local facing = Vector3.new(-look.X, 0, -look.Z)
	facing = if facing.Magnitude < 1e-6 then Vector3.new(0, 0, -1) else facing.Unit
	local left = Vector3.new(-facing.Z, 0, facing.X)
	local right = -left
	local eye = I.creatureEye()
	local function reach(dir: Vector3): number
		local d = 0
		for _, step in LOOKAWAY_PROBES do
			if not I.lineClear(eye, eye + dir * step) then
				break
			end
			d = step
		end
		return d
	end
	local side = if reach(left) >= reach(right) then left else right
	return (side - facing * 0.35).Unit
end

function I.newContext(model: Model, b: CreatureBody.Body, m: Locomotion.Mover): Brain.Context
	return {
		creature = model,
		body = b,
		mover = m,
		level = nil,
		difficulty = difficulty,
		random = MathUtil.seededRandom(20251029, "MonsterAI|" .. tostring(runSeed)),
		now = I.now,
		sightings = {},
		heard = nil,
		heardZones = {},
		target = nil,
		memory = nil,
		phase = "BuildUp",
		canHunt = false,
		investigation = nil,
		searchFrom = nil,
		hiding = nil,
		teleportPlan = nil,
		reposition = false,
		stateDone = false,
		stunFrom = nil,
		speedOf = function(name: Enums.MonsterState): number
			local base = Brain.speedFor(name, difficulty)
			return if name == "Scripted" then base else math.min(CreatureConfig.SpeedCap, base * speedScale)
		end,
		setTarget = I.setTarget,
		catchKind = I.catchKindFor,
		tryCatch = I.tryCatch,
		reachIn = I.reachIn,
		visible = I.visible,
		reachable = I.reachableTest,
		repositionPoint = function(minDistance: number, maxDistance: number): Vector3?
			local c = ctx
			local info = c and c.level
			if not info then
				return nil
			end
			return PacingDirector.repositionPoint(
				I.standingSpots(info),
				I.playerEyes(),
				b:GetPosition(),
				minDistance,
				maxDistance,
				I.visible
			)
		end,
		playerPositions = I.playerEyes,
		lockerInspector = function(): Types.LockerInspector?
			return lockerInspector
		end,
		poolGrabber = function(): Types.PoolGrabber?
			return poolGrabber
		end,
		grabArmed = function(player: Player): boolean
			local at = splashArmed[player]
			return at ~= nil and I.now() - at <= I.GRAB_ARMED_SECONDS and not I.poolQuiet(I.now())
		end,
		setGrabbed = function(player: Player?)
			grabbed = player
			grabbedHeldAt = I.now()
			I.publish()
		end,
		inVent = I.inVent,
		swimming = I.swimmingPlayer,
		playing = I.huntable,
		isHiding = function(player: Player): boolean
			return I.moveStateOf(player) == "Hiding"
		end,
		hideSpotOf = I.hideSpotOf,
		hideSpotsNear = I.hideSpotsNear,
		hideSpotOccupant = I.hideSpotOccupant,
		hideSpotFront = I.hideSpotFront,
		pulledOut = function(player: Player): boolean
			return pulled[player] ~= nil
		end,
		bodyClear = function(player: Player): boolean
			return I.bodyClear(player, nil)
		end,
		telegraph = I.telegraph,
		poolRetreat = I.poolRetreatPoint,
		rootOf = I.rootOf,
		floorPointNear = I.floorPointNear,
		lineClear = function(from: Vector3, to: Vector3): boolean
			return I.lineClear(from, to)
		end,
		setLookAway = function(direction: Vector3?)
			lookAway = direction
			if direction then
				I.setAction("LookAway")
			elseif action == "LookAway" then
				I.setAction(nil)
			end
		end,
		lookAwayDirection = I.lookAwayDirection,
		grunt = function()
			local at = I.creatureEye()
			AudioService.PlayAt(I.GRUNT_PRESET, at, { volume = 1 })
			grunted:Fire(at)
		end,
		startTeleport = I.startTeleport,
		warping = function(): boolean
			return warp ~= nil
		end,
		creatureEye = I.creatureEye,
	}
end

function I.navPath(from: Vector3, to: Vector3): Locomotion.ComputedPath?
	local nav = I.navFor(creatureLevel)
	return if nav then nav:computePath(from, to) else nil
end

function I.detach()
	local m, b = mover, body
	if m then
		m:Destroy()
	end
	if b then
		b:Destroy()
	end
	mover = nil
	body = nil
	ctx = nil
	creature = nil
	creatureLevel = nil
end

-- Takes over `model` as the run's Creature (BeginRun hands it WorldService's; specs and tools hand their own; nil
-- lets go). It is placed at its level's CreatureSpawn and waits Dormant for its level to activate.
function MonsterAIService.Attach(model: Model?)
	I.detach()
	if not model then
		return
	end
	local b = CreatureBody.attach(model)
	if not b then
		return
	end
	local engine = customEngine or Locomotion.defaultEngine(I.navPath)
	local m = Locomotion.new(b, engine, {
		warp = I.warpForMover,
		warping = function(): boolean
			return warp ~= nil
		end,
	}, I.now)
	creature = model
	body = b
	mover = m
	local c = I.newContext(model, b, m)
	ctx = c
	local fallback: Enums.LevelId = LevelDirector.GetCurrentLevel() or Enums.LevelId[1]
	local levelId = Attributes.getEnum(model, I.C.LevelId, Enums.LevelId, fallback)
	state = "Dormant"
	current = I.DORMANT
	stateSince = I.now()
	lastReason = "placed"
	awake = false
	wakeAt = nil
	warp = nil
	action = nil
	b:SetHidden(false)
	I.relocate(levelId :: Enums.LevelId, false)
	Dormant.enter(c, "Dormant")
	I.publish()
end

--------------------------------------------------------------------------------
-- Levels
--------------------------------------------------------------------------------

-- The spawn rule's pick on `levelId` this run (a root CFrame at the anchor, facing the entry room), or nil.
function I.spawnFor(levelId: Enums.LevelId): CFrame?
	local layout = Builder.getLayout(levelId)
	if not layout then
		return nil
	end
	local plan = NoiseAndDirectorService.GetPlan()
	local picks = if plan and plan.objectives then plan.objectives[levelId] else nil
	local entry = LevelDirector.entryFor(levelId)
	local entryRoom = if entry then entry.toRoom else layout.entry
	local choice = SpawnRule.choose(runSeed, layout, picks, entryRoom)
	local candidate = choice.candidate
	if not candidate then
		log.warn("%s: no Creature spawn candidate at all; it starts at the CreatureSpawn", levelId)
		return nil
	end
	if choice.fallback then
		log.warn(
			"%s: no Creature spawn in the %d-%d band out of sight of the entry; using %s (%d studs)",
			levelId,
			I.SPAWN.MinDistance,
			I.SPAWN.MaxDistance,
			candidate.id,
			math.floor(candidate.walk)
		)
	else
		log.info("%s: the Creature starts at %s (%d studs walked)", levelId, candidate.id, math.floor(candidate.walk))
	end
	local origin = WorldConfig.levelOrigin(levelId)
	local position = origin + candidate.pos + Vector3.new(0, CreatureBody.RootHeight, 0)
	local entryRect = LayoutSchema.indexRooms(layout)[entryRoom]
	local toward = position + Vector3.new(0, 0, -1)
	if entryRect then
		local centre = LayoutSchema.rectCenter(entryRect.rect)
		toward = origin + Vector3.new(centre.X, candidate.pos.Y, centre.Y)
	end
	if MathUtil.horizontalDistance(toward, position) < 0.1 then
		toward = position + Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(position, Vector3.new(toward.X, position.Y, toward.Z))
end

function I.onLevelActivated(levelId: Enums.LevelId)
	local p, c = pacing, ctx
	if not (running and p and c) then
		return
	end
	local t = I.now()
	p:NoteAirlock(t)
	if catching then
		JumpscareHandler.Abort("Level")
	end
	stunUntil = 0
	grabbed = nil
	pendingReach = nil
	if creatureLevel ~= levelId then
		I.relocate(levelId, true)
	else
		I.forgetMind()
	end
	awake = false
	wakeAt = t + I.WAKE_DELAY
	graceLevel = nil
	poolEnteredAt = nil
	poolRetreatUntil = -math.huge
	lastSeenAny = t
	teleportReadyAt = t
		+ (CreatureConfig.FloorGrace[difficulty] or CreatureConfig.FloorGrace.Standard)
		+ I.T.FirstAfterGrace
	nextTeleportTry = 0
	lastReason = "level " .. levelId .. " activated"
	if SpawnRule.handles(levelId) and not scripted then
		local spawn = I.spawnFor(levelId)
		if spawn then
			I.cancelWarp()
			I.placeBody(spawn)
			I.hide()
			wakeAt = t + ObjectiveConfig.graceFor(difficulty)
			graceLevel = levelId
		end
	end
	if not scripted then
		I.enterState("Dormant", t)
	end
	I.publish()
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function MonsterAIService.GetState(): Enums.MonsterState
	return state
end

function MonsterAIService.GetTarget(): Player?
	local c = ctx
	return if c then c.target else nil
end

-- The view contract's action now (nil for none).
function MonsterAIService.GetAction(): Enums.CreatureAction?
	return action
end

-- What the brain is doing (dev, specs).
function MonsterAIService.GetSnapshot(): Snapshot
	local b = body
	local w = warp
	return {
		state = state,
		reason = lastReason,
		awake = awake,
		warp = if w then w.kind .. "/" .. w.phase else nil,
		action = action,
		fade = I.fadeAt(I.now()),
		poseMode = I.poseMode(),
		teleports = teleports,
		teleportReadyAt = teleportReadyAt,
		lastSeenAny = lastSeenAny,
		levelId = creatureLevel,
		position = if b then b:GetPosition() else nil,
	}
end

function I.applyStun(seconds: number, from: Vector3)
	local c = ctx
	if not c then
		return
	end
	local t = I.now()
	stunUntil = math.max(stunUntil, t + math.max(0, seconds))
	c.stunFrom = from
	I.setTarget(nil)
	pendingReach = nil
	lookAway = nil
	if action == "LookAway" or action == "ReachIn" then
		I.setAction(nil)
	end
	AudioService.PlayAt(I.STUN_PRESET, I.creatureEye())
	if state == "Stunned" then
		Stunned.retreat(c)
	else
		I.enterState("Stunned", t)
	end
	I.publish()
end

-- Flasks: blinded for `seconds`, stumbling back away from `from`. A catch in progress is called off; a cutscene, a
-- sleeping or a hidden Creature is not stunned.
function MonsterAIService.Stun(seconds: number, from: Vector3)
	local b = body
	if not (running and ctx and b) or scripted or not awake or b.hidden then
		return
	end
	if not (MathUtil.isFinite(seconds) and MathUtil.isFiniteVector(from)) then
		return
	end
	if catching then
		JumpscareHandler.Abort("Stunned")
		if catching then
			I.settleCatch("Aborted")
		end
	end
	I.cancelWarp()
	I.applyStun(seconds, from)
end

-- Scripted alerts: heard on the next tick like a noise of `priority` at `position` (no falloff, no walls).
function MonsterAIService.Alert(position: Vector3, priority: Enums.NoisePriority)
	if not running or not MathUtil.isFiniteVector(position) or not Enums.has(Enums.NoisePriority, priority) then
		return
	end
	local c = ctx
	local level = c and c.level
	local room = if level then Brain.roomAt(level, position) else nil
	table.insert(alerts, {
		position = position,
		rank = Hearing.priorityRank(priority),
		priority = priority,
		medium = "Air",
		kind = "Scripted",
		sourceUserId = nil,
		zoneId = if room then room.id else nil,
		strength = 1,
		at = I.now(),
	})
end

function I.nearestPlayerTo(position: Vector3, predicate: ((Player) -> boolean)?): Player?
	local best: Player? = nil
	local bestDistance = math.huge
	for _, player in I.huntablePlayers() do
		local root = I.rootOf(player)
		if root and (predicate == nil or predicate(player)) and (root - position).Magnitude < bestDistance then
			best, bestDistance = player, (root - position).Magnitude
		end
	end
	return best
end

function I.releaseScripted(nextState: Enums.MonsterState?)
	local c, b = ctx, body
	scripted = nil
	if not (c and b) then
		return
	end
	b:Face(nil)
	if b.hidden then
		I.hide()
	end
	local t = I.now()
	local wanted: Enums.MonsterState = if nextState
			and Enums.has(Enums.MonsterState, nextState)
			and nextState ~= "Scripted"
		then nextState
		else "Patrol"
	if wanted == "Search" or wanted == "HidingResponse" or wanted == "Teleport" then
		wanted = "Patrol"
	end
	awake = wanted ~= "Dormant"
	wakeAt = nil
	local here = b:GetPosition()
	if wanted == "WallChase" then
		local victim = I.nearestPlayerTo(here, function(player: Player): boolean
			return not I.inVent(player)
		end)
		if victim then
			I.chase(victim, t)
		else
			wanted = "Patrol"
		end
	elseif wanted == "InvestigateNoise" then
		local near = I.nearestPlayerTo(here, nil)
		local position = if near then I.rootOf(near) else nil
		c.investigation = { position = I.floorPointNear(position or here), rank = I.EXACT_RANK, at = t }
	elseif wanted == "AquaticStalk" then
		if swimmerPlayer == nil then
			wanted = "Patrol"
		end
	elseif wanted == "Stunned" then
		stunUntil = math.max(stunUntil, t + GameConfig.StunSeconds)
		c.stunFrom = here + b:GetCFrame().LookVector
	end
	lastReason = "released"
	I.enterState(wanted, t)
	I.publish()
end

function I.makeHandle(token: string): ScriptedHandle
	local function live(): boolean
		local hold = scripted
		return running and hold ~= nil and hold.token == token and ctx ~= nil
	end
	local handle: ScriptedHandle
	handle = {
		MoveTo = function(_self: ScriptedHandle, position: Vector3, speed: number?)
			local m, b = mover, body
			if not (live() and m and b) or not MathUtil.isFiniteVector(position) then
				return
			end
			local pace = if speed
					and MathUtil.isFinite(speed)
					and speed > 0
				then speed
				else Brain.speedFor("Scripted", difficulty)
			m:SetSpeed(pace)
			b:SetWalkSpeed(pace)
			m:GoTo(position, { arrive = 1 })
		end,
		Teleport = function(_self: ScriptedHandle, cframe: CFrame)
			if not live() or not MathUtil.isFiniteVector(cframe.Position) then
				return
			end
			I.placeBody(cframe)
			I.publish()
		end,
		SetPose = function(_self: ScriptedHandle, pose: Enums.PoseMode)
			local b = body
			if not (live() and b) or not Enums.has(Enums.PoseMode, pose) then
				return
			end
			b:SetPose(pose)
			I.publish()
		end,
		SetHidden = function(_self: ScriptedHandle, hidden: boolean)
			local b = body
			if not (live() and b) then
				return
			end
			I.cancelWarp()
			b:SetHidden(hidden == true)
			I.publish()
		end,
		Face = function(_self: ScriptedHandle, position: Vector3)
			local m, b = mover, body
			if not (live() and m and b) or not MathUtil.isFiniteVector(position) then
				return
			end
			m:Face(position - b:GetPosition())
		end,
		Release = function(_self: ScriptedHandle, nextState: Enums.MonsterState?)
			if not live() then
				return
			end
			I.releaseScripted(nextState)
		end,
	}
	return handle
end

-- Exclusive control for a cutscene. Nil while another token holds it, during a catch, or without a Creature; the
-- same token gets its handle back. A warp in progress is called off (the script places the Creature itself).
function MonsterAIService.AcquireScripted(token: string): ScriptedHandle?
	if not (running and ctx) or type(token) ~= "string" or token == "" then
		return nil
	end
	local hold = scripted
	if hold then
		return if hold.token == token then hold.handle else nil
	end
	if catching then
		return nil
	end
	local handle = I.makeHandle(token)
	scripted = { token = token, handle = handle }
	pendingReach = nil
	lookAway = nil
	local b = body
	local wasHidden = warp ~= nil and b ~= nil and b.hidden
	I.cancelWarp()
	if b and wasHidden then
		b:SetHidden(true)
	end
	I.setAction(nil)
	lastReason = "acquired by " .. token
	I.enterState("Scripted", I.now())
	return handle
end

-- While the cutscene `token` holds the Creature, turns its stare on `player` (TargetUserId, which every client's head
-- look follows); nil clears it. False, with nothing changed, when `token` does not hold the Creature or `player` is not
-- one of the run's participants.
function MonsterAIService.SetScriptedTarget(token: string, player: Player?): boolean
	local hold = scripted
	if not (running and ctx and hold and hold.token == token) then
		return false
	end
	if player ~= nil and table.find(participants, player) == nil then
		return false
	end
	I.setTarget(player)
	I.publish()
	return true
end

-- Level tuning (Level 3's gym): every state's pace times `scale` (clamped MIN_SPEED_SCALE..MAX_SPEED_SCALE, never past
-- SpeedCap; 1, the default, is as configured; EndRun restores it). A pace already set follows at once.
function MonsterAIService.SetSpeedScale(scale: number)
	local value = if MathUtil.isFinite(scale) then math.clamp(scale, I.MIN_SPEED_SCALE, I.MAX_SPEED_SCALE) else 1
	local previous = speedScale
	if math.abs(value - previous) < 1e-6 then
		return
	end
	speedScale = value
	local m, b = mover, body
	local walker = if b then b.humanoid else nil
	if m and b and walker and scripted == nil and catching == nil and state ~= "Scripted" then
		local pace = math.min(CreatureConfig.SpeedCap, walker.WalkSpeed * value / previous)
		m:SetSpeed(pace)
		b:SetWalkSpeed(pace)
	end
end

function MonsterAIService.GetSpeedScale(): number
	return speedScale
end

function MonsterAIService.RegisterLockerInspector(fn: Types.LockerInspector)
	lockerInspector = fn
end

function MonsterAIService.RegisterPoolGrabber(fn: Types.PoolGrabber)
	poolGrabber = fn
end

-- HideSpotService: the hiding spots of a level, and who is in which.
function MonsterAIService.RegisterHideSpots(provider: HideSpots?)
	hideSpots = provider
end

-- The game forbids a teleport while `fn` returns true (an objective's survive countdown, the roof's finale chase).
-- Returns a function that removes it.
function MonsterAIService.RegisterTeleportBlock(fn: () -> boolean): () -> ()
	table.insert(teleportBlocks, fn)
	return function()
		local index = table.find(teleportBlocks, fn)
		if index then
			table.remove(teleportBlocks, index)
		end
	end
end

-- A teammate pulled `player` out of their hiding spot (THRESHOLD's throw): no catch for it; when it was watching them,
-- it is startled (blind) for Hiding.PullStartle.
function MonsterAIService.NotePulled(player: Player)
	local c = ctx
	if not running or not c then
		return
	end
	local t = I.now()
	pulled[player] = t
	local watch = c.hiding
	if state == "HidingResponse" and watch and watch.player == player then
		startleUntil = t + I.H.PullStartle
	end
end

-- A reveal scare for `player` alone (a fake-out's, `kind` "Fakeout"): the PrivateCue only, no catch.
function MonsterAIService.Reveal(player: Player, kind: string)
	I.sendScare(player, if kind == "Fakeout" then "Fakeout" else "Reveal", "kind", kind)
	revealed:Fire(player, kind)
end

-- The swimmer the Creature is holding (the PoolGrabber's grab) ran out of air: the Underwater jumpscare instead of
-- drowning. False, with nothing changed, when `player` is not the one held, a catch is running, or the Creature is
-- stunned, hidden or out of reach (JumpscareHandler.Catch refuses).
function MonsterAIService.CatchGrabbed(player: Player): boolean
	local model, m, c = creature, mover, ctx
	if not (running and model and m and c) or grabbed ~= player then
		return false
	end
	if catching ~= nil or JumpscareHandler.IsBusy() or I.now() < stunUntil then
		return false
	end
	if not JumpscareHandler.Catch(model, player, "Underwater") then
		return false
	end
	grabbed = nil
	AquaticStalk.released(c)
	catching = { player = player, kind = "Underwater", at = I.now() }
	lastCatchAt = I.now()
	I.setAction("Jumpscare")
	m:Stop()
	I.publish()
	caught:Fire(player, "Underwater")
	return true
end

-- Replaces the server-time source (specs pass a fake clock; nil restores GetServerTimeNow).
function MonsterAIService.SetClock(fake: Clock?)
	clock = fake or function(): number
		return Workspace:GetServerTimeNow()
	end
end

-- Replaces Locomotion's engine for Creatures attached from now on (specs; nil restores the real one: FloorNav routes).
function MonsterAIService.SetEngine(fake: Locomotion.Engine?)
	customEngine = fake
end

-- Replaces the sight-line test (specs: walls in Lune, where every ray is clear; nil restores the raycasts).
function MonsterAIService.SetLineClear(fake: ((from: Vector3, to: Vector3, ignore: Instance?) -> boolean)?)
	I.customLineClear = fake
end

-- Replaces the fixtures "lit" reads, per level (specs; nil restores the world's).
function MonsterAIService.SetLights(fake: { [string]: { LightField.Fixture } }?)
	customLights = fake
	table.clear(lights)
end

-- The level's floor nav (specs and tools).
function MonsterAIService.GetNav(levelId: string): FloorNav.Nav?
	return I.navFor(levelId)
end

-- Pauses (true) or resumes the brain; a paused Creature stands where it is.
function MonsterAIService.SetPaused(value: boolean)
	paused = value
	local m = mover
	if value and m then
		m:Stop()
	end
end

function MonsterAIService.IsPaused(): boolean
	return paused
end

-- The Creature model this service drives (nil without one).
function MonsterAIService.GetCreature(): Model?
	return creature
end

--------------------------------------------------------------------------------
-- Dev commands
--------------------------------------------------------------------------------

function I.stateNamed(text: string): Enums.MonsterState?
	local wanted = string.lower(text)
	for _, name: Enums.MonsterState in Enums.MonsterState do
		if string.lower(name) == wanted then
			return name
		end
	end
	return nil
end

function I.describe(): string
	local c, b, m, p = ctx, body, mover, pacing
	if not (c and b and m and p) then
		return "no Creature this run"
	end
	local snapshot = p:Snapshot()
	local target = c.target
	local t = I.now()
	local w = warp
	return string.format(
		"%s for %.1fs (%s) | target %s | pose %s | %s%s%s | %s | next teleport in %.0fs | pacing %s, tension %.2f%s%s%s",
		state,
		t - stateSince,
		lastReason,
		if target then target.Name else "none",
		I.poseMode(),
		m:Medium(),
		if b.hidden then ", hidden" else "",
		if w then ", warp " .. w.kind .. "/" .. w.phase else "",
		tostring(creatureLevel),
		math.max(0, teleportReadyAt - t),
		snapshot.phase,
		snapshot.tension,
		if t < snapshot.cooldownUntil then string.format(", cooldown %.0fs", snapshot.cooldownUntil - t) else "",
		if t < snapshot.graceUntil then string.format(", grace %.0fs", snapshot.graceUntil - t) else "",
		if paused then " | PAUSED" elseif not awake then " | asleep" else ""
	)
end

function I.callerLevel(player: Player): Enums.LevelId?
	local fromZone = player:GetAttribute(I.P.LevelId)
	if type(fromZone) == "string" and Enums.has(Enums.LevelId, fromZone) then
		return fromZone :: Enums.LevelId
	end
	return LevelDirector.GetCurrentLevel()
end

function I.wakeForDev()
	local b = body
	awake = true
	wakeAt = nil
	local w = warp
	if w and w.kind == "Reveal" then
		I.cancelWarp()
		if b then
			b:SetHidden(false)
		end
	end
end

function I.bringNear(player: Player): string
	local c, b = ctx, body
	local root = I.rootOf(player)
	local eye = I.playerEye(player)
	local levelId = I.callerLevel(player)
	if not (c and b and root and eye and levelId) then
		return "you need a character on a school level"
	end
	if creatureLevel ~= levelId then
		I.setLevel(levelId :: Enums.LevelId)
		I.forgetMind()
	end
	local info = c.level
	if not info then
		return "no layout for " .. levelId
	end
	I.cancelWarp()
	local spots = I.standingSpots(info)
	local point = PacingDirector.repositionPoint(spots, { eye }, root, I.TP_MIN, I.TP_MAX, I.visible)
	local note = ""
	if not point then
		local best, bestDistance = nil :: Vector3?, math.huge
		for _, spot in spots do
			local distance = (spot - root).Magnitude
			if distance >= I.TP_MIN and distance < bestDistance then
				best, bestDistance = spot, distance
			end
		end
		point = best
		note = " (no hidden spot in range: in sight)"
	end
	if not point then
		return "no spot on " .. levelId .. " to bring it to"
	end
	local spot = point :: Vector3
	local facing = CreatureBody.flatDirection(root - spot) or Vector3.new(0, 0, -1)
	I.placeBody(CFrame.lookAt(spot, spot + facing))
	I.wakeForDev()
	lastReason = "ai tp"
	I.enterState("Patrol", I.now())
	I.publish()
	return string.format("Creature brought %.0f studs from you on %s%s", (spot - root).Magnitude, levelId, note)
end

function I.force(player: Player, wanted: Enums.MonsterState): string
	local c, b = ctx, body
	if not (c and b) then
		return "no Creature this run"
	end
	if scripted then
		return "a cutscene holds the Creature"
	end
	local t = I.now()
	local root = I.rootOf(player)
	if wanted == "Scripted" then
		return "Scripted is entered through AcquireScripted (cutscenes)"
	end
	if wanted == "Dormant" then
		awake = false
		wakeAt = nil
		lastReason = "ai Dormant"
		I.enterState("Dormant", t)
		return "Creature asleep (ai Patrol wakes it)"
	end
	if wanted == "Stunned" then
		I.wakeForDev()
		if not root then
			return "you need a character"
		end
		MonsterAIService.Stun(GameConfig.StunSeconds, root)
		return string.format("Creature stunned for %ds", GameConfig.StunSeconds)
	end
	I.wakeForDev()
	local levelId = I.callerLevel(player)
	local away = levelId ~= nil and levelId ~= creatureLevel
	local where = if away then " (it is on " .. tostring(creatureLevel) .. "; ai tp brings it)" else ""
	if wanted == "Patrol" then
		devHuntUntil = 0
		lastReason = "ai Patrol"
		I.enterState("Patrol", t)
		return "Creature patrolling" .. where
	end
	if wanted == "Teleport" then
		if state ~= "Patrol" then
			I.enterState("Patrol", t)
		end
		local plan = I.planTeleport()
		if not plan then
			return "no teleport spot near anyone right now"
		end
		c.teleportPlan = plan
		lastReason = "ai Teleport"
		I.enterState("Teleport", t)
		return string.format(
			"Creature teleporting %s %s (%.0f studs of walking)",
			plan.side,
			plan.target.Name,
			plan.walk
		)
	end
	if not root then
		return "you need a character"
	end
	devHuntUntil = t + I.DEV_FORCE_SECONDS
	lastReason = "ai " .. wanted
	if wanted == "InvestigateNoise" then
		c.investigation = { position = I.floorPointNear(root), rank = I.EXACT_RANK, at = t }
		I.enterState("InvestigateNoise", t)
	elseif wanted == "Search" then
		c.searchFrom = I.floorPointNear(root)
		I.enterState("Search", t)
	elseif wanted == "WallChase" then
		if I.inVent(player) then
			return "you are in a vent or a crawlway: it cannot follow you there"
		end
		I.chase(player, t)
		I.enterState("WallChase", t)
	elseif wanted == "HidingResponse" then
		local spot = I.hideSpotOf(player)
		local front = if spot then I.hideSpotFront(spot) else nil
		if not (spot and front) then
			return "you are not in a hiding spot"
		end
		hideWatch = { player = player, spot = spot, front = front, since = t }
		I.transition({ state = "HidingResponse", reason = "ai HidingResponse", reposition = false, giveUp = false }, t)
	elseif wanted == "AquaticStalk" then
		local level = c.level
		if not (level and #level.basins > 0) then
			return "no pool on this level"
		end
		swimmerAt = t
		swimmerPlayer = player
		I.setTarget(player)
		I.enterState("AquaticStalk", t)
	end
	I.publish()
	return string.format("Creature %s (hunting allowed for %ds)%s", wanted, I.DEV_FORCE_SECONDS, where)
end

function I.aiCommand(player: Player, args: { string }): string?
	if not (running and ctx) then
		return "no Creature this run"
	end
	local first = args[1]
	if first == nil then
		return I.describe()
	end
	local word = string.lower(first)
	if word == "pause" then
		MonsterAIService.SetPaused(true)
		return "AI paused"
	elseif word == "resume" then
		MonsterAIService.SetPaused(false)
		return "AI resumed"
	elseif word == "tp" then
		return I.bringNear(player)
	end
	local wanted = I.stateNamed(first)
	if not wanted then
		return "usage: ai [" .. table.concat(Enums.MonsterState, "|") .. "|pause|resume|tp]"
	end
	return I.force(player, wanted :: Enums.MonsterState)
end

function I.huntCommand(player: Player, _args: { string }): string?
	if not (running and ctx) then
		return "no Creature this run"
	end
	if ignored[player.UserId] then
		return "it is ignoring you (ignoreme to stop)"
	end
	local reply = I.force(player, "WallChase")
	devHuntUntil = math.max(devHuntUntil, I.now() + I.DEV_HUNT_SECONDS)
	return reply
end

function I.ignoreCommand(player: Player, _args: { string }): string?
	local nowIgnored = not ignored[player.UserId]
	if nowIgnored then
		ignored[player.UserId] = true
	else
		ignored[player.UserId] = nil
	end
	local c = ctx
	if nowIgnored and c and c.target == player then
		I.setTarget(nil)
		c.memory = nil
	end
	return if nowIgnored then "the Creature ignores you" else "the Creature notices you again"
end

function I.registerDevCommands()
	DevToolsService.Register(
		"ai",
		"ai [state|pause|resume|tp]: show the Creature's mind, force a state, pause it, or bring it near you unseen",
		I.aiCommand
	)
	DevToolsService.Register("hunt", "hunt: the Creature hunts you", I.huntCommand)
	DevToolsService.Register("ignoreme", "ignoreme: toggle whether the Creature notices you", I.ignoreCommand)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function I.onNoise(event: Types.NoiseEvent)
	if not (running and creature) then
		return
	end
	-- a participant's loud noise ends the spawn rule's grace (the noise itself is heard like any other)
	if
		graceLevel ~= nil
		and not awake
		and event.sourceUserId ~= nil
		and LOUD[event.priority]
		and event.levelId == graceLevel
	then
		wakeAt = I.now()
		lastReason = "grace: a loud noise"
	end
	if #noiseQueue >= I.NOISE_QUEUE_LIMIT then
		table.remove(noiseQueue, 1)
	end
	table.insert(noiseQueue, event)
end

function I.onSplash(player: Player)
	if running then
		splashArmed[player] = I.now()
	end
end

function MonsterAIService.Init()
	if initialized then
		return
	end
	initialized = true
	serviceTrove:Add(NoiseAndDirectorService.NoiseEmitted:Connect(I.onNoise))
	serviceTrove:Add(NoiseAndDirectorService.SplashThresholdCrossed:Connect(I.onSplash))
	serviceTrove:Add(LevelDirector.LevelActivated:Connect(function(levelId: Enums.LevelId, _context: Types.LevelContext)
		I.protected("level activation", function()
			I.onLevelActivated(levelId)
		end)
	end))
	serviceTrove:Add(JumpscareHandler.Finished:Connect(I.onCatchFinished))
	JumpscareHandler.SetStager(function(from: CFrame, to: CFrame): CFrame
		if I.customLineClear then
			return to -- specs: no physics to stage against
		end
		return I.stageTo(from, to)
	end)
	I.registerDevCommands()
end

function MonsterAIService.Start()
	local accumulated = 0
	serviceTrove:Connect(RunService.Heartbeat, function(dt: number)
		if not running or RunLifecycleService.GetPhase() ~= "InRun" then
			accumulated = 0
			return
		end
		I.protected("creature motion", function()
			MonsterAIService.StepMotion(dt)
		end)
		accumulated += dt
		if accumulated < I.TICK then
			return
		end
		local step = accumulated
		accumulated = 0
		I.protected("creature brain", function()
			MonsterAIService.Step(step)
		end)
	end)
end

function MonsterAIService.BeginRun(runContext: Types.RunContext)
	running = true
	difficulty = runContext.difficulty
	runSeed = runContext.seed
	graceLevel = nil
	poolEnteredAt = nil
	poolRetreatUntil = -math.huge
	participants = table.clone(runContext.participants)
	pacing = PacingDirector.new(difficulty, I.now())
	paused = false
	stunUntil = 0
	devHuntUntil = 0
	catching = nil
	pendingReach = nil
	grabbed = nil
	scripted = nil
	table.clear(splashArmed)
	lastCatchAt = -math.huge
	lastDownAt = -math.huge
	teleportReadyAt = math.huge
	teleports = 0
	lastTeleportTarget = nil
	startleUntil = -math.huge
	table.clear(lights)
	MonsterAIService.Attach(WorldService.GetCreature())
end

function MonsterAIService.EndRun()
	-- JumpscareHandler calls off its own catch when the match leaves InRun (its PhaseChanged listener)
	running = false
	scripted = nil
	catching = nil
	pendingReach = nil
	grabbed = nil
	warp = nil
	action = nil
	I.detach()
	I.forgetMind()
	pacing = nil
	participants = {}
	state = "Dormant"
	current = I.DORMANT
	awake = false
	wakeAt = nil
	paused = false
	speedScale = 1
	table.clear(splashArmed)
	table.clear(lastSeen)
	table.clear(lights)
	table.clear(doorModels)
end

function MonsterAIService.OnPlayerRemoving(player: Player)
	-- JumpscareHandler aborts the catch of a leaving victim itself (Players.PlayerRemoving)
	local c = ctx
	if c then
		if c.target == player then
			local memory = c.memory
			I.setTarget(nil)
			if memory and memory.player == player and running then
				local level = c.level
				local room = if level then Brain.roomAt(level, memory.position) else nil
				table.insert(alerts, {
					position = memory.position,
					rank = I.EXACT_RANK,
					priority = "High",
					medium = "Air",
					kind = "Scripted",
					sourceUserId = nil,
					zoneId = if room then room.id else nil,
					strength = 1,
					at = I.now(),
				})
			end
			c.memory = nil
		end
		local sightings: { Perception.Sighting } = {}
		for _, sighting in c.sightings do
			if sighting.player ~= player then
				table.insert(sightings, sighting)
			end
		end
		c.sightings = sightings
		local watch = c.hiding
		if watch and watch.player == player then
			c.stateDone = true
		end
	end
	local watch = hideWatch
	if watch and watch.player == player then
		hideWatch = nil
	end
	if grabbed == player then
		grabbed = nil
		if c then
			AquaticStalk.released(c)
		end
	end
	if swimmerPlayer == player then
		swimmerPlayer = nil
	end
	if lastTeleportTarget == player then
		lastTeleportTarget = nil
	end
	local reach = pendingReach
	if reach and reach.player == player then
		pendingReach = nil
	end
	local index = table.find(participants, player)
	if index then
		table.remove(participants, index)
	end
	lastSeen[player] = nil
	splashArmed[player] = nil
	records[player] = nil
	pulled[player] = nil
	ignored[player.UserId] = nil
end

return MonsterAIService
