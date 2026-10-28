--!strict
-- BearTrapService: the Level 0 trap gauntlet (spec, Level 0). The only writer of a trap's Armed and TrappedUserId,
-- of its jaw / pan poses after the build, and of OwnerUserId on its prompt hosts.
--
-- Traps. Every BearTrap-tagged Model under Workspace.Runtime is tracked (CollectionService added / removed, plus a
-- scan at BeginRun, since WorldService builds the run's props in its own BeginRun just before this one). Each trap is
-- Armed (built armed), Caught (holding one victim) or Spent: a trap snaps once and is never re-armed; props are
-- rebuilt every run.
--
-- Prompt hosts. InteractionService lets one actor channel an Interactable host at a time, and the builder puts both
-- prompts on one attachment under the Interactable model. So the victim's pry and a teammate's rescue can run at the
-- same time, tracking re-hosts them: the PromptPoint attachment is tagged Interactable and keeps TrapPry, and a sibling
-- "RescuePoint" attachment (same place, tagged Interactable) takes TrapRescue. Each prompt is replaced by a fresh
-- clone parented under its host after the tag is set: a prompt InteractionService already filed under the model (its
-- nearest Interactable ancestor at the time) would otherwise stay filed there, and a new instance is adopted under
-- its own host whatever order the deferred tag and descendant signals arrive in. Both prompts stay disabled while the
-- trap is armed or spent (the handlers' filters only serve a caught trap's hosts); both hosts carry OwnerUserId =
-- the victim while caught, so TrapPry ("Self") shows only to the victim and TrapRescue ("Others") to everyone else.
--
-- Springing. At GameConfig.ServerTickHz, every run participant who may spring a trap (canTrigger: the run is live,
-- Alive, not already caught, a living character, no control lock, an on-foot MoveState, and no server move in the
-- last TeleportGrace seconds) has their foot point (root minus HipHeight and half the root's height, as ZoneService
-- measures it) tested with point-in-box maths, after a horizontal distance cull, against each armed trap's pan zone:
-- the TriggerVolume's footprint from its bottom up to PressHeight above the trap's floor (a foot on the pan; a foot
-- in mid-jump over the jaws presses nothing). A sprinter covers about two studs between samples, so the segment from
-- the previous sample's foot point is tested too (slab clipping), unless it is longer than MaxSweepStep (a move the
-- server did not announce) or the player could not spring a trap in between. The volume is a NoCollide part: nothing
-- is ever Touched or queried. Only players are polled, so the Creature never springs a trap; Downed, Dead and
-- Spectating players never do either.
--
-- Snap (Armed -> Caught): Armed false, TrappedUserId = the victim; the root is moved (CharacterService.Teleport, which
-- announces the move to the noise sampler) so the caught right foot of PlayerR15's trapped pose lands on the LegPoint,
-- facing the way the victim faced, then held with CharacterService.Lock(player, "Trap", "Anchor") and the "Trapped"
-- MoveState override (WalkSpeed 0); the pan drops and the jaws are stepped shut in SnapSeconds on Heartbeat, starting
-- GameConfig.OneShotLead from now so they close with the cues; both prompts open; the 130-stud TrapSnap noise, the
-- TrapSnap and BoneCrunch cues at the trap, OneShot "TrapSnap" (subject = the trap) for everyone, PrivateCue "TrapLeg"
-- { trapPosition, legPoint } for the victim, RunStats TrapsTriggered; GameConfig.TrapDamage last (LifeStateService:
-- a lethal snap downs the victim, who stays caught; an execution releases the trap through StateChanged).
--
-- Escape (Caught -> Spent). TrapPry: the victim (Alive or Downed) holds GameConfig.TrapSoloPrySeconds while looking
-- down (PlayerStateService.GetLook pitch <= GameConfig.TrapLookDownPitch to start; a running pry tolerates
-- LookUpSlack more and is cancelled past that). TrapRescue: any other Alive player who is not caught themselves
-- holds GameConfig.TrapRescueSeconds. Either frees the victim: both channels end, both prompts close, the jaws are
-- forced open to PriedOpenness (never back to armed) with a MetalCreak, the lock and override are released and
-- TrappedUserId is cleared. Release (the victim died, started spectating, lost their character or left; the run
-- ended) frees the body the same way but leaves the jaws shut and silent.
--
-- Dev commands: trap [spawn] (snap the nearest armed trap on your level onto yourself, or build a fresh one at your
-- feet when there is none or `spawn` is given), untrap [player], traps (read-only summary).
--
-- Pure rules (tests/Specs/BearTrap.spec.luau): footPoint, footInTrigger, panZone, segmentInBox, footSprings,
-- canTrigger, lookingDown, pryEligible, rescueEligible, nextState, motionOpenness, caughtFootOffset, caughtRootCFrame.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local JointMap = require(ReplicatedStorage.Shared.Animation.ProceduralAnimator.JointMap)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local BearTrapBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.BearTrapBuilder)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)

local AudioService = require(ServerScriptService.Services.Core.AudioService)
local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)

local log = Log.new("BearTrap")

local P = Attributes.Player
local M = Attributes.Match
local W = Attributes.World
local NAMES = BearTrapBuilder.Names

local OVERRIDE_TOKEN = "BearTrap"
local LOCK_REASON: Enums.ControlLock = "Trap"
local LOCK_MODE: Enums.LockMode = "Anchor"
local TRAPPED_STATE: Enums.MoveState = "Trapped"
local DAMAGE_CAUSE = "BearTrap"
local SNAP_NOISE: Enums.NoiseKind = "TrapSnap"
local SNAP_ONESHOT: Enums.OneShotKind = "TrapSnap"
local LEG_CUE: Enums.CueKind = "TrapLeg"
local TRIGGERED_STAT: Enums.StatKey = "TrapsTriggered"
local PRY_KIND: Enums.PromptKind = "TrapPry"
local RESCUE_KIND: Enums.PromptKind = "TrapRescue"
local SNAP_PRESET = "TrapSnap"
local CRUNCH_PRESET = "BoneCrunch"
local CREAK_PRESET = "MetalCreak"
local LOOK_DOWN_HINT = "Hud.Trapped" -- the refusal InteractionService shows a victim who is not looking down
local RESCUE_POINT = "RescuePoint"
local DEFAULT_LEVEL: Enums.LevelId = "Level0_Basement"

