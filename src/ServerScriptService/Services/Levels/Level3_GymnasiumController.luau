--!strict
-- Level3_GymnasiumController: the gymnasium and its locker rooms (spec, Level 3: acoustic stealth, lockers, ducts; the
-- gym is where the Creature stalks at high speed). The lockers themselves are LockerHidingService's; this controller
-- tunes the Creature through MonsterAIService's public API and plays the locker rooms' ambience.
--
-- Stalking. At SPEED_HZ, while the Creature is on Level 3 and inside the gymnasium (the L3_Gymnasium room's
-- footprint) in a hunting state (Patrol, InvestigateNoise, WallChase), its pace is scaled by GYM_SPEED_SCALE
-- (MonsterAIService.SetSpeedScale); anywhere else, and once the level is left, back to 1. Crossing the court is the
-- danger; the changing rooms are where you can still hide.
-- Pressure (MonsterAIService.Alert, both "Low", heard like any other noise, never at a player):
--   Sweep  once a participant has spent SWEEP_DWELL seconds in a room with hideable lockers (the changing rooms, the
--          locker-lined hall ends) while the Creature patrols, every SWEEP_MIN..SWEEP_MAX seconds it is drawn to the
--          front of a seeded locker in that room: it comes in and peeks into the nearest lockers (the hold-breath
--          checks), wherever in the room the squad really hides.
--   Prowl  once it has patrolled outside the gym for PROWL_AWAY seconds with nobody on the court, every PROWL_MIN..
--          PROWL_MAX seconds it is called back to a seeded point on the court: the gym is its ground.
-- Neither fires while a breath check runs (LockerHidingService.IsChecking) or within CHECK_GAP seconds of one.
-- Ambience beats (Scenes, Floor 3), same style as the basement's: a seeded director plays one every INTERVAL_MIN..
-- INTERVAL_MAX seconds, never the same kind twice in a row, at a point no participant can see, within the kind's band
-- (horizontal studs) of a randomly drawn playing participant:
--   ShowerDrip  a showerhead dripping onto the showers' tiles (BANDS.ShowerDrip),
--   LockerBang  a locker door banging or rattling somewhere in the changing rooms, with a quiet FallingObject noise
--               there (it may come and look),
--   BallBounce  a basketball bouncing to rest far off on the dark court.
-- Beats wait while a breath check runs (a sound must never cover the creature at the slits) and retry RETRY seconds
-- later when nothing can be placed.
--
-- Dev command: gymbeat [kind] (one beat now, placed around you).
--
-- Pure rules (tests/Specs/Level3.spec.luau): candidates, inGym, speedScaleFor, pickBeat, nextDelay, place, sweepRoom,
-- lockerFront.

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
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local LockerHidingService = require(ServerScriptService.Services.Mechanics.LockerHidingService)
local MonsterAIService = require(ServerScriptService.Services.Monster.MonsterAIService)

local LevelKit = require(script.Parent.LevelKit)

local log = Log.new("Level3")

local P = Attributes.Player

type BeatKind = Scenes.GymBeatKind
type Schedule = LevelKit.Schedule

export type Candidates = {
	showers: { Vector3 }, -- the shower floors
	lockers: { Vector3 }, -- locker doors (hideable and smashed), at the latch
	court: { Vector3 }, -- the gym floor
}

export type Band = { min: number, max: number }

-- A locker the sweep can draw the Creature to: the floor point before its door, in its room.
export type LockerSpot = { room: string, front: Vector3 }

export type Dependencies = {
	now: () -> number,
	players: () -> { Player },
	rootOf: (player: Player) -> Vector3?,
	eyeOf: (player: Player) -> Vector3?,
	zoneOf: (player: Player) -> string?,
	lineClear: (from: Vector3, to: Vector3) -> boolean,
	oneShot: (kind: Enums.OneShotKind, startAt: number, args: { [string]: Types.OneShotArg }, subject: Instance?) -> (),
	emit: (position: Vector3, kind: Enums.NoiseKind) -> (),
	creature: () -> (Vector3?, Enums.MonsterState, string?), -- root, state, level
	setSpeedScale: (scale: number) -> (),
	alert: (position: Vector3, priority: Enums.NoisePriority) -> (),
	checking: () -> boolean,
}

