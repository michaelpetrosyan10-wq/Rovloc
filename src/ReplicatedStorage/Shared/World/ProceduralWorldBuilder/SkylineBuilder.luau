--!strict
-- Client-only backdrop: the ruined city around the school, out to about 600 studs. Broken towers with sheared,
-- tilted crowns, dark window bands on the faces that look at the school, a few faint lit windows (someone, or
-- something, is still out there), rubble at their feet and a dead ground plane beyond the street. Every part is
-- cosmetic (no collision, no queries, no shadows) and the whole thing is a pure function of the seed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(script.Parent.Geometry)
local SchoolShellBuilder = require(script.Parent.SchoolShellBuilder)

local SkylineBuilder = {}

local INNER_RADIUS = 300 -- nearest skyline building to the school centre
local OUTER_RADIUS = 620
local BUILDING_COUNT = 72
local FAR_GROUND = 720 -- half extent of the cosmetic ground plane around the school
local LOBBY_CLEARANCE = 320 -- nothing cosmetic within this distance of the (enclosed, far-off) lobby
local BURIED = 12 -- towers start this far below street level, so they never float on uneven ground

SkylineBuilder.InnerRadius = INNER_RADIUS
SkylineBuilder.OuterRadius = OUTER_RADIUS

type Footprint = { x: number, z: number, r: number }

local function cosmetic(part: BasePart): BasePart
	Geometry.makeCosmetic(part)
	return part
end

local function add(
	parent: Instance,
	name: string,
	cframe: CFrame,
	size: Vector3,
	key: string,
	transparency: number?
): BasePart
	return cosmetic(Geometry.part(parent, name, cframe, size, key, { transparency = transparency, castShadow = false }))
end

-- Dark ground beyond the authoritative street slab so distant buildings stand on something.
local function buildGround(parent: Instance, centre: Vector2): number
	local ext = SchoolShellBuilder.Exterior
	local street = Geometry.rect(ext.minX, ext.minZ, ext.maxX - ext.minX, ext.maxZ - ext.minZ)
	local outer = Geometry.rect(centre.X - FAR_GROUND, centre.Y - FAR_GROUND, FAR_GROUND * 2, FAR_GROUND * 2)
	local lobby = WorldConfig.LobbyOrigin
	local lobbyZone =
		Geometry.rect(lobby.X - LOBBY_CLEARANCE, lobby.Z - LOBBY_CLEARANCE, LOBBY_CLEARANCE * 2, LOBBY_CLEARANCE * 2)
	local count = 0
	for i, piece in Geometry.subtractRects(outer, { street, lobbyZone }) do
		local part = Geometry.box(
			parent,
			string.format("FarGround_%d", i),
			Vector3.new(piece.x, WorldConfig.GroundY - 4, piece.z),
			Vector3.new(piece.x + piece.w, WorldConfig.GroundY, piece.z + piece.d),
			"Asphalt",
			{ castShadow = false }
		)
		if part then
			cosmetic(part)
			count += 1
		end
	end
	return count
end

local function overlaps(placed: { Footprint }, x: number, z: number, r: number): boolean
	for _, other in placed do
		local dx, dz = other.x - x, other.z - z
		if dx * dx + dz * dz < (other.r + r + 6) ^ 2 then
			return true
		end
	end
	return false
end

local function inLandingField(x: number, z: number, r: number): boolean
	local field = SchoolShellBuilder.Exterior.landing
	return x + r > field.x - 40
		and x - r < field.x + field.w + 40
		and z + r > field.z - 40
		and z - r < field.z + field.d + 40
end

-- The building face (local +-X / +-Z) that looks most toward the school, as a local unit normal.
local function facingNormal(cframe: CFrame, target: Vector3): Vector3
	local localDir = cframe:VectorToObjectSpace(target - cframe.Position)
	if math.abs(localDir.X) > math.abs(localDir.Z) then
		return Vector3.new(if localDir.X > 0 then 1 else -1, 0, 0)
	end
	return Vector3.new(0, 0, if localDir.Z > 0 then 1 else -1)
end

