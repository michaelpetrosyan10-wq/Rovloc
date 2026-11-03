--!strict
-- AirlockController: the stairwell checkpoint banner (spec §6). CheckpointAirlockService (server) runs the airlock;
-- this client only reads what it replicates on the current level's exit fire door(s): the AirlockDoor models on
-- ReplicatedStorage.CurrentLevel whose FromLevel is that level.
--   StragglerDeadline set, the door not Locked   Waiting: a countdown to the deadline (server time, extrapolated every
--                                                frame) and a draining bar: "Waiting for the squad — 0:14" while this
--                                                player is inside the exit vestibule's Checkpoint volume (or has no
--                                                body: spectators wait with the squad), "Get to the stairwell! 0:14"
--                                                in red outside it, pulsing through the last URGENT_SECONDS;
--   StragglerDeadline set, the door Locked       Sealing: "Sealing…";
--   no StragglerDeadline                         nothing (Idle, or Sealed: the server clears the deadline once the
--                                                floor has changed).
-- The banner is a dark panel top-centre in the HUD's UIKit look (Strings keys), on its own screen above the HUD; it
-- fades in and out, and hides while the HUD is hidden (cutscenes), in the Cutscene input context, or under a
-- Cutscene / Jumpscare control lock.
--
-- Pure (tests/Specs/Airlock.spec.luau): bannerState, bannerText, remainingFraction, urgent, visible, exitRoom.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Controllers = script.Parent.Parent
local InputController = require(Controllers.Core.InputController)
local HUD = require(Controllers.HUD)
local UIKit = require(Controllers.HUD.UIKit)

local log = Log.new("AirlockClient")

local P = Attributes.Player
local M = Attributes.Match
local W = Attributes.World
local Palette = UIKit.Palette

export type BannerState = "Hidden" | "Waiting" | "Sealing"

type View = {
	gui: ScreenGui,
	scale: UIScale,
	banner: CanvasGroup,
	label: TextLabel,
	bar: UIKit.MeterBar,
}

local SCREEN_ORDER = 22 -- just above the HUD (20)
local BANNER_WIDTH = 460
local BANNER_TOP = 0.13 -- of the safe area's height: below the toast column
local TEXT_SIZE = 22
local BAR_HEIGHT = 4
local FADE_IN = 4 -- alpha per second
local FADE_OUT = 2.5
local URGENT_SECONDS = 5
local PULSE_HZ = 2
local RESCAN_SECONDS = 0.5 -- the exit doors and volumes are looked up again this often
local WAITING_KEY = "Airlock.Waiting"
local OUTSIDE_KEY = "Airlock.GetIn"
local SEALING_KEY = "Airlock.Sealing"
local SEALED_STATE: Enums.DoorState = "Locked"
local HIDING_LOCKS: { [string]: boolean } = { Cutscene = true, Jumpscare = true }

local AirlockController = {}

AirlockController.Name = "AirlockController"
AirlockController.UrgentSeconds = URGENT_SECONDS

local serviceTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local view: View? = nil
local alpha = 0
local clock = 0

local scannedAt = -math.huge
local scannedLevel: string? = nil
local exitDoors: { Model } = {}
local volumes: { BasePart } = {}

--------------------------------------------------------------------------------
-- Pure (specs: tests/Specs/Airlock.spec.luau)
--------------------------------------------------------------------------------

-- The exit vestibule of `level` on `route` (from-level -> stairwell id; nil: the middle stairwells): the lower-level
-- room of the stairwell the route leaves it by (nil on the roof).
function AirlockController.exitRoom(level: string, route: { [string]: string }?): string?
	local stairwell = WorldConfig.routeExit(route, level)
	return if stairwell then stairwell.fromRoom else nil
end

-- The run's route as far as this client can see it: the stairwell of every built fire door of `level` that is not
-- jammed (DoorBuilder.setJammed), keyed by its FromLevel. Empty before the doors replicate (then the middle ones).
function AirlockController.visibleRoute(level: string?): { [string]: string }
	local route: { [string]: string } = {}
	for _, instance in CollectionService:GetTagged(Tags.AirlockDoor) do
		local from = instance:GetAttribute(W.FromLevel)
		local stairwell = instance:GetAttribute(W.StairwellId)
		if
			(level == nil or instance:GetAttribute(W.LevelId) == level)
			and type(from) == "string"
			and type(stairwell) == "string"
			and instance:GetAttribute(W.Jammed) ~= true
		then
			route[from] = stairwell
		end
	end
	return route
end

-- The stairwell this client sees the run leave `level` by (the middle one until the doors replicate; nil on the roof).
function AirlockController.exitStairwell(level: string): WorldConfig.StairwellSpec?
	return WorldConfig.routeExit(AirlockController.visibleRoute(level), level)
end

