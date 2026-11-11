--!strict
-- Open air and hidden gates (docs/design/game-spec-v2.md 3.6, 4.4, 4.7): the Yard and Gap room kinds and the Gate skins,
-- on a fixture layout (two Yard decks either side of a 12-wide Gap with its deck 12 down, a Hangar behind a hidden
-- BrickFlat Gate). The schema validates it and refuses each broken variant; the zone graph walks the Gap for players
-- (its lips) and gives the Creature no way across; TunnelRules counts the hidden Gate open for connectivity and shut
-- for reach; the shell builds the deck low, no ceilings, a CreatureBlock in each opening and the gate's skin. Real
-- layouts that use them come from the stage packages.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local SchoolShellBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.SchoolShellBuilder)
local Tags = require(ReplicatedStorage.Shared.Tags)
local TunnelRules = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.TunnelRules)
local ZoneGraph = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Layout = LayoutSchema.LevelLayout

local LEVEL: "City1_Rooftops" = "City1_Rooftops"
local DROP = 12

-- The fixture, fresh each time (a variant edits its copy).
local function fixture(): Layout
	return {
		id = LEVEL,
		height = 24,
		acoustic = "Outdoor",
		ambience = "WindDrone",
		entry = "Fx_DeckWest",
		exit = "Fx_Hangar",
		rooms = {
			{ id = "Fx_DeckWest", kind = "Yard", rect = LayoutSchema.rect(0, 0, 194, 288), wallHeight = 3.5 },
			{ id = "Fx_Alley", kind = "Gap", rect = LayoutSchema.rect(194, 0, 12, 288), drop = DROP, wallHeight = 3.5 },
			{ id = "Fx_DeckEast", kind = "Yard", rect = LayoutSchema.rect(206, 0, 94, 288), wallHeight = 3.5 },
			{ id = "Fx_Hangar", kind = "Hangar", rect = LayoutSchema.rect(300, 0, 100, 288) },
		},
		doors = {
			{
				id = "Fx_LipWest",
				kind = "Doorway",
				rooms = { "Fx_DeckWest", "Fx_Alley" },
				at = 144,
				width = 12,
				height = 3,
			},
			{
				id = "Fx_LipEast",
				kind = "Doorway",
				rooms = { "Fx_Alley", "Fx_DeckEast" },
				at = 144,
				width = 12,
				height = 3,
			},
			{
				id = "Fx_HiddenDoor",
				kind = "Gate",
				rooms = { "Fx_DeckEast", "Fx_Hangar" },
				at = 144,
				width = 10,
				height = 12,
				skin = "BrickFlat",
				hidden = true,
			},
		},
		anchors = {
			{ id = "Fx_Spawn", kind = "PlayerSpawn", room = "Fx_DeckWest", pos = Vector3.new(40, 0, 144) },
			{ id = "Fx_Waypoint", kind = "PatrolWaypoint", room = "Fx_DeckEast", pos = Vector3.new(250, 0, 100) },
			{ id = "Fx_DeckBattery", kind = "BatteryCandidate", room = "Fx_Alley", pos = Vector3.new(200, -DROP, 60) },
		},
		triggers = {},
	}
end

local function problems(layout: Layout): string
	return table.concat(LayoutSchema.validate(layout), "; ")
end

local function refuses(t: Expect, layout: Layout, needle: string, label: string)
	local found = problems(layout)
	t.truthy(string.find(found, needle, 1, true) ~= nil, label .. " (got: " .. found .. ")")
end

local function room(layout: Layout, id: string): LayoutSchema.Room
	for _, r in layout.rooms do
		if r.id == id then
			return r
		end
	end
	error("no room " .. id)
end

local function door(layout: Layout, id: string): LayoutSchema.Door
	for _, d in layout.doors do
		if d.id == id then
			return d
		end
	end
	error("no door " .. id)
end

