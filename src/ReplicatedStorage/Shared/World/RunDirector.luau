--!strict
-- RunDirector: everything a run randomizes, as one pure function of (seed, difficulty, layouts, graph).
--
--   Objectives     each floor's objective item (ObjectiveConfig; a floor without one has none): item.count of the
--                  layout's fair item.candidate anchors (objectiveCandidates: at least EntryClearance studs walked from
--                  the floor's entry, never in the room of a CreatureScarePose), as props of kind item.prop (the prop
--                  is the same on every run that uses its anchor), listed in plan.objectives[levelId]
--                  (RunDirector.objectiveOf). Several items lie in different rooms, at least PickSpacing studs apart,
--                  and (three or more) in at least PickQuarters quarters of the floor: a seeded pass takes the first
--                  shuffled candidate that keeps those rules, and a pass that falls short or bunches up is
--                  re-shuffled, up to PICK_ATTEMPTS times. One stream per level ("Objective|<level>"), independent
--                  of the difficulty: a run's objective spots are a pure function of the seed.
--   BearTrap       DifficultyConfig.trapCount Level0 TrapCandidate anchors. First the guard traps: the ref (a
--                  TrapCandidate on the approach) of each of the first item.guarded fuses picked, so at least that
--                  many fuses are guarded; then the rest. No two traps closer than MinTrapSpacing studs, and never
--                  inside an airlock, a stairwell, the level's entry / exit room or a room holding PlayerSpawn anchors.
--   Battery        batteriesPerLevel BatteryCandidate anchors on every school level (today's battery props).
--   batteries      spec v2's radar batteries (plan.batteries[level], pickBatteries; not props yet): on every sneaking
--                  stage, up to the difficulty's RadarConfig BatteriesMax BatteryCandidate anchors in pick order (a
--                  squad of n uses the first RadarRules.batteriesPlaced), stream "Batteries|<level>": the first
--                  20-60 studs walked from the entry, the second within 40 walked of the main station, every pair 30
--                  walked apart, none in a dead end; a floor that cannot keep a rule degrades (fewest broken rules,
--                  then the lowest id).
--   flasks         spec v2's stun flasks (plan.flasks[level], pickFlasks): DifficultyConfig flasksPerStage
--                  FlaskCandidate anchors, stream "Flasks|<level>"; each pick is also a ChemicalFlask prop.
--   Stations       a floor whose objective picks its stations (ObjectiveConfig `stations`: the rooftops' feeders): 3
--                  of 6 on both arcs (pickStations), stream "Objective|<level>", in plan.objectives[levelId].
--   lockedGrates   round(lockedGrateFraction x lockable) of each level's Lockable grates (never CriticalPath ones).
--                  A roll stands only while ZoneGraph still proves the level solvable with those grates locked and
--                  every Gate door shut. A failing roll is re-rolled deterministically, up to MaxRerolls times per
--                  level; a level that never passes keeps every grate unlocked. `rerolls` counts every re-roll.
--
--   Route          plan.route: the stairwell every floor is left by (pickRoute), one of its pair's three candidates
--                  (WorldConfig.stairwellCandidates: North, Middle, South), uniform by the seed (stream
--                  "Route|<from>"), drawn again while it is unfair for the entry the previous pick leads to: its exit
--                  vestibule under RouteFairShare of the longest candidate's walk from the entry, or (the
--                  CreatureSpawnLevels) fewer than MinCreatureSpawns Creature starts CreatureBand studs from its entry vestibule, out of
--                  sight and outside every objective room. The unused candidates are jammed shut for the run.
--
-- Pure: no instances, no clocks, no global random. Every decision draws from its own Rng.seeded(seed, <decision key>)
-- stream (Shared/Util/Rng: the same numbers in Lune, on Roblox and in the web's port, web/src/game/worldData.js) and
-- walks layouts, anchors and grates in list order, so the same inputs always produce an identical plan on every
-- platform, and changing one decision (say the trap count) never shifts another (the grate locks). A run picks
-- where props go, never how they look: a prop's variant is fixed per anchor (variantOf). Plans are frozen.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local ObjectivePlaces = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ObjectivePlaces)
local RadarConfig = require(ReplicatedStorage.Shared.Config.RadarConfig)
local RadarRules = require(ReplicatedStorage.Shared.Rules.RadarRules)
local Rng = require(ReplicatedStorage.Shared.Util.Rng)
local StageConfig = require(ReplicatedStorage.Shared.Config.StageConfig)
local TunnelRules = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.TunnelRules)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local ZoneGraph = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph)

local log = Log.new("RunDirector")

type Rng = Rng.Rng
type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor
type GrateSpec = LayoutSchema.GrateSpec

local TRAP_LEVEL: Enums.LevelId = "Level0_Basement"

