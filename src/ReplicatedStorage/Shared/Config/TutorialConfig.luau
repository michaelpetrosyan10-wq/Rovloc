--!strict
-- TutorialConfig: the onboarding's data (OnboardingController, ObjectiveTracker, FirstTimeHints, LobbySignage).
--
--   * Pages: the HOW TO PLAY walkthrough in order. Each page has a Strings title and body and a procedural
--     illustration (OnboardingController draws `art` from Frames). The Controls page is device-aware: its rows come from
--     ControlRows and InputConfig, and its body has one Strings key per device (body .. "." .. device).
--   * Hints: the first-time contextual hints, highest priority first. Each one is shown once per player (its saved
--     flag is the hidden SettingsSchema Bool `setting`), with up to two input glyphs (an InputConfig action and the
--     Strings label beside it). `radius` is how near the thing must be, for the hints about a thing in the world.
--   * Floors: the title card and the in-run objective lines for each level. `stairwell` names the stairwell tower the
--     level leaves by (WorldConfig.Stairwells), so the objective reads "Find the east stairwell".
--   * Lobby: the lobby walkthrough's steps (the floating marker follows the first one not done).
--   * Timings for the tracker, the direction nudge, the floor card and the hints.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

export type PageArt = "Goal" | "Creature" | "Noise" | "Tools" | "Teamwork" | "Controls" | "Lobby"

export type Page = {
	id: string,
	art: PageArt,
	title: string, -- Strings key
	body: string, -- Strings key (the Controls page appends "." .. device)
	deviceBody: boolean,
}

-- One row of the Controls page: an InputConfig action (its glyph comes from the binding for the device), or a fixed
-- control (move, look) whose glyph text is a Strings key per device (glyph .. "." .. device).
export type ControlRow = {
	label: string, -- Strings key
	action: Enums.InputAction?,
	glyph: string?, -- Strings key prefix for controls without an action
}

-- The exit locks' hints are keyed by the level's id (ObjLock_<LevelId>).
export type HintId =
	"Airlock"
	| "DownedTeammate"
	| "BearTrap"
	| "Flask"
	| "VentGrate"
	| "Locker"
	| "LowBattery"
	| "ObjLock_Level0_Basement"
	| "ObjLock_Level1_Hallways"
	| "ObjBreaker"
	-- spec v2 (docs/design/game-spec-v2.md 3.1, 4.10): the parkour moves, the radar, the get-up, the revolver, the takeoff
	| "Hurdle"
	| "Slide"
	| "Leap"
	| "Radar"
	| "GetUp"
	| "Revolver"
	| "Takeoff"

-- A floor objective's station or lock (FirstTimeHints finds it by ObjectiveId on `level` while its step is undone).
export type HintSpot = {
	objectiveId: string, -- ExitLock | BreakerPanel
	level: string,
	step: string, -- shown while this step is not done (ObjectiveSteps)
	after: string?, -- and only once this one is done
}

export type HintInput = { action: Enums.InputAction, label: string }

export type Hint = {
	id: HintId,
	text: string, -- Strings key
	inputs: { HintInput },
	setting: string, -- hidden SettingsSchema Bool: true once shown
	radius: number?, -- studs, for a thing in the world
	spot: HintSpot?, -- a floor objective's station or lock (within ObjectiveConfig.Tuning.HintRadius, in sight)
}

export type Floor = {
	title: string, -- Strings key: "FLOOR 1"
	name: string, -- Strings key: "MAIN HALLWAYS"
	tip: string, -- Strings key: the objective's second line
	stairwell: string?, -- "East" | "West": the tower the level leaves by (nil on the roof)
}

export type LobbyStepId = "Bus" | "Ready" | "Vote" | "Perks"

export type LobbyStep = { id: LobbyStepId, text: string, optional: boolean }

local TutorialConfig = {}

-- The hidden SettingsSchema Bool that remembers the walkthrough was finished or skipped.
TutorialConfig.TutorialSetting = "TutorialDone"
-- The visible SettingsSchema Bool that turns the first-time hints on and off.
TutorialConfig.HintsSetting = "ShowHints"

local PAGES: { Page } = {
	{ id = "Goal", art = "Goal", title = "Tutorial.Goal.Title", body = "Tutorial.Goal.Body", deviceBody = false },
	{
		id = "Creature",
		art = "Creature",
		title = "Tutorial.Creature.Title",
		body = "Tutorial.Creature.Body",
		deviceBody = false,
	},
	{ id = "Noise", art = "Noise", title = "Tutorial.Noise.Title", body = "Tutorial.Noise.Body", deviceBody = false },
	{ id = "Tools", art = "Tools", title = "Tutorial.Tools.Title", body = "Tutorial.Tools.Body", deviceBody = false },
	{
		id = "Teamwork",
		art = "Teamwork",
		title = "Tutorial.Teamwork.Title",
		body = "Tutorial.Teamwork.Body",
		deviceBody = false,
	},
	{
		id = "Controls",
		art = "Controls",
		title = "Tutorial.Controls.Title",
		body = "Tutorial.Controls.Body",
		deviceBody = true,
	},
	{ id = "Lobby", art = "Lobby", title = "Tutorial.Lobby.Title", body = "Tutorial.Lobby.Body", deviceBody = false },
}
TutorialConfig.Pages = table.freeze(PAGES)

