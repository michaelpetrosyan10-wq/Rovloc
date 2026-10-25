--!strict
-- ProceduralWorldBuilder geometry contracts, checked on small synthetic layouts (and on the real layouts when
-- they are present): openings stay clear, wall pieces tile every wall exactly once, gameplay volumes and anchors
-- carry the right tags and attributes, stairs are climbable, and stacked stair segments never overlap.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local LightingRig = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LightingRig)
local LobbyBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LobbyBuilder)
local Palette = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Palette)
local SchoolShellBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.SchoolShellBuilder)
local SkylineBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.SkylineBuilder)
local StairwellBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.StairwellBuilder)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Layout = LayoutSchema.LevelLayout

local W = Attributes.World
local R = LayoutSchema.rect

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

local function overlapVolume(aMin: Vector3, aMax: Vector3, bMin: Vector3, bMax: Vector3): number
	local dx = math.min(aMax.X, bMax.X) - math.max(aMin.X, bMin.X)
	local dy = math.min(aMax.Y, bMax.Y) - math.max(aMin.Y, bMin.Y)
	local dz = math.min(aMax.Z, bMax.Z) - math.max(aMin.Z, bMin.Z)
	if dx <= 0 or dy <= 0 or dz <= 0 then
		return 0
	end
	return dx * dy * dz
end

local function contains(part: BasePart, point: Vector3): boolean
	local lo, hi = aabb(part)
	local e = 1e-4
	return point.X > lo.X + e
		and point.X < hi.X - e
		and point.Y > lo.Y + e
		and point.Y < hi.Y - e
		and point.Z > lo.Z + e
		and point.Z < hi.Z - e
end

local function parts(root: Instance, predicate: ((BasePart) -> boolean)?): { BasePart }
	local out: { BasePart } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and (predicate == nil or predicate(d)) then
			table.insert(out, d)
		end
	end
	return out
end

-- Attachment world CFrame computed from its parent part (Lune does not derive WorldCFrame).
local function worldCFrame(attachment: Attachment): CFrame
	local parent = attachment.Parent
	assert(parent and parent:IsA("BasePart"), "attachment parent is a part")
	return parent.CFrame * attachment.CFrame
end

local function isWall(part: BasePart): boolean
	return string.sub(part.Name, 1, 4) == "Wall"
end

local function child(parent: Instance, name: string): Instance
	local found = parent:FindFirstChild(name)
	assert(found, string.format("%s has no child %s", parent:GetFullName(), name))
	return found
end

local function childPart(parent: Instance, name: string): BasePart
	local found = child(parent, name)
	assert(found:IsA("BasePart"), name .. " is not a BasePart")
	return found
end

local function isVolume(part: BasePart): boolean
	return part.Transparency == 1
		and part.Anchored
		and not part.CanCollide
		and not part.CanQuery
		and not part.CanTouch
		and not part.CastShadow
		and part.CollisionGroup == CollisionGroups.NoCollide
end

--------------------------------------------------------------------------------
-- Synthetic layouts
--------------------------------------------------------------------------------

-- A slice of the east end of a hallway floor: classroom, chase, corridor, the east airlock (tower opening),
-- an office and a storage strip. Doors of five kinds, one vent with two grates, windows, triggers, lights.
local function hallwaySlice(): Layout
	local classLights: { LayoutSchema.Light } = {
		{ id = "T_L2", kind = "ClassroomGlow", pos = Vector3.new(214, 12, 48), brightness = 2, range = 80 },
	}
	local hallLights: { LayoutSchema.Light } = {
		{
			id = "T_L1",
			kind = "Fluorescent",
			pos = Vector3.new(214, 14, 80),
			brightness = 1.2,
			range = 40,
			flickerGroup = "HallA",
		},
	}
	local airlockLights: { LayoutSchema.Light } = {
		{
			id = "T_L3",
			kind = "EmergencyRed",
			pos = Vector3.new(234, 9, 70),
			brightness = 1,
			range = 20,
			broken = true,
		},
	}
	local windows: { LayoutSchema.Window } = {
		{ room = "T_Class", side = "W", at = 48, width = 6, height = 4, sill = 4, boarded = true },
		{ room = "T_Store", side = "S", at = 210, width = 5, height = 3, sill = 5, boarded = false },
	}
	return {
		id = "Level1_Hallways",
		height = 14,
		acoustic = "Corridor",
		ambience = "DroneHallways",
		entry = "L1_AirlockEast",
		exit = "T_Class",
		rooms = {
			{
				id = "T_Class",
				kind = "Classroom",
				rect = R(200, 36, 28, 25),
				height = 12,
				acoustic = "Room",
				lights = classLights,
			},
			{ id = "T_Chase", kind = "Chase", rect = R(200, 61, 28, 5) },
			{
				id = "T_Hall",
				kind = "Corridor",
				rect = R(200, 66, 28, 28),
				lights = hallLights,
			},
			{
				id = "L1_AirlockEast",
				kind = "Airlock",
				rect = R(228, 66, 12, 28),
				lights = airlockLights,
			},
			{ id = "T_Store", kind = "Storage", rect = R(200, 94, 40, 10) },
			{ id = "T_Office", kind = "Office", rect = R(228, 36, 12, 30) },
		},
		doors = {
			{ id = "T_HallAirlock", kind = "Airlock", rooms = { "T_Hall", "L1_AirlockEast" }, at = 80 },
			{ id = "T_HallStore", kind = "Door", rooms = { "T_Hall", "T_Store" }, at = 214 },
			{ id = "T_StoreAirlock", kind = "Boarded", rooms = { "T_Store", "L1_AirlockEast" }, at = 234 },
			{
				id = "T_ClassOffice",
				kind = "Ajar",
				rooms = { "T_Class", "T_Office" },
				at = 48,
				scriptedId = "ClassroomDoor",
			},
			{
				id = "T_OfficeAirlock",
				kind = "Gate",
				rooms = { "T_Office", "L1_AirlockEast" },
				at = 234,
				scriptedId = "HallwayGate",
			},
		},
		vents = {
			nodes = {
				{ id = "g1", x = 214, z = 66 },
				{ id = "n1", x = 214, z = 63.5 },
				{ id = "n2", x = 222, z = 63.5 },
				{ id = "g2", x = 222, z = 61 },
			},
			edges = { { a = "g1", b = "n1" }, { a = "n1", b = "n2" }, { a = "n2", b = "g2" } },
			grates = {
				{ id = "G1", node = "g1", room = "T_Hall", lockable = false, criticalPath = true },
				{ id = "G2", node = "g2", room = "T_Class", lockable = true, criticalPath = false },
			},
		},
		anchors = {
			{ id = "T_Spawn1", kind = "PlayerSpawn", room = "T_Hall", pos = Vector3.new(210, 0, 80), yaw = 90 },
			{ id = "T_Way1", kind = "PatrolWaypoint", room = "T_Hall", pos = Vector3.new(220, 0, 70) },
			{ id = "T_Creature", kind = "CreatureSpawn", room = "T_Store", pos = Vector3.new(230, 0, 99) },
			{ id = "T_Battery", kind = "BatteryCandidate", room = "T_Class", pos = Vector3.new(205, 0, 40) },
		},
		triggers = {
			{ id = "T_Scare", kind = "ScareStep", room = "T_Hall", rect = R(204, 70, 4, 4), height = 6 },
			{ id = "T_Check", kind = "Checkpoint", room = "L1_AirlockEast", rect = R(229, 67, 10, 26), height = 10 },
		},
		windows = windows,
	}
