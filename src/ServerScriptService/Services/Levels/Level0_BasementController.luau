--!strict
-- Level0_BasementController: the basement's ambience beats (spec, Level 0: no Creature down here; the bear traps
-- are BearTrapService's). While the squad is on Level 0 a seeded director plays a scare every INTERVAL_MIN..
-- INTERVAL_MAX seconds, never the same kind twice in a row, from a point BAND_MIN..BAND_MAX studs (horizontally) from
-- a randomly drawn playing participant that no participant can see (behind walls, pillars, round corners):
--   PipeBang       a bang in the overhead pipes (under the ceiling),
--   BoilerSurge    a boiler roaring up, the lit bulbs within SURGE_RADIUS of it stuttering with it (LightingController
--                  overrides through the timeline's lightScale tracks; only working bulbs, never the broken ones),
--   CeilingDrag    something dragged across the ceiling void, moving away from that player,
--   ChildVoice     a child's whisper or giggle somewhere in the dark,
--   FallingObject  something knocked loose clattering to the floor, with the FallingObject noise where it lands.
-- Each beat is one OneShot Timeline (Scenes) the clients play positionally. A beat that falls due within TRAP_GAP
-- seconds of a TrapSnap waits until TRAP_GAP has passed (a trap snapping is scare enough). When no kind can be placed
-- (nobody playing, nowhere out of sight in the band) it tries again RETRY seconds later.
--
-- Dev command: beat [kind] (play one now, placed around you).
--
-- Pure rules (tests/Specs/Levels.spec.luau): candidates, pickBeat, nextDelay, dueAfterTrap, place, surgeLights.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Scenes = require(ReplicatedStorage.Shared.Sequence.Scenes)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)

local LevelKit = require(script.Parent.LevelKit)

local log = Log.new("Level0")

local W = Attributes.World

type BeatKind = Scenes.BeatKind
type Schedule = LevelKit.Schedule

export type Candidates = {
	ceiling: { Vector3 }, -- under the ceilings (pipes, the ceiling void)
	floor: { Vector3 }, -- just above the floors
	voice: { Vector3 }, -- a child's head height
	boilers: { Vector3 }, -- the boilers' glow fixtures
}

export type LitFixture = { id: string, position: Vector3 }

-- A placed beat: where it sounds (and, for a moving one, where it ends).
export type Placement = { from: Vector3, to: Vector3? }

export type Dependencies = {
	now: () -> number,
	players: () -> { Player },
	rootOf: (player: Player) -> Vector3?,
	eyeOf: (player: Player) -> Vector3?,
	lineClear: (from: Vector3, to: Vector3) -> boolean,
	lights: () -> { LitFixture }, -- working fixtures on the level
	oneShot: (kind: Enums.OneShotKind, startAt: number, args: { [string]: Types.OneShotArg }, subject: Instance?) -> (),
	emit: (position: Vector3, kind: Enums.NoiseKind) -> (),
}

local LEVEL: Enums.LevelId = "Level0_Basement"
local INTERVAL_MIN = 25
local INTERVAL_MAX = 50
local BAND_MIN = 25
local BAND_MAX = 45
local TRAP_GAP = 8
local RETRY = 4
local SURGE_RADIUS = 34
local GRID = 10
local INSET = 3
local CEILING_DROP = 1.2
local FLOOR_LIFT = 0.4
local VOICE_HEIGHT = 3.2
local LEAD = GameConfig.OneShotLead
local TIMELINE_KIND: Enums.OneShotKind = "Timeline"
local FALL_NOISE: Enums.NoiseKind = "FallingObject"
local TRAP_NOISE: Enums.NoiseKind = "TrapSnap"
local SKIPPED_ROOMS: { [string]: boolean } = { Airlock = true }
local ARGS = Scenes.Args
local LIGHT_ARGS: { string } = { ARGS.Light1, ARGS.Light2, ARGS.Light3, ARGS.Light4 }

local Level0 = {}

