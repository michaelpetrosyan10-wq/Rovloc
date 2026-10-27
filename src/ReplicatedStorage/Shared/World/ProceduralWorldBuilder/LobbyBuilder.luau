--!strict
-- The safe-zone lobby (Workspace.Lobby): built from Layouts/Lobby like any level (rooms, lights, zones, anchors),
-- plus bespoke set pieces: a riveted coal boiler with its firebox glow and flue, overhead steam pipes, and the
-- burnt-out school bus shell the squad gathers in. ReadyPad and Terminal anchors become visible pads and
-- consoles (non-interactive until the lobby services arrive). No vents, warm dim light.
--
-- Set pieces place themselves from the layout: the boiler goes against the wall of the Boiler room that keeps the
-- most clearance from doors and anchors; the bus is centred on the ReadyPads (so the pads end up inside it) and
-- oriented along their spread.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(script.Parent.Geometry)
local SchoolShellBuilder = require(script.Parent.SchoolShellBuilder)

local log = Log.new("Lobby")

type Layout = LayoutSchema.LevelLayout
type Room = LayoutSchema.Room
type Rect = LayoutSchema.Rect

local W = Attributes.World
local Names = Instances.Names

local EPS = 1e-3

-- Boiler
local BOILER_LENGTH = 18
local BOILER_DIAMETER = 8
local SADDLE_HEIGHT = 1.4
local FIREBOX_DEPTH = 3

-- Bus (bus-local: X along the bus toward the hood, Y up, Z across)
local BUS_WIDTH = 9
local BUS_HEIGHT = 8.6
local BUS_SKIN = 0.35
local BUS_HOOD = 5.6
local BUS_MIN_LENGTH = 26
local BUS_MAX_LENGTH = 36

local LobbyBuilder = {}

local function area(room: Room): number
	return room.rect.w * room.rect.d
end

local function largest(layout: Layout, predicate: (Room) -> boolean): Room?
	local best: Room? = nil
	for _, room in layout.rooms do
		if predicate(room) and (best == nil or area(room) > area(best)) then
			best = room
		end
	end
	return best
end

-- Points the set pieces must keep clear of: every anchor, and every door centre on that room's walls.
local function obstacles(layout: Layout, room: Room): ({ Vector2 }, { Vector2 })
	local anchors: { Vector2 } = {}
	for _, anchor in layout.anchors do
		table.insert(anchors, Vector2.new(anchor.pos.X, anchor.pos.Z))
	end
	local rooms = LayoutSchema.indexRooms(layout)
	local doors: { Vector2 } = {}
	for _, door in layout.doors do
		if door.rooms[1] ~= room.id and door.rooms[2] ~= room.id then
			continue
		end
		local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
		local edge = if a and b then LayoutSchema.sharedEdge(a.rect, b.rect) else nil
		if edge then
			table.insert(
				doors,
				if edge.axis == "X" then Vector2.new(edge.coord, door.at) else Vector2.new(door.at, edge.coord)
			)
		end
	end
	return anchors, doors
end

local function distanceToRect(point: Vector2, r: Rect): number
	local dx = math.max(r.x - point.X, 0, point.X - (r.x + r.w))
	local dz = math.max(r.z - point.Y, 0, point.Y - (r.z + r.d))
	return math.sqrt(dx * dx + dz * dz)
end

--------------------------------------------------------------------------------
-- Boiler + pipes
--------------------------------------------------------------------------------

type BoilerPlacement = { cframe: CFrame, length: number, footprint: Rect } -- level-local, at the floor

