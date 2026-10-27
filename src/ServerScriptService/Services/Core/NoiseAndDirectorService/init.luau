--!strict
-- NoiseAndDirectorService: the server's noise bus and per-run director.
--
-- Noise. Every audible action becomes one Types.NoiseEvent through Emit(position, kind, options?):
--   * radius, priority and medium default from NoiseConfig.Kinds[kind] (options may override the medium and scale
--     the radius); levelId defaults to LevelDirector's current level; a vent noise without a ventNodeId gets the
--     nearest VentNode on its level; serverTime = workspace:GetServerTimeNow().
--   * A player's continuous noises are paced: a second pulse of the same kind from the same player inside that
--     kind's NoiseConfig interval is merged into the first (Emit returns the standing pulse; TryEmit also says
--     whether anything was broadcast).
--   * Each pulse lands in a ring buffer (RecentNoises), fires NoiseEmitted, and is drawn as a ring for every player
--     with the DevTools attribute (DevOverlay remote).
--   * Water noise feeds the source player's splash meter (NoiseConfig.SplashMeter), which decays over time and fires
--     SplashThresholdCrossed once each time it climbs past the grab threshold.
-- Locomotion. Start() runs LocomotionNoiseSampler at GameConfig.ServerTickHz over every character during a run:
--   server-observed root speed and the server-confirmed MoveState decide each footstep pulse. Server moves are
--   announced with ExpectTeleport(player) (CharacterService.Spawn / Teleport do it for every caller); any other
--   step longer than the sampler's TeleportStep is heard at the speed it implies and fires SuspiciousMovement
--   (player, step), which P3 MovementAuthority consumes.
-- Floor debris. Entering a FloorDebris trigger volume during a run emits the 130-stud FloorDebris noise and a
--   GlassCrunch cue (AudioService) where the player stands, with a per-player, per-volume cooldown (DebrisNoise).
-- Director. BeginRun(ctx) asks RunDirector for the run's SpawnPlan (bear traps, flasks, batteries, locked grates);
--   GetPlan() hands it to WorldService, so this service's BeginRun must run before WorldService's (ServerMain order).
--
-- The current level is read from the ReplicatedStorage CurrentLevel attribute, which LevelDirector alone writes.
-- Reading it there (instead of requiring LevelDirector) keeps the require graph acyclic: WorldService,
-- CharacterService and DevToolsService require this module, and LevelDirector stays free to require them. This
-- module requires only ZoneService and AudioService, which require no other service.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local NoiseConfig = require(ReplicatedStorage.Shared.Config.NoiseConfig)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local ZoneGraph = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph)

local AudioService = require(script.Parent.AudioService)
local ZoneService = require(script.Parent.ZoneService)

local DebrisNoise = require(script.DebrisNoise)
local LocomotionNoiseSampler = require(script.LocomotionNoiseSampler)
local RunDirector = require(script.RunDirector)

local log = Log.new("Noise")

export type EmitOptions = LocomotionNoiseSampler.EmitOptions
export type SuspiciousStep = LocomotionNoiseSampler.SuspiciousStep

type VentPoint = { nodeId: string, position: Vector3 }

