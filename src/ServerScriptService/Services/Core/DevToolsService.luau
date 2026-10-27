--!strict
-- DevToolsService: the dev-command console and the Studio dev-run harness.
--
-- Commands arrive on the DevCommand remote ({ command, args }) and run only for players whose DevTools attribute is
-- true (Studio, GameConfig.DevAllowlistUserIds, or the experience owner when GameConfig.DevToolsForCreator is on;
-- CharacterService sets it). Replies go back on Notify:
-- "Dev.Ok" (args = { reply }), "Dev.Unknown" (args = { command }) or "Dev.Denied". Later phases add commands with
-- Register(command, help, handler, readOnly?); a handler returns the reply text (or nil for a plain "ok").
--
-- Built-ins:
--   devrun [Standard|Nightmare] [seed]   start a run with every player and spawn them at Level0 PlayerSpawn anchors
--   endrun                               end the run (CharacterService returns everyone to the lobby)
--   level <LevelId|0-5|next>             enter that level (starting a dev run first if none) and move every player to
--                                        its entry room (PlayerSpawn anchors there, else the room centre)
--   next                                 same as `level next`
--   noise <NoiseKind>                    emit that noise at the caller (radius from NoiseConfig)
--   sound <Preset> [2d] | stop | list    audition a SynthPresets recipe: 3D six studs ahead of the caller, or 2D for
--                                        the caller only; looped presets fade out after 6 s (one audition per player:
--                                        a new one stops the previous loop)
--   plan                                 DevOverlay "Plan" markers for the current level: every planned prop (kind
--                                        per point) and every grate the director locked, plus that level's counts
--   help                                 list commands
--
-- Dev taint. Every command that is not registered read-only (devrun, level, next, noise and, by default, every
-- later-phase command) sets ReplicatedStorage DevRun = true when a run exists after it ran, whoever started that run.
-- DevRun stays true until the match is back in the Lobby phase, so MatchAndDataService (P8) still sees it while it
-- settles the run and must not award a DevRun run (Attributes.Match.DevRun). Read-only built-ins: plan, sound, help.
--
-- AutoDevRun. In Studio, unless a match policy has called SetMatchPolicyPresent(true) (P8 MatchAndDataService does),
-- a Standard dev run starts 4 s after the first client acknowledges the world, so pressing Play drops you straight
-- into the basement.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local AudioService = require(ServerScriptService.Services.Core.AudioService)
local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local RunDirector = require(ServerScriptService.Services.Core.NoiseAndDirectorService.RunDirector)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local WorldService = require(ServerScriptService.Services.Core.WorldService)

local log = Log.new("DevTools")

local M = Attributes.Match
local P = Attributes.Player

local AUTO_RUN_DELAY = 4
local PLAN_OVERLAY_SECONDS = 20
local MAX_COMMAND_LENGTH = 32
local AUDITION_LOOP_SECONDS = 6
local AUDITION_DISTANCE = 6
local AUDITION_STOP_FADE = 0.3
local LOCKED_GRATE_KIND = "LockedGrate"
local VENT_NODE_ROOT = "VentNodeRoot"
local GRATE_PREFIX = "Grate_"

export type Handler = (player: Player, args: { string }) -> string?

type Command = {
	name: string,
	help: string,
	handler: Handler,
	readOnly: boolean,
}

-- One Plan overlay: points[i] is a marker of kind kinds[i] (a prop kind, or "LockedGrate").
export type PlanOverlay = {
	points: { Vector3 },
	kinds: { string },
	label: string,
}

export type DevRunArgs = {
	difficulty: Enums.Difficulty,
	seed: number?,
}

local DevToolsService = {}

DevToolsService.Name = "DevToolsService"
DevToolsService.AutoRunDelay = AUTO_RUN_DELAY
DevToolsService.AuditionLoopSeconds = AUDITION_LOOP_SECONDS
DevToolsService.LockedGrateKind = LOCKED_GRATE_KIND

