--!strict
-- World dimensions shared by builders, layouts, AI and cameras. All values in studs unless noted.
--
-- The school stands on a 240 x 160 footprint (level-local X 0..240, Z 0..160). Levels stack vertically.
-- Six stair towers stand outside the footprint, three against each side wall: West / East (X -28..0 / 240..268) at
-- Z 64..96 in the middle, NorthWest / NorthEast at Z -4..28 and SouthWest / SouthEast at Z 132..164 on the corners
-- (those stick 4 studs out past the north / south facade). A tower's opening (Towers[id].openingZ) meets one airlock
-- vestibule on every floor it serves. A floor is entered from one side and left by the other, so the squad crosses
-- every floor:
--   L0 (spawn W) -> East -> L1 -> West -> L2 -> East -> L3 -> West -> L4 -> East -> L5 roof (run W, jump).
-- Every floor pair (1..5) has three candidate stairwells, one per tower of its side (slots North, Middle, South):
-- RunDirector.pickRoute picks one per pair for a run (plan.route); the other two are jammed shut for that run.

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
	pair: number, -- 1..5: the floor pair (from = LevelOrder[pair])
	slot: RouteSlot,
	from: Enums.LevelId,
	to: Enums.LevelId,
	tower: TowerId,
	fromRoom: string, -- Airlock room id in the lower level's layout (its exit vestibule)
	toRoom: string, -- Airlock room id in the upper level's layout (its entry vestibule)
}

export type LevelSpec = {
	elevation: number, -- world Y of the floor surface
	height: number, -- default ceiling height above the floor
}

local WorldConfig = {}

WorldConfig.SchoolOrigin = Vector3.new(0, 0, 0)
WorldConfig.FootprintSize = Vector2.new(240, 160)
WorldConfig.SlabThickness = 2
WorldConfig.WallThickness = 1 -- never thinner: thin walls leak light and sound
WorldConfig.ExteriorWallThickness = 1.5
WorldConfig.GroundY = 18 -- street level = Level 1 floor; the basement is below grade

WorldConfig.Levels = table.freeze({
	Level0_Basement = { elevation = 0, height = 16 },
	Level1_Hallways = { elevation = 18, height = 14 },
	Level2_ScienceHall = { elevation = 34, height = 14 },
	Level3_Gymnasium = { elevation = 50, height = 30 },
	Level4_FloodedPool = { elevation = 82, height = 28 },
	Level5_Roof = { elevation = 112, height = 0 },
} :: { [string]: LevelSpec })

WorldConfig.LobbyOrigin = Vector3.new(-800, 0, 0)

-- A tower against the `side` wall spanning Z minZ..minZ + 32, its opening `opening` studs in from minZ.
local function towerSpec(side: TowerSide, minZ: number, opening: number): TowerSpec
	local minX = if side == "East" then 240 else -28
	local spec: TowerSpec =
		{ minX = minX, maxX = minX + 28, minZ = minZ, maxZ = minZ + 32, side = side, openingZ = minZ + opening }
	return table.freeze(spec)
end

WorldConfig.Towers = table.freeze({
	West = towerSpec("West", 64, 16),
	East = towerSpec("East", 64, 16),
	NorthWest = towerSpec("West", -4, 16),
	SouthWest = towerSpec("West", 132, 16),
	NorthEast = towerSpec("East", -4, 16),
	SouthEast = towerSpec("East", 132, 16),
} :: { [string]: TowerSpec })

-- The middle towers' opening; every tower has its own centre (Towers[id].openingZ), the width and height are shared.
WorldConfig.TowerOpening = table.freeze({ centerZ = 80, width = 6, height = 10 })

-- The school levels in climbing order: floor pair i leaves LevelOrder[i] for LevelOrder[i + 1].
WorldConfig.LevelOrder = table.freeze({
	"Level0_Basement",
	"Level1_Hallways",
	"Level2_ScienceHall",
	"Level3_Gymnasium",
	"Level4_FloodedPool",
	"Level5_Roof",
} :: { Enums.LevelId })

local PAIR_SIDES: { TowerSide } = { "East", "West", "East", "West", "East" }
local LEVEL_PREFIX = { "L0", "L1", "L2", "L3", "L4", "L5" }
local SLOT_ORDER: { RouteSlot } = { "North", "Middle", "South" }

-- The route slots in candidate order.
WorldConfig.RouteSlots = table.freeze(table.clone(SLOT_ORDER))

-- The vestibule of slot `slot` on the `side` wall of level `index` (1 = the basement); the roof has stair housings.
local function vestibule(index: number, side: TowerSide, slot: RouteSlot): string
	local suffix = if slot == "Middle" then "" else slot
	if index == #LEVEL_PREFIX then
		return "L5_RoofAccess" .. suffix
	end
	return LEVEL_PREFIX[index] .. "_Airlock" .. suffix .. side
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
	local side: TowerSide = PAIR_SIDES[pair] :: any -- (an array read widens the singleton type)
	local spec: StairwellSpec = {
		id = string.format("Stairwell_%d_%d%s", pair - 1, pair, if slot == "Middle" then "" else "_" .. slot),
		pair = pair,
		slot = slot,
		from = WorldConfig.LevelOrder[pair],
		to = WorldConfig.LevelOrder[pair + 1],
		tower = towerOf(side, slot),
		fromRoom = vestibule(pair, side, slot),
		toRoom = vestibule(pair + 1, side, slot),
	}
	return table.freeze(spec)
end

local stairwells: { StairwellSpec } = {}
local BUILD_ORDER: { RouteSlot } = { "Middle", "North", "South" }
for _, slot in BUILD_ORDER do
	for pair = 1, #PAIR_SIDES do
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

-- Water (part volumes, never Terrain water: custom swim physics, no engine Swimming state)
WorldConfig.WaterSurfaceOffset = -1 -- pool water surface relative to the pool deck floor

-- Roof finale
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
	for i, levelId in WorldConfig.LevelOrder do
		if levelId == to and i > 1 then
			return WorldConfig.routeExit(route, WorldConfig.LevelOrder[i - 1])
		end
	end
	return nil
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

return table.freeze(WorldConfig)
