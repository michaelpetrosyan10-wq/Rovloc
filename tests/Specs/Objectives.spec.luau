--!strict
-- Floor objectives' shared world data: ObjectiveConfig, the layouts' objective anchors (counts per floor, real surfaces,
-- clearances, reachability with every gate shut and every lockable grate locked, a hiding spot within HideReach of
-- every step, every guarded item's guard on the careless walk in from its room's arrival doorway to where its prompt
-- first answers, whichever way a door's leaf hangs (the squad arriving by that doorway, from that side of it, on foot
-- and crawling alike), and the item taken from a spot beside it clear of every trap spot, walked to round its guard
-- with no foot on a pan), RunDirector's seeded picks (deterministic, difficulty-free, the right kinds and counts, the
-- basement's guard traps inside the trap count) and the builders (items as plan props, stations and
-- locks as fixtures: names, tags, attributes, attachments, leaves and their poses, disabled prompts with the configured
-- holds, part budgets, collision presets, determinism).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local BreakerPanelBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.BreakerPanelBuilder)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local LockBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.LockBuilder)
local ObjectiveItemBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.ObjectiveItemBuilder)
local ObjectivePlaces = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ObjectivePlaces)
local PickupBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PickupBuilder)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)
local RunDirector = require(ReplicatedStorage.Shared.World.RunDirector)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local TunnelRules = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.TunnelRules)
local ZoneGraph = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph)

type Expect = SpecRunner.Expect
type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor

local W = Attributes.World
local EPS = 1e-3
local SEEDS = 120