local serviceTrove = Trove.new()

local commands: { [string]: Command } = {}
local matchPolicyPresent = false
local autoRunScheduled = false
local devRunId: string? = nil
local auditions: { [Player]: AudioService.CueHandle } = {}

--------------------------------------------------------------------------------
-- Pure helpers (specs: tests/Specs/CoreServices.spec.luau)
--------------------------------------------------------------------------------

-- `devrun` arguments in any order: a difficulty name (any case) and/or a number (the seed).
function DevToolsService.parseDevRunArgs(args: { string }): DevRunArgs
	local parsed: DevRunArgs = { difficulty = "Standard", seed = nil }
	for _, arg in args do
		local number = tonumber(arg)
		if number ~= nil then
			parsed.seed = number
			continue
		end
		local lowered = string.lower(arg)
		for _, difficulty: Enums.Difficulty in Enums.Difficulty do
			if string.lower(difficulty) == lowered then
				parsed.difficulty = difficulty
			end
		end
	end
	return parsed
end

-- A level from `level` input: an index 0-5, a full LevelId, or its "LevelN" prefix (any case). nil when unknown.
function DevToolsService.parseLevel(arg: string?): Enums.LevelId?
	if arg == nil or arg == "" then
		return nil
	end
	local number = tonumber(arg)
	if number ~= nil then
		if number % 1 ~= 0 then
			return nil
		end
		return Enums.LevelId[number + 1]
	end
	local lowered = string.lower(arg)
	for _, levelId: Enums.LevelId in Enums.LevelId do
		local id = string.lower(levelId)
		if id == lowered or string.split(id, "_")[1] == lowered then
			return levelId
		end
	end
	return nil
end

-- A NoiseKind from input (any case), or nil.
function DevToolsService.parseNoiseKind(arg: string?): Enums.NoiseKind?
	if arg == nil then
		return nil
	end
	local lowered = string.lower(arg)
	for _, kind: Enums.NoiseKind in Enums.NoiseKind do
		if string.lower(kind) == lowered then
			return kind
		end
	end
	return nil
end

