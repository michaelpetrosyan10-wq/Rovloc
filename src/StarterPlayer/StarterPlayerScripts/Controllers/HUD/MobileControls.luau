--!strict
-- MobileControls: the touch buttons, drawn from InputConfig and fed into InputController.Inject.
--
--   * One round button per InputConfig binding with a `touch` entry. A button shows only on a touch device, while
--     its action is live in the current input context (InputController.IsBound) and while it is relevant: the
--     syringe only with a charge left, throw only while holding a flask.
--   * Hold actions inject Begin on press and End when that finger lifts (tracked on the touch itself, so sliding
--     off the button still releases). Tap, Toggle and Mash inject Begin per press. A Toggle button shows its latched
--     state (crouch: latched with each press, confirmed by the server MoveState); the flashlight button shows
--     FlashlightOn.
--   * Layout: InputConfig positions and sizes at the HUD's touch scale, inside the core-UI safe area, for the
--     buttons live in the current context. Buttons anchored bottom-right move up together, and bottom-centre buttons
--     individually, until they clear the default jump button (read from the PlayerModule's TouchGui when present);
--     everything is kept on screen. A context change glides the buttons to their new places.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)

local Core = script.Parent.Parent.Core
local InputController = require(Core.InputController)

local UIKit = require(script.Parent.UIKit)

local P = Attributes.Player

export type Rect = { min: Vector2, max: Vector2 }

export type LayoutEntry = {
	action: string,
	position: UDim2, -- centre (anchor 0.5, 0.5)
	size: number, -- diameter at scale 1
}

export type Placement = { center: Vector2, diameter: number }

export type Relevance = {
	syringeCharges: number,
	heldItem: string,
}

export type Context = {
	root: Instance, -- full safe-area frame
	playerGui: Instance,
	scale: () -> number,
}

export type MobileControls = {
	Update: (self: MobileControls, dt: number, hudAlpha: number) -> (),
	ReservedBottom: (self: MobileControls) -> number,
	Destroy: (self: MobileControls) -> (),
}

type Button = {
	action: Enums.InputAction,
	binding: InputConfig.Binding,
	touch: InputConfig.TouchButton,
	entry: LayoutEntry,
	view: UIKit.RoundButton,
	shownCenter: Vector2?,
	shownDiameter: number,
	active: InputObject?,
	watch: RBXScriptConnection?, -- follows the active touch until it lifts
	latched: boolean,
	pressedAt: number,
	alpha: number,
	connections: { RBXScriptConnection },
}

local JUMP_MARGIN = 10
local EDGE_MARGIN = 6
local MIN_SCALE = UIKit.MinTouchTarget / 56 -- the smallest InputConfig button stays a 44 px target
local MAX_SCALE = 1.3
local FADE = 8
local GLIDE = 12 -- buttons glide to a new layout instead of jumping
local LATCH_CONFIRM = 0.6 -- seconds a local latch waits for the server MoveState before trusting it alone

-- Toggle actions and the server MoveStates that mean "latched".
local TOGGLE_STATES: { [string]: { string } } = {
	Crouch = { "Crouching" },
}

local MobileControls = {}

--------------------------------------------------------------------------------
-- Pure rules (specced)
--------------------------------------------------------------------------------

-- Whether a live action's button is worth showing right now.
function MobileControls.relevant(action: string, state: Relevance): boolean
	if action == "Syringe" then
		return state.syringeCharges > 0
	elseif action == "Throw" then
		return state.heldItem ~= "" and state.heldItem ~= "None"
	end
	return true
end

-- The touch scale for a HUD scale: never below a 44 px target for the smallest button.
function MobileControls.touchScale(hudScale: number): number
	return math.clamp(hudScale, MIN_SCALE, MAX_SCALE)
end

local function overlaps(center: Vector2, radius: number, rect: Rect): boolean
	local closest =
		Vector2.new(math.clamp(center.X, rect.min.X, rect.max.X), math.clamp(center.Y, rect.min.Y, rect.max.Y))
	return (closest - center).Magnitude < radius
end

-- How far up a circle must move to clear `rect` (0 when it already does).
local function liftToClear(center: Vector2, radius: number, rect: Rect): number
	if not overlaps(center, radius, rect) then
		return 0
	end
	return math.max(0, center.Y + radius - rect.min.Y)
end

