-- Rovloc Web: export the real Roblox world, built by the game's own builders in the Lune harness, to JSON.
--
--   cd web && lune run tools/export-world.luau [out.json]      (default build/cache/world-raw.json)
--
-- The place is built fresh with `rojo build` (default.project.json), then this script does what a real run does at
-- the fixed seed RunSeed = 20251029 on Standard difficulty:
--   * WorldService.Start: ProceduralWorldBuilder.BuildAuthoritative() (lobby, the six levels with their statics,
--     stair towers, exterior) and the LightingRig baseline;
--   * WorldService.BeginRun: the director's plan (RunDirector.plan over ZoneGraph.build) -> BuildProp for every
--     planned prop and BuildFixtures for every level (grates with the plan's locks, doors, gate, lockers, crate,
--     floodlight switch) into Workspace.Runtime;
--   * the client's CosmeticWorldController: BuildCosmetic(seed) (skyline + anchor dressing);
--   * the Creature rig (CreatureRigBuilder) at the origin, for the rig export;
--   * the client LightingController's moonlight windows (Volumetrics.windowSpecs) for every layout.
-- Everything the web build needs is written as plain JSON (CFrames as 12 numbers x,y,z,R00..R22, colours as 0..1
-- floats, enums by name). web/tools/bake.mjs turns it into the packed runtime data (see web/DATA.md).
--
-- Known difference from Roblox: the harness's Random is a deterministic xorshift, not Roblox's PCG32, so seeded
-- choices (which traps, which dead tubes revive) are the same on every export but not the same as on a live server.

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local Harness = require("../../tools/lune/harness")

local RUN_SEED = 20251029
local DIFFICULTY = "Standard"

local repo = if fs.isDir("../src") and fs.isFile("../default.project.json") then ".." else "."
local outPath = process.args[1] or (if repo == ".." then "build/cache/world-raw.json" else "web/build/cache/world-raw.json")
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
local MathUtil = h.require("ReplicatedStorage.Shared.Util.MathUtil")
local Palette = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Palette")
local TextureAssets = h.require("ReplicatedStorage.Shared.Config.TextureAssets")
local WorldConfig = h.require("ReplicatedStorage.Shared.Config.WorldConfig")
local ZoneGraph = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph")
local VentGraph = h.require("ReplicatedStorage.Shared.Vents.VentGraph")
local CreatureConfig = h.require("ReplicatedStorage.Shared.Config.CreatureConfig")
local RunDirector = h.require("ServerScriptService.Services.Core.NoiseAndDirectorService.RunDirector")
local Volumetrics = h.require("StarterPlayer.StarterPlayerScripts.Controllers.Core.LightingController.Volumetrics")

--------------------------------------------------------------------------------
-- Build exactly what a run builds
--------------------------------------------------------------------------------

local result = Builder.BuildAuthoritative({ parent = Workspace, yieldEvery = 0 })
Builder.ApplyLighting()
Instances.ensureRuntime()

local layouts = Builder.layouts()
local plan = RunDirector.plan(RUN_SEED, DIFFICULTY, layouts, ZoneGraph.build(layouts))
for _, prop in plan.props do
	local parent = Instances.runtimeLevel(prop.levelId, true)
	local random = MathUtil.seededRandom(plan.seed, "prop:" .. prop.kind .. ":" .. prop.anchorId)
	Builder.BuildProp(prop, parent, random)
end
for _, levelId in Enums.LevelId do
	Builder.BuildFixtures(levelId, Instances.runtimeLevel(levelId, true), plan, plan.seed)
end
local cosmetic = roblox.Instance.new("Folder")
cosmetic.Name = "Cosmetic"
cosmetic.Parent = Workspace
Builder.BuildCosmetic(RUN_SEED, cosmetic)

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
			out[tostring(key)] = toJson(item, d + 1)
		end
		return out
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
-- Classification
--------------------------------------------------------------------------------

local school = Workspace:FindFirstChild("School")
local lobby = Workspace:FindFirstChild("Lobby")
local runtime = Workspace:FindFirstChild("Runtime")

local LEVEL_IDS = {}
for _, id in Enums.LevelId do
	table.insert(LEVEL_IDS, id)
end

-- The level key a world position belongs to (cosmetic dressing and skyline are placed by position).
local function levelForPosition(p): string
	if p.X < -400 then
		return "Lobby"
	end
	local inFootprint = p.X >= -0.5 and p.X <= 240.5 and p.Z >= -0.5 and p.Z <= 160.5
	if not inFootprint then
		local inTower = (p.X >= -28 and p.X <= 0 or p.X >= 240 and p.X <= 268) and p.Z >= 64 and p.Z <= 96
		if inTower and p.Y < WorldConfig.Levels.Level5_Roof.elevation then
			return "Stairwells"
		end
		if p.Y > WorldConfig.Levels.Level5_Roof.elevation - 2 and p.X > -40 and p.X < 280 and p.Z > -40 and p.Z < 200 then
			return "Level5_Roof"
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

-- Volumes and roots never render: zones, triggers, anchor / waypoint roots, vent node roots, hitboxes.
local function isVolume(part): boolean
	return part.Transparency >= 0.999 and not part.CanCollide
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
		color = c3(part.Color),
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
	if not d:IsA("BasePart") then
		continue
	end
	local entity = entityIndexOf(d)
	if entity then
		exportPart(d, { level = entityRoots[entity].level, source = "Entity", entity = entity, entityRoot = entityRoots[entity].root })
	else
		local level, source = staticPlace(d)
		exportPart(d, { level = level, source = source })
	end
end

for _, d in Workspace:GetDescendants() do
	if d:IsA("BasePart") and isVolume(d) then
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
				hostCFrame = if host and host:IsA("BasePart") then cf(host.CFrame) elseif host and host:IsA("Attachment") and host.Parent and host.Parent:IsA("BasePart") then cf(host.Parent.CFrame * host.CFrame) else nil,
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
for _, name in { "ClockTime", "Brightness", "Ambient", "OutdoorAmbient", "EnvironmentDiffuseScale", "EnvironmentSpecularScale", "ExposureCompensation", "ShadowSoftness", "GeographicLatitude", "FogColor", "FogEnd", "FogStart", "ColorShift_Top", "ColorShift_Bottom" } do
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
				color = c3(d.Color),
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
	}
end

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
	worldConfig = toJson(WorldConfig),
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
			for _, kind in { "Fluorescent", "ClassroomGlow", "Bulb", "Floodlight", "EmergencyRed", "ExitSign", "BoilerGlow" } do
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
	windows = windows,
	creature = creature,
}

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
