--!strict
-- SettingsController: the player's settings, applied live and saved.
--
--   * Values start at the SettingsSchema defaults. The data layer (P8) writes the saved blob as JSON into the local
--     Player's Settings attribute after loading; it is read once (now, or when it first appears), every entry checked
--     against the schema (unknown keys, wrong types and NaN dropped; numbers clamped and snapped to their step). Keys
--     the player already changed this session keep the local value.
--   * Applying: bus volumes go to AudioBuses.setVolume (Body follows the Player volume), FlashScale to
--     LightingController.SetFlashScale, Brightness to LightingController.SetBrightness; everything else
--     (sensitivities, InvertY, BaseFov, MotionScale, Captions) is read by its consumer through Get* and Changed.
--   * Set clamps / snaps per the schema, applies, fires Changed, and saves through SettingsSave 2 s after the last
--     change (a slider drag sends one message, not hundreds).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local AudioBuses = require(ReplicatedStorage.Shared.Audio.AudioBuses)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local LightingController = require(script.Parent.LightingController)

local log = Log.new("SettingsController")

local P = Attributes.Player

export type Value = number | boolean
export type Values = { [string]: Value }

local SAVE_DEBOUNCE = 2

-- Settings that are a bus volume, and the bus they drive.
local VOLUME_BUSES: { [string]: AudioBuses.BusName } = {
	MasterVolume = "Master",
	AmbienceVolume = "Ambience",
	WorldVolume = "World",
	MonsterVolume = "Monster",
	PlayerVolume = "Player",
	UIVolume = "UI",
}

local SettingsController = {}

SettingsController.Name = "SettingsController"
SettingsController.SaveDebounce = SAVE_DEBOUNCE

local changed: Signal.Signal<string, Value> = Signal.new()
SettingsController.Changed = changed

local serviceTrove = Trove.new()
local values: Values = SettingsSchema.defaults()
local editedKeys: { [string]: boolean } = {}
local loadedBlob = false
local saveGeneration = 0
local savePending = false

--------------------------------------------------------------------------------
-- Pure rules (specced)
--------------------------------------------------------------------------------

-- The schema's verdict on one incoming value: the clamped / snapped value, or nil for unknown keys and bad types.
function SettingsController.sanitize(key: string, value: unknown): Value?
	return SettingsSchema.sanitize(key, value)
end

-- A saved blob (JSON text or an already-decoded table) -> every schema key, valid saved values over the defaults.
function SettingsController.decode(raw: unknown): Values
	local out = SettingsSchema.defaults()
	local blob: unknown = raw
	if type(raw) == "string" then
		if raw == "" then
			return out
		end
		local ok, decoded = pcall(function(): any
			return HttpService:JSONDecode(raw)
		end)
		if not ok then
			return out
		end
		blob = decoded
	end
	if type(blob) ~= "table" then
		return out
	end
	for key, value in blob :: { [any]: any } do
		if type(key) == "string" then
			local clean = SettingsSchema.sanitize(key, value)
			if clean ~= nil then
				out[key] = clean
			end
		end
	end
	return out
end

-- The SettingsSave payload for a value table: only schema keys, each sanitized.
function SettingsController.payload(from: Values): Types.SettingsSavePayload
	local settings: { [string]: Value } = {}
	for _, setting in SettingsSchema.List do
		local clean = SettingsSchema.sanitize(setting.key, from[setting.key])
		settings[setting.key] = if clean ~= nil then clean else setting.default
	end
	return { settings = settings }
end

--------------------------------------------------------------------------------
-- Apply
--------------------------------------------------------------------------------

local function apply(key: string, value: Value)
	local bus: AudioBuses.BusName? = VOLUME_BUSES[key]
	if bus and type(value) == "number" then
		AudioBuses.setVolume(bus, value)
	elseif key == "FlashScale" and type(value) == "number" then
		LightingController.SetFlashScale(value)
	elseif key == "Brightness" and type(value) == "number" then
		LightingController.SetBrightness(value)
	end
end

local function applyAll()
	for _, setting in SettingsSchema.List do
		apply(setting.key, values[setting.key])
	end
end

local function save()
	savePending = false
	xpcall(function()
		Net.Client.fire("SettingsSave", SettingsController.payload(values))
	end, function(err: any)
		log.warn("settings save failed: %s", tostring(err))
	end)
end

local function scheduleSave()
	saveGeneration += 1
	local generation = saveGeneration
	savePending = true
	task.delay(SAVE_DEBOUNCE, function()
		if generation == saveGeneration and savePending then
			save()
		end
	end)
end

-- Adopts a decoded blob for every key the player has not changed locally (no save: it is what the server holds).
local function adopt(decoded: Values)
	for _, setting in SettingsSchema.List do
		local key = setting.key
		local value = decoded[key]
		if value ~= nil and not editedKeys[key] and values[key] ~= value then
			values[key] = value
			apply(key, value)
			changed:Fire(key, value)
		end
	end
end

local function readBlob(player: Player): boolean
	local raw = player:GetAttribute(P.Settings)
	if type(raw) ~= "string" or raw == "" then
		return false
	end
	loadedBlob = true
	adopt(SettingsController.decode(raw))
	return true
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- The current value (the schema default until set). Unknown keys warn and read as false.
function SettingsController.Get(key: string): Value
	local value = values[key]
	if value == nil then
		log.warnThrottled("get" .. key, 30, "unknown setting %s", key)
		return false
	end
	return value
end

function SettingsController.GetNumber(key: string): number
	local value = values[key]
	if type(value) == "number" then
		return value
	end
	local setting = SettingsSchema.get(key)
	if setting and setting.kind == "Number" then
		return (setting :: SettingsSchema.NumberSetting).default
	end
	log.warnThrottled("number" .. key, 30, "setting %s is not a number", key)
	return 0
end

function SettingsController.GetBool(key: string): boolean
	local value = values[key]
	if type(value) == "boolean" then
		return value
	end
	log.warnThrottled("bool" .. key, 30, "setting %s is not a boolean", key)
	return false
end

-- Clamps / snaps per the schema, applies, fires Changed and schedules the save. Invalid values are ignored.
function SettingsController.Set(key: string, value: Value)
	local clean = SettingsSchema.sanitize(key, value)
	if clean == nil then
		log.warnThrottled("set" .. key, 30, "ignored invalid value %s for setting %s", tostring(value), key)
		return
	end
	editedKeys[key] = true
	if values[key] == clean then
		return
	end
	values[key] = clean
	apply(key, clean)
	changed:Fire(key, clean)
	scheduleSave()
end

-- A copy of every current value.
function SettingsController.GetAll(): Values
	return table.clone(values)
end

-- True once the saved blob has been read (false while playing on defaults).
function SettingsController.IsLoaded(): boolean
	return loadedBlob
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function SettingsController.Init()
	applyAll()
end

function SettingsController.Start()
	local player = Players.LocalPlayer
	if not player then
		return
	end
	if readBlob(player) then
		return
	end
	local connection: RBXScriptConnection? = nil
	connection = serviceTrove:Connect(player:GetAttributeChangedSignal(P.Settings), function()
		if readBlob(player) then
			local live = connection
			if live then
				serviceTrove:Remove(live)
				connection = nil
			end
		end
	end)
end

return table.freeze(SettingsController)