local MIN_TRAP_SPACING = 6 -- studs, horizontal
local BATTERY_SPACING = 10 -- preferred, not required: spreads batteries over a level
local TRAP_ATTEMPTS = 16 -- fresh shuffles tried when the spacing rule leaves a trap short
local MAX_REROLLS = 64
local PICK_ATTEMPTS = 24 -- fresh shuffles tried when a multi-item pick falls short of the room / spacing / spread rules
local VARIANT_RANGE = 1000000
local ROUTE_ATTEMPTS = 8 -- draws from a floor's Route stream before falling back to its first fair candidate
local ROUTE_FAIR_SHARE = 0.6 -- an exit is at least this share of the longest exit candidate's walk from the entry
local CREATURE_BAND = { 70, 140 } -- studs walked from the entry to a Creature start (the web's SpawnTuning)
local MIN_CREATURE_SPAWNS = 2
local CREATURE_SPAWN_LEVELS: { [string]: boolean } = { Level2_Auditorium = true }

local RunDirector = {}

RunDirector.PropKinds = table.freeze({
	BearTrap = "BearTrap",
	ChemicalFlask = "ChemicalFlask",
	Battery = "Battery",
})
RunDirector.MinTrapSpacing = MIN_TRAP_SPACING
RunDirector.MaxRerolls = MAX_REROLLS
RunDirector.PickAttempts = PICK_ATTEMPTS
RunDirector.TrapLevel = TRAP_LEVEL
RunDirector.RouteAttempts = ROUTE_ATTEMPTS
RunDirector.RouteFairShare = ROUTE_FAIR_SHARE
RunDirector.CreatureBand = table.freeze(table.clone(CREATURE_BAND))
RunDirector.MinCreatureSpawns = MIN_CREATURE_SPAWNS
RunDirector.CreatureSpawnLevels = table.freeze(table.clone(CREATURE_SPAWN_LEVELS))

--------------------------------------------------------------------------------
-- Rules (public so specs and later services ask the same questions)
--------------------------------------------------------------------------------

-- Rooms of `layout` that never receive a trap: airlocks, stairwell housings, the entry and exit rooms, and every
-- room holding a PlayerSpawn anchor.
function RunDirector.trapExcludedRooms(layout: Layout): { [string]: boolean }
	local excluded: { [string]: boolean } = { [layout.entry] = true, [layout.exit] = true }
	for _, room in layout.rooms do
		if room.kind == "Airlock" or room.kind == "Stairwell" then
			excluded[room.id] = true
		end
	end
	for _, anchor in layout.anchors do
		if anchor.kind == "PlayerSpawn" then
			excluded[anchor.room] = true
		end
	end
	return excluded
end

-- Grates the director may lock on `layout`: Lockable and not on the critical path, in layout order.
function RunDirector.lockableGrates(layout: Layout): { GrateSpec }
	local out: { GrateSpec } = {}
	local vents = layout.vents
	if not vents then
		return out
	end
	for _, grate in vents.grates do
		if grate.lockable and not grate.criticalPath then
			table.insert(out, grate)
		end
	end
	return out
end

-- How many of `lockableCount` grates a run locks at `fraction` (round half away from zero, clamped).
function RunDirector.lockCount(fraction: number, lockableCount: number): number
	if lockableCount <= 0 or not MathUtil.isFinite(fraction) then
		return 0
	end
	return math.clamp(math.round(fraction * lockableCount), 0, lockableCount)
end

-- Every Gate door of `layout` shut: the worst case the level's scripted gates can produce (a hidden Gate is the way on
-- its floor's script opens, so it never counts shut).
function RunDirector.gateBlocked(layout: Layout): Types.BlockedSet
	local blocked: Types.BlockedSet = {}
	for _, door in layout.doors do
		if door.kind == "Gate" and not LayoutSchema.hiddenGate(door) then
			blocked[door.id] = true
		end
	end
	return blocked
end

-- The portals `plan` closes on `layout`: its Gate doors plus the grates the plan locked there.
function RunDirector.blockedFor(plan: Types.SpawnPlan, layout: Layout): Types.BlockedSet
	local blocked = RunDirector.gateBlocked(layout)
	local vents = layout.vents
	if vents then
		for _, grate in vents.grates do
			if plan.lockedGrates[grate.id] then
				blocked[grate.id] = true
			end
		end
	end
	return blocked
end

--------------------------------------------------------------------------------
-- Choosing anchors
--------------------------------------------------------------------------------

local function anchorsOfKind(layout: Layout, kind: Enums.AnchorKind, excludedRooms: { [string]: boolean }?): { Anchor }
	local out: { Anchor } = {}
	for _, anchor in layout.anchors do
		if anchor.kind == kind and not (excludedRooms and excludedRooms[anchor.room]) then
			table.insert(out, anchor)
		end
	end
	return out
end

local function spacedFrom(anchor: Anchor, chosen: { Anchor }, spacing: number): boolean
	if spacing <= 0 then
		return true
	end
	for _, other in chosen do
		if MathUtil.horizontalDistance(anchor.pos, other.pos) < spacing then
			return false
		end
	end
	return true
end

-- One seeded pass over `candidates`: takes anchors in shuffled order while they keep `spacing` from every anchor
-- already taken (and from every `fixed` one, placed before the pass). Returns the taken anchors and the ones passed
-- over (in the order they were met).
local function spacedPass(
	candidates: { Anchor },
	count: number,
	random: Rng,
	spacing: number,
	fixed: { Anchor }?
): ({ Anchor }, { Anchor })
	local order = Rng.shuffle(table.clone(candidates), random)
	local chosen: { Anchor } = {}
	local passed: { Anchor } = {}
	for _, anchor in order do
		if #chosen >= count then
			break
		end
		if spacedFrom(anchor, chosen, spacing) and (fixed == nil or spacedFrom(anchor, fixed, spacing)) then
			table.insert(chosen, anchor)
		else
			table.insert(passed, anchor)
		end
	end
	return chosen, passed
end

-- Seeded choice of up to `count` anchors that are all at least `spacing` apart. A short pass is retried with
-- fresh shuffles (from the same stream), keeping the fullest result.
local function chooseSpaced(
	candidates: { Anchor },
	count: number,
	random: Rng,
	spacing: number,
	fixed: { Anchor }?
): { Anchor }
	local best: { Anchor } = {}
	if count <= 0 or #candidates == 0 then
		return best
	end
	for _ = 1, TRAP_ATTEMPTS do
		local chosen = spacedPass(candidates, count, random, spacing, fixed)
		if #chosen > #best then
			best = chosen
		end
		if #best >= count then
			break
		end
	end
	return best
end

-- Seeded choice of up to `count` anchors that prefers `spacing` but fills from the closer ones when it must.
local function choosePreferSpaced(candidates: { Anchor }, count: number, random: Rng, spacing: number): { Anchor }
	if count <= 0 or #candidates == 0 then
		return {}
	end
	local chosen, passed = spacedPass(candidates, count, random, spacing)
	for _, anchor in passed do
		if #chosen >= count then
			break
		end
		table.insert(chosen, anchor)
	end
	return chosen
end

-- Puts `chosen` back into layout order, so a plan reads (and diffs) in blueprint order.
local function inLayoutOrder(layout: Layout, chosen: { Anchor }): { Anchor }
	local index: { [string]: number } = {}
	for i, anchor in layout.anchors do
		index[anchor.id] = i
	end
	local sorted = table.clone(chosen)
	table.sort(sorted, function(a: Anchor, b: Anchor): boolean
		return (index[a.id] or 0) < (index[b.id] or 0)
	end)
	return sorted
end

-- The look variant of a `kind` prop on `anchorId` (1..VARIANT_RANGE): fixed per anchor, never per run, so the prop
-- a run places on an anchor looks the same on every run and platform (the web exports one per candidate anchor).
function RunDirector.variantOf(kind: string, layoutId: string, anchorId: string): number
	return Rng.seeded(1, "Variant|" .. kind .. "|" .. layoutId .. "|" .. anchorId):NextInteger(1, VARIANT_RANGE)
end

-- The planned prop of `kind` on `anchor`, exactly as a run plans it.
function RunDirector.plannedProp(kind: string, layout: Layout, anchor: Anchor): Types.PlannedProp
	local prop: Types.PlannedProp = {
		kind = kind,
		anchorId = anchor.id,
		levelId = layout.id,
		cframe = Builder.anchorCFrame(layout.id, anchor),
		variant = RunDirector.variantOf(kind, layout.id, anchor.id),
	}
	table.freeze(prop)
	return prop
end

local function addProps(props: { Types.PlannedProp }, kind: string, layout: Layout, chosen: { Anchor })
	for _, anchor in inLayoutOrder(layout, chosen) do
		table.insert(props, RunDirector.plannedProp(kind, layout, anchor))
	end
end

local function warnShort(what: string, layout: Layout, placed: number, wanted: number)
	if placed < wanted then
		log.warn("%s: placed %d of %d %s (not enough candidate anchors)", layout.id, placed, wanted, what)
	end
end

--------------------------------------------------------------------------------
-- Floor objectives
--------------------------------------------------------------------------------

-- The anchor of `layout` with id `id`, if any.
local function anchorById(layout: Layout, id: string?): Anchor?
	if id == nil then
		return nil
	end
	for _, anchor in layout.anchors do
		if anchor.id == id then
			return anchor
		end
	end
	return nil
end

-- The item of a floor objective (an error for a floor without one: callers ask only for floors with an item).
local function itemOf(spec: ObjectiveConfig.FloorSpec): ObjectiveConfig.ItemSpec
	local item = spec.item
	assert(item, string.format("RunDirector: %s has no item", spec.id))
	return item
end

-- The planned prop of `spec`'s item on its candidate `anchor` of `layout`, exactly as every run that picks the anchor
-- plans it (and as the web's export builds it on every candidate): the anchor's own variant.
function RunDirector.objectiveProp(layout: Layout, spec: ObjectiveConfig.FloorSpec, anchor: Anchor): Types.PlannedProp
	return RunDirector.plannedProp(itemOf(spec).prop, layout, anchor)
end

-- The item candidates of `layout` a run may use for `spec` (layout order): at least ObjectiveConfig.EntryClearance
-- studs walked from the floor's entry, and never in a room holding a CreatureScarePose (the Floor 1 scare classroom).
-- Cached per layout (the walk is the same every run).
local candidateCache: { [Layout]: { [string]: { Anchor } } } = setmetatable({}, { __mode = "k" }) :: any
function RunDirector.objectiveCandidates(layout: Layout, spec: ObjectiveConfig.FloorSpec): { Anchor }
	local item = itemOf(spec)
	local byKind = candidateCache[layout]
	if not byKind then
		byKind = {}
		candidateCache[layout] = byKind
	end
	local cached = byKind[item.candidate]
	if cached then
		return cached
	end
	local scareRooms: { [string]: boolean } = {}
	for _, anchor in layout.anchors do
		if anchor.kind == "CreatureScarePose" then
			scareRooms[anchor.room] = true
		end
	end
	local out: { Anchor } = {}
	for _, anchor in anchorsOfKind(layout, item.candidate, scareRooms) do
		local place = { id = anchor.id, kind = anchor.kind, room = anchor.room, pos = anchor.pos }
		if ObjectivePlaces.entryDistance(layout, place) >= ObjectiveConfig.EntryClearance then
			table.insert(out, anchor)
		end
	end
	table.freeze(out)
	byKind[item.candidate] = out
	return out
end

-- Whether `anchor` keeps the multi-item rules with the items already `taken`: another room, PickSpacing apart.
local function keepsApart(anchor: Anchor, taken: { Anchor }): boolean
	for _, other in taken do
		if other.room == anchor.room then
			return false
		end
	end
	return spacedFrom(anchor, taken, ObjectiveConfig.PickSpacing)
end

-- How many quarters of the floor `picks` lie in.
function RunDirector.quarters(picks: { Anchor }): number
	local seen: { [number]: boolean } = {}
	local count = 0
	for _, anchor in picks do
		local q = ObjectivePlaces.quarter(anchor.pos)
		if not seen[q] then
			seen[q] = true
			count += 1
		end
	end
	return count
end

-- Whether a full pick of `count` items is spread enough: three or more items in at least PickQuarters quarters.
local function spreadEnough(picks: { Anchor }, count: number): boolean
	return count < 3 or RunDirector.quarters(picks) >= ObjectiveConfig.PickQuarters
end

-- The seeded objective picks of one level: `spec.item.count` of its fair candidates (objectiveCandidates, in pick
-- order; several in different rooms, PickSpacing apart and spread over PickQuarters quarters) and the guard traps of
-- the first `spec.item.guarded` of them whose ref is an eligible TrapCandidate. Depends on the seed only.
function RunDirector.pickObjective(
	seed: number,
	layout: Layout,
	spec: ObjectiveConfig.FloorSpec
): ({ Anchor }, { Anchor })
	local item = itemOf(spec)
	local candidates = RunDirector.objectiveCandidates(layout, spec)
	local random = Rng.seeded(seed, "Objective|" .. layout.id)
	local count = math.min(item.count, #candidates)
	local picks: { Anchor } = {}
	for _ = 1, if count > 1 then PICK_ATTEMPTS else 1 do
		local pass: { Anchor } = {}
		for _, anchor in Rng.shuffle(table.clone(candidates), random) do
			if #pass >= count then
				break
			end
			if keepsApart(anchor, pass) then
				table.insert(pass, anchor)
			end
		end
		if #pass > #picks or #picks == 0 then
			picks = pass
		end
		if #pass >= count and spreadEnough(pass, count) then
			picks = pass
			break
		end
	end
	local guards: { Anchor } = {}
	local wanted = item.guarded or 0
	if wanted > 0 then
		local excluded = RunDirector.trapExcludedRooms(layout)
		for _, pick in picks do
			if #guards >= wanted then
				break
			end
			local guard = anchorById(layout, pick.ref)
			if
				guard
				and guard.kind == "TrapCandidate"
				and not excluded[guard.room]
				and spacedFrom(guard, guards, MIN_TRAP_SPACING)
			then
				table.insert(guards, guard)
			end
		end
	end
	return picks, guards
end

--------------------------------------------------------------------------------
-- Route: which stairwell every floor is left by
--------------------------------------------------------------------------------

export type RouteCheck = {
	stairwellId: string,
	distance: number, -- studs walked from the floor's entry to this exit vestibule (math.huge: no way)
	share: number, -- distance / the longest candidate's distance (0 when none is finite)
	creatureSpawns: number?, -- Creature start candidates on the next floor from this entry (levels with the rule)
	fair: boolean,
}

local routeCache: { [Layout]: { [string]: { RouteCheck } } } = setmetatable({}, { __mode = "k" }) :: any

local STATION_KINDS: { [string]: boolean } = { BreakerPanel = true }

-- Rooms of `layout` a Creature never starts in: those holding an objective station or any item candidate (whatever a
-- run picks), so the rule holds for every seed.
local function objectiveRooms(layout: Layout): { [string]: boolean }
	local spec = ObjectiveConfig.forLevel(layout.id)
	local item = if spec then spec.item else nil
	local rooms: { [string]: boolean } = {}
	for _, anchor in layout.anchors do
		if STATION_KINDS[anchor.kind] or (item and anchor.kind == item.candidate) then
			rooms[anchor.room] = true
		end
	end
	return rooms
end

-- How many Creature start candidates `layout` keeps for a squad arriving in `entryRoom` (the web's spawn rule):
-- PatrolWaypoint / CreatureSpawn anchors CreatureBand studs walked from the arrival point, out of sight of the
-- entry (not in it, nor in a room a doorway of it opens into), and never in an objective room.
function RunDirector.creatureSpawnCount(layout: Layout, entryRoom: string): number
	local seen: { [string]: boolean } = { [entryRoom] = true }
	for _, door in layout.doors do
		if door.kind ~= "Boarded" and table.find(door.rooms, entryRoom) then
			for _, room in door.rooms do
				seen[room] = true
			end
		end
	end
	local avoid = objectiveRooms(layout)
	local from = ObjectivePlaces.arrivalPoint(layout, entryRoom)
	local count = 0
	for _, anchor in layout.anchors do
		if (anchor.kind == "PatrolWaypoint" or anchor.kind == "CreatureSpawn") and not seen[anchor.room] then
			if not avoid[anchor.room] then
				local walk = ObjectivePlaces.walkDistance(layout, entryRoom, from, anchor.room, anchor.pos)
				if walk >= CREATURE_BAND[1] and walk <= CREATURE_BAND[2] then
					count += 1
				end
			end
		end
	end
	return count
end

-- The fairness verdict of every exit candidate of `layout` for a squad that entered it in `entryRoom` (candidate
-- order): fair when its vestibule is at least RouteFairShare of the longest candidate's walk from the entry, and the
-- next floor (on the Creature-start levels) keeps at least MinCreatureSpawns starts from its entry vestibule. `byId`
-- holds the layouts (the next floor's may be missing: then only the walk counts). Cached per layout and entry.
function RunDirector.routeChecks(layout: Layout, entryRoom: string, byId: { [string]: Layout }): { RouteCheck }
	local cached = routeCache[layout]
	if not cached then
		cached = {}
		routeCache[layout] = cached
	end
	local hit = cached[entryRoom]
	if hit then
		return hit
	end
	local from = ObjectivePlaces.arrivalPoint(layout, entryRoom)
	local checks: { RouteCheck } = {}
	local longest = 0
	for _, spec in WorldConfig.stairwellCandidates(layout.id) do
		local to = ObjectivePlaces.arrivalPoint(layout, spec.fromRoom)
		local distance = ObjectivePlaces.walkDistance(layout, entryRoom, from, spec.fromRoom, to)
		if distance < math.huge then
			longest = math.max(longest, distance)
		end
		local nextLayout = byId[spec.to]
		local spawns = if nextLayout and CREATURE_SPAWN_LEVELS[spec.to]
			then RunDirector.creatureSpawnCount(nextLayout, spec.toRoom)
			else nil
		table.insert(
			checks,
			{ stairwellId = spec.id, distance = distance, share = 0, creatureSpawns = spawns, fair = false }
		)
	end
	for _, check in checks do
		check.share = if longest > 0 and check.distance < math.huge then check.distance / longest else 0
		check.fair = check.distance < math.huge
			and check.share >= ROUTE_FAIR_SHARE - 1e-9
			and (check.creatureSpawns == nil or check.creatureSpawns >= MIN_CREATURE_SPAWNS)
		table.freeze(check)
	end
	table.freeze(checks)
	cached[entryRoom] = checks
	return checks
end

-- The run's route: for every floor pair in climbing order, one of its three candidate stairwells (slot order North,
-- Middle, South), uniform by the seed (stream "Route|<from>"); a draw that is not fair for the floor's entry (the
-- previous pick's upper vestibule; the basement's layout entry) is drawn again from the same stream, up to
-- RouteAttempts draws, then the first fair candidate in slot order (else the middle one). { [from level] = id }.
function RunDirector.pickRoute(seed: number, layouts: { Layout }?): { [string]: string }
	local byId: { [string]: Layout } = {}
	local list: { Layout } = if layouts then layouts else Builder.layouts()
	for _, layout in list do
		byId[layout.id] = byId[layout.id] or layout
	end
	local route: { [string]: string } = {}
	local entry: string? = nil
	for _, from in WorldConfig.LevelOrder do
		local candidates = WorldConfig.stairwellCandidates(from)
		local layout = byId[from]
		if #candidates == 0 or not layout then
			entry = nil
			continue
		end
		local fair: { [string]: boolean } = {}
		for _, check in RunDirector.routeChecks(layout, entry or layout.entry, byId) do
			fair[check.stairwellId] = check.fair
		end
		local random = Rng.seeded(seed, "Route|" .. from)
		local pick: WorldConfig.StairwellSpec? = nil
		for _ = 1, ROUTE_ATTEMPTS do
			local candidate = candidates[random:NextInteger(1, #candidates)]
			if fair[candidate.id] then
				pick = candidate
				break
			end
		end
		if not pick then
			for _, candidate in candidates do
				if fair[candidate.id] then
					pick = candidate
					break
				end
			end
		end
		local chosen = pick or WorldConfig.routeExit(nil, from)
		if chosen then
			route[from] = chosen.id
			entry = chosen.toRoom
		end
	end
	return table.freeze(route)
end

-- The objective picks of `plan` on `levelId` (nil for a level without an objective or a plan without picks).
function RunDirector.objectiveOf(plan: Types.SpawnPlan, levelId: string): Types.ObjectivePicks?
	local objectives = plan.objectives
	return if objectives then objectives[levelId] else nil
end

--------------------------------------------------------------------------------
-- Picked stations (the rooftops' feeders)
--------------------------------------------------------------------------------

-- Whether `picks` lie on both arcs of the frame: at least one north and one south of its centre line.
function RunDirector.bothArcs(picks: { Anchor }): boolean
	local north, south = false, false
	for _, anchor in picks do
		if ObjectivePlaces.quarter(anchor.pos) <= 2 then
			north = true
		else
			south = true
		end
	end
	return north and south
end

-- The seeded station picks of one level (ObjectiveConfig `stations`: the rooftops' feeders): `count` of its candidate
-- anchors, from the level's objective stream ("Objective|<level>", the seed only). With `arcs`, a pass stands when it
-- holds both arcs (bothArcs); up to PickAttempts passes are shuffled, and if none stands the first pass trades its last
-- pick for the lowest-id candidate of the missing arc.
function RunDirector.pickStations(seed: number, layout: Layout, spec: ObjectiveConfig.FloorSpec): { Anchor }
	local stations = spec.stations
	assert(stations, string.format("RunDirector: %s has no picked stations", spec.id))
	local candidates = anchorsOfKind(layout, stations.candidate, nil)
	local count = math.min(stations.count, #candidates)
	if count == 0 then
		return {}
	end
	local random = Rng.seeded(seed, "Objective|" .. layout.id)
	local first: { Anchor }? = nil
	for _ = 1, PICK_ATTEMPTS do
		local order = Rng.shuffle(table.clone(candidates), random)
		local pass = table.move(order, 1, count, 1, {})
		if not stations.arcs or RunDirector.bothArcs(pass) then
			return pass
		end
		first = first or pass
	end
	local picks = first :: { Anchor }
	local northHeld = ObjectivePlaces.quarter(picks[1].pos) <= 2
	local missing: Anchor? = nil
	for _, anchor in candidates do
		if (ObjectivePlaces.quarter(anchor.pos) <= 2) ~= northHeld and (missing == nil or anchor.id < missing.id) then
			missing = anchor
		end
	end
	if missing and count >= 2 then
		picks[count] = missing
	end
	return picks
end

--------------------------------------------------------------------------------
-- Radar batteries and stun flasks (docs/design/game-spec-v2.md 3.2, 4.2)
--------------------------------------------------------------------------------

export type Place = { room: string, pos: Vector3 }

-- A floor's walks for the placement rules: the walk graph the objective fairness rules use (TunnelRules: every door
-- but the shut Gates, crawlways too, the vents a squad can always use) and each battery candidate's walk to every point.
type Walks = {
	graph: TunnelRules.WalkGraph,
	from: { [string]: { number } }, -- candidate id -> distances over the graph
}

local walksCache: { [Layout]: Walks } = setmetatable({}, { __mode = "k" }) :: any

local function walksOf(layout: Layout): Walks
	local cached = walksCache[layout]
	if cached then
		return cached
	end
	local walks: Walks = { graph = TunnelRules.walkGraph(layout :: any, true), from = {} }
	walksCache[layout] = walks
	return walks
end

local function flat(v: Vector3): Vector2
	return Vector2.new(v.X, v.Z)
end

-- Studs walked between two points of `layout` (math.huge when there is no way), on the placement rules' walk graph.
function RunDirector.walk(layout: Layout, a: Place, b: Place): number
	local walks = walksOf(layout)
	local g = walks.graph
	local dist = TunnelRules.distances(g, TunnelRules.seedsAt(g, a.room, flat(a.pos)))
	return TunnelRules.reach(g, dist, b.room, flat(b.pos), if a.room == b.room then { flat(a.pos) } else nil)
end

local function walkFromAnchor(layout: Layout, anchor: Anchor, to: Place): number
	local walks = walksOf(layout)
	local g = walks.graph
	local dist = walks.from[anchor.id]
	if not dist then
		dist = TunnelRules.distances(g, TunnelRules.seedsAt(g, anchor.room, flat(anchor.pos)))
		walks.from[anchor.id] = dist
	end
	return TunnelRules.reach(
		g,
		dist,
		to.room,
		flat(to.pos),
		if anchor.room == to.room then { flat(anchor.pos) } else nil
	)
end

-- The rooms of `layout` that are dead ends: fewer than two ways in or out (doors, crawlway mouths, open grates).
function RunDirector.deadEndRooms(layout: Layout): { [string]: boolean }
	local g = walksOf(layout).graph
	local out: { [string]: boolean } = {}
	for _, room in layout.rooms do
		local ways = g.members[room.id]
		if room.kind ~= "Solid" and room.kind ~= "Chase" and (ways == nil or #ways < 2) then
			out[room.id] = true
		end
	end
	return out
end

-- Where the squad enters `layout` on `route` (the previous floor's pick; the layout's entry otherwise).
function RunDirector.entryPlace(layout: Layout, route: { [string]: string }?): Place
	local entry = WorldConfig.routeEntry(route, layout.id)
	local room = if entry and entry.to == layout.id then entry.toRoom else layout.entry
	return { room = room, pos = ObjectivePlaces.arrivalPoint(layout, room) }
end

-- The main station(s) of `layout` for a run (ObjectiveConfig mainStation): its anchors of that kind; the exit lock the
-- route's exit uses (the ExitLock nearest its vestibule); the run's picked stations (`picked`, the feeders); the exit
-- vestibule the route leaves by when the floor names none (the interim Auditorium's exit). Empty when there is none.
function RunDirector.mainStations(layout: Layout, route: { [string]: string }?, picked: { string }?): { Place }
	local spec = ObjectiveConfig.forLevel(layout.id)
	local kind: Enums.AnchorKind? = if spec then spec.mainStation else nil
	local out: { Place } = {}
	local exitSpec = WorldConfig.routeExit(route, layout.id)
	local exitRoom = if exitSpec and exitSpec.from == layout.id then exitSpec.fromRoom else nil
	local exitPlace: Place? = if exitRoom
		then { room = exitRoom, pos = ObjectivePlaces.arrivalPoint(layout, exitRoom) }
		else nil
	if kind == nil then
		if exitPlace then
			table.insert(out, exitPlace)
		end
		return out
	end
	local stations = if spec then spec.stations else nil
	local pickedSet: { [string]: boolean }? = nil
	if stations and stations.candidate == kind and picked then
		local set: { [string]: boolean } = {}
		for _, id in picked do
			set[id] = true
		end
		pickedSet = set
	end
	local best: Anchor? = nil
	local bestWalk = math.huge
	local stationKind: Enums.AnchorKind = kind
	for _, anchor in anchorsOfKind(layout, stationKind, nil) do
		if pickedSet and not pickedSet[anchor.id] then
			continue
		end
		if kind == "ExitLock" and exitPlace then
			local d = walkFromAnchor(layout, anchor, exitPlace)
			if d < bestWalk then
				best, bestWalk = anchor, d
			end
		else
			table.insert(out, { room = anchor.room, pos = anchor.pos })
		end
	end
	if best then
		table.insert(out, { room = best.room, pos = best.pos })
	end
	return out
end

-- How many of the battery placement rules `anchor` breaks as the `slot`-th pick next to `taken`: the slot's own rule
-- (1st: EntryMin..EntryMax walked from `entry`; 2nd: within StationReach of a `stations` place, when there is one), the
-- spacing (PairSpacing walked from every battery taken) and the dead end (none in one).
local function brokenRules(
	layout: Layout,
	anchor: Anchor,
	slot: number,
	taken: { Anchor },
	entry: Place,
	stations: { Place },
	dead: { [string]: boolean }
): number
	local rules = RadarConfig.Placement
	local broken = 0
	if slot == 1 then
		local d = walkFromAnchor(layout, anchor, entry)
		if d < rules.EntryMin or d > rules.EntryMax then
			broken += 1
		end
	elseif slot == 2 and #stations > 0 then
		local near = false
		for _, station in stations do
			if walkFromAnchor(layout, anchor, station) <= rules.StationReach then
				near = true
				break
			end
		end
		if not near then
			broken += 1
		end
	end
	for _, other in taken do
		if walkFromAnchor(layout, anchor, { room = other.room, pos = other.pos }) < rules.PairSpacing then
			broken += 1
			break
		end
	end
	if dead[anchor.room] then
		broken += 1
	end
	return broken
end

-- The seeded battery picks of one sneaking stage (stream "Batteries|<level>"): up to the difficulty's BatteriesMax of
-- the layout's BatteryCandidate anchors, in pick order, so a squad of n takes the first RadarRules.batteriesPlaced. The
-- first lies EntryMin..EntryMax walked from `entry`, the second within StationReach of the main station, every pair
-- PairSpacing apart (walked), none in a dead end. Each slot takes the first shuffled candidate that keeps its rules; a
-- floor that cannot (too few candidates, or none in reach) degrades deterministically: the candidate breaking the
-- fewest rules, then the lowest id. `broken` counts the rules broken in all.
function RunDirector.pickBatteries(
	seed: number,
	difficulty: Enums.Difficulty,
	layout: Layout,
	entry: Place,
	stations: { Place }
): Types.BatteryPicks
	local candidates = anchorsOfKind(layout, "BatteryCandidate", nil)
	local count = math.min(RadarConfig.of(difficulty).BatteriesMax, #candidates)
	local order = Rng.shuffle(table.clone(candidates), Rng.seeded(seed, "Batteries|" .. layout.id))
	local dead = RunDirector.deadEndRooms(layout)
	local taken: { Anchor } = {}
	local used: { [string]: boolean } = {}
	local broken = 0
	for slot = 1, count do
		local pick: Anchor? = nil
		local fewest = math.huge
		for _, anchor in order do
			if used[anchor.id] then
				continue
			end
			local n = brokenRules(layout, anchor, slot, taken, entry, stations, dead)
			if n == 0 then
				pick, fewest = anchor, 0
				break
			end
			local best = pick
			if n < fewest or (n == fewest and best ~= nil and anchor.id < best.id) then
				pick, fewest = anchor, n
			end
		end
		local chosen = pick :: Anchor
		used[chosen.id] = true
		table.insert(taken, chosen)
		broken += fewest
	end
	local ids: { string } = {}
	for _, anchor in taken do
		table.insert(ids, anchor.id)
	end
	return table.freeze({ anchors = table.freeze(ids), broken = broken })
end

-- The seeded stun flasks of one stage (stream "Flasks|<level>"): the difficulty's flasksPerStage of the layout's
-- FlaskCandidate anchors, in pick order (fewer when the floor has fewer candidates).
function RunDirector.pickFlasks(seed: number, difficulty: Enums.Difficulty, layout: Layout): { string }
	local spec = if difficulty == "Nightmare" then DifficultyConfig.Nightmare else DifficultyConfig.Standard
	local candidates = anchorsOfKind(layout, "FlaskCandidate", nil)
	local count = math.min(spec.flasksPerStage[layout.id] or 0, #candidates)
	local ids: { string } = {}
	if count > 0 then
		local order = Rng.shuffle(table.clone(candidates), Rng.seeded(seed, "Flasks|" .. layout.id))
		for i = 1, count do
			table.insert(ids, order[i].id)
		end
	end
	return table.freeze(ids)
end

-- The batteries of `plan` a squad of `players` uses on `levelId` (the first RadarRules.batteriesPlaced of its picks).
function RunDirector.batteriesOf(plan: Types.SpawnPlan, levelId: string, players: number): { string }
	local all = plan.batteries
	local picks = if all then all[levelId] else nil
	if not picks then
		return {}
	end
	local n = math.min(#picks.anchors, RadarRules.batteriesPlaced(plan.difficulty, players))
	return table.move(picks.anchors, 1, n, 1, {})
end

--------------------------------------------------------------------------------
-- Locking grates
--------------------------------------------------------------------------------

-- The grates of `layout` locked this run, and how many re-rolls it took to keep the level solvable.
local function lockGrates(
	seed: number,
	fraction: number,
	layout: Layout,
	graph: Types.ZoneGraphData
): ({ GrateSpec }, number)
	local lockable = RunDirector.lockableGrates(layout)
	local count = RunDirector.lockCount(fraction, #lockable)
	if count == 0 then
		return {}, 0
	end
	local gates = RunDirector.gateBlocked(layout)
	if not ZoneGraph.isLevelSolvable(graph, layout, gates) then
		log.error("%s is unsolvable with its gates shut before any grate locks; no grate is locked", layout.id)
		return {}, 0
	end
	local random = Rng.seeded(seed, "Grates|" .. layout.id)
	local rerolls = 0
	for attempt = 0, MAX_REROLLS do
		local order = Rng.shuffle(table.clone(lockable), random)
		local chosen: { GrateSpec } = {}
		local blocked = table.clone(gates)
		for i = 1, count do
			local grate = order[i]
			table.insert(chosen, grate)
			blocked[grate.id] = true
		end
		if ZoneGraph.isLevelSolvable(graph, layout, blocked) then
			return chosen, rerolls
		end
		if attempt < MAX_REROLLS then
			rerolls += 1
		end
	end
	log.warn("%s: no solvable grate lock found in %d re-rolls; every grate stays unlocked", layout.id, MAX_REROLLS)
	return {}, rerolls
end

--------------------------------------------------------------------------------
-- Plan
--------------------------------------------------------------------------------

local function resolveDifficulty(difficulty: Enums.Difficulty): (Enums.Difficulty, DifficultyConfig.DifficultySpec)
	if difficulty == "Nightmare" then
		return "Nightmare", DifficultyConfig.Nightmare
	end
	if difficulty ~= "Standard" then
		log.warn("unknown difficulty %s; planning Standard", tostring(difficulty))
	end
	return "Standard", DifficultyConfig.Standard
end

-- The spawn plan for one run. `layouts` are the blueprints in run order (Builder.layouts()); `graph` is
-- ZoneGraph.build over them (the solvability proofs run on it).
function RunDirector.plan(
	seed: number,
	difficulty: Enums.Difficulty,
	layouts: { Layout },
	graph: Types.ZoneGraphData
): Types.SpawnPlan
	local runSeed = seed
	if not MathUtil.isFinite(runSeed) then
		log.warn("non-finite seed %s; planning seed 0", tostring(seed))
		runSeed = 0
	end
	local resolved: Enums.Difficulty, spec: DifficultyConfig.DifficultySpec = resolveDifficulty(difficulty)

	local byId: { [string]: Layout } = {}
	for _, layout in layouts do
		if byId[layout.id] == nil then
			byId[layout.id] = layout
		end
	end

	local props: { Types.PlannedProp } = {}

	-- Floor objectives (seed only); the basement's guard traps feed the trap plan below
	local objectives: { [string]: Types.ObjectivePicks } = {}
	local objectiveProps: { Types.PlannedProp } = {}
	local guardsByLevel: { [string]: { Anchor } } = {}
	for _, floor in ObjectiveConfig.Floors do
		local layout = byId[floor.levelId]
		local item = floor.item
		if not layout or not item then
			continue
		end
		local picks, guards = RunDirector.pickObjective(runSeed, layout, floor)
		warnShort(item.prop, layout, #picks, item.count)
		guardsByLevel[layout.id] = guards
		local anchorIds: { string } = {}
		for _, anchor in picks do
			table.insert(anchorIds, anchor.id)
			table.insert(objectiveProps, RunDirector.objectiveProp(layout, floor, anchor))
		end
		local guardIds: { string } = {}
		for _, guard in guards do
			table.insert(guardIds, guard.id)
		end
		objectives[layout.id] = table.freeze({
			levelId = layout.id,
			prop = item.prop,
			anchors = table.freeze(anchorIds),
			guards = table.freeze(guardIds),
		})
	end

	-- Picked stations (the rooftops' feeders; seed only)
	for _, floor in ObjectiveConfig.Floors do
		local layout = byId[floor.levelId]
		local stations = floor.stations
		if not layout or not stations then
			continue
		end
		local picks = RunDirector.pickStations(runSeed, layout, floor)
		warnShort(stations.prop, layout, #picks, stations.count)
		local anchorIds: { string } = {}
		for _, anchor in picks do
			table.insert(anchorIds, anchor.id)
		end
		objectives[layout.id] = table.freeze({
			levelId = layout.id,
			prop = stations.prop,
			anchors = table.freeze(anchorIds),
			guards = table.freeze({}),
		})
	end

	local route = RunDirector.pickRoute(runSeed, layouts)

	-- Bear traps: the objective's guard traps first, then the rest of the difficulty's count
	local basement = byId[TRAP_LEVEL]
	if basement then
		local guards: { Anchor } = guardsByLevel[basement.id] or {}
		local reserved: { [Anchor]: boolean } = {}
		for _, guard in guards do
			reserved[guard] = true
		end
		local candidates: { Anchor } = {}
		for _, anchor in anchorsOfKind(basement, "TrapCandidate", RunDirector.trapExcludedRooms(basement)) do
			if not reserved[anchor] then
				table.insert(candidates, anchor)
			end
		end
		local random = Rng.seeded(runSeed, "Traps|" .. basement.id)
		local fill = math.max(0, spec.trapCount - #guards)
		local chosen = chooseSpaced(candidates, fill, random, MIN_TRAP_SPACING, guards)
		for _, guard in guards do
			table.insert(chosen, guard)
		end
		warnShort("bear traps", basement, #chosen, spec.trapCount)
		addProps(props, RunDirector.PropKinds.BearTrap, basement, chosen)
	end

	-- Batteries
	for _, layout in layouts do
		if layout.id == "Lobby" or byId[layout.id] ~= layout then
			continue
		end
		local candidates = anchorsOfKind(layout, "BatteryCandidate", nil)
		if #candidates == 0 then
			continue
		end
		local random = Rng.seeded(runSeed, "Batteries|" .. layout.id)
		local chosen = choosePreferSpaced(candidates, spec.batteriesPerLevel, random, BATTERY_SPACING)
		warnShort("batteries", layout, #chosen, spec.batteriesPerLevel)
		addProps(props, RunDirector.PropKinds.Battery, layout, chosen)
	end

	-- Spec v2's radar batteries (every sneaking stage) and stun flasks (every stage with a count)
	local batteries: { [string]: Types.BatteryPicks } = {}
	local flasks: { [string]: { string } } = {}
	for _, layout in layouts do
		if byId[layout.id] ~= layout then
			continue
		end
		if StageConfig.isSneaking(layout.id) then
			local picked = objectives[layout.id]
			batteries[layout.id] = RunDirector.pickBatteries(
				runSeed,
				resolved,
				layout,
				RunDirector.entryPlace(layout, route),
				RunDirector.mainStations(layout, route, if picked then picked.anchors else nil)
			)
		end
		if (spec.flasksPerStage[layout.id] or 0) > 0 then
			local picked = RunDirector.pickFlasks(runSeed, resolved, layout)
			flasks[layout.id] = picked
			-- each picked spot holds a stun flask, built like the batteries and traps (its anchor's variant)
			local chosen: { Anchor } = {}
			for _, id in picked do
				table.insert(chosen, anchorById(layout, id) :: Anchor)
			end
			addProps(props, RunDirector.PropKinds.ChemicalFlask, layout, chosen)
		end
	end

	-- Grate locks
	local lockedGrates: { [string]: boolean } = {}
	local rerolls = 0
	for _, layout in layouts do
		if layout.id == "Lobby" or byId[layout.id] ~= layout or not layout.vents then
			continue
		end
		local locked, levelRerolls = lockGrates(runSeed, spec.lockedGrateFraction, layout, graph)
		rerolls += levelRerolls
		for _, grate in locked do
			lockedGrates[grate.id] = true
		end
	end

	-- Objective items last, in floor order and pick order
	for _, prop in objectiveProps do
		table.insert(props, prop)
	end

	table.freeze(props)
	table.freeze(lockedGrates)
	table.freeze(objectives)
	local plan: Types.SpawnPlan = {
		seed = runSeed,
		difficulty = resolved,
		props = props,
		lockedGrates = lockedGrates,
		rerolls = rerolls,
		objectives = objectives,
		route = route,
		batteries = table.freeze(batteries),
		flasks = table.freeze(flasks),
	}
	table.freeze(plan)
	return plan
end

-- Props of `kind` in `plan` (optionally on one level), in plan order.
function RunDirector.propsOf(plan: Types.SpawnPlan, kind: string, levelId: string?): { Types.PlannedProp }
	local out: { Types.PlannedProp } = {}
	for _, prop in plan.props do
		if prop.kind == kind and (levelId == nil or prop.levelId == levelId) then
			table.insert(out, prop)
		end
	end
	return out
end

return table.freeze(RunDirector)
