--!strict
-- Set dressing contracts, checked on the real layouts: every SmashedLocker and DripPipe anchor and every FloorDebris /
-- ScareStep trigger is dressed within its part budget; Drip parts carry the DripPipe tag at dripPoint(); debris lies
-- inside its trigger and never collides; nothing intrudes on a doorway, a grate front, a stair landing or a spawn
-- point; client dressing is non-colliding, unqueried and the world's own (the same on every client and run).
-- Signs and posters are lit, non-colliding prints on their walls above the chair rail, clear of every opening, with
-- every word from Strings; the plant rooms' pipework runs above the door heads and clear of every light fixture and drip pipe.
-- Classrooms face a chalkboard with rows of desks that leave aisles (every classroom smaller than a hall seats pupils),
-- furniture stays within its budgets, decay (fallen tiles under their holes,
-- puddles, plaster damage, paper) never collides, lies only in rooms a player walks into and shows in full in every
-- room whose ruin calls for it (each ruined drop ceiling's holes, each plastered room's patches, each room kind's
-- paper; at least DECAY_MIN of each in all), and no sign lands on a board or a hole.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local DecayBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.DecayBuilder)
local Finishes = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Finishes)
local FurnitureBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.FurnitureBuilder)
local SchoolShellBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.SchoolShellBuilder)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)
local SetDressingBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.SetDressingBuilder)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor

