--!strict
-- JanitorCotBuilder: Gus Pruitt asleep in his closet (docs/design/game-spec-v2.md 4.3), on every JanitorCot anchor.
-- All of it is cosmetic (I3): nothing here is a noise, a hide or a light.
--
--   * Fixture "JanitorCot" (rebuilt every run into Workspace.Runtime.<level>, one entity "JanitorCot_<anchor>"): the
--     folding army cot along the wall, its pad and pillow, the shape under an olive army blanket with a tuft of grey
--     hair on the pillow, his work boots at the foot; on the room's shelf (its platform) the transistor radio, the
--     hearing aid in a dish and the clock-radio whose face reads 12:00 (part "ClockFace": the runtime blinks it). The
--     "Wake him" prompt (WakeHim, hold 1.5 s, once a run: the runtime serves it) sits on the sleeper; Attachment
--     "Snore" at his head is where the snore plays from (every 4.5 s, 3D, never an AI noise), "Radio" at the radio's
--     grille where the old tune hisses. The cot and the sleeper collide with players and let the Creature through.
--   * Static "JanitorCloset" (once at boot, into <level>.Props): the blanket hung on a cord between the cot and the
--     door, the shelf's face dressed as a steel supply cabinet (doors, handles, vents, kick plate; Detail 1), the
--     empty key hook on the far wall with its tag ("MASTER RING — if it's not here I left it on a cart."), the
--     door sign on the corridor side ("NIGHT SHIFT SLEEPING. KNOCK LOUD. — GUS") and, in the level's office, the night
--     roster ("NIGHTS: G. PRUITT 11 PM – 7 AM"). The signs and the tag are printed (SurfaceGui) and never Detail.
--
-- Cot space (the anchor's frame): origin on the floor under the cot's middle, X along the cot (his head at -X), -Z out
-- into the room (the anchor faces into the closet), +Z to the wall behind it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Strings = require(ReplicatedStorage.Shared.Strings)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(script.Parent.Parent.Geometry)
local PropKit = require(script.Parent.PropKit)
local SetDressingBuilder = require(script.Parent.SetDressingBuilder)
local SurfaceArt = require(script.Parent.Parent.SurfaceArt)

type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor
type Room = LayoutSchema.Room
type Piece = SetDressingBuilder.Piece

local Kit = SetDressingBuilder.Kit
local W = Attributes.World

local rgb = Color3.fromRGB

local WAKE_HOLD = 1.5
local HALF_LENGTH = 3.2
local HALF_WIDTH = 1.25
local RAIL_Y = 1.32
local PAD_TOP = 1.6
local WALL_HALF = WorldConfig.WallThickness / 2
local SIGN_Y = 5.4
local HOOK_Y = 4.6

local FRAME = rgb(70, 72, 66)
local CANVAS = rgb(80, 82, 76)
local PAD = rgb(92, 92, 88)
local PILLOW = rgb(150, 148, 142)
local BLANKET = rgb(62, 65, 56) -- army olive, drained
local HUNG = rgb(42, 44, 39) -- the blanket he hung up, darker with dust and damp
local HUNG_FOLD = rgb(31, 33, 29) -- its folds turned from the light
local HAIR = rgb(126, 124, 120)
local BOOT = rgb(56, 50, 46)
local RADIO = rgb(66, 64, 60)
local BLACK = rgb(34, 34, 36)
local DISH = rgb(150, 150, 146)
local HEARING_AID = rgb(196, 172, 154)
local LED = rgb(196, 44, 34)
local CABINET = rgb(58, 61, 63)
local CABINET_DARK = rgb(42, 44, 46)
local PAPER = rgb(176, 174, 166)
local INK = rgb(28, 26, 24)

local WAKE_PROMPT: PropKit.PromptSpec = {
	kind = "WakeHim",
	action = "Prompt.WakeHim",
	object = "Prompt.Janitor",
	hold = WAKE_HOLD,
}

local JanitorCotBuilder = {}

JanitorCotBuilder.WakeHold = WAKE_HOLD

local function anchorFrame(layoutId: string, anchor: Anchor): CFrame
	return CFrame.new(WorldConfig.levelOrigin(layoutId) + anchor.pos) * CFrame.Angles(0, math.rad(anchor.yaw or 0), 0)
end

--------------------------------------------------------------------------------
-- The cot and the sleeper
--------------------------------------------------------------------------------

local function planCot(frame: CFrame): { Piece }
	local pieces: { Piece } = {}
	local function box(
		name: string,
		lo: Vector3,
		hi: Vector3,
		key: string,
		color: Color3,
		role: SetDressingBuilder.Role
	)
		table.insert(pieces, Kit.box(frame, name, lo, hi, key, role, { color = color }))
	end
	local function rod(name: string, a: Vector3, b: Vector3, d: number)
		table.insert(pieces, Kit.cylinder(name, frame * a, frame * b, d, "Iron", "Solid", { color = FRAME }))
	end
	local hx, hz = HALF_LENGTH, HALF_WIDTH
	-- the folding frame: two side rails, crossed legs at both ends and the middle
	for i, z in { -hz + 0.08, hz - 0.08 } do
		rod("Rail" .. i, Vector3.new(-hx, RAIL_Y, z), Vector3.new(hx, RAIL_Y, z), 0.14)
	end
	for i, x in { -hx + 0.35, 0, hx - 0.35 } do
		rod("LegA" .. i, Vector3.new(x - 0.35, 0.05, -hz + 0.12), Vector3.new(x + 0.35, RAIL_Y, hz - 0.12), 0.1)
		rod("LegB" .. i, Vector3.new(x - 0.35, 0.05, hz - 0.12), Vector3.new(x + 0.35, RAIL_Y, -hz + 0.12), 0.1)
	end
	box(
		"Canvas",
		Vector3.new(-hx, RAIL_Y - 0.04, -hz + 0.05),
		Vector3.new(hx, RAIL_Y + 0.04, hz - 0.05),
		"Rubber",
		CANVAS,
		"Solid"
	)
	box(
		"Pad",
		Vector3.new(-hx + 0.1, RAIL_Y + 0.04, -hz + 0.15),
		Vector3.new(hx - 0.1, PAD_TOP, hz - 0.15),
		"Carpet",
		PAD,
		"Solid"
	)
	box(
		"Pillow",
		Vector3.new(-hx + 0.2, PAD_TOP, -0.75),
		Vector3.new(-hx + 1.15, PAD_TOP + 0.38, 0.75),
		"PaperSheet",
		PILLOW,
		"Solid"
	)
	-- the shape under the blanket: shoulders and back turned to the room, hips, legs drawn up a little, the feet
	local body: { { name: string, lo: Vector3, hi: Vector3 } } = {
		{ name = "Shoulders", lo = Vector3.new(-2.15, PAD_TOP, -0.55), hi = Vector3.new(-0.9, PAD_TOP + 0.95, 0.75) },
		{ name = "Back", lo = Vector3.new(-1.0, PAD_TOP, -0.6), hi = Vector3.new(0.45, PAD_TOP + 0.85, 0.7) },
		{ name = "Hips", lo = Vector3.new(0.35, PAD_TOP, -0.7), hi = Vector3.new(1.35, PAD_TOP + 0.8, 0.65) },
		{ name = "Legs", lo = Vector3.new(1.25, PAD_TOP, -0.55), hi = Vector3.new(2.75, PAD_TOP + 0.55, 0.5) },
		{ name = "Feet", lo = Vector3.new(2.65, PAD_TOP, -0.45), hi = Vector3.new(3.05, PAD_TOP + 0.65, 0.45) },
	}
	for _, part in body do
		box("Blanket" .. part.name, part.lo, part.hi, "Carpet", BLANKET, "Solid")
	end
	-- its edge hanging down the room side, a fold over the far rail
	box(
		"BlanketDrape",
		Vector3.new(-2.1, 0.75, -hz - 0.06),
		Vector3.new(3.0, PAD_TOP + 0.2, -hz + 0.02),
		"Carpet",
		BLANKET,
		"Solid"
	)
	box(
		"BlanketFold",
		Vector3.new(-1.9, 1.0, hz - 0.02),
		Vector3.new(2.8, PAD_TOP + 0.1, hz + 0.06),
		"Carpet",
		BLANKET,
		"Solid"
	)
	table.insert(
		pieces,
		Kit.ball("Hair", frame * Vector3.new(-2.45, PAD_TOP + 0.45, 0.1), 0.72, "Carpet", "Solid", { color = HAIR })
	)
	-- his work boots at the foot, side by side, one fallen over
	for i, z in { -0.55, 0.1 } do
		local base = frame * CFrame.new(hx + 0.75, 0, z) * CFrame.Angles(0, math.rad(if i == 1 then 8 else -14), 0)
		local tipped = if i == 2 then CFrame.Angles(math.rad(80), 0, 0) * CFrame.new(0, 0.2, 0) else CFrame.new()
		table.insert(
			pieces,
			Kit.block(
				"BootSole" .. i,
				base * tipped * CFrame.new(0, 0.08, 0),
				Vector3.new(1.0, 0.16, 0.42),
				"Rubber",
				"Visible",
				{
					color = BLACK,
				}
			)
		)
		table.insert(
			pieces,
			Kit.block(
				"BootUpper" .. i,
				base * tipped * CFrame.new(-0.2, 0.55, 0),
				Vector3.new(0.55, 0.8, 0.4),
				"Rubber",
				"Visible",
				{ color = BOOT }
			)
		)
	end
	return pieces
end

--------------------------------------------------------------------------------
-- The shelf: radio, hearing aid, clock-radio
--------------------------------------------------------------------------------

-- The highest platform of `room` (the closet's shelf), or nil.
local function shelfOf(layout: Layout, roomId: string): LayoutSchema.Platform?
	local best: LayoutSchema.Platform? = nil
	local platforms: { LayoutSchema.Platform } = layout.platforms or {}
	for _, platform in platforms do
		if platform.room == roomId and (best == nil or platform.top > best.top) then
			best = platform
		end
	end
	return best
end

local function printFace(part: BasePart, face: Enum.NormalId, text: string, ink: Color3, font: Enum.Font, lit: boolean)
	local gui = SurfaceArt.gui(
		part,
		face,
		{ name = "Print", pixelsPerStud = 60, maxDistance = 40, lightInfluence = if lit then 0 else 1 }
	)
	SurfaceArt.text(gui, "Text", text, 0.05, 0.08, 0.9, 0.84, ink, font, 2)
end

-- The shelf's things along its length from its west (or north) end, facing into `room`.
local function buildShelf(model: Model, origin: Vector3, shelf: LayoutSchema.Platform, room: Room)
	local r = shelf.rect
	local alongX = r.w >= r.d
	local top = origin.Y + shelf.top
	local centre = LayoutSchema.rectCenter(room.rect)
	-- facing away from the wall the shelf stands against, toward the room's middle
	local yaw = if alongX
		then (if centre.Y < r.z + r.d / 2 then 0 else 180)
		else (if centre.X < r.x + r.w / 2 then 90 else -90)
	local function at(u: number): (Vector3, CFrame)
		local x = if alongX then r.x + u else r.x + r.w / 2
		local z = if alongX then r.z + r.d / 2 else r.z + u
		local p = Vector3.new(origin.X + x, top, origin.Z + z)
		return p, CFrame.new(p) * CFrame.Angles(0, math.rad(yaw), 0)
	end
	-- the transistor radio, its grille and a raised telescopic aerial
	local _, radioFrame = at(1.2)
	local radio =
		Geometry.part(model, "Radio", radioFrame * CFrame.new(0, 0.36, 0), Vector3.new(1.1, 0.72, 0.42), "ChairShell", {
			color = RADIO,
		})
	local grille = Geometry.part(
		model,
		"RadioGrille",
		radioFrame * CFrame.new(-0.18, 0.36, -0.215),
		Vector3.new(0.6, 0.5, 0.02),
		"Fixture",
		{ color = rgb(120, 120, 116) }
	)
	Geometry.part(
		model,
		"RadioDial",
		radioFrame * CFrame.new(0.35, 0.42, -0.22),
		Vector3.new(0.22, 0.22, 0.03),
		"Fixture",
		{
			color = rgb(170, 168, 160),
		}
	)
	Geometry.cylinder(
		model,
		"RadioAerial",
		radioFrame * Vector3.new(0.45, 0.72, 0),
		radioFrame * Vector3.new(0.95, 2.1, 0.1),
		0.04,
		"Conduit"
	)
	-- the hearing aid in a dish
	local dishAt = at(2.7)
	Geometry.part(
		model,
		"Dish",
		CFrame.new(dishAt + Vector3.new(0, 0.04, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Vector3.new(0.08, 0.62, 0.62),
		"Fixture",
		{ shape = Enum.PartType.Cylinder, color = DISH }
	)
	Geometry.part(
		model,
		"HearingAid",
		CFrame.new(dishAt + Vector3.new(0.05, 0.16, 0.02)),
		Vector3.new(0.2, 0.2, 0.2),
		"Fixture",
		{
			shape = Enum.PartType.Ball,
			color = HEARING_AID,
		}
	)
	Geometry.part(
		model,
		"HearingAidHook",
		CFrame.new(dishAt + Vector3.new(-0.08, 0.2, 0.0)) * CFrame.Angles(0, 0, math.rad(35)),
		Vector3.new(0.05, 0.22, 0.05),
		"Fixture",
		{ color = HEARING_AID }
	)
	-- the clock-radio, its face blinking 12:00 since the power went
	local _, clockFrame = at(4.2)
	Geometry.part(model, "ClockRadio", clockFrame * CFrame.new(0, 0.24, 0), Vector3.new(1.0, 0.48, 0.5), "ChairShell", {
		color = BLACK,
	})
	local face = Geometry.part(
		model,
		"ClockFace",
		clockFrame * CFrame.new(0, 0.26, -0.255),
		Vector3.new(0.7, 0.3, 0.02),
		"Screen",
		{ color = rgb(16, 16, 18) }
	)
	printFace(face, Enum.NormalId.Front, Strings.get("Prop.Gus.Clock"), LED, Enum.Font.Code, true)
	-- small things on a shelf: never in anyone's way; the radio and the clock still answer a look
	for _, part in model:GetChildren() do
		if part:IsA("BasePart") then
			PropKit.detail(part)
			part.CanQuery = part == radio or part.Name == "ClockRadio"
		end
	end
	Geometry.attachment(grille, "Radio", CFrame.new(0, 0, -0.05))
end

local function buildCot(ctx: PropKit.FixtureContext): number
	local layout = ctx.layout
	local built = 0
	for _, anchor in PropKit.anchorsOf(layout, "JanitorCot") do
		local frame = anchorFrame(layout.id, anchor)
		local model = PropKit.model(ctx.parent, "JanitorCot_" .. anchor.id, frame)
		local parts = Kit.realize(model, planCot(frame), nil)
		model.PrimaryPart = parts[1]
		local hair = model:FindFirstChild("Hair") :: BasePart?
		local shoulders = model:FindFirstChild("BlanketShoulders") :: BasePart?
		if hair then
			Geometry.attachment(hair, "Snore", CFrame.new())
		end
		if shoulders then
			local host = Geometry.attachment(shoulders, "PromptPoint", CFrame.new(0, 0.6, 0))
			PropKit.prompt(host, WAKE_PROMPT, model)
		end
		local shelf = shelfOf(layout, anchor.room)
		local room = LayoutSchema.indexRooms(layout)[anchor.room]
		if shelf and room then
			local things = PropKit.model(model, "Shelf", frame)
			buildShelf(things, WorldConfig.levelOrigin(layout.id), shelf, room)
		end
		PropKit.setAttributes(model, { [W.AnchorId] = anchor.id, [W.LevelId] = layout.id })
		built += 1
	end
	return built
end

--------------------------------------------------------------------------------
-- The closet's statics: the hung blanket, the empty hook, the signs
--------------------------------------------------------------------------------

-- A printed card flat on a wall: `centre` on the wall face (world), `normal` out of the wall.
local function card(
	parent: Instance,
	name: string,
	centre: Vector3,
	normal: Vector3,
	size: Vector2,
	text: string,
	font: Enum.Font
): BasePart
	local cframe = CFrame.lookAt(centre + normal * 0.03, centre + normal * 2)
	local part = Geometry.part(parent, name, cframe, Vector3.new(size.X, size.Y, 0.05), "PaperSheet", { color = PAPER })
	PropKit.detail(part)
	part.CanQuery = true
	local gui = SurfaceArt.gui(part, Enum.NormalId.Front, { name = "Print", pixelsPerStud = 40, maxDistance = 45 })
	SurfaceArt.text(gui, "Text", text, 0.06, 0.08, 0.88, 0.84, INK, font, 2)
	SurfaceArt.grime(gui, rgb(60, 56, 50), 0.35, false, 3)
	return part
end

-- The wall faces of `room` (level-local): each side's face coordinate and the normal into the room.
local function faceOf(room: Room, side: LayoutSchema.Side): (number, Vector3)
	local r = room.rect
	if side == "N" then
		return r.z + WALL_HALF, Vector3.new(0, 0, 1)
	elseif side == "S" then
		return r.z + r.d - WALL_HALF, Vector3.new(0, 0, -1)
	elseif side == "W" then
		return r.x + WALL_HALF, Vector3.new(1, 0, 0)
	end
	return r.x + r.w - WALL_HALF, Vector3.new(-1, 0, 0)
end

-- The door of `roomId` and the side of the room it is on.
local function doorOf(layout: Layout, roomId: string): (LayoutSchema.Door?, LayoutSchema.Side?, string?)
	local rooms = LayoutSchema.indexRooms(layout)
	for _, door in layout.doors do
		local i = table.find(door.rooms, roomId)
		if i then
			local other = door.rooms[if i == 1 then 2 else 1]
			local a, b = rooms[roomId], rooms[other]
			local edge = if a and b then LayoutSchema.sharedEdge(a.rect, b.rect) else nil
			if edge then
				local side: LayoutSchema.Side = if edge.axis == "Z"
					then (if math.abs(edge.coord - a.rect.z) < 1e-3 then "N" else "S")
					else (if math.abs(edge.coord - a.rect.x) < 1e-3 then "W" else "E")
				return door, side, other
			end
		end
	end
	return nil, nil, nil
end

local OPPOSITE: { [string]: LayoutSchema.Side } = { N = "S", S = "N", W = "E", E = "W" }

-- The closet's shelf (its platform, a solid steel block to the floor) dressed as the steel supply cabinet it is: on
-- its face toward the room, pairs of doors with their seams, handles and vent slots, a kick plate and a top lip. All
-- of it is Detail 1 laid a few hundredths proud of the face; the platform itself stays the collision.
local function dressCabinet(model: Instance, origin: Vector3, shelf: LayoutSchema.Platform, room: Room)
	local r = shelf.rect
	local alongX = r.w >= r.d
	local centre = LayoutSchema.rectCenter(room.rect)
	local length = if alongX then r.w else r.d
	-- the face toward the room's middle: its centre on the floor and the normal out of it
	local faceCentre: Vector3, normal: Vector3
	if alongX then
		local front = centre.Y < r.z + r.d / 2
		faceCentre = Vector3.new(r.x + r.w / 2, 0, if front then r.z else r.z + r.d)
		normal = Vector3.new(0, 0, if front then -1 else 1)
	else
		local front = centre.X < r.x + r.w / 2
		faceCentre = Vector3.new(if front then r.x else r.x + r.w, 0, r.z + r.d / 2)
		normal = Vector3.new(if front then -1 else 1, 0, 0)
	end
	-- face space: X along the face, Y up, -Z out into the room
	local face = CFrame.lookAt(origin + faceCentre, origin + faceCentre + normal)
	local top = shelf.top
	local function plate(name: string, x: number, y: number, size: Vector3, out: number, key: string, color: Color3)
		local part =
			Geometry.part(model, name, face * CFrame.new(x, y, -(out + size.Z / 2)), size, key, { color = color })
		PropKit.decor(part, 1)
	end
	local kick = 0.45
	local lip = 0.16
	plate("CabinetKick", 0, kick / 2, Vector3.new(length, kick, 0.04), 0.01, "Rubber", BLACK)
	plate("CabinetLip", 0, top - lip / 2, Vector3.new(length + 0.08, lip, 0.12), 0, "CabinetSteel", CABINET_DARK)
	local pairs = math.max(1, math.floor(length / 3.6 + 0.5))
	local doorHeight = top - kick - lip - 0.2
	local doorY = kick + 0.1 + doorHeight / 2
	local doorWidth = length / (pairs * 2) - 0.1
	for p = 1, pairs do
		local pairCentre = -length / 2 + length / pairs * (p - 0.5)
		for side = -1, 1, 2 do
			local x = pairCentre + side * (doorWidth / 2 + 0.05)
			local tag = string.format("%d%s", p, if side < 0 then "L" else "R")
			plate(
				"CabinetDoor" .. tag,
				x,
				doorY,
				Vector3.new(doorWidth, doorHeight, 0.05),
				0.02,
				"CabinetSteel",
				CABINET
			)
			-- the handle by the seam, the vent slots high on the door
			plate(
				"CabinetHandle" .. tag,
				pairCentre + side * 0.28,
				doorY + 0.1,
				Vector3.new(0.08, 0.7, 0.08),
				0.07,
				"Iron",
				BLACK
			)
			for v = 1, 3 do
				plate(
					string.format("CabinetVent%s%d", tag, v),
					x,
					kick + 0.1 + doorHeight - 0.35 - v * 0.16,
					Vector3.new(doorWidth * 0.5, 0.05, 0.02),
					0.07,
					"Rubber",
					BLACK
				)
			end
		end
	end
end

local function buildCloset(ctx: PropKit.StaticContext): number
	local layout = ctx.layout
	local cots = PropKit.anchorsOf(layout, "JanitorCot")
	if #cots == 0 then
		return 0
	end
	local origin = WorldConfig.levelOrigin(layout.id)
	local rooms = LayoutSchema.indexRooms(layout)
	local info = Kit.info(layout)
	local built = 0
	for _, anchor in cots do
		local room = rooms[anchor.room]
		local model = PropKit.model(ctx.parent, "Closet_" .. anchor.id, anchorFrame(layout.id, anchor))
		local frame = anchorFrame(layout.id, anchor)
		-- the blanket hung on a cord between the cot and the room, over its head end; the feet show past it
		local cordA = frame * Vector3.new(-HALF_LENGTH - 0.6, 7.2, -HALF_WIDTH - 0.7)
		local cordB = frame * Vector3.new(HALF_LENGTH + 1.2, 7.2, -HALF_WIDTH - 0.7)
		local cord = Geometry.cylinder(model, "Cord", cordA, cordB, 0.05, "Cable")
		if cord then
			PropKit.decor(cord, 3)
		end
		-- it hangs in folds: narrow panels turned a little each way, their hems ragged
		local folds = 6
		local u0, u1 = -HALF_LENGTH - 0.3, 1.1
		local width = (u1 - u0) / folds
		for i = 1, folds do
			local drop = 5.6 + ((i * 7) % 3) * 0.25
			local swing = if i % 2 == 0 then 14 else -14
			local panel = Geometry.part(
				model,
				"HungBlanket" .. i,
				frame
					* CFrame.new(u0 + width * (i - 0.5), 7.15 - drop / 2, -HALF_WIDTH - 0.7)
					* CFrame.Angles(0, math.rad(swing), 0),
				Vector3.new(width / math.cos(math.rad(14)) + 0.04, drop, 0.08),
				"Carpet",
				{ color = if i % 2 == 0 then HUNG_FOLD else HUNG }
			)
			panel.CanCollide = false
			panel.CanQuery = true
		end
		local shelf = shelfOf(layout, anchor.room)
		if shelf then
			dressCabinet(model, origin, shelf, room)
		end
		-- the empty key hook and its tag on the wall facing the cot
		local farFace, farNormal =
			faceOf(room, OPPOSITE[LayoutSchema.sideOfPoint(room.rect, anchor.pos.X, anchor.pos.Z) or "W"])
		local hookAlong = anchor.pos.Z + 2.5
		local hookAt = if math.abs(farNormal.X) > 0.5
			then Vector3.new(farFace, HOOK_Y, hookAlong)
			else Vector3.new(anchor.pos.X + 2.5, HOOK_Y, farFace)
		local hookWorld = origin + hookAt
		local nail = Geometry.cylinder(model, "Hook", hookWorld, hookWorld + farNormal * 0.32, 0.07, "Iron")
		if nail then
			PropKit.detail(nail)
			nail.CanQuery = true
		end
		card(
			model,
			"HookTag",
			hookWorld + Vector3.new(0, -0.65, 0),
			farNormal,
			Vector2.new(1.1, 0.7),
			Strings.get("Prop.Gus.HookTag"),
			Enum.Font.PatrickHand
		)
		-- the door sign on the corridor side: beside the door where the wall leaves room, else on the corridor's wall
		local door, side, outside = doorOf(layout, anchor.room)
		if door and side and outside then
			local outer = rooms[outside]
			local wallLine = if side == "N"
				then room.rect.z
				elseif side == "S" then room.rect.z + room.rect.d
				elseif side == "W" then room.rect.x
				else room.rect.x + room.rect.w
			local out = if side == "N"
				then Vector3.new(0, 0, -1)
				elseif side == "S" then Vector3.new(0, 0, 1)
				elseif side == "W" then Vector3.new(-1, 0, 0)
				else Vector3.new(1, 0, 0)
			local along = if side == "N" or side == "S" then Vector3.new(1, 0, 0) else Vector3.new(0, 0, 1)
			local half = LayoutSchema.doorWidth(door) / 2
			local spots: { { centre: Vector3, normal: Vector3 } } = {}
			for _, dir in { 1, -1 } do
				local u = door.at + dir * (half + 1.55)
				local base = if side == "N" or side == "S"
					then Vector3.new(u, SIGN_Y, wallLine)
					else Vector3.new(wallLine, SIGN_Y, u)
				table.insert(spots, { centre = base + out * WALL_HALF, normal = out })
			end
			-- the corridor's side walls, a step out from the door wall
			for _, dir in { 1, -1 } do
				local wall: LayoutSchema.Side = if along.X > 0.5
					then (if dir > 0 then "E" else "W")
					else (if dir > 0 then "S" else "N")
				local sideFace, sideNormal = faceOf(outer, wall)
				local alongDoor = wallLine + (out.X + out.Z) * 3.5
				local centre = if along.X > 0.5
					then Vector3.new(sideFace, SIGN_Y, alongDoor)
					else Vector3.new(alongDoor, SIGN_Y, sideFace)
				table.insert(spots, { centre = centre, normal = sideNormal })
			end
			for _, spot in spots do
				local cframe =
					CFrame.lookAt(origin + spot.centre + spot.normal * 0.03, origin + spot.centre + spot.normal * 2)
				local piece = Kit.block("DoorSign", cframe, Vector3.new(1.5, 1.0, 0.05), "PaperSheet", "Visible")
				if Kit.fits(info, { piece }, { room = outside, margin = -0.2 }) then
					card(
						model,
						"DoorSign",
						origin + spot.centre,
						spot.normal,
						Vector2.new(1.5, 1.0),
						Strings.get("Prop.Gus.DoorSign"),
						Enum.Font.PermanentMarker
					)
					break
				end
			end
		end
		built += 1
	end
	-- the night roster on the office wall beside its door
	for _, room in layout.rooms do
		if room.kind ~= "Office" then
			continue
		end
		local door, side = doorOf(layout, room.id)
		if not (door and side) then
			continue
		end
		local face, normal = faceOf(room, side :: LayoutSchema.Side)
		for _, offset in { -11, 11, -7, 7 } do
			local u = door.at + offset
			local centre = if side == "N" or side == "S"
				then Vector3.new(u, SIGN_Y, face)
				else Vector3.new(face, SIGN_Y, u)
			local cframe = CFrame.lookAt(origin + centre + normal * 0.03, origin + centre + normal * 2)
			local piece = Kit.block("Roster", cframe, Vector3.new(2.2, 1.4, 0.05), "PaperSheet", "Visible")
			if Kit.fits(info, { piece }, { room = room.id, margin = -0.2 }) then
				card(
					ctx.parent,
					"Roster_" .. room.id,
					origin + centre,
					normal,
					Vector2.new(2.2, 1.4),
					Strings.get("Prop.Gus.Roster"),
					Enum.Font.SpecialElite
				)
				built += 1
				break
			end
		end
		break
	end
	return built
end

function JanitorCotBuilder.register(registrar: PropKit.Registrar)
	registrar.fixture("JanitorCot", buildCot)
	registrar.static("JanitorCloset", buildCloset)
end

return table.freeze(JanitorCotBuilder)
