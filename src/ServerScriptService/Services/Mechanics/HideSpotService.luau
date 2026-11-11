--!strict
-- HideSpotService: every hiding spot (docs/MONSTER.md 8; the website's web/src/game/mechanics/lockers.js and
-- hidespots.js): lockers, and the tunnels' barrels and steel cabinets. The only writer of a spot's OccupantUserId,
-- OwnerUserId and DoorOpen and of its leaf's pose after the build.
--
-- Spots. Every Hideable-tagged Model under Workspace.Runtime (LockerBuilder, HideBuilder; HideKind "Locker" | "Barrel" |
-- "Cabinet", missing: Locker) is tracked (CollectionService added / removed, plus a scan at BeginRun: WorldService
-- rebuilds the run's fixtures in its own BeginRun before this one). They share one convention: the ExitAnchor,
-- HideAnchor and PeekAnchor attachments and a Hide prompt (a 0.25 s hold); the leaf (a locker's door, a barrel's lid, a
-- cabinet's door) swings by LockerMotion. A spot is Free, Entering, Hidden (one occupant), Exiting or Smashed (its leaf
-- torn off by the Creature: never usable again this run). The Hide prompt serves every unsmashed spot.
--
-- Getting in (canHide: the run is live, Alive with a living body, no control lock, on foot (Standing / Sprinting /
-- Crouching), not hiding already, the spot Free, and the Creature not chasing this player; refusals that matter are
-- told with Hud.LockerOccupied / Hud.LockerSeen). At once: OccupantUserId, CharacterService.Lock(player, "Locker",
-- "Anchor"), the "Hiding" MoveState override, the torch off, the leaf opening from GameConfig.OneShotLead from now. It is
-- heard: the HideEnter noise (8) at the door, HideEnterHurried (14) when they sprinted within Hiding.HurriedWindow. When
-- the leaf is open the body is moved inside (the HideAnchor, facing out); then it shuts and the occupant is settled
-- (RunStats LockersHidden).
--
-- The stay limit (DOORS' Hide). Hiding.KickOutWarning (35 s) after getting in, the warning knock (PrivateCue Scare
-- HideWarn, the Hud.HideWarn hint); at Hiding.KickOutSeconds (45 s) they are shoved out to the spot's exit, unhurt
-- (Scare HideKick). A running breath check holds the shove until it ends.
--
-- Fake-outs (DOORS' Jack). Spot `AnchorId` holds one this run when its own seeded stream ("Fakeout|<seed>|<id>")
-- rolls under 1 / CreatureConfig.FakeoutOneIn (each id its own stream: adding spots never reshuffles the rest). At most one per floor per player: getting into an
-- armed spot within that player's budget, FAKEOUT_DELAY after the leaf starts to open, the player alone gets the reveal
-- scare and the FakeoutShriek (MonsterAIService.Reveal: PrivateCue Scare Fakeout), and nothing else. The spot is then
-- ordinary for the rest of the run, for everyone.
--
-- The pull-out (co-op, THRESHOLD's throw). A "Pull out" prompt (PromptKind PullOut, a Hiding.PullSeconds hold, the Hide
-- prompt's distance) on every spot, shown to the others (OwnerUserId = the occupant, audience "Others") while a
-- teammate hides inside. The puller must be Alive, on foot, not hiding, and within Hiding.PullReach of the spot's exit
-- (canPull). The hider is thrown out beside the puller (the puller's x / z at the exit's floor height, facing away from
-- the spot) when that spot is clear, else to the spot's own exit; the brain is told (MonsterAIService.NotePulled: no
-- exit catch, a startle if it was watching them).
--
-- Getting out (ExitHide, or the prompt key in the client's Locker context): only while settled and not under a check,
-- and only to a clear spot (the ExitAnchor, else a step to either side, else one further out; none clear refuses with
-- Hud.LockerBlocked). Dying, going Downed, losing the character, leaving, the run ending or the spot disappearing
-- releases the occupant the same way (out to a clear spot when there is a living body, else where they are).
--
-- Leaves are server-stepped on Heartbeat (collision follows them) and announced on OneShot "Door" / "LockerRip" with
-- DoorMotion args (+ LockerMotion.Args phase / occupant), so every client renders the same motion smoothly.
--
-- The inspector (MonsterAIService.RegisterLockerInspector; Search and InvestigateNoise call it in their own thread when
-- the Creature stands hunched at the front). Inspect yields until it has a verdict:
--   * Empty (nobody inside, or the occupant already on the way out): "Empty" after LockerMotion.EmptyPeekSeconds.
--   * Occupied: the hold-breath check (LockerMotion: the warning WarnSeconds after the check starts, a seeded
--     PeekMin..PeekMax window; judge). The Creature leaving the front (no longer in InvestigateNoise, Search or
--     HidingResponse, or more than AT_DOOR from it) ends the check safe.
--   * Caught: the gasp (the Gasp cue and noise) and "Caught": the brain's ReachIn follows. When the Creature's catch
--     takes over (MonsterAIService.Caught, kind Locker: a ReachIn's, or the sniff's), the leaf is ripped off (OneShot
--     "LockerRip"), the Locker lock and the override are released (the catch holds the body), and the spot is Smashed;
--     when that catch ends with the victim still playing, they are put down outside it.
-- The brain also reads the spots through RegisterHideSpots: a level's spots (their ExitAnchor fronts), who is in which.
--
-- Dev commands: hide (the nearest free spot on your level), unhide, breathcheck [seconds], lockers (read-only).
--
-- Pure rules (tests/Specs/Lockers.spec.luau, tests/Specs/HideSpots.spec.luau): canHide, canExit, judge, peekSeconds,
-- exitCandidates, rootCFrameAt, isFakeout, stayVerdict, canPull, hurried, pullSpot.
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
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local DoorMotion = require(ReplicatedStorage.Shared.Sequence.DoorMotion)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
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

local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)

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

local log = Log.new("HideSpots")

local P = Attributes.Player
local M = Attributes.Match
local W = Attributes.World
local ARGS = LockerMotion.Args
local CUE = LockerMotion.CueArgs
local CUE_PHASE = LockerMotion.CuePhases
local H = CreatureConfig.Hiding

local LOCK_REASON: Enums.ControlLock = "Locker"
local LOCK_MODE: Enums.LockMode = "Anchor"
local OVERRIDE_TOKEN = "Locker"
local HIDING: Enums.MoveState = "Hiding"
local HIDE_KIND: Enums.PromptKind = "Hide"
local PULL_KIND: Enums.PromptKind = "PullOut"
local HIDDEN_STAT: Enums.StatKey = "LockersHidden"
local GASP_NOISE: Enums.NoiseKind = "Gasp"
local ENTER_NOISE: Enums.NoiseKind = "HideEnter"
local HURRIED_NOISE: Enums.NoiseKind = "HideEnterHurried"
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
local WARN_HINT = "Hud.HideWarn"
local DEFAULT_LEVEL: Enums.LevelId = "Level1_Hallways"

local HIDE_ANCHOR = "HideAnchor"
local PEEK_ANCHOR = "PeekAnchor"
local EXIT_ANCHOR = "ExitAnchor"
local PROMPT_HOST = "HidePrompt"

local LEAD = GameConfig.OneShotLead
local SLIT_OUT = 0.45 -- studs from the peeking eye out through the door to the slits' outer face
local EXIT_SIDE = 1.6 -- a blocked exit spot tries this far to either side
local EXIT_FURTHER = 1.2 -- ... then this much further out
local CLEAR_SIZE = Vector3.new(1.8, 4.2, 1.1) -- a standing body, from just above the floor
local CLEAR_LIFT = 0.5
local DEFAULT_ROOT_HEIGHT = 3 -- R15: HipHeight 2 + half the 2-stud root
local DEV_CHECK_SECONDS = 5
local AT_DOOR = 8 -- the Creature farther than this from the exit anchor has left the door
local FAKEOUT_DELAY = 0.12 -- after the leaf starts to open, the fake-out leaps out
local PULL_DISTANCE = 7 -- the Pull out prompt's MaxActivationDistance (the Hide prompt's)

local ON_FOOT: { [string]: boolean } = { Standing = true, Sprinting = true, Crouching = true }
local LIVE_PHASES: { [string]: boolean } = { Deploying = true, InRun = true }
local CHASES: { [string]: boolean } = { WallChase = true }
-- the Creature's states that stand at a spot sniffing (the breath check runs while it is there)
local AT_SPOT_STATES: { [string]: boolean } = { InvestigateNoise = true, Search = true, HidingResponse = true }
local OBJECT_TEXT: { [string]: string } =
	{ Locker = "Prompt.Locker", Barrel = "Prompt.Barrel", Cabinet = "Prompt.Cabinet" }

export type LockerState = "Free" | "Entering" | "Hidden" | "Exiting" | "Smashed"

export type Reason = "OutOfBreath" | "Gasp" | "Breathing" | "Held" | "Left" | "Gone"

export type StayVerdict = "Warn" | "KickOut"

-- Everything canHide looks at (gathered from the world; specs build it by hand).
export type HideCheck = {
	live: boolean,
	lifeState: Enums.LifeState,
	hasBody: boolean,
	controlLock: Enums.ControlLock,
	moveState: Enums.MoveState,
	hiding: boolean, -- already in (or on the way into / out of) a spot
	lockerState: LockerState,
	chasedBy: boolean, -- the Creature is chasing this player
}

export type ExitCheck = {
	lockerState: LockerState,
	occupant: boolean, -- the asker is this spot's occupant
	checking: boolean, -- a breath check is running on it
	spotFound: boolean,
}

-- Everything canPull looks at.
export type PullCheck = {
	alive: boolean,
	onFoot: boolean,
	hiding: boolean, -- the puller hides somewhere themselves
	occupiedByOther: boolean, -- a teammate hides in the spot
	distance: number, -- the puller's root to the spot's exit
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
	reveal: ((player: Player, kind: string) -> ())?, -- a fake-out's scare (MonsterAIService.Reveal)
	pulled: ((player: Player) -> ())?, -- the brain is told of a pull-out (MonsterAIService.NotePulled)
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

-- The time in a spot: the warning at KickOutWarning, the shove at KickOutSeconds (held while a check runs).
type Stay = { since: number, warned: boolean, out: boolean }

type Fakeout = { at: number, locker: Locker, player: Player }

export type Locker = {
	model: Model,
	base: BasePart,
	kind: Enums.HideKind,
	id: string, -- AnchorId (the fake-out's stream)
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
	stay: Stay?,
}

local HideSpotService = {}

HideSpotService.Name = "HideSpotService"
HideSpotService.OverrideToken = OVERRIDE_TOKEN
HideSpotService.LockReason = LOCK_REASON
HideSpotService.OccupiedHint = OCCUPIED_HINT
HideSpotService.SeenHint = SEEN_HINT
HideSpotService.BlockedHint = BLOCKED_HINT
HideSpotService.WarnHint = WARN_HINT
HideSpotService.ExitSide = EXIT_SIDE
HideSpotService.ExitFurther = EXIT_FURTHER
HideSpotService.FakeoutDelay = FAKEOUT_DELAY
HideSpotService.KickOutWarning = H.KickOutWarning
HideSpotService.KickOutSeconds = H.KickOutSeconds
HideSpotService.PullSeconds = H.PullSeconds
HideSpotService.PullReach = H.PullReach

local hidden: Signal.Signal<Player, Model> = Signal.new()
local left: Signal.Signal<Player, Model> = Signal.new()
local checked: Signal.Signal<Player, Model, Types.LockerVerdict> = Signal.new()
local kicked: Signal.Signal<Player, Model> = Signal.new()
local pulledOut: Signal.Signal<Player, Model, Player> = Signal.new()
local fakedOut: Signal.Signal<Player, Model> = Signal.new()

-- (player, spot) once a player is settled inside.
HideSpotService.Hidden = hidden
-- (player, spot) once an occupant is out (or was released).
HideSpotService.Left = left
-- (occupant, spot, verdict) when a breath check ends ("HiddenSafe" or "Caught").
HideSpotService.Checked = checked
-- (player, spot) the stay limit shoved them out.
HideSpotService.Kicked = kicked
-- (hider, spot, puller) a teammate pulled them out.
HideSpotService.PulledOut = pulledOut
-- (player, spot) a fake-out played for them.
HideSpotService.FakedOut = fakedOut

local serviceTrove = Trove.new()
local deps: Dependencies = {}
local lockers: { [Instance]: Locker } = {}
local occupancy: { [Player]: Locker } = {}
local breaths: { [Player]: LockerMotion.Breath } = {}
local peeks: { Peek } = {}
local taken: { [Player]: Locker } = {} -- victims handed to a Locker catch, put down outside when it ends
local lastSprintAt: { [Player]: number } = {}
local fakeoutBudget: { [Player]: { [string]: boolean } } = {}
local fakeoutsSpent: { [string]: boolean } = {} -- spot ids whose fake-out has played (ordinary for everyone after)
local pendingFakeouts: { Fakeout } = {}
local running = false
local live = false
local runSeed = 0
local participants: { Player } = {}
local random = Random.new(1)
local oneShotSeq = 0
local initialized = false

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/Lockers.spec.luau, tests/Specs/HideSpots.spec.luau)
--------------------------------------------------------------------------------

-- Whether a player may climb into a spot, and why not.
function HideSpotService.canHide(check: HideCheck): (boolean, string?)
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
function HideSpotService.canExit(check: ExitCheck): (boolean, string?)
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

-- Whether `puller` may drag the hider out of a spot (THRESHOLD's throw).
function HideSpotService.canPull(check: PullCheck): boolean
	return check.alive and check.onFoot and not check.hiding and check.occupiedByOther and check.distance <= H.PullReach
end

-- Whether getting in was hurried (the louder HideEnterHurried noise): sprinting at most HurriedWindow before.
function HideSpotService.hurried(lastSprint: number?, now: number): boolean
	return lastSprint ~= nil and now - lastSprint <= H.HurriedWindow
end

-- Whether spot `id` holds a fake-out in the run of `seed` (each id its own seeded stream).
function HideSpotService.isFakeout(seed: number, id: string): boolean
	-- the seed hashed with the key (FNV-1a), so neighbouring seeds draw unrelated streams
	local stream = Random.new(MathUtil.hash("Fakeout|" .. tostring(math.floor(seed)) .. "|" .. id))
	return stream:NextNumber() < 1 / CreatureConfig.FakeoutOneIn
end

-- What the stay clock says at `now` for a stay begun at `since`: "Warn" (once), "KickOut" (once, held while a breath
-- check runs) or nil. `warned` / `out` say what already happened.
function HideSpotService.stayVerdict(
	since: number,
	now: number,
	warned: boolean,
	out: boolean,
	checking: boolean
): StayVerdict?
	if out then
		return nil
	end
	local held = now - since
	if not warned and held >= H.KickOutWarning then
		return "Warn"
	end
	if held >= H.KickOutSeconds and not checking then
		return "KickOut"
	end
	return nil
end

-- The verdict of a breath check at server time `now`, if it has one: (verdict, reason, the instant it was decided).
-- The occupant's lungs are unchanged since breath.at (call it before and after every change of hold).
function HideSpotService.judge(view: CheckView, now: number): (Types.LockerVerdict?, Reason?, number?)
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

-- How long the Creature peeks through the gap (seeded).
function HideSpotService.peekSeconds(source: Random): number
	return source:NextNumber(LockerMotion.PeekMin, LockerMotion.PeekMax)
end

-- Where a leaving occupant may stand, best first: the exit anchor, a step to either side, one further out (floor
-- CFrames facing away from the spot).
function HideSpotService.exitCandidates(exitAnchor: CFrame): { CFrame }
	return {
		exitAnchor,
		exitAnchor * CFrame.new(EXIT_SIDE, 0, 0),
		exitAnchor * CFrame.new(-EXIT_SIDE, 0, 0),
		exitAnchor * CFrame.new(0, 0, -EXIT_FURTHER),
	}
end

-- The root CFrame of a body standing at floor point `floor` (its facing kept), `rootHeight` above it.
function HideSpotService.rootCFrameAt(floor: CFrame, rootHeight: number): CFrame
	return floor * CFrame.new(0, rootHeight, 0)
end

-- Where a pulled hider lands: at the puller's x / z on the exit's floor, facing away from the spot (from the exit
-- toward the puller); nil when the puller stands on the exit itself.
function HideSpotService.pullSpot(exitAnchor: CFrame, pullerRoot: Vector3): CFrame?
	local exit = exitAnchor.Position
	local at = Vector3.new(pullerRoot.X, exit.Y, pullerRoot.Z)
	local toward = Vector3.new(at.X - exit.X, 0, at.Z - exit.Z)
	if toward.Magnitude < 1e-2 then
		return nil
	end
	return CFrame.lookAt(at, at + toward.Unit)
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
-- Creature and the spot itself ignored).
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

local function revealFor(player: Player, kind: string)
	local fake = deps.reveal
	if fake then
		fake(player, kind)
	else
		MonsterAIService.Reveal(player, kind)
	end
end

local function tellPulled(player: Player)
	local fake = deps.pulled
	if fake then
		fake(player)
	else
		MonsterAIService.NotePulled(player)
	end
end

-- A moment for one player (PrivateCue Scare): the stay limit's knock and shove, a pull-out.
local function scare(player: Player, kind: Enums.ScareKind)
	sendCue(player, { kind = "Scare", startAt = serverNow(), endsAt = nil, args = { scare = kind } })
end

-- Swaps in fakes (nil restores every real dependency).
function HideSpotService.SetDependencies(fake: Dependencies?)
	deps = fake or {}
end

--------------------------------------------------------------------------------
-- Spot geometry
--------------------------------------------------------------------------------

local function anchorWorld(locker: Locker, name: string): CFrame?
	local attachment = locker.base:FindFirstChild(name)
	if attachment and attachment:IsA("Attachment") then
		return locker.base.CFrame * attachment.CFrame
	end
	return nil
end

-- The hidden player's eye behind the gap (looking out).
local function peekOf(locker: Locker): CFrame
	return anchorWorld(locker, PEEK_ANCHOR) or locker.base.CFrame
end

-- The gap's outer face: where the Creature breathes in at you.
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

local function kindOf(model: Model): Enums.HideKind
	local value = model:GetAttribute(W.HideKind)
	if type(value) == "string" and Enums.has(Enums.HideKind, value) then
		return value :: Enums.HideKind
	end
	return "Locker"
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
	for _, floor in HideSpotService.exitCandidates(exit) do
		if spotClear(floor, locker.model) then
			return HideSpotService.rootCFrameAt(floor, rootHeight)
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Leaves
--------------------------------------------------------------------------------

local function setDoorOpen(locker: Locker, open: boolean)
	Attributes.set(locker.model, W.DoorOpen, open)
end

-- Starts a leaf motion `from` -> `to` at `startAt`, stepped here and announced to every client.
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

-- Poses every moving leaf at server time `now`.
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
				log.warnThrottled("inspector", 10, "hiding spot inspector failed after its verdict: %s", tostring(err))
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

-- The catch took over: the leaf is torn off and the body handed to JumpscareHandler.
local function handOver(locker: Locker, occupant: Player, now: number)
	local check = locker.check
	locker.state = "Smashed"
	locker.schedule = nil
	locker.check = nil
	locker.stay = nil
	if check and check.verdict == nil then
		check.verdict = "Caught"
		stopSniff(check)
		wake(check.waiters, "Caught")
	end
	startDoor(locker, "Smash", 0, 1, LockerMotion.RipSeconds, now + LEAD, "Rip", occupant)
	occupancy[occupant] = nil
	breaths[occupant] = nil
	locker.occupant = nil
	Attributes.set(locker.model, W.OccupantUserId, nil)
	Attributes.set(locker.model, W.OwnerUserId, nil)
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
	-- The inspector returns now: the brain's ReachIn follows (the rip waits for its catch: onCaught).
	wake(check.waiters, verdict)
	if verdict ~= "Empty" then
		checked:Fire(occupant, locker.model, verdict)
	end
	if verdict == "Caught" and not check.scripted and catchVictim() == occupant and occupancy[occupant] == locker then
		handOver(locker, occupant, serverNow())
	end
end

-- Whether the Creature is still peeking: in a sniffing state, and standing at the front.
local function creatureAtDoor(locker: Locker): boolean
	if not AT_SPOT_STATES[monsterState()] then
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
	local verdict, reason, at = HideSpotService.judge({
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
	Attributes.set(locker.model, W.OwnerUserId, player.UserId)
	hold(player)
	torchOff(player)
	local startAt = now + LEAD
	locker.schedule = LockerMotion.enterSchedule(startAt)
	startDoor(locker, "Swing", 0, 1, LockerMotion.OpenSeconds, startAt, "Enter", player)
	-- heard getting in (louder straight off a sprint); the stay limit starts; a fake-out leaps out as it opens
	local noise: Enums.NoiseKind = if HideSpotService.hurried(lastSprintAt[player], now)
		then HURRIED_NOISE
		else ENTER_NOISE
	emitNoise(doorPoint(locker), noise, player, locker.levelId)
	locker.stay = { since = now, warned = false, out = false }
	local level = locker.levelId or ""
	local budget = fakeoutBudget[player]
	if not budget then
		budget = {}
		fakeoutBudget[player] = budget
	end
	if not fakeoutsSpent[locker.id] and not budget[level] and HideSpotService.isFakeout(runSeed, locker.id) then
		budget[level] = true
		fakeoutsSpent[locker.id] = true
		table.insert(pendingFakeouts, { at = startAt + FAKEOUT_DELAY, locker = locker, player = player })
	end
	refreshPrompt(locker)
	log.debug("%s climbs into %s (%s)", player.Name, locker.model.Name, locker.kind)
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
	locker.stay = nil
	local startAt = now + LEAD
	locker.schedule = LockerMotion.exitSchedule(startAt)
	local motion = locker.motion
	local from = if motion then (DoorMotion.valueAt(motion, now)) else 0
	startDoor(locker, "Swing", from, 1, LockerMotion.OpenSeconds * (1 - from), startAt, "Exit", occupant)
end

-- The occupant is out of the spot (moved out, or let go where they are).
local function vacate(locker: Locker)
	local occupant = locker.occupant
	locker.occupant = nil
	locker.stay = nil
	Attributes.set(locker.model, W.OccupantUserId, nil)
	Attributes.set(locker.model, W.OwnerUserId, nil)
	if occupant then
		if occupancy[occupant] == locker then
			occupancy[occupant] = nil
		end
		breaths[occupant] = nil
		letGo(occupant)
		left:Fire(occupant, locker.model)
	end
	refreshPrompt(locker)
end

-- Lets the occupant go at once: out to `spot` when given, else to a clear spot when `outside` and they have a living
-- body, else where they are. The leaf opens behind them and shuts again.
local function releaseTo(locker: Locker, outside: boolean, spot: CFrame?)
	local occupant = locker.occupant
	if not occupant then
		return
	end
	local target = spot
	if not target and outside then
		local root, height = livingBody(occupant)
		if root then
			target = findExitSpot(locker, height)
		end
	end
	if locker.state ~= "Exiting" then
		beginExit(locker, target)
	end
	if not locker.moved then
		locker.moved = true
		local destination = target or locker.exitSpot
		if destination then
			teleport(occupant, destination)
		end
		vacate(locker)
	end
end

releaseOccupant = function(locker: Locker, outside: boolean)
	releaseTo(locker, outside, nil)
end

-- Lets the occupant go where they are (no body to move: it died, left, or the run is ending). A leaf left open swings
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
				teleport(occupant, HideSpotService.rootCFrameAt(hide, height))
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

-- The stay limit: the knock at KickOutWarning, the shove at KickOutSeconds (held while a check runs).
local function stepStay(locker: Locker, now: number)
	local stay = locker.stay
	local occupant = locker.occupant
	if not (stay and occupant) or locker.state ~= "Hidden" then
		return
	end
	local verdict = HideSpotService.stayVerdict(stay.since, now, stay.warned, stay.out, locker.check ~= nil)
	if verdict == "Warn" then
		stay.warned = true
		scare(occupant, "HideWarn")
		notify(occupant, WARN_HINT)
	elseif verdict == "KickOut" then
		stay.out = true
		scare(occupant, "HideKick")
		kicked:Fire(occupant, locker.model)
		releaseOccupant(locker, true)
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

local function pullCheckFor(player: Player, locker: Locker): PullCheck
	local root = livingBody(player)
	local exit = anchorWorld(locker, EXIT_ANCHOR)
	local occupant = locker.occupant
	return {
		alive = lifeStateOf(player) == "Alive" and root ~= nil,
		onFoot = ON_FOOT[moveStateOf(player)] == true,
		hiding = occupancy[player] ~= nil,
		occupiedByOther = occupant ~= nil and occupant ~= player and locker.state == "Hidden",
		distance = if root and exit then MathUtil.horizontalDistance(root.Position, exit.Position) else math.huge,
	}
end

HideSpotService.HideHandler = {
	kind = HIDE_KIND,
	filter = function(host: Instance, _prompt: ProximityPrompt): boolean
		local locker = lockerOf(host)
		return locker ~= nil and locker.state ~= "Smashed"
	end,
	canUse = function(player: Player, _prompt: ProximityPrompt, host: Instance): (boolean, string?)
		local locker = lockerOf(host)
		if not locker then
			return false, "Unknown"
		end
		return HideSpotService.canHide(hideCheckFor(player, locker))
	end,
	onComplete = function(player: Player, _prompt: ProximityPrompt, host: Instance)
		local locker = lockerOf(host)
		if locker and HideSpotService.canHide(hideCheckFor(player, locker)) then
			enter(player, locker)
		end
	end,
} :: InteractionService.Handler

-- Drags `locker`'s occupant out beside `puller` (see the header). False when the rules refuse it.
local function pull(puller: Player, locker: Locker): boolean
	if not (live and HideSpotService.canPull(pullCheckFor(puller, locker))) then
		return false
	end
	local hider = locker.occupant
	local exit = anchorWorld(locker, EXIT_ANCHOR)
	if not (hider and exit) then
		return false
	end
	local spot: CFrame? = nil
	local pullerRoot = livingBody(puller)
	local _, height = livingBody(hider)
	local floor = if pullerRoot then HideSpotService.pullSpot(exit, pullerRoot.Position) else nil
	if floor and spotClear(floor, locker.model) then
		spot = HideSpotService.rootCFrameAt(floor, height)
	end
	if not spot then
		spot = findExitSpot(locker, height)
	end
	tellPulled(hider)
	scare(hider, "HideKick")
	releaseTo(locker, true, spot)
	pulledOut:Fire(hider, locker.model, puller)
	log.debug("%s pulled %s out of %s", puller.Name, hider.Name, locker.model.Name)
	return true
end

HideSpotService.PullHandler = {
	kind = PULL_KIND,
	filter = function(host: Instance, _prompt: ProximityPrompt): boolean
		local locker = lockerOf(host)
		return locker ~= nil and locker.state == "Hidden" and locker.occupant ~= nil
	end,
	audience = function(_prompt: ProximityPrompt, _host: Instance): Enums.Audience
		return "Others"
	end,
	canUse = function(player: Player, _prompt: ProximityPrompt, host: Instance): (boolean, string?)
		local locker = lockerOf(host)
		if not locker then
			return false, "Unknown"
		end
		return HideSpotService.canPull(pullCheckFor(player, locker)), nil
	end,
	holdSeconds = function(_player: Player, _prompt: ProximityPrompt, _host: Instance): number
		return H.PullSeconds
	end,
	onComplete = function(player: Player, _prompt: ProximityPrompt, host: Instance)
		local locker = lockerOf(host)
		if locker then
			pull(player, locker)
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

-- The Pull out prompt beside the Hide prompt (created once per spot; the builders make only the Hide prompt).
local function ensurePullPrompt(locker: Locker)
	local model = locker.model
	if PropKit.findPrompt(model, PULL_KIND) then
		return
	end
	local host = locker.base:FindFirstChild(PROMPT_HOST)
	if not host then
		return
	end
	PropKit.prompt(host, {
		kind = PULL_KIND,
		action = "Prompt.PullOut",
		object = OBJECT_TEXT[locker.kind] or "Prompt.Locker",
		hold = H.PullSeconds,
		distance = PULL_DISTANCE,
		offset = Vector2.new(0, 64),
	}, model)
end

-- Tracks a Hideable model (WorldService's fixtures; specs track a built one). False when it is not a hiding spot.
function HideSpotService.Track(model: Model): boolean
	if lockers[model] then
		return true
	end
	local base = model.PrimaryPart
	if not (base and (model:HasTag(Tags.Hideable) or model:HasTag(Tags.HideableLocker))) then
		return false
	end
	local locker: Locker = {
		model = model,
		base = base,
		kind = kindOf(model),
		id = Attributes.getString(model, W.AnchorId, model.Name),
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
		stay = nil,
	}
	lockers[model] = locker
	Attributes.set(model, W.DoorOpen, false)
	Attributes.set(model, W.OccupantUserId, nil)
	Attributes.set(model, W.OwnerUserId, nil)
	ensurePullPrompt(locker)
	refreshPrompt(locker)
	return true
end

local function onSpotTagged(instance: Instance)
	if running and instance:IsA("Model") and inRuntime(instance) then
		HideSpotService.Track(instance)
	end
end

local function onSpotUntagged(instance: Instance)
	forget(instance)
end

local function scan()
	for _, tag in { Tags.Hideable, Tags.HideableLocker } do
		for _, instance in CollectionService:GetTagged(tag) do
			onSpotTagged(instance)
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- The inspector MonsterAIService calls (in its own thread) when the Creature peeks into `instance` (see the header).
function HideSpotService.Inspect(instance: Instance): Types.LockerVerdict
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
		local check = startCheck(locker, occupant, now, HideSpotService.peekSeconds(random), false)
		if check.verdict ~= nil then
			return check.verdict :: Types.LockerVerdict
		end
		return await(check.waiters)
	end
	local peek: Peek = { locker = locker, resolveAt = now + LockerMotion.EmptyPeekSeconds, waiters = {} }
	table.insert(peeks, peek)
	return await(peek.waiters)
end

-- Starts a scripted breath check of `seconds` on `player`'s spot (no Creature needed; dev). False when they are not
-- settled in one or one is already running.
function HideSpotService.StartCheck(player: Player, seconds: number?): boolean
	local locker = occupancy[player]
	if not (locker and live and locker.state == "Hidden" and locker.check == nil) then
		return false
	end
	local peek = math.clamp(seconds or DEV_CHECK_SECONDS, LockerMotion.PeekMin, LockerMotion.PeekMax)
	startCheck(locker, player, serverNow(), peek, true)
	return true
end

-- One step at server time `now`: leaf poses, the moves in and out, the stay limits, the fake-outs, the checks and
-- empty peeks (every Heartbeat; specs drive it on a fake clock).
function HideSpotService.Step(at: number?)
	if not running then
		return
	end
	local now = at or serverNow()
	for _, player in participants do
		if moveStateOf(player) == "Sprinting" then
			lastSprintAt[player] = now
		end
	end
	stepDoors(now)
	for _, locker in lockers do
		stepSchedule(locker, now)
		stepStay(locker, now)
	end
	for index = #pendingFakeouts, 1, -1 do
		local fake = pendingFakeouts[index]
		if now >= fake.at then
			table.remove(pendingFakeouts, index)
			if occupancy[fake.player] == fake.locker then
				revealFor(fake.player, "Fakeout")
				fakedOut:Fire(fake.player, fake.locker.model)
			end
		end
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

-- The occupant's hold changed (BreathInput; specs call it). False when they are not in a spot.
function HideSpotService.SetHeld(player: Player, held: boolean): boolean
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
function HideSpotService.RequestExit(player: Player): (boolean, string?)
	local locker = occupancy[player]
	if not locker then
		return false, "NotOccupant"
	end
	local _, height = livingBody(player)
	local spot = if locker.state == "Hidden" and locker.check == nil then findExitSpot(locker, height) else nil
	local ok, reason = HideSpotService.canExit({
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

-- Releases `player` from any spot at once (out to a clear spot when they have a living body). False when they were
-- not in one.
function HideSpotService.Release(player: Player): boolean
	local locker = occupancy[player]
	if not locker then
		return false
	end
	releaseOccupant(locker, true)
	return true
end

-- Puts `player` into `model` as if the prompt completed (dev / scripted). False when refused.
function HideSpotService.Hide(player: Player, model: Model): boolean
	local locker = lockers[model]
	if not locker or not HideSpotService.canHide(hideCheckFor(player, locker)) then
		return false
	end
	enter(player, locker)
	return true
end

-- `puller` drags the hider out of `model` as if the Pull out prompt completed (specs). False when refused.
function HideSpotService.Pull(puller: Player, model: Model): boolean
	local locker = lockers[model]
	return locker ~= nil and pull(puller, locker)
end

function HideSpotService.GetLockerOf(player: Player): Model?
	local locker = occupancy[player]
	return if locker then locker.model else nil
end

HideSpotService.GetSpotOf = HideSpotService.GetLockerOf

function HideSpotService.GetOccupant(model: Model): Player?
	local locker = lockers[model]
	return if locker then locker.occupant else nil
end

function HideSpotService.GetState(model: Model): LockerState?
	local locker = lockers[model]
	return if locker then locker.state else nil
end

function HideSpotService.GetKind(model: Model): Enums.HideKind?
	local locker = lockers[model]
	return if locker then locker.kind else nil
end

function HideSpotService.GetBreath(player: Player): number?
	local breath = breaths[player]
	return if breath then LockerMotion.breathAt(breath, serverNow()) else nil
end

-- Whether a breath check (or an empty peek) is running anywhere.
function HideSpotService.IsChecking(): boolean
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
function HideSpotService.GetCheck(player: Player): (number?, number?, number?)
	local locker = occupancy[player]
	local check = if locker then locker.check else nil
	if not check then
		return nil, nil, nil
	end
	return check.startedAt, check.windowStart, check.windowEnd
end

function HideSpotService.GetLockers(): { Model }
	local out: { Model } = {}
	for model in lockers do
		table.insert(out, model :: Model)
	end
	return out
end

HideSpotService.GetSpots = HideSpotService.GetLockers

-- The brain's view (MonsterAIService.RegisterHideSpots): the unsmashed spots of a level with their fronts.
local function spotsOn(levelId: string): { MonsterAIService.HideSpotEntry }
	local out: { MonsterAIService.HideSpotEntry } = {}
	for model, locker in lockers do
		if locker.state == "Smashed" or (locker.levelId ~= nil and locker.levelId ~= levelId) then
			continue
		end
		local front = anchorWorld(locker, EXIT_ANCHOR)
		if front then
			table.insert(out, { id = model, kind = locker.kind, front = front })
		end
	end
	table.sort(out, function(a, b)
		return a.front.Position.X < b.front.Position.X
			or (a.front.Position.X == b.front.Position.X and a.front.Position.Z < b.front.Position.Z)
	end)
	return out
end

HideSpotService.SpotsOn = spotsOn

--------------------------------------------------------------------------------
-- Catches, players, run
--------------------------------------------------------------------------------

-- MonsterAIService.Caught: a Locker catch on a hider takes the spot (the leaf is torn off, the body handed over).
function HideSpotService.CatchStarted(victim: Player, kind: Enums.JumpscareKind)
	local locker = occupancy[victim]
	if kind ~= CATCH_KIND or not locker or locker.state == "Smashed" then
		return
	end
	handOver(locker, victim, serverNow())
end

-- JumpscareHandler.Finished: a victim handed over from a spot is put down outside it while still playing (Init
-- connects it; specs call it).
function HideSpotService.CatchFinished(victim: Player, kind: Enums.JumpscareKind, _outcome: string)
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
	HideSpotService.SetHeld(player, payload.held == true)
end

local function onExitHide(player: Player, _payload: any)
	HideSpotService.RequestExit(player)
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
	table.clear(lastSprintAt)
	table.clear(fakeoutBudget)
	table.clear(fakeoutsSpent)
	table.clear(pendingFakeouts)
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
		return "no free hiding spot on your level"
	end
	local ok, reason = HideSpotService.canHide(hideCheckFor(player, locker))
	if not ok then
		return "cannot hide now: " .. tostring(reason)
	end
	enter(player, locker)
	return "hiding in " .. locker.model.Name .. " (" .. locker.kind .. ")"
end

local function unhideCommand(player: Player, _args: { string }): string?
	return if HideSpotService.Release(player) then "out of the hiding spot" else "you are not hiding"
end

local function checkCommand(player: Player, args: { string }): string?
	local seconds = if args[1] then tonumber(args[1]) else nil
	if args[1] and (seconds == nil or not MathUtil.isFinite(seconds :: number)) then
		return "usage: breathcheck [seconds]"
	end
	if not HideSpotService.StartCheck(player, seconds) then
		return "settle into a hiding spot first (hide), with no check running"
	end
	return "breath check starting: hold your breath when warned"
end

local function lockersCommand(_player: Player, _args: { string }): string?
	local counts: { [string]: number } = {}
	local kinds: { [string]: number } = {}
	local hiding: { string } = {}
	for _, locker in lockers do
		counts[locker.state] = (counts[locker.state] or 0) + 1
		kinds[locker.kind] = (kinds[locker.kind] or 0) + 1
		local occupant = locker.occupant
		if occupant then
			table.insert(hiding, string.format("%s in %s", occupant.Name, locker.model.Name))
		end
	end
	table.sort(hiding)
	return string.format(
		"lockers %d, barrels %d, cabinets %d | free %d, hidden %d, moving %d, smashed %d | %s",
		kinds.Locker or 0,
		kinds.Barrel or 0,
		kinds.Cabinet or 0,
		counts.Free or 0,
		counts.Hidden or 0,
		(counts.Entering or 0) + (counts.Exiting or 0),
		counts.Smashed or 0,
		if #hiding > 0 then table.concat(hiding, ", ") else "nobody hiding"
	)
end

local function registerDevCommands()
	DevToolsService.Register("hide", "hide: climb into the nearest free hiding spot on your level", hideCommand)
	DevToolsService.Register("unhide", "unhide: get out of your hiding spot at once", unhideCommand)
	DevToolsService.Register(
		"breathcheck",
		"breathcheck [seconds]: a hold-breath check on your hiding spot, as if the Creature were at the door",
		checkCommand
	)
	DevToolsService.Register("lockers", "lockers: hiding spots and who is hiding", lockersCommand, true)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function HideSpotService.Init()
	if initialized then
		return
	end
	initialized = true
	Net.Server.on("BreathInput", onBreathInput)
	Net.Server.on("ExitHide", onExitHide)
	serviceTrove:Add(InteractionService.Register(HideSpotService.HideHandler))
	serviceTrove:Add(InteractionService.Register(HideSpotService.PullHandler))
	for _, tag in { Tags.Hideable, Tags.HideableLocker } do
		serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(tag), onSpotTagged)
		serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(tag), onSpotUntagged)
	end
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(onPhaseChanged))
	serviceTrove:Add(LifeStateService.StateChanged:Connect(onLifeStateChanged))
	serviceTrove:Add(CharacterService.CharacterRemoving:Connect(onCharacterRemoving))
	serviceTrove:Add(JumpscareHandler.Finished:Connect(HideSpotService.CatchFinished))
	serviceTrove:Add(MonsterAIService.Caught:Connect(HideSpotService.CatchStarted))
	MonsterAIService.RegisterLockerInspector(HideSpotService.Inspect)
	MonsterAIService.RegisterHideSpots({
		spotsOn = spotsOn,
		occupant = function(spot: Instance): Player?
			local locker = lockers[spot]
			return if locker then locker.occupant else nil
		end,
		spotOf = function(player: Player): Instance?
			local locker = occupancy[player]
			return if locker then locker.model else nil
		end,
	})
	registerDevCommands()
end

function HideSpotService.Start()
	serviceTrove:Connect(RunService.Heartbeat, function()
		if not running then
			return
		end
		xpcall(HideSpotService.Step, function(err: any)
			log.warnThrottled("step", 10, "hiding spot step failed: %s\n%s", tostring(err), debug.traceback())
		end, nil)
	end)
end

function HideSpotService.BeginRun(ctx: Types.RunContext)
	clearRun()
	runSeed = ctx.seed
	participants = table.clone(ctx.participants)
	random = MathUtil.seededRandom(ctx.seed, "LockerPeek")
	running = true
	live = true
	scan()
end

function HideSpotService.EndRun()
	live = false
	clearRun()
	running = false
	participants = {}
end

function HideSpotService.OnPlayerRemoving(player: Player)
	local locker = occupancy[player]
	if locker then
		drop(locker)
	end
	occupancy[player] = nil
	breaths[player] = nil
	taken[player] = nil
	lastSprintAt[player] = nil
	fakeoutBudget[player] = nil
	local index = table.find(participants, player)
	if index then
		table.remove(participants, index)
	end
end

return HideSpotService
