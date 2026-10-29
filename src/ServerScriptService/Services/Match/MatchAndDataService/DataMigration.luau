--!strict
-- DataMigration: the persisted player record's schema (Types.PlayerData, ARCHITECTURE §6d) as pure functions.
--
--   defaults()        a new player's data at the current schema version
--   migrate(raw)      whatever the store holds -> (current-version data, status):
--                       New       nothing stored yet: the defaults
--                       Current   stored at this version (sanitized)
--                       Migrated  stored at an older version and stepped up through MIGRATIONS, one version at a time
--                       Future    written by a newer build (a rolling update): a sanitized read-only view of the
--                                 fields this build knows; the caller must never write it back (it would drop fields)
--                       Corrupt   not a table, or a version this build cannot step from: the defaults as a read-only
--                                 view; never written back either
--   sanitize(raw)     every known field coerced into range (integers, non-negative, known perks / difficulties /
--                     settings only); unknown fields dropped. Lenient: it repairs what it reads.
--   validate(data)    strict: the reasons a committed draft is unacceptable (MatchAndDataService.Update refuses it
--                     instead of repairing a bad mutation, so a buggy purchase can never mint credits)
--   copy / freeze     deep thawed copy (an Update draft) / deep frozen copy (what GetData hands out)
--
-- Version 0 is a record without a `v` field (one hand-edited in the Creator Dashboard's data store editor or imported
-- by a tool): its fields are read under the v1 names and the record is stamped v1.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)
local Types = require(ReplicatedStorage.Shared.Types)

export type Status = "New" | "Current" | "Migrated" | "Future" | "Corrupt"

type Raw = { [any]: any }
type Step = (record: Raw) -> Raw

local CURRENT_VERSION = 1
local MAX_CREDITS = 1_000_000_000
local MAX_ESCAPES = 1_000_000_000
local MAX_STOCK = 9_999
local MAX_RUN_ID_LENGTH = 64
local MAX_BEST_TIME = 7 * 24 * 3600 -- a week of play: anything longer is not a run time

local DataMigration = {}

DataMigration.Version = CURRENT_VERSION
DataMigration.MaxCredits = MAX_CREDITS
DataMigration.MaxStock = MAX_STOCK
DataMigration.MaxRunIdLength = MAX_RUN_ID_LENGTH

-- MIGRATIONS[n] turns a version-n record into a version-(n + 1) record (still raw; sanitize runs after the last step).
local MIGRATIONS: { [number]: Step } = {
	[0] = function(record: Raw): Raw
		local out = table.clone(record)
		out.v = 1
		return out
	end,
}

--------------------------------------------------------------------------------
-- Field readers (lenient)
--------------------------------------------------------------------------------

local function wholeNumber(value: unknown, maximum: number): number
	if type(value) ~= "number" or not MathUtil.isFinite(value) then
		return 0
	end
	return math.clamp(math.floor(value), 0, maximum)
end

local function bestTimes(value: unknown): { Standard: number?, Nightmare: number? }
	local out: { Standard: number?, Nightmare: number? } = {}
	if type(value) ~= "table" then
		return out
	end
	local source = value :: Raw
	for _, difficulty: Enums.Difficulty in Enums.Difficulty do
		local time = source[difficulty]
		if type(time) == "number" and MathUtil.isFinite(time) and time > 0 and time <= MAX_BEST_TIME then
			if difficulty == "Standard" then
				out.Standard = time
			else
				out.Nightmare = time
			end
		end
	end
	return out
end

local function perkStock(value: unknown): { [string]: number }
	local out: { [string]: number } = {}
	if type(value) ~= "table" then
		return out
	end
	local source = value :: Raw
	for _, perk: Enums.PerkId in Enums.PerkId do
		local count = wholeNumber(source[perk], MAX_STOCK)
		if count > 0 then
			out[perk] = count
		end
	end
	return out
end

local function settingsBlob(value: unknown): Types.SettingsBlob
	local out: Types.SettingsBlob = {}
	if type(value) ~= "table" then
		return out
	end
	for key, entry in value :: Raw do
		if type(key) == "string" then
			local clean = SettingsSchema.sanitize(key, entry)
			if clean ~= nil then
				out[key] = clean
			end
		end
	end
	return out
end

local function runId(value: unknown): string
	if type(value) == "string" and #value <= MAX_RUN_ID_LENGTH then
		return value
	end
	return ""
end

--------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------

function DataMigration.defaults(): Types.PlayerData
	return {
		v = CURRENT_VERSION,
		Escapes = 0,
		SurvivalCredits = 0,
		BestTime = {},
		PerkStock = {},
		Settings = {},
		LastRunId = "",
	}
end