local SNAP_SECONDS = 0.07
local PRY_OPEN_SECONDS = 0.6
local PRIED_OPENNESS = 0.45 -- the jaws forced apart to about 40 degrees: open, nowhere near re-armed (1 = flat)
local CRUNCH_DELAY = 0.03 -- the bone gives a beat after the iron strikes
local TELEPORT_GRACE = 0.35 -- seconds after a server move during which a foot springs nothing
local LOOK_UP_SLACK = 10 -- degrees a running pry may lift above TrapLookDownPitch before it breaks
local CULL_SLACK = 0.5 -- studs added to a pan zone's horizontal half-diagonal for the distance cull
local PRESS_HEIGHT = 0.75 -- studs above the trap's floor a foot point may be and still press the pan
local MAX_SWEEP_STEP = 8 -- studs; a longer step between two samples is a teleport, not a stride

-- PlayerR15's trapped pose holds the right ankle at the right hip's X x 1.05 and leg length x 0.32 ahead of the
-- root (rig space: X right, -Z forward); the root is placed so that point lands on the trap's LegPoint.
local CAUGHT_FOOT_SIDE = 1.05
local CAUGHT_FOOT_AHEAD = 0.32
local CAUGHT_LEG_JOINTS: { string } = { "RightHip", "RightKnee", "RightAnkle" }
local DEFAULT_HIP_X = 0.5 -- an R15 hip's distance from the centre line, when the rig cannot be mapped

local ON_FOOT: { [string]: boolean } = { Standing = true, Sprinting = true, Crouching = true }
local LIVE_PHASES: { [string]: boolean } = { Deploying = true, InRun = true }

export type TrapState = "Armed" | "Caught" | "Spent"

-- Snap: a foot sprang it. Pry: the victim forced it open. Rescue: a teammate did. Release: the victim is gone
-- (died, spectating, lost their character, left) or the run ended; the jaws stay shut.
export type TrapEvent = "Snap" | "Pry" | "Rescue" | "Release"

export type Ease = "In" | "Out"

-- A jaw movement stepped on Heartbeat: openness from `from` to `to` over `seconds`, `delay` seconds after it was
-- started, `elapsed` seconds ago.
export type Motion = {
	from: number,
	to: number,
	delay: number,
	seconds: number,
	ease: Ease,
	elapsed: number,
}

-- Everything canTrigger looks at for one player (gathered by the poll; specs build it by hand).
export type TriggerCheck = {
	live: boolean, -- the run is live (Deploying / InRun)
	participant: boolean,
	lifeState: Enums.LifeState,
	caught: boolean, -- already held by a trap
	hasBody: boolean, -- a living character with a root
	controlLock: Enums.ControlLock,
	moveState: Enums.MoveState,
	graced: boolean, -- moved by the server within TeleportGrace
}

export type PryCheck = {
	userId: number,
	victimUserId: number?,
	lifeState: Enums.LifeState,
	pitch: number, -- radians, the player's latest LookRelay
	channelling: boolean, -- the player's pry is already running (the look may lift by LookUpSlack)
}

export type RescueCheck = {
	userId: number,
	victimUserId: number?,
	lifeState: Enums.LifeState,
	rescuerCaught: boolean,
}

type Trap = {
	model: Model,
	base: BasePart,
	zoneCFrame: CFrame, -- the pan zone (panZone), cached: traps are anchored and never move
	zoneSize: Vector3,
	cull: number,
	legPoint: Attachment,
	pryHost: Attachment,
	rescueHost: Attachment,
	levelId: string?,
	state: TrapState,
	victim: Player?,
	motion: Motion?,
}

local BearTrapService = {}

BearTrapService.Name = "BearTrapService"
BearTrapService.OverrideToken = OVERRIDE_TOKEN
BearTrapService.SnapSeconds = SNAP_SECONDS
BearTrapService.PryOpenSeconds = PRY_OPEN_SECONDS
BearTrapService.PriedOpenness = PRIED_OPENNESS
BearTrapService.TeleportGrace = TELEPORT_GRACE
BearTrapService.LookUpSlack = LOOK_UP_SLACK
BearTrapService.RescuePointName = RESCUE_POINT
BearTrapService.LookDownHint = LOOK_DOWN_HINT
BearTrapService.PressHeight = PRESS_HEIGHT
BearTrapService.MaxSweepStep = MAX_SWEEP_STEP

local snapped: Signal.Signal<Player, Model> = Signal.new()
local freed: Signal.Signal<Player, Model, TrapEvent> = Signal.new()

-- (victim, trap) after a trap closed on a player (before the damage lands).
BearTrapService.Snapped = snapped
-- (victim, trap, event) after a victim was freed: "Pry", "Rescue" or "Release".
BearTrapService.Freed = freed

local serviceTrove = Trove.new()
local traps: { [Model]: Trap } = {}
local trapsByHost: { [Instance]: Trap } = {}
local caught: { [Player]: Trap } = {}
local moving: { [Trap]: boolean } = {}
local participants: { [Player]: boolean } = {}
local graceUntil: { [Player]: number } = {} -- os.clock() until which a server-moved player springs nothing
local lastFoot: { [Player]: Vector3 } = {} -- each eligible player's foot point at the previous poll
local running = false -- between BeginRun and EndRun
local live = false -- running, and the match phase is Deploying / InRun
local oneShotSeq = 0
local devTrapCount = 0
local initialized = false

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/BearTrap.spec.luau)
--------------------------------------------------------------------------------

