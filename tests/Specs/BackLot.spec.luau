--!strict
-- The Back Lot (docs/design/game-spec-v2.md 4.1, 2.4): the opening's set and the prologue's walk, built fresh with the
-- street exterior it stands on.
--   * The fence is closed: its west, south and east runs (the chained gate in the south one) and the facade leave no
--     gap a player fits through, at the fence's height and over it to the invisible wall's.
--   * A mark per slot: four BinStart anchors, slots 1..4, each on the floor inside its own bin, with the lid's PushLid
--     prompt; the cutscene marks the timelines are laid out from.
--   * The hatch is 25 to 45 studs from every bin, and the walk from each bin's climb-out spot to the hatch is clear (a
--     body of radius 1 round everything that collides, on a half-stud grid).
--   * It is a set: WorldConfig's box holds it, nothing in it is a hide, a Creature place or a noise; one ChuteHatch
--     trigger; the lamp, the strobe and the two window rows in their scripted light groups; the chute's mouth on the
--     Basement's mark.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local BackLotBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.BackLotBuilder)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)
local Rng = require(ReplicatedStorage.Shared.Util.Rng)
local SchoolShellBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.SchoolShellBuilder)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local W = Attributes.World
local GROUND = WorldConfig.GroundY
local BODY = 1 -- a player's radius
local STEP = 1.9 -- what a player steps up without a jump
local HEAD = 5
local CELL = 0.5

type Built = { exterior: Folder, lot: Model }

local cached: Built? = nil

local function built(): Built
	local done = cached
	if done then
		return done
	end
	local exterior = Instance.new("Folder")
	exterior.Name = "Exterior"
	SchoolShellBuilder.buildExterior(exterior)
	local lot = BackLotBuilder.build(exterior)
	local result: Built = { exterior = exterior, lot = lot }
	cached = result
	return result
end

local function attachments(root: Instance, kind: string): { Attachment }
	local out: { Attachment } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("Attachment") and d:GetAttribute(W.AnchorKind) == kind then
			table.insert(out, d)
		end
	end
	table.sort(out, function(a: Attachment, b: Attachment): boolean
		return a.Name < b.Name
	end)
	return out
end

local function worldOf(a: Attachment): Vector3
	return PropKit.attachmentWorld(a).Position
end

local function named(root: Instance, name: string): Instance?
	for _, d in root:GetDescendants() do
		if d.Name == name then
			return d
		end
	end
	return nil
end

-- Whether world point `p` lies inside `part`'s box (grown by `pad`).
local function inside(part: BasePart, p: Vector3, pad: number): boolean
	local q = part.CFrame:PointToObjectSpace(p)
	local h = part.Size / 2
	return math.abs(q.X) <= h.X + pad and math.abs(q.Y) <= h.Y + pad and math.abs(q.Z) <= h.Z + pad
end

local function colliders(root: Instance): { BasePart }
	local out: { BasePart } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and d.CanCollide then
			table.insert(out, d)
		end
	end
	return out
end

-- The world box of a part (conservative for rotated ones).
local function bounds(part: BasePart): (Vector3, Vector3)
	local cf, h = part.CFrame, part.Size / 2
	local e = Vector3.new(
		math.abs(cf.RightVector.X) * h.X + math.abs(cf.UpVector.X) * h.Y + math.abs(cf.LookVector.X) * h.Z,
		math.abs(cf.RightVector.Y) * h.X + math.abs(cf.UpVector.Y) * h.Y + math.abs(cf.LookVector.Y) * h.Z,
		math.abs(cf.RightVector.Z) * h.X + math.abs(cf.UpVector.Z) * h.Y + math.abs(cf.LookVector.Z) * h.Z
	)
	return cf.Position - e, cf.Position + e
end

