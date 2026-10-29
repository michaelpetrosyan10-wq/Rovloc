--!strict
-- MatchAndDataService: saved progress and the match policy (spec §1, ARCHITECTURE §5 and §6d).
--
-- The only writer of every PlayerData field and of the Player attributes DataLoaded, Credits, RunOutcome and Settings
-- (the saved blob, written once per load), and of ReplicatedStorage DataMode. LobbyService, PerkShopService,
-- MatchResetService and TelemetryService require it; it requires none of them. Levels signal upward: Level 5's
-- `Escaped` is subscribed through `Levels.Level5` when that controller exists.
--
-- Data.
--   * Backend (StoreBackend.choose, in Start): the DataStore on live servers; in Studio without API access and in the
--     Lune harness an in-memory Ephemeral backend with the same semantics (DataMode "Ephemeral", the HUD's banner).
--   * Each joining player's record is loaded through PlayerDataStore (session lock, migrations, retries). A player
--     whose record cannot be taken (the store keeps failing, or another server still holds the lock) plays on guest
--     data: defaults, read-only, no rewards, Notify "Boot.DataGuest"; the load is retried every GUEST_RETRY_SECONDS and
--     a recovered player gets their real data (DataLoaded fires again). Records from a newer build or corrupt values
--     are read-only for the whole session (never written back). DataMode turns "Guest" while the store is failing.
--   * Ready: Credits mirrors SurvivalCredits, Settings carries the saved blob as JSON (SettingsController reads it
--     once), DataLoaded = true, then the DataLoaded signal.
--   * GetData returns a deep-frozen snapshot. Update(player, reason, mutate) hands `mutate` a draft copy; true commits
--     it (validated by DataMigration.validate, so a bad mutation is refused rather than repaired), mirrors Credits,
--     fires Committed(player, reason, before, after) and queues a save; false discards it. Refused (false) before the
--     load, for read-only data, while the session is being released, when `mutate` throws or yields.
--   * SettingsSave: the blob is sanitized against SettingsSchema and saved (kept until the load when it arrives first).
--   * Saving: PlayerDataStore's serialized queue (one write in flight per player, pacing, retries), autosave every
--     120 s, release on leave; BindToClose releases everyone still here and waits up to CLOSE_DEADLINE_SECONDS.
--
-- Match policy (DevToolsService.SetMatchPolicyPresent(true): the Studio auto dev run stays off; the dev panel's Dev Run
-- still works).
--   * Deploy(participants, difficulty) (LobbyService, at the end of its countdown): refused while a run exists or
--     away from Lobby / Countdown. For every participant (present, de-duplicated, at most GameConfig.MaxSquad) one
--     stock unit of each equipped perk (Player.Loadout) is consumed in one Update; perks with no stock are dropped
--     from the loadout (LoadoutService.SetLoadout; PerkShopService keeps loadouts stocked in the lobby, so this only
--     bites after the `loadout` dev command). Then RunLifecycleService.BeginRun, and the squad goes into Level 0 the
--     way the dev run sends it (DevToolsService.SpawnSquad: a PlayerSpawn slot each, once their client holds the world).
--   * Outcomes per participant: Pending -> Escaped (Level5.Escaped, or the `escape` dev command) / Disconnected (left)
--     / Dead (anything else once the run resolves). RunOutcome mirrors them.
--   * One RunOutcomeEvaluator, coalesced with task.defer, runs on every LifeState change, escape, leave and on
--     entering InRun: `verdict` -> Wipe when no participant is Alive and none is Downed with a syringe charge left
--     (and nobody escaped), Escape when the same holds with at least one escape, else Continue. An empty run is never
--     judged.
--   * Resolution: RunEnded, then each participant is settled once: CreditsPerLevelCleared x the floors they sealed
--     (RunStats FloorsCleared, written by CheckpointAirlockService for the survivors of each airlock) + CreditsEscapeBonus
--     when they escaped, Escapes + 1 and BestTime[difficulty] (their own escape time) when they escaped. One atomic
--     Update guarded by LastRunId, so a run never pays twice; nothing for a DevRun (ReplicatedStorage.DevRun) or
--     read-only data. RunStats CreditsEarned records what was paid. A participant who leaves first is settled as they
--     leave. Then RunSummary to every participant still here, RunResolved(outcomes), and the Results phase
--     (MatchResetService takes it from there).
--   * FloorCleared: survivors are told the floor's credits (Notify "Checkpoint.Reached"), paid when the run resolves.
--
-- Dev commands: escape [player] (count them escaped), credits <amount> (set your SurvivalCredits), data [player]
-- (read-only: what is saved, the data mode).
--
-- Specs (tests/Specs/MatchData.spec.luau, MatchFlow.spec.luau): the pure rules verdict, rewardFor, applyReward,
-- sanitizeSettings, squadFrom; SetDependencies swaps the store, the clock, the run, life states, stats, the senders
-- and the spawner, so a whole deploy -> resolution runs on a fake clock without Players or Net.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local PerkConfig = require(ReplicatedStorage.Shared.Config.PerkConfig)
local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local LoadoutService = require(ServerScriptService.Services.Player.LoadoutService)
local CheckpointAirlockService = require(ServerScriptService.Services.Match.CheckpointAirlockService)
local Levels = require(ServerScriptService.Services.Levels)

local DataMigration = require(script.DataMigration)
local PlayerDataStore = require(script.PlayerDataStore)
local StoreBackend = require(script.StoreBackend)

local log = Log.new("MatchData")

local P = Attributes.Player
local M = Attributes.Match

export type Verdict = "Continue" | "Wipe" | "Escape"

-- One participant as the evaluator sees them.
export type Standing = {
	escaped: boolean,
	disconnected: boolean,
	lifeState: Enums.LifeState,
	syringeCharges: number,
}

export type Reward = {
	runId: string,
	credits: number,
	escaped: boolean,
	difficulty: Enums.Difficulty,
	time: number?, -- the escape time (seconds from the run's start) for BestTime
}

export type RewardResult = { applied: boolean, newBest: boolean }

-- Everything the service touches outside itself (nil fields use the real services).
export type Dependencies = {
	now: (() -> number)?, -- server time (run timing, escape times, guest retries)
	phase: (() -> Enums.MatchPhase)?,
	setPhase: ((phase: Enums.MatchPhase) -> boolean)?,
	run: (() -> Types.RunContext?)?,
	beginRun: ((participants: { Player }, difficulty: Enums.Difficulty) -> Types.RunContext)?,
	lifeState: ((player: Player) -> Enums.LifeState)?,
	syringeCharges: ((player: Player) -> number)?,
	floorsCleared: ((player: Player) -> number)?,
	stats: ((player: Player) -> { [string]: number })?,
	addStat: ((player: Player, key: Enums.StatKey, amount: number) -> ())?,
	runSeconds: (() -> number)?,
	devRun: (() -> boolean)?,
	present: ((player: Player) -> boolean)?,
	send: ((remote: string, player: Player, payload: any) -> ())?,
	setLoadout: ((player: Player, perks: { Enums.PerkId }) -> ())?,
	spawn: ((players: { Player }) -> ())?,
	defer: ((fn: () -> ()) -> ())?,
	store: PlayerDataStore.Store?,
}

type Entry = {
	player: Player,
	session: PlayerDataStore.Session?,
	loaded: boolean,
	leaving: boolean,
	retrying: boolean,
	retryAt: number,
	pendingSettings: Types.SettingsBlob?,
}

type RunState = {
	ctx: Types.RunContext,
	outcomes: { [Player]: Enums.RunOutcome },
	escapedAt: { [Player]: number },
	settled: { [Player]: boolean },
	resolved: boolean,
	scheduled: boolean,
}

type EscapeSource = { Escaped: Signal.Signal<Player> }

local STORE_NAME = "RovlocPlayers"
local GUEST_RETRY_SECONDS = 30
local POLL_SECONDS = 1
local CLOSE_DEADLINE_SECONDS = 25
local CLOSE_POLL_SECONDS = 0.1
local BEST_TIME_PRECISION = 100 -- BestTime is kept to the hundredth of a second

local GUEST_KEY = "Boot.DataGuest"
local CHECKPOINT_KEY = "Checkpoint.Reached"
local CREDITS_STAT: Enums.StatKey = "CreditsEarned"
local FLOORS_STAT: Enums.StatKey = "FloorsCleared"
local REWARD_REASON = "RunReward"
local DEPLOY_REASON = "Deploy"
local SETTINGS_REASON = "Settings"
local DEV_REASON = "Dev"

local MatchAndDataService = {}

MatchAndDataService.Name = "MatchAndDataService"
MatchAndDataService.StoreName = STORE_NAME
MatchAndDataService.GuestRetrySeconds = GUEST_RETRY_SECONDS
MatchAndDataService.CloseDeadlineSeconds = CLOSE_DEADLINE_SECONDS

local dataLoaded: Signal.Signal<Player> = Signal.new()
local runResolved: Signal.Signal<{ [Player]: Enums.RunOutcome }> = Signal.new()
local playerEscaped: Signal.Signal<Player> = Signal.new()
local committed: Signal.Signal<Player, string, Types.PlayerData, Types.PlayerData> = Signal.new()

-- (player) once their data is ready (live or read-only guest data); again if a guest's real data is recovered.
MatchAndDataService.DataLoaded = dataLoaded
-- (outcomes) once per run, after the rewards and RunSummary, before the Results phase.
MatchAndDataService.RunResolved = runResolved
-- (player) the moment a participant escapes (before the run resolves).
MatchAndDataService.PlayerEscaped = playerEscaped
-- (player, reason, before, after) after every committed Update.
MatchAndDataService.Committed = committed

local deps: Dependencies = {}
local serviceTrove = Trove.new()
local storeTrove = serviceTrove:Extend()
local liveStore: PlayerDataStore.Store? = nil
local storeReady: Signal.Signal<()> = Signal.new()
local entries: { [Player]: Entry } = {}
local runState: RunState? = nil
local deploying = false
local loading = 0 -- loads in flight (BindToClose waits for them: a finished load holds a lock to release)
local initialized = false
local pollAccumulated = 0

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/MatchFlow.spec.luau, MatchData.spec.luau)
--------------------------------------------------------------------------------

-- The evaluator's call on the participants (see the header).
local function verdictOf(standings: { Standing }): Verdict
	if #standings == 0 then
		return "Continue"
	end
	local escaped = 0
	for _, standing in standings do
		if standing.escaped then
			escaped += 1
		elseif not standing.disconnected then
			if standing.lifeState == "Alive" then
				return "Continue"
			end
			if standing.lifeState == "Downed" and standing.syringeCharges > 0 then
				return "Continue"
			end
		end
	end
	return if escaped > 0 then "Escape" else "Wipe"
end

MatchAndDataService.verdict = verdictOf

-- Credits a participant earns: per floor they sealed, plus the escape bonus.
function MatchAndDataService.rewardFor(escaped: boolean, floorsCleared: number): number
	local floors = if floorsCleared == floorsCleared then math.max(0, math.floor(floorsCleared)) else 0
	return GameConfig.CreditsPerLevelCleared * floors + (if escaped then GameConfig.CreditsEscapeBonus else 0)
end

local function bestOf(times: { Standard: number?, Nightmare: number? }, difficulty: Enums.Difficulty): number?
	return if difficulty == "Nightmare" then times.Nightmare else times.Standard
end

local function setBest(times: { Standard: number?, Nightmare: number? }, difficulty: Enums.Difficulty, time: number)
	if difficulty == "Nightmare" then
		times.Nightmare = time
	else
		times.Standard = time
	end
end

-- Applies `reward` to a data draft unless this run already paid (LastRunId). Never yields.
function MatchAndDataService.applyReward(data: Types.PlayerData, reward: Reward): RewardResult
	local runId = string.sub(reward.runId, 1, DataMigration.MaxRunIdLength)
	if runId == "" or data.LastRunId == runId then
		return { applied = false, newBest = false }
	end
	data.SurvivalCredits = math.min(data.SurvivalCredits + math.max(0, reward.credits), DataMigration.MaxCredits)
	local newBest = false
	if reward.escaped then
		data.Escapes += 1
		local time = reward.time
		if time and time == time and time > 0 then
			local rounded =
				math.max(1 / BEST_TIME_PRECISION, math.round(time * BEST_TIME_PRECISION) / BEST_TIME_PRECISION)
			local best = bestOf(data.BestTime, reward.difficulty)
			if best == nil or rounded < best then
				setBest(data.BestTime, reward.difficulty, rounded)
				newBest = true
			end
		end
	end
	data.LastRunId = runId
	return { applied = true, newBest = newBest }
end

-- A SettingsSave blob reduced to schema keys with sanitized values.
function MatchAndDataService.sanitizeSettings(raw: unknown): Types.SettingsBlob
	local out: Types.SettingsBlob = {}
	if type(raw) ~= "table" then
		return out
	end
	local source = raw :: { [any]: any }
	for _, setting in SettingsSchema.List do
		local clean = SettingsSchema.sanitize(setting.key, source[setting.key])
		if clean ~= nil then
			out[setting.key] = clean
		end
	end
	return out
end

-- The squad Deploy runs with: present players, each once, in order, at most GameConfig.MaxSquad.
function MatchAndDataService.squadFrom(participants: { Player }, isPresent: (player: Player) -> boolean): { Player }
	local squad: { Player } = {}
	for _, player in participants do
		if #squad >= GameConfig.MaxSquad then
			break
		end
		if isPresent(player) and table.find(squad, player) == nil then
			table.insert(squad, player)
		end
	end
	return squad
end

--------------------------------------------------------------------------------
-- Dependencies
--------------------------------------------------------------------------------

local function now(): number
	local fake = deps.now
	return if fake then fake() else Workspace:GetServerTimeNow()
end

local function currentPhase(): Enums.MatchPhase
	local fake = deps.phase
	return if fake then fake() else RunLifecycleService.GetPhase()
end

local function setPhase(phase: Enums.MatchPhase): boolean
	local fake = deps.setPhase
	return if fake then fake(phase) else RunLifecycleService.SetPhase(phase)
end

local function currentRun(): Types.RunContext?
	local fake = deps.run
	return if fake then fake() else RunLifecycleService.GetRun()
end

local function beginRun(participants: { Player }, difficulty: Enums.Difficulty): Types.RunContext
	local fake = deps.beginRun
	return if fake then fake(participants, difficulty) else RunLifecycleService.BeginRun(participants, difficulty)
end

local function lifeStateOf(player: Player): Enums.LifeState
	local fake = deps.lifeState
	return if fake then fake(player) else LifeStateService.GetState(player)
end

local function syringeChargesOf(player: Player): number
	local fake = deps.syringeCharges
	return if fake then fake(player) else LoadoutService.GetSyringeCharges(player)
end

local function floorsClearedBy(player: Player): number
	local fake = deps.floorsCleared
	return if fake then fake(player) else RunStatsService.Get(player, FLOORS_STAT)
end

local function statsOf(player: Player): { [string]: number }
	local fake = deps.stats
	return if fake then fake(player) else RunStatsService.Snapshot(player)
end

local function addStat(player: Player, key: Enums.StatKey, amount: number)
	local fake = deps.addStat
	if fake then
		fake(player, key, amount)
	else
		RunStatsService.Increment(player, key, amount)
	end
end

local function runSeconds(): number
	local fake = deps.runSeconds
	return if fake then fake() else RunStatsService.RunSeconds()
end

local function isDevRun(): boolean
	local fake = deps.devRun
	if fake then
		return fake()
	end
	return ReplicatedStorage:GetAttribute(M.DevRun) == true
end

local function isPresent(player: Player): boolean
	local fake = deps.present
	return if fake then fake(player) else player.Parent == Players
end

local function send(remote: string, player: Player, payload: any)
	local fake = deps.send
	if fake then
		fake(remote, player, payload)
		return
	end
	if player.Parent == Players then
		Net.Server.fire(remote, player, payload)
	end
end

local function notify(player: Player, key: string, args: { string }?)
	local payload: Types.NotifyPayload = { key = key, args = args or {} }
	send("Notify", player, payload)
end

local function setLoadout(player: Player, perks: { Enums.PerkId })
	local fake = deps.setLoadout
	if fake then
		fake(player, perks)
	else
		LoadoutService.SetLoadout(player, perks)
	end
end

-- The squad into Level 0 exactly as the dev run does (DevToolsService.SpawnSquad: slot = index, once each client
-- holds the world).
local function spawnSquad(players: { Player })
	local fake = deps.spawn
	if fake then
		fake(players)
	else
		DevToolsService.SpawnSquad(players, Enums.LevelId[1])
	end
end

local function defer(fn: () -> ())
	local fake = deps.defer
	if fake then
		fake(fn)
	else
		task.defer(fn)
	end
end

local function currentStore(): PlayerDataStore.Store?
	return deps.store or liveStore
end

local function waitForStore(): PlayerDataStore.Store
	while true do
		local store = currentStore()
		if store then
			return store
		end
		storeReady:Wait()
	end
end

--------------------------------------------------------------------------------
-- Data
--------------------------------------------------------------------------------

local function refreshDataMode()
	local store = currentStore()
	if not store then
		return
	end
	local mode: Enums.DataMode = if store.backend.kind == "Ephemeral"
		then "Ephemeral"
		elseif store:IsHealthy() then "Live"
		else "Guest"
	Attributes.set(ReplicatedStorage, M.DataMode, mode)
end

-- Mirrors `data` onto the player's attributes (the saved settings blob only on a load).
local function publish(player: Player, data: Types.PlayerData, withSettings: boolean)
	Attributes.set(player, P.Credits, data.SurvivalCredits)
	if withSettings then
		local ok, encoded = pcall(function(): string
			return HttpService:JSONEncode(data.Settings)
		end)
		if ok then
			Attributes.set(player, P.Settings, encoded)
		else
			log.warn("%s: settings blob could not be encoded: %s", player.Name, tostring(encoded))
		end
	end
	Attributes.set(player, P.DataLoaded, true)
end

local function entryOf(session: PlayerDataStore.Session): Entry?
	for _, entry in entries do
		if entry.session == session then
			return entry
		end
	end
	return nil
end

local function bindStore(store: PlayerDataStore.Store?)
	storeTrove:Clean()
	if not store then
		return
	end
	storeTrove:Add(store.HealthChanged:Connect(function()
		refreshDataMode()
	end))
	storeTrove:Add(store.SessionLost:Connect(function(session: PlayerDataStore.Session)
		local entry = entryOf(session)
		if entry and not entry.leaving then
			notify(entry.player, GUEST_KEY)
		end
		refreshDataMode()
	end))
end

-- Runs `mutate` on `draft` in its own coroutine: (true, keep) when it returned, (false) when it threw or yielded.
local function runMutate(
	reason: string,
	mutate: (data: Types.PlayerData) -> boolean,
	draft: Types.PlayerData
): (boolean, boolean)
	local thread = coroutine.create(mutate)
	local ok, result = coroutine.resume(thread, draft)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		log.error("Update(%s): mutate yielded; the change was discarded", reason)
		return false, false
	end
	if not ok then
		log.error("Update(%s): mutate failed: %s", reason, tostring(result))
		return false, false
	end
	return true, result == true
end

-- `player`'s data: a frozen snapshot, or nil until it has loaded.
function MatchAndDataService.GetData(player: Player): Types.PlayerData?
	local entry = entries[player]
	local session = if entry and entry.loaded then entry.session else nil
	return if session then session.data else nil
end

-- Whether Update can commit for `player` (loaded, live, not leaving).
function MatchAndDataService.IsWritable(player: Player): boolean
	local entry = entries[player]
	local session = if entry and entry.loaded then entry.session else nil
	return session ~= nil and session.state == "Live" and not session.releasing and not entry.leaving
end

-- The atomic edit of `player`'s data (see the header). Never yields.
function MatchAndDataService.Update(
	player: Player,
	reason: string,
	mutate: (data: Types.PlayerData) -> boolean
): boolean
	local entry = entries[player]
	local session = if entry and entry.loaded then entry.session else nil
	local store = currentStore()
	if not entry or not session or not store or session.state ~= "Live" or session.releasing then
		return false
	end
	local before = session.data
	local draft = DataMigration.copy(before)
	local ok, keep = runMutate(reason, mutate, draft)
	if not ok or not keep then
		return false
	end
	local problem = DataMigration.validate(draft)
	if problem then
		log.error("Update(%s) for %s refused: %s", reason, player.Name, problem)
		return false
	end
	local after = DataMigration.freeze(draft)
	if not store:Commit(session, after) then
		return false
	end
	publish(player, after, false)
	committed:Fire(player, reason, before, after)
	return true
end

-- The data mode this server shows (nil before the backend was chosen).
function MatchAndDataService.GetDataMode(): Enums.DataMode?
	local mode = ReplicatedStorage:GetAttribute(M.DataMode)
	return if Enums.has(Enums.DataMode, mode) then (mode :: any) :: Enums.DataMode else nil
end

local function applySettings(player: Player, blob: Types.SettingsBlob)
	MatchAndDataService.Update(player, SETTINGS_REASON, function(data: Types.PlayerData): boolean
		if DataMigration.equal(data.Settings, blob) then
			return false
		end
		data.Settings = table.clone(blob)
		return true
	end)
end

local function finishLoad(entry: Entry, session: PlayerDataStore.Session)
	local player = entry.player
	entry.session = session
	entry.loaded = true
	entry.retryAt = now() + GUEST_RETRY_SECONDS
	local settings = entry.pendingSettings
	entry.pendingSettings = nil
	if settings and session.state == "Live" then
		applySettings(player, settings)
	end
	publish(player, session.data, true)
	if session.state ~= "Live" then
		notify(player, GUEST_KEY)
	end
	log.info("%s data ready (%s%s)", player.Name, session.state, if session.reason then ", " .. session.reason else "")
	dataLoaded:Fire(player)
	refreshDataMode()
end

-- Starts loading `player`'s data (PlayerAdded; specs call it directly). The load runs in its own thread.
function MatchAndDataService.OnPlayerAdded(player: Player)
	if entries[player] then
		return
	end
	local entry: Entry = {
		player = player,
		session = nil,
		loaded = false,
		leaving = false,
		retrying = false,
		retryAt = math.huge,
		pendingSettings = nil,
	}
	entries[player] = entry
	Attributes.set(player, P.DataLoaded, false)
	loading += 1
	task.spawn(function()
		local store = waitForStore()
		xpcall(function()
			local session = store:Load(player.UserId)
			if entry.leaving or entries[player] ~= entry then
				store:Release(session)
				return
			end
			finishLoad(entry, session)
		end, function(err: any)
			log.error("%s: data load failed: %s\n%s", player.Name, tostring(err), debug.traceback())
		end)
		loading -= 1
	end)
end

-- SettingsSave's body: the sanitized blob is saved now, or kept until the player's data has loaded.
function MatchAndDataService.SaveSettings(player: Player, settings: unknown)
	local blob = MatchAndDataService.sanitizeSettings(settings)
	local entry = entries[player]
	if not entry then
		return
	end
	if not entry.loaded then
		entry.pendingSettings = blob
		return
	end
	applySettings(player, blob)
end

local function onSettingsSave(player: Player, payload: any)
	local message = payload :: Types.SettingsSavePayload
	MatchAndDataService.SaveSettings(player, message.settings)
end

-- Autosave and guest retries (once a second on Heartbeat; specs call it directly).
function MatchAndDataService.Poll()
	local store = currentStore()
	if not store then
		return
	end
	store:Autosave()
	local stamp = now()
	for player, entry in entries do
		local session = entry.session
		if
			not session
			or entry.retrying
			or entry.leaving
			or session.state ~= "ReadOnly"
			or (session.reason ~= "Locked" and session.reason ~= "Error")
			or stamp < entry.retryAt
		then
			continue
		end
		entry.retrying = true
		entry.retryAt = stamp + GUEST_RETRY_SECONDS
		task.spawn(function()
			local recovered = store:Retry(session)
			entry.retrying = false
			if recovered and entries[player] == entry and not entry.leaving then
				publish(player, session.data, true)
				log.info("%s recovered their saved data", player.Name)
				dataLoaded:Fire(player)
			end
			refreshDataMode()
		end)
	end
end

--------------------------------------------------------------------------------
-- Match policy
--------------------------------------------------------------------------------

local function participates(state: RunState, player: Player): boolean
	return table.find(state.ctx.participants, player) ~= nil
end

local function writeOutcome(player: Player, outcome: Enums.RunOutcome)
	if isPresent(player) then
		Attributes.set(player, P.RunOutcome, outcome)
	end
end

-- `player`'s outcome in the current run ("Pending" outside one or for non-participants).
function MatchAndDataService.GetOutcome(player: Player): Enums.RunOutcome
	local state = runState
	return if state then state.outcomes[player] or "Pending" else "Pending"
end

type Settlement = {
	credits: number,
	saved: boolean,
	newBest: boolean,
	runSeconds: number,
	floors: number,
}

-- Pays `player` for the run once (LastRunId guards the data as well) and returns what happened.
local function settle(state: RunState, player: Player, devRun: boolean): Settlement
	state.settled[player] = true
	local escaped = state.outcomes[player] == "Escaped"
	local escapedAt = state.escapedAt[player]
	local seconds = if escaped and escapedAt then math.max(0, escapedAt - state.ctx.startedAt) else runSeconds()
	local floors = floorsClearedBy(player)
	local credits = MatchAndDataService.rewardFor(escaped, floors)
	local result: Settlement = { credits = 0, saved = false, newBest = false, runSeconds = seconds, floors = floors }
	if devRun or not MatchAndDataService.IsWritable(player) then
		return result
	end
	if credits <= 0 and not escaped then
		result.saved = true
		return result
	end
	local reward: Reward = {
		runId = state.ctx.runId,
		credits = credits,
		escaped = escaped,
		difficulty = state.ctx.difficulty,
		time = if escaped then seconds else nil,
	}
	local applied = false
	local newBest = false
	local ok = MatchAndDataService.Update(player, REWARD_REASON, function(data: Types.PlayerData): boolean
		local outcome = MatchAndDataService.applyReward(data, reward)
		applied = outcome.applied
		newBest = outcome.newBest
		return outcome.applied
	end)
	if ok and applied then
		result.credits = credits
		result.saved = true
		result.newBest = newBest
		addStat(player, CREDITS_STAT, credits)
		log.info("%s earned %d credits (%s)", player.Name, credits, if escaped then "escaped" else "floors")
	end
	return result
end

local function summaryFor(
	state: RunState,
	player: Player,
	settlement: Settlement,
	escapees: number
): Types.RunSummaryPayload
	local data = MatchAndDataService.GetData(player)
	return {
		outcome = state.outcomes[player] or "Dead",
		runSeconds = settlement.runSeconds,
		creditsEarned = settlement.credits,
		bestTime = if data then bestOf(data.BestTime, state.ctx.difficulty) else nil,
		stats = statsOf(player),
		levelsCleared = settlement.floors,
		difficulty = state.ctx.difficulty,
		escapees = escapees,
		squadSize = #state.ctx.participants,
		newBest = settlement.newBest,
		saved = settlement.saved,
	}
end

local function resolve(state: RunState, verdict: Verdict)
	state.resolved = true
	local escapees = 0
	for _, player in state.ctx.participants do
		local outcome: Enums.RunOutcome = state.outcomes[player] or "Pending"
		if outcome == "Pending" then
			outcome = "Dead"
			state.outcomes[player] = outcome
		end
		if outcome == "Escaped" then
			escapees += 1
		end
		writeOutcome(player, outcome)
	end
	log.info("run %s resolved: %s (%d of %d escaped)", state.ctx.runId, verdict, escapees, #state.ctx.participants)
	if not setPhase("RunEnded") then
		log.warn("run %s resolved outside InRun (%s)", state.ctx.runId, currentPhase())
	end
	local devRun = isDevRun()
	for _, player in state.ctx.participants do
		if state.settled[player] then
			continue
		end
		local settlement = settle(state, player, devRun)
		if isPresent(player) then
			send("RunSummary", player, summaryFor(state, player, settlement, escapees))
		end
	end
	runResolved:Fire(table.freeze(table.clone(state.outcomes)))
	setPhase("Results")
end

local function evaluate(state: RunState)
	if state.resolved or runState ~= state or currentPhase() ~= "InRun" then
		return
	end
	local standings: { Standing } = {}
	for _, player in state.ctx.participants do
		local outcome: Enums.RunOutcome = state.outcomes[player] or "Pending"
		local gone = outcome == "Disconnected"
		table.insert(standings, {
			escaped = outcome == "Escaped",
			disconnected = gone,
			lifeState = if gone then "Lobby" else lifeStateOf(player),
			syringeCharges = if gone then 0 else syringeChargesOf(player),
		})
	end
	local verdict: Verdict = verdictOf(standings)
	if verdict ~= "Continue" then
		resolve(state, verdict)
	end
end

-- Schedules one evaluation of the current run (calls in the same frame coalesce).
function MatchAndDataService.RequestEvaluation()
	local state = runState
	if not state or state.resolved or state.scheduled then
		return
	end
	state.scheduled = true
	defer(function()
		state.scheduled = false
		evaluate(state)
	end)
end

-- Counts `player` as escaped from the current run (Level5.Escaped and the `escape` dev command). False when they are
-- not a participant still in it, or the run is not InRun.
function MatchAndDataService.MarkEscaped(player: Player): boolean
	local state = runState
	if not state or state.resolved or currentPhase() ~= "InRun" or not participates(state, player) then
		return false
	end
	if (state.outcomes[player] or "Pending") ~= "Pending" then
		return false
	end
	state.outcomes[player] = "Escaped"
	state.escapedAt[player] = now()
	writeOutcome(player, "Escaped")
	log.info("%s escaped", player.Name)
	playerEscaped:Fire(player)
	MatchAndDataService.RequestEvaluation()
	return true
end

-- A participant leaving an unresolved run: Disconnected (an escape stands), paid for what they did, re-evaluated.
local function settleLeaver(player: Player)
	local state = runState
	if not state or state.resolved or not participates(state, player) or state.settled[player] then
		return
	end
	if state.outcomes[player] ~= "Escaped" then
		state.outcomes[player] = "Disconnected"
	end
	settle(state, player, isDevRun())
	MatchAndDataService.RequestEvaluation()
end

-- Consumes one stock unit of each perk `player` has equipped and trims the loadout to what was consumed.
local function consumePerks(player: Player)
	local equipped = PerkConfig.parseLoadout(player:GetAttribute(P.Loadout))
	if #equipped == 0 then
		return
	end
	local consumed: { Enums.PerkId } = {}
	local ok = MatchAndDataService.Update(player, DEPLOY_REASON, function(data: Types.PlayerData): boolean
		local taken: { Enums.PerkId } = {}
		for _, perk in equipped do
			local stock = data.PerkStock[perk] or 0
			if stock >= 1 then
				data.PerkStock[perk] = stock - 1
				table.insert(taken, perk)
			end
		end
		consumed = taken
		return #taken > 0
	end)
	if not ok then
		consumed = {}
	end
	if #consumed ~= #equipped then
		setLoadout(player, consumed)
		log.info("%s deploys with %d of %d equipped perks (no stock for the rest)", player.Name, #consumed, #equipped)
	end
end

-- LobbyService's deploy (see the header). False while a run exists, away from the lobby, or with nobody to send.
function MatchAndDataService.Deploy(participants: { Player }, difficulty: Enums.Difficulty): boolean
	if deploying or currentRun() ~= nil then
		return false
	end
	local phase = currentPhase()
	if phase ~= "Lobby" and phase ~= "Countdown" then
		return false
	end
	local squad = MatchAndDataService.squadFrom(participants, isPresent)
	if #squad == 0 then
		return false
	end
	deploying = true
	for _, player in squad do
		consumePerks(player)
	end
	local chosen: Enums.Difficulty = if Enums.has(Enums.Difficulty, difficulty) then difficulty else "Standard"
	local ok, ctx = pcall(beginRun, squad, chosen)
	deploying = false
	if not ok then
		log.error("Deploy: BeginRun failed: %s", tostring(ctx))
		return false
	end
	spawnSquad(ctx.participants)
	log.info("deployed %d player(s) on %s (run %s)", #ctx.participants, ctx.difficulty, ctx.runId)
	return true
end

local function onFloorCleared(_level: Enums.LevelId, survivors: { Player })
	if isDevRun() then
		return
	end
	local args = { tostring(GameConfig.CreditsPerLevelCleared) }
	for _, player in survivors do
		if MatchAndDataService.IsWritable(player) then
			notify(player, CHECKPOINT_KEY, args)
		end
	end
end

-- Level 5's escape signal, when that controller exists (agent F's Level5_RoofController).
local function escapeSource(): EscapeSource?
	local candidate = (Levels :: any).Level5
	if type(candidate) ~= "table" then
		return nil
	end
	local escaped = candidate.Escaped
	if type(escaped) ~= "table" or type(escaped.Connect) ~= "function" then
		return nil
	end
	return candidate :: EscapeSource
end

--------------------------------------------------------------------------------
-- Dev commands
--------------------------------------------------------------------------------

local function findPlayer(caller: Player, name: string?): Player?
	if name == nil or name == "" then
		return caller
	end
	local wanted = string.lower(name)
	for _, player in Players:GetPlayers() do
		if string.sub(string.lower(player.Name), 1, #wanted) == wanted then
			return player
		end
	end
	return nil
end

local function describeData(player: Player): string
	local data = MatchAndDataService.GetData(player)
	if not data then
		return player.Name .. ": not loaded"
	end
	local entry = entries[player]
	local session = if entry then entry.session else nil
	local stock: { string } = {}
	for _, perk: Enums.PerkId in Enums.PerkId do
		local count = data.PerkStock[perk]
		if count then
			table.insert(stock, string.format("%s x%d", perk, count))
		end
	end
	return string.format(
		"%s: %s%s | mode %s | credits %d | escapes %d | best %s / %s | stock %s",
		player.Name,
		if session then session.state else "?",
		if session and session.reason then " (" .. session.reason .. ")" else "",
		tostring(MatchAndDataService.GetDataMode()),
		data.SurvivalCredits,
		data.Escapes,
		if data.BestTime.Standard then string.format("%.2fs", data.BestTime.Standard) else "-",
		if data.BestTime.Nightmare then string.format("%.2fs", data.BestTime.Nightmare) else "-",
		if #stock > 0 then table.concat(stock, ", ") else "none"
	)
end

local function registerDevCommands()
	DevToolsService.Register(
		"escape",
		"escape [player]: count you (or a named player) as escaped from the run",
		function(caller: Player, args: { string }): string?
			local target = findPlayer(caller, args[1])
			if not target then
				return "no player named " .. tostring(args[1])
			end
			if MatchAndDataService.MarkEscaped(target) then
				return target.Name .. " escaped"
			end
			return target.Name .. " cannot escape now (not a participant still in a live run)"
		end
	)
	DevToolsService.Register(
		"credits",
		"credits <amount>: set your SurvivalCredits",
		function(caller: Player, args: { string }): string?
			local amount = tonumber(args[1])
			if not amount or amount ~= amount or amount < 0 then
				return "usage: credits <amount>"
			end
			local credits = math.min(math.floor(amount), DataMigration.MaxCredits)
			local ok = MatchAndDataService.Update(caller, DEV_REASON, function(data: Types.PlayerData): boolean
				data.SurvivalCredits = credits
				return true
			end)
			return if ok
				then string.format("credits: %d", credits)
				else "your data is not writable (not loaded, or guest)"
		end
	)
	DevToolsService.Register(
		"data",
		"data [player]: show saved progress and the data mode",
		function(caller: Player, args: { string }): string?
			local target = findPlayer(caller, args[1])
			if not target then
				return "no player named " .. tostring(args[1])
			end
			return describeData(target)
		end,
		true
	)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- Swaps in fakes (nil restores every real dependency). A fake `store` replaces the live one.
function MatchAndDataService.SetDependencies(fake: Dependencies?)
	deps = fake or {}
	bindStore(currentStore())
	if deps.store then
		storeReady:Fire()
	end
end

local function serverSessionId(): string
	local ok, jobId = pcall(function(): string
		return game.JobId
	end)
	if ok and type(jobId) == "string" and jobId ~= "" then
		return jobId
	end
	return "studio-" .. HttpService:GenerateGUID(false)
end

local function onClose()
	for player in table.clone(entries) do
		xpcall(MatchAndDataService.OnPlayerRemoving, function(err: any)
			log.error("release at shutdown failed for %s: %s", player.Name, tostring(err))
		end, player)
	end
	local store = currentStore()
	if not store then
		return
	end
	local deadline = os.clock() + CLOSE_DEADLINE_SECONDS
	while (loading > 0 or store:PendingReleases() > 0) and os.clock() < deadline do
		task.wait(CLOSE_POLL_SECONDS)
	end
	if loading > 0 or store:PendingReleases() > 0 then
		log.error(
			"shutdown: %d load(s) and %d release(s) still running at the deadline",
			loading,
			store:PendingReleases()
		)
	end
end

function MatchAndDataService.Init()
	if initialized then
		return
	end
	initialized = true
	DevToolsService.SetMatchPolicyPresent(true)
	Net.Server.on("SettingsSave", onSettingsSave)
	serviceTrove:Connect(Players.PlayerAdded, MatchAndDataService.OnPlayerAdded)
	serviceTrove:Add(LifeStateService.StateChanged:Connect(function()
		MatchAndDataService.RequestEvaluation()
	end))
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(function(phase: Enums.MatchPhase)
		if phase == "InRun" then
			MatchAndDataService.RequestEvaluation()
		end
	end))
	serviceTrove:Add(CheckpointAirlockService.FloorCleared:Connect(onFloorCleared))
	local source = escapeSource()
	if source then
		serviceTrove:Add(source.Escaped:Connect(function(player: Player)
			MatchAndDataService.MarkEscaped(player)
		end))
	else
		log.info("Levels.Level5 has no Escaped signal; escapes come from the `escape` dev command only")
	end
	registerDevCommands()
	game:BindToClose(onClose)
end

function MatchAndDataService.Start()
	local backend, reason = StoreBackend.choose(RunService:IsStudio(), STORE_NAME)
	if reason then
		log.warn("data backend %s: %s", backend.kind, reason)
	end
	liveStore = PlayerDataStore.new({
		backend = backend,
		sessionId = serverSessionId(),
		now = os.time,
		wait = function(seconds: number)
			task.wait(seconds)
		end,
	})
	bindStore(currentStore())
	storeReady:Fire()
	refreshDataMode()
	for _, player in Players:GetPlayers() do
		MatchAndDataService.OnPlayerAdded(player)
	end
	serviceTrove:Connect(RunService.Heartbeat, function(dt: number)
		pollAccumulated += dt
		if pollAccumulated < POLL_SECONDS then
			return
		end
		pollAccumulated = 0
		xpcall(MatchAndDataService.Poll, function(err: any)
			log.warnThrottled("poll", 30, "data poll failed: %s", tostring(err))
		end)
	end)
end

function MatchAndDataService.BeginRun(ctx: Types.RunContext)
	local state: RunState = {
		ctx = ctx,
		outcomes = {},
		escapedAt = {},
		settled = {},
		resolved = false,
		scheduled = false,
	}
	for _, player in ctx.participants do
		state.outcomes[player] = "Pending"
		writeOutcome(player, "Pending")
	end
	runState = state
end

function MatchAndDataService.EndRun()
	local state = runState
	runState = nil
	if state then
		for _, player in state.ctx.participants do
			if isPresent(player) then
				player:SetAttribute(P.RunOutcome, nil)
			end
		end
	end
end

function MatchAndDataService.OnPlayerRemoving(player: Player)
	settleLeaver(player)
	local entry = entries[player]
	if not entry then
		return
	end
	entries[player] = nil
	entry.leaving = true
	local session = entry.session
	local store = currentStore()
	if session and store then
		task.spawn(function()
			store:Release(session)
		end)
	end
end

return table.freeze(MatchAndDataService)
