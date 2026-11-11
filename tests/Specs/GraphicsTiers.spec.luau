--!strict
-- Graphics tiers (GraphicsConfig, GraphicsController, RenderBudgetController, Film): Max is the default and Potato the
-- floor, and every lower tier only takes visual detail away (the torch keeps its shadow down to Low). The Graphics
-- setting saves an index the server's validator accepts, and the menu names and describes every option. The tiers
-- write client-local visual properties only, and the post keeps the exposure, the contrast fit and the fills. A real
-- level is put through every tier and back to Max: every part keeps its collision, queries, size, CFrame and collision
-- group the whole way, and at the end it looks exactly as built.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GraphicsConfig = require(ReplicatedStorage.Shared.Config.GraphicsConfig)
local LightingMood = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LightingMood)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local Strings = require(ReplicatedStorage.Shared.Strings)

local Controllers = StarterPlayer.StarterPlayerScripts.Controllers
local Film = require(Controllers.Core.LightingController.Film)
local GraphicsController = require(Controllers.Core.GraphicsController)
local LightingController = require(Controllers.Core.LightingController)
local RenderBudgetController = require(Controllers.Core.RenderBudgetController)
local SettingsController = require(Controllers.Core.SettingsController)
local SettingsMenu = require(Controllers.HUD.SettingsMenu)

type Expect = SpecRunner.Expect
type TierName = GraphicsConfig.TierName

local LEVEL: Enums.LayoutId = "Level1_Hallways"
local WORLD_RATE = 3 -- the sample world emitter's built rate
local OWNED_RATE = 5

-- What gameplay reads off a part: none of it may change on any tier.
local GAMEPLAY: { string } = {
	"CanCollide",
	"CanQuery",
	"CanTouch",
	"Size",
	"CFrame",
	"CollisionGroup",
	"Anchored",
	"Massless",
	"Material",
	"Transparency",
}

-- What the tiers may change, per instance family: put back exactly by Max.
local VISUAL: { [string]: { string } } = {
	BasePart = { "MaterialVariant", "Color", "LocalTransparencyModifier" },
	SurfaceGui = { "Enabled" },
	Decal = { "Transparency" },
	ParticleEmitter = { "Rate", "Enabled" },
}

local function family(instance: Instance): string?
	for _, name in { "BasePart", "SurfaceGui", "Decal", "ParticleEmitter" } do
		if instance:IsA(name) then
			return name
		end
	end
	return nil
end

type Snapshot = { [Instance]: { any } }

-- A property's value; LocalTransparencyModifier nothing has set yet reads as the engine's 0 (Lune has no default).
local function read(instance: Instance, property: string): any
	local ok, value = pcall(function(): any
		return (instance :: any)[property]
	end)
	if ok then
		return value
	end
	return if property == "LocalTransparencyModifier" then 0 else nil
end

local function snapshot(root: Instance, visual: boolean): Snapshot
	local out: Snapshot = {}
	for _, instance in root:GetDescendants() do
		local kind = family(instance)
		local properties: { string }? = nil
		if visual and kind then
			properties = VISUAL[kind]
		elseif not visual and kind == "BasePart" then
			properties = GAMEPLAY
		end
		if properties then
			local values: { any } = {}
			for i, property in properties do
				values[i] = read(instance, property)
			end
			out[instance] = values
		end
	end
	return out
end

-- The first difference between two snapshots ("" when they match), and how many instances differ.
local function compare(before: Snapshot, after: Snapshot, visual: boolean): (string, number)
	local first = ""
	local count = 0
	for instance, values in before do
		local now = after[instance]
		local kind = family(instance)
		local properties = if visual and kind then VISUAL[kind] else GAMEPLAY
		for i, value in values do
			if now == nil or now[i] ~= value then
				count += 1
				if first == "" then
					first = string.format(
						"%s.%s: %s -> %s",
						instance:GetFullName(),
						properties[i],
						tostring(value),
						tostring(now and now[i])
					)
				end
				break
			end
		end
	end
	return first, count
end

-- Samples of what the maps wave and later builders add: Detail parts, a grime overlay and a poster, a world emitter
-- and one whose owner follows the budget itself, a wear gui and a sign.
type Samples = {
	detail: { Part },
	overlay: Texture,
	poster: Decal,
	emitter: ParticleEmitter,
	owned: ParticleEmitter,
	wear: SurfaceGui,
	sign: SurfaceGui,
}

