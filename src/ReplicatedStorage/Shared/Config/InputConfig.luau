--!strict
-- Every player action and its bindings on keyboard/mouse, gamepad and touch. InputController binds these per
-- context through ContextActionService; MobileControls draws touch buttons from the same table.
-- Space and Shift are contextual (breath, struggle, ripcord / sprint, scurry, freestyle), so the contexts that use
-- them bind above the default jump and sink the input.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)

export type TouchButton = {
	label: string, -- Strings key
	position: UDim2, -- anchor point 0.5, 0.5
	size: number, -- pixels at 1x UI scale
}

export type Binding = {
	action: Enums.InputAction,
	kind: Enums.InputKind,
	keyboard: { Enum.KeyCode | Enum.UserInputType },
	gamepad: { Enum.KeyCode },
	touch: TouchButton?,
	contexts: { Enums.InputContext }, -- contexts in which this action is live
}

local InputConfig = {}

InputConfig.Bindings = table.freeze({
	Sprint = {
		action = "Sprint",
		kind = "Hold",
		keyboard = { Enum.KeyCode.LeftShift },
		gamepad = { Enum.KeyCode.ButtonL3 },
		touch = { label = "Input.Sprint", position = UDim2.new(1, -170, 1, -230), size = 76 },
		contexts = { "OnFoot", "Vent", "Swim" },
	},
	Crouch = {
		action = "Crouch",
		kind = "Toggle",
		keyboard = { Enum.KeyCode.C, Enum.KeyCode.LeftControl },
		gamepad = { Enum.KeyCode.ButtonB },
		touch = { label = "Input.Crouch", position = UDim2.new(1, -90, 1, -150), size = 76 },
		contexts = { "OnFoot" },
	},
	Dive = {
		action = "Dive",
		kind = "Hold",
		keyboard = { Enum.KeyCode.C, Enum.KeyCode.LeftControl },
		gamepad = { Enum.KeyCode.ButtonB },
		touch = { label = "Input.Dive", position = UDim2.new(1, -90, 1, -150), size = 76 },
		contexts = { "Swim" },
	},
	Flashlight = {
		action = "Flashlight",
		kind = "Tap",
		keyboard = { Enum.KeyCode.F },
		gamepad = { Enum.KeyCode.DPadUp },
		touch = { label = "Input.Flashlight", position = UDim2.new(1, -90, 1, -310), size = 64 },
		contexts = { "OnFoot", "Vent", "Swim", "Downed", "Trapped", "Locker" },
	},
	Interact = {
		action = "Interact",
		kind = "Hold",
		keyboard = { Enum.KeyCode.E },
		gamepad = { Enum.KeyCode.ButtonX },
		touch = nil, -- ProximityPrompts render their own tappable buttons
		contexts = { "OnFoot", "Vent", "Swim", "Trapped", "Locker" },
	},
	Kick = {
		action = "Kick",
		kind = "Tap",
		keyboard = { Enum.KeyCode.R },
		gamepad = { Enum.KeyCode.ButtonY },
		touch = nil,
		contexts = { "OnFoot", "Vent" },
	},
	Throw = {
		action = "Throw",
		kind = "Tap",
		keyboard = { Enum.UserInputType.MouseButton1 },
		gamepad = { Enum.KeyCode.ButtonR2 },
		touch = { label = "Input.Throw", position = UDim2.new(1, -250, 1, -150), size = 76 },
		contexts = { "OnFoot", "Vent", "Swim" },
	},
	HoldBreath = {
		action = "HoldBreath",
		kind = "Hold",
		keyboard = { Enum.KeyCode.Space },
		gamepad = { Enum.KeyCode.ButtonA },
		touch = { label = "Input.HoldBreath", position = UDim2.new(1, -110, 1, -130), size = 110 },
		contexts = { "Locker" },
	},
	Struggle = {
		action = "Struggle",
		kind = "Mash",
		keyboard = { Enum.KeyCode.Space },
		gamepad = { Enum.KeyCode.ButtonA },
		touch = { label = "Input.Struggle", position = UDim2.new(0.5, 0, 1, -140), size = 130 },
		contexts = { "Struggle" },
	},
	Syringe = {
		action = "Syringe",
		kind = "Tap",
		keyboard = { Enum.KeyCode.G },
		gamepad = { Enum.KeyCode.DPadDown },
		touch = { label = "Input.Syringe", position = UDim2.new(1, -170, 1, -310), size = 64 },
		contexts = { "OnFoot", "Downed", "Vent", "Swim" },
	},
	Ripcord = {
		action = "Ripcord",
		kind = "Tap",
		keyboard = { Enum.KeyCode.Space },
		gamepad = { Enum.KeyCode.ButtonA },
		touch = { label = "Input.Ripcord", position = UDim2.new(0.5, 0, 1, -140), size = 130 },
		contexts = { "Parachute" },
	},
	SpectatePrev = {
		action = "SpectatePrev",
		kind = "Tap",
		keyboard = { Enum.KeyCode.Q },
		gamepad = { Enum.KeyCode.ButtonL1 },
		touch = { label = "Input.SpectatePrev", position = UDim2.new(0, 70, 0.5, 0), size = 70 },
		contexts = { "Spectator" },
	},
	SpectateNext = {
		action = "SpectateNext",
		kind = "Tap",
		keyboard = { Enum.KeyCode.E },
		gamepad = { Enum.KeyCode.ButtonR1 },
		touch = { label = "Input.SpectateNext", position = UDim2.new(1, -70, 0.5, 0), size = 70 },
		contexts = { "Spectator" },
	},
	Menu = {
		action = "Menu",
		kind = "Tap",
		keyboard = { Enum.KeyCode.M, Enum.KeyCode.Tab },
		gamepad = { Enum.KeyCode.ButtonSelect },
		touch = { label = "Input.Menu", position = UDim2.new(0, 60, 0, 60), size = 56 },
		contexts = { "Menu", "OnFoot", "Vent", "Swim", "Downed", "Trapped", "Locker", "Spectator" },
	},
} :: { [string]: Binding })

-- ContextActionService priority above the PlayerModule's default jump/move bindings.
InputConfig.ActionPriority = Enum.ContextActionPriority.High.Value + 10

return table.freeze(InputConfig)
