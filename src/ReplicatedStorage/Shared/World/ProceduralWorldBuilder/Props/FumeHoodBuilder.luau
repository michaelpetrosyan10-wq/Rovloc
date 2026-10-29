--!strict
-- FumeHoodBuilder: the chem prep room's fume hood, the Floor 2 objective's mixing station (fixture kind "FumeHood",
-- one per FumeHood anchor, rebuilt at every run start into Workspace.Runtime.<level>.FumeHoods with the sash half
-- raised and nothing mixed).
--
-- Mount space: the anchor is the floor point on the wall face; -Z out of the wall (its LookVector), +Y up, +X the
-- viewer's left. A steel base cabinet under a black epoxy worktop, the hood over it (side walls, a baffled back, a
-- canopy with its exhaust duct up to the ceiling), the glass sash in a steel frame (leaf "Sash": rest = lowered; it
-- slides straight up, built half raised; "SashOpen" records the fully raised pose), an airflow monitor whose LED
-- stays red, the "FUME HOOD - KEEP SASH LOWERED" plate on the canopy and, inside, a clamp stand holding the big empty
-- mixing flask. The squad sets the three reagent jars down on "ReagentSlot1".."ReagentSlot3" and the mixed acid flask
-- appears on "AcidFlaskSpot" (AcidFlaskBuilder.buildWorld) when the Mix is done.
--
-- Prompt (disabled): Mix on "MixPrompt" in front of the sash (Step MixAcid, hold 5 s). Tags ObjectiveStation,
-- Interactable; attributes Floor 2, Step MixAcid, ObjectiveId FumeHood, AnchorId, LevelId, ZoneId. The cabinet, the
-- hood's walls and canopy are MonsterPassthrough furniture; the sash, duct and apparatus are details. setSash poses
-- the sash. Part budget PartBudget.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)

local Geometry = require(script.Parent.Parent.Geometry)
local ObjectiveKit = require(script.Parent.ObjectiveKit)
local PropKit = require(script.Parent.PropKit)
local SchoolShellBuilder = require(script.Parent.Parent.SchoolShellBuilder)

local W = Attributes.World

type PartOptions = Geometry.PartOptions

local KIND = "FumeHood"
local FOLDER = "FumeHoods"
local PART_BUDGET = 24
local STEP = "MixAcid"

local HALF_W = 2.8
local DEPTH = 2.7
local WORKTOP = 2.95
local WORKTOP_T = 0.15
local HOOD_TOP = 7.4
local CANOPY_TOP = 8.2
local WALL_T = 0.2
local SASH_BOTTOM = 3.45 -- lowered
local SASH_HEIGHT = 2.6
local SASH_TRAVEL = 2.9 -- fully raised
local SASH_BUILT = 0.45 -- built this share raised
local SASH_OUT = DEPTH - 0.12

local STEEL = Color3.fromRGB(92, 98, 96)
local CABINET = Color3.fromRGB(70, 82, 78)
local EPOXY = Color3.fromRGB(24, 26, 26)

local FumeHoodBuilder = {}

FumeHoodBuilder.Kind = KIND
FumeHoodBuilder.Folder = FOLDER
FumeHoodBuilder.PartBudget = PART_BUDGET
FumeHoodBuilder.SashTravel = SASH_TRAVEL

local function at(x: number, y: number, out: number): Vector3
	return Vector3.new(x, y, -out)
end

local function block(
	parent: Instance,
	name: string,
	mount: CFrame,
	a: Vector3,
	b: Vector3,
	key: string?,
	options: PartOptions?
): Part
	local lo, hi = a:Min(b), a:Max(b)
	return Geometry.part(parent, name, mount * CFrame.new((lo + hi) / 2), hi - lo, key, options)
end

local function detail(part: BasePart?)
	if part then
		PropKit.detail(part)
	end
end

-- The sash 0 (lowered) .. 1 (fully raised).
function FumeHoodBuilder.setSash(model: Model, raised: number): boolean
	return PropKit.poseLeaf(model, "Sash", CFrame.new(0, math.clamp(raised, 0, 1) * SASH_TRAVEL, 0))
end

export type HoodSpec = {
	cframe: CFrame, -- the anchor: floor point on the wall face, LookVector out of the wall
	anchorId: string,
	levelId: string,
	zoneId: string,
	ceiling: number, -- underside of the room's ceiling panel above the anchor
}

