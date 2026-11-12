--!strict
-- BackLotBuilder: the Back Lot, the opening's set and the prologue's walk (docs/design/game-spec-v2.md 4.1, 2.4), and
-- the coal chute's two ends.
--
--   * build(parent): the set, once at boot into School.Exterior.BackLot (ProceduralWorldBuilder calls it after the
--     exterior; SchoolShellBuilder builds the facade's staff doors, strobe and window cards). The lot is asphalt south
--     of the south facade, x 0..80, z 288.75 (the facade's face) .. 350, closed by a chain-link fence 10 high (an
--     invisible wall over it to 14) on its west, south and east sides, the chained street gate in the south side; the
--     facade closes the north. On it: the four bins (one per squad slot: Dumpster A, the skip, the wheelie bin,
--     Dumpster B), each hollow with a hinged lid (leaf "Lid", its PushLid prompt), a BinStart anchor on its floor and
--     Attachment "ClimbOut" where the climb-out lands; the DISCARD boxes and the torn MASQUE crate by Dumpster A; the
--     yard lamp on its 16-stud pole (light group Scripted:BL_Lamp); the coal-chute hatch against the facade (leaves
--     "DoorL" / "DoorR", its ClimbIn prompt, Attachment "ClimbIn", the ChuteHatch trigger over it); the cutscene marks
--     the opening's timelines are laid out from; a bike rack, a basketball hoop, pallets and puddles (Detail 2-3).
--     Anchors carry LevelId "BackLot" (the set, WorldConfig.Sets); nothing here is a hide, a noise or a Creature
--     place: no hiding rules, no noise and no monster in the lot. The bins, crates and fence collide; the rest is
--     dressing.
--   * Static "ChuteMouth": the chute's mouth on every CutsceneMark named "<prefix>_Mark_ChuteMouth" (the Basement's
--     delivery bay): a steel hood on the wall, the dark opening and a sloped steel trough the squad slides out of,
--     coal dust spilled under it.
--
-- Set numbers (Set): world x, z on the street's ground (y = WorldConfig.GroundY; the sidewalk ring, 0.35 higher,
-- covers z < 300). The bins stand 10 studs nearer the facade than 4.1's table (a spec amendment): there every bin was
-- 48-50 studs from the hatch, outside the prologue's 25-45.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(script.Parent.Parent.Geometry)
local PropKit = require(script.Parent.PropKit)
local SchoolShellBuilder = require(script.Parent.Parent.SchoolShellBuilder)
local SurfaceArt = require(script.Parent.Parent.SurfaceArt)

type Anchor = LayoutSchema.Anchor

local W = Attributes.World

local rgb = Color3.fromRGB

local SET_ID = "BackLot"
local ZONE = "BL_Lot"
local GROUND = WorldConfig.GroundY
local SIDEWALK_Z = 300 -- the sidewalk ring (SchoolShellBuilder.Exterior) ends here
local SIDEWALK = SchoolShellBuilder.Exterior.sidewalkHeight
local FACADE_FACE = 288 + WorldConfig.ExteriorWallThickness / 2

local LID_HOLD = 0.6
local CLIMB_HOLD = 0.6

export type Bin = {
	slot: number,
	name: string,
	kind: "Dumpster" | "Skip" | "Wheelie",
	x: number,
	z: number,
	size: Vector3, -- outer: length (x), height, depth (z)
}

-- The set (world x / z; see the header)
local Set = {
	lot = { x0 = 0, x1 = 80, z0 = FACADE_FACE, z1 = 350 },
	fenceHeight = 10,
	wallHeight = 14,
	postSpacing = 8,
	gate = { x0 = 20, x1 = 36 },
	lamp = Vector3.new(28, GROUND, 320),
	lampHeight = 16,
	hatch = { x = 30, z = 290.5, width = 5, depth = 3.6, rise = 1.6 },
	bins = {
		{ slot = 1, name = "DumpsterA", kind = "Dumpster", x = 10, z = 324, size = Vector3.new(6.4, 4.4, 3.8) },
		{ slot = 2, name = "Skip", kind = "Skip", x = 34, z = 328, size = Vector3.new(9, 4.2, 5) },
		{ slot = 3, name = "WheelieBin", kind = "Wheelie", x = 48, z = 326, size = Vector3.new(2.8, 4.6, 3) },
		{ slot = 4, name = "DumpsterB", kind = "Dumpster", x = 22, z = 330, size = Vector3.new(6.4, 4.4, 3.8) },
	} :: { Bin },
	-- where the climb-out sets a player down: in front of the bin (its north side), this far off it
	climbOut = 1.8,
	-- the cutscene marks (2.4): the lot's origin, the staff doors, Danny by Dumpster A (where the Tall Man unfolds),
	-- the gate, the lamp, the hatch
	marks = {
		{ id = "BL_Mark_Origin", pos = WorldConfig.Sets.BackLot.origin, yaw = 180 },
		{ id = "BL_Mark_StaffDoors", pos = Vector3.new(60, GROUND + SIDEWALK, 291), yaw = 180 },
		{ id = "BL_Mark_Danny", pos = Vector3.new(15, GROUND, 319), yaw = 150 },
		{ id = "BL_Mark_Gate", pos = Vector3.new(28, GROUND, 347), yaw = 180 },
		{ id = "BL_Mark_Lamp", pos = Vector3.new(28, GROUND, 320), yaw = 0 },
		{ id = "BL_Mark_Hatch", pos = Vector3.new(30, GROUND + SIDEWALK, 294.5), yaw = 0 },
	},
	lampGroup = "Scripted:BL_Lamp",
}

