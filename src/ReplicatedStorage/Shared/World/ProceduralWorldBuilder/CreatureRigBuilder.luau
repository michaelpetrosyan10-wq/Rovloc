--!strict
-- CreatureRigBuilder: the Creature ("the Tall Man"), built from Parts in code. An 11-stud shadow figure: a thin,
-- elongated humanoid with a narrow but present ribbed chest and bony shoulders, a long sinewy neck jutting forward,
-- arms long enough that the hands hang below the knees and end in long tapering black fingers (no claws), long thin
-- legs on narrow pointed feet, and an ivory porcelain mask over a black skull with black tatters hanging from the crown.
-- The body is matte near-black with a faint sheen; the mask is the palest thing on it.
--
-- The mask. A sculpted porcelain face, one shape defined once here (MaskShape: the outline, the centreline depth and the
-- relief, in face-frame studs: X right, Y up, Z back) and drawn by each platform as well as it can:
--   * Roblox builds it from Parts: the shell (the upper mask, a vertical cylinder from the mouth slit up to the brow
--     capped by a dome, rides the Head; the lower mask, the Jaw ball with the chin tapering to a point below it, rides
--     its own hinged Motor6D so the jumpscare can split the slit open), the relief (brow ridges, glabella, nose ridge
--     and tip, cheekbones, lips, chin: porcelain parts sunk into the shell) and the drawn detail in Fabric: almond eye
--     holes in shaded sockets with the Neon pinprick pupils just in front, the half-smiling slit, black caps and a black
--     sleeve on the faces the split opens (MouthVoidUpper / MouthVoidLower: no porcelain shows inside the split), the
--     cracks (CrackFrom / CrackTo / CrackWidth: their face-frame ends), the weeping streaks (StreakFrom / StreakTo /
--     StreakWidth), the chipped edge (MaskChip: the void behind it) and the jagged shards the open split bares
--     (MawShard<N>), plus a SurfaceGui of grime on the face (MaskGrime).
--   * The website hides all of those parts and draws a dense sculpt of the same outline and relief, painted in its mask
--     shader from the same numbers (MaskAttributes, MaskShape and the detail parts' attributes).
-- What a Roblox animator and controller need to match the website (joints, rest pose, actions and timings, the hinge,
-- the tear, the dissolve, the smoke): docs/MONSTER-LOOK.md.
--
-- Rig-local space. Every piece is placed in the frame of the `cframe` handed to build(): its origin is the floor
-- point at the CreatureSpawn anchor, +Y is up, -Z (LookVector) is the facing and +X the Creature's right. The
-- HumanoidRootPart centre sits Rig.HipHeight + RootSize.Y / 2 above the floor; the pupils' midpoint sits exactly
-- EyeHeightAboveRoot.Biped above the root centre, ahead of it because the head juts forward on the neck
-- (PartNames.FaceAttachment marks it exactly, facing forward, for the jumpscare camera); the top of the skull (the
-- Crown) is Rig.Height above the floor; the soles and toe tips rest on the floor.
--
-- Joints. One Motor6D per entry of CreatureRigBuilder.Joints (R15 names, plus "Jaw", the fingers <Side><Finger> on
-- each Hand and the tatter chains Head -> Hair<N>_1 -> Hair<N>_2, each Motor6D named after its Part1), parented to its
-- Part1. Every joint frame (Part0.CFrame * C0) sits at the pivot and is axis-aligned with the rig-local frame in the
-- rest pose, so a Motor6D.Transform means the same thing on every joint: rotations about X pitch, about Y yaw, about Z
-- roll, all relative to the Creature's own facing. CFrame.Angles(-a, 0, 0) on "Jaw" drops the chin open by `a`
-- radians; a yaw on "Neck" / "Waist" turns the head / upper body about the vertical. All parts are placed explicitly
-- so Part1.CFrame == Part0.CFrame * C0 * C1:Inverse() at rest (identity Transform). Detail pieces (knobs, ribs, finger
-- segments, tatter strands, the neck) are children of the limb that carries them, held by a WeldConstraint.
--
-- Smoke anchors. Attachments named in PartNames.SmokeAnchors (shoulders, elbows, every fingertip, the back and the
-- back of the skull, and the shroud: the chest, the flanks, the hips and the thighs) mark where the web's wisps leave
-- the body; each carries a SmokeWeight attribute (its share of the spawns) and the shroud's a SmokeShroud attribute (the
-- heavy, sinking smoke hanging from the shoulders down).
--
-- Physics (ARCHITECTURE §4a): nothing is anchored (the server owns the assembly). Only HumanoidRootPart has mass
-- and collides (CollisionGroup Monster); every limb and detail is Massless, non-colliding, never queried or
-- touched and in NoCollide. CreatureHitbox (Monster, CanQuery only) hangs off the root by the Weld "HitboxJoint";
-- setHitbox() resizes it per PoseMode. This rig is the one place allowed to write CollisionGroup directly.
--
-- Hitbox layouts (root-relative): Biped and Hunched stand on the floor (box bottom at the floor, pushed forward over
-- the jutting head; Hunched shorter and further forward over the bent body); Quadruped carries the body level
-- with the root, so its low, long box is centred on it and runs forward along the facing.
--
-- Metrics. CreatureRigBuilder.Metrics holds what the web's behaviour reads from the export (meta.creature.metrics):
-- the standing and hunched heights, the eye heights per PoseMode, the catch reach, the root height and the hitbox per
-- PoseMode (size and root-relative offset).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Instances = require(ReplicatedStorage.Shared.Instances)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Rng = require(ReplicatedStorage.Shared.Util.Rng)

local Geometry = require(script.Parent.Geometry)
local PropKit = require(script.Parent.Props.PropKit)
local SurfaceArt = require(script.Parent.SurfaceArt)

type Rng = Rng.Rng
export type JointSpec = { name: string, part0: string, part1: string }

export type PartNameMap = {
	Root: string,
	LowerTorso: string,
	UpperTorso: string,
	Head: string,
	Jaw: string, -- the lower mask (the chin), hinged under the mouth slit
	Mask: string, -- the upper mask, welded to the Head; carries the MaskAttributes
	Crown: string, -- the top of the skull
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
	Hair: { { string } }, -- the tatters, per clump, root to tip
	Fingers: { [string]: { string } }, -- per side ("Left", "Right"): Index, Middle, Ring, Pinky, Thumb
	SmokeAnchors: { string }, -- Attachments the wisps leave from
}

export type HitboxMetric = { size: Vector3, offset: CFrame }

export type MetricsMap = {
	Height: number,
	HunchedHeight: number,
	RootHeight: number,
	Reach: number,
	ArmLength: number,
	EyeHeight: { [string]: number }, -- above the floor, per PoseMode
	EyeHeightAboveRoot: { [string]: number },
	Hitboxes: { [string]: HitboxMetric },
}

type Paint = {
	material: Enum.Material,
	color: Color3,
	shadow: boolean,
	transparency: number?,
	reflectance: number?,
}

type TatterClump = {
	azimuth: number, -- degrees around the skull: 0 = straight back, +90 = the Creature's right
	elevation: number, -- degrees above the skull's equator where it leaves the skull
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
	random: Rng,
	parts: { [string]: BasePart }, -- jointed rig parts by name
	pivots: { [string]: Vector3 }, -- rig-local pivot of each joint, by joint name
}

local RIG = CreatureConfig.Rig
local RIG_KIND = "Creature"
local RIG_SEED = 8517 -- every build of the Creature is identical (its tatters included)
local BIPED: Enums.PoseMode = "Biped"
local PART_BUDGET = 240

local ROOT_HEIGHT = RIG.HipHeight + RIG.RootSize.Y / 2
local EYE_HEIGHT = ROOT_HEIGHT + CreatureConfig.EyeHeightAboveRoot.Biped

-- Posture (rig-local). The pelvis sits a little behind the root's centre; the chest leans forward over it and the
-- neck juts the head forward again, so the face hangs ahead of the body.
local PELVIS_Y = 5.84
local PELVIS_Z = 0.14
local PELVIS_DIAMETER = 0.6
local HIP_X = 0.26
local HIP_Y = 5.62
local KNEE = Vector3.new(0.28, 2.98, PELVIS_Z - 0.2) -- mirrored in X
local ANKLE = Vector3.new(0.3, 0.34, PELVIS_Z + 0.02)
local WAIST = Vector3.new(0, 6.2, PELVIS_Z + 0.02)
local TORSO_PITCH = math.rad(12) -- the chest leans forward about the waist
local NECK_LEAN = math.rad(22) -- the neck leans forward again from its base
local HEAD_PITCH = math.rad(-8) -- chin tucked: the mask looks down at whoever stands in front of it
local TOE_OUT = math.rad(7)