end

local function poolSlice(): Layout
	local windows: { LayoutSchema.Window } = {
		{ room = "P_Hall", side = "W", at = 20, width = 6, height = 6, sill = 8, boarded = true },
	}
	return {
		id = "Level4_FloodedPool",
		height = 28,
		acoustic = "Hall",
		ambience = "DronePool",
		entry = "P_Hall",
		exit = "P_Hall",
		rooms = { { id = "P_Hall", kind = "Pool", rect = R(0, 0, 40, 40) } },
		doors = {},
		anchors = {},
		triggers = {},
		basins = { { id = "P_Basin", room = "P_Hall", rect = R(5, 5, 30, 30), depth = 10, waterLevel = -1 } },
		platforms = {
			{
				id = "P_Walk",
				room = "P_Hall",
				rect = R(10, 18, 20, 4),
				top = -0.5,
				thickness = 1,
				material = "Concrete",
			},
		},
		pillars = { { room = "P_Hall", x = 2.5, z = 2.5, size = 2 } },
		windows = windows,
	}
end

local function lobbySlice(): Layout
	return {
		id = "Lobby",
		height = 16,
		acoustic = "Lobby",
		ambience = "DroneLobby",
		entry = "LB_Bay",
		exit = "LB_Bay",
		rooms = {
			{ id = "LB_Boiler", kind = "Boiler", rect = R(0, 0, 40, 30) },
			{ id = "LB_Bay", kind = "LobbyHall", rect = R(40, 0, 60, 30) },
		},
		doors = { { id = "LB_Door", kind = "Doorway", rooms = { "LB_Boiler", "LB_Bay" }, at = 15 } },
		anchors = {
			{ id = "Pad1", kind = "ReadyPad", room = "LB_Bay", pos = Vector3.new(64, 0, 13) },
			{ id = "Pad2", kind = "ReadyPad", room = "LB_Bay", pos = Vector3.new(64, 0, 17) },
			{ id = "Pad3", kind = "ReadyPad", room = "LB_Bay", pos = Vector3.new(72, 0, 13) },
			{ id = "Pad4", kind = "ReadyPad", room = "LB_Bay", pos = Vector3.new(72, 0, 17) },
			{ id = "TermA", kind = "Terminal", room = "LB_Bay", pos = Vector3.new(92, 0, 26), yaw = 180 },
			{ id = "SpawnA", kind = "PlayerSpawn", room = "LB_Bay", pos = Vector3.new(50, 0, 6) },
		},
		triggers = {},
	}
end

local function buildSlice(layout: Layout): Model
	Geometry.setYieldEvery(0)
	local root = SchoolShellBuilder.createRoot(layout)
	SchoolShellBuilder.buildLevel(layout, root, SchoolShellBuilder.levelOptions(layout.id))
	return root
end

-- World-space box of an opening cut into a wall line, shrunk slightly so touching faces don't count.
local function openingBox(
	layoutId: string,
	axis: "X" | "Z",
	coord: number,
	thickness: number,
	u0: number,
	u1: number,
	y0: number,
	y1: number
): (Vector3, Vector3)
	local o = WorldConfig.levelOrigin(layoutId)
	local s = 0.01
	if axis == "X" then
		return o + Vector3.new(coord - thickness / 2 + s, y0 + s, u0 + s),
			o + Vector3.new(coord + thickness / 2 - s, y1 - s, u1 - s)
	end
	return o + Vector3.new(u0 + s, y0 + s, coord - thickness / 2 + s),
		o + Vector3.new(u1 - s, y1 - s, coord + thickness / 2 - s)
end

