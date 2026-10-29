--!strict
-- TelemetryService: AnalyticsService events for the match loop. Every call is pcall'd and skipped in Studio (and so
-- in the Lune harness), where AnalyticsService only logs to the output.
--
-- Funnel "RunFunnel", one funnel session (a GUID) per player per trip from the lobby, each step logged once and in
-- order: 1 Lobby (data ready in the lobby, or back in it after a run) -> 2 Deploy (a run started with them) ->
-- 3..8 Floor_<LevelId> (each level activated while they were still in the run; Level 0 at the deploy) -> 9 Escape.
-- Custom events:
--   Death         (value: level index 0-5) when a player is executed; CustomField01 = the cause (Bleedout, Fell,
--                 Drowned, a jumpscare, ...), CustomField02 = the level, CustomField03 = the difficulty
--   FloorReached  (value: the highest level index the participant reached) for each participant when the run
--                 resolves; CustomField01 = the outcome, CustomField02 = the difficulty
-- Economy (currency "SurvivalCredits", from MatchAndDataService.Committed): a credit gain is a Source (Gameplay; the
-- item sku is the Update's reason, e.g. RunReward), a loss a Sink (Shop; e.g. the perk shop's purchase), each with
-- the ending balance.
--
-- Pure builders (tests/Specs/MatchFlow.spec.luau): levelStep, deathEvent, floorReachedEvent, economyEvent.
-- SetDependencies swaps the sink (specs record events), the GUID source and the run / phase / level lookups.

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local MatchAndDataService = require(ServerScriptService.Services.Match.MatchAndDataService)

local log = Log.new("Telemetry")

export type Fields = { [string]: string | number }

export type FunnelEvent = {
	kind: "Funnel",
	player: Player,
	funnel: string,
	session: string,
	step: number,
	stepName: string,
}

export type CustomEvent = {
	kind: "Custom",
	player: Player,
	name: string,
	value: number,
	fields: Fields,
}

export type EconomyEvent = {
	kind: "Economy",
	player: Player,
	flow: "Source" | "Sink",
	currency: string,
	amount: number,
	balance: number,
	transaction: "Gameplay" | "Shop",
	sku: string,
}

export type Event = FunnelEvent | CustomEvent | EconomyEvent

export type Dependencies = {
	sink: ((event: Event) -> ())?,
	guid: (() -> string)?,
	run: (() -> Types.RunContext?)?,
	phase: (() -> Enums.MatchPhase)?,
	level: (() -> Enums.LevelId?)?,
}

type Funnel = { id: string, step: number }

local FUNNEL = "RunFunnel"
local CURRENCY = "SurvivalCredits"
local STEP_LOBBY = 1
local STEP_DEPLOY = 2
local FIRST_FLOOR_STEP = 3
local STEP_ESCAPE = FIRST_FLOOR_STEP + #Enums.LevelId
local FIELD_1 = "CustomField01"
local FIELD_2 = "CustomField02"
local FIELD_3 = "CustomField03"
local LOBBY_PHASES: { [string]: boolean } = { Lobby = true, Countdown = true }

local TelemetryService = {}

TelemetryService.Name = "TelemetryService"
TelemetryService.Funnel = FUNNEL
TelemetryService.Currency = CURRENCY
TelemetryService.Steps = table.freeze({ Lobby = STEP_LOBBY, Deploy = STEP_DEPLOY, Escape = STEP_ESCAPE })

local deps: Dependencies = {}
local serviceTrove = Trove.new()
local funnels: { [Player]: Funnel } = {}
local reached: { [Player]: number } = {}
local skip = true
local initialized = false

--------------------------------------------------------------------------------
-- Pure builders
--------------------------------------------------------------------------------

-- The funnel step of reaching `levelId` and its name.
function TelemetryService.levelStep(levelId: Enums.LevelId): (number, string)
	local index = Enums.levelIndex(levelId) or 1
	return FIRST_FLOOR_STEP + index - 1, "Floor_" .. levelId
end

