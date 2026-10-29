--!strict
-- ParachuteBuilder: the roof's parachute crate (fixture) and the two parachute rigs (worn pack, deployed canopy).
--
-- Fixture kind "ParachuteCrate" (the ParachuteCrate anchor on Level5_Roof, rebuilt at every run start into
-- Workspace.Runtime.<level>.ParachuteCrates): a weathered olive-drab wooden supply crate on two skids, its front
-- toward the anchor's LookVector (the jump gap in the parapet), lid hinged along the back edge and propped open by a
-- stick, stencilled "EMERGENCY CHUTES" on the front and across the lid's outer face (the face the squad sees as it
-- runs in from the stairs). GameConfig.ParachutePackCount packs stand in a row inside it, leaning back against the
-- back wall and showing their harness side. Each pack is its own Model "ParachutePack<i>" (olive container, top flap,
-- shoulder and chest straps, a buckle and a bright ripcord handle) tagged ParachutePack + Interactable, with
-- attributes AnchorId and LevelId (TakenByUserId stays unset until someone takes it) and a disabled ParachuteGrab
-- prompt on its "GrabPoint" attachment. The crate collides (Default group); packs are hand-scale details.
--
-- Rigs (Builder.BuildRig). Both are cosmetic (never collide, never queried) and built anchored at the CFrame they are
-- given; the parachute mechanic (P8) welds every part to the PrimaryPart, unanchors them and attaches the rig to the
-- jumper through the named attachment:
--   "ParachuteBackpack"  the pack as worn. The CFrame is the wearer's back mount (the UpperTorso's back surface,
--                        LookVector = the wearer's facing): Attachment "BackAttach" sits exactly there, the container
--                        hangs behind it, straps run over the shoulders and down the chest to a chest strap and a
--                        waist belt, and Attachment "Ripcord" sits on the bright handle on the right chest strap.
--   "ParachuteCanopy"    a deployed nine-cell ram-air canopy spanning 14 studs, its cells (block + nose wedge + tail
--                        wedge) on an arc that droops 2 studs at the tips, with stabiliser panels, suspension lines in
--                        two rows down to four risers, the slider and a trailing pilot chute. The CFrame is the
--                        harness point: Attachment "Harness" sits exactly there, about 10.6 studs under the canopy.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)

local Geometry = require(script.Parent.Parent.Geometry)
local PropKit = require(script.Parent.PropKit)

type PartOptions = Geometry.PartOptions

export type CrateSpec = {
	cframe: CFrame, -- floor centre of the crate, LookVector out of its front
	anchorId: string,
	levelId: string,
	zoneId: string,
	packCount: number,
}

local W = Attributes.World

local KIND = "ParachuteCrate"
local FOLDER = "ParachuteCrates"
local BACKPACK = "ParachuteBackpack"
local CANOPY = "ParachuteCanopy"
local CRATE_BUDGET = 40 -- crate + every pack
local BACKPACK_BUDGET = 12
local CANOPY_BUDGET = 60

-- Crate space: X along the crate, Y up from the deck, -Z out of its front.
local PACK_SPACING = 1.7
local END_PAD = 0.15
local WALL = 0.16
local CRATE_DEPTH = 2.6
local SKID_H = 0.25
local SKID_W = 0.4
local FLOOR_TOP = 0.4
local RIM = 1.55
local LID_T = 0.14
local LID_OVERHANG = 0.03
local LID_OPEN = math.rad(80) -- just short of upright, so it needs the stick
local LID_OPEN_JITTER = math.rad(4)
local STICK_T = 0.12

-- Crate pack (pack space: X across, Y up from the crate floor, -Z out of the harness side; the back-bottom edge on
-- the floor is the origin, the pack leans back about it).
local PACK_W = 1.5
local PACK_D = 0.7
local PACK_BODY_H = 1.9
local PACK_FLAP_H = 0.18
local PACK_H = PACK_BODY_H + PACK_FLAP_H
local PACK_LEAN_MIN = math.rad(6)
local PACK_LEAN_MAX = math.rad(12)
local PACK_YAW = math.rad(4)
local PACK_STRAP_X0, PACK_STRAP_X1 = 0.3, 0.52 -- shoulder straps on the harness side, |X|
local PACK_CHEST_Y = 1.18 -- chest strap centre above the pack's bottom
local PACK_BACK_CLEARANCE = 0.12 -- covers the corners the yaw jitter swings back

