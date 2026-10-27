--!strict
-- Plan props: bear traps, chemical flasks and battery pickups, built through Builder.BuildProp exactly as WorldService
-- does at Deploying (hand-made PlannedProps at rotated CFrames, and every candidate anchor of the real layouts).
-- Contracts: model names, PrimaryPart, tags, attributes and disabled prompts (kind, hold, texts); part budgets;
-- nothing collides or is queried; the bottom rests exactly on the plan point (floor, worktop or block top); the trap
-- is built armed and its jaw / spring / pan poses round-trip, with armed jaws flat and snapped jaws standing up
-- interlocked; its TriggerVolume is a NoCollide volume holding LegPoint and a walker's feet point and root; the flask's
-- visual copy is all-cosmetic with a Grip and is registered as a rig; same seed, same geometry.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)

local BearTrapBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.BearTrapBuilder)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local ChemicalFlaskBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.ChemicalFlaskBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local PickupBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PickupBuilder)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local W = Attributes.World

local TRAP_BUDGET = 40
local FLASK_BUDGET = 14
local BATTERY_BUDGET = 10
local REST_EPSILON = 1e-4
local POSE_DRIFT = 2e-4 -- float32 rounding allowed after a handful of re-poses

local BASEMENT: Enums.LayoutId = "Level0_Basement"
local SCIENCE: Enums.LayoutId = "Level2_ScienceHall"
local POOL: Enums.LayoutId = "Level4_FloodedPool"

