-- Rovloc Web: export the real Roblox world, built by the game's own builders in the Lune harness, to JSON.
--
--   cd web && lune run tools/export-world.luau [out.json]      (default build/cache/world-raw.json)
--
-- The place is built fresh with `rojo build` (default.project.json), then this script does what a real run does at
-- the fixed seed RunSeed = 20251029 on Standard difficulty:
--   * WorldService.Start: ProceduralWorldBuilder.BuildAuthoritative() (lobby, the four school levels of
--     WorldConfig.LevelOrder with their statics, stair towers, exterior) and the LightingRig baseline;
--   * WorldService.BeginRun: the director's plan (RunDirector.plan over ZoneGraph.build) -> BuildProp for every
--     planned prop and BuildFixtures for every school level (grates in both looks, doors, gate, lockers, crate, the
--     floor objectives' stations and locks) into Workspace.Runtime; plus a prop on every other candidate anchor a run
--     may pick (every floor objective's item candidates, every TrapCandidate and BatteryCandidate: attribute
--     Planned = false), so the web picks per run by showing the props on its picks;
--   * the client's CosmeticWorldController: BuildCosmetic (skyline + anchor dressing);
--   * the Creature rig (CreatureRigBuilder) at the origin, for the rig export;
--   * the client LightingController's moonlight windows (Volumetrics.windowSpecs) for every layout.
-- Everything the web build needs is written as plain JSON (CFrames as 12 numbers x,y,z,R00..R22, colours as 0..1
-- floats, enums by name). web/tools/bake.mjs turns it into the packed runtime data (see web/DATA.md).
--
-- The shared rules, generically: every module of ReplicatedStorage.Shared.Config and .Rules with an exportMeta() lands
-- in world-raw.json `configs` (the bake puts each in world.json meta) under its name with a lower-case first letter
-- (meta.stageConfig, meta.livesConfig, ...), and every golden() lands in build/cache/golden.json as
-- { [moduleName]: rows }. A new module is picked up by its own exportMeta / golden; nothing here names it.
--
-- The same world as a live Roblox server's: every seeded choice of the builders, the layouts and RunDirector draws from
-- Shared/Util/Rng (pure Luau, the same numbers in Lune and on Roblox), and everything built is seeded from the
-- builder's world seed, never a run's (a run varies only its plan: the web replays RunDirector's picks with the same
-- generator, web/src/game/worldData.js), so a prop or fixture exported here is the one a live run builds there. Every
-- choice, count, name, attribute and part colour (written on the 8-bit grid a part stores) is the server's exactly;
-- positions match to within the engines' float rounding, at most 2e-4 studs (Roblox stores CFrames in float32 and
-- inverts a rotation by transposing it, Lune stores them to 1/65536 and inverts the full matrix), and no build decision
-- turns on a difference that small.

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local Harness = require("../../tools/lune/harness")

local RUN_SEED = 20251029
local DIFFICULTY = "Standard"

local repo = if fs.isDir("../src") and fs.isFile("../default.project.json") then ".." else "."
local outPath = process.args[1]
	or (if repo == ".." then "build/cache/world-raw.json" else "web/build/cache/world-raw.json")
local cacheDir = string.match(outPath, "^(.*)/[^/]+$") or "."
fs.writeDir(cacheDir)
local placePath = cacheDir .. "/rovloc-export.rbxl"

local started = os.clock()
local build = process.exec("rojo", { "build", repo .. "/default.project.json", "-o", placePath })
if not build.ok then
	print(build.stderr)
	process.exit(2)
end

local h = Harness.load(placePath, { server = true })
local game = h.game
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local Builder = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder")
local Enums = h.require("ReplicatedStorage.Shared.Enums")
local Instances = h.require("ReplicatedStorage.Shared.Instances")
local LightingMood = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LightingMood")
local LightingRig = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LightingRig")
local FixtureGlow = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder.FixtureGlow")
local Palette = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Palette")
local TextureAssets = h.require("ReplicatedStorage.Shared.Config.TextureAssets")
local WorldConfig = h.require("ReplicatedStorage.Shared.Config.WorldConfig")
local ZoneGraph = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph")
local VentGraph = h.require("ReplicatedStorage.Shared.Vents.VentGraph")
local CreatureConfig = h.require("ReplicatedStorage.Shared.Config.CreatureConfig")
local CreatureRigBuilder = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder.CreatureRigBuilder")
local RunDirector = h.require("ReplicatedStorage.Shared.World.RunDirector")
local Volumetrics = h.require("ReplicatedStorage.Shared.World.Volumetrics")

--------------------------------------------------------------------------------
-- Build exactly what a run builds
--------------------------------------------------------------------------------

local result = Builder.BuildAuthoritative({ parent = Workspace, yieldEvery = 0 })
Builder.ApplyLighting()
Instances.ensureRuntime()

local layouts = Builder.layouts()
local plan = RunDirector.plan(RUN_SEED, DIFFICULTY, layouts, ZoneGraph.build(layouts))
for _, prop in plan.props do
	local built = Builder.BuildProp(prop, Instances.runtimeLevel(prop.levelId, true))
	if built then
		built:SetAttribute("Planned", true)
	end
end
for _, levelId in WorldConfig.LevelOrder do
	Builder.BuildFixtures(levelId, Instances.runtimeLevel(levelId, true), plan)
end

local cosmetic = roblox.Instance.new("Folder")
cosmetic.Name = "Cosmetic"
cosmetic.Parent = Workspace
Builder.BuildCosmetic(cosmetic)

local rigFolder = roblox.Instance.new("Folder")
rigFolder.Name = "RigExport"
local creatureRig = Builder.BuildRig("Creature", rigFolder, roblox.CFrame.new(0, 0, 0))

print(string.format("built the world in %.2fs (%d parts)", os.clock() - started, result.partCount))

--------------------------------------------------------------------------------
-- Value conversion
--------------------------------------------------------------------------------

local function r4(x: number): number
	if x ~= x or x == math.huge or x == -math.huge then
		return 0
	end
	return math.floor(x * 10000 + 0.5) / 10000
end

local function r6(x: number): number
	return math.floor(x * 1000000 + 0.5) / 1000000
end

local function cf(c): { number }
	local x, y, z, a, b, c2, d, e, f, g, hh, i = c:GetComponents()
	return { r4(x), r4(y), r4(z), r6(a), r6(b), r6(c2), r6(d), r6(e), r6(f), r6(g), r6(hh), r6(i) }
end

local function v3(v): { number }
	return { r4(v.X), r4(v.Y), r4(v.Z) }
end

local function c3(c): { number }
	return { r4(c.R), r4(c.G), r4(c.B) }
end

-- A part's colour as the engine keeps it. Roblox stores BasePart.Color as Color3uint8 and Lune as floats, so the
-- builders write every part colour on the 8-bit grid (MathUtil.color8): stored exactly by both, and the bake's 8-bit
-- rounding lands on the same byte. A colour off the grid could round differently in the engine than in the bake (and
-- read back differently in a builder), so the export refuses the world (listed, exit 3).
local offGrid: { string } = {}
local offGridCount = 0
local function partColor(part): { number }
	local c = part.Color
	for _, v in { c.R, c.G, c.B } do
		if math.abs(v * 255 - math.round(v * 255)) > 1e-3 then
			offGridCount += 1
			if #offGrid < 20 then
				table.insert(offGrid, string.format("%s %s", part:GetFullName(), tostring(c)))
			end
			break
		end
	end
	return c3(c)
