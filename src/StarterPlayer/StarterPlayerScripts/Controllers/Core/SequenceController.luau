--!strict
-- SequenceController: plays registered Timelines in sync with server time.
--
--   * Owners register timelines (RegisterTimeline(id, spec), validated) and track handlers for their kinds
--     (RegisterTrackHandler(kind, handler)): the camera (FirstPersonController, later phases), creature and door
--     tracks belong to their systems. Built in: "light" (continuous; LightingController.SetOverride on the track's
--     target light id or the light id in the Play arg named by `arg`; released when playback ends unless the track
--     `hold`s a completed value), "sound" (events; each key's value is a SynthPresets name played with
--     AudioController.PlayLocal at the Vector3 / CFrame Play arg named by `arg`, else on the subject, else 2D; late
--     persistent keys start part-way through) and "callback" (events; calls track.callback(ctx, value, late)).
--   * The server announces a moment with OneShot { kind = "Timeline", startAt, subject?, args = { id, ... } }; the
--     timeline `args.id` plays from `startAt` with those args. Play(id, startAt, args?, subject?) does the same
--     locally. Playing an id again restarts it; Stop(id) ends it (handlers release what they hold).
--   * Playbacks update every PreRender against Workspace:GetServerTimeNow() (Timeline fast-forwards late starts).
--     They end with the run.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local Timeline = require(ReplicatedStorage.Shared.Sequence.Timeline)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local AudioController = require(script.Parent.AudioController)
local LightingController = require(script.Parent.LightingController)

local log = Log.new("SequenceController")

local TIMELINE_KIND: Enums.OneShotKind = "Timeline"
local ID_ARG = "id"

local SequenceController = {}

SequenceController.Name = "SequenceController"

local serviceTrove = Trove.new()
local specs: { [string]: Timeline.Spec } = {}
local handlers: { [string]: Timeline.TrackHandler } = {}
local playing: { [string]: Timeline.Playback } = {}
local updater: RBXScriptConnection? = nil
local warnedKinds: { [string]: boolean } = {}

--------------------------------------------------------------------------------
-- Built-in handlers
--------------------------------------------------------------------------------

-- The light id a "light" track drives: its target, else the Play arg it names.
local function lightIdOf(ctx: Timeline.Context, track: Timeline.Track): string?
	if track.target then
		return track.target
	end
	local name = track.arg
	local value = if name then ctx.args[name] else nil
	return if type(value) == "string" then value else nil
end

local LIGHT: Timeline.TrackHandler = {
	mode = "Continuous",
	apply = function(ctx: Timeline.Context, track: Timeline.Track, value: Timeline.Value)
		local lightId = lightIdOf(ctx, track)
		if lightId and type(value) == "number" then
			LightingController.SetOverride(lightId, value)
		end
	end,
	stop = function(ctx: Timeline.Context, track: Timeline.Track, completed: boolean)
		if completed and track.hold then
			return
		end
		local lightId = lightIdOf(ctx, track)
		if lightId then
			LightingController.SetOverride(lightId, nil)
		end
	end,
}

local SOUND: Timeline.TrackHandler = {
	mode = "Events",
	fire = function(ctx: Timeline.Context, track: Timeline.Track, key: Timeline.Key, late: number)
		local preset = key.value
		if type(preset) ~= "string" or not SynthPresets.has(preset) then
			log.warnThrottled("sound:" .. tostring(preset), 30, "%s: unknown sound preset %s", ctx.id, tostring(preset))
			return
		end
		local name = track.arg
		local at = if name then ctx.args[name] else nil
		local position: Vector3? = nil
		if typeof(at) == "Vector3" then
			position = at :: Vector3
		elseif typeof(at) == "CFrame" then
			position = (at :: CFrame).Position
		end
		local subject = ctx.subject
		local attach: Instance? = nil
		if position == nil and subject and subject:IsDescendantOf(Workspace) then
			attach = subject
		end
		AudioController.PlayLocal(preset, {
			position = position,
			attach = attach,
			volume = track.volume,
			startOffset = if late > Timeline.LateTolerance then late else nil,
			seed = MathUtil.hash(ctx.id .. ":" .. tostring(key.t)) % 2_147_483_646 + 1,
		})
	end,
}

local CALLBACK: Timeline.TrackHandler = {
	mode = "Events",
	fire = function(ctx: Timeline.Context, track: Timeline.Track, key: Timeline.Key, late: number)
		local callback = track.callback
		if callback then
			callback(ctx, key.value, late)
		end
	end,
}

