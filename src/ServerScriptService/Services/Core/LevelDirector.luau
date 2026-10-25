--!strict
-- LevelDirector: which level the squad is on. The only writer of ReplicatedStorage CurrentLevel and LevelPhase.
--
-- Per-level controllers (P6-P8, e.g. Level1_HallwaysController) plug in with RegisterLevel(controller). Every
-- controller registered for a level gets Activate(ctx) when that level becomes active and Deactivate() when the
-- squad leaves it or the run ends; each call runs in xpcall, so one broken controller never blocks the others.
--
-- Entering vs activating. EnterLevel(levelId) switches CurrentLevel at once (LevelPhase "Ready"). The level is
-- activated (controllers + LevelActivated, LevelPhase "Active") as soon as the match is InRun. A level entered while
-- the run is still Deploying (BeginRun enters Level0) is therefore activated only after every service's BeginRun has
-- run, so controllers always find the run's props and the Creature in place. Levels entered during the run (Advance,
-- dev level skip) activate immediately. The MatchPhase attribute is read fresh in a Deferred handler, so a run that
-- ends before the handler runs never activates a stale level.
--
-- MarkCleared() sets LevelPhase "Cleared" for the current level (P8 airlocks call it before Advance()).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local log = Log.new("LevelDirector")

local M = Attributes.Match

local LevelDirector = {}

LevelDirector.Name = "LevelDirector"

local levelActivated: Signal.Signal<Enums.LevelId, Types.LevelContext> = Signal.new()
local levelDeactivated: Signal.Signal<Enums.LevelId> = Signal.new()

LevelDirector.LevelActivated = levelActivated
LevelDirector.LevelDeactivated = levelDeactivated

local serviceTrove = Trove.new()

local registry: { [string]: { Types.LevelController } } = {}
local run: Types.RunContext? = nil
local current: Enums.LevelId? = nil
local context: Types.LevelContext? = nil
local active = false -- current level's controllers have been activated

--------------------------------------------------------------------------------
-- Pure helpers (specs: tests/Specs/CoreServices.spec.luau)
--------------------------------------------------------------------------------

-- The level after `levelId` in run order, or nil after the last level (or for an unknown id).
local function nextLevel(levelId: Enums.LevelId): Enums.LevelId?
	local index = Enums.levelIndex(levelId)
	if not index then
		return nil
	end
	local following: Enums.LevelId? = Enums.LevelId[index + 1]
	return following
end
LevelDirector.nextLevel = nextLevel

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function inRun(): boolean
	return ReplicatedStorage:GetAttribute(M.MatchPhase) == "InRun"
end

local function setPhase(phase: Enums.LevelPhase)
	Attributes.set(ReplicatedStorage, M.LevelPhase, phase)
end

local function controllersFor(levelId: Enums.LevelId): { Types.LevelController }
	return table.clone(registry[levelId] or {})
end

local function activateController(controller: Types.LevelController, ctx: Types.LevelContext)
	xpcall(controller.Activate, function(err: any)
		log.error("%s controller Activate failed: %s", ctx.levelId, tostring(err))
	end, ctx)
end

local function deactivateController(controller: Types.LevelController, levelId: Enums.LevelId)
	local deactivate = controller.Deactivate
	if not deactivate then
		return
	end
	xpcall(deactivate, function(err: any)
		log.error("%s controller Deactivate failed: %s", levelId, tostring(err))
	end)
end

local function activateCurrent()
	local ctx = context
	if active or not ctx then
		return
	end
	active = true
	setPhase("Active")
	for _, controller in controllersFor(ctx.levelId) do
		activateController(controller, ctx)
	end
	levelActivated:Fire(ctx.levelId, ctx)
	log.info("level %s active", ctx.levelId)
end

