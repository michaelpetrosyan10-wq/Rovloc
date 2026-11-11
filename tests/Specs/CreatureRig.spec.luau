--!strict
-- CreatureRigBuilder contracts on a Creature built at a raised, turned spawn point: its size against
-- CreatureConfig.Rig (11 tall, feet on the floor, eyes EyeHeightAboveRoot.Biped above the root, hands hanging below
-- the knees on long tapering clawless fingers, arm reach), the ivory porcelain mask (upper half on the Head, the
-- chin on the hinged Jaw, the sculpt's and the painted detail's attributes, the relief, cracks, streaks, chip, shards
-- and grime Roblox draws, nothing white inside the open split), the near-black shadow body, the smoke anchors and the
-- shroud, the exported Metrics, the R15 + Jaw + finger + tatter joint tree (every Motor6D consistent with its parts at
-- rest, joint frames aligned with the facing, everything hanging off the root, details welded to their limb), the
-- physics presets (only
-- the root has mass and collides; limbs NoCollide; the CreatureHitbox queryable and resized per PoseMode by
-- setHitbox), the Humanoid settings, the PoseMode attribute, the part budget and deterministic output.
-- The Lune harness has no joint solver: rest-pose consistency is checked as Part1 == Part0 * C0 * C1^-1.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Types = require(ReplicatedStorage.Shared.Types)

local CreatureRigBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.CreatureRigBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

type Built = {
	folder: Folder,
	model: Model,
	root: BasePart,
	hitbox: BasePart,
}

local RIG = CreatureConfig.Rig
local NAMES = CreatureRigBuilder.PartNames
local ROOT_HEIGHT = RIG.HipHeight + RIG.RootSize.Y / 2

-- The CreatureSpawn floor point: off the origin, raised and turned, so nothing passes by being axis-aligned.
local BASE = CFrame.new(37.5, 12.25, -81) * CFrame.Angles(0, math.rad(131), 0)
local UP = BASE.UpVector
local FLOOR = BASE.Position:Dot(UP)

local POSITION_EPS = 2e-3
local AXIS_EPS = 1e-4
local SIZE_EPS = 1e-4 -- sizes are stored at single precision
local SHELL_SLACK = 3e-3 -- a mask strip's end off its half's shell: its lift (at most 1.5e-3) and float rounding
local SIGNS: { number } = { -1, 1 }

local R15_JOINTS: { { string } } = {
	{ "Root", "HumanoidRootPart", "LowerTorso" },
	{ "Waist", "LowerTorso", "UpperTorso" },
	{ "Neck", "UpperTorso", "Head" },
	{ "LeftShoulder", "UpperTorso", "LeftUpperArm" },
	{ "LeftElbow", "LeftUpperArm", "LeftLowerArm" },
	{ "LeftWrist", "LeftLowerArm", "LeftHand" },
	{ "RightShoulder", "UpperTorso", "RightUpperArm" },
	{ "RightElbow", "RightUpperArm", "RightLowerArm" },
	{ "RightWrist", "RightLowerArm", "RightHand" },
	{ "LeftHip", "LowerTorso", "LeftUpperLeg" },
	{ "LeftKnee", "LeftUpperLeg", "LeftLowerLeg" },
	{ "LeftAnkle", "LeftLowerLeg", "LeftFoot" },
	{ "RightHip", "LowerTorso", "RightUpperLeg" },
	{ "RightKnee", "RightUpperLeg", "RightLowerLeg" },
	{ "RightAnkle", "RightLowerLeg", "RightFoot" },
	{ "Jaw", "Head", "Jaw" },
}

local FORBIDDEN_CLASSES: { string } = {
	"MeshPart",
	"UnionOperation",
	"SpecialMesh",
	"FileMesh",
	"Decal",
	"Texture",
	"SurfaceAppearance",
	"Script",
	"LocalScript",
	"ModuleScript",
	"Animator",
	"Light",
}

