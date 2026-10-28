--!strict
-- CursorController: the only writer of UserInputService.MouseBehavior and MouseIconEnabled.
--
--   * Free requests are ref-counted by token: any open menu (settings, lobby, results) calls RequestFree(token) and
--     Release(token) when it closes. While at least one request is held the cursor is free: MouseBehavior Default,
--     the icon shown, and a Modal TextButton visible (the engine only frees a first-person mouse while a visible
--     Modal button exists; it is also what lets console and touch players use the menu).
--   * With no request held, SetLockWhenIdle decides: FirstPersonController sets it true while it drives the camera,
--     so the cursor is locked to the centre and hidden; false leaves a plain default cursor.
--   * The engine (camera scripts, the Roblox menu closing) may rewrite either property; every change is answered by
--     reasserting the wanted state, except while the Roblox menu is open (the engine owns the cursor then).

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Log = require(ReplicatedStorage.Shared.Util.Log)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)

local log = Log.new("CursorController")

export type CursorState = {
	free: boolean,
	behavior: Enum.MouseBehavior,
	iconEnabled: boolean,
	modal: boolean, -- the Modal button is shown
}

local GUI_NAME = "Cursor"
local GUI_DISPLAY_ORDER = -100

local CursorController = {}

CursorController.Name = "CursorController"

local freeChanged: Signal.Signal<boolean> = Signal.new()
CursorController.FreeChanged = freeChanged

local serviceTrove = Trove.new()
local requests: { [string]: boolean } = {}
local lockWhenIdle = false
local lastFree = true
local modalButton: TextButton? = nil
local started = false

--------------------------------------------------------------------------------
-- Pure rule (specced)
--------------------------------------------------------------------------------

-- What the cursor should be for `requestCount` held free requests and the idle-lock flag.
function CursorController.resolve(requestCount: number, lockIdle: boolean): CursorState
	local requested = requestCount > 0
	local free = requested or not lockIdle
	return {
		free = free,
		behavior = if free then Enum.MouseBehavior.Default else Enum.MouseBehavior.LockCenter,
		iconEnabled = free,
		modal = requested,
	}
end

--------------------------------------------------------------------------------
-- Apply
--------------------------------------------------------------------------------

local function requestCount(): number
	local count = 0
	for _ in requests do
		count += 1
	end
	return count
end

local function apply()
	local state = CursorController.resolve(requestCount(), lockWhenIdle)
	local button = modalButton
	if button then
		button.Visible = state.modal
	end
	if started and not GuiService.MenuIsOpen then
		if UserInputService.MouseBehavior ~= state.behavior then
			UserInputService.MouseBehavior = state.behavior
		end
		if UserInputService.MouseIconEnabled ~= state.iconEnabled then
			UserInputService.MouseIconEnabled = state.iconEnabled
		end
	end
	if state.free ~= lastFree then
		lastFree = state.free
		freeChanged:Fire(state.free)
	end
end

local function buildModal(): TextButton?
	local player = Players.LocalPlayer
	if not player then
		return nil
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.DisplayOrder = GUI_DISPLAY_ORDER
	gui.ScreenInsets = Enum.ScreenInsets.None

	local button = Instance.new("TextButton")
	button.Name = "Modal"
	button.Size = UDim2.fromOffset(1, 1)
	button.Position = UDim2.fromOffset(0, 0)
	button.BackgroundTransparency = 1
	button.Text = ""
	button.TextTransparency = 1
	button.AutoButtonColor = false
	button.Selectable = false
	button.Modal = true
	button.Visible = false
	button.Parent = gui

	gui.Parent = player:WaitForChild("PlayerGui")
	serviceTrove:Add(gui)
	return button
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Frees the cursor until Release(token). Requests are ref-counted by token (repeating a token is a no-op).
function CursorController.RequestFree(token: string)
	if requests[token] then
		return
	end
	requests[token] = true
	apply()
end

function CursorController.Release(token: string)
	if not requests[token] then
		return
	end
	requests[token] = nil
	apply()
end

function CursorController.IsFree(): boolean
	return CursorController.resolve(requestCount(), lockWhenIdle).free
end

-- FirstPersonController: true locks the cursor to the centre whenever nothing requests it free.
function CursorController.SetLockWhenIdle(locked: boolean)
	if lockWhenIdle == locked then
		return
	end
	lockWhenIdle = locked
	apply()
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function CursorController.Start()
	xpcall(function()
		modalButton = buildModal()
	end, function(err: any)
		log.error("could not build the modal cursor button: %s", tostring(err))
	end)
	started = true
	serviceTrove:Connect(UserInputService:GetPropertyChangedSignal("MouseBehavior"), apply)
	serviceTrove:Connect(UserInputService:GetPropertyChangedSignal("MouseIconEnabled"), apply)
	serviceTrove:Connect(GuiService:GetPropertyChangedSignal("MenuIsOpen"), apply)
	apply()
end

return table.freeze(CursorController)
