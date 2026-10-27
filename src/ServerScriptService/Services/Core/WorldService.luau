--!strict
-- WorldService: owns the authoritative world. Clears the edit-time Workspace, builds the school, announces it, and
-- tracks which clients have received it; per run it spawns the planned props and the Creature.
--
-- Boot. Init destroys every Workspace child except Terrain, the Camera and player characters, and every Lighting
-- child, so a place opened from `rojo serve`, `rojo build` or a Studio save always starts from the same empty state.
-- It then creates Workspace.Runtime, before any character can exist (a character is named after its player, and a
-- player may be called "Runtime"; Instances resolves roots by name and class either way).
-- Start (runs in its own thread) calls ProceduralWorldBuilder.BuildAuthoritative(), which yields every few hundred
-- parts so the server keeps ticking, then applies the lighting baseline and sets ReplicatedStorage WorldPartCount and
-- WorldReady = true. A failed build still ends the boot (WorldReady = true, WorldPartCount = parts that exist) but
-- records the reason in ReplicatedStorage BootError, which the loading curtain shows.
--
-- Client acks. Each client's LoadingCurtain fires ClientWorldReady once it holds the world; the handler sets the
-- Player attribute WorldAcked and fires WorldAcked. CharacterService waits for it (with a timeout) before spawning.
--
-- Runs. BeginRun builds every prop in NoiseAndDirectorService's plan into Workspace.Runtime.<level> through
-- ProceduralWorldBuilder.BuildProp, rebuilds every level's fixtures (vent grates with the plan's locks, fire doors,
-- the hallway gate, lockers, the parachute crate, the floodlight switch) there through BuildFixtures, and, when a
-- "Creature" rig builder is registered, builds the Creature at the
-- CreatureSpawn anchor of LevelDirector's current level (or the next level that has one), tags it `Creature` and
-- gives the server network ownership. ServerMain orders NoiseAndDirectorService (plans) and LevelDirector (enters
-- Level0) before this service. EndRun destroys the Creature and clears Workspace.Runtime.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)

local log = Log.new("World")

local M = Attributes.Match
local P = Attributes.Player

local CREATURE_RIG = "Creature"
local POLL_SECONDS = 0.1

export type BuildResult = Builder.BuildResult

local WorldService = {}

WorldService.Name = "WorldService"

local built: Signal.Signal<BuildResult> = Signal.new()
local worldAcked: Signal.Signal<Player> = Signal.new()

WorldService.Built = built
WorldService.WorldAcked = worldAcked

local runTrove = Trove.new()

local ready = false
local buildResult: BuildResult? = nil
local creature: Model? = nil

--------------------------------------------------------------------------------
-- Boot errors
--------------------------------------------------------------------------------

-- Appends `message` to ReplicatedStorage BootError (several problems can be reported) and logs it.
function WorldService.ReportBootError(message: string)
	local existing = ReplicatedStorage:GetAttribute(M.BootError)
	local combined = if type(existing) == "string" and existing ~= "" then existing .. "; " .. message else message
	ReplicatedStorage:SetAttribute(M.BootError, combined)
	log.error("boot error: %s", message)
end

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------

local function clearEditTimeState()
	local removed = 0
	for _, child in Workspace:GetChildren() do
		if child:IsA("Terrain") or child:IsA("Camera") then
			continue
		end
		if child:IsA("Model") and Players:GetPlayerFromCharacter(child) then
			continue
		end
		local ok, err = pcall(function()
			child:Destroy()
		end)
		if ok then
			removed += 1
		else
			log.warn("could not clear Workspace.%s: %s", child.Name, tostring(err))
		end
	end
	for _, child in Lighting:GetChildren() do
		child:Destroy()
	end
	if removed > 0 then
		log.info("cleared %d edit-time Workspace children", removed)
	end
end

local function countWorldParts(): number
	local count = 0
	for _, root in { Instances.school(), Instances.lobby() } :: { Model? } do
		if not root then
			continue
		end
		for _, descendant in root:GetDescendants() do
			if descendant:IsA("BasePart") then
				count += 1
			end
		end
	end
	return count
end

local function finishBoot(result: BuildResult?)
	local partCount = if result then result.partCount else countWorldParts()
	ReplicatedStorage:SetAttribute(M.WorldPartCount, partCount)
	buildResult = result
	ready = true
	ReplicatedStorage:SetAttribute(M.WorldReady, true)
	if result then
		built:Fire(result)
	end
end

--------------------------------------------------------------------------------
-- Readiness + acks
--------------------------------------------------------------------------------

-- True once the boot build has finished (successfully or not; see BootError).
function WorldService.IsReady(): boolean
	return ready
end

-- The boot build's result, or nil before it finished or when it failed.
function WorldService.GetBuild(): BuildResult?
	return buildResult
end

-- Yields until the boot build has finished or `timeout` seconds pass. Returns IsReady().
function WorldService.WaitUntilReady(timeout: number): boolean
	local deadline = os.clock() + math.max(0, timeout)
	while not ready do
		if os.clock() >= deadline then
			return false
		end
		task.wait(POLL_SECONDS)
	end
	return true
end

function WorldService.HasAcked(player: Player): boolean
	return player:GetAttribute(P.WorldAcked) == true
end

-- Yields until `player`'s client has acknowledged the world, `timeout` seconds pass, or the player leaves.
-- Returns whether the ack arrived.
function WorldService.WaitForAck(player: Player, timeout: number): boolean
	local deadline = os.clock() + math.max(0, timeout)
	while not WorldService.HasAcked(player) do
		if player.Parent ~= Players or os.clock() >= deadline then
			return false
		end
		task.wait(POLL_SECONDS)
	end
	return true
