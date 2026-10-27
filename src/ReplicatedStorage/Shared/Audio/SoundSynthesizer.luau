--!strict
-- Client-side voice builder: turns a SynthPresets recipe into layered, DSP-processed Sounds.
--
-- A Voice is one playing preset. It reserves a VoicePool slot (bus caps, priority stealing, distance pre-cull),
-- one emitter (2D, a fixed position, or following an instance) and then schedules its layers on a voice clock:
--   * every trigger of a layer is a "grain": a pooled Sound with a resolved PlaybackRegion slice, a seeded speed /
--     volume / slice jitter, an envelope and an optional PlaybackSpeed glide
--   * a layer's effect chain is not on its grains: every grain of the layer plays through one shared VoicePool
--     effect group (a SoundGroup carrying the chain, under the preset's space group or the bus group). The voice
--     holds its groups until it ends; then they ring out for their tail, so reverbs and echoes are heard in full
--     after the dry grains are gone (a drip's echo, a trap's ringing iron, a groan drowned in reverb)
--   * grains repeat (layer.grains) for crunches and crackle; looped voices re-trigger their non-bed layers every
--     preset.repeat interval (heartbeats, drips, breathing) while bed layers loop for the voice's whole life
-- Timing. Grains start on Heartbeat frames. A trigger that came due between two frames starts from the top of its
-- slice: frame lateness is never fast-forwarded, because the attack transient is the sound. At most one trigger
-- per layer starts per frame; the rest wait for the following frames, so every transient of a cluster is heard
-- instead of stacking into one (recipes get sub-frame density from a short Echo instead). Only network lateness is
-- skipped: a voice started with startOffset (a cue that arrived late) drops triggers that fell before that point
-- and are already over, and starts the rest part-way through their slice and envelope.
-- Budget. A voice keeps at most VoicePool.budget().grainsPerVoice grains sounding (its oldest one-shot grain is
-- released quickly to make room). When every Sound of the device budget is in use, the lowest-priority voice
-- gives one up (its oldest one-shot grain, or the whole voice if it only holds loops) instead of the newcomer's
-- grain being dropped.
-- One Heartbeat step drives every voice (envelopes, glides, fades, cycles) and frees rung-out effect groups; it
-- disconnects when nothing plays or rings. Looped 3D voices that drift past their rollOff.max are paused (asleep)
-- and resume when the listener returns.
--
-- Jitter is drawn from MathUtil.seededRandom(seed, preset) streams (one for the schedule, one per layer for its
-- grains), so the same seed gives the same sound on every client whatever its frame rate.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AudioBuses = require(ReplicatedStorage.Shared.Audio.AudioBuses)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local SoundLibrary = require(ReplicatedStorage.Shared.Audio.SoundLibrary)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local VoicePool = require(ReplicatedStorage.Shared.Audio.VoicePool)

local log = Log.new("Synth")

export type PlayOptions = {
	position: Vector3?, -- play in 3D at a fixed point
	attach: Instance?, -- or follow a BasePart / Attachment / Model
	bus: Enums.AudioBus?, -- override the preset's bus
	volume: number?, -- voice volume multiplier (default 1)
	speed: number?, -- PlaybackSpeed multiplier on every layer (default 1)
	seed: number?, -- jitter seed (cues pass the server's; local plays draw one)
	startOffset: number?, -- seconds already elapsed (late network cues skip what they missed)
	looped: boolean?, -- override whether the voice runs until stopped
	fadeIn: number?, -- seconds to fade the voice in from silence
}

export type Voice = {
	Preset: string,
	Stop: (self: Voice, fade: number?) -> (),
	SetVolume: (self: Voice, volume: number, fade: number?) -> (),
	IsPlaying: (self: Voice) -> boolean,
	Ended: Signal.Signal<>,
}

-- One scheduled trigger of a layer (voice time in seconds).
export type Pending = { at: number, layerIndex: number }

-- Starts one trigger: (layerIndex, base = the voice time its clock starts at, late = network seconds to skip).
export type Starter = (layerIndex: number, base: number, late: number) -> boolean

export type Stats = {
	voices: number,
	sounds: number,
	fxGroups: number, -- effect groups alive (in use or ringing out)
	ringing: number, -- of those, idle groups still ringing out a tail
	reverbs: number,
}

type Grain = {
	layer: SynthPresets.Layer,
	sound: Sound,
	startedAt: number, -- voice time this grain's own clock started
	baseVolume: number,
	baseSpeed: number,
	looped: boolean,
	cutAt: number?, -- voice time the release begins (envelope hold / layer duration)
	releaseAt: number?, -- voice time the release actually began
	releaseFrom: number,
	releaseTime: number,
	endsAt: number?, -- voice time by which a one-shot grain must have finished (safety net)
	extensions: number,
	finished: boolean,
	stolen: boolean, -- released early to keep the voice inside its grain budget
	paused: boolean,
	lastVolume: number,
	lastSpeed: number,
	endedConnection: RBXScriptConnection?,
}

type VoiceState = {
	handle: Voice,
	name: string,
	preset: SynthPresets.Preset,
	bus: Enums.AudioBus,
	seed: number,
	random: Random, -- schedule draws (chance, delays, grain counts)
	layerRandoms: { [number]: Random }, -- grain draws per layer (speed, volume, slice)
	speedScale: number,
	looped: boolean,
	rollOff: SynthPresets.Range,
	emitter: VoicePool.Emitter,
	slot: VoicePool.Slot?,
	clockStart: number, -- os.clock() at voice time 0
	joinAt: number, -- voice time the voice actually began at (its startOffset)
	now: number, -- voice time of the current step
	volume: number,
	volumeFrom: number,
	volumeTo: number,
	volumeAt: number,
	volumeFade: number,
	stopping: boolean,
	stopAt: number?,
	ended: boolean,
	grains: { Grain },
	pending: { Pending },
	nextCycleAt: number?,
	cycleLength: number,
	asleep: boolean,
	nextHealthCheck: number,
	endedSignal: Signal.Signal<>,
	spaceTried: boolean,
	spaceFx: VoicePool.FxGroup?,
	layerTried: { [number]: boolean }, -- layers whose effect group was asked for (it may have been refused)
	layerFx: { [number]: VoicePool.FxGroup },
	starter: Starter,
	reclaim: () -> boolean,
}

local STEAL_FADE = 0.06
local GRAIN_STEAL_RELEASE = 0.015
local DEFAULT_RELEASE = 0.03
local END_SLACK = 0.25
local HEALTH_INTERVAL = 0.25
local SWEEP_INTERVAL = 0.1
local SLEEP_MARGIN = 1.1
local MIN_SPEED = 0.02
local MAX_SPEED = 20
local MAX_SOUND_VOLUME = 10
local VOLUME_EPSILON = 0.002
local SPEED_EPSILON = 0.001

local SoundSynthesizer = {}

local captioned: Signal.Signal<string, string> = Signal.new()
-- Fires (captionKey, presetName) whenever a captioned preset starts; the P3 caption HUD subscribes.
SoundSynthesizer.Captioned = captioned

local voices: { VoiceState } = {}
local stepConnection: RBXScriptConnection? = nil
local nextSweep = 0
local seedSource = Random.new()
local validated = false
local longestLayerTail: { [string]: number } = {}

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function pickRange(random: Random, range: SynthPresets.Range): number
	if range.max <= range.min then
		return range.min
	end
	return random:NextNumber(range.min, range.max)
end

local function pickSpeed(random: Random, speed: number | SynthPresets.Range): number
	if type(speed) == "number" then
		return speed
	end
	return pickRange(random, speed)
end

local function currentVolume(state: VoiceState, now: number): number
	if state.volumeFade <= 0 then
		return state.volumeTo
	end
	local alpha = math.clamp((now - state.volumeAt) / state.volumeFade, 0, 1)
	return MathUtil.lerp(state.volumeFrom, state.volumeTo, alpha)
end

local function setVolumeTarget(state: VoiceState, target: number, fade: number)
	local now = os.clock()
	state.volumeFrom = currentVolume(state, now)
	state.volumeTo = target
	state.volumeAt = now
	state.volumeFade = math.max(fade, 0)
	state.volume = if fade > 0 then state.volumeFrom else target
end

local function layerRandom(state: VoiceState, index: number): Random
	local existing = state.layerRandoms[index]
	if existing then
		return existing
	end
	local created = MathUtil.seededRandom(state.seed, state.name .. "#" .. index)
	state.layerRandoms[index] = created
	return created
end

-- Seconds a non-bed layer occupies (delay + its sound), used as the cycle length of looped voices without repeat.
local function layerSpan(layer: SynthPresets.Layer): number
	local entry = SoundLibrary.get(layer.sample)
	local length = if entry then entry.duration else 0.25
	local region = layer.region
	if region then
		length = region.max - region.min
	end
	local speed = layer.speed
	local slowest = if type(speed) == "number" then speed else speed.min
	local span = layer.duration or (length / math.max(slowest, MIN_SPEED))
	local grainSpec = layer.grains
	if grainSpec then
		span += grainSpec.count.max * grainSpec.spacing.max
	end
	return (layer.delay or 0) + (layer.delayJitter or 0) + span
end

local function cycleLength(state: VoiceState): number
	local pulse = state.preset["repeat"]
	if pulse then
		local jitter = if pulse.jitter > 0 then state.random:NextNumber(-pulse.jitter, pulse.jitter) else 0
		return math.max(0.05, pulse.interval + jitter)
	end
	local longest = 0.05
	for _, layer in state.preset.layers do
		if not SynthPresets.isBedLayer(layer) then
			longest = math.max(longest, layerSpan(layer))
		end
	end
	return longest
end

local function hasCycleLayers(preset: SynthPresets.Preset): boolean
	for _, layer in preset.layers do
		if not SynthPresets.isBedLayer(layer) then
			return true
		end
	end
	return false
end

-- The longest tail among a preset's layer chains (a space group must outlive what feeds it).
local function layerTailOf(name: string, preset: SynthPresets.Preset): number
	local cached = longestLayerTail[name]
	if cached then
		return cached
	end
	local longest = 0
	for _, layer in preset.layers do
		longest = math.max(longest, SynthPresets.chainTail(layer.effects))
	end
	longestLayerTail[name] = longest
	return longest
end

--------------------------------------------------------------------------------
-- Scheduling
--------------------------------------------------------------------------------

local function sortPending(state: VoiceState)
	table.sort(state.pending, function(a: Pending, b: Pending): boolean
		if a.at == b.at then
			return a.layerIndex < b.layerIndex
		end
		return a.at < b.at
	end)
end

-- Queues one pass over the layers starting at voice time `cycleStart`. Bed layers only play on the first cycle.
local function scheduleCycle(state: VoiceState, cycleStart: number, first: boolean)
	local random = state.random
	for index, layer in state.preset.layers do
		if not first and state.looped and SynthPresets.isBedLayer(layer) then
			continue
		end
		local chance = layer.chance
		if chance ~= nil and chance < 1 and random:NextNumber() > chance then
			continue
		end
		local at = cycleStart + (layer.delay or 0)
		local delayJitter = layer.delayJitter
		if delayJitter and delayJitter > 0 then
			at += random:NextNumber(0, delayJitter)
		end
		local grainSpec = layer.grains
		local count = if grainSpec
			then random:NextInteger(math.floor(grainSpec.count.min), math.max(math.floor(grainSpec.count.max), 1))
			else 1
		for _ = 1, math.max(count, 1) do
			table.insert(state.pending, { at = at, layerIndex = index })
			if grainSpec then
				at += pickRange(random, grainSpec.spacing)
			end
		end
	end
	sortPending(state)
end

-- Starts the triggers in `pending` (sorted) that are due by voice time `t`, in schedule order, removing them.
--   * frame lateness is never skipped: a trigger due between frames starts now from the top (late = 0, base = t)
--   * network lateness is: a trigger scheduled before `joinAt` starts `joinAt - at` seconds in (late), with its
--     clock based where it should have started
--   * at most one trigger per layer starts per call; later ones stay queued for the next frames. A trigger that
--     `start` refuses (already over, no budget) is dropped and does not use up its layer's turn.
-- Returns how many triggers started. Pure apart from `start`, so the rule is testable without instances.
function SoundSynthesizer.drainDue(pending: { Pending }, t: number, joinAt: number, start: Starter): number
	local started = 0
	local busy: { [number]: boolean } = {}
	local index = 1
	while index <= #pending do
		local event = pending[index]
		if event.at > t then
			break
		end
		if busy[event.layerIndex] then
			index += 1
			continue
		end
		table.remove(pending, index)
		local late = math.max(0, joinAt - event.at)
		if start(event.layerIndex, t - late, late) then
			busy[event.layerIndex] = true
			started += 1
		end
	end
	return started
end

--------------------------------------------------------------------------------
-- Effect groups
--------------------------------------------------------------------------------

local function keyPrefix(state: VoiceState): string
	return state.bus .. "/" .. state.name
end

-- The preset's space group (its shared room), acquired on first use; nil when the preset has none.
local function spaceFor(state: VoiceState): VoicePool.FxGroup?
	if not state.spaceTried then
		state.spaceTried = true
		local space = state.preset.space
		if space and #space > 0 then
			state.spaceFx = VoicePool.acquireFxGroup(
				keyPrefix(state) .. "/space",
				AudioBuses.group(state.bus),
				space,
				layerTailOf(state.name, state.preset),
				nil
			)
		end
	end
	return state.spaceFx
end

-- The SoundGroup a layer's grains play through: its shared effect group, else the space, else the bus.
local function groupFor(state: VoiceState, layerIndex: number, layer: SynthPresets.Layer): SoundGroup
	local space = spaceFor(state)
	local parent = if space then space.group else AudioBuses.group(state.bus)
	local chain = layer.effects
	if chain == nil or #chain == 0 then
		return parent
	end
	if not state.layerTried[layerIndex] then
		state.layerTried[layerIndex] = true
		local key = keyPrefix(state) .. (if space then "/s" else "/d") .. layerIndex
		local acquired = VoicePool.acquireFxGroup(key, parent, chain, 0, space)
		if acquired then
			state.layerFx[layerIndex] = acquired
		end
	end
	local fx = state.layerFx[layerIndex]
	if fx then
		return fx.group
	end
	return parent
end

local function releaseGroups(state: VoiceState)
	for _, fx in state.layerFx do
		VoicePool.releaseFxGroup(fx)
	end
	table.clear(state.layerFx)
	table.clear(state.layerTried)
	local space = state.spaceFx
	if space then
		state.spaceFx = nil
		VoicePool.releaseFxGroup(space)
	end
end

--------------------------------------------------------------------------------
-- Grains
--------------------------------------------------------------------------------

local function releaseGrain(grain: Grain)
	grain.finished = true
	local connection = grain.endedConnection
	if connection then
		connection:Disconnect()
		grain.endedConnection = nil
	end
	VoicePool.releaseSound(grain.sound)
end

-- Envelope gain of a grain at voice time `t` (0..1); true once its release has run out.
local function envelopeGain(grain: Grain, t: number): (number, boolean)
	local releaseAt = grain.releaseAt
	if releaseAt then
		if grain.releaseTime <= 0 then
			return 0, true
		end
		local k = (t - releaseAt) / grain.releaseTime
		if k >= 1 then
			return 0, true
		end
		return grain.releaseFrom * (1 - k), false
	end
	local envelope = grain.layer.envelope
	local elapsed = t - grain.startedAt
	if envelope and envelope.attack > 0 and elapsed < envelope.attack then
		return math.clamp(elapsed / envelope.attack, 0, 1), false
	end
	return 1, false
end

local function finish(state: VoiceState)
	if state.ended then
		return
	end
	state.ended = true
	for _, grain in state.grains do
		releaseGrain(grain)
	end
	table.clear(state.grains)
	table.clear(state.pending)
	state.nextCycleAt = nil
	-- The dry voice is over; its effect groups now ring out their tails inside VoicePool.
	releaseGroups(state)
	VoicePool.releaseEmitter(state.emitter)
	local slot = state.slot
	if slot then
		state.slot = nil
		VoicePool.release(slot)
	end
	local index = table.find(voices, state)
	if index then
		table.remove(voices, index)
	end
	state.endedSignal:Fire()
end

-- Frees one Sound for `requester` from the lowest-priority other voice (quietest, then oldest, on ties): its oldest
-- one-shot grain, or the whole voice when it only holds loops. False when every sounding voice outranks it.
local function reclaimSound(requester: VoiceState): boolean
	local owners: { VoiceState } = {}
	local candidates: { VoicePool.Candidate } = {}
	for _, other in voices do
		local slot = other.slot
		if other ~= requester and not other.ended and slot ~= nil and #other.grains > 0 then
			table.insert(owners, other)
			table.insert(candidates, {
				priority = other.preset.priority,
				audibility = VoicePool.slotAudibility(slot),
				startedAt = slot.startedAt,
			})
		end
	end
	local index = VoicePool.pickVictim(candidates, requester.preset.priority)
	if index == nil then
		return false
	end
	local victim = owners[index]
	for grainIndex, grain in victim.grains do
		if not grain.looped then
			table.remove(victim.grains, grainIndex)
			releaseGrain(grain)
			return true
		end
	end
	finish(victim)
	return true
end

-- Keeps a voice inside its grain budget: past it, the oldest sounding one-shot grain is released quickly.
local function makeRoom(state: VoiceState, t: number)
	local cap = VoicePool.budget().grainsPerVoice
	local sounding = 0
	local oldest: Grain? = nil
	for _, grain in state.grains do
		if grain.stolen or grain.finished then
			continue
		end
		sounding += 1
		if oldest == nil and not grain.looped then
			oldest = grain
		end
	end
	if sounding < cap or oldest == nil then
		return
	end
	local gain = envelopeGain(oldest, t)
	oldest.stolen = true
	oldest.releaseFrom = gain
	oldest.releaseAt = t
	oldest.releaseTime = GRAIN_STEAL_RELEASE
end

-- Starts one trigger of a layer. `base` = voice time the grain's clock starts at, `late` = network seconds to skip
-- into it, `t` = the current voice time. False when it did not start (already over, unknown sample, no Sound).
local function startGrain(state: VoiceState, layerIndex: number, base: number, late: number, t: number): boolean
	local layer = state.preset.layers[layerIndex]
	if layer == nil then
		return false
	end
	local sampleEntry = SoundLibrary.get(layer.sample)
	if not sampleEntry then
		return false
	end
	local random = layerRandom(state, layerIndex)

	-- Slice: the authored region (or the whole file), slid by regionJitter, then resolved against the real length.
	local estimate = sampleEntry.duration
	local region = layer.region
	local regionMin = if region then region.min else 0
	local regionMax = if region then region.max else estimate
	local jitter = layer.regionJitter
	if jitter and jitter > 0 then
		local shift = random:NextNumber(-jitter, jitter)
		shift = math.clamp(shift, -regionMin, math.max(0, estimate - regionMax))
		regionMin += shift
		regionMax += shift
	end
	local useRegion = region ~= nil or (jitter ~= nil and jitter > 0)
	local sliceMin, sliceMax = 0, SoundLibrary.length(layer.sample)
	if useRegion then
		sliceMin, sliceMax = SoundLibrary.resolveRegion(layer.sample, regionMin, regionMax)
	end
	local sliceLength = math.max(sliceMax - sliceMin, SoundLibrary.MinRegion)

	local speed = math.clamp(pickSpeed(random, layer.speed) * state.speedScale, MIN_SPEED, MAX_SPEED)
	local volume = layer.volume
	local volumeJitter = layer.volumeJitter
	if volumeJitter and volumeJitter > 0 then
		volume *= 1 + random:NextNumber(-volumeJitter, volumeJitter)
	end
	-- A bed layer only loops inside a looped voice; a sustained grain (looped + duration) always loops.
	local looped = layer.looped == true and (state.looped or layer.duration ~= nil)

	local position = (layer.timePosition or 0) + late * speed
	if looped then
		position %= sliceLength
	elseif position >= sliceLength then
		return false -- this trigger was already over when the cue reached us
	end
	local duration = layer.duration
	if duration and late >= duration then
		return false
	end

	makeRoom(state, t)
	local sound = VoicePool.acquireSound(sampleEntry.path, state.reclaim)
	if sound == nil then
		return false
	end

	local envelope = layer.envelope
	local releaseTime = if envelope then math.max(envelope.release, 0) else DEFAULT_RELEASE
	local cutAt: number? = nil
	if envelope and envelope.hold ~= nil then
		cutAt = base + envelope.attack + envelope.hold
	end
	if duration then
		local durationCut = base + math.max(0, duration - releaseTime)
		cutAt = if cutAt then math.min(cutAt, durationCut) else durationCut
	end
	local endsAt: number? = nil
	if not looped then
		local glideSpec = layer.glide
		local slowest = speed * (if glideSpec then math.min(1, glideSpec.to) else 1)
		-- Until the real length is known the estimate is deliberately short, so the safety net is generous;
		-- Sound.Ended normally ends the grain long before either limit.
		local slack = if SoundLibrary.isMeasured(layer.sample) then END_SLACK else sliceLength * 2 + 1
		endsAt = base + (sliceLength - (layer.timePosition or 0)) / math.max(slowest, MIN_SPEED) + slack
	end

	local grain: Grain = {
		layer = layer,
		sound = sound,
		startedAt = base,
		baseVolume = volume,
		baseSpeed = speed,
		looped = looped,
		cutAt = cutAt,
		releaseAt = nil,
		releaseFrom = 1,
		releaseTime = releaseTime,
		endsAt = endsAt,
		extensions = 0,
		finished = false,
		stolen = false,
		paused = false,
		lastVolume = -1,
		lastSpeed = speed,
		endedConnection = nil,
	}

	sound.Looped = looped
	sound.PlaybackRegionsEnabled = useRegion
	if useRegion then
		sound.PlaybackRegion = NumberRange.new(sliceMin, sliceMax)
		sound.LoopRegion = NumberRange.new(sliceMin, sliceMax)
	end
	sound.PlaybackSpeed = speed
	sound.Volume = 0
	sound.SoundGroup = groupFor(state, layerIndex, layer)
	if state.emitter.spatial then
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMinDistance = state.rollOff.min
		sound.RollOffMaxDistance = state.rollOff.max
	end
	sound.TimePosition = (if useRegion then sliceMin else 0) + position
	if not looped then
		grain.endedConnection = sound.Ended:Connect(function()
			grain.finished = true
		end)
	end
	sound.Parent = state.emitter.parent
	sound:Play()
	if state.asleep then
		sound:Pause()
		grain.paused = true
	end
	table.insert(state.grains, grain)
	return true
end

-- Updates one grain; returns true when it is done and has been released.
local function stepGrain(grain: Grain, t: number, voiceVolume: number): boolean
	if grain.finished then
		releaseGrain(grain)
		return true
	end
	local cutAt = grain.cutAt
	if grain.releaseAt == nil and cutAt and t >= cutAt then
		local level = envelopeGain(grain, t)
		grain.releaseFrom = level
		grain.releaseAt = t
	end
	local gain, done = envelopeGain(grain, t)
	if done then
		releaseGrain(grain)
		return true
	end
	local endsAt = grain.endsAt
	if endsAt and t >= endsAt then
		if not grain.sound.IsLoaded and grain.extensions < 4 then
			-- Still loading (first use of a file): give it time instead of cutting it before it starts.
			grain.extensions += 1
			grain.endsAt = endsAt + 0.5
		else
			releaseGrain(grain)
			return true
		end
	end

	local volume = math.clamp(grain.baseVolume * gain * voiceVolume, 0, MAX_SOUND_VOLUME)
	if math.abs(volume - grain.lastVolume) > VOLUME_EPSILON then
		grain.lastVolume = volume
		grain.sound.Volume = volume
	end
	local glideSpec = grain.layer.glide
	if glideSpec then
		local alpha = MathUtil.smoothstep(0, 1, (t - grain.startedAt) / math.max(glideSpec.time, 1e-3))
		local speed = math.clamp(grain.baseSpeed * MathUtil.lerp(1, glideSpec.to, alpha), MIN_SPEED, MAX_SPEED)
		if math.abs(speed - grain.lastSpeed) > SPEED_EPSILON then
			grain.lastSpeed = speed
			grain.sound.PlaybackSpeed = speed
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Voice lifecycle
--------------------------------------------------------------------------------

local function stopVoice(state: VoiceState, fade: number?)
	if state.ended then
		return
	end
	local seconds = fade or 0
	if seconds <= 0 then
		finish(state)
		return
	end
	if state.stopping then
		-- Already fading out: only ever shorten the fade.
		local stopAt = state.stopAt
		if stopAt and os.clock() + seconds >= stopAt then
			return
		end
	end
	state.stopping = true
	table.clear(state.pending)
	state.nextCycleAt = nil
	setVolumeTarget(state, 0, seconds)
	state.stopAt = os.clock() + seconds
end

local function setAsleep(state: VoiceState, asleep: boolean)
	if state.asleep == asleep then
		return
	end
	state.asleep = asleep
	for _, grain in state.grains do
		if asleep and not grain.paused then
			grain.paused = true
			pcall(function()
				grain.sound:Pause()
			end)
		elseif not asleep and grain.paused then
			grain.paused = false
			pcall(function()
				grain.sound:Resume()
			end)
		end
	end
end

local function healthCheck(state: VoiceState, now: number)
	if now < state.nextHealthCheck then
		return
	end
	state.nextHealthCheck = now + HEALTH_INTERVAL
	if not VoicePool.emitterAlive(state.emitter) then
		finish(state)
		return
	end
	if state.looped and state.emitter.spatial then
		local position = VoicePool.emitterPosition(state.emitter)
		if position then
			local distance = (position - VoicePool.listenerPosition()).Magnitude
			if state.asleep then
				if distance <= state.rollOff.max then
					setAsleep(state, false)
				end
			elseif distance > state.rollOff.max * SLEEP_MARGIN then
				setAsleep(state, true)
			end
		end
	end
end

local function stepVoice(state: VoiceState)
	if state.ended then
		return
	end
	local now = os.clock()
	healthCheck(state, now)
	if state.ended then
		return
	end
	local stopAt = state.stopAt
	if stopAt and now >= stopAt then
		finish(state)
		return
	end
	local t = now - state.clockStart
	state.now = t
	state.volume = currentVolume(state, now)

	-- Repeat cycles (looped voices). Missed cycles are skipped, never replayed in a burst.
	local nextCycleAt = state.nextCycleAt
	if nextCycleAt and t >= nextCycleAt and not state.stopping then
		local start = if t - nextCycleAt > state.cycleLength then t else nextCycleAt
		scheduleCycle(state, start, false)
		state.cycleLength = cycleLength(state)
		state.nextCycleAt = start + state.cycleLength
	end

	-- Due triggers (asleep voices let them pass silently).
	if state.asleep then
		while #state.pending > 0 and state.pending[1].at <= t do
			table.remove(state.pending, 1)
		end
	else
		SoundSynthesizer.drainDue(state.pending, t, state.joinAt, state.starter)
	end
	if state.ended then
		return
	end

	local index = 1
	while index <= #state.grains do
		if stepGrain(state.grains[index], t, state.volume) then
			table.remove(state.grains, index)
		else
			index += 1
		end
	end

	if #state.grains == 0 and #state.pending == 0 and state.nextCycleAt == nil then
		finish(state)
	end
end

-- Runs fn(state) protected; a failing voice is logged and torn down so it can never wedge the step loop.
local function protected(fn: (VoiceState) -> (), state: VoiceState, what: string): boolean
	local ok = true
	xpcall(fn, function(err: any)
		ok = false
		log.warnThrottled(what .. state.name, 10, "voice %s %s: %s", state.name, what, tostring(err))
	end, state)
	if not ok then
		xpcall(finish, function(err: any)
			log.warnThrottled("finish" .. state.name, 10, "voice %s cleanup failed: %s", state.name, tostring(err))
		end, state)
	end
	return ok
end

local function step()
	for _, state in table.clone(voices) do
		if not state.ended then
			protected(stepVoice, state, "failed")
		end
	end
	local now = os.clock()
	local alive = -1
	if now >= nextSweep then
		nextSweep = now + SWEEP_INTERVAL
		alive = VoicePool.sweepFxGroups(now)
	end
	if #voices == 0 and alive == 0 then
		local connection = stepConnection
		if connection then
			connection:Disconnect()
			stepConnection = nil
		end
	end
end

local function ensureStepping()
	if stepConnection == nil then
		stepConnection = RunService.Heartbeat:Connect(step)
	end
end

local function validateOnce()
	if validated then
		return
	end
	validated = true
	if not RunService:IsStudio() then
		return
	end
	for _, problem in SynthPresets.validate() do
		log.warn("preset data: %s", problem)
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function SoundSynthesizer.has(preset: string): boolean
	return SynthPresets.has(preset)
end

-- True when a voice of this preset runs until stopped (beds, emitters, pulses).
function SoundSynthesizer.isLooped(preset: string): boolean
	return SynthPresets.isLooped(preset)
end

function SoundSynthesizer.activeVoices(bus: Enums.AudioBus?): number
	return VoicePool.activeCount(bus)
end

-- What the synthesizer is holding right now (dev overlays, budget probes).
function SoundSynthesizer.stats(): Stats
	local groups, ringing, reverbs = VoicePool.fxStats()
	return {
		voices = #voices,
		sounds = VoicePool.soundsInUse(),
		fxGroups = groups,
		ringing = ringing,
		reverbs = reverbs,
	}
end

-- Plays a preset. Returns nil when the preset is unknown, the sound is out of earshot (one-shots past their
-- rollOff.max), its bus is full of more important voices, or this is not a client.
function SoundSynthesizer.play(presetName: string, options: PlayOptions?): Voice?
	if not RunService:IsClient() then
		log.warnThrottled("server", 60, "SoundSynthesizer.play(%s) on the server; use AudioService cues", presetName)
		return nil
	end
	local preset = SynthPresets.get(presetName)
	if not preset then
		log.warnThrottled("unknown" .. presetName, 30, "unknown preset %s", presetName)
		return nil
	end
	validateOnce()
	AudioBuses.setup()
	VoicePool.setup()

	local opts: PlayOptions = options or {}
	local bus: Enums.AudioBus = opts.bus or preset.bus
	local looped = if opts.looped ~= nil then opts.looped else SynthPresets.isLooped(presetName)
	local volume = math.clamp(opts.volume or 1, 0, 4)
	local startOffset = math.max(opts.startOffset or 0, 0)

	-- Cheap early cull for fixed-position one-shots (before an emitter or a slot is taken).
	if not looped and opts.attach == nil and VoicePool.shouldCull(opts.position, SynthPresets.rollOff(preset)) then
		return nil
	end

	local emitter = VoicePool.acquireEmitter(opts.attach, opts.position)
	if emitter == nil then
		return nil
	end
	if opts.attach ~= nil and not emitter.spatial then
		-- The attach target is gone (or not spatial) and no fallback position was given: never play it 2D.
		VoicePool.releaseEmitter(emitter)
		return nil
	end

	local ended: Signal.Signal<> = Signal.new()
	local state: VoiceState
	local handle: Voice = {
		Preset = presetName,
		Stop = function(_self: Voice, fade: number?)
			stopVoice(state, fade)
		end,
		SetVolume = function(_self: Voice, target: number, fade: number?)
			if state.ended or state.stopping then
				return
			end
			setVolumeTarget(state, math.clamp(target, 0, 4), fade or 0)
		end,
		IsPlaying = function(_self: Voice): boolean
			return not state.ended and not state.stopping
		end,
		Ended = ended,
	}
	local seed = opts.seed or seedSource:NextInteger(1, 2_147_483_646)
	local fadeIn = math.max(opts.fadeIn or 0, 0)
	local now = os.clock()
	state = {
		handle = handle,
		name = presetName,
		preset = preset,
		bus = bus,
		seed = seed,
		random = MathUtil.seededRandom(seed, presetName),
		layerRandoms = {},
		speedScale = math.clamp(opts.speed or 1, 0.1, 4),
		looped = looped,
		rollOff = SynthPresets.rollOff(preset),
		emitter = emitter,
		slot = nil,
		clockStart = now - startOffset,
		joinAt = startOffset,
		now = startOffset,
		volume = if fadeIn > 0 then 0 else volume,
		volumeFrom = if fadeIn > 0 then 0 else volume,
		volumeTo = volume,
		volumeAt = now,
		volumeFade = fadeIn,
		stopping = false,
		stopAt = nil,
		ended = false,
		grains = {},
		pending = {},
		nextCycleAt = nil,
		cycleLength = 0,
		asleep = false,
		nextHealthCheck = now + HEALTH_INTERVAL,
		endedSignal = ended,
		spaceTried = false,
		spaceFx = nil,
		layerTried = {},
		layerFx = {},
		starter = function(_layerIndex: number, _base: number, _late: number): boolean
			return false
		end,
		reclaim = function(): boolean
			return false
		end,
	}
	state.starter = function(layerIndex: number, base: number, late: number): boolean
		return startGrain(state, layerIndex, base, late, state.now)
	end
	state.reclaim = function(): boolean
		return reclaimSound(state)
	end

	local slot = VoicePool.admit({
		bus = bus,
		preset = presetName,
		priority = preset.priority,
		maxVoices = preset.maxVoices,
		looped = looped,
		rollOff = if emitter.spatial then state.rollOff else nil,
		position = function(): Vector3?
			return VoicePool.emitterPosition(emitter)
		end,
		gain = function(): number
			return currentVolume(state, os.clock())
		end,
		steal = function()
			stopVoice(state, STEAL_FADE)
		end,
		cull = emitter.spatial and not looped,
	})
	if slot == nil then
		VoicePool.releaseEmitter(emitter)
		return nil
	end
	state.slot = slot

	scheduleCycle(state, 0, true)
	if looped and hasCycleLayers(preset) then
		state.cycleLength = cycleLength(state)
		state.nextCycleAt = state.cycleLength
	end

	table.insert(voices, state)
	ensureStepping()

	if startOffset < 0.5 then
		for _, duckSpec in (preset.duck or {}) :: { SynthPresets.Duck } do
			AudioBuses.duck(duckSpec.bus, duckSpec.gain, duckSpec.attack, duckSpec.hold, duckSpec.release)
		end
	end
	local caption = preset.caption
	if caption then
		captioned:Fire(caption, presetName)
	end

	-- Start whatever is already due this frame (no one-frame gap on the first transient).
	if not protected(stepVoice, state, "failed to start") or state.ended then
		return nil
	end
	return handle
end

-- Stops every voice (optionally only one bus), with an optional fade.
function SoundSynthesizer.stopAll(bus: Enums.AudioBus?, fade: number?)
	for _, state in table.clone(voices) do
		if bus == nil or state.bus == bus then
			stopVoice(state, fade)
		end
	end
end

return table.freeze(SoundSynthesizer)