-- Every known field of `raw` coerced into range, stamped with the current version.
function DataMigration.sanitize(raw: unknown): Types.PlayerData
	if type(raw) ~= "table" then
		return DataMigration.defaults()
	end
	local source = raw :: Raw
	return {
		v = CURRENT_VERSION,
		Escapes = wholeNumber(source.Escapes, MAX_ESCAPES),
		SurvivalCredits = wholeNumber(source.SurvivalCredits, MAX_CREDITS),
		BestTime = bestTimes(source.BestTime),
		PerkStock = perkStock(source.PerkStock),
		Settings = settingsBlob(source.Settings),
		LastRunId = runId(source.LastRunId),
	}
end

-- The stored value -> current-version data and how it got there (see the header).
function DataMigration.migrate(raw: unknown): (Types.PlayerData, Status)
	if raw == nil then
		return DataMigration.defaults(), "New"
	end
	if type(raw) ~= "table" then
		return DataMigration.defaults(), "Corrupt"
	end
	local record = raw :: Raw
	local version = record.v
	if version == nil then
		version = 0
	end
	if type(version) ~= "number" or not MathUtil.isFinite(version) or version < 0 or version ~= math.floor(version) then
		return DataMigration.defaults(), "Corrupt"
	end
	if version > CURRENT_VERSION then
		return DataMigration.sanitize(record), "Future"
	end
	local from = version
	while version < CURRENT_VERSION do
		local step = MIGRATIONS[version]
		if not step then
			return DataMigration.defaults(), "Corrupt"
		end
		record = step(record)
		version += 1
	end
	return DataMigration.sanitize(record), if from == CURRENT_VERSION then "Current" else "Migrated"
end

local function isWhole(value: unknown, maximum: number): boolean
	return type(value) == "number"
		and MathUtil.isFinite(value)
		and value >= 0
		and value <= maximum
		and value == math.floor(value)
end

-- Why `data` must not be committed (nil when it is acceptable).
function DataMigration.validate(data: Types.PlayerData): string?
	if data.v ~= CURRENT_VERSION then
		return "schema version changed"
	end
	if not isWhole(data.SurvivalCredits, MAX_CREDITS) then
		return "SurvivalCredits out of range: " .. tostring(data.SurvivalCredits)
	end
	if not isWhole(data.Escapes, MAX_ESCAPES) then
		return "Escapes out of range: " .. tostring(data.Escapes)
	end
	if type(data.LastRunId) ~= "string" or #data.LastRunId > MAX_RUN_ID_LENGTH then
		return "LastRunId is not a run id"
	end
	if type(data.BestTime) ~= "table" then
		return "BestTime is not a table"
	end
	for key, time in data.BestTime :: Raw do
		if not Enums.has(Enums.Difficulty, key) then
			return "BestTime has an unknown difficulty " .. tostring(key)
		end
		if type(time) ~= "number" or not MathUtil.isFinite(time) or time <= 0 or time > MAX_BEST_TIME then
			return "BestTime." .. tostring(key) .. " out of range"
		end
	end
	if type(data.PerkStock) ~= "table" then
		return "PerkStock is not a table"
	end
	for perk, count in data.PerkStock :: Raw do
		if not Enums.has(Enums.PerkId, perk) then
			return "PerkStock has an unknown perk " .. tostring(perk)
		end
		if not isWhole(count, MAX_STOCK) then
			return "PerkStock." .. tostring(perk) .. " out of range"
		end
	end
	if type(data.Settings) ~= "table" then
		return "Settings is not a table"
	end
	for key, value in data.Settings :: Raw do
		if type(key) ~= "string" or SettingsSchema.sanitize(key, value) ~= value then
			return "Settings." .. tostring(key) .. " is not a valid setting"
		end
	end
	return nil
end

-- A deep, thawed copy of plain data (tables, numbers, strings, booleans).
local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, entry in value do
		out[deepCopy(key)] = deepCopy(entry)
	end
	return out
end

local function deepFreeze(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, entry in value do
		out[key] = deepFreeze(entry)
	end
	return table.freeze(out)
end

-- A deep, writable copy (an Update draft).
function DataMigration.copy(data: Types.PlayerData): Types.PlayerData
	return deepCopy(data) :: Types.PlayerData
end

-- A deep, frozen copy (GetData snapshots: callers can hold them, never change them).
function DataMigration.freeze(data: Types.PlayerData): Types.PlayerData
	return deepFreeze(data) :: Types.PlayerData
end

-- A deep, writable copy of any stored value (backends never share tables with their callers).
function DataMigration.copyValue(value: unknown): unknown
	return deepCopy(value)
end

-- True when two data snapshots hold the same values.
function DataMigration.equal(a: unknown, b: unknown): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	local left = a :: Raw
	local right = b :: Raw
	for key, value in left do
		if not DataMigration.equal(value, right[key]) then
			return false
		end
	end
	for key in right do
		if left[key] == nil then
			return false
		end
	end
	return true
end

return table.freeze(DataMigration)