local BackLotBuilder = {}

BackLotBuilder.Set = Set
BackLotBuilder.LidHold = LID_HOLD
BackLotBuilder.ClimbHold = CLIMB_HOLD

local STEEL = rgb(86, 90, 92)
local STEEL_DARK = rgb(58, 61, 63)
local BIN_STEEL = rgb(54, 66, 54) -- dumpster-green paint gone dull, the rust showing through
local LID = rgb(32, 34, 30)
local HATCH_PLATE = rgb(70, 60, 50) -- the chute doors' tread plate, scuffed and rusting
local MESH = rgb(120, 124, 126)
local CARDBOARD = rgb(106, 86, 60)
local CRATE = rgb(88, 68, 46)
local INK = rgb(30, 28, 26)

-- The ground under (x, z): the sidewalk ring or the asphalt.
function BackLotBuilder.groundAt(z: number): number
	return if z < SIDEWALK_Z then GROUND + SIDEWALK else GROUND
end

local function solid(parent: Instance, name: string, cframe: CFrame, size: Vector3, key: string, color: Color3?): Part
	local part = Geometry.part(parent, name, cframe, size, key, { color = color })
	part.CanCollide = true
	part.CanQuery = true
	return part
end

local function decor(
	parent: Instance,
	name: string,
	cframe: CFrame,
	size: Vector3,
	key: string,
	color: Color3?,
	level: number
)
	local part = Geometry.part(parent, name, cframe, size, key, { color = color })
	PropKit.decor(part, level)
	return part
end

local function rod(
	parent: Instance,
	name: string,
	a: Vector3,
	b: Vector3,
	diameter: number,
	key: string,
	color: Color3?
): Part?
	return Geometry.cylinder(parent, name, a, b, diameter, key, { color = color })
end

local function printOn(part: BasePart, face: Enum.NormalId, text: string, ink: Color3, font: Enum.Font)
	local gui = SurfaceArt.gui(part, face, { name = "Print", pixelsPerStud = 30, maxDistance = 60 })
	SurfaceArt.text(gui, "Text", text, 0.06, 0.12, 0.88, 0.76, ink, font, 2)
	SurfaceArt.grime(gui, rgb(70, 54, 30), 0.4, false, 3)
end

local function anchorAttachment(root: BasePart, id: string, kind: string, cframe: CFrame): Attachment
	local attachment = Geometry.attachment(root, id, root.CFrame:ToObjectSpace(cframe))
	PropKit.setAttributes(attachment, {
		[W.AnchorId] = id,
		[W.AnchorKind] = kind,
		[W.LevelId] = SET_ID,
		[W.ZoneId] = ZONE,
	})
	return attachment
end

--------------------------------------------------------------------------------
-- The fence and the gate
--------------------------------------------------------------------------------

