--!strict
-- Removal (docs/design/game-spec-v2.md 6): what the shorter game cut stays cut. The game's own scripts (every module
-- and script outside the specs) name none of the removed levels, stairwells, modules, objectives, states, noises,
-- strings or attributes; no instance in the game carries a removed module's name; and the built world (every layout
-- through BuildAuthoritative, every school level's fixtures through BuildFixtures) has no instance, tag, attribute
-- name or attribute value from the cut content: no Science Hall, Gym or Pool, no Level 4 or Level 5 ids, no
-- stairwells above the roof, no landing field, no pool water.

local CollectionService = game:GetService("CollectionService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Enums = require(ReplicatedStorage.Shared.Enums)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

-- The cut levels and the stairwells that led to them.
local REMOVED_IDS: { string } = {
	"Level2_ScienceHall",
	"Level3_Gymnasium",
	"Level4_FloodedPool",
	"Level5_Roof",
	"Stairwell_3_4",
	"Stairwell_4_5",
}

-- The cut modules.
local REMOVED_MODULES: { string } = {
	"FumeHoodBuilder",
	"AcidFlaskBuilder",
	"GeneratorBuilder",
	"PoolWaterBuilder",
	"FloodedPoolService",
	"SwimController",
	"StruggleController",
	"WaterRules",
	"HatchValveBuilder",
	"FloodlightSwitchBuilder",
	"Level2_ScienceHallController",
	"Level3_GymnasiumController",
	"Level4_FloodedPoolController",
	"Level5_RoofController",
}

-- Names the game's scripts no longer use: objectives, items, stations, states, noises, scenes, hints, tunables and
-- attributes of the cut content (matched as plain text anywhere in a script), row by row of spec 6: the Science Hall
-- (BurnChain, reagents, the acid flask), the Gym (GymGenerator, the coach's key, the store lock and door), the pool
-- (AquaticStalk, the pool helpers, the struggle, the valve wheel, oxygen), the old roof (the maze, the bolt cutters,
-- CutCrate / CrateChain, the finale scenes, the landing field), the Tab hint's nudge and the Syringe's charges.
local REMOVED_NAMES: { string } = {
	"AquaticStalk",
	"BurnChain",
	"Reagent",
	"AcidFlask",
	"GymGenerator",
	"CoachKey",
	"StoreLock",
	"EquipmentStoreDoor",
	"ValveWheel",
	"Struggle",
	"Maze",
	"CrateChain",
	"CutCrate",
	"BoltCutter",
	"flasksScienceHall",
	"flasksPool",
	"Nudge",
	"FinaleSky",
	"Touchdown",
	"DryFooting",
	"ClimbBand",
	"swimToDry",
	"underWater",
	"ObjHatchValve",
	"ObjCrateChain",
	"LandingField",
	"Treading",
	"Freestyle",
	"SyringeCharges",
	"syringeCharges",
	"GrabbedUserId",
	"Oxygen",
	"oxygen",
	"PoolWater",
	"Submerged",
	"ObjectiveTargets",
	"ObjectiveTimerEndsAt",
	"ObjectiveActivatedAt",
}

-- Quoted ids and enum values of the cut content: the old floors' id prefixes, the Syringe action, the Finale scene,
-- the roof's Cover hide kind, the swim and struggle states and contexts, the drag lock.
local REMOVED_LITERALS: { string } = {
	'"L4_',
	'"L5_',
	'"Syringe"',
	'"Finale"',
	'"Cover"',
	'"Underwater"',
	'"Struggle"',
	'"Grabbed"',
	'"Drag"',
}

-- Attributes the built world never carries again.
local REMOVED_ATTRIBUTES: { string } = {
	"Oxygen",
	"OxygenRate",
	"OxygenAt",
	"OxygenMax",
	"SyringeCharges",
	"GrabbedUserId",
	"Submerged",
	"ObjectiveTimerEndsAt",
	"ObjectiveActivatedAt",
	"ObjectiveTargets",
	"LockerId",
}

-- Tags the built world never carries again.
local REMOVED_TAGS: { string } = { "PoolWater", "FloodlightSwitch" }

-- Enum values of the cut content (spec 6: the swim and underwater MoveStates and CameraStates, the struggle and its
-- drag, AquaticStalk, the Swim pose, the Treading / Freestyle / Splash noises and the Water medium, the stations,
-- items, prompts and candidates of the cut objectives, the pool water and floodlights, the roof's Cover, the Syringe
-- action, "fall without a pack"). SurfaceKind keeps Water: a puddle is still a wet floor.
local REMOVED_ENUM_VALUES: { [string]: { string } } = {
	MoveState = { "Treading", "Freestyle", "Underwater", "Grabbed", "SurfaceSwimming", "UnderwaterSwimming" },
	CameraState = { "SurfaceSwimming", "UnderwaterSwimming", "Underwater" },
	CameraOverride = { "Struggle" },
	ControlLock = { "Drag" },
	MonsterState = { "AquaticStalk" },
	PoseMode = { "Swim" },
	NoiseKind = { "Treading", "Freestyle", "Splash", "GeneratorStart" },
	NoiseMedium = { "Water" },
	JumpscareKind = { "Underwater" },
	ItemId = { "AcidFlask" },
	PromptKind = { "Floodlight", "Mix", "Pour", "Generator", "FitValve", "TurnValve", "CutChain", "Search" },
	AnchorKind = {
		"FloodlightSwitch",
		"ReagentCandidate",
		"CoachKeyCandidate",
		"ValveWheelCandidate",
		"BoltCutterCandidate",
		"FumeHood",
		"Generator",
		"StoreLock",
		"HatchValve",
		"CrateChain",
	},
	RoomKind = { "Pool", "Gym", "Lab", "LockerRoom" },
	TriggerKind = { "PoolWater" },
	LightKind = { "Floodlight" },
	HideKind = { "Cover" },
	InputAction = { "Syringe", "Dive", "Struggle", "Swim" },
	InputContext = { "Underwater", "Struggle", "Swim" },
	ProjectileHitKind = { "Water" },
	CueKind = { "Struggle" },
	ParachuteState = { "Falling" },
}

-- Fragments of instance names from the cut content.
local REMOVED_NAME_PARTS: { string } = {
	"ScienceHall",
	"Gymnasium",
	"FloodedPool",
	"Level5_Roof",
	"Stairwell_3_4",
	"Stairwell_4_5",
	"LandingField",
	"PoolDressing",
	"Basin",
	"FumeHood",
	"BoltCutter",
	"CutCrate",
	"FloodlightSwitch",
	"HatchValve",
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Every module and script of the game (the specs and their runner are left out: they name what they check).
local function gameScripts(): { LuaSourceContainer }
	local tests = ServerScriptService:FindFirstChild("Tests")
	local out: { LuaSourceContainer } = {}
	for _, root: Instance in { ReplicatedFirst, ReplicatedStorage, ServerScriptService, StarterGui, StarterPlayer } do
		for _, d in root:GetDescendants() do
			if d:IsA("LuaSourceContainer") and not (tests and d:IsDescendantOf(tests)) then
				table.insert(out, d)
			end
		end
	end
	table.sort(out, function(a: LuaSourceContainer, b: LuaSourceContainer): boolean
		return a:GetFullName() < b:GetFullName()
	end)
	return out
end

local function sourceOf(container: LuaSourceContainer): string?
	local ok, source = pcall(function(): string
		return (container :: any).Source
	end)
	if not ok or type(source) ~= "string" or source == "" then
		return nil
	end
	return source
end

-- The first entry of `list` found in `text` as plain text, if any.
local function firstIn(text: string, list: { string }): string?
	for _, needle in list do
		if string.find(text, needle, 1, true) then
			return needle
		end
	end
	return nil
end

local function startsWithOldFloor(text: string): boolean
	return string.sub(text, 1, 3) == "L4_" or string.sub(text, 1, 3) == "L5_"
end

type Built = { roots: { Instance } }

local cached: Built? = nil

-- Every layout's world (shell, vents, static props) and every school level's fixtures, built once, detached.
local function built(): Built
	local existing = cached
	if existing then
		return existing
	end
	local host = Instance.new("Model")
	host.Name = "RemovalSpec"
	Builder.BuildAuthoritative({ parent = host :: Instance, layouts = table.clone(Enums.LayoutId), yieldEvery = 0 })
	local roots: { Instance } = { host }
	local previous = Geometry.getYieldEvery()
	Geometry.setYieldEvery(0)
	for _, id in WorldConfig.LevelOrder do
		local folder = Instance.new("Folder")
		folder.Name = id
		Builder.BuildFixtures(id, folder, nil)
		table.insert(roots, folder)
	end
	Geometry.setYieldEvery(previous)
	local result: Built = { roots = roots }
	cached = result
	return result
end

local function report(t: Expect, problems: { string }, what: string)
	t.eq(#problems, 0, what .. ":\n  " .. table.concat(problems, "\n  "))
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["the game's scripts name no removed level, stairwell, module or name"] = function(t: Expect)
		local scripts = gameScripts()
		t.truthy(#scripts >= 200, string.format("scanned %d scripts", #scripts))
		local problems: { string } = {}
		for _, container in scripts do
			local source = sourceOf(container)
			if not source then
				table.insert(
					problems,
					container:GetFullName() .. ": source unreadable here (the scan runs in Lune: tools/verify.sh)"
				)
				continue
			end
			for _, list in { REMOVED_IDS, REMOVED_MODULES, REMOVED_NAMES, REMOVED_LITERALS } do
				local hit = firstIn(source, list)
				if hit then
					table.insert(problems, container:GetFullName() .. " names " .. hit)
				end
			end
		end
		report(t, problems, "leftovers in the game's scripts")
	end,

	["no instance in the game carries a removed module's or level's name"] = function(t: Expect)
		local problems: { string } = {}
		for _, root: Instance in { ReplicatedFirst, ReplicatedStorage, ServerScriptService, StarterGui, StarterPlayer } do
			for _, d in root:GetDescendants() do
				if table.find(REMOVED_MODULES, d.Name) or table.find(REMOVED_IDS, d.Name) then
					table.insert(problems, d:GetFullName())
				end
			end
		end
		report(t, problems, "removed modules still in the place")
		local layouts = ReplicatedStorage.Shared.World.ProceduralWorldBuilder:FindFirstChild("Layouts")
		assert(layouts, "the layouts folder")
		for _, id in REMOVED_IDS do
			t.eq(layouts:FindFirstChild(id), nil, id .. " has no layout")
			t.eq(Builder.getLayout(id), nil, id .. " is no layout id")
		end
	end,

	["the cut ids are gone from the id lists and the stair pairs"] = function(t: Expect)
		local listed: { [string]: boolean } = {}
		for _, id in Enums.LevelId do
			listed[id] = true
		end
		for _, id in Enums.LayoutId do
			listed[id] = true
		end
		for _, id in REMOVED_IDS do
			t.falsy(listed[id], id .. " is listed")
		end
		for _, spec in WorldConfig.Stairwells do
			t.eq(firstIn(spec.id, REMOVED_IDS), nil, spec.id)
			t.falsy(startsWithOldFloor(spec.fromRoom) or startsWithOldFloor(spec.toRoom), spec.id .. " rooms")
		end
	end,

	["no enum lists a value of the cut content"] = function(t: Expect)
		local enums = Enums :: any
		local names: { string } = {}
		for name in REMOVED_ENUM_VALUES do
			table.insert(names, name)
		end
		table.sort(names)
		local problems: { string } = {}
		for _, name in names do
			local list = enums[name]
			if type(list) ~= "table" then
				table.insert(problems, "Enums." .. name .. " is missing")
				continue
			end
			for _, value in REMOVED_ENUM_VALUES[name] do
				if table.find(list, value) then
					table.insert(problems, string.format("Enums.%s lists %s", name, value))
				end
			end
		end
		report(t, problems, "cut enum values")
	end,

	["the built world has no instance or tag from the cut content"] = function(t: Expect)
		local problems: { string } = {}
		local count = 0
		for _, root in built().roots do
			for _, d in root:GetDescendants() do
				count += 1
				local part = firstIn(d.Name, REMOVED_NAME_PARTS)
				if part or startsWithOldFloor(d.Name) then
					table.insert(problems, d:GetFullName() .. " (name)")
				end
				for _, tag in CollectionService:GetTags(d) do
					if table.find(REMOVED_TAGS, tag) then
						table.insert(problems, d:GetFullName() .. " tagged " .. tag)
					end
				end
			end
		end
		t.truthy(count > 10000, string.format("scanned %d instances", count))
		report(t, problems, "cut content in the built world")
	end,

	["the built world carries no removed attribute or cut id in its attributes"] = function(t: Expect)
		local problems: { string } = {}
		for _, root in built().roots do
			for _, d in root:GetDescendants() do
				for name, value in d:GetAttributes() do
					if table.find(REMOVED_ATTRIBUTES, name) then
						table.insert(problems, d:GetFullName() .. " has " .. name)
					elseif type(value) == "string" then
						local hit = firstIn(value, REMOVED_IDS)
						if hit or startsWithOldFloor(value) then
							table.insert(problems, string.format("%s %s = %q", d:GetFullName(), name, value))
						end
					end
				end
			end
		end
		report(t, problems, "cut ids in the built world's attributes")
	end,
}
