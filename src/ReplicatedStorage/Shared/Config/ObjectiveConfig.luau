--!strict
-- ObjectiveConfig: every floor's objective as data, shared by the world (layout anchors, RunDirector's seeded picks,
-- the prop builders' prompts) and the objective services of both versions.
--
-- Core rule: a floor's exit (the airlock fire door between the floor and its exit vestibule) stays locked until the
-- floor's lock step is done. A floor with an item has one carryable item, seeded per run (RunSeed) among the layout's
-- candidate anchors of `item.candidate`: RunDirector.plan puts `item.count` of them in the plan as props of kind
-- `item.prop` and lists them in plan.objectives[levelId]. Every step names the station or lock it is worked at; every
-- prompt the builders create takes its hold from `holds` (by PromptKind) and carries the Step attribute of the step it
-- serves. A floor without an item and without a lock step is a plain crossing: its exit is open from the start and its
-- one step is done when the squad reaches the exit.
--
-- Levels are keyed by id; `floor` is the dense 0..5 run order of the six levels (StageConfig's).
--
--   Level0_Basement    RestorePower  3 fuses (13 candidates, each with a bear-trap spot on its approach; the first 2
--                                    picked are guarded) -> fit them in the breaker panel (2 s each) -> throw the main
--                                    breaker (3 s). Exit lock: Keypad (no power).
--   Level1_Hallways    MasterKeys    the janitor's master keys (all past the gate) -> unlock the stairwell door (4 s).
--                                    Padlock.
--   Level2_Auditorium  ReachExit     reach the east stairs (the interim floor: no item, no lock; the package that
--                                    builds the theatre switches it).
--   City1_Rooftops     PowerSkybridge close 3 of the 6 feeder cabinets (3 s each; the run's picks lie on both arcs of
--                                    the ring: RunDirector.pickStations). Exit lock: Keypad (no power).
--   City2_Airport      Preflight     2 of 10 fuel cans -> the wing filler (2.5 s each) -> the hangar switch (2 s, then
--                                    the door's 20 s) -> board (0.8 s each) -> start the engines (3 s).
--   The roof has no floor objective.
--
-- Every step has a `kind` from a small generic vocabulary, and `at` names the anchor kind of the station it is worked at:
--   Find      pick up `count` of the floor's items          Deliver   bring the carried items to the station `at`
--   Work      hold the station `at`'s prompt                Stations  work each of the run's picked stations (`stations`)
--   Survive   hold `at`, then last `seconds` (no teleports)  Reach     get to the exit
-- `mainStation` is the anchor kind of the floor's main station (the radar's batteries keep one in reach of it).
--
-- Fair spots (the specs and web/tools/data-test.mjs hold every candidate to them): on a real surface the squad can
-- reach (on foot or through the vents); a hiding spot within HideReach; at least EntryClearance studs of
-- walking from the floor's entry (ObjectivePlaces.entryDistance), never in the Floor 1 scare classroom. A run's items
-- (RunDirector.pickObjective) lie in different rooms, at least PickSpacing apart, and three of them in at least
-- PickQuarters quarters of the floor.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)

export type LockVariant = "Padlock" | "Keypad"

export type ItemSpec = {
	prop: string, -- plan prop kind (the Props builder registered for it)
	candidate: Enums.AnchorKind, -- the layout anchors RunDirector picks the run's spots from
	count: number, -- how many a run uses
	guarded: number?, -- fuses: how many of the used ones get a bear trap on their approach (the anchor's ref)
	hold: number, -- Pickup prompt hold, seconds
	object: string, -- Strings key of the Pickup prompt's object text
}

-- The floor's stations when a run picks them (the rooftops' feeders): `count` of the layout's `candidate` anchors,
-- seeded per run; `arcs`: at least one north and one south of the frame's centre line (z 144).
export type StationSpec = {
	prop: string, -- plan prop kind of the station
	candidate: Enums.AnchorKind,
	count: number,
	arcs: boolean?,
}

export type StepKind = "Find" | "Deliver" | "Work" | "Stations" | "Survive" | "Reach"

export type StepSpec = {
	id: string, -- the Step attribute of the props and prompts that serve it
	count: number, -- how many times it is done ("Fuses 1/3")
	label: string, -- Strings key of the tracker line
	kind: StepKind,
	at: Enums.AnchorKind?, -- the anchor kind of the station it is worked at (Deliver, Work, Stations, Survive)
	seconds: number?, -- Survive: the countdown after the hold
}

