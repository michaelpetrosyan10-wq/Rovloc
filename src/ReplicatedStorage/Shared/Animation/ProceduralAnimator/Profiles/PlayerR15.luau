--!strict
-- PlayerR15: the player character's animation profile (CharacterService's normalized R15 rigs).
--
-- Every number that depends on the body is measured from the rig's JointMap (leg and arm bone lengths, hip and
-- shoulder pivots, ankle height and foot extent, the floor under a Humanoid), so the profile fits any R15 build.
-- Rig axes: X right, Y up, -Z forward, origin at the HumanoidRootPart's centre.
--
-- On foot (Standing, Sprinting, Crouching, Scripted, Hiding): the feet are IK targets. Each foot runs the shared
-- cycle phase through ProceduralAnimator.footCycle: planted, it slides back by exactly the distance the body travels
-- during its stance (no foot sliding), heel strike rolling to toe-off; then it swings forward on a cycloid while
-- lifting. Stride and duty come from the speed and are capped by what the legs can reach (the heel / toe pivot
-- raises the ankle at contact and lift-off, so the reach is asymmetric: runners push off far behind the hip). The
-- pelvis drops with speed, bobs twice a cycle (lowest at contact when walking, at mid-stance when running), sways
-- over the stance foot, yaws with the forward leg and dips on the swing side; the chest counter-rotates; the arms
-- swing against the legs with the elbows bending on the forward swing. The body leans into speed and acceleration
-- (ctx.leanPitch / leanRoll); the lower body yaws toward the travel direction for strafing and backpedalling.
-- Standing still: soft knees, a slow weight shift, breathing (faster and deeper when winded), loose arms. Turning on
-- the spot plants the feet (twist) and steps round. In the air the legs tuck and the arms rise; landing compresses.
--
-- Crawling (VentCrawling, VentScurrying): prone on forearms and knees inside the 3.5-stud bore (the root rides the
-- duct centreline, so the bore floor is VentBore / 2 below it). Diagonal limbs move together; the hands and knees
-- are planted the same way as feet. The body sits behind the eye point CameraConfig puts at (0, -0.6, -0.5), so the
-- first-person camera looks over the forearms down the duct.
-- DownedCrawling: lying on the floor, chest propped on the elbows, pulling with alternating arms, legs dragging.
-- Swimming: Treading (upright, eggbeater legs, sculling arms), Freestyle (front crawl with body roll and flutter
-- kick), Underwater (breaststroke arms and frog kick, glide). Hiding: still, arms drawn in, slow breathing.
-- Trapped: right foot caught, kneeling on the left knee, hands tugging at the trap. Grabbed: flailing. Parachuting:
-- hanging in the harness with the hands up on the risers. Scripted: neutral standing. Dead: limp, face down.
-- Hand targets (HandRig's flashlight, pry, ripcord and slit-grip holds) take over the arms on foot, hiding, trapped
-- and parachuting; crawling, swimming strokes, flailing and the dead keep their own arms (half while treading).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local ProceduralAnimator = require(script.Parent.Parent)

type Ctx = ProceduralAnimator.MotionContext
type Pose = ProceduralAnimator.PoseBuilder
type JointMap = ProceduralAnimator.JointMap
type Profile = ProceduralAnimator.Profile
type StateSpec = ProceduralAnimator.StateSpec

local JointMap = ProceduralAnimator.JointMap

local euler = ProceduralAnimator.euler
local footCycle = ProceduralAnimator.footCycle
local ankleLift = ProceduralAnimator.ankleLift
local lerp = MathUtil.lerp
local remap = MathUtil.remapClamped
local smoothstep = MathUtil.smoothstep
local rad = math.rad
local TAU = 2 * math.pi

--------------------------------------------------------------------------------
-- Names
--------------------------------------------------------------------------------

local SIDES: { string } = { "Left", "Right" }
local SIGN: { [string]: number } = { Left = -1, Right = 1 }
local PLANT: { [string]: number } = { Left = 0, Right = 0.5 } -- foot contact phase
local OPPOSITE: { [string]: string } = { Left = "Right", Right = "Left" }

local function names(suffix: string): { [string]: string }
	return { Left = "Left" .. suffix, Right = "Right" .. suffix }
end

local HIP = names("Hip")
local KNEE = names("Knee")
local ANKLE = names("Ankle")
local SHOULDER = names("Shoulder")
local ELBOW = names("Elbow")
local WRIST = names("Wrist")
local LEG = names("Leg")
local ARM = names("Arm")
local FOOT_PART = names("Foot")

local ROOT = "Root"
local WAIST = "Waist"
local NECK = "Neck"

local REQUIRED: { string } = {
	"Root",
	"Waist",
	"Neck",
	"LeftShoulder",
	"LeftElbow",
	"LeftWrist",
	"RightShoulder",
	"RightElbow",
	"RightWrist",
	"LeftHip",
	"LeftKnee",
	"LeftAnkle",
	"RightHip",
	"RightKnee",
	"RightAnkle",
}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local FORWARD = Vector3.new(0, 0, -1)
local REACH = 0.985 -- share of the leg length a planted foot may reach at the ends of its stance
local VENT_FLOOR = -WorldConfig.VentBore / 2 -- bore floor below the root (the root rides the duct centreline)
local VENT_SHOULDER_Z = -0.05 -- shoulders sit just behind the vent eye point (CameraConfig: z -0.5)
local DOWNED_NECK_Z = 0.35 -- neck pivot just behind the downed eye point (CameraConfig: under the root)
local FLOOR_CLEARANCE = 0.12 -- torso parts lying on the floor stay this far above it (no physics contact)
local PAD = 0.03 -- limbs resting on the floor stay this far above it

--------------------------------------------------------------------------------
-- Measurements (per rig, cached)
--------------------------------------------------------------------------------

type Measure = {
	ground: number, -- rig-space floor
	leg: number, -- hip -> knee -> ankle
	thigh: number,
	shin: number,
	upperArm: number,
	forearm: number,
	arm: number, -- shoulder -> wrist
	hip: { [string]: Vector3 }, -- rest pivots
	shoulder: { [string]: Vector3 },
	pelvis: Vector3, -- Root joint pivot
	waist: Vector3,
	neck: Vector3,
	standHip: number, -- rest hip height above the floor
	ankle: number, -- ankle pivot above the sole
	toe: number, -- sole extent ahead of the ankle pivot
	heel: number, -- sole extent behind it
	shoulderRise: number, -- waist -> shoulder pivots, along the spine
	spine: number, -- waist -> neck
	sizes: { [string]: Vector3 },
	kneePad: number, -- knee pivot above the floor when kneeling (half the shin's thickness)
	elbowPad: number, -- elbow pivot above the floor when resting on the forearm
	wristPad: number, -- wrist pivot above the floor with the hand flat (palm down)
}

local measured: { [JointMap]: Measure } = setmetatable({} :: any, { __mode = "k" })

-- Half the smaller cross-section of a limb part (how far its axis sits above the floor when it lies on it).
local function halfThickness(sizes: { [string]: Vector3 }, part: string): number
	local size = sizes[part]
	if not size then
		return 0.5
	end
	return math.min(size.X, size.Z) * 0.5
end

local function measure(map: JointMap): Measure
	local cached = measured[map]
	if cached then
		return cached
	end
	local pivot = function(name: string): Vector3
		return JointMap.pivot(map, name)
	end
	local hip = { Left = pivot("LeftHip"), Right = pivot("RightHip") }
	local shoulder = { Left = pivot("LeftShoulder"), Right = pivot("RightShoulder") }
	local thigh = JointMap.distance(map, "RightHip", "RightKnee")
	local shin = JointMap.distance(map, "RightKnee", "RightAnkle")
	local upperArm = JointMap.distance(map, "RightShoulder", "RightElbow")
	local forearm = JointMap.distance(map, "RightElbow", "RightWrist")
	local anklePivot = pivot("RightAnkle")
	local footPart = FOOT_PART.Right
	local ankle = anklePivot.Y - JointMap.lowestPoint(map, footPart)
	local behind, ahead = JointMap.extentAlong(map, footPart, anklePivot, FORWARD)
	local waist = pivot("Waist")
	local neck = pivot("Neck")
	local sizes: { [string]: Vector3 } = {}
	for name, part in map.parts do
		sizes[name] = part.Size
	end
	local result: Measure = {
		ground = map.groundY,
		leg = thigh + shin,
		thigh = thigh,
		shin = shin,
		upperArm = upperArm,
		forearm = forearm,
		arm = upperArm + forearm,
		hip = hip,
		shoulder = shoulder,
		pelvis = pivot("Root"),
		waist = waist,
		neck = neck,
		standHip = hip.Right.Y - map.groundY,
		ankle = math.max(0.05, ankle),
		toe = math.max(0.1, ahead),
		heel = math.max(0.05, -behind),
		shoulderRise = math.max(0.2, shoulder.Right.Y - waist.Y),
		spine = math.max(0.3, neck.Y - waist.Y),
		sizes = sizes,
		kneePad = halfThickness(sizes, "RightLowerLeg") + PAD,
		elbowPad = halfThickness(sizes, "RightLowerArm") + PAD,
		wristPad = (sizes.RightHand or Vector3.new(0.6, 0.3, 0.6)).X * 0.5 + PAD,
	}
	measured[map] = result
	return result
end

--------------------------------------------------------------------------------
-- Shared helpers
--------------------------------------------------------------------------------

-- Rotation of `v` about the rig's vertical axis by `angle` (CFrame.Angles(0, angle, 0) convention).
local function yawed(v: Vector3, angle: number): Vector3
	if angle == 0 then
		return v
	end
	local c, s = math.cos(angle), math.sin(angle)
	return Vector3.new(v.X * c + v.Z * s, v.Y, -v.X * s + v.Z * c)
end

-- Lowest rig-space height of a part's box under the pose so far.
local function lowestOf(pose: Pose, m: Measure, part: string): number
	local frame = pose:frame(part)
	local half = (m.sizes[part] or Vector3.one) * 0.5
	local extent = math.abs(frame.XVector.Y) * half.X
		+ math.abs(frame.YVector.Y) * half.Y
		+ math.abs(frame.ZVector.Y) * half.Z
	return frame.Position.Y - extent
end

-- Moves the whole body (the Root entry) by `offset` in rig axes.
local function shiftBody(pose: Pose, offset: Vector3)
	pose:set(ROOT, CFrame.new(offset) * pose:get(ROOT))
end

-- Lifts / lowers the body so the lowest of `parts` sits `clearance` above `floor`.
local function restOnFloor(pose: Pose, m: Measure, parts: { string }, floor: number, clearance: number)
	local lowest = math.huge
	for _, part in parts do
		lowest = math.min(lowest, lowestOf(pose, m, part))
	end
	if lowest < math.huge then
		shiftBody(pose, Vector3.new(0, floor + clearance - lowest, 0))
	end
end

-- A face-down body: pitched forward by `pitch` (about -pi/2), then rolled about the rig's long (Z) axis and yawed
-- about the vertical. (euler() rolls about the pelvis' own Z, which points up once the body lies down.)
local function prone(pitch: number, yaw: number, roll: number): CFrame
	return CFrame.Angles(0, yaw, 0) * CFrame.Angles(0, 0, roll) * CFrame.Angles(pitch, 0, 0)
end

-- Hand rotation (relative to rest, rig space) with the palm down and the fingers pointing along the yaw.
local function palmDown(side: string, yaw: number): CFrame
	return CFrame.Angles(0, yaw, 0) * CFrame.Angles(0, 0, SIGN[side] * math.pi / 2) * CFrame.Angles(math.pi / 2, 0, 0)
end

-- Ankle IK target for a foot standing at (x, z) with `pitch`, lifted `lift` above the (probed) floor.
local function anklePoint(
	m: Measure,
	ctx: Ctx,
	side: string,
	x: number,
	z: number,
	lift: number,
	pitch: number
): Vector3
	local y = m.ground + m.ankle + lift + ctx.ground[side] + ankleLift(pitch, m.ankle, m.heel, m.toe)
	return Vector3.new(x, y, z)
end

local function kneePole(side: string, yaw: number): Vector3
	return yawed(Vector3.new(SIGN[side] * 0.18, 0, -1), yaw)
end

local function noise(t: number, seed: number): number
	return math.noise(t, seed * 7.31 + 0.5, 3.7)
end

--------------------------------------------------------------------------------
-- Upright gaits
--------------------------------------------------------------------------------

type ArmStyle = {
	swing: (speed: number) -> number, -- arm swing amplitude, radians
	pitch: number, -- mean shoulder flexion
	elbow: (speed: number) -> number, -- mean elbow bend
	elbowSwing: number, -- extra elbow bend per radian of forward swing
	out: number, -- shoulder abduction
}

type GaitStyle = {
	-- Still.
	idleDrop: number, -- pelvis drop, share of the leg
	idleWidth: number, -- foot spacing relative to the hips
	idleStagger: number, -- left foot ahead of the right, share of the leg
	idleLean: number, -- forward lean, radians
	idleArmPitch: number,
	idleElbow: number,
	-- Moving (curves over speed, studs/s).
	duty: (speed: number) -> number,
	drop: (speed: number) -> number, -- share of the leg
	stride: (speed: number) -> number, -- wanted stance length, share of the leg
	lift: (speed: number) -> number, -- swing clearance, share of the leg
	lean: (speed: number) -> number, -- forward lean, radians
	bias: number, -- stance centre ahead of the hip, share of the leg
	bob: number, -- vertical bob, share of the leg
	sway: number, -- lateral pelvis sway, share of the leg
	pelvisYaw: number,
	pelvisRoll: number,
	chestYaw: number, -- chest counter-rotation (world)
	width: number, -- foot spacing relative to the hips
	strike: number, -- foot pitch at heel strike
	toeOff: number, -- foot pitch at toe-off
	liftPeak: number,
	toeOut: number,
	arms: ArmStyle,
	breath: number, -- chest pitch per breath, radians
}

type Gait = {
	duty: number,
	stance: number, -- stance length at full stride (studs)
	centre: number, -- stance centre ahead of the hip (studs)
	drop: number, -- pelvis drop (studs)
	lift: number, -- swing clearance (studs)
}

-- Stride numbers for `style` at `speed`, capped by the legs' reach.
local function gaitAt(style: GaitStyle, speed: number, m: Measure): Gait
	local leg = m.leg
	local duty = style.duty(speed)
	local drop = style.drop(speed) * leg
	local reach = REACH * leg
	local height = m.standHip - m.ankle - drop + style.bob * leg
	local frontHeight = height - ankleLift(style.strike, m.ankle, m.heel, m.toe)
	local backHeight = height - ankleLift(style.toeOff, m.ankle, m.heel, m.toe)
	local front = math.sqrt(math.max(0, reach * reach - frontHeight * frontHeight))
	local back = math.sqrt(math.max(0, reach * reach - backHeight * backHeight))
	local stance = math.max(0.05, math.min(style.stride(speed) * leg, front + back))
	local lowest, highest = stance / 2 - back, front - stance / 2
	local centre = if lowest < highest then math.clamp(style.bias * leg, lowest, highest) else (front - back) / 2
	return { duty = duty, stance = stance, centre = centre, drop = drop, lift = style.lift(speed) * leg }
end

local function cycleFor(style: GaitStyle, turnStep: number): ProceduralAnimator.CycleSpec
	return {
		length = function(speed: number, map: JointMap): number
			local gait = gaitAt(style, speed, measure(map))
			return gait.stance / gait.duty
		end,
		turnStep = turnStep,
	}
end

-- Arms hanging and swinging against the legs.
local function swingArms(ctx: Ctx, pose: Pose, style: GaitStyle, move: number, lean: number)
	local arms = style.arms
	local speed = ctx.speed
	local idle = 1 - move
	local swingAmount = arms.swing(speed) * move
	local air = ctx.airborne
	for _, side in SIDES do
		local s = SIGN[side]
		-- +1 when this side's foot is at its furthest forward (contact); the arm is then back.
		local legForward = math.cos(TAU * (ctx.phase - PLANT[side] - 0.03))
		local swing = -swingAmount * legForward
		local drift = idle * rad(2.2) * noise(ctx.time * 0.27, ctx.seed * 13 + s)
		local breathe = idle * ctx.breath * rad(0.8) * (1 + ctx.exertion)
		local pitch = lerp(style.idleArmPitch, arms.pitch, move) + swing + drift + lean * 0.35 + air * rad(16)
		local out = arms.out + breathe + air * rad(24) - math.max(0, swing) * 0.12
		pose:set(SHOULDER[side], euler(pitch, 0, s * out))
		local elbow = lerp(style.idleElbow, arms.elbow(speed), move) + arms.elbowSwing * math.max(0, swing)
		pose:set(ELBOW[side], euler(elbow + air * rad(14), 0, 0))
		pose:set(WRIST[side], euler(0, 0, -s * rad(8 + 6 * move)))
	end
end

-- Pelvis, chest and both legs for an upright gait.
local function upright(ctx: Ctx, pose: Pose, style: GaitStyle)
	local m = measure(ctx.map)
	local leg = m.leg
	local move = ctx.moveAmount
	local idle = 1 - move
	local speed = ctx.speed
	local phase = ctx.phase
	local gait = gaitAt(style, speed, m)
	local stance = gait.duty * ctx.cycleLength * move
	local centre = gait.centre * move
	local turnLift = ctx.turnAmount * 0.55 * (1 - move)
	local lift = gait.lift * math.max(move, turnLift)
	local drop = lerp(style.idleDrop * leg, gait.drop, move)
	local midStance = gait.duty / 2
	local bobCentre = remap(gait.duty, 0.6, 0.42, 0, midStance)

	-- Pelvis.
	local bob = -style.bob * leg * move * math.cos(2 * TAU * (phase - bobCentre))
	local sway = -style.sway * leg * move * math.cos(TAU * (phase - midStance))
	local shift = idle * leg * 0.035 * noise(ctx.time * 0.11, ctx.seed * 5)
	local airTuck = ctx.airborne * leg * 0.06
	local height = -drop + bob - ctx.landing + airTuck
	local lean = lerp(style.idleLean, style.lean(speed), move)
	local oscillation = math.cos(TAU * phase)
	local pelvisYaw = ctx.hipYaw - style.pelvisYaw * move * oscillation
	local chestYaw = style.chestYaw * move * oscillation
	local pelvisRoll = -style.pelvisRoll * move * math.cos(TAU * (phase - midStance))
		+ idle * rad(2.5) * noise(ctx.time * 0.11, ctx.seed * 5)
	pose:set(
		ROOT,
		CFrame.new(sway + shift, height, 0)
			* euler(-lean * 0.35 + ctx.leanPitch * 0.4, pelvisYaw, pelvisRoll + ctx.leanRoll * 0.5)
	)
	local breathe = ctx.breath * style.breath * (1 + 1.5 * ctx.exertion) * (0.4 + 0.6 * idle)
	pose:set(
		WAIST,
		euler(
			-lean * 0.65 + ctx.leanPitch * 0.6 + breathe,
			chestYaw - pelvisYaw,
			-pelvisRoll * 0.6 + ctx.leanRoll * 0.5
		)
	)

	-- Legs.
	local width = lerp(style.idleWidth, style.width, move)
	for _, side in SIDES do
		local s = SIGN[side]
		local cycle = footCycle(phase - PLANT[side], stance, {
			duty = gait.duty,
			lift = lift,
			liftPeak = style.liftPeak,
			strike = style.strike * move,
			toeOff = style.toeOff * move,
		})
		local hip = m.hip[side]
		local stagger = -s * style.idleStagger * leg * 0.5 * idle
		local flat = Vector3.new(hip.X * width, 0, stagger) + ctx.travel * (cycle.along + centre)
		local position = yawed(yawed(flat, ctx.hipYaw), ctx.twist[side])
		local tuck = ctx.airborne * leg * 0.22
		local target = anklePoint(m, ctx, side, position.X, position.Z, cycle.lift + tuck, cycle.pitch)
		local yaw = ctx.hipYaw + ctx.twist[side] - s * style.toeOut
		pose:limb(LEG[side], target, kneePole(side, yaw), euler(cycle.pitch + ctx.airborne * rad(18), yaw, 0))
		pose:plant(side, cycle.stance or cycle.lift < 0.01 * leg)
	end

	swingArms(ctx, pose, style, move, lean)
end

local WALK: GaitStyle = {
	idleDrop = 0.025,
	idleWidth = 1.05,
	idleStagger = 0.06,
	idleLean = rad(2),
	idleArmPitch = rad(3),
	idleElbow = rad(13),
	duty = function(speed: number): number
		return remap(speed, 3, 10, 0.6, 0.36)
	end,
	drop = function(speed: number): number
		return remap(speed, 2, 11, 0.035, 0.14)
	end,
	stride = function(speed: number): number
		return remap(speed, 0, 11, 0.5, 1.3)
	end,
	lift = function(speed: number): number
		return remap(speed, 0, 11, 0.07, 0.2)
	end,
	lean = function(speed: number): number
		return remap(speed, 0, 11, rad(1), rad(7))
	end,
	bias = 0.02,
	bob = 0.022,
	sway = 0.028,
	pelvisYaw = rad(7),
	pelvisRoll = rad(4),
	chestYaw = rad(6),
	width = 0.95,
	strike = rad(12),
	toeOff = rad(-30),
	liftPeak = 0.38,
	toeOut = rad(6),
	arms = {
		swing = function(speed: number): number
			return remap(speed, 0, 11, rad(10), rad(30))
		end,
		pitch = rad(-9),
		elbow = function(speed: number): number
			return remap(speed, 2, 11, rad(14), rad(62))
		end,
		elbowSwing = 0.45,
		out = rad(5),
	},
	breath = rad(1.4),
}

local SPRINT: GaitStyle = {
	idleDrop = 0.05,
	idleWidth = 1.05,
	idleStagger = 0.08,
	idleLean = rad(6),
	idleArmPitch = rad(8),
	idleElbow = rad(30),
	duty = function(speed: number): number
		return remap(speed, 10, 19, 0.36, 0.27)
	end,
	drop = function(speed: number): number
		return remap(speed, 10, 19, 0.14, 0.2)
	end,
	stride = function(_speed: number): number
		return 1.6
	end,
	lift = function(speed: number): number
		return remap(speed, 10, 19, 0.22, 0.32)
	end,
	lean = function(speed: number): number
		return remap(speed, 8, 19, rad(8), rad(15))
	end,
	bias = -0.08,
	bob = 0.035,
	sway = 0.014,
	pelvisYaw = rad(9),
	pelvisRoll = rad(3),
	chestYaw = rad(10),
	width = 0.8,
	strike = rad(8),
	toeOff = rad(-42),
	liftPeak = 0.33,
	toeOut = rad(3),
	arms = {
		swing = function(speed: number): number
			return remap(speed, 8, 19, rad(36), rad(52))
		end,
		pitch = rad(-6),
		elbow = function(speed: number): number
			return remap(speed, 8, 19, rad(75), rad(90))
		end,
		elbowSwing = 0.2,
		out = rad(8),
	},
	breath = rad(2),
}

local CROUCH: GaitStyle = {
	idleDrop = 0.46,
	idleWidth = 1.28,
	idleStagger = 0.16,
	idleLean = rad(24),
	idleArmPitch = rad(28),
	idleElbow = rad(70),
	duty = function(speed: number): number
		return remap(speed, 0, 6, 0.66, 0.6)
	end,
	drop = function(speed: number): number
		return remap(speed, 0, 6, 0.46, 0.43)
	end,
	stride = function(speed: number): number
		return remap(speed, 0, 6, 0.35, 1.05)
	end,
	lift = function(_speed: number): number
		return 0.13
	end,
	lean = function(_speed: number): number
		return rad(24)
	end,
	bias = 0.03,
	bob = 0.018,
	sway = 0.04,
	pelvisYaw = rad(5),
	pelvisRoll = rad(3),
	chestYaw = rad(4),
	width = 1.18,
	strike = rad(8),
	toeOff = rad(-22),
	liftPeak = 0.45,
	toeOut = rad(10),
	arms = {
		swing = function(_speed: number): number
			return rad(12)
		end,
		pitch = rad(28),
		elbow = function(_speed: number): number
			return rad(72)
		end,
		elbowSwing = 0.3,
		out = rad(12),
	},
	breath = rad(1.2),
}

local NEUTRAL: GaitStyle = table.clone(WALK)
NEUTRAL.idleStagger = 0
NEUTRAL.idleWidth = 1
NEUTRAL.idleLean = 0
NEUTRAL.breath = rad(0.6)

local HIDE: GaitStyle = table.clone(WALK)
HIDE.idleDrop = 0.06
HIDE.idleWidth = 0.92
HIDE.idleStagger = 0.02
HIDE.idleLean = rad(8)
HIDE.breath = rad(0.9)

local function standing(ctx: Ctx, pose: Pose)
	upright(ctx, pose, WALK)
end

local function sprinting(ctx: Ctx, pose: Pose)
	upright(ctx, pose, SPRINT)
end

local function crouching(ctx: Ctx, pose: Pose)
	upright(ctx, pose, CROUCH)
end

local function scripted(ctx: Ctx, pose: Pose)
	upright(ctx, pose, NEUTRAL)
end

-- In a locker: knees soft, shoulders drawn in, hands held close to the chest, breath kept shallow.
local function hiding(ctx: Ctx, pose: Pose)
	upright(ctx, pose, HIDE)
	local m = measure(ctx.map)
	local chest = pose:frame("UpperTorso").Rotation
	local breathe = ctx.breath * 0.025
	for _, side in SIDES do
		local s = SIGN[side]
		local shoulder = pose:pivot(SHOULDER[side])
		local inward = math.abs(m.shoulder[side].X) - 0.32
		local target = shoulder + chest * Vector3.new(-s * inward, -m.upperArm * 0.6 + breathe, -0.62)
		local pole = chest * Vector3.new(s * 0.9, -1, 0.25)
		pose:limb(ARM[side], target, pole, chest * CFrame.Angles(math.pi * 0.42, s * rad(25), 0))
	end
end

--------------------------------------------------------------------------------
-- Crawling in a duct
--------------------------------------------------------------------------------

type CrawlStyle = {
	duty: number,
	stride: number, -- stance length, share of the leg
	handLift: number, -- studs
	kneeLift: number,
	reach: number, -- hands ahead of the shoulders, share of the forearm
	bodyRoll: number,
	bodyYaw: number,
	chestRise: number, -- radians the chest lifts above the hips
	neck: number, -- neck extension (look down the duct)
}

local function crawlCycle(style: CrawlStyle): ProceduralAnimator.CycleSpec
	return {
		length = function(_speed: number, map: JointMap): number
			return style.stride * measure(map).leg / style.duty
		end,
		turnStep = 0.8,
	}
end

local function vent(ctx: Ctx, pose: Pose, style: CrawlStyle)
	local m = measure(ctx.map)
	local floor = VENT_FLOOR
	local move = ctx.moveAmount
	local phase = ctx.phase
	local stance = style.duty * ctx.cycleLength * move
	-- Travel along the duct only (forward or backward); the body never yaws inside the bore.
	local direction = if ctx.heading.Z > 0.3 then 1 else -1
	local oscillation = math.sin(TAU * phase)

	-- Body: pelvis face down, the hips over the knees, the chest over the elbows.
	local roll = style.bodyRoll * move * oscillation
	pose:set(ROOT, prone(-math.pi / 2 + rad(4), style.bodyYaw * move * oscillation, roll))
	-- Waist axes are the pelvis' own: yaw twists the chest about the spine, roll bends it sideways.
	pose:set(WAIST, euler(style.chestRise + ctx.breath * rad(1.2), -roll * 0.5, 0))
	pose:set(NECK, euler(style.neck, 0, 0))
	-- Thighs vertical at mid-stance put the knees on the floor; they rock up a little toward either end.
	local hipHeight = floor + m.kneePad + m.thigh
	local hipNow = pose:pivot(HIP.Left)
	local shoulderNow = pose:pivot(SHOULDER.Left)
	shiftBody(pose, Vector3.new(0, hipHeight - hipNow.Y, VENT_SHOULDER_Z - shoulderNow.Z))

	for _, side in SIDES do
		local s = SIGN[side]
		-- Diagonal pairs: the left hand moves with the right knee.
		local handCycle = footCycle(phase - PLANT[side], stance, { duty = style.duty, lift = style.handLift * move })
		local kneeCycle =
			footCycle(phase - PLANT[OPPOSITE[side]], stance, { duty = style.duty, lift = style.kneeLift * move })

		local shoulder = pose:pivot(SHOULDER[side])
		local handZ = shoulder.Z - m.forearm * style.reach - direction * handCycle.along
		local wrist = Vector3.new(s * math.abs(shoulder.X) * 0.92, floor + m.wristPad + handCycle.lift, handZ)
		pose:limb(ARM[side], wrist, Vector3.new(s * 0.35, -1, 0.45), palmDown(side, -s * rad(12)))

		local hip = pose:pivot(HIP[side])
		local kneeZ = hip.Z + 0.12 - direction * kneeCycle.along
		local dz = kneeZ - hip.Z
		local drop = math.sqrt(math.max(0.01, m.thigh * m.thigh - dz * dz))
		local knee = Vector3.new(hip.X, hip.Y - drop + kneeCycle.lift, kneeZ)
		pose:aim(HIP[side], knee - hip)
		-- Shin flat along the bore floor (dragged up a little in the swing), the top of the foot down behind it.
		pose:aim(KNEE[side], Vector3.new(0, 0.03 + kneeCycle.lift * 0.6, 1))
		pose:set(ANKLE[side], euler(-rad(78), 0, 0))
	end
end

local VENT_SLOW: CrawlStyle = {
	duty = 0.66,
	stride = 0.42,
	handLift = 0.28,
	kneeLift = 0.12,
	reach = 0.92,
	bodyRoll = rad(4),
	bodyYaw = rad(3),
	chestRise = rad(4),
	neck = rad(50),
}

local VENT_FAST: CrawlStyle = {
	duty = 0.56,
	stride = 0.6,
	handLift = 0.36,
	kneeLift = 0.18,
	reach = 1,
	bodyRoll = rad(6),
	bodyYaw = rad(5),
	chestRise = rad(2),
	neck = rad(45),
}

local function ventCrawling(ctx: Ctx, pose: Pose)
	vent(ctx, pose, VENT_SLOW)
end

local function ventScurrying(ctx: Ctx, pose: Pose)
	vent(ctx, pose, VENT_FAST)
end

--------------------------------------------------------------------------------
-- On the floor
--------------------------------------------------------------------------------

-- Lies the pelvis face down on the floor with the neck at DOWNED_NECK_Z, chest raised by `chestRise`; `roll`
-- rocks the body about its length, `yaw` swings it sideways, and the chest counters both.
local function proneBody(pose: Pose, m: Measure, chestRise: number, roll: number, yaw: number)
	pose:set(ROOT, prone(-math.pi / 2, yaw, roll))
	pose:set(WAIST, euler(chestRise, -roll * 0.6, -yaw * 0.6))
	restOnFloor(pose, m, { "LowerTorso" }, m.ground, FLOOR_CLEARANCE)
	local neck = pose:pivot(NECK)
	shiftBody(pose, Vector3.new(0, 0, DOWNED_NECK_Z - neck.Z))
end

local DOWNED_DUTY = 0.6

local function downed(ctx: Ctx, pose: Pose)
	local m = measure(ctx.map)
	local move = ctx.moveAmount
	local phase = ctx.phase
	local stance = DOWNED_DUTY * ctx.cycleLength * move
	local direction = if ctx.heading.Z > 0.3 then 1 else -1
	local pull = math.sin(TAU * phase)
	local effort = 1 + ctx.exertion
	local laboured = ctx.breath * rad(2.2) * effort
	-- Elbows on the floor: lift the chest until the shoulders sit an upper arm (slightly angled) above them.
	local shoulderHeight = m.ground + m.elbowPad + m.upperArm * 0.8
	local rise = math.asin(math.clamp((shoulderHeight - (m.ground + 0.62)) / m.shoulderRise, 0, 0.95))
	proneBody(pose, m, rise + laboured, rad(4) * move * pull, rad(5) * move * pull)

	for _, side in SIDES do
		local s = SIGN[side]
		local cycle = footCycle(phase - PLANT[side], stance, { duty = DOWNED_DUTY, lift = 0.32 * move })
		local shoulder = pose:pivot(SHOULDER[side])
		local shiver = rad(1.5) * noise(ctx.time * 3.1, ctx.seed * 3 + s) * (1 - move)
		local wrist = Vector3.new(
			s * math.abs(shoulder.X) * 0.82,
			m.ground + m.wristPad + cycle.lift,
			shoulder.Z - m.forearm * 0.95 - m.upperArm * 0.35 - direction * cycle.along
		)
		pose:limb(ARM[side], wrist, Vector3.new(s * 0.55, -1, 0.35), palmDown(side, -s * rad(18) + shiver))

		-- Legs drag: straight back, slightly apart; the leg opposite the pulling arm pushes with a bent knee.
		local push = math.max(0, math.sin(TAU * (phase - PLANT[OPPOSITE[side]]))) * move
		pose:set(HIP[side], euler(rad(-2) - push * rad(6), s * rad(3), s * rad(6)))
		pose:set(KNEE[side], euler(-rad(6) - push * rad(32), 0, 0))
		pose:set(ANKLE[side], euler(-rad(62), 0, 0))
	end
end

local function dead(ctx: Ctx, pose: Pose)
	local m = measure(ctx.map)
	proneBody(pose, m, rad(-2), rad(3), rad(2))
	pose:set(NECK, euler(rad(-4), rad(72), rad(-8)))
	-- One arm flung out on the floor past the head, the other limp along the body (both level with the torso).
	pose:set(SHOULDER.Left, euler(rad(178), rad(10), rad(-34)))
	pose:set(ELBOW.Left, euler(rad(6), 0, 0))
	pose:set(WRIST.Left, euler(rad(-10), 0, rad(20)))
	pose:set(SHOULDER.Right, euler(rad(-2), rad(-6), rad(16)))
	pose:set(ELBOW.Right, euler(rad(5), 0, 0))
	pose:set(WRIST.Right, euler(rad(-10), 0, rad(-12)))
	pose:set(HIP.Left, euler(0, rad(4), rad(-7)))
	pose:set(KNEE.Left, euler(rad(-14), 0, 0))
	pose:set(ANKLE.Left, euler(rad(-58), rad(18), 0))
	pose:set(HIP.Right, euler(rad(-2), rad(-3), rad(5)))
	pose:set(KNEE.Right, euler(rad(-4), 0, 0))
	pose:set(ANKLE.Right, euler(rad(-64), rad(-10), 0))
	-- The torso lies on the floor.
	restOnFloor(pose, m, { "LowerTorso", "UpperTorso" }, m.ground, FLOOR_CLEARANCE)
end

--------------------------------------------------------------------------------
-- Water
--------------------------------------------------------------------------------

local function treading(ctx: Ctx, pose: Pose)
	local phase = ctx.phase
	local bob = 0.07 * math.sin(2 * TAU * phase)
	pose:set(ROOT, CFrame.new(0, -1.1 + bob, 0) * euler(rad(-8) + ctx.leanPitch * 0.5, 0, ctx.leanRoll * 0.5))
	pose:set(WAIST, euler(rad(-6) + ctx.breath * rad(1.5), 0, 0))
	for _, side in SIDES do
		local s = SIGN[side]
		local legAngle = TAU * (phase - PLANT[side])
		-- Eggbeater: each leg circles out and round.
		pose:set(
			HIP[side],
			euler(rad(42) + rad(18) * math.sin(legAngle), s * rad(8), s * (rad(16) + rad(8) * math.cos(legAngle)))
		)
		pose:set(KNEE[side], euler(-(rad(72) + rad(28) * math.cos(legAngle)), 0, 0))
		pose:set(ANKLE[side], euler(rad(12) * math.sin(legAngle), 0, 0))
		-- Sculling: forearms sweeping in and out at chest height.
		local scull = math.sin(TAU * 2 * phase + (if s > 0 then 0 else math.pi))
		pose:set(SHOULDER[side], euler(rad(30), s * rad(22) * scull, s * rad(48)))
		pose:set(ELBOW[side], euler(rad(55) + rad(10) * scull, 0, 0))
		pose:set(WRIST[side], euler(0, 0, -s * rad(20) * scull))
	end
end

local function freestyle(ctx: Ctx, pose: Pose)
	local phase = ctx.phase
	local m = measure(ctx.map)
	-- Body roll toward the pulling arm, twice a cycle.
	local roll = rad(32) * math.sin(TAU * phase)
	pose:set(ROOT, CFrame.Angles(0, 0, roll) * CFrame.Angles(-math.pi / 2 + rad(6), 0, 0))
	pose:set(WAIST, euler(rad(6) + ctx.breath * rad(1), 0, 0))
	pose:set(NECK, euler(rad(28), -roll * 0.6, 0))
	local neck = pose:pivot(NECK)
	shiftBody(pose, Vector3.new(0, -0.35 - neck.Y + m.spine * 0.15, -0.55 - neck.Z))
	for _, side in SIDES do
		local s = SIGN[side]
		local u = (phase - PLANT[side]) % 1
		-- Pull: reach -> under the body -> hip; recovery: elbow high over the water.
		local angle: number
		local elbow: number
		local out: number
		if u < 0.55 then
			local v = u / 0.55
			angle = math.pi * (1 - v)
			elbow = rad(30) * math.sin(math.pi * v)
			out = rad(6)
		else
			local v = (u - 0.55) / 0.45
			angle = -math.pi * v
			elbow = rad(105) * math.sin(math.pi * v)
			out = rad(28) * math.sin(math.pi * v)
		end
		pose:set(SHOULDER[side], euler(angle, 0, s * out))
		pose:set(ELBOW[side], euler(elbow, 0, 0))
		pose:set(WRIST[side], euler(rad(-8), 0, 0))
		-- Flutter kick, three beats per arm.
		local kick = math.sin(TAU * 3 * phase + (if s > 0 then math.pi else 0))
		pose:set(HIP[side], euler(rad(10) * kick, 0, s * rad(3)))
		pose:set(KNEE[side], euler(-(rad(12) + rad(10) * math.max(0, kick)), 0, 0))
		pose:set(ANKLE[side], euler(-rad(55), 0, 0))
	end
end

local function underwater(ctx: Ctx, pose: Pose)
	local phase = ctx.phase
	local m = measure(ctx.map)
	-- 0..0.35 draw (arms sweep in, legs draw up), 0.35..0.55 kick (legs whip together), 0.55..1 glide.
	local draw = smoothstep(0, 0.35, phase) * (1 - smoothstep(0.35, 0.55, phase))
	local sweep = math.sin(math.pi * math.clamp(phase / 0.4, 0, 1))
	pose:set(ROOT, euler(-math.pi / 2 + rad(10) + rad(4) * draw, 0, 0))
	pose:set(WAIST, euler(rad(8) * draw, 0, 0))
	pose:set(NECK, euler(rad(24), 0, 0))
	local neck = pose:pivot(NECK)
	shiftBody(pose, Vector3.new(0, -0.95 - neck.Y + m.spine * 0.1, -0.5 - neck.Z))
	for _, side in SIDES do
		local s = SIGN[side]
		-- Arms: streamlined overhead; the pull sweeps them out and down to the chest.
		pose:set(
			SHOULDER[side],
			euler(math.pi * 0.94 - rad(70) * sweep, s * rad(8) * sweep, s * (rad(6) + rad(40) * sweep))
		)
		pose:set(ELBOW[side], euler(rad(80) * sweep * (1 - smoothstep(0.3, 0.45, phase)), 0, 0))
		pose:set(WRIST[side], euler(0, 0, -s * rad(15) * sweep))
		-- Frog kick: knees out and drawn up, then snapped back together.
		pose:set(HIP[side], euler(rad(50) * draw, s * rad(10) * draw, s * (rad(4) + rad(32) * draw)))
		pose:set(KNEE[side], euler(-(rad(8) + rad(105) * draw), 0, 0))
		pose:set(ANKLE[side], euler(rad(20) * draw - rad(50) * (1 - draw), -s * rad(25) * draw, 0))
	end
end

--------------------------------------------------------------------------------
-- Locked states
--------------------------------------------------------------------------------

-- Right foot held in a trap ahead; kneeling on the left knee; both hands tugging at the jaws.
local function trapped(ctx: Ctx, pose: Pose)
	local m = measure(ctx.map)
	local t = ctx.time
	local tug = math.max(0, math.sin(TAU * 1.1 * t)) ^ 2 + 0.25 * noise(t * 2.3, ctx.seed * 11)
	local hipHeight = m.ground + m.kneePad + m.thigh * 0.96
	pose:set(ROOT, euler(rad(-12) + rad(3) * tug, rad(-8), rad(3)))
	pose:set(WAIST, euler(rad(-30) + rad(5) * tug + ctx.breath * rad(1.5), rad(-10), rad(-4)))
	local hipNow = pose:pivot(HIP.Left)
	shiftBody(pose, Vector3.new(0, hipHeight - hipNow.Y, 0))

	-- Caught leg: foot flat in the trap, knee up.
	local trapAnkle = anklePoint(m, ctx, "Right", m.hip.Right.X * 1.05, -m.leg * 0.32, 0, 0)
	pose:limb(LEG.Right, trapAnkle + Vector3.new(0, 0.04 * tug, 0), kneePole("Right", rad(-6)), euler(0, rad(-6), 0))
	-- Kneeling leg: knee down behind, shin along the floor, toes tucked.
	local leftHip = pose:pivot(HIP.Left)
	local knee = Vector3.new(leftHip.X - 0.05, m.ground + m.kneePad, leftHip.Z + 0.3)
	pose:aim(HIP.Left, knee - leftHip)
	pose:aim(KNEE.Left, Vector3.new(0, -0.08, 1))
	pose:aim(ANKLE.Left, Vector3.new(0, -0.8, 0.6))

	-- Hands on the jaws around the caught ankle, pulling with each tug.
	local lift = Vector3.new(0, 0.18 * tug, 0)
	local right = trapAnkle + Vector3.new(0.38, 0.25, -0.2) + lift
	local left = trapAnkle + Vector3.new(-0.42, 0.3, -0.25) + lift
	pose:limb(ARM.Right, right, Vector3.new(0.8, -0.3, 0.6), palmDown("Right", rad(70)))
	pose:limb(ARM.Left, left, Vector3.new(-0.8, -0.3, 0.6), palmDown("Left", rad(-70)))
	pose:plant("Right", true)
	pose:plant("Left", true)
end

-- Seized and dragged: arms and legs thrash, the body twists against the grip.
local function grabbed(ctx: Ctx, pose: Pose)
	local t = ctx.time
	local seed = ctx.seed * 17
	local function thrash(rate: number, offset: number): number
		return noise(t * rate, seed + offset)
	end
	pose:set(
		ROOT,
		CFrame.new(0, -0.3, 0)
			* euler(rad(18) + rad(8) * thrash(1.3, 1), rad(14) * thrash(1.1, 2), rad(10) * thrash(1.7, 3))
	)
	pose:set(WAIST, euler(rad(14) + rad(10) * thrash(2.1, 4), rad(18) * thrash(1.6, 5), rad(8) * thrash(2.4, 6)))
	pose:set(NECK, euler(rad(10) + rad(20) * thrash(2.6, 7), rad(30) * thrash(2.2, 8), rad(12) * thrash(3, 9)))
	for _, side in SIDES do
		local s = SIGN[side]
		local k = if s > 0 then 20 else 40
		pose:set(
			SHOULDER[side],
			euler(
				rad(70) + rad(80) * thrash(3.1, k),
				s * rad(25) * thrash(2.7, k + 1),
				s * (rad(50) + rad(35) * thrash(3.4, k + 2))
			)
		)
		pose:set(ELBOW[side], euler(rad(50) + rad(40) * thrash(3.8, k + 3), 0, 0))
		pose:set(WRIST[side], euler(rad(25) * thrash(4.2, k + 4), 0, rad(25) * thrash(4, k + 5)))
		pose:set(
			HIP[side],
			euler(
				rad(25) + rad(40) * thrash(3.3, k + 6),
				s * rad(10) * thrash(2.5, k + 7),
				s * (rad(12) + rad(12) * thrash(2.9, k + 8))
			)
		)
		pose:set(KNEE[side], euler(-(rad(45) + rad(38) * thrash(3.6, k + 9)), 0, 0))
		pose:set(ANKLE[side], euler(rad(25) * thrash(4.4, k + 10), 0, 0))
	end
end

-- Hanging in the harness: legs dangling and swaying, hands up on the risers.
local function parachuting(ctx: Ctx, pose: Pose)
	local m = measure(ctx.map)
	local t = ctx.time
	local sway = math.sin(TAU * 0.32 * t)
	pose:set(ROOT, euler(rad(4) * sway, rad(3) * math.sin(TAU * 0.21 * t), rad(4) * math.sin(TAU * 0.27 * t)))
	pose:set(WAIST, euler(rad(4) + ctx.breath * rad(1.2), 0, 0))
	local chest = pose:frame("UpperTorso").Rotation
	for _, side in SIDES do
		local s = SIGN[side]
		local dangle = math.sin(TAU * 0.32 * t + (if s > 0 then 0.9 else 0))
		pose:set(HIP[side], euler(rad(20) + rad(7) * dangle, s * rad(4), s * rad(5)))
		pose:set(KNEE[side], euler(-(rad(24) + rad(9) * dangle), 0, 0))
		pose:set(ANKLE[side], euler(-rad(28), 0, 0))
		local shoulder = pose:pivot(SHOULDER[side])
		local riser = shoulder + chest * Vector3.new(s * 0.15, m.arm * 0.9, 0.15 + 0.05 * sway)
		pose:limb(ARM[side], riser, chest * Vector3.new(s, -0.2, 0.7), chest * CFrame.Angles(math.pi, 0, 0))
	end
end

--------------------------------------------------------------------------------
-- Profile
--------------------------------------------------------------------------------

-- The grip frame in the hand part's space (fingers -Y, thumb -Z): a handle held like a racket, leaving the fist
-- past the thumb about 25 degrees off the line of the forearm (the wrist's ulnar set), thumb side up. With the
-- item pointing forward the forearm angles down into it from a low elbow: the natural flashlight hold.
local GRIP_FORWARD = Vector3.new(0, -0.906, -0.423).Unit
local GRIP_UP = Vector3.new(0, 0.423, -0.906).Unit
local GRIP = CFrame.fromMatrix(Vector3.new(0, -0.05, 0), GRIP_UP:Cross(-GRIP_FORWARD), GRIP_UP, -GRIP_FORWARD)

local function state(spec: StateSpec): StateSpec
	return spec
end

local states: { [string]: StateSpec } = {
	Standing = state({
		pose = standing,
		cycle = cycleFor(WALK, 1.3),
		footsteps = { plants = PLANT, volume = 1, sprint = false },
		plantFeet = true,
		exertion = 0.15,
	}),
	Sprinting = state({
		pose = sprinting,
		cycle = cycleFor(SPRINT, 1.3),
		footsteps = { plants = PLANT, volume = 1, sprint = true },
		blendSpeed = 9,
		plantFeet = true,
		exertion = 1,
	}),
	Crouching = state({
		pose = crouching,
		cycle = cycleFor(CROUCH, 1.1),
		footsteps = { plants = PLANT, volume = 0.45, sprint = false },
		blendSpeed = 8,
		plantFeet = true,
		exertion = 0.2,
	}),
	VentCrawling = state({
		pose = ventCrawling,
		cycle = crawlCycle(VENT_SLOW),
		blendSpeed = 6,
		hands = 0,
		look = { waist = 0, head = 0.55 },
		exertion = 0.25,
	}),
	VentScurrying = state({
		pose = ventScurrying,
		cycle = crawlCycle(VENT_FAST),
		blendSpeed = 7,
		hands = 0,
		look = { waist = 0, head = 0.55 },
		exertion = 0.9,
	}),
	DownedCrawling = state({
		pose = downed,
		cycle = {
			length = function(_speed: number, map: JointMap): number
				return measure(map).arm * 0.62 / DOWNED_DUTY
			end,
			turnStep = 0.6,
		},
		blendSpeed = 5,
		hands = 0,
		look = { waist = 0.4, head = 0.9 },
		exertion = 0.7,
	}),
	Treading = state({
		pose = treading,
		cycle = {
			length = function(_speed: number, _map: JointMap): number
				return 7
			end,
			rate = 0.8,
		},
		blendSpeed = 5,
		hands = 0.5,
		look = { waist = 0.6, head = 1 },
		exertion = 0.35,
	}),
	Freestyle = state({
		pose = freestyle,
		cycle = {
			length = function(_speed: number, _map: JointMap): number
				return 7
			end,
			rate = 0.25,
		},
		blendSpeed = 5,
		hands = 0,
		look = { waist = 0, head = 0.45 },
		exertion = 1,
	}),
	Underwater = state({
		pose = underwater,
		cycle = {
			length = function(_speed: number, _map: JointMap): number
				return 9
			end,
			rate = 0.3,
		},
		blendSpeed = 4,
		hands = 0,
		look = { waist = 0, head = 0.5 },
		exertion = 0.6,
	}),
	Hiding = state({
		pose = hiding,
		blendSpeed = 6,
		plantFeet = true,
		look = { waist = 0.5, head = 1 },
	}),
	Trapped = state({
		pose = trapped,
		blendSpeed = 9,
		look = { waist = 0.3, head = 0.8 },
		exertion = 0.8,
	}),
	Grabbed = state({
		pose = grabbed,
		blendSpeed = 10,
		hands = 0,
		look = { waist = 0, head = 0.35 },
		exertion = 1,
	}),
	Parachuting = state({
		pose = parachuting,
		blendSpeed = 4,
		look = { waist = 0.5, head = 1 },
	}),
	Scripted = state({
		pose = scripted,
		cycle = cycleFor(NEUTRAL, 1.3),
		footsteps = { plants = PLANT, volume = 0.8, sprint = false },
		plantFeet = true,
	}),
	Dead = state({
		pose = dead,
		blendSpeed = 5,
		hands = 0,
		look = { waist = 0, head = 0 },
		settle = true,
	}),
}

local profile: Profile = {
	name = "PlayerR15",
	rootPart = "HumanoidRootPart",
	required = REQUIRED,
	limbs = {
		LeftArm = { upper = "LeftShoulder", lower = "LeftElbow", tip = "LeftWrist", bend = Vector3.new(0, 0, 1) },
		RightArm = { upper = "RightShoulder", lower = "RightElbow", tip = "RightWrist", bend = Vector3.new(0, 0, 1) },
		LeftLeg = { upper = "LeftHip", lower = "LeftKnee", tip = "LeftAnkle", bend = Vector3.new(0, 0, -1) },
		RightLeg = { upper = "RightHip", lower = "RightKnee", tip = "RightAnkle", bend = Vector3.new(0, 0, -1) },
	},
	hands = {
		Left = {
			limb = "LeftArm",
			grip = GRIP,
			pole = Vector3.new(-0.75, -1, 0.5).Unit,
			curl = CFrame.Angles(0, 0, rad(14)),
			wristLimit = rad(70),
		},
		Right = {
			limb = "RightArm",
			grip = GRIP,
			pole = Vector3.new(0.75, -1, 0.5).Unit,
			curl = CFrame.Angles(0, 0, -rad(14)),
			wristLimit = rad(70),
		},
	},
	feet = {
		Left = { part = "LeftFoot", limb = "LeftLeg" },
		Right = { part = "RightFoot", limb = "RightLeg" },
	},
	look = {
		waist = WAIST,
		neck = NECK,
		waistPitch = 0.28,
		waistYaw = 0.35,
		pitchUp = rad(55),
		pitchDown = rad(62),
		yaw = rad(75),
		roll = rad(20),
	},
	states = states,
	defaultState = "Standing",
	blendSpeed = 11,
	lateralStride = 0.75,
}

local PlayerR15 = {}

PlayerR15.Profile = profile
PlayerR15.Grip = GRIP
PlayerR15.VentFloor = VENT_FLOOR
PlayerR15.FloorClearance = FLOOR_CLEARANCE
-- The state Dead rigs are posed in (not a MoveState: CharacterAnimationController picks it from LifeState).
PlayerR15.DeadState = "Dead"

-- Stride numbers the on-foot states use at `speed` (specs and tuning).
function PlayerR15.gait(stateName: string, speed: number, map: JointMap): (number, number, number)
	local style = if stateName == "Sprinting"
		then SPRINT
		elseif stateName == "Crouching" then CROUCH
		elseif stateName == "Scripted" then NEUTRAL
		else WALK
	local gait = gaitAt(style, speed, measure(map))
	return gait.duty, gait.stance, gait.centre
end

-- Rig measurements the profile works from (specs and tuning).
function PlayerR15.measure(map: JointMap): { [string]: number }
	local m = measure(map)
	return {
		leg = m.leg,
		thigh = m.thigh,
		shin = m.shin,
		upperArm = m.upperArm,
		forearm = m.forearm,
		ankle = m.ankle,
		toe = m.toe,
		heel = m.heel,
		standHip = m.standHip,
		ground = m.ground,
	}
end

return table.freeze(PlayerR15)