local function clearOfWalls(t: Expect, shell: Instance, lo: Vector3, hi: Vector3, label: string)
	for _, part in parts(shell, isWall) do
		local a, b = aabb(part)
		t.eq(overlapVolume(a, b, lo, hi), 0, label .. " blocked by " .. part.Name)
	end
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["palette implements every layout key and falls back to Concrete"] = function(t: Expect)
		local required = {
			"Concrete",
			"ConcreteDark",
			"ConcreteStained",
			"TileWhite",
			"TileGreen",
			"TileBlue",
			"Linoleum",
			"WoodGym",
			"WoodPanel",
			"PlasterSchool",
			"PlasterGreen",
			"Brick",
			"MetalRust",
			"MetalGalvanized",
			"RoofGravel",
			"Asphalt",
			"PoolTile",
			"Carpet",
			"Lab",
		}
		for _, key in required do
			t.truthy(Palette.has(key), "missing palette key " .. key)
			t.truthy(Enums.has(Enums.SurfaceKind, Palette.get(key).surface), key .. " surface")
		end
		t.eq(Palette.get("NoSuchKey"), Palette.get("Concrete"))
		t.eq(Palette.get(nil), Palette.get("Concrete"))
	end,

	["subtractRects leaves the exact remainder as disjoint pieces"] = function(t: Expect)
		local base = R(0, 0, 40, 30)
		local holes = { R(5, 5, 10, 10), R(12, 8, 10, 30), R(-5, -5, 8, 8) }
		local pieces = Geometry.subtractRects(base, holes)
		local area = 0
		for i, a in pieces do
			area += a.w * a.d
			for _, hole in holes do
				t.eq(LayoutSchema.rectOverlapArea(a, hole), 0, "piece overlaps a hole")
			end
			for j = i + 1, #pieces do
				t.eq(LayoutSchema.rectOverlapArea(a, pieces[j]), 0, "pieces overlap")
			end
		end
		-- holes: 100 + (10 x 22 inside, minus the 3 x 7 shared with hole 1) + 3 x 3 = 100 + 199 + 9
		t.near(area, 40 * 30 - 308, 1e-6)
	end,

	["splitWall covers the wall exactly once and leaves every opening clear"] = function(t: Expect)
		local openings: { Geometry.Opening } = {
			{ u0 = 3, u1 = 9, y0 = 0, y1 = 10 },
			{ u0 = 14, u1 = 17.5, y0 = 0.25, y1 = 3.75 },
			{ u0 = 15, u1 = 21, y0 = 5, y1 = 9 },
			{ u0 = 28, u1 = 34, y0 = 2, y1 = 6 },
		}
		local boxes = Geometry.splitWall(0, 30, 0, 14, openings)
		local u = 0.13
		while u < 30 do
			local y = 0.11
			while y < 14 do
				local inOpening = false
				for _, o in openings do
					if u > o.u0 and u < o.u1 and y > o.y0 and y < o.y1 then
						inOpening = true
					end
				end
				local hits = 0
				for _, box in boxes do
					if u > box.u0 and u < box.u1 and y > box.y0 and y < box.y1 then
						hits += 1
					end
				end
				t.eq(hits, if inOpening then 0 else 1, string.format("coverage at u=%.2f y=%.2f", u, y))
				y += 0.37
			end
			u += 0.29
		end
		t.eq(#Geometry.splitWall(0, 10, 0, 14, { { u0 = 2, u1 = 8, y0 = 0, y1 = 10 } }), 3, "a door gives 3 boxes")
	end,

	["junctions tile L, T and cross squares once, with fillers for taller arms"] = function(t: Expect)
		-- A plus-shaped pair of runs split at the centre (like four rooms meeting) plus an L corner and a T.
		local segments: { Geometry.WallSegment } = {
			{ axis = "Z", coord = 10, from = 0, to = 10, thickness = 1, height = 10, start = 0, finish = 0 },
			{ axis = "Z", coord = 10, from = 10, to = 20, thickness = 1, height = 10, start = 0, finish = 0 },
			{ axis = "X", coord = 10, from = 0, to = 10, thickness = 1, height = 14, start = 0, finish = 0 },
			{ axis = "X", coord = 10, from = 10, to = 20, thickness = 1, height = 10, start = 0, finish = 0 },
			{ axis = "Z", coord = 0, from = 0, to = 10, thickness = 1.5, height = 10, start = 0, finish = 0 },
			{ axis = "X", coord = 0, from = 0, to = 10, thickness = 1.5, height = 10, start = 0, finish = 0 },
		}
		local fillers = Geometry.resolveJunctions(segments)
		local function solidAt(x: number, y: number, z: number): number
			local hits = 0
			for _, s in segments do
				local half = s.thickness / 2
				local inside = if s.axis == "X"
					then x > s.coord - half and x < s.coord + half and z > s.start and z < s.finish
					else z > s.coord - half and z < s.coord + half and x > s.start and x < s.finish
				if inside and y > 0 and y < s.height then
					hits += 1
				end
			end
			for _, f in fillers do
				if x > f.x0 and x < f.x1 and z > f.z0 and z < f.z1 and y > f.y0 and y < f.y1 then
					hits += 1
				end
			end
			return hits
		end
		-- Cross at (10, 10): the junction square is solid exactly once, up to the tall arm's height (the tall wall
		-- ends flush with the far face of the cross wall); the short arm beyond it stays short.
		for _, p in { Vector2.new(9.7, 9.7), Vector2.new(10.3, 10.3), Vector2.new(9.7, 10.3), Vector2.new(10.3, 9.7) } do
			t.eq(solidAt(p.X, 5, p.Y), 1, "cross square at y=5")
			t.eq(solidAt(p.X, 12, p.Y), 1, "cross square at y=12 (filler)")
		end
		t.eq(solidAt(10, 12, 8.5), 1, "tall arm")
		t.eq(solidAt(10, 12, 11.5), 0, "short arm stays short")
		t.eq(solidAt(10, 15, 9.7), 0, "nothing above the tallest arm")
		-- L corner at (0, 0): the outer corner square is covered once.
		for _, p in { Vector2.new(-0.6, -0.6), Vector2.new(0.6, 0.6), Vector2.new(-0.6, 0.6), Vector2.new(0.6, -0.6) } do
			t.eq(solidAt(p.X, 5, p.Y), 1, string.format("L corner (%.1f, %.1f)", p.X, p.Y))
		end
		-- T at (10, 0) and (0, 10): stems stop at the run's faces; the run stays continuous.
		t.eq(solidAt(10, 5, 0.3), 1, "T stem/run at (10, 0.3)")
		t.eq(solidAt(10, 5, -0.6), 1, "T run outer face")
		t.eq(solidAt(0.3, 5, 10), 1, "T stem/run at (0.3, 10)")
		-- Openings must stay out of junction squares: each end reports the square's half-extent.
		t.near(segments[1].finishMargin or 0, 0.5, 1e-6, "W arm at the cross")
		t.near(segments[1].startMargin or 0, 0.75, 1e-6, "E arm at the exterior T")
		t.near(segments[6].startMargin or 0, 0.75, 1e-6, "exterior corner")
	end,

	["walls leave door, grate, tower and window openings clear"] = function(t: Expect)
		local layout = hallwaySlice()
		local root = buildSlice(layout)
		local shell = child(root, "Shell")
		local id = layout.id
		local wt, et = WorldConfig.WallThickness, WorldConfig.ExteriorWallThickness
		local lo, hi = openingBox(id, "X", 228, wt, 76, 84, 0, 10)
		clearOfWalls(t, shell, lo, hi, "airlock door")
		lo, hi = openingBox(id, "Z", 94, wt, 211, 217, 0, 10)
		clearOfWalls(t, shell, lo, hi, "storage door")
		lo, hi = openingBox(id, "X", 228, wt, 45, 51, 0, 10)
		clearOfWalls(t, shell, lo, hi, "ajar classroom door")
		lo, hi = openingBox(id, "Z", 66, wt, 214 - 1.75, 214 + 1.75, 0.25, 3.75)
		clearOfWalls(t, shell, lo, hi, "corridor grate")
		lo, hi = openingBox(id, "Z", 61, wt, 222 - 1.75, 222 + 1.75, 0.25, 3.75)
		clearOfWalls(t, shell, lo, hi, "classroom grate")
		local opening = WorldConfig.TowerOpening
		lo, hi = openingBox(
			id,
			"X",
			240,
			et,
			opening.centerZ - opening.width / 2,
			opening.centerZ + opening.width / 2,
			0,
			opening.height
		)
		clearOfWalls(t, shell, lo, hi, "tower opening")
		lo, hi = openingBox(id, "X", 200, et, 45, 51, 4, 8)
		clearOfWalls(t, shell, lo, hi, "boarded window")
		-- ... and the wall is really there around them (lintel above the airlock door, sill under the grate)
		local origin = WorldConfig.levelOrigin(id)
		local function solid(point: Vector3): boolean
			for _, part in parts(shell, isWall) do
				if contains(part, origin + point) then
					return true
				end
			end
			return false
		end
		t.truthy(solid(Vector3.new(228.2, 12, 80)), "lintel above the airlock door")
		t.truthy(solid(Vector3.new(214, 6, 66.2)), "wall above the corridor grate")
		t.truthy(solid(Vector3.new(239.6, 12, 80)), "wall above the tower opening")
		t.truthy(solid(Vector3.new(214, 0.1, 65.8)), "sill under the corridor grate")
		root:Destroy()
	end,

	["wall pieces tile every room edge exactly once outside openings"] = function(t: Expect)
		local layout = hallwaySlice()
		local root = buildSlice(layout)
		local walls = parts(child(root, "Shell"), isWall)
		local origin = WorldConfig.levelOrigin(layout.id)
		local options = SchoolShellBuilder.levelOptions(layout.id)
		local exterior = SchoolShellBuilder.exteriorSides(layout)
		local rooms = LayoutSchema.indexRooms(layout)
		-- Openings per wall line, from the layout itself.
		type Hole = { axis: "X" | "Z", coord: number, u0: number, u1: number, y0: number, y1: number }
		local holes: { Hole } = {}
		for _, door in layout.doors do
			local edge = LayoutSchema.sharedEdge(rooms[door.rooms[1]].rect, rooms[door.rooms[2]].rect)
			assert(edge, "door edge")
			local half = LayoutSchema.doorWidth(door) / 2
			table.insert(holes, {
				axis = edge.axis,
				coord = edge.coord,
				u0 = door.at - half,
				u1 = door.at + half,
				y0 = 0,
				y1 = LayoutSchema.doorHeight(door),
			})
		end
		table.insert(holes, { axis = "Z", coord = 66, u0 = 212.25, u1 = 215.75, y0 = 0.25, y1 = 3.75 })
		table.insert(holes, { axis = "Z", coord = 61, u0 = 220.25, u1 = 223.75, y0 = 0.25, y1 = 3.75 })
		table.insert(holes, { axis = "X", coord = 240, u0 = 77, u1 = 83, y0 = 0, y1 = 10 })
		table.insert(holes, { axis = "X", coord = 200, u0 = 45, u1 = 51, y0 = 4, y1 = 8 })
		table.insert(holes, { axis = "Z", coord = 104, u0 = 207.5, u1 = 212.5, y0 = 5, y1 = 8 })
		local checked = 0
		for _, room in layout.rooms do
			local r = room.rect
			local sides: { { any } } = {
				{ "N", "Z", r.z, r.x, r.x + r.w },
				{ "S", "Z", r.z + r.d, r.x, r.x + r.w },
				{ "W", "X", r.x, r.z, r.z + r.d },
				{ "E", "X", r.x + r.w, r.z, r.z + r.d },
			}
			for _, side in sides do
				local name, axis, coord, from, to = side[1], side[2], side[3], side[4], side[5]
				local isExterior = exterior[room.id][name]
				local thickness = if isExterior then WorldConfig.ExteriorWallThickness else WorldConfig.WallThickness
				local top = if isExterior then (options.facadeTop or 14) else 14
				local u = from + 0.26
				while u < to - 0.2 do
					local y = 0.3
					while y < top - 0.2 do
						local inHole = false
						for _, h in holes do
							if
								h.axis == axis
								and math.abs(h.coord - coord) < 1e-3
								and u > h.u0
								and u < h.u1
								and y > h.y0
								and y < h.y1
							then
								inHole = true
							end
						end
						for _, a in { -(thickness / 2 - 0.1), thickness / 2 - 0.1 } do
							local point = if axis == "X"
								then origin + Vector3.new(coord + a, y, u)
								else origin + Vector3.new(u, y, coord + a)
							local hits = 0
							for _, wall in walls do
								if contains(wall, point) then
									hits += 1
								end
							end
							t.eq(
								hits,
								if inHole then 0 else 1,
								string.format("%s %s side at u=%.2f y=%.2f a=%.2f", room.id, name, u, y, a)
							)
							checked += 1
						end
						y += 0.5
					end
					u += 0.5
				end
			end
		end
		t.truthy(checked > 1000, "sampled the walls")
		-- Pairwise: no two wall pieces overlap.
		for i = 1, #walls do
			local a0, a1 = aabb(walls[i])
			for j = i + 1, #walls do
				local b0, b1 = aabb(walls[j])
				t.truthy(overlapVolume(a0, a1, b0, b1) < 1e-6, walls[i].Name .. " overlaps " .. walls[j].Name)
			end
		end
		root:Destroy()
	end,

	["door trims are monster passthrough; gates and airlocks stay clear; boards block"] = function(t: Expect)
		local layout = hallwaySlice()
		local root = buildSlice(layout)
		local shell = child(root, "Shell")
		for _, doorId in { "T_HallStore", "T_ClassOffice" } do
			for i = 1, 3 do
				local trim = childPart(shell, string.format("Door_%s_Trim%d", doorId, i))
				t.eq(trim.CollisionGroup, CollisionGroups.MonsterPassthrough, trim.Name)
				t.truthy(trim:HasTag(Tags.MonsterPassthrough), trim.Name .. " tag")
				local modifier = trim:FindFirstChildOfClass("PathfindingModifier")
				t.truthy(modifier and modifier.PassThrough, trim.Name .. " pathfinding modifier")
			end
		end
		t.falsy(shell:FindFirstChild("Door_T_HallAirlock_Trim1"), "airlock opening has no passthrough trim")
		t.falsy(shell:FindFirstChild("Door_T_OfficeAirlock_Trim1"), "gate opening has no passthrough trim")
		-- Boarded door: planks on the storage side, gaps too small to pass, from the floor to the head.
		local spans: { { number } } = {}
		for _, part in parts(shell) do
			if string.sub(part.Name, 1, 21) == "Boards_T_StoreAirlock" and string.find(part.Name, "Plank") then
				t.eq(part.CollisionGroup, "Default", "planks really block")
				t.truthy(part.CanCollide, "planks collide")
				local lo, hi = aabb(part)
				table.insert(spans, { lo.Y, hi.Y })
			end
		end
		t.truthy(#spans >= 6, "enough planks")
		table.sort(spans, function(a: { number }, b: { number }): boolean
			return a[1] < b[1]
		end)
		local origin = WorldConfig.levelOrigin(layout.id)
		t.truthy(spans[1][1] - origin.Y < 0.6, "lowest plank near the floor")
		local reach = spans[1][2]
		for i = 2, #spans do
			t.truthy(spans[i][1] - reach < 0.6, "gap between planks too small to squeeze through")
			reach = math.max(reach, spans[i][2])
		end
		t.truthy(reach - origin.Y > LayoutSchema.doorHeight(layout.doors[3]) - 0.6, "planks reach the head")
		root:Destroy()
	end,

	["zones, triggers and pool volumes carry ids, tags and attributes"] = function(t: Expect)
		local layout = hallwaySlice()
		local root = buildSlice(layout)
		local zones = child(root, "Zones")
		t.eq(#zones:GetChildren(), #layout.rooms, "one zone per room")
		local hall = childPart(zones, "T_Hall")
		t.truthy(isVolume(hall), "zone is an invisible NoCollide volume")
		t.truthy(hall:HasTag(Tags.Zone))
		t.eq(hall:GetAttribute(W.ZoneId), "T_Hall")
		t.eq(hall:GetAttribute(W.LevelId), "Level1_Hallways")
		t.eq(hall:GetAttribute(W.RoomKind), "Corridor")
		t.eq(hall:GetAttribute(W.AcousticPreset), "Corridor", "falls back to the layout acoustic")
		t.eq(hall:GetAttribute(W.Surface), "Tile", "linoleum floor is a tile surface")
		t.eq(childPart(zones, "T_Class"):GetAttribute(W.AcousticPreset), "Room")
		local origin = WorldConfig.levelOrigin(layout.id)
		t.near(hall.CFrame.Position.Y, origin.Y + 7, 1e-3, "zone spans the room height")
		t.near(hall.Size.X, 28, 1e-3)

		local triggers = child(root, "Triggers")
		local scare = childPart(triggers, "T_Scare")
		t.truthy(isVolume(scare))
		t.truthy(scare:HasTag(Tags.ScareTrigger))
		t.eq(scare:GetAttribute(W.TriggerKind), "ScareStep")
		t.eq(scare:GetAttribute(W.ZoneId), "T_Hall")
		t.truthy(childPart(triggers, "T_Check"):HasTag(Tags.CheckpointVolume))
		root:Destroy()

		local pool = poolSlice()
		local poolRoot = buildSlice(pool)
		local poolOrigin = WorldConfig.levelOrigin(pool.id)
		local water = childPart(child(poolRoot, "Triggers"), "P_Basin")
		t.truthy(water:HasTag(Tags.PoolWater))
		t.truthy(isVolume(water))
		t.eq(water:GetAttribute(W.TriggerKind), "PoolWater")
		t.eq(water:GetAttribute(W.ZoneId), "P_Hall")
		t.near(water.Size.Y, 9, 1e-3, "water from the basin floor to the surface")
		t.near(water.CFrame.Position.Y, poolOrigin.Y - 5.5, 1e-3)
		local poolZone = childPart(child(poolRoot, "Zones"), "P_Hall")
		local zLo = aabb(poolZone)
		t.near(zLo.Y, poolOrigin.Y - 10, 1e-3, "pool zone reaches the basin floor")
		poolRoot:Destroy()
	end,

	["basins carve the pool deck; platforms, pillars and the surface are built"] = function(t: Expect)
		local pool = poolSlice()
		local root = buildSlice(pool)
		local shell = child(root, "Shell")
		local origin = WorldConfig.levelOrigin(pool.id)
		local basinLo = origin + Vector3.new(5.01, -1.99, 5.01)
		local basinHi = origin + Vector3.new(34.99, -0.01, 34.99)
		local floors = 0
		for _, part in parts(shell) do
			if string.sub(part.Name, 1, 6) == "Floor_" then
				floors += 1
				local a, b = aabb(part)
				t.eq(overlapVolume(a, b, basinLo, basinHi), 0, part.Name .. " covers the basin")
			end
		end
		t.truthy(floors >= 4, "deck split around the basin")
		local basinFloor = childPart(shell, "P_Basin_Floor")
		local _, top = aabb(basinFloor)
		t.near(top.Y, origin.Y - 10, 1e-3, "basin floor at depth")
		for i = 1, 4 do
			childPart(shell, "P_Basin_Wall" .. i)
		end
		local surface = childPart(shell, "P_Basin_Surface")
		t.falsy(surface.CanCollide)
		t.eq(surface.CollisionGroup, CollisionGroups.NoCollide)
		t.near(surface.Transparency, 0.25, 1e-3)
		local _, walkTop = aabb(childPart(shell, "Platform_P_Walk"))
		t.near(walkTop.Y, origin.Y - 0.5, 1e-3, "platform top")
		t.eq(childPart(shell, "Pillar_1").CollisionGroup, "Default", "pillar core blocks")
		t.eq(childPart(shell, "Pillar_1_Trim1").CollisionGroup, CollisionGroups.MonsterPassthrough)
		root:Destroy()
	end,

	["anchors, waypoints, spawns and door anchors"] = function(t: Expect)
		local layout = hallwaySlice()
		local root = buildSlice(layout)
		local origin = WorldConfig.levelOrigin(layout.id)
		local anchorRoot = childPart(child(root, "Anchors"), "AnchorRoot")
		t.truthy(isVolume(anchorRoot), "AnchorRoot is invisible and NoCollide")
		t.eq(anchorRoot.Size, Vector3.new(1, 1, 1))
		t.truthy((anchorRoot.CFrame.Position - origin).Magnitude < 1e-4, "AnchorRoot at the level origin")
		t.truthy(anchorRoot.CFrame.LookVector:FuzzyEq(Vector3.new(0, 0, -1), 1e-4), "identity rotation")

		local spawn = child(anchorRoot, "T_Spawn1")
		assert(spawn:IsA("Attachment"))
		t.eq(spawn:GetAttribute(W.AnchorId), "T_Spawn1")
		t.eq(spawn:GetAttribute(W.AnchorKind), "PlayerSpawn")
		t.eq(spawn:GetAttribute(W.LevelId), "Level1_Hallways")
		t.truthy(spawn:HasTag(Tags.SpawnAnchor))
		t.truthy(worldCFrame(spawn).Position:FuzzyEq(origin + Vector3.new(210, 0, 80), 1e-3), "spawn position")
		t.truthy(worldCFrame(spawn).LookVector:FuzzyEq(Vector3.new(-1, 0, 0), 1e-3), "yaw 90 looks down -X")
		local expected = Builder.anchorCFrame(layout.id, layout.anchors[1])
		t.truthy(worldCFrame(spawn).Position:FuzzyEq(expected.Position, 1e-3), "anchorCFrame matches")
		t.truthy(child(anchorRoot, "T_Creature"):HasTag(Tags.SpawnAnchor))
		t.falsy(child(anchorRoot, "T_Battery"):HasTag(Tags.SpawnAnchor))

		local waypointRoot = childPart(child(root, "Waypoints"), "WaypointRoot")
		local waypoint = child(waypointRoot, "T_Way1")
		t.truthy(waypoint:HasTag(Tags.PatrolWaypoint))
		t.falsy(anchorRoot:FindFirstChild("T_Way1"), "waypoints live under WaypointRoot")

		local airlock = child(anchorRoot, "Door_T_HallAirlock")
		assert(airlock:IsA("Attachment"))
		t.eq(airlock:GetAttribute(W.DoorKind), "Airlock")
		t.eq(airlock:GetAttribute(W.DoorWidth), WorldConfig.AirlockDoorWidth)
		t.eq(airlock:GetAttribute(W.DoorHeight), WorldConfig.DoorHeight)
		t.truthy(worldCFrame(airlock).Position:FuzzyEq(origin + Vector3.new(228, 0, 80), 1e-3), "bottom centre")
		t.truthy(worldCFrame(airlock).LookVector:FuzzyEq(Vector3.new(1, 0, 0), 1e-3), "rooms[1] -> rooms[2]")
		local gate = child(anchorRoot, "Door_T_OfficeAirlock")
		t.eq(gate:GetAttribute(W.ScriptedId), "HallwayGate")
		assert(gate:IsA("Attachment"))
		t.truthy(worldCFrame(gate).LookVector:FuzzyEq(Vector3.new(0, 0, 1), 1e-3), "office -> airlock is +Z")
		t.eq(child(anchorRoot, "Door_T_ClassOffice"):GetAttribute(W.ScriptedId), "ClassroomDoor")
		child(anchorRoot, "Door_T_HallStore")
		t.falsy(anchorRoot:FindFirstChild("Door_T_StoreAirlock"), "boarded doors get no anchor")
		root:Destroy()
	end,

	["lights: tagged fixtures, kinds, broken lights dark, range clamped"] = function(t: Expect)
		local layout = hallwaySlice()
		local root = buildSlice(layout)
		local lights = child(root, "Lights")
		local fluorescent = childPart(lights, "T_L1")
		t.truthy(fluorescent:HasTag(Tags.LevelLight))
		t.falsy(fluorescent.CanCollide)
		t.falsy(fluorescent.CastShadow)
		t.eq(fluorescent.CollisionGroup, CollisionGroups.NoCollide)
		t.eq(fluorescent:GetAttribute(W.LightKind), "Fluorescent")
		t.eq(fluorescent:GetAttribute(W.LevelId), "Level1_Hallways")
		t.eq(fluorescent:GetAttribute(W.ZoneId), "T_Hall")
		t.eq(fluorescent:GetAttribute(W.FlickerGroup), "HallA")
		t.near(fluorescent:GetAttribute(W.BaseBrightness) :: number, 1.2, 1e-6)
		local surface = fluorescent:FindFirstChildOfClass("SurfaceLight")
		assert(surface, "fluorescent has a SurfaceLight")
		t.eq(surface.Face, Enum.NormalId.Bottom)
		t.falsy(surface.Shadows)
		local origin = WorldConfig.levelOrigin(layout.id)
		local _, fixtureTop = aabb(fluorescent)
		t.truthy(fixtureTop.Y <= origin.Y + 14 - SchoolShellBuilder.CeilingThickness + 1e-3, "under the ceiling")

		local glow = childPart(lights, "T_L2")
		local spot = glow:FindFirstChildOfClass("SpotLight")
		assert(spot, "classroom glow has a SpotLight")
		t.truthy(glow:FindFirstChildOfClass("PointLight") ~= nil, "and a pale PointLight")
		t.truthy(spot.Range <= 60, "range clamped to 60")

		local broken = childPart(lights, "T_L3")
		local point = broken:FindFirstChildOfClass("PointLight")
		assert(point, "emergency light has a PointLight")
		t.falsy(point.Enabled, "broken light disabled")
		t.eq(point.Brightness, 0)
		t.eq(broken:GetAttribute(W.BaseBrightness), 0)
		t.near(broken.Transparency, 0, 1e-6, "fixture still visible")
		root:Destroy()
	end,

	["stair plan: climbable steps, even switchbacks, segments stack contiguously"] = function(t: Expect)
		local plans = StairwellBuilder.plan({})
		t.eq(#plans, #WorldConfig.Stairwells)
		for _, plan in plans do
			t.truthy(plan.stepRise <= 1 + 1e-6, plan.spec.id .. " rise")
			t.truthy(plan.stepRun >= 1.6 - 1e-6, plan.spec.id .. " run")
			t.eq(plan.flights % 2, 0, plan.spec.id .. " ends beside the building")
			t.near(plan.flights * plan.risers * plan.stepRise, plan.rise, 1e-6, plan.spec.id .. " total rise")
			t.truthy(plan.top > plan.bottom + plan.rise, plan.spec.id .. " shaft reaches the upper ceiling")
		end
		for _, a in plans do
			for _, b in plans do
				if a ~= b and a.spec.tower == b.spec.tower and b.bottom > a.bottom then
					t.truthy(b.bottom - WorldConfig.SlabThickness >= a.top - 1e-6, a.spec.id .. " / " .. b.spec.id)
				end
			end
		end
	end,

	["stairwells: enclosed, aligned openings, flights flush with landings, no overlap"] = function(t: Expect)
		Geometry.setYieldEvery(0)
		local school = Instance.new("Model")
		local container = StairwellBuilder.build(school, {})
		local plans = StairwellBuilder.plan({})
		t.eq(#container:GetChildren(), #plans)
		local shells: { [string]: { BasePart } } = {}
		for _, plan in plans do
			local spec = plan.spec
			local model = child(container, spec.id)
			t.eq(model:GetAttribute(W.FromLevel), spec.from)
			t.eq(model:GetAttribute(W.ToLevel), spec.to)
			local shell = child(model, "Shell")
			shells[spec.id] = parts(shell)

			-- Openings on the building side are clear at both floors.
			local tower = WorldConfig.Towers[spec.tower]
			local edge = if spec.tower == "East" then tower.minX else tower.maxX
			local dir = if spec.tower == "East" then 1 else -1
			local half = WorldConfig.ExteriorWallThickness / 2
			local opening = WorldConfig.TowerOpening
			for _, y in { plan.bottom, plan.bottom + plan.rise } do
				local xa, xb = edge + dir * (half + 0.01), edge + dir * (half + 0.99)
				local lo = Vector3.new(math.min(xa, xb), y + 0.01, opening.centerZ - opening.width / 2 + 0.01)
				local hi =
					Vector3.new(math.max(xa, xb), y + opening.height - 0.01, opening.centerZ + opening.width / 2 - 0.01)
				for _, part in shells[spec.id] do
					local a, b = aabb(part)
					t.eq(overlapVolume(a, b, lo, hi), 0, spec.id .. " opening blocked by " .. part.Name)
				end
			end

			-- Every flight: consecutive treads rise by stepRise; the last tread is flush with a landing.
			local landingTops: { number } = {}
			for _, part in shells[spec.id] do
				if string.sub(part.Name, 1, 7) == "Landing" then
					local _, b = aabb(part)
					table.insert(landingTops, b.Y)
				end
			end
			for k = 1, plan.flights do
				local start = plan.bottom + (k - 1) * plan.rise / plan.flights
				for i = 1, plan.risers do
					local step = childPart(shell, string.format("Flight%d_Step%02d", k, i))
					local _, b = aabb(step)
					t.near(b.Y, start + i * plan.stepRise, 1e-3, step.Name .. " tread height")
					t.truthy(step.Size.X >= plan.stepRun - 1e-3 or step.Size.Z >= plan.stepRun - 1e-3, "run")
				end
				local arrive = start + plan.rise / plan.flights
				local flush = false
				for _, y in landingTops do
					if math.abs(y - arrive) < 1e-3 then
						flush = true
					end
				end
				t.truthy(flush, string.format("%s flight %d arrives on a landing", spec.id, k))
			end
			t.truthy(#child(model, "Lights"):GetChildren() > 0, "emergency lighting")
			local zone = childPart(child(model, "Zones"), spec.id)
			t.eq(zone:GetAttribute(W.AcousticPreset), "Stairwell")
			t.eq(zone:GetAttribute(W.LevelId), spec.from)
		end
		-- Segments that share a tower never overlap.
		for _, a in plans do
			for _, b in plans do
				if a.spec.id < b.spec.id and a.spec.tower == b.spec.tower then
					for _, pa in shells[a.spec.id] do
						local a0, a1 = aabb(pa)
						for _, pb in shells[b.spec.id] do
							local b0, b1 = aabb(pb)
							t.truthy(
								overlapVolume(a0, a1, b0, b1) < 1e-6,
								string.format("%s.%s overlaps %s.%s", a.spec.id, pa.Name, b.spec.id, pb.Name)
							)
						end
					end
				end
			end
		end
		school:Destroy()
	end,

	["lobby: boiler, bus around the ready pads, pads and consoles"] = function(t: Expect)
		Geometry.setYieldEvery(0)
		local layout = lobbySlice()
		local lobby = LobbyBuilder.build(layout)
		t.eq(lobby.Name, "Lobby")
		t.eq(lobby:GetAttribute(W.LayoutId), "Lobby")
		local shell = child(lobby, "Shell")
		local boiler = child(shell, "Boiler")
		t.truthy(#boiler:GetChildren() > 10, "boiler set piece")
		local bus = child(shell, "Bus")
		t.truthy(#bus:GetChildren() > 20, "bus set piece")
		local glow = childPart(child(lobby, "Lights"), "Lobby_BoilerGlow")
		t.eq(glow:GetAttribute(W.LightKind), "BoilerGlow")
		t.eq(glow:GetAttribute(W.LevelId), "Lobby")
		local props = child(lobby, "Props")
		local busLo, busHi = Vector3.one * math.huge, -Vector3.one * math.huge
		for _, part in parts(bus) do
			local a, b = aabb(part)
			busLo, busHi = busLo:Min(a), busHi:Max(b)
		end
		local origin = WorldConfig.levelOrigin("Lobby")
		for i = 1, 4 do
			local pad = childPart(props, "ReadyPad_Pad" .. i)
			t.eq(pad:GetAttribute(W.AnchorKind), "ReadyPad")
			t.truthy(pad.CFrame.Position.X > busLo.X and pad.CFrame.Position.X < busHi.X, "pad inside the bus (X)")
			t.truthy(pad.CFrame.Position.Z > busLo.Z and pad.CFrame.Position.Z < busHi.Z, "pad inside the bus (Z)")
			-- nothing in the bus stands on the pad
			local padTop = origin.Y + 0.12
			for _, part in parts(bus) do
				local a, b = aabb(part)
				local overPad = math.abs(part.CFrame.Position.X - pad.CFrame.Position.X) < 1.5
					and math.abs(part.CFrame.Position.Z - pad.CFrame.Position.Z) < 1.5
				if overPad then
					t.truthy(a.Y > padTop + 2 or b.Y < padTop, part.Name .. " stands on a ready pad")
				end
			end
		end
		local terminal = child(props, "Terminal_TermA")
		t.truthy(terminal:FindFirstChild("Screen") ~= nil, "console screen")
		t.eq(#parts(child(lobby, "Zones")), 2)
		lobby:Destroy()
	end,

	["skyline is deterministic and purely cosmetic"] = function(t: Expect)
		Geometry.setYieldEvery(0)
		local a = Instance.new("Folder")
		local b = Instance.new("Folder")
		local c = Instance.new("Folder")
		local countA = SkylineBuilder.build(7, a)
		local countB = SkylineBuilder.build(7, b)
		local countC = SkylineBuilder.build(8, c)
		t.eq(countA, countB, "same seed, same part count")
		t.truthy(countA > 200, "a real skyline")
		local listA, listB, listC = parts(a), parts(b), parts(c)
		t.eq(#listA, countA)
		local differs = countA ~= countC
		for i, part in listA do
			t.truthy(part.CFrame.Position:FuzzyEq(listB[i].CFrame.Position, 1e-4), "same seed, same layout")
			t.truthy(part.Anchored and not part.CanCollide and not part.CanQuery and not part.CanTouch, part.Name)
			t.falsy(part.CastShadow, part.Name .. " shadow")
			t.eq(part.CollisionGroup, CollisionGroups.NoCollide)
			if listC[i] and not part.CFrame.Position:FuzzyEq(listC[i].CFrame.Position, 1e-3) then
				differs = true
			end
		end
		t.truthy(differs, "different seed, different skyline")
		-- Nothing cosmetic reaches the enclosed lobby far to the west.
		local lobby = WorldConfig.LobbyOrigin
		for _, part in listA do
			local lo, hi = aabb(part)
			local clear = hi.X < lobby.X - 150
				or lo.X > lobby.X + 300
				or hi.Z < lobby.Z - 150
				or lo.Z > lobby.Z + 300
				or hi.Y < lobby.Y - 5
			t.truthy(clear, part.Name .. " intrudes on the lobby")
		end
		for _, folder in { a, b, c } do
			folder:Destroy()
		end
	end,

	["exterior: street level at GroundY with the footprint and towers left open"] = function(t: Expect)
		Geometry.setYieldEvery(0)
		local exterior = Instance.new("Model")
		SchoolShellBuilder.buildExterior(exterior)
		local margin = WorldConfig.ExteriorWallThickness / 2
		local size = WorldConfig.FootprintSize
		local holes: { { Vector3 } } = {
			{ Vector3.new(-margin, -1e3, -margin), Vector3.new(size.X + margin, 1e3, size.Y + margin) },
		}
		for _, tower in WorldConfig.Towers do
			table.insert(holes, { Vector3.new(tower.minX, -1e3, tower.minZ), Vector3.new(tower.maxX, 1e3, tower.maxZ) })
		end
		local grounds = 0
		for _, part in parts(exterior) do
			local lo, hi = aabb(part)
			for _, hole in holes do
				t.truthy(overlapVolume(lo, hi, hole[1], hole[2]) < 1e-6, part.Name .. " covers the school")
			end
			if string.sub(part.Name, 1, 7) == "Ground_" then
				grounds += 1
				t.near(hi.Y, WorldConfig.GroundY, 1e-3, "ground top at GroundY")
			end
		end
		t.truthy(grounds >= 4, "ground pieces around the footprint")
		local field = exterior:FindFirstChild("LandingField")
		t.truthy(field ~= nil, "parachute landing field")
		if field and field:IsA("BasePart") then
			t.truthy(field.CFrame.Position.X < 0, "landing field west of the school")
		end
		exterior:Destroy()
	end,

	["lighting rig rebuilds the baseline"] = function(t: Expect)
		local Lighting = game:GetService("Lighting")
		local stray = Instance.new("BloomEffect")
		stray.Name = "Stray"
		stray.Parent = Lighting
		LightingRig.apply()
		t.falsy(Lighting:FindFirstChild("Stray"), "existing children cleared")
		t.truthy(Lighting:FindFirstChildOfClass("Atmosphere") ~= nil)
		local grade = Lighting:FindFirstChild(LightingRig.Names.ColorCorrection)
		t.truthy(grade and grade:IsA("ColorCorrectionEffect"), "base colour grade")
		t.truthy(Lighting:FindFirstChildOfClass("BloomEffect") ~= nil)
		t.eq(Lighting.ClockTime, LightingRig.Baseline.ClockTime)
		t.eq(Lighting.Brightness, 0)
	end,

	["registries: unregistered props and rigs return nil"] = function(t: Expect)
		local plan = {
			kind = "SpecNoSuchProp",
			anchorId = "a",
			levelId = "Level0_Basement" :: Enums.LayoutId,
			cframe = CFrame.new(),
			variant = 1,
		}
		local folder = Instance.new("Folder")
		t.eq(Builder.BuildProp(plan, folder, Random.new(1)), nil)
		t.eq(Builder.BuildRig("SpecNoSuchRig", folder, CFrame.new()), nil)
		Builder.RegisterProp("SpecCrate", function(ctx): Instance
			local part = Instance.new("Part")
			part.Name = "Crate_" .. ctx.prop.anchorId
			part.CFrame = ctx.prop.cframe
			return part
		end)
		local built = Builder.BuildProp({
			kind = "SpecCrate",
			anchorId = "x",
			levelId = "Level0_Basement",
			cframe = CFrame.new(1, 2, 3),
			variant = 1,
		}, folder, Random.new(1))
		t.truthy(built ~= nil and built.Parent == folder, "registered prop is built and parented")
		folder:Destroy()
	end,

	["real layouts build within budget (when present)"] = function(t: Expect)
		local layoutsFolder = ReplicatedStorage.Shared.World.ProceduralWorldBuilder:FindFirstChild("Layouts")
		if not layoutsFolder or #layoutsFolder:GetChildren() < #Enums.LayoutId then
			return -- layouts not authored yet; the synthetic specs above cover the builders
		end
		local host = Instance.new("Model")
		host.Name = "SpecWorld"
		local result = Builder.BuildAuthoritative({ parent = host :: Instance, yieldEvery = 0 })
		t.truthy(result.partCount > 2000, "a real world")
		t.truthy(result.partCount < 20000, string.format("part budget (%d)", result.partCount))
		for _, id: Enums.LevelId in Enums.LevelId do
			local level = result.levels[id]
			assert(level, "level " .. id)
			t.eq(level:GetAttribute(W.LayoutId), id)
			for _, name in { "Shell", "Lights", "Zones", "Vents", "Anchors", "Triggers", "Waypoints" } do
				child(level, name)
			end
			local layout = Builder.getLayout(id)
			assert(layout, id)
			t.eq(#child(level, "Zones"):GetChildren(), #layout.rooms, id .. " zones")
		end
		t.eq(#child(result.school, "Stairwells"):GetChildren(), #WorldConfig.Stairwells)
		child(result.school, "Exterior")
		child(child(result.lobby, "Anchors"), "AnchorRoot")
		host:Destroy()
	end,
}