function TelemetryService.deathEvent(
	player: Player,
	cause: string,
	levelId: Enums.LevelId?,
	difficulty: Enums.Difficulty?
): CustomEvent
	local index = if levelId then Enums.levelIndex(levelId) else nil
	return {
		kind = "Custom",
		player = player,
		name = "Death",
		value = if index then index - 1 else -1,
		fields = {
			[FIELD_1] = cause,
			[FIELD_2] = levelId or "None",
			[FIELD_3] = difficulty or "None",
		},
	}
end

function TelemetryService.floorReachedEvent(
	player: Player,
	levelIndex: number,
	outcome: Enums.RunOutcome,
	difficulty: Enums.Difficulty
): CustomEvent
	return {
		kind = "Custom",
		player = player,
		name = "FloorReached",
		value = levelIndex,
		fields = { [FIELD_1] = outcome, [FIELD_2] = difficulty },
	}
end

-- The economy event for a credit change (nil when the balance did not move).
function TelemetryService.economyEvent(player: Player, reason: string, before: number, after: number): EconomyEvent?
	local delta = after - before
	if delta == 0 then
		return nil
	end
	return {
		kind = "Economy",
		player = player,
		flow = if delta > 0 then "Source" else "Sink",
		currency = CURRENCY,
		amount = math.abs(delta),
		balance = after,
		transaction = if delta > 0 then "Gameplay" else "Shop",
		sku = reason,
	}
end

--------------------------------------------------------------------------------
-- Sink
--------------------------------------------------------------------------------

local function analytics(event: Event)
	if event.kind == "Funnel" then
		AnalyticsService:LogFunnelStepEvent(event.player, event.funnel, event.session, event.step, event.stepName)
	elseif event.kind == "Custom" then
		AnalyticsService:LogCustomEvent(event.player, event.name, event.value, event.fields)
	else
		local flow = if event.flow == "Source"
			then Enum.AnalyticsEconomyFlowType.Source
			else Enum.AnalyticsEconomyFlowType.Sink
		local transaction = if event.transaction == "Gameplay"
			then Enum.AnalyticsEconomyTransactionType.Gameplay
			else Enum.AnalyticsEconomyTransactionType.Shop
		AnalyticsService:LogEconomyEvent(
			event.player,
			flow,
			event.currency,
			event.amount,
			event.balance,
			transaction.Name,
			event.sku
		)
	end
end

local function emit(event: Event)
	local fake = deps.sink
	if fake then
		fake(event)
		return
	end
	if skip or event.player.Parent ~= Players then
		return
	end
	xpcall(analytics, function(err: any)
		log.warnThrottled(
			"analytics:" .. event.kind,
			60,
			"AnalyticsService %s event failed: %s",
			event.kind,
			tostring(err)
		)
	end, event)
end

local function newGuid(): string
	local fake = deps.guid
	return if fake then fake() else HttpService:GenerateGUID(false)
end

local function currentRun(): Types.RunContext?
	local fake = deps.run
	return if fake then fake() else RunLifecycleService.GetRun()
end

local function currentPhase(): Enums.MatchPhase
	local fake = deps.phase
	return if fake then fake() else RunLifecycleService.GetPhase()
end

local function currentLevel(): Enums.LevelId?
	local fake = deps.level
	return if fake then fake() else LevelDirector.GetCurrentLevel()
end

-- Swaps in fakes (nil restores AnalyticsService and the real lookups) and forgets every funnel session.
function TelemetryService.SetDependencies(fake: Dependencies?)
	deps = fake or {}
	table.clear(funnels)
	table.clear(reached)
end

--------------------------------------------------------------------------------
-- Funnel
--------------------------------------------------------------------------------

local function step(player: Player, number: number, name: string)
	local funnel = funnels[player]
	if not funnel or number <= funnel.step then
		return
	end
	funnel.step = number
	emit({ kind = "Funnel", player = player, funnel = FUNNEL, session = funnel.id, step = number, stepName = name })
end

-- A fresh funnel session for `player`, starting at the Lobby step.
function TelemetryService.EnterLobby(player: Player)
	funnels[player] = { id = newGuid(), step = 0 }
	step(player, STEP_LOBBY, "Lobby")
