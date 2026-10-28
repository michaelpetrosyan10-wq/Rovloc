--!strict
-- LockerController: what a hideable locker looks and feels like on this client. LockerHidingService (server) decides
-- everything (who gets in, the door, the hold-breath verdict); this controller presents it.
--
-- Doors (everyone). OneShot "Door" / "LockerRip" whose subject is a HideableLocker carry a DoorMotion message; the
-- leaf is posed every PreRender on server time (LockerMotion.pose: Swing = setDoor, Smash = setRipped), so a door
-- swings smoothly instead of at the replication rate and ends on the pose the server lands. startAt is honoured, a
-- late message fast-forwards, a message older than the newest played for that locker is dropped. A rip shakes the
-- camera of anyone near when the door hits the floor.
--
-- Hiding (the local player). A session runs while the server has this player in a locker: from the Enter OneShot
-- (phase "Enter", occupant = me) or, failing that, a HideableLocker whose OccupantUserId is me (a respawned client),
-- until the Exit OneShot's step out is over or the occupancy is gone (a release, the Creature's catch).
--   * Camera: FirstPersonController's "Trapped" override (a body held in place) owns the view. Getting in, the eye
--     glides from where it was to the door, turns round as it backs in, and settles behind the middle slit
--     (PeekAnchor) as the door shuts (LockerMotion.enterSchedule times every beat); getting out it leans to the door
--     as it opens and steps out to the exit spot, then hands back to the base camera already looking the same way.
--     Behind the slits the look is free within YAW_LIMIT either side of straight out (pitch: the LockerPeeking range),
--     with a slow breathing sway that stills while the breath is held and trembles as the lungs run low.
--   * InputContext "Locker" (HoldBreath, Interact = step out, Flashlight, Menu), every ProximityPrompt suppressed (the
--     neighbours' Hide prompts would show through the door), both hands hooked into the slits (HandRig SlitGrip).
--   * The lungs meter (bottom centre) and a leave hint (E / X / the LEAVE touch button), dimmed while nothing happens.
-- The check. PrivateCue "BreathCheck" Window { warnAt, the server's lungs } opens the prompt at warnAt: a
-- big centred HOLD YOUR BREATH with the device's glyph (Space / A / the touch button) in a ring that counts down to the
-- window and then drains with the peek, the heartbeat driven up through the panic floor, the vignette closing in, a
-- jolt of the view as its breath first hits the slits.
-- Holding (HoldBreath) sends BreathInput { held } on every change (coalesced, resent while the server disagrees) and
-- silences the panic breathing loop; the meter is predicted locally and re-based on every Meter cue. Letting a long
-- hold go breathes out (BreathExhale). The Result cue ends the prompt ("It moves on." when safe); a catch hands the
-- camera to JumpscareController.
--
-- Pure maths (tests/Specs/Lockers.spec.luau): accept, clampYaw, enterView, exitView, promptStage, ringProgress,
-- meterColor, sway.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local DoorMotion = require(ReplicatedStorage.Shared.Sequence.DoorMotion)
local Enums = require(ReplicatedStorage.Shared.Enums)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local LockerMotion = require(ReplicatedStorage.Shared.Sequence.LockerMotion)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local Controllers = script.Parent.Parent
local AudioController = require(Controllers.Core.AudioController)
local InputController = require(Controllers.Core.InputController)
local SettingsController = require(Controllers.Core.SettingsController)
local FirstPersonController = require(Controllers.FirstPerson.FirstPersonController)
local HUD = require(Controllers.HUD)
local UIKit = require(Controllers.HUD.UIKit)

local log = Log.new("LockerClient")

local W = Attributes.World
local CUE = LockerMotion.CueArgs
local CUE_PHASE = LockerMotion.CuePhases
local ARGS = LockerMotion.Args
local Palette = UIKit.Palette

local TOKEN = "Locker"
local CONTEXT: Enums.InputContext = "Locker"
local OVERRIDE: Enums.CameraOverride = "Trapped"
local CHECK_CUE: Enums.CueKind = "BreathCheck"
local LOCKER_KINDS: { [string]: boolean } = { Door = true, LockerRip = true }

local YAW_LIMIT = math.rad(38) -- either side of straight out through the slits
local DOOR_STAND = 1.55 -- studs in front of the door the eye pauses at before backing in
local ENTER_DIP = 0.35 -- the eye ducks this much as it squeezes in
local RESOLVE_INTERVAL = 0.25 -- seconds between searches for a locker holding me without an Enter message
local ORPHAN_GRACE = 1 -- seconds a fresh session waits for its occupancy to replicate
local SEND_INTERVAL = 0.2 -- BreathInput is coalesced to at most this often
local RESEND_AFTER = 0.35 -- seconds the server may disagree about the hold before it is sent again
local EXHALE_AFTER = 1.2 -- a hold this long is let go with an audible breath out
local RESULT_LINGER = 1.4 -- seconds the prompt stays after the verdict
local HAND_IN = 0.28 -- studs ahead of the eye the fingertips hook into the slits
local SWAY_PITCH = math.rad(0.55)
local SWAY_ROLL = math.rad(0.4)
local SWAY_LIFT = 0.025
local TREMBLE_BELOW = 0.35 -- share of the lungs under which the view trembles
local TREMBLE_DEGREES = 0.9
local FLINCH_DEGREES = 0.7 -- the jolt as its breath first hits the slits
local FLINCH_SECONDS = 0.35
local RIP_SHAKE_RADIUS = 22
local RIP_SHAKE = 2.6
local RIP_LANDS = 0.55 -- of the rip's length: the torn door hits the floor
local HIDDEN_PANIC = 0.3
local WARN_PANIC = 0.78
local WINDOW_PANIC = 0.97
local SAFE_PANIC = 0.45
local DISPLAY_ORDER = 22

export type Stage = "Idle" | "Warn" | "Window" | "Result"

-- The check as this client knows it (server times).
export type Window = {
	warnAt: number,
	startAt: number,
	endsAt: number,
	verdict: string?,
	resultAt: number?,
}

type Playing = { model: Model, motion: DoorMotion.Motion }

type Ui = {
	gui: ScreenGui,
	vignette: UIKit.Vignette,
	meterRoot: Frame,
	meterLabel: TextLabel,
	meter: UIKit.MeterBar,
	leaveHint: TextLabel,
	leaveButton: UIKit.RoundButton,
	prompt: Frame,
	ring: UIKit.Ring,
	keyCap: UIKit.KeyCap,
	title: TextLabel,
	sub: TextLabel,
}

type Session = {
	locker: Model,
	trove: Trove.Trove,
	phase: "Entering" | "Hidden" | "Exiting",
	schedule: LockerMotion.Schedule?,
	fromEye: CFrame,
	peek: CFrame,
	outYaw: number,
	exitEye: CFrame?,
	settled: boolean,
	breath: LockerMotion.Breath,
	held: boolean,
	heldSince: number?,
	serverHeld: boolean,
	lastSentAt: number,
	sentHeld: boolean?,
	window: Window?,
	panic: number,
	seed: number,
	ui: Ui?,
	alpha: number,
	promptAlpha: number,
	startedClock: number,
	flinched: boolean, -- the jolt when its breath first hits the slits
}

local LockerController = {}

LockerController.Name = "LockerController"
LockerController.YawLimit = YAW_LIMIT

local serviceTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local playing: { [Model]: Playing } = {}
local lastMotion: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local session: Session? = nil
local resolveClock = 0
local pendingShakes: { [Model]: thread } = {}

--------------------------------------------------------------------------------
-- Pure maths (specs: tests/Specs/Lockers.spec.luau)
--------------------------------------------------------------------------------

-- Whether a door message with `motionId` should play over the newest one played for that locker.
function LockerController.accept(lastId: number?, motionId: number): boolean
	return lastId == nil or motionId > lastId
end

-- `yaw` kept within YAW_LIMIT of `outYaw` (radians, wrapped).
function LockerController.clampYaw(yaw: number, outYaw: number): number
	local relative = math.clamp(MathUtil.angleDelta(outYaw, yaw), -YAW_LIMIT, YAW_LIMIT)
	return MathUtil.wrapAngle(outYaw + relative)
end

local function smooth(t: number): number
	local x = MathUtil.clamp01(t)
	return x * x * (3 - 2 * x)
end

local function blend(a: CFrame, b: CFrame, t: number): CFrame
	return a:Lerp(b, smooth(t))
end

-- The camera climbing in at server time `now`: from `fromEye` to the door (facing in), backing in while it turns
-- round, then behind the slits (`peek`, looking out) as the door shuts.
function LockerController.enterView(schedule: LockerMotion.Schedule, fromEye: CFrame, peek: CFrame, now: number): CFrame
	local outward = peek.LookVector
	local stand = peek.Position + outward * DOOR_STAND - Vector3.new(0, ENTER_DIP * 0.5, 0)
	local facingIn = CFrame.lookAt(stand, stand - outward)
	if now <= schedule.openAt then
		return fromEye
	end
	if now < schedule.moveAt then
		return blend(fromEye, facingIn, (now - schedule.openAt) / (schedule.moveAt - schedule.openAt))
	end
	local backIn = schedule.closeAt - schedule.moveAt
	local t = if backIn > 0 then MathUtil.clamp01((now - schedule.moveAt) / backIn) else 1
	if t >= 1 then
		return peek
	end
	-- turning round from facing in to facing out (most of it early), backing in, ducking under the shelf
	local outYaw, outPitch = MathUtil.yawPitchFromVector(outward)
	local turn = smooth(math.min(1, t / 0.7))
	local position = stand:Lerp(peek.Position, smooth(t)) - Vector3.new(0, ENTER_DIP * math.sin(math.pi * t), 0)
	return CFrame.new(position) * CFrame.fromOrientation(outPitch * turn, outYaw + math.pi * (1 - turn), 0)
end

-- The camera stepping out at server time `now`: a lean to the door as it opens, then out to `exitEye`.
function LockerController.exitView(schedule: LockerMotion.Schedule, peek: CFrame, exitEye: CFrame, now: number): CFrame
	if now <= schedule.openAt then
		return peek
	end
	local lean = peek * CFrame.new(0, -0.05, -0.18)
	if now < schedule.moveAt then
		return blend(peek, lean, (now - schedule.openAt) / (schedule.moveAt - schedule.openAt))
	end
	local out = schedule.closeAt - schedule.moveAt
	local t = if out > 0 then MathUtil.clamp01((now - schedule.moveAt) / out) else 1
	return blend(lean, exitEye, t)
end

-- Which part of a check the prompt shows at server time `now`.
function LockerController.promptStage(window: Window?, now: number): Stage
	if not window then
		return "Idle"
	end
	local resultAt = window.resultAt
	if resultAt then
		return if now - resultAt < RESULT_LINGER then "Result" else "Idle"
	end
	if now < window.warnAt then
		return "Idle"
	end
	if now < window.startAt then
		return "Warn"
	end
	if now < window.endsAt then
		return "Window"
	end
	return "Result"
end

-- The ring: filling toward the window while warned, then draining with the peek.
function LockerController.ringProgress(window: Window, now: number): number
	if now < window.startAt then
		local warn = window.startAt - window.warnAt
		return if warn > 0 then MathUtil.clamp01((now - window.warnAt) / warn) else 1
	end
	local peek = window.endsAt - window.startAt
	return if peek > 0 then 1 - MathUtil.clamp01((now - window.startAt) / peek) else 0
end

-- The lungs meter's colour for `fraction` of a breath: bone, amber at half, blood once a release would be a gasp.
function LockerController.meterColor(fraction: number): Color3
	if fraction < LockerMotion.CalmFraction then
		return Palette.Ember
	elseif fraction < 0.5 then
		return Palette.Amber
	end
	return Palette.Bone
end

-- The slow breathing sway behind the slits at time `t` (seconds): stilled while holding (`held`), a tremble as the
-- lungs run low (`fraction`), all scaled by the MotionScale setting.
function LockerController.sway(t: number, held: boolean, fraction: number, scale: number, seed: number): CFrame
	local amount = MathUtil.clamp01(scale)
	if amount <= 0 then
		return CFrame.identity
	end
	local calm = if held then 0.25 else 1
	local phase = t * 2 * math.pi * 0.24
	local pitch = SWAY_PITCH * math.sin(phase) * calm
	local roll = SWAY_ROLL * math.sin(phase * 0.5 + 0.7) * calm
	local lift = SWAY_LIFT * math.sin(phase) * calm
	local tremble = if held then MathUtil.clamp01((TREMBLE_BELOW - fraction) / TREMBLE_BELOW) else 0
	if tremble > 0 then
		local degrees = math.rad(TREMBLE_DEGREES) * tremble
		pitch += degrees * MathUtil.noise1(t * 11, seed)
		roll += degrees * 0.6 * MathUtil.noise1(t * 13, seed + 17)
	end
	return CFrame.new(0, lift * amount, 0) * CFrame.Angles(pitch * amount, 0, roll * amount)
end

--------------------------------------------------------------------------------
-- Doors
--------------------------------------------------------------------------------

local function isLocker(instance: unknown): boolean
	if typeof(instance) ~= "Instance" then
		return false
	end
	local candidate = instance :: Instance
	return candidate:IsA("Model") and candidate:HasTag(Tags.HideableLocker)
end

local function render(entry: Playing, now: number): boolean
	local value, done = DoorMotion.valueAt(entry.motion, now)
	LockerMotion.pose(entry.model, entry.motion.mode, value)
	return done
end

local function shakeOnLanding(model: Model, motion: DoorMotion.Motion, now: number)
	local landsAt = motion.startAt + motion.seconds * RIP_LANDS
	local wait = landsAt - now
	if wait < -0.3 or wait > 3 then
		return
	end
	local previous = pendingShakes[model]
	if previous and coroutine.status(previous) == "suspended" then
		task.cancel(previous)
	end
	pendingShakes[model] = task.delay(math.max(0, wait), function()
		pendingShakes[model] = nil
		local base = model.PrimaryPart
		if not base then
			return
		end
		local distance = (FirstPersonController.GetEyeCFrame().Position - base.CFrame.Position).Magnitude
		if distance < RIP_SHAKE_RADIUS then
			local falloff = 1 - distance / RIP_SHAKE_RADIUS
			FirstPersonController.Shake(RIP_SHAKE * falloff * falloff, 0.6)
		end
	end)
end

-- Plays `message` on locker `model` at server time `now`. False when it is older than what the locker played.
function LockerController.Apply(model: Model, message: DoorMotion.Message, now: number): boolean
	if not LockerController.accept(lastMotion[model], message.motionId) then
		return false
	end
	lastMotion[model] = message.motionId
	local entry: Playing = { model = model, motion = message.motion }
	playing[model] = entry
	if render(entry, now) then
		playing[model] = nil
	end
	if message.motion.mode == "Smash" then
		shakeOnLanding(model, message.motion, now)
	end
	return true
end

-- One frame of every playing locker door at server time `now` (the PreRender step).
function LockerController.Render(now: number)
	for model, entry in playing do
		if model.Parent == nil then
			playing[model] = nil
			continue
		end
		if render(entry, now) then
			playing[model] = nil
		end
	end
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

local function deviceGlyph(): (UIKit.GlyphKind, Enum.KeyCode?)
	local device = InputController.GetDevice()
	local binding = InputConfig.Bindings.HoldBreath
	if device == "Gamepad" then
		return "Gamepad", binding.gamepad[1]
	elseif device == "Touch" then
		return "Touch", nil
	end
	for _, input in binding.keyboard do
		if input.EnumType == Enum.KeyCode then
			return "Keyboard", (input :: any) :: Enum.KeyCode
		end
	end
	return "Keyboard", nil
end

local function buildUi(player: Player, onLeave: () -> ()): Ui?
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end
	local gui = UIKit.screenGui("LockerView", DISPLAY_ORDER, Enum.ScreenInsets.CoreUISafeInsets)
	gui.IgnoreGuiInset = true
	local root = UIKit.frame(gui, "Root")
	local vignette = UIKit.vignette(root, "Dark", Palette.Ink, 0.34, 0.05)

	local meterRoot = UIKit.frame(root, "Lungs")
	meterRoot.AnchorPoint = Vector2.new(0.5, 1)
	meterRoot.Position = UDim2.new(0.5, 0, 1, -54)
	meterRoot.Size = UDim2.fromOffset(240, 40)
	local meterLabel = UIKit.label(meterRoot, "Label", UIKit.Fonts.Strong, UIKit.TextSize.Caps, Palette.Ash)
	meterLabel.Size = UDim2.new(1, 0, 0, 14)
	meterLabel.Text = Strings.get("Hud.Breath")
	local meter = UIKit.meterBar(meterRoot, "Bar", Palette.Bone, 6)
	meter.root.Position = UDim2.fromOffset(0, 18)
	local leaveHint = UIKit.label(meterRoot, "Leave", UIKit.Fonts.Body, UIKit.TextSize.Small, Palette.Smoke)
	leaveHint.Size = UDim2.new(1, 0, 0, 16)
	leaveHint.Position = UDim2.fromOffset(0, 28)

	local leaveButton = UIKit.roundButton(root, "LeaveButton", Strings.get("Input.LeaveLocker"), 72)
	leaveButton.button.Position = UDim2.new(0, 96, 1, -120)
	leaveButton.button.Activated:Connect(onLeave)

	local prompt = UIKit.frame(root, "Prompt")
	prompt.AnchorPoint = Vector2.new(0.5, 0.5)
	prompt.Position = UDim2.fromScale(0.5, 0.6)
	prompt.Size = UDim2.fromOffset(420, 200)
	local ring = UIKit.ring(prompt, "Ring", 96, 5, Palette.Bone)
	ring.root.AnchorPoint = Vector2.new(0.5, 0)
	ring.root.Position = UDim2.fromScale(0.5, 0)
	local keyCap = UIKit.keyCap(ring.root, "Glyph", 54)
	keyCap.root.AnchorPoint = Vector2.new(0.5, 0.5)
	keyCap.root.Position = UDim2.fromScale(0.5, 0.5)
	local title = UIKit.label(prompt, "Title", UIKit.Fonts.Title, UIKit.TextSize.Display, Palette.Bone)
	title.Size = UDim2.new(1, 0, 0, 46)
	title.Position = UDim2.fromOffset(0, 104)
	title.Text = Strings.get("Hud.HoldBreathNow")
	UIKit.textStroke(title, 0.4)
	local sub = UIKit.label(prompt, "Sub", UIKit.Fonts.Body, UIKit.TextSize.Hint, Palette.Ash)
	sub.Size = UDim2.new(1, 0, 0, 24)
	sub.Position = UDim2.fromOffset(0, 154)
	UIKit.textStroke(sub, 0.5)

	local scale = Instance.new("UIScale")
	scale.Parent = root
	local function rescale()
		local camera = Workspace.CurrentCamera
		if camera then
			scale.Scale = UIKit.scaleFor(camera.ViewportSize)
		end
	end
	rescale()
	gui.Parent = playerGui
	return {
		gui = gui,
		vignette = vignette,
		meterRoot = meterRoot,
		meterLabel = meterLabel,
		meter = meter,
		leaveHint = leaveHint,
		leaveButton = leaveButton,
		prompt = prompt,
		ring = ring,
		keyCap = keyCap,
		title = title,
		sub = sub,
	}
end

local function setPromptAlpha(ui: Ui, alpha: number)
	ui.ring:SetAlpha(alpha)
	ui.keyCap:SetAlpha(alpha)
	UIKit.setTextTransparency(ui.title, UIKit.fade(0, alpha))
	UIKit.setTextTransparency(ui.sub, UIKit.fade(0, alpha))
	ui.prompt.Visible = alpha > 0.01
end

--------------------------------------------------------------------------------
-- Breath input
--------------------------------------------------------------------------------

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function sendHeld(current: Session, now: number)
	current.lastSentAt = now
	current.sentHeld = current.held
	xpcall(Net.Client.fire, function(err: any)
		log.warnThrottled("breath", 10, "BreathInput failed: %s", tostring(err))
	end, "BreathInput", { held = current.held })
end

local function onHoldBreath(phase: InputController.Phase)
	local current = session
	if not current or current.phase == "Exiting" then
		return
	end
	local held = phase == "Begin"
	if held == current.held then
		return
	end
	local now = serverNow()
	current.held = held
	current.breath = LockerMotion.setHeld(current.breath, held, now)
	FirstPersonController.SuppressBreathing(TOKEN, held)
	if held then
		current.heldSince = now
	else
		local since = current.heldSince
		current.heldSince = nil
		if since and now - since >= EXHALE_AFTER then
			local left = LockerMotion.fraction(LockerMotion.breathAt(current.breath, now))
			AudioController.PlayLocal("BreathExhale", { volume = 0.55 + 0.65 * (1 - left) })
		end
	end
	if now - current.lastSentAt >= SEND_INTERVAL then
		sendHeld(current, now)
	end
end

local function requestExit()
	local current = session
	if not current or current.phase ~= "Hidden" then
		return
	end
	local stage = LockerController.promptStage(current.window, serverNow())
	if stage == "Warn" or stage == "Window" then
		return
	end
	xpcall(Net.Client.fire, function(err: any)
		log.warnThrottled("exit", 10, "ExitHide failed: %s", tostring(err))
	end, "ExitHide", {})
end

--------------------------------------------------------------------------------
-- Session
--------------------------------------------------------------------------------

local function anchorCFrame(model: Model, name: string): CFrame?
	local base = model.PrimaryPart
	local attachment = if base then base:FindFirstChild(name) else nil
	if base and attachment and attachment:IsA("Attachment") then
		return base.CFrame * attachment.CFrame
	end
	return nil
end

local function exitEyeFor(model: Model): CFrame?
	local exit = anchorCFrame(model, "ExitAnchor")
	if not exit then
		return nil
	end
	local height = 3 + CameraConfig.EyeHeightAboveRoot.Standing
	return exit * CFrame.new(0, height, 0)
end

local function viewFor(current: Session, now: number): CFrame
	local schedule = current.schedule
	if current.phase == "Entering" and schedule and now < schedule.closeAt then
		return LockerController.enterView(schedule, current.fromEye, current.peek, now)
	end
	local exitEye = current.exitEye
	if current.phase == "Exiting" and schedule and exitEye then
		return LockerController.exitView(schedule, current.peek, exitEye, now)
	end
	-- behind the slits: the player's own look, kept facing out
	local yaw, pitch = FirstPersonController.GetLook()
	local clamped = LockerController.clampYaw(yaw, current.outYaw)
	if math.abs(MathUtil.angleDelta(clamped, yaw)) > 1e-4 then
		FirstPersonController.SetLook(clamped, pitch)
	end
	local fraction = LockerMotion.fraction(LockerMotion.breathAt(current.breath, now))
	local motion = SettingsController.GetNumber("MotionScale")
	local view = CFrame.new(current.peek.Position) * CFrame.fromOrientation(pitch, clamped, 0)
	return view * LockerController.sway(os.clock(), current.held, fraction, motion, current.seed)
end

local function endSession()
	local current = session
	if not current then
		return
	end
	session = nil
	FirstPersonController.PopOverride(OVERRIDE)
	if current.phase == "Exiting" then
		FirstPersonController.SetLook(current.outYaw, 0)
	end
	current.trove:Destroy()
end

local function startSession(model: Model, schedule: LockerMotion.Schedule?)
	local player = localPlayer
	local peek = anchorCFrame(model, "PeekAnchor")
	if not (player and peek) then
		return
	end
	if session then
		endSession()
	end
	local now = serverNow()
	local outYaw = select(1, MathUtil.yawPitchFromVector(peek.LookVector))
	local current: Session = {
		locker = model,
		trove = Trove.new(),
		phase = if schedule then "Entering" else "Hidden",
		schedule = schedule,
		fromEye = FirstPersonController.GetEyeCFrame(),
		peek = peek,
		outYaw = outYaw,
		exitEye = nil,
		settled = schedule == nil,
		breath = LockerMotion.fullBreath(now),
		held = false,
		heldSince = nil,
		serverHeld = false,
		lastSentAt = -math.huge,
		sentHeld = nil,
		window = nil,
		panic = HIDDEN_PANIC,
		seed = MathUtil.hash(Attributes.getString(model, W.AnchorId, model.Name)) % 1000,
		ui = nil,
		alpha = 0,
		promptAlpha = 0,
		startedClock = os.clock(),
		flinched = false,
	}
	session = current
	local trove = current.trove
	InputController.PushContext(CONTEXT, TOKEN)
	trove:Add(function()
		InputController.PopContext(TOKEN)
	end)
	HUD.SetPromptsSuppressed(TOKEN, true)
	trove:Add(function()
		HUD.SetPromptsSuppressed(TOKEN, false)
	end)
	FirstPersonController.SetPanicFloor(TOKEN, HIDDEN_PANIC)
	trove:Add(function()
		FirstPersonController.SetPanicFloor(TOKEN, nil)
		FirstPersonController.SuppressBreathing(TOKEN, false)
	end)
	FirstPersonController.SetHandPose("SlitGrip", peek * CFrame.new(0, -0.05, -HAND_IN))
	trove:Add(function()
		FirstPersonController.SetHandPose("Flashlight")
	end)
	if not schedule then
		FirstPersonController.SetLook(outYaw, 0)
	end
	FirstPersonController.PushOverride(OVERRIDE, {
		cframe = function(): CFrame
			local live = session
			if live ~= current then
				return current.peek
			end
			return viewFor(current, serverNow())
		end,
		blendIn = 0.05,
		blendOut = 0.25,
	})
	local ui = buildUi(player, requestExit)
	if ui then
		current.ui = ui
		trove:Add(ui.gui)
	end
	-- a hold already in progress when the session starts is sent at once
	if InputController.IsHeld("HoldBreath") then
		onHoldBreath("Begin")
	end
end

local function beginExit(current: Session, schedule: LockerMotion.Schedule)
	current.phase = "Exiting"
	current.schedule = schedule
	current.exitEye = exitEyeFor(current.locker) or current.peek
	current.window = nil
	if current.held then
		onHoldBreath("End")
	end
end

-- The shut locker whose OccupantUserId is me (nil when none). A door still moving belongs to an Enter or Exit
-- message on its way.
local function myLocker(): Model?
	local player = localPlayer
	if not player then
		return nil
	end
	for _, instance in CollectionService:GetTagged(Tags.HideableLocker) do
		if
			instance:IsA("Model")
			and instance:GetAttribute(W.OccupantUserId) == player.UserId
			and instance:GetAttribute(W.DoorOpen) ~= true
		then
			return instance
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Cues
--------------------------------------------------------------------------------

local function onOneShot(payload: any)
	if type(payload) ~= "table" or not LOCKER_KINDS[payload.kind] or not isLocker(payload.subject) then
		return
	end
	local args = payload.args
	local startAt = payload.startAt
	if type(args) ~= "table" or type(startAt) ~= "number" then
		return
	end
	local message = DoorMotion.fromArgs(args, startAt)
	if not message then
		log.warnThrottled("malformed", 10, "malformed locker %s OneShot dropped", tostring(payload.kind))
		return
	end
	local model = payload.subject :: Model
	LockerController.Apply(model, message, serverNow())
	local player = localPlayer
	if not player or args[ARGS.Occupant] ~= player.UserId then
		return
	end
	local phase = args[ARGS.Phase]
	if phase == "Enter" then
		startSession(model, LockerMotion.enterSchedule(startAt))
	elseif phase == "Exit" then
		local current = session
		if current and current.locker == model then
			beginExit(current, LockerMotion.exitSchedule(startAt))
		end
	end
end

local function onCue(payload: any)
	if type(payload) ~= "table" or payload.kind ~= CHECK_CUE or type(payload.args) ~= "table" then
		return
	end
	local current = session
	if not current then
		return
	end
	local args = payload.args
	local phase = args[CUE.Phase]
	local value, held, at = args[CUE.Breath], args[CUE.Held], args[CUE.BreathAt]
	if type(value) == "number" and type(held) == "boolean" and type(at) == "number" then
		-- the server's lungs win; a hold change still in flight is replayed on top
		current.breath = { value = math.clamp(value, 0, LockerMotion.BreathMax), held = held, at = at }
		current.serverHeld = held
		if held ~= current.held then
			current.breath = LockerMotion.setHeld(current.breath, current.held, serverNow())
		end
	end
	if phase == CUE_PHASE.Window then
		local warnAt = args[CUE.WarnAt]
		if type(payload.startAt) == "number" and type(payload.endsAt) == "number" and type(warnAt) == "number" then
			current.window = {
				warnAt = warnAt,
				startAt = payload.startAt,
				endsAt = payload.endsAt,
				verdict = nil,
				resultAt = nil,
			}
			current.flinched = false
		end
	elseif phase == CUE_PHASE.Result then
		local window = current.window
		if window then
			window.verdict = if type(args[CUE.Verdict]) == "string" then args[CUE.Verdict] else nil
			window.resultAt = if type(payload.startAt) == "number" then payload.startAt else serverNow()
		end
	end
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function stepUi(current: Session, ui: Ui, dt: number, now: number)
	local stage = LockerController.promptStage(current.window, now)
	local showing = current.phase ~= "Exiting"
	current.alpha = MathUtil.approach(current.alpha, if showing then 1 else 0, dt * 4)
	ui.vignette:SetAlpha(current.alpha)
	local fraction = LockerMotion.fraction(LockerMotion.breathAt(current.breath, now))
	local active = stage ~= "Idle"
	local meterAlpha = current.alpha * (if active or fraction < 0.98 then 1 else 0.45)
	local low = fraction < LockerMotion.CalmFraction
	local pulse = if low then 0.75 + 0.25 * math.sin(now * 14) else 1
	ui.meter:SetFraction(fraction)
	ui.meter:SetColor(LockerController.meterColor(fraction))
	ui.meter:SetAlpha(meterAlpha * pulse)
	UIKit.setTextTransparency(ui.meterLabel, UIKit.fade(0.2, meterAlpha))

	local device = InputController.GetDevice()
	local canLeave = current.phase == "Hidden" and not active
	ui.leaveHint.Text = Strings.get("Hud.LockerLeave." .. device)
	UIKit.setTextTransparency(ui.leaveHint, UIKit.fade(0.25, current.alpha * (if canLeave then 1 else 0)))
	local touch = device == "Touch" and canLeave
	ui.leaveButton.button.Visible = touch
	ui.leaveButton:SetAlpha(current.alpha)
	ui.leaveButton:Step(dt)

	current.promptAlpha = MathUtil.approach(current.promptAlpha, if active then 1 else 0, dt * 6)
	setPromptAlpha(ui, current.promptAlpha * current.alpha)
	local window = current.window
	if window and active then
		local kind: UIKit.GlyphKind, key: Enum.KeyCode? = deviceGlyph()
		ui.keyCap:SetGlyph(kind, key)
		if stage == "Result" then
			ui.ring:SetProgress(0)
			ui.title.Text = if window.verdict == "HiddenSafe" then "" else Strings.get("Hud.HoldBreathNow")
			ui.sub.Text = if window.verdict == "HiddenSafe" then Strings.get("Hud.BreathSafe") else ""
		else
			ui.ring:SetProgress(LockerController.ringProgress(window, now))
			ui.title.Text = Strings.get("Hud.HoldBreathNow")
			ui.sub.Text = if stage == "Window" and current.held
				then Strings.get("Hud.KeepHolding")
				else Strings.get("Hud.HoldBreath")
		end
		local urgent = stage == "Window" and not current.held
		local flash = if urgent then 0.5 + 0.5 * math.sin(now * 18) else 1
		ui.ring:SetColor(if urgent then Palette.Ember:Lerp(Palette.Bone, flash) else Palette.Bone)
		ui.title.TextColor3 = if urgent then Palette.Ember:Lerp(Palette.Bone, flash) else Palette.Bone
	end
end

local function stepPanic(current: Session, dt: number, now: number)
	local stage = LockerController.promptStage(current.window, now)
	local target = HIDDEN_PANIC
	if stage == "Warn" then
		target = WARN_PANIC
	elseif stage == "Window" then
		target = WINDOW_PANIC
	elseif stage == "Result" then
		target = SAFE_PANIC
	end
	local speed = if target > current.panic then 2.5 else 0.25
	current.panic = MathUtil.approach(current.panic, target, dt * speed)
	FirstPersonController.SetPanicFloor(TOKEN, current.panic)
end

local function stepSession(dt: number)
	local current = session
	if not current then
		return
	end
	local now = serverNow()
	local player = localPlayer
	if current.locker.Parent == nil or not player then
		endSession()
		return
	end
	local mine = current.locker:GetAttribute(W.OccupantUserId) == player.UserId
	if current.phase == "Exiting" then
		local schedule = current.schedule
		if schedule and now >= schedule.closeAt then
			endSession()
			return
		end
	elseif not mine and (current.settled or os.clock() - current.startedClock > ORPHAN_GRACE) then
		-- released or caught: the occupancy is gone without a step out
		endSession()
		return
	end
	if current.phase == "Entering" then
		local schedule = current.schedule
		if schedule and now >= schedule.closeAt then
			current.phase = "Hidden"
			current.settled = true
			current.schedule = nil
			FirstPersonController.SetLook(current.outYaw, 0)
		end
	end
	-- a hold the server has not heard yet (coalesced; resent while it disagrees)
	if current.held ~= current.serverHeld then
		local due = current.sentHeld ~= current.held or now - current.lastSentAt >= RESEND_AFTER
		if due and now - current.lastSentAt >= SEND_INTERVAL then
			sendHeld(current, now)
		end
	end
	if not current.flinched and LockerController.promptStage(current.window, now) == "Window" then
		current.flinched = true
		FirstPersonController.Shake(FLINCH_DEGREES, FLINCH_SECONDS)
	end
	stepPanic(current, dt, now)
	local ui = current.ui
	if ui then
		stepUi(current, ui, dt, now)
	end
end

local function resolveOrphan(dt: number)
	if session then
		return
	end
	resolveClock += dt
	if resolveClock < RESOLVE_INTERVAL then
		return
	end
	resolveClock = 0
	local model = myLocker()
	if model then
		startSession(model, nil)
	end
end

local function step(dt: number)
	local now = serverNow()
	if next(playing) ~= nil then
		LockerController.Render(now)
	end
	resolveOrphan(dt)
	stepSession(dt)
end

local function clear()
	endSession()
	for model, thread in table.clone(pendingShakes) do
		pendingShakes[model] = nil
		if coroutine.status(thread) == "suspended" then
			task.cancel(thread)
		end
	end
	table.clear(playing)
	table.clear(lastMotion)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function LockerController.Init()
	serviceTrove:Add(clear)
	serviceTrove:Add(InputController.Action("HoldBreath"):Connect(onHoldBreath))
	serviceTrove:Add(InputController.Action("Interact"):Connect(function(phase: InputController.Phase)
		if phase == "Begin" and InputController.GetContext() == CONTEXT then
			requestExit()
		end
	end))
end

function LockerController.Start()
	local shots = Net.Client.on("OneShot", onOneShot)
	if shots then
		serviceTrove:Add(shots)
	end
	local cues = Net.Client.on("PrivateCue", onCue)
	if cues then
		serviceTrove:Add(cues)
	end
	serviceTrove:Connect(RunService.PreRender, function(dt: number)
		xpcall(step, function(err: any)
			log.warnThrottled("step", 5, "locker frame failed: %s\n%s", tostring(err), debug.traceback())
		end, dt)
	end)
end

function LockerController.OnRunStarted(_info: Types.RunInfo)
	clear()
end

function LockerController.OnRunEnded()
	clear()
end

-- Whether the local player is hiding in a locker (entering, hidden or stepping out).
function LockerController.IsHiding(): boolean
	return session ~= nil
end

return table.freeze(LockerController)
