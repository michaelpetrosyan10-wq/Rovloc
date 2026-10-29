--!strict
-- RunDirector: everything a run randomizes, as one pure function of (seed, difficulty, layouts, graph).
--
--   Objectives     each floor's objective item (ObjectiveConfig): item.count of the layout's fair item.candidate
--                  anchors (objectiveCandidates: at least EntryClearance studs walked from the floor's entry, never in
--                  the room of a CreatureScarePose), with item.slots one candidate of each kind (the candidates cycle
--                  through the kinds in layout order), as props of kind item.prop, each with its slot (pick order,
--                  1..count; with kinds, the kind: a reagent's colour), listed in plan.objectives[levelId]
--                  (RunDirector.objectiveOf). Several items lie in different rooms, at least PickSpacing studs apart,
--                  and (three or more) in at least PickQuarters quarters of the floor: a seeded pass takes the first
--                  shuffled candidate that keeps those rules, and a pass that falls short or bunches up is
--                  re-shuffled, up to PICK_ATTEMPTS times. One stream per level ("Objective|<level>"), independent
--                  of the difficulty: a run's objective spots are a pure function of the seed.
--   BearTrap       DifficultyConfig.trapCount Level0 TrapCandidate anchors. First the guard traps: the ref (a
--                  TrapCandidate on the approach) of each of the first item.guarded fuses picked, so at least that
--                  many fuses are guarded; then the rest. No two traps closer than MinTrapSpacing studs, and never
--                  inside an airlock, a stairwell, the level's entry / exit room or a room holding PlayerSpawn anchors.
--   ChemicalFlask  flasksScienceHall Level2 FlaskCandidate anchors and flasksPool Level4 FlaskCandidate anchors.
--   Battery        batteriesPerLevel BatteryCandidate anchors on every school level.
--   lockedGrates   round(lockedGrateFraction x lockable) of each level's Lockable grates (never CriticalPath ones).
--                  A roll stands only while ZoneGraph still proves the level solvable with those grates locked and
--                  every Gate door shut. A failing roll is re-rolled deterministically, up to MaxRerolls times per
--                  level; a level that never passes keeps every grate unlocked. `rerolls` counts every re-roll.
--
--   Route          plan.route: the stairwell every floor is left by (pickRoute), one of its pair's three candidates
--                  (WorldConfig.stairwellCandidates: North, Middle, South), uniform by the seed (stream
--                  "Route|<from>"), drawn again while it is unfair for the entry the previous pick leads to: its exit
--                  vestibule under RouteFairShare of the longest candidate's walk from the entry, or (Levels 2 and 3)
--                  fewer than MinCreatureSpawns Creature starts CreatureBand studs from its entry vestibule, out of
--                  sight and outside every objective room. The unused candidates are jammed shut for the run.
--
-- Pure: no instances, no clocks, no global random. Every decision draws from its own
-- MathUtil.seededRandom(seed, <decision key>) stream and walks layouts, anchors and grates in list order, so the
-- same inputs always produce an identical plan, and changing one decision (say the trap count) never shifts another
-- (the grate locks). Plans are frozen.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local ObjectivePlaces = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ObjectivePlaces)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local ZoneGraph = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph)

local log = Log.new("RunDirector")

type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor
type GrateSpec = LayoutSchema.GrateSpec

local TRAP_LEVEL: Enums.LevelId = "Level0_Basement"
local SCIENCE_LEVEL: Enums.LevelId = "Level2_ScienceHall"
local POOL_LEVEL: Enums.LevelId = "Level4_FloodedPool"