-- Places every entry on a `screen`-sized safe area at `scale`, clearing `jump` (the jump button's rect in the same
-- space, already padded) and the screen edges.
function MobileControls.layout(
	entries: { LayoutEntry },
	screen: Vector2,
	jump: Rect?,
	scale: number
): { [string]: Placement }
	local out: { [string]: Placement } = {}
	local clusterLift = 0
	for _, entry in entries do
		local position = entry.position
		local diameter = entry.size * scale
		local center = Vector2.new(
			position.X.Scale * screen.X + position.X.Offset * scale,
			position.Y.Scale * screen.Y + position.Y.Offset * scale
		)
		out[entry.action] = { center = center, diameter = diameter }
		if jump and position.X.Scale == 1 and position.Y.Scale == 1 then
			clusterLift = math.max(clusterLift, liftToClear(center, diameter / 2, jump))
		end
	end
	for _, entry in entries do
		local placement = out[entry.action]
		local position = entry.position
		local center = placement.center
		local radius = placement.diameter / 2
		if position.X.Scale == 1 and position.Y.Scale == 1 then
			center -= Vector2.new(0, clusterLift)
		elseif jump and position.Y.Scale == 1 then
			center -= Vector2.new(0, liftToClear(center, radius, jump))
		end
		center = Vector2.new(
			math.clamp(center.X, radius + EDGE_MARGIN, math.max(radius + EDGE_MARGIN, screen.X - radius - EDGE_MARGIN)),
			math.clamp(center.Y, radius + EDGE_MARGIN, math.max(radius + EDGE_MARGIN, screen.Y - radius - EDGE_MARGIN))
		)
		placement.center = center
	end
	return out
end

-- The latched state of a toggle button after the server confirmed `moveState`, given the local latch and how long
-- ago it was pressed: the server wins once it agrees or the press is old enough.
function MobileControls.reconcileLatch(
	action: string,
	localLatch: boolean,
	moveState: string,
	sincePress: number
): boolean
	local states = TOGGLE_STATES[action]
	if not states then
		return localLatch
	end
	local serverLatch = table.find(states, moveState) ~= nil
	if serverLatch == localLatch or sincePress >= LATCH_CONFIRM then
		return serverLatch
	end
	return localLatch
end

--------------------------------------------------------------------------------
-- Mount
--------------------------------------------------------------------------------

local function jumpButton(playerGui: Instance): GuiObject?
	local touchGui = playerGui:FindFirstChild("TouchGui")
	local frame = touchGui and touchGui:FindFirstChild("TouchControlFrame")
	local jump = frame and frame:FindFirstChild("JumpButton")
	if jump and jump:IsA("GuiObject") then
		return jump
	end
	return nil
end