end

local function inRun(ctx: Types.RunContext, player: Player): boolean
	return table.find(ctx.participants, player) ~= nil and MatchAndDataService.GetOutcome(player) == "Pending"
end

-- RunLifecycleService.RunStarted: the Deploy step (and Level 0) for every participant.
function TelemetryService.OnRunStarted(ctx: Types.RunContext)
	for _, player in ctx.participants do
		if not funnels[player] then
			funnels[player] = { id = newGuid(), step = STEP_LOBBY }
		end
		step(player, STEP_DEPLOY, "Deploy")
		reached[player] = 0
	end
	local level: Enums.LevelId? = currentLevel()
	if level then
		TelemetryService.OnLevelActivated(level)
	end
end

-- LevelDirector.LevelActivated: the floor step for every participant still in the run.
function TelemetryService.OnLevelActivated(levelId: Enums.LevelId)
	local ctx = currentRun()
	if not ctx then
		return
	end
	local number, name = TelemetryService.levelStep(levelId)
	local index = (Enums.levelIndex(levelId) or 1) - 1
	for _, player in ctx.participants do
		if not inRun(ctx, player) then
			continue
		end
		reached[player] = math.max(reached[player] or 0, index)
		-- The first level activates (InRun) before RunStarted logs Deploy; OnRunStarted logs it after Deploy.
		local funnel = funnels[player]
		if funnel and funnel.step >= STEP_DEPLOY then
			step(player, number, name)
		end
	end
end

function TelemetryService.OnEscaped(player: Player)
	step(player, STEP_ESCAPE, "Escape")
end

function TelemetryService.OnExecuted(player: Player, cause: string)
	local ctx = currentRun()
	emit(TelemetryService.deathEvent(player, cause, currentLevel(), if ctx then ctx.difficulty else nil))
end

function TelemetryService.OnRunResolved(outcomes: { [Player]: Enums.RunOutcome })
	local ctx = currentRun()
	local difficulty: Enums.Difficulty = if ctx then ctx.difficulty else "Standard"
	for player, outcome: Enums.RunOutcome in outcomes do
		emit(TelemetryService.floorReachedEvent(player, reached[player] or 0, outcome, difficulty))
	end
	table.clear(reached)
end

function TelemetryService.OnCommitted(player: Player, reason: string, before: Types.PlayerData, after: Types.PlayerData)
	local event = TelemetryService.economyEvent(player, reason, before.SurvivalCredits, after.SurvivalCredits)
	if event then
		emit(event)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function TelemetryService.Init()
	if initialized then
		return
	end
	initialized = true
	skip = RunService:IsStudio()
	serviceTrove:Add(MatchAndDataService.DataLoaded:Connect(function(player: Player)
		if LOBBY_PHASES[currentPhase()] and not funnels[player] then
			TelemetryService.EnterLobby(player)
		end
	end))
	serviceTrove:Add(RunLifecycleService.RunStarted:Connect(TelemetryService.OnRunStarted))
	serviceTrove:Add(LevelDirector.LevelActivated:Connect(function(levelId: Enums.LevelId)
		TelemetryService.OnLevelActivated(levelId)
	end))
	serviceTrove:Add(MatchAndDataService.PlayerEscaped:Connect(TelemetryService.OnEscaped))
	serviceTrove:Add(LifeStateService.Executed:Connect(TelemetryService.OnExecuted))
	serviceTrove:Add(MatchAndDataService.RunResolved:Connect(TelemetryService.OnRunResolved))
	serviceTrove:Add(MatchAndDataService.Committed:Connect(TelemetryService.OnCommitted))
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(function(phase: Enums.MatchPhase)
		if phase ~= "Lobby" then
			return
		end
		for _, player in Players:GetPlayers() do
			if MatchAndDataService.GetData(player) then
				TelemetryService.EnterLobby(player)
			end
		end
	end))
end

function TelemetryService.OnPlayerRemoving(player: Player)
	funnels[player] = nil
	reached[player] = nil
end

return table.freeze(TelemetryService)
