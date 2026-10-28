--!strict
-- The Creature's animation on its real rig (CreatureRigBuilder.build): state resolution from the replicated
-- attributes; every profile state posing finite transforms through a full cycle; joints that only rotate (no
-- stretched limbs: translation only where the profile shifts the body, cranes the neck or shrugs a shoulder); the
-- biped's feet on the floor and its claws above it; planted feet and claws keeping pace with the ground; the
-- quadruped crawl, the stunned retreat and a lunge inside the 3.5 x 3.5 duct bore around the centreline (transforms
-- applied down the joint tree: Part1 = Part0 * C0 * Transform * C1^-1, welded details carried by their limb); the
-- NeckSnap turning the head to face straight behind and back; the Lunge's reach and jaw; every action on two-legged
-- and four-legged bases; seeded twitches and growls as pure functions of time; and CreatureController's pure rules.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Creature = require(ReplicatedStorage.Shared.Animation.ProceduralAnimator.Profiles.Creature)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local CreatureController = require(StarterPlayer.StarterPlayerScripts.Controllers.Characters.CreatureController)
local CreatureRigBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.CreatureRigBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local ProceduralAnimator = require(ReplicatedStorage.Shared.Animation.ProceduralAnimator)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

type Expect = SpecRunner.Expect
type Animator = ProceduralAnimator.Animator

local DT = 1 / 60
local BORE_HALF = WorldConfig.VentBore / 2
-- A raised, turned spawn point, so nothing passes by being axis-aligned.
local BASE = CFrame.new(-23, 17.5, 41) * CFrame.Angles(0, math.rad(-63), 0)
local NAMES = CreatureRigBuilder.PartNames

-- A typical travel speed for each state (studs/s).
local SPEEDS: { [string]: number } = {
	Dormant = 0,
	Patrol = CreatureConfig.Speeds.Patrol,
	Investigate = CreatureConfig.Speeds.InvestigateNoise,
	Chase = CreatureConfig.Speeds.WallChase,
	VentCrawl = CreatureConfig.Speeds.VentChase,
	VentRetreat = CreatureConfig.Speeds.Stunned,
	Stunned = CreatureConfig.Speeds.Stunned,
	Swim = CreatureConfig.Speeds.AquaticStalk,
	Scripted = CreatureConfig.Speeds.Scripted,
}

local BIPED: { string } = { "Dormant", "Patrol", "Investigate", "Chase", "Stunned", "Scripted" }

type Rig = {
	folder: Folder,
	model: Model,
	root: BasePart,
	animator: Animator,
	-- Every BasePart but the root and the hitbox: its carrying jointed part and its corners in that part's space.
	carried: { { limb: string, corners: { Vector3 }, name: string } },
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function boxCorners(cframe: CFrame, size: Vector3): { Vector3 }
	local half = size * 0.5
	local out: { Vector3 } = {}
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				table.insert(out, cframe * Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))
			end
		end
	end
	return out
end

local function animated(state: string, speed: number, backward: boolean?, look: number?): Rig
	local previous = Geometry.getYieldEvery()
	Geometry.setYieldEvery(0)
	local folder = Instance.new("Folder")
	folder.Name = "CreatureAnimationSpec"
	local model = CreatureRigBuilder.build(folder, BASE)
	Geometry.setYieldEvery(previous)
	local rootInstance = model:FindFirstChild(NAMES.Root)
	assert(rootInstance and rootInstance:IsA("BasePart"), "the Creature has no root")
	local root: BasePart = rootInstance
	local animator = ProceduralAnimator.new(model, Creature.Profile, { seed = 5, priority = true })
	assert(animator, "the Creature rig could not be animated")
	local direction = if backward then 1 else -1
	animator:SetInputs({
		moveState = state,
		velocity = root.CFrame:VectorToWorldSpace(Vector3.new(0, 0, direction * speed)),
		grounded = true,
		lookYaw = ProceduralAnimator.yawOf(root.CFrame) + (look or 0),
		lookPitch = 0,
	})
	Creature.setFocus(animator.Map, look ~= nil)
	local map = animator.Map
	local carried: { { limb: string, corners: { Vector3 }, name: string } } = {}
	for _, descendant in model:GetDescendants() do
		if not descendant:IsA("BasePart") or descendant == root or descendant.Name == NAMES.Hitbox then
			continue
		end
		local limb: BasePart? = nil
		if map.parts[descendant.Name] == descendant then
			limb = descendant
		else
			local parent = descendant.Parent
			while parent and parent ~= model do
				if parent:IsA("BasePart") and map.parts[parent.Name] == parent then
					limb = parent
					break
				end
				parent = parent.Parent
			end
		end
		assert(limb, descendant.Name .. " is not carried by a jointed part")
		local offset = limb.CFrame:ToObjectSpace(descendant.CFrame)
		table.insert(
			carried,
			{ limb = limb.Name, corners = boxCorners(offset, descendant.Size), name = descendant.Name }
		)
	end
	return { folder = folder, model = model, root = root, animator = animator, carried = carried }
