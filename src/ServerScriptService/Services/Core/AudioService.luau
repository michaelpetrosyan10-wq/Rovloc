--!strict
-- AudioService: the server's only way to make a sound. It never creates Sounds; it sends an AudioCue
-- (Types.AudioCuePayload) and every client synthesizes the preset itself (AudioController -> SoundSynthesizer).
--
--   PlayAt(preset, position, options?)   3D at a fixed point, for everyone (or everyone but options.except)
--   PlayOn(preset, attach, options?)     3D following a BasePart / Attachment / Model; the cue also carries the
--                                        target's current position, so a client that cannot see the instance
--                                        still hears it in the right place
--   PlayFor(player, preset, options?)    one player only: 2D by default (heartbeat, jumpscare sting), or 3D when
--                                        options.position / options.attach are given
--
-- Looped presets (SynthPresets.isLooped) need a lifetime: options.duration (seconds, e.g. a server-timed unscrew
-- channel) or an attach target (the loop ends when the instance leaves the world). A looped cue with neither is
-- dropped with a warning, so no client is ever left with a loop nothing can end.
--
-- Every cue is stamped startAt = GetServerTimeNow() + GameConfig.OneShotLead + (options.delay or 0), so all clients
-- start it on the same frame; late clients fast-forward or drop it (AudioController). The seed travels with the
-- cue, so every client hears the same jitter. Unknown presets and non-finite input are logged and dropped.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local Types = require(ReplicatedStorage.Shared.Types)

local log = Log.new("Audio")

export type CueOptions = {
	volume: number?, -- voice volume multiplier (0..4)
	seed: number?, -- jitter seed (default: a fresh one per cue)
	except: Player?, -- PlayAt / PlayOn: everyone but this player (e.g. the player who made the noise)
	delay: number?, -- extra seconds before the cue starts
	duration: number?, -- looped presets: seconds until the loop fades out
	position: Vector3?, -- PlayFor only: play in 3D at this point
	attach: Instance?, -- PlayFor only: play in 3D following this instance
}

local REMOTE = "AudioCue"
local MAX_DELAY = 30
local MIN_DURATION = 0.05
local MAX_DURATION = 600
local MAX_VOLUME = 4
local MAX_SEED = 2_147_483_646

local AudioService = {}

AudioService.Name = "AudioService"

local seedSource = Random.new()

local function worldPosition(instance: Instance): Vector3?
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Attachment") then
		return instance.WorldPosition
	end
	if instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	return nil
end

local function finite(value: number?): boolean
	return value == nil or MathUtil.isFinite(value)
end

-- Builds a validated cue, or nil (with a throttled warning) when the request is unusable.
local function buildCue(
	preset: string,
	options: CueOptions?,
	position: Vector3?,
	attach: Instance?
): Types.AudioCuePayload?
	if type(preset) ~= "string" or not SynthPresets.has(preset) then
		log.warnThrottled("preset" .. tostring(preset), 30, "unknown preset %s; cue dropped", tostring(preset))
		return nil
	end
	local opts: CueOptions = options or {}
	if position and not MathUtil.isFiniteVector(position) then
		log.warnThrottled("position" .. preset, 10, "non-finite position for %s; cue dropped", preset)
		return nil
	end
	if not (finite(opts.delay) and finite(opts.volume) and finite(opts.seed) and finite(opts.duration)) then
		log.warnThrottled("options" .. preset, 10, "non-finite options for %s; cue dropped", preset)
		return nil
	end
	local duration = if opts.duration then math.clamp(opts.duration, MIN_DURATION, MAX_DURATION) else nil
	if SynthPresets.isLooped(preset) and duration == nil and attach == nil then
		log.warnThrottled(
			"loop" .. preset,
			30,
			"looped preset %s needs options.duration or an attach target; cue dropped",
			preset
		)
		return nil
	end
	local delay = math.clamp(opts.delay or 0, 0, MAX_DELAY)
	local volume = if opts.volume then math.clamp(opts.volume, 0, MAX_VOLUME) else nil
	local seed = if opts.seed
		then math.floor(math.abs(opts.seed)) % MAX_SEED + 1
		else seedSource:NextInteger(1, MAX_SEED)
	return {
		preset = preset,
		position = position,
		attach = attach,
		startAt = Workspace:GetServerTimeNow() + GameConfig.OneShotLead + delay,
		seed = seed,
		volume = volume,
		duration = duration,
	}
end

local function broadcast(cue: Types.AudioCuePayload, except: Player?)
	if except then
		Net.Server.fireExcept(REMOTE, except, cue)
	else
		Net.Server.fireAll(REMOTE, cue)
	end
end

function AudioService.Init()
	-- Catch broken recipe data early in Studio (pure check, never yields).
	if RunService:IsStudio() then
		for _, problem in SynthPresets.validate() do
			log.warn("preset data: %s", problem)
		end
	end
end

-- 3D cue at a fixed world position for every client (except options.except). Returns the cue sent, or nil.
function AudioService.PlayAt(preset: string, position: Vector3, options: CueOptions?): Types.AudioCuePayload?
	if typeof(position) ~= "Vector3" then
		log.warnThrottled("at" .. tostring(preset), 10, "PlayAt(%s) needs a Vector3 position", tostring(preset))
		return nil
	end
	local cue = buildCue(preset, options, position, nil)
	if cue then
		broadcast(cue, if options then options.except else nil)
	end
	return cue
end

-- 3D cue following `attach` (BasePart, Attachment or Model) for every client (except options.except).
function AudioService.PlayOn(preset: string, attach: Instance, options: CueOptions?): Types.AudioCuePayload?
	if typeof(attach) ~= "Instance" then
		log.warnThrottled("on" .. tostring(preset), 10, "PlayOn(%s) needs an Instance", tostring(preset))
		return nil
	end
	local position = worldPosition(attach)
	if position == nil then
		log.warnThrottled(
			"onType" .. preset,
			10,
			"PlayOn(%s): %s is not a BasePart, Attachment or Model",
			preset,
			attach.ClassName
		)
		return nil
	end
	local cue = buildCue(preset, options, position, attach)
	if cue then
		broadcast(cue, if options then options.except else nil)
	end
	return cue
end

-- Cue for one player: 2D, or 3D when options.position / options.attach are given.
function AudioService.PlayFor(player: Player, preset: string, options: CueOptions?): Types.AudioCuePayload?
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return nil
	end
	local attach = if options then options.attach else nil
	local position = if options then options.position else nil
	if attach then
		if typeof(attach) ~= "Instance" then
			attach = nil
		else
			position = position or worldPosition(attach)
		end
	end
	local cue = buildCue(preset, options, position, attach)
	if cue then
		Net.Server.fire(REMOTE, player, cue)
	end
	return cue
end

-- PlayFor every player in `players` with one shared cue (same seed and start time for all of them).
function AudioService.PlayForList(players: { Player }, preset: string, options: CueOptions?): Types.AudioCuePayload?
	local attach = if options then options.attach else nil
	local position = if options then options.position else nil
	if attach and typeof(attach) == "Instance" then
		position = position or worldPosition(attach)
	end
	local cue = buildCue(preset, options, position, attach)
	if cue then
		Net.Server.fireList(REMOTE, players, cue)
	end
	return cue
end

return table.freeze(AudioService)
