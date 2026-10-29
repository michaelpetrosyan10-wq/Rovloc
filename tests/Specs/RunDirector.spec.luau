--!strict
-- RunDirector: the seeded per-run spawn plan. Same (seed, difficulty, layouts) gives an identical plan; prop counts
-- follow DifficultyConfig; traps keep their spacing and stay out of airlock / spawn rooms; locked grates are only
-- ever Lockable ones and every level stays solvable (ZoneGraph) under the plan, over 500 seeds per difficulty; an
-- unsolvable roll is re-rolled and, failing that, unlocked.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local ZoneGraph = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph)
local RunDirector = require(ServerScriptService.Services.Core.NoiseAndDirectorService.RunDirector)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor
type Plan = Types.SpawnPlan

local R = LayoutSchema.rect

local STANDARD: Enums.Difficulty = "Standard"
local NIGHTMARE: Enums.Difficulty = "Nightmare"
local DIFFICULTIES: { Enums.Difficulty } = { STANDARD, NIGHTMARE }

local SOLVABILITY_SEEDS = 500
local SPACING_SEEDS = 200

local ANCHOR_KIND_FOR_PROP: { [string]: Enums.AnchorKind } = {
	BearTrap = "TrapCandidate",
	ChemicalFlask = "FlaskCandidate",
	Battery = "BatteryCandidate",
	Fuse = "FuseCandidate",
	MasterKeys = "MasterKeyCandidate",
	ReagentJar = "ReagentCandidate",
	CoachKey = "CoachKeyCandidate",
	ValveWheel = "ValveWheelCandidate",
	BoltCutters = "BoltCutterCandidate",
}

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

local cachedLayouts: { Layout }? = nil
local cachedGraph: Types.ZoneGraphData? = nil

local function layouts(): { Layout }
	local list = cachedLayouts
	if list then
		return list
	end
	local loaded = Builder.layouts()
	cachedLayouts = loaded
	return loaded
end

local function graph(): Types.ZoneGraphData
	local built = cachedGraph
	if built then
		return built
	end
	local fresh = ZoneGraph.build(layouts())
	cachedGraph = fresh
	return fresh
end

local function layoutById(id: string): Layout?
	for _, layout in layouts() do
		if layout.id == id then
			return layout
		end
	end
	return nil
end

local function specFor(difficulty: Enums.Difficulty): DifficultyConfig.DifficultySpec
	return if difficulty == "Nightmare" then DifficultyConfig.Nightmare else DifficultyConfig.Standard
end

local function planFor(seed: number, difficulty: Enums.Difficulty): Plan
	return RunDirector.plan(seed, difficulty, layouts(), graph())
end

local function anchorById(layout: Layout, id: string): Anchor?
	for _, anchor in layout.anchors do
		if anchor.id == id then
			return anchor
		end
	end
	return nil
end

local function countAnchors(layout: Layout, kind: Enums.AnchorKind, excluded: { [string]: boolean }?): number
	local count = 0
	for _, anchor in layout.anchors do
		if anchor.kind == kind and not (excluded and excluded[anchor.room]) then
			count += 1
		end
	end
	return count
end

