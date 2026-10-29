--!strict
-- CheckpointAirlockService: the stairwell airlock checkpoints (spec §6). Heavy fire doors between the floors wait for
-- the surviving squad with a straggler timer, lock behind it, bring the eliminated back at the next floor with half
-- their health, and move the run on to that floor.
--
-- One airlock at a time: the current level's (LevelDirector) exit vestibule, the lower-level room of the stairwell
-- the run's route leaves it by (LevelDirector.exitFor: its fromRoom), with that vestibule's Checkpoint trigger (a
-- CheckpointVolume part, ZoneId = the vestibule) and the fire door(s) between the vestibule and the level (DoorService
-- airlocks on that level whose FromLevel is the level and StairwellId the route's). The last level (the roof) has no exit airlock: the service stays Idle there (P8's
-- finale). Any level change it did not make itself (a dev level skip) resets it to Idle for the new level.
--
-- At GameConfig.ServerTickHz every run participant counts as inside while their root, or the point under their feet,
-- is in the volume's box (pure maths: the volume is a NoCollide part).
--   Idle     -> Waiting   the first playing participant (Alive or Downed) is inside: StragglerDeadline = now +
--                         GameConfig.StragglerSeconds (server time) on the exit door(s), and Notify "Hud.Straggler" to
--                         everyone (AirlockController counts down from the attribute on every client).
--   Waiting  -> Sealing   every Alive participant is inside (a Downed one counts only while inside), or the deadline
--                         passed with at least one playing participant inside: the exit door(s) close Locked in
--                         SEAL_SECONDS (DoorService, which never closes them on anyone).
--   Waiting  -> Idle      the deadline passed with nobody playing inside (the doors never seal an empty vestibule):
--                         the deadline is cleared and the doors wait for the next arrival.
--   Sealing  -> Sealed    once the doors are shut (or SEAL_TIMEOUT after they started closing): every playing
--                         participant still outside the volume is left behind (SetSpectating, character despawned,
--                         Notify "Airlock.LeftBehind"); the deadline is cleared; LevelDirector.MarkCleared + Advance
--                         (which initialises the next floor); RunStats FloorsCleared for each survivor (+ Notify
--                         "Checkpoint.Sealed"); FloorCleared(level, survivors); then every Dead / Spectating participant
--                         is made Alive at GameConfig.CheckpointRespawnHealthFraction of their health and spawned in the
--                         next level's entry vestibule (its PlayerSpawn anchors, CharacterService.SpawnCFrame, one slot
--                         per participant; Notify "Checkpoint.Respawned"); Sealed(from, to).
-- Sealed doors stay Locked for the rest of the run (no backtracking). Wipes are not this service's call.
-- A participant leaving re-evaluates the airlock at once (they may have been the last one outside).
--
-- Dev command: seal (seal the current airlock now, as if the straggler timer had run out with the squad inside).
--
-- Pure rules (tests/Specs/Airlock.spec.luau): exitRoom, startsWaiting, sealVerdict, splitSurvivors, respawnHealth.
-- SetClock swaps the time source and SetCharacterHooks the despawn / spawn calls, so specs run a whole floor change on
-- a fake clock with hand-built characters.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local DoorService = require(ServerScriptService.Services.Mechanics.DoorService)

local log = Log.new("Airlock")

local W = Attributes.World

export type AirlockPhase = "Idle" | "Waiting" | "Sealing" | "Sealed"

export type Verdict = "Wait" | "Seal" | "Reset"

export type Clock = { now: () -> number }

-- How the service removes a left-behind player's character and spawns a respawned one (specs replace them).
export type CharacterHooks = {
	despawn: (player: Player) -> (),
	spawn: (player: Player, cframe: CFrame) -> (),
}

-- One participant as the rules see them.
export type Occupant = { lifeState: Enums.LifeState, inside: boolean }

