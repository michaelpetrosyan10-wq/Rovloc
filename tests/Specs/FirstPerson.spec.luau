--!strict
-- First-person maths (FirstPersonController's sub-modules): the override stack's priority blending, camera states and
-- eye offsets, view-bob / breathing / shake, panic integration, look input curves and LookRelay quantization, the
-- R15 eye pivot, the MoveState derivation the server mirrors, EMF interference and flicker, the battery curve and
-- the flashlight's prediction window, hand placements and the body renderer's head classification.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local Tags = require(ReplicatedStorage.Shared.Tags)

local FP = StarterPlayer.StarterPlayerScripts.Controllers.FirstPerson.FirstPersonController
local BodyRenderer = require(FP.BodyRenderer)
local CameraRig = require(FP.CameraRig)
local CameraStack = require(FP.CameraStack)
local CameraStates = require(FP.CameraStates)
local Flashlight = require(FP.Flashlight)
local HandRig = require(FP.HandRig)
local MovementController = require(FP.MovementController)
local PanicVFX = require(FP.PanicVFX)
local ViewBob = require(FP.ViewBob)

type Expect = SpecRunner.Expect

local function frame(x: number, y: number, z: number): CFrame
	return CFrame.new(x, y, z)
end

local function sample(cframe: CFrame, fov: number?, weight: number): CameraStack.Sample
	return { cframe = cframe, fov = fov, weight = weight }
end

local function part(parent: Instance, name: string, size: Vector3, cframe: CFrame): Part
	local made = Instance.new("Part")
	made.Name = name
	made.Size = size
	made.CFrame = cframe
	made.Parent = parent
	return made
end

local function motor(name: string, part0: BasePart, part1: BasePart, c0: CFrame, c1: CFrame): Motor6D
	local joint = Instance.new("Motor6D")
	joint.Name = name
	joint.Part0 = part0
	joint.Part1 = part1
	joint.C0 = c0
	joint.C1 = c1
	joint.Parent = part1
	return joint
end

-- A minimal R15-shaped rig: root, lower / upper torso and head joined by Root, Waist and Neck at the standard rest
-- offsets of a scale-1 block avatar.
local function r15Rig(): (Model, Part, Part, Part, Part)
	local model = Instance.new("Model")
	model.Name = "Rig"
	local root = part(model, "HumanoidRootPart", Vector3.new(2, 2, 1), CFrame.new(0, 3, 0))
	local lower = part(model, "LowerTorso", Vector3.new(2, 0.4, 1), CFrame.new(0, 2.2, 0))
	local upper = part(model, "UpperTorso", Vector3.new(2, 1.6, 1), CFrame.new(0, 3.2, 0))
	local head = part(model, "Head", Vector3.new(1.2, 1.2, 1.2), CFrame.new(0, 4.5, 0))
	motor("Root", root, lower, CFrame.new(0, -0.8, 0), CFrame.new(0, 0, 0))
	motor("Waist", lower, upper, CFrame.new(0, 0.2, 0), CFrame.new(0, -0.8, 0))
	motor("Neck", upper, head, CFrame.new(0, 0.8, 0), CFrame.new(0, -0.5, 0))
	return model, root, lower, upper, head
end

local STATIC_PANIC: PanicVFX.TargetInputs = { proximity = 0, chased = false, floor = 0, downed = false }

return {
	----------------------------------------------------------------------------------------------- CameraStack

	["camera stack: weights ramp over the blend times and zero times are instant"] = function(t: Expect)
		t.near(CameraStack.stepWeight(0, true, 0.5, 0.5, 0.25), 0.5, 1e-9)
		t.near(CameraStack.stepWeight(0.9, true, 0.5, 0.5, 0.25), 1, 1e-9, "clamped at 1")
		t.near(CameraStack.stepWeight(1, false, 0.5, 0.4, 0.1), 0.75, 1e-9)
		t.near(CameraStack.stepWeight(0.1, false, 0.5, 0.4, 0.1), 0, 1e-9, "clamped at 0")
		t.eq(CameraStack.stepWeight(0, true, 0, 1, 1 / 60), 1, "instant in")
		t.eq(CameraStack.stepWeight(1, false, 1, 0, 1 / 60), 0, "instant out")
		t.eq(CameraStack.ease(0), 0)
		t.eq(CameraStack.ease(1), 1)
		t.near(CameraStack.ease(0.5), 0.5, 1e-9)
	end,

	["camera stack: the highest fully blended layer wins, lower ones show through its blend"] = function(t: Expect)
		local base = frame(0, 0, 0)
		local low = frame(10, 0, 0)
		local high = frame(0, 10, 0)
		local cf, fov = CameraStack.blend(base, 70, {})
		t.eq(cf, base)
		t.eq(fov, 70)
		cf, fov = CameraStack.blend(base, 70, { sample(low, 50, 1), sample(high, nil, 1) })
		t.eq(cf.Position, high.Position, "top layer replaces everything below")
		t.eq(fov, 50, "a layer without FOV keeps the FOV below it")
		cf = CameraStack.blend(base, 70, { sample(low, nil, 1), sample(high, nil, 0) })
		t.eq(cf.Position, low.Position, "a blended-out top layer reveals the lower override, not the base")
		cf, fov = CameraStack.blend(base, 70, { sample(low, 50, 1), sample(high, 90, 0.5) })
		t.near(cf.Position.X, 5, 1e-6, "half-way between the two overrides")
		t.near(cf.Position.Y, 5, 1e-6)
		t.near(fov, 70, 1e-6)
		cf = CameraStack.blend(base, 70, { sample(low, nil, 0.25) })
		local share = CameraStack.ease(0.25)
		t.near(cf.Position.X, 10 * share, 1e-6, "eased share of the base")
	end,

	["camera stack: push, blend in, priority, pop, blend out and removal"] = function(t: Expect)
		local stack = CameraStack.new()
		local base = frame(0, 0, 0)
		stack:Push("Trapped", {
			cframe = function(): CFrame
				return frame(1, 0, 0)
			end,
			blendIn = 0.2,
			blendOut = 0.2,
		})
		stack:Push("Cutscene", {
			cframe = function(): CFrame
				return frame(0, 0, 9)
			end,
			fov = 40,
			blendIn = 0.5,
			blendOut = 0,
		})
		t.eq(stack:Top(), "Cutscene")
		for _ = 1, 30 do
			stack:Step(1 / 60)
		end
		local cf, fov = stack:Evaluate(base, 70)
		t.eq(cf.Position, Vector3.new(0, 0, 9), "Cutscene above Trapped")
		t.eq(fov, 40)
		t.near(stack:Weight("Trapped"), 1, 1e-9)
		stack:Pop("Cutscene")
		stack:Step(1 / 60)
		t.eq(stack:Weight("Cutscene"), 0, "zero blend-out")
		t.falsy(stack:IsActive("Cutscene"))
		cf, fov = stack:Evaluate(base, 70)
		t.eq(cf.Position, Vector3.new(1, 0, 0), "Trapped shows once the cutscene is gone")
		t.eq(fov, 70)
		stack:Pop("Trapped")
		stack:Step(0.1)
		t.near(stack:Weight("Trapped"), 0.5, 1e-9, "half blended out")
		stack:Push("Trapped", {
			cframe = function(): CFrame
				return frame(2, 0, 0)
			end,
			blendIn = 0.2,
		})
		t.near(stack:Weight("Trapped"), 0.5, 1e-9, "a re-push keeps its weight")
		t.truthy(stack:IsActive("Trapped"))
		stack:Clear(true)
		t.eq(stack:Top(), nil)
		t.eq(stack:Coverage(), 0)
	end,

	["camera stack: failing sources are skipped and unknown kinds ignored"] = function(t: Expect)
		local stack = CameraStack.new()
		stack:Push("Jumpscare", {
			cframe = function(): CFrame
				error("boom")
			end,
			blendIn = 0,
		})
		stack:Push(("Nope" :: any) :: Enums.CameraOverride, {
			cframe = function(): CFrame
				return frame(5, 5, 5)
			end,
		})
		stack:Step(1 / 60)
		local cf = stack:Evaluate(frame(3, 0, 0), 70)
		t.eq(cf.Position, Vector3.new(3, 0, 0), "base survives a throwing override")
		t.eq(stack:Top(), "Jumpscare")
		t.truthy(CameraStack.Priority.Cutscene > CameraStack.Priority.Jumpscare)
		t.truthy(CameraStack.Priority.Jumpscare > CameraStack.Priority.Spectating)
		t.truthy(CameraStack.Priority.Spectating > CameraStack.Priority.Struggle)
		t.truthy(CameraStack.Priority.Struggle > CameraStack.Priority.Trapped)
		for _, kind: Enums.CameraOverride in Enums.CameraOverride do
			t.truthy(CameraStack.Priority[kind] ~= nil, kind .. " has a priority")
		end
	end,

	----------------------------------------------------------------------------------------------- CameraStates

	["camera states: every MoveState maps, primaries use the configured offsets"] = function(t: Expect)
		for _, state: Enums.MoveState in Enums.MoveState do
			t.truthy(Enums.has(Enums.CameraState, CameraStates.fromMoveState(state)), state)
		end
		t.eq(CameraStates.fromMoveState("Sprinting"), "Standing")
		t.eq(CameraStates.fromMoveState("VentScurrying"), "VentCrawling")
		t.eq(CameraStates.fromMoveState("Underwater"), "UnderwaterSwimming")
		t.eq(CameraStates.fromMoveState("Hiding"), "LockerPeeking")
		t.eq(CameraStates.offset("Standing"), Vector3.new(0, 0, 0))
		t.eq(CameraStates.offset("Crouching"), Vector3.new(0, -1.5, 0))
		t.eq(CameraStates.offset("VentCrawling"), Vector3.new(0, -2.1, -0.5))
		t.eq(CameraStates.offset("DownedCrawling"), Vector3.new(0, -2.3, 0))
		t.eq(CameraStates.offset("Underwater"), CameraConfig.StateOffsets.UnderwaterSwimming)
		t.eq(CameraStates.offset("Treading"), CameraConfig.StateOffsets.SurfaceSwimming)
		for _, cameraState: Enums.CameraState in CameraStates.List do
			t.eq(typeof(CameraConfig.StateOffsets[cameraState]), "Vector3", cameraState .. " has an offset")
			local min, max = CameraStates.pitchLimits(cameraState)
			t.truthy(min < 0 and max > 0 and min >= -89 and max <= 89, cameraState .. " pitch range")
		end
	end,

	["camera states: siblings trim to the server eye, forced states use the offset as is"] = function(t: Expect)
		local eye = CameraConfig.EyeHeightAboveRoot
		t.near(CameraStates.offset("Sprinting").Y, eye.Sprinting - eye.Standing, 1e-6, "sprint eye")
		t.near(CameraStates.offset("Trapped").Y, eye.Trapped - eye.Standing, 1e-6, "trapped eye")
		t.near(
			CameraStates.offset("Freestyle").Y,
			CameraConfig.StateOffsets.SurfaceSwimming.Y + eye.Freestyle - eye.Treading,
			1e-6
		)
		t.near(CameraStates.offset("VentScurrying").Y, -2.1, 1e-6, "same eye as the crawl")
		t.eq(CameraStates.offset("Sprinting", "ParachuteLookback"), CameraConfig.StateOffsets.ParachuteLookback)
		t.eq(CameraStates.offset("Standing", "LockerPeeking"), CameraConfig.StateOffsets.LockerPeeking)
		local min, max = CameraStates.pitchLimits("VentCrawling")
		t.eq(min, CameraConfig.Pitch.VentMin)
		t.eq(max, CameraConfig.Pitch.VentMax)
		min, max = CameraStates.pitchLimits("Standing")
		t.eq(min, CameraConfig.Pitch.Min)
		t.eq(max, CameraConfig.Pitch.Max)
	end,

	["camera states: bob profiles follow posture, held bodies stay still"] = function(t: Expect)
		t.eq(CameraStates.bob("Standing").amplitude, 1)
		t.eq(CameraStates.bob("Sprinting").amplitude, CameraConfig.Bob.SprintMultiplier)
		t.eq(CameraStates.bob("Crouching").amplitude, CameraConfig.Bob.CrouchMultiplier)
		t.eq(CameraStates.bob("VentCrawling").amplitude, CameraConfig.Bob.VentMultiplier)
		t.eq(CameraStates.bob("Sprinting").nominalSpeed, GameConfig.SprintSpeed)
		for _, still: Enums.MoveState in
			{ "Hiding", "Trapped", "Grabbed", "Parachuting", "Scripted" } :: { Enums.MoveState }
		do
			t.eq(CameraStates.bob(still).amplitude, 0, still)
		end
		for _, state: Enums.MoveState in Enums.MoveState do
			t.truthy(CameraStates.bob(state).nominalSpeed > 0, state)
		end
	end,

	----------------------------------------------------------------------------------------------- ViewBob

	["view bob: zero-mean, bounded, dips at each footfall, scales with intensity"] = function(t: Expect)
		local steps = 400
		local sumVertical, sumRoll, sumPitch = 0, 0, 0
		local B = CameraConfig.Bob
		for i = 0, steps - 1 do
			local pitch, roll, vertical, lateral = ViewBob.bob(i / steps, 1, 1)
			sumVertical += vertical
			sumRoll += roll
			sumPitch += pitch
			t.truthy(math.abs(vertical) <= B.WalkVertical + 1e-9, "vertical bound")
			t.truthy(math.abs(roll) <= B.WalkRoll + 1e-9, "roll bound")
			t.truthy(math.abs(pitch) <= B.WalkPitch + 1e-9, "pitch bound")
			t.truthy(math.abs(lateral) <= B.WalkVertical + 1e-9, "lateral bound")
		end
		t.near(sumVertical / steps, 0, 1e-6, "vertical mean")
		t.near(sumRoll / steps, 0, 1e-6, "roll mean")
		t.near(sumPitch / steps, 0, 1e-6, "pitch mean")
		local _, _, plantA = ViewBob.bob(0, 1, 1)
		local _, _, plantB = ViewBob.bob(0.5, 1, 1)
		local _, _, between = ViewBob.bob(0.25, 1, 1)
		t.near(plantA, -B.WalkVertical, 1e-9, "lowest at the first footfall")
		t.near(plantB, -B.WalkVertical, 1e-9, "and at the second")
		t.near(between, B.WalkVertical, 1e-9, "highest mid-stride")
		local p0, r0, v0, l0 = ViewBob.bob(0.3, 0, 1)
		t.eq(p0 + r0 + v0 + l0, 0, "no bob at zero intensity")
		local _, _, half = ViewBob.bob(0, 0.5, 2)
		t.near(half, -B.WalkVertical, 1e-9, "intensity x amplitude")
	end,

	["view bob: breathing deepens and quickens with panic"] = function(t: Expect)
		local function peak(panic: number): number
			local best = 0
			for i = 0, 200 do
				local pitch = ViewBob.breath(i / 100, panic)
				best = math.max(best, math.abs(pitch))
			end
			return best
		end
		t.near(peak(0), CameraConfig.Bob.IdleBreathPitch, 1e-3)
		t.near(peak(1), CameraConfig.Bob.IdleBreathPitch * CameraConfig.Bob.PanicBreathMultiplier, 1e-3)
		t.near(ViewBob.breathRate(0), CameraConfig.Bob.IdleBreathFrequency, 1e-9)
		t.truthy(ViewBob.breathRate(1) > ViewBob.breathRate(0.5) and ViewBob.breathRate(0.5) > ViewBob.breathRate(0))
	end,

	["view bob: shakes decay, end on time, and respect MotionScale"] = function(t: Expect)
		local decay = CameraConfig.Shake.Decay
		t.eq(ViewBob.shakeEnvelope(0, 1, decay), 1)
		t.truthy(ViewBob.shakeEnvelope(0.3, 1, decay) < ViewBob.shakeEnvelope(0.1, 1, decay), "decays")
		t.eq(ViewBob.shakeEnvelope(1, 1, decay), 0, "over at its end")
		t.eq(ViewBob.shakeEnvelope(-0.1, 1, decay), 0)
		t.truthy(ViewBob.shakeEnvelope(0.9, 1, 0) < 0.5, "fades out over its tail even without decay")
		local a, b, c = ViewBob.shakeAngles(1.234, 2, 7)
		local a2, b2, c2 = ViewBob.shakeAngles(1.234, 2, 7)
		t.eq(a, a2)
		t.eq(b, b2)
		t.eq(c, c2)

		local bob = ViewBob.new()
		local inputs: ViewBob.Inputs = {
			speed = 0,
			profile = CameraStates.bob("Standing"),
			panic = 0,
			motionScale = 1,
			chase = 0,
			grounded = true,
		}
		bob:Shake(4, 0.5)
		local shaken = false
		for _ = 1, 10 do
			local offset = bob:Step(1 / 60, inputs)
			local rx, ry, rz = offset:ToOrientation()
			if math.abs(rx) + math.abs(ry) + math.abs(rz) > math.rad(0.5) then
				shaken = true
			end
		end
		t.truthy(shaken, "a 4 degree shake moves the view")
		local still = ViewBob.new()
		still:Shake(10, 2)
		local frozen = table.clone(inputs)
		frozen.motionScale = 0
		frozen.speed = 11
		for _ = 1, 30 do
			local offset = still:Step(1 / 60, frozen)
			t.near(offset.Position.Magnitude, 0, 1e-9, "MotionScale 0: no translation")
			local rx, ry, rz = offset:ToOrientation()
			t.near(math.abs(rx) + math.abs(ry) + math.abs(rz), 0, 1e-9, "MotionScale 0: no rotation")
		end
	end,

	["view bob: walking builds the bob up and stopping lets it settle"] = function(t: Expect)
		local bob = ViewBob.new()
		local walk: ViewBob.Inputs = {
			speed = GameConfig.WalkSpeed,
			profile = CameraStates.bob("Standing"),
			panic = 0,
			motionScale = 1,
			chase = 0,
			grounded = true,
		}
		local peak = 0
		for _ = 1, 120 do
			peak = math.max(peak, math.abs(bob:Step(1 / 60, walk).Position.Y))
		end
		t.truthy(peak > CameraConfig.Bob.WalkVertical * 0.6, "walking bobs")
		t.truthy(bob:Phase() > 0, "the gait advanced")
		local stop = table.clone(walk)
		stop.speed = 0
		local last = math.huge
		for _ = 1, 240 do
			last = math.abs(bob:Step(1 / 60, stop).Position.Y)
		end
		t.truthy(last < 1e-3, "settles after stopping")
		t.eq(ViewBob.intensity(5, CameraStates.bob("Hiding"), true), 0, "still states never bob")
		t.truthy(ViewBob.intensity(11, CameraStates.bob("Standing"), false) < 0.5, "faded in the air")
	end,

	----------------------------------------------------------------------------------------------- PanicVFX

	["panic: proximity runs from the near to the far distance, weaker through walls"] = function(t: Expect)
		local near = CameraConfig.Panic.CreatureNearDistance
		local far = CameraConfig.Panic.CreatureFarDistance
		t.eq(PanicVFX.proximity(near * 0.5, true), 1)
		t.eq(PanicVFX.proximity(near, true), 1)
		t.eq(PanicVFX.proximity(far, true), 0)
		t.eq(PanicVFX.proximity(far + 10, true), 0)
		local previous = 1
		for distance = near, far, 2 do
			local value = PanicVFX.proximity(distance, true)
			t.truthy(value <= previous + 1e-9, "monotone at " .. distance)
			previous = value
		end
		t.near(PanicVFX.proximity(30, false), PanicVFX.proximity(30, true) * PanicVFX.OccludedShare, 1e-9)
		t.eq(PanicVFX.proximity(0 / 0, true), 0, "NaN distance")
	end,

	["panic: target takes the highest source, downed adds, everything clamps"] = function(t: Expect)
		t.eq(PanicVFX.target(STATIC_PANIC), 0)
		local chased = table.clone(STATIC_PANIC)
		chased.chased = true
		t.eq(PanicVFX.target(chased), CameraConfig.Panic.ChaseFloor)
		chased.proximity = 0.9
		t.eq(PanicVFX.target(chased), 0.9, "the highest source wins")
		local floor = table.clone(STATIC_PANIC)
		floor.floor = 0.7
		t.eq(PanicVFX.target(floor), 0.7)
		floor.downed = true
		t.near(PanicVFX.target(floor), 1, 1e-9, "clamped to 1")
		local downed = table.clone(STATIC_PANIC)
		downed.downed = true
		t.near(PanicVFX.target(downed), PanicVFX.DownedBonus, 1e-9)
	end,

	["panic: rises at RiseSpeed and falls at FallSpeed"] = function(t: Expect)
		local P = CameraConfig.Panic
		t.near(PanicVFX.integrate(0, 1, 0.1), P.RiseSpeed * 0.1, 1e-9)
		t.near(PanicVFX.integrate(1, 0, 0.1), 1 - P.FallSpeed * 0.1, 1e-9)
		t.eq(PanicVFX.integrate(0.5, 0.5, 1), 0.5)
		t.eq(PanicVFX.integrate(0.9, 1, 10), 1, "never overshoots")
		t.eq(PanicVFX.integrate(0.1, 0, 10), 0)
		local level = 0
		local seconds = 0
		while level < 0.999 and seconds < 5 do
			level = PanicVFX.integrate(level, 1, 1 / 60)
			seconds += 1 / 60
		end
		t.near(seconds, 1 / P.RiseSpeed, 0.05, "time to full panic")
		t.truthy(P.FallSpeed < P.RiseSpeed, "calming down is slower than panicking")
	end,

	["panic: outputs scale with panic and the comfort settings"] = function(t: Expect)
		t.eq(PanicVFX.fovBonus(0, 1), 0)
		t.near(PanicVFX.fovBonus(1, 1), CameraConfig.FieldOfView.PanicMaxBonus, 1e-9)
		t.eq(PanicVFX.fovBonus(1, 0), 0, "MotionScale 0 removes the FOV warp")
		local saturation, contrast, tint = PanicVFX.grade(1)
		t.near(saturation, CameraConfig.Panic.Saturation, 1e-9)
		t.near(contrast, CameraConfig.Panic.Contrast, 1e-9)
		t.eq(tint, CameraConfig.Panic.TintRed)
		local s0, c0, tint0 = PanicVFX.grade(0)
		t.eq(s0, 0)
		t.eq(c0, 0)
		t.eq(tint0, Color3.new(1, 1, 1))
		t.near(PanicVFX.vignetteOpacity(1, 0, 1), 1 - CameraConfig.Panic.VignetteTransparencyAtFull, 1e-9)
		t.truthy(PanicVFX.vignetteOpacity(0, 1, 1) < PanicVFX.vignetteOpacity(1, 0, 1))
		t.truthy(PanicVFX.vignetteOpacity(1, 1, 1) > PanicVFX.vignetteOpacity(1, 1, 0), "FlashScale damps the throb")
		t.truthy(PanicVFX.vignetteOpacity(1, 1, 1) <= 1)
		t.near(PanicVFX.pulse(0.05), 1, 1e-6, "lub")
		t.truthy(PanicVFX.pulse(0.33) > 0.5 and PanicVFX.pulse(0.7) < 0.05, "dub, then rest")
	end,

	["panic: heartbeat and breathing loops switch with hysteresis"] = function(t: Expect)
		t.eq(PanicVFX.heartbeatPreset(0.1, nil), nil)
		t.eq(PanicVFX.heartbeatPreset(0.4, nil), "Heartbeat")
		t.eq(PanicVFX.heartbeatPreset(0.9, nil), "HeartbeatFast")
		t.eq(PanicVFX.heartbeatPreset(0.6, "HeartbeatFast"), "HeartbeatFast", "stays fast just below the edge")
		t.eq(PanicVFX.heartbeatPreset(0.6, "Heartbeat"), "Heartbeat")
		t.eq(PanicVFX.heartbeatPreset(0.22, "Heartbeat"), "Heartbeat", "keeps beating just below the edge")
		t.eq(PanicVFX.heartbeatPreset(0.22, nil), nil)
		t.eq(PanicVFX.breathingPreset(0.1, nil), nil)
		t.eq(PanicVFX.breathingPreset(0.3, nil), "Breathing")
		t.eq(PanicVFX.breathingPreset(0.8, nil), "BreathingPanic")
		t.eq(PanicVFX.breathingPreset(0.52, "BreathingPanic"), "BreathingPanic")
		t.eq(PanicVFX.breathingPreset(0.52, "Breathing"), "Breathing")
	end,

	----------------------------------------------------------------------------------------------- CameraRig

	["look relay: int16 quantization round-trips and wraps"] = function(t: Expect)
		local step = math.pi / 32767
		for i = -40, 40 do
			local angle = i * 0.0789
			local q = MathUtil.quantizeAngle(angle)
			t.truthy(q == math.floor(q) and q >= -32767 and q <= 32767, "int16")
			t.near(MathUtil.dequantizeAngle(q), MathUtil.wrapAngle(angle), step, "round trip " .. angle)
		end
		t.eq(CameraRig.lookDistance(32760, -32760), 14, "the short way across +-pi")
		t.eq(CameraRig.lookDistance(-32760, 32760), 14)
		t.eq(CameraRig.lookDistance(100, -100), 200)
		t.eq(CameraRig.lookDistance(5, 5), 0)
	end,

	["look relay: a sample is due only past the epsilon"] = function(t: Expect)
		local eps = CameraRig.LookEpsilon
		local due, qYaw, qPitch = CameraRig.shouldSendLook(nil, nil, 0.5, 0.1, eps)
		t.truthy(due, "first sample")
		local tiny = (eps * 0.5) * math.pi / 32767
		local dueTiny = CameraRig.shouldSendLook(qYaw, qPitch, 0.5 + tiny, 0.1, eps)
		t.falsy(dueTiny, "under the epsilon")
		local big = (eps * 2) * math.pi / 32767
		t.truthy((CameraRig.shouldSendLook(qYaw, qPitch, 0.5 + big, 0.1, eps)), "yaw past the epsilon")
		t.truthy((CameraRig.shouldSendLook(qYaw, qPitch, 0.5, 0.1 - big, eps)), "pitch past the epsilon")
		local _, edgeYaw, edgePitch = CameraRig.shouldSendLook(nil, nil, math.pi - 0.0005, 0, eps)
		t.falsy((CameraRig.shouldSendLook(edgeYaw, edgePitch, -math.pi + 0.0005, 0, eps)), "no resend across +-pi")
	end,

	["look input: gamepad deadzone, curve and boost"] = function(t: Expect)
		local dz, ex = CameraRig.GamepadDeadzone, CameraRig.GamepadExponent
		t.eq(CameraRig.gamepadCurve(Vector2.new(0.1, 0.05), dz, ex), Vector2.zero, "inside the deadzone")
		local full = CameraRig.gamepadCurve(Vector2.new(1, 0), dz, ex)
		t.near(full.X, 1, 1e-6, "full deflection, full rate")
		local over = CameraRig.gamepadCurve(Vector2.new(0.9, 0.9), dz, ex)
		t.near(over.Magnitude, 1, 1e-6, "clamped at the rim")
		t.near(over.X, over.Y, 1e-6, "direction kept")
		local previous = 0
		for i = 1, 20 do
			local value = CameraRig.gamepadCurve(Vector2.new(i / 20, 0), dz, ex).X
			t.truthy(value >= previous, "monotone")
			previous = value
		end
		local mid = CameraRig.gamepadCurve(Vector2.new(0.57, 0), dz, ex).X
		t.truthy(mid < 0.5, "fine control below half deflection")
		t.eq(CameraRig.turnBoost(0), 1)
		t.eq(CameraRig.turnBoost(0.1), 1, "no boost before the delay")
		t.truthy(CameraRig.turnBoost(0.4) > 1 and CameraRig.turnBoost(0.4) < CameraRig.turnBoost(2))
		t.near(CameraRig.turnBoost(5), 1.6, 1e-9)
	end,

	["look input: pitch limits hold input and ease a tightened range"] = function(t: Expect)
		local min, max = math.rad(-35), math.rad(35)
		t.near(CameraRig.applyPitch(0, math.rad(50), min, max), max, 1e-9, "input stops at the limit")
		t.near(CameraRig.applyPitch(0, math.rad(-50), min, max), min, 1e-9)
		t.near(CameraRig.applyPitch(math.rad(60), math.rad(5), min, max), math.rad(60), 1e-9, "no further out")
		t.near(CameraRig.applyPitch(math.rad(60), math.rad(-5), min, max), math.rad(55), 1e-9, "back in freely")
		local pitch = math.rad(70)
		local frames = 0
		while pitch > max + 1e-9 and frames < 600 do
			local nextPitch = CameraRig.settlePitch(pitch, min, max, 1 / 60)
			t.truthy(nextPitch < pitch and nextPitch >= max, "eases monotonically inside")
			pitch = nextPitch
			frames += 1
		end
		t.near(pitch, max, 1e-9, "reaches the limit")
		t.truthy(frames < 60, "within a second")
		t.eq(CameraRig.settlePitch(0.2, min, max, 1 / 60), 0.2, "inside: untouched")
	end,

	["look input: touch look zone"] = function(t: Expect)
		local viewport = Vector2.new(1000, 500)
		t.truthy(CameraRig.isLookTouch(Vector2.new(800, 400), viewport, false), "right side")
		t.falsy(CameraRig.isLookTouch(Vector2.new(150, 400), viewport, false), "thumbstick side")
		t.truthy(CameraRig.isLookTouch(Vector2.new(150, 60), viewport, false), "top band")
		t.falsy(CameraRig.isLookTouch(Vector2.new(800, 400), viewport, true), "began on GUI")
		t.falsy(CameraRig.isLookTouch(Vector2.new(800, 400), Vector2.zero, false))
	end,

	["eye pivot: measured from the R15 rest pose and carried forward when looking down"] = function(t: Expect)
		local model = r15Rig()
		local metrics = CameraRig.measureEye(model)
		t.near(metrics.neckHeight, 1, 1e-6, "neck joint 1 stud above the root centre")
		t.near(metrics.neckForward, 0, 1e-6)
		t.near(metrics.eyeUp, 0.5 + 1.2 * 0.08, 1e-6, "eye just above the head centre")
		t.truthy(metrics.eyeForward > 0.18 and metrics.eyeForward < 0.45)
		local level = CameraRig.eyeOffset(metrics, 0, 0)
		t.near(level.Y, metrics.neckHeight + metrics.eyeUp, 1e-6)
		t.near(level.Z, -metrics.eyeForward, 1e-6, "ahead of the neck (yaw 0 faces -Z)")
		t.near(level.Y, CameraConfig.EyeHeightAboveRoot.Standing, 0.15, "close to the server's standing eye")
		local down = CameraRig.eyeOffset(metrics, 0, math.rad(-80))
		t.truthy(down.Z < level.Z - 0.2, "looking down carries the eye forward over the chest")
		t.truthy(down.Y < level.Y, "and lowers it")
		local turned = CameraRig.eyeOffset(metrics, math.pi / 2, 0)
		t.near(turned.X, -metrics.eyeForward, 1e-6, "yaw pi/2 faces -X")
		local bare = Instance.new("Model")
		local defaults = CameraRig.measureEye(bare)
		t.eq(defaults, CameraRig.DefaultEye, "non-R15 rigs use the defaults")
		t.near(defaults.neckHeight + defaults.eyeUp, CameraConfig.EyeHeightAboveRoot.Standing, 1e-9)
		model:Destroy()
	end,

	----------------------------------------------------------------------------------------------- Movement

	["movement: deriveState table (the server mirrors it)"] = function(t: Expect)
		type Row = { inputs: MovementController.DeriveInputs, expected: Enums.MoveState }
		local function row(
			mode: MovementController.Mode,
			crouch: boolean,
			sprint: boolean,
			dive: boolean,
			stamina: number,
			moving: boolean,
			expected: Enums.MoveState,
			exhausted: boolean?
		): Row
			return {
				inputs = {
					mode = mode,
					override = nil,
					crouch = crouch,
					sprint = sprint,
					dive = dive,
					stamina = stamina,
					moving = moving,
					exhausted = exhausted == true,
				},
				expected = expected,
			}
		end
		local rows: { Row } = {
			row("OnFoot", false, false, false, 100, false, "Standing"),
			row("OnFoot", false, false, false, 100, true, "Standing"),
			row("OnFoot", false, true, false, 100, true, "Sprinting"),
			row("OnFoot", false, true, false, 100, false, "Standing"),
			row("OnFoot", false, true, false, 0, true, "Standing"),
			row("OnFoot", true, false, false, 100, true, "Crouching"),
			row("OnFoot", true, true, false, 100, true, "Crouching"),
			row("OnFoot", false, false, true, 100, true, "Standing"),
			row("Vent", false, false, false, 100, false, "VentCrawling"),
			row("Vent", false, true, false, 100, false, "VentScurrying"),
			row("Vent", false, true, false, 0, true, "VentCrawling"),
			row("Vent", true, false, false, 100, true, "VentCrawling"),
			row("Swim", false, false, false, 100, false, "Treading"),
			row("Swim", false, true, false, 100, true, "Freestyle"),
			row("Swim", false, true, false, 0, true, "Treading"),
			row("Swim", false, true, true, 100, true, "Underwater"),
			row("Swim", false, false, true, 0, false, "Underwater"),
			row("Swim", true, false, false, 100, false, "Treading"),
			-- The exhaustion latch blocks every sprint state even with stamina back above 0.
			row("OnFoot", false, true, false, 40, true, "Standing", true),
			row("OnFoot", true, true, false, 40, true, "Crouching", true),
			row("Vent", false, true, false, 40, true, "VentCrawling", true),
			row("Swim", false, true, false, 40, true, "Treading", true),
			row("Swim", false, true, true, 40, true, "Underwater", true),
		}
		for index, entry in rows do
			t.eq(MovementController.deriveState(entry.inputs), entry.expected, "row " .. index)
		end
		for _, override: Enums.MoveState in MovementController.OverridePriority do
			local inputs = table.clone(rows[3].inputs)
			inputs.override = override
			t.eq(MovementController.deriveState(inputs), override, override .. " wins")
		end
	end,

	["movement: override priority, speeds, modes and the moving test"] = function(t: Expect)
		t.eq(MovementController.topOverride({ "DownedCrawling", "Trapped" }), "Trapped")
		t.eq(MovementController.topOverride({ "Hiding", "Scripted", "Grabbed" }), "Scripted")
		t.eq(MovementController.topOverride({ "Parachuting", "DownedCrawling" }), "Parachuting")
		t.eq(MovementController.topOverride({}), nil)
		t.eq(MovementController.OverridePriority[1], "Scripted")
		t.eq(MovementController.OverridePriority[#MovementController.OverridePriority], "DownedCrawling")
		t.truthy(MovementController.isOverride("Hiding"))
		t.falsy(MovementController.isOverride("Sprinting"))
		t.eq(MovementController.speedFor("Standing"), GameConfig.WalkSpeed)
		t.eq(MovementController.speedFor("Sprinting"), GameConfig.SprintSpeed)
		t.eq(MovementController.speedFor("Crouching"), GameConfig.CrouchSpeed)
		t.eq(MovementController.speedFor("DownedCrawling"), GameConfig.DownedMoveSpeed)
		t.eq(MovementController.speedFor("VentScurrying"), GameConfig.VentScurrySpeed)
		t.eq(MovementController.speedFor("Underwater"), GameConfig.UnderwaterSpeed)
		t.eq(MovementController.speedFor("Parachuting"), GameConfig.WalkSpeed)
		for _, held: Enums.MoveState in { "Hiding", "Trapped", "Grabbed", "Scripted" } :: { Enums.MoveState } do
			t.eq(MovementController.speedFor(held), 0, held)
		end
		for _, state: Enums.MoveState in Enums.MoveState do
			t.truthy(MovementController.speedFor(state) >= 0, state)
		end
		t.eq(MovementController.modeOf("VentScurrying"), "Vent")
		t.eq(MovementController.modeOf("Freestyle"), "Swim")
		t.eq(MovementController.modeOf("Underwater"), "Swim")
		t.eq(MovementController.modeOf("Crouching"), "OnFoot")
		t.eq(MovementController.modeOf("DownedCrawling"), "OnFoot")
		t.truthy(MovementController.isMoving(4, 0), "observed speed")
		t.falsy(MovementController.isMoving(3.9, 0.1), "below both thresholds")
		t.truthy(MovementController.isMoving(0, 0.2), "stick input")
	end,

	["movement: the exhaustion latch sets at empty while sprinting, clears on release or full"] = function(t: Expect)
		local max = GameConfig.StaminaMax
		local update = MovementController.updateExhausted
		t.eq(update(false, true, 50, max), false, "sprinting with stamina")
		t.eq(update(false, true, 0, max), true, "ran dry while holding sprint")
		t.eq(update(true, true, 0.5, max), true, "a sliver of regen does not release it")
		t.eq(update(true, true, max - 1, max), true, "nor does almost full")
		t.eq(update(true, true, max, max), false, "back to full")
		t.eq(update(true, false, 0, max), false, "released")
		t.eq(update(true, false, 30, max), false)
		t.eq(update(false, false, 0, max), false, "empty but not sprinting")
		-- A run dry, regen while held, release, sprint again.
		local exhausted = false
		local stamina = 6
		local sprinting: { boolean } = {}
		for step = 1, 120 do
			local held = step < 90
			exhausted = update(exhausted, held, stamina, max)
			local state = MovementController.deriveState({
				mode = "OnFoot",
				override = nil,
				crouch = false,
				sprint = held,
				dive = false,
				stamina = stamina,
				moving = true,
				exhausted = exhausted,
			})
			table.insert(sprinting, state == "Sprinting")
			if state == "Sprinting" then
				stamina = math.max(0, stamina - GameConfig.StaminaSprintDrain / 60)
			else
				stamina = math.min(max, stamina + GameConfig.StaminaRegen / 60)
			end
		end
		t.truthy(sprinting[1], "sprints at first")
		local stoppedAt: number? = table.find(sprinting, false)
		t.truthy(stoppedAt ~= nil, "runs dry")
		if stoppedAt then
			for held = stoppedAt, 89 do
				t.falsy(sprinting[held], "no stutter while still held, frame " .. held)
			end
		end
	end,

	["movement: no jumping while downed, crawling, hiding, trapped, grabbed or locked"] = function(t: Expect)
		for _, state: Enums.MoveState in
			{ "VentCrawling", "VentScurrying", "DownedCrawling", "Hiding", "Trapped", "Grabbed" } :: { Enums.MoveState }
		do
			t.falsy(MovementController.canJump(state, "Alive", false), state)
		end
		for _, state: Enums.MoveState in { "Standing", "Sprinting", "Crouching", "Treading" } :: { Enums.MoveState } do
			t.truthy(MovementController.canJump(state, "Alive", false), state)
			t.truthy(MovementController.canJump(state, "Lobby", false), state .. " in the lobby")
		end
		t.falsy(MovementController.canJump("Standing", "Downed", false), "downed")
		t.falsy(MovementController.canJump("Standing", "Alive", true), "locked")
		t.eq(MovementController.JumpHeight, 2.5)
	end,

	["movement: the server wins a disagreement longer than the window"] = function(t: Expect)
		local window = MovementController.ReconcileWindow
		local state, since = MovementController.reconcile("Sprinting", "Sprinting", nil, 10, window)
		t.eq(state, "Sprinting")
		t.eq(since, nil)
		state, since = MovementController.reconcile("Sprinting", "Standing", nil, 10, window)
		t.eq(state, "Sprinting", "prediction stands at first")
		t.eq(since, 10)
		state, since = MovementController.reconcile("Sprinting", "Standing", since, 10 + window * 0.9, window)
		t.eq(state, "Sprinting")
		state, since = MovementController.reconcile("Sprinting", "Standing", since, 10 + window + 0.01, window)
		t.eq(state, "Standing", "server wins after the window")
		t.eq(since, 10)
		state, since = MovementController.reconcile("Standing", "Standing", since, 11, window)
		t.eq(state, "Standing")
		t.eq(since, nil, "agreement resets the window")
	end,

	----------------------------------------------------------------------------------------------- Flashlight

	["flashlight: EMF intensity by distance and adjacent vents"] = function(t: Expect)
		local radius = CreatureConfig.Senses.EmfRadius
		t.eq(Flashlight.EmfRadius, 45)
		t.eq(Flashlight.emfIntensity(radius, radius, false), 0, "nothing at the edge")
		t.eq(Flashlight.emfIntensity(radius + 20, radius, false), 0)
		t.eq(Flashlight.emfIntensity(2, radius, false), 1, "full right next to it")
		local previous = 1
		for distance = 0, radius, 1.5 do
			local value = Flashlight.emfIntensity(distance, radius, false)
			t.truthy(value >= 0 and value <= 1, "range")
			t.truthy(value <= previous + 1e-9, "monotone")
			previous = value
		end
		t.truthy(Flashlight.emfIntensity(radius * 0.5, radius, false) > 0.2, "clearly felt half-way")
		t.eq(Flashlight.emfIntensity(500, radius, true), Flashlight.VentAdjacentIntensity, "adjacent vent")
		t.eq(Flashlight.emfIntensity(2, radius, true), 1, "proximity still wins")
		t.eq(Flashlight.emfIntensity(0 / 0, radius, false), 0)
	end,

	["flashlight: flicker is deterministic, bounded, and stronger with intensity"] = function(t: Expect)
		local T0 = 1_700_000_000
		local function stats(intensity: number): (number, number)
			local sum, dark = 0, 0
			for i = 0, 2999 do
				local value = Flashlight.flickerFactor(intensity, T0 + i * 0.017, 42)
				t.truthy(value >= 0 and value <= 1, "range")
				t.eq(value, Flashlight.flickerFactor(intensity, T0 + i * 0.017, 42), "deterministic")
				sum += value
				if value < 0.1 then
					dark += 1
				end
			end
			return sum / 3000, dark / 3000
		end
		t.eq(Flashlight.flickerFactor(0, T0, 42), 1, "no interference")
		local weakMean, weakDark = stats(0.2)
		local strongMean, strongDark = stats(1)
		t.truthy(strongMean < weakMean, "dimmer under strong interference")
		t.truthy(strongDark > weakDark, "more dropouts under strong interference")
		t.truthy(strongDark > 0.2 and strongDark < 0.7, "strong interference stutters but stays usable")
		local differs = false
		for i = 0, 200 do
			if Flashlight.flickerFactor(1, T0 + i * 0.05, 1) ~= Flashlight.flickerFactor(1, T0 + i * 0.05, 2) then
				differs = true
				break
			end
		end
		t.truthy(differs, "each light flickers on its own seed")
	end,

	["flashlight: battery dims below 15 % and dies at 0"] = function(t: Expect)
		t.eq(Flashlight.batteryFactor(1), 1)
		t.eq(Flashlight.batteryFactor(Flashlight.LowBattery), 1)
		t.eq(Flashlight.batteryFactor(0), 0)
		t.truthy(Flashlight.batteryFactor(0.1) < 1 and Flashlight.batteryFactor(0.05) < Flashlight.batteryFactor(0.1))
		t.truthy(Flashlight.batteryFactor(0.001) > 0.25, "still a glow before it dies")
		t.eq(Flashlight.beamColor(1), Flashlight.beamColor(0.5), "full colour above the low mark")
		t.truthy(Flashlight.beamColor(0.01) ~= Flashlight.beamColor(1), "warms as it dies")
		t.eq(Flashlight.sputter(0.5, 100, 1), 1)
		for i = 0, 100 do
			local value = Flashlight.sputter(0.01, i * 0.1, 1)
			t.truthy(value > 0 and value <= 1)
		end
	end,

	["flashlight: the prediction holds for its grace window, then the server wins"] = function(t: Expect)
		local grace = Flashlight.ReconcileGrace
		t.eq(Flashlight.resolveOn(false, nil, nil, 10, grace), false)
		t.eq(Flashlight.resolveOn(true, nil, nil, 10, grace), true)
		t.eq(Flashlight.resolveOn(false, true, 10, 10.2, grace), true, "predicted on")
		t.eq(Flashlight.resolveOn(false, true, 10, 10 + grace + 0.01, grace), false, "refused: server wins")
		t.eq(Flashlight.resolveOn(true, false, 10, 10.1, grace), false, "predicted off")
		t.eq(Flashlight.resolveOn(true, true, 10, 50, grace), true, "agreement")
	end,

	["flashlight: vent segments know their adjacent zones"] = function(t: Expect)
		local folder = Instance.new("Folder")
		folder.Name = "EmfSpecShafts"
		local shaft = part(folder, "Duct", Vector3.new(4, 0.5, 20), CFrame.new(0, -500, 0))
		shaft:SetAttribute(Attributes.World.SegmentId, "SpecNodeA-SpecNodeB")
		shaft:SetAttribute(Attributes.World.AdjacentZones, Attributes.joinList({ "Spec_RoomA", "Spec_RoomB" }))
		shaft:AddTag(Tags.VentShaft)
		folder.Parent = Workspace
		t.truthy(Flashlight.segmentTouches("SpecNodeA-SpecNodeB", "Spec_RoomA"))
		t.truthy(Flashlight.segmentTouches("SpecNodeA-SpecNodeB", "Spec_RoomB"))
		t.falsy(Flashlight.segmentTouches("SpecNodeA-SpecNodeB", "Spec_RoomC"))
		t.falsy(Flashlight.segmentTouches("Unknown-Segment", "Spec_RoomA"))
		t.eq(Flashlight.emfAt(Vector3.new(0, 0, 0), "Spec_RoomA"), 0, "no Creature, no interference")
		folder:Destroy()
	end,

	----------------------------------------------------------------------------------------------- HandRig

	["hands: the flashlight hold follows the look, sprinting lowers it"] = function(t: Expect)
		local eye = CFrame.new(0, 5, 0) * CFrame.fromOrientation(math.rad(-20), math.rad(30), 0)
		local held = HandRig.flashlightTarget(eye, 0)
		t.truthy(held.LookVector:Dot(eye.LookVector) > 0.999, "the torch points along the look")
		local offset = eye:PointToObjectSpace(held.Position)
		t.truthy(offset.Z < -0.5, "in front of the eye")
		t.truthy(offset.X > 0, "on the right")
		t.truthy(offset.Y < 0, "below the eye")
		local carried = HandRig.flashlightTarget(eye, 1)
		t.truthy(carried.Position.Y < held.Position.Y - 0.3, "lowered toward the hip")
		t.truthy(carried.LookVector.Y < -0.3, "pointing down while carried")
		local placement = HandRig.placements("Flashlight", nil, held)
		t.truthy(placement.torchInHand)
		t.eq(placement.right, held)
		t.eq(placement.left, nil, "left hand free")
		t.truthy(HandRig.handsBusy("VentCrawling") and HandRig.handsBusy("DownedCrawling"))
		t.truthy(HandRig.handsBusy("Freestyle"))
		t.falsy(HandRig.handsBusy("Sprinting") or HandRig.handsBusy("Crouching") or HandRig.handsBusy("Standing"))
	end,

	["hands: target poses place both hands relative to the target"] = function(t: Expect)
		local target = CFrame.new(3, 1, -2) * CFrame.Angles(0, 0.7, 0)
		local any = CFrame.identity
		for _, pose: HandRig.Pose in { "Pry", "SlitGrip" } :: { HandRig.Pose } do
			local placement = HandRig.placements(pose, target, any)
			local left, right = placement.left, placement.right
			t.truthy(left ~= nil and right ~= nil, pose .. " uses both hands")
			if left and right then
				local l = target:PointToObjectSpace(left.Position)
				local r = target:PointToObjectSpace(right.Position)
				t.near(l.X, -r.X, 1e-6, pose .. " is symmetric about the target")
				t.truthy(l.X < 0 and r.X > 0, pose .. " left hand left, right hand right")
			end
			t.falsy(placement.torchInHand, pose .. " stows the torch")
			t.truthy(placement.leftGrip > 0.5 and placement.rightGrip > 0.5, pose .. " grips")
		end
		local ripcord = HandRig.placements("Ripcord", target, any)
		local hand = ripcord.right
		t.truthy(hand ~= nil and (hand.Position - target.Position).Magnitude < 1e-6, "right hand on the handle")
		local free = HandRig.placements("Free", target, any)
		t.eq(free.left, nil)
		t.eq(free.right, nil)
		local missing = HandRig.placements("Pry", nil, any)
		t.eq(missing.right, nil, "a target pose without a target falls back to free hands")
		local flask = HandRig.placements("Flask", target, any)
		t.eq(flask.right, target, "the flask hand goes exactly where its owner puts it")
		t.eq(flask.left, nil, "left hand free")
		t.falsy(flask.torchInHand, "the torch rides on the chest while a flask is held")
		t.eq(HandRig.placements("Flask", nil, any).right, nil, "no flask target: free hands")
		t.eq(#HandRig.Poses, 6)
	end,

	----------------------------------------------------------------------------------------------- BodyRenderer

	["body renderer: head, face and head accessories hide; the body stays visible"] = function(t: Expect)
		local model, root, _, upper, head = r15Rig()
		local face = Instance.new("Decal")
		face.Name = "face"
		face.Parent = head
		local hatAttachment = Instance.new("Attachment")
		hatAttachment.Name = "HatAttachment"
		hatAttachment.Parent = head

		local hat = Instance.new("Accessory")
		hat.Parent = model
		local hatHandle = part(hat, "Handle", Vector3.new(1, 1, 1), CFrame.new(0, 5.4, 0))
		local hatWeld = Instance.new("Weld")
		hatWeld.Name = "AccessoryWeld"
		hatWeld.Part0 = hatHandle
		hatWeld.Part1 = head
		hatWeld.Parent = hatHandle

		local hair = Instance.new("Accessory")
		hair.Parent = model
		local hairHandle = part(hair, "Handle", Vector3.new(1, 1, 1), CFrame.new(0, 5.2, 0))
		local hairAttachment = Instance.new("Attachment")
		hairAttachment.Name = "HatAttachment"
		hairAttachment.Parent = hairHandle

		local backpack = Instance.new("Accessory")
		backpack.Parent = model
		local packHandle = part(backpack, "Handle", Vector3.new(1, 1, 1), CFrame.new(0, 3.2, 0.8))
		local packWeld = Instance.new("Weld")
		packWeld.Part0 = packHandle
		packWeld.Part1 = upper
		packWeld.Parent = packHandle

		local glasses = part(model, "Glasses", Vector3.new(1, 0.2, 0.2), CFrame.new(0, 4.6, -0.6))
		local glassesWeld = Instance.new("WeldConstraint")
		glassesWeld.Part0 = head
		glassesWeld.Part1 = glasses
		glassesWeld.Parent = head

		t.truthy(BodyRenderer.isHeadAttached(head, head), "the head")
		t.truthy(BodyRenderer.isHeadAttached(hatHandle, head), "welded to the head")
		t.truthy(BodyRenderer.isHeadAttached(hairHandle, head), "worn on a head attachment")
		t.truthy(BodyRenderer.isHeadAttached(glasses, head), "held by a weld inside the head")
		t.falsy(BodyRenderer.isHeadAttached(upper, head), "the Neck motor does not make the torso head")
		t.falsy(BodyRenderer.isHeadAttached(root, head))
		t.falsy(BodyRenderer.isHeadAttached(packHandle, head), "a back accessory stays visible")
		t.falsy(BodyRenderer.isHeadAttached(head, nil), "no head, nothing hidden")
		model:Destroy()
	end,
}
