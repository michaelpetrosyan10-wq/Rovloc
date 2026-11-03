--!strict
-- PromptRenderer: the game's ProximityPrompts, drawn in the HUD's style and tuned per player.
--
--   * Adoption. Every prompt under an Interactable host (and any other prompt the engine shows) is switched to
--     Style = Custom on this client, so the engine stops drawing its own UI while still handling the keys.
--   * Per-player hold. The local HoldDuration is PerkConfig.holdSeconds(PromptKind, BaseHold, my Loadout) (the
--     screwdriver shortens Unscrew), recomputed when the loadout or the prompt's attributes change. The server
--     prompt keeps BaseHold and InteractionService times the channel with the same rule.
--   * Audience. A prompt whose Audience excludes me ("Self" needs the host's OwnerUserId to be me, "Others" needs it
--     not to be) is disabled locally, so the engine never offers it (two prompts on one trap share E; only the
--     right one may answer). The server's own Enabled writes are tracked and re-applied when the audience allows.
--   * Rendering. Shown prompts on the same attachment stack in one BillboardGui: a key glyph for the current input
--     (keyboard key, gamepad button, or a tap mark on touch) inside a hold ring, the object text above the action.
--     Rows fade in and out; the ring fills while holding and drains when released. On touch (and with a free
--     cursor) the row itself is the button: press = InputHoldBegin, release = InputHoldEnd.
--   * Walls. Every prompt is built with RequiresLineOfSight off (a prop's own parts must not hide its prompt), so a
--     prompt in range is tested here instead, BLOCK_SECONDS apart: a ray from the camera toward it through the world's
--     solid geometry (characters, the Creature, lockers and the prompt's own host left out), stopping THROUGH_SLACK
--     short of it (the counter under a flask, the wall a grate sits in). A prompt behind a wall is disabled locally the
--     same way as an audience refusal, so nothing is picked up or opened through a wall; InteractionService refuses it
--     too.
--   * Kinds. SetKindHidden(kind, true) disables every prompt of that PromptKind locally the same way, while it holds
--     (P8: a Revive prompt shows to Alive players only, so a downed or dead teammate never sees one).
--   * Teammates. While another player channels an Interactable host (ChannelActor / ChannelStartedAt /
--     ChannelDuration, server time) a quiet ring with their name shows their progress on it; never on a host inside
--     my own character (a teammate reviving me: my own HUD shows that, and the ring would sit on my camera).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Instances = require(ReplicatedStorage.Shared.Instances)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local PerkConfig = require(ReplicatedStorage.Shared.Config.PerkConfig)
local Tags = require(ReplicatedStorage.Shared.Tags)

local UIKit = require(script.Parent.UIKit)

local P = Attributes.Player
local W = Attributes.World
local Palette = UIKit.Palette

export type Context = {
	playerGui: Instance,
	scale: () -> number,
	device: () -> string,
}

export type PromptRenderer = {
	Update: (self: PromptRenderer, dt: number, hudAlpha: number) -> (),
	RefreshGlyphs: (self: PromptRenderer) -> (),
	SetKindHidden: (self: PromptRenderer, kind: string, hidden: boolean) -> (),
	Destroy: (self: PromptRenderer) -> (),
}

type Record = {
	prompt: ProximityPrompt,
	connections: { RBXScriptConnection },
	suppressed: boolean,
	serverEnabled: boolean,
	written: boolean?,
	blocked: boolean?, -- behind a wall from this camera
}

type Row = {
	prompt: ProximityPrompt,
	frame: Frame,
	ring: UIKit.Ring,
	keyCap: UIKit.KeyCap,
	object: TextLabel,
	action: TextLabel,
	button: TextButton,
	inputType: Enum.ProximityPromptInputType,
	alpha: number,
	shown: boolean,
	holding: boolean,
	holdStart: number,
	progress: number,
	flash: number,
	touch: InputObject?,
	watch: RBXScriptConnection?, -- follows the pressing touch until it lifts
	connections: { RBXScriptConnection },
}

type Group = {
	adornee: Instance,
	gui: BillboardGui,
	list: Frame,
	rows: { Row },
}

type Channel = {
	host: Instance,
	gui: BillboardGui,
	ring: UIKit.Ring,
	name: TextLabel,
	alpha: number,
	active: boolean,
}

type HostRecord = {
	host: Instance,
	connections: { RBXScriptConnection },
}

local ROW_WIDTH = 270
local ROW_HEIGHT = 54
local RING_SIZE = 46
local RING_THICKNESS = 2
local CAP_SIZE = 34
local CHANNEL_SIZE = 44
local FADE_IN = 9
local FADE_OUT = 7
local DRAIN = 5
local HOLD_EPSILON = 1e-3
local BLOCK_SECONDS = 0.2 -- how often the prompts in range are tested for a wall in the way
local BLOCK_RANGE_SLACK = 4 -- studs past a prompt's MaxActivationDistance (measured from the camera) still tested
local THROUGH_SLACK = 1.5 -- the ray stops this short of the prompt

local PromptRenderer = {}

--------------------------------------------------------------------------------
-- Pure rules (specced)
--------------------------------------------------------------------------------

-- Whether a prompt with `audience` on a host owned by `ownerUserId` is for the player `myUserId`.
-- A prompt's world position (its Attachment, BasePart or Model), or nil.
function PromptRenderer.positionOf(prompt: ProximityPrompt): Vector3?
	local parent = prompt.Parent
	if parent and parent:IsA("Attachment") then
		return parent.WorldPosition
	elseif parent and parent:IsA("BasePart") then
		return parent.Position
	elseif parent and parent:IsA("Model") then
		return parent:GetPivot().Position
	end
	return nil
end

function PromptRenderer.audienceAllows(audience: unknown, ownerUserId: unknown, myUserId: number): boolean
	local owner = if type(ownerUserId) == "number" and ownerUserId ~= 0 then ownerUserId else nil
	if audience == "Self" then
		return owner ~= nil and owner == myUserId
	elseif audience == "Others" then
		return owner ~= myUserId
	end
	return true
end

-- The local hold time of a prompt: the shared perk rule over its kind and BaseHold; `fallback` when it carries no
-- BaseHold (a prompt PropKit did not build).
function PromptRenderer.holdSeconds(kind: unknown, baseHold: unknown, loadout: unknown, fallback: number): number
	if type(baseHold) ~= "number" or baseHold ~= baseHold or baseHold < 0 then
		return math.max(0, fallback)
	end
	local promptKind = if type(kind) == "string" then kind else ""
	return math.max(0, PerkConfig.holdSeconds(promptKind, baseHold, PerkConfig.parseLoadout(loadout)))
end

-- A teammate channel's progress (0..1) at server time `now`.
function PromptRenderer.channelProgress(startedAt: number, duration: number, now: number): number
	if duration <= 0 then
		return 1
	end
	return math.clamp((now - startedAt) / duration, 0, 1)
end

-- The glyph a prompt shows for an engine input type.
function PromptRenderer.glyphKind(inputType: Enum.ProximityPromptInputType): UIKit.GlyphKind
	if inputType == Enum.ProximityPromptInputType.Gamepad then
		return "Gamepad"
	elseif inputType == Enum.ProximityPromptInputType.Touch then
		return "Touch"
	end
	return "Keyboard"
end

-- The engine input type matching a HUD device.
function PromptRenderer.inputTypeFor(device: string): Enum.ProximityPromptInputType
	if device == "Gamepad" then
		return Enum.ProximityPromptInputType.Gamepad
	elseif device == "Touch" then
		return Enum.ProximityPromptInputType.Touch
	end
	return Enum.ProximityPromptInputType.Keyboard
end

--------------------------------------------------------------------------------
-- Mount
--------------------------------------------------------------------------------

local function interactableHost(instance: Instance): Instance?
	local node: Instance? = instance
	while node do
		if node:HasTag(Tags.Interactable) then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- OwnerUserId on the prompt itself, else on its nearest ancestor up to (and including) the Interactable host.
local function ownerOf(prompt: ProximityPrompt): unknown
	local node: Instance? = prompt
	while node do
		local owner = node:GetAttribute(W.OwnerUserId)
		if owner ~= nil then
			return owner
		end
		if node:HasTag(Tags.Interactable) then
			return nil
		end
		node = node.Parent
	end
	return nil
end

local function adorneeOf(prompt: ProximityPrompt): Instance?
	local parent = prompt.Parent
	if parent and (parent:IsA("BasePart") or parent:IsA("Attachment")) then
		return parent
	end
	return nil
end

local function firstPromptAnchor(host: Instance): Instance?
	if host:IsA("BasePart") or host:IsA("Attachment") then
		return host
	end
	for _, descendant in host:GetDescendants() do
		if descendant:IsA("ProximityPrompt") then
			local adornee = adorneeOf(descendant)
			if adornee then
				return adornee
			end
		end
	end
	if host:IsA("Model") then
		return host.PrimaryPart
	end
	return nil
end

local function billboard(name: string, adornee: Instance, playerGui: Instance): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Active = true
	gui.ClipsDescendants = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.MaxDistance = math.huge
	gui.Adornee = adornee
	gui.Parent = playerGui
	return gui
end

function PromptRenderer.mount(ctx: Context): PromptRenderer
	local localPlayer = Players.LocalPlayer
	local myUserId = if localPlayer then localPlayer.UserId else 0

	local records: { [ProximityPrompt]: Record } = {}
	local blockClock = 0
	local hosts: { [Instance]: HostRecord } = {}
	local groups: { [Instance]: Group } = {}
	local rowsByPrompt: { [ProximityPrompt]: Row } = {}
	local channels: { [Instance]: Channel } = {}
	local serviceConnections: { RBXScriptConnection } = {}
	local hiddenKinds: { [string]: boolean } = {}
	local visible = true
	local scale = 1

	------------------------------------------------------------------ prompt state

	local function writeEnabled(record: Record, value: boolean)
		record.written = value
		if record.prompt.Enabled ~= value then
			record.prompt.Enabled = value
		end
	end

	local function applyAudience(record: Record)
		local prompt = record.prompt
		local kind = prompt:GetAttribute(W.PromptKind)
		local allowed = PromptRenderer.audienceAllows(prompt:GetAttribute(W.Audience), ownerOf(prompt), myUserId)
			and not (type(kind) == "string" and hiddenKinds[kind] == true)
			and record.blocked ~= true
		if allowed then
			if record.suppressed then
				record.suppressed = false
				writeEnabled(record, record.serverEnabled)
			end
		else
			if not record.suppressed then
				record.suppressed = true
				record.serverEnabled = prompt.Enabled
			end
			writeEnabled(record, false)
		end
	end

	local function applyHold(record: Record)
		local prompt = record.prompt
		local loadout = if localPlayer then localPlayer:GetAttribute(P.Loadout) else nil
		local target = PromptRenderer.holdSeconds(
			prompt:GetAttribute(W.PromptKind),
			prompt:GetAttribute(W.BaseHold),
			loadout,
			prompt.HoldDuration
		)
		if math.abs(prompt.HoldDuration - target) > HOLD_EPSILON then
			prompt.HoldDuration = target
		end
	end

	local function applyStyle(prompt: ProximityPrompt)
		if prompt.Style ~= Enum.ProximityPromptStyle.Custom then
			prompt.Style = Enum.ProximityPromptStyle.Custom
		end
	end

	local function onEnabledChanged(record: Record)
		local value = record.prompt.Enabled
		if record.written ~= nil and value == record.written then
			return -- the echo of our own write
		end
		record.serverEnabled = value
		record.written = nil
		if record.suppressed and value then
			writeEnabled(record, false)
		end
	end

	local forget: (prompt: ProximityPrompt) -> ()

	local function adopt(prompt: ProximityPrompt)
		if records[prompt] then
			return
		end
		local record: Record = {
			prompt = prompt,
			connections = {},
			suppressed = false,
			serverEnabled = prompt.Enabled,
			written = nil,
		}
		records[prompt] = record
		applyStyle(prompt)
		local function refresh()
			applyHold(record)
			applyAudience(record)
		end
		table.insert(record.connections, prompt:GetAttributeChangedSignal(W.Audience):Connect(refresh))
		table.insert(record.connections, prompt:GetAttributeChangedSignal(W.OwnerUserId):Connect(refresh))
		table.insert(record.connections, prompt:GetAttributeChangedSignal(W.PromptKind):Connect(refresh))
		table.insert(record.connections, prompt:GetAttributeChangedSignal(W.BaseHold):Connect(refresh))
		table.insert(
			record.connections,
			prompt:GetPropertyChangedSignal("Enabled"):Connect(function()
				onEnabledChanged(record)
			end)
		)
		table.insert(
			record.connections,
			prompt:GetPropertyChangedSignal("HoldDuration"):Connect(function()
				applyHold(record)
			end)
		)
		table.insert(
			record.connections,
			prompt:GetPropertyChangedSignal("Style"):Connect(function()
				applyStyle(prompt)
			end)
		)
		table.insert(
			record.connections,
			prompt.AncestryChanged:Connect(function()
				if not prompt:IsDescendantOf(game) then
					forget(prompt)
				end
			end)
		)
		refresh()
	end

	local function refreshUnder(root: Instance)
		for _, descendant in root:GetDescendants() do
			if descendant:IsA("ProximityPrompt") then
				local record = records[descendant]
				if record then
					applyHold(record)
					applyAudience(record)
				end
			end
		end
	end

	------------------------------------------------------------------ rows

	local function groupFor(adornee: Instance): Group
		local existing = groups[adornee]
		if existing then
			return existing
		end
		local gui = billboard("Prompt", adornee, ctx.playerGui)
		local list = UIKit.frame(gui, "Rows")
		UIKit.list(list, Enum.FillDirection.Vertical, 0, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
		local uiScale = Instance.new("UIScale")
		uiScale.Name = "Scale"
		uiScale.Scale = scale
		uiScale.Parent = list
		local group: Group = { adornee = adornee, gui = gui, list = list, rows = {} }
		groups[adornee] = group
		return group
	end

	local function layoutGroup(group: Group)
		local count = #group.rows
		group.gui.Size = UDim2.fromOffset(ROW_WIDTH * scale, ROW_HEIGHT * math.max(count, 1) * scale)
		group.list.Size = UDim2.fromScale(1 / scale, 1 / scale)
		local uiScale = group.list:FindFirstChild("Scale")
		if uiScale and uiScale:IsA("UIScale") and math.abs(uiScale.Scale - scale) > 1e-3 then
			uiScale.Scale = scale
		end
		-- The engine's own prompt UI applies UIOffset (pixels) as a SizeOffset of its billboard.
		local first = group.rows[1]
		local offset = if first then first.prompt.UIOffset else Vector2.zero
		local size = group.gui.Size
		group.gui.SizeOffset = Vector2.new(offset.X / size.X.Offset, offset.Y / size.Y.Offset)
		group.gui.Enabled = visible
	end

	local function releaseTouch(row: Row)
		local watch = row.watch
		if watch then
			row.watch = nil
			watch:Disconnect()
		end
		if row.touch then
			row.touch = nil
			if row.prompt.Parent then
				row.prompt:InputHoldEnd()
			end
		end
	end

	local function destroyRow(row: Row)
		releaseTouch(row)
		for _, connection in row.connections do
			connection:Disconnect()
		end
		row.frame:Destroy()
		if rowsByPrompt[row.prompt] == row then
			rowsByPrompt[row.prompt] = nil
		end
		for adornee, group in groups do
			local index = table.find(group.rows, row)
			if index then
				table.remove(group.rows, index)
				if #group.rows == 0 then
					group.gui:Destroy()
					groups[adornee] = nil
				else
					layoutGroup(group)
				end
				break
			end
		end
	end

	local function buildRow(group: Group, prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType): Row
		local frame = UIKit.frame(group.list, "Row")
		frame.Size = UDim2.fromOffset(ROW_WIDTH, ROW_HEIGHT)
		frame.LayoutOrder = #group.rows + 1

		local ring = UIKit.ring(frame, "Ring", RING_SIZE, RING_THICKNESS, Palette.Bone)
		ring.root.AnchorPoint = Vector2.new(0, 0.5)
		ring.root.Position = UDim2.new(0, 0, 0.5, 0)
		local keyCap = UIKit.keyCap(ring.root, "Key", CAP_SIZE)
		keyCap.root.AnchorPoint = Vector2.new(0.5, 0.5)
		keyCap.root.Position = UDim2.fromScale(0.5, 0.5)

		local textColumn = UIKit.frame(frame, "Text")
		textColumn.Position = UDim2.fromOffset(RING_SIZE + 12, 0)
		textColumn.Size = UDim2.new(1, -(RING_SIZE + 12), 1, 0)
		local object = UIKit.label(textColumn, "Object", UIKit.Fonts.Strong, UIKit.TextSize.Caps, Palette.Ash)
		object.TextXAlignment = Enum.TextXAlignment.Left
		object.TextYAlignment = Enum.TextYAlignment.Bottom
		object.TextWrapped = false
		object.TextTruncate = Enum.TextTruncate.AtEnd
		object.Size = UDim2.new(1, 0, 0.5, -1)
		UIKit.textStroke(object, 0.45)
		local action = UIKit.label(textColumn, "Action", UIKit.Fonts.Body, 17, Palette.Bone)
		action.TextXAlignment = Enum.TextXAlignment.Left
		action.TextYAlignment = Enum.TextYAlignment.Top
		action.TextWrapped = false
		action.TextTruncate = Enum.TextTruncate.AtEnd
		action.Position = UDim2.fromScale(0, 0.5)
		action.Size = UDim2.new(1, 0, 0.5, 0)
		UIKit.textStroke(action, 0.35)

		local button = Instance.new("TextButton")
		button.Name = "Hit"
		button.BackgroundTransparency = 1
		button.Text = ""
		button.AutoButtonColor = false
		button.Selectable = false
		button.Size = UDim2.new(0, RING_SIZE + 12 + 150, 1, 0)
		button.ZIndex = 5
		button.Parent = frame

		local row: Row = {
			prompt = prompt,
			frame = frame,
			ring = ring,
			keyCap = keyCap,
			object = object,
			action = action,
			button = button,
			inputType = inputType,
			alpha = 0,
			shown = true,
			holding = false,
			holdStart = 0,
			progress = 0,
			flash = 0,
			touch = nil,
			watch = nil,
			connections = {},
		}
		table.insert(
			row.connections,
			button.InputBegan:Connect(function(input: InputObject)
				local kind = input.UserInputType
				if row.touch or not row.shown then
					return
				end
				if kind == Enum.UserInputType.Touch or kind == Enum.UserInputType.MouseButton1 then
					row.touch = input
					prompt:InputHoldBegin()
					row.watch = input:GetPropertyChangedSignal("UserInputState"):Connect(function()
						local state = input.UserInputState
						local lifted = state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel
						if lifted and row.touch == input then
							releaseTouch(row)
						end
					end)
				end
			end)
		)
		keyCap:SetGlyph(PromptRenderer.glyphKind(inputType), nil)
		return row
	end

	local function setGlyph(row: Row)
		local kind: UIKit.GlyphKind = PromptRenderer.glyphKind(row.inputType)
		local keyCode: Enum.KeyCode? = nil
		if kind == "Keyboard" then
			keyCode = row.prompt.KeyboardKeyCode
		elseif kind == "Gamepad" then
			keyCode = row.prompt.GamepadKeyCode
		end
		row.keyCap:SetGlyph(kind, keyCode)
	end

	local function showRow(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType)
		local adornee = adorneeOf(prompt)
		if not adornee then
			return
		end
		local row = rowsByPrompt[prompt]
		if row then
			row.shown = true
			row.inputType = inputType
			setGlyph(row)
			return
		end
		local group = groupFor(adornee)
		local created = buildRow(group, prompt, inputType)
		table.insert(group.rows, created)
		rowsByPrompt[prompt] = created
		setGlyph(created)
		layoutGroup(group)
	end

	local function hideRow(prompt: ProximityPrompt)
		local row = rowsByPrompt[prompt]
		if row then
			row.shown = false
			row.holding = false
			releaseTouch(row)
		end
	end

	forget = function(prompt: ProximityPrompt)
		local record = records[prompt]
		if record then
			records[prompt] = nil
			for _, connection in record.connections do
				connection:Disconnect()
			end
		end
		local row = rowsByPrompt[prompt]
		if row then
			destroyRow(row)
		end
	end

	------------------------------------------------------------------ channels

	local function channelFor(host: Instance): Channel?
		local existing = channels[host]
		if existing then
			return existing
		end
		local anchor = firstPromptAnchor(host)
		if not anchor then
			return nil
		end
		local gui = billboard("Channel", anchor, ctx.playerGui)
		gui.Enabled = visible
		gui.Size = UDim2.fromOffset(CHANNEL_SIZE * 3 * scale, (CHANNEL_SIZE + 22) * scale)
		gui.StudsOffset = Vector3.new(0, 1.6, 0)
		gui.Active = false
		local content = UIKit.frame(gui, "Content")
		local uiScale = Instance.new("UIScale")
		uiScale.Scale = scale
		uiScale.Parent = content
		content.Size = UDim2.fromScale(1 / scale, 1 / scale)
		local ring = UIKit.ring(content, "Ring", CHANNEL_SIZE, 3, Palette.Bone)
		ring.root.AnchorPoint = Vector2.new(0.5, 0)
		ring.root.Position = UDim2.fromScale(0.5, 0)
		local name = UIKit.label(content, "Name", UIKit.Fonts.Strong, UIKit.TextSize.Caps, Palette.Ash)
		name.AnchorPoint = Vector2.new(0.5, 1)
		name.Position = UDim2.fromScale(0.5, 1)
		name.Size = UDim2.new(1, 0, 0, 16)
		name.TextWrapped = false
		name.TextTruncate = Enum.TextTruncate.AtEnd
		UIKit.textStroke(name, 0.4)
		local channel: Channel = { host = host, gui = gui, ring = ring, name = name, alpha = 0, active = true }
		channels[host] = channel
		return channel
	end

	local function refreshChannel(host: Instance)
		local actor = host:GetAttribute(W.ChannelActor)
		local isOther = type(actor) == "number" and actor ~= 0 and actor ~= myUserId
		local duration = Attributes.getNumber(host, W.ChannelDuration, 0)
		local character = if localPlayer then localPlayer.Character else nil
		local onMe = character ~= nil and host:IsDescendantOf(character)
		if isOther and duration > 0 and not onMe then
			local channel = channelFor(host)
			if channel then
				channel.active = true
				local actorPlayer = Players:GetPlayerByUserId(actor :: number)
				channel.name.Text = if actorPlayer then actorPlayer.DisplayName else ""
			end
		else
			local channel = channels[host]
			if channel then
				channel.active = false
			end
		end
	end

	------------------------------------------------------------------ hosts

	local function addHost(host: Instance)
		if hosts[host] then
			return
		end
		local record: HostRecord = { host = host, connections = {} }
		hosts[host] = record
		for _, descendant in host:GetDescendants() do
			if descendant:IsA("ProximityPrompt") then
				adopt(descendant)
			end
		end
		table.insert(
			record.connections,
			host.DescendantAdded:Connect(function(descendant: Instance)
				if descendant:IsA("ProximityPrompt") then
					adopt(descendant)
				end
			end)
		)
		table.insert(
			record.connections,
			host:GetAttributeChangedSignal(W.OwnerUserId):Connect(function()
				refreshUnder(host)
			end)
		)
		for _, key in { W.ChannelActor, W.ChannelStartedAt, W.ChannelDuration } do
			table.insert(
				record.connections,
				host:GetAttributeChangedSignal(key):Connect(function()
					refreshChannel(host)
				end)
			)
		end
		refreshChannel(host)
	end

	local function removeHost(host: Instance)
		local record = hosts[host]
		if not record then
			return
		end
		hosts[host] = nil
		for _, connection in record.connections do
			connection:Disconnect()
		end
		local channel = channels[host]
		if channel then
			channel.gui:Destroy()
			channels[host] = nil
		end
	end

	------------------------------------------------------------------ wiring

	table.insert(serviceConnections, CollectionService:GetInstanceAddedSignal(Tags.Interactable):Connect(addHost))
	table.insert(serviceConnections, CollectionService:GetInstanceRemovedSignal(Tags.Interactable):Connect(removeHost))
	for _, host in CollectionService:GetTagged(Tags.Interactable) do
		addHost(host)
	end

	table.insert(
		serviceConnections,
		ProximityPromptService.PromptShown:Connect(
			function(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType)
				if not records[prompt] then
					-- Shown before we saw it: the engine already drew its default UI for this showing, so it keeps
					-- that one; from the next showing on the prompt is ours.
					adopt(prompt)
					local host = interactableHost(prompt)
					if host then
						addHost(host)
					end
					return
				end
				if prompt.Style == Enum.ProximityPromptStyle.Custom then
					showRow(prompt, inputType)
				end
			end
		)
	)
	table.insert(serviceConnections, ProximityPromptService.PromptHidden:Connect(hideRow))
	table.insert(
		serviceConnections,
		ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt: ProximityPrompt, player: Player)
			local row = rowsByPrompt[prompt]
			if row and player == localPlayer then
				row.holding = true
				row.holdStart = os.clock()
			end
		end)
	)
	table.insert(
		serviceConnections,
		ProximityPromptService.PromptButtonHoldEnded:Connect(function(prompt: ProximityPrompt, player: Player)
			local row = rowsByPrompt[prompt]
			if row and player == localPlayer then
				row.holding = false
			end
		end)
	)
	table.insert(
		serviceConnections,
		ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
			local row = rowsByPrompt[prompt]
			if row and player == localPlayer then
				row.flash = 1
				row.progress = 1
			end
		end)
	)
	if localPlayer then
		table.insert(
			serviceConnections,
			localPlayer:GetAttributeChangedSignal(P.Loadout):Connect(function()
				for _, record in records do
					applyHold(record)
				end
			end)
		)
	end

	------------------------------------------------------------------ frame

	local handle = {} :: PromptRenderer

	-- The prompts in range tested for a wall in the way (see the header).
	local function updateBlocked()
		local camera = Workspace.CurrentCamera
		local character = if localPlayer then localPlayer.Character else nil
		if not camera then
			return
		end
		local eye = camera.CFrame.Position
		local exclude: { Instance } = {}
		for _, other in Players:GetPlayers() do
			if other.Character then
				table.insert(exclude, other.Character)
			end
		end
		local creature = Instances.creature()
		if creature then
			table.insert(exclude, creature)
		end
		table.insert(exclude, Instances.cosmetic())
		for _, locker in CollectionService:GetTagged(Tags.HideableLocker) do
			table.insert(exclude, locker)
		end
		for _, record in records do
			local prompt = record.prompt
			local position = PromptRenderer.positionOf(prompt)
			local blocked = false
			if position and character then
				local reach = (position - eye).Magnitude
				if reach <= prompt.MaxActivationDistance + BLOCK_RANGE_SLACK and reach > THROUGH_SLACK then
					local host = interactableHost(prompt)
					local params = RaycastParams.new()
					params.FilterType = Enum.RaycastFilterType.Exclude
					local list = table.clone(exclude)
					if host then
						table.insert(list, host)
					end
					params.FilterDescendantsInstances = list
					local direction = (position - eye).Unit * (reach - THROUGH_SLACK)
					blocked = Workspace:Raycast(eye, direction, params) ~= nil
				end
			end
			if (record.blocked == true) ~= blocked then
				record.blocked = blocked
				applyAudience(record)
			end
		end
	end

	function handle.Update(_self: PromptRenderer, dt: number, hudAlpha: number)
		blockClock += dt
		if blockClock >= BLOCK_SECONDS then
			blockClock = 0
			updateBlocked()
		end
		local nextScale = ctx.scale()
		if math.abs(nextScale - scale) > 1e-3 then
			scale = nextScale
			for _, group in groups do
				layoutGroup(group)
			end
		end
		local enabled = hudAlpha > 0.01
		if enabled ~= visible then
			visible = enabled
			for _, group in groups do
				group.gui.Enabled = enabled
			end
			for _, channel in channels do
				channel.gui.Enabled = enabled
			end
		end
		local now = os.clock()
		local finished: { Row }? = nil
		for _, row in rowsByPrompt do
			local target = if row.shown then 1 else 0
			row.alpha = MathUtil.approach(row.alpha, target, (if row.shown then FADE_IN else FADE_OUT) * dt)
			if not row.shown and row.alpha <= 0 then
				local list = finished or {}
				table.insert(list, row)
				finished = list
				continue
			end
			local prompt = row.prompt
			local hold = prompt.HoldDuration
			if row.holding and hold > 0 then
				row.progress = math.clamp((now - row.holdStart) / hold, 0, 1)
			elseif row.flash <= 0 then
				row.progress = math.max(0, row.progress - DRAIN * dt)
			end
			row.flash = math.max(0, row.flash - 3 * dt)

			local alpha = MathUtil.smoothstep(0, 1, row.alpha) * hudAlpha
			row.ring:SetProgress(if hold > 0 or row.flash > 0 then row.progress else 0)
			row.ring:SetColor(Palette.Bone:Lerp(Palette.Amber, math.max(row.progress, row.flash)))
			row.ring:SetAlpha(alpha)
			row.keyCap:SetAlpha(alpha)
			if row.object.Text ~= prompt.ObjectText then
				row.object.Text = prompt.ObjectText
			end
			if row.action.Text ~= prompt.ActionText then
				row.action.Text = prompt.ActionText
			end
			UIKit.setTextTransparency(row.object, UIKit.fade(0.05, alpha))
			UIKit.setTextTransparency(row.action, UIKit.fade(0, alpha))
			row.action.TextColor3 = Palette.Bone:Lerp(Palette.Amber, row.flash)
		end
		if finished then
			for _, row in finished do
				destroyRow(row)
			end
		end

		local serverNow = Workspace:GetServerTimeNow()
		local ended: { Instance }? = nil
		for host, channel in channels do
			channel.alpha = MathUtil.approach(channel.alpha, if channel.active then 1 else 0, FADE_IN * dt)
			if not channel.active and channel.alpha <= 0 then
				local list = ended or {}
				table.insert(list, host)
				ended = list
				continue
			end
			local progress = PromptRenderer.channelProgress(
				Attributes.getNumber(host, W.ChannelStartedAt, serverNow),
				Attributes.getNumber(host, W.ChannelDuration, 0),
				serverNow
			)
			local alpha = channel.alpha * hudAlpha
			channel.ring:SetProgress(progress)
			channel.ring:SetAlpha(alpha * 0.85)
			UIKit.setTextTransparency(channel.name, UIKit.fade(0.15, alpha))
		end
		if ended then
			for _, host in ended do
				local channel = channels[host]
				if channel then
					channel.gui:Destroy()
					channels[host] = nil
				end
			end
		end
	end

	function handle.SetKindHidden(_self: PromptRenderer, kind: string, hidden: boolean)
		if (hiddenKinds[kind] == true) == hidden then
			return
		end
		if hidden then
			hiddenKinds[kind] = true
		else
			hiddenKinds[kind] = nil
		end
		for _, record in records do
			if record.prompt:GetAttribute(W.PromptKind) == kind then
				applyAudience(record)
			end
		end
	end

	function handle.RefreshGlyphs(_self: PromptRenderer)
		local inputType = PromptRenderer.inputTypeFor(ctx.device())
		for _, row in rowsByPrompt do
			if row.inputType ~= inputType then
				row.inputType = inputType
				setGlyph(row)
			end
		end
	end

	function handle.Destroy(_self: PromptRenderer)
		for _, connection in serviceConnections do
			connection:Disconnect()
		end
		for host in table.clone(hosts) do
			removeHost(host)
		end
		for prompt in table.clone(records) do
			forget(prompt)
		end
	end

	return handle
end

return table.freeze(PromptRenderer)