local function placeBoiler(layout: Layout, room: Room): BoilerPlacement?
	local r = room.rect
	local anchors, doors = obstacles(layout, room)
	local depth = BOILER_DIAMETER + 1
	local inset = WorldConfig.WallThickness + 1.2
	local best: BoilerPlacement? = nil
	local bestScore = -math.huge
	local sides: { { number } } = {
		-- { centre x, centre z, body along X (1) or Z (0) }
		{ r.x + r.w / 2, r.z + inset + depth / 2, 1 },
		{ r.x + r.w / 2, r.z + r.d - inset - depth / 2, 1 },
		{ r.x + inset + depth / 2, r.z + r.d / 2, 0 },
		{ r.x + r.w - inset - depth / 2, r.z + r.d / 2, 0 },
	}
	for _, side in sides do
		local alongX = side[3] == 1
		local wallLength = if alongX then r.w else r.d
		local length = math.min(BOILER_LENGTH, wallLength - FIREBOX_DEPTH - 6)
		if length < 8 then
			continue
		end
		local total = length + FIREBOX_DEPTH
		local footprint: Rect = if alongX
			then { x = side[1] - total / 2, z = side[2] - depth / 2, w = total, d = depth }
			else { x = side[1] - depth / 2, z = side[2] - total / 2, w = depth, d = total }
		if not LayoutSchema.rectInside(footprint, r) then
			continue
		end
		local score = math.huge
		for _, point in anchors do
			score = math.min(score, distanceToRect(point, footprint) - 3)
		end
		for _, point in doors do
			score = math.min(score, distanceToRect(point, footprint) - 6)
		end
		if score > bestScore then
			bestScore = score
			local axis = if alongX then Vector3.xAxis else Vector3.zAxis
			-- Boiler-local: X along the body (firebox at +X), Y up; CFrame at the body's floor centre.
			local centre = Vector3.new(side[1], 0, side[2]) - axis * (FIREBOX_DEPTH / 2)
			best = {
				cframe = CFrame.fromMatrix(centre, axis, Vector3.yAxis),
				length = length,
				footprint = footprint,
			}
		end
	end
	if best and bestScore < 0 then
		log.warn("boiler in %s sits within clearance of an anchor or door (%.1f)", room.id, bestScore)
	end
	return best
end

