--!strict
-- The scary-surroundings pass (DreadKit, DreadBuilder, DreadConfig), on the floors it dresses:
--   * Budgets: at most DreadConfig.Budget.Parts parts per floor, of them at most Budget.Signature signature parts (no
--     Detail attribute: drawn on Potato) and enough of those for the story to survive there; everything else Detail 1..3.
--   * Cosmetic is cosmetic (I3): no part collides, is queried or touched or casts a shadow; none sits in a doorway, a
--     leaf's swing, a grate front, a landing, a spawn, a gameplay anchor's reach or a hiding spot's niche; the floors'
--     planned rooms, doors and zone graph keep the hashes ExtraAnchors.spec recorded, and their walk graph, anchors and
--     triggers are the same before and after the kit plans and builds.
--   * Content limits (I12): no forbidden word in any name, attribute, decal text or line of DreadConfig; the writing
--     is DreadConfig's (spec 2.8's lore lines included); every clock reads 3:31.
--   * The same world for the same layout: planned afresh, the kit places the same parts.
--   * Every kind of the kit shows on both floors; the dying circuits are circuits that already flicker.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local DreadConfig = require(ReplicatedStorage.Shared.Config.DreadConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Strings = require(ReplicatedStorage.Shared.Strings)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local DreadKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.DreadKit)
local Props = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props)
local SetDressingBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.SetDressingBuilder)
local TunnelRules = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.TunnelRules)
local ZoneGraph = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Layout = LayoutSchema.LevelLayout

