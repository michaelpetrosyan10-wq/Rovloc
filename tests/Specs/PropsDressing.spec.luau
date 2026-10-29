--!strict
-- Set dressing and pool dressing contracts, checked on the real layouts: every LabCounter, SmashedLocker, DripPipe
-- anchor and every FloorDebris / ScareStep trigger is dressed within its part budget; flasks rest on the epoxy
-- worktops and the pool's starting-block tops stay clear for theirs; Drip parts carry the DripPipe tag at dripPoint(); debris lies inside its trigger and never collides;
-- nothing intrudes on a doorway, a grate front, a stair landing or a spawn point; the pool dressing never makes a
-- route across the water that skips the swim; client dressing is non-colliding, unqueried and seed-deterministic.
-- Signs and posters are lit, non-colliding prints on their walls above the chair rail, clear of every opening, with
-- every word from Strings; the plant rooms' pipework runs above the door heads and clear of every light fixture and drip pipe.
-- Classrooms face a chalkboard with rows of desks that leave aisles, furniture stays within its budgets, decay (fallen
-- tiles under their holes, puddles, plaster damage, paper) never collides, and no sign lands on a board or a hole.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Finishes = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Finishes)
local FurnitureBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.FurnitureBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local PoolWaterBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PoolWaterBuilder)
local SchoolShellBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.SchoolShellBuilder)
local SetDressingBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.SetDressingBuilder)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor

local W = Attributes.World
local BUDGET = SetDressingBuilder.Budget

