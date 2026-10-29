--!strict
-- GeneratorBuilder: the gym equipment store's portable generator, the Floor 3 objective's station (fixture kind
-- "Generator", one per Generator anchor, rebuilt at every run start into Workspace.Runtime.<level>.Generators: cold,
-- the cord home, the lamp dark).
--
-- Generator space: the anchor is the floor centre of its footprint; -Z its front (the anchor's LookVector, the pull
-- start's side), +Y up, +X the viewer's left. A tubular steel cradle on two skids with a pair of wheels at one end,
-- the engine block with the recoil pull-start housing on its front, the alternator drum, a faded yellow fuel tank
-- across the top with its cap, the muffler at the back, the control panel ("PULL TO START") and a work lamp on a mast
-- rising from the back corner (a SpotLight in its head, disabled until the generator runs). Leaf "PullCord": the
-- T-handle and its cord, rest = home against the housing; pulling slides it out along -Z ("PullOut" records the full
-- pull).
--
-- Prompt (disabled): Generator on "PullPrompt" in front of the handle (Step StartGenerator, hold 3 s). Attachments
-- "Exhaust" (the muffler's outlet, for the smoke) and "LampHead". Tags ObjectiveStation, Interactable; attributes
-- Floor 3, Step StartGenerator, ObjectiveId Generator, AnchorId, LevelId, ZoneId. The cradle, engine, tank and
-- alternator are MonsterPassthrough furniture; everything else is a detail. setPull / setLamp are pure poses.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)

local Geometry = require(script.Parent.Parent.Geometry)
local ObjectiveKit = require(script.Parent.ObjectiveKit)
local PropKit = require(script.Parent.PropKit)

local W = Attributes.World

type PartOptions = Geometry.PartOptions

local KIND = "Generator"
local FOLDER = "Generators"
local PART_BUDGET = 28
local STEP = "StartGenerator"

local HALF_L, HALF_D = 1.8, 1.15
local FRAME_TOP = 2.7
local TUBE = 0.12
local PULL_X, PULL_Y = 0.75, 1.25 -- the recoil housing on the engine's front (+X is the viewer's left)
local PULL_TRAVEL = 1.6
local LAMP_TOP = 5.4

local YELLOW = Color3.fromRGB(168, 132, 42)
local ENGINE = Color3.fromRGB(54, 56, 56)
local FRAME = Color3.fromRGB(30, 30, 30)
local LAMP_WARM = Color3.fromRGB(255, 226, 170)

local GeneratorBuilder = {}

GeneratorBuilder.Kind = KIND
GeneratorBuilder.Folder = FOLDER
GeneratorBuilder.PartBudget = PART_BUDGET
GeneratorBuilder.PullTravel = PULL_TRAVEL

