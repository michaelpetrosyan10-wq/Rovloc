--!strict
-- MonsterAIService, the pure rules. The transition table (Brain.decide over perception summaries: priorities, chase
-- break-off, breathers, the duct and pool triggers), catch distance rules (Brain.catchKind), patrol loops from the
-- real layouts (order, wrap-around, corners, which loop next), the vent entry decision (open vs kick vs locked), the
-- search plan around a noise, peering into a grate, stuck detection, speeds, level knowledge (Level 1 rooms, doors
-- and spawn; the Level 4 pool's water and decks) and the rail routes the Creature crawls.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)

local Monster = ServerScriptService.Services.Monster.MonsterAIService
local Brain = require(Monster.Brain)
local CreatureBody = require(Monster.CreatureBody)
local Locomotion = require(Monster.Locomotion)
local AquaticStalk = require(Monster.States.AquaticStalk)
local InvestigateNoise = require(Monster.States.InvestigateNoise)
local Patrol = require(Monster.States.Patrol)
local VentChase = require(Monster.States.VentChase)
local WallChase = require(Monster.States.WallChase)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Summary = Brain.Summary

local SENSES = CreatureConfig.Senses
local EPS = 1e-4
local CHASE_STATES: { Enums.MonsterState } = { "WallChase", "VentChase" }
local CALM_STATES: { Enums.MonsterState } = { "InvestigateNoise", "AquaticStalk", "Patrol", "Dormant" }
local SIGHT_STATES: { Enums.MonsterState } = { "Patrol", "InvestigateNoise", "AquaticStalk", "Dormant", "Scripted" }
local QUARRY_STATES: { Enums.MonsterState } = { "Patrol", "InvestigateNoise", "WallChase", "AquaticStalk" }
local PATROL_LEVELS: { Enums.LevelId } = { "Level1_Hallways", "Level2_ScienceHall", "Level3_Gymnasium" }

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function summary(state: Enums.MonsterState, edit: ((Summary) -> ())?): Summary
	local s: Summary = {
		state = state,
		elapsed = 1,
		scripted = false,
		stunned = false,
		awake = true,
		catching = false,
		canHunt = true,
		inVent = false,
		sees = false,
		seesInVent = false,
		ventQuarry = false,
		heard = 0,
		investigating = 0,
		memoryAge = nil,
		breakChase = false,
		swimmer = false,
		stateDone = false,
	}
	if edit then
		edit(s)
	end
	return s
end

local function check(t: Expect, s: Summary, state: Enums.MonsterState, reposition: boolean?, label: string)
	local decision = Brain.decide(s)
	t.eq(decision.state, state, label .. " (" .. decision.reason .. ")")
	if reposition ~= nil then
		t.eq(decision.reposition, reposition, label .. ": withdraw")
	end
end

local function catchCheck(edit: ((Brain.CatchCheck) -> ())?): Brain.CatchCheck
	local c: Brain.CatchCheck = {
		horizontal = 3,
		vertical = 1.7,
		distance = 3.5,
		creatureInVent = false,
		targetInVent = false,
		lineClear = true,
		playing = true,
		hiding = false,
		canHunt = true,
		busy = false,
		hidden = false,
		stunned = false,
	}
	if edit then
		edit(c)
	end
	return c
end

local function near(a: Vector3, b: Vector3, epsilon: number?): boolean
	return (a - b).Magnitude <= (epsilon or EPS)
end

local function anchor(id: string, x: number, z: number, room: string): LayoutSchema.Anchor
	return { id = id, kind = "PatrolWaypoint", room = room, pos = Vector3.new(x, 0, z), yaw = nil }
end

local function loopOf(id: string, points: { Vector3 }, zones: { string }): Brain.Loop
	local waypoints: { Brain.Waypoint } = {}
	local zoneSet: { [string]: boolean } = {}
	local sum = Vector3.zero
	for index, point in points do
		local zone = zones[index] or zones[1]
		table.insert(waypoints, { id = id .. index, loop = id, order = index, position = point, zoneId = zone })
		zoneSet[zone] = true
		sum += point
	end
	return { id = id, waypoints = waypoints, zones = zoneSet, centre = sum / #points }
end

local function constant(value: number): () -> number
	return function(): number
		return value
	end
end

-- A straight duct A -> B -> C along +X at duct height, a branch B -> D along +Z, and grate G on A.
local function ductGraph(): VentGraph.Graph
	local wall = CFrame.lookAt(Vector3.new(-1, 2, 0), Vector3.new(-2, 2, 0))
	return {
		levelId = "Level1_Hallways",
		nodes = {
			A = { id = "A", position = Vector3.new(0, 2, 0), links = { "B" }, grateId = "G" },
			B = { id = "B", position = Vector3.new(20, 2, 0), links = { "A", "C", "D" }, grateId = nil },
			C = { id = "C", position = Vector3.new(40, 2, 0), links = { "B" }, grateId = nil },
			D = { id = "D", position = Vector3.new(20, 2, 30), links = { "B" }, grateId = nil },
		},
		grates = {
			G = {
				id = "G",
				nodeId = "A",
				facingZoneId = "Room",
				lockable = false,
				criticalPath = false,
				wall = wall,
				mouth = wall.Position + wall.LookVector * VentGraph.MouthOut,
			},
		},
		grateAtNode = { A = "G" },
		segments = { ["A|B"] = "A-B", ["B|A"] = "A-B", ["B|C"] = "B-C", ["C|B"] = "B-C" },
	}
end

local function railPoint(a: string, b: string?, t: number, position: Vector3): VentGraph.RailPoint
	return { a = a, b = b, t = t, position = position, distance = 0 }
end

--------------------------------------------------------------------------------
-- Spec
--------------------------------------------------------------------------------

local spec = {}

spec["decide: priorities run scripted > stunned > dormant > a catch in progress"] = function(t: Expect)
	check(
		t,
		summary("WallChase", function(s)
			s.scripted = true
			s.stunned = true
			s.sees = true
		end),
		"Scripted",
		false,
		"a cutscene wins everything"
	)
	check(
		t,
		summary("WallChase", function(s)
			s.stunned = true
			s.sees = true
			s.catching = true
		end),
		"Stunned",
		false,
		"a stun beats a chase"
	)
	check(
		t,
		summary("Patrol", function(s)
			s.awake = false
			s.sees = true
			s.heard = 4
		end),
		"Dormant",
		false,
		"asleep it neither sees nor hears"
	)
	check(
		t,
		summary("WallChase", function(s)
			s.catching = true
			s.canHunt = false
			s.breakChase = true
		end),
		"WallChase",
		false,
		"a catch in progress holds the state"
	)
	check(
		t,
		summary("AquaticStalk", function(s)
			s.catching = true
		end),
		"AquaticStalk",
		false,
		"a pool grab holds the state"
	)
end

spec["decide: a stun ends in a withdrawal, a breather stops every hunt"] = function(t: Expect)
	check(
		t,
		summary("Stunned", function(s)
			s.sees = true
		end),
		"Patrol",
		true,
		"after a stun it withdraws first"
	)
	for _, state: Enums.MonsterState in CHASE_STATES do
		check(
			t,
			summary(state, function(s)
				s.canHunt = false
				s.sees = true
			end),
			"Patrol",
			true,
			state .. " during a cooldown breaks off and withdraws"
		)
	end
	for _, state: Enums.MonsterState in CALM_STATES do
		check(
			t,
			summary(state, function(s)
				s.canHunt = false
				s.heard = 4
				s.sees = true
				s.swimmer = true
				s.ventQuarry = true
			end),
			"Patrol",
			false,
			state .. " during a cooldown only patrols"
		)
	end
end

spec["decide: chase break-off when the chase has run too long"] = function(t: Expect)
	for _, state: Enums.MonsterState in CHASE_STATES do
		check(
			t,
			summary(state, function(s)
				s.breakChase = true
				s.sees = true
				s.ventQuarry = true
			end),
			"Patrol",
			true,
			state .. " breaks off"
		)
	end
	check(
		t,
		summary("InvestigateNoise", function(s)
			s.breakChase = true
			s.sees = true
		end),
		"WallChase",
		nil,
		"break-off only applies to chases"
	)
end

spec["decide: sight starts a chase, the ducts a vent chase"] = function(t: Expect)
	for _, state: Enums.MonsterState in SIGHT_STATES do
		check(
			t,
			summary(state, function(s)
				s.sees = true
			end),
			"WallChase",
			false,
			state .. " -> sees someone"
		)
	end
	check(
		t,
		summary("Patrol", function(s)
			s.sees = true
			s.seesInVent = true
			s.inVent = true
		end),
		"VentChase",
		nil,
		"a crawler seen from inside the ducts"
	)
	for _, state: Enums.MonsterState in QUARRY_STATES do
		check(
			t,
			summary(state, function(s)
				s.ventQuarry = true
				s.sees = true
			end),
			"VentChase",
			nil,
			state .. " -> a crawler gave itself away"
		)
	end
end

spec["decide: a vent chase runs until it is done, then chases on sight or searches"] = function(t: Expect)
	check(
		t,
		summary("VentChase", function(s)
			s.sees = true
			s.inVent = true
		end),
		"VentChase",
		nil,
		"busy crawling"
	)
	check(
		t,
		summary("VentChase", function(s)
			s.stateDone = true
			s.sees = true
		end),
		"WallChase",
		nil,
		"out of the ducts with the target in sight"
	)
	check(
		t,
		summary("VentChase", function(s)
			s.stateDone = true
			s.sees = true
			s.seesInVent = true
		end),
		"InvestigateNoise",
		nil,
		"only a crawler in sight after giving up"
	)
	check(
		t,
		summary("VentChase", function(s)
			s.stateDone = true
		end),
		"InvestigateNoise",
		nil,
		"lost in the ducts: search"
	)
end

spec["decide: a lost chase is followed for MemorySeconds, then searched"] = function(t: Expect)
	check(
		t,
		summary("WallChase", function(s)
			s.memoryAge = SENSES.MemorySeconds - 0.1
		end),
		"WallChase",
		nil,
		"fresh memory"
	)
	check(
		t,
		summary("WallChase", function(s)
			s.memoryAge = SENSES.MemorySeconds + 0.1
		end),
		"InvestigateNoise",
		nil,
		"stale memory"
	)
	check(
		t,
		summary("WallChase", function(s)
			s.memoryAge = 1
			s.stateDone = true
		end),
		"InvestigateNoise",
		nil,
		"reached the last known spot"
	)
	check(t, summary("WallChase", nil), "InvestigateNoise", nil, "no memory at all")
end

spec["decide: noises, investigations and the pool"] = function(t: Expect)
	check(
		t,
		summary("Patrol", function(s)
			s.heard = 1
		end),
		"InvestigateNoise",
		nil,
		"any noise heard while patrolling"
	)
	check(
		t,
		summary("InvestigateNoise", function(s)
			s.heard = 2
			s.investigating = 3
			s.stateDone = true
		end),
		"Patrol",
		nil,
		"a quieter noise does not keep a finished search going"
	)
	check(
		t,
		summary("InvestigateNoise", function(s)
			s.heard = 3
			s.investigating = 3
			s.stateDone = true
		end),
		"InvestigateNoise",
		nil,
		"an equally loud noise re-targets"
	)
	check(t, summary("InvestigateNoise", nil), "InvestigateNoise", nil, "searching")
	check(
		t,
		summary("InvestigateNoise", function(s)
			s.stateDone = true
		end),
		"Patrol",
		nil,
		"nothing found"
	)
	check(
		t,
		summary("Patrol", function(s)
			s.swimmer = true
			s.heard = 4
		end),
		"AquaticStalk",
		nil,
		"a swimmer on the pool level"
	)
	check(t, summary("AquaticStalk", nil), "Patrol", nil, "the water went calm")
	check(t, summary("Patrol", nil), "Patrol", nil, "nothing going on")
	check(t, summary("Dormant", nil), "Patrol", nil, "woken")
end

spec["catches: hallway and vent distances, never through walls or cooldowns"] = function(t: Expect)
	t.eq(Brain.catchKind(catchCheck(nil)), "Hallway", "in reach on the same floor")
	t.eq(
		Brain.catchKind(catchCheck(function(c)
			c.horizontal = SENSES.CatchDistance
		end)),
		"Hallway",
		"exactly at CatchDistance"
	)
	t.eq(
		Brain.catchKind(catchCheck(function(c)
			c.horizontal = SENSES.CatchDistance + 0.01
		end)),
		nil,
		"just beyond CatchDistance"
	)
	t.eq(
		Brain.catchKind(catchCheck(function(c)
			c.vertical = Brain.CatchVertical + 0.5
		end)),
		nil,
		"a floor apart"
	)
	t.eq(
		Brain.catchKind(catchCheck(function(c)
			c.creatureInVent = true
			c.targetInVent = true
			c.distance = SENSES.VentCatchDistance
		end)),
		"Vent",
		"in the ducts at VentCatchDistance"
	)
	t.eq(
		Brain.catchKind(catchCheck(function(c)
			c.creatureInVent = true
			c.targetInVent = true
			c.distance = SENSES.VentCatchDistance + 0.01
		end)),
		nil,
		"just beyond VentCatchDistance"
	)
	t.eq(
		Brain.catchKind(catchCheck(function(c)
			c.targetInVent = true
		end)),
		nil,
		"through a duct wall from the room"
	)
	t.eq(
		Brain.catchKind(catchCheck(function(c)
			c.creatureInVent = true
			c.distance = 2
		end)),
		nil,
		"from the duct into the room"
	)
	local refusals: { [string]: (Brain.CatchCheck) -> () } = {
		["a wall in between"] = function(c)
			c.lineClear = false
		end,
		["not playing"] = function(c)
			c.playing = false
		end,
		["hiding in a locker"] = function(c)
			c.hiding = true
		end,
		["during a cooldown"] = function(c)
			c.canHunt = false
		end,
		["another catch running"] = function(c)
			c.busy = true
		end,
		["while hidden"] = function(c)
			c.hidden = true
		end,
		["while stunned"] = function(c)
			c.stunned = true
		end,
	}
	for label, refuse in refusals do
		t.eq(Brain.catchKind(catchCheck(refuse)), nil, label)
	end
end

spec["catches: the target is tried first, then everyone else in sight"] = function(t: Expect)
	local a, b, c = Instance.new("Player"), Instance.new("Player"), Instance.new("Player")
	local order = WallChase.catchOrder({ a, b, c }, b)
	t.eq(order[1], b, "target first")
	t.eq(#order, 3, "everyone in sight")
	t.eq(WallChase.catchOrder({ a, c }, b)[1], a, "a target out of sight is not tried")
	t.eq(#WallChase.catchOrder({}, b), 0, "nobody in sight")
end

spec["speeds: per state and difficulty, scripted moves at its own pace"] = function(t: Expect)
	t.near(Brain.speedFor("WallChase", "Standard"), CreatureConfig.Speeds.WallChase, EPS, "standard chase")
	t.near(
		Brain.speedFor("VentChase", "Nightmare"),
		CreatureConfig.Speeds.VentChase * DifficultyConfig.Nightmare.creatureSpeedMultiplier,
		EPS,
		"nightmare crawl"
	)
	t.near(Brain.speedFor("Scripted", "Nightmare"), CreatureConfig.Speeds.Scripted, EPS, "scripted is not scaled")
	t.eq(Brain.speedFor("Dormant", "Standard"), 0, "dormant stands")
	t.truthy(Brain.isChase("WallChase") and Brain.isChase("VentChase") and not Brain.isChase("Patrol"), "chases")
end

spec["patrol: loops parse from the anchors in walking order, whatever order they come in"] = function(t: Expect)
	local anchors = {
		anchor("L9_WP_B_02", 10, 0, "R2"),
		anchor("L9_WP_A_03", 20, 20, "R1"),
		anchor("L9_WP_A_01", 0, 0, "R1"),
		anchor("L9_WP_B_01", 0, 10, "R2"),
		anchor("L9_WP_A_02", 20, 0, "R3"),
		{ id = "L9_Spawn", kind = "CreatureSpawn", room = "R1", pos = Vector3.zero, yaw = nil } :: LayoutSchema.Anchor,
		anchor("L9_NotAWaypointId", 5, 5, "R1"),
	}
	local loops = Brain.patrolLoops(anchors, function(a: LayoutSchema.Anchor): Vector3
		return a.pos
	end)
	t.eq(#loops, 2, "two loops")
	t.eq(loops[1].id, "A", "loops by id")
	t.eq(#loops[1].waypoints, 3, "loop A has three waypoints")
	for index, waypoint in loops[1].waypoints do
		t.eq(waypoint.order, index, "A in order")
	end
	t.truthy(loops[1].zones.R1 and loops[1].zones.R3 and not loops[1].zones.R2, "A's zones")
	t.truthy(near(loops[1].centre, Vector3.new(40 / 3, 0, 20 / 3)), "A's centre")
	t.eq(Patrol.nextIndex(loops[1], 1), 2, "1 -> 2")
	t.eq(Patrol.nextIndex(loops[1], 3), 1, "the last waypoint leads back to the first")
	t.eq(Patrol.nearestIndex(loops[1], Vector3.new(19, 0, 18)), 3, "joins at the nearest waypoint")
end

spec["patrol: every real level's loops close and every hop stays short"] = function(t: Expect)
	for _, levelId: Enums.LevelId in PATROL_LEVELS do
		local layout = Builder.getLayout(levelId)
		assert(layout, levelId .. " layout")
		local info = Brain.levelInfo(layout)
		assert(info, levelId .. " info")
		t.truthy(#info.loops >= 4, levelId .. " has patrol loops")
		local elevation = WorldConfig.levelElevation(levelId)
		for _, loop in info.loops do
			t.truthy(#loop.waypoints >= 3, levelId .. " " .. loop.id .. " is a loop")
			for index, waypoint in loop.waypoints do
				t.eq(waypoint.order, index, loop.id .. " ordered")
				t.near(waypoint.position.Y, elevation, EPS, loop.id .. " on the floor")
				local following = loop.waypoints[Patrol.nextIndex(loop, index)]
				t.truthy((following.position - waypoint.position).Magnitude < 120, loop.id .. " hop is a walk")
				t.truthy(info.rooms[waypoint.zoneId] ~= nil, loop.id .. " waypoint in a known room")
			end
		end
	end
end

spec["patrol: corners turn, looks go to the far corner ahead and then onward"] = function(t: Expect)
	t.near(Patrol.turnDegrees(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), Vector3.new(20, 0, 0)), 0, 1e-3, "straight")
	t.near(
		Patrol.turnDegrees(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), Vector3.new(10, 0, 10)),
		90,
		1e-3,
		"right angle"
	)
	t.near(Patrol.turnDegrees(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), Vector3.new(0, 0, 0)), 180, 1e-3, "back")
	local room: Brain.Room = {
		id = "R",
		kind = "Classroom",
		minX = 0,
		maxX = 20,
		minZ = 0,
		maxZ = 10,
		floorY = 0,
		height = 12,
		centre = Vector3.new(10, 0, 5),
	}
	local here = Vector3.new(18, 0, 2)
	local looks = Patrol.cornerLooks(room, here, Vector3.new(1, 0, 0), Vector3.new(0, 0, 1))
	t.eq(#looks, 2, "a corner look and the onward look")
	local corner = Vector3.new(20, 0, 10) - here
	t.truthy(looks[1]:Dot(corner.Unit) > 0.999, "the far corner")
	t.truthy(near(looks[2], Vector3.new(0, 0, 1)), "then the way on")
	local behind = Patrol.cornerLooks(room, Vector3.new(2, 0, 5), Vector3.new(1, 0, 0), Vector3.new(0, 0, 1))
	t.truthy(behind[1].X > -0.2 * behind[1].Magnitude, "never a corner behind it")
	t.eq(#Patrol.cornerLooks(nil, here, Vector3.new(1, 0, 0), Vector3.zero), 0, "no room, nowhere to go: no looks")
end

spec["patrol: the next loop sweeps toward heard noises, keeps away in Relax, else stays near"] = function(t: Expect)
	local near1 = loopOf("Near", { Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), Vector3.new(10, 0, 10) }, { "A" })
	local mid = loopOf("Mid", { Vector3.new(50, 0, 0), Vector3.new(60, 0, 0), Vector3.new(60, 0, 10) }, { "B" })
	local far = loopOf("Far", { Vector3.new(200, 0, 0), Vector3.new(210, 0, 0), Vector3.new(210, 0, 10) }, { "C" })
	local loops = { near1, mid, far }
	local heard: { [string]: Brain.HeardZone } = { C = { at = 100, rank = 3, position = Vector3.new(205, 0, 5) } }
	local function choose(
		roll: number,
		sweep: number,
		avoid: boolean,
		current: string?,
		zones: { [string]: Brain.HeardZone }
	): Brain.Loop?
		return Patrol.chooseLoop(loops, Vector3.new(1, 0, 1), {
			current = current,
			heardZones = zones,
			now = 110,
			sweepChance = sweep,
			avoid = avoid,
			roll = constant(roll),
		})
	end
	t.eq((choose(0.1, 0.6, false, nil, heard) :: Brain.Loop).id, "Far", "a sweep goes where it heard something")
	t.eq((choose(0.65, 0.6, false, nil, heard) :: Brain.Loop).id, "Mid", "no sweep: one of the nearest three")
	t.eq((choose(0, 0.6, false, nil, {}) :: Brain.Loop).id, "Near", "nothing heard: the nearest")
	t.eq((choose(0.1, 0.6, false, "Near", {}) :: Brain.Loop).id, "Mid", "never the loop just walked")
	t.eq((choose(0.1, 0.6, true, nil, heard) :: Brain.Loop).id, "Near", "Relax: farthest from the noise")
	local stale: { [string]: Brain.HeardZone } = { C = { at = 0, rank = 4, position = Vector3.new(205, 0, 5) } }
	t.eq((choose(0.1, 0.6, false, nil, stale) :: Brain.Loop).id, "Near", "an old noise no longer pulls")
	t.eq(Patrol.heardPull(far, heard, 110), 3 * (1 - 10 / Patrol.HeardTtl), "pull fades with age")
	t.eq(Patrol.heardPull(near1, heard, 110), 0, "no pull where nothing was heard")
	t.eq(Patrol.SweepChance.Relax, 0, "Relax never sweeps")
	t.truthy(Patrol.SweepChance.BuildUp > Patrol.SweepChance.Peak, "BuildUp sweeps most")
	t.eq(
		Patrol.chooseLoop({}, Vector3.zero, {
			current = nil,
			heardZones = {},
			now = 0,
			sweepChance = 1,
			avoid = false,
			roll = constant(0),
		}),
		nil,
		"no loops"
	)
end

spec["vent entry: open grates first, kick a closed one only when no open grate leads in, never a locked one"] = function(
	t: Expect
)
	local walk, crawl = 21, 17
	local function option(id: string, state: Enums.GrateState, w: number, c: number): VentChase.EntryOption
		return { grateId = id, state = state, walk = w, crawl = c }
	end
	local id, kick = VentChase.chooseEntry({
		option("Near", "Closed", 5, 5),
		option("Far", "Open", 60, 40),
	}, walk, crawl)
	t.eq(id, "Far", "an open grate beats a nearer closed one")
	t.falsy(kick, "no kick through an open grate")
	id, kick = VentChase.chooseEntry({
		option("Near", "Closed", 5, 5),
		option("Kicked", "Kicked", 30, 10),
	}, walk, crawl)
	t.eq(id, "Kicked", "a kicked grate is open")
	id, kick = VentChase.chooseEntry({
		option("Locked", "Locked", 1, 1),
		option("Closed", "Closed", 40, 40),
		option("Unscrewing", "Unscrewing", 30, 30),
	}, walk, crawl)
	t.eq(id, "Unscrewing", "the cheapest kickable grate when nothing is open")
	t.truthy(kick, "kicks it in")
	id = VentChase.chooseEntry({ option("Locked", "Locked", 1, 1) }, walk, crawl)
	t.eq(id, nil, "never a locked grate")
	id, kick = VentChase.chooseEntry({
		option("Open", "Open", 5, math.huge),
		option("Closed", "Closed", 10, 10),
	}, walk, crawl)
	t.eq(id, "Closed", "an open grate whose ducts do not reach the target does not count")
	t.truthy(kick, "so the reachable closed one is kicked")
	id = VentChase.chooseEntry({ option("Open", "Open", math.huge, 3) }, walk, crawl)
	t.eq(id, nil, "a grate it cannot walk to is no way in")
	id = VentChase.chooseEntry({ option("B", "Open", 21, 17), option("A", "Open", 21, 17) }, walk, crawl)
	t.eq(id, "A", "ties go to the smaller id")
	id = VentChase.chooseEntry({ option("Slow", "Open", 210, 0), option("Fast", "Open", 0, 170) }, walk, crawl)
	t.eq(id, "Fast", "time, not distance: walking and crawling at their own speeds")
end

spec["vent entry: crawl distances run along the ducts from the mouth"] = function(t: Expect)
	local graph = ductGraph()
	local grate = graph.grates.G
	local stub = (grate.mouth - graph.nodes.A.position).Magnitude
	local target = railPoint("B", "C", 0.5, Vector3.new(30, 2, 0))
	t.near(VentChase.crawlDistance(graph, grate, target), stub + 30, 1e-3, "mouth -> A -> B -> half way to C")
	local lonely = table.clone(graph.nodes)
	lonely.Z = { id = "Z", position = Vector3.new(99, 2, 99), links = {}, grateId = nil }
	local cut: VentGraph.Graph = table.clone(graph)
	cut.nodes = lonely
	t.eq(VentChase.crawlDistance(cut, grate, railPoint("Z", nil, 0, Vector3.new(99, 2, 99))), math.huge, "unjoined")
end

spec["rail routes: shortest along the ducts, ending on the target's own point"] = function(t: Expect)
	local graph = ductGraph()
	local from = railPoint("A", "B", 0.25, Vector3.new(5, 2, 0))
	local points, cost = Locomotion.railRoute(graph, from, railPoint("B", "D", 0.5, Vector3.new(20, 2, 15)))
	assert(points, "a route")
	t.truthy(near(points[#points], Vector3.new(20, 2, 15)), "ends at the target")
	t.near(cost, 15 + 15, 1e-3, "via B")
	t.truthy(near(points[1], graph.nodes.B.position), "heads for B, not back to A")
	local same, sameCost = Locomotion.railRoute(graph, from, railPoint("A", "B", 0.75, Vector3.new(15, 2, 0)))
	assert(same, "same duct")
	t.eq(#same, 1, "straight along the same duct")
	t.near(sameCost, 10, 1e-3, "ten studs on")
	local cut: VentGraph.Graph = table.clone(graph)
	local nodes = table.clone(graph.nodes)
	nodes.Z = { id = "Z", position = Vector3.new(99, 2, 99), links = {}, grateId = nil }
	cut.nodes = nodes
	local none = Locomotion.railRoute(cut, from, railPoint("Z", nil, 0, Vector3.new(99, 2, 99)))
	t.eq(none, nil, "no duct leads there")
end

spec["rail stepping: advance walks the polyline by the budget and reports the heading"] = function(t: Expect)
	local points = { Vector3.new(10, 2, 0), Vector3.new(10, 2, 10) }
	local at, index, heading = Locomotion.advance(points, 1, Vector3.new(0, 2, 0), 4)
	t.truthy(near(at, Vector3.new(4, 2, 0)), "four studs along")
	t.eq(index, 1, "still heading for the first point")
	t.truthy(heading and near(heading, Vector3.new(1, 0, 0)), "heading +X")
	at, index, heading = Locomotion.advance(points, 1, Vector3.new(4, 2, 0), 9)
	t.truthy(near(at, Vector3.new(10, 2, 3)), "round the corner")
	t.eq(index, 2, "past the first point")
	t.truthy(heading and near(heading, Vector3.new(0, 0, 1)), "heading +Z")
	at, index = Locomotion.advance(points, 2, Vector3.new(10, 2, 3), 100)
	t.truthy(near(at, Vector3.new(10, 2, 10)), "stops at the end")
	t.eq(index, 3, "finished")
	local stay, stayIndex, stayHeading = Locomotion.advance(points, 3, Vector3.new(10, 2, 10), 5)
	t.truthy(near(stay, Vector3.new(10, 2, 10)) and stayIndex == 3 and stayHeading == nil, "nothing left")
end

spec["pool: Level 4's basin, its decks, water bounds and the way in and out"] = function(t: Expect)
	local layout = Builder.getLayout("Level4_FloodedPool")
	assert(layout, "Level 4 layout")
	local info = Brain.levelInfo(layout)
	assert(info, "Level 4 info")
	t.eq(#info.basins, 1, "one basin")
	local basin = info.basins[1]
	local origin = WorldConfig.levelOrigin("Level4_FloodedPool")
	t.near(basin.deckY, origin.Y, EPS, "the deck is the floor")
	t.truthy(basin.surfaceY < basin.deckY and basin.floorY < basin.surfaceY, "surface under the deck, floor under it")
	t.eq(#basin.edges, 2, "decks west and east only (the basin runs wall to wall north-south)")
	local spawn = info.spawn
	assert(spawn, "Level 4 has a CreatureSpawn")
	t.truthy(Locomotion.inWater(basin, spawn.Position), "the Creature waits in the water")
	local clamped = Locomotion.clampToWater(basin, Vector3.new(basin.minX - 50, basin.deckY + 20, basin.maxZ + 50))
	t.truthy(Locomotion.inWater(basin, clamped), "clamped into the water")
	t.near(clamped.Y, basin.surfaceY - Locomotion.SwimDepth, EPS, "at swim depth")
	local stand, water = Locomotion.deckCrossing(basin, Vector3.new(basin.minX + 3, basin.surfaceY, 80))
	assert(stand and water, "a crossing")
	t.truthy(stand.Position.X < basin.minX, "stands on the west deck")
	t.near(stand.Position.Y, basin.deckY + CreatureBody.RootHeight, EPS, "at standing height")
	t.truthy(Locomotion.inWater(basin, water), "slips in just inside the coping")
	t.falsy(Locomotion.inWater(basin, stand.Position), "the deck is dry")
	local east = Locomotion.deckCrossing(basin, Vector3.new(basin.maxX - 3, basin.surfaceY, 80))
	t.truthy(east and east.Position.X > basin.maxX, "the east deck for the east side")
	local dry = Brain.levelInfo(Builder.getLayout("Level1_Hallways") :: LayoutSchema.LevelLayout)
	t.eq(dry and #dry.basins, 0, "Level 1 has no pool")
end

spec["level knowledge: Level 1 rooms, open doorways, the spawn and roomAt"] = function(t: Expect)
	local layout = Builder.getLayout("Level1_Hallways")
	assert(layout, "Level 1 layout")
	local info = Brain.levelInfo(layout)
	assert(info, "Level 1 info")
	t.eq(info.levelId, "Level1_Hallways", "level id")
	local spawn = info.spawn
	assert(spawn, "spawn")
	for _, a in layout.anchors do
		if a.kind == "CreatureSpawn" then
			t.truthy(near(spawn.Position, WorldConfig.levelOrigin("Level1_Hallways") + a.pos), "spawn at the anchor")
		end
	end
	for id, list in info.neighbours do
		for _, other in list do
			t.truthy(table.find(info.neighbours[other] or {}, id) ~= nil, id .. " <-> " .. other)
		end
	end
	for _, door in layout.doors do
		local listed = table.find(info.neighbours[door.rooms[1]] or {}, door.rooms[2]) ~= nil
		local passable = door.kind == "Doorway" or door.kind == "Door" or door.kind == "Ajar"
		t.eq(listed, passable, door.id .. " (" .. door.kind .. ")")
	end
	for _, room in info.roomList do
		if room.kind ~= "Chase" then
			local found = Brain.roomAt(info, room.centre + Vector3.new(0, 1, 0))
			t.eq(found and found.id, room.id, "roomAt " .. room.id)
		end
	end
	t.eq(Brain.roomAt(info, Vector3.new(-500, 20, -500)), nil, "outside the school")
	t.eq(Brain.levelInfo(Builder.getLayout("Lobby") :: LayoutSchema.LevelLayout), nil, "the lobby is not a level")
end

spec["search: look, then lockers, grates and rooms nearest first, capped"] = function(t: Expect)
	local at = Vector3.new(0, 0, 0)
	local function spot(x: number): CFrame
		return CFrame.lookAt(Vector3.new(x, 0, 0), Vector3.new(x, 0, -1))
	end
	local lockers: { InvestigateNoise.LockerSpot } = {}
	for _, x in { 9, 3, 6, 12 } do
		local locker: Instance = Instance.new("Model")
		table.insert(lockers, { locker = locker, front = spot(x) })
	end
	local grates: { InvestigateNoise.GrateSpot } = {
		{ grateId = "G2", stand = spot(-8) },
		{ grateId = "G1", stand = spot(-4) },
		{ grateId = "G3", stand = spot(-30) },
	}
	local rooms: { Brain.Room } = {}
	for index, x in { 50, 20, 35 } do
		table.insert(rooms, {
			id = "N" .. index,
			kind = "Classroom",
			minX = x - 5,
			maxX = x + 5,
			minZ = -5,
			maxZ = 5,
			floorY = 0,
			height = 12,
			centre = Vector3.new(x, 0, 0),
		})
	end
	local steps = InvestigateNoise.searchPlan({
		at = at,
		room = nil,
		neighbours = rooms,
		lockers = lockers,
		grates = grates,
		look = Vector3.new(0, 0, -1),
	})
	local kinds: { string } = {}
	for _, step in steps do
		table.insert(kinds, step.kind)
	end
	t.eq(table.concat(kinds, ","), "Look,Locker,Locker,Locker,Grate,Grate,Room,Room", "the order and the caps")
	t.truthy(steps[1].face and near(steps[1].face :: Vector3, Vector3.new(0, 0, 1)), "first it looks behind itself")
	t.near(steps[2].position.X, 3, EPS, "nearest locker first")
	t.near(steps[4].position.X, 9, EPS, "third locker")
	t.truthy(steps[2].face and near(steps[2].face :: Vector3, Vector3.new(0, 0, 1)), "faces the locker door")
	t.eq(steps[5].grateId, "G1", "nearest grate first")
	t.near(steps[7].position.X, 20, EPS, "nearest room first")
	local bare = InvestigateNoise.searchPlan({
		at = at,
		room = nil,
		neighbours = {},
		lockers = {},
		grates = {},
		look = Vector3.zero,
	})
	t.eq(#bare, 1, "with nothing around it only looks")
end

spec["peering: a crawler on the grate's ducts, in range and in clear view, is spotted"] = function(t: Expect)
	local mouth = Vector3.new(0, 2, 0)
	local range = InvestigateNoise.PeerRange
	t.truthy(
		InvestigateNoise.peerSees(railPoint("A", "B", 0.1, Vector3.new(range - 1, 2, 0)), "A", mouth, true),
		"in range"
	)
	t.falsy(
		InvestigateNoise.peerSees(railPoint("A", "B", 0.9, Vector3.new(range + 1, 2, 0)), "A", mouth, true),
		"too deep"
	)
	t.falsy(
		InvestigateNoise.peerSees(railPoint("A", "B", 0.1, Vector3.new(3, 2, 0)), "A", mouth, false),
		"around a bend"
	)
	t.falsy(InvestigateNoise.peerSees(railPoint("C", "D", 0.1, Vector3.new(3, 2, 0)), "A", mouth, true), "another duct")
	t.truthy(
		InvestigateNoise.peerSees(railPoint("A", nil, 0.5, Vector3.new(0.5, 2, 0)), "A", mouth, true),
		"on the stub"
	)
end

spec["pool: it lunges only at an armed swimmer in range, and only when a grab is possible"] = function(t: Expect)
	t.truthy(AquaticStalk.shouldLunge(AquaticStalk.LungeRange, true, true), "in range, armed, hooked")
	t.falsy(AquaticStalk.shouldLunge(AquaticStalk.LungeRange + 0.1, true, true), "out of range")
	t.falsy(AquaticStalk.shouldLunge(2, false, true), "not splashing enough")
	t.falsy(AquaticStalk.shouldLunge(2, true, false), "no grab hook: it never lunges")
	t.truthy(AquaticStalk.GrabReach < AquaticStalk.LungeRange, "grabs within the lunge")
end

spec["stuck: no progress while trying to move for StuckSeconds, pauses never count"] = function(t: Expect)
	local seconds = CreatureConfig.Repath.StuckSeconds
	local tracker = CreatureBody.newStuckTracker(seconds)
	local at = Vector3.zero
	t.falsy(tracker:Sample(at, 0, true), "first sample")
	t.falsy(tracker:Sample(at + Vector3.new(0.5, 0, 0), seconds - 0.1, true), "not yet")
	t.truthy(tracker:Sample(at + Vector3.new(0.5, 0, 0), seconds + 0.01, true), "stuck")
	t.falsy(tracker:Sample(at + Vector3.new(0.5, 0, 0), seconds + 0.2, true), "re-armed after reporting")
	local moving = CreatureBody.newStuckTracker(seconds)
	for step = 0, 20 do
		t.falsy(
			moving:Sample(Vector3.new(step * CreatureBody.MinProgress * 1.5, 0, 0), step * seconds, true),
			"progress"
		)
	end
	local waiting = CreatureBody.newStuckTracker(seconds)
	waiting:Sample(at, 0, true)
	t.falsy(waiting:Sample(at, 100, false), "standing still on purpose")
	t.falsy(waiting:Sample(at, 100 + seconds - 0.1, true), "the clock restarts after a pause")
	waiting:Reset()
	t.falsy(waiting:Sample(at, 500, true), "a reset forgets the anchor")
	t.truthy(CreatureBody.flatDirection(Vector3.new(0, 5, 0)) == nil, "no horizontal direction")
	t.truthy(near(CreatureBody.flatDirection(Vector3.new(3, 9, 4)) :: Vector3, Vector3.new(0.6, 0, 0.8)), "flattened")
end

return spec