-- A preset name from input: an exact name in any case, else the only name starting with it (any case). nil when
-- unknown or ambiguous.
function DevToolsService.parsePreset(arg: string?, names: { string }): string?
	if arg == nil or arg == "" then
		return nil
	end
	local lowered = string.lower(arg)
	local prefixed: string? = nil
	local prefixCount = 0
	for _, name in names do
		local candidate = string.lower(name)
		if candidate == lowered then
			return name
		end
		if string.sub(candidate, 1, #lowered) == lowered then
			prefixed = name
			prefixCount += 1
		end
	end
	return if prefixCount == 1 then prefixed else nil
end

-- The Plan overlay for `levelId` (every level when nil): one marker per planned prop (its kind) and per grate the
-- plan locked there ("LockedGrate", at `gratePosition`), and a label with the level's prop counts and its
-- locked / lockable grate counts.
function DevToolsService.planOverlay(
	plan: Types.SpawnPlan,
	levelId: Enums.LevelId?,
	gratePosition: (layoutId: Enums.LevelId, grate: LayoutSchema.GrateSpec) -> Vector3?
): PlanOverlay
	local points: { Vector3 } = {}
	local kinds: { string } = {}
	local counts: { [string]: number } = {}
	for _, prop in plan.props do
		if levelId == nil or prop.levelId == levelId then
			table.insert(points, prop.cframe.Position)
			table.insert(kinds, prop.kind)
			counts[prop.kind] = (counts[prop.kind] or 0) + 1
		end
	end
	local locked, lockable = 0, 0
	for _, id: Enums.LevelId in Enums.LevelId do
		if levelId ~= nil and id ~= levelId then
			continue
		end
		local layout = Builder.getLayout(id)
		if not layout then
			continue
		end
		lockable += #RunDirector.lockableGrates(layout)
		local vents = layout.vents
		for _, grate in (if vents then vents.grates else {}) :: { LayoutSchema.GrateSpec } do
			if plan.lockedGrates[grate.id] then
				locked += 1
				local position = gratePosition(id, grate)
				if position then
					table.insert(points, position)
					table.insert(kinds, LOCKED_GRATE_KIND)
				end
			end
		end
	end
	local parts: { string } = {}
	for kind, count in counts do
		table.insert(parts, string.format("%d %s", count, kind))
	end
	table.sort(parts)
	local label = string.format(
		"%s: %s | grates %d/%d locked",
		levelId or "all levels",
		if #parts > 0 then table.concat(parts, ", ") else "no props",
		locked,
		lockable
	)
	return { points = points, kinds = kinds, label = label }
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function notify(player: Player, key: string, args: { string })
	local payload: Types.NotifyPayload = { key = key, args = args }
	Net.Server.fire("Notify", player, payload)
end

local function isAllowed(player: Player): boolean
	return player:GetAttribute(P.DevTools) == true
end

local function inRunPhase(): boolean
	local phase = RunLifecycleService.GetPhase()
	return phase == "InRun" or phase == "Deploying"
end

-- Marks the run in progress (if any) as dev-tainted.
local function taintRun()
	if RunLifecycleService.GetRun() then
		ReplicatedStorage:SetAttribute(M.DevRun, true)
	end
end

-- World position of `grate`'s opening: its Grate_<id> attachment in the built level, else its vent node.
local function gratePosition(levelId: Enums.LevelId, grate: LayoutSchema.GrateSpec): Vector3?
	local vents = Instances.layoutChild(levelId, Instances.Names.Vents)
	local nodeRoot = if vents then vents:FindFirstChild(VENT_NODE_ROOT) else nil
	if nodeRoot and nodeRoot:IsA("BasePart") then
		local attachment = nodeRoot:FindFirstChild(GRATE_PREFIX .. grate.id)
		if attachment and attachment:IsA("Attachment") then
			return (nodeRoot.CFrame * attachment.CFrame).Position
		end
	end
	local layout = Builder.getLayout(levelId)
	local network = if layout then layout.vents else nil
	if not network then
		return nil
	end
	for _, node in network.nodes do
		if node.id == grate.node then
			local y = node.y or WorldConfig.VentCenterHeight
			return WorldConfig.levelOrigin(levelId) + Vector3.new(node.x, y, node.z)
		end
	end
	return nil
end

local function stopAudition(player: Player)
	local handle = auditions[player]
	auditions[player] = nil
	if handle then
		handle:Stop(AUDITION_STOP_FADE)
	end
end

-- Spawns `player` at `cframe` once their client holds the world (or GameConfig.ClientAckTimeout passed): a client
-- simulates its own character, so spawning it before the floor arrived would drop it through the level. Yields.
local function spawnWhenReady(player: Player, cframe: CFrame)
	WorldService.WaitForAck(player, GameConfig.ClientAckTimeout)
	if player.Parent ~= Players then
		return
	end
	-- CharacterService announces the move to the noise sampler itself.
	CharacterService.Spawn(player, cframe)
end

-- Spawns every participant at `layoutId`'s spawn slots (in parallel; each spawn yields on the avatar build).
local function spawnAll(players: { Player }, layoutId: Enums.LayoutId)
	for index, player in players do
		task.spawn(spawnWhenReady, player, CharacterService.SpawnCFrame(layoutId, index))
	end
end

-- Starts a run with every player and spawns the participants at `spawnLevel`'s spawn slots.
local function startDevRun(difficulty: Enums.Difficulty, seed: number?, spawnLevel: Enums.LevelId): Types.RunContext
	local ctx = RunLifecycleService.BeginRun(Players:GetPlayers(), difficulty, seed)
	devRunId = ctx.runId
	taintRun()
	spawnAll(ctx.participants, spawnLevel)
	return ctx
end

-- Moves every player into `levelId`'s entry room. Players without a character, or whose character is still being
-- built (it would land at the old spot), get a fresh one there instead.
local function moveSquadTo(levelId: Enums.LevelId)
	for index, player in Players:GetPlayers() do
		local cframe = CharacterService.SpawnCFrame(levelId, index)
		-- Teleport announces the move to the noise sampler (no footstep, no suspicious-step report).
		if CharacterService.IsSpawning(player) or not CharacterService.Teleport(player, cframe) then
			task.spawn(spawnWhenReady, player, cframe)
		end
	end
end

local function enterLevel(levelId: Enums.LevelId): string
	if not RunLifecycleService.GetRun() or not inRunPhase() then
		local ctx = startDevRun("Standard", nil, levelId)
		if levelId ~= Enums.LevelId[1] and not LevelDirector.EnterLevel(levelId) then
			return string.format("dev run %s started, but %s could not be entered", ctx.runId, levelId)
		end
		return string.format("dev run %s started on %s", ctx.runId, levelId)
	end
	if not LevelDirector.EnterLevel(levelId) then
		return "could not enter " .. levelId
	end
	moveSquadTo(levelId)
	return "entered " .. levelId
end

local function levelCommand(args: { string }): string
	local arg = args[1]
	if arg and string.lower(arg) == "next" then
		local currentLevel: Enums.LevelId? = LevelDirector.GetCurrentLevel()
		local nextLevel: Enums.LevelId? = if currentLevel
			then LevelDirector.nextLevel(currentLevel)
			else Enums.LevelId[1]
		if not nextLevel then
			return "already on the last level"
		end
		return enterLevel(nextLevel)
	end
	local levelId: Enums.LevelId? = DevToolsService.parseLevel(arg)
	if not levelId then
		return "usage: level <0-5|" .. table.concat(Enums.LevelId, "|") .. "|next>"
	end
	return enterLevel(levelId)
end

--------------------------------------------------------------------------------
-- Registry
--------------------------------------------------------------------------------

-- Adds (or replaces) a dev command. `command` is matched case-insensitively. Unless `readOnly` is true, running it
-- while a run exists marks that run dev-tainted (ReplicatedStorage DevRun): pass readOnly only for commands that
-- change nothing a run's outcome could depend on (overlays, auditions, help text).
function DevToolsService.Register(command: string, help: string, handler: Handler, readOnly: boolean?)
	local name = string.lower(command)
	if name == "" or #name > MAX_COMMAND_LENGTH or string.find(name, "%s") then
		log.error("Register: invalid command name %q", command)
		return
	end
	if commands[name] then
		log.warn("dev command %s replaced", name)
	end
	commands[name] = { name = name, help = help, handler = handler, readOnly = readOnly == true }
end

-- P8's match policy calls this so the Studio auto dev-run stays out of the way of the real lobby.
function DevToolsService.SetMatchPolicyPresent(present: boolean)
	matchPolicyPresent = present
end

-- Runs `command` for `player` as if it arrived on DevCommand (permission included). Returns the Notify key and
-- reply args that were sent.
function DevToolsService.Execute(player: Player, command: string, args: { string }): (string, { string })
	if not isAllowed(player) then
		notify(player, "Dev.Denied", {})
		return "Dev.Denied", {}
	end
	local name = string.lower(command)
	local entry = commands[name]
	if not entry then
		notify(player, "Dev.Unknown", { command })
		return "Dev.Unknown", { command }
	end
	local reply: string? = nil
	local failed: string? = nil
	xpcall(function()
		reply = entry.handler(player, args)
	end, function(err: any)
		failed = tostring(err)
		log.error("dev command %s failed: %s\n%s", name, tostring(err), debug.traceback())
	end)
	if not entry.readOnly then
		taintRun()
	end
	local text = if failed then name .. " failed: " .. failed else reply or (name .. ": ok")
	log.info("%s ran %s %s -> %s", player.Name, name, table.concat(args, " "), text)
	notify(player, "Dev.Ok", { text })
	return "Dev.Ok", { text }
end

--------------------------------------------------------------------------------
-- Built-in commands
--------------------------------------------------------------------------------

local function registerBuiltIns()
	DevToolsService.Register(
		"devrun",
		"devrun [Standard|Nightmare] [seed]: start a run with everyone in the basement",
		function(_player: Player, args: { string }): string?
			local parsed = DevToolsService.parseDevRunArgs(args)
			local ctx = startDevRun(parsed.difficulty, parsed.seed, Enums.LevelId[1])
			return string.format("run %s started (%s, seed %d)", ctx.runId, ctx.difficulty, ctx.seed)
		end
	)

	DevToolsService.Register("endrun", "endrun: end the run and return to the lobby", function(): string?
		if not RunLifecycleService.GetRun() then
			return "no run in progress"
		end
		RunLifecycleService.EndRun()
		return "run ended"
	end)

	DevToolsService.Register(
		"level",
		"level <0-5|LevelId|next>: jump the squad to a level",
		function(_player: Player, args: { string }): string?
			return levelCommand(args)
		end
	)

	DevToolsService.Register("next", "next: jump the squad to the next level", function(): string?
		return levelCommand({ "next" })
	end)

	DevToolsService.Register(
		"noise",
		"noise <NoiseKind>: emit a noise where you stand",
		function(player: Player, args: { string }): string?
			local kind: Enums.NoiseKind? = DevToolsService.parseNoiseKind(args[1])
			if not kind then
				return "usage: noise <" .. table.concat(Enums.NoiseKind, "|") .. ">"
			end
			local root = Instances.characterRoot(player)
			if not root then
				return "you have no character"
			end
			local event = NoiseAndDirectorService.Emit(root.Position, kind, { sourcePlayer = player })
			return string.format("%s noise, radius %g, %s", kind, event.radius, event.levelId or "no level")
		end
	)

	DevToolsService.Register(
		"sound",
		"sound <Preset> [2d] | sound stop | sound list [filter]: audition a synth preset (loops stop after 6 s)",
		function(player: Player, args: { string }): string?
			local names = SynthPresets.names()
			local first = args[1]
			local lowered = if first then string.lower(first) else ""
			if lowered == "" then
				return string.format("usage: sound <Preset> [2d] | stop | list [filter] (%d presets)", #names)
			end
			if lowered == "stop" then
				stopAudition(player)
				return "audition stopped"
			end
			if lowered == "list" then
				local filter = if args[2] then string.lower(args[2]) else nil
				local listed: { string } = {}
				for _, name in names do
					if filter == nil or string.find(string.lower(name), filter, 1, true) then
						table.insert(listed, name)
					end
				end
				return string.format("%d presets: %s", #listed, table.concat(listed, ", "))
			end
			local preset = DevToolsService.parsePreset(first, names)
			if not preset then
				return string.format("unknown or ambiguous preset %s (try: sound list %s)", first, first)
			end
			local flat = args[2] ~= nil and string.lower(args[2]) == "2d"
			local looped = SynthPresets.isLooped(preset)
			local options: AudioService.CueOptions = { duration = if looped then AUDITION_LOOP_SECONDS else nil }
			stopAudition(player)
			local handle: AudioService.CueHandle? = nil
			if flat then
				handle = AudioService.PlayFor(player, preset, options)
			else
				local root = Instances.characterRoot(player)
				if not root then
					return "you have no character (use: sound " .. preset .. " 2d)"
				end
				local look = root.CFrame.LookVector
				local ahead = Vector3.new(look.X, 0, look.Z)
				local forward = if ahead.Magnitude > 1e-3 then ahead.Unit else Vector3.new(0, 0, -1)
				handle = AudioService.PlayAt(preset, root.Position + forward * AUDITION_DISTANCE, options)
			end
			if not handle then
				return "could not play " .. preset
			end
			if looped then
				auditions[player] = handle
			end
			return string.format(
				"%s: %s, %s",
				preset,
				if flat then "2D" else string.format("3D, %d studs ahead", AUDITION_DISTANCE),
				if looped then string.format("loop, fades out in %d s", AUDITION_LOOP_SECONDS) else "one-shot"
			)
		end,
		true
	)

	DevToolsService.Register(
		"plan",
		"plan: show this level's planned props and locked grates",
		function(player: Player): string?
			local plan = NoiseAndDirectorService.GetPlan()
			if not plan then
				return "no spawn plan (start a run first)"
			end
			local overlay = DevToolsService.planOverlay(plan, LevelDirector.GetCurrentLevel(), gratePosition)
			local payload: Types.DevOverlayPayload = {
				kind = "Plan",
				points = overlay.points,
				kinds = overlay.kinds,
				label = overlay.label,
				duration = PLAN_OVERLAY_SECONDS,
			}
			Net.Server.fire("DevOverlay", player, payload)
			return string.format("%s (%d re-rolls this run)", overlay.label, plan.rerolls)
		end,
		true
	)

	DevToolsService.Register("help", "help: list dev commands", function(): string?
		local names: { string } = {}
		for name in commands do
			table.insert(names, name)
		end
		table.sort(names)
		local lines: { string } = {}
		for _, name in names do
			table.insert(lines, commands[name].help)
		end
		return table.concat(lines, "\n")
	end, true)
end

--------------------------------------------------------------------------------
-- AutoDevRun (Studio only)
--------------------------------------------------------------------------------

local function autoRun()
	if matchPolicyPresent or RunLifecycleService.GetRun() then
		return
	end
	local phase = RunLifecycleService.GetPhase()
	if phase ~= "Lobby" and phase ~= "Booting" then
		return
	end
	local ctx = startDevRun("Standard", nil, Enums.LevelId[1])
	log.info("auto dev run %s started (seed %d)", ctx.runId, ctx.seed)
end

local function scheduleAutoRun()
	if autoRunScheduled or matchPolicyPresent or not RunService:IsStudio() then
		return
	end
	autoRunScheduled = true
	serviceTrove:Delay(AUTO_RUN_DELAY, function()
		xpcall(autoRun, function(err: any)
			log.error("auto dev run failed: %s", tostring(err))
		end)
	end)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function onDevCommand(player: Player, payload: any)
	local message = payload :: Types.DevCommandPayload
	DevToolsService.Execute(player, message.command, message.args)
end

function DevToolsService.Init()
	registerBuiltIns()
	Net.Server.on("DevCommand", onDevCommand)
	serviceTrove:Add(WorldService.WorldAcked:Connect(function(_player: Player)
		scheduleAutoRun()
	end))
	serviceTrove:Add(RunLifecycleService.RunEnded:Connect(function()
		devRunId = nil
	end))
	-- The taint outlives RunEnded / Results / Resetting (the match policy settles the run there) and clears in the Lobby.
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(function(phase: Enums.MatchPhase)
		if phase == "Lobby" then
			ReplicatedStorage:SetAttribute(M.DevRun, false)
		end
	end))
end

function DevToolsService.Start()
	ReplicatedStorage:SetAttribute(M.DevRun, false)
	for _, player in Players:GetPlayers() do
		if WorldService.HasAcked(player) then
			scheduleAutoRun()
			break
		end
	end
end

-- The id of the run started from DevTools, while it is in progress.
function DevToolsService.GetDevRunId(): string?
	return devRunId
end

function DevToolsService.OnPlayerRemoving(player: Player)
	auditions[player] = nil
end

return DevToolsService
