--!strict
-- LoadingCurtain: the black screen every player sees from the first frame until they hold the whole school.
--
-- Before game.Loaded only engine APIs are used (ReplicatedStorage may not have replicated yet): the default loading
-- screen is removed and a full-screen black curtain with a pulsing title bar and a shimmering progress line goes up.
-- After game.Loaded the shared modules are required and the curtain waits for two things:
--   1. ReplicatedStorage.WorldReady (the server finished building), and
--   2. local receipt: the BaseParts under Workspace.School and Workspace.Lobby, counted incrementally with
--      DescendantAdded / DescendantRemoving (never rescanned), reach RECEIVE_FRACTION of ReplicatedStorage.WorldPartCount.
-- Then it acknowledges the world to the server (Net.Client.setup() is idempotent, ClientMain calls it too) with
-- ClientWorldReady { partCount }, which is what lets CharacterService spawn this player. The curtain lifts once the
-- character exists (or after CHARACTER_WAIT seconds) and is destroyed.
--
-- Failure states: after GameConfig.WorldReadyTimeout the status line shows "Boot.Timeout" and the curtain stays up
-- (it still lifts if the world arrives later). A ReplicatedStorage.BootError string is shown as "Boot.Error"; the
-- curtain holds it on screen for ERROR_HOLD seconds before lifting, so a misconfigured place is loud but playable.

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

ReplicatedFirst:RemoveDefaultLoadingScreen()

local RECEIVE_FRACTION = 0.97
local POLL_SECONDS = 0.1
local CHARACTER_WAIT = 10
local READY_HOLD = 0.6
local ERROR_HOLD = 6
local FADE_SECONDS = 1.1

local TITLE_COLOR = Color3.fromRGB(206, 200, 188)
local TITLE_STROKE = Color3.fromRGB(90, 8, 8)
local STATUS_COLOR = Color3.fromRGB(150, 148, 142)
local ERROR_COLOR = Color3.fromRGB(214, 92, 76)
local TRACK_COLOR = Color3.fromRGB(34, 34, 36)
local FILL_COLOR = Color3.fromRGB(176, 40, 30)

local localPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Curtain UI (engine APIs only)
--------------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "LoadingCurtain"
gui.IgnoreGuiInset = true
gui.DisplayOrder = 1000
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local backdrop = Instance.new("Frame")
backdrop.Name = "Backdrop"
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
backdrop.BackgroundTransparency = 0
backdrop.BorderSizePixel = 0
backdrop.Active = true
backdrop.Parent = gui

-- A faint blood-dark glow behind the title, darkest at the edges.
local glow = Instance.new("Frame")
glow.Name = "Glow"
glow.Size = UDim2.fromScale(1, 1)
glow.BackgroundColor3 = Color3.fromRGB(26, 5, 5)
glow.BorderSizePixel = 0
glow.Parent = backdrop
local glowGradient = Instance.new("UIGradient")
glowGradient.Rotation = 90
glowGradient.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.45, 0.55),
	NumberSequenceKeypoint.new(0.55, 0.55),
	NumberSequenceKeypoint.new(1, 1),
})
glowGradient.Parent = glow

local title = Instance.new("TextLabel")
title.Name = "Title"
title.AnchorPoint = Vector2.new(0.5, 0.5)
title.Position = UDim2.fromScale(0.5, 0.4)
title.Size = UDim2.new(0.9, 0, 0, 64)
title.BackgroundTransparency = 1
title.FontFace = Font.fromEnum(Enum.Font.SpecialElite)
title.Text = ""
title.TextColor3 = TITLE_COLOR
title.TextScaled = true
title.TextWrapped = true
title.Parent = backdrop
local titleSize = Instance.new("UITextSizeConstraint")
titleSize.MaxTextSize = 46
titleSize.MinTextSize = 18
titleSize.Parent = title
local titleStroke = Instance.new("UIStroke")
titleStroke.Color = TITLE_STROKE
titleStroke.Thickness = 1.5
titleStroke.Transparency = 0.35
titleStroke.Parent = title