local FLOORS = { "Level0_Basement", "Level1_Hallways" }
-- ExtraAnchors.spec's recording of the untouched plans (rooms, doors and zone graph; FNV-1a of the rows as text)
local RECORDED: { [string]: { hash: string, rows: number } } = {
	Level0_Basement = { hash = "adca49fa", rows = 1105 },
	Level1_Hallways = { hash = "1e6ef063", rows = 1403 },
}
-- the story's signature pieces a floor shows on Potato at the least
local SIGNATURE_MIN = 24
-- every kind of the kit, on both floors; and the ones only the Hallways have (the office's barricade, the trophy case)
local KINDS = {
	"Gouge",
	"CeilingGouge",
	"ForcedFrame",
	"PorcelainTrail",
	"MaskShard",
	"Backpack",
	"Shoe",
	"Phone",
	"Papers",
	"KnockedOver",
	"Coats",
	"Writing",
	"Tally",
	"Clock",
	"Notice",
	"Drawing",
	"WaterStain",
	"Mould",
	"Peel",
	"Cobweb",
	"HangingWire",
	"DyingFixture",
}
local HALLWAY_KINDS = { "Barricade", "TrophyCase" }

local function layoutOf(id: string): Layout
	local layout = Builder.getLayout(id)
	assert(layout, id .. " loads")
	return layout
end

local function optionsOf(id: string): DreadKit.Options
	local options = DreadKit.levelOptions(id)
	assert(options, id .. " is dressed")
	return options
end

local builtCache: { [string]: Model } = {}

-- The kit's model for floor `id`, built the way DreadBuilder builds it.
local function built(id: string): Model
	local cached = builtCache[id]
	if cached then
		return cached
	end
	local folder = Instance.new("Folder")
	local layout = layoutOf(id)
	DreadKit.build(folder, layout, DreadKit.plan(layout, optionsOf(id)))
	local model = folder:FindFirstChild("Dread_" .. id)
	assert(model and model:IsA("Model"), id .. " built a Dread model")
	builtCache[id] = model
	return model
end

local function partsOf(root: Instance): { BasePart }
	local out: { BasePart } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(out, d)
		end
	end
	return out
end

local function aabb(part: BasePart): (Vector3, Vector3)
	local cf = part.CFrame
	local half = part.Size / 2
	local rx, ry, rz = cf.RightVector, cf.UpVector, cf.LookVector
	local extent = Vector3.new(
		math.abs(rx.X) * half.X + math.abs(ry.X) * half.Y + math.abs(rz.X) * half.Z,
		math.abs(rx.Y) * half.X + math.abs(ry.Y) * half.Y + math.abs(rz.Y) * half.Z,
		math.abs(rx.Z) * half.X + math.abs(ry.Z) * half.Y + math.abs(rz.Z) * half.Z
	)
	return cf.Position - extent, cf.Position + extent
end

local function num(x: number?): string
	return if x == nil then "-" else string.format("%.3f", x)
end

-- ExtraAnchors.spec's recipe: the plan's rooms, doors and zone graph as text, hashed.
local function planHash(layout: Layout): (string, number)
	local rows: { string } = {}
	for _, r in layout.rooms do
		local rect = r.rect
		table.insert(
			rows,
			table.concat(
				{ "R", r.id, r.kind, num(rect.x), num(rect.z), num(rect.w), num(rect.d), num(r.height), num(r.drop) },
				"|"
			)
		)
	end
	for _, d in layout.doors do
		local row = {
			"D",
			d.id,
			d.kind,
			d.rooms[1],
			d.rooms[2],
			num(d.at),
			num(d.width),
			num(d.height),
			tostring(d.crawlOnly == true),
			d.scriptedId or "-",
		}
		table.insert(rows, table.concat(row, "|"))
	end
	local graph = ZoneGraph.build({ layout })
	local ids: { string } = {}
	for id in graph.nodes do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local n = graph.nodes[id]
		table.insert(rows, table.concat({ "N", id, n.kind, num(n.center.X), num(n.center.Y), num(n.center.Z) }, "|"))
	end
	for _, e in graph.edges do
		local row = {
			"E",
			e.a,
			e.b,
			e.kind,
			e.portalId,
			num(e.length),
			num(e.clearance),
			tostring(e.crawlOnly == true),
			tostring(e.lip == true),
		}
		table.insert(rows, table.concat(row, "|"))
	end
	return string.format("%08x", MathUtil.hash(table.concat(rows, "\n"))), #rows
end

-- The walk graph, the anchors and the triggers of `layout` as text.
local function gameplayText(layout: Layout): string
	local rows: { string } = {}
	for _, crawl in { false, true } do
		local g = TunnelRules.walkGraph(layout :: any, crawl, true)
		for i, p in g.pos do
			local links: { string } = {}
			for _, link in g.links[i] do
				table.insert(links, string.format("%d:%.3f", link.to, link.cost))
			end
			table.insert(rows, string.format("W%d %.3f %.3f %s", i, p.X, p.Y, table.concat(links, ",")))
		end
	end
	for _, anchor in layout.anchors do
		local p = anchor.pos
		table.insert(
			rows,
			string.format("A %s %s %.3f %.3f %.3f %s", anchor.id, anchor.kind, p.X, p.Y, p.Z, num(anchor.yaw))
		)
	end
	for _, trigger in layout.triggers do
		table.insert(rows, string.format("T %s %s", trigger.id, trigger.kind))
	end
	return table.concat(rows, "\n")
end

-- Every word-bearing thing of a built model: part names, string attributes, decal texts.
local function wordsOf(root: Instance): { string }
	local out: { string } = {}
	for _, d in root:GetDescendants() do
		table.insert(out, d.Name)
		for _, value in d:GetAttributes() do
			if type(value) == "string" then
				table.insert(out, value)
			end
		end
		if d:IsA("TextLabel") then
			table.insert(out, d.Text)
		end
	end
	return out
end

local function forbiddenIn(text: string): string?
	local lower = string.lower(text)
	for _, word in DreadConfig.Forbidden do
		if string.find(lower, word, 1, true) then
			return word
		end
	end
	return nil
end

return {
	["the dressed floors keep to the budgets, with signature pieces on Potato and Detail on the rest"] = function(
		t: Expect
	)
		for _, id in FLOORS do
			local parts = partsOf(built(id))
			local signature, decals = 0, 0
			for _, part in parts do
				local level = part:GetAttribute(Attributes.World.Detail)
				if level == nil then
					signature += 1
				else
					t.truthy(level == 1 or level == 2 or level == 3, part.Name .. " Detail 1..3")
				end
				if part:FindFirstChildOfClass("SurfaceGui") then
					decals += 1
				end
			end
			t.truthy(#parts <= DreadConfig.Budget.Parts, string.format("%s: %d parts", id, #parts))
			t.truthy(signature <= DreadConfig.Budget.Signature, string.format("%s: %d signature parts", id, signature))
			t.truthy(signature >= SIGNATURE_MIN, string.format("%s: %d signature parts on Potato", id, signature))
			t.truthy(decals * 4 >= #parts, string.format("%s: decals preferred (%d of %d)", id, decals, #parts))
			local plan = DreadKit.plan(layoutOf(id), optionsOf(id))
			t.eq(plan.parts, #parts, id .. " plan's part count")
			t.eq(plan.signature, signature, id .. " plan's signature count")
		end
		t.eq(DreadConfig.Budget.Parts, 450)
		t.eq(DreadConfig.Budget.Signature, 60)
	end,

	["nothing collides, is queried, touched or shadowed, and nothing sits in a clearance"] = function(t: Expect)
		for _, id in FLOORS do
			local layout = layoutOf(id)
			local info = SetDressingBuilder.Kit.info(layout)
			local origin = WorldConfig.levelOrigin(id)
			local boxes: { any } = {}
			for _, zone in info.zones do
				if not zone.solidOnly then
					table.insert(boxes, zone)
				end
			end
			for _, zone in DreadKit.clearances(layout) do
				table.insert(boxes, zone)
			end
			local hides = 0
			for _, zone in DreadKit.clearances(layout) do
				if zone.kind == "Barrel" or zone.kind == "Cabinet" or zone.kind == "Locker" then
					hides += 1
				end
			end
			t.truthy(hides >= 50, string.format("%s: %d hiding spots kept clear", id, hides))
			local intrusions = 0
			for _, part in partsOf(built(id)) do
				t.falsy(part.CanCollide, part.Name .. " collides")
				t.falsy(part.CanQuery, part.Name .. " is queried")
				t.falsy(part.CanTouch, part.Name .. " is touched")
				t.falsy(part.CastShadow, part.Name .. " casts a shadow")
				local lo, hi = aabb(part)
				lo -= origin
				hi -= origin
				for _, zone in boxes do
					if
						math.min(hi.X, zone.x1) - math.max(lo.X, zone.x0) > 0.05
						and math.min(hi.Z, zone.z1) - math.max(lo.Z, zone.z0) > 0.05
						and math.min(hi.Y, zone.y1) - math.max(lo.Y, zone.y0) > 0.05
					then
						intrusions += 1
						t.fail(string.format("%s: %s sits in a %s clearance", id, part.Name, zone.kind))
					end
				end
			end
			t.eq(intrusions, 0, id .. " intrusions")
		end
	end,

	["the floors' plans, walk graphs, anchors and triggers are untouched"] = function(t: Expect)
		for _, id in FLOORS do
			local layout = layoutOf(id)
			local before = gameplayText(layout)
			local hash, rows = planHash(layout)
			t.eq(rows, RECORDED[id].rows, id .. " plan rows")
			t.eq(hash, RECORDED[id].hash, id .. " plan hash")
			built(id)
			DreadKit.plan(layout, { density = 1, routes = DreadKit.patrolLoops(layout) })
			t.eq(gameplayText(layout) == before, true, id .. " walk graph, anchors and triggers unchanged")
			local after = planHash(layout)
			t.eq(after, hash, id .. " plan hash after the kit")
			t.eq(table.concat(LayoutSchema.validate(layout), "; "), "", id .. " still validates")
		end
	end,

	["no word of the massacre anywhere: names, attributes, decals, the config's lines and captions"] = function(
		t: Expect
	)
		for _, id in { "Level0_Basement", "Level1_Hallways", "Lobby" } do
			local layout = layoutOf(id)
			local folder = Instance.new("Folder")
			DreadKit.build(folder, layout, DreadKit.plan(layout, optionsOf(id)))
			for _, text in wordsOf(folder) do
				local word = forbiddenIn(text)
				t.eq(word, nil, string.format("%s: %q", id, text))
			end
		end
		local lines: { string } = { DreadConfig.Notice.Heading, DreadConfig.DrawingCaption }
		for _, text in DreadConfig.Notice.Lines do
			table.insert(lines, text)
		end
		for _, list in DreadConfig.Writing do
			for _, entry in list do
				table.insert(lines, entry.text)
			end
		end
		for _, name in DreadConfig.presetNames() do
			local preset = SynthPresets.get(name)
			t.truthy(preset, name .. " is a preset")
			if preset and preset.caption then
				table.insert(lines, Strings.get(preset.caption))
			end
		end
		for _, text in lines do
			t.eq(forbiddenIn(text), nil, string.format("%q", text))
		end
	end,

	["the writing is DreadConfig's, spec 2.8's lore lines included, and every clock reads 3:31"] = function(t: Expect)
		local lore = {
			Level0_Basement = { "IT CAME OUT OF THE BINS", "HE HEARS YOU RUN", "CRAWL →" },
			Level1_Hallways = { "NOT DANNY", "IT KNOWS NAMES", "WHEN IT LOOKS AWAY — GO", "DON'T LOOK AT HIS FACE" },
		}
		for _, id in FLOORS do
			local written: { [string]: boolean } = {}
			local allowed: { [string]: boolean } = {}
			for _, entry in DreadConfig.Writing[id] do
				allowed[entry.text] = true
			end
			local clocks = 0
			for _, part in partsOf(built(id)) do
				local text = part:GetAttribute("DreadText")
				if type(text) == "string" then
					t.truthy(allowed[text], id .. ": written " .. text)
					written[text] = true
					local label = part:FindFirstChild("Text", true)
					t.truthy(
						label and label:IsA("TextLabel") and label.Text == text,
						id .. ": the decal reads " .. text
					)
				end
				if part:GetAttribute("DreadKind") == "Clock" and part:GetAttribute("ClockHour") ~= nil then
					clocks += 1
					t.eq(part:GetAttribute("ClockHour"), 3, part.Name .. " hour")
					t.eq(part:GetAttribute("ClockMinute"), 31, part.Name .. " minute")
					local hour = part:FindFirstChild("HourHand", true)
					local minute = part:FindFirstChild("MinuteHand", true)
					t.truthy(hour and minute, part.Name .. " has both hands")
					if hour and minute and hour:IsA("Frame") and minute:IsA("Frame") then
						t.near(hour.Rotation, (3 + 31 / 60) * 30, 1e-6, part.Name .. " hour hand at 3:31")
						t.near(minute.Rotation, 31 * 6, 1e-6, part.Name .. " minute hand at 3:31")
					end
				end
			end
			t.truthy(clocks >= 1, id .. " has a clock")
			for _, text in lore[id] do
				t.truthy(written[text], id .. " carries the lore line " .. text)
			end
		end
	end,

	["the same layout gives the same world"] = function(t: Expect)
		for _, id in FLOORS do
			local layout = layoutOf(id)
			local options = optionsOf(id)
			local cached = DreadKit.plan(layout, options)
			local fresh = DreadKit.plan(layout, {
				density = options.density,
				kinds = options.kinds,
				routes = DreadKit.patrolLoops(layout),
			})
			t.truthy(fresh ~= cached, id .. " planned afresh")
			t.eq(#fresh.items, #cached.items, id .. " items")
			local same = true
			for i, entry in cached.items do
				local other = fresh.items[i]
				if not other or other.kind ~= entry.kind or #other.pieces ~= #entry.pieces then
					same = false
					break
				end
				for k, piece in entry.pieces do
					local q = other.pieces[k]
					if
						q.name ~= piece.name
						or (q.cframe.Position - piece.cframe.Position).Magnitude > 1e-6
						or (q.size - piece.size).Magnitude > 1e-6
					then
						same = false
					end
				end
			end
			t.truthy(same, id .. ": every piece in the same place")
		end
	end,

	["every kind of the kit shows on both floors, built by DreadBuilder"] = function(t: Expect)
		local registered = false
		for _, entry in Props.modules() do
			if entry.name == "DreadBuilder" then
				registered = true
			end
		end
		t.truthy(registered, "DreadBuilder is a prop builder")
		for _, id in FLOORS do
			local plan = DreadKit.plan(layoutOf(id), optionsOf(id))
			for _, kind in KINDS do
				t.truthy((plan.counts[kind] or 0) > 0, id .. " has " .. kind)
			end
		end
		local hallways = DreadKit.plan(layoutOf("Level1_Hallways"), optionsOf("Level1_Hallways"))
		for _, kind in HALLWAY_KINDS do
			t.truthy((hallways.counts[kind] or 0) > 0, "Level1_Hallways has " .. kind)
		end
		t.eq(DreadKit.levelOptions("Level2_Auditorium"), nil, "the interim Auditorium is left for its rebuild")
		t.eq(DreadKit.levelOptions("Level3_Roof"), nil, "the roof is left for its rebuild")
	end,

	["the dying circuits already flicker; drips and sparks carry their tags and emitters"] = function(t: Expect)
		for _, id in FLOORS do
			local layout = layoutOf(id)
			local flickering: { [string]: boolean } = {}
			for _, room in layout.rooms do
				for _, light in (room.lights or {}) :: { LayoutSchema.Light } do
					local group = light.flickerGroup
					if group and string.sub(group, 1, 8) == "Circuit:" and not light.broken then
						flickering[group] = true
					end
				end
			end
			local dying, drips, sparks = 0, 0, 0
			for _, part in partsOf(built(id)) do
				if part:HasTag(Tags.DyingFixture) then
					dying += 1
					local group = part:GetAttribute("FlickerGroup")
					t.truthy(type(group) == "string" and flickering[group], part.Name .. " marks a flickering circuit")
					local style = part:GetAttribute("DyingStyle")
					t.truthy(style == "Pulse" or style == "Tube", part.Name .. " style")
				elseif part:HasTag(Tags.DreadDrip) then
					drips += 1
					t.truthy(part:FindFirstChild("Drip"), part.Name .. " drips")
				elseif part:HasTag(Tags.DreadSpark) then
					sparks += 1
					t.truthy(part:FindFirstChild("Sparks"), part.Name .. " sparks")
				end
			end
			t.truthy(dying >= 1 and dying <= DreadConfig.Light.DyingPerFloor, string.format("%s: %d dying", id, dying))
			t.truthy(drips >= 1, id .. " drips")
			t.truthy(sparks >= 1, id .. " sparks")
		end
	end,
}
