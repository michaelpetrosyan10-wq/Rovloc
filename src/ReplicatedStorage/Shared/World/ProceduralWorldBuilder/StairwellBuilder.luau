--!strict
-- Stair towers outside the footprint. Each WorldConfig.Stairwells entry is one enclosed concrete shaft segment
-- from the lower level's floor to the upper level's ceiling, holding real switchback stairs around a solid core:
--
--      building side (u = 0)                                outer wall
--      | near landing |  flight 1, 3, ... (north band, climbing out) | far landing |
--      |  (opening)   |  ===================== solid core ========== |             |
--      |              |  flight 2, 4, ... (south band, climbing in)  |             |
--
-- Odd flights climb away from the building in the north band, even flights climb back in the south band, so the
-- last flight always arrives at the near landing beside the upper TowerOpening. Steps rise at most 1 stud and run
-- at least 1.6 (Humanoids walk up them). Segments that share a tower stack without overlapping: a segment's
-- floor slab sits exactly on top of the walls of the segment below it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(script.Parent.Geometry)
local SchoolShellBuilder = require(script.Parent.SchoolShellBuilder)

local log = Log.new("Stairwells")

type Layout = LayoutSchema.LevelLayout

local W = Attributes.World
local Names = Instances.Names

local EPS = 1e-3
local TOWER_WALL = 1
local LANDING = 5 -- landing depth at both ends of the flights
local FLIGHT_WIDTH = 10
local MAX_RISE = 1
local MIN_RUN = 1.6
local LANDING_THICKNESS = 1
local STEP_UNDERSIDE = 0.6
local DEFAULT_TOP_ROOM_HEIGHT = 12

export type SegmentPlan = {
	spec: WorldConfig.StairwellSpec,
	bottom: number, -- world Y of the lower floor surface
	top: number, -- world Y of the upper level's ceiling (top of the shaft walls)
	rise: number,
	flights: number,
	risers: number, -- per flight
	stepRise: number,
	stepRun: number,
	slabFromBuilding: number, -- u where this segment's floor slab starts (the school slab band covers u < it)
	topmost: boolean, -- no segment above it in the same tower (gets a roof cap + parapet)
}

local StairwellBuilder = {}

StairwellBuilder.FlightWidth = FLIGHT_WIDTH
StairwellBuilder.LandingDepth = LANDING

local function upperCeiling(spec: WorldConfig.StairwellSpec, layouts: { [string]: Layout }): number
	local elevation = WorldConfig.levelElevation(spec.to)
	local level = WorldConfig.Levels[spec.to]
	if level and level.height > EPS then
		return elevation + level.height
	end
	local layout = layouts[spec.to]
	if layout then
		for _, room in layout.rooms do
			if room.id == spec.toRoom then
				return elevation + LayoutSchema.roomHeight(layout, room)
			end
		end
		if layout.height > EPS then
			return elevation + layout.height
		end
	end
	return elevation + DEFAULT_TOP_ROOM_HEIGHT
end

local function towerDims(side: WorldConfig.TowerSide)
	local tower = WorldConfig.Towers[side]
	local depth = tower.maxX - tower.minX
	local halfExt = WorldConfig.ExteriorWallThickness / 2
	return {
		tower = tower,
		depth = depth,
		edgeX = if side == "East" then tower.minX else tower.maxX,
		dirX = if side == "East" then 1 else -1,
		halfExt = halfExt,
		uInner0 = halfExt + TOWER_WALL,
		uInner1 = depth - TOWER_WALL,
		vInner0 = tower.minZ + TOWER_WALL,
		vInner1 = tower.maxZ - TOWER_WALL,
	}
end

-- Pure planning (specs use it): the stair geometry numbers for every segment.
function StairwellBuilder.plan(layouts: { [string]: Layout }): { SegmentPlan }
	local plans: { SegmentPlan } = {}
	for _, spec in WorldConfig.Stairwells do
		local dims = towerDims(spec.tower)
		local bottom = WorldConfig.levelElevation(spec.from)
		local top = upperCeiling(spec, layouts)
		local rise = WorldConfig.levelElevation(spec.to) - bottom
		local runLength = (dims.uInner1 - dims.uInner0) - LANDING * 2
		local maxRisersPerFlight = math.max(1, math.floor(runLength / MIN_RUN + EPS))
		local maxFlightRise = maxRisersPerFlight * MAX_RISE
		local flights = 2 * math.max(1, math.ceil(rise / (2 * maxFlightRise) - EPS))
		local flightRise = rise / flights
		local risers = math.max(1, math.ceil(flightRise / MAX_RISE - EPS))
		table.insert(plans, {
			spec = spec,
			bottom = bottom,
			top = top,
			rise = rise,
			flights = flights,
			risers = risers,
			stepRise = flightRise / risers,
			stepRun = runLength / risers,
			slabFromBuilding = dims.halfExt,
			topmost = true,
		})
	end
	for _, plan in plans do
		for _, other in plans do
			if other ~= plan and other.spec.tower == plan.spec.tower and other.bottom > plan.bottom then
				plan.topmost = false
			end
		end
	end
	return plans
