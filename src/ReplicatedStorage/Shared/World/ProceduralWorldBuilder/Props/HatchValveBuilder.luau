--!strict
-- HatchValveBuilder: the jammed watertight hatch over the flooded maintenance duct's west grate and its valve, the
-- Floor 4 objective's station (fixture kind "HatchValve", one per HatchValve anchor, rebuilt at every run start into
-- Workspace.Runtime.<level>.HatchValves: the hatch shut, the socket bare).
--
-- Mount space: the anchor is the grate's centre at the waterline on the coping's inner face; -Z out of the wall (its
-- LookVector, into the pool hall), +Y up, +X the viewer's left. A riveted steel hatch plate (leaf "Hatch", hinged
-- along its top edge: rest = shut over the grate's frame; opening swings it up and out over the water; "HatchOpen"
-- records 100 degrees) with four dog clamps and a "MAINTENANCE HATCH" stencil plate, a steel frame round it on the
-- wall, and to the viewer's right the valve: a flange half under the water, a pipe stub and the bare square spindle
-- (leaf "Stem", turned with the wheel) that the valve wheel from the pool floor fits onto, and the actuator rod running
-- from the valve to the hatch.
--
-- Attachments on the Base (the flange): "WheelSeat" (where the fitted wheel's hub sits, its UpVector along the
-- spindle: pose the wheel so its Hub lands here), "ValvePrompt", "HatchOpen", "<leaf>Rest". Prompts (disabled, both on
-- ValvePrompt, a short reach so the squad has to be in the water): FitValve (Step FitWheel, hold 3 s) and TurnValve
-- (Step TurnValve, hold 4 s). Tags ObjectiveStation, Interactable; attributes Floor 4, Step TurnValve, ObjectiveId
-- HatchValve, GrateId (the grate it covers, when there is one under it), AnchorId, LevelId, ZoneId. The hatch plate is
-- MonsterPassthrough (it shuts the grate to swimmers); everything else is a detail. setHatch / setStem are pure poses.
-- While the hatch is shut the grate behind it is not usable.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)

local Geometry = require(script.Parent.Parent.Geometry)
local ObjectiveKit = require(script.Parent.ObjectiveKit)
local PropKit = require(script.Parent.PropKit)

local W = Attributes.World

type PartOptions = Geometry.PartOptions

local KIND = "HatchValve"
local FOLDER = "HatchValves"
local PART_BUDGET = 20
local STEP = "TurnValve"
local PROMPT_DISTANCE = 5

local HALF = 2.3 -- the hatch plate, square, centred on the grate
local PLATE_OUT, PLATE_T = 0.55, 0.2
local FRAME_W = 0.3
local OPEN_ANGLE = math.rad(100)
local VALVE_X = -3.4 -- to the viewer's right
local SEAT_OUT = 0.95

local STEEL = Color3.fromRGB(76, 84, 82)
local HATCH = Color3.fromRGB(64, 78, 74)

local HatchValveBuilder = {}

HatchValveBuilder.Kind = KIND
HatchValveBuilder.Folder = FOLDER
HatchValveBuilder.PartBudget = PART_BUDGET
HatchValveBuilder.OpenAngle = OPEN_ANGLE

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

-- The hatch 0 (shut) .. 1 (swung open over the water).
function HatchValveBuilder.setHatch(model: Model, open: number): boolean
	return PropKit.poseLeaf(model, "Hatch", CFrame.Angles(math.clamp(open, 0, 1) * OPEN_ANGLE, 0, 0))
end

-- The spindle turned `turns` full turns (the fitted wheel turns with it).
function HatchValveBuilder.setStem(model: Model, turns: number): boolean
	return PropKit.poseLeaf(model, "Stem", CFrame.Angles(0, 0, turns * 2 * math.pi))
end

export type HatchSpec = {
	cframe: CFrame, -- the anchor: grate centre at the waterline on the wall face, LookVector into the hall
	anchorId: string,
	levelId: string,
	zoneId: string,
	grateId: string?,
}