-- Candidate counts the brief asks for, and the stations every floor has
local CANDIDATES: { [string]: number } = {
	Level0_Basement = 14,
	Level1_Hallways = 14,
}
-- The least the brief asks for on each floor
local MIN_CANDIDATES: { [string]: number } = {
	Level0_Basement = 12,
	Level1_Hallways = 9,
}
local COVERAGE_SEEDS = 600 -- pickObjective alone (cheap): every candidate turns up within this many seeds
local STATIONS: { [string]: { Enums.AnchorKind } } = {
	Level0_Basement = { "BreakerPanel", "ExitLock" },
	Level1_Hallways = { "ExitLock" },
}
-- Station fixtures: their folder, model count per level and leaves
local FIXTURES: { { level: string, folder: string, leaves: { string }, budget: number } } = {
	{
		level = "Level0_Basement",
		folder = BreakerPanelBuilder.Folder,
		leaves = { "Door", "FuseSlot1", "FuseSlot2", "FuseSlot3", "Lever" },
		budget = BreakerPanelBuilder.PartBudget,
	},
}
local LOCK_LEAVES: { [string]: { string } } = {
	Padlock = { "Padlock" },
	Keypad = { "Bar" },
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- The floors of the levels the world builds (the school's; the city's rows wait for their layouts).
local function builtFloors(): { ObjectiveConfig.FloorSpec }
	local out: { ObjectiveConfig.FloorSpec } = {}
	for _, spec in ObjectiveConfig.Floors do
		if WorldConfig.isSchoolLevel(spec.levelId) then
			table.insert(out, spec)
		end
	end
	return out
end

-- The built floors with an item to find (the Auditorium's interim floor has none).
local function itemFloors(): { ObjectiveConfig.FloorSpec }
	local out: { ObjectiveConfig.FloorSpec } = {}
	for _, spec in builtFloors() do
		if spec.item then
			table.insert(out, spec)
		end
	end
	return out
end

local function layoutOf(id: string): Layout
	local layout = Builder.getLayout(id)
	assert(layout, "layout " .. id)
	return layout
end

local function anchorsOf(layout: Layout, kind: Enums.AnchorKind): { Anchor }
	local out: { Anchor } = {}
	for _, anchor in layout.anchors do
		if anchor.kind == kind then
			table.insert(out, anchor)
		end
	end
	return out
end

local function anchorById(layout: Layout, id: string?): Anchor?
	for _, anchor in layout.anchors do
		if anchor.id == id then
			return anchor
		end
	end
	return nil
end

local cachedGraph: Types.ZoneGraphData? = nil
local function planFor(seed: number, difficulty: Enums.Difficulty): Types.SpawnPlan
	local layouts = Builder.layouts()
	local graph = cachedGraph or ZoneGraph.build(layouts)
	cachedGraph = graph
	return RunDirector.plan(seed, difficulty, layouts, graph)
end

local function quiet<T>(fn: () -> T): T
	local previous = Geometry.getYieldEvery()
	Geometry.setYieldEvery(0)
	local ok, result = pcall(fn)
	Geometry.setYieldEvery(previous)
	if not ok then
		error(result, 0)
	end
	return result
end

local function parts(root: Instance): { BasePart }
	local out: { BasePart } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(out, d)
		end
	end
	return out
end

local function prompts(root: Instance): { ProximityPrompt }
	local out: { ProximityPrompt } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("ProximityPrompt") then
			table.insert(out, d)
		end
	end
	return out
end

-- Rooms reachable from the entry with every Gate shut and every lockable grate locked.
local function strictReach(layout: Layout): { [string]: boolean }
	local adjacency: { [string]: { string } } = {}
	local function link(a: string, b: string)
		adjacency[a] = adjacency[a] or {}
		adjacency[b] = adjacency[b] or {}
		table.insert(adjacency[a], b)
		table.insert(adjacency[b], a)
	end
	for _, door in layout.doors do
		if door.kind ~= "Boarded" and door.kind ~= "Gate" and #door.rooms == 2 then
			link("room:" .. door.rooms[1], "room:" .. door.rooms[2])
		end
	end
	local vents = layout.vents
	if vents then
		for _, edge in vents.edges do
			link("vent:" .. edge.a, "vent:" .. edge.b)
		end
		for _, grate in vents.grates do
			if not grate.lockable then
				link("room:" .. grate.room, "vent:" .. grate.node)
			end
		end
	end
	local seen: { [string]: boolean } = { ["room:" .. layout.entry] = true }
	local queue = { "room:" .. layout.entry }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, nextId in (adjacency[current] or {}) :: { string } do
			if not seen[nextId] then
				seen[nextId] = true
				table.insert(queue, nextId)
			end
		end
	end
	local rooms: { [string]: boolean } = {}
	for key in seen do
		local id = string.match(key, "^room:(.+)$")
		if id then
			rooms[id] = true
		end
	end
	return rooms
end

-- Fixtures of every school level, built the way WorldService builds them at Deploying.
local cachedRuntime: { [string]: Folder }? = nil
local function runtime(): { [string]: Folder }
	local existing = cachedRuntime
	if existing then
		return existing
	end
	local out: { [string]: Folder } = {}
	quiet(function()
		for _, id: Enums.LevelId in WorldConfig.LevelOrder do
			local folder = Instance.new("Folder")
			folder.Name = id
			Builder.BuildFixtures(id, folder, nil)
			out[id] = folder
		end
		return true
	end)
	cachedRuntime = out
	return out
end

local function buildItem(kind: string, anchor: Anchor, levelId: Enums.LayoutId): Model
	local folder = Instance.new("Folder")
	local plan: Types.PlannedProp = {
		kind = kind,
		anchorId = anchor.id,
		levelId = levelId,
		cframe = Builder.anchorCFrame(levelId, anchor),
		variant = 1,
	}
	local built = quiet(function()
		return Builder.BuildProp(plan, folder)
	end)
	assert(built and built:IsA("Model"), kind .. " builds a model")
	return built
end

local function poseRoundTrip(t: Expect, model: Model, leaf: string, transform: CFrame)
	local before: { [BasePart]: CFrame } = {}
	for _, part in parts(model:FindFirstChild(leaf) :: Instance) do
		before[part] = part.CFrame
	end
	local built = PropKit.leafTransform(model, leaf)
	t.truthy(built ~= nil, model.Name .. " knows where " .. leaf .. " stands")
	t.truthy(PropKit.poseLeaf(model, leaf, transform), model.Name .. " poses " .. leaf)
	t.truthy(PropKit.poseLeaf(model, leaf, built or CFrame.new()), model.Name .. " poses " .. leaf .. " back")
	for part, cf in before do
		t.truthy((part.CFrame.Position - cf.Position).Magnitude < 2e-3, part.Name .. " returns to its built pose")
	end
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["config: every floor has its steps and its holds; an item floor its item and its lock"] = function(t: Expect)
		t.eq(#ObjectiveConfig.Floors, 5, "the basement, the hallways, the Auditorium storey and the city's two")
		t.eq(#builtFloors(), 3, "the school's three floors below the roof")
		for i, spec in builtFloors() do
			t.eq(spec.floor, i - 1, spec.id .. " floor number")
			t.eq(spec.levelId, WorldConfig.LevelOrder[i], spec.id .. " level in run order")
			t.truthy(Strings.has(spec.title), spec.id .. " title string")
			t.truthy(#spec.steps >= 1, spec.id .. " has steps")
			local stepIds: { [string]: boolean } = {}
			for _, step in spec.steps do
				t.truthy(Strings.has(step.label), step.id .. " label")
				stepIds[step.id] = true
			end
			t.truthy(Builder.getLayout(spec.levelId) ~= nil, spec.id .. " level")
			for kind, seconds in spec.holds do
				t.truthy(table.find(Enums.PromptKind, kind :: any) ~= nil, kind .. " is a PromptKind")
				t.truthy(seconds > 0, kind .. " hold")
			end
			local item = spec.item
			if item then
				t.truthy(#spec.steps >= 2, spec.id .. " has its steps")
				t.truthy(Strings.has(item.object), spec.id .. " item string")
				t.truthy(Strings.has(spec.lockReason or ""), spec.id .. " lock reason string")
				t.truthy(stepIds[spec.lockStep or ""], spec.id .. " unlocks on one of its steps")
				t.truthy(spec.lockVariant ~= nil, spec.id .. " locks its exit")
				t.truthy(ObjectiveConfig.forItem(item.prop) == spec, spec.id .. " item lookup")
			else
				t.eq(spec.lockStep, nil, spec.id .. " never locks its exit")
				t.eq(spec.lockVariant, nil, spec.id .. " has no exit lock")
				t.eq(#anchorsOf(layoutOf(spec.levelId), "ExitLock"), 0, spec.id .. " has no exit lock anchors")
			end
		end
		t.eq(ObjectiveConfig.forLevel("Lobby"), nil, "no objective in the lobby")
		t.eq(ObjectiveConfig.forLevel("Level3_Roof"), nil, "no floor objective on the roof")
		t.eq((ObjectiveConfig.Floors[1].item :: ObjectiveConfig.ItemSpec).guarded, 2, "two fuses guarded")
		t.eq(#itemFloors(), 2, "two floors with an item")
		-- the city's floors, as data until their layouts come: a lock step among their steps, an item or stations
		for _, spec in ObjectiveConfig.Floors do
			if WorldConfig.isSchoolLevel(spec.levelId) then
				continue
			end
			local stepIds: { [string]: boolean } = {}
			for _, step in spec.steps do
				t.truthy(Strings.has(step.label), step.id .. " label")
				stepIds[step.id] = true
			end
			t.truthy(stepIds[spec.lockStep or ""], spec.id .. " unlocks on one of its steps")
			t.truthy(spec.item ~= nil or spec.stations ~= nil, spec.id .. " has something to find or work")
			if spec.lockVariant then
				t.truthy(Strings.has(spec.lockReason or ""), spec.id .. " lock reason string")
			end
		end
	end,

	["layouts: candidates, stations and locks on every floor"] = function(t: Expect)
		for _, spec in itemFloors() do
			local itemSpec = spec.item :: ObjectiveConfig.ItemSpec
			local layout = layoutOf(spec.levelId)
			t.eq(#anchorsOf(layout, itemSpec.candidate), CANDIDATES[spec.levelId], spec.levelId .. " candidates")
			t.truthy(
				#anchorsOf(layout, itemSpec.candidate) >= MIN_CANDIDATES[spec.levelId],
				spec.levelId .. " at least the brief's candidates"
			)
			t.truthy(#anchorsOf(layout, itemSpec.candidate) > itemSpec.count, spec.levelId .. " more spots than items")
			for _, kind in STATIONS[spec.levelId] do
				-- an exit lock on every exit candidate's fire door
				local want = if kind == "ExitLock" then 3 else 1
				t.eq(#anchorsOf(layout, kind :: Enums.AnchorKind), want, spec.levelId .. " " .. kind)
			end
			local exitLocks = anchorsOf(layout, "ExitLock")
			if spec.lockVariant then
				t.eq(#exitLocks, 3, spec.levelId .. " an exit lock per exit candidate")
				-- on the fire door into the exit room
				local face = LockBuilder.doorFace(layout, exitLocks[1])
				t.truthy(face ~= nil, spec.levelId .. " exit lock sits in a door")
				if face then
					local door: LayoutSchema.Door? = nil
					for _, d in layout.doors do
						if d.id == face.doorId then
							door = d
						end
					end
					t.truthy(door and door.kind == "Airlock", spec.levelId .. " the lock is on an airlock door")
					t.truthy(
						door and (door.rooms[1] == layout.exit or door.rooms[2] == layout.exit),
						spec.levelId .. " the door is the exit's"
					)
				end
			else
				t.eq(#exitLocks, 0, spec.levelId .. " a floor without a lock has no exit lock")
			end
		end
		-- The basement's fuses are guarded: each refers to its own trap spot on the approach
		local basement = layoutOf("Level0_Basement")
		for _, fuse in anchorsOf(basement, "FuseCandidate") do
			local guard = anchorById(basement, fuse.ref)
			t.truthy(guard and guard.kind == "TrapCandidate", fuse.id .. " has a guard trap spot")
			if guard then
				t.eq(guard.room, fuse.room, fuse.id .. " guard in its room")
				local d = (Vector3.new(guard.pos.X, 0, guard.pos.Z) - Vector3.new(fuse.pos.X, 0, fuse.pos.Z)).Magnitude
				t.truthy(d >= 2 and d <= 9, string.format("%s guard %.1f studs off", fuse.id, d))
			end
		end
	end,

	["layouts: objective items rest on real surfaces"] = function(t: Expect)
		for _, spec in itemFloors() do
			local itemSpec = spec.item :: ObjectiveConfig.ItemSpec
			local layout = layoutOf(spec.levelId)
			for _, anchor in anchorsOf(layout, itemSpec.candidate) do
				local y = anchor.pos.Y
				local supported = false
				local why = ""
				if math.abs(y) < EPS then
					supported, why = true, "the floor"
				end
				for _, platform in (layout.platforms or {}) :: { LayoutSchema.Platform } do
					if
						math.abs(platform.top - y) < EPS
						and LayoutSchema.rectContains(platform.rect, anchor.pos.X, anchor.pos.Z, 0.2)
					then
						supported, why = true, platform.id
					end
				end
				if anchor.kind == "MasterKeyCandidate" then
					-- a nail in the wall: the anchor stands on a wall face
					local room = LayoutSchema.indexRooms(layout)[anchor.room]
					local r = room.rect
					local x, z = anchor.pos.X, anchor.pos.Z
					local onWall = math.abs(x - (r.x + 0.5)) < 0.3
						or math.abs(x - (r.x + r.w - 0.5)) < 0.3
						or math.abs(z - (r.z + 0.5)) < 0.3
						or math.abs(z - (r.z + r.d - 0.5)) < 0.3
					supported, why = onWall, "a wall"
				end
				t.truthy(supported, string.format("%s at y %.2f rests on something (%s)", anchor.id, y, why))
			end
		end
	end,

	["layouts: nothing blocks a doorway, a vent mouth, an airlock or a corridor"] = function(t: Expect)
		for _, spec in builtFloors() do
			local layout = layoutOf(spec.levelId)
			local rooms = LayoutSchema.indexRooms(layout)
			local nodes: { [string]: LayoutSchema.VentNodeSpec } = {}
			for _, n in ((layout.vents and layout.vents.nodes) or {}) :: { LayoutSchema.VentNodeSpec } do
				nodes[n.id] = n
			end
			for _, place in ObjectivePlaces.places(layout) do
				if place.kind == "ExitLock" then
					continue -- it sits on its door by design
				end
				local room = rooms[place.room]
				t.truthy(room.kind ~= "Airlock" and room.kind ~= "Stairwell", place.id .. " outside airlocks")
				local x, z = place.pos.X, place.pos.Z
				-- doorways: 3 studs of walking lane either side of every passable opening
				for _, door in layout.doors do
					local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
					local edge = if a and b then LayoutSchema.sharedEdge(a.rect, b.rect) else nil
					if door.kind == "Boarded" or not edge then
						continue
					end
					local half = LayoutSchema.doorWidth(door) / 2 + 0.5
					local along = if edge.axis == "X" then z else x
					local across = math.abs((if edge.axis == "X" then x else z) - edge.coord)
					t.falsy(
						math.abs(along - door.at) < half and across < 3,
						string.format("%s stands in doorway %s", place.id, door.id)
					)
				end
				-- vent mouths: the floor in front of every grate
				for _, grate in ((layout.vents and layout.vents.grates) or {}) :: { LayoutSchema.GrateSpec } do
					local n = nodes[grate.node]
					if n and grate.room == place.room then
						local d = (Vector3.new(n.x, 0, n.z) - Vector3.new(x, 0, z)).Magnitude
						t.truthy(d > 3.5, string.format("%s %.1f studs from vent %s", place.id, d, grate.id))
					end
				end
				-- corridors: floor items keep to a wall, out of the walking lane
				if room.kind == "Corridor" then
					local r = room.rect
					local fromWall = if r.w >= r.d
						then math.min(z - r.z, r.z + r.d - z)
						else math.min(x - r.x, r.x + r.w - x)
					t.truthy(fromWall < 3.3, place.id .. " keeps out of the corridor's walking lane")
				end
			end
		end
	end,

	["layouts: every objective room is reachable with the gates shut and the lockable grates locked"] = function(
		t: Expect
	)
		for _, spec in builtFloors() do
			local layout = layoutOf(spec.levelId)
			local reach = strictReach(layout)
			t.truthy(reach[layout.exit], spec.levelId .. " exit reachable")
			for _, place in ObjectivePlaces.places(layout) do
				t.truthy(reach[place.room], string.format("%s (%s) reachable", place.id, place.room))
			end
		end
		-- Floor 1: the keys are past the gate (west of its wall), so the bypass vent is the way to them
		local hallways = layoutOf("Level1_Hallways")
		local hallRooms = LayoutSchema.indexRooms(hallways)
		local gateX: number? = nil
		for _, door in hallways.doors do
			if door.scriptedId == "HallwayGate" then
				local edge = LayoutSchema.sharedEdge(hallRooms[door.rooms[1]].rect, hallRooms[door.rooms[2]].rect)
				gateX = if edge then edge.coord else nil
			end
		end
		t.truthy(gateX ~= nil, "the hallway gate's wall")
		for _, keys in anchorsOf(hallways, "MasterKeyCandidate") do
			t.truthy(keys.pos.X < (gateX or 0), keys.id .. " is past the gate")
		end
	end,

	["layouts: every item candidate is fair (entry clearance, real footing, kinds, lockers)"] = function(t: Expect)
		for _, spec in itemFloors() do
			local itemSpec = spec.item :: ObjectiveConfig.ItemSpec
			local layout = layoutOf(spec.levelId)
			local scareRooms: { [string]: boolean } = {}
			for _, a in anchorsOf(layout, "CreatureScarePose") do
				scareRooms[a.room] = true
			end
			local all = anchorsOf(layout, itemSpec.candidate)
			t.eq(
				#RunDirector.objectiveCandidates(layout, spec),
				#all,
				spec.levelId .. " every candidate is one a run may use"
			)
			local entries = ObjectivePlaces.entries(layout)
			t.eq(#entries, if spec.levelId == "Level0_Basement" then 1 else 3, spec.levelId .. " ways in")
			for _, anchor in all do
				local place = { id = anchor.id, kind = anchor.kind, room = anchor.room, pos = anchor.pos }
				local walk = ObjectivePlaces.entryDistance(layout, place)
				t.truthy(
					walk >= ObjectiveConfig.EntryClearance and walk < math.huge,
					string.format("%s is %.1f studs walked from the entry", anchor.id, walk)
				)
				local straight = math.huge
				for _, entry in entries do
					straight = math.min(straight, (Vector3.new(anchor.pos.X, 0, anchor.pos.Z) - entry.pos).Magnitude)
				end
				t.truthy(walk >= straight - EPS, anchor.id .. " walk is never shorter than the straight line")
				t.falsy(scareRooms[anchor.room], anchor.id .. " is not in the scare classroom")
				-- floor items stand clear of solid plant and pillars
				for _, platform in (layout.platforms or {}) :: { LayoutSchema.Platform } do
					local over = LayoutSchema.rectContains(platform.rect, anchor.pos.X, anchor.pos.Z, -0.8)
					t.falsy(
						over and platform.top > anchor.pos.Y + 0.05,
						string.format("%s is clear of %s", anchor.id, platform.id)
					)
				end
				for _, pillar in (layout.pillars or {}) :: { LayoutSchema.Pillar } do
					t.falsy(
						math.abs(pillar.x - anchor.pos.X) < pillar.size / 2 + 0.8
							and math.abs(pillar.z - anchor.pos.Z) < pillar.size / 2 + 0.8,
						anchor.id .. " is clear of the pillars"
					)
				end
			end
		end
	end,

	["layouts: every guarded item is taken from beside it, clear of every trap spot, walked to round its guard"] = function(
		t: Expect
	)
		local body = ObjectivePlaces.BodyRadius
		local expected, checked = 0, 0
		for _, spec in itemFloors() do
			local itemSpec = spec.item :: ObjectiveConfig.ItemSpec
			if not itemSpec.guarded then
				continue
			end
			local layout = layoutOf(spec.levelId)
			local rooms = LayoutSchema.indexRooms(layout)
			local origin = WorldConfig.levelOrigin(spec.levelId)
			-- every trap spot a run may arm: the guards of whichever items it picks and the seeded rest
			local traps: { Vector2 } = {}
			for _, a in anchorsOf(layout, "TrapCandidate") do
				table.insert(traps, Vector2.new(a.pos.X, a.pos.Z))
			end
			local function trapGap(p: Vector2): number
				local best = math.huge
				for _, trap in traps do
					best = math.min(best, (trap - p).Magnitude)
				end
				return best
			end
			for _, item in anchorsOf(layout, itemSpec.candidate) do
				expected += 1
				local guard = anchorById(layout, item.ref)
				t.truthy(guard ~= nil and guard.kind == "TrapCandidate", item.id .. " is guarded")
				local stand = ObjectivePlaces.standingSpot(layout, item)
				t.truthy(stand ~= nil, item.id .. " has a spot beside it clear of every trap spot, walked to")
				if not stand then
					continue
				end
				checked += 1
				local spot = Vector2.new(stand.pos.X, stand.pos.Z)
				local reach = (spot - Vector2.new(item.pos.X, item.pos.Z)).Magnitude
				t.truthy(
					reach >= ObjectivePlaces.StandNear - EPS and reach <= ObjectivePlaces.StandReach + EPS,
					string.format("%s: the spot is %.2f studs off it", item.id, reach)
				)
				t.truthy(
					trapGap(spot) >= ObjectivePlaces.TrapClear - EPS,
					string.format("%s: the spot is %.2f studs from the nearest trap spot", item.id, trapGap(spot))
				)
				-- the item's own Pickup prompt answers there (measured from the standing root)
				local model = buildItem(itemSpec.prop, item, spec.levelId :: Enums.LayoutId)
				local point = PropKit.findAttachment(model, "PromptPoint")
				local prompt: ProximityPrompt? = prompts(model)[1]
				t.truthy(point ~= nil and prompt ~= nil, item.id .. " has its Pickup prompt")
				if point and prompt then
					local root = origin + Vector3.new(spot.X, ObjectivePlaces.StandEye - 1.5, spot.Y)
					local distance = (PropKit.attachmentWorld(point).Position - root).Magnitude
					t.truthy(
						distance <= prompt.MaxActivationDistance,
						string.format("%s: its prompt reaches the spot (%.2f studs)", item.id, distance)
					)
				end
				(model.Parent :: Instance):Destroy()
				-- the walk: from just inside one of the room's doorways, straight legs along the grid inside the room's
				-- walls (a body's width off them), never a foot on a trap's pan, ending on the spot
				local room = rooms[item.room]
				local path = stand.path
				t.truthy(#path >= 1 and (path[#path] - spot).Magnitude < EPS, item.id .. " the walk ends on the spot")
				local first = path[1]
				local inDoorway = false
				for _, door in layout.doors do
					local other = if door.rooms[1] == room.id
						then rooms[door.rooms[2]]
						elseif door.rooms[2] == room.id then rooms[door.rooms[1]]
						else nil
					local edge = if other and door.kind ~= "Boarded"
						then LayoutSchema.sharedEdge(room.rect, other.rect)
						else nil
					if edge then
						local along = if edge.axis == "X" then first.Y else first.X
						local into = math.abs((if edge.axis == "X" then first.X else first.Y) - edge.coord)
						if
							math.abs(along - door.at) <= LayoutSchema.doorWidth(door) / 2 - body + EPS
							and into <= body + WorldConfig.WallThickness + EPS
						then
							inDoorway = true
						end
					end
				end
				t.truthy(inDoorway, item.id .. " the walk starts in a doorway of its room")
				for i = 1, #path - 1 do
					local a, b = path[i], path[i + 1]
					t.truthy(math.abs(a.X - b.X) < EPS or math.abs(a.Y - b.Y) < EPS, item.id .. " legs along the grid")
					local steps = math.max(1, math.ceil((b - a).Magnitude / 0.25))
					for k = 0, steps do
						local p = a + (b - a) * (k / steps)
						t.truthy(
							trapGap(p) > ObjectivePlaces.PanReach,
							string.format(
								"%s: the walk at (%.2f, %.2f) keeps the foot off every pan",
								item.id,
								p.X,
								p.Y
							)
						)
						t.truthy(
							LayoutSchema.rectContains(room.rect, p.X, p.Y, WorldConfig.WallThickness / 2 + body - EPS),
							string.format("%s: the walk at (%.2f, %.2f) stays clear of the walls", item.id, p.X, p.Y)
						)
					end
				end
			end
		end
		t.truthy(expected > 0 and checked == expected, string.format("%d of %d guarded items", checked, expected))
	end,

	["layouts: every guarded item's guard lies on the careless walk in, whichever way a door's leaf hangs"] = function(
		t: Expect
	)
		local body = ObjectivePlaces.BodyRadius
		local wall = WorldConfig.WallThickness
		local expected, checked = 0, 0
		for _, spec in itemFloors() do
			local itemSpec = spec.item :: ObjectiveConfig.ItemSpec
			if not itemSpec.guarded then
				continue
			end
			local layout = layoutOf(spec.levelId)
			local rooms = LayoutSchema.indexRooms(layout)
			local origin = WorldConfig.levelOrigin(spec.levelId)
			-- studs walked from the nearest way in to the floor, on a tunnel floor on foot (crawlways shut) and for a squad
			-- that takes the crawlways too: the careless arrive the same way either way
			type Measure = { how: string, at: (roomId: string, p: Vector2) -> number }
			local measures: { Measure } = {}
			for _, crawling in { false, true } do
				local graph = TunnelRules.walkGraph(layout :: any, crawling)
				local seeds: { { number } } = {}
				for _, entry in ObjectivePlaces.entries(layout) do
					for _, seed in TunnelRules.seedsAt(graph, entry.room, Vector2.new(entry.pos.X, entry.pos.Z)) do
						table.insert(seeds, seed)
					end
				end
				local fromEntries = TunnelRules.distances(graph, seeds)
				table.insert(measures, {
					how = if crawling then "crawling" else "on foot",
					at = function(roomId: string, p: Vector2): number
						if not layout.tunnels then
							return ObjectivePlaces.entryDistance(
								layout,
								{ id = "", kind = "TrapCandidate", room = roomId, pos = Vector3.new(p.X, 0, p.Y) }
							)
						end
						return TunnelRules.reach(graph, fromEntries, roomId, p)
					end,
				})
			end
			for _, item in anchorsOf(layout, itemSpec.candidate) do
				expected += 1
				local guard = anchorById(layout, item.ref)
				local approach = ObjectivePlaces.carelessWalk(layout, item)
				t.truthy(guard ~= nil and approach ~= nil, item.id .. " is guarded and walked in to")
				if not (guard and approach) then
					continue
				end
				local room = rooms[item.room]
				-- the arrival doorway: of the room's ways in on foot, the one nearest the floor's ways in (on foot and
				-- crawling alike)
				local door: LayoutSchema.Door? = nil
				for _, d in layout.doors do
					if d.id == approach.door then
						door = d
					end
				end
				assert(door, item.id .. " arrival doorway " .. approach.door)
				local beyond = rooms[if door.rooms[1] == room.id then door.rooms[2] else door.rooms[1]]
				local edge = LayoutSchema.sharedEdge(room.rect, beyond.rect)
				assert(edge, item.id .. " its doorway joins two rooms")
				local function doorPoint(d: LayoutSchema.Door, e: LayoutSchema.SharedEdge): Vector2
					return if e.axis == "X" then Vector2.new(e.coord, d.at) else Vector2.new(d.at, e.coord)
				end
				for _, measure in measures do
					local arrival = measure.at(beyond.id, doorPoint(door, edge))
					for _, d in layout.doors do
						if d == door or d.kind == "Boarded" or d.kind == "Gate" or #d.rooms ~= 2 then
							continue
						end
						if d.rooms[1] ~= room.id and d.rooms[2] ~= room.id then
							continue
						end
						local other = rooms[if d.rooms[1] == room.id then d.rooms[2] else d.rooms[1]]
						local e = LayoutSchema.sharedEdge(room.rect, other.rect)
						if e and not LayoutSchema.doorCrawlOnly(layout, d) then
							t.truthy(
								measure.at(other.id, doorPoint(d, e)) >= arrival - EPS,
								string.format(
									"%s: walked in by %s, not by %s nearer the way in (%s)",
									item.id,
									door.id,
									d.id,
									measure.how
								)
							)
						end
					end
				end
				-- an ordinary door's leaf hangs on the far face or beside either jamb: a walk for each
				t.eq(#approach.walks, if door.kind == "Door" then 3 else 1, item.id .. " a walk per way the leaf hangs")
				-- the item's own Pickup prompt: where it answers
				local model = buildItem(itemSpec.prop, item, spec.levelId :: Enums.LayoutId)
				local point = PropKit.findAttachment(model, "PromptPoint")
				local prompt: ProximityPrompt? = prompts(model)[1]
				assert(point and prompt, item.id .. " has its Pickup prompt")
				local maxDistance = prompt.MaxActivationDistance
				t.near(maxDistance, ObjectivePlaces.PromptReach, EPS, item.id .. " prompt reach")
				local promptAt = PropKit.attachmentWorld(point).Position;
				(model.Parent :: Instance):Destroy()
				local function answers(p: Vector2): number
					local root = origin + Vector3.new(p.X, ObjectivePlaces.StandEye - 1.5, p.Y)
					return (promptAt - root).Magnitude - maxDistance
				end
				local g = Vector2.new(guard.pos.X, guard.pos.Z)
				local worst = 0
				for v, walk in approach.walks do
					local label = string.format("%s walk %d", item.id, v)
					t.truthy(#walk >= 2, label .. " goes somewhere")
					if #walk < 2 then
						continue
					end
					-- it starts out in the room beyond, ApproachRun back from the doorway at most, on the side the squad
					-- comes from (no nearer the floor's way in mirrored across the doorway)
					local start = walk[1]
					local mouth = doorPoint(door, edge)
					t.truthy(
						LayoutSchema.rectContains(beyond.rect, start.X, start.Y, wall / 2 + body - EPS),
						label .. " starts in " .. beyond.id
					)
					t.truthy(
						(start - mouth).Magnitude <= ObjectivePlaces.ApproachRun * math.sqrt(2) + EPS,
						label .. " starts by the doorway"
					)
					local mirrored = if edge.axis == "X"
						then Vector2.new(start.X, 2 * mouth.Y - start.Y)
						else Vector2.new(2 * mouth.X - start.X, start.Y)
					for _, measure in measures do
						t.truthy(
							measure.at(beyond.id, start) <= measure.at(beyond.id, mirrored) + EPS,
							string.format("%s comes from the side nearer the way in (%s)", label, measure.how)
						)
					end
					-- every step inside the room, the room beyond or the doorway between, a body clear of the walls;
					-- the prompt answers only at its end
					local near = math.huge
					for i = 1, #walk - 1 do
						local a, b = walk[i], walk[i + 1]
						local steps = math.max(1, math.ceil((b - a).Magnitude / 0.1))
						for k = 0, steps do
							local p = a + (b - a) * (k / steps)
							near = math.min(near, (p - g).Magnitude)
							local inside = LayoutSchema.rectContains(room.rect, p.X, p.Y, wall / 2 + body - EPS)
								or LayoutSchema.rectContains(beyond.rect, p.X, p.Y, wall / 2 + body - EPS)
							local along = if edge.axis == "X" then p.Y else p.X
							local across = math.abs((if edge.axis == "X" then p.X else p.Y) - edge.coord)
							local inDoor = math.abs(along - door.at) <= LayoutSchema.doorWidth(door) / 2 - body + EPS
								and across <= wall / 2 + body + EPS
							t.truthy(
								inside or inDoor,
								string.format("%s at (%.2f, %.2f) on the floor", label, p.X, p.Y)
							)
							if i < #walk - 1 or k < steps then
								t.truthy(
									answers(p) > -0.05,
									string.format("%s at (%.2f, %.2f): the prompt waits for its end", label, p.X, p.Y)
								)
							end
						end
					end
					t.truthy(answers(walk[#walk]) <= 0.05, label .. " ends where the prompt answers")
					worst = math.max(worst, near)
					t.truthy(
						near <= ObjectivePlaces.PanCore,
						string.format("%s passes %.2f studs from %s: its foot on the pan", label, near, guard.id)
					)
				end
				t.near(approach.guardGap, worst, 0.05, item.id .. " guard gap")
				checked += 1
			end
		end
		t.truthy(expected > 0 and checked == expected, string.format("%d of %d guarded items", checked, expected))
	end,

	["layouts: a hiding spot within reach of every objective step"] = function(t: Expect)
		for _, spec in builtFloors() do
			local layout = layoutOf(spec.levelId)
			for _, place in ObjectivePlaces.places(layout) do
				local hide = ObjectivePlaces.nearestHide(layout, place)
				t.truthy(hide ~= nil, place.id .. " has a hiding spot")
				if hide then
					t.truthy(
						hide.distance <= ObjectiveConfig.HideReach,
						string.format(
							"%s: nearest %s %s is %.1f studs away",
							place.id,
							hide.kind,
							hide.id,
							hide.distance
						)
					)
					if spec.floor >= 1 and spec.floor <= 3 then
						-- (a tunnel floor's barrels and cabinets are hides like its lockers)
						local tunnelHide = layout.tunnels ~= nil and (hide.kind == "Barrel" or hide.kind == "Cabinet")
						t.truthy(
							hide.kind == "Locker" or hide.kind == "Vent" or tunnelHide,
							place.id .. " hides in a locker, a vent, or a tunnel's barrel or cabinet"
						)
					end
				end
			end
		end
	end,

	["plan: seeded picks, deterministic and independent of the difficulty"] = function(t: Expect)
		local sets: { [string]: { [string]: boolean } } = {}
		for seed = 1, SEEDS do
			local plan = planFor(seed, "Standard")
			local again = planFor(seed, "Standard")
			local nightmare = planFor(seed, "Nightmare")
			local objectives = plan.objectives
			assert(objectives, "the plan lists its objectives")
			t.truthy(table.isfrozen(objectives), "frozen")
			for _, spec in itemFloors() do
				local itemSpec = spec.item :: ObjectiveConfig.ItemSpec
				local picks = RunDirector.objectiveOf(plan, spec.levelId)
				assert(picks, spec.levelId .. " picks")
				local twin = RunDirector.objectiveOf(again, spec.levelId)
				local other = RunDirector.objectiveOf(nightmare, spec.levelId)
				t.eq(#picks.anchors, itemSpec.count, spec.levelId .. " count")
				t.eq(picks.prop, itemSpec.prop, spec.levelId .. " prop kind")
				t.eq(
					table.concat(picks.anchors, ","),
					table.concat((twin :: Types.ObjectivePicks).anchors, ","),
					"same seed"
				)
				t.eq(
					table.concat(picks.anchors, ","),
					table.concat((other :: Types.ObjectivePicks).anchors, ","),
					"any difficulty"
				)
				local layout = layoutOf(spec.levelId)
				local used: { [string]: boolean } = {}
				local picked: { Anchor } = {}
				for _, id in picks.anchors do
					local anchor = anchorById(layout, id)
					t.truthy(anchor and anchor.kind == itemSpec.candidate, id .. " is a candidate")
					t.falsy(used[id], id .. " picked once")
					used[id] = true
					if anchor then
						table.insert(picked, anchor)
					end
				end
				sets[spec.levelId] = sets[spec.levelId] or {}
				sets[spec.levelId][table.concat(picks.anchors, ",")] = true
				-- several items: different rooms, PickSpacing apart, three spread over PickQuarters quarters
				for i = 1, #picked do
					for j = i + 1, #picked do
						local a, b = picked[i], picked[j]
						t.truthy(
							a.room ~= b.room,
							string.format("seed %d: %s and %s in different rooms", seed, a.id, b.id)
						)
						local apart = (Vector3.new(a.pos.X, 0, a.pos.Z) - Vector3.new(b.pos.X, 0, b.pos.Z)).Magnitude
						t.truthy(
							apart >= ObjectiveConfig.PickSpacing,
							string.format("seed %d: %s and %s %.1f apart", seed, a.id, b.id, apart)
						)
					end
				end
				if #picked >= 3 then
					t.truthy(
						RunDirector.quarters(picked) >= ObjectiveConfig.PickQuarters,
						string.format("seed %d: %s picks spread over the floor", seed, spec.levelId)
					)
				end
				-- the plan's props of this floor are its picks, each built once
				local props = RunDirector.propsOf(plan, itemSpec.prop, spec.levelId)
				t.eq(#props, itemSpec.count, spec.levelId .. " props")
				local propAnchors: { [string]: boolean } = {}
				for _, prop in props do
					t.truthy(table.find(picks.anchors, prop.anchorId) ~= nil, prop.anchorId .. " is a pick")
					t.falsy(propAnchors[prop.anchorId], prop.anchorId .. " built once")
					propAnchors[prop.anchorId] = true
				end
			end
			t.eq(RunDirector.objectiveOf(plan, "Level2_Auditorium"), nil, "no picks on a floor without an item")
			-- the guard traps are planned traps on the first two fuses' approaches, inside the trap count
			local fuses = RunDirector.objectiveOf(plan, "Level0_Basement") :: Types.ObjectivePicks
			local basement = layoutOf("Level0_Basement")
			t.eq(#fuses.guards, 2, "two guarded fuses")
			local traps: { [string]: boolean } = {}
			for _, prop in RunDirector.propsOf(plan, "BearTrap") do
				traps[prop.anchorId] = true
			end
			for i, guard in fuses.guards do
				t.truthy(traps[guard], guard .. " is armed")
				local fuse = anchorById(basement, fuses.anchors[i])
				t.eq(fuse and fuse.ref, guard, "guard of pick " .. i)
			end
			t.eq(#RunDirector.propsOf(plan, "BearTrap"), DifficultyConfig.Standard.trapCount, "trap count unchanged")
		end
		-- the picks vary from run to run: every multi-item floor gives at least 20 different sets over the seeds, and
		-- every candidate turns up in some run
		for _, spec in itemFloors() do
			local itemSpec = spec.item :: ObjectiveConfig.ItemSpec
			local layout = layoutOf(spec.levelId)
			local distinct = 0
			for _ in sets[spec.levelId] do
				distinct += 1
			end
			local wanted = if itemSpec.count > 1 then 20 else math.min(8, #anchorsOf(layout, itemSpec.candidate))
			t.truthy(
				distinct >= wanted,
				string.format("%s: %d different picks over %d seeds", spec.levelId, distinct, SEEDS)
			)
			local seen: { [string]: boolean } = {}
			for seed = 1, COVERAGE_SEEDS do
				for _, anchor in (RunDirector.pickObjective(seed, layout, spec)) do
					seen[anchor.id] = true
				end
			end
			for _, anchor in anchorsOf(layout, itemSpec.candidate) do
				t.truthy(seen[anchor.id], anchor.id .. " is used by some seed")
			end
		end
	end,

	["items: plan props with tags, attributes, grips and a disabled pickup prompt"] = function(t: Expect)
		for _, spec in itemFloors() do
			local itemSpec = spec.item :: ObjectiveConfig.ItemSpec
			local layout = layoutOf(spec.levelId)
			for _, anchor in anchorsOf(layout, itemSpec.candidate) do
				local model = buildItem(itemSpec.prop, anchor, spec.levelId :: Enums.LayoutId)
				local twin = buildItem(itemSpec.prop, anchor, spec.levelId :: Enums.LayoutId)
				t.eq(model.Name, itemSpec.prop .. "_" .. anchor.id, "name")
				t.truthy(model.PrimaryPart ~= nil, "PrimaryPart")
				t.truthy(model:HasTag(Tags.ObjectiveItem) and model:HasTag(Tags.Interactable), anchor.id .. " tags")
				t.eq(model:GetAttribute(W.Floor), spec.floor, "Floor")
				t.eq(model:GetAttribute(W.Step), spec.steps[1].id, "Step")
				t.eq(model:GetAttribute(W.ObjectiveId), itemSpec.prop, "ObjectiveId")
				t.eq(model:GetAttribute(W.AnchorId), anchor.id, "AnchorId")
				t.eq(model:GetAttribute(W.LevelId), spec.levelId, "LevelId")
				t.eq(model:GetAttribute(W.Candidate), itemSpec.candidate, "Candidate")
				t.truthy(PropKit.findAttachment(model, "Grip") ~= nil, "Grip")
				local list = prompts(model)
				t.eq(#list, 1, anchor.id .. " one prompt")
				local prompt = list[1]
				t.eq(prompt:GetAttribute(W.PromptKind), "Pickup", "Pickup")
				t.falsy(prompt.Enabled, "disabled")
				t.near(prompt.HoldDuration, itemSpec.hold, EPS, "hold")
				t.eq(prompt:GetAttribute(W.Step), spec.steps[1].id, "prompt Step")
				local all = parts(model)
				local cap = ObjectiveItemBuilder.MaxParts[itemSpec.prop]
				t.truthy(#all <= cap, string.format("%s: %d parts (cap %d)", itemSpec.prop, #all, cap))
				local lowest = math.huge
				local floor = Builder.anchorCFrame(spec.levelId, anchor)
				for i, part in all do
					t.falsy(part.CanCollide or part.CanQuery, part.Name .. " is a detail")
					local other = parts(twin)[i]
					t.truthy(other and other.CFrame == part.CFrame, "same seed, same geometry")
					local shape = if part:IsA("Part") then part.Shape else Enum.PartType.Block
					lowest =
						math.min(lowest, PickupBuilder.lowestPoint(floor:ToObjectSpace(part.CFrame), part.Size, shape))
				end
				if itemSpec.prop ~= "MasterKeys" then
					t.near(lowest, 0, 2e-3, anchor.id .. " rests on its surface")
				end
				(model.Parent :: Instance):Destroy();
				(twin.Parent :: Instance):Destroy()
			end
		end
	end,

	["items: held visuals"] = function(t: Expect)
		local folder = Instance.new("Folder")
		quiet(function()
			for _, kind in ObjectiveItemBuilder.Kinds do
				local rig = Builder.BuildRig(kind .. "Visual", folder, CFrame.new(3, 4, 5))
				t.truthy(rig ~= nil, kind .. "Visual rig")
				if rig then
					t.truthy(PropKit.findAttachment(rig, "Grip") ~= nil, kind .. " grip")
					t.eq(#prompts(rig), 0, kind .. " visual has no prompt")
					for _, part in parts(rig) do
						t.falsy(part.CanCollide or part.CanQuery or part.CastShadow, part.Name .. " cosmetic")
					end
				end
			end
			return true
		end)
		folder:Destroy()
	end,

	["stations: fixtures with leaves, poses, prompts and budgets"] = function(t: Expect)
		local built = runtime()
		for _, entry in FIXTURES do
			local folder = built[entry.level]:FindFirstChild(entry.folder)
			t.truthy(folder ~= nil, entry.level .. " " .. entry.folder)
			if not folder then
				continue
			end
			local models = folder:GetChildren()
			t.eq(#models, 1, entry.folder .. " one model")
			local model = models[1] :: Model
			t.truthy(model:IsA("Model") and model.PrimaryPart ~= nil, entry.folder .. " model + PrimaryPart")
			t.truthy(#parts(model) <= entry.budget, string.format("%s: %d parts", entry.folder, #parts(model)))
			t.truthy(model:HasTag(Tags.ObjectiveStation) or model:HasTag(Tags.ExitLock), entry.folder .. " is tagged")
			t.eq(model:GetAttribute(W.LevelId), entry.level, "LevelId")
			t.truthy(type(model:GetAttribute(W.Step)) == "string", "Step")
			t.truthy(type(model:GetAttribute(W.Floor)) == "number", "Floor")
			for _, leaf in entry.leaves do
				t.truthy(model:FindFirstChild(leaf) ~= nil, entry.folder .. " leaf " .. leaf)
				t.truthy(PropKit.leafRest(model, leaf) ~= nil, entry.folder .. " rest of " .. leaf)
				poseRoundTrip(t, model, leaf, CFrame.new(0, 0.3, 0) * CFrame.Angles(0.2, 0, 0))
			end
			local spec = ObjectiveConfig.forLevel(entry.level) :: ObjectiveConfig.FloorSpec
			for _, prompt in prompts(model) do
				t.falsy(prompt.Enabled, prompt.Name .. " disabled")
				t.truthy(type(prompt:GetAttribute(W.Step)) == "string", prompt.Name .. " Step")
				local kind = prompt:GetAttribute(W.PromptKind)
				if kind ~= "Locked" and kind ~= "Pickup" then
					t.near(prompt.HoldDuration, spec.holds[kind :: string] or -1, EPS, prompt.Name .. " hold")
				end
			end
			t.truthy(#prompts(model) >= 1, entry.folder .. " prompts")
			-- rebuilding replaces, never duplicates
			quiet(function()
				Builder.BuildFixtures(entry.level, built[entry.level], nil)
				return true
			end)
			t.eq(#(built[entry.level]:FindFirstChild(entry.folder) :: Instance):GetChildren(), 1, "rebuilt once")
		end
		-- the breaker panel: three fuse slots with seats and prompts, the lever's throw
		local panel = (built.Level0_Basement:FindFirstChild(BreakerPanelBuilder.Folder) :: Instance):GetChildren()[1] :: Model
		for i = 1, BreakerPanelBuilder.Slots do
			t.truthy(PropKit.findAttachment(panel, "FuseSlot" .. i .. "Seat") ~= nil, "seat " .. i)
		end
		local fit = 0
		for _, prompt in prompts(panel) do
			if prompt:GetAttribute(W.PromptKind) == "FitFuse" then
				fit += 1
				t.truthy(type(prompt:GetAttribute(W.Slot)) == "number", "fit prompt slot")
			end
		end
		t.eq(fit, 3, "three FitFuse prompts")
		t.truthy(BreakerPanelBuilder.setLever(panel, 1) and BreakerPanelBuilder.setLever(panel, 0), "lever poses")
	end,

	["locks: every exit holds its floor's lock variant on its door"] = function(t: Expect)
		local built = runtime()
		for _, spec in builtFloors() do
			local folder = built[spec.levelId]:FindFirstChild(LockBuilder.Folders.ExitLock)
			if not spec.lockVariant then
				t.eq(folder, nil, spec.levelId .. " has no door lock")
				continue
			end
			t.truthy(folder and #folder:GetChildren() == 3, spec.levelId .. " an exit lock per exit candidate")
			if not folder then
				continue
			end
			local layoutAnchors = anchorsOf(layoutOf(spec.levelId), "ExitLock")
			local model = folder:FindFirstChild("ExitLock_" .. layoutAnchors[1].id) :: Model
			if not model then
				for _, candidate in folder:GetChildren() do
					if candidate:GetAttribute(W.AnchorId) == layoutAnchors[1].id then
						model = candidate :: Model
					end
				end
			end
			t.truthy(model:HasTag(Tags.ExitLock), "ExitLock tag")
			t.eq(model:GetAttribute(W.LockVariant), spec.lockVariant, spec.levelId .. " variant")
			t.eq(model:GetAttribute(W.Locked), true, "built locked")
			t.eq(model:GetAttribute(W.Step), spec.lockStep, "unlocked by the floor's lock step")
			t.truthy(type(model:GetAttribute(W.DoorId)) == "string", "names its door")
			for _, leaf in LOCK_LEAVES[spec.lockVariant :: string] do
				t.truthy(model:FindFirstChild(leaf) ~= nil, spec.levelId .. " leaf " .. leaf)
			end
			local kinds: { [string]: boolean } = {}
			for _, prompt in prompts(model) do
				kinds[prompt:GetAttribute(W.PromptKind) :: string] = true
				t.falsy(prompt.Enabled, "disabled")
			end
			t.truthy(kinds.Locked, spec.levelId .. " Locked prompt")
			t.eq(kinds.Unlock == true, spec.levelId == "Level1_Hallways", "Unlock only on the keys' door")
			-- no lock part reaches into the doorway's walking lane
			local layout = layoutOf(spec.levelId)
			local face = LockBuilder.doorFace(layout, anchorsOf(layout, "ExitLock")[1]) :: LockBuilder.DoorFace
			for _, part in parts(model) do
				local p = face.frame:PointToObjectSpace(part.CFrame.Position)
				t.truthy(p.Z > -WorldConfig.WallThickness / 2 - 1.3, part.Name .. " stays at the door")
				t.falsy(part.CanCollide, part.Name .. " never collides")
			end
		end
	end,
}
