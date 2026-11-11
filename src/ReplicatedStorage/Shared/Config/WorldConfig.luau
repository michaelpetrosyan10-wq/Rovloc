--!strict
-- World dimensions shared by builders, layouts, AI and cameras. All values in studs unless noted.
--
-- The school stands on a 400 x 288 footprint (level-local X 0..400, Z 0..288). Levels stack vertically.
-- Six stair towers stand outside the footprint, three against each side wall (X -28..0 west, 400..428 east), each
-- 32 deep along Z: North at Z 12..44 (opening z 28), Middle (West / East) at Z 128..160 (opening z 144) and South at
-- Z 244..276 (opening z 260). A tower's opening (Towers[id].openingZ) meets one airlock vestibule on every floor it
-- serves. A floor is entered from one side and left by the other, so the squad crosses every floor (the school is
-- the four levels of LevelOrder, docs/design/game-spec-v2.md 4.2):
--   L0 Basement (spawn W) -> East -> L1 Hallways -> West -> L2 Auditorium -> East -> L3 roof (run W, jump).
-- Every floor pair has three candidate stairwells, one per tower of its side (slots North, Middle, South):
-- RunDirector.pickRoute picks one per pair for a run (plan.route); the other two are jammed shut for that run.
-- Every per-level table here is keyed by the level's id, never by its number.
--
-- Legacy floors: a layout marked `legacy` still has the old 240 x 160 plan (LegacyFootprint) until it is rebuilt on
-- TunnelPlanner; its vestibules no longer meet the moved towers (see LayoutSchema.validate and docs/MAPS.md).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)

export type TowerSide = "West" | "East" -- the side wall a tower stands against
export type TowerId = "West" | "East" | "NorthWest" | "SouthWest" | "NorthEast" | "SouthEast"
export type RouteSlot = "North" | "Middle" | "South"

export type TowerSpec = {
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	side: TowerSide,
	openingZ: number, -- centre (level-local Z) of the opening between the tower and its vestibules
}

export type StairwellSpec = {
	id: string,
	pair: number, -- 1..3: the floor pair (from = LevelOrder[pair])
	slot: RouteSlot,
	from: Enums.LevelId,
	to: Enums.LevelId,
	tower: TowerId,
	fromRoom: string, -- Airlock room id in the lower level's layout (its exit vestibule)
	toRoom: string, -- Airlock room id in the upper level's layout (its entry vestibule)
}

export type LevelSpec = {
	elevation: number, -- world Y of the floor surface
	height: number, -- default ceiling height above the floor (0: open to the sky)
	prefix: string, -- the level's id prefix (rooms, anchors, doors, lights: "L0_...")
	exitSide: TowerSide?, -- the side wall its stairs up stand against (nil on the top level)
}

local WorldConfig = {}

WorldConfig.SchoolOrigin = Vector3.new(0, 0, 0)
WorldConfig.FootprintSize = Vector2.new(400, 288)
-- The footprint the legacy layouts were drawn for (their rooms tile it; the rest of the footprint stays solid ground).
WorldConfig.LegacyFootprint = Vector2.new(240, 160)
WorldConfig.SlabThickness = 2
WorldConfig.WallThickness = 1 -- never thinner: thin walls leak light and sound
WorldConfig.ExteriorWallThickness = 1.5
WorldConfig.GroundY = 18 -- street level = Level 1 floor; the basement is below grade

local function levelSpec(spec: LevelSpec): LevelSpec
	return table.freeze(spec)
end

-- The school levels (spec 4.2). The roof is open: no ceiling, no slab above it.
WorldConfig.Levels = table.freeze({
	Level0_Basement = levelSpec({ elevation = 0, height = 16, prefix = "L0", exitSide = "East" }),
	Level1_Hallways = levelSpec({ elevation = 18, height = 14, prefix = "L1", exitSide = "West" }),
	Level2_Auditorium = levelSpec({ elevation = 34, height = 28, prefix = "L2", exitSide = "East" }),
	Level3_Roof = levelSpec({ elevation = 64, height = 0, prefix = "L3" }),
} :: { [string]: LevelSpec })

WorldConfig.LobbyOrigin = Vector3.new(-800, 0, 0)

-- A tower against the `side` wall spanning Z minZ..minZ + 32, its opening `opening` studs in from minZ.
local function towerSpec(side: TowerSide, minZ: number, opening: number): TowerSpec
	local minX = if side == "East" then WorldConfig.FootprintSize.X else -28
	local spec: TowerSpec =
		{ minX = minX, maxX = minX + 28, minZ = minZ, maxZ = minZ + 32, side = side, openingZ = minZ + opening }
	return table.freeze(spec)
