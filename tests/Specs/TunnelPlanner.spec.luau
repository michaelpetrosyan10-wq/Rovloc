--!strict
-- TunnelPlanner / TunnelRules: every tunnel floor passes the tunnel rules (connected on foot, junction loops, the
-- crossing, crawlway and hiding-spot reach, regions and plates), the planner is deterministic, crawlways fit a crouched
-- player but never the Creature, the hide props follow the locker's conventions, the zone graph carries clearance and
-- crawl-only flags, and the runtime's teleport points sit on the tunnels' centrelines.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local HideBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.HideBuilder)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local ObjectivePlaces = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ObjectivePlaces)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)
local TunnelPlanner = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.TunnelPlanner)
local TunnelRules = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.TunnelRules)
local ZoneGraph = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Layout = LayoutSchema.LevelLayout

local W = Attributes.World
local HUNCHED = 9 -- the Creature's hunched height (CreatureRigBuilder.Metrics.HunchedHeight)

local function tunnelLayouts(): { Layout }
	local out: { Layout } = {}
	for _, layout in Builder.layouts() do
		if layout.tunnels then
			table.insert(out, layout)
		end
	end
	return out
end

local function roomsOfKind(layout: Layout, kind: Enums.RoomKind): { LayoutSchema.Room }
	local out: { LayoutSchema.Room } = {}
	for _, room in layout.rooms do
		if room.kind == kind then
			table.insert(out, room)
		end
	end
	return out
end

local function attachmentNames(model: Model): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Attachment") then
			out[d.Name] = true
		end
	end
	return out
end

