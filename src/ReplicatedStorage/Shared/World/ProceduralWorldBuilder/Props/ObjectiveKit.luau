--!strict
-- ObjectiveKit: the vocabulary the floor-objective builders share (ObjectiveItemBuilder, AcidFlaskBuilder,
-- BreakerPanelBuilder, FumeHoodBuilder, GeneratorBuilder, HatchValveBuilder, LockBuilder).
--
--   mark(model, tag, spec, step, objectiveId, extra)  the objective's tag (ObjectiveItem | ObjectiveStation | ExitLock)
--                                                       and attributes Floor, Step, ObjectiveId, LevelId (+ extra)
--   prompt(host, spec, kind, action, object, step, tagged, slot?)  a disabled prompt (PropKit.prompt) whose hold is
--                                                       the floor's ObjectiveConfig hold for `kind`, carrying Step (+ Slot)
--   text(part, ...)                                     printed text on a part face (SurfaceGui), baked to decals on the web
--   settle(model, floor)                                lifts every part so the model's lowest point rests on `floor`
--   chain(parent, name, points, ...)                    chain links along a polyline, alternating 90 degrees
--   padlock(parent, name, frame, scale, ...)            a padlock hanging from its shackle at `frame` (shackle top centre)
--
-- Every helper is pure geometry on the parts it makes (no engine pivots), so it behaves the same in Roblox and in the
-- Lune harness that exports the web data.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)

local Geometry = require(script.Parent.Parent.Geometry)
local PickupBuilder = require(script.Parent.PickupBuilder)
local PropKit = require(script.Parent.PropKit)

local W = Attributes.World

type PartOptions = Geometry.PartOptions

local ObjectiveKit = {}

ObjectiveKit.Iron = Color3.fromRGB(58, 56, 52)
ObjectiveKit.Steel = Color3.fromRGB(96, 98, 98)
ObjectiveKit.Brass = Color3.fromRGB(128, 104, 58)
ObjectiveKit.Rust = Color3.fromRGB(96, 58, 36)
ObjectiveKit.LockRed = Color3.fromRGB(120, 28, 24)
ObjectiveKit.PlacardText = Color3.fromRGB(214, 206, 188)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- Tags `model` with `tag` and writes the objective attributes (Floor, Step, ObjectiveId, LevelId) plus `extra`.
function ObjectiveKit.mark(
	model: Instance,
	tag: string,
	spec: ObjectiveConfig.FloorSpec,
	step: string,
	objectiveId: string,
	extra: { [string]: any }?
)
	PropKit.setAttributes(model, {
		[W.Floor] = spec.floor,
		[W.Step] = step,
		[W.ObjectiveId] = objectiveId,
		[W.LevelId] = spec.levelId,
	})
	if extra then
		PropKit.setAttributes(model, extra)
	end
	model:AddTag(tag)
end

-- A disabled prompt of `kind` on `host` (Interactable tag on `tagged`), its hold the floor's configured hold for that
-- kind (`hold` overrides it), carrying the Step it serves (and its Slot).
function ObjectiveKit.prompt(
	host: Instance,
	spec: ObjectiveConfig.FloorSpec,
	kind: Enums.PromptKind,
	action: string,
	object: string,
	step: string,
	tagged: Instance,
	slot: number?,
	hold: number?,
	distance: number?
): ProximityPrompt
	local prompt = PropKit.prompt(host, {
		kind = kind,
		action = action,
		object = object,
		hold = hold or ObjectiveConfig.hold(spec, kind),
		distance = distance,
	}, tagged)
	prompt:SetAttribute(W.Step, step)
	if slot then
		prompt:SetAttribute(W.Slot, slot)
	end
	return prompt
end

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

-- Printed text on face `face` of `part` (default Front): a SurfaceGui with one scaled TextLabel.
function ObjectiveKit.text(
	part: BasePart,
	name: string,
	text: string,
	color: Color3,
	font: Enum.Font,
	face: Enum.NormalId?,
	pixelsPerStud: number?,
	lightInfluence: number?
): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Name = name
	gui.Face = face or Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud or 160
	gui.LightInfluence = lightInfluence or 1
	gui.MaxDistance = 40
	gui.ClipsDescendants = true
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(0.92, 0.82)
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.TextWrapped = true
	label.FontFace = Font.fromEnum(font)
	label.Parent = gui
	gui.Parent = part
	return gui
end

local function shapeOf(part: BasePart): Enum.PartType
	if part:IsA("Part") then
		return part.Shape
	end
	return Enum.PartType.Block