local function addSamples(parent: Instance): Samples
	local folder = Instance.new("Folder")
	folder.Name = "Samples"
	folder.Parent = parent
	local detail: { Part } = {}
	for level = 1, 3 do
		local part = Instance.new("Part")
		part.Name = "Detail" .. level
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part:SetAttribute(GraphicsConfig.DetailAttribute, level)
		part.Parent = folder
		table.insert(detail, part)
	end
	local wall = Instance.new("Part")
	wall.Name = "Wall"
	wall.Anchored = true
	wall.Parent = folder
	local overlay = Instance.new("Texture")
	overlay.Name = GraphicsConfig.WearPrefix .. "WallGrime"
	overlay.Transparency = 0.2
	overlay.Parent = wall
	local poster = Instance.new("Decal")
	poster.Name = "Poster"
	poster.Parent = wall
	local wear = Instance.new("SurfaceGui")
	wear.Name = "Wear"
	wear.Parent = wall
	local sign = Instance.new("SurfaceGui")
	sign.Name = "Print"
	sign.Parent = wall
	local attachment = Instance.new("Attachment")
	attachment.Parent = wall
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Drops"
	emitter.Rate = WORLD_RATE
	emitter.Parent = attachment
	local owned = Instance.new("ParticleEmitter")
	owned.Name = "Dust"
	owned.Rate = OWNED_RATE
	owned:SetAttribute(GraphicsConfig.OwnedAttribute, true)
	owned.Parent = attachment
	return {
		detail = detail,
		overlay = overlay,
		poster = poster,
		emitter = emitter,
		owned = owned,
		wear = wear,
		sign = sign,
	}
end

local function texturedParts(root: Instance): { BasePart }
	local out: { BasePart } = {}
	for _, instance in root:GetDescendants() do
		if instance:IsA("BasePart") and instance.MaterialVariant ~= "" then
			table.insert(out, instance)
		end
	end
	return out
end

local function guisNamed(root: Instance, wear: boolean): { SurfaceGui }
	local out: { SurfaceGui } = {}
	for _, instance in root:GetDescendants() do
		if instance:IsA("SurfaceGui") and (GraphicsConfig.WearGuis[instance.Name] == true) == wear then
			table.insert(out, instance)
		end
	end
	return out
end

-- Builds LEVEL (plus the samples) into a fresh folder, runs `body`, and always removes the folder.
local function withLevel(body: (root: Folder, samples: Samples) -> ())
	local root = Instance.new("Folder")
	root.Name = "GraphicsTiersSpec"
	root.Parent = Workspace
	local ok, err = pcall(function()
		Builder.BuildAuthoritative({ parent = root :: Instance, layouts = { LEVEL }, yieldEvery = 0 })
		body(root, addSamples(root))
	end)
	root:Destroy()
	if not ok then
		error(err, 0)
	end
end

