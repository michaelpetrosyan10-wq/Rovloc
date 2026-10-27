--!strict
-- BearTrapBuilder: the rusted leg-hold traps of the Level 0 gauntlet (plan prop kind "BearTrap": RunDirector picks
-- DifficultyConfig.trapCount TrapCandidate anchors per run; ctx.prop.cframe is the floor point).
--
-- Anatomy, in trap space (X = the hinge / long axis, Y up, Z across, origin on the floor point; the whole trap takes
-- a random yaw from ctx.random, its rust tint comes from the plan variant):
--   * Frame ("Base" and fixed parts): a long base bar whose ends are the lower leaves of the two V springs (with
--     their bends), a cross plate under the pan, a hinge post at each end of the jaws, the pan post and the dog's
--     pivot ear.
--   * JawA / JawB (leaves): serrated semicircular bows of five straight segments, saw teeth on the middle three,
--     each hinged on its own line parallel to X either side of the centre plane. Rest pose = SNAPPED: both bows stand
--     up in the vertical plane with their gripping faces GRIP_GAP either side of it, so the staggered teeth
--     interlock. Armed = each bow turned a quarter turn about its hinge to lie flat on the frame, teeth up, A toward
--     +Z and B toward -Z. setJaws(model, openness) poses them (1 = armed flat, 0 = snapped).
--   * SpringA / SpringB (leaves): the upper leaf and eye of each V spring, pivoting on the spring's bend. Rest =
--     released (the eye high on the post, as after a snap); armed = pressed down to the foot of the post. setJaws
--     moves them with the jaws.
--   * Pan (leaf): the round pressure pan, hinged on its +Z edge at the pan post. Rest = level; setPan(model,
--     depressed) tips its free edge down.
--   * The dog lies across armed JawB with its tip on the pan's free edge; a short chain wanders (ctx.random) from the
--     -X spring end to a stake head driven into the floor.
--   * TriggerVolume: a NoCollide volume over the jaws (2.2 x 2.2, from 0.5 below the floor to 3.5 above it, so both
--     a walker's feet point and root are inside) for the server's 10 Hz point-in-box test; never Touched. Attachment "LegPoint" on Base, over the pan centre, is where a caught leg is
--     held; Attachment "PromptPoint" hosts the disabled TrapPry (solo, GameConfig.TrapSoloPrySeconds) and TrapRescue
--     (teammate, GameConfig.TrapRescueSeconds) prompts.
-- Every visible part is a PropKit.detail (players walk onto the trap; nothing collides or is queried). Model
-- attributes: Armed = true, AnchorId, LevelId (TrappedUserId is written by the trap system when it snaps). Tags:
-- BearTrap, Interactable. Budget: 39 parts (MAX_PARTS 40).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)

local Geometry = require(script.Parent.Parent.Geometry)
local Palette = require(script.Parent.Parent.Palette)
local PropKit = require(script.Parent.PropKit)

local W = Attributes.World

local KIND = "BearTrap"
local MAX_PARTS = 40

-- Frame
local BASE_THICK = 0.06
local BASE_WIDTH = 0.22
local JAW_RADIUS = 0.9 -- bow centre line: trap centre to each hinge post
local SPRING_REACH = 0.75 -- hinge post to spring bend, along X
local BEND_X = JAW_RADIUS + SPRING_REACH
local BEND_Y = 0.09
local BEND_DIAMETER = 0.1
local BASE_HALF = BEND_X + 0.03
local POST_SIZE = Vector3.new(0.12, 0.3, 0.48)
local CROSS_THICK = 0.045 -- below the base bar's top, so the two plates never share a face
local CROSS_WIDTH = 0.2

-- Jaws
local JAW_BAND = 0.16 -- bow width: vertical when armed, along Z when snapped
local JAW_THICK = 0.06 -- radial
local JAW_SEGMENTS = 5
local TOOTH_LENGTH = 0.09
local TOOTH_WIDTH = 0.12
local GRIP_GAP = TOOTH_LENGTH / 2 + 0.005 -- each snapped gripping face's distance from the centre plane
local HINGE_Y = BASE_THICK + JAW_BAND / 2 -- armed bows lie on the frame: bottom at BASE_THICK
local HINGE_Z = GRIP_GAP + JAW_BAND / 2
local JAW_OPEN_ANGLE = math.pi / 2
-- Tooth positions in degrees along each bow (0 and 180 are the hinges; the end segments are plain). B's sit 12
-- degrees off A's, so the snapped teeth mesh without touching, and B leaves its middle clear where the dog crosses.
local TEETH_A: { number } = { 54, 78, 102, 126 }
local TEETH_B: { number } = { 42, 66, 114, 138 }