local LEVEL: Enums.LevelId = "Level3_Gymnasium"
local GYM_ROOM = "L3_Gymnasium"
local GYM_SPEED_SCALE = 1.3
local SPEED_HZ = GameConfig.ServerTickHz
local INTERVAL_MIN = 22
local INTERVAL_MAX = 44
local RETRY = 4
local CHECK_GAP = 6
local SWEEP_DWELL = 12
local SWEEP_MIN = 45
local SWEEP_MAX = 80
local PROWL_AWAY = 30
local PROWL_MIN = 50
local PROWL_MAX = 85
local PRESSURE_CHECK = 1
local GRID = 8
local INSET = 3
local FLOOR_LIFT = 0.3
local LATCH_HEIGHT = 3.6
local LOCKER_FRONT = 2.2 -- studs out from a locker anchor to the floor before its door
local COURT_GRID = 14
local COURT_INSET = 8
local LEAD = GameConfig.OneShotLead
local TIMELINE_KIND: Enums.OneShotKind = "Timeline"
local BANG_NOISE: Enums.NoiseKind = "FallingObject"
local SWEEP_PRIORITY: Enums.NoisePriority = "Low"
local ARGS = Scenes.Args

local BANDS: { [string]: Band } = {
	ShowerDrip = { min = 14, max = 36 },
	LockerBang = { min = 22, max = 48 },
	BallBounce = { min = 34, max = 90 },
}

local HUNTING: { [string]: boolean } = { Patrol = true, InvestigateNoise = true, WallChase = true }

local Level3 = {}

Level3.LevelId = LEVEL
Level3.GymRoom = GYM_ROOM
Level3.GymSpeedScale = GYM_SPEED_SCALE
Level3.IntervalMin = INTERVAL_MIN
Level3.IntervalMax = INTERVAL_MAX
Level3.Retry = RETRY
Level3.CheckGap = CHECK_GAP
Level3.SweepDwell = SWEEP_DWELL
Level3.SweepMin = SWEEP_MIN
Level3.SweepMax = SWEEP_MAX
Level3.ProwlAway = PROWL_AWAY
Level3.ProwlMin = PROWL_MIN
Level3.ProwlMax = PROWL_MAX
Level3.Bands = table.freeze(table.clone(BANDS))

--------------------------------------------------------------------------------
-- Pure rules
--------------------------------------------------------------------------------

local function grid(out: { Vector3 }, origin: Vector3, rect: LayoutSchema.Rect, step: number, inset: number, y: number)
	local nx = math.max(1, math.floor((rect.w - 2 * inset) / step) + 1)
	local nz = math.max(1, math.floor((rect.d - 2 * inset) / step) + 1)
	for i = 0, nx - 1 do
		for j = 0, nz - 1 do
			local x = if nx == 1 then rect.x + rect.w / 2 else rect.x + inset + (rect.w - 2 * inset) * i / (nx - 1)
			local z = if nz == 1 then rect.z + rect.d / 2 else rect.z + inset + (rect.d - 2 * inset) * j / (nz - 1)
			table.insert(out, origin + Vector3.new(x, y, z))
		end
	end
end

local function anchorFront(layoutId: string, anchor: LayoutSchema.Anchor, out: number, y: number): Vector3
	local cframe = CFrame.new(WorldConfig.levelOrigin(layoutId) + anchor.pos)
		* CFrame.Angles(0, math.rad(anchor.yaw or 0), 0)
	return (cframe * CFrame.new(0, y, -out)).Position
end

