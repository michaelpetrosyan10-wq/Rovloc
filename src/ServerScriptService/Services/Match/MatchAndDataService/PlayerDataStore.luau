--!strict
-- PlayerDataStore: one record per player behind a StoreBackend, guarded by a session lock, written by one serialized
-- save queue per player. It never loses a committed change it was able to write, never writes over another server's
-- session, and never writes back data it could not fully read.
--
-- Record (the stored value, key "Player_<UserId>"):
--   { data = <PlayerData, plain>, lock = { jobId, lockedAt }?, savedAt }
-- `lock.jobId` is this server's session id (game.JobId; a GUID in Studio, where JobId is empty) and `lockedAt` the
-- wall clock (os.time) of the holder's last write. Every write is one backend update whose transform decides from the
-- stored value alone (pure, so it can run more than once under UpdateAsync contention):
--
--   acquire (Load / Retry)
--     nothing stored                    -> New: the defaults, locked to us
--     another session's lock, fresh     -> Locked: no write (that server is still saving / releasing)
--     another session's lock, stale     -> Stolen: the holder died without releasing (no write for STALE_LOCK_SECONDS,
--                                          i.e. five missed autosaves); the data is migrated and locked to us
--     no lock, or ours                  -> Acquired (migrated by DataMigration)
--     newer schema / corrupt value      -> Future / Corrupt: no write, a read-only view
--   save (queue, autosave)  only while the lock is still ours: data + lock { us, now }; otherwise Lost (no write)
--   release (leave, shutdown)  the final data with the lock cleared; a lock already cleared counts as released
--
-- Sessions. Load(userId) waits for this server's own release of that UserId still in flight (a quick rejoin), then
-- tries to acquire with backoff (LOAD_RETRY_DELAYS). It always returns a session:
--   Live       the lock is ours; Commit(session, data) replaces the data and queues a save
--   ReadOnly   reason Locked / Error (the store kept refusing: guest data, defaults; Retry(session) tries again and
--              turns it Live), Future / Corrupt (a read-only view, never written), Lost (another server took the lock
--              while we held it: saving stops at once, SessionLost fires)
--   Released   after Release
-- Saves are serialized per session: one write in flight, commits during it coalesce into one more write, and writes to
-- a key are at least MIN_WRITE_INTERVAL apart (the DataStore's per-key write limit). Failed writes retry with backoff;
-- what still failed stays dirty for the next autosave. Autosave() writes every Live session that has not been written
-- for AUTOSAVE_SECONDS (refreshing the lock even without changes). Release(session) is idempotent: it stops the queue,
-- waits for the write in flight, then writes the final snapshot with the lock cleared (RELEASE_RETRY_DELAYS); a second
-- call waits for the first. HealthChanged(false) fires when a request still failed after its retries, (true) on the
-- next success.
--
-- Pure rules (tests/Specs/MatchData.spec.luau): acquire, save, lockHolder, isStale. The clock (`now`) and the yield
-- (`wait`) are injected, so specs run every retry and pacing rule on a fake clock.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Util.Log)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Types = require(ReplicatedStorage.Shared.Types)

local DataMigration = require(script.Parent.DataMigration)
local StoreBackend = require(script.Parent.StoreBackend)

local log = Log.new("PlayerData")

export type Lock = { jobId: string, lockedAt: number }

export type Record = { data: { [string]: any }, lock: Lock?, savedAt: number }

export type AcquireOutcome = "New" | "Acquired" | "Stolen" | "Locked" | "Future" | "Corrupt"

export type SaveOutcome = "Saved" | "Released" | "Lost"

export type WriteResult = SaveOutcome | "Error"

export type State = "Live" | "ReadOnly" | "Released"

export type ReadOnlyReason = "Locked" | "Error" | "Future" | "Corrupt" | "Lost"

