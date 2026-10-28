--!strict
-- JointMap: a rig's joint tree, discovered by name, with everything the animator needs at rest.
--
-- Discovery. Every Motor6D under the rig whose Part0 and Part1 are BaseParts of the rig, and every
-- AnimationConstraint whose two Attachments sit on BaseParts of the rig, becomes a Joint named after the instance
-- (R15: "Root", "Waist", "Neck", "LeftShoulder", ...; the Creature adds "Jaw" and "Hair<N>_<M>"). Joints are ordered
-- breadth-first from the root part (HumanoidRootPart, else the PrimaryPart), so walking `order` always visits a
-- parent before its children. Joints that do not hang off the root, duplicate names and second joints driving an
-- already-driven part are left out (listed in `warnings`).
--
-- Joint frames. Roblox poses Part1 = Part0 * C0 * Transform * C1:Inverse() (an AnimationConstraint uses
-- Attachment0.CFrame / Attachment1.CFrame for C0 / C1). `rest[part]` is each part's CFrame in rig space (the root
-- part's own frame) with every Transform at identity; it comes from C0 / C1 only, so a rig that is already being
-- animated maps the same way. Each joint keeps its rest pivot and `axes`: the rotation of its joint frame
-- (rest[Part0] * C0) in rig space. `toTransform` uses it to turn a pose entry written in *rig axes* (X right, Y up,
-- -Z forward, as if the parent part were at rest; translation in the same axes) into the joint-frame Transform:
--     Transform = axes^-1 * entry * axes
-- so a profile reads the same on a rig whose joint frames are tilted (the conjugation is the identity for R15 and
-- the Creature, whose joint frames are axis-aligned at rest).
--
-- Ground. A rig with a Humanoid stands where the Humanoid keeps it: `groundY` = -(HipHeight + root height / 2) in
-- rig space. Without a Humanoid (or a zero HipHeight) the lowest corner of any jointed part at rest is the floor.

local JointMap = {}

export type Joint = {
	name: string,
	motor: Motor6D?,
	constraint: AnimationConstraint?,
	part0: BasePart,
	part1: BasePart,
	part0Name: string,
	part1Name: string,
	c0: CFrame, -- joint frame in Part0's space
	c1: CFrame, -- joint frame in Part1's space
	c1Inverse: CFrame,
	axes: CFrame, -- rotation of the rest joint frame in rig space
	axesInverse: CFrame,
	pivot: Vector3, -- rest pivot in rig space
	parent: string?, -- the joint driving Part0 (nil when Part0 is the root part)
	children: { string },
	index: number, -- position in `order`
}

export type JointMap = {
	rig: Model,
	root: BasePart,
	rootName: string,
	joints: { [string]: Joint },
	order: { Joint }, -- parents before children
	parts: { [string]: BasePart }, -- the root part and every jointed part, by name
	rest: { [string]: CFrame }, -- each part's rest CFrame in rig space
	restRotationInverse: { [string]: CFrame }, -- rest[part].Rotation:Inverse(), cached
	drivenBy: { [string]: string }, -- part name -> the joint whose Part1 it is
	groundY: number, -- rig-space floor height at rest
	hipHeight: number?, -- Humanoid.HipHeight when the rig has a Humanoid
	warnings: { string },
}

export type Options = {
	root: string?, -- root part name (default HumanoidRootPart, then the PrimaryPart)
	required: { string }?, -- joint names that must be present
}

local DEFAULT_ROOT = "HumanoidRootPart"

local function isRigPart(rig: Model, instance: Instance?): boolean
	return instance ~= nil and instance:IsA("BasePart") and instance:IsDescendantOf(rig)
end

type Candidate = {
	name: string,
	motor: Motor6D?,
	constraint: AnimationConstraint?,
	part0: BasePart,
	part1: BasePart,
	c0: CFrame,
	c1: CFrame,
}