end

-- Moves every part of `model` along `floor`'s up axis so its lowest point lies on `floor`'s plane.
function ObjectiveKit.settle(model: Model, floor: CFrame)
	local parts: { BasePart } = {}
	local lowest = math.huge
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
			lowest = math.min(lowest, PickupBuilder.lowestPoint(floor:ToObjectSpace(d.CFrame), d.Size, shapeOf(d)))
		end
	end
	if lowest == math.huge then
		return
	end
	local lift = floor.UpVector * -lowest
	for _, part in parts do
		part.CFrame += lift
	end
end

-- Chain links along the polyline `points` (world), each `length` long, `width` across and `wire` thick, alternating
-- a quarter turn about the run so the chain reads as interlocked links. Returns the links made (at most `cap`).
function ObjectiveKit.chain(
	parent: Instance,
	name: string,
	points: { Vector3 },
	length: number,
	width: number,
	wire: number,
	options: PartOptions,
	cap: number,
	roll: number?
): { Part }
	local links: { Part } = {}
	local pitch = length * 0.78 -- links overlap where they interlock
	local index = 0
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local run = b - a
		local span = run.Magnitude
		if span < 1e-3 then
			continue
		end
		local axis = run / span
		local count = math.max(1, math.floor(span / pitch + 0.5))
		local step = span / count
		local helper = if math.abs(axis.Y) > 0.9 then Vector3.xAxis else Vector3.yAxis
		for k = 1, count do
			if #links >= cap then
				return links
			end
			index += 1
			local centre = a + axis * (step * (k - 0.5))
			local frame = CFrame.lookAt(centre, centre + axis, helper)
				* CFrame.Angles(0, 0, (roll or 0) + (if index % 2 == 0 then math.pi / 2 else 0))
			local link = Geometry.part(
				parent,
				string.format("%s%d", name, index),
				frame,
				Vector3.new(width, wire, length),
				nil,
				options
			)
			PropKit.detail(link)
			table.insert(links, link)
		end
	end
	return links
end

-- A padlock hanging from `frame` (the top centre of its shackle; -Z out of its face, +Y up), `scale` times a 0.5-stud
-- body. Returns its parts (body, shackle legs and bow, keyway), every one a hand-scale detail.
function ObjectiveKit.padlock(parent: Instance, name: string, frame: CFrame, scale: number, body: Color3): { BasePart }
	local out: { BasePart } = {}
	local w, h, d = 0.5 * scale, 0.42 * scale, 0.2 * scale
	local bow = 0.3 * scale
	local legX = w * 0.3
	local thick = 0.07 * scale
	local steel: PartOptions = { material = Enum.Material.Metal, color = ObjectiveKit.Steel, reflectance = 0.1 }
	local bodyPart = Geometry.part(
		parent,
		name .. "Body",
		frame * CFrame.new(0, -bow - h / 2, 0),
		Vector3.new(w, h, d),
		nil,
		{ material = Enum.Material.Metal, color = body, reflectance = 0.06 }
	)
	table.insert(out, bodyPart)
	for i, x in { -legX, legX } do
		local leg = Geometry.cylinder(
			parent,
			string.format("%sShackle%d", name, i),
			frame * Vector3.new(x, -thick / 2, 0),
			frame * Vector3.new(x, -bow - 0.02, 0),
			thick,
			nil,
			steel
		)
		if leg then
			table.insert(out, leg)
		end
	end
	local top = Geometry.cylinder(
		parent,
		name .. "ShackleTop",
		frame * Vector3.new(-legX - thick / 2, -thick / 2, 0),
		frame * Vector3.new(legX + thick / 2, -thick / 2, 0),
		thick,
		nil,
		steel
	)
	if top then
		table.insert(out, top)
	end
	table.insert(
		out,
		Geometry.part(
			parent,
			name .. "Keyway",
			frame * CFrame.new(0, -bow - h * 0.62, -d / 2 - 0.004),
			Vector3.new(0.05 * scale, 0.12 * scale, 0.01),
			nil,
			{ material = Enum.Material.SmoothPlastic, color = Color3.fromRGB(14, 14, 14) }
		)
	)
	for _, part in out do
		PropKit.detail(part)
	end
	return out
end

-- Counts the BaseParts under `root`.
function ObjectiveKit.partCount(root: Instance): number
	local n = 0
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	return n
end

return table.freeze(ObjectiveKit)
