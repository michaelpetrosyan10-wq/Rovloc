--!strict
-- Hearing. Same level only, never a zero-radius pulse. Air: heard out to radius x Senses.HearingMultiplier x the
-- difficulty x the pacing scale, strength 1 at the source falling to 0 at the edge; each wall multiplies the reach by
-- WallOcclusion and only MaxOccludingWalls count. Water: straight line, walls never counted. Vent with the listener in
-- a duct: rail distance (route between the nearest nodes, straight along one duct, via the node around a corner) x
-- VentPropagationMultiplier, walls never counted, the Air route when the ducts do not connect. Vent with the listener
-- outside: through the walls, or leaking out of an open grate near the listener (only the mouth-to-listener walls
-- count), never out of a closed one, and grates out of reach are not even asked about. Localisation: Critical and
-- High exact; Low and Normal blurred horizontally within 15% of the distance, the same way every time for one pulse.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local NoiseConfig = require(ReplicatedStorage.Shared.Config.NoiseConfig)
local Types = require(ReplicatedStorage.Shared.Types)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)

local Hearing = require(ServerScriptService.Services.Monster.MonsterAIService.Hearing)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Listener = Hearing.Listener

local LEVEL: Enums.LevelId = "Level2_ScienceHall"
local DIFFICULTIES: { Enums.Difficulty } = { "Standard", "Nightmare" }
local EPS = 1e-6
local VPM = NoiseConfig.VentPropagationMultiplier
local WO = NoiseConfig.WallOcclusion

--------------------------------------------------------------------------------
-- Builders
--------------------------------------------------------------------------------

type EventOptions = { medium: Enums.NoiseMedium?, ventNodeId: string?, serverTime: number?, levelId: Enums.LevelId? }

local function pulse(kind: Enums.NoiseKind, position: Vector3, options: EventOptions?): Types.NoiseEvent
	local opts: EventOptions = options or {}
	local spec = NoiseConfig.Kinds[kind]
	return {
		position = position,
		radius = spec.radius,
		kind = kind,
		priority = spec.priority,
		levelId = opts.levelId or LEVEL,
		medium = opts.medium or spec.medium,
		ventNodeId = opts.ventNodeId,
		sourceUserId = nil,
		serverTime = opts.serverTime or 1000,
	}
end

local function walls(count: number): (from: Vector3, to: Vector3) -> number
	return function(_from: Vector3, _to: Vector3): number
		return count
	end
end

local function noWallsAsked(t: Expect): (from: Vector3, to: Vector3) -> number
	return function(_from: Vector3, _to: Vector3): number
		t.fail("walls were counted on a route that ignores them")
		return 0
	end
end

local function listenerAt(position: Vector3, difficulty: Enums.Difficulty?): Listener
	return {
		position = position,
		levelId = LEVEL,
		inVent = false,
		ventNode = nil,
		graph = nil,
		difficulty = difficulty or "Standard",
		occluders = walls(0),
		grateOpen = function(_grateId: string): boolean
			return false
		end,
		-- the geometry specs measure plain reach: the pacing scale cancels the difficulty's hearing multiplier
		-- (harder Standard hears 15 % further; the multiplier spec sets its own scale)
		scale = 1
			/ (if difficulty == "Nightmare" then DifficultyConfig.Nightmare else DifficultyConfig.Standard).hearingMultiplier,
	}
end

local function addNode(graph: VentGraph.Graph, id: string, position: Vector3, links: { string })
	local nodes = graph.nodes :: { [string]: VentGraph.Node }
	nodes[id] = { id = id, position = position, links = links, grateId = nil }
end

-- A grate on `nodeId` whose wall faces along `facing`, `wallOffset` studs from the node.
local function addGrate(graph: VentGraph.Graph, id: string, nodeId: string, facing: Vector3, wallOffset: number)
	local node = graph.nodes[nodeId]
	local wallAt = node.position + facing * wallOffset
	local wall = CFrame.lookAt(wallAt, wallAt + facing)
	local grates = graph.grates :: { [string]: VentGraph.Grate }
	grates[id] = {
		id = id,
		nodeId = nodeId,
		facingZoneId = "Room",
		lockable = false,
		criticalPath = false,
		wall = wall,
		mouth = wall.Position + wall.LookVector * VentGraph.MouthOut,
	}
	local grateAtNode = graph.grateAtNode :: { [string]: string }
	grateAtNode[nodeId] = id
	local nodes = graph.nodes :: { [string]: VentGraph.Node }
	nodes[nodeId] = { id = node.id, position = node.position, links = node.links, grateId = id }
