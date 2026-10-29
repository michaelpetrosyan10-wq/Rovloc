--!strict
-- Payload validators for client-to-server remotes. Every incoming payload is untrusted: these reject wrong
-- types, NaN/inf, oversized strings and tables, unknown enum values and unexpected keys before any handler runs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)

export type Validator = (value: unknown) -> boolean

local Validators = {}

local MAX_TABLE_KEYS = 48 -- the settings blob is the widest payload (SettingsSchema: 36 keys)

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

function Validators.boolean(): Validator
	return function(value: unknown): boolean
		return type(value) == "boolean"
	end
end

function Validators.number(min: number, max: number): Validator
	return function(value: unknown): boolean
		return type(value) == "number" and isFinite(value) and value >= min and value <= max
	end
end

function Validators.integer(min: number, max: number): Validator
	return function(value: unknown): boolean
		return type(value) == "number" and isFinite(value) and value % 1 == 0 and value >= min and value <= max
	end
end

function Validators.string(maxLength: number): Validator
	return function(value: unknown): boolean
		return type(value) == "string" and #value <= maxLength and utf8.len(value) ~= nil
	end
end

function Validators.enum<T>(list: { T }): Validator
	return function(value: unknown): boolean
		return Enums.has(list, value)
	end
end

function Validators.vector3(maxMagnitude: number): Validator
	return function(value: unknown): boolean
		if typeof(value) ~= "Vector3" then
			return false
		end
		local v = value :: Vector3
		return isFinite(v.X) and isFinite(v.Y) and isFinite(v.Z) and v.Magnitude <= maxMagnitude
	end
end

function Validators.unitVector(): Validator
	return function(value: unknown): boolean
		if typeof(value) ~= "Vector3" then
			return false
		end
		local v = value :: Vector3
		return isFinite(v.X) and isFinite(v.Y) and isFinite(v.Z) and math.abs(v.Magnitude - 1) < 0.02
	end
end

function Validators.optional(inner: Validator): Validator
	return function(value: unknown): boolean
		return value == nil or inner(value)
	end
end

function Validators.arrayOf(inner: Validator, maxLength: number): Validator
	return function(value: unknown): boolean
		if type(value) ~= "table" then
			return false
		end
		local tbl = value :: { [any]: any }
		local count = 0
		for key, entry in tbl do
			count += 1
			if count > maxLength or type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > maxLength then
				return false
			end
			if not inner(entry) then
				return false
			end
		end
		return count == #tbl
	end
end

function Validators.mapOf(keyValidator: Validator, valueValidator: Validator, maxEntries: number): Validator
	return function(value: unknown): boolean
		if type(value) ~= "table" then
			return false
		end
		local count = 0
		for key, entry in value :: { [any]: any } do
			count += 1
			if count > maxEntries or not keyValidator(key) or not valueValidator(entry) then
				return false
			end
		end
		return true
	end
end

function Validators.oneOf(options: { Validator }): Validator
	return function(value: unknown): boolean
		for _, option in options do
			if option(value) then
				return true
			end
		end
		return false
	end
end

-- A table with exactly these fields (missing optional fields allowed, extra keys rejected).
function Validators.shape(fields: { [string]: Validator }): Validator
	return function(value: unknown): boolean
		if type(value) ~= "table" then
			return false
		end
		local tbl = value :: { [any]: any }
		local count = 0
		for key in tbl do
			count += 1
			if count > MAX_TABLE_KEYS or type(key) ~= "string" or fields[key] == nil then
				return false
			end
		end
		for key, validator in fields do
			if not validator(tbl[key]) then
				return false
			end
		end
		return true
	end
end

-- An empty table (or nil) for remotes that carry no data.
function Validators.empty(): Validator
	return function(value: unknown): boolean
		if value == nil then
			return true
		end
		return type(value) == "table" and next(value :: { [any]: any }) == nil
	end
end

return table.freeze(Validators)
