--!strict
-- Level2_ScienceHallController: the Science Hall's chemical flasks stay in play (spec, Level 2).
--
-- Restock. While the squad is on Level 2 there are always at least MINIMUM untaken world flasks
-- (ChemicalProjectileService.CountAvailable): when there are fewer, one is built (SpawnFlask, a seeded variant) at a
-- FlaskCandidate anchor on the lab counters that no other flask stands on, that is more than MIN_DISTANCE studs from
-- every playing participant and that none of them can see, at most one every INTERVAL seconds. Nobody ever watches a
-- flask appear.
-- Hint. The first time in a run any playing participant comes within HINT_RADIUS studs of an untaken flask, every
-- participant on the level gets the Hud.FlaskStun toast (Notify), once.
--
-- Pure rules (tests/Specs/Levels.spec.luau): restockDue, pickSpot, hintDue.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)

local ChemicalProjectileService = require(ServerScriptService.Services.Mechanics.ChemicalProjectileService)

local LevelKit = require(script.Parent.LevelKit)

local log = Log.new("Level2")

local W = Attributes.World

export type Dependencies = {
	now: () -> number,
	players: () -> { Player },
	rootOf: (player: Player) -> Vector3?,
	eyeOf: (player: Player) -> Vector3?,
	lineClear: (from: Vector3, to: Vector3) -> boolean,
	countAvailable: (levelId: Enums.LevelId) -> number,
	spawnFlask: (levelId: Enums.LevelId, cframe: CFrame, variant: number) -> Model?,
	flasks: () -> { Vector3 }, -- untaken world flasks on the level
	notify: (player: Player, key: string) -> (),
}

local LEVEL: Enums.LevelId = "Level2_ScienceHall"
local CANDIDATE_KIND = "FlaskCandidate"
local MINIMUM = 2
local INTERVAL = 45
local MIN_DISTANCE = 30
local HINT_RADIUS = 10
local OCCUPIED_RADIUS = 1.5
local RESTOCK_CHECK = 1
local HINT_CHECK = 1 / GameConfig.ServerTickHz
local SIGHT_LIFT = 0.4 -- the flask's body above the worktop it stands on
local VARIANT_MAX = 999999
local HINT_KEY = "Hud.FlaskStun"

local Level2 = {}

Level2.LevelId = LEVEL
Level2.Minimum = MINIMUM
Level2.Interval = INTERVAL
Level2.MinDistance = MIN_DISTANCE
Level2.HintRadius = HINT_RADIUS
Level2.HintKey = HINT_KEY

--------------------------------------------------------------------------------
-- Pure rules
--------------------------------------------------------------------------------

-- Whether a flask should be built now: fewer than MINIMUM available and INTERVAL since the last one.
function Level2.restockDue(now: number, lastSpawnAt: number, available: number): boolean
	return available < MINIMUM and now - lastSpawnAt >= INTERVAL
end

