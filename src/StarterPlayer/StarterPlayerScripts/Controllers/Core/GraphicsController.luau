--!strict
-- GraphicsController: the Graphics setting (GraphicsConfig tiers: Max, the default, down to Potato) applied to this
-- client's own view. Nothing here reaches the server or any other player.
--
--   * Budget. The tier is RenderBudgetController's ceiling: fixtures, their shadows and the radius past which
--     unshadowed ones go dark, the torches' shadows (kept down to Low) and haze, moonlight spills, light shafts, dust,
--     the particle scale, depth of field and animation LOD. Its frame-rate guard may lower that budget, never raise it.
--   * Post. LightingController.SetGraphics: bloom, sun rays, the area grade, Potato's flat grade and the render
--     distance the level's haze closes at (LightingController/Film).
--   * Surfaces, applied here to everything under Workspace when the tier changes, and to every instance that arrives
--     later (DescendantAdded: a run's props and fixtures, the cosmetic dressing, characters):
--       - textured parts (a MaterialVariant) show their plain material on Low and Potato, in their palette colour
--         (MaterialLibrary tints a textured part by its texture's reference albedo; the plain one is untinted);
--       - pure-noise wear paint (GraphicsConfig.WearGuis SurfaceGuis, "Overlay_" Textures) is hidden on Low and
--         Potato; every other SurfaceGui (signs, labels, notices, wayfinding, hazard stripes) is always kept;
--       - a part whose Detail attribute is above the tier's limit is hidden through LocalTransparencyModifier (the
--         replicated Transparency is never written); a part without the attribute is never hidden;
--       - world ParticleEmitters run at the tier's particle scale and stop on Potato (an effect whose owner follows
--         the budget itself carries GraphicsConfig.OwnedAttribute and is left alone).
--     Every write remembers the value it replaced, so a higher tier puts back exactly what was built. Only the
--     GraphicsConfig.Writes properties are ever written: never collision, queries, sizes, positions, collision groups,
--     materials, physics or server state (tests/Specs/GraphicsTiers.spec.luau).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GraphicsConfig = require(ReplicatedStorage.Shared.Config.GraphicsConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MaterialLibrary = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.MaterialLibrary)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TextureAssets = require(ReplicatedStorage.Shared.Config.TextureAssets)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)

local LightingController = require(script.Parent.LightingController)
local RenderBudgetController = require(script.Parent.RenderBudgetController)
local SettingsController = require(script.Parent.SettingsController)

local log = Log.new("Graphics")

local SETTING = "Graphics"
local WALK_CHUNK = 6000 -- instances per frame when a tier change walks the whole Workspace

export type TierName = GraphicsConfig.TierName

-- What the surfaces need from a tier.
export type Look = {
	materialVariants: boolean,
	wear: boolean,
	detailLimit: number,
	particleScale: number,
}

-- What an instance looked like before any tier touched it (only the fields its kind uses).
export type Original = {
	variant: string?, -- textured parts: MaterialVariant
	color: Color3?, -- textured parts: Color
	ltm: number?, -- Detail parts: LocalTransparencyModifier
	enabled: boolean?, -- wear SurfaceGuis, ParticleEmitters
	transparency: number?, -- wear Decals and Textures
	rate: number?, -- ParticleEmitters
}

export type Memory = { [Instance]: Original }

-- property -> value
export type Writes = { [string]: any }

local GraphicsController = {}

GraphicsController.Name = "GraphicsController"

local tierChanged: Signal.Signal<TierName> = Signal.new()
GraphicsController.TierChanged = tierChanged

local serviceTrove = Trove.new()

--------------------------------------------------------------------------------
-- Pure rules (specced)
--------------------------------------------------------------------------------

-- The tier a Graphics setting value stands for (anything out of range: the default).
function GraphicsController.tierOf(value: unknown): TierName
	return GraphicsConfig.tierAt(if type(value) == "number" then value else 0).name
end

function GraphicsController.lookFor(name: string): Look
	local tier = GraphicsConfig.tier(name)
	return {
		materialVariants = tier.surfaces.materialVariants,
		wear = tier.surfaces.wear,
		detailLimit = tier.surfaces.detailLimit,
		particleScale = tier.budget.particleScale,
	}
end