local progressTrack = Instance.new("Frame")
progressTrack.Name = "Track"
progressTrack.AnchorPoint = Vector2.new(0.5, 0.5)
progressTrack.Position = UDim2.fromScale(0.5, 0.52)
progressTrack.Size = UDim2.new(0.6, 0, 0, 4)
progressTrack.BackgroundColor3 = TRACK_COLOR
progressTrack.BorderSizePixel = 0
progressTrack.ClipsDescendants = true
progressTrack.Parent = backdrop
local trackLimit = Instance.new("UISizeConstraint")
trackLimit.MaxSize = Vector2.new(440, 4)
trackLimit.Parent = progressTrack
local trackCorner = Instance.new("UICorner")
trackCorner.CornerRadius = UDim.new(1, 0)
trackCorner.Parent = progressTrack

local fill = Instance.new("Frame")
fill.Name = "Fill"
fill.Size = UDim2.fromScale(0, 1)
fill.BackgroundColor3 = FILL_COLOR
fill.BorderSizePixel = 0
fill.Parent = progressTrack
local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(1, 0)
fillCorner.Parent = fill
local fillGradient = Instance.new("UIGradient")
fillGradient.Color = ColorSequence.new(Color3.fromRGB(110, 20, 16), Color3.fromRGB(230, 70, 48))
fillGradient.Parent = fill

-- Indeterminate shimmer while the size of the world is still unknown.
local shimmer = Instance.new("Frame")
shimmer.Name = "Shimmer"
shimmer.Size = UDim2.fromScale(0.28, 1)
shimmer.BackgroundColor3 = FILL_COLOR
shimmer.BorderSizePixel = 0
shimmer.Parent = progressTrack
local shimmerGradient = Instance.new("UIGradient")
shimmerGradient.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.5, 0.1),
	NumberSequenceKeypoint.new(1, 1),
})
shimmerGradient.Parent = shimmer

local status = Instance.new("TextLabel")
status.Name = "Status"
status.AnchorPoint = Vector2.new(0.5, 0)
status.Position = UDim2.fromScale(0.5, 0.56)
status.Size = UDim2.new(0.9, 0, 0, 24)
status.BackgroundTransparency = 1
status.FontFace = Font.fromEnum(Enum.Font.Gotham)
status.Text = ""
status.TextColor3 = STATUS_COLOR
status.TextScaled = true
status.TextWrapped = true
status.Parent = backdrop
local statusSize = Instance.new("UITextSizeConstraint")
statusSize.MaxTextSize = 20
statusSize.MinTextSize = 12
statusSize.Parent = status

local detail = Instance.new("TextLabel")
detail.Name = "Detail"
detail.AnchorPoint = Vector2.new(0.5, 0)
detail.Position = UDim2.fromScale(0.5, 0.64)
detail.Size = UDim2.new(0.86, 0, 0.26, 0)
detail.BackgroundTransparency = 1
detail.FontFace = Font.fromEnum(Enum.Font.Gotham)
detail.Text = ""
detail.TextColor3 = ERROR_COLOR
detail.TextSize = 15
detail.TextWrapped = true
detail.TextYAlignment = Enum.TextYAlignment.Top
detail.Parent = backdrop

gui.Parent = localPlayer:WaitForChild("PlayerGui")

--------------------------------------------------------------------------------
-- Animation (title pulse + progress easing), one Heartbeat connection
--------------------------------------------------------------------------------

local targetFraction: number? = nil -- nil = indeterminate
local shownFraction = 0
local fading = false