-- Leaves the current level. A level that was activated gets Deactivate() on its controllers and LevelDeactivated,
-- so every LevelDeactivated pairs with an earlier LevelActivated.
local function leaveCurrent()
	local previous: Enums.LevelId? = current
	local wasActive = active
	current = nil
	context = nil
	active = false
	if not previous or not wasActive then
		return
	end
	for _, controller in controllersFor(previous) do
		deactivateController(controller, previous)
	end
	levelDeactivated:Fire(previous)
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- Adds a per-level controller. Several controllers may share a level. A controller registered for the level that
-- is already active is activated right away.
function LevelDirector.RegisterLevel(controller: Types.LevelController)
	if not Enums.has(Enums.LevelId, controller.LevelId) then
		log.error("RegisterLevel: unknown LevelId %s", tostring(controller.LevelId))
		return
	end
	if type(controller.Activate) ~= "function" then
		log.error("RegisterLevel(%s): controller has no Activate", controller.LevelId)
		return
	end
	local list = registry[controller.LevelId]
	if not list then
		list = {}
		registry[controller.LevelId] = list
	end
	if table.find(list, controller) then
		return
	end
	table.insert(list, controller)
	local ctx = context
	if active and ctx and ctx.levelId == controller.LevelId then
		activateController(controller, ctx)
	end
end

function LevelDirector.GetCurrentLevel(): Enums.LevelId?
	return current
end

-- The current level's context (nil outside a run).
function LevelDirector.GetContext(): Types.LevelContext?
	return context
end

function LevelDirector.IsActive(): boolean
	return active
end

-- Switches the squad's level. Returns false (and changes nothing) outside a run, for an unknown id, or when the
-- level's geometry is missing. Re-entering the current level is a no-op that returns true.
function LevelDirector.EnterLevel(levelId: Enums.LevelId): boolean
	if not Enums.has(Enums.LevelId, levelId) then
		log.warn("EnterLevel: unknown level %s", tostring(levelId))
		return false
	end
	local runContext = run
	if not runContext then
		log.warn("EnterLevel(%s) ignored: no run in progress", levelId)
		return false
	end
	if current == levelId then
		return true
	end
	local root = Instances.layoutRoot(levelId)
	if not root then
		log.error("EnterLevel(%s): Workspace.School.%s is missing", levelId, levelId)
		return false
	end
	local runtime = Instances.runtimeLevel(levelId, true)
	assert(runtime, "runtimeLevel(create = true) always returns a folder")

	local previous = current
	leaveCurrent()
	if previous then
		log.info("left %s", previous)
	end

	local ctx: Types.LevelContext = {
		levelId = levelId,
		run = runContext,
		root = root,
		runtime = runtime,
	}
	current = levelId
	context = ctx
	active = false
	Attributes.set(ReplicatedStorage, M.CurrentLevel, levelId)
	setPhase("Ready")
	if inRun() then
		activateCurrent()
	else
		log.info("entered %s (activates when the run is live)", levelId)
	end
	return true
end

-- Moves to the next level in run order. Returns it, or nil when there is none (the roof is last) or no run.
function LevelDirector.Advance(): Enums.LevelId?
	local levelId: Enums.LevelId? = current
	if not levelId then
		log.warn("Advance ignored: no current level")
		return nil
	end
	local nextId: Enums.LevelId? = nextLevel(levelId)
	if not nextId then
		return nil
	end
	if LevelDirector.EnterLevel(nextId) then
		return nextId
	end
	return nil
end

-- Marks the current level cleared (the squad made it to the exit airlock).
function LevelDirector.MarkCleared()
	if current then
		setPhase("Cleared")
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function LevelDirector.Init()
	ReplicatedStorage:SetAttribute(M.CurrentLevel, nil)
	setPhase("Inactive")
	serviceTrove:Connect(ReplicatedStorage:GetAttributeChangedSignal(M.MatchPhase), function()
		if inRun() and run ~= nil then
			activateCurrent()
		end
	end)
end

function LevelDirector.BeginRun(ctx: Types.RunContext)
	leaveCurrent()
	run = ctx
	LevelDirector.EnterLevel(Enums.LevelId[1])
end

function LevelDirector.EndRun()
	leaveCurrent()
	run = nil
	ReplicatedStorage:SetAttribute(M.CurrentLevel, nil)
	setPhase("Inactive")
end

return LevelDirector