end

-- Any Luau / Roblox value -> JSON-safe value (tables recursively; Vector3/CFrame/Color3/... as arrays; enums by name).
local function toJson(value: any, depth: number?): any
	local d = depth or 0
	if d > 24 then
		return nil
	end
	local kind = typeof(value)
	if kind == "number" then
		return r6(value)
	elseif kind == "string" or kind == "boolean" or kind == "nil" then
		return value
	elseif kind == "Vector3" then
		return v3(value)
	elseif kind == "Vector2" then
		return { r4(value.X), r4(value.Y) }
	elseif kind == "CFrame" then
		return cf(value)
	elseif kind == "Color3" then
		return c3(value)
	elseif kind == "EnumItem" then
		return value.Name
	elseif kind == "UDim2" then
		return { r6(value.X.Scale), r4(value.X.Offset), r6(value.Y.Scale), r4(value.Y.Offset) }
	elseif kind == "UDim" then
		return { r6(value.Scale), r4(value.Offset) }
	elseif kind == "NumberRange" then
		return { r4(value.Min), r4(value.Max) }
	elseif kind == "ColorSequence" then
		local out = {}
		for _, k in value.Keypoints do
			table.insert(out, { r4(k.Time), c3(k.Value) })
		end
		return out
	elseif kind == "NumberSequence" then
		local out = {}
		for _, k in value.Keypoints do
			table.insert(out, { r4(k.Time), r4(k.Value) })
		end
		return out
	elseif kind == "Instance" then
		return value:GetFullName()
	elseif kind == "table" then
		local isArray = #value > 0 or next(value) == nil
		if isArray then
			local out = {}
			for i, item in ipairs(value) do
				out[i] = toJson(item, d + 1)
			end
			if #out == 0 and next(value) ~= nil then
				isArray = false
			else
				return out
			end
		end
		local out = {}
		for key, item in pairs(value) do
			-- functions are code, not data (their tostring is an address: the export would differ run to run)
			if type(item) ~= "function" then
				out[tostring(key)] = toJson(item, d + 1)
			end
		end
		return out
	end
	if kind == "function" then
		return nil
	end
	return tostring(value)
end

local function attributes(instance): { [string]: any }
	local out = {}
	for key, value in instance:GetAttributes() do
		out[key] = toJson(value)
	end
	return out
end

local function tagsOf(instance): { string }
	local seen = {}
	local out = {}
	for _, tag in instance:GetTags() do
		if not seen[tag] then
			seen[tag] = true
			table.insert(out, tag)
		end
	end
	table.sort(out)
	return out
end

local function tryPivot(model)
	local ok, pivot = pcall(function()
		return model.WorldPivot
	end)
	if ok and pivot then
		return pivot
	end
	local primary = model.PrimaryPart
	if primary then
		return primary.CFrame
	end
	return nil
end

--------------------------------------------------------------------------------
-- Floor objectives (built before the entity roots are collected)
--------------------------------------------------------------------------------

-- Floor objectives. A run builds only its seed's picks; the web picks per run with the same rule, so every candidate
-- is exported: attribute Planned is true on this seed's picks and false on the rest (hide them). A floor without an
-- item (a plain crossing) has no candidates.
local ObjectiveConfig = h.require("ReplicatedStorage.Shared.Config.ObjectiveConfig")
local ObjectivePlaces = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ObjectivePlaces")
-- The floors of the levels the world builds (ObjectiveConfig's every row, the city's too, is meta.objectiveConfig).
local builtFloors = {}
for _, spec in ObjectiveConfig.Floors do
	if Builder.getLayout(spec.levelId) then
		table.insert(builtFloors, spec)
	end