end

local function release(rig: Rig)
	rig.animator:Destroy()
	rig.folder:Destroy()
end

local function run(rig: Rig, seconds: number, each: ((step: number) -> ())?)
	for step = 1, math.floor(seconds / DT + 0.5) do
		rig.animator:Step(DT)
		if each then
			each(step)
		end
	end
end

-- Rig-space frames of every jointed part, from the Motor6D Transforms the animator wrote.
local function posedFrames(rig: Rig): { [string]: CFrame }
	local map = rig.animator.Map
	local frames: { [string]: CFrame } = { [map.rootName] = CFrame.identity }
	for _, joint in map.order do
		local motor = joint.motor
		assert(motor, joint.name .. " is not a Motor6D")
		frames[joint.part1Name] = frames[joint.part0Name] * joint.c0 * motor.Transform * joint.c1Inverse
	end
	return frames
end

-- Every corner of every part (welded details included) under the current pose, rig space.
local function posedCorners(rig: Rig): { { point: Vector3, name: string } }
	local frames = posedFrames(rig)
	local out: { { point: Vector3, name: string } } = {}
	for _, item in rig.carried do
		local frame = frames[item.limb]
		for _, corner in item.corners do
			table.insert(out, { point = frame * corner, name = item.name })
		end
	end
	return out
end

local function finite(value: number): boolean
	return value == value and math.abs(value) ~= math.huge
end

local function finiteFrame(frame: CFrame): boolean
	for _, value in { frame:GetComponents() } do
		if not finite(value) then
			return false
		end
	end
	return true
end

-- The face's forward direction (rig space) under the current pose.
local function facing(rig: Rig): Vector3
	local frames = posedFrames(rig)
	local head = rig.model:FindFirstChild(NAMES.Head)
	assert(head and head:IsA("BasePart"), "no head")
	local face = head:FindFirstChild(NAMES.FaceAttachment)
	assert(face and face:IsA("Attachment"), "no face attachment")
	return (frames[NAMES.Head] * face.CFrame).LookVector
end

local function flat(v: Vector3): Vector3
	local horizontal = Vector3.new(v.X, 0, v.Z)
	return if horizontal.Magnitude > 1e-6 then horizontal.Unit else Vector3.zero
end

-- How far a corner pokes out of the bore's cross-section (<= 0 inside).
local function boreExcess(point: Vector3): number
	return math.max(math.abs(point.X), math.abs(point.Y)) - BORE_HALF
end

-- Translation each joint may carry: the body shift on Root, a craned / lunging neck, a shoulder shrug.
local function translationLimit(name: string): number
	if name == "Root" then
		return 6
	elseif name == "Neck" then
		return 0.4
	elseif string.find(name, "Shoulder") then
		return 0.25
	end
	return 1e-4
end