-- Springs
local SPRING_LEAF = Vector3.new(SPRING_REACH, 0.04, 0.16)
local SPRING_EYE = Vector3.new(0.2, 0.07, POST_SIZE.Z + 0.08)
local SPRING_RELEASED = math.rad(14) -- rest: the eye rides high on the post
local SPRING_PRESSED = math.rad(2) -- armed: pressed nearly flat

-- Pan and dog
local PAN_RADIUS = 0.34
local PAN_THICK = 0.04
local PAN_Y = 0.18 -- centre height; the top sits level with the armed bows
local PAN_TILT = math.rad(8) -- fully depressed
local PAN_POST_DEPTH = 0.08
local DOG_THICK = 0.025
local DOG_WIDTH = 0.08
local DOG_PIVOT_Z = -(HINGE_Z + JAW_RADIUS + JAW_THICK / 2 + 0.08) -- just outside armed JawB
local DOG_PIVOT_Y = 0.245 -- clears armed JawB's top edge where the dog crosses it
local DOG_TIP_Z = -(PAN_RADIUS - 0.04)
local DOG_TIP_Y = PAN_Y + PAN_THICK / 2 + DOG_THICK / 2 -- resting on the pan's free edge

-- Chain and stake
local CHAIN_LINKS = 4
local LINK_LENGTH = 0.24
local LINK_WIDTH = 0.1
local LINK_WIRE = 0.035
local LINK_PITCH = 0.17 -- centre to centre: neighbouring links overlap where they interlock
local CHAIN_SWAY = 0.3 -- radians of heading change per link
local CHAIN_SPREAD = 0.9 -- the chain never turns back more than this from straight out along -X
local STAKE_DIAMETER = 0.11
local STAKE_HEIGHT = 0.26
local STAKE_HEAD_DIAMETER = 0.2
local STAKE_HEAD_THICK = 0.05

-- Gameplay. The trigger spans the floor: a walker's feet point (floor level) and root (about 3 studs up) both sit
-- well inside it, never on a face, whichever of the two the point-in-box test uses.
local TRIGGER_SIZE = Vector3.new(2.2, 4, 2.2)
local TRIGGER_BOTTOM = -0.5
local LEG_POINT_Y = 0.3
local PROMPT_Y = 0.4

local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- a cylinder's axis (local X) turned to +Y
local ACROSS = CFrame.Angles(0, math.pi / 2, 0) -- a cylinder's axis turned to Z

local NAMES = table.freeze({
	JawA = "JawA",
	JawB = "JawB",
	SpringA = "SpringA",
	SpringB = "SpringB",
	Pan = "Pan",
	TriggerVolume = "TriggerVolume",
	LegPoint = "LegPoint",
	PromptPoint = "PromptPoint",
})

local PRY_PROMPT: PropKit.PromptSpec = {
	kind = "TrapPry",
	action = "Prompt.TrapPry",
	object = "Prompt.Trap",
	hold = GameConfig.TrapSoloPrySeconds,
}

local RESCUE_PROMPT: PropKit.PromptSpec = {
	kind = "TrapRescue",
	action = "Prompt.TrapRescue",
	object = "Prompt.Trap",
	hold = GameConfig.TrapRescueSeconds,
}

type Tint = {
	frame: Color3,
	jaw: Color3,
	tooth: Color3,
	spring: Color3,
	chain: Color3,
}

local BearTrapBuilder = {}

BearTrapBuilder.Kind = KIND
BearTrapBuilder.MaxParts = MAX_PARTS
BearTrapBuilder.Names = NAMES
BearTrapBuilder.JawOpenAngle = JAW_OPEN_ANGLE
BearTrapBuilder.SpringTravel = SPRING_RELEASED - SPRING_PRESSED
BearTrapBuilder.PanTilt = PAN_TILT
BearTrapBuilder.TriggerSize = TRIGGER_SIZE

--------------------------------------------------------------------------------
-- Poses
--------------------------------------------------------------------------------

-- A pose fraction clamped to [0, 1]; NaN reads as 0 (the rest pose), so a broken tween can never write NaN CFrames.
local function fraction(value: number): number
	if value ~= value then
		return 0
	end
	return math.clamp(value, 0, 1)
end