export type FloorSpec = {
	floor: number, -- the level's place in run order, 0 (basement) .. 5 (StageConfig's floor)
	levelId: Enums.LevelId,
	id: string,
	title: string, -- Strings key
	item: ItemSpec?, -- nil: the floor has no item to find
	stations: StationSpec?, -- the stations a run picks (nil: the floor's stations are fixed anchors)
	mainStation: Enums.AnchorKind?, -- the floor's main station (nil: the exit)
	steps: { StepSpec },
	lockStep: string?, -- the step whose completion unlocks the exit (nil: the exit is never locked)
	lockVariant: LockVariant?, -- the ExitLock prop on the exit airlock doors (nil: no lock)
	lockReason: string?, -- Strings key of the Locked prompt on the exit lock
	holds: { [string]: number }, -- prompt holds by PromptKind, seconds
}

local ObjectiveConfig = {}

local FLOORS: { FloorSpec } = {
	{
		floor = 0,
		levelId = "Level0_Basement",
		id = "RestorePower",
		title = "Objective.Floor.RestorePower",
		item = {
			prop = "Fuse",
			candidate = "FuseCandidate",
			count = 3,
			guarded = 2,
			hold = 0.6,
			object = "Prompt.Fuse",
		},
		mainStation = "BreakerPanel",
		steps = {
			{ id = "FindFuses", count = 3, label = "Objective.Step.FindFuses", kind = "Find" },
			{
				id = "FitFuses",
				count = 3,
				label = "Objective.Step.FitFuses",
				kind = "Deliver",
				at = "BreakerPanel",
			},
			{
				id = "ThrowBreaker",
				count = 1,
				label = "Objective.Step.ThrowBreaker",
				kind = "Work",
				at = "BreakerPanel",
			},
		},
		lockStep = "ThrowBreaker",
		lockVariant = "Keypad",
		lockReason = "Prompt.Locked.Level0_Basement",
		holds = { FitFuse = 2, Breaker = 3 },
	},
	{
		floor = 1,
		levelId = "Level1_Hallways",
		id = "MasterKeys",
		title = "Objective.Floor.MasterKeys",
		item = {
			prop = "MasterKeys",
			candidate = "MasterKeyCandidate",
			count = 1,
			hold = 0.6,
			object = "Prompt.MasterKeys",
		},
		mainStation = "ExitLock",
		steps = {
			{ id = "FindKeys", count = 1, label = "Objective.Step.FindKeys", kind = "Find" },
			{ id = "UnlockExit", count = 1, label = "Objective.Step.UnlockExit", kind = "Work", at = "ExitLock" },
		},
		lockStep = "UnlockExit",
		lockVariant = "Padlock",
		lockReason = "Prompt.Locked.Level1_Hallways",
		holds = { Unlock = 4 },
	},
	{
		floor = 2,
		levelId = "Level2_Auditorium",
		id = "ReachExit",
		title = "Objective.Floor.ReachExit",
		item = nil,
		steps = {
			{ id = "ReachExit", count = 1, label = "Objective.Step.Exit", kind = "Reach" },
		},
		lockStep = nil,
		lockVariant = nil,
		lockReason = nil,
		holds = {},
	},
	{
		floor = 4,
		levelId = "City1_Rooftops",
		id = "PowerSkybridge",
		title = "Objective.Floor.PowerSkybridge",
		item = nil,
		stations = { prop = "FeederCabinet", candidate = "FeederCandidate", count = 3, arcs = true },
		mainStation = "FeederCandidate",
		steps = {
			{
				id = "CloseFeeders",
				count = 3,
				label = "Objective.Step.CloseFeeders",
				kind = "Stations",
				at = "FeederCandidate",
			},
		},
		lockStep = "CloseFeeders",
		lockVariant = "Keypad",
		lockReason = "Prompt.Locked.City1_Rooftops",
		holds = { CloseFeeder = 3 },
	},
	{
		floor = 5,
		levelId = "City2_Airport",
		id = "Preflight",
		title = "Objective.Floor.Preflight",
		item = {
			prop = "FuelCan",
			candidate = "FuelCanCandidate",
			count = 2,
			hold = 0.6,
			object = "Prompt.FuelCan",
		},
		mainStation = "WingFiller",
		steps = {
			{ id = "FindFuel", count = 2, label = "Objective.Step.FindFuel", kind = "Find" },
			{ id = "FuelPlane", count = 2, label = "Objective.Step.FuelPlane", kind = "Deliver", at = "WingFiller" },
			{
				id = "OpenHangar",
				count = 1,
				label = "Objective.Step.OpenHangar",
				kind = "Survive",
				at = "HangarSwitch",
				seconds = 20,
			},
			{ id = "Board", count = 1, label = "Objective.Step.Board", kind = "Work", at = "CabinDoor" },
		},
		lockStep = "Board",
		lockVariant = nil,
		lockReason = nil,
		holds = { FuelPlane = 2.5, HangarSwitch = 2, Board = 0.8, StartEngines = 3 },
	},
}

local function deepFreeze(value: any)
	if type(value) == "table" and not table.isfrozen(value) then
		for _, child in value do
			deepFreeze(child)
		end
		table.freeze(value)
	end
