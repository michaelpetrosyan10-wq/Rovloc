--!strict
-- GraphicsConfig: the Graphics setting's tiers as data, Max (the default: everything on) down to Potato (school
-- Chromebooks). A tier only ever strips visual overhead from this client's own view. Collision, queries, sizes,
-- positions, collision groups, materials, physics, the Creature and everything the server owns are the same on every
-- tier (tests/Specs/GraphicsTiers.spec.luau). The web build mirrors the same table.
--
--   * budget: the light budget RenderBudgetController publishes. LightingController (fixtures, their shadows, the
--     radius past which unshadowed ones go dark), Volumetrics (moonlight spills, shafts, dust), the torches, the
--     particle effects and the animation LOD read it. The tier is a ceiling: the frame-rate guard may step the budget
--     down further while the frame rate is low, never above it.
--   * post: what LightingController/Film puts on screen: bloom, sun rays, the area grade, Potato's flat grade (the
--     exposure and the contrast and brightness fit stay, so the frame keeps the web's brightness:
--     docs/LIGHTING-PARITY.md), and the render distance the level's haze closes at.
--   * surfaces: what GraphicsController does to the world's instances: MaterialVariants, pure-noise wear paint and
--     decorative Detail parts. Signs, labels and wayfinding are always kept: they are gameplay information.

export type TierName = "Max" | "High" | "Medium" | "Low" | "Potato"

export type Budget = {
	lights: number, -- level-light fixtures rendered at once (nearest first)
	shadows: boolean, -- fixtures may cast shadows at all
	shadowLights: number, -- of the rendered fixtures, the nearest that keep their shadows
	fillRadius: number, -- studs: an unshadowed fixture further than this from the camera goes dark (its glow stays)
	flashlightShadows: boolean, -- the torch's inner cone, the player's own and the teammates'
	flashlightHaze: boolean, -- the torch's faint visible cone in the haze
	remoteFlashlights: number, -- teammates' torch cones rendered at once (nearest first)
	windowLights: number, -- moonlight spills through the nearest windows
	windowShadows: number, -- of those, the nearest that are shadowed (the planks stripe the floor)
	shafts: number, -- visible light shafts (fixture haze cones and window rays), nearest first
	dust: number, -- dust-mote emitters, in the nearest shafts
	particleScale: number, -- every ParticleEmitter's rate multiplier (0: no particles)
	dof: boolean, -- panic depth of field
	animNear: number, -- studs: full-rate procedural animation inside this
	animFar: number, -- studs: every third frame up to this, frozen beyond
}