local function candidates(rig: Model, warnings: { string }): { Candidate }
	local found: { Candidate } = {}
	for _, descendant in rig:GetDescendants() do
		if descendant:IsA("Motor6D") then
			local part0 = descendant.Part0
			local part1 = descendant.Part1
			if part0 and part1 and isRigPart(rig, part0) and isRigPart(rig, part1) and part0 ~= part1 then
				table.insert(found, {
					name = descendant.Name,
					motor = descendant,
					constraint = nil,
					part0 = part0,
					part1 = part1,
					c0 = descendant.C0,
					c1 = descendant.C1,
				})
			end
		elseif descendant:IsA("AnimationConstraint") then
			local a0 = descendant.Attachment0
			local a1 = descendant.Attachment1
			local part0 = if a0 then a0.Parent else nil
			local part1 = if a1 then a1.Parent else nil
			if a0 and a1 and part0 and part1 and isRigPart(rig, part0) and isRigPart(rig, part1) and part0 ~= part1 then
				table.insert(found, {
					name = descendant.Name,
					motor = nil,
					constraint = descendant,
					part0 = part0 :: BasePart,
					part1 = part1 :: BasePart,
					c0 = a0.CFrame,
					c1 = a1.CFrame,
				})
			else
				table.insert(warnings, "AnimationConstraint " .. descendant.Name .. " is not between two rig parts")
			end
		end
	end
	return found
end

local function lowestCorner(cframe: CFrame, size: Vector3): number
	local half = size * 0.5
	local lowest = math.huge
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local corner = cframe * Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)
				lowest = math.min(lowest, corner.Y)
			end
		end
	end
	return lowest
end

-- Builds the joint map of `rig`. Returns nil and a reason when the rig has no root part or misses a required joint.
function JointMap.build(rig: Model, options: Options?): (JointMap?, string?)
	local opts: Options = options or {}
	local rootName = opts.root or DEFAULT_ROOT
	local rootInstance = rig:FindFirstChild(rootName)
	local root: BasePart? = if rootInstance and rootInstance:IsA("BasePart") then rootInstance else rig.PrimaryPart
	if not root then
		return nil, "no root part " .. rootName
	end
	local warnings: { string } = {}
	local pending = candidates(rig, warnings)

	local joints: { [string]: Joint } = {}
	local order: { Joint } = {}
	local parts: { [string]: BasePart } = { [root.Name] = root }
	local rest: { [string]: CFrame } = { [root.Name] = CFrame.identity }
	local drivenBy: { [string]: string } = {}
	local placed: { [BasePart]: boolean } = { [root] = true }
	local partJoint: { [BasePart]: string } = {}

	-- Breadth-first from the root: each pass adopts every candidate whose Part0 is already placed.
	local frontier: { BasePart } = { root }
	while #frontier > 0 do
		local nextFrontier: { BasePart } = {}
		for _, parent in frontier do
			for index = #pending, 1, -1 do
				local candidate = pending[index]
				if candidate.part0 ~= parent then
					continue
				end
				table.remove(pending, index)
				if placed[candidate.part1] then
					table.insert(warnings, "joint " .. candidate.name .. " drives an already-driven part")
					continue
				end
				if joints[candidate.name] then
					table.insert(warnings, "duplicate joint name " .. candidate.name)
					continue
				end
				local part0Name = candidate.part0.Name
				local part1Name = candidate.part1.Name
				if parts[part1Name] and parts[part1Name] ~= candidate.part1 then
					table.insert(warnings, "duplicate part name " .. part1Name)
					continue
				end
				local parentRest = rest[part0Name]
				local frame = parentRest * candidate.c0
				local axes = frame.Rotation
				local joint: Joint = {
					name = candidate.name,
					motor = candidate.motor,
					constraint = candidate.constraint,
					part0 = candidate.part0,
					part1 = candidate.part1,
					part0Name = part0Name,
					part1Name = part1Name,
					c0 = candidate.c0,
					c1 = candidate.c1,
					c1Inverse = candidate.c1:Inverse(),
					axes = axes,
					axesInverse = axes:Inverse(),
					pivot = frame.Position,
					parent = partJoint[candidate.part0],
					children = {},
					index = #order + 1,
				}
				joints[joint.name] = joint
				table.insert(order, joint)
				parts[part1Name] = candidate.part1
				rest[part1Name] = frame * candidate.c1:Inverse()
				drivenBy[part1Name] = joint.name
				placed[candidate.part1] = true
				partJoint[candidate.part1] = joint.name
				local parentJoint = joint.parent
				if parentJoint then
					table.insert(joints[parentJoint].children, joint.name)
				end
				table.insert(nextFrontier, candidate.part1)
			end
		end
		frontier = nextFrontier
	end
	for _, candidate in pending do
		table.insert(warnings, "joint " .. candidate.name .. " does not hang off " .. root.Name)
	end

	local required: { string } = opts.required or {}
	for _, name in required do
		if joints[name] == nil then
			return nil, "missing joint " .. name
		end
	end

	local restRotationInverse: { [string]: CFrame } = {}
	for name, frame in rest do
		restRotationInverse[name] = frame.Rotation:Inverse()
	end

	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	local hipHeight: number? = if humanoid then humanoid.HipHeight else nil
	local groundY: number
	if hipHeight and hipHeight > 0 then
		groundY = -(hipHeight + root.Size.Y / 2)
	else
		groundY = 0
		local lowest = math.huge
		for name, part in parts do
			if part ~= root then
				lowest = math.min(lowest, lowestCorner(rest[name], part.Size))
			end
		end
		if lowest < math.huge then
			groundY = lowest
		else
			groundY = -root.Size.Y / 2
		end
	end

	local map: JointMap = {
		rig = rig,
		root = root,
		rootName = root.Name,
		joints = joints,
		order = order,
		parts = parts,
		rest = rest,
		restRotationInverse = restRotationInverse,
		drivenBy = drivenBy,
		groundY = groundY,
		hipHeight = hipHeight,
		warnings = warnings,
	}
	return map, nil