local function buildBoiler(layout: Layout, room: Room, root: Instance, lights: Instance, origin: Vector3): number
	local placement = placeBoiler(layout, room)
	if not placement then
		log.warn("room %s is too small for the boiler", room.id)
		return 0
	end
	local model = Instance.new("Model")
	model.Name = "Boiler"
	local count = 0
	local frame = CFrame.new(origin) * placement.cframe
	local length = placement.length
	local radius = BOILER_DIAMETER / 2
	local axisY = SADDLE_HEIGHT + radius
	local ceiling = SchoolShellBuilder.ceilingBottom(layout, room)
	local function at(x: number, y: number, z: number): Vector3
		return frame:PointToWorldSpace(Vector3.new(x, y, z))
	end
	local function block(name: string, x: number, y: number, z: number, size: Vector3, key: string)
		Geometry.part(model, name, frame * CFrame.new(x, y, z), size, key)
		count += 1
	end
	local function pipe(name: string, a: Vector3, b: Vector3, diameter: number, key: string)
		if Geometry.cylinder(model, name, a, b, diameter, key) then
			count += 1
		end
	end

	-- Saddles, riveted body, bands
	for i, x in { -length * 0.3, length * 0.3 } do
		block(
			string.format("Saddle%d", i),
			x,
			SADDLE_HEIGHT / 2,
			0,
			Vector3.new(1.6, SADDLE_HEIGHT, BOILER_DIAMETER * 0.8),
			"ConcreteDark"
		)
	end
	pipe("Body", at(-length / 2, axisY, 0), at(length / 2, axisY, 0), BOILER_DIAMETER, "Iron")
	for i, x in { -length / 3, 0, length / 3 } do
		pipe(
			string.format("Band%d", i),
			at(x - 0.25, axisY, 0),
			at(x + 0.25, axisY, 0),
			BOILER_DIAMETER + 0.3,
			"MetalRust"
		)
	end
	pipe("EndCap", at(-length / 2 - 0.4, axisY, 0), at(-length / 2, axisY, 0), BOILER_DIAMETER - 0.8, "MetalRust")

	-- Firebox, door, gauges, flue
	local fireTop = SADDLE_HEIGHT + BOILER_DIAMETER + 0.6
	block(
		"Firebox",
		length / 2 + FIREBOX_DEPTH / 2,
		fireTop / 2,
		0,
		Vector3.new(FIREBOX_DEPTH, fireTop, BOILER_DIAMETER),
		"Iron"
	)
	local face = length / 2 + FIREBOX_DEPTH
	block("FireDoor", face + 0.15, 3.2, 0, Vector3.new(0.3, 2.6, 3.2), "MetalRust")
	for i, z in { -2.4, 2.4 } do
		pipe(
			string.format("Gauge%d", i),
			at(face, fireTop - 1.6, z),
			at(face + 0.3, fireTop - 1.6, z),
			0.9,
			"TrimMetal"
		)
	end
	local flueTop = math.max(fireTop + 1, ceiling - 0.05)
	pipe(
		"Flue",
		at(length / 2 - 2, SADDLE_HEIGHT + BOILER_DIAMETER - 0.5, 0),
		at(length / 2 - 2, flueTop, 0),
		2.2,
		"MetalRust"
	)

	-- The fire's glow: a LevelLight so the lobby lighting pass owns it like every other fixture.
	local glowAt = at(face + 0.35, 1.6, 0)
	SchoolShellBuilder.buildLight(lights, {
		id = "Lobby_BoilerGlow",
		kind = "BoilerGlow",
		position = glowAt,
		brightness = 1.6,
		range = 28,
		flickerGroup = "LobbyBoiler",
		levelId = "Lobby",
		zoneId = room.id,
		facing = at(face + 10, 1.6, 0),
	})

	-- Steam pipes: risers off the body up under the ceiling, then runs across the room and along it.
	local pipeY = math.max(fireTop + 1.5, ceiling - 2.4) -- clear of ceiling fixtures
	local r = room.rect
	local localZ = frame:VectorToWorldSpace(Vector3.zAxis)
	local toCentre = (origin + Vector3.new(r.x + r.w / 2, 0, r.z + r.d / 2)) - frame.Position
	local acrossSign = if localZ:Dot(toCentre) >= 0 then 1 else -1
	-- How far the room extends across the boiler (toward its centre) from the body axis.
	local function reachAcross(): number
		local direction = frame:VectorToWorldSpace(Vector3.new(0, 0, acrossSign))
		local position = frame.Position - origin
		local reach = math.huge
		if math.abs(direction.X) > 0.5 then
			reach = if direction.X > 0 then (r.x + r.w) - position.X else position.X - r.x
		else
			reach = if direction.Z > 0 then (r.z + r.d) - position.Z else position.Z - r.z
		end
		return math.max(2, reach - WorldConfig.WallThickness / 2 - 0.8)
	end
	local across = reachAcross()
	for i, x in { -length / 4, length / 4 } do
		local base = at(x, SADDLE_HEIGHT + BOILER_DIAMETER - 0.4, 0)
		local elbow = at(x, pipeY, 0)
		local far = at(x, pipeY, acrossSign * across)
		pipe(string.format("Riser%d", i), base, elbow, 1.2, "MetalGalvanized")
		pipe(string.format("Run%d", i), elbow, far, 1.2, "MetalGalvanized")
		Geometry.part(
			model,
			string.format("Elbow%d", i),
			CFrame.new(elbow),
			Vector3.new(1.5, 1.5, 1.5),
			"MetalRust",
			{ shape = Enum.PartType.Ball }
		)
		count += 1
		pipe(string.format("Valve%d", i), at(x, pipeY - 2.5, -0.7), at(x, pipeY - 2.5, 0.7), 1.6, "MetalRust")
	end
	local lengthReach = (if math.abs(frame.RightVector.X) > 0.5 then r.w else r.d) / 2 - 2.5
	for i, z in { -(radius + 1.2), radius + 1.2 } do
		pipe(
			string.format("Main%d", i),
			at(-lengthReach, pipeY + 0.2, z * acrossSign),
			at(lengthReach, pipeY + 0.2, z * acrossSign),
			0.9,
			"MetalRust"
		)
	end

	model.Parent = root
	return count
