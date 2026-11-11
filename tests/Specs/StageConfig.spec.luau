--!strict
-- StageConfig and the school's stack (docs/design/game-spec-v2.md 0.1 and 4.2): the nine stages in run order, one row
-- per stage id, every LevelId and every SetId exactly once, the levels numbered by a dense floor 0..5 in that order
-- (and ObjectiveConfig agreeing), the stage lookups; WorldConfig's four school levels at their elevations and heights,
-- and the stair pairs they generate (east, west, east), each with its North and South candidates.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local StageConfig = require(ReplicatedStorage.Shared.Config.StageConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local RUN_ORDER: { string } = {
	"BackLot",
	"Level0_Basement",
	"Level1_Hallways",
	"Level2_Auditorium",
	"Level3_Roof",
	"City1_Rooftops",
	"City2_Airport",
	"Runway",
	"Bahamas",
}

-- Spec 4.2: elevation (world y of the floor), height (0: open to the sky), prefix, the side its stairs up leave by.
local STACK: { [string]: { elevation: number, height: number, prefix: string, exitSide: string? } } = {
	Level0_Basement = { elevation = 0, height = 16, prefix = "L0", exitSide = "East" },
	Level1_Hallways = { elevation = 18, height = 14, prefix = "L1", exitSide = "West" },
	Level2_Auditorium = { elevation = 34, height = 28, prefix = "L2", exitSide = "East" },
	Level3_Roof = { elevation = 64, height = 0, prefix = "L3", exitSide = nil },
}

return {
	["the nine stages play in the spec's order, one row per stage id"] = function(t: Expect)
		t.eq(#StageConfig.Order, #RUN_ORDER, "nine stages")
		local seen: { [string]: number } = {}
		for i, stage in StageConfig.Order do
			t.eq(stage.id, RUN_ORDER[i], "stage " .. i)
			seen[stage.id] = (seen[stage.id] or 0) + 1
			t.eq(StageConfig.get(stage.id), stage, stage.id .. " looks itself up")
			t.eq(StageConfig.ById[stage.id], stage, stage.id .. " is indexed")
			t.truthy(#stage.play >= 1, stage.id .. " plays something")
			t.truthy(stage.par > 0, stage.id .. " has a par")
			if stage.parReplay then
				t.truthy(stage.parReplay < stage.par, stage.id .. " plays shorter on a replay")
			end
			if stage.card then
				t.truthy(Strings.has(stage.card), stage.id .. " card string")
			end
		end
		for id, count in seen do
			t.eq(count, 1, id .. " has one row")
		end
		t.truthy(table.isfrozen(StageConfig.Order) and table.isfrozen(StageConfig.Order[1]), "frozen")
		t.eq(StageConfig.get("Level4_FloodedPool"), nil, "an unknown id")
	end,

	["every LevelId and every SetId is a stage exactly once, of its kind"] = function(t: Expect)
		local function count(id: string): number
			local n = 0
			for _, stage in StageConfig.Order do
				if stage.id == id then
					n += 1
				end
			end
			return n
		end
		for _, id in Enums.LevelId do
			t.eq(count(id), 1, id .. " is a stage once")
			local stage = StageConfig.get(id)
			t.eq(stage and stage.kind, "Level", id .. " is a level")
		end
		for _, id in Enums.SetId do
			t.eq(count(id), 1, id .. " is a stage once")
			local stage = StageConfig.get(id)
			t.eq(stage and stage.kind, "Set", id .. " is a set")
		end
		t.eq(#StageConfig.Order, #Enums.LevelId + #Enums.SetId, "no other stages")
	end,

	["levels carry a dense floor 0..5 in run order; sets carry none; ObjectiveConfig agrees"] = function(t: Expect)
		local floor = 0
		for _, stage in StageConfig.Order do
			if stage.kind == "Level" then
				t.eq(stage.floor, floor, stage.id .. " floor")
				t.eq(StageConfig.floorOf(stage.id), floor, stage.id .. " floorOf")
				floor += 1
			else
				t.eq(stage.floor, nil, stage.id .. " is no floor")
				t.eq(StageConfig.floorOf(stage.id), nil, stage.id .. " floorOf")
			end
		end
		t.eq(floor, 6, "six levels")
		t.truthy(#ObjectiveConfig.Floors >= 3, "the school's floors have objectives")
		for _, spec in ObjectiveConfig.Floors do
			t.eq(
				spec.floor,
				StageConfig.floorOf(spec.levelId),
				spec.levelId .. ": ObjectiveConfig's floor is StageConfig's"
			)
		end
	end,

	["nextStage walks the run and parSeconds picks the replay par"] = function(t: Expect)
		for i, id in RUN_ORDER do
			local after = StageConfig.nextStage(id)
			t.eq(after and after.id, RUN_ORDER[i + 1], id .. " is followed by the next stage")
		end
		t.eq(StageConfig.nextStage("Lobby"), nil, "not a stage")
		local backLot = StageConfig.get("BackLot")
		assert(backLot and backLot.parReplay, "the Back Lot plays shorter on a replay")
		t.eq(StageConfig.parSeconds("BackLot"), backLot.par)
		t.eq(StageConfig.parSeconds("BackLot", true), backLot.parReplay)
		t.eq(StageConfig.parSeconds("Bahamas", true), StageConfig.ById.Bahamas.par, "no replay par: the par")
		t.eq(StageConfig.parSeconds("Nowhere"), nil)
	end,

	["the school is four levels stacked at the spec's elevations and heights"] = function(t: Expect)
		t.eq(
			table.concat(WorldConfig.LevelOrder, ","),
			"Level0_Basement,Level1_Hallways,Level2_Auditorium,Level3_Roof",
			"climbing order"
		)
		local levels = 0
		for id, spec in WorldConfig.Levels do
			levels += 1
			local want = STACK[id]
			assert(want, id .. " is a school level")
			t.eq(spec.elevation, want.elevation, id .. " elevation")
			t.eq(spec.height, want.height, id .. " height")
			t.eq(spec.prefix, want.prefix, id .. " prefix")
			t.eq(spec.exitSide, want.exitSide, id .. " stairs up")
			t.eq(WorldConfig.levelPrefix(id), want.prefix)
			t.truthy(WorldConfig.isSchoolLevel(id), id .. " is in the school")
		end
		t.eq(levels, #WorldConfig.LevelOrder, "a stack entry per school level")
		for i, id in WorldConfig.LevelOrder do
			t.eq(WorldConfig.nextLevel(id), WorldConfig.LevelOrder[i + 1], id .. " next")
			t.eq(WorldConfig.previousLevel(id), WorldConfig.LevelOrder[i - 1], id .. " previous")
			if i > 1 then
				local below = WorldConfig.Levels[WorldConfig.LevelOrder[i - 1]]
				t.truthy(WorldConfig.Levels[id].elevation > below.elevation + below.height - 1e-6, id .. " sits above")
			end
		end
		for _, id in { "City1_Rooftops", "City2_Airport" } do
			t.falsy(WorldConfig.isSchoolLevel(id), id .. " is no part of the school")
			t.eq(WorldConfig.nextLevel(id), nil)
		end
	end,

	["the stair pairs go east, west, east, each with North and South candidates"] = function(t: Expect)
		local sides = { "East", "West", "East" }
		local ids: { [string]: boolean } = {}
		for _, spec in WorldConfig.Stairwells do
			t.falsy(ids[spec.id], spec.id .. " is unique")
			ids[spec.id] = true
			t.eq(spec.from, WorldConfig.LevelOrder[spec.pair], spec.id .. " from")
			t.eq(spec.to, WorldConfig.LevelOrder[spec.pair + 1], spec.id .. " to")
			local tower = WorldConfig.Towers[spec.tower]
			t.eq(tower.side, sides[spec.pair], spec.id .. " side")
		end
		t.eq(#WorldConfig.Stairwells, 9, "three pairs of three candidates")
		for pair = 0, 2 do
			local base = string.format("Stairwell_%d_%d", pair, pair + 1)
			for _, suffix in { "", "_North", "_South" } do
				t.truthy(ids[base .. suffix], base .. suffix)
			end
		end
		for id in ids do
			t.falsy(string.find(id, "Stairwell_3_4", 1, true) or string.find(id, "Stairwell_4_5", 1, true), id)
		end
		-- the roof is entered through its stair housings, the floors below through their vestibules
		for _, spec in WorldConfig.Stairwells do
			if spec.to == "Level3_Roof" then
				t.eq(string.sub(spec.toRoom, 1, 13), "L3_RoofAccess", spec.id .. " lands in a roof housing")
			end
		end
	end,
}
