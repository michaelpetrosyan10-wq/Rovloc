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
--   Level2_Auditorium  ReachExit     reach the east stairs (the interim floor: no item, no lock).
--   The roof and the city levels have no objective here yet.
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

export type StepSpec = {
	id: string, -- the Step attribute of the props and prompts that serve it
	count: number, -- how many times it is done ("Fuses 1/3")
	label: string, -- Strings key of the tracker line
}

export type FloorSpec = {
	floor: number, -- the level's place in run order, 0 (basement) .. 5 (StageConfig's floor)
	levelId: Enums.LevelId,
	id: string,
	title: string, -- Strings key
	item: ItemSpec?, -- nil: the floor has no item to find
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
		steps = {
			{ id = "FindFuses", count = 3, label = "Objective.Step.FindFuses" },
			{ id = "FitFuses", count = 3, label = "Objective.Step.FitFuses" },
			{ id = "ThrowBreaker", count = 1, label = "Objective.Step.ThrowBreaker" },
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
		steps = {
			{ id = "FindKeys", count = 1, label = "Objective.Step.FindKeys" },
			{ id = "UnlockExit", count = 1, label = "Objective.Step.UnlockExit" },
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
			{ id = "ReachExit", count = 1, label = "Objective.Step.Exit" },
		},
		lockStep = nil,
		lockVariant = nil,
		lockReason = nil,
		holds = {},
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