-- Torso-local (origin at the waist pivot, Y up the spine, -Z forward).
local TORSO_LENGTH = 2.5 -- waist to the neck base
local NECK_BASE = Vector3.new(0, TORSO_LENGTH, -0.04)
local SHOULDER = Vector3.new(0.63, 2.26, 0.02) -- mirrored in X: a narrow, slightly hunched yoke of bony shoulders
local FLANK_X = 0.19
local FLANK_DIAMETER = 0.52
local CHEST_BOTTOM = 0.95
local CHEST_TOP = 2.16

-- Head-local (origin at the pupils' midpoint, axes pitched by HEAD_PITCH, -Z forward). The mask's numbers below are
-- face-frame studs (X right, Y up, Z back).
local EYE_X = 0.15 -- the eye holes' centres either side
local MASK_RADIUS = 0.345 -- Roblox's shell: the upper mask's cylinder (the sculpt's outline is MASK_OUTLINE)
local MASK_Z = math.sqrt(MASK_RADIUS ^ 2 - EYE_X ^ 2) -- the cylinder's axis: the eye-hole centres lie on its surface
local MASK_TOP = 0.17 -- the brow dome's centre; the upper mask's cylinder runs from the slit up to it
local SLIT_Y = -0.34 -- the mouth slit: the seam between the upper mask and the hinged chin
local SLIT_HALF_WIDTH = 0.15
local SLIT_UPTURN = 0.036 -- the slit's right corner (+X) curls up this much: a wrong half-smile
local CHIN_RADIUS = 0.3 -- Roblox's jaw ball, hanging just under the slit ...
local CHIN_CENTRE = Vector3.new(0, SLIT_Y - 0.02, MASK_Z)
local CHIN_TIP = Vector3.new(0.008, -0.7, MASK_Z - 0.17) -- ... and the pointed chin under it
local CHIN_TIP_RADIUS = 0.09
local SLEEVE_RADIUS = 0.32 -- the black sleeve over the jaw ball's cap above the seam (inside the upper cylinder)
local JAW_HINGE = Vector3.new(0, SLIT_Y + 0.02, MASK_Z + 0.3) -- behind the slit, inside the skull
local EYE_HOLE = Vector3.new(0.106, 0.062, 0.3) -- the eye holes: half-width, half-height, depth (of the bores)
local PUPIL_SIZE = 0.03
local PUPIL_GLOW_RADIUS = 0.009 -- the painted pinprick at the bottom of each hole ...
local PUPIL_SCALE_RIGHT = 1.45 -- ... the right one larger than the left
local CRANIUM_RADIUS = 0.47
local CRANIUM_Z = MASK_Z + 0.27
-- Skull height that puts the top of the cranium exactly Rig.Height above the floor in the rest pose.
local CRANIUM_Y = (RIG.Height - EYE_HEIGHT - CRANIUM_RADIUS + math.sin(HEAD_PITCH) * CRANIUM_Z) / math.cos(HEAD_PITCH)
local SKULL_BASE = Vector3.new(0, -0.36, 0.62) -- where the neck column enters the skull
local THROAT = Vector3.new(0, SLIT_Y - 0.12, MASK_Z + 0.3)

-- The sculpt (MaskShape; the website draws it, Roblox's parts approximate it). The front outline as knots from the
-- top down: { y, half-width to the left (-X), half-width to the right (+X) }: an elongated oval a little too long,
-- a touch lopsided, tapering from the cheekbones to a pointed chin.
local MASK_OUTLINE: { { number } } = {
	{ 0.53, 0, 0 },
	{ 0.5, 0.14, 0.15 },
	{ 0.44, 0.235, 0.245 },
	{ 0.36, 0.3, 0.31 },
	{ 0.24, 0.345, 0.352 },
	{ 0.1, 0.368, 0.372 },
	{ -0.04, 0.37, 0.366 },
	{ -0.16, 0.352, 0.346 },
	{ -0.28, 0.318, 0.312 },
	{ -0.4, 0.272, 0.262 },
	{ -0.52, 0.212, 0.2 },
	{ -0.62, 0.148, 0.134 },
	{ -0.7, 0.088, 0.074 },
	{ -0.76, 0.036, 0.028 },
	{ -0.79, 0, 0 },
}
-- The centreline's depth (Z back) down the face, { y, z }; the rim recedes MASK_DEPTH further back on an ellipse.
local MASK_PROFILE: { { number } } = {
	{ 0.53, 0.24 },
	{ 0.48, 0.14 },
	{ 0.4, 0.06 },
	{ 0.3, 0.02 },
	{ 0.15, 0 },
	{ 0, 0 },
	{ -0.2, 0 },
	{ -0.34, 0.01 },
	{ -0.5, 0.03 },
	{ -0.65, 0.06 },
	{ -0.79, 0.13 },
}
local MASK_DEPTH = 0.24
-- The relief over the shell, in studs toward the viewer (negative: hollowed): anisotropic bumps
-- { centre x, centre y, radius x, radius y, height, tilt in degrees }. A heavy brow ridge over deep sockets, a thin
-- nose ridge, cheekbones over sunken cheeks, faint lips round the slit and a pointed chin.
local MASK_RELIEF: { [string]: { number } } = {
	BrowLeft = { -0.155, 0.125, 0.115, 0.034, 0.055, -9 },
	BrowRight = { 0.16, 0.135, 0.118, 0.034, 0.05, 7 },
	Glabella = { 0, 0.085, 0.04, 0.045, 0.03, 0 },
	Forehead = { 0, 0.33, 0.23, 0.13, 0.025, 0 },
	SocketLeft = { -0.15, -0.005, 0.105, 0.085, -0.085, 0 },
	SocketRight = { 0.152, 0, 0.11, 0.09, -0.09, 0 },
	Nose = { 0, -0.075, 0.022, 0.12, 0.04, 0 },
	NoseTip = { 0, -0.2, 0.042, 0.032, 0.03, 0 },
	CheekLeft = { -0.245, -0.11, 0.078, 0.046, 0.032, -14 },
	CheekRight = { 0.25, -0.1, 0.078, 0.046, 0.03, 14 },
	HollowLeft = { -0.2, -0.25, 0.06, 0.08, -0.055, 0 },
	HollowRight = { 0.205, -0.245, 0.06, 0.085, -0.06, 0 },
	LipUpper = { 0, -0.312, 0.13, 0.018, 0.014, 0 },
	LipLower = { 0.005, -0.374, 0.11, 0.022, 0.016, 0 },
	Philtrum = { 0, -0.265, 0.014, 0.04, -0.008, 0 },
	Chin = { 0.008, -0.62, 0.075, 0.07, 0.025, 0 },
	TempleLeft = { -0.34, 0.14, 0.06, 0.1, -0.03, 0 },
	TempleRight = { 0.34, 0.14, 0.06, 0.1, -0.03, 0 },
	Mentolabial = { 0, -0.47, 0.08, 0.02, -0.012, 0 },
}
-- The chipped edge: an ellipse { centre, radii, tilt } where a piece of the rim broke away onto the black behind.
local CHIP_CENTRE = Vector2.new(0.315, 0.31)
local CHIP_RADIUS = Vector2.new(0.075, 0.05)
local CHIP_ANGLE = 35

-- Arm proportions: shoulder -> elbow -> wrist -> knuckles -> middle fingertip adds up to Rig.ArmLength.
local FINGER = RIG.FingerLength
local PALM = 0.6
local UPPER_ARM = (RIG.ArmLength - FINGER - PALM) * 0.52
local FOREARM = RIG.ArmLength - FINGER - PALM - UPPER_ARM
local SEGMENT_SHARE = { 0.42, 0.33, 0.25 } -- proximal, middle and distal share of a finger
local SEGMENT_CURL = { 10, 22, 30 } -- each segment's curl toward the palm, degrees
local SEGMENT_DIAMETER = { 0.08, 0.066, 0.052 }
local TIP_LENGTH = 0.11 -- the tapering point past the last segment
local TIP_WIDTH = 0.04

local HAIR_THICKNESS = 0.03
local STRAND_WIDTH = 0.028
local STRAND_THICKNESS = 0.02

local HITBOX_NAME = "CreatureHitbox"
local HITBOX_JOINT = "HitboxJoint"
local FACE_ATTACHMENT = "FaceFrontAttachment"

type HitboxLayout = { floor: boolean, forward: number }

local HITBOX_LAYOUTS: { [string]: HitboxLayout } = {
	Biped = { floor = true, forward = 0.35 },
	Hunched = { floor = true, forward = 1.3 },
	Quadruped = { floor = false, forward = 0.9 },
}

local FINGERS: { FingerSpec } = {
	{ name = "Index", offset = -0.11, inset = 0.03, scale = 0.94, spread = -6, curl = 2 },
	{ name = "Middle", offset = -0.037, inset = 0, scale = 1, spread = -2, curl = 0 },
	{ name = "Ring", offset = 0.037, inset = 0.02, scale = 0.95, spread = 3, curl = 4 },
	{ name = "Pinky", offset = 0.11, inset = 0.06, scale = 0.8, spread = 8, curl = 8 },
}
local THUMB = "Thumb"

-- x is foot-local and measured toward the outside of the foot (the big toe sits innermost).
local TOES: { ToeSpec } = {
	{ x = -0.07, length = 0.42, width = 0.07 },
	{ x = 0.01, length = 0.37, width = 0.06 },
	{ x = 0.08, length = 0.3, width = 0.055 },
}

local TATTERS: { TatterClump } = {
	{ azimuth = 0, elevation = 26, lengths = { 1.3, 1.45 }, splay = { 0.22, 0.08 }, width = 0.16 },
	{ azimuth = 34, elevation = 30, lengths = { 1.2, 1.3 }, splay = { 0.24, 0.08 }, width = 0.14 },
	{ azimuth = -34, elevation = 30, lengths = { 1.25, 1.25 }, splay = { 0.24, 0.08 }, width = 0.14 },
	{ azimuth = 74, elevation = 22, lengths = { 1.05, 1.2 }, splay = { 0.26, 0.06 }, width = 0.12 },
	{ azimuth = -74, elevation = 22, lengths = { 1.08, 1.12 }, splay = { 0.26, 0.06 }, width = 0.12 },
	{ azimuth = 128, elevation = 12, lengths = { 0.9, 0.95 }, splay = { 0.2, 0.04 }, width = 0.1 },
	{ azimuth = -128, elevation = 12, lengths = { 0.86, 0.96 }, splay = { 0.2, 0.04 }, width = 0.1 },
}

--------------------------------------------------------------------------------
-- Paints
--------------------------------------------------------------------------------

local SMOOTH = Enum.Material.SmoothPlastic
local SHEEN = 0.04 -- the body's faint sheen
local BONE_TONE = MathUtil.lerpColor(RIG.ShadowColor, Color3.fromRGB(70, 72, 80), 0.12) -- bony knobs, a hair lighter

local PAINT_SHADOW: Paint = { material = SMOOTH, color = RIG.ShadowColor, shadow = true, reflectance = SHEEN }
local PAINT_SHADOW_SMALL: Paint = { material = SMOOTH, color = RIG.ShadowColor, shadow = false, reflectance = SHEEN }
local PAINT_BONE: Paint = { material = SMOOTH, color = BONE_TONE, shadow = true, reflectance = SHEEN }
local PAINT_BONE_SMALL: Paint = { material = SMOOTH, color = BONE_TONE, shadow = false, reflectance = SHEEN }
local PAINT_MASK: Paint = { material = Enum.Material.Marble, color = RIG.MaskColor, shadow = true, reflectance = 0.1 }
local PAINT_PUPIL: Paint = { material = Enum.Material.Neon, color = RIG.PupilColor, shadow = false }
local PAINT_INVISIBLE: Paint = { material = SMOOTH, color = RIG.ShadowColor, shadow = false, transparency = 1 }
-- The mask's drawn detail (what Roblox renders; the web hides the Fabric chunk and paints the same detail itself)
local PAINT_VOID: Paint = { material = Enum.Material.Fabric, color = Color3.fromRGB(4, 4, 5), shadow = false }
local PAINT_CRACK: Paint = { material = Enum.Material.Fabric, color = Color3.fromRGB(30, 26, 22), shadow = false }
local PAINT_STREAK: Paint = { material = Enum.Material.Fabric, color = Color3.fromRGB(24, 20, 18), shadow = false }
local PAINT_GRIME_CARD: Paint =
	{ material = Enum.Material.Fabric, color = RIG.ShadowColor, shadow = false, transparency = 1 }
local GRIME_COLOR = Color3.fromRGB(92, 70, 38) -- yellowed, sooty grime in the creases and at the rim

-- The cracks on the mask, as face-frame polylines (x right, y up) with their width in studs. The major crack runs from
-- the brow through the left socket down to the jaw; hairlines branch off it, cross the right temple and the forehead,
-- leave the slit's upturned corner down toward the jaw and split the chin.
type CrackPath = { width: number, points: { Vector2 } }
local CRACKS: { CrackPath } = {
	{
		width = 0.008,
		points = {
			Vector2.new(-0.02, 0.46),
			Vector2.new(-0.065, 0.36),
			Vector2.new(-0.1, 0.27),
			Vector2.new(-0.125, 0.18),
			Vector2.new(-0.15, 0.07),
			Vector2.new(-0.17, -0.07),
			Vector2.new(-0.2, -0.17),
			Vector2.new(-0.205, -0.28),
			Vector2.new(-0.218, -0.42),
			Vector2.new(-0.19, -0.56),
		},
	},
	{ width = 0.0042, points = { Vector2.new(-0.125, 0.18), Vector2.new(-0.21, 0.245), Vector2.new(-0.3, 0.27) } },
	{ width = 0.0035, points = { Vector2.new(-0.205, -0.28), Vector2.new(-0.28, -0.225), Vector2.new(-0.33, -0.25) } },
	{ width = 0.004, points = { Vector2.new(0.34, 0.2), Vector2.new(0.285, 0.265), Vector2.new(0.25, 0.37) } },
	{
		width = 0.004,
		points = {
			Vector2.new(0.146, -0.307),
			Vector2.new(0.182, -0.33),
			Vector2.new(0.196, -0.39),
			Vector2.new(0.236, -0.43),
			Vector2.new(0.24, -0.5),
		},
	},
	{ width = 0.0035, points = { Vector2.new(0.04, -0.55), Vector2.new(0.075, -0.635), Vector2.new(0.055, -0.72) } },
	{ width = 0.0035, points = { Vector2.new(0.075, 0.43), Vector2.new(0.115, 0.34), Vector2.new(0.095, 0.27) } },
}
local CRACK_THICKNESS = 0.004

-- The weeping: dark streaks run down from the bottom of both eye holes, as face-frame polylines with their width.
local STREAKS: { CrackPath } = {
	{ width = 0.016, points = { Vector2.new(-0.158, -0.06), Vector2.new(-0.164, -0.16), Vector2.new(-0.154, -0.27) } },
	{ width = 0.01, points = { Vector2.new(-0.118, -0.055), Vector2.new(-0.116, -0.13) } },
	{
		width = 0.016,
		points = {
			Vector2.new(0.148, -0.065),
			Vector2.new(0.143, -0.17),
			Vector2.new(0.151, -0.29),
			Vector2.new(0.146, -0.4),
		},
	},
	{ width = 0.01, points = { Vector2.new(0.192, -0.045), Vector2.new(0.198, -0.115) } },
}

-- The jagged porcelain the open split bares (Roblox; the web tears its own maw): { x, length, width, side }, side 1
-- hanging from the upper mask's edge, -1 rising from the chin's.
local MAW_SHARDS: { { number } } = {
	{ -0.11, 0.09, 0.05, 1 },
	{ 0.02, 0.14, 0.045, 1 },
	{ 0.12, 0.07, 0.04, 1 },
	{ -0.06, 0.08, 0.045, -1 },
	{ 0.07, 0.11, 0.05, -1 },
}

--------------------------------------------------------------------------------
-- Contract tables
--------------------------------------------------------------------------------

local function sideName(side: number): string
	return if side > 0 then "Right" else "Left"
end

local function hairName(clump: number, segment: number): string
	return string.format("Hair%d_%d", clump, segment)
end

local FINGER_NAMES: { string } = {}
for _, finger in FINGERS do
	table.insert(FINGER_NAMES, finger.name)
end
table.insert(FINGER_NAMES, THUMB)

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
local fingerNames: { [string]: { string } } = {}
for _, side in { -1, 1 } do
	local prefix = sideName(side)
	local names: { string } = {}
	for _, finger in FINGER_NAMES do
		local name = prefix .. finger
		table.insert(jointList, { name = name, part0 = prefix .. "Hand", part1 = name })
		table.insert(names, name)
	end
	fingerNames[prefix] = table.freeze(names)
end
local hairNames: { { string } } = {}
for index, clump in TATTERS do
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
table.freeze(fingerNames)

local smokeAnchors: { string } = { "SmokeBack", "SmokeHead", "SmokeChest" }
for _, side in { -1, 1 } do
	local prefix = sideName(side)
	table.insert(smokeAnchors, "Smoke" .. prefix .. "Shoulder")
	table.insert(smokeAnchors, "Smoke" .. prefix .. "Elbow")
	for _, finger in FINGERS do
		table.insert(smokeAnchors, "Smoke" .. prefix .. finger.name .. "Tip")
	end
	-- the shroud: heavy smoke hanging from the shoulders down the flanks, the hips and the thighs
	table.insert(smokeAnchors, "Smoke" .. prefix .. "Flank")
	table.insert(smokeAnchors, "Smoke" .. prefix .. "Hip")
	table.insert(smokeAnchors, "Smoke" .. prefix .. "Thigh")
end
table.freeze(smokeAnchors)

local partNames: PartNameMap = {
	Root = "HumanoidRootPart",
	LowerTorso = "LowerTorso",
	UpperTorso = "UpperTorso",
	Head = "Head",
	Jaw = "Jaw",
	Mask = "Mask",
	Crown = "Crown",
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
	Fingers = fingerNames,
	SmokeAnchors = smokeAnchors,
}
table.freeze(partNames)

-- The mask's painted detail, set as attributes on the Mask part (face-frame studs: X right, Y up, Z back).
local MASK_ATTRIBUTES: { [string]: number } = table.freeze({
	MaskRadius = MASK_RADIUS,
	MaskAxisZ = MASK_Z,
	MaskTop = MASK_OUTLINE[1][1],
	ChinY = MASK_OUTLINE[#MASK_OUTLINE][1],
	MaskDepth = MASK_DEPTH,
	EyeX = EYE_X,
	EyeHoleWidth = EYE_HOLE.X,
	EyeHoleHeight = EYE_HOLE.Y,
	EyeHoleDepth = EYE_HOLE.Z,
	PupilGlowRadius = PUPIL_GLOW_RADIUS,
	PupilScaleRight = PUPIL_SCALE_RIGHT,
	SlitY = SLIT_Y,
	SlitHalfWidth = SLIT_HALF_WIDTH,
	SlitUpturn = SLIT_UPTURN,
	ChinRadius = CHIN_RADIUS,
	ChipAngle = CHIP_ANGLE,
})

-- Number rows as "a:b:c;d:e:f" (attributes hold no arrays).
local function rows(list: { { number } }): string
	local out: { string } = {}
	for _, row in list do
		local cells: { string } = {}
		for _, value in row do
			table.insert(cells, string.format("%.4g", value))
		end
		table.insert(out, table.concat(cells, ":"))
	end
	return table.concat(out, ";")
end

local reliefNames: { string } = {}
for name in MASK_RELIEF do
	table.insert(reliefNames, name)
end
table.sort(reliefNames)

local function reliefRows(): string
	local out: { string } = {}
	for _, name in reliefNames do
		table.insert(out, name .. ":" .. rows({ MASK_RELIEF[name] }))
	end
	return table.concat(out, ";")
end

-- The sculpt's shape, set as attributes on the Mask part too: MaskOutline "y:left:right;..." (the front outline's
-- knots, top down), MaskProfile "y:z;..." (the centreline's depth), MaskRelief "Name:x:y:rx:ry:height:tilt;..." (the
-- relief's bumps, sorted by name), ChipCentre / ChipRadius (with ChipAngle above: the broken-off piece of the rim).
export type MaskShapeMap = {
	MaskOutline: string,
	MaskProfile: string,
	MaskRelief: string,
	ChipCentre: Vector2,
	ChipRadius: Vector2,
}
local MASK_SHAPE: MaskShapeMap = table.freeze({
	MaskOutline = rows(MASK_OUTLINE),
	MaskProfile = rows(MASK_PROFILE),
	MaskRelief = reliefRows(),
	ChipCentre = CHIP_CENTRE,
	ChipRadius = CHIP_RADIUS,
})

local function hitboxOffset(poseMode: string, size: Vector3): CFrame
	local layout = HITBOX_LAYOUTS[poseMode]
	if not layout then
		return CFrame.identity
	end
	local y = if layout.floor then size.Y / 2 - ROOT_HEIGHT else 0
	return CFrame.new(0, y, -layout.forward)
end

local function buildMetrics(): MetricsMap
	local eyeHeight: { [string]: number } = {}
	local hitboxes: { [string]: HitboxMetric } = {}
	for mode, above in CreatureConfig.EyeHeightAboveRoot do
		eyeHeight[mode] = ROOT_HEIGHT + above
	end
	for mode, size in CreatureConfig.Hitbox do
		hitboxes[mode] = table.freeze({ size = size, offset = hitboxOffset(mode, size) })
	end
	return table.freeze({
		Height = RIG.Height,
		HunchedHeight = RIG.HunchedHeight,
		RootHeight = ROOT_HEIGHT,
		Reach = RIG.Reach,
		ArmLength = RIG.ArmLength,
		EyeHeight = table.freeze(eyeHeight),
		EyeHeightAboveRoot = CreatureConfig.EyeHeightAboveRoot,
		Hitboxes = table.freeze(hitboxes),
	})
end

local CreatureRigBuilder = {}

-- Ordered parent-before-child: walking it in order composes every rest frame from the root outward.
CreatureRigBuilder.Joints = jointList
CreatureRigBuilder.PartNames = partNames
CreatureRigBuilder.PartBudget = PART_BUDGET
CreatureRigBuilder.MaskAttributes = MASK_ATTRIBUTES
CreatureRigBuilder.MaskShape = MASK_SHAPE
CreatureRigBuilder.Metrics = buildMetrics()

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
		reflectance = paint.reflectance,
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

-- A smoke anchor: an Attachment on `part` at rig-local `position`, axis-aligned with the rig. A shroud anchor's smoke
-- is the heavy, sinking kind that hangs from the shoulders down.
local function smokeAnchor(ctx: Ctx, part: BasePart, name: string, position: Vector3, weight: number, shroud: boolean?)
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.CFrame = part.CFrame:ToObjectSpace(ctx.base * CFrame.new(position))
	attachment:SetAttribute("SmokeWeight", weight)
	if shroud then
		attachment:SetAttribute("SmokeShroud", true)
	end
	attachment.Parent = part
end

--------------------------------------------------------------------------------
-- Root, pelvis and torso
--------------------------------------------------------------------------------

local function buildRoot(ctx: Ctx)
	rigPart(ctx, "HumanoidRootPart", CFrame.new(0, ROOT_HEIGHT, 0), RIG.RootSize, PAINT_INVISIBLE)
end

local function buildPelvis(ctx: Ctx)
	-- a narrow bowl slung between the hip joints, the iliac crests jutting from its upper front corners
	local centre = Vector3.new(0, PELVIS_Y, PELVIS_Z)
	local pelvis =
		rigPart(ctx, "LowerTorso", CFrame.new(centre), Vector3.one * PELVIS_DIAMETER, PAINT_SHADOW, Enum.PartType.Ball)
	ctx.pivots.Root = centre
	for _, side in { -1, 1 } do
		ball(ctx, pelvis, sideName(side) .. "HipBone", centre + Vector3.new(side * 0.24, 0.12, -0.18), 0.17, PAINT_BONE)
	end
end

-- Builds the chest, ribs and abdomen; returns the torso frame (origin at the waist pivot, pitched forward).
local function buildTorso(ctx: Ctx): CFrame
	local torso = CFrame.new(WAIST) * CFrame.Angles(-TORSO_PITCH, 0, 0)
	local function at(x: number, y: number, z: number): Vector3
		return torso * Vector3.new(x, y, z)
	end
	local chest = rigPart(
		ctx,
		"UpperTorso",
		torso * CFrame.new(0, (CHEST_BOTTOM + CHEST_TOP) / 2, 0.02),
		Vector3.new(FLANK_X * 2 + 0.16, CHEST_TOP - CHEST_BOTTOM, FLANK_DIAMETER - 0.06),
		PAINT_SHADOW
	)
	ctx.pivots.Waist = WAIST

	-- the waist: a thin column, the belly drawn in under the ribs
	rod(ctx, chest, "Abdomen", at(0, -0.25, 0.05), at(0, CHEST_BOTTOM + 0.08, 0.05), 0.32, PAINT_SHADOW)
	-- the shoulder yoke: a thin bar between the shoulder knobs, set high and a little forward (the hunch)
	rod(
		ctx,
		chest,
		"Yoke",
		at(-SHOULDER.X + 0.05, SHOULDER.Y - 0.02, SHOULDER.Z),
		at(SHOULDER.X - 0.05, SHOULDER.Y - 0.02, SHOULDER.Z),
		0.3,
		PAINT_SHADOW
	)
	-- the breastbone: a bony ridge down the front of the ribcage
	rod(
		ctx,
		chest,
		"Sternum",
		at(0, CHEST_BOTTOM + 0.18, -FLANK_DIAMETER / 2 + 0.02),
		at(0, SHOULDER.Y - 0.08, -FLANK_DIAMETER / 2 + 0.05),
		0.09,
		PAINT_BONE_SMALL
	)
	for _, side in { -1, 1 } do
		local prefix = sideName(side)
		-- the narrow ribcage: two rounded flanks side by side, a few ribs standing proud on each
		rod(
			ctx,
			chest,
			prefix .. "Flank",
			at(side * FLANK_X, CHEST_BOTTOM, 0.02),
			at(side * (FLANK_X + 0.01), CHEST_TOP, 0.02),
			FLANK_DIAMETER,
			PAINT_SHADOW
		)
		for rib = 1, 3 do
			local y = CHEST_BOTTOM + 0.22 + (rib - 1) * 0.26
			local frame = torso * CFrame.new(side * (FLANK_X + 0.02), y, 0.02) * CFrame.Angles(-math.rad(14), 0, 0)
			disc(
				ctx,
				chest,
				string.format("%sRib%d", prefix, rib),
				frame,
				0.045,
				FLANK_DIAMETER + 0.05,
				PAINT_BONE_SMALL
			)
		end
		-- the trapezius: a hunched slope from the neck down onto the shoulder
		wedge(
			ctx,
			chest,
			prefix .. "Trapezius",
			torso * frameY(Vector3.new(side * 0.35, SHOULDER.Y + 0.1, 0.06), Vector3.yAxis, Vector3.new(-side, 0, 0)),
			Vector3.new(0.48, 0.36, 0.48),
			PAINT_SHADOW
		)
		rod(
			ctx,
			chest,
			prefix .. "Collarbone",
			at(side * 0.07, SHOULDER.Y + 0.05, -0.17),
			at(side * (SHOULDER.X - 0.08), SHOULDER.Y + 0.02, -0.08),
			0.07,
			PAINT_BONE_SMALL
		)
		-- the shoulder blade juts beside the spine and slopes flat toward the armpit
		local blade = torso * CFrame.new(side * 0.28, SHOULDER.Y - 0.42, FLANK_DIAMETER / 2 + 0.03)
		wedge(
			ctx,
			chest,
			prefix .. "ShoulderBlade",
			frameZ(blade.Position, rotate(blade, Vector3.new(-side, 0, 0)), rotate(blade, Vector3.zAxis))
				* CFrame.Angles(0, 0, side * math.rad(8)),
			Vector3.new(0.46, 0.09, 0.3),
			PAINT_BONE
		)
	end
	-- the spine: a ridge of knobs down the hunched back
	local knobs: { { number } } = {
		{ 2.3, 0.1 },
		{ 2.0, 0.1 },
		{ 1.7, 0.105 },
		{ 1.4, 0.105 },
		{ 1.1, 0.11 },
		{ 0.6, 0.11 },
		{ 0.25, 0.115 },
	}
	for i, knob in knobs do
		local surface = if knob[1] >= CHEST_BOTTOM then FLANK_DIAMETER / 2 + 0.02 else 0.05 + 0.16
		ball(ctx, chest, string.format("Spine%d", i), at(0, knob[1], surface), knob[2], PAINT_BONE_SMALL)
	end
	smokeAnchor(ctx, chest, "SmokeBack", at(0, SHOULDER.Y - 0.35, FLANK_DIAMETER / 2 + 0.08), 1.2)
	-- the shroud hangs from the shoulders down: the breastbone and the flanks
	smokeAnchor(ctx, chest, "SmokeChest", at(0, SHOULDER.Y - 0.5, -FLANK_DIAMETER / 2 - 0.06), 1.1, true)
	for _, side in { -1, 1 } do
		local flank = at(side * (FLANK_X + FLANK_DIAMETER / 2 + 0.04), CHEST_BOTTOM + 0.35, 0.02)
		smokeAnchor(ctx, chest, "Smoke" .. sideName(side) .. "Flank", flank, 1, true)
	end
	return torso
end

--------------------------------------------------------------------------------
-- Head, mask and neck
--------------------------------------------------------------------------------

-- The head frame (origin at the pupils' midpoint) for a neck rising from `neckBase`: the neck leans forward by
-- NECK_LEAN and is exactly long enough to put the eyes at EYE_HEIGHT. Returns the frame and the skull base.
local function headFrame(neckBase: Vector3): (CFrame, Vector3)
	local tilt = CFrame.Angles(HEAD_PITCH, 0, 0)
	local skullBase = tilt * SKULL_BASE
	local rise = EYE_HEIGHT + skullBase.Y - neckBase.Y
	local length = rise / math.cos(NECK_LEAN)
	local top = neckBase + Vector3.new(0, rise, -math.sin(NECK_LEAN) * length)
	return CFrame.new(top - skullBase) * tilt, top
end

-- Builds the skull (the Head part), the upper mask, the pupils, the throat and the neck. Returns the head frame.
local function buildHead(ctx: Ctx, torso: CFrame): CFrame
	local neckBase = torso * NECK_BASE
	local head, skullBase = headFrame(neckBase)
	local function at(x: number, y: number, z: number): Vector3
		return head * Vector3.new(x, y, z)
	end
	-- the skull turns on the top of the long neck; the neck itself rides the chest
	ctx.pivots.Neck = skullBase

	-- the black skull behind the mask; the Crown is its top, the highest point of the body
	local skull = rigPart(
		ctx,
		"Head",
		CFrame.new(at(0, CRANIUM_Y, CRANIUM_Z)),
		Vector3.one * CRANIUM_RADIUS * 2,
		PAINT_SHADOW,
		Enum.PartType.Ball
	)
	local face = Instance.new("Attachment")
	face.Name = FACE_ATTACHMENT
	face.CFrame = skull.CFrame:ToObjectSpace(ctx.base * head)
	face.Parent = skull
	local crownTop = at(0, CRANIUM_Y, CRANIUM_Z) + Vector3.yAxis * CRANIUM_RADIUS
	ball(ctx, skull, "Crown", crownTop - Vector3.yAxis * 0.16, 0.32, PAINT_SHADOW)

	-- the upper mask (Roblox's shell): a porcelain cylinder from the slit up to the brow, capped by a dome; it carries
	-- the numbers both platforms draw the mask from
	local mask = rod(ctx, skull, "Mask", at(0, SLIT_Y, MASK_Z), at(0, MASK_TOP, MASK_Z), MASK_RADIUS * 2, PAINT_MASK)
	for name, value in MASK_ATTRIBUTES do
		mask:SetAttribute(name, value)
	end
	mask:SetAttribute("MaskOutline", MASK_SHAPE.MaskOutline)
	mask:SetAttribute("MaskProfile", MASK_SHAPE.MaskProfile)
	mask:SetAttribute("MaskRelief", MASK_SHAPE.MaskRelief)
	mask:SetAttribute("ChipCentre", MASK_SHAPE.ChipCentre)
	mask:SetAttribute("ChipRadius", MASK_SHAPE.ChipRadius)
	ball(ctx, skull, "MaskBrow", at(0, MASK_TOP, MASK_Z), MASK_RADIUS * 2, PAINT_MASK)
	for _, side in { -1, 1 } do
		-- the pinprick at each eye hole's centre, on the mask's surface; the right one larger
		local size = if side > 0 then PUPIL_SIZE * PUPIL_SCALE_RIGHT else PUPIL_SIZE
		ball(ctx, skull, sideName(side) .. "Pupil", at(side * EYE_X, 0, 0), size, PAINT_PUPIL)
	end
	-- the black inside the skull behind the slit: what the split mask opens onto
	ball(ctx, skull, "Throat", at(THROAT.X, THROAT.Y, THROAT.Z), 0.52, PAINT_SHADOW_SMALL)

	-- the neck: a long thin column with two straining tendons, carried by the chest
	local chest = ctx.parts.UpperTorso
	local axis = (skullBase - neckBase).Unit
	rod(ctx, chest, "NeckColumn", neckBase - axis * 0.16, skullBase + axis * 0.06, 0.25, PAINT_SHADOW)
	ball(ctx, chest, "NeckTop", skullBase, 0.27, PAINT_SHADOW)
	for _, side in { -1, 1 } do
		rod(
			ctx,
			chest,
			sideName(side) .. "NeckTendon",
			skullBase + Vector3.new(side * 0.1, -0.12, -0.06),
			torso * Vector3.new(side * 0.07, TORSO_LENGTH - 0.08, -0.16),
			0.065,
			PAINT_SHADOW_SMALL
		)
	end
	smokeAnchor(ctx, skull, "SmokeHead", at(0, CRANIUM_Y - 0.1, CRANIUM_Z + CRANIUM_RADIUS + 0.05), 0.6)
	return head
end

-- The lower mask on its hinge: a porcelain ball under the slit (the Jaw part itself) with the chin tapering to a point
-- below it. The ball's cap above the seam hides inside the upper mask; the black sleeve (MouthVoidLower) covers it
-- when the split opens, so no porcelain shows inside the split.
local function buildJaw(ctx: Ctx, head: CFrame)
	local jaw = rigPart(
		ctx,
		"Jaw",
		CFrame.new(head * CHIN_CENTRE),
		Vector3.one * CHIN_RADIUS * 2,
		PAINT_MASK,
		Enum.PartType.Ball
	)
	ball(ctx, jaw, "Chin", head * CHIN_TIP, CHIN_TIP_RADIUS * 2, PAINT_MASK)
	ctx.pivots.Jaw = head * JAW_HINGE
end

-- Face-frame point on Roblox's mask shell over (x, y) and its outward normal: on the cylinder between the slit and the
-- brow, on the brow dome above it, below the slit on the jaw ball or the chin, whichever stands further out. `jaw`
-- names the half when the caller knows it (a strip rides the half its limb carries), so a point on the slit itself is
-- never placed by the side of it a float rounding lands on; without it the point's own height decides.
local function maskSurface(x: number, y: number, jaw: boolean?): (Vector3, Vector3)
	local function onBall(centre: Vector3, radius: number): (Vector3, Vector3, boolean)
		local dx, dy = x - centre.X, y - centre.Y
		local inside = radius * radius - dx * dx - dy * dy
		local point = Vector3.new(x, y, centre.Z - math.sqrt(math.max(inside, 0)))
		return point, (point - centre).Unit, inside > 0
	end
	local lower = if jaw == nil then y < SLIT_Y else jaw
	if not lower then
		if y > MASK_TOP then
			local point, normal = onBall(Vector3.new(0, MASK_TOP, MASK_Z), MASK_RADIUS)
			return point, normal
		end
		local z = MASK_Z - math.sqrt(math.max(MASK_RADIUS ^ 2 - x * x, 0))
		return Vector3.new(x, y, z), Vector3.new(x, 0, z - MASK_Z).Unit
	end
	local point, normal, onJaw = onBall(CHIN_CENTRE, CHIN_RADIUS)
	local tip, tipNormal, onTip = onBall(CHIN_TIP, CHIN_TIP_RADIUS)
	if onTip and (not onJaw or tip.Z < point.Z) then
		return tip, tipNormal
	end
	return point, normal
end

-- A thin strip `name` on the shell from face-frame a2 to b2, `width` across and `lift` proud of the surface of the
-- half `limb` carries (the jaw's below the slit, the head's above it): both ends ride that half, a seam end too.
local function surfaceStrip(
	ctx: Ctx,
	head: CFrame,
	limb: BasePart,
	name: string,
	a2: Vector2,
	b2: Vector2,
	width: number,
	lift: number,
	paint: Paint
): BasePart
	local jaw = limb == ctx.parts.Jaw
	local a, na = maskSurface(a2.X, a2.Y, jaw)
	local b, nb = maskSurface(b2.X, b2.Y, jaw)
	local out = rotate(head, (na + nb).Unit)
	local from, to = head * a + out * lift, head * b + out * lift
	return block(
		ctx,
		limb,
		name,
		frameZ((from + to) / 2, to - from, out),
		Vector3.new(width, CRACK_THICKNESS, (to - from).Magnitude + width * 0.5),
		paint
	)
end

-- A polyline's segments, split where they cross the seam so each piece rides the half of the mask it lies on (the cut
-- point in Luau's doubles: the same on every platform; which half each piece rides is its limb's, see surfaceStrip).
local function seamSegments(points: { Vector2 }): { { Vector2 } }
	local out: { { Vector2 } } = {}
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		if (a.Y - SLIT_Y) * (b.Y - SLIT_Y) < 0 then
			local cut = MathUtil.lerpVector2(a, b, (SLIT_Y - a.Y) / (b.Y - a.Y))
			table.insert(out, { a, cut })
			table.insert(out, { cut, b })
		else
			table.insert(out, { a, b })
		end
	end
	return out
end

-- The relief Roblox draws with porcelain parts sunk into the shell (the web sculpts the same bumps from MaskRelief):
-- a long bump is a cylinder ridge along its tilt, a round one a ball whose cap stands its height proud of the shell.
-- The hollows (sockets, sunken cheeks, temples) Roblox paints darker with the grime (buildMaskGrime).
local function buildRelief(ctx: Ctx, head: CFrame)
	for _, name in reliefNames do
		local f = MASK_RELIEF[name]
		local cx, cy, rx, ry, height, tilt = f[1], f[2], f[3], f[4], f[5], math.rad(f[6])
		if height <= 0 or name == "Forehead" then
			continue
		end
		local limb = if cy < SLIT_Y then ctx.parts.Jaw else ctx.parts.Head
		local long, short = math.max(rx, ry), math.min(rx, ry)
		if long > short * 1.8 then
			local along = if rx >= ry
				then Vector2.new(math.cos(tilt), math.sin(tilt))
				else Vector2.new(-math.sin(tilt), math.cos(tilt))
			local radius = short * 1.25
			local a2 = Vector2.new(cx, cy) - along * long
			local b2 = Vector2.new(cx, cy) + along * long
			local a, na = maskSurface(a2.X, a2.Y)
			local b, nb = maskSurface(b2.X, b2.Y)
			local mid = maskSurface(cx, cy)
			-- the chord sags under the curved shell: lift it so the ridge's middle stands its full height
			local sag = math.max(0, (mid - (a + b) / 2):Dot(-(na + nb).Unit))
			local sink = radius - height - sag
			rod(ctx, limb, "Relief" .. name, head * (a - na * sink), head * (b - nb * sink), radius * 2, PAINT_MASK)
		else
			local footprint = (rx + ry) / 2
			local radius = (footprint * footprint + height * height) / (2 * height)
			local point, normal = maskSurface(cx, cy)
			ball(ctx, limb, "Relief" .. name, head * (point + normal * (height - radius)), radius * 2, PAINT_MASK)
		end
	end
end

-- Grime on Roblox: a SurfaceGui of soft frames on an invisible card over each half of the face (soot pooled in the
-- socket and down the weeping streak, the porcelain yellowed toward the rim). Roblox caps a texture at 1024 pixels and
-- builds no MeshParts from code, so the relief is parts and the grime is this decal (GRIME_PPS pixels per stud keeps
-- the canvas small); the web paints both in its mask shader.
local GRIME_CARD = Vector2.new(0.26, 0.44)
local GRIME_PPS = 400
local function buildMaskGrime(ctx: Ctx, head: CFrame)
	local skull = ctx.parts.Head
	for _, side in { -1, 1 } do
		local point, normal = maskSurface(side * EYE_X, -0.06)
		local out = rotate(head, normal)
		local centre = head * point + out * 0.004
		local card = block(
			ctx,
			skull,
			"MaskGrime" .. sideName(side),
			frameZ(centre, -out, rotate(head, Vector3.yAxis)),
			Vector3.new(GRIME_CARD.X, GRIME_CARD.Y, 0.002),
			PAINT_GRIME_CARD
		)
		local gui = Instance.new("SurfaceGui")
		gui.Name = "Grime"
		gui.Face = Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = GRIME_PPS
		gui.LightInfluence = 1
		gui.MaxDistance = 60
		gui.ClipsDescendants = true
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.Parent = card
		-- the canvas is about 104 x 176 pixels, the eye hole at (0.5, 0.36): every frame is symmetric about x = 0.5
		local soot = MathUtil.lerpColor(GRIME_COLOR, Color3.new(), 0.7)
		SurfaceArt.stain(gui, 0.5, 0.36, 0.95, 0.42, soot, 0.62, nil, 1)
		SurfaceArt.stain(gui, 0.5, 0.36, 0.7, 0.28, soot, 0.4, nil, 2)
		SurfaceArt.streak(gui, 0.5, 70, 8, 96, soot, 0.6, 3)
		SurfaceArt.grime(gui, GRIME_COLOR, 0.3, false, 0)
	end
end

-- The mask's detail drawn in parts, for Roblox (all Fabric but the jagged maw: the web hides that chunk and paints the
-- same detail with depth): an almond eye hole of two black discs round each pinprick, the half-smiling slit in black
-- strips, black caps and a sleeve on the faces the split opens, the cracks (CrackFrom / CrackTo / CrackWidth) and the
-- weeping streaks (StreakFrom / StreakTo / StreakWidth) as dark strips carrying their face-frame ends, the chipped
-- edge as black over the rim, and the porcelain shards the open split bares (MawShard<N>, hidden inside the shell
-- while the mask is shut).
local function buildMaskDetail(ctx: Ctx, head: CFrame)
	local skull = ctx.parts.Head
	local jaw = ctx.parts.Jaw
	local function onSurface(limb: BasePart, name: string, x: number, y: number, diameter: number, paint: Paint)
		local point, normal = maskSurface(x, y)
		local axis = rotate(head, normal)
		local centre = head * (point + normal * 0.002)
		rod(ctx, limb, name, centre - axis * 0.006, centre + axis * 0.006, diameter, paint)
	end
	local function limbFor(a: Vector2, b: Vector2): BasePart
		return if (a.Y + b.Y) / 2 < SLIT_Y then jaw else skull
	end
	for _, side in { -1, 1 } do
		local prefix = sideName(side)
		onSurface(skull, prefix .. "EyeHole", side * EYE_X, 0, EYE_HOLE.Y * 2, PAINT_VOID)
		-- the outer corner droops
		onSurface(skull, prefix .. "EyeHoleCorner", side * (EYE_X + 0.05), -0.02, EYE_HOLE.Y * 1.35, PAINT_VOID)
	end
	-- the slit: four strips along the seam, the right corner curling up into the wrong half-smile
	local function slitAt(x: number): Vector2
		local corner = math.clamp((x - SLIT_HALF_WIDTH * 0.35) / (SLIT_HALF_WIDTH * 0.65), 0, 1)
		return Vector2.new(x, SLIT_Y + 0.004 + SLIT_UPTURN * corner * corner)
	end
	local edges =
		{ -SLIT_HALF_WIDTH, -SLIT_HALF_WIDTH / 3, SLIT_HALF_WIDTH * 0.35, SLIT_HALF_WIDTH * 0.72, SLIT_HALF_WIDTH }
	for i = 1, #edges - 1 do
		surfaceStrip(
			ctx,
			head,
			skull,
			string.format("MouthSlit%d", i),
			slitAt(edges[i]),
			slitAt(edges[i + 1]),
			0.016,
			0.003,
			PAINT_VOID
		)
	end
	-- black over the faces the split opens: a cap under the upper mask, a sleeve over the jaw ball's cap above the seam
	local up = rotate(head, Vector3.yAxis)
	local under = head * Vector3.new(0, SLIT_Y - 0.004, MASK_Z)
	rod(ctx, skull, "MouthVoidUpper", under - up * 0.003, under + up * 0.003, MASK_RADIUS * 2 - 0.02, PAINT_VOID)
	local capTop = CHIN_CENTRE.Y + CHIN_RADIUS
	rod(
		ctx,
		jaw,
		"MouthVoidLower",
		head * Vector3.new(0, SLIT_Y + 0.002, CHIN_CENTRE.Z),
		head * Vector3.new(0, capTop + 0.01, CHIN_CENTRE.Z),
		SLEEVE_RADIUS * 2,
		PAINT_VOID
	)
	-- the cracks and the weeping streaks
	local count = 0
	for _, path in CRACKS do
		for _, segment in seamSegments(path.points) do
			count += 1
			local a2, b2 = segment[1], segment[2]
			local crack = surfaceStrip(
				ctx,
				head,
				limbFor(a2, b2),
				string.format("MaskCrack%d", count),
				a2,
				b2,
				path.width,
				0.0015,
				PAINT_CRACK
			)
			crack:SetAttribute("CrackFrom", a2)
			crack:SetAttribute("CrackTo", b2)
			crack:SetAttribute("CrackWidth", path.width)
		end
	end
	count = 0
	for _, path in STREAKS do
		for _, segment in seamSegments(path.points) do
			count += 1
			local a2, b2 = segment[1], segment[2]
			local streak = surfaceStrip(
				ctx,
				head,
				limbFor(a2, b2),
				string.format("MaskStreak%d", count),
				a2,
				b2,
				path.width,
				0.001,
				PAINT_STREAK
			)
			streak:SetAttribute("StreakFrom", a2)
			streak:SetAttribute("StreakTo", b2)
			streak:SetAttribute("StreakWidth", path.width)
		end
	end
	-- the chipped edge: the black behind it, two discs over the rim where the piece broke away
	local chipAxis = Vector2.new(math.cos(math.rad(CHIP_ANGLE)), math.sin(math.rad(CHIP_ANGLE)))
	for i, offset in { -0.35, 0.4 } do
		local at2 = CHIP_CENTRE + chipAxis * CHIP_RADIUS.X * offset
		onSurface(skull, string.format("MaskChip%d", i), at2.X, at2.Y, CHIP_RADIUS.Y * (2.4 - i * 0.5), PAINT_VOID)
	end
	-- the porcelain the open split bares: jagged shards hanging from the upper mask's edge into the chin and rising from
	-- the chin's into the upper mask, inside the shell while it is shut
	for i, shard in MAW_SHARDS do
		local x, length, width, hang = shard[1], shard[2], shard[3], shard[4]
		local limb = if hang > 0 then skull else jaw
		local radius = if hang > 0 then CHIN_RADIUS - 0.03 else (SLEEVE_RADIUS + MASK_RADIUS) / 2
		local axisZ = if hang > 0 then CHIN_CENTRE.Z else MASK_Z
		local z = axisZ - math.sqrt(math.max(radius * radius - x * x, 0))
		local base = Vector3.new(x, SLIT_Y, z)
		local tip = base - Vector3.yAxis * hang * length
		local normal = Vector3.new(x, 0, z - axisZ).Unit
		-- a WedgePart seen along its X axis is a right triangle: X faces out of the mask, the triangle's base lies on
		-- the seam and its point runs away from it
		local centre = head * ((base + tip) / 2)
		local outward = rotate(head, normal)
		local along = rotate(head, -Vector3.yAxis * hang)
		local shardPart = wedge(
			ctx,
			limb,
			string.format("MawShard%d", i),
			CFrame.fromMatrix(centre, outward, along, outward:Cross(along)),
			Vector3.new(0.012, length, width),
			PAINT_MASK
		)
		shardPart:SetAttribute("MawSide", if hang > 0 then "Upper" else "Lower")
	end
end

-- The tatters: black strips hanging from the skull around the back of the mask, each a chain of segments jointed
-- to the Head for a later sway, with a stray strand peeling off every segment.
local function buildTatters(ctx: Ctx, head: CFrame)
	local centre = Vector3.new(0, CRANIUM_Y, CRANIUM_Z)
	for index, clump in TATTERS do
		local azimuth = math.rad(clump.azimuth)
		local elevation = math.rad(clump.elevation)
		local outwardLocal = Vector3.new(math.sin(azimuth), 0, math.cos(azimuth))
		local onSkull = Vector3.new(
			math.sin(azimuth) * math.cos(elevation),
			math.sin(elevation),
			math.cos(azimuth) * math.cos(elevation)
		)
		local pivot = head * (centre + onSkull * (CRANIUM_RADIUS + HAIR_THICKNESS / 2))
		local outward = rotate(head, outwardLocal)
		outward = Vector3.new(outward.X, 0, outward.Z).Unit
		local width = clump.width
		for segment, length in clump.lengths do
			local name = hairName(index, segment)
			local jitter = Vector3.new(ctx.random:NextNumber(-0.04, 0.04), 0, ctx.random:NextNumber(-0.04, 0.04))
			local direction = (Vector3.new(0, -1, 0) + outward * clump.splay[segment] + jitter).Unit
			local tip = pivot + direction * length
			-- twisted about its length, so no clump turns a flat face to the light: hanks of hair, not planks
			local tangent0 = direction:Cross(outward).Unit
			local twist = math.rad(ctx.random:NextNumber(-55, 55))
			local hang = rigPart(
				ctx,
				name,
				frameY((pivot + tip) / 2, -direction, outward * math.cos(twist) + tangent0 * math.sin(twist)),
				Vector3.new(width, length, HAIR_THICKNESS),
				PAINT_SHADOW
			)
			ctx.pivots[name] = pivot
			-- a stray strand peeling off one edge, lankier and longer than the strip
			local tangent = direction:Cross(outward).Unit
			local edge = if (index + segment) % 2 == 0 then -1 else 1
			local strandLength = length * ctx.random:NextNumber(0.95, 1.25)
			local strandDirection = (
				direction
				+ tangent * edge * ctx.random:NextNumber(0.03, 0.1)
				+ outward * ctx.random:NextNumber(-0.02, 0.05)
			).Unit
			local start = pivot + tangent * edge * (width / 2 + ctx.random:NextNumber(0.01, 0.03))
			block(
				ctx,
				hang,
				name .. "Strand",
				frameY(start + strandDirection * (strandLength / 2), -strandDirection, outward),
				Vector3.new(STRAND_WIDTH, strandLength, STRAND_THICKNESS),
				PAINT_SHADOW_SMALL
			)
			pivot = tip
			width *= 0.6
		end
	end
end

--------------------------------------------------------------------------------
-- Limbs
--------------------------------------------------------------------------------

-- One long tapering finger: the jointed proximal segment, the middle and distal segments and a pointed tip welded to
-- it. `bend(degrees)` gives the finger's direction curled that far toward the palm. Returns the fingertip.
local function buildFinger(
	ctx: Ctx,
	name: string,
	base: Vector3,
	length: number,
	bend: (number) -> Vector3,
	dorsal: Vector3
): Vector3
	local directions = { bend(SEGMENT_CURL[1]), bend(SEGMENT_CURL[2]), bend(SEGMENT_CURL[3]) }
	local joints = { base }
	for i = 1, 3 do
		table.insert(joints, joints[i] + directions[i] * (length * SEGMENT_SHARE[i]))
	end
	local finger = rigRod(ctx, name, base - directions[1] * 0.02, joints[2], SEGMENT_DIAMETER[1], PAINT_SHADOW_SMALL)
	ctx.pivots[name] = base
	ball(ctx, finger, name .. "Knuckle", base + dorsal * 0.02, SEGMENT_DIAMETER[1] + 0.03, PAINT_BONE_SMALL)
	rod(ctx, finger, name .. "Middle", joints[2], joints[3], SEGMENT_DIAMETER[2], PAINT_SHADOW_SMALL)
	rod(ctx, finger, name .. "Distal", joints[3], joints[4], SEGMENT_DIAMETER[3], PAINT_SHADOW_SMALL)
	-- the point: a slim wedge tapering to nothing past the last joint
	local tipDirection = bend(SEGMENT_CURL[3] + 6)
	local centre = joints[4] + tipDirection * (TIP_LENGTH / 2 - 0.01)
	wedge(
		ctx,
		finger,
		name .. "Point",
		frameZ(centre, -tipDirection, dorsal),
		Vector3.new(TIP_WIDTH, TIP_WIDTH, TIP_LENGTH),
		PAINT_SHADOW_SMALL
	)
	return joints[4] + tipDirection * (TIP_LENGTH - 0.02)
end

local function buildArm(ctx: Ctx, torso: CFrame, side: number)
	local prefix = sideName(side)
	local outward = Vector3.new(side, 0, 0)
	local shoulder = torso * Vector3.new(side * SHOULDER.X, SHOULDER.Y, SHOULDER.Z)
	local upperDir = Vector3.new(side * 0.07, -1, 0.03).Unit
	local elbow = shoulder + upperDir * UPPER_ARM
	local foreDir = Vector3.new(side * 0.02, -1, -0.13).Unit
	local wrist = elbow + foreDir * FOREARM
	local handDir = Vector3.new(-side * 0.03, -1, -0.07).Unit
	local knuckles = wrist + handDir * PALM
	ctx.pivots[prefix .. "Shoulder"] = shoulder
	ctx.pivots[prefix .. "Elbow"] = elbow
	ctx.pivots[prefix .. "Wrist"] = wrist

	-- each limb tapers: a thicker rod over its upper half, a thinner one down to the joint below
	local upper = rigRod(
		ctx,
		prefix .. "UpperArm",
		shoulder - upperDir * 0.08,
		shoulder + upperDir * UPPER_ARM * 0.55,
		0.3,
		PAINT_SHADOW
	)
	rod(ctx, upper, prefix .. "Bicep", shoulder + upperDir * UPPER_ARM * 0.4, elbow, 0.22, PAINT_SHADOW)
	ball(ctx, upper, prefix .. "ShoulderKnob", shoulder + Vector3.new(side * 0.02, 0.05, 0), 0.36, PAINT_BONE)

	local lower = rigRod(ctx, prefix .. "LowerArm", elbow, elbow + foreDir * FOREARM * 0.5, 0.21, PAINT_SHADOW)
	rod(ctx, lower, prefix .. "Forearm", elbow + foreDir * FOREARM * 0.4, wrist + foreDir * 0.03, 0.15, PAINT_SHADOW)
	local foreBack = orthogonal(Vector3.zAxis, foreDir)
	ball(ctx, lower, prefix .. "ElbowKnob", elbow + foreBack * 0.05, 0.2, PAINT_BONE)
	ball(ctx, lower, prefix .. "WristKnob", wrist - foreDir * 0.04 + foreBack * 0.03, 0.11, PAINT_BONE_SMALL)

	-- The palm faces the thigh; `across` runs over the knuckles from the index (front) to the pinky (back).
	local inward = orthogonal(-outward, handDir)
	local dorsal = -inward
	local across = orthogonal(orthogonal(Vector3.zAxis, handDir), inward)
	rigPart(
		ctx,
		prefix .. "Hand",
		frameY(wrist + handDir * (PALM / 2), -handDir, across),
		Vector3.new(0.09, PALM, 0.27),
		PAINT_SHADOW
	)

	for _, finger in FINGERS do
		local name = prefix .. finger.name
		local base = knuckles - handDir * finger.inset + across * finger.offset
		local fan = across * math.tan(math.rad(finger.spread))
		local function bend(degrees: number): Vector3
			local angle = math.rad(degrees + finger.curl)
			return (handDir * math.cos(angle) + inward * math.sin(angle) + fan).Unit
		end
		local tip = buildFinger(ctx, name, base, FINGER * finger.scale, bend, dorsal)
		smokeAnchor(ctx, ctx.parts[name], "Smoke" .. name .. "Tip", tip, 0.55)
	end

	local thumbBase = wrist + handDir * (PALM * 0.3) - across * 0.12 + inward * 0.04
	local function thumbBend(degrees: number): Vector3
		local angle = math.rad(degrees)
		return (handDir * 0.62 * math.cos(angle) - across * 0.5 + inward * (0.6 + math.sin(angle))).Unit
	end
	buildFinger(ctx, prefix .. THUMB, thumbBase, FINGER * 0.62, thumbBend, dorsal)

	smokeAnchor(ctx, upper, "Smoke" .. prefix .. "Shoulder", shoulder + Vector3.new(side * 0.05, 0.16, 0.04), 1)
	smokeAnchor(ctx, lower, "Smoke" .. prefix .. "Elbow", elbow + foreBack * 0.12, 0.7)
end

local function buildLeg(ctx: Ctx, side: number)
	local prefix = sideName(side)
	local hip = Vector3.new(side * HIP_X, HIP_Y, PELVIS_Z)
	local knee = Vector3.new(side * KNEE.X, KNEE.Y, KNEE.Z)
	local ankle = Vector3.new(side * ANKLE.X, ANKLE.Y, ANKLE.Z)
	ctx.pivots[prefix .. "Hip"] = hip
	ctx.pivots[prefix .. "Knee"] = knee
	ctx.pivots[prefix .. "Ankle"] = ankle

	local thighDir = (knee - hip).Unit
	local shinDir = (ankle - knee).Unit
	local thighLength = (knee - hip).Magnitude
	local shinLength = (ankle - knee).Magnitude
	local thigh =
		rigRod(ctx, prefix .. "UpperLeg", hip - thighDir * 0.1, hip + thighDir * thighLength * 0.55, 0.36, PAINT_SHADOW)
	rod(ctx, thigh, prefix .. "Thigh", hip + thighDir * thighLength * 0.4, knee, 0.26, PAINT_SHADOW)
	ball(ctx, thigh, prefix .. "HipJoint", hip + Vector3.new(side * 0.02, 0, 0), 0.36, PAINT_SHADOW)
	smokeAnchor(ctx, thigh, "Smoke" .. prefix .. "Hip", hip + Vector3.new(side * 0.2, -0.05, -0.05), 0.9, true)
	smokeAnchor(
		ctx,
		thigh,
		"Smoke" .. prefix .. "Thigh",
		hip + thighDir * thighLength * 0.45 + Vector3.new(side * 0.12, 0, 0),
		0.7,
		true
	)
	local shin = rigRod(ctx, prefix .. "LowerLeg", knee, knee + shinDir * shinLength * 0.5, 0.25, PAINT_SHADOW)
	rod(ctx, shin, prefix .. "Shin", knee + shinDir * shinLength * 0.4, ankle + shinDir * 0.1, 0.17, PAINT_SHADOW)
	ball(ctx, shin, prefix .. "KneeJoint", knee, 0.27, PAINT_SHADOW)
	ball(ctx, shin, prefix .. "KneeCap", knee + Vector3.new(0, 0.05, -0.11), 0.17, PAINT_BONE)
	ball(ctx, shin, prefix .. "AnkleKnob", ankle + Vector3.new(side * 0.08, -0.02, 0.01), 0.11, PAINT_BONE_SMALL)

	-- Foot-local: origin on the floor under the ankle, toes turned slightly out. A narrow sole with a steep instep,
	-- the heel knob behind and three long toes gripping the floor ahead.
	local foot = CFrame.new(ankle.X, 0, ankle.Z) * CFrame.Angles(0, -side * TOE_OUT, 0)
	local footPart =
		rigPart(ctx, prefix .. "Foot", foot * CFrame.new(0, 0.05, -0.28), Vector3.new(0.24, 0.1, 0.9), PAINT_SHADOW)
	wedge(
		ctx,
		footPart,
		prefix .. "Instep",
		foot * CFrame.new(0, 0.2, -0.3),
		Vector3.new(0.22, 0.2, 0.62),
		PAINT_SHADOW
	)
	ball(ctx, footPart, prefix .. "Heel", foot * Vector3.new(0, 0.12, 0.1), 0.24, PAINT_SHADOW)
	local droop = math.rad(12)
	for i, toe in TOES do
		local height = 0.06
		local splay = side * math.rad((i - 2) * 4)
		local direction =
			Vector3.new(-math.sin(splay) * math.cos(droop), -math.sin(droop), -math.cos(splay) * math.cos(droop))
		-- the front-bottom edge of each toe rests on the floor
		local centreY = toe.length / 2 * math.sin(droop) + height / 2 * math.cos(droop)
		local start = Vector3.new(side * toe.x, centreY + toe.length / 2 * math.sin(droop), -0.7)
		local centre = start + direction * (toe.length / 2)
		block(
			ctx,
			footPart,
			string.format("%sToe%d", prefix, i),
			foot * frameZ(centre, -direction, Vector3.yAxis),
			Vector3.new(toe.width, height, toe.length),
			PAINT_SHADOW_SMALL
		)
	end
end

--------------------------------------------------------------------------------
-- Hitbox, joints, Humanoid
--------------------------------------------------------------------------------

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
		random = Rng.seeded(RIG_SEED, RIG_KIND),
		parts = {},
		pivots = {},
	}
	buildRoot(ctx)
	buildPelvis(ctx)
	local torso = buildTorso(ctx)
	local head = buildHead(ctx, torso)
	buildJaw(ctx, head)
	buildRelief(ctx, head)
	buildMaskDetail(ctx, head)
	buildMaskGrime(ctx, head)
	buildTatters(ctx, head)
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
