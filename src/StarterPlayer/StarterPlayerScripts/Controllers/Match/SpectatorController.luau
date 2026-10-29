--!strict
-- SpectatorController: watching the run through a teammate's eyes (spec §6, first-person spectator camera).
-- SpectatorService (server) decides who spectates and whom (SpectateReason / SpectateTargetUserId); this client only
-- renders it.
--
-- When. While my SpectateReason is not "None". A death holds on the body first: for DEATH_HOLD seconds after my
-- LifeState turned Dead the camera stays on my own corpse (and whatever caught me) before cutting away.
--
-- The view. A "Spectating" FirstPersonController override (above the base view, under jumpscares and cutscenes)
-- sits at the target's eyes: their Head's position plus an eye offset in head space, spring-smoothed against
-- replication jitter (snapping on a switch or a teleport), looking along their LookBroadcast yaw / pitch (eased toward
-- each 10 Hz sample the short way round; before their first sample, their root's facing). A sphere cast from their
-- root to the eye keeps the camera on this side of a wall their head is pressed against. FirstPersonController's body
-- subject becomes their character, so their head is hidden and their arms and legs show as they would to them. Their
-- torch is drawn from inside (RemoteFlashlightRenderer.SetFocus: their whole dual cone, from this camera). The
-- override's FOV is my BaseFov setting. Every listener in the game follows the camera (SoundService's Camera listener,
-- AudioController's rooms, beds and emitters), so I hear what they hear, in their room's acoustics.
--
-- Switching. A new target cuts through black: the screen fades out (CUT_IN), the view jumps, and fades back
-- (CUT_OUT). SpectatePrev / SpectateNext (Q / E, L1 / R1, the touch arrows MobileControls draws in the "Spectator"
-- input context, which is pushed while watching) send SpectateCycle { direction = ∓1 } and start the fade at once;
-- if the server does not answer within PRESS_TIMEOUT the screen fades back in on the same view.
--
-- The HUD. Bottom centre, in the HUD's look: "Spectating <name>" between the cycle glyphs (hidden on touch, where
-- the arrows are, and while there is nobody else to switch to), a red "DOWN" tag while they are downed, why I am
-- watching (dead / left behind / joined late / squad full) and, for an eliminated participant on a floor with a
-- stairwell ahead, that the next checkpoint brings me back. Nobody left: "No survivors to watch." over the last view.
-- Every prompt on this client is suppressed while watching (spectators can use none). The panel hides with the HUD
-- and once the run has ended (RunEnded / Results: the summary owns the screen; the view stays until EndRun).
--
-- Pure (tests/Specs/Spectator.spec.luau): isWatching, reasonKey, showRespawn, eyePosition, approachLook, cutStep.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Spring = require(ReplicatedStorage.Shared.Util.Spring)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Controllers = script.Parent.Parent
local InputController = require(Controllers.Core.InputController)
local SettingsController = require(Controllers.Core.SettingsController)
local CharacterAnimationController = require(Controllers.Characters.CharacterAnimationController)
local RemoteFlashlightRenderer = require(Controllers.Characters.RemoteFlashlightRenderer)
local FirstPersonController = require(Controllers.FirstPerson.FirstPersonController)
local HUD = require(Controllers.HUD)
local UIKit = require(Controllers.HUD.UIKit)

local log = Log.new("Spectator")

local P = Attributes.Player
local M = Attributes.Match
local Palette = UIKit.Palette

type Look = { yaw: number, pitch: number }

type View = {
	gui: ScreenGui,
	cut: ScreenGui,
	scale: UIScale,
	panel: CanvasGroup,
	prev: UIKit.KeyCap,
	next: UIKit.KeyCap,
	name: TextLabel,
	downTag: TextLabel,
	reason: TextLabel,
	respawn: TextLabel,
	black: Frame,
}

