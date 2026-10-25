--!strict
-- ClientMain: the client's one ordered bootstrap.
--
--   1. Waits for game.Loaded, then Net.Client.setup() (waits for the server's remotes; the loading curtain may have
--      run it already, setup is idempotent).
--   2. Disables the Reset Character menu button (a self-reset would bypass LifeStateService; ARCHITECTURE §5).
--      SetCore only works once the core scripts registered it, so it retries for up to RESET_RETRY_SECONDS.
--   3. Requires the controllers in CONTROLLER_ORDER (each require isolated), calls every Init (xpcall; Init must not
--      yield), then every Start (each in its own thread, so a yielding Start never blocks the rest).
--   4. Watches ReplicatedStorage.RunId (RunLifecycleService writes it last when a run begins and clears it when the
--      run resets) and calls OnRunStarted({ runId, seed, difficulty }) / OnRunEnded() on every controller, in order.
--      A run already in progress when this client joins is announced right after Start.
-- Later phases append their controllers to CONTROLLER_ORDER; this is the only client file that grows.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)

local log = Log.new("ClientMain")

local M = Attributes.Match

local RESET_RETRY_SECONDS = 10
local RESET_RETRY_INTERVAL = 0.25

local Core = script.Parent.Controllers.Core

type Loader = { name: string, load: () -> any }

-- Bootstrap order. Audio first (buses exist before anything plays), DevTools last (it reads the others' stats).
local CONTROLLER_ORDER: { Loader } = {
	{
		name = "AudioController",
		load = function(): any
			return require(Core.AudioController)
		end,
	},
	{
		name = "LightingController",
		load = function(): any
			return require(Core.LightingController)
		end,
	},
	{
		name = "CosmeticWorldController",
		load = function(): any
			return require(Core.CosmeticWorldController)
		end,
	},
	{
		name = "DevToolsController",
		load = function(): any
			return require(Core.DevToolsController)
		end,
	},
}

--------------------------------------------------------------------------------
-- Net + Reset button
--------------------------------------------------------------------------------

xpcall(Net.Client.setup, function(err: any)
	-- Controllers still start; their remote handlers stay unbound and Net logs every use.
	log.error("Net.Client.setup failed: %s", tostring(err))
end)

task.spawn(function()
	local deadline = os.clock() + RESET_RETRY_SECONDS
	while true do
		local ok = xpcall(function()
			StarterGui:SetCore("ResetButtonCallback", false)
		end, function(err: any): any
			return err
		end)
		if ok then
			return
		end
		if os.clock() >= deadline then
			log.warn("could not disable the Reset Character button after %ds", RESET_RETRY_SECONDS)
			return
		end
		task.wait(RESET_RETRY_INTERVAL)
	end
end)

--------------------------------------------------------------------------------
-- Controllers
--------------------------------------------------------------------------------

local controllers: { Types.Controller } = {}

for _, loader in CONTROLLER_ORDER do
	local loaded: any = nil
	xpcall(function()
		loaded = loader.load()
	end, function(err: any)
		log.error("%s failed to load: %s", loader.name, tostring(err))
	end)
	if type(loaded) == "table" and type(loaded.Name) == "string" then
		table.insert(controllers, loaded :: Types.Controller)
	elseif loaded ~= nil then
		log.error("%s is not a controller (missing Name)", loader.name)
	end
end

local function call(controller: Types.Controller, stage: string, fn: (...any) -> (), ...: any)
	xpcall(fn, function(err: any)
		log.error("%s.%s failed: %s\n%s", controller.Name, stage, tostring(err), debug.traceback())
	end, ...)
end

for _, controller in controllers do
	local init = controller.Init
	if init then
		call(controller, "Init", init)
	end
end

for _, controller in controllers do
	local start = controller.Start
	if start then
		task.spawn(call, controller, "Start", start)
	end
end

log.info("%d controllers started", #controllers)

--------------------------------------------------------------------------------
-- Run lifecycle (ReplicatedStorage.RunId)
--------------------------------------------------------------------------------

local announcedRunId: string? = nil

local function readRun(): Types.RunInfo?
	local runId = ReplicatedStorage:GetAttribute(M.RunId)
	if type(runId) ~= "string" or runId == "" then
		return nil
	end
	local rawDifficulty = ReplicatedStorage:GetAttribute(M.Difficulty)
	local difficulty: Enums.Difficulty = if Enums.has(Enums.Difficulty, rawDifficulty)
		then (rawDifficulty :: any) :: Enums.Difficulty
		else "Standard"
	return {
		runId = runId,
		seed = Attributes.getNumber(ReplicatedStorage, M.RunSeed, 0),
		difficulty = difficulty,
	}
end

local function runEnded()
	if announcedRunId == nil then
		return
	end
	log.info("run %s ended", announcedRunId)
	announcedRunId = nil
	for _, controller in controllers do
		local hook = controller.OnRunEnded
		if hook then
			call(controller, "OnRunEnded", hook)
		end
	end
end

local function runStarted(info: Types.RunInfo)
	announcedRunId = info.runId
	log.info("run %s started (seed %d, %s)", info.runId, info.seed, info.difficulty)
	for _, controller in controllers do
		local hook = controller.OnRunStarted
		if hook then
			call(controller, "OnRunStarted", hook, info)
		end
	end
end

local function syncRun()
	local info = readRun()
	local runId = if info then info.runId else nil
	if runId == announcedRunId then
		return
	end
	runEnded()
	if info then
		runStarted(info)
	end
end

ReplicatedStorage:GetAttributeChangedSignal(M.RunId):Connect(syncRun)
syncRun()