-- Rotated, off-origin plan points (yaw only, as RunDirector's anchor CFrames are).
local POINTS: { CFrame } = {
	CFrame.new(31.5, -84, 112.25) * CFrame.Angles(0, math.rad(-127), 0),
	CFrame.new(-12, 3.2, 40) * CFrame.Angles(0, math.rad(37), 0),
	CFrame.new(140, 61.5, -8) * CFrame.Angles(0, math.rad(90), 0),
}

local FORBIDDEN_CLASSES: { string } = {
	"Light",
	"Decal",
	"MeshPart",
	"SpecialMesh",
	"FileMesh",
	"SurfaceAppearance",
	"PartOperation",
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Runs `fn` with Geometry's cooperative yielding off (specs never task.wait), restoring it afterwards.
local function quiet(fn: () -> ())
	local previous = Geometry.getYieldEvery()
	Geometry.setYieldEvery(0)
	local failure: any = nil
	xpcall(fn, function(err: any)
		failure = err
	end)
	Geometry.setYieldEvery(previous)
	if failure ~= nil then
		error(failure, 0)
	end
end

local function planned(
	kind: string,
	anchorId: string,
	levelId: Enums.LayoutId,
	cframe: CFrame,
	variant: number
): Types.PlannedProp
	return { kind = kind, anchorId = anchorId, levelId = levelId, cframe = cframe, variant = variant }
end

local function build(plan: Types.PlannedProp, seed: number): Model
	local folder = Instance.new("Folder")
	folder.Name = "SpecProps"
	local built = Builder.BuildProp(plan, folder, Random.new(seed))
	assert(built ~= nil, string.format("%s at %s built nothing", plan.kind, plan.anchorId))
	assert(built:IsA("Model"), plan.kind .. " builds a Model")
	assert(built.Parent == folder, plan.kind .. " is parented to the plan folder")
	return built
end

-- Destroys the folder a spec build was parented to (and so the model).
local function discard(model: Model)
	local folder = model.Parent
	if folder then
		folder:Destroy()
	end
end

local function parts(root: Instance): { BasePart }
	local out: { BasePart } = {}
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(out, descendant)
		end
	end
	return out
end

local function visibleParts(root: Instance): { BasePart }
	local out: { BasePart } = {}
	for _, part in parts(root) do
		if part.Transparency < 1 then
			table.insert(out, part)
		end
	end
	return out
end

local function leafParts(model: Model, leaf: string): { BasePart }
	local found = model:FindFirstChild(leaf)
	assert(found and found:IsA("Model"), "leaf " .. leaf)
	return parts(found)
end

local function leafPart(model: Model, leaf: string, name: string): BasePart
	for _, part in leafParts(model, leaf) do
		if part.Name == name then
			return part
		end
	end
	error(string.format("leaf %s has no part %s", leaf, name))
end

-- Lowest and highest points of a part along `frame`'s up axis (exact for blocks, wedges, cylinders and balls).
local function extentY(part: BasePart, frame: CFrame): (number, number)
	local cf = frame:ToObjectSpace(part.CFrame)
	local size = part.Size
	local y = cf.Position.Y
	local shape = if part:IsA("Part") then part.Shape else Enum.PartType.Block
	if shape == Enum.PartType.Ball then
		local radius = math.min(size.X, size.Y, size.Z) / 2
		return y - radius, y + radius
	elseif shape == Enum.PartType.Cylinder then
		local axisY = cf.RightVector.Y
		local reach = math.abs(axisY) * size.X / 2
			+ math.min(size.Y, size.Z) / 2 * math.sqrt(math.max(0, 1 - axisY * axisY))
		return y - reach, y + reach
	end
	local half = size / 2
	local corners: { Vector3 } = {}
	if part:IsA("WedgePart") then
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				table.insert(corners, Vector3.new(sx * half.X, -half.Y, sz * half.Z))
			end
			table.insert(corners, Vector3.new(sx * half.X, half.Y, half.Z))
		end
	else
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					table.insert(corners, Vector3.new(sx * half.X, sy * half.Y, sz * half.Z))
				end
			end
		end
	end
	local lo, hi = math.huge, -math.huge
	for _, corner in corners do
		local cornerY = (cf * corner).Y
		lo = math.min(lo, cornerY)
		hi = math.max(hi, cornerY)
	end
	return lo, hi
end

local function lowest(list: { BasePart }, frame: CFrame): number
	local out = math.huge
	for _, part in list do
		out = math.min(out, (extentY(part, frame)))
	end
	return out
end

local function highest(list: { BasePart }, frame: CFrame): number
	local out = -math.huge
	for _, part in list do
		local _, hi = extentY(part, frame)
		out = math.max(out, hi)
	end
	return out
end

-- Largest horizontal distance of any bounding-box corner from `frame`'s origin.
local function horizontalReach(list: { BasePart }, frame: CFrame): number
	local out = 0
	for _, part in list do
		local half = part.Size / 2
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				for _, sy in { -1, 1 } do
					local p = frame:PointToObjectSpace(part.CFrame * Vector3.new(sx * half.X, sy * half.Y, sz * half.Z))
					out = math.max(out, Vector3.new(p.X, 0, p.Z).Magnitude)
				end
			end
		end
	end
	return out
end

local function contains(volume: BasePart, point: Vector3): boolean
	local p = volume.CFrame:PointToObjectSpace(point)
	local half = volume.Size / 2
	return math.abs(p.X) <= half.X and math.abs(p.Y) <= half.Y and math.abs(p.Z) <= half.Z
end

local function cframeNear(a: CFrame, b: CFrame, epsilon: number): boolean
	local ac = { a:GetComponents() }
	local bc = { b:GetComponents() }
	for i = 1, 12 do
		if math.abs(ac[i] - bc[i]) > epsilon then
			return false
		end
	end
	return true
end

local function snapshot(root: Instance): { CFrame }
	local out: { CFrame } = {}
	for _, part in parts(root) do
		table.insert(out, part.CFrame)
	end
	return out
end

local function snapshotDrift(a: { CFrame }, b: { CFrame }): number
	assert(#a == #b, "snapshots of the same model")
	local drift = 0
	for i, cf in a do
		local ac = { cf:GetComponents() }
		local bc = { b[i]:GetComponents() }
		for k = 1, 12 do
			drift = math.max(drift, math.abs(ac[k] - bc[k]))
		end
	end
	return drift
end

local function sameSnapshot(a: { CFrame }, b: { CFrame }, epsilon: number): boolean
	if #a ~= #b then
		return false
	end
	for i, cf in a do
		if not cframeNear(cf, b[i], epsilon) then
			return false
		end
	end
	return true
end

local function attachmentWorld(root: Instance, name: string): CFrame
	local attachment = PropKit.findAttachment(root, name)
	assert(attachment, "attachment " .. name)
	return PropKit.attachmentWorld(attachment)
end

local function expectIdentity(t: Expect, model: Model, plan: Types.PlannedProp, tag: string)
	t.eq(model.Name, plan.kind .. "_" .. plan.anchorId, "model name")
	local primary = model.PrimaryPart
	assert(primary, plan.kind .. " has a PrimaryPart")
	t.eq(primary.Name, "Base", "PrimaryPart name")
	t.truthy(primary:IsDescendantOf(model), "PrimaryPart inside the model")
	t.truthy(model:HasTag(tag), plan.kind .. " tagged " .. tag)
	t.truthy(model:HasTag(Tags.Interactable), plan.kind .. " tagged Interactable")
	t.eq(model:GetAttribute(W.AnchorId), plan.anchorId, "AnchorId")
	t.eq(model:GetAttribute(W.LevelId), plan.levelId, "LevelId")
end

local function expectPrompt(
	t: Expect,
	model: Model,
	kind: Enums.PromptKind,
	action: string,
	object: string,
	hold: number
): ProximityPrompt
	local prompt = PropKit.findPrompt(model, kind)
	assert(prompt, "prompt " .. kind)
	t.falsy(prompt.Enabled, kind .. " starts disabled")
	t.eq(prompt.Name, kind)
	t.near(prompt.HoldDuration, hold, 1e-5, kind .. " hold") -- stored as float32
	t.eq(prompt:GetAttribute(W.BaseHold), hold, kind .. " BaseHold")
	t.eq(prompt.ActionText, Strings.get(action), kind .. " action text")
	t.eq(prompt.ObjectText, Strings.get(object), kind .. " object text")
	local host = prompt.Parent
	t.truthy(host ~= nil and host:IsA("Attachment"), kind .. " hosted on an Attachment")
	return prompt
end

-- Every part anchored, never collided, touched or queried; visible parts cast no shadow. No forbidden classes.
local function expectInert(t: Expect, model: Model, label: string)
	for _, part in parts(model) do
		t.truthy(part.Anchored, label .. " " .. part.Name .. " anchored")
		t.falsy(part.CanCollide, label .. " " .. part.Name .. " collides")
		t.falsy(part.CanQuery, label .. " " .. part.Name .. " is queryable")
		t.falsy(part.CanTouch, label .. " " .. part.Name .. " is touchable")
		t.falsy(part.CastShadow, label .. " " .. part.Name .. " casts a shadow")
	end
	for _, descendant in model:GetDescendants() do
		for _, class in FORBIDDEN_CLASSES do
			t.falsy(descendant:IsA(class), label .. " contains a " .. descendant.ClassName)
		end
	end
end

local function trapPlan(index: number, variant: number): Types.PlannedProp
	return planned("BearTrap", "SpecTrap_" .. index, BASEMENT, POINTS[index], variant)
end

local function flaskPlan(index: number, variant: number): Types.PlannedProp
	return planned("ChemicalFlask", "SpecFlask_" .. index, SCIENCE, POINTS[index], variant)
end

local function batteryPlan(index: number, variant: number): Types.PlannedProp
	return planned("Battery", "SpecBattery_" .. index, BASEMENT, POINTS[index], variant)
end

local function anchorsOf(layoutId: Enums.LayoutId, kind: Enums.AnchorKind): { { id: string, cframe: CFrame } }
	local layout = Builder.getLayout(layoutId)
	local out: { { id: string, cframe: CFrame } } = {}
	if not layout then
		return out
	end
	for _, anchor in layout.anchors do
		if anchor.kind == kind then
			table.insert(out, { id = anchor.id, cframe = Builder.anchorCFrame(layoutId, anchor) })
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["BearTrap: identity, Armed attribute and the disabled pry / rescue prompts"] = function(t: Expect)
		quiet(function()
			for index = 1, #POINTS do
				local plan = trapPlan(index, 1000 + index)
				local model = build(plan, index)
				expectIdentity(t, model, plan, Tags.BearTrap)
				t.eq(model:GetAttribute(W.Armed), true, "built armed")
				t.eq(model:GetAttribute(W.TrappedUserId), nil, "nobody trapped yet")
				local pry =
					expectPrompt(t, model, "TrapPry", "Prompt.TrapPry", "Prompt.Trap", GameConfig.TrapSoloPrySeconds)
				local rescue = expectPrompt(
					t,
					model,
					"TrapRescue",
					"Prompt.TrapRescue",
					"Prompt.Trap",
					GameConfig.TrapRescueSeconds
				)
				t.eq(pry.Parent, rescue.Parent, "both prompts share the attachment over the trap")
				local host = plan.cframe:PointToObjectSpace(attachmentWorld(model, "PromptPoint").Position)
				t.truthy(host.Y > 0 and Vector3.new(host.X, 0, host.Z).Magnitude < 0.05, "prompt over the trap")
				discard(model)
			end
		end)
	end,

	["BearTrap: budget, inert details, resting on the floor point"] = function(t: Expect)
		quiet(function()
			for index = 1, #POINTS do
				local plan = trapPlan(index, 77 * index)
				local model = build(plan, 40 + index)
				local count = #parts(model)
				t.truthy(count <= TRAP_BUDGET, string.format("trap budget (%d parts)", count))
				expectInert(t, model, "trap")
				local visible = visibleParts(model)
				t.eq(#visible, count - 1, "every part but the TriggerVolume is visible")
				t.near(lowest(visible, plan.cframe), 0, REST_EPSILON, "trap bottom on the floor point")
				for _, part in visible do
					t.eq(part.CollisionGroup, CollisionGroups.Default, part.Name .. " stays a plain detail")
				end
				local reach = horizontalReach(visible, plan.cframe)
				t.truthy(reach > 1 and reach < 2.6, string.format("trap footprint (%.2f studs)", reach))
				discard(model)
			end
		end)
	end,

	["BearTrap: built armed; jaw, spring and pan poses round-trip"] = function(t: Expect)
		quiet(function()
			local model = build(trapPlan(2, 31), 9)
			local open = BearTrapBuilder.JawOpenAngle
			local travel = BearTrapBuilder.SpringTravel
			local function expectPose(leaf: string, expected: CFrame, label: string)
				local transform = PropKit.leafTransform(model, leaf)
				assert(transform, leaf .. " has a rest pose")
				t.truthy(cframeNear(transform, expected, 1e-5), string.format("%s %s", leaf, label))
			end
			expectPose("JawA", CFrame.Angles(open, 0, 0), "built armed")
			expectPose("JawB", CFrame.Angles(-open, 0, 0), "built armed")
			expectPose("SpringA", CFrame.Angles(0, 0, travel), "built pressed")
			expectPose("SpringB", CFrame.Angles(0, 0, -travel), "built pressed")
			expectPose("Pan", CFrame.new(), "built level")
			local armed = snapshot(model)

			t.truthy(BearTrapBuilder.setJaws(model, 0), "setJaws finds every leaf")
			expectPose("JawA", CFrame.new(), "snapped = rest")
			expectPose("JawB", CFrame.new(), "snapped = rest")
			expectPose("SpringA", CFrame.new(), "released = rest")
			BearTrapBuilder.setJaws(model, 0.25)
			expectPose("JawA", CFrame.Angles(open * 0.25, 0, 0), "quarter open")
			expectPose("JawB", CFrame.Angles(-open * 0.25, 0, 0), "quarter open")
			expectPose("SpringB", CFrame.Angles(0, 0, -travel * 0.25), "quarter pressed")
			BearTrapBuilder.setJaws(model, 3)
			expectPose("JawA", CFrame.Angles(open, 0, 0), "openness clamps to 1")
			BearTrapBuilder.setJaws(model, math.sqrt(-1))
			expectPose("JawB", CFrame.new(), "NaN openness reads as the rest pose")
			BearTrapBuilder.setJaws(model, 0)
			BearTrapBuilder.setJaws(model, 1)
			local drift = snapshotDrift(snapshot(model), armed)
			-- CFrames are float32 (in the engine and in Lune): each re-pose tens of studs from the origin rounds a
			-- few ulps, far below anything visible.
			t.truthy(drift < POSE_DRIFT, string.format("re-arming restores the built geometry (drift %.2e)", drift))

			local frame = model.WorldPivot
			local plate = leafPart(model, "Pan", "Plate")
			local levelY = frame:PointToObjectSpace(plate.CFrame.Position).Y
			t.truthy(BearTrapBuilder.setPan(model, 1), "setPan finds the pan")
			expectPose("Pan", CFrame.Angles(-BearTrapBuilder.PanTilt, 0, 0), "fully depressed")
			t.truthy(frame:PointToObjectSpace(plate.CFrame.Position).Y < levelY - 0.02, "a depressed pan sinks")
			t.truthy(lowest({ plate }, frame) > 0, "a depressed pan stays above the floor")
			BearTrapBuilder.setPan(model, 0.5)
			expectPose("Pan", CFrame.Angles(-BearTrapBuilder.PanTilt * 0.5, 0, 0), "half depressed")
			BearTrapBuilder.setPan(model, 0)
			t.truthy(sameSnapshot(snapshot(model), armed, POSE_DRIFT), "a released pan returns to level")

			local bare = Instance.new("Model")
			t.falsy(BearTrapBuilder.setJaws(bare, 1), "setJaws reports a model without jaws")
			t.falsy(BearTrapBuilder.setPan(bare, 1), "setPan reports a model without a pan")
			discard(model)
		end)
	end,

	["BearTrap: armed jaws lie flat, snapped jaws stand up interlocked"] = function(t: Expect)
		quiet(function()
			local model = build(trapPlan(1, 5), 3)
			local frame = model.WorldPivot
			local jawA = leafParts(model, "JawA")
			local jawB = leafParts(model, "JawB")
			t.eq(#jawA, #jawB, "both jaws have the same parts")

			-- Armed: flat on the frame, A toward +Z and B toward -Z, teeth up.
			t.truthy(highest(jawA, frame) < 0.5, string.format("armed JawA flat (%.2f)", highest(jawA, frame)))
			t.truthy(highest(jawB, frame) < 0.5, string.format("armed JawB flat (%.2f)", highest(jawB, frame)))
			t.truthy(lowest(jawA, frame) > -REST_EPSILON and lowest(jawB, frame) > -REST_EPSILON, "jaws above floor")
			for _, part in jawA do
				t.truthy(
					frame:PointToObjectSpace(part.CFrame.Position).Z > 0,
					"armed JawA lies toward +Z: " .. part.Name
				)
			end
			for _, part in jawB do
				t.truthy(
					frame:PointToObjectSpace(part.CFrame.Position).Z < 0,
					"armed JawB lies toward -Z: " .. part.Name
				)
			end
			local spread = horizontalReach(jawA, frame)
			t.truthy(spread > 0.85 and spread < 1.2, string.format("open jaws ~2 studs across (%.2f)", spread))
			local plate = leafPart(model, "Pan", "Plate")
			t.truthy(highest({ plate }, frame) < highest(jawA, frame), "the pan sits inside the open jaws' height")

			-- Snapped: standing up in the centre plane, teeth crossing it but never touching each other.
			local eyeArmed = leafPart(model, "SpringA", "Eye").CFrame.Position
			BearTrapBuilder.setJaws(model, 0)
			t.truthy(highest(jawA, frame) > 0.9, string.format("snapped JawA stands (%.2f)", highest(jawA, frame)))
			t.truthy(highest(jawB, frame) > 0.9, string.format("snapped JawB stands (%.2f)", highest(jawB, frame)))
			for _, part in jawA do
				local p = frame:PointToObjectSpace(part.CFrame.Position)
				t.truthy(math.abs(p.Z) < 0.25, "snapped JawA in the centre plane: " .. part.Name)
			end
			local eyeSnapped = leafPart(model, "SpringA", "Eye").CFrame.Position
			t.truthy(
				frame:PointToObjectSpace(eyeSnapped).Y > frame:PointToObjectSpace(eyeArmed).Y + 0.05,
				"a released spring rises"
			)
			local function teeth(list: { BasePart }): { BasePart }
				local out: { BasePart } = {}
				for _, part in list do
					if string.sub(part.Name, 1, 5) == "Tooth" then
						table.insert(out, part)
					end
				end
				return out
			end
			local teethA, teethB = teeth(jawA), teeth(jawB)
			t.truthy(#teethA >= 3 and #teethB >= 3, "serrated jaws")
			for _, a in teethA do
				local pa = frame:PointToObjectSpace(a.CFrame.Position)
				local tipA = frame:PointToObjectSpace(a.CFrame * Vector3.new(0, a.Size.Y / 2, 0))
				t.truthy(tipA.Z < 0, "JawA tooth reaches past the centre plane: " .. a.Name)
				for _, b in teethB do
					local pb = frame:PointToObjectSpace(b.CFrame.Position)
					local gap = Vector3.new(pa.X - pb.X, pa.Y - pb.Y, 0).Magnitude
					t.truthy(gap >= (a.Size.Z + b.Size.Z) / 2 - 1e-6, "interlocked teeth never collide")
				end
			end
			for _, b in teethB do
				local tipB = frame:PointToObjectSpace(b.CFrame * Vector3.new(0, b.Size.Y / 2, 0))
				t.truthy(tipB.Z > 0, "JawB tooth reaches past the centre plane: " .. b.Name)
			end
			discard(model)
		end)
	end,

	["BearTrap: TriggerVolume is a NoCollide volume around LegPoint and the jaws"] = function(t: Expect)
		quiet(function()
			local plan = trapPlan(3, 12)
			local model = build(plan, 12)
			local volume = model:FindFirstChild("TriggerVolume")
			assert(volume and volume:IsA("BasePart"), "TriggerVolume")
			t.eq(volume.Transparency, 1, "invisible")
			t.eq(volume.CollisionGroup, CollisionGroups.NoCollide, "NoCollide group")
			t.falsy(volume.CanCollide or volume.CanQuery or volume.CanTouch, "math-tested only")
			t.near(volume.Size.X, 2.2, 1e-5, "volume width")
			t.near(volume.Size.Z, 2.2, 1e-5, "volume depth")
			local bottom, top = extentY(volume, plan.cframe)
			t.truthy(bottom < -0.25 and bottom > -1, string.format("volume reaches below the floor (%.2f)", bottom))
			t.truthy(top > 3.25 and top < 4, string.format("volume reaches above a standing root (%.2f)", top))
			local frame = model.WorldPivot
			t.truthy(contains(volume, frame.Position), "a walker's feet point on the trap is inside")
			t.truthy(
				contains(volume, (frame * CFrame.new(0, 3, 0)).Position),
				"a standing root over the trap is inside"
			)
			t.falsy(contains(volume, (frame * CFrame.new(1.6, 3, 0)).Position), "a root beside the trap is outside")

			local leg = attachmentWorld(model, "LegPoint").Position
			t.truthy(contains(volume, leg), "LegPoint inside the TriggerVolume")
			local legLocal = frame:PointToObjectSpace(leg)
			t.near(legLocal.Y, 0.3, 0.05, "LegPoint ~0.3 above the floor")
			t.near(Vector3.new(legLocal.X, 0, legLocal.Z).Magnitude, 0, 1e-4, "LegPoint over the pan centre")
			t.truthy(contains(volume, leafPart(model, "Pan", "Plate").CFrame.Position), "pan inside the volume")
			for _, leaf in { "JawA", "JawB" } do
				for _, part in leafParts(model, leaf) do
					t.truthy(
						contains(volume, part.CFrame.Position),
						"armed jaw inside the volume: " .. leaf .. part.Name
					)
				end
			end
			discard(model)
		end)
	end,

	["ChemicalFlask: identity, Pickup prompt, glass and Neon liquid, no lights"] = function(t: Expect)
		quiet(function()
			for index = 1, #POINTS do
				local variant = 400 + index
				local plan = flaskPlan(index, variant)
				local model = build(plan, index)
				expectIdentity(t, model, plan, Tags.ChemicalItem)
				expectPrompt(t, model, "Pickup", "Prompt.Pickup", "Prompt.Flask", ChemicalFlaskBuilder.PickupHold)
				t.near(ChemicalFlaskBuilder.PickupHold, 0.35, 0.1, "a quick grab")

				local bulb = model:FindFirstChild("Bulb")
				assert(bulb and bulb:IsA("BasePart"), "Bulb")
				t.eq(bulb.Material, Enum.Material.Glass, "glass bulb")
				t.truthy(bulb.Transparency > 0.2 and bulb.Transparency < 0.9, "partly transparent glass")
				local liquid = 0
				for _, part in parts(model) do
					if part.Material == Enum.Material.Neon then
						liquid += 1
						t.eq(part.Color, ChemicalFlaskBuilder.liquidColor(variant), "liquid colour from the variant")
						t.truthy(string.sub(part.Name, 1, 6) == "Liquid", "only the liquid glows: " .. part.Name)
					end
				end
				t.truthy(liquid >= 1, "glowing liquid")

				local label = model:FindFirstChildWhichIsA("TextLabel", true)
				assert(label, "hazard label")
				t.eq(label.Text, Strings.get("Prop.Lab.Hazard"), "hazard text from Strings")
				local gui = label:FindFirstAncestorWhichIsA("SurfaceGui")
				t.truthy(gui ~= nil and gui.Parent ~= nil and gui.Parent:IsA("BasePart"), "printed on a part")
				discard(model)
			end
		end)
	end,

	["ChemicalFlask: budget, inert details, resting on the plan point"] = function(t: Expect)
		quiet(function()
			for variant = 1, 24 do
				local index = variant % #POINTS + 1
				local plan = flaskPlan(index, variant * 7919)
				local model = build(plan, variant)
				local count = #parts(model)
				t.truthy(count <= FLASK_BUDGET, string.format("flask budget (%d parts)", count))
				expectInert(t, model, "flask")
				local list = parts(model)
				t.near(lowest(list, plan.cframe), 0, REST_EPSILON, "flask bottom on the plan point")
				local reach = horizontalReach(list, plan.cframe)
				t.truthy(reach < 0.6, string.format("flask footprint (%.2f)", reach))
				local top = highest(list, plan.cframe)
				t.truthy(top > 0.8 and top < 1.4, string.format("flask height (%.2f)", top))
				-- GripOffset is straight up the neck, so the prop's random yaw never moves the Grip off it.
				local grip = plan.cframe:PointToObjectSpace(attachmentWorld(model, "Grip").Position)
				t.near(grip.Y, ChemicalFlaskBuilder.GripOffset.Y, 1e-4, "Grip height")
				t.near(Vector3.new(grip.X, 0, grip.Z).Magnitude, 0, 1e-4, "Grip on the neck axis")
				discard(model)
			end
		end)
	end,

	["ChemicalFlask: buildVisual is cosmetic, unprompted and gripped; rig ChemicalFlask"] = function(t: Expect)
		quiet(function()
			local folder = Instance.new("Folder")
			local cframe = POINTS[1]
			local visual = ChemicalFlaskBuilder.buildVisual(folder, cframe, 402)
			t.eq(visual.Parent, folder, "parented")
			local primary = visual.PrimaryPart
			assert(primary, "visual PrimaryPart")
			t.eq(primary.Name, "Base")
			for _, part in parts(visual) do
				t.truthy(part.Anchored, "anchored " .. part.Name)
				t.falsy(part.CanCollide or part.CanQuery or part.CanTouch or part.CastShadow, "cosmetic " .. part.Name)
				t.eq(part.CollisionGroup, CollisionGroups.NoCollide, "NoCollide " .. part.Name)
				t.eq(#part:GetTags(), 0, "untagged " .. part.Name)
			end
			t.eq(#visual:GetTags(), 0, "visual untagged")
			t.eq(next(visual:GetAttributes()), nil, "visual has no attributes")
			t.eq(visual:FindFirstChildWhichIsA("ProximityPrompt", true), nil, "visual has no prompt")
			local grip = attachmentWorld(visual, "Grip")
			t.truthy(cframeNear(grip, cframe * ChemicalFlaskBuilder.GripOffset, 1e-5), "Grip at GripOffset")
			t.near(lowest(parts(visual), cframe), 0, REST_EPSILON, "visual rests on its cframe")

			-- The same variant's world prop and visual are the same flask.
			local prop = build(flaskPlan(1, 402), 99)
			local function shape(root: Instance): { [string]: Vector3 }
				local out: { [string]: Vector3 } = {}
				for _, part in parts(root) do
					out[part.Name] = part.Size
				end
				return out
			end
			local propShape, visualShape = shape(prop), shape(visual)
			for name, size in propShape do
				t.truthy((visualShape[name] :: Vector3?) == size, "visual matches the prop: " .. name)
			end
			for name in visualShape do
				t.truthy((propShape[name] :: Vector3?) ~= nil, "visual has nothing extra: " .. name)
			end

			t.truthy(Builder.HasRig("ChemicalFlask"), "rig registered")
			local rig = Builder.BuildRig("ChemicalFlask", folder, POINTS[2])
			assert(rig, "rig built")
			t.eq(rig.Parent, folder, "rig parented")
			t.truthy(PropKit.findAttachment(rig, "Grip") ~= nil, "rig has a Grip")
			for _, part in parts(rig) do
				t.eq(part.CollisionGroup, CollisionGroups.NoCollide, "rig part cosmetic " .. part.Name)
				if part.Material == Enum.Material.Neon then
					t.eq(part.Color, ChemicalFlaskBuilder.liquidColor(0), "rig is variant 0")
				end
			end
			discard(prop)
			folder:Destroy()
		end)
	end,

	["ChemicalFlask: liquidColor is pure and covers green, yellow and violet"] = function(t: Expect)
		local seen: { [string]: boolean } = {}
		local distinct = 0
		for variant = 0, 11 do
			local color = ChemicalFlaskBuilder.liquidColor(variant)
			t.eq(color, ChemicalFlaskBuilder.liquidColor(variant), "same variant, same colour")
			t.eq(color, ChemicalFlaskBuilder.liquidColor(variant + 3), "three-colour cycle")
			local key = string.format("%.4f,%.4f,%.4f", color.R, color.G, color.B)
			if not seen[key] then
				seen[key] = true
				distinct += 1
			end
		end
		t.eq(distinct, 3, "three liquids")
		t.eq(typeof(ChemicalFlaskBuilder.liquidColor(-4)), "Color3", "negative variants are valid")
		t.eq(
			ChemicalFlaskBuilder.liquidColor(math.sqrt(-1)),
			ChemicalFlaskBuilder.liquidColor(0),
			"NaN falls back to 0"
		)
	end,

	["Battery: identity, Charge, Pickup prompt, budget, indicator and resting over many seeds"] = function(t: Expect)
		quiet(function()
			local knocked, upright = 0, 0
			for seed = 1, 40 do
				local index = seed % #POINTS + 1
				local plan = batteryPlan(index, seed * 31)
				local model = build(plan, seed)
				expectIdentity(t, model, plan, Tags.BatteryPickup)
				t.eq(model:GetAttribute(W.Charge), GameConfig.BatteryPickupCharge, "Charge")
				expectPrompt(t, model, "Pickup", "Prompt.Pickup", "Prompt.Battery", PickupBuilder.PickupHold)
				t.near(PickupBuilder.PickupHold, 0.25, 0.1, "a quick grab")
				local list = parts(model)
				t.truthy(#list <= BATTERY_BUDGET, string.format("battery budget (%d parts)", #list))
				expectInert(t, model, "battery")
				t.near(lowest(list, plan.cframe), 0, REST_EPSILON, "battery rests on the plan point")
				t.truthy(horizontalReach(list, plan.cframe) < 1, "battery stays on its anchor")
				local glow = 0
				for _, part in list do
					if part.Material == Enum.Material.Neon then
						glow += 1
						t.truthy(part.Size.Magnitude < 0.2, "a tiny charge indicator")
					end
				end
				t.eq(glow, 1, "one Neon charge indicator")
				local base = model.PrimaryPart
				assert(base, "Base")
				local up = plan.cframe:VectorToObjectSpace(base.CFrame.UpVector).Y
				if up < 0.5 then
					knocked += 1
				else
					upright += 1
					t.truthy(up > math.cos(math.rad(5)), "an upright battery leans only slightly")
				end
				discard(model)
			end
			t.truthy(knocked > 0 and upright > 0, string.format("%d knocked over, %d upright", knocked, upright))
		end)
	end,

	["determinism: same seed, same geometry; another seed moves it"] = function(t: Expect)
		quiet(function()
			for _, makePlan in { trapPlan, flaskPlan, batteryPlan } do
				local plan = makePlan(2, 4242)
				local a = build(plan, 17)
				local b = build(plan, 17)
				local c = build(plan, 18)
				t.truthy(sameSnapshot(snapshot(a), snapshot(b), 0), plan.kind .. ": same seed, identical CFrames")
				t.falsy(sameSnapshot(snapshot(a), snapshot(c), 1e-6), plan.kind .. ": another seed differs")
				for _, model in { a, b, c } do
					discard(model)
				end
			end
		end)
	end,

	["real layouts: every candidate anchor builds and rests on its point"] = function(t: Expect)
		quiet(function()
			local cases: { { layout: Enums.LayoutId, anchor: Enums.AnchorKind, kind: string } } = {
				{ layout = BASEMENT, anchor = "TrapCandidate", kind = "BearTrap" },
				{ layout = SCIENCE, anchor = "FlaskCandidate", kind = "ChemicalFlask" },
				{ layout = POOL, anchor = "FlaskCandidate", kind = "ChemicalFlask" },
			}
			for _, id: Enums.LevelId in Enums.LevelId do
				table.insert(cases, { layout = id, anchor = "BatteryCandidate", kind = "Battery" })
			end
			local built = 0
			for _, case in cases do
				for i, anchor in anchorsOf(case.layout, case.anchor) do
					local plan = planned(case.kind, anchor.id, case.layout, anchor.cframe, i * 977)
					local model = build(plan, i)
					t.near(
						lowest(visibleParts(model), anchor.cframe),
						0,
						REST_EPSILON,
						case.kind .. " rests on " .. anchor.id
					)
					built += 1
					discard(model)
				end
			end
			if Builder.getLayout(BASEMENT) then
				t.truthy(built > 60, string.format("built every candidate (%d)", built))
			end
		end)
	end,

	["real layouts: Science Hall flasks stand inside their lab worktops"] = function(t: Expect)
		quiet(function()
			local counters = anchorsOf(SCIENCE, "LabCounter")
			local flasks = anchorsOf(SCIENCE, "FlaskCandidate")
			if #flasks == 0 then
				return -- layout not present
			end
			for i, anchor in flasks do
				local model = build(planned("ChemicalFlask", anchor.id, SCIENCE, anchor.cframe, i), i)
				local list = parts(model)
				local best: CFrame? = nil
				for _, counter in counters do
					local offset = counter.cframe:PointToObjectSpace(anchor.cframe.Position)
					if math.abs(offset.X) <= 5 and math.abs(offset.Z) <= 1.75 then
						best = counter.cframe
					end
				end
				assert(best, anchor.id .. " stands over a LabCounter")
				local worktop = best
				for _, part in list do
					local half = part.Size / 2
					for _, sx in { -1, 1 } do
						for _, sz in { -1, 1 } do
							local corner =
								worktop:PointToObjectSpace(part.CFrame * Vector3.new(sx * half.X, 0, sz * half.Z))
							t.truthy(
								math.abs(corner.X) <= 5 and math.abs(corner.Z) <= 1.75,
								anchor.id .. " " .. part.Name .. " over the 10 x 3.5 worktop"
							)
						end
					end
				end
				discard(model)
			end
		end)
	end,
}
