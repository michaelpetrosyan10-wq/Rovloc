--!strict
-- MopCartBuilder: Gus's trail (docs/design/game-spec-v2.md 4.3): a janitor's cart on every MopCart anchor of a layout
-- (static kind "MopCart": once at boot, into <level>.Props), each with its mop bucket and a WET FLOOR A-frame. They
-- are landmarks a squad finds its way by, so no piece is Detail: the cart, bucket and mop collide with players and let
-- the Creature through (MonsterPassthrough); the sign is seen and queried but never collides.
--
-- Cart space (the anchor's frame): origin on the floor under the cart's middle, X along the wall (the push handle at
-- +X, the bin bag at -X, the bucket and the sign beyond it), -Z out into the run, +Z to the wall behind. Two carts
-- carry the objective's key hook on the handle's crossbar (keySpot: a MasterKeyCandidate facing +X, the ring hanging
-- clear of the cart); four carry a flask spot on the top tray (flaskSpot). The layout asks for both from here, so the
-- anchors and the cart always agree. Clearance (Length / Depth) is what ExtraAnchors and the dressing keep free.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Strings = require(ReplicatedStorage.Shared.Strings)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local PropKit = require(script.Parent.PropKit)
local SetDressingBuilder = require(script.Parent.SetDressingBuilder)
local SurfaceArt = require(script.Parent.Parent.SurfaceArt)

type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor
type Piece = SetDressingBuilder.Piece

local Kit = SetDressingBuilder.Kit
local W = Attributes.World

local rgb = Color3.fromRGB

-- The cart (studs, cart space)
local HALF_LENGTH = 2.0
local HALF_DEPTH = 0.85
local BASE_Y = { 0.42, 0.62 }
local TOP_Y = { 2.78, 3.0 }
local RIM = 0.16
local POST = 0.16
local HANDLE_X = 2.18
local HANDLE_TOP = 3.6
local CROSSBAR_Y = 3.15
local WHEEL = 0.42
local BAG_X = { -2.75, -2.0 }
-- The bucket and the mop beyond the bag; the sign beyond them
local BUCKET_X = { -4.35, -2.95 }
local BUCKET_TOP = 1.5
local SIGN_X = -5.6
local BOARD = Vector2.new(1.15, 2.05)
local BOARD_LEAN = math.rad(13)

local PLASTIC = rgb(76, 78, 80)
local PLASTIC_DARK = rgb(56, 58, 60)
local FRAME = rgb(72, 74, 76)
local BAG = rgb(30, 31, 33)
local MOP = rgb(150, 148, 142)
local INK = rgb(24, 22, 18)

local MopCartBuilder = {}

-- How far the cart, its bucket and its sign reach along the wall from the anchor (each way, the sign's side the far
-- one) and out from the wall (the anchor stands this far off the wall face).
MopCartBuilder.Reach = table.freeze({ minX = SIGN_X - 1.0, maxX = HANDLE_X + 0.5, depth = HALF_DEPTH * 2 + 0.6 })
MopCartBuilder.WallOffset = HALF_DEPTH + 0.45

local function frameOf(pos: Vector3, yaw: number): CFrame
	return CFrame.new(pos) * CFrame.Angles(0, math.rad(yaw), 0)
end

-- The key hook on a cart standing at `pos` (level-local floor point) turned `yaw`: the nail point on the crossbar's
-- outer face, facing along the cart away from it.
function MopCartBuilder.keySpot(pos: Vector3, yaw: number): { pos: Vector3, yaw: number }
	local p = frameOf(pos, yaw) * Vector3.new(HANDLE_X + POST / 2 + 0.02, CROSSBAR_Y, 0)
	return { pos = p, yaw = yaw - 90 }
end

-- The flask spot on a cart's top tray.
function MopCartBuilder.flaskSpot(pos: Vector3, yaw: number): { pos: Vector3, yaw: number }
	local p = frameOf(pos, yaw) * Vector3.new(0.6, TOP_Y[2], 0.1)
	return { pos = p, yaw = yaw }
end

local function paintSign(part: BasePart)
	local gui, pps = SurfaceArt.gui(part, Enum.NormalId.Front, { name = "Print", pixelsPerStud = 20, maxDistance = 70 })
	SurfaceArt.text(gui, "Caution", Strings.get("Prop.Sign.Caution"), 0.08, 0.06, 0.84, 0.2, INK, Enum.Font.Oswald, 2)
	SurfaceArt.text(gui, "Text", Strings.get("Prop.Sign.WetFloor"), 0.08, 0.3, 0.84, 0.3, INK, Enum.Font.GothamBlack, 2)
	local band = SurfaceArt.frame(gui, "Band", 0, 0.86, 1, 0.1, INK, 0, 1)
	band.ClipsDescendants = true
	SurfaceArt.hazard(band, Vector2.new(BOARD.X, BOARD.Y * 0.1), pps, 0.12)
	SurfaceArt.grime(gui, rgb(40, 38, 34), 0.35, false, 4)
end

-- Every piece of one cart, its bucket and its sign, in world space.
local function planCart(frame: CFrame, name: string): { Piece }
	local pieces: { Piece } = {}
	local function solid(part: string, lo: Vector3, hi: Vector3, key: string, color: Color3)
		table.insert(pieces, Kit.box(frame, name .. "_" .. part, lo, hi, key, "Solid", { color = color }))
	end
	local function rod(part: string, a: Vector3, b: Vector3, diameter: number, key: string, color: Color3)
		table.insert(
			pieces,
			Kit.cylinder(name .. "_" .. part, frame * a, frame * b, diameter, key, "Solid", { color = color })
		)
	end
	local hx, hz = HALF_LENGTH, HALF_DEPTH
	-- trays, the top one rimmed
	solid("Base", Vector3.new(-hx, BASE_Y[1], -hz), Vector3.new(hx, BASE_Y[2], hz), "ChairShell", PLASTIC)
	solid("Top", Vector3.new(-hx, TOP_Y[1], -hz), Vector3.new(hx, TOP_Y[2], hz), "ChairShell", PLASTIC)
	solid(
		"RimFront",
		Vector3.new(-hx, TOP_Y[2], -hz),
		Vector3.new(hx, TOP_Y[2] + RIM, -hz + 0.08),
		"ChairShell",
		PLASTIC
	)
	solid("RimBack", Vector3.new(-hx, TOP_Y[2], hz - 0.08), Vector3.new(hx, TOP_Y[2] + RIM, hz), "ChairShell", PLASTIC)
	-- corner posts
	for i, c in { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } } do
		local x, z = c[1] * (hx - 0.15), c[2] * (hz - 0.15)
		rod("Post" .. i, Vector3.new(x, BASE_Y[2], z), Vector3.new(x, TOP_Y[1], z), POST, "CabinetSteel", FRAME)
	end
	-- the push handle: two uprights, the grip on top and the crossbar the key hook is driven into
	for i, z in { -0.62, 0.62 } do
		rod(
			"Handle" .. i,
			Vector3.new(HANDLE_X, BASE_Y[2], z),
			Vector3.new(HANDLE_X, HANDLE_TOP, z),
			POST,
			"CabinetSteel",
			FRAME
		)
	end
	rod(
		"Grip",
		Vector3.new(HANDLE_X, HANDLE_TOP, -0.7),
		Vector3.new(HANDLE_X, HANDLE_TOP, 0.7),
		0.2,
		"Rubber",
		PLASTIC_DARK
	)
	rod(
		"Crossbar",
		Vector3.new(HANDLE_X, CROSSBAR_Y, -0.62),
		Vector3.new(HANDLE_X, CROSSBAR_Y, 0.62),
		POST,
		"CabinetSteel",
		FRAME
	)
	-- wheels
	for i, c in { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } } do
		local x, z = c[1] * (hx - 0.35), c[2] * (hz - 0.05)
		rod(
			"Wheel" .. i,
			Vector3.new(x, WHEEL / 2, z - 0.09),
			Vector3.new(x, WHEEL / 2, z + 0.09),
			WHEEL,
			"Rubber",
			PLASTIC_DARK
		)
	end
	-- the bin bag hung off the far end, sagging round under its knot
	solid("Bag", Vector3.new(BAG_X[1], BASE_Y[2] + 0.5, -0.72), Vector3.new(BAG_X[2], TOP_Y[2], 0.72), "Rubber", BAG)
	local bagMid = (BAG_X[1] + BAG_X[2]) / 2
	table.insert(
		pieces,
		Kit.ball(name .. "_BagBelly", frame * Vector3.new(bagMid, BASE_Y[2] + 0.7, 0), 1.2, "Rubber", "Solid", {
			color = BAG,
		})
	)
	table.insert(
		pieces,
		Kit.ball(name .. "_BagKnot", frame * Vector3.new(bagMid, TOP_Y[2] + 0.12, 0.1), 0.42, "Rubber", "Visible", {
			color = BAG,
		})
	)
	-- the mop bucket (round, on its casters), its grey water, the wringer and the mop leaning out of it
	local bucketMid = (BUCKET_X[1] + BUCKET_X[2]) / 2
	local bucketWidth = BUCKET_X[2] - BUCKET_X[1]
	rod(
		"Bucket",
		Vector3.new(bucketMid, 0.12, 0),
		Vector3.new(bucketMid, BUCKET_TOP, 0),
		bucketWidth,
		"ChairShell",
		PLASTIC
	)
	rod(
		"BucketRim",
		Vector3.new(bucketMid, BUCKET_TOP - 0.08, 0),
		Vector3.new(bucketMid, BUCKET_TOP + 0.04, 0),
		bucketWidth + 0.12,
		"ChairShell",
		PLASTIC_DARK
	)
	table.insert(
		pieces,
		Kit.disc(
			name .. "_Water",
			frame * Vector3.new(bucketMid, BUCKET_TOP + 0.04, 0),
			bucketWidth - 0.2,
			0.03,
			"Puddle",
			"Visible"
		)
	)
	for i, c in { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } } do
		local x, z = bucketMid + c[1] * bucketWidth * 0.32, c[2] * bucketWidth * 0.32
		rod("Caster" .. i, Vector3.new(x, 0.06, z - 0.05), Vector3.new(x, 0.06, z + 0.05), 0.12, "Rubber", PLASTIC_DARK)
	end
	-- the wringer on the bucket's rim: two side cheeks, the press between them and its lever
	for i, z in { -0.52, 0.52 } do
		solid(
			"WringerCheek" .. i,
			Vector3.new(BUCKET_X[2] - 0.5, BUCKET_TOP, z - 0.05),
			Vector3.new(BUCKET_X[2] - 0.1, BUCKET_TOP + 0.75, z + 0.05),
			"CabinetSteel",
			PLASTIC_DARK
		)
	end
	solid(
		"WringerPress",
		Vector3.new(BUCKET_X[2] - 0.42, BUCKET_TOP + 0.2, -0.47),
		Vector3.new(BUCKET_X[2] - 0.3, BUCKET_TOP + 0.65, 0.47),
		"CabinetSteel",
		FRAME
	)
	rod(
		"WringerLever",
		Vector3.new(BUCKET_X[2] - 0.3, BUCKET_TOP + 0.6, 0),
		Vector3.new(BUCKET_X[2] - 0.15, BUCKET_TOP + 2.2, 0.15),
		0.1,
		"CabinetSteel",
		FRAME
	)
	rod("Mop", Vector3.new(-3.85, 1.0, 0.05), Vector3.new(-3.35, 5.7, 0.4), 0.12, "WoodPanel", rgb(80, 78, 74))
	solid("MopHead", Vector3.new(-4.2, 0.9, -0.4), Vector3.new(-3.5, 1.45, 0.45), "PaperSheet", MOP)
	-- WET FLOOR: an A-frame whose boards face along the run, both ways
	local base = frame * CFrame.new(SIGN_X, 0, -0.2) * CFrame.Angles(0, math.rad(90), 0)
	local apex = BOARD.Y * math.cos(BOARD_LEAN)
	-- each board leans out from the apex, its printed Front face outward
	for i = 1, 2 do
		local cframe = base
			* CFrame.Angles(0, if i == 2 then math.pi else 0, 0)
			* CFrame.new(0, apex, 0)
			* CFrame.Angles(BOARD_LEAN, 0, 0)
			* CFrame.new(0, -BOARD.Y / 2, 0.03)
		local board = Kit.block(
			name .. "_WetFloor" .. i,
			cframe,
			Vector3.new(BOARD.X, BOARD.Y, 0.06),
			"HazardYellow",
			"Visible",
			{ castShadow = false }
		)
		table.insert(pieces, board)
	end
	return pieces
end

local function buildCarts(ctx: PropKit.StaticContext): number
	local carts = PropKit.anchorsOf(ctx.layout, "MopCart")
	if #carts == 0 then
		return 0
	end
	local origin = WorldConfig.levelOrigin(ctx.layout.id)
	local built = 0
	for _, anchor in carts do
		local frame = CFrame.new(origin) * frameOf(anchor.pos, anchor.yaw or 0)
		local model = PropKit.model(ctx.parent, anchor.id, frame)
		local parts = Kit.realize(model, planCart(frame, "Cart"), nil)
		for _, part in parts do
			if string.find(part.Name, "WetFloor", 1, true) then
				paintSign(part)
			end
		end
		model.PrimaryPart = parts[1]
		PropKit.setAttributes(model, { [W.AnchorId] = anchor.id, [W.LevelId] = ctx.layout.id })
		built += #parts
	end
	return built
end

function MopCartBuilder.register(registrar: PropKit.Registrar)
	registrar.static("MopCart", buildCarts)
end

return table.freeze(MopCartBuilder)