local SEAL_SECONDS = 1.6
local SEAL_TIMEOUT = 6 -- seconds after the doors start closing that the floor changes whatever the doors are doing
local RESOLVE_INTERVAL = 1 -- seconds between searches for a level's volume and doors while they are missing
local CLEARED_STAT: Enums.StatKey = "FloorsCleared"
local SEALED_STATE: Enums.DoorState = "Locked"
local STRAGGLER_KEY = "Hud.Straggler"
local LEFT_BEHIND_KEY = "Airlock.LeftBehind"
local SEALED_KEY = "Checkpoint.Sealed"
local RESPAWNED_KEY = "Checkpoint.Respawned"
local DEFAULT_HIP_HEIGHT = 2
local LIVE_PHASES: { [string]: boolean } = { Deploying = true, InRun = true }

local CheckpointAirlockService = {}

CheckpointAirlockService.Name = "CheckpointAirlockService"
CheckpointAirlockService.SealSeconds = SEAL_SECONDS
CheckpointAirlockService.SealTimeout = SEAL_TIMEOUT

local floorCleared: Signal.Signal<Enums.LevelId, { Player }> = Signal.new()
local sealedSignal: Signal.Signal<Enums.LevelId, Enums.LevelId> = Signal.new()

-- (cleared level, survivors who sealed in) once the doors have shut and the run moved on (P8 awards credits).
CheckpointAirlockService.FloorCleared = floorCleared
-- (from, to) after LevelDirector.Advance and the respawns.
CheckpointAirlockService.Sealed = sealedSignal

local realClock: Clock = {
	now = function(): number
		return Workspace:GetServerTimeNow()
	end,
}

local realHooks: CharacterHooks = {
	despawn = function(player: Player)
		CharacterService.Despawn(player)
	end,
	spawn = function(player: Player, cframe: CFrame)
		task.spawn(CharacterService.Spawn, player, cframe)
	end,
}

local clock: Clock = realClock
local hooks: CharacterHooks = realHooks
local serviceTrove = Trove.new()

local participants: { Player } = {} -- run order (spawn slots)
local running = false
local live = false
local initialized = false

local phase: AirlockPhase = "Idle"
local levelId: Enums.LevelId? = nil -- the level whose exit airlock is watched
local exitRoomId: string? = nil
local exitStairwellId: string? = nil -- the route's stairwell out of the watched level
local volumes: { BasePart } = {}
local exitDoors: { Model } = {}
local resolvedAt = -math.huge
local deadline: number? = nil
local sealingSince: number? = nil

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/Airlock.spec.luau)
--------------------------------------------------------------------------------