Level0.LevelId = LEVEL
Level0.IntervalMin = INTERVAL_MIN
Level0.IntervalMax = INTERVAL_MAX
Level0.BandMin = BAND_MIN
Level0.BandMax = BAND_MAX
Level0.TrapGap = TRAP_GAP
Level0.Retry = RETRY
Level0.SurgeRadius = SURGE_RADIUS

--------------------------------------------------------------------------------
-- Pure rules
--------------------------------------------------------------------------------

-- Where beats can sound on `layout` (world points): a GRID-stud lattice over every room but the stair airlock, under
-- the ceiling, at child height and just above the floor, plus the boilers' glow fixtures.
function Level0.candidates(layout: LayoutSchema.LevelLayout): Candidates
	local origin = WorldConfig.levelOrigin(layout.id)
	local out: Candidates = { ceiling = {}, floor = {}, voice = {}, boilers = {} }
	for _, room in layout.rooms do
		if SKIPPED_ROOMS[room.kind] then
			continue
		end
		local r = room.rect
		local height = LayoutSchema.roomHeight(layout, room)
		local nx = math.max(1, math.floor((r.w - 2 * INSET) / GRID) + 1)
		local nz = math.max(1, math.floor((r.d - 2 * INSET) / GRID) + 1)
		for i = 0, nx - 1 do
			for j = 0, nz - 1 do
				local x = if nx == 1 then r.x + r.w / 2 else r.x + INSET + (r.w - 2 * INSET) * i / (nx - 1)
				local z = if nz == 1 then r.z + r.d / 2 else r.z + INSET + (r.d - 2 * INSET) * j / (nz - 1)
				table.insert(out.ceiling, origin + Vector3.new(x, height - CEILING_DROP, z))
				table.insert(out.voice, origin + Vector3.new(x, VOICE_HEIGHT, z))
				table.insert(out.floor, origin + Vector3.new(x, FLOOR_LIFT, z))
			end
		end
		for _, light in (room.lights or {}) :: { LayoutSchema.Light } do
			if light.kind == "BoilerGlow" then
				table.insert(out.boilers, origin + light.pos)
			end
		end
	end
	return out
end