local NAME = "SpectatorController"
local CONTEXT: Enums.InputContext = "Spectator"
local OVERRIDE: Enums.CameraOverride = "Spectating"
local SCREEN_ORDER = 21
local CUT_ORDER = 24
local DEATH_HOLD = 2.5
local CUT_IN = 0.14 -- seconds to black
local CUT_OUT = 0.32 -- seconds back from black
local PRESS_TIMEOUT = 0.7
local CYCLE_COOLDOWN = 0.25
local LOOK_SPEED = 12 -- 1/s easing toward the target's latest look sample
local EYE_SPEED = 38 -- rad/s, eye position spring (critically damped)
local SNAP_DISTANCE = 6
local EYE_OFFSET = Vector3.new(0, 0.12, -0.3) -- head space: the eyes, just inside the face
local CAMERA_RADIUS = 0.2
local CAMERA_SKIN = 0.05
local EXCLUDE_REFRESH = 0.5
local PANEL_WIDTH = 460
local PANEL_BOTTOM = 26
local FADE_SPEED = 4
local CAP_SIZE = 30

local SpectatorController = {}

SpectatorController.Name = NAME
SpectatorController.DeathHold = DEATH_HOLD

local serviceTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local view: View? = nil
local clock = 0
local panelAlpha = 0

local watching = false
local deathAt: number? = nil -- os.clock() my LifeState turned Dead
local lastLifeState = "Lobby"
local shown: Player? = nil -- whose eyes the camera is in
local subject: Model? = nil -- the body subject handed to FirstPersonController
local cutAlpha = 0
local pressedAt: number? = nil
local lastCycleAt = -math.huge
local looks: { [number]: Look } = {} -- latest LookBroadcast sample per UserId
local eased: Look? = nil
local eyeSpring = Spring.vector(Vector3.zero, EYE_SPEED, 1)
local eyeReady = false
local lastView = CFrame.identity
local lastViewAt = os.clock()
local excludeParams: RaycastParams? = nil
local excludeAt = -math.huge
local overrideSource: FirstPersonController.OverrideSource? = nil

--------------------------------------------------------------------------------
-- Pure (specs: tests/Specs/Spectator.spec.luau)
--------------------------------------------------------------------------------

-- Whether the spectator view is up: spectating, and past the death hold (`deathAt` is the os.clock() of my death).
function SpectatorController.isWatching(reason: string, diedAt: number?, now: number): boolean
	if reason == "None" or reason == "" then
		return false
	end
	return diedAt == nil or now - diedAt >= DEATH_HOLD
end

-- The Strings key for why I am watching.
function SpectatorController.reasonKey(reason: string, lifeState: string): string?
	if reason == "Eliminated" then
		return if lifeState == "Spectating" then "Spectate.LeftBehind" else "Spectate.Eliminated"
	elseif reason == "LateJoin" then
		return "Spectate.LateJoin"
	elseif reason == "OverCapacity" then
		return "Lobby.ServerFull"
	end
	return nil
end

-- Whether to promise a comeback: an eliminated participant on a level with a stairwell airlock ahead.
function SpectatorController.showRespawn(reason: string, level: string?): boolean
	if reason ~= "Eliminated" or level == nil then
		return false
	end
	for _, stairwell in WorldConfig.Stairwells do
		if stairwell.from == level then
			return true
		end
	end
	return false
end

-- Where the eyes are for a head at `head`.
function SpectatorController.eyePosition(head: CFrame): Vector3
	return (head * CFrame.new(EYE_OFFSET)).Position
end

-- The eased look after `dt` toward a target look (the short way round in yaw; pitch clamped to ±89°).
function SpectatorController.approachLook(current: Look, target: Look, dt: number): Look
	local blend = MathUtil.damp(LOOK_SPEED, dt)
	local limit = math.rad(89)
	return {
		yaw = MathUtil.wrapAngle(current.yaw + MathUtil.angleDelta(current.yaw, target.yaw) * blend),
		pitch = math.clamp(current.pitch + (target.pitch - current.pitch) * blend, -limit, limit),
	}
end

