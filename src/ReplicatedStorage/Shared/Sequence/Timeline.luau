--!strict
-- Timeline: keyed tracks played against server time, so every client runs a scripted moment on the same frame.
--
-- A Spec is { duration, tracks }. Each track names a handler `kind` ("light", "sound", "callback", and kinds later
-- phases register: "camera", "creature", "door", ...) and holds keys { t, value, ease?, persist? } sorted by time.
-- Handlers decide how a track plays:
--   * Continuous tracks are sampled every update: the value between two keys is interpolated (numbers, Vector3,
--     CFrame, Color3; booleans and strings step) with the destination key's ease; before the first key the track
--     holds the first value, after the last key the last value. The handler's `apply` sees each new value.
--   * Event tracks fire each key once, when playback passes its time (`fire`, with how late it fired).
-- Playback starts at `startAt` (server time) and waits until then. A playback first updated after its start is
-- fast-forwarded: event keys already more than LateTolerance seconds in the past are skipped unless the key (or its
-- track) is `persist` (those fire at once, told how late they are); continuous tracks simply jump to the current
-- sample. When the duration is reached the last values are applied, every handler's `stop` runs (completed = true)
-- and the playback ends; Stop() ends it early (completed = false), so handlers release what they hold.
--
-- Everything here is pure (no services, no clock): the caller passes `now` to Update. SequenceController drives it
-- on the client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)

export type Value = number | boolean | string | Vector3 | CFrame | Color3

export type Ease =
	"Linear"
	| "Step"
	| "InQuad"
	| "OutQuad"
	| "InOutQuad"
	| "InCubic"
	| "OutCubic"
	| "InOutCubic"
	| "InSine"
	| "OutSine"
	| "InOutSine"
	| "InExpo"
	| "OutExpo"
	| "InOutExpo"
	| "InBack"
	| "OutBack"

export type Key = {
	t: number, -- seconds from the start
	value: Value,
	ease: Ease?, -- shape of the segment arriving at this key (default Linear)
	persist: boolean?, -- event keys: still fire when playback starts after them
}

export type Context = {
	id: string,
	startAt: number, -- server time
	args: { [string]: Types.OneShotArg },
	subject: Instance?,
	elapsed: number, -- seconds into the timeline at the current update
}

export type Track = {
	kind: string, -- handler kind
	keys: { Key },
	target: string?, -- handler-specific target (the light id for "light")
	arg: string?, -- name of a Play arg the handler reads (a light id, a sound position)
	volume: number?, -- "sound": voice volume
	persist: boolean?, -- event tracks: every key persists
	hold: boolean?, -- continuous tracks: keep the last value after the timeline completes
	callback: ((ctx: Context, value: Value, late: number) -> ())?, -- "callback" tracks
}

export type Spec = {
	duration: number,
	tracks: { Track },
}

export type Mode = "Continuous" | "Events"

export type TrackHandler = {
	mode: Mode,
	apply: ((ctx: Context, track: Track, value: Value) -> ())?, -- continuous: a new sampled value
	fire: ((ctx: Context, track: Track, key: Key, late: number) -> ())?, -- events: a key's time was reached
	stop: ((ctx: Context, track: Track, completed: boolean) -> ())?, -- playback ended (or was stopped)
}

export type HandlerResolver = (kind: string) -> TrackHandler?

export type Playback = {
	Id: string,
	Spec: Spec,
	Context: Context,
	-- Advances to server time `now`; returns false once the playback has ended.
	Update: (self: Playback, now: number) -> boolean,
	Stop: (self: Playback) -> (),
	IsFinished: (self: Playback) -> boolean,
}

export type DueKey = { track: number, key: Key, late: number }

local Timeline = {}

-- Event keys this far in the past at the first update still fire normally (network jitter, a frame of delay).
local LATE_TOLERANCE = 0.25
local BACK_C1 = 1.70158
local BACK_C3 = BACK_C1 + 1

Timeline.LateTolerance = LATE_TOLERANCE

local EASES: { Ease } = {
	"Linear",
	"Step",
	"InQuad",
	"OutQuad",
	"InOutQuad",
	"InCubic",
	"OutCubic",
	"InOutCubic",
	"InSine",
	"OutSine",
	"InOutSine",
	"InExpo",
	"OutExpo",
	"InOutExpo",
	"InBack",
	"OutBack",
}
Timeline.Eases = table.freeze(EASES)

--------------------------------------------------------------------------------
-- Pure evaluation
--------------------------------------------------------------------------------