-- The floor point under a character: its root lowered by HipHeight and half the root's height.
function BearTrapService.footPoint(rootCFrame: CFrame, rootSize: Vector3, hipHeight: number): Vector3
	return rootCFrame.Position - Vector3.new(0, hipHeight + rootSize.Y * 0.5, 0)
end

-- Whether `foot` is inside a box (edges inclusive; pure maths, so NoCollide volumes count).
function BearTrapService.footInTrigger(volumeCFrame: CFrame, volumeSize: Vector3, foot: Vector3): boolean
	return MathUtil.isFiniteVector(foot) and SpatialQuery.pointInBox(volumeCFrame, volumeSize, foot)
end

-- The pan zone of a trigger volume whose trap rests on `floor`: the volume's footprint, from its bottom up to
-- PressHeight above the floor (never above the volume's own top).
function BearTrapService.panZone(volumeCFrame: CFrame, volumeSize: Vector3, floor: Vector3): (CFrame, Vector3)
	local bottom = -volumeSize.Y * 0.5
	local top = math.clamp(volumeCFrame:PointToObjectSpace(floor).Y + PRESS_HEIGHT, bottom, volumeSize.Y * 0.5)
	return volumeCFrame * CFrame.new(0, (bottom + top) * 0.5, 0), Vector3.new(volumeSize.X, top - bottom, volumeSize.Z)
end

-- Narrows the parameter range [t0, t1] of a segment p + d * t to where one axis stays within [-half, half].
local function clipAxis(p: number, d: number, half: number, t0: number, t1: number): (number, number)
	if math.abs(d) < 1e-9 then
		if math.abs(p) > half then
			return 1, 0
		end
		return t0, t1
	end
	local enter, exit = (-half - p) / d, (half - p) / d
	if enter > exit then
		enter, exit = exit, enter
	end
	return math.max(t0, enter), math.min(t1, exit)
end

-- Whether the segment `from` -> `to` passes through the box `cframe` x `size` (slab clipping in the box's space).
function BearTrapService.segmentInBox(cframe: CFrame, size: Vector3, from: Vector3, to: Vector3): boolean
	if not (MathUtil.isFiniteVector(from) and MathUtil.isFiniteVector(to)) then
		return false
	end
	local a = cframe:PointToObjectSpace(from)
	local d = cframe:PointToObjectSpace(to) - a
	local half = size * 0.5
	local t0, t1 = clipAxis(a.X, d.X, half.X, 0, 1)
	t0, t1 = clipAxis(a.Y, d.Y, half.Y, t0, t1)
	t0, t1 = clipAxis(a.Z, d.Z, half.Z, t0, t1)
	return t0 <= t1
end

-- Whether a foot now at `to` (last seen at `from`, when known) pressed the pan zone `zoneCFrame` x `zoneSize`.
function BearTrapService.footSprings(zoneCFrame: CFrame, zoneSize: Vector3, from: Vector3?, to: Vector3): boolean
	if BearTrapService.footInTrigger(zoneCFrame, zoneSize, to) then
		return true
	end
	if from == nil or not MathUtil.isFiniteVector(from) or (to - from).Magnitude > MAX_SWEEP_STEP then
		return false
	end
	return BearTrapService.segmentInBox(zoneCFrame, zoneSize, from, to)
end

-- Whether a player may spring an armed trap their foot is in, and why not.
function BearTrapService.canTrigger(check: TriggerCheck): (boolean, string?)
	if not check.live then
		return false, "NoRun"
	end
	if not check.participant then
		return false, "NotParticipant"
	end
	if check.lifeState ~= "Alive" then
		return false, "LifeState"
	end
	if check.caught then
		return false, "Caught"
	end
	if not check.hasBody then
		return false, "NoBody"
	end
	if check.controlLock ~= "None" then
		return false, "Locked"
	end
	if not ON_FOOT[check.moveState] then
		return false, "MoveState"
	end
	if check.graced then
		return false, "Grace"
	end
	return true, nil
end

-- Whether `pitch` (radians, up positive) looks down at the trap: at or below GameConfig.TrapLookDownPitch to start a
-- pry; `sustaining` (a pry already running) allows LookUpSlack more.
function BearTrapService.lookingDown(pitch: number, sustaining: boolean?): boolean
	local limit = GameConfig.TrapLookDownPitch + (if sustaining then LOOK_UP_SLACK else 0)
	return MathUtil.isFinite(pitch) and pitch <= math.rad(limit)
end

-- Whether a player may pry a caught trap open: its own victim, Alive or Downed, looking down. The look-down refusal
-- is a Strings key (InteractionService shows it to the player).
function BearTrapService.pryEligible(check: PryCheck): (boolean, string?)
	local victim = check.victimUserId
	if victim == nil then
		return false, "Released"
	end
	if check.userId ~= victim then
		return false, "NotVictim"
	end
	if check.lifeState ~= "Alive" and check.lifeState ~= "Downed" then
		return false, "LifeState"
	end
	if not BearTrapService.lookingDown(check.pitch, check.channelling) then
		return false, LOOK_DOWN_HINT
	end
	return true, nil
end

-- Whether a player may free someone else from a caught trap: not its victim, Alive, and not caught themselves.
function BearTrapService.rescueEligible(check: RescueCheck): (boolean, string?)
	local victim = check.victimUserId
	if victim == nil then
		return false, "Released"
	end
	if check.userId == victim then
		return false, "Victim"
	end
	if check.lifeState ~= "Alive" then
		return false, "LifeState"
	end
	if check.rescuerCaught then
		return false, "Caught"
	end
	return true, nil
end

-- The state a trap moves to on `event`, or nil when the event does not apply (a spent trap never changes again).
function BearTrapService.nextState(state: TrapState, event: TrapEvent): TrapState?
	if state == "Armed" then
		return if event == "Snap" then "Caught" else nil
	elseif state == "Caught" then
		return if event == "Snap" then nil else "Spent"
	end
	return nil
end

-- A motion's openness now, and whether it has finished. Before its delay it holds `from`. "In" accelerates (a spring
-- slamming shut), "Out" decelerates (iron forced apart until it sticks).
function BearTrapService.motionOpenness(motion: Motion): (number, boolean)
	local seconds = math.max(motion.seconds, 1e-3)
	local t = math.clamp((motion.elapsed - motion.delay) / seconds, 0, 1)
	local eased = if motion.ease == "In" then t * t else 1 - (1 - t) ^ 3
	return motion.from + (motion.to - motion.from) * eased, motion.elapsed >= motion.delay + seconds
end

-- Where PlayerR15's trapped pose holds the caught (right) foot's sole, in root space: `hipX` is the right hip's rest
-- X, `leg` the hip-to-ankle bone length, `groundY` the floor height under the root (negative).
function BearTrapService.caughtFootOffset(hipX: number, leg: number, groundY: number): Vector3
	return Vector3.new(math.abs(hipX) * CAUGHT_FOOT_SIDE, groundY, -leg * CAUGHT_FOOT_AHEAD)
end

-- The root CFrame that puts `footOffset` (root space) on `footTarget`, upright, keeping `rootCFrame`'s heading.
function BearTrapService.caughtRootCFrame(rootCFrame: CFrame, footOffset: Vector3, footTarget: Vector3): CFrame
	local look = rootCFrame.LookVector
	local yaw = if math.abs(look.X) + math.abs(look.Z) > 1e-4 then math.atan2(-look.X, -look.Z) else 0
	local heading = CFrame.Angles(0, yaw, 0)
	return CFrame.new(footTarget - heading:VectorToWorldSpace(footOffset)) * heading
end

--------------------------------------------------------------------------------
-- Instance helpers
--------------------------------------------------------------------------------

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function legPosition(trap: Trap): Vector3
	return PropKit.attachmentWorld(trap.legPoint).Position
end

-- A trap's floor point: the bottom of its base bar, which rests on the plan point.
local function floorUnder(base: BasePart): Vector3
	return (base.CFrame * CFrame.new(0, -base.Size.Y * 0.5, 0)).Position
end

local function livingBody(player: Player): (BasePart?, Humanoid?)
	local root = Instances.characterRoot(player)
	local humanoid = Instances.characterHumanoid(player)
	if root and humanoid and humanoid.Health > 0 then
		return root, humanoid
	end
	return nil, nil
end

local function levelOf(model: Model): Enums.LevelId?
	local value = model:GetAttribute(W.LevelId)
	if type(value) == "string" and Enums.has(Enums.LevelId, value) then
		return value :: Enums.LevelId
	end
	return nil
end

-- The level `player` stands on: ZoneService's LevelId, else the run's current level, else the basement.
local function playerLevel(player: Player): Enums.LevelId
	for _, value in { player:GetAttribute(P.LevelId), ReplicatedStorage:GetAttribute(M.CurrentLevel) } do
		if type(value) == "string" and Enums.has(Enums.LevelId, value) then
			return value :: Enums.LevelId
		end
	end
	return DEFAULT_LEVEL
end

-- The caught foot's sole in `character`'s root space, measured from its rest rig like the animation profile does.
local function footOffsetOf(character: Model, humanoid: Humanoid, root: BasePart): Vector3
	local map = JointMap.build(character, { required = CAUGHT_LEG_JOINTS })
	if map then
		local hip = JointMap.pivot(map, "RightHip")
		local leg = JointMap.distance(map, "RightHip", "RightKnee") + JointMap.distance(map, "RightKnee", "RightAnkle")
		return BearTrapService.caughtFootOffset(hip.X, leg, map.groundY)
	end
	local ground = -(humanoid.HipHeight + root.Size.Y * 0.5)
	return BearTrapService.caughtFootOffset(DEFAULT_HIP_X, humanoid.HipHeight, ground)
end

local function inRuntime(instance: Instance): boolean
	local runtime = Instances.runtime()
	return runtime ~= nil and instance:IsDescendantOf(runtime)
end

--------------------------------------------------------------------------------
-- Jaw motions
--------------------------------------------------------------------------------

local function startMotion(trap: Trap, from: number, to: number, seconds: number, ease: Ease)
	trap.motion = {
		from = from,
		to = to,
		delay = GameConfig.OneShotLead,
		seconds = seconds,
		ease = ease,
		elapsed = 0,
	}
	moving[trap] = true
end

-- Advances every jaw motion by `dt` seconds and poses the jaws (the Heartbeat driver calls this every frame; specs
-- drive it by hand).
function BearTrapService.StepMotions(dt: number)
	for trap in table.clone(moving) do
		local motion = trap.motion
		if motion == nil or trap.model.Parent == nil then
			moving[trap] = nil
			trap.motion = nil
			continue
		end
		motion.elapsed += math.max(0, dt)
		if motion.elapsed < motion.delay then
			continue
		end
		local openness, done = BearTrapService.motionOpenness(motion)
		BearTrapBuilder.setJaws(trap.model, openness)
		if done then
			trap.motion = nil
			moving[trap] = nil
		end
	end
end

--------------------------------------------------------------------------------
-- Prompts
--------------------------------------------------------------------------------

-- Re-evaluates the trap's prompt hosts against the handlers below (InteractionService untracks the hosts of a trap
-- that is being destroyed on its own). Protected: a refresh failure must never leave a victim half caught or freed.
local function refreshPrompts(trap: Trap)
	if trap.model.Parent == nil then
		return
	end
	for _, host in { trap.pryHost, trap.rescueHost } do
		xpcall(InteractionService.Refresh, function(err: any)
			log.warnThrottled("refresh", 10, "prompt refresh on %s failed: %s", host:GetFullName(), tostring(err))
		end, host)
	end
