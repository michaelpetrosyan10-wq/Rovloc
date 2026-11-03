--!strict
-- Level4_FloodedPoolController: the flooded natatorium (spec, Level 4). The water, the oxygen and the grab are
-- FloodedPoolService's; this controller runs the level around them.
--
-- Pool activation. A pool session starts when the first playing participant gets into the water and ends when the
-- last one is out. ALERT_MIN..ALERT_MAX seconds into a session (seeded), if the Creature is wandering the level
-- (Patrol or InvestigateNoise: not asleep, not already stalking, chasing, stunned or held by a script), it is alerted
-- (MonsterAIService.Alert, Normal priority) to a swimmer's spot on the surface: it comes to the water, where its own
-- senses take over (swimmers' water noise and sight hand it to AquaticStalk). One alert per session, at most one every
-- ALERT_COOLDOWN seconds; while the Creature is busy the alert waits for it.
--
-- The emergency floodlights. The owner of the FloodlightSwitch prompt (InteractionService kind "Floodlight", served
-- while the switch's On is false) and of FloodlightSwitch.On. Flipping it (one use per run: the breaker burns out on
-- the lamps): On = true (the prompt closes), the lever is thrown over LEVER_SECONDS (server-stepped, the green lamp
-- lit once it is up), the breaker's clank at the switch, and BREAKER_DELAY later the nine L4 Floodlight fixtures
-- come up for the rest of the run (their BaseBrightness set to the layout's brightness, so late joiners see them lit;
-- restored at EndRun) while every client plays the Scenes "L4_Floodlights" strike-up and hears the lamps hum to life.
-- At that moment a swimmer the Creature holds is let go (FloodedPoolService.ReleaseGrab "Floodlight", which stuns
-- it), and a Creature in the natatorium or stalking the water that held nobody is blinded and flees the light
-- (MonsterAIService.Stun for GameConfig.StunSeconds from the nearest lamp; RunStats Stuns for the player who threw the
-- switch). Everyone on the level gets Hud.FloodlightsOn.
--
-- Ambience. While the squad is on Level 4 a seeded director plays a beat every BEAT_MIN..BEAT_MAX seconds, never the
-- same kind twice in a row, at a point BAND_MIN..BAND_MAX studs (horizontally) from a random playing participant that
-- nobody can see: a heavy drip into the water (PoolDrip), something stirring the water far off (WaterSlosh), a loose
-- tile dropping in (TileFall), a groan echoing under the roof (DistantGroan). None within QUIET_GAP seconds of a grab
-- starting or ending or of the floodlights; nowhere to place one retries RETRY seconds later. Beats are sounds only:
-- they make no noise the Creature hears.
--
-- Dev commands: floodlights (throw the switch now, as you), poolbeat [kind].
--
-- Pure rules (tests/Specs/Level4.spec.luau): poolAlert, alertable, blinds, leverAt, candidates, pickBeat, place,
-- nearestLight.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Scenes = require(ReplicatedStorage.Shared.Sequence.Scenes)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local FloodlightSwitchBuilder =
	require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.FloodlightSwitchBuilder)