-- Poses both jaws (and the springs that drive them): 1 = armed, laid open flat; 0 = snapped shut (the rest pose).
-- Pure: the result depends only on `openness`. Returns false when the model is missing a leaf.
function BearTrapBuilder.setJaws(model: Model, openness: number): boolean
	local open = fraction(openness)
	local angle = open * JAW_OPEN_ANGLE
	local press = open * (SPRING_RELEASED - SPRING_PRESSED)
	local jawA = PropKit.poseLeaf(model, NAMES.JawA, CFrame.Angles(angle, 0, 0))
	local jawB = PropKit.poseLeaf(model, NAMES.JawB, CFrame.Angles(-angle, 0, 0))
	local springA = PropKit.poseLeaf(model, NAMES.SpringA, CFrame.Angles(0, 0, press))
	local springB = PropKit.poseLeaf(model, NAMES.SpringB, CFrame.Angles(0, 0, -press))
	return jawA and jawB and springA and springB
end

-- Tips the pressure pan about its hinge: 0 = level (rest), 1 = fully depressed. Pure, like setJaws.
function BearTrapBuilder.setPan(model: Model, depressed: number): boolean
	return PropKit.poseLeaf(model, NAMES.Pan, CFrame.Angles(-fraction(depressed) * PAN_TILT, 0, 0))
end

--------------------------------------------------------------------------------
-- Parts
--------------------------------------------------------------------------------

local function tintOf(variant: number): Tint
	local finite = variant == variant and math.abs(variant) ~= math.huge
	local random = MathUtil.seededRandom(if finite then variant else 0, "BearTrap:tint")
	local iron = Palette.get("Iron").color
	local rust = Palette.get("MetalRust").color
	local steel = Palette.get("TrimMetal").color
	return {
		frame = iron:Lerp(rust, random:NextNumber(0.2, 0.6)),
		jaw = iron:Lerp(rust, random:NextNumber(0.4, 0.9)),
		tooth = steel:Lerp(rust, random:NextNumber(0.25, 0.55)),
		spring = iron:Lerp(rust, random:NextNumber(0.1, 0.5)),
		chain = iron:Lerp(rust, random:NextNumber(0.05, 0.4)),
	}
end

local function block(
	parent: Instance,
	name: string,
	cframe: CFrame,
	size: Vector3,
	color: Color3,
	material: Enum.Material?
): Part
	local part = Geometry.part(parent, name, cframe, size, nil, {
		material = material or Enum.Material.CorrodedMetal,
		color = color,
	})
	PropKit.detail(part)
	return part
end

-- A cylinder whose axis is `cframe`'s X axis.
local function cylinder(
	parent: Instance,
	name: string,
	cframe: CFrame,
	length: number,
	diameter: number,
	color: Color3
): Part
	local part = Geometry.part(parent, name, cframe, Vector3.new(length, diameter, diameter), nil, {
		shape = Enum.PartType.Cylinder,
		material = Enum.Material.CorrodedMetal,
		color = color,
	})
	PropKit.detail(part)
	return part
end

-- The fixed frame: base bar (PrimaryPart "Base"), cross plate, hinge posts, spring bends, pan post, dog and its ear.
local function buildFrame(model: Model, frame: CFrame, tint: Tint): Part
	local base = block(
		model,
		"Base",
		frame * CFrame.new(0, BASE_THICK / 2, 0),
		Vector3.new(BASE_HALF * 2, BASE_THICK, BASE_WIDTH),
		tint.frame
	)
	model.PrimaryPart = base

	local panPostZ0 = PAN_RADIUS - 0.02
	local crossZ0 = DOG_PIVOT_Z - 0.03
	local crossZ1 = panPostZ0 + PAN_POST_DEPTH + 0.02
	block(
		model,
		"CrossPlate",
		frame * CFrame.new(0, CROSS_THICK / 2, (crossZ0 + crossZ1) / 2),
		Vector3.new(CROSS_WIDTH, CROSS_THICK, crossZ1 - crossZ0),
		tint.frame
	)

	for _, side in { 1, -1 } do
		local suffix = if side > 0 then "A" else "B"
		block(
			model,
			"Post" .. suffix,
			frame * CFrame.new(side * JAW_RADIUS, BASE_THICK + POST_SIZE.Y / 2, 0),
			POST_SIZE,
			tint.frame
		)
		cylinder(
			model,
			"Bend" .. suffix,
			frame * CFrame.new(side * BEND_X, BEND_Y, 0) * ACROSS,
			SPRING_LEAF.Z,
			BEND_DIAMETER,
			tint.spring
		)
	end

	block(
		model,
		"PanPost",
		frame * CFrame.new(0, (CROSS_THICK + PAN_Y) / 2, panPostZ0 + PAN_POST_DEPTH / 2),
		Vector3.new(0.14, PAN_Y - CROSS_THICK, PAN_POST_DEPTH),
		tint.frame
	)

	local earTop = DOG_PIVOT_Y + 0.02
	block(
		model,
		"DogPivot",
		frame * CFrame.new(0, (CROSS_THICK + earTop) / 2, DOG_PIVOT_Z),
		Vector3.new(0.1, earTop - CROSS_THICK, 0.05),
		tint.frame
	)
	local dogFrom = Vector3.new(0, DOG_PIVOT_Y, DOG_PIVOT_Z)
	local dogTo = Vector3.new(0, DOG_TIP_Y, DOG_TIP_Z)
	block(
		model,
		"Dog",
		frame * CFrame.lookAt((dogFrom + dogTo) / 2, dogTo),
		Vector3.new(DOG_WIDTH, DOG_THICK, (dogTo - dogFrom).Magnitude),
		tint.spring
	)
	return base
