--!strict
-- Builds one layout's shell (school levels and the lobby share this path): room floors (the structural slab),
-- ceilings, split-slab walls with every opening cut (doors, grates, stair-tower openings, windows), door trims,
-- boarded planks, pillars, platforms, pool basins, the interior finishes (Finishes: glossy, checkered and vinyl
-- floors, drop ceilings, wainscots kept clear of every opening, hazard plates at the fire doors and the gate), then
-- the invisible gameplay layer: Zone volumes, trigger volumes, light fixtures (with their FixtureGlow surfaces),
-- anchor attachments, door anchors and patrol waypoints. Also builds the street-level exterior around the school.
-- Every wall face a room sees is weathered (Finishes.decorateWall: grime, soot, corner dirt, water runs, cracks), and
-- every door casing carries a stepped head cap (Geometry.doorTrims).
--
-- Vertical layout of a level (level-local Y): every room floor occupies [-SlabThickness, 0], so the floors of a
-- level are the structural slab under it (rooms tile the footprint, so the slab has no holes except basins and
-- room for ducts that sit low in a chase). Under the outer half of every footprint wall the slab continues as a
-- slab-edge strip of one material, the band seen on the facade between storeys. Walls stand on the slab from 0
-- to their height; footprint walls continue up to the next level's floor so the facade is continuous, and the
-- facade skin owns the whole square at every building corner. Ceilings are thin panels hanging just under each
-- room's height.
--
-- Every light fixture casts shadows unless its layout entry says `shadows = false`: a Future-lighting light
-- without shadows shines straight through walls and slabs into the neighbouring rooms. LightingController's
-- render budget can still turn them off on low-end devices.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Finishes = require(script.Parent.Finishes)
local FixtureGlow = require(script.Parent.FixtureGlow)
local Geometry = require(script.Parent.Geometry)
local LightingMood = require(script.Parent.LightingMood)
local Palette = require(script.Parent.Palette)
local SurfaceArt = require(script.Parent.SurfaceArt)
local VentShaftBuilder = require(script.Parent.VentShaftBuilder)

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
	slabEdgeKey: string?, -- palette of the slab-edge strips under footprint walls (default ConcreteDark)
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
	along: Vector3?, -- horizontal axis a ceiling strip fixture runs along (the room's long axis; default X)
	hang: boolean?, -- false: a broken fixture never sags out of its mounts (a pipe runs under it); default true
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

export type LineOpening = {
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

-- One opening cut into a wall line (`opening` in wall-local u / y).
export type PlacedOpening = {
	kind: "Door" | "Grate" | "Tower" | "Window",
	axis: Axis,
	coord: number,
	opening: LineOpening,
	door: LayoutSchema.Door?,
	window: LayoutSchema.Window?,
}

local EPS = 1e-3
local CEILING = 0.4 -- ceiling panel thickness (hangs below the room height)
local PLANK = 0.22
local ROOF_ZONE_MIN = 24 -- open-sky zones extend this high so jumps and platforms stay inside them
local BASIN_WALL = Geometry.BasinWall
local SLAB_EDGE_KEY = "ConcreteDark" -- slab edges nobody sees from the street (below grade, the lobby)
local FACADE_SLAB_EDGE_KEY = "SlabEdge" -- the concrete band between storeys on the brick facade
local WATER_SURFACE = 0.2 -- thickness of a murky water surface part

-- Murky water surfaces (basins and layout PoolWater volumes): visible, never collided, queried or shadowed.
local WATER_OPTIONS: Geometry.PartOptions =
	{ transparency = 0.25, canCollide = false, canQuery = false, castShadow = false, reflectance = 0.08 }

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
	boundaryHeight = 40, -- invisible walls around the ground slab's edge
	boundaryThickness = 2,
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
		slabEdgeKey = if aboveGrade then FACADE_SLAB_EDGE_KEY else SLAB_EDGE_KEY,
	}
end

--------------------------------------------------------------------------------
-- Lights (shared with the stairwell and lobby builders)
--------------------------------------------------------------------------------

-- SynthPresets loop each working fixture kind emits (none for the rest).
local FIXTURE_HUM: { [string]: string } = {
	Fluorescent = "FluorescentBuzz",
	BoilerGlow = "BoilerHum",
}

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
	-- Shadowed by default (broken fixtures too: an override such as the pool floodlight switch can revive them).
	-- Unshadowed lights are not blocked by parts, so they would light the rooms behind every wall in range.
	light.Shadows = spec.shadows ~= false
	light.Enabled = not spec.broken
	-- Broken fixtures stay dark whatever the client controller does with BaseBrightness.
	light.Brightness = if spec.broken then 0 else spec.brightness
	return light
end

-- Strip fixtures (fluorescent troffers and the classroom glow): a shallow housing under the ceiling and two bare
-- tubes under it, the long axis along the room's long axis. The whole fixture stays within 0.33 studs of the ceiling,
-- so the drip pipes hung under the ceilings (SetDressingBuilder) pass beneath it.
type StripDims = { length: number, height: number, width: number, tube: number, spacing: number }

local STRIP: { [string]: StripDims } = {
	Fluorescent = { length = 5.5, height = 0.18, width = 1.0, tube = 0.14, spacing = 0.22 },
	ClassroomGlow = { length = 4.6, height = 0.18, width = 1.0, tube = 0.14, spacing = 0.22 },
}
local TUBE_INSET = 0.2 -- each tube stops this short of the housing's ends (the sockets)
local BULB_SIZE = 0.7
local BULB_FILAMENT = 0.42
local BULB_DROP = 1.1 -- bulb centre below the ceiling: it hangs on its flex
local CORD_DIAMETER = 0.07

-- Broken strip fixtures fall apart in a few ways (seeded per fixture): both tubes dead, one pulled, one hanging out
-- of a socket, or the whole housing sagging off one mount.
type StripVariant = "Whole" | "MissingTube" | "HangingTube" | "SaggingHousing"

local function stripVariant(random: Random, broken: boolean, mayHang: boolean): StripVariant
	if not broken then
		return "Whole"
	end
	local roll = random:NextNumber()
	if mayHang and roll < 0.12 then
		return "SaggingHousing"
	elseif mayHang and roll < 0.32 then
		return "HangingTube"
	elseif roll < 0.56 then
		return "MissingTube"
	end
	return "Whole"
end

local function flatAxis(along: Vector3?): Vector3
	if along then
		local flat = Vector3.new(along.X, 0, along.Z)
		if flat.Magnitude > 1e-3 then
			return flat.Unit
		end
	end
	return Vector3.xAxis
end

-- Long axis a strip fixture takes in `room` (its long horizontal axis).
function SchoolShellBuilder.fixtureAlong(room: Room): Vector3
	return if room.rect.d > room.rect.w then Vector3.zAxis else Vector3.xAxis
end

-- The rest-pose bounding box of a fixture of `kind` built at `position` under a ceiling at `ceilingY` (both in one
-- space, level-local or world), strip fixtures along `along`. Planners that must miss the fixtures (pipe runs, sign
-- spots) use this rather than guessing its size. Broken strip fixtures may sag below it, but only within its
-- footprint, and never where the layout runs a drip pipe (see LightSpec.hang).
function SchoolShellBuilder.fixtureBox(
	kind: string,
	position: Vector3,
	ceilingY: number?,
	along: Vector3?
): (Vector3, Vector3)
	local function under(halfHeight: number): Vector3
		if ceilingY then
			return Vector3.new(position.X, math.min(position.Y, ceilingY - halfHeight), position.Z)
		end
		return position
	end
	local strip = STRIP[kind]
	if strip then
		local at = under(strip.height / 2)
		local axis = flatAxis(along)
		local half = Vector3.new(
			math.abs(axis.X) * strip.length / 2 + math.abs(axis.Z) * strip.width / 2,
			0,
			math.abs(axis.Z) * strip.length / 2 + math.abs(axis.X) * strip.width / 2
		)
		local top = at.Y + strip.height / 2
		local bottom = at.Y - strip.height / 2 - strip.tube - 0.01
		return Vector3.new(at.X - half.X, bottom, at.Z - half.Z), Vector3.new(at.X + half.X, top, at.Z + half.Z)
	elseif kind == "Bulb" then
		local at = if ceilingY
			then Vector3.new(position.X, math.min(position.Y, ceilingY - BULB_DROP), position.Z)
			else position
		local r = BULB_SIZE / 2
		local top = if ceilingY then math.max(ceilingY, at.Y + r) else at.Y + r
		return Vector3.new(at.X - r, at.Y - r, at.Z - r), Vector3.new(at.X + r, top, at.Z + r)
	end
	local half: Vector3
	if kind == "Floodlight" then
		local at = under(0.8)
		half = Vector3.one * 1.6
		return at - half, at + half
	elseif kind == "ExitSign" then
		half = Vector3.new(1.15, 0.4, 1.15)
		local at = under(0.4)
		return at - half, at + half
	elseif kind == "BoilerGlow" then
		half = Vector3.new(0.85, 0.5, 0.85)
		local at = under(0.5)
		return at - half, at + half
	end
	half = Vector3.new(0.65, 0.25, 0.65)
	local at = under(0.25)
	return at - half, at + half
end

-- One fixture part + its light(s) + its glow surfaces (FixtureGlow). The fixture carries the LevelLight tag and the
-- attributes the client LightingController drives (it is the only run-time writer of these lights, and of the glow
-- surfaces, which it dims, flickers and kills together with the light).
function SchoolShellBuilder.buildLight(parent: Instance, spec: LightSpec): BasePart
	local kind = spec.kind
	local position = spec.position
	local lightColor = spec.color or LIGHT_COLORS[kind] or Color3.new(1, 1, 1)
	local litColor = FixtureGlow.litColor(kind, lightColor)
	local level = if spec.broken then 0 else 1
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
	local function glow(part: BasePart?)
		if part then
			Geometry.makeFixture(part)
			FixtureGlow.apply(part, litColor, level)
		end
	end
	-- A flat lens on the front face (local -Z) of a box fixture.
	local function lens(fixture: BasePart, size: Vector2)
		local depth = 0.05
		glow(
			Geometry.part(
				fixture,
				FixtureGlow.PartPrefix,
				fixture.CFrame * CFrame.new(0, 0, -(fixture.Size.Z + depth) / 2),
				Vector3.new(size.X, size.Y, depth),
				"Fixture",
				{ castShadow = false, canCollide = false }
			)
		)
	end

	local fixture: Part
	local primary: Light
	local secondary: Light? = nil
	local fixtureOptions: Geometry.PartOptions = { castShadow = false, canCollide = false }
	local strip = STRIP[kind]
	if strip then
		local random = MathUtil.seededRandom(1, "fixture:" .. spec.id)
		local variant = stripVariant(random, spec.broken == true, spec.hang ~= false)
		local axis = flatAxis(spec.along)
		local frame = CFrame.fromMatrix(underCeiling(strip.height / 2), axis, Vector3.yAxis)
		if variant == "SaggingHousing" then
			-- one mount let go: the housing swings down about the top edge of its other end
			local side = if random:NextNumber() < 0.5 then 1 else -1
			local pivot = frame * CFrame.new(side * strip.length / 2, strip.height / 2, 0)
			frame = pivot * CFrame.Angles(0, 0, side * math.rad(random:NextNumber(7, 12))) * pivot:Inverse() * frame
		end
		fixture = Geometry.part(
			parent,
			spec.id,
			frame,
			Vector3.new(strip.length, strip.height, strip.width),
			"Fixture",
			fixtureOptions
		)
		local tubeY = -strip.height / 2 - strip.tube / 2 - 0.005
		local tubeHalf = strip.length / 2 - TUBE_INSET
		local odd = random:NextInteger(1, 2)
		for index, z in { -strip.spacing, strip.spacing } do
			if variant == "MissingTube" and index == odd then
				continue
			end
			local a = frame * Vector3.new(-tubeHalf, tubeY, z)
			local b = frame * Vector3.new(tubeHalf, tubeY, z)
			if variant == "HangingTube" and index == odd then
				-- out of one socket: the tube hangs from the other at a steep angle
				if random:NextNumber() < 0.5 then
					a, b = b, a
				end
				local run = b - a
				local length = run.Magnitude
				local drop = math.rad(random:NextNumber(22, 38))
				b = a + (run.Unit * math.cos(drop) - Vector3.yAxis * math.sin(drop)) * length
			end
			glow(
				Geometry.cylinder(
					fixture,
					FixtureGlow.PartPrefix .. index,
					a,
					b,
					strip.tube,
					"Fixture",
					{ castShadow = false, canCollide = false }
				)
			)
		end
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
		local ceilingY = spec.ceilingY
		local at = if ceilingY
			then Vector3.new(position.X, math.min(position.Y, ceilingY - BULB_DROP), position.Z)
			else position
		fixture = Geometry.part(
			parent,
			spec.id,
			CFrame.new(at),
			Vector3.one * BULB_SIZE,
			"Glass",
			{ shape = Enum.PartType.Ball, castShadow = false, canCollide = false, transparency = 0.2 }
		)
		glow(Geometry.part(fixture, FixtureGlow.PartPrefix, CFrame.new(at), Vector3.one * BULB_FILAMENT, "Fixture", {
			shape = Enum.PartType.Ball,
			castShadow = false,
			canCollide = false,
		}))
		if ceilingY and ceilingY - at.Y > BULB_SIZE then
			local cord = Geometry.cylinder(
				fixture,
				"Cord",
				at + Vector3.new(0, BULB_SIZE / 2 - 0.05, 0),
				Vector3.new(at.X, ceilingY, at.Z),
				CORD_DIAMETER,
				"Rubber",
				{ castShadow = false, canCollide = false }
			)
			if cord then
				Geometry.makeFixture(cord)
			end
		end
		primary = newLight("PointLight", spec, "Light", spec.range)
	elseif kind == "Floodlight" then
		local at = underCeiling(0.8)
		local aim = spec.aimAt or (at - Vector3.new(0, 10, 0))
		local cframe = if (aim - at).Magnitude > 0.1 then CFrame.lookAt(at, aim) else CFrame.new(at)
		fixture = Geometry.part(parent, spec.id, cframe, Vector3.new(2.2, 1.4, 1.2), "TrimMetal", fixtureOptions)
		lens(fixture, Vector2.new(1.9, 1.1))
		local spot = newLight("SpotLight", spec, "Light", spec.range) :: SpotLight
		spot.Face = Enum.NormalId.Front
		spot.Angle = 70
		primary = spot
	elseif kind == "ExitSign" then
		local at = underCeiling(0.4)
		fixture =
			Geometry.part(parent, spec.id, facingCFrame(at), Vector3.new(2.2, 0.8, 0.3), "Fixture", fixtureOptions)
		-- the letters are the light: a self-lit face that the controller dims with the light
		local gui = SurfaceArt.gui(fixture, Enum.NormalId.Front, {
			name = FixtureGlow.GuiName,
			pixelsPerStud = 20,
			maxDistance = 140,
			lightInfluence = 0,
			brightness = FixtureGlow.guiBrightness(level),
		})
		SurfaceArt.frame(gui, "Panel", 0.03, 0.07, 0.94, 0.86, Color3.fromRGB(12, 14, 12), 0, 1)
		SurfaceArt.text(gui, "Text", Strings.get("Prop.Sign.Exit"), 0.12, 0.1, 0.76, 0.8, litColor, Enum.Font.Oswald, 2)
		local surface = newLight("SurfaceLight", spec, "Light", spec.range) :: SurfaceLight
		surface.Face = Enum.NormalId.Front
		surface.Angle = 100
		primary = surface
	elseif kind == "BoilerGlow" then
		local at = underCeiling(0.5)
		fixture = Geometry.part(parent, spec.id, facingCFrame(at), Vector3.new(1.6, 1, 0.25), "Ember", fixtureOptions)
		lens(fixture, Vector2.new(1.3, 0.7))
		primary = newLight("PointLight", spec, "Light", spec.range)
	else
		-- EmergencyRed
		local at = underCeiling(0.25)
		fixture =
			Geometry.part(parent, spec.id, facingCFrame(at), Vector3.new(1.2, 0.5, 0.5), "Fixture", fixtureOptions)
		lens(fixture, Vector2.new(0.9, 0.28))
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
	-- Working tubes buzz and boilers hum: AudioController plays the nearest tagged emitters as looping 3D voices.
	local hum = if spec.broken then nil else FIXTURE_HUM[kind]
	if hum then
		fixture:SetAttribute(W.Preset, hum)
		fixture:AddTag(Tags.AmbientEmitter)
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

-- Palette key of the outside skin of an exterior run.
local function outerKey(run: Run): string
	return if run.low == nil then run.lowKey else run.highKey
end

-- Key of the stretch of `run` that Geometry.resolveJunctions extends over an L-corner square at `u` (the junction
-- at u along the run's line). When either arm is a footprint wall, every face of that stretch that shows is on the
-- outside of the building, so it takes the facade skin whole (the room's own wall skin would show as a stripe on
-- the adjacent facade). Nil keeps the run's two skins (a corner inside the building).
local function cornerKey(lines: { [string]: Line }, run: Run, u: number): string?
	if run.exterior then
		return outerKey(run)
	end
	local partner = runAt(lines[lineKey(if run.axis == "X" then "Z" else "X", u)], run.coord)
	if partner and partner.exterior then
		return outerKey(partner)
	end
	return nil
end

type CornerPiece = { u0: number, u1: number, key: string }

-- What weathering a level's wall faces needs to know about its rooms.
type WearContext = {
	layout: Layout,
	inner: { [string]: Rect }, -- room rects shrunk to their wall faces
	wainscoted: { [string]: boolean },
}

local function wearContext(layout: Layout, exteriorSides: { [string]: { [string]: boolean } }): WearContext
	local inner: { [string]: Rect } = {}
	local wainscoted: { [string]: boolean } = {}
	for _, room in layout.rooms do
		inner[room.id] = innerRect(room, exteriorSides)
		wainscoted[room.id] = Finishes.wainscotStyle(layout.id, room, SchoolShellBuilder.wallKey(room)) ~= nil
	end
	return { layout = layout, inner = inner, wainscoted = wainscoted }
end

-- Weathers the face of wall box `part` (wall-local [u0, u1] x [y0, y1] on `run`) that looks into `room`.
local function wearFace(wear: WearContext, part: BasePart, run: Run, box: Geometry.WallBox, room: Room?, high: boolean)
	if not room then
		return
	end
	local r = wear.inner[room.id]
	if not r then
		return
	end
	local lo = if run.axis == "Z" then r.x else r.z
	local hi = if run.axis == "Z" then r.x + r.w else r.z + r.d
	if box.u1 <= lo + EPS or box.u0 >= hi - EPS then
		return -- the box sits in a junction or beyond the room's corner
	end
	local face = if run.axis == "Z"
		then (if high then Enum.NormalId.Back else Enum.NormalId.Front)
		else (if high then Enum.NormalId.Right else Enum.NormalId.Left)
	Finishes.decorateWall({
		part = part,
		face = face,
		layoutId = wear.layout.id,
		room = room,
		y0 = box.y0,
		y1 = box.y1,
		ceiling = if hasCeiling(room) then SchoolShellBuilder.ceilingBottom(wear.layout, room) else math.huge,
		wainscot = wear.wainscoted[room.id] == true,
		cornerLo = if box.u0 <= lo + 0.6 then math.max(0, lo - box.u0) else nil,
		cornerHi = if box.u1 >= hi - 0.6 then math.max(0, box.u1 - hi) else nil,
	})
end

local function buildWalls(
	origin: Vector3,
	shell: Folder,
	lines: { [string]: Line },
	order: { string },
	wear: WearContext
): number
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
		-- An L-corner extension (beyond the run's own ends) is one solid piece in the facade key; openings never
		-- reach it (they are clipped to [clip0, clip1]).
		local coreStart, coreFinish = segment.start, segment.finish
		local corners: { CornerPiece } = {}
		if run.lowKey ~= run.highKey then
			if segment.start < run.from - EPS then
				local key = cornerKey(lines, run, run.from)
				if key then
					table.insert(corners, { u0 = segment.start, u1 = run.from, key = key })
					coreStart = run.from
				end
			end
			if segment.finish > run.to + EPS then
				local key = cornerKey(lines, run, run.to)
				if key then
					table.insert(corners, { u0 = run.to, u1 = segment.finish, key = key })
					coreFinish = run.to
				end
			end
		end
		local boxes = Geometry.splitWall(coreStart, coreFinish, 0, run.height, openings)
		local half = run.thickness / 2
		local name = string.format("Wall_%s_%s", roomName(run.low), roomName(run.high))
		for i, corner in corners do
			if
				Geometry.wallBox(
					shell,
					string.format("%s_Corner%d", name, i),
					origin,
					run.axis,
					run.coord,
					corner.u0,
					corner.u1,
					0,
					run.height,
					-half,
					half,
					corner.key
				)
			then
				count += 1
			end
		end
		for i, box in boxes do
			if run.lowKey == run.highKey then
				local part = Geometry.wallBox(
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
				if part then
					count += 1
					wearFace(wear, part, run, box, run.low, false)
					wearFace(wear, part, run, box, run.high, true)
				end
			else
				local low = Geometry.wallBox(
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
				if low then
					count += 1
					wearFace(wear, low, run, box, run.low, false)
				end
				local high = Geometry.wallBox(
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
				if high then
					count += 1
					wearFace(wear, high, run, box, run.high, true)
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
				if run then (if run.exterior then outerKey(run) else run.lowKey) else "Concrete"
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

-- Every opening cut into a wall line: doors, grates, stair-tower openings and windows (pure layout maths). With
-- `lines`, each is also registered on its wall line (and one without a line is dropped with a warning).
local function planOpenings(layout: Layout, rooms: { [string]: Room }, lines: { [string]: Line }?): { PlacedOpening }
	local placed: { PlacedOpening } = {}
	local function add(
		kind: "Door" | "Grate" | "Tower" | "Window",
		axis: Axis,
		coord: number,
		opening: LineOpening,
		door: LayoutSchema.Door?,
		window: LayoutSchema.Window?
	)
		if lines then
			local line = lines[lineKey(axis, coord)]
			if not line then
				log.warn("%s: %s opening at %s=%.1f has no wall line", layout.id, kind, axis, coord)
				return
			end
			table.insert(line.openings, opening)
		end
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

type Box3 = { x0: number, x1: number, y0: number, y1: number, z0: number, z1: number }

-- One tiled side wall of a pool basin, in wall-local terms (see Geometry's header).
type BasinSide = { axis: Axis, coord: number, u0: number, u1: number }

type BoundaryWall = { name: string, x0: number, z0: number, x1: number, z1: number }

-- Level-local box of every grate's bore from its wall line into its room, through the room-side half of the wall
-- and one basin coping beyond it: a grate opening over a pool cuts through the coping too.
local function grateTunnels(layout: Layout, rooms: { [string]: Room }): { Box3 }
	local out: { Box3 } = {}
	local vents = layout.vents
	if not vents then
		return out
	end
	local nodes: { [string]: LayoutSchema.VentNodeSpec } = {}
	for _, node in vents.nodes do
		nodes[node.id] = node
	end
	local halfBore = WorldConfig.VentBore / 2
	local reach = WorldConfig.WallThickness / 2 + BASIN_WALL
	for _, grate in vents.grates do
		local node, room = nodes[grate.node], rooms[grate.room]
		if not node or not room then
			continue
		end
		local side = LayoutSchema.sideOfPoint(room.rect, node.x, node.z)
		if not side then
			continue
		end
		local y = LayoutSchema.ventNodeY(node)
		local box: Box3 = {
			x0 = node.x - halfBore,
			x1 = node.x + halfBore,
			y0 = y - halfBore,
			y1 = y + halfBore,
			z0 = node.z - halfBore,
			z1 = node.z + halfBore,
		}
		-- the room lies on the inward side of the wall the grate is cut through
		if side == "N" then
			box.z0, box.z1 = node.z, node.z + reach
		elseif side == "S" then
			box.z0, box.z1 = node.z - reach, node.z
		elseif side == "W" then
			box.x0, box.x1 = node.x, node.x + reach
		else
			box.x0, box.x1 = node.x - reach, node.x
		end
		table.insert(out, box)
	end
	return out
end

-- Every opening the shell cuts into `layout`'s walls (pure; the sign and pipe planners keep clear of them).
function SchoolShellBuilder.openings(layout: Layout): { PlacedOpening }
	return planOpenings(layout, LayoutSchema.indexRooms(layout), nil)
end

--------------------------------------------------------------------------------
-- Finishes: wainscots and hazard plates (floors and ceilings are finished as they are built)
--------------------------------------------------------------------------------

local SIDES: { LayoutSchema.Side } = { "N", "S", "W", "E" }

-- How far a wainscot stops short of each kind of opening: the casing, steel frame, rails or boards around it.
local DOOR_FRAME_PAD: { [string]: number } = {
	Doorway = 0.4,
	Door = 0.4,
	Ajar = 0.4,
	RoofDoor = 0.45,
	Gate = 0.6,
	Boarded = 0.6,
	Airlock = 0.8,
}
local OPENING_PAD: { [string]: number } = { Grate = 0.5, Window = 0.5, Tower = 0.2 }

-- Props that stand against a wall (half their width along it): the wainscot leaves their wall bare.
local WALL_PROPS: { [string]: number } = { Locker = 1.65, FloodlightSwitch = 1.3, Terminal = 2.4 }
local WALL_PROP_REACH = 3.5

-- Along-wall cuts per wall line: every opening that reaches below the chair rail, padded by what frames it.
local function wainscotCuts(placed: { PlacedOpening }): { [string]: { Finishes.Interval } }
	local cuts: { [string]: { Finishes.Interval } } = {}
	for _, item in placed do
		local opening = item.opening
		if opening.y0 >= Finishes.RailTop + 0.05 then
			continue
		end
		local door = item.door
		local pad = if door then DOOR_FRAME_PAD[door.kind] or 0.4 else OPENING_PAD[item.kind] or 0.4
		local key = lineKey(item.axis, item.coord)
		local list = cuts[key]
		if not list then
			list = {}
			cuts[key] = list
		end
		table.insert(list, { u0 = opening.u0 - pad, u1 = opening.u1 + pad })
	end
	return cuts
end

type FaceSpan = { u0: number, u1: number, face: number, dir: number }

-- The wall faces of `room`'s side on `line`: the runs that look into the room, clipped to the room's inner faces
-- [lo, hi] and merged where neighbouring runs share a face.
local function sideFaces(room: Room, line: Line, lo: number, hi: number): { FaceSpan }
	local spans: { FaceSpan } = {}
	for _, run in line.runs do
		if run.low ~= room and run.high ~= room then
			continue
		end
		if run.height < Finishes.RailTop + 0.1 then
			continue
		end
		local isLow = run.low == room
		local a, b = math.max(run.from, lo), math.min(run.to, hi)
		if b - a <= EPS then
			continue
		end
		local face = if isLow then -run.thickness / 2 else run.thickness / 2
		local last = spans[#spans]
		if last and math.abs(last.u1 - a) < EPS and math.abs(last.face - face) < EPS then
			last.u1 = b
		else
			table.insert(spans, { u0 = a, u1 = b, face = face, dir = if isLow then -1 else 1 })
		end
	end
	table.sort(spans, function(x: FaceSpan, y: FaceSpan): boolean
		return x.u0 < y.u0
	end)
	return spans
end

local function buildWainscots(
	layout: Layout,
	origin: Vector3,
	shell: Folder,
	lines: { [string]: Line },
	placed: { PlacedOpening },
	exteriorSides: { [string]: { [string]: boolean } }
): number
	local cuts = wainscotCuts(placed)
	local count = 0
	for _, room in layout.rooms do
		local style = Finishes.wainscotStyle(layout.id, room, SchoolShellBuilder.wallKey(room))
		if not style then
			continue
		end
		local inner = innerRect(room, exteriorSides)
		for _, side: LayoutSchema.Side in SIDES do
			local axis: Axis, coord: number = sideLine(room.rect, side)
			local key = lineKey(axis, coord)
			local line = lines[key]
			if not line then
				continue
			end
			local lo = if axis == "Z" then inner.x else inner.z
			local hi = if axis == "Z" then inner.x + inner.w else inner.z + inner.d
			local faceAt = if side == "N"
				then inner.z
				elseif side == "S" then inner.z + inner.d
				elseif side == "W" then inner.x
				else inner.x + inner.w
			local sideCuts: { Finishes.Interval } = table.clone(cuts[key] or {})
			for _, anchor in layout.anchors do
				local half = WALL_PROPS[anchor.kind]
				if not half or anchor.room ~= room.id then
					continue
				end
				local acrossAt = if axis == "Z" then anchor.pos.Z else anchor.pos.X
				if math.abs(acrossAt - faceAt) <= WALL_PROP_REACH then
					local u = if axis == "Z" then anchor.pos.X else anchor.pos.Z
					table.insert(sideCuts, { u0 = u - half, u1 = u + half })
				end
			end
			for f, faceSpan in sideFaces(room, line, lo, hi) do
				for i, span in Finishes.subtract(faceSpan.u0, faceSpan.u1, sideCuts) do
					-- walls of constant Z stop short of the corners; walls of constant X own them
					local insetLo = axis == "Z" and math.abs(span.u0 - lo) < EPS
					local insetHi = axis == "Z" and math.abs(span.u1 - hi) < EPS
					count += Finishes.wainscot(
						shell,
						string.format("Wainscot_%s_%s%d_%d", room.id, side, f, i),
						origin,
						axis,
						coord,
						faceSpan.face,
						faceSpan.dir,
						span.u0,
						span.u1,
						style,
						insetLo,
						insetHi
					)
				end
			end
		end
	end
	return count
end

-- Striped floor plates either side of every airlock fire door and the hallway gate.
local HAZARD_DEPTH: { [string]: number } = { Airlock = 1.3, Gate = 1.1 }
local HAZARD_REACH: { [string]: number } = { Airlock = 0.9, Gate = 0.7 }

local function buildHazardPlates(layout: Layout, rooms: { [string]: Room }, origin: Vector3, shell: Folder): number
	local count = 0
	for _, door in layout.doors do
		local depth = HAZARD_DEPTH[door.kind]
		if not depth then
			continue
		end
		local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
		local edge = if a and b then LayoutSchema.sharedEdge(a.rect, b.rect) else nil
		if not edge then
			continue
		end
		local half = LayoutSchema.doorWidth(door) / 2 + HAZARD_REACH[door.kind]
		for _, s in { -1, 1 } do
			local face = s * WorldConfig.WallThickness / 2
			if
				Finishes.hazardPlate(
					shell,
					string.format("Hazard_%s_%s", door.id, if s < 0 then "Low" else "High"),
					origin,
					edge.axis,
					edge.coord,
					door.at - half,
					door.at + half,
					face,
					face + s * depth
				)
			then
				count += 1
			end
		end
	end
	return count
end

-- The world box of `room`'s ceiling panel and the fixtures hanging from it (which no missing tile may expose).
local function ceilingPanel(
	layout: Layout,
	room: Room,
	origin: Vector3,
	exteriorSides: { [string]: { [string]: boolean } }
): (Vector3, Vector3, { Finishes.Keepout })
	local h = LayoutSchema.roomHeight(layout, room)
	local r = innerRect(room, exteriorSides)
	local keepouts: { Finishes.Keepout } = {}
	local along = SchoolShellBuilder.fixtureAlong(room)
	for _, light in (room.lights or {}) :: { LayoutSchema.Light } do
		local lo, hi = SchoolShellBuilder.fixtureBox(light.kind, light.pos, h - CEILING, along)
		table.insert(keepouts, {
			x0 = origin.X + lo.X - 0.3,
			x1 = origin.X + hi.X + 0.3,
			z0 = origin.Z + lo.Z - 0.3,
			z1 = origin.Z + hi.Z + 0.3,
		})
	end
	return origin + Vector3.new(r.x, h - CEILING, r.z), origin + Vector3.new(r.x + r.w, h, r.z + r.d), keepouts
end

export type CeilingFall = {
	room: string,
	centre: Vector3, -- world: the underside of the missing tile
	size: Vector2, -- the tile (X, Z)
}

-- The dressed holes of every drop ceiling of `layout` (Finishes.planCeiling's first holes, built as void plates):
-- where DecayBuilder lays the fallen tiles and hangs the wiring. Pure layout maths, the same answer the build used.
function SchoolShellBuilder.ceilingFalls(layout: Layout): { CeilingFall }
	local out: { CeilingFall } = {}
	local origin = WorldConfig.levelOrigin(layout.id)
	local exteriorSides = SchoolShellBuilder.exteriorSides(layout)
	for _, room in layout.rooms do
		if not (hasCeiling(room) and Finishes.dropCeiling(room, SchoolShellBuilder.ceilingKey(room))) then
			continue
		end
		local lo, hi, keepouts = ceilingPanel(layout, room, origin, exteriorSides)
		local size = hi - lo
		if size.X < EPS or size.Z < EPS then
			continue
		end
		local cframe = CFrame.new((lo + hi) / 2)
		local plan = Finishes.planCeiling(layout.id, room, cframe, size, keepouts)
		for index = 1, plan.dressed do
			table.insert(out, {
				room = room.id,
				centre = Finishes.cellCentre(cframe, size, plan, plan.holes[index]),
				size = Vector2.new(size.X / plan.cols, size.Z / plan.rows),
			})
		end
	end
	return out
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

	-- Floors (= the structural slab), ceilings, roof caps. Each room's floor covers its own rect. Where a side is
	-- exterior the slab continues under the outer half of the footprint wall as a separate slab-edge strip, so the
	-- band on the facade between storeys is one material all round (never the room's carpet, tile or gravel).
	-- Chase floors leave room for any duct that sits low in its chase (down through the slab to a waterline).
	local exteriorSides = SchoolShellBuilder.exteriorSides(layout)
	local slabEdgeKey = options.slabEdgeKey or SLAB_EDGE_KEY
	local ductHoles: { Rect } = {}
	for _, envelope in VentShaftBuilder.envelopes(layout) do
		if envelope.y0 < -EPS and envelope.y1 > -slab + EPS then
			table.insert(
				ductHoles,
				Geometry.rect(envelope.x0, envelope.z0, envelope.x1 - envelope.x0, envelope.z1 - envelope.z0)
			)
		end
	end
	for _, room in layout.rooms do
		local holes: { Rect } = {}
		for _, basin in (basinsByRoom[room.id] or {}) :: { LayoutSchema.Basin } do
			table.insert(holes, basin.rect)
		end
		if room.kind == "Chase" then
			for _, hole in ductHoles do
				table.insert(holes, hole)
			end
		end
		local floorKey = SchoolShellBuilder.floorKey(room)
		for i, piece in Geometry.subtractRects(room.rect, holes) do
			local floor = Geometry.box(
				shell,
				string.format("Floor_%s_%d", room.id, i),
				origin + Vector3.new(piece.x, -slab, piece.z),
				origin + Vector3.new(piece.x + piece.w, 0, piece.z + piece.d),
				floorKey
			)
			if floor then
				Finishes.decorateFloor(floor, levelId, room, floorKey)
			end
		end
		local edgeHoles = table.clone(holes)
		table.insert(edgeHoles, room.rect)
		for i, piece in Geometry.subtractRects(floorRect(room, exteriorSides), edgeHoles) do
			Geometry.box(
				shell,
				string.format("SlabEdge_%s_%d", room.id, i),
				origin + Vector3.new(piece.x, -slab, piece.z),
				origin + Vector3.new(piece.x + piece.w, 0, piece.z + piece.d),
				slabEdgeKey
			)
		end
		if hasCeiling(room) then
			local h = LayoutSchema.roomHeight(layout, room)
			local ceilingKey = SchoolShellBuilder.ceilingKey(room)
			local lo, hi, keepouts = ceilingPanel(layout, room, origin, exteriorSides)
			local ceiling = Geometry.box(shell, "Ceiling_" .. room.id, lo, hi, ceilingKey, { castShadow = true })
			if ceiling then
				Finishes.decorateCeiling(ceiling, levelId, room, ceilingKey, keepouts)
			end
			if not options.hasLevelAbove then
				local r0 = room.rect
				Geometry.box(
					shell,
					"Roof_" .. room.id,
					origin + Vector3.new(r0.x, h, r0.z),
					origin + Vector3.new(r0.x + r0.w, h + slab, r0.z + r0.d),
					if options.isSchool then "RoofGravel" else "ConcreteDark"
				)
				for i, piece in Geometry.subtractRects(floorRect(room, exteriorSides), { r0 }) do
					Geometry.box(
						shell,
						string.format("RoofEdge_%s_%d", room.id, i),
						origin + Vector3.new(piece.x, h, piece.z),
						origin + Vector3.new(piece.x + piece.w, h + slab, piece.z + piece.d),
						slabEdgeKey
					)
				end
			end
		end
	end

	-- Walls with every opening cut
	local lines, order = collectLines(layout)
	for _, key in order do
		buildRuns(layout, lines[key], options)
	end
	local placed = planOpenings(layout, rooms, lines)
	buildWalls(origin, shell, lines, order, wearContext(layout, exteriorSides))
	buildWainscots(layout, origin, shell, lines, placed, exteriorSides)
	buildHazardPlates(layout, rooms, origin, shell)

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

	-- Platforms, clipped to the room's wall faces so a platform laid against a wall never sinks into it. One whose
	-- top is at or below the deck only shows over open water, so it is clipped to the basin interiors as well: it
	-- never shares the deck's or the coping's top face (z-fighting) or buries itself in them.
	local basinInteriors: { Rect } = {}
	for _, basin in (layout.basins or {}) :: { LayoutSchema.Basin } do
		table.insert(basinInteriors, Geometry.insetRect(basin.rect, BASIN_WALL))
	end
	for _, platform in (layout.platforms or {}) :: { LayoutSchema.Platform } do
		local room = rooms[platform.room]
		local clipped = if room
			then Geometry.rectIntersection(platform.rect, innerRect(room, exteriorSides))
			else platform.rect
		if not clipped then
			continue
		end
		local pieces: { Rect } = { clipped }
		if platform.top <= EPS then
			local wet: { Rect } = {}
			for _, interior in basinInteriors do
				local cut = Geometry.rectIntersection(clipped, interior)
				if cut then
					table.insert(wet, cut)
				end
			end
			if #wet > 0 then
				pieces = wet
			end
		end
		for i, r in pieces do
			Geometry.box(
				shell,
				if i == 1 then "Platform_" .. platform.id else string.format("Platform_%s_%d", platform.id, i),
				origin + Vector3.new(r.x, platform.top - platform.thickness, r.z),
				origin + Vector3.new(r.x + r.w, platform.top, r.z + r.d),
				platform.material or "ConcreteStained"
			)
		end
	end

	-- Pool basins: shell down to `depth` (its coping cut wherever a grate opens over the pool), a murky surface,
	-- and a PoolWater volume
	local tunnels = grateTunnels(layout, rooms)
	for _, basin in (layout.basins or {}) :: { LayoutSchema.Basin } do
		local r = basin.rect
		local depth = basin.depth
		local wall = BASIN_WALL
		local halfWall = wall / 2
		Geometry.box(
			shell,
			basin.id .. "_Floor",
			origin + Vector3.new(r.x, -depth - 1, r.z),
			origin + Vector3.new(r.x + r.w, -depth, r.z + r.d),
			"PoolTile"
		)
		local sides: { BasinSide } = {
			{ axis = "Z", coord = r.z + halfWall, u0 = r.x, u1 = r.x + r.w },
			{ axis = "Z", coord = r.z + r.d - halfWall, u0 = r.x, u1 = r.x + r.w },
			{ axis = "X", coord = r.x + halfWall, u0 = r.z + wall, u1 = r.z + r.d - wall },
			{ axis = "X", coord = r.x + r.w - halfWall, u0 = r.z + wall, u1 = r.z + r.d - wall },
		}
		for i, side in sides do
			local alongX = side.axis == "Z"
			local sx0 = if alongX then side.u0 else side.coord - halfWall
			local sx1 = if alongX then side.u1 else side.coord + halfWall
			local sz0 = if alongX then side.coord - halfWall else side.u0
			local sz1 = if alongX then side.coord + halfWall else side.u1
			local openings: { Geometry.Opening } = {}
			for _, tunnel in tunnels do
				local through = math.min(tunnel.x1, sx1) - math.max(tunnel.x0, sx0) > EPS
					and math.min(tunnel.z1, sz1) - math.max(tunnel.z0, sz0) > EPS
					and math.min(tunnel.y1, 0) - math.max(tunnel.y0, -depth) > EPS
				if through then
					table.insert(openings, {
						u0 = if alongX then tunnel.x0 else tunnel.z0,
						u1 = if alongX then tunnel.x1 else tunnel.z1,
						y0 = tunnel.y0,
						y1 = tunnel.y1,
					})
				end
			end
			for k, piece in Geometry.splitWall(side.u0, side.u1, -depth, 0, openings) do
				Geometry.wallBox(
					shell,
					if k == 1
						then string.format("%s_Wall%d", basin.id, i)
						else string.format("%s_Wall%d_%d", basin.id, i, k),
					origin,
					side.axis,
					side.coord,
					piece.u0,
					piece.u1,
					piece.y0,
					piece.y1,
					-halfWall,
					halfWall,
					"PoolTile"
				)
			end
		end
		local inner = Geometry.insetRect(r, wall)
		local surface = Geometry.box(
			shell,
			basin.id .. "_Surface",
			origin + Vector3.new(inner.x, basin.waterLevel - WATER_SURFACE, inner.z),
			origin + Vector3.new(inner.x + inner.w, basin.waterLevel, inner.z + inner.d),
			"Water",
			WATER_OPTIONS
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

	-- Triggers. A PoolWater volume the layout places itself also gets a murky surface at its top, over the part of
	-- it that is open water: not over a basin (which draws its own surface) and not in a chase (water standing in a
	-- duct, which VentShaftBuilder floods inside the bore).
	local notOpenWater: { Rect } = {}
	for _, room in layout.rooms do
		if room.kind == "Chase" then
			table.insert(notOpenWater, room.rect)
		end
	end
	for _, basin in (layout.basins or {}) :: { LayoutSchema.Basin } do
		table.insert(notOpenWater, basin.rect)
	end
	for _, trigger in layout.triggers do
		local r = trigger.rect
		local y = trigger.y or 0
		if trigger.kind == "PoolWater" and trigger.height > EPS then
			local room = rooms[trigger.room]
			local area = if room then Geometry.rectIntersection(r, innerRect(room, exteriorSides)) else r
			if area then
				local top = y + trigger.height
				for i, piece in Geometry.subtractRects(area, notOpenWater) do
					local surface = Geometry.box(
						shell,
						if i == 1 then trigger.id .. "_Surface" else string.format("%s_Surface%d", trigger.id, i),
						origin + Vector3.new(piece.x, top - math.min(WATER_SURFACE, trigger.height), piece.z),
						origin + Vector3.new(piece.x + piece.w, top, piece.z + piece.d),
						"Water",
						WATER_OPTIONS
					)
					if surface then
						Geometry.makeFixture(surface)
					end
				end
			end
		end
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

	-- Lights. Each level's mood decides which burn and casts its colour over them; a broken fixture only sags out of
	-- its mounts in a room without a drip pipe (whose run passes just under the fixtures).
	local dripRooms: { [string]: boolean } = {}
	for _, anchor in layout.anchors do
		if anchor.kind == "DripPipe" then
			dripRooms[anchor.room] = true
		end
	end
	for _, room in layout.rooms do
		local cx, cz = roomCenter(room)
		local ceilingY = origin.Y + SchoolShellBuilder.ceilingBottom(layout, room)
		local along = SchoolShellBuilder.fixtureAlong(room)
		for _, light in (room.lights or {}) :: { LayoutSchema.Light } do
			local mood = LightingMood.resolve(layout.id, room.id, light)
			local base = light.color or LIGHT_COLORS[light.kind] or Color3.new(1, 1, 1)
			SchoolShellBuilder.buildLight(folders.Lights, {
				id = light.id,
				kind = light.kind,
				position = origin + light.pos,
				brightness = mood.brightness,
				range = mood.range,
				color = LightingMood.cast(layout.id, room.id, light.kind, base),
				along = along,
				hang = not dripRooms[room.id],
				flickerGroup = mood.flickerGroup,
				broken = mood.broken,
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

	-- Invisible walls around the edge of the ground slab, so nobody walks off the end of the world (a fall past
	-- FallenPartsDestroyHeight leaves a player with no character). Default group so characters and the Creature
	-- collide with them; never queried (cameras, sight lines and flasks ignore them), never rendered or shadowed.
	local t = ext.boundaryThickness
	local y0, y1 = groundY - ext.groundThickness, groundY + ext.boundaryHeight
	local boundaries: { BoundaryWall } = {
		{ name = "Boundary_N", x0 = ext.minX - t, z0 = ext.minZ - t, x1 = ext.maxX + t, z1 = ext.minZ },
		{ name = "Boundary_S", x0 = ext.minX - t, z0 = ext.maxZ, x1 = ext.maxX + t, z1 = ext.maxZ + t },
		{ name = "Boundary_W", x0 = ext.minX - t, z0 = ext.minZ, x1 = ext.minX, z1 = ext.maxZ },
		{ name = "Boundary_E", x0 = ext.maxX, z0 = ext.minZ, x1 = ext.maxX + t, z1 = ext.maxZ },
	}
	for _, wall in boundaries do
		Geometry.box(
			parent,
			wall.name,
			Vector3.new(wall.x0, y0, wall.z0),
			Vector3.new(wall.x1, y1, wall.z1),
			"Concrete",
			{ transparency = 1, canCollide = true, canQuery = false, castShadow = false }
		)
	end

	return Geometry.partsCreated() - before
end

return table.freeze(SchoolShellBuilder)
