--!strict
-- SurfaceArt: procedural paint for part faces. Every pattern is a SurfaceGui of plain Frames (and the odd TextLabel,
-- UICorner, UIStroke or UIGradient): no images, no decals, no textures. Used for checker floors, drop-ceiling grids,
-- hazard stripes, signs and posters, and the wear on every wall: grime at the foot, soot under the ceiling, dirt in
-- the corners, water runs and cracks.
--
-- Rules every surface follows:
--   * PixelsPerStud sizing, low resolution (4..20 px per stud) and capped so no canvas side exceeds MaxCanvas pixels
--     (the engine downscales larger canvases anyway, and phones pay for every texel);
--   * LightInfluence 1 unless a surface is itself a light source (an exit sign's letters), so paint sits in the
--     scene's light and darkness like the part under it;
--   * patterns are drawn as the minority colour only (the dark squares of a checker, the seams of a grid) over a part
--     coloured as the majority, so a floor keeps its own material, gloss and reflections where most of it shows;
--   * positions are in canvas Scale, and every pattern here is symmetric under flipping either canvas axis, so the
--     result does not depend on how the engine orients a Top or Bottom face's canvas.

local SurfaceArt = {}

SurfaceArt.MaxCanvas = 1024
SurfaceArt.MinPixelsPerStud = 4
SurfaceArt.MaxPixelsPerStud = 20

SurfaceArt.HazardYellow = Color3.fromRGB(214, 168, 22)
SurfaceArt.HazardBlack = Color3.fromRGB(20, 19, 17)

export type GuiOptions = {
	name: string?,
	pixelsPerStud: number?, -- wanted resolution (clamped by pixelsPerStud below)
	maxDistance: number?,
	lightInfluence: number?,
	brightness: number?,
}

-- The size in studs of `face` of a part of `size` (canvas X, canvas Y).
function SurfaceArt.faceStuds(size: Vector3, face: Enum.NormalId): Vector2
	if face == Enum.NormalId.Front or face == Enum.NormalId.Back then
		return Vector2.new(size.X, size.Y)
	elseif face == Enum.NormalId.Left or face == Enum.NormalId.Right then
		return Vector2.new(size.Z, size.Y)
	end
	return Vector2.new(size.X, size.Z)
end

-- Pixels per stud for a canvas of `studs`: `wanted`, lowered so the longest side fits MaxCanvas, within the limits.
function SurfaceArt.pixelsPerStud(studs: Vector2, wanted: number): number
	local longest = math.max(studs.X, studs.Y, 1e-3)
	local fit = math.floor(SurfaceArt.MaxCanvas / longest)
	return math.clamp(math.min(wanted, fit), SurfaceArt.MinPixelsPerStud, SurfaceArt.MaxPixelsPerStud)
end

-- A SurfaceGui on `face` of `part`. Returns the gui and its pixels per stud.
function SurfaceArt.gui(part: BasePart, face: Enum.NormalId, options: GuiOptions?): (SurfaceGui, number)
	local o: GuiOptions = options or {}
	local pps = SurfaceArt.pixelsPerStud(SurfaceArt.faceStuds(part.Size, face), o.pixelsPerStud or 12)
	local gui = Instance.new("SurfaceGui")
	gui.Name = o.name or "Paint"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pps
	gui.LightInfluence = o.lightInfluence or 1
	gui.Brightness = o.brightness or 1
	gui.MaxDistance = o.maxDistance or 120
	gui.ClipsDescendants = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = part
	return gui, pps
end

-- A borderless Frame in canvas Scale coordinates.
function SurfaceArt.frame(
	parent: Instance,
	name: string,
	x: number,
	y: number,
	w: number,
	h: number,
	color: Color3,
	transparency: number?,
	zIndex: number?
): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Position = UDim2.fromScale(x, y)
	frame.Size = UDim2.fromScale(w, h)
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency or 0
	frame.BorderSizePixel = 0
	frame.ZIndex = zIndex or 1
	frame.Parent = parent
	return frame
end

-- The dark squares of a cols x rows checker over the whole canvas (the part is the pale squares). With odd counts
-- the four corner squares are dark, so the pattern is the same under either axis flip.
function SurfaceArt.checker(
	parent: Instance,
	cols: number,
	rows: number,
	color: Color3,
	transparency: number,
	zIndex: number?
): number
	local count = 0
	for i = 0, cols - 1 do
		for j = 0, rows - 1 do
			if (i + j) % 2 == 0 then
				SurfaceArt.frame(parent, "Square", i / cols, j / rows, 1 / cols, 1 / rows, color, transparency, zIndex)
				count += 1
			end
		end
	end
	return count
end

-- Interior seams of a cols x rows grid of `thickness` pixels (the canvas edges are left to the walls).
function SurfaceArt.grid(
	parent: Instance,
	cols: number,
	rows: number,
	color: Color3,
	transparency: number,
	thickness: number,
	zIndex: number?
): number
	local count = 0
	for i = 1, cols - 1 do
		local line = SurfaceArt.frame(parent, "SeamU", i / cols, 0, 0, 1, color, transparency, zIndex)
		line.Position = UDim2.new(i / cols, -thickness / 2, 0, 0)
		line.Size = UDim2.new(0, thickness, 1, 0)
		count += 1
	end
	for j = 1, rows - 1 do
		local line = SurfaceArt.frame(parent, "SeamV", 0, j / rows, 1, 0, color, transparency, zIndex)
		line.Position = UDim2.new(0, 0, j / rows, -thickness / 2)
		line.Size = UDim2.new(1, 0, 0, thickness)
		count += 1
	end
	return count
end

-- A hollow box (or oval with `round`) in canvas Scale, drawn as a `thickness`-pixel stroke: court lines, borders.
function SurfaceArt.outline(
	parent: Instance,
	name: string,
	x: number,
	y: number,
	w: number,
	h: number,
	color: Color3,
	thickness: number,
	transparency: number?,
	round: boolean?,
	zIndex: number?
): Frame
	local frame = SurfaceArt.frame(parent, name, x, y, w, h, color, 1, zIndex)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = math.max(1, thickness)
	stroke.Transparency = transparency or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame
	if round then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = frame
	end
	return frame
end

-- An oval stain centred at (cx, cy) in canvas Scale, with a darker tide line round its rim when `ring` is given.
function SurfaceArt.stain(
	parent: Instance,
	cx: number,
	cy: number,
	w: number,
	h: number,
	color: Color3,
	transparency: number,
	ring: Color3?,
	zIndex: number?
): Frame
	local stain = SurfaceArt.frame(parent, "Stain", cx - w / 2, cy - h / 2, w, h, color, transparency, zIndex)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = stain
	if ring then
		local stroke = Instance.new("UIStroke")
		stroke.Color = ring
		stroke.Thickness = 1
		stroke.Transparency = math.clamp(transparency - 0.15, 0, 1)
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = stain
	end
	return stain
end

-- Grime pooled toward the canvas bottom (`fromTop` false) or top: one frame faded by a gradient.
function SurfaceArt.grime(parent: Instance, color: Color3, strength: number, fromTop: boolean?, zIndex: number?): Frame
	local frame = SurfaceArt.frame(parent, "Grime", 0, 0, 1, 1, color, 0, zIndex)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = if fromTop then 90 else -90
	local dense = math.clamp(1 - strength, 0, 1)
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, dense),
		NumberSequenceKeypoint.new(0.55, math.clamp(dense + (1 - dense) * 0.7, 0, 1)),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = frame
	return frame
