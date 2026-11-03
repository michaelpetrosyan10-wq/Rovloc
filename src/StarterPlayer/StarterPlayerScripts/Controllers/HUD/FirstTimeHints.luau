--!strict
-- FirstTimeHints: one short line the first time something new turns up (spec: onboarding brief §5).
--
--   * TutorialConfig.Hints, highest priority first: the airlock countdown, a downed teammate, the first bear trap, flask,
--     vent grate or locker within the hint's radius on the current level, getting into the water, a low battery with
--     the light on. Each shows once per player, ever: its hidden setting (Hint<Id>) is set the moment it shows and
--     saved with the Settings blob (guests and ephemeral data keep it for the session).
--   * The floor objective's stations and locks (TutorialConfig hints with a `spot`, right after the airlock): a station or
--     lock of the current floor (ObjectiveId on the level; the locker search: a locker-room locker with its Search prompt
--     up) whose step is still undone (ObjectiveSteps), within the hint's radius (ObjectiveConfig.Tuning.HintRadius) of
--     the eye with a clear line to it. Once ever, like every hint.
--   * The airlock hint shows while its doors count down or on the way into the vestibule, and a card ends when the floor
--     changes (it never rides into the next floor).
--   * The card: a taped strip below the crosshair with the line and the right input glyphs for the device (InputGlyphs:
--     key, button or the touch button's label), fading in, staying TutorialConfig.Timing.HintSeconds, fading out; at
--     most one at a time, HintGap quiet seconds between two.
--   * Never at a bad moment (allowed): only for an Alive player in a run, with Settings "First-time hints" on, the HUD
--     visible, no onboarding screen up, outside the Cutscene / Menu / Struggle / Locker / Trapped / Parachute input
--     contexts (a locker, a trap and the jump show their own lines), under no Cutscene /
--     Jumpscare / Drag control lock, not while the Creature is chasing this player (WallChase, VentChase, AquaticStalk
--     with TargetUserId = me) and not while the panic is above HintPanicMax. A hint that is due while held back waits
--     (it shows once the moment passes, if it is still due); a card already up fades out early when the moment turns.
--
-- Pure (tests/Specs/Onboarding.spec.luau): allowed, pick, chased, batteryLow, seenAll.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Strings = require(ReplicatedStorage.Shared.Strings)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local TutorialConfig = require(ReplicatedStorage.Shared.Config.TutorialConfig)
local Types = require(ReplicatedStorage.Shared.Types)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local ObjectiveState = require(ReplicatedStorage.Shared.Util.ObjectiveState)

local Controllers = script.Parent.Parent
local InputController = require(Controllers.Core.InputController)
local SettingsController = require(Controllers.Core.SettingsController)
local FirstPersonController = require(Controllers.FirstPerson.FirstPersonController)
local OnboardingController = require(Controllers.Match.OnboardingController)
local HUD = require(script.Parent)
local InputGlyphs = require(script.Parent.InputGlyphs)
local UIKit = require(script.Parent.UIKit)

local log = Log.new("Hints")

local P = Attributes.Player
local M = Attributes.Match
local W = Attributes.World
local C = Attributes.Creature
local Palette = UIKit.Palette
local Timing = TutorialConfig.Timing

export type HintId = TutorialConfig.HintId

export type GateState = {
	enabled: boolean, -- the ShowHints setting
	inRun: boolean, -- an Alive participant in a running match
	hudVisible: boolean,
	busy: boolean, -- an onboarding screen is up
	context: string, -- InputController context
	controlLock: string, -- Player.ControlLock
	chased: boolean,
	panic: number,
}

type Row = { frame: Frame, cap: InputGlyphs.Cap, label: TextLabel }

type View = {
	gui: ScreenGui,
	layer: Frame,
	scale: UIScale,
	card: CanvasGroup,
	text: TextLabel,
	inputs: Frame,
	rows: { Row },
}

local SCREEN_ORDER = 19
local CARD_WIDTH = 460
local SCAN_SECONDS = 0.25
local FADE_IN = 3
local FADE_OUT = 2
local QUICK_FADE_OUT = 6
local BLOCKED_CONTEXTS: { [string]: boolean } =
	{ Cutscene = true, Menu = true, Struggle = true, Locker = true, Trapped = true, Parachute = true }
local AIRLOCK_HINT_RADIUS = 22 -- the airlock hint also shows this close to an idle checkpoint
local BLOCKED_LOCKS: { [string]: boolean } = { Cutscene = true, Jumpscare = true, Drag = true }
local CHASE_STATES: { [string]: boolean } = { WallChase = true, VentChase = true, AquaticStalk = true }
local WATER_STATES: { [string]: boolean } = { Treading = true, Freestyle = true, Underwater = true }
local GRATE_SHUT: { [string]: boolean } = { Closed = true, Unscrewing = true, Locked = true }

local FirstTimeHints = {}

FirstTimeHints.Name = "FirstTimeHints"

local serviceTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local view: View? = nil
local clock = 0
local scale = 1
local alpha = 0
local showing: TutorialConfig.Hint? = nil
local shownAt = -math.huge
local endedAt = -math.huge
local scannedAt = -math.huge
local due: { [string]: boolean } = {}
local showingLevel: string? = nil

--------------------------------------------------------------------------------
-- Pure (specs: tests/Specs/Onboarding.spec.luau)
--------------------------------------------------------------------------------

-- Whether a hint may show now.
function FirstTimeHints.allowed(state: GateState): boolean
	return state.enabled
		and state.inRun
		and state.hudVisible
		and not state.busy
		and not BLOCKED_CONTEXTS[state.context]
		and not BLOCKED_LOCKS[state.controlLock]
		and not state.chased
		and state.panic <= Timing.HintPanicMax
end

-- The first hint (TutorialConfig order) that is due and not yet seen, or nil.
function FirstTimeHints.pick(dueNow: { [string]: boolean }, seen: { [string]: boolean }): TutorialConfig.Hint?
	for _, hint in TutorialConfig.Hints do
		if dueNow[hint.id] and not seen[hint.id] then
			return hint
		end
	end
	return nil
end

-- Whether the Creature is hunting this player down right now.
function FirstTimeHints.chased(monsterState: unknown, targetUserId: unknown, userId: number): boolean
	return type(monsterState) == "string" and CHASE_STATES[monsterState] == true and targetUserId == userId
end

-- Whether the battery warning is due: the light on and the battery at or under LowBatteryFraction (not empty).
function FirstTimeHints.batteryLow(fraction: number, lightOn: boolean): boolean
	return lightOn and fraction > 0 and fraction <= TutorialConfig.LowBatteryFraction
end

-- True once every hint has been seen (the scan can stop).
function FirstTimeHints.seenAll(seen: { [string]: boolean }): boolean
	for _, hint in TutorialConfig.Hints do
		if not seen[hint.id] then
			return false
		end
	end
	return true
end

--------------------------------------------------------------------------------
-- Reads
--------------------------------------------------------------------------------

local function seenTable(): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, hint in TutorialConfig.Hints do
		out[hint.id] = SettingsController.GetBool(hint.setting)
	end
	return out
end

local function onLevel(instance: Instance, level: string): boolean
	local tagged = instance:GetAttribute(W.LevelId)
	if tagged ~= nil then
		return tagged == level
	end
	local root = Instances.layoutRoot(level)
	if root and instance:IsDescendantOf(root) then
		return true
	end
	local runtime = Instances.runtimeLevel(level, false)
	return runtime ~= nil and instance:IsDescendantOf(runtime)
end

local function positionOf(instance: Instance): Vector3?
	if instance:IsA("Model") then
		return instance:GetPivot().Position
	elseif instance:IsA("BasePart") then
		return instance.Position
	end
	return nil
end

local function anyNear(tag: string, level: string, from: Vector3, radius: number, keep: (Instance) -> boolean): boolean
	for _, instance in CollectionService:GetTagged(tag) do
		local position = positionOf(instance)
		if position and (position - from).Magnitude <= radius and keep(instance) and onLevel(instance, level) then
			return true
		end
	end
	return false
end

local function radiusOf(id: HintId): number
	for _, hint in TutorialConfig.Hints do
		if hint.id == id then
			return hint.radius or 0
		end
	end
	return 0
end

local function inRun(player: Player): boolean
	local phase = ReplicatedStorage:GetAttribute(M.MatchPhase)
	return (phase == "InRun" or phase == "Deploying") and player:GetAttribute(P.LifeState) == "Alive"
end

-- The world point of an objective station or lock (its first prompt's position, else its pivot).
local function spotPoint(model: Instance): Vector3?
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("ProximityPrompt") then
			local parent = descendant.Parent
			if parent and parent:IsA("Attachment") then
				return parent.WorldPosition
			end
		end
	end
	return positionOf(model)
end

local function clearLine(from: Vector3, to: Vector3, model: Instance): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { model, Instances.cosmetic() }
	for _, other in Players:GetPlayers() do
		if other.Character then
			table.insert(exclude, other.Character)
		end
	end
	params.FilterDescendantsInstances = exclude
	return Workspace:Raycast(from, to - from, params) == nil
end

local function anyPromptUp(model: Instance): boolean
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("ProximityPrompt") and descendant.Enabled then
			return true
		end
	end
	return false
end

local function searchable(locker: Instance): boolean
	for _, descendant in locker:GetDescendants() do
		if descendant:IsA("ProximityPrompt") and descendant:GetAttribute(W.PromptKind) == "Search" then
			return descendant.Enabled
		end
	end
	return false
end

-- Whether the objective hint `hint` is due for an eye at `eye` on `level`.
local function objectiveDue(hint: TutorialConfig.Hint, level: string, eye: Vector3): boolean
	local spot = hint.spot
	if not spot or spot.level ~= level or ReplicatedStorage:GetAttribute(M.ObjectiveLevel) ~= level then
		return false
	end
	local spec = ObjectiveConfig.forLevel(level)
	local progress = ObjectiveState.decodeSteps(ReplicatedStorage:GetAttribute(M.ObjectiveSteps))
	if not spec or ObjectiveState.done(spec, progress, spot.step) then
		return false
	end
	local after = spot.after
	if after and not ObjectiveState.done(spec, progress, after) then
		return false
	end
	local radius = hint.radius or ObjectiveConfig.Tuning.HintRadius
	local tag = if spot.objectiveId == "Locker"
		then Tags.HideableLocker
		elseif spot.objectiveId == "ExitLock" or spot.objectiveId == "CrateChain" then Tags.ExitLock
		else Tags.ObjectiveStation
	for _, model in CollectionService:GetTagged(tag) do
		if not onLevel(model, level) then
			continue
		end
		if spot.objectiveId == "Locker" then
			if not searchable(model) then
				continue
			end
		elseif model:GetAttribute(W.ObjectiveId) ~= spot.objectiveId then
			continue
		elseif spot.objectiveId == "ExitLock" and not anyPromptUp(model) then
			continue -- a jammed stairwell's lock (only the run's exit lock offers its prompts)
		end
		local point = spotPoint(model)
		if point and (point - eye).Magnitude <= radius and clearLine(eye, point, model) then
			return true
		end
	end
	return false
end

local function nearCheckpoint(level: string, from: Vector3): boolean
	for _, volume in CollectionService:GetTagged(Tags.CheckpointVolume) do
		if volume:IsA("BasePart") and volume:GetAttribute(W.LevelId) == level then
			local offset = volume.Position - from
			if Vector3.new(offset.X, 0, offset.Z).Magnitude <= AIRLOCK_HINT_RADIUS and math.abs(offset.Y) < 8 then
				return true
			end
		end
	end
	return false
end

local function scanDue(player: Player, seen: { [string]: boolean })
	table.clear(due)
	if not inRun(player) then
		return
	end
	local level = ReplicatedStorage:GetAttribute(M.CurrentLevel)
	local root = Instances.characterRoot(player)
	if type(level) ~= "string" or not root then
		return
	end
	local from = root.Position
	if not seen.Airlock then
		local open = ReplicatedStorage:GetAttribute(M.ObjectiveLevel) ~= level
			or ReplicatedStorage:GetAttribute(M.ObjectiveUnlocked) == true
		for _, door in CollectionService:GetTagged(Tags.AirlockDoor) do
			if
				door:GetAttribute(W.FromLevel) == level
				and type(door:GetAttribute(W.StragglerDeadline)) == "number"
				and onLevel(door, level)
			then
				due.Airlock = true
				break
			end
		end
		-- told on the way in, once the exit is open (alone, the doors seal before a countdown hint could show)
		if not due.Airlock and open and nearCheckpoint(level, from) then
			due.Airlock = true
		end
	end
	local camera = Workspace.CurrentCamera
	local eye = if camera then camera.CFrame.Position else from
	for _, hint in TutorialConfig.Hints do
		if hint.spot and not seen[hint.id] and objectiveDue(hint, level, eye) then
			due[hint.id] = true
		end
	end
	if not seen.DownedTeammate then
		for _, other in Players:GetPlayers() do
			if other ~= player and other:GetAttribute(P.LifeState) == "Downed" then
				due.DownedTeammate = true
				break
			end
		end
	end
	if not seen.BearTrap then
		due.BearTrap = anyNear(Tags.BearTrap, level, from, radiusOf("BearTrap"), function(trap: Instance): boolean
			return trap:GetAttribute(W.Armed) ~= false
		end)
	end
	if not seen.Flask then
		due.Flask = anyNear(Tags.ChemicalItem, level, from, radiusOf("Flask"), function(flask: Instance): boolean
			local holder = flask:GetAttribute(W.HeldByUserId)
			return holder == nil or holder == 0
		end)
	end
	if not seen.VentGrate then
		due.VentGrate = anyNear(Tags.VentGrate, level, from, radiusOf("VentGrate"), function(grate: Instance): boolean
			local state = grate:GetAttribute(W.GrateState)
			return type(state) ~= "string" or GRATE_SHUT[state] == true
		end)
	end
	if not seen.Locker then
		due.Locker = anyNear(Tags.HideableLocker, level, from, radiusOf("Locker"), function(_locker: Instance): boolean
			return true
		end)
	end
	local moveState = player:GetAttribute(P.MoveState)
	due.Water = type(moveState) == "string" and WATER_STATES[moveState] == true
	if not seen.LowBattery then
		local max = Attributes.getNumber(player, P.BatteryMax, GameConfig.BatteryMax)
		local battery =
			Attributes.readMeter(player, P.Battery, P.BatteryRate, P.BatteryAt, max, Workspace:GetServerTimeNow())
		due.LowBattery =
			FirstTimeHints.batteryLow(battery / math.max(max, 1e-3), player:GetAttribute(P.FlashlightOn) == true)
	end
end

local function gate(player: Player): GateState
	local creature = Instances.creature()
	return {
		enabled = SettingsController.GetBool(TutorialConfig.HintsSetting),
		inRun = inRun(player),
		hudVisible = HUD.IsVisible(),
		busy = OnboardingController.IsBusy(),
		context = InputController.GetContext(),
		controlLock = Attributes.getString(player, P.ControlLock, "None"),
		chased = creature ~= nil and FirstTimeHints.chased(
			creature:GetAttribute(C.MonsterState),
			creature:GetAttribute(C.TargetUserId),
			player.UserId
		),
		panic = FirstPersonController.GetPanic(),
	}
end

--------------------------------------------------------------------------------
-- View
--------------------------------------------------------------------------------

local function build(parent: Instance): View
	local gui = UIKit.screenGui("FirstTimeHints", SCREEN_ORDER, Enum.ScreenInsets.CoreUISafeInsets)
	local layer = UIKit.frame(gui, "Layer")
	local layerScale = Instance.new("UIScale")
	layerScale.Parent = layer

	local card = Instance.new("CanvasGroup")
	card.Name = "Card"
	card.BackgroundTransparency = 1
	card.BorderSizePixel = 0
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.fromScale(0.5, 0.6)
	card.Size = UDim2.fromOffset(CARD_WIDTH, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.GroupTransparency = 1
	card.Visible = false
	card.Parent = layer
	local sheet = UIKit.panel(card, "Sheet", 0.18, 6203)
	sheet.Size = UDim2.fromScale(1, 0)
	sheet.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.padding(sheet, 16, 10)
	UIKit.list(sheet, Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	local tape = UIKit.fill(card, "Tape", Palette.Bone, 0.66)
	tape.AnchorPoint = Vector2.new(0.5, 0.5)
	tape.Position = UDim2.fromScale(0.5, 0)
	tape.Size = UDim2.fromOffset(64, 14)
	tape.Rotation = -4
	tape.ZIndex = 4

	local text = UIKit.label(sheet, "Text", UIKit.Fonts.Title, UIKit.TextSize.Hint - 1, Palette.Bone)
	text.LayoutOrder = 1
	text.Size = UDim2.fromScale(1, 0)
	text.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.textStroke(text, 0.4)

	local inputs = UIKit.frame(sheet, "Inputs")
	inputs.LayoutOrder = 2
	inputs.Size = UDim2.new(1, 0, 0, 30)
	UIKit.list(
		inputs,
		Enum.FillDirection.Horizontal,
		22,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	)
	local rows: { Row } = {}
	for index = 1, 2 do
		local row = UIKit.frame(inputs, "Input" .. index)
		row.LayoutOrder = index
		row.Size = UDim2.fromOffset(0, 30)
		row.AutomaticSize = Enum.AutomaticSize.X
		UIKit.list(row, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		local cap = InputGlyphs.cap(row, "Cap", 28)
		cap.root.LayoutOrder = 1
		local label = UIKit.label(row, "Label", UIKit.Fonts.Strong, UIKit.TextSize.Small, Palette.Ash)
		label.LayoutOrder = 2
		label.AutomaticSize = Enum.AutomaticSize.X
		label.Size = UDim2.fromScale(0, 1)
		label.TextWrapped = false
		table.insert(rows, { frame = row, cap = cap, label = label })
	end

	gui.Parent = parent
	return { gui = gui, layer = layer, scale = layerScale, card = card, text = text, inputs = inputs, rows = rows }
end

local function fill(current: View, hint: TutorialConfig.Hint)
	current.text.Text = if hint.id == "Airlock"
		then Strings.get(hint.text, GameConfig.StragglerSeconds)
		else Strings.get(hint.text)
	local device = InputController.GetDevice()
	for index, row in current.rows do
		local input = hint.inputs[index]
		row.frame.Visible = input ~= nil
		if input then
			row.cap:SetGlyph(InputGlyphs.forAction(input.action, device))
			row.label.Text = Strings.get(input.label)
		end
	end
	current.inputs.Visible = #hint.inputs > 0
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function step(dt: number)
	local current = view
	local player = localPlayer
	if not current or not player then
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

	local ok = FirstTimeHints.allowed(gate(player))
	local seen = seenTable()
	if clock - scannedAt >= SCAN_SECONDS then
		scannedAt = clock
		if not FirstTimeHints.seenAll(seen) then
			scanDue(player, seen)
		else
			table.clear(due)
		end
	end

	local hint = showing
	local level = ReplicatedStorage:GetAttribute(M.CurrentLevel)
	if hint then
		-- a card belongs to the floor it came up on
		if not ok or clock - shownAt >= Timing.HintSeconds or level ~= showingLevel then
			showing = nil
			endedAt = clock
		end
	elseif ok and clock - endedAt >= Timing.HintGap then
		local nextHint = FirstTimeHints.pick(due, seen)
		if nextHint then
			showing = nextHint
			showingLevel = if type(level) == "string" then level else nil
			shownAt = clock
			fill(current, nextHint)
			SettingsController.Set(nextHint.setting, true)
		end
	end

	local target = if showing then 1 else 0
	local speed = if target > alpha then FADE_IN elseif ok then FADE_OUT else QUICK_FADE_OUT
	alpha = MathUtil.approach(alpha, target, dt * speed)
	current.card.Visible = alpha > 0.001
	current.card.GroupTransparency = 1 - alpha
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function FirstTimeHints.Init() end

function FirstTimeHints.Start()
	local player = localPlayer
	if not player then
		return
	end
	local gui = player:WaitForChild("PlayerGui")
	local mounted = xpcall(function()
		view = build(gui)
	end, function(err: any)
		log.error("hints failed to mount: %s\n%s", tostring(err), debug.traceback())
	end)
	local current = view
	if not mounted or not current then
		return
	end
	serviceTrove:Add(current.gui)
	serviceTrove:Add(InputController.DeviceChanged:Connect(function()
		local now = view
		local hint = showing
		if now and hint then
			fill(now, hint)
		end
	end))
	serviceTrove:Connect(RunService.PreRender, function(dt: number)
		xpcall(step, function(err: any)
			log.warnThrottled("step", 10, "hints step failed: %s\n%s", tostring(err), debug.traceback())
		end, dt)
	end)
end

function FirstTimeHints.OnRunStarted(_info: Types.RunInfo)
	table.clear(due)
	endedAt = clock
end

function FirstTimeHints.OnRunEnded()
	showing = nil
	table.clear(due)
end

return table.freeze(FirstTimeHints)
