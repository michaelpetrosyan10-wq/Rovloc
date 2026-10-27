--!strict
-- LayoutSchema.validate catches broken blueprints before a builder runs: openings that merge on a wall, grate
-- openings through a ceiling, past their wall or into a dry floor, ducts that cross or touch without a shared vent
-- node, duplicate ducts, and anchors or triggers outside their room's volume. Each case starts from a small valid
-- layout (a hall, a service chase, a classroom and a pool hall with a basin; a dry low duct plus a flooded duct
-- sunk to the waterline) and breaks one thing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Layout = LayoutSchema.LevelLayout
type VentNetwork = LayoutSchema.VentNetwork

local R = LayoutSchema.rect
local WATER = -1
local HALF_BORE = WorldConfig.VentBore / 2

-- S_Hall (z 0..14) | S_Chase (z 14..19) | S_Room (x 0..30) and S_Pool (x 30..60, basin x 36..60) below it.
-- A dry duct joins the hall and the classroom; a flooded duct at the waterline opens over the basin.
local function base(): Layout
	return {
		id = "Lobby", -- not a school level: no footprint tiling or stairwell vestibules needed
		height = 12,
		acoustic = "Room",
		ambience = "DroneLobby",
		entry = "S_Room",
		exit = "S_Pool",
		rooms = {
			{ id = "S_Hall", kind = "Corridor", rect = R(0, 0, 60, 14) },
			{ id = "S_Chase", kind = "Chase", rect = R(0, 14, 60, 5) },
			{ id = "S_Room", kind = "Classroom", rect = R(0, 19, 30, 30) },
			{ id = "S_Pool", kind = "Pool", rect = R(30, 19, 30, 30), height = 20 },
		},
		doors = {
			{ id = "S_Door", kind = "Door", rooms = { "S_Room", "S_Pool" }, at = 40 },
		},
		basins = {
			{ id = "S_Basin", room = "S_Pool", rect = R(36, 19, 24, 30), depth = 8, waterLevel = WATER },
		},
		vents = {
			nodes = {
				{ id = "gHall", x = 10, z = 14 },
				{ id = "j1", x = 10, z = 16.5 },
				{ id = "j2", x = 20, z = 16.5 },
				{ id = "gRoom", x = 20, z = 19 },
				{ id = "j3", x = 45, z = 16.5, y = WATER },
				{ id = "gPool", x = 45, z = 19, y = WATER },
				{ id = "jEnd", x = 55, z = 16.5, y = WATER },
			},
			edges = {
				{ a = "gHall", b = "j1" },
				{ a = "j1", b = "j2" },
				{ a = "j2", b = "gRoom" },
				{ a = "j3", b = "gPool", submerged = true },
				{ a = "j3", b = "jEnd", submerged = true },
			},
			grates = {
				{ id = "G_Hall", node = "gHall", room = "S_Hall", lockable = false, criticalPath = false },
				{ id = "G_Room", node = "gRoom", room = "S_Room", lockable = true, criticalPath = false },
				{ id = "G_Pool", node = "gPool", room = "S_Pool", lockable = false, criticalPath = true },
			},
		},
		anchors = {
			{ id = "A_Spawn", kind = "PlayerSpawn", room = "S_Room", pos = Vector3.new(10, 3.5, 30) },
			{ id = "A_Deep", kind = "CreatureSpawn", room = "S_Pool", pos = Vector3.new(48, WATER - 4, 34) },
		},
		triggers = {
			-- the flooded half of the sunken duct's bore
			{
				id = "T_DuctWater",
				kind = "PoolWater",
				room = "S_Chase",
				rect = R(45 - HALF_BORE, 16.5 - HALF_BORE, 10 + 2 * HALF_BORE, 19 - (16.5 - HALF_BORE)),
				height = HALF_BORE,
				y = WATER - HALF_BORE,
			},
			{ id = "T_Glass", kind = "ScareStep", room = "S_Room", rect = R(4, 30, 6, 6), height = 4 },
		},
		windows = {},
	}
end

local function ventsOf(layout: Layout): VentNetwork
	local vents = layout.vents
	assert(vents, "the base layout has vents")
	return vents
end