local RING_CAPACITY = 128
-- Pulses that arrive this much early (scheduler jitter between the sampler's clock and server time) still count.
local INTERVAL_SLACK = 0.05
local DEV_RING_SECONDS = 1.25

local W = Attributes.World

local NoiseAndDirectorService = {}

NoiseAndDirectorService.Name = "NoiseAndDirectorService"
NoiseAndDirectorService.RingCapacity = RING_CAPACITY

local noiseEmitted: Signal.Signal<Types.NoiseEvent> = Signal.new()
local splashThresholdCrossed: Signal.Signal<Player> = Signal.new()
local suspiciousMovement: Signal.Signal<Player, SuspiciousStep> = Signal.new()

NoiseAndDirectorService.NoiseEmitted = noiseEmitted
NoiseAndDirectorService.SplashThresholdCrossed = splashThresholdCrossed
-- A character covered more than the sampler's TeleportStep in one sample with no server teleport armed. The step
-- was already heard as movement; P3 MovementAuthority turns these into strikes / rubber-banding.
NoiseAndDirectorService.SuspiciousMovement = suspiciousMovement

local serviceTrove = Trove.new()

local plan: Types.SpawnPlan? = nil
local zoneGraph: Types.ZoneGraphData? = nil

-- Ring buffer of recent pulses: `ring[ringNext]` is the next slot written; the oldest pulse sits there once full.
local ring: { Types.NoiseEvent } = {}
local ringNext = 1
local ringCount = 0

-- Last broadcast pulse per player per kind (pacing), and splash meters per player.
local lastPulses: { [Player]: { [string]: Types.NoiseEvent } } = {}
local splashMeters: { [Player]: LocomotionNoiseSampler.SplashMeter } = {}

-- FloorDebris crunches (created below, once emit exists).
local debris: DebrisNoise.Debris

-- VentNode positions per level, rebuilt on demand whenever VentNodes come or go.
local ventIndex: { [string]: { VentPoint } }? = nil

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function currentLevel(): Enums.LevelId?
	local value = ReplicatedStorage:GetAttribute(Attributes.Match.CurrentLevel)
	if type(value) == "string" and Enums.has(Enums.LevelId, value) then
		return (value :: any) :: Enums.LevelId
	end
	return nil
end

local function inRun(): boolean
	return ReplicatedStorage:GetAttribute(Attributes.Match.MatchPhase) == "InRun"
end

local function graph(): Types.ZoneGraphData
	local built = zoneGraph
	if built then
		return built
	end
	local fresh = ZoneGraph.build(Builder.layouts())
	zoneGraph = fresh
	return fresh
end

local function buildVentIndex(): { [string]: { VentPoint } }
	local index: { [string]: { VentPoint } } = {}
	for _, instance in CollectionService:GetTagged(Tags.VentNode) do
		if not instance:IsA("Attachment") then
			continue
		end
		local parent = instance.Parent
		local nodeId = instance:GetAttribute(W.NodeId)
		local levelId = instance:GetAttribute(W.LevelId)
		if not (parent and parent:IsA("BasePart")) or type(nodeId) ~= "string" or type(levelId) ~= "string" then
			continue
		end
		local points = index[levelId]
		if not points then
			points = {}
			index[levelId] = points
		end
		-- parent.CFrame * attachment.CFrame is Attachment.WorldPosition, written so the Lune harness can run it too.
		table.insert(points, { nodeId = nodeId, position = (parent.CFrame * instance.CFrame).Position })
	end
	return index
end

-- NodeId of the VentNode nearest `position` (on `levelId` when given), or nil when no vent exists there.
local function nearestVentNode(position: Vector3, levelId: Enums.LevelId?): string?
	local index: { [string]: { VentPoint } } = ventIndex or buildVentIndex()
	ventIndex = index
	local bestId: string? = nil
	local bestDistance = math.huge
	local function scan(points: { VentPoint })
		for _, point in points do
			local distance = (point.position - position).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				bestId = point.nodeId
			end
		end
	end
	if levelId then
		local points = index[levelId]
		if points then
			scan(points)
		end
	else
		for _, points in index do
			scan(points)
		end
	end
	return bestId
end

local function invalidateVentIndex()
	ventIndex = nil
end

local function pushRing(event: Types.NoiseEvent)
	ring[ringNext] = event
	ringNext = ringNext % RING_CAPACITY + 1
	ringCount = math.min(ringCount + 1, RING_CAPACITY)
end

local function clearNoiseState()
	table.clear(ring)
	ringNext = 1
	ringCount = 0
	table.clear(lastPulses)
	table.clear(splashMeters)
	LocomotionNoiseSampler.reset()
	debris.reset()
end

local function forgetPlayer(player: Player)
	lastPulses[player] = nil
	splashMeters[player] = nil
	LocomotionNoiseSampler.forget(player)
	debris.forget(player)
end

local function isTracked(player: Player): boolean
	return player.Parent == Players
end

local function feedSplashMeter(player: Player, kind: Enums.NoiseKind, now: number)
	local gain = LocomotionNoiseSampler.splashGain(kind)
	if gain <= 0 or not isTracked(player) then
		return
	end
	local meter = splashMeters[player]
	if not meter then
		meter = LocomotionNoiseSampler.newSplashMeter(now)
		splashMeters[player] = meter
	end
	if LocomotionNoiseSampler.addSplash(meter, gain, now) then
		splashThresholdCrossed:Fire(player)
	end
end

local function showDevRing(event: Types.NoiseEvent, source: Player?)
	if event.radius <= 0 then
		return
	end
	local label = if source then string.format("%s %s", event.kind, source.Name) else event.kind
	for _, player in Players:GetPlayers() do
		if player:GetAttribute(Attributes.Player.DevTools) ~= true then
			continue
		end
		local payload: Types.DevOverlayPayload = {
			kind = "Noise",
			position = event.position,
			radius = event.radius,
			label = label,
			duration = DEV_RING_SECONDS,
		}
		xpcall(Net.Server.fire, function(err: any)
			log.warnThrottled("devoverlay", 10, "DevOverlay noise ring failed: %s", tostring(err))
		end, "DevOverlay", player, payload)
	end
end

--------------------------------------------------------------------------------
-- Noise API
--------------------------------------------------------------------------------

local function emit(position: Vector3, kind: Enums.NoiseKind, options: EmitOptions?): (Types.NoiseEvent, boolean)
	local opts: EmitOptions = options or {}
	local spec = NoiseConfig.Kinds[kind]
	if not spec then
		log.warnThrottled("kind:" .. tostring(kind), 10, "unknown noise kind %s; emitted as Scripted", tostring(kind))
		spec = NoiseConfig.Kinds.Scripted
	end
	local now = Workspace:GetServerTimeNow()
	local source = opts.sourcePlayer

	if source then
		local previous = lastPulses[source] and lastPulses[source][kind]
		if previous and not LocomotionNoiseSampler.intervalElapsed(previous.serverTime, now, kind, INTERVAL_SLACK) then
			return previous, false
		end
	end

	local multiplier = opts.radiusMultiplier
	if multiplier ~= nil and not (MathUtil.isFinite(multiplier) and multiplier >= 0) then
		log.warnThrottled("multiplier", 10, "ignoring radiusMultiplier %s for %s", tostring(multiplier), kind)
		multiplier = nil
	end
	local medium: Enums.NoiseMedium = opts.medium or spec.medium
	local levelId: Enums.LevelId? = opts.levelId or currentLevel()
	local ventNodeId: string? = opts.ventNodeId
	if ventNodeId == nil and medium == "Vent" then
		ventNodeId = nearestVentNode(position, levelId)
	end

	local event: Types.NoiseEvent = {
		position = position,
		radius = spec.radius * (multiplier or 1),
		kind = kind,
		priority = spec.priority,
		levelId = levelId,
		medium = medium,
		ventNodeId = ventNodeId,
		sourceUserId = if source then source.UserId else nil,
		serverTime = now,
	}
	table.freeze(event)

	if not MathUtil.isFiniteVector(position) then
		log.warnThrottled("position:" .. kind, 10, "dropped %s noise at a non-finite position", kind)
		return event, false
	end

	pushRing(event)
	if source and isTracked(source) then
		local perKind = lastPulses[source]
		if not perKind then
			perKind = {}
			lastPulses[source] = perKind
		end
		perKind[kind] = event
		feedSplashMeter(source, kind, now)
	end
	noiseEmitted:Fire(event)
	showDevRing(event, source)
	return event, true
end

-- Emits a noise pulse at `position` and returns it. When the same player's same continuous noise already pulsed
-- inside its NoiseConfig interval, nothing new is broadcast and that standing pulse is returned.
function NoiseAndDirectorService.Emit(position: Vector3, kind: Enums.NoiseKind, options: EmitOptions?): Types.NoiseEvent
	local event = emit(position, kind, options)
	return event
end

-- Emit, also reporting whether the pulse was broadcast (false: merged into a standing pulse, or dropped because
-- the position was not finite).
function NoiseAndDirectorService.TryEmit(
	position: Vector3,
	kind: Enums.NoiseKind,
	options: EmitOptions?
): (Types.NoiseEvent, boolean)
	return emit(position, kind, options)
end

-- Pulses with serverTime >= `sinceServerTime`, oldest first (at most RingCapacity of the newest).
function NoiseAndDirectorService.RecentNoises(sinceServerTime: number): { Types.NoiseEvent }
	local out: { Types.NoiseEvent } = {}
	local start = if ringCount < RING_CAPACITY then 1 else ringNext
	for offset = 0, ringCount - 1 do
		local event = ring[(start - 1 + offset) % RING_CAPACITY + 1]
		if event and event.serverTime >= sinceServerTime then
			table.insert(out, event)
		end
	end
	return out
end

-- `player`'s splash meter now (decayed), 0 when they have not splashed.
function NoiseAndDirectorService.GetSplashMeter(player: Player): number
	local meter = splashMeters[player]
	if not meter then
		return 0
	end
	return LocomotionNoiseSampler.splashValue(meter, Workspace:GetServerTimeNow())
end

-- Announces a server move of `player`'s character: a long step in the next second is not heard (and not reported
-- as suspicious). CharacterService.Spawn / Teleport call this for every caller; code that moves a character some
-- other way (a P4 vent exit that pivots the rig itself) must call it too, right before the move.
function NoiseAndDirectorService.ExpectTeleport(player: Player)
	LocomotionNoiseSampler.expectTeleport(player)