-- Unit-cube corners of a WedgePart: the full-height face at +Z, the slope falling to the bottom edge at -Z.
local WEDGE_VERTICES: { Vector3 } = {
	Vector3.new(-0.5, -0.5, -0.5),
	Vector3.new(0.5, -0.5, -0.5),
	Vector3.new(-0.5, -0.5, 0.5),
	Vector3.new(0.5, -0.5, 0.5),
	Vector3.new(-0.5, 0.5, 0.5),
	Vector3.new(0.5, 0.5, 0.5),
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function build(cframe: CFrame): Built
	local previous = Geometry.getYieldEvery()
	Geometry.setYieldEvery(0)
	local folder = Instance.new("Folder")
	folder.Name = "CreatureRigSpec"
	local model = CreatureRigBuilder.build(folder, cframe)
	Geometry.setYieldEvery(previous)
	local root = model:FindFirstChild(NAMES.Root)
	local hitbox = model:FindFirstChild(NAMES.Hitbox)
	if root and root:IsA("BasePart") and hitbox and hitbox:IsA("BasePart") then
		return { folder = folder, model = model, root = root, hitbox = hitbox }
	end
	error("the Creature has no HumanoidRootPart or CreatureHitbox")
end

-- One rest-pose build shared by the read-only tests (tests that mutate the rig build their own).
local cached: Built? = nil
local function rest(): Built
	local existing = cached
	if existing then
		return existing
	end
	local built = build(BASE)
	cached = built
	return built
end

local function findPart(model: Model, name: string): BasePart
	local found = model:FindFirstChild(name, true)
	if found and found:IsA("BasePart") then
		return found
	end
	error("the Creature has no part " .. name)
end

local function baseParts(root: Instance): { BasePart }
	local list: { BasePart } = {}
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(list, descendant)
		end
	end
	return list
end

local function motors(model: Model): { Motor6D }
	local list: { Motor6D } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Motor6D") then
			table.insert(list, descendant)
		end
	end
	return list
end

-- The furthest any point of `part` reaches along the unit vector `axis` (exact for blocks, balls, cylinders and
-- wedges; the bounding box for anything else).
local function reach(part: BasePart, axis: Vector3): number
	local cframe = part.CFrame
	local size = part.Size
	local centre = cframe.Position:Dot(axis)
	local x = cframe.RightVector:Dot(axis)
	local y = cframe.UpVector:Dot(axis)
	local z = cframe.LookVector:Dot(axis)
	if part:IsA("Part") then
		if part.Shape == Enum.PartType.Ball then
			return centre + math.min(size.X, size.Y, size.Z) / 2
		elseif part.Shape == Enum.PartType.Cylinder then
			local along = math.abs(x)
			local radius = math.min(size.Y, size.Z) / 2
			return centre + along * size.X / 2 + radius * math.sqrt(math.max(0, 1 - along * along))
		end
	elseif part:IsA("WedgePart") then
		local best = -math.huge
		for _, vertex in WEDGE_VERTICES do
			best = math.max(best, (cframe * (vertex * size)):Dot(axis))
		end
		return best
	end
	return centre + math.abs(x) * size.X / 2 + math.abs(y) * size.Y / 2 + math.abs(z) * size.Z / 2
end

-- Highest and lowest points of the visible body above the floor.
local function verticalSpan(model: Model): (number, number)
	local top, bottom = -math.huge, math.huge
	for _, part in baseParts(model) do
		if part.Transparency < 1 then
			top = math.max(top, reach(part, UP))
			bottom = math.min(bottom, -reach(part, -UP))
		end
	end
	return top - FLOOR, bottom - FLOOR
end

local function sameFrame(t: Expect, actual: CFrame, expected: CFrame, label: string)
	t.near((actual.Position - expected.Position).Magnitude, 0, POSITION_EPS, label .. " position")
	t.near(actual.RightVector:Dot(expected.RightVector), 1, AXIS_EPS, label .. " right axis")
	t.near(actual.UpVector:Dot(expected.UpVector), 1, AXIS_EPS, label .. " up axis")
end

local function sameAxes(t: Expect, actual: CFrame, expected: CFrame, label: string)
	t.near(actual.RightVector:Dot(expected.RightVector), 1, AXIS_EPS, label .. " right axis")
	t.near(actual.UpVector:Dot(expected.UpVector), 1, AXIS_EPS, label .. " up axis")
end

local function sameVector(t: Expect, actual: Vector3, expected: Vector3, epsilon: number, label: string)
	t.near((actual - expected).Magnitude, 0, epsilon, label)
end

local function hitboxJoint(built: Built): JointInstance
	local joint = built.hitbox:FindFirstChild(NAMES.HitboxJoint)
	if joint and joint:IsA("JointInstance") and (joint.ClassName == "Weld" or joint.ClassName == "Motor6D") then
		return joint
	end
	error("CreatureHitbox has no HitboxJoint Weld or Motor6D")
end

-- The hitbox part must sit where its joint puts it, axis-aligned with the root.
local function checkHitboxSeat(t: Expect, built: Built, label: string)
	local joint = hitboxJoint(built)
	t.eq(joint.Part0, built.root, label .. ": HitboxJoint.Part0")
	t.eq(joint.Part1, built.hitbox, label .. ": HitboxJoint.Part1")
	sameFrame(t, built.hitbox.CFrame, built.root.CFrame * joint.C0 * joint.C1:Inverse(), label .. ": hitbox seat")
	sameAxes(t, built.hitbox.CFrame, built.root.CFrame, label .. ": hitbox axes")
end

local function insideHitbox(built: Built, point: Vector3): boolean
	local localPoint = built.hitbox.CFrame:PointToObjectSpace(point)
	local half = built.hitbox.Size / 2 + Vector3.one * 1e-3
	return math.abs(localPoint.X) <= half.X and math.abs(localPoint.Y) <= half.Y and math.abs(localPoint.Z) <= half.Z
end

local function sortedPoseModes(): { string }
	local modes: { string } = {}
	for mode in CreatureConfig.Hitbox do
		table.insert(modes, mode)
	end
	table.sort(modes)
	return modes
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["model: a Creature rooted on HumanoidRootPart, PoseMode Biped, untagged"] = function(t: Expect)
		local built = rest()
		local model = built.model
		t.eq(model.Name, "Creature")
		t.eq(model.Parent, built.folder, "parented to the requested parent")
		t.eq(model.PrimaryPart, built.root, "PrimaryPart")
		t.eq(built.root.Parent, model, "HumanoidRootPart is a direct child")
		t.eq(model:GetAttribute(Attributes.Creature.PoseMode), "Biped")
		t.eq(#model:GetTags(), 0, "WorldService tags the Creature, the builder does not")
		sameAxes(t, built.root.CFrame, BASE, "root faces the spawn's LookVector")
		t.near(built.root.CFrame.Position:Dot(UP) - FLOOR, ROOT_HEIGHT, POSITION_EPS, "root centre height")
		local offset = built.root.CFrame.Position - BASE.Position
		t.near((offset - UP * offset:Dot(UP)).Magnitude, 0, POSITION_EPS, "root right above the spawn point")
	end,

	["humanoid: R15, explicit HipHeight, no scaling, neck, joint breaking, labels or Animator"] = function(t: Expect)
		local model = rest().model
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			t.fail("the Creature has no Humanoid")
			return
		end
		t.eq(humanoid.Name, NAMES.Humanoid)
		t.eq(humanoid.Parent, model)
		t.eq(humanoid.RigType, Enum.HumanoidRigType.R15)
		t.near(humanoid.HipHeight, RIG.HipHeight, 1e-6, "HipHeight")
		t.falsy(humanoid.AutomaticScalingEnabled, "AutomaticScalingEnabled")
		t.falsy(humanoid.RequiresNeck, "RequiresNeck")
		t.falsy(humanoid.BreakJointsOnDeath, "BreakJointsOnDeath")
		t.eq(humanoid.DisplayDistanceType, Enum.HumanoidDisplayDistanceType.None)
		t.eq(humanoid.HealthDisplayType, Enum.HumanoidHealthDisplayType.AlwaysOff)
		t.eq(humanoid.NameDisplayDistance, 0)
		for _, descendant in model:GetDescendants() do
			for _, className in FORBIDDEN_CLASSES do
				t.falsy(descendant:IsA(className), descendant:GetFullName() .. " is a " .. className)
			end
		end
	end,

	["size: 11 studs to the crown, soles and toes on the floor, hands below the knees"] = function(t: Expect)
		local model = rest().model
		local top, bottom = verticalSpan(model)
		t.near(top, RIG.Height, 0.05, "top of the head above the floor")
		t.near(bottom, 0, 0.02, "lowest point of the body (nothing sinks into the floor)")
		for _, name in { NAMES.LeftFoot, NAMES.RightFoot } do
			local foot = findPart(model, name)
			t.near(-reach(foot, -UP) - FLOOR, 0, 0.01, name .. " sole on the floor")
		end
		-- the crown of the skull is the top: nothing pokes out above it
		t.near(reach(findPart(model, NAMES.Crown), UP) - FLOOR, top, 0.01, "the crown is the highest point")
		t.truthy(RIG.HunchedHeight < RIG.Height, "hunched is shorter than standing")
		-- the arms hang so long that the fingertips are below the knees
		for _, side in { "Left", "Right" } do
			local knee = model:FindFirstChild(side .. "Knee", true)
			local kneePart0 = if knee and knee:IsA("Motor6D") then knee.Part0 else nil
			if not (knee and knee:IsA("Motor6D") and kneePart0) then
				t.fail("no " .. side .. "Knee")
				continue
			end
			local kneeHeight = (kneePart0.CFrame * knee.C0).Position:Dot(UP) - FLOOR
			local lowest = math.huge
			for _, finger in NAMES.Fingers[side] do
				local part = findPart(model, finger)
				lowest = math.min(lowest, -reach(part, -UP) - FLOOR)
				for _, piece in baseParts(part) do
					lowest = math.min(lowest, -reach(piece, -UP) - FLOOR)
				end
			end
			t.truthy(
				lowest < kneeHeight - 0.3,
				string.format("%s fingertips %.2f below the knee %.2f", side, lowest, kneeHeight)
			)
		end
	end,

	["eyes: pinprick pupils EyeHeightAboveRoot.Biped above the root, on the mask at the eye holes"] = function(
		t: Expect
	)
		local built = rest()
		local model = built.model
		local left = findPart(model, NAMES.LeftPupil)
		local right = findPart(model, NAMES.RightPupil)
		local eyes = (left.CFrame.Position + right.CFrame.Position) / 2
		local fromRoot = eyes - built.root.CFrame.Position
		t.near(fromRoot:Dot(UP), CreatureConfig.EyeHeightAboveRoot.Biped, 0.01, "eye height above the root centre")
		local ahead = fromRoot:Dot(BASE.LookVector)
		t.truthy(ahead >= 0 and ahead <= 1.7, "the face juts ahead of the root on the neck: " .. ahead)
		t.near(fromRoot:Dot(BASE.RightVector), 0, POSITION_EPS, "eyes centred on the body")
		t.truthy(left.CFrame.Position:Dot(BASE.RightVector) < right.CFrame.Position:Dot(BASE.RightVector), "sides")

		local face = model:FindFirstChild(NAMES.FaceAttachment, true)
		if not (face and face:IsA("Attachment")) then
			t.fail("no " .. NAMES.FaceAttachment)
			return
		end
		local head = findPart(model, NAMES.Head)
		t.eq(face.Parent, head, "the face attachment rides the Head")
		local faceFrame = head.CFrame * face.CFrame
		sameVector(t, faceFrame.Position, eyes, POSITION_EPS, "face attachment at the pupils' midpoint")
		t.truthy(faceFrame.LookVector:Dot(BASE.LookVector) > 0.95, "the face attachment looks where the Creature faces")

		-- the eye holes are painted on the mask around the pupils (the Mask part's attributes, in the face frame)
		local mask = findPart(model, NAMES.Mask)
		local eyeX = mask:GetAttribute("EyeX")
		if type(eyeX) ~= "number" then
			t.fail("Mask carries no EyeX")
			return
		end
		for _, pupil in { left, right } do
			t.eq(pupil.Material, Enum.Material.Neon, pupil.Name .. " material")
			t.eq(pupil.Color, RIG.PupilColor, pupil.Name .. " colour")
			t.truthy(pupil.Size.X <= 0.06, pupil.Name .. " is a pinprick")
			t.eq(pupil.Parent, head, pupil.Name .. " rides the Head")
			local inFace = faceFrame:PointToObjectSpace(pupil.CFrame.Position)
			t.near(math.abs(inFace.X), eyeX, POSITION_EPS, pupil.Name .. " at its eye hole's centre")
			-- it sits on the porcelain surface of the upper mask's cylinder
			local onAxis = mask.CFrame:PointToObjectSpace(pupil.CFrame.Position)
			local radial = math.sqrt(onAxis.Y ^ 2 + onAxis.Z ^ 2)
			t.near(radial, mask.Size.Y / 2, 0.01, pupil.Name .. " on the mask's surface")
		end
	end,

	["joints: every Motor6D is consistent with its parts at rest and framed on the facing"] = function(t: Expect)
		local model = rest().model
		local list = motors(model)
		t.truthy(#list > 0, "the rig has joints")
		for _, motor in list do
			local part0, part1 = motor.Part0, motor.Part1
			if not (part0 and part1) then
				t.fail(motor.Name .. " is missing Part0 or Part1")
				continue
			end
			t.truthy(part0:IsDescendantOf(model) and part1:IsDescendantOf(model), motor.Name .. " parts in the model")
			t.eq(motor.Parent, part1, motor.Name .. " lives in its Part1")
			sameFrame(t, part1.CFrame, part0.CFrame * motor.C0 * motor.C1:Inverse(), motor.Name .. " rest pose")
			-- a Transform means the same thing on every joint: pitch about the Creature's X, yaw about its Y
			sameAxes(t, part0.CFrame * motor.C0, BASE, motor.Name .. " joint frame")
		end
	end,

	["joints: names, parts and order follow CreatureRigBuilder.Joints"] = function(t: Expect)
		local model = rest().model
		local joints = CreatureRigBuilder.Joints
		t.truthy(table.isfrozen(joints), "Joints is frozen")
		local byName: { [string]: Motor6D } = {}
		for _, motor in motors(model) do
			t.falsy(byName[motor.Name], "one Motor6D named " .. motor.Name)
			byName[motor.Name] = motor
		end
		local listed: { [string]: boolean } = {}
		local placed: { [string]: boolean } = { [NAMES.Root] = true }
		for _, spec in joints do
			t.truthy(table.isfrozen(spec), spec.name .. " entry is frozen")
			t.falsy(listed[spec.name], spec.name .. " is listed once")
			listed[spec.name] = true
			-- parent before child: walking the list in order composes every frame from the root outward
			t.truthy(placed[spec.part0], spec.name .. ": " .. spec.part0 .. " is placed before it")
			placed[spec.part1] = true
			local motor = byName[spec.name]
			if not motor then
				t.fail("no Motor6D " .. spec.name)
				continue
			end
			local part0, part1 = motor.Part0, motor.Part1
			t.eq(part0 and part0.Name, spec.part0, spec.name .. " Part0")
			t.eq(part1 and part1.Name, spec.part1, spec.name .. " Part1")
		end
		for name in byName do
			t.truthy(listed[name], "Motor6D " .. name .. " is listed in Joints")
		end
		for _, entry in R15_JOINTS do
			local motor = byName[entry[1]]
			t.truthy(motor, "R15 joint " .. entry[1])
			if motor then
				local part0, part1 = motor.Part0, motor.Part1
				t.eq(part0 and part0.Name, entry[2], entry[1] .. " Part0")
				t.eq(part1 and part1.Name, entry[3], entry[1] .. " Part1")
			end
		end
		-- the hair hangs in swaying chains Head -> HairN_1 -> HairN_2 ...
		t.truthy(#NAMES.Hair >= 4, "several hair clumps")
		for clump, chain in NAMES.Hair do
			t.truthy(#chain >= 2, "hair clump " .. clump .. " has at least two segments")
			for segment, name in chain do
				t.eq(name, string.format("Hair%d_%d", clump, segment), "hair segment name")
				local motor = byName[name]
				local parentName = if segment == 1 then NAMES.Head else chain[segment - 1]
				local part0 = motor and motor.Part0
				t.eq(part0 and part0.Name, parentName, name .. " hangs from " .. parentName)
			end
		end
	end,

	["joints: every limb hangs off the root through the joint tree"] = function(t: Expect)
		local built = rest()
		local model = built.model
		local children: { [BasePart]: { BasePart } } = {}
		local parentCount: { [BasePart]: number } = {}
		for _, motor in motors(model) do
			local part0, part1 = motor.Part0, motor.Part1
			if part0 and part1 then
				local list = children[part0] or {}
				table.insert(list, part1)
				children[part0] = list
				parentCount[part1] = (parentCount[part1] or 0) + 1
			end
		end
		local reached: { [BasePart]: boolean } = { [built.root] = true }
		local queue: { BasePart } = { built.root }
		while #queue > 0 do
			local part = table.remove(queue) :: BasePart
			local branch: { BasePart } = children[part] or {}
			for _, child in branch do
				if not reached[child] then
					reached[child] = true
					table.insert(queue, child)
				end
			end
		end
		for _, child in model:GetChildren() do
			if child:IsA("BasePart") and child ~= built.root and child ~= built.hitbox then
				t.eq(parentCount[child], 1, child.Name .. " is Part1 of exactly one Motor6D")
				t.truthy(reached[child], child.Name .. " is reached from the root")
			end
		end
		t.falsy(parentCount[built.root], "nothing drives the root")
	end,

	["details: every piece is welded to the jointed limb that carries it"] = function(t: Expect)
		local model = rest().model
		local details = 0
		for _, part in baseParts(model) do
			local limb = part.Parent
			if limb == model then
				continue
			end
			details += 1
			if limb and limb:IsA("BasePart") then
				t.eq(limb.Parent, model, part.Name .. " is carried by a jointed rig part")
				local welded = false
				for _, child in part:GetChildren() do
					local weld: (WeldConstraint | Weld)? = nil
					if child:IsA("WeldConstraint") or child:IsA("Weld") then
						weld = child
					end
					if weld then
						welded = welded or (weld.Part0 == limb and weld.Part1 == part)
					end
				end
				t.truthy(welded, part:GetFullName() .. " is welded to " .. limb.Name)
			else
				t.fail(part:GetFullName() .. " is neither a rig part nor carried by one")
			end
		end
		t.truthy(details > 100, "the body is detailed (" .. details .. " pieces)")
	end,

	["physics: unanchored, only the root has mass and collides, limbs NoCollide"] = function(t: Expect)
		local built = rest()
		local root = built.root
		sameVector(t, root.Size, RIG.RootSize, SIZE_EPS, "root size")
		t.eq(root.Transparency, 1, "root is invisible")
		t.falsy(root.Massless, "root carries the mass")
		t.truthy(root.CanCollide, "root collides")
		t.falsy(root.CanQuery, "root CanQuery")
		t.falsy(root.CanTouch, "root CanTouch")
		t.eq(root.CollisionGroup, CollisionGroups.Monster, "root group")
		for _, part in baseParts(built.model) do
			t.falsy(part.Anchored, part:GetFullName() .. " is anchored")
			if part == root or part == built.hitbox then
				continue
			end
			t.truthy(part.Massless, part:GetFullName() .. " Massless")
			t.falsy(part.CanCollide, part:GetFullName() .. " CanCollide")
			t.falsy(part.CanQuery, part:GetFullName() .. " CanQuery")
			t.falsy(part.CanTouch, part:GetFullName() .. " CanTouch")
			t.eq(part.CollisionGroup, CollisionGroups.NoCollide, part:GetFullName() .. " group")
		end
	end,

	["hitbox: invisible Monster query volume covering the biped from the floor up"] = function(t: Expect)
		local built = rest()
		local hitbox = built.hitbox
		t.eq(hitbox.Name, "CreatureHitbox")
		t.eq(hitbox.Parent, built.model)
		t.eq(hitbox.Transparency, 1, "invisible")
		t.falsy(hitbox.CanCollide, "CanCollide")
		t.truthy(hitbox.CanQuery, "CanQuery")
		t.falsy(hitbox.CanTouch, "CanTouch")
		t.truthy(hitbox.Massless, "Massless")
		t.eq(hitbox.CollisionGroup, CollisionGroups.Monster, "group")
		sameVector(t, hitbox.Size, CreatureConfig.Hitbox.Biped, SIZE_EPS, "biped size")
		t.eq(hitboxJoint(built).Name, "HitboxJoint")
		checkHitboxSeat(t, built, "Biped")
		t.near(-reach(hitbox, -UP) - FLOOR, 0, POSITION_EPS, "box bottom on the floor")
		-- the box covers the body: every jointed part's centre and the eyes are inside it
		for _, child in built.model:GetChildren() do
			if child:IsA("BasePart") and child ~= hitbox then
				t.truthy(insideHitbox(built, child.CFrame.Position), child.Name .. " lies inside the biped hitbox")
			end
		end
		local left = findPart(built.model, NAMES.LeftPupil)
		t.truthy(insideHitbox(built, left.CFrame.Position), "the eyes lie inside the biped hitbox")
	end,

	["hitbox: setHitbox resizes and re-seats the box for every PoseMode"] = function(t: Expect)
		local built = build(BASE)
		local joint = hitboxJoint(built)
		local restSize = built.hitbox.Size
		local restFrame = built.hitbox.CFrame
		local restC0 = joint.C0
		local tops: { [string]: number } = {}
		local modes = sortedPoseModes()
		t.eq(#modes, 3, "Biped, Hunched and Quadruped")
		for _, mode in modes do
			local size = CreatureConfig.Hitbox[mode]
			CreatureRigBuilder.setHitbox(built.model, mode)
			sameVector(t, built.hitbox.Size, size, SIZE_EPS, mode .. " size")
			checkHitboxSeat(t, built, mode)
			local centre = built.hitbox.CFrame.Position - built.root.CFrame.Position
			tops[mode] = reach(built.hitbox, UP) - FLOOR
			t.truthy(centre:Dot(BASE.LookVector) >= -POSITION_EPS, mode .. " box is not behind the root")
			if mode == "Biped" or mode == "Hunched" then
				t.near(-reach(built.hitbox, -UP) - FLOOR, 0, POSITION_EPS, mode .. " box stands on the floor")
			else
				-- low and long along the facing, carried level with the root (the vent rail / water line)
				t.truthy(size.Z > size.X and size.Z > size.Y, mode .. " box is longest front to back")
				t.near(centre:Dot(UP), 0, POSITION_EPS, mode .. " box centred at root height")
				t.truthy(centre:Dot(BASE.LookVector) > 0, mode .. " box runs ahead of the root")
				t.truthy(
					size.Y / 2 < CreatureConfig.EyeHeightAboveRoot.Biped,
					mode .. " box is lower than the standing eyes"
				)
			end
		end
		t.truthy(tops.Hunched < tops.Biped, "the hunched box is shorter than the biped box")

		CreatureRigBuilder.setHitbox(built.model, "Biped")
		CreatureRigBuilder.setHitbox(built.model, "Levitating")
		sameVector(t, built.hitbox.Size, restSize, SIZE_EPS, "unknown modes leave the size alone")
		sameFrame(t, joint.C0, restC0, "unknown modes leave the joint alone")
		sameFrame(t, built.hitbox.CFrame, restFrame, "back to Biped restores the rest box")

		-- a model without a hitbox (or a stripped rig) is left alone without throwing
		CreatureRigBuilder.setHitbox(Instance.new("Model"), "Quadruped")
		built.folder:Destroy()
	end,

	["hands: long arms ending in four long tapering fingers and a thumb, no claws"] = function(t: Expect)
		local model = rest().model
		for _, part in baseParts(model) do
			t.falsy(string.find(part.Name, "Claw"), part.Name .. ": the hands have no claws")
		end
		local black = RIG.ShadowColor.R + RIG.ShadowColor.G + RIG.ShadowColor.B
		for _, side in { "Left", "Right" } do
			local chain = NAMES.Fingers[side]
			t.eq(#chain, 5, side .. " has four fingers and a thumb")
			local hand = findPart(model, side .. "Hand")
			for _, name in chain do
				local finger = findPart(model, name)
				t.eq(finger.Parent, model, name .. " is a jointed rig part")
				local motor = finger:FindFirstChild(name)
				local motorPart0 = if motor and motor:IsA("Motor6D") then motor.Part0 else nil
				t.eq(motorPart0, hand, name .. " is jointed to " .. hand.Name)
				-- the finger tapers: every welded segment is thinner than the jointed one, ending in a slim point
				local pointed = false
				local thickness = math.min(finger.Size.Y, finger.Size.Z)
				for _, piece in baseParts(finger) do
					if string.find(piece.Name, "Knuckle$") then
						continue
					end
					t.truthy(math.min(piece.Size.X, piece.Size.Y, piece.Size.Z) < thickness, piece.Name .. " tapers")
					pointed = pointed or (piece:IsA("WedgePart") and string.find(piece.Name, "Point$") ~= nil)
				end
				t.truthy(pointed, name .. " ends in a point")
				t.near(finger.Color.R + finger.Color.G + finger.Color.B, black, 0.02, name .. " is black")
			end
			local shoulder = model:FindFirstChild(side .. "Shoulder", true)
			local part0 = if shoulder and shoulder:IsA("Motor6D") then shoulder.Part0 else nil
			if not (shoulder and shoulder:IsA("Motor6D") and part0) then
				t.fail("no " .. side .. "Shoulder")
				continue
			end
			local pivot = (part0.CFrame * shoulder.C0).Position
			local furthest = 0
			local middle = findPart(model, side .. "Middle")
			for _, piece in baseParts(middle) do
				local direction = (piece.CFrame.Position - pivot).Unit
				furthest = math.max(furthest, reach(piece, direction) - pivot:Dot(direction))
			end
			t.truthy(
				furthest >= RIG.ArmLength * 0.93 and furthest <= RIG.ArmLength * 1.03,
				string.format(
					"%s shoulder-to-fingertip reach %.2f against ArmLength %.2f",
					side,
					furthest,
					RIG.ArmLength
				)
			)
		end
	end,

	["mask: ivory porcelain over the face, the chin a separate Jaw that drops the slit open"] = function(t: Expect)
		local model = rest().model
		local head = findPart(model, NAMES.Head)
		local mask = findPart(model, NAMES.Mask)
		local jaw = findPart(model, NAMES.Jaw)
		t.eq(mask.Parent, head, "the upper mask rides the Head")
		for _, part in { mask, findPart(model, "MaskBrow"), jaw, findPart(model, "Chin") } do
			t.eq(part.Material, Enum.Material.Marble, part.Name .. " is porcelain")
			t.eq(part.Color, RIG.MaskColor, part.Name .. " colour")
			local average = (part.Color.R + part.Color.G + part.Color.B) / 3
			t.truthy(average > 0.68 and average < 0.8, part.Name .. " is ivory, not white")
			t.truthy(part.Color.B < part.Color.R, part.Name .. " is warm")
			t.truthy(part.Reflectance > 0 and part.Reflectance <= 0.2, part.Name .. " has a slight sheen")
		end
		for name, value in CreatureRigBuilder.MaskAttributes do
			t.eq(mask:GetAttribute(name), value, "Mask attribute " .. name)
		end
		for _, name in
			{ "EyeX", "EyeHoleWidth", "EyeHoleHeight", "EyeHoleDepth", "SlitY", "SlitHalfWidth", "SlitUpturn" }
		do
			t.truthy(type(mask:GetAttribute(name)) == "number", "Mask carries " .. name)
		end
		-- the sculpt both platforms draw: the outline, the profile and the relief as rows of numbers, and the chip
		local shape = CreatureRigBuilder.MaskShape
		t.eq(mask:GetAttribute("MaskOutline"), shape.MaskOutline, "MaskOutline")
		t.eq(mask:GetAttribute("MaskProfile"), shape.MaskProfile, "MaskProfile")
		t.eq(mask:GetAttribute("MaskRelief"), shape.MaskRelief, "MaskRelief")
		t.eq(mask:GetAttribute("ChipCentre"), shape.ChipCentre, "ChipCentre")
		t.eq(mask:GetAttribute("ChipRadius"), shape.ChipRadius, "ChipRadius")
		local outline: { { number } } = {}
		for row in string.gmatch(shape.MaskOutline, "[^;]+") do
			local cells: { number } = {}
			for cell in string.gmatch(row, "[^:]+") do
				table.insert(cells, tonumber(cell) or 0)
			end
			t.eq(#cells, 3, "an outline knot is y:left:right")
			table.insert(outline, cells)
		end
		t.truthy(#outline >= 8, "the outline has knots")
		local top, chin = outline[1], outline[#outline]
		local widest, lopsided = 0, false
		for i, knot in outline do
			widest = math.max(widest, knot[2] + knot[3])
			lopsided = lopsided or math.abs(knot[2] - knot[3]) > 0.004
			if i > 1 then
				t.truthy(knot[1] < outline[i - 1][1], "the outline runs top down")
			end
		end
		t.truthy((top[1] - chin[1]) / widest > 1.6, "an elongated oval, a little too long")
		t.truthy(lopsided, "a touch asymmetric")
		t.eq(chin[2] + chin[3], 0, "the chin comes to a point")
		local reliefs = 0
		local hollows = 0
		for row in string.gmatch(shape.MaskRelief, "[^;]+") do
			local cells: { string } = {}
			for cell in string.gmatch(row, "[^:]+") do
				table.insert(cells, cell)
			end
			t.eq(#cells, 7, "a relief row is Name:x:y:rx:ry:height:tilt")
			reliefs += 1
			if (tonumber(cells[6]) or 0) < 0 then
				hollows += 1
			end
		end
		t.truthy(
			reliefs >= 10 and hollows >= 4,
			"a sculpted relief with hollows (" .. reliefs .. ", " .. hollows .. ")"
		)
		-- the chin hangs from the Head on its own hinge, under the slit; a negative pitch drops it open
		local motor = jaw:FindFirstChild("Jaw")
		if not (motor and motor:IsA("Motor6D")) then
			t.fail("no Jaw Motor6D")
			return
		end
		t.eq(motor.Part0, head, "the chin hangs from the Head")
		local face = model:FindFirstChild(NAMES.FaceAttachment, true)
		local slit = mask:GetAttribute("SlitY")
		if not (face and face:IsA("Attachment") and type(slit) == "number") then
			t.fail("no face attachment or SlitY")
			return
		end
		local faceFrame = head.CFrame * face.CFrame
		t.truthy(faceFrame:PointToObjectSpace(jaw.CFrame.Position).Y < slit, "the chin's centre lies under the slit")
		local chinTip = findPart(model, "Chin")
		t.eq(chinTip.Parent, jaw, "the pointed chin rides the Jaw")
		local hinge = faceFrame:PointToObjectSpace((head.CFrame * motor.C0).Position)
		t.truthy(hinge.Z > 0, "the hinge sits behind the mask's face")
		local open = head.CFrame * motor.C0 * CFrame.Angles(-math.rad(35), 0, 0) * motor.C1:Inverse()
		t.truthy(open.Position:Dot(UP) < jaw.CFrame.Position:Dot(UP) - 0.05, "a negative pitch drops the chin")
		-- the detail drawn in parts for Roblox (the web paints its own): black almond eye holes round the pinpricks,
		-- the slit in strips along the seam, black over the faces the split opens
		for _, name in
			{ "LeftEyeHole", "RightEyeHole", "MouthSlit1", "MouthSlit2", "MouthSlit3", "MouthSlit4", "MouthVoidUpper" }
		do
			local part = findPart(model, name)
			t.eq(part.Parent, head, name .. " rides the Head")
			t.eq(part.Material, Enum.Material.Fabric, name .. " is drawn detail (Fabric)")
			t.truthy((part.Color.R + part.Color.G + part.Color.B) / 3 < 0.05, name .. " is black")
		end
		-- no porcelain shows inside the open split: the jaw ball's cap above the seam stays inside the black sleeve on
		-- the Jaw, and the sleeve inside the upper mask while it is shut
		local sleeve = findPart(model, "MouthVoidLower")
		t.eq(sleeve.Parent, jaw, "the black sleeve rides the Jaw")
		local jawRadius = math.min(jaw.Size.X, jaw.Size.Y, jaw.Size.Z) / 2
		local jawInFace = faceFrame:PointToObjectSpace(jaw.CFrame.Position)
		local sleeveInFace = faceFrame:PointToObjectSpace(sleeve.CFrame.Position)
		local maskInFace = faceFrame:PointToObjectSpace(mask.CFrame.Position)
		local sleeveRadius = math.min(sleeve.Size.Y, sleeve.Size.Z) / 2
		local capAtSeam = math.sqrt(math.max(jawRadius ^ 2 - (slit - jawInFace.Y) ^ 2, 0))
		local offset = Vector2.new(jawInFace.X - sleeveInFace.X, jawInFace.Z - sleeveInFace.Z).Magnitude
		t.truthy(offset + capAtSeam < sleeveRadius, "the jaw's cap above the seam is inside the sleeve")
		t.truthy(sleeveInFace.Y + sleeve.Size.X / 2 >= jawInFace.Y + jawRadius, "the sleeve reaches over the cap's top")
		local sleeveOffset = Vector2.new(sleeveInFace.X - maskInFace.X, sleeveInFace.Z - maskInFace.Z).Magnitude
		t.truthy(sleeveOffset + sleeveRadius < mask.Size.Y / 2, "the sleeve hides inside the upper mask while shut")
		for _, part in baseParts(model) do
			if
				part.Material == Enum.Material.Marble
				and part.Parent == jaw
				and part ~= chinTip
				and not string.find(part.Name, "^MawShard")
			then
				local inFace = faceFrame:PointToObjectSpace(part.CFrame.Position)
				t.truthy(inFace.Y < slit, part.Name .. " (porcelain on the Jaw) hangs under the slit")
			end
		end
		-- the relief, sunk into the shell: brow ridges, nose, cheekbones, lips, chin
		for _, name in
			{ "BrowLeft", "BrowRight", "Nose", "NoseTip", "CheekLeft", "CheekRight", "LipUpper", "LipLower", "Chin" }
		do
			local part = findPart(model, "Relief" .. name)
			t.eq(part.Material, Enum.Material.Marble, part.Name .. " is porcelain")
			t.truthy(part.Parent == head or part.Parent == jaw, part.Name .. " rides the mask")
		end
		-- every crack and streak piece rides the half of the mask it lies on and hugs that half's shell at both ends, a
		-- seam end too (never placed by the side of the slit a float rounding lands on): the upper mask's cylinder or
		-- brow dome on the Head, the jaw ball or the chin on the Jaw
		local maskTop, maskRadius = maskInFace.Y + mask.Size.X / 2, mask.Size.Y / 2
		local chinInFace, chinRadius = faceFrame:PointToObjectSpace(chinTip.CFrame.Position), chinTip.Size.X / 2
		local function offShell(part: BasePart, width: number): number
			local half = (part.Size.Z - width * 0.5) / 2
			local worst = 0
			for _, sign in SIGNS do
				local e = faceFrame:PointToObjectSpace(part.CFrame.Position + part.CFrame.ZVector * (sign * half))
				local off: number
				if part.Parent == jaw then
					off = math.min(
						math.abs((e - jawInFace).Magnitude - jawRadius),
						math.abs((e - chinInFace).Magnitude - chinRadius)
					)
				elseif e.Y > maskTop then
					off = math.abs((e - Vector3.new(maskInFace.X, maskTop, maskInFace.Z)).Magnitude - maskRadius)
				else
					off = math.abs(Vector2.new(e.X - maskInFace.X, e.Z - maskInFace.Z).Magnitude - maskRadius)
				end
				worst = math.max(worst, off)
			end
			return worst
		end
		-- (the attributes' own types are checked where it is called)
		local function onItsHalf(part: BasePart, from: unknown, to: unknown, width: unknown)
			if typeof(from) == "Vector2" and typeof(to) == "Vector2" and type(width) == "number" then
				t.eq(
					part.Parent,
					if (from.Y + to.Y) / 2 < slit then jaw else head,
					part.Name .. " rides the half it lies on"
				)
				local off = offShell(part, width)
				t.truthy(
					off < SHELL_SLACK,
					string.format("%s hugs its half's shell at both ends (%.4f off)", part.Name, off)
				)
			end
		end
		local cracks, streaks, shards, widestCrack = 0, 0, 0, 0
		for _, part in baseParts(model) do
			if string.find(part.Name, "^MaskCrack") then
				cracks += 1
				t.eq(part.Material, Enum.Material.Fabric, part.Name .. " is drawn detail")
				t.truthy(typeof(part:GetAttribute("CrackFrom")) == "Vector2", part.Name .. " CrackFrom")
				t.truthy(typeof(part:GetAttribute("CrackTo")) == "Vector2", part.Name .. " CrackTo")
				local width = part:GetAttribute("CrackWidth")
				t.truthy(type(width) == "number" and width > 0, part.Name .. " CrackWidth")
				widestCrack = math.max(widestCrack, if type(width) == "number" then width else 0)
				t.truthy(part.Parent == head or part.Parent == jaw, part.Name .. " rides the mask")
				onItsHalf(part, part:GetAttribute("CrackFrom"), part:GetAttribute("CrackTo"), width)
			elseif string.find(part.Name, "^MaskStreak") then
				streaks += 1
				t.eq(part.Material, Enum.Material.Fabric, part.Name .. " is drawn detail")
				t.truthy(typeof(part:GetAttribute("StreakFrom")) == "Vector2", part.Name .. " StreakFrom")
				t.truthy(typeof(part:GetAttribute("StreakTo")) == "Vector2", part.Name .. " StreakTo")
				t.truthy(type(part:GetAttribute("StreakWidth")) == "number", part.Name .. " StreakWidth")
				local from, to = part:GetAttribute("StreakFrom"), part:GetAttribute("StreakTo")
				onItsHalf(part, from, to, part:GetAttribute("StreakWidth"))
			elseif string.find(part.Name, "^MawShard") then
				shards += 1
				t.eq(part.Material, Enum.Material.Marble, part.Name .. " is porcelain")
				t.truthy(part:IsA("WedgePart"), part.Name .. " is a jagged wedge")
			end
		end
		t.truthy(cracks >= 12, "the major crack and its hairlines (" .. cracks .. ")")
		t.truthy(widestCrack >= 0.007, "one major crack")
		t.truthy(streaks >= 4, "weeping streaks under both eyes (" .. streaks .. ")")
		t.truthy(shards >= 4, "jagged shards in the split (" .. shards .. ")")
		t.eq(findPart(model, "MaskChip1").Material, Enum.Material.Fabric, "the chipped edge shows the black behind")
		-- the grime: a SurfaceGui decal on an invisible card over each half of the face, within Roblox's texture cap
		for _, side in { "Left", "Right" } do
			local card = findPart(model, "MaskGrime" .. side)
			t.eq(card.Transparency, 1, card.Name .. " is invisible")
			local gui = card:FindFirstChildOfClass("SurfaceGui")
			if not gui then
				t.fail(card.Name .. " has no SurfaceGui")
				continue
			end
			t.truthy(#gui:GetDescendants() >= 4, card.Name .. " draws grime")
			t.truthy(
				math.max(card.Size.X, card.Size.Y) * gui.PixelsPerStud <= 1024,
				card.Name .. " stays within the 1024-pixel texture cap"
			)
		end
		-- the pinpricks: tiny, one larger than the other
		local left, right = findPart(model, NAMES.LeftPupil), findPart(model, NAMES.RightPupil)
		t.truthy(right.Size.X > left.Size.X * 1.2, "one pinprick is larger than the other")
		-- the mask is the palest thing on the Creature
		for _, part in baseParts(model) do
			local lit = part.Material == Enum.Material.Neon or part.Material == Enum.Material.Marble
			if part.Transparency < 1 and not lit then
				t.truthy(
					(part.Color.R + part.Color.G + part.Color.B) / 3 < 0.15,
					part.Name .. " is darker than the mask"
				)
			end
		end
	end,

	["budget: at most 240 BaseParts of the allowed classes"] = function(t: Expect)
		local parts = baseParts(rest().model)
		t.truthy(CreatureRigBuilder.PartBudget <= 240, "budget constant")
		t.truthy(#parts <= CreatureRigBuilder.PartBudget, #parts .. " BaseParts")
		for _, part in parts do
			t.truthy(
				part.ClassName == "Part" or part.ClassName == "WedgePart" or part.ClassName == "CornerWedgePart",
				part:GetFullName() .. " is a " .. part.ClassName
			)
		end
	end,

	["contract: PartNames resolve on the built rig and the tables are frozen"] = function(t: Expect)
		local model = rest().model
		t.truthy(table.isfrozen(NAMES), "PartNames is frozen")
		t.truthy(table.isfrozen(NAMES.Hair), "PartNames.Hair is frozen")
		local partNames: { string } = {
			NAMES.Root,
			NAMES.LowerTorso,
			NAMES.UpperTorso,
			NAMES.Head,
			NAMES.Jaw,
			NAMES.LeftUpperArm,
			NAMES.LeftLowerArm,
			NAMES.LeftHand,
			NAMES.RightUpperArm,
			NAMES.RightLowerArm,
			NAMES.RightHand,
			NAMES.LeftUpperLeg,
			NAMES.LeftLowerLeg,
			NAMES.LeftFoot,
			NAMES.RightUpperLeg,
			NAMES.RightLowerLeg,
			NAMES.RightFoot,
			NAMES.LeftPupil,
			NAMES.RightPupil,
			NAMES.Hitbox,
			NAMES.Mask,
			NAMES.Crown,
		}
		for _, chain in NAMES.Hair do
			t.truthy(table.isfrozen(chain), "hair chain is frozen")
			for _, name in chain do
				table.insert(partNames, name)
			end
		end
		t.truthy(table.isfrozen(NAMES.Fingers), "PartNames.Fingers is frozen")
		for _, side in { "Left", "Right" } do
			local chain = NAMES.Fingers[side]
			t.truthy(chain and table.isfrozen(chain), side .. " fingers are frozen")
			if chain then
				for _, name in chain do
					table.insert(partNames, name)
				end
			end
		end
		for _, name in partNames do
			local found = model:FindFirstChild(name, true)
			t.truthy(found and found:IsA("BasePart"), "PartNames: " .. name)
		end
		t.truthy(model:FindFirstChild(NAMES.HitboxJoint, true), "PartNames: " .. NAMES.HitboxJoint)
		t.truthy(model:FindFirstChild(NAMES.FaceAttachment, true), "PartNames: " .. NAMES.FaceAttachment)
		t.truthy(model:FindFirstChildOfClass("Humanoid"), "PartNames: " .. NAMES.Humanoid)
		t.truthy(table.isfrozen(CreatureRigBuilder), "the module is frozen")
	end,

	["determinism: every build of the Creature is identical"] = function(t: Expect)
		local first = build(BASE)
		local second = build(BASE)
		local a, b = baseParts(first.model), baseParts(second.model)
		t.eq(#a, #b, "part counts")
		for i, part in a do
			local other = b[i]
			if not other then
				break
			end
			t.eq(part:GetFullName(), other:GetFullName(), "part order")
			t.eq(part.Size, other.Size, part.Name .. " size")
			t.eq(part.Color, other.Color, part.Name .. " colour")
			sameFrame(t, part.CFrame, other.CFrame, part.Name)
		end
		first.folder:Destroy()
		second.folder:Destroy()
	end,

	["register: hands build to the registrar as the Creature rig"] = function(t: Expect)
		local rigs: { [string]: Types.RigBuilder } = {}
		local others = 0
		local registrar: PropKit.Registrar = {
			prop = function(_kind: string, _builder: Types.PropBuilder)
				others += 1
			end,
			fixture = function(_kind: string, _builder: PropKit.FixtureBuilder)
				others += 1
			end,
			static = function(_kind: string, _builder: PropKit.StaticBuilder)
				others += 1
			end,
			rig = function(kind: string, builder: Types.RigBuilder)
				rigs[kind] = builder
			end,
			cosmetic = function(_kind: Enums.AnchorKind, _builder: PropKit.CosmeticAnchorBuilder)
				others += 1
			end,
		}
		CreatureRigBuilder.register(registrar)
		t.eq(rigs.Creature, CreatureRigBuilder.build, "the Creature rig builder")
		t.eq(others, 0, "the rig registers nothing else")
	end,
	["shadow: the body is matte near-black with a faint sheen; the pupils glow"] = function(t: Expect)
		local built = rest()
		local body = 0
		for _, part in baseParts(built.model) do
			if part.Transparency >= 1 or part.Material ~= Enum.Material.SmoothPlastic then
				continue
			end
			body += 1
			local color = part.Color
			t.truthy((color.R + color.G + color.B) / 3 < 0.1, part.Name .. " is near-black")
			t.truthy(part.Reflectance > 0 and part.Reflectance <= 0.08, part.Name .. " has only a faint sheen")
		end
		t.truthy(body >= 60, string.format("the shadow body is detailed (%d parts)", body))
		local pupil = findPart(built.model, NAMES.LeftPupil)
		t.eq(pupil.Material, Enum.Material.Neon, "the eyes glow")
	end,

	["smoke: anchors at the shoulders, elbows, fingertips, the back and the skull"] = function(t: Expect)
		local model = rest().model
		t.truthy(table.isfrozen(NAMES.SmokeAnchors), "SmokeAnchors is frozen")
		local found: { [string]: Attachment } = {}
		for _, name in NAMES.SmokeAnchors do
			local attachment = model:FindFirstChild(name, true)
			if not (attachment and attachment:IsA("Attachment")) then
				t.fail("no smoke anchor " .. name)
				continue
			end
			found[name] = attachment
			local weight = attachment:GetAttribute("SmokeWeight")
			t.truthy(type(weight) == "number" and weight > 0, name .. " has a SmokeWeight")
			local parent = attachment.Parent
			t.truthy(parent and parent:IsA("BasePart") and parent.Parent == model, name .. " rides a jointed rig part")
		end
		for _, side in { "Left", "Right" } do
			t.truthy(found["Smoke" .. side .. "Shoulder"], side .. " shoulder")
			t.truthy(found["Smoke" .. side .. "Elbow"], side .. " elbow")
			for _, finger in { "Index", "Middle", "Ring", "Pinky" } do
				local tip = found["Smoke" .. side .. finger .. "Tip"]
				t.truthy(tip, side .. " " .. finger .. " tip")
				local tipParent = if tip then tip.Parent else nil
				t.eq(tipParent and tipParent.Name, side .. finger, "the tip anchor rides its finger")
			end
		end
		t.truthy(found.SmokeBack, "the back")
		t.truthy(found.SmokeHead, "the skull")
		-- the shroud: heavy smoke from the shoulders down
		local shroud = 0
		for name, attachment in found do
			if attachment:GetAttribute("SmokeShroud") == true then
				shroud += 1
				local holder = attachment.Parent
				local world = if holder and holder:IsA("BasePart")
					then (holder.CFrame * attachment.CFrame).Position
					else Vector3.zero
				local position = world:Dot(UP) - FLOOR
				t.truthy(position > 3 and position < 9, name .. " hangs between the shoulders and the knees")
			end
		end
		t.truthy(shroud >= 5, "the shroud's anchors (" .. shroud .. ")")
	end,

	["metrics: heights, eyes, reach and hitboxes for the web's behaviour"] = function(t: Expect)
		local metrics = CreatureRigBuilder.Metrics
		t.truthy(table.isfrozen(metrics), "Metrics is frozen")
		t.eq(metrics.Height, 11, "standing height")
		t.eq(metrics.HunchedHeight, 9, "hunched height")
		t.eq(metrics.Reach, 4, "catch reach")
		t.near(metrics.RootHeight, ROOT_HEIGHT, 1e-6, "root height")
		for mode, above in CreatureConfig.EyeHeightAboveRoot do
			t.near(metrics.EyeHeight[mode], ROOT_HEIGHT + above, 1e-6, mode .. " eye height")
		end
		t.truthy(metrics.EyeHeight.Hunched < metrics.HunchedHeight, "hunched eyes under the hunched crown")
		t.truthy(metrics.EyeHeight.Biped < metrics.Height, "standing eyes under the crown")
		local built = build(BASE)
		for mode, box in metrics.Hitboxes do
			CreatureRigBuilder.setHitbox(built.model, mode)
			sameVector(t, built.hitbox.Size, box.size, SIZE_EPS, mode .. " hitbox size")
			sameFrame(t, built.hitbox.CFrame, built.root.CFrame * box.offset, mode .. " hitbox offset")
		end
		built.folder:Destroy()
	end,
}
