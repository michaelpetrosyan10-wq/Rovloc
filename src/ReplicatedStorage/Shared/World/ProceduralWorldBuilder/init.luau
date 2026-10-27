--!strict
-- ProceduralWorldBuilder: builds every piece of world geometry in code.
--
-- Server: BuildAuthoritative() makes Workspace.Lobby (boiler room + wrecked bus) and Workspace.School (one Model
-- per level, the stair towers and the street-level exterior, each level's static props in <level>.Props), then
-- ApplyLighting() sets the storm-night baseline. Per run, BuildProp() places the director's planned props and
-- BuildFixtures() rebuilds each level's stateful set pieces (grates, fire doors, lockers, ...) into
-- Workspace.Runtime.<level>, so every run starts fresh.
-- Client: BuildCosmetic(seed, parent) adds the ruined skyline plus the cosmetic-anchor dressing.
-- The registries (RegisterProp / RegisterFixture / RegisterStatic / RegisterRig / RegisterCosmeticAnchor) are filled
-- at load by the Props catalog and CreatureRigBuilder (see Props/PropKit for the builder kinds); later phases may
-- register more kinds or replace one.

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

local CreatureRigBuilder = require(script.CreatureRigBuilder)
local Geometry = require(script.Geometry)
local LightingRig = require(script.LightingRig)
local LobbyBuilder = require(script.LobbyBuilder)
local PropKit = require(script.Props.PropKit)
local Props = require(script.Props)
local SchoolShellBuilder = require(script.SchoolShellBuilder)
local SkylineBuilder = require(script.SkylineBuilder)
local StairwellBuilder = require(script.StairwellBuilder)
-- Sub-builders never require this module (SchoolShellBuilder itself requires VentShaftBuilder for duct envelopes).
local VentShaftBuilder = require(script.VentShaftBuilder)

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

export type CosmeticAnchorBuilder = PropKit.CosmeticAnchorBuilder
export type FixtureBuilder = PropKit.FixtureBuilder
export type FixtureContext = PropKit.FixtureContext
export type StaticBuilder = PropKit.StaticBuilder
export type StaticContext = PropKit.StaticContext

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
local fixtureBuilders: { [string]: FixtureBuilder } = {}
local staticBuilders: { [string]: StaticBuilder } = {}
local rigBuilders: { [string]: Types.RigBuilder } = {}
local cosmeticBuilders: { [string]: CosmeticAnchorBuilder } = {}

-- Registry keys in a stable order (builders run in this order, so builds are deterministic).
local function sortedKinds(registry: { [string]: any }): { string }
	local kinds: { string } = {}
	for kind in registry do
		table.insert(kinds, kind)
	end
	table.sort(kinds)
	return kinds
end

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

function Builder.RegisterFixture(kind: string, builder: FixtureBuilder)
	if fixtureBuilders[kind] then
		log.warn("fixture builder %q replaced", kind)
	end
	fixtureBuilders[kind] = builder
end

function Builder.HasFixture(kind: string): boolean
	return fixtureBuilders[kind] ~= nil
end

-- Rebuilds every registered fixture kind of `layoutId` into `parent` (Workspace.Runtime.<layoutId>) for one run.
-- Returns the number of fixtures built. Each kind is isolated: one failing builder never stops the others.
function Builder.BuildFixtures(layoutId: string, parent: Instance, plan: Types.SpawnPlan?, seed: number): number
	local layout = Builder.getLayout(layoutId)
	if not layout then
		return 0
	end
	local levelRoot = Instances.layoutRoot(layoutId)
	local total = 0
	for _, kind in sortedKinds(fixtureBuilders) do
		local ctx: FixtureContext = {
			layout = layout,
			levelRoot = levelRoot,
			parent = parent,
			plan = plan,
			random = MathUtil.seededRandom(seed, layoutId .. ":fixture:" .. kind),
		}
		local built = 0
		xpcall(function()
			built = fixtureBuilders[kind](ctx)
		end, function(err: any)
			log.error("fixtures %s on %s failed: %s", kind, layoutId, tostring(err))
		end)
		total += built
	end
	return total
end

function Builder.RegisterStatic(kind: string, builder: StaticBuilder)
	if staticBuilders[kind] then
		log.warn("static builder %q replaced", kind)
	end
	staticBuilders[kind] = builder
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

-- Ducts + VentNode graph for one level.
local function buildVents(layout: Layout, root: Model)
	if not layout.vents then
		return
	end
	guarded("vents for " .. layout.id, function()
		VentShaftBuilder.build(layout, root)
	end)
end

-- Every registered static kind for one level, into <level>.Props (the same geometry on every server).
local function buildStatics(layout: Layout, root: Model)
	local kinds = sortedKinds(staticBuilders)
	if #kinds == 0 then
		return
	end
	local folder = Geometry.folder(root, Names.Props)
	for _, kind in kinds do
		local ctx: StaticContext = {
			layout = layout,
			root = root,
			parent = folder,
			random = MathUtil.seededRandom(1, layout.id .. ":static:" .. kind),
		}
		guarded("static " .. kind .. " for " .. layout.id, function()
			staticBuilders[kind](ctx)
		end)
	end
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
		buildStatics(lobbyLayout, lobby)
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
		buildStatics(layout, root)
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

--------------------------------------------------------------------------------
-- Built-in kinds (Phase 2 props and the Creature)
--------------------------------------------------------------------------------

local registrar: PropKit.Registrar = {
	prop = Builder.RegisterProp,
	fixture = Builder.RegisterFixture,
	static = Builder.RegisterStatic,
	rig = Builder.RegisterRig,
	cosmetic = Builder.RegisterCosmeticAnchor,
}
Props.registerAll(registrar)
xpcall(CreatureRigBuilder.register, function(err: any)
	log.error("CreatureRigBuilder failed to register: %s", tostring(err))
end, registrar)

return table.freeze(Builder)