end

-- ExpectTeleport plus a fresh speed window (the character's motion so far is forgotten).
function NoiseAndDirectorService.ResetMotion(player: Player)
	LocomotionNoiseSampler.restartMotion(player)
end

--------------------------------------------------------------------------------
-- Director API
--------------------------------------------------------------------------------

-- This run's spawn plan, or nil outside a run.
function NoiseAndDirectorService.GetPlan(): Types.SpawnPlan?
	return plan
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function emitFromSampler(position: Vector3, kind: Enums.NoiseKind, options: EmitOptions)
	emit(position, kind, options)
end

local function reportFromSampler(player: Player, step: SuspiciousStep)
	suspiciousMovement:Fire(player, step)
end

-- Where a player crunches debris: their living character's root.
local function debrisPosition(player: Player, _volume: BasePart): Vector3?
	local root = Instances.characterRoot(player)
	local humanoid = Instances.characterHumanoid(player)
	if not root or not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return root.Position
end

debris = DebrisNoise.new({
	inRun = inRun,
	now = function(): number
		return Workspace:GetServerTimeNow()
	end,
	positionOf = debrisPosition,
	emit = emitFromSampler,
	playCue = function(preset: string, position: Vector3)
		AudioService.PlayAt(preset, position)
	end,
})

function NoiseAndDirectorService.Init()
	serviceTrove:Connect(Players.PlayerRemoving, function(player: Player)
		forgetPlayer(player)
	end)
	serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(Tags.VentNode), invalidateVentIndex)
	serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(Tags.VentNode), invalidateVentIndex)
	serviceTrove:Add(ZoneService.VolumeEntered:Connect(function(player: Player, volume: BasePart, tag: string)
		debris.onVolumeEntered(player, volume, tag)
	end))
