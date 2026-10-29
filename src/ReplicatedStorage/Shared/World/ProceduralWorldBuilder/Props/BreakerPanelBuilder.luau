--!strict
-- BreakerPanelBuilder: the basement's main distribution panel (fixture kind "BreakerPanel", one per BreakerPanel
-- anchor, rebuilt at every run start into Workspace.Runtime.<level>.BreakerPanels: the fuse slots empty, the main
-- breaker down, every lamp dark). The Floor 0 objective: fit three fuses, then throw the main breaker.
--
-- Mount space: the anchor is the floor point on the wall face; -Z out of the wall (its LookVector), +Y up, +X the
-- viewer's left. A grey steel cabinet on a backplate, 2.2 to 6.6 studs up, its interior a dark back panel holding three
-- porcelain fuse holders side by side (leaves "FuseSlot1".."FuseSlot3": the holder, its two brass spring clips and the
-- slot's indicator lamp), the cabinet door (leaf "Door", hinged on the viewer's left edge, rest = shut; built hanging
-- open), the main breaker's big throw lever on the cabinet's right side (leaf "Lever", rest = down / OFF; ON swings it
-- up through LeverThrow about its boss) with OFF / ON tabs, a red main lamp over it, the "MAIN DISTRIBUTION" plate on
-- the wall above, a "DANGER 480V" plate on the door and a conduit up to the ceiling.
--
-- Attachments on the Base (the cabinet body): "FuseSlot<i>Seat" (where a fitted fuse's centre sits, its RightVector
-- along the fuse: pose the fuse so its Grip lands here), "FuseSlot<i>Prompt", "LeverPrompt" and "<leaf>Rest" (PropKit),
-- "DoorOpen" (the door's built pose). Prompts (disabled): FitFuse on each slot (Slot i, Step FitFuses, hold 2 s) and
-- Breaker on the lever (Step ThrowBreaker, hold 3 s). Tags ObjectiveStation, Interactable; attributes Floor 0,
-- Step ThrowBreaker, ObjectiveId BreakerPanel, AnchorId, LevelId, ZoneId. The cabinet, door and backplate are
-- MonsterPassthrough furniture; everything else is a hand-scale detail. setLever / setSlotLamp / setDoor are pure
-- poses for the objective service. Part budget PartBudget.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)

local Geometry = require(script.Parent.Parent.Geometry)
local ObjectiveKit = require(script.Parent.ObjectiveKit)
local PropKit = require(script.Parent.PropKit)
local SchoolShellBuilder = require(script.Parent.Parent.SchoolShellBuilder)

local W = Attributes.World

type PartOptions = Geometry.PartOptions

local KIND = "BreakerPanel"
local FOLDER = "BreakerPanels"
local PART_BUDGET = 32
local SLOTS = 3
local STEP = "ThrowBreaker"

-- Cabinet (mount space; "out" is the distance from the wall face)
local HALF_W = 1.7
local BOTTOM, TOP = 2.2, 6.6
local DEPTH = 0.9
local CASE_T = 0.1
local PLATE_HALF_W, PLATE_BOTTOM, PLATE_TOP, PLATE_T = 2, 1.9, 6.9, 0.08
local INNER_BACK = 0.22 -- the dark interior panel's face, out from the wall
local SLOT_Y = 4.6
local SLOT_SPACING = 0.95
local HOLDER = Vector3.new(0.62, 1.9, 0.14)
local CLIP_D = 0.22
local CLIP_LENGTH = 0.46
local FUSE_HALF = 0.62 -- clips grip the fuse's caps this far above and below its centre
local LAMP_D = 0.18
local DOOR_T = 0.08
local DOOR_OPEN = math.rad(105)

-- Lever on the cabinet's -X side (the viewer's right)
local PIVOT_Y, PIVOT_OUT = 4.4, 0.5
local ARM_LENGTH = 1.5
local ARM_REST = math.rad(55) -- below the outward horizontal
local LEVER_THROW = 2 * ARM_REST