-- Where Floor 3 beats can sound on `layout` (world points): the shower rooms' floors, every locker door (hideable and
-- smashed) at latch height just off its face, and a coarse lattice over the court.
function Level3.candidates(layout: LayoutSchema.LevelLayout): Candidates
	local origin = WorldConfig.levelOrigin(layout.id)
	local out: Candidates = { showers = {}, lockers = {}, court = {} }
	for _, room in layout.rooms do
		if room.kind == "Restroom" then
			grid(out.showers, origin, room.rect, GRID, INSET, FLOOR_LIFT)
		elseif room.id == GYM_ROOM then
			grid(out.court, origin, room.rect, COURT_GRID, COURT_INSET, FLOOR_LIFT)
		end
	end
	for _, anchor in layout.anchors do
		if anchor.kind == "Locker" or anchor.kind == "SmashedLocker" then
			table.insert(out.lockers, anchorFront(layout.id, anchor, 0.3, LATCH_HEIGHT))
		end
	end
	return out
end

-- Every hideable locker's front (the floor before its door) with its room.
function Level3.lockerFronts(layout: LayoutSchema.LevelLayout): { LockerSpot }
	local out: { LockerSpot } = {}
	for _, anchor in layout.anchors do
		if anchor.kind == "Locker" then
			table.insert(out, { room = anchor.room, front = anchorFront(layout.id, anchor, LOCKER_FRONT, 0) })
		end
	end
	return out
end

-- Whether world point `point` is inside the gymnasium's footprint on `layout`.
function Level3.inGym(layout: LayoutSchema.LevelLayout, point: Vector3): boolean
	local origin = WorldConfig.levelOrigin(layout.id)
	for _, room in layout.rooms do
		if room.id == GYM_ROOM then
			local p = point - origin
			return LayoutSchema.rectContains(room.rect, p.X, p.Z)
		end
	end
	return false
end

-- The Creature's pace scale: GYM_SPEED_SCALE while it hunts on the court, else 1.
function Level3.speedScaleFor(inGym: boolean, state: Enums.MonsterState): number
	return if inGym and HUNTING[state] then GYM_SPEED_SCALE else 1
end

-- A beat kind drawn from `allowed`, never `previous` (nil when nothing else is allowed).
function Level3.pickBeat(random: Random, previous: BeatKind?, allowed: { BeatKind }): BeatKind?
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
function Level3.nextDelay(random: Random): number
	return random:NextNumber(INTERVAL_MIN, INTERVAL_MAX)
end

local function poolFor(kind: BeatKind, candidates: Candidates): { Vector3 }
	if kind == "ShowerDrip" then
		return candidates.showers
	elseif kind == "LockerBang" then
		return candidates.lockers
	end
	return candidates.court
end

