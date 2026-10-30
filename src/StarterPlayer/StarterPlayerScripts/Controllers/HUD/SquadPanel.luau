--!strict
-- SquadPanel: who is in the run with me and how each of them is doing. The core player list is off (HUD: Tab is the
-- Objective action), so this compact sheet carries the squad, as the browser build's co-op HUD does
-- (web/src/game/coop/ui.js).
--
--   * Rows. Every participant of the run (Player.RunOutcome is set on exactly them, from BeginRun to EndRun): me
--     first, marked "(you)", then the rest by name, each with a status word in its colour:
--       ESCAPED           RunOutcome Escaped                         Moss
--       DOWN              LifeState Downed                           Ember
--       DEAD              LifeState Dead                             Blood
--       WATCHING          LifeState Spectating                       Ash
--       IN THE LOBBY      LifeState Lobby (back in the lobby)        Ash
--       IN THE STAIRWELL  alive in the exit vestibule                Amber (AirlockController.InVestibule)
--       ALIVE             otherwise                                  Bone
--   * Where. Top-right, in the HUD's look. The objective tracker sits top-left, the toasts and the airlock banner
--     top-centre, the struggle panel bottom-centre and the prompts on world billboards, so the corner is free. On touch
--     the tracker moves into that corner (clear of the MENU / GOAL buttons): the panel then takes the corner only
--     while the tracker has faded (ObjectiveTracker.GetTrackerAlpha) and yields it as soon as the tracker comes back.
--   * When. During a run (Deploying / InRun) with two or more participants; never while solo. Hidden with the HUD
--     (cutscenes, jumpscares, results), in the Cutscene / Menu input contexts and while the onboarding screens are up.
--     A status changing, someone joining or leaving the list, or the Objective action (Tab, d-pad right, GOAL) shows
--     it fully for HOLD seconds; then it fades to a dim IDLE_ALPHA, readable at a glance without drawing the eye.
--
-- Pure (tests/Specs/SquadPanel.spec.luau): status, statusKey, statusColor, rows, signature, visible, restAlpha,
-- cornerShare.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local Controllers = script.Parent.Parent
local InputController = require(Controllers.Core.InputController)
local AirlockController = require(Controllers.Match.AirlockController)
local OnboardingController = require(Controllers.Match.OnboardingController)
local HUD = require(script.Parent)
local ObjectiveTracker = require(script.Parent.ObjectiveTracker)
local UIKit = require(script.Parent.UIKit)

local log = Log.new("SquadPanel")

local P = Attributes.Player
local M = Attributes.Match
local Palette = UIKit.Palette

export type Status = "Alive" | "Downed" | "Dead" | "Spectating" | "Lobby" | "Airlock" | "Escaped"

export type Member = {
	userId: number,
	name: string,
	lifeState: string,
	outcome: string?,
	inVestibule: boolean,
	isLocal: boolean,
}

export type Row = {
	userId: number,
	name: string,
	status: Status,
	isLocal: boolean,
}

type RowView = { frame: Frame, name: TextLabel, status: TextLabel }

type View = {
	gui: ScreenGui,
	layer: Frame,
	scale: UIScale,
	panel: CanvasGroup,
	rows: { RowView },
}

local SCREEN_ORDER = 18 -- under the objective tracker (19) and the HUD (20)
local PANEL_WIDTH = 214
local MARGIN = 14
local TOUCH_TOP = 72 -- the tracker's top on touch: the corner the two share
local ROW_HEIGHT = 18
local SCAN_SECONDS = 0.25
local HOLD = 6 -- seconds fully shown after a change or the Objective action
local FADE = 2.2 -- seconds easing down to the idle alpha after that
local IDLE_ALPHA = 0.38
local FADE_IN = 4 -- alpha per second
local FADE_OUT = 2.5
local IN_RUN: { [string]: boolean } = { InRun = true, Deploying = true }
local HIDDEN_CONTEXTS: { [string]: boolean } = { Cutscene = true, Menu = true }

local STATUS_COLORS: { [Status]: Color3 } = {
	Alive = Palette.Bone,
	Downed = Palette.Ember,
	Dead = Palette.Blood,
	Spectating = Palette.Ash,
	Lobby = Palette.Ash,
	Airlock = Palette.Amber,
	Escaped = Palette.Moss,
}

local SquadPanel = {}

SquadPanel.Name = "SquadPanel"
SquadPanel.Hold = HOLD
SquadPanel.IdleAlpha = IDLE_ALPHA

local serviceTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local view: View? = nil
local clock = 0
local scale = 1
local alpha = 0
local activeAt = -math.huge
local scannedAt = -math.huge
local lastSignature: string? = nil
local placedForTouch = false
local rows: { Row } = {}

