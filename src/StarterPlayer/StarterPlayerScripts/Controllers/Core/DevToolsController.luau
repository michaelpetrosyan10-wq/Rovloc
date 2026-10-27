--!strict
-- DevToolsController: the touch-first dev panel, the dev overlays and the game's toast line.
--
--   * Toasts (every player). showToast(text) stacks short messages under the top bar; tap one to dismiss it.
--     Notify payloads ({ key, args } -> Strings.get) become toasts until a later phase's HUD claims them through
--     SetNotifyHandler. This is the only Notify UI until P3.
--   * Dev panel (only while the local Player attribute DevTools is true). A "DEV" button in the top-right corner of
--     the core-UI safe area opens a scrollable panel of large buttons that send DevCommand: Dev Run (with the chosen
--     mode), End Run, Next Level, Show Plan, Noise Ring (with the chosen noise kind), Help, and one button per level.
--     Local toggles: Overlays (server DevOverlay drawings + the Creature's state tag) and Vent Graph (the VentNode
--     links of the level the camera is in), and Light (a client-only lamp riding the camera, for inspecting dark
--     rooms without touching Lighting). A sound row auditions any SynthPresets recipe through the server's `sound`
--     command (tap the name for 3D, or Play 2D, or Stop). A status block shows phase, level, zone, FPS, ping and
--     light counts.
--     Nothing needs a keyboard; every target is at least 44 px.
--   * Overlays render in a client-local Workspace folder with HandleAdornments anchored on one invisible part: noise
--     rings are floor annuli that grow and fade (green -> red by radius), plan markers are tall pillars, paths are
--     lines. No parts are simulated and nothing is replicated.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local LightingController = require(script.Parent.LightingController)

local log = Log.new("DevTools")

local P = Attributes.Player
local M = Attributes.Match
local W = Attributes.World
local C = Attributes.Creature

local localPlayer = Players.LocalPlayer

-- Layout (pixels)
local MARGIN = 8
local TOGGLE_SIZE = Vector2.new(76, 44)
local PANEL_WIDTH = 304
local PANEL_TOP = MARGIN + TOGGLE_SIZE.Y + 8
local PANEL_BOTTOM_CLEARANCE = 96 -- keeps the touch jump button free
local BUTTON_HEIGHT = 46
local LEVEL_BUTTON_HEIGHT = 44
local STEP_BUTTON_WIDTH = 52
local GAP = 8

-- Palette
local PANEL_COLOR = Color3.fromRGB(14, 16, 19)
local BUTTON_COLOR = Color3.fromRGB(34, 38, 43)
local BUTTON_ACTIVE = Color3.fromRGB(28, 92, 84)
local BUTTON_PRESSED = Color3.fromRGB(70, 78, 86)
local STROKE_COLOR = Color3.fromRGB(70, 80, 86)
local ACCENT = Color3.fromRGB(96, 214, 190)
local TEXT_COLOR = Color3.fromRGB(232, 236, 236)
local MUTED_TEXT = Color3.fromRGB(160, 170, 172)
local TOAST_COLOR = Color3.fromRGB(16, 18, 21)

local BUTTON_FONT = Font.fromEnum(Enum.Font.BuilderSansBold)
local BODY_FONT = Font.fromEnum(Enum.Font.BuilderSansMedium)
local MONO_FONT = Font.fromEnum(Enum.Font.RobotoMono)

-- Behaviour
local COMMAND_COOLDOWN = 0.5
local STATUS_INTERVAL = 0.5
local CREATURE_INTERVAL = 0.25
local VENT_GRAPH_INTERVAL = 1
local MAX_TOASTS = 4
local MAX_OVERLAY_ITEMS = 160
local DEFAULT_OVERLAY_SECONDS = 2
local RING_GROW_SECONDS = 0.3
local FLOOR_PROBE = 14

-- Dev light (client-only; follows the camera)
local DEV_LIGHT_COLOR = Color3.fromRGB(255, 244, 226)
local DEV_LIGHT_FILL_RANGE = 36
local DEV_LIGHT_FILL_BRIGHTNESS = 1.4
local DEV_LIGHT_BEAM_RANGE = 60
local DEV_LIGHT_BEAM_BRIGHTNESS = 3
local DEV_LIGHT_BEAM_ANGLE = 75

local NOISE_KINDS: { Enums.NoiseKind } = {
	"Walk",
	"Sprint",
	"CrouchWalk",
	"VentScurry",
	"GrateUnscrew",
	"GrateKick",
	"FloorDebris",
	"TrapSnap",
	"Splash",
	"Gasp",
}

export type NotifyHandler = (text: string, payload: Types.NotifyPayload) -> ()

type OverlayItem = {
	instances: { Instance },
	born: number,
	duration: number,
	update: ((age: number, fade: number) -> ())?,
}

local DevToolsController = {}

DevToolsController.Name = "DevToolsController"

local serviceTrove = Trove.new()
local devTrove: Trove.Trove? = nil -- alive while the DevTools attribute is true

-- Toasts
local toastGui: ScreenGui? = nil
local toastList: Frame? = nil
local toastOrder = 0
local notifyHandler: NotifyHandler? = nil

-- Dev state
local devEnabled = false
local overlaysEnabled = true
local ventGraphEnabled = false
local devLightEnabled = false
local soundIndex = 1
local noiseIndex = 1
local difficultyIndex = 1
local lastCommandAt: { [string]: number } = {}

-- Overlays
local overlayFolder: Folder? = nil
local overlayAnchor: Part? = nil
local overlayItems: { OverlayItem } = {}
local ventGraphFolder: Folder? = nil
local ventGraphLayout: string? = nil
local creatureTag: BillboardGui? = nil
local devLight: Part? = nil

-- Per-button UI state (weak keys: entries vanish with their buttons)
local idleColors: { [GuiButton]: Color3 } = setmetatable({}, { __mode = "k" }) :: any
local leavingToasts: { [GuiButton]: boolean } = setmetatable({}, { __mode = "k" }) :: any

--------------------------------------------------------------------------------
-- UI primitives (procedural: Frames, TextButtons, UICorner, UIStroke, UIGradient)
--------------------------------------------------------------------------------

