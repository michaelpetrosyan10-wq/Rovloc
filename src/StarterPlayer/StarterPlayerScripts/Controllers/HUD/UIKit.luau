--!strict
-- UIKit: the HUD's procedural primitives and its look. No images anywhere: Frames, UICorner, UIStroke, UIGradient and
-- TextLabels with built-in fonts.
--
-- Look. Near-black, desaturated panels with a faint warm grain; bone-white text; one restrained accent per meaning
-- (amber light, moss stamina, cold cyan air, blood for danger). Titles and narrative hints use a typewriter face, data
-- and controls a clean sans. Everything fades rather than pops.
--
-- Primitives. Components return a small handle with setters, so owners animate them per frame without touching the
-- instance tree: meterBar, ring (a progress ring from two clipped halves, each a full ring masked by a hard-edged
-- UIGradient rotated with the progress), keyCap (keyboard key, gamepad button, d-pad or a touch "tap" mark), round
-- touch buttons, slider and toggle visuals, vignette edges and the grain overlay.
--
-- Sizes are design pixels at UI scale 1; the HUD root carries a UIScale from `scaleFor(viewport)`, so text and hit
-- targets grow on large screens and never shrink below the 44 px touch minimum on phones.

local UserInputService = game:GetService("UserInputService")

local UIKit = {}

UIKit.Palette = table.freeze({
	Ink = Color3.fromRGB(8, 8, 9),
	Panel = Color3.fromRGB(15, 14, 15),
	Raised = Color3.fromRGB(26, 24, 24),
	Track = Color3.fromRGB(40, 37, 35),
	Stroke = Color3.fromRGB(84, 77, 68),
	StrokeDim = Color3.fromRGB(48, 45, 42),
	Bone = Color3.fromRGB(208, 201, 188),
	Ash = Color3.fromRGB(134, 128, 118),
	Smoke = Color3.fromRGB(92, 88, 82),
	Blood = Color3.fromRGB(142, 24, 20),
	Ember = Color3.fromRGB(198, 58, 40),
	Amber = Color3.fromRGB(204, 158, 88),
	Moss = Color3.fromRGB(150, 158, 132),
	Cyan = Color3.fromRGB(110, 148, 160),
	Grain = Color3.fromRGB(255, 238, 214),
	GamepadA = Color3.fromRGB(126, 168, 112),
	GamepadB = Color3.fromRGB(196, 96, 82),
	GamepadX = Color3.fromRGB(104, 140, 186),
	GamepadY = Color3.fromRGB(206, 178, 98),
})

UIKit.Fonts = table.freeze({
	Title = Font.fromEnum(Enum.Font.SpecialElite),
	Body = Font.fromEnum(Enum.Font.BuilderSansMedium),
	Strong = Font.fromEnum(Enum.Font.BuilderSansBold),
	Heavy = Font.fromEnum(Enum.Font.BuilderSansExtraBold),
})

UIKit.TextSize = table.freeze({
	Caps = 11, -- small all-caps labels (meter names)
	Small = 13,
	Body = 15,
	Hint = 19,
	Title = 26,
	Display = 40,
})

UIKit.MinTouchTarget = 44
-- The smallest glyph label a key cap or pill draws (design px): a long label widens its cap instead of shrinking
-- under this, so a cap never reads as an empty dark square.
UIKit.MinGlyphText = 9

local DESIGN_AXIS = 720
local MIN_SCALE = 0.9
local MAX_SCALE = 1.3
local GAMEPAD_PREFIX = "Button"
local GLYPH_ADVANCE = 0.62 -- average advance of an upper-case Builder Sans Bold glyph, in em (cap width estimate)

-- Labels for keys that type no visible character: the engine's key string for them is blank or a control character
-- (Tab "\t", Space " ", Enter "\r") and their enum names are long.
local KEY_LABELS: { [string]: string } = {
	Tab = "TAB",
	Space = "SPACE",
	Return = "ENTER",
	KeypadEnter = "ENTER",
	Backspace = "BKSP",
	Escape = "ESC",
	LeftShift = "SHIFT",
	RightShift = "SHIFT",
	LeftControl = "CTRL",
	RightControl = "CTRL",
	LeftAlt = "ALT",
	RightAlt = "ALT",
	CapsLock = "CAPS",
}

local DPAD_ARMS: { [string]: Vector2 } = {
	DPadUp = Vector2.new(0, -1),
	DPadDown = Vector2.new(0, 1),
	DPadLeft = Vector2.new(-1, 0),
	DPadRight = Vector2.new(1, 0),
}

local GAMEPAD_TINTS: { [string]: Color3 } = {
	ButtonA = UIKit.Palette.GamepadA,
	ButtonB = UIKit.Palette.GamepadB,
	ButtonX = UIKit.Palette.GamepadX,
	ButtonY = UIKit.Palette.GamepadY,
}

