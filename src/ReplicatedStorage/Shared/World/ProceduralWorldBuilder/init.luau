--!strict
-- ProceduralWorldBuilder: builds every piece of world geometry in code.
--
-- Server: BuildAuthoritative() makes Workspace.Lobby (boiler room + wrecked bus) and Workspace.School (one Model
-- per level, the stair towers and the street-level exterior), then ApplyLighting() sets the storm-night baseline.
-- Client: BuildCosmetic(seed, parent) adds the ruined skyline plus whatever cosmetic-anchor dressing later phases
-- register. Later phases plug in through the registries (RegisterProp / RegisterRig / RegisterCosmeticAnchor), so
-- this file never needs to change for them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(script.Geometry)
local LightingRig = require(script.LightingRig)
local LobbyBuilder = require(script.LobbyBuilder)
local SchoolShellBuilder = require(script.SchoolShellBuilder)
local SkylineBuilder = require(script.SkylineBuilder)
local StairwellBuilder = require(script.StairwellBuilder)

local log = Log.new("WorldBuilder")

type Layout = LayoutSchema.LevelLayout

export type BuildOptions = {
	parent: Instance?, -- default Workspace
	layouts: { Enums.LayoutId }?, -- subset to build (default: every layout)
	yieldEvery: number?, -- parts between task.wait()s (default 600; <= 0 never yields)
}

export type BuildResult = {
	school: Model,
	lobby: Model,
	levels: { [string]: Model },
	partCount: number,
}

export type CosmeticAnchorBuilder = (
	anchor: LayoutSchema.Anchor,
	cframe: CFrame,
	parent: Instance,
	random: Random
) -> ()

local DEFAULT_YIELD_EVERY = 600
local SKYLINE_FOLDER = "Skyline"
local DRESSING_FOLDER = "Dressing"

local Names = Instances.Names

local Builder = {}

--------------------------------------------------------------------------------
-- Layouts
--------------------------------------------------------------------------------

local loadedLayouts: { Layout }? = nil
local layoutsById: { [string]: Layout } = {}