end

local function setOwner(trap: Trap, userId: number?)
	Attributes.set(trap.pryHost, W.OwnerUserId, userId)
	Attributes.set(trap.rescueHost, W.OwnerUserId, userId)
end

-- The trap behind a prompt host, and whether that host is the pry host.
local function hostTrap(host: Instance): (Trap?, boolean)
	local trap = trapsByHost[host]
	if trap == nil then
		return nil, false
	end
	return trap, host == trap.pryHost
end

-- Replaces `prompt` with a fresh copy parented under `host` (tagged Interactable first; see the header).
local function rehost(prompt: ProximityPrompt, host: Attachment): ProximityPrompt
	local fresh = prompt:Clone()
	prompt:Destroy()
	fresh.Parent = host
	return fresh
end

-- The RescuePoint beside `promptPoint` (created, tagged Interactable before it enters the world, on first use).
local function rescuePointFor(promptPoint: Attachment): Attachment
	local parent = promptPoint.Parent
	local existing = if parent then parent:FindFirstChild(RESCUE_POINT) else nil
	if existing and existing:IsA("Attachment") then
		existing:AddTag(Tags.Interactable)
		return existing
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = RESCUE_POINT
	attachment.CFrame = promptPoint.CFrame
	attachment:AddTag(Tags.Interactable)
	attachment.Parent = parent
	return attachment
