--!strict
-- EscapeSummaryController: the end-of-run screen (spec §1 "Play Again"; the Level 5 finale's ESCAPED summary).
--
-- RunSummary (MatchAndDataService sends it once per run to each participant) opens a full-screen summary:
--   * Title treatment by outcome: ESCAPED (Results.Escaped) in bone white with a cold storm-light glow, landing with a
--     lightning flash (scaled by the FlashScale setting); WIPED (Results.Wiped: nobody got out) and DEAD (Results.Dead:
--     you died, others escaped) in blood red with a failing-bulb flicker. Under it the squad line (Results.Squad) and
--     the difficulty.
--   * Run time and best time (Results.Time / Results.BestTime), a NEW BEST TIME tag, the credits earned counting up
--     (Results.Credits), the stat rows (traps triggered, vents crawled, flasks thrown, stuns, revives, lockers hidden,
--     floors cleared, times downed) and Results.NotSaved when the run paid nothing (a DevRun, guest data).
--   * Play Again (the PlayAgain remote): click / tap, gamepad A (the button is selected on a gamepad), Enter on a
--     keyboard; pressed, it reads Results.Waiting. Under it the auto-return countdown (Results.Returning) with a
--     draining bar, from ReplicatedStorage.ResultsEndsAt (server time, MatchResetService).
-- While it is up the cursor is free (CursorController), gameplay input is off (the "Menu" input context) and the HUD is
-- hidden. It waits while a finale shot or a jumpscare owns the view (the Cutscene input context, or a Cutscene /
-- Jumpscare / Parachute control lock), at most HOLD_MAX_SECONDS after the summary arrived, then fades in from black.
-- It closes when the match moves on to Resetting / Lobby or the run ends.
--
-- Pure (tests/Specs/EscapeSummary.spec.luau): titleKind, titleKey, statRows, countdown, countUp, holding, squadText,
-- timeText, bestText.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local Controllers = script.Parent.Parent
local AudioController = require(Controllers.Core.AudioController)
local CursorController = require(Controllers.Core.CursorController)
local InputController = require(Controllers.Core.InputController)
local SettingsController = require(Controllers.Core.SettingsController)
local HUD = require(Controllers.HUD)
local UIKit = require(Controllers.HUD.UIKit)

local log = Log.new("EscapeSummary")

local P = Attributes.Player
local M = Attributes.Match
local Palette = UIKit.Palette

export type TitleKind = "Escaped" | "Wiped" | "Dead"

export type StatRow = { key: string, stat: Enums.StatKey, value: number }

type View = {
	backdropGui: ScreenGui,
	gui: ScreenGui,
	backdrop: Frame,
	flash: Frame,
	vignette: UIKit.Vignette,
	scale: UIScale,
	root: CanvasGroup,
	title: TextLabel,
	titleStroke: UIStroke,
	titleScale: UIScale,
	rule: Frame,
	squad: TextLabel,
	difficulty: TextLabel,
	time: TextLabel,
	best: TextLabel,
	newBest: TextLabel,
	credits: TextLabel,
	rows: { TextLabel },
	note: TextLabel,
	button: TextButton,
	buttonStroke: UIStroke,
	countdown: TextLabel,
	bar: UIKit.MeterBar,
}

local TOKEN = "EscapeSummary"
local CONFIRM_ACTION = "EscapeSummaryConfirm"
local BACKDROP_ORDER = 39
local SCREEN_ORDER = 40 -- above the HUD (20) and the airlock banner (22)
local CONTENT_WIDTH = 560
local CONTENT_HEIGHT = 640
local FIT = 0.94 -- the content never takes more than this share of the screen
local HOLD_MAX_SECONDS = 10
local FADE_IN = 0.9 -- alpha per second
local FADE_OUT = 1.8
local TITLE_DELAY = 0.15
local TITLE_REVEAL = 0.9
local CREDIT_DELAY = 0.8
local COUNT_UP_SECONDS = 1.6
local FLASH_PEAK = 0.55
local FLASH_DECAY = 6
local TITLE_SIZE = 58
local CLOSING_PHASES: { [string]: boolean } = { Resetting = true, Lobby = true }
local ESCAPE_TINT = Color3.fromRGB(18, 34, 46) -- the escape's vignette: night sky over the storm
local FLASH_COLOR = Color3.fromRGB(214, 226, 240) -- lightning
local HOLDING_LOCKS: { [string]: boolean } = { Cutscene = true, Jumpscare = true, Parachute = true }

-- Stat rows in display order: the RunStats key and its Strings line.
local STAT_ROWS: { { stat: Enums.StatKey, key: string } } = {
	{ stat = "TrapsTriggered", key = "Results.TrapsTriggered" },
	{ stat = "VentsCrawled", key = "Results.VentsCrawled" },
	{ stat = "FlasksThrown", key = "Results.FlasksThrown" },
	{ stat = "Stuns", key = "Results.Stuns" },
	{ stat = "Revives", key = "Results.Revives" },
	{ stat = "LockersHidden", key = "Results.LockersHidden" },
	{ stat = "FloorsCleared", key = "Results.FloorsCleared" },
	{ stat = "TimesDowned", key = "Results.TimesDowned" },
}

local TITLE_KEYS: { [string]: string } = {
	Escaped = "Results.Escaped",
	Wiped = "Results.Wiped",
	Dead = "Results.Dead",
}

local EscapeSummaryController = {}

EscapeSummaryController.Name = "EscapeSummaryController"
EscapeSummaryController.HoldMaxSeconds = HOLD_MAX_SECONDS
EscapeSummaryController.StatRows = table.freeze(table.clone(STAT_ROWS))

local serviceTrove = Trove.new()
local view: View? = nil
local pending: Types.RunSummaryPayload? = nil
local kind: TitleKind = "Wiped"
local receivedAt = 0
local shownAt = 0
local showing = false
local pressed = false
local hovered = false
local alpha = 0
local clock = 0
local endsAtSeen: number? = nil
local countdownTotal = 1

--------------------------------------------------------------------------------
-- Pure (specs: tests/Specs/EscapeSummary.spec.luau)
--------------------------------------------------------------------------------

-- Which title the summary wears: ESCAPED for an escape, WIPED when nobody got out, DEAD when others did.
function EscapeSummaryController.titleKind(outcome: Enums.RunOutcome, escapees: number?): TitleKind
	if outcome == "Escaped" then
		return "Escaped"
	end
	return if (escapees or 0) > 0 then "Dead" else "Wiped"
end

function EscapeSummaryController.titleKey(titleKind: TitleKind): string
	return TITLE_KEYS[titleKind]
end

-- Every stat row in display order (missing stats read 0, fractions are dropped).
function EscapeSummaryController.statRows(stats: { [string]: number }?): { StatRow }
	local rows: { StatRow } = {}
	for _, row in STAT_ROWS do
		local value = if stats then stats[row.stat] else nil
		local count = if type(value) == "number" and MathUtil.isFinite(value) then math.max(0, math.floor(value)) else 0
		table.insert(rows, { key = row.key, stat = row.stat, value = count })
	end
	return rows
end

-- The auto-return countdown at server time `now`: whole seconds left (nil without a deadline) and the bar's fill
-- (1 full .. 0 at the deadline) for a countdown that started `total` seconds before `endsAt`.
function EscapeSummaryController.countdown(now: number, endsAt: number?, total: number): (number?, number)
	if endsAt == nil or not MathUtil.isFinite(endsAt) then
		return nil, 0
	end
	local remaining = math.max(0, endsAt - now)
	return math.ceil(remaining), math.clamp(remaining / math.max(total, 1e-3), 0, 1)
end

-- The credits shown `elapsed` seconds into the count-up to `total` (ease-out, whole numbers, exact at the end).
function EscapeSummaryController.countUp(elapsed: number, total: number): number
	if total <= 0 or elapsed <= 0 then
		return 0
	end
	local t = math.clamp(elapsed / COUNT_UP_SECONDS, 0, 1)
	local eased = 1 - (1 - t) ^ 3
	return if t >= 1 then total else math.min(total, math.floor(total * eased + 0.5))
end

-- Whether the summary still waits for the view: a cutscene / jumpscare / parachute owns it, for at most
-- HOLD_MAX_SECONDS after the summary arrived.
function EscapeSummaryController.holding(context: string, controlLock: string, waited: number): boolean
	if waited >= HOLD_MAX_SECONDS then
		return false
	end
	return context == "Cutscene" or HOLDING_LOCKS[controlLock] == true
end

-- "2 of 4 escaped" (nil when the payload did not say).
function EscapeSummaryController.squadText(escapees: number?, squadSize: number?): string?
	if escapees == nil or squadSize == nil or squadSize <= 0 then
		return nil
	end
	return Strings.get("Results.Squad", math.clamp(escapees, 0, squadSize), squadSize)
end

function EscapeSummaryController.timeText(seconds: number): string
	return Strings.get("Results.Time", Strings.formatTime(seconds))
end

-- The best-time line, or nil when there is no best time yet.
function EscapeSummaryController.bestText(bestTime: number?): string?
	if bestTime == nil or not MathUtil.isFinite(bestTime) or bestTime <= 0 then
		return nil
	end
	return Strings.get("Results.BestTime", Strings.formatTime(bestTime))
end

--------------------------------------------------------------------------------
-- View
--------------------------------------------------------------------------------

local function line(parent: Instance, name: string, order: number, font: Font, size: number, color: Color3): TextLabel
	local label = UIKit.label(parent, name, font, size, color)
	label.LayoutOrder = order
	label.Size = UDim2.new(1, 0, 0, math.ceil(size * 1.35))
	label.TextWrapped = false
	label.TextTruncate = Enum.TextTruncate.AtEnd
	return label
end

local function build(parent: Instance): View
	local backdropGui = UIKit.screenGui("EscapeSummaryBackdrop", BACKDROP_ORDER, Enum.ScreenInsets.None)
	backdropGui.Enabled = false
	local backdrop = UIKit.fill(backdropGui, "Backdrop", Palette.Ink, 1)
	backdrop.Active = true -- swallows clicks meant for the world under the summary
	local vignette = UIKit.vignette(backdrop, "Vignette", Palette.Blood, 0.38, 0.35)
	vignette:SetAlpha(0)
	local flash = UIKit.fill(backdropGui, "Flash", FLASH_COLOR, 1)
	flash.ZIndex = 5

	local gui = UIKit.screenGui("EscapeSummary", SCREEN_ORDER, Enum.ScreenInsets.CoreUISafeInsets)
	gui.Enabled = false
	local layer = UIKit.frame(gui, "Layer")
	local scale = Instance.new("UIScale")
	scale.Parent = layer

	local root = Instance.new("CanvasGroup")
	root.Name = "Summary"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromOffset(CONTENT_WIDTH, CONTENT_HEIGHT)
	root.GroupTransparency = 1
	root.Parent = layer
	UIKit.list(root, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)

	local title = line(root, "Title", 1, UIKit.Fonts.Title, TITLE_SIZE, Palette.Bone)
	title.TextTruncate = Enum.TextTruncate.None
	title.TextScaled = true
	local titleLimit = Instance.new("UITextSizeConstraint")
	titleLimit.MaxTextSize = TITLE_SIZE
	titleLimit.MinTextSize = 24
	titleLimit.Parent = title
	local titleScale = Instance.new("UIScale")
	titleScale.Parent = title
	local titleStroke = Instance.new("UIStroke")
	titleStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	titleStroke.Color = Palette.Cyan
	titleStroke.Thickness = 2
	titleStroke.Transparency = 0.5
	titleStroke.Parent = title

	local rule = UIKit.fill(root, "Rule", Palette.Stroke, 0.2)
	rule.LayoutOrder = 2
	rule.Size = UDim2.new(0.7, 0, 0, 1)
	UIKit.gradient(rule, 0, { { 0, 1 }, { 0.25, 0 }, { 0.75, 0 }, { 1, 1 } })

	local squad = line(root, "Squad", 3, UIKit.Fonts.Strong, UIKit.TextSize.Hint, Palette.Bone)
	local difficulty = line(root, "Difficulty", 4, UIKit.Fonts.Body, UIKit.TextSize.Small, Palette.Ash)

	local times = UIKit.panel(root, "Times", 0.25, 9127)
	times.LayoutOrder = 5
	times.Size = UDim2.new(1, 0, 0, 74)
	UIKit.padding(times, 18, 8)
	UIKit.list(times, Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local time = line(times, "Time", 1, UIKit.Fonts.Heavy, UIKit.TextSize.Title, Palette.Bone)
	local bestRow = UIKit.frame(times, "BestRow")
	bestRow.LayoutOrder = 2
	bestRow.Size = UDim2.new(1, 0, 0, 22)
	UIKit.list(
		bestRow,
		Enum.FillDirection.Horizontal,
		10,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	)
	local best = UIKit.label(bestRow, "Best", UIKit.Fonts.Body, UIKit.TextSize.Body, Palette.Ash)
	best.LayoutOrder = 1
	best.AutomaticSize = Enum.AutomaticSize.X
	best.Size = UDim2.new(0, 0, 1, 0)
	best.TextWrapped = false
	local newBest = UIKit.label(bestRow, "NewBest", UIKit.Fonts.Heavy, UIKit.TextSize.Caps, Palette.Ink)
	newBest.LayoutOrder = 2
	newBest.AutomaticSize = Enum.AutomaticSize.X
	newBest.Size = UDim2.new(0, 0, 0, 18)
	newBest.TextWrapped = false
	newBest.BackgroundColor3 = Palette.Amber
	newBest.BackgroundTransparency = 0
	newBest.Text = Strings.get("Results.NewBest")
	UIKit.padding(newBest, 8, 0)
	UIKit.corner(newBest, UDim.new(0, 4))

	local credits = line(root, "Credits", 6, UIKit.Fonts.Heavy, UIKit.TextSize.Title, Palette.Amber)
	UIKit.textStroke(credits, 0.4)

	local stats = UIKit.panel(root, "Stats", 0.3, 4471)
	stats.LayoutOrder = 7
	stats.Size = UDim2.new(1, 0, 0, 4 * 30 + 20)
	UIKit.padding(stats, 18, 10)
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(0.5, -6, 0, 28)
	grid.CellPadding = UDim2.fromOffset(12, 2)
	grid.FillDirection = Enum.FillDirection.Horizontal
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.Parent = stats
	local rows: { TextLabel } = {}
	for index, row in STAT_ROWS do
		local label = UIKit.label(stats, row.stat, UIKit.Fonts.Body, UIKit.TextSize.Body, Palette.Bone)
		label.LayoutOrder = index
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextWrapped = false
		label.TextTruncate = Enum.TextTruncate.AtEnd
		table.insert(rows, label)
	end

	local note = line(root, "Note", 8, UIKit.Fonts.Body, UIKit.TextSize.Small, Palette.Ash)
	note.Text = Strings.get("Results.NotSaved")

	local button = Instance.new("TextButton")
	button.Name = "PlayAgain"
	button.LayoutOrder = 9
	button.Size = UDim2.fromOffset(300, 56)
	button.BackgroundColor3 = Palette.Raised
	button.BackgroundTransparency = 0.05
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Selectable = true
	button.FontFace = UIKit.Fonts.Heavy
	button.TextSize = UIKit.TextSize.Hint
	button.TextColor3 = Palette.Bone
	button.Text = Strings.get("Results.PlayAgain")
	button.Parent = root
	UIKit.corner(button, UDim.new(0, 8))
	local buttonStroke = UIKit.stroke(button, Palette.StrokeDim, 1.5, 0)
	local highlight = UIKit.frame(nil, "Selection")
	UIKit.corner(highlight, UDim.new(0, 8))
	UIKit.stroke(highlight, Palette.Amber, 2, 0.1)
	button.SelectionImageObject = highlight

	local countdown = line(root, "Countdown", 10, UIKit.Fonts.Body, UIKit.TextSize.Small, Palette.Ash)
	local barHolder = UIKit.frame(root, "TimerHolder")
	barHolder.LayoutOrder = 11
	barHolder.Size = UDim2.new(0.6, 0, 0, 4)
	local bar = UIKit.meterBar(barHolder, "Timer", Palette.Amber, 4)

	backdropGui.Parent = parent
	gui.Parent = parent
	return {
		backdropGui = backdropGui,
		gui = gui,
		backdrop = backdrop,
		flash = flash,
		vignette = vignette,
		scale = scale,
		root = root,
		title = title,
		titleStroke = titleStroke,
		titleScale = titleScale,
		rule = rule,
		squad = squad,
		difficulty = difficulty,
		time = time,
		best = best,
		newBest = newBest,
		credits = credits,
		rows = rows,
		note = note,
		button = button,
		buttonStroke = buttonStroke,
		countdown = countdown,
		bar = bar,
	}
end

-- Writes the summary's static text into the view.
local function fill(current: View, payload: Types.RunSummaryPayload)
	kind = EscapeSummaryController.titleKind(payload.outcome, payload.escapees)
	current.title.Text = Strings.get(EscapeSummaryController.titleKey(kind))
	local escapedLook = kind == "Escaped"
	current.titleStroke.Color = if escapedLook then Palette.Cyan else Palette.Blood
	current.vignette:SetColor(if escapedLook then ESCAPE_TINT else Palette.Blood)
	local squad = EscapeSummaryController.squadText(payload.escapees, payload.squadSize)
	current.squad.Text = squad or ""
	current.squad.Visible = squad ~= nil
	local difficulty = payload.difficulty
	current.difficulty.Text = if difficulty then Strings.get("Lobby.Difficulty." .. difficulty) else ""
	current.difficulty.Visible = difficulty ~= nil
	current.time.Text = EscapeSummaryController.timeText(payload.runSeconds)
	local best = EscapeSummaryController.bestText(payload.bestTime)
	current.best.Text = best or ""
	current.best.Visible = best ~= nil
	current.newBest.Visible = payload.newBest == true and best ~= nil
	current.credits.Text = Strings.get("Results.Credits", 0)
	for index, row in EscapeSummaryController.statRows(payload.stats) do
		local label = current.rows[index]
		if label then
			label.Text = Strings.get(row.key, row.value)
			label.TextColor3 = if row.value > 0 then Palette.Bone else Palette.Smoke
		end
	end
	current.note.Visible = payload.saved == false
	current.button.Text = Strings.get("Results.PlayAgain")
	current.countdown.Text = ""
end

--------------------------------------------------------------------------------
-- Open / close
--------------------------------------------------------------------------------

local function selectButton()
	local current = view
	if current and showing and InputController.GetDevice() == "Gamepad" then
		GuiService.SelectedObject = current.button
	end
end

local function press()
	local current = view
	if not current or not showing or pressed then
		return
	end
	pressed = true
	current.button.Text = Strings.get("Results.Waiting")
	AudioController.PlayLocal("UiConfirm")
	xpcall(function()
		Net.Client.fire("PlayAgain", {})
	end, function(err: any)
		log.warn("PlayAgain failed: %s", tostring(err))
	end)
end

local function onConfirm(_action: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		press()
	end
	return Enum.ContextActionResult.Sink
end

local function open()
	local current = view
	if not current or showing then
		return
	end
	showing = true
	shownAt = clock
	current.backdropGui.Enabled = true
	current.gui.Enabled = true
	CursorController.RequestFree(TOKEN)
	InputController.PushContext("Menu", TOKEN)
	HUD.SetVisible(false)
	ContextActionService:BindActionAtPriority(
		CONFIRM_ACTION,
		onConfirm,
		false,
		Enum.ContextActionPriority.High.Value + 20,
		Enum.KeyCode.Return,
		Enum.KeyCode.KeypadEnter
	)
	AudioController.PlayLocal(if kind == "Escaped" then "DistantThunder" else "FarRumble")
	selectButton()
end

local function close()
	pending = nil
	if not showing then
		return
	end
	showing = false
	ContextActionService:UnbindAction(CONFIRM_ACTION)
	local current = view
	local selected = GuiService.SelectedObject
	if current and selected and selected:IsDescendantOf(current.gui) then
		GuiService.SelectedObject = nil
	end
	CursorController.Release(TOKEN)
	InputController.PopContext(TOKEN)
	HUD.SetVisible(true)
end

local function onSummary(payload: any)
	if type(payload) ~= "table" or not Enums.has(Enums.RunOutcome, payload.outcome) then
		return
	end
	local summary = payload :: Types.RunSummaryPayload
	local current = view
	if not current then
		return
	end
	if showing then
		close()
	end
	pending = summary
	receivedAt = clock
	pressed = false
	alpha = 0
	endsAtSeen = nil
	fill(current, summary)
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function animate(current: View)
	local camera = Workspace.CurrentCamera
	if camera then
		local viewport = camera.ViewportSize
		local fit = math.min(viewport.X * FIT / CONTENT_WIDTH, viewport.Y * FIT / CONTENT_HEIGHT)
		local nextScale = math.min(UIKit.scaleFor(viewport), if fit > 0 then fit else 1)
		if math.abs(current.scale.Scale - nextScale) > 1e-3 then
			current.scale.Scale = nextScale
		end
	end
	local eased = alpha * alpha * (3 - 2 * alpha)
	UIKit.setTransparency(current.backdrop, UIKit.fade(0.04, eased))
	current.vignette:SetAlpha(eased)
	current.root.GroupTransparency = 1 - eased
	current.root.Position = UDim2.new(0.5, 0, 0.5, math.floor((1 - eased) * 16))

	local t = clock - shownAt
	local reveal = MathUtil.smoothstep(0, 1, (t - TITLE_DELAY) / TITLE_REVEAL)
	current.titleScale.Scale = 1.12 - 0.12 * reveal
	local flicker = 1
	if kind == "Escaped" then
		current.title.TextColor3 = Palette.Bone
		local glow = 0.5 + 0.5 * math.sin(t * 1.3)
		UIKit.setStrokeTransparency(current.titleStroke, 0.35 + 0.3 * glow)
		local since = t - TITLE_DELAY
		local flashScale = SettingsController.GetNumber("FlashScale")
		local strength = if since >= 0 then FLASH_PEAK * math.exp(-since * FLASH_DECAY) * flashScale else 0
		UIKit.setTransparency(current.flash, 1 - math.clamp(strength, 0, 1) * eased)
	else
		local dip = math.max(0, MathUtil.noise1(t * 6, 17) - 0.35)
		flicker = 1 - math.min(0.7, dip * 1.6)
		current.title.TextColor3 = Palette.Blood:Lerp(Palette.Ember, 0.35 * flicker)
		UIKit.setStrokeTransparency(current.titleStroke, 0.55 + 0.3 * (1 - flicker))
		UIKit.setTransparency(current.flash, 1)
	end
	UIKit.setTextTransparency(current.title, 1 - reveal * flicker)

	local summary = pending
	if summary then
		local shown = EscapeSummaryController.countUp(t - CREDIT_DELAY, summary.creditsEarned)
		local text = Strings.get("Results.Credits", shown)
		if current.credits.Text ~= text then
			current.credits.Text = text
		end
	end

	local raw = ReplicatedStorage:GetAttribute(M.ResultsEndsAt)
	local endsAt = if type(raw) == "number" then raw else nil
	local serverNow = Workspace:GetServerTimeNow()
	if endsAt ~= endsAtSeen then
		endsAtSeen = endsAt
		if endsAt then
			countdownTotal = math.max(1, endsAt - serverNow)
		end
	end
	local seconds, fraction = EscapeSummaryController.countdown(serverNow, endsAt, countdownTotal)
	local countdownText = if seconds then Strings.get("Results.Returning", seconds) else ""
	if current.countdown.Text ~= countdownText then
		current.countdown.Text = countdownText
	end
	current.bar.root.Visible = seconds ~= nil
	current.bar:SetFraction(fraction)

	local selected = GuiService.SelectedObject == current.button
	local lit = (hovered or selected) and not pressed
	current.buttonStroke.Color = if lit then Palette.Amber else Palette.StrokeDim
	current.button.TextColor3 = if pressed then Palette.Ash else Palette.Bone
	current.button.BackgroundColor3 = if lit then Palette.Track else Palette.Raised
end

local function step(dt: number)
	clock += dt
	local current = view
	if not current then
		return
	end
	local phase = ReplicatedStorage:GetAttribute(M.MatchPhase)
	if pending and type(phase) == "string" and CLOSING_PHASES[phase] then
		close()
	end
	if pending and not showing then
		local player = Players.LocalPlayer
		local lock = if player then Attributes.getString(player, P.ControlLock, "None") else "None"
		if not EscapeSummaryController.holding(InputController.GetContext(), lock, clock - receivedAt) then
			open()
		end
	end
	alpha = MathUtil.approach(alpha, if showing then 1 else 0, (if showing then FADE_IN else FADE_OUT) * dt)
	local visible = alpha > 1e-3
	if current.gui.Enabled ~= visible then
		current.gui.Enabled = visible
		current.backdropGui.Enabled = visible
	end
	if visible then
		animate(current)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function EscapeSummaryController.Init()
	serviceTrove:Add(function()
		close()
		local current = view
		view = nil
		if current then
			current.gui:Destroy()
			current.backdropGui:Destroy()
		end
	end)
end

function EscapeSummaryController.Start()
	local player = Players.LocalPlayer
	if not player then
		log.warn("no local player; the run summary is not shown")
		return
	end
	local gui = player:WaitForChild("PlayerGui")
	xpcall(function()
		view = build(gui)
	end, function(err: any)
		log.error("run summary failed to build: %s\n%s", tostring(err), debug.traceback())
	end)
	local current = view
	if not current then
		return
	end
	serviceTrove:Add(current.button.Activated:Connect(press))
	serviceTrove:Add(current.button.MouseEnter:Connect(function()
		hovered = true
	end))
	serviceTrove:Add(current.button.MouseLeave:Connect(function()
		hovered = false
	end))
	serviceTrove:Add(InputController.DeviceChanged:Connect(function()
		selectButton()
	end))
	local connection = Net.Client.on("RunSummary", onSummary)
	if connection then
		serviceTrove:Add(connection)
	end
	serviceTrove:Connect(RunService.PreRender, step)
end

function EscapeSummaryController.OnRunEnded()
	close()
	alpha = 0
	local current = view
	if current then
		current.gui.Enabled = false
		current.backdropGui.Enabled = false
	end
end

return table.freeze(EscapeSummaryController)