-- The exit vestibule of `level` on `route` (a plan's route; nil: the middle stairwells): the lower-level room of the
-- stairwell the route leaves it by (nil on the roof).
function CheckpointAirlockService.exitRoom(level: Enums.LevelId, route: { [string]: string }?): string?
	local stairwell = WorldConfig.routeExit(route, level)
	return if stairwell then stairwell.fromRoom else nil
end

local function isPlaying(state: Enums.LifeState): boolean
	return state == "Alive" or state == "Downed"
end

-- Whether a playing participant (Alive or Downed) is inside: Idle turns Waiting.
function CheckpointAirlockService.startsWaiting(occupants: { Occupant }): boolean
	for _, occupant in occupants do
		if occupant.inside and isPlaying(occupant.lifeState) then
			return true
		end
	end
	return false
end

-- What a Waiting airlock does at server time `now`: seal (every Alive participant inside, or the deadline passed
-- with a playing participant inside), reset (the deadline passed with nobody playing inside) or keep waiting.
function CheckpointAirlockService.sealVerdict(occupants: { Occupant }, now: number, sealAt: number): Verdict
	local anyInside = false
	local allAliveInside = true
	for _, occupant in occupants do
		if occupant.inside and isPlaying(occupant.lifeState) then
			anyInside = true
		end
		if occupant.lifeState == "Alive" and not occupant.inside then
			allAliveInside = false
		end
	end
	if not anyInside then
		return if now >= sealAt then "Reset" else "Wait"
	end
	if allAliveInside or now >= sealAt then
		return "Seal"
	end
	return "Wait"
end

-- Splits the occupants (by index) at the moment the floor changes: playing ones inside survive, playing ones outside
-- are left behind; everyone else (Dead, Spectating, Lobby) is neither.
function CheckpointAirlockService.splitSurvivors(occupants: { Occupant }): ({ number }, { number })
	local survivors: { number } = {}
	local leftBehind: { number } = {}
	for index, occupant in occupants do
		if isPlaying(occupant.lifeState) then
			table.insert(if occupant.inside then survivors else leftBehind, index)
		end
	end
	return survivors, leftBehind
end

-- The health an eliminated participant comes back with at the checkpoint.
function CheckpointAirlockService.respawnHealth(): number
	return LifeStateService.reviveHealth(GameConfig.CheckpointRespawnHealthFraction)
end

--------------------------------------------------------------------------------
-- World lookups
--------------------------------------------------------------------------------

-- The level's Checkpoint volume(s) in its exit vestibule (any of the level's when none names the vestibule).
local function findVolumes(level: Enums.LevelId, room: string): { BasePart }
	local matching: { BasePart } = {}
	local any: { BasePart } = {}
	for _, instance in CollectionService:GetTagged(Tags.CheckpointVolume) do
		if not (instance:IsA("BasePart") and instance:IsDescendantOf(Workspace)) then
			continue
		end
		if instance:GetAttribute(W.LevelId) ~= level then
			continue
		end
		table.insert(any, instance)
		if instance:GetAttribute(W.ZoneId) == room then
			table.insert(matching, instance)
		end
	end
	return if #matching > 0 then matching else any
end

-- The fire door(s) between the level and its exit vestibule (the route's stairwell; the jammed ones never count).
local function findExitDoors(level: Enums.LevelId): { Model }
	local out: { Model } = {}
	for _, door in DoorService.Airlocks(level) do
		local stairwell = door:GetAttribute(W.StairwellId)
		if
			door:GetAttribute(W.FromLevel) == level
			and door:GetAttribute(W.LevelId) == level
			and (stairwell == nil or stairwell == exitStairwellId)
		then
			table.insert(out, door)
		end
	end
	return out
end

local function resolve(force: boolean)
	local level: Enums.LevelId?, room: string? = levelId, exitRoomId
	if not (level and room) then
		return
	end
	local now = clock.now()
	if not force and #volumes > 0 and #exitDoors > 0 then
		return
	end
	if not force and now - resolvedAt < RESOLVE_INTERVAL then
		return
	end
	resolvedAt = now
	volumes = findVolumes(level, room)
	exitDoors = findExitDoors(level)
end

local function isInside(player: Player): boolean
	local root = Instances.characterRoot(player)
	if not root then
		return false
	end
	local humanoid = Instances.characterHumanoid(player)
	local hipHeight = if humanoid then humanoid.HipHeight else DEFAULT_HIP_HEIGHT
	local position = root.CFrame.Position
	local feet = position - Vector3.new(0, hipHeight + root.Size.Y * 0.5, 0)
	for _, volume in volumes do
		if volume.Parent == nil then
			continue
		end
		if SpatialQuery.pointInBox(volume.CFrame, volume.Size, position) then
			return true
		end
		if SpatialQuery.pointInBox(volume.CFrame, volume.Size, feet) then
			return true
		end
	end
	return false
end

local function occupants(): { Occupant }
	local out: { Occupant } = {}
	for _, player in participants do
		local state: Enums.LifeState = LifeStateService.GetState(player)
		local occupant: Occupant = { lifeState = state, inside = isPlaying(state) and isInside(player) }
		table.insert(out, occupant)
	end
	return out
end

local function setDeadline(value: number?)
	deadline = value
	for _, door in exitDoors do
		Attributes.set(door, W.StragglerDeadline, value)
	end
end

local function notify(player: Player, key: string)
	local payload: Types.NotifyPayload = { key = key, args = {} }
	Net.Server.fire("Notify", player, payload)
end

--------------------------------------------------------------------------------
-- Phases
--------------------------------------------------------------------------------

-- Watches `level`'s exit airlock from Idle (the previous level's deadline, if any, is cleared).
local function resetFor(level: Enums.LevelId?)
	if deadline ~= nil then
		setDeadline(nil)
	end
	phase = "Idle"
	sealingSince = nil
	levelId = level
	local exit = if level then LevelDirector.exitFor(level) else nil
	exitRoomId = if exit then exit.fromRoom else nil
	exitStairwellId = if exit then exit.id else nil
	volumes = {}
	exitDoors = {}
	resolvedAt = -math.huge
	resolve(true)