end

--------------------------------------------------------------------------------
-- Moments
--------------------------------------------------------------------------------

local function sendMoments(trap: Trap, victim: Player)
	local model = trap.model
	local leg = legPosition(trap)
	local floor = floorUnder(trap.base)
	local startAt = serverNow() + GameConfig.OneShotLead
	NoiseAndDirectorService.Emit(floor, SNAP_NOISE, { sourcePlayer = victim, levelId = levelOf(model) })
	AudioService.PlayAt(SNAP_PRESET, floor)
	AudioService.PlayAt(CRUNCH_PRESET, leg, { delay = CRUNCH_DELAY })
	oneShotSeq += 1
	local event: Types.OneShotEvent = {
		seq = oneShotSeq,
		kind = SNAP_ONESHOT,
		subject = model,
		startAt = startAt,
		args = { userId = victim.UserId, legPoint = leg },
	}
	Net.Server.fireAll("OneShot", event)
	if victim.Parent == Players then
		local cue: Types.PrivateCuePayload = {
			kind = LEG_CUE,
			startAt = startAt,
			endsAt = nil,
			args = { trapPosition = floor, legPoint = leg },
		}
		Net.Server.fire("PrivateCue", victim, cue)
	end
end

--------------------------------------------------------------------------------
-- Snap / free
--------------------------------------------------------------------------------

local function snap(trap: Trap, player: Player): boolean
	local nextState: TrapState? = BearTrapService.nextState(trap.state, "Snap")
	if nextState == nil or caught[player] ~= nil then
		return false
	end
	local root, humanoid = livingBody(player)
	local character = player.Character
	if not (root and humanoid and character) then
		return false
	end
	local model = trap.model
	trap.state = nextState :: TrapState
	trap.victim = player
	caught[player] = trap
	Attributes.set(model, W.Armed, false)
	Attributes.set(model, W.TrappedUserId, player.UserId)

	-- The body: the caught foot onto the leg point, then held there.
	local leg = legPosition(trap)
	local floor = floorUnder(trap.base)
	local target = BearTrapService.caughtRootCFrame(
		root.CFrame,
		footOffsetOf(character, humanoid, root),
		Vector3.new(leg.X, floor.Y, leg.Z)
	)
	if not CharacterService.Teleport(player, target) then
		log.debug("%s: no managed character to seat in %s; held where they stand", player.Name, model.Name)
	end
	CharacterService.Lock(player, LOCK_REASON, LOCK_MODE)
	PlayerStateService.PushOverride(player, OVERRIDE_TOKEN, TRAPPED_STATE)

	-- The iron: the pan is down under the foot; the jaws slam shut with the cues.
	BearTrapBuilder.setPan(model, 1)
	startMotion(trap, 1, 0, SNAP_SECONDS, "In")

	setOwner(trap, player.UserId)
	refreshPrompts(trap)
	sendMoments(trap, player)
	RunStatsService.Increment(player, TRIGGERED_STAT)
	log.info("%s caught in %s", player.Name, model.Name)
	snapped:Fire(player, model)

	-- Damage last: a lethal snap downs the victim (still caught); an execution releases the trap via StateChanged.
	LifeStateService.Damage(player, GameConfig.TrapDamage, DAMAGE_CAUSE)
	return true
end

local function free(trap: Trap, event: TrapEvent): boolean
	local victim = trap.victim
	local nextState: TrapState? = BearTrapService.nextState(trap.state, event)
	if nextState == nil or victim == nil then
		return false
	end
	trap.state = nextState :: TrapState
	trap.victim = nil
	if caught[victim] == trap then
		caught[victim] = nil
	end
	local model = trap.model
	Attributes.set(model, W.TrappedUserId, nil)

	-- Whoever is still holding a prompt lets go; then the filters stop serving both hosts.
	InteractionService.CancelChannel(trap.pryHost, "Freed")
	InteractionService.CancelChannel(trap.rescueHost, "Freed")
	refreshPrompts(trap)
	setOwner(trap, nil)

	CharacterService.Unlock(victim, LOCK_REASON)
	PlayerStateService.PopOverride(victim, OVERRIDE_TOKEN)

	if event ~= "Release" and model.Parent ~= nil then
		startMotion(trap, 0, PRIED_OPENNESS, PRY_OPEN_SECONDS, "Out")
		AudioService.PlayAt(CREAK_PRESET, legPosition(trap))
	end
	log.info("%s freed from %s (%s)", victim.Name, model.Name, event)
	freed:Fire(victim, model, event)
	return true
