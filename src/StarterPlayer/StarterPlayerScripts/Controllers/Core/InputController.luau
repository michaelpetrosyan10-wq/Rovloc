--!strict
-- InputController: every gameplay action, on every device, through one context stack.
--
--   * Contexts. Systems push an Enums.InputContext under a token (a vent controller pushes "Vent", the settings menu
--     pushes "Menu") and pop it by the same token. The active context is the highest-priority pushed one, in
--     Enums.InputContext order (Menu > Cutscene > Struggle > ... > OnFoot > Spectator); with nothing pushed it is the
--     "OnFoot" baseline. Only the actions InputConfig marks live in the active context are bound.
--   * Bindings. Each live action is one ContextActionService binding (keyboard + gamepad inputs from InputConfig) at
--     InputConfig.ActionPriority, above the PlayerModule's jump. Actions that claim the keys the default controls own
--     (Space / LeftShift / gamepad A) sink them, so holding breath never also jumps; every other input passes through,
--     so ProximityPrompts still see E / X and the core UI still sees Tab. A context change unbinds what is no longer
--     live (held actions get their End) and binds what became live.
--   * Phases. Hold actions fire Begin when the first of their inputs goes down and End when the last comes up (keys,
--     gamepad buttons and injected touch presses all count). Tap, Toggle and Mash actions fire Begin on every press;
--     the consumer owns toggling and counting.
--   * Touch. MobileControls draws the buttons and feeds presses through Inject; an injected Begin only counts while
--     the action is live, an injected End always releases.
--   * Text entry. While any TextBox (the chat bar included) has focus nothing is bound and every held action is
--     released; losing window focus releases held keys too (their key-up never arrives).
--   * Device. The last input type decides the device (KeyboardMouse / Gamepad / Touch), which drives glyphs and
--     whether touch buttons show.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Enums = require(ReplicatedStorage.Shared.Enums)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)

local log = Log.new("InputController")

export type Device = "KeyboardMouse" | "Gamepad" | "Touch"
export type Phase = "Begin" | "End" -- Hold: Begin + End; Tap / Toggle / Mash: Begin per press

type Entry = { token: string, context: Enums.InputContext }

local ACTION_PREFIX = "Rovloc."
local BASELINE: Enums.InputContext = "OnFoot"

-- Inputs the default character controls own: an action bound to one of these sinks it.
local SINK_KEYS: { Enum.KeyCode } = { Enum.KeyCode.Space, Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonA }

local GAMEPAD_TYPES: { Enum.UserInputType } = {
	Enum.UserInputType.Gamepad1,
	Enum.UserInputType.Gamepad2,
	Enum.UserInputType.Gamepad3,
	Enum.UserInputType.Gamepad4,
	Enum.UserInputType.Gamepad5,
	Enum.UserInputType.Gamepad6,
	Enum.UserInputType.Gamepad7,
	Enum.UserInputType.Gamepad8,
}

local KEYBOARD_MOUSE_TYPES: { Enum.UserInputType } = {
	Enum.UserInputType.Keyboard,
	Enum.UserInputType.MouseButton1,
	Enum.UserInputType.MouseButton2,
	Enum.UserInputType.MouseButton3,
	Enum.UserInputType.MouseWheel,
	Enum.UserInputType.MouseMovement,
	Enum.UserInputType.TextInput,
}

local InputController = {}

InputController.Name = "InputController"

local contextChanged: Signal.Signal<Enums.InputContext> = Signal.new()
local deviceChanged: Signal.Signal<Device> = Signal.new()
InputController.ContextChanged = contextChanged
InputController.DeviceChanged = deviceChanged

local serviceTrove = Trove.new()

local actionSignals: { [Enums.InputAction]: Signal.Signal<Phase> } = {}
for _, action: Enums.InputAction in Enums.InputAction do
	actionSignals[action] = Signal.new()
end

local actionByName: { [string]: Enums.InputAction } = {}
for _, action: Enums.InputAction in Enums.InputAction do
	actionByName[ACTION_PREFIX .. action] = action
end

local stack: { Entry } = {}
local current: Enums.InputContext = BASELINE
local device: Device = "KeyboardMouse"
local started = false
local textFocused = false

local bound: { [Enums.InputAction]: boolean } = {}
local pressed: { [Enums.InputAction]: { [string]: boolean } } = {}
local injected: { [Enums.InputAction]: boolean } = {}

--------------------------------------------------------------------------------
-- Pure rules (specced)
--------------------------------------------------------------------------------

local function priorityOf(context: Enums.InputContext): number
	return table.find(Enums.InputContext, context) or math.huge
end

-- The active context for a set of pushed contexts: the one earliest in Enums.InputContext, else "OnFoot".
function InputController.resolveContext(pushed: { Enums.InputContext }): Enums.InputContext
	local best: Enums.InputContext? = nil
	local bestPriority = math.huge
	for _, context: Enums.InputContext in pushed do
		local priority = priorityOf(context)
		if priority < bestPriority then
			best = context
			bestPriority = priority
		end
	end
	return best or BASELINE