export type Post = {
	bloom: boolean,
	sunRays: boolean,
	areaGrade: boolean, -- the level's colour cast (LightingMood.grade)
	flatGrade: boolean, -- the film's colour look (saturation, tint) is dropped; exposure and contrast stay
	viewDistance: number, -- studs at which the haze closes (math.huge: the level's own haze only)
}

export type Surfaces = {
	materialVariants: boolean, -- textured surfaces; off: the plain material in its palette colour
	wear: boolean, -- pure-noise wear paint (grime, soot, water runs, cracks, plaster damage)
	detailLimit: number, -- parts whose Detail attribute is above this are hidden
}

export type Tier = {
	name: TierName,
	budget: Budget,
	post: Post,
	surfaces: Surfaces,
}

-- Best first: the order the settings menu shows them in. The Graphics setting's value is an index into it.
local ORDER: { TierName } = { "Max", "High", "Medium", "Low", "Potato" }
local DEFAULT: TierName = "Max"

local GraphicsConfig = {}

GraphicsConfig.Order = table.freeze(ORDER)
GraphicsConfig.Default = DEFAULT

-- Decorative parts carry this attribute (1 is kept longest, DetailLevels dropped first). Parts without it are never
-- hidden.
GraphicsConfig.DetailAttribute = "Detail"
GraphicsConfig.DetailLevels = 3
-- An effect whose owner already follows the render budget (Volumetrics' dust, the flask's splash and cloud, burst
-- sparks) carries this attribute, and GraphicsController leaves its emitters alone.
GraphicsConfig.OwnedAttribute = "GraphicsOwned"
-- SurfaceArt guis that are pure-noise wear (Finishes and the stairwells' and ducts' grime, DecayBuilder's plaster
-- damage). Every other SurfaceGui (signs, labels, notices, hazard stripes, floor finishes) is always kept.
GraphicsConfig.WearGuis = table.freeze({ Wear = true, Damage = true } :: { [string]: boolean })
-- MaterialLibrary.overlay names its grime, dirt, rust and crack Textures "Overlay_<texture>".
GraphicsConfig.WearPrefix = "Overlay_"
-- The haze closes (95% fog) where density x distance reaches this: the web's exp² fog, (0.02 x density x d)² = 3.
GraphicsConfig.FogReach = 86.5
-- How dark the extra haze of a short render distance is, as a share of the film's own haze colour at full extra
-- density: it reads as darkness, not a wall.
GraphicsConfig.FogDarken = 0.35

-- What a tier may change, per class: client-local visual properties only. GraphicsController writes the instance
-- rows; LightingController, Film, Volumetrics and the torches write the lighting rows from the budget and post.
GraphicsConfig.Writes = table.freeze({
	BasePart = { "MaterialVariant", "Color", "LocalTransparencyModifier" },
	SurfaceGui = { "Enabled" },
	Decal = { "Transparency" }, -- and Texture, a Decal
	ParticleEmitter = { "Rate", "Enabled" },
	Light = { "Shadows", "Enabled" },
	Beam = { "Enabled", "Brightness" },
	PostEffect = { "Enabled" }, -- Bloom, SunRays, the area grade, depth of field
	ColorCorrectionEffect = { "Saturation", "TintColor" },
	Atmosphere = { "Density", "Color", "Decay" },
} :: { [string]: { string } })

-- Gameplay-relevant part properties no tier may ever write.
GraphicsConfig.Never = table.freeze({
	"CanCollide",
	"CanQuery",
	"CanTouch",
	"Size",
	"CFrame",
	"Position",
	"CollisionGroup",
	"Anchored",
	"Massless",
	"Material",
	"CustomPhysicalProperties",
	"Transparency",
} :: { string })

local function tier(name: TierName, budget: Budget, post: Post, surfaces: Surfaces): Tier
	return table.freeze({
		name = name,
		budget = table.freeze(budget),
		post = table.freeze(post),
		surfaces = table.freeze(surfaces),
	})
end

-- High, Medium and Low keep the budgets the game shipped with; Max lifts every cap for a strong PC; Potato is the
-- least that still reads as Rovloc: the torch, a few lights near you, the exposure and the grade's brightness.
local TIERS: { [TierName]: Tier } = {
	Max = tier("Max", {
		lights = 64,
		shadows = true,
		shadowLights = 56,
		fillRadius = math.huge,
		flashlightShadows = true,
		flashlightHaze = true,
		remoteFlashlights = 3,
		windowLights = 14,
		windowShadows = 6,
		shafts = 20,
		dust = 12,
		particleScale = 1,
		dof = true,
		animNear = 120,
		animFar = 300,
	}, {
		bloom = true,
		sunRays = true,
		areaGrade = true,
		flatGrade = false,
		viewDistance = math.huge,
	}, { materialVariants = true, wear = true, detailLimit = 3 }),
	High = tier("High", {
		lights = 48,
		shadows = true,
		shadowLights = 40,
		fillRadius = 220,
		flashlightShadows = true,
		flashlightHaze = true,
		remoteFlashlights = 3,
		windowLights = 10,
		windowShadows = 4,
		shafts = 14,
		dust = 8,
		particleScale = 1,
		dof = true,
		animNear = 80,
		animFar = 220,
	}, {
		bloom = true,
		sunRays = true,
		areaGrade = true,
		flatGrade = false,
		viewDistance = 300,
	}, { materialVariants = true, wear = true, detailLimit = 3 }),
	Medium = tier("Medium", {
		lights = 30,
		shadows = true,
		shadowLights = 20,
		fillRadius = 150,
		flashlightShadows = true,
		flashlightHaze = true,
		remoteFlashlights = 2,
		windowLights = 6,
		windowShadows = 0,
		shafts = 6,
		dust = 3,
		particleScale = 0.7,
		dof = false,
		animNear = 55,
		animFar = 140,
	}, {
		bloom = true,
		sunRays = false,
		areaGrade = true,
		flatGrade = false,
		viewDistance = 220,
	}, { materialVariants = true, wear = true, detailLimit = 2 }),
	Low = tier("Low", {
		lights = 16,
		shadows = false,
		shadowLights = 0,
		fillRadius = 100,
		flashlightShadows = true,
		flashlightHaze = false,
		remoteFlashlights = 1,
		windowLights = 4,
		windowShadows = 0,
		shafts = 0,
		dust = 0,
		particleScale = 0.4,
		dof = false,
		animNear = 35,
		animFar = 90,
	}, {
		bloom = false,
		sunRays = false,
		areaGrade = true,
		flatGrade = false,
		viewDistance = 160,
	}, { materialVariants = false, wear = false, detailLimit = 1 }),
	Potato = tier("Potato", {
		lights = 10,
		shadows = false,
		shadowLights = 0,
		fillRadius = 70,
		flashlightShadows = false,
		flashlightHaze = false,
		remoteFlashlights = 1,
		windowLights = 2,
		windowShadows = 0,
		shafts = 0,
		dust = 0,
		particleScale = 0,
		dof = false,
		animNear = 35,
		animFar = 90,
	}, {
		bloom = false,
		sunRays = false,
		areaGrade = false,
		flatGrade = true,
		viewDistance = 120,
	}, { materialVariants = false, wear = false, detailLimit = 0 }),
}
table.freeze(TIERS)

GraphicsConfig.Tiers = TIERS

-- The tier called `name` (the default tier for anything that is not a tier name).
function GraphicsConfig.tier(name: string): Tier
	return TIERS[name :: TierName] or TIERS[DEFAULT]
end

-- The default tier, Max (typed, where GraphicsConfig.Default reads as a plain string).
function GraphicsConfig.default(): Tier
	return TIERS[DEFAULT]
end

-- The tier at a Graphics setting value (an index into Order); anything else reads as the default.
function GraphicsConfig.tierAt(index: number): Tier
	local name: TierName? = ORDER[index]
	return TIERS[name or DEFAULT]
end

-- A tier's index in Order (1, Max, for anything that is not a tier name).
function GraphicsConfig.indexOf(name: string): number
	return table.find(ORDER, name :: TierName) or 1
end

-- The Atmosphere density at which the haze closes at `distance` studs (0 for an unlimited distance).
function GraphicsConfig.viewDensity(distance: number): number
	if distance >= math.huge or distance <= 0 then
		return 0
	end
	return GraphicsConfig.FogReach / distance
end

return table.freeze(GraphicsConfig)