end
deepFreeze(FLOORS)
ObjectiveConfig.Floors = FLOORS

-- How close a hiding spot (a hideable locker, a barrel or cabinet, an open vent grate, a dark corner) stands to every
-- objective step's spot. The specs hold every layout to it.
ObjectiveConfig.HideReach = 25

-- How far (studs walked, ObjectivePlaces.entryDistance) every item candidate lies from the floor's entry, how far apart
-- the items of one run lie (horizontal), and in how many quarters of the floor a run's three items lie at least.
ObjectiveConfig.EntryClearance = 35
ObjectiveConfig.PickSpacing = 25
ObjectiveConfig.PickQuarters = 2

-- What the objective services tune beyond the floors above (seconds and studs; the web build mirrors every number).
ObjectiveConfig.Tuning = table.freeze({
	WorkNoisePeriod = 1, -- a working hold (an unlock) emits WorkNoise at its start and then this often
	WorkNoise = "ObjectiveWork" :: Enums.NoiseKind,
	LoudNoise = "ObjectiveClunk" :: Enums.NoiseKind, -- the breaker, each exit unlocking
	LockOffSeconds = 0.9, -- a lock comes off over this
	DoorDelay = 0.75, -- the exit door swings open this long after the unlock clunk
	PowerOffFactor = 0.04, -- the basement's mains while the power is out
	PowerOnSeconds = 2.6, -- their switch-on stutter
	LeverCreep = 0.22, -- the share of the breaker lever's throw it creeps over the hold
	HintRadius = 12, -- a station or lock's first-time hint: this close to the eye, with a clear line
	DropSpread = 1.2, -- studs between the items a carrier drops
})

-- Where the Creature starts on the basement and the Auditorium, and its grace there (the Hallways keep their scripted
-- scare, the roof its door, whose wait uses Grace too). The basement has the Creature too (docs/MONSTER.md 5).
ObjectiveConfig.Spawn = table.freeze({
	Levels = table.freeze({ "Level0_Basement", "Level2_Auditorium" } :: { string }),
	MinDistance = 70, -- studs walked from the entry (ObjectivePlaces.walkDistance)
	MaxDistance = 140,
	Grace = table.freeze({ Standard = 20, Nightmare = 12 } :: { [string]: number }),
	EntryEyeHeight = 4.6, -- the entry room's sample points (its centre and its corners inset EntryInset) ...
	EntryInset = 2,
	AnchorHeights = table.freeze({ 2.2, 7.4 } :: { number }), -- ... to these heights over the anchor
	ReleaseNear = 30, -- the held Creature lets go when a player comes this close ...
	ReleaseSight = 70, -- ... or can see its head from this far
	Stream = "CreatureSpawn|", -- the seeded stream, by level
})

-- Every floor as plain data for the website (world.json meta.objectiveConfig: every row, the city's included;
-- meta.objectives carries the rows of the levels the world builds, with their candidates and places).
function ObjectiveConfig.exportMeta(): { [string]: any }
	local function copy(value: any): any
		if type(value) ~= "table" then
			return value
		end
		local out: { [any]: any } = {}
		for key, item in value do
			out[key] = copy(item)
		end
		return out
	end
	return {
		floors = copy(FLOORS),
		hideReach = ObjectiveConfig.HideReach,
		entryClearance = ObjectiveConfig.EntryClearance,
		pickSpacing = ObjectiveConfig.PickSpacing,
		pickQuarters = ObjectiveConfig.PickQuarters,
		tuning = copy(ObjectiveConfig.Tuning),
		spawn = copy(ObjectiveConfig.Spawn),
	}
end

-- The grace of a difficulty (Standard's for an unknown one).
function ObjectiveConfig.graceFor(difficulty: string): number
	return ObjectiveConfig.Spawn.Grace[difficulty] or ObjectiveConfig.Spawn.Grace.Standard
end

local byLevel: { [string]: FloorSpec } = {}
local byProp: { [string]: FloorSpec } = {}
for _, spec in ObjectiveConfig.Floors do
	byLevel[spec.levelId] = spec
	local item = spec.item
	if item then
		byProp[item.prop] = spec
	end
end

-- The objective of a level (nil for the Lobby and for a level without one).
function ObjectiveConfig.forLevel(levelId: string): FloorSpec?
	return byLevel[levelId]
end

-- The floor whose item a plan prop kind is (nil for any other prop).
function ObjectiveConfig.forItem(propKind: string): FloorSpec?
	return byProp[propKind]
end

-- A prompt hold of `spec` (by PromptKind); errors on a kind the floor does not use, so a typo never ships a 0 s hold.
function ObjectiveConfig.hold(spec: FloorSpec, kind: string): number
	local seconds = spec.holds[kind]
	assert(seconds, string.format("ObjectiveConfig: %s has no %s hold", spec.id, kind))
	return seconds
end

return table.freeze(ObjectiveConfig)
