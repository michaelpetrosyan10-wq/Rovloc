--!strict
-- DownedController: being down, on this client (spec §6, Downed, crawl and revive).
--
-- The victim (LifeState Downed while the run is live: Deploying / InRun; from RunEnded on the summary owns the screen
-- and a body still Downed no longer bleeds). This controller draws the whole downed state (it claims the HUD's own downed block,
-- HUD.ClaimDowned) and pushes the "Downed" input context (the torch, the syringe and the menu stay live; sprinting,
-- crouching and prompts do not):
--   * the bleedout: a ring emptying with the time left inside it, extrapolated every frame from BleedoutEndsAt
--     (server time) over GameConfig.BleedoutSeconds, with "BLEEDING OUT" and "YOU'RE DOWN" around it;
--   * the way back: "A teammate can revive you" (Alive teammates left), "No one is left to revive you", or "<name>
--     is reviving you..." with the revive's progress, read from the ChannelActor / ChannelStartedAt /
--     ChannelDuration attributes DownedReviveService's anchor carries (the Revive prompt's host on my character);
--   * the syringe: while SyringeCharges > 0 a button (device glyph: G / D-pad down / a tap mark; tapping or clicking
--     it works too) that sends UseSyringe { SelfRevive }; the Syringe action does the same from any device;
--   * the body: a blood vignette at the screen edges throbbing with a heartbeat that quickens as the time runs out
--     (its throb scaled by the FlashScale setting), the colour draining out of the world (a ColorCorrectionEffect of
--     its own under the camera: saturation, contrast, brightness, a cold red tint) and the panic floor raised
--     (FirstPersonController.SetPanicFloor), which brings in PanicVFX's heartbeat and breathing loops.
-- Coming back up fades it all out; dying fades it out too (SpectatorController takes over).
--
-- The Syringe action outside the downed state: while Alive it sends UseSyringe { Stamina } (the perk's other use,
-- spec §1); the server checks the charge and the life state either way.
--
-- Teammates. Every other Downed player gets a subtle marker seen through walls within MARKER_RANGE studs: a thin
-- ring of their bleedout around a small cross, "DOWN" (or "REVIVING" while someone holds their prompt) and their
-- name. It fades out with distance and again up close (inside MARKER_NEAR the Revive prompt itself takes over).
-- Markers hide with the HUD (cutscenes).
--
-- Prompts. A Revive prompt shows to Alive players only: while I am anything else this client hides every Revive
-- prompt (HUD.SetPromptKindHidden).
--
-- Pure (tests/Specs/Revive.spec.luau): panicFloor, grade, heartRate, statusLine, syringeMode, markerAlpha,
-- reviveProgress.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local Controllers = script.Parent.Parent
local AudioController = require(Controllers.Core.AudioController)
local InputController = require(Controllers.Core.InputController)
local SettingsController = require(Controllers.Core.SettingsController)
local FirstPersonController = require(Controllers.FirstPerson.FirstPersonController)
local HUD = require(Controllers.HUD)
local UIKit = require(Controllers.HUD.UIKit)

local log = Log.new("Downed")

local P = Attributes.Player
local M = Attributes.Match
local W = Attributes.World
local Palette = UIKit.Palette

local NAME = "DownedController"
local SCREEN_ORDER = 21 -- above the HUD (20)
local OVERLAY_ORDER = 14 -- under the HUD's overlay (15)
local CONTEXT: Enums.InputContext = "Downed"
local REVIVE_KIND: Enums.PromptKind = "Revive"
local FADE_IN = 1.4 -- alpha per second
local FADE_OUT = 1.1
local RING_SIZE = 96
local RING_THICKNESS = 4
local PANEL_WIDTH = 420
local PANEL_Y = 0.66 -- of the safe area: under the crosshair line, above the touch buttons
local BUTTON_HEIGHT = 46
local SYRINGE_COOLDOWN = 1
local MARKER_RANGE = 120
local MARKER_NEAR = 9
local MARKER_SIZE = Vector2.new(120, 70)
local MARKER_RING = 30
local MARKER_LIFT = 2.6 -- studs above the root
local MARKER_PEAK = 0.75
local PANIC_REST = 0.3
local PANIC_PEAK = 0.95
local SATURATION_FLOOR = -0.85
local CONTRAST_PEAK = 0.18
local BRIGHTNESS_FLOOR = -0.12
local COLD_RED = Color3.fromRGB(255, 214, 214)