return {
	["the Graphics setting picks Max by default and saves an index the server accepts"] = function(t: Expect)
		t.eq(table.concat(GraphicsConfig.Order, ","), "Max,High,Medium,Low,Potato")
		t.eq(GraphicsConfig.Default, "Max")
		local setting = SettingsSchema.get("Graphics")
		assert(setting and setting.kind == "Choice", "Graphics is a choice")
		local choice = setting :: SettingsSchema.ChoiceSetting
		t.falsy(choice.hidden, "shown in the settings menu")
		t.eq(choice.options[choice.default], "Max", "Max by default")
		t.eq(SettingsSchema.defaults().Graphics, 1)
		t.eq(SettingsSchema.option("Graphics", 5), "Potato")
		t.eq(SettingsSchema.option("Graphics", 42), "Max", "out of range reads as the default")
		t.eq(SettingsSchema.option("Captions", true), nil, "only choices have options")
		t.eq(SettingsController.sanitize("Graphics", 2.4), 2)
		t.eq(SettingsController.sanitize("Graphics", 0), 1, "clamped to Max")
		t.eq(SettingsController.sanitize("Graphics", 9), 5, "clamped to Potato")
		t.eq(SettingsController.sanitize("Graphics", "Potato"), nil, "saved as an index, never a name")
		t.eq(SettingsController.decode('{"Graphics":4}').Graphics, 4, "a saved tier loads")
		t.eq(SettingsController.GetChoice("Graphics"), "Max")
		local spec = RemoteRegistry.get("SettingsSave")
		local validate = if spec then spec.validate else nil
		assert(validate, "SettingsSave is validated")
		local values = SettingsSchema.defaults()
		for index = 1, #GraphicsConfig.Order do
			values.Graphics = index
			t.truthy(validate(SettingsController.payload(values)), "tier " .. index .. " validates")
		end
		local bad = SettingsController.payload(SettingsSchema.defaults())
		bad.settings.Graphics = 6
		t.falsy(validate(bad), "an index past Potato is refused")
		for index, name in GraphicsConfig.Order do
			t.eq(GraphicsController.tierOf(index), name)
			local nameKey, infoKey = SettingsMenu.optionKeys(choice, index)
			t.truthy(Strings.has(nameKey) and Strings.has(infoKey), name .. " is named and described")
			t.eq(string.find(Strings.get(infoKey), "\n", 1, true), nil, name .. "'s description is one line")
		end
		local _, potatoInfo = SettingsMenu.optionKeys(choice, 5)
		t.truthy(
			string.find(string.lower(Strings.get(potatoInfo)), "for school chromebooks", 1, true) ~= nil,
			"Potato reads 'for school Chromebooks'"
		)
		t.eq(GraphicsController.tierOf(nil), "Max")
		t.eq(GraphicsController.tierOf(99), "Max")
		t.eq(SettingsMenu.choiceStepped(choice, 1, -1), 1, "no step past Max")
		t.eq(SettingsMenu.choiceStepped(choice, 4, 1), 5)
		t.eq(SettingsMenu.choiceStepped(choice, 5, 1), 5, "no step past Potato")
	end,

	["every lower tier only takes visual detail away"] = function(t: Expect)
		local order = GraphicsConfig.Order
		for i = 2, #order do
			local better = GraphicsConfig.tier(order[i - 1]) :: any
			local worse = GraphicsConfig.tier(order[i]) :: any
			for _, group in { "budget", "post", "surfaces" } do
				for key, value in worse[group] do
					local above = better[group][key]
					local label = string.format("%s.%s.%s", order[i], group, key)
					if type(value) == "number" then
						t.truthy(value <= above, label .. " is no more than " .. order[i - 1] .. "'s")
					elseif key == "flatGrade" then
						t.truthy(value or not above, label .. " stays flat below a flat tier")
					elseif type(value) == "boolean" then
						t.truthy(above or not value, label .. " is only on where the tier above has it")
					end
				end
			end
		end
		local max, low, potato = GraphicsConfig.tier("Max"), GraphicsConfig.tier("Low"), GraphicsConfig.tier("Potato")
		t.truthy(max.post.bloom and max.post.sunRays and max.post.areaGrade and not max.post.flatGrade, "Max: all post")
		t.eq(max.post.viewDistance, math.huge, "Max: the level's own haze only")
		t.eq(max.budget.fillRadius, math.huge, "Max: no light LOD")
		t.truthy(max.surfaces.materialVariants and max.surfaces.wear, "Max: every texture and all the wear")
		t.eq(max.surfaces.detailLimit, GraphicsConfig.DetailLevels, "Max: every Detail part")
		t.truthy(GraphicsController.isFull(GraphicsController.lookFor("Max")), "Max changes nothing a builder made")
		t.falsy(GraphicsController.isFull(GraphicsController.lookFor("Medium")), "Medium does")
		t.truthy(
			max.budget.shadows and max.budget.dof and max.budget.particleScale == 1,
			"Max: shadows, DOF, particles"
		)
		for _, name in { "Max", "High", "Medium", "Low" } do
			t.truthy(GraphicsConfig.tier(name).budget.flashlightShadows, name .. " keeps the torch's shadow")
			t.truthy(GraphicsConfig.tier(name).budget.particleScale > 0, name .. " keeps some particles")
		end
		t.falsy(potato.budget.flashlightShadows, "Potato casts no shadows at all")
		t.falsy(low.budget.shadows or potato.budget.shadows, "no fixture shadows on Low or Potato")
		for _, name in { "Max", "High", "Medium" } do
			t.truthy(GraphicsConfig.tier(name).surfaces.materialVariants, name .. " keeps MaterialVariants")
		end
		t.falsy(low.surfaces.materialVariants or potato.surfaces.materialVariants, "plain materials on Low and Potato")
		t.falsy(low.surfaces.wear or potato.surfaces.wear, "no wear paint on Low and Potato")
		t.eq(potato.budget.particleScale, 0, "no particles on Potato")
		t.eq(low.budget.shafts + low.budget.dust + potato.budget.shafts + potato.budget.dust, 0, "no shafts or dust")
		t.falsy(potato.post.bloom or potato.post.sunRays or potato.post.areaGrade or potato.budget.dof, "Potato post")
		t.truthy(potato.post.flatGrade, "Potato keeps a flat grade")
		t.truthy(potato.budget.lights > 0 and potato.budget.windowLights > 0, "Potato still lights the way")
		for _, name in order do
			local budget = RenderBudgetController.budgetFor(name :: TierName)
			t.eq(budget.tier, name)
			for key, value in GraphicsConfig.tier(name).budget do
				t.eq((budget :: any)[key], value, name .. " publishes its " .. tostring(key))
			end
			t.truthy(budget.shadowLights + budget.windowShadows <= budget.lights, name .. " shadows only what burns")
		end
		local writes = GraphicsConfig.Writes.BasePart
		for _, property in GraphicsConfig.Never do
			t.eq(table.find(writes, property), nil, property .. " is never a part write")
		end
	end,

	["the post keeps the exposure, the contrast fit and the fills on every tier"] = function(t: Expect)
		local layouts: { string } = {}
		for _, layout in Builder.layouts() do
			table.insert(layouts, layout.id)
		end
		local kept = {
			"exposure",
			"contrast",
			"brightness",
			"ambient",
			"outdoorAmbient",
			"haze",
			"fixtureGain",
			"fixtureRange",
			"torch",
		}
		local graded: { [string]: boolean } = {
			bloomIntensity = true,
			sunRays = true,
			saturation = true,
			density = true,
			hazeColor = true,
			decay = true,
		}
		for i = 1, #layouts + 1 do
			local layoutId: string? = layouts[i] -- the last pass: outdoors (no layout)
			local grade, render = LightingMood.film(layoutId), LightingMood.render(layoutId)
			local where = tostring(layoutId or "outdoors")
			for _, name in GraphicsConfig.Order do
				local post = GraphicsConfig.tier(name).post
				local g, r = Film.graded(grade, render, post)
				for _, key in kept do
					t.eq(
						(r :: any)[key],
						(render :: any)[key],
						string.format("%s %s keeps the render's %s", where, name, key)
					)
				end
				for key, value in grade :: any do
					if not graded[key] then
						t.eq((g :: any)[key], value, string.format("%s %s keeps the film's %s", where, name, key))
					end
				end
				t.truthy(g.density >= grade.density, where .. " " .. name .. ": the haze only thickens")
				if name == "Max" then
					t.truthy(g == grade and r == render, where .. ": Max is the film itself")
				end
				if post.viewDistance < math.huge then
					t.truthy(
						g.density * post.viewDistance >= GraphicsConfig.FogReach - 1e-6,
						where .. " " .. name .. " closes"
					)
					t.truthy(
						g.hazeColor.R <= grade.hazeColor.R + 1e-9 and g.decay.B <= grade.decay.B + 1e-9,
						where .. " " .. name .. ": the extra haze is darker, not a grey wall"
					)
				end
				if not post.bloom then
					t.eq(g.bloomIntensity, 0)
				end
				if post.flatGrade then
					t.eq(g.saturation, 0, "a flat grade")
					t.eq(r.tint, Color3.new(1, 1, 1))
				end
			end
		end
	end,

	["the steam vents follow the particle budget, and Detail is the world's Detail attribute"] = function(t: Expect)
		t.eq(GraphicsConfig.DetailAttribute, Attributes.World.Detail, "the builders' Detail attribute")
		for _, tier: GraphicsConfig.Tier in GraphicsConfig.Tiers do
			local scale = tier.budget.particleScale
			local rate = LightingController.steamRate(12, scale)
			t.near(rate, 12 * scale, 1e-9, tier.name .. ": steam at the tier's particle scale")
		end
		t.eq(LightingController.steamRate(12, 0), 0, "no steam without particles (Potato)")
		t.eq(LightingController.steamRate(0, 1), 0, "an emitter that never steamed stays off")
	end,

	["only unshadowed fixtures past the tier's fill radius go dark"] = function(t: Expect)
		t.truthy(LightingController.fillKept(10, false, false, 100))
		t.falsy(LightingController.fillKept(120, false, false, 100), "an unshadowed fixture past the radius")
		t.truthy(LightingController.fillKept(120, true, false, 100), "a shadowed fixture always burns")
		t.truthy(LightingController.fillKept(500, false, true, 100), "so does a forced one (an override, a burst)")
		local radius = GraphicsConfig.tier("Max").budget.fillRadius
		t.truthy(LightingController.fillKept(1e6, false, false, radius), "Max has no radius")
	end,

	["every tier writes only client-local visual properties, and a level keeps its gameplay through all of them"] = function(
		t: Expect
	)
		withLevel(function(root: Folder, samples: Samples)
			local textured = texturedParts(root)
			t.truthy(#textured > 100, "the level is textured")
			local first = textured[1]
			first:SetAttribute(GraphicsConfig.DetailAttribute, 2) -- a textured Detail part
			local wearGuis = guisNamed(root, true)
			local signs = guisNamed(root, false)
			t.truthy(#wearGuis > 10 and #signs > 1, "the level has wear paint and signs")

			-- The writes every tier plans are on the whitelist.
			for _, name in GraphicsConfig.Order do
				local look = GraphicsController.lookFor(name)
				local offWhitelist = ""
				local touched = 0
				for _, instance in root:GetDescendants() do
					local original = GraphicsController.capture(instance)
					local kind = family(instance)
					if original and kind then
						touched += 1
						local allowed = GraphicsConfig.Writes[kind]
						for property in GraphicsController.plan(instance, original, look) do
							if not table.find(allowed, property) and offWhitelist == "" then
								offWhitelist = kind .. "." .. property
							end
						end
					end
				end
				t.eq(offWhitelist, "", name .. " writes only whitelisted properties")
				t.truthy(touched > #textured, name .. " plans for the textured parts and more")
			end

			local gameplay = snapshot(root, false)
			local visual = snapshot(root, true)
			local memory = GraphicsController.newMemory()
			local colour = first.Color
			local variant = first.MaterialVariant
			for _, sequence in { GraphicsConfig.Order, { "Potato", "High", "Low", "Medium" } } do
				for _, name in sequence :: { TierName } do
					local tier = GraphicsConfig.tier(name)
					local look = GraphicsController.lookFor(name)
					GraphicsController.applyTo(root, look, memory)
					local diff, count = compare(gameplay, snapshot(root, false), false)
					t.eq(count, 0, name .. " leaves gameplay alone (" .. diff .. ")")

					local plain = 0
					for _, part in textured do
						if part.MaterialVariant == "" then
							plain += 1
						end
					end
					t.eq(plain, if tier.surfaces.materialVariants then 0 else #textured, name .. " textures")
					if not tier.surfaces.materialVariants then
						local expected = GraphicsController.plainColor(colour, variant, first.Material)
						t.truthy(
							first.Color == expected and expected ~= colour,
							name .. ": plain parts get the palette colour"
						)
					end
					local wearShown, signsHidden = 0, 0
					for _, gui in wearGuis do
						if gui.Enabled then
							wearShown += 1
						end
					end
					for _, gui in signs do
						if not gui.Enabled then
							signsHidden += 1
						end
					end
					t.eq(wearShown, if tier.surfaces.wear then #wearGuis else 0, name .. " wear paint")
					t.eq(signsHidden, 0, name .. " keeps every sign, label and wayfinding mark")
					t.near(
						samples.overlay.Transparency,
						if tier.surfaces.wear then 0.2 else 1,
						1e-6,
						name .. " grime overlay"
					)
					t.eq(samples.poster.Transparency, 0, name .. " leaves other decals alone")
					for level, part in samples.detail do
						local hidden = level > tier.surfaces.detailLimit
						t.eq(part.LocalTransparencyModifier, if hidden then 1 else 0, name .. " Detail " .. level)
					end
					t.eq(first.LocalTransparencyModifier, if 2 > tier.surfaces.detailLimit then 1 else 0, name)
					local scale = tier.budget.particleScale
					t.near(samples.emitter.Rate, WORLD_RATE * scale, 1e-6, name .. " world particles")
					t.eq(samples.emitter.Enabled, scale > 0, name .. " particles off only at 0")
					t.truthy(
						samples.owned.Rate == OWNED_RATE and samples.owned.Enabled,
						name .. " leaves owned effects"
					)

					-- Something arriving now (DescendantAdded) gets the tier too.
					local late = Instance.new("Part")
					late.Material = first.Material
					late.MaterialVariant = variant
					late.Color = colour
					late:SetAttribute(GraphicsConfig.DetailAttribute, 3)
					late.Parent = samples.wear.Parent
					GraphicsController.applyOne(late, look, memory)
					t.eq(late.MaterialVariant, if tier.surfaces.materialVariants then variant else "", name .. " late")
					t.eq(
						late.LocalTransparencyModifier,
						if 3 > tier.surfaces.detailLimit then 1 else 0,
						name .. " late"
					)
					late:Destroy()
				end
				GraphicsController.applyTo(root, GraphicsController.lookFor("Max"), memory)
				local gameplayDiff, gameplayCount = compare(gameplay, snapshot(root, false), false)
				t.eq(gameplayCount, 0, "back on Max, gameplay is as built (" .. gameplayDiff .. ")")
				local visualDiff, visualCount = compare(visual, snapshot(root, true), true)
				t.eq(visualCount, 0, "back on Max, it looks exactly as built (" .. visualDiff .. ")")
			end
		end)
	end,
}