export type Session = {
	userId: number,
	key: string,
	state: State,
	reason: ReadOnlyReason?,
	data: Types.PlayerData, -- frozen
	version: number, -- bumps on every commit
	savedVersion: number, -- the newest version a write carried
	lastWriteAt: number, -- wall clock of the last write attempt
	saving: boolean,
	saveQueued: boolean,
	releasing: boolean,
	releaseOk: boolean?,
	idle: Signal.Signal<()>,
	released: Signal.Signal<boolean>,
}

export type Options = {
	backend: StoreBackend.Backend,
	sessionId: string,
	now: () -> number, -- wall-clock seconds (os.time) for locks and write pacing
	wait: (seconds: number) -> (), -- yields (task.wait)
	keyPrefix: string?,
	staleLockSeconds: number?,
	minWriteInterval: number?,
	autosaveSeconds: number?,
}

export type Store = {
	backend: StoreBackend.Backend,
	sessionId: string,
	HealthChanged: Signal.Signal<boolean>,
	SessionLost: Signal.Signal<Session>,
	Load: (self: Store, userId: number) -> Session,
	Retry: (self: Store, session: Session) -> boolean,
	Commit: (self: Store, session: Session, data: Types.PlayerData) -> boolean,
	RequestSave: (self: Store, session: Session) -> (),
	Autosave: (self: Store) -> number,
	Release: (self: Store, session: Session) -> boolean,
	WaitForRelease: (self: Store, userId: number, timeout: number) -> boolean,
	PendingReleases: (self: Store) -> number,
	IsHealthy: (self: Store) -> boolean,
	GetSession: (self: Store, userId: number) -> Session?,
}

local KEY_PREFIX = "Player_"
local STALE_LOCK_SECONDS = 600
local MIN_WRITE_INTERVAL = 6
local AUTOSAVE_SECONDS = 120
local RELEASE_WAIT_SECONDS = 30
local IDLE_WAIT_SECONDS = 15
local IDLE_WAITS = 2
local LOAD_RETRY_DELAYS: { number } = { 1, 2, 4, 8 }
local SAVE_RETRY_DELAYS: { number } = { 1, 3 }
local RELEASE_RETRY_DELAYS: { number } = { 1, 2, 4, 8 }

local PlayerDataStore = {}

PlayerDataStore.KeyPrefix = KEY_PREFIX
PlayerDataStore.StaleLockSeconds = STALE_LOCK_SECONDS
PlayerDataStore.MinWriteInterval = MIN_WRITE_INTERVAL
PlayerDataStore.AutosaveSeconds = AUTOSAVE_SECONDS
PlayerDataStore.LoadRetryDelays = table.freeze(table.clone(LOAD_RETRY_DELAYS))
PlayerDataStore.SaveRetryDelays = table.freeze(table.clone(SAVE_RETRY_DELAYS))
PlayerDataStore.ReleaseRetryDelays = table.freeze(table.clone(RELEASE_RETRY_DELAYS))

--------------------------------------------------------------------------------
-- Pure rules
--------------------------------------------------------------------------------

-- The session id holding `lock` (a stored lock value), or nil when there is no well-formed lock.
function PlayerDataStore.lockHolder(lock: unknown): string?
	if type(lock) ~= "table" then
		return nil
	end
	local jobId = (lock :: { [any]: any }).jobId
	return if type(jobId) == "string" then jobId else nil
end

-- Whether `lock` was last refreshed at least `staleSeconds` before `now` (a lock without a time is stale).
function PlayerDataStore.isStale(lock: unknown, now: number, staleSeconds: number): boolean
	if type(lock) ~= "table" then
		return true
	end
	local lockedAt = (lock :: { [any]: any }).lockedAt
	if type(lockedAt) ~= "number" or lockedAt ~= lockedAt then
		return true
	end
	return now - lockedAt >= staleSeconds
end

local function newRecord(data: Types.PlayerData, sessionId: string, now: number, locked: boolean): Record
	return {
		data = DataMigration.copy(data) :: any,
		lock = if locked then { jobId = sessionId, lockedAt = now } else nil,
		savedAt = now,
	}
end