function HatchValveBuilder.buildHatch(parent: Instance, spec: HatchSpec): Model
	local objective = ObjectiveConfig.forLevel(spec.levelId) or ObjectiveConfig.Floors[5]
	local mount = spec.cframe
	local model = PropKit.model(parent, spec.anchorId, mount)
	local steel: PartOptions = { material = Enum.Material.Metal, color = STEEL }
	-- The valve first: its flange is the Base the leaves record their rest on
	local base = Geometry.cylinder(
		model,
		"Base",
		mount * at(VALVE_X, 0, 0.005),
		mount * at(VALVE_X, 0, 0.16),
		1.15,
		"TrimMetal",
		steel
	)
	assert(base, "flange")
	model.PrimaryPart = base
	detail(
		Geometry.cylinder(
			model,
			"Stub",
			mount * at(VALVE_X, 0, 0.16),
			mount * at(VALVE_X, 0, 0.62),
			0.5,
			"PipeIron",
			{ material = Enum.Material.CorrodedMetal, color = Color3.fromRGB(86, 62, 44) }
		)
	)
	local stem = PropKit.leaf(model, "Stem", mount * CFrame.new(at(VALVE_X, 0, 0.62)))
	detail(
		Geometry.cylinder(
			stem,
			"Gland",
			mount * at(VALVE_X, 0, 0.62),
			mount * at(VALVE_X, 0, 0.74),
			0.4,
			"TrimMetal",
			steel
		)
	)
	detail(
		block(
			stem,
			"Spindle",
			mount,
			at(VALVE_X - 0.11, -0.11, 0.74),
			at(VALVE_X + 0.11, 0.11, 1.18),
			"TrimMetal",
			{ material = Enum.Material.Metal, color = ObjectiveKit.Brass }
		)
	)
	detail(
		Geometry.cylinder(
			model,
			"Actuator",
			mount * at(VALVE_X + 0.4, 0.35, 0.3),
			mount * at(-HALF - FRAME_W, 0.35, 0.3),
			0.16,
			"TrimMetal",
			steel
		)
	)

	-- The frame round the hatch on the wall
	local frame: PartOptions = { material = Enum.Material.Metal, color = STEEL:Lerp(Color3.new(), 0.2) }
	detail(
		block(
			model,
			"FrameTop",
			mount,
			at(-HALF - FRAME_W, HALF, 0.02),
			at(HALF + FRAME_W, HALF + FRAME_W, PLATE_OUT),
			"TrimMetal",
			frame
		)
	)
	detail(
		block(
			model,
			"FrameBottom",
			mount,
			at(-HALF - FRAME_W, -HALF - FRAME_W, 0.02),
			at(HALF + FRAME_W, -HALF, PLATE_OUT),
			"TrimMetal",
			frame
		)
	)
	for i, x in { -HALF - FRAME_W, HALF } do
		detail(
			block(
				model,
				"FrameSide" .. i,
				mount,
				at(x, -HALF, 0.02),
				at(x + FRAME_W, HALF, PLATE_OUT),
				"TrimMetal",
				frame
			)
		)
	end

	-- The hatch, hinged along its top edge
	local hatch = PropKit.leaf(model, "Hatch", mount * CFrame.new(at(0, HALF, PLATE_OUT + PLATE_T / 2)))
	block(
		hatch,
		"HatchPlate",
		mount,
		at(-HALF + 0.05, -HALF + 0.05, PLATE_OUT),
		at(HALF - 0.05, HALF - 0.05, PLATE_OUT + PLATE_T),
		"TrimMetal",
		{ material = Enum.Material.Metal, color = HATCH }
	)
	for i, p in { { -HALF + 0.35, 0 }, { HALF - 0.35, 0 }, { 0, -HALF + 0.35 }, { 0, HALF - 0.45 } } do
		detail(
			block(
				hatch,
				"Dog" .. i,
				mount,
				at(p[1] - 0.18, p[2] - 0.12, PLATE_OUT + PLATE_T),
				at(p[1] + 0.18, p[2] + 0.12, PLATE_OUT + PLATE_T + 0.16),
				"TrimMetal",
				steel
			)
		)
	end
	local stencil = block(
		hatch,
		"Stencil",
		mount,
		at(-1.5, 0.6, PLATE_OUT + PLATE_T),
		at(1.5, 1.3, PLATE_OUT + PLATE_T + 0.02),
		nil,
		{ material = Enum.Material.SmoothPlastic, color = Color3.fromRGB(156, 128, 44) }
	)
	detail(stencil)
	ObjectiveKit.text(
		stencil,
		"Label",
		Strings.get("Prop.Hatch.Label"),
		Color3.fromRGB(24, 24, 22),
		Enum.Font.Oswald,
		Enum.NormalId.Front,
		120
	)

	Geometry.attachment(
		base,
		"WheelSeat",
		base.CFrame:ToObjectSpace(mount * CFrame.new(at(VALVE_X, 0, SEAT_OUT)) * CFrame.Angles(-math.pi / 2, 0, 0))
	)
	local promptPoint =
		Geometry.attachment(base, "ValvePrompt", base.CFrame:ToObjectSpace(mount * CFrame.new(at(VALVE_X, 0.4, 1.8))))
	Geometry.attachment(
		base,
		"HatchOpen",
		base.CFrame:ToObjectSpace((PropKit.leafRest(model, "Hatch") :: CFrame) * CFrame.Angles(OPEN_ANGLE, 0, 0))
	)

	PropKit.passthroughAll(model)
	PropKit.setAttributes(model, { [W.AnchorId] = spec.anchorId, [W.ZoneId] = spec.zoneId })
	if spec.grateId then
		model:SetAttribute(W.GrateId, spec.grateId)
	end
	ObjectiveKit.mark(model, Tags.ObjectiveStation, objective, STEP, KIND)
	ObjectiveKit.prompt(
		promptPoint,
		objective,
		"FitValve",
		"Prompt.FitValve",
		"Prompt.HatchValve",
		"FitWheel",
		model,
		nil,
		nil,
		PROMPT_DISTANCE
	)
	ObjectiveKit.prompt(
		promptPoint,
		objective,
		"TurnValve",
		"Prompt.TurnValve",
		"Prompt.HatchValve",
		STEP,
		model,
		nil,
		nil,
		PROMPT_DISTANCE
	)
	return model