-- The black cut's opacity after `dt`: toward 1 while a switch is pending, back to 0 otherwise.
function SpectatorController.cutStep(current: number, pending: boolean, dt: number): number
	if pending then
		return math.min(1, current + dt / CUT_IN)
	end
	return math.max(0, current - dt / CUT_OUT)
end

--------------------------------------------------------------------------------
-- Reads
--------------------------------------------------------------------------------

local function wantedTarget(player: Player): Player?
	local userId = player:GetAttribute(P.SpectateTargetUserId)
	if type(userId) ~= "number" then
		return nil
	end
	local target = Players:GetPlayerByUserId(userId)
	return if target and target ~= player then target else nil
end

local function headOf(player: Player): BasePart?
	local character = player.Character
	if not character or not character:IsDescendantOf(Workspace) then
		return nil
	end
	local head = character:FindFirstChild("Head")
	return if head and head:IsA("BasePart") then head else nil
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	return if root and root:IsA("BasePart") then root else nil
end

local function candidateCount(player: Player): number
	local count = 0
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local state = Attributes.getString(other, P.LifeState, "Lobby")
			if state == "Alive" or state == "Downed" then
				count += 1
			end
		end
	end
	return count
end

local function collisionParams(now: number): RaycastParams
	local params = excludeParams
	if params and now < excludeAt then
		return params
	end
	excludeAt = now + EXCLUDE_REFRESH
	local exclude: { Instance } = {}
	for _, other in Players:GetPlayers() do
		local model = other.Character
		if model then
			table.insert(exclude, model)
		end
	end
	local creature = Instances.creature()
	if creature then
		table.insert(exclude, creature)
	end
	local camera = Workspace.CurrentCamera
	if camera then
		table.insert(exclude, camera)
	end
	local fresh = RaycastParams.new()
	fresh.FilterType = Enum.RaycastFilterType.Exclude
	fresh.FilterDescendantsInstances = exclude
	fresh.CollisionGroup = "Default"
	fresh.RespectCanCollide = true
	fresh.IgnoreWater = true
	excludeParams = fresh
	return fresh
end

--------------------------------------------------------------------------------
-- The view
--------------------------------------------------------------------------------

-- The target's look sample, or their root's facing at level pitch before their first one.
local function targetLook(target: Player): Look
	local sample = looks[target.UserId]
	if sample then
		return sample
	end
	local root = rootOf(target)
	local yaw = if root then MathUtil.yawPitchFromVector(root.CFrame.LookVector) else 0
	return { yaw = yaw, pitch = 0 }
end

-- This frame's camera at the shown target's eyes (called by the camera stack once per frame).
local function computeView(): CFrame
	local now = os.clock()
	local dt = math.clamp(now - lastViewAt, 0, 0.1)
	lastViewAt = now
	local target = shown
	if not target then
		return lastView
	end
	local head = headOf(target)
	if not head then
		return lastView -- respawning or gone: hold the last frame
	end
	local desired = SpectatorController.eyePosition(head.CFrame)
	if not eyeReady or (eyeSpring.position - desired).Magnitude > SNAP_DISTANCE then
		eyeSpring:reset(desired)
		eyeReady = true
	end
	eyeSpring.target = desired
	local eye = eyeSpring:step(dt)
	local root = rootOf(target)
	if root then
		local origin = root.Position
		local offset = eye - origin
		local length = offset.Magnitude
		if length > 1e-3 then
			local hit = Workspace:Spherecast(origin, CAMERA_RADIUS, offset, collisionParams(now))
			if hit then
				eye = origin + offset.Unit * math.max(0, hit.Distance - CAMERA_SKIN)
			end
		end
	end
	local goal = targetLook(target)
	local current = eased or goal
	local look = SpectatorController.approachLook(current, goal, dt)
	eased = look
	lastView = CFrame.new(eye) * CFrame.fromOrientation(look.pitch, look.yaw, 0)
	return lastView
end

local function currentView(): CFrame
	return lastView
end