-- The acquire transform: (record to store or nil for no write, outcome, the data the session starts from).
local function acquire(
	current: unknown,
	sessionId: string,
	now: number,
	staleSeconds: number
): (Record?, AcquireOutcome, Types.PlayerData)
	if current == nil then
		local fresh = DataMigration.defaults()
		return newRecord(fresh, sessionId, now, true), "New", fresh
	end
	if type(current) ~= "table" then
		return nil, "Corrupt", DataMigration.defaults()
	end
	local envelope = current :: { [any]: any }
	local holder = PlayerDataStore.lockHolder(envelope.lock)
	local foreign = holder ~= nil and holder ~= sessionId
	if foreign and not PlayerDataStore.isStale(envelope.lock, now, staleSeconds) then
		return nil, "Locked", DataMigration.sanitize(envelope.data)
	end
	local data, status = DataMigration.migrate(envelope.data)
	if status == "Future" or status == "Corrupt" then
		return nil, status, data
	end
	local outcome: AcquireOutcome = if foreign then "Stolen" elseif status == "New" then "New" else "Acquired"
	return newRecord(data, sessionId, now, true), outcome, data
end

PlayerDataStore.acquire = acquire

-- The save / release transform: (record to store or nil for no write, outcome).
local function save(
	current: unknown,
	sessionId: string,
	data: Types.PlayerData,
	now: number,
	release: boolean
): (Record?, SaveOutcome)
	if type(current) ~= "table" then
		return nil, "Lost"
	end
	local holder = PlayerDataStore.lockHolder((current :: { [any]: any }).lock)
	if holder ~= sessionId then
		-- A release that finds no lock at all: an earlier attempt of this release already landed.
		if release and holder == nil then
			return nil, "Released"
		end
		return nil, "Lost"
	end
	local outcome: SaveOutcome = if release then "Released" else "Saved"
	return newRecord(data, sessionId, now, not release), outcome
end

PlayerDataStore.save = save

--------------------------------------------------------------------------------
-- Store
--------------------------------------------------------------------------------