local PROMPT_OUT = 1.3

-- Finish
local CABINET = Color3.fromRGB(78, 84, 80)
local INTERIOR = Color3.fromRGB(26, 28, 28)
local PORCELAIN = Color3.fromRGB(176, 170, 152)
local LAMP_RED = Color3.fromRGB(232, 44, 28)
local LAMP_DARK = Color3.fromRGB(56, 18, 16)
local LAMP_GREEN = Color3.fromRGB(70, 230, 96)
local GRIP_RED = Color3.fromRGB(122, 30, 24)
local HAZARD_YELLOW = Color3.fromRGB(156, 128, 44)
local HAZARD_BLACK = Color3.fromRGB(24, 24, 22)

local BreakerPanelBuilder = {}

BreakerPanelBuilder.Kind = KIND
BreakerPanelBuilder.Folder = FOLDER
BreakerPanelBuilder.PartBudget = PART_BUDGET
BreakerPanelBuilder.Slots = SLOTS
BreakerPanelBuilder.LeverThrow = LEVER_THROW
BreakerPanelBuilder.DoorOpenAngle = DOOR_OPEN
BreakerPanelBuilder.LampLit = table.freeze({ red = LAMP_RED, green = LAMP_GREEN })

local function at(x: number, y: number, out: number): Vector3
	return Vector3.new(x, y, -out)
end