-- A look that changes nothing a builder made (Max, High): instances it has never touched need no visit.
function GraphicsController.isFull(look: Look): boolean
	return look.materialVariants
		and look.wear
		and look.particleScale >= 1
		and look.detailLimit >= GraphicsConfig.DetailLevels
end

function GraphicsController.newMemory(): Memory
	return setmetatable({}, { __mode = "k" }) :: any
end

-- Pure-noise wear paint: a GraphicsConfig.WearGuis SurfaceGui or an "Overlay_" Decal / Texture.
function GraphicsController.isWear(instance: Instance): boolean
	if instance:IsA("SurfaceGui") then
		return GraphicsConfig.WearGuis[instance.Name] == true
	elseif instance:IsA("Decal") then
		local prefix = GraphicsConfig.WearPrefix
		return string.sub(instance.Name, 1, #prefix) == prefix
	end
	return false
end

local references: { [string]: Color3 | false } = {}

-- A property's current value, or nil when it has none to read (LocalTransparencyModifier on a part nothing has set it
-- on, outside Roblox: the Lune harness has no default for it; in Roblox it reads 0).
local function read(instance: Instance, property: string): any
	local ok, value = pcall(function(): any
		return (instance :: any)[property]
	end)
	return if ok then value else nil
end

-- The reference albedo of the texture behind MaterialVariant `variant` on `base` (nil: not one of ours).
local function referenceOf(variant: string, base: Enum.Material): Color3?
	local cached = references[variant]
	if cached == false then
		return nil
	elseif cached ~= nil then
		return cached :: Color3
	end
	local found: Color3? = nil
	for texture, entry in TextureAssets do
		if MaterialLibrary.variantName(texture, base) == variant then
			found = entry.reference
			break
		end
	end
	references[variant] = found or false
	return found
end

-- The colour a textured part shows plain: MaterialLibrary.tint undone (the palette colour), or `color` unchanged when
-- the variant is not one of the generated textures.
function GraphicsController.plainColor(color: Color3, variant: string, base: Enum.Material): Color3
	local reference = referenceOf(variant, base)
	if not reference then
		return color
	end
	return Color3.new(color.R * reference.R, color.G * reference.G, color.B * reference.B)
end

-- What `instance` looks like before any tier, when a tier can change it; nil for everything else.
function GraphicsController.capture(instance: Instance): Original?
	if instance:IsA("BasePart") then
		local variant = instance.MaterialVariant
		local detail = instance:GetAttribute(GraphicsConfig.DetailAttribute)
		local textured = variant ~= ""
		local decorative = type(detail) == "number"
		if not textured and not decorative then
			return nil
		end
		return {
			variant = if textured then variant else nil,
			color = if textured then instance.Color else nil,
			ltm = if decorative then read(instance, "LocalTransparencyModifier") or 0 else nil,
		}
	elseif instance:IsA("SurfaceGui") then
		return if GraphicsController.isWear(instance) then { enabled = instance.Enabled } else nil
	elseif instance:IsA("Decal") then
		return if GraphicsController.isWear(instance) then { transparency = instance.Transparency } else nil
	elseif instance:IsA("ParticleEmitter") then
		if instance:GetAttribute(GraphicsConfig.OwnedAttribute) == true then
			return nil
		end
		return { rate = instance.Rate, enabled = instance.Enabled }
	end
	return nil
end

-- The writes `look` wants on `instance` (property -> value), given what it looked like before any tier. A full look
-- (Max) gives back every original value.
function GraphicsController.plan(instance: Instance, original: Original, look: Look): Writes
	local writes: Writes = {}
	if instance:IsA("BasePart") then
		local variant = original.variant
		local color = original.color
		if variant and color then
			if look.materialVariants then
				writes.MaterialVariant = variant
				writes.Color = color
			else
				writes.MaterialVariant = ""
				writes.Color = GraphicsController.plainColor(color, variant, instance.Material)
			end
		end
		local ltm = original.ltm
		if ltm ~= nil then
			local detail = instance:GetAttribute(GraphicsConfig.DetailAttribute)
			local hidden = type(detail) == "number" and detail > look.detailLimit
			writes.LocalTransparencyModifier = if hidden then 1 else ltm
		end
	elseif instance:IsA("SurfaceGui") then
		writes.Enabled = if look.wear then original.enabled == true else false
	elseif instance:IsA("Decal") then
		writes.Transparency = if look.wear then original.transparency or 0 else 1
	elseif instance:IsA("ParticleEmitter") then
		local scale = math.max(0, look.particleScale)
		writes.Rate = (original.rate or 0) * scale
		writes.Enabled = original.enabled == true and scale > 0
	end
	return writes
