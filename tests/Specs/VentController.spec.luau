--!strict
-- VentController's rail maths. On a hand-built network (a cross, a T, a bend, a straight joint, dead ends, an open
-- and a shut grate): input -> travel direction (backward allowed, junction lookahead, bends rounded, ties to the
-- current heading), branch choice at junctions (stop when looking at a wall, blocked stubs never taken, one way on
-- is followed), cursor advance across edges and stubs (stopping at dead ends, short of shut grates, at the mouth of
-- an open grate's stub), the keep-out a grate that shuts on a crawler pushes the cursor out of, panel stops, facing
-- choice and smoothing, rail speed, membership, collider modes, server-move classification, crawl speeds against
-- MovementController, loop volumes, the vignette and hand plants. On every real level's ducts (built with
-- VentShaftBuilder, read with VentGraph): from any duct at any node the input carries the cursor into any branch it
-- points down, every duct is crawlable end to end, an entry point snaps onto the rail, and a long random crawl
-- with grates shut and open keeps every invariant (on the rail, outside keep-outs, within speed, no jumps).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local VentShaftBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.VentShaftBuilder)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

local Controllers = StarterPlayer.StarterPlayerScripts.Controllers
local VentController = require(Controllers.Gameplay.VentController)
local MovementController = require(Controllers.FirstPerson.FirstPersonController.MovementController)

type Expect = SpecRunner.Expect
type Cursor = VentController.Cursor
type Rail = VentController.Rail
type Layout = LayoutSchema.LevelLayout

local ORIGIN = Vector3.new(120, 31.5, -48)
local MOUTH = VentGraph.MouthOut
local SHUT_STOP = 0.9
local X = Vector3.xAxis
local Z = Vector3.zAxis
local NONE = Vector3.zero
local DT = 1 / 60
local EPS = 1e-4 -- Vector3 is float32: positions near world coordinates of a few hundred studs carry ~3e-5 of error

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

local function at(x: number, z: number): Vector3
	return ORIGIN + Vector3.new(x, 0, z)
end

local function node(id: string, x: number, z: number, links: { string }, grateId: string?): VentGraph.Node
	return { id = id, position = at(x, z), links = links, grateId = grateId }
end

local function grate(id: string, nodeId: string, x: number, z: number, look: Vector3): VentGraph.Grate
	local position = at(x, z)
	return {
		id = id,
		nodeId = nodeId,
		facingZoneId = "Room",
		lockable = false,
		criticalPath = false,
		wall = CFrame.lookAt(position, position + look),
		mouth = position + look * MOUTH,
	}
end

--           NW ---- N ---- NE          N: a T (stem toward J)
--                   |
--   W2 ---- W ----- J ----- E ]GE      J: a cross; W: a straight joint; E: an open grate facing +X
--                   |
--                   S ---- C ---- K ]GK     S: a bend; C: a straight joint; K: a shut grate facing +X
local function network(): VentGraph.Graph
	local nodes: { [string]: VentGraph.Node } = {
		J = node("J", 0, 0, { "E", "N", "S", "W" }),
		N = node("N", 0, -10, { "J", "NE", "NW" }),
		NW = node("NW", -6, -10, { "N" }),
		NE = node("NE", 6, -10, { "N" }),
		W = node("W", -10, 0, { "J", "W2" }),
		W2 = node("W2", -20, 0, { "W" }),
		E = node("E", 10, 0, { "J" }, "GE"),
		S = node("S", 0, 10, { "C", "J" }),
		C = node("C", 8, 10, { "K", "S" }),
		K = node("K", 16, 10, { "C" }, "GK"),
	}
	local segments: { [string]: string } = {}
	for id, entry in nodes do
		for _, other in entry.links do
			segments[id .. "|" .. other] = if id < other then id .. "-" .. other else other .. "-" .. id
		end
	end
	return {
		levelId = "Level1_Hallways",
		nodes = nodes,
		grates = { GE = grate("GE", "E", 10, 0, X), GK = grate("GK", "K", 16, 10, X) },
		grateAtNode = { E = "GE", K = "GK" },
		segments = segments,
	}
end

local function railFor(graph: VentGraph.Graph, open: { [string]: boolean }, stop: number?): Rail
	return {
		graph = graph,
		passable = function(grateId: string): boolean
			return open[grateId] == true
		end,
		stopShort = function(_grateId: string): number
			return stop or SHUT_STOP
		end,
	}
end

local function cursor(a: string, b: string?, t: number): Cursor
	return { a = a, b = b, t = t }
end

local function positionOf(rail: Rail, c: Cursor): Vector3
	local position = VentController.position(rail.graph, c)
	assert(position, "cursor off the graph")
	return position
end

local function vecNear(a: Vector3, b: Vector3, epsilon: number): boolean
	return (a - b).Magnitude <= epsilon
end

local function flatDir(degrees: number): Vector3
	local r = math.rad(degrees)
	return Vector3.new(math.cos(r), 0, math.sin(r))