-- One straight run of fence from a to b (world, on the ground): posts at most postSpacing apart, a mesh panel and a top
-- rail between each pair, the invisible wall over it.
local function fenceRun(parent: Instance, name: string, a: Vector3, b: Vector3)
	local length = (b - a).Magnitude
	local dir = (b - a).Unit
	local n = math.max(1, math.ceil(length / Set.postSpacing))
	local top = Set.fenceHeight
	for i = 0, n do
		local p = a + dir * (length * i / n)
		rod(
			parent,
			string.format("%s_Post%d", name, i),
			p,
			p + Vector3.new(0, top + 0.3, 0),
			0.32,
			"MetalGalvanized",
			STEEL
		)
		if i == n then
			break
		end
		local q = a + dir * (length * (i + 1) / n)
		local mid = (p + q) / 2
		local span = (q - p).Magnitude
		local frame =
			CFrame.lookAt(mid + Vector3.new(0, top / 2, 0), mid + Vector3.new(0, top / 2, 0) + dir:Cross(Vector3.yAxis))
		local panel = Geometry.part(
			parent,
			string.format("%s_Mesh%d", name, i),
			frame,
			Vector3.new(span, top - 0.15, 0.06),
			"MetalGalvanized",
			{
				color = MESH,
				transparency = 0.62,
			}
		)
		panel.CanCollide = true
		panel.CastShadow = false
		local gui = SurfaceArt.gui(panel, Enum.NormalId.Front, { name = "Wire", pixelsPerStud = 8, maxDistance = 90 })
		SurfaceArt.grid(
			gui,
			math.max(2, math.floor(span * 1.6)),
			math.max(2, math.floor(top * 1.6)),
			STEEL_DARK,
			0.15,
			1
		)
		rod(
			parent,
			string.format("%s_Rail%d", name, i),
			p + Vector3.new(0, top, 0),
			q + Vector3.new(0, top, 0),
			0.18,
			"MetalGalvanized",
			STEEL
		)
	end
	-- the invisible wall over it, to wallHeight: nobody climbs out of the set
	local mid = (a + b) / 2
	local wall = Geometry.part(
		parent,
		name .. "_Wall",
		CFrame.lookAt(
			mid + Vector3.new(0, Set.wallHeight / 2, 0),
			mid + Vector3.new(0, Set.wallHeight / 2, 0) + dir:Cross(Vector3.yAxis)
		),
		Vector3.new(length, Set.wallHeight, 0.6),
		"Concrete",
		{ transparency = 1, canCollide = true, canQuery = false, castShadow = false }
	)
	wall.CanTouch = false
end

local function buildGate(parent: Instance)
	local g = Set.gate
	local z = Set.lot.z1
	local half = (g.x1 - g.x0) / 2
	local top = Set.fenceHeight
	for i, side in { { g.x0, 1 }, { g.x1, -1 } } do
		local x0 = side[1]
		local hinge = Vector3.new(x0, GROUND, z)
		rod(parent, "GatePost" .. i, hinge, hinge + Vector3.new(0, top + 0.4, 0), 0.42, "MetalGalvanized", STEEL)
		local leaf = Instance.new("Model")
		leaf.Name = "GateLeaf" .. i
		leaf.Parent = parent
		local cx = x0 + side[2] * half / 2
		for _, y in { 0.4, top - 0.2 } do
			rod(
				leaf,
				"Rail",
				Vector3.new(x0, GROUND + y, z),
				Vector3.new(x0 + side[2] * (half - 0.1), GROUND + y, z),
				0.16,
				"MetalGalvanized",
				STEEL
			)
		end
		rod(
			leaf,
			"Stile",
			Vector3.new(x0 + side[2] * (half - 0.1), GROUND + 0.4, z),
			Vector3.new(x0 + side[2] * (half - 0.1), GROUND + top - 0.2, z),
			0.16,
			"MetalGalvanized",
			STEEL
		)
		local panel = Geometry.part(
			leaf,
			"Mesh",
			CFrame.new(cx, GROUND + top / 2, z),
			Vector3.new(half - 0.2, top - 0.6, 0.06),
			"MetalGalvanized",
			{
				color = MESH,
				transparency = 0.62,
			}
		)
		panel.CanCollide = true
		panel.CastShadow = false
		local gui = SurfaceArt.gui(panel, Enum.NormalId.Front, { name = "Wire", pixelsPerStud = 8, maxDistance = 90 })
		SurfaceArt.grid(gui, math.floor(half * 1.6), math.floor(top * 1.6), STEEL_DARK, 0.15, 1)
	end
	-- the chain round both stiles where they meet, and its padlock; the "Chained." prompt
	local meet = Vector3.new((g.x0 + g.x1) / 2, GROUND + 4.2, z)
	for i = 0, 5 do
		local link = Geometry.part(
			parent,
			"Chain" .. i,
			CFrame.new(meet + Vector3.new(math.sin(i) * 0.25, -i * 0.18, -0.12 + (i % 2) * 0.24))
				* CFrame.Angles(0, 0, i * 0.9),
			Vector3.new(0.32, 0.2, 0.06),
			"Iron",
			{ color = STEEL_DARK }
		)
		PropKit.decor(link, 3)
	end
	local lock = solid(
		parent,
		"Padlock",
		CFrame.new(meet + Vector3.new(0, -1.3, -0.15)),
		Vector3.new(0.5, 0.6, 0.22),
		"Iron",
		STEEL_DARK
	)
	lock.CanCollide = false
	PropKit.prompt(lock, {
		kind = "Locked",
		action = "Prop.BackLot.Chained",
		object = "Prompt.StreetGate",
		hold = 0,
	})
	-- the invisible wall over the gate, as over the fence
	local wall = Geometry.box(
		parent,
		"Gate_Wall",
		Vector3.new(g.x0, GROUND, z - 0.3),
		Vector3.new(g.x1, GROUND + Set.wallHeight, z + 0.3),
		"Concrete",
		{ transparency = 1, canCollide = true, canQuery = false, castShadow = false }
	)
	if wall then
		wall.CanTouch = false
	end