end

-- A band `depthPx` pixels deep along the canvas bottom (or top with `fromTop`), `offsetPx` in from that edge, dense at
-- the edge and fading away from it: grime gathered at a wall's foot, soot under a ceiling.
function SurfaceArt.edgeBand(
	parent: Instance,
	name: string,
	fromTop: boolean,
	offsetPx: number,
	depthPx: number,
	color: Color3,
	strength: number,
	zIndex: number?
): Frame
	local frame = SurfaceArt.frame(parent, name, 0, 0, 1, 0, color, 0, zIndex)
	frame.Size = UDim2.new(1, 0, 0, depthPx)
	frame.Position = if fromTop then UDim2.new(0, 0, 0, offsetPx) else UDim2.new(0, 0, 1, -offsetPx - depthPx)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = if fromTop then 90 else -90
	local dense = math.clamp(1 - strength, 0, 1)
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, dense),
		NumberSequenceKeypoint.new(0.3, math.clamp(dense + (1 - dense) * 0.45, 0, 1)),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = frame
	return frame
end

-- A strip `widthPx` wide down the canvas's left (or right with `atRight`) edge, `insetPx` in from it, dark at its
-- outer side and fading inward: the dirt that gathers in an inside corner.
function SurfaceArt.sideBand(
	parent: Instance,
	name: string,
	atRight: boolean,
	insetPx: number,
	widthPx: number,
	color: Color3,
	strength: number,
	zIndex: number?
): Frame
	local frame = SurfaceArt.frame(parent, name, 0, 0, 0, 1, color, 0, zIndex)
	frame.Size = UDim2.new(0, widthPx, 1, 0)
	frame.Position = if atRight then UDim2.new(1, -insetPx - widthPx, 0, 0) else UDim2.new(0, insetPx, 0, 0)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = if atRight then 180 else 0
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, math.clamp(1 - strength, 0, 1)),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = frame
	return frame
