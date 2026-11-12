--!strict
-- TunnelDressingBuilder: the dressing of a tunnel floor (TunnelPlanner), static kind "TunnelDressing": built once at
-- boot into <level>.Props as one Model "Tunnels_<layoutId>", the same on every server. Every piece is non-colliding,
-- never queried and never touched, and every piece but the landmarks a player navigates by carries
-- Attributes.World.Detail (1 shapes the tunnel's look .. 3 small), so a low graphics setting may hide it; nothing
-- here is collision or nav geometry.
--
--   * Service pipes along every tunnel and gallery: a main, a branch and a conduit hung under the ceiling against one
--     side wall (galleries: both), painted in their region's colour with paint bands (TunnelData regions: pipe, band),
--     each run ending in an elbow into the wall a stud short of the run's ends, on hangers; stencilled markers on the
--     main name what it carries (the region's `medium`) with a flow arrow.
--   * A cable tray along the other wall of every tunnel and gallery, on hangers.
--   * Steam vents: relief valves teed off the main (in the steam region at every stretch, elsewhere now and then),
--     each with a handwheel and a nozzle leaking a plume (a "Steam" ParticleEmitter under the nozzle, tagged
--     SteamVent) and a wet stain on the floor below.
--   * Grime: rust and water runs down the walls under the pipes.
--   * Landmarks (TunnelData.landmarks), baked as decals: enamel junction plates ("J-07"), region names stencilled at
--     region entrances and keep-room names by their doors, spray-painted lore lines and tags, tally marks and arrows
--     toward the stairs. The paint sits on an invisible, non-colliding plate on the wall face (a decal host; the
--     export keeps a transparent part that carries a SurfaceGui), legible in a torch beam (LightInfluence 1). Plates,
--     stencils and arrows stay at every setting (players find their way by them); lore, tallies and tags are Detail.
--   * Floor: drain grates at the junctions of wet regions, puddles along their tunnels, coal spilled in the coal
--     chutes, rubble at the dead ends, and heaps of debris (brick, broken block, cans, paper) against the walls, kept
--     off every doorway, anchor and trigger.
-- Deterministic: seeded by layout and room ids.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Rng = require(ReplicatedStorage.Shared.Util.Rng)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(script.Parent.Parent.Geometry)
local PropKit = require(script.Parent.PropKit)
local SurfaceArt = require(script.Parent.Parent.SurfaceArt)

type Rng = Rng.Rng
type Layout = LayoutSchema.LevelLayout
type Room = LayoutSchema.Room
type Region = LayoutSchema.TunnelRegion
type Landmark = LayoutSchema.Landmark
type Span = { number }

local TunnelDressingBuilder = {}

TunnelDressingBuilder.Kind = "TunnelDressing"

-- Detail levels (Attributes.World.Detail)
local LOOK, MEDIUM, SMALL = 1, 2, 3
TunnelDressingBuilder.DetailLevels = table.freeze({ Look = LOOK, Medium = MEDIUM, Small = SMALL })

local EPS = 1e-3
local WALL = WorldConfig.WallThickness
local EXTERIOR = WorldConfig.ExteriorWallThickness
local BAND_SPACING = 9
local HANGER_SPACING = 11
local TRAY_HANGER_SPACING = 6
local MARKER_SPACING = 23
local VENT_SPACING = 34 -- the steam region: one relief valve per this much tunnel
local VENT_CHANCE = 0.22 -- elsewhere: a run's chance of one
local DEBRIS_SPACING = 26
local GALVANIZED = Color3.fromRGB(118, 124, 126)
local IRON = Color3.fromRGB(46, 47, 48)
local VALVE_RED = Color3.fromRGB(150, 32, 26)
local PLATE = Color3.fromRGB(22, 34, 52) -- enamel junction plate
local PLATE_INK = Color3.fromRGB(228, 226, 214)
local CABLE = Color3.fromRGB(24, 24, 22)
local BLOCK = Color3.fromRGB(74, 76, 78)
local PAPER = Color3.fromRGB(196, 188, 164)
local CANS: { Color3 } = {
	Color3.fromRGB(86, 72, 70),
	Color3.fromRGB(66, 76, 70),
	Color3.fromRGB(120, 122, 118),
	Color3.fromRGB(104, 98, 82),
}
local STEAM = Color3.fromRGB(214, 214, 208)

-- A decorative part (or nil): non-colliding, never queried or touched, tagged with its Detail level.
local function decor(part: BasePart?, level: number): BasePart?
	if part then
		PropKit.decor(part, level)
	end
	return part
end

--------------------------------------------------------------------------------
-- A run's frame: its axis, extent, walls and what already uses them
--------------------------------------------------------------------------------

type Run = {
	room: Room,
	axis: "X" | "Z",
	lo: number, -- along the axis
	hi: number,
	cross: number, -- the centre line across
	width: number,
	ceiling: number, -- the ceiling panel's underside
	region: Region,
	pipeSide: number, -- -1 / +1: the wall the pipes hang on (the tray hangs on the other)
	gallery: boolean,
	busy: { [number]: { Span } }, -- per side: spans along the wall taken by openings and landmarks
	floorBusy: { { x0: number, z0: number, x1: number, z1: number } }, -- level-local: anchors, triggers, openings
	random: Rng,
}

-- The inner face coordinate of `room`'s wall on `side` (-1 low, +1 high) across axis `axis` (the run's long axis).
local function wallFace(room: Room, axis: "X" | "Z", side: number): number
	local r = room.rect
	local size = WorldConfig.FootprintSize
	local line = if axis == "X" then (if side < 0 then r.z else r.z + r.d) else (if side < 0 then r.x else r.x + r.w)
	local limit = if axis == "X" then size.Y else size.X
	local t = if line < EPS or line > limit - EPS then EXTERIOR else WALL
	return line - side * t / 2
end

-- World point at `u` along the run, height `y`, `off` studs out from the wall on `side`.
local function onWall(origin: Vector3, run: Run, side: number, u: number, y: number, off: number): Vector3
	local across = wallFace(run.room, run.axis, side) - side * off
	if run.axis == "X" then
		return origin + Vector3.new(u, y, across)
	end
	return origin + Vector3.new(across, y, u)
end

-- Unit vector from the wall on `side` into the run.
local function inward(run: Run, side: number): Vector3
	if run.axis == "X" then
		return Vector3.new(0, 0, -side)
	end
	return Vector3.new(-side, 0, 0)
end

local function alongAxis(run: Run): Vector3
	return if run.axis == "X" then Vector3.xAxis else Vector3.zAxis
end

local function spanFree(list: { Span }?, u0: number, u1: number): boolean
	local spans: { Span } = list or {}
	for _, s in spans do
		if u1 > s[1] and u0 < s[2] then
			return false
		end
	end
	return true
end

local function markBusy(run: Run, side: number, u0: number, u1: number)
	local list = run.busy[side]
	if not list then
		list = {}
		run.busy[side] = list
	end
	table.insert(list, { u0, u1 })
end

local function floorFree(run: Run, x0: number, z0: number, x1: number, z1: number): boolean
	for _, b in run.floorBusy do
		if x1 > b.x0 and x0 < b.x1 and z1 > b.z0 and z0 < b.z1 then
			return false
		end
	end
	return true
end

local function buildRuns(layout: Layout, regions: { [string]: Region }): { Run }
	local tunnels = layout.tunnels
	if not tunnels then
		return {}
	end
	local rooms = LayoutSchema.indexRooms(layout)
	local out: { Run } = {}
	local byRoom: { [string]: Run } = {}
	for _, seg in tunnels.segments do
		if seg.kind ~= "Tunnel" and seg.kind ~= "Gallery" then
			continue
		end
		local room = rooms[seg.room]
		local region = regions[seg.region]
		if not room or not region or byRoom[room.id] then
			continue
		end
		local axis: "X" | "Z" = if math.abs(seg.az - seg.bz) < EPS then "X" else "Z"
		local r = room.rect
		local run: Run = {
			room = room,
			axis = axis,
			lo = if axis == "X" then r.x else r.z,
			hi = if axis == "X" then r.x + r.w else r.z + r.d,
			cross = if axis == "X" then r.z + r.d / 2 else r.x + r.w / 2,
			width = if axis == "X" then r.d else r.w,
			ceiling = LayoutSchema.roomHeight(layout, room) - 0.4,
			region = region,
			pipeSide = if MathUtil.hash(room.id) % 2 == 0 then -1 else 1,
			gallery = seg.kind == "Gallery",
			busy = {},
			floorBusy = {},
			random = Rng.seeded(1, layout.id .. ":dress:" .. room.id),
		}
		table.insert(out, run)
		byRoom[room.id] = run
	end
	-- openings in the side walls (and a stud either side), and the floor in front of every opening
	for _, door in layout.doors do
		for _, id in door.rooms do
			local run = byRoom[id]
			local otherId = if door.rooms[1] == id then door.rooms[2] else door.rooms[1]
			local other = rooms[otherId]
			if not run or not other then
				continue
			end
			local edge = LayoutSchema.sharedEdge(run.room.rect, other.rect)
			if not edge then
				continue
			end
			local half = LayoutSchema.doorWidth(door) / 2
			local r = run.room.rect
			-- an edge "X" is a line of constant x: a side wall of a run along Z
			if (edge.axis == "X") == (run.axis == "Z") then
				local side = if math.abs(edge.coord - (if run.axis == "X" then r.z else r.x)) < EPS then -1 else 1
				markBusy(run, side, door.at - half - 1, door.at + half + 1)
				local face = wallFace(run.room, run.axis, side)
				local depth = 3.5
				if run.axis == "X" then
					local z0, z1 = math.min(face, face - side * depth), math.max(face, face - side * depth)
					table.insert(run.floorBusy, { x0 = door.at - half - 1, z0 = z0, x1 = door.at + half + 1, z1 = z1 })
				else
					local x0, x1 = math.min(face, face - side * depth), math.max(face, face - side * depth)
					table.insert(run.floorBusy, { x0 = x0, z0 = door.at - half - 1, x1 = x1, z1 = door.at + half + 1 })
				end
			end
		end
	end
	-- landmarks on the side walls
	for _, landmark in tunnels.landmarks do
		local run = byRoom[landmark.room]
		if not run then
			continue
		end
		local u = if run.axis == "X" then landmark.pos.X else landmark.pos.Z
		local c = if run.axis == "X" then landmark.pos.Z else landmark.pos.X
		local side = if c < run.cross then -1 else 1
		markBusy(run, side, u - landmark.width / 2 - 0.4, u + landmark.width / 2 + 0.4)
	end
	-- the floor around anchors and over triggers
	for _, anchor in layout.anchors do
		local run = byRoom[anchor.room]
		if run then
			-- a mop cart with its bucket and sign stands along the wall: its stretch of wall and floor stays bare
			local reach = if anchor.kind == "MopCart" then 7 else 2.6
			local p = anchor.pos
			table.insert(run.floorBusy, { x0 = p.X - reach, z0 = p.Z - reach, x1 = p.X + reach, z1 = p.Z + reach })
			if anchor.kind == "MopCart" then
				local u = if run.axis == "X" then p.X else p.Z
				local c = if run.axis == "X" then p.Z else p.X
				markBusy(run, if c < run.cross then -1 else 1, u - reach, u + reach)
			end
		end
	end
	for _, trigger in layout.triggers do
		local run = byRoom[trigger.room]
		if run then
			local t = trigger.rect
			table.insert(run.floorBusy, { x0 = t.x - 1, z0 = t.z - 1, x1 = t.x + t.w + 1, z1 = t.z + t.d + 1 })
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Pipes, markers, vents, trays and grime
--------------------------------------------------------------------------------

type Pipe = {
	name: string,
	d: number,
	y: number,
	off: number,
	color: Color3,
	banded: boolean,
	key: string,
	level: number,
}

local function pipesOf(run: Run, ceiling: number): { Pipe }
	local paint = MathUtil.lerpColor(run.region.pipe, Color3.new(0, 0, 0), run.random:NextNumber(0, 0.15))
	return {
		{
			name = "Main",
			d = 0.8,
			y = ceiling - 1.15,
			off = 0.55,
			color = paint,
			banded = true,
			key = "PipeIron",
			level = LOOK,
		},
		{
			name = "Branch",
			d = 0.45,
			y = ceiling - 2.05,
			off = 0.4,
			color = MathUtil.lerpColor(paint, IRON, 0.35),
			banded = false,
			key = "PipeLead",
			level = MEDIUM,
		},
		{
			name = "Conduit",
			d = 0.2,
			y = ceiling - 0.45,
			off = 0.25,
			color = GALVANIZED,
			banded = false,
			key = "Conduit",
			level = MEDIUM,
		},
	}
end

local function pipeRun(parent: Instance, origin: Vector3, run: Run, side: number, ceiling: number): number
	local u0, u1 = run.lo + 1.4, run.hi - 1.4
	if u1 - u0 < 5 then
		return 0
	end
	local name = run.room.id
	local count = 0
	for _, pipe in pipesOf(run, ceiling) do
		local a, b = onWall(origin, run, side, u0, pipe.y, pipe.off), onWall(origin, run, side, u1, pipe.y, pipe.off)
		local main = decor(
			Geometry.cylinder(parent, name .. "_" .. pipe.name, a, b, pipe.d, pipe.key, { color = pipe.color }),
			pipe.level
		)
		if main then
			main.CastShadow = pipe.d > 0.3 -- the heavy runs throw the torch's shadows
		end
		count += 1
		-- elbows into the wall at both ends
		for k, u in { u0, u1 } do
			decor(
				Geometry.cylinder(
					parent,
					string.format("%s_%sElbow%d", name, pipe.name, k),
					onWall(origin, run, side, u, pipe.y, pipe.off),
					onWall(origin, run, side, u, pipe.y, -0.3),
					pipe.d * 0.98,
					pipe.key,
					{ color = pipe.color }
				),
				pipe.level
			)
			count += 1
		end
		if pipe.banded then
			local u = u0 + run.random:NextNumber(1.5, 4)
			while u < u1 - 0.5 do
				decor(
					Geometry.cylinder(
						parent,
						name .. "_Band",
						onWall(origin, run, side, u - 0.25, pipe.y, pipe.off),
						onWall(origin, run, side, u + 0.25, pipe.y, pipe.off),
						pipe.d + 0.06,
						"PipeIron",
						{ material = Enum.Material.SmoothPlastic, color = run.region.band }
					),
					SMALL
				)
				count += 1
				u += BAND_SPACING
			end
		end
	end
	-- hangers from the ceiling, one rod over all three
	local u = u0 + 2
	while u < u1 - 1 do
		decor(
			Geometry.cylinder(
				parent,
				name .. "_Hanger",
				onWall(origin, run, side, u, ceiling - 2.3, 0.5),
				onWall(origin, run, side, u, ceiling + 0.05, 0.5),
				0.07,
				"TrimMetal"
			),
			SMALL
		)
		count += 1
		u += HANGER_SPACING
	end
	return count
end

-- Stencilled markers on the main naming what it carries, with a flow arrow (toward the run's far end).
local function pipeMarkers(parent: Instance, origin: Vector3, run: Run, side: number, ceiling: number): number
	local medium = run.region.medium
	if not medium or run.hi - run.lo < 12 then
		return 0
	end
	local main = pipesOf(run, ceiling)[1]
	local count = 0
	local u = run.lo + run.random:NextNumber(5, 9)
	while u < run.hi - 5 do
		if spanFree(run.busy[side], u - 1.6, u + 1.6) then
			-- a plate hung on the pipe's room side, facing into the run
			local into = inward(run, side)
			local centre = onWall(origin, run, side, u, main.y, main.off) + into * (main.d / 2 + 0.05)
			local frame = CFrame.lookAt(centre, centre + into, Vector3.yAxis)
			local plate =
				Geometry.part(parent, run.room.id .. "_Marker", frame, Vector3.new(2.6, 0.62, 0.04), "SignPlate", {
					color = run.region.band,
					castShadow = false,
				})
			decor(plate, MEDIUM)
			local gui =
				SurfaceArt.gui(plate, Enum.NormalId.Front, { name = "Marker", pixelsPerStud = 40, maxDistance = 60 })
			local ink = if run.region.band.R + run.region.band.G + run.region.band.B > 1.4
				then Color3.fromRGB(20, 20, 18)
				else PLATE_INK
			-- the arrow points along +axis; seen from the run it reads left or right
			local right = alongAxis(run):Dot(frame.RightVector) > 0
			local text = if right then medium .. "  →" else "←  " .. medium
			SurfaceArt.text(gui, "Text", text, 0.04, 0.08, 0.92, 0.84, ink, Enum.Font.Oswald, 2)
			count += 1
		end
		u += MARKER_SPACING
	end
	return count
end

-- A relief valve teed down off the main at `u`, its nozzle leaking steam into the run.
local function steamVent(parent: Instance, origin: Vector3, run: Run, side: number, ceiling: number, u: number): number
	local main = pipesOf(run, ceiling)[1]
	local into = inward(run, side)
	local name = string.format("%s_Vent%d", run.room.id, math.floor(u))
	local top = onWall(origin, run, side, u, main.y, main.off)
	local valveY = main.y - 1.5
	local valve = onWall(origin, run, side, u, valveY, main.off)
	decor(Geometry.cylinder(parent, name .. "_Tee", top, valve, 0.36, "PipeIron", { color = main.color }), MEDIUM)
	decor(
		Geometry.part(parent, name .. "_Body", CFrame.new(valve), Vector3.new(0.62, 0.7, 0.62), "Iron", {
			color = IRON,
		}),
		MEDIUM
	)
	-- the handwheel on the run side
	local wheelAt = valve + into * 0.42
	decor(
		Geometry.cylinder(parent, name .. "_Wheel", wheelAt, wheelAt + into * 0.08, 0.78, "MetalRust", {
			color = VALVE_RED,
		}),
		SMALL
	)
	-- the nozzle: a short elbow out into the run, pointing down and out
	local nozzleFrom = valve - Vector3.new(0, 0.35, 0)
	local nozzleTo = nozzleFrom + into * 0.75 - Vector3.new(0, 0.25, 0)
	local nozzle = decor(
		Geometry.cylinder(parent, name .. "_Nozzle", nozzleFrom, nozzleTo, 0.24, "PipeIron", { color = IRON }),
		MEDIUM
	)
	if nozzle then
		nozzle:AddTag(Tags.SteamVent)
		-- the mouth looks along the nozzle; the plume leaves through its front
		local dir = (nozzleTo - nozzleFrom).Unit
		local mouth = Geometry.attachment(
			nozzle,
			"Mouth",
			nozzle.CFrame:ToObjectSpace(CFrame.lookAt(nozzleTo, nozzleTo + dir, Vector3.yAxis))
		)
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Steam"
		emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
		emitter.Rate = run.random:NextNumber(10, 16)
		emitter.Lifetime = NumberRange.new(1.1, 2.1)
		emitter.Speed = NumberRange.new(3.2, 5.2)
		emitter.SpreadAngle = Vector2.new(14, 14)
		emitter.Acceleration = Vector3.new(0, 1.6, 0)
		emitter.Drag = 1.6
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(1, 2.8),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.62),
			NumberSequenceKeypoint.new(0.4, 0.78),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Color = ColorSequence.new(STEAM)
		emitter.LightInfluence = 1
		emitter.LightEmission = 0
		emitter.RotSpeed = NumberRange.new(-40, 40)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.EmissionDirection = Enum.NormalId.Front
		emitter.Parent = mouth
	end
	-- the condensate's wet stain on the floor below
	local below = onWall(origin, run, side, u, 0, main.off + 1.4)
	decor(
		Geometry.part(
			parent,
			name .. "_Wet",
			CFrame.new(below + Vector3.new(0, 0.02, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			Vector3.new(0.025, 2.4, 2.4),
			"Puddle",
			{ shape = Enum.PartType.Cylinder, transparency = 0.35, reflectance = 0.15 }
		),
		MEDIUM
	)
	markBusy(run, side, u - 1.2, u + 1.2)
	return 6
end

local function steamVents(parent: Instance, origin: Vector3, run: Run, side: number, ceiling: number): number
	local length = run.hi - run.lo
	if length < 16 then
		return 0
	end
	local wanted = if run.region.id == "Steam"
		then math.max(1, math.floor(length / VENT_SPACING))
		elseif run.random:NextNumber() < VENT_CHANCE then 1
		else 0
	local count = 0
	for k = 1, wanted do
		local base = run.lo + length * (k - 0.5) / wanted
		for _, nudge in { 0, 2, -2, 4, -4, 6, -6 } do
			local u = base + nudge
			if u > run.lo + 5 and u < run.hi - 5 and spanFree(run.busy[side], u - 1.4, u + 1.4) then
				count += steamVent(parent, origin, run, side, ceiling, u)
				break
			end
		end
	end
	return count
end

local function cableTray(parent: Instance, origin: Vector3, run: Run, side: number, ceiling: number): number
	local u0, u1 = run.lo + 1.2, run.hi - 1.2
	if u1 - u0 < 6 then
		return 0
	end
	local face = wallFace(run.room, run.axis, side)
	local y = ceiling - 1.4
	local name = run.room.id
	local function box(part: string, off0: number, off1: number, y0: number, y1: number, color: Color3?, level: number)
		local c0, c1 = face - side * off0, face - side * off1
		local lo = if run.axis == "X"
			then Vector3.new(u0, y0, math.min(c0, c1))
			else Vector3.new(math.min(c0, c1), y0, u0)
		local hi = if run.axis == "X"
			then Vector3.new(u1, y1, math.max(c0, c1))
			else Vector3.new(math.max(c0, c1), y1, u1)
		decor(Geometry.box(parent, name .. "_" .. part, origin + lo, origin + hi, "Conduit", { color = color }), level)
	end
	box("TrayFloor", 0.15, 1.25, y, y + 0.06, nil, LOOK)
	box("TrayLip", 1.2, 1.25, y, y + 0.28, nil, LOOK)
	box("Cables", 0.35, 1.05, y + 0.06, y + 0.22, CABLE, MEDIUM)
	local count = 3
	-- hangers: a rod from the lip up to the ceiling
	local u = u0 + 1.5
	while u < u1 - 0.5 do
		decor(
			Geometry.cylinder(
				parent,
				name .. "_TrayHanger",
				onWall(origin, run, side, u, y, 1.22),
				onWall(origin, run, side, u, ceiling + 0.05, 1.22),
				0.06,
				"TrimMetal"
			),
			SMALL
		)
		count += 1
		u += TRAY_HANGER_SPACING
	end
	return count
end

-- Rust and water runs down the wall under the pipes.
local function grime(parent: Instance, origin: Vector3, run: Run, side: number, ceiling: number): number
	local count = 0
	local u = run.lo + run.random:NextNumber(2, 6)
	while u < run.hi - 2 do
		if run.random:NextNumber() < 0.55 then
			local w = run.random:NextNumber(0.35, 1.1)
			local top = ceiling - 2.4
			local length = run.random:NextNumber(1.6, 5.2)
			if spanFree(run.busy[side], u - w / 2 - 0.2, u + w / 2 + 0.2) then
				local centre = onWall(origin, run, side, u, top - length / 2, 0.015)
				local into = inward(run, side)
				local frame = CFrame.lookAt(centre, centre + into, Vector3.yAxis)
				decor(
					Geometry.part(
						parent,
						run.room.id .. "_Streak",
						frame,
						Vector3.new(w, length, 0.02),
						"ConcreteDark",
						{
							material = Enum.Material.SmoothPlastic,
							color = MathUtil.lerpColor(
								run.region.grime,
								Color3.fromRGB(52, 50, 46),
								run.random:NextNumber(0, 0.5)
							),
							transparency = run.random:NextNumber(0.25, 0.5),
							castShadow = false,
						}
					),
					SMALL
				)
				count += 1
			end
		end
		u += run.random:NextNumber(6, 11)
	end
	return count
end

--------------------------------------------------------------------------------
-- Landmarks (decals)
--------------------------------------------------------------------------------

-- A plate on the wall face (or hung from the ceiling) whose Front face looks along `normal`; invisible for paint (a
-- decal host). Never collides, queried or touched.
local function decalHost(parent: Instance, name: string, origin: Vector3, landmark: Landmark, visible: boolean): Part
	local normal = landmark.normal
	local pos = origin + landmark.pos + normal * 0.03
	local frame = CFrame.lookAt(pos, pos + normal)
	local part = Geometry.part(parent, name, frame, Vector3.new(landmark.width, landmark.height, 0.06), "SignPlate", {
		color = PLATE,
		transparency = if visible then nil else 1,
		castShadow = false,
	})
	PropKit.detail(part)
	return part
end

-- Lore, tallies and tags are atmosphere; plates, stencils and arrows find the way (never Detail).
local PAINT_DETAIL: { [string]: number } = { Lore = LOOK, Tally = MEDIUM, Tag = SMALL }

local function paintLandmark(
	parent: Instance,
	origin: Vector3,
	landmark: Landmark,
	region: Region?,
	random: Rng
): number
	local paint = if region then region.paint else Color3.fromRGB(230, 226, 210)
	local kind = landmark.kind
	if kind == "JunctionPlate" then
		local plate = decalHost(parent, "Plate_" .. landmark.text, origin, landmark, true)
		local gui = SurfaceArt.gui(plate, Enum.NormalId.Front, { name = "Plate", pixelsPerStud = 40, maxDistance = 80 })
		SurfaceArt.frame(gui, "Border", 0.04, 0.08, 0.92, 0.84, PLATE_INK, 0, 1)
		SurfaceArt.frame(gui, "Field", 0.07, 0.14, 0.86, 0.72, PLATE, 0, 2)
		SurfaceArt.text(gui, "Text", landmark.text, 0.1, 0.16, 0.8, 0.68, PLATE_INK, Enum.Font.RobotoMono, 3)
		-- four rivets
		for i, p in { { 0.03, 0.06 }, { 0.93, 0.06 }, { 0.03, 0.82 }, { 0.93, 0.82 } } do
			SurfaceArt.frame(gui, "Rivet" .. i, p[1], p[2], 0.04, 0.1, Color3.fromRGB(150, 150, 140), 0, 4)
		end
		return 1
	end
	local host = decalHost(parent, string.format("Paint_%s", landmark.id), origin, landmark, false)
	local level = PAINT_DETAIL[kind]
	if level then
		decor(host, level)
	end
	local gui = SurfaceArt.gui(host, Enum.NormalId.Front, { name = "Graffiti", pixelsPerStud = 28, maxDistance = 90 })
	if kind == "RegionSign" then
		-- a stencil: square capitals in paint, a ruled line under them
		local label = SurfaceArt.text(gui, "Text", landmark.text, 0.02, 0.05, 0.96, 0.72, paint, Enum.Font.Oswald, 2)
		label.TextTransparency = 0.08
		SurfaceArt.frame(gui, "Rule", 0.04, 0.84, 0.92, 0.06, paint, 0.15, 2)
	elseif kind == "Arrow" then
		local right = (landmark.yaw or 0) < 90
		local text = if right then landmark.text .. "  →" else "←  " .. landmark.text
		local label = SurfaceArt.text(
			gui,
			"Text",
			text,
			0.02,
			0.08,
			0.96,
			0.84,
			Color3.fromRGB(240, 214, 70),
			Enum.Font.Oswald,
			2
		)
		label.Rotation = random:NextNumber(-3, 3)
	elseif kind == "Tally" then
		local label = SurfaceArt.text(
			gui,
			"Text",
			landmark.text,
			0,
			0,
			1,
			1,
			Color3.fromRGB(214, 210, 196),
			Enum.Font.PatrickHand,
			2
		)
		label.Rotation = random:NextNumber(-4, 4)
	else
		-- lore lines and tags: spray paint, a little crooked
		local label =
			SurfaceArt.text(gui, "Text", landmark.text, 0.01, 0.04, 0.98, 0.92, paint, Enum.Font.PatrickHand, 2)
		label.Rotation = random:NextNumber(-5, 5)
		label.TextTransparency = random:NextNumber(0, 0.12)
	end
	return 1
end

--------------------------------------------------------------------------------
-- Floor dressing
--------------------------------------------------------------------------------

local function grate(parent: Instance, origin: Vector3, x: number, z: number, name: string)
	local base = origin + Vector3.new(x, 0, z)
	decor(
		Geometry.box(parent, name, base + Vector3.new(-1.4, 0, -1.4), base + Vector3.new(1.4, 0.05, 1.4), "Iron", {
			color = Color3.fromRGB(20, 18, 16),
		}),
		MEDIUM
	)
	for i = -2, 2 do
		decor(
			Geometry.box(
				parent,
				name .. "_Bar",
				base + Vector3.new(i * 0.55 - 0.08, 0.05, -1.3),
				base + Vector3.new(i * 0.55 + 0.08, 0.09, 1.3),
				"Iron",
				{ color = IRON }
			),
			SMALL
		)
	end
end

local function puddle(parent: Instance, origin: Vector3, x: number, z: number, random: Rng, name: string)
	local centre = origin + Vector3.new(x, 0.004, z)
	local d = random:NextNumber(2.2, 3.8)
	-- a Cylinder's face is round on every engine (Roblox draws the smaller of its Y and Z): sized round, as drawn
	local across = d * random:NextNumber(0.6, 1)
	decor(
		Geometry.part(
			parent,
			name,
			CFrame.new(centre + Vector3.new(0, 0.015, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			Vector3.new(0.03, across, across),
			"Water",
			{
				shape = Enum.PartType.Cylinder,
				transparency = 0.3,
				reflectance = 0.18,
			}
		),
		MEDIUM
	)
end

local function lumps(
	parent: Instance,
	origin: Vector3,
	x: number,
	z: number,
	random: Rng,
	name: string,
	key: string,
	color: Color3
)
	for i = 1, random:NextInteger(4, 7) do
		local s = random:NextNumber(0.35, 0.9)
		decor(
			Geometry.part(
				parent,
				string.format("%s_%d", name, i),
				CFrame.new(
					origin + Vector3.new(x + random:NextNumber(-1.2, 1.2), s * 0.35, z + random:NextNumber(-1.2, 1.2))
				) * CFrame.Angles(random:NextNumber(0, 3), random:NextNumber(0, 3), random:NextNumber(0, 3)),
				Vector3.new(s, s * 0.7, s * 0.9),
				key,
				{ color = color }
			),
			SMALL
		)
	end
end

-- A heap of debris against the wall on `side` at `u`: brick, broken block, a can or two, paper.
local function debrisHeap(parent: Instance, origin: Vector3, run: Run, side: number, u: number): number
	local random = run.random
	local into = inward(run, side)
	local along = alongAxis(run)
	local base = onWall(origin, run, side, u, 0, 1)
	local name = string.format("%s_Heap%d", run.room.id, math.floor(u))
	local count = 0
	for i = 1, random:NextInteger(4, 7) do
		local at = base + along * random:NextNumber(-1.6, 1.6) + into * random:NextNumber(-0.5, 0.9)
		local roll = random:NextNumber()
		local yaw = CFrame.Angles(0, random:NextNumber(0, math.pi * 2), 0)
		if roll < 0.35 then
			-- a brick, or half of one
			local size = Vector3.new(random:NextNumber(0.45, 0.9), 0.32, 0.42)
			decor(
				Geometry.part(
					parent,
					name .. "_Brick" .. i,
					CFrame.new(at + Vector3.new(0, 0.16, 0)) * yaw,
					size,
					"BlockGray",
					{
						color = MathUtil.lerpColor(BLOCK, Color3.new(0, 0, 0), random:NextNumber(0, 0.3)),
					}
				),
				SMALL
			)
		elseif roll < 0.6 then
			-- broken block
			local s = random:NextNumber(0.4, 0.95)
			decor(
				Geometry.part(
					parent,
					name .. "_Block" .. i,
					CFrame.new(at + Vector3.new(0, s * 0.3, 0))
						* yaw
						* CFrame.Angles(random:NextNumber(-0.3, 0.3), 0, random:NextNumber(-0.3, 0.3)),
					Vector3.new(s, s * 0.6, s * 0.8),
					"Rubble"
				),
				SMALL
			)
		elseif roll < 0.8 then
			-- a can on its side
			local can = at + Vector3.new(0, 0.13, 0)
			local dir = (yaw * CFrame.new(0.22, 0, 0)).Position
			decor(
				Geometry.cylinder(parent, name .. "_Can" .. i, can - dir, can + dir, 0.26, "TrimMetal", {
					material = Enum.Material.Metal,
					color = CANS[random:NextInteger(1, #CANS)],
				}),
				SMALL
			)
		else
			-- a sheet of paper
			decor(
				Geometry.part(
					parent,
					name .. "_Paper" .. i,
					CFrame.new(at + Vector3.new(0, 0.012, 0))
						* yaw
						* CFrame.Angles(random:NextNumber(-0.06, 0.06), 0, 0),
					Vector3.new(random:NextNumber(0.6, 0.85), 0.01, random:NextNumber(0.8, 1.1)),
					"PaperSheet",
					{ color = MathUtil.lerpColor(PAPER, Color3.fromRGB(101, 97, 89), random:NextNumber(0, 0.6)) }
				),
				SMALL
			)
		end
		count += 1
	end
	return count
end

local function debrisHeaps(parent: Instance, origin: Vector3, run: Run): number
	local count = 0
	local u = run.lo + run.random:NextNumber(6, 12)
	while u < run.hi - 6 do
		local side = if run.random:NextNumber() < 0.5 then -1 else 1
		local a = onWall(Vector3.zero, run, side, u - 2.2, 0, 0)
		local b = onWall(Vector3.zero, run, side, u + 2.2, 0, 2.4)
		local lo, hi = a:Min(b), a:Max(b)
		if spanFree(run.busy[side], u - 2.4, u + 2.4) and floorFree(run, lo.X, lo.Z, hi.X, hi.Z) then
			count += debrisHeap(parent, origin, run, side, u)
		end
		u += DEBRIS_SPACING * run.random:NextNumber(0.7, 1.3)
	end
	return count
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function build(ctx: PropKit.StaticContext): number
	local layout = ctx.layout
	local tunnels = layout.tunnels
	if not tunnels then
		return 0
	end
	local origin = WorldConfig.levelOrigin(layout.id)
	local model = PropKit.model(ctx.parent, "Tunnels_" .. layout.id, CFrame.new(origin))
	local regions: { [string]: Region } = {}
	for _, region in tunnels.regions do
		regions[region.id] = region
	end
	local runs = buildRuns(layout, regions)
	local count = 0
	-- landmarks first: the dressing on the walls keeps clear of them
	for _, landmark in tunnels.landmarks do
		local random = Rng.seeded(1, layout.id .. ":landmark:" .. landmark.id)
		count += paintLandmark(model, origin, landmark, regions[landmark.region], random)
	end
	-- pipes (galleries: both walls), markers, vents, trays, grime
	for _, run in runs do
		local side = run.pipeSide
		count += pipeRun(model, origin, run, side, run.ceiling)
		count += steamVents(model, origin, run, side, run.ceiling)
		count += pipeMarkers(model, origin, run, side, run.ceiling)
		count += grime(model, origin, run, side, run.ceiling)
		if run.gallery then
			count += pipeRun(model, origin, run, -side, run.ceiling - 1.6)
		end
		count += cableTray(model, origin, run, -side, run.ceiling)
	end
	-- floor dressing: drain grates at wet junctions, puddles in wet tunnels, coal in the chutes, rubble at dead ends,
	-- debris heaps against the walls
	for _, node in tunnels.nodes do
		local region = if node.region then regions[node.region] else nil
		if not region then
			continue
		end
		if node.kind == "Junction" and region.wet and MathUtil.hash(node.id) % 3 ~= 0 then
			grate(model, origin, node.x, node.z, "Grate_" .. node.id)
			count += 1
		elseif node.kind == "End" then
			lumps(
				model,
				origin,
				node.x,
				node.z,
				Rng.seeded(1, node.id),
				"Rubble_" .. node.id,
				"Rubble",
				Color3.fromRGB(84, 80, 72)
			)
			count += 1
		end
	end
	for _, run in runs do
		local region = run.region
		local random = Rng.seeded(1, layout.id .. ":floor:" .. run.room.id)
		local length = run.hi - run.lo
		local function at(t: number, across: number): (number, number)
			local u = run.lo + length * t
			if run.axis == "X" then
				return u, run.cross + across
			end
			return run.cross + across, u
		end
		if region.wet then
			for i = 1, math.floor(length / 18) do
				local x, z = at(random:NextNumber(0.1, 0.9), random:NextNumber(-1, 1) * (run.width / 2 - 1.6))
				puddle(model, origin, x, z, random, string.format("Puddle_%s_%d", run.room.id, i))
				count += 1
			end
		elseif region.id == "Coal" and length > 16 and random:NextNumber() < 0.6 then
			local x, z =
				at(random:NextNumber(0.2, 0.8), (if random:NextNumber() < 0.5 then -1 else 1) * (run.width / 2 - 1.2))
			lumps(model, origin, x, z, random, "Coal_" .. run.room.id, "Rubble", Color3.fromRGB(18, 18, 20))
			count += 1
		end
		count += debrisHeaps(model, origin, run)
	end
	return count
end

function TunnelDressingBuilder.register(registrar: PropKit.Registrar)
	registrar.static(TunnelDressingBuilder.Kind, build)
end

return table.freeze(TunnelDressingBuilder)