function MobileControls.mount(ctx: Context): MobileControls
	local player = Players.LocalPlayer
	local container = UIKit.frame(ctx.root, "MobileControls")
	container.ZIndex = 4

	local buttons: { Button } = {}
	for _, action: Enums.InputAction in Enums.InputAction do
		local binding = InputConfig.Bindings[action]
		local touch = if binding then binding.touch else nil
		if binding and touch then
			local view = UIKit.roundButton(container, action, Strings.get(touch.label), touch.size)
			view.button.Visible = false
			local name: string = action
			local button: Button = {
				action = action,
				binding = binding,
				touch = touch,
				entry = { action = name, position = touch.position, size = touch.size },
				view = view,
				shownCenter = nil,
				shownDiameter = touch.size,
				active = nil,
				watch = nil,
				latched = false,
				pressedAt = -math.huge,
				alpha = 0,
				connections = {},
			}
			table.insert(buttons, button)
		end
	end

	local clock = 0
	local lastScreen = Vector2.zero
	local lastJump: Rect? = nil
	local lastScale = 0
	local lastContext: string? = nil
	local reservedBottom = 0
	local placements: { [string]: Placement } = {}

	local function release(button: Button)
		local active = button.active
		if not active then
			return
		end
		button.active = nil
		local watch = button.watch
		if watch then
			button.watch = nil
			watch:Disconnect()
		end
		button.view:SetPressed(false)
		if button.binding.kind == "Hold" then
			InputController.Inject(button.action, "End")
		end
	end

	local function press(button: Button, input: InputObject)
		if button.active then
			return
		end
		button.active = input
		button.view:SetPressed(true)
		InputController.Inject(button.action, "Begin")
		if button.binding.kind == "Toggle" then
			button.latched = not button.latched
			button.pressedAt = clock
		end
		button.watch = input:GetPropertyChangedSignal("UserInputState"):Connect(function()
			local state = input.UserInputState
			if (state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel) and button.active == input then
				release(button)
			end
		end)
	end

	for _, button in buttons do
		table.insert(
			button.connections,
			button.view.button.InputBegan:Connect(function(input: InputObject)
				local kind = input.UserInputType
				if kind == Enum.UserInputType.Touch or kind == Enum.UserInputType.MouseButton1 then
					press(button, input)
				end
			end)
		)
	end

	local function jumpRect(): Rect?
		local jump = jumpButton(ctx.playerGui)
		if not jump or not jump.Visible then
			return nil
		end
		local origin = container.AbsolutePosition
		local min = jump.AbsolutePosition - origin - Vector2.new(JUMP_MARGIN, JUMP_MARGIN)
		local max = jump.AbsolutePosition + jump.AbsoluteSize - origin + Vector2.new(JUMP_MARGIN, JUMP_MARGIN)
		return { min = min, max = max }
	end

	local function sameRect(a: Rect?, b: Rect?): boolean
		if a == nil or b == nil then
			return a == b
		end
		return (a.min - b.min).Magnitude < 0.5 and (a.max - b.max).Magnitude < 0.5
	end

	-- Lays out the buttons live in the current context (so a big context-only button never pushes the everyday
	-- cluster around); buttons of other contexts keep their last placement while hidden.
	local function relayout(force: boolean)
		local screen = container.AbsoluteSize
		local jump = jumpRect()
		local scale = MobileControls.touchScale(ctx.scale())
		local context = InputController.GetContext()
		if
			not force
			and context == lastContext
			and (screen - lastScreen).Magnitude < 0.5
			and sameRect(jump, lastJump)
			and math.abs(scale - lastScale) < 1e-3
		then
			return
		end
		lastScreen = screen
		lastJump = jump
		lastScale = scale
		lastContext = context
		local live: { LayoutEntry } = {}
		for _, button in buttons do
			if InputController.IsBound(button.action) then
				table.insert(live, button.entry)
			end
		end
		for action, placement in MobileControls.layout(live, screen, jump, scale) do
			placements[action] = placement
		end
	end

	-- Moves a showing button toward its placement (snapping when it has just appeared).
	local function place(button: Button, dt: number, appearing: boolean)
		local placement = placements[button.action]
		if not placement then
			return
		end
		local current = button.shownCenter
		local center = if current == nil or appearing
			then placement.center
			else current:Lerp(placement.center, 1 - math.exp(-GLIDE * dt))
		local diameter = if current == nil or appearing
			then placement.diameter
			else button.shownDiameter + (placement.diameter - button.shownDiameter) * (1 - math.exp(-GLIDE * dt))
		if current == nil or (center - current).Magnitude > 0.2 or math.abs(diameter - button.shownDiameter) > 0.2 then
			button.shownCenter = center
			button.shownDiameter = diameter
			button.view.button.Position = UDim2.fromOffset(math.round(center.X), math.round(center.Y))
			button.view.button.Size = UDim2.fromOffset(math.round(diameter), math.round(diameter))
		end
	end

	local handle = {} :: MobileControls

	function handle.Update(_self: MobileControls, dt: number, hudAlpha: number)
		clock += dt
		local touchDevice = InputController.GetDevice() == "Touch"
		container.Visible = touchDevice
		if not touchDevice then
			for _, button in buttons do
				release(button)
				button.alpha = 0
				button.view.button.Visible = false
			end
			reservedBottom = 0
			return
		end
		relayout(false)
		local relevance: Relevance = {
			syringeCharges = if player then Attributes.getNumber(player, P.SyringeCharges, 0) else 0,
			heldItem = if player then Attributes.getString(player, P.HeldItem, "None") else "None",
		}
		local moveState = if player then Attributes.getString(player, P.MoveState, "Standing") else "Standing"
		local flashlightOn = if player then Attributes.getBool(player, P.FlashlightOn, false) else false
		local reserved = 0
		for _, button in buttons do
			local live = hudAlpha > 0.01
				and InputController.IsBound(button.action)
				and MobileControls.relevant(button.action, relevance)
			if not live then
				release(button)
			end
			local appearing = button.alpha <= 0
			button.alpha = math.clamp(button.alpha + (if live then FADE else -FADE) * dt, 0, 1)
			local shown = button.alpha > 0
			button.view.button.Visible = shown
			if not shown then
				continue
			end
			place(button, dt, appearing)
			if button.binding.kind == "Toggle" then
				button.latched =
					MobileControls.reconcileLatch(button.action, button.latched, moveState, clock - button.pressedAt)
				button.view:SetLatched(button.latched)
			elseif button.action == "Flashlight" then
				button.view:SetLatched(flashlightOn)
			end
			button.view:SetAlpha(button.alpha * hudAlpha)
			button.view:Step(dt)
			local placement = placements[button.action]
			if placement and button.touch.position.X.Scale == 0.5 then
				local top = placement.center.Y - placement.diameter / 2
				reserved = math.max(reserved, (lastScreen.Y - top) * button.alpha)
			end
		end
		reservedBottom = reserved
	end

	-- Height (px, from the bottom of the safe area) the showing bottom-centre buttons occupy; the HUD's centre
	-- column (hints, captions) stays above it.
	function handle.ReservedBottom(_self: MobileControls): number
		return reservedBottom
	end

	function handle.Destroy(_self: MobileControls)
		for _, button in buttons do
			release(button)
			for _, connection in button.connections do
				connection:Disconnect()
			end
		end
		container:Destroy()
	end

	relayout(true)
	return handle
end

return table.freeze(MobileControls)