end

local function beginWaiting()
	local seconds = GameConfig.StragglerSeconds
	phase = "Waiting"
	setDeadline(clock.now() + seconds)
	local payload: Types.NotifyPayload = { key = STRAGGLER_KEY, args = { tostring(seconds) } }
	Net.Server.fireAll("Notify", payload)
	log.info("%s airlock waiting (%ds)", levelId or "?", seconds)
end

local function seal()
	phase = "Sealing"
	sealingSince = clock.now()
	for _, door in exitDoors do
		DoorService.SetState(door, SEALED_STATE, SEAL_SECONDS)
	end
	log.info("%s airlock sealing", levelId or "?")
end

local function doorsShut(): boolean
	for _, door in exitDoors do
		if door.Parent ~= nil and (DoorService.IsMoving(door) or DoorService.GetState(door) ~= SEALED_STATE) then
			return false
		end
	end
	return true
end

local function respawnEliminated(to: Enums.LevelId)
	local health = CheckpointAirlockService.respawnHealth()
	for slot, player in participants do
		local state: Enums.LifeState = LifeStateService.GetState(player)
		if state ~= "Dead" and state ~= "Spectating" then
			continue
		end
		LifeStateService.SetAlive(player, health)
		hooks.spawn(player, CharacterService.SpawnCFrame(to, slot))
		notify(player, RESPAWNED_KEY)
	end
end