local function loadLayouts(): { Layout }
	local list: { Layout } = {}
	local folder = script:FindFirstChild("Layouts")
	if not folder then
		log.error("ProceduralWorldBuilder.Layouts is missing; nothing can be built")
		return list
	end
	for _, id: Enums.LayoutId in Enums.LayoutId do
		local module = folder:FindFirstChild(id)
		if not (module and module:IsA("ModuleScript")) then
			log.error("layout %s is missing", id)
			continue
		end
		local loaded: Layout? = nil
		xpcall(function()
			loaded = (require(module) :: any) :: Layout
		end, function(err: any)
			log.error("layout %s failed to load: %s", id, tostring(err))
		end)
		local layout = loaded
		if not layout then
			continue
		end
		if layout.id ~= id then
			log.warn("layout module %s declares id %s", id, tostring(layout.id))
		end
		local problems = LayoutSchema.validate(layout)
		for i, problem in problems do
			if i > 8 then
				log.warn("layout %s: %d more problems", id, #problems - 8)
				break
			end
			log.warn("layout %s: %s", id, problem)
		end
		table.insert(list, layout)
		layoutsById[id] = layout
	end
	return list
end

-- Lobby, Level0..Level5 in run order (loaded once from Layouts/*).
function Builder.layouts(): { Layout }
	local cached = loadedLayouts
	if cached then
		return cached
	end
	local list = loadLayouts()
	table.freeze(list)
	loadedLayouts = list
	return list
end

function Builder.getLayout(id: string): Layout?
	Builder.layouts()
	return layoutsById[id]
end

-- World-space CFrame of a layout anchor (level origin + local position, yaw applied).
function Builder.anchorCFrame(layoutId: string, anchor: LayoutSchema.Anchor): CFrame
	return CFrame.new(WorldConfig.levelOrigin(layoutId)) * SchoolShellBuilder.anchorLocalCFrame(anchor)
end

-- Builders call this once per created part; it yields every `yieldEvery` parts.
function Builder.yieldPoint()
	Geometry.yieldPoint()
end

--------------------------------------------------------------------------------
-- Registries (later phases plug in here)
--------------------------------------------------------------------------------

local propBuilders: { [string]: Types.PropBuilder } = {}
local rigBuilders: { [string]: Types.RigBuilder } = {}
local cosmeticBuilders: { [string]: CosmeticAnchorBuilder } = {}

function Builder.RegisterProp(kind: string, builder: Types.PropBuilder)
	if propBuilders[kind] then
		log.warn("prop builder %q replaced", kind)
	end
	propBuilders[kind] = builder
end

-- Builds one planned prop. Returns nil (and warns) when no builder is registered for its kind or it fails.
function Builder.BuildProp(plan: Types.PlannedProp, parent: Instance, random: Random): Instance?
	local builder = propBuilders[plan.kind]
	if not builder then
		log.warnThrottled("prop:" .. plan.kind, 30, "no prop builder registered for %q", plan.kind)
		return nil
	end
	local built: Instance? = nil
	xpcall(function()
		built = builder({ prop = plan, parent = parent, random = random })
	end, function(err: any)
		log.error("prop %s at %s failed: %s", plan.kind, plan.anchorId, tostring(err))
	end)
	local instance = built
	if instance and instance.Parent == nil then
		instance.Parent = parent
	end
	return instance
end

function Builder.RegisterRig(kind: string, builder: Types.RigBuilder)
	if rigBuilders[kind] then
		log.warn("rig builder %q replaced", kind)
	end
	rigBuilders[kind] = builder
end

function Builder.HasRig(kind: string): boolean
	return rigBuilders[kind] ~= nil
end

-- Builds a registered rig at `cframe`. Returns nil when none is registered for `kind` or it fails.
function Builder.BuildRig(kind: string, parent: Instance, cframe: CFrame): Model?
	local builder = rigBuilders[kind]
	if not builder then
		return nil
	end
	local built: Model? = nil
	xpcall(function()
		built = builder(parent, cframe)
	end, function(err: any)
		log.error("rig %s failed: %s", kind, tostring(err))
	end)
	local model = built
	if model and model.Parent == nil then
		model.Parent = parent
	end
	return model
end

function Builder.RegisterCosmeticAnchor(kind: Enums.AnchorKind, builder: CosmeticAnchorBuilder)
	if cosmeticBuilders[kind] then
		log.warn("cosmetic anchor builder %q replaced", kind)
	end
	cosmeticBuilders[kind] = builder
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function countParts(root: Instance): number
	local count = 0
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			count += 1
		end
	end
	return count
end

local function guarded(what: string, fn: () -> ())
	xpcall(fn, function(err: any)
		log.error("%s failed: %s", what, tostring(err))
	end)
end

-- Ducts + VentNode graph for one level. VentShaftBuilder is required on first use rather than at load time, so
-- it may require this module (for yieldPoint) without creating a load-order cycle.
local function buildVents(layout: Layout, root: Model)
	if not layout.vents then
		return
	end
	guarded("vents for " .. layout.id, function()
		local VentShaftBuilder = require(script.VentShaftBuilder)
		VentShaftBuilder.build(layout, root)
	end)
end

-- Server: lobby + six levels + stair towers + exterior. Replaces any previous build under `parent`.
function Builder.BuildAuthoritative(options: BuildOptions?): BuildResult
	local opts: BuildOptions = options or {}
	local parent: Instance = opts.parent or Workspace
	local previousYield = Geometry.getYieldEvery()
	Geometry.setYieldEvery(opts.yieldEvery or DEFAULT_YIELD_EVERY)
	local started = os.clock()

	local selected: { [string]: boolean } = {}
	for _, id in (opts.layouts or Enums.LayoutId) :: { Enums.LayoutId } do
		selected[id] = true
	end
	Builder.layouts()

	for _, name in { Names.Lobby, Names.School } do
		local previous = parent:FindFirstChild(name)
		if previous then
			previous:Destroy()
		end
	end

	-- Lobby
	local lobby: Model
	local lobbyLayout = layoutsById.Lobby
	if selected.Lobby and lobbyLayout then
		local built: Model? = nil
		guarded("lobby", function()
			built = LobbyBuilder.build(lobbyLayout)
		end)
		lobby = built or SchoolShellBuilder.createRoot(lobbyLayout, Names.Lobby)
		buildVents(lobbyLayout, lobby)
	else
		lobby = Instance.new("Model")
		lobby.Name = Names.Lobby
	end
	lobby:SetAttribute(Attributes.World.ExpectedParts, countParts(lobby))
	lobby.Parent = parent

	-- School levels
	local school = Instance.new("Model")
	school.Name = Names.School
	school.Parent = parent
	local levels: { [string]: Model } = {}
	local anyLevel = false
	for _, levelId: Enums.LevelId in Enums.LevelId do
		if not selected[levelId] then
			continue
		end
		local layout = layoutsById[levelId]
		if not layout then
			log.warn("no layout for %s; level skipped", levelId)
			continue
		end
		anyLevel = true
		local root = SchoolShellBuilder.createRoot(layout)
		guarded("level " .. levelId, function()
			SchoolShellBuilder.buildLevel(layout, root, SchoolShellBuilder.levelOptions(levelId))
		end)
		buildVents(layout, root)
		root:SetAttribute(Attributes.World.ExpectedParts, countParts(root))
		root.Parent = school
		levels[levelId] = root
	end

	-- Stair towers + street-level exterior
	if anyLevel then
		guarded("stairwells", function()
			StairwellBuilder.build(school, layoutsById, if opts.layouts then selected else nil)
		end)
		local exterior = Instance.new("Model")
		exterior.Name = Names.Exterior
		guarded("exterior", function()
			SchoolShellBuilder.buildExterior(exterior)
		end)
		exterior.Parent = school
	end

	local partCount = countParts(school) + countParts(lobby)
	school:SetAttribute(Attributes.World.ExpectedParts, countParts(school))
	Geometry.setYieldEvery(previousYield)
	log.info("world built: %d parts in %.2fs", partCount, os.clock() - started)
	return { school = school, lobby = lobby, levels = levels, partCount = partCount }
end

-- Client: skyline (once per cosmetic tree) + registered cosmetic-anchor dressing. Returns parts created.
-- The skyline is skipped when an ancestor of `parent` already holds one, so a run-seeded rebuild into a
-- sub-folder only adds the run-varying dressing; the dressing folder under `parent` is replaced on every call.
function Builder.BuildCosmetic(seed: number, parent: Instance): number
	local before = countParts(parent)
	local previousYield = Geometry.getYieldEvery()
	Geometry.setYieldEvery(DEFAULT_YIELD_EVERY)

	local ancestorSkyline = false
	local cursor = parent.Parent
	while cursor do
		if cursor:FindFirstChild(SKYLINE_FOLDER) then
			ancestorSkyline = true
			break
		end
		cursor = cursor.Parent
	end
	if not ancestorSkyline then
		local old = parent:FindFirstChild(SKYLINE_FOLDER)
		if old then
			old:Destroy()
		end
		local skyline = Instance.new("Folder")
		skyline.Name = SKYLINE_FOLDER
		guarded("skyline", function()
			SkylineBuilder.build(seed, skyline)
		end)
		skyline.Parent = parent
	end

	local oldDressing = parent:FindFirstChild(DRESSING_FOLDER)
	if oldDressing then
		oldDressing:Destroy()
	end
	local dressing = Instance.new("Folder")
	dressing.Name = DRESSING_FOLDER
	for _, layout in Builder.layouts() do
		for _, anchor in layout.anchors do
			local builder = cosmeticBuilders[anchor.kind]
			if not builder then
				continue
			end
			local random = MathUtil.seededRandom(seed, layout.id .. ":" .. anchor.id)
			local cframe = Builder.anchorCFrame(layout.id, anchor)
			xpcall(builder, function(err: any)
				log.error("cosmetic %s at %s failed: %s", anchor.kind, anchor.id, tostring(err))
			end, anchor, cframe, dressing, random)
		end
	end
	for _, descendant in dressing:GetDescendants() do
		if descendant:IsA("BasePart") then
			Geometry.makeCosmetic(descendant)
		end
	end
	dressing.Parent = parent

	Geometry.setYieldEvery(previousYield)
	return countParts(parent) - before
end

-- Server lighting baseline (Atmosphere, grade, bloom, storm clouds).
function Builder.ApplyLighting()
	LightingRig.apply()
end

-- Destroys every per-run instance under Workspace.Runtime.
function Builder.ClearRuntime()
	local runtime = Instances.runtime()
	if not runtime then
		return
	end
	for _, child in runtime:GetChildren() do
		child:Destroy()
	end
end

return table.freeze(Builder)