end

-- One serrated bow, built in its rest (snapped) pose: a semicircle of radius JAW_RADIUS about its hinge point,
-- standing in the vertical plane. `side` = +1 for JawA (lies toward +Z when armed), -1 for JawB.
local function buildJaw(model: Model, frame: CFrame, name: string, side: number, teeth: { number }, tint: Tint)
	local hinge = frame * CFrame.new(0, HINGE_Y, side * HINGE_Z)
	local leaf = PropKit.leaf(model, name, hinge)
	local step = math.pi / JAW_SEGMENTS
	local chordRadius = JAW_RADIUS * math.cos(step / 2)
	-- Each chord is lengthened by its share of the joint wedge, so neighbouring segments close on the outside.
	local chordLength = 2 * JAW_RADIUS * math.sin(step / 2) + JAW_THICK * math.tan(step / 2)
	for i = 1, JAW_SEGMENTS do
		local phi = (i - 0.5) * step
		local radial = Vector3.new(math.cos(phi), math.sin(phi), 0)
		local tangent = Vector3.new(-math.sin(phi), math.cos(phi), 0)
		block(
			leaf,
			"Bow" .. i,
			hinge * CFrame.fromMatrix(radial * chordRadius, tangent, radial),
			Vector3.new(chordLength, JAW_THICK, JAW_BAND),
			tint.jaw
		)
	end

	-- Saw teeth on the gripping face (toward the other jaw when snapped, straight up when armed), flush on their
	-- segment's chord: the wedge's flat bottom sits on the face, its slope leans along the bow.
	local face = -side * JAW_BAND / 2
	local grip = Vector3.new(0, 0, -side)
	for i, degrees in teeth do
		local phi = math.rad(degrees)
		local segment = math.clamp(math.floor(phi / step), 0, JAW_SEGMENTS - 1)
		local centre = (segment + 0.5) * step
		local radial = Vector3.new(math.cos(centre), math.sin(centre), 0)
		local reach = chordRadius / math.cos(phi - centre)
		local position = Vector3.new(reach * math.cos(phi), reach * math.sin(phi), face) + grip * (TOOTH_LENGTH / 2)
		local tooth = Geometry.wedge(
			leaf,
			"Tooth" .. i,
			hinge * CFrame.fromMatrix(position, radial, grip),
			Vector3.new(JAW_THICK, TOOTH_LENGTH, TOOTH_WIDTH),
			nil,
			{ material = Enum.Material.Metal, color = tint.tooth }
		)
		PropKit.detail(tooth)
	end
end

-- The upper leaf and eye of one V spring, built released (rest). `side` = +1 for SpringA (+X end), -1 for SpringB.
local function buildSpring(model: Model, frame: CFrame, name: string, side: number, tint: Tint)
	local pivot = frame * CFrame.new(side * BEND_X, BEND_Y, 0) * CFrame.Angles(0, 0, -side * SPRING_RELEASED)
	local leaf = PropKit.leaf(model, name, pivot)
	local lift = BEND_DIAMETER / 2 - SPRING_LEAF.Y / 2 -- the leaf runs off the top of the bend
	local inward = Vector3.new(-side, 0, 0)
	block(
		leaf,
		"Leaf",
		pivot * CFrame.new(inward * (SPRING_REACH / 2) + Vector3.new(0, lift, 0)),
		SPRING_LEAF,
		tint.spring
	)
	block(leaf, "Eye", pivot * CFrame.new(inward * SPRING_REACH + Vector3.new(0, lift, 0)), SPRING_EYE, tint.spring)
end

local function buildPan(model: Model, frame: CFrame, tint: Tint)
	local leaf = PropKit.leaf(model, NAMES.Pan, frame * CFrame.new(0, PAN_Y, PAN_RADIUS))
	cylinder(leaf, "Plate", frame * CFrame.new(0, PAN_Y, 0) * UPRIGHT, PAN_THICK, PAN_RADIUS * 2, tint.frame)
