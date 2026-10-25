--!strict
-- Builds one layout's shell (school levels and the lobby share this path): room floors (the structural slab),
-- ceilings, split-slab walls with every opening cut (doors, grates, stair-tower openings, windows), door trims,
-- boarded planks, pillars, platforms, pool basins, then the invisible gameplay layer: Zone volumes, trigger
-- volumes, light fixtures, anchor attachments, door anchors and patrol waypoints. Also builds the street-level
-- exterior around the school.
--
-- Vertical layout of a level (level-local Y): every room floor occupies [-SlabThickness, 0], so the floors of a
-- level are the structural slab under it (rooms tile the footprint, so the slab has no holes except basins).
-- Walls stand on the slab from 0 to their height; footprint walls continue up to the next level's floor so the
-- facade is continuous. Ceilings are thin panels hanging just under each room's height.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(script.Parent.Geometry)
local Palette = require(script.Parent.Palette)

local log = Log.new("SchoolShell")

type Room = LayoutSchema.Room
type Rect = LayoutSchema.Rect
type Layout = LayoutSchema.LevelLayout
type Axis = Geometry.Axis

export type Folders = {
	Shell: Folder,
	Lights: Folder,
	Zones: Folder,
	Vents: Folder,
	Anchors: Folder,
	Triggers: Folder,
	Waypoints: Folder,
}