local function corner(parent: GuiObject, radius: number)
	local instance = Instance.new("UICorner")
	instance.CornerRadius = UDim.new(0, radius)
	instance.Parent = parent
end

local function stroke(parent: GuiObject, color: Color3, thickness: number, transparency: number): UIStroke
	local instance = Instance.new("UIStroke")
	instance.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	instance.Color = color
	instance.Thickness = thickness
	instance.Transparency = transparency
	instance.Parent = parent
	return instance
end

local function sheen(parent: GuiObject)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(190, 196, 200))
	gradient.Parent = parent
end

local function padding(parent: GuiObject, pixels: number)
	local instance = Instance.new("UIPadding")
	instance.PaddingTop = UDim.new(0, pixels)
	instance.PaddingBottom = UDim.new(0, pixels)
	instance.PaddingLeft = UDim.new(0, pixels)
	instance.PaddingRight = UDim.new(0, pixels)
	instance.Parent = parent
end

local function screenGui(name: string, displayOrder: number): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.DisplayOrder = displayOrder
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.SafeAreaCompatibility = Enum.SafeAreaCompatibility.FullscreenExtension
	return gui
end

local function playerGui(): Instance
	return localPlayer:WaitForChild("PlayerGui")
end

local function click()
	xpcall(function()
		local AudioController = require(script.Parent.AudioController)
		AudioController.PlayLocal("UiClick")
	end, function(err: any)
		log.warnThrottled("click", 60, "ui click failed: %s", tostring(err))
	end)
end

local function button(parent: Instance, text: string, height: number, order: number): TextButton
	local instance = Instance.new("TextButton")
	instance.Name = "Button"
	instance.LayoutOrder = order
	instance.Size = UDim2.new(1, 0, 0, height)
	instance.BackgroundColor3 = BUTTON_COLOR
	instance.BorderSizePixel = 0
	instance.AutoButtonColor = false
	instance.FontFace = BUTTON_FONT
	instance.Text = text
	instance.TextColor3 = TEXT_COLOR
	instance.TextSize = 17
	instance.TextWrapped = true
	instance.Parent = parent
	corner(instance, 8)
	stroke(instance, STROKE_COLOR, 1, 0.2)
	sheen(instance)
	idleColors[instance] = BUTTON_COLOR
	instance.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1
		then
			instance.BackgroundColor3 = BUTTON_PRESSED
		end
	end)
	instance.InputEnded:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1
		then
			instance.BackgroundColor3 = idleColors[instance] or BUTTON_COLOR
		end
	end)
	return instance
end

local function setIdleColor(target: TextButton, color: Color3)
	idleColors[target] = color
	target.BackgroundColor3 = color
end

--------------------------------------------------------------------------------
-- Toasts
--------------------------------------------------------------------------------

local function ensureToasts(): Frame
	local existing = toastList
	local gui = toastGui
	if existing and gui and gui.Parent then
		return existing
	end
	local newGui = screenGui("Toasts", 900)
	local list = Instance.new("Frame")
	list.Name = "List"
	list.AnchorPoint = Vector2.new(0.5, 0)
	list.Position = UDim2.new(0.5, 0, 0, MARGIN)
	list.Size = UDim2.new(1, -2 * (TOGGLE_SIZE.X + 2 * MARGIN), 1, -2 * MARGIN)
	list.BackgroundTransparency = 1
	list.Parent = newGui
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(520, math.huge)
	limit.MinSize = Vector2.new(220, 0)
	limit.Parent = list
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = list
	newGui.Parent = playerGui()
	toastGui = newGui
	toastList = list
	serviceTrove:Add(newGui)
	return list
end

local function dismissToast(toast: TextButton)
	if leavingToasts[toast] then
		return
	end
	leavingToasts[toast] = true
	local info = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(toast, info, { BackgroundTransparency = 1, TextTransparency = 1 }):Play()
	local border = toast:FindFirstChildOfClass("UIStroke")
	if border then
		TweenService:Create(border, info, { Transparency = 1 }):Play()
	end
	task.delay(0.32, function()
		toast:Destroy()
	end)
end

