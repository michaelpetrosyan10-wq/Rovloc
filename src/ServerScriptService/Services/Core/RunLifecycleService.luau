--!strict
-- RunLifecycleService: the match state machine. The only writer of the ReplicatedStorage attributes MatchPhase,
-- RunId, RunSeed, Difficulty, RunStartedAt and RunEndedAt.
--
-- Phases: Booting -> Lobby -> (Countdown ->) Deploying -> InRun -> RunEnded -> (Results ->) Resetting -> Lobby.
-- SetPhase refuses any other transition. The service boots in Booting and moves to Lobby once WorldService has
-- finished building the world.
--
-- BeginRun(participants, difficulty, seed?) ends any run in progress, builds the RunContext (fresh run id; the seed
-- given, or a new one), publishes the run attributes, enters Deploying, calls every service's BeginRun in ServerMain
-- order (each in xpcall), enters InRun and fires RunStarted. EndRun() enters RunEnded (unless a match policy already
-- moved the run to RunEnded / Results), fires RunEnded, enters Resetting, calls every service's EndRun in reverse
-- order, clears Workspace.Runtime, clears RunId / RunSeed and returns to Lobby. Transitions are serialized: a
-- BeginRun / EndRun issued while another is running waits for it.
--
-- RunId is written last on BeginRun and cleared on EndRun, so clients watching it (ClientMain) always see the seed
-- and difficulty of the run that just started.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Types = require(ReplicatedStorage.Shared.Types)

local WorldService = require(ServerScriptService.Services.Core.WorldService)

local log = Log.new("RunLifecycle")

local M = Attributes.Match

local MAX_SEED = 2147483646
local BOOT_WAIT_SECONDS = 30

-- Allowed phase transitions (from -> set of to).
local TRANSITIONS: { [Enums.MatchPhase]: { [Enums.MatchPhase]: boolean } } = {
	Booting = { Lobby = true },
	Lobby = { Countdown = true, Deploying = true },
	Countdown = { Lobby = true, Deploying = true },
	Deploying = { InRun = true, RunEnded = true, Resetting = true },
	InRun = { RunEnded = true },
	RunEnded = { Results = true, Resetting = true },
	Results = { Resetting = true },
	Resetting = { Lobby = true },
}

local RunLifecycleService = {}

RunLifecycleService.Name = "RunLifecycleService"

local phaseChanged: Signal.Signal<Enums.MatchPhase> = Signal.new()
local runStarted: Signal.Signal<Types.RunContext> = Signal.new()
local runEnded: Signal.Signal<()> = Signal.new()

RunLifecycleService.PhaseChanged = phaseChanged
RunLifecycleService.RunStarted = runStarted
RunLifecycleService.RunEnded = runEnded

local services: { Types.Service } = {}
local phase: Enums.MatchPhase = "Booting"
local run: Types.RunContext? = nil
local transitioning = false
local transitionThread: thread? = nil -- the thread running the current BeginRun / EndRun
local runCount = 0

--------------------------------------------------------------------------------
-- Pure helpers (specs: tests/Specs/CoreServices.spec.luau)
--------------------------------------------------------------------------------

function RunLifecycleService.canTransition(from: Enums.MatchPhase, to: Enums.MatchPhase): boolean
	if from == to then
		return true
	end
	local allowed = TRANSITIONS[from]
	return allowed ~= nil and allowed[to] == true
end

-- A usable run seed from caller input: a positive integer in [1, 2^31 - 2], or nil when `seed` is missing or not a
-- finite number.
function RunLifecycleService.normalizeSeed(seed: number?): number?
	if seed == nil or not MathUtil.isFinite(seed) then
		return nil
	end
	local whole = math.abs(math.floor(seed))
	return (whole - 1) % MAX_SEED + 1
end

-- A seed derived from `entropy` (deterministic for equal input).
function RunLifecycleService.seedFromEntropy(entropy: string): number
	return MathUtil.hash(entropy) % MAX_SEED + 1
end

