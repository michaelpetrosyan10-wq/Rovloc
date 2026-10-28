--!strict
-- Captions: what a sound was, for players who cannot hear it (the Captions setting).
--
--   * Every captioned preset that starts on this client (SoundSynthesizer.Captioned: captionKey, preset) becomes a
--     line of Strings.get(captionKey). The same caption again within DEDUPE seconds refreshes its line instead of
--     stacking a copy (a dripping pipe is one line, not a column). At most MAX_LINES show; the oldest gives way.
--   * Lines fade in, hold, and fade out; Creature sounds carry a thin blood-red tick so danger reads at a glance.
--   * Turning the setting off clears every line at once.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundSynthesizer = require(ReplicatedStorage.Shared.Audio.SoundSynthesizer)
local Strings = require(ReplicatedStorage.Shared.Strings)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)

local UIKit = require(script.Parent.UIKit)

local Palette = UIKit.Palette

export type Line = {
	key: string,
	preset: string,
	bornAt: number,
	refreshedAt: number,
	id: number,
}

export type Context = {
	root: Instance, -- the HUD's centre column
	enabled: () -> boolean,
}

export type Captions = {
	Update: (self: Captions, dt: number, hudAlpha: number) -> (),
	Clear: (self: Captions) -> (),
	Destroy: (self: Captions) -> (),
}

type View = {
	line: Line,
	frame: Frame,
	label: TextLabel,
	tick: Frame,
}

local DEDUPE = 1.5
local MAX_LINES = 3
local HOLD = 3.2
local FADE_IN = 0.2
local FADE_OUT = 0.7
local LINE_HEIGHT = 26

local Captions = {}

Captions.Dedupe = DEDUPE
Captions.MaxLines = MAX_LINES

--------------------------------------------------------------------------------
-- Pure rules (specced)
--------------------------------------------------------------------------------

-- Adds a caption at `now` to `lines` (oldest first), in place: a repeat within DEDUPE refreshes its line; otherwise a
-- new line is appended and the oldest dropped past MAX_LINES. Returns the line that now carries the caption.
function Captions.push(lines: { Line }, key: string, preset: string, now: number, nextId: number): Line
	for _, line in lines do
		if line.key == key and now - line.refreshedAt <= DEDUPE then
			line.refreshedAt = now
			return line
		end
	end
	local line: Line = { key = key, preset = preset, bornAt = now, refreshedAt = now, id = nextId }
	table.insert(lines, line)
	while #lines > MAX_LINES do
		table.remove(lines, 1)
	end
	return line
end

-- Drops lines whose fade-out has finished, in place.
function Captions.expire(lines: { Line }, now: number)
	local index = 1
	while index <= #lines do
		if now - lines[index].refreshedAt >= HOLD + FADE_OUT then
			table.remove(lines, index)
		else
			index += 1
		end
	end
end

-- A line's visibility at `now`: fades in from bornAt, holds HOLD seconds past its last refresh, then fades out.
function Captions.alpha(line: Line, now: number): number
	local fadeIn = math.clamp((now - line.bornAt) / FADE_IN, 0, 1)
	local sinceRefresh = now - line.refreshedAt
	local fadeOut = if sinceRefresh <= HOLD then 1 else math.clamp(1 - (sinceRefresh - HOLD) / FADE_OUT, 0, 1)
	return math.min(fadeIn, fadeOut)
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

local function isCreature(preset: string): boolean
	local data = SynthPresets.get(preset)
	return data ~= nil and data.bus == "Monster"
end

local function buildView(parent: Instance, line: Line): View
	local frame = UIKit.fill(parent, "Caption", Palette.Ink, 1)
	frame.AutomaticSize = Enum.AutomaticSize.X
	frame.Size = UDim2.fromOffset(0, LINE_HEIGHT)
	frame.LayoutOrder = line.id
	UIKit.corner(frame, UDim.new(0, 4))
	UIKit.padding(frame, 10, 0)

	local tick = UIKit.fill(frame, "Tick", Palette.Blood, 1)
	tick.AnchorPoint = Vector2.new(0, 0.5)
	tick.Position = UDim2.new(0, -6, 0.5, 0)
	tick.Size = UDim2.fromOffset(2, 12)
	tick.Visible = isCreature(line.preset)

	local label = UIKit.label(frame, "Text", UIKit.Fonts.Body, UIKit.TextSize.Body, Palette.Bone)
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromScale(0, 1)
	label.TextWrapped = false
	label.Text = Strings.get(line.key)
	label.TextTransparency = 1
	return { line = line, frame = frame, label = label, tick = tick }
end

function Captions.mount(ctx: Context): Captions
	local column = UIKit.frame(ctx.root, "Captions")
	column.LayoutOrder = 3
	column.AutomaticSize = Enum.AutomaticSize.Y
	column.Size = UDim2.fromScale(1, 0)
	UIKit.list(column, Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Bottom)

	local lines: { Line } = {}
	local views: { [Line]: View } = {}
	local nextId = 0
	local clock = 0

	local connection = SoundSynthesizer.Captioned:Connect(function(captionKey: string, preset: string)
		if not ctx.enabled() or not Strings.has(captionKey) then
			return
		end
		nextId += 1
		Captions.push(lines, captionKey, preset, clock, nextId)
	end)

	local handle = {} :: Captions

	function handle.Update(_self: Captions, dt: number, hudAlpha: number)
		clock += dt
		if #lines > 0 and not ctx.enabled() then
			table.clear(lines)
		end
		Captions.expire(lines, clock)
		local live: { [Line]: boolean } = {}
		for _, line in lines do
			live[line] = true
			local view = views[line]
			if not view then
				view = buildView(column, line)
				views[line] = view
			end
			local shown = Captions.alpha(line, clock) * hudAlpha
			UIKit.setTransparency(view.frame, UIKit.fade(0.42, shown))
			UIKit.setTextTransparency(view.label, UIKit.fade(0.05, shown))
			if view.tick.Visible then
				UIKit.setTransparency(view.tick, UIKit.fade(0, shown))
			end
		end
		for line, view in views do
			if not live[line] then
				view.frame:Destroy()
				views[line] = nil
			end
		end
	end

	function handle.Clear(_self: Captions)
		table.clear(lines)
	end

	function handle.Destroy(_self: Captions)
		connection:Disconnect()
		column:Destroy()
	end

	return handle
end

return table.freeze(Captions)
