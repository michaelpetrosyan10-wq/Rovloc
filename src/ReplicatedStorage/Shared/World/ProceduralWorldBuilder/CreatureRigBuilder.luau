--!strict
-- CreatureRigBuilder: the Creature, built from Parts in code. An 8.5-stud, gaunt, pale humanoid: a narrow skull
-- under a heavy brow, hollow pitch-black sockets holding pinprick Neon pupils, sunken cheeks and temples, a lipless
-- ear-to-ear grin (gums bared, rows of uneven yellowed teeth, the side cuts running back toward the ears) on a
-- separate hinged Jaw, a too-long sinewy neck, a ribcage flaring over a sucked-in belly with every rib showing,
-- collarbones, jutting shoulder blades and spine knobs, bony hips, knees, ankles and knuckles, elongated arms ending in long curled fingers with 6-inch claws, and long
-- stringy black hair hanging in clumps that a later animator can sway. The rest pose stands with a slight hunch
-- (upper torso and neck pitched forward, chin down).
--
-- Rig-local space. Every piece is placed in the frame of the `cframe` handed to build(): its origin is the floor
-- point at the CreatureSpawn anchor, +Y is up, -Z (LookVector) is the facing and +X the Creature's right. The
-- HumanoidRootPart centre sits Rig.HipHeight + RootSize.Y / 2 above the floor; the pupils' midpoint sits exactly
-- EyeHeightAboveRoot.Biped above the root centre, under 0.8 studs ahead of it because the hunched face is
-- (PartNames.FaceAttachment marks it exactly, facing forward, for the jumpscare camera); the top of the hair cap is
-- Rig.Height above the floor; the soles, heels and toe tips rest on the floor.
--
-- Joints. One Motor6D per entry of CreatureRigBuilder.Joints (R15 names, plus "Jaw" and the hair chains
-- Head -> Hair<N>_1 -> Hair<N>_2, each Motor6D named after its Part1), parented to its Part1. Every joint frame
-- (Part0.CFrame * C0) sits at the pivot and is axis-aligned with the rig-local frame in the rest pose, so a
-- Motor6D.Transform means the same thing on every joint: rotations about X pitch, about Y yaw, about Z roll, all
-- relative to the Creature's own facing. CFrame.Angles(-a, 0, 0) on "Jaw" drops the jaw open by `a` radians;
-- a yaw on "Neck" / "Waist" turns the head / upper body about the vertical. All parts are placed explicitly so
-- Part1.CFrame == Part0.CFrame * C0 * C1:Inverse() at rest (identity Transform). Detail pieces (bones, teeth,
-- claws, eyes, hair strands within a clump, the neck) are children of the limb that carries them, held by a
-- WeldConstraint.
--
-- Physics (ARCHITECTURE §4a): nothing is anchored (the server owns the assembly). Only HumanoidRootPart has mass
-- and collides (CollisionGroup Monster); every limb and detail is Massless, non-colliding, never queried or
-- touched and in NoCollide (the Humanoid rewrites CanCollide on torso and head parts; the group keeps them out).
-- CreatureHitbox (Monster, CanQuery only) hangs off the root by the Weld "HitboxJoint"; setHitbox() resizes it
-- per PoseMode. This rig is the one place allowed to write CollisionGroup directly.
--
-- Hitbox layouts (root-relative): Biped and Hunched stand on the floor (the root at its rest height above it,
-- box bottom at the floor, Hunched shorter and pushed forward over the bent body); Quadruped and Swim carry the
-- body level with the root (the vent rail or the water line), so their low, long boxes are centred on it and run
-- forward along the facing, where the head and forelimbs lead.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Instances = require(ReplicatedStorage.Shared.Instances)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

local Geometry = require(script.Parent.Geometry)
local PropKit = require(script.Parent.Props.PropKit)

export type JointSpec = { name: string, part0: string, part1: string }

export type PartNameMap = {
	Root: string,
	LowerTorso: string,
	UpperTorso: string,
	Head: string,
	Jaw: string,
	LeftUpperArm: string,
	LeftLowerArm: string,
	LeftHand: string,
	RightUpperArm: string,
	RightLowerArm: string,
	RightHand: string,
	LeftUpperLeg: string,
	LeftLowerLeg: string,
	LeftFoot: string,
	RightUpperLeg: string,
	RightLowerLeg: string,
	RightFoot: string,
	LeftPupil: string,
	RightPupil: string,
	FaceAttachment: string, -- Attachment on Head at the pupils' midpoint, facing forward
	Hitbox: string,
	HitboxJoint: string, -- Weld under Hitbox (Part0 = root)
	Humanoid: string,
	Hair: { { string } }, -- per clump, root to tip
}

type Paint = {
	material: Enum.Material,
	color: Color3,
	shadow: boolean,
	transparency: number?,
}

type HairClump = {
	azimuth: number, -- degrees around the scalp: 0 = straight back, +90 = the Creature's right
	lengths: { number }, -- hanging segment lengths, root to tip
	splay: { number }, -- outward lean of each segment (horizontal run per stud of drop)
	width: number, -- of the first segment; each segment below is narrower
}

type FingerSpec = {
	name: string,
	offset: number, -- across the palm from the middle of the knuckle line (+ toward the pinky)
	inset: number, -- how far the knuckle sits back toward the wrist
	scale: number, -- length relative to the middle finger
	spread: number, -- fan angle across the palm, degrees
	curl: number, -- extra curl toward the palm, degrees
}

type ToeSpec = { x: number, length: number, width: number }

type Ctx = {
	model: Model,
	base: CFrame, -- rig-local -> world
	random: Random,
	parts: { [string]: BasePart }, -- jointed rig parts by name
	pivots: { [string]: Vector3 }, -- rig-local pivot of each joint, by joint name
}

local RIG = CreatureConfig.Rig
local RIG_KIND = "Creature"
local RIG_SEED = 8517 -- every build of the Creature is identical (its uneven teeth and hair included)
local BIPED: Enums.PoseMode = "Biped"
local PART_BUDGET = 220

local ROOT_HEIGHT = RIG.HipHeight + RIG.RootSize.Y / 2
local EYE_HEIGHT = ROOT_HEIGHT + CreatureConfig.EyeHeightAboveRoot.Biped

-- Posture (rig-local). The pelvis sits behind the root's centre so the body, heels to brow, is centred over the
-- root and the hunched-forward face stays just past the root's front face.
local PELVIS_Y = ROOT_HEIGHT - 0.48
local PELVIS_Z = 0.5
local PELVIS_DIAMETER = 0.74
local PELVIS_CENTRE = Vector3.new(0, -0.02, 0.04) -- relative to (0, PELVIS_Y, PELVIS_Z)
local HIP_Y = PELVIS_Y - 0.27
local KNEE_Y = HIP_Y * 0.537
local ANKLE_Y = 0.38
local WAIST = Vector3.new(0, PELVIS_Y + 0.4, PELVIS_Z + 0.02)
local TORSO_PITCH = math.rad(12) -- upper torso leans forward about the waist
local NECK_LEAN = math.rad(13) -- the neck leans forward again from its base
local HEAD_PITCH = math.rad(-6) -- chin tucked: the eyes look out from under the brow
local TOE_OUT = math.rad(8)