end

-- Frees `player` without prying (cleanup); false when they are not caught.
local function release(player: Player): boolean
	local trap = caught[player]
	if not trap then
		return false
	end
	return free(trap, "Release")
end

--------------------------------------------------------------------------------
-- Prompt handlers
--------------------------------------------------------------------------------

local function onPryComplete(player: Player, _prompt: ProximityPrompt, host: Instance)
	local trap, isPry = hostTrap(host)
	if trap and isPry and trap.victim == player then
		free(trap, "Pry")
	end
end

local function onRescueComplete(player: Player, _prompt: ProximityPrompt, host: Instance)
	local trap, isPry = hostTrap(host)
	local victim = if trap then trap.victim else nil
	if trap and not isPry and victim and victim ~= player then
		free(trap, "Rescue")
	end
end

-- TrapPry on a caught trap's PromptPoint: the victim alone, while looking down.
BearTrapService.PryHandler = table.freeze({
	kind = PRY_KIND,
	filter = function(host: Instance, _prompt: ProximityPrompt): boolean
		local trap, isPry = hostTrap(host)
		return trap ~= nil and isPry and trap.state == "Caught" and trap.victim ~= nil
	end,
	canUse = function(player: Player, _prompt: ProximityPrompt, host: Instance): (boolean, string?)
		local trap = hostTrap(host)
		local victim = if trap and trap.state == "Caught" then trap.victim else nil
		local actor = InteractionService.GetChannel(host)
		local _, pitch = PlayerStateService.GetLook(player)
		return BearTrapService.pryEligible({
			userId = player.UserId,
			victimUserId = if victim then victim.UserId else nil,
			lifeState = LifeStateService.GetState(player),
			pitch = pitch,
			channelling = actor == player,
		})
	end,
	audience = function(_prompt: ProximityPrompt, _host: Instance): Enums.Audience
		return "Self"
	end,
	onComplete = onPryComplete,
} :: InteractionService.Handler)

-- TrapRescue on a caught trap's RescuePoint: any other Alive player who is free.
BearTrapService.RescueHandler = table.freeze({
	kind = RESCUE_KIND,
	filter = function(host: Instance, _prompt: ProximityPrompt): boolean
		local trap, isPry = hostTrap(host)
		return trap ~= nil and not isPry and trap.state == "Caught" and trap.victim ~= nil
	end,
	canUse = function(player: Player, _prompt: ProximityPrompt, host: Instance): (boolean, string?)
		local trap = hostTrap(host)
		local victim = if trap and trap.state == "Caught" then trap.victim else nil
		return BearTrapService.rescueEligible({
			userId = player.UserId,
			victimUserId = if victim then victim.UserId else nil,
			lifeState = LifeStateService.GetState(player),
			rescuerCaught = caught[player] ~= nil,
		})
	end,
	audience = function(_prompt: ProximityPrompt, _host: Instance): Enums.Audience
		return "Others"
	end,
	onComplete = onRescueComplete,
} :: InteractionService.Handler)

--------------------------------------------------------------------------------
-- Tracking
--------------------------------------------------------------------------------

local function forget(model: Model)
	local trap = traps[model]
	if not trap then
		return
	end
	if trap.victim then
		free(trap, "Release")
	end
	traps[model] = nil
	moving[trap] = nil
	trap.motion = nil
	if trapsByHost[trap.pryHost] == trap then
		trapsByHost[trap.pryHost] = nil
	end
	if trapsByHost[trap.rescueHost] == trap then
		trapsByHost[trap.rescueHost] = nil
	end
end

-- Starts managing a built trap: re-hosts its prompts (see the header) and reads its state from Armed. Returns false
-- when the model is not a complete trap. Tracking a trap twice is harmless.
function BearTrapService.Track(model: Model): boolean
	if traps[model] then
		return true
	end
	local base = model.PrimaryPart
	local volume = model:FindFirstChild(NAMES.TriggerVolume)
	local legPoint = PropKit.findAttachment(model, NAMES.LegPoint)
	local promptPoint = PropKit.findAttachment(model, NAMES.PromptPoint)
	local pry = PropKit.findPrompt(model, PRY_KIND)
	local rescue = PropKit.findPrompt(model, RESCUE_KIND)
	if not (base and volume and volume:IsA("BasePart") and legPoint and promptPoint and pry and rescue) then
		log.warn("%s is not a complete bear trap; left alone", model:GetFullName())
		return false
	end
	local rescuePoint = rescuePointFor(promptPoint)
	local zoneCFrame, zoneSize = BearTrapService.panZone(volume.CFrame, volume.Size, floorUnder(base))
	local trap: Trap = {
		model = model,
		base = base,
		zoneCFrame = zoneCFrame,
		zoneSize = zoneSize,
		cull = math.sqrt((zoneSize.X * 0.5) ^ 2 + (zoneSize.Z * 0.5) ^ 2) + CULL_SLACK,
		legPoint = legPoint,
		pryHost = promptPoint,
		rescueHost = rescuePoint,
		levelId = levelOf(model),
		state = if Attributes.getBool(model, W.Armed, false) then "Armed" else "Spent",
		victim = nil,
		motion = nil,
	}
	traps[model] = trap
	trapsByHost[promptPoint] = trap
	trapsByHost[rescuePoint] = trap
	promptPoint:AddTag(Tags.Interactable)
	rehost(pry, promptPoint)
	rehost(rescue, rescuePoint)
	return true