local function block(
	parent: Instance,
	name: string,
	mount: CFrame,
	a: Vector3,
	b: Vector3,
	key: string?,
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

local function slotX(i: number): number
	return (i - (SLOTS + 1) / 2) * SLOT_SPACING
end

--------------------------------------------------------------------------------
-- Poses
--------------------------------------------------------------------------------

-- The main breaker 0 (OFF, down) .. 1 (ON, up). False when `model` is not a breaker panel.
function BreakerPanelBuilder.setLever(model: Model, on: number): boolean
	return PropKit.poseLeaf(model, "Lever", CFrame.Angles(math.clamp(on, 0, 1) * LEVER_THROW, 0, 0))
end

-- The cabinet door 0 (shut) .. 1 (hanging open).
function BreakerPanelBuilder.setDoor(model: Model, open: number): boolean
	return PropKit.poseLeaf(model, "Door", CFrame.Angles(0, -math.clamp(open, 0, 1) * DOOR_OPEN, 0))
end

-- Lights slot `i`'s lamp green (a fuse fitted), red (power on, empty) or dark.
function BreakerPanelBuilder.setSlotLamp(model: Model, i: number, state: "Dark" | "Red" | "Green"): boolean
	local leaf = model:FindFirstChild("FuseSlot" .. i)
	local lamp = if leaf then leaf:FindFirstChild("Lamp" .. i) else nil
	if not (lamp and lamp:IsA("BasePart")) then
		return false
	end
	lamp.Material = if state == "Dark" then Enum.Material.Glass else Enum.Material.Neon
	lamp.Color = if state == "Green" then LAMP_GREEN elseif state == "Red" then LAMP_RED else LAMP_DARK
	return true
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function buildSlot(model: Model, base: BasePart, mount: CFrame, i: number)
	local x = slotX(i)
	local leaf = PropKit.leaf(model, "FuseSlot" .. i, mount * CFrame.new(at(x, SLOT_Y, INNER_BACK)))
	detail(
		block(
			leaf,
			"Holder" .. i,
			mount,
			at(x - HOLDER.X / 2, SLOT_Y - HOLDER.Y / 2, INNER_BACK),
			at(x + HOLDER.X / 2, SLOT_Y + HOLDER.Y / 2, INNER_BACK + HOLDER.Z),
			nil,
			{ material = Enum.Material.Marble, color = PORCELAIN }
		)
	)
	local brass: PartOptions = { material = Enum.Material.Metal, color = ObjectiveKit.Brass, reflectance = 0.1 }
	for k, sign in { 1, -1 } do
		local y = SLOT_Y + sign * FUSE_HALF
		detail(
			Geometry.cylinder(
				leaf,
				string.format("Clip%d_%d", i, k),
				mount * at(x - CLIP_LENGTH / 2, y, INNER_BACK + HOLDER.Z + CLIP_D / 2 - 0.02),
				mount * at(x + CLIP_LENGTH / 2, y, INNER_BACK + HOLDER.Z + CLIP_D / 2 - 0.02),
				CLIP_D,
				nil,
				brass
			)
		)
	end
	local lamp = Geometry.cylinder(
		leaf,
		"Lamp" .. i,
		mount * at(x, SLOT_Y - HOLDER.Y / 2 - 0.24, INNER_BACK),
		mount * at(x, SLOT_Y - HOLDER.Y / 2 - 0.24, INNER_BACK + 0.1),
		LAMP_D,
		"Glass"
	)
	detail(lamp)
	local seatOut = INNER_BACK + HOLDER.Z + 0.24
	Geometry.attachment(
		base,
		string.format("FuseSlot%dSeat", i),
		base.CFrame:ToObjectSpace(mount * CFrame.new(at(x, SLOT_Y, seatOut)) * CFrame.Angles(0, 0, math.pi / 2))
	)
	Geometry.attachment(
		base,
		string.format("FuseSlot%dPrompt", i),
		base.CFrame:ToObjectSpace(mount * CFrame.new(at(x, SLOT_Y, PROMPT_OUT)))
	)
end

local function buildDoor(model: Model, mount: CFrame)
	-- hinged on the viewer's left (+X) front edge; opening swings it out and round toward +X
	local hinge = mount * CFrame.new(at(HALF_W, (BOTTOM + TOP) / 2, DEPTH))
	local leaf = PropKit.leaf(model, "Door", hinge)
	block(
		leaf,
		"DoorPanel",
		mount,
		at(-HALF_W + 0.04, BOTTOM + 0.05, DEPTH),
		at(HALF_W, TOP - 0.05, DEPTH + DOOR_T),
		"TrimMetal",
		{ material = Enum.Material.Metal, color = CABINET:Lerp(Color3.new(1, 1, 1), 0.04) }
	)
	detail(
		block(
			leaf,
			"DoorHandle",
			mount,
			at(-HALF_W + 0.25, 4.2, DEPTH + DOOR_T),
			at(-HALF_W + 0.35, 4.9, DEPTH + DOOR_T + 0.12),
			"TrimMetal",
			{ material = Enum.Material.Metal, color = ObjectiveKit.Steel }
		)
	)
	local danger = block(
		leaf,
		"DangerPlate",
		mount,
		at(-0.75, 5.4, DEPTH + DOOR_T),
		at(0.75, 6.0, DEPTH + DOOR_T + 0.02),
		nil,
		{ material = Enum.Material.SmoothPlastic, color = HAZARD_YELLOW }
	)
	detail(danger)
	ObjectiveKit.text(
		danger,
		"Danger",
		Strings.get("Prop.Breaker.Danger"),
		HAZARD_BLACK,
		Enum.Font.Oswald,
		Enum.NormalId.Front,
		120
	)
end

local function buildLever(model: Model, mount: CFrame)
	local pivot = mount * CFrame.new(at(-HALF_W - 0.24, PIVOT_Y, PIVOT_OUT))
	detail(
		Geometry.cylinder(
			model,
			"LeverBoss",
			mount * at(-HALF_W, PIVOT_Y, PIVOT_OUT),
			pivot.Position,
			0.56,
			"TrimMetal",
			{ material = Enum.Material.Metal, color = ObjectiveKit.Steel }
		)
	)
	for _, mark in
		{
			{ name = "OffMark", angle = -ARM_REST, color = Color3.fromRGB(140, 34, 26) },
			{ name = "OnMark", angle = ARM_REST, color = Color3.fromRGB(40, 110, 52) },
		}
	do
		local y = PIVOT_Y + 0.5 * math.sin(mark.angle)
		local out = PIVOT_OUT + 0.5 * math.cos(mark.angle)
		detail(
			block(
				model,
				mark.name,
				mount,
				at(-HALF_W - 0.02, y - 0.09, out - 0.09),
				at(-HALF_W, y + 0.09, out + 0.09),
				nil,
				{ material = Enum.Material.SmoothPlastic, color = mark.color }
			)
		)
	end
	local lever = PropKit.leaf(model, "Lever", pivot)
	local arm = pivot * CFrame.new(-0.08, 0, 0) * CFrame.Angles(-ARM_REST, 0, 0)
	local steel: PartOptions = { material = Enum.Material.Metal, color = ObjectiveKit.Steel }
	detail(
		Geometry.part(
			lever,
			"LeverArm",
			arm * CFrame.new(0, 0, -(ARM_LENGTH / 2 - 0.1)),
			Vector3.new(0.12, 0.18, ARM_LENGTH),
			"TrimMetal",
			steel
		)
	)
	detail(
		Geometry.cylinder(lever, "LeverHub", pivot.Position, pivot * Vector3.new(-0.2, 0, 0), 0.34, "TrimMetal", steel)
	)
	detail(
		Geometry.cylinder(
			lever,
			"LeverGrip",
			arm * Vector3.new(0.05, 0, -(ARM_LENGTH - 0.1)),
			arm * Vector3.new(-0.6, 0, -(ARM_LENGTH - 0.1)),
			0.28,
			"Rubber",
			{ material = Enum.Material.Rubber, color = GRIP_RED }
		)
	)
end

export type PanelSpec = {
	cframe: CFrame, -- the anchor: floor point on the wall face, LookVector out of the wall
	anchorId: string,
	levelId: string,
	zoneId: string,
	ceiling: number, -- underside of the room's ceiling panel above the anchor
}

-- Builds one breaker panel into `parent`.
function BreakerPanelBuilder.buildPanel(parent: Instance, spec: PanelSpec): Model
	local objective = ObjectiveConfig.forLevel(spec.levelId) or ObjectiveConfig.Floors[1]
	local mount = spec.cframe
	local model = PropKit.model(parent, spec.anchorId, mount)
	-- A hollow steel box: its back (the Base, painted dark inside) and four walls out to the door
	local cabinet: PartOptions = { material = Enum.Material.Metal, color = CABINET }
	local base = block(
		model,
		"Base",
		mount,
		at(-HALF_W, BOTTOM, PLATE_T),
		at(HALF_W, TOP, INNER_BACK),
		nil,
		{ material = Enum.Material.SmoothPlastic, color = INTERIOR }
	)
	model.PrimaryPart = base
	block(
		model,
		"Backplate",
		mount,
		at(-PLATE_HALF_W, PLATE_BOTTOM, 0.005),
		at(PLATE_HALF_W, PLATE_TOP, PLATE_T),
		"TrimMetal",
		{ material = Enum.Material.Metal, color = Color3.fromRGB(48, 50, 52) }
	)
	for i, x in { -HALF_W, HALF_W - CASE_T } do
		block(
			model,
			"CaseSide" .. i,
			mount,
			at(x, BOTTOM, INNER_BACK),
			at(x + CASE_T, TOP, DEPTH),
			"TrimMetal",
			cabinet
		)
	end
	block(model, "CaseTop", mount, at(-HALF_W, TOP - CASE_T, INNER_BACK), at(HALF_W, TOP, DEPTH), "TrimMetal", cabinet)
	block(
		model,
		"CaseBottom",
		mount,
		at(-HALF_W, BOTTOM, INNER_BACK),
		at(HALF_W, BOTTOM + CASE_T, DEPTH),
		"TrimMetal",
		cabinet
	)
	for i = 1, SLOTS do
		buildSlot(model, base, mount, i)
	end
	buildDoor(model, mount)
	buildLever(model, mount)
	local mainLamp = Geometry.cylinder(
		model,
		"MainLamp",
		mount * at(-HALF_W - 0.02, PIVOT_Y + 1.1, PIVOT_OUT),
		mount * at(-HALF_W - 0.14, PIVOT_Y + 1.1, PIVOT_OUT),
		0.26,
		"Glass"
	)
	detail(mainLamp)
	local label = block(
		model,
		"LabelPlate",
		mount,
		at(-1.45, TOP + 0.4, 0.02),
		at(1.45, TOP + 0.95, 0.06),
		nil,
		{ material = Enum.Material.SmoothPlastic, color = Color3.fromRGB(36, 38, 38) }
	)
	detail(label)
	ObjectiveKit.text(
		label,
		"Label",
		Strings.get("Prop.Breaker.Label"),
		Color3.fromRGB(196, 192, 176),
		Enum.Font.Michroma,
		Enum.NormalId.Front,
		120
	)
	local top = math.max(TOP + 1.5, spec.ceiling - 0.01)
	detail(
		Geometry.cylinder(
			model,
			"Conduit",
			mount * at(0.9, TOP, 0.4),
			mount * at(0.9, top, 0.4),
			0.34,
			"MetalGalvanized",
			{ material = Enum.Material.Metal }
		)
	)
	Geometry.attachment(
		base,
		"LeverPrompt",
		base.CFrame:ToObjectSpace(mount * CFrame.new(at(-HALF_W - 0.9, PIVOT_Y, PROMPT_OUT)))
	)
	Geometry.attachment(
		base,
		"DoorOpen",
		base.CFrame:ToObjectSpace((PropKit.leafRest(model, "Door") :: CFrame) * CFrame.Angles(0, -DOOR_OPEN, 0))
	)

	PropKit.passthroughAll(model)
	PropKit.setAttributes(model, { [W.AnchorId] = spec.anchorId, [W.ZoneId] = spec.zoneId })
	ObjectiveKit.mark(model, Tags.ObjectiveStation, objective, STEP, KIND)
	for i = 1, SLOTS do
		local host = base:FindFirstChild(string.format("FuseSlot%dPrompt", i))
		if host then
			ObjectiveKit.prompt(
				host,
				objective,
				"FitFuse",
				"Prompt.FitFuse",
				"Prompt.BreakerPanel",
				"FitFuses",
				model,
				i,
				nil,
				5
			)
		end
	end
	local leverHost = base:FindFirstChild("LeverPrompt")
	if leverHost then
		ObjectiveKit.prompt(leverHost, objective, "Breaker", "Prompt.Breaker", "Prompt.BreakerPanel", STEP, model)
	end
	for i = 1, SLOTS do
		BreakerPanelBuilder.setSlotLamp(model, i, "Dark")
	end
	BreakerPanelBuilder.setDoor(model, 1)
	return model
end

local function buildFixtures(ctx: PropKit.FixtureContext): number
	local stale = ctx.parent:FindFirstChild(FOLDER)
	if stale then
		stale:Destroy()
	end
	local anchors = PropKit.anchorsOf(ctx.layout, "BreakerPanel")
	if #anchors == 0 then
		return 0
	end
	local folder = Geometry.folder(ctx.parent, FOLDER)
	local rooms = LayoutSchema.indexRooms(ctx.layout)
	for _, anchor in anchors do
		local room = rooms[anchor.room]
		local height = if room then SchoolShellBuilder.ceilingBottom(ctx.layout, room) else ctx.layout.height
		BreakerPanelBuilder.buildPanel(folder, {
			cframe = PropKit.anchorCFrame(ctx.layout.id, anchor),
			anchorId = anchor.id,
			levelId = ctx.layout.id,
			zoneId = anchor.room,
			ceiling = height - anchor.pos.Y,
		})
	end
	return #anchors
end

function BreakerPanelBuilder.register(registrar: PropKit.Registrar)
	registrar.fixture(KIND, buildFixtures)
end

return table.freeze(BreakerPanelBuilder)
