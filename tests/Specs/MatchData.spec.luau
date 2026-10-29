--!strict
-- MatchData. DataMigration (defaults, every migrate status, the lenient sanitize and the strict validate, frozen
-- copies), the Ephemeral backend's semantics, PlayerDataStore's pure lock rules (acquire / save / release over every
-- stored shape) and the store itself on a fake clock with injected backends: a fresh load locks the record, release
-- writes the final data and clears the lock (twice is once), saves are serialized, paced to the per-key interval and
-- coalesced (a gated backend holds a write in flight), a fresh foreign lock is retried with backoff and then played as
-- a guest until Retry takes it once stale, failing requests back off and flip the health, a stolen session stops
-- writing, a quick rejoin waits for the release in flight, autosave refreshes the lock, a newer schema is never written
-- back. Then MatchAndDataService's data API over that store: Update refused before the load and for guests, a commit
-- mirrored and announced, every discarded mutation (false, throws, yields, invalid), settings sanitized and kept until
-- the load, the Settings attribute and frozen snapshots.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)
local Types = require(ReplicatedStorage.Shared.Types)

local MatchFolder = ServerScriptService.Services.Match
local MatchAndDataService = require(MatchFolder.MatchAndDataService)
local DataMigration = require(MatchFolder.MatchAndDataService.DataMigration)
local PlayerDataStore = require(MatchFolder.MatchAndDataService.PlayerDataStore)
local StoreBackend = require(MatchFolder.MatchAndDataService.StoreBackend)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

type Clock = { now: number, waits: { number } }

type Gate = {
	backend: StoreBackend.Backend,
	open: boolean,
	held: { thread },
	writes: number,
	releaseOne: () -> (),
}

local P = Attributes.Player
local SESSION = "job-A"
local OTHER = "job-B"
local START = 1_700_000_000

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local nextUserId = 8800

local function newPlayer(): Player
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "DataSpec" .. nextUserId
	local writable = player :: any
	writable.UserId = nextUserId
	return player
end

local function newClock(): Clock
	return { now = START, waits = {} }
end

local function newStore(backend: StoreBackend.Backend, clock: Clock, sessionId: string?): PlayerDataStore.Store
	return PlayerDataStore.new({
		backend = backend,
		sessionId = sessionId or SESSION,
		now = function(): number
			return clock.now
		end,
		wait = function(seconds: number)
			table.insert(clock.waits, seconds)
			clock.now += seconds
		end,
	})
end

local function stored(backend: StoreBackend.Backend, userId: number): { [string]: any }?
	local ok, value = backend.read(PlayerDataStore.KeyPrefix .. tostring(userId))
	assert(ok, "ephemeral reads never fail")
	return if type(value) == "table" then value :: { [string]: any } else nil
end

-- A backend whose first `failures` requests fail.
local function failing(inner: StoreBackend.Backend, failures: { count: number, calls: number }): StoreBackend.Backend
	return {
		kind = "Live",
		update = function(key: string, transform: StoreBackend.Transform, userIds: { number }?): (boolean, string?)
			failures.calls += 1
			if failures.count > 0 then
				failures.count -= 1
				return false, "503: service unavailable"
			end
			return inner.update(key, transform, userIds)
		end,
		read = inner.read,
	}
end

-- A backend that parks every update while closed (only ever closed around writes made from spawned threads).
local function gated(inner: StoreBackend.Backend): Gate
	local gate = {} :: Gate
	gate.open = true
	gate.held = {}
	gate.writes = 0
	gate.backend = {
		kind = "Live",
		update = function(key: string, transform: StoreBackend.Transform, userIds: { number }?): (boolean, string?)
			if not gate.open then
				table.insert(gate.held, coroutine.running())
				coroutine.yield()
			end
			gate.writes += 1
			return inner.update(key, transform, userIds)
		end,
		read = inner.read,
	}
	function gate.releaseOne()
		local thread = table.remove(gate.held, 1)
		if thread then
			task.spawn(thread)
		end
	end
	return gate
end

