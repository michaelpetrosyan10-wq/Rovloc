--!strict
-- ObjectiveItemBuilder: the floor objectives' carryable items, plan props RunDirector places on the run's picks among
-- each floor's candidate anchors (ObjectiveConfig item.prop / item.candidate), built into Workspace.Runtime.<level> at
-- Deploying like the batteries and flasks:
--
--   Fuse         (Level 0)  a big industrial cartridge fuse: grimy ceramic barrel, brass end caps and blade contacts,
--                           a printed "100A" band and a red blown-indicator pin. Lies on its side.
--   MasterKeys   (Level 1)  the janitor's ring of keys hung on a nail driven into the wall: a steel ring, five brass
--                           and steel keys fanned under it and a red "MASTER" fob. The anchor is the nail's wall point.
--   ReagentJar   (Level 2)  a labelled amber reagent jar: coloured liquid, screw cap and label stripe coded by the
--                           prop's slot (1 Nitric orange, 2 Sulfuric blue, 3 Catalyst green). Stands on a worktop.
--   CoachKey     (Level 3)  the coach's key on a red lanyard with a whistle and a "COACH" tag, on a hook inside a
--                           locker (the anchor is the hook on the locker's back wall).
--   ValveWheel   (Level 4)  a cast-iron handwheel in chipped red paint: rim, four spokes, a hub with a square drive.
--                           Lies flat on the pool floor.
--   BoltCutters  (Level 5)  long-handled bolt cutters with red rubber grips; leaning against the plant behind the
--                           anchor (a deck anchor), or lying on the surface (an anchor above the deck).
--
-- Every part is a PropKit.detail (no collision, no query), the same as the other pickups. Model attributes AnchorId,
-- LevelId, Candidate (the anchor kind), Slot (the plan's slot), Floor, Step (the floor's find step), ObjectiveId (the
-- item kind); tags ObjectiveItem and Interactable; Attachment "Grip" (where a hand holds it; the valve wheel also has
-- "Hub", its axis as UpVector, which the hatch valve's WheelSeat takes) and a disabled Pickup
-- prompt (hold item.hold, object item.object; a reagent's object names its reagent) on Attachment "PromptPoint".
-- buildVisual(parent, kind, cframe, slot) is the cosmetic copy for the held item (every part makeCosmetic, no prompt,
-- tags or attributes); each kind is also registered as a rig "<Kind>Visual". Part budgets per kind in MaxParts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(script.Parent.Parent.Geometry)
local ObjectiveKit = require(script.Parent.ObjectiveKit)
local PropKit = require(script.Parent.PropKit)

local W = Attributes.World

type PartOptions = Geometry.PartOptions
type Built = { base: BasePart, grip: CFrame, prompt: CFrame, hub: CFrame? }

local ObjectiveItemBuilder = {}

ObjectiveItemBuilder.Kinds =
	table.freeze({ "Fuse", "MasterKeys", "ReagentJar", "CoachKey", "ValveWheel", "BoltCutters" })
ObjectiveItemBuilder.MaxParts = table.freeze({
	Fuse = 8,
	MasterKeys = 24,
	ReagentJar = 8,
	CoachKey = 12,
	ValveWheel = 20,
	BoltCutters = 12,
} :: { [string]: number })

local SLOT_COLORS: { Color3 } = {
	Color3.fromRGB(206, 112, 34), -- Nitric
	Color3.fromRGB(48, 92, 184), -- Sulfuric
	Color3.fromRGB(84, 164, 60), -- Catalyst
}

-- The slot colour of a reagent (1..3; anything else wraps).
function ObjectiveItemBuilder.slotColor(slot: number?): Color3
	local n = if slot and slot == slot then math.floor(slot) else 1
	return SLOT_COLORS[(n - 1) % #SLOT_COLORS + 1]
end

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

local function buildFuse(model: Model, body: CFrame, _slot: number?): Built
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

local function buildKeys(model: Model, mount: CFrame, _slot: number?): Built
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
				color = ObjectiveKit.Brass:Lerp(Color3.new(), 0.1 * (k % 3)),
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
-- Reagent jar: standing (body space: origin on the worktop, Y up, the label facing -Z)
--------------------------------------------------------------------------------

local JAR_DIAMETER = 0.56
local JAR_HEIGHT = 0.72
local AMBER = Color3.fromRGB(122, 74, 30)

local function buildJar(model: Model, body: CFrame, slot: number?): Built
	local color = ObjectiveItemBuilder.slotColor(slot)
	local function upright(name: string, y0: number, y1: number, d: number, options: PartOptions): Part
		return cylinder(model, name, body * Vector3.new(0, y0, 0), body * Vector3.new(0, y1, 0), d, options)
	end
	local base = upright(
		"Base",
		0,
		JAR_HEIGHT,
		JAR_DIAMETER,
		{ material = Enum.Material.Glass, color = AMBER, transparency = 0.35, reflectance = 0.06 }
	)
	upright(
		"Liquid",
		0.04,
		JAR_HEIGHT * 0.72,
		JAR_DIAMETER - 0.07,
		{ material = Enum.Material.SmoothPlastic, color = color:Lerp(AMBER, 0.35), transparency = 0.08 }
	)
	upright(
		"Shoulder",
		JAR_HEIGHT - 0.01,
		JAR_HEIGHT + 0.07,
		JAR_DIAMETER * 0.78,
		{ material = Enum.Material.Glass, color = AMBER, transparency = 0.3 }
	)
	upright(
		"Cap",
		JAR_HEIGHT + 0.06,
		JAR_HEIGHT + 0.22,
		JAR_DIAMETER * 0.74,
		{ material = Enum.Material.SmoothPlastic, color = color }
	)
	local label = block(
		model,
		"Label",
		body * CFrame.new(0, JAR_HEIGHT * 0.45, -JAR_DIAMETER / 2 - 0.004),
		Vector3.new(JAR_DIAMETER * 0.78, 0.34, 0.01),
		{ material = Enum.Material.SmoothPlastic, color = Color3.fromRGB(176, 168, 140) }
	)
	local n = if slot then slot else 1
	ObjectiveKit.text(
		label,
		"Reagent",
		Strings.get("Prop.Reagent." .. tostring((n - 1) % 3 + 1)),
		Color3.fromRGB(34, 24, 18),
		Enum.Font.Oswald,
		Enum.NormalId.Front,
		400
	)
	block(
		model,
		"Stripe",
		body * CFrame.new(0, JAR_HEIGHT * 0.45 + 0.2, -JAR_DIAMETER / 2 - 0.006),
		Vector3.new(JAR_DIAMETER * 0.78, 0.07, 0.012),
		{ material = Enum.Material.SmoothPlastic, color = color }
	)
	return {
		base = base,
		grip = body * CFrame.new(0, JAR_HEIGHT * 0.5, 0),
		prompt = body * CFrame.new(0, JAR_HEIGHT * 0.5, 0),
	}
end

--------------------------------------------------------------------------------
-- Coach's key: on a hook inside a locker (mount space: origin at the hook's wall point, -Z out, +Y up)
--------------------------------------------------------------------------------

local LANYARD_RED = Color3.fromRGB(150, 30, 26)

local function buildCoachKey(model: Model, mount: CFrame, _slot: number?): Built
	local base = cylinder(
		model,
		"Base",
		mount * Vector3.new(0, 0, 0.04),
		mount * Vector3.new(0, 0, -0.22),
		0.07,
		{ material = Enum.Material.Metal, color = ObjectiveKit.Steel }
	)
	local cord: PartOptions = { material = Enum.Material.Fabric, color = LANYARD_RED }
	local bottom = Vector3.new(0.02, -1.05, -0.16)
	for i, x in { -0.13, 0.13 } do
		local top = Vector3.new(x * 0.4, -0.02, -0.18)
		local low = bottom + Vector3.new(x * 0.5, 0, 0)
		block(
			model,
			"Lanyard" .. i,
			mount * CFrame.lookAt((top + low) / 2, low, Vector3.zAxis),
			Vector3.new(0.06, 0.012, (low - top).Magnitude),
			cord
		)
	end
	-- A steel whistle on the lanyard, the key beside it
	local whistle = mount * CFrame.new(bottom + Vector3.new(-0.1, -0.12, -0.02))
	cylinder(
		model,
		"Whistle",
		whistle * Vector3.new(-0.15, 0, 0),
		whistle * Vector3.new(0.12, 0, 0),
		0.17,
		{ material = Enum.Material.Metal, color = Color3.fromRGB(168, 170, 166), reflectance = 0.25 }
	)
	block(
		model,
		"WhistleMouth",
		whistle * CFrame.new(0.2, 0.03, 0),
		Vector3.new(0.14, 0.08, 0.1),
		{ material = Enum.Material.Metal, color = Color3.fromRGB(150, 152, 150) }
	)
	local brass: PartOptions = { material = Enum.Material.Metal, color = ObjectiveKit.Brass, reflectance = 0.15 }
	local key = mount * CFrame.new(bottom + Vector3.new(0.14, -0.06, -0.03)) * CFrame.Angles(0, 0, math.rad(8))
	cylinder(model, "KeyBow", key * Vector3.new(0, -0.08, 0.012), key * Vector3.new(0, -0.08, -0.012), 0.24, brass)
	block(model, "KeyBlade", key * CFrame.new(0, -0.44, 0), Vector3.new(0.08, 0.52, 0.022), brass)
	block(model, "KeyTeeth", key * CFrame.new(0.06, -0.52, 0), Vector3.new(0.05, 0.26, 0.02), brass)
	local tag = block(
		model,
		"Tag",
		mount * CFrame.new(bottom + Vector3.new(-0.02, -0.5, -0.05)),
		Vector3.new(0.3, 0.2, 0.02),
		{ material = Enum.Material.SmoothPlastic, color = Color3.fromRGB(190, 186, 170) }
	)
	ObjectiveKit.text(
		tag,
		"Tag",
		Strings.get("Prop.CoachKey.Tag"),
		Color3.fromRGB(28, 34, 76),
		Enum.Font.Oswald,
		Enum.NormalId.Front,
		400
	)
	return {
		base = base,
		grip = mount * CFrame.new(bottom),
		prompt = mount * CFrame.new(bottom + Vector3.new(0, 0, -0.3)),
	}
end

--------------------------------------------------------------------------------
-- Valve wheel: lying flat (body space: origin on the resting point, Y up)
--------------------------------------------------------------------------------

local WHEEL_RADIUS = 0.86
local WHEEL_RIM = 0.15
local WHEEL_SEGMENTS = 12
local WHEEL_SPOKES = 4
local WHEEL_RED = Color3.fromRGB(140, 34, 26)

local function buildWheel(model: Model, body: CFrame, _slot: number?): Built
	local paint: PartOptions = { material = Enum.Material.CorrodedMetal, color = WHEEL_RED }
	local y = WHEEL_RIM / 2
	local hub = cylinder(model, "Base", body * Vector3.new(0, 0, 0), body * Vector3.new(0, 0.3, 0), 0.42, paint)
	block(
		model,
		"Drive",
		body * CFrame.new(0, 0.3, 0),
		Vector3.new(0.16, 0.012, 0.16),
		{ material = Enum.Material.SmoothPlastic, color = Color3.fromRGB(16, 14, 12) }
	)
	local function rim(angle: number): Vector3
		return Vector3.new(math.cos(angle) * WHEEL_RADIUS, y, math.sin(angle) * WHEEL_RADIUS)
	end
	for i = 1, WHEEL_SEGMENTS do
		local a0 = (i - 1) / WHEEL_SEGMENTS * 2 * math.pi
		local a1 = i / WHEEL_SEGMENTS * 2 * math.pi
		local p0, p1 = rim(a0), rim(a1)
		local extend = (p1 - p0).Unit * WHEEL_RIM * 0.45
		cylinder(model, "Rim" .. i, body * (p0 - extend), body * (p1 + extend), WHEEL_RIM, paint)
	end
	for i = 1, WHEEL_SPOKES do
		local angle = (i - 0.5) / WHEEL_SPOKES * 2 * math.pi
		cylinder(
			model,
			"Spoke" .. i,
			body * Vector3.new(0, y + 0.04, 0),
			body * (rim(angle) * 0.97 + Vector3.new(0, 0.0, 0)),
			0.1,
			paint
		)
	end
	return {
		base = hub,
		grip = body * CFrame.new(rim(0)),
		prompt = body * CFrame.new(0, 0.4, 0),
		hub = body * CFrame.new(0, 0.15, 0),
	}
end

--------------------------------------------------------------------------------
-- Bolt cutters (tool space: origin at the grip ends' midpoint, +X toward the jaws, lying flat on Y = 0)
--------------------------------------------------------------------------------

local CUTTER_LENGTH = 2.5
local HANDLE_SPLAY = math.rad(5)
local GRIP_LENGTH = 0.62
local GRIP_RED = Color3.fromRGB(150, 32, 24)

local function buildCuttersFlat(model: Model, tool: CFrame): Built
	local steel: PartOptions =
		{ material = Enum.Material.Metal, color = Color3.fromRGB(70, 74, 76), reflectance = 0.05 }
	local y = 0.1
	local pivotX = CUTTER_LENGTH - 0.5
	for i, sign in { -1, 1 } do
		local tail = Vector3.new(0, y, sign * pivotX * math.tan(HANDLE_SPLAY))
		local head = Vector3.new(pivotX, y, sign * 0.05)
		cylinder(model, "Handle" .. i, tool * tail, tool * head, 0.11, steel)
		local dir = (head - tail).Unit
		cylinder(
			model,
			"Grip" .. i,
			tool * (tail - dir * 0.03),
			tool * (tail + dir * GRIP_LENGTH),
			0.17,
			{ material = Enum.Material.Rubber, color = GRIP_RED }
		)
		block(
			model,
			"Jaw" .. i,
			tool * CFrame.new(pivotX + 0.28, y, sign * 0.06),
			Vector3.new(0.5, 0.18, 0.1),
			{ material = Enum.Material.Metal, color = Color3.fromRGB(44, 46, 48) }
		)
	end
	local plate = block(model, "Base", tool * CFrame.new(pivotX + 0.02, y, 0), Vector3.new(0.34, 0.06, 0.3), steel)
	cylinder(
		model,
		"PivotBolt1",
		tool * Vector3.new(pivotX - 0.05, y - 0.06, 0),
		tool * Vector3.new(pivotX - 0.05, y + 0.06, 0),
		0.1,
		steel
	)
	cylinder(
		model,
		"PivotBolt2",
		tool * Vector3.new(pivotX + 0.1, y - 0.06, 0),
		tool * Vector3.new(pivotX + 0.1, y + 0.06, 0),
		0.1,
		steel
	)
	return {
		base = plate,
		grip = tool * CFrame.new(GRIP_LENGTH * 0.5, y, 0),
		prompt = tool * CFrame.new(CUTTER_LENGTH * 0.5, y, 0),
	}
end

local LEAN = math.rad(16) -- from upright, back against the face behind the anchor
local LEAN_FOOT = 0.55 -- the grips stand this far behind the anchor (deck anchors sit 1.4 off the face)

local function buildCutters(model: Model, frame: CFrame, leaning: boolean): Built
	if not leaning then
		return buildCuttersFlat(model, frame)
	end
	-- Stood on its grips, jaws up, leaning back (+Z) against the face behind the anchor
	local tool = frame * CFrame.new(0, 0, LEAN_FOOT) * CFrame.Angles(LEAN, 0, 0) * CFrame.Angles(0, 0, math.pi / 2)
	return buildCuttersFlat(model, tool)
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

type Shape = (model: Model, frame: CFrame, slot: number?) -> Built

local SHAPES: { [string]: Shape } = {
	Fuse = buildFuse,
	MasterKeys = buildKeys,
	ReagentJar = buildJar,
	CoachKey = buildCoachKey,
	ValveWheel = buildWheel,
}

-- How a resting item sits on its anchor: the yaw it is given and whether it is settled onto the anchor plane
-- (hung items keep the anchor's frame).
local function restFrame(kind: string, cframe: CFrame, random: Random, leaning: boolean): (CFrame, boolean)
	if kind == "MasterKeys" or kind == "CoachKey" then
		return cframe, false
	elseif leaning then
		return cframe, true
	elseif kind == "ReagentJar" then
		return cframe * CFrame.Angles(0, random:NextNumber(-0.5, 0.5), 0), true
	end
	return cframe * CFrame.Angles(0, random:NextNumber(0, 2 * math.pi), 0), true
end

local function shapeInto(model: Model, kind: string, frame: CFrame, slot: number?, leaning: boolean): Built
	if kind == "BoltCutters" then
		return buildCutters(model, frame, leaning)
	end
	local shape = SHAPES[kind]
	assert(shape, "no objective item " .. kind)
	return shape(model, frame, slot)
end

-- The cosmetic copy of an item (held in the hand): every part cosmetic, with its "Grip" attachment, no prompt, tags
-- or attributes. `cframe` is where it rests (as a world prop would).
function ObjectiveItemBuilder.buildVisual(parent: Instance, kind: string, cframe: CFrame, slot: number?): Model
	local model = PropKit.model(parent, kind, cframe)
	local built = shapeInto(model, kind, cframe, slot, false)
	model.PrimaryPart = built.base
	Geometry.attachment(built.base, "Grip", built.base.CFrame:ToObjectSpace(built.grip))
	PropKit.cosmeticAll(model)
	return model
end

-- Builds one item for a PlannedProp of an objective item kind.
function ObjectiveItemBuilder.build(ctx: Types.PropBuildContext): Model
	local plan = ctx.prop
	local spec = ObjectiveConfig.forItem(plan.kind)
	assert(spec, "no floor objective uses " .. plan.kind)
	-- Bolt cutters on the deck lean on the plant behind their anchor; anywhere higher they lie on the surface
	local leaning = plan.kind == "BoltCutters"
		and plan.cframe.Position.Y - WorldConfig.levelOrigin(plan.levelId).Y < 0.5
	local frame, settled = restFrame(plan.kind, plan.cframe, ctx.random, leaning)
	local model = PropKit.model(ctx.parent, plan.kind .. "_" .. plan.anchorId, frame)
	local built = shapeInto(model, plan.kind, frame, plan.slot, leaning)
	model.PrimaryPart = built.base
	if settled then
		ObjectiveKit.settle(model, plan.cframe)
	end
	detailAll(model)
	local base = built.base
	Geometry.attachment(base, "Grip", base.CFrame:ToObjectSpace(built.grip))
	local promptPoint = Geometry.attachment(base, "PromptPoint", base.CFrame:ToObjectSpace(built.prompt))
	if built.hub then
		Geometry.attachment(base, "Hub", base.CFrame:ToObjectSpace(built.hub))
	end
	local object = if plan.kind == "ReagentJar"
		then "Prompt.Reagent." .. tostring(((plan.slot or 1) - 1) % 3 + 1)
		else spec.item.object
	ObjectiveKit.prompt(
		promptPoint,
		spec,
		"Pickup",
		"Prompt.Pickup",
		object,
		spec.steps[1].id,
		model,
		plan.slot,
		spec.item.hold
	)
	local extra: { [string]: any } = {
		[W.AnchorId] = plan.anchorId,
		[W.Candidate] = spec.item.candidate,
		[W.Slot] = plan.slot or 1,
	}
	ObjectiveKit.mark(model, Tags.ObjectiveItem, spec, spec.steps[1].id, plan.kind, extra)
	return model
end

function ObjectiveItemBuilder.register(registrar: PropKit.Registrar)
	for _, kind in ObjectiveItemBuilder.Kinds do
		registrar.prop(kind, ObjectiveItemBuilder.build)
		registrar.rig(kind .. "Visual", function(parent: Instance, cframe: CFrame): Model
			return ObjectiveItemBuilder.buildVisual(parent, kind, cframe, 1)
		end)
	end
end

return table.freeze(ObjectiveItemBuilder)