end

local function onClientWorldReady(player: Player, payload: any)
	local message = payload :: Types.ClientWorldReadyPayload
	if WorldService.HasAcked(player) then
		return
	end
	player:SetAttribute(P.WorldAcked, true)
	local expected = ReplicatedStorage:GetAttribute(M.WorldPartCount)
	log.info(
		"%s received the world (%d of %s parts)",
		player.Name,
		message.partCount,
		if type(expected) == "number" then tostring(expected) else "?"
	)
	worldAcked:Fire(player)
end

--------------------------------------------------------------------------------
-- Runs
--------------------------------------------------------------------------------

local function spawnProps(ctx: Types.RunContext)
	local plan = NoiseAndDirectorService.GetPlan()
	if not plan then
		log.warn("run %s has no spawn plan; no props placed", ctx.runId)
		return
	end
	local placed, skipped = 0, 0
	for _, prop in plan.props do
		local parent = Instances.runtimeLevel(prop.levelId, true)
		if not parent then
			skipped += 1
			continue
		end
		local random = MathUtil.seededRandom(plan.seed, "prop:" .. prop.kind .. ":" .. prop.anchorId)
		if Builder.BuildProp(prop, parent, random) then
			placed += 1
		else
			skipped += 1
		end
	end
	log.info("run %s: %d props placed, %d without a builder", ctx.runId, placed, skipped)
end

-- Fresh fixtures for every school level (grate locks from the plan; none locked without one).
local function spawnFixtures(ctx: Types.RunContext)
	local plan = NoiseAndDirectorService.GetPlan()
	local seed = if plan then plan.seed else ctx.seed
	local total = 0
	for _, levelId: Enums.LevelId in Enums.LevelId do
		local parent = Instances.runtimeLevel(levelId, true)
		if parent then
			total += Builder.BuildFixtures(levelId, parent, plan, seed)
		end
	end
	log.info("run %s: %d fixtures built", ctx.runId, total)
end

-- The first CreatureSpawn anchor at or after `levelId` in run order.
local function creatureSpawn(levelId: Enums.LevelId): (CFrame?, Enums.LevelId?)
	local start = Enums.levelIndex(levelId) or 1
	for i = start, #Enums.LevelId do
		local candidate: Enums.LevelId = Enums.LevelId[i]
		local layout = Builder.getLayout(candidate)
		if not layout then
			continue
		end
		for _, anchor in layout.anchors do
			if anchor.kind == "CreatureSpawn" then
				return Builder.anchorCFrame(candidate, anchor), candidate
			end
		end
	end
	return nil, nil
end

-- Server ownership for every unanchored assembly of `model` that sits in Workspace.
local function claimOwnership(model: Model)
	local claimed: { [BasePart]: boolean } = {}
	for _, descendant in model:GetDescendants() do
		if not descendant:IsA("BasePart") or descendant.Anchored or not descendant:IsDescendantOf(Workspace) then
			continue
		end
		local root = descendant.AssemblyRootPart or descendant
		if claimed[root] or root.Anchored then
			continue
		end
		claimed[root] = true
		local allowed = root:CanSetNetworkOwnership()
		if allowed then
			root:SetNetworkOwner(nil)
		end
	end
end

local function spawnCreature()
	if not Builder.HasRig(CREATURE_RIG) then
		log.debug("no %s rig registered; the run has no Creature", CREATURE_RIG)
		return
	end
	local cframe, levelId = creatureSpawn(LevelDirector.GetCurrentLevel() or Enums.LevelId[1])
	if not cframe or not levelId then
		log.warn("no CreatureSpawn anchor on or after the current level; the Creature was not placed")
		return
	end
	local model = Builder.BuildRig(CREATURE_RIG, Workspace, cframe)
	if not model then
		return
	end
	model.Name = Instances.Names.Creature
	model:SetAttribute(Attributes.Creature.LevelId, levelId)
	model:AddTag(Tags.Creature)
	claimOwnership(model)
	creature = model
	runTrove:Add(model)
	log.info("Creature placed on %s", levelId)
end

-- The run's Creature (nil when none was built).
function WorldService.GetCreature(): Model?
	local model = creature
	if model and model.Parent then
		return model
	end
	return nil
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function WorldService.Init()
	ReplicatedStorage:SetAttribute(M.WorldReady, false)
	ReplicatedStorage:SetAttribute(M.WorldPartCount, 0)
	clearEditTimeState()
	Instances.ensureRuntime()
	Net.Server.on("ClientWorldReady", onClientWorldReady)
end

function WorldService.Start()
	local result: BuildResult? = nil
	local failure: string? = nil
	xpcall(function()
		result = Builder.BuildAuthoritative()
	end, function(err: any)
		failure = tostring(err)
		log.error("world build failed: %s\n%s", tostring(err), debug.traceback())
	end)
	xpcall(Builder.ApplyLighting, function(err: any)
		log.error("lighting baseline failed: %s", tostring(err))
	end)
	local completed = result
	if failure then
		WorldService.ReportBootError("world build failed: " .. failure)
	elseif completed and completed.partCount <= 0 then
		WorldService.ReportBootError("the world build produced no parts")
	end
	finishBoot(completed)
end

function WorldService.BeginRun(ctx: Types.RunContext)
	runTrove:Clean()
	creature = nil
	spawnProps(ctx)
	spawnFixtures(ctx)
	spawnCreature()
end

function WorldService.EndRun()
	runTrove:Clean()
	creature = nil
	Builder.ClearRuntime()
end

return WorldService
