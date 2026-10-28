--!strict
-- Timeline: easing curves, track sampling (numbers, vectors, CFrames, colours, stepped values; holding before the
-- first and after the last key), spec validation, key windows, playback on time (each event key once, continuous
-- values applied as they change, handlers stopped at the end), waiting for startAt, late starts (past one-shot keys
-- skipped unless persistent, continuous tracks jumping to the current value), Stop, late-registered handlers, and
-- SequenceController's registration / playback of a callback timeline.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local SequenceController = require(StarterPlayer.StarterPlayerScripts.Controllers.Core.SequenceController)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local Timeline = require(ReplicatedStorage.Shared.Sequence.Timeline)
local Types = require(ReplicatedStorage.Shared.Types)

type Expect = SpecRunner.Expect

type Log = {
	fired: { { kind: string, value: Timeline.Value, late: number } },
	applied: { { kind: string, value: Timeline.Value } },
	stopped: { { kind: string, completed: boolean } },
}

local function recorder(): (Log, Timeline.HandlerResolver)
	local log: Log = { fired = {}, applied = {}, stopped = {} }
	local events: Timeline.TrackHandler = {
		mode = "Events",
		fire = function(_ctx: Timeline.Context, track: Timeline.Track, key: Timeline.Key, late: number)
			table.insert(log.fired, { kind = track.kind, value = key.value, late = late })
		end,
		stop = function(_ctx: Timeline.Context, track: Timeline.Track, completed: boolean)
			table.insert(log.stopped, { kind = track.kind, completed = completed })
		end,
	}
	local continuous: Timeline.TrackHandler = {
		mode = "Continuous",
		apply = function(_ctx: Timeline.Context, track: Timeline.Track, value: Timeline.Value)
			table.insert(log.applied, { kind = track.kind, value = value })
		end,
		stop = function(_ctx: Timeline.Context, track: Timeline.Track, completed: boolean)
			table.insert(log.stopped, { kind = track.kind, completed = completed })
		end,
	}
	local function resolve(kind: string): Timeline.TrackHandler?
		if kind == "cue" then
			return events
		elseif kind == "level" then
			return continuous
		end
		return nil
	end
	return log, resolve
end

local SPEC: Timeline.Spec = {
	duration = 4,
	tracks = {
		{
			kind = "cue",
			keys = {
				{ t = 0, value = "open" },
				{ t = 1, value = "persisted", persist = true },
				{ t = 1.5, value = "skippable" },
				{ t = 3, value = "late" },
				{ t = 4, value = "end" },
			},
		},
		{
			kind = "level",
			keys = {
				{ t = 0, value = 0 },
				{ t = 2, value = 10, ease = "Linear" },
				{ t = 4, value = 0, ease = "Step" },
			},
		},
	},
}

local function values(entries: { { kind: string, value: Timeline.Value, late: number } }): string
	local out: { string } = {}
	for _, entry in entries do
		table.insert(out, tostring(entry.value))
	end
	return table.concat(out, ",")
end