export type GlyphKind = "Keyboard" | "Gamepad" | "Touch"

export type MeterBar = {
	root: Frame,
	fill: Frame,
	SetFraction: (self: MeterBar, fraction: number) -> (),
	SetColor: (self: MeterBar, color: Color3) -> (),
	SetAlpha: (self: MeterBar, alpha: number) -> (),
}

export type Ring = {
	root: Frame,
	SetProgress: (self: Ring, progress: number) -> (),
	SetColor: (self: Ring, color: Color3) -> (),
	SetAlpha: (self: Ring, alpha: number) -> (),
}

export type KeyCap = {
	root: Frame,
	SetGlyph: (self: KeyCap, kind: GlyphKind, keyCode: Enum.KeyCode?) -> (),
	SetAlpha: (self: KeyCap, alpha: number) -> (),
}

export type RoundButton = {
	button: TextButton,
	SetPressed: (self: RoundButton, pressed: boolean) -> (),
	SetLatched: (self: RoundButton, latched: boolean) -> (),
	SetAlpha: (self: RoundButton, alpha: number) -> (),
	Step: (self: RoundButton, dt: number) -> (),
}

export type Vignette = {
	root: Frame,
	SetAlpha: (self: Vignette, alpha: number) -> (),
	SetColor: (self: Vignette, color: Color3) -> (),
}

export type Slider = {
	root: TextButton,
	SetFraction: (self: Slider, fraction: number) -> (),
	SetFocused: (self: Slider, focused: boolean) -> (),
	IsDragging: (self: Slider) -> boolean,
	Destroy: (self: Slider) -> (),
}

export type Toggle = {
	root: Frame,
	SetOn: (self: Toggle, on: boolean, instant: boolean?) -> (),
	SetFocused: (self: Toggle, focused: boolean) -> (),
	Step: (self: Toggle, dt: number) -> (),
}

--------------------------------------------------------------------------------
-- Pure helpers (specced)
--------------------------------------------------------------------------------

-- The HUD's UIScale for a viewport: proportional to its short side, clamped so phones stay legible.
function UIKit.scaleFor(viewport: Vector2): number
	local short = math.min(viewport.X, viewport.Y)
	if short <= 0 then
		return 1
	end
	return math.clamp(short / DESIGN_AXIS, MIN_SCALE, MAX_SCALE)
end

-- The transparency that shows something of rest transparency `base` at visibility `alpha` (0 hidden .. 1 shown).
function UIKit.fade(base: number, alpha: number): number
	return 1 - (1 - base) * math.clamp(alpha, 0, 1)
end