end

local function write(instance: Instance, writes: Writes)
	local target = instance :: any
	for property, value in writes do
		if read(instance, property) ~= value then
			target[property] = value
		end
	end
end

-- Applies `look` to one instance, remembering its original look the first time. Returns whether a tier can change it.
function GraphicsController.applyOne(instance: Instance, look: Look, memory: Memory): boolean
	local original: Original? = memory[instance]
	if original == nil then
		local captured = GraphicsController.capture(instance)
		if captured == nil then
			return false
		end
		memory[instance] = captured
		original = captured
	end
	write(instance, GraphicsController.plan(instance, original :: Original, look))
	return true
end

-- Applies `look` to `root` and everything under it. Returns how many instances a tier can change.
function GraphicsController.applyTo(root: Instance, look: Look, memory: Memory): number
	local count = if GraphicsController.applyOne(root, look, memory) then 1 else 0
	for _, descendant in root:GetDescendants() do
		if GraphicsController.applyOne(descendant, look, memory) then
			count += 1
		end
	end
	return count
end

--------------------------------------------------------------------------------
-- Runtime
--------------------------------------------------------------------------------

local memory: Memory = GraphicsController.newMemory()
local current: TierName = GraphicsConfig.default().name
local look: Look = GraphicsController.lookFor(current)
local walkGeneration = 0

-- An instance arriving under Workspace: at a full look only Detail parts (or one a lower tier touched) need a visit.
local function onAdded(instance: Instance)
	if
		GraphicsController.isFull(look)
		and memory[instance] == nil
		and not (instance:IsA("BasePart") and instance:GetAttribute(GraphicsConfig.DetailAttribute) ~= nil)
	then
		return
	end
	GraphicsController.applyOne(instance, look, memory)
end

-- Walks the whole Workspace in chunks (a newer tier change stops an older walk).
local function walk()
	walkGeneration += 1
	local generation = walkGeneration
	task.spawn(function()
		local started = os.clock()
		local count = 0
		local list = Workspace:GetDescendants()
		for index, instance in list do
			if generation ~= walkGeneration then
				return
			end
			if instance.Parent ~= nil and GraphicsController.applyOne(instance, look, memory) then
				count += 1
			end
			if index % WALK_CHUNK == 0 then
				task.wait()
			end
		end
		log.info("Graphics %s: %d instances in %.0f ms", current, count, (os.clock() - started) * 1000)
	end)
end

local function applyTier(name: TierName, force: boolean?)
	if name == current and not force then
		return
	end
	local wasFull = GraphicsController.isFull(look)
	current = name
	look = GraphicsController.lookFor(name)
	local tier = GraphicsConfig.tier(name)
	RenderBudgetController.SetCeiling(name)
	LightingController.SetGraphics(tier.post)
	-- A full look on a client no lower tier has touched has nothing to undo, except Detail parts.
	if not (wasFull and GraphicsController.isFull(look) and next(memory) == nil) then
		walk()
	end
	tierChanged:Fire(name)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function GraphicsController.GetTier(): TierName
	return current
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function GraphicsController.Init()
	current = GraphicsController.tierOf(SettingsController.Get(SETTING))
	look = GraphicsController.lookFor(current)
	local tier = GraphicsConfig.tier(current)
	RenderBudgetController.SetCeiling(current)
	LightingController.SetGraphics(tier.post)
end

function GraphicsController.Start()
	serviceTrove:Connect(Workspace.DescendantAdded, onAdded)
	serviceTrove:Add(SettingsController.Changed:Connect(function(key: string, value: SettingsController.Value)
		if key == SETTING then
			applyTier(GraphicsController.tierOf(value))
		end
	end))
	-- The setting as it stands now (the saved blob may have landed before this Start), on the world already here.
	applyTier(GraphicsController.tierOf(SettingsController.Get(SETTING)), true)
end

return table.freeze(GraphicsController)
