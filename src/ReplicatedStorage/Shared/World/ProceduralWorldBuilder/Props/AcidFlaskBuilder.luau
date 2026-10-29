--!strict
-- AcidFlaskBuilder: the Floor 2 objective's acid flask, mixed from the three reagents at the fume hood and thrown at
-- (or poured on) the chain on the stairwell door.
--
-- A conical lab flask, in flask space (origin on the resting point, Y up, the tag facing -Z): a heavy glass foot
-- ("Base"), the cone as four stepped glass tiers narrowing to a neck with a rolled lip and a rubber bung, the acid as
-- three stepped Neon tiers (a sickly yellow-green, brighter than any lab flask, so the held item reads as the
-- objective), a twine tie and a hazard tag printed "ACID". Attachment "Grip" on the neck.
--
--   buildVisual(parent, cframe)  the client copy for the held item and the thrown projectile: every part cosmetic, no
--                                prompt, tags or attributes. Also rig "AcidFlask".
--   buildWorld(parent, cframe, anchorId)
--                                the flask standing where the fume hood leaves it (FumeHoodBuilder's AcidFlaskSpot):
--                                every part a PropKit.detail; tags ObjectiveItem and Interactable; attributes Floor 2,
--                                Step BurnChain, ObjectiveId AcidFlask, LevelId, AnchorId (the hood's); a disabled
--                                Pickup prompt on "PromptPoint". The objective service builds it when the mix is done.
-- MaxParts 14.

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

local KIND = "AcidFlask"
local MAX_PARTS = 14
local PICKUP_HOLD = 0.4
local LEVEL: string = "Level2_ScienceHall"
local STEP = "BurnChain"

local FOOT_DIAMETER = 0.72
local FOOT_HEIGHT = 0.05
local TIERS: { { y0: number, y1: number, d: number } } = {
	{ y0 = 0.04, y1 = 0.22, d = 0.7 },
	{ y0 = 0.22, y1 = 0.4, d = 0.58 },
	{ y0 = 0.4, y1 = 0.56, d = 0.44 },
	{ y0 = 0.56, y1 = 0.7, d = 0.3 },
}
local NECK_TOP = 0.98
local NECK_DIAMETER = 0.19
local LIP_DIAMETER = 0.24
local ACID = Color3.fromRGB(196, 232, 58)
local GLASS: PartOptions =
	{ material = Enum.Material.Glass, color = Color3.fromRGB(150, 170, 160), transparency = 0.55 }
local GRIP_Y = 0.82

local AcidFlaskBuilder = {}

AcidFlaskBuilder.Kind = KIND
AcidFlaskBuilder.MaxParts = MAX_PARTS
AcidFlaskBuilder.AcidColor = ACID
AcidFlaskBuilder.GripOffset = CFrame.new(0, GRIP_Y, 0)

local function upright(
	parent: Instance,
	name: string,
	cframe: CFrame,
	y0: number,
	y1: number,
	d: number,
	options: PartOptions
): Part
	local part =
		Geometry.cylinder(parent, name, cframe * Vector3.new(0, y0, 0), cframe * Vector3.new(0, y1, 0), d, nil, options)
	assert(part, name)
	return part
end

local function buildFlask(parent: Instance, name: string, cframe: CFrame): (Model, Part)
	local model = PropKit.model(parent, name, cframe)
	local base = upright(
		model,
		"Base",
		cframe,
		0,
		FOOT_HEIGHT,
		FOOT_DIAMETER,
		{ material = Enum.Material.Glass, color = GLASS.color, transparency = 0.4 }
	)
	model.PrimaryPart = base
	for i, tier in TIERS do
		upright(model, "Cone" .. i, cframe, tier.y0, tier.y1, tier.d, GLASS)
	end
	upright(model, "Neck", cframe, TIERS[#TIERS].y1 - 0.02, NECK_TOP, NECK_DIAMETER, GLASS)
	upright(
		model,
		"Lip",
		cframe,
		NECK_TOP - 0.03,
		NECK_TOP + 0.01,
		LIP_DIAMETER,
		{ material = Enum.Material.Glass, color = GLASS.color, transparency = 0.35 }
	)
	upright(
		model,
		"Bung",
		cframe,
		NECK_TOP - 0.06,
		NECK_TOP + 0.1,
		0.17,
		{ material = Enum.Material.Rubber, color = Color3.fromRGB(46, 44, 42) }
	)
	-- The acid fills the bottom three tiers, each a little inside its glass
	for i = 1, 3 do
		local tier = TIERS[i]
		upright(
			model,
			"Acid" .. i,
			cframe,
			tier.y0 + 0.01,
			tier.y1 - (if i == 3 then 0.06 else 0),
			tier.d - 0.06,
			{ material = Enum.Material.Neon, color = ACID }
		)
	end
	upright(
		model,
		"Tie",
		cframe,
		0.74,
		0.77,
		NECK_DIAMETER + 0.014,
		{ material = Enum.Material.Fabric, color = Color3.fromRGB(96, 84, 60) }
	)
	local tag = Geometry.part(
		model,
		"Tag",
		cframe * CFrame.new(0, 0.3, -0.33) * CFrame.Angles(math.rad(-34), 0, 0),
		Vector3.new(0.26, 0.17, 0.012),
		nil,
		{ material = Enum.Material.Cardboard, color = Color3.fromRGB(168, 150, 60) }
	)
	ObjectiveKit.text(
		tag,
		"Label",
		Strings.get("Prop.Acid.Label"),
		Color3.fromRGB(92, 22, 16),
		Enum.Font.Oswald,
		Enum.NormalId.Front,
		400
	)
	Geometry.attachment(base, "Grip", base.CFrame:ToObjectSpace(cframe * AcidFlaskBuilder.GripOffset))
	return model, base
end

-- The held / thrown copy: every part cosmetic, with "Grip". `cframe` is where its foot rests.
function AcidFlaskBuilder.buildVisual(parent: Instance, cframe: CFrame): Model
	local model = buildFlask(parent, KIND, cframe)
	PropKit.cosmeticAll(model)
	return model
end

-- The flask standing at `cframe` (the fume hood's AcidFlaskSpot), ready to pick up.
function AcidFlaskBuilder.buildWorld(parent: Instance, cframe: CFrame, anchorId: string): Model
	local spec = ObjectiveConfig.forLevel(LEVEL)
	assert(spec, "the science hall has an objective")
	local model, base = buildFlask(parent, KIND .. "_" .. anchorId, cframe)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			PropKit.detail(d)
		end
	end
	local promptPoint =
		Geometry.attachment(base, "PromptPoint", base.CFrame:ToObjectSpace(cframe * CFrame.new(0, 0.4, 0)))
	ObjectiveKit.prompt(promptPoint, spec, "Pickup", "Prompt.Pickup", "Prompt.AcidFlask", STEP, model, nil, PICKUP_HOLD)
	ObjectiveKit.mark(model, Tags.ObjectiveItem, spec, STEP, KIND, { [W.AnchorId] = anchorId })
	return model
end

function AcidFlaskBuilder.register(registrar: PropKit.Registrar)
	registrar.rig(KIND, AcidFlaskBuilder.buildVisual)
end

return table.freeze(AcidFlaskBuilder)
