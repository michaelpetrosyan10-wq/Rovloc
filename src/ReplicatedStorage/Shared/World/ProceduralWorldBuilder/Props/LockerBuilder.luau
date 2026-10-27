--!strict
-- LockerBuilder: the hideable lockers of the Level 3 locker rooms and halls. Fixture kind "HideableLocker": one per
-- Locker anchor, rebuilt into Workspace.Runtime.<level>.HideableLockers at every run start, so every run begins with
-- each door shut and each locker empty.
--
-- Locker space: X across the door, Y up from the room floor, -Z out through the door (the anchor's LookVector). The
-- anchor is the floor centre of the footprint; the back stands against the wall behind it (the gap to that wall's
-- face is read from the layout, so the back is flush whatever the wall's thickness). The body is a hollow steel shell
-- (recessed floor pan, back, sides, top, a hat shelf above head height and a louvred header rail) around an interior
-- 2.7 wide, 2.4 deep and 6.45 clear above its floor. The door (leaf "Door", hinged about its outer edge on the -X
-- side, opening outward) carries five horizontal vent slits at the hidden player's eye height: real gaps between
-- steel slats, so the LockerPeeking camera and the Creature's line-of-sight rays both see through them (and the slats
-- in between block those rays).
--
-- Attachments on the Base (the floor pan), all looking out through the door:
--   HideAnchor   interior floor centre (where the hidden player stands)
--   PeekAnchor   the hidden player's eye right behind the middle slit (the LockerPeeking camera)
--   ExitAnchor   floor level, 2.2 studs in front of the closed door, facing away from the locker
--   HidePrompt   in front of the door; hosts the Hide prompt (created disabled)
--   DoorLanding  where the LockerRip leaves the torn door's hinge pivot: lying face up in front of the row, on the
--                first of three spots the room has clear floor for (inside its walls, off its benches)
-- Attributes AnchorId, LevelId, ZoneId, DoorOpen = false; OccupantUserId stays unset until someone hides. Tags
-- HideableLocker and Interactable.
--
-- Collision: the shell and the door are MonsterPassthrough (players bump into them, the Creature walks through and
-- reaches in, a hidden player is NoCollide under its Locked control lock); hand-scale details collide with nothing.
-- setDoor and setRipped are pure poses of the Door leaf (the hiding mechanic tweens them and writes DoorOpen).
-- Variety (seeded by the run): each bank of lockers shares a faded paint, each locker gets its own shade, rust level,
-- rust streak below the slits, an occasional replacement door in another colour and a dent in the door.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(script.Parent.Parent.Geometry)
local PropKit = require(script.Parent.PropKit)

type Layout = LayoutSchema.LevelLayout
type Room = LayoutSchema.Room
type Anchor = LayoutSchema.Anchor
type PartOptions = Geometry.PartOptions

export type LockerSpec = {
	cframe: CFrame, -- floor centre of the footprint, LookVector out through the door
	anchorId: string,
	levelId: string,
	zoneId: string,
	number: number, -- printed on the number plate
	wallGap: number?, -- from `cframe` back to the face of the wall behind it; nil for a free-standing locker
	paint: Color3, -- the bank's paint
	-- Whether the torn-off door may land on this floor footprint (its four world-space corners); nil takes the first
	-- landing choice.
	landingClear: ((footprint: { Vector3 }) -> boolean)?,
}

local W = Attributes.World

local KIND = "HideableLocker"
local FOLDER = "HideableLockers"
local DOOR = "Door"
local PART_BUDGET = 24

-- Shell
local WIDTH = 2.9 -- outer, across the door (Locker anchors stand 3 studs apart along a wall)
local DEPTH = 2.6 -- outer, from the wall to the door face
local HEIGHT = 7.7
local SIDE_T = 0.1
local BACK_T = 0.1
local TOP_T = 0.1
local FLOOR_Y = 0.35 -- top of the floor pan: the interior floor
local PLINTH_RECESS = 0.06 -- the floor pan's front sits back under the door
local SHELF_Y = 6.8 -- underside of the hat shelf
local SHELF_T = 0.08
local HEADER_T = 0.08
local INNER_HALF = WIDTH / 2 - SIDE_T
local WALL_CLEARANCE = 0.02 -- the back never touches (or z-fights) the wall
local WALL_SNAP = 0.5 -- a wall this close to the nominal back position is the one the locker stands against

-- Door leaf
local DOOR_T = 0.1
local DOOR_GAP = 0.03 -- to each side wall
local DOOR_BOTTOM = FLOOR_Y + 0.05
local DOOR_TOP = 7.0
local HEADER_BOTTOM = DOOR_TOP + 0.05
local HINGE_X = -INNER_HALF + DOOR_GAP
local LATCH_X = INNER_HALF - DOOR_GAP
local DOOR_WIDTH = LATCH_X - HINGE_X
local SWING = 1 -- the door hangs on the -X side, so it swings toward -X (see swingOf)
local DOOR_OPEN_ANGLE = math.rad(110)
local STILE_W = 0.3

-- Vent slits: SLITS gaps between SLITS - 1 slats. SLITS is odd so the middle gap is centred on the peeking eye.
local SLITS = 5
local SLIT_GAP = 0.14
local SLAT_H = 0.1
local SLAT_INSET = 0.02 -- slats sit back from the door face
local SLAT_T = 0.06
local ROOT_HEIGHT = 3 -- R15 HumanoidRootPart centre above the feet (HipHeight 2 + half the 2-stud root)
local PEEK_EYE_Y = FLOOR_Y
	+ ROOT_HEIGHT
	+ CameraConfig.EyeHeightAboveRoot.Standing
	+ CameraConfig.StateOffsets.LockerPeeking.Y
local SLIT_BAND = SLITS * SLIT_GAP + (SLITS - 1) * SLAT_H
local SLIT_BOTTOM = PEEK_EYE_Y - SLIT_BAND / 2
local SLIT_TOP = SLIT_BOTTOM + SLIT_BAND
local PEEK_BEHIND = 0.3 -- eye distance behind the door's inner face

-- Anchors and prompt
local EXIT_DISTANCE = 2.2
local PROMPT_OUT = 0.6
local PROMPT_Y = 3.6

local HIDE_PROMPT: PropKit.PromptSpec = {
	kind = "Hide",
	action = "Prompt.Hide",
	object = "Prompt.Locker",
	hold = 0.25,
}

-- Ripping (LockerRip): the Creature wrenches the door against its hinge, tears it off and flings it to the floor.
local RIP_WRENCH = 0.3 -- share of the rip spent wrenching
local RIP_WRENCH_ANGLE = math.rad(72)
local RIP_ARC = 1.4 -- peak lift of the flung door
local LANDING = "DoorLanding" -- Base attachment: where the torn door's hinge pivot lands
local LANDING_SIDE = 2.6 -- how far along the row from its own locker the torn door's centre lands
local LANDING_CLEARANCE = 0.55 -- from the row's door line to the landed door's nearest edge
-- Landing choices in order of preference: the door's height axis leaning out toward its latch side, toward its hinge
-- side, or pointing straight out from the row.
local LANDING_HEADINGS: { number } = { 1, -1, 0 }
local LANDING_WALL_MARGIN = 0.9 -- from a room edge: half a wall, a door trim's reveal, and air
local DOOR_PROUD = 0.12 -- handle, staple and dents stand this far off the door's painted face
local FLOOR_CLEARANCE = 0.005 -- the flung door never dips closer to the floor than this
local LANDING_OBSTACLE_MARGIN = 0.25

-- Finish
local PAINTS: { Color3 } = {
	Color3.fromRGB(58, 86, 84), -- faded teal
	Color3.fromRGB(50, 62, 80), -- school navy
	Color3.fromRGB(94, 50, 42), -- oxide red
	Color3.fromRGB(76, 82, 58), -- olive drab
	Color3.fromRGB(80, 84, 86), -- battleship grey
	Color3.fromRGB(104, 92, 54), -- tired mustard
}
local RUST = Color3.fromRGB(92, 54, 34)
local RUST_DARK = Color3.fromRGB(56, 38, 28)
local GRIME = Color3.fromRGB(16, 15, 13)
local STEEL = Color3.fromRGB(74, 76, 78)
local PLATE = Color3.fromRGB(146, 142, 124) -- enamel number plate
local INK = Color3.fromRGB(28, 28, 26)
local CORRODED_ABOVE = 0.65 -- rust level past which the paint has given way to corrosion
local REPLACEMENT_DOOR_CHANCE = 0.15
local DENT_CHANCE = 0.7
local NUMBER_FONT = Enum.Font.RobotoMono

local LockerBuilder = {}

LockerBuilder.Kind = KIND
LockerBuilder.Folder = FOLDER
LockerBuilder.DoorLeaf = DOOR
LockerBuilder.PartBudget = PART_BUDGET
LockerBuilder.DoorOpenAngle = DOOR_OPEN_ANGLE

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Axis-aligned box between two locker-space corners.
local function block(
	parent: Instance,
	name: string,
	frame: CFrame,
	a: Vector3,
	b: Vector3,
	key: string,
	options: PartOptions?
): Part
	local lo, hi = a:Min(b), a:Max(b)
	return Geometry.part(parent, name, frame * CFrame.new((lo + hi) / 2), hi - lo, key, options)
end

local function detail(part: BasePart): BasePart
	PropKit.detail(part)
	return part
end

-- `color` nudged in hue, saturation and brightness so no two lockers of a bank match exactly.
local function shade(color: Color3, random: Random, amount: number): Color3
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(
		(h + random:NextNumber(-0.012, 0.012)) % 1,
		math.clamp(s * random:NextNumber(1 - amount, 1 + amount), 0, 1),
		math.clamp(v * random:NextNumber(1 - amount, 1), 0, 1)
	)
end

-- Paint aged by `rust` (0 = sound paint, 1 = mostly corrosion).
local function weathered(paint: Color3, rust: number): Color3
	return paint:Lerp(RUST, 0.12 + 0.3 * rust):Lerp(GRIME, 0.1 * rust)
end

local function printText(part: BasePart, name: string, text: string)
	local gui = Instance.new("SurfaceGui")
	gui.Name = name
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 96
	gui.LightInfluence = 1
	gui.MaxDistance = 40
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = text
	label.TextColor3 = INK
	label.TextScaled = true
	label.FontFace = Font.fromEnum(NUMBER_FONT)
	label.Parent = gui
	gui.Parent = part
end

-- Distance from the anchor back to the face of the wall it stands against: the edge of its room that its back
-- faces, less half that wall's thickness. Nil when the anchor does not face straight out of a wall.
local function wallGap(room: Room, anchor: Anchor): number?
	local look = CFrame.Angles(0, math.rad(anchor.yaw or 0), 0).LookVector
	local rect = room.rect
	local size = WorldConfig.FootprintSize
	local distance: number
	local exterior: boolean
	if math.abs(look.X) > 0.999 then
		local wallX = if look.X > 0 then rect.x else rect.x + rect.w
		distance = math.abs(anchor.pos.X - wallX)
		exterior = math.abs(wallX) < Geometry.EPS or math.abs(wallX - size.X) < Geometry.EPS
	elseif math.abs(look.Z) > 0.999 then
		local wallZ = if look.Z > 0 then rect.z else rect.z + rect.d
		distance = math.abs(anchor.pos.Z - wallZ)
		exterior = math.abs(wallZ) < Geometry.EPS or math.abs(wallZ - size.Y) < Geometry.EPS
	else
		return nil
	end
	local thickness = if exterior then WorldConfig.ExteriorWallThickness else WorldConfig.WallThickness
	return distance - thickness / 2
end

-- Locker-space Z of the back face: just off the wall when one stands behind, else half the depth.
local function backFace(gap: number?): number
	if gap and math.abs(gap - DEPTH / 2) <= WALL_SNAP then
		return gap - WALL_CLEARANCE
	end
	return DEPTH / 2
end

-- A floor test for torn-door landings in `room`: every footprint corner stays inside the room, clear of its walls and
-- door trims, and the footprint stays off the room's platforms (benches, bleachers).
local function clearFloor(layout: Layout, room: Room): (footprint: { Vector3 }) -> boolean
	local origin = WorldConfig.levelOrigin(layout.id)
	local obstacles: { LayoutSchema.Rect } = {}
	for _, platform in (layout.platforms or {}) :: { LayoutSchema.Platform } do
		if platform.room == room.id then
			table.insert(obstacles, Geometry.insetRect(platform.rect, -LANDING_OBSTACLE_MARGIN))
		end
	end
	return function(points: { Vector3 }): boolean
		local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
		for _, point in points do
			local p = point - origin
			if not LayoutSchema.rectContains(room.rect, p.X, p.Z, LANDING_WALL_MARGIN) then
				return false
			end
			x0, z0, x1, z1 = math.min(x0, p.X), math.min(z0, p.Z), math.max(x1, p.X), math.max(z1, p.Z)
		end
		local area = Geometry.rect(x0, z0, x1 - x0, z1 - z0)
		for _, obstacle in obstacles do
			if Geometry.rectIntersection(area, obstacle) then
				return false
			end
		end
		return true
	end
end

-- Lockers along one wall form a bank: same room, same facing, same wall line.
local function bankKey(anchor: Anchor, cframe: CFrame): string
	local look = cframe.LookVector
	return string.format(
		"%s|%d|%d",
		anchor.room,
		math.round(anchor.yaw or 0),
		math.round(cframe.Position:Dot(look) * 10)
	)
end

local function bankPaint(banks: { [string]: Color3 }, key: string, random: Random): Color3
	local existing = banks[key]
	if existing then
		return existing
	end
	local chosen = PAINTS[random:NextInteger(1, #PAINTS)]
	banks[key] = chosen
	return chosen
end

-- +1 when the door hangs on the -X side (it swings toward -X when opened), -1 when on the +X side.
local function swingOf(model: Model): number?
	local base = model.PrimaryPart
	local rest = PropKit.leafRest(model, DOOR)
	if not (base and rest) then
		return nil
	end
	return if base.CFrame:PointToObjectSpace(rest.Position).X <= 0 then 1 else -1
end

-- The door's floor-level corners in its own (hinge pivot) space: the hinge edge at X = 0, the latch edge toward
-- `swing` * X.
local function doorCorners(swing: number): { Vector3 }
	local latch = swing * DOOR_WIDTH
	return {
		Vector3.new(0, DOOR_BOTTOM, 0),
		Vector3.new(latch, DOOR_BOTTOM, 0),
		Vector3.new(latch, DOOR_TOP, 0),
		Vector3.new(0, DOOR_TOP, 0),
	}
end

-- The eight corners of the box holding every door part, in its own (hinge pivot) space.
local function doorBox(swing: number): { Vector3 }
	local out: { Vector3 } = {}
	for _, corner in doorCorners(swing) do
		table.insert(out, corner + Vector3.new(0, 0, -DOOR_PROUD))
		table.insert(out, corner + Vector3.new(0, 0, DOOR_T))
	end
	return out
end

-- `transform` raised just enough that no part of the door it poses dips into the floor (rest-pivot Y = 0).
local function aboveFloor(transform: CFrame, swing: number): CFrame
	local lowest = math.huge
	for _, corner in doorBox(swing) do
		lowest = math.min(lowest, (transform * corner).Y)
	end
	if lowest < FLOOR_CLEARANCE then
		return CFrame.new(0, FLOOR_CLEARANCE - lowest, 0) * transform
	end
	return transform
end

-- World-space floor footprint of the door posed at `pivot` (its hinge pivot's world CFrame).
local function footprint(pivot: CFrame, swing: number): { Vector3 }
	local out: { Vector3 } = {}
	for _, corner in doorCorners(swing) do
		table.insert(out, pivot * corner)
	end
	return out
end

--------------------------------------------------------------------------------
-- Poses
--------------------------------------------------------------------------------

-- The door's transform about its hinge for `openness` 0 (shut) .. 1 (DoorOpenAngle, about 110 degrees outward).
function LockerBuilder.doorTransform(swing: number, openness: number): CFrame
	return CFrame.Angles(0, swing * math.clamp(openness, 0, 1) * DOOR_OPEN_ANGLE, 0)
end

-- The torn-off door lying painted face up on the floor in front of the row, relative to its rest hinge pivot. Its
-- height axis leans out toward the latch side (`heading` 1), the hinge side (-1) or points straight out (0); its
-- centre lands LANDING_SIDE along the row toward that side, its nearest edge LANDING_CLEARANCE in front of the doors.
function LockerBuilder.landingTransform(swing: number, heading: number): CFrame
	local along = if heading == 0 then Vector3.new(0, 0, -1) else Vector3.new(swing * heading, 0, -0.5).Unit
	local down = Vector3.new(0, -1, 0)
	local across = along:Cross(down) -- where the door's +X lands (painted face, -Z, up)
	local lo = Vector3.new(math.huge, math.huge, math.huge)
	local hi = -lo
	for _, corner in doorCorners(swing) do
		local p = across * corner.X + along * corner.Y
		lo, hi = lo:Min(p), hi:Max(p)
	end
	local lockerCentre = -swing * HINGE_X -- the locker's centre line, seen from the hinge
	local x = lockerCentre + swing * heading * LANDING_SIDE - (lo.X + hi.X) / 2
	local z = -LANDING_CLEARANCE - hi.Z
	return CFrame.fromMatrix(Vector3.new(x, DOOR_T + 0.01, z), across, along, down)
end

-- The door's transform about its hinge `t` of the way through being ripped off (0 = shut, 1 = lying at `landed`):
-- wrenched open against the hinge, then torn free and flung in an arc to the floor (never through it).
function LockerBuilder.rippedTransform(swing: number, landed: CFrame, t: number): CFrame
	local progress = math.clamp(t, 0, 1)
	local wrenched = CFrame.new(swing * 0.06, 0.18, -0.3) * CFrame.Angles(0, swing * RIP_WRENCH_ANGLE, 0)
	if progress <= RIP_WRENCH then
		local s = progress / RIP_WRENCH
		return CFrame.new():Lerp(wrenched, 1 - (1 - s) * (1 - s))
	end
	local s = (progress - RIP_WRENCH) / (1 - RIP_WRENCH)
	return aboveFloor(CFrame.new(0, 4 * RIP_ARC * s * (1 - s), 0) * wrenched:Lerp(landed, s), swing)
end

-- Where `model`'s torn door lands, relative to its rest pivot (the builder's DoorLanding choice).
local function landedOf(model: Model, swing: number): CFrame
	local base = model.PrimaryPart
	local rest = PropKit.leafRest(model, DOOR)
	local landing = if base then base:FindFirstChild(LANDING) else nil
	if base and rest and landing and landing:IsA("Attachment") then
		return rest:ToObjectSpace(base.CFrame * landing.CFrame)
	end
	return LockerBuilder.landingTransform(swing, LANDING_HEADINGS[1])
end

-- Poses the door `openness` 0 (shut) .. 1 (fully open). Returns false when `model` is not a locker.
function LockerBuilder.setDoor(model: Model, openness: number): boolean
	local swing = swingOf(model)
	if not swing then
		return false
	end
	return PropKit.poseLeaf(model, DOOR, LockerBuilder.doorTransform(swing, openness))
end

-- Poses the door `t` 0 (shut) .. 1 (torn off and flung to the floor) through the LockerRip. Returns false when
-- `model` is not a locker.
function LockerBuilder.setRipped(model: Model, t: number): boolean
	local swing = swingOf(model)
	if not swing then
		return false
	end
	return PropKit.poseLeaf(model, DOOR, LockerBuilder.rippedTransform(swing, landedOf(model, swing), t))
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function buildDoor(
	model: Model,
	frame: CFrame,
	front: number,
	options: PartOptions,
	spec: LockerSpec,
	random: Random,
	rust: number
)
	local door = PropKit.leaf(model, DOOR, frame * CFrame.new(HINGE_X, 0, front))
	local inner = front + DOOR_T
	block(
		door,
		"DoorLower",
		frame,
		Vector3.new(HINGE_X, DOOR_BOTTOM, front),
		Vector3.new(LATCH_X, SLIT_BOTTOM, inner),
		"TrimMetal",
		options
	)
	block(
		door,
		"DoorUpper",
		frame,
		Vector3.new(HINGE_X, SLIT_TOP, front),
		Vector3.new(LATCH_X, DOOR_TOP, inner),
		"TrimMetal",
		options
	)
	block(
		door,
		"StileHinge",
		frame,
		Vector3.new(HINGE_X, SLIT_BOTTOM, front),
		Vector3.new(HINGE_X + STILE_W, SLIT_TOP, inner),
		"TrimMetal",
		options
	)
	block(
		door,
		"StileLatch",
		frame,
		Vector3.new(LATCH_X - STILE_W, SLIT_BOTTOM, front),
		Vector3.new(LATCH_X, SLIT_TOP, inner),
		"TrimMetal",
		options
	)
	for i = 1, SLITS - 1 do
		local y = SLIT_BOTTOM + i * SLIT_GAP + (i - 1) * SLAT_H
		block(
			door,
			string.format("Slat%d", i),
			frame,
			Vector3.new(HINGE_X + STILE_W, y, front + SLAT_INSET),
			Vector3.new(LATCH_X - STILE_W, y + SLAT_H, front + SLAT_INSET + SLAT_T),
			"TrimMetal",
			options
		)
	end

	-- Lift handle and padlock staple on the latch side.
	local steel: PartOptions = { material = Enum.Material.Metal, color = STEEL }
	detail(
		block(
			door,
			"Handle",
			frame,
			Vector3.new(LATCH_X - 0.34, 3.3, front - 0.07),
			Vector3.new(LATCH_X - 0.22, 3.9, front),
			"TrimMetal",
			steel
		)
	)
	detail(
		block(
			door,
			"Hasp",
			frame,
			Vector3.new(LATCH_X - 0.38, 3.02, front - 0.1),
			Vector3.new(LATCH_X - 0.18, 3.16, front),
			"TrimMetal",
			steel
		)
	)

	-- Enamel number plate on the upper panel.
	local plate = detail(
		block(
			door,
			"NumberPlate",
			frame,
			Vector3.new(-0.28, 6.3, front - 0.02),
			Vector3.new(0.28, 6.58, front),
			"Fixture",
			{ material = Enum.Material.SmoothPlastic, color = PLATE:Lerp(RUST, 0.25 * rust) }
		)
	)
	printText(plate, "Number", Strings.get("Prop.Locker.Number", spec.number))

	-- Rust bleeding down from the slits.
	local streakWidth = random:NextNumber(0.08, 0.22)
	local streakLength = 0.6 + 2.4 * rust
	local streakX = random:NextNumber(HINGE_X + STILE_W, LATCH_X - 0.45 - streakWidth)
	detail(
		block(
			door,
			"RustStreak",
			frame,
			Vector3.new(streakX, math.max(DOOR_BOTTOM + 0.1, SLIT_BOTTOM - 0.02 - streakLength), front - 0.012),
			Vector3.new(streakX + streakWidth, SLIT_BOTTOM - 0.02, front),
			"MetalRust",
			{ material = Enum.Material.CorrodedMetal, color = RUST:Lerp(RUST_DARK, random:NextNumber()) }
		)
	)

	-- A dent: a slightly tilted plate sunk into the door face, so its crease reads where it cuts the panel.
	if random:NextNumber() < DENT_CHANCE then
		local w = random:NextNumber(0.5, 1.0)
		-- Lower panel (under the slits) or the short upper panel between the slits and the number plate.
		local upper = random:NextNumber() < 0.35
		local h = if upper then random:NextNumber(0.3, 0.55) else random:NextNumber(0.35, 0.8)
		local y = if upper
			then random:NextNumber(SLIT_TOP + 0.15 + h / 2, 6.15 - h / 2)
			else random:NextNumber(DOOR_BOTTOM + 0.4 + h / 2, SLIT_BOTTOM - 0.3 - h / 2)
		local x = random:NextNumber(HINGE_X + 0.1 + w / 2, LATCH_X - 0.55 - w / 2)
		local tilt =
			CFrame.Angles(random:NextNumber(-0.07, 0.07), random:NextNumber(-0.07, 0.07), random:NextNumber(-0.4, 0.4))
		detail(
			Geometry.part(
				door,
				"Dent",
				frame * CFrame.new(x, y, front - 0.006) * tilt,
				Vector3.new(w, h, 0.04),
				"TrimMetal",
				{ material = options.material, color = (options.color or STEEL):Lerp(GRIME, 0.18) }
			)
		)
	end
end

-- Builds one locker into `parent`. Every random choice draws from `random`.
function LockerBuilder.buildLocker(parent: Instance, spec: LockerSpec, random: Random): Model
	local frame = spec.cframe
	local back = backFace(spec.wallGap)
	local front = back - DEPTH
	local model = PropKit.model(parent, spec.anchorId, frame)

	local rust = random:NextNumber()
	local material = if rust > CORRODED_ABOVE then Enum.Material.CorrodedMetal else Enum.Material.Metal
	local bodyColor = weathered(shade(spec.paint, random, 0.08), rust)
	local doorPaint = if random:NextNumber() < REPLACEMENT_DOOR_CHANCE
		then PAINTS[random:NextInteger(1, #PAINTS)]
		else spec.paint
	local doorColor = weathered(shade(doorPaint, random, 0.1), rust)
	local body: PartOptions = { material = material, color = bodyColor }
	local interior: PartOptions = { material = material, color = bodyColor:Lerp(GRIME, 0.3) }

	-- Shell
	local base = block(
		model,
		"Base",
		frame,
		Vector3.new(-INNER_HALF, 0, front + PLINTH_RECESS),
		Vector3.new(INNER_HALF, FLOOR_Y, back - BACK_T),
		"MetalRust",
		{ material = Enum.Material.CorrodedMetal, color = RUST_DARK:Lerp(bodyColor, 0.3) }
	)
	model.PrimaryPart = base
	block(
		model,
		"SideLeft",
		frame,
		Vector3.new(-WIDTH / 2, 0, front),
		Vector3.new(-INNER_HALF, HEIGHT - TOP_T, back),
		"TrimMetal",
		body
	)
	block(
		model,
		"SideRight",
		frame,
		Vector3.new(INNER_HALF, 0, front),
		Vector3.new(WIDTH / 2, HEIGHT - TOP_T, back),
		"TrimMetal",
		body
	)
	block(
		model,
		"Back",
		frame,
		Vector3.new(-INNER_HALF, 0, back - BACK_T),
		Vector3.new(INNER_HALF, HEIGHT - TOP_T, back),
		"TrimMetal",
		interior
	)
	block(
		model,
		"Top",
		frame,
		Vector3.new(-WIDTH / 2, HEIGHT - TOP_T, front),
		Vector3.new(WIDTH / 2, HEIGHT, back),
		"TrimMetal",
		body
	)
	block(
		model,
		"Shelf",
		frame,
		Vector3.new(-INNER_HALF, SHELF_Y, front + DOOR_T + 0.06),
		Vector3.new(INNER_HALF, SHELF_Y + SHELF_T, back - BACK_T),
		"TrimMetal",
		interior
	)
	block(
		model,
		"Header",
		frame,
		Vector3.new(-INNER_HALF, HEADER_BOTTOM, front),
		Vector3.new(INNER_HALF, HEIGHT - TOP_T, front + HEADER_T),
		"TrimMetal",
		body
	)

	-- Two stamped louvre hoods across the header (wedge slopes face up and out, the slot underneath).
	local headerHeight = HEIGHT - TOP_T - HEADER_BOTTOM
	for k = 1, 2 do
		detail(
			Geometry.wedge(
				model,
				string.format("Louvre%d", k),
				frame * CFrame.new(0, HEADER_BOTTOM + headerHeight * k / 3, front - 0.03),
				Vector3.new(INNER_HALF * 2 - 0.5, 0.12, 0.06),
				"TrimMetal",
				body
			)
		)
	end

	-- Full-length hinge barrel on the door's outer edge and a coat hook under the shelf.
	local hinge = Geometry.cylinder(
		model,
		"Hinge",
		frame * Vector3.new(HINGE_X, DOOR_BOTTOM + 0.15, front),
		frame * Vector3.new(HINGE_X, DOOR_TOP - 0.15, front),
		0.07,
		"TrimMetal",
		{ material = Enum.Material.Metal, color = STEEL:Lerp(RUST, 0.4 * rust) }
	)
	if hinge then
		detail(hinge)
	end
	detail(
		block(
			model,
			"CoatHook",
			frame,
			Vector3.new(-0.08, 6.1, back - BACK_T - 0.22),
			Vector3.new(0.08, 6.32, back - BACK_T),
			"TrimMetal",
			{ material = Enum.Material.Metal, color = STEEL }
		)
	)

	buildDoor(model, frame, front, { material = material, color = doorColor }, spec, random, rust)

	-- Anchors (relative to the Base, so they follow it)
	local function anchorAt(name: string, localCFrame: CFrame): Attachment
		return Geometry.attachment(base, name, base.CFrame:ToObjectSpace(frame * localCFrame))
	end
	anchorAt("HideAnchor", CFrame.new(0, FLOOR_Y, (front + DOOR_T + back - BACK_T) / 2))
	anchorAt("PeekAnchor", CFrame.new(0, PEEK_EYE_Y, front + DOOR_T + PEEK_BEHIND))
	anchorAt("ExitAnchor", CFrame.new(0, 0, front - EXIT_DISTANCE))
	local promptHost = anchorAt("HidePrompt", CFrame.new(0, PROMPT_Y, front - PROMPT_OUT))

	-- Where the LockerRip flings the door: the first landing whose footprint the room has clear floor for (the last
	-- choice, straight out from the row, when none is).
	local rest = frame * CFrame.new(HINGE_X, 0, front)
	local landed = LockerBuilder.landingTransform(SWING, LANDING_HEADINGS[#LANDING_HEADINGS])
	local clear = spec.landingClear
	for _, heading in LANDING_HEADINGS do
		local candidate = LockerBuilder.landingTransform(SWING, heading)
		if not clear or clear(footprint(rest * candidate, SWING)) then
			landed = candidate
			break
		end
	end
	Geometry.attachment(base, LANDING, base.CFrame:ToObjectSpace(rest * landed))

	PropKit.passthroughAll(model)
	PropKit.setAttributes(model, {
		[W.AnchorId] = spec.anchorId,
		[W.LevelId] = spec.levelId,
		[W.ZoneId] = spec.zoneId,
		[W.DoorOpen] = false,
	})
	model:AddTag(Tags.HideableLocker)
	PropKit.prompt(promptHost, HIDE_PROMPT, model)
	return model
end

-- Fixture builder: every Locker anchor of the level, in layout order (the number plates count them).
local function buildFixtures(ctx: PropKit.FixtureContext): number
	local stale = ctx.parent:FindFirstChild(FOLDER)
	if stale then
		stale:Destroy()
	end
	local anchors = PropKit.anchorsOf(ctx.layout, "Locker")
	if #anchors == 0 then
		return 0
	end
	local folder = Geometry.folder(ctx.parent, FOLDER)
	local rooms = LayoutSchema.indexRooms(ctx.layout)
	local banks: { [string]: Color3 } = {}
	local floors: { [string]: (footprint: { Vector3 }) -> boolean } = {}
	for index, anchor in anchors do
		local cframe = PropKit.anchorCFrame(ctx.layout.id, anchor)
		local room = rooms[anchor.room]
		local clear: ((footprint: { Vector3 }) -> boolean)? = nil
		if room then
			local test = floors[room.id] or clearFloor(ctx.layout, room)
			floors[room.id] = test
			clear = test
		end
		LockerBuilder.buildLocker(folder, {
			cframe = cframe,
			anchorId = anchor.id,
			levelId = ctx.layout.id,
			zoneId = anchor.room,
			number = index,
			wallGap = if room then wallGap(room, anchor) else nil,
			paint = bankPaint(banks, bankKey(anchor, cframe), ctx.random),
			landingClear = clear,
		}, ctx.random)
	end
	return #anchors
end

function LockerBuilder.register(registrar: PropKit.Registrar)
	registrar.fixture(KIND, buildFixtures)
end

return table.freeze(LockerBuilder)