local function cycleSeconds(rig: Rig, speed: number, state: string): number
	local spec = Creature.Profile.states[state]
	local cycle = spec.cycle
	if not cycle then
		return 2
	end
	local perSecond = speed / cycle.length(speed, rig.animator.Map) + (cycle.rate or 0)
	return if perSecond > 0 then math.min(3, 1 / perSecond) else 2
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["resolveState: body shape first (duct, water), then the AI state"] = function(t: Expect)
		type Row = { monster: unknown, pose: unknown, vent: unknown, expected: string }
		local rows: { Row } = {
			{ monster = "Dormant", pose = "Biped", vent = false, expected = "Dormant" },
			{ monster = "Patrol", pose = "Biped", vent = false, expected = "Patrol" },
			{ monster = "Patrol", pose = "Hunched", vent = false, expected = "Patrol" },
			{ monster = "InvestigateNoise", pose = "Biped", vent = false, expected = "Investigate" },
			{ monster = "WallChase", pose = "Biped", vent = false, expected = "Chase" },
			{ monster = "VentChase", pose = "Biped", vent = false, expected = "Chase" },
			{ monster = "VentChase", pose = "Quadruped", vent = true, expected = "VentCrawl" },
			{ monster = "Patrol", pose = "Quadruped", vent = false, expected = "VentCrawl" },
			{ monster = "WallChase", pose = "Biped", vent = true, expected = "VentCrawl" },
			{ monster = "Stunned", pose = "Biped", vent = false, expected = "Stunned" },
			{ monster = "Stunned", pose = "Quadruped", vent = true, expected = "VentRetreat" },
			{ monster = "Stunned", pose = "Swim", vent = false, expected = "Stunned" },
			{ monster = "AquaticStalk", pose = "Swim", vent = false, expected = "Swim" },
			{ monster = "Patrol", pose = "Swim", vent = false, expected = "Swim" },
			{ monster = "AquaticStalk", pose = "Biped", vent = false, expected = "Patrol" },
			{ monster = "Scripted", pose = "Biped", vent = false, expected = "Scripted" },
			{ monster = "Scripted", pose = "Quadruped", vent = true, expected = "VentCrawl" },
			{ monster = nil, pose = nil, vent = nil, expected = "Dormant" },
			{ monster = "Bogus", pose = 7, vent = "yes", expected = "Dormant" },
		}
		for index, row in rows do
			t.eq(Creature.resolveState(row.monster, row.pose, row.vent), row.expected, "row " .. index)
			local viaController, hunch = CreatureController.resolveState(row.monster, row.pose, row.vent)
			t.eq(viaController, row.expected, "controller row " .. index)
			t.eq(hunch, if row.pose == "Hunched" then 1 else 0, "hunch row " .. index)
		end
		for _, name in Creature.States do
			t.truthy(Creature.Profile.states[name] ~= nil, "the profile poses " .. name)
			t.truthy(Creature.isState(name), name .. " is a state")
		end
		t.falsy(Creature.isState("Standing"), "player states are not Creature states")
		t.eq(
			#ProceduralAnimator.missingJoints(
				CreatureRigBuilder.build(Instance.new("Folder"), CFrame.identity),
				Creature.Profile
			),
			0,
			"the rig has every joint the profile needs"
		)
	end,

	["every state poses finite, rotation-only joints through a full cycle"] = function(t: Expect)
		for _, state in Creature.States do
			for _, speed in { 0, SPEEDS[state] } do
				local rig = animated(state, speed)
				run(rig, 1)
				t.eq(rig.animator:GetState(), state, state .. " is the dominant state")
				local bad: string? = nil
				run(rig, cycleSeconds(rig, speed, state), function()
					if bad then
						return
					end
					for _, joint in rig.animator.Map.order do
						local motor = joint.motor :: Motor6D
						local transform = motor.Transform
						if not finiteFrame(transform) then
							bad = joint.name .. " not finite"
						elseif transform.Position.Magnitude > translationLimit(joint.name) then
							bad = string.format("%s translated %.3f", joint.name, transform.Position.Magnitude)
						end
					end
				end)
				t.eq(bad, nil, string.format("%s at %d studs/s", state, speed))
				release(rig)
			end
		end
	end,

	["state changes cross-fade with finite transforms"] = function(t: Expect)
		local rig = animated("Dormant", 0, false, 0)
		local sequence: { string } =
			{ "Patrol", "Chase", "VentCrawl", "VentRetreat", "Chase", "Swim", "Stunned", "Investigate", "Scripted" }
		run(rig, 0.5)
		for _, state in sequence do
			rig.animator:SetInputs({
				moveState = state,
				velocity = rig.root.CFrame:VectorToWorldSpace(Vector3.new(0, 0, -SPEEDS[state])),
			})
			local bad: string? = nil
			run(rig, 0.9, function()
				for _, joint in rig.animator.Map.order do
					if not finiteFrame((joint.motor :: Motor6D).Transform) then
						bad = joint.name
					end
				end
			end)
			t.eq(bad, nil, "into " .. state)
			t.eq(rig.animator:GetState(), state, state .. " takes over")
		end
		release(rig)
	end,

	["limbs stay within reach: IK never stretches a bone"] = function(t: Expect)
		for _, state in { "Patrol", "Chase", "Stunned", "VentCrawl", "VentRetreat" } do
			local rig = animated(state, SPEEDS[state])
			local measured = Creature.measure(rig.animator.Map)
			local worst = 0
			run(rig, 1.2, function(step: number)
				if step % 6 ~= 0 then
					return
				end
				local frames = posedFrames(rig)
				local map = rig.animator.Map
				for _, chain in
					{ { "RightShoulder", "RightElbow", "RightWrist" }, { "LeftHip", "LeftKnee", "LeftAnkle" } }
				do
					local points: { Vector3 } = {}
					for _, name in chain do
						-- The pivot where the joint's Transform puts it (a shrug may move a shoulder).
						local joint = map.joints[name]
						local motor = joint.motor :: Motor6D
						table.insert(points, (frames[joint.part0Name] * joint.c0 * motor.Transform).Position)
					end
					local upper = if string.find(chain[1], "Shoulder") then measured.upperArm else measured.thigh
					local lower = if string.find(chain[1], "Shoulder") then measured.forearm else measured.shin
					worst = math.max(worst, math.abs((points[2] - points[1]).Magnitude - upper))
					worst = math.max(worst, math.abs((points[3] - points[2]).Magnitude - lower))
					worst = math.max(worst, (points[3] - points[1]).Magnitude - (upper + lower))
				end
			end)
			t.truthy(worst < 1e-3, string.format("%s bones keep their length (worst %.5f)", state, worst))
			release(rig)
		end
	end,

	["two legs: feet on the floor, nothing sinks through it"] = function(t: Expect)
		for _, state in BIPED do
			local speed = SPEEDS[state]
			local rig = animated(state, speed)
			local ground = rig.animator.Map.groundY
			run(rig, 1)
			local lowest, lowestName = math.huge, ""
			local footFloor = 0
			local samples = 0
			run(rig, cycleSeconds(rig, speed, state), function(step: number)
				if step % 3 ~= 0 then
					return
				end
				samples += 1
				local feet = math.huge
				for _, corner in posedCorners(rig) do
					if corner.point.Y < lowest then
						lowest, lowestName = corner.point.Y, corner.name
					end
				end
				local frames = posedFrames(rig)
				for _, side in { "Left", "Right" } do
					local foot = frames[side .. "Foot"]
					feet = math.min(feet, (foot * Vector3.new(0, -0.05, 0)).Y)
				end
				if feet - ground < 0.25 then
					footFloor += 1
				end
			end)
			t.truthy(
				lowest >= ground - 0.08,
				string.format("%s: lowest point %.3f (%s) vs floor %.3f", state, lowest, lowestName, ground)
			)
			if state ~= "Chase" then
				-- Walking always has a foot down (the chase has a flight phase).
				t.eq(footFloor, samples, state .. ": a foot stays on the floor")
			end
			release(rig)
		end
	end,

	["planted feet and claws keep pace with the ground (no sliding)"] = function(t: Expect)
		type Case = { state: string, speed: number, part: string, foot: string }
		local cases: { Case } = {
			{ state = "Patrol", speed = 8, part = "LeftFoot", foot = "Left" },
			{ state = "VentCrawl", speed = 12, part = "LeftHand", foot = "LeftHand" },
			{ state = "VentCrawl", speed = 12, part = "RightFoot", foot = "Right" },
		}
		for _, case in cases do
			local rig = animated(case.state, case.speed)
			run(rig, 1.5)
			local previous: Vector3? = nil
			local worst, planted = 0, 0
			local plants = 0
			local connection = rig.animator.Footstep:Connect(function(event: ProceduralAnimator.FootstepEvent)
				if event.foot == case.foot then
					plants += 1
				end
			end)
			run(rig, 2, function()
				local frame = rig.animator:GetPartFrame(case.part)
				assert(frame, "no frame for " .. case.part)
				local position = frame.Position
				local last = previous
				previous = position
				if not last then
					return
				end
				-- Moving forward at `speed`, a planted part slides back by exactly speed * dt in rig space.
				local delta = position - last
				if math.abs(delta.Y) < 0.01 and math.abs(delta.Z - case.speed * DT) < 0.02 then
					planted += 1
					worst = math.max(worst, math.abs(delta.X))
				end
			end)
			connection:Disconnect()
			t.truthy(planted >= 15, string.format("%s %s spends steps planted (%d)", case.state, case.part, planted))
			t.truthy(worst < 0.02, string.format("%s %s does not slide sideways (%.4f)", case.state, case.part, worst))
			t.truthy(plants >= 1, string.format("%s %s fires footsteps (%d)", case.state, case.foot, plants))
			release(rig)
		end
	end,

	["the quadruped crawl, the retreat and a lunge fit inside the 3.5-stud bore"] = function(t: Expect)
		type Case = { state: string, speed: number, backward: boolean, action: string? }
		local cases: { Case } = {
			{ state = "VentCrawl", speed = 0, backward = false },
			{ state = "VentCrawl", speed = CreatureConfig.Speeds.Patrol, backward = false },
			{ state = "VentCrawl", speed = CreatureConfig.Speeds.VentChase, backward = false },
			{ state = "VentCrawl", speed = CreatureConfig.Speeds.Patrol, backward = true },
			{ state = "VentRetreat", speed = CreatureConfig.Speeds.Stunned, backward = true },
			{ state = "VentRetreat", speed = 0, backward = false },
			{ state = "VentCrawl", speed = 0, backward = false, action = "Lunge" },
			{ state = "VentCrawl", speed = 6, backward = false, action = "Vanish" },
			{ state = "VentCrawl", speed = 0, backward = false, action = "NeckSnap" },
			{ state = "VentRetreat", speed = 3, backward = true, action = "Reveal" },
		}
		for _, case in cases do
			local rig = animated(case.state, case.speed, case.backward, 0)
			run(rig, 1)
			if case.action then
				Creature.playAction(rig.animator.Map, case.action)
			end
			local worst, worstName = -math.huge, ""
			local seconds = if case.action
				then Creature.ActionDurations[case.action]
				else math.max(cycleSeconds(rig, case.speed, case.state), 1.5)
			run(rig, seconds, function(step: number)
				if step % 2 ~= 0 then
					return
				end
				for _, corner in posedCorners(rig) do
					local excess = boreExcess(corner.point)
					if excess > worst then
						worst, worstName = excess, corner.name
					end
				end
			end)
			local label = string.format(
				"%s at %d studs/s%s%s",
				case.state,
				case.speed,
				if case.backward then " backward" else "",
				if case.action then " + " .. case.action else ""
			)
			t.truthy(worst <= 0, string.format("%s stays in the bore (worst %.3f by %s)", label, worst, worstName))
			release(rig)
		end
	end,

	["NeckSnap: the head wrenches round to face straight behind, holds, and comes back"] = function(t: Expect)
		local timing = Creature.NeckSnapTiming
		t.near(Creature.snapProgress(0), 0, 1e-9, "starts at the base pose")
		t.near(Creature.snapProgress(timing.turn), 1, 1e-6, "fully round at the end of the turn")
		local overshoot = 0
		for step = 1, 20 do
			overshoot = math.max(overshoot, Creature.snapProgress(timing.turn * step / 20))
		end
		t.truthy(overshoot > 1.01 and overshoot < 1.1, string.format("the snap overshoots a little (%.3f)", overshoot))
		t.near(Creature.snapProgress(timing.settle + timing.hold * 0.5), 1, 1e-9, "held round")
		t.near(Creature.snapProgress(timing.settle + timing.hold + timing.release + 0.01), 0, 1e-9, "released")

		for _, base in { "Dormant", "Scripted", "Patrol" } do
			local rig = animated(base, 0, false, 0)
			run(rig, 1.5)
			local before = flat(facing(rig))
			t.truthy(before:Dot(Vector3.new(0, 0, -1)) > 0.5, base .. ": faces forward before the snap")
			t.truthy(Creature.playAction(rig.animator.Map, "NeckSnap"), "NeckSnap starts")
			run(rig, timing.turn * 0.5)
			local midway = flat(facing(rig))
			t.truthy(midway:Dot(before) < 0.6, base .. ": already well round halfway through the turn")
			run(rig, timing.settle - timing.turn * 0.5)
			local worst = math.huge
			run(rig, timing.hold * 0.9, function(step: number)
				if step % 10 == 0 then
					worst = math.min(worst, flat(facing(rig)):Dot(Vector3.new(0, 0, 1)))
				end
			end)
			t.truthy(
				worst > 0.97,
				string.format("%s: the head faces straight behind through the hold (%.3f)", base, worst)
			)
			run(rig, timing.hold * 0.1 + timing.release + 0.6)
			t.eq(#Creature.activeActions(rig.animator.Map), 0, base .. ": the action has ended")
			t.truthy(flat(facing(rig)):Dot(Vector3.new(0, 0, -1)) > 0.5, base .. ": faces forward again")
			release(rig)
		end
	end,

	["Lunge: arms thrown out past the face, the jaw dropped wide"] = function(t: Expect)
		for _, base in { "Chase", "VentCrawl" } do
			local rig = animated(base, 0, false, 0)
			run(rig, 1)
			Creature.playAction(rig.animator.Map, "Lunge")
			run(rig, CreatureConfig.Jumpscare.LungeSeconds + 0.3)
			local jaw = rig.animator.Map.joints.Jaw.motor :: Motor6D
			local open = -jaw.Transform:ToEulerAnglesXYZ()
			t.truthy(open > math.rad(55), string.format("%s: the jaw hangs open (%.1f deg)", base, math.deg(open)))
			local frames = posedFrames(rig)
			local head = rig.model:FindFirstChild(NAMES.Head) :: BasePart
			local face = frames[NAMES.Head] * (head:FindFirstChild(NAMES.FaceAttachment) :: Attachment).CFrame
			for _, side in { "Left", "Right" } do
				local hand = face:PointToObjectSpace(frames[side .. "Hand"].Position)
				t.truthy(
					hand.Z < -0.5,
					string.format("%s: the %s hand reaches out past the face (%.2f)", base, side, hand.Z)
				)
			end
			release(rig)
		end
	end,

	["every action plays on two legs and four with finite transforms; unknown ones are refused"] = function(t: Expect)
		for _, base in { "Patrol", "VentCrawl", "Swim" } do
			for _, action in Creature.Actions do
				local rig = animated(base, 4, false, 0.4)
				run(rig, 0.5)
				t.truthy(Creature.playAction(rig.animator.Map, action), action .. " starts")
				t.eq(Creature.activeActions(rig.animator.Map)[1], action, action .. " is running")
				local bad: string? = nil
				run(rig, Creature.ActionDurations[action] + 0.1, function()
					for _, joint in rig.animator.Map.order do
						if not finiteFrame((joint.motor :: Motor6D).Transform) then
							bad = joint.name
						end
					end
				end)
				t.eq(bad, nil, string.format("%s on %s stays finite", action, base))
				t.eq(#Creature.activeActions(rig.animator.Map), 0, string.format("%s on %s ends", action, base))
				release(rig)
			end
		end
		local rig = animated("Patrol", 0)
		t.falsy(Creature.playAction(rig.animator.Map, "Moonwalk"), "unknown actions are refused")
		t.falsy(Creature.playAction(rig.animator.Map, "Lunge", 0 / 0), "a non-finite start is refused")
		-- An action started at a time in the past fast-forwards; one already over never runs.
		Creature.playAction(rig.animator.Map, "Vanish", -100)
		run(rig, DT * 2)
		t.eq(#Creature.activeActions(rig.animator.Map), 0, "a long-finished action is dropped")
		Creature.playAction(rig.animator.Map, "NeckSnap")
		Creature.stopAction(rig.animator.Map)
		t.eq(#Creature.activeActions(rig.animator.Map), 0, "stopAction clears every action")
		release(rig)
	end,

	["hunching ducks the body under a 6-stud ceiling"] = function(t: Expect)
		local rig = animated("Patrol", 0)
		Creature.setHunch(rig.animator.Map, 1)
		run(rig, 3)
		local highest = -math.huge
		for _, corner in posedCorners(rig) do
			highest = math.max(highest, corner.point.Y)
		end
		local ground = rig.animator.Map.groundY
		local height = highest - ground
		t.truthy(
			height <= CreatureConfig.Hitbox.Hunched.Y,
			string.format("hunched height %.2f fits %.1f", height, CreatureConfig.Hitbox.Hunched.Y)
		)
		release(rig)
	end,

	["twitches and growls are pure functions of time"] = function(t: Expect)
		local seen = 0
		for step = 0, 600 do
			local time = 1_700_000_000 + step * 0.05
			local a, kindA, signA = Creature.twitchAt(time, 3, 0.4)
			local b, kindB, signB = Creature.twitchAt(time, 3, 0.4)
			t.eq(a, b, "same envelope")
			t.eq(kindA, kindB, "same kind")
			t.eq(signA, signB, "same side")
			t.truthy(a >= 0 and a <= 1, "envelope in [0, 1]")
			if a > 0.5 then
				seen += 1
			end
		end
		t.truthy(seen > 0, "twitches happen")
		local growls = 0
		for slot = 1000, 1100 do
			local at = CreatureController.growlAt(slot, 8517)
			t.eq(at, CreatureController.growlAt(slot, 8517), "the same growl on every client")
			if at then
				growls += 1
				t.truthy(at >= slot * 4.5 and at < (slot + 1) * 4.5, "the growl falls inside its slot")
			end
		end
		t.truthy(growls > 30 and growls < 100, "some slots growl, some stay quiet (" .. growls .. ")")
	end,

	["CreatureController: velocity, look, light, pupils, loops, footsteps"] = function(t: Expect)
		local estimate = CreatureController.estimateVelocity
		local moving = Vector3.new(0, 0, -10)
		t.eq(estimate(moving, Vector3.new(0, 0, -10 / 60), 1 / 60), moving, "replicated velocity is used")
		local measured = estimate(Vector3.zero, Vector3.new(0.2, 0, 0), 1 / 60)
		t.near(measured.X, 12, 1e-6, "a kinematically moved root is measured from its motion")
		t.eq(estimate(Vector3.zero, Vector3.new(40, 0, 0), 1 / 60), Vector3.zero, "teleports read as still")

		local yaw, pitch = CreatureController.lookAt(Vector3.zero, Vector3.new(-5, 0, 0))
		t.near(yaw :: number, math.pi / 2, 1e-6, "looking left is +90 degrees")
		t.near(pitch :: number, 0, 1e-6, "level")
		t.eq(CreatureController.lookAt(Vector3.one, Vector3.one), nil, "no look at itself")

		local samples: { CreatureController.LightSample } = {
			{ position = Vector3.new(0, 10, 0), brightness = 2, range = 20 },
			{ position = Vector3.new(100, 0, 0), brightness = 5, range = 20 },
		}
		t.near(CreatureController.exposure(Vector3.zero, samples), 2 * 0.25, 1e-6, "falloff inside the range")
		t.eq(CreatureController.exposure(Vector3.new(0, 40, 0), samples), 0, "nothing outside every range")
		t.eq(CreatureController.pupilGlow(true, 50), 1, "pupils glow in a duct however lit")
		t.eq(CreatureController.pupilGlow(false, 0), 1, "pupils glow in the dark")
		t.eq(CreatureController.pupilGlow(false, 10), 0, "faint in bright light")
		local faintT, faintS = CreatureController.pupilLook(0)
		local brightT, brightS = CreatureController.pupilLook(1)
		t.truthy(brightT < faintT and brightS > faintS, "glowing pupils are clearer and larger")

		local quietScrape, quietBreath = CreatureController.ventVolumes(0)
		local loudScrape, loudBreath = CreatureController.ventVolumes(CreatureConfig.Speeds.VentChase)
		t.truthy(loudScrape > quietScrape and loudBreath > quietBreath, "the duct loops swell with speed")
		t.near(loudScrape, 1, 1e-9, "full scrape at chase speed")

		local skitterSpeed, skitterVolume = CreatureController.footstepVoice("VentCrawl", false, 1)
		local heavySpeed, heavyVolume = CreatureController.footstepVoice("Patrol", false, 1)
		t.truthy(skitterSpeed > 1 and heavySpeed < 1, "claws skitter fast, feet land slow")
		t.truthy(heavyVolume > skitterVolume, "feet land heavier than claws")
		t.truthy(CreatureController.isDuplicate(10, 10.02), "the same moment twice plays once")
		t.falsy(CreatureController.isDuplicate(10, 10.5), "a later replay restarts")
		t.falsy(CreatureController.isDuplicate(nil, 10), "nothing running")
	end,
}