local function setNode(layout: Layout, id: string, x: number, z: number, y: number?)
	for i, node in ventsOf(layout).nodes do
		if node.id == id then
			ventsOf(layout).nodes[i] = { id = id, x = x, z = z, y = y }
			return
		end
	end
	error("no node " .. id)
end

-- One boarded window, typed (string-literal sides widen inside table literals).
local function window(
	room: string,
	side: LayoutSchema.Side,
	at: number,
	width: number,
	height: number,
	sill: number
): { LayoutSchema.Window }
	return { { room = room, side = side, at = at, width = width, height = height, sill = sill, boarded = true } }
end

-- Number of validation errors containing `fragment` (plain text), and the whole list for messages.
local function matching(layout: Layout, fragment: string): (number, string)
	local errors = LayoutSchema.validate(layout)
	local count = 0
	for _, message in errors do
		if string.find(message, fragment, 1, true) then
			count += 1
		end
	end
	return count, table.concat(errors, " | ")
end

local function expectClean(t: Expect, layout: Layout, what: string)
	local errors = LayoutSchema.validate(layout)
	t.eq(#errors, 0, what .. ": " .. (errors[1] or ""))
end

local function expectError(t: Expect, layout: Layout, fragment: string, what: string)
	local count, all = matching(layout, fragment)
	t.truthy(count >= 1, string.format("%s: expected an error containing %q, got: %s", what, fragment, all))
end

return {
	["the base layout validates"] = function(t: Expect)
		expectClean(t, base(), "base")
	end,

	["openings on one wall keep a pier between them, beside and above"] = function(t: Expect)
		local overlapping = base()
		table.insert(overlapping.doors, { id = "S_Door2", kind = "Door", rooms = { "S_Room", "S_Pool" }, at = 42 })
		expectError(t, overlapping, "S_Door and door S_Door2 overlap", "two doors overlapping on one wall")

		-- a window over the door wall: beside the door with too thin a pier, then with enough
		local thin = base()
		thin.windows = window("S_Room", "E", 43.6, 1, 3, 4)
		expectError(t, thin, "overlap on the wall", "a window 0.1 studs beside a door")
		local beside = base()
		beside.windows = window("S_Room", "E", 44, 1, 3, 4)
		expectClean(t, beside, "a window 0.5 studs beside a door")

		-- above the door: a lintel thinner than the pier merges the openings
		local low = base()
		low.windows = window("S_Room", "E", 40, 4, 1.5, 10.2)
		expectError(t, low, "overlap on the wall", "a window 0.2 studs above a door")
		local high = base()
		high.windows = window("S_Room", "E", 40, 4, 1, 10.6)
		expectClean(t, high, "a window 0.6 studs above a door")

		-- a window cut through a grate opening on the chase wall
		local grate = base()
		grate.windows = window("S_Room", "N", 21, 3, 3, 1)
		expectError(t, grate, "grate G_Room and window of S_Room", "a window over a grate")
	end,

	["windows fit their wall"] = function(t: Expect)
		local layout = base()
		layout.windows = window("S_Room", "W", 1, 4, 3, 4)
		expectError(t, layout, "does not fit the wall", "a window running past the wall's end")
		local tall = base()
		tall.windows = window("S_Room", "W", 30, 4, 4, 9)
		expectError(t, tall, "does not fit the wall", "a window above the wall top")
	end,

	["grate openings fit under a lintel and inside their shared wall"] = function(t: Expect)
		local high = base()
		setNode(high, "j2", 20, 16.5, 10)
		setNode(high, "gRoom", 20, 19, 10)
		setNode(high, "j1", 10, 16.5, 10)
		setNode(high, "gHall", 10, 14, 10)
		expectError(t, high, "lintel", "a grate whose opening reaches the 12-stud ceiling")
		local ok = base()
		setNode(ok, "j1", 10, 16.5, 9)
		setNode(ok, "j2", 20, 16.5, 9)
		setNode(ok, "gRoom", 20, 19, 9)
		setNode(ok, "gHall", 10, 14, 9)
		expectClean(t, ok, "a grate 0.75 under the ceiling")

		-- the opening must stay off the wall meeting the shared stretch (S_Room / S_Chase share x 0..30)
		local past = base()
		setNode(past, "j2", 29, 16.5)
		setNode(past, "gRoom", 29, 19)
		expectError(t, past, "runs past the wall S_Room shares with S_Chase", "a grate opening overrunning its wall")
	end,

	["a grate sinks below the floor only wholly over a pool basin"] = function(t: Expect)
		local dry = base()
		setNode(dry, "j3", 33, 16.5, WATER)
		setNode(dry, "gPool", 33, 19, WATER)
		expectError(t, dry, "sinks below the floor of S_Pool", "a waterline grate over the dry deck")
		local straddle = base()
		setNode(straddle, "j3", 37, 16.5, WATER)
		setNode(straddle, "gPool", 37, 19, WATER)
		expectError(t, straddle, "sinks below the floor of S_Pool", "a waterline grate half over the deck")
		local lowRoom = base()
		setNode(lowRoom, "j2", 20, 16.5, 1)
		setNode(lowRoom, "gRoom", 20, 19, 1)
		setNode(lowRoom, "j1", 10, 16.5, 1)
		setNode(lowRoom, "gHall", 10, 14, 1)
		expectError(t, lowRoom, "sinks below the floor of S_Room", "a classroom grate cut into the floor")
	end,

	["ducts never cross or touch without a shared node"] = function(t: Expect)
		-- a second run alongside the dry duct, half a stud off its centre line
		local parallel = base()
		local vents = ventsOf(parallel)
		table.insert(vents.nodes, { id = "k1", x = 12, z = 17 })
		table.insert(vents.nodes, { id = "k2", x = 18, z = 17 })
		table.insert(vents.edges, { a = "k1", b = "k2" })
		expectError(t, parallel, "cross or touch without a shared vent node", "a duct inside another")

		-- two ducts crossing in a wide chase: an error without a node at the crossing, fine with one
		local function wide(split: boolean): Layout
			local layout = base()
			table.insert(layout.rooms, { id = "W_A", kind = "Storage", rect = R(60, 0, 20, 49) })
			table.insert(layout.rooms, { id = "W_Chase", kind = "Chase", rect = R(80, 0, 40, 49) })
			table.insert(layout.rooms, { id = "W_B", kind = "Storage", rect = R(120, 0, 20, 49) })
			local w = ventsOf(layout)
			for _, node in
				{
					{ id = "n1", x = 80, z = 25 },
					{ id = "n2", x = 120, z = 25 },
					{ id = "m1", x = 100, z = 5 },
					{ id = "m2", x = 100, z = 44 },
				} :: { LayoutSchema.VentNodeSpec }
			do
				table.insert(w.nodes, node)
			end
			if split then
				table.insert(w.nodes, { id = "x", x = 100, z = 25 })
				for _, edge in
					{
						{ a = "n1", b = "x" },
						{ a = "x", b = "n2" },
						{ a = "m1", b = "x" },
						{ a = "x", b = "m2" },
					} :: { LayoutSchema.VentEdgeSpec }
				do
					table.insert(w.edges, edge)
				end
			else
				table.insert(w.edges, { a = "n1", b = "n2" })
				table.insert(w.edges, { a = "m1", b = "m2" })
			end
			table.insert(w.grates, { id = "G_A", node = "n1", room = "W_A", lockable = false, criticalPath = false })
			table.insert(w.grates, { id = "G_B", node = "n2", room = "W_B", lockable = false, criticalPath = false })
			return layout
		end
		expectError(t, wide(false), "duct n1-n2 and duct m1-m2 cross", "two ducts crossing with no node")
		expectClean(t, wide(true), "two ducts crossing at a shared junction")
	end,

	["junctions closer than a box width are fine when linked, branches on one side are not"] = function(t: Expect)
		local function chaseWithBranches(northAt: number, southAt: number, southSide: "N" | "S"): Layout
			local layout = base()
			local vents = ventsOf(layout)
			-- a third duct along the chase's west half: run b1..b2 with two branch grates
			table.insert(vents.nodes, { id = "b1", x = 30, z = 16.5 })
			table.insert(vents.nodes, { id = "b2", x = 38, z = 16.5 })
			table.insert(vents.nodes, { id = "bN", x = northAt, z = 14 })
			table.insert(vents.nodes, { id = "bJN", x = northAt, z = 16.5 })
			table.insert(vents.nodes, { id = "bS", x = southAt, z = if southSide == "N" then 14 else 19 })
			table.insert(vents.nodes, { id = "bJS", x = southAt, z = 16.5 })
			table.insert(vents.edges, { a = "b1", b = "bJN" })
			table.insert(vents.edges, { a = "bJN", b = "bJS" })
			table.insert(vents.edges, { a = "bJS", b = "b2" })
			table.insert(vents.edges, { a = "bJN", b = "bN" })
			table.insert(vents.edges, { a = "bJS", b = "bS" })
			table.insert(
				vents.grates,
				{ id = "G_BN", node = "bN", room = "S_Hall", lockable = true, criticalPath = false }
			)
			local southRoom = if southSide == "N" then "S_Hall" elseif southAt < 30 then "S_Room" else "S_Pool"
			table.insert(
				vents.grates,
				{ id = "G_BS", node = "bS", room = southRoom, lockable = true, criticalPath = false }
			)
			return layout
		end
		-- the dry duct ends at x = 20 and the flooded one starts at 43: keep this run between them
		expectClean(t, chaseWithBranches(33, 36, "S"), "branches 3 studs apart on opposite sides of the run")
		local sameSide = chaseWithBranches(33, 36, "N")
		expectError(t, sameSide, "cross or touch without a shared vent node", "branches 3 studs apart on one side")
	end,

	["ducts are listed once"] = function(t: Expect)
		local layout = base()
		table.insert(ventsOf(layout).edges, { a = "j2", b = "j1" })
		expectError(t, layout, "vent edge j2-j1 is listed twice", "a duplicated, reversed duct")
	end,

	["anchors and triggers stay inside their room's volume"] = function(t: Expect)
		local buried = base()
		table.insert(
			buried.anchors,
			{ id = "A_Buried", kind = "PlayerSpawn", room = "S_Room", pos = Vector3.new(10, -50, 40) }
		)
		expectError(t, buried, "anchor A_Buried at height -50.00 is outside room S_Room", "an anchor under the floor")
		local sky = base()
		table.insert(
			sky.anchors,
			{ id = "A_Sky", kind = "BatteryCandidate", room = "S_Room", pos = Vector3.new(10, 13, 40) }
		)
		expectError(t, sky, "anchor A_Sky", "an anchor above the ceiling")
		-- under water is fine over the basin, not over the dry deck
		local deck = base()
		table.insert(deck.anchors, { id = "A_Deck", kind = "Corpse", room = "S_Pool", pos = Vector3.new(33, -3, 30) })
		expectError(t, deck, "anchor A_Deck", "an anchor under the dry deck")

		local sunk = base()
		table.insert(
			sunk.triggers,
			{ id = "T_Sunk", kind = "FloorDebris", room = "S_Room", rect = R(4, 40, 4, 4), height = 4, y = -1 }
		)
		expectError(t, sunk, "trigger T_Sunk", "a trigger below the floor")
		local tall = base()
		table.insert(
			tall.triggers,
			{ id = "T_Tall", kind = "Checkpoint", room = "S_Room", rect = R(4, 40, 4, 4), height = 13 }
		)
		expectError(t, tall, "trigger T_Tall", "a trigger through the ceiling")
		-- a duct water volume below the chase floor needs the sunken duct under it
		local dryChase = base()
		local vents = ventsOf(dryChase)
		for i = #vents.edges, 1, -1 do
			if vents.edges[i].a == "j3" then
				table.remove(vents.edges, i)
			end
		end
		for i = #vents.nodes, 1, -1 do
			local id = vents.nodes[i].id
			if id == "j3" or id == "gPool" or id == "jEnd" then
				table.remove(vents.nodes, i)
			end
		end
		for i = #vents.grates, 1, -1 do
			if vents.grates[i].id == "G_Pool" then
				table.remove(vents.grates, i)
			end
		end
		expectError(t, dryChase, "trigger T_DuctWater", "a duct water volume with no sunken duct")
	end,
}