end

local function sameEdge(c: Cursor, a: string, b: string?): boolean
	return c.a == a and c.b == b
end

--------------------------------------------------------------------------------
-- Real levels
--------------------------------------------------------------------------------

local function realLayouts(): { Layout }
	local out: { Layout } = {}
	local folder = ReplicatedStorage.Shared.World.ProceduralWorldBuilder:FindFirstChild("Layouts")
	if not folder then
		return out
	end
	for _, id: Enums.LayoutId in Enums.LayoutId do
		local module = folder:FindFirstChild(id)
		if module and module:IsA("ModuleScript") then
			local layout = (require(module) :: any) :: Layout
			if layout.vents and #layout.vents.edges > 0 then
				table.insert(out, layout)
			end
		end
	end
	return out
end

local builtGraphs: { VentGraph.Graph }? = nil

-- Every real level's ducts, built the way the world builds them and read back through VentGraph.
local function realGraphs(t: Expect): { VentGraph.Graph }
	local cached = builtGraphs
	if cached then
		return cached
	end
	local out: { VentGraph.Graph } = {}
	local previous = Geometry.getYieldEvery()
	Geometry.setYieldEvery(0)
	for _, layout in realLayouts() do
		local model = Instance.new("Model")
		model.Name = layout.id
		VentShaftBuilder.build(layout, model)
		local graph = VentGraph.build(model, layout.id)
		t.truthy(graph, layout.id .. ": no graph")
		if graph then
			table.insert(out, graph)
		end
	end
	Geometry.setYieldEvery(previous)
	t.truthy(#out >= 3, "the levels with ducts")
	builtGraphs = out
	return out
end

local function sortedNodeIds(graph: VentGraph.Graph): { string }
	local ids: { string } = {}
	for id in graph.nodes do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

local function sortedGrateIds(graph: VentGraph.Graph): { string }
	local ids: { string } = {}
	for id in graph.grates do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

local function wayLength(rail: Rail, way: VentController.Way): number
	local from, to = VentController.span(rail.graph, { a = way.a, b = way.b, t = 0 })
	return if from and to then (to - from).Magnitude else 0
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["input -> travel: along the duct, backward allowed, nothing into a wall, strength from the stick"] = function(
		t: Expect
	)
		local rail = railFor(network(), { GE = true })
		local mid = cursor("J", "E", 0.5)
		local heading, strength = VentController.travel(rail, mid, X)
		t.eq(heading, 1, "forward")
		t.near(strength, 1, EPS)
		heading, strength = VentController.travel(rail, mid, -X)
		t.eq(heading, -1, "backward allowed")
		t.near(strength, 1, EPS)
		heading = VentController.travel(rail, mid, Z)
		t.eq(heading, 0, "into the duct wall")
		heading = VentController.travel(rail, mid, X * 0.05)
		t.eq(heading, 0, "inside the dead zone")
		heading, strength = VentController.travel(rail, mid, X * 0.5)
		t.eq(heading, 1)
		t.near(strength, 0.5, EPS, "half a stick, half the speed")
		heading, strength = VentController.travel(rail, mid, flatDir(45))
		t.eq(heading, 1, "a diagonal crawls along the duct")
		t.near(strength, 1, EPS, "at full speed")
		heading = VentController.travel(rail, mid, flatDir(82))
		t.eq(heading, 0, "nearly across the duct: below MIN_TRAVEL_DOT")
		heading, strength = VentController.travel(rail, mid, flatDir(72))
		t.eq(heading, 1)
		t.truthy(strength > 0 and strength < 1, "eases in between the thresholds")
		local _, slow = VentController.travel(rail, mid, flatDir(76))
		t.truthy(slow < strength, "the further off the duct, the slower")
	end,

	["input -> travel: a junction within reach offers its branches; bends are rounded"] = function(t: Expect)
		local rail = railFor(network(), { GE = true })
		local nearJ = cursor("J", "E", 0.1) -- one stud from the cross
		t.eq((VentController.travel(rail, nearJ, Z)), -1, "looking down S: back to the cross first")
		t.eq((VentController.travel(rail, nearJ, -Z)), -1, "looking down N")
		t.eq((VentController.travel(rail, cursor("J", "E", 0.5), Z)), 0, "five studs out the branch is out of reach")
		local nearStub = cursor("J", "E", 0.95)
		t.eq((VentController.travel(rail, nearStub, X)), 1, "on toward the open grate")

		-- The bend at S: the tangent turns halfway at the node, continuously.
		local before = VentController.tangent(rail, cursor("J", "S", 1), 1)
		local after = VentController.tangent(rail, cursor("S", "C", 0), 1)
		t.truthy(vecNear(before, after, EPS), "continuous across the bend")
		t.truthy(vecNear(before, (X + Z).Unit, EPS), "halfway round at the node")
		t.truthy(vecNear(VentController.tangent(rail, cursor("J", "S", 0.5), 1), Z, EPS), "straight away from the bend")
		local heading, strength = VentController.travel(rail, cursor("S", "C", 0.5 / 8), Z)
		t.eq(heading, 1, "half a stud past the bend, still looking the old way: carried on round it")
		t.near(strength, 1, EPS)
		t.eq((VentController.travel(rail, cursor("S", "C", 1.6 / 8), Z)), 0, "then it is a wall")
		t.eq((VentController.travel(rail, cursor("J", "S", 0.95), X)), 1, "looking into the bend: on to it")

		-- No rounding toward a junction or a dead end, nor at a shut grate.
		t.truthy(vecNear(VentController.tangent(rail, cursor("W", "J", 0.95), 1), X, EPS), "into the cross")
		t.truthy(vecNear(VentController.tangent(rail, cursor("J", "N", 0.95), 1), -Z, EPS), "into the T")
		t.truthy(vecNear(VentController.tangent(rail, cursor("C", "K", 0.95), 1), X, EPS), "into the shut grate")
	end,

	["input -> travel: the heading already moving wins a tie"] = function(t: Expect)
		local rail = railFor(network(), { GE = true })
		local atJ = cursor("J", "E", 0) -- on the cross; +X along J-E ties with the S branch at 45 degrees
		local input = flatDir(45)
		t.eq((VentController.travel(rail, atJ, input, 1)), 1, "keeps going east")
		t.eq((VentController.travel(rail, atJ, input, -1)), -1, "keeps turning south")
		t.eq((VentController.travel(rail, atJ, input)), 1, "deterministic from rest")
	end,

	["branch choice at junctions"] = function(t: Expect)
		local rail = railFor(network(), { GE = true })
		local function waysAt(nodeId: string, except: string?): { VentController.Way }
			local out: { VentController.Way } = {}
			for _, way in VentController.ways(rail, nodeId) do
				if way.b ~= except then
					table.insert(out, way)
				end
			end
			return out
		end
		local fromW = waysAt("J", "W")
		local function pick(input: Vector3, arrival: Vector3?): string?
			local way = VentController.chooseBranch(fromW, input, arrival)
			return if way then way.b else nil
		end
		t.eq(pick(Z, X), "S", "the branch the input points down")
		t.eq(pick(X, X), "E", "straight on")
		t.eq(pick(-Z, X), "N")
		t.eq(pick(-X, X), nil, "back the way we came is not on offer: stop")
		t.eq(pick(flatDir(186), X), nil, "nearly back, only grazing the N branch: stop")
		t.eq(pick(flatDir(194), X), "N", "aligned enough with N")
		t.eq(pick(NONE, X), nil, "no input at a junction: stop there")

		local bend = waysAt("S", "J")
		t.eq(#bend, 1)
		local follow = VentController.chooseBranch(bend, NONE, Z)
		t.truthy(follow and follow.b == "C", "one way on is followed round the bend")
		t.eq(VentController.chooseBranch(bend, NONE, nil), nil, "but not chosen from a standstill without input")
		local chosen = VentController.chooseBranch(bend, X, nil)
		t.truthy(chosen and chosen.b == "C", "from a standstill the input picks it")

		local shut = waysAt("K", "C")
		t.eq(#shut, 1, "the shut grate's stub is a way out")
		t.truthy(shut[1].blocked and shut[1].b == nil, "blocked")
		t.eq(VentController.chooseBranch(shut, X, X), nil, "never taken")
		local open = waysAt("E", "J")
		local out = VentController.chooseBranch(open, X, X)
		t.truthy(out and out.b == nil and not out.blocked, "an open grate's stub is followed toward the room")
	end,

	["cursor advance across edges, junctions and bends"] = function(t: Expect)
		local rail = railFor(network(), { GE = true })
		local step = VentController.advance(rail, cursor("J", "E", 0), 1, 2, X)
		t.truthy(sameEdge(step.cursor, "J", "E"), "same duct")
		t.near(step.cursor.t, 0.2, EPS)
		t.near(step.travelled, 2, EPS)
		t.eq(step.stopped, nil)
		t.eq(step.turned, 0)

		step = VentController.advance(rail, cursor("W", "J", 0.9), 1, 3, X)
		t.truthy(sameEdge(step.cursor, "J", "E"), "straight through the cross")
		t.near(step.cursor.t, 0.2, EPS)
		t.near(step.travelled, 3, EPS)
		t.near(step.turned, 0, EPS)

		step = VentController.advance(rail, cursor("W", "J", 0.9), 1, 3, Z)
		t.truthy(sameEdge(step.cursor, "J", "S"), "into the branch the input points down")
		t.near(step.cursor.t, 0.2, EPS)
		t.near(step.turned, math.pi / 2, EPS)
		t.eq(step.heading, 1, "a new duct runs away from the node it was entered at")

		step = VentController.advance(rail, cursor("J", "N", 0.95), 1, 3, -Z)
		t.eq(step.stopped, "Junction", "looking at the wall of a T: stop at it")
		t.near(step.travelled, 0.5, EPS)
		t.truthy(vecNear(positionOf(rail, step.cursor), at(0, -10), EPS), "on the node")
		step = VentController.advance(rail, cursor("J", "N", 0.95), 1, 3, -X)
		t.truthy(sameEdge(step.cursor, "N", "NW"), "look left, go left")
		t.near(step.cursor.t, 2.5 / 6, EPS)

		step = VentController.advance(rail, cursor("N", "NW", 0), 1, 20, -X)
		t.eq(step.stopped, "DeadEnd")
		t.near(step.cursor.t, 1, EPS)
		t.near(step.travelled, 6, EPS)

		step = VentController.advance(rail, cursor("J", "S", 0.9), 1, 3, Z)
		t.truthy(sameEdge(step.cursor, "S", "C"), "the bend is followed")
		t.near(step.cursor.t, 2 / 8, EPS)
		t.near(step.turned, math.pi / 2, EPS)

		step = VentController.advance(rail, cursor("S", "C", 0.5), 1, 6, X)
		t.truthy(sameEdge(step.cursor, "C", "K"), "through the straight joint")
		t.near(step.cursor.t, 2 / 8, EPS)
		t.near(step.turned, 0, EPS)

		step = VentController.advance(rail, cursor("J", "E", 0), -1, 0, Z)
		t.truthy(sameEdge(step.cursor, "J", "E") and step.cursor.t == 0, "zero distance never crosses a node")
		t.eq(step.travelled, 0)
		step = VentController.advance(rail, cursor("J", "E", 0.5), 1, 0 / 0, X)
		t.eq(step.travelled, 0, "NaN distance moves nothing")
	end,

	["cursor advance: shut grates stop the ball short, open grates carry it out to the mouth"] = function(t: Expect)
		local rail = railFor(network(), { GE = true })
		local step = VentController.advance(rail, cursor("C", "K", 0), 1, 100, X)
		t.eq(step.stopped, "Blocked")
		t.near(step.travelled, 8 - SHUT_STOP, EPS)
		t.near(positionOf(rail, step.cursor).X, at(16 - SHUT_STOP, 10).X, EPS, "stopShort before the grate")
		step = VentController.advance(rail, cursor("C", "K", 0.95), 1, 1, X)
		t.eq(step.stopped, "Blocked", "already inside the keep-out: no further")
		t.eq(step.travelled, 0)
		step = VentController.advance(rail, cursor("K", nil, 0), 1, 1, X)
		t.eq(step.stopped, "Blocked", "never out along a shut stub")
		t.eq(step.travelled, 0)

		local flush = railFor(network(), { GE = true }, 0)
		step = VentController.advance(flush, cursor("C", "K", 0), 1, 100, X)
		t.eq(step.stopped, "Blocked", "a panel far out still blocks at the node")
		t.near(step.travelled, 8, EPS)

		step = VentController.advance(rail, cursor("J", "E", 0.5), 1, 20, X)
		t.eq(step.stopped, "Mouth", "out along the open grate's stub")
		t.truthy(step.cursor.a == "E" and step.cursor.b == nil, "on the stub")
		t.near(step.cursor.t, 1, EPS)
		t.near(step.travelled, 5 + MOUTH, EPS)
		t.truthy(vecNear(positionOf(rail, step.cursor), at(10, 0) + X * MOUTH, EPS), "at the mouth")
		t.truthy(
			(positionOf(rail, step.cursor) - at(10, 0)):Dot(X) >= WorldConfig.WallThickness / 2 - 0.1,
			"past the room face, where the server's exit fires"
		)

		step = VentController.advance(rail, cursor("E", nil, 1), -1, 2, -X)
		t.truthy(sameEdge(step.cursor, "E", "J"), "back off the stub into the duct")
		t.near(step.cursor.t, (2 - MOUTH) / 10, EPS)
		t.near(step.travelled, 2, EPS)
	end,

	["a grate that shuts on the crawler pushes the cursor out of its keep-out"] = function(t: Expect)
		local rail = railFor(network(), { GE = true })
		local depth, away = VentController.encroachment(rail, cursor("C", "K", 1))
		t.near(depth, SHUT_STOP, EPS)
		t.eq(away, -1)
		depth = VentController.encroachment(rail, cursor("C", "K", 0.95))
		t.near(depth, SHUT_STOP - 0.4, EPS)
		t.eq((VentController.encroachment(rail, cursor("C", "K", 0.5))), 0, "clear of it")
		t.eq((VentController.encroachment(rail, cursor("J", "E", 1))), 0, "an open grate keeps nobody out")
		depth, away = VentController.encroachment(rail, cursor("K", nil, 0.5))
		t.near(depth, 0.5 * MOUTH + SHUT_STOP, EPS, "on the shut stub")
		t.eq(away, -1)
		local back = VentController.advance(rail, cursor("K", nil, 0.5), away, depth, NONE)
		t.truthy(sameEdge(back.cursor, "K", "C"), "retreats into the duct")
		t.near(positionOf(rail, back.cursor).X, at(16 - SHUT_STOP, 10).X, EPS)
		t.near((VentController.encroachment(rail, back.cursor)), 0, EPS, "and is clear")
		local reversed = VentController.encroachment(rail, cursor("K", "C", 0))
		t.near(reversed, SHUT_STOP, EPS, "either orientation of the duct")
		t.eq(select(2, VentController.encroachment(rail, cursor("K", "C", 0))), 1)
	end,

	["panel stops keep the ball off the louvres"] = function(t: Expect)
		local radius = VentController.BallRadius
		local margin = VentController.PanelMargin
		t.near(VentController.panelStop(nil), margin + radius - WorldConfig.WallThickness / 2, 1e-9, "unmeasured")
		t.near(VentController.panelStop(-0.6), margin + 0.6, 1e-9, "the ball touched 0.6 behind the node")
		t.eq(VentController.panelStop(0.5), 0, "a panel out past the ball's reach")
		t.near(VentController.panelStop(0 / 0), VentController.panelStop(nil), 1e-9)
		local typical = VentController.panelStop(WorldConfig.WallThickness / 2 + 0.085 - radius)
		t.truthy(typical > 0.6 and typical < 0.9, "a wall grate stops the root ~0.8 behind its centre plane")
	end,

	["facing: the duct direction nearest the look, held against side glances"] = function(t: Expect)
		local rail = railFor(network(), { GE = true })
		local mid = cursor("J", "E", 0.5)
		t.truthy(vecNear(VentController.chooseFacing(rail, mid, X, nil), X, EPS))
		t.truthy(vecNear(VentController.chooseFacing(rail, mid, -X, X), -X, EPS), "looking right back turns round")
		t.truthy(vecNear(VentController.chooseFacing(rail, mid, Z, X), X, EPS), "a side glance keeps it")
		t.truthy(vecNear(VentController.chooseFacing(rail, mid, Z, -X), -X, EPS))
		t.truthy(vecNear(VentController.chooseFacing(rail, mid, flatDir(100), X), X, EPS), "100 degrees: held")
		t.truthy(vecNear(VentController.chooseFacing(rail, mid, flatDir(125), X), -X, EPS), "125 degrees: turns")
		local corner = VentController.chooseFacing(rail, cursor("S", "C", 0), Z, Z)
		t.truthy(vecNear(corner, (X + Z).Unit, EPS), "halfway round the bend at its node")
		t.truthy(
			vecNear(VentController.chooseFacing(rail, cursor("S", "C", 0.5), Z, corner), X, EPS),
			"then along the new duct"
		)
	end,

	["facing smoothing: eased, rate-limited, the short way round"] = function(t: Expect)
		local yaw = 0
		local target = math.pi / 2
		local last = math.huge
		for _ = 1, 120 do
			local nextYaw = VentController.smoothYaw(yaw, target, DT)
			t.truthy(math.abs(nextYaw - yaw) <= VentController.MaxTurnRate * DT + 1e-9, "rate-limited")
			local remaining = math.abs(MathUtil.angleDelta(nextYaw, target))
			t.truthy(remaining <= last + 1e-12, "never overshoots or backs off")
			last = remaining
			yaw = nextYaw
		end
		t.near(yaw, target, 1e-3, "arrives")
		local corner = 0
		for _ = 1, math.round(0.35 / DT) do
			corner = VentController.smoothYaw(corner, math.pi / 2, DT)
		end
		t.truthy(math.abs(MathUtil.angleDelta(corner, math.pi / 2)) < math.rad(6), "a corner turns in about 0.3 s")

		local across = VentController.smoothYaw(3, -3, DT)
		t.truthy(across > 3 or across < -3, "3 -> -3 goes through pi, not through zero")
		local fine, coarse = 0, 0
		for _ = 1, 60 do
			fine = VentController.smoothYaw(fine, 1.2, 1 / 60)
		end
		for _ = 1, 30 do
			coarse = VentController.smoothYaw(coarse, 1.2, 1 / 30)
		end
		t.near(fine, coarse, 0.05, "frame-rate independent")
		t.near(VentController.smoothYaw(0.7, 0.7, DT), 0.7, 1e-12, "settled stays settled")
		t.near(VentController.smoothYaw(0.4, 1, 0), 0.4, 1e-12, "no time, no turn")
	end,

	["rail speed: eases in and out, brakes before reversing, never above the state's speed"] = function(t: Expect)
		local top = GameConfig.VentCrawlSpeed
		local speed, heading = 0, 1
		local frames = 0
		while speed < top - 1e-9 and frames < 600 do
			local reversed: boolean
			speed, heading, reversed = VentController.stepSpeed(speed, heading, 1, top, top, DT)
			t.falsy(reversed)
			t.truthy(speed <= top + 1e-9, "never above WalkSpeed")
			frames += 1
		end
		t.near(frames * DT, VentController.AccelTime, DT + 1e-9, "full speed in AccelTime")
		local coast = 0
		while speed > 0 and coast < 600 do
			speed, heading = VentController.stepSpeed(speed, heading, 0, 0, top, DT)
			coast += 1
		end
		t.near(coast * DT, VentController.DecelTime, DT + 1e-9, "stops in DecelTime")
		t.eq(heading, 1, "coasting keeps its heading")

		speed, heading = top, 1
		local flips = 0
		local wrong = 0
		for _ = 1, 60 do
			local reversed: boolean
			local before = heading
			speed, heading, reversed = VentController.stepSpeed(speed, heading, -1, top, top, DT)
			if reversed then
				flips += 1
				t.eq(before, 1)
				t.eq(speed, 0, "turns round from a standstill")
			end
			if heading == 1 and speed <= 1e-3 then
				wrong += 1
			end
		end
		t.eq(flips, 1, "one reversal")
		t.eq(heading, -1)
		t.near(speed, top, 1e-9, "back up to speed the other way")
		t.eq(wrong, 0)
		speed = VentController.stepSpeed(0, 1, 1, 50, top, 1)
		t.near(speed, top, 1e-9, "a request above the state's speed is capped")
		t.eq((VentController.stepSpeed(2, 1, 1, 0, 0, DT)) < 2, true, "a held state (speed 0) stops")
	end,

	["membership: in on a vent state, held through duct overrides and locks, out on foot or dead"] = function(
		t: Expect
	)
		local function decide(
			engaged: boolean,
			moveState: string,
			collider: VentController.ColliderMode,
			locked: boolean?,
			alive: boolean?
		): VentController.Membership
			return VentController.membership({
				engaged = engaged,
				alive = alive ~= false,
				moveState = moveState,
				collider = collider,
				locked = locked == true,
			})
		end
		t.eq(decide(false, "Standing", "Normal"), "Idle")
		t.eq(decide(false, "VentCrawling", "Vent"), "Engage")
		t.eq(decide(false, "VentScurrying", "Normal"), "Engage", "the MoveState is enough to start")
		t.eq(decide(false, "DownedCrawling", "Vent"), "Idle", "an override never starts a crawl")
		t.eq(decide(false, "VentCrawling", "Vent", false, false), "Idle", "the dead do not crawl")
		t.eq(decide(true, "VentCrawling", "Vent"), "Drive")
		t.eq(decide(true, "VentScurrying", "Normal"), "Drive", "collision still catching up")
		t.eq(decide(true, "VentCrawling", "Vent", true), "Hold", "a ControlLock / anchored root")
		t.eq(decide(true, "VentCrawling", "Locked"), "Hold", "Locked collision")
		t.eq(decide(true, "DownedCrawling", "Vent"), "Drive", "downed in a duct: drag along the rail")
		t.eq(decide(true, "Grabbed", "Locked", true), "Hold")
		t.eq(decide(true, "DownedCrawling", "Normal"), "Release", "the server took us out")
		t.eq(decide(true, "Standing", "Vent"), "Release", "the server's MoveState left the duct")
		t.eq(decide(true, "Crouching", "Normal"), "Release")
		t.eq(decide(true, "Treading", "Vent"), "Release")
		t.eq(decide(true, "VentCrawling", "Vent", false, false), "Release", "death")

		t.eq(VentController.colliderMode(CollisionGroups.VentCollider, CollisionGroups.NoCollide), "Vent")
		t.eq(VentController.colliderMode(CollisionGroups.NoCollide, CollisionGroups.NoCollide), "Locked")
		t.eq(VentController.colliderMode(CollisionGroups.NoCollide, CollisionGroups.Players), "Normal")
		t.eq(VentController.colliderMode(nil, CollisionGroups.NoCollide), "Vent", "no ball: NoCollide reads as Vent")
		t.eq(VentController.colliderMode(nil, CollisionGroups.Players), "Normal")
	end,

	["server moves: corrections re-snap, an exit teleport holds, our own motion is ignored"] = function(t: Expect)
		local jump = VentController.JumpDistance
		t.eq(VentController.serverMove(0.2, 0.1, 0), "None", "a frame of crawling")
		t.eq(VentController.serverMove(jump + 1, 0.3, 0), "None", "the body caught up with the cursor")
		t.eq(VentController.serverMove(jump + 3, jump + 3, 0), "Resnap", "put back on the rail")
		t.eq(VentController.serverMove(jump + 3, jump + 3, VentController.OnRail), "Resnap")
		t.eq(VentController.serverMove(jump + 3, jump + 3, VentController.OnRail + 0.01), "Hold", "off the rail")
		t.eq(VentController.serverMove(jump + 3, jump + 3, nil), "Hold", "nowhere near a duct")
	end,

	["crawl speeds match MovementController; loops, vignette and hand plants"] = function(t: Expect)
		local crawlStates: { Enums.MoveState } = { "VentCrawling", "VentScurrying", "DownedCrawling" }
		for _, state: Enums.MoveState in crawlStates do
			t.eq(VentController.crawlSpeed(state), MovementController.speedFor(state), state)
		end
		local holdStates: { Enums.MoveState } = { "Grabbed", "Trapped", "Hiding", "Scripted" }
		for _, state: Enums.MoveState in holdStates do
			t.eq(VentController.crawlSpeed(state), 0, state)
			t.eq(MovementController.speedFor(state), 0, state)
		end

		t.eq(VentController.crawlVolume(0, false), 0, "silent at rest")
		t.eq(VentController.crawlVolume(0, true), 0)
		local last = 0
		for step = 1, 10 do
			local volume = VentController.crawlVolume(step * 0.5, false)
			t.truthy(volume >= last, "rises with speed")
			last = volume
		end
		t.truthy(
			VentController.crawlVolume(GameConfig.VentScurrySpeed, true)
				> VentController.crawlVolume(GameConfig.VentCrawlSpeed, false),
			"scurrying is louder"
		)

		local closed = VentController.vignette(0, 1)
		t.eq(closed, 0, "outside: no vignette")
		local opacity, depth = VentController.vignette(1, 0)
		local scurryOpacity, scurryDepth = VentController.vignette(1, 1)
		t.truthy(opacity > 0.5 and opacity < 1, "dark, not black")
		t.truthy(scurryOpacity > opacity and scurryDepth > depth, "scurrying narrows it")
		t.truthy(scurryOpacity <= 1 and depth > 0)

		t.truthy(VentController.plantCrossed(0.9, 0.05), "through 0: the left hand")
		t.truthy(VentController.plantCrossed(0.45, 0.55), "through 0.5: the right hand")
		t.falsy(VentController.plantCrossed(0.1, 0.4), "between plants")
		t.falsy(VentController.plantCrossed(0.2, 0.9), "half a cycle or more is a reset")
		t.falsy(VentController.plantCrossed(0.3, 0.3), "still")

		local passable: { Enums.GrateState } = { "Open", "Kicked" }
		local shut: { Enums.GrateState } = { "Closed", "Unscrewing", "Locked" }
		for _, state: Enums.GrateState in passable do
			t.truthy(VentController.isPassable(state), state)
		end
		for _, state: Enums.GrateState in shut do
			t.falsy(VentController.isPassable(state), state)
		end
		t.falsy(VentController.isPassable(nil))
	end,

	["rail points snap the cursor whatever their t means"] = function(t: Expect)
		local graph = network()
		local point: VentGraph.RailPoint = { a = "J", b = "E", t = 7.5, position = at(7.5, 0), distance = 0.2 }
		local snapped = VentController.fromRailPoint(graph, point)
		t.truthy(sameEdge(snapped, "J", "E"))
		t.near(snapped.t, 0.75, EPS, "fraction recomputed from the position")
		local stub = VentController.fromRailPoint(
			graph,
			{ a = "E", b = nil, t = 0.5, position = at(10, 0) + X * (MOUTH / 2), distance = 0 }
		)
		t.truthy(stub.a == "E" and stub.b == nil)
		t.near(stub.t, 0.5, EPS)
		t.eq(VentController.position(graph, cursor("J", "nowhere", 0.5)), nil, "a cursor off the graph has no position")
	end,

	["real levels: from any duct at any node the input takes the branch it points down"] = function(t: Expect)
		for _, graph in realGraphs(t) do
			local open: { [string]: boolean } = {}
			for id in graph.grates do
				open[id] = true
			end
			local rail = railFor(graph, open, 0.9)
			local checked = 0
			for _, nodeId in sortedNodeIds(graph) do
				local ways = VentController.ways(rail, nodeId)
				for _, from in ways do
					for _, to in ways do
						if from == to or wayLength(rail, to) < 0.75 then
							continue
						end
						-- Crawling in along `from`, a stud out from the node, the input pointing down `to`.
						local distance = math.min(1, wayLength(rail, from))
						local start: Cursor = { a = nodeId, b = from.b, t = distance / wayLength(rail, from) }
						local heading, strength = VentController.travel(rail, start, to.direction, -1)
						local where =
							string.format("%s: %s -> %s at %s", graph.levelId, tostring(from.b), tostring(to.b), nodeId)
						t.eq(heading, -1, where .. ": heads for the node")
						t.near(strength, 1, EPS, where)
						local step = VentController.advance(rail, start, heading, distance + 0.5, to.direction)
						t.truthy(
							step.cursor.a == nodeId and step.cursor.b == to.b,
							where .. ": ends on the branch, got " .. step.cursor.a .. "-" .. tostring(step.cursor.b)
						)
						t.near(step.travelled, distance + 0.5, EPS, where .. ": without stopping")
						checked += 1
					end
				end
			end
			t.truthy(checked > 0, graph.levelId .. ": junctions checked")
		end
	end,

	["real levels: every duct crawls end to end; entry points snap onto the rail"] = function(t: Expect)
		for _, graph in realGraphs(t) do
			local open: { [string]: boolean } = {}
			for id in graph.grates do
				open[id] = true
			end
			local rail = railFor(graph, open, 0.9)
			for _, nodeId in sortedNodeIds(graph) do
				for _, way in VentController.ways(rail, nodeId) do
					local length = wayLength(rail, way)
					local start: Cursor = { a = nodeId, b = way.b, t = 0 }
					local heading = VentController.travel(rail, start, way.direction)
					t.eq(heading, 1, graph.levelId .. " " .. nodeId .. ": along the duct")
					local step = VentController.advance(rail, start, 1, length * 0.999, way.direction)
					t.near(step.travelled, length * 0.999, EPS, graph.levelId .. " " .. nodeId .. ": end to end")
					t.eq(step.stopped, nil)
				end
			end
			for _, grateId in sortedGrateIds(graph) do
				local entry = graph.grates[grateId]
				local inside = entry.wall.Position - entry.wall.LookVector * 1.0
				local point = VentGraph.nearest(graph, inside, VentController.OnRail)
				t.truthy(point, grateId .. ": the entry point is on the rail")
				if point then
					local snapped = VentController.fromRailPoint(graph, point)
					local position = VentController.position(graph, snapped)
					t.truthy(position and vecNear(position, inside, 1e-3), grateId .. ": the cursor lands there")
				end
			end
		end
	end,

	["real levels: a long random crawl keeps every invariant"] = function(t: Expect)
		for index, graph in realGraphs(t) do
			local open: { [string]: boolean } = {}
			for position, id in sortedGrateIds(graph) do
				open[id] = position % 2 == 0
			end
			local rail = railFor(graph, open, 0.9)
			local random = Random.new(9100 + index)
			local ids = sortedNodeIds(graph)
			local startNode = ids[1]
			local first = VentController.ways(rail, startNode)[1]
			local c: Cursor = { a = startNode, b = first.b, t = 0 }
			if first.blocked then
				c = { a = startNode, b = VentController.ways(rail, startNode)[2].b, t = 0 }
			end
			local speed, heading = 0, 1
			local input = Vector3.zero
			local visited: { [string]: boolean } = {}
			local states: { Enums.MoveState } = { "VentCrawling", "VentScurrying" }
			local state: Enums.MoveState = "VentCrawling"
			for frame = 1, 5400 do
				if frame % 45 == 1 then
					local angle = random:NextInteger(0, 7) * 45
					input = if random:NextNumber() < 0.1 then Vector3.zero else flatDir(angle)
					state = states[random:NextInteger(1, 2)]
				end
				local top = VentController.crawlSpeed(state)
				local before = positionOf(rail, c)
				local previous = speed
				local want, strength = VentController.travel(rail, c, input, if speed > 0 then heading else nil)
				speed, heading = VentController.stepSpeed(speed, heading, want, top * strength, top, DT)
				t.truthy(speed <= math.max(top, previous) + EPS, "never speeds up past the state's speed")
				local step = VentController.advance(rail, c, heading, speed * DT, input)
				t.truthy(step.travelled <= speed * DT + EPS, "never further than asked")
				t.truthy(step.cursor.t >= 0 and step.cursor.t <= 1, "t in range")
				c = step.cursor
				heading = step.heading
				if step.stopped then
					speed = 0
				end
				local after = positionOf(rail, c)
				t.truthy(MathUtil.isFiniteVector(after), "finite")
				t.truthy((after - before).Magnitude <= step.travelled + EPS, "no jumps at nodes")
				t.near(after.Y, before.Y, EPS, "level ducts")
				t.truthy(VentController.encroachment(rail, c) <= EPS, "never inside a shut grate's keep-out")
				if c.b == nil then
					local grateId = graph.grateAtNode[c.a]
					t.truthy(grateId and open[grateId], "only open stubs")
				end
				visited[c.a] = true
			end
			-- The nodes a crawl from the start can reach (a shut grate's node is never crossed).
			local reachable: { [string]: boolean } = { [startNode] = true }
			local queue: { string } = { startNode }
			while #queue > 0 do
				local id = table.remove(queue, 1) :: string
				for _, other in graph.nodes[id].links do
					local grateId = graph.grateAtNode[other]
					if not reachable[other] and (grateId == nil or open[grateId]) then
						reachable[other] = true
						table.insert(queue, other)
					end
				end
			end
			local reach, count = 0, 0
			for id in reachable do
				reach += 1
				if visited[id] then
					count += 1
				end
			end
			for id in visited do
				t.truthy(reachable[id], graph.levelId .. ": " .. id .. " was reachable")
			end
			t.truthy(
				count >= math.max(2, math.ceil(reach * 0.75)),
				string.format("%s: the crawl gets around (%d of %d reachable nodes)", graph.levelId, count, reach)
			)
		end
	end,
}
