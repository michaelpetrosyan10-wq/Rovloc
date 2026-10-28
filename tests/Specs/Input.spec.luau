--!strict
-- Input rules: the context stack (resolveContext + push / pop by token), InputConfig's binding tables per context,
-- which bindings sink the default controls' keys, device detection, action phases (Hold / Tap, injected touch
-- presses, release on a context change) and the cursor's ref-counted free requests.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Enums = require(ReplicatedStorage.Shared.Enums)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

local Core = StarterPlayer.StarterPlayerScripts.Controllers.Core
local CursorController = require(Core.CursorController)
local InputController = require(Core.InputController)

type Expect = SpecRunner.Expect

local function inputName(input: Enum.KeyCode | Enum.UserInputType): string
	return tostring(input)
end

-- Records every phase an action fires while `body` runs.
local function record(action: Enums.InputAction, body: () -> ()): { InputController.Phase }
	local phases: { InputController.Phase } = {}
	local connection = InputController.Action(action):Connect(function(phase: InputController.Phase)
		table.insert(phases, phase)
	end)
	body()
	connection:Disconnect()
	return phases
end

return {
	["resolveContext picks the highest-priority pushed context, OnFoot when none"] = function(t: Expect)
		t.eq(InputController.resolveContext({}), "OnFoot")
		for _, context: Enums.InputContext in Enums.InputContext do
			t.eq(InputController.resolveContext({ context }), context, "alone: " .. context)
		end
		t.eq(InputController.resolveContext({ "OnFoot", "Menu" }), "Menu")
		t.eq(InputController.resolveContext({ "Menu", "OnFoot" }), "Menu", "order of pushes does not matter")
		t.eq(InputController.resolveContext({ "Vent", "Downed" }), "Downed")
		t.eq(InputController.resolveContext({ "Swim", "Struggle", "Locker" }), "Struggle")
		t.eq(InputController.resolveContext({ "Spectator" }), "Spectator", "Spectator stands alone without OnFoot")
		t.eq(InputController.resolveContext({ "Spectator", "OnFoot" }), "OnFoot")
		t.eq(InputController.resolveContext({ "Cutscene", "Menu", "Vent" }), "Menu")
	end,

	["every action has a binding and resolves live in exactly its contexts"] = function(t: Expect)
		for _, action: Enums.InputAction in Enums.InputAction do
			local binding = InputConfig.Bindings[action]
			t.truthy(binding, "binding for " .. action)
			if not binding then
				continue
			end
			t.eq(binding.action, action, "binding key matches its action")
			t.truthy(Enums.has(Enums.InputKind, binding.kind), action .. " kind")
			t.truthy(#binding.contexts > 0, action .. " is live somewhere")
			t.truthy(#binding.keyboard + #binding.gamepad > 0, action .. " has a key or button")
			for _, context: Enums.InputContext in binding.contexts do
				t.truthy(Enums.has(Enums.InputContext, context), action .. " context " .. tostring(context))
			end
			for _, context: Enums.InputContext in Enums.InputContext do
				local expected = table.find(binding.contexts, context) ~= nil
				t.eq(InputController.isLive(action, context), expected, action .. " in " .. context)
				t.eq(
					table.find(InputController.actionsFor(context), action) ~= nil,
					expected,
					action .. " listed for " .. context
				)
			end
		end
	end,

	["each context binds every key and button to at most one action"] = function(t: Expect)
		for _, context: Enums.InputContext in Enums.InputContext do
			local owners: { [string]: string } = {}
			for _, action in InputController.actionsFor(context) do
				local binding = InputConfig.Bindings[action]
				local inputs: { Enum.KeyCode | Enum.UserInputType } = table.clone(binding.keyboard)
				for _, key in binding.gamepad do
					table.insert(inputs, key)
				end
				for _, input in inputs do
					local name = inputName(input)
					t.eq(owners[name], nil, string.format("%s: %s also bound to %s", context, name, action))
					owners[name] = action
				end
			end
		end
	end,

	["the Menu action is live wherever a player can open settings, and in the menu itself"] = function(t: Expect)
		for _, context: Enums.InputContext in
			{ "Menu", "OnFoot", "Vent", "Swim", "Downed", "Spectator" } :: { Enums.InputContext }
		do
			t.truthy(InputController.isLive("Menu", context), "Menu in " .. context)
		end
		local actions = InputController.actionsFor("Menu")
		t.eq(#actions, 1, "the menu binds only Menu")
		t.eq(actions[1], "Menu")
	end,

	["bindings that claim jump or sprint keys sink them; the rest pass through"] = function(t: Expect)
		for _, action: Enums.InputAction in { "HoldBreath", "Struggle", "Ripcord", "Sprint" } :: { Enums.InputAction } do
			t.truthy(InputController.sinks(InputConfig.Bindings[action]), action .. " sinks")
		end
		for _, action: Enums.InputAction in
			{ "Interact", "Flashlight", "Crouch", "Menu", "Throw", "Kick" } :: { Enums.InputAction }
		do
			t.falsy(InputController.sinks(InputConfig.Bindings[action]), action .. " passes")
		end
	end,

	["the last input type decides the device"] = function(t: Expect)
		t.eq(InputController.deviceFor(Enum.UserInputType.Touch, "KeyboardMouse"), "Touch")
		t.eq(InputController.deviceFor(Enum.UserInputType.Gamepad1, "Touch"), "Gamepad")
		t.eq(InputController.deviceFor(Enum.UserInputType.Gamepad4, "KeyboardMouse"), "Gamepad")
		t.eq(InputController.deviceFor(Enum.UserInputType.Keyboard, "Gamepad"), "KeyboardMouse")
		t.eq(InputController.deviceFor(Enum.UserInputType.MouseMovement, "Touch"), "KeyboardMouse")
		t.eq(InputController.deviceFor(Enum.UserInputType.MouseButton1, "Gamepad"), "KeyboardMouse")
		t.eq(InputController.deviceFor(Enum.UserInputType.Focus, "Touch"), "Touch", "focus says nothing")
		t.eq(InputController.deviceFor(Enum.UserInputType.Gyro, "Gamepad"), "Gamepad", "sensors say nothing")
	end,

	["contexts push and pop by token"] = function(t: Expect)
		local seen: { Enums.InputContext } = {}
		local connection = InputController.ContextChanged:Connect(function(context: Enums.InputContext)
			table.insert(seen, context)
		end)
		t.eq(InputController.GetContext(), "OnFoot")
		InputController.PushContext("Vent", "spec.vent")
		t.eq(InputController.GetContext(), "Vent")
		InputController.PushContext("Menu", "spec.menu")
		t.eq(InputController.GetContext(), "Menu")
		InputController.PushContext("Swim", "spec.vent") -- re-pushing a token replaces its context
		t.eq(InputController.GetContext(), "Menu")
		InputController.PopContext("spec.menu")
		t.eq(InputController.GetContext(), "Swim")
		InputController.PopContext("spec.unknown")
		t.eq(InputController.GetContext(), "Swim", "popping an unknown token changes nothing")
		InputController.PopContext("spec.vent")
		t.eq(InputController.GetContext(), "OnFoot")
		connection:Disconnect()
		t.eq(table.concat(seen, ","), "Vent,Menu,Swim,OnFoot")
		t.truthy(InputController.IsBound("Crouch"), "Crouch is live on foot")
		t.falsy(InputController.IsBound("Dive"), "Dive is not live on foot")
	end,

	["injected holds begin once and end on release; taps begin per press"] = function(t: Expect)
		local phases = record("Sprint", function()
			InputController.Inject("Sprint", "Begin")
			t.truthy(InputController.IsHeld("Sprint"))
			InputController.Inject("Sprint", "Begin") -- a second press of the same hold is not a new Begin
			InputController.Inject("Sprint", "End")
			t.falsy(InputController.IsHeld("Sprint"))
			InputController.Inject("Sprint", "End") -- releasing twice is harmless
		end)
		t.eq(table.concat(phases, ","), "Begin,End")

		local taps = record("Flashlight", function()
			InputController.Inject("Flashlight", "Begin")
			InputController.Inject("Flashlight", "End")
			InputController.Inject("Flashlight", "Begin")
		end)
		t.eq(table.concat(taps, ","), "Begin,Begin", "taps fire Begin per press and never End")
		t.falsy(InputController.IsHeld("Flashlight"))

		local dive = record("Dive", function()
			InputController.Inject("Dive", "Begin")
		end)
		t.eq(#dive, 0, "an action that is not live ignores injected presses")
		t.falsy(InputController.IsHeld("Dive"))
	end,

	["a context change releases holds that stop being live"] = function(t: Expect)
		local phases = record("Sprint", function()
			InputController.Inject("Sprint", "Begin")
			InputController.PushContext("Downed", "spec.downed")
			t.falsy(InputController.IsHeld("Sprint"), "Downed has no Sprint")
			InputController.Inject("Sprint", "End")
			InputController.PopContext("spec.downed")
		end)
		t.eq(table.concat(phases, ","), "Begin,End")
		t.eq(InputController.GetContext(), "OnFoot")

		local kept = record("Flashlight", function()
			InputController.PushContext("Downed", "spec.downed")
			InputController.Inject("Flashlight", "Begin")
			InputController.PopContext("spec.downed")
		end)
		t.eq(#kept, 1, "Flashlight stays live while downed")
	end,

	["Action rejects unknown actions"] = function(t: Expect)
		t.throws(function()
			InputController.Action(("Fly" :: any) :: Enums.InputAction)
		end)
	end,

	["cursor state follows the free requests and the idle lock"] = function(t: Expect)
		local idle = CursorController.resolve(0, false)
		t.truthy(idle.free)
		t.eq(idle.behavior, Enum.MouseBehavior.Default)
		t.truthy(idle.iconEnabled)
		t.falsy(idle.modal, "no modal button without a request")

		local locked = CursorController.resolve(0, true)
		t.falsy(locked.free)
		t.eq(locked.behavior, Enum.MouseBehavior.LockCenter)
		t.falsy(locked.iconEnabled)
		t.falsy(locked.modal)

		for _, lockIdle in { true, false } do
			local requested = CursorController.resolve(2, lockIdle)
			t.truthy(requested.free)
			t.eq(requested.behavior, Enum.MouseBehavior.Default)
			t.truthy(requested.iconEnabled)
			t.truthy(requested.modal, "a request shows the modal button")
		end
	end,

	["cursor free requests are ref-counted by token"] = function(t: Expect)
		local changes: { boolean } = {}
		local connection = CursorController.FreeChanged:Connect(function(free: boolean)
			table.insert(changes, free)
		end)
		CursorController.SetLockWhenIdle(true)
		t.falsy(CursorController.IsFree())
		CursorController.RequestFree("spec.a")
		CursorController.RequestFree("spec.a")
		CursorController.RequestFree("spec.b")
		t.truthy(CursorController.IsFree())
		CursorController.Release("spec.a")
		t.truthy(CursorController.IsFree(), "b still holds it")
		CursorController.Release("spec.a")
		CursorController.Release("spec.b")
		t.falsy(CursorController.IsFree())
		CursorController.SetLockWhenIdle(false)
		t.truthy(CursorController.IsFree())
		connection:Disconnect()
		local names: { string } = {}
		for _, value in changes do
			table.insert(names, tostring(value))
		end
		t.eq(table.concat(names, ","), "false,true,false,true")
	end,
}