return {
	["ease curves start at 0, end at 1 and rise monotonically"] = function(t: Expect)
		for _, name: Timeline.Ease in Timeline.Eases do
			t.near(Timeline.ease(name, 0), 0, 1e-6, name .. " at 0")
			t.near(Timeline.ease(name, 1), 1, 1e-6, name .. " at 1")
			if name ~= "InBack" and name ~= "OutBack" then
				local previous = 0
				for step = 1, 20 do
					local value = Timeline.ease(name, step / 20)
					t.truthy(value >= previous - 1e-9, name .. " monotonic")
					previous = value
				end
			end
		end
		t.eq(Timeline.ease("Step", 0.99), 0, "Step holds until the key")
		t.near(Timeline.ease("InQuad", 0.5), 0.25, 1e-9)
		t.near(Timeline.ease("OutQuad", 0.5), 0.75, 1e-9)
		t.truthy(Timeline.ease("OutBack", 0.7) > 1, "OutBack overshoots")
		t.near(Timeline.ease(nil, 2), 1, 1e-9, "clamped, linear by default")
	end,

	["tracks sample numbers, vectors, CFrames and colours; strings and booleans step"] = function(t: Expect)
		local numbers: Timeline.Track = {
			kind = "x",
			keys = { { t = 1, value = 2 }, { t = 3, value = 6, ease = "InQuad" } },
		}
		t.eq(Timeline.sampleTrack(numbers, 0), 2, "holds the first value before it")
		t.near(Timeline.sampleTrack(numbers, 2) :: number, 3, 1e-9, "destination key's ease")
		t.eq(Timeline.sampleTrack(numbers, 5), 6, "holds the last value after it")
		local vectors: Timeline.Track = {
			kind = "x",
			keys = { { t = 0, value = Vector3.zero }, { t = 2, value = Vector3.new(2, 4, 6) } },
		}
		t.eq(Timeline.sampleTrack(vectors, 1), Vector3.new(1, 2, 3), "Vector3 lerp")
		local frames: Timeline.Track = {
			kind = "x",
			keys = { { t = 0, value = CFrame.new() }, { t = 1, value = CFrame.new(0, 2, 0) } },
		}
		local mid = Timeline.sampleTrack(frames, 0.5) :: CFrame
		t.near(mid.Position.Y, 1, 1e-6, "CFrame lerp")
		local colours: Timeline.Track = {
			kind = "x",
			keys = { { t = 0, value = Color3.new(0, 0, 0) }, { t = 1, value = Color3.new(1, 0.5, 0) } },
		}
		t.near((Timeline.sampleTrack(colours, 0.5) :: Color3).R, 0.5, 1e-6, "Color3 lerp")
		local words: Timeline.Track = {
			kind = "x",
			keys = { { t = 0, value = "a" }, { t = 1, value = "b" } },
		}
		t.eq(Timeline.sampleTrack(words, 0.99), "a", "strings step")
		t.eq(Timeline.sampleTrack(words, 1), "b", "and switch at the key")
		t.eq(Timeline.sampleTrack({ kind = "x", keys = {} }, 1), nil, "no keys, no value")
		local all = Timeline.sample(SPEC, 0.9)
		t.eq(all[1], "open", "event track holds its last key")
		t.near(all[2] :: number, 4.5, 1e-9, "continuous track sampled")
		t.eq(Timeline.sample(SPEC, 1)[1], "persisted", "a key counts from its own time")
	end,

	["validate reports unsorted, out-of-range, mixed and unknown entries"] = function(t: Expect)
		t.eq(#Timeline.validate(SPEC), 0, "the sample spec is valid")
		local bad: Timeline.Spec = {
			duration = 2,
			tracks = {
				{ kind = "a", keys = { { t = 1, value = 1 }, { t = 0.5, value = 2 } } },
				{ kind = "b", keys = { { t = 3, value = 1 } } },
				{ kind = "c", keys = { { t = 0, value = 1 }, { t = 1, value = "x" } } },
				{ kind = "d", keys = { { t = 0, value = 1, ease = "Wobble" :: any } } },
				{ kind = "", keys = {} },
			},
		}
		local errors = Timeline.validate(bad)
		local text = table.concat(errors, "\n")
		t.truthy(string.find(text, "sorted", 1, true), "unsorted keys")
		t.truthy(string.find(text, "within", 1, true), "key past the duration")
		t.truthy(string.find(text, "earlier keys", 1, true), "mixed value types")
		t.truthy(string.find(text, "Wobble", 1, true), "unknown ease")
		t.truthy(string.find(text, "non-empty", 1, true), "empty kind")
		t.truthy(string.find(text, "at least one key", 1, true), "no keys")
		t.truthy(#Timeline.validate({ duration = 0, tracks = {} }) > 0, "zero duration")
	end,

	["keysBetween and fastForward pick the right keys"] = function(t: Expect)
		local track = SPEC.tracks[1]
		local window = Timeline.keysBetween(track, 1, 3)
		t.eq(#window, 2, "exclusive start")
		t.eq(window[1].value, "skippable")
		t.eq(#Timeline.keysBetween(track, 1, 3, true), 3, "inclusive start")
		local due = Timeline.fastForward(SPEC, 3.1, function(candidate: Timeline.Track): boolean
			return candidate.kind == "cue"
		end)
		t.eq(#due, 2, "persisted + within tolerance")
		t.eq(due[1].key.value, "persisted")
		t.near(due[1].late, 2.1, 1e-9, "told how late")
		t.eq(due[2].key.value, "late")
	end,

	["playback on time fires every key once and applies changing values"] = function(t: Expect)
		local log, resolve = recorder()
		local playback = Timeline.play(SPEC, "spec", 100, resolve)
		t.truthy(playback:Update(99.5), "waiting before startAt")
		t.eq(#log.fired + #log.applied, 0, "nothing before the start")
		local now = 100
		while playback:Update(now) do
			now += 0.1
		end
		t.eq(values(log.fired), "open,persisted,skippable,late,end", "each key once, in order")
		t.eq(log.applied[1].value, 0, "first value")
		local peak = 0
		for _, entry in log.applied do
			peak = math.max(peak, entry.value :: number)
		end
		t.near(peak, 10, 1e-6, "reaches the peak")
		t.eq(log.applied[#log.applied].value, 0, "final value applied")
		t.eq(#log.stopped, 2, "every handler stopped")
		t.truthy(log.stopped[1].completed, "completed")
		t.falsy(playback:Update(now + 1), "finished")
		t.truthy(playback:IsFinished())
	end,

	["a late start skips past one-shot keys but keeps persistent ones, and jumps continuous tracks"] = function(
		t: Expect
	)
		local log, resolve = recorder()
		local playback = Timeline.play(SPEC, "spec", 100, resolve)
		playback:Update(102.6)
		t.eq(values(log.fired), "persisted", "past keys skipped, the persistent one fired")
		t.near(log.fired[1].late, 1.6, 1e-6, "told how late it fired")
		t.near(log.applied[1].value :: number, 10, 1e-6, "continuous track jumps to the current value")
		playback:Update(103.05)
		t.eq(log.fired[#log.fired].value, "late", "later keys still fire")
		t.truthy(log.fired[#log.fired].late < 0.1, "on time")
	end,

	["Stop ends a playback once and releases its handlers"] = function(t: Expect)
		local log, resolve = recorder()
		local playback = Timeline.play(SPEC, "spec", 0, resolve)
		playback:Update(0.5)
		playback:Stop()
		playback:Stop()
		t.eq(#log.stopped, 2, "stopped once per track")
		t.falsy(log.stopped[1].completed, "not completed")
		local fired = #log.fired
		t.falsy(playback:Update(3.5), "no updates after Stop")
		t.eq(#log.fired, fired, "nothing fires after Stop")
	end,

	["a handler registered after the start joins the playback"] = function(t: Expect)
		local registered: Timeline.TrackHandler? = nil
		local seen: { Timeline.Value } = {}
		local function resolve(_kind: string): Timeline.TrackHandler?
			return registered
		end
		local spec: Timeline.Spec = {
			duration = 2,
			tracks = { { kind = "late", keys = { { t = 0, value = 1 }, { t = 2, value = 3 } } } },
		}
		local playback = Timeline.play(spec, "late", 0, resolve)
		playback:Update(0.5)
		t.eq(#seen, 0, "no handler yet")
		registered = {
			mode = "Continuous",
			apply = function(_ctx: Timeline.Context, _track: Timeline.Track, value: Timeline.Value)
				table.insert(seen, value)
			end,
		}
		playback:Update(1)
		t.near(seen[1] :: number, 2, 1e-6, "joined at the current value")
	end,

	["SequenceController plays registered callback timelines and refuses invalid ones"] = function(t: Expect)
		local calls: { Timeline.Value } = {}
		local spec: Timeline.Spec = {
			duration = 1,
			tracks = {
				{
					kind = "callback",
					keys = { { t = 0, value = "begin" }, { t = 1, value = "finish" } },
					callback = function(ctx: Timeline.Context, value: Timeline.Value, _late: number)
						table.insert(calls, value)
						t.eq(ctx.args.who, "spec", "args reach the callback")
					end,
				},
			},
		}
		SequenceController.Init()
		SequenceController.RegisterTimeline("Spec.Callback", spec)
		t.truthy(SequenceController.HasTimeline("Spec.Callback"), "registered")
		local args: { [string]: Types.OneShotArg } = { who = "spec" }
		SequenceController.Play("Spec.Callback", Workspace:GetServerTimeNow(), args)
		t.eq(calls[1], "begin", "the first key fires as playback starts")
		t.truthy(SequenceController.IsPlaying("Spec.Callback"), "playing")
		SequenceController.Stop("Spec.Callback")
		t.falsy(SequenceController.IsPlaying("Spec.Callback"), "stopped")
		SequenceController.RegisterTimeline("Spec.Bad", { duration = -1, tracks = {} })
		t.falsy(SequenceController.HasTimeline("Spec.Bad"), "invalid spec refused")
	end,
}
