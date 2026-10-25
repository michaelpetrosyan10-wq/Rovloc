--!strict
-- CosmeticWorldController: client-only scenery that never replicates and never collides.
--
--   * Static pass. Once ReplicatedStorage.WorldReady is true (so it never competes with the world download on a
--     phone), ProceduralWorldBuilder.BuildCosmetic(STATIC_SEED, Workspace.Cosmetic) builds the ruined skyline and the
--     between-runs dressing (every registered cosmetic-anchor builder, seeded with STATIC_SEED).
--   * Run pass. OnRunStarted rebuilds the run-varying dressing into Workspace.Cosmetic.<RUN_FOLDER> with the run
--     seed (BuildCosmetic skips the skyline there because an ancestor already holds it) and parks the static
--     dressing; OnRunEnded destroys the run folder and puts the static dressing back.
--   * Builds yield (the builder's yieldPoint), so one worker thread reconciles "what should exist" with "what was
--     built": runs that start and end while a build is in flight never leave dressing behind or build twice at once.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local log = Log.new("CosmeticWorld")

local M = Attributes.Match

local STATIC_SEED = 1
local RUN_FOLDER = "Run"
local DRESSING_FOLDER = "Dressing" -- the folder BuildCosmetic replaces under its parent

export type Stats = {
	staticBuilt: boolean,
	staticParts: number,
	runId: string?,
	runParts: number,
	building: boolean,
}

local CosmeticWorldController = {}

CosmeticWorldController.Name = "CosmeticWorldController"

local serviceTrove = Trove.new()

local staticBuilt = false
local staticParts = 0
local parkedDressing: Instance? = nil
local runFolder: Folder? = nil
local builtRunId: string? = nil
local runParts = 0
local desiredRun: Types.RunInfo? = nil
local working = false

local function build(seed: number, parent: Instance): number
	local parts = 0
	xpcall(function()
		parts = Builder.BuildCosmetic(seed, parent)
	end, function(err: any)
		log.error("cosmetic build (seed %d) failed: %s", seed, tostring(err))
	end)
	return parts
end

-- Puts the static dressing back under Workspace.Cosmetic (when a run folder no longer replaces it).
local function restoreStaticDressing()
	local parked = parkedDressing
	parkedDressing = nil
	if parked then
		parked.Parent = Instances.cosmetic()
	end
end

-- Takes the static dressing out of the world while a run's own dressing stands in for it.
local function parkStaticDressing()
	if parkedDressing then
		return
	end
	local dressing = Instances.cosmetic():FindFirstChild(DRESSING_FOLDER)
	if dressing then
		dressing.Parent = nil
		parkedDressing = dressing
	end
end

local function clearRun()
	local folder = runFolder
	runFolder = nil
	builtRunId = nil
	runParts = 0
	if folder then
		folder:Destroy()
	end
	restoreStaticDressing()
end

local function buildRun(info: Types.RunInfo)
	clearRun()
	local folder = Instance.new("Folder")
	folder.Name = RUN_FOLDER
	folder.Parent = Instances.cosmetic()
	runFolder = folder
	builtRunId = info.runId
	parkStaticDressing()
	runParts = build(info.seed, folder)
	log.debug("run %s dressing: %d parts", info.runId, runParts)
end

-- One worker at a time; it loops until what is built matches what is wanted.
local function reconcile()
	if working or not staticBuilt then
		return
	end
	working = true
	task.spawn(function()
		while true do
			local want = desiredRun
			local wantId = if want then want.runId else nil
			if wantId == builtRunId and (want == nil or runFolder ~= nil) then
				break
			end
			if want then
				buildRun(want)
			else
				clearRun()
			end
		end
		working = false
	end)
end

local function buildStatic()
	staticParts = build(STATIC_SEED, Instances.cosmetic())
	staticBuilt = true
	log.info("cosmetic world built: %d parts", staticParts)
	reconcile()
end

local function whenWorldReady(callback: () -> ())
	if ReplicatedStorage:GetAttribute(M.WorldReady) == true then
		task.spawn(callback)
		return
	end
	local connection: RBXScriptConnection? = nil
	connection = serviceTrove:Connect(ReplicatedStorage:GetAttributeChangedSignal(M.WorldReady), function()
		if ReplicatedStorage:GetAttribute(M.WorldReady) ~= true then
			return
		end
		local current = connection
		if current then
			connection = nil
			serviceTrove:Remove(current)
			task.spawn(callback)
		end
	end)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function CosmeticWorldController.Start()
	whenWorldReady(buildStatic)
end

function CosmeticWorldController.OnRunStarted(info: Types.RunInfo)
	desiredRun = info
	reconcile()
end

function CosmeticWorldController.OnRunEnded()
	desiredRun = nil
	reconcile()
end

function CosmeticWorldController.GetStats(): Stats
	return {
		staticBuilt = staticBuilt,
		staticParts = staticParts,
		runId = builtRunId,
		runParts = runParts,
		building = working,
	}
end

return CosmeticWorldController