-- A candidate (world CFrames) with no flask on it (`occupied`), more than MIN_DISTANCE from every root in `roots`
-- and unseen (`visible` tests a point), drawn with `random`; nil when there is none.
function Level2.pickSpot(
	candidates: { CFrame },
	occupied: { Vector3 },
	roots: { Vector3 },
	visible: (Vector3) -> boolean,
	random: Random
): CFrame?
	local eligible: { CFrame } = {}
	for _, cframe in candidates do
		local point = cframe.Position
		local free = true
		for _, flask in occupied do
			if (flask - point).Magnitude <= OCCUPIED_RADIUS then
				free = false
				break
			end
		end
		if free then
			for _, root in roots do
				if (root - point).Magnitude <= MIN_DISTANCE then
					free = false
					break
				end
			end
		end
		if free and not visible(point + Vector3.new(0, SIGHT_LIFT, 0)) then
			table.insert(eligible, cframe)
		end
	end
	if #eligible == 0 then
		return nil
	end
	return eligible[random:NextInteger(1, #eligible)]
end

-- Whether anyone (roots) is within HINT_RADIUS of an untaken flask.
function Level2.hintDue(roots: { Vector3 }, flasks: { Vector3 }): boolean
	for _, root in roots do
		for _, flask in flasks do
			if (root - flask).Magnitude <= HINT_RADIUS then
				return true
			end
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Dependencies + state
--------------------------------------------------------------------------------

local function worldFlasks(): { Vector3 }
	local out: { Vector3 } = {}
	local runtime = Instances.runtimeLevel(LEVEL, false)
	if not runtime then
		return out
	end
	for _, instance in CollectionService:GetTagged(Tags.ChemicalItem) do
		if
			instance:IsA("Model")
			and instance:IsDescendantOf(runtime)
			and Attributes.getNumber(instance, W.HeldByUserId, 0) == 0
		then
			table.insert(out, instance:GetPivot().Position)
		end
	end
	return out
end

local function realDependencies(): Dependencies
	return {
		now = function(): number
			return Workspace:GetServerTimeNow()
		end,
		players = function(): { Player }
			return LevelKit.playersOn(LEVEL)
		end,
		rootOf = LevelKit.rootOf,
		eyeOf = LevelKit.eyeOf,
		lineClear = LevelKit.lineClear,
		countAvailable = ChemicalProjectileService.CountAvailable,
		spawnFlask = ChemicalProjectileService.SpawnFlask,
		flasks = worldFlasks,
		notify = LevelKit.notify,
	}
end

local deps: Dependencies = realDependencies()
local candidates: { CFrame }? = nil
local random: Random = MathUtil.seededRandom(1, "L2Restock")
local active = false
local lastSpawnAt = -math.huge
local nextRestockAt = -math.huge
local nextHintAt = -math.huge
local hinted = false
local spawned = 0

local function candidateSpots(): { CFrame }
	local cached = candidates
	if cached then
		return cached
	end
	local out: { CFrame } = {}
	local layout = Builder.getLayout(LEVEL)
	if layout then
		for _, anchor in layout.anchors do
			if anchor.kind == CANDIDATE_KIND then
				table.insert(out, Builder.anchorCFrame(layout.id, anchor))
			end
		end
	else
		log.error("no %s layout; flasks are not restocked", LEVEL)
	end
	candidates = out
	return out
end

local function roots(players: { Player }): { Vector3 }
	local out: { Vector3 } = {}
	for _, player in players do
		local root = deps.rootOf(player)
		if root then
			table.insert(out, root)
		end
	end
	return out
end

local function restock(now: number, players: { Player })
	if not Level2.restockDue(now, lastSpawnAt, deps.countAvailable(LEVEL)) then
		return
	end
	local eyes = LevelKit.eyes(players, deps.eyeOf)
	local spot = Level2.pickSpot(candidateSpots(), deps.flasks(), roots(players), function(point: Vector3): boolean
		return LevelKit.seenBy(eyes, point, deps.lineClear)
	end, random)
	if not spot then
		return
	end
	local variant = random:NextInteger(1, VARIANT_MAX)
	if deps.spawnFlask(LEVEL, spot, variant) then
		lastSpawnAt = now
		spawned += 1
		log.debug("restocked a flask at %s", tostring(spot.Position))
	end
end

local function hint(players: { Player })
	if hinted or not Level2.hintDue(roots(players), deps.flasks()) then
		return
	end
	hinted = true
	for _, player in players do
		deps.notify(player, HINT_KEY)
	end
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- One step at `now` (every Heartbeat from the Levels service; specs pass a fake clock): the hint at the server tick
-- rate, the restock once a second.
function Level2.Step(now: number?)
	local t = now or deps.now()
	if not active then
		return
	end
	local players: { Player }? = nil
	if not hinted and t >= nextHintAt then
		nextHintAt = t + HINT_CHECK
		players = deps.players()
		hint(players :: { Player })
	end
	if t >= nextRestockAt then
		nextRestockAt = t + RESTOCK_CHECK
		restock(t, players or deps.players())
	end
end

function Level2.HasHinted(): boolean
	return hinted
end

function Level2.SpawnedCount(): number
	return spawned
end

function Level2.SetDependencies(fake: Dependencies?)
	deps = fake or realDependencies()
end

--------------------------------------------------------------------------------
-- Level controller + lifecycle
--------------------------------------------------------------------------------

-- LevelDirector: the squad is in the Science Hall.
function Level2.Activate(_ctx: Types.LevelContext)
	active = true
	nextRestockAt = -math.huge
	nextHintAt = -math.huge
end

-- LevelDirector: the squad left it (or the run ended).
function Level2.Deactivate()
	active = false
end

local controller: Types.LevelController = {
	LevelId = LEVEL,
	Activate = Level2.Activate,
	Deactivate = Level2.Deactivate,
}
Level2.Controller = controller

function Level2.BeginRun(ctx: Types.RunContext)
	random = MathUtil.seededRandom(ctx.seed, "L2Restock")
	active = false
	lastSpawnAt = -math.huge
	hinted = false
	spawned = 0
end

function Level2.EndRun()
	active = false
end

return table.freeze(Level2)
