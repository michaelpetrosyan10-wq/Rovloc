--!strict
-- BearTrapController: what a bear trap feels like on this client. BearTrapService judges everything (the snap, the
-- pry and the rescue are server-timed prompts); this controller only presents it.
--
-- Caught. The local player is caught while a BearTrap model's TrappedUserId is their UserId, or while their MoveState
-- is Trapped (whichever replicates first); the TrapLeg PrivateCue { trapPosition, legPoint } announces a fresh snap
-- before either does and holds the state for CUE_CONFIRM_SECONDS until the attributes confirm it. While caught:
--   * InputContext "Trapped" (flashlight, prompts and the menu stay live; no sprint or crouch),
--   * the eye drops to a kneel (camera state "Crouching" pinned: PlayerR15's trapped pose kneels on the free leg),
--   * the camera tilts down toward the leg: the upper pitch limit drops to the pitch of the LegPoint seen from the
--     eye (clamped between CameraConfig.Pitch.Min and Pitch.TrappedLookDown), so FirstPersonController eases the look
--     down to it; once there the head may come back up to TrappedPitchMax, just below the horizon, never higher,
--   * on a fresh snap a sharp shake lands with the jaws (the cue's startAt, the same instant as the clang),
--   * HUD.ShowHint("Hud.Trapped") (look down and pry), and a panic floor (the heart races while the leg is held).
-- Prying (the victim's own TrapPry channel: ChannelActor on the trap's PromptPoint is this player, or a local hold
-- began on it less than CONFIRM_GRACE ago and the server has not answered yet): the camera trembles with small
-- shakes that build with the channel's progress, and both hands go to the jaws (HandRig "Pry" through
-- FirstPersonController.SetHandPose) with a building jitter. A hold the server ends early (released, refused or
-- broken by looking up) stops the tremble and shows the hint again (at most every HINT_REPEAT_SECONDS).
-- Freed (or the run ends): everything above is restored.
-- Teammates. OneShot "TrapSnap" for someone else gives a distance-scaled jolt within NEAR_SHAKE_RADIUS at its startAt.
--
-- Pure maths (tests/Specs/BearTrap.spec.luau): shouldPresent, tiltPitch, pryProgress, trembleIntensity,
-- trembleAmplitude, handJitter, pryTarget, nearbyShake.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local BearTrapBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.BearTrapBuilder)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)

local Controllers = script.Parent.Parent
local InputController = require(Controllers.Core.InputController)
local FirstPersonController = require(Controllers.FirstPerson.FirstPersonController)
local HUD = require(Controllers.HUD)

local log = Log.new("BearTrapClient")

local P = Attributes.Player
local W = Attributes.World
local NAMES = BearTrapBuilder.Names

local TOKEN = "BearTrap"
local TRAPPED_CONTEXT: Enums.InputContext = "Trapped"
local KNEEL_CAMERA_STATE: Enums.CameraState = "Crouching"
local TRAPPED_STATE: Enums.MoveState = "Trapped"
local PRY_KIND: Enums.PromptKind = "TrapPry"
local HINT_KEY = "Hud.Trapped"
local SNAP_ONESHOT: Enums.OneShotKind = "TrapSnap"
local LEG_CUE: Enums.CueKind = "TrapLeg"

local CUE_CONFIRM_SECONDS = 2 -- a TrapLeg cue holds the caught state this long waiting for the attributes
local RESOLVE_INTERVAL = 0.25 -- seconds between searches for the trap holding us while it is unknown
local MAX_LEAD = 1 -- seconds a cue may be scheduled ahead (clock skew guard)
local TILT_SETTLED = 1.5 -- degrees above the tilt target that count as arrived
local TILT_MAX_SECONDS = 1.2 -- the tilt hands the look back after this long whatever happens
local TRAPPED_PITCH_MAX = CameraConfig.Pitch.TrappedLookDown + 45 -- degrees: the head lifts to just below the horizon
local TRAPPED_PANIC = 0.35
local SNAP_SHAKE_AMPLITUDE = CameraConfig.Shake.ImpactAmplitude * 2
local SNAP_SHAKE_SECONDS = 0.55
local CONFIRM_GRACE = 0.4 -- seconds a local pry hold trembles before the server must confirm the channel
local TREMBLE_INTERVAL = 0.12 -- seconds between tremble impulses
local TREMBLE_PULSE_SECONDS = 0.3
local TREMBLE_FLOOR = 0.25 -- intensity at the first instant of a pry
local TREMBLE_SHAKE_MIN = 0.12 -- degrees
local TREMBLE_SHAKE_MAX = 0.9
local TREMBLE_HAND_STUDS = 0.05
local TREMBLE_HAND_DEGREES = 5
local TREMBLE_HZ = 9
local PRY_HAND_RISE = 0.4 -- studs above the LegPoint: hands on the closed bows around the shin
local NEAR_SHAKE_RADIUS = 18
local HINT_REPEAT_SECONDS = 4 -- the hint comes back at most this often after a broken pry

