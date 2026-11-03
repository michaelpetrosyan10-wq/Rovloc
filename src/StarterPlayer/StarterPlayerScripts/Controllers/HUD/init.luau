--!strict
-- HUD: everything the player reads on screen, kept minimal and dark.
--
--   * Screens. "HUD" (core-UI safe area) holds the content; "HUDOverlay" (full screen, under it) holds the edge
--     vignette of the downed state. Text and panels sit on a scaled layer (UIKit.scaleFor the viewport); the touch
--     buttons are laid out in screen pixels by MobileControls.
--   * Core UI. The Roblox health bar, backpack and player list are disabled (retried until the core scripts accept
--     it). The player list owned Tab, which is the Objective action here (the nudge toward the goal); the squad's
--     names and states are on SquadPanel instead.
--   * Toasts. Notify messages from the server (claimed from DevToolsController through SetNotifyHandler) and
--     HUD.Toast calls appear top-centre on a dark strip that fades at its ends; at most three, repeats refresh.
--   * Hint. HUD.ShowHint(key, seconds?, ...) shows one centred narrative line (Hud.* keys) above the captions; a new
--     hint crossfades the old one out; seconds <= 0 keeps it until ClearHint.
--   * Data banner. ReplicatedStorage.DataMode "Ephemeral" / "Guest" shows Boot.DataEphemeral / Boot.DataGuest as a
--     small line at the top (dimmer during a run).
--   * Downed. While LifeState is Downed: a blood vignette beating faster as the bleedout runs out, Hud.Downed, the
--     time left (BleedoutEndsAt, server time) and the bleedout bar, and Hud.SelfRevive with the syringe glyph when a
--     charge is left. A later phase that draws the whole downed state itself claims it (ClaimDowned; P8's
--     DownedController), and this block then stays hidden.
--   * Owns StatusBars, PromptRenderer, MobileControls, Captions and SettingsMenu, drives all of them from one
--     PreRender step, and fades the lot out and back in through SetVisible (cutscenes).

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local Core = script.Parent.Core
local DevToolsController = require(Core.DevToolsController)
local InputController = require(Core.InputController)
local SettingsController = require(Core.SettingsController)

local Captions = require(script.Captions)
local MobileControls = require(script.MobileControls)
local PromptRenderer = require(script.PromptRenderer)
local SettingsMenu = require(script.SettingsMenu)
local StatusBars = require(script.StatusBars)
local UIKit = require(script.UIKit)

local log = Log.new("HUD")

local P = Attributes.Player
local M = Attributes.Match
local Palette = UIKit.Palette

export type Toast = {
	text: string,
	bornAt: number,
	expiresAt: number,
	id: number,
	dismissed: boolean,
}

type ToastView = {
	toast: Toast,
	frame: Frame,
	label: TextLabel,
}

type HintState = {
	key: string?,
	text: string,
	expiresAt: number, -- math.huge = until cleared
	alpha: number,
	pending: { key: string, text: string, expiresAt: number }?,
}

local HUD_ORDER = 20
local OVERLAY_ORDER = 15
local CORE_RETRY_SECONDS = 15
local CORE_RETRY_INTERVAL = 0.5
local MAX_TOASTS = 3
local TOAST_DEDUPE = 1.5
local TOAST_FADE_IN = 0.25
local TOAST_FADE_OUT = 0.6
local TOAST_WIDTH = 520
local HINT_FADE_IN = 3
local HINT_FADE_OUT = 1.4
local HINT_SWAP = 6
local VISIBILITY_FADE = 2.5
local DOWNED_FADE_IN = 1.6
local DOWNED_FADE_OUT = 1.2
local CENTRE_BOTTOM = 96 -- design px between the safe area's bottom and the hint / caption column
local TOP_MARGIN = 10

local CORE_GUIS: { Enum.CoreGuiType } =
	{ Enum.CoreGuiType.Health, Enum.CoreGuiType.Backpack, Enum.CoreGuiType.PlayerList }

local HUD = {}

HUD.Name = "HUD"
-- The core GUIs Start turns off (specs check Tab is free for the Objective action).
HUD.DisabledCoreGuis = table.freeze(table.clone(CORE_GUIS))

local serviceTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer

