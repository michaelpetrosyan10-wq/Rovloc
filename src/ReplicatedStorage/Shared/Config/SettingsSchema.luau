--!strict
-- Player settings: keys, ranges and defaults. SettingsController applies them; PlayerDataStore persists them.
-- Brightness (-2..+2 around the graded default) goes to LightingController.SetBrightness. Graphics (a Choice: an
-- index into GraphicsConfig.Order, Max by default) is read by GraphicsController.
--
-- Hidden entries (hidden = true) are saved and sanitized like every other setting but never drawn by SettingsMenu: the
-- onboarding's progress (TutorialConfig.TutorialSetting: the walkthrough was finished or skipped; one Hint<Id> flag per
-- first-time hint once shown). They live in the Settings blob because they are this player's own presentation state,
-- exactly like a preference: no gameplay authority, already sanitized by this schema, saved by the existing debounced
-- SettingsSave, and kept for the session by SettingsController for guests and ephemeral data.

export type NumberSetting = {
	key: string,
	kind: "Number",
	label: string, -- Strings key
	hidden: boolean?, -- saved, never shown in the settings menu
	min: number,
	max: number,
	step: number,
	default: number,
}

export type BoolSetting = {
	key: string,
	kind: "Bool",
	label: string,
	hidden: boolean?,
	default: boolean,
}

-- One of a few named options, saved as its index (a number, so the save blob, the SettingsSave validator and the data
-- migration treat it like any other number). Strings names each option "<label>.<option>" and describes it in one
-- line, "<label>.<option>.Info".
export type ChoiceSetting = {
	key: string,
	kind: "Choice",
	label: string,
	hidden: boolean?,
	options: { string },
	default: number, -- index into options
}

export type Setting = NumberSetting | BoolSetting | ChoiceSetting

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GraphicsConfig = require(ReplicatedStorage.Shared.Config.GraphicsConfig)

local GRAPHICS_OPTIONS: { string } = {}
for _, name in GraphicsConfig.Order do
	table.insert(GRAPHICS_OPTIONS, name)
end

local SettingsSchema = {}