-- Device glyph for the syringe.
type Glyph = { kind: UIKit.GlyphKind, key: Enum.KeyCode? }

type View = {
	gui: ScreenGui,
	overlay: ScreenGui,
	scale: UIScale,
	panel: CanvasGroup,
	title: TextLabel,
	ring: UIKit.Ring,
	time: TextLabel,
	caption: TextLabel,
	hint: TextLabel,
	status: TextLabel,
	progressSlot: Frame,
	progress: UIKit.MeterBar,
	syringe: TextButton,
	syringeKey: UIKit.KeyCap,
	syringeLabel: TextLabel,
	vignette: UIKit.Vignette,
	dim: Frame,
}

type Marker = {
	player: Player,
	gui: BillboardGui,
	group: CanvasGroup,
	ring: UIKit.Ring,
	state: TextLabel,
	name: TextLabel,
	alpha: number,
}

local DownedController = {}

DownedController.Name = NAME
DownedController.MarkerRange = MARKER_RANGE
DownedController.MarkerNear = MARKER_NEAR

local serviceTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local view: View? = nil
local alpha = 0
local clock = 0
local downed = false
local lastSyringeAt = -math.huge
local grade: ColorCorrectionEffect? = nil
local markers: { [Player]: Marker } = {}
local promptsHidden = false

--------------------------------------------------------------------------------
-- Pure (specs: tests/Specs/Revive.spec.luau)
--------------------------------------------------------------------------------

-- The panic floor while `fraction` (1 just down .. 0 bled out) of the bleedout is left.
function DownedController.panicFloor(fraction: number): number
	local spent = 1 - MathUtil.clamp01(fraction)
	return MathUtil.lerp(PANIC_REST, PANIC_PEAK, spent ^ 1.2)
end

-- The downed colour grade at `fraction` of the bleedout left: saturation, contrast, brightness, tint.
function DownedController.grade(fraction: number): (number, number, number, Color3)
	local spent = MathUtil.smoothstep(0, 1, 1 - MathUtil.clamp01(fraction))
	return SATURATION_FLOOR * spent,
		CONTRAST_PEAK * spent,
		BRIGHTNESS_FLOOR * spent * spent,
		Color3.new(1, 1, 1):Lerp(COLD_RED, spent)
end

-- The heart rate (beats per minute) the vignette throbs at with `fraction` of the bleedout left.
function DownedController.heartRate(fraction: number): number
	return MathUtil.lerp(62, 132, (1 - MathUtil.clamp01(fraction)) ^ 1.4)
end

-- What the status line says: a teammate's revive in progress (their display name), else whether anyone is left.
function DownedController.statusLine(reviverName: string?, aliveTeammates: number): (string, { string })
	if reviverName ~= nil then
		return "Downed.BeingRevived", { reviverName }
	end
	if aliveTeammates > 0 then
		return "Downed.TeammateCanRevive", {}
	end
	return "Downed.NoTeammates", {}
end

-- The syringe use the Syringe action asks for (nil: nothing to ask).
function DownedController.syringeMode(lifeState: string, charges: number): Enums.SyringeMode?
	if charges <= 0 then
		return nil
	end
	if lifeState == "Downed" then
		return "SelfRevive"
	elseif lifeState == "Alive" then
		return "Stamina"
	end
	return nil
end

-- A teammate marker's opacity `distance` studs from the camera: out past `range`, faded close in (the prompt takes
-- over inside `near`), full in between.
function DownedController.markerAlpha(distance: number, near: number, range: number): number
	if distance ~= distance or distance >= range then
		return 0
	end
	local far = 1 - MathUtil.smoothstep(range * 0.65, range, distance)
	local close = MathUtil.smoothstep(near * 0.6, near, distance)
	return far * close