local animation = RunService.Heartbeat:Connect(function(dt: number)
	if fading then
		return
	end
	local t = os.clock()
	-- Slow breathing pulse with the occasional dying-bulb stutter.
	local pulse = 0.5 + 0.5 * math.sin(t * 2.1)
	local stutter = math.noise(t * 3.1, 0.37, 0.5) > 0.38
	title.TextTransparency = if stutter then 0.78 else 0.08 + 0.4 * pulse
	titleStroke.Transparency = 0.25 + 0.5 * pulse
	glow.BackgroundTransparency = 0.15 + 0.25 * pulse

	local target = targetFraction
	if target == nil then
		shimmer.Visible = true
		fill.Visible = false
		shimmer.Position = UDim2.fromScale(((t * 0.55) % 1.4) - 0.3, 0)
	else
		shimmer.Visible = false
		fill.Visible = true
		shownFraction += (target - shownFraction) * (1 - math.exp(-6 * dt))
		fill.Size = UDim2.fromScale(math.clamp(shownFraction, 0, 1), 1)
	end
end)

--------------------------------------------------------------------------------
-- Wait for game.Loaded, then the shared modules are safe to require
--------------------------------------------------------------------------------

-- Everything after game.Loaded. Returns how long the finished curtain should hold before it lifts.
local function boot(): number
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end

	local Attributes = require(ReplicatedStorage.Shared.Attributes)
	local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
	local Instances = require(ReplicatedStorage.Shared.Instances)
	local Log = require(ReplicatedStorage.Shared.Util.Log)
	local Net = require(ReplicatedStorage.Shared.Net)
	local Strings = require(ReplicatedStorage.Shared.Strings)

	local log = Log.new("LoadingCurtain")
	local M = Attributes.Match
	local SCHOOL_NAME = Instances.Names.School
	local LOBBY_NAME = Instances.Names.Lobby

	title.Text = Strings.get("Boot.Generating")

	--------------------------------------------------------------------------------
	-- Incremental receipt counting
	--------------------------------------------------------------------------------

	type Tracked = {
		parts: { [BasePart]: boolean },
		count: number,
		connections: { RBXScriptConnection },
	}

	local tracked: { [Instance]: Tracked } = {}
	local received = 0

	local function isWorldRoot(instance: Instance): boolean
		return instance:IsA("Model") and (instance.Name == SCHOOL_NAME or instance.Name == LOBBY_NAME)
	end

	local function trackRoot(root: Instance)
		if tracked[root] then
			return
		end
		local entry: Tracked = { parts = {}, count = 0, connections = {} }
		tracked[root] = entry
		for _, descendant in root:GetDescendants() do
			if descendant:IsA("BasePart") then
				entry.parts[descendant] = true
				entry.count += 1
			end
		end
		received += entry.count
		table.insert(
			entry.connections,
			root.DescendantAdded:Connect(function(descendant: Instance)
				if descendant:IsA("BasePart") and not entry.parts[descendant] then
					entry.parts[descendant] = true
					entry.count += 1
					received += 1
				end
			end)
		)
		table.insert(
			entry.connections,
			root.DescendantRemoving:Connect(function(descendant: Instance)
				if descendant:IsA("BasePart") and entry.parts[descendant] then
					entry.parts[descendant] = nil
					entry.count -= 1
					received -= 1
				end
			end)
		)
	end

	local function untrackRoot(root: Instance)
		local entry = tracked[root]
		if not entry then
			return
		end
		tracked[root] = nil
		received -= entry.count
		for _, connection in entry.connections do
			connection:Disconnect()
		end
	end

	local function untrackAll()
		for root in table.clone(tracked) do
			untrackRoot(root)
		end
	end

	local rootAdded = Workspace.ChildAdded:Connect(function(child: Instance)
		if isWorldRoot(child) then
			trackRoot(child)
		end
	end)
	local rootRemoved = Workspace.ChildRemoved:Connect(function(child: Instance)
		untrackRoot(child)
	end)
	for _, child in Workspace:GetChildren() do
		if isWorldRoot(child) then
			trackRoot(child)
		end
	end

	--------------------------------------------------------------------------------
	-- Status
	--------------------------------------------------------------------------------

	local function bootError(): string?
		local value = ReplicatedStorage:GetAttribute(M.BootError)
		if type(value) == "string" and value ~= "" then
			return value
		end
		return nil
	end

	local function showBootError(): boolean
		local problem = bootError()
		if problem then
			detail.Text = Strings.get("Boot.Error", problem)
			return true
		end
		detail.Text = ""
		return false
	end

	local function worldReceived(): (boolean, number)
		local ready = ReplicatedStorage:GetAttribute(M.WorldReady) == true
		local expected = Attributes.getNumber(ReplicatedStorage, M.WorldPartCount, 0)
		if expected <= 0 then
			targetFraction = nil
			return ready, 0
		end
		local fraction = math.clamp(received / expected, 0, 1)
		targetFraction = fraction
		return ready and received >= expected * RECEIVE_FRACTION, fraction
	end

	--------------------------------------------------------------------------------
	-- Boot sequence
	--------------------------------------------------------------------------------

	local waitStarted = os.clock()
	local timedOut = false

	while true do
		local done, fraction = worldReceived()
		showBootError()
		if done then
			break
		end
		if not timedOut and os.clock() - waitStarted >= GameConfig.WorldReadyTimeout then
			timedOut = true
			log.warn(
				"world not received after %ds (%d parts, WorldReady=%s)",
				GameConfig.WorldReadyTimeout,
				received,
				tostring(ReplicatedStorage:GetAttribute(M.WorldReady))
			)
		end
		if timedOut then
			status.Text = Strings.get("Boot.Timeout")
		elseif targetFraction ~= nil then
			status.Text = Strings.get("Boot.Receiving", math.floor(fraction * 100))
		else
			status.Text = ""
		end
		task.wait(POLL_SECONDS)
	end

	local partCount = math.max(0, math.floor(received))
	rootAdded:Disconnect()
	rootRemoved:Disconnect()
	untrackAll()
	targetFraction = 1
	status.Text = Strings.get("Boot.Receiving", 100)

	-- Acknowledge the world. Net.Client.setup() waits for the server's remotes and is a no-op once ClientMain ran it.
	local acked = false
	xpcall(function()
		Net.Client.setup()
		local payload = { partCount = partCount }
		Net.Client.fire("ClientWorldReady", payload)
		acked = true
	end, function(err: any)
		log.error("could not acknowledge the world: %s", tostring(err))
	end)
	if acked then
		log.info("world received (%d parts)", partCount)
	end

	status.Text = ""
	title.Text = Strings.get("Boot.Ready")

	-- Lift once our character exists, so nobody sees the camera floating in the void before the spawn.
	local characterDeadline = os.clock() + CHARACTER_WAIT
	while os.clock() < characterDeadline do
		if Instances.characterRoot(localPlayer) then
			break
		end
		showBootError()
		task.wait(POLL_SECONDS)
	end

	return if showBootError() then ERROR_HOLD else READY_HOLD
