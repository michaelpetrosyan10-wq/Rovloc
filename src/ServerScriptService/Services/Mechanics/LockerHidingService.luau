--!strict
-- LockerHidingService: the Level 3 hideable lockers and the hold-breath check (spec, Level 3; ARCHITECTURE §4c). The
-- only writer of a HideableLocker's OccupantUserId and DoorOpen and of its door leaf's pose after the build.
--
-- Lockers. Every HideableLocker-tagged Model under Workspace.Runtime is tracked (CollectionService added / removed,
-- plus a scan at BeginRun: WorldService rebuilds the run's fixtures in its own BeginRun before this one). A locker is
-- Free, Entering, Hidden (one occupant), Exiting or Smashed (its door torn off by the Creature: never usable again this
-- run). The Hide prompt (InteractionService, its 0.25 s hold) serves every unsmashed locker, except one that Floor 3's
-- key search holds ajar (SetSearchOpen: ObjectiveService swings a Free locker's door to SearchOpen and back).
--
-- Getting in (canHide: the run is live, Alive with a living body, no control lock, on foot (Standing / Sprinting /
-- Crouching), not hiding already, the locker Free, and the Creature not chasing this player; refusals that matter
-- are told with Hud.LockerOccupied / Hud.LockerSeen). At once: OccupantUserId, CharacterService.Lock(player,
-- "Locker", "Anchor"), the "Hiding" MoveState override (WalkSpeed 0, never seen by the Creature), the torch switched
-- off (FlashlightService.ForceOff: its beam would only blind the slits), and the door swinging open from
-- GameConfig.OneShotLead from now (LockerMotion.enterSchedule). When it is open the body is moved inside (the
-- HideAnchor, facing out through the slits); then the door swings shut and the occupant is settled (RunStats
-- LockersHidden). Teammates cannot enter an occupied or moving locker.
--
-- Getting out (ExitHide, or the prompt key in the client's Locker context): only while settled and not under a
-- check, and only to a clear spot (the ExitAnchor 2.2 studs in front of the door, else a step to either side, else
-- one further out; none clear refuses with Hud.LockerBlocked). The door opens, the body is moved out facing away from
-- the locker, the lock and override are released and OccupantUserId cleared; then the door shuts and the locker is
-- Free again. Dying, going Downed, losing the character, leaving, the run ending or the locker disappearing releases
-- the occupant the same way (out to a clear spot when there is a living body, else where they are).
--
-- Doors are server-stepped on Heartbeat (collision follows them) and announced on OneShot "Door" / "LockerRip" with
-- DoorMotion args (+ LockerMotion.Args phase / occupant), so every client renders the same motion smoothly. DoorOpen
-- is true from the start of an opening until a shut has landed (and for good once ripped). LockerDoor cues at the door.
--
-- The inspector (MonsterAIService.RegisterLockerInspector; InvestigateNoise calls it in its own thread when it stands
-- hunched at the door). Inspect yields until it has a verdict:
--   * Empty (nobody inside, or the occupant already on the way out): "Empty" after LockerMotion.EmptyPeekSeconds.
--   * Occupied: the hold-breath check. The Creature's peek lasts a seeded LockerMotion.PeekMin..PeekMax; the window
--     opens LockerMotion.WarnSeconds after the check starts (after the occupant is settled, for one still climbing
--     in). PrivateCue "BreathCheck" Window (startAt / endsAt = the window, args warnAt, the server's lungs) to the
--     occupant; the CreatureSniff loop at the slits outside for everyone. The occupant holds (BreathInput held = true):
--     their lungs drain while held and recover while released (LockerMotion; judged on the server's clock as the
--     inputs arrive). judge decides: a held breath running out from the check's start on ("OutOfBreath"), a release
--     inside the window with less than CalmFraction left ("Gasp"), or not holding inside the window for longer than
--     ReholdGrace (a late start, or a quiet breath held too long: "Breathing") is caught; holding through the window
--     is "HiddenSafe". The Creature leaving the door (no longer InvestigateNoise: a stun, a louder noise) ends the
--     check safe.
--   * Caught: the gasp (Gasp cue at the slits for everyone, the Gasp noise from the occupant), a Result cue, and
--     "Caught". InvestigateNoise then calls tryCatch; right after, if JumpscareHandler is catching this occupant (the
--     catch took over), the door is ripped off (OneShot "LockerRip", LockerRip cue, the Smash pose stepped over
--     LockerMotion.RipSeconds), the Locker lock and the override are released (the catch's own Jumpscare lock holds the
--     body), OccupantUserId is cleared and the locker is Smashed. When that catch finishes with the victim still
--     playing, they are put down outside the locker (a clear spot). A catch that did not take (pacing, a stun) leaves
--     the occupant hidden: the gasp is still a noise, so it comes back.
-- Holding a breath to empty outside a check is a gasp too (the cue and the noise): the lungs give out.
--
-- Dev commands: hide (the nearest free locker on your level), unhide, breathcheck [seconds] (a scripted check on your
-- locker, as if the Creature were at the door), lockers (read-only summary).
--
-- Pure rules (tests/Specs/Lockers.spec.luau): canHide, canExit, judge, peekSeconds, exitCandidates, rootCFrameAt.
-- SetDependencies swaps the clock, the body moves, locks, overrides, the senders, the audio, the noise bus, the
-- Creature's state and the catch probe, so specs hide, check and catch on a fake clock.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local DoorMotion = require(ReplicatedStorage.Shared.Sequence.DoorMotion)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LockerMotion = require(ReplicatedStorage.Shared.Sequence.LockerMotion)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local AudioService = require(ServerScriptService.Services.Core.AudioService)
local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local FlashlightService = require(ServerScriptService.Services.Player.FlashlightService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local MonsterAIService = require(ServerScriptService.Services.Monster.MonsterAIService)
local JumpscareHandler = require(ServerScriptService.Services.Monster.MonsterAIService.JumpscareHandler)

local log = Log.new("Lockers")

local P = Attributes.Player
local M = Attributes.Match
local W = Attributes.World
local ARGS = LockerMotion.Args
local CUE = LockerMotion.CueArgs
local CUE_PHASE = LockerMotion.CuePhases

local LOCK_REASON: Enums.ControlLock = "Locker"
local LOCK_MODE: Enums.LockMode = "Anchor"
local OVERRIDE_TOKEN = "Locker"
local HIDING: Enums.MoveState = "Hiding"
local HIDE_KIND: Enums.PromptKind = "Hide"
local HIDDEN_STAT: Enums.StatKey = "LockersHidden"
local GASP_NOISE: Enums.NoiseKind = "Gasp"
local DOOR_ONESHOT: Enums.OneShotKind = "Door"
local RIP_ONESHOT: Enums.OneShotKind = "LockerRip"
local CHECK_CUE: Enums.CueKind = "BreathCheck"
local CATCH_KIND: Enums.JumpscareKind = "Locker"
local DOOR_PRESET = "LockerDoor"
local GASP_PRESET = "Gasp"
local SNIFF_PRESET = "CreatureSniff"
local RIP_PRESET = "LockerRip"
local OCCUPIED_HINT = "Hud.LockerOccupied"
local SEEN_HINT = "Hud.LockerSeen"
local BLOCKED_HINT = "Hud.LockerBlocked"
local DEFAULT_LEVEL: Enums.LevelId = "Level3_Gymnasium"

local HIDE_ANCHOR = "HideAnchor"
local PEEK_ANCHOR = "PeekAnchor"
local EXIT_ANCHOR = "ExitAnchor"

local LEAD = GameConfig.OneShotLead
local SEARCH_OPEN = ObjectiveConfig.Tuning.SearchOpen
local SLIT_OUT = 0.45 -- studs from the peeking eye out through the door to the slits' outer face
local EXIT_SIDE = 1.6 -- a blocked exit spot tries this far to either side
local EXIT_FURTHER = 1.2 -- ... then this much further out
local CLEAR_SIZE = Vector3.new(1.8, 4.2, 1.1) -- a standing body, from just above the floor
local CLEAR_LIFT = 0.5
local DEFAULT_ROOT_HEIGHT = 3 -- R15: HipHeight 2 + half the 2-stud root
local DEV_CHECK_SECONDS = 5
local AT_DOOR = 8 -- the Creature farther than this from the exit anchor has left the door (InvestigateNoise reach)

local ON_FOOT: { [string]: boolean } = { Standing = true, Sprinting = true, Crouching = true }
local LIVE_PHASES: { [string]: boolean } = { Deploying = true, InRun = true }
local CHASES: { [string]: boolean } = { WallChase = true, VentChase = true }

export type LockerState = "Free" | "Entering" | "Hidden" | "Exiting" | "Smashed"

export type Reason = "OutOfBreath" | "Gasp" | "Breathing" | "Held" | "Left" | "Gone"

-- Everything canHide looks at (gathered from the world; specs build it by hand).
export type HideCheck = {
	live: boolean,
	lifeState: Enums.LifeState,
	hasBody: boolean,
	controlLock: Enums.ControlLock,
	moveState: Enums.MoveState,
	hiding: boolean, -- already in (or on the way into / out of) a locker
	lockerState: LockerState,
	chasedBy: boolean, -- the Creature is chasing this player
}

export type ExitCheck = {
	lockerState: LockerState,
	occupant: boolean, -- the asker is this locker's occupant
	checking: boolean, -- a breath check is running on it
	spotFound: boolean,
}

-- What judge looks at: the check's times and the occupant's lungs (changed last at breath.at).
export type CheckView = {
	startedAt: number, -- the Creature began its peek (the warning)
	windowStart: number,
	windowEnd: number,
	breath: LockerMotion.Breath,
}

-- The services this one drives (each nil field of Dependencies keeps the real one).
export type Dependencies = {
	now: (() -> number)?,
	teleport: ((player: Player, cframe: CFrame) -> boolean)?,
	lock: ((player: Player) -> ())?,
	unlock: ((player: Player) -> ())?,
	pushOverride: ((player: Player) -> ())?,
	popOverride: ((player: Player) -> ())?,
	lifeState: ((player: Player) -> Enums.LifeState)?,
	moveState: ((player: Player) -> Enums.MoveState)?,
	controlLock: ((player: Player) -> Enums.ControlLock)?,
	body: ((player: Player) -> (CFrame?, number))?, -- a living root's CFrame and its height above the feet
	clear: ((cframe: CFrame, locker: Model) -> boolean)?, -- a body fits standing at this floor point
	oneShot: ((
		kind: Enums.OneShotKind,
		startAt: number,
		args: { [string]: Types.OneShotArg },
		subject: Instance?
	) -> ())?,
	cue: ((player: Player, payload: Types.PrivateCuePayload) -> ())?,
	notify: ((player: Player, key: string) -> ())?,
	playAt: ((preset: string, position: Vector3, options: AudioService.CueOptions?) -> AudioService.CueHandle?)?,
	emit: ((position: Vector3, kind: Enums.NoiseKind, source: Player?, levelId: string?) -> ())?,
	monsterState: (() -> Enums.MonsterState)?,
	creatureAt: (() -> Vector3?)?, -- the Creature's root
	chaser: (() -> Player?)?, -- the player the Creature is chasing
	victim: (() -> Player?)?, -- the player JumpscareHandler is catching
	stat: ((player: Player, key: Enums.StatKey) -> ())?,
	refresh: ((host: Instance) -> ())?,
	torchOff: ((player: Player) -> ())?,
}

type Check = {
	locker: Locker,
	occupant: Player,
	startedAt: number,
	windowStart: number,
	windowEnd: number,
	verdict: Types.LockerVerdict?,
	reason: Reason?,
	waiters: { thread },
	sniff: AudioService.CueHandle?,
	scripted: boolean, -- a dev check: no Creature at the door
	cued: boolean, -- the Window cue went out
}

type Peek = { locker: Locker, resolveAt: number, waiters: { thread } }

export type Locker = {
	model: Model,
	base: BasePart,
	levelId: string?,
	state: LockerState,
	occupant: Player?,
	motion: DoorMotion.Motion?,
	motionId: number,
	schedule: LockerMotion.Schedule?, -- the running move in / out
	moved: boolean, -- the schedule's body move happened
	closing: boolean, -- the schedule's shut was sent
	exitSpot: CFrame?, -- where the occupant leaving is put (root CFrame)
	check: Check?,
	searchOpen: boolean?, -- Floor 3's key search holds the door ajar (no hiding while it stands open)
}

local LockerHidingService = {}

LockerHidingService.Name = "LockerHidingService"
LockerHidingService.OverrideToken = OVERRIDE_TOKEN
LockerHidingService.LockReason = LOCK_REASON
LockerHidingService.OccupiedHint = OCCUPIED_HINT
LockerHidingService.SeenHint = SEEN_HINT
LockerHidingService.BlockedHint = BLOCKED_HINT
LockerHidingService.ExitSide = EXIT_SIDE
LockerHidingService.ExitFurther = EXIT_FURTHER

local hidden: Signal.Signal<Player, Model> = Signal.new()
local left: Signal.Signal<Player, Model> = Signal.new()
local checked: Signal.Signal<Player, Model, Types.LockerVerdict> = Signal.new()

-- (player, locker) once a player is settled inside.
LockerHidingService.Hidden = hidden
-- (player, locker) once an occupant is out (or was released).
LockerHidingService.Left = left
-- (occupant, locker, verdict) when a breath check ends ("HiddenSafe" or "Caught").
LockerHidingService.Checked = checked

local serviceTrove = Trove.new()
local deps: Dependencies = {}
local lockers: { [Instance]: Locker } = {}
local occupancy: { [Player]: Locker } = {}
local breaths: { [Player]: LockerMotion.Breath } = {}
local peeks: { Peek } = {}
local taken: { [Player]: Locker } = {} -- victims handed to a Locker catch, put down outside when it ends
local running = false
local live = false
local random = Random.new(1)
local oneShotSeq = 0
local initialized = false

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/Lockers.spec.luau)
--------------------------------------------------------------------------------

-- Whether a player may climb into a locker, and why not.
function LockerHidingService.canHide(check: HideCheck): (boolean, string?)
	if not check.live then
		return false, "NotLive"
	end
	if check.lifeState ~= "Alive" then
		return false, "LifeState"
	end
	if not check.hasBody then
		return false, "NoBody"
	end
	if check.hiding then
		return false, "Hiding"
	end
	if check.lockerState ~= "Free" then
		return false, OCCUPIED_HINT
	end
	if check.controlLock ~= "None" then
		return false, "Locked"
	end
	if not ON_FOOT[check.moveState] then
		return false, "Posture"
	end
	if check.chasedBy then
		return false, SEEN_HINT
	end
	return true, nil
end

-- Whether an occupant may step out now, and why not.
function LockerHidingService.canExit(check: ExitCheck): (boolean, string?)
	if not check.occupant then
		return false, "NotOccupant"
	end
	if check.lockerState ~= "Hidden" then
		return false, "Moving"
	end
	if check.checking then
		return false, "Checking"
	end
	if not check.spotFound then
		return false, BLOCKED_HINT
	end
	return true, nil
end

-- The verdict of a breath check at server time `now`, if it has one: (verdict, reason, the instant it was decided).
-- The occupant's lungs are unchanged since breath.at (call it before and after every change of hold).
function LockerHidingService.judge(view: CheckView, now: number): (Types.LockerVerdict?, Reason?, number?)
	local breath = view.breath
	local empty = LockerMotion.emptyAt(breath)
	if empty and empty <= now and empty >= view.startedAt and empty < view.windowEnd then
		return "Caught", "OutOfBreath", empty
	end
	if now < view.windowStart then
		return nil, nil, nil
	end
	if not breath.held then
		local inWindow = breath.at >= view.windowStart and breath.at < view.windowEnd
		if inWindow and not LockerMotion.calm(breath.value) then
			return "Caught", "Gasp", breath.at
		end
		local heard = math.max(breath.at, view.windowStart) + LockerMotion.ReholdGrace
		if heard < view.windowEnd and heard <= now then
			return "Caught", "Breathing", heard
		end
	end
	if now >= view.windowEnd then
		return "HiddenSafe", "Held", view.windowEnd
	end
	return nil, nil, nil
end

-- How long the Creature peeks through the slits (seeded).
function LockerHidingService.peekSeconds(source: Random): number
	return source:NextNumber(LockerMotion.PeekMin, LockerMotion.PeekMax)
end

-- Where a leaving occupant may stand, best first: the exit anchor, a step to either side, one further out (floor
-- CFrames facing away from the locker).
function LockerHidingService.exitCandidates(exitAnchor: CFrame): { CFrame }
	return {
		exitAnchor,
		exitAnchor * CFrame.new(EXIT_SIDE, 0, 0),
		exitAnchor * CFrame.new(-EXIT_SIDE, 0, 0),
		exitAnchor * CFrame.new(0, 0, -EXIT_FURTHER),
	}
end

-- The root CFrame of a body standing at floor point `floor` (its facing kept), `rootHeight` above it.
function LockerHidingService.rootCFrameAt(floor: CFrame, rootHeight: number): CFrame
	return floor * CFrame.new(0, rootHeight, 0)
end

--------------------------------------------------------------------------------
-- Dependencies
--------------------------------------------------------------------------------

local function serverNow(): number
	local fake = deps.now
	return if fake then fake() else Workspace:GetServerTimeNow()
end

local function livingBody(player: Player): (CFrame?, number)
	local fake = deps.body
	if fake then
		return fake(player)
	end
	local root = Instances.characterRoot(player)
	local humanoid = Instances.characterHumanoid(player)
	if root and humanoid and humanoid.Health > 0 then
		return root.CFrame, humanoid.HipHeight + root.Size.Y / 2
	end
	return nil, DEFAULT_ROOT_HEIGHT
end

local function teleport(player: Player, cframe: CFrame): boolean
	local fake = deps.teleport
	if fake then
		return fake(player, cframe)
	end
	return CharacterService.Teleport(player, cframe)
end

local function hold(player: Player)
	local fake = deps.lock
	if fake then
		fake(player)
	else
		CharacterService.Lock(player, LOCK_REASON, LOCK_MODE)
	end
	local push = deps.pushOverride
	if push then
		push(player)
	else
		PlayerStateService.PushOverride(player, OVERRIDE_TOKEN, HIDING)
	end
end

local function letGo(player: Player)
	local pop = deps.popOverride
	if pop then
		pop(player)
	else
		PlayerStateService.PopOverride(player, OVERRIDE_TOKEN)
	end
	local fake = deps.unlock
	if fake then
		fake(player)
	else
		CharacterService.Unlock(player, LOCK_REASON)
	end
end

local function lifeStateOf(player: Player): Enums.LifeState
	local fake = deps.lifeState
	return if fake then fake(player) else LifeStateService.GetState(player)
end

local function moveStateOf(player: Player): Enums.MoveState
	local fake = deps.moveState
	return if fake then fake(player) else PlayerStateService.GetMoveState(player)
end

local function controlLockOf(player: Player): Enums.ControlLock
	local fake = deps.controlLock
	return if fake then fake(player) else CharacterService.GetLock(player)
end

local function characters(): { Instance }
	local list: { Instance } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(list, character)
		end
	end
	local creature = Instances.creature()
	if creature then
		table.insert(list, creature)
	end
	return list
end

-- Whether a standing body fits at floor point `floor` (nothing a player collides with in the way; characters, the
-- Creature and the locker itself ignored).
local function spotClear(floor: CFrame, locker: Model): boolean
	local fake = deps.clear
	if fake then
		return fake(floor, locker)
	end
	local exclude = characters()
	table.insert(exclude, locker)
	local params = SpatialQuery.overlapParams(exclude, CollisionGroups.Players)
	local box = floor * CFrame.new(0, CLEAR_LIFT + CLEAR_SIZE.Y / 2, 0)
	for _, part in Workspace:GetPartBoundsInBox(box, CLEAR_SIZE, params) do
		if part.CanCollide then
			return false
		end
	end
	return true
end

local function sendOneShot(
	kind: Enums.OneShotKind,
	startAt: number,
	args: { [string]: Types.OneShotArg },
	subject: Instance?
)
	local fake = deps.oneShot
	if fake then
		fake(kind, startAt, args, subject)
		return
	end
	oneShotSeq += 1
	local event: Types.OneShotEvent =
		{ seq = oneShotSeq, kind = kind, subject = subject, startAt = startAt, args = args }
	Net.Server.fireAll("OneShot", event)
end

local function sendCue(player: Player, payload: Types.PrivateCuePayload)
	local fake = deps.cue
	if fake then
		fake(player, payload)
		return
	end
	if player.Parent == Players then
		Net.Server.fire("PrivateCue", player, payload)
	end
end

local function notify(player: Player, key: string)
	local fake = deps.notify
	if fake then
		fake(player, key)
		return
	end
	if player.Parent == Players then
		local payload: Types.NotifyPayload = { key = key, args = {} }
		Net.Server.fire("Notify", player, payload)
	end
end

local function playAt(preset: string, position: Vector3, options: AudioService.CueOptions?): AudioService.CueHandle?
	local fake = deps.playAt
	if fake then
		return fake(preset, position, options)
	end
	return AudioService.PlayAt(preset, position, options)
end

local function emitNoise(position: Vector3, kind: Enums.NoiseKind, source: Player?, levelId: string?)
	local fake = deps.emit
	if fake then
		fake(position, kind, source, levelId)
		return
	end
	local level: Enums.LevelId? = if levelId and Enums.has(Enums.LevelId, levelId)
		then levelId :: Enums.LevelId
		else nil
	NoiseAndDirectorService.Emit(position, kind, { sourcePlayer = source, levelId = level })
end

local function monsterState(): Enums.MonsterState
	local fake = deps.monsterState
	return if fake then fake() else MonsterAIService.GetState()
end

local function creaturePosition(): Vector3?
	local fake = deps.creatureAt
	if fake then
		return fake()
	end
	local creature = MonsterAIService.GetCreature()
	local root = if creature then creature.PrimaryPart else nil
	return if root then root.CFrame.Position else nil
end

local function chaser(): Player?
	local fake = deps.chaser
	if fake then
		return fake()
	end
	return if CHASES[MonsterAIService.GetState()] then MonsterAIService.GetTarget() else nil
end

local function catchVictim(): Player?
	local fake = deps.victim
	return if fake then fake() else JumpscareHandler.GetVictim()
end

local function addStat(player: Player, key: Enums.StatKey)
	local fake = deps.stat
	if fake then
		fake(player, key)
	else
		RunStatsService.Increment(player, key)
	end
end

local function refreshPrompt(locker: Locker)
	if locker.model.Parent == nil then
		return
	end
	local fake = deps.refresh
	if fake then
		fake(locker.model)
		return
	end
	xpcall(InteractionService.Refresh, function(err: any)
		log.warnThrottled("refresh", 10, "prompt refresh on %s failed: %s", locker.model:GetFullName(), tostring(err))
	end, locker.model)
end

local function torchOff(player: Player)
	local fake = deps.torchOff
	if fake then
		fake(player)
	else
		FlashlightService.ForceOff(player)
	end
end

-- Swaps in fakes (nil restores every real dependency).
function LockerHidingService.SetDependencies(fake: Dependencies?)
	deps = fake or {}
end

--------------------------------------------------------------------------------
-- Locker geometry
--------------------------------------------------------------------------------

local function anchorWorld(locker: Locker, name: string): CFrame?
	local attachment = locker.base:FindFirstChild(name)
	if attachment and attachment:IsA("Attachment") then
		return locker.base.CFrame * attachment.CFrame
	end
	return nil
end

-- The hidden player's eye behind the slits (looking out).
local function peekOf(locker: Locker): CFrame
	return anchorWorld(locker, PEEK_ANCHOR) or locker.base.CFrame
end

-- The slits' outer face: where the Creature breathes in at you.
local function slitOf(locker: Locker): Vector3
	local peek = peekOf(locker)
	return (peek * CFrame.new(0, 0, -SLIT_OUT)).Position
end

local function doorPoint(locker: Locker): Vector3
	return (peekOf(locker) * CFrame.new(0, -1.2, -SLIT_OUT)).Position
end

local function levelOf(model: Model): string?
	local value = model:GetAttribute(W.LevelId)
	return if type(value) == "string" then value else nil
end

local function playerLevel(player: Player): Enums.LevelId
	for _, value in { player:GetAttribute(P.LevelId), ReplicatedStorage:GetAttribute(M.CurrentLevel) } do
		if type(value) == "string" and Enums.has(Enums.LevelId, value) then
			return value :: Enums.LevelId
		end
	end
	return DEFAULT_LEVEL
end

-- The first clear spot a body can step out to (root CFrame), or nil.
local function findExitSpot(locker: Locker, rootHeight: number): CFrame?
	local exit = anchorWorld(locker, EXIT_ANCHOR)
	if not exit then
		return nil
	end
	for _, floor in LockerHidingService.exitCandidates(exit) do
		if spotClear(floor, locker.model) then
			return LockerHidingService.rootCFrameAt(floor, rootHeight)
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Doors
--------------------------------------------------------------------------------

local function setDoorOpen(locker: Locker, open: boolean)
	Attributes.set(locker.model, W.DoorOpen, open)
end

-- Starts a door motion `from` -> `to` at `startAt`, stepped here and announced to every client.
local function startDoor(
	locker: Locker,
	mode: DoorMotion.Mode,
	from: number,
	to: number,
	seconds: number,
	startAt: number,
	phase: LockerMotion.Phase,
	occupant: Player?
)
	locker.motionId += 1
	local motion: DoorMotion.Motion = {
		mode = mode,
		from = from,
		to = to,
		startAt = startAt,
		seconds = seconds,
		ease = if mode == "Smash" then "Linear" else "InOut",
		smashFrom = 0,
	}
	locker.motion = motion
	local message: DoorMotion.Message = {
		doorId = Attributes.getString(locker.model, W.AnchorId, locker.model.Name),
		levelId = locker.levelId or "",
		motionId = locker.motionId,
		state = if mode == "Smash" then "Smashed" elseif to > 0 then "Open" else "Closed",
		held = false,
		motion = motion,
	}
	local args = DoorMotion.toArgs(message)
	args[ARGS.Phase] = phase
	args[ARGS.Occupant] = if occupant then occupant.UserId else 0
	sendOneShot(if mode == "Smash" then RIP_ONESHOT else DOOR_ONESHOT, startAt, args, locker.model)
	if mode == "Smash" or to > 0 then
		setDoorOpen(locker, true)
	end
	local preset = if mode == "Smash" then RIP_PRESET else DOOR_PRESET
	playAt(preset, doorPoint(locker), { delay = math.max(0, startAt - serverNow()) })
end

-- Poses every moving door at server time `now`.
local function stepDoors(now: number)
	for _, locker in lockers do
		local motion = locker.motion
		if not motion then
			continue
		end
		local value, done = DoorMotion.valueAt(motion, now)
		if locker.model.Parent ~= nil then
			LockerMotion.pose(locker.model, motion.mode, value)
		end
		if done then
			locker.motion = nil
			if motion.mode == "Swing" and motion.to <= 0 then
				setDoorOpen(locker, false)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Waiting inspectors
--------------------------------------------------------------------------------

local function await(waiters: { thread }): Types.LockerVerdict
	table.insert(waiters, coroutine.running())
	local verdict = coroutine.yield()
	if verdict == "Caught" or verdict == "HiddenSafe" then
		return verdict
	end
	return "Empty"
end

local function wake(waiters: { thread }, verdict: Types.LockerVerdict)
	local list = table.clone(waiters)
	table.clear(waiters)
	for _, thread in list do
		if coroutine.status(thread) == "suspended" then
			local ok, err = coroutine.resume(thread, verdict)
			if not ok then
				log.warnThrottled("inspector", 10, "locker inspector failed after its verdict: %s", tostring(err))
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Checks
--------------------------------------------------------------------------------

local function breathOf(player: Player, now: number): LockerMotion.Breath
	local breath = breaths[player]
	if not breath then
		breath = LockerMotion.fullBreath(now)
		breaths[player] = breath
	end
	return breath
end

local function meterCue(player: Player, breath: LockerMotion.Breath)
	sendCue(player, {
		kind = CHECK_CUE,
		startAt = breath.at,
		endsAt = nil,
		args = {
			[CUE.Phase] = CUE_PHASE.Meter,
			[CUE.Breath] = breath.value,
			[CUE.Held] = breath.held,
			[CUE.BreathAt] = breath.at,
		},
	})
end

local function resultCue(player: Player, verdict: string, reason: Reason, at: number)
	sendCue(player, {
		kind = CHECK_CUE,
		startAt = at,
		endsAt = at,
		args = { [CUE.Phase] = CUE_PHASE.Result, [CUE.Verdict] = verdict, [CUE.Reason] = reason },
	})
end

local function windowCue(check: Check, breath: LockerMotion.Breath)
	check.cued = true
	sendCue(check.occupant, {
		kind = CHECK_CUE,
		startAt = check.windowStart,
		endsAt = check.windowEnd,
		args = {
			[CUE.Phase] = CUE_PHASE.Window,
			[CUE.WarnAt] = check.startedAt,
			[CUE.Breath] = breath.value,
			[CUE.Held] = breath.held,
			[CUE.BreathAt] = breath.at,
		},
	})
end

-- The lungs give out (or let go at the worst moment): a loud gasp and the noise it makes.
local function gasp(locker: Locker, player: Player, at: number)
	local breath = breathOf(player, at)
	breaths[player] = { value = LockerMotion.breathAt(breath, at), held = false, at = at }
	local mouth = peekOf(locker).Position
	playAt(GASP_PRESET, mouth, nil)
	emitNoise(mouth, GASP_NOISE, player, locker.levelId)
	meterCue(player, breaths[player])
end

local function stopSniff(check: Check)
	local handle = check.sniff
	check.sniff = nil
	if handle then
		handle:Stop(0.4)
	end
end

local releaseOccupant: (locker: Locker, outside: boolean) -> ()

-- The catch took over: the door is torn off and the body handed to JumpscareHandler.
local function handOver(locker: Locker, occupant: Player, now: number)
	locker.state = "Smashed"
	locker.schedule = nil
	locker.check = nil
	startDoor(locker, "Smash", 0, 1, LockerMotion.RipSeconds, now + LEAD, "Rip", occupant)
	occupancy[occupant] = nil
	breaths[occupant] = nil
	locker.occupant = nil
	Attributes.set(locker.model, W.OccupantUserId, nil)
	letGo(occupant)
	taken[occupant] = locker
	refreshPrompt(locker)
	left:Fire(occupant, locker.model)
end

local function finishCheck(check: Check, verdict: Types.LockerVerdict, reason: Reason, at: number)
	if check.verdict ~= nil then
		return
	end
	check.verdict = verdict
	check.reason = reason
	local locker = check.locker
	local occupant = check.occupant
	stopSniff(check)
	if verdict == "Caught" then
		gasp(locker, occupant, at)
	end
	if verdict ~= "Empty" then
		resultCue(occupant, verdict, reason, at)
	end
	if locker.check == check then
		locker.check = nil
	end
	-- The inspector returns now: InvestigateNoise tries the catch in that same thread.
	wake(check.waiters, verdict)
	if verdict ~= "Empty" then
		checked:Fire(occupant, locker.model, verdict)
	end
	if verdict ~= "Caught" or check.scripted then
		return
	end
	if catchVictim() == occupant and occupancy[occupant] == locker then
		handOver(locker, occupant, serverNow())
	else
		log.debug("%s gasped in %s but no catch followed", occupant.Name, locker.model.Name)
	end
end

-- Whether the Creature is still peeking: investigating, and standing at the door.
local function creatureAtDoor(locker: Locker): boolean
	if monsterState() ~= "InvestigateNoise" then
		return false
	end
	local at = creaturePosition()
	local front = anchorWorld(locker, EXIT_ANCHOR)
	if not (at and front) then
		return false
	end
	return MathUtil.horizontalDistance(at, front.Position) <= AT_DOOR
end

-- Advances `check` to `now` (the lungs unchanged since their last record).
local function advanceCheck(check: Check, now: number)
	if check.verdict ~= nil then
		return
	end
	local occupant = check.occupant
	local locker = check.locker
	if occupancy[occupant] ~= locker or locker.occupant ~= occupant then
		finishCheck(check, "Empty", "Gone", now)
		return
	end
	if not check.scripted and not creatureAtDoor(locker) then
		finishCheck(check, "HiddenSafe", "Left", now)
		return
	end
	if not check.cued and now >= check.startedAt then
		windowCue(check, breathOf(occupant, now))
	end
	local verdict, reason, at = LockerHidingService.judge({
		startedAt = check.startedAt,
		windowStart = check.windowStart,
		windowEnd = check.windowEnd,
		breath = breathOf(occupant, now),
	}, now)
	if verdict ~= nil and reason ~= nil and at ~= nil then
		-- casts, not the refined locals: refining the unions against nil widens them to string
		finishCheck(check, verdict :: Types.LockerVerdict, reason :: Reason, at)
	end
end

-- Starts the breath check on `locker`'s occupant (the window opens WarnSeconds after the occupant is settled).
local function startCheck(locker: Locker, occupant: Player, now: number, peek: number, scripted: boolean): Check
	local schedule = locker.schedule
	local warnAt = if locker.state == "Entering" and schedule then math.max(now, schedule.settledAt) else now
	local windowStart = warnAt + LockerMotion.WarnSeconds
	local check: Check = {
		locker = locker,
		occupant = occupant,
		startedAt = warnAt,
		windowStart = windowStart,
		windowEnd = windowStart + peek,
		verdict = nil,
		reason = nil,
		waiters = {},
		sniff = nil,
		scripted = scripted,
		cued = false,
	}
	locker.check = check
	if not scripted then
		check.sniff = playAt(SNIFF_PRESET, slitOf(locker), {
			delay = math.max(0, warnAt - now),
			duration = check.windowEnd - warnAt,
		})
	end
	advanceCheck(check, now)
	return check
end

--------------------------------------------------------------------------------
-- Getting in and out
--------------------------------------------------------------------------------

local function enter(player: Player, locker: Locker)
	local now = serverNow()
	locker.state = "Entering"
	locker.occupant = player
	locker.moved = false
	locker.closing = false
	occupancy[player] = locker
	breaths[player] = LockerMotion.fullBreath(now)
	Attributes.set(locker.model, W.OccupantUserId, player.UserId)
	hold(player)
	torchOff(player)
	local startAt = now + LEAD
	locker.schedule = LockerMotion.enterSchedule(startAt)
	startDoor(locker, "Swing", 0, 1, LockerMotion.OpenSeconds, startAt, "Enter", player)
	log.debug("%s climbs into %s", player.Name, locker.model.Name)
end

-- Starts getting `locker`'s occupant out to `spot` (nil: they stay where they are).
local function beginExit(locker: Locker, spot: CFrame?)
	local occupant = locker.occupant
	local now = serverNow()
	local check = locker.check
	if check then
		finishCheck(check, "Empty", "Gone", now)
	end
	locker.state = "Exiting"
	locker.exitSpot = spot
	locker.moved = false
	locker.closing = false
	local startAt = now + LEAD
	locker.schedule = LockerMotion.exitSchedule(startAt)
	local motion = locker.motion
	local from = if motion then (DoorMotion.valueAt(motion, now)) else 0
	startDoor(locker, "Swing", from, 1, LockerMotion.OpenSeconds * (1 - from), startAt, "Exit", occupant)
end

-- The occupant is out of the locker (moved out, or let go where they are).
local function vacate(locker: Locker)
	local occupant = locker.occupant
	locker.occupant = nil
	Attributes.set(locker.model, W.OccupantUserId, nil)
	if occupant then
		if occupancy[occupant] == locker then
			occupancy[occupant] = nil
		end
		breaths[occupant] = nil
		letGo(occupant)
		left:Fire(occupant, locker.model)
	end
end

-- Lets the occupant go at once: out to a clear spot when `outside` and they have a living body, else where they are.
-- The door opens behind them and shuts again.
releaseOccupant = function(locker: Locker, outside: boolean)
	local occupant = locker.occupant
	if not occupant then
		return
	end
	local spot: CFrame? = nil
	if outside then
		local root, height = livingBody(occupant)
		if root then
			spot = findExitSpot(locker, height)
		end
	end
	if locker.state ~= "Exiting" then
		beginExit(locker, spot)
	end
	if not locker.moved then
		locker.moved = true
		local target = spot or locker.exitSpot
		if target then
			teleport(occupant, target)
		end
		vacate(locker)
	end
end

-- Lets the occupant go where they are (no body to move: it died, left, or the run is ending). A door left open swings
-- shut while the run is live.
local function drop(locker: Locker)
	local now = serverNow()
	local check = locker.check
	if check then
		finishCheck(check, "Empty", "Gone", now)
	end
	locker.check = nil
	locker.schedule = nil
	vacate(locker)
	if locker.state == "Smashed" then
		return
	end
	locker.state = "Free"
	local motion = locker.motion
	local openness = if motion then (DoorMotion.valueAt(motion, now)) else 0
	local open = openness > 1e-3 or (motion ~= nil and motion.to > 0)
	if open and live and locker.model.Parent ~= nil then
		startDoor(locker, "Swing", openness, 0, LockerMotion.CloseSeconds * openness, now + LEAD, "Shut", nil)
	end
	refreshPrompt(locker)
end

local function stepSchedule(locker: Locker, now: number)
	local schedule = locker.schedule
	if not schedule then
		return
	end
	local occupant = locker.occupant
	if not locker.moved and now >= schedule.moveAt then
		locker.moved = true
		if locker.state == "Entering" and occupant then
			local hide = anchorWorld(locker, HIDE_ANCHOR)
			local _, height = livingBody(occupant)
			if hide then
				teleport(occupant, LockerHidingService.rootCFrameAt(hide, height))
			end
		elseif locker.state == "Exiting" then
			local spot = locker.exitSpot
			if occupant and spot then
				teleport(occupant, spot)
			end
			vacate(locker)
		end
	end
	if not locker.closing and now >= schedule.closeAt - LEAD then
		locker.closing = true
		startDoor(
			locker,
			"Swing",
			1,
			0,
			LockerMotion.CloseSeconds,
			math.max(schedule.closeAt, now),
			"Shut",
			locker.occupant
		)
	end
	if now >= schedule.settledAt and locker.closing and locker.motion == nil then
		locker.schedule = nil
		if locker.state == "Entering" then
			locker.state = "Hidden"
			if occupant then
				addStat(occupant, HIDDEN_STAT)
				hidden:Fire(occupant, locker.model)
			end
		elseif locker.state == "Exiting" then
			locker.state = "Free"
			refreshPrompt(locker)
		end
	end
end

--------------------------------------------------------------------------------
-- Interaction
--------------------------------------------------------------------------------

local function lockerOf(host: Instance): Locker?
	return lockers[host]
end

local function hideCheckFor(player: Player, locker: Locker): HideCheck
	local root = livingBody(player)
	return {
		live = live,
		lifeState = lifeStateOf(player),
		hasBody = root ~= nil,
		controlLock = controlLockOf(player),
		moveState = moveStateOf(player),
		hiding = occupancy[player] ~= nil,
		lockerState = locker.state,
		chasedBy = chaser() == player,
	}
end

LockerHidingService.HideHandler = {
	kind = HIDE_KIND,
	filter = function(host: Instance, _prompt: ProximityPrompt): boolean
		local locker = lockerOf(host)
		return locker ~= nil and locker.state ~= "Smashed" and locker.searchOpen ~= true
	end,
	canUse = function(player: Player, _prompt: ProximityPrompt, host: Instance): (boolean, string?)
		local locker = lockerOf(host)
		if not locker then
			return false, "Unknown"
		end
		return LockerHidingService.canHide(hideCheckFor(player, locker))
	end,
	onComplete = function(player: Player, _prompt: ProximityPrompt, host: Instance)
		local locker = lockerOf(host)
		if locker and LockerHidingService.canHide(hideCheckFor(player, locker)) then
			enter(player, locker)
		end
	end,
} :: InteractionService.Handler

--------------------------------------------------------------------------------
-- Tracking
--------------------------------------------------------------------------------

local function inRuntime(instance: Instance): boolean
	local runtime = Instances.runtime()
	return runtime ~= nil and instance:IsDescendantOf(runtime)
end

local function forget(model: Instance)
	local locker = lockers[model]
	if not locker then
		return
	end
	drop(locker)
	for player, gone in table.clone(taken) do
		if gone == locker then
			taken[player] = nil
		end
	end
	lockers[model] = nil
end

-- Tracks a HideableLocker model (WorldService's fixtures; specs track a built one). False when it is not a locker.
function LockerHidingService.Track(model: Model): boolean
	if lockers[model] then
		return true
	end
	local base = model.PrimaryPart
	if not (base and model:HasTag(Tags.HideableLocker)) then
		return false
	end
	local locker: Locker = {
		model = model,
		base = base,
		levelId = levelOf(model),
		state = "Free",
		occupant = nil,
		motion = nil,
		motionId = 0,
		schedule = nil,
		moved = false,
		closing = false,
		exitSpot = nil,
		check = nil,
	}
	lockers[model] = locker
	Attributes.set(model, W.DoorOpen, false)
	Attributes.set(model, W.OccupantUserId, nil)
	refreshPrompt(locker)
	return true
end

local function onLockerTagged(instance: Instance)
	if running and instance:IsA("Model") and inRuntime(instance) then
		LockerHidingService.Track(instance)
	end
end

local function onLockerUntagged(instance: Instance)
	forget(instance)
end

local function scan()
	for _, instance in CollectionService:GetTagged(Tags.HideableLocker) do
		onLockerTagged(instance)
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- The inspector MonsterAIService calls (in its own thread) when the Creature peeks into `instance` (see the header).
function LockerHidingService.Inspect(instance: Instance): Types.LockerVerdict
	local locker = lockers[instance]
	if not (locker and live) then
		return "Empty"
	end
	local now = serverNow()
	local current = locker.check
	if current and current.verdict == nil then
		return await(current.waiters)
	end
	local occupant = locker.occupant
	if occupant and (locker.state == "Hidden" or locker.state == "Entering") then
		local check = startCheck(locker, occupant, now, LockerHidingService.peekSeconds(random), false)
		if check.verdict ~= nil then
			return check.verdict :: Types.LockerVerdict
		end
		return await(check.waiters)
	end
	local peek: Peek = { locker = locker, resolveAt = now + LockerMotion.EmptyPeekSeconds, waiters = {} }
	table.insert(peeks, peek)
	return await(peek.waiters)
end

-- Starts a scripted breath check of `seconds` on `player`'s locker (no Creature needed; dev). False when they are
-- not settled in one or one is already running.
function LockerHidingService.StartCheck(player: Player, seconds: number?): boolean
	local locker = occupancy[player]
	if not (locker and live and locker.state == "Hidden" and locker.check == nil) then
		return false
	end
	local peek = math.clamp(seconds or DEV_CHECK_SECONDS, LockerMotion.PeekMin, LockerMotion.PeekMax)
	startCheck(locker, player, serverNow(), peek, true)
	return true
end

-- One step at server time `now`: door poses, the moves in and out, the checks and empty peeks (every Heartbeat;
-- specs drive it on a fake clock).
function LockerHidingService.Step(at: number?)
	if not running then
		return
	end
	local now = at or serverNow()
	stepDoors(now)
	for _, locker in lockers do
		stepSchedule(locker, now)
	end
	for player, breath in table.clone(breaths) do
		local locker = occupancy[player]
		local check = if locker then locker.check else nil
		if check then
			advanceCheck(check, now)
		end
		local empty = LockerMotion.emptyAt(breaths[player] or breath)
		if empty and empty <= now and locker then
			gasp(locker, player, empty)
		end
	end
	for _, locker in lockers do
		local check = locker.check
		if check then
			advanceCheck(check, now)
		end
	end
	for index = #peeks, 1, -1 do
		local peek = peeks[index]
		if now >= peek.resolveAt or lockers[peek.locker.model] == nil then
			table.remove(peeks, index)
			wake(peek.waiters, "Empty")
		end
	end
end

-- The occupant's hold changed (BreathInput; specs call it). False when they are not in a locker.
function LockerHidingService.SetHeld(player: Player, held: boolean): boolean
	local locker = occupancy[player]
	if not locker or locker.state == "Exiting" or locker.state == "Smashed" then
		return false
	end
	local now = serverNow()
	local check = locker.check
	if check then
		advanceCheck(check, now)
	end
	local current = occupancy[player]
	if current ~= locker then
		return false
	end
	local before = breathOf(player, now)
	local after = LockerMotion.setHeld(before, held, now)
	if after == before then
		return true
	end
	breaths[player] = after
	meterCue(player, after)
	local again = locker.check
	if again then
		advanceCheck(again, now)
	end
	return true
end

-- The occupant asks to step out (ExitHide; specs call it). False (with a reason) when refused.
function LockerHidingService.RequestExit(player: Player): (boolean, string?)
	local locker = occupancy[player]
	if not locker then
		return false, "NotOccupant"
	end
	local _, height = livingBody(player)
	local spot = if locker.state == "Hidden" and locker.check == nil then findExitSpot(locker, height) else nil
	local ok, reason = LockerHidingService.canExit({
		lockerState = locker.state,
		occupant = locker.occupant == player,
		checking = locker.check ~= nil,
		spotFound = spot ~= nil,
	})
	if not ok then
		if reason == BLOCKED_HINT then
			notify(player, BLOCKED_HINT)
		end
		return false, reason
	end
	beginExit(locker, spot)
	return true, nil
end

-- Releases `player` from any locker at once (out to a clear spot when they have a living body). False when they
-- were not in one.
function LockerHidingService.Release(player: Player): boolean
	local locker = occupancy[player]
	if not locker then
		return false
	end
	releaseOccupant(locker, true)
	return true
end

-- Puts `player` into `model` as if the prompt completed (dev / scripted). False when refused.
function LockerHidingService.Hide(player: Player, model: Model): boolean
	local locker = lockers[model]
	if not locker or not LockerHidingService.canHide(hideCheckFor(player, locker)) then
		return false
	end
	enter(player, locker)
	return true
end

function LockerHidingService.GetLockerOf(player: Player): Model?
	local locker = occupancy[player]
	return if locker then locker.model else nil
end

function LockerHidingService.GetOccupant(model: Model): Player?
	local locker = lockers[model]
	return if locker then locker.occupant else nil
end

function LockerHidingService.GetState(model: Model): LockerState?
	local locker = lockers[model]
	return if locker then locker.state else nil
end

function LockerHidingService.GetBreath(player: Player): number?
	local breath = breaths[player]
	return if breath then LockerMotion.breathAt(breath, serverNow()) else nil
end

-- Whether a breath check (or an empty peek) is running anywhere.
function LockerHidingService.IsChecking(): boolean
	if #peeks > 0 then
		return true
	end
	for _, locker in lockers do
		if locker.check then
			return true
		end
	end
	return false
end

-- The window of the check running on `player`, if any: (warnAt, windowStart, windowEnd).
function LockerHidingService.GetCheck(player: Player): (number?, number?, number?)
	local locker = occupancy[player]
	local check = if locker then locker.check else nil
	if not check then
		return nil, nil, nil
	end
	return check.startedAt, check.windowStart, check.windowEnd
end

-- Floor 3's key search: swings a Free locker's door ajar (`open`: ObjectiveConfig.Tuning.SearchOpen of fully open, the
-- LockerDoor creak) or shut again; its Hide prompt waits while it stands open. False when the locker is not Free or
-- already so.
function LockerHidingService.SetSearchOpen(model: Model, open: boolean): boolean
	local locker = lockers[model]
	if not locker or locker.state ~= "Free" or (locker.searchOpen == true) == open then
		return false
	end
	local now = serverNow()
	local motion = locker.motion
	local from = if motion then (DoorMotion.valueAt(motion, now)) elseif locker.searchOpen then SEARCH_OPEN else 0
	locker.searchOpen = open
	local seconds = if open then LockerMotion.OpenSeconds else LockerMotion.CloseSeconds
	startDoor(locker, "Swing", from, if open then SEARCH_OPEN else 0, seconds, now + LEAD, "Shut", nil)
	refreshPrompt(locker)
	return true
end

-- Whether Floor 3's key search holds the locker ajar.
function LockerHidingService.IsSearchOpen(model: Model): boolean
	local locker = lockers[model]
	return locker ~= nil and locker.searchOpen == true
end

function LockerHidingService.GetLockers(): { Model }
	local out: { Model } = {}
	for model in lockers do
		table.insert(out, model :: Model)
	end
	return out
end

--------------------------------------------------------------------------------
-- Catches, players, run
--------------------------------------------------------------------------------

-- JumpscareHandler.Finished: a victim handed over from a locker is put down outside it while still playing (Init
-- connects it; specs call it).
function LockerHidingService.CatchFinished(victim: Player, kind: Enums.JumpscareKind, _outcome: string)
	local locker = taken[victim]
	if not locker or kind ~= CATCH_KIND then
		return
	end
	taken[victim] = nil
	local state = lifeStateOf(victim)
	if state ~= "Alive" and state ~= "Downed" then
		return
	end
	local root, height = livingBody(victim)
	if not root then
		return
	end
	local spot = findExitSpot(locker, height)
	if spot then
		teleport(victim, spot)
	end
end

local function onLifeStateChanged(player: Player, state: Enums.LifeState, _previous: Enums.LifeState)
	local locker = occupancy[player]
	if locker and state == "Downed" then
		releaseOccupant(locker, true)
	elseif locker and state ~= "Alive" then
		drop(locker)
	end
	if state ~= "Alive" and state ~= "Downed" then
		taken[player] = nil
	end
end

local function onCharacterRemoving(player: Player, _model: Model)
	local locker = occupancy[player]
	if locker then
		drop(locker)
	end
	taken[player] = nil
end

local function onPhaseChanged(phase: Enums.MatchPhase)
	live = running and LIVE_PHASES[phase] == true
	if not live then
		for _, locker in lockers do
			drop(locker)
		end
	end
end

local function onBreathInput(player: Player, payload: Types.BreathInputPayload)
	LockerHidingService.SetHeld(player, payload.held == true)
end

local function onExitHide(player: Player, _payload: any)
	LockerHidingService.RequestExit(player)
end

local function clearRun()
	for _, locker in lockers do
		drop(locker)
	end
	for _, peek in peeks do
		wake(peek.waiters, "Empty")
	end
	table.clear(peeks)
	table.clear(lockers)
	table.clear(occupancy)
	table.clear(breaths)
	table.clear(taken)
end

--------------------------------------------------------------------------------
-- Dev commands
--------------------------------------------------------------------------------

local function nearestFree(player: Player): Locker?
	local root = livingBody(player)
	if not root then
		return nil
	end
	local level = playerLevel(player)
	local best: Locker? = nil
	local bestDistance = math.huge
	for _, locker in lockers do
		if locker.state == "Free" and (locker.levelId == nil or locker.levelId == level) then
			local distance = (locker.base.CFrame.Position - root.Position).Magnitude
			if distance < bestDistance then
				best, bestDistance = locker, distance
			end
		end
	end
	return best
end

local function hideCommand(player: Player, _args: { string }): string?
	if not running then
		return "no run in progress"
	end
	local locker = nearestFree(player)
	if not locker then
		return "no free locker on your level"
	end
	local ok, reason = LockerHidingService.canHide(hideCheckFor(player, locker))
	if not ok then
		return "cannot hide now: " .. tostring(reason)
	end
	enter(player, locker)
	return "hiding in " .. locker.model.Name
end

local function unhideCommand(player: Player, _args: { string }): string?
	return if LockerHidingService.Release(player) then "out of the locker" else "you are not in a locker"
end

local function checkCommand(player: Player, args: { string }): string?
	local seconds = if args[1] then tonumber(args[1]) else nil
	if args[1] and (seconds == nil or not MathUtil.isFinite(seconds :: number)) then
		return "usage: breathcheck [seconds]"
	end
	if not LockerHidingService.StartCheck(player, seconds) then
		return "settle into a locker first (hide), with no check running"
	end
	return "breath check starting: hold your breath when warned"
end

local function lockersCommand(_player: Player, _args: { string }): string?
	local counts: { [string]: number } = {}
	local hiding: { string } = {}
	for _, locker in lockers do
		counts[locker.state] = (counts[locker.state] or 0) + 1
		local occupant = locker.occupant
		if occupant then
			table.insert(hiding, string.format("%s in %s", occupant.Name, locker.model.Name))
		end
	end
	table.sort(hiding)
	return string.format(
		"free %d, hidden %d, moving %d, smashed %d | %s",
		counts.Free or 0,
		counts.Hidden or 0,
		(counts.Entering or 0) + (counts.Exiting or 0),
		counts.Smashed or 0,
		if #hiding > 0 then table.concat(hiding, ", ") else "nobody hiding"
	)
end

local function registerDevCommands()
	DevToolsService.Register("hide", "hide: climb into the nearest free locker on your level", hideCommand)
	DevToolsService.Register("unhide", "unhide: get out of your locker at once", unhideCommand)
	DevToolsService.Register(
		"breathcheck",
		"breathcheck [seconds]: a hold-breath check on your locker, as if the Creature were at the door",
		checkCommand
	)
	DevToolsService.Register("lockers", "lockers: locker states and who is hiding", lockersCommand, true)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function LockerHidingService.Init()
	if initialized then
		return
	end
	initialized = true
	Net.Server.on("BreathInput", onBreathInput)
	Net.Server.on("ExitHide", onExitHide)
	serviceTrove:Add(InteractionService.Register(LockerHidingService.HideHandler))
	serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(Tags.HideableLocker), onLockerTagged)
	serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(Tags.HideableLocker), onLockerUntagged)
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(onPhaseChanged))
	serviceTrove:Add(LifeStateService.StateChanged:Connect(onLifeStateChanged))
	serviceTrove:Add(CharacterService.CharacterRemoving:Connect(onCharacterRemoving))
	serviceTrove:Add(JumpscareHandler.Finished:Connect(LockerHidingService.CatchFinished))
	MonsterAIService.RegisterLockerInspector(LockerHidingService.Inspect)
	registerDevCommands()
end

function LockerHidingService.Start()
	serviceTrove:Connect(RunService.Heartbeat, function()
		if not running then
			return
		end
		xpcall(LockerHidingService.Step, function(err: any)
			log.warnThrottled("step", 10, "locker step failed: %s\n%s", tostring(err), debug.traceback())
		end, nil)
	end)
end

function LockerHidingService.BeginRun(ctx: Types.RunContext)
	clearRun()
	random = MathUtil.seededRandom(ctx.seed, "LockerPeek")
	running = true
	live = true
	scan()
end

function LockerHidingService.EndRun()
	live = false
	clearRun()
	running = false
end

function LockerHidingService.OnPlayerRemoving(player: Player)
	local locker = occupancy[player]
	if locker then
		drop(locker)
	end
	occupancy[player] = nil
	breaths[player] = nil
	taken[player] = nil
end

return LockerHidingService