end

-- A revive channel's progress (0..1) at server time `now`.
function DownedController.reviveProgress(startedAt: number, duration: number, now: number): number
	if duration <= 0 then
		return 0
	end
	return MathUtil.clamp01((now - startedAt) / duration)
end

--------------------------------------------------------------------------------
-- Reads
--------------------------------------------------------------------------------

local function lifeStateOf(player: Player): string
	return Attributes.getString(player, P.LifeState, "Lobby")
end

local function bleedoutFraction(player: Player, now: number): number
	local endsAt = Attributes.getNumber(player, P.BleedoutEndsAt, now)
	return MathUtil.clamp01((endsAt - now) / math.max(GameConfig.BleedoutSeconds, 1e-3))
end

-- The revive anchor on `player`'s character (the Revive prompt's host), if any.
local function anchorOf(player: Player): Instance?
	local character = player.Character
	if not character then
		return nil
	end
	local prompt = PropKit.findPrompt(character, REVIVE_KIND)
	return if prompt then prompt.Parent else nil
end

-- Who is channelling `anchor` and how far along (server time `now`).
local function channelOn(anchor: Instance?, now: number): (Player?, number)
	if not anchor then
		return nil, 0
	end
	local actor = anchor:GetAttribute(W.ChannelActor)
	if type(actor) ~= "number" or actor == 0 then
		return nil, 0
	end
	local progress = DownedController.reviveProgress(
		Attributes.getNumber(anchor, W.ChannelStartedAt, now),
		Attributes.getNumber(anchor, W.ChannelDuration, 0),
		now
	)
	return Players:GetPlayerByUserId(actor), progress
end

local function aliveTeammates(): number
	local count = 0
	for _, player in Players:GetPlayers() do
		if player ~= localPlayer and lifeStateOf(player) == "Alive" then
			count += 1
		end
	end
	return count
end

local function syringeGlyph(): Glyph
	local device = InputController.GetDevice()
	local binding = InputConfig.Bindings.Syringe
	if device == "Touch" or not binding then
		return { kind = "Touch", key = nil }
	elseif device == "Gamepad" then
		return { kind = "Gamepad", key = binding.gamepad[1] }
	end
	local first = binding.keyboard[1]
	if typeof(first) == "EnumItem" and first.EnumType == Enum.KeyCode then
		return { kind = "Keyboard", key = first :: Enum.KeyCode }
	end
	return { kind = "Keyboard", key = nil }
end

--------------------------------------------------------------------------------
-- Syringe
--------------------------------------------------------------------------------

local function useSyringe()
	local player = localPlayer
	if not player then
		return
	end
	local wanted: Enums.SyringeMode? =
		DownedController.syringeMode(lifeStateOf(player), Attributes.getNumber(player, P.SyringeCharges, 0))
	local now = os.clock()
	if not wanted or now - lastSyringeAt < SYRINGE_COOLDOWN then
		return
	end
	lastSyringeAt = now
	local mode: Enums.SyringeMode = wanted
	local payload: Types.UseSyringePayload = { mode = mode }
	xpcall(Net.Client.fire, function(err: any)
		log.warnThrottled("syringe", 10, "UseSyringe failed: %s", tostring(err))
	end, "UseSyringe", payload)
	AudioController.PlayLocal("UiConfirm")
end

--------------------------------------------------------------------------------
-- View
--------------------------------------------------------------------------------