end

function InputController.binding(action: Enums.InputAction): InputConfig.Binding?
	return InputConfig.Bindings[action]
end

-- True when InputConfig marks `action` live in `context`.
function InputController.isLive(action: Enums.InputAction, context: Enums.InputContext): boolean
	local binding = InputConfig.Bindings[action]
	return binding ~= nil and table.find(binding.contexts, context) ~= nil
end

-- Every action live in `context`, in Enums.InputAction order.
function InputController.actionsFor(context: Enums.InputContext): { Enums.InputAction }
	local out: { Enums.InputAction } = {}
	for _, action: Enums.InputAction in Enums.InputAction do
		if InputController.isLive(action, context) then
			table.insert(out, action)
		end
	end
	return out
end

-- Whether a binding claims an input the default controls use (jump / sprint keys), so it must sink it.
function InputController.sinks(binding: InputConfig.Binding): boolean
	for _, input in binding.keyboard do
		if typeof(input) == "EnumItem" and table.find(SINK_KEYS, input :: any) ~= nil then
			return true
		end
	end
	for _, key in binding.gamepad do
		if table.find(SINK_KEYS, key) ~= nil then
			return true
		end
	end
	return false
end

-- The device an input type implies; types that say nothing about the device (focus, sensors) keep `previous`.
function InputController.deviceFor(inputType: Enum.UserInputType, previous: Device): Device
	if inputType == Enum.UserInputType.Touch then
		return "Touch"
	elseif table.find(GAMEPAD_TYPES, inputType) ~= nil then
		return "Gamepad"
	elseif table.find(KEYBOARD_MOUSE_TYPES, inputType) ~= nil then
		return "KeyboardMouse"
	end
	return previous
end

--------------------------------------------------------------------------------
-- Held state
--------------------------------------------------------------------------------

local function kindOf(action: Enums.InputAction): Enums.InputKind
	local binding = InputConfig.Bindings[action]
	return if binding then binding.kind else "Tap"
end

local function physicallyHeld(action: Enums.InputAction): boolean
	local keys = pressed[action]
	return keys ~= nil and next(keys) ~= nil
end

local function held(action: Enums.InputAction): boolean
	return physicallyHeld(action) or injected[action] == true
end

local function fire(action: Enums.InputAction, phase: Phase)
	actionSignals[action]:Fire(phase)
end

-- Drops every press of `action` (physical and injected); a held Hold action gets its End.
local function release(action: Enums.InputAction)
	local wasHeld = held(action)
	pressed[action] = nil
	injected[action] = nil
	if wasHeld and kindOf(action) == "Hold" then
		fire(action, "End")
	end
end

local function releasePhysical()
	for _, action: Enums.InputAction in Enums.InputAction do
		if physicallyHeld(action) then
			local wasHeld = held(action)
			pressed[action] = nil
			if wasHeld and not held(action) and kindOf(action) == "Hold" then
				fire(action, "End")
			end
		end
	end
end

local function inputKey(input: InputObject): string
	if input.KeyCode ~= Enum.KeyCode.None then
		return input.KeyCode.Name
	end
	return input.UserInputType.Name
end

--------------------------------------------------------------------------------
-- ContextActionService
--------------------------------------------------------------------------------

