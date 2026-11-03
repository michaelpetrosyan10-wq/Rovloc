--!strict
-- Creature: the Creature's animation profile (CreatureRigBuilder's 8.5-stud rig) and its one-shot action layers.
--
-- Every length comes from the rig's JointMap (bone lengths, pivots, the floor under the Humanoid, how far the claws
-- and toes reach, measured from the welded detail parts), so the profile follows the rig if its proportions change.
-- Rig axes: X right, Y up, -Z forward, origin at the HumanoidRootPart's centre.
--
-- The body moves wrong on purpose. Its head never bobs with the body: it holds perfectly still, then snaps to a new
-- direction in a few frames (a saccade tracker shared by every state; with a target it waits until the target has
-- drifted, then catches up in one jerk), cocked at a tilt. Idle bodies stay dead still apart from a slow breath,
-- broken by seeded twitches (a head jerk, a shoulder hitch, a hand spasm) that every client sees on the same frame
-- because they are a pure function of server time. Swinging feet dart off the floor and hang before they land; the
-- elbows sit a little past straight.
--
-- States (keyed by the Creature's situation; `resolveState` maps the replicated attributes onto them):
--   Dormant      hunched deep in a corner facing the wall, head hanging, arms limp, a slow shoulder-heave breath.
--   Patrol       the stalk: long bent-kneed strides that lift high and hover before they plant, a hunch, the arms
--                hanging to the knees and swaying loose, the head scanning in saccades (or locked on its target).
--   Investigate  the stalk lower, neck craned forward, the head tilting like a bird's and sniffing in short pecks,
--                the jaw parted, one hand lifted ahead with the claws feeling the air.
--   Chase        WallChase: a loping sprint of too-long strides with a flight phase, a hard forward lean, both arms
--                thrown forward reaching and clawing, the head dead level on its target, the grin hanging open.
--   VentCrawl    PoseMode Quadruped: a spider crawl inside the 3.5-stud bore with the root on the duct centreline.
--                The body hangs low and level, the hands walk on their claws beside the head with the elbows jutting
--                up toward the ceiling corners, the knees splay up the walls, the feet push off on their toes, the
--                spine snakes; diagonal limbs move together and every swing is a dart (waiting, a hand lifts now and
--                then to tap its claws on the steel). Everything stays inside the bore: the IK picks the bend plane
--                that keeps each elbow and knee off the walls, and a head that would touch the ceiling or a wall
--                lowers the body or turns the face away from it.
--   VentRetreat  stunned in a duct: the same crawl, driven backwards in stutters, the head thrashing, a hand leaving
--                the floor to claw at the face.
--   Stunned      blinded: both hands raking at the face, the head shaking, the torso wrenching, staggering steps on
--                buckling knees.
--   Swim         AquaticStalk: level in the water, an eel's wave running head to toe (chest, pelvis and the legs
--                together as a tail), the arms trailing along the flanks, the hair streaming back.
--   Scripted     neutral: upright and still, staring at its target; scripted beats drive it with actions. A scripted
--                hold in PoseMode Hunched poses Dormant instead (the corner crouch a cutscene stages it in).
--
-- Actions (one-shot layers over whatever state is posing; started with `playAction` on the rig's JointMap at an
-- animator clock time, which CreatureController feeds with server time so every client plays them together):
--   NeckSnap   the upper torso and head wrench 180 degrees round (Waist and Neck) in 0.12 s with an overshoot,
--              shudder to rest facing straight behind, hold the stare, then grind back round in three jerks.
--   Lunge      the jumpscare: a recoil, then the arms thrown forward, the hands pouncing palm-down beside the face
--              (inside the frame of the camera locked on it), the head driven forward along its face and the jaw
--              dropped wide, held shaking (CreatureConfig.Jumpscare timings).
--   LockerRip  reach, grip and wrench a locker door away with a twist of the whole body.
--   DoorSmash  wind up and smash through a door with the right forearm.
--   Vanish     a violent glitch of every joint, ending with the head wrenched sideways (it is hidden right after).
--   Reveal     appears mid-spasm, jerks once more and locks still.
-- The hair clumps hang from the scalp as damped chains: they keep their rest splay, fall with gravity, trail
-- against motion, lag behind every head snap and never pass through the floor (or the duct walls).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local ProceduralAnimator = require(script.Parent.Parent)

type Ctx = ProceduralAnimator.MotionContext
type Pose = ProceduralAnimator.PoseBuilder
type JointMap = ProceduralAnimator.JointMap
type Profile = ProceduralAnimator.Profile
type StateSpec = ProceduralAnimator.StateSpec
type CycleSpec = ProceduralAnimator.CycleSpec
type FootCycle = ProceduralAnimator.FootCycle

local JointMap = ProceduralAnimator.JointMap
local IK = ProceduralAnimator.IK

local euler = ProceduralAnimator.euler
local footCycle = ProceduralAnimator.footCycle
local ankleLift = ProceduralAnimator.ankleLift
local lerp = MathUtil.lerp
local remap = MathUtil.remapClamped
local smoothstep = MathUtil.smoothstep
local clamp01 = MathUtil.clamp01
local rad = math.rad
local TAU = 2 * math.pi

export type StateName =
	"Dormant"
	| "Patrol"
	| "Investigate"
	| "Chase"
	| "VentCrawl"
	| "VentRetreat"
	| "Stunned"
	| "Swim"
	| "Scripted"

export type ActionName = "NeckSnap" | "Lunge" | "LockerRip" | "DoorSmash" | "Vanish" | "Reveal"

--------------------------------------------------------------------------------
-- Names
--------------------------------------------------------------------------------

local SIDES: { string } = { "Left", "Right" }
local SIGN: { [string]: number } = { Left = -1, Right = 1 }
local PLANT: { [string]: number } = { Left = 0, Right = 0.5 } -- biped foot contact phase

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
local HAND_PART = names("Hand")
local CLAWS = names("Hand") -- the hands' footstep keys (they skitter on their claws in the ducts)

local ROOT = "Root"
local WAIST = "Waist"
local NECK = "Neck"
local JAW = "Jaw"
local UPPER = "UpperTorso"
local HEAD = "Head"

