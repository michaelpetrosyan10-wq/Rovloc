--!strict
-- SettingsMenu: every visible SettingsSchema entry on one quiet panel, applied live (hidden entries, the onboarding's
-- saved progress, are never drawn).
--
--   * Opened and closed by the Menu action (keyboard M, gamepad Select, the touch MENU button). Open pushes
--     the "Menu" input context (gameplay actions unbind) and frees the cursor; close restores both.
--   * One row per schema entry, labelled through Strings: numbers are sliders that snap to the schema step (drag with
--     mouse or touch; the d-pad / arrow keys step left and right on the selected row, held keys repeat), booleans are
--     switches, choices (Graphics: Max .. Potato) are a row of segments with the picked option's one-line
--     description under them (click or tap a segment; left and right step through them). Every change goes straight
--     to SettingsController.Set, which clamps, applies and saves; external changes (the saved blob arriving) move the
--     controls.
--   * Gamepad: rows and the Close button are selectable with a procedural highlight; opening selects the first row,
--     B closes.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)
local Strings = require(ReplicatedStorage.Shared.Strings)

local Core = script.Parent.Parent.Core
local AudioController = require(Core.AudioController)
local CursorController = require(Core.CursorController)
local InputController = require(Core.InputController)
local SettingsController = require(Core.SettingsController)

local UIKit = require(script.Parent.UIKit)

local log = Log.new("SettingsMenu")

local Palette = UIKit.Palette

export type Context = {
	playerGui: Instance,
	scale: () -> number,
}

export type SettingsMenu = {
	Open: (self: SettingsMenu) -> (),
	Close: (self: SettingsMenu) -> (),
	Toggle: (self: SettingsMenu) -> (),
	IsOpen: (self: SettingsMenu) -> boolean,
	Update: (self: SettingsMenu, dt: number) -> (),
	Destroy: (self: SettingsMenu) -> (),
}

type Row = {
	setting: SettingsSchema.Setting,
	button: TextButton,
	value: TextLabel?,
	slider: UIKit.Slider?,
	toggle: UIKit.Toggle?,
	choice: UIKit.Segmented?,
	info: TextLabel?,
}

local TOKEN = "SettingsMenu"
local NAV_ACTION = "Rovloc.SettingsNav"
local DISPLAY_ORDER = 60
local ROW_HEIGHT = 52
local CHOICE_ROW_HEIGHT = 86
local PANEL_MAX = Vector2.new(560, 660)
local REPEAT_DELAY = 0.35
local REPEAT_INTERVAL = 0.07
local FADE = 8

local LEFT_KEYS: { Enum.KeyCode } = { Enum.KeyCode.DPadLeft, Enum.KeyCode.Left }
local RIGHT_KEYS: { Enum.KeyCode } = { Enum.KeyCode.DPadRight, Enum.KeyCode.Right }

local SettingsMenu = {}

--------------------------------------------------------------------------------
-- Pure rules (specced)
--------------------------------------------------------------------------------

-- A number setting's slider fraction for `value`.
function SettingsMenu.fractionOf(setting: SettingsSchema.NumberSetting, value: number): number
	local span = setting.max - setting.min
	if span <= 0 then
		return 0
	end
	return math.clamp((value - setting.min) / span, 0, 1)
end

-- The value under a slider fraction, snapped to the setting's step and kept in range.
function SettingsMenu.valueAt(setting: SettingsSchema.NumberSetting, fraction: number): number
	local raw = setting.min + math.clamp(fraction, 0, 1) * (setting.max - setting.min)
	local snapped = math.round(raw / setting.step) * setting.step
	return math.clamp(snapped, setting.min, setting.max)
end

-- One step left (-1) or right (+1) from `value`.
function SettingsMenu.stepped(setting: SettingsSchema.NumberSetting, value: number, direction: number): number
	local snapped = math.round(value / setting.step) * setting.step
	return math.clamp(snapped + direction * setting.step, setting.min, setting.max)
end

