--!strict
-- HideBuilder: the tunnels' hiding spots besides the lockers (LockerBuilder). Fixture kinds "HideableBarrel" (one per
-- Barrel anchor) and "HideableCabinet" (one per Cabinet anchor), rebuilt into Workspace.Runtime.<level>.HideableBarrels
-- / .HideableCabinets at every run start, so every run begins with each lid and door shut and each spot empty.
--
-- Both follow the locker's conventions (LockerBuilder), so the hiding mechanic serves all three alike:
--   * prop space: X across the front, Y up from the floor, -Z out through the front (the anchor's LookVector); the
--     anchor is the floor centre of the footprint;
--   * a hollow body around an interior the hidden player stands (barrel: crouches) in, and one moving leaf: the
--     barrel's "Lid" (hinged at the back of the rim, it swings up and back) or the cabinet's "Door" (hinged on its -X
--     edge, it swings out); the leaf's rest pose is attachment "<Leaf>Rest" and its open pose "<Leaf>Open";
--   * a gap the hidden player watches through and the Creature's sight rays pass: the barrel's lid sits on three
--     lugs, leaving a slot under it at the hidden eye; the cabinet's door carries louvred slats at eye height;
--   * attachments on the Base, all looking out through the front:
--       EntryAnchor  floor level 1.4 studs in front, facing the prop (where a player stands to climb in)
--       ExitAnchor   floor level 2.2 studs in front, facing away (where they step out to); a prop standing free
--                    (its anchor's `exit`) has it 1.3 studs off its Left (-X) or Right (+X) side instead, facing
--                    out that way, so the hider can come out on a side the Creature is not standing on
--       HideAnchor   the interior floor centre (where the hidden player stands)
--       PeekAnchor   the hidden player's eye behind the gap (the hiding camera)
--       HidePrompt   hosts the Hide prompt (created disabled; ObjectText Barrel / Cabinet)
--       <Leaf>Landing where the Creature's rip throws the torn leaf's pivot (on the floor in front)
--   * attributes AnchorId, LevelId, ZoneId, DoorOpen = false, HideKind ("Barrel" | "Cabinet"); tags Hideable and
--     Interactable;
--   * collision: the body and leaf are MonsterPassthrough (players bump into them, the Creature reaches in); hand-scale
--     details collide with nothing.
-- Variety is seeded by the run: paint, rust, dents, a hazard band on some drums, stencilled numbers on the cabinets.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local Tags = require(ReplicatedStorage.Shared.Tags)

local Geometry = require(script.Parent.Parent.Geometry)
local PropKit = require(script.Parent.PropKit)

type PartOptions = Geometry.PartOptions

export type HideSpec = {
	cframe: CFrame, -- floor centre of the footprint, LookVector out through the front
	anchorId: string,
	levelId: string,
	zoneId: string,
	number: number,
	exit: ("Left" | "Right")?, -- the side the hider steps out to (nil: the front)
}

local W = Attributes.World

local HideBuilder = {}

HideBuilder.BarrelKind = "HideableBarrel"
HideBuilder.CabinetKind = "HideableCabinet"
HideBuilder.BarrelFolder = "HideableBarrels"
HideBuilder.CabinetFolder = "HideableCabinets"

local ROOT_HEIGHT = 3 -- R15 HumanoidRootPart centre above the feet
local ENTRY_DISTANCE = 1.4
local EXIT_DISTANCE = 2.2
local SIDE_EXIT_GAP = 1.3 -- a side exit's distance off the prop's side
local PROMPT_OUT = 0.6
local PROMPT_Y = 3.4

local RUST = Color3.fromRGB(92, 54, 34)
local GRIME = Color3.fromRGB(16, 15, 13)
local STEEL = Color3.fromRGB(70, 72, 74)
local HAZARD = Color3.fromRGB(196, 150, 28)

-- Barrel (a 205-litre drum scaled up to hide a crouching player)
local BARREL_RADIUS = 1.65
local BARREL_HEIGHT = 4.7
local STAVES = 10
local STAVE_T = 0.12
local BARREL_FLOOR = 0.25
local LID_T = 0.12
local LID_LIFT = 0.32 -- the lid rests on lugs this far above the rim: the slot the hidden player watches through
local LID_OPEN_ANGLE = math.rad(105)
HideBuilder.LidOpenAngle = LID_OPEN_ANGLE
local BARREL_PAINTS: { Color3 } = {
	Color3.fromRGB(46, 70, 104), -- drum blue
	Color3.fromRGB(110, 34, 28), -- drum red
	Color3.fromRGB(62, 76, 48), -- army green
	Color3.fromRGB(150, 116, 30), -- hazard yellow
	Color3.fromRGB(52, 52, 54), -- black
}

-- Cabinet (a tall steel stores cabinet)
local CABINET_WIDTH = 3.3
local CABINET_DEPTH = 2.4

-- Footprints (X across the front, Y front to back): TunnelPlanner stands the props free in their niches by these
HideBuilder.Footprints = table.freeze({
	Barrel = Vector2.new(BARREL_RADIUS * 2, BARREL_RADIUS * 2),
	Cabinet = Vector2.new(CABINET_WIDTH, CABINET_DEPTH),
})
local CABINET_HEIGHT = 7.8
local CAB_T = 0.1
local CAB_FLOOR = 0.3
local DOOR_T = 0.1
local DOOR_GAP = 0.03
local DOOR_OPEN_ANGLE = math.rad(105)
HideBuilder.DoorOpenAngle = DOOR_OPEN_ANGLE
local SLATS = 6
local SLAT_GAP = 0.13
local SLAT_H = 0.1
local CABINET_PAINTS: { Color3 } = {
	Color3.fromRGB(78, 86, 72), -- stores green
	Color3.fromRGB(86, 88, 90), -- battleship grey
	Color3.fromRGB(64, 72, 84), -- slate blue
	Color3.fromRGB(96, 80, 56), -- tan
}

local HIDE_PROMPT_BARREL: PropKit.PromptSpec = {
	kind = "Hide",
	action = "Prompt.Hide",
	object = "Prompt.Barrel",
	hold = 0.25,
}
local HIDE_PROMPT_CABINET: PropKit.PromptSpec = {
	kind = "Hide",
	action = "Prompt.Hide",
	object = "Prompt.Cabinet",
	hold = 0.25,
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

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

local function detail(part: BasePart?): BasePart?
	if part then
		PropKit.detail(part)
	end
	return part
end

local function weathered(paint: Color3, rust: number): Color3
	return paint:Lerp(RUST, 0.1 + 0.35 * rust):Lerp(GRIME, 0.12 * rust)
end

local function eyeHeight(floorY: number, crouched: boolean): number
	local standing = floorY + ROOT_HEIGHT + CameraConfig.EyeHeightAboveRoot.Standing
	if crouched then
		return standing + CameraConfig.StateOffsets.Crouching.Y
	end
	return standing + CameraConfig.StateOffsets.LockerPeeking.Y
end

local function finish(
	model: Model,
	base: BasePart,
	spec: HideSpec,
	kind: string,
	prompt: PropKit.PromptSpec,
	front: number,
	peek: Vector3,
	hide: Vector3,
	frame: CFrame,
	halfWidth: number
)
	local function anchorAt(name: string, localCFrame: CFrame): Attachment
		return Geometry.attachment(base, name, base.CFrame:ToObjectSpace(frame * localCFrame))
	end
	anchorAt("HideAnchor", CFrame.new(hide))
	anchorAt("PeekAnchor", CFrame.new(peek))
	if spec.exit == "Left" then
		anchorAt("ExitAnchor", CFrame.new(-(halfWidth + SIDE_EXIT_GAP), 0, 0) * CFrame.Angles(0, math.pi / 2, 0))
	elseif spec.exit == "Right" then
		anchorAt("ExitAnchor", CFrame.new(halfWidth + SIDE_EXIT_GAP, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0))
	else
		anchorAt("ExitAnchor", CFrame.new(0, 0, front - EXIT_DISTANCE))
	end
	-- the entry spot faces the prop (turned round from the prop's LookVector)
	anchorAt("EntryAnchor", CFrame.new(0, 0, front - ENTRY_DISTANCE) * CFrame.Angles(0, math.pi, 0))
	local host = anchorAt("HidePrompt", CFrame.new(0, PROMPT_Y, front - PROMPT_OUT))
	PropKit.passthroughAll(model)
	PropKit.setAttributes(model, {
		[W.AnchorId] = spec.anchorId,
		[W.LevelId] = spec.levelId,
		[W.ZoneId] = spec.zoneId,
		[W.DoorOpen] = false,
		[W.HideKind] = kind,
	})
	model:AddTag(Tags.Hideable)
	PropKit.prompt(host, prompt, model)
end

--------------------------------------------------------------------------------
-- Barrel
--------------------------------------------------------------------------------

-- The lid's pose `openness` (0 shut .. 1 open): a turn about the hinge at the back of the rim.
function HideBuilder.lidTransform(openness: number): CFrame
	return CFrame.Angles(LID_OPEN_ANGLE * math.clamp(openness, 0, 1), 0, 0)
end

function HideBuilder.buildBarrel(parent: Instance, spec: HideSpec, random: Random): Model
	local frame = spec.cframe
	local model = PropKit.model(parent, spec.anchorId, frame)
	local rust = random:NextNumber()
	local paint = weathered(BARREL_PAINTS[random:NextInteger(1, #BARREL_PAINTS)], rust)
	local material = if rust > 0.6 then Enum.Material.CorrodedMetal else Enum.Material.Metal
	local body: PartOptions = { material = material, color = paint }

	-- the floor disc (the Base)
	local base = Geometry.part(
		model,
		"Base",
		frame * CFrame.new(0, BARREL_FLOOR / 2, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Vector3.new(BARREL_FLOOR, BARREL_RADIUS * 2 - 0.1, BARREL_RADIUS * 2 - 0.1),
		"MetalRust",
		{ shape = Enum.PartType.Cylinder, material = Enum.Material.CorrodedMetal, color = paint:Lerp(GRIME, 0.5) }
	)
	model.PrimaryPart = base

	-- staves round the drum (a hollow shell); the front stave is the one the hidden player faces
	local staveWidth = 2 * BARREL_RADIUS * math.tan(math.pi / STAVES) + 0.04
	local bands = { BARREL_HEIGHT * 0.33, BARREL_HEIGHT * 0.7 }
	local hazard = random:NextNumber() < 0.35
	for i = 0, STAVES - 1 do
		local angle = (i + 0.5) * 2 * math.pi / STAVES
		local out = Vector3.new(math.sin(angle), 0, -math.cos(angle))
		local at = out * (BARREL_RADIUS - STAVE_T / 2)
		local staveFrame = frame
			* CFrame.lookAt(at + Vector3.new(0, BARREL_HEIGHT / 2, 0), at + out + Vector3.new(0, BARREL_HEIGHT / 2, 0))
		Geometry.part(
			model,
			"Stave" .. i,
			staveFrame,
			Vector3.new(staveWidth, BARREL_HEIGHT, STAVE_T),
			"MetalRust",
			body
		)
		-- rolling hoops: proud bands round the drum
		for k, y in bands do
			local band = Geometry.part(
				model,
				string.format("Hoop%d_%d", i, k),
				frame
					* CFrame.lookAt(
						out * (BARREL_RADIUS + 0.03) + Vector3.new(0, y, 0),
						out * (BARREL_RADIUS + 1) + Vector3.new(0, y, 0)
					),
				Vector3.new(staveWidth + 0.02, 0.16, 0.08),
				"MetalRust",
				if hazard and k == 2
					then { material = Enum.Material.SmoothPlastic, color = HAZARD:Lerp(GRIME, 0.2 * rust) }
					else body
			)
			detail(band)
		end
	end
	-- the inner face darkened (a dim liner the hidden player sees)
	detail(
		Geometry.part(
			model,
			"Liner",
			frame * CFrame.new(0, BARREL_FLOOR + 0.01, 0) * CFrame.Angles(0, 0, math.rad(90)),
			Vector3.new(0.02, BARREL_RADIUS * 2 - 0.4, BARREL_RADIUS * 2 - 0.4),
			"MetalRust",
			{ shape = Enum.PartType.Cylinder, material = Enum.Material.CorrodedMetal, color = paint:Lerp(GRIME, 0.7) }
		)
	)
	-- lugs on the rim the lid rests on (the slot between them is the peep)
	for i, angle in { math.pi * 0.75, math.pi * 1.25, 0 } do
		local out = Vector3.new(math.sin(angle), 0, -math.cos(angle))
		detail(
			block(
				model,
				"Lug" .. i,
				frame * CFrame.new(out * (BARREL_RADIUS - 0.2)),
				Vector3.new(-0.15, BARREL_HEIGHT, -0.15),
				Vector3.new(0.15, BARREL_HEIGHT + LID_LIFT, 0.15),
				"TrimMetal",
				{ material = Enum.Material.Metal, color = STEEL }
			)
		)
	end

	-- the lid: hinged at the back of the rim (local +Z), it swings up and back about the X axis
	local hingeZ = BARREL_RADIUS - 0.05
	local lidY = BARREL_HEIGHT + LID_LIFT
	local rest = frame * CFrame.new(0, lidY, hingeZ)
	local lid = PropKit.leaf(model, "Lid", rest)
	Geometry.part(
		lid,
		"LidDisc",
		frame * CFrame.new(0, lidY + LID_T / 2, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Vector3.new(LID_T, BARREL_RADIUS * 2 + 0.12, BARREL_RADIUS * 2 + 0.12),
		"MetalRust",
		{ shape = Enum.PartType.Cylinder, material = material, color = paint:Lerp(GRIME, 0.15) }
	)
	detail(
		Geometry.part(
			lid,
			"LidRing",
			frame * CFrame.new(0, lidY + LID_T + 0.04, 0) * CFrame.Angles(0, 0, math.rad(90)),
			Vector3.new(0.08, BARREL_RADIUS * 1.2, BARREL_RADIUS * 1.2),
			"TrimMetal",
			{ shape = Enum.PartType.Cylinder, material = Enum.Material.Metal, color = STEEL }
		)
	)
	detail(
		block(
			lid,
			"Handle",
			frame,
			Vector3.new(-0.5, lidY + LID_T, -BARREL_RADIUS * 0.55 - 0.1),
			Vector3.new(0.5, lidY + LID_T + 0.14, -BARREL_RADIUS * 0.55 + 0.1),
			"TrimMetal",
			{ material = Enum.Material.Metal, color = STEEL }
		)
	)
	Geometry.attachment(base, "LidOpen", base.CFrame:ToObjectSpace(rest * HideBuilder.lidTransform(1)))
	-- where the rip throws the lid: flat on the floor in front, a little to one side
	local side = if random:NextNumber() < 0.5 then -1 else 1
	Geometry.attachment(
		base,
		"LidLanding",
		base.CFrame:ToObjectSpace(
			frame * CFrame.new(side * 1.4, 0.07, -BARREL_RADIUS - 1.6) * CFrame.Angles(0, random:NextNumber(-1, 1), 0)
		)
	)

	-- the hidden player crouches inside and rises to the slot under the lid to look out: the eye in the slot
	local front = -BARREL_RADIUS
	local peek = Vector3.new(0, BARREL_HEIGHT + LID_LIFT * 0.5, -BARREL_RADIUS * 0.35)
	finish(
		model,
		base,
		spec,
		"Barrel",
		HIDE_PROMPT_BARREL,
		front,
		peek,
		Vector3.new(0, BARREL_FLOOR, 0),
		frame,
		BARREL_RADIUS
	)
	return model
end

--------------------------------------------------------------------------------
-- Cabinet
--------------------------------------------------------------------------------

-- The door's pose `openness` (0 shut .. 1 open): a turn about its hinge on the -X edge, swinging out.
function HideBuilder.doorTransform(openness: number): CFrame
	return CFrame.Angles(0, DOOR_OPEN_ANGLE * math.clamp(openness, 0, 1), 0)
end

function HideBuilder.buildCabinet(parent: Instance, spec: HideSpec, random: Random): Model
	local frame = spec.cframe
	local model = PropKit.model(parent, spec.anchorId, frame)
	local rust = random:NextNumber()
	local paint = weathered(CABINET_PAINTS[random:NextInteger(1, #CABINET_PAINTS)], rust)
	local material = if rust > 0.65 then Enum.Material.CorrodedMetal else Enum.Material.Metal
	local body: PartOptions = { material = material, color = paint }
	local inside: PartOptions = { material = material, color = paint:Lerp(GRIME, 0.4) }
	local half = CABINET_WIDTH / 2
	local inner = half - CAB_T
	local back = CABINET_DEPTH / 2
	local front = -CABINET_DEPTH / 2

	local base = block(
		model,
		"Base",
		frame,
		Vector3.new(-inner, 0, front + 0.05),
		Vector3.new(inner, CAB_FLOOR, back - CAB_T),
		"MetalRust",
		{
			material = Enum.Material.CorrodedMetal,
			color = paint:Lerp(GRIME, 0.5),
		}
	)
	model.PrimaryPart = base
	block(
		model,
		"SideLeft",
		frame,
		Vector3.new(-half, 0, front),
		Vector3.new(-inner, CABINET_HEIGHT - CAB_T, back),
		"TrimMetal",
		body
	)
	block(
		model,
		"SideRight",
		frame,
		Vector3.new(inner, 0, front),
		Vector3.new(half, CABINET_HEIGHT - CAB_T, back),
		"TrimMetal",
		body
	)
	block(
		model,
		"Back",
		frame,
		Vector3.new(-inner, 0, back - CAB_T),
		Vector3.new(inner, CABINET_HEIGHT - CAB_T, back),
		"TrimMetal",
		inside
	)
	block(
		model,
		"Top",
		frame,
		Vector3.new(-half, CABINET_HEIGHT - CAB_T, front),
		Vector3.new(half, CABINET_HEIGHT, back),
		"TrimMetal",
		body
	)
	-- a shelf up high (the hidden player stands under it) and a header rail over the door
	detail(
		block(
			model,
			"Shelf",
			frame,
			Vector3.new(-inner, 6.7, 0),
			Vector3.new(inner, 6.78, back - CAB_T),
			"TrimMetal",
			inside
		)
	)
	block(
		model,
		"Header",
		frame,
		Vector3.new(-inner, 7.05, front),
		Vector3.new(inner, CABINET_HEIGHT - CAB_T, front + 0.1),
		"TrimMetal",
		body
	)

	-- the door: one leaf over the whole front, louvred at the hidden eye
	local hingeX = -inner + DOOR_GAP
	local latchX = inner - DOOR_GAP
	local doorBottom = CAB_FLOOR + 0.05
	local doorTop = 7.0
	local rest = frame * CFrame.new(hingeX, 0, front)
	local door = PropKit.leaf(model, "Door", rest)
	local doorColor = paint:Lerp(GRIME, 0.08)
	local doorOptions: PartOptions = { material = material, color = doorColor }
	local eye = eyeHeight(CAB_FLOOR, false)
	local band = SLATS * SLAT_GAP + (SLATS - 1) * SLAT_H
	local slitBottom = eye - band / 2
	local slitTop = slitBottom + band
	block(
		door,
		"PanelLow",
		frame,
		Vector3.new(hingeX, doorBottom, front - DOOR_T),
		Vector3.new(latchX, slitBottom, front),
		"TrimMetal",
		doorOptions
	)
	block(
		door,
		"PanelHigh",
		frame,
		Vector3.new(hingeX, slitTop, front - DOOR_T),
		Vector3.new(latchX, doorTop, front),
		"TrimMetal",
		doorOptions
	)
	local stile = 0.32
	block(
		door,
		"StileHinge",
		frame,
		Vector3.new(hingeX, slitBottom, front - DOOR_T),
		Vector3.new(hingeX + stile, slitTop, front),
		"TrimMetal",
		doorOptions
	)
	block(
		door,
		"StileLatch",
		frame,
		Vector3.new(latchX - stile, slitBottom, front - DOOR_T),
		Vector3.new(latchX, slitTop, front),
		"TrimMetal",
		doorOptions
	)
	for i = 1, SLATS - 1 do
		local y0 = slitBottom + i * SLAT_GAP + (i - 1) * SLAT_H
		block(
			door,
			"Slat" .. i,
			frame,
			Vector3.new(hingeX + stile, y0, front - DOOR_T + 0.02),
			Vector3.new(latchX - stile, y0 + SLAT_H, front - 0.02),
			"TrimMetal",
			doorOptions
		)
	end
	detail(
		block(
			door,
			"Handle",
			frame,
			Vector3.new(latchX - 0.5, 3.3, front - DOOR_T - 0.14),
			Vector3.new(latchX - 0.36, 4.3, front - DOOR_T),
			"TrimMetal",
			{
				material = Enum.Material.Metal,
				color = STEEL,
			}
		)
	)
	-- stencilled number on the door's upper panel
	local plate = detail(
		block(
			door,
			"Stencil",
			frame,
			Vector3.new(-0.9, 5.5, front - DOOR_T - 0.012),
			Vector3.new(0.9, 6.3, front - DOOR_T),
			"TrimMetal",
			doorOptions
		)
	)
	if plate then
		local gui = Instance.new("SurfaceGui")
		gui.Name = "Stencil"
		gui.Face = Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 48
		gui.LightInfluence = 1
		gui.MaxDistance = 40
		local label = Instance.new("TextLabel")
		label.Name = "Text"
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Text = string.format("C-%02d", spec.number)
		label.TextColor3 = Color3.fromRGB(214, 206, 180)
		label.TextScaled = true
		label.FontFace = Font.fromEnum(Enum.Font.SpecialElite)
		label.Parent = gui
		gui.Parent = plate
	end
	Geometry.attachment(base, "DoorOpen", base.CFrame:ToObjectSpace(rest * HideBuilder.doorTransform(1)))
	Geometry.attachment(
		base,
		"DoorLanding",
		base.CFrame:ToObjectSpace(
			frame * CFrame.new(hingeX - 0.4, 0.06, front - 2.4) * CFrame.Angles(math.rad(-90), 0, 0)
		)
	)
	local peek = Vector3.new(0, eye, front + DOOR_T + 0.3)
	finish(
		model,
		base,
		spec,
		"Cabinet",
		HIDE_PROMPT_CABINET,
		front - DOOR_T,
		peek,
		Vector3.new(0, CAB_FLOOR, (front + back) / 2),
		frame,
		CABINET_WIDTH / 2
	)
	return model
end

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

local function fixtures(kind: "Barrel" | "Cabinet", folderName: string): PropKit.FixtureBuilder
	return function(ctx: PropKit.FixtureContext): number
		local stale = ctx.parent:FindFirstChild(folderName)
		if stale then
			stale:Destroy()
		end
		local anchors = PropKit.anchorsOf(ctx.layout, kind)
		if #anchors == 0 then
			return 0
		end
		local folder = Geometry.folder(ctx.parent, folderName)
		for index, anchor in anchors do
			local spec: HideSpec = {
				cframe = PropKit.anchorCFrame(ctx.layout.id, anchor),
				anchorId = anchor.id,
				levelId = ctx.layout.id,
				zoneId = anchor.room,
				number = index,
				exit = anchor.exit,
			}
			if kind == "Barrel" then
				HideBuilder.buildBarrel(folder, spec, ctx.random)
			else
				HideBuilder.buildCabinet(folder, spec, ctx.random)
			end
		end
		return #anchors
	end
end

function HideBuilder.register(registrar: PropKit.Registrar)
	registrar.fixture(HideBuilder.BarrelKind, fixtures("Barrel", HideBuilder.BarrelFolder))
	registrar.fixture(HideBuilder.CabinetKind, fixtures("Cabinet", HideBuilder.CabinetFolder))
end

return table.freeze(HideBuilder)