--------------------------------------------------------------------------------
-- Pure (specs: tests/Specs/SquadPanel.spec.luau)
--------------------------------------------------------------------------------

-- A participant's status: escaped first (they are out, whatever their body does), then the life state, then alive
-- in the exit vestibule.
function SquadPanel.status(lifeState: string, outcome: string?, inVestibule: boolean): Status
	if outcome == "Escaped" then
		return "Escaped"
	elseif lifeState == "Downed" then
		return "Downed"
	elseif lifeState == "Dead" then
		return "Dead"
	elseif lifeState == "Spectating" then
		return "Spectating"
	elseif lifeState == "Lobby" then
		return "Lobby"
	elseif inVestibule then
		return "Airlock"
	end
	return "Alive"
end

function SquadPanel.statusKey(status: Status): string
	return "Squad.Status." .. status
end

function SquadPanel.statusColor(status: Status): Color3
	return STATUS_COLORS[status] or Palette.Bone
end

-- The rows for the participants in `members`: me first, then by name (then user id, so equal names keep an order).
function SquadPanel.rows(members: { Member }): { Row }
	local out: { Row } = {}
	for _, member in members do
		table.insert(out, {
			userId = member.userId,
			name = member.name,
			status = SquadPanel.status(member.lifeState, member.outcome, member.inVestibule),
			isLocal = member.isLocal,
		})
	end
	table.sort(out, function(a: Row, b: Row): boolean
		if a.isLocal ~= b.isLocal then
			return a.isLocal
		end
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.userId < b.userId
	end)
	return out
end

-- A short string that changes whenever a row appears, leaves, is renamed or changes status.
function SquadPanel.signature(list: { Row }): string
	local parts: { string } = {}
	for _, row in list do
		table.insert(parts, string.format("%d:%s:%s", row.userId, row.name, row.status))
	end
	return table.concat(parts, "|")
end

-- Whether the panel may show: a run is on, the squad has company, the HUD is up, no cutscene / menu input context
-- and no onboarding screen.
function SquadPanel.visible(inRun: boolean, count: number, hudVisible: boolean, context: string, busy: boolean): boolean
	return inRun and count >= 2 and hudVisible and not busy and not HIDDEN_CONTEXTS[context]
end

-- The panel's resting visibility `since` seconds after it was last brought up: full for HOLD, then easing down to
-- IDLE_ALPHA over FADE.
function SquadPanel.restAlpha(since: number): number
	if since <= HOLD then
		return 1
	end
	local t = MathUtil.smoothstep(0, 1, math.clamp((since - HOLD) / FADE, 0, 1))
	return 1 - (1 - IDLE_ALPHA) * t
end

-- The panel's share of its corner: all of it off touch; on touch, only while the tracker that shares the corner
-- has faded (it yields as soon as the tracker starts to show).
function SquadPanel.cornerShare(touch: boolean, trackerAlpha: number): number
	if not touch then
		return 1
	end
	return math.clamp(1 - trackerAlpha * 4, 0, 1)
end

--------------------------------------------------------------------------------
-- View
--------------------------------------------------------------------------------

local function build(parent: Instance): View
	local gui = UIKit.screenGui("Squad", SCREEN_ORDER, Enum.ScreenInsets.CoreUISafeInsets)
	local layer = UIKit.frame(gui, "Layer")
	local layerScale = Instance.new("UIScale")
	layerScale.Parent = layer

	local panel = Instance.new("CanvasGroup")
	panel.Name = "Panel"
	panel.BackgroundTransparency = 1
	panel.BorderSizePixel = 0
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -MARGIN, 0, MARGIN)
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.GroupTransparency = 1
	panel.Visible = false
	panel.Parent = layer
	local sheet = UIKit.panel(panel, "Sheet", 0.28, 5113)
	sheet.Size = UDim2.fromScale(1, 0)
	sheet.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.padding(sheet, 12, 8)
	UIKit.list(sheet, Enum.FillDirection.Vertical, 3, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top)

	local header = UIKit.label(sheet, "Header", UIKit.Fonts.Heavy, UIKit.TextSize.Caps, Palette.Amber)
	header.LayoutOrder = 0
	header.Size = UDim2.new(1, 0, 0, 16)
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.TextWrapped = false
	header.Text = Strings.get("Squad.Title")

	local rowViews: { RowView } = {}
	for index = 1, GameConfig.MaxSquad do
		local frame = UIKit.frame(sheet, "Row" .. index)
		frame.LayoutOrder = index
		frame.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		frame.Visible = false
		local name = UIKit.label(frame, "Name", UIKit.Fonts.Body, UIKit.TextSize.Small, Palette.Bone)
		name.Size = UDim2.new(0.56, -4, 1, 0)
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextWrapped = false
		name.TextTruncate = Enum.TextTruncate.AtEnd
		local status = UIKit.label(frame, "Status", UIKit.Fonts.Heavy, UIKit.TextSize.Caps, Palette.Bone)
		status.AnchorPoint = Vector2.new(1, 0)
		status.Position = UDim2.fromScale(1, 0)
		status.Size = UDim2.new(0.44, 0, 1, 0)
		status.TextXAlignment = Enum.TextXAlignment.Right
		status.TextWrapped = false
		status.TextTruncate = Enum.TextTruncate.AtEnd
		table.insert(rowViews, { frame = frame, name = name, status = status })
	end

	gui.Parent = parent
	return { gui = gui, layer = layer, scale = layerScale, panel = panel, rows = rowViews }