end

WorldConfig.Towers = table.freeze({
	West = towerSpec("West", 128, 16),
	East = towerSpec("East", 128, 16),
	NorthWest = towerSpec("West", 12, 16),
	SouthWest = towerSpec("West", 244, 16),
	NorthEast = towerSpec("East", 12, 16),
	SouthEast = towerSpec("East", 244, 16),
} :: { [string]: TowerSpec })

-- The middle towers' opening; every tower has its own centre (Towers[id].openingZ), the width and height are shared.
WorldConfig.TowerOpening = table.freeze({ centerZ = 144, width = 6, height = 10 })

-- The school levels in climbing order, the levels the world builder builds: floor pair i leaves LevelOrder[i] for
-- LevelOrder[i + 1]. The city levels (Enums.LevelId) follow them in the run but are no part of the school.
WorldConfig.LevelOrder = table.freeze({
	"Level0_Basement",
	"Level1_Hallways",
	"Level2_Auditorium",
	"Level3_Roof",
} :: { Enums.LevelId })

local SLOT_ORDER: { RouteSlot } = { "North", "Middle", "South" }

-- The route slots in candidate order.
WorldConfig.RouteSlots = table.freeze(table.clone(SLOT_ORDER))

-- Whether `levelId` is one of the school levels the world builder builds.
function WorldConfig.isSchoolLevel(levelId: string?): boolean
	return levelId ~= nil and WorldConfig.Levels[levelId] ~= nil
end

-- The school level after `levelId` in climbing order (nil on the top level and for any other id).
function WorldConfig.nextLevel(levelId: string): Enums.LevelId?
	local at = table.find(WorldConfig.LevelOrder, levelId :: any)
	return if at then WorldConfig.LevelOrder[at + 1] else nil
end

-- The school level before `levelId` in climbing order (nil on the basement and for any other id).
function WorldConfig.previousLevel(levelId: string): Enums.LevelId?
	local at = table.find(WorldConfig.LevelOrder, levelId :: any)
	return if at and at > 1 then WorldConfig.LevelOrder[at - 1] else nil
end

-- The id prefix of a school level ("L0".."L3"; nil for any other id).
function WorldConfig.levelPrefix(levelId: string): string?
	local spec = WorldConfig.Levels[levelId]
	return if spec then spec.prefix else nil
end

-- The vestibule of slot `slot` on the `side` wall of `levelId`; the open roof has stair housings.
local function vestibule(levelId: string, side: TowerSide, slot: RouteSlot): string
	local suffix = if slot == "Middle" then "" else slot
	local spec = WorldConfig.Levels[levelId]
	if spec.height == 0 then
		return spec.prefix .. "_RoofAccess" .. suffix
	end
	return spec.prefix .. "_Airlock" .. suffix .. side
end

-- Every candidate stairwell: the five middle ones first (their ids are the original single route), then the corner
-- ones (`Stairwell_<a>_<b>_North` / `_South`) pair by pair.
local function towerOf(side: TowerSide, slot: RouteSlot): TowerId
	if slot == "Middle" then
		return side
	elseif slot == "North" then
		return if side == "East" then "NorthEast" else "NorthWest"
	end
	return if side == "East" then "SouthEast" else "SouthWest"
end

local function stairwell(pair: number, slot: RouteSlot): StairwellSpec
	-- (an array read widens the singleton types)
	local from: Enums.LevelId, to: Enums.LevelId =
		WorldConfig.LevelOrder[pair] :: any, WorldConfig.LevelOrder[pair + 1] :: any
	local side: TowerSide = if WorldConfig.Levels[from].exitSide == "West" then "West" else "East"
	local spec: StairwellSpec = {
		id = string.format("Stairwell_%d_%d%s", pair - 1, pair, if slot == "Middle" then "" else "_" .. slot),
		pair = pair,
		slot = slot,
		from = from,
		to = to,
		tower = towerOf(side, slot),
		fromRoom = vestibule(from, side, slot),
		toRoom = vestibule(to, side, slot),
	}
	return table.freeze(spec)
end

local stairwells: { StairwellSpec } = {}
local BUILD_ORDER: { RouteSlot } = { "Middle", "North", "South" }
for _, slot in BUILD_ORDER do
	for pair = 1, #WorldConfig.LevelOrder - 1 do
		table.insert(stairwells, stairwell(pair, slot :: any))
	end
end
WorldConfig.Stairwells = table.freeze(stairwells)

