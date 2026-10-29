--!strict
-- Player settings: keys, ranges and defaults. SettingsController applies them; PlayerDataStore persists them.
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

export type Setting = NumberSetting | BoolSetting

local SettingsSchema = {}

SettingsSchema.List = table.freeze({
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
	local snapped = math.round(value / setting.step) * setting.step
	return math.clamp(snapped, setting.min, setting.max)
end

return table.freeze(SettingsSchema)