local MIN_TRAP_SPACING = 6 -- studs, horizontal
local FLASK_SPACING = 3 -- preferred, not required: flasks may share a long lab counter
local BATTERY_SPACING = 10 -- preferred, not required: spreads batteries over a level
local TRAP_ATTEMPTS = 16 -- fresh shuffles tried when the spacing rule leaves a trap short
local MAX_REROLLS = 64
local PICK_ATTEMPTS = 24 -- fresh shuffles tried when a multi-item pick falls short of the room / spacing / spread rules
local VARIANT_RANGE = 1000000
local ROUTE_ATTEMPTS = 8 -- draws from a floor's Route stream before falling back to its first fair candidate
local ROUTE_FAIR_SHARE = 0.6 -- an exit is at least this share of the longest exit candidate's walk from the entry
local CREATURE_BAND = { 70, 140 } -- studs walked from the entry to a Creature start (the web's SpawnTuning)
local MIN_CREATURE_SPAWNS = 2
local CREATURE_SPAWN_LEVELS: { [string]: boolean } = { Level2_ScienceHall = true, Level3_Gymnasium = true }

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
RunDirector.ScienceLevel = SCIENCE_LEVEL
RunDirector.PoolLevel = POOL_LEVEL
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

-- Every Gate door of `layout` shut: the worst case the level's scripted gates can produce.
function RunDirector.gateBlocked(layout: Layout): Types.BlockedSet
	local blocked: Types.BlockedSet = {}
	for _, door in layout.doors do
		if door.kind == "Gate" then
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
	random: Random,
	spacing: number,
	fixed: { Anchor }?
): ({ Anchor }, { Anchor })
	local order = MathUtil.shuffle(table.clone(candidates), random)
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
	random: Random,
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
local function choosePreferSpaced(candidates: { Anchor }, count: number, random: Random, spacing: number): { Anchor }
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

local function plannedProp(seed: number, kind: string, layout: Layout, anchor: Anchor, slot: number?): Types.PlannedProp
	local variantRandom = MathUtil.seededRandom(seed, "Variant|" .. kind .. "|" .. layout.id .. "|" .. anchor.id)
	local prop: Types.PlannedProp = {
		kind = kind,
		anchorId = anchor.id,
		levelId = layout.id,
		cframe = Builder.anchorCFrame(layout.id, anchor),
		variant = variantRandom:NextInteger(1, VARIANT_RANGE),
		slot = slot,
	}
	table.freeze(prop)
	return prop
end

local function addProps(props: { Types.PlannedProp }, seed: number, kind: string, layout: Layout, chosen: { Anchor })
	for _, anchor in inLayoutOrder(layout, chosen) do
		table.insert(props, plannedProp(seed, kind, layout, anchor))
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

-- The slot of the `index`-th candidate (layout order) of a floor whose candidates cycle through kinds (reagents), else
-- the index itself.
function RunDirector.candidateSlot(spec: ObjectiveConfig.FloorSpec, index: number): number
	local slots = spec.item.slots
	return if slots then (index - 1) % slots + 1 else index
end