export type PryInput = {
	myUserId: number,
	serverActor: number?, -- ChannelActor on the trap's PromptPoint
	serverStartedAt: number?,
	serverDuration: number?,
	serverNow: number,
	holdSince: number?, -- os.clock() a local TrapPry hold began (nil when not holding)
	holdSeconds: number, -- that prompt's local HoldDuration
	clock: number, -- os.clock() now
}

type Session = {
	trove: Trove.Trove,
	trap: Model?,
	pryHost: Attachment?,
	legPoint: Vector3?,
	resolveAt: number,
	tilting: boolean,
	tiltPitch: number,
	tiltStartedAt: number,
	holdSince: number?,
	holdSeconds: number,
	prying: boolean,
	nextTrembleAt: number,
	hintAt: number,
	seed: number,
}

local BearTrapController = {}

BearTrapController.Name = "BearTrapController"
BearTrapController.TrappedPitchMax = TRAPPED_PITCH_MAX
BearTrapController.ConfirmGrace = CONFIRM_GRACE
BearTrapController.NearShakeRadius = NEAR_SHAKE_RADIUS

local serviceTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local session: Session? = nil
local cueUntil: number? = nil
local cueLeg: Vector3? = nil

--------------------------------------------------------------------------------
-- Pure maths (specs: tests/Specs/BearTrap.spec.luau)
--------------------------------------------------------------------------------

-- Whether the caught presentation should be up.
function BearTrapController.shouldPresent(ownTrap: boolean, moveStateTrapped: boolean, cuePending: boolean): boolean
	return ownTrap or moveStateTrapped or cuePending
end