-- Eased progress for `x` in [0, 1] (clamped). Step stays 0 until x reaches 1.
function Timeline.ease(name: Ease?, x: number): number
	local t = math.clamp(x, 0, 1)
	if name == nil or name == "Linear" then
		return t
	elseif name == "Step" then
		return if t >= 1 then 1 else 0
	elseif name == "InQuad" then
		return t * t
	elseif name == "OutQuad" then
		return 1 - (1 - t) * (1 - t)
	elseif name == "InOutQuad" then
		return if t < 0.5 then 2 * t * t else 1 - ((-2 * t + 2) ^ 2) / 2
	elseif name == "InCubic" then
		return t * t * t
	elseif name == "OutCubic" then
		return 1 - (1 - t) ^ 3
	elseif name == "InOutCubic" then
		return if t < 0.5 then 4 * t * t * t else 1 - ((-2 * t + 2) ^ 3) / 2
	elseif name == "InSine" then
		return 1 - math.cos(t * math.pi / 2)
	elseif name == "OutSine" then
		return math.sin(t * math.pi / 2)
	elseif name == "InOutSine" then
		return -(math.cos(math.pi * t) - 1) / 2
	elseif name == "InExpo" then
		return if t <= 0 then 0 else 2 ^ (10 * t - 10)
	elseif name == "OutExpo" then
		return if t >= 1 then 1 else 1 - 2 ^ (-10 * t)
	elseif name == "InOutExpo" then
		if t <= 0 or t >= 1 then
			return t
		end
		return if t < 0.5 then (2 ^ (20 * t - 10)) / 2 else (2 - 2 ^ (-20 * t + 10)) / 2
	elseif name == "InBack" then
		return BACK_C3 * t * t * t - BACK_C1 * t * t
	elseif name == "OutBack" then
		local u = t - 1
		return 1 + BACK_C3 * u * u * u + BACK_C1 * u * u
	end
	return t
end

-- `a` toward `b` by `alpha`: numbers, Vector3, CFrame and Color3 interpolate; anything else steps at alpha 1.
function Timeline.interpolate(a: Value, b: Value, alpha: number): Value
	if type(a) == "number" and type(b) == "number" then
		return a + (b - a) * alpha
	end
	local kind = typeof(a)
	if kind == typeof(b) then
		if kind == "Vector3" then
			return (a :: Vector3):Lerp(b :: Vector3, alpha)
		elseif kind == "CFrame" then
			return (a :: CFrame):Lerp(b :: CFrame, alpha)
		elseif kind == "Color3" then
			return (a :: Color3):Lerp(b :: Color3, alpha)
		end
	end
	return if alpha >= 1 then b else a
end

-- The track's value at `t` seconds (nil for a track without keys).
function Timeline.sampleTrack(track: Track, t: number): Value?
	local keys = track.keys
	local count = #keys
	if count == 0 then
		return nil
	end
	local first = keys[1]
	if t <= first.t then
		return first.value
	end
	for index = 2, count do
		local key = keys[index]
		if t < key.t then
			local previous = keys[index - 1]
			local span = key.t - previous.t
			if span <= 0 then
				return key.value
			end
			local alpha = Timeline.ease(key.ease, (t - previous.t) / span)
			return Timeline.interpolate(previous.value, key.value, alpha)
		end
	end
	return keys[count].value
end

-- Every track's value at `t`, by track index (tracks without keys are absent).
function Timeline.sample(spec: Spec, t: number): { [number]: Value }
	local out: { [number]: Value } = {}
	for index, track in spec.tracks do
		local value = Timeline.sampleTrack(track, t)
		if value ~= nil then
			out[index] = value
		end
	end
	return out
end

-- Keys with from < t <= to (from <= t <= to when `inclusive`), in time order.
function Timeline.keysBetween(track: Track, from: number, to: number, inclusive: boolean?): { Key }
	local out: { Key } = {}
	for _, key in track.keys do
		local after = if inclusive then key.t >= from else key.t > from
		if after and key.t <= to then
			table.insert(out, key)
		end
	end
	return out
end

-- The event keys a playback first updated `elapsed` seconds after its start must fire now: those due within the
-- last LateTolerance seconds, plus earlier ones that persist. `late` is how far past each key's time it fires.
function Timeline.fastForward(spec: Spec, elapsed: number, isEvents: (track: Track) -> boolean): { DueKey }
	local out: { DueKey } = {}
	local cutoff = elapsed - LATE_TOLERANCE
	for index, track in spec.tracks do
		if not isEvents(track) then
			continue
		end
		for _, key in track.keys do
			if key.t > elapsed then
				break
			end
			if key.t >= cutoff or key.persist or track.persist then
				table.insert(out, { track = index, key = key, late = math.max(0, elapsed - key.t) })
			end
		end
	end
	table.sort(out, function(a: DueKey, b: DueKey): boolean
		if a.key.t == b.key.t then
			return a.track < b.track
		end
		return a.key.t < b.key.t
	end)
	return out
end

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

