--!strict
-- RunDirector's spec v2 picks (docs/design/game-spec-v2.md 3.2, 4.2, 4.7): the radar batteries of a sneaking stage (the
-- stream "Batteries|<stage>"; 6 [4] + 1 per extra player up to 9 [7]; one 20-60 walked from the entry, one within 40
-- walked of the main station, every pair 30 walked apart, none in a dead end), the stun flasks per stage (3, 3, 2, 2,
-- 2 [2, 2, 1, 1, 1]) and the rooftops' feeders (3 of 6, both arcs), each on its own stream so today's plans keep their
-- picks. Every rule on fixtures for 16 seeds and both difficulties; the deterministic degrade when a floor cannot keep
-- one; the real floors held to every rule once they offer the 36 candidates (the ones still short are printed).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local RadarRules = require(ReplicatedStorage.Shared.Rules.RadarRules)
local RunDirector = require(ReplicatedStorage.Shared.World.RunDirector)
local StageConfig = require(ReplicatedStorage.Shared.Config.StageConfig)
local ZoneGraph = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor

local SEEDS: { number } =
	{ 1, 2, 3, 7, 42, 99, 1029, 4242, 5150, 65537, 20251029, 123456789, 2147483646, 31, 8080, 777 }
local DIFFICULTIES: { Enums.Difficulty } = { "Standard", "Nightmare" }

-- A 5 x 4 grid of 80 x 72 rooms joined by doorways, two battery candidates a room, the entry in the north-west room,
-- the airport's wing filler (its main station) in the middle; the two east corner rooms are dead ends (one doorway
-- each); eight flask candidates.
local function gridFixture(id: string): Layout
	local rooms: { LayoutSchema.Room } = {}
	local doors: { LayoutSchema.Door } = {}
	local anchors: { Anchor } = {}
	local function name(r: number, c: number): string
		return string.format("G_%d_%d", r, c)
	end
	for r = 1, 4 do
		for c = 1, 5 do
			local x, z = (c - 1) * 80, (r - 1) * 72
			table.insert(rooms, { id = name(r, c), kind = "Storage", rect = LayoutSchema.rect(x, z, 80, 72) })
			for k, dx in { 20, 60 } do
				table.insert(anchors, {
					id = string.format("B_%d_%d_%d", r, c, k),
					kind = "BatteryCandidate",
					room = name(r, c),
					pos = Vector3.new(x + dx, 0, z + 36),
				})
			end
			if c < 5 then
				table.insert(doors, {
					id = string.format("D_%d_%d_E", r, c),
					kind = "Doorway",
					rooms = { name(r, c), name(r, c + 1) },
					at = z + 36,
				})
			end
			-- the east column's corners hang off their west neighbour alone
			local corner = c == 5 and (r == 1 or r == 4)
			local below = r < 4 and not (c == 5 and r == 3)
			if below and not corner then
				table.insert(doors, {
					id = string.format("D_%d_%d_S", r, c),
					kind = "Doorway",
					rooms = { name(r, c), name(r + 1, c) },
					at = x + 40,
				})
			end
		end
	end
	table.insert(anchors, { id = "Fx_Spawn", kind = "PlayerSpawn", room = "G_1_1", pos = Vector3.new(40, 0, 36) })
	table.insert(anchors, { id = "Fx_Wing", kind = "WingFiller", room = "G_3_3", pos = Vector3.new(200, 0, 180) })
	for k = 1, 8 do
		local c = k % 5 + 1
		table.insert(anchors, {
			id = string.format("F_%d", k),
			kind = "FlaskCandidate",
			room = name(2, c),
			pos = Vector3.new((c - 1) * 80 + 10 + k, 0, 100),
		})
	end
	return {
		id = id :: any,
		height = 12,
		acoustic = "Room",
		ambience = "BasementDrone",
		entry = "G_1_1",
		exit = "G_4_4",
		rooms = rooms,
		doors = doors,
		anchors = anchors,
		triggers = {},
	}
end

local function place(anchor: Anchor): RunDirector.Place
	return { room = anchor.room, pos = anchor.pos }
end

local function byId(layout: Layout): { [string]: Anchor }
	local out: { [string]: Anchor } = {}
	for _, anchor in layout.anchors do
		out[anchor.id] = anchor
	end
	return out
end