-- A beat kind drawn from `allowed`, never `previous` (nil when nothing else is allowed).
function Level0.pickBeat(random: Random, previous: BeatKind?, allowed: { BeatKind }): BeatKind?
	local pool: { BeatKind } = {}
	for _, kind in allowed do
		if kind ~= previous then
			table.insert(pool, kind)
		end
	end
	if #pool == 0 then
		return nil
	end
	return pool[random:NextInteger(1, #pool)]
end

-- Seconds until the next beat.
function Level0.nextDelay(random: Random): number
	return random:NextNumber(INTERVAL_MIN, INTERVAL_MAX)
end

-- When a beat due at `due` may play, given the last TrapSnap at `lastTrapAt`.
function Level0.dueAfterTrap(due: number, lastTrapAt: number): number
	return math.max(due, lastTrapAt + TRAP_GAP)
end

local function poolFor(kind: BeatKind, candidates: Candidates): { Vector3 }
	if kind == "BoilerSurge" then
		return candidates.boilers
	elseif kind == "ChildVoice" then
		return candidates.voice
	elseif kind == "FallingObject" then
		return candidates.floor
	end
	return candidates.ceiling
end

-- Where a beat of `kind` sounds for a listener whose root is at `listener`: a candidate BAND_MIN..BAND_MAX studs
-- away horizontally that none of `eyes` can see, drawn with `random`; a ceiling drag runs CeilingDragDistance
-- further away from the listener. Nil when there is no such point.
function Level0.place(
	kind: BeatKind,
	candidates: Candidates,
	listener: Vector3,
	eyes: { Vector3 },
	lineClear: (Vector3, Vector3) -> boolean,
	random: Random
): Placement?
	local eligible: { Vector3 } = {}
	for _, point in poolFor(kind, candidates) do
		local distance = MathUtil.horizontalDistance(point, listener)
		if distance >= BAND_MIN and distance <= BAND_MAX and not LevelKit.seenBy(eyes, point, lineClear) then
			table.insert(eligible, point)
		end
	end
	if #eligible == 0 then
		return nil
	end
	local from = eligible[random:NextInteger(1, #eligible)]
	if kind ~= "CeilingDrag" then
		return { from = from, to = nil }
	end
	local away = MathUtil.flat(from - listener)
	local direction = if away.Magnitude > 1e-3 then away.Unit else Vector3.new(1, 0, 0)
	return { from = from, to = from + direction * Scenes.CeilingDragDistance }
end

-- The working fixtures a surge at `point` stutters: within SURGE_RADIUS, nearest first, at most Scenes.SurgeLights.
function Level0.surgeLights(point: Vector3, fixtures: { LitFixture }): { string }
	local near: { { id: string, distance: number } } = {}
	for _, fixture in fixtures do
		local distance = (fixture.position - point).Magnitude
		if distance <= SURGE_RADIUS then
			table.insert(near, { id = fixture.id, distance = distance })
		end
	end
	table.sort(near, function(a: { id: string, distance: number }, b: { id: string, distance: number }): boolean
		if a.distance == b.distance then
			return a.id < b.id
		end
		return a.distance < b.distance
	end)
	local out: { string } = {}
	for index = 1, math.min(#near, Scenes.SurgeLights) do
		table.insert(out, near[index].id)
	end
	return out
end

--------------------------------------------------------------------------------
-- Dependencies + state
--------------------------------------------------------------------------------

local function workingFixtures(): { LitFixture }
	local out: { LitFixture } = {}
	for _, instance in CollectionService:GetTagged(Tags.LevelLight) do
		if
			instance:IsA("BasePart")
			and instance:GetAttribute(W.LevelId) == LEVEL
			and Attributes.getNumber(instance, W.BaseBrightness, 0) > 0
		then
			table.insert(out, { id = instance.Name, position = instance.CFrame.Position })
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
		lights = workingFixtures,
		oneShot = LevelKit.oneShot,
		emit = function(position: Vector3, kind: Enums.NoiseKind)
			NoiseAndDirectorService.Emit(position, kind, { levelId = LEVEL })
		end,
	}
end

local deps: Dependencies = realDependencies()
local candidates: Candidates? = nil
local schedule: Schedule = LevelKit.newSchedule()
local random: Random = MathUtil.seededRandom(1, "L0Beats")
local active = false
local nextAt = math.huge
local previous: BeatKind? = nil
local lastTrapAt = -math.huge
local played = 0

local function candidateSet(): Candidates?
	local cached = candidates
	if cached then
		return cached
	end
	local layout = Builder.getLayout(LEVEL)
	if not layout then
		log.error("no %s layout; the basement stays quiet", LEVEL)
		return nil
	end
	local built = Level0.candidates(layout)
	candidates = built
	return built
end

local function play(kind: BeatKind, placement: Placement, now: number)
	local startAt = now + LEAD
	local ids = Scenes.beatIds(kind)
	local id = ids[random:NextInteger(1, #ids)]
	local args: { [string]: Types.OneShotArg } = { id = id }
	if kind == "CeilingDrag" then
		args[ARGS.From] = placement.from
		args[ARGS.To] = placement.to or placement.from
	else
		args[ARGS.At] = placement.from
	end
	if kind == "BoilerSurge" then
		for index, lightId in Level0.surgeLights(placement.from, deps.lights()) do
			args[LIGHT_ARGS[index]] = lightId
		end
	end
	deps.oneShot(TIMELINE_KIND, startAt, args, nil)
	if kind == "FallingObject" then
		local at = placement.from
		schedule:At(startAt + Scenes.FallImpact, "fall", function()
			deps.emit(at, FALL_NOISE)
		end)
	end
	previous = kind
	played += 1
	log.debug("basement beat %s (%s)", kind, id)
end

-- Draws a beat around `listener` and plays it; false when no kind could be placed.
local function tryBeat(listener: Player, now: number, only: BeatKind?): boolean
	local set = candidateSet()
	local root = deps.rootOf(listener)
	if not (set and root) then
		return false
	end
	local eyes = LevelKit.eyes(deps.players(), deps.eyeOf)
	local remaining: { BeatKind } = if only then { only } else Scenes.beatKinds()
	while #remaining > 0 do
		local kind: BeatKind? = if only then only else Level0.pickBeat(random, previous, remaining)
		if kind == nil then
			return false
		end
		local placement = Level0.place(kind, set, root, eyes, deps.lineClear, random)
		if placement then
			play(kind, placement, now)
			return true
		end
		local index = table.find(remaining, kind)
		if index then
			table.remove(remaining, index)
		end
		if only then
			return false
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- One step at `now` (every Heartbeat from the Levels service; specs pass a fake clock).
function Level0.Step(now: number?)
	local t = now or deps.now()
	schedule:Run(t)
	if not active or t < nextAt then
		return
	end
	local due = Level0.dueAfterTrap(nextAt, lastTrapAt)
	if t < due then
		nextAt = due
		return
	end
	local players = deps.players()
	if #players == 0 then
		nextAt = t + RETRY
		return
	end
	local listener = players[random:NextInteger(1, #players)]
	if tryBeat(listener, t, nil) then
		nextAt = t + Level0.nextDelay(random)
	else
		nextAt = t + RETRY
	end
end

-- A TrapSnap went off at server time `at` (the noise bus reports it; specs call it).
function Level0.NoteTrapSnap(at: number)
	lastTrapAt = math.max(lastTrapAt, at)
end

function Level0.GetNextAt(): number
	return nextAt
end

function Level0.GetPrevious(): BeatKind?
	return previous
end

function Level0.PlayedCount(): number
	return played
end

function Level0.SetDependencies(fake: Dependencies?)
	deps = fake or realDependencies()
end

--------------------------------------------------------------------------------
-- Level controller + lifecycle
--------------------------------------------------------------------------------

-- LevelDirector: the squad is in the basement. The first beat comes 25-50 s in.
function Level0.Activate(_ctx: Types.LevelContext)
	active = true
	nextAt = deps.now() + Level0.nextDelay(random)
end

-- LevelDirector: the squad left it (or the run ended).
function Level0.Deactivate()
	active = false
	nextAt = math.huge
	schedule:Clear()
end

local controller: Types.LevelController = {
	LevelId = LEVEL,
	Activate = Level0.Activate,
	Deactivate = Level0.Deactivate,
}
Level0.Controller = controller

local function beatCommand(player: Player, args: { string }): string?
	if not active then
		return "go to Level 0 first (level 0)"
	end
	local wanted: BeatKind? = nil
	local text = args[1]
	if text then
		for _, kind: BeatKind in Scenes.beatKinds() do
			if string.lower(kind) == string.lower(text) then
				wanted = kind
			end
		end
		if wanted == nil then
			return "usage: beat [" .. table.concat(Scenes.beatKinds(), "|") .. "]"
		end
	end
	if not tryBeat(player, deps.now(), wanted) then
		return "nowhere out of sight " .. BAND_MIN .. "-" .. BAND_MAX .. " studs from you for that beat"
	end
	return "played " .. tostring(previous)
end

function Level0.Init(serviceTrove: Trove.Trove)
	serviceTrove:Add(NoiseAndDirectorService.NoiseEmitted:Connect(function(event: Types.NoiseEvent)
		if event.kind == TRAP_NOISE then
			Level0.NoteTrapSnap(event.serverTime)
		end
	end))
	DevToolsService.Register("beat", "beat [kind]: play a basement ambience beat around you now", beatCommand)
end

function Level0.BeginRun(ctx: Types.RunContext)
	schedule:Clear()
	random = MathUtil.seededRandom(ctx.seed, "L0Beats")
	active = false
	nextAt = math.huge
	previous = nil
	lastTrapAt = -math.huge
	played = 0
end

function Level0.EndRun()
	schedule:Clear()
	active = false
	nextAt = math.huge
end

return table.freeze(Level0)
