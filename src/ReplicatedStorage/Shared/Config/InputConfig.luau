--!strict
-- Every player action and its bindings on keyboard/mouse, gamepad and touch. InputController binds these per
-- context through ContextActionService; MobileControls draws touch buttons from the same table.
-- Space and Shift are contextual (breath, ripcord, pull up / sprint, scurry), so the contexts that use
-- them bind above the default jump and sink the input.
--
-- Spec v2's controls (docs/design/game-spec-v2.md 3.1, 2.3, 4.6, 4.9): Radar (Tab, d-pad right, RADAR: it was the
-- Objective action), LookBack (hold V, R3, LOOK BACK), Skip (hold Enter, gamepad Y, SKIP: never Space or B), the
-- revolver's Fire (LMB, RT, FIRE) and LowerGun (G, d-pad down, LOWER), and the plane's Steer (A / D or the arrows, the
-- left stick, the two pads) and PullUp (hold Space or S, A, PULL UP). Steer is an axis: `axis` names the keys of each
-- way and its two touch pads. exportMeta gives the website the same table by key and button names.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)

export type TouchButton = {
	label: string, -- Strings key
	position: UDim2, -- anchor point 0.5, 0.5
	size: number, -- pixels at 1x UI scale
}

-- A two-way action (Steer): the keys that push it to -1 and to +1, the stick whose X drives it, and its two touch pads
-- (the negative one first).
export type Axis = {
	negative: { Enum.KeyCode },
	positive: { Enum.KeyCode },
	stick: Enum.KeyCode,
	pads: { TouchButton },
}

export type Binding = {
	action: Enums.InputAction,
	kind: Enums.InputKind,
	keyboard: { Enum.KeyCode | Enum.UserInputType },
	gamepad: { Enum.KeyCode },
	touch: TouchButton?,
	contexts: { Enums.InputContext }, -- contexts in which this action is live
	axis: Axis?,
}

local InputConfig = {}