end

-- The grate whose wall node lies under the anchor (within the hatch), if any.
local function grateUnder(layout: LayoutSchema.LevelLayout, anchor: LayoutSchema.Anchor): string?
	local vents = layout.vents
	if not vents then
		return nil
	end
	local nodes: { [string]: LayoutSchema.VentNodeSpec } = {}
	for _, node in vents.nodes do
		nodes[node.id] = node
	end
	for _, grate in vents.grates do
		local node = nodes[grate.node]
		if node and math.abs(node.x - anchor.pos.X) <= HALF and math.abs(node.z - anchor.pos.Z) <= 1.5 then
			return grate.id
		end
	end
	return nil
end

local function buildFixtures(ctx: PropKit.FixtureContext): number
	local stale = ctx.parent:FindFirstChild(FOLDER)
	if stale then
		stale:Destroy()
	end
	local anchors = PropKit.anchorsOf(ctx.layout, "HatchValve")
	if #anchors == 0 then
		return 0
	end
	local folder = Geometry.folder(ctx.parent, FOLDER)
	for _, anchor in anchors do
		HatchValveBuilder.buildHatch(folder, {
			cframe = PropKit.anchorCFrame(ctx.layout.id, anchor),
			anchorId = anchor.id,
			levelId = ctx.layout.id,
			zoneId = anchor.room,
			grateId = grateUnder(ctx.layout, anchor),
		})
	end
	return #anchors
end

function HatchValveBuilder.register(registrar: PropKit.Registrar)
	registrar.fixture(KIND, buildFixtures)
end

return table.freeze(HatchValveBuilder)