-- The pitch (degrees) the camera tilts down to: toward `legPoint` from `eye`, between CameraConfig.Pitch.Min and
-- Pitch.TrappedLookDown (always at least that far down, never past the camera's floor).
function BearTrapController.tiltPitch(eye: Vector3, legPoint: Vector3): number
	local offset = legPoint - eye
	if not MathUtil.isFiniteVector(offset) or offset.Magnitude < 1e-3 then
		return CameraConfig.Pitch.TrappedLookDown
	end
	local _, pitch = MathUtil.yawPitchFromVector(offset)
	return math.clamp(math.deg(pitch), CameraConfig.Pitch.Min, CameraConfig.Pitch.TrappedLookDown)
end

-- How far along this player's pry is (0..1), or nil when they are not prying: the server's channel when it is theirs,
-- else a local hold for its first CONFIRM_GRACE seconds (the server has not answered yet).
function BearTrapController.pryProgress(input: PryInput): number?
	local startedAt, duration = input.serverStartedAt, input.serverDuration
	if input.serverActor == input.myUserId and startedAt ~= nil and duration ~= nil and duration > 0 then
		return MathUtil.clamp01((input.serverNow - startedAt) / duration)
	end
	local since = input.holdSince
	if since ~= nil and input.clock - since <= CONFIRM_GRACE then
		return MathUtil.clamp01((input.clock - since) / math.max(input.holdSeconds, 1e-3))
	end
	return nil
end

-- Tremble intensity 0..1 for a pry `progress` of the way through: never still, building to full near the end.
function BearTrapController.trembleIntensity(progress: number): number
	return TREMBLE_FLOOR + (1 - TREMBLE_FLOOR) * MathUtil.smoothstep(0, 1, progress)
end

-- Camera tremble impulse amplitude (degrees) at `intensity`.
function BearTrapController.trembleAmplitude(intensity: number): number
	return MathUtil.lerp(TREMBLE_SHAKE_MIN, TREMBLE_SHAKE_MAX, MathUtil.clamp01(intensity))
end

-- The shaking-hands offset at time `t` (seconds) for `intensity`: smooth noise on every axis, within
-- TREMBLE_HAND_STUDS and TREMBLE_HAND_DEGREES at full intensity.
function BearTrapController.handJitter(t: number, intensity: number, seed: number): CFrame
	local level = MathUtil.clamp01(intensity)
	local reach = TREMBLE_HAND_STUDS * level
	local turn = math.rad(TREMBLE_HAND_DEGREES) * level
	local phase = t * TREMBLE_HZ
	local function wobble(axis: number): number
		return math.clamp(MathUtil.noise1(phase, seed + axis * 13), -1, 1)
	end
	return CFrame.new(wobble(1) * reach, wobble(2) * reach, wobble(3) * reach * 0.5)
		* CFrame.Angles(wobble(4) * turn, wobble(5) * turn * 0.5, wobble(6) * turn)
end

-- HandRig's Pry target: over the caught leg, facing along the look's heading (-Z away from the player, +Y up).
function BearTrapController.pryTarget(legPoint: Vector3, yaw: number): CFrame
	return CFrame.new(legPoint + Vector3.new(0, PRY_HAND_RISE, 0)) * CFrame.Angles(0, yaw, 0)
end

-- The jolt (degrees) a teammate `distance` studs from a snapping trap feels; 0 beyond NEAR_SHAKE_RADIUS.
function BearTrapController.nearbyShake(distance: number): number
	if not MathUtil.isFinite(distance) or distance >= NEAR_SHAKE_RADIUS then
		return 0
	end
	local falloff = 1 - math.max(0, distance) / NEAR_SHAKE_RADIUS
	return CameraConfig.Shake.ImpactAmplitude * falloff * falloff
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function myUserId(): number?
	local player = localPlayer
	return if player then player.UserId else nil
end

-- The BearTrap model whose TrappedUserId is this player.
local function findMyTrap(): Model?
	local userId = myUserId()
	if userId == nil then
		return nil
	end
	for _, instance in CollectionService:GetTagged(Tags.BearTrap) do
		if instance:IsA("Model") and instance:GetAttribute(W.TrappedUserId) == userId then
			return instance
		end
	end
	return nil
end

local function moveStateTrapped(): boolean
	local player = localPlayer
	return player ~= nil and Attributes.getString(player, P.MoveState, "Standing") == TRAPPED_STATE
end

local function cuePending(): boolean
	local untilAt = cueUntil
	return untilAt ~= nil and os.clock() < untilAt
end

-- Seconds until server time `startAt` (0 when it has passed), capped against skew.
local function leadTo(startAt: unknown): number
	if type(startAt) ~= "number" or not MathUtil.isFinite(startAt) then
		return 0
	end
	return math.clamp(startAt - Workspace:GetServerTimeNow(), 0, MAX_LEAD)
end

local function adoptTrap(current: Session, trap: Model?)
	if trap == current.trap then
		return
	end
	current.trap = trap
	current.pryHost = if trap then PropKit.findAttachment(trap, NAMES.PromptPoint) else nil
	local leg = if trap then PropKit.findAttachment(trap, NAMES.LegPoint) else nil
	if leg then
		current.legPoint = PropKit.attachmentWorld(leg).Position
	end
end

-- Starts the tilt toward the session's leg point (or straight to TrappedLookDown while it is unknown).
local function beginTilt(current: Session)
	local leg = current.legPoint
	current.tiltPitch = if leg
		then BearTrapController.tiltPitch(FirstPersonController.GetEyeCFrame().Position, leg)
		else CameraConfig.Pitch.TrappedLookDown
	current.tilting = true
	current.tiltStartedAt = os.clock()
	FirstPersonController.SetPitchLimits(CameraConfig.Pitch.Min, current.tiltPitch)
end

local function stopPrying(current: Session)
	if current.prying then
		current.prying = false
		FirstPersonController.SetHandPose("Flashlight")
	end
end

--------------------------------------------------------------------------------
-- Session
--------------------------------------------------------------------------------

local function stepSession(current: Session)
	local now = os.clock()
	if current.trap == nil or current.trap.Parent == nil then
		if now >= current.resolveAt then
			current.resolveAt = now + RESOLVE_INTERVAL
			adoptTrap(current, findMyTrap())
		end
	end

	if current.tilting then
		local _, pitch = FirstPersonController.GetLook()
		if math.deg(pitch) <= current.tiltPitch + TILT_SETTLED or now - current.tiltStartedAt >= TILT_MAX_SECONDS then
			current.tilting = false
			FirstPersonController.SetPitchLimits(CameraConfig.Pitch.Min, TRAPPED_PITCH_MAX)
		end
	end

	local host = current.pryHost
	local userId = myUserId()
	local actor = if host then host:GetAttribute(W.ChannelActor) else nil
	local progress = if userId
		then BearTrapController.pryProgress({
			myUserId = userId,
			serverActor = if type(actor) == "number" then actor else nil,
			serverStartedAt = if host then Attributes.getNumber(host, W.ChannelStartedAt, 0) else nil,
			serverDuration = if host then Attributes.getNumber(host, W.ChannelDuration, 0) else nil,
			serverNow = Workspace:GetServerTimeNow(),
			holdSince = current.holdSince,
			holdSeconds = current.holdSeconds,
			clock = now,
		})
		else nil
	local leg = current.legPoint
	if progress == nil or leg == nil then
		if current.prying and current.holdSince ~= nil and now - current.hintAt >= HINT_REPEAT_SECONDS then
			-- Still holding, but the server let go of the channel: tell them how to make it count.
			current.hintAt = now
			HUD.ShowHint(HINT_KEY)
		end
		stopPrying(current)
		return
	end
	current.prying = true
	local intensity = BearTrapController.trembleIntensity(progress)
	if now >= current.nextTrembleAt then
		current.nextTrembleAt = now + TREMBLE_INTERVAL
		FirstPersonController.Shake(BearTrapController.trembleAmplitude(intensity), TREMBLE_PULSE_SECONDS)
	end
	local yaw = FirstPersonController.GetLook()
	FirstPersonController.SetHandPose(
		"Pry",
		BearTrapController.pryTarget(leg, yaw) * BearTrapController.handJitter(now, intensity, current.seed)
	)
end

local function exitSession()
	local current = session
	if not current then
		return
	end
	session = nil
	current.trove:Destroy()
	stopPrying(current)
	InputController.PopContext(TOKEN)
	FirstPersonController.ForceCameraState(TOKEN, nil)
	FirstPersonController.SetPitchLimits(nil, nil)
	FirstPersonController.SetPanicFloor(TOKEN, nil)
	HUD.ClearHint(HINT_KEY)
	cueUntil = nil
	cueLeg = nil
end

local function enterSession(): Session
	local existing = session
	if existing then
		return existing
	end
	local now = os.clock()
	local current: Session = {
		trove = Trove.new(),
		trap = nil,
		pryHost = nil,
		legPoint = cueLeg,
		resolveAt = now,
		tilting = false,
		tiltPitch = CameraConfig.Pitch.TrappedLookDown,
		tiltStartedAt = now,
		holdSince = nil,
		holdSeconds = GameConfig.TrapSoloPrySeconds,
		prying = false,
		nextTrembleAt = now,
		hintAt = now,
		seed = (myUserId() or 0) % 997,
	}
	session = current
	adoptTrap(current, findMyTrap())
	InputController.PushContext(TRAPPED_CONTEXT, TOKEN)
	FirstPersonController.ForceCameraState(TOKEN, KNEEL_CAMERA_STATE)
	FirstPersonController.SetPanicFloor(TOKEN, TRAPPED_PANIC)
	HUD.ShowHint(HINT_KEY)
	current.trove:Connect(RunService.PreRender, function()
		if session == current then
			stepSession(current)
		end
	end)
	return current
end

-- Brings the presentation in line with the replicated state.
local function reconcile()
	local present = BearTrapController.shouldPresent(findMyTrap() ~= nil, moveStateTrapped(), cuePending())
	local current = session
	if present and not current then
		local entered = enterSession()
		beginTilt(entered)
	elseif not present and current then
		exitSession()
	end
end

--------------------------------------------------------------------------------
-- Moments
--------------------------------------------------------------------------------

-- The jaws closing on this player: the session starts now; the tilt and the jolt land with the clang.
local function onLegCue(args: { [string]: any }, startAt: unknown)
	local leg = args.legPoint
	cueLeg = if typeof(leg) == "Vector3" and MathUtil.isFiniteVector(leg) then leg else nil
	cueUntil = os.clock() + CUE_CONFIRM_SECONDS
	local current = session or enterSession()
	if cueLeg then
		current.legPoint = cueLeg
	end
	current.trove:Delay(leadTo(startAt), function()
		if session ~= current then
			return
		end
		beginTilt(current)
		FirstPersonController.Shake(SNAP_SHAKE_AMPLITUDE, SNAP_SHAKE_SECONDS)
	end)
	-- Re-check once the cue's hold runs out (the attributes normally confirmed it long before).
	serviceTrove:Delay(CUE_CONFIRM_SECONDS + 0.05, reconcile)
end

local function onPrivateCue(payload: any)
	if type(payload) ~= "table" or payload.kind ~= LEG_CUE then
		return
	end
	local args: { [string]: any } = if type(payload.args) == "table" then payload.args else {}
	onLegCue(args, payload.startAt)
end

local function onOneShot(payload: any)
	if type(payload) ~= "table" or payload.kind ~= SNAP_ONESHOT then
		return
	end
	local args: { [string]: any } = if type(payload.args) == "table" then payload.args else {}
	if args.userId == myUserId() then
		return -- the victim's own jolt comes with the TrapLeg cue
	end
	local leg = args.legPoint
	if typeof(leg) ~= "Vector3" then
		return
	end
	local startAt = payload.startAt
	if type(startAt) == "number" and Workspace:GetServerTimeNow() - startAt > GameConfig.OneShotMaxLate then
		return
	end
	local amplitude = BearTrapController.nearbyShake((FirstPersonController.GetEyeCFrame().Position - leg).Magnitude)
	if amplitude <= 0 then
		return
	end
	serviceTrove:Delay(leadTo(startAt), function()
		FirstPersonController.Shake(amplitude, SNAP_SHAKE_SECONDS * 0.6)
	end)
end

--------------------------------------------------------------------------------
-- Prompt holds (the local half of the pry)
--------------------------------------------------------------------------------

local function isPryPrompt(prompt: ProximityPrompt): boolean
	return prompt:GetAttribute(W.PromptKind) == PRY_KIND
end

local function onHoldBegan(prompt: ProximityPrompt, player: Player)
	local current = session
	if player ~= localPlayer or not current or not isPryPrompt(prompt) then
		return
	end
	local trap = current.trap
	if trap and not prompt:IsDescendantOf(trap) then
		return
	end
	current.holdSince = os.clock()
	current.holdSeconds = prompt.HoldDuration
end

local function onHoldEnded(prompt: ProximityPrompt, player: Player)
	local current = session
	if player == localPlayer and current and isPryPrompt(prompt) then
		current.holdSince = nil
	end
end

--------------------------------------------------------------------------------
-- Trap watching
--------------------------------------------------------------------------------

local watched: { [Instance]: RBXScriptConnection } = {}

local function watchTrap(instance: Instance)
	if watched[instance] or not instance:IsA("Model") then
		return
	end
	watched[instance] = instance:GetAttributeChangedSignal(W.TrappedUserId):Connect(reconcile)
	reconcile()
end

local function unwatchTrap(instance: Instance)
	local connection = watched[instance]
	if connection then
		watched[instance] = nil
		connection:Disconnect()
	end
	reconcile()
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function BearTrapController.Init()
	serviceTrove:Add(function()
		for _, connection in watched do
			connection:Disconnect()
		end
		table.clear(watched)
	end)
end

function BearTrapController.Start()
	local player = localPlayer
	if not player then
		log.warn("no local player; bear traps are not presented")
		return
	end
	serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(Tags.BearTrap), watchTrap)
	serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(Tags.BearTrap), unwatchTrap)
	for _, instance in CollectionService:GetTagged(Tags.BearTrap) do
		watchTrap(instance)
	end
	serviceTrove:Connect(player:GetAttributeChangedSignal(P.MoveState), reconcile)
	serviceTrove:Connect(ProximityPromptService.PromptButtonHoldBegan, onHoldBegan)
	serviceTrove:Connect(ProximityPromptService.PromptButtonHoldEnded, onHoldEnded)
	serviceTrove:Connect(ProximityPromptService.PromptTriggered, onHoldEnded)
	local cueConnection = Net.Client.on("PrivateCue", onPrivateCue)
	if cueConnection then
		serviceTrove:Add(cueConnection)
	end
	local oneShotConnection = Net.Client.on("OneShot", onOneShot)
	if oneShotConnection then
		serviceTrove:Add(oneShotConnection)
	end
	reconcile()
end

function BearTrapController.OnRunStarted(_info: Types.RunInfo)
	reconcile()
end

function BearTrapController.OnRunEnded()
	exitSession()
	cueUntil = nil
	cueLeg = nil
end

return table.freeze(BearTrapController)