--------------------------------------------------------------------------------
-- Playback
--------------------------------------------------------------------------------

local function resolve(kind: string): Timeline.TrackHandler?
	local handler = handlers[kind]
	if handler == nil and not warnedKinds[kind] then
		warnedKinds[kind] = true
		log.warn("no track handler for kind %s yet; its tracks wait until one registers", kind)
	end
	return handler
end

local function update()
	local now = Workspace:GetServerTimeNow()
	for id, playback in table.clone(playing) do
		local ok, running = xpcall(function(): boolean
			return playback:Update(now)
		end, function(err: any): any
			log.warnThrottled("update:" .. id, 5, "timeline %s failed: %s", id, tostring(err))
			return err
		end)
		if not ok or not running then
			if playing[id] == playback then
				playing[id] = nil
			end
			if not ok then
				xpcall(function()
					playback:Stop()
				end, function(err: any)
					log.warnThrottled("stop:" .. id, 5, "timeline %s failed to stop: %s", id, tostring(err))
				end)
			end
		end
	end
	if next(playing) == nil then
		local connection = updater
		updater = nil
		if connection then
			connection:Disconnect()
		end
	end
end

local function ensureUpdater()
	if updater == nil then
		updater = RunService.PreRender:Connect(update)
	end
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- Registers (or replaces) the timeline `id`. Invalid specs are refused with the reasons logged.
function SequenceController.RegisterTimeline(id: string, spec: Timeline.Spec)
	local errors = Timeline.validate(spec)
	if #errors > 0 then
		log.warn("timeline %s refused: %s", id, table.concat(errors, "; "))
		return
	end
	specs[id] = spec
end

-- Registers (or replaces) the handler that plays tracks of `kind`.
function SequenceController.RegisterTrackHandler(kind: string, handler: Timeline.TrackHandler)
	handlers[kind] = handler
	warnedKinds[kind] = nil
end

-- Plays timeline `id` from server time `startAt` (restarting it when it is already playing).
function SequenceController.Play(id: string, startAt: number, args: { [string]: Types.OneShotArg }?, subject: Instance?)
	local spec = specs[id]
	if not spec then
		log.warnThrottled("play:" .. id, 30, "no timeline %s", id)
		return
	end
	SequenceController.Stop(id)
	local start = if MathUtil.isFinite(startAt) then startAt else Workspace:GetServerTimeNow()
	local playback = Timeline.play(spec, id, start, resolve, args, subject)
	playing[id] = playback
	ensureUpdater()
	update()
end

-- Ends timeline `id` now; its handlers release what they hold.
function SequenceController.Stop(id: string)
	local playback = playing[id]
	if not playback then
		return
	end
	playing[id] = nil
	playback:Stop()
end

function SequenceController.IsPlaying(id: string): boolean
	return playing[id] ~= nil
end

function SequenceController.HasTimeline(id: string): boolean
	return specs[id] ~= nil
end

-- Ends every playback.
function SequenceController.StopAll()
	for id in table.clone(playing) do
		SequenceController.Stop(id)
	end
end

--------------------------------------------------------------------------------
-- OneShot
--------------------------------------------------------------------------------

local function onOneShot(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local event = payload :: { [string]: any }
	if event.kind ~= TIMELINE_KIND then
		return
	end
	local raw = event.args
	if type(raw) ~= "table" then
		return
	end
	local id = raw[ID_ARG]
	if type(id) ~= "string" then
		log.warnThrottled("oneshot", 10, "Timeline OneShot without an id")
		return
	end
	local args: { [string]: Types.OneShotArg } = {}
	for key, value in raw :: { [any]: any } do
		local kind = typeof(value)
		if
			type(key) == "string"
			and (kind == "string" or kind == "number" or kind == "boolean" or kind == "Vector3" or kind == "CFrame")
		then
			args[key] = value
		end
	end
	local startAt = if type(event.startAt) == "number" then event.startAt else Workspace:GetServerTimeNow()
	local subject = if typeof(event.subject) == "Instance" then event.subject else nil
	SequenceController.Play(id, startAt, args, subject)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function SequenceController.Init()
	SequenceController.RegisterTrackHandler("light", LIGHT)
	SequenceController.RegisterTrackHandler("sound", SOUND)
	SequenceController.RegisterTrackHandler("callback", CALLBACK)
end

function SequenceController.Start()
	local connection = Net.Client.on("OneShot", onOneShot)
	if connection then
		serviceTrove:Add(connection)
	end
end

function SequenceController.OnRunEnded()
	SequenceController.StopAll()
end

return table.freeze(SequenceController)