-- Gradient rotations for a progress ring at `progress` (0..1, clockwise from 12 o'clock): the right half's mask
-- rotation, the left half's, and whether each half shows anything. Each half holds a full ring whose UIGradient is
-- opaque on one side of a line through the centre; rotating that line by 360 * progress sweeps the arc.
function UIKit.ringRotations(progress: number): (number, number, boolean, boolean)
	local p = math.clamp(progress, 0, 1)
	local degrees = 360 * p
	return math.clamp(degrees, 0, 180), math.clamp(degrees, 180, 360), p > 1e-3, p > 0.5
end

-- The short label a key cap shows for a key: gamepad buttons lose their "Button" prefix; keys that type no visible
-- character get a fixed label (TAB, SPACE, ENTER, SHIFT ...); other keyboard keys use the engine's localized key
-- string when it is short and printable, else the key's name. Never blank.
function UIKit.glyphText(keyCode: Enum.KeyCode, localized: string?): string
	local name = keyCode.Name
	if string.sub(name, 1, #GAMEPAD_PREFIX) == GAMEPAD_PREFIX and #name > #GAMEPAD_PREFIX then
		return string.sub(name, #GAMEPAD_PREFIX + 1)
	end
	local fixed = KEY_LABELS[name]
	if fixed then
		return fixed
	end
	local length = if localized then utf8.len(localized) else nil
	if
		localized
		and length ~= nil
		and length <= 6
		and string.find(localized, "%S") ~= nil -- something visible
		and string.find(localized, "%c") == nil -- no control characters
	then
		return string.upper(localized)
	end
	return name
end

-- A key cap's label size and cap width (design px) for `label` on a cap `size` px tall: a keyboard key is a rounded
-- square 0.86 of the size, a gamepad button a full-size disc. A long label keeps at least MinGlyphText and widens the
-- cap (a wide key, a capsule button) instead of shrinking into an unreadable smudge.
function UIKit.keyCapLayout(kind: GlyphKind, size: number, label: string): (number, number)
	local chars = utf8.len(label) or #label
	local gamepad = kind == "Gamepad"
	local long = chars > (if gamepad then 1 else 2)
	local factor = if gamepad then (if long then 0.3 else 0.42) else (if long then 0.26 else 0.4)
	local textSize = math.max(UIKit.MinGlyphText, math.floor(size * factor))
	local base = if gamepad then size else size * 0.86
	local width = math.max(base, chars * textSize * GLYPH_ADVANCE + size * 0.3)
	return textSize, math.ceil(width - 1e-6)
end

-- The d-pad direction a key code points (nil for anything that is not a d-pad arm).
function UIKit.dpadArm(keyCode: Enum.KeyCode): Vector2?
	return DPAD_ARMS[keyCode.Name]
end

--------------------------------------------------------------------------------
-- Instance helpers
--------------------------------------------------------------------------------

function UIKit.screenGui(name: string, displayOrder: number, insets: Enum.ScreenInsets): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.DisplayOrder = displayOrder
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ScreenInsets = insets
	gui.SafeAreaCompatibility = Enum.SafeAreaCompatibility.FullscreenExtension
	return gui
end

-- A transparent, borderless Frame (layout containers).
function UIKit.frame(parent: Instance?, name: string): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromScale(1, 1)
	frame.Parent = parent
	return frame
end

function UIKit.fill(parent: Instance?, name: string, color: Color3, transparency: number): Frame
	local frame = UIKit.frame(parent, name)
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency
	return frame
end

function UIKit.label(parent: Instance?, name: string, font: Font, size: number, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.FontFace = font
	label.TextSize = size
	label.TextColor3 = color
	label.Text = ""
	label.TextWrapped = true
	label.RichText = false
	label.Size = UDim2.fromScale(1, 1)
	label.Parent = parent
	return label
end

function UIKit.corner(parent: Instance, radius: UDim): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius
	corner.Parent = parent
	return corner
end

function UIKit.round(parent: Instance): UICorner
	return UIKit.corner(parent, UDim.new(0.5, 0))
end

function UIKit.stroke(parent: Instance, color: Color3, thickness: number, transparency: number): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = transparency
	stroke.Parent = parent
	return stroke
end

-- Text outline (contextual stroke) for text over the 3D world.
function UIKit.textStroke(parent: TextLabel | TextButton, transparency: number): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Color = UIKit.Palette.Ink
	stroke.Thickness = 1
	stroke.Transparency = transparency
	stroke.Parent = parent
	return stroke
end

function UIKit.padding(parent: Instance, horizontal: number, vertical: number): UIPadding
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, horizontal)
	padding.PaddingRight = UDim.new(0, horizontal)
	padding.PaddingTop = UDim.new(0, vertical)
	padding.PaddingBottom = UDim.new(0, vertical)
	padding.Parent = parent
	return padding
end

-- The grain layer UIKit.grain put on each surface (weak: it goes with the surface).
local grainLayers: { [Instance]: Frame } = setmetatable({}, { __mode = "k" }) :: any

-- Takes the grain off a surface that is about to be laid out (UIKit.list, or a caller's own UIGridLayout). The grain
-- is a full-size backdrop, not a row: a layout would stack it first, sized to the whole surface, and push every real
-- row out past the surface's edge, leaving an empty dark panel. A laid-out panel goes without it (on an
-- automatically sized panel it could never fill the panel anyway).
function UIKit.dropGrain(surface: Instance)
	local layer = grainLayers[surface]
	if layer then
		grainLayers[surface] = nil
		layer:Destroy()
	end
end

function UIKit.list(
	parent: Instance,
	direction: Enum.FillDirection,
	gap: number,
	horizontal: Enum.HorizontalAlignment,
	vertical: Enum.VerticalAlignment
): UIListLayout
	UIKit.dropGrain(parent)
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = direction
	layout.Padding = UDim.new(0, gap)
	layout.HorizontalAlignment = horizontal
	layout.VerticalAlignment = vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = parent
	return layout
end

function UIKit.sizeLimit(parent: Instance, minSize: Vector2, maxSize: Vector2): UISizeConstraint
	local constraint = Instance.new("UISizeConstraint")
	constraint.MinSize = minSize
	constraint.MaxSize = maxSize
	constraint.Parent = parent
	return constraint
end

local function sequence(points: { { number } }): NumberSequence
	local keypoints: { NumberSequenceKeypoint } = {}
	for _, point in points do
		table.insert(keypoints, NumberSequenceKeypoint.new(point[1], point[2]))
	end
	return NumberSequence.new(keypoints)
end

UIKit.sequence = sequence

-- A transparency gradient on `parent` (a GuiObject or a UIStroke).
function UIKit.gradient(parent: Instance, rotation: number, points: { { number } }): UIGradient
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Transparency = sequence(points)
	gradient.Parent = parent
	return gradient
end

-- Writes a property only when it changed (per-frame animation without churning the instance).
function UIKit.setTransparency(object: GuiObject, value: number)
	if math.abs(object.BackgroundTransparency - value) > 1e-3 then
		object.BackgroundTransparency = value
	end
end

function UIKit.setTextTransparency(object: TextLabel, value: number)
	if math.abs(object.TextTransparency - value) > 1e-3 then
		object.TextTransparency = value
	end
end

function UIKit.setStrokeTransparency(stroke: UIStroke, value: number)
	if math.abs(stroke.Transparency - value) > 1e-3 then
		stroke.Transparency = value
	end
end

--------------------------------------------------------------------------------
-- Surfaces
--------------------------------------------------------------------------------

-- Faint warm mottling and two hairline scratches on a panel's background (seeded, static).
function UIKit.grain(parent: GuiObject, seed: number, radius: UDim?): Frame
	local random = Random.new(seed)
	local layer = UIKit.fill(parent, "Grain", UIKit.Palette.Grain, 0.965)
	layer.ZIndex = 0 -- a texture on the parent's background, under its content
	layer.Active = false
	grainLayers[parent] = layer
	if radius then
		UIKit.corner(layer, radius)
	end
	local points: { { number } } = { { 0, random:NextNumber(0, 0.7) } }
	local steps = 9
	for index = 1, steps - 1 do
		table.insert(points, { index / steps, random:NextNumber(0, 0.85) })
	end
	table.insert(points, { 1, random:NextNumber(0, 0.7) })
	UIKit.gradient(layer, random:NextNumber(-25, 25), points)
	for index = 1, 2 do
		local scratch = UIKit.fill(layer, "Scratch" .. index, UIKit.Palette.Grain, 0.93)
		scratch.AnchorPoint = Vector2.new(0.5, 0.5)
		scratch.Position = UDim2.fromScale(random:NextNumber(0.15, 0.85), random:NextNumber(0.2, 0.8))
		scratch.Size = UDim2.new(random:NextNumber(0.25, 0.6), 0, 0, 1)
		scratch.Rotation = random:NextNumber(-14, 14)
		UIKit.gradient(scratch, 0, { { 0, 1 }, { 0.3, 0.4 }, { 0.7, 0.5 }, { 1, 1 } })
	end
	return layer
end

-- A dark translucent panel with a hairline border, soft corners and grain (dropped if the panel is laid out with
-- UIKit.list: see dropGrain).
function UIKit.panel(parent: Instance?, name: string, transparency: number, seed: number): Frame
	local panel = UIKit.fill(parent, name, UIKit.Palette.Panel, transparency)
	local radius = UDim.new(0, 6)
	UIKit.corner(panel, radius)
	UIKit.stroke(panel, UIKit.Palette.StrokeDim, 1, 0.15)
	UIKit.gradient(panel, 90, { { 0, 0 }, { 1, 0.18 } })
	UIKit.grain(panel, seed, radius)
	return panel
end

-- Four edge gradients darkening the screen edges (corners overlap, so they read darkest).
function UIKit.vignette(parent: Instance, name: string, color: Color3, depth: number, edge: number): Vignette
	local root = UIKit.frame(parent, name)
	root.Active = false
	local edges: { Frame } = {}
	local specs: { { size: UDim2, position: UDim2, rotation: number } } = {
		{ size = UDim2.fromScale(1, depth), position = UDim2.fromScale(0, 0), rotation = 90 },
		{ size = UDim2.fromScale(1, depth), position = UDim2.fromScale(0, 1 - depth), rotation = -90 },
		{ size = UDim2.fromScale(depth * 0.75, 1), position = UDim2.fromScale(0, 0), rotation = 0 },
		{ size = UDim2.fromScale(depth * 0.75, 1), position = UDim2.fromScale(1 - depth * 0.75, 0), rotation = 180 },
	}
	for index, spec in specs do
		local frame = UIKit.fill(root, "Edge" .. index, color, edge)
		frame.Size = spec.size
		frame.Position = spec.position
		UIKit.gradient(frame, spec.rotation, { { 0, 0 }, { 0.45, 0.55 }, { 1, 1 } })
		table.insert(edges, frame)
	end
	local vignette = {} :: Vignette
	vignette.root = root
	function vignette.SetAlpha(_self: Vignette, alpha: number)
		local transparency = UIKit.fade(edge, alpha)
		for _, frame in edges do
			UIKit.setTransparency(frame, transparency)
		end
	end
	function vignette.SetColor(_self: Vignette, nextColor: Color3)
		for _, frame in edges do
			frame.BackgroundColor3 = nextColor
		end
	end
	return vignette
end

--------------------------------------------------------------------------------
-- Meter bar
--------------------------------------------------------------------------------

-- A thin rounded bar: a dim track and a fill whose width is the fraction.
function UIKit.meterBar(parent: Instance, name: string, color: Color3, height: number): MeterBar
	local root = UIKit.fill(parent, name, UIKit.Palette.Track, 0.35)
	root.Size = UDim2.new(1, 0, 0, height)
	root.ClipsDescendants = true
	UIKit.round(root)
	local fill = UIKit.fill(root, "Fill", color, 0)
	fill.Size = UDim2.fromScale(1, 1)
	UIKit.round(fill)
	UIKit.gradient(fill, 0, { { 0, 0.35 }, { 0.85, 0 }, { 1, 0 } })

	local fraction = 1
	local alpha = 1
	local bar = {} :: MeterBar
	bar.root = root
	bar.fill = fill
	function bar.SetFraction(_self: MeterBar, value: number)
		local clamped = math.clamp(value, 0, 1)
		if math.abs(clamped - fraction) > 1e-4 then
			fraction = clamped
			fill.Size = UDim2.fromScale(clamped, 1)
		end
		fill.Visible = clamped > 1e-3
	end
	function bar.SetColor(_self: MeterBar, nextColor: Color3)
		if fill.BackgroundColor3 ~= nextColor then
			fill.BackgroundColor3 = nextColor
		end
	end
	function bar.SetAlpha(_self: MeterBar, value: number)
		if math.abs(value - alpha) <= 1e-3 then
			return
		end
		alpha = value
		UIKit.setTransparency(root, UIKit.fade(0.35, value))
		UIKit.setTransparency(fill, UIKit.fade(0, value))
	end
	return bar
end

--------------------------------------------------------------------------------
-- Progress ring
--------------------------------------------------------------------------------

local MASK = { { 0, 0 }, { 0.5, 0 }, { 0.501, 1 }, { 1, 1 } }
local TRACK_TRANSPARENCY = 0.82

-- A full ring (a circle whose UIStroke is the ring), inset so the outward stroke stays inside `parent`.
local function ringCircle(
	parent: Instance,
	name: string,
	thickness: number,
	scaleX: number,
	offsetX: number
): (Frame, UIStroke)
	local circle = UIKit.frame(parent, name)
	circle.Size = UDim2.new(scaleX, -2 * thickness, 1, -2 * thickness)
	circle.Position = UDim2.new(offsetX, thickness, 0, thickness)
	UIKit.round(circle)
	local stroke = UIKit.stroke(circle, UIKit.Palette.Bone, thickness, 0)
	return circle, stroke
end

-- A clockwise progress ring of `diameter` px with a faint full-circle track.
function UIKit.ring(parent: Instance, name: string, diameter: number, thickness: number, color: Color3): Ring
	local root = UIKit.frame(parent, name)
	root.Size = UDim2.fromOffset(diameter, diameter)

	local _, trackStroke = ringCircle(root, "Track", thickness, 1, 0)
	trackStroke.Color = UIKit.Palette.Bone
	trackStroke.Transparency = TRACK_TRANSPARENCY

	local right = UIKit.frame(root, "Right")
	right.Size = UDim2.fromScale(0.5, 1)
	right.Position = UDim2.fromScale(0.5, 0)
	right.ClipsDescendants = true
	local _, rightStroke = ringCircle(right, "Arc", thickness, 2, -1)
	local rightMask = UIKit.gradient(rightStroke, 0, MASK)

	local left = UIKit.frame(root, "Left")
	left.Size = UDim2.fromScale(0.5, 1)
	left.Position = UDim2.fromScale(0, 0)
	left.ClipsDescendants = true
	local _, leftStroke = ringCircle(left, "Arc", thickness, 2, 0)
	local leftMask = UIKit.gradient(leftStroke, 180, MASK)

	rightStroke.Color = color
	leftStroke.Color = color

	local alpha = 1
	local ring = {} :: Ring
	ring.root = root
	function ring.SetProgress(_self: Ring, progress: number)
		local rightRotation, leftRotation, rightVisible, leftVisible = UIKit.ringRotations(progress)
		if math.abs(rightMask.Rotation - rightRotation) > 0.05 then
			rightMask.Rotation = rightRotation
		end
		if math.abs(leftMask.Rotation - leftRotation) > 0.05 then
			leftMask.Rotation = leftRotation
		end
		right.Visible = rightVisible
		left.Visible = leftVisible
	end
	function ring.SetColor(_self: Ring, nextColor: Color3)
		if rightStroke.Color ~= nextColor then
			rightStroke.Color = nextColor
			leftStroke.Color = nextColor
		end
	end
	function ring.SetAlpha(_self: Ring, value: number)
		if math.abs(value - alpha) <= 1e-3 then
			return
		end
		alpha = value
		UIKit.setStrokeTransparency(rightStroke, UIKit.fade(0, value))
		UIKit.setStrokeTransparency(leftStroke, UIKit.fade(0, value))
		UIKit.setStrokeTransparency(trackStroke, UIKit.fade(TRACK_TRANSPARENCY, value))
	end
	ring:SetProgress(0)
	return ring
end

--------------------------------------------------------------------------------
-- Key cap
--------------------------------------------------------------------------------

local function localizedKey(keyCode: Enum.KeyCode): string?
	local ok, text = pcall(function(): string
		return UserInputService:GetStringForKeyCode(keyCode)
	end)
	return if ok then text else nil
end

-- A control glyph: keyboard key (rounded square + key label), gamepad button (disc + tinted letter), d-pad (a
-- cross with the pressed arm lit) or a touch mark (a dot in a thin ring: "tap here"). The root is `size` square; a
-- long label (TAB, SHIFT, Select) widens it (keyCapLayout), so lay caps out with a list or centre them.
function UIKit.keyCap(parent: Instance, name: string, size: number): KeyCap
	local palette = UIKit.Palette
	local root = UIKit.frame(parent, name)
	root.Size = UDim2.fromOffset(size, size)

	local cap = UIKit.fill(root, "Cap", palette.Ink, 0.22)
	cap.AnchorPoint = Vector2.new(0.5, 0.5)
	cap.Position = UDim2.fromScale(0.5, 0.5)
	local capCorner = UIKit.corner(cap, UDim.new(0.5, 0))
	local capStroke = UIKit.stroke(cap, palette.Bone, 1, 0.45)

	local text = UIKit.label(cap, "Text", UIKit.Fonts.Strong, math.floor(size * 0.42), palette.Bone)
	text.TextWrapped = false
	text.TextScaled = false

	local cross = UIKit.frame(cap, "DPad")
	local arms: { [string]: Frame } = {}
	for armName, direction in DPAD_ARMS do
		local arm = UIKit.fill(cross, armName, palette.Smoke, 0.1)
		arm.AnchorPoint = Vector2.new(0.5, 0.5)
		local horizontal = direction.X ~= 0
		arm.Size = if horizontal then UDim2.fromScale(0.26, 0.2) else UDim2.fromScale(0.2, 0.26)
		arm.Position = UDim2.fromScale(0.5 + direction.X * 0.2, 0.5 + direction.Y * 0.2)
		UIKit.corner(arm, UDim.new(0, 2))
		arms[armName] = arm
	end
	local hub = UIKit.fill(cross, "Hub", palette.Smoke, 0.1)
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = UDim2.fromScale(0.5, 0.5)
	hub.Size = UDim2.fromScale(0.2, 0.2)

	local tapRing = UIKit.frame(cap, "Tap")
	tapRing.AnchorPoint = Vector2.new(0.5, 0.5)
	tapRing.Position = UDim2.fromScale(0.5, 0.5)
	tapRing.Size = UDim2.fromScale(0.56, 0.56)
	UIKit.round(tapRing)
	local tapStroke = UIKit.stroke(tapRing, palette.Bone, 1.5, 0.35)
	local tapDot = UIKit.fill(tapRing, "Dot", palette.Bone, 0.05)
	tapDot.AnchorPoint = Vector2.new(0.5, 0.5)
	tapDot.Position = UDim2.fromScale(0.5, 0.5)
	tapDot.Size = UDim2.fromScale(0.38, 0.38)
	UIKit.round(tapDot)

	local kind: GlyphKind = "Keyboard"
	local litArm: string? = nil
	local alpha = 1

	local function paint()
		cap.BackgroundTransparency = UIKit.fade(0.22, alpha)
		capStroke.Transparency = UIKit.fade(0.45, alpha)
		text.TextTransparency = UIKit.fade(0, alpha)
		for armName, arm in arms do
			arm.BackgroundTransparency = UIKit.fade(if armName == litArm then 0 else 0.35, alpha)
		end
		hub.BackgroundTransparency = UIKit.fade(0.35, alpha)
		tapStroke.Transparency = UIKit.fade(0.35, alpha)
		tapDot.BackgroundTransparency = UIKit.fade(0.05, alpha)
	end

	local keyCap = {} :: KeyCap
	keyCap.root = root
	function keyCap.SetGlyph(_self: KeyCap, nextKind: GlyphKind, keyCode: Enum.KeyCode?)
		kind = nextKind
		litArm = nil
		local arm = if keyCode and kind == "Gamepad" then UIKit.dpadArm(keyCode) else nil
		text.Visible = false
		cross.Visible = false
		tapRing.Visible = false
		root.Size = UDim2.fromOffset(size, size)
		if kind == "Touch" or keyCode == nil then
			cap.Size = UDim2.fromScale(1, 1)
			capCorner.CornerRadius = UDim.new(0.5, 0)
			tapRing.Visible = true
		elseif arm then
			cap.Size = UDim2.fromScale(1, 1)
			capCorner.CornerRadius = UDim.new(0.5, 0)
			cross.Visible = true
			litArm = keyCode.Name
			for armName, armFrame in arms do
				armFrame.BackgroundColor3 = if armName == litArm then palette.Bone else palette.Smoke
			end
		elseif kind == "Gamepad" then
			local label = UIKit.glyphText(keyCode, nil)
			local textSize, width = UIKit.keyCapLayout(kind, size, label)
			cap.Size = UDim2.new(0, width, 1, 0)
			capCorner.CornerRadius = UDim.new(0.5, 0)
			root.Size = UDim2.fromOffset(math.max(size, width), size)
			text.Visible = true
			text.Text = label
			text.TextColor3 = GAMEPAD_TINTS[keyCode.Name] or palette.Bone
			text.TextSize = textSize
		else
			local label = UIKit.glyphText(keyCode, localizedKey(keyCode))
			local textSize, width = UIKit.keyCapLayout(kind, size, label)
			cap.Size = UDim2.new(0, width, 0.86, 0)
			capCorner.CornerRadius = UDim.new(0.18, 0)
			root.Size = UDim2.fromOffset(math.max(size, width + math.ceil(size * 0.14)), size)
			text.Visible = true
			text.Text = label
			text.TextColor3 = palette.Bone
			text.TextSize = textSize
		end
		paint()
	end
	function keyCap.SetAlpha(_self: KeyCap, value: number)
		if math.abs(value - alpha) <= 1e-3 then
			return
		end
		alpha = value
		paint()
	end
	keyCap:SetGlyph("Keyboard", Enum.KeyCode.E)
	return keyCap
end

--------------------------------------------------------------------------------
-- Touch button
--------------------------------------------------------------------------------

-- A round touch button: dark glass disc, hairline rim, small caps label. Pressing sinks it slightly; a latched
-- (toggled on) button gets an amber rim and a warm inner glow.
function UIKit.roundButton(parent: Instance, name: string, text: string, diameter: number): RoundButton
	local palette = UIKit.Palette
	local button = Instance.new("TextButton")
	button.Name = name
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Size = UDim2.fromOffset(diameter, diameter)
	button.BackgroundColor3 = palette.Ink
	button.BackgroundTransparency = 0.45
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Selectable = false
	button.Text = ""
	button.Parent = parent
	UIKit.round(button)
	local rim = UIKit.stroke(button, palette.Bone, 1.5, 0.6)
	local glow = UIKit.fill(button, "Glow", palette.Amber, 1)
	UIKit.round(glow)
	UIKit.gradient(glow, 90, { { 0, 0.55 }, { 1, 0.9 } })
	local label =
		UIKit.label(button, "Label", UIKit.Fonts.Strong, math.clamp(math.floor(diameter * 0.17), 10, 16), palette.Bone)
	label.Text = text
	label.TextScaled = false
	label.TextWrapped = true
	UIKit.padding(label, 6, 0)
	local scale = Instance.new("UIScale")
	scale.Parent = button

	local pressed = false
	local latched = false
	local alpha = 1
	local shownScale = 1

	local function paint()
		button.BackgroundTransparency = UIKit.fade(if pressed then 0.25 else 0.45, alpha)
		rim.Color = if latched then palette.Amber else palette.Bone
		rim.Transparency = UIKit.fade(if pressed or latched then 0.15 else 0.6, alpha)
		glow.BackgroundTransparency = if latched then UIKit.fade(0, alpha) else 1
		label.TextTransparency = UIKit.fade(if pressed or latched then 0 else 0.12, alpha)
		label.TextColor3 = if latched then palette.Amber else palette.Bone
	end

	local handle = {} :: RoundButton
	handle.button = button
	function handle.SetPressed(_self: RoundButton, value: boolean)
		if pressed ~= value then
			pressed = value
			paint()
		end
	end
	function handle.SetLatched(_self: RoundButton, value: boolean)
		if latched ~= value then
			latched = value
			paint()
		end
	end
	function handle.SetAlpha(_self: RoundButton, value: number)
		if math.abs(value - alpha) > 1e-3 then
			alpha = value
			paint()
		end
	end
	function handle.Step(_self: RoundButton, dt: number)
		local target = if pressed then 0.9 else 1
		shownScale += (target - shownScale) * (1 - math.exp(-24 * dt))
		if math.abs(scale.Scale - shownScale) > 1e-3 then
			scale.Scale = shownScale
		end
	end
	paint()
	return handle
end

--------------------------------------------------------------------------------
-- Slider and toggle
--------------------------------------------------------------------------------

-- A horizontal slider: a hairline track, a bone fill and a round knob. Dragging (mouse or touch, starting anywhere
-- on its hit area) reports the fraction under the pointer through `onDrag`; SetFraction moves it from outside.
function UIKit.slider(parent: Instance, name: string, onDrag: (fraction: number) -> ()): Slider
	local palette = UIKit.Palette
	local hit = Instance.new("TextButton")
	hit.Name = name
	hit.BackgroundTransparency = 1
	hit.BorderSizePixel = 0
	hit.AutoButtonColor = false
	hit.Selectable = false
	hit.Text = ""
	hit.Size = UDim2.fromScale(1, 1)
	hit.Parent = parent

	local track = UIKit.fill(hit, "Track", palette.Track, 0)
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.fromScale(0, 0.5)
	track.Size = UDim2.new(1, 0, 0, 4)
	UIKit.round(track)
	local fill = UIKit.fill(track, "Fill", palette.Bone, 0.1)
	fill.Size = UDim2.fromScale(0, 1)
	UIKit.round(fill)
	local knob = UIKit.fill(track, "Knob", palette.Bone, 0)
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.fromScale(0, 0.5)
	knob.Size = UDim2.fromOffset(16, 16)
	UIKit.round(knob)
	UIKit.stroke(knob, palette.Ink, 2, 0.2)

	local dragging: InputObject? = nil
	local connections: { RBXScriptConnection } = {}

	local function fractionAt(x: number): number
		local width = track.AbsoluteSize.X
		if width <= 0 then
			return 0
		end
		return math.clamp((x - track.AbsolutePosition.X) / width, 0, 1)
	end

	table.insert(
		connections,
		hit.InputBegan:Connect(function(input: InputObject)
			local kind = input.UserInputType
			if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
				dragging = input
				onDrag(fractionAt(input.Position.X))
			end
		end)
	)
	table.insert(
		connections,
		UserInputService.InputChanged:Connect(function(input: InputObject)
			local active = dragging
			if not active then
				return
			end
			local matches = input == active
				or (
					active.UserInputType == Enum.UserInputType.MouseButton1
					and input.UserInputType == Enum.UserInputType.MouseMovement
				)
			if matches then
				onDrag(fractionAt(input.Position.X))
			end
		end)
	)
	table.insert(
		connections,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if input == dragging then
				dragging = nil
			end
		end)
	)

	local slider = {} :: Slider
	slider.root = hit
	function slider.SetFraction(_self: Slider, fraction: number)
		local clamped = math.clamp(fraction, 0, 1)
		fill.Size = UDim2.fromScale(clamped, 1)
		knob.Position = UDim2.fromScale(clamped, 0.5)
	end
	function slider.SetFocused(_self: Slider, focused: boolean)
		fill.BackgroundColor3 = if focused then palette.Amber else palette.Bone
		knob.BackgroundColor3 = if focused then palette.Amber else palette.Bone
	end
	function slider.IsDragging(_self: Slider): boolean
		return dragging ~= nil
	end
	function slider.Destroy(_self: Slider)
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		hit:Destroy()
	end
	return slider
end

-- A pill switch: the knob slides right and the pill warms to amber when on.
function UIKit.toggle(parent: Instance, name: string): Toggle
	local palette = UIKit.Palette
	local pill = UIKit.fill(parent, name, palette.Track, 0)
	pill.Size = UDim2.fromOffset(46, 24)
	UIKit.round(pill)
	local rim = UIKit.stroke(pill, palette.StrokeDim, 1, 0)
	local knob = UIKit.fill(pill, "Knob", palette.Ash, 0)
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Size = UDim2.fromOffset(18, 18)
	knob.Position = UDim2.new(0, 12, 0.5, 0)
	UIKit.round(knob)

	local on = false
	local shown = 0
	local toggle = {} :: Toggle
	toggle.root = pill
	local function paint()
		knob.Position = UDim2.new(0, 12 + 22 * shown, 0.5, 0)
		pill.BackgroundColor3 = palette.Track:Lerp(palette.Amber, shown * 0.55)
		knob.BackgroundColor3 = palette.Ash:Lerp(palette.Bone, shown)
		rim.Color = palette.StrokeDim:Lerp(palette.Amber, shown)
	end
	function toggle.SetOn(_self: Toggle, value: boolean, instant: boolean?)
		on = value
		if instant then
			shown = if value then 1 else 0
			paint()
		end
	end
	function toggle.SetFocused(_self: Toggle, focused: boolean)
		rim.Thickness = if focused then 2 else 1
	end
	function toggle.Step(_self: Toggle, dt: number)
		local target = if on then 1 else 0
		if math.abs(shown - target) < 1e-3 then
			return
		end
		shown += (target - shown) * (1 - math.exp(-18 * dt))
		if math.abs(shown - target) < 1e-3 then
			shown = target
		end
		paint()
	end
	paint()
	return toggle
end

return table.freeze(UIKit)