end

--------------------------------------------------------------------------------
-- Bus
--------------------------------------------------------------------------------

type BusPlacement = { cframe: CFrame, length: number } -- level-local, at the floor under the bus centre

local function placeBus(room: Room, pads: { LayoutSchema.Anchor }): BusPlacement?
	local r = room.rect
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, pad in pads do
		minX, maxX = math.min(minX, pad.pos.X), math.max(maxX, pad.pos.X)
		minZ, maxZ = math.min(minZ, pad.pos.Z), math.max(maxZ, pad.pos.Z)
	end
	local cx: number, cz: number
	local spreadX, spreadZ = 0, 0
	if #pads > 0 then
		cx, cz = (minX + maxX) / 2, (minZ + maxZ) / 2
		spreadX, spreadZ = maxX - minX, maxZ - minZ
	else
		cx, cz = r.x + r.w / 2, r.z + r.d / 2
	end
	local alongX = if math.abs(spreadX - spreadZ) > 0.5 then spreadX > spreadZ else r.w >= r.d
	local roomLong = if alongX then r.w else r.d
	local roomShort = if alongX then r.d else r.w
	if roomShort < BUS_WIDTH + 4 or roomLong < BUS_MIN_LENGTH * 0.6 + BUS_HOOD then
		return nil
	end
	local spreadAlong = if alongX then spreadX else spreadZ
	local length = math.clamp(spreadAlong + 16, BUS_MIN_LENGTH, BUS_MAX_LENGTH)
	length = math.min(length, roomLong - BUS_HOOD - 4)
	-- Hood toward the side of the room with more space.
	local towardPositive = if alongX then (r.x + r.w - cx) >= (cx - r.x) else (r.z + r.d - cz) >= (cz - r.z)
	local forward = if alongX then Vector3.xAxis else Vector3.zAxis
	if not towardPositive then
		forward = -forward
	end
	-- Clamp the footprint (rear .. bumper) inside the room with a 2-stud margin.
	local margin = 2 + WorldConfig.WallThickness / 2
	local lo = if alongX then r.x + margin else r.z + margin
	local hi = if alongX then r.x + r.w - margin else r.z + r.d - margin
	local centreAlong = if alongX then cx else cz
	local backReach = length / 2
	local frontReach = length / 2 + BUS_HOOD
	local sign = if towardPositive then 1 else -1
	local minAlong = centreAlong - (if sign > 0 then backReach else frontReach)
	local maxAlong = centreAlong + (if sign > 0 then frontReach else backReach)
	if minAlong < lo then
		centreAlong += lo - minAlong
	elseif maxAlong > hi then
		centreAlong -= maxAlong - hi
	end
	local across = if alongX then cz else cx
	local acrossLo = (if alongX then r.z else r.x) + margin + BUS_WIDTH / 2
	local acrossHi = (if alongX then r.z + r.d else r.x + r.w) - margin - BUS_WIDTH / 2
	across = math.clamp(across, acrossLo, math.max(acrossLo, acrossHi))
	local centre = if alongX then Vector3.new(centreAlong, 0, across) else Vector3.new(across, 0, centreAlong)
	return { cframe = CFrame.fromMatrix(centre, forward, Vector3.yAxis), length = length }
end