local function lockOf(record: { [string]: any }?): { [string]: any }?
	if not record then
		return nil
	end
	local lock = record.lock
	return if type(lock) == "table" then lock :: { [string]: any } else nil
end

local function withCredits(data: Types.PlayerData, credits: number): Types.PlayerData
	local copy = DataMigration.copy(data)
	copy.SurvivalCredits = credits
	return DataMigration.freeze(copy)
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

local spec = {}

spec["DataMigration: defaults, sanitize and validate"] = function(t: Expect)
	local defaults = DataMigration.defaults()
	t.eq(defaults.v, DataMigration.Version)
	t.eq(defaults.SurvivalCredits, 0)
	t.eq(defaults.Escapes, 0)
	t.eq(defaults.LastRunId, "")
	t.eq(DataMigration.validate(defaults), nil, "defaults are valid")

	local clean = DataMigration.sanitize({
		v = 1,
		SurvivalCredits = 12.9,
		Escapes = -3,
		BestTime = { Standard = 300.5, Nightmare = -1, Hard = 10 },
		PerkStock = { RustyScrewdriver = 2, LithiumCell = 0, Jetpack = 4, AdrenalineSyringe = "3" },
		Settings = { MasterVolume = 7, InvertY = true, Bogus = 1, BaseFov = "wide" },
		LastRunId = string.rep("x", 200),
		Extra = "dropped",
	})
	t.eq(clean.SurvivalCredits, 12, "credits are whole")
	t.eq(clean.Escapes, 0, "negative counts clamp to 0")
	t.eq(clean.BestTime.Standard, 300.5)
	t.eq(clean.BestTime.Nightmare, nil, "a non-positive time is dropped")
	t.eq(clean.PerkStock.RustyScrewdriver, 2)
	t.eq(clean.PerkStock.LithiumCell, nil, "zero stock is dropped")
	t.eq(clean.PerkStock.Jetpack, nil, "unknown perks are dropped")
	t.eq(clean.PerkStock.AdrenalineSyringe, nil, "non-numbers are dropped")
	t.eq(clean.Settings.MasterVolume, SettingsSchema.sanitize("MasterVolume", 7), "settings clamp to the schema")
	t.eq(clean.Settings.InvertY, true)
	t.eq(clean.Settings.Bogus, nil)
	t.eq(clean.Settings.BaseFov, nil)
	t.eq(clean.LastRunId, "", "an over-long run id is not a run id")
	t.eq((clean :: any).Extra, nil)
	t.eq(DataMigration.validate(clean), nil)

	local negative = DataMigration.copy(clean)
	negative.SurvivalCredits = -5
	t.truthy(DataMigration.validate(negative), "negative credits are refused")
	local fractional = DataMigration.copy(clean)
	fractional.SurvivalCredits = 2.5
	t.truthy(DataMigration.validate(fractional), "fractional credits are refused")
	local stock = DataMigration.copy(clean)
	stock.PerkStock.Jetpack = 1
	t.truthy(DataMigration.validate(stock), "unknown perks are refused")
	local setting = DataMigration.copy(clean)
	setting.Settings.MasterVolume = 99
	t.truthy(DataMigration.validate(setting), "an out-of-schema setting is refused")
	local zero = DataMigration.copy(clean)
	zero.PerkStock.LithiumCell = 0
	t.eq(DataMigration.validate(zero), nil, "used-up stock (0) is valid")
end

