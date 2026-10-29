--!strict
-- ObjectiveConfig: every floor's objective as data, shared by the world (layout anchors, RunDirector's seeded picks,
-- the prop builders' prompts) and the objective services of both versions.
--
-- Core rule: a floor's exit (the airlock fire door between the floor and its exit vestibule; on the roof, the
-- parachute crate) stays locked until the floor's steps are done. Each floor has one carryable item, seeded per run
-- (RunSeed) among the layout's candidate anchors of `item.candidate`: RunDirector.plan puts `item.count` of them in
-- the plan as props of kind `item.prop` and lists them in plan.objectives[levelId]. Every step names the station or
-- lock it is worked at; every prompt the builders create takes its hold from `holds` (by PromptKind) and carries the
-- Step attribute of the step it serves.
--
--   Floor 0  RestorePower  3 fuses (13 candidates, each with a bear-trap spot on its approach; the first 2 picked are
--                          guarded) -> fit them in the breaker panel (2 s each) -> throw the main breaker (3 s). Exit
--                          lock: Keypad (no power).
--   Floor 1  MasterKeys    the janitor's master keys (10 spots, all past the gate) -> unlock the stairwell door (4 s).
--                          Padlock.
--   Floor 2  BurnChain     3 reagents, one of each kind (12 candidates, four per kind) -> mix them at the fume hood
--                          (5 s) -> an acid flask -> throw it at the chain (within 3 studs) or pour it at the door (2 s).
--                          Chain.
--   Floor 3  GymGenerator  the coach's key (in any of the 32 locker-room lockers) -> unlock the equipment store (2 s) ->
--                          start the generator (3 s) -> survive 45 s while the door motor winds. Keypad (motor).
--   Floor 4  ValveWheel    the valve wheel (8 spots on the deep pool floor) -> fit it on the hatch valve (3 s) -> turn
--                          it (4 s). Keypad (hatch interlock).
--   Floor 5  CutCrate      the bolt cutters (9 candidates) -> cut the chain on the parachute crate (4 s).
--
-- Fair spots (the specs and web/tools/data-test.mjs hold every candidate to them): on a real surface the squad can
-- reach (on foot, through the vents or by swimming); a hiding spot within HideReach; at least EntryClearance studs of
-- walking from the floor's entry (ObjectivePlaces.entryDistance), never in the Floor 1 scare classroom. A run's items
-- (RunDirector.pickObjective) lie in different rooms, at least PickSpacing apart, and three of them in at least
-- PickQuarters quarters of the floor.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)

export type LockVariant = "Padlock" | "Chain" | "Keypad"

