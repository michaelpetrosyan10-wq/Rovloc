--!strict
-- ChemicalFlaskBuilder: the volatile chemical flasks of the Science Hall's lab worktops and the Pool's starting blocks
-- and decks (plan prop kind "ChemicalFlask"; ctx.prop.cframe is the resting point: worktop top, block top or deck).
--
-- A flat-bottomed boiling flask, in flask space (origin on the resting point, Y up, the tag facing +Z): a glass bulb
-- on a small foot ("Base"), a neck with a rolled lip and a two-step rubber stopper, the glowing liquid (three Neon
-- tiers stepped to follow the bulb's curve up to a flat surface), a twine tie on the neck with a paper hazard tag
-- (SurfaceGui text "Prop.Lab.Hazard") and, on some flasks, a hairline crack round the back. No Light instances: the
-- Neon liquid is what glows. The look (liquid colour, fill level, crack) is a pure function of the variant, so one
-- flask's world prop, held item and thrown projectile all match; the world prop only adds a random yaw (ctx.random).
--
-- The world prop: every part a PropKit.detail (no collision, no query); model attributes AnchorId, LevelId; tags
-- ChemicalItem, Interactable; a disabled Pickup prompt on Attachment "PromptPoint". 12 or 13 parts (MAX_PARTS 14).
-- buildVisual(parent, cframe, variant) is the client copy for the held item and the thrown projectile: every part
-- Geometry.makeCosmetic, no prompt, tags or attributes. Both carry Attachment "Grip" on the neck, where a hand holds
-- the flask (GripOffset from the resting point). buildVisual with variant 0 is also rig "ChemicalFlask".
-- liquidColor(variant) gives the liquid's colour, so the shatter cloud can match it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)

local Geometry = require(script.Parent.Parent.Geometry)
local PropKit = require(script.Parent.PropKit)

local W = Attributes.World

local KIND = "ChemicalFlask"
local MAX_PARTS = 14
local PICKUP_HOLD = 0.35

-- Glass
local FOOT_DIAMETER = 0.28
local FOOT_HEIGHT = 0.035
local BULB_DIAMETER = 0.66
local BULB_RADIUS = BULB_DIAMETER / 2
local BULB_Y = 0.01 + BULB_RADIUS -- the bulb's bottom sinks into its foot
local GLASS_WALL = 0.03
local NECK_DIAMETER = 0.17
local NECK_BOTTOM = BULB_Y + 0.28 -- starts inside the bulb, so the joint never shows a seam
local NECK_TOP = 0.97
local LIP_DIAMETER = 0.215
local LIP_HEIGHT = 0.035
local LIP_TOP = NECK_TOP + 0.02 -- the rolled lip stands just proud of the neck's end
local GLASS_TRANSPARENCY = 0.55
local THICK_GLASS_TRANSPARENCY = 0.4 -- the foot and the lip are solid glass

-- Stopper
local PLUG_DIAMETER = 0.14
local PLUG_BOTTOM = 0.9
local CAP_DIAMETER = 0.19
local CAP_HEIGHT = 0.08

-- Liquid: the surface sits between FILL_MIN and FILL_MAX bulb inner radii from the bulb centre
local LIQUID_TIERS = 3
local LIQUID_BOTTOM = -0.92 -- inner radii below the bulb centre
local LIQUID_MARGIN = 0.006 -- clearance between a tier's rim and the glass
local FILL_MIN = -0.35
local FILL_MAX = 0.3
local LIQUID_COLORS: { Color3 } = {
	Color3.fromRGB(118, 212, 52), -- sickly green
	Color3.fromRGB(212, 202, 40), -- acid yellow
	Color3.fromRGB(150, 64, 214), -- toxic violet
}

-- Tie and tag
local TIE_Y = 0.71
local TIE_HEIGHT = 0.025
local TIE_DIAMETER = NECK_DIAMETER + 0.012
local TAG_SIZE = Vector3.new(0.2, 0.13, 0.012)
local TAG_ELEVATION = math.rad(46) -- above the bulb's equator, on the +Z side
local STRING_THICK = 0.012
local TWINE_COLOR = Color3.fromRGB(96, 84, 60)
local TAG_COLOR = Color3.fromRGB(148, 132, 86)
local TAG_TEXT_COLOR = Color3.fromRGB(92, 24, 18)
local TAG_FONT = Enum.Font.Oswald
local TAG_PIXELS_PER_STUD = 400
local TAG_MAX_DISTANCE = 24

-- Crack
local CRACK_CHANCE = 0.4
local CRACK_DEPTH = 0.008 -- how far its centre sits inside the bulb surface
local CRACK_SIZE = Vector2.new(0.006, 0.014) -- thickness (along the surface normal), width
local CRACK_COLOR = Color3.fromRGB(172, 180, 174)

-- Hand
local GRIP_Y = 0.8
local PROMPT_Y = BULB_Y

local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- a cylinder's axis (local X) turned to +Y

local PICKUP_PROMPT: PropKit.PromptSpec = {
	kind = "Pickup",
	action = "Prompt.Pickup",
	object = "Prompt.Flask",
	hold = PICKUP_HOLD,
}

type Look = {
	liquid: Color3,
	fill: number,
	cracked: boolean,
	crackAzimuth: number,
	crackElevation: number,
	crackRoll: number,
	crackLength: number,
}

local ChemicalFlaskBuilder = {}

ChemicalFlaskBuilder.Kind = KIND
ChemicalFlaskBuilder.MaxParts = MAX_PARTS
ChemicalFlaskBuilder.PickupHold = PICKUP_HOLD
ChemicalFlaskBuilder.GripOffset = CFrame.new(0, GRIP_Y, 0) -- Grip relative to the resting point

-- A variant as a whole number (0 for NaN or an infinity, which no plan produces but nothing should choke on).
local function wholeVariant(variant: number): number
	if variant ~= variant or math.abs(variant) == math.huge then
		return 0
	end
	return math.floor(variant)
end

-- The liquid colour of a flask variant (sickly green, acid yellow or toxic violet). Pure.
function ChemicalFlaskBuilder.liquidColor(variant: number): Color3
	return LIQUID_COLORS[wholeVariant(variant) % #LIQUID_COLORS + 1]
end

local function lookOf(variant: number): Look
	local random = MathUtil.seededRandom(wholeVariant(variant), "ChemicalFlask:look")
	-- Every draw is made unconditionally, so the stream (and so each value) never depends on another value.
	local fill = random:NextNumber(FILL_MIN, FILL_MAX)
	local cracked = random:NextNumber() < CRACK_CHANCE
	return {
		liquid = ChemicalFlaskBuilder.liquidColor(variant),
		fill = fill,
		cracked = cracked,
		crackAzimuth = random:NextNumber(math.rad(120), math.rad(240)), -- round the back, away from the tag
		crackElevation = random:NextNumber(math.rad(-25), math.rad(25)),
		crackRoll = random:NextNumber(0, math.pi),
		crackLength = random:NextNumber(0.14, 0.22),
	}
end

local function glassOptions(transparency: number, shape: Enum.PartType?): Geometry.PartOptions
	return { shape = shape, transparency = transparency, reflectance = 0.04 }
end

-- A cylinder standing on its axis at flask-space height [y0, y1].
local function upright(
	parent: Instance,
	name: string,
	cframe: CFrame,
	y0: number,
	y1: number,
	diameter: number,
	key: string?,
	options: Geometry.PartOptions
): Part
	local merged: Geometry.PartOptions = {
		shape = Enum.PartType.Cylinder,
		transparency = options.transparency,
		reflectance = options.reflectance,
		material = options.material,
		color = options.color,
	}
	return Geometry.part(
		parent,
		name,
		cframe * CFrame.new(0, (y0 + y1) / 2, 0) * UPRIGHT,
		Vector3.new(y1 - y0, diameter, diameter),
		key,
		merged
	)
end

local function buildLiquid(model: Model, cframe: CFrame, look: Look)
	local inner = BULB_RADIUS - GLASS_WALL
	local bottom = LIQUID_BOTTOM * inner
	local surface = look.fill * inner
	for i = 1, LIQUID_TIERS do
		local y0 = bottom + (surface - bottom) * (i - 1) / LIQUID_TIERS
		local y1 = bottom + (surface - bottom) * i / LIQUID_TIERS
		-- A flat-ended tier touches the sphere first at whichever end is further from the centre.
		local reach = math.max(math.abs(y0), math.abs(y1))
		local radius = math.sqrt(math.max(0, inner * inner - reach * reach)) - LIQUID_MARGIN
		upright(model, "Liquid" .. i, cframe, BULB_Y + y0, BULB_Y + y1, radius * 2, nil, {
			material = Enum.Material.Neon,
			color = look.liquid,
		})
	end
end

local function buildTag(model: Model, cframe: CFrame)
	upright(model, "Tie", cframe, TIE_Y - TIE_HEIGHT / 2, TIE_Y + TIE_HEIGHT / 2, TIE_DIAMETER, nil, {
		material = Enum.Material.Fabric,
		color = TWINE_COLOR,
	})

	-- The tag hangs against the bulb's shoulder: Front (-Z) faces out along the surface normal, +Y runs up the slope.
	local normal = Vector3.new(0, math.sin(TAG_ELEVATION), math.cos(TAG_ELEVATION))
	local upSlope = Vector3.new(0, math.cos(TAG_ELEVATION), -math.sin(TAG_ELEVATION))
	local centre = Vector3.new(0, BULB_Y, 0) + normal * (BULB_RADIUS + TAG_SIZE.Z / 2 + 0.004)
	local tag = Geometry.part(
		model,
		"Tag",
		cframe * CFrame.fromMatrix(centre, Vector3.new(-1, 0, 0), upSlope),
		TAG_SIZE,
		nil,
		{ material = Enum.Material.Cardboard, color = TAG_COLOR }
	)

	local tagTop = centre + upSlope * (TAG_SIZE.Y / 2)
	local knot = Vector3.new(0, TIE_Y, TIE_DIAMETER / 2)
	Geometry.part(
		model,
		"String",
		cframe * CFrame.lookAt((knot + tagTop) / 2, tagTop),
		Vector3.new(STRING_THICK, STRING_THICK, (tagTop - knot).Magnitude),
		nil,
		{ material = Enum.Material.Fabric, color = TWINE_COLOR }
	)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Label"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = TAG_PIXELS_PER_STUD
	gui.LightInfluence = 1
	gui.MaxDistance = TAG_MAX_DISTANCE
	gui.ClipsDescendants = true
	local label = Instance.new("TextLabel")
	label.Name = "Hazard"
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromScale(0.05, 0.08)
	label.Size = UDim2.fromScale(0.9, 0.84)
	label.FontFace = Font.fromEnum(TAG_FONT)
	label.Text = Strings.get("Prop.Lab.Hazard")
	label.TextColor3 = TAG_TEXT_COLOR
	label.TextScaled = true
	label.TextWrapped = true
	label.Parent = gui
	gui.Parent = tag
end

local function buildCrack(model: Model, cframe: CFrame, look: Look)
	local azimuth, elevation = look.crackAzimuth, look.crackElevation
	local outward = Vector3.new(
		math.sin(azimuth) * math.cos(elevation),
		math.sin(elevation),
		math.cos(azimuth) * math.cos(elevation)
	)
	local east = Vector3.new(math.cos(azimuth), 0, -math.sin(azimuth))
	local north = outward:Cross(east)
	local along = east * math.cos(look.crackRoll) + north * math.sin(look.crackRoll)
	local position = Vector3.new(0, BULB_Y, 0) + outward * (BULB_RADIUS - CRACK_DEPTH)
	Geometry.part(
		model,
		"Crack",
		cframe * CFrame.fromMatrix(position, along, outward),
		Vector3.new(look.crackLength, CRACK_SIZE.X, CRACK_SIZE.Y),
		"Glass",
		{ transparency = 0.3, color = CRACK_COLOR }
	)
end

-- The flask's geometry (no collision presets, prompt, tags or attributes) resting on `cframe`. Returns the model and
-- its PrimaryPart.
local function buildFlask(parent: Instance, name: string, cframe: CFrame, variant: number): (Model, Part)
	local look = lookOf(variant)
	local model = PropKit.model(parent, name, cframe)

	local base =
		upright(model, "Base", cframe, 0, FOOT_HEIGHT, FOOT_DIAMETER, "Glass", glassOptions(THICK_GLASS_TRANSPARENCY))
	model.PrimaryPart = base
	Geometry.part(
		model,
		"Bulb",
		cframe * CFrame.new(0, BULB_Y, 0),
		Vector3.one * BULB_DIAMETER,
		"Glass",
		glassOptions(GLASS_TRANSPARENCY, Enum.PartType.Ball)
	)
	upright(model, "Neck", cframe, NECK_BOTTOM, NECK_TOP, NECK_DIAMETER, "Glass", glassOptions(GLASS_TRANSPARENCY))
	upright(
		model,
		"Lip",
		cframe,
		LIP_TOP - LIP_HEIGHT,
		LIP_TOP,
		LIP_DIAMETER,
		"Glass",
		glassOptions(THICK_GLASS_TRANSPARENCY)
	)
	upright(model, "Plug", cframe, PLUG_BOTTOM, LIP_TOP, PLUG_DIAMETER, "Rubber", {})
	upright(model, "Cap", cframe, LIP_TOP, LIP_TOP + CAP_HEIGHT, CAP_DIAMETER, "Rubber", {})

	buildLiquid(model, cframe, look)
	buildTag(model, cframe)
	if look.cracked then
		buildCrack(model, cframe, look)
	end

	Geometry.attachment(base, "Grip", base.CFrame:ToObjectSpace(cframe * ChemicalFlaskBuilder.GripOffset))
	return model, base
end

-- The client-side flask (held item, thrown projectile): every part cosmetic, with its "Grip" Attachment. No prompt,
-- tags or attributes. `cframe` is where its foot rests (align Grip to the hand with GripOffset).
function ChemicalFlaskBuilder.buildVisual(parent: Instance, cframe: CFrame, variant: number): Model
	local model = buildFlask(parent, KIND, cframe, variant)
	PropKit.cosmeticAll(model)
	return model
end

-- Builds one flask for a PlannedProp (registered as plan prop kind "ChemicalFlask").
function ChemicalFlaskBuilder.build(ctx: Types.PropBuildContext): Model
	local plan = ctx.prop
	local cframe = plan.cframe * CFrame.Angles(0, ctx.random:NextNumber(0, 2 * math.pi), 0)
	local model, base = buildFlask(ctx.parent, KIND .. "_" .. plan.anchorId, cframe, plan.variant)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			PropKit.detail(descendant)
		end
	end

	local promptPoint =
		Geometry.attachment(base, "PromptPoint", base.CFrame:ToObjectSpace(cframe * CFrame.new(0, PROMPT_Y, 0)))
	PropKit.prompt(promptPoint, PICKUP_PROMPT, model)
	PropKit.setAttributes(model, {
		[W.AnchorId] = plan.anchorId,
		[W.LevelId] = plan.levelId,
	})
	model:AddTag(Tags.ChemicalItem)
	return model
end

function ChemicalFlaskBuilder.register(registrar: PropKit.Registrar)
	registrar.prop(KIND, ChemicalFlaskBuilder.build)
	registrar.rig(KIND, function(parent: Instance, cframe: CFrame): Model
		return ChemicalFlaskBuilder.buildVisual(parent, cframe, 0)
	end)
end

return table.freeze(ChemicalFlaskBuilder)