end

local function onTrapTagged(instance: Instance)
	if instance:IsA("Model") and instance.Parent ~= nil and inRuntime(instance) then
		BearTrapService.Track(instance)
	end
end

local function onTrapUntagged(instance: Instance)
	if instance:IsA("Model") then
		forget(instance)
	end
end

local function scan()
	for _, instance in CollectionService:GetTagged(Tags.BearTrap) do
		onTrapTagged(instance)
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Snaps the armed trap `model` onto `player` (the poll does this when a foot springs it; dev commands too). Returns
-- false when the trap is not armed, the player is already caught or has no living character.
function BearTrapService.Snap(model: Model, player: Player): boolean
	local trap = traps[model]
	if not trap then
		return false
	end
	return snap(trap, player)
end

-- Frees the victim of the caught trap `model`: a pry when `by` is the victim (or nil), a rescue when it is someone
-- else. Returns false when nobody is caught in it.
function BearTrapService.Free(model: Model, by: Player?): boolean
	local trap = traps[model]
	if not trap then
		return false
	end
	local victim = trap.victim
	local event: TrapEvent = if by == nil or by == victim then "Pry" else "Rescue"
	return free(trap, event)
end

-- Frees `player` from whatever trap holds them without prying it (the jaws stay shut). False when not caught.
function BearTrapService.Release(player: Player): boolean
	return release(player)
end

-- The trap holding `player`, if any.
function BearTrapService.GetTrapOf(player: Player): Model?
	local trap = caught[player]
	return if trap then trap.model else nil
end

-- The player caught in `model`, if any.
function BearTrapService.GetVictim(model: Model): Player?
	local trap = traps[model]
	return if trap then trap.victim else nil
end

-- `model`'s state, or nil when it is not a tracked trap.
function BearTrapService.GetState(model: Model): TrapState?
	local trap = traps[model]
	return if trap then trap.state else nil
end

-- The prompt hosts of a tracked trap: the PromptPoint (TrapPry) and the RescuePoint (TrapRescue).
function BearTrapService.GetHosts(model: Model): (Attachment?, Attachment?)
	local trap = traps[model]
	if not trap then
		return nil, nil
	end
	return trap.pryHost, trap.rescueHost
end

--------------------------------------------------------------------------------
-- Springing
--------------------------------------------------------------------------------

-- The armed trap a foot now at `foot` (last seen at `from`) pressed: the nearest to `foot` when several did.
local function armedTrapUnder(from: Vector3?, foot: Vector3): Trap?
	local reach = if from then MathUtil.horizontalDistance(from, foot) else 0
	if reach > MAX_SWEEP_STEP then
		from, reach = nil, 0
	end
	local best: Trap? = nil
	local bestDistance = math.huge
	for _, trap in traps do
		if trap.state ~= "Armed" then
			continue
		end
		local distance = MathUtil.horizontalDistance(trap.zoneCFrame.Position, foot)
		if distance > trap.cull + reach or distance >= bestDistance then
			continue
		end
		if BearTrapService.footSprings(trap.zoneCFrame, trap.zoneSize, from, foot) then
			best = trap
			bestDistance = distance
		end
	end
	return best
end

-- One trigger pass over every participant (GameConfig.ServerTickHz; specs call it directly).
function BearTrapService.Poll()
	if not live then
		return
	end
	local now = os.clock()
	for player in participants do
		local root, humanoid = livingBody(player)
		local allowed = BearTrapService.canTrigger({
			live = live,
			participant = true,
			lifeState = LifeStateService.GetState(player),
			caught = caught[player] ~= nil,
			hasBody = root ~= nil,
			controlLock = CharacterService.GetLock(player),
			moveState = PlayerStateService.GetMoveState(player),
			graced = (graceUntil[player] or -math.huge) > now,
		})
		if not (allowed and root and humanoid) then
			lastFoot[player] = nil
			continue
		end
		local foot = BearTrapService.footPoint(root.CFrame, root.Size, humanoid.HipHeight)
		local trap = armedTrapUnder(lastFoot[player], foot)
		lastFoot[player] = foot
		if trap then
			snap(trap, player)
		end
	end
end

--------------------------------------------------------------------------------
-- Dev commands
--------------------------------------------------------------------------------

local function nearestArmedOnLevel(levelId: Enums.LevelId, position: Vector3): Trap?
	local best: Trap? = nil
	local bestDistance = math.huge
	for _, trap in traps do
		if trap.state ~= "Armed" or trap.levelId ~= levelId or trap.model.Parent == nil then
			continue
		end
		local distance = (trap.zoneCFrame.Position - position).Magnitude
		if distance < bestDistance then
			best = trap
			bestDistance = distance
		end
	end
	return best
end

-- A fresh trap built at `player`'s feet in Workspace.Runtime.<their level> (cleared with the run like any prop).
local function spawnTestTrap(player: Player, root: BasePart, humanoid: Humanoid): Trap?
	local levelId: Enums.LayoutId = playerLevel(player)
	local parent = Instances.runtimeLevel(levelId, true)
	if not parent then
		return nil
	end
	devTrapCount += 1
	local plan: Types.PlannedProp = {
		kind = BearTrapBuilder.Kind,
		anchorId = string.format("DevTrap%d", devTrapCount),
		levelId = levelId,
		cframe = CFrame.new(BearTrapService.footPoint(root.CFrame, root.Size, humanoid.HipHeight)),
		variant = devTrapCount,
	}
	local built = Builder.BuildProp(plan, parent, MathUtil.seededRandom(devTrapCount, "DevTrap"))
	if not (built and built:IsA("Model") and BearTrapService.Track(built)) then
		return nil
	end
	return traps[built]
end