SettingsSchema.List = table.freeze({
	-- How much this client renders, best first (GraphicsConfig tiers; GraphicsController applies it).
	{
		key = "Graphics",
		kind = "Choice",
		label = "Settings.Graphics",
		options = table.freeze(GRAPHICS_OPTIONS),
		default = GraphicsConfig.indexOf(GraphicsConfig.Default),
	},
	{
		key = "MouseSensitivity",
		kind = "Number",
		label = "Settings.MouseSensitivity",
		min = 0.2,
		max = 3,
		step = 0.05,
		default = 1,
	},
	{
		key = "GamepadSensitivity",
		kind = "Number",
		label = "Settings.GamepadSensitivity",
		min = 0.2,
		max = 3,
		step = 0.05,
		default = 1,
	},
	{
		key = "TouchSensitivity",
		kind = "Number",
		label = "Settings.TouchSensitivity",
		min = 0.2,
		max = 3,
		step = 0.05,
		default = 1,
	},
	{ key = "InvertY", kind = "Bool", label = "Settings.InvertY", default = false },
	{ key = "BaseFov", kind = "Number", label = "Settings.BaseFov", min = 60, max = 90, step = 1, default = 70 },
	{
		key = "MotionScale",
		kind = "Number",
		label = "Settings.MotionScale",
		min = 0,
		max = 1,
		step = 0.05,
		default = 1,
	},
	{ key = "FlashScale", kind = "Number", label = "Settings.FlashScale", min = 0, max = 1, step = 0.05, default = 1 },
	-- Steps around the lighting the game is graded to (0): each lifts or lowers the exposure and the ambient fill a
	-- little (LightingMood.BrightnessStep), for dark or bright monitors.
	{ key = "Brightness", kind = "Number", label = "Settings.Brightness", min = -2, max = 2, step = 1, default = 0 },
	{
		key = "MasterVolume",
		kind = "Number",
		label = "Settings.MasterVolume",
		min = 0,
		max = 1,
		step = 0.05,
		default = 1,
	},
	{
		key = "AmbienceVolume",
		kind = "Number",
		label = "Settings.AmbienceVolume",
		min = 0,
		max = 1,
		step = 0.05,
		default = 0.85,
	},
	{
		key = "WorldVolume",
		kind = "Number",
		label = "Settings.WorldVolume",
		min = 0,
		max = 1,
		step = 0.05,
		default = 1,
	},
	{
		key = "MonsterVolume",
		kind = "Number",
		label = "Settings.MonsterVolume",
		min = 0,
		max = 1,
		step = 0.05,
		default = 1,
	},
	{
		key = "PlayerVolume",
		kind = "Number",
		label = "Settings.PlayerVolume",
		min = 0,
		max = 1,
		step = 0.05,
		default = 0.9,
	},
	{ key = "UIVolume", kind = "Number", label = "Settings.UIVolume", min = 0, max = 1, step = 0.05, default = 0.8 },
	{ key = "Captions", kind = "Bool", label = "Settings.Captions", default = false },
	{ key = "ShowHints", kind = "Bool", label = "Settings.ShowHints", default = true },
	-- Onboarding progress (hidden; TutorialConfig names them)
	{ key = "TutorialDone", kind = "Bool", label = "Settings.TutorialDone", hidden = true, default = false },
	{ key = "HintBearTrap", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintVentGrate", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintFlask", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintLocker", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintDownedTeammate", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintWater", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintLowBattery", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintAirlock", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintObjLock0", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintObjLock1", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintObjLock2", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintObjLock3", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintObjLock4", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintObjBreaker", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintObjFumeHood", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintObjLockerSearch", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintObjStoreLock", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintObjGenerator", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintObjHatchValve", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
	{ key = "HintObjCrateChain", kind = "Bool", label = "Settings.HintSeen", hidden = true, default = false },
} :: { Setting })

local byKey: { [string]: Setting } = {}
for _, setting in SettingsSchema.List do
	byKey[setting.key] = setting
end

function SettingsSchema.get(key: string): Setting?
	return byKey[key]
end

-- The entries the settings menu draws (every one not hidden), in order.
function SettingsSchema.visible(): { Setting }
	local out: { Setting } = {}
	for _, setting in SettingsSchema.List do
		if not setting.hidden then
			table.insert(out, setting)
		end
	end
	return out
end

-- The option name a Choice setting's value stands for (its default's for anything out of range), or nil for a key
-- that is not a Choice.
function SettingsSchema.option(key: string, value: unknown): string?
	local setting = byKey[key]
	if not setting or setting.kind ~= "Choice" then
		return nil
	end
	local choice = setting :: ChoiceSetting
	local index = if type(value) == "number" then value else choice.default
	return choice.options[index] or choice.options[choice.default]
end

-- Defaults for every key, as a fresh mutable table.
function SettingsSchema.defaults(): { [string]: number | boolean }
	local out: { [string]: number | boolean } = {}
	for _, setting in SettingsSchema.List do
		out[setting.key] = setting.default
	end
	return out
end

-- Clamps, snaps and type-checks one incoming value. Returns nil for unknown keys or wrong types.
function SettingsSchema.sanitize(key: string, value: unknown): (number | boolean)?
	local setting = byKey[key]
	if not setting then
		return nil
	end
	if setting.kind == "Bool" then
		return if type(value) == "boolean" then value else nil
	end
	if type(value) ~= "number" or value ~= value then
		return nil
	end
	if setting.kind == "Choice" then
		local choice = setting :: ChoiceSetting
		return math.clamp(math.round(value), 1, #choice.options)
	end
	local numeric = setting :: NumberSetting
	local snapped = math.round(value / numeric.step) * numeric.step
	return math.clamp(snapped, numeric.min, numeric.max)
end

return table.freeze(SettingsSchema)