local STATIC_PREFIXES: { string } = {
	"LabCounter_",
	"SmashedLocker_",
	"DripPipe_",
	"FloorDebris_",
	"PoolDressing_",
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
-- Cosmetic builds (two with one seed, one with another)
--------------------------------------------------------------------------------

local cosmetic: { [number]: Folder } = {}

local function dressing(seed: number, slot: number): Instance
	local folder = cosmetic[slot]
	if not folder then
		local fresh = Instance.new("Folder")
		fresh.Name = "Cosmetic" .. slot
		Builder.BuildCosmetic(seed, fresh)
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
	["lab counters: one per anchor, within budget, passthrough bodies"] = function(t: Expect)
		local layout = layoutOf("Level2_ScienceHall")
		local folder = props(layout.id)
		local counters = anchorsOf(layout, "LabCounter")
		t.eq(#counters, 33, "Level2 lab counters (32 islands and the specimen store's bench)")
		for _, anchor in counters do
			local counter = model(folder, "LabCounter_" .. anchor.id)
			t.eq(counter:GetAttribute(W.AnchorId), anchor.id)
			t.eq(counter:GetAttribute(W.LevelId), layout.id)
			local list = parts(counter)
			t.truthy(#list >= 18 and #list <= BUDGET.LabCounter, string.format("%s has %d parts", anchor.id, #list))
			local tops = 0
			for _, part in list do
				t.truthy(part.Anchored, part.Name .. " anchored")
				t.truthy(isPassthrough(part) or isDetail(part), part:GetFullName() .. " is passthrough or detail")
				if string.sub(part.Name, 1, 4) == "Top_" then
					tops += 1
					t.truthy(isPassthrough(part), "worktop collides for players")
				end
			end
			t.eq(tops, 4, anchor.id .. " worktop pieces round the sink")
		end
	end,

	["lab counters: every flask candidate rests on its counter's worktop"] = function(t: Expect)
		local layout = layoutOf("Level2_ScienceHall")
		local folder = props(layout.id)
		local origin = WorldConfig.levelOrigin(layout.id)
		local flasks = anchorsOf(layout, "FlaskCandidate")
		t.eq(#flasks, 31, "Level2 flask candidates")
		for _, flask in flasks do
			local point = origin + flask.pos
			local rests = 0
			for _, counterAnchor in anchorsOf(layout, "LabCounter") do
				if counterAnchor.room ~= flask.room then
					continue
				end
				local counter = model(folder, "LabCounter_" .. counterAnchor.id)
				for _, part in parts(counter) do
					local lo, hi = aabb(part)
					local under = point.X > lo.X + 0.05
						and point.X < hi.X - 0.05
						and point.Z > lo.Z + 0.05
						and point.Z < hi.Z - 0.05
					if string.sub(part.Name, 1, 4) == "Top_" and under then
						t.near(hi.Y, point.Y, 0.05, flask.id .. " on the worktop")
						rests += 1
					end
					-- Nothing of the counter stands in the space the flask occupies
					local clear = Vector3.new(0.5, 0, 0.5)
					if
						overlaps(
							lo,
							hi,
							point - clear + Vector3.new(0, 0.03, 0),
							point + clear + Vector3.new(0, 1.4, 0)
						)
					then
						t.fail(string.format("%s crowds %s", part:GetFullName(), flask.id))
					end
				end
			end
			t.eq(rests, 1, flask.id .. " rests on exactly one worktop piece")
		end
	end,

	["smashed lockers: a bank of 3-5 lockers backed onto the wall at every anchor"] = function(t: Expect)
		for _, id in { "Level1_Hallways", "Level3_Gymnasium" } do
			local layout = layoutOf(id)
			local origin = WorldConfig.levelOrigin(id)
			local rooms = LayoutSchema.indexRooms(layout)
			local folder = props(id)
			local anchors = anchorsOf(layout, "SmashedLocker")
			t.eq(#anchors, if id == "Level1_Hallways" then 16 else 4, id .. " smashed locker anchors")
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
		for _, id: Enums.LevelId in Enums.LevelId do
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
		for _, id: Enums.LevelId in Enums.LevelId do
			for _, d in world()[id]:GetDescendants() do
				if d:HasTag(Tags.DripPipe) then
					tagged += 1
				end
			end
		end
		t.eq(tagged, 29, "every DripPipe anchor has one tagged Drip")
	end,

	["floor debris: inside every FloorDebris and ScareStep trigger, flat, never colliding"] = function(t: Expect)
		local triggers = 0
		for _, id: Enums.LevelId in Enums.LevelId do
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
		t.eq(triggers, 18, "FloorDebris + ScareStep triggers across the school")
	end,

	["static dressing stays out of doorways, grate fronts, landings and spawns"] = function(t: Expect)
		for _, id: Enums.LayoutId in Enums.LayoutId do
			local layout = layoutOf(id)
			assertClear(t, layout, dressingParts(id))
		end
	end,

	["pool dressing: within budget, the water left to the shell, lips on the walkway, nothing that shortens a swim"] = function(
		t: Expect
	)
		local layout = layoutOf("Level4_FloodedPool")
		local origin = WorldConfig.levelOrigin(layout.id)
		local basins = layout.basins or {}
		t.eq(#basins, 1)
		local basin = basins[1]
		local pool = model(props(layout.id), "PoolDressing_" .. basin.id)
		local list = parts(pool)
		t.truthy(#list >= 120 and #list <= PoolWaterBuilder.Budget, string.format("pool dressing has %d parts", #list))
		-- The shell's surface and volume are not duplicated
		for _, part in list do
			t.falsy(part:HasTag(Tags.PoolWater), part.Name .. " is not a water volume")
			t.falsy(string.find(part.Name, "Surface", 1, true) ~= nil, part.Name .. " is not a water surface")
		end
		local pools = 0
		for _, d in world()[layout.id]:GetDescendants() do
			if d:HasTag(Tags.PoolWater) then
				pools += 1
			end
		end
		local expectedVolumes = #basins
		for _, trigger in layout.triggers do
			if trigger.kind == "PoolWater" then
				expectedVolumes += 1
			end
		end
		t.eq(pools, expectedVolumes, "PoolWater volumes are the shell's alone")
		-- No-bypass: every colliding piece over open water is deep enough (or too steep) to stand on; the lips stand on
		-- their walkway fragment and stay low on it
		local interior = Geometry.insetRect(basin.rect, Geometry.BasinWall)
		local limit = origin.Y + basin.waterLevel - PoolWaterBuilder.NoBypassDepth
		local classified = PoolWaterBuilder.classify(layout, basin)
		local colliding = 0
		local lips = 0
		for _, part in list do
			if not part.CanCollide then
				continue
			end
			colliding += 1
			local lo, hi = aabb(part)
			local box = {
				x0 = lo.X - origin.X,
				x1 = hi.X - origin.X,
				z0 = lo.Z - origin.Z,
				z1 = hi.Z - origin.Z,
				y0 = lo.Y - origin.Y,
				y1 = hi.Y - origin.Y,
			}
			if PoolWaterBuilder.onFragment(classified, box) then
				lips += 1
				t.truthy(string.sub(part.Name, 1, 3) == "Lip", part.Name .. " is a lip on its walkway")
				t.truthy(box.y1 <= 0.5 + PoolWaterBuilder.LipHeight + 1e-3, part.Name .. " stays a low kerb")
				t.truthy(isPassthrough(part), part.Name .. " lets the Creature through")
				continue
			end
			local over = math.min(hi.X, origin.X + interior.x + interior.w) - math.max(lo.X, origin.X + interior.x)
					> 1e-3
				and math.min(hi.Z, origin.Z + interior.z + interior.d) - math.max(lo.Z, origin.Z + interior.z)
					> 1e-3
			if over then
				local tilt = math.deg(math.acos(math.clamp(part.CFrame.UpVector.Y, -1, 1)))
				t.truthy(
					hi.Y <= limit + 1e-3 or tilt > PoolWaterBuilder.TiltLimit,
					string.format(
						"%s tops out at %.2f over the water (limit %.2f, tilt %.1f)",
						part.Name,
						hi.Y,
						limit,
						tilt
					)
				)
				t.truthy(hi.Y <= limit + 1e-3, part.Name .. " stays under the no-bypass line")
				t.truthy(isPassthrough(part), part.Name .. " lets the Creature through")
			end
		end
		t.truthy(colliding > lips, "some wreckage under the water still collides")
		t.truthy(lips >= #classified.fragments, "every walkway fragment has its lip")
		-- Between every pair of walkway fragments the water stays open: nothing solid above the line in a gap
		local edges = PoolWaterBuilder.breakEdges(classified)
		local swims = 0
		for _, edge in edges do
			if edge.gap > PoolWaterBuilder.StepOver then
				swims += 1
			end
		end
		t.truthy(#edges >= 8, "the walkway breaks at its cracks and its fallen span")
		t.truthy(swims >= 2, "the fallen span leaves open water on both sides")
		for _, edge in edges do
			local r = edge.fragment.rect
			local gapLo: Vector3
			local gapHi: Vector3
			local d = edge.direction
			if d.X > 0.5 then
				gapLo, gapHi = Vector3.new(r.x + r.w, limit, r.z), Vector3.new(r.x + r.w + edge.gap, 50, r.z + r.d)
			elseif d.X < -0.5 then
				gapLo, gapHi = Vector3.new(r.x - edge.gap, limit, r.z), Vector3.new(r.x, 50, r.z + r.d)
			elseif d.Z > 0.5 then
				gapLo, gapHi = Vector3.new(r.x, limit, r.z + r.d), Vector3.new(r.x + r.w, 50, r.z + r.d + edge.gap)
			else
				gapLo, gapHi = Vector3.new(r.x, limit, r.z - edge.gap), Vector3.new(r.x + r.w, 50, r.z)
			end
			gapLo = Vector3.new(origin.X + gapLo.X, gapLo.Y, origin.Z + gapLo.Z)
			gapHi = Vector3.new(origin.X + gapHi.X, gapHi.Y, origin.Z + gapHi.Z)
			for _, part in list do
				if part.CanCollide then
					local lo, hi = aabb(part)
					t.falsy(overlaps(lo, hi, gapLo, gapHi), part.Name .. " bridges the gap off " .. edge.fragment.id)
				end
			end
		end
		-- The broken walkway has its chunks, the lanes their ropes, the deep end its drain
		local names: { [string]: number } = {}
		for _, part in list do
			local key = string.match(part.Name, "^%a+") or part.Name
			names[key] = (names[key] or 0) + 1
		end
		t.truthy((names.ChunkUnder or 0) + (names.Chunk or 0) >= swims, "a chunk hangs off every break over the water")
		t.truthy((names.Rebar or 0) >= swims * 2 + (#edges - swims), "rebar at every break and crack")
		t.truthy((names.Rope or 0) >= 4 and (names.Float or 0) >= 4, "lane ropes with floats")
		t.truthy((names.Rail or 0) >= 4 and (names.Rung or 0) >= 3, "pool ladders")
		t.truthy((names.BoardStub or 0) == 1 and (names.BoardAdrift or 0) == 1, "the snapped diving board")
		t.truthy((names.Seat or 0) == 1 and (names.Backrest or 0) == 1, "the toppled lifeguard chair")
		t.truthy((names.DrainFrame or 0) == 1, "the deep-end drain")
		t.truthy((names.Kickboard or 0) >= 2 and (names.Scum or 0) >= 3, "debris on the water")
		t.truthy((names.GrabBar or 0) == #classified.blocks, "every starting block dressed")
	end,

	["pool dressing: the starting blocks keep their tops clear for the flasks standing on them"] = function(t: Expect)
		local layout = layoutOf("Level4_FloodedPool")
		local origin = WorldConfig.levelOrigin(layout.id)
		local basin = (layout.basins or {})[1]
		assert(basin, "the pool basin")
		local classified = PoolWaterBuilder.classify(layout, basin)
		t.eq(#classified.blocks, 6, "six starting blocks")
		local list = parts(model(props(layout.id), "PoolDressing_" .. basin.id))
		local onBlocks = 0
		for _, flask in anchorsOf(layout, "FlaskCandidate") do
			local block: PoolWaterBuilder.Fragment? = nil
			for _, candidate in classified.blocks do
				if LayoutSchema.rectContains(candidate.rect, flask.pos.X, flask.pos.Z) then
					block = candidate
				end
			end
			if not block then
				continue
			end
			onBlocks += 1
			t.near(flask.pos.Y, block.top, 0.05, flask.id .. " stands on its starting block's top")
			local point = origin + flask.pos
			local clear = Vector3.new(0.5, 0, 0.5)
			for _, part in list do
				local lo, hi = aabb(part)
				if
					overlaps(lo, hi, point - clear + Vector3.new(0, 0.03, 0), point + clear + Vector3.new(0, 1.4, 0))
				then
					t.fail(string.format("%s crowds %s", part:GetFullName(), flask.id))
				end
			end
		end
		t.eq(onBlocks, 3, "flask candidates on starting blocks")
	end,

	["cosmetic dressing: every anchor dressed within budget, never colliding or queried"] = function(t: Expect)
		local folder = dressing(7, 1)
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

	["cosmetic dressing: the same seed gives the same dressing, another seed another"] = function(t: Expect)
		local a, b, c = dressing(7, 1), dressing(7, 2), dressing(11, 3)
		local listA, listB, listC = parts(a), parts(b), parts(c)
		t.eq(#listA, #listB, "same seed, same part count")
		local differs = #listA ~= #listC
		for i, part in listA do
			t.eq(part.Name, listB[i].Name)
			t.truthy(part.CFrame.Position:FuzzyEq(listB[i].CFrame.Position, 1e-5), part.Name .. " same position")
			t.truthy(part.CFrame.LookVector:FuzzyEq(listB[i].CFrame.LookVector, 1e-5), part.Name .. " same rotation")
			local other = listC[i]
			if other and not part.CFrame.Position:FuzzyEq(other.CFrame.Position, 1e-3) then
				differs = true
			end
		end
		t.truthy(differs, "another seed poses and scatters differently")
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
				"Science",
				"Gym",
				"Lockers",
				"Pool",
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
		local plates = 0
		for _, id: Enums.LayoutId in Enums.LayoutId do
			local layout = layoutOf(id)
			local origin = WorldConfig.levelOrigin(id)
			local signs = props(id):FindFirstChild("Signs_" .. id)
			if not signs then
				t.truthy(id == "Level5_Roof", id .. " has signs")
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
									t.truthy(
										label.Text == Strings.get("Prop.Sign.Room", n)
											or label.Text == Strings.get("Prop.Sign.Lab", n),
										part.Name .. " names its room"
									)
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
			if id ~= "Lobby" then
				t.truthy(count >= 10, string.format("%s has %d signs", id, count))
			end
			-- STAIRS by every fire door, on the corridor side
			for _, door in layout.doors do
				if door.kind == "Airlock" then
					t.truthy(signs:FindFirstChild("Stairs_" .. door.id) ~= nil, door.id .. " has a STAIRS sign")
				end
			end
		end
		t.truthy(plates >= 25, string.format("%d room plates", plates))
	end,

	["service pipes: plant rooms only, above the door heads, clear of every light fixture and drip pipe"] = function(
		t: Expect
	)
		for _, id in { "Level0_Basement", "Level4_FloodedPool" } do
			local origin = WorldConfig.levelOrigin(id)
			local pipes = props(id):FindFirstChild("Pipes_" .. id)
			assert(pipes, id .. " has pipework")
			local list = parts(pipes)
			t.truthy(#list >= 30, string.format("%s has %d pipe parts", id, #list))
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
		local boards, desks = 0, 0
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
				elseif string.find(part.Name, "^Desk_.*_Top$") then
					desks += 1
				end
			end
			for _, room in layout.rooms do
				local used = perRoom[room.id] or 0
				local cap = if room.kind == "Classroom"
					then math.max(budget.Classroom, budget.Hall)
					elseif room.kind == "Office" then budget.Office
					elseif room.kind == "Lab" then budget.Lab
					elseif room.kind == "Corridor" then budget.Corridor
					else 0
				t.truthy(used <= cap, string.format("%s has %d furniture parts (cap %d)", room.id, used, cap))
			end
		end
		t.truthy(boards >= 20, string.format("classrooms and labs have chalkboards (%d)", boards))
		t.truthy(desks >= 60, string.format("pupils' desks stand in the classrooms (%d)", desks))
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
		-- Upright pupils' desks of one row stand at least a player's width apart.
		local rows: { [string]: { number } } = {}
		for _, piece in plan.pieces do
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
		t.truthy(checked > 0, "rows checked")
	end,

	["decay: fallen tiles under their holes, glossy puddles, damage on the walls, nothing collides or is queried"] = function(
		t: Expect
	)
		local falls, tiles, puddles, damage, papers = 0, 0, 0, 0, 0
		for _, id: Enums.LayoutId in Enums.LayoutId do
			local layout = layoutOf(id)
			local decay = props(id):FindFirstChild("Decay_" .. id)
			local holes = SchoolShellBuilder.ceilingFalls(layout)
			falls += #holes
			if not decay then
				continue
			end
			for _, part in parts(decay) do
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
				elseif string.sub(part.Name, 1, 7) == "Damage_" and part:FindFirstChild("Damage") then
					damage += 1
					t.eq(part.Transparency, 1, part.Name .. " carries only its paint")
					local y = part.CFrame.Position.Y - WorldConfig.levelOrigin(id).Y
					t.truthy(y > Finishes.RailTop, part.Name .. " above the rail")
				elseif string.sub(part.Name, 1, 6) == "Paper_" then
					papers += 1
					t.truthy(part:FindFirstChild("Print") ~= nil, part.Name .. " is printed")
				end
			end
		end
		t.truthy(falls >= 20, string.format("ruined ceilings drop their tiles (%d holes)", falls))
		t.truthy(tiles >= falls / 2, string.format("most holes have their tile below (%d of %d)", tiles, falls))
		t.truthy(puddles >= 10, string.format("standing water in the wet rooms (%d)", puddles))
		t.truthy(damage >= 10, string.format("plaster has come away (%d sites)", damage))
		t.truthy(papers >= 30, string.format("paper on the floors (%d)", papers))
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
}