return {
	["the basement is a tunnel floor, and every tunnel floor passes the rules"] = function(t: Expect)
		local layouts = tunnelLayouts()
		t.truthy(#layouts >= 1, "at least one tunnel floor")
		t.truthy(
			(Builder.getLayout("Level0_Basement") :: Layout).tunnels ~= nil,
			"the basement is built on TunnelPlanner"
		)
		for _, layout in layouts do
			local problems = LayoutSchema.validate(layout)
			for i, problem in problems do
				if i <= 10 then
					t.fail(layout.id .. ": " .. problem)
				end
			end
			t.eq(#problems, 0, layout.id .. " validates")
		end
	end,

	["the basement's measures: crossing, loops, crawlways, hiding spots"] = function(t: Expect)
		local layout = Builder.getLayout("Level0_Basement") :: Layout
		local rules = TunnelRules.rules(layout :: any)
		local m = TunnelRules.measure(layout :: any)
		t.eq(#m.unreachable, 0, "every keep-room and vestibule is reachable on foot without a crawlway")
		t.truthy(
			m.crossing >= rules.crossing[1] and m.crossing <= rules.crossing[2],
			string.format("crossing %.0f studs (%.0f s at %d studs/s)", m.crossing, m.crossing / 11, 11)
		)
		t.truthy(m.longestLoop <= rules.maxLoop, string.format("every junction on a loop <= %d", rules.maxLoop))
		t.truthy(m.junctions >= 8, string.format("%d junctions", m.junctions))
		t.truthy(
			m.crawlways >= rules.crawlways[1] and m.crawlways <= rules.crawlways[2],
			string.format("%d crawlways (%d..%d)", m.crawlways, rules.crawlways[1], rules.crawlways[2])
		)
		t.truthy(m.crawlReach <= 60, string.format("a crawlway within %.1f studs of every tunnel point", m.crawlReach))
		t.truthy(m.hideReach <= 30, string.format("a hiding spot within %.1f studs of every tunnel point", m.hideReach))
		t.truthy(#m.deadEnds <= rules.deadEndCount, "few dead ends")
		for _, dead in m.deadEnds do
			t.truthy(dead.length <= 25, dead.node .. " dead end at most 25 studs")
		end
		t.truthy(m.galleryLength >= 0.1 * m.length, "pipe galleries make up a share of the tunnels")
		-- every exit candidate stays a fair share of the longest (the route rule's 0.6)
		local worst = 0
		for _, d in m.crossingTo do
			worst = math.max(worst, d)
		end
		for id, d in m.crossingTo do
			t.truthy(d >= 0.6 * worst, id .. " is a fair exit")
		end
	end,

	["objective places keep a hiding spot within reach, walked"] = function(t: Expect)
		for _, layout in tunnelLayouts() do
			for _, place in ObjectivePlaces.places(layout) do
				local hide = ObjectivePlaces.nearestHide(layout, place)
				t.truthy(
					hide and hide.distance <= ObjectiveConfig.HideReach,
					string.format(
						"%s %s: hide %s",
						layout.id,
						place.id,
						if hide then string.format("%.1f", hide.distance) else "none"
					)
				)
			end
		end
	end,

	["the planner is deterministic"] = function(t: Expect)
		local a = Builder.getLayout("Level0_Basement") :: Layout
		local module = ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Layouts:FindFirstChild("Level0_Basement")
		t.truthy(module ~= nil, "the basement layout module")
		-- the layout module ran the planner at load; the frozen result is the plan of its fixed seed
		local tunnels = a.tunnels :: LayoutSchema.TunnelData
		t.truthy(#tunnels.nodes > 0 and #tunnels.edges > 0 and #tunnels.segments > 0, "a graph and segments")
		local ids: { [string]: boolean } = {}
		for _, room in a.rooms do
			t.falsy(ids[room.id], room.id .. " unique")
			ids[room.id] = true
		end
		-- running the same spec twice gives the same map (a small synthetic floor)
		local function spec(): TunnelPlanner.PlanSpec
			local entry: LayoutSchema.Room = {
				id = "T_Entry",
				kind = "Storage",
				rect = LayoutSchema.rect(36, 108, 24, 24),
				height = 12,
				lights = {},
			}
			local exit: LayoutSchema.Room = {
				id = "T_Exit",
				kind = "Airlock",
				rect = LayoutSchema.rect(306, 108, 14, 24),
				height = 12,
				lights = {},
			}
			return {
				levelId = "Level0_Basement",
				prefix = "T",
				seed = 7,
				height = 16,
				keepRooms = {
					{ room = entry, ports = { { side = "E", at = 120, kind = "Doorway", width = 8 } } },
					{ room = exit, ports = { { side = "W", at = 120, kind = "Airlock" } } },
				},
				entry = "T_Entry",
				exits = { "T_Exit" },
				gridX = { 70, 94, 122, 150, 174, 202, 230, 252, 276, 299 },
				gridZ = { 72, 96, 120, 146, 172 },
				style = {
					width = { 7 },
					height = { 10.5 },
					galleryWidth = 9,
					galleryHeight = { 14 },
					galleryShare = 0.1,
					galleryMin = 40,
					pitch = 24,
					jitter = 0,
					length = 800,
					deadEnds = 2,
					crawlWidth = 4,
					alcoveWidth = 5,
					alcoveDepth = 4.5,
					alcoveHeight = 8,
					lightSpacing = { 14, 18 },
					deadShare = 0.3,
					flickerShare = 0.1,
					plateLampEvery = 2,
					wall = "ConcreteDark",
					floor = "ConcreteStained",
					ceiling = "ConcreteDark",
					acoustic = "Basement",
					galleryAcoustic = "Hall",
					crawlAcoustic = "Vent",
				},
				regions = {
					{
						id = "A",
						name = "Alpha",
						x = 100,
						z = 120,
						pipe = Color3.new(1, 0, 0),
						band = Color3.new(1, 1, 1),
						grime = Color3.new(0, 0, 0),
						paint = Color3.new(1, 1, 1),
						graffiti = { "A" },
					},
					{
						id = "B",
						name = "Beta",
						x = 260,
						z = 120,
						pipe = Color3.new(0, 0, 1),
						band = Color3.new(1, 1, 1),
						grime = Color3.new(0, 0, 0),
						paint = Color3.new(1, 1, 1),
						graffiti = { "B" },
					},
				},
				rules = {
					maxLoop = 200,
					deadEndCount = 8,
					deadEndLength = 25,
					crossing = { 100, 1500 },
					crawlCrossingSeconds = 0,
					crawlways = { 1, 6 },
					crawlLength = 20,
					crawlHeight = TunnelRules.CrawlClearance,
					crawlReach = 200,
					hideReach = 30,
					objectiveHideReach = 25,
					regions = { 2, 6 },
				},
				attempts = 2,
				traps = 4,
				batteries = 2,
				clutter = 2,
				corpses = 1,
				drips = 1,
				debris = 1,
				scares = 1,
				creatureSpawns = 2,
				creatureBand = { 40, 160 },
			}
		end
		local first = TunnelPlanner.plan(spec())
		local second = TunnelPlanner.plan(spec())
		t.eq(#first.rooms, #second.rooms, "same rooms")
		t.eq(#first.doors, #second.doors, "same doors")
		t.eq(#first.anchors, #second.anchors, "same anchors")
		for i, room in first.rooms do
			local other = second.rooms[i]
			t.eq(room.id, other.id, "room order")
			t.truthy(
				room.rect.x == other.rect.x and room.rect.z == other.rect.z and room.rect.w == other.rect.w,
				room.id .. " same rect"
			)
		end
	end,

	["crawlways fit a crouched player and never the Creature"] = function(t: Expect)
		for _, layout in tunnelLayouts() do
			local crawls = roomsOfKind(layout, "Crawlway")
			t.truthy(#crawls >= 3, layout.id .. " has crawlways")
			local graph = ZoneGraph.build({ layout })
			for _, room in crawls do
				t.truthy(math.min(room.rect.w, room.rect.d) >= 3.5, room.id .. " is wide enough to crawl")
				t.truthy(math.max(room.rect.w, room.rect.d) <= 20, room.id .. " is at most 20 long")
				-- the ceiling panel hangs 0.4 under the room height; the mouths are CrawlClearance high
				t.truthy(
					LayoutSchema.roomHeight(layout, room) - 0.4 >= TunnelRules.CrawlClearance - 1e-3,
					room.id .. " head room"
				)
			end
			local mouths = 0
			for _, door in layout.doors do
				if LayoutSchema.doorCrawlOnly(layout, door) then
					mouths += 1
					t.near(
						LayoutSchema.doorHeight(door),
						TunnelRules.CrawlClearance,
						0.01,
						door.id .. " crouch height + 0.6"
					)
					t.truthy(LayoutSchema.doorWidth(door) >= 3, door.id .. " fits the 2-stud capsule")
					local found = false
					for _, edge in graph.edges do
						if edge.portalId == door.id then
							found = true
							t.truthy(edge.crawlOnly == true, door.id .. " edge is crawl-only")
							t.truthy((edge.clearance or 99) < HUNCHED, door.id .. " is lower than the hunched Creature")
						end
					end
					t.truthy(found, door.id .. " has a zone graph edge")
				end
			end
			t.eq(mouths, 2 * #crawls, layout.id .. " two mouths per crawlway")
			-- every other tunnel doorway carries its clearance and lets the hunched Creature through
			for _, edge in graph.edges do
				if edge.kind == "Doorway" and not edge.crawlOnly then
					t.truthy((edge.clearance or 0) >= HUNCHED, edge.portalId .. " lets the hunched Creature through")
				end
			end
		end
	end,

	["regions, plates and stencils"] = function(t: Expect)
		for _, layout in tunnelLayouts() do
			local tunnels = layout.tunnels :: LayoutSchema.TunnelData
			t.truthy(#tunnels.regions >= 4 and #tunnels.regions <= 6, layout.id .. " has 4-6 regions")
			local pipes: { [string]: boolean } = {}
			for _, region in tunnels.regions do
				local key = string.format("%.2f,%.2f,%.2f", region.pipe.R, region.pipe.G, region.pipe.B)
				t.falsy(pipes[key], region.name .. " has its own pipe colour")
				pipes[key] = true
				t.truthy(#region.graffiti >= 2, region.name .. " has its own graffiti")
				t.truthy(#region.rooms >= 1, region.name .. " holds tunnels")
			end
			local kinds: { [string]: number } = {}
			for _, landmark in tunnels.landmarks do
				kinds[landmark.kind] = (kinds[landmark.kind] or 0) + 1
				t.truthy(math.abs(landmark.normal.Magnitude - 1) < 1e-3, landmark.id .. " faces into its room")
			end
			for _, kind in { "JunctionPlate", "RegionSign", "Lore", "Arrow", "Tally" } do
				t.truthy((kinds[kind] or 0) >= 1, layout.id .. " has " .. kind .. " landmarks")
			end
			local plates = 0
			for _, node in tunnels.nodes do
				if node.kind == "Junction" then
					plates += 1
					t.truthy(node.plate and string.match(node.plate, "^J%-%d%d$") ~= nil, node.id .. " plate J-NN")
				end
			end
			t.eq(kinds.JunctionPlate, plates, layout.id .. " a plate per junction")
		end
	end,

	["teleport points ride the tunnel centrelines, never in a crawlway or a doorway"] = function(t: Expect)
		for _, layout in tunnelLayouts() do
			local points = TunnelRules.teleportPoints(layout :: any)
			local rooms = LayoutSchema.indexRooms(layout)
			t.truthy(#points >= 100, string.format("%s has %d teleport points", layout.id, #points))
			for _, point in points do
				local room = rooms[point.zone]
				t.truthy(room and (room.kind == "Tunnel" or room.kind == "Gallery"), point.zone .. " is a tunnel")
				if room then
					t.truthy(
						LayoutSchema.rectContains(room.rect, point.pos.X, point.pos.Z),
						point.zone .. " holds its point"
					)
				end
				t.truthy(#point.facings == 2, "two facings along the tunnel")
				t.truthy(point.region ~= "", "a region")
			end
		end
	end,

	["barrels and cabinets follow the locker's conventions"] = function(t: Expect)
		local holder = Instance.new("Folder")
		local random = Random.new(3)
		local spec: HideBuilder.HideSpec = {
			cframe = CFrame.new(10, 0, 10),
			anchorId = "Spec_Hide",
			levelId = "Level0_Basement",
			zoneId = "Z",
			number = 4,
		}
		local models: { [string]: Model } = {
			Barrel = HideBuilder.buildBarrel(holder, spec, random),
			Cabinet = HideBuilder.buildCabinet(holder, spec, random),
		}
		for kind, model in models do
			t.eq(model:GetAttribute(W.HideKind), kind, kind .. " HideKind")
			t.truthy(model:HasTag(Tags.Hideable), kind .. " is Hideable")
			t.eq(model:GetAttribute(W.DoorOpen), false, kind .. " starts shut")
			local names = attachmentNames(model)
			for _, name in { "EntryAnchor", "ExitAnchor", "HideAnchor", "PeekAnchor", "HidePrompt" } do
				t.truthy(names[name], kind .. " " .. name)
			end
			local leaf = if kind == "Barrel" then "Lid" else "Door"
			t.truthy(model:FindFirstChild(leaf) ~= nil, kind .. " leaf " .. leaf)
			t.truthy(
				names[leaf .. "Rest"] and names[leaf .. "Open"] and names[leaf .. "Landing"],
				kind .. " leaf poses"
			)
			local prompt: ProximityPrompt? = nil
			for _, d in model:GetDescendants() do
				if d:IsA("ProximityPrompt") then
					prompt = d
				end
			end
			t.truthy(prompt and prompt.Name == "Hide", kind .. " has a Hide prompt")
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") then
					t.truthy(d.Anchored, d.Name .. " anchored")
				end
			end
		end
		holder:Destroy()
	end,

	["barrels and cabinets stand free in their niches, the hider stepping out to a side"] = function(t: Expect)
		-- the builder: a side exit sits off the prop's side, looking out that way
		local holder = Instance.new("Folder")
		local exits: { "Left" | "Right" } = { "Left", "Right" }
		for _, exit in exits do
			local sign = if exit == "Left" then -1 else 1
			local spec: HideBuilder.HideSpec = {
				cframe = CFrame.new(10, 0, 10),
				anchorId = "Spec_" .. exit,
				levelId = "Level0_Basement",
				zoneId = "Z",
				number = 1,
				exit = exit :: "Left" | "Right",
			}
			local models: { [string]: Model } = {
				Barrel = HideBuilder.buildBarrel(holder, spec, Random.new(1)),
				Cabinet = HideBuilder.buildCabinet(holder, spec, Random.new(1)),
			}
			for kind, model in models do
				local anchor = model:FindFirstChild("ExitAnchor", true)
				t.truthy(anchor and anchor:IsA("Attachment"), kind .. " ExitAnchor")
				if anchor and anchor:IsA("Attachment") then
					local world = PropKit.attachmentWorld(anchor)
					local half = (HideBuilder.Footprints :: any)[kind].X / 2
					t.truthy(
						(world.Position.X - 10) * sign >= half + 1,
						string.format("%s %s exit %.2f off the side", kind, exit, (world.Position.X - 10) * sign)
					)
					t.truthy(world.LookVector:Dot(Vector3.xAxis * sign) > 0.99, kind .. " exit looks out that way")
					t.near(world.Position.Y, 0, 0.01, kind .. " exit on the floor")
				end
			end
		end
		holder:Destroy()
		-- the basement: most hides stand free, each side exit a stud clear of its room's walls
		local layout = Builder.getLayout("Level0_Basement") :: Layout
		local rooms = LayoutSchema.indexRooms(layout)
		local free, total = 0, 0
		for _, a in layout.anchors do
			if a.kind ~= "Barrel" and a.kind ~= "Cabinet" then
				continue
			end
			total += 1
			local exit = a.exit
			if not exit then
				continue
			end
			free += 1
			local yaw = math.rad(a.yaw or 0)
			local right = Vector3.new(math.cos(yaw), 0, -math.sin(yaw))
			local half = (HideBuilder.Footprints :: any)[a.kind].X / 2
			local p = a.pos + right * (if exit == "Left" then -1 else 1) * (half + 1.3)
			local r = rooms[a.room].rect
			local margin = WorldConfig.WallThickness / 2 + 1
			t.truthy(
				p.X >= r.x + margin and p.X <= r.x + r.w - margin and p.Z >= r.z + margin and p.Z <= r.z + r.d - margin,
				string.format("%s side exit (%.1f, %.1f) clear inside %s", a.id, p.X, p.Z, a.room)
			)
		end
		t.truthy(free >= 0.75 * total, string.format("%d of %d hides stand free", free, total))
	end,

	["the footprint and the moved towers"] = function(t: Expect)
		t.eq(WorldConfig.FootprintSize, Vector2.new(400, 288), "the 400 x 288 school")
		local openings: { [string]: { number } } = {}
		for id, tower in WorldConfig.Towers do
			t.near(tower.maxZ - tower.minZ, 32, 1e-6, id .. " keeps its depth")
			t.near(tower.maxX - tower.minX, 28, 1e-6, id .. " keeps its width")
			t.truthy(tower.minX == -28 or tower.minX == 400, id .. " stands against a side wall")
			openings[tower.side] = openings[tower.side] or {}
			table.insert(openings[tower.side], tower.openingZ)
		end
		for side, list in openings do
			table.sort(list)
			t.eq(table.concat(list, ","), "28,144,260", side .. " openings spread over the depth")
		end
		-- the basement's three exit vestibules meet the east towers' openings
		local layout = Builder.getLayout("Level0_Basement") :: Layout
		local rooms = LayoutSchema.indexRooms(layout)
		for _, spec in WorldConfig.stairwellCandidates("Level0_Basement") do
			local room = rooms[spec.fromRoom]
			local tower = WorldConfig.Towers[spec.tower]
			t.truthy(
				room and room.rect.x + room.rect.w == tower.minX,
				spec.fromRoom .. " against the " .. spec.tower .. " tower"
			)
			t.truthy(
				room and room.rect.z < tower.openingZ - 3 and room.rect.z + room.rect.d > tower.openingZ + 3,
				spec.fromRoom .. " spans the opening"
			)
		end
	end,
}