local function buildBus(
	room: Room,
	pads: { LayoutSchema.Anchor },
	root: Instance,
	lights: Instance,
	origin: Vector3
): number
	local placement = placeBus(room, pads)
	if not placement then
		log.warn("room %s is too small for the bus", room.id)
		return 0
	end
	local model = Instance.new("Model")
	model.Name = "Bus"
	local count = 0
	local frame = CFrame.new(origin) * placement.cframe
	local length = placement.length
	local halfL, halfW = length / 2, BUS_WIDTH / 2
	local random = MathUtil.seededRandom(1, "LobbyBus")

	local function box(
		name: string,
		x0: number,
		x1: number,
		y0: number,
		y1: number,
		z0: number,
		z1: number,
		key: string
	)
		local size = Vector3.new(math.abs(x1 - x0), math.abs(y1 - y0), math.abs(z1 - z0))
		if size.X < EPS or size.Y < EPS or size.Z < EPS then
			return
		end
		Geometry.part(model, name, frame * CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), size, key)
		count += 1
	end
	local function cylinder(name: string, a: Vector3, b: Vector3, diameter: number, key: string)
		if Geometry.cylinder(model, name, frame:PointToWorldSpace(a), frame:PointToWorldSpace(b), diameter, key) then
			count += 1
		end
	end

	-- Side walls: window band split by pillars; the door side (+Z) also has the entry door near the front.
	local windowY0, windowY1 = 3.6, 6.9
	local roofY = BUS_HEIGHT - 0.4
	for _, sideSign in { -1, 1 } do
		local openings: { Geometry.Opening } = {}
		local u = -halfL + 1.6
		local doorStart = halfL - 5.4
		while u + 2.6 <= halfL - 1.4 do
			if sideSign > 0 and u + 2.6 > doorStart - 0.6 then
				break
			end
			table.insert(openings, { u0 = u, u1 = u + 2.6, y0 = windowY0, y1 = windowY1 })
			u += 3.4
		end
		if sideSign > 0 then
			table.insert(openings, { u0 = doorStart, u1 = doorStart + 3, y0 = 0, y1 = 7.2 })
		end
		local z0 = if sideSign > 0 then halfW - BUS_SKIN else -halfW
		local z1 = z0 + BUS_SKIN
		for i, piece in Geometry.splitWall(-halfL, halfL, 0, roofY, openings) do
			box(
				string.format("Side%s_%d", if sideSign > 0 then "R" else "L", i),
				piece.u0,
				piece.u1,
				piece.y0,
				piece.y1,
				z0,
				z1,
				"BusPaint"
			)
		end
	end
	-- Rear wall with the sprung emergency door, front wall with the windshield hole.
	local innerZ0, innerZ1 = -halfW + BUS_SKIN, halfW - BUS_SKIN
	for i, piece in Geometry.splitWall(innerZ0, innerZ1, 0, roofY, { { u0 = -1.8, u1 = 1.8, y0 = 0, y1 = 7.2 } }) do
		box(string.format("Rear_%d", i), -halfL, -halfL + BUS_SKIN, piece.y0, piece.y1, piece.u0, piece.u1, "BusPaint")
	end
	Geometry.part(
		model,
		"EmergencyDoor",
		frame * CFrame.new(-halfL - 0.2, 3.6, 1.8) * CFrame.Angles(0, math.rad(72), 0) * CFrame.new(0, 0, -1.8),
		Vector3.new(0.25, 7.0, 3.6),
		"BusPaint"
	)
	count += 1
	for i, piece in Geometry.splitWall(innerZ0, innerZ1, 0, roofY, { { u0 = -3.6, u1 = 3.6, y0 = 4.2, y1 = 7.4 } }) do
		box(string.format("Front_%d", i), halfL - BUS_SKIN, halfL, piece.y0, piece.y1, piece.u0, piece.u1, "BusPaint")
	end
	-- Roof, sagging at one end; hood, grille, bumper, headlights
	box("Roof", -halfL, halfL, roofY, BUS_HEIGHT, -halfW, halfW, "BusPaint")
	box("Hood", halfL, halfL + BUS_HOOD - 0.6, 1.2, 4.6, -3.8, 3.8, "BusPaint")
	box("Grille", halfL + BUS_HOOD - 0.6, halfL + BUS_HOOD - 0.3, 1.4, 4.2, -2.6, 2.6, "TrimMetal")
	box("Bumper", halfL + BUS_HOOD - 0.3, halfL + BUS_HOOD, 0.9, 1.8, -4.6, 4.6, "TrimMetal")
	for i, z in { -3.1, 3.1 } do
		cylinder(
			string.format("Headlight%d", i),
			Vector3.new(halfL + BUS_HOOD - 0.6, 3.4, z),
			Vector3.new(halfL + BUS_HOOD - 0.35, 3.4, z),
			1.1,
			"Glass"
		)
	end
	-- Flat, half-sunk tyres
	for i, x in { halfL + 2.6, -halfL + 6 } do
		for j, z in { -(halfW - 0.6), halfW - 0.6 } do
			cylinder(
				string.format("Wheel%d%d", i, j),
				Vector3.new(x, 0.9, z - 0.55),
				Vector3.new(x, 0.9, z + 0.55),
				3.6,
				"Rubber"
			)
		end
	end
	-- Wrecked seat rows, left out wherever a ReadyPad sits so the squad has floor to gather on.
	local padLocal: { Vector3 } = {}
	for _, pad in pads do
		table.insert(padLocal, frame:PointToObjectSpace(origin + pad.pos))
	end
	local seatDepth, seatWidth = 1.6, 3
	local x = -halfL + 2.5
	local row = 0
	while x <= halfL - 7 do
		row += 1
		for _, sideSign in { -1, 1 } do
			local zInner = sideSign * (halfW - BUS_SKIN - seatWidth)
			local zOuter = sideSign * (halfW - BUS_SKIN)
			local clear = true
			for _, p in padLocal do
				if math.abs(p.X - x) < 3.2 and math.abs(p.Z - (zInner + zOuter) / 2) < 3.5 then
					clear = false
				end
			end
			if not clear or random:NextNumber() < 0.25 then
				continue
			end
			local name = string.format("Seat%d%s", row, if sideSign > 0 then "R" else "L")
			box(
				name .. "_Base",
				x - seatDepth / 2,
				x + seatDepth / 2,
				1.2,
				1.8,
				math.min(zInner, zOuter),
				math.max(zInner, zOuter),
				"Carpet"
			)
			box(
				name .. "_Back",
				x - seatDepth / 2 - 0.35,
				x - seatDepth / 2,
				1.2,
				4,
				math.min(zInner, zOuter),
				math.max(zInner, zOuter),
				"Carpet"
			)
		end
		x += 3
	end
	for _, p in padLocal do
		if math.abs(p.Z) > halfW - 1 or p.X < -halfL + 0.5 or p.X > halfL - 0.5 then
			log.warn("ReadyPad at (%.1f, %.1f) lies outside the bus shell", p.X, p.Z)
		end
	end

	-- A single dim bulb inside: the gathering point
	SchoolShellBuilder.buildLight(lights, {
		id = "Lobby_BusBulb",
		kind = "Bulb",
		position = frame:PointToWorldSpace(Vector3.new(0, roofY - 0.5, 0)),
		brightness = 0.8,
		range = 20,
		flickerGroup = "LobbyBus",
		levelId = "Lobby",
		zoneId = room.id,
		ceilingY = frame.Position.Y + roofY,
	})

	model.Parent = root
	return count