-- Where a beat of `kind` sounds for a listener at `listener`: a candidate within the kind's band (horizontal studs)
-- that none of `eyes` can see, drawn with `random`; nil when there is none.
function Level3.place(
	kind: BeatKind,
	candidates: Candidates,
	listener: Vector3,
	eyes: { Vector3 },
	lineClear: (Vector3, Vector3) -> boolean,
	random: Random
): Vector3?
	local band = BANDS[kind]
	local eligible: { Vector3 } = {}
	for _, point in poolFor(kind, candidates) do
		local distance = MathUtil.horizontalDistance(point, listener)
		if distance >= band.min and distance <= band.max and not LevelKit.seenBy(eyes, point, lineClear) then
			table.insert(eligible, point)
		end
	end
	if #eligible == 0 then
		return nil
	end
	return eligible[random:NextInteger(1, #eligible)]
end

-- The hiding room a sweep goes to: of the rooms (zone ids) players have been in since `since[room]`, the one entered
-- longest ago that has been occupied for at least SWEEP_DWELL by `now` (ties by id). Nil when none qualifies.
function Level3.sweepRoom(since: { [string]: number }, now: number): string?
	local best: string? = nil
	local bestSince = math.huge
	for room, at in since do
		if now - at >= SWEEP_DWELL and (at < bestSince or (at == bestSince and best ~= nil and room < best)) then
			best, bestSince = room, at
		end
	end
	return best
end

-- The front of a locker in `room` drawn with `random` (nil when the room has none).
function Level3.lockerFront(spots: { LockerSpot }, room: string, random: Random): Vector3?
	local inRoom: { Vector3 } = {}
	for _, spot in spots do
		if spot.room == room then
			table.insert(inRoom, spot.front)
		end
	end
	if #inRoom == 0 then
		return nil
	end
	return inRoom[random:NextInteger(1, #inRoom)]
end

--------------------------------------------------------------------------------
-- Dependencies + state
--------------------------------------------------------------------------------

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
		zoneOf = function(player: Player): string?
			local zone = player:GetAttribute(P.ZoneId)
			return if type(zone) == "string" then zone else nil
		end,
		lineClear = LevelKit.lineClear,
		oneShot = LevelKit.oneShot,
		emit = function(position: Vector3, kind: Enums.NoiseKind)
			NoiseAndDirectorService.Emit(position, kind, { levelId = LEVEL })
		end,
		creature = function(): (Vector3?, Enums.MonsterState, string?)
			local model = MonsterAIService.GetCreature()
			local root = if model then model.PrimaryPart else nil
			local level = if model then model:GetAttribute(Attributes.Creature.LevelId) else nil
			return if root then root.CFrame.Position else nil,
				MonsterAIService.GetState(),
				if type(level) == "string" then level else nil
		end,
		setSpeedScale = MonsterAIService.SetSpeedScale,
		alert = MonsterAIService.Alert,
		checking = LockerHidingService.IsChecking,
	}
end

local deps: Dependencies = realDependencies()
local layoutCache: LayoutSchema.LevelLayout? = nil
local candidates: Candidates? = nil
local fronts: { LockerSpot }? = nil
local schedule: Schedule = LevelKit.newSchedule()
local random: Random = MathUtil.seededRandom(1, "L3Beats")
local pressureRandom: Random = MathUtil.seededRandom(1, "L3Pressure")
local active = false
local nextAt = math.huge
local previous: BeatKind? = nil
local played = 0
local speedClock = -math.huge
local appliedScale = 1
local pressureClock = -math.huge
local lastCheckAt = -math.huge
local nextSweepAt = math.huge
local nextProwlAt = math.huge
local awaySince: number? = nil -- the Creature has patrolled outside the gym since
local roomSince: { [string]: number } = {} -- hiding rooms with players in them, since when
local sweeps = 0
local prowls = 0

local function layout(): LayoutSchema.LevelLayout?
	local cached = layoutCache
	if cached then
		return cached
	end
	local found = Builder.getLayout(LEVEL)
	if not found then
		log.error("no %s layout; the gym stays quiet", LEVEL)
		return nil
	end
	layoutCache = found
	return found
end

local function candidateSet(): Candidates?
	local cached = candidates
	if cached then
		return cached
	end
	local blueprint = layout()
	if not blueprint then
		return nil
	end
	local built = Level3.candidates(blueprint)
	candidates = built
	return built
end

local function lockerSpots(): { LockerSpot }
	local cached = fronts
	if cached then
		return cached
	end
	local blueprint = layout()
	local built = if blueprint then Level3.lockerFronts(blueprint) else {}
	fronts = built
	return built
end

local lockerRooms: { [string]: boolean }? = nil

-- Whether the room `zoneId` has hideable lockers.
local function hasLockers(zoneId: string): boolean
	local cached = lockerRooms
	if cached then
		return cached[zoneId] == true
	end
	local built: { [string]: boolean } = {}
	for _, spot in lockerSpots() do
		built[spot.room] = true
	end
	lockerRooms = built
	return built[zoneId] == true
end

local function applyScale(scale: number)
	if math.abs(scale - appliedScale) < 1e-6 then
		return
	end
	appliedScale = scale
	deps.setSpeedScale(scale)
end

local function play(kind: BeatKind, at: Vector3, now: number)
	local startAt = now + LEAD
	local ids = Scenes.gymBeatIds(kind)
	local id = ids[random:NextInteger(1, #ids)]
	deps.oneShot(TIMELINE_KIND, startAt, { id = id, [ARGS.At] = at }, nil)
	if kind == "LockerBang" then
		schedule:At(startAt, "bang", function()
			deps.emit(at, BANG_NOISE)
		end)
	end
	previous = kind
	played += 1
	log.debug("gym beat %s (%s)", kind, id)
end

-- Draws a beat around `listener` and plays it; false when no kind could be placed.
local function tryBeat(listener: Player, now: number, only: BeatKind?): boolean
	local set = candidateSet()
	local root = deps.rootOf(listener)
	if not (set and root) then
		return false
	end
	local eyes = LevelKit.eyes(deps.players(), deps.eyeOf)
	local remaining: { BeatKind } = if only then { only } else Scenes.gymBeatKinds()
	while #remaining > 0 do
		local kind: BeatKind? = if only then only else Level3.pickBeat(random, previous, remaining)
		if kind == nil then
			return false
		end
		local point = Level3.place(kind, set, root, eyes, deps.lineClear, random)
		if point then
			play(kind, point, now)
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

local function stepSpeed(now: number)
	if now - speedClock < 1 / SPEED_HZ then
		return
	end
	speedClock = now
	local blueprint = layout()
	local at: Vector3?, state: Enums.MonsterState, level: string? = deps.creature()
	local inGym = blueprint ~= nil and at ~= nil and level == LEVEL and Level3.inGym(blueprint, at)
	applyScale(Level3.speedScaleFor(inGym, state))
end

local function stepBeats(now: number, checking: boolean)
	if now < nextAt then
		return
	end
	if checking or now - lastCheckAt < CHECK_GAP then
		nextAt = now + RETRY
		return
	end
	local players = deps.players()
	if #players == 0 then
		nextAt = now + RETRY
		return
	end
	local listener = players[random:NextInteger(1, #players)]
	nextAt = if tryBeat(listener, now, nil) then now + Level3.nextDelay(random) else now + RETRY
end

local function stepPressure(now: number, checking: boolean)
	if now - pressureClock < PRESSURE_CHECK then
		return
	end
	pressureClock = now
	local blueprint = layout()
	if not blueprint then
		return
	end
	-- where the squad is
	local present: { [string]: boolean } = {}
	local anyoneInGym = false
	for _, player in deps.players() do
		local zone = deps.zoneOf(player)
		if zone and hasLockers(zone) then
			present[zone] = true
		end
		local root = deps.rootOf(player)
		if root and Level3.inGym(blueprint, root) then
			anyoneInGym = true
		end
	end
	for room in table.clone(roomSince) do
		if not present[room] then
			roomSince[room] = nil
		end
	end
	for room in present do
		if roomSince[room] == nil then
			roomSince[room] = now
		end
	end
	-- where it is
	local at: Vector3?, state: Enums.MonsterState, level: string? = deps.creature()
	local onLevel = at ~= nil and level == LEVEL
	local patrolling = onLevel and state == "Patrol"
	local creatureInGym = onLevel and at ~= nil and Level3.inGym(blueprint, at)
	if patrolling and not creatureInGym then
		awaySince = awaySince or now
	else
		awaySince = nil
	end
	if checking or now - lastCheckAt < CHECK_GAP or not patrolling then
		return
	end
	if now >= nextSweepAt then
		local room = Level3.sweepRoom(roomSince, now)
		local front = if room then Level3.lockerFront(lockerSpots(), room, pressureRandom) else nil
		if front then
			deps.alert(front, SWEEP_PRIORITY)
			sweeps += 1
			nextSweepAt = now + pressureRandom:NextNumber(SWEEP_MIN, SWEEP_MAX)
			log.debug("sweep: the Creature is drawn into %s", tostring(room))
			return
		end
	end
	local away = awaySince
	if now >= nextProwlAt and away and now - away >= PROWL_AWAY and not anyoneInGym then
		local set = candidateSet()
		local court = if set then set.court else {}
		if #court > 0 then
			deps.alert(court[pressureRandom:NextInteger(1, #court)], SWEEP_PRIORITY)
			prowls += 1
			nextProwlAt = now + pressureRandom:NextNumber(PROWL_MIN, PROWL_MAX)
			awaySince = nil
		end
	end
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- One step at `now` (every Heartbeat from the Levels service; specs pass a fake clock).
function Level3.Step(now: number?)
	local t = now or deps.now()
	schedule:Run(t)
	if not active then
		return
	end
	local checking = deps.checking()
	if checking then
		lastCheckAt = t
	end
	stepSpeed(t)
	stepBeats(t, checking)
	stepPressure(t, checking)
end

function Level3.GetNextAt(): number
	return nextAt
end

function Level3.GetPrevious(): BeatKind?
	return previous
end

function Level3.PlayedCount(): number
	return played
end

-- How many sweeps and prowls the Creature was sent on this run.
function Level3.PressureCounts(): (number, number)
	return sweeps, prowls
end

function Level3.GetSpeedScale(): number
	return appliedScale
end

function Level3.SetDependencies(fake: Dependencies?)
	deps = fake or realDependencies()
end

--------------------------------------------------------------------------------
-- Level controller + lifecycle
--------------------------------------------------------------------------------

-- LevelDirector: the squad is in the gym wing. The first beat comes 22-44 s in; the first sweep and prowl after a
-- full interval.
function Level3.Activate(_ctx: Types.LevelContext)
	active = true
	local now = deps.now()
	nextAt = now + Level3.nextDelay(random)
	nextSweepAt = now + pressureRandom:NextNumber(SWEEP_MIN, SWEEP_MAX)
	nextProwlAt = now + pressureRandom:NextNumber(PROWL_MIN, PROWL_MAX)
	awaySince = nil
	table.clear(roomSince)
	speedClock = -math.huge
	pressureClock = -math.huge
end

-- LevelDirector: the squad left it (or the run ended). The Creature's pace goes back to normal.
function Level3.Deactivate()
	active = false
	nextAt = math.huge
	nextSweepAt = math.huge
	nextProwlAt = math.huge
	awaySince = nil
	table.clear(roomSince)
	schedule:Clear()
	applyScale(1)
end

local controller: Types.LevelController = {
	LevelId = LEVEL,
	Activate = Level3.Activate,
	Deactivate = Level3.Deactivate,
}
Level3.Controller = controller

local function beatCommand(player: Player, args: { string }): string?
	if not active then
		return "go to Level 3 first (level 3)"
	end
	local wanted: BeatKind? = nil
	local text = args[1]
	if text then
		for _, kind: BeatKind in Scenes.gymBeatKinds() do
			if string.lower(kind) == string.lower(text) then
				wanted = kind
			end
		end
		if wanted == nil then
			return "usage: gymbeat [" .. table.concat(Scenes.gymBeatKinds(), "|") .. "]"
		end
	end
	if not tryBeat(player, deps.now(), wanted) then
		return "nowhere out of sight in that beat's range of you"
	end
	return "played " .. tostring(previous)
end

function Level3.Init()
	DevToolsService.Register("gymbeat", "gymbeat [kind]: play a Floor 3 ambience beat around you now", beatCommand)
end

function Level3.BeginRun(ctx: Types.RunContext)
	schedule:Clear()
	random = MathUtil.seededRandom(ctx.seed, "L3Beats")
	pressureRandom = MathUtil.seededRandom(ctx.seed, "L3Pressure")
	active = false
	nextAt = math.huge
	nextSweepAt = math.huge
	nextProwlAt = math.huge
	previous = nil
	played = 0
	sweeps = 0
	prowls = 0
	lastCheckAt = -math.huge
	awaySince = nil
	appliedScale = 1
	table.clear(roomSince)
end

function Level3.EndRun()
	schedule:Clear()
	active = false
	nextAt = math.huge
	nextSweepAt = math.huge
	nextProwlAt = math.huge
	table.clear(roomSince)
	appliedScale = 1
end

return table.freeze(Level3)