local AudioService = require(ServerScriptService.Services.Core.AudioService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local MonsterAIService = require(ServerScriptService.Services.Monster.MonsterAIService)
local FloodedPoolService = require(ServerScriptService.Services.Mechanics.FloodedPoolService)

local LevelKit = require(script.Parent.LevelKit)

local log = Log.new("Level4")

local W = Attributes.World
local C = Attributes.Creature

type Schedule = LevelKit.Schedule

export type BeatKind = "Drip" | "Slosh" | "TileFall" | "Groan"

export type Candidates = {
	water: { Vector3 }, -- just over the water surface
	ceiling: { Vector3 }, -- under the ceilings
}

export type Floodlight = { id: string, part: BasePart?, position: Vector3, brightness: number }

export type AlertInput = {
	swimming: boolean, -- a pool session is on
	alerted: boolean, -- this session already brought the Creature
	alertAt: number, -- when this session's alert falls due
	cooldownUntil: number,
	now: number,
	state: string, -- the Creature's MonsterState
}

export type AlertDecision = "Wait" | "Alert" | "Done"

export type Dependencies = {
	now: () -> number,
	players: () -> { Player }, -- playing participants on Level 4
	rootOf: (player: Player) -> Vector3?,
	eyeOf: (player: Player) -> Vector3?,
	lineClear: (from: Vector3, to: Vector3) -> boolean,
	swimmers: () -> { Player },
	creature: () -> (Vector3?, Enums.MonsterState), -- root position (nil without one on this level), state
	alert: (position: Vector3, priority: Enums.NoisePriority) -> (),
	stun: (seconds: number, from: Vector3) -> (),
	releaseGrab: (outcome: FloodedPoolService.Outcome) -> boolean,
	floodlights: () -> { Floodlight },
	setBase: (part: BasePart, brightness: number) -> (),
	poseSwitch: (model: Model, lever: number, lit: boolean) -> (),
	refresh: (host: Instance) -> (),
	oneShot: (kind: Enums.OneShotKind, startAt: number, args: { [string]: Types.OneShotArg }, subject: Instance?) -> (),
	playAt: (preset: string, position: Vector3, volume: number?) -> (),
	notify: (player: Player, key: string) -> (),
	stat: (player: Player, key: Enums.StatKey) -> (),
}

local LEVEL: Enums.LevelId = "Level4_FloodedPool"
local POOL_ROOM = "L4_Natatorium"
local ALERT_MIN = 4
local ALERT_MAX = 7
local ALERT_COOLDOWN = 40
local ALERT_CHECK = 1
local ALERTABLE: { [string]: boolean } = { Patrol = true, InvestigateNoise = true }
local HUNTING: { [string]: boolean } = { AquaticStalk = true, WallChase = true, VentChase = true }
local LEVER_SECONDS = 0.45
local LEVER_LIT_AT = 0.85 -- lever travel (0..1) at which the green lamp comes on
local BREAKER_DELAY = 0.35 -- seconds from the clank to the lamps striking
local LEAD = GameConfig.OneShotLead
local BEAT_MIN = 18
local BEAT_MAX = 36
local BAND_MIN = 18
local BAND_MAX = 45
local QUIET_GAP = 8
local RETRY = 4
local GRID = 9
local INSET = 3
local WATER_LIFT = 0.1
local CEILING_DROP = 1.2
local SKIPPED_ROOMS: { [string]: boolean } = { Airlock = true, Chase = true }
local BEAT_KINDS: { BeatKind } = { "Drip", "Slosh", "TileFall", "Groan" }
local BEAT_PRESETS: { [string]: string } = {
	Drip = "PoolDrip",
	Slosh = "WaterSlosh",
	TileFall = "TileFall",
	Groan = "DistantGroan",
}
local BEAT_VOLUME: { [string]: number } = { Drip = 1.2, Slosh = 1, TileFall = 1.1, Groan = 0.9 }
local BREAKER_PRESET = "FloodlightBreaker"
local STRIKE_PRESET = "FloodlightStrike"
local TIMELINE_KIND: Enums.OneShotKind = "Timeline"
local PROMPT_KIND: Enums.PromptKind = "Floodlight"
local ON_KEY = "Hud.FloodlightsOn"
local STUN_STAT: Enums.StatKey = "Stuns"
local ALERT_PRIORITY: Enums.NoisePriority = "Normal"

local Level4 = {}

Level4.LevelId = LEVEL
Level4.AlertMin = ALERT_MIN
Level4.AlertMax = ALERT_MAX
Level4.AlertCooldown = ALERT_COOLDOWN
Level4.LeverSeconds = LEVER_SECONDS
Level4.BreakerDelay = BREAKER_DELAY
Level4.BeatMin = BEAT_MIN
Level4.BeatMax = BEAT_MAX
Level4.BandMin = BAND_MIN
Level4.BandMax = BAND_MAX
Level4.QuietGap = QUIET_GAP
Level4.Retry = RETRY
Level4.OnKey = ON_KEY
Level4.BeatPresets = table.freeze(table.clone(BEAT_PRESETS))

--------------------------------------------------------------------------------
-- Pure rules
--------------------------------------------------------------------------------

-- Whether a Creature in `state` should be brought to the water (wandering the level, not busy).
function Level4.alertable(state: string): boolean
	return ALERTABLE[state] == true
end

-- What a pool session does now (see the header): "Alert" the Creature, "Wait" for it, or "Done" (no session, already
-- alerted, or it is hunting already).
function Level4.poolAlert(input: AlertInput): AlertDecision
	if not input.swimming or input.alerted then
		return "Done"
	end
	if HUNTING[input.state] then
		return "Done"
	end
	if input.now < input.alertAt or input.now < input.cooldownUntil then
		return "Wait"
	end
	return if Level4.alertable(input.state) then "Alert" else "Wait"
end

-- Whether the floodlights blind a Creature at `position` in `state`: stalking the water, or inside the natatorium's
-- box (`low`..`high`, world corners).
function Level4.blinds(position: Vector3?, state: string, low: Vector3, high: Vector3): boolean
	if state == "AquaticStalk" then
		return true
	end
	if not position then
		return false
	end
	return position.X >= low.X
		and position.X <= high.X
		and position.Y >= low.Y
		and position.Y <= high.Y
		and position.Z >= low.Z
		and position.Z <= high.Z
end

-- The lever's throw (0 = OFF .. 1 = ON) `t` seconds after the flip: heaved up, a little overshoot, then home.
function Level4.leverAt(t: number): number
	if t <= 0 then
		return 0
	end
	local u = math.clamp(t / LEVER_SECONDS, 0, 1)
	if u < 0.8 then
		local v = u / 0.8
		return 1.06 * (1 - (1 - v) ^ 3)
	end
	local v = (u - 0.8) / 0.2
	return 1.06 - 0.06 * MathUtil.smoothstep(0, 1, v)
end

-- Where beats can sound on `layout` (world points): a GRID-stud lattice just over every basin's open water, and under
-- the ceiling of every room but the stair airlocks and the duct chase.
function Level4.candidates(layout: LayoutSchema.LevelLayout): Candidates
	local origin = WorldConfig.levelOrigin(layout.id)
	local out: Candidates = { water = {}, ceiling = {} }
	local function lattice(r: LayoutSchema.Rect, y: number, into: { Vector3 })
		local nx = math.max(1, math.floor((r.w - 2 * INSET) / GRID) + 1)
		local nz = math.max(1, math.floor((r.d - 2 * INSET) / GRID) + 1)
		for i = 0, nx - 1 do
			for j = 0, nz - 1 do
				local x = if nx == 1 then r.x + r.w / 2 else r.x + INSET + (r.w - 2 * INSET) * i / (nx - 1)
				local z = if nz == 1 then r.z + r.d / 2 else r.z + INSET + (r.d - 2 * INSET) * j / (nz - 1)
				table.insert(into, origin + Vector3.new(x, y, z))
			end
		end
	end
	for _, basin in (layout.basins or {}) :: { LayoutSchema.Basin } do
		lattice(Geometry.insetRect(basin.rect, Geometry.BasinWall), basin.waterLevel + WATER_LIFT, out.water)
	end
	for _, room in layout.rooms do
		if not SKIPPED_ROOMS[room.kind] then
			lattice(room.rect, LayoutSchema.roomHeight(layout, room) - CEILING_DROP, out.ceiling)
		end
	end
	return out
end

-- A beat kind drawn from `allowed`, never `previous` (nil when nothing else is allowed).
function Level4.pickBeat(random: Random, previous: BeatKind?, allowed: { BeatKind }): BeatKind?
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

-- Where a beat of `kind` sounds for a listener whose root is at `listener`: a candidate BAND_MIN..BAND_MAX studs
-- away horizontally that none of `eyes` can see, drawn with `random`; nil when there is none.
function Level4.place(
	kind: BeatKind,
	candidates: Candidates,
	listener: Vector3,
	eyes: { Vector3 },
	lineClear: (Vector3, Vector3) -> boolean,
	random: Random
): Vector3?
	local pool: { Vector3 } = if kind == "Groan" then candidates.ceiling else candidates.water
	local eligible: { Vector3 } = {}
	for _, point in pool do
		local distance = MathUtil.horizontalDistance(point, listener)
		if distance >= BAND_MIN and distance <= BAND_MAX and not LevelKit.seenBy(eyes, point, lineClear) then
			table.insert(eligible, point)
		end
	end
	if #eligible == 0 then
		return nil
	end
	return eligible[random:NextInteger(1, #eligible)]
end

-- The floodlight nearest `point` (its position), nil without any.
function Level4.nearestLight(point: Vector3, lights: { Floodlight }): Vector3?
	local best: Vector3? = nil
	local bestDistance = math.huge
	for _, light in lights do
		local distance = (light.position - point).Magnitude
		if distance < bestDistance then
			best = light.position
			bestDistance = distance
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- Dependencies + state
--------------------------------------------------------------------------------

local function layoutFloodlights(): { Floodlight }
	local out: { Floodlight } = {}
	local layout = Builder.getLayout(LEVEL)
	if not layout then
		return out
	end
	local origin = WorldConfig.levelOrigin(LEVEL)
	local parts: { [string]: BasePart } = {}
	for _, instance in CollectionService:GetTagged(Tags.LevelLight) do
		if instance:IsA("BasePart") and instance:GetAttribute(W.LevelId) == LEVEL then
			parts[instance.Name] = instance
		end
	end
	for _, room in layout.rooms do
		for _, light in (room.lights or {}) :: { LayoutSchema.Light } do
			if light.kind == "Floodlight" then
				table.insert(out, {
					id = light.id,
					part = parts[light.id],
					position = origin + light.pos,
					brightness = light.brightness,
				})
			end
		end
	end
	table.sort(out, function(a: Floodlight, b: Floodlight): boolean
		return a.id < b.id
	end)
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
		swimmers = FloodedPoolService.Swimmers,
		creature = function(): (Vector3?, Enums.MonsterState)
			local model = MonsterAIService.GetCreature()
			local root = if model then model:FindFirstChild("HumanoidRootPart") else nil
			local onLevel = model ~= nil and Attributes.getString(model, C.LevelId, "") == LEVEL
			local position = if onLevel and root and root:IsA("BasePart") then root.CFrame.Position else nil
			return position, MonsterAIService.GetState()
		end,
		alert = MonsterAIService.Alert,
		stun = MonsterAIService.Stun,
		releaseGrab = FloodedPoolService.ReleaseGrab,
		floodlights = layoutFloodlights,
		setBase = function(part: BasePart, brightness: number)
			part:SetAttribute(W.BaseBrightness, brightness)
		end,
		poseSwitch = function(model: Model, lever: number, lit: boolean)
			FloodlightSwitchBuilder.setLever(model, lever)
			FloodlightSwitchBuilder.setIndicator(model, lit)
		end,
		refresh = InteractionService.Refresh,
		oneShot = LevelKit.oneShot,
		playAt = function(preset: string, position: Vector3, volume: number?)
			AudioService.PlayAt(preset, position, { volume = volume })
		end,
		notify = LevelKit.notify,
		stat = function(player: Player, key: Enums.StatKey)
			RunStatsService.Increment(player, key)
		end,
	}
end

local deps: Dependencies = realDependencies()
local beats: Schedule = LevelKit.newSchedule()
local lights: Schedule = LevelKit.newSchedule()
local random: Random = MathUtil.seededRandom(1, "L4Pool")
local candidates: Candidates? = nil
local active = false
local nextBeatAt = math.huge
local previousBeat: BeatKind? = nil
local beatsPlayed = 0
local lastQuietAt = -math.huge
local swimming = false
local alerted = false
local alertAt = math.huge
local cooldownUntil = -math.huge
local nextAlertCheck = -math.huge
local alerts = 0
local flipped = false
local flippedBy: Player? = nil
local lever: { model: Model, from: number, lit: boolean }? = nil
local lit: { [BasePart]: number } = {} -- fixtures the switch lit -> their BaseBrightness before

local function candidateSet(): Candidates?
	local cached = candidates
	if cached then
		return cached
	end
	local layout = Builder.getLayout(LEVEL)
	if not layout then
		log.error("no %s layout; the pool stays quiet", LEVEL)
		return nil
	end
	local built = Level4.candidates(layout)
	candidates = built
	return built
end

local function natatoriumBox(): (Vector3, Vector3)
	local layout = Builder.getLayout(LEVEL)
	local origin = WorldConfig.levelOrigin(LEVEL)
	if layout then
		for _, room in layout.rooms do
			if room.id == POOL_ROOM then
				local r = room.rect
				local depth = 0
				for _, basin in (layout.basins or {}) :: { LayoutSchema.Basin } do
					depth = math.max(depth, basin.depth)
				end
				return origin + Vector3.new(r.x, -depth - 1, r.z),
					origin + Vector3.new(r.x + r.w, LayoutSchema.roomHeight(layout, room), r.z + r.d)
			end
		end
	end
	return origin, origin
end

--------------------------------------------------------------------------------
-- Floodlights
--------------------------------------------------------------------------------

local function lightsOn(player: Player?)
	local fixtures = deps.floodlights()
	for _, fixture in fixtures do
		local part = fixture.part
		if part and lit[part] == nil then
			lit[part] = math.max(0, Attributes.getNumber(part, W.BaseBrightness, 0))
			deps.setBase(part, fixture.brightness)
		end
	end
	local low, high = natatoriumBox()
	deps.playAt(STRIKE_PRESET, (low + high) / 2, 1.2)
	local freed = deps.releaseGrab("Floodlight")
	if not freed then
		local position, state = deps.creature()
		if Level4.blinds(position, state, low, high) then
			local from = if position then Level4.nearestLight(position, fixtures) else nil
			deps.stun(GameConfig.StunSeconds, from or (low + high) / 2)
			if player then
				deps.stat(player, STUN_STAT)
			end
		end
	end
	for _, other in deps.players() do
		deps.notify(other, ON_KEY)
	end
	log.info("the pool floodlights are on")
end

-- Throws the emergency switch `host` (a FloodlightSwitch model) for `player` (see the header). False when the
-- floodlights are already on.
function Level4.Flip(player: Player?, host: Instance): boolean
	if flipped or not host:IsA("Model") or Attributes.getBool(host, W.On, false) then
		return false
	end
	local model = host :: Model
	flipped = true
	flippedBy = player
	local now = deps.now()
	lastQuietAt = math.max(lastQuietAt, now)
	model:SetAttribute(W.On, true)
	deps.refresh(model)
	lever = { model = model, from = now, lit = false }
	local base = model.PrimaryPart
	deps.playAt(BREAKER_PRESET, if base then base.CFrame.Position else model:GetPivot().Position, 1)
	local startAt = now + LEAD + BREAKER_DELAY
	local args: { [string]: Types.OneShotArg } = { id = Scenes.FloodlightsId }
	for index, fixture in deps.floodlights() do
		local arg = Scenes.FloodlightArgs[index]
		if arg then
			args[arg] = fixture.id
		end
	end
	deps.oneShot(TIMELINE_KIND, startAt, args, nil)
	lights:At(startAt, "floodlights", function()
		lightsOn(flippedBy)
	end)
	return true
end

local function stepLever(now: number)
	local current = lever
	if not current then
		return
	end
	local t = now - current.from
	local value = Level4.leverAt(t)
	local litNow = value >= LEVER_LIT_AT
	current.lit = current.lit or litNow
	xpcall(deps.poseSwitch, function(err: any)
		log.warnThrottled("lever", 10, "posing the floodlight switch failed: %s", tostring(err))
	end, current.model, value, current.lit)
	if t >= LEVER_SECONDS then
		lever = nil
	end
end

--------------------------------------------------------------------------------
-- Pool activation + ambience
--------------------------------------------------------------------------------

local function stepPool(now: number)
	local list = deps.swimmers()
	local on = #list > 0
	if on and not swimming then
		alerted = false
		alertAt = now + random:NextNumber(ALERT_MIN, ALERT_MAX)
	end
	swimming = on
	if now < nextAlertCheck then
		return
	end
	nextAlertCheck = now + ALERT_CHECK
	local _, state = deps.creature()
	local decision = Level4.poolAlert({
		swimming = swimming,
		alerted = alerted,
		alertAt = alertAt,
		cooldownUntil = cooldownUntil,
		now = now,
		state = state,
	})
	if decision == "Done" and swimming then
		alerted = true
	elseif decision == "Alert" then
		local swimmer = list[random:NextInteger(1, #list)]
		local root = deps.rootOf(swimmer)
		if root then
			deps.alert(root, ALERT_PRIORITY)
			alerted = true
			alerts += 1
			cooldownUntil = now + ALERT_COOLDOWN
			log.debug("the Creature was called to the water by %s", swimmer.Name)
		end
	end
end

local function tryBeat(listener: Player, only: BeatKind?): boolean
	local set = candidateSet()
	local root = deps.rootOf(listener)
	if not (set and root) then
		return false
	end
	local eyes = LevelKit.eyes(deps.players(), deps.eyeOf)
	local remaining: { BeatKind } = if only then { only } else table.clone(BEAT_KINDS)
	while #remaining > 0 do
		local kind: BeatKind? = if only then only else Level4.pickBeat(random, previousBeat, remaining)
		if kind == nil then
			return false
		end
		local point = Level4.place(kind, set, root, eyes, deps.lineClear, random)
		if point then
			deps.playAt(BEAT_PRESETS[kind], point, BEAT_VOLUME[kind])
			previousBeat = kind
			beatsPlayed += 1
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

local function stepBeats(now: number)
	if now < nextBeatAt then
		return
	end
	if now < lastQuietAt + QUIET_GAP then
		nextBeatAt = lastQuietAt + QUIET_GAP
		return
	end
	local players = deps.players()
	if #players == 0 then
		nextBeatAt = now + RETRY
		return
	end
	local listener = players[random:NextInteger(1, #players)]
	if tryBeat(listener, nil) then
		nextBeatAt = now + random:NextNumber(BEAT_MIN, BEAT_MAX)
	else
		nextBeatAt = now + RETRY
	end
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- One step at `now` (every Heartbeat from the Levels service; specs pass a fake clock): the switch's lever and its
-- lamps whenever they are moving, the pool session and the ambience while the squad is here.
function Level4.Step(now: number?)
	local t = now or deps.now()
	stepLever(t)
	lights:Run(t)
	beats:Run(t)
	if not active then
		return
	end
	stepPool(t)
	stepBeats(t)
end

-- A grab started or ended at server time `at` (FloodedPoolService's signals; specs call it).
function Level4.NoteDisturbance(at: number)
	lastQuietAt = math.max(lastQuietAt, at)
end

function Level4.IsFlipped(): boolean
	return flipped
end

function Level4.GetNextBeatAt(): number
	return nextBeatAt
end

function Level4.GetPreviousBeat(): BeatKind?
	return previousBeat
end

function Level4.BeatsPlayed(): number
	return beatsPlayed
end

function Level4.AlertCount(): number
	return alerts
end

function Level4.SetDependencies(fake: Dependencies?)
	deps = fake or realDependencies()
end

--------------------------------------------------------------------------------
-- Level controller + lifecycle
--------------------------------------------------------------------------------

-- LevelDirector: the squad reached the pool. The first beat comes BEAT_MIN..BEAT_MAX seconds in.
function Level4.Activate(_ctx: Types.LevelContext)
	active = true
	local now = deps.now()
	nextBeatAt = now + random:NextNumber(BEAT_MIN, BEAT_MAX)
	swimming = false
	alerted = false
	alertAt = math.huge
	nextAlertCheck = -math.huge
end

-- LevelDirector: the squad left it (or the run ended). The floodlights, once thrown, stay as they are.
function Level4.Deactivate()
	active = false
	nextBeatAt = math.huge
	swimming = false
	beats:Clear()
end

local controller: Types.LevelController = {
	LevelId = LEVEL,
	Activate = Level4.Activate,
	Deactivate = Level4.Deactivate,
}
Level4.Controller = controller

local function restoreLights()
	for part, base in lit do
		deps.setBase(part, base)
	end
	table.clear(lit)
end

local function floodlightsCommand(player: Player, _args: { string }): string?
	if flipped then
		return "the floodlights are already on this run"
	end
	for _, instance in CollectionService:GetTagged(Tags.FloodlightSwitch) do
		if instance:IsA("Model") and Attributes.getString(instance, W.LevelId, "") == LEVEL then
			return if Level4.Flip(player, instance) then "floodlights thrown" else "the switch would not move"
		end
	end
	return "no floodlight switch in this run (start a run first)"
end

local function poolBeatCommand(player: Player, args: { string }): string?
	if not active then
		return "go to Level 4 first (level 4)"
	end
	local wanted: BeatKind? = nil
	local text = args[1]
	if text then
		for _, kind: BeatKind in BEAT_KINDS do
			if string.lower(kind) == string.lower(text) then
				wanted = kind
			end
		end
		if wanted == nil then
			return "usage: poolbeat [" .. table.concat(BEAT_KINDS, "|") .. "]"
		end
	end
	if not tryBeat(player, wanted) then
		return "nowhere out of sight " .. BAND_MIN .. "-" .. BAND_MAX .. " studs from you for that beat"
	end
	return "played " .. tostring(previousBeat)
end

function Level4.Init(serviceTrove: Trove.Trove)
	serviceTrove:Add(InteractionService.Register({
		kind = PROMPT_KIND,
		filter = function(host: Instance, _prompt: ProximityPrompt): boolean
			return host:HasTag(Tags.FloodlightSwitch) and not Attributes.getBool(host, W.On, false)
		end,
		onComplete = function(player: Player, _prompt: ProximityPrompt, host: Instance)
			Level4.Flip(player, host)
		end,
	}))
	serviceTrove:Add(FloodedPoolService.GrabStarted:Connect(function(_player: Player)
		Level4.NoteDisturbance(deps.now())
	end))
	serviceTrove:Add(FloodedPoolService.GrabEnded:Connect(function(_player: Player, _outcome: string)
		Level4.NoteDisturbance(deps.now())
	end))
	DevToolsService.Register("floodlights", "floodlights: throw the pool's emergency switch now", floodlightsCommand)
	DevToolsService.Register("poolbeat", "poolbeat [kind]: play a pool ambience beat around you now", poolBeatCommand)
end

function Level4.BeginRun(ctx: Types.RunContext)
	beats:Clear()
	lights:Clear()
	restoreLights()
	random = MathUtil.seededRandom(ctx.seed, "L4Pool")
	active = false
	nextBeatAt = math.huge
	previousBeat = nil
	beatsPlayed = 0
	lastQuietAt = -math.huge
	swimming = false
	alerted = false
	alertAt = math.huge
	cooldownUntil = -math.huge
	nextAlertCheck = -math.huge
	alerts = 0
	flipped = false
	flippedBy = nil
	lever = nil
end

function Level4.EndRun()
	beats:Clear()
	lights:Clear()
	active = false
	nextBeatAt = math.huge
	lever = nil
	flippedBy = nil
	restoreLights()
end

return table.freeze(Level4)