local REQUIRED: { string } = {
	"Root",
	"Waist",
	"Neck",
	"Jaw",
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

local STATE_NAMES: { StateName } = {
	"Dormant",
	"Patrol",
	"Investigate",
	"Chase",
	"VentCrawl",
	"VentRetreat",
	"Stunned",
	"Swim",
	"Scripted",
}

local ACTION_NAMES: { ActionName } = { "NeckSnap", "Lunge", "LockerRip", "DoorSmash", "Vanish", "Reveal" }

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local FORWARD = Vector3.new(0, 0, -1)
local DOWN = Vector3.new(0, -1, 0)
local REACH = 0.985 -- share of the leg a planted foot may reach at the ends of its stance
local BORE_HALF = WorldConfig.VentBore / 2 -- the root rides the duct centreline
local BORE_MARGIN = 0.08 -- every part stays this far inside the bore
local FLOOR_PAD = 0.05 -- planted claws and toes, and hair tips, stay this far above a floor
local HAND_FLOOR = 0.1 -- hanging claws never come lower than this above the floor
local NOISE_PERIOD = 4096 -- noise is sampled on time modulo this (keeps math.noise inputs precise)
local HUNCH_DROP = 1.3 -- PoseMode Hunched: extra pelvis drop (studs) and chest pitch
local HUNCH_PITCH = rad(38)
local HUNCH_SPEED = 3.5
local HAIR_DAMP = 9
local HAIR_STALE = 0.5 -- seconds without an update before a state's hair dynamics restart
local HAIR_STRAND = 1.3 -- the stray strands run up to this much longer than their clump segment
local DRAG_SCALE = 0.045 -- hair trailing per stud/s of motion
local MAX_DRAG = 0.9

local NECK_LIMITS = {
	pitchUp = rad(70),
	pitchDown = rad(75),
	yaw = rad(95),
	roll = rad(40),
}

-- Action timings (seconds).
local SNAP_TURN = 0.12
local SNAP_SETTLE = 0.45
local SNAP_HOLD = 2.4
local SNAP_RELEASE = 1.3
local SNAP_WAIST = rad(75)
local LUNGE = CreatureConfig.Jumpscare.LungeSeconds
local LUNGE_HOLD = CreatureConfig.Jumpscare.HoldSeconds
local LUNGE_WIND = 0.1
local LUNGE_RELEASE = 0.5
-- The claws close in beside the face, inside the jumpscare camera's frame (it sits FaceDistance ahead of the eyes).
local LUNGE_REACH = CreatureConfig.Jumpscare.FaceDistance * 0.4
local RIP = 1.35
local SMASH = 0.95
local VANISH = 0.36
local REVEAL = 0.75

local DURATIONS: { [string]: number } = {
	NeckSnap = SNAP_SETTLE + SNAP_HOLD + SNAP_RELEASE,
	Lunge = LUNGE + LUNGE_HOLD + LUNGE_RELEASE,
	LockerRip = RIP,
	DoorSmash = SMASH,
	Vanish = VANISH + 0.05,
	Reveal = REVEAL,
}

--------------------------------------------------------------------------------
-- Measurements (per rig, cached)
--------------------------------------------------------------------------------

type HairSegment = {
	joint: string,
	parentPart: string,
	length: number, -- pivot to tip, the longest stray strand included
	rest: Vector3, -- rest bone direction (rig space)
	splay: Vector3, -- horizontal outward lean at rest (rig space)
}

type Bounds = { min: Vector3, max: Vector3 }

type Measure = {
	ground: number, -- rig-space floor (biped)
	leg: number,
	thigh: number,
	shin: number,
	upperArm: number,
	forearm: number,
	arm: number,
	hip: { [string]: Vector3 },
	standHip: number,
	ankle: number, -- ankle pivot above the sole
	toe: number, -- sole extent ahead of the ankle pivot (toes included)
	heel: number,
	faceInHead: CFrame, -- the face frame (eyes' midpoint, facing forward) in the Head part's space
	bounds: { [string]: Bounds }, -- every jointed part with its welded details, in the part's own space
	-- Corners of each hand / foot (with its details) relative to its wrist / ankle pivot at rest, rig space.
	handCorners: { [string]: { Vector3 } },
	footCorners: { [string]: { Vector3 } },
	hair: { { HairSegment } },
}

local measured: { [JointMap]: Measure } = setmetatable({} :: any, { __mode = "k" })

local function cornersOf(cframe: CFrame, size: Vector3, into: Bounds)
	local half = size * 0.5
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local corner = cframe * Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)
				into.min = into.min:Min(corner)
				into.max = into.max:Max(corner)
			end
		end
	end
end

-- A jointed part's box together with every detail welded under it (descendants that are not jointed parts).
local function boundsOf(map: JointMap, name: string): Bounds
	local part = map.parts[name]
	local bounds: Bounds = { min = Vector3.one * math.huge, max = -Vector3.one * math.huge }
	cornersOf(CFrame.identity, part.Size, bounds)
	for _, descendant in part:GetDescendants() do
		if descendant:IsA("BasePart") and map.drivenBy[descendant.Name] == nil then
			cornersOf(part.CFrame:ToObjectSpace(descendant.CFrame), descendant.Size, bounds)
		end
	end
	return bounds
end

local function boxCorners(frame: CFrame, box: Bounds): { Vector3 }
	local out: { Vector3 } = {}
	for _, x in { box.min.X, box.max.X } do
		for _, y in { box.min.Y, box.max.Y } do
			for _, z in { box.min.Z, box.max.Z } do
				table.insert(out, frame * Vector3.new(x, y, z))
			end
		end
	end
	return out
end

local function hairChains(map: JointMap): { { HairSegment } }
	type Item = { index: number, joint: string }
	local clumps: { [number]: { Item } } = {}
	local order: { number } = {}
	for name in map.joints do
		local clump, segment = string.match(name, "^Hair(%d+)_(%d+)$")
		if clump and segment then
			local key = tonumber(clump) :: number
			local list = clumps[key]
			if not list then
				list = {}
				clumps[key] = list
				table.insert(order, key)
			end
			table.insert(list, { index = tonumber(segment) :: number, joint = name })
		end
	end
	table.sort(order)
	local chains: { { HairSegment } } = {}
	for _, key in order do
		local list = clumps[key]
		table.sort(list, function(a: Item, b: Item): boolean
			return a.index < b.index
		end)
		local chain: { HairSegment } = {}
		for _, item in list do
			local joint = map.joints[item.joint]
			local tip: Vector3
			if #joint.children > 0 then
				tip = map.joints[joint.children[1]].pivot
			else
				local rest = map.rest[joint.part1Name]
				tip = rest.Position + (rest.Position - joint.pivot)
			end
			local along = tip - joint.pivot
			local length = math.max(0.1, along.Magnitude)
			table.insert(chain, {
				joint = item.joint,
				parentPart = joint.part0Name,
				length = length * HAIR_STRAND,
				rest = along / length,
				splay = Vector3.new(along.X, 0, along.Z) / length,
			})
		end
		table.insert(chains, chain)
	end
	return chains
end

local function measure(map: JointMap): Measure
	local cached = measured[map]
	if cached then
		return cached
	end
	local pivot = function(name: string): Vector3
		return JointMap.pivot(map, name)
	end
	local bounds: { [string]: Bounds } = {}
	for name in map.parts do
		if name ~= map.rootName then
			bounds[name] = boundsOf(map, name)
		end
	end
	local function relativeCorners(part: string, joint: string): { Vector3 }
		local out: { Vector3 } = {}
		local origin = pivot(joint)
		for _, corner in boxCorners(map.rest[part], bounds[part]) do
			table.insert(out, corner - origin)
		end
		return out
	end
	local handCorners: { [string]: { Vector3 } } = {}
	local footCorners: { [string]: { Vector3 } } = {}
	for _, side in SIDES do
		handCorners[side] = relativeCorners(HAND_PART[side], WRIST[side])
		footCorners[side] = relativeCorners(FOOT_PART[side], ANKLE[side])
	end
	local hip = { Left = pivot("LeftHip"), Right = pivot("RightHip") }
	local thigh = JointMap.distance(map, "RightHip", "RightKnee")
	local shin = JointMap.distance(map, "RightKnee", "RightAnkle")
	local upperArm = JointMap.distance(map, "RightShoulder", "RightElbow")
	local forearm = JointMap.distance(map, "RightElbow", "RightWrist")
	local lowest, behind, ahead = math.huge, math.huge, -math.huge
	for _, offset in footCorners.Right do
		lowest = math.min(lowest, offset.Y)
		local along = offset:Dot(FORWARD)
		behind = math.min(behind, along)
		ahead = math.max(ahead, along)
	end
	local head = map.parts[HEAD]
	local face = head:FindFirstChild("FaceFrontAttachment")
	local faceInHead = if face and face:IsA("Attachment") then face.CFrame else CFrame.new(0, 0, -0.4)
	local result: Measure = {
		ground = map.groundY,
		leg = thigh + shin,
		thigh = thigh,
		shin = shin,
		upperArm = upperArm,
		forearm = forearm,
		arm = upperArm + forearm,
		hip = hip,
		standHip = hip.Right.Y - map.groundY,
		ankle = math.max(0.05, -lowest),
		toe = math.max(0.1, ahead),
		heel = math.max(0.05, -behind),
		faceInHead = faceInHead,
		bounds = bounds,
		handCorners = handCorners,
		footCorners = footCorners,
		hair = hairChains(map),
	}
	measured[map] = result
	return result
end

--------------------------------------------------------------------------------
-- Shared helpers
--------------------------------------------------------------------------------

local function wrapTime(t: number): number
	return t % NOISE_PERIOD
end

local function noise(t: number, seed: number): number
	return math.noise(wrapTime(t), seed * 7.31 + 0.5, 3.7)
end

-- Deterministic hash of two numbers into [0, 1).
local function hash01(a: number, b: number): number
	local x = math.sin((a % 65536) * 12.9898 + (b % 4096) * 78.233) * 43758.5453
	return x - math.floor(x)
end

-- Sample-and-hold noise in [-1, 1]: a new value `rate` times a second (stepped, jerky motion).
local function stepped(t: number, rate: number, seed: number): number
	return hash01(math.floor(wrapTime(t) * rate), seed) * 2 - 1
end

-- Rotation of `v` about the rig's vertical axis by `angle` (CFrame.Angles(0, angle, 0) convention).
local function yawed(v: Vector3, angle: number): Vector3
	if angle == 0 then
		return v
	end
	local c, s = math.cos(angle), math.sin(angle)
	return Vector3.new(v.X * c + v.Z * s, v.Y, -v.X * s + v.Z * c)
end

local function shiftBody(pose: Pose, offset: Vector3)
	pose:set(ROOT, CFrame.new(offset) * pose:get(ROOT))
end

-- A face-down body: pitched by `pitch` (about -pi/2), rolled about the rig's long (Z) axis, yawed about the vertical.
local function prone(pitch: number, yaw: number, roll: number): CFrame
	return CFrame.Angles(0, yaw, 0) * CFrame.Angles(0, 0, roll) * CFrame.Angles(pitch, 0, 0)
end

-- The lowest rig-space height of a part (with its details) under the pose so far.
local function lowestUnder(pose: Pose, m: Measure, part: string): number
	local lowest = math.huge
	for _, corner in boxCorners(pose:frame(part), m.bounds[part]) do
		lowest = math.min(lowest, corner.Y)
	end
	return lowest
end

-- Extent of corner offsets turned by `rotation`: (lowest Y, furthest |X| toward `sideSign`).
local function extentOf(corners: { Vector3 }, rotation: CFrame, sideSign: number): (number, number)
	local lowest, outward = math.huge, -math.huge
	for _, offset in corners do
		local turned = rotation * offset
		lowest = math.min(lowest, turned.Y)
		outward = math.max(outward, turned.X * sideSign)
	end
	return lowest, outward
end

-- The face frame (eyes' midpoint, LookVector = where the face points) under the pose so far.
local function faceFrame(pose: Pose, m: Measure): CFrame
	return pose:frame(HEAD) * m.faceInHead
end

-- Ease with a fast start and a soft landing.
local function outCubic(x: number): number
	local u = 1 - clamp01(x)
	return 1 - u * u * u
end

-- Ease that springs past the end and settles back onto it exactly at x = 1 (c = overshoot strength).
local function outBack(x: number, c: number): number
	local u = clamp01(x) - 1
	return 1 + (c + 1) * u * u * u + c * u * u
end

-- An impulse envelope: rises over `rise`, then decays exponentially at `decay` per second.
local function impulse(elapsed: number, rise: number, decay: number): number
	if elapsed < 0 then
		return 0
	end
	if elapsed < rise then
		return smoothstep(0, rise, elapsed)
	end
	return math.exp(-(elapsed - rise) * decay)
end

-- Envelope of a one-shot: in over `fadeIn`, held, out over `fadeOut` before `duration`.
local function envelope(elapsed: number, duration: number, fadeIn: number, fadeOut: number): number
	if elapsed < 0 or elapsed > duration then
		return 0
	end
	local inside = if fadeIn > 0 then smoothstep(0, fadeIn, elapsed) else 1
	local outside = if fadeOut > 0 then 1 - smoothstep(duration - fadeOut, duration, elapsed) else 1
	return math.min(inside, outside)
end

-- A swing that darts off the floor and hangs over its landing spot (`hover` 0 = the plain cycloid). With `hold`
-- the limb first waits, poised where it left the floor, for that share of the swing (stance limbs are untouched,
-- so planted feet never slide).
local function swingAlong(cycle: FootCycle, stance: number, hover: number, hold: number?): number
	if cycle.stance or (hover <= 0 and (hold or 0) <= 0) then
		return cycle.along
	end
	local wait = math.clamp(hold or 0, 0, 0.9)
	local v = clamp01((cycle.progress - wait) / (1 - wait))
	local cycloid = v - math.sin(TAU * v) / TAU
	return stance * (lerp(cycloid, outCubic(v), hover) - 0.5)
end

--------------------------------------------------------------------------------
-- Per-rig runtime: actions, hunch, focus, gaze, hair
--------------------------------------------------------------------------------

type ActionRun = {
	name: ActionName,
	startAt: number?, -- animator clock; nil binds to the next step
	sign: number, -- side the action turns toward (+1 left), fixed when it binds
	seed: number,
}

type Gaze = {
	yaw: number,
	pitch: number,
	roll: number,
	fromYaw: number,
	fromPitch: number,
	fromRoll: number,
	toYaw: number,
	toPitch: number,
	toRoll: number,
	moveStart: number,
	moveDuration: number,
	nextAt: number,
	count: number,
}

type HairDynamics = { stamp: number, directions: { [string]: Vector3 } }

type Runtime = {
	actions: { ActionRun },
	hunch: number,
	hunchTarget: number,
	focused: boolean,
	stamp: number?,
	gaze: Gaze,
	hair: { [string]: HairDynamics },
	serial: number,
}

local runtimes: { [JointMap]: Runtime } = setmetatable({} :: any, { __mode = "k" })

local function runtimeOf(map: JointMap): Runtime
	local existing = runtimes[map]
	if existing then
		return existing
	end
	local runtime: Runtime = {
		actions = {},
		hunch = 0,
		hunchTarget = 0,
		focused = false,
		stamp = nil,
		gaze = {
			yaw = 0,
			pitch = 0,
			roll = 0,
			fromYaw = 0,
			fromPitch = 0,
			fromRoll = 0,
			toYaw = 0,
			toPitch = 0,
			toRoll = 0,
			moveStart = -math.huge,
			moveDuration = 0.1,
			nextAt = -math.huge,
			count = 0,
		},
		hair = {},
		serial = 0,
	}
	runtimes[map] = runtime
	return runtime
end

-- Gaze: the head holds still, then jerks to its next direction.
local SACCADE_THRESHOLD = rad(7) -- a tracked target this far off starts a catch-up snap
local SACCADE_BASE = 0.06 -- seconds per snap, plus SACCADE_PER_RADIAN of turn
local SACCADE_PER_RADIAN = 0.07
local FOCUS_DWELL_MIN = 0.18
local FOCUS_DWELL_MAX = 0.6
local SCAN_DWELL_MIN = 1.1
local SCAN_DWELL_MAX = 3.6
local SCAN_YAW = rad(68)
local SCAN_PITCH_UP = rad(10)
local SCAN_PITCH_DOWN = rad(24)
local TILT = rad(16)

local function updateGaze(runtime: Runtime, ctx: Ctx)
	local gaze = runtime.gaze
	local t = ctx.time
	local u = if gaze.moveDuration > 0 then clamp01((t - gaze.moveStart) / gaze.moveDuration) else 1
	local e = outCubic(u)
	gaze.yaw = lerp(gaze.fromYaw, gaze.toYaw, e)
	gaze.pitch = lerp(gaze.fromPitch, gaze.toPitch, e)
	gaze.roll = lerp(gaze.fromRoll, gaze.toRoll, e)
	if u < 1 then
		return
	end
	local seed = ctx.seed * 1000
	local targetYaw, targetPitch, dwellMin, dwellMax
	if runtime.focused then
		targetYaw, targetPitch = ctx.lookYaw, ctx.lookPitch
		dwellMin, dwellMax = FOCUS_DWELL_MIN, FOCUS_DWELL_MAX
	else
		local pick = gaze.count + 1
		targetYaw = (hash01(pick, seed + 1) * 2 - 1) * SCAN_YAW + ctx.lookYaw * 0.3
		targetPitch = lerp(-SCAN_PITCH_DOWN, SCAN_PITCH_UP, hash01(pick, seed + 2))
		dwellMin, dwellMax = SCAN_DWELL_MIN, SCAN_DWELL_MAX
	end
	local offYaw = math.abs(MathUtil.angleDelta(gaze.yaw, targetYaw))
	local offPitch = math.abs(targetPitch - gaze.pitch)
	local drifted = runtime.focused and math.max(offYaw, offPitch) > SACCADE_THRESHOLD
	if not drifted and t < gaze.nextAt then
		return
	end
	gaze.count += 1
	local pick = gaze.count
	gaze.fromYaw, gaze.fromPitch, gaze.fromRoll = gaze.yaw, gaze.pitch, gaze.roll
	gaze.toYaw, gaze.toPitch = targetYaw, targetPitch
	-- Every snap lands at a new tilt; one in four cocks the head hard over.
	local tilt = (hash01(pick, seed + 3) * 2 - 1) * TILT
	if hash01(pick, seed + 4) < 0.25 then
		tilt = (if tilt >= 0 then 1 else -1) * TILT * 1.9
	end
	gaze.toRoll = tilt
	gaze.moveStart = t
	gaze.moveDuration = SACCADE_BASE + SACCADE_PER_RADIAN * math.max(offYaw, offPitch)
	gaze.nextAt = t + lerp(dwellMin, dwellMax, hash01(pick, seed + 5))
end

-- Once per animator step (the first state posed in a step does it): hunch, gaze, action bookkeeping.
local function stepRuntime(runtime: Runtime, ctx: Ctx)
	if runtime.stamp == ctx.time then
		return
	end
	runtime.stamp = ctx.time
	runtime.hunch = MathUtil.dampNumber(runtime.hunch, runtime.hunchTarget, HUNCH_SPEED, ctx.dt)
	updateGaze(runtime, ctx)
	for index = #runtime.actions, 1, -1 do
		local run = runtime.actions[index]
		local startAt = run.startAt
		if startAt == nil then
			startAt = ctx.time
			run.startAt = startAt
		end
		if run.sign == 0 then
			run.sign = if ctx.lookYaw < -0.2 then -1 else 1
		end
		if ctx.time - (startAt :: number) > DURATIONS[run.name] then
			table.remove(runtime.actions, index)
		end
	end
end

-- Seeded twitches, a pure function of time: (envelope 0..1, kind 0..1, sign) of the strongest recent twitch.
local TWITCH_SLOT = 1.6

local function twitchAt(t: number, seed: number, chance: number): (number, number, number)
	local best, kind, sign = 0, 0, 1
	local slot = math.floor(t / TWITCH_SLOT)
	for back = 0, 2 do
		local s = slot - back
		if hash01(s, seed + 11) < chance then
			local at = (s + hash01(s, seed + 12) * 0.8) * TWITCH_SLOT
			local value = impulse(t - at, 0.045, 5.5)
			if value > best then
				best = value
				kind = hash01(s, seed + 13)
				sign = if hash01(s, seed + 14) < 0.5 then -1 else 1
			end
		end
	end
	return best, kind, sign
end

--------------------------------------------------------------------------------
-- Head, jaw and hair
--------------------------------------------------------------------------------

-- Points the head (its rig-space rotation relative to rest) at `desired` through the Neck, clamped to the neck's
-- range unless `free`. The Neck entry keeps its translation (a craned neck).
local function headTo(pose: Pose, desired: CFrame, free: boolean?)
	local parent = pose:delta(UPPER)
	local relative = parent:Inverse() * desired.Rotation
	if not free then
		local rx, ry, rz = relative:ToEulerAnglesYXZ()
		relative = euler(
			math.clamp(rx, -NECK_LIMITS.pitchDown, NECK_LIMITS.pitchUp),
			math.clamp(ry, -NECK_LIMITS.yaw, NECK_LIMITS.yaw),
			math.clamp(rz, -NECK_LIMITS.roll, NECK_LIMITS.roll)
		)
	end
	pose:set(NECK, CFrame.new(pose:get(NECK).Position) * relative)
end

-- The head's rig-space rotation (relative to rest) for a look (yaw, pitch, roll) relative to the root.
local function lookRotation(yaw: number, pitch: number, roll: number): CFrame
	return euler(pitch, yaw, roll)
end

local function setJaw(pose: Pose, open: number)
	pose:set(JAW, CFrame.Angles(-math.max(0, open), 0, 0))
end

local function jawOpen(pose: Pose): number
	local rx = pose:get(JAW):ToEulerAnglesXYZ()
	return -rx
end

type HairStyle = {
	gravity: number, -- 0..1: share of the hang that falls straight down (the rest keeps the clump's own lie)
	stream: number, -- water: the hair streams back from the face instead of falling
	sway: number, -- loose sway amplitude
	bore: boolean, -- also stay inside the duct
}

local function clampTip(pivot: Vector3, direction: Vector3, length: number, floor: number, bore: boolean): Vector3
	local d = direction
	local lowest = floor + FLOOR_PAD
	if pivot.Y + d.Y * length < lowest then
		local y = math.clamp((lowest - pivot.Y) / length, -1, 1)
		local flat = Vector3.new(d.X, 0, d.Z)
		local horizontal = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, 1)
		d = horizontal * math.sqrt(math.max(0, 1 - y * y)) + Vector3.new(0, y, 0)
	end
	if bore then
		local limit = BORE_HALF - BORE_MARGIN - 0.06
		local tip = pivot + d * length
		local clamped = Vector3.new(math.clamp(tip.X, -limit, limit), math.clamp(tip.Y, -limit, limit), tip.Z)
		if (clamped - tip).Magnitude > 1e-4 then
			local toward = clamped - pivot
			local reach = toward.Magnitude
			if reach < length then
				-- Lay the rest of the length back along the duct so the tip keeps its distance.
				toward += Vector3.new(0, 0, math.sqrt(math.max(0, length * length - reach * reach)))
			end
			d = if toward.Magnitude > 1e-4 then toward.Unit else d
		end
	end
	return d
end

local function hair(ctx: Ctx, pose: Pose, m: Measure, style: HairStyle, floor: number)
	if #m.hair == 0 then
		return
	end
	local runtime = runtimeOf(ctx.map)
	local dynamics = runtime.hair[ctx.state]
	if dynamics == nil or ctx.time - dynamics.stamp > HAIR_STALE or ctx.time < dynamics.stamp then
		dynamics = { stamp = ctx.time, directions = {} }
		runtime.hair[ctx.state] = dynamics
	end
	local dt = math.max(0, ctx.time - dynamics.stamp)
	dynamics.stamp = ctx.time
	local motion = Vector3.new(ctx.velocity.X, ctx.verticalSpeed, ctx.velocity.Z)
	local drag = -motion * DRAG_SCALE
	if drag.Magnitude > MAX_DRAG then
		drag = drag.Unit * MAX_DRAG
	end
	local facing = faceFrame(pose, m).LookVector
	local back = -Vector3.new(facing.X, 0, facing.Z)
	back = if back.Magnitude > 1e-3 then back.Unit else Vector3.new(0, 0, 1)
	local headDelta = pose:delta(HEAD)
	local t = wrapTime(ctx.time)
	for chainIndex, chain in m.hair do
		for segmentIndex, segment in chain do
			local carried = pose:delta(segment.parentPart) * segment.rest
			local splay = headDelta * segment.splay
			local fall = (DOWN + Vector3.new(splay.X, 0, splay.Z) * 1.4).Unit
			local hang = fall:Lerp((back + Vector3.new(0, 0.15, 0)).Unit, style.stream)
			local stiffness = if segmentIndex == 1 then 0.4 else 0.22
			local phase = chainIndex * 1.37 + segmentIndex * 0.6
			local sway = Vector3.new(
				math.noise(t * 0.7, phase, ctx.seed * 3),
				0,
				math.noise(t * 0.6, phase + 9.1, ctx.seed * 3)
			) * (style.sway * segmentIndex)
			local keep = (1 - style.gravity) * stiffness
			local desired = carried * keep + hang * (1 - keep) + drag * segmentIndex + sway
			desired = if desired.Magnitude > 1e-4 then desired.Unit else hang
			local previous = dynamics.directions[segment.joint]
			local direction = if previous then previous:Lerp(desired, MathUtil.damp(HAIR_DAMP, dt)) else desired
			direction = if direction.Magnitude > 1e-4 then direction.Unit else desired
			direction = clampTip(pose:pivot(segment.joint), direction, segment.length, floor, style.bore)
			dynamics.directions[segment.joint] = direction
			pose:aim(segment.joint, direction)
		end
	end
end

--------------------------------------------------------------------------------
-- Limbs
--------------------------------------------------------------------------------

-- Keeps a hanging hand's claws above `floor`: bends the elbow (and lifts the arm a little) as far as needed.
local function clawsAbove(pose: Pose, m: Measure, side: string, floor: number)
	for _ = 1, 4 do
		local deficit = floor + HAND_FLOOR - lowestUnder(pose, m, HAND_PART[side])
		if deficit <= 0 then
			return
		end
		local bend = math.min(rad(40), deficit / math.max(0.5, m.forearm) * 1.15)
		pose:set(ELBOW[side], euler(bend, 0, 0) * pose:get(ELBOW[side]))
		pose:set(SHOULDER[side], euler(bend * 0.35, 0, 0) * pose:get(SHOULDER[side]))
	end
end

-- How far a point lies outside the bore's cross-section (0 inside) for a body part of radius `radius`.
local function boreExcess(point: Vector3, radius: number): number
	local limit = BORE_HALF - BORE_MARGIN - radius
	return math.max(0, math.abs(point.X) - limit) + math.max(0, math.abs(point.Y) - limit)
end

-- Two-bone IK whose bend plane is the first of `poles` that keeps the middle joint inside the bore (else the one
-- that strays least).
local function limbInBore(
	pose: Pose,
	limb: string,
	upperJoint: string,
	upper: number,
	lower: number,
	target: Vector3,
	poles: { Vector3 },
	radius: number,
	tip: CFrame
)
	local origin = pose:pivot(upperJoint)
	local best = poles[1]
	local bestExcess = math.huge
	for _, pole in poles do
		local excess = boreExcess(IK.solveTwoBone(origin, target, upper, lower, pole).mid, radius)
		if excess < bestExcess - 1e-6 then
			best = pole
			bestExcess = excess
			if excess <= 0 then
				break
			end
		end
	end
	pose:limb(limb, target, best, tip)
end

--------------------------------------------------------------------------------
-- Upright gaits
--------------------------------------------------------------------------------

type Style = {
	-- Still.
	idleDrop: number, -- pelvis drop, share of the leg
	idleWidth: number, -- foot spacing relative to the hips
	idleStagger: number, -- left foot ahead of the right, share of the leg
	-- Moving (curves over speed, studs/s).
	duty: (speed: number) -> number,
	drop: (speed: number) -> number,
	stride: (speed: number) -> number, -- wanted stance length, share of the leg
	lift: (speed: number) -> number, -- swing clearance, share of the leg
	lean: (speed: number) -> number, -- whole-body forward lean, radians
	bias: number,
	bob: number,
	sway: number,
	pelvisYaw: number,
	pelvisRoll: number,
	chestYaw: number,
	width: number,
	strike: number,
	toeOff: number,
	liftPeak: number,
	toeOut: number,
	kneeOut: number, -- knee pole outward (splayed knees)
	hover: number, -- swing shape: 0 cycloid, 1 dart off the floor and hang before planting
	hunch: number, -- chest pitch forward on top of the rig's own stoop (moving)
	idleHunch: number, -- the same, standing still
	breath: number, -- chest pitch per breath
}

type Gait = { duty: number, stance: number, centre: number, drop: number, lift: number }

local function gaitAt(style: Style, speed: number, m: Measure): Gait
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

local function cycleFor(style: Style, turnStep: number): CycleSpec
	return {
		length = function(speed: number, map: JointMap): number
			local gait = gaitAt(style, speed, measure(map))
			return gait.stance / gait.duty
		end,
		turnStep = turnStep,
	}
end

-- Extra crouching and body motion an upright state adds before the legs are solved (so the feet stay planted).
type Extra = {
	drop: number, -- studs
	pitch: number, -- chest pitch forward, radians
	root: CFrame?, -- applied to the pelvis (translation in rig axes, then rotation about the pelvis)
	waist: CFrame?, -- pre-multiplied onto the chest
}

local NO_EXTRA: Extra = { drop = 0, pitch = 0 }

type Upright = { lean: number, move: number, chestPitch: number }

-- Pelvis, chest and both legs for an upright gait.
local function upright(ctx: Ctx, pose: Pose, m: Measure, style: Style, extra: Extra): Upright
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
	local drop = lerp(style.idleDrop * leg, gait.drop, move) + extra.drop
	local midStance = gait.duty / 2
	local bobCentre = remap(gait.duty, 0.6, 0.42, 0, midStance)

	-- Pelvis.
	local bob = -style.bob * leg * move * math.cos(2 * TAU * (phase - bobCentre))
	local sway = -style.sway * leg * move * math.cos(TAU * (phase - midStance))
	local height = -drop + bob - ctx.landing
	local lean = style.lean(speed) * move
	local oscillation = math.cos(TAU * phase)
	local pelvisYaw = ctx.hipYaw - style.pelvisYaw * move * oscillation
	local chestYaw = style.chestYaw * move * oscillation
	local pelvisRoll = -style.pelvisRoll * move * math.cos(TAU * (phase - midStance))
	local pelvis = CFrame.new(sway, height, 0)
		* euler(-lean * 0.4 + ctx.leanPitch * 0.4, pelvisYaw, pelvisRoll + ctx.leanRoll * 0.5)
	local root = extra.root
	if root then
		pelvis = CFrame.new(root.Position) * pelvis * root.Rotation
	end
	pose:set(ROOT, pelvis)
	local breathe = ctx.breath * style.breath * (1 + 1.5 * ctx.exertion)
	local chestPitch = -(lean * 0.6 + lerp(style.idleHunch, style.hunch, move) + extra.pitch)
	local chest =
		euler(chestPitch + ctx.leanPitch * 0.6 + breathe, chestYaw - pelvisYaw, -pelvisRoll * 0.6 + ctx.leanRoll * 0.5)
	local waist = extra.waist
	pose:set(WAIST, if waist then waist * chest else chest)

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
		local along = swingAlong(cycle, stance, style.hover)
		local hip = m.hip[side]
		local stagger = -s * style.idleStagger * leg * 0.5 * idle
		local flat = Vector3.new(hip.X * width, 0, stagger) + ctx.travel * (along + centre)
		local position = yawed(yawed(flat, ctx.hipYaw), ctx.twist[side])
		local y = m.ground + m.ankle + cycle.lift + ctx.ground[side] + ankleLift(cycle.pitch, m.ankle, m.heel, m.toe)
		local yaw = ctx.hipYaw + ctx.twist[side] - s * style.toeOut
		local pole = yawed(Vector3.new(s * style.kneeOut, 0, -1), yaw)
		pose:limb(LEG[side], Vector3.new(position.X, y, position.Z), pole, euler(cycle.pitch, yaw, 0))
		pose:plant(side, cycle.stance or cycle.lift < 0.01 * leg)
	end
	return { lean = lean, move = move, chestPitch = chestPitch }
end

local function curve(fromSpeed: number, toSpeed: number, a: number, b: number): (speed: number) -> number
	return function(speed: number): number
		return remap(speed, fromSpeed, toSpeed, a, b)
	end
end

local function constant(value: number): (speed: number) -> number
	return function(_speed: number): number
		return value
	end
end

local STALK: Style = {
	idleDrop = 0.12,
	idleWidth = 1.15,
	idleStagger = 0.1,
	duty = curve(2, 10, 0.66, 0.56),
	drop = curve(2, 10, 0.12, 0.2),
	stride = curve(0, 10, 0.55, 1.25),
	lift = curve(0, 10, 0.1, 0.17),
	lean = curve(0, 10, rad(2), rad(8)),
	bias = 0.03,
	bob = 0.012,
	sway = 0.022,
	pelvisYaw = rad(6),
	pelvisRoll = rad(3),
	chestYaw = rad(5),
	width = 1.05,
	strike = rad(4),
	toeOff = rad(-34),
	liftPeak = 0.3,
	toeOut = rad(9),
	kneeOut = 0.45,
	hover = 0.85,
	hunch = rad(14),
	idleHunch = rad(12),
	breath = rad(1.1),
}

local CREEP: Style = table.clone(STALK)
CREEP.idleDrop = 0.17
CREEP.drop = curve(2, 14, 0.17, 0.23)
CREEP.duty = curve(2, 14, 0.64, 0.52)
CREEP.stride = curve(0, 14, 0.5, 1.3)
CREEP.lean = curve(0, 14, rad(6), rad(13))
CREEP.hunch = rad(24)
CREEP.idleHunch = rad(26)
CREEP.kneeOut = 0.6

local CHASE: Style = {
	idleDrop = 0.12,
	idleWidth = 1.1,
	idleStagger = 0.12,
	duty = curve(10, 22, 0.4, 0.3),
	drop = curve(10, 22, 0.17, 0.24),
	stride = constant(1.7),
	lift = curve(10, 22, 0.2, 0.3),
	lean = curve(6, 22, rad(18), rad(36)),
	bias = -0.06,
	bob = 0.03,
	sway = 0.012,
	pelvisYaw = rad(11),
	pelvisRoll = rad(4),
	chestYaw = rad(14),
	width = 0.85,
	strike = rad(6),
	toeOff = rad(-45),
	liftPeak = 0.32,
	toeOut = rad(6),
	kneeOut = 0.35,
	hover = 0.25,
	hunch = rad(10),
	idleHunch = rad(12),
	breath = rad(2.4),
}

local STAGGER: Style = {
	idleDrop = 0.15,
	idleWidth = 1.45,
	idleStagger = 0.2,
	duty = constant(0.62),
	drop = constant(0.18),
	stride = curve(0, 5, 0.25, 0.6),
	lift = constant(0.12),
	lean = constant(rad(4)),
	bias = 0,
	bob = 0.02,
	sway = 0.06,
	pelvisYaw = rad(9),
	pelvisRoll = rad(7),
	chestYaw = rad(6),
	width = 1.4,
	strike = rad(2),
	toeOff = rad(-20),
	liftPeak = 0.4,
	toeOut = rad(14),
	kneeOut = 0.7,
	hover = 0,
	hunch = rad(8),
	idleHunch = rad(8),
	breath = rad(3),
}

local DORMANT: Style = table.clone(STALK)
DORMANT.idleDrop = 0.27
DORMANT.idleWidth = 1.3
DORMANT.idleStagger = 0.08
DORMANT.idleHunch = rad(44)
DORMANT.hunch = rad(40)
DORMANT.kneeOut = 0.55
DORMANT.breath = 0

local NEUTRAL: Style = table.clone(STALK)
NEUTRAL.idleDrop = 0.035
NEUTRAL.idleWidth = 1
NEUTRAL.idleStagger = 0
NEUTRAL.idleHunch = 0
NEUTRAL.hunch = rad(4)
NEUTRAL.drop = curve(2, 16, 0.08, 0.18)
NEUTRAL.hover = 0.4
NEUTRAL.kneeOut = 0.25
NEUTRAL.breath = rad(0.6)

--------------------------------------------------------------------------------
-- Arms (upright)
--------------------------------------------------------------------------------

type ArmStyle = {
	hang: number, -- shoulder pitch forward when still
	swing: number, -- swing amplitude at full move, radians
	pitch: number, -- mean shoulder pitch while moving
	elbow: number, -- elbow flexion (+) or hyperextension (-)
	elbowSwing: number,
	out: number,
	sway: number, -- idle pendulum sway
	wrist: number, -- wrist flex (claws curling in)
}

local HANG: ArmStyle = {
	hang = rad(6),
	swing = rad(13),
	pitch = rad(8),
	elbow = rad(-9),
	elbowSwing = 0.25,
	out = rad(9),
	sway = rad(2.5),
	wrist = rad(6),
}

local STILL_ARMS: ArmStyle = table.clone(HANG)
STILL_ARMS.sway = 0
STILL_ARMS.elbow = rad(-6)

-- The shoulder pitch that keeps an arm hanging plumb under a stooped body.
local function plumb(body: Upright): number
	return -body.chestPitch + body.lean * 0.4
end

-- Arms hanging loose and swinging a beat behind the opposite leg; the hands dangle from the wrists.
local function hangArms(ctx: Ctx, pose: Pose, m: Measure, style: ArmStyle, body: Upright)
	local move = body.move
	local idle = 1 - move
	for _, side in SIDES do
		local s = SIGN[side]
		local legForward = math.cos(TAU * (ctx.phase - PLANT[side] - 0.08))
		local swing = -style.swing * move * legForward
		local drag = math.sin(TAU * (ctx.phase - PLANT[side] - 0.2)) * move
		local drift = idle * style.sway * noise(ctx.time * 0.31, ctx.seed * 13 + s)
		local pitch = lerp(style.hang, style.pitch, move) + swing + drift + plumb(body) * 0.9
		pose:set(SHOULDER[side], euler(pitch, s * rad(4), s * (style.out + idle * rad(1.5) * ctx.breath)))
		pose:set(ELBOW[side], euler(style.elbow + style.elbowSwing * math.max(0, swing), 0, 0))
		pose:set(WRIST[side], euler(style.wrist + rad(10) * drag, 0, -s * rad(6)))
		clawsAbove(pose, m, side, m.ground)
	end
end

--------------------------------------------------------------------------------
-- Actions (declared here, defined below the states)
--------------------------------------------------------------------------------

local applyActions: (ctx: Ctx, pose: Pose, m: Measure) -> ()

--------------------------------------------------------------------------------
-- States: upright
--------------------------------------------------------------------------------

local UPRIGHT_HAIR: HairStyle = { gravity = 0.55, stream = 0, sway = 0.05, bore = false }

local function finishUpright(ctx: Ctx, pose: Pose, m: Measure)
	applyActions(ctx, pose, m)
	hair(ctx, pose, m, UPRIGHT_HAIR, m.ground)
end

local function hunchExtra(ctx: Ctx): Extra
	local hunch = runtimeOf(ctx.map).hunch
	if hunch <= 1e-3 then
		return NO_EXTRA
	end
	return { drop = HUNCH_DROP * hunch, pitch = HUNCH_PITCH * hunch }
end

-- The upper body turns a share of the gaze (pre-multiplied: about the lower torso's vertical).
local function waistFollow(ctx: Ctx, pose: Pose, share: number)
	local gaze = runtimeOf(ctx.map).gaze
	pose:set(WAIST, euler(gaze.pitch * share * 0.5, gaze.yaw * share, 0) * pose:get(WAIST))
end

-- The head held still, then snapped round by the gaze tracker (`extraPitch` / `extraRoll` on top).
local function trackHead(ctx: Ctx, pose: Pose, extraPitch: number, extraRoll: number)
	local gaze = runtimeOf(ctx.map).gaze
	headTo(pose, lookRotation(gaze.yaw, gaze.pitch + extraPitch, gaze.roll + extraRoll))
end

local function dormant(ctx: Ctx, pose: Pose)
	local m = measure(ctx.map)
	local t = ctx.time
	local body = upright(ctx, pose, m, DORMANT, NO_EXTRA)
	-- A slow, deep breath that heaves the shoulders.
	local breath = math.sin(TAU * 0.16 * wrapTime(t) + ctx.seed * 5)
	local heave = math.max(0, breath)
	local twitch, kind, sign = twitchAt(t, ctx.seed * 100, 0.32)
	pose:set(WAIST, euler(rad(2.5) * breath, 0, 0) * pose:get(WAIST))
	for _, side in SIDES do
		local s = SIGN[side]
		local hitch = if kind > 0.66 and sign == s then twitch else 0
		pose:set(
			SHOULDER[side],
			CFrame.new(0, 0.07 * heave + 0.12 * hitch, 0.02 * heave)
				* euler(rad(16) + plumb(body) * 0.8 + rad(4) * heave, s * rad(6), s * (rad(4) + rad(2) * heave))
		)
		pose:set(ELBOW[side], euler(rad(12) + rad(8) * hitch, 0, 0))
		local spasm = if kind > 0.33 and kind <= 0.66 and sign == s then twitch else 0
		pose:set(WRIST[side], euler(rad(14) - rad(35) * spasm, 0, -s * rad(8)))
		clawsAbove(pose, m, side, m.ground)
	end
	-- Head hanging toward the wall; a twitch jerks it sideways.
	local jerk = if kind <= 0.33 then twitch else twitch * 0.25
	headTo(pose, lookRotation(sign * rad(18) * jerk, -rad(52) + rad(3) * breath, rad(9) + sign * rad(26) * jerk))
	setJaw(pose, rad(3) + rad(2) * heave)
	finishUpright(ctx, pose, m)
end

local function patrol(ctx: Ctx, pose: Pose)
	local m = measure(ctx.map)
	local body = upright(ctx, pose, m, STALK, hunchExtra(ctx))
	waistFollow(ctx, pose, 0.25)
	hangArms(ctx, pose, m, HANG, body)
	-- Idle twitches breaking the stillness: a shoulder hitch or a head jerk.
	local twitch, kind, sign = twitchAt(ctx.time, ctx.seed * 100 + 7, 0.18 * (1 - body.move))
	if kind > 0.5 then
		local side = if sign > 0 then "Right" else "Left"
		pose:set(SHOULDER[side], CFrame.new(0, 0.1 * twitch, 0) * pose:get(SHOULDER[side]))
	end
	trackHead(ctx, pose, 0, if kind <= 0.5 then sign * rad(24) * twitch else 0)
	setJaw(pose, rad(4) + rad(1.5) * (ctx.breath + 1))
	finishUpright(ctx, pose, m)
end

local function investigate(ctx: Ctx, pose: Pose)
	local m = measure(ctx.map)
	local body = upright(ctx, pose, m, CREEP, hunchExtra(ctx))
	waistFollow(ctx, pose, 0.2)
	hangArms(ctx, pose, m, HANG, body)
	local t = ctx.time
	-- One hand lifted ahead, claws curled, feeling the air.
	local feel = noise(t * 0.4, ctx.seed * 3)
	pose:set(
		SHOULDER.Right,
		euler(rad(38) + plumb(body) * 0.6 + rad(8) * feel, rad(-10), rad(14) + rad(5) * noise(t * 0.5, 4))
	)
	pose:set(ELBOW.Right, euler(rad(62) + rad(10) * noise(t * 0.7, 5), 0, 0))
	pose:set(WRIST.Right, euler(rad(28) + rad(14) * math.max(0, noise(t * 1.3, 6)), 0, rad(-12)))
	clawsAbove(pose, m, "Right", m.ground)
	-- Sniffing: bursts of quick pecks with the neck craned out; the head cocks curiously between them.
	local burst = math.max(0, math.sin(TAU * wrapTime(t) / 2.3 + ctx.seed))
	local peck = burst * math.max(0, math.sin(TAU * 5.5 * wrapTime(t))) ^ 2
	pose:set(NECK, CFrame.new(0, -0.02, -0.22 - 0.07 * peck))
	-- The face hangs low on the out-thrust neck, nose to the scent.
	trackHead(ctx, pose, -rad(24) + rad(6) * peck, rad(8) * math.sin(TAU * wrapTime(t) / 3.1))
	setJaw(pose, rad(7) + rad(5) * peck)
	finishUpright(ctx, pose, m)
end

local function chase(ctx: Ctx, pose: Pose)
	local m = measure(ctx.map)
	local body = upright(ctx, pose, m, CHASE, hunchExtra(ctx))
	waistFollow(ctx, pose, 0.15)
	local t = ctx.time
	local move = body.move
	-- Both arms thrown forward, reaching and clawing; each reach goes with the opposite leg.
	for _, side in SIDES do
		local s = SIGN[side]
		local legForward = math.cos(TAU * (ctx.phase - PLANT[side]))
		local claw = noise(t * 3.1, ctx.seed * 11 + s * 3)
		local reach = lerp(rad(30), rad(72), move) + rad(24) * legForward * move + rad(14) * claw
		pose:set(SHOULDER[side], euler(reach + plumb(body) * 0.6, -s * rad(8), s * (rad(14) + rad(10) * claw)))
		local grab = math.max(0, noise(t * 4.3, ctx.seed * 13 + s))
		pose:set(ELBOW[side], euler(rad(18) + rad(46) * grab + rad(12) * (1 - move), 0, 0))
		pose:set(WRIST[side], euler(rad(-26) + rad(40) * grab, 0, -s * rad(10)))
		clawsAbove(pose, m, side, m.ground)
	end
	-- The head stays dead level on its target while the body pounds underneath it.
	trackHead(ctx, pose, rad(4) * move, 0)
	local snap = math.max(0, noise(t * 2.2, ctx.seed * 17))
	setJaw(pose, rad(22) + rad(18) * snap * move + rad(4) * math.sin(TAU * 2 * ctx.phase))
	finishUpright(ctx, pose, m)
end

local function stunned(ctx: Ctx, pose: Pose)
	local m = measure(ctx.map)
	local t = ctx.time
	local seed = ctx.seed * 19
	local function thrash(rate: number, offset: number): number
		return noise(t * rate, seed + offset)
	end
	-- Knees buckle in lurches; the body reels.
	local buckle = math.max(0, thrash(0.9, 1) - 0.15) * 1.6
	upright(ctx, pose, m, STAGGER, {
		drop = 0.55 * buckle,
		pitch = rad(6) * buckle,
		root = CFrame.new(0.25 * thrash(0.8, 5), 0, 0.2 * thrash(0.7, 6))
			* euler(0, rad(10) * thrash(1.1, 7), rad(8) * thrash(1.4, 8)),
		waist = euler(rad(14) * thrash(1.7, 2) - rad(10), rad(26) * thrash(1.3, 3), rad(14) * thrash(1.9, 4)),
	})
	-- The head shakes and wrenches as if it could tear the burning off.
	local gaze = runtimeOf(ctx.map).gaze
	headTo(
		pose,
		lookRotation(
			gaze.yaw * 0.3 + rad(40) * thrash(2.8, 10) + rad(9) * stepped(t, 9, seed + 20),
			rad(18) * thrash(2.2, 11) + rad(10),
			rad(30) * thrash(2.5, 12)
		)
	)
	-- Both hands rake at the face: claws dragged down over the eyes in turn.
	local face = faceFrame(pose, m)
	for _, side in SIDES do
		local s = SIGN[side]
		local rake = (wrapTime(t) * 2.4 + (if s > 0 then 0.5 else 0)) % 1
		local down = smoothstep(0.1, 0.75, rake)
		local offset = Vector3.new(s * (0.32 + 0.1 * thrash(3, 9 + s)), 0.35 - 0.75 * down, -0.3 + 0.15 * down)
		pose:limb(ARM[side], face * offset, face:VectorToWorldSpace(Vector3.new(s, -0.6, 0.35)), nil)
		pose:set(WRIST[side], euler(rad(30) + rad(30) * down, 0, 0) * pose:get(WRIST[side]))
	end
	setJaw(pose, rad(38) + rad(20) * thrash(4, 13))
	finishUpright(ctx, pose, m)
end

local function scripted(ctx: Ctx, pose: Pose)
	local m = measure(ctx.map)
	local body = upright(ctx, pose, m, NEUTRAL, hunchExtra(ctx))
	waistFollow(ctx, pose, 0.2)
	hangArms(ctx, pose, m, STILL_ARMS, body)
	trackHead(ctx, pose, 0, 0)
	setJaw(pose, rad(3))
	finishUpright(ctx, pose, m)
end

--------------------------------------------------------------------------------
-- States: the duct crawl
--------------------------------------------------------------------------------

type CrawlStyle = {
	duty: number,
	stride: number, -- stance length at full move (studs)
	handLift: number,
	footLift: number,
	reach: number, -- hands ahead of the shoulders (studs)
	handOut: number, -- wanted distance of the wrists from the centreline (kept inside the bore)
	footBack: number, -- feet behind the hips
	footOut: number,
	hipHeight: number, -- hip pivots above the bore floor
	shoulderZ: number, -- shoulder line ahead of the root
	chestRise: number, -- the spine rises toward the shoulders (radians)
	spine: number, -- lateral spine wave
	roll: number, -- body roll with the gait
	face: number, -- head pitch (negative peers from under the brow)
	clawTip: number, -- hands tipped forward onto the claws (radians)
	toeTip: number, -- feet pitched onto the toes (radians)
	stutter: number, -- 0..1: jerky, stop-start limbs and body
	hover: number,
}

local function crawlCycle(style: CrawlStyle): CycleSpec
	return {
		length = function(_speed: number, _map: JointMap): number
			return style.stride / style.duty
		end,
		turnStep = 0.9,
	}
end

-- Plants for the duct gaits: diagonal pairs land a beat apart, so each pair is two clicks.
local CRAWL_PLANT: { [string]: number } = {
	LeftHand = 0,
	Right = 0.07,
	RightHand = 0.5,
	Left = 0.57,
}

local BORE_HAIR: HairStyle = { gravity = 0.75, stream = 0.35, sway = 0.03, bore = true }
local QUADRUPED: { [string]: boolean } = { VentCrawl = true, VentRetreat = true }
local HEAD_PARTS: { string } = { HEAD, JAW }
local BODY_PARTS: { string } = { "LowerTorso", UPPER }
local FIT_STEP = rad(5)

-- Rig-space extent of some parts (with their details) under the pose so far: top, bottom, right, left.
local function spanOf(pose: Pose, m: Measure, parts: { string }): (number, number, number, number)
	local top, bottom, right, left = -math.huge, math.huge, -math.huge, math.huge
	for _, part in parts do
		for _, corner in boxCorners(pose:frame(part), m.bounds[part]) do
			top = math.max(top, corner.Y)
			bottom = math.min(bottom, corner.Y)
			right = math.max(right, corner.X)
			left = math.min(left, corner.X)
		end
	end
	return top, bottom, right, left
end

-- Turns the head about its pivot, a step at a time, until it clears the duct: rolled back off a wall, the face
-- tipped down from the ceiling (or up off the floor).
local function headInBore(pose: Pose, m: Measure, limit: number)
	for _ = 1, 12 do
		local top, bottom, right, left = spanOf(pose, m, HEAD_PARTS)
		local turn: CFrame
		if right > limit then
			turn = CFrame.Angles(0, 0, FIT_STEP)
		elseif left < -limit then
			turn = CFrame.Angles(0, 0, -FIT_STEP)
		elseif top > limit then
			turn = CFrame.Angles(-FIT_STEP, 0, 0)
		elseif bottom < -limit then
			turn = CFrame.Angles(FIT_STEP, 0, 0)
		else
			return
		end
		headTo(pose, turn * pose:delta(HEAD), true)
	end
end

local ARM_POLES: { [string]: { Vector3 } } = {}
local LEG_POLES: { [string]: { Vector3 } } = {}
for _, side in SIDES do
	local s = SIGN[side]
	ARM_POLES[side] = {
		Vector3.new(s * 0.75, 1, -0.15),
		Vector3.new(s * 1, 0.55, 0),
		Vector3.new(s * 0.35, 1, 0.3),
		Vector3.new(s * 1, 0.1, 0.4),
		Vector3.new(0, 1, 0.6),
	}
	LEG_POLES[side] = {
		Vector3.new(s * 0.8, 1, -0.3),
		Vector3.new(s * 1, 0.4, -0.2),
		Vector3.new(s * 0.5, 1, 0.2),
		Vector3.new(s * 1, -0.2, 0),
		Vector3.new(0, 1, -0.6),
	}
end

local function crawl(ctx: Ctx, pose: Pose, style: CrawlStyle, thrash: number)
	local m = measure(ctx.map)
	local floor = -BORE_HALF
	local limit = BORE_HALF - BORE_MARGIN
	local move = ctx.moveAmount
	local t = ctx.time
	local seed = ctx.seed * 23
	local direction = if ctx.heading.Z > 0.3 then -1 else 1 -- +1 crawling forward
	local phase = ctx.phase
	-- Stutter: the swinging limbs freeze in the air for a beat, then dart.
	local hold = style.stutter * 0.5 * (stepped(t, 7, seed) * 0.5 + 0.5)
	local stance = style.duty * ctx.cycleLength * move
	local oscillation = math.sin(TAU * phase)

	-- Body: face down, low and level, the spine snaking with the gait.
	local roll = style.roll * move * oscillation
	local wave = style.spine * move * math.sin(TAU * (phase + 0.12))
	local jolt = style.stutter * move * stepped(t, 11, seed + 1)
	pose:set(ROOT, prone(-math.pi / 2 + rad(2) + rad(3) * jolt, wave * 0.5, roll))
	pose:set(WAIST, euler(style.chestRise + ctx.breath * rad(1.4), -roll * 0.5, -wave))
	local hips = (pose:pivot(HIP.Left) + pose:pivot(HIP.Right)) / 2
	local shoulders = pose:pivot(SHOULDER.Left)
	shiftBody(
		pose,
		Vector3.new(0, floor + style.hipHeight - hips.Y + 0.05 * jolt, -style.shoulderZ - shoulders.Z + 0.08 * jolt)
	)

	-- Head: low and forward, peering from under the brow; the gaze tracker snaps it about.
	local gaze = runtimeOf(ctx.map).gaze
	headTo(
		pose,
		lookRotation(
			gaze.yaw * 0.55 + thrash * rad(35) * noise(t * 3.4, seed + 3),
			style.face + gaze.pitch * 0.4 + thrash * rad(10) * noise(t * 2.6, seed + 4),
			gaze.roll * 1.3 + thrash * rad(25) * noise(t * 2.9, seed + 5)
		),
		true
	)
	-- A crown that would scrape the ceiling lowers the whole body first (while the belly has room), then the face.
	local ceiling = BORE_HALF - BORE_MARGIN
	local top = spanOf(pose, m, HEAD_PARTS)
	if top > ceiling then
		local _, belly = spanOf(pose, m, BODY_PARTS)
		local drop = math.min(top - ceiling, math.max(0, belly - (floor + BORE_MARGIN)))
		if drop > 0 then
			shiftBody(pose, Vector3.new(0, -drop, 0))
		end
	end
	headInBore(pose, m, ceiling)

	-- Arms: walking on the claws beside the head, elbows jutting up toward the ceiling corners. Waiting, a hand now
	-- and then lifts and taps its claws on the steel.
	local tap, _, tapSide = twitchAt(t, ctx.seed * 100 + 31, 0.3 * (1 - move))
	for _, side in SIDES do
		local s = SIGN[side]
		local cycle = footCycle(phase - CRAWL_PLANT[CLAWS[side]], stance, {
			duty = style.duty,
			lift = style.handLift * move,
			liftPeak = 0.35,
		})
		if tapSide == s and tap > 0 then
			cycle.lift += 0.3 * tap
		end
		local along = swingAlong(cycle, stance, style.hover, hold)
		local lifted = if style.handLift > 0 then clamp01(cycle.lift / style.handLift) else 0
		local hand = CFrame.Angles(0, 0, s * rad(14)) * CFrame.Angles(style.clawTip + rad(30) * lifted, 0, 0)
		local lowest, outward = extentOf(m.handCorners[side], hand, s)
		local shoulder = pose:pivot(SHOULDER[side])
		local wrist = Vector3.new(
			s * math.min(style.handOut, limit - outward),
			floor + FLOOR_PAD - lowest + cycle.lift,
			shoulder.Z - style.reach - direction * along
		)
		local clawing = if side == "Right" then thrash else 0
		if clawing > 0 then
			-- The hand leaves the floor to claw at the face.
			local face = faceFrame(pose, m)
			local rake = (wrapTime(t) * 2.2) % 1
			local target = face * Vector3.new(s * 0.32, 0.3 - 0.6 * smoothstep(0.1, 0.8, rake), -0.35)
			wrist = wrist:Lerp(target, clawing)
		end
		limbInBore(pose, ARM[side], SHOULDER[side], m.upperArm, m.forearm, wrist, ARM_POLES[side], 0.24, hand)
		pose:plant(CLAWS[side], cycle.stance)
	end

	-- Legs: splayed, the knees up the walls, the feet pushing off the bore floor on their toes behind.
	for _, side in SIDES do
		local s = SIGN[side]
		local cycle = footCycle(phase - CRAWL_PLANT[side], stance, {
			duty = style.duty,
			lift = style.footLift * move,
			liftPeak = 0.4,
		})
		local along = swingAlong(cycle, stance, style.hover, hold)
		local foot = euler(style.toeTip, s * rad(28), 0)
		local lowest, outward = extentOf(m.footCorners[side], foot, s)
		local hip = pose:pivot(HIP[side])
		local ankle = Vector3.new(
			s * math.min(style.footOut, limit - outward),
			floor + FLOOR_PAD - lowest + cycle.lift,
			hip.Z + style.footBack - direction * along
		)
		limbInBore(pose, LEG[side], HIP[side], m.thigh, m.shin, ankle, LEG_POLES[side], 0.3, foot)
		pose:plant(side, cycle.stance)
	end

	setJaw(pose, rad(10) + rad(6) * math.max(0, oscillation) * move + thrash * rad(25))
	applyActions(ctx, pose, m)
	headInBore(pose, m, ceiling)
	hair(ctx, pose, m, BORE_HAIR, floor)
end

local VENT: CrawlStyle = {
	duty = 0.56,
	stride = 1.9,
	handLift = 0.32,
	footLift = 0.22,
	reach = 1.05,
	handOut = 1.2,
	footBack = 1.0,
	footOut = 1.15,
	hipHeight = 0.85,
	shoulderZ = 1.9,
	chestRise = rad(9),
	spine = rad(9),
	roll = rad(4),
	face = rad(-8),
	clawTip = rad(35),
	toeTip = rad(-62),
	stutter = 0.15,
	hover = 0.7,
}

local RETREAT: CrawlStyle = table.clone(VENT)
RETREAT.duty = 0.62
RETREAT.stride = 1.2
RETREAT.stutter = 1
RETREAT.hover = 0.3
RETREAT.face = rad(-12)

local function ventCrawl(ctx: Ctx, pose: Pose)
	crawl(ctx, pose, VENT, 0)
end

local function ventRetreat(ctx: Ctx, pose: Pose)
	local claw = smoothstep(0.2, 0.6, math.max(0, noise(ctx.time * 0.5, ctx.seed * 29)))
	crawl(ctx, pose, RETREAT, claw)
end

--------------------------------------------------------------------------------
-- States: water
--------------------------------------------------------------------------------

local SWIM_HAIR: HairStyle = { gravity = 0.2, stream = 0.85, sway = 0.12, bore = false }
local SWIM_FLOOR = -1e6

local function swim(ctx: Ctx, pose: Pose)
	local m = measure(ctx.map)
	local phase = ctx.phase
	local amplitude = rad(13) * math.max(ctx.moveAmount, 0.35)
	-- An eel's wave: each segment's heading lags the one ahead of it.
	local function heading(lag: number, gain: number): number
		return amplitude * gain * math.sin(TAU * (phase - lag))
	end
	local head, chest, pelvis, thighs, shins =
		heading(0, 0.35), heading(0.12, 0.8), heading(0.24, 1), heading(0.36, 1.5), heading(0.48, 2.2)
	pose:set(ROOT, prone(-math.pi / 2 + rad(4), pelvis, ctx.leanRoll * 0.5))
	pose:set(WAIST, euler(rad(14) + ctx.breath * rad(1), 0, -(chest - pelvis)))
	local neckNow = pose:pivot(NECK)
	shiftBody(pose, Vector3.new(0, -0.15 - neckNow.Y, -1.9 - neckNow.Z))
	local gaze = runtimeOf(ctx.map).gaze
	headTo(pose, lookRotation(gaze.yaw * 0.6 + head, rad(-30) + gaze.pitch * 0.5, gaze.roll * 0.5), true)
	for _, side in SIDES do
		local s = SIGN[side]
		-- Arms trailing back along the flanks, rippling with the wave.
		local ripple = math.sin(TAU * (phase - 0.3))
		pose:set(SHOULDER[side], euler(rad(-18) + rad(6) * ripple * s, 0, s * (rad(10) + rad(5) * ripple)))
		pose:set(ELBOW[side], euler(rad(-4) + rad(8) * math.max(0, ripple * s), 0, 0))
		pose:set(WRIST[side], euler(rad(-10), 0, -s * rad(10) * ripple))
		-- Legs together as a tail.
		pose:set(HIP[side], euler(rad(2), 0, -(thighs - pelvis) + s * rad(2)))
		pose:set(KNEE[side], euler(-rad(6), 0, -(shins - thighs)))
		pose:set(ANKLE[side], euler(-rad(55), 0, 0))
	end
	setJaw(pose, rad(6) + rad(4) * math.sin(TAU * phase))
	applyActions(ctx, pose, m)
	hair(ctx, pose, m, SWIM_HAIR, SWIM_FLOOR)
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

type ActionFn = (ctx: Ctx, pose: Pose, m: Measure, elapsed: number, run: ActionRun) -> ()

-- How far round the snap has turned: 0 (base pose) .. 1 (facing straight behind), overshooting on the way in.
local function snapProgress(elapsed: number): number
	if elapsed < 0 then
		return 0
	elseif elapsed < SNAP_TURN then
		return outBack(elapsed / SNAP_TURN, 1.2)
	end
	local holdEnd = SNAP_SETTLE + SNAP_HOLD
	if elapsed < holdEnd then
		return 1
	end
	-- Grinds back round in three jerks.
	local steps = 3
	local u = clamp01((elapsed - holdEnd) / SNAP_RELEASE) * steps
	local k = math.floor(u)
	return 1 - clamp01((k + smoothstep(0.35, 0.75, u - k)) / steps)
end

-- The settle shudder after the snap (radians of yaw), decaying.
local function snapShudder(elapsed: number): number
	if elapsed < SNAP_TURN or elapsed > SNAP_SETTLE then
		return 0
	end
	local u = elapsed - SNAP_TURN
	return rad(3.5) * math.exp(-u * 9) * math.sin(TAU * 17 * u)
end

local function neckSnap(ctx: Ctx, pose: Pose, _m: Measure, elapsed: number, run: ActionRun)
	local s = snapProgress(elapsed)
	if s <= 0 then
		return
	end
	local sign = run.sign
	local shudder = snapShudder(elapsed)
	local rx, ry, rz = pose:delta(HEAD):ToEulerAnglesYXZ()
	if not QUADRUPED[ctx.state] then
		-- The stoop half straightens as the upper body wrenches round, so it stares level over its shoulder. (In a
		-- duct the limbs carry the body, so the neck alone turns.)
		local stoop = pose:get(WAIST):Lerp(CFrame.identity, 0.5 * math.min(s, 1))
		pose:set(WAIST, euler(0, sign * (SNAP_WAIST * s + shudder * 0.5), 0) * stoop)
	end
	local hold = smoothstep(SNAP_TURN, SNAP_SETTLE + 0.4, elapsed) * s
	headTo(
		pose,
		euler(lerp(rx, rad(-4), s), lerp(ry, sign * math.pi, s) + shudder, lerp(rz, sign * rad(11), hold)),
		true
	)
	setJaw(pose, lerp(jawOpen(pose), rad(9), hold))
end

-- Blends a set of joint entries toward the ones `solve` writes, by `weight`.
local function blendJoints(pose: Pose, joints: { string }, weight: number, solve: () -> ())
	if weight <= 0 then
		return
	end
	local saved: { [string]: CFrame } = {}
	for _, joint in joints do
		saved[joint] = pose:get(joint)
	end
	solve()
	if weight >= 1 then
		return
	end
	for _, joint in joints do
		pose:set(joint, saved[joint]:Lerp(pose:get(joint), weight))
	end
end

local ARM_JOINTS: { [string]: { string } } = {
	Left = { SHOULDER.Left, ELBOW.Left, WRIST.Left },
	Right = { SHOULDER.Right, ELBOW.Right, WRIST.Right },
}

local function lunge(ctx: Ctx, pose: Pose, m: Measure, elapsed: number, run: ActionRun)
	local weight = envelope(elapsed, DURATIONS.Lunge, LUNGE_WIND * 0.6, LUNGE_RELEASE)
	if weight <= 0 then
		return
	end
	-- Recoil, then thrown forward.
	local recoil = smoothstep(0, LUNGE_WIND, elapsed) * (1 - smoothstep(LUNGE_WIND, LUNGE_WIND + 0.08, elapsed))
	local thrust = if elapsed < LUNGE_WIND
		then 0
		else outBack((elapsed - LUNGE_WIND) / math.max(0.05, LUNGE - LUNGE_WIND), 1.6)
	local tremor = smoothstep(LUNGE, LUNGE + 0.1, elapsed) * stepped(ctx.time, 24, run.seed)
	-- The chest is thrown forward only when it stands upright (in a duct it would dig into the floor).
	local standing = clamp01(pose:frame(UPPER).UpVector.Y)
	pose:set(
		WAIST,
		euler((rad(-22) * thrust + rad(14) * recoil) * weight * standing, 0, rad(3) * tremor * weight) * pose:get(WAIST)
	)
	-- Head driven forward along its face, chin up toward its victim; the jaw drops wide and shudders.
	local rx, ry, rz = pose:delta(HEAD):ToEulerAnglesYXZ()
	local push = pose:delta(UPPER):Inverse() * (faceFrame(pose, m).LookVector * (0.14 * thrust * weight))
	pose:set(NECK, CFrame.new(push) * pose:get(NECK))
	headTo(
		pose,
		euler(lerp(rx, rad(10) - rad(14) * recoil, weight), lerp(ry, 0, weight), lerp(rz, rad(6) * tremor, weight)),
		true
	)
	-- Arms: thrown out past the face, the claws closing in on either side of the victim's head.
	local face = faceFrame(pose, m)
	local bore = QUADRUPED[ctx.state] == true
	for _, side in SIDES do
		local s = SIGN[side]
		blendJoints(pose, ARM_JOINTS[side], weight, function()
			local shoulder = pose:pivot(SHOULDER[side])
			local target = face
				* Vector3.new(
					s * lerp(0.45, 0.8, thrust),
					-0.05 * thrust - 0.4 * recoil,
					-lerp(0.3, LUNGE_REACH, thrust)
				)
			local toward = target - shoulder
			if toward.Magnitude > m.arm * 0.97 then
				target = shoulder + toward.Unit * m.arm * 0.97
			end
			-- The hands pounce: palms down, fingers forward, the hooked claws coming down at the victim's eyes.
			local grab = face.Rotation
				* CFrame.Angles(0, s * rad(15), 0)
				* CFrame.Angles(-rad(20), 0, 0)
				* CFrame.fromMatrix(Vector3.zero, Vector3.new(0, s, 0), Vector3.new(0, 0, 1), Vector3.new(s, 0, 0))
			if bore then
				local limit = BORE_HALF - BORE_MARGIN - 0.3
				target = Vector3.new(math.clamp(target.X, -limit, limit), math.clamp(target.Y, -limit, limit), target.Z)
				limbInBore(pose, ARM[side], SHOULDER[side], m.upperArm, m.forearm, target, ARM_POLES[side], 0.24, grab)
			else
				pose:limb(ARM[side], target, face:VectorToWorldSpace(Vector3.new(s, -0.4, 0)), grab)
			end
		end)
	end
	local open = rad(68) * smoothstep(LUNGE_WIND * 0.5, LUNGE, elapsed) + rad(4) * tremor
	setJaw(pose, lerp(jawOpen(pose), open, weight))
end

-- Ripping and smashing need the body upright (nothing to rip from inside a duct).
local function lockerRip(ctx: Ctx, pose: Pose, m: Measure, elapsed: number, _run: ActionRun)
	local weight = envelope(elapsed, RIP, 0.15, 0.4)
	if weight <= 0 or QUADRUPED[ctx.state] then
		return
	end
	local reach = smoothstep(0, 0.35, elapsed)
	local brace = smoothstep(0.35, 0.55, elapsed)
	local rip = smoothstep(0.55, 0.72, elapsed)
	pose:set(
		WAIST,
		euler((rad(-18) * reach + rad(16) * brace) * weight, rad(-42) * rip * weight, rad(-8) * rip * weight)
			* pose:get(WAIST)
	)
	local rx, ry, rz = pose:delta(HEAD):ToEulerAnglesYXZ()
	headTo(pose, euler(rx, lerp(ry, rad(-25), rip * weight), lerp(rz, rad(18), rip * weight)))
	local chest = pose:frame(UPPER)
	for _, side in SIDES do
		local s = SIGN[side]
		blendJoints(pose, ARM_JOINTS[side], weight, function()
			local shoulder = pose:pivot(SHOULDER[side])
			-- Hands on the door's edge ahead at chest height, then wrenched back and across.
			local grip = shoulder + chest:VectorToWorldSpace(Vector3.new(-s * 0.3, -0.5, -m.arm * 0.72))
			local pulled = shoulder + chest:VectorToWorldSpace(Vector3.new(s * 0.2 + 0.9, -0.7, -m.arm * 0.35))
			pose:limb(ARM[side], grip:Lerp(pulled, rip), chest:VectorToWorldSpace(Vector3.new(s, -0.5, 0.2)), nil)
			pose:set(WRIST[side], euler(rad(50) * brace, 0, 0) * pose:get(WRIST[side]))
		end)
	end
	setJaw(pose, rad(30) * rip * weight + rad(5))
end

local function doorSmash(ctx: Ctx, pose: Pose, m: Measure, elapsed: number, _run: ActionRun)
	local weight = envelope(elapsed, SMASH, 0.1, 0.35)
	if weight <= 0 or QUADRUPED[ctx.state] then
		return
	end
	local wind = smoothstep(0, 0.3, elapsed)
	local smash = smoothstep(0.3, 0.42, elapsed)
	pose:set(
		WAIST,
		euler(
			(rad(10) * wind - rad(20) * smash) * weight,
			(rad(-32) * wind + rad(44) * smash) * weight,
			rad(-6) * wind * weight
		) * pose:get(WAIST)
	)
	-- The right forearm: raised high behind the head, then driven straight ahead at chest height through the door.
	blendJoints(pose, ARM_JOINTS.Right, weight, function()
		local shoulder = pose:pivot(SHOULDER.Right)
		local raised = shoulder + Vector3.new(0.4, m.arm * 0.5, m.arm * 0.3)
		local struck = shoulder + Vector3.new(-0.5, -0.2, -m.arm * 0.85)
		local target = shoulder:Lerp(raised, wind):Lerp(struck, smash)
		pose:limb(ARM.Right, target, Vector3.new(1, 0.2, 0.6), nil)
	end)
	blendJoints(pose, ARM_JOINTS.Left, weight * 0.8, function()
		local shoulder = pose:pivot(SHOULDER.Left)
		local guard = shoulder + Vector3.new(0.5, -m.arm * 0.15, -m.arm * 0.6)
		pose:limb(ARM.Left, guard, Vector3.new(-1, -0.4, 0.3), nil)
	end)
	setJaw(pose, rad(26) * smash * weight + rad(4))
end

-- Glitch: every upper-body joint jerks to a new random offset many times a second.
local GLITCH_JOINTS: { string } = {
	NECK,
	WAIST,
	SHOULDER.Left,
	SHOULDER.Right,
	ELBOW.Left,
	ELBOW.Right,
	WRIST.Left,
	WRIST.Right,
}

-- `limbs` false keeps the torso and limbs still (in a duct they carry the body): only the head and jaw jerk.
local function glitch(pose: Pose, t: number, seed: number, amount: number, limbs: boolean)
	if amount <= 0 then
		return
	end
	for index, joint in GLITCH_JOINTS do
		if not limbs and joint ~= NECK then
			continue
		end
		local scale = if joint == NECK then 1.4 elseif joint == WAIST then 0.6 else 1
		local pitch = stepped(t, 26, seed + index * 3) * rad(28) * scale * amount
		local yaw = stepped(t, 23, seed + index * 3 + 1) * rad(34) * scale * amount
		local roll = stepped(t, 29, seed + index * 3 + 2) * rad(26) * scale * amount
		pose:set(joint, euler(pitch, yaw, roll) * pose:get(joint))
	end
	local jaw = math.max(0, stepped(t, 31, seed + 40)) * rad(40) * amount
	pose:set(JAW, CFrame.Angles(-jaw, 0, 0) * pose:get(JAW))
end

local function vanish(ctx: Ctx, pose: Pose, _m: Measure, elapsed: number, run: ActionRun)
	local amount = smoothstep(0, 0.06, elapsed) * (if elapsed <= VANISH then 1 else 0)
	glitch(pose, ctx.time, run.seed, amount * (0.6 + 0.4 * smoothstep(0.1, VANISH, elapsed)), not QUADRUPED[ctx.state])
	-- It ends with the head wrenched sideways.
	local wrench = smoothstep(VANISH * 0.65, VANISH, elapsed) * amount
	pose:set(NECK, euler(rad(-10) * wrench, run.sign * rad(55) * wrench, run.sign * rad(40) * wrench) * pose:get(NECK))
end

local function reveal(ctx: Ctx, pose: Pose, _m: Measure, elapsed: number, run: ActionRun)
	-- A spasm, one hard jerk, then locked still; the jerk's cocked head eases out.
	glitch(pose, ctx.time, run.seed, 1 - smoothstep(0, 0.28, elapsed), not QUADRUPED[ctx.state])
	local jerk = impulse(elapsed - 0.34, 0.03, 9)
	local cock = if elapsed > 0.32 then math.max(jerk, 1 - smoothstep(0.38, REVEAL, elapsed)) else 0
	pose:set(NECK, euler(rad(6) * cock, run.sign * rad(14) * cock, run.sign * rad(34) * cock) * pose:get(NECK))
end

local ACTIONS: { [string]: ActionFn } = {
	NeckSnap = neckSnap,
	Lunge = lunge,
	LockerRip = lockerRip,
	DoorSmash = doorSmash,
	Vanish = vanish,
	Reveal = reveal,
}

-- Applies every running action on top of the state's pose, in start order.
function applyActions(ctx: Ctx, pose: Pose, m: Measure)
	for _, run in runtimeOf(ctx.map).actions do
		local startAt = run.startAt
		if startAt == nil then
			continue
		end
		local elapsed = ctx.time - startAt
		if elapsed >= 0 and elapsed <= DURATIONS[run.name] then
			ACTIONS[run.name](ctx, pose, m, elapsed, run)
		end
	end
end

--------------------------------------------------------------------------------
-- Profile
--------------------------------------------------------------------------------

-- Every pose starts by stepping the rig's runtime (once per animator step: gaze, hunch, action bookkeeping).
local function posed(fn: (ctx: Ctx, pose: Pose) -> ()): (ctx: Ctx, pose: Pose) -> ()
	return function(ctx: Ctx, pose: Pose)
		stepRuntime(runtimeOf(ctx.map), ctx)
		fn(ctx, pose)
	end
end

local function state(spec: StateSpec): StateSpec
	return spec
end

-- The profile aims the head itself (saccades, crane, snap): the animator's own look layer stays out of it.
local OWN_LOOK: ProceduralAnimator.StateLook = { waist = 0, head = 0 }

local states: { [string]: StateSpec } = {
	Dormant = state({
		pose = posed(dormant),
		cycle = cycleFor(DORMANT, 1),
		footsteps = { plants = PLANT, volume = 0.4, sprint = false },
		blendSpeed = 4,
		look = OWN_LOOK,
		plantFeet = true,
		hands = 0,
	}),
	Patrol = state({
		pose = posed(patrol),
		cycle = cycleFor(STALK, 1.4),
		footsteps = { plants = PLANT, volume = 1, sprint = false },
		blendSpeed = 6,
		look = OWN_LOOK,
		plantFeet = true,
		hands = 0,
		exertion = 0.1,
	}),
	Investigate = state({
		pose = posed(investigate),
		cycle = cycleFor(CREEP, 1.3),
		footsteps = { plants = PLANT, volume = 0.8, sprint = false },
		blendSpeed = 6,
		look = OWN_LOOK,
		plantFeet = true,
		hands = 0,
		exertion = 0.25,
	}),
	Chase = state({
		pose = posed(chase),
		cycle = cycleFor(CHASE, 1.4),
		footsteps = { plants = PLANT, volume = 1.25, sprint = true },
		blendSpeed = 9,
		look = OWN_LOOK,
		plantFeet = true,
		hands = 0,
		exertion = 1,
	}),
	VentCrawl = state({
		pose = posed(ventCrawl),
		cycle = crawlCycle(VENT),
		footsteps = { plants = CRAWL_PLANT, volume = 0.55, sprint = false },
		blendSpeed = 14, -- the body folds into the duct fast (a slow blend drags upright legs through the walls)
		look = OWN_LOOK,
		hands = 0,
		exertion = 0.6,
	}),
	VentRetreat = state({
		pose = posed(ventRetreat),
		cycle = crawlCycle(RETREAT),
		footsteps = { plants = CRAWL_PLANT, volume = 0.65, sprint = false },
		blendSpeed = 14,
		look = OWN_LOOK,
		hands = 0,
		exertion = 1,
	}),
	Stunned = state({
		pose = posed(stunned),
		cycle = cycleFor(STAGGER, 1.6),
		footsteps = { plants = PLANT, volume = 0.9, sprint = false },
		blendSpeed = 10,
		look = OWN_LOOK,
		plantFeet = true,
		hands = 0,
		exertion = 1,
	}),
	Swim = state({
		pose = posed(swim),
		cycle = {
			length = function(_speed: number, _map: JointMap): number
				return 9
			end,
			rate = 0.35,
		},
		blendSpeed = 4,
		look = OWN_LOOK,
		hands = 0,
		exertion = 0.3,
	}),
	Scripted = state({
		pose = posed(scripted),
		cycle = cycleFor(NEUTRAL, 1.3),
		footsteps = { plants = PLANT, volume = 0.9, sprint = false },
		blendSpeed = 7,
		look = OWN_LOOK,
		plantFeet = true,
		hands = 0,
	}),
}

local profile: Profile = {
	name = "Creature",
	rootPart = "HumanoidRootPart",
	required = REQUIRED,
	limbs = {
		LeftArm = { upper = "LeftShoulder", lower = "LeftElbow", tip = "LeftWrist", bend = Vector3.new(0, 0, 1) },
		RightArm = { upper = "RightShoulder", lower = "RightElbow", tip = "RightWrist", bend = Vector3.new(0, 0, 1) },
		LeftLeg = { upper = "LeftHip", lower = "LeftKnee", tip = "LeftAnkle", bend = Vector3.new(0, 0, -1) },
		RightLeg = { upper = "RightHip", lower = "RightKnee", tip = "RightAnkle", bend = Vector3.new(0, 0, -1) },
	},
	hands = {},
	feet = {
		Left = { part = "LeftFoot", limb = "LeftLeg" },
		Right = { part = "RightFoot", limb = "RightLeg" },
		LeftHand = { part = "LeftHand", limb = "LeftArm" },
		RightHand = { part = "RightHand", limb = "RightArm" },
	},
	look = {
		waist = nil,
		neck = nil,
		waistPitch = 0,
		waistYaw = 0,
		pitchUp = NECK_LIMITS.pitchUp,
		pitchDown = NECK_LIMITS.pitchDown,
		yaw = NECK_LIMITS.yaw,
		roll = NECK_LIMITS.roll,
	},
	states = states,
	defaultState = "Dormant",
	blendSpeed = 7,
	lateralStride = 0.8,
}

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

local Creature = {}

Creature.Profile = profile
Creature.States = table.freeze(table.clone(STATE_NAMES))
Creature.Actions = table.freeze(table.clone(ACTION_NAMES))
Creature.ActionDurations = table.freeze(table.clone(DURATIONS))
Creature.BoreHalf = BORE_HALF
-- NeckSnap timing (seconds): the turn, the end of its settle, the hold after it, the release.
Creature.NeckSnapTiming = table.freeze({
	turn = SNAP_TURN,
	settle = SNAP_SETTLE,
	hold = SNAP_HOLD,
	release = SNAP_RELEASE,
})

function Creature.isState(name: unknown): boolean
	return type(name) == "string" and table.find(STATE_NAMES, name :: any) ~= nil
end

function Creature.isAction(name: unknown): boolean
	return type(name) == "string" and DURATIONS[name :: string] ~= nil
end

-- The profile state for the Creature's replicated attributes: its body shape (PoseMode, InVent) first, then the AI
-- state (Scripted + Hunched is the staged corner crouch, Dormant). Missing or unknown states pose Dormant.
function Creature.resolveState(monsterState: unknown, poseMode: unknown, inVent: unknown): StateName
	if poseMode == "Quadruped" or inVent == true then
		return if monsterState == "Stunned" then "VentRetreat" else "VentCrawl"
	end
	if poseMode == "Swim" then
		return if monsterState == "Stunned" then "Stunned" else "Swim"
	end
	if monsterState == "Patrol" or monsterState == "AquaticStalk" then
		return "Patrol"
	elseif monsterState == "InvestigateNoise" then
		return "Investigate"
	elseif monsterState == "WallChase" or monsterState == "VentChase" then
		return "Chase"
	elseif monsterState == "Stunned" then
		return "Stunned"
	elseif monsterState == "Scripted" then
		-- A cutscene that sets PoseMode Hunched stages the corner crouch (the Floor 1 classroom scare).
		return if poseMode == "Hunched" then "Dormant" else "Scripted"
	end
	return "Dormant"
end

-- How far the body ducks for a PoseMode (Hunched fits the 6-stud hitbox).
function Creature.hunchFor(poseMode: unknown): number
	return if poseMode == "Hunched" then 1 else 0
end

-- Starts `name` on the rig at animator clock `startAt` (nil: its next step). Playing an action again restarts it.
-- Returns false for unknown names and non-finite times.
function Creature.playAction(map: JointMap, name: string, startAt: number?): boolean
	if DURATIONS[name] == nil then
		return false
	end
	if startAt ~= nil and not MathUtil.isFinite(startAt) then
		return false
	end
	local runtime = runtimeOf(map)
	for index = #runtime.actions, 1, -1 do
		if runtime.actions[index].name == name then
			table.remove(runtime.actions, index)
		end
	end
	runtime.serial += 1
	table.insert(runtime.actions, {
		name = name :: ActionName,
		startAt = startAt,
		sign = 0,
		seed = runtime.serial * 97 + #name,
	})
	return true
end

-- Ends `name` (every action when nil) at once.
function Creature.stopAction(map: JointMap, name: string?)
	local runtime = runtimeOf(map)
	for index = #runtime.actions, 1, -1 do
		if name == nil or runtime.actions[index].name == name then
			table.remove(runtime.actions, index)
		end
	end
end

-- Names of the actions running (or waiting for their first step) on the rig.
function Creature.activeActions(map: JointMap): { string }
	local out: { string } = {}
	for _, run in runtimeOf(map).actions do
		table.insert(out, run.name)
	end
	return out
end

-- The clock time `name` is bound to on the rig (nil when it is not running or has not stepped yet).
function Creature.actionStart(map: JointMap, name: string): number?
	for _, run in runtimeOf(map).actions do
		if run.name == name then
			return run.startAt
		end
	end
	return nil
end

-- 0 upright .. 1 ducked under a 6-stud ceiling (eased toward over the rig's next steps).
function Creature.setHunch(map: JointMap, amount: number)
	if MathUtil.isFinite(amount) then
		runtimeOf(map).hunchTarget = clamp01(amount)
	end
end

-- Whether the look input is a real target (the head locks on and catches up in snaps) or just the facing (the head
-- scans by itself).
function Creature.setFocus(map: JointMap, focused: boolean)
	runtimeOf(map).focused = focused
end

-- Pure pieces (specs and tuning).
Creature.snapProgress = snapProgress
Creature.twitchAt = twitchAt

-- Rig measurements the profile works from (specs and tuning).
function Creature.measure(map: JointMap): { [string]: number }
	local m = measure(map)
	return {
		leg = m.leg,
		thigh = m.thigh,
		shin = m.shin,
		upperArm = m.upperArm,
		forearm = m.forearm,
		arm = m.arm,
		ankle = m.ankle,
		toe = m.toe,
		heel = m.heel,
		standHip = m.standHip,
		ground = m.ground,
		hairChains = #m.hair,
	}
end

return table.freeze(Creature)
