--!strict
-- PickupBuilder: flashlight battery pickups (plan prop kind "Battery": RunDirector puts batteriesPerLevel of them on
-- each school level's BatteryCandidate anchors; ctx.prop.cframe is the floor, shelf or desk point they lie on).
--
-- A chunky 6-volt lantern battery, in body space (origin at the centre of the can's bottom face, Y up): a steel can
-- ("Base") in a faded maker's wrap with a contrasting stripe (colours from the plan variant), a crimped top rim, a
-- black top plate with two coil-spring contacts, and a tiny Neon charge strip that glows in the dark, so the pickup
-- reads in a flashlight sweep without a Light instance. ctx.random gives each battery a random yaw, knocks some onto
-- their side and leans every one a few degrees; the battery is then settled so its lowest point rests exactly on the
-- anchor's plane (no part ever sinks below it or floats above it).
--
-- Every part is a PropKit.detail (no collision, no query). Model attributes AnchorId, LevelId and Charge
-- (GameConfig.BatteryPickupCharge, what the pickup restores); tags BatteryPickup, Interactable; a disabled Pickup
-- prompt on Attachment "PromptPoint" at the can's centre. 8 parts (MAX_PARTS 10).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)

local Geometry = require(script.Parent.Parent.Geometry)
local PropKit = require(script.Parent.PropKit)

local W = Attributes.World

local KIND = "Battery"
local MAX_PARTS = 10
local PICKUP_HOLD = 0.25

-- Can and wrap
local CAN = Vector3.new(0.44, 0.6, 0.44)
local WRAP_BOTTOM = 0.06
local WRAP_TOP = 0.5
local WRAP_PROUD = 0.006 -- the wrap stands off the can, the stripe off the wrap
local STRIPE_Y = 0.36
local STRIPE_HEIGHT = 0.06
local RIM_HEIGHT = 0.035
local RIM_PROUD = 0.005

-- Top plate, contacts, charge strip
local PLATE = Vector3.new(0.36, 0.03, 0.36)
local PLATE_BOTTOM = CAN.Y - 0.01
local SPRING_DIAMETER = 0.07
local SPRING_HEIGHT = 0.14
local SPRING_SPACING = 0.09 -- each contact's distance from the centre, along X
local SPRING_SET_BACK = 0.04 -- contacts sit toward -Z, the charge strip toward +Z
local STRIP = Vector3.new(0.08, 0.022, 0.045)
local STRIP_Z = 0.12

-- Placement
local KNOCKED_CHANCE = 0.3
local MAX_LEAN = math.rad(4)
local KNOCKED_OVER = CFrame.Angles(0, 0, math.pi / 2) -- onto its -X side

type Wrap = { body: Color3, stripe: Color3 }

-- Faded maker's colours: the wrap, then the stripe printed round it.
local WRAPS: { Wrap } = {
	{ body = Color3.fromRGB(116, 44, 36), stripe = Color3.fromRGB(150, 142, 118) },
	{ body = Color3.fromRGB(40, 62, 100), stripe = Color3.fromRGB(150, 128, 52) },
	{ body = Color3.fromRGB(52, 84, 52), stripe = Color3.fromRGB(28, 28, 28) },
	{ body = Color3.fromRGB(136, 82, 32), stripe = Color3.fromRGB(28, 28, 28) },
}
local CAN_COLOR = Color3.fromRGB(78, 80, 78)
local PLATE_COLOR = Color3.fromRGB(24, 24, 24)
local BRASS_COLOR = Color3.fromRGB(122, 100, 58)
local CHARGE_COLOR = Color3.fromRGB(104, 210, 92)

local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- a cylinder's axis (local X) turned to +Y

local PICKUP_PROMPT: PropKit.PromptSpec = {
	kind = "Pickup",
	action = "Prompt.Pickup",
	object = "Prompt.Battery",
	hold = PICKUP_HOLD,
}

local PickupBuilder = {}

PickupBuilder.Kind = KIND
PickupBuilder.MaxParts = MAX_PARTS
PickupBuilder.PickupHold = PICKUP_HOLD

-- The lowest point of a part, in the space `cframe` is expressed in (shape-aware: a lying cylinder rests on its
-- curve, not on the corners of its bounding box).
function PickupBuilder.lowestPoint(cframe: CFrame, size: Vector3, shape: Enum.PartType): number
	local y = cframe.Position.Y
	if shape == Enum.PartType.Ball then
		return y - math.min(size.X, size.Y, size.Z) / 2
	elseif shape == Enum.PartType.Cylinder then
		local axisY = cframe.RightVector.Y
		local radius = math.min(size.Y, size.Z) / 2
		return y - math.abs(axisY) * size.X / 2 - radius * math.sqrt(math.max(0, 1 - axisY * axisY))
	end
	return y
		- (
			math.abs(cframe.RightVector.Y) * size.X / 2
			+ math.abs(cframe.UpVector.Y) * size.Y / 2
			+ math.abs(cframe.LookVector.Y) * size.Z / 2
		)
end

local function shapeOf(part: BasePart): Enum.PartType
	if part:IsA("Part") then
		return part.Shape
	end
	return Enum.PartType.Block
end

-- Lifts (or lowers) every part of `model` along `floor`'s up axis so its lowest point lies on `floor`'s plane.
local function settle(model: Model, floor: CFrame)
	local parts: { BasePart } = {}
	local lowest = math.huge
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(parts, child)
			lowest = math.min(
				lowest,
				PickupBuilder.lowestPoint(floor:ToObjectSpace(child.CFrame), child.Size, shapeOf(child))
			)
		end
	end
	local lift = floor.UpVector * -lowest
	for _, part in parts do
		part.CFrame += lift
	end
end

local function piece(
	parent: Instance,
	name: string,
	cframe: CFrame,
	size: Vector3,
	material: Enum.Material,
	color: Color3,
	shape: Enum.PartType?
): Part
	local part = Geometry.part(parent, name, cframe, size, nil, { material = material, color = color, shape = shape })
	PropKit.detail(part)
	return part
end

-- Builds one battery for a PlannedProp (registered as plan prop kind "Battery").
function PickupBuilder.build(ctx: Types.PropBuildContext): Model
	local plan = ctx.prop
	local random = ctx.random
	local yaw = random:NextNumber(0, 2 * math.pi)
	local knocked = random:NextNumber() < KNOCKED_CHANCE
	local lean = random:NextNumber(-MAX_LEAN, MAX_LEAN)
	local floor = plan.cframe * CFrame.Angles(0, yaw, 0)
	local body = floor * CFrame.Angles(lean, 0, 0) * (if knocked then KNOCKED_OVER else CFrame.new())
	local finite = plan.variant == plan.variant and math.abs(plan.variant) ~= math.huge
	local wrap = WRAPS[math.floor(if finite then plan.variant else 0) % #WRAPS + 1]

	local model = PropKit.model(ctx.parent, KIND .. "_" .. plan.anchorId, floor)
	local base = piece(model, "Base", body * CFrame.new(0, CAN.Y / 2, 0), CAN, Enum.Material.Metal, CAN_COLOR)
	model.PrimaryPart = base

	local wrapSize = Vector3.new(CAN.X + WRAP_PROUD * 2, WRAP_TOP - WRAP_BOTTOM, CAN.Z + WRAP_PROUD * 2)
	piece(
		model,
		"Wrap",
		body * CFrame.new(0, (WRAP_BOTTOM + WRAP_TOP) / 2, 0),
		wrapSize,
		Enum.Material.SmoothPlastic,
		wrap.body
	)
	piece(
		model,
		"Stripe",
		body * CFrame.new(0, STRIPE_Y, 0),
		Vector3.new(wrapSize.X + WRAP_PROUD * 2, STRIPE_HEIGHT, wrapSize.Z + WRAP_PROUD * 2),
		Enum.Material.SmoothPlastic,
		wrap.stripe
	)
	piece(
		model,
		"Rim",
		body * CFrame.new(0, CAN.Y + RIM_PROUD - RIM_HEIGHT / 2, 0),
		Vector3.new(CAN.X + RIM_PROUD * 2, RIM_HEIGHT, CAN.Z + RIM_PROUD * 2),
		Enum.Material.Metal,
		CAN_COLOR:Lerp(Color3.new(), 0.25)
	)
	local plateTop = PLATE_BOTTOM + PLATE.Y
	piece(
		model,
		"TopPlate",
		body * CFrame.new(0, PLATE_BOTTOM + PLATE.Y / 2, 0),
		PLATE,
		Enum.Material.SmoothPlastic,
		PLATE_COLOR
	)
	for _, side in { 1, -1 } do
		piece(
			model,
			if side > 0 then "ContactPositive" else "ContactNegative",
			body * CFrame.new(side * SPRING_SPACING, plateTop + SPRING_HEIGHT / 2, -SPRING_SET_BACK) * UPRIGHT,
			Vector3.new(SPRING_HEIGHT, SPRING_DIAMETER, SPRING_DIAMETER),
			Enum.Material.Metal,
			BRASS_COLOR,
			Enum.PartType.Cylinder
		)
	end
	piece(
		model,
		"ChargeStrip",
		body * CFrame.new(0, plateTop + STRIP.Y / 2, STRIP_Z),
		STRIP,
		Enum.Material.Neon,
		CHARGE_COLOR
	)

	settle(model, plan.cframe)

	local promptPoint = Geometry.attachment(base, "PromptPoint", CFrame.new())
	PropKit.prompt(promptPoint, PICKUP_PROMPT, model)
	PropKit.setAttributes(model, {
		[W.AnchorId] = plan.anchorId,
		[W.LevelId] = plan.levelId,
		[W.Charge] = GameConfig.BatteryPickupCharge,
	})
	model:AddTag(Tags.BatteryPickup)
	return model
end

function PickupBuilder.register(registrar: PropKit.Registrar)
	registrar.prop(KIND, PickupBuilder.build)
end

return table.freeze(PickupBuilder)