function PlayerDataStore.new(options: Options): Store
	local backend = options.backend
	local sessionId = options.sessionId
	local now = options.now
	local wait = options.wait
	local prefix = options.keyPrefix or KEY_PREFIX
	local staleSeconds = options.staleLockSeconds or STALE_LOCK_SECONDS
	local minInterval = options.minWriteInterval or MIN_WRITE_INTERVAL
	local autosaveSeconds = options.autosaveSeconds or AUTOSAVE_SECONDS

	local healthChanged: Signal.Signal<boolean> = Signal.new()
	local sessionLost: Signal.Signal<Session> = Signal.new()
	local healthy = true
	local sessions: { [number]: Session } = {}
	local releasing: { [number]: Session } = {}
	local pending = 0

	local store = {} :: Store
	store.backend = backend
	store.sessionId = sessionId
	store.HealthChanged = healthChanged
	store.SessionLost = sessionLost

	local function setHealthy(value: boolean)
		if healthy ~= value then
			healthy = value
			healthChanged:Fire(value)
		end
	end

	local function newSession(userId: number, state: State, reason: ReadOnlyReason?, data: Types.PlayerData): Session
		return {
			userId = userId,
			key = prefix .. tostring(userId),
			state = state,
			reason = reason,
			data = DataMigration.freeze(data),
			version = 0,
			savedVersion = 0,
			lastWriteAt = now(),
			saving = false,
			saveQueued = false,
			releasing = false,
			releaseOk = nil,
			idle = Signal.new(),
			released = Signal.new(),
		}
	end

	-- One acquire request: its outcome ("Error" when the request failed) and the data it produced.
	local function attemptAcquire(key: string, userId: number): (AcquireOutcome | "Error", Types.PlayerData?)
		local outcome: AcquireOutcome? = nil
		local loaded: Types.PlayerData? = nil
		local stamp = now()
		local ok, err = backend.update(key, function(current: unknown): unknown
			local record: Record?, verdict: AcquireOutcome, data: Types.PlayerData =
				acquire(current, sessionId, stamp, staleSeconds)
			outcome = verdict
			loaded = data
			return record
		end, { userId })
		local result: AcquireOutcome? = outcome
		if not ok or result == nil then
			log.warn("%s: load request failed: %s", key, tostring(err))
			return "Error", nil
		end
		return result, loaded
	end

	-- One save or release, retried after each of `delays`. "Error" when every attempt failed.
	local function write(session: Session, release: boolean, delays: { number }): WriteResult
		for attempt = 1, #delays + 1 do
			local outcome: SaveOutcome? = nil
			local snapshot = session.data
			local stamp = now()
			local ok, err = backend.update(session.key, function(current: unknown): unknown
				local record: Record?, verdict: SaveOutcome = save(current, sessionId, snapshot, stamp, release)
				outcome = verdict
				return record
			end, { session.userId })
			session.lastWriteAt = now()
			local result: SaveOutcome? = outcome
			if ok and result ~= nil then
				setHealthy(true)
				return result
			end
			log.warn(
				"%s: %s failed (attempt %d of %d): %s",
				session.key,
				if release then "release" else "save",
				attempt,
				#delays + 1,
				tostring(err)
			)
			if attempt <= #delays then
				wait(delays[attempt])
			end
		end
		setHealthy(false)
		return "Error"
	end

	local function lose(session: Session)
		if session.state ~= "Live" then
			return
		end
		session.state = "ReadOnly"
		session.reason = "Lost"
		session.saveQueued = false
		log.error("%s: another server holds the session lock; saving stopped for this session", session.key)
		sessionLost:Fire(session)
	end

	local function runSaves(session: Session)
		session.saving = true
		while session.saveQueued and session.state == "Live" and not session.releasing do
			session.saveQueued = false
			local gap = session.lastWriteAt + minInterval - now()
			if gap > 0 then
				wait(gap)
			end
			if session.state ~= "Live" or session.releasing then
				break
			end
			local version = session.version
			local result = write(session, false, SAVE_RETRY_DELAYS)
			if result == "Saved" then
				session.savedVersion = math.max(session.savedVersion, version)
			elseif result == "Lost" then
				lose(session)
				break
			end
		end
		session.saving = false
		session.idle:Fire()
	end

	local function waitForRelease(userId: number, timeout: number): boolean
		local inFlight = releasing[userId]
		if not inFlight then
			return true
		end
		local fired = inFlight.released:TryWait(timeout)
		return fired
	end

	function store.Load(_self: Store, userId: number): Session
		if not waitForRelease(userId, RELEASE_WAIT_SECONDS) then
			log.warn("%s%d: the previous release is still running; loading anyway", prefix, userId)
		end
		local key = prefix .. tostring(userId)
		local failure: ReadOnlyReason = "Error"
		for attempt = 1, #LOAD_RETRY_DELAYS + 1 do
			local outcome, data = attemptAcquire(key, userId)
			if outcome == "New" or outcome == "Acquired" or outcome == "Stolen" then
				setHealthy(true)
				if outcome == "Stolen" then
					log.warn("%s: took over a stale session lock", key)
				end
				local session = newSession(userId, "Live", nil, data or DataMigration.defaults())
				sessions[userId] = session
				return session
			elseif outcome == "Future" or outcome == "Corrupt" then
				setHealthy(true)
				log.error("%s: stored record is %s; this session is read-only", key, outcome)
				local session = newSession(userId, "ReadOnly", outcome, data or DataMigration.defaults())
				sessions[userId] = session
				return session
			end
			if outcome == "Locked" then
				setHealthy(true)
				failure = "Locked"
			else
				failure = "Error"
			end
			if attempt <= #LOAD_RETRY_DELAYS then
				wait(LOAD_RETRY_DELAYS[attempt])
			end
		end
		if failure == "Error" then
			setHealthy(false)
		end
		log.warn("%s: could not acquire (%s); playing on guest data", key, failure)
		local session = newSession(userId, "ReadOnly", failure, DataMigration.defaults())
		sessions[userId] = session
		return session
	end

	function store.Retry(_self: Store, session: Session): boolean
		if session.state ~= "ReadOnly" or session.releasing then
			return false
		end
		if session.reason ~= "Locked" and session.reason ~= "Error" then
			return false
		end
		local outcome, data = attemptAcquire(session.key, session.userId)
		if session.state ~= "ReadOnly" or session.releasing then
			-- Released (the player left) while the request was out: give back what was just taken.
			if outcome == "New" or outcome == "Acquired" or outcome == "Stolen" then
				local stamp = now()
				backend.update(session.key, function(current: unknown): unknown
					local record = save(current, sessionId, data or DataMigration.defaults(), stamp, true)
					return record
				end, { session.userId })
			end
			return false
		end
		if outcome == "New" or outcome == "Acquired" or outcome == "Stolen" then
			setHealthy(true)
			session.state = "Live"
			session.reason = nil
			session.data = DataMigration.freeze(data or DataMigration.defaults())
			session.version += 1
			session.savedVersion = session.version
			session.lastWriteAt = now()
			log.info("%s: recovered from guest mode", session.key)
			return true
		elseif outcome == "Future" or outcome == "Corrupt" then
			setHealthy(true)
			session.reason = outcome
			session.data = DataMigration.freeze(data or DataMigration.defaults())
		elseif outcome == "Locked" then
			setHealthy(true)
			session.reason = "Locked"
		end
		return false
	end

	function store.RequestSave(_self: Store, session: Session)
		if session.state ~= "Live" or session.releasing then
			return
		end
		session.saveQueued = true
		if not session.saving then
			task.spawn(runSaves, session)
		end
	end

	function store.Commit(self: Store, session: Session, data: Types.PlayerData): boolean
		if session.state ~= "Live" or session.releasing then
			return false
		end
		session.data = if table.isfrozen(data) then data else DataMigration.freeze(data)
		session.version += 1
		self:RequestSave(session)
		return true
	end

	function store.Autosave(self: Store): number
		local stamp = now()
		local queued = 0
		for _, session in sessions do
			if
				session.state == "Live"
				and not session.releasing
				and not session.saving
				and stamp - session.lastWriteAt >= autosaveSeconds
			then
				self:RequestSave(session)
				queued += 1
			end
		end
		return queued
	end

	function store.Release(_self: Store, session: Session): boolean
		if session.state == "Released" then
			return session.releaseOk == true
		end
		if session.releasing then
			local fired, ok = session.released:TryWait(RELEASE_WAIT_SECONDS)
			return fired and ok == true
		end
		session.releasing = true
		session.saveQueued = false
		pending += 1
		releasing[session.userId] = session
		local ok = true
		-- The write in flight finishes first (bounded: a request that never answers must not hold the release; its
		-- transform would then find the lock cleared and write nothing).
		local waits = 0
		while session.state == "Live" and session.saving and waits < IDLE_WAITS do
			session.idle:TryWait(IDLE_WAIT_SECONDS)
			waits += 1
		end
		if session.state == "Live" then
			local result = write(session, true, RELEASE_RETRY_DELAYS)
			if result == "Lost" then
				ok = false
				log.error(
					"%s: the lock was taken before the final save; this session's last changes were dropped",
					session.key
				)
			elseif result == "Error" then
				ok = false
				log.error("%s: the final save failed; changes since the last save are lost", session.key)
			end
		end
		session.state = "Released"
		session.releaseOk = ok
		session.releasing = false
		if sessions[session.userId] == session then
			sessions[session.userId] = nil
		end
		if releasing[session.userId] == session then
			releasing[session.userId] = nil
		end
		pending -= 1
		session.released:Fire(ok)
		return ok
	end

	function store.WaitForRelease(_self: Store, userId: number, timeout: number): boolean
		return waitForRelease(userId, timeout)
	end

	function store.PendingReleases(_self: Store): number
		return pending
	end

	function store.IsHealthy(_self: Store): boolean
		return healthy
	end

	function store.GetSession(_self: Store, userId: number): Session?
		return sessions[userId]
	end

	return store
end

return table.freeze(PlayerDataStore)