local CONTROL_ROWS: { ControlRow } = {
	{ label = "Tutorial.Control.Move", glyph = "Tutorial.Glyph.Move" },
	{ label = "Tutorial.Control.Look", glyph = "Tutorial.Glyph.Look" },
	{ label = "Tutorial.Control.Sprint", action = "Sprint" },
	{ label = "Tutorial.Control.Crouch", action = "Crouch" },
	{ label = "Tutorial.Control.Flashlight", action = "Flashlight" },
	{ label = "Tutorial.Control.Interact", action = "Interact" },
	{ label = "Tutorial.Control.Kick", action = "Kick" },
	{ label = "Tutorial.Control.Throw", action = "Throw" },
	{ label = "Tutorial.Control.Radar", action = "Radar" },
	{ label = "Tutorial.Control.Menu", action = "Menu" },
}
TutorialConfig.ControlRows = table.freeze(CONTROL_ROWS)

-- Highest priority first: when several are due at once, the first one shows (the rest wait their turn).
local HINTS: { Hint } = {
	{
		id = "Airlock",
		text = "Hint.Airlock",
		inputs = {},
		setting = "HintAirlock",
	},
	{
		id = "ObjLock_Level0_Basement",
		text = "Hint.Obj.Lock.Level0_Basement",
		inputs = {},
		setting = "HintObjLock_Level0_Basement",
		spot = { objectiveId = "ExitLock", level = "Level0_Basement", step = "ThrowBreaker" },
	},
	{
		id = "ObjLock_Level1_Hallways",
		text = "Hint.Obj.Lock.Level1_Hallways",
		inputs = {},
		setting = "HintObjLock_Level1_Hallways",
		spot = { objectiveId = "ExitLock", level = "Level1_Hallways", step = "UnlockExit" },
	},
	{
		id = "ObjBreaker",
		text = "Hint.Obj.BreakerPanel",
		inputs = {},
		setting = "HintObjBreaker",
		spot = { objectiveId = "BreakerPanel", level = "Level0_Basement", step = "ThrowBreaker" },
	},
	{
		id = "DownedTeammate",
		text = "Hint.DownedTeammate",
		inputs = { { action = "Interact", label = "Hint.Input.Revive" } },
		setting = "HintDownedTeammate",
	},
	{
		id = "GetUp",
		text = "Hint.GetUp",
		inputs = { { action = "Interact", label = "Hint.Input.GetUp" } },
		setting = "HintGetUp",
	},
	{
		id = "BearTrap",
		text = "Hint.BearTrap",
		inputs = {
			{ action = "Crouch", label = "Hint.Input.Crouch" },
			{ action = "Interact", label = "Hint.Input.Pry" },
		},
		setting = "HintBearTrap",
		radius = 16,
	},
	{
		id = "Flask",
		text = "Hint.Flask",
		inputs = {
			{ action = "Interact", label = "Hint.Input.PickUp" },
			{ action = "Throw", label = "Hint.Input.Throw" },
		},
		setting = "HintFlask",
		radius = 12,
	},
	{
		id = "VentGrate",
		text = "Hint.VentGrate",
		inputs = {
			{ action = "Interact", label = "Hint.Input.Unscrew" },
			{ action = "Kick", label = "Hint.Input.Kick" },
		},
		setting = "HintVentGrate",
		radius = 11,
	},
	{
		id = "Locker",
		text = "Hint.Locker",
		inputs = {
			{ action = "Interact", label = "Hint.Input.Hide" },
			{ action = "HoldBreath", label = "Hint.Input.HoldBreath" },
		},
		setting = "HintLocker",
		radius = 10,
	},
	{
		id = "LowBattery",
		text = "Hint.LowBattery",
		inputs = { { action = "Flashlight", label = "Hint.Input.Light" } },
		setting = "HintLowBattery",
	},
	{
		id = "Radar",
		text = "Hint.Radar",
		inputs = { { action = "Radar", label = "Hint.Input.Radar" } },
		setting = "HintRadar",
	},
	{
		id = "Hurdle",
		text = "Hint.Hurdle",
		inputs = {},
		setting = "HintHurdle",
		radius = 12,
	},
	{
		id = "Slide",
		text = "Hint.Slide",
		inputs = {
			{ action = "Sprint", label = "Hint.Input.Sprint" },
			{ action = "Crouch", label = "Hint.Input.Slide" },
		},
		setting = "HintSlide",
		radius = 14,
	},
	{
		id = "Leap",
		text = "Hint.Leap",
		inputs = { { action = "Sprint", label = "Hint.Input.Sprint" } },
		setting = "HintLeap",
		radius = 20,
	},
	{
		id = "Revolver",
		text = "Hint.Revolver",
		inputs = {
			{ action = "Fire", label = "Hint.Input.Fire" },
			{ action = "LowerGun", label = "Hint.Input.Lower" },
		},
		setting = "HintRevolver",
	},
	{
		id = "Takeoff",
		text = "Hint.Takeoff",
		inputs = { { action = "PullUp", label = "Hint.Input.PullUp" } },
		setting = "HintTakeoff",
	},
}
for _, hint in HINTS do
	table.freeze(hint.inputs)
	table.freeze(hint)