end

-- A water run: a narrow streak from `topPx` down `lengthPx` pixels at canvas-Scale x, strongest where it starts and
-- thinning out as it runs.
function SurfaceArt.streak(
	parent: Instance,
	x: number,
	topPx: number,
	widthPx: number,
	lengthPx: number,
	color: Color3,
	strength: number,
	zIndex: number?
): Frame
	local frame = SurfaceArt.frame(parent, "Run", x, 0, 0, 0, color, 0, zIndex)
	frame.Position = UDim2.new(x, -widthPx / 2, 0, topPx)
	frame.Size = UDim2.new(0, widthPx, 0, lengthPx)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	local dense = math.clamp(1 - strength, 0, 1)
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, dense),
		NumberSequenceKeypoint.new(0.6, math.clamp(dense + (1 - dense) * 0.5, 0, 1)),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = frame
	return frame
end

-- A crack: `segments` thin dark strokes chained from canvas-Scale (x, y), wandering about `heading` degrees (0 = down
-- the canvas). Returns the strokes drawn.
function SurfaceArt.crack(
	parent: Instance,
	random: Random,
	x: number,
	y: number,
	heading: number,
	segments: number,
	lengthPx: number,
	thicknessPx: number,
	color: Color3,
	zIndex: number?
): number
	local px, py = 0, 0
	local angle = heading
	for i = 1, segments do
		angle += random:NextNumber(-35, 35)
		local length = lengthPx * random:NextNumber(0.6, 1.2)
		local radians = math.rad(angle)
		local dx, dy = math.sin(radians) * length, math.cos(radians) * length
		local stroke = SurfaceArt.frame(parent, "Crack", x, y, 0, 0, color, 0.15 + i * 0.08, zIndex)
		stroke.AnchorPoint = Vector2.new(0.5, 0.5)
		stroke.Position = UDim2.new(x, px + dx / 2, y, py + dy / 2)
		stroke.Size = UDim2.fromOffset(math.max(1, thicknessPx), length + thicknessPx)
		stroke.Rotation = -angle
		px += dx
		py += dy
	end
	return segments
end

