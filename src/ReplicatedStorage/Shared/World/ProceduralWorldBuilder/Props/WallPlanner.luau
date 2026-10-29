--!strict
-- WallPlanner: where pieces may hang on a room's walls. Shared by the statics that mount things there (FurnitureBuilder's
-- chalkboards, noticeboards and filing cabinets, DecayBuilder's plaster damage) and read back by SignageBuilder, so a
-- poster never lands on a chalkboard. Pure layout maths: a room's wall faces, every opening the shell cuts on each wall
-- line (padded by its casing, sign plate and, beside an ordinary door, the leaf that stands open against the wall),
-- and the light fixtures mounted on a wall.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)

local Finishes = require(script.Parent.Parent.Finishes)
local SchoolShellBuilder = require(script.Parent.Parent.SchoolShellBuilder)
local SetDressingBuilder = require(script.Parent.SetDressingBuilder)

type Layout = LayoutSchema.LevelLayout
type Room = LayoutSchema.Room
type LevelInfo = SetDressingBuilder.LevelInfo

export type Axis = "X" | "Z"

-- One wall face of a room: the wall line (the room rect's edge), the face across it, the normal into the room and the
-- along-wall extent of the face (u is world X on an "Z" wall, world Z on an "X" wall).
export type Wall = { room: Room, axis: Axis, line: number, face: number, normal: Vector3, u0: number, u1: number }

-- A wall-local box on one wall line.
export type Span = { u0: number, u1: number, y0: number, y1: number }

-- A mounted piece's wall-local box, with the line it is on (what SignageBuilder keeps clear of).
export type Mount = { axis: Axis, line: number, u0: number, u1: number, y0: number, y1: number }

local WallPlanner = {}

WallPlanner.EndGap = 0.5 -- mounted pieces keep this far from a room's corners

function WallPlanner.lineKey(axis: Axis, line: number): string
	return string.format("%s|%.3f", axis, line)
end

-- The four wall faces of `room`.
function WallPlanner.walls(info: LevelInfo, room: Room): { Wall }
	local inner = info.inner[room.id]
	if not inner then
		return {}
	end
	local r = room.rect
	return {
		{
			room = room,
			axis = "Z",
			line = r.z,
			face = inner.z,
			normal = Vector3.zAxis,
			u0 = inner.x,
			u1 = inner.x + inner.w,
		},
		{
			room = room,
			axis = "Z",
			line = r.z + r.d,
			face = inner.z + inner.d,
			normal = -Vector3.zAxis,
			u0 = inner.x,
			u1 = inner.x + inner.w,
		},
		{
			room = room,
			axis = "X",
			line = r.x,
			face = inner.x,
			normal = Vector3.xAxis,
			u0 = inner.z,
			u1 = inner.z + inner.d,
		},
		{
			room = room,
			axis = "X",
			line = r.x + r.w,
			face = inner.x + inner.w,
			normal = -Vector3.xAxis,
			u0 = inner.z,
			u1 = inner.z + inner.d,
		},
	}
end

-- How far along the wall (each side), below and above an opening its surroundings reach.
local function openingPad(item: SchoolShellBuilder.PlacedOpening): (number, number, number)
	local door = item.door
	if door then
		if door.kind == "Door" or door.kind == "Ajar" or door.kind == "RoofDoor" then
			return LayoutSchema.doorWidth(door) + 1.2, 0.5, 1.2 -- the leaf stands open against the wall beside it
		elseif door.kind == "Airlock" or door.kind == "Gate" then
			return 1.6, 0.5, 2.6 -- steel frame, housing and the sign plate over it
		end
		return 1, 0.5, 1
	elseif item.kind == "Grate" then
		return 0.9, 0.8, 0.9
	end
	return 0.6, 0.5, 0.6
end

local openingCache: { [Layout]: { [string]: { Span } } } = setmetatable({}, { __mode = "k" }) :: any

-- Per wall line: what every opening the shell cuts there takes of the wall (cached per layout).
function WallPlanner.openings(layout: Layout): { [string]: { Span } }
	local cached = openingCache[layout]
	if cached then
		return cached
	end
	local out: { [string]: { Span } } = {}
	for _, item in SchoolShellBuilder.openings(layout) do
		local o = item.opening
		local pad, below, above = openingPad(item)
		local key = WallPlanner.lineKey(item.axis, item.coord)
		local list = out[key]
		if not list then
			list = {}
			out[key] = list
		end
		table.insert(list, { u0 = o.u0 - pad, u1 = o.u1 + pad, y0 = o.y0 - below, y1 = o.y1 + above })
	end
	openingCache[layout] = out
	return out
end

-- The light fixtures of `wall`'s room that hang on (or close to) that wall.
function WallPlanner.fixtures(wall: Wall): { Span }
	local out: { Span } = {}
	for _, light in (wall.room.lights or {}) :: { LayoutSchema.Light } do
		local p = light.pos
		local across = if wall.axis == "Z" then p.Z else p.X
		local mounted = light.kind == "EmergencyRed" or light.kind == "ExitSign" or light.kind == "BoilerGlow"
		if mounted or math.abs(across - wall.face) < 1.8 then
			local u = if wall.axis == "Z" then p.X else p.Z
			table.insert(out, { u0 = u - 1.7, u1 = u + 1.7, y0 = p.Y - 1.4, y1 = p.Y + 1.4 })
		end
	end
	return out
end

-- The stretches of `wall` free over heights [y0, y1] of everything in `taken` (spans on its line), corners left clear,
-- sorted and no shorter than `minWidth`.
function WallPlanner.free(wall: Wall, taken: { Span }, y0: number, y1: number, minWidth: number): { Finishes.Interval }
	local cuts: { Finishes.Interval } = {}
	for _, span in taken do
		if span.y1 > y0 and span.y0 < y1 then
			table.insert(cuts, { u0 = span.u0, u1 = span.u1 })
		end
	end
	local out: { Finishes.Interval } = {}
	for _, run in Finishes.subtract(wall.u0 + WallPlanner.EndGap, wall.u1 - WallPlanner.EndGap, cuts) do
		if run.u1 - run.u0 >= minWidth then
			table.insert(out, run)
		end
	end
	return out
end

-- Everything already on `wall`'s line: its openings, its room's wall fixtures and `extra` mounts.
function WallPlanner.taken(layout: Layout, wall: Wall, extra: { Mount }?): { Span }
	local out: { Span } = table.clone(WallPlanner.openings(layout)[WallPlanner.lineKey(wall.axis, wall.line)] or {})
	for _, span in WallPlanner.fixtures(wall) do
		table.insert(out, span)
	end
	for _, mount in (extra or {}) :: { Mount } do
		if mount.axis == wall.axis and math.abs(mount.line - wall.line) < 1e-3 then
			table.insert(out, { u0 = mount.u0, u1 = mount.u1, y0 = mount.y0, y1 = mount.y1 })
		end
	end
	return out
end

-- World CFrame centred at (u, y) on `wall`, `out` studs off its face, looking into the room.
function WallPlanner.cframe(info: LevelInfo, wall: Wall, u: number, y: number, out: number): CFrame
	local offset = wall.face + (if wall.axis == "Z" then wall.normal.Z else wall.normal.X) * out
	local centre = if wall.axis == "Z" then Vector3.new(u, y, offset) else Vector3.new(offset, y, u)
	local world = info.origin + centre
	return CFrame.lookAt(world, world + wall.normal)
end

-- World point `depth` studs into the room from `wall`'s face at along-wall `u`, on the floor.
function WallPlanner.floorPoint(info: LevelInfo, wall: Wall, u: number, depth: number): Vector3
	local across = wall.face + (if wall.axis == "Z" then wall.normal.Z else wall.normal.X) * depth
	return info.origin + (if wall.axis == "Z" then Vector3.new(u, 0, across) else Vector3.new(across, 0, u))
end

-- How deep the room is from `wall`'s face to the face opposite.
function WallPlanner.depth(info: LevelInfo, wall: Wall): number
	local inner = info.inner[wall.room.id]
	if not inner then
		return 0
	end
	return if wall.axis == "Z" then inner.d else inner.w
end

function WallPlanner.mount(wall: Wall, u0: number, u1: number, y0: number, y1: number): Mount
	return { axis = wall.axis, line = wall.line, u0 = u0, u1 = u1, y0 = y0, y1 = y1 }
end

return table.freeze(WallPlanner)