-- Torso-local (origin at the waist pivot, Y up the spine, -Z forward).
local TORSO_LENGTH = 1.78 -- waist to the neck base
local NECK_BASE = Vector3.new(0, TORSO_LENGTH, -0.06)
local SHOULDER = Vector3.new(0.74, 1.58, -0.06) -- mirrored in X
-- The ribcage: a flat-fronted core (UpperTorso, under the sternum and the spine) between two rounded flanks whose
-- axes lean out toward the bottom, so the cage flares over the sucked-in belly. Ribs are arcs set around each flank.
local RIBCAGE_BOTTOM = 0.62
local RIBCAGE_TOP = 1.74
local RIBCAGE_DEPTH = 0.74
local FLANK_TOP_X = 0.17
local FLANK_BOTTOM_X = 0.25
local RIB_COUNT = 5
local RIB_TOP = 1.52 -- torso-local height of the first rib arc's centre
local RIB_SPACING = 0.21
local RIB_OFFSET = 0.04 -- arc centres sit this far outside the flank axis: proud on the side, flush front and back
local RIB_TILT = math.rad(16) -- ribs drop toward the front
local RIB_FRONT_DEGREES = 22 -- where the cartilage leaves each arc

-- Head-local (origin at the pupils' midpoint, axes pitched by HEAD_PITCH, -Z forward).
local SKULL_BASE = Vector3.new(0, -0.28, 0.55) -- where the neck column enters the skull
local JAW_HINGE = Vector3.new(0, -0.36, 0.55)
local PUPIL_X = 0.18
local PUPIL_SIZE = 0.045
local SOCKET_X = 0.2
local SOCKET_SIZE = 0.3
-- The socket's surface passes through the pupil, so the pinprick sits in the very back of the hollow.
local SOCKET_Z = math.sqrt((SOCKET_SIZE / 2) ^ 2 - (SOCKET_X - PUPIL_X) ^ 2)
local DOME_RADIUS = 0.46
local DOME_Z = 0.45
local CAP_RADIUS = 0.49
local CAP_OFFSET = Vector3.new(0, 0.02, 0.07) -- the hair cap sits back on the dome, leaving a high bare forehead
-- Dome height that puts the top of the hair cap exactly Rig.Height above the floor in the rest pose.
local DOME_Y = (RIG.Height - EYE_HEIGHT - CAP_RADIUS + math.sin(HEAD_PITCH) * (DOME_Z + CAP_OFFSET.Z))
		/ math.cos(HEAD_PITCH)
	- CAP_OFFSET.Y
-- The mouth is built on a circular dental arch (mouth-local: origin at the centre of the arch between the gums,
-- Y up through it), tipped so its front sits lower than its sides: the grin turns up as it runs back toward the
-- ears.
local MOUTH_CENTRE = Vector3.new(0, -0.325, 0.2)
local MOUTH_TILT = math.rad(-12)
local UPPER_GUM_Y = 0.095
local LOWER_GUM_Y = -0.095
local GUM_HEIGHT = 0.062
local ARCH_RADIUS = 0.31 -- upper gum; the lower arch sits just inside it (overbite)

-- Arm proportions: shoulder -> elbow -> wrist -> knuckles -> middle fingertip adds up to Rig.ArmLength.
local UPPER_ARM = RIG.ArmLength * 0.38
local FOREARM = RIG.ArmLength * 0.36
local PALM = RIG.ArmLength * 0.11
local FINGER = RIG.ArmLength * 0.15
local PROXIMAL_SHARE = 0.58
local FINGER_CURL = { 13, 31, 52 } -- proximal, distal and claw angles toward the palm, degrees
local CLAW_WIDTH = 0.055
local CLAW_THICKNESS = 0.065
local CLAW_EMBED = 0.02

local HAIR_THICKNESS = 0.032
local HAIR_DROP = math.rad(15) -- the clumps leave the scalp this far above the cap's equator
local STRAND_WIDTH = 0.03
local STRAND_THICKNESS = 0.022
local TOOTH_THICKNESS = 0.034
local TOOTH_EMBED = 0.018
local ABDOMEN_DIAMETER = 0.64
local ABDOMEN_Z = 0.06 -- torso-local

local HITBOX_NAME = "CreatureHitbox"
local HITBOX_JOINT = "HitboxJoint"
local FACE_ATTACHMENT = "FaceFrontAttachment"

type HitboxLayout = { floor: boolean, forward: number }

local HITBOX_LAYOUTS: { [string]: HitboxLayout } = {
	Biped = { floor = true, forward = 0 },
	Hunched = { floor = true, forward = 0.6 },
	Quadruped = { floor = false, forward = 0.9 },
	Swim = { floor = false, forward = 0.8 },
}

local FINGERS: { FingerSpec } = {
	{ name = "Index", offset = -0.13, inset = 0.03, scale = 0.92, spread = -7, curl = 2 },
	{ name = "Middle", offset = -0.044, inset = 0, scale = 1, spread = -2, curl = 0 },
	{ name = "Ring", offset = 0.044, inset = 0.02, scale = 0.93, spread = 3, curl = 4 },
	{ name = "Pinky", offset = 0.13, inset = 0.06, scale = 0.75, spread = 9, curl = 7 },
}

-- x is foot-local and measured toward the outside of the foot (the big toe sits innermost).
local TOES: { ToeSpec } = {
	{ x = -0.1, length = 0.38, width = 0.095 },
	{ x = 0, length = 0.33, width = 0.08 },
	{ x = 0.095, length = 0.27, width = 0.07 },
}

local HAIR: { HairClump } = {
	{ azimuth = 0, lengths = { 1.05, 1.1 }, splay = { 0.24, 0.1 }, width = 0.09 },
	{ azimuth = 36, lengths = { 1, 1.05 }, splay = { 0.22, 0.1 }, width = 0.085 },
	{ azimuth = -36, lengths = { 1.02, 0.98 }, splay = { 0.22, 0.1 }, width = 0.085 },
	{ azimuth = 76, lengths = { 0.92, 0.95 }, splay = { 0.22, 0.08 }, width = 0.08 },
	{ azimuth = -76, lengths = { 0.94, 0.9 }, splay = { 0.22, 0.08 }, width = 0.08 },
	{ azimuth = 124, lengths = { 0.8, 0.82 }, splay = { 0.2, 0.04 }, width = 0.075 },
	{ azimuth = -124, lengths = { 0.78, 0.86 }, splay = { 0.2, 0.04 }, width = 0.075 },
}

--------------------------------------------------------------------------------
-- Paints
--------------------------------------------------------------------------------

local SHADOW_TONE = Color3.fromRGB(50, 52, 48)
local SALLOW_TONE = Color3.fromRGB(128, 130, 108)
local CLAW_STAIN = Color3.fromRGB(52, 40, 18)
local ROT_STAIN = Color3.fromRGB(70, 56, 32)
local GUM_RED = Color3.fromRGB(122, 40, 38)

local SMOOTH = Enum.Material.SmoothPlastic

local PAINT_SKIN: Paint = { material = SMOOTH, color = RIG.SkinColor, shadow = true }
local PAINT_SKIN_SMALL: Paint = { material = SMOOTH, color = RIG.SkinColor, shadow = false }
local PAINT_CORE: Paint = { material = SMOOTH, color = RIG.SkinColor:Lerp(SALLOW_TONE, 0.3), shadow = true }
local PAINT_HOLLOW: Paint = { material = SMOOTH, color = RIG.SkinColor:Lerp(SHADOW_TONE, 0.55), shadow = true }
local PAINT_BONE: Paint = { material = SMOOTH, color = RIG.SkinColor:Lerp(RIG.ToothColor, 0.55), shadow = true }
local PAINT_BONE_SMALL: Paint = { material = SMOOTH, color = PAINT_BONE.color, shadow = false }
local PAINT_HAIR: Paint = { material = SMOOTH, color = RIG.HairColor, shadow = true }
local PAINT_SCALP: Paint = { material = Enum.Material.Fabric, color = RIG.HairColor, shadow = true }
local PAINT_SOCKET: Paint = { material = Enum.Material.Fabric, color = RIG.EyeSocketColor, shadow = false }
local PAINT_PUPIL: Paint = { material = Enum.Material.Neon, color = RIG.PupilColor, shadow = false }
local PAINT_CAVITY: Paint = { material = Enum.Material.Fabric, color = RIG.GrinColor, shadow = false }
local PAINT_GUM: Paint = { material = SMOOTH, color = RIG.GrinColor:Lerp(GUM_RED, 0.35), shadow = false }
local PAINT_CLAW: Paint = { material = SMOOTH, color = RIG.ToothColor:Lerp(CLAW_STAIN, 0.6), shadow = true }
local PAINT_INVISIBLE: Paint = { material = SMOOTH, color = RIG.SkinColor, shadow = false, transparency = 1 }

--------------------------------------------------------------------------------
-- Contract tables
--------------------------------------------------------------------------------

local function sideName(side: number): string
	return if side > 0 then "Right" else "Left"
end

local function hairName(clump: number, segment: number): string
	return string.format("Hair%d_%d", clump, segment)
end

local jointList: { JointSpec } = {
	{ name = "Root", part0 = "HumanoidRootPart", part1 = "LowerTorso" },
	{ name = "Waist", part0 = "LowerTorso", part1 = "UpperTorso" },
	{ name = "Neck", part0 = "UpperTorso", part1 = "Head" },
	{ name = "Jaw", part0 = "Head", part1 = "Jaw" },
}
for _, side in { -1, 1 } do
	local prefix = sideName(side)
	table.insert(jointList, { name = prefix .. "Shoulder", part0 = "UpperTorso", part1 = prefix .. "UpperArm" })
	table.insert(jointList, { name = prefix .. "Elbow", part0 = prefix .. "UpperArm", part1 = prefix .. "LowerArm" })
	table.insert(jointList, { name = prefix .. "Wrist", part0 = prefix .. "LowerArm", part1 = prefix .. "Hand" })
end
for _, side in { -1, 1 } do
	local prefix = sideName(side)
	table.insert(jointList, { name = prefix .. "Hip", part0 = "LowerTorso", part1 = prefix .. "UpperLeg" })
	table.insert(jointList, { name = prefix .. "Knee", part0 = prefix .. "UpperLeg", part1 = prefix .. "LowerLeg" })
	table.insert(jointList, { name = prefix .. "Ankle", part0 = prefix .. "LowerLeg", part1 = prefix .. "Foot" })
end
local hairNames: { { string } } = {}
for index, clump in HAIR do
	local chain: { string } = {}
	for segment = 1, #clump.lengths do
		local name = hairName(index, segment)
		local parent = if segment == 1 then "Head" else hairName(index, segment - 1)
		table.insert(jointList, { name = name, part0 = parent, part1 = name })
		table.insert(chain, name)
	end
	table.insert(hairNames, table.freeze(chain))
end
for _, spec in jointList do
	table.freeze(spec)
end
table.freeze(jointList)
table.freeze(hairNames)

local partNames: PartNameMap = {
	Root = "HumanoidRootPart",
	LowerTorso = "LowerTorso",
	UpperTorso = "UpperTorso",
	Head = "Head",
	Jaw = "Jaw",
	LeftUpperArm = "LeftUpperArm",
	LeftLowerArm = "LeftLowerArm",
	LeftHand = "LeftHand",
	RightUpperArm = "RightUpperArm",
	RightLowerArm = "RightLowerArm",
	RightHand = "RightHand",
	LeftUpperLeg = "LeftUpperLeg",
	LeftLowerLeg = "LeftLowerLeg",
	LeftFoot = "LeftFoot",
	RightUpperLeg = "RightUpperLeg",
	RightLowerLeg = "RightLowerLeg",
	RightFoot = "RightFoot",
	LeftPupil = "LeftPupil",
	RightPupil = "RightPupil",
	FaceAttachment = FACE_ATTACHMENT,
	Hitbox = HITBOX_NAME,
	HitboxJoint = HITBOX_JOINT,
	Humanoid = "Humanoid",
	Hair = hairNames,
}
table.freeze(partNames)

local CreatureRigBuilder = {}

-- Ordered parent-before-child: walking it in order composes every rest frame from the root outward.
CreatureRigBuilder.Joints = jointList
CreatureRigBuilder.PartNames = partNames
CreatureRigBuilder.PartBudget = PART_BUDGET

--------------------------------------------------------------------------------
-- Frames
--------------------------------------------------------------------------------

local function orthogonal(v: Vector3, axis: Vector3): Vector3
	return (v - axis * v:Dot(axis)).Unit
end

-- Frame at `position` whose Y axis is exactly `yAxis` and whose Z axis leans toward `zHint`.
local function frameY(position: Vector3, yAxis: Vector3, zHint: Vector3): CFrame
	local y = yAxis.Unit
	local z = orthogonal(zHint, y)
	return CFrame.fromMatrix(position, y:Cross(z), y, z)
end

-- Frame at `position` whose Z axis is exactly `zAxis` and whose Y axis leans toward `yHint`.
local function frameZ(position: Vector3, zAxis: Vector3, yHint: Vector3): CFrame
	local z = zAxis.Unit
	local y = orthogonal(yHint, z)
	return CFrame.fromMatrix(position, y:Cross(z), y, z)
end

-- Frame at the midpoint of a -> b whose X axis runs from a to b (Part.Shape Cylinder runs along local X).
local function alongX(a: Vector3, b: Vector3): CFrame
	local axis = (b - a).Unit
	local hint = if math.abs(axis.Y) > 0.9 then Vector3.zAxis else Vector3.yAxis
	local y = orthogonal(hint, axis)
	return CFrame.fromMatrix((a + b) / 2, axis, y, axis:Cross(y))
end

-- Torso-local X of a ribcage flank's axis at torso-local height `y` (it leans out toward the bottom).
local function flankAxisX(y: number): number
	local t = (y - RIBCAGE_BOTTOM) / (RIBCAGE_TOP - RIBCAGE_BOTTOM)
	return FLANK_BOTTOM_X + (FLANK_TOP_X - FLANK_BOTTOM_X) * t
end

local function rotate(frame: CFrame, v: Vector3): Vector3
	return frame:VectorToWorldSpace(v)
end

--------------------------------------------------------------------------------
-- Part factory (rig-local CFrames; Geometry anchors every part, finalize() frees them once jointed)
--------------------------------------------------------------------------------

local function options(paint: Paint, shape: Enum.PartType?): Geometry.PartOptions
	return {
		shape = shape,
		material = paint.material,
		color = paint.color,
		castShadow = paint.shadow,
		transparency = paint.transparency,
	}
end

local function rigPart(
	ctx: Ctx,
	name: string,
	cframe: CFrame,
	size: Vector3,
	paint: Paint,
	shape: Enum.PartType?
): BasePart
	local part = Geometry.part(ctx.model, name, ctx.base * cframe, size, nil, options(paint, shape))
	ctx.parts[name] = part
	return part
end

local function rigRod(ctx: Ctx, name: string, a: Vector3, b: Vector3, diameter: number, paint: Paint): BasePart
	return rigPart(
		ctx,
		name,
		alongX(a, b),
		Vector3.new((b - a).Magnitude, diameter, diameter),
		paint,
		Enum.PartType.Cylinder
	)
end

local function weldTo(limb: BasePart, piece: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Name = "Weld"
	weld.Part0 = limb
	weld.Part1 = piece
	weld.Parent = piece
end

local function block(
	ctx: Ctx,
	limb: BasePart,
	name: string,
	cframe: CFrame,
	size: Vector3,
	paint: Paint,
	shape: Enum.PartType?
): BasePart
	local part = Geometry.part(limb, name, ctx.base * cframe, size, nil, options(paint, shape))
	weldTo(limb, part)
	return part
end

local function wedge(ctx: Ctx, limb: BasePart, name: string, cframe: CFrame, size: Vector3, paint: Paint): BasePart
	local part = Geometry.wedge(limb, name, ctx.base * cframe, size, nil, options(paint))
	weldTo(limb, part)
	return part
end

local function ball(ctx: Ctx, limb: BasePart, name: string, centre: Vector3, diameter: number, paint: Paint): BasePart
	return block(ctx, limb, name, CFrame.new(centre), Vector3.one * diameter, paint, Enum.PartType.Ball)
end

local function rod(
	ctx: Ctx,
	limb: BasePart,
	name: string,
	a: Vector3,
	b: Vector3,
	diameter: number,
	paint: Paint
): BasePart
	return block(
		ctx,
		limb,
		name,
		alongX(a, b),
		Vector3.new((b - a).Magnitude, diameter, diameter),
		paint,
		Enum.PartType.Cylinder
	)
end

-- A block running from a to b (its Z axis), `width` across (X) and `height` toward `up` (Y).
local function strip(
	ctx: Ctx,
	limb: BasePart,
	name: string,
	a: Vector3,
	b: Vector3,
	up: Vector3,
	width: number,
	height: number,
	paint: Paint
): BasePart
	return block(ctx, limb, name, frameZ((a + b) / 2, b - a, up), Vector3.new(width, height, (b - a).Magnitude), paint)
end

-- A flat cylinder whose axis is `frame`'s Y axis.
local function disc(
	ctx: Ctx,
	limb: BasePart,
	name: string,
	frame: CFrame,
	height: number,
	diameter: number,
	paint: Paint
): BasePart
	return rod(
		ctx,
		limb,
		name,
		frame * Vector3.new(0, -height / 2, 0),
		frame * Vector3.new(0, height / 2, 0),
		diameter,
		paint
	)
end

--------------------------------------------------------------------------------
-- Root, pelvis and torso
--------------------------------------------------------------------------------

local function buildRoot(ctx: Ctx)
	rigPart(ctx, "HumanoidRootPart", CFrame.new(0, ROOT_HEIGHT, 0), RIG.RootSize, PAINT_INVISIBLE)
end

local function buildPelvis(ctx: Ctx)
	-- The girdle: a rounded bowl slung between the hip joints, the iliac crests jutting from its upper front
	-- corners beside the sunken belly and the sacrum's knobs running down its back.
	local radius = PELVIS_DIAMETER / 2
	local centre = Vector3.new(0, PELVIS_Y + PELVIS_CENTRE.Y, PELVIS_Z + PELVIS_CENTRE.Z)
	local pelvis =
		rigPart(ctx, "LowerTorso", CFrame.new(centre), Vector3.one * PELVIS_DIAMETER, PAINT_CORE, Enum.PartType.Ball)
	ctx.pivots.Root = Vector3.new(0, PELVIS_Y, PELVIS_Z)
	for _, side in { -1, 1 } do
		local crest = Vector3.new(side * 0.64, 0.5, -0.58).Unit * (radius + 0.015)
		ball(ctx, pelvis, sideName(side) .. "HipBone", centre + crest, 0.2, PAINT_BONE)
	end
	for i, degrees in { 34, 8 } do
		local angle = math.rad(degrees)
		local surface = centre + Vector3.new(0, math.sin(angle), math.cos(angle)) * (radius + 0.01)
		ball(ctx, pelvis, string.format("Sacrum%d", i), surface, 0.12 - i * 0.01, PAINT_BONE_SMALL)
	end
end

-- Torso-local centre of the rib arc `rib` on `side`: on the flank axis at that height, nudged outward.
local function ribFrame(side: number, rib: number): CFrame
	local y = RIB_TOP - (rib - 1) * RIB_SPACING
	return CFrame.new(side * (flankAxisX(y) + RIB_OFFSET), y, 0) * CFrame.Angles(-RIB_TILT, 0, 0)
end

-- Torso-local point on the rim of a rib arc, `degrees` around it from straight ahead toward its own side, lifted
-- `lift` off the rim.
local function ribPoint(side: number, rib: number, degrees: number, lift: number): Vector3
	local angle = math.rad(degrees)
	local radius = RIBCAGE_DEPTH / 2 + lift
	return ribFrame(side, rib) * Vector3.new(side * radius * math.sin(angle), 0, -radius * math.cos(angle))
end

-- Builds the ribcage and abdomen; returns the torso frame (origin at the waist pivot, pitched forward).
local function buildTorso(ctx: Ctx): CFrame
	local torso = CFrame.new(WAIST) * CFrame.Angles(-TORSO_PITCH, 0, 0)
	local centreY = (RIBCAGE_BOTTOM + RIBCAGE_TOP) / 2
	local coreSize = Vector3.new((FLANK_TOP_X + FLANK_BOTTOM_X), RIBCAGE_TOP - RIBCAGE_BOTTOM, RIBCAGE_DEPTH)
	local chest = rigPart(ctx, "UpperTorso", torso * CFrame.new(0, centreY, 0), coreSize, PAINT_CORE)
	ctx.pivots.Waist = WAIST

	local front = -RIBCAGE_DEPTH / 2
	local back = RIBCAGE_DEPTH / 2
	local function at(x: number, y: number, z: number): Vector3
		return torso * Vector3.new(x, y, z)
	end

	-- The waist is a narrow column and the belly is sucked in well behind the front of the ribs.
	rod(ctx, chest, "Abdomen", at(0, -0.36, ABDOMEN_Z), at(0, 0.7, ABDOMEN_Z), ABDOMEN_DIAMETER, PAINT_CORE)
	block(ctx, chest, "Sternum", torso * CFrame.new(0, 1.3, front - 0.01), Vector3.new(0.11, 0.82, 0.06), PAINT_BONE)

	for _, side in { -1, 1 } do
		local prefix = sideName(side)
		-- the rounded flank of the cage, leaning out toward the bottom so the ribs flare over the belly
		rod(
			ctx,
			chest,
			prefix .. "Flank",
			at(side * FLANK_BOTTOM_X, RIBCAGE_BOTTOM, 0),
			at(side * FLANK_TOP_X, RIBCAGE_TOP, 0),
			RIBCAGE_DEPTH,
			PAINT_CORE
		)
		for rib = 1, RIB_COUNT do
			local name = string.format("%sRib%d", prefix, rib)
			-- the rib itself: an arc around the flank, sloping down toward the front, standing proud of the skin
			-- on the side and sinking into it toward the spine and the chest
			local thickness = 0.062 - rib * 0.004
			disc(ctx, chest, name, torso * ribFrame(side, rib), thickness, RIBCAGE_DEPTH, PAINT_BONE)
			if rib < RIB_COUNT then
				-- its cartilage, rising from the front of the arc to the sternum
				local sternal = Vector3.new(side * 0.07, RIB_TOP - (rib - 1) * RIB_SPACING + 0.03, front - 0.012)
				rod(
					ctx,
					chest,
					name .. "Cartilage",
					torso * sternal,
					torso * ribPoint(side, rib, RIB_FRONT_DEGREES, 0.012),
					thickness,
					PAINT_BONE
				)
			end
		end
		-- the lower edge of the cage: an inverted V from under the sternum out to the last rib, overhanging the
		-- hollow belly
		rod(
			ctx,
			chest,
			prefix .. "CostalMargin",
			at(side * 0.05, 0.88, front - 0.012),
			torso * ribPoint(side, RIB_COUNT, RIB_FRONT_DEGREES, 0.014),
			0.075,
			PAINT_BONE
		)
		rod(
			ctx,
			chest,
			prefix .. "Collarbone",
			at(side * 0.08, 1.7, front + 0.01),
			at(side * 0.7, 1.66, -0.1),
			0.09,
			PAINT_BONE
		)
		-- trapezius: slopes from the neck down to the bony shoulder (full height toward the neck)
		wedge(
			ctx,
			chest,
			prefix .. "Trapezius",
			torso * frameY(Vector3.new(side * 0.35, 1.89, 0.04), Vector3.yAxis, Vector3.new(-side, 0, 0)),
			Vector3.new(0.46, 0.3, 0.5),
			PAINT_SKIN
		)
		-- the shoulder blade: its inner border juts out beside the spine and it slopes flat toward the armpit
		local blade = torso * CFrame.new(side * 0.3, 1.3, back + 0.02) * CFrame.Angles(0, side * math.rad(16), 0)
		wedge(
			ctx,
			chest,
			prefix .. "ShoulderBlade",
			frameZ(blade.Position, rotate(blade, Vector3.new(-side, 0, 0)), rotate(blade, Vector3.zAxis))
				* CFrame.Angles(0, 0, side * math.rad(8)),
			Vector3.new(0.52, 0.1, 0.34),
			PAINT_SKIN
		)
	end

	local knobs: { { number } } =
		{ { 1.66, 0.11 }, { 1.42, 0.11 }, { 1.18, 0.11 }, { 0.94, 0.115 }, { 0.66, 0.12 }, { 0.38, 0.125 } }
	for i, knob in knobs do
		local surface = if knob[1] >= RIBCAGE_BOTTOM then back else ABDOMEN_Z + ABDOMEN_DIAMETER / 2
		ball(ctx, chest, string.format("Spine%d", i), at(0, knob[1], surface + 0.012), knob[2], PAINT_BONE_SMALL)
	end
	return torso
end

--------------------------------------------------------------------------------
-- Head, face, jaw and neck
--------------------------------------------------------------------------------

-- The head frame (origin at the pupils' midpoint) for a neck rising from `neckBase`: the neck leans forward by
-- NECK_LEAN and is exactly long enough to put the eyes at EYE_HEIGHT.
local function headFrame(neckBase: Vector3): (CFrame, Vector3)
	local tilt = CFrame.Angles(HEAD_PITCH, 0, 0)
	local skullBase = tilt * SKULL_BASE
	local rise = EYE_HEIGHT + skullBase.Y - neckBase.Y
	local length = rise / math.cos(NECK_LEAN)
	local top = neckBase + Vector3.new(0, rise, -math.sin(NECK_LEAN) * length)
	return CFrame.new(top - skullBase) * tilt, top
end

local function toothPaint(random: Random): Paint
	local stain = random:NextNumber(0, 0.45)
	local color = RIG.ToothColor:Lerp(PAINT_CLAW.color, stain)
	if random:NextNumber() < 0.12 then
		color = color:Lerp(ROT_STAIN, 0.55)
	end
	return { material = SMOOTH, color = color, shadow = false }
end

-- One tooth leaving the gum at `root` and growing along `grow`, set in a row running along `along` on a gum
-- facing `facing` (all rig-local). Fangs are sawtooth wedges, the rest worn pegs; each leans a little.
local function tooth(
	ctx: Ctx,
	limb: BasePart,
	name: string,
	root: Vector3,
	grow: Vector3,
	along: Vector3,
	facing: Vector3,
	length: number,
	width: number,
	fang: boolean
)
	local lean = math.rad(ctx.random:NextNumber(-10, 10))
	local direction = (grow * math.cos(lean) + along * math.sin(lean)).Unit
	local centre = root + direction * (length / 2 - TOOTH_EMBED)
	local paint = toothPaint(ctx.random)
	if fang then
		local slant = if ctx.random:NextNumber() < 0.5 then -1 else 1
		wedge(
			ctx,
			limb,
			name,
			frameZ(centre, -direction, along * slant),
			Vector3.new(TOOTH_THICKNESS, width, length),
			paint
		)
	else
		block(ctx, limb, name, frameY(centre, direction, facing), Vector3.new(width, length, TOOTH_THICKNESS), paint)
	end
end

type ArchRow = {
	prefix: string,
	count: number,
	from: number, -- arch angles of the first and last tooth, degrees (0 = front, +90 = the Creature's right)
	to: number,
	radius: number, -- mouth-local distance of each tooth's centre from the arch's axis
	rootY: number, -- mouth-local height the teeth leave the gum at
	grow: number, -- -1 hangs (upper row), +1 stands (lower row)
	lengths: { number }, -- min, max
	widths: { number },
	fangChance: number,
}

-- A row of uneven teeth set around the dental arch, each facing out of the grin.
local function archRow(ctx: Ctx, limb: BasePart, mouth: CFrame, row: ArchRow)
	local grow = rotate(mouth, Vector3.new(0, row.grow, 0))
	for i = 1, row.count do
		local t = (i - 0.5) / row.count + ctx.random:NextNumber(-0.15, 0.15) / row.count
		local theta = math.rad(row.from + (row.to - row.from) * t)
		local facing = Vector3.new(math.sin(theta), 0, -math.cos(theta))
		local along = Vector3.new(math.cos(theta), 0, math.sin(theta))
		local root = mouth * (facing * row.radius + Vector3.new(0, row.rootY, 0))
		local length = ctx.random:NextNumber(row.lengths[1], row.lengths[2])
		local width = ctx.random:NextNumber(row.widths[1], row.widths[2])
		local fang = ctx.random:NextNumber() < row.fangChance
		local name = string.format("%s%d", row.prefix, i)
		tooth(ctx, limb, name, root, grow, rotate(mouth, along), rotate(mouth, facing), length, width, fang)
	end
end

-- Builds the skull, face and upper teeth on Head, and the neck welded to it. Returns the head frame.
local function buildHead(ctx: Ctx, torso: CFrame): CFrame
	local neckBase = torso * NECK_BASE
	local head, skullTop = headFrame(neckBase)
	local function at(x: number, y: number, z: number): Vector3
		return head * Vector3.new(x, y, z)
	end
	local function frame(x: number, y: number, z: number): CFrame
		return head * CFrame.new(x, y, z)
	end
	ctx.pivots.Neck = neckBase

	-- The skull's core is the hollow-toned mass under the cranium and behind the facial bones: it is what shows
	-- as sunken cheeks between the cheekbones and the grin.
	local skull = rigPart(
		ctx,
		"Head",
		alongX(at(0, -0.05, 0.1), at(0, -0.05, 0.74)),
		Vector3.new(0.64, 0.56, 0.56),
		PAINT_HOLLOW,
		Enum.PartType.Cylinder
	)
	local face = Instance.new("Attachment")
	face.Name = FACE_ATTACHMENT
	face.CFrame = skull.CFrame:ToObjectSpace(ctx.base * head)
	face.Parent = skull

	ball(ctx, skull, "Cranium", at(0, DOME_Y, DOME_Z), DOME_RADIUS * 2, PAINT_SKIN)
	block(ctx, skull, "NasalBridge", frame(0, -0.01, -0.035), Vector3.new(0.11, 0.22, 0.17), PAINT_BONE)
	disc(ctx, skull, "Maxilla", frame(0, -0.185, 0.2), 0.17, 0.5, PAINT_SKIN)
	for _, side in { -1, 1 } do
		local prefix = sideName(side)
		-- a heavy brow ridge, the two halves crossing low over the nose in a frown and sweeping up and back into
		-- the temples
		rod(ctx, skull, prefix .. "Brow", at(-side * 0.05, 0.1, -0.1), at(side * 0.43, 0.18, 0.24), 0.1, PAINT_BONE)
		-- the cheekbone leaves the upper jaw under the socket and runs back toward the ear; a knob of bone closes
		-- the outer corner of the orbit
		rod(
			ctx,
			skull,
			prefix .. "Cheekbone",
			at(side * 0.05, -0.15, -0.02),
			at(side * 0.42, -0.1, 0.27),
			0.1,
			PAINT_BONE
		)
		ball(ctx, skull, prefix .. "OrbitRim", at(side * 0.34, -0.01, 0.1), 0.13, PAINT_BONE)
		-- the nose is gone: two slits of the nasal cavity in an inverted V
		block(
			ctx,
			skull,
			prefix .. "Nostril",
			frame(side * 0.036, -0.165, -0.05) * CFrame.Angles(0, 0, side * math.rad(20)),
			Vector3.new(0.035, 0.1, 0.05),
			PAINT_CAVITY
		)
		-- hollow sockets: a matte black void behind the brow, cheekbone and orbit rim, a pinprick at the back
		ball(ctx, skull, prefix .. "EyeSocket", at(side * SOCKET_X, 0, SOCKET_Z), SOCKET_SIZE, PAINT_SOCKET)
		ball(ctx, skull, prefix .. "Pupil", at(side * PUPIL_X, 0, 0), PUPIL_SIZE, PAINT_PUPIL)
	end

	-- Upper half of the grin: bared gums around the whole arch, the dark mouth behind the teeth, and the upper
	-- teeth hanging over the lower row all the way back toward the ears.
	local mouth = head * CFrame.new(MOUTH_CENTRE) * CFrame.Angles(MOUTH_TILT, 0, 0)
	disc(ctx, skull, "UpperGum", mouth * CFrame.new(0, UPPER_GUM_Y, 0), GUM_HEIGHT, ARCH_RADIUS * 2, PAINT_GUM)
	disc(
		ctx,
		skull,
		"MouthCavity",
		mouth,
		UPPER_GUM_Y - LOWER_GUM_Y - GUM_HEIGHT + 0.006,
		ARCH_RADIUS * 2 - 0.06,
		PAINT_CAVITY
	)
	archRow(ctx, skull, mouth, {
		prefix = "UpperTooth",
		count = 12,
		from = -112,
		to = 112,
		radius = ARCH_RADIUS - 0.01,
		rootY = UPPER_GUM_Y - GUM_HEIGHT / 2,
		grow = -1,
		lengths = { 0.08, 0.125 },
		widths = { 0.048, 0.068 },
		fangChance = 0.35,
	})

	-- The neck: a long sinewy column with the windpipe and two straining tendons.
	local axis = (skullTop - neckBase).Unit
	rod(ctx, skull, "NeckColumn", neckBase - axis * 0.22, skullTop + axis * 0.08, 0.4, PAINT_CORE)
	rod(ctx, skull, "Windpipe", torso * Vector3.new(0, 1.76, -0.3), at(0, -0.6, 0.42), 0.11, PAINT_SKIN)
	for _, side in { -1, 1 } do
		rod(
			ctx,
			skull,
			sideName(side) .. "NeckTendon",
			at(side * 0.22, -0.32, 0.62),
			torso * Vector3.new(side * 0.07, 1.74, -0.33),
			0.1,
			PAINT_SKIN
		)
	end
	return head
end

-- The lower jaw on its hinge: a narrow mandible tapering to a pointed chin, bared lower gums and teeth.
local function buildJaw(ctx: Ctx, head: CFrame)
	local mouth = head * CFrame.new(MOUTH_CENTRE) * CFrame.Angles(MOUTH_TILT, 0, 0)
	-- the jaw's body sits narrow and recessed under the gum; the mandibles and the chin give the lower face its V
	local jaw = rigPart(ctx, "Jaw", head * CFrame.new(0, -0.53, 0.27), Vector3.new(0.3, 0.12, 0.48), PAINT_SKIN)
	ctx.pivots.Jaw = head * JAW_HINGE

	disc(ctx, jaw, "LowerGum", mouth * CFrame.new(0, LOWER_GUM_Y, 0), GUM_HEIGHT, ARCH_RADIUS * 2 - 0.04, PAINT_GUM)
	disc(
		ctx,
		jaw,
		"Tongue",
		mouth * CFrame.new(0, LOWER_GUM_Y + GUM_HEIGHT / 2, 0.02),
		0.012,
		ARCH_RADIUS * 2 - 0.16,
		PAINT_CAVITY
	)
	local up = rotate(head, Vector3.yAxis)
	local down = -up
	for _, side in { -1, 1 } do
		local prefix = sideName(side)
		-- half of a pointed chin: full height on the centre line, tapering out along the jaw
		local inward = rotate(head, Vector3.new(-side, 0, 0))
		wedge(
			ctx,
			jaw,
			prefix .. "Chin",
			frameZ(head * Vector3.new(side * 0.07, -0.585, -0.02), inward, down),
			Vector3.new(0.12, 0.17, 0.14),
			PAINT_BONE
		)
		local chin = head * Vector3.new(side * 0.1, -0.56, 0)
		local angle = head * Vector3.new(side * 0.28, -0.46, 0.52)
		strip(ctx, jaw, prefix .. "Mandible", chin, angle, up, 0.06, 0.14, PAINT_SKIN)
	end
	archRow(ctx, jaw, mouth, {
		prefix = "LowerTooth",
		count = 10,
		from = -100,
		to = 100,
		radius = ARCH_RADIUS - 0.028,
		rootY = LOWER_GUM_Y + GUM_HEIGHT / 2,
		grow = 1,
		lengths = { 0.065, 0.1 },
		widths = { 0.042, 0.058 },
		fangChance = 0.3,
	})
end

-- Long stringy black hair: a cap over the crown and the back of the skull, and clumps hanging from it, each a
-- chain of thin segments jointed to the Head for a later sway, with two stray strands peeling off every segment.
local function buildHair(ctx: Ctx, head: CFrame)
	local skull = ctx.parts.Head
	local capCentre = Vector3.new(0, DOME_Y, DOME_Z) + CAP_OFFSET
	local capWorld = head * capCentre
	ball(ctx, skull, "Scalp", capWorld, CAP_RADIUS * 2, PAINT_SCALP)

	for index, clump in HAIR do
		local azimuth = math.rad(clump.azimuth)
		local outward = Vector3.new(math.sin(azimuth), 0, math.cos(azimuth))
		local horizontal = math.cos(HAIR_DROP) * CAP_RADIUS
		local drop = Vector3.new(
			math.sin(azimuth) * horizontal,
			math.sin(HAIR_DROP) * CAP_RADIUS,
			math.cos(azimuth) * horizontal
		)
		local pivot = head * (capCentre + drop * (1 + HAIR_THICKNESS / CAP_RADIUS))
		local width = clump.width
		for segment, length in clump.lengths do
			local name = hairName(index, segment)
			local jitter = Vector3.new(ctx.random:NextNumber(-0.05, 0.05), 0, ctx.random:NextNumber(-0.05, 0.05))
			local direction = (Vector3.new(0, -1, 0) + outward * clump.splay[segment] + jitter).Unit
			local tip = pivot + direction * length
			local hang = rigPart(
				ctx,
				name,
				frameY((pivot + tip) / 2, -direction, outward),
				Vector3.new(width, length, HAIR_THICKNESS),
				PAINT_HAIR
			)
			ctx.pivots[name] = pivot

			-- stray strands peeling off both edges of the clump, lankier and longer than it
			local tangent = direction:Cross(outward).Unit
			for _, edge in { -1, 1 } do
				local strandLength = length * ctx.random:NextNumber(0.9, 1.25)
				local strandDirection = (
					direction
					+ tangent * edge * ctx.random:NextNumber(0.02, 0.1)
					+ outward * ctx.random:NextNumber(-0.02, 0.06)
				).Unit
				local start = pivot + tangent * edge * (width / 2 + ctx.random:NextNumber(0.01, 0.035))
				local suffix = if edge < 0 then "StrandA" else "StrandB"
				block(
					ctx,
					hang,
					name .. suffix,
					frameY(start + strandDirection * (strandLength / 2), -strandDirection, outward),
					Vector3.new(STRAND_WIDTH, strandLength, STRAND_THICKNESS),
					PAINT_HAIR
				)
			end

			pivot = tip
			width *= 0.7
		end
	end
end

--------------------------------------------------------------------------------
-- Limbs
--------------------------------------------------------------------------------

local function claw(ctx: Ctx, hand: BasePart, name: string, tip: Vector3, direction: Vector3, dorsal: Vector3)
	-- a blade with its flat face toward the palm, tapering from the finger to a point that hooks inward
	local centre = tip + direction * (RIG.ClawLength / 2 - CLAW_EMBED)
	wedge(
		ctx,
		hand,
		name,
		frameZ(centre, -direction, dorsal),
		Vector3.new(CLAW_WIDTH, CLAW_THICKNESS, RIG.ClawLength),
		PAINT_CLAW
	)
end

local function buildArm(ctx: Ctx, torso: CFrame, side: number)
	local prefix = sideName(side)
	local outward = Vector3.new(side, 0, 0)
	local shoulder = torso * Vector3.new(side * SHOULDER.X, SHOULDER.Y, SHOULDER.Z)
	local upperDir = Vector3.new(side * 0.09, -1, -0.03).Unit
	local elbow = shoulder + upperDir * UPPER_ARM
	local foreDir = Vector3.new(side * 0.025, -1, -0.21).Unit
	local wrist = elbow + foreDir * FOREARM
	local handDir = Vector3.new(-side * 0.04, -1, -0.12).Unit
	local knuckles = wrist + handDir * PALM
	ctx.pivots[prefix .. "Shoulder"] = shoulder
	ctx.pivots[prefix .. "Elbow"] = elbow
	ctx.pivots[prefix .. "Wrist"] = wrist

	local upper = rigRod(ctx, prefix .. "UpperArm", shoulder - upperDir * 0.08, elbow, 0.3, PAINT_SKIN)
	ball(ctx, upper, prefix .. "ShoulderKnob", shoulder + Vector3.new(0, 0.03, 0), 0.36, PAINT_SKIN)

	local lower = rigRod(ctx, prefix .. "LowerArm", elbow, wrist + foreDir * 0.04, 0.24, PAINT_SKIN)
	local foreBack = orthogonal(Vector3.zAxis, foreDir)
	local foreOut = orthogonal(outward, foreDir)
	ball(ctx, lower, prefix .. "ElbowKnob", elbow + foreBack * 0.07, 0.26, PAINT_BONE)
	rod(
		ctx,
		lower,
		prefix .. "ForearmRidge",
		elbow - foreBack * 0.075 + foreDir * 0.25,
		wrist - foreBack * 0.06 - foreDir * 0.12,
		0.1,
		PAINT_SKIN
	)
	ball(
		ctx,
		lower,
		prefix .. "WristKnob",
		wrist - foreDir * 0.06 + foreOut * 0.08 + foreBack * 0.03,
		0.13,
		PAINT_BONE_SMALL
	)

	-- The palm faces the thigh; `across` runs over the knuckles from the index (front) to the pinky (back).
	local inward = orthogonal(-outward, handDir)
	local dorsal = -inward
	local across = orthogonal(orthogonal(Vector3.zAxis, handDir), inward)
	local hand = rigPart(
		ctx,
		prefix .. "Hand",
		frameY(wrist + handDir * (PALM / 2), -handDir, across),
		Vector3.new(0.12, PALM, 0.34),
		PAINT_SKIN
	)

	for _, finger in FINGERS do
		local name = prefix .. finger.name
		local length = FINGER * finger.scale
		local base = knuckles - handDir * finger.inset + across * finger.offset
		local fan = across * math.tan(math.rad(finger.spread))
		local function bend(degrees: number): Vector3
			local angle = math.rad(degrees + finger.curl)
			return (handDir * math.cos(angle) + inward * math.sin(angle) + fan).Unit
		end
		local proximal, distal = bend(FINGER_CURL[1]), bend(FINGER_CURL[2])
		local joint = base + proximal * (length * PROXIMAL_SHARE)
		local tip = joint + distal * (length * (1 - PROXIMAL_SHARE))
		rod(ctx, hand, name .. "Proximal", base - proximal * 0.03, joint, 0.075, PAINT_SKIN_SMALL)
		rod(ctx, hand, name .. "Distal", joint, tip, 0.062, PAINT_SKIN_SMALL)
		ball(ctx, hand, name .. "Knuckle", base + dorsal * 0.035, 0.1, PAINT_BONE_SMALL)
		claw(ctx, hand, name .. "Claw", tip, bend(FINGER_CURL[3]), dorsal)
	end

	local thumbBase = wrist + handDir * (PALM * 0.3) - across * 0.15 + inward * 0.04
	local thumbDir = (handDir * 0.62 - across * 0.5 + inward * 0.6).Unit
	local thumbTip = thumbBase + thumbDir * (FINGER * 0.6)
	rod(ctx, hand, prefix .. "Thumb", thumbBase, thumbTip, 0.085, PAINT_SKIN_SMALL)
	claw(ctx, hand, prefix .. "ThumbClaw", thumbTip, (thumbDir + inward * 0.45).Unit, dorsal)
end

local function buildLeg(ctx: Ctx, side: number)
	local prefix = sideName(side)
	local hip = Vector3.new(side * 0.34, HIP_Y, PELVIS_Z)
	local knee = Vector3.new(side * 0.37, KNEE_Y, PELVIS_Z - 0.14)
	local ankle = Vector3.new(side * 0.38, ANKLE_Y, PELVIS_Z + 0.02)
	ctx.pivots[prefix .. "Hip"] = hip
	ctx.pivots[prefix .. "Knee"] = knee
	ctx.pivots[prefix .. "Ankle"] = ankle

	local thighDir = (knee - hip).Unit
	local shinDir = (ankle - knee).Unit
	local thigh = rigRod(ctx, prefix .. "UpperLeg", hip - thighDir * 0.14, knee, 0.36, PAINT_SKIN)
	ball(ctx, thigh, prefix .. "HipJoint", hip + Vector3.new(side * 0.02, 0, 0), 0.4, PAINT_SKIN)
	local shin = rigRod(ctx, prefix .. "LowerLeg", knee, ankle + shinDir * 0.16, 0.3, PAINT_SKIN)
	local shinFront = orthogonal(-Vector3.zAxis, shinDir)
	ball(ctx, shin, prefix .. "KneeJoint", knee, 0.4, PAINT_SKIN)
	ball(ctx, shin, prefix .. "KneeCap", knee + Vector3.new(0, 0.04, -0.17), 0.22, PAINT_BONE)
	rod(
		ctx,
		shin,
		prefix .. "ShinRidge",
		knee + shinFront * 0.14 + shinDir * 0.22,
		ankle + shinFront * 0.13 - shinDir * 0.25,
		0.09,
		PAINT_BONE
	)
	ball(ctx, shin, prefix .. "AnkleKnob", ankle + Vector3.new(side * 0.14, -0.02, 0.01), 0.13, PAINT_BONE_SMALL)

	-- Foot-local: origin on the floor under the ankle, toes turned slightly out.
	local foot = CFrame.new(ankle.X, 0, ankle.Z) * CFrame.Angles(0, -side * TOE_OUT, 0)
	-- a bony sole carrying the steep instep, the heel knob behind and three long toes gripping the floor ahead
	local footPart =
		rigPart(ctx, prefix .. "Foot", foot * CFrame.new(0, 0.05, -0.25), Vector3.new(0.32, 0.1, 0.86), PAINT_SKIN)
	wedge(
		ctx,
		footPart,
		prefix .. "Instep",
		foot * CFrame.new(0, 0.22, -0.3),
		Vector3.new(0.28, 0.24, 0.66),
		PAINT_SKIN
	)
	ball(ctx, footPart, prefix .. "Heel", foot * Vector3.new(0, 0.15, 0.12), 0.3, PAINT_SKIN)
	local droop = math.rad(14)
	for i, toe in TOES do
		local height = 0.075
		local splay = side * math.rad((i - 2) * 4)
		local direction =
			Vector3.new(-math.sin(splay) * math.cos(droop), -math.sin(droop), -math.cos(splay) * math.cos(droop))
		-- the front-bottom edge of each toe rests on the floor
		local centreY = toe.length / 2 * math.sin(droop) + height / 2 * math.cos(droop)
		local start = Vector3.new(side * toe.x, centreY + toe.length / 2 * math.sin(droop), -0.66)
		local centre = start + direction * (toe.length / 2)
		block(
			ctx,
			footPart,
			string.format("%sToe%d", prefix, i),
			foot * frameZ(centre, -direction, Vector3.yAxis),
			Vector3.new(toe.width, height, toe.length),
			PAINT_SKIN_SMALL
		)
	end
end

--------------------------------------------------------------------------------
-- Hitbox, joints, Humanoid
--------------------------------------------------------------------------------

local function hitboxOffset(poseMode: string, size: Vector3): CFrame
	local layout = HITBOX_LAYOUTS[poseMode]
	if not layout then
		return CFrame.identity
	end
	local y = if layout.floor then size.Y / 2 - ROOT_HEIGHT else 0
	return CFrame.new(0, y, -layout.forward)
end

local function buildHitbox(ctx: Ctx)
	local root = ctx.parts.HumanoidRootPart
	local size = CreatureConfig.Hitbox[BIPED]
	local offset = hitboxOffset(BIPED, size)
	local hitbox = Geometry.part(ctx.model, HITBOX_NAME, root.CFrame * offset, size, nil, options(PAINT_INVISIBLE))
	local joint = Instance.new("Weld")
	joint.Name = HITBOX_JOINT
	joint.Part0 = root
	joint.Part1 = hitbox
	joint.C0 = offset
	joint.C1 = CFrame.identity
	joint.Parent = hitbox
end

local function buildJoints(ctx: Ctx)
	for _, spec in jointList do
		local part0 = ctx.parts[spec.part0]
		local part1 = ctx.parts[spec.part1]
		local pivot = ctx.pivots[spec.name]
		assert(part0 and part1 and pivot, "creature joint " .. spec.name .. " has no parts or pivot")
		local frame = ctx.base * CFrame.new(pivot)
		local motor = Instance.new("Motor6D")
		motor.Name = spec.name
		motor.Part0 = part0
		motor.Part1 = part1
		motor.C0 = part0.CFrame:ToObjectSpace(frame)
		motor.C1 = part1.CFrame:ToObjectSpace(frame)
		motor.Parent = part1
	end
end

local function buildHumanoid(ctx: Ctx)
	local humanoid = Instance.new("Humanoid")
	humanoid.Name = partNames.Humanoid
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.AutomaticScalingEnabled = false
	humanoid.HipHeight = RIG.HipHeight
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.NameDisplayDistance = 0
	humanoid.Parent = ctx.model
end

-- Frees every part (the server owns the assembly) and applies the collision presets.
local function finalize(ctx: Ctx)
	local root = ctx.parts.HumanoidRootPart
	for _, descendant in ctx.model:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end
		descendant.Anchored = false
		descendant.CanTouch = false
		descendant.CanQuery = false
		descendant.CanCollide = false
		descendant.Massless = true
		descendant.CollisionGroup = CollisionGroups.NoCollide
	end
	root.Massless = false
	root.CanCollide = true
	root.CollisionGroup = CollisionGroups.Monster
	local hitbox = ctx.model:FindFirstChild(HITBOX_NAME)
	if hitbox and hitbox:IsA("BasePart") then
		hitbox.CanQuery = true
		hitbox.CollisionGroup = CollisionGroups.Monster
	end
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- Builds the Creature standing on the floor point `cframe` (LookVector = facing) and parents it to `parent` once
-- it is fully jointed. Untagged: WorldService names, tags and claims it.
function CreatureRigBuilder.build(parent: Instance, cframe: CFrame): Model
	local model = Instance.new("Model")
	model.Name = Instances.Names.Creature
	local ctx: Ctx = {
		model = model,
		base = cframe,
		random = MathUtil.seededRandom(RIG_SEED, RIG_KIND),
		parts = {},
		pivots = {},
	}
	buildRoot(ctx)
	buildPelvis(ctx)
	local torso = buildTorso(ctx)
	local head = buildHead(ctx, torso)
	buildJaw(ctx, head)
	buildHair(ctx, head)
	for _, side in { -1, 1 } do
		buildArm(ctx, torso, side)
		buildLeg(ctx, side)
	end
	buildHitbox(ctx)
	buildJoints(ctx)
	buildHumanoid(ctx)
	finalize(ctx)
	model.PrimaryPart = ctx.parts.HumanoidRootPart
	model:SetAttribute(Attributes.Creature.PoseMode, BIPED)
	model.Parent = parent
	return model
end

-- Resizes the CreatureHitbox to CreatureConfig.Hitbox[poseMode] and moves it to that pose's layout (see the
-- header). The joint offset and the part's CFrame stay consistent. Unknown modes and models without a hitbox
-- are left untouched.
function CreatureRigBuilder.setHitbox(model: Model, poseMode: string)
	local size = CreatureConfig.Hitbox[poseMode]
	if not size then
		return
	end
	local root = model:FindFirstChild(partNames.Root)
	local hitbox = model:FindFirstChild(HITBOX_NAME)
	if not (root and root:IsA("BasePart") and hitbox and hitbox:IsA("BasePart")) then
		return
	end
	local joint = hitbox:FindFirstChild(HITBOX_JOINT)
	if not (joint and joint:IsA("JointInstance")) then
		return
	end
	local offset = hitboxOffset(poseMode, size)
	hitbox.Size = size
	joint.C0 = offset
	joint.C1 = CFrame.identity
	hitbox.CFrame = root.CFrame * offset
end

function CreatureRigBuilder.register(registrar: PropKit.Registrar)
	registrar.rig(RIG_KIND, CreatureRigBuilder.build)
end

return table.freeze(CreatureRigBuilder)