spec["DataMigration: every migrate status"] = function(t: Expect)
	local fresh, status = DataMigration.migrate(nil)
	t.eq(status, "New")
	t.eq(fresh.SurvivalCredits, 0)

	local current, currentStatus = DataMigration.migrate({ v = 1, SurvivalCredits = 40, Escapes = 2 })
	t.eq(currentStatus, "Current")
	t.eq(current.SurvivalCredits, 40)
	t.eq(current.Escapes, 2)

	local legacy, legacyStatus = DataMigration.migrate({ SurvivalCredits = 75, PerkStock = { LithiumCell = 1 } })
	t.eq(legacyStatus, "Migrated", "a record without v is version 0")
	t.eq(legacy.v, DataMigration.Version)
	t.eq(legacy.SurvivalCredits, 75)
	t.eq(legacy.PerkStock.LithiumCell, 1)

	local future, futureStatus =
		DataMigration.migrate({ v = DataMigration.Version + 1, SurvivalCredits = 9, NewThing = 1 })
	t.eq(futureStatus, "Future")
	t.eq(future.SurvivalCredits, 9, "a newer record still shows what this build understands")

	local _, corrupt = DataMigration.migrate("not a record")
	t.eq(corrupt, "Corrupt")
	local _, badVersion = DataMigration.migrate({ v = 0.5 })
	t.eq(badVersion, "Corrupt")
	local _, negativeVersion = DataMigration.migrate({ v = -1 })
	t.eq(negativeVersion, "Corrupt")
end

spec["DataMigration: frozen snapshots and thawed drafts"] = function(t: Expect)
	local data = DataMigration.defaults()
	data.PerkStock.RustyScrewdriver = 1
	local frozen = DataMigration.freeze(data)
	t.truthy(table.isfrozen(frozen) and table.isfrozen(frozen.PerkStock) and table.isfrozen(frozen.BestTime))
	t.throws(function()
		(frozen :: any).SurvivalCredits = 5
	end, "snapshots cannot be changed")
	local draft = DataMigration.copy(frozen)
	t.falsy(table.isfrozen(draft) or table.isfrozen(draft.PerkStock), "drafts are writable")
	draft.PerkStock.RustyScrewdriver = 2
	t.eq(frozen.PerkStock.RustyScrewdriver, 1, "a draft shares nothing with its snapshot")
	t.truthy(DataMigration.equal(DataMigration.copy(frozen), frozen))
	t.falsy(DataMigration.equal(draft, frozen))
end

spec["StoreBackend: the ephemeral backend copies values and cancels on nil"] = function(t: Expect)
	local backend = StoreBackend.ephemeral()
	t.eq(backend.kind, "Ephemeral")
	local value = { n = 1, nested = { a = 1 } }
	t.truthy((backend.update("k", function(current: unknown): unknown
		t.eq(current, nil, "an empty key reads nil")
		return value
	end)))
	value.nested.a = 99
	local _, read = backend.read("k")
	t.eq(((read :: any).nested :: any).a, 1, "the store kept its own copy")
	t.truthy((backend.update("k", function(current: unknown): unknown
		(current :: any).n = 50
		return nil
	end)))
	local _, after = backend.read("k")
	t.eq((after :: any).n, 1, "nil cancels the write, and the transform's copy changed nothing")
	local ok, err = backend.update("k", function(): unknown
		error("boom")
	end)
	t.falsy(ok)
	t.truthy(err and string.find(err, "boom", 1, true), "a failing transform is a failed request")
end

