--!strict
-- ServicePipeBuilder: the exposed service runs under the ceilings of the plant rooms (static kind "ServicePipes":
-- once at boot, the same on every server, into <level>.Props as one Model "Pipes_<layoutId>").
--
-- Every boiler, pump and filter room, the basement's stores and undercrofts and the pool's chlorine store carry
-- pipework along their long walls: a corroded iron main, a copper branch and a galvanized electrical conduit, each a
-- straight run from wall to wall (they pass through the walls at both ends) hung a little under the ceiling on straps,
-- the boiler rooms' mains with a gate valve and its handwheel. A run keeps clear of every ceiling fixture
-- (SchoolShellBuilder.fixtureBox), every drip pipe's run (SetDressingBuilder.dripEnvelopes), the pillars and the
-- other runs: it steps further out from its wall until it is clear, or is left out. Everything sits above the door
-- heads and never collides or is queried; the mains and branches cast shadows, the conduit does not.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

local PropKit = require(script.Parent.PropKit)
local SchoolShellBuilder = require(script.Parent.Parent.SchoolShellBuilder)
local SetDressingBuilder = require(script.Parent.SetDressingBuilder)

type Layout = LayoutSchema.LevelLayout
type Room = LayoutSchema.Room
type Piece = SetDressingBuilder.Piece
type Box = SetDressingBuilder.Box
type LevelInfo = SetDressingBuilder.LevelInfo

local Kit = SetDressingBuilder.Kit
local W = Attributes.World

local CEILING_GAP = 0.3 -- between the ceiling and the top of a pipe
local WALL_GAP = 0.3 -- between the wall face and the nearest pipe
local STEP = 0.55 -- how far a blocked run steps out from its wall per try
local STEPS = 5
local HANGER_SPACING = 12
local MAX_HANGERS = 4
local MIN_TOP = 11 -- nothing hangs lower than this (door heads are at 10)
local MAX_PER_ROOM = 22 -- part budget per room

type PipeKind = { name: string, diameter: number, key: string, shadow: boolean }

local MAIN: PipeKind = { name = "Main", diameter = 0.8, key = "PipeIron", shadow = true }
local BRANCH: PipeKind = { name = "Branch", diameter = 0.46, key = "PipeCopper", shadow = true }
local CONDUIT: PipeKind = { name = "Conduit", diameter = 0.2, key = "Conduit", shadow = false }

-- Rooms that get pipework.
local function isServiceRoom(layout: Layout, room: Room): boolean
	if layout.id == "Lobby" then
		return false -- the lobby's boiler has its own steam pipes (LobbyBuilder)
	end
	if room.kind == "Boiler" then
		return true
	end
	if room.kind == "Storage" then
		return layout.id == "Level0_Basement" or string.find(room.id, "Chlorine", 1, true) ~= nil
	end
	return false
end

local function overlap(a: Box, b: Box): boolean
	return math.min(a.x1, b.x1) - math.max(a.x0, b.x0) > 0
		and math.min(a.z1, b.z1) - math.max(a.z0, b.z0) > 0
		and math.min(a.y1, b.y1) - math.max(a.y0, b.y0) > 0
end

-- What the runs of `room` keep clear of (level-local boxes).
local function obstacles(info: LevelInfo, room: Room, ceiling: number): { Box }
	local out: { Box } = {}
	local along = SchoolShellBuilder.fixtureAlong(room)
	for _, light in (room.lights or {}) :: { LayoutSchema.Light } do
		local lo, hi = SchoolShellBuilder.fixtureBox(light.kind, light.pos, ceiling, along)
		-- a broken strip may sag below its box, but only within its footprint: keep out of the whole column under it
		table.insert(out, {
			x0 = lo.X - 0.35,
			x1 = hi.X + 0.35,
			z0 = lo.Z - 0.35,
			z1 = hi.Z + 0.35,
			y0 = math.min(lo.Y, ceiling - 4) - 0.2,
			y1 = hi.Y + 0.2,
		})
	end
	for _, anchor in info.layout.anchors do
		if anchor.kind == "DripPipe" and anchor.room == room.id then
			for _, envelope in SetDressingBuilder.dripEnvelopes(info.layout, anchor) do
				table.insert(out, envelope)
			end
		end
	end
	for _, pillar in info.pillars do
		table.insert(out, pillar)
	end
	return out
end

type Run = { box: Box, from: Vector3, to: Vector3, axisX: boolean, y: number, cross: number, kind: PipeKind }

-- The first clear line for a `kind` pipe along the wall at across-coordinate `face` (its room side `dir`), stacked
-- `slot` pipes out from the wall.
local function findRun(
	inner: LayoutSchema.Rect,
	axisX: boolean,
	face: number,
	dir: number,
	slot: number,
	kind: PipeKind,
	ceiling: number,
	blocked: { Box }
): Run?
	local r = kind.diameter / 2
	local y = ceiling - CEILING_GAP - r - slot * 0.12
	if y - r < MIN_TOP then
		return nil
	end
	local u0 = if axisX then inner.x else inner.z
	local u1 = u0 + (if axisX then inner.w else inner.d)
	for step = 0, STEPS - 1 do
		local cross = face + dir * (WALL_GAP + r + slot * 0.95 + step * STEP)
		local box: Box = {
			x0 = if axisX then u0 else cross - r - 0.05,
			x1 = if axisX then u1 else cross + r + 0.05,
			z0 = if axisX then cross - r - 0.05 else u0,
			z1 = if axisX then cross + r + 0.05 else u1,
			y0 = y - r - 0.05,
			y1 = ceiling,
		}
		local clear = true
		for _, o in blocked do
			if overlap(box, o) then
				clear = false
				break
			end
		end
		if clear then
			local from = if axisX then Vector3.new(u0, y, cross) else Vector3.new(cross, y, u0)
			local to = if axisX then Vector3.new(u1, y, cross) else Vector3.new(cross, y, u1)
			return { box = box, from = from, to = to, axisX = axisX, y = y, cross = cross, kind = kind }
		end
	end
	return nil
