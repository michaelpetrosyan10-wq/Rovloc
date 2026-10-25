--!strict
-- The only audio sources in the game: the 11 engine files every Roblox client ships under rbxasset://sounds/
-- (verified against the v0.744 client install manifest). Every voice the game makes is synthesized from these
-- through PlaybackSpeed, PlaybackRegion slicing, TimePosition, layering, envelopes and SoundEffect DSP chains
-- (see SynthPresets / SoundSynthesizer). No uploaded audio asset is referenced anywhere.
--
-- Durations are APPROXIMATE. The files could not be measured offline, so each `duration` is a deliberately
-- conservative (short) estimate of the real length in seconds. Recipes author their PlaybackRegions inside these
-- estimates, and at run time the client measures the real `Sound.TimeLength` of every file (VoicePool probes
-- them at setup and every pooled Sound reports it once loaded) and records it here. `resolveRegion` then keeps
-- every region inside the real file: a region that fits is used as-is, one that would run past the real end is
-- remapped proportionally into the measured length, so no recipe ever plays beyond the end of a file.

export type Sample = {
	id: string, -- short key; also the key in SoundLibrary.Samples
	path: string, -- rbxasset://sounds/<file>
	duration: number, -- seconds, approximate and conservative (see header); measured length overrides it at run time
	character: string, -- what the raw file sounds like and what the recipes turn it into
}

local ROOT = "rbxasset://sounds/"
-- Shortest region the synthesizer will ever play (seconds). Also the granular "oscillator" floor for loop tones.
local MIN_REGION = 0.004

local function sample(id: string, file: string, duration: number, character: string): Sample
	return table.freeze({ id = id, path = ROOT .. file, duration = duration, character = character })
end

local samples: { [string]: Sample } = {
	Falling = sample(
		"Falling",
		"action_falling.ogg",
		1.2,
		"sustained broadband wind rush (the only true noise source): drones, hiss, rain air, breath, static"
	),
	FootstepsPlastic = sample(
		"FootstepsPlastic",
		"action_footsteps_plastic.mp3",
		0.35,
		"dry, clicky footstep transients: footsteps per surface, glass crunch, claws, ticks, splinters, crackle"
	),
	GetUp = sample(
		"GetUp",
		"action_get_up.mp3",
		0.4,
		"soft body and cloth rustle: cloth movement, body drag in ducts, grass, debris settling"
	),
	Jump = sample("Jump", "action_jump.mp3", 0.25, "short airy whoosh: lunges, swipes, breath bursts"),
	JumpLand = sample(
		"JumpLand",
		"action_jump_land.mp3",
		0.2,
		"dull low thump: heartbeat (slowed), body impacts, door and trap weight"
	),
	Swim = sample(
		"Swim",
		"action_swim.mp3",
		0.8,
		"wet sloshing stroke (wet noise): splashes, treading, rain body, chemical fizz, pool lapping"
	),
	Explosion = sample(
		"Explosion",
		"impact_explosion_03.mp3",
		1.8,
		"boom with a crackling tail: thunder, monster roar body, slams, deep drones when slowed"
	),
	WaterImpact = sample(
		"WaterImpact",
		"impact_water.mp3",
		0.7,
		"splash transient with droplets: drips (sped up, sliced), splashes, rain patter"
	),
	Oof = sample("Oof", "oof.ogg", 0.35, "short voiced grunt: gasps, creature snarls and growls (slowed)"),
	Ouch = sample("Ouch", "ouch.ogg", 0.35, "short voiced cry: the screech (pitched up hard and looped), moans"),
	VolumeSlider = sample(
		"VolumeSlider",
		"volume_slider.ogg",
		0.08,
		"tiny tonal tick: metallic pings and rings (slowed), shards (sped up), UI, loop-region hum tones"
	),
}

local byPath: { [string]: string } = {}
local keys: { string } = {}
for key, entry in samples do
	byPath[entry.path] = key
	table.insert(keys, key)
end
table.sort(keys)

-- Real lengths reported by clients at run time (never shipped data).
local measured: { [string]: number } = {}

local SoundLibrary = {}

SoundLibrary.Samples = table.freeze(samples)
SoundLibrary.Keys = table.freeze(keys)
SoundLibrary.MinRegion = MIN_REGION

function SoundLibrary.get(key: string): Sample?
	return samples[key]
end

function SoundLibrary.has(key: string): boolean
	return samples[key] ~= nil
end

-- Sample key for a full rbxasset:// path (used when a loaded Sound reports its TimeLength).
function SoundLibrary.keyForPath(path: string): string?
	return byPath[path]
end

-- Records the real length of a file once a Sound using it has loaded. Ignores nonsense values.
function SoundLibrary.recordLength(key: string, seconds: number)
	if samples[key] == nil then
		return
	end
	if type(seconds) ~= "number" or seconds ~= seconds or seconds <= MIN_REGION or seconds > 3600 then
		return
	end
	measured[key] = seconds
end

-- Forgets every measured length (back to the estimates). Used by specs, and safe to call at any time:
-- clients simply re-measure the next time a Sound using each file loads.
function SoundLibrary.resetMeasurements()
	table.clear(measured)
end

function SoundLibrary.isMeasured(key: string): boolean
	return measured[key] ~= nil
end

-- Best known length: the measured TimeLength when a client has loaded the file, else the conservative estimate.
function SoundLibrary.length(key: string): number
	local real = measured[key]
	if real then
		return real
	end
	local entry = samples[key]
	return if entry then entry.duration else 0
end

-- Turns an authored region (seconds, written against the catalog estimate) into one that is valid for the real
-- file. Regions that fit are kept; a region running past the real end is scaled into the measured length.
-- Always returns min < max with at least MinRegion between them, both inside [0, length].
function SoundLibrary.resolveRegion(key: string, regionMin: number, regionMax: number): (number, number)
	local entry = samples[key]
	local estimate = if entry then entry.duration else 0
	local length = SoundLibrary.length(key)
	if length <= MIN_REGION then
		return 0, MIN_REGION
	end
	local a = math.max(0, math.min(regionMin, regionMax))
	local b = math.max(regionMin, regionMax)
	if b > length and estimate > 0 and measured[key] ~= nil then
		local scale = length / math.max(estimate, b)
		a *= scale
		b *= scale
	end
	b = math.clamp(b, MIN_REGION, length)
	a = math.clamp(a, 0, b - MIN_REGION)
	return a, b
end

return table.freeze(SoundLibrary)
