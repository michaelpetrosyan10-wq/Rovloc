--!strict
-- Hide-and-escape props on the real layouts: Level 3's hideable lockers, Level 4's emergency floodlight switch and
-- Level 5's parachute crate, built through ProceduralWorldBuilder.BuildAuthoritative + BuildFixtures, plus the two
-- parachute rigs through BuildRig. Contracts: one locker per Locker anchor; a player (2 x 5.2 x 1) stands inside
-- without touching any locker part; the peeking eye looks out between two slats (and the slats beside it block the
-- view); the exit anchor is in front of the door and inside the room; lockers stand flush against their wall without
-- touching it, each other or the shell; door, rip and lever poses round-trip; prompts are disabled with the right
-- kinds and holds; tags, attributes, collision presets and part budgets hold; the switch hangs on its wall with its
-- conduit up to the ceiling and drives the level's floodlight flicker group; ParachutePackCount packs rest in the
-- crate; the rigs carry their attachments; and builds are deterministic per seed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local FloodlightSwitchBuilder =
	require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.FloodlightSwitchBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local LockerBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.LockerBuilder)
local ParachuteBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.ParachuteBuilder)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)
local SchoolShellBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.SchoolShellBuilder)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Layout = LayoutSchema.LevelLayout

-- An oriented box (a part's volume, or a test volume).
type Box = { cframe: CFrame, half: Vector3 }

type WorldPart = { part: BasePart, lo: Vector3, hi: Vector3 }

type World = {
	runtime: { [string]: Folder }, -- Workspace.Runtime.<level> stand-ins, fixtures built
	levels: { [string]: Model }, -- the built shells, in a host outside Workspace
}

local W = Attributes.World

local GYM: Enums.LayoutId = "Level3_Gymnasium"
local POOL: Enums.LayoutId = "Level4_FloodedPool"
local ROOF: Enums.LayoutId = "Level5_Roof"
local LEVELS: { Enums.LayoutId } = { GYM, POOL, ROOF }
local SEED = 4242
local TOUCH = 2e-3 -- faces closer than this count as touching, not overlapping
local PLAYER_SIZE = Vector3.new(2, 5.2, 1)
-- CFrames are single precision, and the Lune harness stores part rotations with a few millionths of error on every
-- write, so a pose round trip carries rounding drift. A wrong transform is off by orders of magnitude more.
local POSE_EPSILON = 2e-3
local TURN_EPSILON = 1e-4

local FORBIDDEN_CLASSES: { string } = {
	"MeshPart",
	"SpecialMesh",
	"FileMesh",
	"Decal",
	"Texture",
	"SurfaceAppearance",
	"UnionOperation",
	"NegateOperation",
}

--------------------------------------------------------------------------------
-- World (built once, lazily)
--------------------------------------------------------------------------------

-- The folders these builders own under a runtime level folder.
local OWN_FOLDERS: { string } = { LockerBuilder.Folder, FloodlightSwitchBuilder.Folder, ParachuteBuilder.Folder }

local function ownFolders(level: Instance): { Instance }
	local out: { Instance } = {}
	for _, name in OWN_FOLDERS do
		local found = level:FindFirstChild(name)
		if found then
			table.insert(out, found)
		end
	end
	return out
end

local function buildRuntime(seed: number): { [string]: Folder }
	local runtime: { [string]: Folder } = {}
	local previous = Geometry.getYieldEvery()
	Geometry.setYieldEvery(0)
	for _, id in LEVELS do
		local folder = Instance.new("Folder")
		folder.Name = id
		Builder.BuildFixtures(id, folder, nil, seed)
		runtime[id] = folder
	end
	Geometry.setYieldEvery(previous)
	return runtime
end

local cached: World? = nil

local function world(): World
	local existing = cached
	if existing then
		return existing
	end
	-- The shell goes into a detached host, never Workspace: in Studio the specs run beside the live server's school.
	-- These fixtures read only the layouts; the shell is what the overlap checks test them against.
	local host = Instance.new("Model")
	host.Name = "PropsHideAndEscapeSpec"
	local result = Builder.BuildAuthoritative({ parent = host :: Instance, layouts = LEVELS, yieldEvery = 0 })
	local runtime = buildRuntime(SEED)
	local built: World = { runtime = runtime, levels = result.levels }
	cached = built
	return built
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function child(parent: Instance, name: string): Instance
	local found = parent:FindFirstChild(name)
	assert(found, string.format("%s has no child %s", parent:GetFullName(), name))
	return found
end

local function modelsIn(parent: Instance): { Model }
	local out: { Model } = {}
	for _, c in parent:GetChildren() do
		if c:IsA("Model") then
			table.insert(out, c)
		end
	end
	table.sort(out, function(a: Model, b: Model): boolean
		return a.Name < b.Name
	end)
	return out
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

local function partNamed(root: Instance, name: string): BasePart
	local found = root:FindFirstChild(name, true)
	assert(found and found:IsA("BasePart"), string.format("%s has no part %s", root:GetFullName(), name))
	return found
end

local function attachmentOf(root: Instance, name: string): Attachment
	local found = PropKit.findAttachment(root, name)
	assert(found, string.format("%s has no attachment %s", root:GetFullName(), name))
	return found
end

local function lockers(): { Model }
	return modelsIn(child(world().runtime[GYM], LockerBuilder.Folder))
end

local function switchModel(): Model
	local list = modelsIn(child(world().runtime[POOL], FloodlightSwitchBuilder.Folder))
	assert(#list == 1, "one floodlight switch")
	return list[1]
end

local function crateModel(): Model
	local list = modelsIn(child(world().runtime[ROOF], ParachuteBuilder.Folder))
	assert(#list == 1, "one parachute crate")
	return list[1]
end

local function packsOf(crate: Model): { Model }
	local out: { Model } = {}
	for _, m in modelsIn(crate) do
		if m:HasTag(Tags.ParachutePack) then
			table.insert(out, m)
		end
	end
	return out
end

local function anchorById(layout: Layout, id: string): LayoutSchema.Anchor
	for _, anchor in layout.anchors do
		if anchor.id == id then
			return anchor
		end
	end
	error("no anchor " .. id)
end

local function layoutOf(id: string): Layout
	local layout = Builder.getLayout(id)
	assert(layout, "layout " .. id)
	return layout
end

local function boxOf(part: BasePart): Box
	return { cframe = part.CFrame, half = part.Size / 2 }
end

-- Min / max corners of `part` in `frame` space.
local function extentIn(frame: CFrame, part: BasePart): (Vector3, Vector3)
	local cf = frame:ToObjectSpace(part.CFrame)
	local h = part.Size / 2
	local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
	local extent = Vector3.new(
		math.abs(r.X) * h.X + math.abs(u.X) * h.Y + math.abs(l.X) * h.Z,
		math.abs(r.Y) * h.X + math.abs(u.Y) * h.Y + math.abs(l.Y) * h.Z,
		math.abs(r.Z) * h.X + math.abs(u.Z) * h.Y + math.abs(l.Z) * h.Z
	)
	return cf.Position - extent, cf.Position + extent
end

local function boundsIn(frame: CFrame, parts: { BasePart }): (Vector3, Vector3)
	local lo = Vector3.new(math.huge, math.huge, math.huge)
	local hi = -lo
	for _, part in parts do
		local a, b = extentIn(frame, part)
		lo, hi = lo:Min(a), hi:Max(b)
	end
	return lo, hi
end

local function projectedRadius(box: Box, axis: Vector3): number
	local cf = box.cframe
	return math.abs(cf.RightVector:Dot(axis)) * box.half.X
		+ math.abs(cf.UpVector:Dot(axis)) * box.half.Y
		+ math.abs(cf.LookVector:Dot(axis)) * box.half.Z
end

-- Separating-axis test: true when the boxes interpenetrate by more than TOUCH along every axis.
local function overlaps(a: Box, b: Box): boolean
	local axesA: { Vector3 } = { a.cframe.RightVector, a.cframe.UpVector, a.cframe.LookVector }
	local axesB: { Vector3 } = { b.cframe.RightVector, b.cframe.UpVector, b.cframe.LookVector }
	local axes: { Vector3 } = table.clone(axesA)
	for _, v in axesB do
		table.insert(axes, v)
	end
	for _, u in axesA do
		for _, v in axesB do
			local c = u:Cross(v)
			if c.Magnitude > 1e-6 then
				table.insert(axes, c.Unit)
			end
		end
	end
	local delta = b.cframe.Position - a.cframe.Position
	for _, axis in axes do
		if math.abs(delta:Dot(axis)) >= projectedRadius(a, axis) + projectedRadius(b, axis) - TOUCH then
			return false
		end
	end
	return true
end

-- True when the segment from `origin` along unit `direction` for `length` studs enters `box`.
local function rayHits(origin: Vector3, direction: Vector3, length: number, box: Box): boolean
	local o = box.cframe:PointToObjectSpace(origin)
	local d = box.cframe:VectorToObjectSpace(direction)
	local os: { number } = { o.X, o.Y, o.Z }
	local ds: { number } = { d.X, d.Y, d.Z }
	local hs: { number } = { box.half.X, box.half.Y, box.half.Z }
	local enter, exit = 0, length
	for i = 1, 3 do
		if math.abs(ds[i]) < 1e-9 then
			if math.abs(os[i]) > hs[i] then
				return false
			end
		else
			local t1 = (-hs[i] - os[i]) / ds[i]
			local t2 = (hs[i] - os[i]) / ds[i]
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			enter = math.max(enter, t1)
			exit = math.min(exit, t2)
			if enter > exit then
				return false
			end
		end
	end
	return true
end

-- Parts with their oriented boxes and world AABBs, so pairwise overlap checks skip far-apart pairs cheaply.
local function obstaclesOf(parts: { BasePart }): { WorldPart }
	local out: { WorldPart } = {}
	for _, part in parts do
		local lo, hi = extentIn(CFrame.new(), part)
		table.insert(out, { part = part, lo = lo, hi = hi })
	end
	return out
end

-- The first of `obstacles` that `part` interpenetrates, if any.
local function firstOverlap(part: BasePart, obstacles: { WorldPart }): BasePart?
	local lo, hi = extentIn(CFrame.new(), part)
	local box = boxOf(part)
	for _, entry in obstacles do
		if entry.hi.X <= lo.X or entry.lo.X >= hi.X or entry.hi.Z <= lo.Z or entry.lo.Z >= hi.Z then
			continue
		end
		if entry.hi.Y <= lo.Y or entry.lo.Y >= hi.Y then
			continue
		end
		if overlaps(box, boxOf(entry.part)) then
			return entry.part
		end
	end
	return nil
end

local function rayHitsAny(origin: Vector3, direction: Vector3, length: number, parts: { BasePart }): BasePart?
	for _, part in parts do
		if rayHits(origin, direction, length, boxOf(part)) then
			return part
		end
	end
	return nil
end

-- Colliding shell parts of a level with their world AABBs (for fast candidate filtering).
local shellCache: { [string]: { WorldPart } } = {}
local function shellParts(id: string): { WorldPart }
	local hit = shellCache[id]
	if hit then
		return hit
	end
	local out: { WorldPart } = {}
	local level = world().levels[id]
	assert(level, "level " .. id)
	for _, part in partsOf(level) do
		if part.CanCollide then
			local lo, hi = extentIn(CFrame.new(), part)
			table.insert(out, { part = part, lo = lo, hi = hi })
		end
	end
	shellCache[id] = out
	return out
end

-- The first colliding shell part `parts` interpenetrate, if any.
local function shellOverlap(id: string, parts: { BasePart }): (BasePart?, BasePart?)
	local lo, hi = boundsIn(CFrame.new(), parts)
	for _, entry in shellParts(id) do
		if entry.hi.X <= lo.X or entry.lo.X >= hi.X then
			continue
		end
		if entry.hi.Y <= lo.Y or entry.lo.Y >= hi.Y or entry.hi.Z <= lo.Z or entry.lo.Z >= hi.Z then
			continue
		end
		local shellBox = boxOf(entry.part)
		for _, part in parts do
			if overlaps(boxOf(part), shellBox) then
				return part, entry.part
			end
		end
	end
	return nil, nil
end

local function expectPrompt(
	t: Expect,
	root: Instance,
	kind: Enums.PromptKind,
	hold: number,
	action: string,
	object: string,
	what: string
): ProximityPrompt
	local found = PropKit.findPrompt(root, kind)
	assert(found, what .. " has a " .. kind .. " prompt")
	t.eq(found.Enabled, false, what .. " prompt starts disabled")
	t.near(found.HoldDuration, hold, 1e-6, what .. " hold")
	t.near(Attributes.getNumber(found, W.BaseHold, -1), hold, 1e-6, what .. " BaseHold")
	t.eq(found.ActionText, Strings.get(action), what .. " action text")
	t.eq(found.ObjectText, Strings.get(object), what .. " object text")
	t.eq(found.KeyboardKeyCode, Enum.KeyCode.E, what .. " key")
	local host = found.Parent
	t.truthy(host and host:IsA("Attachment"), what .. " prompt hangs on an attachment")
	local count = 0
	for _, d in root:GetDescendants() do
		if d:IsA("ProximityPrompt") then
			count += 1
		end
	end
	t.eq(count, 1, what .. " has exactly one prompt")
	return found
end

local function textOf(root: Instance, guiName: string): string
	local gui = root:FindFirstChild(guiName, true)
	assert(gui and gui:IsA("SurfaceGui"), string.format("%s has a SurfaceGui %s", root:GetFullName(), guiName))
	local label = gui:FindFirstChildOfClass("TextLabel")
	assert(label, guiName .. " has a TextLabel")
	return label.Text
end

local function isPassthrough(part: BasePart): boolean
	return part.CanCollide
		and part.CollisionGroup == CollisionGroups.MonsterPassthrough
		and part:HasTag(Tags.MonsterPassthrough)
		and part:FindFirstChildOfClass("PathfindingModifier") ~= nil
end

local function isDetail(part: BasePart): boolean
	return not part.CanCollide and not part.CanQuery and not part.CastShadow
end

local function isCosmetic(part: BasePart): boolean
	return not part.CanCollide
		and not part.CanQuery
		and part.CollisionGroup == CollisionGroups.NoCollide
		and part.Anchored
end

-- Every part keeps its CFrame (within `epsilon`) between two snapshots.
local function snapshot(root: Instance): { [BasePart]: CFrame }
	local out: { [BasePart]: CFrame } = {}
	for _, part in partsOf(root) do
		out[part] = part.CFrame
	end
	return out
end

local function expectRestored(t: Expect, before: { [BasePart]: CFrame }, what: string)
	for part, cframe in before do
		local now = part.CFrame
		local moved = (now.Position - cframe.Position).Magnitude
		local turned = 1 - now.LookVector:Dot(cframe.LookVector)
		local rolled = 1 - now.UpVector:Dot(cframe.UpVector)
		t.truthy(moved < POSE_EPSILON, string.format("%s: %s moved %.6f", what, part.Name, moved))
		t.truthy(turned < TURN_EPSILON, string.format("%s: %s turned %.8f", what, part.Name, turned))
		t.truthy(rolled < TURN_EPSILON, string.format("%s: %s rolled %.8f", what, part.Name, rolled))
	end
end

local function signature(root: Instance): string
	local rows: { string } = {}
	for _, part in partsOf(root) do
		local p, s, c = part.CFrame.Position, part.Size, part.Color
		table.insert(
			rows,
			string.format(
				"%s|%.3f,%.3f,%.3f|%.3f,%.3f,%.3f|%.3f,%.3f,%.3f|%s",
				part:GetFullName(),
				p.X,
				p.Y,
				p.Z,
				s.X,
				s.Y,
				s.Z,
				c.R,
				c.G,
				c.B,
				part.Material.Name
			)
		)
	end
	table.sort(rows)
	return table.concat(rows, "\n")
end

-- Signature of everything these builders put under a runtime level folder.
local function ownSignature(level: Instance): string
	local rows: { string } = {}
	for _, folder in ownFolders(level) do
		table.insert(rows, signature(folder))
	end
	return table.concat(rows, "\n")
end

-- Locker frame helpers: the model's pivot is the anchor (floor centre, LookVector out through the door).
local function lockerFront(model: Model): number
	local frame = model.WorldPivot
	local lo = extentIn(frame, partNamed(model, "SideLeft"))
	return lo.Z
end

local function bodyParts(model: Model): { BasePart }
	local door = child(model, LockerBuilder.DoorLeaf)
	local out: { BasePart } = {}
	for _, part in partsOf(model) do
		if not part:IsDescendantOf(door) then
			table.insert(out, part)
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["every Locker anchor gets one hideable locker with its tags, attributes and number"] = function(t: Expect)
		local layout = layoutOf(GYM)
		local anchors = PropKit.anchorsOf(layout, "Locker")
		t.eq(#anchors, 45, "Level 3 has 45 Locker anchors (40 in the locker wing, 5 the floor objective added)")
		local list = lockers()
		t.eq(#list, #anchors, "one locker per anchor")
		local byId: { [string]: Model } = {}
		for _, model in list do
			byId[model.Name] = model
		end
		for index, anchor in anchors do
			local model = byId[anchor.id]
			assert(model, "locker for " .. anchor.id)
			t.truthy(model:HasTag(Tags.HideableLocker), anchor.id .. " HideableLocker tag")
			t.truthy(model:HasTag(Tags.Interactable), anchor.id .. " Interactable tag")
			t.eq(model:GetAttribute(W.AnchorId), anchor.id, anchor.id .. " AnchorId")
			t.eq(model:GetAttribute(W.LevelId), GYM, anchor.id .. " LevelId")
			t.eq(model:GetAttribute(W.ZoneId), anchor.room, anchor.id .. " ZoneId")
			t.eq(model:GetAttribute(W.DoorOpen), false, anchor.id .. " DoorOpen")
			t.eq(model:GetAttribute(W.OccupantUserId), nil, anchor.id .. " OccupantUserId unset")
			t.eq(textOf(model, "Number"), Strings.get("Prop.Locker.Number", index), anchor.id .. " number")
			local base = model.PrimaryPart
			assert(base and base.Name == "Base", anchor.id .. " PrimaryPart is the Base")
			-- The door faces the anchor's LookVector.
			local pivot = PropKit.anchorCFrame(GYM, anchor)
			t.truthy((model.WorldPivot.Position - pivot.Position).Magnitude < 1e-4, anchor.id .. " pivot")
			for _, name in { "HideAnchor", "PeekAnchor", "ExitAnchor" } do
				local look = PropKit.attachmentWorld(attachmentOf(model, name)).LookVector
				t.truthy(look:Dot(pivot.LookVector) > 0.9999, anchor.id .. " " .. name .. " looks out of the door")
			end
		end
	end,

	["a player fits inside every locker, which is at least 2.4 wide and 6.4 clear"] = function(t: Expect)
		for _, model in lockers() do
			local hide = PropKit.attachmentWorld(attachmentOf(model, "HideAnchor"))
			local player: Box = { cframe = hide * CFrame.new(0, PLAYER_SIZE.Y / 2, 0), half = PLAYER_SIZE / 2 }
			local interior: Box = { cframe = hide * CFrame.new(0, 3.2, 0), half = Vector3.new(1.2, 3.2, 0.8) }
			for _, part in partsOf(model) do
				t.falsy(overlaps(player, boxOf(part)), model.Name .. ": the player box hits " .. part.Name)
				t.falsy(overlaps(interior, boxOf(part)), model.Name .. ": the 2.4 x 6.4 interior hits " .. part.Name)
			end
			-- The player stands on the locker's own floor, enclosed: back, sides, top and door around them.
			local frame = model.WorldPivot
			local p = frame:PointToObjectSpace(hide.Position)
			local floorLo, floorHi = extentIn(frame, partNamed(model, "Base"))
			t.near(p.Y, floorHi.Y, 1e-4, model.Name .. " HideAnchor on the locker floor")
			t.near(floorLo.Y, 0, 1e-4, model.Name .. " floor pan on the room floor")
			local lo, hi = boundsIn(frame, partsOf(model))
			t.truthy(
				p.X > lo.X + 1 and p.X < hi.X - 1 and p.Z > lo.Z + 0.5 and p.Z < hi.Z - 0.5,
				model.Name .. " HideAnchor inside the shell"
			)
			local shelfLo = extentIn(frame, partNamed(model, "Shelf"))
			t.truthy(shelfLo.Y - p.Y >= 6.4, model.Name .. " clear height under the shelf")
			t.truthy(shelfLo.Y > p.Y + PLAYER_SIZE.Y, model.Name .. " shelf above head height")
		end
	end,

	["the peek eye looks out through the middle slit, and the slats beside it block the view"] = function(t: Expect)
		for _, model in lockers() do
			local parts = partsOf(model)
			local peek = PropKit.attachmentWorld(attachmentOf(model, "PeekAnchor"))
			local origin, look = peek.Position, peek.LookVector
			local hit = rayHitsAny(origin, look, 4, parts)
			t.eq(hit, nil, model.Name .. ": the peek ray hits " .. (if hit then hit.Name else ""))
			-- The ray leaves through the door (between its lower and upper panels, inside its width), not round it.
			local lower = partNamed(model, "DoorLower")
			local upper = partNamed(model, "DoorUpper")
			local o = lower.CFrame:PointToObjectSpace(origin)
			local d = lower.CFrame:VectorToObjectSpace(look)
			local crossing = o + d * ((-lower.Size.Z / 2 - o.Z) / d.Z)
			t.truthy(
				math.abs(crossing.X) < lower.Size.X / 2 - 0.3,
				model.Name .. " peek crosses the door between stiles"
			)
			t.truthy(crossing.Y > lower.Size.Y / 2, model.Name .. " peek crosses above the lower panel")
			local above = upper.CFrame:PointToObjectSpace(lower.CFrame * crossing)
			t.truthy(above.Y < -upper.Size.Y / 2, model.Name .. " peek crosses below the upper panel")
			-- Half a slit plus half a slat up or down, the ray meets a slat: the slits are gaps between real slats.
			local slat = partNamed(model, "Slat2")
			local slit = partNamed(model, "Slat3").CFrame.Position - slat.CFrame.Position
			local pitch = slit.Magnitude / 2
			for _, dy: number in { pitch, -pitch } do
				local blocked = rayHitsAny(origin + peek.UpVector * dy, look, 4, parts)
				t.truthy(
					blocked and string.sub(blocked.Name, 1, 4) == "Slat",
					model.Name .. " slats block beside the slit"
				)
			end
			-- Slats block line-of-sight rays (queryable, Creature-passthrough steel).
			for i = 1, 4 do
				local s = partNamed(model, string.format("Slat%d", i))
				t.truthy(s.CanQuery and isPassthrough(s), model.Name .. " slat " .. i .. " blocks sight")
			end
			-- The eye sits just behind the door at the hidden player's peeking eye height.
			local hide = PropKit.attachmentWorld(attachmentOf(model, "HideAnchor"))
			local eye = hide:PointToObjectSpace(origin)
			t.truthy(eye.Y > 4 and eye.Y < 4.7, model.Name .. " peek eye height")
			t.truthy(eye.Z < 0, model.Name .. " peek eye toward the door")
		end
	end,

	["the exit anchor stands in front of the door, inside the room"] = function(t: Expect)
		local layout = layoutOf(GYM)
		local rooms = LayoutSchema.indexRooms(layout)
		local origin = WorldConfig.levelOrigin(GYM)
		for _, model in lockers() do
			local exit = PropKit.attachmentWorld(attachmentOf(model, "ExitAnchor"))
			local frame = model.WorldPivot
			local p = frame:PointToObjectSpace(exit.Position)
			local front = lockerFront(model)
			t.near(front - p.Z, 2.2, 0.05, model.Name .. " exit 2.2 in front of the door")
			t.near(p.Y, 0, 1e-4, model.Name .. " exit at floor level")
			local lo, hi = boundsIn(frame, partsOf(model))
			t.falsy(p.X > lo.X and p.X < hi.X and p.Z > lo.Z and p.Z < hi.Z, model.Name .. " exit outside the locker")
			local roomId = model:GetAttribute(W.ZoneId)
			local room = rooms[roomId :: string]
			assert(room, model.Name .. " room")
			local at = exit.Position - origin
			t.truthy(LayoutSchema.rectContains(room.rect, at.X, at.Z, 1.5), model.Name .. " exit inside " .. room.id)
			-- A player standing at the exit is clear of every locker.
			local player: Box = { cframe = exit * CFrame.new(0, PLAYER_SIZE.Y / 2, 0), half = PLAYER_SIZE / 2 }
			for _, other in lockers() do
				if (other.WorldPivot.Position - exit.Position).Magnitude < 8 then
					for _, part in partsOf(other) do
						t.falsy(overlaps(player, boxOf(part)), model.Name .. " exit hits " .. other.Name)
					end
				end
			end
		end
	end,

	["lockers stand flush against their wall without touching it, their neighbours or the shell"] = function(t: Expect)
		local layout = layoutOf(GYM)
		local rooms = LayoutSchema.indexRooms(layout)
		local list = lockers()
		for _, model in list do
			local frame = model.WorldPivot
			local roomId = model:GetAttribute(W.ZoneId)
			local room = rooms[roomId :: string]
			assert(room, model.Name .. " room")
			-- The wall behind: the room edge the back faces, half a wall thickness in.
			local back = -frame.LookVector
			local local3 = frame.Position - WorldConfig.levelOrigin(GYM)
			local edge: number
			if math.abs(back.X) > 0.5 then
				edge = if back.X < 0 then room.rect.x else room.rect.x + room.rect.w
				edge = math.abs(local3.X - edge)
			else
				edge = if back.Z < 0 then room.rect.z else room.rect.z + room.rect.d
				edge = math.abs(local3.Z - edge)
			end
			local wallFace = edge - WorldConfig.WallThickness / 2
			local _, hi = boundsIn(frame, partsOf(model))
			t.truthy(hi.Z < wallFace and hi.Z > wallFace - 0.06, model.Name .. " back flush against the wall")
			local part, shell = shellOverlap(GYM, partsOf(model))
			t.eq(
				part,
				nil,
				string.format(
					"%s: %s cuts into %s",
					model.Name,
					if part then part.Name else "",
					if shell then shell:GetFullName() else ""
				)
			)
			for _, other in list do
				if other ~= model and (other.WorldPivot.Position - frame.Position).Magnitude < 4 then
					local obstacles = obstaclesOf(partsOf(other))
					for _, a in partsOf(model) do
						t.eq(firstOverlap(a, obstacles), nil, model.Name .. " " .. a.Name .. " overlaps " .. other.Name)
					end
				end
			end
		end
	end,

	["locker doors swing out about their hinge and round-trip"] = function(t: Expect)
		for _, model in lockers() do
			local door = child(model, LockerBuilder.DoorLeaf)
			local before = snapshot(door)
			-- The hinge barrel is coaxial with the door's hinge edge by design; everything else stays clear.
			local body: { BasePart } = {}
			for _, part in bodyParts(model) do
				if part.Name ~= "Hinge" then
					table.insert(body, part)
				end
			end
			local front = lockerFront(model)
			local frame = model.WorldPivot
			for _, openness: number in { 0.35, 1 } do
				t.truthy(LockerBuilder.setDoor(model, openness), model.Name .. " setDoor")
				local transform = PropKit.leafTransform(model, LockerBuilder.DoorLeaf)
				assert(transform, model.Name .. " door transform")
				local angle = math.acos(math.clamp(transform.LookVector:Dot(Vector3.new(0, 0, -1)), -1, 1))
				t.near(angle, openness * LockerBuilder.DoorOpenAngle, 1e-3, model.Name .. " door angle")
				t.near(transform.UpVector.Y, 1, TURN_EPSILON, model.Name .. " door turns about the vertical hinge")
				t.near(transform.Position.Magnitude, 0, POSE_EPSILON, model.Name .. " door turns about its hinge")
				for _, part in partsOf(door) do
					for _, other in body do
						t.falsy(overlaps(boxOf(part), boxOf(other)), model.Name .. " open door clips " .. other.Name)
					end
				end
			end
			-- Fully open, the whole door is out in front of the locker.
			for _, part in partsOf(door) do
				local _, hi = extentIn(frame, part)
				t.truthy(hi.Z <= front + 1e-3, model.Name .. " open door swings outward")
			end
			t.truthy(LockerBuilder.setDoor(model, 0), model.Name .. " close")
			expectRestored(t, before, model.Name .. " door")
			local rest = PropKit.leafTransform(model, LockerBuilder.DoorLeaf)
			t.truthy(rest and rest.Position.Magnitude < POSE_EPSILON, model.Name .. " door back at rest")
		end
		local stray = Instance.new("Model")
		t.eq(LockerBuilder.setDoor(stray, 1), false, "setDoor on a non-locker")
		t.eq(LockerBuilder.setRipped(stray, 1), false, "setRipped on a non-locker")
	end,

	["a ripped door lands on the floor clear of the lockers and the shell, and the rip round-trips"] = function(
		t: Expect
	)
		local list = lockers()
		local rooms = LayoutSchema.indexRooms(layoutOf(GYM))
		local origin = WorldConfig.levelOrigin(GYM)
		for _, model in list do
			local door = child(model, LockerBuilder.DoorLeaf)
			local before = snapshot(door)
			local frame = model.WorldPivot
			local front = lockerFront(model)
			-- In flight the door stays above the floor and clear of the neighbouring lockers.
			local nearby: { BasePart } = {}
			for _, other in list do
				if other ~= model and (other.WorldPivot.Position - frame.Position).Magnitude < 9 then
					for _, part in partsOf(other) do
						table.insert(nearby, part)
					end
				end
			end
			local neighbours = obstaclesOf(nearby)
			for _, step: number in { 0.15, 0.3, 0.45, 0.6, 0.75, 0.9 } do
				t.truthy(LockerBuilder.setRipped(model, step), model.Name .. " setRipped")
				for _, part in partsOf(door) do
					local lo = extentIn(frame, part)
					t.truthy(lo.Y > -1e-3, string.format("%s door below the floor at %.2f", model.Name, step))
					local hit = firstOverlap(part, neighbours)
					t.eq(
						hit,
						nil,
						string.format(
							"%s door flies through %s at %.2f",
							model.Name,
							if hit then hit:GetFullName() else "",
							step
						)
					)
				end
			end
			t.truthy(LockerBuilder.setRipped(model, 1), model.Name .. " ripped")
			local doorParts = partsOf(door)
			local lo, hi = boundsIn(frame, doorParts)
			t.truthy(lo.Y > -1e-3 and hi.Y < 0.4, model.Name .. " torn door lies on the floor")
			t.truthy(hi.Z < front - 0.3, model.Name .. " torn door lands in front of the row")
			local roomId = model:GetAttribute(W.ZoneId) :: string
			local room = rooms[roomId]
			for _, part in doorParts do
				local p = part.CFrame.Position - origin
				t.truthy(
					LayoutSchema.rectContains(room.rect, p.X, p.Z, 0.5),
					model.Name .. " torn door stays in " .. roomId
				)
			end
			local cut, shell = shellOverlap(GYM, doorParts)
			t.eq(
				cut,
				nil,
				string.format("%s torn door cuts into %s", model.Name, if shell then shell:GetFullName() else "")
			)
			local landingObstacles = obstaclesOf(bodyParts(model))
			for _, entry in neighbours do
				table.insert(landingObstacles, entry)
			end
			for _, part in doorParts do
				local hit = firstOverlap(part, landingObstacles)
				t.eq(
					hit,
					nil,
					string.format("%s torn door lands in %s", model.Name, if hit then hit:GetFullName() else "")
				)
			end
			t.truthy(LockerBuilder.setRipped(model, 0), model.Name .. " un-ripped")
			expectRestored(t, before, model.Name .. " ripped door")
		end
	end,

	["locker prompts, collision presets and part budgets"] = function(t: Expect)
		for _, model in lockers() do
			local prompt = expectPrompt(t, model, "Hide", 0.25, "Prompt.Hide", "Prompt.Locker", model.Name)
			local host = prompt.Parent :: Attachment
			local p = model.WorldPivot:PointToObjectSpace(PropKit.attachmentWorld(host).Position)
			t.truthy(p.Z < lockerFront(model), model.Name .. " prompt in front of the door")
			t.truthy(p.Y > 2 and p.Y < 5, model.Name .. " prompt at hand height")
			local parts = partsOf(model)
			t.truthy(#parts <= LockerBuilder.PartBudget, string.format("%s: %d parts", model.Name, #parts))
			local structural: { [string]: boolean } = {
				Base = true,
				SideLeft = true,
				SideRight = true,
				Back = true,
				Top = true,
				Shelf = true,
				Header = true,
				DoorLower = true,
				DoorUpper = true,
				StileHinge = true,
				StileLatch = true,
			}
			for _, part in parts do
				t.truthy(part.Anchored and not part.CanTouch, model.Name .. " " .. part.Name .. " anchored, no touch")
				if structural[part.Name] or string.sub(part.Name, 1, 4) == "Slat" then
					t.truthy(isPassthrough(part), model.Name .. " " .. part.Name .. " is MonsterPassthrough")
				else
					t.truthy(isDetail(part), model.Name .. " " .. part.Name .. " is a detail")
				end
			end
		end
	end,

	["the floodlight switch hangs on its wall with its prompt, attributes and flicker group"] = function(t: Expect)
		local layout = layoutOf(POOL)
		local anchors = PropKit.anchorsOf(layout, "FloodlightSwitch")
		t.eq(#anchors, 1, "one FloodlightSwitch anchor")
		local anchor = anchors[1]
		local model = switchModel()
		t.eq(model.Name, anchor.id)
		t.truthy(model:HasTag(Tags.FloodlightSwitch), "FloodlightSwitch tag")
		t.truthy(model:HasTag(Tags.Interactable), "Interactable tag")
		t.eq(model:GetAttribute(W.On), false, "On starts false")
		t.eq(model:GetAttribute(W.AnchorId), anchor.id, "AnchorId")
		t.eq(model:GetAttribute(W.LevelId), POOL, "LevelId")
		t.eq(model:GetAttribute(W.ZoneId), anchor.room, "ZoneId")
		expectPrompt(t, model, "Floodlight", 1.0, "Prompt.Floodlight", "Prompt.FloodlightSwitch", "switch")
		t.eq(textOf(model, "Label"), Strings.get("Prop.Floodlight.Label"), "label")
		t.eq(textOf(model, "Warning"), Strings.get("Prop.Floodlight.Warning"), "warning")

		-- It drives the flicker group of the pool's Floodlight fixtures.
		local level = world().levels[POOL]
		local groups: { [string]: number } = {}
		for _, d in child(level, "Lights"):GetDescendants() do
			if d:HasTag(Tags.LevelLight) and d:GetAttribute(W.LightKind) == "Floodlight" then
				local group = d:GetAttribute(W.FlickerGroup)
				t.truthy(type(group) == "string", "floodlight fixture has a FlickerGroup")
				groups[group :: string] = (groups[group :: string] or 0) + 1
			end
		end
		local group = model:GetAttribute(W.FlickerGroup)
		t.truthy(type(group) == "string" and (groups[group :: string] or 0) >= 9, "switch drives the floodlight group")

		-- The mounting plate sits on the wall face behind the anchor; the box stands out from it.
		local rooms = LayoutSchema.indexRooms(layout)
		local room = rooms[anchor.room]
		local pivot = PropKit.anchorCFrame(POOL, anchor)
		local wallX = WorldConfig.levelOrigin(POOL).X + room.rect.x + WorldConfig.WallThickness / 2
		t.truthy(math.abs(pivot.LookVector.X - 1) < 1e-6, "the switch faces east, off the west wall")
		local lo, hi = boundsIn(CFrame.new(), partsOf(model))
		t.truthy(lo.X >= wallX and lo.X < wallX + 0.02, "plate flush on the wall face")
		t.truthy(hi.X > pivot.Position.X, "lever reaches out past the anchor")
		local part, shell = shellOverlap(POOL, partsOf(model))
		t.eq(
			part,
			nil,
			string.format("%s cuts into %s", if part then part.Name else "", if shell then shell:GetFullName() else "")
		)
	end,

	["the floodlight lever throws up to ON and back; the indicator turns green and back"] = function(t: Expect)
		local model = switchModel()
		local lever = child(model, FloodlightSwitchBuilder.LeverLeaf)
		local before = snapshot(lever)
		local frame = model.WorldPivot
		local pivot = PropKit.leafRest(model, FloodlightSwitchBuilder.LeverLeaf)
		assert(pivot, "lever rest")
		local grip = partNamed(model, "LeverGrip")
		t.truthy(
			frame:PointToObjectSpace(grip.CFrame.Position).Y < frame:PointToObjectSpace(pivot.Position).Y,
			"OFF is down"
		)
		t.truthy(FloodlightSwitchBuilder.setLever(model, 1), "setLever")
		local transform = PropKit.leafTransform(model, FloodlightSwitchBuilder.LeverLeaf)
		assert(transform, "lever transform")
		local expected = CFrame.Angles(FloodlightSwitchBuilder.LeverThrow, 0, 0)
		t.near(transform.LookVector:Dot(expected.LookVector), 1, TURN_EPSILON, "lever throw angle")
		t.near(transform.UpVector:Dot(expected.UpVector), 1, TURN_EPSILON, "lever turns about its pivot's X axis")
		t.truthy(transform.Position.Magnitude < POSE_EPSILON, "lever turns about its pivot")
		t.truthy(
			frame:PointToObjectSpace(grip.CFrame.Position).Y > frame:PointToObjectSpace(pivot.Position).Y,
			"ON is up"
		)
		for _, part in partsOf(lever) do
			for _, other in partsOf(model) do
				if not other:IsDescendantOf(lever) and other.Name ~= "PivotBoss" then
					t.falsy(overlaps(boxOf(part), boxOf(other)), "thrown lever clips " .. other.Name)
				end
			end
		end
		t.truthy(FloodlightSwitchBuilder.setLever(model, 0), "setLever back")
		expectRestored(t, before, "lever")

		local red, green = partNamed(model, "LampRed"), partNamed(model, "LampGreen")
		local glow = partNamed(model, "IndicatorBezel"):FindFirstChildOfClass("PointLight")
		assert(glow, "indicator glow")
		t.eq(red.Material, Enum.Material.Neon, "red lamp lit while off")
		t.truthy(green.Material ~= Enum.Material.Neon, "green lamp dark while off")
		t.eq(glow.Color, FloodlightSwitchBuilder.LampLit.red, "glow red while off")
		t.truthy(FloodlightSwitchBuilder.setIndicator(model, true), "setIndicator on")
		t.eq(green.Material, Enum.Material.Neon, "green lamp lit when on")
		t.truthy(red.Material ~= Enum.Material.Neon, "red lamp dark when on")
		t.eq(green.Color, FloodlightSwitchBuilder.LampLit.green, "green lamp colour")
		t.eq(glow.Color, FloodlightSwitchBuilder.LampLit.green, "glow green when on")
		t.truthy(FloodlightSwitchBuilder.setIndicator(model, false), "setIndicator off")
		t.eq(red.Color, FloodlightSwitchBuilder.LampLit.red, "red lamp colour")
		t.eq(red.Material, Enum.Material.Neon, "red lamp lit again")
		local stray = Instance.new("Model")
		t.eq(FloodlightSwitchBuilder.setLever(stray, 1), false, "setLever on a non-switch")
		t.eq(FloodlightSwitchBuilder.setIndicator(stray, true), false, "setIndicator on a non-switch")
	end,

	["the switch conduit climbs to the ceiling; one tiny unshadowed light; budget and presets"] = function(t: Expect)
		local layout = layoutOf(POOL)
		local model = switchModel()
		local anchor = anchorById(layout, model.Name)
		local room = LayoutSchema.indexRooms(layout)[anchor.room]
		local ceiling = WorldConfig.levelOrigin(POOL).Y + SchoolShellBuilder.ceilingBottom(layout, room)
		local _, boxTop = extentIn(CFrame.new(), partNamed(model, "PullBox"))
		t.truthy(boxTop.Y <= ceiling and boxTop.Y > ceiling - 0.05, "pull box tucked under the ceiling")
		local conduitLo, conduitHi = extentIn(CFrame.new(), partNamed(model, "Conduit"))
		local _, capTop = extentIn(CFrame.new(), partNamed(model, "DripCap"))
		t.truthy(conduitLo.Y < capTop.Y + 0.5 and conduitHi.Y > ceiling - 1, "conduit runs from the cabinet up")

		local lights: { Light } = {}
		for _, d in model:GetDescendants() do
			if d:IsA("Light") then
				table.insert(lights, d)
			end
		end
		t.eq(#lights, 1, "exactly one light")
		local glow = lights[1]
		t.truthy(glow:IsA("PointLight") and (glow :: PointLight).Range <= 4, "a tiny PointLight")
		t.eq(glow.Shadows, false, "no shadows")

		local parts = partsOf(model)
		t.truthy(#parts <= FloodlightSwitchBuilder.PartBudget, string.format("switch: %d parts", #parts))
		local structural: { [string]: boolean } =
			{ Base = true, Body = true, DoorPanel = true, DripCap = true, Sill = true }
		for _, part in parts do
			t.truthy(part.Anchored and not part.CanTouch, part.Name .. " anchored, no touch")
			if structural[part.Name] then
				t.truthy(isPassthrough(part), part.Name .. " is MonsterPassthrough")
			else
				t.truthy(isDetail(part), part.Name .. " is a detail")
			end
		end
	end,

	["the parachute crate holds ParachutePackCount tagged packs, each with its grab prompt"] = function(t: Expect)
		local layout = layoutOf(ROOF)
		local anchors = PropKit.anchorsOf(layout, "ParachuteCrate")
		t.eq(#anchors, 1, "one ParachuteCrate anchor")
		local anchor = anchors[1]
		local crate = crateModel()
		t.eq(crate.Name, anchor.id)
		t.eq(crate:GetAttribute(W.AnchorId), anchor.id, "crate AnchorId")
		t.eq(crate:GetAttribute(W.LevelId), ROOF, "crate LevelId")
		t.eq(textOf(child(crate, "Front"), "Stencil"), Strings.get("Prop.Parachute.Stencil"), "front stencil")
		t.eq(textOf(child(crate, "Lid"), "Stencil"), Strings.get("Prop.Parachute.Stencil"), "lid stencil")
		local packs = packsOf(crate)
		t.eq(#packs, GameConfig.ParachutePackCount, "pack count")
		for i, pack in packs do
			t.eq(pack.Name, string.format("ParachutePack%d", i), "pack name")
			t.truthy(pack:HasTag(Tags.ParachutePack) and pack:HasTag(Tags.Interactable), pack.Name .. " tags")
			t.eq(pack:GetAttribute(W.AnchorId), anchor.id, pack.Name .. " AnchorId")
			t.eq(pack:GetAttribute(W.LevelId), ROOF, pack.Name .. " LevelId")
			t.eq(pack:GetAttribute(W.TakenByUserId), nil, pack.Name .. " TakenByUserId unset")
			local base = pack.PrimaryPart
			t.truthy(base ~= nil and base.Name == "Base", pack.Name .. " PrimaryPart")
			expectPrompt(t, pack, "ParachuteGrab", 0.5, "Prompt.ParachuteGrab", "Prompt.Parachute", pack.Name)
			for _, part in partsOf(pack) do
				t.truthy(isDetail(part) and part.Anchored, pack.Name .. " " .. part.Name .. " is a detail")
			end
			partNamed(pack, "Ripcord")
			partNamed(pack, "Buckle")
		end
		-- Only the packs carry prompts.
		local prompts = 0
		for _, d in crate:GetDescendants() do
			if d:IsA("ProximityPrompt") then
				prompts += 1
			end
		end
		t.eq(prompts, #packs, "one prompt per pack")
	end,

	["the packs rest inside the crate; the crate collides and faces the jump gap"] = function(t: Expect)
		local layout = layoutOf(ROOF)
		local crate = crateModel()
		local frame = crate.WorldPivot
		local crateParts: { BasePart } = {}
		for _, part in partsOf(crate) do
			local pack = part:FindFirstAncestorWhichIsA("Model")
			if pack == crate then
				table.insert(crateParts, part)
			end
		end
		local floorTop = select(2, extentIn(frame, partNamed(crate, "Base"))) :: Vector3
		local frontLo, frontHi = extentIn(frame, partNamed(crate, "Front"))
		local backLo = extentIn(frame, partNamed(crate, "Back"))
		local leftLo, leftHi = extentIn(frame, partNamed(crate, "EndLeft"))
		local rightLo = extentIn(frame, partNamed(crate, "EndRight"))
		for _, pack in packsOf(crate) do
			local lo, hi = boundsIn(frame, partsOf(pack))
			t.near(lo.Y, floorTop.Y, 0.12, pack.Name .. " stands on the crate floor")
			t.truthy(lo.Z > frontHi.Z and hi.Z < backLo.Z, pack.Name .. " between front and back walls")
			t.truthy(lo.X > leftHi.X and hi.X < rightLo.X, pack.Name .. " between the end walls")
			t.truthy(hi.Y > select(2, extentIn(frame, partNamed(crate, "Back"))).Y, pack.Name .. " shows over the rim")
			for _, a in partsOf(pack) do
				for _, b in crateParts do
					t.falsy(overlaps(boxOf(a), boxOf(b)), pack.Name .. " " .. a.Name .. " cuts into " .. b.Name)
				end
			end
		end
		t.truthy(leftLo.X < frontLo.X + 1e-3, "end walls flush with the front")
		local parts = partsOf(crate)
		t.truthy(#parts <= ParachuteBuilder.CrateBudget, string.format("crate + packs: %d parts", #parts))
		for _, name in { "Base", "Front", "Back", "EndLeft", "EndRight", "Skid1", "Skid2", "Lid" } do
			local part = partNamed(crate, name)
			t.truthy(part.CanCollide and part.CollisionGroup == CollisionGroups.Default, name .. " collides")
			t.truthy(part.Anchored and not part.CanTouch, name .. " anchored")
		end
		-- The crate's front faces the jump gap in the parapet, on the roof deck, and nothing cuts into it.
		local origin = WorldConfig.levelOrigin(ROOF)
		local rooms = LayoutSchema.indexRooms(layout)
		local gap = rooms[layout.exit]
		local centre = LayoutSchema.rectCenter(gap.rect)
		local toGap = (origin + Vector3.new(centre.X, 0, centre.Y) - frame.Position).Unit
		t.truthy(frame.LookVector:Dot(toGap) > 0.9, "the crate faces the jump gap")
		local lo = boundsIn(CFrame.new(), parts)
		t.near(lo.Y, origin.Y, 1e-3, "the crate stands on the roof deck")
		local part, shell = shellOverlap(ROOF, crateParts)
		t.eq(
			part,
			nil,
			string.format("%s cuts into %s", if part then part.Name else "", if shell then shell:GetFullName() else "")
		)
	end,

	["the parachute backpack rig wears at BackAttach with its ripcord on the chest"] = function(t: Expect)
		t.truthy(Builder.HasRig(ParachuteBuilder.BackpackRig), "backpack rig registered")
		local host = Instance.new("Folder")
		local mount = CFrame.new(12, 40, -7) * CFrame.Angles(0, math.rad(35), 0)
		local rig = Builder.BuildRig(ParachuteBuilder.BackpackRig, host, mount)
		assert(rig, "backpack rig built")
		t.eq(rig.Name, ParachuteBuilder.BackpackRig)
		t.eq(rig.Parent, host, "parented to the host")
		local base = rig.PrimaryPart
		assert(base, "backpack PrimaryPart")
		local back = PropKit.attachmentWorld(attachmentOf(rig, "BackAttach"))
		t.truthy((back.Position - mount.Position).Magnitude < 1e-4, "BackAttach at the back mount")
		t.truthy(back.LookVector:Dot(mount.LookVector) > 1 - TURN_EPSILON, "BackAttach faces the wearer's way")
		t.eq(attachmentOf(rig, "BackAttach").Parent, base, "BackAttach on the PrimaryPart")
		local ripcord = attachmentOf(rig, "Ripcord")
		local handle = ripcord.Parent
		assert(handle and handle:IsA("BasePart"), "Ripcord on a part")
		local r = mount:PointToObjectSpace(PropKit.attachmentWorld(ripcord).Position)
		t.truthy(r.Z < -1 and r.X > 0, "ripcord handle on the wearer's right chest")
		local lo = extentIn(mount, base)
		t.truthy(lo.Z > 0, "container hangs behind the back")
		local parts = partsOf(rig)
		t.truthy(#parts <= ParachuteBuilder.BackpackBudget, string.format("backpack: %d parts", #parts))
		for _, part in parts do
			t.truthy(isCosmetic(part), part.Name .. " is cosmetic")
		end
		host:Destroy()
	end,

	["the parachute canopy rig spans about 14 studs, about 10 above its Harness"] = function(t: Expect)
		t.truthy(Builder.HasRig(ParachuteBuilder.CanopyRig), "canopy rig registered")
		local host = Instance.new("Folder")
		local harness = CFrame.new(-30, 90, 55) * CFrame.Angles(0, math.rad(-120), 0)
		local rig = Builder.BuildRig(ParachuteBuilder.CanopyRig, host, harness)
		assert(rig, "canopy rig built")
		t.eq(rig.Name, ParachuteBuilder.CanopyRig)
		local base = rig.PrimaryPart
		assert(base, "canopy PrimaryPart")
		local at = PropKit.attachmentWorld(attachmentOf(rig, "Harness"))
		t.truthy((at.Position - harness.Position).Magnitude < 1e-4, "Harness at the harness point")
		t.truthy(at.LookVector:Dot(harness.LookVector) > 1 - TURN_EPSILON, "Harness faces the flying direction")
		local cells: { BasePart } = {}
		local lines = 0
		for _, part in partsOf(rig) do
			local name = part.Name
			if name == "Base" or string.match(name, "^Cell%d") or string.match(name, "^Nose%d") then
				table.insert(cells, part)
			elseif string.match(name, "^Line%d") then
				lines += 1
			end
		end
		t.truthy(#cells >= 18, "cells and their noses")
		t.truthy(lines >= 8, "suspension lines")
		local lo, hi = boundsIn(harness, cells)
		t.truthy(hi.X - lo.X > 13 and hi.X - lo.X < 15.5, string.format("span %.2f", hi.X - lo.X))
		t.truthy(lo.Y > 8 and hi.Y < 12.5, string.format("canopy %.2f .. %.2f above the harness", lo.Y, hi.Y))
		local _, centreTop = extentIn(harness, base)
		t.truthy(centreTop.Y > hi.Y - 0.2, "the arc peaks at the centre cell")
		for _, name in { "RiserLeftFront", "RiserLeftRear", "RiserRightFront", "RiserRightRear" } do
			local riserLo = extentIn(harness, partNamed(rig, name))
			t.truthy(riserLo.Y < 0.3, name .. " reaches the harness")
		end
		local parts = partsOf(rig)
		t.truthy(#parts <= ParachuteBuilder.CanopyBudget, string.format("canopy: %d parts", #parts))
		for _, part in parts do
			t.truthy(isCosmetic(part), part.Name .. " is cosmetic")
		end
		host:Destroy()
	end,

	["fixtures are deterministic per seed, vary between seeds and rebuild in place"] = function(t: Expect)
		-- Two fresh builds (the shared world's props have been posed by other specs).
		local first = buildRuntime(SEED)
		local again = buildRuntime(SEED)
		for _, id in LEVELS do
			t.eq(ownSignature(again[id]), ownSignature(first[id]), id .. " rebuilds identically from the same seed")
		end
		local other = buildRuntime(SEED + 1)
		t.truthy(ownSignature(other[GYM]) ~= ownSignature(first[GYM]), "another seed varies the lockers")
		t.truthy(ownSignature(other[ROOF]) ~= ownSignature(first[ROOF]), "another seed varies the crate")
		-- Building into the same runtime folder again replaces the previous run's fixtures.
		local previous = Geometry.getYieldEvery()
		Geometry.setYieldEvery(0)
		local count = Builder.BuildFixtures(GYM, again[GYM], nil, SEED + 2)
		Geometry.setYieldEvery(previous)
		t.truthy(count >= 40, "fixture count reported")
		t.eq(#modelsIn(child(again[GYM], LockerBuilder.Folder)), 45, "rebuild replaces, never duplicates")
		local folders = 0
		for _, c in again[GYM]:GetChildren() do
			if c.Name == LockerBuilder.Folder then
				folders += 1
			end
		end
		t.eq(folders, 1, "one locker folder after a rebuild")
		-- Levels without the anchors build none of these kinds.
		for _, id in LEVELS do
			for _, folderName in { LockerBuilder.Folder, FloodlightSwitchBuilder.Folder, ParachuteBuilder.Folder } do
				local expected = (id == GYM and folderName == LockerBuilder.Folder)
					or (id == POOL and folderName == FloodlightSwitchBuilder.Folder)
					or (id == ROOF and folderName == ParachuteBuilder.Folder)
				t.eq(first[id]:FindFirstChild(folderName) ~= nil, expected, id .. " " .. folderName)
			end
		end
		for _, set in { first, again, other } do
			for _, folder in set do
				folder:Destroy()
			end
		end
	end,

	["props are pure procedural parts with no lights beyond the switch glow"] = function(t: Expect)
		local roots: { Instance } = {}
		for _, id in LEVELS do
			for _, folder in ownFolders(world().runtime[id]) do
				table.insert(roots, folder)
			end
		end
		t.eq(#roots, 3, "a locker, a switch and a crate folder")
		local host = Instance.new("Folder")
		local backpack = Builder.BuildRig(ParachuteBuilder.BackpackRig, host, CFrame.new())
		local canopy = Builder.BuildRig(ParachuteBuilder.CanopyRig, host, CFrame.new())
		t.truthy(backpack and canopy, "rigs built")
		table.insert(roots, host)
		local lights = 0
		for _, root in roots do
			for _, d in root:GetDescendants() do
				t.falsy(table.find(FORBIDDEN_CLASSES, d.ClassName), d:GetFullName() .. " is a " .. d.ClassName)
				if d:IsA("Light") then
					lights += 1
				end
				if d:IsA("BasePart") then
					t.truthy(d.Anchored, d:GetFullName() .. " anchored")
				end
				if d:IsA("TextLabel") then
					t.truthy(string.sub(d.Text, 1, 5) ~= "Prop.", d:GetFullName() .. " text resolved from Strings")
				end
			end
		end
		t.eq(lights, 1, "the switch's glow is the only light")
		host:Destroy()
	end,
}