-- Every placement rule over `ids` (the picks a squad of 1 uses first): the broken ones, as text.
local function ruleProblems(
	layout: Layout,
	ids: { string },
	entry: RunDirector.Place,
	stations: { RunDirector.Place }
): { string }
	local anchors = byId(layout)
	local out: { string } = {}
	local first, second = anchors[ids[1]], anchors[ids[2]]
	local toEntry = if first then RunDirector.walk(layout, place(first), entry) else math.huge
	if toEntry < 20 or toEntry > 60 then
		table.insert(out, string.format("first %s is %.1f walked from the entry", tostring(ids[1]), toEntry))
	end
	if #stations > 0 then
		local best = math.huge
		for _, station in stations do
			best = math.min(best, if second then RunDirector.walk(layout, place(second), station) else math.huge)
		end
		if best > 40 then
			table.insert(out, string.format("second %s is %.1f walked from the main station", tostring(ids[2]), best))
		end
	end
	local dead = RunDirector.deadEndRooms(layout)
	for i, id in ids do
		local a = anchors[id]
		if dead[a.room] then
			table.insert(out, id .. " is in a dead end")
		end
		for j = i + 1, #ids do
			local d = RunDirector.walk(layout, place(a), place(anchors[ids[j]]))
			if d < 30 then
				table.insert(out, string.format("%s and %s are %.1f walked apart", id, ids[j], d))
			end
		end
	end
	return out
end

-- Feeder candidates: three north of the frame's centre line, three south (or `north` of them all north).
local function rooftopsFixture(allNorth: boolean): Layout
	local layout = gridFixture("City1_Rooftops")
	local spots = { { 332, 57 }, { 226, 22 }, { 79, 50 }, { 37, 230 }, { 200, 249 }, { 349, 206 } }
	for i, spot in spots do
		local z = if allNorth then (i * 11) else spot[2]
		local r, c = math.floor(z / 72) + 1, math.floor(spot[1] / 80) + 1
		table.insert(layout.anchors, {
			id = string.format("C1_Feeder%d", i),
			kind = "FeederCandidate",
			room = string.format("G_%d_%d", r, c),
			pos = Vector3.new(spot[1], 0, z),
		})
	end
	return layout
end