end
local objectiveData = {
	floors = toJson(builtFloors),
	hideReach = ObjectiveConfig.HideReach,
	-- a guarded item's guard and standing spot (ObjectivePlaces.carelessWalk and standingSpot: the guard traps' rules,
	-- see web/DATA.md)
	stand = {
		near = ObjectivePlaces.StandNear,
		reach = ObjectivePlaces.StandReach,
		trapClear = ObjectivePlaces.TrapClear,
		panReach = r6(ObjectivePlaces.PanReach),
		panCore = r6(ObjectivePlaces.PanCore),
		promptReach = ObjectivePlaces.PromptReach,
		approachRun = ObjectivePlaces.ApproachRun,
		body = ObjectivePlaces.BodyRadius,
		step = ObjectivePlaces.StepHeight,
		eye = ObjectivePlaces.StandEye,
		bodyHeight = ObjectivePlaces.BodyHeight,
	},
	-- the fairness and spread rules RunDirector.pickObjective applies (see web/DATA.md)
	rules = {
		entryClearance = ObjectiveConfig.EntryClearance,
		pickSpacing = ObjectiveConfig.PickSpacing,
		pickQuarters = ObjectiveConfig.PickQuarters,
		pickAttempts = RunDirector.PickAttempts,
		footprint = toJson(WorldConfig.FootprintSize),
	},
	levels = {},
}
for _, spec in builtFloors do
	local layout = Builder.getLayout(spec.levelId)
	local parent = Instances.runtimeLevel(spec.levelId, true)
	local picks = plan.objectives and plan.objectives[spec.levelId]
	local picked = {}
	for slot, id in (if picks then picks.anchors else {}) do
		picked[id] = slot
	end
	local candidates = {}
	local item = spec.item
	for _, anchor in (if item then layout.anchors else {}) do
		if anchor.kind ~= item.candidate then
			continue
		end
		local name = item.prop .. "_" .. anchor.id
		if not picked[anchor.id] then
			-- exactly the prop a run that picks this anchor builds (RunDirector.objectiveProp, the plan's own): its
			-- variant and look are the anchor's
			Builder.BuildProp(RunDirector.objectiveProp(layout, spec, anchor), parent)
		end
		local model = parent:FindFirstChild(name)
		if model then
			model:SetAttribute("Planned", picked[anchor.id] ~= nil)
		end
		local place = { id = anchor.id, kind = anchor.kind, room = anchor.room, pos = anchor.pos }
		local hide = ObjectivePlaces.nearestHide(layout, place)
		-- a guarded item: the careless walk in its guard lies on, where a careful player stands to take it and the walk
		-- there round every trap spot
		local approach = if item.guarded then ObjectivePlaces.carelessWalk(layout, anchor) else nil
		local stand = if item.guarded then ObjectivePlaces.standingSpot(layout, anchor) else nil
		table.insert(candidates, {
			anchorId = anchor.id,
			room = anchor.room,
			ref = anchor.ref,
			pos = toJson(anchor.pos),
			planned = picked[anchor.id] ~= nil,
			entryDistance = math.floor(ObjectivePlaces.entryDistance(layout, place) * 10 + 0.5) / 10,
			quarter = ObjectivePlaces.quarter(anchor.pos),
			hide = if hide
				then { kind = hide.kind, id = hide.id, distance = math.floor(hide.distance * 10 + 0.5) / 10 }
				else nil,
			eligible = table.find(RunDirector.objectiveCandidates(layout, spec), anchor) ~= nil,
			careless = if approach
				then { door = approach.door, walks = toJson(approach.walks), guardGap = toJson(approach.guardGap) }
				else nil,
			stand = if stand
				then {
					pos = toJson(stand.pos),
					reach = toJson(stand.reach),
					trapClear = toJson(stand.trapClear),
					path = toJson(stand.path),
				}
				else nil,
		})
	end
	local entryPoint = ObjectivePlaces.entryPoint(layout)
	local places = {}
	for _, place in ObjectivePlaces.places(layout) do
		local hide = ObjectivePlaces.nearestHide(layout, place)
		table.insert(places, {
			id = place.id,
			kind = place.kind,
			room = place.room,
			pos = toJson(place.pos),
			hide = if hide
				then { kind = hide.kind, id = hide.id, distance = math.floor(hide.distance * 10 + 0.5) / 10 }
				else nil,
		})
	end
	objectiveData.levels[spec.levelId] = {
		floor = spec.floor,
		id = spec.id,
		entry = { room = layout.entry, pos = toJson(entryPoint) },
		-- every way in (the entry room and each entry vestibule candidate): entryDistance is walked from the nearest
		entries = (function()
			local out = {}
			for _, entry in ObjectivePlaces.entries(layout) do
				table.insert(out, { room = entry.room, pos = toJson(entry.pos) })
			end
			return out
		end)(),
		candidates = candidates,
		picks = if picks then toJson(picks) else nil,
		places = places,
	}
end

--------------------------------------------------------------------------------
-- Plan props: one on every candidate anchor a run may pick
--------------------------------------------------------------------------------

-- A run picks which TrapCandidate / BatteryCandidate anchors hold a prop, but a prop's look is its
-- anchor's own (RunDirector.plannedProp: the variant and Builder.propRandom take no run seed), so the web keeps one
-- entity per candidate anchor, exactly the prop a live run builds there, and shows a run's picks
-- (worldData.plan replays RunDirector's draws). Attribute Planned: this seed's Standard picks.
local DifficultyConfig = h.require("ReplicatedStorage.Shared.Config.DifficultyConfig")
do
	local planned: { [string]: boolean } = {}
	for _, prop in plan.props do
		planned[prop.kind .. "|" .. prop.anchorId] = true
	end
	local trapLayout = Builder.getLayout(RunDirector.TrapLevel)
	local sets = {
		{
			kind = RunDirector.PropKinds.BearTrap,
			candidate = "TrapCandidate",
			levels = { RunDirector.TrapLevel },
			-- RunDirector never arms a trap in these (airlocks, the entry and exit rooms, spawn rooms)
			skip = RunDirector.trapExcludedRooms(trapLayout),
			most = 0,
		},
		{
			kind = RunDirector.PropKinds.Battery,
			candidate = "BatteryCandidate",
			levels = WorldConfig.LevelOrder,
			skip = {},
			most = 0,
		},
	}
	for _, name in Enums.Difficulty do
		local spec = DifficultyConfig[name]
		if spec then
			sets[1].most = math.max(sets[1].most, spec.trapCount)
			sets[2].most = math.max(sets[2].most, spec.batteriesPerLevel)
		end
	end
	for _, set in sets do
		local count, picked = 0, 0
		for _, levelId in set.levels do
			local layout = Builder.getLayout(levelId)
			local parent = Instances.runtimeLevel(levelId, true)
			for _, anchor in layout.anchors do
				if anchor.kind ~= set.candidate or set.skip[anchor.room] then
					continue
				end
				count += 1
				if planned[set.kind .. "|" .. anchor.id] then
					picked += 1
					continue
				end
				local built = Builder.BuildProp(RunDirector.plannedProp(set.kind, layout, anchor), parent)
				if built then
					built:SetAttribute("Planned", false)
				end
			end
		end
		print(
			string.format(
				"%s entities: %d, one per candidate anchor (%d this seed's picks; a run needs at most %d per level)",
				set.kind,
				count,
				picked,
				set.most
			)
		)
	end
end

--------------------------------------------------------------------------------
-- Routes: every candidate stairwell per floor pair, the jam state, the pick rule
--------------------------------------------------------------------------------

-- Every stairwell door (fire doors, roof housing doors) carries StairwellId / RouteSlot / RouteRole / Jammed (this
-- seed's route) and the leaf "Jam" (the collapse behind it). The web picks a route per run, so every Jam leaf is
-- exported with its geometry shown; the web hides it on the run's used doors and shuts + locks the others.
local DoorBuilder = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.DoorBuilder")
for _, levelId in WorldConfig.LevelOrder do
	for _, child in Instances.runtimeLevel(levelId, true):GetDescendants() do
		if child:IsA("Model") and child:GetAttribute("StairwellId") ~= nil then
			DoorBuilder.showJam(child, true)
		end
	end
end

-- Every grate is built in both looks over the same boxes (VentGrateBuilder: galvanized, and rusted shut in sub-Models
-- "Rusted" of the grate, its panel and each screw) and this seed's plan shows one (setLocked). The web locks grates per
-- run, so both looks are exported shown; the web shows the one each run's plan picks (src/game/mechanics/vents.js).
local VentGrateBuilder = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.VentGrateBuilder")
for _, levelId in WorldConfig.LevelOrder do
	for _, child in Instances.runtimeLevel(levelId, true):GetDescendants() do
		if child:IsA("Model") and child:HasTag("VentGrate") then
			assert(VentGrateBuilder.showLook(child, "Galvanized", true), child.Name .. ": no galvanized look")
			assert(VentGrateBuilder.showLook(child, "Rusted", true), child.Name .. ": no rusted look")
		end
	end
end

local layoutById = {}
for _, layout in layouts do
	layoutById[layout.id] = layout
end
local function doorsInto(layout, roomId: string, kinds: { [string]: boolean }): { string }
	local out = {}
	for _, door in layout.doors do
		if kinds[door.kind] and table.find(door.rooms, roomId) then
			table.insert(out, door.id)
		end
	end
	return out
end
local function anchorsIn(layout, kind: string, roomId: string): { string }
	local out = {}
	for _, anchor in layout.anchors do
		if anchor.kind == kind and anchor.room == roomId then
			table.insert(out, anchor.id)
		end
	end
	table.sort(out)
	return out
end
local function triggerIn(layout, kind: string, roomId: string): string?
	for _, trigger in layout.triggers do
		if trigger.kind == kind and trigger.room == roomId then
			return trigger.id
		end
	end
	return nil
end
local LockBuilder = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.LockBuilder")
local function exitLockOf(layout, doorIds: { string }): string?
	for _, anchor in layout.anchors do
		if anchor.kind == "ExitLock" then
			local face = LockBuilder.doorFace(layout, anchor)
			if face and table.find(doorIds, face.doorId) then
				return anchor.id
			end
		end
	end
	return nil
end
local round1 = function(x: number): number
	return if x == math.huge then -1 else math.floor(x * 10 + 0.5) / 10
end

local routeData = {} -- { [from level] = { candidate } }: the shape worldData.routeCandidates consumes
local routePairs = {}
local routeChecks = {}
local planRoute = plan.route or {}
for _, from in WorldConfig.LevelOrder do
	local candidates = WorldConfig.stairwellCandidates(from)
	local lower = layoutById[from]
	if #candidates == 0 or not lower then
		continue
	end
	local list = {}
	local ids = {}
	for _, spec in candidates do
		local upper = layoutById[spec.to]
		local exitDoorIds = doorsInto(lower, spec.fromRoom, { Airlock = true })
		table.insert(ids, spec.id)
		table.insert(list, {
			id = spec.id,
			stairwellId = spec.id,
			pair = spec.pair,
			slot = spec.slot,
			tower = spec.tower,
			from = spec.from,
			to = spec.to,
			fromRoom = spec.fromRoom,
			toRoom = spec.toRoom,
			exitDoorIds = exitDoorIds,
			entryDoorIds = doorsInto(upper, spec.toRoom, { Airlock = true, RoofDoor = true }),
			checkpoint = triggerIn(lower, "Checkpoint", spec.fromRoom),
			spawns = anchorsIn(upper, "PlayerSpawn", spec.toRoom),
			exitLock = exitLockOf(lower, exitDoorIds),
			creatureSpawn = (anchorsIn(upper, "CreatureSpawn", spec.toRoom))[1],
			picked = planRoute[from] == spec.id,
		})
	end
	routeData[from] = list
	table.insert(routePairs, {
		pair = candidates[1].pair,
		from = from,
		to = candidates[1].to,
		candidates = ids,
		picked = planRoute[from],
	})
	-- the fairness verdicts for every way in to the floor (its entry room and every entry vestibule candidate)
	local byEntry = {}
	for _, entry in ObjectivePlaces.entries(lower) do
		local checks = {}
		for _, check in RunDirector.routeChecks(lower, entry.room, layoutById) do
			table.insert(checks, {
				stairwellId = check.stairwellId,
				distance = round1(check.distance),
				share = math.floor(check.share * 1000 + 0.5) / 1000,
				creatureSpawns = check.creatureSpawns,
				fair = check.fair,
			})
		end
		byEntry[entry.room] = checks
	end
	routeChecks[from] = byEntry
end
local routeRule = {
	stream = "Route|<from>",
	order = "candidates in slot order North, Middle, South (meta.routes[from])",
	draw = "NextInteger(1, #candidates) per draw from Rng.seeded(seed, 'Route|' .. from)",
	attempts = RunDirector.RouteAttempts,
	fallback = "the first fair candidate in slot order, else the Middle one",
	entry = "Level0 starts at its layout entry; every later floor at the previous pick's toRoom",
	fairShare = RunDirector.RouteFairShare,
	creatureBand = toJson(RunDirector.CreatureBand),
	minCreatureSpawns = RunDirector.MinCreatureSpawns,
	creatureSpawnLevels = toJson(RunDirector.CreatureSpawnLevels),
	checks = routeChecks,
}

--------------------------------------------------------------------------------
-- Classification
--------------------------------------------------------------------------------

local school = Workspace:FindFirstChild("School")
local lobby = Workspace:FindFirstChild("Lobby")
local runtime = Workspace:FindFirstChild("Runtime")

local LEVEL_IDS = WorldConfig.LevelOrder
local ROOF = LEVEL_IDS[#LEVEL_IDS]

-- The level key a world position belongs to (cosmetic dressing and skyline are placed by position).
local function levelForPosition(p): string
	if p.X < -400 then
		return "Lobby"
	end
	local size = WorldConfig.FootprintSize
	local inFootprint = p.X >= -0.5 and p.X <= size.X + 0.5 and p.Z >= -0.5 and p.Z <= size.Y + 0.5
	if not inFootprint then
		local inTower = false
		for _, tower in WorldConfig.Towers do
			if p.X >= tower.minX and p.X <= tower.maxX and p.Z >= tower.minZ and p.Z <= tower.maxZ then
				inTower = true
			end
		end
		if inTower and p.Y < WorldConfig.Levels[ROOF].elevation then
			return "Stairwells"
		end
		if
			p.Y > WorldConfig.Levels[ROOF].elevation - 2
			and p.X > -40
			and p.X < size.X + 40
			and p.Z > -40
			and p.Z < size.Y + 40
		then
			return ROOF
		end
		return "Exterior"
	end
	local best = LEVEL_IDS[1]
	for _, id in LEVEL_IDS do
		if p.Y >= WorldConfig.Levels[id].elevation - 1.0 then
			best = id
		end
	end
	return best
end

-- Entity roots: everything a run rebuilds in Workspace.Runtime (a Model, or each Model in a Folder there), plus
-- the lobby's interactive pieces (terminals, ready pads).
local entityRoots: { { root: Instance, level: string } } = {}
local entityOfRoot: { [Instance]: number } = {}

local function addEntityRoot(instance, level)
	if entityOfRoot[instance] then
		return
	end
	table.insert(entityRoots, { root = instance, level = level })
	entityOfRoot[instance] = #entityRoots
end

if runtime then
	for _, levelFolder in runtime:GetChildren() do
		for _, child in levelFolder:GetChildren() do
			if child:IsA("Model") or child:IsA("BasePart") then
				addEntityRoot(child, levelFolder.Name)
			elseif child:IsA("Folder") then
				for _, inner in child:GetChildren() do
					if inner:IsA("Model") or inner:IsA("BasePart") then
						addEntityRoot(inner, levelFolder.Name)
					end
				end
			end
		end
	end
end
if lobby then
	local props = lobby:FindFirstChild("Props")
	if props then
		-- a ready pad is three loose parts (ReadyPad_<id>, _Ring, _Lamp): one entity rooted at the pad
		local pads = {}
		for _, child in props:GetChildren() do
			local tagged = #child:GetTags() > 0
			local isPadPiece = string.match(child.Name, "^ReadyPad_") ~= nil
			if isPadPiece then
				local base = string.gsub(string.gsub(child.Name, "_Ring$", ""), "_Lamp$", "")
				pads[base] = pads[base] or {}
				table.insert(pads[base], child)
			elseif tagged or string.match(child.Name, "^Terminal_") then
				addEntityRoot(child, "Lobby")
			end
		end
		local padNames = {}
		for base in pads do
			table.insert(padNames, base)
		end
		table.sort(padNames)
		for _, base in padNames do
			local root = props:FindFirstChild(base)
			if root then
				addEntityRoot(root, "Lobby")
				for _, piece in pads[base] do
					entityOfRoot[piece] = entityOfRoot[root]
				end
			end
		end
	end
end

local function entityIndexOf(instance): number?
	local cursor = instance
	while cursor and cursor ~= Workspace do
		local index = entityOfRoot[cursor]
		if index then
			return index
		end
		cursor = cursor.Parent
	end
	return nil
end

-- Static level key + source group for a part outside the runtime entities.
local function staticPlace(part): (string, string)
	local cursor = part
	local chain = {}
	while cursor and cursor.Parent ~= Workspace do
		table.insert(chain, 1, cursor)
		cursor = cursor.Parent
	end
	local top = cursor
	if top == lobby then
		return "Lobby", if chain[1] then chain[1].Name else "Shell"
	elseif top == school then
		local levelModel = chain[1]
		if not levelModel then
			return "Exterior", "Shell"
		end
		local name = levelModel.Name
		if name == "Stairwells" then
			return "Stairwells", "Stairwells"
		elseif name == "Exterior" then
			return "Exterior", "Exterior"
		end
		return name, if chain[2] then chain[2].Name else "Shell"
	elseif top == cosmetic then
		local group = if chain[1] then chain[1].Name else "Dressing"
		if group == "Skyline" then
			return "Exterior", "Skyline"
		end
		return levelForPosition(part.CFrame.Position), "Dressing"
	end
	return levelForPosition(part.CFrame.Position), "Other"
end

--------------------------------------------------------------------------------
-- Parts
--------------------------------------------------------------------------------

local function shapeOf(part): string
	if part.ClassName == "WedgePart" then
		return "Wedge"
	elseif part.ClassName == "CornerWedgePart" then
		return "CornerWedge"
	elseif part.ClassName == "Part" then
		return part.Shape.Name
	end
	return "Block"
end

local function textureOf(part): string?
	local variant = part.MaterialVariant
	if variant == nil or variant == "" then
		return nil
	end
	local texture = string.match(variant, "^Rovloc(.+)_" .. part.Material.Name .. "$")
	return texture
end

-- Fixture index of every LevelLight fixture part (glow parts point at their fixture).
local fixtures: { any } = {}
local fixtureOf: { [Instance]: number } = {}

local function fixtureIndexOf(part): number?
	local cursor = part
	while cursor and cursor ~= Workspace do
		local index = fixtureOf[cursor]
		if index then
			return index
		end
		cursor = cursor.Parent
	end
	return nil
end

local lights: { any } = {}
local lightOwner: { [Instance]: BasePart } = {}

for _, d in game:GetService("Workspace"):GetDescendants() do
	if d:IsA("Light") then
		local holder = d.Parent
		local part = nil
		local localCf = roblox.CFrame.new()
		if holder and holder:IsA("Attachment") then
			part = holder.Parent
			localCf = holder.CFrame
		elseif holder and holder:IsA("BasePart") then
			part = holder
		end
		if part and part:IsA("BasePart") then
			-- the fixture: nearest ancestor part tagged LevelLight, else the holder part
			local fixture = part
			local cursor = part
			while cursor and cursor ~= Workspace do
				if cursor:IsA("BasePart") and cursor:HasTag("LevelLight") then
					fixture = cursor
					break
				end
				cursor = cursor.Parent
			end
			if fixtureOf[fixture] == nil then
				table.insert(fixtures, {
					name = fixture.Name,
					attributes = attributes(fixture),
					tags = tagsOf(fixture),
					cframe = cf(fixture.CFrame),
					size = v3(fixture.Size),
					path = fixture:GetFullName(),
				})
				fixtureOf[fixture] = #fixtures
			end
			local entry = {
				class = d.ClassName,
				name = d.Name,
				fixture = fixtureOf[fixture],
				part = part:GetFullName(),
				partCFrame = cf(part.CFrame * localCf),
				partSize = v3(part.Size),
				attached = holder:IsA("Attachment"),
				color = c3(d.Color),
				brightness = r4(d.Brightness),
				enabled = d.Enabled,
				shadows = d.Shadows,
				range = r4(d.Range),
				attributes = attributes(d),
			}
			if d:IsA("SpotLight") or d:IsA("SurfaceLight") then
				entry.angle = r4(d.Angle)
				entry.face = d.Face.Name
			end
			local entity = entityIndexOf(d)
			if entity then
				entry.entity = entity
			end
			table.insert(lights, entry)
			lightOwner[d] = part
		end
	end
end

local parts: { any } = {}
local volumes: { any } = {}
local guis: { any } = {}
local partIndex: { [Instance]: number } = {}

-- Volumes and roots never render: zones, triggers, anchor / waypoint roots, vent node roots, hitboxes. A transparent
-- part that carries a SurfaceGui is a decal host (the tunnels' paint), exported as a part for its decals.
local function isVolume(part): boolean
	return part.Transparency >= 0.999 and not part.CanCollide and part:FindFirstChildOfClass("SurfaceGui") == nil
end

-- SurfaceGui trees (frames, text, gradients, corners, strokes) for the decal baker.
local function guiNode(instance): any?
	local class = instance.ClassName
	local node: any = { class = class, name = instance.Name }
	if instance:IsA("GuiObject") then
		node.position = toJson(instance.Position)
		node.size = toJson(instance.Size)
		node.anchor = toJson(instance.AnchorPoint)
		node.rotation = r4(instance.Rotation)
		node.color = c3(instance.BackgroundColor3)
		node.transparency = r4(instance.BackgroundTransparency)
		node.z = instance.ZIndex
		node.visible = instance.Visible
		node.clips = instance.ClipsDescendants
		if instance:IsA("TextLabel") or instance:IsA("TextButton") then
			node.text = instance.Text
			node.textColor = c3(instance.TextColor3)
			node.textTransparency = r4(instance.TextTransparency)
			node.textScaled = instance.TextScaled
			node.textSize = r4(instance.TextSize)
			local okFont, font = pcall(function()
				return instance.FontFace
			end)
			if okFont and font then
				node.font = tostring(font.Family)
				node.fontWeight = tostring(font.Weight)
				node.fontStyle = tostring(font.Style)
			end
			node.xAlign = instance.TextXAlignment.Name
			node.yAlign = instance.TextYAlignment.Name
			node.wrapped = instance.TextWrapped
			node.strokeTransparency = r4(instance.TextStrokeTransparency)
			node.strokeColor = c3(instance.TextStrokeColor3)
		end
	elseif class == "UICorner" then
		node.radius = toJson(instance.CornerRadius)
	elseif class == "UIGradient" then
		node.colorSeq = toJson(instance.Color)
		node.transparencySeq = toJson(instance.Transparency)
		node.rotation = r4(instance.Rotation)
		node.offset = toJson(instance.Offset)
		node.enabled = instance.Enabled
	elseif class == "UIStroke" then
		node.color = c3(instance.Color)
		node.thickness = r4(instance.Thickness)
		node.transparency = r4(instance.Transparency)
		node.mode = instance.ApplyStrokeMode.Name
	else
		return nil
	end
	local children = {}
	for _, child in instance:GetChildren() do
		local c = guiNode(child)
		if c then
			table.insert(children, c)
		end
	end
	if #children > 0 then
		node.children = children
	end
	return node
end

local function exportPart(part, owner: any)
	if isVolume(part) then
		return
	end
	local entry: any = {
		name = part.Name,
		cf = cf(part.CFrame),
		size = v3(part.Size),
		shape = shapeOf(part),
		material = part.Material.Name,
		texture = textureOf(part),
		color = partColor(part),
		transparency = r4(part.Transparency),
		reflectance = r4(part.Reflectance),
		canCollide = part.CanCollide,
		castShadow = part.CastShadow,
		canQuery = part.CanQuery,
		group = part.CollisionGroup,
		level = owner.level,
		source = owner.source,
	}
	if owner.entity then
		entry.entity = owner.entity
	end
	if owner.creature then
		entry.creature = true
	end
	local fixture = fixtureIndexOf(part)
	if fixture then
		entry.fixture = fixture
		entry.glow = FixtureGlow.isGlowPart(part)
	end
	-- the nearest Model ancestor below the entity root (doors' leaves, locker doors, ...)
	if owner.entityRoot and part:IsDescendantOf(owner.entityRoot) then
		local cursor = part.Parent
		local chain = {}
		while cursor and cursor ~= owner.entityRoot and cursor ~= Workspace do
			if cursor:IsA("Model") then
				table.insert(chain, 1, cursor.Name)
			end
			cursor = cursor.Parent
		end
		if #chain > 0 then
			entry.node = table.concat(chain, "/")
		end
		if part.Parent and part.Parent:IsA("BasePart") then
			entry.parentPart = part.Parent.Name
		end
	end
	local tags = tagsOf(part)
	if #tags > 0 then
		entry.tags = tags
	end
	local attrs = attributes(part)
	if next(attrs) then
		entry.attributes = attrs
	end
	table.insert(parts, entry)
	partIndex[part] = #parts
	for _, child in part:GetChildren() do
		if child:IsA("SurfaceGui") then
			local nodes = {}
			for _, g in child:GetChildren() do
				local n = guiNode(g)
				if n then
					table.insert(nodes, n)
				end
			end
			table.insert(guis, {
				part = #parts,
				name = child.Name,
				face = child.Face.Name,
				pixelsPerStud = r4(child.PixelsPerStud),
				sizingMode = child.SizingMode.Name,
				lightInfluence = r4(child.LightInfluence),
				brightness = r4(child.Brightness),
				alwaysOnTop = child.AlwaysOnTop,
				enabled = child.Enabled,
				children = nodes,
			})
		end
	end
end

for _, d in Workspace:GetDescendants() do
	-- (Workspace.Terrain is a BasePart too: the place's, never part of the built world)
	if not d:IsA("BasePart") or d:IsA("Terrain") then
		continue
	end
	local entity = entityIndexOf(d)
	if entity then
		exportPart(d, {
			level = entityRoots[entity].level,
			source = "Entity",
			entity = entity,
			entityRoot = entityRoots[entity].root,
		})
	else
		local level, source = staticPlace(d)
		exportPart(d, { level = level, source = source })
	end
end

for _, d in Workspace:GetDescendants() do
	if d:IsA("BasePart") and not d:IsA("Terrain") and isVolume(d) then
		local tags = tagsOf(d)
		local attrs = attributes(d)
		if #tags > 0 or next(attrs) then
			local level = d:GetAttribute("LevelId") or levelForPosition(d.CFrame.Position)
			table.insert(volumes, {
				name = d.Name,
				path = d:GetFullName(),
				cframe = cf(d.CFrame),
				size = v3(d.Size),
				tags = tags,
				attributes = attrs,
				level = level,
				entity = entityIndexOf(d),
			})
		end
	end
end

--------------------------------------------------------------------------------
-- Attachments (anchors, waypoints, door anchors, vent nodes, grate mouths, entity attachments)
--------------------------------------------------------------------------------

local attachments: { any } = {}
for _, d in Workspace:GetDescendants() do
	if d:IsA("Attachment") then
		local parent = d.Parent
		if parent and parent:IsA("BasePart") then
			table.insert(attachments, {
				name = d.Name,
				parent = parent.Name,
				path = d:GetFullName(),
				cframe = cf(parent.CFrame * d.CFrame),
				tags = tagsOf(d),
				attributes = attributes(d),
				entity = entityIndexOf(d),
			})
		end
	end
end

--------------------------------------------------------------------------------
-- Entities
--------------------------------------------------------------------------------

local entities: { any } = {}
for index, info in entityRoots do
	local root = info.root
	local pivot = if root:IsA("Model") then tryPivot(root) else root.CFrame
	if not pivot then
		-- no pivot recorded: the first part's position, axis-aligned
		for _, d in root:GetDescendants() do
			if d:IsA("BasePart") then
				pivot = roblox.CFrame.new(d.CFrame.Position)
				break
			end
		end
	end
	local nodes = {}
	for _, d in root:GetDescendants() do
		if d:IsA("Model") then
			local chain = {}
			local cursor = d
			while cursor and cursor ~= root do
				if cursor:IsA("Model") then
					table.insert(chain, 1, cursor.Name)
				end
				cursor = cursor.Parent
			end
			local nodePivot = tryPivot(d)
			table.insert(nodes, {
				path = table.concat(chain, "/"),
				pivot = if nodePivot then cf(nodePivot) else nil,
				attributes = attributes(d),
				tags = tagsOf(d),
			})
		end
	end
	local prompts = {}
	for _, d in root:GetDescendants() do
		if d:IsA("ProximityPrompt") then
			local host = d.Parent
			table.insert(prompts, {
				name = d.Name,
				host = if host then host.Name else nil,
				hostCFrame = if host and host:IsA("BasePart")
					then cf(host.CFrame)
					elseif host and host:IsA("Attachment") and host.Parent and host.Parent:IsA("BasePart") then cf(
						host.Parent.CFrame * host.CFrame
					)
					else nil,
				actionText = d.ActionText,
				objectText = d.ObjectText,
				holdDuration = r4(d.HoldDuration),
				maxDistance = r4(d.MaxActivationDistance),
				requiresLineOfSight = d.RequiresLineOfSight,
				key = d.KeyboardKeyCode.Name,
				attributes = attributes(d),
			})
		end
	end
	table.insert(entities, {
		index = index,
		name = root.Name,
		class = root.ClassName,
		level = info.level,
		path = root:GetFullName(),
		pivot = if pivot then cf(pivot) else nil,
		primaryPart = if root:IsA("Model") and root.PrimaryPart then root.PrimaryPart.Name else nil,
		attributes = attributes(root),
		tags = tagsOf(root),
		nodes = nodes,
		prompts = prompts,
	})
end

--------------------------------------------------------------------------------
-- Graphs, layouts, lighting
--------------------------------------------------------------------------------

local ventGraphs = {}
for _, layout in layouts do
	local root = Instances.layoutRoot(layout.id)
	if root then
		local ok, graph = pcall(VentGraph.build, root, layout.id)
		if ok and graph then
			ventGraphs[layout.id] = toJson(graph)
		end
	end
end

local zoneGraph = ZoneGraph.build(layouts)

-- Tunnel floors (TunnelPlanner): the runtime's teleport points (TunnelRules.teleportPoints: tunnel and gallery
-- centrelines every 6 studs, never in a crawlway or a doorway), the landmarks (junction plates, region stencils,
-- graffiti) and the regions, per level, in world space. See web/DATA.md.
local TunnelRules = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder.TunnelRules")
local teleportPoints = {}
local landmarks = {}
local regions = {}
for _, layout in layouts do
	local tunnels = layout.tunnels
	if not tunnels then
		continue
	end
	local origin = WorldConfig.levelOrigin(layout.id)
	local points = {}
	for _, point in TunnelRules.teleportPoints(layout) do
		table.insert(points, {
			pos = v3(origin + point.pos),
			facings = point.facings,
			region = point.region,
			zone = point.zone,
		})
	end
	teleportPoints[layout.id] = points
	local marks = {}
	for _, landmark in tunnels.landmarks do
		table.insert(marks, {
			id = landmark.id,
			kind = landmark.kind,
			region = landmark.region,
			room = landmark.room,
			pos = v3(origin + landmark.pos),
			normal = v3(landmark.normal),
			text = landmark.text,
		})
	end
	landmarks[layout.id] = marks
	local list = {}
	for _, region in tunnels.regions do
		table.insert(list, {
			id = region.id,
			name = region.name,
			zones = region.rooms,
			junctions = region.junctions,
			pipe = c3(region.pipe),
			band = c3(region.band),
			wet = region.wet == true,
			medium = region.medium,
		})
	end
	regions[layout.id] = list
end

local layoutData = {}
for _, layout in layouts do
	layoutData[layout.id] = toJson(layout)
end

local windows = {}
for _, layout in layouts do
	local ok, specs = pcall(Volumetrics.windowSpecs, layout)
	if ok then
		windows[layout.id] = toJson(specs)
	end
end

local films = {}
local moods = {}
for _, layout in layouts do
	films[layout.id] = toJson(LightingMood.film(layout.id))
	moods[layout.id] = toJson(LightingMood.levelMood(layout.id))
end

local paletteData = {}
for _, key in Palette.keys() do
	local entry = Palette.get(key)
	paletteData[key] = {
		material = entry.material.Name,
		color = c3(entry.color),
		surface = entry.surface,
		texture = entry.variant,
		dressedColor = c3(Palette.colorFor(key)),
	}
end

local textureRefs = {}
for id, entry in TextureAssets do
	textureRefs[id] = { reference = if entry.reference then c3(entry.reference) else nil }
end

local lightingProps = {}
for _, name in
	{
		"ClockTime",
		"Brightness",
		"Ambient",
		"OutdoorAmbient",
		"EnvironmentDiffuseScale",
		"EnvironmentSpecularScale",
		"ExposureCompensation",
		"ShadowSoftness",
		"GeographicLatitude",
		"FogColor",
		"FogEnd",
		"FogStart",
		"ColorShift_Top",
		"ColorShift_Bottom",
	}
do
	local ok, value = pcall(function()
		return (Lighting :: any)[name]
	end)
	if ok then
		lightingProps[name] = toJson(value)
	end
end

local levelsData = {}
for _, layout in layouts do
	local spec = WorldConfig.Levels[layout.id]
	levelsData[layout.id] = {
		origin = v3(WorldConfig.levelOrigin(layout.id)),
		elevation = if spec then spec.elevation else WorldConfig.levelOrigin(layout.id).Y,
		height = if spec then spec.height else nil,
	}
end

--------------------------------------------------------------------------------
-- Creature rig
--------------------------------------------------------------------------------

local creature = nil
if creatureRig then
	local rigParts = {}
	local rigIndex = {}
	for _, d in creatureRig:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(rigParts, {
				name = d.Name,
				cf = cf(d.CFrame),
				size = v3(d.Size),
				shape = shapeOf(d),
				material = d.Material.Name,
				texture = textureOf(d),
				color = partColor(d),
				transparency = r4(d.Transparency),
				reflectance = r4(d.Reflectance),
				canCollide = d.CanCollide,
				castShadow = d.CastShadow,
				parent = if d.Parent and d.Parent:IsA("BasePart") then d.Parent.Name else nil,
				attributes = attributes(d),
				tags = tagsOf(d),
			})
			rigIndex[d] = #rigParts
		end
	end
	local joints = {}
	for _, d in creatureRig:GetDescendants() do
		if d:IsA("Motor6D") or d:IsA("Weld") or d:IsA("WeldConstraint") then
			local p0 = d.Part0
			local p1 = d.Part1
			table.insert(joints, {
				class = d.ClassName,
				name = d.Name,
				part0 = if p0 then p0.Name else nil,
				part1 = if p1 then p1.Name else nil,
				c0 = if d:IsA("WeldConstraint") then nil else cf(d.C0),
				c1 = if d:IsA("WeldConstraint") then nil else cf(d.C1),
				parent = if d.Parent then d.Parent.Name else nil,
			})
		end
	end
	local rigLights = {}
	local rigAttachments = {}
	for _, d in creatureRig:GetDescendants() do
		if d:IsA("Light") then
			local holder = d.Parent
			table.insert(rigLights, {
				class = d.ClassName,
				name = d.Name,
				parent = if holder then holder.Name else nil,
				color = c3(d.Color),
				brightness = r4(d.Brightness),
				range = r4(d.Range),
				enabled = d.Enabled,
				shadows = d.Shadows,
				angle = if d:IsA("SpotLight") or d:IsA("SurfaceLight") then r4(d.Angle) else nil,
				face = if d:IsA("SpotLight") or d:IsA("SurfaceLight") then d.Face.Name else nil,
			})
		elseif d:IsA("Attachment") then
			local parent = d.Parent
			table.insert(rigAttachments, {
				name = d.Name,
				parent = if parent then parent.Name else nil,
				cframe = cf(d.CFrame),
				attributes = attributes(d),
			})
		end
	end
	local humanoid = creatureRig:FindFirstChildOfClass("Humanoid")
	creature = {
		name = creatureRig.Name,
		attributes = attributes(creatureRig),
		primaryPart = if creatureRig.PrimaryPart then creatureRig.PrimaryPart.Name else nil,
		hipHeight = if humanoid then r4(humanoid.HipHeight) else nil,
		parts = rigParts,
		joints = joints,
		lights = rigLights,
		attachments = rigAttachments,
		config = toJson(CreatureConfig),
		-- the rig's measures for the web's behaviour (CreatureRigBuilder.Metrics; the bake lifts them into
		-- meta.creature): heights standing / hunched, eye heights per PoseMode, the catch reach, hitboxes per PoseMode
		metrics = {
			height = CreatureRigBuilder.Metrics.Height,
			hunchedHeight = CreatureRigBuilder.Metrics.HunchedHeight,
			eyeHeight = r6(CreatureRigBuilder.Metrics.EyeHeight.Biped),
			eyeHeights = toJson(CreatureRigBuilder.Metrics.EyeHeight),
			eyeHeightAboveRoot = toJson(CreatureRigBuilder.Metrics.EyeHeightAboveRoot),
			reach = CreatureRigBuilder.Metrics.Reach,
			rootHeight = r6(CreatureRigBuilder.Metrics.RootHeight),
			armLength = CreatureRigBuilder.Metrics.ArmLength,
			hitboxes = toJson(CreatureRigBuilder.Metrics.Hitboxes),
		},
	}
end

--------------------------------------------------------------------------------
-- RunDirector's plans for a spread of seeds: web/tools/data-test.mjs replays each with the web's port (worldData.plan
-- and routes, on Rng) and requires the same picks and prop variants, so a seed plays the same run on the web as
-- on a live server.
--------------------------------------------------------------------------------

local PLAN_SEEDS = { 1, 2, 3, 1029, 4242, 5150, 65537, RUN_SEED, 123456789, 2147483646 }
local runPlans: { any } = {}
for _, seed in PLAN_SEEDS do
	for _, difficulty in { "Standard", "Nightmare" } do
		local planned = RunDirector.plan(seed, difficulty, layouts, zoneGraph)
		local objectives = {}
		for levelId, picks in planned.objectives or {} do
			objectives[levelId] = { anchors = table.clone(picks.anchors), guards = table.clone(picks.guards) }
		end
		local props = {}
		for _, prop in planned.props do
			table.insert(props, {
				kind = prop.kind,
				anchorId = prop.anchorId,
				levelId = prop.levelId,
				variant = prop.variant,
			})
		end
		local locked = {}
		for id in planned.lockedGrates do
			table.insert(locked, id)
		end
		table.sort(locked)
		local batteries = {}
		for levelId, picks in planned.batteries or {} do
			batteries[levelId] = { anchors = table.clone(picks.anchors), broken = picks.broken }
		end
		local flasks = {}
		for levelId, ids in planned.flasks or {} do
			flasks[levelId] = table.clone(ids)
		end
		table.insert(runPlans, {
			seed = seed,
			difficulty = difficulty,
			objectives = objectives,
			props = props,
			lockedGrates = locked,
			route = table.clone(planned.route or {}),
			batteries = batteries,
			flasks = flasks,
		})
	end
end
fs.writeFile(cacheDir .. "/run-plans.json", serde.encode("json", runPlans, true))
print(string.format("RunDirector plans for %d seeds x 2 difficulties -> %s/run-plans.json", #PLAN_SEEDS, cacheDir))

--------------------------------------------------------------------------------
-- The shared rules: every config's exportMeta() and every rule module's golden(), found by walking the folders
--------------------------------------------------------------------------------

local function lowerFirst(name: string): string
	return string.lower(string.sub(name, 1, 1)) .. string.sub(name, 2)
end

local configs = {}
local goldens = {}
local goldenRows = 0
for _, folderName in { "Config", "Rules" } do
	local folder = game:GetService("ReplicatedStorage").Shared:FindFirstChild(folderName)
	local names = {}
	for _, child in (if folder then folder:GetChildren() else {}) do
		if child:IsA("ModuleScript") then
			table.insert(names, child.Name)
		end
	end
	table.sort(names)
	for _, name in names do
		local module = h.require("ReplicatedStorage.Shared." .. folderName .. "." .. name)
		if type(module) ~= "table" then
			continue
		end
		if type(module.exportMeta) == "function" then
			configs[lowerFirst(name)] = toJson(module.exportMeta())
		end
		if type(module.golden) == "function" then
			local rows = module.golden()
			goldens[name] = rows
			goldenRows += #rows
		end
	end
end
fs.writeFile(cacheDir .. "/golden.json", serde.encode("json", goldens))
local configNames = {}
for key in configs do
	table.insert(configNames, key)
end
table.sort(configNames)
print(string.format("configs for meta: %s", table.concat(configNames, ", ")))
print(string.format(
	"golden rows: %d of %d modules -> %s/golden.json",
	goldenRows,
	(function()
		local n = 0
		for _ in goldens do
			n += 1
		end
		return n
	end)(),
	cacheDir
))

-- The CreatureBlocks (an invisible wall across every opening into a Gap, colliding for the Creature only): the web's
-- Creature clamps to the same boxes (meta.creatureBlocks); its players never collide with them.
local CollectionService = game:GetService("CollectionService")
local creatureBlocks = {}
for _, part in CollectionService:GetTagged("CreatureBlock") do
	if part:IsA("BasePart") then
		table.insert(creatureBlocks, {
			level = part:GetAttribute("LevelId"),
			door = part:GetAttribute("DoorId"),
			cframe = cf(part.CFrame),
			size = v3(part.Size),
		})
	end
end
table.sort(creatureBlocks, function(a, b)
	return tostring(a.level) .. "|" .. tostring(a.door) < tostring(b.level) .. "|" .. tostring(b.door)
end)

--------------------------------------------------------------------------------
-- Write
--------------------------------------------------------------------------------

local out = {
	version = 1,
	seed = RUN_SEED,
	difficulty = DIFFICULTY,
	plan = toJson(plan),
	levels = levelsData,
	layoutIds = (function()
		local ids = {}
		for _, layout in layouts do
			table.insert(ids, layout.id)
		end
		return ids
	end)(),
	worldConfig = configs.worldConfig,
	configs = configs,
	creatureBlocks = creatureBlocks,
	objectives = objectiveData,
	routes = routeData,
	routePairs = routePairs,
	routeRule = routeRule,
	lighting = {
		baseline = toJson(LightingRig.Baseline),
		properties = lightingProps,
		moonlight = toJson(LightingMood.Moonlight),
		baseFilm = toJson(LightingMood.BaseFilm),
		outdoorFilm = toJson(LightingMood.OutdoorFilm),
		films = films,
		moods = moods,
		maxBrightness = toJson(LightingMood.MaxBrightness),
		fixtureCones = (function()
			local cones = {}
			for _, kind in { "Fluorescent", "ClassroomGlow", "Bulb", "EmergencyRed", "ExitSign", "BoilerGlow" } do
				local shape = FixtureGlow.cone(kind)
				if shape then
					cones[kind] = toJson(shape)
				end
			end
			return cones
		end)(),
	},
	palette = paletteData,
	textureRefs = textureRefs,
	parts = parts,
	guis = guis,
	volumes = volumes,
	attachments = attachments,
	fixtures = fixtures,
	lights = lights,
	entities = entities,
	ventGraphs = ventGraphs,
	zoneGraph = toJson(zoneGraph),
	layouts = layoutData,
	teleportPoints = teleportPoints,
	landmarks = landmarks,
	regions = regions,
	windows = windows,
	creature = creature,
}

if offGridCount > 0 then
	print(
		string.format(
			"%d part colour(s) off the 8-bit grid a part stores (write them with MathUtil.color8):",
			offGridCount
		)
	)
	for _, line in offGrid do
		print("  " .. line)
	end
	process.exit(3)
end

fs.writeFile(outPath, serde.encode("json", out))
print(
	string.format(
		"exported %d parts, %d lights, %d entities, %d guis, %d volumes, %d attachments in %.2fs -> %s",
		#parts,
		#lights,
		#entities,
		#guis,
		#volumes,
		#attachments,
		os.clock() - started,
		outPath
	)
)
for _, warning in h.warnings do
	print("  warn " .. warning)
end
