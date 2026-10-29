--!strict
-- ServerMain: the one server bootstrap (docs/ARCHITECTURE.md §1, §5).
--
--   1. Net.Server.setup() creates ReplicatedStorage.Remotes before any service registers a handler.
--   2. A place-settings audit checks what scripts can read (docs/PLACE_SETUP.md). Problems that break the game are
--      written to ReplicatedStorage BootError, which the loading curtain shows; the server keeps running either way.
--   3. Every service's Init runs in list order, each in xpcall (Init never yields). The ordered list is handed to
--      RunLifecycleService, which runs BeginRun forward and EndRun in reverse.
--   4. Every Start runs in its own thread (task.spawn), so WorldService's yielding world build never holds up the
--      other services' loops.
--   5. PlayerRemoving (and BindToClose for whoever is still connected at shutdown) calls every service's
--      OnPlayerRemoving in reverse order, once per player.
--
-- Later phases append their services to SERVICES; this file and ClientMain are the only files that grow.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)

local log = Log.new("ServerMain")
local bootStarted = os.clock()

Net.Server.setup()

local AudioService = require(ServerScriptService.Services.Core.AudioService)
local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local CollisionService = require(ServerScriptService.Services.Core.CollisionService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local WorldService = require(ServerScriptService.Services.Core.WorldService)
local ZoneService = require(ServerScriptService.Services.Core.ZoneService)

local FlashlightService = require(ServerScriptService.Services.Player.FlashlightService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local LoadoutService = require(ServerScriptService.Services.Player.LoadoutService)
local MovementAuthority = require(ServerScriptService.Services.Player.MovementAuthority)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)

local BearTrapService = require(ServerScriptService.Services.Mechanics.BearTrapService)
local DoorService = require(ServerScriptService.Services.Mechanics.DoorService)
local ChemicalProjectileService = require(ServerScriptService.Services.Mechanics.ChemicalProjectileService)
local LockerHidingService = require(ServerScriptService.Services.Mechanics.LockerHidingService)
local FloodedPoolService = require(ServerScriptService.Services.Mechanics.FloodedPoolService)

local VentNetworkService = require(ServerScriptService.Services.Vents.VentNetworkService)

local CheckpointAirlockService = require(ServerScriptService.Services.Match.CheckpointAirlockService)
local MonsterAIService = require(ServerScriptService.Services.Monster.MonsterAIService)

local Levels = require(ServerScriptService.Services.Levels)

local MatchAndDataService = require(ServerScriptService.Services.Match.MatchAndDataService)
local MatchResetService = require(ServerScriptService.Services.Match.MatchResetService)
local TelemetryService = require(ServerScriptService.Services.Match.TelemetryService)
local DownedReviveService = require(ServerScriptService.Services.Match.DownedReviveService)
local SpectatorService = require(ServerScriptService.Services.Match.SpectatorService)
local LobbyService = require(ServerScriptService.Services.Match.LobbyService)
local PerkShopService = require(ServerScriptService.Services.Match.PerkShopService)

--------------------------------------------------------------------------------
-- Place-settings audit
--------------------------------------------------------------------------------

-- Fires a BindableEvent and checks whether its handler already ran: under Deferred signal behaviour it has not.
local function signalsAreDeferred(): boolean
	local probe = Instance.new("BindableEvent")
	local ran = false
	probe.Event:Connect(function()
		ran = true
	end)
	probe:Fire()
	local immediate = ran
	task.defer(function()
		probe:Destroy()
	end)
	return not immediate
end

-- Returns the problems that break the game. Problems this server can correct (or that only matter in a live
-- server) are fixed or logged here instead.
local function auditPlace(): { string }
	local problems: { string } = {}
	if Workspace.StreamingEnabled then
		table.insert(problems, "Workspace.StreamingEnabled must be false (clients must hold the whole school)")
	end
	if Players.CharacterAutoLoads then
		Players.CharacterAutoLoads = false
		log.warn("Players.CharacterAutoLoads was true; turned off for this server (set it in the place file)")
	end
	if StarterPlayer.LuaCharacterController ~= Enum.CharacterControlMode.Legacy then
		table.insert(
			problems,
			string.format(
				"StarterPlayer.LuaCharacterController is %s, expected Legacy",
				StarterPlayer.LuaCharacterController.Name
			)
		)
	end
	if Players.MaxPlayers > GameConfig.MaxSquad then
		local message = string.format(
			"server size is %d, expected at most %d (Creator Dashboard > Places > Server Size)",
			Players.MaxPlayers,
			GameConfig.MaxSquad
		)
		-- Studio test servers take their size from the Test tab, not the published place.
		if RunService:IsStudio() then
			log.warn("%s", message)
		else
			table.insert(problems, message)
		end
	end
	if not signalsAreDeferred() then
		table.insert(problems, "Workspace.SignalBehavior must be Deferred")
	end
	return problems
end

local problems = auditPlace()
if #problems > 0 then
	WorldService.ReportBootError("place settings: " .. table.concat(problems, "; "))
end

--------------------------------------------------------------------------------
-- Services
--------------------------------------------------------------------------------

-- Order is load-bearing. Init runs top to bottom; BeginRun runs top to bottom; EndRun runs bottom to top.
--   CollisionService         Init registers the collision groups before anything builds or spawns parts.
--   CharacterService         Spawning + locks; it pushes collision modes through CollisionService.
--   LevelDirector            BeginRun enters Level0, so CurrentLevel is set before anything reads it below.
--   NoiseAndDirectorService  BeginRun builds the run's SpawnPlan (bear traps, flasks, batteries, locked grates).
--                            Init subscribes to ZoneService.VolumeEntered for FloorDebris crunches (noise + an
--                            AudioService GlassCrunch cue), so ZoneService and AudioService need no run hooks of
--                            their own for it; CharacterService announces every server move to its sampler.
--   WorldService             Init clears the edit-time Workspace before any Start parents instances; Start builds
--                            the world. BeginRun spawns the planned props (needs the plan above) and the Creature at
--                            the current level's CreatureSpawn (needs LevelDirector above). Level controllers are
--                            activated only once the match is InRun, after this, so they find props in place.
--                            In reverse (EndRun) the runtime is cleared before LevelDirector deactivates the level,
--                            so controllers keep their own run troves rather than touching props in Deactivate.
--   ZoneService              10 Hz zone / volume tracking (no run hooks).
--   AudioService             Cue routing to clients.
--   RunStatsService          BeginRun resets the counters; EndRun freezes them for the summary.
--   LoadoutService           Perks from Player.Loadout; BeginRun sets syringe charges before anything reads them.
--   PlayerStateService       MoveState / stamina / oxygen authority, MoveIntent + LookRelay.
--   LifeStateService         Health + LifeState; BeginRun makes participants Alive. Owns the recovery hook.
--   MovementAuthority        10 Hz movement validation (registered validators first).
--   InteractionService       Server-timed prompt channels for every registered PromptKind handler.
--   FlashlightService        Battery + FlashlightOn; BeginRun sizes the battery from LoadoutService.
--   BearTrapService          Level 0 traps: BeginRun tracks the traps WorldService built above; 10 Hz springing,
--                            snap / solo pry / co-op rescue; EndRun (early, in reverse) frees every victim.
--   DoorService              Fixture doors (BeginRun indexes the fire doors, gate and scripted doors WorldService
--                            rebuilt above and sets their initial states); Heartbeat-stepped leaves, never crushing.
--   VentNetworkService       Vent grates (BeginRun tracks the grates WorldService rebuilt above), crawl entry / exit,
--                            the VentRail validator (MovementAuthority above), level VentGraphs for later systems.
--   CheckpointAirlockService Stairwell airlocks: 10 Hz checkpoint volume watch, straggler timer, sealing through
--                            DoorService, left-behind spectators, LevelDirector.Advance, 50% respawns at the next floor.
--   MonsterAIService         The Creature's brain: BeginRun takes over the Creature WorldService built above, reads
--                            VentNetworkService's graphs and grates; EndRun (early, in reverse) lets it go.
--   ChemicalProjectileService Level 2 flasks: BeginRun tracks the flasks WorldService built above; pickups, throws,
--                            stepped server flights, stun clouds (VentNetworkService's graphs, MonsterAIService.Stun).
--   LockerHidingService      Level 3 lockers: BeginRun tracks the lockers WorldService rebuilt above; Hide prompt,
--                            Anchor-locked hiding, server-stepped doors, the hold-breath check (MonsterAIService's
--                            locker inspector), the LockerRip hand-over to JumpscareHandler; EndRun lets everyone out.
--   FloodedPoolService       Level 4 water: who swims (Swim mode), oxygen rates, the Swim validator, the Creature's
--                            grab (MonsterAIService's PoolGrabber), drag, struggle, flask / floodlight release, drowning.
--   Levels                   The Level 0-4 controllers (registered with LevelDirector in Init): basement beats,
--                            the Floor 1 classroom scare (MonsterAIService.AcquireScripted, DoorService's gate), Level 2
--                            flask restock (ChemicalProjectileService), the Level 3 gym (MonsterAIService.SetSpeedScale /
--                            Alert, LockerHidingService's checks), the Level 4 pool (the Creature called to the water,
--                            the floodlight switch, FloodedPoolService.ReleaseGrab); EndRun (early, in reverse) lets the
--                            Creature go.
--   MatchAndDataService      Saved progress (session-locked records, serialized saves, BindToClose) and the match
--                            policy: Deploy (perk stock, BeginRun, Level 0 spawns), the RunOutcomeEvaluator over
--                            LifeStateService / Levels.Level5 escapes / leaves, rewards, RunSummary, RunResolved, Results.
--                            Init turns the Studio auto dev run off (DevToolsService.SetMatchPolicyPresent).
--   MatchResetService        Results -> Resetting -> Lobby (timer or everyone pressed Play Again), PlayAgainRequested.
--   TelemetryService         AnalyticsService funnel + custom + economy events (skipped in Studio).
--   DownedReviveService      Match layer: the teammate Revive prompt on Downed participants (InteractionService
--                            channel), LifeStateService.Revive, RunStats Revives, down / lost / revived notices.
--   SpectatorService         Match layer: SpectateReason / SpectateTargetUserId for eliminated participants, late
--                            joiners and over-capacity players (LifeStateService.SetSpectating, no body mid-run), the
--                            SpectateCycle remote; BeginRun after LifeStateService made the participants Alive.
--   LobbyService             Ready pads / LobbyAction, the difficulty vote and console, the squad cap and the
--                            countdown (RunLifecycleService.SetPhase Countdown / Lobby) into MatchAndDataService.Deploy.
--   PerkShopService          The perks console: PerkPurchase through MatchAndDataService.Update, EquipPerk /
--                            UnequipPerk (LobbyService routes them) into Player.Loadout, the PerkStock mirror.
--   RunLifecycleService      Drives the fan-out above; boots to Lobby once WorldService is ready.
--   DevToolsService          Dev commands and the Studio auto dev-run; it calls everything above.
--
-- Each entry lists exactly the lifecycle hooks the module implements, so the type checker verifies every hook's
-- signature against Types.Service. RunLifecycleService contributes only Init / Start: its public BeginRun / EndRun
-- drive the fan-out and are not lifecycle hooks.
local SERVICES: { Types.Service } = {
	{ Name = CollisionService.Name, Init = CollisionService.Init },
	{
		Name = CharacterService.Name,
		Init = CharacterService.Init,
		Start = CharacterService.Start,
		EndRun = CharacterService.EndRun,
		OnPlayerRemoving = CharacterService.OnPlayerRemoving,
	},
	{
		Name = LevelDirector.Name,
		Init = LevelDirector.Init,
		BeginRun = LevelDirector.BeginRun,
		EndRun = LevelDirector.EndRun,
	},
	{
		Name = NoiseAndDirectorService.Name,
		Init = NoiseAndDirectorService.Init,
		Start = NoiseAndDirectorService.Start,
		BeginRun = NoiseAndDirectorService.BeginRun,
		EndRun = NoiseAndDirectorService.EndRun,
		OnPlayerRemoving = NoiseAndDirectorService.OnPlayerRemoving,
	},
	{
		Name = WorldService.Name,
		Init = WorldService.Init,
		Start = WorldService.Start,
		BeginRun = WorldService.BeginRun,
		EndRun = WorldService.EndRun,
	},
	{
		Name = ZoneService.Name,
		Init = ZoneService.Init,
		Start = ZoneService.Start,
		OnPlayerRemoving = ZoneService.OnPlayerRemoving,
	},
	{ Name = AudioService.Name, Init = AudioService.Init },
	{ Name = RunStatsService.Name, BeginRun = RunStatsService.BeginRun, EndRun = RunStatsService.EndRun },
	{
		Name = LoadoutService.Name,
		Init = LoadoutService.Init,
		BeginRun = LoadoutService.BeginRun,
		EndRun = LoadoutService.EndRun,
		OnPlayerRemoving = LoadoutService.OnPlayerRemoving,
	},
	{
		Name = PlayerStateService.Name,
		Init = PlayerStateService.Init,
		Start = PlayerStateService.Start,
		BeginRun = PlayerStateService.BeginRun,
		EndRun = PlayerStateService.EndRun,
		OnPlayerRemoving = PlayerStateService.OnPlayerRemoving,
	},
	{
		Name = LifeStateService.Name,
		Init = LifeStateService.Init,
		Start = LifeStateService.Start,
		BeginRun = LifeStateService.BeginRun,
		EndRun = LifeStateService.EndRun,
		OnPlayerRemoving = LifeStateService.OnPlayerRemoving,
	},
	{
		Name = MovementAuthority.Name,
		Init = MovementAuthority.Init,
		Start = MovementAuthority.Start,
		BeginRun = MovementAuthority.BeginRun,
		EndRun = MovementAuthority.EndRun,
		OnPlayerRemoving = MovementAuthority.OnPlayerRemoving,
	},
	{
		Name = InteractionService.Name,
		Init = InteractionService.Init,
		Start = InteractionService.Start,
		EndRun = InteractionService.EndRun,
		OnPlayerRemoving = InteractionService.OnPlayerRemoving,
	},
	{
		Name = FlashlightService.Name,
		Init = FlashlightService.Init,
		BeginRun = FlashlightService.BeginRun,
		EndRun = FlashlightService.EndRun,
		OnPlayerRemoving = FlashlightService.OnPlayerRemoving,
	},
	{
		Name = BearTrapService.Name,
		Init = BearTrapService.Init,
		Start = BearTrapService.Start,
		BeginRun = BearTrapService.BeginRun,
		EndRun = BearTrapService.EndRun,
		OnPlayerRemoving = BearTrapService.OnPlayerRemoving,
	},
	{
		Name = DoorService.Name,
		Init = DoorService.Init,
		Start = DoorService.Start,
		BeginRun = DoorService.BeginRun,
		EndRun = DoorService.EndRun,
		OnPlayerRemoving = DoorService.OnPlayerRemoving,
	},
	{
		Name = VentNetworkService.Name,
		Init = VentNetworkService.Init,
		Start = VentNetworkService.Start,
		BeginRun = VentNetworkService.BeginRun,
		EndRun = VentNetworkService.EndRun,
		OnPlayerRemoving = VentNetworkService.OnPlayerRemoving,
	},
	{
		Name = CheckpointAirlockService.Name,
		Init = CheckpointAirlockService.Init,
		Start = CheckpointAirlockService.Start,
		BeginRun = CheckpointAirlockService.BeginRun,
		EndRun = CheckpointAirlockService.EndRun,
		OnPlayerRemoving = CheckpointAirlockService.OnPlayerRemoving,
	},
	{
		Name = MonsterAIService.Name,
		Init = MonsterAIService.Init,
		Start = MonsterAIService.Start,
		BeginRun = MonsterAIService.BeginRun,
		EndRun = MonsterAIService.EndRun,
		OnPlayerRemoving = MonsterAIService.OnPlayerRemoving,
	},
	{
		Name = ChemicalProjectileService.Name,
		Init = ChemicalProjectileService.Init,
		Start = ChemicalProjectileService.Start,
		BeginRun = ChemicalProjectileService.BeginRun,
		EndRun = ChemicalProjectileService.EndRun,
		OnPlayerRemoving = ChemicalProjectileService.OnPlayerRemoving,
	},
	{
		Name = LockerHidingService.Name,
		Init = LockerHidingService.Init,
		Start = LockerHidingService.Start,
		BeginRun = LockerHidingService.BeginRun,
		EndRun = LockerHidingService.EndRun,
		OnPlayerRemoving = LockerHidingService.OnPlayerRemoving,
	},
	{
		Name = FloodedPoolService.Name,
		Init = FloodedPoolService.Init,
		Start = FloodedPoolService.Start,
		BeginRun = FloodedPoolService.BeginRun,
		EndRun = FloodedPoolService.EndRun,
		OnPlayerRemoving = FloodedPoolService.OnPlayerRemoving,
	},
	{
		Name = Levels.Name,
		Init = Levels.Init,
		Start = Levels.Start,
		BeginRun = Levels.BeginRun,
		EndRun = Levels.EndRun,
	},
	{
		Name = MatchAndDataService.Name,
		Init = MatchAndDataService.Init,
		Start = MatchAndDataService.Start,
		BeginRun = MatchAndDataService.BeginRun,
		EndRun = MatchAndDataService.EndRun,
		OnPlayerRemoving = MatchAndDataService.OnPlayerRemoving,
	},
	{
		Name = MatchResetService.Name,
		Init = MatchResetService.Init,
		Start = MatchResetService.Start,
		OnPlayerRemoving = MatchResetService.OnPlayerRemoving,
	},
	{
		Name = TelemetryService.Name,
		Init = TelemetryService.Init,
		OnPlayerRemoving = TelemetryService.OnPlayerRemoving,
	},
	{
		Name = DownedReviveService.Name,
		Init = DownedReviveService.Init,
		Start = DownedReviveService.Start,
		BeginRun = DownedReviveService.BeginRun,
		EndRun = DownedReviveService.EndRun,
		OnPlayerRemoving = DownedReviveService.OnPlayerRemoving,
	},
	{
		Name = SpectatorService.Name,
		Init = SpectatorService.Init,
		BeginRun = SpectatorService.BeginRun,
		EndRun = SpectatorService.EndRun,
		OnPlayerRemoving = SpectatorService.OnPlayerRemoving,
	},
	{
		Name = LobbyService.Name,
		Init = LobbyService.Init,
		Start = LobbyService.Start,
		OnPlayerRemoving = LobbyService.OnPlayerRemoving,
	},
	{ Name = PerkShopService.Name, Init = PerkShopService.Init, Start = PerkShopService.Start },
	{ Name = RunLifecycleService.Name, Init = RunLifecycleService.Init, Start = RunLifecycleService.Start },
	{
		Name = DevToolsService.Name,
		Init = DevToolsService.Init,
		Start = DevToolsService.Start,
		OnPlayerRemoving = DevToolsService.OnPlayerRemoving,
	},
}

for _, service in SERVICES do
	local init = service.Init
	if init then
		local started = os.clock()
		xpcall(init, function(err: any)
			log.error("%s.Init failed: %s\n%s", service.Name, tostring(err), debug.traceback())
		end)
		log.debug("%s.Init %.1f ms", service.Name, (os.clock() - started) * 1000)
	end
end

RunLifecycleService.SetServices(SERVICES)

for _, service in SERVICES do
	local start = service.Start
	if start then
		task.spawn(function()
			xpcall(start, function(err: any)
				log.error("%s.Start failed: %s\n%s", service.Name, tostring(err), debug.traceback())
			end)
		end)
	end
end

--------------------------------------------------------------------------------
-- Leaving + shutdown
--------------------------------------------------------------------------------

local removed: { [Player]: boolean } = {}
setmetatable(removed, { __mode = "k" })

local function onPlayerRemoving(player: Player)
	if removed[player] then
		return
	end
	removed[player] = true
	for i = #SERVICES, 1, -1 do
		local service = SERVICES[i]
		local handler = service.OnPlayerRemoving
		if handler then
			xpcall(handler, function(err: any)
				log.error("%s.OnPlayerRemoving(%s) failed: %s", service.Name, player.Name, tostring(err))
			end, player)
		end
	end
end

Players.PlayerRemoving:Connect(onPlayerRemoving)

game:BindToClose(function()
	for _, player in Players:GetPlayers() do
		onPlayerRemoving(player)
	end
end)

log.info("%d services initialised in %.2fs; world build running", #SERVICES, os.clock() - bootStarted)
