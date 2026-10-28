--!strict
-- ProceduralAnimator: JointMap discovery on an R15-named rig built here (standard R15 proportions: 2x2x1 root
-- 3 studs above the floor, HipHeight 2) and on the real Creature rig; joint-frame conjugation; two-bone IK (reach,
-- clamping, pole side, folding, bone rotations); the gait foot cycle (planted feet keep pace with the ground,
-- continuous through stance and swing); shared-phase continuity through speed and state changes; footstep plants;
-- pose blending and state cross-fades; every PlayerR15 state posing finite transforms; standing feet on the floor;
-- the vent crawl inside the 3.5-stud bore; downed / dead bodies above the floor; the head following the look; hand
-- IK reaching its grip target; and the LOD driver (full / every third frame / frozen).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CreatureRigBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.CreatureRigBuilder)
local IK = require(ReplicatedStorage.Shared.Animation.ProceduralAnimator.IK)
local JointMap = require(ReplicatedStorage.Shared.Animation.ProceduralAnimator.JointMap)
local PlayerR15 = require(ReplicatedStorage.Shared.Animation.ProceduralAnimator.Profiles.PlayerR15)
local ProceduralAnimator = require(ReplicatedStorage.Shared.Animation.ProceduralAnimator)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

type Expect = SpecRunner.Expect
type Animator = ProceduralAnimator.Animator

local DT = 1 / 60
local ROOT_HEIGHT = 3 -- root centre above the floor (HipHeight 2 + half the 2-stud root)
local GROUND = -ROOT_HEIGHT -- rig-space floor

type PartSpec = { name: string, size: Vector3, centre: Vector3 }
type JointSpec = { name: string, part0: string, part1: string, pivot: Vector3 }

local PART_SPECS: { PartSpec } = {
	{ name = "HumanoidRootPart", size = Vector3.new(2, 2, 1), centre = Vector3.new(0, 0, 0) },
	{ name = "LowerTorso", size = Vector3.new(2, 0.4, 1), centre = Vector3.new(0, -0.25, 0) },
	{ name = "UpperTorso", size = Vector3.new(2, 1.6, 1), centre = Vector3.new(0, 0.75, 0) },
	{ name = "Head", size = Vector3.new(1.2, 1.2, 1.2), centre = Vector3.new(0, 2.15, 0) },
}
local JOINT_SPECS: { JointSpec } = {
	{ name = "Root", part0 = "HumanoidRootPart", part1 = "LowerTorso", pivot = Vector3.new(0, -0.35, 0) },
	{ name = "Waist", part0 = "LowerTorso", part1 = "UpperTorso", pivot = Vector3.new(0, -0.05, 0) },
	{ name = "Neck", part0 = "UpperTorso", part1 = "Head", pivot = Vector3.new(0, 1.55, 0) },
}
for _, side in { "Left", "Right" } do
	local s = if side == "Left" then -1 else 1
	local function part(name: string, size: Vector3, centre: Vector3)
		table.insert(PART_SPECS, { name = side .. name, size = size, centre = centre })
	end
	local function joint(name: string, part0: string, part1: string, pivot: Vector3)
		table.insert(JOINT_SPECS, { name = side .. name, part0 = part0, part1 = side .. part1, pivot = pivot })
	end
	part("UpperArm", Vector3.new(1, 1.17, 1), Vector3.new(1.5 * s, 0.75, 0))
	part("LowerArm", Vector3.new(1, 1.05, 1), Vector3.new(1.5 * s, -0.3, 0))
	part("Hand", Vector3.new(1, 0.3, 1), Vector3.new(1.5 * s, -0.95, 0))
	part("UpperLeg", Vector3.new(1, 1.2, 1), Vector3.new(0.5 * s, -1.05, 0))
	part("LowerLeg", Vector3.new(1, 1.1, 1), Vector3.new(0.5 * s, -2.15, 0))
	part("Foot", Vector3.new(1, 0.3, 1.2), Vector3.new(0.5 * s, -2.85, -0.1))
	joint("Shoulder", "UpperTorso", "UpperArm", Vector3.new(1 * s, 1.15, 0))
	joint("Elbow", side .. "UpperArm", "LowerArm", Vector3.new(1.5 * s, 0.2, 0))
	joint("Wrist", side .. "LowerArm", "Hand", Vector3.new(1.5 * s, -0.8, 0))
	joint("Hip", "LowerTorso", "UpperLeg", Vector3.new(0.5 * s, -0.45, 0))
	joint("Knee", side .. "UpperLeg", "LowerLeg", Vector3.new(0.5 * s, -1.6, 0))
	joint("Ankle", side .. "LowerLeg", "Foot", Vector3.new(0.5 * s, -2.65, 0))
