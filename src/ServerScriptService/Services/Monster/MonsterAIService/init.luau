--!strict
-- MonsterAIService: the Creature's brain (spec §5). The only writer of the Creature's attributes (MonsterState,
-- StateSince, PoseMode, TargetUserId, InVent, VentSegmentId, Hidden, GrabbedUserId, LevelId; WorldService only seeds
-- LevelId / MonsterState when it builds the rig). StateSince is the server time of every MonsterState change.
--
-- Brain. During InRun, at GameConfig.ServerTickHz:
--   perceive  Perception.scan over the run's playing participants (ignored dev players left out), and every
--             NoiseEmitted pulse since the last tick through Hearing.perceive (the Creature's level, its eye, its duct
--             node, the level's VentGraph, the pacing's HearingScale), plus scripted Alerts. It remembers the target's
--             last seen or heard position (MemorySeconds), the rooms it heard noises in (Patrol sweeps toward them),
--             crawlers that gave themselves away (seen climbing in within SpotWindow, heard making a High / Critical
--             duct noise, spotted through a grate) and swimmers on the pool level.
--   pace      PacingDirector.Tick (chasing, target in sight, nearest player).
--   decide    Brain.decide over a Summary of the above (the transition table); entering a state runs the old state's
--             exit and the new one's enter; every state module updates once per tick.
--   act       the states drive Locomotion (stepped every Heartbeat so kinematic motion is smooth).
-- Catches go through JumpscareHandler.Catch (Hallway on floors, Vent in ducts, Locker through the LockerInspector
-- hook). While a catch runs the brain leaves the body alone (no states, no movement); when it finishes the movement
-- is re-synced from the root, the pacing notes the catch (cooldown, Relax) and the Creature withdraws out of sight.
-- A mover that stalls for good is put back on its level's patrol network at the nearest waypoint nobody can see,
-- and only while nobody can see the Creature either: it never pops in or out in front of anyone.
--
-- Levels. When LevelDirector activates Level 1 or later: PacingDirector.NoteAirlock (grace), the Creature is moved
-- (hidden) to that level's CreatureSpawn if it is elsewhere, it reappears once nobody can see it, and it wakes into
-- Patrol WakeDelay seconds later. A level controller that acquired it (AcquireScripted) in its Activate keeps it.
--
-- Hooks: RegisterLockerInspector (P7 lockers), RegisterPoolGrabber (P7 pool), AcquireScripted (P6 / P8 cutscenes),
-- Stun (P6 chemicals; a catch in progress is called off), Alert (scripted noises, heard like any other),
-- SetSpeedScale (P7 level tuning: Level 3's gym).
--
-- Dev commands (DevToolsService): ai [state|pause|resume|tp], hunt, ignoreme.

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
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
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
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local VentNetworkService = require(ServerScriptService.Services.Vents.VentNetworkService)

local Brain = require(script.Brain)
local CreatureBody = require(script.CreatureBody)
local Hearing = require(script.Hearing)
local JumpscareHandler = require(script.JumpscareHandler)
local Locomotion = require(script.Locomotion)
local Perception = require(script.Perception)

local AquaticStalk = require(script.States.AquaticStalk)
local Dormant = require(script.States.Dormant)
local InvestigateNoise = require(script.States.InvestigateNoise)
local Patrol = require(script.States.Patrol)
local Scripted = require(script.States.Scripted)
local Stunned = require(script.States.Stunned)
local VentChase = require(script.States.VentChase)
local WallChase = require(script.States.WallChase)

local log = Log.new("MonsterAI")

local C = Attributes.Creature
local P = Attributes.Player

export type ScriptedHandle = {
	MoveTo: (self: ScriptedHandle, position: Vector3, speed: number?) -> (),
	Teleport: (self: ScriptedHandle, cframe: CFrame) -> (),
	SetPose: (self: ScriptedHandle, poseMode: Enums.PoseMode) -> (),
	SetHidden: (self: ScriptedHandle, hidden: boolean) -> (),
	Face: (self: ScriptedHandle, position: Vector3) -> (),
	Release: (self: ScriptedHandle, nextState: Enums.MonsterState?) -> (),
}

export type Clock = () -> number

type Catching = { player: Player, kind: Enums.JumpscareKind, at: number }
type Hold = { token: string, handle: ScriptedHandle }

local function stateModule(
	name: Enums.MonsterState,
	enter: (ctx: Brain.Context, from: Enums.MonsterState) -> (),
	update: (ctx: Brain.Context, dt: number) -> (),
	exit: (ctx: Brain.Context, to: Enums.MonsterState) -> ()
): Brain.StateModule
	return { Name = name, enter = enter, update = update, exit = exit }
end

local DORMANT = stateModule("Dormant", Dormant.enter, Dormant.update, Dormant.exit)
local PATROL = stateModule("Patrol", Patrol.enter, Patrol.update, Patrol.exit)

local STATES: { [string]: Brain.StateModule } = {
	Dormant = DORMANT,
	Patrol = PATROL,
	InvestigateNoise = stateModule(
		"InvestigateNoise",
		InvestigateNoise.enter,
		InvestigateNoise.update,
		InvestigateNoise.exit
	),
	WallChase = stateModule("WallChase", WallChase.enter, WallChase.update, WallChase.exit),
	VentChase = stateModule("VentChase", VentChase.enter, VentChase.update, VentChase.exit),
	Stunned = stateModule("Stunned", Stunned.enter, Stunned.update, Stunned.exit),
	AquaticStalk = stateModule("AquaticStalk", AquaticStalk.enter, AquaticStalk.update, AquaticStalk.exit),
	Scripted = stateModule("Scripted", Scripted.enter, Scripted.update, Scripted.exit),
}

local TICK = 1 / GameConfig.ServerTickHz
local WAKE_DELAY = 4 -- seconds after a level activates before the Creature starts its patrol
local REVEAL_RETRY = 25 -- a hidden Creature still in sight this long is moved to a spot nobody sees
local SPOT_WINDOW = 3 -- seconds a crawler stays given away
local SEEN_ENTER_WINDOW = 1.5 -- seen this recently when crawling in counts as seen climbing in
local VENT_BLOCK_SECONDS = 15 -- after finding no way into the ducts, crawlers are not chased again for this long
local SWIMMER_MEMORY = 6
local GRAB_ARMED_SECONDS = 10
local GRAB_GRACE = 1 -- seconds a grabbed player may read as not Grabbed before the grab counts as over
local CATCH_TIMEOUT = GameConfig.OneShotLead
	+ CreatureConfig.Jumpscare.LungeSeconds
	+ CreatureConfig.Jumpscare.HoldSeconds
	+ 4
local HEARD_ZONE_TTL = Patrol.HeardTtl
local NOISE_QUEUE_LIMIT = 64
local SIGHT_RANGE_LIMIT = 250 -- visibility checks for players farther than this are skipped
local UNSTICK_MIN = 6 -- an unstick teleport lands at least this far away
local DUCT_SNAP = 1.5 -- a believed noise position this close to a duct centreline is inside the duct
local EXACT_RANK = Hearing.priorityRank("High")
local DEV_FORCE_SECONDS = 30
local DEV_HUNT_SECONDS = 45
local TP_MIN = 18
local TP_MAX = 60
local SPOT_PRESET = "Screech"
local SPOT_VOLUME = 0.75
local STUN_PRESET = "Screech"
local MIN_SPEED_SCALE = 0.5
local MAX_SPEED_SCALE = 2
local SWIM_STATES: { [string]: boolean } = { Treading = true, Freestyle = true, Underwater = true, Grabbed = true }
local EXIT_ANCHOR = "ExitAnchor"

local MonsterAIService = {}

MonsterAIService.Name = "MonsterAIService"
MonsterAIService.WakeDelay = WAKE_DELAY
MonsterAIService.SpotWindow = SPOT_WINDOW

local stateChanged: Signal.Signal<Enums.MonsterState, Enums.MonsterState> = Signal.new()
local caught: Signal.Signal<Player, Enums.JumpscareKind> = Signal.new()

-- (new, old) on every MonsterState change.
MonsterAIService.StateChanged = stateChanged
-- (victim, kind) when a catch starts.
MonsterAIService.Caught = caught

local serviceTrove = Trove.new()
local initialized = false

local clock: Clock = function(): number
	return Workspace:GetServerTimeNow()
end
local engine: Locomotion.Engine = Locomotion.defaultEngine()

-- the run
local running = false
local difficulty: Enums.Difficulty = "Standard"
local speedScale = 1 -- SetSpeedScale (level tuning); every pace but a scripted one
local participants: { Player } = {}
local pacing: PacingDirector.Pacing? = nil

-- the Creature
local creature: Model? = nil
local body: CreatureBody.Body? = nil
local mover: Locomotion.Mover? = nil
local ctx: Brain.Context? = nil
local creatureLevel: Enums.LevelId? = nil
local levelInfos: { [string]: Brain.LevelInfo } = {}

-- the mind
local state: Enums.MonsterState = "Dormant"
local stateSince = 0
local current: Brain.StateModule = DORMANT
local lastReason = "placed"
local awake = false
local wakeAt: number? = nil
local revealPending = false
local revealAt = 0
local paused = false
local chaseStarted: number? = nil
local stunUntil = 0
local ventBlockedUntil = 0
local devHuntUntil = 0
local catching: Catching? = nil
local grabbed: Player? = nil
local grabbedHeldAt = 0
local scripted: Hold? = nil
local noiseQueue: { Types.NoiseEvent } = {}
local alerts: { Brain.HeardNoise } = {}
local lastSeen: { [Player]: number } = {}
local spotted: { [Player]: number } = {}
local exitGrates: { [Player]: string } = {}
local splashArmed: { [Player]: number } = {}
local swimmerAt = -math.huge
local swimmerPlayer: Player? = nil
local ignored: { [number]: boolean } = {}

-- hooks
local lockerInspector: Types.LockerInspector? = nil
local poolGrabber: Types.PoolGrabber? = nil

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function now(): number
	return clock()
end

local function protected(label: string, fn: () -> ())
	xpcall(fn, function(err: any)
		log.warnThrottled(label, 10, "%s failed: %s\n%s", label, tostring(err), debug.traceback())
	end)
end

local function levelInfoFor(levelId: string): Brain.LevelInfo?
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

local function rootOf(player: Player): Vector3?
	local root = Instances.characterRoot(player)
	return if root then root.CFrame.Position else nil
end

-- Alive or Downed with a character (a player who left is no longer playing: LifeStateService forgets them).
local function playing(player: Player): boolean
	return LifeStateService.IsPlaying(player) and Instances.characterRoot(player) ~= nil
end

local function huntable(player: Player): boolean
	return not ignored[player.UserId] and playing(player)
end

local function huntablePlayers(): { Player }
	local out: { Player } = {}
	for _, player in participants do
		if huntable(player) then
			table.insert(out, player)
		end
	end
	return out
end

local function playingPlayers(): { Player }
	local out: { Player } = {}
	for _, player in participants do
		if playing(player) then
			table.insert(out, player)
		end
	end
	return out
end

local function swimmingPlayer(player: Player): boolean
	return PlayerStateService.GetMode(player) == "Swim" or SWIM_STATES[PlayerStateService.GetMoveState(player)] == true
end

local function sightParams(): RaycastParams
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
	return SpatialQuery.losParams(exclude)
end

local function lineClear(from: Vector3, to: Vector3): boolean
	return SpatialQuery.lineClear(from, to, sightParams())
end

-- Could any playing participant see the Creature with its root at `point` (its head or its chest)?
local function visible(point: Vector3): boolean
	local params = sightParams()
	for _, player in playingPlayers() do
		local eye = Perception.playerEye(player)
		if not eye or (eye - point).Magnitude > SIGHT_RANGE_LIMIT then
			continue
		end
		for _, lift in { CreatureConfig.EyeHeightAboveRoot.Biped, 0 } do
			if SpatialQuery.lineClear(eye, point + Vector3.new(0, lift, 0), params) then
				return true
			end
		end
	end
	return false
end

local function playerEyes(): { Vector3 }
	local out: { Vector3 } = {}
	for _, player in playingPlayers() do
		local eye = Perception.playerEye(player)
		if eye then
			table.insert(out, eye)
		end
	end
	return out
end

-- Root positions the Creature can stand at on its level: every patrol waypoint (under water where the waypoint is).
local function standingSpots(info: Brain.LevelInfo, m: Locomotion.Mover): { Vector3 }
	local out: { Vector3 } = {}
	for _, waypoint in info.waypoints do
		local point = waypoint.position
		if m:BasinAt(point) then
			table.insert(out, point)
		else
			table.insert(out, point + Vector3.new(0, CreatureBody.RootHeight, 0))
		end
	end
	return out
end

local function sees(player: Player): boolean
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

local function grateStandPoint(grate: VentGraph.Grate): CFrame
	local model = VentNetworkService.GetGrateModel(grate.id)
	local anchor = if model then PropKit.findAttachment(model, EXIT_ANCHOR) else nil
	if anchor then
		return PropKit.attachmentWorld(anchor)
	end
	-- the builder's placement when the fixture is missing: ExitOut into the room at floor level
	local wall = grate.wall
	local out = wall.Position + wall.LookVector * (WorldConfig.WallThickness / 2 + VentGrateBuilder.ExitOut)
	local floor = Vector3.new(out.X, wall.Position.Y - WorldConfig.VentCenterHeight, out.Z)
	local facing = CreatureBody.flatDirection(wall.LookVector) or Vector3.new(0, 0, -1)
	return CFrame.lookAt(floor, floor + facing)
end

local GRATES: Locomotion.Grates = {
	state = function(grateId: string): Enums.GrateState
		return VentNetworkService.GetGrateState(grateId)
	end,
	standPoint = grateStandPoint,
	kick = function(grateId: string)
		VentNetworkService.ForceGrate(grateId, "Kicked")
	end,
}

-- A floor point for a believed position: a point inside a duct becomes the room side of the grate nearest it.
local function floorPointNear(position: Vector3): Vector3
	local graph = ctx and ctx.graph
	if not graph or VentGraph.nearest(graph, position, DUCT_SNAP) == nil then
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
	return if best then grateStandPoint(best).Position else position
end

--------------------------------------------------------------------------------
-- Attributes
--------------------------------------------------------------------------------

local function publish()
	local model, b, m, c = creature, body, mover, ctx
	if not (model and b and m and c) then
		return
	end
	local target = c.target
	Attributes.set(model, C.MonsterState, state)
	Attributes.set(model, C.StateSince, stateSince)
	Attributes.set(model, C.PoseMode, b.pose)
	Attributes.set(model, C.TargetUserId, if target then target.UserId else 0)
	Attributes.set(model, C.InVent, m:Medium() == "Vent")
	Attributes.set(model, C.VentSegmentId, m:Segment() or "")
	Attributes.set(model, C.Hidden, b.hidden)
	Attributes.set(model, C.GrabbedUserId, if grabbed then (grabbed :: Player).UserId else 0)
	if creatureLevel then
		Attributes.set(model, C.LevelId, creatureLevel)
	end
end

-- The attributes that change with movement, every frame (the rest are written each brain tick).
local function publishMotion()
	local model, b, m = creature, body, mover
	if model and b and m then
		Attributes.set(model, C.PoseMode, b.pose)
		Attributes.set(model, C.InVent, m:Medium() == "Vent")
	end
end

--------------------------------------------------------------------------------
-- Body placement
--------------------------------------------------------------------------------

-- Puts the root at `cframe` (anchored, held), in the medium that point is in.
local function placeBody(cframe: CFrame)
	local b, m = body, mover
	if not (b and m) then
		return
	end
	m:Reset("Floor")
	b:Face(nil)
	b:SetAnchored(true)
	b:PlaceAt(cframe)
	local water = m:BasinAt(cframe.Position) ~= nil
	m:Reset(if water then "Water" else "Floor")
	if water then
		b:SetPose("Swim")
	elseif b.pose == "Swim" or b.pose == "Quadruped" then
		b:SetPose("Biped")
	end
end

local function hide(seconds: number)
	local b = body
	if not b then
		return
	end
	b:SetHidden(true)
	revealPending = true
	revealAt = now() + seconds
end

local function forgetMind()
	local c = ctx
	if c then
		c.target = nil
		c.memory = nil
		c.investigation = nil
		c.heard = nil
		c.sightings = {}
		c.reposition = false
		c.stateDone = false
		table.clear(c.heardZones)
	end
	noiseQueue = {}
	alerts = {}
	table.clear(spotted)
	table.clear(lastSeen)
	swimmerPlayer = nil
	swimmerAt = -math.huge
	chaseStarted = nil
end

-- Moves the Creature onto `levelId` at its CreatureSpawn (hidden until nobody can see it when `conceal` is set).
local function relocate(levelId: Enums.LevelId, conceal: boolean)
	local c, m = ctx, mover
	if not (c and m) then
		return
	end
	local info = levelInfoFor(levelId)
	creatureLevel = levelId
	c.level = info
	c.graph = VentNetworkService.GetGraph(levelId)
	m:SetLevel(c.graph, if info then info.basins else {})
	forgetMind()
	local spawn = if info then info.spawn else nil
	if not spawn and info and info.waypoints[1] then
		spawn = CFrame.new(standingSpots(info, m)[1])
	end
	if spawn then
		placeBody(spawn)
	end
	if conceal then
		hide(REVEAL_RETRY)
	end
end

-- Teleports the Creature to the nearest standing spot of its level (at least UNSTICK_MIN away) that nobody can see,
-- and only while nobody can see it where it is. False when that is not possible right now.
local function relocateUnseen(): boolean
	local c, b, m = ctx, body, mover
	local info = c and c.level
	if not (c and b and m and info) then
		return false
	end
	local here = b:GetPosition()
	if visible(here) then
		return false
	end
	local spots: { Vector3 } = {}
	for _, spot in standingSpots(info, m) do
		if (spot - here).Magnitude >= UNSTICK_MIN then
			table.insert(spots, spot)
		end
	end
	local point = PacingDirector.repositionPoint(spots, playerEyes(), here, 0, math.huge, visible)
	if not point then
		return false
	end
	local facing = CreatureBody.flatDirection(b:GetCFrame().LookVector) or Vector3.new(0, 0, -1)
	placeBody(CFrame.lookAt(point, point + facing))
	log.debug("the Creature was stuck; moved unseen to %s", tostring(point))
	return true
end

--------------------------------------------------------------------------------
-- Targets and catches
--------------------------------------------------------------------------------

local function setTarget(player: Player?)
	local c = ctx
	if not c then
		return
	end
	if c.target == player then
		return
	end
	c.target = player
	local memory = c.memory
	if memory and memory.player ~= player then
		c.memory = nil
	end
end

local function canHuntNow(): boolean
	local p = pacing
	local t = now()
	return t < devHuntUntil or (p ~= nil and p:CanHunt(t))
end

local function catchKindFor(player: Player): Enums.JumpscareKind?
	local model, b, m = creature, body, mover
	local target = rootOf(player)
	if not (model and b and m and target) then
		return nil
	end
	local here = b:GetPosition()
	local eye = Perception.playerEye(player) or target
	return Brain.catchKind({
		horizontal = MathUtil.horizontalDistance(here, target),
		vertical = math.abs(here.Y - target.Y),
		distance = (here - target).Magnitude,
		creatureInVent = m:Medium() == "Vent",
		targetInVent = VentNetworkService.IsInVent(player),
		lineClear = lineClear(Perception.creatureEye(model), eye),
		playing = huntable(player),
		hiding = PlayerStateService.GetMoveState(player) == "Hiding",
		canHunt = canHuntNow(),
		busy = catching ~= nil or JumpscareHandler.IsBusy(),
		hidden = b.hidden,
		stunned = now() < stunUntil,
	})
end

local function tryCatch(player: Player, kind: Enums.JumpscareKind): boolean
	local model, m = creature, mover
	if not (model and m) or catching ~= nil or JumpscareHandler.IsBusy() or not canHuntNow() then
		return false
	end
	if ignored[player.UserId] or now() < stunUntil then
		return false
	end
	if not JumpscareHandler.Catch(model, player, kind) then
		return false
	end
	catching = { player = player, kind = kind, at = now() }
	-- the handler owns the root now: drop the plan without touching the body (the root is anchored by the handler)
	m:Stop()
	caught:Fire(player, kind)
	return true
end

--------------------------------------------------------------------------------
-- States
--------------------------------------------------------------------------------

local function enterState(nextState: Enums.MonsterState, t: number)
	local c = ctx
	local previous = state
	if not c or nextState == previous then
		return
	end
	current.exit(c, nextState)
	if Brain.isChase(nextState) and not Brain.isChase(previous) then
		chaseStarted = t
		local b = body
		if b and not b.hidden then
			AudioService.PlayAt(SPOT_PRESET, Perception.creatureEye(b.model), { volume = SPOT_VOLUME })
		end
	elseif not Brain.isChase(nextState) then
		chaseStarted = nil
	end
	if previous == "VentChase" then
		if c.ventBlocked then
			ventBlockedUntil = t + VENT_BLOCK_SECONDS
			c.ventBlocked = false
		end
		table.clear(spotted)
	end
	state = nextState
	stateSince = t
	c.stateDone = false
	current = STATES[nextState] or PATROL
	current.enter(c, previous :: Enums.MonsterState)
	publish()
	stateChanged:Fire(nextState, previous :: Enums.MonsterState)
end

local function bestNonCrawler(): Player?
	local c = ctx
	if not c then
		return nil
	end
	for _, sighting in c.sightings do
		if not VentNetworkService.IsInVent(sighting.player) then
			return sighting.player
		end
	end
	return nil
end

local function bestCrawler(): Player?
	local c = ctx
	if not c then
		return nil
	end
	for _, sighting in c.sightings do
		if VentNetworkService.IsInVent(sighting.player) then
			return sighting.player
		end
	end
	return nil
end

local function remember(player: Player, position: Vector3, t: number)
	local c = ctx
	if c and c.target == player then
		c.memory = { player = player, position = position, at = t }
	end
end

-- Gets the hand-offs ready, then enters the decided state.
local function transition(decision: Brain.Decision, quarry: Player?, t: number)
	local c = ctx
	if not c then
		return
	end
	lastReason = decision.reason
	if decision.reposition then
		c.reposition = true
	end
	local nextState = decision.state
	if nextState == state then
		return
	end
	if nextState == "WallChase" then
		local target = c.target
		local chosen = if target and sees(target) then target else bestNonCrawler()
		setTarget(chosen)
		local position = if chosen then rootOf(chosen) else nil
		if chosen and position then
			remember(chosen, position, t)
		end
	elseif nextState == "VentChase" then
		setTarget(quarry or bestCrawler() or c.target)
	elseif nextState == "AquaticStalk" then
		setTarget(swimmerPlayer)
	elseif nextState == "InvestigateNoise" then
		local heard = c.heard
		local memory = c.memory
		local position: Vector3
		local rank = EXACT_RANK
		local fromNoise = heard ~= nil and (decision.reason == "heard" or memory == nil)
		if fromNoise and heard then
			position, rank = heard.position, heard.rank
		elseif memory then
			position = memory.position
		else
			local b = body
			position = if b then b:GetPosition() else Vector3.zero
		end
		c.investigation = { position = floorPointNear(position), rank = rank, at = t }
	end
	enterState(nextState :: Enums.MonsterState, t)
end

-- Who it looks at this tick: the chase's target (switching to whoever it can see when the target is out of sight),
-- or, outside the chases, whoever it is staring at.
local function updateTarget(quarry: Player?)
	local c = ctx
	if not c then
		return
	end
	local target = c.target
	if state == "WallChase" then
		if not (target and sees(target)) then
			local other = bestNonCrawler()
			if other then
				setTarget(other)
			end
		end
	elseif state == "VentChase" then
		if quarry and target == nil then
			setTarget(quarry)
		end
	elseif state == "AquaticStalk" then
		local swimmer = swimmerPlayer
		if swimmer and target ~= swimmer and not (target and sees(target)) then
			setTarget(swimmer)
		end
	elseif state == "Patrol" or state == "InvestigateNoise" then
		local best = c.sightings[1]
		setTarget(if best then best.player else nil)
	else
		setTarget(nil)
	end
end

--------------------------------------------------------------------------------
-- Senses
--------------------------------------------------------------------------------

local function noteHeard(noise: Brain.HeardNoise, best: Brain.HeardNoise?, t: number): Brain.HeardNoise?
	local c = ctx
	if not c then
		return best
	end
	local zone = noise.zoneId
	if zone then
		c.heardZones[zone] = { at = t, rank = noise.rank, position = noise.position }
	end
	local sourceId = noise.sourceUserId
	local source = if sourceId then Players:GetPlayerByUserId(sourceId) else nil
	if source and huntable(source) then
		if noise.medium == "Vent" and noise.rank >= EXACT_RANK and VentNetworkService.IsInVent(source) then
			spotted[source] = t
		end
		if noise.medium == "Water" and swimmingPlayer(source) then
			swimmerAt = t
			swimmerPlayer = source
		end
		remember(source, noise.position, t)
	end
	if best == nil or noise.rank > best.rank or (noise.rank == best.rank and noise.strength > best.strength) then
		return noise
	end
	return best
end

local function sense(t: number)
	local c, m, p, model = ctx, mover, pacing, creature
	if not (c and m and p and model) then
		return
	end
	local inVent = m:Medium() == "Vent"
	local segment = m:Segment()
	local sightings = Perception.scan(model, huntablePlayers(), {
		difficulty = difficulty,
		creatureInVent = inVent,
		creatureSegment = segment,
		raycast = nil,
	})
	c.sightings = sightings
	for _, sighting in sightings do
		local player = sighting.player
		lastSeen[player] = t
		local position = rootOf(player)
		if position then
			remember(player, position, t)
		end
		if c.level and #(c.level :: Brain.LevelInfo).basins > 0 and swimmingPlayer(player) then
			swimmerAt = t
			swimmerPlayer = player
		end
	end

	local listener: Hearing.Listener = {
		position = Perception.creatureEye(model),
		levelId = creatureLevel,
		inVent = inVent,
		ventNode = m:NearestNode(),
		graph = c.graph,
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
		local heard = Hearing.perceive(event, listener)
		if not heard then
			continue
		end
		local level = c.level
		local room = if level then Brain.roomAt(level, heard.position) else nil
		best = noteHeard({
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
		best = noteHeard(alert, best, t)
	end
	c.heard = best
	for zone, heard in c.heardZones do
		if t - heard.at > HEARD_ZONE_TTL then
			c.heardZones[zone] = nil
		end
	end
	for player, at in spotted do
		if t - at > SPOT_WINDOW then
			spotted[player] = nil
		end
	end
end

-- A crawler that gave itself away and may be chased into the ducts (the current target first).
local function ventQuarry(t: number): Player?
	if t < ventBlockedUntil then
		return nil
	end
	local c = ctx
	local best: Player? = nil
	for player, at in spotted do
		if t - at <= SPOT_WINDOW and huntable(player) and VentNetworkService.IsInVent(player) then
			if best == nil or (c ~= nil and c.target == player) then
				best = player
			end
		end
	end
	return best
end

local function nearestPlayerDistance(): number?
	local b = body
	if not b then
		return nil
	end
	local here = b:GetPosition()
	local best: number? = nil
	for _, player in huntablePlayers() do
		local position = rootOf(player)
		if position then
			local distance = (position - here).Magnitude
			if best == nil or distance < (best :: number) then
				best = distance
			end
		end
	end
	return best
end

local function summarize(t: number): (Brain.Summary, Player?)
	local c, m, p = ctx, mover, pacing
	assert(c and m and p, "summarize needs a Creature")
	local best = c.sightings[1]
	local quarry = ventQuarry(t)
	local devHunt = t < devHuntUntil
	local chaseSeconds = if chaseStarted then t - (chaseStarted :: number) else 0
	local memory = c.memory
	local investigation = c.investigation
	local level = c.level
	local summary: Brain.Summary = {
		state = state,
		elapsed = t - stateSince,
		scripted = scripted ~= nil,
		stunned = t < stunUntil,
		awake = awake and not revealPending,
		catching = catching ~= nil or grabbed ~= nil,
		canHunt = devHunt or p:CanHunt(t),
		inVent = m:Medium() == "Vent",
		sees = best ~= nil,
		seesInVent = best ~= nil and VentNetworkService.IsInVent(best.player),
		ventQuarry = quarry ~= nil,
		heard = if c.heard then (c.heard :: Brain.HeardNoise).rank else 0,
		investigating = if investigation and state == "InvestigateNoise" then investigation.rank else 0,
		memoryAge = if memory then t - memory.at else nil,
		breakChase = chaseStarted ~= nil and not devHunt and p:ShouldBreakChase(chaseSeconds),
		swimmer = level ~= nil and #level.basins > 0 and t - swimmerAt <= SWIMMER_MEMORY,
		stateDone = c.stateDone,
	}
	return summary, quarry
end

--------------------------------------------------------------------------------
-- Upkeep
--------------------------------------------------------------------------------

local function updateReveal(t: number)
	local b = body
	if not (revealPending and b) then
		return
	end
	if not visible(b:GetPosition()) then
		b:SetHidden(false)
		revealPending = false
		return
	end
	if t >= revealAt then
		-- still watched: slip away to a spot nobody sees and appear there, or keep waiting out of sight
		if relocateUnseen() then
			b:SetHidden(false)
			revealPending = false
		else
			revealAt = t + REVEAL_RETRY
		end
	end
end

local function updateGrab(t: number)
	local victim = grabbed
	local c, p = ctx, pacing
	if not (victim and c and p) then
		return
	end
	local holding = victim.Parent == Players and PlayerStateService.GetMoveState(victim) == "Grabbed"
	if holding then
		grabbedHeldAt = t
	end
	if
		victim.Parent ~= Players
		or not LifeStateService.IsPlaying(victim)
		or (not holding and t - grabbedHeldAt > GRAB_GRACE)
	then
		grabbed = nil
		p:NoteCatch(t)
		c.reposition = true
		AquaticStalk.released(c)
	end
end

-- A mover that stalled for good (or is shut in the ducts) is moved unseen to a standing spot and the state starts
-- over from there; while someone watches it, it keeps trying where it stands.
local function handleMover()
	local m, c = mover, ctx
	if not (m and c) then
		return
	end
	local status = m:Status()
	if status == "Stuck" or (status == "Failed" and m:Medium() == "Vent") then
		if relocateUnseen() then
			current.enter(c, state)
		else
			m:Reset(m:Medium())
		end
	end
end

local function settleCatch(outcome: string)
	local c, b, m, p = ctx, body, mover, pacing
	local active = catching
	catching = nil
	if not (c and b and m and p and active) then
		return
	end
	-- the handler moved and re-anchored the root: take the body and the movement from where it really is
	b.anchored = b.root.Anchored
	b:Reassert()
	m:Reset(m:Medium())
	if outcome ~= "Aborted" then
		p:NoteCatch(now())
	end
	-- a dev hunt ends with its catch: the cooldown applies like any other
	devHuntUntil = 0
	c.reposition = true
	if c.target == active.player then
		setTarget(nil)
		c.memory = nil
	end
end

local function onCatchFinished(victim: Player, _kind: Enums.JumpscareKind, outcome: string)
	local active = catching
	if active and active.player == victim then
		settleCatch(outcome)
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
	local t = now()
	if paused then
		noiseQueue = {}
		alerts = {}
		publish()
		return
	end
	local active = catching
	if active and t - active.at > CATCH_TIMEOUT then
		if not JumpscareHandler.Abort("Timeout") then
			settleCatch("Aborted")
		end
	end
	updateGrab(t)
	if scripted then
		noiseQueue = {}
		alerts = {}
		publish()
		return
	end
	local busy = catching ~= nil
	if not busy then
		updateReveal(t)
	end
	sense(t)
	local target = c.target
	c.phase = p:Tick(dt, {
		chasing = Brain.isChase(state),
		seesTarget = target ~= nil and sees(target),
		nearestPlayerDistance = nearestPlayerDistance(),
	})
	local wake = wakeAt
	if not awake and wake and t >= wake then
		awake = true
		wakeAt = nil
	end
	local summary, quarry = summarize(t)
	c.canHunt = summary.canHunt
	transition(Brain.decide(summary), quarry, t)
	updateTarget(quarry)
	if not busy then
		handleMover()
		current.update(c, dt)
	end
	publish()
end

-- One movement step (every Heartbeat during InRun; specs call it directly). Nothing moves while a catch runs.
function MonsterAIService.StepMotion(dt: number)
	local m = mover
	if not (running and m) or paused or catching ~= nil then
		return
	end
	m:Step(dt)
	publishMotion()
end

--------------------------------------------------------------------------------
-- Context
--------------------------------------------------------------------------------

local function newContext(model: Model, b: CreatureBody.Body, m: Locomotion.Mover): Brain.Context
	return {
		creature = model,
		body = b,
		mover = m,
		level = nil,
		graph = nil,
		difficulty = difficulty,
		random = Random.new(),
		now = now,
		sightings = {},
		heard = nil,
		heardZones = {},
		target = nil,
		memory = nil,
		phase = "BuildUp",
		canHunt = false,
		investigation = nil,
		reposition = false,
		stateDone = false,
		ventBlocked = false,
		stunFrom = nil,
		speedOf = function(name: Enums.MonsterState): number
			return Brain.speedFor(name, difficulty) * (if name == "Scripted" then 1 else speedScale)
		end,
		setTarget = setTarget,
		catchKind = catchKindFor,
		tryCatch = tryCatch,
		visible = visible,
		repositionPoint = function(minDistance: number, maxDistance: number): Vector3?
			local c = ctx
			local info = c and c.level
			if not info then
				return nil
			end
			return PacingDirector.repositionPoint(
				standingSpots(info, m),
				playerEyes(),
				b:GetPosition(),
				minDistance,
				maxDistance,
				visible
			)
		end,
		playerPositions = playerEyes,
		lockerInspector = function(): Types.LockerInspector?
			return lockerInspector
		end,
		poolGrabber = function(): Types.PoolGrabber?
			return poolGrabber
		end,
		noteSpotted = function(player: Player)
			if huntable(player) then
				spotted[player] = now()
			end
		end,
		grabArmed = function(player: Player): boolean
			local at = splashArmed[player]
			return at ~= nil and now() - at <= GRAB_ARMED_SECONDS
		end,
		setGrabbed = function(player: Player?)
			grabbed = player
			grabbedHeldAt = now()
			publish()
		end,
		inVent = function(player: Player): boolean
			return VentNetworkService.IsInVent(player)
		end,
		railPointOf = function(player: Player): VentGraph.RailPoint?
			return VentNetworkService.GetRailPoint(player)
		end,
		exitGrateOf = function(player: Player): string?
			return exitGrates[player]
		end,
		ventOccupants = function(): { Player }
			local levelId = creatureLevel
			local out: { Player } = {}
			if not levelId then
				return out
			end
			for _, player in VentNetworkService.OccupantsOf(levelId) do
				if huntable(player) then
					table.insert(out, player)
				end
			end
			return out
		end,
		grateState = function(grateId: string): Enums.GrateState
			return VentNetworkService.GetGrateState(grateId)
		end,
		standPoint = grateStandPoint,
		swimming = swimmingPlayer,
		rootOf = rootOf,
		lineClear = lineClear,
	}
end

local function detach()
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
	detach()
	if not model then
		return
	end
	local b = CreatureBody.attach(model)
	if not b then
		return
	end
	local m = Locomotion.new(b, engine, GRATES, now)
	creature = model
	body = b
	mover = m
	local c = newContext(model, b, m)
	ctx = c
	local fallback: Enums.LevelId = Enums.LevelId[2]
	local currentLevel: Enums.LevelId? = LevelDirector.GetCurrentLevel()
	if currentLevel and (Enums.levelIndex(currentLevel) or 1) >= 2 then
		fallback = currentLevel
	end
	local levelId = Attributes.getEnum(model, C.LevelId, Enums.LevelId, fallback)
	if (Enums.levelIndex(levelId) or 1) < 2 then
		levelId = fallback
	end
	state = "Dormant"
	current = DORMANT
	stateSince = now()
	lastReason = "placed"
	awake = false
	wakeAt = nil
	revealPending = false
	relocate(levelId :: Enums.LevelId, false)
	Dormant.enter(c, "Dormant")
	publish()
end

--------------------------------------------------------------------------------
-- Levels
--------------------------------------------------------------------------------

local function onLevelActivated(levelId: Enums.LevelId)
	local p, c = pacing, ctx
	if not (running and p and c) then
		return
	end
	if (Enums.levelIndex(levelId) or 1) < 2 then
		return -- the basement has no Creature
	end
	local t = now()
	p:NoteAirlock(t)
	if catching then
		JumpscareHandler.Abort("Level")
	end
	stunUntil = 0
	grabbed = nil
	if creatureLevel ~= levelId then
		relocate(levelId, true)
	else
		forgetMind()
	end
	awake = false
	wakeAt = t + WAKE_DELAY
	lastReason = "level " .. levelId .. " activated"
	if not scripted then
		enterState("Dormant", t)
	end
	publish()
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

local function applyStun(seconds: number, from: Vector3)
	local c, b = ctx, body
	if not (c and b) then
		return
	end
	local t = now()
	stunUntil = math.max(stunUntil, t + math.max(0, seconds))
	c.stunFrom = from
	setTarget(nil)
	AudioService.PlayAt(STUN_PRESET, Perception.creatureEye(b.model))
	if state == "Stunned" then
		Stunned.retreat(c)
	else
		enterState("Stunned", t)
	end
	publish()
end

-- P6 chemicals: blinded for `seconds`, stumbling back away from `from` (in a duct along VentPathfinder.retreatPath).
-- A catch in progress is called off; a cutscene or a sleeping Creature is not stunned.
function MonsterAIService.Stun(seconds: number, from: Vector3)
	if not (running and ctx) or scripted or not awake then
		return
	end
	if not (MathUtil.isFinite(seconds) and MathUtil.isFiniteVector(from)) then
		return
	end
	if catching then
		JumpscareHandler.Abort("Stunned")
		if catching then
			settleCatch("Aborted")
		end
	end
	applyStun(seconds, from)
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
		at = now(),
	})
end

local function nearestPlayerTo(position: Vector3, predicate: ((Player) -> boolean)?): Player?
	local best: Player? = nil
	local bestDistance = math.huge
	for _, player in huntablePlayers() do
		local root = rootOf(player)
		if root and (predicate == nil or predicate(player)) and (root - position).Magnitude < bestDistance then
			best, bestDistance = player, (root - position).Magnitude
		end
	end
	return best
end

local function releaseScripted(nextState: Enums.MonsterState?)
	local c, b = ctx, body
	scripted = nil
	if not (c and b) then
		return
	end
	b:Face(nil)
	if b.hidden then
		hide(REVEAL_RETRY)
	end
	local t = now()
	local wanted: Enums.MonsterState = if nextState
			and Enums.has(Enums.MonsterState, nextState)
			and nextState ~= "Scripted"
		then nextState
		else "Patrol"
	awake = wanted ~= "Dormant"
	wakeAt = nil
	local here = b:GetPosition()
	if wanted == "WallChase" then
		local victim = nearestPlayerTo(here, function(player: Player): boolean
			return not VentNetworkService.IsInVent(player)
		end)
		setTarget(victim)
		local position = if victim then rootOf(victim) else nil
		if victim and position then
			remember(victim, position, t)
		else
			wanted = "Patrol"
		end
	elseif wanted == "VentChase" then
		local crawler = nearestPlayerTo(here, VentNetworkService.IsInVent)
		if crawler then
			setTarget(crawler)
			spotted[crawler] = t
		else
			wanted = "Patrol"
		end
	elseif wanted == "InvestigateNoise" then
		local near = nearestPlayerTo(here, nil)
		local position = if near then rootOf(near) else nil
		c.investigation = { position = floorPointNear(position or here), rank = EXACT_RANK, at = t }
	elseif wanted == "AquaticStalk" then
		if swimmerPlayer == nil then
			wanted = "Patrol"
		end
	elseif wanted == "Stunned" then
		stunUntil = math.max(stunUntil, t + GameConfig.StunSeconds)
		c.stunFrom = here + b:GetCFrame().LookVector
	end
	lastReason = "released"
	enterState(wanted, t)
	publish()
end

local function makeHandle(token: string): ScriptedHandle
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
			placeBody(cframe)
			publish()
		end,
		SetPose = function(_self: ScriptedHandle, poseMode: Enums.PoseMode)
			local b = body
			if not (live() and b) or not Enums.has(Enums.PoseMode, poseMode) then
				return
			end
			b:SetPose(poseMode)
			publish()
		end,
		SetHidden = function(_self: ScriptedHandle, hidden: boolean)
			local b = body
			if not (live() and b) then
				return
			end
			b:SetHidden(hidden == true)
			revealPending = false
			publish()
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
			releaseScripted(nextState)
		end,
	}
	return handle
end

-- Exclusive control for a cutscene. Nil while another token holds it, during a catch, or without a Creature; the
-- same token gets its handle back.
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
	local handle = makeHandle(token)
	scripted = { token = token, handle = handle }
	lastReason = "acquired by " .. token
	enterState("Scripted", now())
	return handle
end

-- Level tuning (P7: Level 3's gym, where it stalks at high speed): every state's pace times `scale` (clamped
-- MIN_SPEED_SCALE..MAX_SPEED_SCALE; 1, the default, is as configured; EndRun restores it). A pace already set follows at
-- once, in proportion, so a state's own choice of pace (a withdraw, a lunge) keeps its ratio; scripted moves keep their
-- own speed.
function MonsterAIService.SetSpeedScale(scale: number)
	local value = if MathUtil.isFinite(scale) then math.clamp(scale, MIN_SPEED_SCALE, MAX_SPEED_SCALE) else 1
	local previous = speedScale
	if math.abs(value - previous) < 1e-6 then
		return
	end
	speedScale = value
	local m, b = mover, body
	local walker = if b then b.humanoid else nil
	if m and b and walker and scripted == nil and catching == nil and state ~= "Scripted" then
		local pace = walker.WalkSpeed * value / previous
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

-- Replaces the server-time source (specs pass a fake clock; nil restores GetServerTimeNow).
function MonsterAIService.SetClock(fake: Clock?)
	clock = fake or function(): number
		return Workspace:GetServerTimeNow()
	end
end

-- Replaces Locomotion's engine for Creatures attached from now on (specs; nil restores the real one).
function MonsterAIService.SetEngine(fake: Locomotion.Engine?)
	engine = fake or Locomotion.defaultEngine()
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

local function stateNamed(text: string): Enums.MonsterState?
	local wanted = string.lower(text)
	for _, name: Enums.MonsterState in Enums.MonsterState do
		if string.lower(name) == wanted then
			return name
		end
	end
	return nil
end

local function describe(): string
	local c, b, m, p = ctx, body, mover, pacing
	if not (c and b and m and p) then
		return "no Creature this run"
	end
	local snapshot = p:Snapshot()
	local target = c.target
	local medium = m:Medium()
	local segment = m:Segment()
	local t = now()
	return string.format(
		"%s for %.1fs (%s) | target %s | pose %s | %s%s%s | %s | pacing %s, tension %.2f%s%s%s",
		state,
		t - stateSince,
		lastReason,
		if target then target.Name else "none",
		b.pose,
		medium,
		if segment then " " .. segment else "",
		if b.hidden then ", hidden" else "",
		tostring(creatureLevel),
		snapshot.phase,
		snapshot.tension,
		if t < snapshot.cooldownUntil then string.format(", cooldown %.0fs", snapshot.cooldownUntil - t) else "",
		if t < snapshot.graceUntil then string.format(", grace %.0fs", snapshot.graceUntil - t) else "",
		if paused then " | PAUSED" elseif not awake then " | asleep" else ""
	)
end

local function callerLevel(player: Player): Enums.LevelId?
	local fromZone = player:GetAttribute(P.LevelId)
	if type(fromZone) == "string" and Enums.has(Enums.LevelId, fromZone) then
		return fromZone :: Enums.LevelId
	end
	return LevelDirector.GetCurrentLevel()
end

-- Brings the Creature to the caller's level (when it is elsewhere) without the airlock rules.
local function joinLevel(levelId: Enums.LevelId)
	local c, m = ctx, mover
	if not (c and m) or creatureLevel == levelId then
		return
	end
	local info = levelInfoFor(levelId)
	creatureLevel = levelId
	c.level = info
	c.graph = VentNetworkService.GetGraph(levelId)
	m:SetLevel(c.graph, if info then info.basins else {})
	forgetMind()
end

local function wakeForDev()
	local b = body
	awake = true
	wakeAt = nil
	if revealPending and b then
		b:SetHidden(false)
		revealPending = false
	end
end

local function bringNear(player: Player): string
	local c, b, m = ctx, body, mover
	local root = rootOf(player)
	local eye = Perception.playerEye(player)
	local levelId = callerLevel(player)
	if not (c and b and m and root and eye and levelId) then
		return "you need a character on a school level"
	end
	if (Enums.levelIndex(levelId) or 1) < 2 then
		return "the Creature never enters the basement"
	end
	joinLevel(levelId :: Enums.LevelId)
	local info = c.level
	if not info then
		return "no layout for " .. levelId
	end
	local spots = standingSpots(info, m)
	local point = PacingDirector.repositionPoint(spots, { eye }, root, TP_MIN, TP_MAX, visible)
	local note = ""
	if not point then
		local best, bestDistance = nil :: Vector3?, math.huge
		for _, spot in spots do
			local distance = (spot - root).Magnitude
			if distance >= TP_MIN and distance < bestDistance then
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
	placeBody(CFrame.lookAt(spot, spot + facing))
	wakeForDev()
	lastReason = "ai tp"
	enterState("Patrol", now())
	publish()
	return string.format("Creature brought %.0f studs from you on %s%s", (spot - root).Magnitude, levelId, note)
end

local function force(player: Player, wanted: Enums.MonsterState): string
	local c, b = ctx, body
	if not (c and b) then
		return "no Creature this run"
	end
	if scripted then
		return "a cutscene holds the Creature"
	end
	local t = now()
	local root = rootOf(player)
	if wanted == "Scripted" then
		return "Scripted is entered through AcquireScripted (cutscenes)"
	end
	if wanted == "Dormant" then
		awake = false
		wakeAt = nil
		lastReason = "ai Dormant"
		enterState("Dormant", t)
		return "Creature asleep (ai Patrol wakes it)"
	end
	if wanted == "Stunned" then
		wakeForDev()
		if not root then
			return "you need a character"
		end
		MonsterAIService.Stun(GameConfig.StunSeconds, root)
		return string.format("Creature stunned for %ds", GameConfig.StunSeconds)
	end
	wakeForDev()
	local levelId = callerLevel(player)
	local away = levelId ~= nil and levelId ~= creatureLevel
	if wanted == "Patrol" then
		devHuntUntil = 0
		lastReason = "ai Patrol"
		enterState("Patrol", t)
		return "Creature patrolling"
			.. (if away then " (on " .. tostring(creatureLevel) .. "; ai tp brings it)" else "")
	end
	if not root then
		return "you need a character"
	end
	devHuntUntil = t + DEV_FORCE_SECONDS
	lastReason = "ai " .. wanted
	if wanted == "InvestigateNoise" then
		c.investigation = { position = floorPointNear(root), rank = EXACT_RANK, at = t }
		enterState("InvestigateNoise", t)
	elseif wanted == "WallChase" then
		if VentNetworkService.IsInVent(player) then
			return "you are in a vent: use ai VentChase"
		end
		setTarget(player)
		remember(player, root, t)
		enterState("WallChase", t)
	elseif wanted == "VentChase" then
		if not VentNetworkService.IsInVent(player) then
			return "you are not in a vent"
		end
		setTarget(player)
		spotted[player] = t
		enterState("VentChase", t)
	elseif wanted == "AquaticStalk" then
		local level = c.level
		if not (level and #level.basins > 0) then
			return "no pool on this level"
		end
		swimmerAt = t
		swimmerPlayer = player
		setTarget(player)
		enterState("AquaticStalk", t)
	end
	publish()
	return string.format(
		"Creature %s (hunting allowed for %ds)%s",
		wanted,
		DEV_FORCE_SECONDS,
		if away then " (it is on " .. tostring(creatureLevel) .. "; ai tp brings it)" else ""
	)
end

local function aiCommand(player: Player, args: { string }): string?
	if not (running and ctx) then
		return "no Creature this run"
	end
	local first = args[1]
	if first == nil then
		return describe()
	end
	local word = string.lower(first)
	if word == "pause" then
		MonsterAIService.SetPaused(true)
		return "AI paused"
	elseif word == "resume" then
		MonsterAIService.SetPaused(false)
		return "AI resumed"
	elseif word == "tp" then
		return bringNear(player)
	end
	local wanted = stateNamed(first)
	if not wanted then
		return "usage: ai [" .. table.concat(Enums.MonsterState, "|") .. "|pause|resume|tp]"
	end
	return force(player, wanted :: Enums.MonsterState)
end

local function huntCommand(player: Player, _args: { string }): string?
	if not (running and ctx) then
		return "no Creature this run"
	end
	if ignored[player.UserId] then
		return "it is ignoring you (ignoreme to stop)"
	end
	local reply = force(player, if VentNetworkService.IsInVent(player) then "VentChase" else "WallChase")
	devHuntUntil = math.max(devHuntUntil, now() + DEV_HUNT_SECONDS)
	return reply
end

local function ignoreCommand(player: Player, _args: { string }): string?
	local nowIgnored = not ignored[player.UserId]
	if nowIgnored then
		ignored[player.UserId] = true
	else
		ignored[player.UserId] = nil
	end
	local c = ctx
	if nowIgnored and c and c.target == player then
		setTarget(nil)
		c.memory = nil
	end
	spotted[player] = nil
	return if nowIgnored then "the Creature ignores you" else "the Creature notices you again"
end

local function registerDevCommands()
	DevToolsService.Register(
		"ai",
		"ai [state|pause|resume|tp]: show the Creature's mind, force a state, pause it, or bring it near you unseen",
		aiCommand
	)
	DevToolsService.Register("hunt", "hunt: the Creature hunts you", huntCommand)
	DevToolsService.Register("ignoreme", "ignoreme: toggle whether the Creature notices you", ignoreCommand)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function onNoise(event: Types.NoiseEvent)
	if not (running and creature) then
		return
	end
	if #noiseQueue >= NOISE_QUEUE_LIMIT then
		table.remove(noiseQueue, 1)
	end
	table.insert(noiseQueue, event)
end

local function onEntered(player: Player, _grateId: string)
	local seen = lastSeen[player]
	if running and seen and now() - seen <= SEEN_ENTER_WINDOW and huntable(player) then
		spotted[player] = now()
	end
end

local function onExited(player: Player, grateId: string)
	exitGrates[player] = grateId
end

local function onSplash(player: Player)
	if running then
		splashArmed[player] = now()
	end
end

function MonsterAIService.Init()
	if initialized then
		return
	end
	initialized = true
	serviceTrove:Add(NoiseAndDirectorService.NoiseEmitted:Connect(onNoise))
	serviceTrove:Add(NoiseAndDirectorService.SplashThresholdCrossed:Connect(onSplash))
	serviceTrove:Add(VentNetworkService.Entered:Connect(onEntered))
	serviceTrove:Add(VentNetworkService.Exited:Connect(onExited))
	serviceTrove:Add(LevelDirector.LevelActivated:Connect(function(levelId: Enums.LevelId, _context: Types.LevelContext)
		protected("level activation", function()
			onLevelActivated(levelId)
		end)
	end))
	serviceTrove:Add(JumpscareHandler.Finished:Connect(onCatchFinished))
	registerDevCommands()
end

function MonsterAIService.Start()
	local accumulated = 0
	serviceTrove:Connect(RunService.Heartbeat, function(dt: number)
		if not running or RunLifecycleService.GetPhase() ~= "InRun" then
			accumulated = 0
			return
		end
		protected("creature motion", function()
			MonsterAIService.StepMotion(dt)
		end)
		accumulated += dt
		if accumulated < TICK then
			return
		end
		local step = accumulated
		accumulated = 0
		protected("creature brain", function()
			MonsterAIService.Step(step)
		end)
	end)
end

function MonsterAIService.BeginRun(runContext: Types.RunContext)
	running = true
	difficulty = runContext.difficulty
	participants = table.clone(runContext.participants)
	pacing = PacingDirector.new(difficulty, now())
	paused = false
	stunUntil = 0
	ventBlockedUntil = 0
	devHuntUntil = 0
	catching = nil
	grabbed = nil
	scripted = nil
	table.clear(exitGrates)
	table.clear(splashArmed)
	MonsterAIService.Attach(WorldService.GetCreature())
end

function MonsterAIService.EndRun()
	-- JumpscareHandler calls off its own catch when the match leaves InRun (its PhaseChanged listener)
	running = false
	scripted = nil
	catching = nil
	grabbed = nil
	detach()
	forgetMind()
	pacing = nil
	participants = {}
	state = "Dormant"
	current = DORMANT
	awake = false
	wakeAt = nil
	revealPending = false
	paused = false
	speedScale = 1
	table.clear(exitGrates)
	table.clear(splashArmed)
	table.clear(lastSeen)
end

function MonsterAIService.OnPlayerRemoving(player: Player)
	-- JumpscareHandler aborts the catch of a leaving victim itself (Players.PlayerRemoving)
	local c = ctx
	if c and c.target == player then
		local memory = c.memory
		setTarget(nil)
		if memory and memory.player == player and running then
			local level = c.level
			local room = if level then Brain.roomAt(level, memory.position) else nil
			table.insert(alerts, {
				position = memory.position,
				rank = EXACT_RANK,
				priority = "High",
				medium = "Air",
				kind = "Scripted",
				sourceUserId = nil,
				zoneId = if room then room.id else nil,
				strength = 1,
				at = now(),
			})
		end
		c.memory = nil
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
	local index = table.find(participants, player)
	if index then
		table.remove(participants, index)
	end
	lastSeen[player] = nil
	spotted[player] = nil
	exitGrates[player] = nil
	splashArmed[player] = nil
	ignored[player.UserId] = nil
end

return MonsterAIService