local GRAB_PROMPT: PropKit.PromptSpec = {
	kind = "ParachuteGrab",
	action = "Prompt.ParachuteGrab",
	object = "Prompt.Parachute",
	hold = 0.5,
}

-- Worn pack (rig space: origin at the wearer's back surface, -Z the wearer's facing, +X the wearer's right).
local TORSO_DEPTH = 1 -- R15 UpperTorso, back surface to chest
local SHOULDER_Y = 0.8 -- top of the UpperTorso above the back mount
local HIP_HALF = 1 -- half width of the LowerTorso
local CONTAINER_HALF_W = 0.9
local STRAP_X0, STRAP_X1 = 0.4, 0.66 -- shoulder straps run between these |X|
local WAIST_Y0, WAIST_Y1 = -1.1, -0.95 -- the waist belt, round the top of the LowerTorso

-- Canopy (rig space: origin at the harness, -Z the flying direction, +X the pilot's right).
local SPAN = 14
local SAG = 2 -- how far the tips droop below the centre cell
local CELLS = 9
local CELL_T = 0.85
local CHORD = 5.2
local NOSE = 0.9
local TAIL = 0.8
local BODY = CHORD - NOSE - TAIL
local BODY_Z = (NOSE - TAIL) / 2 -- body centre (the leading edge is at -CHORD / 2)
local CANOPY_Y = 10.6 -- centre cell's centre above the harness
local ARC_RADIUS = (SPAN * SPAN / 4 + SAG * SAG) / (2 * SAG)
local CELL_ANGLE = 2 * math.asin(SPAN / 2 / ARC_RADIUS) / CELLS
local CELL_WIDTH = (ARC_RADIUS + CELL_T / 2) * CELL_ANGLE -- flush along the top skin
local STAB_H = 1.5
local STAB_L = 3.4
local LINE_ROWS: { number } = { -CHORD / 2 + 0.6, CHORD / 2 - TAIL - 0.3 } -- front (A) and rear (C) attachment rows
local LOADED_RIBS: { number } = { 0, 2, 4, 5, 7, 9 } -- cell boundaries carrying lines (0 and CELLS are the tips)
local CONFLUENCE_X = 0.55
local CONFLUENCE_Y = 2.4
local CONFLUENCE_Z = 0.12
local HARNESS_X = 0.42
local HARNESS_Y = 0.12
local SLIDER_Y = 2.75
local LINE_D = 0.04

-- Finish
local OLIVE = Color3.fromRGB(70, 76, 50)
local CRATE_PAINT = Color3.fromRGB(66, 70, 48)
local CRATE_RAW = Color3.fromRGB(96, 80, 58) -- bare, weathered wood where the paint has worn off
local STENCIL_INK = Color3.fromRGB(196, 188, 162)
local WEBBING = Color3.fromRGB(50, 52, 40)
local BUCKLE = Color3.fromRGB(112, 114, 108)
local RIPCORD = Color3.fromRGB(204, 70, 32)
local CANOPY_A = Color3.fromRGB(88, 94, 64) -- faded olive
local CANOPY_B = Color3.fromRGB(128, 116, 88) -- weathered sand
local LINE = Color3.fromRGB(156, 150, 134)
local FABRIC: Enum.Material = Enum.Material.Fabric
local STENCIL_FONT = Enum.Font.Oswald

local ParachuteBuilder = {}

ParachuteBuilder.Kind = KIND
ParachuteBuilder.Folder = FOLDER
ParachuteBuilder.BackpackRig = BACKPACK
ParachuteBuilder.CanopyRig = CANOPY
ParachuteBuilder.CrateBudget = CRATE_BUDGET
ParachuteBuilder.BackpackBudget = BACKPACK_BUDGET
ParachuteBuilder.CanopyBudget = CANOPY_BUDGET

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Axis-aligned box between two corners in `frame` space.
local function block(
	parent: Instance,
	name: string,
	frame: CFrame,
	a: Vector3,
	b: Vector3,
	key: string,
	options: PartOptions?
): Part
	local lo, hi = a:Min(b), a:Max(b)
	return Geometry.part(parent, name, frame * CFrame.new((lo + hi) / 2), hi - lo, key, options)
end

local function detail(part: BasePart): BasePart
	PropKit.detail(part)
	return part
end

-- A flat strap (webbing, a wooden stick) from world point `a` to `b`, its width across `across`.
local function strap(
	parent: Instance,
	name: string,
	a: Vector3,
	b: Vector3,
	across: Vector3,
	width: number,
	thickness: number,
	key: string,
	options: PartOptions?
): Part
	local axis = (b - a).Unit
	local right = (across - axis * across:Dot(axis)).Unit
	return Geometry.part(
		parent,
		name,
		CFrame.fromMatrix((a + b) / 2, right, axis),
		Vector3.new(width, (b - a).Magnitude, thickness),
		key,
		options
	)
end

local function jitter(color: Color3, random: Random, amount: number): Color3
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(
		(h + random:NextNumber(-0.01, 0.01)) % 1,
		math.clamp(s * random:NextNumber(1 - amount, 1 + amount), 0, 1),
		math.clamp(v * random:NextNumber(1 - amount, 1 + amount * 0.5), 0, 1)
	)
end

-- Stencilled text on the Front face of `part`, filling the middle `fill` of its height.
local function stencil(part: BasePart, fill: number)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Stencil"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 48
	gui.LightInfluence = 1
	gui.MaxDistance = 90
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(0.86, fill)
	label.Text = Strings.get("Prop.Parachute.Stencil")
	label.TextColor3 = STENCIL_INK
	label.TextTransparency = 0.25 -- worn paint
	label.TextScaled = true
	label.FontFace = Font.fromEnum(STENCIL_FONT)
	label.Parent = gui
	gui.Parent = part
end

local function webbing(color: Color3?): PartOptions
	return { material = FABRIC, color = color or WEBBING }
end

--------------------------------------------------------------------------------
-- Crate
--------------------------------------------------------------------------------

-- One pack standing in the crate. `frame` is pack space (see PACK_* above).
local function buildCratePack(crate: Model, index: number, frame: CFrame, spec: CrateSpec, random: Random): Model
	local pack = PropKit.model(crate, string.format("ParachutePack%d", index), frame)
	local x0, x1 = -PACK_W / 2, PACK_W / 2
	local container = jitter(OLIVE, random, 0.08)
	local base = block(
		pack,
		"Base",
		frame,
		Vector3.new(x0, 0, -PACK_D),
		Vector3.new(x1, PACK_BODY_H, 0),
		"Plank",
		{ material = FABRIC, color = container }
	)
	pack.PrimaryPart = base
	block(
		pack,
		"Flap",
		frame,
		Vector3.new(x0 + 0.04, PACK_BODY_H, -PACK_D + 0.04),
		Vector3.new(x1 - 0.04, PACK_H, -0.04),
		"Plank",
		{ material = FABRIC, color = container:Lerp(Color3.new(), 0.18) }
	)
	local front = -PACK_D
	for _, side: number in { -1, 1 } do
		block(
			pack,
			if side < 0 then "StrapLeft" else "StrapRight",
			frame,
			Vector3.new(side * PACK_STRAP_X0, 0.25, front - 0.06),
			Vector3.new(side * PACK_STRAP_X1, PACK_H - 0.08, front),
			"Plank",
			webbing()
		)
	end
	block(
		pack,
		"ChestStrap",
		frame,
		Vector3.new(-PACK_STRAP_X1 - 0.06, PACK_CHEST_Y - 0.06, front - 0.1),
		Vector3.new(PACK_STRAP_X1 + 0.06, PACK_CHEST_Y + 0.06, front - 0.06),
		"Plank",
		webbing()
	)
	block(
		pack,
		"Buckle",
		frame,
		Vector3.new(-0.1, PACK_CHEST_Y - 0.09, front - 0.14),
		Vector3.new(0.1, PACK_CHEST_Y + 0.09, front - 0.1),
		"TrimMetal",
		{ material = Enum.Material.Metal, color = BUCKLE }
	)
	block(
		pack,
		"Ripcord",
		frame,
		Vector3.new(PACK_STRAP_X0 + 0.01, PACK_CHEST_Y + 0.3, front - 0.2),
		Vector3.new(PACK_STRAP_X1 - 0.01, PACK_CHEST_Y + 0.5, front - 0.06),
		"Fixture",
		{ material = Enum.Material.SmoothPlastic, color = RIPCORD }
	)
	for _, descendant in pack:GetDescendants() do
		if descendant:IsA("BasePart") then
			PropKit.detail(descendant)
		end
	end

	local grab = Geometry.attachment(
		base,
		"GrabPoint",
		base.CFrame:ToObjectSpace(frame * CFrame.new(0, PACK_CHEST_Y, front - 0.3))
	)
	PropKit.setAttributes(pack, { [W.AnchorId] = spec.anchorId, [W.LevelId] = spec.levelId })
	pack:AddTag(Tags.ParachutePack)
	PropKit.prompt(grab, GRAB_PROMPT, pack)
	return pack
end

-- The crate's half length (along X), half depth, rim height and wall thickness for `packCount` packs (crate space).
function ParachuteBuilder.crateExtents(packCount: number): (number, number, number, number)
	local inner = math.max(0, packCount) * PACK_SPACING + 2 * END_PAD
	return (inner + 2 * WALL) / 2, CRATE_DEPTH / 2, RIM, WALL
end

-- Builds the crate and its packs into `parent`. Every random choice draws from `random`.
function ParachuteBuilder.buildCrate(parent: Instance, spec: CrateSpec, random: Random): Model
	local frame = spec.cframe
	local count = math.max(0, spec.packCount)
	local inner = count * PACK_SPACING + 2 * END_PAD
	local length = inner + 2 * WALL
	local halfL, halfD = length / 2, CRATE_DEPTH / 2
	local crate = PropKit.model(parent, spec.anchorId, frame)

	local paint = jitter(CRATE_PAINT, random, 0.08)
	local function plank(wear: number): PartOptions
		return { material = Enum.Material.WoodPlanks, color = paint:Lerp(CRATE_RAW, wear) }
	end

	-- Skids, floor and walls
	for i, z in { -halfD + 0.35, halfD - 0.35 } do
		block(
			crate,
			string.format("Skid%d", i),
			frame,
			Vector3.new(-halfL, 0, z - SKID_W / 2),
			Vector3.new(halfL, SKID_H, z + SKID_W / 2),
			"PlankDark",
			{ material = Enum.Material.Wood, color = CRATE_RAW:Lerp(Color3.new(), 0.45) }
		)
	end
	local base = block(
		crate,
		"Base",
		frame,
		Vector3.new(-halfL + WALL, SKID_H, -halfD + WALL),
		Vector3.new(halfL - WALL, FLOOR_TOP, halfD - WALL),
		"Plank",
		plank(random:NextNumber(0.2, 0.5))
	)
	crate.PrimaryPart = base
	local frontWall = block(
		crate,
		"Front",
		frame,
		Vector3.new(-halfL, SKID_H, -halfD),
		Vector3.new(halfL, RIM, -halfD + WALL),
		"Plank",
		plank(random:NextNumber(0.05, 0.3))
	)
	stencil(frontWall, 0.6)
	block(
		crate,
		"Back",
		frame,
		Vector3.new(-halfL, SKID_H, halfD - WALL),
		Vector3.new(halfL, RIM, halfD),
		"Plank",
		plank(random:NextNumber(0.05, 0.3))
	)
	for i, x in { -halfL, halfL - WALL } do
		block(
			crate,
			if i == 1 then "EndLeft" else "EndRight",
			frame,
			Vector3.new(x, SKID_H, -halfD + WALL),
			Vector3.new(x + WALL, RIM, halfD - WALL),
			"Plank",
			plank(random:NextNumber(0.1, 0.4))
		)
	end

	-- Lid: hinged along the back edge of the rim, opened to about 80 degrees. Lid space has the exterior on its Front face
	-- and its up toward the free edge, so the stencil reads upright on the propped lid.
	local hinge = frame
		* CFrame.new(0, RIM, halfD)
		* CFrame.Angles(LID_OPEN + random:NextNumber(-LID_OPEN_JITTER, LID_OPEN_JITTER), 0, 0)
	local lid = Geometry.part(
		crate,
		"Lid",
		hinge * CFrame.fromMatrix(Vector3.new(0, LID_T / 2, -halfD), Vector3.new(-1, 0, 0), Vector3.new(0, 0, -1)),
		Vector3.new(length + 2 * LID_OVERHANG, CRATE_DEPTH, LID_T),
		"Plank",
		plank(random:NextNumber(0.1, 0.35))
	)
	stencil(lid, 0.42)
	detail(
		Geometry.part(
			crate,
			"LidBatten",
			hinge * CFrame.new(0, LID_T + 0.04, -CRATE_DEPTH + 0.2),
			Vector3.new(length + 2 * LID_OVERHANG, 0.08, 0.3),
			"Plank",
			plank(random:NextNumber(0.3, 0.6))
		)
	)
	-- Prop stick from the left end wall's top up to the lid's underside near its free edge.
	local stickX = -halfL + WALL / 2
	detail(
		strap(
			crate,
			"PropStick",
			frame * Vector3.new(stickX, RIM, -halfD + 0.45),
			hinge * Vector3.new(stickX, 0, -(CRATE_DEPTH - 0.35)),
			frame.RightVector,
			STICK_T,
			STICK_T,
			"PlankDark",
			{ material = Enum.Material.Wood, color = CRATE_RAW }
		)
	)

	-- Packs in a row, each leaning back on its bottom-back edge until its top meets the back wall.
	local backInner = halfD - WALL
	for i = 1, count do
		local lean = random:NextNumber(PACK_LEAN_MIN, PACK_LEAN_MAX)
		local yaw = random:NextNumber(-PACK_YAW, PACK_YAW)
		local x = -inner / 2 + END_PAD + (i - 0.5) * PACK_SPACING
		local z = backInner - PACK_H * math.sin(lean) - PACK_BACK_CLEARANCE
		local packFrame = frame * CFrame.new(x, FLOOR_TOP, z) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(lean, 0, 0)
		buildCratePack(crate, i, packFrame, spec, random)
	end

	PropKit.setAttributes(crate, {
		[W.AnchorId] = spec.anchorId,
		[W.LevelId] = spec.levelId,
		[W.ZoneId] = spec.zoneId,
	})
	return crate
end

local function buildFixtures(ctx: PropKit.FixtureContext): number
	local stale = ctx.parent:FindFirstChild(FOLDER)
	if stale then
		stale:Destroy()
	end
	local anchors = PropKit.anchorsOf(ctx.layout, "ParachuteCrate")
	if #anchors == 0 then
		return 0
	end
	local folder = Geometry.folder(ctx.parent, FOLDER)
	for _, anchor in anchors do
		ParachuteBuilder.buildCrate(folder, {
			cframe = PropKit.anchorCFrame(ctx.layout.id, anchor),
			anchorId = anchor.id,
			levelId = ctx.layout.id,
			zoneId = anchor.room,
			packCount = GameConfig.ParachutePackCount,
		}, ctx.random)
	end
	return #anchors
end

--------------------------------------------------------------------------------
-- Rigs
--------------------------------------------------------------------------------

-- The pack as worn; `cframe` is the wearer's back mount (see the header).
function ParachuteBuilder.buildBackpack(parent: Instance, cframe: CFrame): Model
	local model = PropKit.model(parent, BACKPACK, cframe)
	local chest = -TORSO_DEPTH
	local base = block(
		model,
		"Base",
		cframe,
		Vector3.new(-CONTAINER_HALF_W, -1.35, 0.04),
		Vector3.new(CONTAINER_HALF_W, SHOULDER_Y - 0.08, 0.74),
		"Plank",
		{ material = FABRIC, color = OLIVE }
	)
	model.PrimaryPart = base
	block(
		model,
		"Flap",
		cframe,
		Vector3.new(-CONTAINER_HALF_W + 0.04, SHOULDER_Y - 0.08, 0.08),
		Vector3.new(CONTAINER_HALF_W - 0.04, SHOULDER_Y + 0.1, 0.7),
		"Plank",
		{ material = FABRIC, color = OLIVE:Lerp(Color3.new(), 0.18) }
	)
	for _, side: number in { -1, 1 } do
		local name = if side < 0 then "Left" else "Right"
		local a, b = side * STRAP_X0, side * STRAP_X1
		-- Over the shoulder, then down the chest to the waist belt.
		block(
			model,
			"StrapTop" .. name,
			cframe,
			Vector3.new(a, SHOULDER_Y, chest - 0.05),
			Vector3.new(b, SHOULDER_Y + 0.1, 0.1),
			"Plank",
			webbing()
		)
		block(
			model,
			"StrapFront" .. name,
			cframe,
			Vector3.new(a, WAIST_Y1, chest - 0.06),
			Vector3.new(b, SHOULDER_Y + 0.08, chest),
			"Plank",
			webbing()
		)
		-- Round the hip from the waist belt back into the container's side.
		block(
			model,
			"HipStrap" .. name,
			cframe,
			Vector3.new(side * CONTAINER_HALF_W, WAIST_Y0, chest),
			Vector3.new(side * (HIP_HALF + 0.06), WAIST_Y1, 0.1),
			"Plank",
			webbing()
		)
	end
	block(
		model,
		"ChestStrap",
		cframe,
		Vector3.new(-STRAP_X1, 0.05, chest - 0.1),
		Vector3.new(STRAP_X1, 0.17, chest - 0.06),
		"Plank",
		webbing()
	)
	block(
		model,
		"Buckle",
		cframe,
		Vector3.new(-0.12, 0, chest - 0.14),
		Vector3.new(0.12, 0.22, chest - 0.1),
		"TrimMetal",
		{ material = Enum.Material.Metal, color = BUCKLE }
	)
	block(
		model,
		"WaistBelt",
		cframe,
		Vector3.new(-(HIP_HALF + 0.06), WAIST_Y0, chest - 0.06),
		Vector3.new(HIP_HALF + 0.06, WAIST_Y1, chest),
		"Plank",
		webbing()
	)
	local handle = block(
		model,
		"RipcordHandle",
		cframe,
		Vector3.new(STRAP_X0, -0.4, chest - 0.2),
		Vector3.new(STRAP_X1, -0.18, chest - 0.06),
		"Fixture",
		{ material = Enum.Material.SmoothPlastic, color = RIPCORD }
	)

	Geometry.attachment(base, "BackAttach", base.CFrame:ToObjectSpace(cframe))
	Geometry.attachment(handle, "Ripcord", CFrame.new())
	PropKit.cosmeticAll(model)
	return model
end

-- The deployed canopy; `cframe` is the harness point (see the header).
function ParachuteBuilder.buildCanopy(parent: Instance, cframe: CFrame): Model
	local model = PropKit.model(parent, CANOPY, cframe)
	local arcCentre = CFrame.new(0, CANOPY_Y - ARC_RADIUS, 0)
	local middle = (CELLS + 1) / 2

	-- Rig-space CFrame of cell `i`'s body centre, rolled to follow the arc.
	local function cellFrame(i: number): CFrame
		local angle = (i - middle) * CELL_ANGLE
		return cframe * arcCentre * CFrame.Angles(0, 0, -angle) * CFrame.new(0, ARC_RADIUS, BODY_Z)
	end
	-- World point on the bottom skin at cell boundary `rib` (0 .. CELLS), `z` along the chord.
	local function ribPoint(rib: number, z: number): Vector3
		local angle = (rib - CELLS / 2) * CELL_ANGLE
		local radius = ARC_RADIUS - CELL_T / 2
		return cframe * (arcCentre * Vector3.new(radius * math.sin(angle), radius * math.cos(angle), z))
	end

	local base: Part? = nil
	for i = 1, CELLS do
		local fabric: PartOptions = { material = FABRIC, color = if i % 2 == 1 then CANOPY_A else CANOPY_B }
		local frame = cellFrame(i)
		local cell = Geometry.part(
			model,
			if i == middle then "Base" else string.format("Cell%d", i),
			frame,
			Vector3.new(CELL_WIDTH, CELL_T, BODY),
			"Plank",
			fabric
		)
		if i == middle then
			base = cell
		end
		Geometry.wedge(
			model,
			string.format("Nose%d", i),
			frame * CFrame.new(0, 0, -BODY / 2 - NOSE / 2),
			Vector3.new(CELL_WIDTH, CELL_T, NOSE),
			"Plank",
			fabric
		)
		Geometry.wedge(
			model,
			string.format("Tail%d", i),
			frame * CFrame.new(0, 0, BODY / 2 + TAIL / 2) * CFrame.Angles(0, math.pi, 0),
			Vector3.new(CELL_WIDTH, CELL_T, TAIL),
			"Plank",
			fabric
		)
	end
	local primary = assert(base, "the canopy has an odd number of cells, so one sits in the middle")
	model.PrimaryPart = primary

	-- Stabilisers: triangular side panels hanging under the tip cells (full length at the top, deepest at the back).
	for _, tip: number in { 1, CELLS } do
		local side = if tip == 1 then -1 else 1
		Geometry.wedge(
			model,
			if side < 0 then "StabiliserLeft" else "StabiliserRight",
			cellFrame(tip)
				* CFrame.new(side * (CELL_WIDTH / 2 - 0.03), -CELL_T / 2 - STAB_H / 2, 0)
				* CFrame.Angles(0, 0, math.pi),
			Vector3.new(0.05, STAB_H, STAB_L),
			"Plank",
			{ material = FABRIC, color = CANOPY_B }
		)
	end

	-- Suspension lines: two rows from the loaded ribs to the riser tops on their side.
	local line: PartOptions = { material = Enum.Material.SmoothPlastic, color = LINE }
	local function confluence(side: number, row: number): Vector3
		return cframe * Vector3.new(side * CONFLUENCE_X, CONFLUENCE_Y, if row == 1 then -CONFLUENCE_Z else CONFLUENCE_Z)
	end
	for _, rib in LOADED_RIBS do
		local side = if rib < CELLS / 2 then -1 else 1
		for row, z in LINE_ROWS do
			Geometry.cylinder(
				model,
				string.format("Line%d%s", rib, if row == 1 then "A" else "C"),
				ribPoint(rib, z),
				confluence(side, row),
				LINE_D,
				"Fixture",
				line
			)
		end
	end
	-- Brake lines from the trailing edge at each tip to the rear risers.
	for _, side: number in { -1, 1 } do
		Geometry.cylinder(
			model,
			if side < 0 then "BrakeLineLeft" else "BrakeLineRight",
			ribPoint(if side < 0 then 0 else CELLS, CHORD / 2 - 0.1),
			confluence(side, 2),
			LINE_D,
			"Fixture",
			line
		)
	end

	-- Risers down to the harness, and the slider resting on them.
	for _, side: number in { -1, 1 } do
		for row = 1, 2 do
			local z = if row == 1 then -CONFLUENCE_Z else CONFLUENCE_Z
			strap(
				model,
				string.format("Riser%s%s", if side < 0 then "Left" else "Right", if row == 1 then "Front" else "Rear"),
				confluence(side, row),
				cframe * Vector3.new(side * HARNESS_X, HARNESS_Y, z * 0.5),
				cframe.RightVector,
				0.16,
				0.04,
				"Plank",
				webbing()
			)
		end
	end
	Geometry.part(
		model,
		"Slider",
		cframe * CFrame.new(0, SLIDER_Y, 0),
		Vector3.new(1.9, 0.04, 1.1),
		"Plank",
		{ material = FABRIC, color = CANOPY_B }
	)

	-- Pilot chute trailing above and behind the centre cell on its bridle.
	local bridleStart = cframe * Vector3.new(0, CANOPY_Y + CELL_T / 2, 0.8)
	local chuteCentre = cframe * Vector3.new(0, CANOPY_Y + 1.6, 4.6)
	local towing = (chuteCentre - bridleStart).Unit
	Geometry.cylinder(model, "Bridle", bridleStart, chuteCentre - towing * 0.22, LINE_D, "Fixture", line)
	Geometry.cylinder(
		model,
		"PilotChute",
		chuteCentre - towing * 0.22,
		chuteCentre + towing * 0.22,
		1.4,
		"Plank",
		{ material = FABRIC, color = CANOPY_A }
	)

	Geometry.attachment(primary, "Harness", primary.CFrame:ToObjectSpace(cframe))
	PropKit.cosmeticAll(model)
	return model
end

function ParachuteBuilder.register(registrar: PropKit.Registrar)
	registrar.fixture(KIND, buildFixtures)
	registrar.rig(BACKPACK, ParachuteBuilder.buildBackpack)
	registrar.rig(CANOPY, ParachuteBuilder.buildCanopy)
end

return table.freeze(ParachuteBuilder)