local function setSubject(model: Model?)
	if model ~= subject then
		subject = model
		FirstPersonController.SetBodySubject(model)
	end
end

-- Puts the camera in `target`'s eyes (nil: hold the last view).
local function show(target: Player?)
	shown = target
	eyeReady = false
	eased = nil
	RemoteFlashlightRenderer.SetFocus(target, if target then currentView else nil)
	setSubject(if target then target.Character else nil)
end

local function startWatching()
	if watching then
		return
	end
	watching = true
	local camera = Workspace.CurrentCamera
	if camera then
		lastView = camera.CFrame
	end
	lastViewAt = os.clock()
	local source: FirstPersonController.OverrideSource = {
		cframe = computeView,
		fov = SettingsController.GetNumber("BaseFov"),
		blendIn = 0,
		blendOut = 0.45,
	}
	overrideSource = source
	FirstPersonController.PushOverride(OVERRIDE, source)
	InputController.PushContext(CONTEXT, NAME)
	HUD.SetPromptsSuppressed(NAME, true)
	SoundService:SetListener(Enum.ListenerType.Camera)
	cutAlpha = 1 -- arrive from black
	pressedAt = nil
end

local function stopWatching()
	if not watching then
		return
	end
	watching = false
	overrideSource = nil
	FirstPersonController.PopOverride(OVERRIDE)
	InputController.PopContext(NAME)
	HUD.SetPromptsSuppressed(NAME, false)
	show(nil)
	pressedAt = nil
end

local function requestCycle(direction: number)
	local player = localPlayer
	if not watching or not player or candidateCount(player) < 2 then
		return -- nobody else to switch to
	end
	local now = os.clock()
	if now - lastCycleAt < CYCLE_COOLDOWN then
		return
	end
	lastCycleAt = now
	local payload: Types.SpectateCyclePayload = { direction = direction }
	xpcall(Net.Client.fire, function(err: any)
		log.warnThrottled("cycle", 10, "SpectateCycle failed: %s", tostring(err))
	end, "SpectateCycle", payload)
	pressedAt = now
end

--------------------------------------------------------------------------------
-- HUD
--------------------------------------------------------------------------------

local function glyphFor(action: string): (UIKit.GlyphKind, Enum.KeyCode?)
	local device = InputController.GetDevice()
	local binding = InputConfig.Bindings[action]
	if device == "Touch" or not binding then
		return "Touch", nil
	elseif device == "Gamepad" then
		return "Gamepad", binding.gamepad[1]
	end
	local first = binding.keyboard[1]
	if typeof(first) == "EnumItem" and first.EnumType == Enum.KeyCode then
		return "Keyboard", first :: Enum.KeyCode
	end
	return "Keyboard", nil
end

local function refreshGlyphs()
	local current = view
	if not current then
		return
	end
	local prevKind: UIKit.GlyphKind, prevKey: Enum.KeyCode? = glyphFor("SpectatePrev")
	local nextKind: UIKit.GlyphKind, nextKey: Enum.KeyCode? = glyphFor("SpectateNext")
	current.prev:SetGlyph(prevKind, prevKey)
	current.next:SetGlyph(nextKind, nextKey)
end