--------------------------------------------------------------------------------
-- Phases
--------------------------------------------------------------------------------

local function writePhase(nextPhase: Enums.MatchPhase)
	if phase == nextPhase then
		return
	end
	local previous = phase
	phase = nextPhase
	ReplicatedStorage:SetAttribute(M.MatchPhase, nextPhase)
	log.info("phase %s -> %s", previous, nextPhase)
	phaseChanged:Fire(nextPhase)
end

-- Moves the match to `nextPhase`. Returns false (and changes nothing) for an unknown phase or a transition the
-- state machine does not allow.
function RunLifecycleService.SetPhase(nextPhase: Enums.MatchPhase): boolean
	if not Enums.has(Enums.MatchPhase, nextPhase) then
		log.warn("SetPhase: unknown phase %s", tostring(nextPhase))
		return false
	end
	if not RunLifecycleService.canTransition(phase, nextPhase) then
		log.warn("SetPhase: %s -> %s is not allowed", phase, nextPhase)
		return false
	end
	writePhase(nextPhase)
	return true
end

function RunLifecycleService.GetPhase(): Enums.MatchPhase
	return phase
end

function RunLifecycleService.GetRun(): Types.RunContext?
	return run
end

-- ServerMain hands over its ordered service list (BeginRun runs forward, EndRun in reverse).
function RunLifecycleService.SetServices(list: { Types.Service })
	services = table.clone(list)
end

--------------------------------------------------------------------------------
-- Runs
--------------------------------------------------------------------------------

-- True when the calling thread is the one running the current transition (a service's BeginRun / EndRun hook
-- calling back into this service), which must not wait for itself.
local function insideTransition(): boolean
	return transitioning and transitionThread == coroutine.running()
end

-- Serializes BeginRun / EndRun: the check and the set happen without a yield in between.
local function acquire()
	while transitioning do
		task.wait()
	end
	transitioning = true
	transitionThread = coroutine.running()
end

local function release()
	transitioning = false
	transitionThread = nil
end

local function fanOut(stage: "BeginRun" | "EndRun", ctx: Types.RunContext?)
	if stage == "BeginRun" then
		local context = ctx
		assert(context, "BeginRun fan-out needs a context")
		for _, service in services do
			local beginRun = service.BeginRun
			if beginRun and service.Name ~= RunLifecycleService.Name then
				xpcall(beginRun, function(err: any)
					log.error("%s.BeginRun failed: %s", service.Name, tostring(err))
				end, context)
			end
		end
	else
		for i = #services, 1, -1 do
			local service = services[i]
			local endRun = service.EndRun
			if endRun and service.Name ~= RunLifecycleService.Name then
				xpcall(endRun, function(err: any)
					log.error("%s.EndRun failed: %s", service.Name, tostring(err))
				end)
			end
		end
	end
end

local function endRunLocked()
	local current = run
	if not current then
		return
	end
	if phase ~= "RunEnded" and phase ~= "Results" then
		writePhase("RunEnded")
	end
	ReplicatedStorage:SetAttribute(M.RunEndedAt, Workspace:GetServerTimeNow())
	runEnded:Fire()
	writePhase("Resetting")
	fanOut("EndRun", nil)
	xpcall(Builder.ClearRuntime, function(err: any)
		log.error("ClearRuntime failed: %s", tostring(err))
	end)
	run = nil
	ReplicatedStorage:SetAttribute(M.RunId, nil)
	ReplicatedStorage:SetAttribute(M.RunSeed, nil)
	writePhase("Lobby")
	log.info("run %s ended", current.runId)
end

-- Ends the run in progress (no-op when there is none). Yields only while another transition finishes.
function RunLifecycleService.EndRun()
	if insideTransition() then
		-- Called from a lifecycle hook: finish the current transition first.
		log.warn("EndRun called from inside a run transition; it runs once that transition finishes")
		task.defer(RunLifecycleService.EndRun)
		return
	end
	acquire()
	if run then
		xpcall(endRunLocked, function(err: any)
			log.error("EndRun failed: %s", tostring(err))
		end)
	end
	release()
