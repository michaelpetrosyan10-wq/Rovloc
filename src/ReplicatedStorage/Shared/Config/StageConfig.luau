--!strict
-- StageConfig: the run, stage by stage (docs/design/game-spec-v2.md 0.1). Order is the nine stages in the order they
-- play: three sets (Enums.SetId: scenes, no level) and six playable levels (Enums.LevelId). Every table in the game
-- that is per stage (cards, credits, lives, radar, batteries, flasks, objectives, voice odds) is keyed by these ids,
-- never by a stage's or a level's number.
--
-- Each row: the stage id; whether it is a Set or a Level; what is played there (`play`, in the order it happens); the
-- Strings key of its title card (nil: no card); its par time in seconds (`parReplay`: on a replay, where the stage
-- plays shorter); and, for a level, its `floor`, the dense 0..5 the objective data numbers the levels by
-- (ObjectiveConfig's `floor` agrees with it).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)

export type StageKind = "Set" | "Level"

export type StagePlay =
	"Cutscene" -- a cutscene plays
	| "Walk" -- a short walk to the next stage
	| "Sneak" -- a sneaking level: objectives, the Creature hunting
	| "Chase" -- a scripted chase
	| "Standoff" -- the revolver and the choice
	| "Twist"
	| "Parachute"
	| "Parkour"

export type Stage = {
	id: Enums.StageId,
	kind: StageKind,
	play: { StagePlay },
	card: string?, -- Strings key of the stage card (nil: the stage shows none)
	par: number, -- seconds
	parReplay: number?, -- seconds, when a replay plays it shorter
	floor: number?, -- levels only: 0..5 in run order
}

local StageConfig = {}

local ORDER: { Stage } = {
	{ id = "BackLot", kind = "Set", play = { "Cutscene", "Walk" }, card = nil, par = 140, parReplay = 70 },
	{
		id = "Level0_Basement",
		kind = "Level",
		play = { "Sneak" },
		card = "Stage.Card.Level0_Basement",
		par = 480,
		floor = 0,
	},
	{
		id = "Level1_Hallways",
		kind = "Level",
		play = { "Sneak" },
		card = "Stage.Card.Level1_Hallways",
		par = 480,
		floor = 1,
	},
	{
		id = "Level2_Auditorium",
		kind = "Level",
		play = { "Sneak" },
		card = "Stage.Card.Level2_Auditorium",
		par = 450,
		floor = 2,
	},
	{
		id = "Level3_Roof",
		kind = "Level",
		play = { "Chase", "Standoff", "Twist", "Parachute" },
		card = "Stage.Card.Level3_Roof",
		par = 240,
		floor = 3,
	},
	{
		id = "City1_Rooftops",
		kind = "Level",
		play = { "Sneak", "Parkour" },
		card = "Stage.Card.City1_Rooftops",
		par = 480,
		floor = 4,
	},
	{
		id = "City2_Airport",
		kind = "Level",
		play = { "Sneak" },
		card = "Stage.Card.City2_Airport",
		par = 420,
		floor = 5,
	},
	{ id = "Runway", kind = "Set", play = { "Chase" }, card = "Stage.Card.Runway", par = 45 },
	{ id = "Bahamas", kind = "Set", play = { "Cutscene" }, card = nil, par = 45 },
}

local function deepFreeze(value: any)
	if type(value) == "table" and not table.isfrozen(value) then
		for _, child in value do
			deepFreeze(child)
		end
		table.freeze(value)
	end
end
deepFreeze(ORDER)

-- The nine stages in run order.
StageConfig.Order = ORDER

local byId: { [string]: Stage } = {}
for _, stage in ORDER do
	byId[stage.id] = stage
end
StageConfig.ById = table.freeze(byId)

-- The stage with id `id` (nil for an unknown id).
function StageConfig.get(id: string): Stage?
	return byId[id]
end

-- The stage after `id` in run order (nil after the last and for an unknown id).
function StageConfig.nextStage(id: string): Stage?
	for i, stage in ORDER do
		if stage.id == id then
			return ORDER[i + 1]
		end
	end
	return nil
end

-- The floor number (0-5) of level `id`; nil for a set or an unknown id.
function StageConfig.floorOf(id: string): number?
	local stage = byId[id]
	return if stage then stage.floor else nil
end

-- The par of stage `id` in seconds (`replay`: its replay par where it has one).
function StageConfig.parSeconds(id: string, replay: boolean?): number?
	local stage = byId[id]
	if not stage then
		return nil
	end
	return if replay and stage.parReplay then stage.parReplay else stage.par
end

return table.freeze(StageConfig)