export type LevelOptions = {
	isSchool: boolean,
	hasLevelAbove: boolean, -- false caps every ceiling with a roof slab
	facadeTop: number?, -- level-local Y footprint walls rise to (the next level's slab underside); nil = own height
	facadeKey: string?, -- palette of the outside skin of footprint walls (nil = single skin, e.g. below grade)
	gradeY: number?, -- level-local Y of street level; windows below it get a soil backing outside
	groundUnderside: number?, -- level-local Y of the exterior ground slab's underside (soil backings stop there)
}

export type LightSpec = {
	id: string,
	kind: Enums.LightKind,
	position: Vector3, -- world
	brightness: number,
	range: number,
	color: Color3?,
	flickerGroup: string?,
	broken: boolean?,
	shadows: boolean?,
	levelId: string,
	zoneId: string,
	ceilingY: number?, -- world Y of the ceiling underside; fixtures never poke through it
	facing: Vector3?, -- world point wall-mounted fixtures face (room centre)
	aimAt: Vector3?, -- world point floodlights aim at
}

type Run = {
	axis: Axis,
	coord: number,
	from: number,
	to: number,
	low: Room?, -- room on the -normal side (smaller X / Z)
	high: Room?,
	exterior: boolean,
	thickness: number,
	height: number,
	lowKey: string,
	highKey: string,
	clip0: number, -- openings are clipped to [clip0, clip1] so junction squares stay solid
	clip1: number,
}

type LineOpening = {
	u0: number,
	u1: number,
	y0: number,
	y1: number,
}

type Line = {
	axis: Axis,
	coord: number,
	entries: { { from: number, to: number, room: Room, low: boolean } },
	openings: { LineOpening },
	runs: { Run },
}

local EPS = 1e-3
local CEILING = 0.4 -- ceiling panel thickness (hangs below the room height)
local PLANK = 0.22
local ROOF_ZONE_MIN = 24 -- open-sky zones extend this high so jumps and platforms stay inside them

local DEFAULT_FLOOR: { [string]: string } = {
	Corridor = "Linoleum",
	Classroom = "Linoleum",
	Lab = "Lab",
	LockerRoom = "TileWhite",
	Gym = "WoodGym",
	Pool = "PoolTile",
	Boiler = "ConcreteStained",
	Storage = "Concrete",
	Office = "Carpet",
	Restroom = "TileWhite",
	Chase = "Concrete",
	Airlock = "ConcreteDark",
	Stairwell = "ConcreteDark",
	Roof = "RoofGravel",
	LobbyHall = "ConcreteStained",
}

local DEFAULT_WALL: { [string]: string } = {
	Corridor = "PlasterGreen",
	Classroom = "PlasterSchool",
	Lab = "TileWhite",
	LockerRoom = "TileGreen",
	Gym = "Brick",
	Pool = "PoolTile",
	Boiler = "ConcreteDark",
	Storage = "Concrete",
	Office = "WoodPanel",
	Restroom = "TileWhite",
	Chase = "Concrete",
	Airlock = "ConcreteDark",
	Stairwell = "ConcreteDark",
	Roof = "Brick",
	LobbyHall = "Brick",
}

local DEFAULT_CEILING: { [string]: string } = {
	Corridor = "PlasterSchool",
	Classroom = "PlasterSchool",
	Lab = "PlasterSchool",
	LockerRoom = "Concrete",
	Gym = "MetalGalvanized",
	Pool = "ConcreteStained",
	Boiler = "ConcreteDark",
	Office = "PlasterSchool",
	Restroom = "PlasterSchool",
}

local TRIGGER_TAGS: { [string]: string } = {
	ScareStep = Tags.ScareTrigger,
	FloorDebris = Tags.FloorDebris,
	Checkpoint = Tags.CheckpointVolume,
	PoolWater = Tags.PoolWater,
	LevelExit = Tags.LevelExit,
}

local LIGHT_COLORS: { [string]: Color3 } = {
	Fluorescent = Color3.fromRGB(214, 228, 236),
	Bulb = Color3.fromRGB(255, 196, 140),
	EmergencyRed = Color3.fromRGB(255, 34, 22),
	ClassroomGlow = Color3.fromRGB(196, 214, 236),
	Floodlight = Color3.fromRGB(255, 240, 214),
	ExitSign = Color3.fromRGB(60, 255, 110),
	BoilerGlow = Color3.fromRGB(255, 118, 34),
}

local W = Attributes.World
local Names = Instances.Names

local SchoolShellBuilder = {}

SchoolShellBuilder.CeilingThickness = CEILING

-- Street-level exterior around the school (world X/Z; the ground's top is WorldConfig.GroundY).
SchoolShellBuilder.Exterior = table.freeze({
	minX = -360,
	maxX = 600,
	minZ = -280,
	maxZ = 440,
	groundThickness = 2,
	sidewalkWidth = 12,
	sidewalkHeight = 0.35,
	landing = table.freeze({ x = -190, z = 10, w = 150, d = 140 }),
})

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

function SchoolShellBuilder.floorKey(room: Room): string
	return room.floor or DEFAULT_FLOOR[room.kind] or "Concrete"
end

function SchoolShellBuilder.wallKey(room: Room): string
	return room.wall or DEFAULT_WALL[room.kind] or "Concrete"
end

function SchoolShellBuilder.ceilingKey(room: Room): string
	return room.ceiling or DEFAULT_CEILING[room.kind] or "Concrete"
end

function SchoolShellBuilder.surface(room: Room): Enums.SurfaceKind
	return room.surface or Palette.get(SchoolShellBuilder.floorKey(room)).surface
end

local function hasCeiling(room: Room): boolean
	return not room.noCeiling and room.kind ~= "Chase"
end

-- World Y of a room's ceiling underside (or its open top).
function SchoolShellBuilder.ceilingBottom(layout: Layout, room: Room): number
	local h = LayoutSchema.roomHeight(layout, room)
	return if hasCeiling(room) then h - CEILING else h
end

-- Sides of each room that no other room shares (the footprint boundary on school levels).
function SchoolShellBuilder.exteriorSides(layout: Layout): { [string]: { [string]: boolean } }
	local out: { [string]: { [string]: boolean } } = {}
	for _, room in layout.rooms do
		local sides: { [string]: boolean } = { N = true, S = true, W = true, E = true }
		local r = room.rect
		for _, other in layout.rooms do
			if other == room then
				continue
			end
			local edge = LayoutSchema.sharedEdge(r, other.rect)
			if edge then
				if edge.axis == "X" then
					sides[if math.abs(edge.coord - r.x) < EPS then "W" else "E"] = false
				else
					sides[if math.abs(edge.coord - r.z) < EPS then "N" else "S"] = false
				end
			end
		end
		out[room.id] = sides
	end
	return out
end

local function floorRect(room: Room, exteriorSides: { [string]: { [string]: boolean } }): Rect
	local sides = exteriorSides[room.id]
	local margin = WorldConfig.ExteriorWallThickness / 2
	local r = room.rect
	local x0, z0, x1, z1 = r.x, r.z, r.x + r.w, r.z + r.d
	if sides then
		if sides.W then
			x0 -= margin
		end
		if sides.E then
			x1 += margin
		end
		if sides.N then
			z0 -= margin
		end
		if sides.S then
			z1 += margin
		end
	end
	return { x = x0, z = z0, w = x1 - x0, d = z1 - z0 }
end

-- The room rect shrunk to its wall faces (every side of a ceiling-bearing room has a wall).
local function innerRect(room: Room, exteriorSides: { [string]: { [string]: boolean } }): Rect
	local sides = exteriorSides[room.id]
	local function inset(side: string): number
		local exterior = sides ~= nil and sides[side] == true
		return (if exterior then WorldConfig.ExteriorWallThickness else WorldConfig.WallThickness) / 2
	end
	local r = room.rect
	local x0, x1 = r.x + inset("W"), r.x + r.w - inset("E")
	local z0, z1 = r.z + inset("N"), r.z + r.d - inset("S")
	return { x = x0, z = z0, w = math.max(0, x1 - x0), d = math.max(0, z1 - z0) }
end

local function sideHeight(layout: Layout, room: Room): number
	return room.wallHeight or LayoutSchema.roomHeight(layout, room)
end

local function lineKey(axis: Axis, coord: number): string
	return string.format("%s|%.3f", axis, coord)
end

local function sideLine(rect: Rect, side: LayoutSchema.Side): (Axis, number)
	if side == "N" then
		return "Z", rect.z
	elseif side == "S" then
		return "Z", rect.z + rect.d
	elseif side == "W" then
		return "X", rect.x
	end
	return "X", rect.x + rect.w
end

local function roomCenter(room: Room): (number, number)
	return room.rect.x + room.rect.w / 2, room.rect.z + room.rect.d / 2
end

local function setAttributes(instance: Instance, values: { [string]: any })
	for key, value in values do
		instance:SetAttribute(key, value)
	end
end

--------------------------------------------------------------------------------
-- Root + folders
--------------------------------------------------------------------------------

function SchoolShellBuilder.folders(root: Model): Folders
	return {
		Shell = Geometry.folder(root, Names.Shell),
		Lights = Geometry.folder(root, Names.Lights),
		Zones = Geometry.folder(root, Names.Zones),
		Vents = Geometry.folder(root, Names.Vents),
		Anchors = Geometry.folder(root, Names.Anchors),
		Triggers = Geometry.folder(root, Names.Triggers),
		Waypoints = Geometry.folder(root, Names.Waypoints),
	}
end

function SchoolShellBuilder.createRoot(layout: Layout, name: string?): Model
	local root = Instance.new("Model")
	root.Name = name or layout.id
	root:SetAttribute(W.LayoutId, layout.id)
	SchoolShellBuilder.folders(root)
	return root
end

-- Options for a school level from WorldConfig: the level above (if any) decides the facade height and whether
-- ceilings need a roof cap; street level decides the facade skin and window wells.
function SchoolShellBuilder.levelOptions(layoutId: string): LevelOptions
	if layoutId == "Lobby" then
		return { isSchool = false, hasLevelAbove = false }
	end
	local elevation = WorldConfig.levelElevation(layoutId)
	local index = Enums.levelIndex(layoutId)
	local nextId = if index then Enums.LevelId[index + 1] else nil
	local facadeTop = if nextId then WorldConfig.levelElevation(nextId) - elevation - WorldConfig.SlabThickness else nil
	local aboveGrade = elevation >= WorldConfig.GroundY - EPS
	return {
		isSchool = true,
		hasLevelAbove = nextId ~= nil,
		facadeTop = facadeTop,
		facadeKey = if aboveGrade then "Brick" else nil,
		gradeY = WorldConfig.GroundY - elevation,
		groundUnderside = WorldConfig.GroundY - SchoolShellBuilder.Exterior.groundThickness - elevation,
	}
end

--------------------------------------------------------------------------------
-- Lights (shared with the stairwell and lobby builders)
--------------------------------------------------------------------------------

local function newLight(
	className: "PointLight" | "SpotLight" | "SurfaceLight",
	spec: LightSpec,
	name: string,
	range: number
): Light
	local clamped = math.clamp(range, 0, 60)
	local light: Light
	if className == "SpotLight" then
		local spot = Instance.new("SpotLight")
		spot.Range = clamped
		light = spot
	elseif className == "SurfaceLight" then
		local surface = Instance.new("SurfaceLight")
		surface.Range = clamped
		light = surface
	else
		local point = Instance.new("PointLight")
		point.Range = clamped
		light = point
	end
	light.Name = name
	light.Color = spec.color or LIGHT_COLORS[spec.kind] or Color3.new(1, 1, 1)
	light.Shadows = spec.shadows == true
	light.Enabled = not spec.broken
	-- Broken fixtures stay dark whatever the client controller does with BaseBrightness.
	light.Brightness = if spec.broken then 0 else spec.brightness
	return light
end

-- One fixture part + its light(s). The fixture carries the LevelLight tag and the attributes the client
-- LightingController drives (it is the only run-time writer of these lights).
function SchoolShellBuilder.buildLight(parent: Instance, spec: LightSpec): BasePart
	local kind = spec.kind
	local position = spec.position
	local function underCeiling(halfHeight: number): Vector3
		if spec.ceilingY then
			return Vector3.new(position.X, math.min(position.Y, spec.ceilingY - halfHeight), position.Z)
		end
		return position
	end
	local function facingCFrame(at: Vector3): CFrame
		local target = spec.facing
		if target then
			local flat = Vector3.new(target.X, at.Y, target.Z)
			if (flat - at).Magnitude > 0.1 then
				return CFrame.lookAt(at, flat)
			end
		end
		return CFrame.new(at)
	end

	local fixture: Part
	local primary: Light
	local secondary: Light? = nil
	local fixtureOptions: Geometry.PartOptions = { castShadow = false, canCollide = false }
	if kind == "Fluorescent" or kind == "ClassroomGlow" then
		fixture = Geometry.part(
			parent,
			spec.id,
			CFrame.new(underCeiling(0.125)),
			Vector3.new(4, 0.25, 0.9),
			"Fixture",
			fixtureOptions
		)
		if kind == "Fluorescent" then
			local surface = newLight("SurfaceLight", spec, "Light", spec.range) :: SurfaceLight
			surface.Face = Enum.NormalId.Bottom
			surface.Angle = 120
			primary = surface
		else
			local spot = newLight("SpotLight", spec, "Light", spec.range) :: SpotLight
			spot.Face = Enum.NormalId.Bottom
			spot.Angle = 110
			primary = spot
			local fill = newLight("PointLight", spec, "Fill", spec.range * 0.6)
			fill.Brightness = if spec.broken then 0 else spec.brightness * 0.35
			secondary = fill
		end
	elseif kind == "Bulb" then
		fixture = Geometry.part(
			parent,
			spec.id,
			CFrame.new(underCeiling(0.6)),
			Vector3.new(0.7, 0.7, 0.7),
			"Glass",
			{ shape = Enum.PartType.Ball, castShadow = false, canCollide = false, transparency = 0.2 }
		)
		primary = newLight("PointLight", spec, "Light", spec.range)
	elseif kind == "Floodlight" then
		local at = underCeiling(0.8)
		local aim = spec.aimAt or (at - Vector3.new(0, 10, 0))
		local cframe = if (aim - at).Magnitude > 0.1 then CFrame.lookAt(at, aim) else CFrame.new(at)
		fixture = Geometry.part(parent, spec.id, cframe, Vector3.new(2.2, 1.4, 1.2), "TrimMetal", fixtureOptions)
		local spot = newLight("SpotLight", spec, "Light", spec.range) :: SpotLight
		spot.Face = Enum.NormalId.Front
		spot.Angle = 70
		primary = spot
	elseif kind == "ExitSign" then
		local at = underCeiling(0.4)
		fixture =
			Geometry.part(parent, spec.id, facingCFrame(at), Vector3.new(2.2, 0.8, 0.3), "Fixture", fixtureOptions)
		local surface = newLight("SurfaceLight", spec, "Light", spec.range) :: SurfaceLight
		surface.Face = Enum.NormalId.Front
		surface.Angle = 100
		primary = surface
	elseif kind == "BoilerGlow" then
		local at = underCeiling(0.5)
		fixture = Geometry.part(parent, spec.id, facingCFrame(at), Vector3.new(1.6, 1, 0.25), "Ember", fixtureOptions)
		primary = newLight("PointLight", spec, "Light", spec.range)
	else
		-- EmergencyRed
		local at = underCeiling(0.25)
		fixture =
			Geometry.part(parent, spec.id, facingCFrame(at), Vector3.new(1.2, 0.5, 0.5), "Fixture", fixtureOptions)
		primary = newLight("PointLight", spec, "Light", spec.range)
	end
	Geometry.makeFixture(fixture)
	primary.Parent = fixture
	if secondary then
		secondary.Parent = fixture
	end
	fixture:AddTag(Tags.LevelLight)
	fixture:SetAttribute(W.LightKind, kind)
	fixture:SetAttribute(W.LevelId, spec.levelId)
	fixture:SetAttribute(W.ZoneId, spec.zoneId)
	fixture:SetAttribute(W.BaseBrightness, if spec.broken then 0 else spec.brightness)
	if spec.flickerGroup then
		fixture:SetAttribute(W.FlickerGroup, spec.flickerGroup)
	end
	return fixture
end

--------------------------------------------------------------------------------
-- Walls
--------------------------------------------------------------------------------

local function collectLines(layout: Layout): ({ [string]: Line }, { string })
	local lines: { [string]: Line } = {}
	local order: { string } = {}
	local function lineFor(axis: Axis, coord: number): Line
		local key = lineKey(axis, coord)
		local line = lines[key]
		if not line then
			line = { axis = axis, coord = coord, entries = {}, openings = {}, runs = {} }
			lines[key] = line
			table.insert(order, key)
		end
		return line
	end
	for _, room in layout.rooms do
		local r = room.rect
		table.insert(lineFor("Z", r.z).entries, { from = r.x, to = r.x + r.w, room = room, low = false })
		table.insert(lineFor("Z", r.z + r.d).entries, { from = r.x, to = r.x + r.w, room = room, low = true })
		table.insert(lineFor("X", r.x).entries, { from = r.z, to = r.z + r.d, room = room, low = false })
		table.insert(lineFor("X", r.x + r.w).entries, { from = r.z, to = r.z + r.d, room = room, low = true })
	end
	table.sort(order)
	return lines, order
end

-- Two chases that touch form one continuous service cavity (ducts may cross between them). Every other shared
-- edge gets a wall; between open roof rooms that wall is a parapet-height firewall (their wallHeight).
local function wallIsOpen(low: Room?, high: Room?): boolean
	return low ~= nil and high ~= nil and low.kind == "Chase" and high.kind == "Chase"
end

local function buildRuns(layout: Layout, line: Line, options: LevelOptions)
	local breaks: { number } = {}
	for _, entry in line.entries do
		table.insert(breaks, entry.from)
		table.insert(breaks, entry.to)
	end
	table.sort(breaks)
	local unique: { number } = {}
	for _, value in breaks do
		if #unique == 0 or value - unique[#unique] > EPS then
			table.insert(unique, value)
		end
	end
	local current: Run? = nil
	for i = 1, #unique - 1 do
		local p, q = unique[i], unique[i + 1]
		local mid = (p + q) / 2
		local low: Room?, high: Room? = nil, nil
		for _, entry in line.entries do
			if entry.from < mid and entry.to > mid then
				if entry.low then
					low = entry.room
				else
					high = entry.room
				end
			end
		end
		if (low == nil and high == nil) or wallIsOpen(low, high) then
			current = nil
			continue
		end
		if current and current.low == low and current.high == high and math.abs(current.to - p) < EPS then
			current.to = q
			current.clip1 = q
			continue
		end
		local exterior = low == nil or high == nil
		local height: number
		local lowKey: string
		local highKey: string
		if exterior then
			local room = (low or high) :: Room
			-- Under another level the facade always closes up to the slab, whatever the room's own height.
			height = options.facadeTop or sideHeight(layout, room)
			local inner = SchoolShellBuilder.wallKey(room)
			local outer = options.facadeKey or inner
			if low then
				lowKey, highKey = inner, outer
			else
				lowKey, highKey = outer, inner
			end
		else
			local a, b = low :: Room, high :: Room
			height = math.max(sideHeight(layout, a), sideHeight(layout, b))
			lowKey, highKey = SchoolShellBuilder.wallKey(a), SchoolShellBuilder.wallKey(b)
			if a.kind == "Chase" then
				lowKey = highKey
			elseif b.kind == "Chase" then
				highKey = lowKey
			end
		end
		if height <= EPS then
			current = nil
			continue -- a parapet gap (wallHeight 0)
		end
		local run: Run = {
			axis = line.axis,
			coord = line.coord,
			from = p,
			to = q,
			low = low,
			high = high,
			exterior = exterior,
			thickness = if exterior then WorldConfig.ExteriorWallThickness else WorldConfig.WallThickness,
			height = height,
			lowKey = lowKey,
			highKey = highKey,
			clip0 = p,
			clip1 = q,
		}
		table.insert(line.runs, run)
		current = run
	end
end

local function runAt(line: Line?, u: number): Run?
	if not line then
		return nil
	end
	for _, run in line.runs do
		if u >= run.from - EPS and u <= run.to + EPS then
			return run
		end
	end
	return nil
end

-- Signed across offset of the wall face that looks into `room`, and the direction (+1/-1) away from the wall.
local function faceToward(run: Run, room: Room): (number, number)
	local cx, cz = roomCenter(room)
	local c = if run.axis == "X" then cx else cz
	if c < run.coord then
		return -run.thickness / 2, -1
	end
	return run.thickness / 2, 1
end

local function roomName(room: Room?): string
	return if room then room.id else "Outside"
end

local function buildWalls(origin: Vector3, shell: Folder, lines: { [string]: Line }, order: { string }): number
	local runs: { Run } = {}
	local segments: { Geometry.WallSegment } = {}
	for _, key in order do
		for _, run in lines[key].runs do
			table.insert(runs, run)
			table.insert(segments, {
				axis = run.axis,
				coord = run.coord,
				from = run.from,
				to = run.to,
				thickness = run.thickness,
				height = run.height,
				start = run.from,
				finish = run.to,
			})
		end
	end
	local fillers = Geometry.resolveJunctions(segments)
	local count = 0
	for index, run in runs do
		local segment = segments[index]
		run.clip0 = run.from + (segment.startMargin or 0)
		run.clip1 = run.to - (segment.finishMargin or 0)
		local line = lines[lineKey(run.axis, run.coord)]
		local openings: { Geometry.Opening } = {}
		for _, opening in line.openings do
			local u0, u1 = math.max(opening.u0, run.clip0), math.min(opening.u1, run.clip1)
			if u1 - u0 > EPS then
				table.insert(openings, { u0 = u0, u1 = u1, y0 = opening.y0, y1 = opening.y1 })
			end
		end
		local boxes = Geometry.splitWall(segment.start, segment.finish, 0, run.height, openings)
		local half = run.thickness / 2
		local name = string.format("Wall_%s_%s", roomName(run.low), roomName(run.high))
		for i, box in boxes do
			if run.lowKey == run.highKey then
				if
					Geometry.wallBox(
						shell,
						string.format("%s_%d", name, i),
						origin,
						run.axis,
						run.coord,
						box.u0,
						box.u1,
						box.y0,
						box.y1,
						-half,
						half,
						run.lowKey
					)
				then
					count += 1
				end
			else
				if
					Geometry.wallBox(
						shell,
						string.format("%s_%dL", name, i),
						origin,
						run.axis,
						run.coord,
						box.u0,
						box.u1,
						box.y0,
						box.y1,
						-half,
						0,
						run.lowKey
					)
				then
					count += 1
				end
				if
					Geometry.wallBox(
						shell,
						string.format("%s_%dH", name, i),
						origin,
						run.axis,
						run.coord,
						box.u0,
						box.u1,
						box.y0,
						box.y1,
						0,
						half,
						run.highKey
					)
				then
					count += 1
				end
			end
		end
	end
	for i, filler in fillers do
		local run = runs[filler.segment]
		if
			Geometry.box(
				shell,
				string.format("WallJoint_%d", i),
				origin + Vector3.new(filler.x0, filler.y0, filler.z0),
				origin + Vector3.new(filler.x1, filler.y1, filler.z1),
				if run then run.lowKey else "Concrete"
			)
		then
			count += 1
		end
	end
	return count
end

--------------------------------------------------------------------------------
-- Opening dressing: trims, planks, window shards, soil backings
--------------------------------------------------------------------------------

local function addPlanks(
	parent: Instance,
	name: string,
	origin: Vector3,
	run: Run,
	u0: number,
	u1: number,
	y0: number,
	y1: number,
	face: number,
	dir: number,
	random: Random
): number
	local count = 0
	local width = (u1 - u0) + 0.8
	local mid = (u0 + u1) / 2
	local y = y0 + 0.2
	local index = 0
	while y < y1 - 0.25 do
		index += 1
		local h = math.min(random:NextNumber(0.75, 1.05), y1 - 0.05 - y)
		if h < 0.3 then
			break
		end
		local depth = face + dir * (PLANK / 2 + (index % 2) * 0.06)
		local cframe = Geometry.wallCFrame(
			origin,
			run.axis,
			run.coord,
			mid + random:NextNumber(-0.15, 0.15),
			y + h / 2,
			depth
		) * CFrame.Angles(0, 0, math.rad(random:NextNumber(-5, 5)))
		Geometry.part(
			parent,
			string.format("%s_Plank%d", name, index),
			cframe,
			Vector3.new(width, h, PLANK),
			if index % 3 == 0 then "PlankDark" else "Plank"
		)
		count += 1
		y += h + random:NextNumber(0.18, 0.42)
	end
	-- One diagonal brace nailed over the planks.
	local spanU, spanY = u1 - u0, y1 - y0
	local length = math.sqrt(spanU * spanU + spanY * spanY)
	if length > 1 then
		local angle = math.atan2(spanY, spanU) * (if random:NextNumber() < 0.5 then 1 else -1)
		local depth = face + dir * (PLANK * 1.5 + 0.08)
		local cframe = Geometry.wallCFrame(origin, run.axis, run.coord, mid, (y0 + y1) / 2, depth)
			* CFrame.Angles(0, 0, angle)
		Geometry.part(
			parent,
			name .. "_Brace",
			cframe,
			Vector3.new(math.max(0.5, length - 0.6), 0.7, PLANK),
			"PlankDark"
		)
		count += 1
	end
	return count
end

local function addShards(
	parent: Instance,
	name: string,
	origin: Vector3,
	run: Run,
	opening: LineOpening,
	random: Random
): number
	local count = 0
	local corners: { { number } } = {
		{ opening.u0, opening.y1, 1, -1 },
		{ opening.u1, opening.y0, -1, 1 },
	}
	for i, corner in corners do
		local w = random:NextNumber(0.6, 1.4)
		local h = random:NextNumber(0.6, 1.6)
		local u = corner[1] + corner[3] * w / 2
		local y = corner[2] + corner[4] * h / 2
		local cframe = Geometry.wallCFrame(origin, run.axis, run.coord, u, y, 0)
			* CFrame.Angles(0, 0, math.rad(if corner[4] < 0 then 180 else 0))
		local shard = Geometry.wedge(
			parent,
			string.format("%s_Shard%d", name, i),
			cframe * CFrame.Angles(0, math.rad(90), 0),
			Vector3.new(0.05, h, w),
			"Glass",
			{ transparency = 0.55, castShadow = false, canCollide = false, canQuery = false }
		)
		Geometry.makeFixture(shard)
		count += 1
	end
	return count
end

--------------------------------------------------------------------------------
-- Level build
--------------------------------------------------------------------------------

local function collectOpenings(
	layout: Layout,
	rooms: { [string]: Room },
	lines: { [string]: Line }
): {
	{
		kind: string,
		axis: Axis,
		coord: number,
		opening: LineOpening,
		door: LayoutSchema.Door?,
		window: LayoutSchema.Window?,
	}
}
	local placed: {
		{
			kind: string,
			axis: Axis,
			coord: number,
			opening: LineOpening,
			door: LayoutSchema.Door?,
			window: LayoutSchema.Window?,
		}
	} =
		{}
	local function add(
		kind: string,
		axis: Axis,
		coord: number,
		opening: LineOpening,
		door: LayoutSchema.Door?,
		window: LayoutSchema.Window?
	)
		local line = lines[lineKey(axis, coord)]
		if not line then
			log.warn("%s: %s opening at %s=%.1f has no wall line", layout.id, kind, axis, coord)
			return
		end
		table.insert(line.openings, opening)
		table.insert(
			placed,
			{ kind = kind, axis = axis, coord = coord, opening = opening, door = door, window = window }
		)
	end

	for _, door in layout.doors do
		local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
		if not a or not b then
			log.warn("%s: door %s references a missing room", layout.id, door.id)
			continue
		end
		local edge = LayoutSchema.sharedEdge(a.rect, b.rect)
		if not edge then
			log.warn("%s: door %s rooms do not share a wall", layout.id, door.id)
			continue
		end
		local half = LayoutSchema.doorWidth(door) / 2
		add(
			"Door",
			edge.axis,
			edge.coord,
			{ u0 = door.at - half, u1 = door.at + half, y0 = 0, y1 = LayoutSchema.doorHeight(door) },
			door,
			nil
		)
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
			if not node or not room then
				log.warn("%s: grate %s references a missing node or room", layout.id, grate.id)
				continue
			end
			local side = LayoutSchema.sideOfPoint(room.rect, node.x, node.z)
			if not side then
				log.warn("%s: grate %s node is not on a wall of %s", layout.id, grate.id, room.id)
				continue
			end
			local axis: Axis, coord: number = sideLine(room.rect, side :: LayoutSchema.Side)
			local u = if axis == "X" then node.z else node.x
			local y = LayoutSchema.ventNodeY(node)
			add("Grate", axis, coord, { u0 = u - halfBore, u1 = u + halfBore, y0 = y - halfBore, y1 = y + halfBore })
		end
	end

	if layout.id ~= "Lobby" then
		local opening = WorldConfig.TowerOpening
		for _, spec in WorldConfig.Stairwells do
			local roomId = if spec.from == layout.id
				then spec.fromRoom
				elseif spec.to == layout.id then spec.toRoom
				else nil
			if not roomId then
				continue
			end
			local room = rooms[roomId]
			if not room then
				log.warn("%s: stairwell %s needs room %s", layout.id, spec.id, roomId)
				continue
			end
			local tower = WorldConfig.Towers[spec.tower]
			local coord = if spec.tower == "East" then room.rect.x + room.rect.w else room.rect.x
			local expected = if spec.tower == "East" then tower.minX else tower.maxX
			if math.abs(coord - expected) > EPS then
				log.warn("%s: room %s does not touch the %s tower", layout.id, roomId, spec.tower)
				continue
			end
			add("Tower", "X", coord, {
				u0 = opening.centerZ - opening.width / 2,
				u1 = opening.centerZ + opening.width / 2,
				y0 = 0,
				y1 = opening.height,
			})
		end
	end

	for _, window in (layout.windows or {}) :: { LayoutSchema.Window } do
		local room = rooms[window.room]
		if not room then
			continue
		end
		local axis: Axis, coord: number = sideLine(room.rect, window.side)
		local half = window.width / 2
		add(
			"Window",
			axis,
			coord,
			{ u0 = window.at - half, u1 = window.at + half, y0 = window.sill, y1 = window.sill + window.height },
			nil,
			window
		)
	end
	return placed
end

-- Builds every piece of `layout` into `root` (see SchoolShellBuilder.createRoot). Returns parts created.
function SchoolShellBuilder.buildLevel(layout: Layout, root: Model, options: LevelOptions): number
	local before = Geometry.partsCreated()
	local folders = SchoolShellBuilder.folders(root)
	local origin = WorldConfig.levelOrigin(layout.id)
	local rooms = LayoutSchema.indexRooms(layout)
	local shell = folders.Shell
	local slab = WorldConfig.SlabThickness
	local levelId: string = layout.id

	-- Basins per room (deck holes, zone depth)
	local basinsByRoom: { [string]: { LayoutSchema.Basin } } = {}
	for _, basin in (layout.basins or {}) :: { LayoutSchema.Basin } do
		basinsByRoom[basin.room] = basinsByRoom[basin.room] or {}
		table.insert(basinsByRoom[basin.room], basin)
	end

	-- Floors (= the structural slab), ceilings, roof caps. Floors reach under the outer half of exterior walls so
	-- the slab edge closes the facade between storeys.
	local exteriorSides = SchoolShellBuilder.exteriorSides(layout)
	for _, room in layout.rooms do
		local holes: { Rect } = {}
		for _, basin in (basinsByRoom[room.id] or {}) :: { LayoutSchema.Basin } do
			table.insert(holes, basin.rect)
		end
		for i, piece in Geometry.subtractRects(floorRect(room, exteriorSides), holes) do
			Geometry.box(
				shell,
				string.format("Floor_%s_%d", room.id, i),
				origin + Vector3.new(piece.x, -slab, piece.z),
				origin + Vector3.new(piece.x + piece.w, 0, piece.z + piece.d),
				SchoolShellBuilder.floorKey(room)
			)
		end
		if hasCeiling(room) then
			local h = LayoutSchema.roomHeight(layout, room)
			local r = innerRect(room, exteriorSides)
			Geometry.box(
				shell,
				"Ceiling_" .. room.id,
				origin + Vector3.new(r.x, h - CEILING, r.z),
				origin + Vector3.new(r.x + r.w, h, r.z + r.d),
				SchoolShellBuilder.ceilingKey(room),
				{ castShadow = true }
			)
			if not options.hasLevelAbove then
				local cap = floorRect(room, exteriorSides)
				Geometry.box(
					shell,
					"Roof_" .. room.id,
					origin + Vector3.new(cap.x, h, cap.z),
					origin + Vector3.new(cap.x + cap.w, h + slab, cap.z + cap.d),
					if options.isSchool then "RoofGravel" else "ConcreteDark"
				)
			end
		end
	end

	-- Walls with every opening cut
	local lines, order = collectLines(layout)
	for _, key in order do
		buildRuns(layout, lines[key], options)
	end
	local placed = collectOpenings(layout, rooms, lines)
	buildWalls(origin, shell, lines, order)

	-- Opening dressing
	for index, item in placed do
		local line = lines[lineKey(item.axis, item.coord)]
		local opening = item.opening
		local run = runAt(line, (opening.u0 + opening.u1) / 2)
		if not run then
			continue -- the opening sits in an open (unwalled) edge
		end
		opening = {
			u0 = math.max(opening.u0, run.clip0),
			u1 = math.min(opening.u1, run.clip1),
			y0 = opening.y0,
			y1 = opening.y1,
		}
		if opening.u1 - opening.u0 <= EPS then
			continue
		end
		local door = item.door
		local window = item.window
		if door then
			-- A gap in a wall lower than the door (a roof firewall) has no lintel, so it gets no casing.
			local hasLintel = opening.y1 < run.height - EPS
			if (door.kind == "Doorway" or door.kind == "Door" or door.kind == "Ajar") and hasLintel then
				Geometry.doorTrims(
					shell,
					"Door_" .. door.id,
					origin,
					run.axis,
					run.coord,
					opening.u0,
					opening.u1,
					math.min(opening.y1, run.height),
					run.thickness,
					"Trim"
				)
			elseif door.kind == "Boarded" then
				local room = rooms[door.rooms[1]]
				local face, dir = faceToward(run, room)
				addPlanks(
					shell,
					"Boards_" .. door.id,
					origin,
					run,
					opening.u0,
					opening.u1,
					opening.y0,
					math.min(opening.y1, run.height),
					face,
					dir,
					MathUtil.seededRandom(1, layout.id .. ":door:" .. door.id)
				)
			end
		elseif window then
			local room = rooms[window.room]
			local random = MathUtil.seededRandom(1, string.format("%s:window:%d", layout.id, index))
			local name = string.format("Window_%s_%d", window.room, index)
			if window.boarded then
				local face, dir = faceToward(run, room)
				addPlanks(shell, name, origin, run, opening.u0, opening.u1, opening.y0, opening.y1, face, dir, random)
			else
				addShards(shell, name, origin, run, opening, random)
			end
			if run.exterior and options.gradeY and opening.y1 < options.gradeY then
				-- Below grade: a soil-filled light well behind the opening.
				local outsideDir = if run.low == nil then -1 else 1
				local outerFace = outsideDir * run.thickness / 2
				local top = opening.y1 + 0.5
				if options.groundUnderside then
					top = math.min(top, options.groundUnderside)
				end
				Geometry.wallBox(
					shell,
					name .. "_Well",
					origin,
					run.axis,
					run.coord,
					opening.u0 - 0.5,
					opening.u1 + 0.5,
					math.max(0, opening.y0 - 0.5),
					top,
					math.min(outerFace, outerFace + outsideDir),
					math.max(outerFace, outerFace + outsideDir),
					"Soil"
				)
			end
		end
	end

	-- Pillars
	for i, pillar in (layout.pillars or {}) :: { LayoutSchema.Pillar } do
		local room = rooms[pillar.room]
		if not room then
			continue
		end
		Geometry.pillar(
			shell,
			string.format("Pillar_%d", i),
			origin,
			pillar.x,
			pillar.z,
			pillar.size,
			SchoolShellBuilder.ceilingBottom(layout, room),
			"ConcreteDark",
			"ConcreteStained"
		)
	end

	-- Platforms
	for _, platform in (layout.platforms or {}) :: { LayoutSchema.Platform } do
		local room = rooms[platform.room]
		-- Clipped to the room's wall faces so a platform laid against a wall never sinks into it.
		local r = if room
			then Geometry.rectIntersection(platform.rect, innerRect(room, exteriorSides))
			else platform.rect
		if not r then
			continue
		end
		Geometry.box(
			shell,
			"Platform_" .. platform.id,
			origin + Vector3.new(r.x, platform.top - platform.thickness, r.z),
			origin + Vector3.new(r.x + r.w, platform.top, r.z + r.d),
			platform.material or "ConcreteStained"
		)
	end

	-- Pool basins: shell down to `depth`, a murky surface, and a PoolWater volume
	for _, basin in (layout.basins or {}) :: { LayoutSchema.Basin } do
		local r = basin.rect
		local depth = basin.depth
		local wall = 1
		Geometry.box(
			shell,
			basin.id .. "_Floor",
			origin + Vector3.new(r.x, -depth - 1, r.z),
			origin + Vector3.new(r.x + r.w, -depth, r.z + r.d),
			"PoolTile"
		)
		local sides: { { number } } = {
			{ r.x, r.z, r.x + r.w, r.z + wall },
			{ r.x, r.z + r.d - wall, r.x + r.w, r.z + r.d },
			{ r.x, r.z + wall, r.x + wall, r.z + r.d - wall },
			{ r.x + r.w - wall, r.z + wall, r.x + r.w, r.z + r.d - wall },
		}
		for i, side in sides do
			Geometry.box(
				shell,
				string.format("%s_Wall%d", basin.id, i),
				origin + Vector3.new(side[1], -depth, side[2]),
				origin + Vector3.new(side[3], 0, side[4]),
				"PoolTile"
			)
		end
		local inner = Geometry.insetRect(r, wall)
		local surface = Geometry.box(
			shell,
			basin.id .. "_Surface",
			origin + Vector3.new(inner.x, basin.waterLevel - 0.2, inner.z),
			origin + Vector3.new(inner.x + inner.w, basin.waterLevel, inner.z + inner.d),
			"Water",
			{ transparency = 0.25, canCollide = false, canQuery = false, castShadow = false, reflectance = 0.08 }
		)
		if surface then
			Geometry.makeFixture(surface)
		end
		local volume = Geometry.box(
			folders.Triggers,
			basin.id,
			origin + Vector3.new(r.x, -depth, r.z),
			origin + Vector3.new(r.x + r.w, basin.waterLevel, r.z + r.d),
			"Water"
		)
		if volume then
			Geometry.makeVolume(volume)
			volume:AddTag(Tags.PoolWater)
			setAttributes(volume, {
				[W.TriggerId] = basin.id,
				[W.TriggerKind] = "PoolWater",
				[W.LevelId] = levelId,
				[W.ZoneId] = basin.room,
			})
		end
	end

	-- Zones
	for _, room in layout.rooms do
		local r = room.rect
		local bottom = 0
		for _, basin in (basinsByRoom[room.id] or {}) :: { LayoutSchema.Basin } do
			bottom = math.min(bottom, -basin.depth)
		end
		local top = LayoutSchema.roomHeight(layout, room)
		if room.noCeiling then
			top = math.max(top, ROOF_ZONE_MIN)
		end
		local zone = Geometry.box(
			folders.Zones,
			room.id,
			origin + Vector3.new(r.x, bottom, r.z),
			origin + Vector3.new(r.x + r.w, top, r.z + r.d),
			"Concrete"
		)
		if zone then
			Geometry.makeVolume(zone)
			zone:AddTag(Tags.Zone)
			setAttributes(zone, {
				[W.ZoneId] = room.id,
				[W.LevelId] = levelId,
				[W.RoomKind] = room.kind,
				[W.AcousticPreset] = room.acoustic or layout.acoustic,
				[W.Surface] = SchoolShellBuilder.surface(room),
			})
		end
	end

	-- Triggers
	for _, trigger in layout.triggers do
		local r = trigger.rect
		local y = trigger.y or 0
		local part = Geometry.box(
			folders.Triggers,
			trigger.id,
			origin + Vector3.new(r.x, y, r.z),
			origin + Vector3.new(r.x + r.w, y + trigger.height, r.z + r.d),
			"Concrete"
		)
		if part then
			Geometry.makeVolume(part)
			local tag = TRIGGER_TAGS[trigger.kind]
			if tag then
				part:AddTag(tag)
			end
			setAttributes(part, {
				[W.TriggerId] = trigger.id,
				[W.TriggerKind] = trigger.kind,
				[W.LevelId] = levelId,
				[W.ZoneId] = trigger.room,
			})
		end
	end

	-- Lights
	for _, room in layout.rooms do
		local cx, cz = roomCenter(room)
		local ceilingY = origin.Y + SchoolShellBuilder.ceilingBottom(layout, room)
		for _, light in (room.lights or {}) :: { LayoutSchema.Light } do
			SchoolShellBuilder.buildLight(folders.Lights, {
				id = light.id,
				kind = light.kind,
				position = origin + light.pos,
				brightness = light.brightness,
				range = light.range,
				color = light.color,
				flickerGroup = light.flickerGroup,
				broken = light.broken,
				shadows = light.shadows,
				levelId = levelId,
				zoneId = room.id,
				ceilingY = if hasCeiling(room) then ceilingY else nil,
				facing = origin + Vector3.new(cx, light.pos.Y, cz),
				aimAt = origin + Vector3.new(cx, 0, cz),
			})
		end
	end

	-- Anchors, waypoints, door anchors
	SchoolShellBuilder.buildAnchors(layout, folders, origin)

	return Geometry.partsCreated() - before
end

local function rootPart(parent: Instance, name: string, origin: Vector3): Part
	local part = Geometry.part(parent, name, CFrame.new(origin), Vector3.new(1, 1, 1), "Concrete")
	Geometry.makeVolume(part)
	return part
end

function SchoolShellBuilder.anchorLocalCFrame(anchor: LayoutSchema.Anchor): CFrame
	return CFrame.new(anchor.pos) * CFrame.Angles(0, math.rad(anchor.yaw or 0), 0)
end

function SchoolShellBuilder.buildAnchors(layout: Layout, folders: Folders, origin: Vector3)
	local levelId: string = layout.id
	local anchorRoot = rootPart(folders.Anchors, "AnchorRoot", origin)
	local waypointRoot = rootPart(folders.Waypoints, "WaypointRoot", origin)
	for _, anchor in layout.anchors do
		local isWaypoint = anchor.kind == "PatrolWaypoint"
		local attachment = Geometry.attachment(
			if isWaypoint then waypointRoot else anchorRoot,
			anchor.id,
			SchoolShellBuilder.anchorLocalCFrame(anchor)
		)
		setAttributes(attachment, {
			[W.AnchorId] = anchor.id,
			[W.AnchorKind] = anchor.kind,
			[W.LevelId] = levelId,
			[W.ZoneId] = anchor.room,
		})
		if isWaypoint then
			attachment:AddTag(Tags.PatrolWaypoint)
		elseif anchor.kind == "PlayerSpawn" or anchor.kind == "CreatureSpawn" then
			attachment:AddTag(Tags.SpawnAnchor)
		end
	end

	local rooms = LayoutSchema.indexRooms(layout)
	for _, door in layout.doors do
		if
			not (
				door.kind == "Door"
				or door.kind == "Ajar"
				or door.kind == "Gate"
				or door.kind == "Airlock"
				or door.kind == "RoofDoor"
			)
		then
			continue
		end
		local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
		if not a or not b then
			continue
		end
		local edge = LayoutSchema.sharedEdge(a.rect, b.rect)
		if not edge then
			continue
		end
		local ax, az = roomCenter(a)
		local bx, bz = roomCenter(b)
		local position: Vector3
		local direction: Vector3
		if edge.axis == "X" then
			position = Vector3.new(edge.coord, 0, door.at)
			direction = Vector3.new(if bx > ax then 1 else -1, 0, 0)
		else
			position = Vector3.new(door.at, 0, edge.coord)
			direction = Vector3.new(0, 0, if bz > az then 1 else -1)
		end
		local attachment =
			Geometry.attachment(anchorRoot, "Door_" .. door.id, CFrame.lookAt(position, position + direction))
		setAttributes(attachment, {
			[W.DoorId] = door.id,
			[W.DoorKind] = door.kind,
			[W.DoorWidth] = LayoutSchema.doorWidth(door),
			[W.DoorHeight] = LayoutSchema.doorHeight(door),
			[W.LevelId] = levelId,
		})
		if door.scriptedId then
			attachment:SetAttribute(W.ScriptedId, door.scriptedId)
		end
	end
end

--------------------------------------------------------------------------------
-- Exterior: street-level ground around the school, sidewalks, the parachute landing field
--------------------------------------------------------------------------------

function SchoolShellBuilder.buildExterior(parent: Instance): number
	local before = Geometry.partsCreated()
	local ext = SchoolShellBuilder.Exterior
	local groundY = WorldConfig.GroundY
	local size = WorldConfig.FootprintSize
	local margin = WorldConfig.ExteriorWallThickness / 2
	local footprint = Geometry.rect(-margin, -margin, size.X + margin * 2, size.Y + margin * 2)
	local holes: { Rect } = { footprint }
	for _, tower in WorldConfig.Towers do
		table.insert(holes, Geometry.rect(tower.minX, tower.minZ, tower.maxX - tower.minX, tower.maxZ - tower.minZ))
	end

	local ground = Geometry.rect(ext.minX, ext.minZ, ext.maxX - ext.minX, ext.maxZ - ext.minZ)
	for i, piece in Geometry.subtractRects(ground, holes) do
		Geometry.box(
			parent,
			string.format("Ground_%d", i),
			Vector3.new(piece.x, groundY - ext.groundThickness, piece.z),
			Vector3.new(piece.x + piece.w, groundY, piece.z + piece.d),
			"Asphalt"
		)
	end

	local walk = ext.sidewalkWidth
	local ring = Geometry.rect(-walk, -walk, size.X + walk * 2, size.Y + walk * 2)
	for i, piece in Geometry.subtractRects(ring, holes) do
		Geometry.box(
			parent,
			string.format("Sidewalk_%d", i),
			Vector3.new(piece.x, groundY, piece.z),
			Vector3.new(piece.x + piece.w, groundY + ext.sidewalkHeight, piece.z + piece.d),
			"Sidewalk"
		)
	end

	-- Parachute landing field west of the school: a churned dead-grass lot ringed by broken kerbs.
	local field = ext.landing
	Geometry.box(
		parent,
		"LandingField",
		Vector3.new(field.x, groundY, field.z),
		Vector3.new(field.x + field.w, groundY + 0.2, field.z + field.d),
		"DeadGrass"
	)
	local kerbs: { { number } } = {
		{ field.x, field.z - 1, field.x + field.w * 0.45, field.z },
		{ field.x + field.w * 0.6, field.z - 1, field.x + field.w, field.z },
		{ field.x, field.z + field.d, field.x + field.w * 0.3, field.z + field.d + 1 },
		{ field.x + field.w * 0.5, field.z + field.d, field.x + field.w, field.z + field.d + 1 },
		{ field.x - 1, field.z, field.x, field.z + field.d * 0.7 },
	}
	for i, kerb in kerbs do
		Geometry.box(
			parent,
			string.format("Kerb_%d", i),
			Vector3.new(kerb[1], groundY, kerb[2]),
			Vector3.new(kerb[3], groundY + 0.8, kerb[4]),
			"Concrete"
		)
	end

	-- Deterministic street debris and dead lamp posts (no lights: the storm is the only light outside).
	local random = MathUtil.seededRandom(1, "Exterior")
	local function clearOfSchool(x: number, z: number, pad: number): boolean
		if x > -walk - pad and x < size.X + walk + pad and z > -walk - pad and z < size.Y + walk + pad then
			return false
		end
		if x > field.x - pad and x < field.x + field.w + pad and z > field.z - pad and z < field.z + field.d + pad then
			return false
		end
		return true
	end
	local placedDebris = 0
	local attempts = 0
	while placedDebris < 14 and attempts < 200 do
		attempts += 1
		local x = random:NextNumber(-140, 380)
		local z = random:NextNumber(-90, 250)
		if not clearOfSchool(x, z, 6) then
			continue
		end
		placedDebris += 1
		local w, d, h = random:NextNumber(3, 9), random:NextNumber(3, 9), random:NextNumber(1, 3.5)
		Geometry.part(
			parent,
			string.format("Rubble_%d", placedDebris),
			CFrame.new(x, groundY + h / 2 - 0.3, z)
				* CFrame.Angles(math.rad(random:NextNumber(-8, 8)), math.rad(random:NextNumber(0, 180)), 0),
			Vector3.new(w, h, d),
			"Rubble"
		)
	end
	local lampSpots: { { number } } = {
		{ -walk + 1.5, 20 },
		{ -walk + 1.5, 140 },
		{ 60, -walk + 1.5 },
		{ 180, -walk + 1.5 },
		{ 60, size.Y + walk - 1.5 },
		{ 180, size.Y + walk - 1.5 },
		{ size.X + walk - 1.5, 20 },
		{ size.X + walk - 1.5, 140 },
	}
	for i, spot in lampSpots do
		local x, z = spot[1], spot[2]
		local lean = math.rad(random:NextNumber(-9, 9))
		local base = Vector3.new(x, groundY + ext.sidewalkHeight, z)
		local top = base + (CFrame.Angles(lean, 0, lean * 0.5) * Vector3.new(0, 16, 0))
		Geometry.cylinder(parent, string.format("LampPost_%d", i), base, top, 0.6, "MetalRust")
		Geometry.part(parent, string.format("LampHead_%d", i), CFrame.new(top), Vector3.new(1.4, 0.6, 2.4), "TrimMetal")
	end

	return Geometry.partsCreated() - before
end

return table.freeze(SchoolShellBuilder)