end

--------------------------------------------------------------------------------
-- Pads + consoles
--------------------------------------------------------------------------------

local function buildPads(layout: Layout, props: Instance, origin: Vector3): number
	local count = 0
	for _, anchor in layout.anchors do
		if anchor.kind ~= "ReadyPad" then
			continue
		end
		local base = origin + Vector3.new(anchor.pos.X, 0, anchor.pos.Z)
		local ring = Geometry.cylinder(
			props,
			"ReadyPad_" .. anchor.id .. "_Ring",
			base,
			base + Vector3.new(0, 0.06, 0),
			4.4,
			"BusPaint",
			{ canCollide = false, castShadow = false }
		)
		local pad = Geometry.cylinder(
			props,
			"ReadyPad_" .. anchor.id,
			base,
			base + Vector3.new(0, 0.12, 0),
			3.6,
			"MetalGalvanized",
			{ canCollide = false, castShadow = false }
		)
		for _, part in { ring, pad } do
			if part then
				part:SetAttribute(W.AnchorId, anchor.id)
				part:SetAttribute(W.AnchorKind, anchor.kind)
				count += 1
			end
		end
	end
	return count
end

local function buildTerminals(layout: Layout, props: Instance, origin: Vector3): number
	local count = 0
	for _, anchor in layout.anchors do
		if anchor.kind ~= "Terminal" then
			continue
		end
		local frame = CFrame.new(origin)
			* CFrame.new(anchor.pos.X, 0, anchor.pos.Z)
			* CFrame.Angles(0, math.rad(anchor.yaw or 0), 0)
		local model = Instance.new("Model")
		model.Name = "Terminal_" .. anchor.id
		model:SetAttribute(W.AnchorId, anchor.id)
		model:SetAttribute(W.AnchorKind, anchor.kind)
		Geometry.part(model, "Desk", frame * CFrame.new(0, 1.5, 0), Vector3.new(3.2, 3, 1.8), "TrimMetal")
		Geometry.part(model, "Riser", frame * CFrame.new(0, 3.6, 0.5), Vector3.new(2.6, 1.2, 0.6), "Iron")
		local screen = Geometry.part(
			model,
			"Screen",
			frame * CFrame.new(0, 4.3, 0.05) * CFrame.Angles(math.rad(-18), 0, 0),
			Vector3.new(2.8, 1.8, 0.2),
			"Screen",
			{ castShadow = false }
		)
		local glow = Instance.new("SurfaceLight")
		glow.Name = "Glow"
		glow.Face = Enum.NormalId.Front
		glow.Angle = 80
		glow.Range = 7
		glow.Brightness = 0.5
		glow.Color = Color3.fromRGB(90, 255, 140)
		glow.Shadows = true -- like every fixture: an unshadowed light shines through the walls behind it
		glow.Parent = screen
		count += 3
		model.Parent = props
	end
	return count