end

-- A curtain that fails must not brick a working game: show the error, hold it, then lift anyway.
local hold = ERROR_HOLD * 2
xpcall(function()
	hold = boot()
end, function(err: any)
	detail.Text = tostring(err)
	warn("[C:LoadingCurtain] boot failed:", tostring(err), debug.traceback())
end)
task.wait(hold)

--------------------------------------------------------------------------------
-- Fade out and clean up
--------------------------------------------------------------------------------

fading = true
local fadeInfo = TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local tweens: { Tween } = {
	TweenService:Create(backdrop, fadeInfo, { BackgroundTransparency = 1 }),
	TweenService:Create(glow, fadeInfo, { BackgroundTransparency = 1 }),
	TweenService:Create(title, fadeInfo, { TextTransparency = 1 }),
	TweenService:Create(titleStroke, fadeInfo, { Transparency = 1 }),
	TweenService:Create(status, fadeInfo, { TextTransparency = 1 }),
	TweenService:Create(detail, fadeInfo, { TextTransparency = 1 }),
	TweenService:Create(progressTrack, fadeInfo, { BackgroundTransparency = 1 }),
	TweenService:Create(fill, fadeInfo, { BackgroundTransparency = 1 }),
}
for _, tween in tweens do
	tween:Play()
end
backdrop.Active = false
task.wait(FADE_SECONDS)
animation:Disconnect()
gui:Destroy()