local function build(parent: Instance): View
	local gui = UIKit.screenGui("Spectator", SCREEN_ORDER, Enum.ScreenInsets.CoreUISafeInsets)
	local cut = UIKit.screenGui("SpectatorCut", CUT_ORDER, Enum.ScreenInsets.None)
	local black = UIKit.fill(cut, "Black", Palette.Ink, 1)
	black.Active = false
	cut.Enabled = false

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
	panel.GroupTransparency = 1
	panel.Visible = false
	panel.Parent = layer

	local backing = UIKit.panel(panel, "Backing", 0.22, 4411)
	backing.Size = UDim2.fromScale(1, 0)
	backing.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.padding(backing, 18, 10)
	UIKit.list(backing, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)

	local row = UIKit.frame(backing, "Target")
	row.LayoutOrder = 1
	row.Size = UDim2.new(1, 0, 0, CAP_SIZE + 4)
	UIKit.list(row, Enum.FillDirection.Horizontal, 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)

	local prev = UIKit.keyCap(row, "Prev", CAP_SIZE)
	prev.root.LayoutOrder = 1
	local name = UIKit.label(row, "Name", UIKit.Fonts.Title, 22, Palette.Bone)
	name.LayoutOrder = 2
	name.AutomaticSize = Enum.AutomaticSize.X
	name.Size = UDim2.fromScale(0, 1)
	name.TextWrapped = false
	UIKit.textStroke(name, 0.3)
	local downTag = UIKit.label(row, "Down", UIKit.Fonts.Strong, UIKit.TextSize.Caps, Palette.Ember)
	downTag.LayoutOrder = 3
	downTag.AutomaticSize = Enum.AutomaticSize.X
	downTag.Size = UDim2.fromScale(0, 1)
	downTag.TextWrapped = false
	downTag.Text = Strings.get("Spectate.TargetDowned")
	UIKit.textStroke(downTag, 0.4)
	local nextCap = UIKit.keyCap(row, "Next", CAP_SIZE)
	nextCap.root.LayoutOrder = 4

	local reason = UIKit.label(backing, "Reason", UIKit.Fonts.Body, UIKit.TextSize.Body, Palette.Ash)
	reason.LayoutOrder = 2
	reason.Size = UDim2.new(1, 0, 0, 0)
	reason.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.textStroke(reason, 0.45)

	local respawn = UIKit.label(backing, "Respawn", UIKit.Fonts.Body, UIKit.TextSize.Small, Palette.Amber)
	respawn.LayoutOrder = 3
	respawn.Size = UDim2.new(1, 0, 0, 0)
	respawn.AutomaticSize = Enum.AutomaticSize.Y
	respawn.Text = Strings.get("Spectate.Respawn")
	UIKit.textStroke(respawn, 0.45)

	cut.Parent = parent
	gui.Parent = parent
	return {
		gui = gui,
		cut = cut,
		scale = scale,
		panel = panel,
		prev = prev,
		next = nextCap,
		name = name,
		downTag = downTag,
		reason = reason,
		respawn = respawn,
		black = black,
	}
end