end

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

-- Builds the whole lobby into a new Model named "Lobby" (unparented; the caller parents it).
function LobbyBuilder.build(layout: Layout): Model
	local root = SchoolShellBuilder.createRoot(layout, Names.Lobby)
	SchoolShellBuilder.buildLevel(layout, root, SchoolShellBuilder.levelOptions("Lobby"))
	local folders = SchoolShellBuilder.folders(root)
	local props = Geometry.folder(root, Names.Props)
	local origin = WorldConfig.levelOrigin("Lobby")

	local boilerRoom = largest(layout, function(room: Room): boolean
		return room.kind == "Boiler"
	end) or largest(layout, function(room: Room): boolean
		return room.kind ~= "Chase"
	end)

	local pads: { LayoutSchema.Anchor } = {}
	local padRooms: { [string]: number } = {}
	for _, anchor in layout.anchors do
		if anchor.kind == "ReadyPad" then
			table.insert(pads, anchor)
			padRooms[anchor.room] = (padRooms[anchor.room] or 0) + 1
		end
	end
	local rooms = LayoutSchema.indexRooms(layout)
	local busRoom: Room? = nil
	local bestPads = 0
	for roomId, count in padRooms do
		if count > bestPads or (count == bestPads and busRoom and roomId < busRoom.id) then
			bestPads = count
			busRoom = rooms[roomId]
		end
	end
	if not busRoom then
		busRoom = largest(layout, function(room: Room): boolean
			return room.kind == "LobbyHall" and room ~= boilerRoom
		end) or boilerRoom
	end

	if boilerRoom then
		buildBoiler(layout, boilerRoom, folders.Shell, folders.Lights, origin)
	end
	if busRoom then
		local inRoom: { LayoutSchema.Anchor } = {}
		for _, pad in pads do
			if pad.room == busRoom.id then
				table.insert(inRoom, pad)
			end
		end
		buildBus(busRoom, inRoom, folders.Shell, folders.Lights, origin)
	end
	buildPads(layout, props, origin)
	buildTerminals(layout, props, origin)
	return root
end

return table.freeze(LobbyBuilder)