-- The item candidates of `layout` a run may use for `spec` (layout order): at least ObjectiveConfig.EntryClearance
-- studs walked from the floor's entry, and never in a room holding a CreatureScarePose (the Floor 1 scare classroom).
-- Cached per layout (the walk is the same every run).
local candidateCache: { [Layout]: { [string]: { Anchor } } } = setmetatable({}, { __mode = "k" }) :: any
function RunDirector.objectiveCandidates(layout: Layout, spec: ObjectiveConfig.FloorSpec): { Anchor }
	local byKind = candidateCache[layout]
	if not byKind then
		byKind = {}
		candidateCache[layout] = byKind
	end
	local cached = byKind[spec.item.candidate]
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
	for _, anchor in anchorsOfKind(layout, spec.item.candidate, scareRooms) do
		local place = { id = anchor.id, kind = anchor.kind, room = anchor.room, pos = anchor.pos }
		if ObjectivePlaces.entryDistance(layout, place) >= ObjectiveConfig.EntryClearance then
			table.insert(out, anchor)
		end
	end
	table.freeze(out)
	byKind[spec.item.candidate] = out
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
	local candidates = RunDirector.objectiveCandidates(layout, spec)
	local random = MathUtil.seededRandom(seed, "Objective|" .. layout.id)
	local slots = spec.item.slots
	local count = if slots then math.min(slots, spec.item.count) else math.min(spec.item.count, #candidates)
	local groups: { { Anchor } } = {}
	if slots then
		-- one of each kind: the fair candidates of slot k (the slot cycles over every candidate in layout order)
		local fair: { [Anchor]: boolean } = {}
		for _, anchor in candidates do
			fair[anchor] = true
		end
		for k = 1, count do
			groups[k] = {}
		end
		for i, anchor in anchorsOfKind(layout, spec.item.candidate, nil) do
			local group = groups[RunDirector.candidateSlot(spec, i)]
			if group and fair[anchor] then
				table.insert(group, anchor)
			end
		end
	end
	local picks: { Anchor } = {}
	for _ = 1, if count > 1 then PICK_ATTEMPTS else 1 do
		local pass: { Anchor } = {}
		if slots then
			-- kind by kind, the first shuffled candidate that keeps apart from the kinds already taken
			for k = 1, count do
				for _, anchor in MathUtil.shuffle(table.clone(groups[k]), random) do
					if keepsApart(anchor, pass) then
						table.insert(pass, anchor)
						break
					end
				end
			end
		else
			for _, anchor in MathUtil.shuffle(table.clone(candidates), random) do
				if #pass >= count then
					break
				end
				if keepsApart(anchor, pass) then
					table.insert(pass, anchor)
				end
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
	local wanted = spec.item.guarded or 0
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

local STATION_KINDS: { [string]: boolean } =
	{ BreakerPanel = true, FumeHood = true, Generator = true, HatchValve = true, CrateChain = true }

-- Rooms of `layout` a Creature never starts in: those holding an objective station or any item candidate (whatever a
-- run picks), so the rule holds for every seed.
local function objectiveRooms(layout: Layout): { [string]: boolean }
	local spec = ObjectiveConfig.forLevel(layout.id)
	local rooms: { [string]: boolean } = {}
	for _, anchor in layout.anchors do
		if STATION_KINDS[anchor.kind] or (spec and anchor.kind == spec.item.candidate) then
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
		local random = MathUtil.seededRandom(seed, "Route|" .. from)
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
	local random = MathUtil.seededRandom(seed, "Grates|" .. layout.id)
	local rerolls = 0
	for attempt = 0, MAX_REROLLS do
		local order = MathUtil.shuffle(table.clone(lockable), random)
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
		if not layout then
			continue
		end
		local picks, guards = RunDirector.pickObjective(runSeed, layout, floor)
		warnShort(floor.item.prop, layout, #picks, floor.item.count)
		guardsByLevel[layout.id] = guards
		local anchorIds: { string } = {}
		for slot, anchor in picks do
			table.insert(anchorIds, anchor.id)
			table.insert(objectiveProps, plannedProp(runSeed, floor.item.prop, layout, anchor, slot))
		end
		-- (with slots the picks come one per kind in kind order, so a pick's place in the list is its kind)
		local guardIds: { string } = {}
		for _, guard in guards do
			table.insert(guardIds, guard.id)
		end
		objectives[layout.id] = table.freeze({
			levelId = layout.id,
			prop = floor.item.prop,
			anchors = table.freeze(anchorIds),
			guards = table.freeze(guardIds),
		})
	end

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
		local random = MathUtil.seededRandom(runSeed, "Traps|" .. basement.id)
		local fill = math.max(0, spec.trapCount - #guards)
		local chosen = chooseSpaced(candidates, fill, random, MIN_TRAP_SPACING, guards)
		for _, guard in guards do
			table.insert(chosen, guard)
		end
		warnShort("bear traps", basement, #chosen, spec.trapCount)
		addProps(props, runSeed, RunDirector.PropKinds.BearTrap, basement, chosen)
	end

	-- Chemical flasks
	local flaskLevels: { { level: Enums.LevelId, count: number } } = {
		{ level = SCIENCE_LEVEL, count = spec.flasksScienceHall },
		{ level = POOL_LEVEL, count = spec.flasksPool },
	}
	for _, entry in flaskLevels do
		local layout = byId[entry.level]
		if not layout then
			continue
		end
		local candidates = anchorsOfKind(layout, "FlaskCandidate", nil)
		local random = MathUtil.seededRandom(runSeed, "Flasks|" .. layout.id)
		local chosen = choosePreferSpaced(candidates, entry.count, random, FLASK_SPACING)
		warnShort("chemical flasks", layout, #chosen, entry.count)
		addProps(props, runSeed, RunDirector.PropKinds.ChemicalFlask, layout, chosen)
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
		local random = MathUtil.seededRandom(runSeed, "Batteries|" .. layout.id)
		local chosen = choosePreferSpaced(candidates, spec.batteriesPerLevel, random, BATTERY_SPACING)
		warnShort("batteries", layout, #chosen, spec.batteriesPerLevel)
		addProps(props, runSeed, RunDirector.PropKinds.Battery, layout, chosen)
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
		route = RunDirector.pickRoute(runSeed, layouts),
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