-- What the banner shows for an exit door's StragglerDeadline (nil when unset) and whether the door is sealing.
function AirlockController.bannerState(deadline: number?, sealing: boolean): BannerState
	if deadline == nil or not MathUtil.isFinite(deadline) then
		return "Hidden"
	end
	return if sealing then "Sealing" else "Waiting"
end

-- The banner's line: the squad countdown inside, the call to hurry outside, "Sealing…" once the doors close.
function AirlockController.bannerText(state: BannerState, inside: boolean, remaining: number): string
	if state == "Sealing" then
		return Strings.get(SEALING_KEY)
	elseif state == "Waiting" then
		local time = Strings.formatTime(math.ceil(math.max(0, remaining)))
		return Strings.get(if inside then WAITING_KEY else OUTSIDE_KEY, time)
	end
	return ""
end

-- How much of the straggler timer is left (1 just started .. 0 at the deadline).
function AirlockController.remainingFraction(remaining: number): number
	return math.clamp(remaining / math.max(GameConfig.StragglerSeconds, 1e-3), 0, 1)
end

-- Whether the line pulses red: waiting, outside, in the last URGENT_SECONDS.
function AirlockController.urgent(state: BannerState, inside: boolean, remaining: number): boolean
	return state == "Waiting" and not inside and remaining <= URGENT_SECONDS
end

-- Whether the banner may show at all (hidden in cutscenes: HUD hidden, Cutscene context, Cutscene / Jumpscare lock).
function AirlockController.visible(hudVisible: boolean, context: string, controlLock: string): boolean
	return hudVisible and context ~= "Cutscene" and not HIDING_LOCKS[controlLock]
end

--------------------------------------------------------------------------------
-- World
--------------------------------------------------------------------------------

local function rescan(level: string?)
	scannedAt = clock
	scannedLevel = level
	table.clear(exitDoors)
	table.clear(volumes)
	if level == nil then
		return
	end
	local exit = AirlockController.exitStairwell(level)
	for _, instance in CollectionService:GetTagged(Tags.AirlockDoor) do
		local stairwell = instance:GetAttribute(W.StairwellId)
		if
			instance:IsA("Model")
			and instance:GetAttribute(W.LevelId) == level
			and instance:GetAttribute(W.FromLevel) == level
			and (stairwell == nil or exit == nil or stairwell == exit.id)
		then
			table.insert(exitDoors, instance)
		end
	end
	local room = if exit then exit.fromRoom else nil
	local any: { BasePart } = {}
	for _, instance in CollectionService:GetTagged(Tags.CheckpointVolume) do
		if instance:IsA("BasePart") and instance:GetAttribute(W.LevelId) == level then
			table.insert(any, instance)
			if instance:GetAttribute(W.ZoneId) == room then
				table.insert(volumes, instance)
			end
		end
	end
	if #volumes == 0 then
		for _, volume in any do
			table.insert(volumes, volume)
		end
	end
end

-- The deadline on the exit door(s) (they share it) and whether any of them is sealing.
local function readDoors(): (number?, boolean)
	local deadline: number? = nil
	local sealing = false
	for _, door in exitDoors do
		if door.Parent == nil then
			continue
		end
		local value = door:GetAttribute(W.StragglerDeadline)
		if type(value) == "number" then
			deadline = if deadline then math.min(deadline, value) else value
			if door:GetAttribute(W.DoorState) == SEALED_STATE then
				sealing = true
			end
		end
	end
	return deadline, sealing
end

-- Whether `player`'s living body stands in the current level's exit vestibule (nil: no body to place).
local function bodyInside(player: Player): boolean?
	local root = Instances.characterRoot(player)
	local humanoid = Instances.characterHumanoid(player)
	if not root or not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local position = root.CFrame.Position
	local feet = position - Vector3.new(0, humanoid.HipHeight + root.Size.Y * 0.5, 0)
	for _, volume in volumes do
		if volume.Parent and (SpatialQuery.pointInPart(volume, position) or SpatialQuery.pointInPart(volume, feet)) then
			return true
		end
	end
	return false
end

-- Inside the vestibule's volume; a player without a body (spectating) waits with the squad.
local function localInside(): boolean
	local player = localPlayer
	if not player then
		return true
	end
	local inside = bodyInside(player)
	return inside == nil or inside
end

--------------------------------------------------------------------------------
-- View
--------------------------------------------------------------------------------