local function samePlan(a: Plan, b: Plan): (boolean, string)
	if a.seed ~= b.seed or a.difficulty ~= b.difficulty or a.rerolls ~= b.rerolls then
		return false, "seed / difficulty / rerolls differ"
	end
	if #a.props ~= #b.props then
		return false, string.format("prop counts differ (%d vs %d)", #a.props, #b.props)
	end
	for i, pa in a.props do
		local pb = b.props[i]
		if
			pa.kind ~= pb.kind
			or pa.anchorId ~= pb.anchorId
			or pa.levelId ~= pb.levelId
			or pa.variant ~= pb.variant
			or pa.cframe ~= pb.cframe
		then
			return false,
				string.format("prop %d differs (%s %s vs %s %s)", i, pa.kind, pa.anchorId, pb.kind, pb.anchorId)
		end
	end
	for id in a.lockedGrates do
		if not b.lockedGrates[id] then
			return false, "grate " .. id .. " locked only in the first plan"
		end
	end
	for id in b.lockedGrates do
		if not a.lockedGrates[id] then
			return false, "grate " .. id .. " locked only in the second plan"
		end
	end
	return true, ""
end

-- Two corridors split by a Gate; the only way past it is a chase with a lockable grate into each corridor, plus
-- (optionally lockable) a grate into a dead-end store room. With every roll locking one grate, only rolls that
-- lock the store room's grate keep the level solvable.
local function syntheticLayout(storeLockable: boolean): Layout
	local rooms: { LayoutSchema.Room } = {
		{ id = "West", kind = "Corridor", rect = R(0, 0, 20, 60) },
		{ id = "East", kind = "Corridor", rect = R(20, 0, 25, 20) },
		{ id = "Chase", kind = "Chase", rect = R(20, 20, 5, 40) },
		{ id = "Store", kind = "Storage", rect = R(25, 20, 20, 40) },
	}
	local doors: { LayoutSchema.Door } = {
		{ id = "SynthGate", kind = "Gate", rooms = { "West", "East" }, at = 10 },
	}
	local nodes: { LayoutSchema.VentNodeSpec } = {
		{ id = "nWest", x = 20, z = 40 },
		{ id = "nJunction", x = 22.5, z = 40 },
		{ id = "nEast", x = 22.5, z = 20 },
		{ id = "nBend", x = 22.5, z = 50 },
		{ id = "nStore", x = 25, z = 50 },
	}
	local edges: { LayoutSchema.VentEdgeSpec } = {
		{ a = "nWest", b = "nJunction" },
		{ a = "nJunction", b = "nEast" },
		{ a = "nJunction", b = "nBend" },
		{ a = "nBend", b = "nStore" },
	}
	local grates: { LayoutSchema.GrateSpec } = {
		{ id = "SynthGrate_West", node = "nWest", room = "West", lockable = true, criticalPath = false },
		{ id = "SynthGrate_East", node = "nEast", room = "East", lockable = true, criticalPath = false },
		{ id = "SynthGrate_Store", node = "nStore", room = "Store", lockable = storeLockable, criticalPath = false },
	}
	local layout: Layout = {
		id = "Level1_Hallways",
		height = 14,
		acoustic = "Corridor",
		ambience = "DroneHallways",
		entry = "West",
		exit = "East",
		rooms = rooms,
		doors = doors,
		vents = { nodes = nodes, edges = edges, grates = grates },
		anchors = {},
		triggers = {},
	}
	return layout
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["the same seed, difficulty and layouts give an identical plan"] = function(t: Expect)
		local seeds = { 0, 1, 7, 42, 1337, 987654321, 2 ^ 31 + 11, 4294967295 }
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			for _, seed in seeds do
				local first = planFor(seed, difficulty)
				local second = planFor(seed, difficulty)
				local same, reason = samePlan(first, second)
				t.truthy(same, string.format("seed %s %s: %s", tostring(seed), difficulty, reason))
				t.truthy(first ~= second, "every call builds a fresh plan")
				t.truthy(table.isfrozen(first) and table.isfrozen(first.props), "plans are frozen")
			end
		end
	end,

	["different seeds shuffle the plan"] = function(t: Expect)
		local base = planFor(1, STANDARD)
		local differing = 0
		for seed = 2, 12 do
			local same = samePlan(base, planFor(seed, STANDARD))
			if not same then
				differing += 1
			end
		end
		t.truthy(differing >= 10, string.format("only %d of 11 other seeds changed the plan", differing))
	end,

	["prop counts follow DifficultyConfig"] = function(t: Expect)
		local basement = layoutById(RunDirector.TrapLevel)
		local science = layoutById(RunDirector.ScienceLevel)
		local pool = layoutById(RunDirector.PoolLevel)
		t.truthy(basement and science and pool, "the basement, science hall and pool layouts load")
		assert(basement and science and pool, "unreachable")
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			local spec = specFor(difficulty)
			t.truthy(
				countAnchors(basement, "TrapCandidate", RunDirector.trapExcludedRooms(basement)) >= spec.trapCount,
				"the basement has enough eligible trap candidates for " .. difficulty
			)
			for seed = 1, 25 do
				local plan = planFor(seed, difficulty)
				t.eq(plan.difficulty, difficulty, "plan difficulty")
				t.eq(#RunDirector.propsOf(plan, "BearTrap"), spec.trapCount, difficulty .. " bear traps")
				t.eq(
					#RunDirector.propsOf(plan, "ChemicalFlask", science.id),
					math.min(spec.flasksScienceHall, countAnchors(science, "FlaskCandidate", nil)),
					difficulty .. " science hall flasks"
				)
				t.eq(
					#RunDirector.propsOf(plan, "ChemicalFlask", pool.id),
					math.min(spec.flasksPool, countAnchors(pool, "FlaskCandidate", nil)),
					difficulty .. " pool flasks"
				)
				t.eq(
					#RunDirector.propsOf(plan, "ChemicalFlask"),
					spec.flasksScienceHall + spec.flasksPool,
					"flasks only on L2 + L4"
				)
				for _, layout in layouts() do
					local expected = if layout.id == "Lobby"
						then 0
						else math.min(spec.batteriesPerLevel, countAnchors(layout, "BatteryCandidate", nil))
					t.eq(
						#RunDirector.propsOf(plan, "Battery", layout.id),
						expected,
						difficulty .. " batteries on " .. layout.id
					)
				end
			end
		end
		t.truthy(DifficultyConfig.Nightmare.trapCount > DifficultyConfig.Standard.trapCount, "Nightmare has more traps")
		t.truthy(
			DifficultyConfig.Nightmare.batteriesPerLevel < DifficultyConfig.Standard.batteriesPerLevel,
			"Nightmare has fewer batteries"
		)
	end,

	["traps keep their spacing and stay out of airlock and spawn rooms"] = function(t: Expect)
		local basement = layoutById(RunDirector.TrapLevel)
		assert(basement, "the basement layout loads")
		local rooms = LayoutSchema.indexRooms(basement)
		local spawnRooms: { [string]: boolean } = {}
		for _, anchor in basement.anchors do
			if anchor.kind == "PlayerSpawn" then
				spawnRooms[anchor.room] = true
			end
		end
		t.truthy(next(spawnRooms) ~= nil, "the basement has a spawn room")
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			for seed = 1, SPACING_SEEDS do
				local traps = RunDirector.propsOf(planFor(seed, difficulty), "BearTrap")
				local positions: { Vector3 } = {}
				for _, prop in traps do
					local anchor = anchorById(basement, prop.anchorId)
					assert(anchor, "trap anchor " .. prop.anchorId .. " exists")
					local room = rooms[anchor.room]
					assert(room, "trap room " .. anchor.room .. " exists")
					t.truthy(room.kind ~= "Airlock" and room.kind ~= "Stairwell", "trap in airlock room " .. room.id)
					t.falsy(spawnRooms[room.id], "trap in spawn room " .. room.id)
					t.truthy(
						room.id ~= basement.entry and room.id ~= basement.exit,
						"trap in entry/exit room " .. room.id
					)
					table.insert(positions, prop.cframe.Position)
				end
				for i = 1, #positions do
					for j = i + 1, #positions do
						local distance = MathUtil.horizontalDistance(positions[i], positions[j])
						if distance < RunDirector.MinTrapSpacing then
							t.fail(
								string.format(
									"seed %d %s: traps %s and %s are %.2f studs apart",
									seed,
									difficulty,
									traps[i].anchorId,
									traps[j].anchorId,
									distance
								)
							)
						end
					end
				end
			end
		end
		t.eq(RunDirector.MinTrapSpacing, 6, "trap spacing")
	end,

	["props sit on distinct anchors of the right kind"] = function(t: Expect)
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			for seed = 1, 20 do
				local plan = planFor(seed * 7919, difficulty)
				local used: { [string]: boolean } = {}
				for _, prop in plan.props do
					local layout = layoutById(prop.levelId)
					assert(layout, "prop level " .. prop.levelId .. " exists")
					local anchor = anchorById(layout, prop.anchorId)
					assert(anchor, "prop anchor " .. prop.anchorId .. " exists")
					t.eq(anchor.kind, ANCHOR_KIND_FOR_PROP[prop.kind], "anchor kind for " .. prop.kind)
					t.truthy(prop.cframe == Builder.anchorCFrame(layout.id, anchor), "prop CFrame = anchor CFrame")
					t.truthy(prop.variant >= 1 and prop.variant == math.floor(prop.variant), "integer variant")
					local key = prop.levelId .. "/" .. prop.anchorId
					t.falsy(used[key], "anchor used twice: " .. key)
					used[key] = true
				end
			end
		end
	end,

	["locked grates are Lockable and every level stays solvable"] = function(t: Expect)
		local lockableById: { [string]: boolean } = {}
		local grateIds: { [string]: string } = {}
		for _, layout in layouts() do
			local vents = layout.vents
			if not vents then
				continue
			end
			for _, grate in vents.grates do
				t.falsy(grateIds[grate.id], "grate id " .. grate.id .. " is unique across layouts")
				grateIds[grate.id] = layout.id
				if grate.lockable and not grate.criticalPath then
					lockableById[grate.id] = true
				end
			end
		end
		local schoolLevels: { Layout } = {}
		for _, layout in layouts() do
			if layout.id ~= "Lobby" then
				table.insert(schoolLevels, layout)
			end
		end
		local everLocked = 0
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			local fraction = specFor(difficulty).lockedGrateFraction
			for seed = 1, SOLVABILITY_SEEDS do
				local plan = planFor(seed, difficulty)
				t.truthy(
					plan.rerolls >= 0 and plan.rerolls <= RunDirector.MaxRerolls * #schoolLevels,
					"rerolls bounded"
				)
				local lockedPerLevel: { [string]: number } = {}
				for id in plan.lockedGrates do
					if not lockableById[id] then
						t.fail(string.format("seed %d %s locked non-lockable grate %s", seed, difficulty, id))
					end
					local levelId = grateIds[id] or "?"
					lockedPerLevel[levelId] = (lockedPerLevel[levelId] or 0) + 1
					everLocked += 1
				end
				for _, layout in schoolLevels do
					if not ZoneGraph.isLevelSolvable(graph(), layout, RunDirector.blockedFor(plan, layout)) then
						t.fail(string.format("seed %d %s: %s unsolvable under the plan", seed, difficulty, layout.id))
					end
					local expected = RunDirector.lockCount(fraction, #RunDirector.lockableGrates(layout))
					t.eq(
						lockedPerLevel[layout.id] or 0,
						expected,
						string.format("%s locked grates on %s", difficulty, layout.id)
					)
				end
			end
		end
		t.truthy(everLocked > 0, "the director locks grates at all")
	end,

	["an unsolvable roll is re-rolled, and a hopeless level stays unlocked"] = function(t: Expect)
		-- Only the store-room grate is safe to lock: rolls that lock a corridor grate are re-rolled.
		local recoverable = syntheticLayout(true)
		local recoverableGraph = ZoneGraph.build({ recoverable })
		local blockedGate = RunDirector.gateBlocked(recoverable)
		t.truthy(ZoneGraph.isLevelSolvable(recoverableGraph, recoverable, blockedGate), "solvable through the chase")
		local totalRerolls = 0
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			for seed = 1, 24 do
				local plan = RunDirector.plan(seed, difficulty, { recoverable }, recoverableGraph)
				t.truthy(plan.lockedGrates.SynthGrate_Store, "the store grate is the one locked")
				t.falsy(
					plan.lockedGrates.SynthGrate_West or plan.lockedGrates.SynthGrate_East,
					"corridor grates stay open"
				)
				t.truthy(plan.rerolls <= RunDirector.MaxRerolls, "rerolls bounded")
				t.truthy(
					ZoneGraph.isLevelSolvable(recoverableGraph, recoverable, RunDirector.blockedFor(plan, recoverable)),
					"still solvable"
				)
				totalRerolls += plan.rerolls
			end
		end
		t.truthy(totalRerolls > 0, "some seeds needed a re-roll")

		-- Every roll locks a corridor grate: after MaxRerolls the level keeps every grate unlocked.
		local hopeless = syntheticLayout(false)
		local hopelessGraph = ZoneGraph.build({ hopeless })
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			local plan = RunDirector.plan(99, difficulty, { hopeless }, hopelessGraph)
			t.eq(plan.rerolls, RunDirector.MaxRerolls, difficulty .. " re-rolls")
			t.eq(next(plan.lockedGrates), nil, difficulty .. " leaves every grate unlocked")
			t.truthy(
				ZoneGraph.isLevelSolvable(hopelessGraph, hopeless, RunDirector.blockedFor(plan, hopeless)),
				"solvable"
			)
		end
	end,

	["lockCount rounds the fraction of lockable grates"] = function(t: Expect)
		t.eq(RunDirector.lockCount(0.25, 19), 5)
		t.eq(RunDirector.lockCount(0.45, 19), 9)
		t.eq(RunDirector.lockCount(0.25, 2), 1)
		t.eq(RunDirector.lockCount(0.45, 3), 1)
		t.eq(RunDirector.lockCount(0.25, 0), 0)
		t.eq(RunDirector.lockCount(2, 4), 4)
		t.eq(RunDirector.lockCount(0 / 0, 4), 0)
	end,

	["route: one fair stairwell per floor pair, seeded, varied, chained through the vestibules"] = function(t: Expect)
		local byId: { [string]: Layout } = {}
		for _, layout in layouts() do
			byId[layout.id] = layout
		end
		local used: { [string]: number } = {}
		for seed = 1, 40 do
			local route = RunDirector.pickRoute(seed, layouts())
			local again = RunDirector.pickRoute(seed, layouts())
			local plan = planFor(seed, STANDARD)
			local entry: string? = nil
			for _, from in WorldConfig.LevelOrder do
				local id = route[from]
				t.eq(again[from], id, "deterministic per seed")
				t.eq(plan.route and plan.route[from], id, "the plan carries the route")
				local candidates = WorldConfig.stairwellCandidates(from)
				if #candidates == 0 then
					t.eq(id, nil, from .. " (the roof) has no exit stairwell")
					continue
				end
				local spec = WorldConfig.stairwellById(id)
				t.truthy(
					spec and spec.from == from,
					string.format("seed %d: %s leaves by %s", seed, from, tostring(id))
				)
				if not spec then
					continue
				end
				used[spec.id] = (used[spec.id] or 0) + 1
				local layout = byId[from]
				for _, check in RunDirector.routeChecks(layout, entry or layout.entry, byId) do
					if check.stairwellId == spec.id then
						t.truthy(
							check.fair,
							string.format("seed %d: %s is fair from %s", seed, spec.id, tostring(entry))
						)
						t.truthy(check.share >= RunDirector.RouteFairShare - 1e-9, spec.id .. " is far enough")
						t.truthy(
							check.creatureSpawns == nil or check.creatureSpawns >= RunDirector.MinCreatureSpawns,
							spec.id .. " leaves the next floor Creature starts"
						)
					end
				end
				entry = spec.toRoom
			end
		end
		for _, spec in WorldConfig.Stairwells do
			t.truthy((used[spec.id] or 0) > 0, spec.id .. " is picked by some seed")
		end
		-- every floor pair has a north, middle and south candidate, each reachable from every way in
		for _, from in WorldConfig.LevelOrder do
			local layout = byId[from]
			local candidates = WorldConfig.stairwellCandidates(from)
			if #candidates == 0 then
				continue
			end
			t.eq(#candidates, 3, from .. " has three exit candidates")
			local entries = { layout.entry }
			for _, spec in WorldConfig.Stairwells do
				if spec.to == from and spec.toRoom ~= layout.entry then
					table.insert(entries, spec.toRoom)
				end
			end
			for _, entryRoom in entries do
				for _, check in RunDirector.routeChecks(layout, entryRoom, byId) do
					t.truthy(check.distance < math.huge, check.stairwellId .. " reachable from " .. entryRoom)
				end
			end
		end
		-- no route in a hand-made plan: the middle stairwells
		local exit, entry =
			WorldConfig.routeExit(nil, "Level1_Hallways"), WorldConfig.routeEntry(nil, "Level1_Hallways")
		t.eq(exit and exit.id, "Stairwell_1_2")
		t.eq(entry and entry.id, "Stairwell_0_1")
		t.eq(WorldConfig.routeEntry(nil, "Level0_Basement"), nil)
	end,

	["an unknown difficulty plans Standard"] = function(t: Expect)
		local plan = RunDirector.plan(5, ("Easy" :: any) :: Enums.Difficulty, layouts(), graph())
		t.eq(plan.difficulty, "Standard")
		local same = samePlan(plan, planFor(5, STANDARD))
		t.truthy(same, "identical to the Standard plan")
	end,
}