local function onAction(actionName: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	local found: Enums.InputAction? = actionByName[actionName]
	local binding = if found then InputConfig.Bindings[found] else nil
	if found == nil or binding == nil then
		return Enum.ContextActionResult.Pass
	end
	local action: Enums.InputAction = found
	local result = if InputController.sinks(binding)
		then Enum.ContextActionResult.Sink
		else Enum.ContextActionResult.Pass
	if textFocused or UserInputService:GetFocusedTextBox() ~= nil then
		return Enum.ContextActionResult.Pass
	end
	local key = inputKey(input)
	if state == Enum.UserInputState.Begin then
		local wasHeld = held(action)
		local keys = pressed[action]
		if not keys then
			keys = {}
			pressed[action] = keys
		end
		keys[key] = true
		if binding.kind ~= "Hold" or not wasHeld then
			fire(action, "Begin")
		end
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		local keys = pressed[action]
		if keys and keys[key] then
			keys[key] = nil
			if next(keys) == nil then
				pressed[action] = nil
			end
			if binding.kind == "Hold" and not held(action) then
				fire(action, "End")
			end
		end
	end
	return result
end

local function bindAction(action: Enums.InputAction, binding: InputConfig.Binding)
	local inputs: { Enum.KeyCode | Enum.UserInputType } = table.clone(binding.keyboard)
	for _, key in binding.gamepad do
		table.insert(inputs, key)
	end
	ContextActionService:BindActionAtPriority(
		ACTION_PREFIX .. action,
		onAction,
		false,
		InputConfig.ActionPriority,
		table.unpack(inputs)
	)
end

-- Brings the ContextActionService bindings in line with the active context and text focus.
local function rebind()
	for _, action: Enums.InputAction in Enums.InputAction do
		local binding = InputConfig.Bindings[action]
		local want = started and not textFocused and binding ~= nil and InputController.isLive(action, current)
		if want and not bound[action] and binding then
			bound[action] = true
			xpcall(bindAction, function(err: any)
				bound[action] = nil
				log.error("could not bind %s: %s", action, tostring(err))
			end, action, binding)
		elseif not want and bound[action] then
			bound[action] = nil
			ContextActionService:UnbindAction(ACTION_PREFIX .. action)
			if physicallyHeld(action) then
				local wasHeld = held(action)
				pressed[action] = nil
				if wasHeld and not held(action) and kindOf(action) == "Hold" then
					fire(action, "End")
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Contexts
--------------------------------------------------------------------------------

local function refreshContext()
	local contexts: { Enums.InputContext } = {}
	for _, entry in stack do
		table.insert(contexts, entry.context)
	end
	local resolved: Enums.InputContext = InputController.resolveContext(contexts)
	if resolved == current then
		return
	end
	current = resolved
	for _, action: Enums.InputAction in Enums.InputAction do
		if held(action) and not InputController.isLive(action, resolved) then
			release(action)
		end
	end
	rebind()
	contextChanged:Fire(resolved)
end

-- Pushes `context` under `token` (re-pushing a token replaces its context).
function InputController.PushContext(context: Enums.InputContext, token: string)
	if not Enums.has(Enums.InputContext, context) then
		log.warnThrottled("context" .. tostring(context), 30, "PushContext: unknown context %s", tostring(context))
		return
	end
	for index, entry in stack do
		if entry.token == token then
			table.remove(stack, index)
			break
		end
	end
	table.insert(stack, { token = token, context = context })
	refreshContext()
end

function InputController.PopContext(token: string)
	for index, entry in stack do
		if entry.token == token then
			table.remove(stack, index)
			refreshContext()
			return
		end
	end
end

function InputController.GetContext(): Enums.InputContext
	return current
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

function InputController.Action(action: Enums.InputAction): Signal.Signal<Phase>
	local signal = actionSignals[action]
	assert(signal, "unknown input action " .. tostring(action))
	return signal
end

function InputController.IsHeld(action: Enums.InputAction): boolean
	return held(action)
end

-- True when `action` is live in the active context (the bindings and touch buttons follow this).
function InputController.IsBound(action: Enums.InputAction): boolean
	return InputController.isLive(action, current)
end

-- Feeds a touch press: Begin counts only while the action is live; End always releases an injected hold.
function InputController.Inject(action: Enums.InputAction, phase: Phase)
	local binding = InputConfig.Bindings[action]
	if not binding then
		return
	end
	if phase == "Begin" then
		if textFocused or not InputController.isLive(action, current) then
			return
		end
		if binding.kind == "Hold" then
			local wasHeld = held(action)
			injected[action] = true
			if not wasHeld then
				fire(action, "Begin")
			end
		else
			fire(action, "Begin")
		end
	elseif phase == "End" then
		if binding.kind == "Hold" and injected[action] then
			injected[action] = nil
			if not held(action) then
				fire(action, "End")
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Device
--------------------------------------------------------------------------------

function InputController.GetDevice(): Device
	return device
end

local function setDevice(nextDevice: Device)
	if nextDevice == device then
		return
	end
	device = nextDevice
	deviceChanged:Fire(nextDevice)
end

local function initialDevice(): Device
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and not UserInputService.MouseEnabled then
		return "Touch"
	end
	if UserInputService.GamepadEnabled and GuiService:IsTenFootInterface() then
		return "Gamepad"
	end
	return "KeyboardMouse"
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function InputController.Init()
	device = InputController.deviceFor(UserInputService:GetLastInputType(), initialDevice())
end

function InputController.Start()
	serviceTrove:Connect(UserInputService.LastInputTypeChanged, function(inputType: Enum.UserInputType)
		setDevice(InputController.deviceFor(inputType, device))
	end)
	serviceTrove:Connect(UserInputService.TextBoxFocused, function()
		if not textFocused then
			textFocused = true
			for _, action: Enums.InputAction in Enums.InputAction do
				if held(action) then
					release(action)
				end
			end
			rebind()
		end
	end)
	serviceTrove:Connect(UserInputService.TextBoxFocusReleased, function()
		if textFocused and UserInputService:GetFocusedTextBox() == nil then
			textFocused = false
			rebind()
		end
	end)
	serviceTrove:Connect(UserInputService.WindowFocusReleased, releasePhysical)
	textFocused = UserInputService:GetFocusedTextBox() ~= nil
	started = true
	rebind()
end

return table.freeze(InputController)