local function build(parent: Instance): View
	local gui = UIKit.screenGui("Downed", SCREEN_ORDER, Enum.ScreenInsets.CoreUISafeInsets)
	local overlay = UIKit.screenGui("DownedOverlay", OVERLAY_ORDER, Enum.ScreenInsets.None)
	local layer = UIKit.frame(gui, "Layer")
	local scale = Instance.new("UIScale")
	scale.Parent = layer

	local dim = UIKit.fill(overlay, "Dim", Palette.Ink, 1)
	dim.Active = false
	UIKit.gradient(dim, 90, { { 0, 0.15 }, { 0.5, 0.55 }, { 1, 0.15 } })
	local vignette = UIKit.vignette(overlay, "Blood", Palette.Blood, 0.38, 0.04)
	vignette:SetAlpha(0)

	local panel = Instance.new("CanvasGroup")
	panel.Name = "Panel"
	panel.BackgroundTransparency = 1
	panel.BorderSizePixel = 0
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, PANEL_Y)
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.GroupTransparency = 1
	panel.Visible = false
	panel.Parent = layer
	UIKit.list(panel, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)

	local title = UIKit.label(panel, "Title", UIKit.Fonts.Title, UIKit.TextSize.Title, Palette.Bone)
	title.LayoutOrder = 1
	title.Size = UDim2.new(1, 0, 0, 32)
	title.TextWrapped = false
	title.Text = Strings.get("Downed.Title")
	UIKit.textStroke(title, 0.3)

	local ringSlot = UIKit.frame(panel, "Bleedout")
	ringSlot.LayoutOrder = 2
	ringSlot.Size = UDim2.fromOffset(RING_SIZE, RING_SIZE)
	local ring = UIKit.ring(ringSlot, "Ring", RING_SIZE, RING_THICKNESS, Palette.Ember)
	local time = UIKit.label(ringSlot, "Time", UIKit.Fonts.Heavy, 28, Palette.Bone)
	time.TextWrapped = false
	UIKit.textStroke(time, 0.25)

	local caption = UIKit.label(panel, "Caption", UIKit.Fonts.Strong, UIKit.TextSize.Caps, Palette.Ember)
	caption.LayoutOrder = 3
	caption.Size = UDim2.new(1, 0, 0, 16)
	caption.TextWrapped = false
	caption.Text = Strings.get("Hud.Bleedout")
	UIKit.textStroke(caption, 0.4)

	local hint = UIKit.label(panel, "Hint", UIKit.Fonts.Body, UIKit.TextSize.Body, Palette.Ash)
	hint.LayoutOrder = 4
	hint.Size = UDim2.new(1, 0, 0, 0)
	hint.AutomaticSize = Enum.AutomaticSize.Y
	hint.Text = Strings.get("Hud.Downed")
	UIKit.textStroke(hint, 0.4)

	local status = UIKit.label(panel, "Status", UIKit.Fonts.Strong, UIKit.TextSize.Body, Palette.Bone)
	status.LayoutOrder = 5
	status.Size = UDim2.new(1, 0, 0, 0)
	status.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.textStroke(status, 0.35)

	local progressSlot = UIKit.frame(panel, "Revive")
	progressSlot.LayoutOrder = 6
	progressSlot.Size = UDim2.fromOffset(220, 4)
	local progress = UIKit.meterBar(progressSlot, "Progress", Palette.Moss, 4)

	local syringe = Instance.new("TextButton")
	syringe.Name = "Syringe"
	syringe.LayoutOrder = 7
	syringe.AutoButtonColor = false
	syringe.BackgroundColor3 = Palette.Ink
	syringe.BackgroundTransparency = 0.45
	syringe.BorderSizePixel = 0
	syringe.Selectable = false
	syringe.Text = ""
	syringe.AutomaticSize = Enum.AutomaticSize.X
	syringe.Size = UDim2.fromOffset(0, BUTTON_HEIGHT)
	syringe.Parent = panel
	UIKit.corner(syringe, UDim.new(0, 6))
	UIKit.stroke(syringe, Palette.Amber, 1, 0.45)
	UIKit.padding(syringe, 14, 0)
	UIKit.list(
		syringe,
		Enum.FillDirection.Horizontal,
		10,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	)
	local syringeKey = UIKit.keyCap(syringe, "Key", 30)
	syringeKey.root.LayoutOrder = 1
	local syringeLabel = UIKit.label(syringe, "Text", UIKit.Fonts.Body, UIKit.TextSize.Body, Palette.Bone)
	syringeLabel.LayoutOrder = 2
	syringeLabel.Text = Strings.get("Hud.SelfRevive")
	syringeLabel.TextWrapped = false
	syringeLabel.AutomaticSize = Enum.AutomaticSize.X
	syringeLabel.Size = UDim2.fromScale(0, 1)
	syringeLabel.TextXAlignment = Enum.TextXAlignment.Left

	overlay.Parent = parent
	gui.Parent = parent
	return {
		gui = gui,
		overlay = overlay,
		scale = scale,
		panel = panel,
		title = title,
		ring = ring,
		time = time,
		caption = caption,
		hint = hint,
		status = status,
		progressSlot = progressSlot,
		progress = progress,
		syringe = syringe,
		syringeKey = syringeKey,
		syringeLabel = syringeLabel,
		vignette = vignette,
		dim = dim,
	}