export type ItemSpec = {
	prop: string, -- plan prop kind (the Props builder registered for it)
	candidate: Enums.AnchorKind, -- the layout anchors RunDirector picks the run's spots from
	count: number, -- how many a run uses
	guarded: number?, -- fuses: how many of the used ones get a bear trap on their approach (the anchor's ref)
	slots: number?, -- reagents: the candidates in layout order cycle through this many kinds (slot 1, 2, 3, 1, ...)
	-- and a run uses one of each kind
	hold: number, -- Pickup prompt hold, seconds
	object: string, -- Strings key of the Pickup prompt's object text
}

export type StepSpec = {
	id: string, -- the Step attribute of the props and prompts that serve it
	count: number, -- how many times it is done ("Fuses 1/3")
	label: string, -- Strings key of the tracker line
	seconds: number?, -- a timed step (the door motor winding)
}

export type FloorSpec = {
	floor: number, -- 0 (basement) .. 5 (roof)
	levelId: Enums.LevelId,
	id: string,
	title: string, -- Strings key
	item: ItemSpec,
	steps: { StepSpec },
	lockStep: string, -- the step whose completion unlocks the exit
	lockVariant: LockVariant?, -- the ExitLock prop on the exit airlock door (nil on the roof: the crate chain)
	lockReason: string, -- Strings key of the Locked prompt on the exit lock
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
		levelId = "Level2_ScienceHall",
		id = "BurnChain",
		title = "Objective.Floor.BurnChain",
		item = {
			prop = "ReagentJar",
			candidate = "ReagentCandidate",
			count = 3,
			slots = 3,
			hold = 0.6,
			object = "Prompt.Reagent.1",
		},
		steps = {
			{ id = "FindReagents", count = 3, label = "Objective.Step.FindReagents" },
			{ id = "MixAcid", count = 1, label = "Objective.Step.MixAcid" },
			{ id = "BurnChain", count = 1, label = "Objective.Step.BurnChain" },
		},
		lockStep = "BurnChain",
		lockVariant = "Chain",
		lockReason = "Prompt.Locked.Level2_ScienceHall",
		holds = { Mix = 5, Pour = 2 },
	},
	{
		floor = 3,
		levelId = "Level3_Gymnasium",
		id = "GymGenerator",
		title = "Objective.Floor.GymGenerator",
		item = {
			prop = "CoachKey",
			candidate = "CoachKeyCandidate",
			count = 1,
			hold = 0.6,
			object = "Prompt.CoachKey",
		},
		steps = {
			{ id = "FindCoachKey", count = 1, label = "Objective.Step.FindCoachKey" },
			{ id = "UnlockStore", count = 1, label = "Objective.Step.UnlockStore" },
			{ id = "StartGenerator", count = 1, label = "Objective.Step.StartGenerator" },
			{ id = "WindMotor", count = 1, label = "Objective.Step.WindMotor", seconds = 45 },
		},
		lockStep = "WindMotor",
		lockVariant = "Keypad",
		lockReason = "Prompt.Locked.Level3_Gymnasium",
		holds = { Unlock = 2, Generator = 3 },
	},
	{
		floor = 4,
		levelId = "Level4_FloodedPool",
		id = "ValveWheel",
		title = "Objective.Floor.ValveWheel",
		item = {
			prop = "ValveWheel",
			candidate = "ValveWheelCandidate",
			count = 1,
			hold = 0.8,
			object = "Prompt.ValveWheel",
		},
		steps = {
			{ id = "FindWheel", count = 1, label = "Objective.Step.FindWheel" },
			{ id = "FitWheel", count = 1, label = "Objective.Step.FitWheel" },
			{ id = "TurnValve", count = 1, label = "Objective.Step.TurnValve" },
		},
		lockStep = "TurnValve",
		lockVariant = "Keypad",
		lockReason = "Prompt.Locked.Level4_FloodedPool",
		holds = { FitValve = 3, TurnValve = 4 },
	},
	{
		floor = 5,
		levelId = "Level5_Roof",
		id = "CutCrate",
		title = "Objective.Floor.CutCrate",
		item = {
			prop = "BoltCutters",
			candidate = "BoltCutterCandidate",
			count = 1,
			hold = 0.6,
			object = "Prompt.BoltCutters",
		},
		steps = {
			{ id = "FindCutters", count = 1, label = "Objective.Step.FindCutters" },
			{ id = "CutChain", count = 1, label = "Objective.Step.CutChain" },
		},
		lockStep = "CutChain",
		lockVariant = nil,
		lockReason = "Prompt.Locked.Level5_Roof",
		holds = { CutChain = 4 },
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

-- The step a store door unlock serves on Floor 3, and the prompt text of its lock.
ObjectiveConfig.StoreLockStep = "UnlockStore"
ObjectiveConfig.StoreLockReason = "Prompt.Locked.Store"

-- How close a hiding spot (a hideable locker, an open vent grate, a dark corner, or on the roof a plant block to crouch
-- behind) stands to every objective step's spot. The specs hold every layout to it.
ObjectiveConfig.HideReach = 25

-- How far (studs walked, ObjectivePlaces.entryDistance) every item candidate lies from the floor's entry, how far apart
-- the items of one run lie (horizontal), and in how many quarters of the floor a run's three items lie at least.
ObjectiveConfig.EntryClearance = 35
ObjectiveConfig.PickSpacing = 25
ObjectiveConfig.PickQuarters = 2

local byLevel: { [string]: FloorSpec } = {}
local byProp: { [string]: FloorSpec } = {}
for _, spec in ObjectiveConfig.Floors do
	byLevel[spec.levelId] = spec
	byProp[spec.item.prop] = spec
end

-- The objective of a level (nil for the Lobby).
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
