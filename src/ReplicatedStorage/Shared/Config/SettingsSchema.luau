--!strict
-- Player settings: keys, ranges and defaults. SettingsController applies them; PlayerDataStore persists them.

export type NumberSetting = {
	key: string,
	kind: "Number",
	label: string, -- Strings key
	min: number,
	max: number,
	step: number,
	default: number,
}

export type BoolSetting = {
	key: string,
	kind: "Bool",
	label: string,
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
} :: { Setting })

local byKey: { [string]: Setting } = {}
for _, setting in SettingsSchema.List do
	byKey[setting.key] = setting
end

function SettingsSchema.get(key: string): Setting?
	return byKey[key]
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