end

function NoiseAndDirectorService.Start()
	local tickSeconds = 1 / GameConfig.ServerTickHz
	local accumulated = 0
	local sampling = false
	serviceTrove:Connect(RunService.Heartbeat, function(dt: number)
		accumulated += dt
		if accumulated < tickSeconds then
			return
		end
		local elapsed = accumulated
		accumulated = 0
		if not inRun() then
			if sampling then
				sampling = false
				LocomotionNoiseSampler.reset()
			end
			return
		end
		sampling = true
		xpcall(LocomotionNoiseSampler.step, function(err: any)
			log.warnThrottled("step", 10, "locomotion sampler step failed: %s", tostring(err))
		end, elapsed, emitFromSampler, reportFromSampler)
	end)
end

function NoiseAndDirectorService.BeginRun(ctx: Types.RunContext)
	clearNoiseState()
	local layouts = Builder.layouts()
	local runPlan = RunDirector.plan(ctx.seed, ctx.difficulty, layouts, graph())
	plan = runPlan
	local locked = 0
	for _ in runPlan.lockedGrates do
		locked += 1
	end
	log.info(
		"run %s (%s, seed %s): %d traps, %d flasks, %d batteries, %d grates locked, %d re-rolls",
		ctx.runId,
		runPlan.difficulty,
		tostring(runPlan.seed),
		#RunDirector.propsOf(runPlan, RunDirector.PropKinds.BearTrap),
		#RunDirector.propsOf(runPlan, RunDirector.PropKinds.ChemicalFlask),
		#RunDirector.propsOf(runPlan, RunDirector.PropKinds.Battery),
		locked,
		runPlan.rerolls
	)
end

function NoiseAndDirectorService.EndRun()
	plan = nil
	clearNoiseState()
end

function NoiseAndDirectorService.OnPlayerRemoving(player: Player)
	forgetPlayer(player)
end

return NoiseAndDirectorService
