--!strict
-- DreadArt: the painters of DreadKit's decals (SurfaceArt guis on invisible or thin host parts). Every painter draws
-- from its own seeded stream (never the part's place in a build), so the same host is painted the same on Roblox and
-- in the web's bake. Frames, rotations, corners, strokes, gradients and text only (what the bake rasterises).
--
--   gouges     long claw marks: a few parallel strokes, a torn pale lip along each, tapering at both ends
--   writing    a scrawled line in one of four hands (marker, chalk, faded 1989 paint, scratched into the paint)
--   tally      groups of five scratched strokes, the last group never finished
--   clock      a school wall clock's face, stopped at DreadConfig.Clock (its hands' rotations are the time)
--   notice     the printed lockdown notice
--   drawing    a child's crayon drawing of a tall thin figure with a white face beside a door and a small figure
--   cracks     plaster cracked out from the top corners of a doorway a very tall thing forced through
--   stain      a water stain spreading from a ceiling corner, with its tide line and runs down the wall
--   mould      a bloom of black mould
--   cobweb     threads strung across a corner
--   peel       a long strip of paint peeled back to the bare wall
--   hole       the dark plenum where a ceiling tile was knocked out
--   soot       the brown-black scorch round a failing bulb
--   screen     a phone's cracked glass, still faintly lit
--   louvres    a torn-off locker door's vents and number plate
--   flies      dead flies on a sill

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DreadConfig = require(ReplicatedStorage.Shared.Config.DreadConfig)
local Rng = require(ReplicatedStorage.Shared.Util.Rng)

local SurfaceArt = require(script.Parent.Parent.SurfaceArt)

type Rng = Rng.Rng

local DreadArt = {}

DreadArt.GuiName = "Dread"

local INK = Color3.fromRGB(22, 20, 24)
local CHALK = Color3.fromRGB(222, 218, 204)
local PAINT_1989 = Color3.fromRGB(206, 196, 164)
local VOID = Color3.fromRGB(12, 10, 9)
local STAIN = Color3.fromRGB(104, 80, 44)
local STAIN_RING = Color3.fromRGB(70, 50, 26)
local MOULD = Color3.fromRGB(26, 32, 22)
local WEB = Color3.fromRGB(210, 210, 204)
local CRAYON_BLACK = Color3.fromRGB(30, 28, 34)
local CRAYON_BLUE = Color3.fromRGB(40, 64, 140)
local CRAYON_BROWN = Color3.fromRGB(120, 76, 40)
local MASK_WHITE = Color3.fromRGB(246, 244, 236)

local function scaled(color: Color3, f: number): Color3
	return Color3.new(math.clamp(color.R * f, 0, 1), math.clamp(color.G * f, 0, 1), math.clamp(color.B * f, 0, 1))
end

local function luminance(color: Color3): number
	return 0.299 * color.R + 0.587 * color.G + 0.114 * color.B
end

-- A gui on `face` of `part` and its canvas in pixels.
local function canvas(
	part: BasePart,
	face: Enum.NormalId,
	pps: number,
	maxDistance: number?,
	lightInfluence: number?
): (SurfaceGui, Vector2)
	local gui, density = SurfaceArt.gui(part, face, {
		name = DreadArt.GuiName,
		pixelsPerStud = pps,
		maxDistance = maxDistance or 90,
		lightInfluence = lightInfluence,
	})
	return gui, SurfaceArt.faceStuds(part.Size, face) * density
end

-- A straight stroke from pixel (x0, y0) to (x1, y1), `thickness` pixels wide.
local function stroke(
	parent: Instance,
	name: string,
	x0: number,
	y0: number,
	x1: number,
	y1: number,
	thickness: number,
	color: Color3,
	transparency: number,
	zIndex: number?
): Frame
	local dx, dy = x1 - x0, y1 - y0
	local length = math.sqrt(dx * dx + dy * dy)
	local frame = SurfaceArt.frame(parent, name, 0, 0, 0, 0, color, transparency, zIndex)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromOffset((x0 + x1) / 2, (y0 + y1) / 2)
	frame.Size = UDim2.fromOffset(math.max(1, thickness), length + thickness)
	frame.Rotation = -math.deg(math.atan2(dx, dy))
	return frame
end