local mounted = false
local visibleTarget = true
local hudAlpha = 1
local clock = 0
local scale = 1

-- Before Start mounts the screens, toasts and hints queue here.
local pendingToasts: { { text: string, seconds: number? } } = {}
local pendingHint: { key: string, seconds: number?, args: { any } }? = nil

local toasts: { Toast } = {}
local toastViews: { [Toast]: ToastView } = {}
local toastId = 0
local hint: HintState = { key = nil, text = "", expiresAt = 0, alpha = 0, pending = nil }

-- Mounted pieces
local statusBars: StatusBars.StatusBars? = nil
local promptRenderer: PromptRenderer.PromptRenderer? = nil
local mobileControls: MobileControls.MobileControls? = nil
local captions: Captions.Captions? = nil
local settingsMenu: SettingsMenu.SettingsMenu? = nil

type Screens = {
	hud: ScreenGui,
	overlay: ScreenGui,
	root: Frame,
	layer: Frame,
	layerScale: UIScale,
	top: Frame,
	toastList: Frame,
	banner: TextLabel,
	centre: Frame,
	hintStrip: Frame,
	hintLabel: TextLabel,
	vignette: UIKit.Vignette,
	downed: Frame,
	downedTitle: TextLabel,
	downedTime: TextLabel,
	downedSlot: Frame,
	revive: Frame,
	reviveKey: UIKit.KeyCap,
	reviveLabel: TextLabel,
}

local screens: Screens? = nil
local downedAlpha = 0
local bannerAlpha = 0
local downedClaims: { [string]: boolean } = {}
local hiddenPromptKinds: { [string]: { [string]: boolean } } = {} -- kind -> tokens hiding it

--------------------------------------------------------------------------------
-- Pure rules (specced)
--------------------------------------------------------------------------------

-- How long a toast or hint of `text` stays when the caller gives no duration.
function HUD.readSeconds(text: string, minimum: number, maximum: number): number
	local length = utf8.len(text) or #text
	return math.clamp(2.5 + length / 24, minimum, maximum)
end

-- Adds a toast (oldest first, in place): an identical live toast within TOAST_DEDUPE is refreshed instead; past
-- MAX_TOASTS the oldest live ones are dismissed. Returns the toast carrying the text.
function HUD.pushToast(list: { Toast }, text: string, now: number, seconds: number, id: number): Toast
	for _, toast in list do
		if not toast.dismissed and toast.text == text and now - toast.bornAt <= TOAST_DEDUPE then
			toast.expiresAt = math.max(toast.expiresAt, now + seconds)
			return toast
		end
	end
	local toast: Toast = { text = text, bornAt = now, expiresAt = now + seconds, id = id, dismissed = false }
	table.insert(list, toast)
	local live = 0
	for index = #list, 1, -1 do
		local entry = list[index]
		if not entry.dismissed then
			live += 1
			if live > MAX_TOASTS then
				entry.dismissed = true
			end
		end
	end
	return toast
end

-- The text of the data-mode banner for a DataMode value, or nil when nothing needs saying.
function HUD.dataBanner(mode: unknown): string?
	if mode == "Ephemeral" then
		return "Boot.DataEphemeral"
	elseif mode == "Guest" then
		return "Boot.DataGuest"
	end
	return nil
end

-- A heartbeat envelope (0..1): a strong beat and a softer echo per cycle, at `bpm`.
function HUD.heartbeat(t: number, bpm: number): number
	local period = 60 / math.max(bpm, 1)
	local phase = (t % period) / period
	local lub = math.exp(-((phase - 0.08) / 0.05) ^ 2)
	local dub = 0.6 * math.exp(-((phase - 0.3) / 0.06) ^ 2)
	return math.clamp(lub + dub, 0, 1)
end

--------------------------------------------------------------------------------
-- Screens
--------------------------------------------------------------------------------

local function playerGui(): Instance?
	local player = localPlayer
	if not player then
		return nil
	end
	return player:WaitForChild("PlayerGui")
end

