--!strict
-- Floor objectives' shared world data: ObjectiveConfig, the layouts' objective anchors (counts per floor, real surfaces,
-- clearances, reachability with every gate shut and every lockable grate locked, a hiding spot within HideReach of
-- every step), RunDirector's seeded picks (deterministic, difficulty-free, the right kinds and counts, reagent slots,
-- the basement's guard traps inside the trap count) and the builders (items as plan props, stations and locks as
-- fixtures: names, tags, attributes, attachments, leaves and their poses, disabled prompts with the configured holds,
-- part budgets, collision presets, determinism).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local AcidFlaskBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.AcidFlaskBuilder)
local BreakerPanelBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.BreakerPanelBuilder)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local LockBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.LockBuilder)
local ObjectiveItemBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.ObjectiveItemBuilder)
local ObjectivePlaces = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ObjectivePlaces)
local PickupBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PickupBuilder)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)
local RunDirector = require(ServerScriptService.Services.Core.NoiseAndDirectorService.RunDirector)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local ZoneGraph = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph)

type Expect = SpecRunner.Expect
type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor

local W = Attributes.World
local EPS = 1e-3
local SEEDS = 120

-- Candidate counts the brief asks for, and the stations every floor has
local CANDIDATES: { [string]: number } = {
	Level0_Basement = 13,
	Level1_Hallways = 10,
	Level2_ScienceHall = 12,
	Level3_Gymnasium = 32,
	Level4_FloodedPool = 8,
	Level5_Roof = 9,
}
-- The least the brief asks for on each floor
local MIN_CANDIDATES: { [string]: number } = {
	Level0_Basement = 12,
	Level1_Hallways = 9,
	Level2_ScienceHall = 12,
	Level3_Gymnasium = 12,
	Level4_FloodedPool = 6,
	Level5_Roof = 8,
}
local COVERAGE_SEEDS = 600 -- pickObjective alone (cheap): every candidate turns up within this many seeds
local STATIONS: { [string]: { Enums.AnchorKind } } = {
	Level0_Basement = { "BreakerPanel", "ExitLock" },
	Level1_Hallways = { "ExitLock" },
	Level2_ScienceHall = { "FumeHood", "ExitLock" },
	Level3_Gymnasium = { "Generator", "StoreLock", "ExitLock" },
	Level4_FloodedPool = { "HatchValve", "ExitLock" },
	Level5_Roof = { "CrateChain" },
}
-- Station fixtures: their folder, model count per level and leaves
local FIXTURES: { { level: string, folder: string, leaves: { string }, budget: number } } = {
	{
		level = "Level0_Basement",
		folder = BreakerPanelBuilder.Folder,
		leaves = { "Door", "FuseSlot1", "FuseSlot2", "FuseSlot3", "Lever" },
		budget = BreakerPanelBuilder.PartBudget,
	},
	{ level = "Level2_ScienceHall", folder = "FumeHoods", leaves = { "Sash" }, budget = 24 },
	{ level = "Level3_Gymnasium", folder = "Generators", leaves = { "PullCord" }, budget = 28 },
	{ level = "Level4_FloodedPool", folder = "HatchValves", leaves = { "Hatch", "Stem" }, budget = 20 },
	{ level = "Level5_Roof", folder = "CrateChains", leaves = { "Chain", "Padlock" }, budget = 32 },
	{ level = "Level3_Gymnasium", folder = "StoreLocks", leaves = { "Padlock" }, budget = 12 },
}
local LOCK_LEAVES: { [string]: { string } } = {
	Padlock = { "Padlock" },
	Chain = { "Chain", "Padlock" },
	Keypad = { "Bar" },
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

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
		for _, id: Enums.LevelId in Enums.LevelId do
			local folder = Instance.new("Folder")
			folder.Name = id
			Builder.BuildFixtures(id, folder, nil, 99)
			out[id] = folder
		end
		return true
	end)
	cachedRuntime = out
	return out
end