local function finalize()
	local from: Enums.LevelId? = levelId
	if not from then
		resetFor(LevelDirector.GetCurrentLevel())
		return
	end
	local list = table.clone(participants)
	local survivorIndices, leftBehindIndices = CheckpointAirlockService.splitSurvivors(occupants())
	local survivors: { Player } = {}
	for _, index in survivorIndices do
		table.insert(survivors, list[index])
	end
	for _, index in leftBehindIndices do
		local player = list[index]
		LifeStateService.SetSpectating(player)
		hooks.despawn(player)
		notify(player, LEFT_BEHIND_KEY)
		log.info("%s left behind on %s", player.Name, from)
	end
	setDeadline(nil)
	phase = "Sealed"
	sealingSince = nil
	LevelDirector.MarkCleared()
	local to: Enums.LevelId? = LevelDirector.Advance()
	for _, player in survivors do
		RunStatsService.Increment(player, CLEARED_STAT)
		notify(player, SEALED_KEY)
	end
	log.info("%s cleared by %d of %d", from, #survivors, #list)
	floorCleared:Fire(from, survivors)
	if to then
		respawnEliminated(to)
		sealedSignal:Fire(from, to)
	end
end

-- One airlock pass (GameConfig.ServerTickHz; specs call it directly).
function CheckpointAirlockService.Poll()
	if not live then
		return
	end
	local current: Enums.LevelId? = LevelDirector.GetCurrentLevel()
	if current ~= levelId then
		resetFor(current)
	end
	if levelId == nil or exitRoomId == nil then
		return
	end
	resolve(false)
	local sealing = phase == "Sealing"
	if #volumes == 0 and not sealing then
		return -- the level has no checkpoint volume yet: nothing to wait in
	end
	local now = clock.now()
	if phase == "Idle" then
		if CheckpointAirlockService.startsWaiting(occupants()) then
			beginWaiting()
		else
			return
		end
	end
	if phase == "Waiting" then
		local verdict = CheckpointAirlockService.sealVerdict(occupants(), now, deadline or now)
		if verdict == "Seal" then
			seal()
		elseif verdict == "Reset" then
			setDeadline(nil)
			phase = "Idle"
			log.info("%s airlock reset: nobody waited inside", levelId or "?")
			return
		else
			return
		end
	end
	if phase == "Sealing" then
		local since = sealingSince or now
		if doorsShut() or now - since >= SEAL_TIMEOUT then
			finalize()
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function CheckpointAirlockService.GetPhase(): AirlockPhase
	return phase
end

-- The current airlock's straggler deadline (server time), while Waiting or Sealing.
function CheckpointAirlockService.GetDeadline(): number?
	return deadline
end

-- Seals the current airlock now, as if the straggler timer had run out (dev / scripted). False outside a run, on
-- a level without an exit airlock, or when it is already sealing or sealed.
function CheckpointAirlockService.Seal(): boolean
	if not live then
		return false
	end
	local current: Enums.LevelId? = LevelDirector.GetCurrentLevel()
	if current ~= levelId then
		resetFor(current)
	end
	if levelId == nil or exitRoomId == nil or (phase ~= "Idle" and phase ~= "Waiting") then
		return false
	end
	resolve(true)
	if phase == "Idle" then
		setDeadline(clock.now())
	end
	seal()
	CheckpointAirlockService.Poll()
	return true
end

-- Replaces the time source (specs pass a fake clock; nil restores server time).
function CheckpointAirlockService.SetClock(fake: Clock?)
	clock = fake or realClock
end

-- Replaces how characters are despawned and spawned (specs; nil restores CharacterService).
function CheckpointAirlockService.SetCharacterHooks(fake: CharacterHooks?)
	hooks = fake or realHooks
end

--------------------------------------------------------------------------------
-- Dev commands
--------------------------------------------------------------------------------

local function sealCommand(_player: Player, _args: { string }): string?
	local level: Enums.LevelId? = LevelDirector.GetCurrentLevel()
	if not live or level == nil then
		return "no run in progress"
	end
	if CheckpointAirlockService.exitRoom(level) == nil then
		return level .. " has no exit airlock"
	end
	if not CheckpointAirlockService.Seal() then
		return string.format("the %s airlock is already %s", level, string.lower(phase))
	end
	return string.format("%s airlock: %s", level, string.lower(phase))
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function onPhaseChanged(matchPhase: Enums.MatchPhase)
	live = running and LIVE_PHASES[matchPhase] == true
end

function CheckpointAirlockService.Init()
	if initialized then
		return
	end
	initialized = true
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(onPhaseChanged))
	DevToolsService.Register(
		"seal",
		"seal: seal the current floor's stairwell airlock now (as if its straggler timer ran out)",
		sealCommand
	)
end

function CheckpointAirlockService.Start()
	local interval = 1 / GameConfig.ServerTickHz
	local accumulated = 0
	serviceTrove:Connect(RunService.Heartbeat, function(dt: number)
		accumulated += dt
		if accumulated < interval then
			return
		end
		accumulated = 0
		xpcall(CheckpointAirlockService.Poll, function(err: any)
			log.warnThrottled("poll", 10, "airlock poll failed: %s", tostring(err))
		end)
	end)
end

function CheckpointAirlockService.BeginRun(ctx: Types.RunContext)
	participants = table.clone(ctx.participants)
	running = true
	live = true
	resetFor(LevelDirector.GetCurrentLevel())
end

function CheckpointAirlockService.EndRun()
	running = false
	live = false
	resetFor(nil)
	table.clear(participants)
end

function CheckpointAirlockService.OnPlayerRemoving(player: Player)
	local index = table.find(participants, player)
	if not index then
		return
	end
	table.remove(participants, index)
	if live then
		CheckpointAirlockService.Poll()
	end
end

return CheckpointAirlockService