-- The value readout: as many decimals as the step needs; a setting centred on zero (Brightness) signs its steps.
function SettingsMenu.format(setting: SettingsSchema.NumberSetting, value: number): string
	local step = setting.step
	if step >= 1 then
		local whole = math.round(value)
		if setting.min < 0 and whole > 0 then
			return string.format("+%d", whole)
		end
		return string.format("%d", whole)
	elseif step >= 0.1 then
		return string.format("%.1f", value)
	end
	return string.format("%.2f", value)
end

-- One step left (-1) or right (+1) through a choice's options, stopping at either end.
function SettingsMenu.choiceStepped(setting: SettingsSchema.ChoiceSetting, value: number, direction: number): number
	return math.clamp(math.round(value) + direction, 1, #setting.options)
end

-- The Strings keys of a choice's option `index`: its name and its one-line description.
function SettingsMenu.optionKeys(setting: SettingsSchema.ChoiceSetting, index: number): (string, string)
	local option = setting.options[index] or setting.options[setting.default]
	local key = setting.label .. "." .. option
	return key, key .. ".Info"
end

--------------------------------------------------------------------------------
-- Mount
--------------------------------------------------------------------------------

local function click(preset: string)
	xpcall(function()
		AudioController.PlayLocal(preset)
	end, function(err: any)
		log.warnThrottled("click", 60, "ui sound failed: %s", tostring(err))
	end)
end

function SettingsMenu.mount(ctx: Context): SettingsMenu
	local gui = UIKit.screenGui("SettingsMenu", DISPLAY_ORDER, Enum.ScreenInsets.CoreUISafeInsets)
	gui.Enabled = false

	local backdrop = UIKit.fill(gui, "Backdrop", Palette.Ink, 1)
	backdrop.Active = true
	UIKit.gradient(backdrop, 90, { { 0, 0.15 }, { 0.5, 0.35 }, { 1, 0.1 } })

	local panel = UIKit.panel(backdrop, "Panel", 0.06, 731)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.92, 0.9)
	UIKit.sizeLimit(panel, Vector2.new(280, 220), PANEL_MAX)
	local uiScale = Instance.new("UIScale")
	uiScale.Parent = panel

	local title = UIKit.label(panel, "Title", UIKit.Fonts.Title, UIKit.TextSize.Title, Palette.Bone)
	title.Text = Strings.get("Settings.Title")
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Position = UDim2.fromOffset(22, 14)
	title.Size = UDim2.new(1, -44, 0, 34)
	title.TextWrapped = false
	local rule = UIKit.fill(panel, "Rule", Palette.Blood, 0.1)
	rule.Position = UDim2.fromOffset(22, 52)
	rule.Size = UDim2.new(0, 64, 0, 2)
	UIKit.gradient(rule, 0, { { 0, 0 }, { 1, 1 } })

	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Position = UDim2.fromOffset(12, 64)
	list.Size = UDim2.new(1, -24, 1, -64 - 76)
	list.CanvasSize = UDim2.fromScale(0, 0)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.ScrollBarThickness = 3
	list.ScrollBarImageColor3 = Palette.Stroke
	list.ScrollBarImageTransparency = 0.3
	list.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	list.Selectable = false
	list.Parent = panel
	UIKit.list(list, Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	UIKit.padding(list, 10, 4)

	local highlight = UIKit.frame(nil, "Selection")
	UIKit.corner(highlight, UDim.new(0, 6))
	UIKit.stroke(highlight, Palette.Amber, 1.5, 0.15)

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(0.5, 1)
	close.Position = UDim2.new(0.5, 0, 1, -16)
	close.Size = UDim2.new(1, -44, 0, 48)
	close.BackgroundColor3 = Palette.Raised
	close.BackgroundTransparency = 0.1
	close.BorderSizePixel = 0
	close.AutoButtonColor = false
	close.FontFace = UIKit.Fonts.Strong
	close.TextSize = UIKit.TextSize.Body
	close.TextColor3 = Palette.Bone
	close.Text = Strings.get("Settings.Close")
	close.SelectionImageObject = highlight
	close.Parent = panel
	UIKit.corner(close, UDim.new(0, 6))
	UIKit.stroke(close, Palette.StrokeDim, 1, 0)

	local rows: { Row } = {}
	local rowsByKey: { [string]: Row } = {}
	local connections: { RBXScriptConnection } = {}
	local signalConnections: { Signal.Connection } = {}
	local isOpen = false
	local alpha = 0
	local heldDirection = 0
	local heldFor = 0
	local repeatAt = 0

	local handle = {} :: SettingsMenu

	------------------------------------------------------------------ rows

	local function refresh(row: Row)
		local setting = row.setting
		local value = SettingsController.Get(setting.key)
		if setting.kind == "Number" and type(value) == "number" then
			local numeric = setting :: SettingsSchema.NumberSetting
			local slider = row.slider
			if slider then
				slider:SetFraction(SettingsMenu.fractionOf(numeric, value))
			end
			local readout = row.value
			if readout then
				readout.Text = SettingsMenu.format(numeric, value)
			end
		elseif setting.kind == "Bool" and type(value) == "boolean" then
			local toggle = row.toggle
			if toggle then
				toggle:SetOn(value, not isOpen)
			end
		elseif setting.kind == "Choice" and type(value) == "number" then
			local choice = row.choice
			if choice then
				choice:SetIndex(value)
			end
			local info = row.info
			if info then
				local _, infoKey = SettingsMenu.optionKeys(setting :: SettingsSchema.ChoiceSetting, value)
				info.Text = Strings.get(infoKey)
			end
		end
	end

	local function nudge(row: Row, direction: number): boolean
		local setting = row.setting
		if setting.kind == "Choice" then
			local current = SettingsController.GetNumber(setting.key)
			local nextValue = SettingsMenu.choiceStepped(setting :: SettingsSchema.ChoiceSetting, current, direction)
			if nextValue ~= current then
				SettingsController.Set(setting.key, nextValue)
				click("UiClick")
			end
			return true
		elseif setting.kind ~= "Number" then
			return false
		end
		local numeric = setting :: SettingsSchema.NumberSetting
		local current = SettingsController.GetNumber(setting.key)
		local nextValue = SettingsMenu.stepped(numeric, current, direction)
		if nextValue ~= current then
			SettingsController.Set(setting.key, nextValue)
			click("UiClick")
		end
		return true
	end

	local function buildRow(setting: SettingsSchema.Setting, order: number): Row
		local button = Instance.new("TextButton")
		button.Name = setting.key
		button.LayoutOrder = order
		button.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		button.BackgroundColor3 = Palette.Raised
		button.BackgroundTransparency = 1
		button.BorderSizePixel = 0
		button.AutoButtonColor = false
		button.Text = ""
		button.Selectable = true
		button.SelectionImageObject = highlight
		button.Parent = list
		UIKit.corner(button, UDim.new(0, 6))

		local label = UIKit.label(button, "Label", UIKit.Fonts.Body, UIKit.TextSize.Body, Palette.Bone)
		label.Text = Strings.get(setting.label)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.TextWrapped = false
		label.Position = UDim2.fromOffset(12, 0)
		label.Size = UDim2.new(0.5, -12, 1, 0)

		local row: Row = {
			setting = setting,
			button = button,
			value = nil,
			slider = nil,
			toggle = nil,
			choice = nil,
			info = nil,
		}
		if setting.kind == "Choice" then
			-- The name on its own line, the segments under it, the picked option's description under them.
			local choiceSetting = setting :: SettingsSchema.ChoiceSetting
			button.Size = UDim2.new(1, 0, 0, CHOICE_ROW_HEIGHT)
			label.Position = UDim2.fromOffset(12, 4)
			label.Size = UDim2.new(1, -24, 0, 26)
			local names: { string } = {}
			for index in choiceSetting.options do
				local nameKey = SettingsMenu.optionKeys(choiceSetting, index)
				table.insert(names, Strings.get(nameKey))
			end
			local choice = UIKit.segmented(button, "Choice", names, function(index: number)
				if SettingsController.GetNumber(setting.key) ~= index then
					SettingsController.Set(setting.key, index)
					click("UiClick")
				end
			end)
			choice.root.Position = UDim2.fromOffset(12, 32)
			choice.root.Size = UDim2.new(1, -24, 0, 30)
			row.choice = choice
			local info = UIKit.label(button, "Info", UIKit.Fonts.Body, UIKit.TextSize.Small, Palette.Ash)
			info.TextXAlignment = Enum.TextXAlignment.Left
			info.TextTruncate = Enum.TextTruncate.AtEnd
			info.TextWrapped = false
			info.Position = UDim2.fromOffset(12, 64)
			info.Size = UDim2.new(1, -24, 0, 18)
			row.info = info
		elseif setting.kind == "Number" then
			local numeric = setting :: SettingsSchema.NumberSetting
			local holder = UIKit.frame(button, "Control")
			holder.AnchorPoint = Vector2.new(1, 0.5)
			holder.Position = UDim2.new(1, -62, 0.5, 0)
			holder.Size = UDim2.new(0.5, -74, 0, 32)
			row.slider = UIKit.slider(holder, "Slider", function(fraction: number)
				SettingsController.Set(setting.key, SettingsMenu.valueAt(numeric, fraction))
			end)
			local readout = UIKit.label(button, "Value", UIKit.Fonts.Strong, UIKit.TextSize.Small, Palette.Ash)
			readout.AnchorPoint = Vector2.new(1, 0.5)
			readout.Position = UDim2.new(1, -10, 0.5, 0)
			readout.Size = UDim2.fromOffset(46, 20)
			readout.TextXAlignment = Enum.TextXAlignment.Right
			readout.TextWrapped = false
			row.value = readout
		else
			local toggle = UIKit.toggle(button, "Switch")
			toggle.root.AnchorPoint = Vector2.new(1, 0.5)
			toggle.root.Position = UDim2.new(1, -12, 0.5, 0)
			row.toggle = toggle
			table.insert(
				connections,
				button.Activated:Connect(function()
					SettingsController.Set(setting.key, not SettingsController.GetBool(setting.key))
					click("UiClick")
				end)
			)
		end
		table.insert(
			connections,
			button.SelectionGained:Connect(function()
				button.BackgroundTransparency = 0.55
				if row.slider then
					row.slider:SetFocused(true)
				end
				if row.toggle then
					row.toggle:SetFocused(true)
				end
				if row.choice then
					row.choice:SetFocused(true)
				end
			end)
		)
		table.insert(
			connections,
			button.SelectionLost:Connect(function()
				button.BackgroundTransparency = 1
				if row.slider then
					row.slider:SetFocused(false)
				end
				if row.toggle then
					row.toggle:SetFocused(false)
				end
				if row.choice then
					row.choice:SetFocused(false)
				end
			end)
		)
		table.insert(
			connections,
			button.MouseEnter:Connect(function()
				if GuiService.SelectedObject == nil then
					button.BackgroundTransparency = 0.7
				end
			end)
		)
		table.insert(
			connections,
			button.MouseLeave:Connect(function()
				if GuiService.SelectedObject ~= button then
					button.BackgroundTransparency = 1
				end
			end)
		)
		refresh(row)
		return row
	end

	for index, setting in SettingsSchema.visible() do
		local row = buildRow(setting, index)
		table.insert(rows, row)
		rowsByKey[setting.key] = row
	end
	local first = rows[1]
	local last = rows[#rows]
	if first and last then
		last.button.NextSelectionDown = close
		close.NextSelectionUp = last.button
	end

	------------------------------------------------------------------ navigation

	local function selectedRow(): Row?
		local selected = GuiService.SelectedObject
		if not selected then
			return nil
		end
		for _, row in rows do
			if row.button == selected then
				return row
			end
		end
		return nil
	end

	local function directionOf(keyCode: Enum.KeyCode): number
		if table.find(LEFT_KEYS, keyCode) then
			return -1
		elseif table.find(RIGHT_KEYS, keyCode) then
			return 1
		end
		return 0
	end

	local function onNav(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
		if not isOpen then
			return Enum.ContextActionResult.Pass
		end
		if input.KeyCode == Enum.KeyCode.ButtonB then
			if state == Enum.UserInputState.Begin then
				handle:Close()
			end
			return Enum.ContextActionResult.Sink
		end
		local row = selectedRow()
		if not row or row.setting.kind == "Bool" then
			heldDirection = 0
			return Enum.ContextActionResult.Pass
		end
		local direction = directionOf(input.KeyCode)
		if direction == 0 then
			return Enum.ContextActionResult.Pass
		end
		if state == Enum.UserInputState.Begin then
			heldDirection = direction
			heldFor = 0
			repeatAt = REPEAT_DELAY
			nudge(row, direction)
		elseif heldDirection == direction then
			heldDirection = 0
		end
		return Enum.ContextActionResult.Sink
	end

	local function bindNav()
		ContextActionService:BindActionAtPriority(
			NAV_ACTION,
			onNav,
			false,
			InputConfig.ActionPriority + 1,
			Enum.KeyCode.DPadLeft,
			Enum.KeyCode.DPadRight,
			Enum.KeyCode.Left,
			Enum.KeyCode.Right,
			Enum.KeyCode.ButtonB
		)
	end

	------------------------------------------------------------------ open / close

	function handle.Open(_self: SettingsMenu)
		if isOpen then
			return
		end
		isOpen = true
		for _, row in rows do
			refresh(row)
		end
		gui.Enabled = true
		InputController.PushContext("Menu", TOKEN)
		CursorController.RequestFree(TOKEN)
		bindNav()
		if InputController.GetDevice() == "Gamepad" and first then
			GuiService.SelectedObject = first.button
		end
		click("UiConfirm")
	end

	function handle.Close(_self: SettingsMenu)
		if not isOpen then
			return
		end
		isOpen = false
		heldDirection = 0
		ContextActionService:UnbindAction(NAV_ACTION)
		local selected = GuiService.SelectedObject
		if selected and selected:IsDescendantOf(gui) then
			GuiService.SelectedObject = nil
		end
		InputController.PopContext(TOKEN)
		CursorController.Release(TOKEN)
		click("UiBack")
	end

	function handle.Toggle(self: SettingsMenu)
		if isOpen then
			self:Close()
		else
			self:Open()
		end
	end

	function handle.IsOpen(_self: SettingsMenu): boolean
		return isOpen
	end

	function handle.Update(_self: SettingsMenu, dt: number)
		alpha = math.clamp(alpha + (if isOpen then FADE else -FADE) * dt, 0, 1)
		if not isOpen and alpha <= 0 then
			if gui.Enabled then
				gui.Enabled = false
			end
			return
		end
		local scale = ctx.scale()
		if math.abs(uiScale.Scale - scale) > 1e-3 then
			-- The UIScale grows the panel too: size it so the scaled panel still fits the screen.
			uiScale.Scale = scale
			panel.Size = UDim2.fromScale(0.92 / scale, 0.9 / scale)
		end
		local eased = alpha * alpha * (3 - 2 * alpha)
		backdrop.BackgroundTransparency = UIKit.fade(0.3, eased)
		panel.Position = UDim2.new(0.5, 0, 0.5, math.floor((1 - eased) * 18))
		panel.Visible = eased > 0.02
		for _, row in rows do
			local toggle = row.toggle
			if toggle then
				toggle:Step(dt)
			end
		end
		if heldDirection ~= 0 then
			heldFor += dt
			if heldFor >= repeatAt then
				repeatAt += REPEAT_INTERVAL
				local row = selectedRow()
				if row then
					nudge(row, heldDirection)
				else
					heldDirection = 0
				end
			end
		end
	end

	function handle.Destroy(self: SettingsMenu)
		self:Close()
		for _, connection in connections do
			connection:Disconnect()
		end
		for _, connection in signalConnections do
			connection:Disconnect()
		end
		for _, row in rows do
			local slider = row.slider
			if slider then
				slider:Destroy()
			end
			local choice = row.choice
			if choice then
				choice:Destroy()
			end
		end
		highlight:Destroy()
		gui:Destroy()
	end

	table.insert(
		connections,
		close.Activated:Connect(function()
			handle:Close()
		end)
	)
	table.insert(
		signalConnections,
		SettingsController.Changed:Connect(function(key: string)
			local row = rowsByKey[key]
			if row then
				refresh(row)
			end
		end)
	)
	table.insert(
		signalConnections,
		InputController.Action("Menu"):Connect(function(phase)
			if phase == "Begin" then
				handle:Toggle()
			end
		end)
	)

	gui.Parent = ctx.playerGui
	return handle
end

return table.freeze(SettingsMenu)