local function buildScreens(parent: Instance): Screens
	local hud = UIKit.screenGui("HUD", HUD_ORDER, Enum.ScreenInsets.CoreUISafeInsets)
	local overlay = UIKit.screenGui("HUDOverlay", OVERLAY_ORDER, Enum.ScreenInsets.None)

	local root = UIKit.frame(hud, "Root")
	local layer = UIKit.frame(root, "Layer")
	local layerScale = Instance.new("UIScale")
	layerScale.Parent = layer

	-- Top column: data banner, then toasts.
	local top = UIKit.frame(layer, "Top")
	top.AnchorPoint = Vector2.new(0.5, 0)
	top.Position = UDim2.new(0.5, 0, 0, TOP_MARGIN)
	top.Size = UDim2.fromOffset(TOAST_WIDTH, 0)
	top.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.list(top, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)

	local banner = UIKit.label(top, "DataBanner", UIKit.Fonts.Strong, UIKit.TextSize.Small, Palette.Amber)
	banner.LayoutOrder = 0
	banner.Size = UDim2.new(1, 0, 0, 18)
	banner.TextWrapped = false
	banner.TextTruncate = Enum.TextTruncate.AtEnd
	banner.TextTransparency = 1
	banner.Visible = false
	UIKit.textStroke(banner, 0.4)

	local toastList = UIKit.frame(top, "Toasts")
	toastList.LayoutOrder = 1
	toastList.Size = UDim2.fromScale(1, 0)
	toastList.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.list(toastList, Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)

	-- Centre column: hint above captions, kept above the bottom-centre touch buttons.
	local centre = UIKit.frame(layer, "Centre")
	centre.AnchorPoint = Vector2.new(0.5, 1)
	centre.Position = UDim2.new(0.5, 0, 1, -CENTRE_BOTTOM)
	centre.Size = UDim2.new(0.86, 0, 0, 0)
	centre.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.sizeLimit(centre, Vector2.new(0, 0), Vector2.new(760, math.huge))
	UIKit.list(centre, Enum.FillDirection.Vertical, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Bottom)

	local hintStrip = UIKit.fill(centre, "Hint", Palette.Ink, 1)
	hintStrip.LayoutOrder = 1
	hintStrip.Size = UDim2.fromScale(1, 0)
	hintStrip.AutomaticSize = Enum.AutomaticSize.Y
	hintStrip.Visible = false
	UIKit.gradient(hintStrip, 0, { { 0, 1 }, { 0.22, 0.25 }, { 0.78, 0.25 }, { 1, 1 } })
	UIKit.padding(hintStrip, 28, 8)
	local hintLabel = UIKit.label(hintStrip, "Text", UIKit.Fonts.Title, UIKit.TextSize.Hint, Palette.Bone)
	hintLabel.Size = UDim2.fromScale(1, 0)
	hintLabel.AutomaticSize = Enum.AutomaticSize.Y
	hintLabel.TextTransparency = 1
	UIKit.textStroke(hintLabel, 0.35)

	-- Downed: edge vignette on the overlay, the message block in the centre of the layer.
	local vignette = UIKit.vignette(overlay, "Downed", Palette.Blood, 0.32, 0.05)
	vignette.root.Visible = false
	vignette:SetAlpha(0)

	local downed = UIKit.frame(layer, "Downed")
	downed.AnchorPoint = Vector2.new(0.5, 0.5)
	downed.Position = UDim2.fromScale(0.5, 0.4)
	downed.Size = UDim2.fromOffset(420, 0)
	downed.AutomaticSize = Enum.AutomaticSize.Y
	downed.Visible = false
	UIKit.list(downed, Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)

	local downedTitle = UIKit.label(downed, "Message", UIKit.Fonts.Title, 22, Palette.Bone)
	downedTitle.LayoutOrder = 1
	downedTitle.Size = UDim2.new(1, 0, 0, 0)
	downedTitle.AutomaticSize = Enum.AutomaticSize.Y
	downedTitle.Text = Strings.get("Hud.Downed")
	UIKit.textStroke(downedTitle, 0.3)

	local downedTime = UIKit.label(downed, "Time", UIKit.Fonts.Heavy, UIKit.TextSize.Display, Palette.Bone)
	downedTime.LayoutOrder = 2
	downedTime.Size = UDim2.new(1, 0, 0, 46)
	downedTime.TextWrapped = false
	UIKit.textStroke(downedTime, 0.25)

	local downedSlot = UIKit.frame(downed, "Bleedout")
	downedSlot.LayoutOrder = 3
	downedSlot.Size = UDim2.fromOffset(240, 30)

	local revive = UIKit.frame(downed, "SelfRevive")
	revive.LayoutOrder = 4
	revive.Size = UDim2.new(1, 0, 0, 34)
	UIKit.list(
		revive,
		Enum.FillDirection.Horizontal,
		10,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	)
	local reviveKey = UIKit.keyCap(revive, "Key", 30)
	reviveKey.root.LayoutOrder = 1
	local reviveLabel = UIKit.label(revive, "Text", UIKit.Fonts.Body, UIKit.TextSize.Body, Palette.Bone)
	reviveLabel.LayoutOrder = 2
	reviveLabel.Text = Strings.get("Hud.SelfRevive")
	reviveLabel.TextXAlignment = Enum.TextXAlignment.Left
	reviveLabel.TextWrapped = false
	reviveLabel.AutomaticSize = Enum.AutomaticSize.X
	reviveLabel.Size = UDim2.fromScale(0, 1)
	UIKit.textStroke(reviveLabel, 0.35)

	overlay.Parent = parent
	hud.Parent = parent
	return {
		hud = hud,
		overlay = overlay,
		root = root,
		layer = layer,
		layerScale = layerScale,
		top = top,
		toastList = toastList,
		banner = banner,
		centre = centre,
		hintStrip = hintStrip,
		hintLabel = hintLabel,
		vignette = vignette,
		downed = downed,
		downedTitle = downedTitle,
		downedTime = downedTime,
		downedSlot = downedSlot,
		revive = revive,
		reviveKey = reviveKey,
		reviveLabel = reviveLabel,
	}
