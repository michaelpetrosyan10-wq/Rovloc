--!strict
-- World dimensions shared by builders, layouts, AI and cameras. All values in studs unless noted.
--
-- The school stands on a 240 x 160 footprint (level-local X 0..240, Z 0..160). Levels stack vertically.
-- Two stair towers sit outside the footprint: West (X -28..0) and East (X 240..268), both at Z 64..96.
-- Each level is entered from one tower and left by the other, so the squad crosses every floor:
--   L0 (spawn W) -> East -> L1 -> West -> L2 -> East -> L3 -> West -> L4 -> East -> L5 roof (run W, jump).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)

export type TowerSide = "West" | "East"

export type StairwellSpec = {
	id: string,
	from: Enums.LevelId,
	to: Enums.LevelId,
	tower: TowerSide,
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

WorldConfig.Towers = table.freeze({
	West = { minX = -28, maxX = 0, minZ = 64, maxZ = 96 },
	East = { minX = 240, maxX = 268, minZ = 64, maxZ = 96 },
} :: { [string]: { minX: number, maxX: number, minZ: number, maxZ: number } })

WorldConfig.TowerOpening = table.freeze({ centerZ = 80, width = 6, height = 10 })

WorldConfig.Stairwells = table.freeze({
	{
		id = "Stairwell_0_1",
		from = "Level0_Basement",
		to = "Level1_Hallways",
		tower = "East",
		fromRoom = "L0_AirlockEast",
		toRoom = "L1_AirlockEast",
	},
	{
		id = "Stairwell_1_2",
		from = "Level1_Hallways",
		to = "Level2_ScienceHall",
		tower = "West",
		fromRoom = "L1_AirlockWest",
		toRoom = "L2_AirlockWest",
	},
	{
		id = "Stairwell_2_3",
		from = "Level2_ScienceHall",
		to = "Level3_Gymnasium",
		tower = "East",
		fromRoom = "L2_AirlockEast",
		toRoom = "L3_AirlockEast",
	},
	{
		id = "Stairwell_3_4",
		from = "Level3_Gymnasium",
		to = "Level4_FloodedPool",
		tower = "West",
		fromRoom = "L3_AirlockWest",
		toRoom = "L4_AirlockWest",
	},
	{
		id = "Stairwell_4_5",
		from = "Level4_FloodedPool",
		to = "Level5_Roof",
		tower = "East",
		fromRoom = "L4_AirlockEast",
		toRoom = "L5_RoofAccess",
	},
} :: { StairwellSpec })

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

return table.freeze(WorldConfig)
