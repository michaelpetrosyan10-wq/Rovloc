--!strict
-- ObjectiveItemBuilder: the floor objectives' carryable items, plan props RunDirector places on the run's picks among
-- each floor's candidate anchors (ObjectiveConfig item.prop / item.candidate), built into Workspace.Runtime.<level> at
-- Deploying like the batteries and flasks:
--
--   Fuse         (Level 0)  a big industrial cartridge fuse: grimy ceramic barrel, brass end caps and blade contacts,
--                           a printed "100A" band and a red blown-indicator pin. Lies on its side.
--   MasterKeys   (Level 1)  the janitor's ring of keys hung on a nail driven into the wall: a steel ring, five brass
--                           and steel keys fanned under it and a red "MASTER" fob. The anchor is the nail's wall point.
--
-- Every part is a PropKit.detail (no collision, no query), the same as the other pickups. Model attributes AnchorId,
-- LevelId, Candidate (the anchor kind), Floor, Step (the floor's find
-- step), ObjectiveId (the item kind); tags ObjectiveItem and Interactable; Attachment "Grip" (where a hand holds it)
-- and a disabled Pickup prompt (hold item.hold, object item.object) on Attachment "PromptPoint".
-- buildVisual(parent, kind, cframe) is the cosmetic copy for the held item (every part makeCosmetic, no prompt,
-- tags or attributes); each kind is also registered as a rig "<Kind>Visual". Part budgets per kind in MaxParts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Rng = require(ReplicatedStorage.Shared.Util.Rng)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)

local Geometry = require(script.Parent.Parent.Geometry)
local ObjectiveKit = require(script.Parent.ObjectiveKit)
local PropKit = require(script.Parent.PropKit)

local W = Attributes.World

type Rng = Rng.Rng
type PartOptions = Geometry.PartOptions
type Built = { base: BasePart, grip: CFrame, prompt: CFrame }

local ObjectiveItemBuilder = {}

ObjectiveItemBuilder.Kinds = table.freeze({ "Fuse", "MasterKeys" })
ObjectiveItemBuilder.MaxParts = table.freeze({
	Fuse = 8,
	MasterKeys = 24,
} :: { [string]: number })

