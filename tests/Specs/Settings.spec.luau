--!strict
-- Settings: clamping and step snapping per SettingsSchema, decoding the saved JSON blob (bad entries dropped, the
-- rest over the defaults), the SettingsSave payload passing the server's own validator, and the getters' defaults.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

local SettingsController = require(StarterPlayer.StarterPlayerScripts.Controllers.Core.SettingsController)

type Expect = SpecRunner.Expect

local function numberSetting(key: string): SettingsSchema.NumberSetting
	local setting = SettingsSchema.get(key)
	assert(setting and setting.kind == "Number", key .. " is a number setting")
	return setting :: SettingsSchema.NumberSetting
end

return {
	["values clamp to the schema range and snap to its step"] = function(t: Expect)
		t.near(SettingsController.sanitize("MouseSensitivity", 1.234) :: number, 1.25, 1e-9)
		t.near(SettingsController.sanitize("MouseSensitivity", 9) :: number, 3, 1e-9, "clamped to max")
		t.near(SettingsController.sanitize("MouseSensitivity", -4) :: number, 0.2, 1e-9, "clamped to min")
		t.eq(SettingsController.sanitize("BaseFov", 70.4), 70)
		t.eq(SettingsController.sanitize("BaseFov", 59), 60)
		t.eq(SettingsController.sanitize("BaseFov", 120), 90)
		t.eq(SettingsController.sanitize("Captions", true), true)
		t.eq(SettingsController.sanitize("Captions", "yes"), nil, "wrong type")
		t.eq(SettingsController.sanitize("MasterVolume", 0 / 0), nil, "NaN")
		t.eq(SettingsController.sanitize("MasterVolume", "1"), nil, "numeric strings are not numbers")
		t.eq(SettingsController.sanitize("Gravity", 1), nil, "unknown key")
		for _, setting in SettingsSchema.List do
			if setting.kind == "Number" then
				local numeric = setting :: SettingsSchema.NumberSetting
				for step = -5, 25 do
					local raw = numeric.min + (numeric.max - numeric.min) * step / 20
					local clean = SettingsController.sanitize(numeric.key, raw) :: number
					t.truthy(clean >= numeric.min and clean <= numeric.max, numeric.key .. " in range")
					t.near(clean / numeric.step, math.round(clean / numeric.step), 1e-6, numeric.key .. " on a step")
				end
			end
		end
	end,

	["a saved blob decodes over the defaults; bad entries are dropped"] = function(t: Expect)
		local defaults = SettingsSchema.defaults()
		local function expectDefaults(raw: unknown, label: string)
			local decoded = SettingsController.decode(raw)
			for key, value in defaults do
				t.eq(decoded[key], value, string.format("%s default for %s", key, label))
			end
		end
		expectDefaults(nil, "nil")
		for _, raw in { "", "not json", "[1, 2, 3]", "42", '"text"' } do
			expectDefaults(raw, raw)
		end
		local blob = HttpService:JSONEncode({
			MouseSensitivity = 1.5,
			BaseFov = 200,
			InvertY = true,
			Captions = "on",
			MasterVolume = 0.33,
			Gravity = 2,
		})
		local decoded = SettingsController.decode(blob)
		t.near(decoded.MouseSensitivity :: number, 1.5, 1e-9)
		t.eq(decoded.BaseFov, 90, "clamped")
		t.eq(decoded.InvertY, true)
		t.eq(decoded.Captions, defaults.Captions, "a wrong type keeps the default")
		t.near(decoded.MasterVolume :: number, 0.35, 1e-9, "snapped to the 0.05 step")
		t.eq(decoded.Gravity, nil, "unknown keys are not carried")
		local fromTable = SettingsController.decode({ UIVolume = 0.5, [3] = true } :: any)
		t.near(fromTable.UIVolume :: number, 0.5, 1e-9, "an already-decoded table works too")
		local count = 0
		for _ in fromTable do
			count += 1
		end
		t.eq(count, #SettingsSchema.List, "every schema key and nothing else")
	end,

	["the save payload carries every key and passes the server's validator"] = function(t: Expect)
		local spec = RemoteRegistry.get("SettingsSave")
		t.truthy(spec and spec.validate, "SettingsSave is validated")
		local validate = if spec then spec.validate else nil
		local values = SettingsSchema.defaults()
		values.MouseSensitivity = 2.9999999
		values.BaseFov = 71
		values.Captions = true
		local payload = SettingsController.payload(values)
		for _, setting in SettingsSchema.List do
			t.truthy(payload.settings[setting.key] ~= nil, "payload has " .. setting.key)
		end
		if validate then
			t.truthy(validate(payload), "defaults-based payload validates")
			local extremes: { [string]: number | boolean } = {}
			for _, setting in SettingsSchema.List do
				if setting.kind == "Number" then
					extremes[setting.key] = (setting :: SettingsSchema.NumberSetting).max + 0.0001
				else
					extremes[setting.key] = true
				end
			end
			t.truthy(validate(SettingsController.payload(extremes)), "out-of-range values are clamped before sending")
		end
	end,

	["getters read the schema defaults before anything is set"] = function(t: Expect)
		local fov = numberSetting("BaseFov")
		t.eq(SettingsController.GetNumber("BaseFov"), fov.default)
		t.eq(SettingsController.Get("BaseFov"), fov.default)
		t.eq(SettingsController.GetBool("Captions"), false)
		t.eq(SettingsController.GetBool("InvertY"), false)
		t.eq(SettingsController.GetNumber("MasterVolume"), 1)
		local all = SettingsController.GetAll()
		for _, setting in SettingsSchema.List do
			t.truthy(all[setting.key] ~= nil, setting.key)
		end
		all.BaseFov = 1
		t.eq(SettingsController.GetNumber("BaseFov"), fov.default, "GetAll returns a copy")
		t.falsy(SettingsController.IsLoaded(), "no blob has been read here")
	end,
}
