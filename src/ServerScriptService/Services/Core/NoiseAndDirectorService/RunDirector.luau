--!strict
-- RunDirector: everything a run randomizes, as one pure function of (seed, difficulty, layouts, graph).
--
--   BearTrap       DifficultyConfig.trapCount Level0 TrapCandidate anchors. No two traps closer than
--                  MinTrapSpacing studs, and never inside an airlock, a stairwell, the level's entry / exit room or a
--                  room holding PlayerSpawn anchors.
--   ChemicalFlask  flasksScienceHall Level2 FlaskCandidate anchors and flasksPool Level4 FlaskCandidate anchors.
--   Battery        batteriesPerLevel BatteryCandidate anchors on every school level.
--   lockedGrates   round(lockedGrateFraction x lockable) of each level's Lockable grates (never CriticalPath ones).
--                  A roll stands only while ZoneGraph still proves the level solvable with those grates locked and
--                  every Gate door shut. A failing roll is re-rolled deterministically, up to MaxRerolls times per
--                  level; a level that never passes keeps every grate unlocked. `rerolls` counts every re-roll.
--
-- Pure: no instances, no clocks, no global random. Every decision draws from its own
-- MathUtil.seededRandom(seed, <decision key>) stream and walks layouts, anchors and grates in list order, so the
-- same inputs always produce an identical plan, and changing one decision (say the trap count) never shifts another
-- (the grate locks). Plans are frozen.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Types = require(ReplicatedStorage.Shared.Types)
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
local VARIANT_RANGE = 1000000

local RunDirector = {}

RunDirector.PropKinds = table.freeze({
	BearTrap = "BearTrap",
	ChemicalFlask = "ChemicalFlask",
	Battery = "Battery",
})
RunDirector.MinTrapSpacing = MIN_TRAP_SPACING
RunDirector.MaxRerolls = MAX_REROLLS
RunDirector.TrapLevel = TRAP_LEVEL
RunDirector.ScienceLevel = SCIENCE_LEVEL
RunDirector.PoolLevel = POOL_LEVEL

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
-- already taken. Returns the taken anchors and the ones passed over (in the order they were met).
local function spacedPass(
	candidates: { Anchor },
	count: number,
	random: Random,
	spacing: number
): ({ Anchor }, { Anchor })
	local order = MathUtil.shuffle(table.clone(candidates), random)
	local chosen: { Anchor } = {}
	local passed: { Anchor } = {}
	for _, anchor in order do
		if #chosen >= count then
			break
		end
		if spacedFrom(anchor, chosen, spacing) then
			table.insert(chosen, anchor)
		else
			table.insert(passed, anchor)
		end
	end
	return chosen, passed
end

-- Seeded choice of up to `count` anchors that are all at least `spacing` apart. A short pass is retried with
-- fresh shuffles (from the same stream), keeping the fullest result.
local function chooseSpaced(candidates: { Anchor }, count: number, random: Random, spacing: number): { Anchor }
	local best: { Anchor } = {}
	if count <= 0 or #candidates == 0 then
		return best
	end
	for _ = 1, TRAP_ATTEMPTS do
		local chosen = spacedPass(candidates, count, random, spacing)
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

local function plannedProp(seed: number, kind: string, layout: Layout, anchor: Anchor): Types.PlannedProp
	local variantRandom = MathUtil.seededRandom(seed, "Variant|" .. kind .. "|" .. layout.id .. "|" .. anchor.id)
	local prop: Types.PlannedProp = {
		kind = kind,
		anchorId = anchor.id,
		levelId = layout.id,
		cframe = Builder.anchorCFrame(layout.id, anchor),
		variant = variantRandom:NextInteger(1, VARIANT_RANGE),
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

	-- Bear traps
	local basement = byId[TRAP_LEVEL]
	if basement then
		local candidates = anchorsOfKind(basement, "TrapCandidate", RunDirector.trapExcludedRooms(basement))
		local random = MathUtil.seededRandom(runSeed, "Traps|" .. basement.id)
		local chosen = chooseSpaced(candidates, spec.trapCount, random, MIN_TRAP_SPACING)
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

	table.freeze(props)
	table.freeze(lockedGrates)
	local plan: Types.SpawnPlan = {
		seed = runSeed,
		difficulty = resolved,
		props = props,
		lockedGrates = lockedGrates,
		rerolls = rerolls,
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