end

local function render(current: View)
	for index, rowView in current.rows do
		local row = rows[index]
		rowView.frame.Visible = row ~= nil
		if row then
			local name = if row.isLocal then Strings.get("Squad.You", row.name) else row.name
			if rowView.name.Text ~= name then
				rowView.name.Text = name
			end
			rowView.name.TextColor3 = if row.isLocal then Palette.Bone else Palette.Ash
			rowView.status.Text = Strings.get(SquadPanel.statusKey(row.status))
			rowView.status.TextColor3 = SquadPanel.statusColor(row.status)
		end
	end
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function gather(): { Member }
	local out: { Member } = {}
	for _, player in Players:GetPlayers() do
		local outcome = player:GetAttribute(P.RunOutcome)
		if type(outcome) ~= "string" then
			continue -- not a participant of this run
		end
		local lifeState = Attributes.getString(player, P.LifeState, "Lobby")
		table.insert(out, {
			userId = player.UserId,
			name = player.DisplayName,
			lifeState = lifeState,
			outcome = outcome,
			inVestibule = lifeState == "Alive" and AirlockController.InVestibule(player),
			isLocal = player == localPlayer,
		})
	end
	return out
end

local function step(dt: number)
	local current = view
	if not current then
		return
	end
	clock += dt
	local camera = Workspace.CurrentCamera
	local nextScale = if camera then UIKit.scaleFor(camera.ViewportSize) else 1
	if math.abs(nextScale - scale) > 1e-3 then
		scale = nextScale
		current.scale.Scale = scale
		current.layer.Size = UDim2.fromScale(1 / scale, 1 / scale)
	end

	local inRun = IN_RUN[tostring(ReplicatedStorage:GetAttribute(M.MatchPhase))] == true
	if clock - scannedAt >= SCAN_SECONDS then
		scannedAt = clock
		rows = if inRun then SquadPanel.rows(gather()) else {}
		local signature = SquadPanel.signature(rows)
		if signature ~= lastSignature then
			lastSignature = signature
			activeAt = clock
			render(current)
		end
	end

	local trackerAlpha, touch = ObjectiveTracker.GetTrackerAlpha()
	if touch ~= placedForTouch then
		placedForTouch = touch
		current.panel.Position = UDim2.new(1, -MARGIN, 0, if touch then TOUCH_TOP else MARGIN)
	end
	local shown =
		SquadPanel.visible(inRun, #rows, HUD.IsVisible(), InputController.GetContext(), OnboardingController.IsBusy())
	local target = if shown
		then SquadPanel.restAlpha(clock - activeAt) * SquadPanel.cornerShare(touch, trackerAlpha)
		else 0
	alpha = MathUtil.approach(alpha, target, dt * (if target > alpha then FADE_IN else FADE_OUT))
	current.panel.Visible = alpha > 0.001
	current.panel.GroupTransparency = 1 - alpha
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function SquadPanel.Init() end

function SquadPanel.Start()
	local player = localPlayer
	if not player then
		return
	end
	local gui = player:WaitForChild("PlayerGui")
	xpcall(function()
		view = build(gui)
	end, function(err: any)
		log.error("squad panel failed to mount: %s\n%s", tostring(err), debug.traceback())
	end)
	local current = view
	if not current then
		return
	end
	serviceTrove:Add(current.gui)
	serviceTrove:Add(InputController.Action("Objective"):Connect(function(phase: InputController.Phase)
		if phase == "Begin" then
			activeAt = clock
		end
	end))
	serviceTrove:Connect(RunService.PreRender, function(dt: number)
		xpcall(step, function(err: any)
			log.warnThrottled("step", 10, "squad panel step failed: %s\n%s", tostring(err), debug.traceback())
		end, dt)
	end)
end

function SquadPanel.OnRunStarted(_info: Types.RunInfo)
	activeAt = clock
	scannedAt = -math.huge
	lastSignature = nil
end

function SquadPanel.OnRunEnded()
	scannedAt = -math.huge
	lastSignature = nil
	table.clear(rows)
end

return table.freeze(SquadPanel)
