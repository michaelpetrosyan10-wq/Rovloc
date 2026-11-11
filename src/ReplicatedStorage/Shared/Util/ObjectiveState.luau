--!strict
-- ObjectiveState: how the floor objective travels from ObjectiveService to the HUD (pure; shared by both sides).
--
--   Steps     ReplicatedStorage ObjectiveSteps: "<StepId>=<done>" pairs joined by ";" in the floor's step order
--   Carrying  Player Carrying: "<Kind>:<n>" pairs joined by ";" in the order first carried
--
-- stepLines turns a floor's steps into the tracker's lines (the label with its count, done / active flags).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)

export type StepLine = { id: string, text: string, done: boolean, active: boolean }

local ObjectiveState = {}

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

-- The tracker's lines.
function ObjectiveState.stepLines(spec: ObjectiveConfig.FloorSpec, progress: { [string]: number }): { StepLine }
	local current = ObjectiveState.current(spec, progress)
	local out: { StepLine } = {}
	for _, step in spec.steps do
		local n = math.min(progress[step.id] or 0, step.count)
		local text: string
		if step.count > 1 then
			text = Strings.get(step.label, n, step.count)
		else
			text = Strings.get(step.label)
		end
		table.insert(out, {
			id = step.id,
			text = text,
			done = n >= step.count,
			active = current == step,
		})
	end
	return out
end

-- The carried items as one line ("Carrying: Fuse ×2, Master keys"), or nil for none.
function ObjectiveState.carryLine(entries: { CarryEntry }): string?
	local parts: { string } = {}
	for _, entry in entries do
		local label = Strings.get("Carry." .. entry.kind)
		table.insert(parts, if entry.count > 1 then Strings.get("Carry.Count", label, entry.count) else label)
	end
	if #parts == 0 then
		return nil
	end
	return Strings.get("Carry.Line", table.concat(parts, ", "))
end

return table.freeze(ObjectiveState)
