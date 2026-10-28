--!strict
-- ProceduralAnimator: poses every registered rig in code. One PreSimulation driver steps them all; each Animator
-- writes Motor6D.Transform (AnimationConstraint.Transform) and nothing else. No Animator instance, no assets.
--
-- A rig is a JointMap (joint tree discovered by name) plus a Profile: data and pose functions written in rig axes
-- (X right, Y up, -Z forward, relative to the root part). The player's R15 profile lives in Profiles/PlayerR15; the
-- Creature (P4) adds its own profile over the same machinery.
--
-- Each step, per rig:
--   1. Inputs: { moveState, velocity (world), grounded, lookYaw / lookPitch (world look, radians), time? }, pushed
--      with SetInputs or pulled by an input provider right before the step (only rigs that are due get read).
--   2. Motion: the root-space velocity is smoothed into speed / heading; acceleration and turning feed lean springs;
--      the lower body yaws toward the travel direction (backpedalling and strafing included); airborne time,
--      landing compression, exertion and a breathing cycle are tracked.
--   3. Phase: one cycle phase shared by every state, advanced by distance travelled divided by the blended cycle
--      length of the active states (studs per cycle, plus time-driven rates for strokes and turning on the spot), so
--      gaits stay phase-continuous through speed and state changes and planted feet never slide. Foot plants
--      crossed this step become Footstep events (dominant state's spec).
--   4. Base pose: every state with weight > 0 evaluates its pose function into a PoseBuilder (joint entries in rig
--      axes, with FK queries and two-bone IK for its limbs). State weights are critically damped springs, so states
--      cross-fade smoothly; the poses blend by normalized CFrame slerp.
--   5. Additive look: the waist takes a share of the look pitch / yaw; the neck aims the head along the look
--      (gaze stabilisation, clamped to neck limits), blended per state.
--   6. Overrides: hand targets (world CFrames, via SetHandTarget) solve the arm chains with two-bone IK and blend
--      in / out with springs; grip curls the wrist. Optional ground probes plant the feet on uneven floors.
--   7. Write: Transform = axes^-1 * entry * axes per joint (JointMap.toTransform).
--
-- LOD (SetLod(near, far), from RenderBudgetController): rigs within `near` of the focus (the camera) step every
-- frame, rigs up to `far` every third frame (staggered, with the accumulated dt), rigs beyond `far` are frozen.
-- Priority rigs (the local character) always step at full rate.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Spring = require(ReplicatedStorage.Shared.Util.Spring)

local IK = require(script.IK)
local JointMap = require(script.JointMap)

local log = Log.new("ProceduralAnimator")

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

export type JointMap = JointMap.JointMap
export type Solution = IK.Solution

-- Joint name -> entry: rotation (and optional translation) of the joint in rig axes, relative to its parent part.
export type Pose = { [string]: CFrame }

export type LimbSpec = {
	upper: string, -- joint at the limb's root (hip / shoulder)
	lower: string, -- middle joint (knee / elbow)
	tip: string, -- end joint (ankle / wrist); IK targets its pivot
	bend: Vector3, -- rig-space direction the middle joint protrudes when the limb bends at rest (knee: forward)
}

export type HandSpec = {
	limb: string, -- key into Profile.limbs
	grip: CFrame, -- the grip frame in the tip part's own space: SetHandTarget places this frame
	pole: Vector3, -- direction the middle joint points under IK, in the limb parent's rig axes
	curl: CFrame, -- extra tip-joint rotation at full grip (SetHandGrip 1), in the tip's own axes
	wristLimit: number, -- radians the tip may turn away from the lower bone under IK
}

export type FootSpec = {
	part: string, -- foot part (footstep position, ground probes)
	limb: string, -- key into Profile.limbs
}

export type ProfileLook = {
	waist: string?, -- joint that takes a share of the look (upper body)
	neck: string?, -- joint that aims the head along the look
	waistPitch: number, -- share of the look pitch taken by the waist (0..1)
	waistYaw: number, -- share of the look yaw taken by the waist
	pitchUp: number, -- neck limits, radians relative to the neck's parent part
	pitchDown: number,
	yaw: number,
	roll: number,
}

export type CycleSpec = {
	-- Studs travelled per cycle at `speed` (studs/s). `map` lets the profile scale by the rig's own proportions.
	length: (speed: number, map: JointMap) -> number,
	rate: number?, -- cycles per second regardless of travel (strokes, treading)
	turnStep: number?, -- studs of virtual travel per radian turned on the spot (stepping round)
}

export type FootstepSpec = {
	plants: { [string]: number }, -- foot -> cycle phase of its contact
	volume: number, -- loudness relative to a normal step
	sprint: boolean, -- use the sprint footstep presets
}

export type StateLook = {
	waist: number?, -- multiplier on the profile's waist shares (default 1)
	head: number?, -- gaze stabilisation 0..1 (default 1)
}

export type MotionContext = {
	map: JointMap,
	state: string, -- the state being posed
	weight: number, -- its current blend weight
	phase: number, -- shared cycle phase, 0..1
	cycleLength: number, -- studs per cycle actually in use (blended, lateral-scaled)
	time: number, -- seconds
	dt: number,
	speed: number, -- smoothed horizontal speed, studs/s
	moveAmount: number, -- 0 standing still .. 1 moving
	heading: Vector3, -- unit travel direction in root space (XZ); the last one while still
	hipYaw: number, -- lower-body yaw toward the travel direction (radians, + = left)
	travel: Vector3, -- unit travel direction in the hip-yawed frame (XZ)
	velocity: Vector3, -- smoothed root-space velocity (horizontal)
	verticalSpeed: number,
	leanPitch: number, -- radians, CFrame.Angles X convention (negative leans forward)
	leanRoll: number, -- radians, + leans left
	turnRate: number, -- smoothed yaw rate, rad/s (+ = turning left)
	turnAmount: number, -- 0..1
	airborne: number, -- 0 grounded .. 1 in the air (smoothed)
	landing: number, -- landing compression, studs
	exertion: number, -- 0 rested .. 1 winded
	breath: number, -- breathing cycle, -1..1 (faster when winded)
	lookYaw: number, -- look relative to the root, radians
	lookPitch: number,
	seed: number, -- per-rig variation, 0..1
	ground: { [string]: number }, -- per foot: probed floor offset from the flat floor (studs)
	twist: { [string]: number }, -- per foot: planted-turn yaw (radians)
}

export type PoseBuilder = {
	entries: Pose,
	planted: { [string]: boolean },
	set: (self: PoseBuilder, joint: string, entry: CFrame) -> (),
	get: (self: PoseBuilder, joint: string) -> CFrame,
	frame: (self: PoseBuilder, part: string) -> CFrame, -- rig-space CFrame of a part under the entries so far
	pivot: (self: PoseBuilder, joint: string) -> Vector3, -- rig-space pivot of a joint under the entries so far
	delta: (self: PoseBuilder, part: string) -> CFrame, -- a part's rotation relative to its rest (rig space)
	-- Two-bone IK: places the limb's tip pivot at `target` (rig space) with the middle joint toward `pole`; `tip` is
	-- the tip part's wanted rotation relative to its rest (rig space), nil to keep it in line with the lower bone.
	limb: (self: PoseBuilder, limb: string, target: Vector3, pole: Vector3, tip: CFrame?) -> Solution,
	-- Turns a joint's bone (pivot toward its child pivots) to lie along `direction` (rig space). With `hint` the
	-- bone's rest front (-Z) turns toward it; without, the smallest rotation is used.
	aim: (self: PoseBuilder, joint: string, direction: Vector3, hint: Vector3?) -> (),
	plant: (self: PoseBuilder, foot: string, planted: boolean) -> (), -- reports a foot on the floor (turn twist)
	reset: (self: PoseBuilder) -> (), -- clears every entry (the animator does this before each pose call)
}

export type PoseFn = (ctx: MotionContext, pose: PoseBuilder) -> ()

export type StateSpec = {
	pose: PoseFn,
	cycle: CycleSpec?,
	footsteps: FootstepSpec?,
	blendSpeed: number?, -- weight spring speed when entering this state (default Profile.blendSpeed)
	look: StateLook?,
	exertion: number?, -- winded target while in this state, 0..1
	plantFeet: boolean?, -- feet stand on the floor (ground probes)
	settle: boolean?, -- a still pose: the rig stops stepping once fully blended in
	hands: number?, -- how much SetHandTarget may take over the arms here, 0..1 (default 1; 0 when crawling)
}

export type Profile = {
	name: string,
	rootPart: string?,
	required: { string },
	limbs: { [string]: LimbSpec },
	hands: { [string]: HandSpec },
	feet: { [string]: FootSpec },
	look: ProfileLook,
	states: { [string]: StateSpec },
	defaultState: string,
	blendSpeed: number,
	lateralStride: number?, -- cycle-length factor when moving sideways in the hip frame (default 0.75)
}

export type Inputs = {
	moveState: string,
	velocity: Vector3,
	grounded: boolean,
	lookYaw: number,
	lookPitch: number,
	time: number?,
}

export type InputPatch = {
	moveState: string?,
	velocity: Vector3?,
	grounded: boolean?,
	lookYaw: number?, -- world yaw, MathUtil convention (0 looks down -Z, + turns left)
	lookPitch: number?, -- + looks up
	time: number?, -- external clock (seconds); defaults to the animator's own
}

export type FootstepEvent = {
	foot: string,
	position: Vector3, -- world position of the foot part
	state: string,
	sprint: boolean,
	volume: number,
}

-- Raycast-like probe: the world point hit along `direction` from `origin`, or nil.
export type GroundProbe = (origin: Vector3, direction: Vector3) -> Vector3?

export type Animator = {
	Rig: Model,
	Map: JointMap,
	Profile: Profile,
	Footstep: Signal.Signal<FootstepEvent>,
	SetInputs: (self: Animator, inputs: InputPatch) -> (),
	SetHandTarget: (self: Animator, hand: string, target: CFrame?) -> (),
	SetHandGrip: (self: Animator, hand: string, grip: number) -> (),
	SetGroundProbe: (self: Animator, probe: GroundProbe?) -> (),
	SetInputProvider: (self: Animator, provider: ((animator: Animator, dt: number) -> ())?) -> (),
	SetPriority: (self: Animator, priority: boolean) -> (),
	Step: (self: Animator, dt: number) -> (),
	GetState: (self: Animator) -> string,
	GetPhase: (self: Animator) -> number,
	GetPartFrame: (self: Animator, part: string) -> CFrame?,
	IsDestroyed: (self: Animator) -> boolean,
	Destroy: (self: Animator) -> (),
}

export type Options = {
	seed: number?, -- per-rig variation (any number)
	priority: boolean?, -- always step at full rate (the local character)
}

export type LodTier = "Full" | "Reduced" | "Frozen"

export type StepParams = {
	duty: number, -- stance share of the cycle, 0..1
	lift: number, -- swing clearance (studs)
	liftPeak: number?, -- point of the swing (0..1) where the foot is highest (default 0.45)
	strike: number?, -- foot pitch at contact (radians, + = toe up)
	toeOff: number?, -- foot pitch at lift-off (radians, - = toe down)
}

export type FootCycle = {
	along: number, -- offset along the travel direction (studs, + = ahead)
	lift: number, -- height above the floor (studs)
	pitch: number, -- foot pitch (radians, + = toe up)
	stance: boolean, -- on the floor
	progress: number, -- 0..1 through the stance (stance) or the swing (swing)
}

--------------------------------------------------------------------------------
-- Tuning
--------------------------------------------------------------------------------

local MAX_DT = 0.1
local DEFAULT_NEAR = 60
local DEFAULT_FAR = 180
local REDUCED_EVERY = 3
local VELOCITY_DAMP = 10
local LOOK_DAMP = 20
local HAND_BLEND_SPEED = 14
local GRIP_DAMP = 12
local MOVE_START = 0.35
local MOVE_FULL = 2.2
local HEADING_MIN_SPEED = 0.25
local TURN_FULL = 3.5 -- rad/s at turnAmount 1
local TURN_DAMP = 10
local TELEPORT_YAW = 1.2 -- a yaw jump above this in one step is a teleport / respawn, not a turn
local TURN_STEP_LIMIT = 2 -- above this speed turning adds no stepping
local TWIST_LIMIT = math.rad(40)
local TWIST_RELEASE = 9
local LEAN_SPEED = 7
local LEAN_DAMPING = 0.7
local ACCEL_LEAN = 0.012 -- radians per stud/s^2
local MAX_ACCEL = 60
local MAX_ACCEL_LEAN = math.rad(11)
local TURN_LEAN = 0.016 -- radians per (stud/s * rad/s)
local MAX_TURN_LEAN = math.rad(9)
local HIP_YAW_SHARE = 0.6
local HIP_YAW_MAX = math.rad(45)
local HIP_YAW_SPEED = 8
local BACKWARD_ENTER = math.rad(105)
local BACKWARD_EXIT = math.rad(75)
local LATERAL_STRIDE = 0.75
local AIR_RISE = 9
local AIR_FALL = 14
local LANDING_SPEED = 13
local LANDING_DAMPING = 0.55
local LANDING_IMPULSE = 0.045 -- studs/s of dip velocity per stud/s of fall speed
local MAX_FALL_SPEED = 70
local EXERTION_RISE = 0.12
local EXERTION_FALL = 0.05
local BREATH_RESTED = 0.24 -- breaths per second
local BREATH_WINDED = 0.75
local PROBE_HEIGHT = 2.2
local PROBE_DEPTH = 4.5
local GROUND_LIMIT = 1.2
local GROUND_DAMP = 18
local MIN_CYCLE = 0.25
local POLE_TIEBREAK = 0.35 -- weight of the profile pole against the aligned-forearm pole for hand targets
local SETTLED_WEIGHT = 0.999
local STEP_MOVE = 0.25
local STEP_TURN = 0.35
local WEIGHT_EPSILON = 0.002

local ProceduralAnimator = {}

ProceduralAnimator.IK = IK
ProceduralAnimator.JointMap = JointMap
ProceduralAnimator.ReducedEvery = REDUCED_EVERY
ProceduralAnimator.DefaultNear = DEFAULT_NEAR
ProceduralAnimator.DefaultFar = DEFAULT_FAR

--------------------------------------------------------------------------------
-- Pure helpers (specced; profiles use them too)
--------------------------------------------------------------------------------

-- CFrame.fromEulerAnglesYXZ(pitch, yaw, roll): yaw about Y, then pitch about X, then roll about Z.
function ProceduralAnimator.euler(pitch: number, yaw: number, roll: number): CFrame
	return CFrame.fromEulerAnglesYXZ(pitch, yaw, roll)
end

-- sin(2*pi*(phase + offset)).
function ProceduralAnimator.wave(phase: number, offset: number?): number
	return math.sin(2 * math.pi * (phase + (offset or 0)))
end

-- True when a phase running from `from` to `to` (unwrapped, to >= from) passes `mark` (mod 1).
function ProceduralAnimator.crossed(from: number, to: number, mark: number): boolean
	if to <= from then
		return false
	end
	return math.floor(to - mark) > math.floor(from - mark)
end

-- Which LOD tier a rig `distance` studs from the focus falls in.
function ProceduralAnimator.lodTier(distance: number, near: number, far: number): LodTier
	if distance <= near then
		return "Full"
	elseif distance <= far then
		return "Reduced"
	end
	return "Frozen"
end

-- One foot through a gait cycle. `footPhase` is 0 at contact; the foot is on the floor for the first `duty` of the
-- cycle and slides back by exactly `stance` studs (the body's travel during the stance, so it stays planted), then
-- swings forward by the same distance with a cycloid ease while lifting `lift` studs.
function ProceduralAnimator.footCycle(footPhase: number, stance: number, params: StepParams): FootCycle
	local duty = math.clamp(params.duty, 0.05, 0.95)
	local p = footPhase % 1
	local strike = params.strike or 0
	local toeOff = params.toeOff or 0
	if p < duty then
		local u = p / duty
		-- Heel strike -> flat by 15% -> flat -> heel rises over the last 40% to the toe-off angle.
		local pitch: number
		if u < 0.15 then
			pitch = strike * (1 - MathUtil.smoothstep(0, 0.15, u))
		elseif u > 0.6 then
			pitch = toeOff * MathUtil.smoothstep(0.6, 1, u)
		else
			pitch = 0
		end
		return { along = stance * (0.5 - u), lift = 0, pitch = pitch, stance = true, progress = u }
	end
	local v = (p - duty) / (1 - duty)
	local eased = v - math.sin(2 * math.pi * v) / (2 * math.pi)
	-- Lift: eases up to the peak and back down (zero vertical speed at lift-off, the peak and contact).
	local peak = math.clamp(params.liftPeak or 0.45, 0.1, 0.9)
	local height = if v < peak
		then params.lift * (1 - math.cos(math.pi * v / peak)) / 2
		else params.lift * (1 + math.cos(math.pi * (v - peak) / (1 - peak))) / 2
	local pitch = MathUtil.lerp(toeOff, strike, MathUtil.smoothstep(0.2, 0.95, v))
	return { along = stance * (eased - 0.5), lift = height, pitch = pitch, stance = false, progress = v }
end

-- How far an ankle rises when its foot pitches by `pitch` while pivoting on the heel (pitch > 0) or the toe
-- (pitch < 0): `ankle` = ankle height above the sole, `heel` / `toe` = sole extent behind / ahead of the ankle.
function ProceduralAnimator.ankleLift(pitch: number, ankle: number, heel: number, toe: number): number
	if pitch >= 0 then
		return ankle * math.cos(pitch) + heel * math.sin(pitch) - ankle
	end
	return ankle * math.cos(pitch) + toe * math.sin(-pitch) - ankle
end

-- Normalized weighted blend of poses (slerp per joint; a joint missing from a pose is identity there).
function ProceduralAnimator.blend(poses: { Pose }, weights: { number }, out: Pose?): Pose
	local result: Pose = out or {}
	table.clear(result)
	local accumulated = 0
	for index, pose in poses do
		local weight = weights[index] or 0
		if weight <= 0 then
			continue
		end
		local first = accumulated == 0
		accumulated += weight
		if first then
			for joint, entry in pose do
				result[joint] = entry
			end
			continue
		end
		local alpha = weight / accumulated
		for joint, entry in pose do
			local current = result[joint] or CFrame.identity
			result[joint] = current:Lerp(entry, alpha)
		end
		for joint, current in result do
			local own: CFrame? = pose[joint]
			if own == nil then
				result[joint] = current:Lerp(CFrame.identity, alpha)
			end
		end
	end
	return result
end

-- The yaw (MathUtil convention) of a CFrame's facing.
local function yawOf(cframe: CFrame): number
	local look = cframe.LookVector
	return math.atan2(-look.X, -look.Z)
end

ProceduralAnimator.yawOf = yawOf

--------------------------------------------------------------------------------
-- Pose builder
--------------------------------------------------------------------------------

type LimbData = {
	spec: LimbSpec,
	upper: number,
	lower: number,
	upperRest: Vector3,
	lowerRest: Vector3,
	bend: Vector3,
}

type RigData = {
	map: JointMap,
	limbs: { [string]: LimbData },
	boneRest: { [string]: Vector3 },
	boneHint: { [string]: Vector3 },
}

local FORWARD = Vector3.new(0, 0, -1)
local IDENTITY = CFrame.new()

local function unitOr(v: Vector3, fallback: Vector3): Vector3
	if v.Magnitude > 1e-6 then
		return v.Unit
	end
	return fallback
end

local function buildRigData(map: JointMap, profile: Profile): RigData
	local limbs: { [string]: LimbData } = {}
	for name, spec in profile.limbs do
		local upperPivot = JointMap.pivot(map, spec.upper)
		local lowerPivot = JointMap.pivot(map, spec.lower)
		local tipPivot = JointMap.pivot(map, spec.tip)
		limbs[name] = {
			spec = spec,
			upper = (lowerPivot - upperPivot).Magnitude,
			lower = (tipPivot - lowerPivot).Magnitude,
			upperRest = unitOr(lowerPivot - upperPivot, -Vector3.yAxis),
			lowerRest = unitOr(tipPivot - lowerPivot, -Vector3.yAxis),
			bend = unitOr(spec.bend, FORWARD),
		}
	end
	local boneRest: { [string]: Vector3 } = {}
	local boneHint: { [string]: Vector3 } = {}
	for _, joint in map.order do
		local direction: Vector3
		if #joint.children > 0 then
			local sum = Vector3.zero
			for _, child in joint.children do
				sum += map.joints[child].pivot
			end
			direction = sum / #joint.children - joint.pivot
		else
			direction = map.rest[joint.part1Name].Position - joint.pivot
		end
		boneRest[joint.name] = unitOr(direction, -Vector3.yAxis)
		boneHint[joint.name] = FORWARD
	end
	for _, data in limbs do
		boneHint[data.spec.upper] = data.bend
		boneHint[data.spec.lower] = data.bend
	end
	return { map = map, limbs = limbs, boneRest = boneRest, boneHint = boneHint }
end

local function newBuilder(rig: RigData): PoseBuilder
	local map = rig.map
	local entries: Pose = {}
	local cache: { [string]: CFrame } = {}
	local planted: { [string]: boolean } = {}

	local function frameOf(part: string): CFrame
		if part == map.rootName then
			return CFrame.identity
		end
		local cached = cache[part]
		if cached then
			return cached
		end
		local jointName = map.drivenBy[part]
		assert(jointName, "part " .. part .. " is not jointed to the root")
		local joint = map.joints[jointName]
		local entry = entries[jointName] or CFrame.identity
		local frame = frameOf(joint.part0Name) * joint.c0 * JointMap.toTransform(joint, entry) * joint.c1Inverse
		cache[part] = frame
		return frame
	end

	local function deltaOf(part: string): CFrame
		local inverse = map.restRotationInverse[part]
		assert(inverse, "no part " .. part)
		return frameOf(part).Rotation * inverse
	end

	local function pivotOf(name: string): Vector3
		local joint = map.joints[name]
		assert(joint, "no joint " .. name)
		return (frameOf(joint.part0Name) * joint.c0).Position
	end

	local builder: PoseBuilder = {
		entries = entries,
		planted = planted,
		set = function(_self: PoseBuilder, joint: string, entry: CFrame)
			entries[joint] = entry
			table.clear(cache)
		end,
		get = function(_self: PoseBuilder, joint: string): CFrame
			return entries[joint] or CFrame.identity
		end,
		frame = function(_self: PoseBuilder, part: string): CFrame
			return frameOf(part)
		end,
		pivot = function(_self: PoseBuilder, joint: string): Vector3
			return pivotOf(joint)
		end,
		delta = function(_self: PoseBuilder, part: string): CFrame
			return deltaOf(part)
		end,
		limb = function(_self: PoseBuilder, limb: string, target: Vector3, pole: Vector3, tip: CFrame?): Solution
			local data = rig.limbs[limb]
			assert(data, "no limb " .. limb)
			local spec = data.spec
			local upperJoint = map.joints[spec.upper]
			local origin = pivotOf(spec.upper)
			local solution = IK.solveTwoBone(origin, target, data.upper, data.lower, pole)
			local parentDelta = deltaOf(upperJoint.part0Name)
			local upperDelta = IK.boneRotation(data.upperRest, data.bend, solution.mid - origin, solution.bend)
			local lowerDelta = IK.boneRotation(data.lowerRest, data.bend, solution.tip - solution.mid, solution.bend)
			entries[spec.upper] = parentDelta:Inverse() * upperDelta
			entries[spec.lower] = upperDelta:Inverse() * lowerDelta
			entries[spec.tip] = if tip then lowerDelta:Inverse() * tip.Rotation else CFrame.identity
			table.clear(cache)
			return solution
		end,
		aim = function(_self: PoseBuilder, joint: string, direction: Vector3, hint: Vector3?)
			local spec = map.joints[joint]
			assert(spec, "no joint " .. joint)
			local rest = rig.boneRest[joint]
			local parentDelta = deltaOf(spec.part0Name)
			local delta = if hint
				then IK.boneRotation(rest, rig.boneHint[joint], direction, hint)
				else IK.aim(rest, direction)
			local previous = entries[joint]
			local offset = if previous then previous.Position else Vector3.zero
			entries[joint] = CFrame.new(offset) * (parentDelta:Inverse() * delta)
			table.clear(cache)
		end,
		plant = function(_self: PoseBuilder, foot: string, isPlanted: boolean)
			planted[foot] = isPlanted
		end,
		reset = function(_self: PoseBuilder)
			table.clear(entries)
			table.clear(planted)
			table.clear(cache)
		end,
	}
	return builder
end

--------------------------------------------------------------------------------
-- Driver
--------------------------------------------------------------------------------

type Registered = {
	animator: Animator,
	step: (dt: number) -> (),
	root: () -> BasePart,
	priority: () -> boolean,
	stagger: number,
	pending: number,
}

local registry: { Registered } = {}
local lodNear = DEFAULT_NEAR
local lodFar = DEFAULT_FAR
local frameCount = 0
local staggerCounter = 0
local driver: RBXScriptConnection? = nil
local focusProvider: (() -> Vector3?)? = nil

local function focusPosition(): Vector3?
	local provider = focusProvider
	if provider then
		return provider()
	end
	local camera = Workspace.CurrentCamera
	if camera then
		return camera.CFrame.Position
	end
	return nil
end

-- Steps every registered rig once (the PreSimulation driver calls this; specs call it directly).
function ProceduralAnimator.Step(dt: number)
	frameCount += 1
	local focus = focusPosition()
	for _, entry in table.clone(registry) do
		local tier: LodTier = "Full"
		if focus and not entry.priority() then
			local root = entry.root()
			tier = ProceduralAnimator.lodTier((root.CFrame.Position - focus).Magnitude, lodNear, lodFar)
		end
		local stepDt = 0
		if tier == "Full" then
			stepDt = math.min(entry.pending + dt, MAX_DT)
			entry.pending = 0
		elseif tier == "Reduced" then
			entry.pending = math.min(entry.pending + dt, MAX_DT)
			if (frameCount + entry.stagger) % REDUCED_EVERY ~= 0 then
				continue
			end
			stepDt = entry.pending
			entry.pending = 0
		else
			entry.pending = 0
			continue
		end
		xpcall(entry.step, function(err: any)
			log.warnThrottled("step:" .. entry.animator.Profile.name, 5, "step failed: %s", tostring(err))
		end, stepDt)
	end
end

local function register(entry: Registered)
	table.insert(registry, entry)
	if driver == nil then
		driver = RunService.PreSimulation:Connect(ProceduralAnimator.Step)
	end
end

local function unregister(animator: Animator)
	for index, entry in registry do
		if entry.animator == animator then
			table.remove(registry, index)
			break
		end
	end
	if #registry == 0 then
		local connection = driver
		driver = nil
		if connection then
			connection:Disconnect()
		end
	end
end

-- LOD distances (studs from the focus): full rate within `near`, every third frame up to `far`, frozen beyond.
function ProceduralAnimator.SetLod(near: number, far: number)
	lodNear = math.max(0, near)
	lodFar = math.max(lodNear, far)
end

function ProceduralAnimator.GetLod(): (number, number)
	return lodNear, lodFar
end

-- Where LOD distances are measured from (default: the current camera). nil restores the default.
function ProceduralAnimator.SetFocus(provider: (() -> Vector3?)?)
	focusProvider = provider
end

-- How many rigs the driver is stepping.
function ProceduralAnimator.Count(): number
	return #registry
end

-- Joints a profile needs that `rig` does not have yet (empty when the rig can be animated).
function ProceduralAnimator.missingJoints(rig: Model, profile: Profile): { string }
	local map = JointMap.build(rig, { root = profile.rootPart })
	if not map then
		return table.clone(profile.required)
	end
	return JointMap.missing(map, profile.required)
end

--------------------------------------------------------------------------------
-- Animator
--------------------------------------------------------------------------------

type StateRuntime = {
	name: string,
	spec: StateSpec,
	weight: Spring.NumberSpring,
	builder: PoseBuilder,
}

type HandRuntime = {
	name: string,
	spec: HandSpec,
	limb: LimbData,
	gripInverse: CFrame,
	lowerInTip: Vector3, -- the lower bone's rest direction in the tip part's own axes
	target: CFrame?,
	held: CFrame?, -- the last target, kept while the IK weight blends out after a release
	weight: Spring.NumberSpring,
	grip: number,
	gripTarget: number,
}

-- Creates an Animator for `rig` and registers it with the driver. Returns nil and a reason when the rig lacks a
-- joint the profile requires.
function ProceduralAnimator.new(rig: Model, profile: Profile, options: Options?): (Animator?, string?)
	local opts: Options = options or {}
	local builtMap, reason = JointMap.build(rig, { root = profile.rootPart, required = profile.required })
	if not builtMap then
		return nil, reason
	end
	local map: JointMap = builtMap
	assert(profile.states[profile.defaultState], "profile default state missing: " .. profile.defaultState)
	local rigData = buildRigData(map, profile)
	local root = map.root
	local seed = ((opts.seed or 0) * 0.6180339887) % 1
	local priority = opts.priority == true

	local footstep: Signal.Signal<FootstepEvent> = Signal.new()
	local inputs: Inputs = {
		moveState = profile.defaultState,
		velocity = Vector3.zero,
		grounded = true,
		lookYaw = yawOf(root.CFrame),
		lookPitch = 0,
		time = nil,
	}
	local states: { [string]: StateRuntime } = {}
	local stateOrder: { StateRuntime } = {}
	local blended: Pose = {}
	local overrides: Pose = {}
	local frames: { [string]: CFrame } = {}
	local deltas: { [string]: CFrame } = {}
	local transforms: { [string]: CFrame } = {}
	local pendingFeet: { string } = {}
	local poses: { Pose } = {}
	local weights: { number } = {}

	local phase = 0
	local cycleLength = 1
	local clock = 0
	local smoothedVelocity = Vector3.zero
	local verticalSpeed = 0
	local heading = FORWARD
	local backward = false
	local hipYaw = Spring.number(0, HIP_YAW_SPEED, 1)
	local leanPitch = Spring.number(0, LEAN_SPEED, LEAN_DAMPING)
	local leanRoll = Spring.number(0, LEAN_SPEED, LEAN_DAMPING)
	local landing = Spring.number(0, LANDING_SPEED, LANDING_DAMPING)
	local turnRate = 0
	local lastYaw: number? = nil
	local airborne = 0
	local airTime = 0
	local fallSpeed = 0
	local exertion = 0
	local breathPhase = seed
	local lookYaw = 0
	local lookPitch = 0
	local twist: { [string]: number } = {}
	local ground: { [string]: number } = {}
	for foot in profile.feet do
		twist[foot] = 0
		ground[foot] = 0
	end
	local probe: GroundProbe? = nil
	local provider: ((animator: Animator, dt: number) -> ())? = nil
	local settledState: string? = nil
	local destroyed = false

	local hands: { [string]: HandRuntime } = {}
	local handsByUpper: { [string]: HandRuntime } = {}
	local handsByTip: { [string]: HandRuntime } = {}
	for name, spec in profile.hands do
		local limb = rigData.limbs[spec.limb]
		assert(limb, "hand " .. name .. " names unknown limb " .. spec.limb)
		local runtime: HandRuntime = {
			name = name,
			spec = spec,
			limb = limb,
			gripInverse = spec.grip:Inverse(),
			lowerInTip = map.restRotationInverse[map.joints[limb.spec.tip].part1Name] * limb.lowerRest,
			target = nil,
			held = nil,
			weight = Spring.number(0, HAND_BLEND_SPEED, 1),
			grip = 0,
			gripTarget = 0,
		}
		hands[name] = runtime
		handsByUpper[limb.spec.upper] = runtime
		handsByTip[limb.spec.tip] = runtime
	end

	local ctx: MotionContext = {
		map = map,
		state = profile.defaultState,
		weight = 1,
		phase = 0,
		cycleLength = 1,
		time = 0,
		dt = 0,
		speed = 0,
		moveAmount = 0,
		heading = FORWARD,
		hipYaw = 0,
		travel = FORWARD,
		velocity = Vector3.zero,
		verticalSpeed = 0,
		leanPitch = 0,
		leanRoll = 0,
		turnRate = 0,
		turnAmount = 0,
		airborne = 0,
		landing = 0,
		exertion = 0,
		breath = 0,
		lookYaw = 0,
		lookPitch = 0,
		seed = seed,
		ground = ground,
		twist = twist,
	}

	local function runtimeFor(name: string): StateRuntime
		local existing = states[name]
		if existing then
			return existing
		end
		local spec = profile.states[name]
		local runtime: StateRuntime = {
			name = name,
			spec = spec,
			weight = Spring.number(if next(states) == nil then 1 else 0, profile.blendSpeed, 1),
			builder = newBuilder(rigData),
		}
		states[name] = runtime
		table.insert(stateOrder, runtime)
		return runtime
	end

	local function targetState(): string
		local name = inputs.moveState
		if profile.states[name] then
			return name
		end
		log.warnThrottled("state:" .. profile.name .. ":" .. name, 30, "%s has no state %s", profile.name, name)
		return profile.defaultState
	end

	runtimeFor(profile.defaultState)

	local function updateWeights(target: string, dt: number): (StateRuntime, number)
		local entering = profile.states[target].blendSpeed or profile.blendSpeed
		runtimeFor(target)
		local total = 0
		for index = #stateOrder, 1, -1 do
			local runtime = stateOrder[index]
			local spring = runtime.weight
			spring.target = if runtime.name == target then 1 else 0
			spring.speed = entering
			spring:step(dt)
			spring.position = math.clamp(spring.position, 0, 1)
			if runtime.name ~= target and spring.position < WEIGHT_EPSILON then
				states[runtime.name] = nil
				table.remove(stateOrder, index)
				continue
			end
			total += spring.position
		end
		if total <= 0 then
			local runtime = states[target]
			runtime.weight:reset(1)
			total = 1
		end
		local dominant = states[target]
		for _, runtime in stateOrder do
			if runtime.weight.position > dominant.weight.position then
				dominant = runtime
			end
		end
		return dominant, total
	end

	local function updateMotion(rootWorld: CFrame, dt: number)
		local localVelocity = rootWorld:VectorToObjectSpace(inputs.velocity)
		if not MathUtil.isFiniteVector(localVelocity) then
			localVelocity = Vector3.zero
		end
		local horizontal = Vector3.new(localVelocity.X, 0, localVelocity.Z)
		local previous = smoothedVelocity
		smoothedVelocity = smoothedVelocity:Lerp(horizontal, MathUtil.damp(VELOCITY_DAMP, dt))
		verticalSpeed = localVelocity.Y
		local speed = smoothedVelocity.Magnitude
		if speed > HEADING_MIN_SPEED then
			heading = smoothedVelocity / speed
		end
		local moveAmount = MathUtil.smoothstep(MOVE_START, MOVE_FULL, speed)

		-- Turning.
		local yaw = yawOf(rootWorld)
		local deltaYaw = if lastYaw then MathUtil.angleDelta(lastYaw, yaw) else 0
		lastYaw = yaw
		if math.abs(deltaYaw) > TELEPORT_YAW then
			deltaYaw = 0
			for foot in twist do
				twist[foot] = 0
			end
		end
		if dt > 0 then
			turnRate = MathUtil.dampNumber(turnRate, deltaYaw / dt, TURN_DAMP, dt)
		end

		-- Lean into acceleration and turns.
		local accel = if dt > 0 then (smoothedVelocity - previous) / dt else Vector3.zero
		if accel.Magnitude > MAX_ACCEL then
			accel = accel.Unit * MAX_ACCEL
		end
		local forwardAccel = -accel.Z
		local pitchTarget = math.clamp(-forwardAccel * ACCEL_LEAN, -MAX_ACCEL_LEAN, MAX_ACCEL_LEAN)
		local rollTarget = math.clamp(-accel.X * ACCEL_LEAN, -MAX_ACCEL_LEAN, MAX_ACCEL_LEAN)
			+ math.clamp(speed * turnRate * TURN_LEAN, -MAX_TURN_LEAN, MAX_TURN_LEAN)
		leanPitch.target = pitchTarget
		leanRoll.target = rollTarget
		leanPitch:step(dt)
		leanRoll:step(dt)

		-- Lower body toward the travel direction (backpedalling past ~105 degrees).
		local angle = math.atan2(-heading.X, -heading.Z)
		if backward and math.abs(angle) < BACKWARD_EXIT then
			backward = false
		elseif not backward and math.abs(angle) > BACKWARD_ENTER then
			backward = true
		end
		local relative = if backward then MathUtil.wrapAngle(angle - math.pi) else angle
		hipYaw.target = math.clamp(relative * HIP_YAW_SHARE, -HIP_YAW_MAX, HIP_YAW_MAX) * moveAmount
		hipYaw:step(dt)
		local travel = CFrame.Angles(0, -hipYaw.position, 0) * heading

		-- Airborne and landing.
		local grounded = inputs.grounded
		if grounded then
			if airTime > 0.15 and fallSpeed > 4 then
				landing:impulse(math.min(fallSpeed, MAX_FALL_SPEED) * LANDING_IMPULSE)
			end
			airTime = 0
			fallSpeed = 0
			airborne = MathUtil.dampNumber(airborne, 0, AIR_FALL, dt)
		else
			airTime += dt
			fallSpeed = math.max(fallSpeed, -verticalSpeed)
			airborne = MathUtil.dampNumber(airborne, 1, AIR_RISE, dt)
		end
		landing:step(dt)

		-- Look relative to the facing.
		local yawTarget = math.clamp(MathUtil.angleDelta(yaw, inputs.lookYaw), -math.rad(110), math.rad(110))
		local pitchInput = math.clamp(inputs.lookPitch, -math.rad(85), math.rad(85))
		lookYaw = MathUtil.dampNumber(lookYaw, yawTarget, LOOK_DAMP, dt)
		lookPitch = MathUtil.dampNumber(lookPitch, pitchInput, LOOK_DAMP, dt)

		ctx.speed = speed
		ctx.moveAmount = moveAmount
		ctx.heading = heading
		ctx.hipYaw = hipYaw.position
		ctx.travel = unitOr(Vector3.new(travel.X, 0, travel.Z), FORWARD)
		ctx.velocity = smoothedVelocity
		ctx.verticalSpeed = verticalSpeed
		ctx.leanPitch = leanPitch.position
		ctx.leanRoll = leanRoll.position
		ctx.turnRate = turnRate
		ctx.turnAmount = math.clamp(math.abs(turnRate) / TURN_FULL, 0, 1)
		ctx.airborne = airborne
		ctx.landing = math.max(0, landing.position)
		ctx.lookYaw = lookYaw
		ctx.lookPitch = lookPitch
		return deltaYaw
	end

	local function advancePhase(dominant: StateRuntime, deltaYaw: number, dt: number)
		local cycleWeight, lengthSum, rateSum, turnSum = 0, 0, 0, 0
		for _, runtime in stateOrder do
			local cycle = runtime.spec.cycle
			local weight = runtime.weight.position
			if cycle and weight > 0 then
				cycleWeight += weight
				lengthSum += weight * cycle.length(ctx.speed, map)
				rateSum += weight * (cycle.rate or 0)
				turnSum += weight * (cycle.turnStep or 0)
			end
		end
		table.clear(pendingFeet)
		if cycleWeight <= 0 then
			ctx.cycleLength = cycleLength
			return
		end
		local lateral = math.abs(ctx.travel.X)
		cycleLength = math.max(MIN_CYCLE, lengthSum / cycleWeight)
			* MathUtil.lerp(1, profile.lateralStride or LATERAL_STRIDE, lateral)
		local travel = ctx.speed * dt
		if ctx.speed < TURN_STEP_LIMIT then
			travel += math.abs(deltaYaw) * (turnSum / cycleWeight) * (1 - ctx.moveAmount)
		end
		local from = phase
		local to = phase + travel / cycleLength + (rateSum / cycleWeight) * dt
		local steps = dominant.spec.footsteps
		if steps and ctx.airborne < 0.5 and (ctx.moveAmount > STEP_MOVE or ctx.turnAmount > STEP_TURN) then
			for foot, mark in steps.plants do
				if ProceduralAnimator.crossed(from, to, mark) then
					table.insert(pendingFeet, foot)
				end
			end
		end
		phase = to % 1
		ctx.cycleLength = cycleLength
	end

	local function updateExertion(dt: number)
		local target = 0
		local total = 0
		for _, runtime in stateOrder do
			local weight = runtime.weight.position
			total += weight
			target += weight * (runtime.spec.exertion or 0)
		end
		if total > 0 then
			target /= total
		end
		target *= math.max(ctx.moveAmount, 0.35)
		if target > exertion then
			exertion = MathUtil.approach(exertion, target, EXERTION_RISE * dt)
		else
			exertion = MathUtil.approach(exertion, target, EXERTION_FALL * dt)
		end
		breathPhase += dt * MathUtil.lerp(BREATH_RESTED, BREATH_WINDED, exertion)
		ctx.exertion = exertion
		ctx.breath = math.sin(2 * math.pi * breathPhase)
	end

	local function updateTwist(dominant: StateRuntime, deltaYaw: number, dt: number)
		local planted = dominant.builder.planted
		for foot, value in twist do
			if planted[foot] and ctx.airborne < 0.5 then
				twist[foot] = math.clamp(value - deltaYaw, -TWIST_LIMIT, TWIST_LIMIT)
			else
				twist[foot] = MathUtil.dampNumber(value, 0, TWIST_RELEASE, dt)
			end
		end
	end

	local function solveHand(
		hand: HandRuntime,
		joint: JointMap.Joint,
		fkEntry: CFrame,
		rootWorld: CFrame,
		share: number
	): CFrame
		local spec = hand.limb.spec
		local target = hand.target or hand.held
		if not target then
			return fkEntry
		end
		local gripRig = rootWorld:ToObjectSpace(target)
		local handFrame = gripRig * hand.gripInverse
		local tipJoint = map.joints[spec.tip]
		local wristTarget = (handFrame * tipJoint.c1).Position
		local parentFrame = frames[joint.part0Name]
		local parentDelta = deltas[joint.part0Name]
		local origin = (parentFrame * joint.c0).Position
		-- Aim the middle joint where the lower bone would line up with the held tip (smallest wrist bend), with
		-- the profile's pole as the tie-breaker.
		local forearm = handFrame.Rotation * hand.lowerInTip
		local ideal = wristTarget - forearm * hand.limb.lower
		local reach = wristTarget - origin
		local toward = ideal - origin
		local across = if reach.Magnitude > 1e-4 then toward - reach.Unit * toward:Dot(reach.Unit) else toward
		local pole = across + parentDelta * hand.spec.pole * POLE_TIEBREAK
		local solution = IK.solveTwoBone(origin, wristTarget, hand.limb.upper, hand.limb.lower, pole)
		local upperDelta = IK.boneRotation(hand.limb.upperRest, hand.limb.bend, solution.mid - origin, solution.bend)
		local lowerDelta =
			IK.boneRotation(hand.limb.lowerRest, hand.limb.bend, solution.tip - solution.mid, solution.bend)
		local tipDelta = handFrame.Rotation * map.restRotationInverse[tipJoint.part1Name]
		local tipEntry = IK.limitRotation(lowerDelta:Inverse() * tipDelta, hand.spec.wristLimit)
		local weight = math.clamp(hand.weight.position * share, 0, 1)
		overrides[spec.lower] = (blended[spec.lower] or CFrame.identity):Lerp(upperDelta:Inverse() * lowerDelta, weight)
		overrides[spec.tip] = (blended[spec.tip] or CFrame.identity):Lerp(tipEntry, weight)
		return fkEntry:Lerp(parentDelta:Inverse() * upperDelta, weight)
	end

	local look = profile.look
	local function gaze(joint: JointMap.Joint, entry: CFrame, share: number): CFrame
		local parentDelta = deltas[joint.part0Name]
		local desired = CFrame.fromEulerAnglesYXZ(lookPitch, lookYaw, 0)
		local relative = parentDelta:Inverse() * desired
		local rx, ry, rz = relative:ToEulerAnglesYXZ()
		local clamped = CFrame.fromEulerAnglesYXZ(
			math.clamp(rx, -look.pitchDown, look.pitchUp),
			math.clamp(ry, -look.yaw, look.yaw),
			math.clamp(rz, -look.roll, look.roll)
		)
		return entry:Lerp(CFrame.new(entry.Position) * clamped, share)
	end

	local function solveFinal(rootWorld: CFrame, waistShare: number, headShare: number, handShare: number)
		frames[map.rootName] = CFrame.identity
		deltas[map.rootName] = CFrame.identity
		table.clear(overrides)
		local waistLook =
			CFrame.fromEulerAnglesYXZ(lookPitch * look.waistPitch * waistShare, lookYaw * look.waistYaw * waistShare, 0)
		for _, joint in map.order do
			local name = joint.name
			local entry = overrides[name] or blended[name] or CFrame.identity
			if name == look.waist and waistShare > 0 then
				entry = waistLook * entry
			end
			local hand = handsByUpper[name]
			if hand and (hand.target or hand.held) and hand.weight.position * handShare > 1e-3 then
				entry = solveHand(hand, joint, entry, rootWorld, handShare)
			end
			if name == look.neck and headShare > 0 then
				entry = gaze(joint, entry, headShare)
			end
			local curl = handsByTip[name]
			if curl and curl.grip > 1e-3 then
				entry = entry * IDENTITY:Lerp(curl.spec.curl, curl.grip)
			end
			local transform = JointMap.toTransform(joint, entry)
			local frame = frames[joint.part0Name] * joint.c0 * transform * joint.c1Inverse
			frames[joint.part1Name] = frame
			deltas[joint.part1Name] = frame.Rotation * map.restRotationInverse[joint.part1Name]
			transforms[name] = transform
		end
	end

	local function emitFootsteps(dominant: StateRuntime, rootWorld: CFrame)
		local steps = dominant.spec.footsteps
		if not steps or #pendingFeet == 0 then
			return
		end
		local volume = steps.volume * math.clamp(math.max(ctx.moveAmount, ctx.turnAmount * 0.5), 0.3, 1)
		for _, foot in pendingFeet do
			local spec = profile.feet[foot]
			local frame = if spec then frames[spec.part] else nil
			if frame then
				footstep:Fire({
					foot = foot,
					position = rootWorld * frame.Position,
					state = dominant.name,
					sprint = steps.sprint,
					volume = volume,
				})
			end
		end
	end

	local function probeGround(rootWorld: CFrame, plantShare: number, dt: number)
		local active = probe
		local floorY = rootWorld:PointToWorldSpace(Vector3.new(0, map.groundY, 0)).Y
		for foot, spec in profile.feet do
			local offset = 0
			local frame = frames[spec.part]
			if active and frame and plantShare > 0.5 and ctx.airborne < 0.5 then
				local world = rootWorld * frame.Position
				local hit =
					active(Vector3.new(world.X, floorY + PROBE_HEIGHT, world.Z), Vector3.new(0, -PROBE_DEPTH, 0))
				if hit then
					offset = math.clamp(hit.Y - floorY, -GROUND_LIMIT, GROUND_LIMIT)
				end
			end
			ground[foot] = MathUtil.dampNumber(ground[foot], offset, GROUND_DAMP, dt)
		end
	end

	local animator: Animator

	local function step(dt: number)
		if destroyed then
			return
		end
		dt = math.clamp(dt, 0, MAX_DT)
		local feed = provider
		if feed then
			feed(animator, dt)
		end
		if root.Parent == nil then
			return
		end
		local target = targetState()
		-- Hands only keep a settled rig awake where the target state lets them move the arms.
		local anyHand = false
		if (profile.states[target].hands or 1) > 0 then
			for _, hand in hands do
				if hand.target or hand.weight.position > 1e-3 or math.abs(hand.grip - hand.gripTarget) > 1e-3 then
					anyHand = true
				end
			end
		end
		if settledState == target and not anyHand then
			return
		end
		settledState = nil
		clock += dt
		local rootWorld = root.CFrame
		local deltaYaw = updateMotion(rootWorld, dt)
		local dominant, total = updateWeights(target, dt)
		advancePhase(dominant, deltaYaw, dt)
		updateExertion(dt)
		ctx.time = inputs.time or clock
		ctx.dt = dt
		ctx.phase = phase

		table.clear(poses)
		table.clear(weights)
		local waistShare, headShare, plantShare, handShare = 0, 0, 0, 0
		for _, runtime in stateOrder do
			local weight = runtime.weight.position
			if weight <= 0 then
				continue
			end
			ctx.state = runtime.name
			ctx.weight = weight / total
			runtime.builder:reset()
			runtime.spec.pose(ctx, runtime.builder)
			table.insert(poses, runtime.builder.entries)
			table.insert(weights, weight)
			local stateLook = runtime.spec.look
			waistShare += weight * (if stateLook and stateLook.waist then stateLook.waist else 1)
			headShare += weight * (if stateLook and stateLook.head then stateLook.head else 1)
			plantShare += weight * (if runtime.spec.plantFeet then 1 else 0)
			handShare += weight * math.clamp(runtime.spec.hands or 1, 0, 1)
		end
		waistShare /= total
		headShare /= total
		plantShare /= total
		handShare /= total
		ProceduralAnimator.blend(poses, weights, blended)
		updateTwist(dominant, deltaYaw, dt)

		for _, hand in hands do
			hand.weight.target = if hand.target then 1 else 0
			hand.weight:step(dt)
			hand.weight.position = math.clamp(hand.weight.position, 0, 1)
			hand.grip = MathUtil.dampNumber(hand.grip, hand.gripTarget, GRIP_DAMP, dt)
			if hand.target == nil and hand.weight.position <= 1e-3 then
				hand.weight:reset(0)
				hand.held = nil
			end
		end

		solveFinal(rootWorld, waistShare, headShare, handShare)
		for _, joint in map.order do
			JointMap.write(joint, transforms[joint.name])
		end
		emitFootsteps(dominant, rootWorld)
		probeGround(rootWorld, plantShare, dt)

		if dominant.spec.settle and dominant.weight.position >= SETTLED_WEIGHT and not anyHand then
			settledState = dominant.name
		end
	end

	animator = {
		Rig = rig,
		Map = map,
		Profile = profile,
		Footstep = footstep,
		SetInputs = function(_self: Animator, patch: InputPatch)
			if patch.moveState ~= nil then
				inputs.moveState = patch.moveState
			end
			local velocity = patch.velocity
			if velocity ~= nil and MathUtil.isFiniteVector(velocity) then
				inputs.velocity = velocity
			end
			if patch.grounded ~= nil then
				inputs.grounded = patch.grounded
			end
			local yaw = patch.lookYaw
			if yaw ~= nil and MathUtil.isFinite(yaw) then
				inputs.lookYaw = yaw
			end
			local pitch = patch.lookPitch
			if pitch ~= nil and MathUtil.isFinite(pitch) then
				inputs.lookPitch = pitch
			end
			if patch.time ~= nil then
				inputs.time = patch.time
			end
		end,
		SetHandTarget = function(_self: Animator, hand: string, target: CFrame?)
			local runtime = hands[hand]
			if not runtime then
				log.warnThrottled("hand:" .. hand, 30, "%s has no hand %s", profile.name, hand)
				return
			end
			if target and not MathUtil.isFiniteVector(target.Position) then
				return
			end
			runtime.target = target
			if target then
				runtime.held = target
			end
			settledState = nil
		end,
		SetHandGrip = function(_self: Animator, hand: string, grip: number)
			local runtime = hands[hand]
			if not runtime or not MathUtil.isFinite(grip) then
				return
			end
			runtime.gripTarget = math.clamp(grip, 0, 1)
			settledState = nil
		end,
		SetGroundProbe = function(_self: Animator, newProbe: GroundProbe?)
			probe = newProbe
		end,
		SetInputProvider = function(_self: Animator, newProvider: ((animator: Animator, dt: number) -> ())?)
			provider = newProvider
		end,
		SetPriority = function(_self: Animator, value: boolean)
			priority = value
		end,
		Step = function(_self: Animator, dt: number)
			step(dt)
		end,
		GetState = function(_self: Animator): string
			local best: StateRuntime? = nil
			for _, runtime in stateOrder do
				if best == nil or runtime.weight.position > best.weight.position then
					best = runtime
				end
			end
			return if best then best.name else profile.defaultState
		end,
		GetPhase = function(_self: Animator): number
			return phase
		end,
		GetPartFrame = function(_self: Animator, part: string): CFrame?
			return frames[part]
		end,
		IsDestroyed = function(_self: Animator): boolean
			return destroyed
		end,
		Destroy = function(self: Animator)
			if destroyed then
				return
			end
			destroyed = true
			unregister(self)
			footstep:DisconnectAll()
			provider = nil
			probe = nil
			if root.Parent ~= nil then
				for _, joint in map.order do
					JointMap.write(joint, CFrame.identity)
				end
			end
		end,
	}

	staggerCounter += 1
	register({
		animator = animator,
		step = step,
		root = function(): BasePart
			return root
		end,
		priority = function(): boolean
			return priority
		end,
		stagger = staggerCounter % REDUCED_EVERY,
		pending = 0,
	})
	return animator, nil
end

return table.freeze(ProceduralAnimator)