-- Openings
WorldConfig.DoorWidth = 6 -- the 8.5-stud Creature passes every doorway; it ducks under the 10-stud lintel
WorldConfig.DoorHeight = 10
WorldConfig.AirlockDoorWidth = 8
WorldConfig.CorridorWidth = 14

-- Vents (3.5 x 3.5 inner bore, galvanized shell)
WorldConfig.VentBore = 3.5
WorldConfig.VentShell = 0.2
WorldConfig.VentCenterHeight = 2 -- duct centre above the floor ("low wall vents"); bore floor sits at 0.25
WorldConfig.ChaseWidth = 5 -- service chase between rooms that hides the ducts "inside the walls"
WorldConfig.VentColliderDiameter = 2.6

-- The roof
WorldConfig.ParapetHeight = 3.5
WorldConfig.ParachuteLandingY = WorldConfig.GroundY

-- Avatar normalization (CharacterService). Keeps eye height and body width predictable for vents and cameras.
WorldConfig.Avatar = table.freeze({
	HeightScale = 1,
	WidthScale = 1,
	DepthScale = 1,
	HeadScale = 1,
	BodyTypeScale = 0,
	ProportionScale = 0,
	StripLayeredClothing = true,
	StripHeadAccessories = true,
})

-- Spawn anchors
WorldConfig.SpawnSpacing = 4

function WorldConfig.levelElevation(levelId: string): number
	local spec = WorldConfig.Levels[levelId]
	return if spec then spec.elevation else 0
end

function WorldConfig.levelOrigin(layoutId: string): Vector3
	if layoutId == "Lobby" then
		return WorldConfig.LobbyOrigin
	end
	return WorldConfig.SchoolOrigin + Vector3.new(0, WorldConfig.levelElevation(layoutId), 0)
end

local byId: { [string]: StairwellSpec } = {}
for _, spec in WorldConfig.Stairwells do
	byId[spec.id] = spec
end

-- The stairwell with id `id` (nil when there is none).
function WorldConfig.stairwellById(id: string?): StairwellSpec?
	return if id then byId[id] else nil
end

-- The candidate stairwells leaving `from`, in slot order (North, Middle, South); empty on the roof.
function WorldConfig.stairwellCandidates(from: string): { StairwellSpec }
	local out: { StairwellSpec } = {}
	for _, slot in SLOT_ORDER do
		for _, spec in WorldConfig.Stairwells do
			if spec.from == from and spec.slot == slot then
				table.insert(out, spec)
			end
		end
	end
	return out
end

-- The stairwell a route (RunDirector's plan.route: from-level -> stairwell id) leaves `from` by: the middle candidate
-- when the route is nil or names none for that level. Nil on the roof.
function WorldConfig.routeExit(route: { [string]: string }?, from: string): StairwellSpec?
	local picked = if route then byId[route[from]] else nil
	if picked and picked.from == from then
		return picked
	end
	for _, spec in WorldConfig.Stairwells do
		if spec.from == from and spec.slot == "Middle" then
			return spec
		end
	end
	return nil
end

-- The stairwell a route enters `to` by (the previous floor's exit); nil for the basement and the lobby.
function WorldConfig.routeEntry(route: { [string]: string }?, to: string): StairwellSpec?
	local from = WorldConfig.previousLevel(to)
	return if from then WorldConfig.routeExit(route, from) else nil
end

-- The side wall tower `tower` stands against.
function WorldConfig.towerSide(tower: string): TowerSide
	local spec = WorldConfig.Towers[tower]
	return if spec then spec.side else "East"
end

-- Whether the stretch [z0, z1] of a side wall faces a stair tower (comes within `margin` studs of one's Z span).
function WorldConfig.facesTower(z0: number, z1: number, margin: number): boolean
	for _, tower in WorldConfig.Towers do
		if z1 > tower.minZ - margin and z0 < tower.maxZ + margin then
			return true
		end
	end
	return false
end

-- `value` as plain data: vectors as arrays of their components, tables copied, functions left out.
local function plain(value: any): any
	local kind = typeof(value)
	if kind == "Vector3" then
		return { value.X, value.Y, value.Z }
	elseif kind == "Vector2" then
		return { value.X, value.Y }
	elseif kind == "table" then
		local out: { [any]: any } = {}
		for key, item in value do
			if type(item) ~= "function" then
				out[key] = plain(item)
			end
		end
		return out
	end
	return value
end

-- The world's dimensions, levels, towers and stairwells as plain data for the website (world.json
-- meta.worldConfig; vectors as arrays).
function WorldConfig.exportMeta(): { [string]: any }
	return plain(WorldConfig)
end

return table.freeze(WorldConfig)
