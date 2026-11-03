--!strict
-- ObjectiveState: how the floor objective travels from ObjectiveService to the HUD (pure; shared by both sides).
--
--   Steps     ReplicatedStorage ObjectiveSteps: "<StepId>=<done>" pairs joined by ";" in the floor's step order
--   Carrying  Player Carrying: "<Kind>:<n>" pairs joined by ";" in the order first carried
--   Targets   ReplicatedStorage ObjectiveTargets: where the next undone step is worked, "<room>|x|y|z" joined by ";"
--             (world points; the room is the layout room holding the point, "" when none does)
--
-- stepLines turns a floor's steps into the tracker's lines (the label with its count, "Survive ...: 45s" for the
-- timed step, done / active flags). The Tab nudge points at a target's ROOM, never the item: nudge picks the target
-- nearest the player and returns that room's centre (when the player is already in it) or its doorway nearest the
-- player, labelled with the room's name (roomName: "L2_ChemPrep_205" -> "Chem Prep 205").

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

type Layout = LayoutSchema.LevelLayout

export type Target = { room: string, point: Vector3 }

export type StepLine = { id: string, text: string, done: boolean, active: boolean, timed: boolean }

export type Nudge = { point: Vector3, room: string, label: string }

local ObjectiveState = {}

local NUDGE_LIFT = 3

--------------------------------------------------------------------------------
-- Encoding
--------------------------------------------------------------------------------

function ObjectiveState.encodeSteps(spec: ObjectiveConfig.FloorSpec, progress: { [string]: number }): string
	local parts: { string } = {}
	for _, step in spec.steps do
		table.insert(parts, string.format("%s=%d", step.id, progress[step.id] or 0))
	end
	return table.concat(parts, ";")
end

function ObjectiveState.decodeSteps(raw: unknown): { [string]: number }
	local out: { [string]: number } = {}
	if type(raw) ~= "string" then
		return out
	end
	for id, value in string.gmatch(raw, "([%w_]+)=(%d+)") do
		out[id] = tonumber(value) or 0
	end
	return out
end

-- `counts` in `order`: "Fuse:2;MasterKeys:1" (kinds with nothing are left out).
function ObjectiveState.encodeCarry(order: { string }, counts: { [string]: number }): string
	local parts: { string } = {}
	for _, kind in order do
		local n = counts[kind] or 0
		if n > 0 then
			table.insert(parts, string.format("%s:%d", kind, n))
		end
	end
	return table.concat(parts, ";")
end

export type CarryEntry = { kind: string, count: number }

function ObjectiveState.decodeCarry(raw: unknown): { CarryEntry }
	local out: { CarryEntry } = {}
	if type(raw) ~= "string" then
		return out
	end
	for kind, n in string.gmatch(raw, "([%w_]+):(%d+)") do
		local count = tonumber(n) or 0
		if count > 0 then
			table.insert(out, { kind = kind, count = count })
		end
	end
	return out
end

local function fmt(n: number): string
	return string.format("%.2f", n)
end

function ObjectiveState.encodeTargets(targets: { Target }): string
	local parts: { string } = {}
	for _, target in targets do
		local p = target.point
		table.insert(parts, table.concat({ target.room, fmt(p.X), fmt(p.Y), fmt(p.Z) }, "|"))
	end
	return table.concat(parts, ";")
end

function ObjectiveState.decodeTargets(raw: unknown): { Target }
	local out: { Target } = {}
	if type(raw) ~= "string" then
		return out
	end
	for entry in string.gmatch(raw, "[^;]+") do
		local room, x, y, z = string.match(entry, "^([^|]*)|([^|]+)|([^|]+)|([^|]+)$")
		local px, py, pz = tonumber(x), tonumber(y), tonumber(z)
		if room and px and py and pz then
			table.insert(out, { room = room, point = Vector3.new(px, py, pz) })
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- The tracker
--------------------------------------------------------------------------------

-- Whether step `id` of `spec` is done under `progress`.
function ObjectiveState.done(spec: ObjectiveConfig.FloorSpec, progress: { [string]: number }, id: string): boolean
	for _, step in spec.steps do
		if step.id == id then
			return (progress[id] or 0) >= step.count
		end
	end
	return false
end

-- The first step not done (nil once all are).
function ObjectiveState.current(
	spec: ObjectiveConfig.FloorSpec,
	progress: { [string]: number }
): ObjectiveConfig.StepSpec?
	for _, step in spec.steps do
		if (progress[step.id] or 0) < step.count then
			return step
		end
	end
	return nil
end