local W = Attributes.World
local BUDGET = SetDressingBuilder.Budget
-- The least decay the floors show in all (re-set for the tunnel floors' few school rooms, with a margin): holes in the
-- ruined drop ceilings, patches of plaster off the walls, loose sheets of paper, puddle parts in the rooms players walk.
local DECAY_MIN = table.freeze({ holes = 4, sites = 4, papers = 8, puddles = 300 })
-- A drop ceiling at least this ruined (Finishes.ruin) has lost tiles: one more for every tenth of ruin past it, and
-- the holes it shows (SchoolShellBuilder.ceilingFalls, a tile under each) are two once five tiles are gone, else one.
local DECAY_HOLE_RUIN = 0.3
-- A classroom this big (floor area, square studs) is a hall: long tables, not rows of desks.
local HALL_AREA = 1400
local STATIC_PREFIXES: { string } = {
	"SmashedLocker_",
	"DripPipe_",
	"FloorDebris_",
	"Signs_",
	"Pipes_",
	"Furniture_",
	"Decay_",
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

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

local function parts(root: Instance): { BasePart }
	local out: { BasePart } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(out, d)
		end
	end
	return out
end

local function overlaps(lo: Vector3, hi: Vector3, bLo: Vector3, bHi: Vector3): boolean
	return math.min(hi.X, bHi.X) - math.max(lo.X, bLo.X) > 0.02
		and math.min(hi.Y, bHi.Y) - math.max(lo.Y, bLo.Y) > 0.02
		and math.min(hi.Z, bHi.Z) - math.max(lo.Z, bLo.Z) > 0.02
end

local function hasPrefix(name: string, prefixes: { string }): boolean
	for _, prefix in prefixes do
		if string.sub(name, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

local function layoutOf(id: string): Layout
	local layout = Builder.getLayout(id)
	assert(layout, "layout " .. id)
	return layout
end

local function anchorsOf(layout: Layout, kind: string): { Anchor }
	local out: { Anchor } = {}
	for _, anchor in layout.anchors do
		if anchor.kind == kind then
			table.insert(out, anchor)
		end
	end
	return out
end

-- Every school level and the lobby built once (statics included) and shared by the tests below.
local built: { [string]: Model }? = nil

local function world(): { [string]: Model }
	local cached = built
	if cached then
		return cached
	end
	local host = Instance.new("Model")
	host.Name = "DressingSpecWorld"
	local result = Builder.BuildAuthoritative({ parent = host :: Instance, yieldEvery = 0 })
	local levels: { [string]: Model } = table.clone(result.levels)
	levels.Lobby = result.lobby
	built = levels
	return levels
end

local function props(id: string): Instance
	local level = world()[id]
	assert(level, "built level " .. id)
	local folder = level:FindFirstChild("Props")
	assert(folder, id .. " has a Props folder")
	return folder
end

local function model(folder: Instance, name: string): Instance
	local found = folder:FindFirstChild(name)
	assert(found, string.format("%s has no %s", folder:GetFullName(), name))
	return found
end

local function isDetail(part: BasePart): boolean
	return not part.CanCollide and not part.CanQuery and not part.CanTouch and part.Anchored
end

-- The holes a ruined drop ceiling shows (see DECAY_HOLE_RUIN).
local function decayHolesShown(ruin: number): number
	if ruin < DECAY_HOLE_RUIN then
		return 0
	end
	local missing = math.floor(1 + (ruin - DECAY_HOLE_RUIN) / 0.7 * 7)
	return if missing >= 5 then 2 else 1
end

local function isPassthrough(part: BasePart): boolean
	return part.CanCollide
		and part.CollisionGroup == CollisionGroups.MonsterPassthrough
		and part:HasTag(Tags.MonsterPassthrough)
		and part:FindFirstChildOfClass("PathfindingModifier") ~= nil
end

-- Level-local boxes nothing may intrude on: each doorway (the opening and a stud either side), the floor in front of
-- each grate, airlocks and stair landings, and a 2-stud column over each PlayerSpawn.
local function keepOut(layout: Layout): { { lo: Vector3, hi: Vector3, what: string } }
	local out: { { lo: Vector3, hi: Vector3, what: string } } = {}
	local origin = WorldConfig.levelOrigin(layout.id)
	local rooms = LayoutSchema.indexRooms(layout)
	local function add(what: string, lo: Vector3, hi: Vector3)
		table.insert(out, { lo = origin + lo:Min(hi), hi = origin + lo:Max(hi), what = what })
	end
	for _, door in layout.doors do
		local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
		local edge = if a and b then LayoutSchema.sharedEdge(a.rect, b.rect) else nil
		if edge then
			local half = LayoutSchema.doorWidth(door) / 2
			local h = LayoutSchema.doorHeight(door)
			local reach = WorldConfig.WallThickness / 2 + 1
			if edge.axis == "X" then
				add(
					"door " .. door.id,
					Vector3.new(edge.coord - reach, 0, door.at - half),
					Vector3.new(edge.coord + reach, h, door.at + half)
				)
			else
				add(
					"door " .. door.id,
					Vector3.new(door.at - half, 0, edge.coord - reach),
					Vector3.new(door.at + half, h, edge.coord + reach)
				)
			end
		end
	end
	local vents = layout.vents
	if vents then
		local nodes: { [string]: LayoutSchema.VentNodeSpec } = {}
		for _, node in vents.nodes do
			nodes[node.id] = node
		end
		local halfBore = WorldConfig.VentBore / 2
		for _, grate in vents.grates do
			local node, room = nodes[grate.node], rooms[grate.room]
			local side = if node and room then LayoutSchema.sideOfPoint(room.rect, node.x, node.z) else nil
			if node and side then
				local y = LayoutSchema.ventNodeY(node)
				local y0, y1 = math.min(0, y - halfBore), y + halfBore
				local face = WorldConfig.WallThickness / 2
				local front = face + 3
				if side == "N" then
					add(
						"grate " .. grate.id,
						Vector3.new(node.x - halfBore, y0, node.z + face),
						Vector3.new(node.x + halfBore, y1, node.z + front)
					)
				elseif side == "S" then
					add(
						"grate " .. grate.id,
						Vector3.new(node.x - halfBore, y0, node.z - front),
						Vector3.new(node.x + halfBore, y1, node.z - face)
					)
				elseif side == "W" then
					add(
						"grate " .. grate.id,
						Vector3.new(node.x + face, y0, node.z - halfBore),
						Vector3.new(node.x + front, y1, node.z + halfBore)
					)
				else
					add(
						"grate " .. grate.id,
						Vector3.new(node.x - front, y0, node.z - halfBore),
						Vector3.new(node.x - face, y1, node.z + halfBore)
					)
				end
			end
		end
	end
	for _, room in layout.rooms do
		if room.kind == "Airlock" or room.kind == "Stairwell" then
			local r = room.rect
			add(
				"landing " .. room.id,
				Vector3.new(r.x, -1, r.z),
				Vector3.new(r.x + r.w, LayoutSchema.roomHeight(layout, room), r.z + r.d)
			)
		end
	end
	for _, anchor in anchorsOf(layout, "PlayerSpawn") do
		local p = anchor.pos
		add("spawn " .. anchor.id, Vector3.new(p.X - 1, -1, p.Z - 1), Vector3.new(p.X + 1, p.Y + 3, p.Z + 1))
	end
	return out
end

local function assertClear(t: Expect, layout: Layout, list: { BasePart })
	local zones = keepOut(layout)
	for _, part in list do
		local lo, hi = aabb(part)
		for _, zone in zones do
			if overlaps(lo, hi, zone.lo, zone.hi) then
				t.fail(string.format("%s intrudes on %s", part:GetFullName(), zone.what))
			end
		end
	end
end

local function dressingParts(id: string): { BasePart }
	local out: { BasePart } = {}
	for _, child in props(id):GetChildren() do
		if hasPrefix(child.Name, STATIC_PREFIXES) then
			for _, part in parts(child) do
				table.insert(out, part)
			end
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Cosmetic builds (two, as two clients or two runs would make them)
--------------------------------------------------------------------------------

local cosmetic: { [number]: Folder } = {}

local function dressing(slot: number): Instance
	local folder = cosmetic[slot]
	if not folder then
		local fresh = Instance.new("Folder")
		fresh.Name = "Cosmetic" .. slot
		Builder.BuildCosmetic(fresh)
		cosmetic[slot] = fresh
		folder = fresh
	end
	local found = folder:FindFirstChild("Dressing")
	assert(found, "BuildCosmetic made a Dressing folder")
	return found
end

local COSMETIC_KINDS: { [string]: { prefix: string, budget: number } } = {
	Corpse = { prefix = "Corpse_", budget = BUDGET.Corpse },
	Clutter = { prefix = "Clutter_", budget = BUDGET.Clutter },
	DripPipe = { prefix = "Drips_", budget = BUDGET.DripCosmetic },
}

return {
	["smashed lockers: a bank of 3-5 lockers backed onto the wall at every anchor"] = function(t: Expect)
		for _, id in { "Level1_Hallways" } do
			local layout = layoutOf(id)
			local origin = WorldConfig.levelOrigin(id)
			local rooms = LayoutSchema.indexRooms(layout)
			local folder = props(id)
			local anchors = anchorsOf(layout, "SmashedLocker")
			if id == "Level1_Hallways" then
				t.truthy(#anchors >= 8, string.format("%s smashed locker anchors (%d)", id, #anchors))
			else
				t.eq(#anchors, 4, id .. " smashed locker anchors")
			end
			for _, anchor in anchors do
				local bank = model(folder, "SmashedLocker_" .. anchor.id)
				local list = parts(bank)
				t.truthy(#list <= BUDGET.SmashedLocker, string.format("%s has %d parts", anchor.id, #list))
				local dividers = 0
				local back: BasePart? = nil
				for _, part in list do
					t.truthy(part.Anchored, part.Name .. " anchored")
					t.truthy(isPassthrough(part) or isDetail(part), part:GetFullName() .. " is passthrough or detail")
					if string.sub(part.Name, 1, 7) == "Divider" then
						dividers += 1
					elseif part.Name == "Back" then
						back = part
					end
				end
				t.truthy(
					dividers - 1 >= 3 and dividers - 1 <= 5,
					string.format("%s: %d lockers", anchor.id, dividers - 1)
				)
				-- The bank backs onto the wall behind the anchor, and solid wreckage stays out of the corridor's lane
				local room = rooms[anchor.room]
				local look = CFrame.Angles(0, math.rad(anchor.yaw or 0), 0).LookVector
				local alongZ = math.abs(look.Z) > math.abs(look.X)
				local wall: number
				if alongZ then
					wall = origin.Z + (if look.Z > 0 then room.rect.z + 0.5 else room.rect.z + room.rect.d - 0.5)
				else
					wall = origin.X + (if look.X > 0 then room.rect.x + 0.5 else room.rect.x + room.rect.w - 0.5)
				end
				assert(back, anchor.id .. " back panel")
				local bLo, bHi = aabb(back)
				local backDistance = if alongZ
					then math.min(math.abs(bLo.Z - wall), math.abs(bHi.Z - wall))
					else math.min(math.abs(bLo.X - wall), math.abs(bHi.X - wall))
				t.truthy(backDistance < 0.15, anchor.id .. " backs onto its wall")
				for _, part in list do
					if part.CanCollide then
						local lo, hi = aabb(part)
						local reach = if alongZ
							then math.max(math.abs(lo.Z - wall), math.abs(hi.Z - wall))
							else math.max(math.abs(lo.X - wall), math.abs(hi.X - wall))
						t.truthy(
							reach <= 3.35,
							string.format("%s reaches %.2f into the corridor", part:GetFullName(), reach)
						)
					end
				end
			end
		end
	end,

	["drip pipes: a tagged Drip at dripPoint under every pipe run"] = function(t: Expect)
		for _, id: Enums.LevelId in WorldConfig.LevelOrder do
			local layout = layoutOf(id)
			local rooms = LayoutSchema.indexRooms(layout)
			local origin = WorldConfig.levelOrigin(id)
			local folder = props(id)
			for _, anchor in anchorsOf(layout, "DripPipe") do
				local pipe = model(folder, "DripPipe_" .. anchor.id)
				local list = parts(pipe)
				t.truthy(#list <= BUDGET.DripPipe, string.format("%s has %d parts", anchor.id, #list))
				local drip = pipe:FindFirstChild("Drip")
				assert(drip and drip:IsA("BasePart"), anchor.id .. " has a Drip part")
				t.truthy(drip:HasTag(Tags.DripPipe), "Drip is tagged DripPipe")
				t.eq(drip:GetAttribute(W.LevelId), id, "Drip LevelId")
				t.truthy(isDetail(drip), "Drip never collides")
				local expected = SetDressingBuilder.dripPoint(id, anchor)
				t.truthy(drip.CFrame.Position:FuzzyEq(expected, 1e-3), anchor.id .. " Drip sits at dripPoint")
				t.truthy(expected:FuzzyEq(SetDressingBuilder.dripPoint(id, anchor), 1e-6), "dripPoint is pure")
				-- Under the ceiling, over the anchor
				local ceiling = origin.Y + SchoolShellBuilder.ceilingBottom(layout, rooms[anchor.room])
				t.near(expected.X, origin.X + anchor.pos.X, 1e-3)
				t.near(expected.Z, origin.Z + anchor.pos.Z, 1e-3)
				t.truthy(
					expected.Y < ceiling and expected.Y > ceiling - 2.5,
					anchor.id .. " leak hangs under the ceiling"
				)
				local pipeA = pipe:FindFirstChild("PipeA")
				assert(pipeA and pipeA:IsA("BasePart"), anchor.id .. " pipe")
				local _, hi = aabb(pipeA)
				t.truthy(hi.Y <= ceiling + 1e-3, anchor.id .. " pipe hangs below the ceiling")
				for _, part in list do
					t.truthy(part.Anchored, part.Name .. " anchored")
					if string.find(part.Name, "Puddle", 1, true) or part.Name == "WetStain" then
						t.truthy(isDetail(part), part.Name .. " is a non-colliding film")
						local lo = aabb(part)
						t.truthy(
							lo.Y >= origin.Y - 0.01 and lo.Y < origin.Y + 3.4,
							part.Name .. " lies on the surface below"
						)
					end
				end
			end
		end
		local tagged = 0
		for _, id: Enums.LevelId in WorldConfig.LevelOrder do
			for _, d in world()[id]:GetDescendants() do
				if d:HasTag(Tags.DripPipe) then
					tagged += 1
				end
			end
		end
		local anchors = 0
		for _, id: Enums.LevelId in WorldConfig.LevelOrder do
			anchors += #PropKit.anchorsOf(layoutOf(id), "DripPipe")
		end
		t.eq(tagged, anchors, "every DripPipe anchor has one tagged Drip")
	end,

	["floor debris: inside every FloorDebris and ScareStep trigger, flat, never colliding"] = function(t: Expect)
		local triggers = 0
		for _, id: Enums.LevelId in WorldConfig.LevelOrder do
			local layout = layoutOf(id)
			local origin = WorldConfig.levelOrigin(id)
			local folder = props(id)
			for _, trigger in layout.triggers do
				if trigger.kind ~= "FloorDebris" and trigger.kind ~= "ScareStep" then
					continue
				end
				triggers += 1
				local debris = model(folder, "FloorDebris_" .. trigger.id)
				t.eq(debris:GetAttribute(W.TriggerId), trigger.id)
				local list = parts(debris)
				t.truthy(
					#list >= 8 and #list <= BUDGET.FloorDebris,
					string.format("%s has %d parts", trigger.id, #list)
				)
				local r = trigger.rect
				local floor = origin.Y + (trigger.y or 0)
				local glassCount = 0
				for _, part in list do
					t.truthy(isDetail(part), part:GetFullName() .. " never collides")
					local lo, hi = aabb(part)
					t.truthy(
						lo.X >= origin.X + r.x - 0.05 and hi.X <= origin.X + r.x + r.w + 0.05,
						part.Name .. " inside the trigger (X)"
					)
					t.truthy(
						lo.Z >= origin.Z + r.z - 0.05 and hi.Z <= origin.Z + r.z + r.d + 0.05,
						part.Name .. " inside the trigger (Z)"
					)
					t.truthy(lo.Y >= floor - 0.08 and hi.Y <= floor + 0.6, part.Name .. " lies on the floor")
					if part:IsA("WedgePart") and part.Material == Enum.Material.Glass then
						glassCount += 1
					end
				end
				if trigger.kind == "ScareStep" then
					t.truthy(glassCount >= 6, "the scare step is strewn with glass")
				end
			end
		end
		t.truthy(triggers >= 18, "FloorDebris + ScareStep triggers across the school")
	end,

	["static dressing stays out of doorways, grate fronts, landings and spawns"] = function(t: Expect)
		for _, id: Enums.LayoutId in Enums.LayoutId do
			local layout = layoutOf(id)
			assertClear(t, layout, dressingParts(id))
		end
	end,

	["cosmetic dressing: every anchor dressed within budget, never colliding or queried"] = function(t: Expect)
		local folder = dressing(1)
		for _, layout in Builder.layouts() do
			local dressed: { BasePart } = {}
			for _, anchor in layout.anchors do
				local spec = COSMETIC_KINDS[anchor.kind]
				if not spec then
					continue
				end
				local anchorModel = folder:FindFirstChild(spec.prefix .. anchor.id)
				assert(anchorModel, string.format("%s %s is dressed", anchor.kind, anchor.id))
				local list = parts(anchorModel)
				t.truthy(#list >= 1 and #list <= spec.budget, string.format("%s has %d parts", anchor.id, #list))
				for _, part in list do
					t.falsy(part.CanCollide, part:GetFullName() .. " collides")
					t.falsy(part.CanQuery, part:GetFullName() .. " is queried")
					t.falsy(part.CanTouch, part:GetFullName() .. " touches")
					t.eq(part.CollisionGroup, CollisionGroups.NoCollide)
					t.truthy(part.Anchored, part.Name .. " anchored")
					table.insert(dressed, part)
				end
				if anchor.kind == "Corpse" then
					t.truthy(anchorModel:HasTag(Tags.Corpse), anchor.id .. " tagged Corpse")
					t.truthy(#list >= 18, anchor.id .. " is a whole body")
				elseif anchor.kind == "DripPipe" then
					local host = anchorModel:FindFirstChild("Emitter")
					assert(host and host:IsA("BasePart"), anchor.id .. " emitter host")
					t.eq(host.Transparency, 1, "emitter host is invisible")
					t.truthy(
						host.CFrame.Position:FuzzyEq(SetDressingBuilder.dripPoint(layout.id, anchor), 1e-3),
						"drops fall from dripPoint"
					)
					local emitter = host:FindFirstChildOfClass("ParticleEmitter")
					assert(emitter, anchor.id .. " drops")
					t.truthy(emitter.Acceleration.Y < -50, "drops fall under gravity")
					t.truthy(emitter.Rate <= 2, "sparse drops")
					-- Never pointed at an uploaded asset (the harness cannot read an unset Texture, Roblox reads the default)
					local readable, texture = pcall(function(): string
						return emitter.Texture
					end)
					t.truthy(
						not readable or string.find(texture, "rbxassetid", 1, true) == nil,
						"default particle texture"
					)
					t.falsy(host:HasTag(Tags.DripPipe), "the client emitter is not a second drip voice")
				end
			end
			assertClear(t, layout, dressed)
		end
	end,

	["cosmetic dressing: the world's, the same on every client and run, each anchor posed its own way"] = function(
		t: Expect
	)
		local a, b = dressing(1), dressing(2)
		local listA, listB = parts(a), parts(b)
		t.eq(#listA, #listB, "every build makes the same parts")
		for i, part in listA do
			local other = listB[i]
			t.eq(part.Name, other.Name)
			t.truthy(part.CFrame.Position:FuzzyEq(other.CFrame.Position, 1e-5), part.Name .. " same position")
			t.truthy(part.CFrame.LookVector:FuzzyEq(other.CFrame.LookVector, 1e-5), part.Name .. " same rotation")
			t.truthy(part.Size:FuzzyEq(other.Size, 1e-5), part.Name .. " same size")
			t.eq(part.Color, other.Color, part.Name .. " same colour")
		end
		-- every anchor draws from its own stream: a floor's corpses do not all lie alike on their anchors
		for _, layout in Builder.layouts() do
			local poses: { [string]: boolean } = {}
			local corpses, distinct = 0, 0
			for _, anchor in layout.anchors do
				if anchor.kind ~= "Corpse" then
					continue
				end
				local body = a:FindFirstChild("Corpse_" .. anchor.id)
				assert(body, anchor.id .. " is dressed")
				local frame = Builder.anchorCFrame(layout.id, anchor)
				local rows: { string } = {}
				for _, part in parts(body) do
					local p = frame:PointToObjectSpace(part.CFrame.Position)
					table.insert(rows, string.format("%s %.2f %.2f %.2f", part.Name, p.X, p.Y, p.Z))
				end
				table.sort(rows)
				local pose = table.concat(rows, ";")
				corpses += 1
				if not poses[pose] then
					poses[pose] = true
					distinct += 1
				end
			end
			t.truthy(
				distinct >= math.min(corpses, 2),
				string.format("%s: %d corpses in %d poses", layout.id, corpses, distinct)
			)
		end
	end,

	["signage: lit, non-colliding prints above the chair rail, clear of every opening, words from Strings"] = function(
		t: Expect
	)
		local allowed: { [string]: boolean } = {}
		for _, key in
			{
				"NoRunning",
				"Exit",
				"Stairs",
				"Office",
				"Boiler",
				"Missing",
				"Assembly",
				"Quarantine",
				"Help",
				"Hide",
				"Caution",
				"WetFloor",
			}
		do
			allowed[Strings.get("Prop.Sign." .. key)] = true
		end
		local plates, platable = 0, 0
		for _, id: Enums.LayoutId in Enums.LayoutId do
			local layout = layoutOf(id)
			local origin = WorldConfig.levelOrigin(id)
			local signs = props(id):FindFirstChild("Signs_" .. id)
			if not signs then
				t.truthy(id == "Level3_Roof", id .. " has signs")
				continue
			end
			local count = 0
			for _, part in parts(signs) do
				count += 1
				t.falsy(part.CanCollide, part.Name .. " never collides")
				t.falsy(part.CanQuery, part.Name .. " is never queried")
				t.falsy(part.CastShadow, part.Name .. " casts no shadow")
				local lo, hi = aabb(part)
				local standing = string.sub(part.Name, 1, 9) == "WetFloor_"
				if standing then
					t.truthy(lo.Y >= origin.Y - 0.01 and hi.Y < origin.Y + 2.4, part.Name .. " stands on the floor")
				else
					t.truthy(lo.Y >= origin.Y + Finishes.RailTop, part.Name .. " hangs above the chair rail")
					t.truthy(math.min(hi.X - lo.X, hi.Z - lo.Z) <= 0.35, part.Name .. " is flat on its wall")
				end
				for _, gui in part:GetChildren() do
					if gui:IsA("SurfaceGui") then
						t.eq(gui.LightInfluence, 1, part.Name .. " is lit by the scene")
						t.truthy(gui.PixelsPerStud <= 20, part.Name .. " low resolution")
						for _, label in gui:GetDescendants() do
							if label:IsA("TextLabel") then
								local number = string.match(part.Name, "^Plate_.-_(%d+)$")
								if number then
									plates += 1
									local n = tonumber(number) :: number
									t.eq(label.Text, Strings.get("Prop.Sign.Room", n), part.Name .. " names its room")
								else
									t.truthy(
										allowed[label.Text],
										part.Name .. " text comes from Strings: " .. label.Text
									)
								end
							end
						end
					end
				end
				-- clear of every opening the shell cuts, a stud either side of the wall
				for _, item in SchoolShellBuilder.openings(layout) do
					local o = item.opening
					local a0 = item.coord - 1.2
					local a1 = item.coord + 1.2
					local boxLo = origin
						+ (if item.axis == "X" then Vector3.new(a0, o.y0, o.u0) else Vector3.new(o.u0, o.y0, a0))
					local boxHi = origin
						+ (if item.axis == "X" then Vector3.new(a1, o.y1, o.u1) else Vector3.new(o.u1, o.y1, a1))
					t.falsy(overlaps(lo, hi, boxLo, boxHi), part.Name .. " covers a " .. item.kind .. " opening")
				end
			end
			-- (a tunnel floor's own signs are its landmarks: junction plates, region stencils, TunnelDressingBuilder)
			if id ~= "Lobby" and not layout.tunnels then
				t.truthy(count >= 10, string.format("%s has %d signs", id, count))
			end
			-- STAIRS by every fire door, on the corridor side
			for _, door in layout.doors do
				if door.kind == "Airlock" then
					t.truthy(signs:FindFirstChild("Stairs_" .. door.id) ~= nil, door.id .. " has a STAIRS sign")
				end
			end
			-- the numbered classrooms and labs that open onto a corridor, each owed a plate beside that door (a tunnel
			-- floor's keep-rooms are named by its stencils instead)
			local rooms = LayoutSchema.indexRooms(layout)
			local owed: { [string]: boolean } = {}
			for _, door in layout.doors do
				if door.kind ~= "Door" and door.kind ~= "Doorway" and door.kind ~= "Ajar" then
					continue
				end
				for index = 1, 2 do
					local room, other = rooms[door.rooms[index]], rooms[door.rooms[3 - index]]
					if
						room
						and other
						and other.kind == "Corridor"
						and room.kind == "Classroom"
						and string.match(room.id, "_(%d+)$")
					then
						owed[room.id] = true
					end
				end
			end
			for _ in owed do
				platable += 1
			end
		end
		t.truthy(platable >= 1, "numbered rooms open onto the corridors (Classroom 108)")
		t.truthy(
			plates >= math.ceil(0.75 * platable),
			string.format("%d room plates for %d numbered rooms on corridors", plates, platable)
		)
	end,

	["service pipes: plant rooms only, above the door heads, clear of every light fixture and drip pipe"] = function(
		t: Expect
	)
		for _, id in { "Level0_Basement" } do
			local origin = WorldConfig.levelOrigin(id)
			local pipes = props(id):FindFirstChild("Pipes_" .. id)
			assert(pipes, id .. " has pipework")
			local list = parts(pipes)
			-- a tunnel floor's plant rooms are few: its tunnels carry their own pipes (TunnelDressingBuilder)
			local least = if layoutOf(id).tunnels then 8 else 30
			t.truthy(#list >= least, string.format("%s has %d pipe parts", id, #list))
			local fixtures: { { lo: Vector3, hi: Vector3, name: string } } = {}
			for _, part in parts(model(world()[id], "Lights")) do
				local lo, hi = aabb(part)
				table.insert(fixtures, { lo = lo, hi = hi, name = part.Name })
			end
			-- the drip pipes hung under the same ceilings
			for _, item in props(id):GetChildren() do
				if string.sub(item.Name, 1, 9) == "DripPipe_" then
					for _, part in parts(item) do
						local lo, hi = aabb(part)
						table.insert(fixtures, { lo = lo, hi = hi, name = item.Name .. "." .. part.Name })
					end
				end
			end
			for _, part in list do
				t.falsy(part.CanCollide, part.Name .. " never collides")
				t.falsy(part.CanQuery, part.Name .. " is never queried")
				local lo, hi = aabb(part)
				t.truthy(lo.Y >= origin.Y + 10.5, part.Name .. " runs above the door heads")
				for _, fixture in fixtures do
					t.falsy(overlaps(lo, hi, fixture.lo, fixture.hi), part.Name .. " runs through " .. fixture.name)
				end
			end
		end
		t.falsy(
			props("Level1_Hallways"):FindFirstChild("Pipes_Level1_Hallways"),
			"the classroom floors keep theirs hidden"
		)
	end,

	["static dressing is the same on every build"] = function(t: Expect)
		local host = Instance.new("Model")
		local only: { Enums.LayoutId } = { "Level1_Hallways" }
		local again = Builder.BuildAuthoritative({ parent = host :: Instance, layouts = only, yieldEvery = 0 })
		local level = again.levels.Level1_Hallways
		assert(level, "rebuilt Level1")
		local fresh = level:FindFirstChild("Props")
		assert(fresh, "rebuilt Props")
		for _, child in props("Level1_Hallways"):GetChildren() do
			if not hasPrefix(child.Name, STATIC_PREFIXES) then
				continue
			end
			local twin = fresh:FindFirstChild(child.Name)
			assert(twin, child.Name .. " rebuilt")
			local listA, listB = parts(child), parts(twin)
			t.eq(#listA, #listB, child.Name .. " part count")
			for i, part in listA do
				t.truthy(
					part.CFrame.Position:FuzzyEq(listB[i].CFrame.Position, 1e-5),
					part:GetFullName() .. " position"
				)
			end
		end
		host:Destroy()
	end,
	["furniture: classrooms face a chalkboard; desks, tables and offices within budget; tops solid, the rest detail"] = function(
		t: Expect
	)
		local budget = FurnitureBuilder.Budget
		local boards = 0
		-- the rooms that face a board and the classrooms that seat pupils in rows: every one smaller than a hall
		local boarded = 0
		local seated: { [string]: boolean } = {}
		local desksIn: { [string]: number } = {}
		for _, id: Enums.LayoutId in Enums.LayoutId do
			local layout = layoutOf(id)
			for _, room in layout.rooms do
				if room.kind == "Classroom" then
					boarded += 1
				end
				if room.kind ~= "Classroom" or room.rect.w * room.rect.d >= HALL_AREA then
					continue
				end
				seated[room.id] = true
			end
		end
		for _, id: Enums.LayoutId in Enums.LayoutId do
			local layout = layoutOf(id)
			local furniture = props(id):FindFirstChild("Furniture_" .. id)
			if not furniture then
				continue
			end
			local perRoom: { [string]: number } = {}
			for _, part in parts(furniture) do
				local solid = string.find(part.Name, "_Top$") ~= nil
					or string.find(part.Name, "_Seat$") ~= nil
					or string.sub(part.Name, 1, 8) == "Cabinet_"
				if solid then
					t.truthy(isPassthrough(part), part.Name .. " is solid for players, open to the Creature")
				else
					t.truthy(isDetail(part), part.Name .. " never collides")
				end
				local p = part.CFrame.Position - WorldConfig.levelOrigin(id)
				for _, room in layout.rooms do
					if LayoutSchema.rectContains(room.rect, p.X, p.Z) then
						perRoom[room.id] = (perRoom[room.id] or 0) + 1
						break
					end
				end
				if string.find(part.Name, "_Slate$") then
					boards += 1
					local chalk = part:FindFirstChild("Chalk")
					assert(chalk and chalk:IsA("SurfaceGui"), part.Name .. " is chalked")
					t.eq(chalk.Face, Enum.NormalId.Front, part.Name .. " chalk faces the room")
					for _, item in chalk:GetDescendants() do
						if item:IsA("TextLabel") then
							t.truthy(
								item.Text == Strings.get("Prop.Sign.Hide") or item.Text == Strings.get("Prop.Sign.Help"),
								part.Name .. " chalk words from Strings"
							)
						end
					end
				else
					local deskRoom = string.match(part.Name, "^Desk_(.+)_%d+_%d+_Top$")
					if deskRoom then
						desksIn[deskRoom] = (desksIn[deskRoom] or 0) + 1
					end
				end
			end
			for _, room in layout.rooms do
				local used = perRoom[room.id] or 0
				local cap = if room.kind == "Classroom"
					then math.max(budget.Classroom, budget.Hall)
					elseif room.kind == "Office" then budget.Office
					elseif room.kind == "Corridor" then budget.Corridor
					else 0
				t.truthy(used <= cap, string.format("%s has %d furniture parts (cap %d)", room.id, used, cap))
			end
		end
		t.truthy(
			boarded > 0 and boards >= math.ceil(0.75 * boarded),
			string.format("classrooms and labs have chalkboards (%d of %d rooms)", boards, boarded)
		)
		local classrooms = 0
		for roomId in seated do
			classrooms += 1
			t.truthy(
				(desksIn[roomId] or 0) >= 4,
				string.format("pupils' desks stand in %s (%d)", roomId, desksIn[roomId] or 0)
			)
		end
		t.truthy(classrooms > 0, "classrooms seat pupils")
	end,

	["furniture: desk columns keep aisles a player fits through, clear of the side walls"] = function(t: Expect)
		local layout = layoutOf("Level1_Hallways")
		local plan = FurnitureBuilder.plan(layout)
		local info = SetDressingBuilder.Kit.info(layout)
		for _, piece in plan.pieces do
			if piece.role ~= "Solid" or string.sub(piece.name, 1, 8) == "Cabinet_" then
				continue -- cabinets stand against a wall on purpose
			end
			local box = SetDressingBuilder.Kit.localBox(info, piece)
			for _, room in layout.rooms do
				local inner = info.inner[room.id]
				if
					inner
					and box.x0 >= inner.x - 1
					and box.x1 <= inner.x + inner.w + 1
					and box.z0 >= inner.z - 1
					and box.z1 <= inner.z + inner.d + 1
				then
					t.truthy(
						box.x0 >= inner.x + 0.4 - 1e-3
							and box.x1 <= inner.x + inner.w - 0.4 + 1e-3
							and box.z0 >= inner.z + 0.4 - 1e-3
							and box.z1 <= inner.z + inner.d - 0.4 + 1e-3,
						piece.name .. " keeps off the walls"
					)
				end
			end
		end
		-- Upright pupils' desks of one row stand at least a player's width apart: in the floors' classrooms (which desks
		-- stand upright is the world stream's draw) and in a full 40 x 30 classroom planned the same way, so the rule is
		-- held on a whole room of rows whatever the floors' rooms drew.
		local classroom: Layout = {
			id = "Level1_Hallways",
			height = 14,
			acoustic = "Corridor",
			ambience = "DroneHallways",
			entry = "Spec_Hall",
			exit = "Spec_Class",
			rooms = {
				{
					id = "Spec_Class",
					kind = "Classroom",
					rect = LayoutSchema.rect(100, 40, 40, 30),
					height = 12,
					acoustic = "Room",
				},
				{ id = "Spec_Hall", kind = "Corridor", rect = LayoutSchema.rect(100, 70, 40, 12) },
			},
			doors = { { id = "Spec_ClassDoor", kind = "Door", rooms = { "Spec_Hall", "Spec_Class" }, at = 110 } },
			anchors = {},
			triggers = {},
		}
		local rows: { [string]: { number } } = {}
		for _, pieces in { plan.pieces, FurnitureBuilder.plan(classroom).pieces } do
			for _, piece in pieces do
				local room, row = string.match(piece.name, "^Desk_(.+)_(%d+)_%d+_Top$")
				if room and row and math.abs(piece.cframe.UpVector.Y) > 0.95 then
					local key = room .. ":" .. row
					local list = rows[key] or {}
					rows[key] = list
					local p = piece.cframe.Position
					table.insert(list, p.X)
					table.insert(list, p.Z)
				end
			end
		end
		local checked = 0
		for key, coords in rows do
			for i = 1, #coords, 2 do
				for j = i + 2, #coords, 2 do
					local dx, dz = coords[i] - coords[j], coords[i + 1] - coords[j + 1]
					t.truthy(math.sqrt(dx * dx + dz * dz) >= 2.4 + 2, key .. " desks leave an aisle")
					checked += 1
				end
			end
		end
		t.truthy(checked >= 6, string.format("rows checked (%d pairs of upright desks)", checked))
	end,

	["decay: fallen tiles under their holes, glossy puddles, damage on the walls, nothing collides or is queried"] = function(
		t: Expect
	)
		local falls, tiles, puddles, damage, papers = 0, 0, 0, 0, 0
		for _, id: Enums.LayoutId in Enums.LayoutId do
			local layout = layoutOf(id)
			local rooms = LayoutSchema.indexRooms(layout)
			local decay = props(id):FindFirstChild("Decay_" .. id)
			local holes = SchoolShellBuilder.ceilingFalls(layout)
			falls += #holes
			local holed: { [string]: number } = {}
			for _, hole in holes do
				holed[hole.room] = (holed[hole.room] or 0) + 1
			end
			local sitesIn: { [string]: number } = {}
			local papersIn: { [string]: number } = {}
			for _, part in (if decay then parts(decay) else {}) :: { BasePart } do
				t.truthy(isDetail(part), part.Name .. " never collides or is queried")
				t.falsy(part.CastShadow, part.Name .. " casts no shadow")
				local roomId, index = string.match(part.Name, "^Fall_(.+)_(%d+)_Tile")
				if roomId and index then
					local hole = holes[tonumber(index) or 0]
					assert(hole, part.Name .. " has its hole")
					t.eq(hole.room, roomId, part.Name .. " room")
					local p = part.CFrame.Position
					local offset = Vector3.new(p.X - hole.centre.X, 0, p.Z - hole.centre.Z).Magnitude
					t.truthy(offset <= 2.5, part.Name .. " lies under its hole")
					t.truthy(p.Y < hole.centre.Y - 6, part.Name .. " lies on the floor")
					tiles += 1
				elseif string.sub(part.Name, 1, 7) == "Puddle_" then
					puddles += 1
					t.eq(part.Material, Enum.Material.Glass, part.Name .. " is water")
					t.truthy(part.Reflectance >= 0.2, part.Name .. " is glossy")
					t.truthy(part.Size.X <= 0.05, part.Name .. " lies flat")
					-- on the floor of a room a player walks into (never in the solid ground between the tunnels)
					local wet = string.match(part.Name, "^Puddle_(.+)_%d+_Spill$")
						or string.match(part.Name, "^Puddle_(.+)_%d+$")
					local room = if wet then rooms[wet] else nil
					t.truthy(room ~= nil and room.kind ~= "Solid", part.Name .. " lies in a room a player walks into")
				elseif string.sub(part.Name, 1, 7) == "Damage_" and part:FindFirstChild("Damage") then
					damage += 1
					t.eq(part.Transparency, 1, part.Name .. " carries only its paint")
					local y = part.CFrame.Position.Y - WorldConfig.levelOrigin(id).Y
					t.truthy(y > Finishes.RailTop, part.Name .. " above the rail")
					local site = string.match(part.Name, "^Damage_(.+)_%d+$")
					if site then
						sitesIn[site] = (sitesIn[site] or 0) + 1
					end
				elseif string.sub(part.Name, 1, 6) == "Paper_" then
					papers += 1
					t.truthy(part:FindFirstChild("Print") ~= nil, part.Name .. " is printed")
					local sheet = string.match(part.Name, "^Paper_(.+)_%d+$")
					if sheet then
						papersIn[sheet] = (papersIn[sheet] or 0) + 1
					end
				end
			end
			-- every room shows all the decay its ruin calls for: the holes of a ruined drop ceiling (DECAY_HOLE_RUIN),
			-- every patch of plaster its ruin pulls off a plastered wall, its kind's sheets of paper
			for _, room in layout.rooms do
				local ruin = Finishes.ruin(id, room.id)
				local dropped = not room.noCeiling and Finishes.dropCeiling(room, SchoolShellBuilder.ceilingKey(room))
				local shown = if dropped then decayHolesShown(ruin) else 0
				t.eq(holed[room.id] or 0, shown, string.format("%s: holes in its ceiling (ruin %.2f)", room.id, ruin))
				local sites = DecayBuilder.damageSites(layout, room)
				t.eq(sitesIn[room.id] or 0, sites, string.format("%s: plaster come away (ruin %.2f)", room.id, ruin))
				local range = DecayBuilder.PaperCount[room.kind]
				local sheets = papersIn[room.id] or 0
				if range then
					t.truthy(
						sheets >= range[1] and sheets <= range[2],
						string.format(
							"%s: %d sheets of paper on its floor (%d to %d)",
							room.id,
							sheets,
							range[1],
							range[2]
						)
					)
				else
					t.eq(sheets, 0, room.id .. ": no paper in a " .. room.kind)
				end
			end
		end
		t.truthy(falls >= DECAY_MIN.holes, string.format("ruined ceilings drop their tiles (%d holes)", falls))
		t.truthy(tiles >= falls / 2, string.format("most holes have their tile below (%d of %d)", tiles, falls))
		t.truthy(puddles >= DECAY_MIN.puddles, string.format("standing water in the wet rooms (%d)", puddles))
		t.truthy(damage >= DECAY_MIN.sites, string.format("plaster has come away (%d sites)", damage))
		t.truthy(papers >= DECAY_MIN.papers, string.format("paper on the floors (%d)", papers))
	end,

	["lights: every stair vestibule's strip and red lamp are fast to its ceiling, on every floor"] = function(
		t: Expect
	)
		-- (buildLight only ever lowers a fixture to its ceiling: one set lower hangs in the air with nothing holding it;
		-- a bulb hangs on its flex)
		local checked = 0
		for _, id in WorldConfig.LevelOrder do
			local layout = layoutOf(id)
			local rooms = LayoutSchema.indexRooms(layout)
			local origin = WorldConfig.levelOrigin(id)
			local here = 0
			for _, d in world()[id]:GetDescendants() do
				if not (d:IsA("BasePart") and d:HasTag(Tags.LevelLight)) then
					continue
				end
				local room = rooms[d:GetAttribute(W.ZoneId) :: string]
				local kind = d:GetAttribute(W.LightKind)
				if not room or (room.kind ~= "Airlock" and room.kind ~= "Stairwell") or kind == "Bulb" then
					continue
				end
				local ceiling = origin.Y + SchoolShellBuilder.ceilingBottom(layout, room)
				local _, hi = aabb(d)
				t.truthy(
					math.abs(ceiling - hi.Y) <= 0.15,
					string.format(
						"%s %s (%s): %.2f studs under the ceiling",
						room.id,
						d.Name,
						tostring(kind),
						ceiling - hi.Y
					)
				)
				here += 1
			end
			t.truthy(here >= 3, string.format("%s: its stair vestibules' fixtures (%d)", id, here))
			checked += here
		end
		t.truthy(checked > 0, "fixtures checked")
	end,

	["signage keeps off the chalkboards, noticeboards, cabinets and plaster damage"] = function(t: Expect)
		for _, id: Enums.LayoutId in Enums.LayoutId do
			local signs = props(id):FindFirstChild("Signs_" .. id)
			if not signs then
				continue
			end
			local mounted: { BasePart } = {}
			for _, name in { "Furniture_" .. id, "Decay_" .. id } do
				local holder = props(id):FindFirstChild(name)
				if holder then
					for _, part in parts(holder) do
						local wallPiece = string.find(part.Name, "_Frame$")
							or string.sub(part.Name, 1, 8) == "Cabinet_"
							or part:FindFirstChild("Damage") ~= nil
						if wallPiece then
							table.insert(mounted, part)
						end
					end
				end
			end
			for _, sign in parts(signs) do
				local lo, hi = aabb(sign)
				for _, part in mounted do
					local bLo, bHi = aabb(part)
					t.falsy(overlaps(lo, hi, bLo, bHi), sign.Name .. " overlaps " .. part.Name)
				end
			end
		end
	end,
	["ceiling falls: every dressed hole is a void plate under its ceiling, where ceilingFalls says"] = function(
		t: Expect
	)
		local total = 0
		for _, id: Enums.LayoutId in Enums.LayoutId do
			local layout = layoutOf(id)
			local level = world()[id]
			local shell = level and level:FindFirstChild("Shell")
			if not shell then
				continue
			end
			local seen: { [string]: number } = {}
			for _, hole in SchoolShellBuilder.ceilingFalls(layout) do
				seen[hole.room] = (seen[hole.room] or 0) + 1
				local plate = shell:FindFirstChild(string.format("MissingTile_%s_%d", hole.room, seen[hole.room]))
				assert(
					plate and plate:IsA("BasePart"),
					string.format("%s hole %d is built", hole.room, seen[hole.room])
				)
				t.truthy(
					(plate.CFrame.Position - hole.centre).Magnitude < 0.1,
					plate.Name .. " where ceilingFalls says"
				)
				t.truthy(isDetail(plate), plate.Name .. " never collides")
				t.truthy(plate.Size.X < hole.size.X and plate.Size.Z < hole.size.Y, plate.Name .. " inside its tile")
				total += 1
			end
		end
		t.truthy(total > 0, "some ceilings have come down")
	end,

	["decor: a Detail level marks only parts that never collide, are never queried or touched"] = function(t: Expect)
		local marked = 0
		for id, level in world() do
			for _, part in parts(level) do
				local detail = part:GetAttribute(W.Detail)
				if detail == nil then
					continue
				end
				marked += 1
				t.truthy(
					type(detail) == "number" and detail >= 1 and detail <= 3 and detail % 1 == 0,
					string.format("%s Detail %s is 1..3", part:GetFullName(), tostring(detail))
				)
				if not isDetail(part) then
					t.fail(
						string.format("%s (%s) is decor but collides, is queried or touched", part:GetFullName(), id)
					)
				end
			end
		end
		t.truthy(marked >= 2000, string.format("%d decor parts", marked))
	end,

	["tunnel dressing: decor but the landmarks, a cable tray in every tunnel, steam vents that leak"] = function(
		t: Expect
	)
		local layout = layoutOf("Level0_Basement")
		local tunnels = model(props(layout.id), "Tunnels_" .. layout.id)
		local levels: { [number]: number } = {}
		local wayfinding = 0
		for _, part in parts(tunnels) do
			t.truthy(isDetail(part), part.Name .. " never collides")
			local detail = part:GetAttribute(W.Detail)
			local name = part.Name
			-- junction plates, region / keep-room stencils and arrows find the way at every setting
			local finds = string.sub(name, 1, 6) == "Plate_"
				or (
					string.sub(name, 1, 6) == "Paint_"
					and (
						string.find(name, "_RegionSign_", 1, true) ~= nil
						or string.find(name, "_Arrow_", 1, true) ~= nil
					)
				)
			if finds then
				wayfinding += 1
				t.eq(detail, nil, name .. " stays at every setting")
			else
				t.truthy(detail ~= nil, name .. " carries a Detail level")
				if type(detail) == "number" then
					levels[detail] = (levels[detail] or 0) + 1
				end
			end
		end
		t.truthy(wayfinding >= 40, string.format("%d wayfinding landmarks", wayfinding))
		for level = 1, 3 do
			t.truthy((levels[level] or 0) >= 50, string.format("Detail %d: %d parts", level, levels[level] or 0))
		end
		-- every tunnel and gallery carries a cable tray
		local trays: { [string]: boolean } = {}
		for _, part in parts(tunnels) do
			local room = string.match(part.Name, "^(.-)_TrayFloor$")
			if room then
				trays[room] = true
			end
		end
		for _, room in layout.rooms do
			local long = math.max(room.rect.w, room.rect.d) >= 10
			if
				(room.kind == "Tunnel" or room.kind == "Gallery")
				and long
				and not string.find(room.id, "Alcove", 1, true)
			then
				t.truthy(trays[room.id], room.id .. " has a cable tray")
			end
		end
		-- steam vents: tagged nozzles leaking a Steam plume, most of them in the steam region
		local vents = 0
		for _, part in parts(tunnels) do
			if part:HasTag(Tags.SteamVent) then
				vents += 1
				local plume = part:FindFirstChild("Steam", true)
				t.truthy(plume ~= nil and plume:IsA("ParticleEmitter"), part.Name .. " leaks a Steam plume")
			end
		end
		t.truthy(vents >= 12, string.format("%d steam vents", vents))
	end,
}
