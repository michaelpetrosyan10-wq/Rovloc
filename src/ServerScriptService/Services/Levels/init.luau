--!strict
-- Levels: the per-level controllers (ARCHITECTURE §2, Services/Levels), registered with LevelDirector in Init.
--
--   Level0_BasementController     the basement's ambience beats (pipes, boiler surges, the ceiling, a child, debris)
--   Level1_HallwaysController     the Floor 1 classroom scare: the Creature staged in Classroom 108, the glass, the
--                                 180-degree snap, the burst, the vanish, the gate slam, the hunt
--   Level2_ScienceHallController  chemical flask restock (always two in play, never in sight) + the throw hint
--   Level3_GymnasiumController    the gym's fast stalk, locker-room sweeps and court prowls, the locker-room beats
--   Level4_FloodedPoolController  the pool: the Creature called to the water, the emergency floodlights, water beats
--   Level5_RoofController         the roof: the stairwell door smashed behind the squad, the final sprint, the finale
--                                 (the Creature revealed on the ledge by lightning, gone at the next flash) and Escaped
--
-- LevelDirector activates a level's controller when the squad is on it (after every service's BeginRun at a run's
-- start) and deactivates it when they leave or the run ends. This service gives the controllers their run (seed,
-- reset at BeginRun / EndRun) and one Heartbeat driver: each Step runs its scheduled beats on time and its own checks
-- at the rate it needs. It runs after MonsterAIService (the Creature is the run's by then) and before
-- RunLifecycleService; its EndRun runs early in reverse, so the Creature is let go before the brain shuts down.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Util.Log)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)

local Level0 = require(script.Level0_BasementController)
local Level1 = require(script.Level1_HallwaysController)
local Level2 = require(script.Level2_ScienceHallController)
local Level3 = require(script.Level3_GymnasiumController)
local Level4 = require(script.Level4_FloodedPoolController)
local Level5 = require(script.Level5_RoofController)

local log = Log.new("Levels")

local Levels = {}

Levels.Name = "Levels"
Levels.Level0 = Level0
Levels.Level1 = Level1
Levels.Level2 = Level2
Levels.Level3 = Level3
Levels.Level4 = Level4
Levels.Level5 = Level5

local serviceTrove = Trove.new()
local initialized = false
local running = false

local function protected(label: string, fn: (now: number?) -> (), now: number)
	xpcall(fn, function(err: any)
		log.warnThrottled(label, 10, "%s failed: %s\n%s", label, tostring(err), debug.traceback())
	end, now)
end

-- One step of every controller at server time `now` (the Heartbeat driver; specs call the controllers directly).
function Levels.Step(now: number?)
	if not running then
		return
	end
	local t = now or Workspace:GetServerTimeNow()
	protected("Level0", Level0.Step, t)
	protected("Level1", Level1.Step, t)
	protected("Level2", Level2.Step, t)
	protected("Level3", Level3.Step, t)
	protected("Level4", Level4.Step, t)
	protected("Level5", Level5.Step, t)
end

function Levels.Init()
	if initialized then
		return
	end
	initialized = true
	Level0.Init(serviceTrove)
	Level1.Init()
	Level3.Init()
	Level4.Init(serviceTrove)
	Level5.Init()
	LevelDirector.RegisterLevel(Level0.Controller)
	LevelDirector.RegisterLevel(Level1.Controller)
	LevelDirector.RegisterLevel(Level2.Controller)
	LevelDirector.RegisterLevel(Level3.Controller)
	LevelDirector.RegisterLevel(Level4.Controller)
	LevelDirector.RegisterLevel(Level5.Controller)
end

function Levels.Start()
	serviceTrove:Connect(RunService.Heartbeat, function()
		Levels.Step(nil)
	end)
end

function Levels.BeginRun(ctx: Types.RunContext)
	Level0.BeginRun(ctx)
	Level1.BeginRun(ctx)
	Level2.BeginRun(ctx)
	Level3.BeginRun(ctx)
	Level4.BeginRun(ctx)
	Level5.BeginRun(ctx)
	running = true
end

function Levels.EndRun()
	running = false
	Level5.EndRun()
	Level4.EndRun()
	Level3.EndRun()
	Level2.EndRun()
	Level1.EndRun()
	Level0.EndRun()
end

return table.freeze(Levels)