end
TutorialConfig.Hints = table.freeze(HINTS)

-- The battery fraction at or under which the low-battery hint is due (while the light is on).
TutorialConfig.LowBatteryFraction = 0.2

local function stairwellOf(level: Enums.LevelId): string?
	for _, stairwell in WorldConfig.Stairwells do
		if stairwell.from == level then
			return stairwell.tower
		end
	end
	return nil
end

-- Every school level by id: its Strings keys are "Floor.<id>.Title", "Floor.<id>.Name" and "Objective.Tip.<id>".
local FLOORS: { [string]: Floor } = {}
for _, levelId: Enums.LevelId in WorldConfig.LevelOrder do
	FLOORS[levelId] = {
		title = "Floor." .. levelId .. ".Title",
		name = "Floor." .. levelId .. ".Name",
		tip = "Objective.Tip." .. levelId,
		stairwell = stairwellOf(levelId),
	}
end
for _, floor in FLOORS do
	table.freeze(floor)
end
TutorialConfig.Floors = table.freeze(FLOORS)

local LOBBY_STEPS: { LobbyStep } = {
	{ id = "Bus", text = "Objective.Lobby.Bus", optional = false },
	{ id = "Ready", text = "Objective.Lobby.Ready", optional = false },
	{ id = "Vote", text = "Objective.Lobby.Vote", optional = true },
	{ id = "Perks", text = "Objective.Lobby.Perks", optional = true },
}
for _, step in LOBBY_STEPS do
	table.freeze(step)
end
TutorialConfig.LobbySteps = table.freeze(LOBBY_STEPS)

TutorialConfig.Timing = table.freeze({
	TrackerHold = 9, -- seconds the objective stays fully shown after it changes or is asked for
	TrackerFade = 1.6, -- seconds it takes to fade out after that
	DirectionShow = 3.5, -- seconds the direction nudge shows
	DirectionCooldown = 20, -- seconds before the next nudge
	FloorCardIn = 1.2,
	FloorCardHold = 3.6,
	FloorCardOut = 1.6,
	FloorCardWait = 8, -- a card due while the HUD is hidden waits this long for it, then is dropped
	HintSeconds = 7, -- how long a first-time hint stays
	HintGap = 5, -- quiet seconds between two hints
	HintPanicMax = 0.55, -- no hint while the panic is above this (FirstPersonController.GetPanic)
	TitleDriftPeriod = 64, -- seconds for one loop of the title screen's camera
})

-- The title screen's camera drift through the boiler room: level-local points of the Lobby layout (eye, look-at),
-- one loop, Catmull-Rom through them. Every eye stays inside Lobby_BoilerRoom (x 0..60, z 0..48, 20 high).
local DRIFT: { { eye: Vector3, look: Vector3 } } = {
	{ eye = Vector3.new(10, 6.5, 42), look = Vector3.new(30, 5.5, 8) },
	{ eye = Vector3.new(30, 8, 44), look = Vector3.new(24, 6, 6) },
	{ eye = Vector3.new(50, 7, 40), look = Vector3.new(64, 5, 30) },
	{ eye = Vector3.new(52, 9.5, 20), look = Vector3.new(30, 6, 6) },
	{ eye = Vector3.new(30, 11, 30), look = Vector3.new(8, 5, 8) },
	{ eye = Vector3.new(12, 8, 30), look = Vector3.new(40, 4, 10) },
}
for _, key in DRIFT do
	table.freeze(key)
end
TutorialConfig.TitleDrift = table.freeze(DRIFT)

-- The first-time hints and their saved flags as plain data for the website (world.json meta.tutorialConfig).
function TutorialConfig.exportMeta(): { [string]: any }
	local hints: { any } = {}
	for _, hint in HINTS do
		local inputs: { any } = {}
		for _, input in hint.inputs do
			table.insert(inputs, table.clone(input))
		end
		table.insert(hints, {
			id = hint.id,
			text = hint.text,
			inputs = inputs,
			setting = hint.setting,
			radius = hint.radius,
			spot = if hint.spot then table.clone(hint.spot) else nil,
		})
	end
	return {
		hints = hints,
		hintsSetting = TutorialConfig.HintsSetting,
		tutorialSetting = TutorialConfig.TutorialSetting,
		lowBatteryFraction = TutorialConfig.LowBatteryFraction,
		timing = table.clone(TutorialConfig.Timing),
	}
end

return table.freeze(TutorialConfig)