end

local function emptyGraph(): VentGraph.Graph
	return { levelId = LEVEL, nodes = {}, grates = {}, grateAtNode = {}, segments = {} }
end

-- A U of ducts: a(0,0,0) - b(0,0,-40) - c(10,0,-40) - d(10,0,0); and a separate pair e(40,0,0) - f(40,0,-5).
local function uGraph(): VentGraph.Graph
	local graph = emptyGraph()
	addNode(graph, "a", Vector3.new(0, 0, 0), { "b" })
	addNode(graph, "b", Vector3.new(0, 0, -40), { "a", "c" })
	addNode(graph, "c", Vector3.new(10, 0, -40), { "b", "d" })
	addNode(graph, "d", Vector3.new(10, 0, 0), { "c" })
	addNode(graph, "e", Vector3.new(40, 0, 0), { "f" })
	addNode(graph, "f", Vector3.new(40, 0, -5), { "e" })
	return graph
end

-- A duct p(0,0,0) - q(0,0,-20) - r(0,0,100) (r on the other side of p) with grate g on q opening +X into a room and
-- grate h on r far away.
local function grateGraph(): VentGraph.Graph
	local graph = emptyGraph()
	addNode(graph, "p", Vector3.new(0, 0, 0), { "q", "r" })
	addNode(graph, "q", Vector3.new(0, 0, -20), { "p" })
	addNode(graph, "r", Vector3.new(0, 0, 100), { "p" })
	addGrate(graph, "g", "q", Vector3.new(1, 0, 0), 1)
	addGrate(graph, "h", "r", Vector3.new(1, 0, 0), 1)
	return graph
end

local function inDuct(graph: VentGraph.Graph, position: Vector3, node: string, t: Expect): Listener
	local listener = listenerAt(position)
	listener.inVent = true
	listener.ventNode = node
	listener.graph = graph
	listener.occluders = noWallsAsked(t)
	return listener
end