local function build(parent: Instance): View
	local gui = UIKit.screenGui("Airlock", SCREEN_ORDER, Enum.ScreenInsets.CoreUISafeInsets)
	local layer = UIKit.frame(gui, "Layer")
	local scale = Instance.new("UIScale")
	scale.Parent = layer

	local banner = Instance.new("CanvasGroup")
	banner.Name = "Banner"
	banner.BackgroundTransparency = 1
	banner.BorderSizePixel = 0
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.fromScale(0.5, BANNER_TOP)
	banner.Size = UDim2.fromOffset(BANNER_WIDTH, 0)
	banner.AutomaticSize = Enum.AutomaticSize.Y
	banner.GroupTransparency = 1
	banner.Visible = false
	banner.Parent = layer

	local panel = UIKit.panel(banner, "Panel", 0.18, 6611)
	panel.Size = UDim2.fromScale(1, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.padding(panel, 20, 12)
	UIKit.list(panel, Enum.FillDirection.Vertical, 9, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)

	local label = UIKit.label(panel, "Text", UIKit.Fonts.Title, TEXT_SIZE, Palette.Bone)
	label.LayoutOrder = 1
	label.Size = UDim2.fromScale(1, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.textStroke(label, 0.35)

	local bar = UIKit.meterBar(panel, "Timer", Palette.Amber, BAR_HEIGHT)
	bar.root.LayoutOrder = 2

	gui.Parent = parent
	return { gui = gui, scale = scale, banner = banner, label = label, bar = bar }
end

local function step(dt: number)
	clock += dt
	local current = view
	if not current then
		return
	end
	local camera = Workspace.CurrentCamera
	if camera then
		local nextScale = UIKit.scaleFor(camera.ViewportSize)
		if math.abs(current.scale.Scale - nextScale) > 1e-3 then
			current.scale.Scale = nextScale
			-- The UIScale grows the layer from its top-left corner: size it so the scaled layer still fills the screen
			-- (as the HUD's layer does), or the panel drifts off centre on screens that aren't about 720 px tall.
			local layer = current.scale.Parent
			if layer and layer:IsA("GuiObject") then
				layer.Size = UDim2.fromScale(1 / nextScale, 1 / nextScale)
			end
		end
	end

	local raw = ReplicatedStorage:GetAttribute(M.CurrentLevel)
	local level = if type(raw) == "string" then raw else nil
	if level ~= scannedLevel or clock - scannedAt >= RESCAN_SECONDS then
		rescan(level)
	end
	local deadline, sealing = readDoors()
	local state: BannerState = AirlockController.bannerState(deadline, sealing)
	local player = localPlayer
	local lock = if player then Attributes.getString(player, P.ControlLock, "None") else "None"
	local shown = state ~= "Hidden" and AirlockController.visible(HUD.IsVisible(), InputController.GetContext(), lock)

	local target = if shown then 1 else 0
	alpha = MathUtil.approach(alpha, target, (if shown then FADE_IN else FADE_OUT) * dt)
	local banner = current.banner
	local showing = alpha > 1e-3
	if banner.Visible ~= showing then
		banner.Visible = showing
	end
	if math.abs(banner.GroupTransparency - (1 - alpha)) > 1e-3 then
		banner.GroupTransparency = 1 - alpha
	end
	if not shown then
		return
	end

	local remaining = if deadline then deadline - Workspace:GetServerTimeNow() else 0
	local inside = localInside()
	local text = AirlockController.bannerText(state, inside, remaining)
	if current.label.Text ~= text then
		current.label.Text = text
	end
	local color = if state == "Waiting" and not inside then Palette.Ember else Palette.Bone
	if AirlockController.urgent(state, inside, remaining) then
		local pulse = 0.5 + 0.5 * math.cos(clock * PULSE_HZ * 2 * math.pi)
		color = Palette.Ember:Lerp(Palette.Bone, pulse * 0.45)
	end
	if current.label.TextColor3 ~= color then
		current.label.TextColor3 = color
	end
	current.bar.root.Visible = state == "Waiting"
	current.bar:SetColor(if inside then Palette.Amber else Palette.Ember)
	current.bar:SetFraction(AirlockController.remainingFraction(remaining))
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- True when `player`'s body stands in the current level's exit vestibule (SquadPanel's "in the stairwell"); false
-- without a body or outside a run's exit.
function AirlockController.InVestibule(player: Player): boolean
	return bodyInside(player) == true
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function AirlockController.Init()
	serviceTrove:Add(function()
		local current = view
		view = nil
		if current then
			current.gui:Destroy()
		end
	end)
end

function AirlockController.Start()
	local player = localPlayer
	if not player then
		log.warn("no local player; the airlock banner is not shown")
		return
	end
	local gui = player:WaitForChild("PlayerGui")
	xpcall(function()
		view = build(gui)
	end, function(err: any)
		log.error("airlock banner failed to build: %s\n%s", tostring(err), debug.traceback())
	end)
	serviceTrove:Connect(RunService.PreRender, step)
	for _, tag in { Tags.AirlockDoor, Tags.CheckpointVolume } do
		serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(tag), function()
			scannedAt = -math.huge
		end)
	end
end

function AirlockController.OnRunStarted(_info: Types.RunInfo)
	scannedAt = -math.huge
end

function AirlockController.OnRunEnded()
	scannedAt = -math.huge
	alpha = 0
	local current = view
	if current then
		current.banner.Visible = false
		current.banner.GroupTransparency = 1
	end
end

return table.freeze(AirlockController)