-- The tracker's lines; `secondsLeft` is the timed step's countdown (nil: not started, its full length shows).
function ObjectiveState.stepLines(
	spec: ObjectiveConfig.FloorSpec,
	progress: { [string]: number },
	secondsLeft: number?
): { StepLine }
	local current = ObjectiveState.current(spec, progress)
	local out: { StepLine } = {}
	for _, step in spec.steps do
		local n = math.min(progress[step.id] or 0, step.count)
		local text: string
		local seconds = step.seconds
		if seconds then
			text = Strings.get(step.label, math.ceil(math.max(0, secondsLeft or seconds)))
		elseif step.count > 1 then
			text = Strings.get(step.label, n, step.count)
		else
			text = Strings.get(step.label)
		end
		table.insert(out, {
			id = step.id,
			text = text,
			done = n >= step.count,
			active = current == step,
			timed = seconds ~= nil and secondsLeft ~= nil and n < step.count,
		})
	end
	return out
end

-- The carried items as one line ("Carrying: Fuse ×2, Master keys"), or nil for none.
function ObjectiveState.carryLine(entries: { CarryEntry }, acid: boolean): string?
	local parts: { string } = {}
	for _, entry in entries do
		local label = Strings.get("Carry." .. entry.kind)
		table.insert(parts, if entry.count > 1 then Strings.get("Carry.Count", label, entry.count) else label)
	end
	if acid then
		table.insert(parts, Strings.get("Carry.AcidFlask"))
	end
	if #parts == 0 then
		return nil
	end
	return Strings.get("Carry.Line", table.concat(parts, ", "))
end

--------------------------------------------------------------------------------
-- Rooms and the nudge
--------------------------------------------------------------------------------

-- A room's spoken name from its layout id: the level prefix dropped, words split at underscores and capitals.
function ObjectiveState.roomName(id: string): string
	local parts = string.split(id, "_")
	if #parts > 1 and (string.match(parts[1], "^L%d+$") or parts[1] == "Lobby") then
		table.remove(parts, 1)
	end
	local words: { string } = {}
	for _, part in parts do
		if string.match(part, "^[%u%d]+$") then
			table.insert(words, part)
		else
			local spaced = string.gsub(part, "(%l)([%u%d])", "%1 %2")
			spaced = string.gsub(spaced, "(%d)(%a)", "%1 %2")
			for word in string.gmatch(spaced, "%S+") do
				table.insert(words, word)
			end
		end
	end
	return table.concat(words, " ")
end

-- The room of `layout` holding the world point (nil outside every room).
function ObjectiveState.roomAt(layout: Layout, point: Vector3): string?
	local origin = WorldConfig.levelOrigin(layout.id)
	local x, z = point.X - origin.X, point.Z - origin.Z
	for _, room in layout.rooms do
		if LayoutSchema.rectContains(room.rect, x, z) then
			return room.id
		end
	end
	return nil
end

-- World centre (floor level) of a room, or nil.
function ObjectiveState.roomCentre(layout: Layout, roomId: string): Vector3?
	local room = LayoutSchema.indexRooms(layout)[roomId]
	if not room then
		return nil
	end
	local c = LayoutSchema.rectCenter(room.rect)
	local origin = WorldConfig.levelOrigin(layout.id)
	return origin + Vector3.new(c.X, 0, c.Y)
end

-- World points (floor level) of every passable doorway of a room.
function ObjectiveState.doorways(layout: Layout, roomId: string): { Vector3 }
	local rooms = LayoutSchema.indexRooms(layout)
	local origin = WorldConfig.levelOrigin(layout.id)
	local out: { Vector3 } = {}
	for _, door in layout.doors do
		if door.kind == "Boarded" or #door.rooms ~= 2 or table.find(door.rooms, roomId) == nil then
			continue
		end
		local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
		local edge = if a and b then LayoutSchema.sharedEdge(a.rect, b.rect) else nil
		if edge then
			local local2 = if edge.axis == "X"
				then Vector3.new(edge.coord, 0, door.at)
				else Vector3.new(door.at, 0, edge.coord)
			table.insert(out, origin + local2)
		end
	end
	return out
end

-- The Tab nudge for a player at `root` among `targets`: the nearest target's room, its centre when the player is in
-- it, else its doorway nearest the player. Nil without a target in a known room.
function ObjectiveState.nudge(layout: Layout, targets: { Target }, root: Vector3): Nudge?
	local best: Target? = nil
	local bestDistance = math.huge
	for _, target in targets do
		local room = if target.room ~= "" then target.room else ObjectiveState.roomAt(layout, target.point)
		if room then
			local d = (target.point - root).Magnitude
			if d < bestDistance then
				best, bestDistance = { room = room, point = target.point }, d
			end
		end
	end
	if not best then
		return nil
	end
	local room = best.room
	local point = ObjectiveState.roomCentre(layout, room) or best.point
	if ObjectiveState.roomAt(layout, root) ~= room then
		local nearest = math.huge
		for _, doorway in ObjectiveState.doorways(layout, room) do
			local d = (doorway - root).Magnitude
			if d < nearest then
				point, nearest = doorway, d
			end
		end
	end
	return {
		point = Vector3.new(point.X, best.point.Y + NUDGE_LIFT, point.Z),
		room = room,
		label = ObjectiveState.roomName(room),
	}
end

return table.freeze(ObjectiveState)