end

local function refreshGlyph()
	local current = view
	if current then
		local glyph = syringeGlyph()
		current.syringeKey:SetGlyph(glyph.kind, glyph.key)
	end
end

--------------------------------------------------------------------------------
-- Teammate markers
--------------------------------------------------------------------------------

local function buildMarker(player: Player, parent: Instance, root: BasePart): Marker
	local gui = Instance.new("BillboardGui")
	gui.Name = "DownedMarker"
	gui.ResetOnSpawn = false
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Active = false
	gui.ClipsDescendants = false
	gui.MaxDistance = MARKER_RANGE
	gui.Size = UDim2.fromOffset(MARKER_SIZE.X, MARKER_SIZE.Y)
	gui.StudsOffsetWorldSpace = Vector3.new(0, MARKER_LIFT, 0)
	gui.Adornee = root
	gui.Parent = parent

	local group = Instance.new("CanvasGroup")
	group.Name = "Content"
	group.BackgroundTransparency = 1
	group.BorderSizePixel = 0
	group.Size = UDim2.fromScale(1, 1)
	group.GroupTransparency = 1
	group.Parent = gui

	local ring = UIKit.ring(group, "Bleedout", MARKER_RING, 2.5, Palette.Ember)
	ring.root.AnchorPoint = Vector2.new(0.5, 0)
	ring.root.Position = UDim2.fromScale(0.5, 0)
	for index, size in { UDim2.fromOffset(10, 2), UDim2.fromOffset(2, 10) } do
		local bar = UIKit.fill(ring.root, "Cross" .. index, Palette.Ember, 0.1)
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromScale(0.5, 0.5)
		bar.Size = size
	end

	local state = UIKit.label(group, "State", UIKit.Fonts.Strong, UIKit.TextSize.Caps, Palette.Ember)
	state.AnchorPoint = Vector2.new(0.5, 0)
	state.Position = UDim2.new(0.5, 0, 0, MARKER_RING + 3)
	state.Size = UDim2.new(1, 0, 0, 14)
	state.TextWrapped = false
	UIKit.textStroke(state, 0.4)

	local name = UIKit.label(group, "Name", UIKit.Fonts.Body, UIKit.TextSize.Small, Palette.Bone)
	name.AnchorPoint = Vector2.new(0.5, 0)
	name.Position = UDim2.new(0.5, 0, 0, MARKER_RING + 17)
	name.Size = UDim2.new(1, 0, 0, 16)
	name.TextWrapped = false
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = player.DisplayName
	UIKit.textStroke(name, 0.4)

	return { player = player, gui = gui, group = group, ring = ring, state = state, name = name, alpha = 0 }
end

local function dropMarker(player: Player)
	local marker = markers[player]
	if marker then
		markers[player] = nil
		marker.gui:Destroy()
	end
end

