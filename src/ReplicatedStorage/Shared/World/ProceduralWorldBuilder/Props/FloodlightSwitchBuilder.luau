--!strict
-- FloodlightSwitchBuilder: the emergency floodlight breaker on the natatorium's west deck (fixture kind
-- "FloodlightSwitch", one per FloodlightSwitch anchor, rebuilt at every run start into
-- Workspace.Runtime.<level>.FloodlightSwitches, so every run starts with the floodlights dead and the lever down).
--
-- A wall-mounted steel breaker cabinet: a mounting plate flush on the wall behind the anchor (the gap to the wall's
-- face is read from the layout), the box with a drip cap and sill, its door panel framed above and below by
-- yellow-and-black hazard bands, an engraved label (Prop.Floodlight.Label) and a yellow warning plate
-- (Prop.Floodlight.Warning), a pair of indicator lamps (Neon red while off, green once on) with the switch's one tiny
-- PointLight between them, and a big throw lever (leaf "Lever") on the cabinet's right-hand side that swings in the
-- side plane from OFF (rest, pointing down and out) up to ON, past red and green tabs on the cabinet side. Conduit runs
-- from the cap straight up the wall to a pull box under the room's ceiling panel (from the layout's room height).
--
-- Mount space: X across the cabinet (+X is the viewer's left), Y up from the anchor height, -Z out of the wall (the
-- anchor's LookVector); "out" below is the distance from the wall face. Attributes On = false, AnchorId, LevelId,
-- ZoneId and FlickerGroup (the layout's Floodlight group the switch brings up, when the level has one). Tags
-- FloodlightSwitch and Interactable; a disabled Floodlight prompt on the "SwitchPrompt" attachment in front of the
-- door. The box is MonsterPassthrough furniture; lever, lamps, plates, stripes and conduit are hand-scale details.
-- setLever and setIndicator are pure poses for the mechanic (P7) to drive.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(script.Parent.Parent.Geometry)
local PropKit = require(script.Parent.PropKit)
local SchoolShellBuilder = require(script.Parent.Parent.SchoolShellBuilder)

type Layout = LayoutSchema.LevelLayout
type Room = LayoutSchema.Room
type Anchor = LayoutSchema.Anchor
type PartOptions = Geometry.PartOptions

export type SwitchSpec = {
	cframe: CFrame, -- the anchor: cabinet centre height, LookVector out of the wall
	anchorId: string,
	levelId: string,
	zoneId: string,
	wallGap: number?, -- from `cframe` back to the wall face; nil when the anchor does not face out of a wall
	ceiling: number, -- underside of the room's ceiling panel above `cframe`
	flickerGroup: string?,
}

local W = Attributes.World

local KIND = "FloodlightSwitch"
local FOLDER = "FloodlightSwitches"
local LEVER = "Lever"
local PART_BUDGET = 30

-- Cabinet
local PLATE_HALF_W, PLATE_HALF_H, PLATE_T = 1.35, 1.95, 0.08
local BOX_HALF_W, BOX_HALF_H, BOX_FRONT = 1.2, 1.7, 0.83
local PANEL_HALF_W, PANEL_BOTTOM, PANEL_TOP, PANEL_FRONT = 1.05, -1.25, 1.05, 0.88
local CAP_HALF_W, CAP_BOTTOM, CAP_TOP, CAP_FRONT = 1.3, 1.35, 1.78, 0.95
local SILL_BOTTOM, SILL_TOP = -1.78, -1.55
local MOUNT_GAP_MIN, MOUNT_GAP_MAX = BOX_FRONT, 3 -- a wall farther than this is not the one the cabinet hangs on
local DEFAULT_GAP = 1

-- Hazard bands: a yellow strip in the reveal between the door panel and the cap (and the sill), crossed by black
-- bars at 45 degrees whose ends are buried in the panel, cap and sill, so the stripes end square on the band edges.
local STRIPE_FRONT = 0.855
local BAR_FRONT = 0.867
local BAR_W, BAR_L = 0.18, 0.66
local BARS = 3
local BAR_SPACING = 0.6

-- Lever: pivots on a boss on the cabinet's -X side; rest (OFF) points down and out, ON swings it up and out.
local PIVOT_X, PIVOT_Y, PIVOT_OUT = -BOX_HALF_W - 0.22, 0.55, 0.48
local ARM_L = 1.25
local ARM_REST = math.rad(50) -- below the outward horizontal
local LEVER_THROW = 2 * ARM_REST -- OFF -> ON, mirrored about the horizontal
local MARK_RADIUS = 0.42

-- Lamps and plates
local LAMP_Y = 0.8
local LAMP_X = 0.25
local LAMP_D = 0.24
local LAMPS: { { name: string, x: number } } = {
	{ name = "LampRed", x = LAMP_X }, -- the viewer's left
	{ name = "LampGreen", x = -LAMP_X },
}
local GLOW_RANGE = 3.5
local GLOW_BRIGHTNESS = 0.8

-- Conduit
local CONDUIT_X, CONDUIT_OUT, CONDUIT_D = 0.55, 0.4, 0.3
local FITTING_TOP = CAP_TOP + 0.22
local PULL_BOX_H = 0.45
local STRAP_EVERY = 8
local MAX_STRAPS = 2

local PROMPT_OUT = 1.5
local PROMPT_Y = 0.2

local FLOODLIGHT_PROMPT: PropKit.PromptSpec = {
	kind = "Floodlight",
	action = "Prompt.Floodlight",
	object = "Prompt.FloodlightSwitch",
	hold = 1.0,
}

-- Finish
local CABINET = Color3.fromRGB(66, 74, 68)
local PANEL = Color3.fromRGB(78, 86, 80)
local PLATE_STEEL = Color3.fromRGB(46, 48, 50)
local HAZARD_YELLOW = Color3.fromRGB(156, 128, 44)
local HAZARD_BLACK = Color3.fromRGB(24, 24, 22)
local STEEL = Color3.fromRGB(90, 92, 94)
local GRIP = Color3.fromRGB(118, 30, 24)
local ENAMEL = Color3.fromRGB(36, 38, 38)
local ENGRAVING = Color3.fromRGB(196, 192, 176)
local RED_LIT = Color3.fromRGB(232, 44, 28)
local RED_DARK = Color3.fromRGB(52, 16, 14)
local GREEN_LIT = Color3.fromRGB(70, 230, 96)
local GREEN_DARK = Color3.fromRGB(16, 44, 22)
local MARK_RED = Color3.fromRGB(140, 34, 26)
local MARK_GREEN = Color3.fromRGB(40, 110, 52)
local LABEL_FONT = Enum.Font.Michroma
local WARNING_FONT = Enum.Font.Oswald

local FloodlightSwitchBuilder = {}

FloodlightSwitchBuilder.Kind = KIND
FloodlightSwitchBuilder.Folder = FOLDER
FloodlightSwitchBuilder.LeverLeaf = LEVER
FloodlightSwitchBuilder.PartBudget = PART_BUDGET
FloodlightSwitchBuilder.LeverThrow = LEVER_THROW
FloodlightSwitchBuilder.LampLit = table.freeze({ red = RED_LIT, green = GREEN_LIT })

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Mount-space point: `out` studs off the wall face.
local function at(x: number, y: number, out: number): Vector3
	return Vector3.new(x, y, -out)
end

-- Axis-aligned box between two mount-space corners.
local function block(
	parent: Instance,
	name: string,
	mount: CFrame,
	a: Vector3,
	b: Vector3,
	key: string,
	options: PartOptions?
): Part
	local lo, hi = a:Min(b), a:Max(b)
	return Geometry.part(parent, name, mount * CFrame.new((lo + hi) / 2), hi - lo, key, options)
end

local function detail(part: BasePart?)
	if part then
		PropKit.detail(part)
	end
end

local function printText(part: BasePart, name: string, text: string, color: Color3, font: Enum.Font)
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
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(0.92, 0.7)
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.FontFace = Font.fromEnum(font)
	label.Parent = gui
	gui.Parent = part
end

local function paintLamp(lamp: BasePart, lit: boolean, litColor: Color3, darkColor: Color3)
	lamp.Material = if lit then Enum.Material.Neon else Enum.Material.Glass
	lamp.Color = if lit then litColor else darkColor
end

-- Distance from the anchor back to the face of the wall behind it (the room edge its back faces, less half that
-- wall's thickness), or nil when the anchor does not face straight out of a wall.
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

-- The FlickerGroup of the layout's Floodlight fixtures: the anchor's room first, else anywhere on the level.
local function floodlightGroup(layout: Layout, roomId: string): string?
	local elsewhere: string? = nil
	for _, room in layout.rooms do
		for _, light in (room.lights or {}) :: { LayoutSchema.Light } do
			if light.kind ~= "Floodlight" or not light.flickerGroup then
				continue
			end
			if room.id == roomId then
				return light.flickerGroup
			end
			elsewhere = elsewhere or light.flickerGroup
		end
	end
	return elsewhere
end

--------------------------------------------------------------------------------
-- Poses
--------------------------------------------------------------------------------

-- Poses the lever `on` 0 (OFF, down) .. 1 (ON, up). Returns false when `model` is not a floodlight switch.
function FloodlightSwitchBuilder.setLever(model: Model, on: number): boolean
	return PropKit.poseLeaf(model, LEVER, CFrame.Angles(math.clamp(on, 0, 1) * LEVER_THROW, 0, 0))
end

-- Lights the green lamp (on) or the red one (off) and tints the indicator glow to match. Returns false when `model`
-- is not a floodlight switch.
function FloodlightSwitchBuilder.setIndicator(model: Model, on: boolean): boolean
	local red = model:FindFirstChild("LampRed")
	local green = model:FindFirstChild("LampGreen")
	if not (red and red:IsA("BasePart") and green and green:IsA("BasePart")) then
		return false
	end
	paintLamp(red, not on, RED_LIT, RED_DARK)
	paintLamp(green, on, GREEN_LIT, GREEN_DARK)
	local bezel = model:FindFirstChild("IndicatorBezel")
	local glow = if bezel then bezel:FindFirstChildOfClass("PointLight") else nil
	if glow then
		glow.Color = if on then GREEN_LIT else RED_LIT
	end
	return true
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function buildHazardBand(model: Model, mount: CFrame, name: string, y0: number, y1: number)
	local stripe = block(
		model,
		name,
		mount,
		at(-BOX_HALF_W, y0, BOX_FRONT),
		at(BOX_HALF_W, y1, STRIPE_FRONT),
		"Fixture",
		{ material = Enum.Material.SmoothPlastic, color = HAZARD_YELLOW }
	)
	detail(stripe)
	local centre = (y0 + y1) / 2
	for i = 1, BARS do
		local x = (i - (BARS + 1) / 2) * BAR_SPACING
		local bar = Geometry.part(
			model,
			string.format("%sBar%d", name, i),
			mount * CFrame.new(at(x, centre, (STRIPE_FRONT + BAR_FRONT) / 2)) * CFrame.Angles(0, 0, math.rad(45)),
			Vector3.new(BAR_W, BAR_L, BAR_FRONT - STRIPE_FRONT),
			"Fixture",
			{ material = Enum.Material.SmoothPlastic, color = HAZARD_BLACK }
		)
		detail(bar)
	end
end

local function buildLever(model: Model, mount: CFrame)
	local pivot = mount * CFrame.new(at(PIVOT_X, PIVOT_Y, PIVOT_OUT))
	detail(
		Geometry.cylinder(
			model,
			"PivotBoss",
			mount * at(-BOX_HALF_W, PIVOT_Y, PIVOT_OUT),
			pivot.Position,
			0.5,
			"TrimMetal",
			{ material = Enum.Material.Metal, color = STEEL }
		)
	)
	-- OFF / ON tabs on the cabinet side where the arm points at rest and when thrown.
	local marks: { { name: string, angle: number, color: Color3 } } = {
		{ name = "OffMark", angle = -ARM_REST, color = MARK_RED },
		{ name = "OnMark", angle = ARM_REST, color = MARK_GREEN },
	}
	for _, mark in marks do
		local y = PIVOT_Y + MARK_RADIUS * math.sin(mark.angle)
		local out = PIVOT_OUT + MARK_RADIUS * math.cos(mark.angle)
		detail(
			block(
				model,
				mark.name,
				mount,
				at(-BOX_HALF_W - 0.02, y - 0.08, out - 0.08),
				at(-BOX_HALF_W, y + 0.08, out + 0.08),
				"Fixture",
				{ material = Enum.Material.SmoothPlastic, color = mark.color }
			)
		)
	end

	local lever = PropKit.leaf(model, LEVER, pivot)
	local arm = pivot * CFrame.new(-0.07, 0, 0) * CFrame.Angles(-ARM_REST, 0, 0)
	local steel: PartOptions = { material = Enum.Material.Metal, color = STEEL }
	detail(
		Geometry.part(
			lever,
			"LeverArm",
			arm * CFrame.new(0, 0, -(ARM_L / 2 - 0.1)),
			Vector3.new(0.1, 0.16, ARM_L),
			"TrimMetal",
			steel
		)
	)
	detail(
		Geometry.cylinder(lever, "LeverHub", pivot.Position, pivot * Vector3.new(-0.18, 0, 0), 0.3, "TrimMetal", steel)
	)
	detail(
		Geometry.cylinder(
			lever,
			"LeverGrip",
			arm * Vector3.new(0.04, 0, -(ARM_L - 0.08)),
			arm * Vector3.new(-0.5, 0, -(ARM_L - 0.08)),
			0.24,
			"Rubber",
			{ material = Enum.Material.Rubber, color = GRIP }
		)
	)
end

local function buildFront(model: Model, mount: CFrame)
	-- Indicator lamps on a bezel strip, the glow between them.
	local bezel = block(
		model,
		"IndicatorBezel",
		mount,
		at(-0.5, LAMP_Y - 0.18, PANEL_FRONT),
		at(0.5, LAMP_Y + 0.18, PANEL_FRONT + 0.03),
		"TrimMetal",
		{ material = Enum.Material.Metal, color = PLATE_STEEL }
	)
	detail(bezel)
	for _, lamp in LAMPS do
		detail(
			Geometry.cylinder(
				model,
				lamp.name,
				mount * at(lamp.x, LAMP_Y, PANEL_FRONT + 0.03),
				mount * at(lamp.x, LAMP_Y, PANEL_FRONT + 0.11),
				LAMP_D,
				"Glass"
			)
		)
	end
	local glow = Instance.new("PointLight")
	glow.Name = "IndicatorGlow"
	glow.Range = GLOW_RANGE
	glow.Brightness = GLOW_BRIGHTNESS
	glow.Shadows = false
	glow.Color = RED_LIT
	glow.Parent = bezel

	local label = block(
		model,
		"LabelPlate",
		mount,
		at(-0.85, 0.12, PANEL_FRONT),
		at(0.85, 0.52, PANEL_FRONT + 0.025),
		"Fixture",
		{ material = Enum.Material.SmoothPlastic, color = ENAMEL }
	)
	detail(label)
	printText(label, "Label", Strings.get("Prop.Floodlight.Label"), ENGRAVING, LABEL_FONT)
	local warning = block(
		model,
		"WarningPlate",
		mount,
		at(-0.85, -0.95, PANEL_FRONT),
		at(0.85, -0.55, PANEL_FRONT + 0.025),
		"Fixture",
		{ material = Enum.Material.SmoothPlastic, color = HAZARD_YELLOW }
	)
	detail(warning)
	printText(warning, "Warning", Strings.get("Prop.Floodlight.Warning"), HAZARD_BLACK, WARNING_FONT)

	-- Quarter-turn door latch.
	detail(
		block(
			model,
			"Latch",
			mount,
			at(0.85, -0.41, PANEL_FRONT),
			at(0.95, -0.09, PANEL_FRONT + 0.1),
			"TrimMetal",
			{ material = Enum.Material.Metal, color = STEEL }
		)
	)
end

local function buildConduit(model: Model, mount: CFrame, ceiling: number)
	local galvanized: PartOptions = { material = Enum.Material.Metal }
	local top = math.max(FITTING_TOP + PULL_BOX_H + 0.5, ceiling - 0.01)
	detail(
		Geometry.cylinder(
			model,
			"ConduitFitting",
			mount * at(CONDUIT_X, CAP_TOP, CONDUIT_OUT),
			mount * at(CONDUIT_X, FITTING_TOP, CONDUIT_OUT),
			CONDUIT_D + 0.12,
			"MetalGalvanized",
			galvanized
		)
	)
	local runTop = top - PULL_BOX_H
	detail(
		Geometry.cylinder(
			model,
			"Conduit",
			mount * at(CONDUIT_X, FITTING_TOP, CONDUIT_OUT),
			mount * at(CONDUIT_X, runTop, CONDUIT_OUT),
			CONDUIT_D,
			"MetalGalvanized",
			galvanized
		)
	)
	detail(
		block(
			model,
			"PullBox",
			mount,
			at(CONDUIT_X - 0.4, runTop, 0.01),
			at(CONDUIT_X + 0.4, top, 0.7),
			"MetalGalvanized",
			galvanized
		)
	)
	local length = runTop - FITTING_TOP
	local straps = math.clamp(math.floor(length / STRAP_EVERY), 1, MAX_STRAPS)
	for i = 1, straps do
		local y = FITTING_TOP + length * i / (straps + 1)
		detail(
			block(
				model,
				string.format("ConduitStrap%d", i),
				mount,
				at(CONDUIT_X - 0.24, y - 0.06, 0.01),
				at(CONDUIT_X + 0.24, y + 0.06, CONDUIT_OUT + CONDUIT_D / 2 + 0.05),
				"TrimMetal",
				{ material = Enum.Material.Metal, color = STEEL }
			)
		)
	end
end

-- Builds one switch cabinet into `parent`.
function FloodlightSwitchBuilder.buildSwitch(parent: Instance, spec: SwitchSpec): Model
	local wall = spec.wallGap
	local gap = if wall and wall >= MOUNT_GAP_MIN and wall <= MOUNT_GAP_MAX then wall else DEFAULT_GAP
	local mount = spec.cframe * CFrame.new(0, 0, gap)
	local model = PropKit.model(parent, spec.anchorId, spec.cframe)

	local base = block(
		model,
		"Base",
		mount,
		at(-PLATE_HALF_W, -PLATE_HALF_H, 0.005),
		at(PLATE_HALF_W, PLATE_HALF_H, PLATE_T),
		"TrimMetal",
		{ material = Enum.Material.Metal, color = PLATE_STEEL }
	)
	model.PrimaryPart = base
	local cabinet: PartOptions = { material = Enum.Material.Metal, color = CABINET }
	block(
		model,
		"Body",
		mount,
		at(-BOX_HALF_W, -BOX_HALF_H, PLATE_T),
		at(BOX_HALF_W, BOX_HALF_H, BOX_FRONT),
		"TrimMetal",
		cabinet
	)
	block(
		model,
		"DoorPanel",
		mount,
		at(-PANEL_HALF_W, PANEL_BOTTOM, BOX_FRONT),
		at(PANEL_HALF_W, PANEL_TOP, PANEL_FRONT),
		"TrimMetal",
		{ material = Enum.Material.Metal, color = PANEL }
	)
	block(
		model,
		"DripCap",
		mount,
		at(-CAP_HALF_W, CAP_BOTTOM, PLATE_T),
		at(CAP_HALF_W, CAP_TOP, CAP_FRONT),
		"TrimMetal",
		cabinet
	)
	block(
		model,
		"Sill",
		mount,
		at(-CAP_HALF_W, SILL_BOTTOM, PLATE_T),
		at(CAP_HALF_W, SILL_TOP, CAP_FRONT),
		"TrimMetal",
		cabinet
	)
	-- Bands from inside the panel's edge to inside the cap / sill, so only the reveal between them shows.
	buildHazardBand(model, mount, "HazardTop", PANEL_TOP - 0.05, CAP_BOTTOM + 0.05)
	buildHazardBand(model, mount, "HazardBottom", SILL_TOP - 0.05, PANEL_BOTTOM + 0.05)

	buildLever(model, mount)
	buildFront(model, mount)
	buildConduit(model, mount, spec.ceiling)

	local prompt = Geometry.attachment(
		base,
		"SwitchPrompt",
		base.CFrame:ToObjectSpace(mount * CFrame.new(at(0, PROMPT_Y, PROMPT_OUT)))
	)

	PropKit.passthroughAll(model)
	PropKit.setAttributes(model, {
		[W.On] = false,
		[W.AnchorId] = spec.anchorId,
		[W.LevelId] = spec.levelId,
		[W.ZoneId] = spec.zoneId,
	})
	if spec.flickerGroup then
		model:SetAttribute(W.FlickerGroup, spec.flickerGroup)
	end
	model:AddTag(Tags.FloodlightSwitch)
	PropKit.prompt(prompt, FLOODLIGHT_PROMPT, model)
	FloodlightSwitchBuilder.setIndicator(model, false)
	return model
end

local function buildFixtures(ctx: PropKit.FixtureContext): number
	local stale = ctx.parent:FindFirstChild(FOLDER)
	if stale then
		stale:Destroy()
	end
	local anchors = PropKit.anchorsOf(ctx.layout, "FloodlightSwitch")
	if #anchors == 0 then
		return 0
	end
	local folder = Geometry.folder(ctx.parent, FOLDER)
	local rooms = LayoutSchema.indexRooms(ctx.layout)
	for _, anchor in anchors do
		local room = rooms[anchor.room]
		local height = if room then SchoolShellBuilder.ceilingBottom(ctx.layout, room) else ctx.layout.height
		FloodlightSwitchBuilder.buildSwitch(folder, {
			cframe = PropKit.anchorCFrame(ctx.layout.id, anchor),
			anchorId = anchor.id,
			levelId = ctx.layout.id,
			zoneId = anchor.room,
			wallGap = if room then wallGap(room, anchor) else nil,
			ceiling = height - anchor.pos.Y,
			flickerGroup = floodlightGroup(ctx.layout, anchor.room),
		})
	end
	return #anchors
end

function FloodlightSwitchBuilder.register(registrar: PropKit.Registrar)
	registrar.fixture(KIND, buildFixtures)
end

return table.freeze(FloodlightSwitchBuilder)