local function buildTower(
	parent: Instance,
	index: number,
	random: Random,
	x: number,
	z: number,
	target: Vector3
): number
	local count = 0
	local distance = (Vector2.new(x, z) - Vector2.new(target.X, target.Z)).Magnitude
	local width = random:NextNumber(18, 46)
	local depth = random:NextNumber(18, 46)
	local tall = MathUtil.remapClamped(distance, INNER_RADIUS, OUTER_RADIUS, 0.55, 1.15)
	local height = random:NextNumber(36, 180) * tall
	local base = WorldConfig.GroundY - BURIED
	local yaw = math.rad(random:NextNumber(-25, 25))
	local frame = CFrame.new(x, base, z) * CFrame.Angles(0, yaw, 0)
	local name = string.format("Tower%02d", index)
	local key = if random:NextNumber() < 0.5 then "SkylineConcrete" else "SkylineSoot"

	-- Main shaft
	add(parent, name, frame * CFrame.new(0, height / 2, 0), Vector3.new(width, height, depth), key)
	count += 1

	-- Broken crown: a sheared slab tilted off the top, and stubs of the floors that are left
	if random:NextNumber() < 0.7 then
		local crownH = random:NextNumber(8, 24)
		local tiltX = math.rad(random:NextNumber(-18, 18))
		local tiltZ = math.rad(random:NextNumber(-18, 18))
		local shift = Vector3.new(random:NextNumber(-width, width) * 0.15, 0, random:NextNumber(-depth, depth) * 0.15)
		add(
			parent,
			name .. "_Crown",
			frame * CFrame.new(shift + Vector3.new(0, height + crownH / 2 - 2, 0)) * CFrame.Angles(tiltX, 0, tiltZ),
			Vector3.new(width * random:NextNumber(0.5, 0.9), crownH, depth * random:NextNumber(0.5, 0.9)),
			key
		)
		count += 1
	end
	for s = 1, random:NextInteger(0, 3) do
		local stubW = width * random:NextNumber(0.15, 0.4)
		local stubD = depth * random:NextNumber(0.15, 0.4)
		local stubH = random:NextNumber(3, 14)
		local ox = random:NextNumber(-0.5, 0.5) * (width - stubW)
		local oz = random:NextNumber(-0.5, 0.5) * (depth - stubD)
		add(
			parent,
			string.format("%s_Stub%d", name, s),
			frame * CFrame.new(ox, height + stubH / 2, oz),
			Vector3.new(stubW, stubH, stubD),
			key
		)
		count += 1
	end

	-- Window bands on the face toward the school, a rare faint lit window
	local normal = facingNormal(frame, target)
	local alongX = math.abs(normal.Z) > 0.5
	local faceSpan = if alongX then width else depth
	local faceOffset = (if alongX then depth else width) / 2 + 0.2
	local bands = math.clamp(math.floor(height / 14), 1, 8)
	for b = 1, bands do
		if random:NextNumber() < 0.2 then
			continue -- a blown-out floor
		end
		local y = BURIED + b * (height - BURIED) / (bands + 1)
		local bandSize = if alongX
			then Vector3.new(faceSpan * 0.86, 1.6, 0.4)
			else Vector3.new(0.4, 1.6, faceSpan * 0.86)
		add(
			parent,
			string.format("%s_Band%d", name, b),
			frame * CFrame.new(normal * faceOffset + Vector3.new(0, y, 0)),
			bandSize,
			"SkylineWindow"
		)
		count += 1
	end
	if random:NextNumber() < 0.22 then
		for l = 1, random:NextInteger(1, 2) do
			local y = random:NextNumber(BURIED + 6, math.max(BURIED + 8, height - 6))
			local along = random:NextNumber(-0.4, 0.4) * faceSpan
			local offset = normal * (faceOffset + 0.1)
				+ (if alongX then Vector3.new(along, y, 0) else Vector3.new(0, y, along))
			add(
				parent,
				string.format("%s_Lit%d", name, l),
				frame * CFrame.new(offset),
				if alongX then Vector3.new(2.4, 1.5, 0.3) else Vector3.new(0.3, 1.5, 2.4),
				"SkylineLit",
				0.45
			)
			count += 1
		end
	end

	-- Rubble spill at the base on the school side
	if random:NextNumber() < 0.55 then
		local spill = normal * ((if alongX then depth else width) / 2 + random:NextNumber(3, 9))
		add(
			parent,
			name .. "_Rubble",
			frame
				* CFrame.new(spill + Vector3.new(0, BURIED + 1, 0))
				* CFrame.Angles(math.rad(random:NextNumber(-12, 12)), math.rad(random:NextNumber(0, 90)), 0),
			Vector3.new(random:NextNumber(8, 18), random:NextNumber(3, 7), random:NextNumber(6, 14)),
			"Rubble"
		)
		count += 1
	end
	return count
end

-- Builds the skyline into `parent`. Same seed -> identical skyline. Returns parts created.
function SkylineBuilder.build(seed: number, parent: Instance): number
	local random = MathUtil.seededRandom(seed, "Skyline")
	local size = WorldConfig.FootprintSize
	local centre = Vector2.new(size.X / 2, size.Y / 2)
	local target = Vector3.new(centre.X, WorldConfig.GroundY, centre.Y)
	local count = buildGround(parent, centre)
	local placed: { Footprint } = {}
	local built = 0
	local attempts = 0
	while built < BUILDING_COUNT and attempts < BUILDING_COUNT * 20 do
		attempts += 1
		local angle = random:NextNumber(0, math.pi * 2)
		-- sqrt keeps the ring evenly dense instead of crowding the inner edge
		local t = math.sqrt(random:NextNumber())
		local radius = INNER_RADIUS + (OUTER_RADIUS - INNER_RADIUS) * t
		local x = centre.X + math.cos(angle) * radius
		local z = centre.Y + math.sin(angle) * radius
		local footprintRadius = 34
		local lobby = WorldConfig.LobbyOrigin
		local nearLobby = math.abs(x - lobby.X) < LOBBY_CLEARANCE + footprintRadius
			and math.abs(z - lobby.Z) < LOBBY_CLEARANCE + footprintRadius
		if overlaps(placed, x, z, footprintRadius) or inLandingField(x, z, footprintRadius) or nearLobby then
			continue
		end
		built += 1
		table.insert(placed, { x = x, z = z, r = footprintRadius })
		count += buildTower(parent, built, random, x, z, target)
	end
	return count
end

return table.freeze(SkylineBuilder)