local function updateMarkers(dt: number, now: number, cameraPosition: Vector3?, shown: boolean, live: boolean)
	local player = localPlayer
	local gui = if player then player:FindFirstChildOfClass("PlayerGui") else nil
	local inRun = live and player ~= nil and lifeStateOf(player) ~= "Lobby"
	for _, other in Players:GetPlayers() do
		if other == localPlayer then
			continue
		end
		local character = other.Character
		local rootInstance = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local root = if rootInstance and rootInstance:IsA("BasePart") then rootInstance else nil
		local wanted = inRun and lifeStateOf(other) == "Downed"
		local existing = markers[other]
		if not wanted or not root or not gui then
			if existing then
				dropMarker(other)
			end
			continue
		end
		local marker: Marker
		if existing and existing.gui.Adornee == root then
			marker = existing
		else
			dropMarker(other)
			marker = buildMarker(other, gui, root)
			markers[other] = marker
		end
		local distance = if cameraPosition then (root.Position - cameraPosition).Magnitude else math.huge
		local target = if shown then DownedController.markerAlpha(distance, MARKER_NEAR, MARKER_RANGE) else 0
		marker.alpha = MathUtil.approach(marker.alpha, target, dt * 3)
		local pulse = 0.85 + 0.15 * math.sin(clock * 2.4 + other.UserId)
		local visibleAlpha = marker.alpha * MARKER_PEAK * pulse
		marker.group.GroupTransparency = 1 - visibleAlpha
		marker.gui.Enabled = visibleAlpha > 0.005
		local fraction = bleedoutFraction(other, now)
		marker.ring:SetProgress(fraction)
		local reviver = channelOn(anchorOf(other), now)
		local stateText = Strings.get(if reviver then "Downed.MarkerReviving" else "Downed.Marker")
		if marker.state.Text ~= stateText then
			marker.state.Text = stateText
		end
		local color = if reviver then Palette.Moss else Palette.Ember
		marker.state.TextColor3 = color
		marker.ring:SetColor(color)
		if marker.name.Text ~= other.DisplayName then
			marker.name.Text = other.DisplayName
		end
	end
	for other in table.clone(markers) do
		if other.Parent ~= Players then
			dropMarker(other)
		end
	end
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function setDowned(now: boolean)
	if now == downed then
		return
	end
	downed = now
	if now then
		InputController.PushContext(CONTEXT, NAME)
	else
		InputController.PopContext(NAME)
		FirstPersonController.SetPanicFloor(NAME, nil)
	end
end

local function setPromptsHidden(hidden: boolean)
	if hidden ~= promptsHidden then
		promptsHidden = hidden
		HUD.SetPromptKindHidden(REVIVE_KIND, NAME, hidden)
	end
end

local function updateGrade(camera: Camera?, amount: number, fraction: number)
	local existing = grade
	if amount <= 0.001 or not camera then
		if existing then
			existing.Enabled = false
		end
		return
	end
	local effect: ColorCorrectionEffect
	if existing then
		effect = existing
	else
		effect = Instance.new("ColorCorrectionEffect")
		effect.Name = "DownedGrade"
		grade = effect
	end
	if effect.Parent ~= camera then
		effect.Parent = camera
	end
	local saturation, contrast, brightness, tint = DownedController.grade(fraction)
	effect.Enabled = true
	effect.Saturation = saturation * amount
	effect.Contrast = contrast * amount
	effect.Brightness = brightness * amount
	effect.TintColor = Color3.new(1, 1, 1):Lerp(tint, amount)