end

--------------------------------------------------------------------------------
-- The bins
--------------------------------------------------------------------------------

-- One bin: a hollow steel body on the ground (front to the north, the facade), its lid hinged along the back, the
-- slot's BinStart on its floor, ClimbOut in front of it.
local function buildBin(parent: Instance, root: BasePart, bin: Bin): Model
	local size = bin.size
	local base = CFrame.new(bin.x, GROUND, bin.z)
	local model = PropKit.model(parent, "Bin_" .. bin.name, base)
	local hx, hz, h = size.X / 2, size.Z / 2, size.Y
	local t = 0.18
	local color = if bin.kind == "Wheelie" then rgb(40, 52, 42) else BIN_STEEL
	local key = if bin.kind == "Wheelie" then "ChairShell" else "MetalRust"
	local floor = solid(model, "Floor", base * CFrame.new(0, 0.35, 0), Vector3.new(size.X, 0.3, size.Z), key, color)
	model.PrimaryPart = floor
	-- the walls; a skip's ends slope out
	solid(model, "Front", base * CFrame.new(0, h / 2 + 0.2, -hz + t / 2), Vector3.new(size.X, h - 0.4, t), key, color)
	solid(model, "Back", base * CFrame.new(0, h / 2 + 0.2, hz - t / 2), Vector3.new(size.X, h - 0.4, t), key, color)
	for i, s in { -1, 1 } do
		local tilt = if bin.kind == "Skip" then CFrame.Angles(0, 0, math.rad(-s * 18)) else CFrame.new()
		solid(
			model,
			"End" .. i,
			base * CFrame.new(s * (hx - t / 2), h / 2 + 0.2, 0) * tilt,
			Vector3.new(t, h - 0.4, size.Z),
			key,
			color
		)
	end
	-- the pressed ribs down the long sides and the rolled rim round the top (a skip's sloped ends keep theirs plain)
	local ribs: { number } = if bin.kind == "Wheelie" then { -0.5, 0.5 } else { -0.72, -0.24, 0.24, 0.72 }
	for side, s in { -1, 1 } do
		for i, u in ribs do
			decor(
				model,
				string.format("Rib%d%d", side, i),
				base * CFrame.new(u * hx, h / 2 + 0.1, s * (hz + 0.06)),
				Vector3.new(0.2, h - 0.8, 0.12),
				"MetalGalvanized",
				STEEL_DARK,
				2
			)
		end
		decor(
			model,
			"RimSide" .. side,
			base * CFrame.new(0, h - 0.12, s * (hz + 0.1)),
			Vector3.new(size.X + 0.2, 0.26, 0.14),
			"MetalGalvanized",
			STEEL_DARK,
			1
		)
		if bin.kind ~= "Skip" then
			decor(
				model,
				"RimEnd" .. side,
				base * CFrame.new(s * (hx + 0.1), h - 0.12, 0),
				Vector3.new(0.14, 0.26, size.Z + 0.34),
				"MetalGalvanized",
				STEEL_DARK,
				1
			)
		end
	end
	-- the wheels or skids
	for i, s in { -1, 1 } do
		if bin.kind == "Skip" then
			solid(
				model,
				"Skid" .. i,
				base * CFrame.new(0, 0.1, s * (hz - 0.6)),
				Vector3.new(size.X - 0.4, 0.2, 0.5),
				"Iron",
				STEEL_DARK
			)
		else
			for j, x in { -1, 1 } do
				local wheel = rod(
					model,
					string.format("Wheel%d%d", i, j),
					Vector3.new(bin.x + x * (hx - 0.5), GROUND + 0.2, bin.z + s * (hz - 0.4) - 0.1),
					Vector3.new(bin.x + x * (hx - 0.5), GROUND + 0.2, bin.z + s * (hz - 0.4) + 0.1),
					0.4,
					"Rubber",
					LID
				)
				if wheel then
					PropKit.decor(wheel, 3)
				end
			end
		end
	end
	if bin.kind == "Dumpster" then
		-- the forklift pockets either end
		for i, s in { -1, 1 } do
			decor(
				model,
				"Pocket" .. i,
				base * CFrame.new(s * (hx + 0.12), 1.6, 0),
				Vector3.new(0.24, 0.5, size.Z * 0.7),
				"Iron",
				STEEL_DARK,
				2
			)
		end
	end
	-- the lid: hinged along the back edge, resting shut but for a finger's gap at the front (Dumpster A's ajar)
	local hinge = base * CFrame.new(0, h + 0.05, hz)
	local lid = PropKit.leaf(model, "Lid", hinge)
	local ajar = if bin.slot == 1 then math.rad(9) else math.rad(2.5)
	local lidFrame = hinge * CFrame.Angles(ajar, 0, 0) * CFrame.new(0, 0.06, -hz)
	solid(lid, "Lid", lidFrame, Vector3.new(size.X + 0.1, 0.12, size.Z + 0.1), "Rubber", LID)
	solid(
		lid,
		"LidLip",
		lidFrame * CFrame.new(0, -0.14, -hz + 0.02),
		Vector3.new(size.X + 0.1, 0.28, 0.08),
		"Rubber",
		LID
	)
	local promptAt =
		Geometry.attachment(floor, "PromptPoint", floor.CFrame:ToObjectSpace(base * CFrame.new(0, h - 0.6, -hz + 0.6)))
	PropKit.prompt(
		promptAt,
		{ kind = "PushLid", action = "Prompt.PushLid", object = "Prompt.Bin", hold = LID_HOLD },
		model
	)
	-- where the slot's player starts (on the floor, facing the gap), and where the climb-out sets them down
	local start = base * CFrame.new(0, 0.5, 0)
	local attachment = anchorAttachment(root, string.format("BL_BinStart_%d", bin.slot), "BinStart", start)
	attachment:SetAttribute(W.Slot, bin.slot)
	Geometry.attachment(
		floor,
		"ClimbOut",
		floor.CFrame:ToObjectSpace(CFrame.new(bin.x, GROUND, bin.z - hz - Set.climbOut))
	)
	PropKit.setAttributes(model, { [W.LevelId] = SET_ID, [W.Slot] = bin.slot })
	return model