end

local function setAttributes(instance: Instance, values: { [string]: any })
	for key, value in values do
		instance:SetAttribute(key, value)
	end
end

local function buildSegment(plan: SegmentPlan, parent: Instance): Model
	local spec = plan.spec
	local dims = towerDims(spec.tower)
	local model = Instance.new("Model")
	model.Name = spec.id
	model:SetAttribute(W.FromLevel, spec.from)
	model:SetAttribute(W.ToLevel, spec.to)
	local shell = Geometry.folder(model, Names.Shell)
	local lights = Geometry.folder(model, Names.Lights)
	local zones = Geometry.folder(model, Names.Zones)

	local slab = WorldConfig.SlabThickness
	local tower = dims.tower
	local function worldX(u: number): number
		return dims.edgeX + dims.dirX * u
	end
	local function box(
		name: string,
		u0: number,
		u1: number,
		y0: number,
		y1: number,
		v0: number,
		v1: number,
		key: string
	): Part?
		return Geometry.box(shell, name, Vector3.new(worldX(u0), y0, v0), Vector3.new(worldX(u1), y1, v1), key)
	end

	local bottom, top = plan.bottom, plan.top
	local upper = bottom + plan.rise

	-- Floor slab and enclosure
	box("Floor", plan.slabFromBuilding, dims.depth, bottom - slab, bottom, tower.minZ, tower.maxZ, "ConcreteDark")
	box("WallNorth", dims.halfExt, dims.depth, bottom, top, tower.minZ, tower.minZ + TOWER_WALL, "ConcreteDark")
	box("WallSouth", dims.halfExt, dims.depth, bottom, top, tower.maxZ - TOWER_WALL, tower.maxZ, "ConcreteDark")
	box("WallOuter", dims.depth - TOWER_WALL, dims.depth, bottom, top, dims.vInner0, dims.vInner1, "ConcreteDark")
	local opening = WorldConfig.TowerOpening
	local openings: { Geometry.Opening } = {}
	for _, y in { bottom, upper } do
		table.insert(openings, {
			u0 = opening.centerZ - opening.width / 2,
			u1 = opening.centerZ + opening.width / 2,
			y0 = y,
			y1 = y + opening.height,
		})
	end
	for i, piece in Geometry.splitWall(dims.vInner0, dims.vInner1, bottom, top, openings) do
		box(
			string.format("WallBuilding_%d", i),
			dims.halfExt,
			dims.uInner0,
			piece.y0,
			piece.y1,
			piece.u0,
			piece.u1,
			"ConcreteDark"
		)
	end
	if plan.topmost then
		box("Cap", dims.halfExt, dims.depth, top, top + slab, tower.minZ, tower.maxZ, "RoofGravel")
		local lipTop = top + slab + WorldConfig.ParapetHeight
		box("ParapetNorth", dims.halfExt, dims.depth, top + slab, lipTop, tower.minZ, tower.minZ + TOWER_WALL, "Brick")
		box("ParapetSouth", dims.halfExt, dims.depth, top + slab, lipTop, tower.maxZ - TOWER_WALL, tower.maxZ, "Brick")
		box(
			"ParapetOuter",
			dims.depth - TOWER_WALL,
			dims.depth,
			top + slab,
			lipTop,
			dims.vInner0,
			dims.vInner1,
			"Brick"
		)
	end

	-- Solid core between the two flight bands
	local nearEnd = dims.uInner0 + LANDING
	local farStart = dims.uInner1 - LANDING
	local northBand0, northBand1 = dims.vInner0, dims.vInner0 + FLIGHT_WIDTH
	local southBand0, southBand1 = dims.vInner1 - FLIGHT_WIDTH, dims.vInner1
	if southBand0 - northBand1 > EPS then
		box("Core", nearEnd, farStart, bottom, top, northBand1, southBand0, "Concrete")
	end

	-- Flights and landings
	local flightRise = plan.rise / plan.flights
	for k = 1, plan.flights do
		local start = bottom + (k - 1) * flightRise
		local outbound = k % 2 == 1
		local u = if outbound then nearEnd else farStart
		local v = if outbound then (northBand0 + northBand1) / 2 else (southBand0 + southBand1) / 2
		local direction = Vector3.new(dims.dirX * (if outbound then 1 else -1), 0, 0)
		Geometry.stairFlight({
			parent = shell,
			name = string.format("Flight%d", k),
			start = Vector3.new(worldX(u), start, v),
			direction = direction,
			width = FLIGHT_WIDTH,
			risers = plan.risers,
			rise = plan.stepRise,
			run = plan.stepRun,
			underside = STEP_UNDERSIDE,
			floor = if k == 1 then bottom else nil,
			key = "Concrete",
		})
		local arrive = start + flightRise
		if outbound then
			box(
				string.format("LandingFar%d", (k + 1) // 2),
				farStart,
				dims.uInner1,
				arrive - LANDING_THICKNESS,
				arrive,
				dims.vInner0,
				dims.vInner1,
				"ConcreteStained"
			)
		else
			box(
				string.format("LandingNear%d", k // 2),
				dims.uInner0,
				nearEnd,
				arrive - LANDING_THICKNESS,
				arrive,
				dims.vInner0,
				dims.vInner1,
				"ConcreteStained"
			)
		end
	end
	if plan.stepRun < MIN_RUN - EPS or plan.stepRise > MAX_RISE + EPS then
		log.warn(
			"%s: steps are %.2f high x %.2f deep (limits %.1f x %.1f)",
			spec.id,
			plan.stepRise,
			plan.stepRun,
			MAX_RISE,
			MIN_RUN
		)
	end

	-- Emergency lighting: above each building-side opening / landing, and on the outer wall at each far landing
	local random = MathUtil.seededRandom(1, spec.id)
	local centre = Vector3.new(worldX((dims.uInner0 + dims.uInner1) / 2), bottom, opening.centerZ)
	local index = 0
	local working = 0
	local function addLight(position: Vector3)
		index += 1
		local broken = random:NextNumber() < 0.35 and working > 0
		if not broken then
			working += 1
		end
		SchoolShellBuilder.buildLight(lights, {
			id = string.format("%s_Light%d", spec.id, index),
			kind = "EmergencyRed",
			position = position,
			brightness = 0.9,
			range = 22,
			flickerGroup = spec.id,
			broken = broken,
			levelId = spec.from,
			zoneId = spec.id,
			facing = Vector3.new(centre.X, position.Y, centre.Z),
		})
	end
	addLight(Vector3.new(worldX(dims.uInner0 + 0.4), bottom + opening.height + 1, opening.centerZ))
	for k = 1, plan.flights do
		local arrive = bottom + k * flightRise
		if k % 2 == 1 then
			addLight(Vector3.new(worldX(dims.uInner1 - 0.4), arrive + 7, opening.centerZ))
		else
			addLight(Vector3.new(worldX(dims.uInner0 + 0.4), arrive + opening.height + 1, opening.centerZ))
		end
	end

	-- Zone volume (stairwell acoustics)
	local zone = Geometry.box(
		zones,
		spec.id,
		Vector3.new(worldX(dims.uInner0), bottom, dims.vInner0),
		Vector3.new(worldX(dims.uInner1), top, dims.vInner1),
		"Concrete"
	)
	if zone then
		Geometry.makeVolume(zone)
		zone:AddTag(Tags.Zone)
		setAttributes(zone, {
			[W.ZoneId] = spec.id,
			[W.LevelId] = spec.from,
			[W.RoomKind] = "Stairwell",
			[W.AcousticPreset] = "Stairwell",
			[W.Surface] = "Concrete",
		})
	end

	model.Parent = parent
	return model
end

-- Builds School.Stairwells. `only` restricts to stairwells touching those level ids (nil = all).
function StairwellBuilder.build(school: Model, layouts: { [string]: Layout }, only: { [string]: boolean }?): Model
	local existing = school:FindFirstChild(Names.Stairwells)
	if existing then
		existing:Destroy()
	end
	local container = Instance.new("Model")
	container.Name = Names.Stairwells
	for _, plan in StairwellBuilder.plan(layouts) do
		if only and not (only[plan.spec.from] or only[plan.spec.to]) then
			continue
		end
		buildSegment(plan, container)
	end
	container.Parent = school
	return container
end

return table.freeze(StairwellBuilder)