end

-- An R15-named rig whose root sits at `origin` (rig space = origin's frame). Parented to Workspace.
local function buildRig(origin: CFrame): (Model, { [string]: BasePart })
	local model = Instance.new("Model")
	model.Name = "SpecR15"
	local parts: { [string]: BasePart } = {}
	for _, spec in PART_SPECS do
		local part = Instance.new("Part")
		part.Name = spec.name
		part.Size = spec.size
		part.CFrame = origin * CFrame.new(spec.centre)
		part.Parent = model
		parts[spec.name] = part
	end
	for _, spec in JOINT_SPECS do
		local part0, part1 = parts[spec.part0], parts[spec.part1]
		local pivot = origin * CFrame.new(spec.pivot)
		local motor = Instance.new("Motor6D")
		motor.Name = spec.name
		motor.Part0 = part0
		motor.Part1 = part1
		motor.C0 = part0.CFrame:Inverse() * pivot
		motor.C1 = part1.CFrame:Inverse() * pivot
		motor.Parent = part1
	end
	local humanoid = Instance.new("Humanoid")
	humanoid.HipHeight = ROOT_HEIGHT - 1
	humanoid.Parent = model
	model.PrimaryPart = parts.HumanoidRootPart
	model.Parent = Workspace
	return model, parts
end

local ORIGIN = CFrame.new(12, 40 + ROOT_HEIGHT, -7) * CFrame.Angles(0, math.rad(35), 0)

type Rig = { model: Model, parts: { [string]: BasePart }, animator: Animator }
type Case = { state: string, speed: number }

local function animated(state: string, speed: number?, extra: ProceduralAnimator.InputPatch?): Rig
	local model, parts = buildRig(ORIGIN)
	local animator = ProceduralAnimator.new(model, PlayerR15.Profile, { seed = 7, priority = true })
	assert(animator, "the R15 rig could not be animated")
	local velocity = ORIGIN:VectorToWorldSpace(Vector3.new(0, 0, -(speed or 0)))
	animator:SetInputs({
		moveState = state,
		velocity = velocity,
		grounded = true,
		lookYaw = ProceduralAnimator.yawOf(ORIGIN),
		lookPitch = 0,
	})
	if extra then
		animator:SetInputs(extra)
	end
	return { model = model, parts = parts, animator = animator }
end

local function release(rig: Rig)
	rig.animator:Destroy()
	rig.model:Destroy()
end

local function run(animator: Animator, seconds: number)
	for _ = 1, math.floor(seconds / DT + 0.5) do
		animator:Step(DT)
	end
end

local function frameOf(rig: Rig, part: string): CFrame
	local frame = rig.animator:GetPartFrame(part)
	assert(frame, "no solved frame for " .. part)
	return frame
end

-- Lowest / highest rig-space Y of a part's box under the current pose.
local function verticalExtent(rig: Rig, part: string): (number, number)
	local frame = frameOf(rig, part)
	local half = rig.parts[part].Size * 0.5
	local reach = math.abs(frame.XVector.Y) * half.X
		+ math.abs(frame.YVector.Y) * half.Y
		+ math.abs(frame.ZVector.Y) * half.Z
	return frame.Position.Y - reach, frame.Position.Y + reach
end

local function finiteFrame(frame: CFrame): boolean
	for _, value in { frame:GetComponents() } do
		if value ~= value or math.abs(value) == math.huge then
			return false
		end
	end
	return true
end

local function near(a: Vector3, b: Vector3, epsilon: number): boolean
	return (a - b).Magnitude <= epsilon
end

local function body(rig: Rig): { string }
	local out: { string } = {}
	for name in rig.parts do
		if name ~= "HumanoidRootPart" then
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

return {
	["JointMap discovers an R15-named rig, parents before children, rest frames from C0 / C1"] = function(t: Expect)
		local model, parts = buildRig(ORIGIN)
		local map, reason = JointMap.build(model, { required = PlayerR15.Profile.required })
		t.truthy(map, "R15 map: " .. tostring(reason))
		assert(map, "map missing")
		t.eq(#map.order, 15, "joint count")
		for index, joint in map.order do
			t.eq(joint.index, index, joint.name .. " index")
			local parent = joint.parent
			if parent then
				t.truthy(map.joints[parent].index < index, joint.name .. " after its parent " .. parent)
			else
				t.eq(joint.part0Name, "HumanoidRootPart", joint.name .. " hangs off the root")
			end
			local rest = map.rest[joint.part1Name]
			local actual = ORIGIN:ToObjectSpace(parts[joint.part1Name].CFrame)
			t.truthy(near(rest.Position, actual.Position, 1e-4), joint.part1Name .. " rest position")
		end
		t.truthy(near(JointMap.pivot(map, "LeftKnee"), Vector3.new(-0.5, -1.6, 0), 1e-4), "knee pivot in rig space")
		t.near(JointMap.distance(map, "RightHip", "RightKnee"), 1.15, 1e-4, "thigh length")
		local upperArm = math.sqrt(0.5 * 0.5 + 0.95 * 0.95)
		t.near(
			JointMap.chainLength(map, { "RightShoulder", "RightElbow", "RightWrist" }),
			upperArm + 1,
			1e-3,
			"arm chain"
		)
		t.near(map.groundY, GROUND, 1e-6, "floor from the Humanoid's HipHeight")
		local measured = PlayerR15.measure(map)
		t.near(measured.leg, 1.15 + 1.05, 1e-4, "leg length")
		t.near(measured.ankle, 0.35, 1e-4, "ankle above the sole")
		t.near(measured.toe, 0.7, 1e-4, "toe ahead of the ankle")
		t.near(measured.heel, 0.5, 1e-4, "heel behind the ankle")
		t.near(measured.standHip, 2.55, 1e-4, "hip height")
		t.eq(#map.warnings, 0, "no warnings")
		t.truthy(JointMap.isIntact(map), "intact")
		model:Destroy()
	end,

	["JointMap reports a missing required joint and a broken rig"] = function(t: Expect)
		local model, parts = buildRig(ORIGIN)
		local knee = parts.LeftLowerLeg:FindFirstChild("LeftKnee")
		assert(knee, "knee missing")
		knee:Destroy()
		local map, reason = JointMap.build(model, { required = PlayerR15.Profile.required })
		t.eq(map, nil, "map refused")
		t.truthy(reason and string.find(reason, "LeftKnee", 1, true), "reason names the joint")
		t.eq(ProceduralAnimator.missingJoints(model, PlayerR15.Profile)[1], "LeftKnee", "missingJoints")
		local animator, why = ProceduralAnimator.new(model, PlayerR15.Profile)
		t.eq(animator, nil, "no animator without the joint")
		t.truthy(why, "reason given")
		model:Destroy()
	end,

	["JointMap maps the Creature rig's R15, Jaw and hair joints"] = function(t: Expect)
		local folder = Instance.new("Folder")
		folder.Parent = Workspace
		local creature = CreatureRigBuilder.build(folder, CFrame.new(5, 10, 5) * CFrame.Angles(0, 1, 0))
		local names: { string } = {}
		for _, spec in CreatureRigBuilder.Joints do
			table.insert(names, spec.name)
		end
		local map, reason = JointMap.build(creature, { required = names })
		t.truthy(map, "creature map: " .. tostring(reason))
		assert(map, "map missing")
		t.eq(#map.order, #CreatureRigBuilder.Joints, "every creature joint found")
		local root = creature:FindFirstChild("HumanoidRootPart") :: BasePart
		for _, joint in map.order do
			local actual = root.CFrame:ToObjectSpace(joint.part1.CFrame)
			t.truthy(near(map.rest[joint.part1Name].Position, actual.Position, 2e-3), joint.name .. " rest")
			t.truthy(IK.angleOf(joint.axes) < 1e-3, joint.name .. " joint frame aligned with the rig")
		end
		local arm = JointMap.chainLength(map, { "RightShoulder", "RightElbow", "RightWrist" })
		t.truthy(arm > 2, "long creature arm chain")
		folder:Destroy()
	end,

	["toTransform turns rig-axes entries into tilted joint frames"] = function(t: Expect)
		-- Two parts, the joint frame yawed 90 degrees: a rig-axes pitch must still swing the child about rig X.
		local model = Instance.new("Model")
		local a = Instance.new("Part")
		a.Name = "HumanoidRootPart"
		a.Size = Vector3.new(1, 1, 1)
		a.CFrame = CFrame.new()
		a.Parent = model
		local b = Instance.new("Part")
		b.Name = "Arm"
		b.Size = Vector3.new(0.5, 2, 0.5)
		b.CFrame = CFrame.new(0, -1.5, 0)
		b.Parent = model
		local frame = CFrame.new(0, -0.5, 0) * CFrame.Angles(0, math.pi / 2, 0)
		local motor = Instance.new("Motor6D")
		motor.Name = "Joint"
		motor.Part0 = a
		motor.Part1 = b
		motor.C0 = a.CFrame:Inverse() * frame
		motor.C1 = b.CFrame:Inverse() * frame
		motor.Parent = b
		local map = JointMap.build(model)
		assert(map, "map missing")
		local joint = map.joints.Joint
		local entry = CFrame.Angles(math.rad(30), 0, 0)
		local transform = JointMap.toTransform(joint, entry)
		local child = JointMap.childFrame(joint, CFrame.identity, transform)
		local expected = CFrame.new(0, -0.5, 0) * entry * CFrame.new(0, -1, 0)
		t.truthy(near(child.Position, expected.Position, 1e-4), "child swung about rig X")
		local back = JointMap.fromTransform(joint, transform)
		t.truthy(IK.angleOf(back:Inverse() * entry) < 1e-4, "fromTransform inverts toTransform")
		model:Destroy()
	end,

	["IK reaches targets within reach with exact bone lengths"] = function(t: Expect)
		local origin = Vector3.new(1, 2, 3)
		local targets: { Vector3 } = {
			Vector3.new(1, 0.5, 2.2),
			Vector3.new(2.2, 1.4, 3.1),
			Vector3.new(0.4, 3.1, 2.5),
			Vector3.new(1, 2.9, 3),
		}
		for index, target in targets do
			local solution = IK.solveTwoBone(origin, target, 1.17, 1.05, Vector3.new(0, 0, 1))
			t.truthy(solution.reached, "target " .. index .. " reachable")
			t.truthy(near(solution.tip, target, 1e-4), "tip on target " .. index)
			t.near((solution.mid - origin).Magnitude, 1.17, 1e-4, "upper bone " .. index)
			t.near((solution.tip - solution.mid).Magnitude, 1.05, 1e-4, "lower bone " .. index)
		end
	end,

	["IK clamps unreachable targets onto the reach shell, along the same line"] = function(t: Expect)
		local origin = Vector3.zero
		local far = Vector3.new(0, -10, 2)
		local solution = IK.solveTwoBone(origin, far, 1.2, 1.1, Vector3.new(0, 0, -1))
		t.falsy(solution.reached, "flagged as clamped")
		t.near(solution.distance, 2.3 * IK.ReachMargin, 1e-4, "clamped to the reach margin")
		t.truthy(solution.tip.Unit:Dot(far.Unit) > 1 - 1e-6, "same direction")
		local close = IK.solveTwoBone(origin, Vector3.new(0, -0.01, 0), 1.2, 1.1, Vector3.new(0, 0, -1))
		t.falsy(close.reached, "too close is clamped too")
		t.truthy(close.distance >= 0.1 * 2.3 * IK.FoldMargin, "never folded flat")
		local onOrigin = IK.solveTwoBone(origin, origin, 1, 1, Vector3.new(0, 0, -1))
		t.truthy(onOrigin.distance > 0 and onOrigin.mid == onOrigin.mid, "a target on the origin still solves")
	end,

	["IK bends toward the pole and falls back when the pole is parallel"] = function(t: Expect)
		local origin = Vector3.zero
		local target = Vector3.new(0, -1.6, 0)
		for _, pole in { Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), Vector3.new(0.3, -0.2, 0.9) } do
			local solution = IK.solveTwoBone(origin, target, 1.2, 1.1, pole)
			local side = solution.mid - Vector3.new(0, solution.mid.Y, 0)
			t.truthy(side:Dot(pole) > 0, "middle joint on the pole side")
			t.near(solution.bend:Dot(target.Unit), 0, 1e-6, "bend direction perpendicular to the chain")
		end
		local parallel = IK.solveTwoBone(origin, target, 1.2, 1.1, Vector3.new(0, -1, 0))
		t.truthy(parallel.mid == parallel.mid and math.abs(parallel.bend:Dot(target.Unit)) < 1e-6, "fallback bend")
	end,

	["boneRotation maps axis and hint; aim is the smallest turn; limitRotation caps the angle"] = function(t: Expect)
		local restAxis = Vector3.new(0, -1, 0)
		local restHint = Vector3.new(0, 0, -1)
		local newAxis = Vector3.new(0.3, -0.5, -0.8).Unit
		local newHint = Vector3.new(0, 1, -0.4)
		local rotation = IK.boneRotation(restAxis, restHint, newAxis, newHint)
		t.truthy(near(rotation * restAxis, newAxis, 1e-5), "axis mapped")
		local hint = rotation * restHint
		t.truthy(hint:Dot(newHint) > 0 and math.abs(hint:Dot(newAxis)) < 1e-5, "hint turned toward the new hint")
		local from = Vector3.new(1, 0, 0)
		local to = Vector3.new(0, 1, 1).Unit
		local turn = IK.aim(from, to)
		t.truthy(near(turn * from, to, 1e-5), "aim maps from onto to")
		t.near(IK.angleOf(turn), math.pi / 2, 1e-5, "smallest angle")
		t.truthy(near(IK.aim(from, -from) * from, -from, 1e-5), "opposite directions")
		local capped = IK.limitRotation(CFrame.Angles(0, math.rad(100), 0), math.rad(30))
		t.near(IK.angleOf(capped), math.rad(30), 1e-5, "capped")
		t.near(IK.angleOf(IK.limitRotation(CFrame.Angles(0.2, 0, 0), 1)), 0.2, 1e-5, "under the cap unchanged")
		t.near(IK.jointAngle(1, 1, 2), math.pi, 1e-6, "straight chain interior angle")
	end,

	["footCycle keeps the planted foot at ground speed and is continuous"] = function(t: Expect)
		local params: ProceduralAnimator.StepParams =
			{ duty = 0.4, lift = 0.5, liftPeak = 0.35, strike = 0.2, toeOff = -0.5 }
		local stance = 2.4
		local samples = 400
		local previous = ProceduralAnimator.footCycle(0, stance, params)
		t.near(previous.along, stance / 2, 1e-9, "contact at the front of the stance")
		local maxLift = 0
		for index = 1, samples do
			local p = index / samples
			local cycle = ProceduralAnimator.footCycle(p, stance, params)
			if cycle.stance and previous.stance then
				-- Studs per unit phase: exactly -stance / duty (the body's travel during the stance).
				t.near((cycle.along - previous.along) * samples, -stance / params.duty, 1e-6, "planted at " .. p)
				t.eq(cycle.lift, 0, "planted feet stay down")
			end
			t.truthy(math.abs(cycle.along - previous.along) < stance * 0.05, "continuous along at " .. p)
			t.truthy(math.abs(cycle.lift - previous.lift) < params.lift * 0.05, "continuous lift at " .. p)
			maxLift = math.max(maxLift, cycle.lift)
			previous = cycle
		end
		t.near(maxLift, params.lift, 0.01, "swing reaches its clearance")
		t.near(ProceduralAnimator.footCycle(0.9999, stance, params).along, stance / 2, 1e-3, "swing ends at contact")
		local swing = ProceduralAnimator.footCycle(0.4 + 0.6 * 0.35, stance, params)
		t.near(swing.lift, params.lift, 1e-3, "highest at liftPeak")
		t.near(ProceduralAnimator.ankleLift(0, 0.35, 0.5, 0.7), 0, 1e-9, "flat foot: no ankle lift")
		t.truthy(ProceduralAnimator.ankleLift(-0.5, 0.35, 0.5, 0.7) > 0.25, "toe pivot lifts the ankle")
	end,

	["crossed and lodTier"] = function(t: Expect)
		t.truthy(ProceduralAnimator.crossed(0.9, 1.1, 0), "wraps through 0")
		t.truthy(ProceduralAnimator.crossed(0.4, 0.5, 0.5), "lands on the mark")
		t.falsy(ProceduralAnimator.crossed(0.5, 0.6, 0.5), "starting on the mark does not count")
		t.falsy(ProceduralAnimator.crossed(0.6, 0.6, 0.6), "no movement")
		t.eq(ProceduralAnimator.lodTier(10, 60, 180), "Full")
		t.eq(ProceduralAnimator.lodTier(60, 60, 180), "Full")
		t.eq(ProceduralAnimator.lodTier(61, 60, 180), "Reduced")
		t.eq(ProceduralAnimator.lodTier(181, 60, 180), "Frozen")
	end,

	["blend normalizes weights and treats missing joints as identity"] = function(t: Expect)
		local a: ProceduralAnimator.Pose = { Waist = CFrame.Angles(0.4, 0, 0), Neck = CFrame.Angles(0, 0.6, 0) }
		local b: ProceduralAnimator.Pose = { Waist = CFrame.Angles(-0.4, 0, 0), Root = CFrame.new(0, -1, 0) }
		local only = ProceduralAnimator.blend({ a, b }, { 1, 0 })
		t.eq(only.Waist, a.Waist, "zero weight ignored")
		t.eq(only.Root, nil, "nothing from the zero-weight pose")
		local half = ProceduralAnimator.blend({ a, b }, { 2, 2 })
		t.near(IK.angleOf(half.Waist), 0, 1e-5, "even blend meets in the middle")
		t.near(IK.angleOf(half.Neck), 0.3, 1e-5, "missing joint blends toward identity")
		t.near(half.Root.Position.Y, -0.5, 1e-5, "translation blends")
		local quarter = ProceduralAnimator.blend({ a, b }, { 1, 3 })
		local x = quarter.Waist:ToEulerAnglesXYZ()
		t.near(x, -0.2, 1e-5, "weights 1:3")
	end,

	["the shared phase advances continuously through speed and state changes"] = function(t: Expect)
		local rig = animated("Standing", 0)
		local states = { "Standing", "Sprinting", "Crouching", "Standing", "VentCrawling", "Standing" }
		local speeds = { 4, 19, 5.5, 11, 4.5, 0 }
		local last = rig.animator:GetPhase()
		local largest = 0
		for index, state in states do
			rig.animator:SetInputs({
				moveState = state,
				velocity = ORIGIN:VectorToWorldSpace(Vector3.new(0, 0, -speeds[index])),
			})
			for _ = 1, 50 do
				rig.animator:Step(DT)
				local phase = rig.animator:GetPhase()
				local delta = (phase - last) % 1
				largest = math.max(largest, delta)
				last = phase
			end
		end
		t.truthy(largest < 0.1, "no phase jumps (largest step " .. largest .. ")")
		release(rig)
	end,

	["planted feet keep pace with the ground and stay on the floor"] = function(t: Expect)
		local speed = 11
		local rig = animated("Standing", speed)
		run(rig.animator, 2)
		local checked = 0
		local previous = frameOf(rig, "LeftFoot")
		local lastPhase = rig.animator:GetPhase()
		local duty = PlayerR15.gait("Standing", speed, rig.animator.Map)
		for _ = 1, 120 do
			rig.animator:Step(DT)
			local frame = frameOf(rig, "LeftFoot")
			local phase = rig.animator:GetPhase()
			-- Mid-stance of the left foot (contact at phase 0), away from the heel and toe pivots.
			local u = phase / duty
			local lastU = lastPhase / duty
			if u > 0.2 and u < 0.55 and lastU > 0.2 and lastU < 0.55 then
				checked += 1
				local slide = (frame.Position - previous.Position) / DT
				t.near(slide.Z, speed, 0.25, "foot moves back at ground speed")
				t.near(slide.X, 0, 0.25, "no sideways slide")
				local low = verticalExtent(rig, "LeftFoot")
				t.near(low, GROUND, 0.06, "sole on the floor")
			end
			previous = frame
			lastPhase = phase
		end
		t.truthy(checked >= 4, "mid-stance samples checked: " .. checked)
		release(rig)
	end,

	["footsteps land twice a cycle, quieter crouched, none crawling"] = function(t: Expect)
		local function count(state: string, speed: number): (number, number, number)
			local rig = animated(state, speed)
			local steps, volume = 0, 0
			rig.animator.Footstep:Connect(function(event: ProceduralAnimator.FootstepEvent)
				steps += 1
				volume = event.volume
			end)
			run(rig.animator, 1)
			local phase = rig.animator:GetPhase()
			local cycles = 0
			local before = steps
			for _ = 1, 180 do
				rig.animator:Step(DT)
				local now = rig.animator:GetPhase()
				if now < phase then
					cycles += 1
				end
				phase = now
			end
			release(rig)
			return steps - before, cycles, volume
		end
		local walk, walkCycles, walkVolume = count("Standing", 11)
		t.truthy(math.abs(walk - 2 * walkCycles) <= 1, "two steps per cycle walking")
		t.near(walkVolume, 1, 1e-6, "full volume walking")
		local _, _, crouchVolume = count("Crouching", 5.5)
		t.near(crouchVolume, 0.45, 1e-6, "crouched steps are quiet")
		local crawl = count("VentCrawling", 4.5)
		t.eq(crawl, 0, "no footsteps crawling")
	end,

	["every PlayerR15 state poses finite transforms on every joint"] = function(t: Expect)
		local speeds: { [string]: number } = {
			Sprinting = 19,
			Crouching = 5.5,
			VentCrawling = 4.5,
			VentScurrying = 9,
			DownedCrawling = 2.5,
			Freestyle = 9,
			Underwater = 5,
			Treading = 2,
		}
		for name in PlayerR15.Profile.states do
			local rig = animated(name, speeds[name] or 0)
			run(rig.animator, 1.2)
			t.eq(rig.animator:GetState(), name, name .. " reached")
			for _, joint in rig.animator.Map.order do
				local motor = joint.motor
				assert(motor, "motor missing")
				t.truthy(finiteFrame(motor.Transform), name .. " " .. joint.name .. " transform finite")
			end
			release(rig)
		end
	end,

	["standing still: soft knees, both soles on the floor"] = function(t: Expect)
		for _, state in { "Standing", "Crouching", "Scripted", "Hiding" } do
			local rig = animated(state, 0)
			run(rig.animator, 1.5)
			for _, foot in { "LeftFoot", "RightFoot" } do
				local low = verticalExtent(rig, foot)
				t.near(low, GROUND, 0.06, state .. " " .. foot .. " on the floor")
			end
			local hip = frameOf(rig, "LowerTorso").Position.Y
			t.truthy(hip < -0.25, state .. " pelvis settles below its rest height")
			release(rig)
		end
	end,

	["the vent crawl fits inside the bore"] = function(t: Expect)
		local half = WorldConfig.VentBore / 2
		local cases: { Case } = {
			{ state = "VentCrawling", speed = 4.5 },
			{ state = "VentScurrying", speed = 9 },
			{ state = "VentCrawling", speed = 0 },
		}
		for _, case in cases do
			local state, speed = case.state, case.speed
			local rig = animated(state, speed)
			run(rig.animator, 1.5)
			for _ = 1, 40 do
				rig.animator:Step(DT)
				for _, part in body(rig) do
					local low, high = verticalExtent(rig, part)
					t.truthy(low >= -half - 0.12, string.format("%s %s above the bore floor (%.2f)", state, part, low))
					t.truthy(high <= half + 0.05, string.format("%s %s under the bore top (%.2f)", state, part, high))
				end
			end
			local neck = rig.animator:GetPartFrame("Head")
			assert(neck, "neck missing")
			t.truthy(neck.Position.Z < 0.6, state .. " head leads the body")
			release(rig)
		end
	end,

	["downed and dead bodies lie on the floor without sinking into it"] = function(t: Expect)
		local cases: { Case } = {
			{ state = "DownedCrawling", speed = 2.5 },
			{ state = "DownedCrawling", speed = 0 },
			{ state = "Dead", speed = 0 },
		}
		for _, case in cases do
			local state, speed = case.state, case.speed
			local rig = animated(state, speed)
			run(rig.animator, 2)
			for _ = 1, 30 do
				rig.animator:Step(DT)
				for _, part in { "LowerTorso", "UpperTorso" } do
					local low = verticalExtent(rig, part)
					t.truthy(low >= GROUND + 0.05, string.format("%s %s clears the floor (%.2f)", state, part, low))
				end
			end
			local pelvis = frameOf(rig, "LowerTorso").Position.Y
			t.truthy(pelvis < GROUND + 1, state .. " pelvis on the floor")
			release(rig)
		end
		-- The downed head sits where the downed camera does (CameraConfig: about 0.8 under the root).
		local downed = animated("DownedCrawling", 0)
		run(downed.animator, 2)
		local head = frameOf(downed, "Head").Position
		t.truthy(head.Y > -1.4 and head.Y < 0, "downed head height " .. head.Y)
		release(downed)
	end,

	["the head follows the look within the neck's limits"] = function(t: Expect)
		local yaw = ProceduralAnimator.yawOf(ORIGIN)
		local rig = animated("Standing", 0, { lookPitch = -0.6, lookYaw = yaw + 0.5 })
		run(rig.animator, 1.5)
		local head = frameOf(rig, "Head")
		local headYaw = math.atan2(-head.LookVector.X, -head.LookVector.Z)
		local headPitch = math.asin(head.LookVector.Y)
		t.near(headPitch, -0.6, 0.03, "head pitch")
		t.near(headYaw, 0.5, 0.03, "head yaw relative to the body")
		local chest = frameOf(rig, "UpperTorso")
		t.truthy(chest.LookVector.Y < -0.05, "the upper body takes a share of the pitch")
		rig.animator:SetInputs({ lookPitch = 1.4 })
		run(rig.animator, 1.5)
		local up = frameOf(rig, "Head")
		local chestUp = frameOf(rig, "UpperTorso")
		local relative = (chestUp.Rotation:Inverse() * up.Rotation):ToEulerAnglesYXZ()
		t.truthy(relative <= PlayerR15.Profile.look.pitchUp + 0.02, "neck limit respected")
		release(rig)
	end,

	["hand IK reaches the grip target and lets go smoothly"] = function(t: Expect)
		local rig = animated("Standing", 0)
		local root = rig.parts.HumanoidRootPart
		local grip = root.CFrame * CFrame.new(0.55, 0.55, -1.5) * CFrame.Angles(math.rad(-5), math.rad(8), 0)
		rig.animator:SetHandTarget("Right", grip)
		rig.animator:SetHandGrip("Right", 1)
		run(rig.animator, 1.5)
		local hand = root.CFrame * frameOf(rig, "RightHand") * PlayerR15.Grip
		t.truthy(near(hand.Position, grip.Position, 0.05), "grip point on target")
		t.truthy(hand.LookVector:Dot(grip.LookVector) > 0.97, "held item points along the target")
		local held = frameOf(rig, "RightHand").Position
		rig.animator:SetHandTarget("Right", nil)
		rig.animator:Step(DT)
		local afterOne = frameOf(rig, "RightHand").Position
		t.truthy((afterOne - held).Magnitude < 0.25, "no snap on release")
		run(rig.animator, 1)
		local free = frameOf(rig, "RightHand").Position
		t.truthy((free - held).Magnitude > 0.5, "the arm returns to the animation")
		-- Crawling keeps both hands on the floor even while a hand target is held.
		rig.animator:SetHandTarget("Right", grip)
		rig.animator:SetInputs({ moveState = "VentCrawling" })
		run(rig.animator, 2)
		local crawling = root.CFrame * frameOf(rig, "RightHand") * PlayerR15.Grip
		t.truthy((crawling.Position - grip.Position).Magnitude > 0.5, "the crawl wins over the hand target")
		t.truthy(frameOf(rig, "RightHand").Position.Y < -0.8, "the hand is down on the bore floor")
		release(rig)
	end,

	["the driver steps near rigs every frame, mid rigs every third frame, far rigs never"] = function(t: Expect)
		local near0 = animated("Standing", 0)
		local mid = animated("Standing", 0)
		local far = animated("Standing", 0)
		local counts = { near = 0, mid = 0, far = 0 }
		near0.animator:SetPriority(false)
		mid.animator:SetPriority(false)
		far.animator:SetPriority(false)
		near0.animator:SetInputProvider(function()
			counts.near += 1
		end)
		mid.animator:SetInputProvider(function()
			counts.mid += 1
		end)
		far.animator:SetInputProvider(function()
			counts.far += 1
		end)
		local root = ORIGIN.Position
		mid.parts.HumanoidRootPart.CFrame = ORIGIN + Vector3.new(100, 0, 0)
		far.parts.HumanoidRootPart.CFrame = ORIGIN + Vector3.new(400, 0, 0)
		local oldNear, oldFar = ProceduralAnimator.GetLod()
		ProceduralAnimator.SetLod(60, 180)
		ProceduralAnimator.SetFocus(function(): Vector3?
			return root
		end)
		for _ = 1, 9 do
			ProceduralAnimator.Step(DT)
		end
		t.eq(counts.near, 9, "full rate")
		t.eq(counts.mid, 3, "every third frame")
		t.eq(counts.far, 0, "frozen")
		ProceduralAnimator.SetFocus(nil)
		ProceduralAnimator.SetLod(oldNear, oldFar)
		release(near0)
		release(mid)
		release(far)
	end,
}