-- Shows `text` as a toast for `duration` seconds (default: scaled by length). Safe to call from anywhere.
function DevToolsController.showToast(text: string, duration: number?)
	if text == "" then
		return
	end
	local list = ensureToasts()
	toastOrder += 1
	local toast = Instance.new("TextButton")
	toast.Name = "Toast"
	toast.LayoutOrder = toastOrder
	toast.Size = UDim2.fromScale(1, 0)
	toast.AutomaticSize = Enum.AutomaticSize.Y
	toast.BackgroundColor3 = TOAST_COLOR
	toast.BackgroundTransparency = 1
	toast.BorderSizePixel = 0
	toast.AutoButtonColor = false
	toast.FontFace = BODY_FONT
	toast.Text = text
	toast.TextColor3 = TEXT_COLOR
	toast.TextTransparency = 1
	toast.TextSize = 16
	toast.TextWrapped = true
	toast.TextXAlignment = Enum.TextXAlignment.Left
	toast.TextYAlignment = Enum.TextYAlignment.Top
	padding(toast, 10)
	corner(toast, 8)
	local border = stroke(toast, STROKE_COLOR, 1, 1)
	toast.Parent = list
	toast.Activated:Connect(function()
		dismissToast(toast)
	end)

	local fadeIn = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(toast, fadeIn, { BackgroundTransparency = 0.12, TextTransparency = 0 }):Play()
	TweenService:Create(border, fadeIn, { Transparency = 0.2 }):Play()

	local live: { TextButton } = {}
	for _, child in list:GetChildren() do
		if child:IsA("TextButton") and not leavingToasts[child] then
			table.insert(live, child)
		end
	end
	table.sort(live, function(a: TextButton, b: TextButton): boolean
		return a.LayoutOrder < b.LayoutOrder
	end)
	for i = 1, #live - MAX_TOASTS do
		dismissToast(live[i])
	end

	local seconds = duration or math.clamp(2.5 + #text / 28, 3, 14)
	task.delay(seconds, function()
		if toast.Parent then
			dismissToast(toast)
		end
	end)
end

-- A later phase's HUD takes over Notify messages (nil hands them back to the toasts).
function DevToolsController.SetNotifyHandler(handler: NotifyHandler?)
	notifyHandler = handler
end

local function onNotify(payload: any)
	if type(payload) ~= "table" or type(payload.key) ~= "string" then
		return
	end
	local args: { string } = {}
	if type(payload.args) == "table" then
		for _, value in payload.args :: { any } do
			table.insert(args, tostring(value))
		end
	end
	local message: Types.NotifyPayload = { key = payload.key, args = args }
	local text = Strings.get(message.key, table.unpack(args))
	local handler = notifyHandler
	if handler then
		xpcall(handler, function(err: any)
			log.error("notify handler failed: %s", tostring(err))
		end, text, message)
		return
	end
	DevToolsController.showToast(text)
end

--------------------------------------------------------------------------------
-- Overlay rendering (HandleAdornments on one invisible client-local anchor)
--------------------------------------------------------------------------------

local function overlayRoot(): (Folder, Part)
	local folder = overlayFolder
	local anchor = overlayAnchor
	if folder and anchor and folder.Parent == Workspace and anchor.Parent == folder then
		return folder, anchor
	end
	local newFolder = Instance.new("Folder")
	newFolder.Name = "DevOverlays"
	local newAnchor = Instance.new("Part")
	newAnchor.Name = "OverlayAnchor"
	newAnchor.Anchored = true
	newAnchor.CanCollide = false
	newAnchor.CanQuery = false
	newAnchor.CanTouch = false
	newAnchor.CastShadow = false
	newAnchor.Transparency = 1
	newAnchor.Size = Vector3.one
	newAnchor.CFrame = CFrame.identity
	newAnchor.CollisionGroup = CollisionGroups.NoCollide
	newAnchor.Parent = newFolder
	newFolder.Parent = Workspace
	overlayFolder = newFolder
	overlayAnchor = newAnchor
	serviceTrove:Add(newFolder)
	return newFolder, newAnchor
end

local function destroyItem(item: OverlayItem)
	for _, instance in item.instances do
		instance:Destroy()
	end
	table.clear(item.instances)
end

local function clearOverlays()
	for _, item in overlayItems do
		destroyItem(item)
	end
	table.clear(overlayItems)
end

local function addItem(item: OverlayItem)
	table.insert(overlayItems, item)
	while #overlayItems > MAX_OVERLAY_ITEMS do
		destroyItem(table.remove(overlayItems, 1) :: OverlayItem)
	end
end

local function tierColor(radius: number): Color3
	if radius <= 12 then
		return Color3.fromRGB(90, 220, 120)
	elseif radius <= 35 then
		return Color3.fromRGB(240, 210, 80)
	elseif radius <= 70 then
		return Color3.fromRGB(250, 140, 50)
	elseif radius <= 100 then
		return Color3.fromRGB(240, 70, 60)
	end
	return Color3.fromRGB(220, 60, 200)
end

local function characters(): { Instance }
	local list: { Instance } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(list, character)
		end
	end
	local folder = overlayFolder
	if folder then
		table.insert(list, folder)
	end
	return list
end

local function floorBelow(position: Vector3): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = characters()
	local hit = Workspace:Raycast(position + Vector3.new(0, 1, 0), Vector3.new(0, -FLOOR_PROBE, 0), params)
	if hit then
		return hit.Position + Vector3.new(0, 0.12, 0)
	end
	return position - Vector3.new(0, 2.9, 0)
end

local function label(parent: Instance, at: Vector3, text: string, color: Color3): (Attachment, BillboardGui, TextLabel)
	local _, anchor = overlayRoot()
	local attachment = Instance.new("Attachment")
	attachment.Name = "Label"
	attachment.Position = at -- the anchor sits at the origin with identity rotation: local = world
	attachment.Parent = anchor
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Adornee = attachment
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = 220
	billboard.Size = UDim2.fromOffset(180, 26)
	billboard.Parent = parent
	local textLabel = Instance.new("TextLabel")
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundTransparency = 1
	textLabel.FontFace = BUTTON_FONT
	textLabel.Text = text
	textLabel.TextColor3 = color
	textLabel.TextSize = 15
	textLabel.TextStrokeTransparency = 0.4
	textLabel.Parent = billboard
	return attachment, billboard, textLabel
end

local function addNoiseRing(position: Vector3, radius: number, text: string?, duration: number)
	local folder, anchor = overlayRoot()
	local floor = floorBelow(position)
	local color = tierColor(radius)
	local width = math.clamp(radius * 0.035, 0.35, 2.5)
	local flat = CFrame.new(floor) * CFrame.Angles(math.rad(90), 0, 0)

	local ring = Instance.new("CylinderHandleAdornment")
	ring.Name = "NoiseRing"
	ring.Adornee = anchor
	ring.CFrame = flat
	ring.Height = 0.15
	ring.Angle = 360
	ring.Radius = 0.5
	ring.InnerRadius = 0
	ring.Color3 = color
	ring.Transparency = 0.2
	ring.AlwaysOnTop = false
	ring.AdornCullingMode = Enum.AdornCullingMode.Never
	ring.Parent = folder

	local disc = Instance.new("CylinderHandleAdornment")
	disc.Name = "NoiseDisc"
	disc.Adornee = anchor
	disc.CFrame = flat * CFrame.new(0, 0, 0.02)
	disc.Height = 0.05
	disc.Angle = 360
	disc.Radius = 0.5
	disc.InnerRadius = 0
	disc.Color3 = color
	disc.Transparency = 0.9
	disc.AlwaysOnTop = false
	disc.AdornCullingMode = Enum.AdornCullingMode.Never
	disc.Parent = folder

	local instances: { Instance } = { ring, disc }
	local textLabel: TextLabel? = nil
	if text and text ~= "" then
		local attachment, billboard, created = label(folder, position + Vector3.new(0, 2.5, 0), text, color)
		table.insert(instances, billboard)
		table.insert(instances, attachment)
		textLabel = created
	end

	addItem({
		instances = instances,
		born = os.clock(),
		duration = duration,
		update = function(age: number, fade: number)
			local grow = MathUtil.smoothstep(0, RING_GROW_SECONDS, age)
			local r = math.max(0.5, radius * (0.12 + 0.88 * grow))
			ring.Radius = r
			ring.InnerRadius = math.max(0, r - width)
			disc.Radius = r
			ring.Transparency = 0.2 + 0.8 * fade
			disc.Transparency = 0.9 + 0.1 * fade
			local current = textLabel
			if current then
				current.TextTransparency = fade
				current.TextStrokeTransparency = 0.4 + 0.6 * fade
			end
		end,
	})
end

-- Plan marker look per planned kind. Props are pillars; a grate the director locked is a flat plate at the grate.
type PlanStyle = { color: Color3, size: Vector3, lift: number }

local PLAN_STYLES: { [string]: PlanStyle } = {
	BearTrap = { color = Color3.fromRGB(255, 108, 64), size = Vector3.new(0.9, 7, 0.9), lift = 3.5 },
	ChemicalFlask = { color = Color3.fromRGB(120, 235, 90), size = Vector3.new(0.8, 6, 0.8), lift = 3 },
	Battery = { color = Color3.fromRGB(255, 220, 70), size = Vector3.new(0.7, 5, 0.7), lift = 2.5 },
	LockedGrate = { color = Color3.fromRGB(235, 80, 235), size = Vector3.new(3.6, 3.6, 0.4), lift = 0 },
}
local DEFAULT_PLAN_STYLE: PlanStyle = { color = ACCENT, size = Vector3.new(0.8, 7, 0.8), lift = 3.5 }

local function addPlan(points: { Vector3 }, kinds: { [number]: string }, duration: number)
	local folder, anchor = overlayRoot()
	local instances: { Instance } = {}
	local pillars: { BoxHandleAdornment } = {}
	for index, point in points do
		local style = PLAN_STYLES[kinds[index] or ""] or DEFAULT_PLAN_STYLE
		local pillar = Instance.new("BoxHandleAdornment")
		pillar.Name = "PlanMarker"
		pillar.Adornee = anchor
		pillar.CFrame = CFrame.new(point + Vector3.new(0, style.lift, 0))
		pillar.Size = style.size
		pillar.Color3 = style.color
		pillar.Transparency = 0.35
		pillar.AlwaysOnTop = true
		pillar.AdornCullingMode = Enum.AdornCullingMode.Never
		pillar.ZIndex = 2
		pillar.Parent = folder
		table.insert(instances, pillar)
		table.insert(pillars, pillar)
	end
	addItem({
		instances = instances,
		born = os.clock(),
		duration = duration,
		update = function(_age: number, fade: number)
			for _, pillar in pillars do
				pillar.Transparency = 0.35 + 0.65 * fade
			end
		end,
	})
end

local function addPath(points: { Vector3 }, duration: number)
	local folder, anchor = overlayRoot()
	local instances: { Instance } = {}
	local pieces: { HandleAdornment } = {}
	local color = Color3.fromRGB(120, 200, 255)
	for index, point in points do
		local dot = Instance.new("SphereHandleAdornment")
		dot.Name = "PathNode"
		dot.Adornee = anchor
		dot.CFrame = CFrame.new(point)
		dot.Radius = 0.45
		dot.Color3 = color
		dot.Transparency = 0.2
		dot.AlwaysOnTop = true
		dot.AdornCullingMode = Enum.AdornCullingMode.Never
		dot.Parent = folder
		table.insert(instances, dot)
		table.insert(pieces, dot)
		local nextPoint = points[index + 1]
		if nextPoint and (nextPoint - point).Magnitude > 0.05 then
			local line = Instance.new("LineHandleAdornment")
			line.Name = "PathLine"
			line.Adornee = anchor
			line.CFrame = CFrame.lookAt(point, nextPoint)
			line.Length = (nextPoint - point).Magnitude
			line.Thickness = 4
			line.Color3 = color
			line.Transparency = 0.2
			line.AlwaysOnTop = true
			line.AdornCullingMode = Enum.AdornCullingMode.Never
			line.Parent = folder
			table.insert(instances, line)
			table.insert(pieces, line)
		end
	end
	addItem({
		instances = instances,
		born = os.clock(),
		duration = duration,
		update = function(_age: number, fade: number)
			for _, piece in pieces do
				piece.Transparency = 0.2 + 0.8 * fade
			end
		end,
	})
end

local function pointList(value: any): { Vector3 }
	local out: { Vector3 } = {}
	if type(value) ~= "table" then
		return out
	end
	for _, point in value :: { any } do
		if typeof(point) == "Vector3" and MathUtil.isFiniteVector(point) then
			table.insert(out, point)
		end
	end
	return out
end

-- Plan markers: the valid points of the payload and, aligned with them, the kind each one was sent with (a point
-- that is not a finite Vector3 drops together with its kind; a kind that is not a string draws the default marker).
local function planList(rawPoints: any, rawKinds: any): ({ Vector3 }, { [number]: string })
	local points: { Vector3 } = {}
	local kinds: { [number]: string } = {}
	if type(rawPoints) ~= "table" then
		return points, kinds
	end
	local kindTable: { any } = if type(rawKinds) == "table" then rawKinds :: { any } else {}
	for index, point in rawPoints :: { any } do
		if typeof(point) == "Vector3" and MathUtil.isFiniteVector(point) then
			table.insert(points, point)
			local kind = kindTable[index]
			if type(kind) == "string" then
				kinds[#points] = kind
			end
		end
	end
	return points, kinds
end

local function onDevOverlay(payload: any)
	if not devEnabled or type(payload) ~= "table" then
		return
	end
	local kind = payload.kind
	if kind == "Clear" then
		clearOverlays()
		return
	end
	if not overlaysEnabled then
		return
	end
	local duration = if type(payload.duration) == "number" and MathUtil.isFinite(payload.duration)
		then math.clamp(payload.duration, 0.2, 120)
		else DEFAULT_OVERLAY_SECONDS
	if kind == "Noise" then
		local position = payload.position
		local radius = payload.radius
		if typeof(position) ~= "Vector3" or type(radius) ~= "number" or not MathUtil.isFinite(radius) then
			return
		end
		local text = if type(payload.label) == "string" then payload.label else nil
		addNoiseRing(position, math.clamp(radius, 0.5, 600), text, duration)
	elseif kind == "Plan" then
		local points, kinds = planList(payload.points, payload.kinds)
		addPlan(points, kinds, duration)
	elseif kind == "Path" then
		addPath(pointList(payload.points), duration)
	end
end

local function updateOverlays()
	if #overlayItems == 0 then
		return
	end
	local now = os.clock()
	for i = #overlayItems, 1, -1 do
		local item = overlayItems[i]
		local age = now - item.born
		if age >= item.duration then
			destroyItem(item)
			table.remove(overlayItems, i)
		else
			local update = item.update
			if update then
				update(age, MathUtil.smoothstep(item.duration * 0.45, item.duration, age))
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Vent graph + Creature tag
--------------------------------------------------------------------------------

-- World CFrame of an attachment (its parent part's CFrame composed with its own; identity-safe for any parent).
local function attachmentWorld(attachment: Attachment): CFrame
	local parent = attachment.Parent
	if parent and parent:IsA("BasePart") then
		return parent.CFrame * attachment.CFrame
	end
	return attachment.WorldCFrame
end

local function clearVentGraph()
	local folder = ventGraphFolder
	ventGraphFolder = nil
	ventGraphLayout = nil
	if folder then
		folder:Destroy()
	end
end

local function graphLayout(): string?
	local view = LightingController.GetStats().viewLayout
	if view then
		return view
	end
	local current = ReplicatedStorage:GetAttribute(M.CurrentLevel)
	return if type(current) == "string" then current else nil
end

local function buildVentGraph(layoutId: string)
	clearVentGraph()
	local root, anchor = overlayRoot()
	local folder = Instance.new("Folder")
	folder.Name = "VentGraph"
	folder.Parent = root
	ventGraphFolder = folder
	ventGraphLayout = layoutId

	local positions: { [string]: Vector3 } = {}
	local links: { [string]: { string } } = {}
	local roots: { [Instance]: boolean } = {}
	for _, node in CollectionService:GetTagged(Tags.VentNode) do
		if not node:IsA("Attachment") or Attributes.getString(node, W.LevelId, "") ~= layoutId then
			continue
		end
		local id = Attributes.getString(node, W.NodeId, node.Name)
		positions[id] = attachmentWorld(node).Position
		links[id] = Attributes.getList(node, W.Links)
		local parent = node.Parent
		if parent then
			roots[parent] = true
		end
	end
	local nodeColor = Color3.fromRGB(255, 196, 92)
	local linkColor = Color3.fromRGB(255, 150, 60)
	for id, position in positions do
		local dot = Instance.new("SphereHandleAdornment")
		dot.Name = id
		dot.Adornee = anchor
		dot.CFrame = CFrame.new(position)
		dot.Radius = 0.5
		dot.Color3 = nodeColor
		dot.Transparency = 0.15
		dot.AlwaysOnTop = true
		dot.AdornCullingMode = Enum.AdornCullingMode.Never
		dot.Parent = folder
		for _, other in links[id] do
			local otherPosition = positions[other]
			if otherPosition and id < other and (otherPosition - position).Magnitude > 0.05 then
				local line = Instance.new("LineHandleAdornment")
				line.Name = id .. "-" .. other
				line.Adornee = anchor
				line.CFrame = CFrame.lookAt(position, otherPosition)
				line.Length = (otherPosition - position).Magnitude
				line.Thickness = 3
				line.Color3 = linkColor
				line.Transparency = 0.25
				line.AlwaysOnTop = true
				line.AdornCullingMode = Enum.AdornCullingMode.Never
				line.Parent = folder
			end
		end
	end
	for nodeRoot in roots do
		for _, child in nodeRoot:GetChildren() do
			if not child:IsA("Attachment") or Attributes.getString(child, W.GrateId, "") == "" then
				continue
			end
			if child:HasTag(Tags.VentNode) then
				continue
			end
			local critical = Attributes.getBool(child, W.CriticalPath, false)
			local lockable = Attributes.getBool(child, W.Lockable, false)
			local marker = Instance.new("BoxHandleAdornment")
			marker.Name = child.Name
			marker.Adornee = anchor
			marker.CFrame = attachmentWorld(child)
			marker.Size = Vector3.new(3.5, 3.5, 0.3)
			marker.Color3 = if critical
				then Color3.fromRGB(90, 220, 120)
				elseif lockable then Color3.fromRGB(240, 200, 70)
				else Color3.fromRGB(200, 200, 200)
			marker.Transparency = 0.45
			marker.AlwaysOnTop = true
			marker.AdornCullingMode = Enum.AdornCullingMode.Never
			marker.Parent = folder
		end
	end
end

local function refreshVentGraph()
	if not devEnabled or not ventGraphEnabled then
		if ventGraphFolder then
			clearVentGraph()
		end
		return
	end
	local layoutId = graphLayout()
	if layoutId == nil then
		clearVentGraph()
		return
	end
	if layoutId ~= ventGraphLayout or ventGraphFolder == nil or ventGraphFolder.Parent == nil then
		buildVentGraph(layoutId)
	end
end

local function clearCreatureTag()
	local tag = creatureTag
	creatureTag = nil
	if tag then
		tag:Destroy()
	end
end

local function refreshCreatureTag()
	if not devEnabled or not overlaysEnabled then
		clearCreatureTag()
		return
	end
	local creature = Instances.creature()
	local root = Instances.creatureRoot()
	if not creature or not root then
		clearCreatureTag()
		return
	end
	local tag = creatureTag
	local text: TextLabel
	if not tag or tag.Parent == nil or tag.Adornee ~= root then
		clearCreatureTag()
		local folder = overlayRoot()
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "CreatureTag"
		billboard.Adornee = root
		billboard.AlwaysOnTop = true
		billboard.LightInfluence = 0
		billboard.MaxDistance = 400
		billboard.Size = UDim2.fromOffset(240, 28)
		billboard.StudsOffsetWorldSpace = Vector3.new(0, 6, 0)
		billboard.Parent = folder
		local created = Instance.new("TextLabel")
		created.Name = "Text"
		created.Size = UDim2.fromScale(1, 1)
		created.BackgroundTransparency = 1
		created.FontFace = BUTTON_FONT
		created.TextColor3 = Color3.fromRGB(255, 110, 100)
		created.TextSize = 16
		created.TextStrokeTransparency = 0.3
		created.Parent = billboard
		creatureTag = billboard
		text = created
	else
		local existing = tag:FindFirstChildOfClass("TextLabel")
		if not existing then
			clearCreatureTag()
			return
		end
		text = existing
	end
	local none = Strings.get("Dev.Panel.None")
	local target = creature:GetAttribute(C.TargetUserId)
	text.Text = Strings.get(
		"Dev.Panel.Creature",
		Attributes.getString(creature, C.MonsterState, none),
		Attributes.getString(creature, C.PoseMode, none),
		if target ~= nil then tostring(target) else none
	)
end

--------------------------------------------------------------------------------
-- Dev light: a fill PointLight and a forward SpotLight on an invisible part under the camera. It only adds light
-- sources, so LightingController's Lighting writes and light budget are untouched (the part is not tagged).
--------------------------------------------------------------------------------

local function clearDevLight()
	local part = devLight
	devLight = nil
	if part then
		part:Destroy()
	end
end

local function createDevLight(camera: Camera): Part
	clearDevLight()
	local part = Instance.new("Part")
	part.Name = "DevLight"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = camera.CFrame
	part.CollisionGroup = CollisionGroups.NoCollide
	local fill = Instance.new("PointLight")
	fill.Name = "Fill"
	fill.Color = DEV_LIGHT_COLOR
	fill.Range = DEV_LIGHT_FILL_RANGE
	fill.Brightness = DEV_LIGHT_FILL_BRIGHTNESS
	fill.Shadows = false
	fill.Parent = part
	local beam = Instance.new("SpotLight")
	beam.Name = "Beam"
	beam.Color = DEV_LIGHT_COLOR
	beam.Face = Enum.NormalId.Front
	beam.Range = DEV_LIGHT_BEAM_RANGE
	beam.Brightness = DEV_LIGHT_BEAM_BRIGHTNESS
	beam.Angle = DEV_LIGHT_BEAM_ANGLE
	beam.Shadows = false
	beam.Parent = part
	part.Parent = camera
	devLight = part
	return part
end

-- Runs every frame before render while dev mode is on.
local function updateDevLight()
	if not devEnabled or not devLightEnabled then
		if devLight then
			clearDevLight()
		end
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local existing = devLight
	local part: Part = if existing and existing.Parent == camera then existing else createDevLight(camera)
	part.CFrame = camera.CFrame
end

--------------------------------------------------------------------------------
-- Dev commands
--------------------------------------------------------------------------------

local function send(command: string, args: { string })
	local now = os.clock()
	local key = command .. " " .. table.concat(args, " ")
	local last = lastCommandAt[key]
	if last and now - last < COMMAND_COOLDOWN then
		return
	end
	lastCommandAt[key] = now
	click()
	local payload: Types.DevCommandPayload = { command = command, args = args }
	Net.Client.fire("DevCommand", payload)
end

--------------------------------------------------------------------------------
-- Dev panel
--------------------------------------------------------------------------------

local function onOff(value: boolean): string
	return Strings.get(if value then "Dev.Panel.On" else "Dev.Panel.Off")
end

local function grid(parent: Instance, columns: number, cellHeight: number, order: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = "Grid"
	frame.LayoutOrder = order
	frame.Size = UDim2.fromScale(1, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundTransparency = 1
	frame.Parent = parent
	local layout = Instance.new("UIGridLayout")
	local inset = math.ceil(GAP * (columns - 1) / columns)
	layout.CellSize = UDim2.new(1 / columns, -inset, 0, cellHeight)
	layout.CellPadding = UDim2.fromOffset(GAP, GAP)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame
	return frame
end

local function buildPanel(trove: Trove.Trove)
	local gui = screenGui("DevTools", 950)
	trove:Add(gui)

	local toggle = button(gui, Strings.get("Dev.Panel.Toggle"), TOGGLE_SIZE.Y, 0)
	toggle.Name = "Toggle"
	toggle.AnchorPoint = Vector2.new(1, 0)
	toggle.Position = UDim2.new(1, -MARGIN, 0, MARGIN)
	toggle.Size = UDim2.fromOffset(TOGGLE_SIZE.X, TOGGLE_SIZE.Y)
	toggle.TextColor3 = ACCENT
	local toggleStroke = toggle:FindFirstChildOfClass("UIStroke")
	if toggleStroke then
		toggleStroke.Color = ACCENT
		toggleStroke.Thickness = 1.5
	end

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -MARGIN, 0, PANEL_TOP)
	panel.Size = UDim2.new(0, PANEL_WIDTH, 1, -(PANEL_TOP + PANEL_BOTTOM_CLEARANCE))
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BackgroundTransparency = 0.08
	panel.BorderSizePixel = 0
	panel.Active = true
	panel.Visible = false
	panel.Parent = gui
	corner(panel, 12)
	stroke(panel, STROKE_COLOR, 1.5, 0.1)
	padding(panel, 10)
	local panelLimit = Instance.new("UISizeConstraint")
	panelLimit.MinSize = Vector2.new(PANEL_WIDTH, 100) -- landscape phones: stay clear of the jump button
	panelLimit.MaxSize = Vector2.new(PANEL_WIDTH, 520)
	panelLimit.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 20)
	title.BackgroundTransparency = 1
	title.FontFace = BUTTON_FONT
	title.Text = Strings.get("Dev.Panel.Title")
	title.TextColor3 = ACCENT
	title.TextSize = 16
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = panel

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "Status"
	statusLabel.Position = UDim2.fromOffset(0, 22)
	statusLabel.Size = UDim2.new(1, 0, 0, 34)
	statusLabel.BackgroundTransparency = 1
	statusLabel.FontFace = MONO_FONT
	statusLabel.Text = ""
	statusLabel.TextColor3 = MUTED_TEXT
	statusLabel.TextSize = 12
	statusLabel.TextWrapped = true
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.TextYAlignment = Enum.TextYAlignment.Top
	statusLabel.Parent = panel

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Buttons"
	scroll.Position = UDim2.fromOffset(0, 62)
	scroll.Size = UDim2.new(1, 0, 1, -62)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ScrollBarThickness = 5
	scroll.ScrollBarImageColor3 = STROKE_COLOR
	scroll.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	scroll.Parent = panel
	local scrollLayout = Instance.new("UIListLayout")
	scrollLayout.FillDirection = Enum.FillDirection.Vertical
	scrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
	scrollLayout.Padding = UDim.new(0, GAP)
	scrollLayout.Parent = scroll
	local scrollPad = Instance.new("UIPadding")
	scrollPad.PaddingRight = UDim.new(0, 8)
	scrollPad.PaddingBottom = UDim.new(0, 4)
	scrollPad.Parent = scroll

	local actions = grid(scroll, 2, BUTTON_HEIGHT, 1)
	local order = 0
	local function action(text: string, onActivated: (TextButton) -> ()): TextButton
		order += 1
		local created = button(actions, text, BUTTON_HEIGHT, order)
		created.Activated:Connect(function()
			onActivated(created)
		end)
		return created
	end

	local difficulties: { Enums.Difficulty } = Enums.Difficulty
	action(Strings.get("Dev.Panel.DevRun"), function()
		send("devrun", { difficulties[difficultyIndex] })
	end)
	action(Strings.get("Dev.Panel.EndRun"), function()
		send("endrun", {})
	end)
	action(Strings.get("Dev.Panel.NextLevel"), function()
		send("next", {})
	end)
	action(Strings.get("Dev.Panel.ShowPlan"), function()
		send("plan", {})
	end)
	action(Strings.get("Dev.Panel.NoiseRing"), function()
		send("noise", { NOISE_KINDS[noiseIndex] })
	end)
	action(Strings.get("Dev.Panel.NoiseKind", NOISE_KINDS[noiseIndex]), function(self: TextButton)
		noiseIndex = noiseIndex % #NOISE_KINDS + 1
		click()
		self.Text = Strings.get("Dev.Panel.NoiseKind", NOISE_KINDS[noiseIndex])
	end)
	local overlaysButton = action(Strings.get("Dev.Panel.Overlays", onOff(overlaysEnabled)), function(self: TextButton)
		overlaysEnabled = not overlaysEnabled
		click()
		if not overlaysEnabled then
			clearOverlays()
			clearCreatureTag()
		end
		self.Text = Strings.get("Dev.Panel.Overlays", onOff(overlaysEnabled))
		setIdleColor(self, if overlaysEnabled then BUTTON_ACTIVE else BUTTON_COLOR)
	end)
	setIdleColor(overlaysButton, if overlaysEnabled then BUTTON_ACTIVE else BUTTON_COLOR)
	local ventButton = action(Strings.get("Dev.Panel.VentGraph", onOff(ventGraphEnabled)), function(self: TextButton)
		ventGraphEnabled = not ventGraphEnabled
		click()
		self.Text = Strings.get("Dev.Panel.VentGraph", onOff(ventGraphEnabled))
		setIdleColor(self, if ventGraphEnabled then BUTTON_ACTIVE else BUTTON_COLOR)
		refreshVentGraph()
	end)
	setIdleColor(ventButton, if ventGraphEnabled then BUTTON_ACTIVE else BUTTON_COLOR)
	local lightButton = action(Strings.get("Dev.Panel.Light", onOff(devLightEnabled)), function(self: TextButton)
		devLightEnabled = not devLightEnabled
		click()
		self.Text = Strings.get("Dev.Panel.Light", onOff(devLightEnabled))
		setIdleColor(self, if devLightEnabled then BUTTON_ACTIVE else BUTTON_COLOR)
		updateDevLight()
	end)
	setIdleColor(lightButton, if devLightEnabled then BUTTON_ACTIVE else BUTTON_COLOR)
	action(Strings.get("Dev.Panel.Difficulty", difficulties[difficultyIndex]), function(self: TextButton)
		difficultyIndex = difficultyIndex % #difficulties + 1
		click()
		self.Text = Strings.get("Dev.Panel.Difficulty", difficulties[difficultyIndex])
	end)
	action(Strings.get("Dev.Panel.Help"), function()
		send("help", {})
	end)

	local levelsLabel = Instance.new("TextLabel")
	levelsLabel.Name = "LevelsLabel"
	levelsLabel.LayoutOrder = 2
	levelsLabel.Size = UDim2.new(1, 0, 0, 18)
	levelsLabel.BackgroundTransparency = 1
	levelsLabel.FontFace = BODY_FONT
	levelsLabel.Text = Strings.get("Dev.Panel.Levels")
	levelsLabel.TextColor3 = MUTED_TEXT
	levelsLabel.TextSize = 14
	levelsLabel.TextXAlignment = Enum.TextXAlignment.Left
	levelsLabel.Parent = scroll

	local levels = grid(scroll, 3, LEVEL_BUTTON_HEIGHT, 3)
	for index = 1, #Enums.LevelId do
		local levelNumber = index - 1
		local levelButton = button(levels, Strings.get("Dev.Panel.Level", levelNumber), LEVEL_BUTTON_HEIGHT, index)
		levelButton.Activated:Connect(function()
			send("level", { tostring(levelNumber) })
		end)
	end

	-- Sound audition: < [preset] > steps through SynthPresets.names(); tapping the name plays it 3D ahead of the
	-- character, Play 2D plays it flat, Stop ends a looping audition.
	local soundNames = SynthPresets.names()
	local soundsLabel = Instance.new("TextLabel")
	soundsLabel.Name = "SoundsLabel"
	soundsLabel.LayoutOrder = 4
	soundsLabel.Size = UDim2.new(1, 0, 0, 18)
	soundsLabel.BackgroundTransparency = 1
	soundsLabel.FontFace = BODY_FONT
	soundsLabel.Text = Strings.get("Dev.Panel.Sounds", #soundNames)
	soundsLabel.TextColor3 = MUTED_TEXT
	soundsLabel.TextSize = 14
	soundsLabel.TextXAlignment = Enum.TextXAlignment.Left
	soundsLabel.Parent = scroll

	if #soundNames > 0 then
		soundIndex = math.clamp(soundIndex, 1, #soundNames)
		local stepper = Instance.new("Frame")
		stepper.Name = "SoundStepper"
		stepper.LayoutOrder = 5
		stepper.Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT)
		stepper.BackgroundTransparency = 1
		stepper.Parent = scroll
		local previous = button(stepper, Strings.get("Dev.Panel.SoundPrev"), BUTTON_HEIGHT, 1)
		previous.Size = UDim2.new(0, STEP_BUTTON_WIDTH, 1, 0)
		local current = button(stepper, soundNames[soundIndex], BUTTON_HEIGHT, 2)
		current.Name = "Preset"
		current.Position = UDim2.fromOffset(STEP_BUTTON_WIDTH + GAP, 0)
		current.Size = UDim2.new(1, -2 * (STEP_BUTTON_WIDTH + GAP), 1, 0)
		current.TextSize = 14
		local nextButton = button(stepper, Strings.get("Dev.Panel.SoundNext"), BUTTON_HEIGHT, 3)
		nextButton.AnchorPoint = Vector2.new(1, 0)
		nextButton.Position = UDim2.fromScale(1, 0)
		nextButton.Size = UDim2.new(0, STEP_BUTTON_WIDTH, 1, 0)
		local function step(delta: number)
			soundIndex = (soundIndex - 1 + delta) % #soundNames + 1
			click()
			current.Text = soundNames[soundIndex]
		end
		previous.Activated:Connect(function()
			step(-1)
		end)
		nextButton.Activated:Connect(function()
			step(1)
		end)
		current.Activated:Connect(function()
			send("sound", { soundNames[soundIndex] })
		end)

		local soundActions = grid(scroll, 2, BUTTON_HEIGHT, 6)
		local play2d = button(soundActions, Strings.get("Dev.Panel.SoundPlay2D"), BUTTON_HEIGHT, 1)
		play2d.Activated:Connect(function()
			send("sound", { soundNames[soundIndex], "2d" })
		end)
		local stop = button(soundActions, Strings.get("Dev.Panel.SoundStop"), BUTTON_HEIGHT, 2)
		stop.Activated:Connect(function()
			send("sound", { "stop" })
		end)
	end

	toggle.Activated:Connect(function()
		panel.Visible = not panel.Visible
		click()
		toggle.Text = Strings.get(if panel.Visible then "Dev.Panel.Hide" else "Dev.Panel.Toggle")
	end)

	-- Status block (2 Hz) + FPS counter
	local frames = 0
	local frameWindow = 0
	local fps = 0
	trove:Connect(RunService.Heartbeat, function(dt: number)
		frames += 1
		frameWindow += dt
		if frameWindow >= STATUS_INTERVAL then
			fps = math.floor(frames / frameWindow + 0.5)
			frames = 0
			frameWindow = 0
			if not panel.Visible then
				return
			end
			local none = Strings.get("Dev.Panel.None")
			local stats = LightingController.GetStats()
			local ping = 0
			xpcall(function()
				ping = math.floor(localPlayer:GetNetworkPing() * 1000 + 0.5)
			end, function(): any
				return nil
			end)
			statusLabel.Text = Strings.get(
				"Dev.Panel.Status",
				Attributes.getString(ReplicatedStorage, M.MatchPhase, none),
				Attributes.getString(ReplicatedStorage, M.CurrentLevel, none),
				Attributes.getString(localPlayer, P.ZoneId, none)
			) .. "\n" .. Strings.get("Dev.Panel.Perf", fps, ping, stats.lit, stats.registered)
		end
	end)

	gui.Parent = playerGui()
end

--------------------------------------------------------------------------------
-- Enabling / disabling dev mode
--------------------------------------------------------------------------------

local function showBootError()
	local problem = ReplicatedStorage:GetAttribute(M.BootError)
	if type(problem) == "string" and problem ~= "" then
		DevToolsController.showToast(Strings.get("Boot.Error", problem), 12)
	end
end

local function disableDev()
	devEnabled = false
	local trove = devTrove
	devTrove = nil
	if trove then
		trove:Destroy()
	end
	clearOverlays()
	clearVentGraph()
	clearCreatureTag()
	clearDevLight()
end

local function enableDev()
	if devEnabled then
		return
	end
	devEnabled = true
	local trove = serviceTrove:Extend()
	devTrove = trove
	buildPanel(trove)

	local creatureClock = 0
	local graphClock = 0
	trove:Connect(RunService.Heartbeat, function(dt: number)
		updateOverlays()
		creatureClock += dt
		if creatureClock >= CREATURE_INTERVAL then
			creatureClock = 0
			refreshCreatureTag()
		end
		graphClock += dt
		if graphClock >= VENT_GRAPH_INTERVAL then
			graphClock = 0
			refreshVentGraph()
		end
	end)
	trove:Connect(RunService.PreRender, updateDevLight)
	trove:Connect(ReplicatedStorage:GetAttributeChangedSignal(M.BootError), showBootError)
	showBootError()
end

local function syncDev()
	if localPlayer:GetAttribute(P.DevTools) == true then
		enableDev()
	else
		disableDev()
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function DevToolsController.Start()
	local notify = Net.Client.on("Notify", onNotify)
	if notify then
		serviceTrove:Add(notify)
	end
	local overlay = Net.Client.on("DevOverlay", onDevOverlay)
	if overlay then
		serviceTrove:Add(overlay)
	end
	serviceTrove:Connect(localPlayer:GetAttributeChangedSignal(P.DevTools), syncDev)
	syncDev()
end

function DevToolsController.OnRunEnded()
	clearOverlays()
end

-- True while the local player has dev tools.
function DevToolsController.IsEnabled(): boolean
	return devEnabled
end

return DevToolsController
