--!strict
-- CreatureRigBuilder contracts on a Creature built at a raised, turned spawn point: its size against
-- CreatureConfig.Rig (8.5 tall, feet on the floor, eyes EyeHeightAboveRoot.Biped above the root, 6-inch claws, arm
-- reach), the R15 + Jaw + hair joint tree (every Motor6D consistent with its parts at rest, joint frames aligned
-- with the facing, everything hanging off the root, details welded to their limb), the physics presets (only the
-- root has mass and collides; limbs NoCollide; the CreatureHitbox queryable and resized per PoseMode by
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

local function baseParts(model: Model): { BasePart }
	local list: { BasePart } = {}
	for _, descendant in model:GetDescendants() do
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

	["size: 8.5 studs to the top of the head, soles, heels and toes on the floor"] = function(t: Expect)
		local model = rest().model
		local top, bottom = verticalSpan(model)
		t.near(top, RIG.Height, 0.25, "top of the head above the floor")
		t.near(bottom, 0, 0.02, "lowest point of the body (nothing sinks into the floor)")
		for _, name in { NAMES.LeftFoot, NAMES.RightFoot } do
			local foot = findPart(model, name)
			t.near(-reach(foot, -UP) - FLOOR, 0, 0.01, name .. " sole on the floor")
		end
		-- the hair cap is the crown: nothing pokes out above it
		t.near(reach(findPart(model, "Scalp"), UP) - FLOOR, top, 0.01, "the scalp is the highest point")
	end,

	["eyes: pinprick pupils EyeHeightAboveRoot.Biped above the root, deep in black sockets"] = function(t: Expect)
		local built = rest()
		local model = built.model
		local left = findPart(model, NAMES.LeftPupil)
		local right = findPart(model, NAMES.RightPupil)
		local eyes = (left.CFrame.Position + right.CFrame.Position) / 2
		local fromRoot = eyes - built.root.CFrame.Position
		t.near(fromRoot:Dot(UP), CreatureConfig.EyeHeightAboveRoot.Biped, 0.01, "eye height above the root centre")
		local ahead = fromRoot:Dot(BASE.LookVector)
		t.truthy(ahead >= 0 and ahead <= 1, "the hunched face leans at most a stud ahead of the root: " .. ahead)
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

		for _, pupil in { left, right } do
			t.eq(pupil.Material, Enum.Material.Neon, pupil.Name .. " material")
			t.eq(pupil.Color, RIG.PupilColor, pupil.Name .. " colour")
			t.truthy(pupil.Size.X <= 0.06, pupil.Name .. " is a pinprick")
			local side = string.sub(pupil.Name, 1, #pupil.Name - #"Pupil")
			local socket = findPart(model, side .. "EyeSocket")
			t.eq(socket.Color, RIG.EyeSocketColor, socket.Name .. " colour")
			t.truthy(socket.Size.X > pupil.Size.X * 4, socket.Name .. " dwarfs its pupil")
			-- the pinprick lies on the black back wall of the socket, where it can be seen ...
			local offset = pupil.CFrame.Position - socket.CFrame.Position
			t.near(offset.Magnitude, socket.Size.X / 2, pupil.Size.X / 2, pupil.Name .. " sits on its socket's wall")
			t.truthy(offset:Dot(BASE.LookVector) > 0, pupil.Name .. " faces out of the socket")
			-- ... sunk behind the brow, so the socket reads as a hollow
			local pupilFront = pupil.CFrame.Position:Dot(BASE.LookVector)
			local browFront = reach(findPart(model, side .. "Brow"), BASE.LookVector)
			t.truthy(browFront > pupilFront + 0.05, side .. " brow overhangs the socket")
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
		t.eq(#modes, 4, "Biped, Hunched, Quadruped and Swim")
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

	["hands: elongated arms ending in four clawed fingers and a clawed thumb"] = function(t: Expect)
		local model = rest().model
		local claws: { [string]: number } = {}
		local total = 0
		for _, part in baseParts(model) do
			if string.sub(part.Name, -4) ~= "Claw" then
				continue
			end
			total += 1
			t.truthy(part:IsA("WedgePart"), part.Name .. " is a tapering wedge")
			t.near(part.Size.Z, RIG.ClawLength, 1e-3, part.Name .. " length")
			t.truthy(part.Size.X < 0.1 and part.Size.Y < 0.1, part.Name .. " is a slender blade")
			local hand = part.Parent
			local handName = if hand then hand.Name else "nil"
			claws[handName] = (claws[handName] or 0) + 1
			t.truthy(part.Color ~= RIG.SkinColor and part.Color ~= RIG.ToothColor, part.Name .. " is stained")
		end
		t.eq(total, 10, "ten claws")
		t.eq(claws[NAMES.LeftHand], 5, "five claws on the left hand")
		t.eq(claws[NAMES.RightHand], 5, "five claws on the right hand")

		for _, side in { "Left", "Right" } do
			local shoulder = model:FindFirstChild(side .. "Shoulder", true)
			if not (shoulder and shoulder:IsA("Motor6D")) then
				t.fail("no " .. side .. "Shoulder")
				continue
			end
			local part0 = shoulder.Part0
			if not part0 then
				t.fail(side .. "Shoulder has no Part0")
				continue
			end
			local pivot = (part0.CFrame * shoulder.C0).Position
			local hand = findPart(model, side .. "Hand")
			local furthest = 0
			for _, piece in hand:GetChildren() do
				if piece:IsA("BasePart") then
					local direction = (piece.CFrame.Position - pivot).Unit
					furthest = math.max(furthest, reach(piece, direction) - pivot:Dot(direction))
				end
			end
			t.truthy(
				furthest >= RIG.ArmLength * 0.95 and furthest <= RIG.ArmLength + RIG.ClawLength,
				string.format("%s shoulder-to-claw reach %.2f against ArmLength %.2f", side, furthest, RIG.ArmLength)
			)
		end
	end,

	["face: a separate Jaw that drops open on its Motor6D, bared teeth above and below"] = function(t: Expect)
		local model = rest().model
		local jaw = findPart(model, NAMES.Jaw)
		local motor = jaw:FindFirstChild("Jaw")
		if not (motor and motor:IsA("Motor6D")) then
			t.fail("no Jaw Motor6D")
			return
		end
		local head = motor.Part0
		t.eq(head and head.Name, NAMES.Head, "the jaw hangs from the Head")
		if not head then
			return
		end
		local open = head.CFrame * motor.C0 * CFrame.Angles(-math.rad(35), 0, 0) * motor.C1:Inverse()
		t.truthy(open.Position:Dot(UP) < jaw.CFrame.Position:Dot(UP) - 0.05, "a negative pitch drops the jaw")
		local upper, lower = 0, 0
		for _, part in baseParts(model) do
			if string.find(part.Name, "^UpperTooth") then
				upper += 1
				t.eq(part.Parent, head, part.Name .. " rides the Head")
			elseif string.find(part.Name, "^LowerTooth") then
				lower += 1
				t.eq(part.Parent, jaw, part.Name .. " rides the Jaw")
			end
		end
		t.truthy(upper >= 8 and lower >= 8, "rows of teeth above (" .. upper .. ") and below (" .. lower .. ")")
		t.eq(findPart(model, "MouthCavity").Color, RIG.GrinColor, "dark mouth cavity")
	end,

	["budget: at most 220 BaseParts of the allowed classes"] = function(t: Expect)
		local parts = baseParts(rest().model)
		t.truthy(CreatureRigBuilder.PartBudget <= 220, "budget constant")
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
		}
		for _, chain in NAMES.Hair do
			t.truthy(table.isfrozen(chain), "hair chain is frozen")
			for _, name in chain do
				table.insert(partNames, name)
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
	["skin: dark, wet and glossy; the pupils the brightest thing on it"] = function(t: Expect)
		local built = rest()
		local skin = 0
		for _, part in baseParts(built.model) do
			if part.Transparency >= 1 then
				continue
			end
			if part.Material == Enum.Material.SmoothPlastic and part.Reflectance > 0 then
				skin += 1
				t.truthy(part.Reflectance <= 0.25, part.Name .. " is wet, not chrome")
			end
		end
		t.truthy(skin >= 40, string.format("the body glistens (%d glossy parts)", skin))
		local upper = findPart(built.model, "UpperTorso")
		local color = upper.Color
		t.truthy((color.R + color.G + color.B) / 3 < 0.4, "the skin is dark")
		t.truthy(upper.Reflectance >= 0.1, "the torso is wet")
		local pupil = findPart(built.model, NAMES.LeftPupil)
		t.eq(pupil.Material, Enum.Material.Neon, "the eyes glow")
	end,
}