end

-- The DISCARD boxes and the torn MASQUE crate beside Dumpster A (2.4's S5).
local function buildDiscards(parent: Instance, bin: Bin)
	local x0 = bin.x - bin.size.X / 2 - 2.8
	for i, b in { { 0, 0, 2.2, 1.6, 1.8, 6 }, { 0.15, 1.6, 1.9, 1.3, 1.6, -9 }, { -0.4, 0, 1.9, 1.3, 1.5, 21 } } do
		local cframe = CFrame.new(x0 + b[1], GROUND + b[2] + b[4] / 2, bin.z - 0.8 + i * 0.7)
			* CFrame.Angles(0, math.rad(b[6]), 0)
		local box = solid(parent, "DiscardBox" .. i, cframe, Vector3.new(b[3], b[4], b[5]), "PaperSheet", CARDBOARD)
		if i == 1 then
			printOn(box, Enum.NormalId.Back, Strings.get("Prop.BackLot.Discard"), INK, Enum.Font.PermanentMarker)
		end
	end
	-- the crate in front of the dumpster, its lid prised off and leaning on it
	local crate = CFrame.new(bin.x + 1.2, GROUND, bin.z - bin.size.Z / 2 - 1.5) * CFrame.Angles(0, math.rad(-12), 0)
	local body =
		solid(parent, "MasqueCrate", crate * CFrame.new(0, 0.75, 0), Vector3.new(2.4, 1.5, 1.6), "WoodPanel", CRATE)
	printOn(body, Enum.NormalId.Front, Strings.get("Prop.BackLot.Masque"), INK, Enum.Font.SpecialElite)
	decor(
		parent,
		"MasqueCrateLid",
		crate * CFrame.new(1.45, 0.8, 0.2) * CFrame.Angles(0, 0, math.rad(68)),
		Vector3.new(2.4, 0.12, 1.6),
		"WoodPanel",
		CRATE,
		2
	)
	decor(
		parent,
		"MasqueStraw",
		crate * CFrame.new(0, 1.52, 0),
		Vector3.new(2.1, 0.08, 1.3),
		"PaperSheet",
		rgb(138, 120, 80),
		3
	)
end

--------------------------------------------------------------------------------
-- The lamp, the hatch, the dressing
--------------------------------------------------------------------------------

local function buildLamp(parent: Instance)
	local foot = Set.lamp
	local top = foot + Vector3.new(0, Set.lampHeight, 0)
	rod(parent, "LampPole", foot, top, 0.5, "MetalGalvanized", STEEL_DARK)
	solid(parent, "LampFoot", CFrame.new(foot + Vector3.new(0, 0.2, 0)), Vector3.new(1.2, 0.4, 1.2), "Concrete")
	local armEnd = top + Vector3.new(0, 0, -2.6)
	rod(parent, "LampArm", top, armEnd, 0.24, "MetalGalvanized", STEEL_DARK)
	decor(
		parent,
		"LampShade",
		CFrame.new(armEnd + Vector3.new(0, 0.1, 0)),
		Vector3.new(1.6, 0.35, 1.2),
		"TrimMetal",
		STEEL_DARK,
		2
	)
	SchoolShellBuilder.buildLight(parent, {
		id = "BL_Light_Lamp",
		kind = "Bulb",
		position = armEnd - Vector3.new(0, 0.35, 0),
		brightness = 0.9,
		range = 30,
		color = rgb(200, 204, 210),
		flickerGroup = Set.lampGroup,
		levelId = SET_ID,
		zoneId = ZONE,
	})
end

local function buildHatch(parent: Instance, root: BasePart)
	local hs = Set.hatch
	local ground = BackLotBuilder.groundAt(hs.z)
	local model = PropKit.model(parent, "ChuteHatch", CFrame.new(hs.x, ground, hs.z))
	-- the sloped steel frame against the facade: high at the wall, low at the front
	local front = FACADE_FACE + hs.depth
	local slope = math.atan2(hs.rise, hs.depth)
	local run = math.sqrt(hs.rise * hs.rise + hs.depth * hs.depth)
	local plane = CFrame.new(hs.x, ground + hs.rise / 2 + 0.2, (FACADE_FACE + front) / 2) * CFrame.Angles(slope, 0, 0)
	local frame = solid(
		model,
		"Frame",
		plane * CFrame.new(0, -0.15, 0),
		Vector3.new(hs.width + 0.6, 0.3, run + 0.4),
		"Iron",
		STEEL_DARK
	)
	model.PrimaryPart = frame
	solid(
		model,
		"Curb",
		CFrame.new(hs.x, ground + 0.2, front + 0.1),
		Vector3.new(hs.width + 0.8, 0.4, 0.3),
		"ConcreteDark"
	)
	for i, s in { -1, 1 } do
		solid(
			model,
			"Cheek" .. i,
			CFrame.new(hs.x + s * (hs.width / 2 + 0.25), ground + hs.rise / 2, (FACADE_FACE + front) / 2),
			Vector3.new(0.3, hs.rise + 0.4, hs.depth),
			"ConcreteDark"
		)
		-- each door hinged along its outer edge, lying shut on the slope
		local hinge = plane * CFrame.new(s * hs.width / 2, 0.06, 0)
		local leaf = PropKit.leaf(model, if s < 0 then "DoorL" else "DoorR", hinge)
		local door = solid(
			leaf,
			"Plate",
			hinge * CFrame.new(-s * hs.width / 4, 0, 0),
			Vector3.new(hs.width / 2 - 0.05, 0.12, run),
			"Iron",
			HATCH_PLATE
		)
		for k = -1, 1 do
			decor(
				leaf,
				"Tread" .. k,
				hinge * CFrame.new(-s * hs.width / 4, 0.08, k * run / 3),
				Vector3.new(hs.width / 2 - 0.4, 0.04, 0.12),
				"Iron",
				STEEL_DARK,
				3
			)
		end
		decor(
			leaf,
			"Handle",
			door.CFrame * CFrame.new(s * (hs.width / 4 - 0.5), 0.12, 0.5),
			Vector3.new(0.12, 0.12, 0.7),
			"Iron",
			STEEL_DARK,
			3
		)
	end
	local climb =
		Geometry.attachment(frame, "ClimbIn", frame.CFrame:ToObjectSpace(CFrame.new(hs.x, ground, front + 1.2)))
	PropKit.prompt(
		climb,
		{ kind = "ClimbIn", action = "Prompt.ClimbIn", object = "Prompt.Chute", hold = CLIMB_HOLD },
		model
	)
	PropKit.setAttributes(model, { [W.LevelId] = SET_ID })
	-- the trigger over it: where the prologue's "Climb in" is offered
	local trigger = Geometry.box(
		parent,
		"BL_Trigger_ChuteHatch",
		Vector3.new(hs.x - hs.width / 2 - 1, GROUND, FACADE_FACE),
		Vector3.new(hs.x + hs.width / 2 + 1, GROUND + 7, front + 3),
		"Concrete"
	)
	if trigger then
		Geometry.makeVolume(trigger)
		trigger:AddTag(Tags.ChuteHatch)
		PropKit.setAttributes(trigger, {
			[W.TriggerId] = "BL_Trigger_ChuteHatch",
			[W.TriggerKind] = "ChuteHatch",
			[W.LevelId] = SET_ID,
			[W.ZoneId] = ZONE,
		})
	end
	anchorAttachment(root, "BL_Mark_HatchInside", "CutsceneMark", CFrame.new(hs.x, ground + 0.5, FACADE_FACE + 0.6))
end

local function buildDressing(parent: Instance)
	-- the bike rack along the west fence
	for i = 0, 4 do
		local x = 4 + i * 1.6
		local a, b = Vector3.new(x, GROUND, 304), Vector3.new(x, GROUND, 306.4)
		local hoop = rod(
			parent,
			"BikeRack" .. i,
			a + Vector3.new(0, 1.6, 0),
			b + Vector3.new(0, 1.6, 0),
			0.14,
			"MetalGalvanized",
			STEEL
		)
		if hoop then
			PropKit.decor(hoop, 2)
		end
		for j, p in { a, b } do
			local leg = rod(
				parent,
				string.format("BikeRackLeg%d%d", i, j),
				p,
				p + Vector3.new(0, 1.6, 0),
				0.14,
				"MetalGalvanized",
				STEEL
			)
			if leg then
				PropKit.decor(leg, 2)
			end
		end
	end
	-- the basketball hoop on the east fence, its net long gone
	local post = Vector3.new(78.4, GROUND, 314)
	local hoopPost = rod(parent, "HoopPost", post, post + Vector3.new(0, 11, 0), 0.36, "MetalGalvanized", STEEL_DARK)
	if hoopPost then
		PropKit.decor(hoopPost, 2)
	end
	decor(
		parent,
		"Backboard",
		CFrame.new(76.9, GROUND + 10.5, 314),
		Vector3.new(0.12, 2.6, 4.2),
		"Fixture",
		rgb(124, 122, 112),
		2
	)
	local rim = rod(
		parent,
		"Rim",
		Vector3.new(76.8, GROUND + 9.6, 314),
		Vector3.new(75.2, GROUND + 9.6, 314),
		0.08,
		"Iron",
		rgb(110, 46, 38)
	)
	if rim then
		PropKit.decor(rim, 3)
	end
	-- pallets stacked against the east fence, one fallen flat
	for i, p in { { 72, 341, 0, 0 }, { 72, 341, 0.55, 8 }, { 66, 344, 0, 34 } } do
		local cframe = CFrame.new(p[1], GROUND + p[3] + 0.25, p[2]) * CFrame.Angles(0, math.rad(p[4]), 0)
		decor(parent, "Pallet" .. i, cframe, Vector3.new(4, 0.5, 3.4), "Plank", rgb(84, 66, 46), 2)
	end
	-- puddles on the asphalt
	for i, p in { { 40, 318, 5, 3.2 }, { 18, 341, 3.4, 2.4 }, { 56, 334, 4.2, 2.8 }, { 30, 304, 3, 2 } } do
		decor(
			parent,
			"Puddle" .. i,
			CFrame.new(p[1], GROUND + 0.02, p[2]),
			Vector3.new(p[3], 0.04, p[4]),
			"Puddle",
			nil,
			3
		)
	end
end

-- Builds the Back Lot into `parent` (School.Exterior). Returns the set's Model.
function BackLotBuilder.build(parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = "BackLot"
	model:SetAttribute(W.LevelId, SET_ID)
	model.Parent = parent
	local lot = Set.lot
	local root =
		Geometry.part(model, "AnchorRoot", CFrame.new(WorldConfig.Sets.BackLot.origin), Vector3.one, "Concrete")
	Geometry.makeVolume(root)
	-- the fence: west, south (the gate in it), east; the facade closes the north
	local fence = Instance.new("Model")
	fence.Name = "Fence"
	fence.Parent = model
	fenceRun(fence, "FenceW", Vector3.new(lot.x0, GROUND, lot.z0), Vector3.new(lot.x0, GROUND, lot.z1))
	fenceRun(fence, "FenceSW", Vector3.new(lot.x0, GROUND, lot.z1), Vector3.new(Set.gate.x0, GROUND, lot.z1))
	fenceRun(fence, "FenceSE", Vector3.new(Set.gate.x1, GROUND, lot.z1), Vector3.new(lot.x1, GROUND, lot.z1))
	fenceRun(fence, "FenceE", Vector3.new(lot.x1, GROUND, lot.z1), Vector3.new(lot.x1, GROUND, lot.z0))
	buildGate(fence)
	local bins = Instance.new("Model")
	bins.Name = "Bins"
	bins.Parent = model
	for _, bin in Set.bins do
		buildBin(bins, root, bin)
		if bin.slot == 1 then
			buildDiscards(bins, bin)
		end
	end
	buildLamp(model)
	buildHatch(model, root)
	buildDressing(model)
	for _, mark in Set.marks do
		anchorAttachment(root, mark.id, "CutsceneMark", CFrame.new(mark.pos) * CFrame.Angles(0, math.rad(mark.yaw), 0))
	end
	return model
end

--------------------------------------------------------------------------------
-- The chute's mouth (the Basement's delivery bay)
--------------------------------------------------------------------------------

local function buildMouths(ctx: PropKit.StaticContext): number
	local built = 0
	for _, anchor in PropKit.anchorsOf(ctx.layout, "CutsceneMark") do
		if string.sub(anchor.id, -16) ~= "_Mark_ChuteMouth" then
			continue
		end
		-- mouth space: origin on the floor at the wall face, -Z out into the room
		local frame = PropKit.anchorCFrame(ctx.layout.id, anchor)
		local model = PropKit.model(ctx.parent, "ChuteMouth_" .. anchor.id, frame)
		local hood =
			Geometry.part(model, "Hood", frame * CFrame.new(0, 8.4, -0.5), Vector3.new(5.6, 4.4, 1.0), "Iron", {
				color = STEEL_DARK,
			})
		model.PrimaryPart = hood
		Geometry.part(model, "Opening", frame * CFrame.new(0, 8.2, -1.02), Vector3.new(4.2, 3.4, 0.04), "CeilingVoid")
		-- the trough: from the opening's sill down to a lip 1.4 above the floor, 4.4 out
		local a, b = Vector3.new(0, 6.6, -1.0), Vector3.new(0, 1.4, -4.6)
		local mid = (a + b) / 2
		local trough = frame * CFrame.lookAt(mid, b)
		local length = (b - a).Magnitude
		Geometry.part(model, "Trough", trough, Vector3.new(4.0, 0.14, length), "MetalRust")
		for i, s in { -1, 1 } do
			Geometry.part(
				model,
				"TroughSide" .. i,
				trough * CFrame.new(s * 2.0, 0.45, 0),
				Vector3.new(0.14, 0.9, length),
				"MetalRust"
			)
		end
		for i, s in { -1, 1 } do
			rod(
				model,
				"Strut" .. i,
				frame * Vector3.new(s * 1.8, 0, -4.2),
				frame * Vector3.new(s * 1.8, 1.4, -4.4),
				0.18,
				"Iron",
				STEEL_DARK
			)
		end
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				Geometry.makePassthrough(part)
			end
		end
		-- coal dust spilled under the lip
		for i, p in { { 0, -5.6, 3.6, 2.6 }, { 0.9, -7.2, 2.0, 1.4 } } do
			decor(
				model,
				"CoalDust" .. i,
				frame * CFrame.new(p[1], 0.03, p[2]),
				Vector3.new(p[3], 0.06, p[4]),
				"Rubble",
				rgb(30, 30, 31),
				3
			)
		end
		PropKit.setAttributes(model, { [W.AnchorId] = anchor.id, [W.LevelId] = ctx.layout.id })
		built += 1
	end
	return built
end

function BackLotBuilder.register(registrar: PropKit.Registrar)
	registrar.static("ChuteMouth", buildMouths)
end

return table.freeze(BackLotBuilder)