end

--------------------------------------------------------------------------------
-- Toasts
--------------------------------------------------------------------------------

local function toastAlpha(toast: Toast, now: number): number
	local fadeIn = math.clamp((now - toast.bornAt) / TOAST_FADE_IN, 0, 1)
	local fadeOut = math.clamp((toast.expiresAt - now) / TOAST_FADE_OUT, 0, 1)
	return math.min(fadeIn, fadeOut)
end

local function buildToast(list: Frame, toast: Toast): ToastView
	local frame = UIKit.fill(list, "Toast", Palette.Ink, 1)
	frame.LayoutOrder = toast.id
	frame.Size = UDim2.fromScale(1, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.gradient(frame, 0, { { 0, 1 }, { 0.18, 0.2 }, { 0.82, 0.2 }, { 1, 1 } })
	UIKit.padding(frame, 34, 7)
	local label = UIKit.label(frame, "Text", UIKit.Fonts.Body, UIKit.TextSize.Body, Palette.Bone)
	label.Size = UDim2.fromScale(1, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.Text = toast.text
	label.TextTransparency = 1
	UIKit.textStroke(label, 0.4)
	return { toast = toast, frame = frame, label = label }
end

local function updateToasts(built: Screens)
	local index = 1
	while index <= #toasts do
		local toast = toasts[index]
		if toast.dismissed and toast.expiresAt > clock + TOAST_FADE_OUT then
			toast.expiresAt = clock + TOAST_FADE_OUT
		end
		if clock >= toast.expiresAt then
			table.remove(toasts, index)
			local view = toastViews[toast]
			if view then
				view.frame:Destroy()
				toastViews[toast] = nil
			end
		else
			index += 1
		end
	end
	for _, toast in toasts do
		local view = toastViews[toast]
		if not view then
			view = buildToast(built.toastList, toast)
			toastViews[toast] = view
		end
		local shown = toastAlpha(toast, clock) * hudAlpha
		UIKit.setTransparency(view.frame, UIKit.fade(0.3, shown))
		UIKit.setTextTransparency(view.label, UIKit.fade(0, shown))
	end
end

--------------------------------------------------------------------------------
-- Hint
--------------------------------------------------------------------------------

local function setHint(key: string, text: string, seconds: number?)
	local duration = if seconds == nil then HUD.readSeconds(text, 3.5, 9) else seconds
	local expiresAt = if duration <= 0 then math.huge else clock + duration
	if hint.alpha > 0.01 and hint.text ~= text then
		hint.pending = { key = key, text = text, expiresAt = expiresAt }
		return
	end
	hint.key = key
	hint.text = text
	hint.expiresAt = expiresAt
	hint.pending = nil
end

local function updateHint(built: Screens, dt: number)
	local pending = hint.pending
	local showing = hint.text ~= "" and clock < hint.expiresAt
	if pending then
		hint.alpha = math.max(0, hint.alpha - HINT_SWAP * dt)
		if hint.alpha <= 0 then
			hint.key = pending.key
			hint.text = pending.text
			hint.expiresAt = pending.expiresAt
			hint.pending = nil
		end
	elseif showing then
		hint.alpha = math.min(1, hint.alpha + HINT_FADE_IN * dt)
	else
		hint.alpha = math.max(0, hint.alpha - HINT_FADE_OUT * dt)
		if hint.alpha <= 0 then
			hint.key = nil
			hint.text = ""
		end
	end
	if built.hintLabel.Text ~= hint.text then
		built.hintLabel.Text = hint.text
	end
	local breathe = 0.5 + 0.5 * math.sin(clock * 1.7)
	local shown = MathUtil.smoothstep(0, 1, hint.alpha) * hudAlpha
	built.hintStrip.Visible = shown > 0.005
	UIKit.setTransparency(built.hintStrip, UIKit.fade(0.35, shown))
	UIKit.setTextTransparency(built.hintLabel, UIKit.fade(0.1 * breathe, shown))
end

--------------------------------------------------------------------------------
-- Banner and downed state
--------------------------------------------------------------------------------

local function updateBanner(built: Screens, dt: number)
	local key = HUD.dataBanner(ReplicatedStorage:GetAttribute(M.DataMode))
	local inRun = ReplicatedStorage:GetAttribute(M.RunId) ~= nil
	local target = if key == nil then 0 elseif inRun then 0.55 else 1
	if key then
		local text = Strings.get(key)
		if built.banner.Text ~= text then
			built.banner.Text = text
		end
	end
	bannerAlpha = MathUtil.approach(bannerAlpha, target, dt * 2)
	built.banner.Visible = bannerAlpha > 0.005
	UIKit.setTextTransparency(built.banner, UIKit.fade(0, bannerAlpha * hudAlpha))
end

local function syringeKey(): (UIKit.GlyphKind, Enum.KeyCode?)
	local device = InputController.GetDevice()
	local binding = InputConfig.Bindings.Syringe
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

local function refreshReviveGlyph()
	local built = screens
	if built then
		local kind: UIKit.GlyphKind, keyCode: Enum.KeyCode? = syringeKey()
		built.reviveKey:SetGlyph(kind, keyCode)
	end
end

local function updateDowned(built: Screens, dt: number)
	local player = localPlayer
	local downedNow = player ~= nil
		and next(downedClaims) == nil
		and Attributes.getString(player, P.LifeState, "Lobby") == "Downed"
	downedAlpha = MathUtil.approach(
		downedAlpha,
		if downedNow then 1 else 0,
		dt * (if downedNow then DOWNED_FADE_IN else DOWNED_FADE_OUT)
	)
	local visible = downedAlpha > 0.005
	built.downed.Visible = visible
	built.vignette.root.Visible = visible
	if not visible or not player then
		return
	end
	local now = Workspace:GetServerTimeNow()
	local endsAt = Attributes.getNumber(player, P.BleedoutEndsAt, now)
	local remaining = math.max(0, endsAt - now)
	local fraction = StatusBars.bleedoutFraction(endsAt, now, GameConfig.BleedoutSeconds)
	local bpm = MathUtil.lerp(64, 118, 1 - fraction)
	local beat = HUD.heartbeat(clock, bpm)
	local shown = MathUtil.smoothstep(0, 1, downedAlpha) * hudAlpha

	built.vignette:SetAlpha(shown * (0.55 + 0.45 * beat))
	UIKit.setTextTransparency(built.downedTitle, UIKit.fade(0, shown))
	local time = Strings.formatTime(math.ceil(remaining))
	if built.downedTime.Text ~= time then
		built.downedTime.Text = time
	end
	built.downedTime.TextColor3 =
		Palette.Bone:Lerp(Palette.Ember, math.clamp((1 - fraction) * 1.2, 0, 1) * (0.6 + 0.4 * beat))
	UIKit.setTextTransparency(built.downedTime, UIKit.fade(0, shown))

	local canRevive = Attributes.getNumber(player, P.SyringeCharges, 0) > 0
	built.revive.Visible = canRevive
	if canRevive then
		built.reviveKey:SetAlpha(shown)
		UIKit.setTextTransparency(built.reviveLabel, UIKit.fade(0.05, shown))
	end
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function onUpdateError(err: any)
	log.warnThrottled("update", 10, "a HUD component failed to update: %s\n%s", tostring(err), debug.traceback())
end

local function step(dt: number)
	local built = screens
	if not built then
		return
	end
	clock += dt
	hudAlpha = MathUtil.approach(hudAlpha, if visibleTarget then 1 else 0, dt * VISIBILITY_FADE)

	local camera = Workspace.CurrentCamera
	local nextScale = if camera then UIKit.scaleFor(camera.ViewportSize) else 1
	if math.abs(nextScale - scale) > 1e-3 then
		scale = nextScale
		built.layerScale.Scale = scale
		built.layer.Size = UDim2.fromScale(1 / scale, 1 / scale)
	end

	local mobile = mobileControls
	local reserved = if mobile then mobile:ReservedBottom() / scale else 0
	built.centre.Position = UDim2.new(0.5, 0, 1, -math.max(CENTRE_BOTTOM, reserved + 16))

	updateToasts(built)
	updateHint(built, dt)
	updateBanner(built, dt)
	updateDowned(built, dt)

	local bars = statusBars
	if bars then
		xpcall(bars.Update, onUpdateError, bars, dt, hudAlpha)
	end
	local prompts = promptRenderer
	if prompts then
		xpcall(prompts.Update, onUpdateError, prompts, dt, hudAlpha)
	end
	if mobile then
		xpcall(mobile.Update, onUpdateError, mobile, dt, hudAlpha)
	end
	local lines = captions
	if lines then
		xpcall(lines.Update, onUpdateError, lines, dt, hudAlpha)
	end
	local menu = settingsMenu
	if menu then
		xpcall(menu.Update, onUpdateError, menu, dt)
	end
end

local function disableCoreGuis()
	local deadline = os.clock() + CORE_RETRY_SECONDS
	local remaining = table.clone(CORE_GUIS)
	while #remaining > 0 do
		for index = #remaining, 1, -1 do
			local kind = remaining[index]
			local ok = pcall(function()
				StarterGui:SetCoreGuiEnabled(kind, false)
			end)
			if ok then
				table.remove(remaining, index)
			end
		end
		if #remaining == 0 then
			return
		end
		if os.clock() >= deadline then
			log.warn("could not disable %d core GUI element(s)", #remaining)
			return
		end
		task.wait(CORE_RETRY_INTERVAL)
	end
end

local function mount(gui: Instance)
	local built = buildScreens(gui)
	screens = built
	serviceTrove:Add(built.hud)
	serviceTrove:Add(built.overlay)

	local function deviceName(): string
		return InputController.GetDevice()
	end
	local function currentScale(): number
		return scale
	end

	statusBars = StatusBars.mount({ root = built.layer, downed = built.downedSlot, device = deviceName })
	captions = Captions.mount({
		root = built.centre,
		enabled = function(): boolean
			return SettingsController.GetBool("Captions")
		end,
	})
	local renderer = PromptRenderer.mount({ playerGui = gui, scale = currentScale, device = deviceName })
	promptRenderer = renderer
	for kind, tokens in hiddenPromptKinds do
		renderer:SetKindHidden(kind, next(tokens) ~= nil)
	end
	mobileControls = MobileControls.mount({ root = built.root, playerGui = gui, scale = currentScale })
	settingsMenu = SettingsMenu.mount({ playerGui = gui, scale = currentScale })

	serviceTrove:Add(InputController.DeviceChanged:Connect(function()
		local prompts = promptRenderer
		if prompts then
			prompts:RefreshGlyphs()
		end
		refreshReviveGlyph()
	end))
	refreshReviveGlyph()

	mounted = true
	for _, queued in pendingToasts do
		HUD.Toast(queued.text, queued.seconds)
	end
	table.clear(pendingToasts)
	local queuedHint = pendingHint
	pendingHint = nil
	if queuedHint then
		HUD.ShowHint(queuedHint.key, queuedHint.seconds, table.unpack(queuedHint.args))
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

local promptHolds: { [string]: boolean } = {}

local function applyPrompts()
	-- Prompts go with the HUD: nothing can be started on this client while it is hidden or a hold is on them.
	ProximityPromptService.Enabled = visibleTarget and next(promptHolds) == nil
end

-- Shows or hides the whole HUD (cutscenes). Fades; prompts and touch buttons go with it.
function HUD.SetVisible(visible: boolean)
	visibleTarget = visible
	applyPrompts()
end

-- Turns every ProximityPrompt off on this client while any token holds it (hidden in a locker: the neighbours' Hide
-- prompts must not show through the door), without hiding the rest of the HUD.
function HUD.SetPromptsSuppressed(token: string, suppressed: boolean)
	if suppressed then
		promptHolds[token] = true
	else
		promptHolds[token] = nil
	end
	applyPrompts()
end

function HUD.IsVisible(): boolean
	return visibleTarget
end

-- Hides every prompt of PromptKind `kind` on this client while any token holds it (P8: Revive prompts show to Alive
-- players only), without touching other prompts.
function HUD.SetPromptKindHidden(kind: string, token: string, hidden: boolean)
	local tokens = hiddenPromptKinds[kind]
	if not tokens then
		tokens = {}
		hiddenPromptKinds[kind] = tokens
	end
	if hidden then
		tokens[token] = true
	else
		tokens[token] = nil
	end
	local prompts = promptRenderer
	if prompts then
		prompts:SetKindHidden(kind, next(tokens) ~= nil)
	end
end

-- While any token claims it, the built-in downed block (vignette, message, timer, syringe line) stays hidden: the
-- claimant draws the downed state itself (P8 DownedController).
function HUD.ClaimDowned(token: string, claimed: boolean)
	if claimed then
		downedClaims[token] = true
	else
		downedClaims[token] = nil
	end
end

-- A short message top-centre for `seconds` (default: by length).
function HUD.Toast(text: string, seconds: number?)
	if type(text) ~= "string" or text == "" then
		return
	end
	if not mounted then
		table.insert(pendingToasts, { text = text, seconds = seconds })
		return
	end
	toastId += 1
	HUD.pushToast(toasts, text, clock, seconds or HUD.readSeconds(text, 3, 14), toastId)
end

-- A centred contextual hint: Strings.get(key, ...) for `seconds` (default: by length; <= 0 = until ClearHint).
function HUD.ShowHint(key: string, seconds: number?, ...: any)
	if not mounted then
		pendingHint = { key = key, seconds = seconds, args = { ... } }
		return
	end
	setHint(key, Strings.get(key, ...), seconds)
end

-- Clears the hint (only if it is `key`, when given).
function HUD.ClearHint(key: string?)
	if not mounted then
		if key == nil or (pendingHint and pendingHint.key == key) then
			pendingHint = nil
		end
		return
	end
	local pending = hint.pending
	if pending and (key == nil or pending.key == key) then
		hint.pending = nil
	end
	if key == nil or hint.key == key then
		hint.expiresAt = 0
	end
end

function HUD.OpenSettings()
	local menu = settingsMenu
	if menu then
		menu:Open()
	end
end

function HUD.CloseSettings()
	local menu = settingsMenu
	if menu then
		menu:Close()
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function HUD.Init()
	DevToolsController.SetNotifyHandler(function(text: string, _payload: Types.NotifyPayload)
		HUD.Toast(text)
	end)
end

function HUD.Start()
	task.spawn(disableCoreGuis)
	local gui = playerGui()
	if not gui then
		return
	end
	xpcall(mount, function(err: any)
		log.error("HUD failed to mount: %s\n%s", tostring(err), debug.traceback())
	end, gui)
	serviceTrove:Connect(RunService.PreRender, step)
end

function HUD.OnRunStarted(_info: Types.RunInfo)
	HUD.ClearHint()
end

function HUD.OnRunEnded()
	HUD.ClearHint()
	local lines = captions
	if lines then
		lines:Clear()
	end
end

return table.freeze(HUD)