local function spec(difficulty: Enums.Difficulty): DifficultyConfig.DifficultySpec
	return if difficulty == "Nightmare" then DifficultyConfig.Nightmare else DifficultyConfig.Standard
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["priorityRank: Low < Normal < High < Critical"] = function(t: Expect)
		local previous = 0
		for _, priority: Enums.NoisePriority in Enums.NoisePriority do
			local rank = Hearing.priorityRank(priority)
			t.truthy(rank > previous, priority .. " outranks the one before it")
			previous = rank
		end
		t.eq(Hearing.priorityRank("Critical"), 4, "Critical is the top")
	end,

	["perceive: same level only, and never a zero-radius pulse"] = function(t: Expect)
		local listener = listenerAt(Vector3.new(0, 0, 5))
		listener.occluders = noWallsAsked(t)
		local elsewhere = pulse("GrateKick", Vector3.zero, { levelId = "Level3_Gymnasium" })
		t.eq(Hearing.perceive(elsewhere, listener), nil, "another level")
		local lobby = pulse("GrateKick", Vector3.zero)
		lobby.levelId = nil
		t.eq(Hearing.perceive(lobby, listener), nil, "a pulse with no level is not on this one")
		local silent = pulse("Scripted", Vector3.zero)
		t.eq(Hearing.perceive(silent, listener), nil, "radius 0")
		listener.occluders = walls(0)
		t.truthy(Hearing.perceive(pulse("GrateKick", Vector3.zero), listener), "same level, in reach")
	end,

	["Air: reach is radius x hearing multipliers x pacing scale; strength 1 at the source, 0 at the edge"] = function(
		t: Expect
	)
		local radius = NoiseConfig.Kinds.Walk.radius
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			for _, scale in { 1, 0.8, 1.15 } do
				local reach = radius
					* CreatureConfig.Senses.HearingMultiplier
					* spec(difficulty).hearingMultiplier
					* scale
				t.near(Hearing.multiplier(difficulty, scale) * radius, reach, EPS, "multiplier")
				local inside = listenerAt(Vector3.new(reach - 0.05, 0, 0), difficulty)
				inside.scale = scale
				local outside = listenerAt(Vector3.new(reach + 0.05, 0, 0), difficulty)
				outside.scale = scale
				local label = difficulty .. " x" .. scale
				t.truthy(Hearing.perceive(pulse("Walk", Vector3.zero), inside), label .. ": just inside")
				t.eq(Hearing.perceive(pulse("Walk", Vector3.zero), outside), nil, label .. ": just outside")
			end
		end
		local atSource = Hearing.perceive(pulse("Walk", Vector3.zero), listenerAt(Vector3.zero))
		assert(atSource, "heard at the source")
		t.near(atSource.strength, 1, EPS, "strength 1 at the source")
		local halfway = Hearing.perceive(pulse("Walk", Vector3.zero), listenerAt(Vector3.new(0, 0, radius / 2)))
		assert(halfway, "heard halfway")
		t.near(halfway.strength, 0.5, EPS, "strength 0.5 halfway")
		local bogus = listenerAt(Vector3.zero)
		bogus.scale = 0 / 0
		t.near(
			Hearing.multiplier("Standard", bogus.scale),
			CreatureConfig.Senses.HearingMultiplier * spec("Standard").hearingMultiplier,
			EPS,
			"NaN scale = 1"
		)
	end,

	["Air: each wall multiplies the reach by WallOcclusion; only MaxOccludingWalls count"] = function(t: Expect)
		local radius = NoiseConfig.Kinds.Sprint.radius
		local source = Vector3.new(5, 2, 1)
		for count = 0, NoiseConfig.MaxOccludingWalls + 3 do
			local counted = math.min(count, NoiseConfig.MaxOccludingWalls)
			local reach = radius * WO ^ counted
			t.near(Hearing.occluded(radius, count), reach, EPS, count .. " walls")
			local asked: { { Vector3 } } = {}
			local near = listenerAt(source + Vector3.new(0, 0, reach - 0.05))
			near.occluders = function(from: Vector3, to: Vector3): number
				table.insert(asked, { from, to })
				return count
			end
			local heard = Hearing.perceive(pulse("Sprint", source), near)
			t.truthy(heard, count .. " walls: just inside the shrunk reach")
			t.eq(asked[1][1], source, "walls counted from the source")
			t.eq(asked[1][2], near.position, "to the listener")
			local far = listenerAt(source + Vector3.new(0, 0, reach + 0.05))
			far.occluders = walls(count)
			t.eq(Hearing.perceive(pulse("Sprint", source), far), nil, count .. " walls: just outside")
		end
		t.truthy(WO < 1, "walls muffle")
	end,

	["Water: straight line, walls never counted"] = function(t: Expect)
		local radius = NoiseConfig.Kinds.Freestyle.radius
		local listener = listenerAt(Vector3.new(radius - 0.5, -3, 0))
		listener.occluders = noWallsAsked(t)
		local heard = Hearing.perceive(pulse("Freestyle", Vector3.new(0, -3, 0)), listener)
		assert(heard, "heard across the pool")
		t.near(heard.strength, 0.5 / radius, 1e-4, "strength by straight distance")
	end,

	["Vent, listener in a duct: rail distance x VentPropagationMultiplier, no walls"] = function(t: Expect)
		local graph = uGraph()
		local scurry = NoiseConfig.Kinds.VentScurry.radius
		local fromA = pulse("VentScurry", Vector3.new(0, 0, 0), { ventNodeId = "a" })

		local acrossTheU = inDuct(graph, Vector3.new(10, 0, 0), "d", t)
		t.near(Hearing.route(fromA, acrossTheU).distance, 90 * VPM, 1e-4, "round the U: 40 + 10 + 40")
		t.eq(Hearing.perceive(fromA, acrossTheU), nil, "10 studs away in a line, 126 by duct: not heard")

		local corner = inDuct(graph, Vector3.new(10, 0, -40), "c", t)
		local heard = Hearing.perceive(fromA, corner)
		assert(heard, "50 studs of duct")
		t.near(heard.strength, 1 - 50 * VPM / scurry, 1e-4, "strength by duct distance")

		local alongOne = inDuct(graph, Vector3.new(0, 0, -30), "b", t)
		local fromNearA = pulse("VentScurry", Vector3.new(0, 0, -5), { ventNodeId = "a" })
		t.near(Hearing.route(fromNearA, alongOne).distance, 25 * VPM, 1e-4, "one duct: straight along it")

		local roundB = inDuct(graph, Vector3.new(3, 0, -40), "b", t)
		local nearB = pulse("VentScurry", Vector3.new(0, 0, -37), { ventNodeId = "b" })
		t.near(Hearing.route(nearB, roundB).distance, 6 * VPM, 1e-4, "round a corner: via the node")

		local crawlRadius = NoiseConfig.Kinds.SlowVentCrawl.radius
		local crawl = pulse("SlowVentCrawl", Vector3.new(0, 0, -2), { ventNodeId = "a" })
		local justIn = (crawlRadius / VPM) - 0.05
		t.truthy(Hearing.perceive(crawl, inDuct(graph, Vector3.new(0, 0, -2 - justIn), "a", t)), "crawl, close")
		t.eq(
			Hearing.perceive(crawl, inDuct(graph, Vector3.new(0, 0, -2 - justIn - 0.2), "a", t)),
			nil,
			"a slow crawl is nearly silent: " .. string.format("%.2f", crawlRadius / VPM) .. " studs of duct"
		)

		local otherNetwork = inDuct(graph, Vector3.new(40, 0, -5), "f", t)
		local asked = 0
		otherNetwork.occluders = function(_from: Vector3, _to: Vector3): number
			asked += 1
			return 0
		end
		local fromE = pulse("VentScurry", Vector3.new(40, 0, -60), { ventNodeId = "b" })
		local fallback = Hearing.perceive(fromE, otherNetwork)
		t.truthy(fallback, "ducts that do not connect: heard through the air")
		t.eq(asked, 1, "the Air route counted the walls")
	end,

	["Vent, listener outside: through the walls or leaking out of an open grate near them"] = function(t: Expect)
		local graph = grateGraph()
		local scurry = NoiseConfig.Kinds.VentScurry.radius
		local event = pulse("VentScurry", Vector3.zero, { ventNodeId = "p" })
		local room = Vector3.new(12, 0, -20)
		local mouth = graph.grates.g.mouth
		local asked: { string } = {}
		local listener = listenerAt(room)
		listener.graph = graph
		listener.occluders = function(from: Vector3, _to: Vector3): number
			return if (from - mouth).Magnitude < EPS then 0 else 3
		end
		listener.grateOpen = function(grateId: string): boolean
			table.insert(asked, grateId)
			return grateId == "g"
		end
		t.truthy(room.Magnitude > Hearing.occluded(scurry, 3), "three walls would muffle it out of reach")
		local heard = Hearing.perceive(event, listener)
		assert(heard, "leaks out of the open grate")
		local inside = 20 + (mouth - graph.nodes.q.position).Magnitude
		local expected = inside * VPM + (room - mouth).Magnitude
		t.near(heard.strength, 1 - expected / scurry, 1e-4, "full strength out of the opening")
		t.eq(table.find(asked, "h"), nil, "a grate whose mouth is out of reach is never asked about")

		local closed = listenerAt(room)
		closed.graph = graph
		closed.occluders = listener.occluders
		t.eq(Hearing.perceive(event, closed), nil, "closed grates keep it in")

		local nextRoom = listenerAt(room)
		nextRoom.graph = graph
		nextRoom.grateOpen = listener.grateOpen
		nextRoom.occluders = function(from: Vector3, _to: Vector3): number
			return if (from - mouth).Magnitude < EPS then 2 else 3
		end
		t.eq(Hearing.perceive(event, nextRoom), nil, "two walls past the grate muffle the leak out of reach too")
		local route = Hearing.route(event, nextRoom)
		t.near(route.reach, Hearing.occluded(scurry, 3), 1e-4, "neither route reaches: the direct one is reported")

		local direct = listenerAt(Vector3.new(0, 0, -25))
		direct.graph = graph
		direct.grateOpen = listener.grateOpen
		direct.occluders = walls(1)
		local wallRoute = Hearing.route(event, direct)
		t.near(wallRoute.distance, 25, 1e-4, "next to the duct: straight through one wall")
		t.near(wallRoute.reach, scurry * WO, 1e-4, "one wall")
	end,

	["railDistance: one node, one duct, a route; nil when disconnected or unknown"] = function(t: Expect)
		local graph = uGraph()
		t.near(
			Hearing.railDistance(graph, Vector3.new(0, 0, -1), "a", Vector3.new(0, 0, -3), "a") or -1,
			2,
			1e-4,
			"one duct"
		)
		t.near(
			Hearing.railDistance(graph, Vector3.new(0, 0, -38), "b", Vector3.new(2, 0, -40), "b") or -1,
			4,
			1e-4,
			"round b"
		)
		t.near(Hearing.railDistance(graph, Vector3.zero, "a", Vector3.new(10, 0, -1), "d") or -1, 91, 1e-4, "the U")
		t.eq(Hearing.railDistance(graph, Vector3.zero, "a", Vector3.new(40, 0, 0), "e"), nil, "disconnected")
		t.eq(Hearing.railDistance(graph, Vector3.zero, "zz", Vector3.zero, "a"), nil, "unknown node")
	end,

	["localisation: Critical and High exact; Low and Normal blurred within 15% on the horizontal"] = function(
		t: Expect
	)
		local random = Random.new(97)
		local kinds: { Enums.NoiseKind } = { "Walk", "CrouchWalk", "Sprint", "GrateKick", "Gasp", "GrateUnscrew" }
		local offsets: { [string]: boolean } = {}
		local blurred = 0
		local wide = 0
		for _ = 1, 300 do
			local kind: Enums.NoiseKind = kinds[random:NextInteger(1, #kinds)]
			local source = Vector3.new(random:NextNumber(-80, 80), random:NextNumber(0, 6), random:NextNumber(-80, 80))
			local listener =
				Vector3.new(random:NextNumber(-80, 80), random:NextNumber(0, 6), random:NextNumber(-80, 80))
			local event = pulse(kind, source, { serverTime = 1000 + random:NextNumber(0, 500) })
			local believed = Hearing.believedPosition(event, listener)
			local distance = (source - listener).Magnitude
			if Hearing.priorityRank(event.priority) >= Hearing.priorityRank("High") then
				t.eq(believed, source, kind .. " is placed exactly")
				continue
			end
			blurred += 1
			local offset = believed - source
			t.near(offset.Y, 0, 1e-4, "blur stays on the horizontal")
			t.truthy(offset.Magnitude <= Hearing.BlurFraction * distance + 1e-4, "within 15% of the distance")
			if offset.Magnitude > 0.05 * distance then
				wide += 1
			end
			offsets[string.format("%.3f,%.3f", offset.X, offset.Z)] = true
			t.eq(Hearing.believedPosition(event, listener), believed, "the same pulse blurs the same way")
		end
		local distinct = 0
		for _ in offsets do
			distinct += 1
		end
		t.truthy(blurred > 50 and distinct > blurred * 0.9, "different pulses blur differently")
		t.truthy(wide > blurred * 0.5, "most blurs move the guess noticeably")
		t.eq(Hearing.blur(Vector3.one, 0, 5), Vector3.one, "no distance, no blur")
	end,

	["perceive: the pulse, the believed position and the strength"] = function(t: Expect)
		local kick = pulse("GrateKick", Vector3.new(10, 0, 0))
		local heard = Hearing.perceive(kick, listenerAt(Vector3.new(10, 0, 65)))
		assert(heard, "a kick 65 studs away")
		t.eq(heard.event, kick, "the pulse itself")
		t.eq(heard.position, kick.position, "Critical: exact")
		t.near(heard.strength, 1 - 65 / NoiseConfig.Kinds.GrateKick.radius, 1e-4, "strength")
		local step = pulse("Walk", Vector3.new(0, 0, 0), { serverTime = 1234.5 })
		local walk = Hearing.perceive(step, listenerAt(Vector3.new(0, 0, 20)))
		assert(walk, "a walk 20 studs away")
		t.eq(walk.position, Hearing.believedPosition(step, Vector3.new(0, 0, 20)), "Normal: the blurred guess")
		t.truthy((walk.position - step.position).Magnitude <= 0.15 * 20 + 1e-4, "within 3 studs")

		local defaults = listenerAt(Vector3.new(0, 0, 20))
		defaults.occluders = nil
		defaults.grateOpen = nil
		t.truthy(Hearing.perceive(step, defaults), "the default wall counter (no geometry in the harness: no walls)")
		defaults.graph = grateGraph()
		local scurry = pulse("VentScurry", Vector3.new(0, 0, -5), { ventNodeId = "p" })
		local fromDuct = Hearing.perceive(scurry, defaults)
		assert(fromDuct, "a scurry next door")
		t.near(
			fromDuct.strength,
			1 - 25 / NoiseConfig.Kinds.VentScurry.radius,
			1e-4,
			"VentNetworkService: no grate open"
		)
	end,
}