local function setText(label: TextLabel, text: string)
	if label.Text ~= text then
		label.Text = text
	end
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function step(dt: number)
	clock += dt
	local player = localPlayer
	local current = view
	if not player or not current then
		return
	end
	local camera = Workspace.CurrentCamera
	if camera then
		local nextScale = UIKit.scaleFor(camera.ViewportSize)
		if math.abs(current.scale.Scale - nextScale) > 1e-3 then
			current.scale.Scale = nextScale
			-- The UIScale grows the layer from its top-left corner: size it so the scaled layer still fills the screen
			-- (as the HUD's layer does), or the panel drifts off centre on screens that aren't about 720 px tall.
			local layer = current.scale.Parent
			if layer and layer:IsA("GuiObject") then
				layer.Size = UDim2.fromScale(1 / nextScale, 1 / nextScale)
			end
		end
	end

	local now = os.clock()
	local lifeState = Attributes.getString(player, P.LifeState, "Lobby")
	if lifeState ~= lastLifeState then
		deathAt = if lifeState == "Dead" then now else nil
		lastLifeState = lifeState
	end
	local reason = Attributes.getString(player, P.SpectateReason, "None")
	if SpectatorController.isWatching(reason, deathAt, now) then
		startWatching()
	else
		stopWatching()
	end

	-- Cuts: a pending switch (the server's new target, or a press waiting for its answer) fades to black first.
	local wanted = if watching then wantedTarget(player) else nil
	if pressedAt ~= nil and now - pressedAt > PRESS_TIMEOUT then
		pressedAt = nil
	end
	local switching = watching and (wanted ~= shown or pressedAt ~= nil)
	cutAlpha = SpectatorController.cutStep(cutAlpha, switching, dt)
	if watching and wanted ~= shown and (cutAlpha >= 1 or shown == nil) then
		show(wanted)
		pressedAt = nil
	end
	if shown then
		setSubject(shown.Character)
	end
	local source = overrideSource
	if source then
		source.fov = SettingsController.GetNumber("BaseFov")
	end
	current.cut.Enabled = cutAlpha > 0.001
	UIKit.setTransparency(current.black, 1 - MathUtil.smoothstep(0, 1, cutAlpha))

	-- Panel
	local target = shown
	-- The panel stays on while the run is live; from RunEnded on the summary owns the screen (the view stays).
	local phase = ReplicatedStorage:GetAttribute(M.MatchPhase)
	local live = phase == "InRun" or phase == "Deploying"
	local showPanel = watching and live and HUD.IsVisible()
	panelAlpha = MathUtil.approach(panelAlpha, if showPanel then 1 else 0, dt * FADE_SPEED)
	current.panel.Visible = panelAlpha > 0.003
	current.panel.GroupTransparency = 1 - panelAlpha
	if not current.panel.Visible then
		return
	end
	local others = candidateCount(player)
	local touch = InputController.GetDevice() == "Touch"
	local canCycle = others > 1 and not touch
	current.prev.root.Visible = canCycle
	current.next.root.Visible = canCycle
	if target then
		setText(current.name, Strings.get("Hud.Spectating", target.DisplayName))
		current.downTag.Visible = Attributes.getString(target, P.LifeState, "Lobby") == "Downed"
	else
		setText(current.name, Strings.get("Hud.NoOneToSpectate"))
		current.downTag.Visible = false
	end
	local key = SpectatorController.reasonKey(reason, lifeState)
	current.reason.Visible = key ~= nil
	if key then
		setText(current.reason, Strings.get(key))
	end
	local level = ReplicatedStorage:GetAttribute(M.CurrentLevel)
	current.respawn.Visible = SpectatorController.showRespawn(reason, if type(level) == "string" then level else nil)
end

local function onLookBroadcast(payload: any)
	for userId, sample in CharacterAnimationController.parseLookBroadcast(payload) do
		looks[userId] = { yaw = sample.yaw, pitch = sample.pitch }
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function SpectatorController.Init()
	serviceTrove:Add(function()
		stopWatching()
		local current = view
		view = nil
		if current then
			current.gui:Destroy()
			current.cut:Destroy()
		end
	end)
end

function SpectatorController.Start()
	local player = localPlayer
	if not player then
		log.warn("no local player; spectating is not available")
		return
	end
	local gui = player:WaitForChild("PlayerGui")
	xpcall(function()
		view = build(gui)
	end, function(err: any)
		log.error("spectator HUD failed to build: %s\n%s", tostring(err), debug.traceback())
	end)
	refreshGlyphs()
	serviceTrove:Add(InputController.DeviceChanged:Connect(refreshGlyphs))
	serviceTrove:Add(InputController.Action("SpectatePrev"):Connect(function(phase: InputController.Phase)
		if phase == "Begin" then
			requestCycle(-1)
		end
	end))
	serviceTrove:Add(InputController.Action("SpectateNext"):Connect(function(phase: InputController.Phase)
		if phase == "Begin" then
			requestCycle(1)
		end
	end))
	local connection = Net.Client.on("LookBroadcast", onLookBroadcast)
	if connection then
		serviceTrove:Add(connection)
	end
	serviceTrove:Connect(Players.PlayerRemoving, function(leaving: Player)
		looks[leaving.UserId] = nil
	end)
	serviceTrove:Connect(RunService.PreRender, step)
end

function SpectatorController.OnRunStarted(_info: Types.RunInfo)
	deathAt = nil
	cutAlpha = 0
end

function SpectatorController.OnRunEnded()
	stopWatching()
	deathAt = nil
	table.clear(looks)
end

return table.freeze(SpectatorController)