-- Problems with a spec (empty when it is playable).
function Timeline.validate(spec: Spec): { string }
	local errors: { string } = {}
	if type(spec) ~= "table" then
		table.insert(errors, "spec is not a table")
		return errors
	end
	local duration = spec.duration
	if type(duration) ~= "number" or not isFinite(duration) or duration <= 0 then
		table.insert(errors, "duration must be a positive number")
		duration = math.huge
	end
	if type(spec.tracks) ~= "table" then
		table.insert(errors, "tracks must be a list")
		return errors
	end
	for index, track in spec.tracks do
		local label = string.format("track %d (%s)", index, tostring(track.kind))
		if type(track.kind) ~= "string" or track.kind == "" then
			table.insert(errors, label .. ": kind must be a non-empty string")
		end
		if type(track.keys) ~= "table" or #track.keys == 0 then
			table.insert(errors, label .. ": needs at least one key")
			continue
		end
		local kind: string? = nil
		local last = -math.huge
		for keyIndex, key in track.keys do
			local where = string.format("%s key %d", label, keyIndex)
			if type(key.t) ~= "number" or not isFinite(key.t) or key.t < 0 or key.t > duration then
				table.insert(errors, where .. ": t must lie within [0, duration]")
			elseif key.t < last then
				table.insert(errors, where .. ": keys must be sorted by t")
			else
				last = key.t
			end
			local valueKind = typeof(key.value)
			if kind == nil then
				kind = valueKind
			elseif kind ~= valueKind then
				table.insert(errors, string.format("%s: value is a %s, earlier keys are %s", where, valueKind, kind))
			end
			if key.ease ~= nil and table.find(EASES, key.ease) == nil then
				table.insert(errors, where .. ": unknown ease " .. tostring(key.ease))
			end
		end
	end
	return errors
end

--------------------------------------------------------------------------------
-- Playback
--------------------------------------------------------------------------------

-- A playback of `spec` (call Update every frame with the server time). Handlers are looked up by kind on each
-- update until found, so a handler registered after the playback started still joins it.
function Timeline.play(
	spec: Spec,
	id: string,
	startAt: number,
	resolve: HandlerResolver,
	args: { [string]: Types.OneShotArg }?,
	subject: Instance?
): Playback
	local ctx: Context = {
		id = id,
		startAt = startAt,
		args = args or {},
		subject = subject,
		elapsed = 0,
	}
	local handlers: { [number]: TrackHandler } = {}
	local applied: { [number]: Value } = {}
	local lastElapsed: number? = nil
	local finished = false

	local function handlerFor(index: number): TrackHandler?
		local cached = handlers[index]
		if cached then
			return cached
		end
		local found = resolve(spec.tracks[index].kind)
		if found then
			handlers[index] = found
		end
		return found
	end

	local function isEvents(track: Track): boolean
		local index = table.find(spec.tracks, track)
		local handler = if index then handlerFor(index) else nil
		return handler ~= nil and handler.mode == "Events"
	end

	local function finish(completed: boolean)
		if finished then
			return
		end
		finished = true
		for index, track in spec.tracks do
			local handler = handlerFor(index)
			local stop = if handler then handler.stop else nil
			if stop then
				stop(ctx, track, completed)
			end
		end
	end

	local playback: Playback
	playback = {
		Id = id,
		Spec = spec,
		Context = ctx,
		Update = function(_self: Playback, now: number): boolean
			if finished then
				return false
			end
			local elapsed = now - startAt
			if elapsed < 0 then
				return true
			end
			local at = math.min(elapsed, spec.duration)
			ctx.elapsed = at
			local previous = lastElapsed
			if previous == nil then
				for _, due in Timeline.fastForward(spec, at, isEvents) do
					local handler = handlerFor(due.track)
					local fire = if handler then handler.fire else nil
					if fire then
						fire(ctx, spec.tracks[due.track], due.key, math.max(0, elapsed - due.key.t))
					end
				end
			end
			for index, track in spec.tracks do
				local handler = handlerFor(index)
				if not handler then
					continue
				end
				if handler.mode == "Events" then
					if previous ~= nil then
						local fire = handler.fire
						if fire then
							for _, key in Timeline.keysBetween(track, previous, at, false) do
								fire(ctx, track, key, math.max(0, elapsed - key.t))
							end
						end
					end
				else
					local value = Timeline.sampleTrack(track, at)
					local apply = handler.apply
					if value ~= nil and apply and applied[index] ~= value then
						applied[index] = value
						apply(ctx, track, value)
					end
				end
			end
			lastElapsed = at
			if elapsed >= spec.duration then
				finish(true)
				return false
			end
			return true
		end,
		Stop = function(_self: Playback)
			finish(false)
		end,
		IsFinished = function(_self: Playback): boolean
			return finished
		end,
	}
	return playback
end

return table.freeze(Timeline)