return {
	["the fence is closed: west, south (the chained gate in it) and east, and the facade across the north"] = function(
		t: Expect
	)
		local set = BackLotBuilder.Set
		local lot = set.lot
		local walls = colliders(built().lot)
		-- the facade: the school's south wall runs the whole lot, the fence's runs end on its face
		t.truthy(lot.x0 >= 0 and lot.x1 <= WorldConfig.FootprintSize.X, "the lot lies along the south facade")
		t.near(lot.z0, WorldConfig.FootprintSize.Y + WorldConfig.ExteriorWallThickness / 2, 1e-6, "from its face")
		local function closed(a: Vector3, b: Vector3, side: string)
			local length = (b - a).Magnitude
			local gaps: { string } = {}
			for _, y in { 1, 5, set.fenceHeight - 0.5, set.wallHeight - 0.5 } do
				local n = math.ceil(length / 0.25)
				for i = 0, n do
					local p = a + (b - a) * (i / n) + Vector3.new(0, y, 0)
					local covered = false
					for _, part in walls do
						if inside(part, p, 0.05) then
							covered = true
							break
						end
					end
					if not covered then
						table.insert(gaps, string.format("(%.2f, %.1f, %.2f)", p.X, p.Y, p.Z))
					end
				end
			end
			t.eq(#gaps, 0, side .. " has gaps at " .. table.concat(gaps, " ", 1, math.min(#gaps, 6)))
		end
		closed(Vector3.new(lot.x0, GROUND, lot.z0), Vector3.new(lot.x0, GROUND, lot.z1), "the west fence")
		closed(Vector3.new(lot.x0, GROUND, lot.z1), Vector3.new(lot.x1, GROUND, lot.z1), "the south fence and gate")
		closed(Vector3.new(lot.x1, GROUND, lot.z1), Vector3.new(lot.x1, GROUND, lot.z0), "the east fence")
		t.truthy(set.fenceHeight == 10 and set.wallHeight == 14, "10 high, an invisible wall to 14")
		local gate = named(built().lot, "Padlock")
		t.truthy(gate and PropKit.findPrompt(gate, "Locked") ~= nil, "the gate's chain answers Chained.")
	end,

	["a mark per slot: four bins, each its BinStart on its floor, its lid's PushLid prompt"] = function(t: Expect)
		local lot = built().lot
		local starts = attachments(lot, "BinStart")
		t.eq(#starts, 4, "four bin starts")
		local slots: { [number]: boolean } = {}
		for _, bin in BackLotBuilder.Set.bins do
			local model = named(lot, "Bin_" .. bin.name)
			t.truthy(model and model:IsA("Model"), bin.name .. " built")
			if not (model and model:IsA("Model")) then
				continue
			end
			local start: Attachment? = nil
			for _, a in starts do
				if a:GetAttribute(W.Slot) == bin.slot then
					start = a
				end
			end
			t.truthy(start ~= nil, bin.name .. " has slot " .. bin.slot .. "'s mark")
			if start then
				slots[bin.slot] = true
				t.eq(start:GetAttribute(W.LevelId), "BackLot")
				local p = worldOf(start)
				local floor = model:FindFirstChild("Floor") :: BasePart
				t.truthy(
					math.abs(p.X - bin.x) < 1e-3 and math.abs(p.Z - bin.z) < 1e-3,
					bin.name .. ": the mark in its middle"
				)
				t.near(p.Y, floor.CFrame.Position.Y + floor.Size.Y / 2, 1e-3, bin.name .. ": on its floor")
			end
			local prompt = PropKit.findPrompt(model, "PushLid")
			t.truthy(
				prompt ~= nil and math.abs(prompt.HoldDuration - 0.6) < 1e-4 and BackLotBuilder.LidHold == 0.6,
				bin.name .. " lid: PushLid, a 0.6 s hold"
			)
			t.truthy(PropKit.leafRest(model, "Lid") ~= nil, bin.name .. " lid is a hinged leaf")
			t.truthy(PropKit.findAttachment(model, "ClimbOut") ~= nil, bin.name .. " climb-out spot")
		end
		for slot = 1, 4 do
			t.truthy(slots[slot], "slot " .. slot)
		end
		local marks: { [string]: boolean } = {}
		for _, a in attachments(lot, "CutsceneMark") do
			marks[a.Name] = true
			t.eq(a:GetAttribute(W.LevelId), "BackLot", a.Name)
		end
		for _, id in
			{ "BL_Mark_Origin", "BL_Mark_StaffDoors", "BL_Mark_Danny", "BL_Mark_Gate", "BL_Mark_Lamp", "BL_Mark_Hatch" }
		do
			t.truthy(marks[id], id)
		end
	end,

	["the hatch is 25 to 45 studs from every bin; the walk there from each climb-out is clear"] = function(t: Expect)
		local set = BackLotBuilder.Set
		local lot = built().lot
		local hatch = named(lot, "ChuteHatch")
		assert(hatch and hatch:IsA("Model"), "the hatch")
		local climbIn = PropKit.findAttachment(hatch, "ClimbIn")
		assert(climbIn, "the hatch's ClimbIn spot")
		t.truthy(PropKit.findPrompt(hatch, "ClimbIn") ~= nil and BackLotBuilder.ClimbHold == 0.6, "its prompt")
		local goal = worldOf(climbIn)
		local centre = Vector3.new(set.hatch.x, GROUND, set.hatch.z)
		for _, a in attachments(lot, "BinStart") do
			local p = worldOf(a)
			local d = (Vector3.new(p.X, GROUND, p.Z) - centre).Magnitude
			t.truthy(d >= 25 and d <= 45, string.format("%s is %.1f studs from the hatch", a.Name, d))
		end
		-- the walk: a half-stud grid over the lot, a cell blocked within BODY of anything that collides between a step
		-- up and head height
		local x0, x1, z0, z1 = set.lot.x0, set.lot.x1, set.lot.z0, set.lot.z1
		local nx, nz = math.floor((x1 - x0) / CELL), math.floor((z1 - z0) / CELL)
		local blocked: { [number]: boolean } = {}
		for _, part in colliders(built().exterior) do
			local lo, hi = bounds(part)
			local floorY = BackLotBuilder.groundAt((lo.Z + hi.Z) / 2)
			if hi.Y <= floorY + STEP or lo.Y >= floorY + HEAD then
				continue
			end
			for i = math.max(0, math.floor((lo.X - BODY - x0) / CELL)), math.min(nx, math.ceil((hi.X + BODY - x0) / CELL)) do
				for j = math.max(0, math.floor((lo.Z - BODY - z0) / CELL)), math.min(nz, math.ceil((hi.Z + BODY - z0) / CELL)) do
					local x, z = x0 + i * CELL, z0 + j * CELL
					local dx = math.max(lo.X - x, 0, x - hi.X)
					local dz = math.max(lo.Z - z, 0, z - hi.Z)
					if dx * dx + dz * dz < BODY * BODY then
						blocked[i * (nz + 1) + j] = true
					end
				end
			end
		end
		local function cellOf(p: Vector3): number
			return math.round((p.X - x0) / CELL) * (nz + 1) + math.round((p.Z - z0) / CELL)
		end
		local goalCell = cellOf(goal)
		t.falsy(blocked[goalCell], "the hatch's ClimbIn spot is free")
		for _, bin in set.bins do
			local model = named(lot, "Bin_" .. bin.name) :: Instance
			local out = PropKit.findAttachment(model, "ClimbOut") :: Attachment
			local start = cellOf(worldOf(out))
			t.falsy(blocked[start], bin.name .. ": its climb-out spot is free")
			local seen: { [number]: number } = { [start] = 0 }
			local queue = { start }
			local head = 1
			while head <= #queue and seen[goalCell] == nil do
				local c = queue[head]
				head += 1
				local i, j = c // (nz + 1), c % (nz + 1)
				for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
					local a, b = i + d[1], j + d[2]
					local n = a * (nz + 1) + b
					if a >= 0 and a <= nx and b >= 0 and b <= nz and not blocked[n] and seen[n] == nil then
						seen[n] = seen[c] + 1
						table.insert(queue, n)
					end
				end
			end
			local steps = seen[goalCell]
			t.truthy(steps ~= nil, bin.name .. ": a clear walk to the hatch")
			if steps then
				t.truthy(steps * CELL <= 70, string.format("%s: %.1f studs on the grid", bin.name, steps * CELL))
			end
		end
	end,

	["a set: in its box, no hide, no Creature place, one ChuteHatch trigger, its lights in scripted groups"] = function(
		t: Expect
	)
		local b = built()
		for _, part in b.lot:GetDescendants() do
			if part:IsA("BasePart") and part.Name ~= "AnchorRoot" then
				local lo, hi = bounds(part)
				local within = WorldConfig.setAt(lo + Vector3.new(0, 0.01, 0)) == "BackLot"
					and WorldConfig.setAt(hi - Vector3.new(0, 0.01, 0)) == "BackLot"
				t.truthy(within, part:GetFullName() .. " inside the set's box")
			end
			t.falsy(part:HasTag(Tags.Hideable), part.Name .. " is no hide")
		end
		for _, kind in { "PatrolWaypoint", "CreatureSpawn", "CreatureScarePose" } do
			t.eq(#attachments(b.lot, kind), 0, "no " .. kind)
		end
		local triggers = 0
		for _, part in b.exterior:GetDescendants() do
			if part:IsA("BasePart") and part:GetAttribute(W.TriggerKind) == "ChuteHatch" then
				triggers += 1
				t.truthy(
					part:HasTag(Tags.ChuteHatch) and part:GetAttribute(W.LevelId) == "BackLot",
					"tagged, on the set"
				)
			end
		end
		t.eq(triggers, 1, "one ChuteHatch trigger")
		local groups: { [string]: number } = {}
		for _, part in b.exterior:GetDescendants() do
			if part:IsA("BasePart") and part:HasTag(Tags.LevelLight) then
				local group = part:GetAttribute(W.FlickerGroup)
				if type(group) == "string" then
					groups[group] = (groups[group] or 0) + 1
				end
				t.eq(part:GetAttribute(W.LevelId), "BackLot", part.Name .. " lights the set")
			end
		end
		t.eq(groups["Scripted:BL_Lamp"], 1, "the yard lamp")
		t.eq(groups["Scripted:BL_Strobe"], 1, "the LOCKDOWN strobe")
		t.eq(groups["Scripted:BL_Windows_1"], 6, "the first row of windows")
		t.eq(groups["Scripted:BL_Windows_2"], 6, "the second row")
		t.eq(WorldConfig.setAt(Vector3.new(40, 20, 320)), "BackLot", "levelAt finds the set by its box")
		t.eq(WorldConfig.setAt(Vector3.new(40, 20, 200)), nil, "the school is no set")
	end,

	["the chute's mouth stands on the Basement's mark"] = function(t: Expect)
		local statics: { [string]: any } = {}
		BackLotBuilder.register({
			prop = function() end,
			fixture = function() end,
			static = function(kind: string, builder: any)
				statics[kind] = builder
			end,
			rig = function() end,
			cosmetic = function() end,
		})
		local build = statics.ChuteMouth
		t.truthy(build ~= nil, "registered")
		local layout = Builder.getLayout("Level0_Basement")
		assert(layout and build, "the Basement")
		local folder = Instance.new("Folder")
		local root = Instance.new("Model")
		t.eq(build({ layout = layout, root = root, parent = folder, random = Rng.seeded(1, "spec") }), 1, "one mouth")
		local mouth = folder:FindFirstChild("ChuteMouth_L0_Mark_ChuteMouth")
		t.truthy(mouth ~= nil, "built at the mark")
	end,
}
