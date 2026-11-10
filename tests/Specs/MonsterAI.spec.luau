--!strict
-- MonsterAIService, the pure rules (docs/MONSTER.md 6; web/src/creature/brain.js and states/*.js). The transition
-- table (Brain.decide: priorities, the chase's 22 s give-up and its breather, line of sight lost for 4 s -> Search,
-- the saw-you-hide rule, the 1 s stare, noises, the teleport, the pool), the catch rules (reach, the same floor, eye to
-- eye AND chest to chest: never through a wall, never in the water or into a duct), speeds (nothing but a cutscene
-- outruns a sprinter), the teleport's weighing and sides, the search plan round a noise, the HidingResponse stand-off,
-- patrol loops from the real layouts (order, wrap-around, corners, which loop next), level knowledge (Level 1's rooms,
-- doors and spawn; Level 4's pool), the pool lunge and stuck detection.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)

local Monster = ServerScriptService.Services.Monster.MonsterAIService
local Brain = require(Monster.Brain)
local CreatureBody = require(Monster.CreatureBody)
local Locomotion = require(Monster.Locomotion)
local AquaticStalk = require(Monster.States.AquaticStalk)
local HidingResponse = require(Monster.States.HidingResponse)
local InvestigateNoise = require(Monster.States.InvestigateNoise)
local Patrol = require(Monster.States.Patrol)
local Search = require(Monster.States.Search)
local Sniff = require(Monster.States.Sniff)
local Teleport = require(Monster.States.Teleport)
local WallChase = require(Monster.States.WallChase)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Summary = Brain.Summary

local SENSES = CreatureConfig.Senses
local EPS = 1e-4
local STANDARD = DifficultyConfig.Standard
local PATROL_LEVELS: { Enums.LevelId } =
	{ "Level0_Basement", "Level1_Hallways", "Level2_ScienceHall", "Level3_Gymnasium" }
local ROAMING: { Enums.MonsterState } = { "Patrol", "InvestigateNoise", "Search", "Teleport", "AquaticStalk" }

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
		warping = false,
		canHunt = true,
		sees = false,
		stared = false,
		hidingWatch = false,
		heard = 0,
		investigating = 0,
		chaseSeconds = 0,
		lostSeconds = 0,
		maxChase = STANDARD.maxChaseSeconds,
		chaseLost = STANDARD.chaseLostSeconds,
		swimmer = false,
		inWater = false,
		retreating = false,
		teleportDue = false,
		stateDone = false,
	}
	if edit then
		edit(s)
	end
	return s
end

local function check(
	t: Expect,
	s: Summary,
	state: Enums.MonsterState,
	label: string,
	reposition: boolean?
): Brain.Decision
	local decision = Brain.decide(s)
	t.eq(decision.state, state, label .. " (" .. decision.reason .. ")")
	if reposition ~= nil then
		t.eq(decision.reposition, reposition, label .. ": withdraw")
	end
	return decision
end

local function catchCheck(edit: ((Brain.CatchCheck) -> ())?): Brain.CatchCheck
	local c: Brain.CatchCheck = {
		horizontal = 3,
		vertical = 1.7,
		reach = SENSES.CatchDistance,
		targetInVent = false,
		lineClear = true,
		bodyClear = true,
		playing = true,
		hiding = false,
		canHunt = true,
		busy = false,
		hidden = false,
		stunned = false,
		warping = false,
		creatureInWater = false,
		targetSwimming = false,
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

local function spot(x: number, z: number, kind: Enums.HideKind?): Brain.HideSpot
	local front = CFrame.lookAt(Vector3.new(x, 0, z), Vector3.new(x, 0, z - 1))
	return { id = Instance.new("Model"), kind = kind or "Locker", front = front }
end

--------------------------------------------------------------------------------
-- Spec
--------------------------------------------------------------------------------

local spec = {}

spec["decide: scripted > stunned > dormant > a catch in progress > a warp"] = function(t: Expect)
	for _, state: Enums.MonsterState in Enums.MonsterState do
		check(
			t,
			summary(state, function(s)
				s.scripted = true
				s.stunned = true
				s.sees = true
			end),
			"Scripted",
			state .. ": a cutscene wins"
		)
		check(
			t,
			summary(state, function(s)
				s.stunned = true
				s.sees = true
				s.catching = true
			end),
			"Stunned",
			state .. ": a stun wins over everything but a cutscene"
		)
		check(
			t,
			summary(state, function(s)
				s.awake = false
				s.sees = true
			end),
			"Dormant",
			state .. ": asleep until its level wakes it"
		)
	end
	check(
		t,
		summary("WallChase", function(s)
			s.catching = true
			s.chaseSeconds = 100
		end),
		"WallChase",
		"a catch in progress holds the state, even past the give-up"
	)
	check(
		t,
		summary("Teleport", function(s)
			s.warping = true
			s.sees = true
		end),
		"Teleport",
		"a warp holds the state"
	)
	check(
		t,
		summary("Patrol", function(s)
			s.warping = true
			s.heard = 4
		end),
		"Patrol",
		"nothing interrupts a fade"
	)
end

spec["decide: a stun ends in a withdrawal; a breather stops every hunt"] = function(t: Expect)
	check(
		t,
		summary("Stunned", function(s)
			s.sees = true
		end),
		"Patrol",
		"recovered: withdraws first",
		true
	)
	for _, state: Enums.MonsterState in
		{ "Patrol", "InvestigateNoise", "Search", "HidingResponse" } :: { Enums.MonsterState }
	do
		check(
			t,
			summary(state, function(s)
				s.canHunt = false
				s.sees = true
				s.stared = true
				s.heard = 4
				s.hidingWatch = true
			end),
			"Patrol",
			state .. ": the breather"
		)
	end
	check(
		t,
		summary("HidingResponse", function(s)
			s.canHunt = false
		end),
		"Patrol",
		"a hiding response called off withdraws",
		true
	)
end

spec["decide: a chase gives up at 22 s (28 on Nightmare) whatever it sees, and on a breather"] = function(t: Expect)
	t.eq(STANDARD.maxChaseSeconds, 22, "22 s on Standard")
	t.eq(DifficultyConfig.Nightmare.maxChaseSeconds, 28, "28 s on Nightmare")
	local still = check(
		t,
		summary("WallChase", function(s)
			s.sees = true
			s.chaseSeconds = 21.9
		end),
		"WallChase",
		"still on at 21.9 s"
	)
	t.falsy(still.giveUp, "no give-up yet")
	local over = check(
		t,
		summary("WallChase", function(s)
			s.sees = true
			s.stared = true
			s.chaseSeconds = 22
		end),
		"Patrol",
		"gives up at 22 s even in sight",
		true
	)
	t.truthy(over.giveUp, "a give-up: it fades out")
	local nightmare = summary("WallChase", function(s)
		s.sees = true
		s.chaseSeconds = 25
		s.maxChase = DifficultyConfig.Nightmare.maxChaseSeconds
	end)
	check(t, nightmare, "WallChase", "Nightmare chases on at 25 s")
	local breather = check(
		t,
		summary("WallChase", function(s)
			s.sees = true
			s.canHunt = false
		end),
		"Patrol",
		"the pacing calls it off",
		true
	)
	t.truthy(breather.giveUp, "and it fades out the same way")
end

spec["decide: sight or a stare keeps the chase; lost for 4 s or the last seen point reached: Search"] = function(
	t: Expect
)
	check(
		t,
		summary("WallChase", function(s)
			s.sees = true
		end),
		"WallChase",
		"in sight"
	)
	check(
		t,
		summary("WallChase", function(s)
			s.stared = true
		end),
		"WallChase",
		"stared at"
	)
	check(
		t,
		summary("WallChase", function(s)
			s.lostSeconds = 3.9
		end),
		"WallChase",
		"tracking the last seen point"
	)
	check(
		t,
		summary("WallChase", function(s)
			s.lostSeconds = STANDARD.chaseLostSeconds
		end),
		"Search",
		"lost for chaseLost seconds"
	)
	check(
		t,
		summary("WallChase", function(s)
			s.stateDone = true
		end),
		"Search",
		"reached the last seen point"
	)
	check(
		t,
		summary("WallChase", function(s)
			s.hidingWatch = true
			s.sees = true
		end),
		"HidingResponse",
		"it saw its quarry climb into a hiding spot"
	)
end

spec["decide: sight starts a chase from every roaming state; a stare starts one too"] = function(t: Expect)
	for _, state: Enums.MonsterState in ROAMING do
		if state == "AquaticStalk" then
			continue
		end
		check(
			t,
			summary(state, function(s)
				s.sees = true
			end),
			"WallChase",
			state .. ": seen"
		)
		check(
			t,
			summary(state, function(s)
				s.stared = true
			end),
			"WallChase",
			state .. ": a held stare"
		)
		check(
			t,
			summary(state, function(s)
				s.hidingWatch = true
				s.sees = true
			end),
			"HidingResponse",
			state .. ": saw someone hide"
		)
	end
	check(
		t,
		summary("Patrol", function(s)
			s.sees = true
			s.swimmer = true
			s.inWater = true
		end),
		"AquaticStalk",
		"a swimmer in sight of a swimming Creature: only the telegraphed lunge"
	)
end

spec["decide: HidingResponse holds until its hider is out, then chases on sight or searches"] = function(t: Expect)
	check(
		t,
		summary("HidingResponse", function(s)
			s.sees = true
			s.heard = 4
			s.teleportDue = true
		end),
		"HidingResponse",
		"waits at the spot"
	)
	check(
		t,
		summary("HidingResponse", function(s)
			s.stateDone = true
			s.sees = true
		end),
		"WallChase",
		"out and in sight: the chase"
	)
	check(
		t,
		summary("HidingResponse", function(s)
			s.stateDone = true
		end),
		"Search",
		"slipped away: the search"
	)
end

spec["decide: noises, investigations and the search's break-off"] = function(t: Expect)
	check(
		t,
		summary("Patrol", function(s)
			s.heard = 1
		end),
		"InvestigateNoise",
		"a noise is investigated"
	)
	check(
		t,
		summary("InvestigateNoise", function(s)
			s.heard = 2
			s.investigating = 2
		end),
		"InvestigateNoise",
		"an equally loud noise re-targets"
	)
	check(
		t,
		summary("InvestigateNoise", function(s)
			s.stateDone = true
		end),
		"Patrol",
		"nothing found"
	)
	check(
		t,
		summary("InvestigateNoise", function(s)
			s.heard = 1
			s.investigating = 3
			s.stateDone = true
		end),
		"Patrol",
		"a quieter noise does not keep a finished search going"
	)
	check(
		t,
		summary("Search", function(s)
			s.heard = 2
		end),
		"Search",
		"a quiet noise does not break a search"
	)
	check(
		t,
		summary("Search", function(s)
			s.heard = 3
		end),
		"InvestigateNoise",
		"a High noise does"
	)
	check(
		t,
		summary("Search", function(s)
			s.stateDone = true
		end),
		"Patrol",
		"the search over"
	)
end

spec["decide: a due teleport, run to its end; the pool"] = function(t: Expect)
	check(
		t,
		summary("Patrol", function(s)
			s.teleportDue = true
		end),
		"Teleport",
		"due"
	)
	check(t, summary("Teleport", nil), "Teleport", "runs to its end")
	check(
		t,
		summary("Teleport", function(s)
			s.stateDone = true
		end),
		"Patrol",
		"then the stalk again"
	)
	check(
		t,
		summary("Teleport", function(s)
			s.sees = true
		end),
		"WallChase",
		"sight (the service holds it back while it stalks) starts a chase"
	)
	check(
		t,
		summary("Patrol", function(s)
			s.teleportDue = true
			s.heard = 2
		end),
		"InvestigateNoise",
		"a noise comes before a teleport"
	)
	check(
		t,
		summary("Patrol", function(s)
			s.swimmer = true
		end),
		"AquaticStalk",
		"a swimmer on the pool level"
	)
	check(t, summary("AquaticStalk", nil), "Patrol", "the water is calm")
	check(
		t,
		summary("Patrol", function(s)
			s.retreating = true
			s.inWater = true
			s.sees = true
		end),
		"AquaticStalk",
		"after a grab it retreats in the water"
	)
end

spec["catches: in reach, on the same floor, eye to eye and chest to chest: never through a wall"] = function(t: Expect)
	t.eq(Brain.catchKind(catchCheck()), "Hallway", "in reach in the open")
	t.eq(SENSES.CatchDistance, CreatureConfig.Rig.Reach, "the reach is the rig's")
	t.eq(
		Brain.catchKind(catchCheck(function(c)
			c.horizontal = c.reach + 0.01
		end)),
		nil,
		"just out of reach"
	)
	t.eq(
		Brain.catchKind(catchCheck(function(c)
			c.vertical = SENSES.CatchVertical + 0.01
		end)),
		nil,
		"another floor"
	)
	t.eq(
		Brain.catchKind(catchCheck(function(c)
			c.lineClear = false
		end)),
		nil,
		"no catch through a wall (eyes)"
	)
	t.eq(
		Brain.catchKind(catchCheck(function(c)
			c.bodyClear = false
		end)),
		nil,
		"no catch through a wall (bodies: a low wall, a counter)"
	)
	for _, field in
		{ "busy", "hidden", "stunned", "warping", "hiding", "targetInVent", "creatureInWater", "targetSwimming" }
	do
		t.eq(
			Brain.catchKind(catchCheck(function(c)
				(c :: any)[field] = true
			end)),
			nil,
			field
		)
	end
	t.eq(
		Brain.catchKind(catchCheck(function(c)
			c.playing = false
		end)),
		nil,
		"not playing"
	)
	t.eq(
		Brain.catchKind(catchCheck(function(c)
			c.canHunt = false
		end)),
		nil,
		"a breather"
	)
	local a, b, c = Instance.new("Player"), Instance.new("Player"), Instance.new("Player")
	local order = WallChase.catchOrder({ a, b, c }, b)
	t.eq(order[1], b, "the target first")
	t.eq(#order, 3, "then everyone else in sight")
	t.eq(WallChase.catchOrder({ a, c }, b)[1], a, "a target out of sight is not tried")
	t.eq(#WallChase.catchOrder({}, b), 0, "nobody in sight")
end

spec["speeds: the Stalk is slower than a walker, the Chase than a sprinter; only a cutscene is faster"] = function(
	t: Expect
)
	t.near(Brain.speedFor("WallChase", "Standard"), 16.5, EPS, "the chase at 16.5")
	t.truthy(CreatureConfig.Speeds.Patrol < GameConfig.WalkSpeed, "a walker outpaces the Stalk")
	t.truthy(CreatureConfig.Speeds.WallChase < GameConfig.WalkSpeed * 2, "a chase")
	t.truthy(CreatureConfig.SpeedCap < GameConfig.SprintSpeed, "the cap is under a sprint")
	for _, difficulty: Enums.Difficulty in { "Standard", "Nightmare" } :: { Enums.Difficulty } do
		for _, state: Enums.MonsterState in Enums.MonsterState do
			local speed = Brain.speedFor(state, difficulty)
			if state ~= "Scripted" then
				t.truthy(speed < GameConfig.SprintSpeed, state .. " on " .. difficulty .. " never outruns a sprinter")
				t.truthy(speed <= CreatureConfig.SpeedCap + EPS, state .. " under the cap")
			end
		end
	end
	t.near(Brain.speedFor("Scripted", "Nightmare"), CreatureConfig.Speeds.Scripted, EPS, "scripted is not scaled")
	t.eq(Brain.speedFor("Dormant", "Standard"), 0, "dormant stands")
	t.truthy(Brain.speedFor("WallChase", "Nightmare") > Brain.speedFor("WallChase", "Standard"), "Nightmare is faster")
	t.truthy(Brain.isChase("WallChase") and not Brain.isChase("Patrol") and not Brain.isChase("Search"), "the chase")
	t.truthy(CreatureConfig.Speeds.AquaticStalk < GameConfig.FreestyleSpeed, "a freestyle swimmer outpaces it")
end

spec["teleport: weighing the target, picking by weight, and which side of them a spot lies"] = function(t: Expect)
	local plain = Teleport.targetWeight({ isolated = false, loud = false, lastTarget = true })
	t.eq(plain, 1, "nothing special")
	t.truthy(Teleport.targetWeight({ isolated = true, loud = false, lastTarget = true }) > plain, "isolated")
	t.truthy(Teleport.targetWeight({ isolated = false, loud = true, lastTarget = true }) > plain, "loud lately")
	t.truthy(Teleport.targetWeight({ isolated = false, loud = false, lastTarget = false }) > plain, "not the last one")
	t.eq(Teleport.pickWeighted({ "a", "b" }, { 1, 3 }, 0.2), "a", "a low roll")
	t.eq(Teleport.pickWeighted({ "a", "b" }, { 1, 3 }, 0.3), "b", "past a's share")
	t.eq(Teleport.pickWeighted({ "a", "b" }, { 0, 0 }, 0.9), "a", "no weights: the first")
	t.eq(Teleport.pickWeighted({} :: { string }, {}, 0.5), nil, "nobody")
	local target = Vector3.new(0, 0, 0)
	local look = Vector3.new(0, 0, -1) -- walking north
	local trail = { Vector3.new(0, 0, 8), Vector3.new(0, 0, 14), Vector3.new(0, 0, 20) }
	t.eq(Teleport.classify(Vector3.new(0, 0, 16), target, trail, look, look), "Behind", "on the way they came")
	t.eq(Teleport.classify(Vector3.new(0, 0, -16), target, trail, look, look), "Ahead", "round the corner ahead")
	t.eq(Teleport.classify(Vector3.new(16, 0, 1), target, trail, look, look), "Side", "off to the side")
	t.eq(Teleport.classify(Vector3.new(0, 0, 16), target, {}, look, nil), "Behind", "behind their look")
	t.eq(CreatureConfig.Teleport.MinWalk, 12, "12..24 studs of walking")
	t.eq(CreatureConfig.Teleport.MaxWalk, 24)
	t.eq(CreatureConfig.Teleport.MinStraight, 12, "never within 12 studs of anyone")
	t.eq(CreatureConfig.Teleport.WarningSeconds, 1.6, "the 1.6 s warning")
end

spec["search: a look back the way it came, then the nearest hiding spots, capped"] = function(t: Expect)
	local at = Vector3.new(0, 0, 0)
	local spots = { spot(9, 0), spot(3, 0, "Barrel"), spot(6, 0, "Cabinet"), spot(12, 0) }
	local steps = InvestigateNoise.searchPlan(at, spots, Vector3.new(0, 0, -1), 2)
	t.eq(#steps, 3, "the look and two spots")
	t.eq(steps[1].kind, "Look", "first it looks back")
	t.truthy(steps[1].face and near(steps[1].face :: Vector3, Vector3.new(0, 0, 1)), "the way it came")
	t.eq(steps[2].kind, "Spot", "then a hiding spot")
	t.near(steps[2].position.X, 3, EPS, "the nearest first")
	t.near(steps[3].position.X, 6, EPS, "then the next")
	t.eq(steps[2].spot, spots[2].id, "the spot itself, for the sniff")
	t.truthy(steps[2].face and near(steps[2].face :: Vector3, Vector3.new(0, 0, 1)), "faces into the spot")
	t.eq(steps[2].seconds, Sniff.SniffSeconds, "sniffing as long as a breath check")
	t.eq(#InvestigateNoise.searchPlan(at, {}, Vector3.zero, 4), 1, "nothing around: it only looks")
	local random = Random.new(11)
	local list = { 1, 2, 3, 4, 5, 6 }
	local shuffled = Search.shuffled(list, random)
	t.eq(#shuffled, #list, "a permutation")
	local seen: { [number]: boolean } = {}
	for _, v in shuffled do
		seen[v] = true
	end
	t.eq(#list, 6, "the list is left alone")
	for _, v in list do
		t.truthy(seen[v], "keeps " .. v)
	end
	local again = Search.shuffled(list, Random.new(11))
	t.eq(table.concat(again, ","), table.concat(shuffled, ","), "seeded: the same order for the same seed")
	t.eq(CreatureConfig.Search.MinSeconds, 12, "it searches 12..18 s")
	t.eq(CreatureConfig.Search.MaxSeconds, 18)
end

spec["hiding response: it stands off the spot's front; the LookAway and ReachIn timings"] = function(t: Expect)
	local front = CFrame.lookAt(Vector3.new(10, 0, 10), Vector3.new(10, 0, 20))
	local stand = HidingResponse.standPoint(front)
	t.truthy(near(stand, Vector3.new(10, 0, 10 + CreatureConfig.Hiding.StandOff - 1)), "out along the front")
	local tilted = CFrame.lookAt(Vector3.new(0, 0, 0), Vector3.new(0, 5, 0.0001))
	t.near(HidingResponse.standPoint(tilted).Y, 0, EPS, "stays on the floor")
	local H = CreatureConfig.Hiding
	t.eq(STANDARD.reachInSeconds, 30, "it reaches in after 30 s")
	t.truthy(DifficultyConfig.Nightmare.reachInSeconds < STANDARD.reachInSeconds, "sooner on Nightmare")
	t.truthy(H.LookAwayMin >= 7 and H.LookAwayMax <= 10, "a LookAway every 7..10 s")
	t.truthy(H.LookAwayMax + H.LookAwaySeconds < STANDARD.reachInSeconds, "at least one LookAway before the reach")
	t.truthy(H.GruntLead > 0 and H.GruntLead < H.LookAwayMin, "the grunt comes first")
	t.eq(H.KickOutSeconds, 45, "kicked out at 45 s")
	t.eq(H.KickOutWarning, 35, "warned at 35 s")
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
	local reachable = function(p: Vector3): boolean
		return p.Z < 10
	end
	t.eq(Patrol.nearestIndex(loops[1], Vector3.new(19, 0, 18), reachable), 2, "the nearest it can walk to")
end

spec["patrol: every real level's loops close, every hop is a walk, every waypoint in a known room"] = function(
	t: Expect
)
	for _, levelId: Enums.LevelId in PATROL_LEVELS do
		local layout = Builder.getLayout(levelId)
		assert(layout, levelId .. " layout")
		local info = Brain.levelInfo(layout)
		assert(info, levelId .. " info")
		t.truthy(#info.loops >= 2, levelId .. " has patrol loops")
		local elevation = WorldConfig.levelElevation(levelId)
		for _, loop in info.loops do
			t.truthy(#loop.waypoints >= 2, levelId .. " " .. loop.id .. " is a loop")
			for index, waypoint in loop.waypoints do
				t.eq(waypoint.order, index, loop.id .. " ordered")
				t.near(waypoint.position.Y, elevation, 0.5, loop.id .. " on the floor")
				local following = loop.waypoints[Patrol.nextIndex(loop, index)]
				t.truthy((following.position - waypoint.position).Magnitude < 160, loop.id .. " hop is a walk")
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

spec["pool: Level 4's basin, its water bounds, and it starts in the tunnels"] = function(t: Expect)
	local layout = Builder.getLayout("Level4_FloodedPool")
	assert(layout, "Level 4 layout")
	local info = Brain.levelInfo(layout)
	assert(info, "Level 4 info")
	t.eq(#info.basins, 1, "one basin")
	local basin = info.basins[1]
	local origin = WorldConfig.levelOrigin("Level4_FloodedPool")
	t.near(basin.deckY, origin.Y, EPS, "the deck is the floor")
	t.truthy(basin.surfaceY < basin.deckY and basin.floorY < basin.surfaceY, "surface under the deck, floor under it")
	t.truthy(basin.fadeOnly == true, "it enters and leaves the water only by a fade (Level 4 fairness)")
	local spawn = info.spawn
	assert(spawn, "Level 4 has a CreatureSpawn")
	-- it hunts the plant tunnels on foot and takes to the water when a swimmer is about
	t.falsy(Locomotion.inWater(basin, spawn.Position), "the Creature starts in the tunnels, on land")
	local clamped = Locomotion.clampToWater(basin, Vector3.new(basin.minX - 50, basin.deckY + 20, basin.maxZ + 50))
	t.truthy(Locomotion.inWater(basin, clamped), "clamped into the water")
	t.near(clamped.Y, basin.surfaceY - Locomotion.SwimDepth, EPS, "at swim depth")
	t.falsy(
		Locomotion.inWater(basin, Vector3.new(basin.minX - 3, basin.deckY + 3, (basin.minZ + basin.maxZ) / 2)),
		"the deck is dry"
	)
	t.eq(Locomotion.poseFor("Water"), "Swim", "it swims in the water")
	t.eq(Locomotion.poseFor("Floor"), "Biped", "and walks on land")
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
	local onAnchor = false
	for _, a in layout.anchors do
		if a.kind == "CreatureSpawn" then
			local at = WorldConfig.levelOrigin("Level1_Hallways") + a.pos
			if Vector3.new(spawn.Position.X - at.X, 0, spawn.Position.Z - at.Z).Magnitude < 0.01 then
				onAnchor = true
			end
		end
	end
	t.truthy(onAnchor, "the spawn stands at a CreatureSpawn anchor")
	t.truthy(
		math.abs(spawn.Position.Y - WorldConfig.levelElevation("Level1_Hallways") - CreatureBody.RootHeight) < 0.5,
		"about standing height over the floor"
	)
	for id, list in info.neighbours do
		for _, other in list do
			t.truthy(table.find(info.neighbours[other] or {}, id) ~= nil, id .. " <-> " .. other)
		end
	end
	for _, room in info.roomList do
		if room.kind ~= "Chase" then
			local found = Brain.roomAt(info, room.centre + Vector3.new(0, 1, 0))
			t.eq(found and found.id, room.id, "roomAt " .. room.id)
		end
	end
	t.eq(Brain.roomAt(info, Vector3.new(-500, 20, -500)), nil, "outside the school")
	t.eq(Brain.levelInfo(Builder.getLayout("Lobby") :: LayoutSchema.LevelLayout), nil, "the lobby is not a level")
	local basement = Brain.levelInfo(Builder.getLayout("Level0_Basement") :: LayoutSchema.LevelLayout)
	t.truthy(basement and basement.spawn ~= nil, "the basement has a spawn too: it hunts from Level 0")
end

spec["pool: it lunges only at an armed swimmer in range, and only when a grab is possible"] = function(t: Expect)
	t.truthy(AquaticStalk.shouldLunge(AquaticStalk.LungeRange, true, true), "in range, armed, hooked")
	t.falsy(AquaticStalk.shouldLunge(AquaticStalk.LungeRange + 0.1, true, true), "out of range")
	t.falsy(AquaticStalk.shouldLunge(2, false, true), "not splashing enough")
	t.falsy(AquaticStalk.shouldLunge(2, true, false), "no grab hook: it never lunges")
	t.truthy(AquaticStalk.GrabReach < AquaticStalk.LungeRange, "grabs within the lunge")
	t.truthy(AquaticStalk.TelegraphSeconds > 0, "every lunge is telegraphed")
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