spec["PlayerDataStore: acquire over every stored shape"] = function(t: Expect)
	local stale = PlayerDataStore.StaleLockSeconds
	local record, outcome = PlayerDataStore.acquire(nil, SESSION, START, stale)
	t.eq(outcome, "New")
	t.truthy(record and record.lock and record.lock.jobId == SESSION and record.lock.lockedAt == START)

	local stored0 = { data = { v = 1, SurvivalCredits = 10 }, lock = nil, savedAt = START - 50 }
	local acquired, acquiredOutcome, data = PlayerDataStore.acquire(stored0, SESSION, START, stale)
	t.eq(acquiredOutcome, "Acquired")
	t.eq(data.SurvivalCredits, 10)
	t.truthy(acquired and acquired.lock and acquired.lock.jobId == SESSION)

	local held = { data = { v = 1, SurvivalCredits = 10 }, lock = { jobId = OTHER, lockedAt = START - 30 } }
	local none, lockedOutcome = PlayerDataStore.acquire(held, SESSION, START, stale)
	t.eq(lockedOutcome, "Locked")
	t.eq(none, nil, "a fresh foreign lock is never overwritten")

	local dead = { data = { v = 1, SurvivalCredits = 10 }, lock = { jobId = OTHER, lockedAt = START - stale } }
	local stolen, stolenOutcome = PlayerDataStore.acquire(dead, SESSION, START, stale)
	t.eq(stolenOutcome, "Stolen")
	t.truthy(stolen and stolen.lock and stolen.lock.jobId == SESSION)

	local mine = { data = { v = 1 }, lock = { jobId = SESSION, lockedAt = START - 5 } }
	local _, mineOutcome = PlayerDataStore.acquire(mine, SESSION, START, stale)
	t.eq(mineOutcome, "Acquired", "our own lock (a release that never landed) is ours to take")

	local future = { data = { v = DataMigration.Version + 1, SurvivalCredits = 3 } }
	local noWrite, futureOutcome, view = PlayerDataStore.acquire(future, SESSION, START, stale)
	t.eq(futureOutcome, "Future")
	t.eq(noWrite, nil)
	t.eq(view.SurvivalCredits, 3)
	local _, corruptOutcome = PlayerDataStore.acquire(42, SESSION, START, stale)
	t.eq(corruptOutcome, "Corrupt")
	local _, lockedFirst =
		PlayerDataStore.acquire({ data = "junk", lock = { jobId = OTHER, lockedAt = START } }, SESSION, START, stale)
	t.eq(lockedFirst, "Locked", "a live lock is respected before the data is even read")
	t.truthy(PlayerDataStore.isStale({ jobId = OTHER }, START, stale), "a lock without a time is stale")
	t.eq(PlayerDataStore.lockHolder({ jobId = 5 }), nil)
end

spec["PlayerDataStore: save and release keep to our lock"] = function(t: Expect)
	local data = withCredits(DataMigration.defaults(), 30)
	local ours = { data = { v = 1 }, lock = { jobId = SESSION, lockedAt = START - 100 } }
	local saved, savedOutcome = PlayerDataStore.save(ours, SESSION, data, START, false)
	t.eq(savedOutcome, "Saved")
	t.truthy(saved and saved.data.SurvivalCredits == 30 and saved.lock and saved.lock.lockedAt == START)
	local released, releasedOutcome = PlayerDataStore.save(ours, SESSION, data, START, true)
	t.eq(releasedOutcome, "Released")
	t.truthy(released and released.lock == nil and released.data.SurvivalCredits == 30)

	local theirs = { data = { v = 1 }, lock = { jobId = OTHER, lockedAt = START } }
	local lost, lostOutcome = PlayerDataStore.save(theirs, SESSION, data, START, false)
	t.eq(lostOutcome, "Lost")
	t.eq(lost, nil)
	local _, lostRelease = PlayerDataStore.save(theirs, SESSION, data, START, true)
	t.eq(lostRelease, "Lost", "a release never clears someone else's lock")
	local unlocked = { data = { v = 1 } }
	local _, again = PlayerDataStore.save(unlocked, SESSION, data, START, true)
	t.eq(again, "Released", "a release that finds no lock already landed")
	local _, unlockedSave = PlayerDataStore.save(unlocked, SESSION, data, START, false)
	t.eq(unlockedSave, "Lost", "a save without our lock stops")
	local _, missing = PlayerDataStore.save(nil, SESSION, data, START, false)
	t.eq(missing, "Lost")
end