function FumeHoodBuilder.buildHood(parent: Instance, spec: HoodSpec): Model
	local objective = ObjectiveConfig.forLevel(spec.levelId) or ObjectiveConfig.Floors[3]
	local mount = spec.cframe
	local model = PropKit.model(parent, spec.anchorId, mount)
	local base = block(
		model,
		"Base",
		mount,
		at(-HALF_W, 0, 0.05),
		at(HALF_W, WORKTOP, DEPTH - 0.1),
		"CabinetSteel",
		{ material = Enum.Material.Metal, color = CABINET }
	)
	model.PrimaryPart = base
	block(
		model,
		"Worktop",
		mount,
		at(-HALF_W - 0.1, WORKTOP, 0.02),
		at(HALF_W + 0.1, WORKTOP + WORKTOP_T, DEPTH),
		"LabWorktop",
		{ color = EPOXY }
	)
	local steel: PartOptions = { material = Enum.Material.Metal, color = STEEL }
	for i, x in { -HALF_W, HALF_W - WALL_T } do
		block(
			model,
			"Side" .. i,
			mount,
			at(x, WORKTOP + WORKTOP_T, 0.05),
			at(x + WALL_T, HOOD_TOP, DEPTH),
			"TrimMetal",
			steel
		)
	end
	block(
		model,
		"Baffle",
		mount,
		at(-HALF_W + WALL_T, WORKTOP + WORKTOP_T, 0.05),
		at(HALF_W - WALL_T, HOOD_TOP, 0.25),
		"TrimMetal",
		{ material = Enum.Material.Metal, color = STEEL:Lerp(Color3.new(), 0.35) }
	)
	local canopy = block(
		model,
		"Canopy",
		mount,
		at(-HALF_W - 0.05, HOOD_TOP, 0.05),
		at(HALF_W + 0.05, CANOPY_TOP, DEPTH + 0.05),
		"TrimMetal",
		steel
	)
	local top = math.max(CANOPY_TOP + 1, spec.ceiling - 0.01)
	detail(
		Geometry.cylinder(
			model,
			"Duct",
			mount * at(0, CANOPY_TOP, 1.2),
			mount * at(0, top, 1.2),
			1.1,
			"MetalGalvanized"
		)
	)

	-- The sash: glass in a steel frame, sliding up
	local sash = PropKit.leaf(model, "Sash", mount * CFrame.new(at(0, SASH_BOTTOM, SASH_OUT)))
	detail(
		block(
			sash,
			"SashGlass",
			mount,
			at(-HALF_W + WALL_T + 0.05, SASH_BOTTOM + 0.12, SASH_OUT - 0.03),
			at(HALF_W - WALL_T - 0.05, SASH_BOTTOM + SASH_HEIGHT - 0.1, SASH_OUT + 0.01),
			"Glass",
			{ transparency = 0.55, color = Color3.fromRGB(120, 136, 130) }
		)
	)
	detail(
		block(
			sash,
			"SashRail",
			mount,
			at(-HALF_W + WALL_T + 0.02, SASH_BOTTOM, SASH_OUT - 0.06),
			at(HALF_W - WALL_T - 0.02, SASH_BOTTOM + 0.14, SASH_OUT + 0.06),
			"TrimMetal",
			steel
		)
	)
	detail(
		block(
			sash,
			"SashHead",
			mount,
			at(-HALF_W + WALL_T + 0.02, SASH_BOTTOM + SASH_HEIGHT - 0.12, SASH_OUT - 0.06),
			at(HALF_W - WALL_T - 0.02, SASH_BOTTOM + SASH_HEIGHT, SASH_OUT + 0.06),
			"TrimMetal",
			steel
		)
	)

	-- Airflow monitor on the right-hand side wall's front, its LED stuck on red; the warning plate on the canopy
	local monitor = block(
		model,
		"Monitor",
		mount,
		at(-HALF_W - 0.12, 5.6, DEPTH - 0.7),
		at(-HALF_W, 6.3, DEPTH - 0.15),
		nil,
		{ material = Enum.Material.SmoothPlastic, color = Color3.fromRGB(40, 42, 42) }
	)
	detail(monitor)
	detail(
		Geometry.cylinder(
			model,
			"MonitorLed",
			mount * at(-HALF_W - 0.12, 6.08, DEPTH - 0.42),
			mount * at(-HALF_W - 0.17, 6.08, DEPTH - 0.42),
			0.14,
			nil,
			{ material = Enum.Material.Neon, color = Color3.fromRGB(226, 40, 30) }
		)
	)
	local plate = block(
		model,
		"WarningPlate",
		mount,
		at(-2.2, HOOD_TOP + 0.18, DEPTH + 0.05),
		at(2.2, CANOPY_TOP - 0.18, DEPTH + 0.08),
		nil,
		{ material = Enum.Material.SmoothPlastic, color = Color3.fromRGB(156, 128, 44) }
	)
	detail(plate)
	ObjectiveKit.text(
		plate,
		"Warning",
		Strings.get("Prop.FumeHood.Label"),
		Color3.fromRGB(24, 24, 22),
		Enum.Font.Oswald,
		Enum.NormalId.Front,
		120
	)

	-- The apparatus: a clamp stand holding the empty mixing flask, toward the viewer's right
	local standX = -1.4
	local work = WORKTOP + WORKTOP_T
	detail(
		block(
			model,
			"StandFoot",
			mount,
			at(standX - 0.35, work, 0.6),
			at(standX + 0.35, work + 0.06, 1.3),
			"TrimMetal",
			steel
		)
	)
	detail(
		Geometry.cylinder(
			model,
			"StandRod",
			mount * at(standX, work, 0.8),
			mount * at(standX, work + 2.2, 0.8),
			0.07,
			"TrimMetal",
			steel
		)
	)
	detail(
		block(
			model,
			"Clamp",
			mount,
			at(standX - 0.05, work + 1.3, 0.8),
			at(standX + 0.05, work + 1.4, 1.35),
			"TrimMetal",
			steel
		)
	)
	detail(
		Geometry.part(
			model,
			"MixingFlask",
			mount * CFrame.new(at(standX, work + 0.75, 1.45)),
			Vector3.one * 1.0,
			"Glass",
			{ shape = Enum.PartType.Ball, transparency = 0.55, color = Color3.fromRGB(150, 170, 160) }
		)
	)
	detail(
		Geometry.cylinder(
			model,
			"MixingNeck",
			mount * at(standX, work + 1.15, 1.45),
			mount * at(standX, work + 1.75, 1.45),
			0.26,
			"Glass",
			{ transparency = 0.5, color = Color3.fromRGB(150, 170, 160) }
		)
	)

	-- Where things go on the worktop, and the prompt in front of the sash
	for i = 1, 3 do
		Geometry.attachment(
			base,
			"ReagentSlot" .. i,
			base.CFrame:ToObjectSpace(mount * CFrame.new(at(0.4 + (i - 1) * 0.75, work, 1.6)))
		)
	end
	Geometry.attachment(base, "AcidFlaskSpot", base.CFrame:ToObjectSpace(mount * CFrame.new(at(-0.2, work, 1.9))))
	local promptPoint =
		Geometry.attachment(base, "MixPrompt", base.CFrame:ToObjectSpace(mount * CFrame.new(at(0, 3.6, DEPTH + 1.1))))
	Geometry.attachment(
		base,
		"SashOpen",
		base.CFrame:ToObjectSpace((PropKit.leafRest(model, "Sash") :: CFrame) * CFrame.new(0, SASH_TRAVEL, 0))
	)
	Geometry.attachment(canopy, "Exhaust", canopy.CFrame:ToObjectSpace(mount * CFrame.new(at(0, CANOPY_TOP, 1.2))))

	PropKit.passthroughAll(model)
	PropKit.setAttributes(model, { [W.AnchorId] = spec.anchorId, [W.ZoneId] = spec.zoneId })
	ObjectiveKit.mark(model, Tags.ObjectiveStation, objective, STEP, KIND)
	ObjectiveKit.prompt(promptPoint, objective, "Mix", "Prompt.Mix", "Prompt.FumeHood", STEP, model)
	FumeHoodBuilder.setSash(model, SASH_BUILT)
	return model
end

local function buildFixtures(ctx: PropKit.FixtureContext): number
	local stale = ctx.parent:FindFirstChild(FOLDER)
	if stale then
		stale:Destroy()
	end
	local anchors = PropKit.anchorsOf(ctx.layout, "FumeHood")
	if #anchors == 0 then
		return 0
	end
	local folder = Geometry.folder(ctx.parent, FOLDER)
	local rooms = LayoutSchema.indexRooms(ctx.layout)
	for _, anchor in anchors do
		local room = rooms[anchor.room]
		local height = if room then SchoolShellBuilder.ceilingBottom(ctx.layout, room) else ctx.layout.height
		FumeHoodBuilder.buildHood(folder, {
			cframe = PropKit.anchorCFrame(ctx.layout.id, anchor),
			anchorId = anchor.id,
			levelId = ctx.layout.id,
			zoneId = anchor.room,
			ceiling = height - anchor.pos.Y,
		})
	end
	return #anchors
end

function FumeHoodBuilder.register(registrar: PropKit.Registrar)
	registrar.fixture(KIND, buildFixtures)
end

return table.freeze(FumeHoodBuilder)
