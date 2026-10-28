--!strict
-- StruggleController: being dragged under by the Creature, on the victim's client. FloodedPoolService judges the
-- struggle (every press, the rate cap, the decay, every way out, the drowning); this controller presents it and
-- sends the presses.
--
-- Session. It starts with the PrivateCue "Struggle" {phase Start, needed, creature, drag} (or, should the cue be
-- late, the moment the replicated MoveState reads Grabbed under the Drag lock) and ends with the cue's phase End
-- {outcome} (or when the MoveState has left Grabbed for EndGrace seconds). While it runs:
--   * InputContext "Struggle": the Struggle action (Space, gamepad A, the big touch button MobileControls draws for
--     this context) is the only one live. Every press is checked against the same rule the server applies
--     (WaterRules.wouldCount: a fresh sequence number, at most StruggleMaxPressesPerSecond in any second): a press
--     that would count goes out as StrugglePress {sequence} and moves the predicted progress, one that would be
--     dropped is not sent at all (never banked, never wasted on the rate limiter). Server Progress cues reconcile the
--     prediction (a gap of more than ReconcileGap presses snaps to the server's count).
--   * The mash UI (HUD layer, safe insets, scaled to the screen): the Hud.Struggle line, the device's key glyph
--     (UIKit keyCap: Space / A / a tap) with "MASH", and the escape bar filling with the progress; each counted press
--     punches the glyph and the bar.
--   * The camera (FirstPersonController override "Struggle"): the player's own view dragged down toward the Creature's
--     face under them (Scenes.Pulled; harder while the drag is pulling and whenever it yanks), shaking with the thrash,
--     yanked down every TugMin..TugMax seconds (a sharp dip and pitch with a jolt), each press jerking it back up a
--     little; all scaled by the MotionScale setting.
--   * The body: the oxygen bar (StatusBars) keeps draining in view; the screen darkens and the vignette closes in as
--     the air runs out (darkness, pure), a panic floor of 1 drives the heartbeat (the breathing loop held: no air to
--     breathe; ProximityPrompts suppressed: nothing can be used while held); bubbles stream from the mouth
--     (SwimController.EmitBubbles) with every press and all the while; the PlayerR15 Grabbed pose flails the arms.
-- Ending: everything above is released; broken free (Escaped, Flask, Floodlight, LetGo) kicks the swimmer up toward
-- the surface (SwimController.Kick), a burst of bubbles and Hud.StruggleFree. Caught / Drowned leave the screen to the
-- jumpscare or the downed state. Death, respawn and the run ending release it too.
--
-- Pure maths (tests/Specs/Pool.spec.luau): shouldStart, shouldEnd, darkness, pullWeight, tugEnvelope, nextTug,
-- shakeAngles, reconcile, isFreed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Scenes = require(ReplicatedStorage.Shared.Sequence.Scenes)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local WaterRules = require(ReplicatedStorage.Shared.Util.WaterRules)

local Controllers = script.Parent.Parent
local InputController = require(Controllers.Core.InputController)
local SettingsController = require(Controllers.Core.SettingsController)
local FirstPersonController = require(Controllers.FirstPerson.FirstPersonController)
local HUD = require(Controllers.HUD)
local UIKit = require(Controllers.HUD.UIKit)
local SwimController = require(script.Parent.SwimController)

local log = Log.new("StruggleClient")

local P = Attributes.Player
local Palette = UIKit.Palette

export type StartInput = { engaged: boolean, cueStarted: boolean, moveState: string, controlLock: string }
export type EndInput = { engaged: boolean, cueEnded: boolean, grabbedFor: number, notGrabbedFor: number }

type View = {
	gui: ScreenGui,
	scale: UIScale,
	panel: CanvasGroup,
	pulse: UIScale,
	title: TextLabel,
	mash: TextLabel,
	glyph: UIKit.KeyCap,
	bar: UIKit.MeterBar,
	dark: Frame,
	vignette: UIKit.Vignette,
}

type Session = {
	trove: Trove.Trove,
	startedAt: number, -- os.clock()
	needed: number,
	drag: number,
	creature: Vector3?,
	struggle: WaterRules.Struggle,
	sequence: number,
	nextTugAt: number,
	tugAt: number,
	jerkAt: number,
	nextBubblesAt: number,
	seed: number,
	notGrabbedSince: number?,
	ended: boolean,
}

local TOKEN = "Struggle"
local CONTEXT: Enums.InputContext = "Struggle"
local OVERRIDE: Enums.CameraOverride = "Struggle"
local CUE_KIND = "Struggle"
local GRABBED = "Grabbed"
local DRAG_LOCK = "Drag"
local SCREEN_ORDER = 6
local END_GRACE = 0.6 -- seconds out of Grabbed that end a session whose End cue never came
local CUE_LATE_START = 0.4 -- seconds the Grabbed state must hold before it starts a session without a cue
local RECONCILE_GAP = 2
local TUG_MIN = 0.8
local TUG_MAX = 1.5
local TUG_SECONDS = 0.3
local JERK_SECONDS = 0.18
local PULL_BASE = 0.5
local PULL_DRAG = 0.85
local PULL_TUG = 0.3
local SHAKE_DEGREES = 2.6
local TUG_PITCH = math.rad(8)
local TUG_DIP = 0.22
local JERK_PITCH = math.rad(3)
local BUBBLE_INTERVAL = 0.45
local FREE_KICK_SPEED = 7.5
local FREE_KICK_SECONDS = 0.7
local FREE_HINT_SECONDS = 2.5
local FOV_SQUEEZE = 6
local PANEL_WIDTH = 320
local PANEL_BOTTOM = 230 -- pixels from the bottom: clear of the touch Struggle button
local GLYPH_SIZE = 64
local BAR_HEIGHT = 10
local FREED: { [string]: boolean } = { Escaped = true, Flask = true, Floodlight = true, LetGo = true }

local StruggleController = {}

StruggleController.Name = "StruggleController"
StruggleController.EndGrace = END_GRACE
StruggleController.TugMin = TUG_MIN
StruggleController.TugMax = TUG_MAX
StruggleController.ReconcileGap = RECONCILE_GAP

local localPlayer: Player? = Players.LocalPlayer
local serviceTrove = Trove.new()
local session: Session? = nil
local view: View? = nil
local grabbedSince: number? = nil
local motionScale = 1

--------------------------------------------------------------------------------
-- Pure maths
--------------------------------------------------------------------------------

-- Whether a session starts: the Start cue arrived, or the body has read Grabbed under the Drag lock for a moment.
function StruggleController.shouldStart(input: StartInput): boolean
	if input.engaged then
		return false
	end
	return input.cueStarted or (input.moveState == GRABBED and input.controlLock == DRAG_LOCK)
end

-- Whether a running session ends: the End cue arrived, or the body has been out of Grabbed for EndGrace seconds.
function StruggleController.shouldEnd(input: EndInput): boolean
	if not input.engaged then
		return false
	end
	return input.cueEnded or input.notGrabbedFor >= END_GRACE
end

-- Whether an outcome means the swimmer fought (or was let) free.
function StruggleController.isFreed(outcome: string): boolean
	return FREED[outcome] == true
end

-- How dark the screen is (0..0.9) with `oxygenFraction` of the air left, pulsing with the heart at `heart` (0..1).
function StruggleController.darkness(oxygenFraction: number, heart: number): number
	local starving = 1 - MathUtil.smoothstep(0.08, 0.6, oxygenFraction)
	return math.clamp(0.82 * starving + 0.08 * starving * MathUtil.clamp01(heart), 0, 0.9)
end

-- How hard the view is dragged toward the Creature `t` seconds into the grab (the drag lasts `drag` seconds), with a
-- yank `tug` (0..1) under way.
function StruggleController.pullWeight(t: number, drag: number, tug: number): number
	local dragging = if drag > 0 and t < drag then 1 - t / drag else 0
	return MathUtil.clamp01(PULL_BASE + (PULL_DRAG - PULL_BASE) * dragging + PULL_TUG * MathUtil.clamp01(tug))
end

-- A yank's envelope `t` seconds after it began (0 outside TugSeconds): a sharp rise, a slower release.
function StruggleController.tugEnvelope(t: number): number
	if t < 0 or t >= TUG_SECONDS then
		return 0
	end
	local attack = MathUtil.smoothstep(0, 0.05, t)
	local release = 1 - MathUtil.smoothstep(0.05, TUG_SECONDS, t)
	return attack * release
end

-- When the next yank comes after one at `at` (`roll` 0..1).
function StruggleController.nextTug(at: number, roll: number): number
	return at + TUG_MIN + (TUG_MAX - TUG_MIN) * MathUtil.clamp01(roll)
end

-- The thrash's shake (pitch, yaw, roll radians) at time `t` for a seed, scaled by `amount`.
function StruggleController.shakeAngles(t: number, seed: number, amount: number): (number, number, number)
	local a = math.rad(SHAKE_DEGREES) * math.max(0, amount)
	return a * math.noise(t * 9.1, seed, 0.31),
		a * 0.8 * math.noise(t * 7.3, seed + 17.4, 0.77),
		a * 0.6 * math.noise(t * 11.7, seed + 41.9, 0.13)
end

-- The predicted progress after a server Progress cue reporting `server` presses: kept within ReconcileGap of it.
function StruggleController.reconcile(predicted: number, server: number): number
	if math.abs(predicted - server) > RECONCILE_GAP then
		return server
	end
	return predicted
end

--------------------------------------------------------------------------------
-- View
--------------------------------------------------------------------------------

local function build(parent: Instance): View
	local gui = UIKit.screenGui("Struggle", SCREEN_ORDER, Enum.ScreenInsets.CoreUISafeInsets)
	gui.Enabled = false
	local fullscreen = UIKit.screenGui("StruggleDark", SCREEN_ORDER - 1, Enum.ScreenInsets.None)
	fullscreen.IgnoreGuiInset = true
	local dark = UIKit.fill(fullscreen, "Dark", Palette.Ink, 1)
	local vignette = UIKit.vignette(fullscreen, "Vignette", Color3.fromRGB(4, 10, 10), 0.42, 0.05)
	vignette:SetAlpha(0)
	fullscreen.Parent = parent

	local layer = UIKit.frame(gui, "Layer")
	local scale = Instance.new("UIScale")
	scale.Parent = layer

	local panel = Instance.new("CanvasGroup")
	panel.Name = "Panel"
	panel.BackgroundTransparency = 1
	panel.BorderSizePixel = 0
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -PANEL_BOTTOM)
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.GroupTransparency = 0
	panel.Parent = layer
	local pulse = Instance.new("UIScale")
	pulse.Parent = panel

	local card = UIKit.panel(panel, "Card", 0.2, 7741)
	card.Size = UDim2.fromScale(1, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.padding(card, 18, 12)
	UIKit.list(card, Enum.FillDirection.Vertical, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)

	local title = UIKit.label(card, "Title", UIKit.Fonts.Title, UIKit.TextSize.Hint, Palette.Bone)
	title.LayoutOrder = 1
	title.Size = UDim2.fromScale(1, 0)
	title.AutomaticSize = Enum.AutomaticSize.Y
	title.Text = Strings.get("Hud.Struggle")
	UIKit.textStroke(title, 0.35)

	local row = UIKit.frame(card, "Row")
	row.LayoutOrder = 2
	row.Size = UDim2.new(1, 0, 0, GLYPH_SIZE)
	UIKit.list(row, Enum.FillDirection.Horizontal, 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local glyph = UIKit.keyCap(row, "Key", GLYPH_SIZE)
	glyph.root.LayoutOrder = 1
	local mash = UIKit.label(row, "Mash", UIKit.Fonts.Heavy, UIKit.TextSize.Title, Palette.Ember)
	mash.LayoutOrder = 2
	mash.Size = UDim2.fromOffset(110, GLYPH_SIZE)
	mash.TextXAlignment = Enum.TextXAlignment.Left
	mash.Text = Strings.get("Hud.StruggleMash")
	UIKit.textStroke(mash, 0.3)

	local bar = UIKit.meterBar(card, "Escape", Palette.Bone, BAR_HEIGHT)
	bar.root.LayoutOrder = 3
	bar:SetFraction(0)

	gui.Parent = parent
	return {
		gui = gui,
		scale = scale,
		panel = panel,
		pulse = pulse,
		title = title,
		mash = mash,
		glyph = glyph,
		bar = bar,
		dark = dark,
		vignette = vignette,
	}
end

local function setGlyph(current: View)
	local device = InputController.GetDevice()
	if device == "Gamepad" then
		current.glyph:SetGlyph("Gamepad", Enum.KeyCode.ButtonA)
	elseif device == "Touch" then
		current.glyph:SetGlyph("Touch", nil)
	else
		current.glyph:SetGlyph("Keyboard", Enum.KeyCode.Space)
	end
end

--------------------------------------------------------------------------------
-- Session
--------------------------------------------------------------------------------

local function oxygenFraction(player: Player): number
	local max = Attributes.getNumber(player, P.OxygenMax, GameConfig.OxygenMax)
	local value = Attributes.readMeter(player, P.Oxygen, P.OxygenRate, P.OxygenAt, max, Workspace:GetServerTimeNow())
	return if max > 0 then MathUtil.clamp01(value / max) else 1
end

local function creatureFace(fallback: Vector3?): Vector3?
	local creature = Instances.creature()
	if creature then
		local head = creature:FindFirstChild("Head", true)
		if head and head:IsA("BasePart") then
			return head.Position
		end
		local root = Instances.creatureRoot()
		if root then
			return root.Position
		end
	end
	return fallback
end

local function overrideView(): CFrame
	-- The player's own eye this frame (FirstPersonController evaluates its overrides after computing it).
	local eye = FirstPersonController.GetEyeCFrame()
	local current = session
	if not current then
		return eye
	end
	local now = os.clock()
	local t = now - current.startedAt
	local tug = StruggleController.tugEnvelope(now - current.tugAt)
	local jerk = 1 - MathUtil.smoothstep(0, JERK_SECONDS, now - current.jerkAt)
	local face = creatureFace(current.creature)
	if face then
		eye = Scenes.Pulled(eye, face, StruggleController.pullWeight(t, current.drag, tug) * motionScale + 0.25)
	end
	local pitch, yaw, roll = StruggleController.shakeAngles(now, current.seed, (1 + 1.5 * tug) * motionScale)
	local dip = -TUG_DIP * tug * motionScale
	local yank = (-TUG_PITCH * tug + JERK_PITCH * jerk) * motionScale
	return eye * CFrame.new(0, dip, 0) * CFrame.Angles(pitch + yank, yaw, roll)
end

local function begin(cue: Types.PrivateCuePayload?)
	local player = localPlayer
	if not player or session then
		return
	end
	local now = os.clock()
	local args: { [string]: Types.OneShotArg } = if cue then cue.args else {}
	local needed = args.needed
	local drag = args.drag
	local creature = args.creature
	local current: Session = {
		trove = Trove.new(),
		startedAt = now,
		needed = if type(needed) == "number" then needed else WaterRules.PressesToEscape,
		drag = if type(drag) == "number" then drag else 1.2,
		creature = if typeof(creature) == "Vector3" then creature :: Vector3 else nil,
		struggle = WaterRules.newStruggle(now),
		sequence = 0,
		nextTugAt = StruggleController.nextTug(now, math.random()),
		tugAt = -math.huge,
		jerkAt = -math.huge,
		nextBubblesAt = now,
		seed = math.random() * 100,
		notGrabbedSince = nil,
		ended = false,
	}
	session = current
	motionScale = MathUtil.clamp01(SettingsController.GetNumber("MotionScale"))
	InputController.PushContext(CONTEXT, TOKEN)
	FirstPersonController.PushOverride(OVERRIDE, {
		cframe = overrideView,
		fov = SettingsController.GetNumber("BaseFov") - FOV_SQUEEZE,
		blendIn = 0.15,
		blendOut = 0.4,
	})
	FirstPersonController.SetPanicFloor(TOKEN, 1)
	FirstPersonController.SuppressBreathing(TOKEN, true)
	HUD.SetPromptsSuppressed(TOKEN, true)
	FirstPersonController.Shake(CameraConfig.Shake.ImpactAmplitude * 1.6 * motionScale, 0.5)
	SwimController.EmitBubbles(10, nil)
	HUD.ClearHint(nil)
	local currentView = view
	if currentView then
		setGlyph(currentView)
		currentView.bar:SetFraction(0)
		currentView.gui.Enabled = true
	end
	log.debug("struggle started")
end

local function finish(outcome: string?)
	local current = session
	if not current then
		return
	end
	session = nil
	current.ended = true
	current.trove:Destroy()
	InputController.PopContext(TOKEN)
	FirstPersonController.PopOverride(OVERRIDE)
	FirstPersonController.SetPanicFloor(TOKEN, nil)
	FirstPersonController.SuppressBreathing(TOKEN, false)
	HUD.SetPromptsSuppressed(TOKEN, false)
	local currentView = view
	if currentView then
		currentView.gui.Enabled = false
		currentView.dark.BackgroundTransparency = 1
		currentView.vignette:SetAlpha(0)
	end
	if outcome and StruggleController.isFreed(outcome) then
		SwimController.Kick(FREE_KICK_SPEED, FREE_KICK_SECONDS)
		SwimController.EmitBubbles(14, nil)
		FirstPersonController.Shake(CameraConfig.Shake.ImpactAmplitude * motionScale, 0.35)
		HUD.ShowHint("Hud.StruggleFree", FREE_HINT_SECONDS)
	end
	log.debug("struggle ended: %s", tostring(outcome))
end

local function press()
	local current = session
	if not current then
		return
	end
	local now = os.clock()
	local sequence = current.sequence + 1
	if WaterRules.wouldCount(current.struggle, sequence, now) ~= "Counted" then
		return
	end
	current.sequence = sequence
	WaterRules.press(current.struggle, sequence, now)
	current.jerkAt = now
	local payload: Types.StrugglePressPayload = { sequence = sequence }
	xpcall(Net.Client.fire, function(err: any)
		log.warnThrottled("press", 10, "StrugglePress failed: %s", tostring(err))
	end, "StrugglePress", payload)
	SwimController.EmitBubbles(math.random(2, 4), nil)
	local currentView = view
	if currentView then
		currentView.pulse.Scale = 1.08
	end
end

local function onCue(payload: any)
	if type(payload) ~= "table" or payload.kind ~= CUE_KIND then
		return
	end
	local cue = payload :: Types.PrivateCuePayload
	local args: { [string]: Types.OneShotArg } = cue.args or {}
	local phase = args.phase
	if phase == "Start" then
		if session then
			finish(nil)
		end
		begin(cue)
	elseif phase == "Progress" then
		local current = session
		local progress = args.progress
		if current and type(progress) == "number" then
			local now = os.clock()
			local predicted = WaterRules.progressAt(current.struggle, now)
			current.struggle.progress = StruggleController.reconcile(predicted, progress)
			current.struggle.at = now
		end
	elseif phase == "End" then
		local outcome = args.outcome
		finish(if type(outcome) == "string" then outcome else nil)
	end
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function step(dt: number)
	local player = localPlayer
	if not player then
		return
	end
	local now = os.clock()
	local moveState = Attributes.getString(player, P.MoveState, "Standing")
	local lock = Attributes.getString(player, P.ControlLock, "None")
	if moveState == GRABBED and lock == DRAG_LOCK then
		grabbedSince = grabbedSince or now
	else
		grabbedSince = nil
	end
	local current = session
	if not current then
		if
			grabbedSince ~= nil
			and now - (grabbedSince :: number) >= CUE_LATE_START
			and StruggleController.shouldStart({
				engaged = false,
				cueStarted = false,
				moveState = moveState,
				controlLock = lock,
			})
		then
			begin(nil)
		end
		return
	end
	if moveState == GRABBED then
		current.notGrabbedSince = nil
	else
		current.notGrabbedSince = current.notGrabbedSince or now
	end
	local notGrabbedFor = if current.notGrabbedSince then now - (current.notGrabbedSince :: number) else 0
	if
		StruggleController.shouldEnd({
			engaged = true,
			cueEnded = false,
			grabbedFor = now - current.startedAt,
			notGrabbedFor = notGrabbedFor,
		})
	then
		finish(nil)
		return
	end
	if now >= current.nextTugAt then
		current.tugAt = now
		current.nextTugAt = StruggleController.nextTug(now, math.random())
		FirstPersonController.Shake(CameraConfig.Shake.ImpactAmplitude * 0.8 * motionScale, 0.25)
	end
	if now >= current.nextBubblesAt then
		current.nextBubblesAt = now + BUBBLE_INTERVAL * (0.7 + 0.6 * math.random())
		SwimController.EmitBubbles(math.random(1, 3), nil)
	end
	local currentView = view
	if currentView then
		local camera = Workspace.CurrentCamera
		if camera then
			local nextScale = UIKit.scaleFor(camera.ViewportSize)
			if math.abs(currentView.scale.Scale - nextScale) > 1e-3 then
				currentView.scale.Scale = nextScale
			end
		end
		setGlyph(currentView)
		currentView.bar:SetFraction(WaterRules.progressAt(current.struggle, now) / math.max(1, current.needed))
		currentView.pulse.Scale = MathUtil.dampNumber(currentView.pulse.Scale, 1, 14, dt)
		local air = oxygenFraction(player)
		local heart = HUD.heartbeat(now, 90 + 80 * (1 - air))
		local darkness = StruggleController.darkness(air, heart)
		currentView.dark.BackgroundTransparency = 1 - darkness
		currentView.vignette:SetAlpha(MathUtil.clamp01(0.45 + darkness))
		local flash = 0.5 + 0.5 * math.sin(now * 10)
		currentView.mash.TextTransparency = 0.15 * flash
	end
end

local function onPreRender(dt: number)
	xpcall(step, function(err: any)
		log.warnThrottled("step", 5, "struggle frame failed: %s\n%s", tostring(err), debug.traceback())
	end, math.clamp(dt, 0, 0.1))
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function StruggleController.Init()
	serviceTrove:Add(InputController.Action("Struggle"):Connect(function(phase: InputController.Phase)
		if phase == "Begin" then
			press()
		end
	end))
	serviceTrove:Add(SettingsController.Changed:Connect(function(key: string, _value: number | boolean)
		if key == "MotionScale" then
			motionScale = MathUtil.clamp01(SettingsController.GetNumber("MotionScale"))
		end
	end))
	serviceTrove:Add(function()
		finish(nil)
	end)
end

function StruggleController.Start()
	local player = localPlayer
	if not player then
		log.warn("no local player; the struggle is not presented")
		return
	end
	local gui = player:WaitForChild("PlayerGui")
	xpcall(function()
		view = build(gui)
	end, function(err: any)
		log.error("struggle UI failed to build: %s\n%s", tostring(err), debug.traceback())
	end)
	local connection = Net.Client.on("PrivateCue", onCue)
	if connection then
		serviceTrove:Add(connection)
	end
	serviceTrove:Connect(player.CharacterRemoving, function(_model: Model)
		finish(nil)
	end)
	serviceTrove:Connect(RunService.PreRender, onPreRender)
end

function StruggleController.OnRunEnded()
	finish(nil)
	grabbedSince = nil
end

--------------------------------------------------------------------------------
-- Beyond the contract
--------------------------------------------------------------------------------

-- True while the local player is fighting the Creature's grip.
function StruggleController.IsStruggling(): boolean
	return session ~= nil
end

-- The predicted escape progress (0..1), 0 outside a struggle.
function StruggleController.GetProgress(): number
	local current = session
	if not current then
		return 0
	end
	return MathUtil.clamp01(WaterRules.progressAt(current.struggle, os.clock()) / math.max(1, current.needed))
end

return table.freeze(StruggleController)