spec["Store: load locks the record; release saves and unlocks once"] = function(t: Expect)
	local clock = newClock()
	local backend = StoreBackend.ephemeral()
	local store = newStore(backend, clock)
	local session = store:Load(501)
	t.eq(session.state, "Live")
	t.eq(session.data.SurvivalCredits, 0)
	t.truthy(table.isfrozen(session.data))
	local record = stored(backend, 501)
	local lock = lockOf(record)
	t.truthy(lock and lock.jobId == SESSION, "the record is locked to this server")
	t.eq(store:GetSession(501), session)

	clock.now += 30
	t.truthy(store:Commit(session, withCredits(session.data, 25)))
	local afterSave = stored(backend, 501)
	t.eq(afterSave and afterSave.data.SurvivalCredits, 25, "a commit is written")

	clock.now += 30
	t.truthy(store:Commit(session, withCredits(session.data, 40)))
	t.truthy(store:Release(session))
	t.eq(session.state, "Released")
	local final = stored(backend, 501)
	t.eq(final and final.data.SurvivalCredits, 40, "the final snapshot is written on release")
	t.eq(lockOf(final), nil, "release clears the lock")
	t.eq(store:GetSession(501), nil)
	t.truthy(store:Release(session), "a second release is the first one's result")
	t.falsy(store:Commit(session, withCredits(session.data, 99)), "a released session takes no commits")
	t.eq(store:PendingReleases(), 0)
end