-- Fades a frame along its length: `head` transparency at its start, clear in the middle, `tail` at its end.
local function taper(frame: Frame, head: number, tail: number)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, head),
		NumberSequenceKeypoint.new(0.25, 0),
		NumberSequenceKeypoint.new(0.7, 0.1),
		NumberSequenceKeypoint.new(1, tail),
	})
	gradient.Parent = frame
end

local function round(frame: Frame, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(radius, 0)
	corner.Parent = frame
end

--------------------------------------------------------------------------------
-- He was here
--------------------------------------------------------------------------------

-- Claw marks on the Front face of `part` (`wall`: the surface colour they are gouged into). `strokes` parallel marks
-- run down the face at `lean` degrees from its long axis.
function DreadArt.gouges(part: BasePart, wall: Color3, seed: number, strokes: number, lean: number)
	local random = Rng.new(seed)
	local gui, size = canvas(part, Enum.NormalId.Front, 18, 120)
	local pps = size.X / part.Size.X
	local tall = size.Y >= size.X
	local length = (if tall then size.Y else size.X) * 0.82
	local across = if tall then size.X else size.Y
	local spacing = math.min(across / (strokes + 1.4), 0.55 * pps)
	local radians = math.rad(lean)
	local core = scaled(wall, 0.18)
	local scraped = scaled(wall, if luminance(wall) > 0.5 then 1.25 else 2.1)
	for i = 1, strokes do
		local l = length * random:NextNumber(0.78, 1)
		local offset = spacing * (i - (strokes + 1) / 2) + random:NextNumber(-0.1, 0.1) * spacing
		local start = random:NextNumber(0, 0.08) * length - length / 2
		-- the swipe: along the long axis turned by the lean, bowing a little as the hand dragged, then into pixels
		local cosL, sinL = math.cos(radians), math.sin(radians)
		local function point(t: number, side: number): (number, number)
			local a = start + t * l
			local c = offset + side + math.sin(t * math.pi) * spacing * 0.35
			local u, v = c * cosL - a * sinL, c * sinL + a * cosL
			if tall then
				return size.X / 2 + u, size.Y / 2 + v
			end
			return size.X / 2 + v, size.Y / 2 + u
		end
		local ax, ay = point(0, 0)
		local bx, by = point(1, 0)
		-- the paint and plaster scraped off round the groove, pale where the torch catches it
		local mx, my = point(0.5, 0)
		local band = stroke(gui, "Scrape" .. i, ax, ay, mx, my, math.max(3, 0.36 * pps), scraped, 0.25, 2)
		taper(band, 0.6, 0.2)
		band = stroke(gui, "Scrape" .. i, mx, my, bx, by, math.max(3, 0.36 * pps), scraped, 0.25, 2)
		taper(band, 0.2, 0.9)
		-- the groove itself, deep and dark
		local groove = stroke(gui, "Gouge" .. i, ax, ay, mx, my, math.max(2, 0.16 * pps), core, 0, 3)
		taper(groove, 0.5, 0)
		groove = stroke(gui, "Gouge" .. i, mx, my, bx, by, math.max(2, 0.16 * pps), core, 0, 3)
		taper(groove, 0, 0.9)
		-- its shadowed lip
		local sx0, sy0 = point(0.04, -0.12 * pps)
		local sx1, sy1 = point(0.92, -0.12 * pps)
		local shade = stroke(gui, "Shade" .. i, sx0, sy0, sx1, sy1, math.max(1, 0.05 * pps), scaled(wall, 0.4), 0.3, 3)
		taper(shade, 0.85, 0.95)
	end
end

-- Plaster cracked out from both top corners of an opening `openWidth` studs wide centred on the canvas bottom.
function DreadArt.cracks(part: BasePart, seed: number, openWidth: number, wall: Color3)
	local random = Rng.new(seed)
	local gui, size = canvas(part, Enum.NormalId.Front, 16, 100)
	local pps = size.X / part.Size.X
	local half = openWidth / 2 * pps
	local dark = scaled(wall, 0.3)
	for _, side in { -1, 1 } do
		local x = (size.X / 2 + side * half) / size.X
		for branch = 1, 3 do
			SurfaceArt.crack(
				gui,
				random,
				x,
				0.98,
				180 + side * random:NextNumber(20, 70) * (if branch == 2 then 0.4 else 1),
				random:NextInteger(3, 5),
				size.Y * 0.22,
				2,
				dark,
				2
			)
		end
	end
	-- the plaster knocked off the lintel's corners
	for _, side in { -1, 1 } do
		local cx = size.X / 2 + side * half
		local chip = SurfaceArt.frame(gui, "Chip", 0, 0, 0, 0, scaled(wall, 1.3), 0.2, 1)
		chip.AnchorPoint = Vector2.new(0.5, 1)
		chip.Position = UDim2.fromOffset(cx, size.Y)
		chip.Size = UDim2.fromOffset(pps * 0.9, size.Y * 0.4)
		round(chip, 0.4)
	end
end

-- The black plenum where a ceiling tile was knocked out, ragged where the tile broke away.
function DreadArt.hole(part: BasePart, seed: number)
	local random = Rng.new(seed)
	local gui = canvas(part, Enum.NormalId.Front, 14, 90, 0)
	local void = SurfaceArt.frame(gui, "Void", 0.04, 0.04, 0.92, 0.92, VOID, 0, 1)
	void.Rotation = random:NextNumber(-2, 2)
	for i = 1, 4 do
		local x, y = random:NextNumber(0.05, 0.85), random:NextNumber(0.05, 0.85)
		local bite = SurfaceArt.frame(gui, "Ragged" .. i, x, y, 0.16, 0.16, Color3.fromRGB(118, 112, 94), 0.1, 2)
		bite.Rotation = random:NextNumber(0, 90)
	end
end

--------------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------------

-- The hand a line is written in: its font, ink, transparency and how crooked.
local function hand(entry: DreadConfig.Line, wall: Color3): (Enum.Font, Color3, number, number)
	local dark = luminance(wall) < 0.33
	if entry.hand == "Chalk" then
		return Enum.Font.PatrickHand, CHALK, 0.22, 4
	elseif entry.hand == "Paint" then
		return Enum.Font.PatrickHand, PAINT_1989, 0.42, 3
	elseif entry.hand == "Scratched" then
		return Enum.Font.SpecialElite, scaled(wall, if dark then 2.1 else 1.4), 0.2, 6
	end
	return Enum.Font.PatrickHand, if dark then Color3.fromRGB(236, 232, 222) else INK, 0.04, 5
end

-- A scrawled line on the Front face of `part`, in the line's hand (a 1989 line is half worn away).
function DreadArt.writing(part: BasePart, entry: DreadConfig.Line, wall: Color3, seed: number)
	local random = Rng.new(seed)
	local gui = canvas(part, Enum.NormalId.Front, 20, 120)
	local font, ink, transparency, crooked = hand(entry, wall)
	local label = SurfaceArt.text(gui, "Text", entry.text, 0.01, 0.02, 0.98, 0.96, ink, font, 3)
	label.TextTransparency = transparency
	label.Rotation = random:NextNumber(-crooked, crooked)
	if entry.year < 2000 then
		-- the old paint has flaked: patches of the wall show through
		for i = 1, 4 do
			local flake = SurfaceArt.frame(
				gui,
				"Flake" .. i,
				random:NextNumber(0.05, 0.85),
				random:NextNumber(0.1, 0.7),
				random:NextNumber(0.04, 0.1),
				random:NextNumber(0.12, 0.3),
				wall,
				0.25,
				4
			)
			round(flake, 0.5)
		end
	elseif entry.hand == "Marker" then
		-- the marker ran where it was pressed hardest
		local run = SurfaceArt.frame(gui, "Run", random:NextNumber(0.1, 0.9), 0.7, 0.008, 0.28, ink, 0.35, 2)
		taper(run, 0, 1)
	end
end

-- Tally marks: `groups` gates of five, then a gate that was never finished.
function DreadArt.tally(part: BasePart, seed: number, groups: number, wall: Color3)
	local random = Rng.new(seed)
	local gui, size = canvas(part, Enum.NormalId.Front, 18, 90)
	local ink = scaled(wall, if luminance(wall) < 0.33 then 2.2 else 0.35)
	local gate = size.X / (groups + 1)
	for g = 0, groups do
		local marks = if g == groups then random:NextInteger(1, 3) else 4
		local x0 = g * gate + gate * 0.12
		for m = 0, marks - 1 do
			local x = x0 + m * gate * 0.19 + random:NextNumber(-1, 1)
			stroke(gui, "Mark", x, size.Y * 0.15, x + random:NextNumber(-2, 2), size.Y * 0.88, 2, ink, 0.1, 2)
		end
		if g < groups then
			stroke(gui, "Bar", x0 - 2, size.Y * 0.75, x0 + gate * 0.7, size.Y * 0.25, 2, ink, 0.1, 3)
		end
	end
end

-- A wall clock's face (the Front face of a square host), stopped at DreadConfig.Clock: the HourHand's and MinuteHand's
-- Rotation (degrees clockwise from twelve) are the time.
function DreadArt.clock(part: BasePart)
	local gui, size = canvas(part, Enum.NormalId.Front, 20, 90)
	local face = SurfaceArt.frame(gui, "Face", 0.04, 0.04, 0.92, 0.92, Color3.fromRGB(226, 220, 198), 0, 1)
	round(face, 0.5)
	local rim = Instance.new("UIStroke")
	rim.Color = Color3.fromRGB(28, 28, 30)
	rim.Thickness = math.max(2, size.X * 0.05)
	rim.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	rim.Parent = face
	local cx, cy, r = size.X / 2, size.Y / 2, size.X * 0.42
	for hour = 0, 11 do
		local a = math.rad(hour * 30)
		local inner = if hour % 3 == 0 then 0.78 else 0.86
		stroke(
			gui,
			"Tick",
			cx + math.sin(a) * r * inner,
			cy - math.cos(a) * r * inner,
			cx + math.sin(a) * r * 0.95,
			cy - math.cos(a) * r * 0.95,
			if hour % 3 == 0 then 3 else 2,
			INK,
			0,
			2
		)
	end
	local time = DreadConfig.Clock
	local hourAngle = (time.Hour % 12 + time.Minute / 60) * 30
	local minuteAngle = time.Minute * 6
	local function clockHand(name: string, angle: number, length: number, width: number)
		local a = math.rad(angle)
		local frame = SurfaceArt.frame(gui, name, 0, 0, 0, 0, INK, 0, 3)
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromOffset(cx + math.sin(a) * length / 2, cy - math.cos(a) * length / 2)
		frame.Size = UDim2.fromOffset(width, length)
		frame.Rotation = angle
	end
	clockHand("HourHand", hourAngle, r * 0.55, math.max(2, size.X * 0.045))
	clockHand("MinuteHand", minuteAngle, r * 0.86, math.max(2, size.X * 0.03))
	local pin = SurfaceArt.frame(gui, "Pin", 0.47, 0.47, 0.06, 0.06, INK, 0, 4)
	round(pin, 0.5)
	-- the glass cracked across
	stroke(
		gui,
		"Crack",
		size.X * 0.2,
		size.Y * 0.3,
		size.X * 0.66,
		size.Y * 0.62,
		1,
		Color3.fromRGB(250, 250, 244),
		0.3,
		5
	)
	stroke(
		gui,
		"Crack",
		size.X * 0.66,
		size.Y * 0.62,
		size.X * 0.82,
		size.Y * 0.52,
		1,
		Color3.fromRGB(250, 250, 244),
		0.4,
		5
	)
	part:SetAttribute("ClockHour", time.Hour)
	part:SetAttribute("ClockMinute", time.Minute)
end

-- The printed lockdown notice (a sheet of paper's Front face).
function DreadArt.notice(part: BasePart, seed: number)
	local random = Rng.new(seed)
	local gui = canvas(part, Enum.NormalId.Front, 20, 60)
	local notice = DreadConfig.Notice
	SurfaceArt.frame(gui, "Band", 0.06, 0.05, 0.88, 0.16, Color3.fromRGB(28, 26, 26), 0, 1)
	SurfaceArt.text(
		gui,
		"Heading",
		notice.Heading,
		0.08,
		0.06,
		0.84,
		0.14,
		Color3.fromRGB(236, 232, 220),
		Enum.Font.Oswald,
		2
	)
	local y = 0.27
	for i, text in notice.Lines do
		SurfaceArt.text(gui, "Line" .. i, text, 0.08, y, 0.84, 0.1, INK, Enum.Font.SpecialElite, 2)
		y += 0.14
	end
	-- a corner torn where it was pulled at, the tape still on
	SurfaceArt.frame(gui, "Tape", 0.38, 0, 0.24, 0.04, Color3.fromRGB(200, 190, 150), 0.3, 3)
	SurfaceArt.grime(gui, Color3.fromRGB(90, 76, 50), random:NextNumber(0.2, 0.4), false, 4)
end

-- A child's crayon drawing (a sheet of paper's Front face): a door, a small figure, and beside them a tall thin
-- figure with long arms and a white face, taller than the door.
function DreadArt.drawing(part: BasePart, seed: number)
	local random = Rng.new(seed)
	local gui, size = canvas(part, Enum.NormalId.Front, 20, 70)
	local w, h = size.X, size.Y
	local function jitter(): number
		return random:NextNumber(-1.2, 1.2)
	end
	-- the door, brown, with its knob
	local door = SurfaceArt.frame(gui, "Door", 0.08, 0.42, 0.22, 0.42, CRAYON_BROWN, 0.25, 1)
	door.Rotation = random:NextNumber(-2, 2)
	SurfaceArt.frame(gui, "Knob", 0.25, 0.62, 0.03, 0.02, CRAYON_BLACK, 0, 2)
	-- the small figure (us), blue
	local kx, ky = w * 0.42, h * 0.62
	stroke(gui, "Kid", kx, ky, kx + jitter(), ky + h * 0.12, 2, CRAYON_BLUE, 0, 2)
	stroke(gui, "KidLeg", kx, ky + h * 0.12, kx - w * 0.03, ky + h * 0.2, 2, CRAYON_BLUE, 0, 2)
	stroke(gui, "KidLeg", kx, ky + h * 0.12, kx + w * 0.03, ky + h * 0.2, 2, CRAYON_BLUE, 0, 2)
	stroke(gui, "KidArm", kx - w * 0.04, ky + h * 0.05, kx + w * 0.04, ky + h * 0.05, 2, CRAYON_BLUE, 0, 2)
	local kidHead = SurfaceArt.frame(gui, "KidHead", 0, 0, 0, 0, CRAYON_BLUE, 0.1, 2)
	kidHead.AnchorPoint = Vector2.new(0.5, 1)
	kidHead.Position = UDim2.fromOffset(kx, ky)
	kidHead.Size = UDim2.fromOffset(w * 0.06, w * 0.06)
	round(kidHead, 0.5)
	-- the tall one: black, thin, its head over the top of the door
	local tx, top, feet = w * 0.72, h * 0.2, h * 0.86
	stroke(gui, "Figure", tx, top, tx + jitter(), feet - h * 0.2, 3, CRAYON_BLACK, 0, 2)
	stroke(gui, "Leg", tx, feet - h * 0.2, tx - w * 0.05, feet, 3, CRAYON_BLACK, 0, 2)
	stroke(gui, "Leg", tx, feet - h * 0.2, tx + w * 0.06, feet, 3, CRAYON_BLACK, 0, 2)
	stroke(gui, "Arm", tx, top + h * 0.06, tx - w * 0.13, top + h * 0.42, 2, CRAYON_BLACK, 0, 2)
	stroke(gui, "Arm", tx, top + h * 0.06, tx + w * 0.14, top + h * 0.44, 2, CRAYON_BLACK, 0, 2)
	for f = -1, 1 do
		stroke(
			gui,
			"Finger",
			tx - w * 0.13,
			top + h * 0.42,
			tx - w * (0.15 + f * 0.02),
			top + h * 0.49,
			1,
			CRAYON_BLACK,
			0,
			2
		)
		stroke(
			gui,
			"Finger",
			tx + w * 0.14,
			top + h * 0.44,
			tx + w * (0.16 + f * 0.02),
			top + h * 0.51,
			1,
			CRAYON_BLACK,
			0,
			2
		)
	end
	local face = SurfaceArt.frame(gui, "Face", 0, 0, 0, 0, MASK_WHITE, 0, 3)
	face.AnchorPoint = Vector2.new(0.5, 1)
	face.Position = UDim2.fromOffset(tx, top + 2)
	face.Size = UDim2.fromOffset(w * 0.14, h * 0.12)
	round(face, 0.5)
	local outline = Instance.new("UIStroke")
	outline.Color = CRAYON_BLACK
	outline.Thickness = 2
	outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	outline.Parent = face
	for e = -1, 1, 2 do
		local eye = SurfaceArt.frame(gui, "Eye", 0, 0, 0, 0, CRAYON_BLACK, 0, 4)
		eye.AnchorPoint = Vector2.new(0.5, 0.5)
		eye.Position = UDim2.fromOffset(tx + e * w * 0.03, top - h * 0.06)
		eye.Size = UDim2.fromOffset(w * 0.025, h * 0.025)
		round(eye, 0.5)
	end
	stroke(gui, "Crack", tx - w * 0.02, top - h * 0.11, tx + w * 0.03, top - h * 0.02, 1, CRAYON_BLACK, 0, 4)
	SurfaceArt.text(
		gui,
		"Caption",
		DreadConfig.DrawingCaption,
		0.06,
		0.04,
		0.88,
		0.1,
		CRAYON_BLUE,
		Enum.Font.PatrickHand,
		3
	)
end

--------------------------------------------------------------------------------
-- Decay
--------------------------------------------------------------------------------

-- A water stain spread from a ceiling corner (the canvas top, the corner on the `left` or right), runs down the wall.
function DreadArt.stain(part: BasePart, seed: number, left: boolean)
	local random = Rng.new(seed)
	local gui, size = canvas(part, Enum.NormalId.Front, 12, 90)
	local cx = if left then 0.12 else 0.88
	SurfaceArt.stain(gui, cx, 0.05, 1.1, 0.7, STAIN, 0.55, STAIN_RING, 1)
	SurfaceArt.stain(gui, cx, 0.02, 0.7, 0.42, scaled(STAIN, 0.8), 0.45, STAIN_RING, 2)
	for _ = 1, random:NextInteger(3, 5) do
		local x = cx + (if left then 1 else -1) * random:NextNumber(0.05, 0.55)
		SurfaceArt.streak(
			gui,
			x,
			size.Y * 0.22,
			random:NextNumber(2, 4),
			size.Y * random:NextNumber(0.4, 0.75),
			STAIN,
			0.6,
			3
		)
	end
end

-- A bloom of black mould.
function DreadArt.mould(part: BasePart, seed: number)
	local random = Rng.new(seed)
	local gui = canvas(part, Enum.NormalId.Front, 12, 80)
	SurfaceArt.stain(gui, 0.5, 0.5, 0.95, 0.85, MOULD, 0.75, nil, 1)
	for i = 1, random:NextInteger(7, 11) do
		local d = random:NextNumber(0.08, 0.24)
		local spot = SurfaceArt.stain(
			gui,
			random:NextNumber(0.2, 0.8),
			random:NextNumber(0.2, 0.8),
			d,
			d * random:NextNumber(0.7, 1.2),
			scaled(MOULD, random:NextNumber(0.6, 1.2)),
			random:NextNumber(0.15, 0.45),
			nil,
			2
		)
		spot.Name = "Spot" .. i
	end
end

-- Threads strung across an upper corner (the corner on the `left` or right of the canvas top).
function DreadArt.cobweb(part: BasePart, seed: number, left: boolean)
	local random = Rng.new(seed)
	local gui, size = canvas(part, Enum.NormalId.Front, 20, 45)
	local ox = if left then 0 else size.X
	local dir = if left then 1 else -1
	local spokes: { Vector2 } = {}
	for i = 0, 4 do
		local a = math.rad(i * 22.5 + random:NextNumber(-5, 5))
		local reach = math.min(size.X, size.Y) * random:NextNumber(0.75, 1)
		local tip = Vector2.new(ox + dir * math.cos(a) * reach, math.sin(a) * reach)
		table.insert(spokes, tip)
		stroke(gui, "Thread", ox, 0, tip.X, tip.Y, 1, WEB, 0.45, 2)
	end
	for ring = 1, 3 do
		local f = ring / 4
		for i = 1, #spokes - 1 do
			local a, b = spokes[i], spokes[i + 1]
			stroke(gui, "Ring", ox + (a.X - ox) * f, a.Y * f, ox + (b.X - ox) * f, b.Y * f, 1, WEB, 0.55, 2)
		end
	end
end

-- A long strip of paint peeled back to the wall underneath (the canvas is tall and narrow).
function DreadArt.peel(part: BasePart, seed: number, wall: Color3)
	local random = Rng.new(seed)
	local gui = canvas(part, Enum.NormalId.Front, 14, 80)
	local bare = scaled(wall, 0.62)
	local strip = SurfaceArt.frame(gui, "Bare", 0.18, 0.02, 0.64, 0.96, bare, 0.1, 1)
	round(strip, 0.25)
	local lip = Instance.new("UIStroke")
	lip.Color = scaled(wall, 1.3)
	lip.Thickness = 2
	lip.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	lip.Parent = strip
	for i = 1, 3 do
		local y = random:NextNumber(0.1, 0.8)
		SurfaceArt.frame(
			gui,
			"Shred" .. i,
			random:NextNumber(0.1, 0.6),
			y,
			random:NextNumber(0.2, 0.35),
			0.03,
			bare,
			0.2,
			2
		)
	end
end

-- The brown-black scorch round a failing bulb (a ceiling host's Front face, looking down).
function DreadArt.soot(part: BasePart, seed: number)
	local random = Rng.new(seed)
	local gui = canvas(part, Enum.NormalId.Front, 10, 70)
	SurfaceArt.stain(gui, 0.5, 0.5, 0.95, 0.95, Color3.fromRGB(30, 22, 14), 0.55, nil, 1)
	SurfaceArt.stain(gui, 0.5 + random:NextNumber(-0.05, 0.05), 0.5, 0.5, 0.5, Color3.fromRGB(16, 12, 8), 0.35, nil, 2)
end

-- A phone's cracked glass (the screen's Front face), its faint light still on.
function DreadArt.screen(part: BasePart, seed: number)
	local random = Rng.new(seed)
	local gui, size = canvas(part, Enum.NormalId.Front, 40, 40, 0)
	local hx, hy = size.X * random:NextNumber(0.3, 0.7), size.Y * random:NextNumber(0.25, 0.6)
	for i = 1, 6 do
		local a = math.rad(i * 60 + random:NextNumber(-20, 20))
		local reach = size.Y * random:NextNumber(0.25, 0.6)
		stroke(
			gui,
			"Crack",
			hx,
			hy,
			hx + math.sin(a) * reach,
			hy + math.cos(a) * reach,
			1,
			Color3.fromRGB(235, 240, 250),
			0.25,
			2
		)
	end
	-- a notification bar that never got read
	SurfaceArt.frame(gui, "Banner", 0.08, 0.08, 0.84, 0.1, Color3.fromRGB(200, 214, 230), 0.35, 1)
end

-- A locker door's vents and number plate (the Front face of a torn-off door lying on its back).
function DreadArt.louvres(part: BasePart, number: number)
	local gui = canvas(part, Enum.NormalId.Front, 16, 60)
	for i = 0, 3 do
		SurfaceArt.frame(gui, "Vent" .. i, 0.25, 0.06 + i * 0.035, 0.5, 0.018, VOID, 0.1, 2)
	end
	SurfaceArt.frame(gui, "Plate", 0.36, 0.24, 0.28, 0.06, Color3.fromRGB(180, 176, 160), 0, 2)
	SurfaceArt.text(gui, "Number", tostring(number), 0.37, 0.24, 0.26, 0.06, INK, Enum.Font.RobotoMono, 3)
	SurfaceArt.frame(gui, "Dent", 0.2, 0.55, 0.6, 0.12, scaled(part.Color, 0.55), 0.5, 1)
end

-- Dead flies on a sill (the Front face of a thin host lying on it).
function DreadArt.flies(part: BasePart, seed: number)
	local random = Rng.new(seed)
	local gui = canvas(part, Enum.NormalId.Front, 40, 30)
	for i = 1, random:NextInteger(9, 15) do
		local fly = SurfaceArt.frame(
			gui,
			"Fly" .. i,
			random:NextNumber(0.05, 0.9),
			random:NextNumber(0.1, 0.8),
			0.04,
			0.09,
			Color3.fromRGB(14, 12, 12),
			0.05,
			2
		)
		fly.Rotation = random:NextNumber(0, 180)
		round(fly, 0.5)
	end
end

return table.freeze(DreadArt)