local function detailAll(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			PropKit.detail(d)
		end
	end
end

local function cylinder(parent: Instance, name: string, a: Vector3, b: Vector3, d: number, options: PartOptions): Part
	local part = Geometry.cylinder(parent, name, a, b, d, nil, options)
	assert(part, name .. " has no length")
	return part
end

local function block(parent: Instance, name: string, cframe: CFrame, size: Vector3, options: PartOptions): Part
	return Geometry.part(parent, name, cframe, size, nil, options)
end

--------------------------------------------------------------------------------
-- Fuse: lying on its side along the body's X axis (body space: origin on the resting point, Y up)
--------------------------------------------------------------------------------

local FUSE_LENGTH = 1.3
local FUSE_DIAMETER = 0.42
local CAP_LENGTH = 0.17
local CAP_DIAMETER = 0.47
local BLADE = Vector3.new(0.24, 0.05, 0.22)
local CERAMIC = Color3.fromRGB(184, 176, 154)

local function buildFuse(model: Model, body: CFrame): Built
	local y = CAP_DIAMETER / 2
	local half = FUSE_LENGTH / 2
	local ceramic: PartOptions = { material = Enum.Material.Marble, color = CERAMIC }
	local brass: PartOptions = { material = Enum.Material.Metal, color = ObjectiveKit.Brass, reflectance = 0.12 }
	local base = cylinder(
		model,
		"Base",
		body * Vector3.new(-half + CAP_LENGTH, y, 0),
		body * Vector3.new(half - CAP_LENGTH, y, 0),
		FUSE_DIAMETER,
		ceramic
	)
	for i, sign in { -1, 1 } do
		cylinder(
			model,
			"Cap" .. i,
			body * Vector3.new(sign * (half - CAP_LENGTH), y, 0),
			body * Vector3.new(sign * half, y, 0),
			CAP_DIAMETER,
			brass
		)
		block(model, "Blade" .. i, body * CFrame.new(sign * (half + BLADE.X / 2 - 0.02), y, 0), BLADE, brass)
	end
	local band = block(
		model,
		"Band",
		body * CFrame.new(0, y + FUSE_DIAMETER / 2 + 0.004, 0),
		Vector3.new(0.52, 0.008, 0.26),
		{ material = Enum.Material.SmoothPlastic, color = Color3.fromRGB(150, 132, 92) }
	)
	ObjectiveKit.text(
		band,
		"Rating",
		Strings.get("Prop.Fuse.Rating"),
		Color3.fromRGB(40, 26, 18),
		Enum.Font.Oswald,
		Enum.NormalId.Top,
		400
	)
	cylinder(
		model,
		"Indicator",
		body * Vector3.new(half + 0.0, y + 0.1, 0),
		body * Vector3.new(half + 0.06, y + 0.1, 0),
		0.07,
		{ material = Enum.Material.SmoothPlastic, color = Color3.fromRGB(176, 30, 24) }
	)
	return { base = base, grip = body * CFrame.new(0, y, 0), prompt = body * CFrame.new(0, y, 0) }
end

--------------------------------------------------------------------------------
-- Master keys: hung on a nail (mount space: origin at the nail's wall point, -Z out of the wall, +Y up)
--------------------------------------------------------------------------------

local NAIL_OUT = 0.42
local RING_RADIUS = 0.3
local RING_SEGMENTS = 8
local RING_WIRE = 0.05
local RING_Z = -0.26
local KEYS = 5

local function buildKeys(model: Model, mount: CFrame): Built
	local steel: PartOptions = { material = Enum.Material.Metal, color = ObjectiveKit.Steel, reflectance = 0.15 }
	local base = cylinder(
		model,
		"Base",
		mount * Vector3.new(0, 0, 0.06),
		mount * Vector3.new(0, 0, -NAIL_OUT),
		0.07,
		{ material = Enum.Material.Metal, color = ObjectiveKit.Iron }
	)
	local centre = Vector3.new(0, -RING_RADIUS - RING_WIRE / 2, RING_Z)
	local function ringPoint(angle: number): Vector3
		return centre + Vector3.new(math.cos(angle), math.sin(angle), 0) * RING_RADIUS
	end
	for i = 1, RING_SEGMENTS do
		local a0 = (i - 1) / RING_SEGMENTS * 2 * math.pi
		local a1 = i / RING_SEGMENTS * 2 * math.pi
		local p0, p1 = ringPoint(a0), ringPoint(a1)
		local extend = (p1 - p0).Unit * RING_WIRE * 0.45
		cylinder(model, "Ring" .. i, mount * (p0 - extend), mount * (p1 + extend), RING_WIRE, steel)
	end
	-- Keys hang straight down from the bottom of the ring, fanned a little, each a bow and a toothed blade
	for k = 1, KEYS do
		local t = (k - (KEYS + 1) / 2) / (KEYS - 1) -- -0.5 .. 0.5
		local angle = -math.pi / 2 + t * math.rad(80)
		local hang = ringPoint(angle) + Vector3.new(0, 0, -0.02 - 0.024 * k)
		local fan = CFrame.new(hang) * CFrame.Angles(0, 0, t * math.rad(28))
		local brass = k % 2 == 1
		local options: PartOptions = if brass
			then {
				material = Enum.Material.Metal,
				color = MathUtil.lerpColor(ObjectiveKit.Brass, Color3.new(), 0.1 * (k % 3)),
				reflectance = 0.12,
			}
			else steel
		local bow = fan * CFrame.new(0, -0.15, 0)
		cylinder(
			model,
			"KeyBow" .. k,
			mount * (bow * Vector3.new(0, 0, 0.012)),
			mount * (bow * Vector3.new(0, 0, -0.012)),
			0.24,
			options
		)
		local length = 0.5 + 0.08 * ((k * 7) % 3)
		block(
			model,
			"KeyBlade" .. k,
			mount * fan * CFrame.new(0, -0.27 - length / 2, 0),
			Vector3.new(0.08, length, 0.022),
			options
		)
	end
	local fob = block(
		model,
		"Fob",
		mount
			* CFrame.new(ringPoint(math.rad(-20)) + Vector3.new(0.12, -0.36, -0.03))
			* CFrame.Angles(0, 0, math.rad(-12)),
		Vector3.new(0.34, 0.56, 0.03),
		{ material = Enum.Material.SmoothPlastic, color = ObjectiveKit.LockRed }
	)
	ObjectiveKit.text(
		fob,
		"Tag",
		Strings.get("Prop.Keys.Tag"),
		ObjectiveKit.PlacardText,
		Enum.Font.Oswald,
		Enum.NormalId.Front,
		300
	)
	return {
		base = base,
		grip = mount * CFrame.new(centre),
		prompt = mount * CFrame.new(centre + Vector3.new(0, -0.3, -0.2)),
	}
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

type Shape = (model: Model, frame: CFrame) -> Built

local SHAPES: { [string]: Shape } = {
	Fuse = buildFuse,
	MasterKeys = buildKeys,
}

-- How a resting item sits on its anchor: the yaw it is given and whether it is settled onto the anchor plane
-- (hung items keep the anchor's frame).
local function restFrame(kind: string, cframe: CFrame, random: Rng): (CFrame, boolean)
	if kind == "MasterKeys" then
		return cframe, false
	end
	return cframe * CFrame.Angles(0, random:NextNumber(0, 2 * math.pi), 0), true
end

local function shapeInto(model: Model, kind: string, frame: CFrame): Built
	local shape = SHAPES[kind]
	assert(shape, "no objective item " .. kind)
	return shape(model, frame)
end

-- The cosmetic copy of an item (held in the hand): every part cosmetic, with its "Grip" attachment, no prompt, tags
-- or attributes. `cframe` is where it rests (as a world prop would).
function ObjectiveItemBuilder.buildVisual(parent: Instance, kind: string, cframe: CFrame): Model
	local model = PropKit.model(parent, kind, cframe)
	local built = shapeInto(model, kind, cframe)
	model.PrimaryPart = built.base
	Geometry.attachment(built.base, "Grip", built.base.CFrame:ToObjectSpace(built.grip))
	PropKit.cosmeticAll(model)
	return model
end

-- Builds one item for a PlannedProp of an objective item kind.
function ObjectiveItemBuilder.build(ctx: Types.PropBuildContext): Model
	local plan = ctx.prop
	local spec = ObjectiveConfig.forItem(plan.kind)
	local item = if spec then spec.item else nil
	assert(spec and item, "no floor objective uses " .. plan.kind)
	local frame, settled = restFrame(plan.kind, plan.cframe, ctx.random)
	local model = PropKit.model(ctx.parent, plan.kind .. "_" .. plan.anchorId, frame)
	local built = shapeInto(model, plan.kind, frame)
	model.PrimaryPart = built.base
	if settled then
		ObjectiveKit.settle(model, plan.cframe)
	end
	detailAll(model)
	local base = built.base
	Geometry.attachment(base, "Grip", base.CFrame:ToObjectSpace(built.grip))
	local promptPoint = Geometry.attachment(base, "PromptPoint", base.CFrame:ToObjectSpace(built.prompt))
	ObjectiveKit.prompt(
		promptPoint,
		spec,
		"Pickup",
		"Prompt.Pickup",
		item.object,
		spec.steps[1].id,
		model,
		nil,
		item.hold
	)
	local extra: { [string]: any } = {
		[W.AnchorId] = plan.anchorId,
		[W.Candidate] = item.candidate,
	}
	ObjectiveKit.mark(model, Tags.ObjectiveItem, spec, spec.steps[1].id, plan.kind, extra)
	return model
end

function ObjectiveItemBuilder.register(registrar: PropKit.Registrar)
	for _, kind in ObjectiveItemBuilder.Kinds do
		registrar.prop(kind, ObjectiveItemBuilder.build)
		registrar.rig(kind .. "Visual", function(parent: Instance, cframe: CFrame): Model
			return ObjectiveItemBuilder.buildVisual(parent, kind, cframe)
		end)
	end
end

return table.freeze(ObjectiveItemBuilder)