spec["Store: saves are serialized, paced and coalesced"] = function(t: Expect)
	local clock = newClock()
	local inner = StoreBackend.ephemeral()
	local gate = gated(inner)
	local store = newStore(gate.backend, clock)
	local session = store:Load(502)
	local loadWrites = gate.writes
	clock.now += 60
	gate.open = false
	store:Commit(session, withCredits(session.data, 1))
	t.truthy(session.saving, "the first save is in flight")
	t.eq(#gate.held, 1)
	store:Commit(session, withCredits(session.data, 2))
	store:Commit(session, withCredits(session.data, 3))
	t.eq(#gate.held, 1, "commits during a write never start a second one")
	t.truthy(session.saveQueued)
	gate.open = true
	gate.releaseOne()
	t.falsy(session.saving, "the queue drained")
	t.eq(gate.writes - loadWrites, 2, "three commits, two writes: the in-flight one and one coalesced")
	local record = stored(inner, 502)
	t.eq(record and record.data.SurvivalCredits, 3, "the coalesced write carries the newest data")
	t.eq(session.savedVersion, session.version)
	local paced = false
	for _, seconds in clock.waits do
		if seconds > 0 and seconds <= PlayerDataStore.MinWriteInterval then
			paced = true
		end
	end
	t.truthy(paced, "the second write waited out the per-key interval")
	store:Release(session)
end

spec["Store: a held lock retries, plays as a guest, then Retry takes it once stale"] = function(t: Expect)
	local clock = newClock()
	local backend = StoreBackend.ephemeral()
	local otherStore = newStore(backend, clock, OTHER)
	local theirs = otherStore:Load(503)
	otherStore:Commit(theirs, withCredits(theirs.data, 70))
	local store = newStore(backend, clock)
	local before = #clock.waits
	local session = store:Load(503)
	t.eq(session.state, "ReadOnly")
	t.eq(session.reason, "Locked")
	t.eq(session.data.SurvivalCredits, 0, "a guest plays on defaults")
	t.eq(#clock.waits - before, #PlayerDataStore.LoadRetryDelays, "every backoff step was waited")
	t.eq(clock.waits[before + 1], PlayerDataStore.LoadRetryDelays[1])
	t.truthy(store:IsHealthy(), "a lock is not a store failure")
	t.falsy(store:Commit(session, withCredits(session.data, 5)), "guests cannot commit")
	t.falsy(store:Retry(session), "still locked")
	clock.now += PlayerDataStore.StaleLockSeconds
	t.truthy(store:Retry(session), "a lock nobody refreshed for StaleLockSeconds is taken")
	t.eq(session.state, "Live")
	t.eq(session.data.SurvivalCredits, 70, "the recovered session has the real data")
	t.eq(otherStore:Commit(theirs, withCredits(theirs.data, 1)), true, "the dead server still thinks it holds it")
	t.eq(theirs.state, "ReadOnly", "but its next write finds the lock taken")
	t.eq(theirs.reason, "Lost")
	local record = stored(backend, 503)
	t.eq(record and record.data.SurvivalCredits, 70, "the stale server wrote nothing over the new session")
	store:Release(session)
end

spec["Store: failing requests back off, then guest data, and health recovers"] = function(t: Expect)
	local clock = newClock()
	local failures = { count = 99, calls = 0 }
	local backend = failing(StoreBackend.ephemeral(), failures)
	local store = newStore(backend, clock)
	local health: { boolean } = {}
	store.HealthChanged:Connect(function(value: boolean)
		table.insert(health, value)
	end)
	local session = store:Load(504)
	t.eq(session.state, "ReadOnly")
	t.eq(session.reason, "Error")
	t.eq(failures.calls, #PlayerDataStore.LoadRetryDelays + 1)
	t.falsy(store:IsHealthy())
	t.eq(health[1], false)
	failures.count = 0
	t.truthy(store:Retry(session), "the store came back")
	t.truthy(store:IsHealthy())
	t.eq(health[2], true)
	failures.count = 1
	clock.now += 60
	store:Commit(session, withCredits(session.data, 12))
	t.eq(session.savedVersion, session.version, "one failure is retried within the save")
	failures.count = 99
	clock.now += 60
	store:Commit(session, withCredits(session.data, 13))
	t.truthy(session.savedVersion < session.version, "a save that kept failing stays dirty")
	t.falsy(store:IsHealthy())
	failures.count = 0
	clock.now += PlayerDataStore.AutosaveSeconds
	t.eq(store:Autosave(), 1, "autosave picks the dirty session up")
	t.eq(session.savedVersion, session.version)
	store:Release(session)
end

spec["Store: a rejoin waits for the release still in flight"] = function(t: Expect)
	local clock = newClock()
	local inner = StoreBackend.ephemeral()
	local gate = gated(inner)
	local store = newStore(gate.backend, clock)
	local first = store:Load(505)
	store:Commit(first, withCredits(first.data, 33))
	gate.open = false
	local released = false
	task.spawn(function()
		store:Release(first)
		released = true
	end)
	t.eq(store:PendingReleases(), 1)
	local second: PlayerDataStore.Session? = nil
	task.spawn(function()
		second = store:Load(505)
	end)
	t.eq(second, nil, "the load waits for the release")
	gate.open = true
	gate.releaseOne()
	t.truthy(released)
	local loaded = second :: PlayerDataStore.Session?
	t.truthy(loaded and loaded.state == "Live", "then it loads")
	t.eq(loaded and loaded.data.SurvivalCredits, 33, "with what the release saved")
	if loaded then
		store:Release(loaded)
	end
end

spec["Store: autosave refreshes the lock; a newer schema is never written"] = function(t: Expect)
	local clock = newClock()
	local backend = StoreBackend.ephemeral()
	local store = newStore(backend, clock)
	local session = store:Load(506)
	t.eq(store:Autosave(), 0, "nothing is due yet")
	clock.now += PlayerDataStore.AutosaveSeconds
	t.eq(store:Autosave(), 1)
	local lock = lockOf(stored(backend, 506))
	t.eq(lock and lock.lockedAt, clock.now, "an autosave without changes still refreshes the lock")
	store:Release(session)

	backend.update(PlayerDataStore.KeyPrefix .. "507", function(): unknown
		return { data = { v = DataMigration.Version + 1, SurvivalCredits = 5, Future = true }, savedAt = START }
	end)
	local future = store:Load(507)
	t.eq(future.state, "ReadOnly")
	t.eq(future.reason, "Future")
	t.falsy(store:Retry(future), "a newer record is not retried")
	store:Release(future)
	local record = stored(backend, 507)
	t.eq(record and record.data.Future, true, "the newer build's fields survive")
	t.eq(lockOf(record), nil, "and the record was never locked")
end

--------------------------------------------------------------------------------
-- MatchAndDataService data API
--------------------------------------------------------------------------------

type Sent = { remote: string, player: Player, payload: any }

local function useStore(store: PlayerDataStore.Store?, sent: { Sent }?)
	MatchAndDataService.SetDependencies({
		store = store,
		now = function(): number
			return 5000
		end,
		present = function(): boolean
			return true
		end,
		send = function(remote: string, player: Player, payload: any)
			if sent then
				table.insert(sent, { remote = remote, player = player, payload = payload })
			end
		end,
	})
end

spec["Service: Update before the load, for guests, and a committed change"] = function(t: Expect)
	local clock = newClock()
	local backend = StoreBackend.ephemeral()
	local store = newStore(backend, clock)
	local sent: { Sent } = {}
	useStore(store, sent)
	local player = newPlayer()
	t.falsy(
		MatchAndDataService.Update(player, "Spec", function(): boolean
			return true
		end),
		"refused before the player is known"
	)
	t.eq(MatchAndDataService.GetData(player), nil)

	local loadedFor: Player? = nil
	local connection = MatchAndDataService.DataLoaded:Connect(function(who: Player)
		loadedFor = who
	end)
	MatchAndDataService.OnPlayerAdded(player)
	connection:Disconnect()
	t.eq(loadedFor, player, "DataLoaded fired")
	t.eq(player:GetAttribute(P.DataLoaded), true)
	t.eq(player:GetAttribute(P.Credits), 0)
	local data = MatchAndDataService.GetData(player)
	t.truthy(data and table.isfrozen(data), "GetData is a frozen snapshot")
	t.truthy(MatchAndDataService.IsWritable(player))

	local events: { { reason: string, before: number, after: number } } = {}
	local watch = MatchAndDataService.Committed:Connect(
		function(_who: Player, reason: string, before: Types.PlayerData, after: Types.PlayerData)
			table.insert(events, { reason = reason, before = before.SurvivalCredits, after = after.SurvivalCredits })
		end
	)
	t.truthy(MatchAndDataService.Update(player, "Spec", function(draft: Types.PlayerData): boolean
		draft.SurvivalCredits += 150
		draft.PerkStock.LithiumCell = 2
		return true
	end))
	watch:Disconnect()
	t.eq(player:GetAttribute(P.Credits), 150, "Credits mirrors the commit")
	local after = MatchAndDataService.GetData(player)
	t.eq(after and after.PerkStock.LithiumCell, 2)
	t.eq(#events, 1)
	t.eq(events[1].reason, "Spec")
	t.eq(events[1].before, 0)
	t.eq(events[1].after, 150)
	t.eq(data and data.SurvivalCredits, 0, "the old snapshot never changes")
	local record = stored(backend, player.UserId)
	t.eq(record and record.data.SurvivalCredits, 150, "the commit was saved")

	MatchAndDataService.OnPlayerRemoving(player)
	t.eq(lockOf(stored(backend, player.UserId)), nil, "leaving releases the record")
	t.falsy(
		MatchAndDataService.Update(player, "Spec", function(): boolean
			return true
		end),
		"refused after leaving"
	)

	-- A guest (the record is locked elsewhere): defaults, read-only, the guest toast.
	local guest = newPlayer()
	local otherStore = newStore(backend, clock, OTHER)
	local theirs = otherStore:Load(guest.UserId)
	otherStore:Commit(theirs, withCredits(theirs.data, 500))
	MatchAndDataService.OnPlayerAdded(guest)
	t.eq(guest:GetAttribute(P.DataLoaded), true, "a guest is ready too (nobody blocks ready-up)")
	t.eq(guest:GetAttribute(P.Credits), 0)
	t.falsy(MatchAndDataService.IsWritable(guest))
	t.falsy(
		MatchAndDataService.Update(guest, "Spec", function(draft: Types.PlayerData): boolean
			draft.SurvivalCredits = 1
			return true
		end),
		"guests are read-only"
	)
	local toasted = false
	for _, entry in sent do
		if entry.player == guest and entry.remote == "Notify" and entry.payload.key == "Boot.DataGuest" then
			toasted = true
		end
	end
	t.truthy(toasted, "the guest is told progress will not save")
	MatchAndDataService.OnPlayerRemoving(guest)
	otherStore:Release(theirs)
	local kept = stored(backend, guest.UserId)
	t.eq(kept and kept.data.SurvivalCredits, 500, "the guest session never touched the real record")
	useStore(nil)
end

spec["Service: discarded mutations"] = function(t: Expect)
	local clock = newClock()
	local backend = StoreBackend.ephemeral()
	useStore(newStore(backend, clock))
	local player = newPlayer()
	MatchAndDataService.OnPlayerAdded(player)
	t.falsy(
		MatchAndDataService.Update(player, "Keep", function(draft: Types.PlayerData): boolean
			draft.SurvivalCredits = 10
			return false
		end),
		"false discards"
	)
	t.falsy(
		MatchAndDataService.Update(player, "Throws", function(draft: Types.PlayerData): boolean
			draft.SurvivalCredits = 10
			if draft.SurvivalCredits > 0 then
				error("purchase failed")
			end
			return true
		end),
		"a throwing mutation is discarded"
	)
	t.falsy(
		MatchAndDataService.Update(player, "Yields", function(draft: Types.PlayerData): boolean
			draft.SurvivalCredits = 10
			coroutine.yield()
			return true
		end),
		"a yielding mutation is discarded"
	)
	t.falsy(
		MatchAndDataService.Update(player, "Invalid", function(draft: Types.PlayerData): boolean
			draft.SurvivalCredits -= GameConfig.CreditsEscapeBonus
			return true
		end),
		"an invalid result (negative credits) is refused, not repaired"
	)
	local data = MatchAndDataService.GetData(player)
	t.eq(data and data.SurvivalCredits, 0, "nothing changed")
	t.eq(player:GetAttribute(P.Credits), 0)
	MatchAndDataService.OnPlayerRemoving(player)
	useStore(nil)
end

spec["Service: settings are sanitized, kept until the load, and sent back as JSON"] = function(t: Expect)
	local blob = MatchAndDataService.sanitizeSettings({ MasterVolume = 5, InvertY = true, Unknown = 3, BaseFov = "x" })
	t.eq(blob.MasterVolume, SettingsSchema.sanitize("MasterVolume", 5))
	t.eq(blob.InvertY, true)
	t.eq(blob.Unknown, nil)
	t.eq(blob.BaseFov, nil)
	t.eq(next(MatchAndDataService.sanitizeSettings("nope")), nil)

	local clock = newClock()
	local backend = StoreBackend.ephemeral()
	local player = newPlayer()
	backend.update(PlayerDataStore.KeyPrefix .. tostring(player.UserId), function(): unknown
		return { data = { v = 1, Settings = { InvertY = true, MasterVolume = 0.5 } }, savedAt = START }
	end)
	useStore(newStore(backend, clock))
	MatchAndDataService.OnPlayerAdded(player)
	local encoded = player:GetAttribute(P.Settings)
	t.eq(type(encoded), "string", "the saved blob is sent back as JSON")
	local decoded = HttpService:JSONDecode(encoded :: string)
	t.eq(decoded.InvertY, true)
	t.eq(decoded.MasterVolume, 0.5)
	MatchAndDataService.SaveSettings(player, { InvertY = false, MasterVolume = 0.5 })
	local changed = MatchAndDataService.GetData(player)
	t.eq(changed and changed.Settings.InvertY, false, "a SettingsSave after the load is committed")
	MatchAndDataService.OnPlayerRemoving(player)
	local record = stored(backend, player.UserId)
	t.eq(record and record.data.Settings.InvertY, false, "and saved")

	-- A blob that arrives while the load is still out is applied once it lands.
	local gate = gated(StoreBackend.ephemeral())
	useStore(newStore(gate.backend, clock))
	local early = newPlayer()
	gate.open = false
	MatchAndDataService.OnPlayerAdded(early)
	t.eq(early:GetAttribute(P.DataLoaded), false, "still loading")
	MatchAndDataService.SaveSettings(early, { InvertY = true })
	t.eq(MatchAndDataService.GetData(early), nil)
	gate.open = true
	gate.releaseOne()
	local loaded = MatchAndDataService.GetData(early)
	t.eq(loaded and loaded.Settings.InvertY, true, "the early blob was saved after the load")
	MatchAndDataService.OnPlayerRemoving(early)
	useStore(nil)
end

return spec