end

-- Names in `names` that `map` lacks.
function JointMap.missing(map: JointMap, names: { string }): { string }
	local out: { string } = {}
	for _, name in names do
		if map.joints[name] == nil then
			table.insert(out, name)
		end
	end
	return out
end

-- Rest pivot of joint `name` in rig space.
function JointMap.pivot(map: JointMap, name: string): Vector3
	local joint = map.joints[name]
	assert(joint, "no joint " .. name)
	return joint.pivot
end

-- Distance between two joints' rest pivots (a bone length when `b` is a child of `a`).
function JointMap.distance(map: JointMap, a: string, b: string): number
	return (JointMap.pivot(map, b) - JointMap.pivot(map, a)).Magnitude
end

-- Total bone length along a chain of joint names (pivot to pivot).
function JointMap.chainLength(map: JointMap, names: { string }): number
	local total = 0
	for index = 2, #names do
		total += JointMap.distance(map, names[index - 1], names[index])
	end
	return total
end

-- Rest CFrame of a part in rig space.
function JointMap.restFrame(map: JointMap, part: string): CFrame
	local frame = map.rest[part]
	assert(frame, "no part " .. part)
	return frame
end

-- Rest size of a jointed part.
function JointMap.partSize(map: JointMap, part: string): Vector3
	local instance = map.parts[part]
	assert(instance, "no part " .. part)
	return instance.Size
end

-- Lowest rig-space height of a part's box at rest.
function JointMap.lowestPoint(map: JointMap, part: string): number
	return lowestCorner(JointMap.restFrame(map, part), JointMap.partSize(map, part))
end

-- A part's box extent along a rig-space axis at rest, measured from `point`: (furthest behind, furthest ahead) as
-- distances along `axis` (negative = behind `point`).
function JointMap.extentAlong(map: JointMap, part: string, point: Vector3, axis: Vector3): (number, number)
	local frame = JointMap.restFrame(map, part)
	local half = JointMap.partSize(map, part) * 0.5
	local low, high = math.huge, -math.huge
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local corner = frame * Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)
				local along = (corner - point):Dot(axis)
				low = math.min(low, along)
				high = math.max(high, along)
			end
		end
	end
	return low, high
end

-- The joint-frame Transform for a pose entry written in rig axes (see the header).
function JointMap.toTransform(joint: Joint, entry: CFrame): CFrame
	return joint.axesInverse * entry * joint.axes
end

-- The rig-axes entry a joint-frame Transform stands for (inverse of toTransform).
function JointMap.fromTransform(joint: Joint, transform: CFrame): CFrame
	return joint.axes * transform * joint.axesInverse
end

-- Writes a Transform to the joint's Motor6D or AnimationConstraint.
function JointMap.write(joint: Joint, transform: CFrame)
	local motor = joint.motor
	if motor then
		motor.Transform = transform
		return
	end
	local constraint = joint.constraint
	if constraint then
		constraint.Transform = transform
	end
end

-- Rig-space CFrame of Part1 for a given Transform and Part0 frame (the engine's joint equation).
function JointMap.childFrame(joint: Joint, parentFrame: CFrame, transform: CFrame): CFrame
	return parentFrame * joint.c0 * transform * joint.c1Inverse
end

-- True while every joint instance is still in the rig (a respawned or broken rig needs a new map).
function JointMap.isIntact(map: JointMap): boolean
	if map.root.Parent == nil or not map.root:IsDescendantOf(map.rig) then
		return false
	end
	for _, joint in map.order do
		local instance: Instance? = joint.motor or joint.constraint
		if instance == nil or instance.Parent == nil or not instance:IsDescendantOf(map.rig) then
			return false
		end
	end
	return true
end

return table.freeze(JointMap)