local function buildItem(kind: string, anchor: Anchor, levelId: Enums.LayoutId, slot: number, seed: number): Model
	local folder = Instance.new("Folder")
	local plan: Types.PlannedProp = {
		kind = kind,
		anchorId = anchor.id,
		levelId = levelId,
		cframe = Builder.anchorCFrame(levelId, anchor),
		variant = 1,
		slot = slot,
	}
	local built = quiet(function()
		return Builder.BuildProp(plan, folder, Random.new(seed))
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
	["config: every floor has an item, its steps, its holds and its lock"] = function(t: Expect)
		t.eq(#ObjectiveConfig.Floors, 6, "six floors")
		for i, spec in ObjectiveConfig.Floors do
			t.eq(spec.floor, i - 1, spec.id .. " floor number")
			t.truthy(Strings.has(spec.title), spec.id .. " title string")
			t.truthy(Strings.has(spec.item.object), spec.id .. " item string")
			t.truthy(Strings.has(spec.lockReason), spec.id .. " lock reason string")
			t.truthy(#spec.steps >= 2, spec.id .. " has steps")
			local stepIds: { [string]: boolean } = {}
			for _, step in spec.steps do
				t.truthy(Strings.has(step.label), step.id .. " label")
				stepIds[step.id] = true
			end
			t.truthy(stepIds[spec.lockStep], spec.id .. " unlocks on one of its steps")
			t.truthy(Builder.getLayout(spec.levelId) ~= nil, spec.id .. " level")
			t.truthy(ObjectiveConfig.forItem(spec.item.prop) == spec, spec.id .. " item lookup")
			for kind, seconds in spec.holds do
				t.truthy(table.find(Enums.PromptKind, kind :: any) ~= nil, kind .. " is a PromptKind")
				t.truthy(seconds > 0, kind .. " hold")
			end
		end
		t.eq(ObjectiveConfig.forLevel("Lobby"), nil, "no objective in the lobby")
		t.eq(ObjectiveConfig.Floors[1].item.guarded, 2, "two fuses guarded")
		t.eq(ObjectiveConfig.Floors[4].steps[4].seconds, 45, "the door motor winds 45 s")
	end,

	["layouts: candidates, stations and locks on every floor"] = function(t: Expect)
		for _, spec in ObjectiveConfig.Floors do
			local layout = layoutOf(spec.levelId)
			t.eq(#anchorsOf(layout, spec.item.candidate), CANDIDATES[spec.levelId], spec.levelId .. " candidates")
			t.truthy(
				#anchorsOf(layout, spec.item.candidate) >= MIN_CANDIDATES[spec.levelId],
				spec.levelId .. " at least the brief's candidates"
			)
			t.truthy(
				#anchorsOf(layout, spec.item.candidate) > spec.item.count,
				spec.levelId .. " more spots than items"
			)
			for _, kind in STATIONS[spec.levelId] do
				t.eq(#anchorsOf(layout, kind :: Enums.AnchorKind), 1, spec.levelId .. " " .. kind)
			end
			local exitLocks = anchorsOf(layout, "ExitLock")
			if spec.lockVariant then
				t.eq(#exitLocks, 1, spec.levelId .. " exit lock")
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
				t.eq(#exitLocks, 0, "the roof's exit is the crate")
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
		-- The coach's key hangs inside a locker of a locker room
		local gym = layoutOf("Level3_Gymnasium")
		local rooms = LayoutSchema.indexRooms(gym)
		for _, key in anchorsOf(gym, "CoachKeyCandidate") do
			local locker = anchorById(gym, key.ref)
			t.truthy(locker and locker.kind == "Locker", key.id .. " refers to a locker")
			if locker then
				t.eq(rooms[locker.room].kind, "LockerRoom", key.id .. " in a locker room")
				local inner = CFrame.new(locker.pos) * CFrame.Angles(0, math.rad(locker.yaw or 0), 0)
				local p = inner:PointToObjectSpace(key.pos)
				t.truthy(math.abs(p.X) < 1.3 and p.Z > 0.5 and p.Z < 1.25, key.id .. " on the locker's back wall")
				t.truthy(p.Y > 3 and p.Y < 6.5, key.id .. " at chest height")
			end
		end
	end,

	["layouts: objective items rest on real surfaces"] = function(t: Expect)
		for _, spec in ObjectiveConfig.Floors do
			local layout = layoutOf(spec.levelId)
			local basin = (layout.basins or {})[1]
			for _, anchor in anchorsOf(layout, spec.item.candidate) do
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
				for _, counter in anchorsOf(layout, "LabCounter") do
					local local_ = (CFrame.new(counter.pos) * CFrame.Angles(0, math.rad(counter.yaw or 0), 0)):PointToObjectSpace(
						anchor.pos
					)
					if math.abs(local_.X) <= 4.8 and math.abs(local_.Z) <= 1.55 and y > 2.5 and y < 4 then
						supported, why = true, "a lab worktop"
					end
				end
				if basin and math.abs(y + basin.depth) < EPS then
					local interior = Geometry.insetRect(basin.rect, Geometry.BasinWall)
					if LayoutSchema.rectContains(interior, anchor.pos.X, anchor.pos.Z, 1) then
						supported, why = true, "the pool floor"
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
				elseif anchor.kind == "CoachKeyCandidate" then
					supported, why = anchor.ref ~= nil, "a locker's back wall"
				end
				t.truthy(supported, string.format("%s at y %.2f rests on something (%s)", anchor.id, y, why))
			end
		end
	end,

	["layouts: nothing blocks a doorway, a vent mouth, an airlock or a corridor"] = function(t: Expect)
		for _, spec in ObjectiveConfig.Floors do
			local layout = layoutOf(spec.levelId)
			local rooms = LayoutSchema.indexRooms(layout)
			local nodes: { [string]: LayoutSchema.VentNodeSpec } = {}
			for _, n in ((layout.vents and layout.vents.nodes) or {}) :: { LayoutSchema.VentNodeSpec } do
				nodes[n.id] = n
			end
			for _, place in ObjectivePlaces.places(layout) do
				if place.kind == "ExitLock" or place.kind == "StoreLock" or place.kind == "HatchValve" then
					continue -- they sit on their door or grate by design
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
		for _, spec in ObjectiveConfig.Floors do
			local layout = layoutOf(spec.levelId)
			local reach = strictReach(layout)
			t.truthy(reach[layout.exit], spec.levelId .. " exit reachable")
			for _, place in ObjectivePlaces.places(layout) do
				t.truthy(reach[place.room], string.format("%s (%s) reachable", place.id, place.room))
			end
		end
		-- Floor 1: the keys are past the gate, so the bypass vent is the way to them
		local hallways = layoutOf("Level1_Hallways")
		for _, keys in anchorsOf(hallways, "MasterKeyCandidate") do
			t.truthy(keys.pos.X < 120, keys.id .. " is past the gate")
		end
	end,

	["layouts: every item candidate is fair (entry clearance, real footing, kinds, lockers)"] = function(t: Expect)
		for _, spec in ObjectiveConfig.Floors do
			local layout = layoutOf(spec.levelId)
			local scareRooms: { [string]: boolean } = {}
			for _, a in anchorsOf(layout, "CreatureScarePose") do
				scareRooms[a.room] = true
			end
			local all = anchorsOf(layout, spec.item.candidate)
			t.eq(
				#RunDirector.objectiveCandidates(layout, spec),
				#all,
				spec.levelId .. " every candidate is one a run may use"
			)
			local entry = ObjectivePlaces.entryPoint(layout)
			for _, anchor in all do
				local place = { id = anchor.id, kind = anchor.kind, room = anchor.room, pos = anchor.pos }
				local walk = ObjectivePlaces.entryDistance(layout, place)
				t.truthy(
					walk >= ObjectiveConfig.EntryClearance and walk < math.huge,
					string.format("%s is %.1f studs walked from the entry", anchor.id, walk)
				)
				local straight = (Vector3.new(anchor.pos.X, 0, anchor.pos.Z) - entry).Magnitude
				t.truthy(walk >= straight - EPS, anchor.id .. " walk is never shorter than the straight line")
				t.falsy(scareRooms[anchor.room], anchor.id .. " is not in the scare classroom")
				-- floor items stand clear of solid plant and pillars; pool-floor items lie in open water
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
		-- reagents: at least four of each kind
		local science = layoutOf("Level2_ScienceHall")
		local spec2 = ObjectiveConfig.forLevel("Level2_ScienceHall") :: ObjectiveConfig.FloorSpec
		local perKind: { [number]: number } = {}
		for i in anchorsOf(science, "ReagentCandidate") do
			local slot = RunDirector.candidateSlot(spec2, i)
			perKind[slot] = (perKind[slot] or 0) + 1
		end
		for k = 1, spec2.item.slots or 0 do
			t.truthy((perKind[k] or 0) >= 4, string.format("reagent kind %d has %d spots", k, perKind[k] or 0))
		end
		-- the coach's key: every locker of both locker rooms can hold it
		local gym = layoutOf("Level3_Gymnasium")
		local rooms = LayoutSchema.indexRooms(gym)
		local holds: { [string]: boolean } = {}
		for _, key in anchorsOf(gym, "CoachKeyCandidate") do
			holds[key.ref or ""] = true
		end
		for _, locker in anchorsOf(gym, "Locker") do
			if rooms[locker.room].kind == "LockerRoom" then
				t.truthy(holds[locker.id], locker.id .. " can hold the coach's key")
			end
		end
	end,

	["layouts: a hiding spot within reach of every objective step"] = function(t: Expect)
		for _, spec in ObjectiveConfig.Floors do
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
						t.truthy(
							hide.kind == "Locker" or hide.kind == "Vent",
							place.id .. " hides in a locker or a vent"
						)
					end
				end
			end
			-- valve wheels are one breath from dry footing
			for _, wheel in anchorsOf(layout, "ValveWheelCandidate") do
				local hide = ObjectivePlaces.nearestHide(layout, {
					id = wheel.id,
					kind = wheel.kind,
					room = wheel.room,
					pos = wheel.pos,
				})
				t.truthy(
					hide and hide.kind == "DryFooting" and hide.distance <= 12,
					wheel.id .. " within 12 studs of dry footing"
				)
			end
		end
	end,

	["plan: seeded picks, deterministic and independent of the difficulty"] = function(t: Expect)
		local sets: { [string]: { [string]: boolean } } = {}
		local slotsSeen = 0
		for seed = 1, SEEDS do
			local plan = planFor(seed, "Standard")
			local again = planFor(seed, "Standard")
			local nightmare = planFor(seed, "Nightmare")
			local objectives = plan.objectives
			assert(objectives, "the plan lists its objectives")
			t.truthy(table.isfrozen(objectives), "frozen")
			for _, spec in ObjectiveConfig.Floors do
				local picks = RunDirector.objectiveOf(plan, spec.levelId)
				assert(picks, spec.levelId .. " picks")
				local twin = RunDirector.objectiveOf(again, spec.levelId)
				local other = RunDirector.objectiveOf(nightmare, spec.levelId)
				t.eq(#picks.anchors, spec.item.count, spec.levelId .. " count")
				t.eq(picks.prop, spec.item.prop, spec.levelId .. " prop kind")
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
					t.truthy(anchor and anchor.kind == spec.item.candidate, id .. " is a candidate")
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
				-- the plan's props of this floor are its picks, slots 1..count in pick order
				local props = RunDirector.propsOf(plan, spec.item.prop, spec.levelId)
				t.eq(#props, spec.item.count, spec.levelId .. " props")
				local slots: { [number]: boolean } = {}
				local candidates = anchorsOf(layout, spec.item.candidate)
				for _, prop in props do
					local slot = prop.slot or 0
					t.eq(picks.anchors[slot], prop.anchorId, prop.anchorId .. " slot " .. slot)
					t.falsy(slots[slot], "slots distinct")
					slots[slot] = true
					slotsSeen += 1
					if spec.item.slots then
						-- one of each kind: the slot is the candidate's own kind
						for i, candidate in candidates do
							if candidate.id == prop.anchorId then
								t.eq(RunDirector.candidateSlot(spec, i), slot, prop.anchorId .. " is its kind")
							end
						end
					end
				end
			end
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
		t.truthy(slotsSeen > 0, "slots")
		-- the picks vary from run to run: every multi-item floor gives at least 20 different sets over the seeds, and
		-- every candidate turns up in some run
		for _, spec in ObjectiveConfig.Floors do
			local layout = layoutOf(spec.levelId)
			local distinct = 0
			for _ in sets[spec.levelId] do
				distinct += 1
			end
			local wanted = if spec.item.count > 1 then 20 else math.min(8, #anchorsOf(layout, spec.item.candidate))
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
			for _, anchor in anchorsOf(layout, spec.item.candidate) do
				t.truthy(seen[anchor.id], anchor.id .. " is used by some seed")
			end
		end
	end,

	["items: plan props with tags, attributes, grips and a disabled pickup prompt"] = function(t: Expect)
		for _, spec in ObjectiveConfig.Floors do
			local layout = layoutOf(spec.levelId)
			for slot, anchor in anchorsOf(layout, spec.item.candidate) do
				local model = buildItem(spec.item.prop, anchor, spec.levelId :: Enums.LayoutId, (slot - 1) % 3 + 1, 7)
				local twin = buildItem(spec.item.prop, anchor, spec.levelId :: Enums.LayoutId, (slot - 1) % 3 + 1, 7)
				t.eq(model.Name, spec.item.prop .. "_" .. anchor.id, "name")
				t.truthy(model.PrimaryPart ~= nil, "PrimaryPart")
				t.truthy(model:HasTag(Tags.ObjectiveItem) and model:HasTag(Tags.Interactable), anchor.id .. " tags")
				t.eq(model:GetAttribute(W.Floor), spec.floor, "Floor")
				t.eq(model:GetAttribute(W.Step), spec.steps[1].id, "Step")
				t.eq(model:GetAttribute(W.ObjectiveId), spec.item.prop, "ObjectiveId")
				t.eq(model:GetAttribute(W.AnchorId), anchor.id, "AnchorId")
				t.eq(model:GetAttribute(W.LevelId), spec.levelId, "LevelId")
				t.eq(model:GetAttribute(W.Candidate), spec.item.candidate, "Candidate")
				t.eq(model:GetAttribute(W.Slot), (slot - 1) % 3 + 1, "Slot")
				t.truthy(PropKit.findAttachment(model, "Grip") ~= nil, "Grip")
				local list = prompts(model)
				t.eq(#list, 1, anchor.id .. " one prompt")
				local prompt = list[1]
				t.eq(prompt:GetAttribute(W.PromptKind), "Pickup", "Pickup")
				t.falsy(prompt.Enabled, "disabled")
				t.near(prompt.HoldDuration, spec.item.hold, EPS, "hold")
				t.eq(prompt:GetAttribute(W.Step), spec.steps[1].id, "prompt Step")
				local all = parts(model)
				local cap = ObjectiveItemBuilder.MaxParts[spec.item.prop]
				t.truthy(#all <= cap, string.format("%s: %d parts (cap %d)", spec.item.prop, #all, cap))
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
				if spec.item.prop ~= "MasterKeys" and spec.item.prop ~= "CoachKey" then
					t.near(lowest, 0, 2e-3, anchor.id .. " rests on its surface")
				end
				(model.Parent :: Instance):Destroy();
				(twin.Parent :: Instance):Destroy()
			end
		end
		-- the reagent slots colour the jars, and the wheel has its hub
		t.truthy(ObjectiveItemBuilder.slotColor(1) ~= ObjectiveItemBuilder.slotColor(2), "slot colours differ")
		local pool = layoutOf("Level4_FloodedPool")
		local wheel = buildItem("ValveWheel", anchorsOf(pool, "ValveWheelCandidate")[1], "Level4_FloodedPool", 1, 3)
		t.truthy(PropKit.findAttachment(wheel, "Hub") ~= nil, "the valve wheel's Hub");
		(wheel.Parent :: Instance):Destroy()
	end,

	["items: held visuals and the acid flask"] = function(t: Expect)
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
			local acid = Builder.BuildRig("AcidFlask", folder, CFrame.new())
			t.truthy(acid and PropKit.findAttachment(acid, "Grip") ~= nil, "AcidFlask rig with a grip")
			local world = AcidFlaskBuilder.buildWorld(folder, CFrame.new(1, 2, 3), "L2_FumeHood")
			t.truthy(world:HasTag(Tags.ObjectiveItem), "acid flask tag")
			t.eq(world:GetAttribute(W.Step), "BurnChain", "acid flask step")
			t.eq(world:GetAttribute(W.ObjectiveId), "AcidFlask", "acid flask id")
			t.eq(#prompts(world), 1, "acid flask prompt")
			t.truthy(#parts(world) <= AcidFlaskBuilder.MaxParts, "acid flask budget")
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
				Builder.BuildFixtures(entry.level, built[entry.level], nil, 98)
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
		for _, spec in ObjectiveConfig.Floors do
			local folder = built[spec.levelId]:FindFirstChild(LockBuilder.Folders.ExitLock)
			if not spec.lockVariant then
				t.eq(folder, nil, spec.levelId .. " has no door lock")
				local crate = built[spec.levelId]:FindFirstChild(LockBuilder.Folders.CrateChain)
				t.truthy(crate and #crate:GetChildren() == 1, "the crate chain")
				if crate then
					local chain = crate:GetChildren()[1] :: Model
					t.truthy(chain:HasTag(Tags.ExitLock), "the crate chain holds the roof's exit")
					t.eq(chain:GetAttribute(W.Locked), true, "locked")
				end
				continue
			end
			t.truthy(folder and #folder:GetChildren() == 1, spec.levelId .. " exit lock")
			if not folder then
				continue
			end
			local model = folder:GetChildren()[1] :: Model
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
			t.eq(kinds.Pour == true, spec.levelId == "Level2_ScienceHall", "Pour only on the chained door")
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