return {
	["the fixtures validate"] = function(t: Expect)
		t.eq(table.concat(LayoutSchema.validate(gridFixture("City2_Airport")), "; "), "")
		t.eq(table.concat(LayoutSchema.validate(rooftopsFixture(false)), "; "), "")
	end,

	["batteries: 9 [7] in pick order, every rule kept on 16 seeds, the prefix a squad of n uses keeps them too"] = function(
		t: Expect
	)
		local layout = gridFixture("City2_Airport")
		local entry = RunDirector.entryPlace(layout, nil)
		local stations = RunDirector.mainStations(layout, nil, nil)
		t.eq(#stations, 1, "the wing filler is the airport's main station")
		local dead = RunDirector.deadEndRooms(layout)
		t.truthy(dead.G_1_5 and dead.G_4_5 and not dead.G_1_1, "the two dead-end corners")
		local seen: { [string]: boolean } = {}
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			for _, seed in SEEDS do
				local picks = RunDirector.pickBatteries(seed, difficulty, layout, entry, stations)
				local again = RunDirector.pickBatteries(seed, difficulty, layout, entry, stations)
				local tag = difficulty .. " " .. seed
				t.eq(table.concat(picks.anchors, ","), table.concat(again.anchors, ","), tag .. " deterministic")
				t.eq(#picks.anchors, if difficulty == "Standard" then 9 else 7, tag)
				t.eq(picks.broken, 0, tag .. " breaks no rule")
				local problems = ruleProblems(layout, picks.anchors, entry, stations)
				t.eq(#problems, 0, tag .. ": " .. table.concat(problems, "; "))
				local unique: { [string]: boolean } = {}
				for _, id in picks.anchors do
					t.falsy(unique[id], tag .. " " .. id .. " once")
					unique[id] = true
				end
				for players = 1, 4 do
					local n = RadarRules.batteriesPlaced(difficulty, players)
					local squad = table.move(picks.anchors, 1, n, 1, {})
					t.eq(#ruleProblems(layout, squad, entry, stations), 0, tag .. " a squad of " .. players)
				end
				seen[table.concat(picks.anchors, ",")] = true
			end
		end
		local variety = 0
		for _ in seen do
			variety += 1
		end
		t.truthy(variety >= 8, string.format("the seed varies the picks (%d distinct)", variety))
	end,

	["batteries: their own stream, so another decision's draws never move them"] = function(t: Expect)
		local layout = gridFixture("City2_Airport")
		local entry = RunDirector.entryPlace(layout, nil)
		local a = RunDirector.pickBatteries(5, "Standard", layout, entry, {})
		RunDirector.pickFlasks(5, "Standard", layout)
		RunDirector.pickBatteries(6, "Nightmare", layout, entry, {})
		local b = RunDirector.pickBatteries(5, "Standard", layout, entry, {})
		t.eq(table.concat(a.anchors, ","), table.concat(b.anchors, ","))
	end,

	["batteries degrade deterministically: the fewest broken rules, then the lowest id"] = function(t: Expect)
		local layout = gridFixture("City2_Airport")
		-- only three candidates, all in the dead-end corner, 10 apart, far from the entry and the station
		local kept: { Anchor } = {}
		for _, anchor in layout.anchors do
			if anchor.kind ~= "BatteryCandidate" then
				table.insert(kept, anchor)
			end
		end
		for i, id in { "Z_c", "Z_a", "Z_b" } do
			table.insert(
				kept,
				{ id = id, kind = "BatteryCandidate", room = "G_4_5", pos = Vector3.new(340 + 10 * i, 0, 250) }
			)
		end
		layout.anchors = kept
		local entry = RunDirector.entryPlace(layout, nil)
		local stations = RunDirector.mainStations(layout, nil, nil)
		for _, seed in SEEDS do
			local picks = RunDirector.pickBatteries(seed, "Standard", layout, entry, stations)
			t.eq(table.concat(picks.anchors, ","), "Z_a,Z_b,Z_c", "seed " .. seed .. ": lowest ids, whatever the seed")
			t.truthy(picks.broken > 0, "seed " .. seed .. " counts its broken rules")
		end
		-- one candidate that keeps every rule of the first slot wins it over the lower ids
		table.insert(
			layout.anchors,
			{ id = "Z_z", kind = "BatteryCandidate", room = "G_1_2", pos = Vector3.new(100, 0, 36) }
		)
		local mixed = RunDirector.pickBatteries(3, "Standard", layout, entry, stations)
		t.eq(mixed.anchors[1], "Z_z", "the rule-keeping candidate first")
	end,

	["flasks: 3, 3, 2, 2, 2 [2, 2, 1, 1, 1] a stage, distinct flask candidates, deterministic"] = function(t: Expect)
		local want: { [string]: { [string]: number } } = {
			Standard = {
				Level0_Basement = 3,
				Level1_Hallways = 3,
				Level2_Auditorium = 2,
				City1_Rooftops = 2,
				City2_Airport = 2,
			},
			Nightmare = {
				Level0_Basement = 2,
				Level1_Hallways = 2,
				Level2_Auditorium = 1,
				City1_Rooftops = 1,
				City2_Airport = 1,
			},
		}
		for difficulty, counts in want do
			for stage, count in counts do
				local layout = gridFixture(stage)
				local anchors = byId(layout)
				for _, seed in SEEDS do
					local picks = RunDirector.pickFlasks(seed, difficulty :: any, layout)
					t.eq(#picks, count, string.format("%s %s seed %d", difficulty, stage, seed))
					t.eq(
						table.concat(picks, ","),
						table.concat(RunDirector.pickFlasks(seed, difficulty :: any, layout), ",")
					)
					local unique: { [string]: boolean } = {}
					for _, id in picks do
						t.truthy(anchors[id] and anchors[id].kind == "FlaskCandidate" and not unique[id], id)
						unique[id] = true
					end
				end
			end
		end
		t.eq(#RunDirector.pickFlasks(1, "Standard", gridFixture("Level3_Roof")), 0, "the roof places none")
	end,

	["feeders: 3 of 6 on both arcs for 16 seeds, from the objective's own stream"] = function(t: Expect)
		local layout = rooftopsFixture(false)
		local spec = ObjectiveConfig.forLevel("City1_Rooftops")
		t.truthy(spec ~= nil and spec.stations ~= nil, "the rooftops pick their stations")
		if not spec then
			return
		end
		for _, seed in SEEDS do
			local picks = RunDirector.pickStations(seed, layout, spec)
			t.eq(#picks, 3, "seed " .. seed)
			t.truthy(RunDirector.bothArcs(picks), "seed " .. seed .. " walks both arcs")
			local unique: { [string]: boolean } = {}
			for _, anchor in picks do
				t.truthy(anchor.kind == "FeederCandidate" and not unique[anchor.id], anchor.id)
				unique[anchor.id] = true
			end
			local again = RunDirector.pickStations(seed, layout, spec)
			t.eq(again[1].id .. again[2].id .. again[3].id, picks[1].id .. picks[2].id .. picks[3].id)
		end
		-- every candidate on one arc: the pick cannot keep the rule and still gives three, the same each time
		local north = rooftopsFixture(true)
		local a = RunDirector.pickStations(9, north, spec)
		local b = RunDirector.pickStations(9, north, spec)
		t.eq(#a, 3)
		t.eq(a[1].id .. a[2].id .. a[3].id, b[1].id .. b[2].id .. b[3].id)
	end,

	["the plan carries the picks: batteries and flasks per stage, the feeders in objectives"] = function(t: Expect)
		local layout = rooftopsFixture(false)
		local plan = RunDirector.plan(4242, "Standard", { layout }, ZoneGraph.build({ layout }))
		local feeders = RunDirector.objectiveOf(plan, "City1_Rooftops")
		t.truthy(feeders and #feeders.anchors == 3 and feeders.prop == "FeederCabinet", "the feeders")
		local batteries = plan.batteries and plan.batteries.City1_Rooftops
		t.truthy(batteries and #batteries.anchors == 9, "nine batteries in pick order")
		t.eq(#RunDirector.batteriesOf(plan, "City1_Rooftops", 1), 6, "a squad of one uses six")
		t.eq(#RunDirector.batteriesOf(plan, "City1_Rooftops", 4), 9, "a squad of four uses nine")
		t.eq(#RunDirector.batteriesOf(plan, "Level0_Basement", 4), 0, "a level the plan has no layout for")
		local flasks = plan.flasks and plan.flasks.City1_Rooftops
		t.truthy(flasks and #flasks == 2, "two flasks on the rooftops")
		-- the feeders are the rooftops' main stations: one battery stands within 40 walked of a picked feeder
		local stations = RunDirector.mainStations(layout, plan.route, if feeders then feeders.anchors else nil)
		t.eq(#stations, 3, "the run's three feeders")
	end,

	["the real floors: every rule once a floor offers 36 battery candidates (the short ones are listed)"] = function(
		t: Expect
	)
		local layouts = Builder.layouts()
		local graph = ZoneGraph.build(layouts)
		local short: { string } = {}
		for _, layout in layouts do
			if not StageConfig.isSneaking(layout.id) then
				continue
			end
			local count = 0
			for _, anchor in layout.anchors do
				if anchor.kind == "BatteryCandidate" then
					count += 1
				end
			end
			if count < 36 then
				table.insert(short, string.format("%s %d of 36", layout.id, count))
				continue
			end
			for _, difficulty: Enums.Difficulty in DIFFICULTIES do
				for _, seed in SEEDS do
					local plan = RunDirector.plan(seed, difficulty, layouts, graph)
					local picks = (plan.batteries :: any)[layout.id]
					local entry = RunDirector.entryPlace(layout, plan.route)
					local objective = RunDirector.objectiveOf(plan, layout.id)
					local stations =
						RunDirector.mainStations(layout, plan.route, if objective then objective.anchors else nil)
					local problems = ruleProblems(layout, picks.anchors, entry, stations)
					t.eq(
						#problems,
						0,
						string.format("%s %s %d: %s", layout.id, difficulty, seed, table.concat(problems, "; "))
					)
				end
			end
		end
		if #short > 0 then
			print("  note battery candidates short of 36 (the full rules wait for them): " .. table.concat(short, ", "))
		end
		local plan = RunDirector.plan(20251029, "Standard", layouts, graph)
		for _, layout in layouts do
			local picks = plan.batteries and plan.batteries[layout.id]
			t.eq(
				picks ~= nil,
				StageConfig.isSneaking(layout.id),
				layout.id .. ": batteries on the sneaking stages only"
			)
		end
	end,
}