InputConfig.Bindings = table.freeze({
	Sprint = {
		action = "Sprint",
		kind = "Hold",
		keyboard = { Enum.KeyCode.LeftShift },
		gamepad = { Enum.KeyCode.ButtonL3 },
		touch = { label = "Input.Sprint", position = UDim2.new(1, -170, 1, -230), size = 76 },
		contexts = { "OnFoot", "Vent", "Revolver" },
	},
	Crouch = {
		action = "Crouch",
		kind = "Toggle",
		keyboard = { Enum.KeyCode.C, Enum.KeyCode.LeftControl },
		gamepad = { Enum.KeyCode.ButtonB },
		touch = { label = "Input.Crouch", position = UDim2.new(1, -90, 1, -150), size = 76 },
		contexts = { "OnFoot", "Revolver" },
	},
	Flashlight = {
		action = "Flashlight",
		kind = "Tap",
		keyboard = { Enum.KeyCode.F },
		gamepad = { Enum.KeyCode.DPadUp },
		touch = { label = "Input.Flashlight", position = UDim2.new(1, -90, 1, -310), size = 64 },
		contexts = { "OnFoot", "Vent", "Downed", "Trapped", "Locker", "Revolver" },
	},
	Interact = {
		action = "Interact",
		kind = "Hold",
		keyboard = { Enum.KeyCode.E },
		gamepad = { Enum.KeyCode.ButtonX },
		touch = nil, -- ProximityPrompts render their own tappable buttons
		contexts = { "OnFoot", "Vent", "Trapped", "Locker", "Revolver" },
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
		kind = "Hold", -- press: wind up and aim; release: throw (ChemicalThrowController)
		keyboard = { Enum.UserInputType.MouseButton1 },
		gamepad = { Enum.KeyCode.ButtonR2 },
		touch = { label = "Input.Throw", position = UDim2.new(1, -250, 1, -150), size = 76 },
		contexts = { "OnFoot", "Vent" },
	},
	HoldBreath = {
		action = "HoldBreath",
		kind = "Hold",
		keyboard = { Enum.KeyCode.Space },
		gamepad = { Enum.KeyCode.ButtonA },
		touch = { label = "Input.HoldBreath", position = UDim2.new(1, -110, 1, -130), size = 110 },
		contexts = { "Locker" },
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
		keyboard = { Enum.KeyCode.M },
		gamepad = { Enum.KeyCode.ButtonSelect },
		touch = { label = "Input.Menu", position = UDim2.new(0, 60, 0, 60), size = 56 },
		contexts = {
			"Menu",
			"OnFoot",
			"Vent",
			"Downed",
			"Trapped",
			"Locker",
			"Spectator",
			"Revolver",
			"Cockpit",
			"Seat",
		},
	},
	-- A radar scan (RadarRules; with no charge, the objective sheet: ObjectiveTracker). Tab on the keyboard, d-pad
	-- right on a gamepad (Select stays the menu: Start belongs to the Roblox menu), a small button under MENU.
	Radar = {
		action = "Radar",
		kind = "Tap",
		keyboard = { Enum.KeyCode.Tab },
		gamepad = { Enum.KeyCode.DPadRight },
		touch = { label = "Input.Radar", position = UDim2.new(0, 60, 0, 124), size = 56 },
		contexts = { "OnFoot", "Vent" },
	},
	-- Hold to look back (on foot, and from a plane seat): the view turns 150 degrees in 0.18 s (ParkourConfig.LookBack);
	-- movement keeps its heading.
	LookBack = {
		action = "LookBack",
		kind = "Hold",
		keyboard = { Enum.KeyCode.V },
		gamepad = { Enum.KeyCode.ButtonR3 },
		touch = { label = "Input.LookBack", position = UDim2.new(1, -170, 1, -310), size = 64 },
		contexts = { "OnFoot", "Cockpit", "Seat" },
	},
	-- The cutscene skip vote: hold 1.0 s. Never Space or B (pressed in panic); Start belongs to the Roblox menu, so the
	-- gamepad votes with Y.
	Skip = {
		action = "Skip",
		kind = "Hold",
		keyboard = { Enum.KeyCode.Return },
		gamepad = { Enum.KeyCode.ButtonY },
		touch = { label = "Input.Skip", position = UDim2.new(1, -90, 0, 60), size = 76 },
		contexts = { "Cutscene" },
	},
	-- The revolver (holding it replaces Throw and the jump): fire on press; the FIRE button fires on press and on a
	-- release inside it.
	Fire = {
		action = "Fire",
		kind = "Tap",
		keyboard = { Enum.UserInputType.MouseButton1 },
		gamepad = { Enum.KeyCode.ButtonR2 },
		touch = { label = "Input.Fire", position = UDim2.new(1, -110, 1, -170), size = 120 },
		contexts = { "Revolver" },
	},
	-- Hold 1.5 s to lower the gun (the choice not to shoot); a tap under 0.3 s drops it.
	LowerGun = {
		action = "LowerGun",
		kind = "Hold",
		keyboard = { Enum.KeyCode.G },
		gamepad = { Enum.KeyCode.DPadDown },
		touch = { label = "Input.LowerGun", position = UDim2.new(0, 90, 1, -260), size = 76 },
		contexts = { "Revolver" },
	},
	-- The pilot steers the plane: A / D or the arrows, the left stick, the two pads bottom left.
	Steer = {
		action = "Steer",
		kind = "Hold",
		keyboard = { Enum.KeyCode.A, Enum.KeyCode.D, Enum.KeyCode.Left, Enum.KeyCode.Right },
		gamepad = { Enum.KeyCode.Thumbstick1 },
		touch = nil, -- the two pads of `axis`
		contexts = { "Cockpit" },
		axis = {
			negative = { Enum.KeyCode.A, Enum.KeyCode.Left },
			positive = { Enum.KeyCode.D, Enum.KeyCode.Right },
			stick = Enum.KeyCode.Thumbstick1,
			pads = {
				{ label = "Input.SteerLeft", position = UDim2.new(0, 80, 1, -90), size = 110 },
				{ label = "Input.SteerRight", position = UDim2.new(0, 200, 1, -90), size = 110 },
			},
		},
	},
	-- Hold to pull up: from 60 studs/s, 1.0 s of it lifts off (TakeoffRules).
	PullUp = {
		action = "PullUp",
		kind = "Hold",
		keyboard = { Enum.KeyCode.Space, Enum.KeyCode.S },
		gamepad = { Enum.KeyCode.ButtonA },
		touch = { label = "Input.PullUp", position = UDim2.new(1, -100, 1, -100), size = 130 },
		contexts = { "Cockpit" },
	},
} :: { [string]: Binding })

-- ContextActionService priority above the PlayerModule's default jump/move bindings.
InputConfig.ActionPriority = Enum.ContextActionPriority.High.Value + 10

local function names(list: { Enum.KeyCode | Enum.UserInputType }): { string }
	local out: { string } = {}
	for _, input in list do
		table.insert(out, input.Name)
	end
	return out
end

local function button(touch: TouchButton): { [string]: any }
	local p = touch.position
	return {
		label = touch.label,
		position = { p.X.Scale, p.X.Offset, p.Y.Scale, p.Y.Offset },
		size = touch.size,
	}
end

-- The bindings as plain data for the website (world.json meta.inputConfig): per action its kind, key and button names
-- (Enum.KeyCode / Enum.UserInputType names), touch button (position as scale x, offset x, scale y, offset y), contexts
-- and axis.
function InputConfig.exportMeta(): { [string]: any }
	local bindings: { [string]: any } = {}
	for action, binding in InputConfig.Bindings do
		local touch = binding.touch
		local axis = binding.axis
		local pads: { any } = {}
		if axis then
			for _, pad in axis.pads do
				table.insert(pads, button(pad))
			end
		end
		bindings[action] = {
			kind = binding.kind,
			keyboard = names(binding.keyboard),
			gamepad = names(binding.gamepad),
			touch = if touch then button(touch) else nil,
			contexts = table.clone(binding.contexts),
			axis = if axis
				then {
					negative = names(axis.negative),
					positive = names(axis.positive),
					stick = axis.stick.Name,
					pads = pads,
				}
				else nil,
		}
	end
	return { bindings = bindings }
end

return table.freeze(InputConfig)