end

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
	local state = lifeStateOf(player)
	-- Once the run has ended (RunEnded / Results) the summary owns the screen; a body still Downed is no longer bleeding.
	local phase = ReplicatedStorage:GetAttribute(M.MatchPhase)
	local live = phase == "InRun" or phase == "Deploying"
	local isDowned = live and state == "Downed"
	setDowned(isDowned)
	setPromptsHidden(state ~= "Alive")

	local now = Workspace:GetServerTimeNow()
	local hudShown = HUD.IsVisible()
	updateMarkers(dt, now, if camera then camera.CFrame.Position else nil, hudShown, live)

	alpha = MathUtil.approach(alpha, if isDowned then 1 else 0, dt * (if isDowned then FADE_IN else FADE_OUT))
	local shown = MathUtil.smoothstep(0, 1, alpha)
	local showing = shown > 0.003
	current.panel.Visible = showing
	current.overlay.Enabled = showing
	if not showing then
		updateGrade(camera, 0, 1)
		return
	end

	local fraction = if isDowned then bleedoutFraction(player, now) else 1
	if isDowned then
		FirstPersonController.SetPanicFloor(NAME, DownedController.panicFloor(fraction))
	end
	updateGrade(camera, shown, fraction)

	local flash = SettingsController.GetNumber("FlashScale")
	local beat = HUD.heartbeat(clock, DownedController.heartRate(fraction))
	local throb = 1 - 0.45 * flash * (1 - beat)
	current.vignette:SetAlpha(shown * (0.45 + 0.55 * (1 - fraction)) * throb)
	UIKit.setTransparency(current.dim, UIKit.fade(0.35, shown * MathUtil.smoothstep(0.45, 0, fraction)))

	local panelAlpha = shown * (if hudShown then 1 else 0)
	current.panel.GroupTransparency = 1 - panelAlpha
	current.ring:SetProgress(fraction)
	current.ring:SetColor(Palette.Ember:Lerp(Palette.Blood, 1 - fraction))
	local remaining = math.max(0, Attributes.getNumber(player, P.BleedoutEndsAt, now) - now)
	local text = Strings.formatTime(math.ceil(remaining))
	if current.time.Text ~= text then
		current.time.Text = text
	end
	current.time.TextColor3 =
		Palette.Bone:Lerp(Palette.Ember, MathUtil.clamp01((1 - fraction) * 1.2) * (0.6 + 0.4 * beat))

	local reviver, progress = channelOn(anchorOf(player), now)
	local key, args = DownedController.statusLine(if reviver then reviver.DisplayName else nil, aliveTeammates())
	local line = Strings.get(key, table.unpack(args))
	if current.status.Text ~= line then
		current.status.Text = line
	end
	current.status.TextColor3 = if reviver then Palette.Moss else Palette.Bone
	current.progressSlot.Visible = reviver ~= nil
	current.progress:SetFraction(progress)

	local canInject = DownedController.syringeMode(state, Attributes.getNumber(player, P.SyringeCharges, 0)) ~= nil
	current.syringe.Visible = canInject and isDowned
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function DownedController.Init()
	HUD.ClaimDowned(NAME, true)
	serviceTrove:Add(function()
		HUD.ClaimDowned(NAME, false)
		HUD.SetPromptKindHidden(REVIVE_KIND, NAME, false)
		InputController.PopContext(NAME)
		FirstPersonController.SetPanicFloor(NAME, nil)
		local current = view
		view = nil
		if current then
			current.gui:Destroy()
			current.overlay:Destroy()
		end
		local effect = grade
		grade = nil
		if effect then
			effect:Destroy()
		end
		for player in table.clone(markers) do
			dropMarker(player)
		end
	end)
end

function DownedController.Start()
	local player = localPlayer
	if not player then
		log.warn("no local player; the downed HUD is not shown")
		return
	end
	local gui = player:WaitForChild("PlayerGui")
	xpcall(function()
		local built = build(gui)
		view = built
		serviceTrove:Connect(built.syringe.Activated, useSyringe)
	end, function(err: any)
		log.error("downed HUD failed to build: %s\n%s", tostring(err), debug.traceback())
	end)
	refreshGlyph()
	serviceTrove:Add(InputController.DeviceChanged:Connect(refreshGlyph))
	serviceTrove:Add(InputController.Action("Syringe"):Connect(function(phase: InputController.Phase)
		if phase == "Begin" then
			useSyringe()
		end
	end))
	serviceTrove:Connect(Players.PlayerRemoving, dropMarker)
	serviceTrove:Connect(RunService.PreRender, step)
end

function DownedController.OnRunStarted(_info: Types.RunInfo)
	lastSyringeAt = -math.huge
end

function DownedController.OnRunEnded()
	setDowned(false)
	alpha = 0
	for player in table.clone(markers) do
		dropMarker(player)
	end
end

return table.freeze(DownedController)