-- Hard-edged stripes across the canvas Scale box (x, y, w, h): `count` bands of `ink` over `ground`, each `duty` of
-- its period thick, running across (`vertical` false: horizontal stripes stacked down the box). One Frame and one
-- UIGradient however many stripes (at most 4), for printed lines, lath and mortar courses.
function SurfaceArt.stripes(
	parent: Instance,
	name: string,
	x: number,
	y: number,
	w: number,
	h: number,
	count: number,
	duty: number,
	ink: Color3,
	ground: Color3,
	transparency: number?,
	zIndex: number?
): Frame
	local frame = SurfaceArt.frame(parent, name, x, y, w, h, Color3.new(1, 1, 1), transparency, zIndex)
	local n = math.clamp(count, 1, 4)
	local period = 1 / n
	local keys: { ColorSequenceKeypoint } = { ColorSequenceKeypoint.new(0, ground) }
	for i = 0, n - 1 do
		local a = i * period + period * (1 - duty) / 2
		local b = a + period * duty
		table.insert(keys, ColorSequenceKeypoint.new(math.max(a - 1e-3, 1e-3), ground))
		table.insert(keys, ColorSequenceKeypoint.new(a, ink))
		table.insert(keys, ColorSequenceKeypoint.new(b, ink))
		table.insert(keys, ColorSequenceKeypoint.new(math.min(b + 1e-3, 1 - 1e-3), ground))
	end
	table.insert(keys, ColorSequenceKeypoint.new(1, ground))
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(keys)
	gradient.Parent = frame
	return frame
end

-- Yellow-and-black hazard stripes over the whole canvas of `parent` (a gui or a frame) that is `studs` big at
-- `pps` pixels per stud: black bars `stripe` studs wide at 45 degrees, clipped to the canvas, then a little grime.
function SurfaceArt.hazard(parent: Instance, studs: Vector2, pps: number, stripe: number?, worn: number?): number
	local ground = SurfaceArt.frame(parent, "Hazard", 0, 0, 1, 1, SurfaceArt.HazardYellow, 0, 1)
	ground.ClipsDescendants = true
	local w, h = studs.X * pps, studs.Y * pps
	local bar = math.max(2, (stripe or 0.35) * pps)
	local period = bar * 2 * math.sqrt(2) -- horizontal distance between bar centres (equal yellow and black)
	local length = (w + h) * 1.5 + bar
	local first = -h / 2 - bar
	local n = math.ceil((w + h + bar * 2) / period) + 1
	local count = 1
	for i = 0, n do
		local cx = first + i * period
		local stripeFrame = Instance.new("Frame")
		stripeFrame.Name = "Stripe"
		stripeFrame.AnchorPoint = Vector2.new(0.5, 0.5)
		stripeFrame.Position = UDim2.fromOffset(cx, h / 2)
		stripeFrame.Size = UDim2.fromOffset(bar, length)
		stripeFrame.Rotation = 45
		stripeFrame.BackgroundColor3 = SurfaceArt.HazardBlack
		stripeFrame.BorderSizePixel = 0
		stripeFrame.ZIndex = 2
		stripeFrame.Parent = ground
		count += 1
	end
	if (worn or 0) > 0 then
		SurfaceArt.grime(ground, Color3.fromRGB(46, 38, 26), worn or 0, false, 3)
		count += 1
	end
	return count
end

-- A TextLabel filling the canvas Scale box (x, y, w, h), text scaled to fit.
function SurfaceArt.text(
	parent: Instance,
	name: string,
	text: string,
	x: number,
	y: number,
	w: number,
	h: number,
	color: Color3,
	font: Enum.Font,
	zIndex: number?
): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Position = UDim2.fromScale(x, y)
	label.Size = UDim2.fromScale(w, h)
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.TextWrapped = true
	label.FontFace = Font.fromEnum(font)
	label.ZIndex = zIndex or 2
	label.Parent = parent
	return label
end

return table.freeze(SurfaceArt)