local function describe(player: Player): string
	return string.format(
		"%s: %s, %d/%d",
		player.Name,
		PlayerStateService.GetMoveState(player),
		math.round(LifeStateService.GetHealth(player)),
		GameConfig.MaxHealth
	)
end

local function trapCommand(player: Player, args: { string }): string?
	if not live then
		return "no run in progress"
	end
	if not participants[player] then
		return player.Name .. " is not in this run"
	end
	if caught[player] then
		return player.Name .. " is already caught"
	end
	local root, humanoid = livingBody(player)
	if not (root and humanoid) then
		return player.Name .. " has no living character"
	end
	local fresh = args[1] ~= nil and string.lower(args[1]) == "spawn"
	local trap = if fresh then nil else nearestArmedOnLevel(playerLevel(player), root.CFrame.Position)
	if trap == nil then
		trap = spawnTestTrap(player, root, humanoid)
	end
	if trap == nil then
		return "could not build a trap here"
	end
	if not snap(trap, player) then
		return trap.model.Name .. " did not spring"
	end
	return trap.model.Name .. " | " .. describe(player)
end

local function untrapCommand(player: Player, args: { string }): string?
	local target = player
	if args[1] ~= nil then
		local found = LifeStateService.findPlayer(args[1], Players:GetPlayers())
		if not found then
			return string.format("no single player matches %q", args[1])
		end
		target = found
	end
	local trap = caught[target]
	if not trap then
		return target.Name .. " is not caught"
	end
	free(trap, "Pry")
	return target.Name .. " freed from " .. trap.model.Name
end

local function trapsCommand(_player: Player, _args: { string }): string?
	local armed, spent = 0, 0
	local victims: { string } = {}
	for _, trap in traps do
		if trap.state == "Armed" then
			armed += 1
		elseif trap.state == "Spent" then
			spent += 1
		else
			local victim = trap.victim
			table.insert(victims, string.format("%s in %s", if victim then victim.Name else "?", trap.model.Name))
		end
	end
	table.sort(victims)
	return string.format(
		"%d armed, %d caught%s, %d spent",
		armed,
		#victims,
		if #victims > 0 then " (" .. table.concat(victims, ", ") .. ")" else "",
		spent
	)
end

local function registerDevCommands()
	DevToolsService.Register(
		"trap",
		"trap [spawn]: snap the nearest armed trap on your level onto yourself (spawn: build one at your feet)",
		trapCommand
	)
	DevToolsService.Register("untrap", "untrap [player]: pry yourself (or a player) out of a bear trap", untrapCommand)
	DevToolsService.Register("traps", "traps: armed, caught and spent bear traps", trapsCommand, true)
end

--------------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------------

local function onLifeStateChanged(player: Player, state: Enums.LifeState, _previous: Enums.LifeState)
	if state ~= "Alive" and state ~= "Downed" then
		release(player)
	end
end

local function onMoved(player: Player, _model: Model, _cframe: CFrame)
	graceUntil[player] = os.clock() + TELEPORT_GRACE
	lastFoot[player] = nil
end

local function onCharacterRemoving(player: Player, _model: Model)
	release(player)
end

-- A running pry breaks when its victim looks up past the slack.
local function onLookChanged(player: Player, _yaw: number, pitch: number)
	local trap = caught[player]
	if not trap then
		return
	end
	local actor = InteractionService.GetChannel(trap.pryHost)
	if actor == player and not BearTrapService.lookingDown(pitch, true) then
		InteractionService.CancelChannel(trap.pryHost, "LookedAway")
	end
end

local function onPhaseChanged(phase: Enums.MatchPhase)
	live = running and LIVE_PHASES[phase] == true
end

local function releaseAll()
	for player in table.clone(caught) do
		release(player)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function BearTrapService.Init()
	if initialized then
		return
	end
	initialized = true
	serviceTrove:Add(InteractionService.Register(BearTrapService.PryHandler))
	serviceTrove:Add(InteractionService.Register(BearTrapService.RescueHandler))
	serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(Tags.BearTrap), onTrapTagged)
	serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(Tags.BearTrap), onTrapUntagged)
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(onPhaseChanged))
	serviceTrove:Add(LifeStateService.StateChanged:Connect(onLifeStateChanged))
	serviceTrove:Add(CharacterService.Moved:Connect(onMoved))
	serviceTrove:Add(CharacterService.CharacterRemoving:Connect(onCharacterRemoving))
	serviceTrove:Add(PlayerStateService.LookChanged:Connect(onLookChanged))
	registerDevCommands()
end

function BearTrapService.Start()
	local interval = 1 / GameConfig.ServerTickHz
	local accumulated = 0
	serviceTrove:Connect(RunService.Heartbeat, function(dt: number)
		if next(moving) ~= nil then
			xpcall(BearTrapService.StepMotions, function(err: any)
				log.warnThrottled("motion", 10, "jaw motion failed: %s", tostring(err))
			end, dt)
		end
		accumulated += dt
		if accumulated < interval then
			return
		end
		accumulated = 0
		xpcall(BearTrapService.Poll, function(err: any)
			log.warnThrottled("poll", 10, "trap poll failed: %s", tostring(err))
		end)
	end)
end

function BearTrapService.BeginRun(ctx: Types.RunContext)
	releaseAll()
	table.clear(participants)
	for _, player in ctx.participants do
		participants[player] = true
	end
	table.clear(lastFoot)
	running = true
	live = true
	scan()
end

function BearTrapService.EndRun()
	running = false
	live = false
	releaseAll()
	for model in table.clone(traps) do
		forget(model)
	end
	table.clear(participants)
	table.clear(graceUntil)
	table.clear(lastFoot)
end

function BearTrapService.OnPlayerRemoving(player: Player)
	release(player)
	participants[player] = nil
	graceUntil[player] = nil
	lastFoot[player] = nil
end

return BearTrapService