end

local function deploy(ctx: Types.RunContext)
	if phase ~= "Deploying" then
		if not RunLifecycleService.canTransition(phase, "Deploying") then
			log.warn("BeginRun from %s: forcing Deploying", phase)
		end
		writePhase("Deploying")
	end
	ReplicatedStorage:SetAttribute(M.RunSeed, ctx.seed)
	ReplicatedStorage:SetAttribute(M.Difficulty, ctx.difficulty)
	ReplicatedStorage:SetAttribute(M.RunStartedAt, ctx.startedAt)
	ReplicatedStorage:SetAttribute(M.RunEndedAt, nil)
	ReplicatedStorage:SetAttribute(M.RunId, ctx.runId)
	log.info("run %s: %s, seed %d, %d participant(s)", ctx.runId, ctx.difficulty, ctx.seed, #ctx.participants)
	fanOut("BeginRun", ctx)
	writePhase("InRun")
end

local function newSeed(): number
	runCount += 1
	local entropy = string.format(
		"%s|%.6f|%.6f|%d",
		HttpService:GenerateGUID(false),
		Workspace:GetServerTimeNow(),
		os.clock(),
		runCount
	)
	return RunLifecycleService.seedFromEntropy(entropy)
end

-- Starts a run for `participants` (players who already left are dropped). Ends any run in progress first, and waits
-- for the world when called during boot. Returns the run's context.
function RunLifecycleService.BeginRun(
	participants: { Player },
	difficulty: Enums.Difficulty,
	seed: number?
): Types.RunContext
	if insideTransition() then
		error("RunLifecycleService.BeginRun called from inside a run transition (a BeginRun / EndRun hook)", 2)
	end
	while phase == "Booting" do
		WorldService.WaitUntilReady(BOOT_WAIT_SECONDS)
		if phase == "Booting" then
			task.wait()
		end
	end
	acquire()
	local previous = run
	if previous then
		log.info("BeginRun: ending run %s first", previous.runId)
		xpcall(endRunLocked, function(err: any)
			log.error("EndRun before BeginRun failed: %s", tostring(err))
		end)
	end

	local chosenDifficulty: Enums.Difficulty = if Enums.has(Enums.Difficulty, difficulty)
		then difficulty
		else "Standard"
	if chosenDifficulty ~= difficulty then
		log.warn("BeginRun: unknown difficulty %s, using Standard", tostring(difficulty))
	end
	local present: { Player } = {}
	for _, player in participants do
		if player.Parent == Players then
			table.insert(present, player)
		end
	end
	table.freeze(present)
	local ctx: Types.RunContext = {
		runId = HttpService:GenerateGUID(false),
		seed = RunLifecycleService.normalizeSeed(seed) or newSeed(),
		difficulty = chosenDifficulty,
		participants = present,
		startedAt = Workspace:GetServerTimeNow(),
	}
	table.freeze(ctx)
	run = ctx

	xpcall(deploy, function(err: any)
		log.error("BeginRun %s failed: %s", ctx.runId, tostring(err))
	end, ctx)
	release()
	runStarted:Fire(ctx)
	return ctx
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function RunLifecycleService.Init()
	phase = "Booting"
	ReplicatedStorage:SetAttribute(M.MatchPhase, phase)
	ReplicatedStorage:SetAttribute(M.RunId, nil)
	ReplicatedStorage:SetAttribute(M.RunSeed, nil)
	ReplicatedStorage:SetAttribute(M.RunStartedAt, nil)
	ReplicatedStorage:SetAttribute(M.RunEndedAt, nil)
end

function RunLifecycleService.Start()
	while not WorldService.WaitUntilReady(BOOT_WAIT_SECONDS) do
		log.warnThrottled("boot", 30, "still waiting for the world build")
	end
	if phase == "Booting" then
		writePhase("Lobby")
	end
end

return RunLifecycleService