local function at(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local function block(
	parent: Instance,
	name: string,
	frame: CFrame,
	a: Vector3,
	b: Vector3,
	key: string?,
	options: PartOptions?
): Part
	local lo, hi = a:Min(b), a:Max(b)
	return Geometry.part(parent, name, frame * CFrame.new((lo + hi) / 2), hi - lo, key, options)
end

local function detail(part: BasePart?)
	if part then
		PropKit.detail(part)
	end
end

-- The pull cord 0 (home) .. 1 (fully pulled).
function GeneratorBuilder.setPull(model: Model, pulled: number): boolean
	return PropKit.poseLeaf(model, "PullCord", CFrame.new(0, 0, -math.clamp(pulled, 0, 1) * PULL_TRAVEL))
end

-- Lights (or darkens) the work lamp: its lens and its SpotLight.
function GeneratorBuilder.setLamp(model: Model, on: boolean): boolean
	local lens = model:FindFirstChild("LampLens")
	if not (lens and lens:IsA("BasePart")) then
		return false
	end
	lens.Material = if on then Enum.Material.Neon else Enum.Material.Glass
	lens.Color = if on then LAMP_WARM else Color3.fromRGB(110, 106, 92)
	local light = lens:FindFirstChildOfClass("SpotLight")
	if light then
		light.Enabled = on
	end
	return true
end

export type GeneratorSpec = {
	cframe: CFrame, -- footprint centre on the floor, LookVector out of the pull-start side
	anchorId: string,
	levelId: string,
	zoneId: string,
}

function GeneratorBuilder.buildGenerator(parent: Instance, spec: GeneratorSpec): Model
	local objective = ObjectiveConfig.forLevel(spec.levelId) or ObjectiveConfig.Floors[4]
	local frame = spec.cframe
	local model = PropKit.model(parent, spec.anchorId, frame)
	local steel: PartOptions = { material = Enum.Material.Metal, color = FRAME }
	for i, z in { -HALF_D + 0.2, HALF_D - 0.2 } do
		block(model, "Skid" .. i, frame, at(-HALF_L, 0, z - 0.14), at(HALF_L, 0.24, z + 0.14), "TrimMetal", steel)
	end
	local base = block(
		model,
		"Base",
		frame,
		at(-0.2, 0.3, -0.8),
		at(HALF_L - 0.15, 1.95, 0.8),
		"TrimMetal",
		{ material = Enum.Material.Metal, color = ENGINE }
	)
	model.PrimaryPart = base
	block(
		model,
		"Alternator",
		frame,
		at(-HALF_L + 0.15, 0.45, -0.7),
		at(-0.2, 1.75, 0.7),
		"TrimMetal",
		{ material = Enum.Material.Metal, color = ENGINE:Lerp(Color3.new(1, 1, 1), 0.08) }
	)
	block(
		model,
		"Tank",
		frame,
		at(-HALF_L + 0.1, 2.0, -0.78),
		at(HALF_L - 0.1, 2.62, 0.78),
		nil,
		{ material = Enum.Material.Metal, color = YELLOW }
	)
	detail(
		Geometry.cylinder(
			model,
			"TankCap",
			frame * at(1.1, 2.62, 0.2),
			frame * at(1.1, 2.76, 0.2),
			0.32,
			nil,
			{ material = Enum.Material.Metal, color = FRAME }
		)
	)
	detail(
		Geometry.cylinder(
			model,
			"Muffler",
			frame * at(-0.2, 1.5, 0.98),
			frame * at(HALF_L - 0.3, 1.5, 0.98),
			0.42,
			nil,
			{ material = Enum.Material.CorrodedMetal, color = Color3.fromRGB(80, 54, 38) }
		)
	)
	-- Cradle: four corner posts and two top rails
	for i, corner in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		local x, z = corner[1] * (HALF_L - 0.06), corner[2] * (HALF_D - 0.06)
		detail(
			Geometry.cylinder(model, "Post" .. i, frame * at(x, 0.2, z), frame * at(x, FRAME_TOP, z), TUBE, nil, steel)
		)
	end
	for i, z in { -(HALF_D - 0.06), HALF_D - 0.06 } do
		detail(
			Geometry.cylinder(
				model,
				"Rail" .. i,
				frame * at(-HALF_L, FRAME_TOP, z),
				frame * at(HALF_L, FRAME_TOP, z),
				TUBE,
				nil,
				steel
			)
		)
	end
	for i, z in { -(HALF_D + 0.12), HALF_D + 0.12 } do
		detail(
			Geometry.cylinder(
				model,
				"Wheel" .. i,
				frame * at(-HALF_L + 0.35, 0.36, z - 0.12),
				frame * at(-HALF_L + 0.35, 0.36, z + 0.12),
				0.72,
				"Rubber",
				{ material = Enum.Material.Rubber, color = Color3.fromRGB(22, 22, 22) }
			)
		)
	end
	-- Front: the recoil housing, the control panel
	detail(
		Geometry.cylinder(
			model,
			"Recoil",
			frame * at(PULL_X, PULL_Y, -0.8),
			frame * at(PULL_X, PULL_Y, -1.02),
			0.9,
			nil,
			{ material = Enum.Material.Metal, color = YELLOW:Lerp(Color3.new(), 0.25) }
		)
	)
	local panel = block(
		model,
		"ControlPanel",
		frame,
		at(-1.55, 0.5, -0.83),
		at(-0.35, 1.45, -0.72),
		nil,
		{ material = Enum.Material.SmoothPlastic, color = Color3.fromRGB(38, 40, 40) }
	)
	detail(panel)
	ObjectiveKit.text(
		panel,
		"Label",
		Strings.get("Prop.Generator.Label"),
		YELLOW,
		Enum.Font.Oswald,
		Enum.NormalId.Front,
		120
	)
	local pull = PropKit.leaf(model, "PullCord", frame * CFrame.new(at(PULL_X, PULL_Y, -1.02)))
	detail(
		Geometry.cylinder(
			pull,
			"Cord",
			frame * at(PULL_X, PULL_Y, -1.0),
			frame * at(PULL_X, PULL_Y, -1.12),
			0.05,
			nil,
			{ material = Enum.Material.Fabric, color = Color3.fromRGB(150, 140, 120) }
		)
	)
	detail(
		Geometry.cylinder(
			pull,
			"Handle",
			frame * at(PULL_X - 0.28, PULL_Y, -1.17),
			frame * at(PULL_X + 0.28, PULL_Y, -1.17),
			0.14,
			"Rubber",
			{ material = Enum.Material.Rubber, color = Color3.fromRGB(30, 30, 30) }
		)
	)
	-- Work lamp on its mast at the back corner, aimed down past the front
	local mastX, mastZ = -(HALF_L - 0.06), HALF_D - 0.06
	detail(
		Geometry.cylinder(
			model,
			"LampMast",
			frame * at(mastX, FRAME_TOP, mastZ),
			frame * at(mastX, LAMP_TOP, mastZ),
			TUBE,
			nil,
			steel
		)
	)
	local head = frame * CFrame.new(at(mastX, LAMP_TOP + 0.25, mastZ - 0.2)) * CFrame.Angles(math.rad(-35), 0, 0)
	detail(Geometry.part(model, "LampHead", head, Vector3.new(0.75, 0.55, 0.45), "TrimMetal", steel))
	local lens =
		Geometry.part(model, "LampLens", head * CFrame.new(0, 0, -0.24), Vector3.new(0.62, 0.42, 0.04), "Glass")
	detail(lens)
	local light = Instance.new("SpotLight")
	light.Name = "WorkLamp"
	light.Face = Enum.NormalId.Front
	light.Angle = 70
	light.Range = 40
	light.Brightness = 3
	light.Color = LAMP_WARM
	light.Shadows = true
	light.Enabled = false
	light.Parent = lens

	Geometry.attachment(
		base,
		"PullPrompt",
		base.CFrame:ToObjectSpace(frame * CFrame.new(at(PULL_X, PULL_Y + 0.3, -2.2)))
	)
	Geometry.attachment(
		base,
		"PullOut",
		base.CFrame:ToObjectSpace((PropKit.leafRest(model, "PullCord") :: CFrame) * CFrame.new(0, 0, -PULL_TRAVEL))
	)
	Geometry.attachment(base, "Exhaust", base.CFrame:ToObjectSpace(frame * CFrame.new(at(HALF_L - 0.3, 1.5, 0.98))))
	Geometry.attachment(base, "LampHead", base.CFrame:ToObjectSpace(head))

	PropKit.passthroughAll(model)
	PropKit.setAttributes(model, { [W.AnchorId] = spec.anchorId, [W.ZoneId] = spec.zoneId })
	ObjectiveKit.mark(model, Tags.ObjectiveStation, objective, STEP, KIND)
	local host = base:FindFirstChild("PullPrompt")
	if host then
		ObjectiveKit.prompt(host, objective, "Generator", "Prompt.Generator", "Prompt.GeneratorName", STEP, model)
	end
	GeneratorBuilder.setLamp(model, false)
	return model
end

local function buildFixtures(ctx: PropKit.FixtureContext): number
	local stale = ctx.parent:FindFirstChild(FOLDER)
	if stale then
		stale:Destroy()
	end
	local anchors = PropKit.anchorsOf(ctx.layout, "Generator")
	if #anchors == 0 then
		return 0
	end
	local folder = Geometry.folder(ctx.parent, FOLDER)
	for _, anchor in anchors do
		GeneratorBuilder.buildGenerator(folder, {
			cframe = PropKit.anchorCFrame(ctx.layout.id, anchor),
			anchorId = anchor.id,
			levelId = ctx.layout.id,
			zoneId = anchor.room,
		})
	end
	return #anchors
end

function GeneratorBuilder.register(registrar: PropKit.Registrar)
	registrar.fixture(KIND, buildFixtures)
end

return table.freeze(GeneratorBuilder)
