--!strict
-- StoreBackend: where player records live. Two backends behind one interface, so PlayerDataStore (session lock, save
-- queue, migrations) never knows which one it talks to:
--
--   Live       DataStoreService: every write is one UpdateAsync (atomic read-modify-write; the transform may run
--              more than once on contention, so transforms are pure functions of the stored value). Before each
--              request it waits (bounded) for the UpdateAsync request budget, so a burst of saves queues here instead
--              of in the engine's throttle. UserIds are attached to every write (GDPR erasure requests find them).
--   Ephemeral  an in-memory table with the same semantics (the transform sees a copy of the stored value; nil
--              cancels the write; values are deep-copied in and out, so nothing outside shares the stored tables).
--              Used in Studio when the place has no API access (unpublished, or "Enable Studio Access to API
--              Services" off) and in the Lune harness, where DataStoreService has no implementation.
--
-- choose(isStudio, storeName) picks one and may yield: live servers always use the DataStore; Studio probes it once
-- (GetDataStore + a GetAsync of a probe key inside pcall) and falls back to Ephemeral, returning the reason.
--
-- Specs build their own backends on this interface (failing, gated, counting) around `ephemeral()`.

local DataStoreService = game:GetService("DataStoreService")

local DataMigration = require(script.Parent.DataMigration)

export type Kind = "Live" | "Ephemeral"

-- Receives the stored value (nil when the key is empty) and returns the value to store, or nil to cancel the write.
export type Transform = (current: unknown) -> unknown

export type Backend = {
	kind: Kind,
	-- Atomic read-modify-write of `key`. Yields. (true) when the transform ran and its result (or its cancel) took
	-- effect, (false, message) when the request failed.
	update: (key: string, transform: Transform, userIds: { number }?) -> (boolean, string?),
	-- The stored value of `key` (nil when empty). Yields. (false, message) when the request failed.
	read: (key: string) -> (boolean, unknown),
}

local BUDGET_WAIT_SECONDS = 6
local BUDGET_POLL_SECONDS = 0.25
local PROBE_KEY = "__probe"

local StoreBackend = {}

StoreBackend.ProbeKey = PROBE_KEY

local function message(err: unknown): string
	return if type(err) == "string" then err else tostring(err)
end

-- Waits (at most BUDGET_WAIT_SECONDS) until the UpdateAsync budget allows a request. The budget call itself can
-- fail on a server without DataStore access; the request then goes ahead and reports its own error.
local function waitForBudget(requestType: Enum.DataStoreRequestType)
	local waited = 0
	while waited < BUDGET_WAIT_SECONDS do
		local ok, budget = pcall(function(): number
			return DataStoreService:GetRequestBudgetForRequestType(requestType)
		end)
		if not ok or budget > 0 then
			return
		end
		task.wait(BUDGET_POLL_SECONDS)
		waited += BUDGET_POLL_SECONDS
	end
end

-- The DataStore backend over `store`.
function StoreBackend.dataStore(store: DataStore): Backend
	local function update(key: string, transform: Transform, userIds: { number }?): (boolean, string?)
		waitForBudget(Enum.DataStoreRequestType.UpdateAsync)
		local ok, err = pcall(function()
			store:UpdateAsync(key, function(current: any): (any, { number }?, {}?)
				local nextValue = transform(DataMigration.copyValue(current))
				if nextValue == nil then
					return nil, nil, nil
				end
				return nextValue, userIds, nil
			end)
		end)
		if not ok then
			return false, message(err)
		end
		return true, nil
	end

	local function read(key: string): (boolean, unknown)
		waitForBudget(Enum.DataStoreRequestType.GetAsync)
		local ok, value = pcall(function(): any
			return (store:GetAsync(key))
		end)
		if not ok then
			return false, message(value)
		end
		return true, value
	end

	return table.freeze({ kind = "Live" :: Kind, update = update, read = read })
end

-- An in-memory backend with the DataStore's update semantics (see the header).
function StoreBackend.ephemeral(): Backend
	local records: { [string]: unknown } = {}

	local function update(key: string, transform: Transform, _userIds: { number }?): (boolean, string?)
		local ok, result = pcall(transform, DataMigration.copyValue(records[key]))
		if not ok then
			return false, message(result)
		end
		if result ~= nil then
			records[key] = DataMigration.copyValue(result)
		end
		return true, nil
	end

	local function read(key: string): (boolean, unknown)
		return true, DataMigration.copyValue(records[key])
	end

	return table.freeze({ kind = "Ephemeral" :: Kind, update = update, read = read })
end

-- A Live backend whose every request fails with `reason` (a live server that could not open its store).
function StoreBackend.unavailable(reason: string): Backend
	local function update(_key: string, _transform: Transform, _userIds: { number }?): (boolean, string?)
		return false, reason
	end
	local function read(_key: string): (boolean, unknown)
		return false, reason
	end
	return table.freeze({ kind = "Live" :: Kind, update = update, read = read })
end

-- The backend for this server and, when it is not the plain DataStore, why. Yields in Studio (the probe).
function StoreBackend.choose(isStudio: boolean, storeName: string): (Backend, string?)
	local ok, store = pcall(function(): DataStore
		return DataStoreService:GetDataStore(storeName)
	end)
	if not ok then
		if isStudio then
			return StoreBackend.ephemeral(), message(store)
		end
		-- A live server that cannot even open the store still runs Live: every request fails, so each player plays
		-- on read-only guest data and keeps retrying, and nothing is ever written anywhere else.
		return StoreBackend.unavailable(message(store)), message(store)
	end
	local backend = StoreBackend.dataStore(store)
	if not isStudio then
		return backend, nil
	end
	local probeOk, probeErr = backend.read(PROBE_KEY)
	if not probeOk then
		return StoreBackend.ephemeral(), message(probeErr)
	end
	return backend, nil
end

return table.freeze(StoreBackend)