end

local function pipePieces(
	info: LevelInfo,
	room: Room,
	run: Run,
	ceiling: number,
	random: Random,
	index: number
): { Piece }
	local origin = info.origin
	local kind = run.kind
	local name = string.format("%s%d", kind.name, index)
	local pieces: { Piece } = {
		Kit.cylinder(
			name,
			origin + run.from,
			origin + run.to,
			kind.diameter,
			kind.key,
			"Detail",
			{ castShadow = kind.shadow }
		),
	}
	-- straps from the ceiling round the pipe, evenly along it
	local length = (run.to - run.from).Magnitude
	local hangers = math.clamp(math.floor(length / HANGER_SPACING), 1, MAX_HANGERS)
	local axis = (run.to - run.from).Unit
	local top = run.y - kind.diameter / 2 - 0.04
	for i = 1, hangers do
		local at = run.from + axis * (length * i / (hangers + 1) + random:NextNumber(-0.8, 0.8))
		local centre = origin + Vector3.new(at.X, (ceiling + top) / 2, at.Z)
		local size = if run.axisX
			then Vector3.new(0.1, ceiling - top, kind.diameter + 0.1)
			else Vector3.new(kind.diameter + 0.1, ceiling - top, 0.1)
		table.insert(
			pieces,
			Kit.block(string.format("%s_Strap%d", name, i), CFrame.new(centre), size, "Iron", "Detail", nil)
		)
	end
	-- a gate valve on a boiler room's main: the body on the pipe, the handwheel hanging under it
	if kind == MAIN and room.kind == "Boiler" then
		local at = run.from + axis * (length * random:NextNumber(0.3, 0.7))
		local body = origin + at
		local cframe = CFrame.fromMatrix(body, axis, Vector3.yAxis)
		table.insert(
			pieces,
			Kit.block(
				name .. "_Valve",
				cframe,
				Vector3.new(0.9, kind.diameter + 0.24, kind.diameter + 0.24),
				"Iron",
				"Detail",
				nil
			)
		)
		local wheelAt = body - Vector3.yAxis * (kind.diameter / 2 + 0.55)
		table.insert(
			pieces,
			Kit.cylinder(
				name .. "_Stem",
				body - Vector3.yAxis * (kind.diameter / 2),
				wheelAt,
				0.1,
				"Iron",
				"Detail",
				nil
			)
		)
		table.insert(
			pieces,
			Kit.disc(name .. "_Wheel", wheelAt - Vector3.yAxis * 0.04, 0.95, 0.08, "MetalRust", "Detail", nil)
		)
	end
	return pieces
end

-- Static "ServicePipes" for one level. Returns the parts built.
local function buildServicePipes(ctx: PropKit.StaticContext): number
	local layout = ctx.layout
	local info = Kit.info(layout)
	local pieces: { Piece } = {}
	for _, room in layout.rooms do
		if not isServiceRoom(layout, room) then
			continue
		end
		local inner = info.inner[room.id]
		if not inner then
			continue
		end
		local ceiling = SchoolShellBuilder.ceilingBottom(layout, room)
		local random = MathUtil.seededRandom(1, layout.id .. ":pipes:" .. room.id)
		local blocked = obstacles(info, room, ceiling)
		local axisX = inner.w >= inner.d -- runs follow the long walls
		local faces: { { number } } = if axisX
			then { { inner.z, 1 }, { inner.z + inner.d, -1 } }
			else { { inner.x, 1 }, { inner.x + inner.w, -1 } }
		if random:NextNumber() < 0.5 then
			faces[1], faces[2] = faces[2], faces[1]
		end
		-- the first wall carries the main (and often a conduit), the other a branch (and sometimes a conduit)
		local plans: { { PipeKind } } = {
			if random:NextNumber() < 0.65 then { MAIN, CONDUIT } else { MAIN },
			if random:NextNumber() < 0.4 then { BRANCH, CONDUIT } else { BRANCH },
		}
		local roomPieces: { Piece } = {}
		local index = 0
		for w, face in faces do
			for slot, kind in plans[w] do
				local run = findRun(inner, axisX, face[1], face[2], slot - 1, kind, ceiling, blocked)
				if not run then
					continue
				end
				index += 1
				local list = pipePieces(info, room, run, ceiling, random, index)
				if #roomPieces + #list > MAX_PER_ROOM then
					continue
				end
				if not Kit.fits(info, list, { room = room.id, margin = -0.05 }) then
					continue
				end
				table.insert(blocked, run.box)
				for _, piece in list do
					table.insert(roomPieces, piece)
				end
			end
		end
		for _, piece in roomPieces do
			piece.name = string.format("%s_%s", room.id, piece.name)
			table.insert(pieces, piece)
		end
	end
	if #pieces == 0 then
		return 0
	end
	local model = PropKit.model(ctx.parent, "Pipes_" .. layout.id, CFrame.new(info.origin))
	model:SetAttribute(W.LevelId, layout.id)
	local parts = Kit.realize(model, pieces)
	-- Detail parts never cast shadows; the heavy runs do
	for i, part in parts do
		local options = pieces[i].options
		if options and options.castShadow then
			part.CastShadow = true
		end
	end
	return #parts
end

local ServicePipeBuilder = {}

ServicePipeBuilder.isServiceRoom = isServiceRoom

function ServicePipeBuilder.register(registrar: PropKit.Registrar)
	registrar.static("ServicePipes", buildServicePipes)
end

return table.freeze(ServicePipeBuilder)