return {
	["the fixture validates: two Yard decks, a Gap 12 down between them, a hidden BrickFlat Gate"] = function(
		t: Expect
	)
		local layout = fixture()
		t.eq(problems(layout), "")
		t.truthy(LayoutSchema.openSky(room(layout, "Fx_DeckWest")), "a Yard is open to the sky")
		t.truthy(LayoutSchema.openSky(room(layout, "Fx_Alley")), "so is a Gap")
		t.falsy(LayoutSchema.openSky(room(layout, "Fx_Hangar")), "a Hangar has a roof")
		t.eq(LayoutSchema.roomDrop(room(layout, "Fx_Alley")), DROP)
		t.eq(LayoutSchema.roomDrop(room(layout, "Fx_DeckWest")), 0)
		t.falsy(LayoutSchema.creatureFloor(room(layout, "Fx_Alley")), "no floor for the Creature in a Gap")
		t.truthy(LayoutSchema.creatureFloor(room(layout, "Fx_DeckEast")))
		t.truthy(LayoutSchema.hiddenGate(door(layout, "Fx_HiddenDoor")))
		local openings = LayoutSchema.gapOpenings(layout)
		t.eq(#openings, 2, "two openings into the gap")
		for _, opening in openings do
			t.eq(opening.gap.id, "Fx_Alley")
			t.truthy(opening.room.kind == "Yard", opening.door.id)
		end
	end,

	["the schema refuses a broken gap, a door into it, a Creature on its deck, a stray skin"] = function(t: Expect)
		local layout = fixture()
		room(layout, "Fx_Alley").drop = nil
		refuses(t, layout, "needs a positive drop", "a gap without a drop")
		layout = fixture()
		room(layout, "Fx_DeckWest").drop = 4
		refuses(t, layout, "only a Gap's floor lies below", "a drop on a yard")
		layout = fixture()
		door(layout, "Fx_LipWest").kind = "Door"
		refuses(t, layout, "must be a Doorway", "a door leaf into a gap")
		layout = fixture()
		table.insert(
			layout.anchors,
			{ id = "Fx_Lurker", kind = "CreatureSpawn", room = "Fx_Alley", pos = Vector3.new(200, -DROP, 200) }
		)
		refuses(t, layout, "where the Creature has no floor", "a Creature start in a gap")
		layout = fixture()
		door(layout, "Fx_LipEast").skin = "Shutter"
		refuses(t, layout, "is a Doorway, not a Gate", "a gate skin on a doorway")
		layout = fixture()
		door(layout, "Fx_HiddenDoor").skin = "Portcullis" :: any
		refuses(t, layout, "unknown gate skin", "an unknown skin")
		layout = fixture()
		layout.entry = "Fx_Alley"
		refuses(t, layout, "cannot be the entry or the exit", "a gap as the entry")
		layout = fixture()
		room(layout, "Fx_DeckEast").ceiling = "PlasterSchool"
		refuses(t, layout, "open to the sky and names a ceiling", "a ceiling over a yard")
		layout = fixture()
		table.insert(
			layout.anchors,
			{ id = "Fx_TooDeep", kind = "BatteryCandidate", room = "Fx_Alley", pos = Vector3.new(200, -DROP - 1, 90) }
		)
		refuses(t, layout, "outside room Fx_Alley vertically", "below the deck")
	end,

	["a hidden Gate counts open for the solvability proof; a plain Gate shut cuts the exit off"] = function(t: Expect)
		local layout = fixture()
		t.eq(problems(layout), "", "the hidden door is the way on")
		door(layout, "Fx_HiddenDoor").hidden = nil
		refuses(t, layout, "exit Fx_Hangar is unreachable", "a plain gate is the worst case shut")
	end,

	["the zone graph: players cross the Gap by its lips, the Creature never; the deck is 12 down"] = function(
		t: Expect
	)
		local layout = fixture()
		local graph = ZoneGraph.build({ layout })
		local west = ZoneGraph.roomNodeId(LEVEL, "Fx_DeckWest")
		local east = ZoneGraph.roomNodeId(LEVEL, "Fx_DeckEast")
		local alley = ZoneGraph.roomNodeId(LEVEL, "Fx_Alley")
		local hangar = ZoneGraph.roomNodeId(LEVEL, "Fx_Hangar")
		t.eq(graph.nodes[alley].roomKind, "Gap")
		t.eq(graph.nodes[alley].center.Y, -DROP, "the gap's node stands on its deck")
		local lips = 0
		for _, edge in graph.edges do
			if edge.portalId == "Fx_LipWest" or edge.portalId == "Fx_LipEast" then
				t.truthy(edge.lip, edge.portalId .. " is a lip")
				lips += 1
			else
				t.falsy(edge.lip, edge.portalId .. " is no lip")
			end
		end
		t.eq(lips, 2)
		local players = ZoneGraph.reachable(graph, west, ZoneGraph.worstCaseBlocked(layout))
		t.truthy(players[east] and players[alley], "players reach the far deck across the gap")
		t.truthy(players[hangar], "and the hangar through the hidden door (it opens)")
		local blocked = ZoneGraph.creatureBlocked(graph)
		t.truthy(
			blocked.Fx_LipWest and blocked.Fx_LipEast and not blocked.Fx_HiddenDoor,
			"the Creature's blocked portals"
		)
		local creature = ZoneGraph.reachable(graph, west, blocked)
		t.falsy(creature[alley], "no floor for the Creature in the gap")
		t.falsy(creature[east], "it must go round: here there is no way round")
		t.truthy(ZoneGraph.isLevelSolvable(graph, layout, ZoneGraph.worstCaseBlocked(layout)), "solvable")
		t.falsy(ZoneGraph.isLevelSolvable(graph, layout, { Fx_HiddenDoor = true }), "the hidden door is the only way")
		local _, length = ZoneGraph.shortestPath(graph, west, east)
		t.truthy(length < math.huge, "a path across the gap for a player")
	end,

	["TunnelRules: the hidden Gate is open for connectivity and the crossing, shut for every reach"] = function(
		t: Expect
	)
		local layout = fixture()
		local shut = TunnelRules.walkGraph(layout :: any, false)
		local open = TunnelRules.walkGraph(layout :: any, false, false, true)
		local from = TunnelRules.arrival(layout :: any, "Fx_DeckWest")
		local inHangar = Vector2.new(350, 144)
		local shutDist = TunnelRules.distances(shut, TunnelRules.seedsAt(shut, "Fx_DeckWest", from))
		local openDist = TunnelRules.distances(open, TunnelRules.seedsAt(open, "Fx_DeckWest", from))
		t.eq(TunnelRules.reach(shut, shutDist, "Fx_Hangar", inHangar), math.huge, "shut for reach")
		local through = TunnelRules.reach(open, openDist, "Fx_Hangar", inHangar)
		t.truthy(through < math.huge, "open for connectivity")
		local onDeck = TunnelRules.reach(shut, shutDist, "Fx_Alley", Vector2.new(200, 144))
		t.truthy(onDeck < math.huge, "the gap's deck is walked like any room")
	end,

	["the shell: the deck 12 down, open sky, a CreatureBlock in each opening, the gate's skin and no hazard plates"] = function(
		t: Expect
	)
		local layout = fixture()
		local root = SchoolShellBuilder.createRoot(layout)
		SchoolShellBuilder.buildLevel(layout, root, SchoolShellBuilder.levelOptions(LEVEL))
		local deckTop: number? = nil
		local ceilings, hazards, wells = 0, 0, 0
		local hangarCeiling = false
		local blocks: { BasePart } = {}
		for _, d in root:GetDescendants() do
			if not d:IsA("BasePart") then
				continue
			end
			if string.find(d.Name, "^Floor_Fx_Alley_") then
				deckTop = d.CFrame.Position.Y + d.Size.Y / 2
			elseif d.Name == "Ceiling_Fx_Hangar" then
				hangarCeiling = true
			elseif string.find(d.Name, "^Ceiling_") or string.find(d.Name, "^Roof_Fx_Deck") then
				ceilings += 1
			elseif string.find(d.Name, "^Hazard_Fx_HiddenDoor") then
				hazards += 1
			elseif string.find(d.Name, "^GapWell_Fx_Alley_") then
				wells += 1
			elseif d:HasTag(Tags.CreatureBlock) then
				table.insert(blocks, d)
			end
		end
		t.truthy(deckTop ~= nil and math.abs((deckTop :: number) + DROP) < 1e-3, "the alley's deck at -12")
		t.eq(ceilings, 0, "no ceiling or roof over a yard or the gap")
		t.truthy(hangarCeiling, "the hangar has its ceiling")
		t.eq(hazards, 0, "a hidden gate reads as wall: no hazard plates")
		t.eq(wells, 4, "the alley's sides lined down to its deck")
		t.eq(#blocks, 2, "a CreatureBlock in each opening")
		for _, block in blocks do
			t.eq(block.CollisionGroup, CollisionGroups.CreatureBlock, block.Name)
			t.truthy(block.CanCollide and block.Transparency == 1 and not block.CanQuery, block.Name)
			t.truthy(block.Size.Y >= 11, block.Name .. " taller than the Creature")
			t.eq(block:GetAttribute("LevelId"), LEVEL)
		end
		local zone = root:FindFirstChild("Fx_Alley", true)
		t.truthy(zone and zone:IsA("BasePart") and zone:GetAttribute("Drop") == DROP, "the gap's zone knows its drop")
		if zone and zone:IsA("BasePart") then
			t.truthy(math.abs(zone.CFrame.Position.Y - zone.Size.Y / 2 + DROP) < 1e-3, "its zone starts on the deck")
		end
		local anchor = root:FindFirstChild("Door_Fx_HiddenDoor", true)
		t.truthy(anchor ~= nil, "the hidden gate's door anchor")
		if anchor then
			t.eq(anchor:GetAttribute("GateSkin"), "BrickFlat")
			t.eq(anchor:GetAttribute("GateHidden"), true)
		end
		root:Destroy()
	end,

	["collision groups: a CreatureBlock stops the Creature only; Traversing collides with nothing"] = function(
		t: Expect
	)
		for _, group: CollisionGroups.GroupName in CollisionGroups.All do
			t.eq(CollisionGroups.collides("CreatureBlock", group), group == "Monster", "CreatureBlock vs " .. group)
			t.falsy(CollisionGroups.collides("Traversing", group), "Traversing vs " .. group)
		end
		t.truthy(table.find(CollisionGroups.Custom, "CreatureBlock") ~= nil)
		t.truthy(table.find(CollisionGroups.Custom, "Traversing") ~= nil)
	end,
}
