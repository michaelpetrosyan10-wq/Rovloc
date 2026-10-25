--!strict
-- RunStatsService: per-player counters for the current run (Enums.StatKey) plus run timing.
--
-- BeginRun clears every counter and starts the clock. Increments outside a run are ignored. EndRun stops the clock
-- and keeps the last run's numbers readable until the next BeginRun, so the P8 escape summary can read them after
-- the run has been torn down. Counters are keyed by UserId, so a player who drops and rejoins mid-run keeps theirs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Types = require(ReplicatedStorage.Shared.Types)

local log = Log.new("RunStats")

local RunStatsService = {}

RunStatsService.Name = "RunStatsService"

local counters: { [number]: { [string]: number } } = {}
local running = false
local startedAt: number? = nil
local endedAt: number? = nil

local function countersFor(userId: number): { [string]: number }
	local entry = counters[userId]
	if not entry then
		entry = {}
		counters[userId] = entry
	end
	return entry
end

-- Adds `amount` (default 1) to `player`'s `key` counter for the current run.
function RunStatsService.Increment(player: Player, key: Enums.StatKey, amount: number?)
	if not Enums.has(Enums.StatKey, key) then
		log.warnThrottled("key:" .. tostring(key), 10, "Increment: unknown stat %s", tostring(key))
		return
	end
	local delta = amount or 1
	if not MathUtil.isFinite(delta) then
		log.warnThrottled("amount:" .. key, 10, "Increment(%s): non-finite amount ignored", key)
		return
	end
	if not running then
		return
	end
	local entry = countersFor(player.UserId)
	entry[key] = (entry[key] or 0) + delta
end

-- `player`'s `key` counter for the current (or last finished) run.
function RunStatsService.Get(player: Player, key: Enums.StatKey): number
	local entry = counters[player.UserId]
	return if entry then entry[key] or 0 else 0
end

-- Every StatKey for `player` (zeros included), as a fresh table.
function RunStatsService.Snapshot(player: Player): { [string]: number }
	local entry = counters[player.UserId]
	local out: { [string]: number } = {}
	for _, key: Enums.StatKey in Enums.StatKey do
		out[key] = if entry then entry[key] or 0 else 0
	end
	return out
end

-- Seconds since the current run began; after EndRun, the finished run's length; 0 before any run.
function RunStatsService.RunSeconds(): number
	local started = startedAt
	if not started then
		return 0
	end
	local finish = if running then Workspace:GetServerTimeNow() else endedAt or started
	return math.max(0, finish - started)
end

function RunStatsService.IsRunning(): boolean
	return running
end

function RunStatsService.BeginRun(ctx: Types.RunContext)
	table.clear(counters)
	running = true
	startedAt = ctx.startedAt
	endedAt = nil
end

function RunStatsService.EndRun()
	if not running then
		return
	end
	running = false
	endedAt = Workspace:GetServerTimeNow()
	log.info("run lasted %.1fs", RunStatsService.RunSeconds())
end

return RunStatsService