end

-- Links alternate flat and on edge, wandering out from the -X spring end, then the stake they are fixed to.
local function buildChain(model: Model, frame: CFrame, random: Random, tint: Tint)
	local heading = math.pi + random:NextNumber(-CHAIN_SPREAD / 2, CHAIN_SPREAD / 2)
	local direction = Vector3.new(math.cos(heading), 0, math.sin(heading))
	local centre = Vector3.new(-BASE_HALF, 0, 0) + direction * (LINK_LENGTH / 2 - 0.05)
	for i = 1, CHAIN_LINKS do
		if i > 1 then
			heading = math.clamp(
				heading + random:NextNumber(-CHAIN_SWAY, CHAIN_SWAY),
				math.pi - CHAIN_SPREAD,
				math.pi + CHAIN_SPREAD
			)
			local nextDirection = Vector3.new(math.cos(heading), 0, math.sin(heading))
			centre += (direction + nextDirection) * (LINK_PITCH / 2)
			direction = nextDirection
		end
		local size = if i % 2 == 1
			then Vector3.new(LINK_WIDTH, LINK_WIRE, LINK_LENGTH)
			else Vector3.new(LINK_WIRE, LINK_WIDTH, LINK_LENGTH)
		local position = Vector3.new(centre.X, size.Y / 2, centre.Z)
		block(model, "Link" .. i, frame * CFrame.lookAt(position, position + direction), size, tint.chain)
	end
	local stake = centre + direction * (LINK_LENGTH / 2 + STAKE_DIAMETER / 2 - 0.04)
	cylinder(
		model,
		"Stake",
		frame * CFrame.new(stake.X, STAKE_HEIGHT / 2, stake.Z) * UPRIGHT,
		STAKE_HEIGHT,
		STAKE_DIAMETER,
		tint.chain
	)
	cylinder(
		model,
		"StakeHead",
		frame * CFrame.new(stake.X, STAKE_HEIGHT - STAKE_HEAD_THICK / 2 + 0.02, stake.Z) * UPRIGHT,
		STAKE_HEAD_THICK,
		STAKE_HEAD_DIAMETER,
		tint.chain
	)
end

--------------------------------------------------------------------------------
-- Builder
--------------------------------------------------------------------------------

-- Builds one armed trap for a PlannedProp (registered as plan prop kind "BearTrap").
function BearTrapBuilder.build(ctx: Types.PropBuildContext): Model
	local plan = ctx.prop
	local tint = tintOf(plan.variant)
	local frame = plan.cframe * CFrame.Angles(0, ctx.random:NextNumber(0, 2 * math.pi), 0)
	local model = PropKit.model(ctx.parent, KIND .. "_" .. plan.anchorId, frame)

	local base = buildFrame(model, frame, tint)
	buildJaw(model, frame, NAMES.JawA, 1, TEETH_A, tint)
	buildJaw(model, frame, NAMES.JawB, -1, TEETH_B, tint)
	buildSpring(model, frame, NAMES.SpringA, 1, tint)
	buildSpring(model, frame, NAMES.SpringB, -1, tint)
	buildPan(model, frame, tint)
	buildChain(model, frame, ctx.random, tint)

	local volume = Geometry.part(
		model,
		NAMES.TriggerVolume,
		frame * CFrame.new(0, TRIGGER_BOTTOM + TRIGGER_SIZE.Y / 2, 0),
		TRIGGER_SIZE
	)
	Geometry.makeVolume(volume)

	Geometry.attachment(base, NAMES.LegPoint, base.CFrame:ToObjectSpace(frame * CFrame.new(0, LEG_POINT_Y, 0)))
	local promptPoint =
		Geometry.attachment(base, NAMES.PromptPoint, base.CFrame:ToObjectSpace(frame * CFrame.new(0, PROMPT_Y, 0)))
	PropKit.prompt(promptPoint, PRY_PROMPT, model)
	PropKit.prompt(promptPoint, RESCUE_PROMPT, model)

	PropKit.setAttributes(model, {
		[W.Armed] = true,
		[W.AnchorId] = plan.anchorId,
		[W.LevelId] = plan.levelId,
	})
	model:AddTag(Tags.BearTrap)

	-- Initial game state: armed and waiting.
	BearTrapBuilder.setJaws(model, 1)
	BearTrapBuilder.setPan(model, 0)
	return model
end

function BearTrapBuilder.register(registrar: PropKit.Registrar)
	registrar.prop(KIND, BearTrapBuilder.build)
end

return table.freeze(BearTrapBuilder)
