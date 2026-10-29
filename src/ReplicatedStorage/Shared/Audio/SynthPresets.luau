--!strict
-- Data-only synthesis recipes. Every sound in the game is one of these presets, built on clients by
-- SoundSynthesizer from the 11 engine files in SoundLibrary. Nothing here creates instances.
--
-- A preset is a stack of layers. Each layer plays one SoundLibrary sample and shapes it:
--   speed         PlaybackSpeed (number, or {min, max} picked per trigger from the voice's seeded Random)
--   region        PlaybackRegion slice in seconds (authored inside the SoundLibrary estimate; resolved against
--                 the real TimeLength at run time), regionJitter slides the slice per trigger (granular variety)
--   timePosition  start offset inside the region (or the file)
--   delay         seconds after the voice starts (delayJitter randomizes it)
--   duration      cut the layer after this long (with the envelope release)
--   looped        loop the region; a looped layer WITHOUT duration is a bed layer that runs for the whole voice,
--                 a looped layer WITH duration is a sustained grain that re-triggers every pulse
--   envelope      {attack, hold?, release}: gain ramps; hold nil = sustain until the layer ends or is cut
--   glide         PlaybackSpeed multiplier reached after `time` seconds (rising shrieks, sweeping whooshes)
--   grains        re-trigger the layer `count` times, `spacing` apart, each with fresh jitter (crunch, crackle)
--   chance        probability the layer sounds on a given trigger; volumeJitter = +/- fraction of volume
--   effects       SoundEffect chain in order (first = highest Priority); kinds and ranges in SynthPresets.Effects.
--                 The chain lives on one pooled SoundGroup per layer that every grain of the layer plays through,
--                 and that group outlives the grains by the chain's tail (chainTail), so reverbs and echoes ring out
-- Preset fields: bus, layers, rollOff {min, max} (3D distances; nil = bus default when placed in 3D), priority
-- (0..100, voice stealing), maxVoices (concurrent voices of this preset), caption (Strings key), looped (the voice
-- runs until stopped), repeat {interval, jitter} (how a looped voice re-triggers its non-bed layers: heartbeat
-- pulses, drips, rain patter), duck (other buses dipped while this plays), space (an effect chain the whole preset
-- plays through, after each layer's own chain: one shared room for an ambience bed instead of a reverb per layer).
--
-- Loop-region tones: a looped region a few milliseconds long repeats fast enough to become a pitched tone
-- (period = region length / speed), e.g. a 10 ms slice of the slider tick at speed 1.2 hums at 120 Hz.
--
-- Rules the validator enforces (they keep recipes playable on a 30 fps phone):
--   * grains are spaced at least MinGrainSpacing apart: grains only start on frames, so denser clusters stack
--     into one transient. Sub-frame density comes from a short Echo on the layer (sample-accurate) instead.
--   * at most MaxGrainCount grains per trigger and MaxPresetReverbs Reverb effects per preset.
--   * a bed layer (looped, no duration) is either a whole-file loop of a seamless engine loop (Falling, Swim,
--     FootstepsPlastic) or a loop-region tone no longer than MaxToneRegion. Looping a longer region of any other
--     file (e.g. the explosion) restarts on an audible seam every pass.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local SoundLibrary = require(ReplicatedStorage.Shared.Audio.SoundLibrary)
local Strings = require(ReplicatedStorage.Shared.Strings)

export type EffectKind =
	"PitchShift"
	| "Distortion"
	| "Reverb"
	| "Equalizer"
	| "Echo"
	| "Tremolo"
	| "Chorus"
	| "Flanger"
	| "Compressor"

export type Range = { min: number, max: number }

export type Effect = { kind: EffectKind, props: { [string]: number } }

export type Envelope = { attack: number, hold: number?, release: number }

export type Glide = { to: number, time: number }

export type Grains = { count: Range, spacing: Range }

export type Layer = {
	sample: string,
	volume: number,
	speed: number | Range,
	timePosition: number?,
	region: Range?,
	regionJitter: number?,
	delay: number?,
	delayJitter: number?,
	duration: number?,
	looped: boolean?,
	effects: { Effect }?,
	envelope: Envelope?,
	glide: Glide?,
	grains: Grains?,
	chance: number?,
	volumeJitter: number?,
}

export type Pulse = { interval: number, jitter: number }

export type Duck = { bus: Enums.AudioBus, gain: number, attack: number, hold: number, release: number }

export type Preset = {
	bus: Enums.AudioBus,
	layers: { Layer },
	rollOff: Range?,
	priority: number,
	maxVoices: number,
	caption: string?,
	["repeat"]: Pulse?,
	looped: boolean?,
	duck: { Duck }?,
	space: { Effect }?,
}

-- Random one-shots scattered around the listener while an ambience bed plays. distance nil = 2D.
export type Stinger = { preset: string, interval: Range, distance: Range?, volume: number? }

export type EffectSpec = {
	className: string,
	props: { [string]: Range }, -- documented valid range of every scriptable property we drive
	defaults: { [string]: number }, -- engine defaults (pooled effects are reset to these before reuse)
}

local function r(min: number, max: number): Range
	return { min = min, max = max }
end

--------------------------------------------------------------------------------
-- SoundEffect metadata. Class names and property names verified against the v0.744 API dump
-- (note the flanger class is FlangeSoundEffect); ranges are the documented valid ranges.
--------------------------------------------------------------------------------

local EFFECTS: { [EffectKind]: EffectSpec } = {
	PitchShift = {
		className = "PitchShiftSoundEffect",
		props = { Octave = r(0.5, 2) },
		defaults = { Octave = 1.25 },
	},
	Distortion = {
		className = "DistortionSoundEffect",
		props = { Level = r(0, 1) },
		defaults = { Level = 0.75 },
	},
	Reverb = {
		className = "ReverbSoundEffect",
		props = {
			DecayTime = r(0.1, 20),
			Density = r(0, 1),
			Diffusion = r(0, 1),
			DryLevel = r(-80, 20),
			WetLevel = r(-80, 20),
		},
		defaults = { DecayTime = 1.5, Density = 1, Diffusion = 1, DryLevel = 0, WetLevel = 0 },
	},
	Equalizer = {
		className = "EqualizerSoundEffect",
		props = { LowGain = r(-80, 10), MidGain = r(-80, 10), HighGain = r(-80, 10) },
		defaults = { LowGain = -20, MidGain = -10, HighGain = 0 },
	},
	Echo = {
		className = "EchoSoundEffect",
		props = { Delay = r(0.01, 5), Feedback = r(0, 1), DryLevel = r(-80, 10), WetLevel = r(-80, 10) },
		defaults = { Delay = 1, Feedback = 0.5, DryLevel = 0, WetLevel = 0 },
	},
	Tremolo = {
		className = "TremoloSoundEffect",
		props = { Depth = r(0, 1), Duty = r(0, 1), Frequency = r(0, 20) },
		defaults = { Depth = 1, Duty = 0.5, Frequency = 5 },
	},
	Chorus = {
		className = "ChorusSoundEffect",
		props = { Depth = r(0, 1), Mix = r(0, 1), Rate = r(0, 20) },
		defaults = { Depth = 0.15, Mix = 0.5, Rate = 0.5 },
	},
	Flanger = {
		className = "FlangeSoundEffect",
		props = { Depth = r(0.01, 1), Mix = r(0, 1), Rate = r(0, 20) },
		defaults = { Depth = 0.45, Mix = 0.85, Rate = 5 },
	},
	Compressor = {
		className = "CompressorSoundEffect",
		props = {
			Threshold = r(-60, 0),
			Ratio = r(1, 50),
			Attack = r(0.0001, 1),
			Release = r(0.0001, 5),
			GainMakeup = r(0, 30),
		},
		defaults = { Threshold = -40, Ratio = 40, Attack = 0.1, Release = 0.1, GainMakeup = 0 },
	},
}

local EFFECT_KINDS: { EffectKind } = {
	"PitchShift",
	"Distortion",
	"Reverb",
	"Equalizer",
	"Echo",
	"Tremolo",
	"Chorus",
	"Flanger",
	"Compressor",
}

-- Sound property limits the synthesizer respects (PlaybackSpeed and Volume as authored, before options).
local SPEED_RANGE = r(0.05, 8)
local VOLUME_RANGE = r(0, 4)

-- Recipe rules (see the header).
local MIN_GRAIN_SPACING = 0.03
local MAX_GRAIN_COUNT = 10
local MAX_PRESET_REVERBS = 2
local MAX_TONE_REGION = 0.06
-- Longest tail a chain is ever held open for (seconds), and the level an echo has to decay to (dB re: input).
local MAX_TAIL = 14
local TAIL_FLOOR_DB = -60
-- Every Chorus / Flanger delay line is a few tens of milliseconds long.
local MODULATION_TAIL = 0.05

-- Default 3D distances per bus when a preset without rollOff is placed in the world.
local WORLD_ROLLOFF = r(8, 120)
local DEFAULT_ROLLOFF: { [Enums.AudioBus]: Range } = {
	Ambience = r(10, 90),
	World = WORLD_ROLLOFF,
	Monster = r(10, 160),
	Player = r(6, 80),
	Body = r(2, 20),
	UI = r(4, 40),
}

--------------------------------------------------------------------------------
-- Effect constructors (always set every property, so a recipe never inherits engine defaults by accident)
--------------------------------------------------------------------------------

local function eq(low: number, mid: number, high: number): Effect
	return { kind = "Equalizer", props = { LowGain = low, MidGain = mid, HighGain = high } }
end

local function reverb(decay: number, wet: number, dry: number?, density: number?, diffusion: number?): Effect
	return {
		kind = "Reverb",
		props = {
			DecayTime = decay,
			WetLevel = wet,
			DryLevel = dry or 0,
			Density = density or 1,
			Diffusion = diffusion or 1,
		},
	}
end

local function echo(delay: number, feedback: number, wet: number, dry: number?): Effect
	return { kind = "Echo", props = { Delay = delay, Feedback = feedback, WetLevel = wet, DryLevel = dry or 0 } }
end

local function tremolo(frequency: number, depth: number, duty: number?): Effect
	return { kind = "Tremolo", props = { Frequency = frequency, Depth = depth, Duty = duty or 0.5 } }
end

local function pitch(octave: number): Effect
	return { kind = "PitchShift", props = { Octave = octave } }
end

local function distortion(level: number): Effect
	return { kind = "Distortion", props = { Level = level } }
end

local function chorus(rate: number, depth: number, mix: number): Effect
	return { kind = "Chorus", props = { Rate = rate, Depth = depth, Mix = mix } }
end

local function flanger(rate: number, depth: number, mix: number): Effect
	return { kind = "Flanger", props = { Rate = rate, Depth = depth, Mix = mix } }
end

local function compressor(threshold: number, ratio: number, attack: number, release: number, makeup: number): Effect
	return {
		kind = "Compressor",
		props = { Threshold = threshold, Ratio = ratio, Attack = attack, Release = release, GainMakeup = makeup },
	}
end

local function env(attack: number, hold: number?, release: number): Envelope
	return { attack = attack, hold = hold, release = release }
end

local function glide(to: number, time: number): Glide
	return { to = to, time = time }
end

local function grains(countMin: number, countMax: number, spacingMin: number, spacingMax: number): Grains
	return { count = r(countMin, countMax), spacing = r(spacingMin, spacingMax) }
end

local function pulse(interval: number, jitter: number): Pulse
	return { interval = interval, jitter = jitter }
end

local function duck(bus: Enums.AudioBus, gain: number, attack: number, hold: number, release: number): Duck
	return { bus = bus, gain = gain, attack = attack, hold = hold, release = release }
end

local function stinger(
	preset: string,
	minInterval: number,
	maxInterval: number,
	distance: Range?,
	volume: number?
): Stinger
	return { preset = preset, interval = r(minInterval, maxInterval), distance = distance, volume = volume }
end

--------------------------------------------------------------------------------
-- Presets
--------------------------------------------------------------------------------

local presets: { [string]: Preset } = {}
local order: { string } = {}

local function define(name: string, preset: Preset)
	assert(presets[name] == nil, "duplicate preset " .. name)
	presets[name] = preset
	table.insert(order, name)
end

---------------------------------------------------------------- the Creature

-- The jumpscare cry. The engine's "ouch" pitched up hard (speed x PitchShift ~ +21 semitones), looped on its
-- voiced core so it sustains, rising, torn by distortion and shimmering under a fast tremolo; a detuned second
-- throat smears it into a chord; a slowed explosion gives it a chest; slider pings chatter like claws on steel;
-- a short pre-delay echo throws it off the walls.
define("Screech", {
	bus = "Monster",
	priority = 100,
	maxVoices = 2,
	rollOff = r(20, 420),
	caption = "Caption.Screech",
	duck = { duck("Ambience", 0.25, 0.03, 1.2, 1.6), duck("World", 0.6, 0.03, 0.8, 1.0) },
	layers = {
		{
			sample = "Ouch",
			volume = 1.5,
			speed = r(2.15, 2.45),
			region = r(0.04, 0.3),
			regionJitter = 0.02,
			looped = true,
			duration = 1.25,
			envelope = env(0.015, nil, 0.4),
			glide = glide(1.2, 0.6),
			effects = { pitch(1.5), distortion(0.62), tremolo(13, 0.5, 0.55), eq(-14, 3, 6), echo(0.07, 0.3, -8) },
		},
		{
			sample = "Ouch",
			volume = 0.95,
			speed = r(2.6, 2.9),
			region = r(0.08, 0.28),
			regionJitter = 0.02,
			delay = 0.035,
			looped = true,
			duration = 1.1,
			envelope = env(0.03, nil, 0.45),
			glide = glide(1.28, 0.7),
			effects = { pitch(1.25), chorus(6, 0.45, 0.6), distortion(0.45), eq(-20, 0, 4) },
		},
		{
			sample = "Explosion",
			volume = 1.3,
			speed = r(0.55, 0.65),
			region = r(0, 1.4),
			duration = 1.4,
			envelope = env(0.03, nil, 0.6),
			effects = { distortion(0.45), eq(6, -2, -10), compressor(-20, 6, 0.005, 0.2, 4) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.65,
			speed = r(3.2, 3.8),
			delay = 0.05,
			grains = grains(6, 9, 0.06, 0.11),
			volumeJitter = 0.3,
			effects = { flanger(8, 0.6, 0.7), distortion(0.5), echo(0.03, 0.35, -6) },
		},
		{
			sample = "Falling",
			volume = 0.55,
			speed = 2.4,
			region = r(0.1, 1),
			duration = 0.95,
			envelope = env(0.02, nil, 0.4),
			effects = { eq(-30, -6, 6), distortion(0.3) },
		},
	},
})

-- The lunge: a whoosh swept upward as it closes in, rushing air, a crushed snarl, claws, then the hit.
define("Lunge", {
	bus = "Monster",
	priority = 98,
	maxVoices = 2,
	rollOff = r(10, 200),
	duck = { duck("Ambience", 0.3, 0.02, 0.6, 1.0) },
	layers = {
		{
			sample = "Jump",
			volume = 1.6,
			speed = r(0.5, 0.6),
			glide = glide(1.6, 0.35),
			effects = { eq(4, 2, -6), flanger(1.5, 0.5, 0.4) },
		},
		{
			sample = "Falling",
			volume = 1,
			speed = 1.6,
			region = r(0.1, 0.8),
			duration = 0.5,
			envelope = env(0.15, 0.1, 0.25),
			glide = glide(1.8, 0.4),
			effects = { eq(-10, 2, 2) },
		},
		{
			sample = "Oof",
			volume = 1.2,
			speed = r(0.52, 0.6),
			effects = { pitch(0.75), distortion(0.7), eq(6, 2, -6) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.5,
			speed = r(1.8, 2.4),
			delay = 0.3,
			grains = grains(3, 5, 0.03, 0.06),
			effects = { distortion(0.6), eq(-20, 2, 4) },
		},
		{ sample = "JumpLand", volume = 1.4, speed = 0.6, delay = 0.42, effects = { eq(8, -4, -16) } },
	},
})

-- Metal scraping inside the walls while the Creature crawls the ducts (looped; audible to everyone nearby).
-- Each stride is one sustained scrape: wind noise sped up into a hiss and pushed through a tight comb echo (the
-- 10-15 ms delay rings like sheet steel), crushed, and chopped by a fast low-duty tremolo into stick-slip chatter,
-- sagging in pitch as the limb drags. Steel squeals under the weight, claws click on the seams and the body slides.
-- Under it the duct itself rumbles in its bore.
define("VentScrape", {
	bus = "Monster",
	priority = 85,
	maxVoices = 2,
	rollOff = r(10, 180),
	caption = "Caption.VentScrape",
	looped = true,
	["repeat"] = pulse(1.1, 0.4),
	layers = {
		-- The duct: a slow resonant rumble (the comb echo is the tube's ringing mode).
		{
			sample = "Falling",
			volume = 0.45,
			speed = 0.48,
			looped = true,
			envelope = env(0.5, nil, 0.6),
			effects = { eq(-6, 6, -14), echo(0.02, 0.6, -8) },
		},
		-- The scrape (one sustained stroke per stride).
		{
			sample = "Falling",
			volume = 0.75,
			speed = r(1.8, 2.4),
			region = r(0.1, 1.1),
			regionJitter = 0.08,
			looped = true,
			duration = 0.75,
			envelope = env(0.06, nil, 0.3),
			glide = glide(0.85, 0.6),
			effects = { echo(0.012, 0.8, -3), distortion(0.5), eq(-20, 8, 2), tremolo(9, 0.7, 0.3) },
		},
		-- Steel squealing under load: an 8 ms loop tone bending upward, not on every stride.
		{
			sample = "VolumeSlider",
			volume = 0.22,
			speed = r(0.9, 1.4),
			region = r(0.02, 0.028),
			looped = true,
			duration = 0.55,
			delay = 0.08,
			delayJitter = 0.2,
			chance = 0.55,
			envelope = env(0.05, nil, 0.25),
			glide = glide(1.18, 0.45),
			effects = { distortion(0.35), flanger(0.7, 0.4, 0.35), eq(-24, 4, -2) },
		},
		-- Claws: short bright clicks (footstep transients sped up), skittering on the steel.
		{
			sample = "FootstepsPlastic",
			volume = 0.9,
			speed = r(1.6, 2.2),
			region = r(0, 0.06),
			regionJitter = 0.12,
			grains = grains(3, 5, 0.05, 0.13),
			volumeJitter = 0.3,
			effects = { eq(-10, 6, 4), echo(0.011, 0.6, -6) },
		},
		-- Body drag: cloth rustle slowed into a heavy torso sliding on steel.
		{
			sample = "GetUp",
			volume = 0.7,
			speed = r(0.45, 0.55),
			delay = 0.2,
			delayJitter = 0.15,
			grains = grains(1, 2, 0.3, 0.6),
			effects = { eq(4, 3, -10), echo(0.016, 0.5, -8) },
		},
	},
})

-- Heavy breathing through the ductwork (looped): throat-band wind inhale, raspy exhale, a voiced growl under it.
define("VentBreathing", {
	bus = "Monster",
	priority = 80,
	maxVoices = 2,
	rollOff = r(8, 130),
	caption = "Caption.Breathing",
	looped = true,
	["repeat"] = pulse(2.7, 0.5),
	layers = {
		{
			sample = "Falling",
			volume = 0.9,
			speed = r(0.72, 0.82),
			region = r(0.2, 1),
			looped = true,
			duration = 1.4,
			envelope = env(0.65, 0.25, 0.5),
			effects = { eq(-12, 4, -6), chorus(0.8, 0.3, 0.4), echo(0.08, 0.5, -6) },
		},
		{
			sample = "Falling",
			volume = 1,
			speed = r(0.55, 0.62),
			region = r(0.1, 1.1),
			delay = 1.2,
			looped = true,
			duration = 1.35,
			envelope = env(0.15, 0.35, 0.85),
			effects = { eq(-6, 2, -12), distortion(0.22), echo(0.08, 0.5, -6) },
		},
		{
			sample = "Oof",
			volume = 0.55,
			speed = r(0.36, 0.42),
			delay = 1.18,
			chance = 0.7,
			envelope = env(0.1, nil, 0.5),
			effects = { pitch(0.7), distortion(0.45), eq(4, -2, -16) },
		},
	},
})

-- A low, wet snarl (investigating, peering into lockers and grates).
define("CreatureGrowl", {
	bus = "Monster",
	priority = 75,
	maxVoices = 2,
	rollOff = r(8, 140),
	layers = {
		{
			sample = "Oof",
			volume = 1.1,
			speed = r(0.38, 0.44),
			region = r(0.04, 0.3),
			looped = true,
			duration = 1.6,
			envelope = env(0.2, nil, 0.6),
			glide = glide(0.85, 1.4),
			effects = { pitch(0.7), distortion(0.6), tremolo(6, 0.5, 0.5), eq(6, 0, -10) },
		},
		{
			sample = "Explosion",
			volume = 0.6,
			speed = 0.5,
			region = r(0, 1),
			duration = 1.5,
			envelope = env(0.3, nil, 0.6),
			effects = { distortion(0.35), eq(6, -4, -24) },
		},
		{
			sample = "Ouch",
			volume = 0.4,
			speed = r(0.58, 0.66),
			delay = 0.5,
			chance = 0.4,
			effects = { pitch(0.8), distortion(0.5), eq(0, 2, -8) },
		},
	},
})

-- The 180-degree head turn: vertebrae grinding round, then one sharp crack.
define("NeckSnap", {
	bus = "Monster",
	priority = 90,
	maxVoices = 1,
	rollOff = r(8, 140),
	layers = {
		{
			sample = "FootstepsPlastic",
			volume = 1.2,
			speed = r(0.5, 0.65),
			region = r(0, 0.3),
			regionJitter = 0.05,
			grains = grains(4, 6, 0.03, 0.07),
			effects = { distortion(0.75), eq(4, 6, -4) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 1.5,
			speed = 1.6,
			region = r(0, 0.12),
			delay = 0.24,
			effects = { distortion(0.85), eq(-4, 6, 4) },
		},
		{ sample = "GetUp", volume = 0.6, speed = 0.5, effects = { eq(2, 4, -12) } },
	},
})

-- Stinger hit for jumpscares (played 2D for the victim).
define("JumpscareSting", {
	bus = "Monster",
	priority = 99,
	maxVoices = 1,
	duck = { duck("Ambience", 0.1, 0.01, 1.4, 2), duck("World", 0.4, 0.01, 1, 1.5) },
	layers = {
		{
			sample = "Explosion",
			volume = 1.4,
			speed = 1.1,
			region = r(0, 0.8),
			effects = { distortion(0.6), compressor(-14, 12, 0.001, 0.25, 6) },
		},
		{
			sample = "Ouch",
			volume = 1.2,
			speed = 2.4,
			region = r(0.05, 0.3),
			looped = true,
			duration = 0.6,
			envelope = env(0.005, nil, 0.35),
			effects = { pitch(2), distortion(0.8), eq(-20, 2, 6) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.5,
			speed = 0.3,
			region = r(0.01, 0.05),
			looped = true,
			duration = 0.8,
			envelope = env(0.005, nil, 0.6),
			effects = { distortion(0.9), flanger(4, 0.8, 0.6) },
		},
	},
})

---------------------------------------------------------------- the player's body

-- Lub-dub: the landing thump slowed into a chest thud with the low end boosted; the second beat follows by a
-- layer delay and the voice re-triggers on the pulse interval.
define("Heartbeat", {
	bus = "Body",
	priority = 60,
	maxVoices = 1,
	caption = "Caption.Heartbeat",
	looped = true,
	["repeat"] = pulse(0.92, 0.03),
	layers = {
		{
			sample = "JumpLand",
			volume = 1.7,
			speed = r(0.42, 0.46),
			region = r(0, 0.2),
			envelope = env(0.004, 0.09, 0.14),
			effects = { eq(8, -14, -40), compressor(-24, 8, 0.002, 0.15, 6) },
		},
		{
			sample = "JumpLand",
			volume = 1.15,
			speed = r(0.5, 0.54),
			region = r(0, 0.2),
			delay = 0.27,
			envelope = env(0.004, 0.07, 0.14),
			effects = { eq(8, -16, -40), compressor(-24, 8, 0.002, 0.15, 6) },
		},
		{
			sample = "Explosion",
			volume = 0.35,
			speed = 0.35,
			region = r(0, 0.25),
			envelope = env(0.006, 0.06, 0.2),
			effects = { eq(6, -24, -60) },
		},
	},
})

define("HeartbeatFast", {
	bus = "Body",
	priority = 62,
	maxVoices = 1,
	caption = "Caption.Heartbeat",
	looped = true,
	["repeat"] = pulse(0.43, 0.02),
	layers = {
		{
			sample = "JumpLand",
			volume = 1.9,
			speed = r(0.5, 0.54),
			region = r(0, 0.2),
			envelope = env(0.003, 0.06, 0.1),
			effects = { eq(8, -12, -40), compressor(-22, 8, 0.002, 0.12, 7) },
		},
		{
			sample = "JumpLand",
			volume = 1.3,
			speed = r(0.56, 0.6),
			region = r(0, 0.2),
			delay = 0.17,
			envelope = env(0.003, 0.05, 0.1),
			effects = { eq(8, -14, -40), compressor(-22, 8, 0.002, 0.12, 7) },
		},
		{
			sample = "Explosion",
			volume = 0.4,
			speed = 0.4,
			region = r(0, 0.2),
			envelope = env(0.004, 0.05, 0.14),
			effects = { eq(6, -24, -60) },
		},
	},
})

define("Breathing", {
	bus = "Body",
	priority = 40,
	maxVoices = 1,
	looped = true,
	["repeat"] = pulse(3.4, 0.35),
	layers = {
		{
			sample = "Falling",
			volume = 0.35,
			speed = r(0.95, 1.05),
			region = r(0.2, 1),
			looped = true,
			duration = 1.25,
			envelope = env(0.55, 0.2, 0.5),
			effects = { eq(-22, -2, -8) },
		},
		{
			sample = "Falling",
			volume = 0.4,
			speed = r(0.8, 0.88),
			region = r(0.1, 1),
			delay = 1.45,
			looped = true,
			duration = 1.5,
			envelope = env(0.12, 0.35, 1),
			effects = { eq(-18, -4, -12) },
		},
	},
})

-- Panicked breathing: short, shaking inhales (a fast tremolo is the shudder) and ragged exhales. Pure breath noise,
-- no voice: the stock avatar grunt must never be recognisable in a horror moment.
define("BreathingPanic", {
	bus = "Body",
	priority = 45,
	maxVoices = 1,
	looped = true,
	["repeat"] = pulse(1.2, 0.12),
	layers = {
		{
			sample = "Falling",
			volume = 0.55,
			speed = r(1.1, 1.2),
			region = r(0.2, 1),
			looped = true,
			duration = 0.5,
			envelope = env(0.18, 0.12, 0.2),
			effects = { eq(-20, 0, -4), tremolo(9, 0.35, 0.5) },
		},
		{
			sample = "Falling",
			volume = 0.6,
			speed = r(0.92, 1),
			region = r(0.1, 1),
			delay = 0.52,
			looped = true,
			duration = 0.62,
			envelope = env(0.06, 0.2, 0.36),
			effects = { eq(-16, -2, -8), distortion(0.12) },
		},
		-- Now and then the breath catches in the throat.
		{
			sample = "GetUp",
			volume = 0.18,
			speed = r(1.5, 1.8),
			region = r(0, 0.12),
			delay = 0.47,
			chance = 0.3,
			effects = { eq(-14, 3, -6) },
		},
	},
})

-- A loud gasp (failed breath hold): a sharp intake built from breath noise alone. The wind loop is narrowed to the
-- throat band and rises in pitch as the lungs fill, a soft whoosh of air sits under it, and the throat catches at the
-- top. No voiced sample: the stock avatar grunt would read as comedy.
define("Gasp", {
	bus = "Player",
	priority = 80,
	maxVoices = 2,
	rollOff = r(6, 90),
	caption = "Caption.Gasp",
	layers = {
		{
			sample = "Falling",
			volume = 1.25,
			speed = 1.3,
			region = r(0.1, 0.7),
			envelope = env(0.01, 0.15, 0.2),
			glide = glide(1.55, 0.25),
			effects = { eq(-30, 4, 2), reverb(0.6, -12) },
		},
		{ sample = "Jump", volume = 0.55, speed = 1.2, effects = { eq(-18, 2, 0) } },
		{
			sample = "GetUp",
			volume = 0.35,
			speed = 1.6,
			region = r(0, 0.15),
			delay = 0.2,
			chance = 0.6,
			effects = { eq(-12, 4, -2) },
		},
	},
})

-- EMF interference (looped, 2D): crushed and chopped wind hiss, crackle grains, a buzzing loop-region tone.
define("EmfStatic", {
	bus = "Body",
	priority = 55,
	maxVoices = 1,
	caption = "Caption.Static",
	looped = true,
	["repeat"] = pulse(0.55, 0.3),
	layers = {
		{
			sample = "Falling",
			volume = 0.55,
			speed = 2.6,
			looped = true,
			envelope = env(0.08, nil, 0.25),
			effects = { distortion(0.8), tremolo(17, 0.85, 0.3), eq(-30, 0, 4) },
		},
		-- Crackle: a few sped-up clicks per burst; the short echo fills them in to dense static.
		{
			sample = "FootstepsPlastic",
			volume = 0.45,
			speed = r(2.5, 3.5),
			region = r(0, 0.3),
			regionJitter = 0.08,
			grains = grains(3, 6, 0.035, 0.11),
			volumeJitter = 0.5,
			effects = { distortion(0.9), eq(-24, 2, 6), echo(0.014, 0.35, -10) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.12,
			speed = 1,
			region = r(0.02, 0.03),
			looped = true,
			envelope = env(0.1, nil, 0.2),
			effects = { distortion(0.9), tremolo(11, 0.9, 0.5), eq(-20, 2, -4) },
		},
	},
})

-- Hand and knee thumps on galvanized steel while crawling a duct.
define("VentCrawl", {
	bus = "Player",
	priority = 32,
	maxVoices = 6,
	rollOff = r(5, 70),
	layers = {
		{
			sample = "JumpLand",
			volume = 0.8,
			speed = r(0.75, 0.9),
			volumeJitter = 0.2,
			effects = { flanger(0.6, 0.5, 0.5), eq(2, 5, -6), echo(0.04, 0.45, -6) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.2,
			speed = r(0.4, 0.5),
			chance = 0.6,
			effects = { distortion(0.2), reverb(0.6, -10) },
		},
	},
})

define("SwimStroke", {
	bus = "Player",
	priority = 35,
	maxVoices = 6,
	rollOff = r(6, 120),
	layers = {
		{
			sample = "Swim",
			volume = 0.9,
			speed = r(0.95, 1.15),
			region = r(0, 0.8),
			regionJitter = 0.04,
			volumeJitter = 0.15,
			effects = { eq(2, 0, -2) },
		},
		{
			sample = "WaterImpact",
			volume = 0.4,
			speed = r(1.3, 1.6),
			region = r(0, 0.4),
			delay = 0.08,
			chance = 0.4,
		},
	},
})

define("WaterTread", {
	bus = "Player",
	priority = 25,
	maxVoices = 6,
	rollOff = r(4, 50),
	layers = {
		{
			sample = "Swim",
			volume = 0.45,
			speed = r(0.7, 0.85),
			region = r(0.1, 0.6),
			regionJitter = 0.08,
			envelope = env(0.08, 0.3, 0.3),
			effects = { eq(2, -2, -8) },
		},
	},
})

-- Bursting up through the surface out of breath (P7, local): a ragged intake through the throat band, rising as the
-- lungs fill, with the water streaming off the head and shoulders.
define("SurfaceGasp", {
	bus = "Player",
	priority = 50,
	maxVoices = 2,
	rollOff = r(4, 45),
	layers = {
		{
			sample = "Falling",
			volume = 0.9,
			speed = 1.25,
			region = r(0.1, 0.55),
			envelope = env(0.02, 0.12, 0.25),
			glide = glide(1.4, 0.3),
			effects = { eq(-30, 4, 0), reverb(0.5, -14) },
		},
		{
			sample = "Swim",
			volume = 0.45,
			speed = r(1.2, 1.4),
			region = r(0.2, 0.6),
			delay = 0.05,
			effects = { eq(-6, 0, -4) },
		},
	},
})

-- Hauling yourself out over the coping (P7): the body breaking the surface, water pouring off and pattering on the
-- tiles, a knee landing on the deck.
define("ClimbOut", {
	bus = "Player",
	priority = 30,
	maxVoices = 3,
	rollOff = r(5, 70),
	layers = {
		{ sample = "Swim", volume = 0.8, speed = r(0.9, 1.05), region = r(0, 0.7), effects = { eq(2, 0, -2) } },
		{
			sample = "WaterImpact",
			volume = 0.35,
			speed = r(2.2, 2.8),
			region = r(0.05, 0.25),
			regionJitter = 0.04,
			delay = 0.25,
			grains = grains(4, 7, 0.05, 0.12),
			volumeJitter = 0.5,
			effects = { eq(-12, 0, 2) },
		},
		{ sample = "JumpLand", volume = 0.6, speed = 0.9, delay = 0.45, effects = { eq(2, 0, -6) } },
	},
})

-- Breath escaping underwater (P7): a burst of small bubbles, each a sped-up droplet slice smeared by a chorus, with a
-- glassy pop or two on top, the highs drowned.
define("Bubbles", {
	bus = "Player",
	priority = 30,
	maxVoices = 4,
	rollOff = r(2, 30),
	layers = {
		{
			sample = "WaterImpact",
			volume = 0.35,
			speed = r(2.6, 3.4),
			region = r(0.05, 0.15),
			regionJitter = 0.05,
			grains = grains(4, 8, 0.04, 0.11),
			volumeJitter = 0.5,
			effects = { eq(-10, 4, -24), chorus(2.5, 0.5, 0.5) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.18,
			speed = r(1.6, 2.4),
			region = r(0.02, 0.026),
			looped = true,
			duration = 0.05,
			grains = grains(3, 6, 0.05, 0.12),
			envelope = env(0.001, 0.01, 0.03),
			glide = glide(1.6, 0.05),
			effects = { eq(-20, 2, -18) },
		},
	},
})

-- A swimmer fighting the Creature's grip under the surface (P7, looped on the victim): churning water under it, the
-- slaps of arms and legs on every pulse, and spray some of the time.
define("StruggleThrash", {
	bus = "Player",
	priority = 70,
	maxVoices = 2,
	rollOff = r(6, 110),
	caption = "Caption.Thrash",
	looped = true,
	["repeat"] = pulse(0.3, 0.15),
	layers = {
		{
			sample = "Swim",
			volume = 0.7,
			speed = r(1.1, 1.4),
			looped = true,
			envelope = env(0.15, nil, 0.4),
			effects = { eq(2, 0, -4), chorus(1.2, 0.4, 0.4) },
		},
		{
			sample = "WaterImpact",
			volume = 0.7,
			speed = r(0.8, 1.3),
			region = r(0, 0.4),
			regionJitter = 0.1,
			volumeJitter = 0.35,
			effects = { eq(2, 0, -3) },
		},
		{
			sample = "Swim",
			volume = 0.5,
			speed = r(1.4, 1.9),
			region = r(0.1, 0.5),
			regionJitter = 0.1,
			chance = 0.6,
			effects = { eq(0, 2, -2) },
		},
	},
})

define("Pickup", {
	bus = "Player",
	priority = 45,
	maxVoices = 2,
	layers = {
		{ sample = "VolumeSlider", volume = 0.45, speed = 1.6, effects = { eq(-10, 0, 2) } },
		{ sample = "VolumeSlider", volume = 0.4, speed = 2.1, delay = 0.05, effects = { eq(-10, 0, 2) } },
		{ sample = "GetUp", volume = 0.3, speed = 1.4, region = r(0, 0.3) },
	},
})

---------------------------------------------------------------- world events

-- Bear trap: a crushed strike, then ringing iron. The ring is a 6 ms slice of the slider tick looped into a bright
-- tone, struck and left to decay while the jaws settle (a slight downward glide), with a tight comb echo for the
-- steel body and an inharmonic second partial above it (iron never rings in tune with itself). Then the spring
-- rattling as it unloads, the weight of the jaws and the crack of the hit.
define("TrapSnap", {
	bus = "World",
	priority = 90,
	maxVoices = 3,
	rollOff = r(10, 220),
	caption = "Caption.TrapSnap",
	duck = { duck("Ambience", 0.5, 0.01, 0.4, 0.8) },
	layers = {
		{
			sample = "FootstepsPlastic",
			volume = 2,
			speed = 0.8,
			region = r(0, 0.15),
			effects = { distortion(0.6), eq(2, 6, 4), compressor(-18, 10, 0.001, 0.1, 6) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.9,
			speed = r(1.5, 1.7),
			region = r(0.03, 0.036),
			looped = true,
			duration = 0.9,
			envelope = env(0.002, nil, 0.8),
			glide = glide(0.97, 0.8),
			effects = { echo(0.01, 0.6, -4), distortion(0.2), eq(-18, 4, 2) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.45,
			speed = r(2.6, 2.9),
			region = r(0.03, 0.036),
			looped = true,
			duration = 0.6,
			envelope = env(0.002, nil, 0.55),
			glide = glide(0.98, 0.5),
			effects = { eq(-30, 0, 4), reverb(1.4, -10) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.55,
			speed = r(1.4, 1.8),
			delay = 0.03,
			grains = grains(3, 5, 0.035, 0.06),
			effects = { eq(-20, 2, 4), echo(0.018, 0.35, -8) },
		},
		{ sample = "JumpLand", volume = 1.2, speed = 0.7, effects = { eq(6, -4, -12) } },
		{ sample = "Explosion", volume = 0.6, speed = 1.4, region = r(0, 0.35), effects = { eq(0, 2, -6) } },
	},
})

define("BoneCrunch", {
	bus = "World",
	priority = 85,
	maxVoices = 3,
	rollOff = r(6, 120),
	layers = {
		-- Splintering: a few crushed transients; the short echo packs them into a dense crackle.
		{
			sample = "FootstepsPlastic",
			volume = 1.6,
			speed = r(0.55, 0.7),
			region = r(0, 0.3),
			regionJitter = 0.04,
			grains = grains(2, 4, 0.035, 0.06),
			effects = { distortion(0.7), eq(4, 6, -6), echo(0.012, 0.45, -6) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 1.2,
			speed = r(1.7, 1.9),
			region = r(0, 0.12),
			delay = 0.012,
			effects = { distortion(0.8), eq(-6, 4, 6) },
		},
		{
			sample = "WaterImpact",
			volume = 0.7,
			speed = r(0.6, 0.7),
			region = r(0, 0.35),
			delay = 0.02,
			effects = { eq(6, 0, -18), distortion(0.3) },
		},
		{ sample = "JumpLand", volume = 0.8, speed = 0.6, effects = { eq(6, -6, -20) } },
	},
})

-- One drop: a "plink" - a 5 ms slice of the slider tick looped into a tone whose pitch rises over 40 ms, the way a
-- drop's bubble rings - with the splash transient mixed in under it, an echo off the floor and a short damp room
-- tail (the tails ring out on the layer's group after the drop itself is gone).
local DRIP_LAYERS: { Layer } = {
	{
		sample = "VolumeSlider",
		volume = 0.5,
		speed = r(2.4, 3.2),
		region = r(0.03, 0.035),
		looped = true,
		duration = 0.07,
		volumeJitter = 0.3,
		envelope = env(0.001, 0.01, 0.05),
		glide = glide(1.3, 0.04),
		effects = { eq(-30, -2, 4), echo(0.11, 0.3, -12), reverb(1.4, -9) },
	},
	{
		sample = "WaterImpact",
		volume = 0.18,
		speed = r(2.6, 3.4),
		region = r(0, 0.08),
		regionJitter = 0.02,
		volumeJitter = 0.3,
		envelope = env(0.001, 0.03, 0.04),
		effects = { eq(-30, -2, 4) },
	},
}

-- DripPipe emitters play this looped (AudioController); it re-triggers on the pulse. Its own voices are reserved
-- for emitters (maxVoices above AudioController.MaxEmitterVoices); bed stingers use DripStinger below, so a
-- stinger can never evict a pipe.
define("Drip", {
	bus = "World",
	priority = 15,
	maxVoices = 10,
	rollOff = r(4, 60),
	["repeat"] = pulse(2.2, 1.3),
	layers = DRIP_LAYERS,
})

-- A single drop somewhere nearby (ambience bed stinger, one-shot).
define("DripStinger", {
	bus = "World",
	priority = 14,
	maxVoices = 3,
	rollOff = r(4, 60),
	layers = DRIP_LAYERS,
})

-- Broken glass and cans underfoot: transient clusters (every grain lands on its own frame and a short echo packs
-- each one into a dense crunch), skittering shards, crushed tin, body weight.
define("GlassCrunch", {
	bus = "World",
	priority = 75,
	maxVoices = 3,
	rollOff = r(6, 170),
	caption = "Caption.GlassCrunch",
	layers = {
		{
			sample = "FootstepsPlastic",
			volume = 1.3,
			speed = r(1.8, 2.3),
			region = r(0, 0.3),
			regionJitter = 0.06,
			grains = grains(3, 5, 0.035, 0.06),
			effects = { eq(-18, 2, 8), distortion(0.5), echo(0.013, 0.45, -6) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.5,
			speed = r(2.8, 4.2),
			delay = 0.02,
			grains = grains(4, 7, 0.035, 0.08),
			volumeJitter = 0.4,
			effects = { eq(-40, -4, 6), echo(0.021, 0.35, -9) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.9,
			speed = r(0.8, 0.9),
			region = r(0, 0.2),
			delay = 0.06,
			effects = { flanger(0.5, 0.7, 0.5), eq(-4, 6, -2) },
		},
		{ sample = "JumpLand", volume = 0.6, speed = 1, effects = { eq(2, -2, -10) } },
	},
})

define("FlaskShatter", {
	bus = "World",
	priority = 72,
	maxVoices = 3,
	rollOff = r(8, 180),
	layers = {
		{
			sample = "FootstepsPlastic",
			volume = 1.3,
			speed = r(2, 2.4),
			region = r(0, 0.15),
			effects = { distortion(0.6), eq(-12, 4, 8) },
		},
		-- Shards: one per frame at most; the echo multiplies each into a shower.
		{
			sample = "VolumeSlider",
			volume = 0.7,
			speed = r(3, 4.5),
			delay = 0.01,
			grains = grains(5, 8, 0.035, 0.07),
			volumeJitter = 0.5,
			effects = { eq(-40, -4, 6), echo(0.017, 0.4, -7) },
		},
		{
			sample = "WaterImpact",
			volume = 0.8,
			speed = r(1.4, 1.7),
			region = r(0, 0.4),
			delay = 0.02,
			effects = { eq(-6, 2, 2) },
		},
	},
})

-- The stun cloud: a long chemical hiss with a fizzing undertone, after the initial gout of gas.
define("ChemHiss", {
	bus = "World",
	priority = 50,
	maxVoices = 4,
	rollOff = r(6, 90),
	caption = "Caption.ChemHiss",
	layers = {
		{
			sample = "Falling",
			volume = 0.9,
			speed = r(2, 2.3),
			region = r(0.1, 1.1),
			looped = true,
			duration = 6.6,
			envelope = env(0.05, 5, 1.4),
			effects = { eq(-30, -4, 6), chorus(3, 0.4, 0.5) },
		},
		{
			sample = "Swim",
			volume = 0.6,
			speed = r(2.5, 2.8),
			looped = true,
			duration = 6.3,
			envelope = env(0.1, 4.6, 1.5),
			effects = { distortion(0.4), eq(-24, -2, 5) },
		},
		{
			sample = "Falling",
			volume = 0.8,
			speed = 1.5,
			region = r(0.1, 0.9),
			duration = 0.7,
			envelope = env(0.01, 0.2, 0.45),
			effects = { eq(-18, 2, 4), distortion(0.3) },
		},
	},
})

-- The hallway gate slamming: a boom, ringing bars, rattling chain, the weight, and the corridor throwing it back.
define("GateSlam", {
	bus = "World",
	priority = 92,
	maxVoices = 2,
	rollOff = r(16, 320),
	caption = "Caption.GateSlam",
	duck = { duck("Ambience", 0.35, 0.01, 0.9, 1.5) },
	layers = {
		{
			sample = "Explosion",
			volume = 1.5,
			speed = r(0.95, 1.05),
			region = r(0, 0.6),
			effects = { distortion(0.3), eq(6, 0, -6), compressor(-16, 8, 0.002, 0.2, 4) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.9,
			speed = 0.3,
			effects = { flanger(0.1, 0.9, 0.6), distortion(0.4), reverb(3.5, -2) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.5,
			speed = r(1.2, 1.7),
			delay = 0.08,
			grains = grains(6, 10, 0.03, 0.08),
			volumeJitter = 0.3,
			effects = { echo(0.06, 0.4, -6), eq(-16, 3, 2) },
		},
		{ sample = "JumpLand", volume = 1.4, speed = 0.5, effects = { eq(8, -6, -20) } },
		{
			sample = "Explosion",
			volume = 0.6,
			speed = 0.5,
			region = r(0.2, 1.6),
			delay = 0.1,
			effects = { echo(0.25, 0.4, -6, -4), eq(4, -6, -24) },
		},
	},
})

-- The Creature tearing through the roof stairwell door.
define("DoorSmash", {
	bus = "World",
	priority = 95,
	maxVoices = 2,
	rollOff = r(20, 320),
	caption = "Caption.DoorSmash",
	duck = { duck("Ambience", 0.3, 0.01, 1, 1.6), duck("Player", 0.7, 0.01, 0.5, 0.8) },
	layers = {
		{
			sample = "FootstepsPlastic",
			volume = 1.8,
			speed = r(0.45, 0.55),
			region = r(0, 0.3),
			regionJitter = 0.05,
			grains = grains(2, 4, 0.035, 0.06),
			effects = {
				distortion(0.75),
				eq(4, 6, 2),
				compressor(-18, 10, 0.001, 0.2, 6),
				echo(0.012, 0.5, -5),
			},
		},
		{
			sample = "Explosion",
			volume = 1.6,
			speed = r(0.7, 0.8),
			region = r(0, 0.9),
			effects = { distortion(0.4), eq(8, 0, -8) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.45,
			speed = 0.42,
			region = r(0.01, 0.05),
			looped = true,
			duration = 0.9,
			glide = glide(0.7, 0.8),
			envelope = env(0.01, nil, 0.5),
			effects = { flanger(0.8, 0.8, 0.6), distortion(0.6), reverb(2.5, -6) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.6,
			speed = r(0.9, 1.6),
			region = r(0, 0.3),
			regionJitter = 0.06,
			delay = 0.25,
			grains = grains(6, 10, 0.04, 0.12),
			volumeJitter = 0.4,
			effects = { eq(-6, 3, 0) },
		},
		{ sample = "JumpLand", volume = 1.3, speed = 0.45, delay = 0.4, effects = { eq(8, -6, -20) } },
	},
})

-- A heavy steel fire door swinging on its closer: a slow hinge groan sagging in pitch, the closer's hydraulic hiss,
-- the weight of air it pushes, and the push bar rattling as it sets off, in a concrete vestibule.
define("FireDoorSwing", {
	bus = "World",
	priority = 55,
	maxVoices = 3,
	rollOff = r(8, 110),
	space = { reverb(1.8, -8) },
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.32,
			speed = r(0.18, 0.24),
			region = r(0.01, 0.05),
			looped = true,
			duration = 1.3,
			glide = glide(0.75, 1.2),
			envelope = env(0.25, nil, 0.5),
			effects = { flanger(0.25, 0.85, 0.55), distortion(0.4), eq(2, 4, -12) },
		},
		{
			sample = "Falling",
			volume = 0.22,
			speed = r(0.5, 0.6),
			region = r(0.1, 1.1),
			duration = 1.4,
			envelope = env(0.4, nil, 0.6),
			effects = { eq(-14, 2, -6) },
		},
		{
			sample = "Falling",
			volume = 0.18,
			speed = r(0.22, 0.28),
			region = r(0.1, 1.1),
			duration = 1.5,
			envelope = env(0.5, nil, 0.6),
			effects = { eq(6, -8, -30) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.35,
			speed = r(1.2, 1.5),
			region = r(0, 0.2),
			regionJitter = 0.04,
			grains = grains(2, 3, 0.05, 0.09),
			volumeJitter = 0.3,
			effects = { flanger(1, 0.5, 0.5), eq(-10, 4, 0) },
		},
	},
})

-- A fire door slamming into its frame and latching: the body thump, a short steel boom, the leaf ringing, the latch
-- bolt snapping home a beat later and the frame rattling around it.
define("FireDoorLatch", {
	bus = "World",
	priority = 80,
	maxVoices = 2,
	rollOff = r(12, 200),
	caption = "Caption.FireDoor",
	duck = { duck("Ambience", 0.55, 0.01, 0.5, 1) },
	space = { reverb(2.6, -6) },
	layers = {
		{
			sample = "JumpLand",
			volume = 1.5,
			speed = 0.42,
			effects = { eq(9, -4, -18), compressor(-18, 8, 0.002, 0.2, 5) },
		},
		{
			sample = "Explosion",
			volume = 0.9,
			speed = r(1.05, 1.2),
			region = r(0, 0.35),
			effects = { distortion(0.25), eq(5, -2, -10) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.6,
			speed = r(0.32, 0.38),
			effects = { flanger(0.2, 0.8, 0.5), distortion(0.3), reverb(2.2, -4) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.8,
			speed = r(1.5, 1.8),
			region = r(0, 0.12),
			delay = 0.04,
			effects = { eq(-12, 6, 4), echo(0.02, 0.3, -8) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.3,
			speed = r(1, 1.4),
			delay = 0.06,
			grains = grains(3, 6, 0.03, 0.07),
			volumeJitter = 0.35,
			effects = { echo(0.04, 0.35, -8), eq(-14, 2, 0) },
		},
	},
})

-- A lighter door (the classroom's wood, the roof's dented steel) swinging: a hinge creak rising under a shiver, the
-- leaf flexing, a breath of air.
define("DoorCreak", {
	bus = "World",
	priority = 35,
	maxVoices = 3,
	rollOff = r(6, 70),
	caption = "Caption.DoorCreak",
	space = { reverb(1.2, -12) },
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.3,
			speed = r(0.36, 0.46),
			region = r(0.01, 0.04),
			looped = true,
			duration = 0.8,
			glide = glide(1.35, 0.7),
			envelope = env(0.08, nil, 0.3),
			effects = { tremolo(9, 0.6), flanger(0.6, 0.6, 0.4), eq(-6, 6, -8) },
		},
		{
			sample = "GetUp",
			volume = 0.3,
			speed = r(0.5, 0.6),
			region = r(0, 0.35),
			effects = { eq(2, 0, -12) },
		},
		{
			sample = "Falling",
			volume = 0.12,
			speed = r(0.7, 0.8),
			region = r(0.2, 1),
			duration = 0.7,
			envelope = env(0.2, nil, 0.3),
			effects = { eq(-10, -2, -12) },
		},
	},
})

-- A vent grate kicked off its frame: the kick, a steel bang, the grate clattering across the floor.
define("MetalCrash", {
	bus = "World",
	priority = 88,
	maxVoices = 2,
	rollOff = r(14, 260),
	duck = { duck("Ambience", 0.5, 0.01, 0.5, 0.9) },
	layers = {
		{
			sample = "FootstepsPlastic",
			volume = 1.8,
			speed = 0.6,
			region = r(0, 0.18),
			effects = { distortion(0.55), eq(4, 6, 0), compressor(-18, 10, 0.001, 0.15, 6) },
		},
		{
			sample = "VolumeSlider",
			volume = 1.3,
			speed = 0.38,
			effects = { flanger(0.3, 0.8, 0.6), distortion(0.45), echo(0.06, 0.5, -2), reverb(1.8, -6) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.7,
			speed = r(1.1, 1.6),
			region = r(0, 0.3),
			regionJitter = 0.05,
			delay = 0.12,
			grains = grains(5, 8, 0.04, 0.1),
			volumeJitter = 0.3,
			effects = { flanger(1.2, 0.6, 0.5), eq(-8, 4, 2) },
		},
		{ sample = "Explosion", volume = 0.8, speed = 1.6, region = r(0, 0.4), effects = { eq(2, 0, -6) } },
		{
			sample = "VolumeSlider",
			volume = 0.4,
			speed = r(0.8, 1.2),
			delay = 0.35,
			grains = grains(4, 7, 0.05, 0.14),
			volumeJitter = 0.4,
			effects = { echo(0.05, 0.4, -6), eq(-12, 2, 0) },
		},
	},
})

-- Unscrewing a grate quietly (looped until the channel ends): a rising screw squeal in rhythmic turns.
define("Unscrew", {
	bus = "World",
	priority = 30,
	maxVoices = 4,
	rollOff = r(4, 40),
	looped = true,
	["repeat"] = pulse(0.42, 0.08),
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.55,
			speed = r(0.55, 0.7),
			glide = glide(1.25, 0.25),
			effects = { flanger(6, 0.4, 0.5), distortion(0.2), eq(-10, 4, -2) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.3,
			speed = r(0.9, 1.2),
			region = r(0, 0.2),
			regionJitter = 0.05,
			grains = grains(2, 3, 0.05, 0.1),
			effects = { eq(-20, 2, 4) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.25,
			speed = 2.2,
			delay = 0.2,
			chance = 0.25,
			effects = { eq(-30, 0, 4), echo(0.03, 0.3, -10) },
		},
	},
})

-- A light fixture bursting: the pop, glass tinkle, an electrical zap, the thump.
define("LightBurst", {
	bus = "World",
	priority = 78,
	maxVoices = 3,
	rollOff = r(8, 150),
	caption = "Caption.LightBurst",
	layers = {
		{
			sample = "FootstepsPlastic",
			volume = 1.4,
			speed = 2.4,
			region = r(0, 0.12),
			effects = { distortion(0.85), eq(-10, 4, 8) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.6,
			speed = r(3, 4.5),
			delay = 0.04,
			grains = grains(4, 7, 0.035, 0.08),
			volumeJitter = 0.4,
			effects = { eq(-40, -4, 6), echo(0.017, 0.4, -7) },
		},
		{
			sample = "Falling",
			volume = 0.7,
			speed = 2.8,
			region = r(0.1, 0.6),
			duration = 0.35,
			envelope = env(0.004, 0.08, 0.22),
			effects = { distortion(0.95), tremolo(20, 1, 0.35), eq(-24, 0, 4) },
		},
		{ sample = "Explosion", volume = 0.6, speed = 1.8, region = r(0, 0.3), effects = { eq(0, 0, -6) } },
	},
})

define("LockerDoor", {
	bus = "World",
	priority = 45,
	maxVoices = 4,
	rollOff = r(6, 90),
	layers = {
		{
			sample = "FootstepsPlastic",
			volume = 1,
			speed = r(0.66, 0.74),
			region = r(0, 0.2),
			effects = { flanger(0.5, 0.6, 0.5), eq(-2, 6, -2) },
		},
		{ sample = "VolumeSlider", volume = 0.5, speed = r(0.48, 0.55), effects = { reverb(0.9, -10) } },
		{ sample = "JumpLand", volume = 0.8, speed = 0.8, delay = 0.03, effects = { eq(4, -2, -12) } },
	},
})

---------------------------------------------------------------- lockers and the gym (P7)

-- The Creature breathing in at the locker slits: a long, wet, snuffling draw through the vents (the wind loop slowed
-- into the nasal band, chopped by a slow tremolo into sniffs), a held beat, then a rattling exhale through bared teeth
-- (slowed further, torn by distortion) and now and then a wet click of the jaw. Close and dry: it is inches away.
define("CreatureSniff", {
	bus = "Monster",
	priority = 82,
	maxVoices = 2,
	rollOff = r(4, 46),
	caption = "Caption.CreatureSniff",
	looped = true,
	["repeat"] = pulse(2.25, 0.35),
	layers = {
		{
			sample = "Falling",
			volume = 1,
			speed = r(0.62, 0.7),
			region = r(0.2, 1),
			looped = true,
			duration = 0.95,
			envelope = env(0.3, 0.35, 0.3),
			effects = { eq(-14, 6, -4), tremolo(7.5, 0.7, 0.45), echo(0.03, 0.2, -10) },
		},
		{
			sample = "Falling",
			volume = 1.1,
			speed = r(0.46, 0.52),
			region = r(0.1, 1.1),
			delay = 1.2,
			looped = true,
			duration = 0.85,
			envelope = env(0.08, 0.25, 0.5),
			effects = { eq(-6, 3, -14), distortion(0.35), tremolo(16, 0.35, 0.5) },
		},
		{
			sample = "Oof",
			volume = 0.4,
			speed = r(0.3, 0.36),
			delay = 1.18,
			chance = 0.45,
			envelope = env(0.06, nil, 0.4),
			effects = { pitch(0.6), distortion(0.5), eq(4, -2, -18) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.25,
			speed = r(2.2, 2.8),
			region = r(0, 0.03),
			delay = 2,
			chance = 0.35,
			effects = { eq(-20, 4, -4) },
		},
	},
})

-- Letting a held breath go, quietly: a slow, shaking exhale through the nose (the wind loop low and narrow, a 7 Hz
-- tremble in it), right inside your head.
define("BreathExhale", {
	bus = "Body",
	priority = 50,
	maxVoices = 1,
	layers = {
		{
			sample = "Falling",
			volume = 0.45,
			speed = r(0.82, 0.9),
			region = r(0.2, 1),
			looped = true,
			duration = 1.3,
			envelope = env(0.12, 0.45, 0.7),
			effects = { eq(-24, 0, -10), tremolo(7, 0.4, 0.5) },
		},
		{
			sample = "GetUp",
			volume = 0.12,
			speed = r(1.2, 1.4),
			region = r(0, 0.1),
			delay = 0.9,
			chance = 0.5,
			effects = { eq(-16, 2, -8) },
		},
	},
})

-- A locker door torn off its hinge: the sheet buckling with a long shriek of steel (the slider ring slowed, gliding
-- down, flanged and torn), the hinge pins snapping, then the door crashing flat onto the tiles a beat later.
define("LockerRip", {
	bus = "World",
	priority = 92,
	maxVoices = 2,
	rollOff = r(14, 220),
	caption = "Caption.LockerRip",
	duck = { duck("Ambience", 0.35, 0.01, 0.8, 1.2) },
	layers = {
		{
			sample = "VolumeSlider",
			volume = 1.2,
			speed = 0.5,
			region = r(0.01, 0.05),
			looped = true,
			duration = 0.5,
			glide = glide(0.55, 0.45),
			envelope = env(0.01, nil, 0.25),
			effects = { flanger(1.1, 0.8, 0.6), distortion(0.7), eq(-6, 6, 0) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 1.6,
			speed = r(0.7, 0.8),
			region = r(0, 0.12),
			delay = 0.16,
			grains = grains(2, 3, 0.04, 0.07),
			effects = { distortion(0.6), eq(2, 6, 4), compressor(-18, 10, 0.001, 0.15, 6) },
		},
		{
			sample = "JumpLand",
			volume = 1.4,
			speed = 0.62,
			delay = 0.52,
			effects = { eq(8, -2, -16) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 1.3,
			speed = r(0.48, 0.55),
			region = r(0, 0.18),
			delay = 0.52,
			effects = { distortion(0.5), echo(0.017, 0.7, -4), reverb(1.6, -6) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.6,
			speed = r(0.34, 0.4),
			delay = 0.55,
			effects = { echo(0.021, 0.75, -4), eq(-8, 6, -8) },
		},
	},
})

-- A locker door banging shut somewhere in the changing rooms: the slam of thin steel on its frame, the sheet ringing
-- through a tight comb echo, the latch rattling after it, all thrown off bare tile.
define("LockerSlam", {
	bus = "World",
	priority = 42,
	maxVoices = 2,
	rollOff = r(10, 150),
	caption = "Caption.LockerSlam",
	space = { reverb(1.9, -5) },
	layers = {
		{
			sample = "FootstepsPlastic",
			volume = 1.5,
			speed = r(0.52, 0.6),
			region = r(0, 0.14),
			effects = { distortion(0.45), eq(4, 6, -6), compressor(-18, 10, 0.001, 0.15, 6) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.9,
			speed = r(0.36, 0.42),
			effects = { echo(0.013, 0.72, -4), flanger(0.4, 0.5, 0.35), eq(-8, 6, -6) },
		},
		{ sample = "JumpLand", volume = 0.8, speed = 0.7, effects = { eq(6, -4, -18) } },
		{
			sample = "FootstepsPlastic",
			volume = 0.4,
			speed = r(1.3, 1.7),
			region = r(0, 0.2),
			regionJitter = 0.05,
			delay = 0.09,
			grains = grains(3, 5, 0.035, 0.07),
			volumeJitter = 0.35,
			effects = { flanger(1.5, 0.5, 0.4), eq(-10, 4, 0) },
		},
	},
})

-- One bounce of a basketball on the gym's wooden floor, far off: the hollow rubber thump (the landing thump at a
-- higher pitch, its body boosted), the faint ping of the inflated ball, and the hall's long tail under it.
define("BallBounce", {
	bus = "World",
	priority = 30,
	maxVoices = 3,
	rollOff = r(12, 200),
	caption = "Caption.BallBounce",
	space = { reverb(5.5, -2, -4) },
	layers = {
		{
			sample = "JumpLand",
			volume = 1.3,
			speed = r(0.95, 1.05),
			effects = { eq(6, 4, -14), compressor(-20, 6, 0.002, 0.12, 4) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.22,
			speed = r(0.62, 0.7),
			region = r(0.02, 0.026),
			looped = true,
			duration = 0.09,
			envelope = env(0.002, 0.02, 0.06),
			effects = { eq(-20, 6, -10) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.35,
			speed = r(0.72, 0.8),
			region = r(0, 0.08),
			effects = { eq(2, 2, -12) },
		},
	},
})

-- A showerhead dripping onto tile: a heavy drop's plink and splat with the tiled room ringing after it.
define("ShowerDrip", {
	bus = "World",
	priority = 16,
	maxVoices = 3,
	rollOff = r(4, 70),
	space = { reverb(2.4, -4) },
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.55,
			speed = r(2, 2.7),
			region = r(0.03, 0.035),
			looped = true,
			duration = 0.08,
			volumeJitter = 0.3,
			envelope = env(0.001, 0.012, 0.055),
			glide = glide(1.35, 0.05),
			effects = { eq(-30, -2, 4), echo(0.09, 0.35, -10) },
		},
		{
			sample = "WaterImpact",
			volume = 0.3,
			speed = r(2.2, 2.9),
			region = r(0, 0.1),
			regionJitter = 0.02,
			volumeJitter = 0.3,
			envelope = env(0.001, 0.04, 0.05),
			effects = { eq(-24, 0, 4) },
		},
	},
})

define("Splash", {
	bus = "World",
	priority = 60,
	maxVoices = 4,
	rollOff = r(6, 160),
	caption = "Caption.Splash",
	layers = {
		{ sample = "WaterImpact", volume = 1.3, speed = r(0.85, 1.1), effects = { eq(2, 0, -2) } },
		{ sample = "Swim", volume = 0.8, speed = r(0.9, 1.15), delay = 0.05 },
		{
			sample = "WaterImpact",
			volume = 0.35,
			speed = r(2.2, 3),
			region = r(0.05, 0.2),
			regionJitter = 0.03,
			delay = 0.15,
			grains = grains(3, 5, 0.05, 0.12),
			volumeJitter = 0.4,
			effects = { eq(-20, 0, 3) },
		},
		{ sample = "JumpLand", volume = 0.6, speed = 0.6, effects = { eq(6, -6, -20) } },
	},
})

-- A heavy drop from the natatorium's roof into the water (P7 pool beat): the drop's ping, the plunk, the hall.
define("PoolDrip", {
	bus = "World",
	priority = 16,
	maxVoices = 3,
	rollOff = r(6, 90),
	caption = "Caption.PoolDrip",
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.6,
			speed = r(1.6, 2.1),
			region = r(0.03, 0.035),
			looped = true,
			duration = 0.09,
			envelope = env(0.001, 0.015, 0.07),
			glide = glide(1.4, 0.05),
			effects = { eq(-24, 0, 2), echo(0.24, 0.35, -10) },
		},
		{
			sample = "WaterImpact",
			volume = 0.35,
			speed = r(1.7, 2.2),
			region = r(0, 0.12),
			regionJitter = 0.02,
			envelope = env(0.001, 0.05, 0.08),
			effects = { eq(-12, 0, -2), reverb(2.6, -6) },
		},
	},
})

-- Something stirring the water far off (P7 pool beat): a slow, heavy slosh against the tiles and its swell after.
define("WaterSlosh", {
	bus = "World",
	priority = 20,
	maxVoices = 2,
	rollOff = r(8, 110),
	caption = "Caption.WaterSlosh",
	layers = {
		{
			sample = "Swim",
			volume = 0.8,
			speed = r(0.45, 0.6),
			region = r(0.05, 0.75),
			regionJitter = 0.04,
			envelope = env(0.15, 0.4, 0.5),
			effects = { eq(4, -4, -16), reverb(2.4, -5) },
		},
		{
			sample = "WaterImpact",
			volume = 0.3,
			speed = r(0.5, 0.65),
			region = r(0.1, 0.6),
			delay = 0.35,
			envelope = env(0.1, 0.2, 0.4),
			effects = { eq(6, -6, -20) },
		},
	},
})

-- A loose tile dropping into the pool (P7 pool beat): the clack off the coping, its ceramic ring, the plop.
define("TileFall", {
	bus = "World",
	priority = 30,
	maxVoices = 2,
	rollOff = r(8, 120),
	caption = "Caption.TileFall",
	layers = {
		{
			sample = "FootstepsPlastic",
			volume = 0.9,
			speed = r(1.4, 1.7),
			region = r(0, 0.2),
			effects = { eq(-10, 2, 4), echo(0.18, 0.3, -8) },
		},
		{ sample = "VolumeSlider", volume = 0.25, speed = r(0.7, 0.9), delay = 0.02, effects = { reverb(1.6, -10) } },
		{
			sample = "WaterImpact",
			volume = 0.6,
			speed = r(1.2, 1.5),
			region = r(0, 0.3),
			delay = 0.38,
			delayJitter = 0.08,
			effects = { eq(-4, 0, -4), reverb(2.2, -7) },
		},
	},
})

-- The emergency floodlight breaker thrown (P7): the heavy clank of the lever, its steel ringing, contacts arcing.
define("FloodlightBreaker", {
	bus = "World",
	priority = 70,
	maxVoices = 2,
	rollOff = r(8, 140),
	caption = "Caption.FloodlightBreaker",
	layers = {
		{ sample = "JumpLand", volume = 1.4, speed = r(0.55, 0.65), effects = { eq(6, 0, -6), distortion(0.2) } },
		{
			sample = "VolumeSlider",
			volume = 0.6,
			speed = r(0.42, 0.48),
			delay = 0.01,
			effects = { distortion(0.3), reverb(1.2, -8) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.7,
			speed = 2.6,
			region = r(0, 0.25),
			delay = 0.06,
			grains = grains(3, 5, 0.03, 0.06),
			effects = { distortion(0.6), eq(-20, 2, 6), echo(0.012, 0.4, -8) },
		},
	},
})

-- The pool floodlights striking up under the roof (P7): the ballasts' hum swelling, arcs catching, relays clunking
-- down the line, all in the natatorium's hall.
define("FloodlightStrike", {
	bus = "World",
	priority = 60,
	maxVoices = 2,
	rollOff = r(20, 220),
	caption = "Caption.Floodlights",
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.35,
			speed = 1,
			region = r(0.02, 0.0283),
			looped = true,
			duration = 2.4,
			envelope = env(0.6, 1.2, 0.6),
			glide = glide(1.08, 1.5),
			effects = { distortion(0.7), tremolo(14, 0.6, 0.5), eq(-12, 4, -6) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.55,
			speed = r(2.6, 3.2),
			region = r(0, 0.25),
			regionJitter = 0.05,
			grains = grains(4, 8, 0.05, 0.16),
			effects = { distortion(0.8), eq(-24, 2, 6), echo(0.012, 0.35, -8) },
		},
		{
			sample = "JumpLand",
			volume = 0.7,
			speed = r(0.6, 0.7),
			delay = 0.15,
			grains = grains(3, 5, 0.09, 0.14),
			effects = { eq(4, -2, -8), reverb(3, -6) },
		},
	},
})

---------------------------------------------------------------- the roof finale (P8)

-- The wind slamming the roof stairwell door shut behind the squad: a gust rushing through the frame, the steel slab
-- hitting the jamb with a crack, the whole door ringing.
define("RoofDoorSlam", {
	bus = "World",
	priority = 80,
	maxVoices = 2,
	rollOff = r(20, 260),
	caption = "Caption.RoofDoorSlam",
	layers = {
		{
			sample = "Falling",
			volume = 0.7,
			speed = 1.6,
			region = r(0.1, 0.9),
			duration = 0.5,
			envelope = env(0.05, nil, 0.3),
			glide = glide(0.7, 0.45),
			effects = { eq(-6, 0, 2) },
		},
		{
			sample = "JumpLand",
			volume = 1.7,
			speed = r(0.48, 0.54),
			delay = 0.12,
			effects = { distortion(0.3), eq(8, 0, -10), compressor(-18, 8, 0.002, 0.25, 5) },
		},
		{
			sample = "Explosion",
			volume = 0.9,
			speed = r(0.9, 1),
			region = r(0, 0.35),
			delay = 0.12,
			effects = { eq(4, 0, -6) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.5,
			speed = 0.35,
			delay = 0.13,
			effects = { eq(-6, 2, -4), reverb(1.6, -6) },
		},
	},
})

-- Something hammering on the far side of a steel door in a concrete stairwell: a dull, distorted blow, the slab
-- booming in its frame, the frame rattling.
define("DoorPound", {
	bus = "World",
	priority = 85,
	maxVoices = 3,
	rollOff = r(18, 220),
	caption = "Caption.DoorPound",
	layers = {
		{
			sample = "JumpLand",
			volume = 1.8,
			speed = r(0.42, 0.5),
			effects = { distortion(0.45), eq(9, -2, -14), compressor(-20, 8, 0.002, 0.3, 6) },
		},
		{
			sample = "Explosion",
			volume = 0.7,
			speed = r(0.55, 0.65),
			region = r(0, 0.4),
			effects = { eq(6, -4, -20) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.35,
			speed = r(0.3, 0.34),
			delay = 0.005,
			effects = { eq(-8, 0, -6), reverb(2.2, -8) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.5,
			speed = 0.7,
			region = r(0, 0.3),
			regionJitter = 0.05,
			delay = 0.02,
			grains = grains(2, 3, 0.03, 0.05),
			effects = { distortion(0.5), eq(0, 2, -6) },
		},
	},
})

-- Freefall (2D, the jumper's own ears): the wind roaring past, a lower buffeting under it, gusts slapping the hood.
define("WindRush", {
	bus = "Body",
	priority = 80,
	maxVoices = 1,
	looped = true,
	["repeat"] = pulse(0.24, 0.12),
	layers = {
		{
			sample = "Falling",
			volume = 1,
			speed = 1.15,
			looped = true,
			envelope = env(0.25, nil, 0.6),
			effects = { eq(-2, 0, 4) },
		},
		{
			sample = "Falling",
			volume = 0.7,
			speed = 0.62,
			looped = true,
			envelope = env(0.4, nil, 0.6),
			effects = { eq(6, -4, -10), tremolo(7, 0.25, 0.5) },
		},
		{
			sample = "Jump",
			volume = 0.45,
			speed = r(0.6, 0.9),
			regionJitter = 0.04,
			volumeJitter = 0.4,
			effects = { eq(4, 0, -6) },
		},
	},
})

-- The canopy coming out: fabric rushing off the pack, the cells filling with a crack, the opening shock knocking the
-- breath out of the jumper.
define("CanopyDeploy", {
	bus = "Player",
	priority = 85,
	maxVoices = 3,
	rollOff = r(8, 160),
	caption = "Caption.CanopyDeploy",
	layers = {
		{
			sample = "Falling",
			volume = 0.9,
			speed = 2,
			region = r(0.1, 0.6),
			duration = 0.45,
			envelope = env(0.01, nil, 0.25),
			glide = glide(0.6, 0.4),
			effects = { eq(-4, 2, 4) },
		},
		{
			sample = "GetUp",
			volume = 1,
			speed = r(0.8, 1),
			region = r(0, 0.4),
			grains = grains(2, 3, 0.04, 0.07),
			effects = { eq(2, 2, 0) },
		},
		{
			sample = "JumpLand",
			volume = 1.6,
			speed = 0.7,
			delay = 0.38,
			effects = { distortion(0.25), eq(6, 2, -4) },
		},
		{
			sample = "Explosion",
			volume = 0.5,
			speed = 1.6,
			region = r(0, 0.12),
			delay = 0.38,
			effects = { eq(-4, 4, 2) },
		},
		{ sample = "Jump", volume = 0.7, speed = r(0.62, 0.7), delay = 0.42, effects = { eq(2, 0, -6) } },
	},
})

-- Under the canopy (2D): the cells fluttering in the gusts, the wind singing in the lines, the fabric luffing.
define("CanopyFlutter", {
	bus = "Body",
	priority = 50,
	maxVoices = 1,
	looped = true,
	["repeat"] = pulse(0.7, 0.4),
	layers = {
		{
			sample = "Falling",
			volume = 0.5,
			speed = 0.8,
			looped = true,
			envelope = env(0.6, nil, 1),
			effects = { eq(-2, -2, -8), tremolo(9, 0.35, 0.5) },
		},
		{
			sample = "Falling",
			volume = 0.3,
			speed = 1.3,
			looped = true,
			envelope = env(1, nil, 1),
			effects = { eq(-12, 0, 2), chorus(0.8, 0.5, 0.4) },
		},
		{
			sample = "GetUp",
			volume = 0.35,
			speed = r(0.7, 1.1),
			region = r(0, 0.4),
			regionJitter = 0.05,
			volumeJitter = 0.4,
			effects = { eq(0, 0, -4) },
		},
	},
})

-- Feet first into the dead grass under a full canopy: a soft thump, the harness and buckles jingling, grass flattening.
define("ParachuteLanding", {
	bus = "Player",
	priority = 60,
	maxVoices = 3,
	rollOff = r(6, 90),
	layers = {
		{ sample = "JumpLand", volume = 1.2, speed = 0.8, effects = { eq(4, 0, -4) } },
		{ sample = "GetUp", volume = 0.9, speed = r(0.9, 1.1), region = r(0, 0.4), delay = 0.03 },
		{
			sample = "FootstepsPlastic",
			volume = 0.4,
			speed = 0.6,
			region = r(0, 0.3),
			delay = 0.05,
			grains = grains(2, 4, 0.05, 0.09),
			effects = { eq(-4, 0, -8) },
		},
		{ sample = "VolumeSlider", volume = 0.25, speed = 1.3, delay = 0.08, effects = { eq(-10, 0, 0) } },
	},
})

-- A late, half-open canopy: the body slamming into the ground, the breath punched out, a roll through the grass.
define("HardLanding", {
	bus = "Player",
	priority = 75,
	maxVoices = 3,
	rollOff = r(8, 120),
	caption = "Caption.HardLanding",
	layers = {
		{
			sample = "JumpLand",
			volume = 2,
			speed = 0.55,
			effects = { distortion(0.35), eq(8, 0, -8), compressor(-18, 10, 0.002, 0.25, 6) },
		},
		{ sample = "Explosion", volume = 0.6, speed = 1.1, region = r(0, 0.25), effects = { eq(4, 0, -10) } },
		{
			sample = "Oof",
			volume = 1.1,
			speed = r(0.58, 0.66),
			delay = 0.06,
			effects = { distortion(0.25), eq(4, 2, -6) },
		},
		{ sample = "GetUp", volume = 0.8, speed = 0.7, region = r(0, 0.4), delay = 0.1 },
	},
})

-- Shrugging into a parachute harness: straps dragged over the shoulders, two buckles clicking home.
define("PackBuckle", {
	bus = "Player",
	priority = 45,
	maxVoices = 3,
	rollOff = r(6, 60),
	layers = {
		{ sample = "GetUp", volume = 0.7, speed = 1.2, region = r(0, 0.35) },
		{ sample = "VolumeSlider", volume = 0.5, speed = 1.8, delay = 0.22, effects = { eq(-10, 0, 2) } },
		{
			sample = "FootstepsPlastic",
			volume = 0.3,
			speed = 2.4,
			region = r(0, 0.2),
			delay = 0.24,
			effects = { eq(-12, 0, 4) },
		},
		{ sample = "VolumeSlider", volume = 0.45, speed = 2.2, delay = 0.3, effects = { eq(-10, 0, 3) } },
	},
})

-- The finale's reveal (2D): a sub-bass swell rising out of nothing, a low hum souring under it, a glassy shiver on
-- top and a long breath of wind, while the world around it drops away.
define("FinaleSting", {
	bus = "Ambience",
	priority = 90,
	maxVoices = 1,
	caption = "Caption.FinaleSting",
	duck = { duck("World", 0.5, 0.3, 2.5, 2) },
	layers = {
		{
			sample = "Explosion",
			volume = 1.1,
			speed = r(0.12, 0.14),
			region = r(0.2, 1.8),
			envelope = env(0.4, nil, 2.2),
			effects = { eq(8, -10, -40), tremolo(0.8, 0.3, 0.5) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.3,
			speed = 0.5,
			region = r(0.02, 0.0283),
			looped = true,
			duration = 3,
			envelope = env(1.2, nil, 1.5),
			glide = glide(0.94, 2.6),
			effects = { flanger(0.3, 0.6, 0.5), distortion(0.3), reverb(4, -6) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.15,
			speed = 1.6,
			region = r(0.02, 0.025),
			looped = true,
			duration = 2.6,
			envelope = env(1.5, nil, 1.2),
			effects = { chorus(1.4, 0.6, 0.5), tremolo(6, 0.4, 0.5) },
		},
		{
			sample = "Falling",
			volume = 0.4,
			speed = 0.5,
			region = r(0.1, 1.1),
			duration = 2.5,
			envelope = env(0.8, nil, 1.6),
			effects = { eq(-6, -4, -12) },
		},
	},
})

---------------------------------------------------------------- weather

-- Thunder (2D): a close crack some of the time, the main rolling rumble, and a far second roll, all rolling around
-- one huge open-air space.
define("Thunder", {
	bus = "Ambience",
	priority = 70,
	maxVoices = 2,
	caption = "Caption.Thunder",
	space = { reverb(9.5, -3) },
	layers = {
		{
			sample = "Explosion",
			volume = 1.3,
			speed = r(0.8, 0.95),
			region = r(0, 0.5),
			chance = 0.6,
			effects = { distortion(0.35), eq(2, 2, -2) },
		},
		{
			sample = "Explosion",
			volume = 1.6,
			speed = r(0.26, 0.32),
			region = r(0.1, 1.8),
			delay = 0.15,
			delayJitter = 0.1,
			effects = { eq(6, -6, -24), tremolo(2.2, 0.35, 0.5) },
		},
		{
			sample = "Explosion",
			volume = 1,
			speed = r(0.18, 0.22),
			region = r(0.4, 1.8),
			delay = 0.9,
			delayJitter = 0.3,
			effects = { eq(6, -10, -40), tremolo(1.1, 0.5, 0.5) },
		},
		{
			sample = "Falling",
			volume = 0.4,
			speed = 0.7,
			region = r(0.1, 1.1),
			delay = 0.2,
			looped = true,
			duration = 3,
			envelope = env(0.5, nil, 2.2),
			effects = { eq(-4, -6, -16) },
		},
	},
})

define("DistantThunder", {
	bus = "Ambience",
	priority = 30,
	maxVoices = 2,
	space = { reverb(11, -5) },
	layers = {
		{
			sample = "Explosion",
			volume = 0.9,
			speed = r(0.2, 0.26),
			region = r(0.1, 1.8),
			effects = { eq(6, -10, -40), tremolo(1.4, 0.5, 0.5) },
		},
		{
			sample = "Explosion",
			volume = 0.6,
			speed = 0.16,
			region = r(0.3, 1.8),
			delay = 0.6,
			delayJitter = 0.4,
			effects = { eq(6, -14, -50) },
		},
	},
})

define("Rain", {
	bus = "Ambience",
	priority = 12,
	maxVoices = 1,
	looped = true,
	["repeat"] = pulse(0.35, 0.15),
	layers = {
		{
			sample = "Swim",
			volume = 0.6,
			speed = 1.9,
			looped = true,
			envelope = env(2, nil, 2),
			effects = { eq(-18, -2, 3), chorus(0.6, 0.5, 0.4) },
		},
		{
			sample = "Falling",
			volume = 0.35,
			speed = 0.9,
			looped = true,
			envelope = env(2, nil, 2),
			effects = { eq(-8, -2, -6), tremolo(0.2, 0.4, 0.5) },
		},
		{
			sample = "WaterImpact",
			volume = 0.3,
			speed = r(2.4, 3.2),
			region = r(0, 0.15),
			regionJitter = 0.05,
			grains = grains(3, 6, 0.03, 0.12),
			volumeJitter = 0.5,
			effects = { eq(-24, -2, 4) },
		},
	},
})

---------------------------------------------------------------- ambience beds (2D, looped, Ambience bus)
--
-- Every bed is built from whole-file loops of the engine's own seamless loops (the falling-wind and swim files),
-- slowed into rumbles and filtered, so nothing in a bed ever restarts on a seam. Two copies of the same file run at
-- different speeds and start points so they beat slowly against each other and their loop points never line up.
-- Movement comes from very slow chorus / flanger / tremolo; one shared reverb per bed (space) is the room. The
-- explosion never loops: it is only heard as a sparse far rumble (FarRumble, a bed stinger).

-- Basement: the building's weight as a subsonic rumble, a second detuned throat beating under it, stale air
-- through the boiler room, water shifting in old pipes; a long concrete room.
define("DroneBasement", {
	bus = "Ambience",
	priority = 10,
	maxVoices = 2,
	looped = true,
	space = { reverb(7, -5, 0, 1, 0.9) },
	layers = {
		{
			sample = "Falling",
			volume = 0.95,
			speed = 0.23,
			looped = true,
			envelope = env(3, nil, 3),
			effects = { eq(6, -8, -34), chorus(0.07, 0.5, 0.4), tremolo(0.11, 0.35, 0.5) },
		},
		{
			sample = "Falling",
			volume = 0.6,
			speed = 0.29,
			timePosition = 0.55,
			looped = true,
			envelope = env(4, nil, 3),
			effects = { eq(4, -10, -40), flanger(0.05, 0.55, 0.35) },
		},
		{
			sample = "Falling",
			volume = 0.22,
			speed = 0.62,
			timePosition = 0.3,
			looped = true,
			envelope = env(5, nil, 3),
			effects = { eq(-12, -2, -14), tremolo(0.07, 0.6, 0.5) },
		},
		{
			sample = "Swim",
			volume = 0.14,
			speed = 0.38,
			looped = true,
			envelope = env(4, nil, 3),
			effects = { eq(4, -8, -30), chorus(0.2, 0.5, 0.5) },
		},
	},
})

-- Hallways: wind moaning down long broken corridors, a thinner draught above it, the deep body, a dying mains hum.
define("DroneHallways", {
	bus = "Ambience",
	priority = 10,
	maxVoices = 2,
	looped = true,
	space = { reverb(5, -6) },
	layers = {
		{
			sample = "Falling",
			volume = 0.7,
			speed = 0.42,
			looped = true,
			envelope = env(3, nil, 3),
			effects = { flanger(0.06, 0.7, 0.45), eq(-2, 0, -16), tremolo(0.12, 0.4, 0.5) },
		},
		{
			sample = "Falling",
			volume = 0.4,
			speed = 0.57,
			timePosition = 0.4,
			looped = true,
			envelope = env(4, nil, 3),
			effects = { eq(-10, -2, -10), chorus(0.15, 0.6, 0.5) },
		},
		{
			sample = "Falling",
			volume = 0.55,
			speed = 0.24,
			timePosition = 0.8,
			looped = true,
			envelope = env(3, nil, 3),
			effects = { eq(5, -8, -34), tremolo(0.09, 0.4, 0.5) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.05,
			speed = 1.2,
			region = r(0.02, 0.03),
			looped = true,
			envelope = env(5, nil, 3),
			effects = { distortion(0.5), eq(-30, 0, -20), tremolo(0.4, 0.6, 0.5) },
		},
	},
})

-- Science hall: an eerie chorused air, bubbling in forgotten tanks, the deep body, a gas leak swelling and fading.
define("DroneScience", {
	bus = "Ambience",
	priority = 10,
	maxVoices = 2,
	looped = true,
	space = { reverb(5, -6) },
	layers = {
		{
			sample = "Falling",
			volume = 0.45,
			speed = 0.58,
			looped = true,
			envelope = env(3, nil, 3),
			effects = { chorus(0.25, 0.7, 0.6), eq(-8, 2, -12), tremolo(0.15, 0.3, 0.5) },
		},
		{
			sample = "Swim",
			volume = 0.22,
			speed = 0.35,
			looped = true,
			envelope = env(4, nil, 3),
			effects = { flanger(0.3, 0.6, 0.5), eq(2, -4, -20) },
		},
		{
			sample = "Falling",
			volume = 0.6,
			speed = 0.25,
			timePosition = 0.6,
			looped = true,
			envelope = env(3, nil, 3),
			effects = { eq(5, -8, -34), chorus(0.05, 0.4, 0.3) },
		},
		{
			sample = "Falling",
			volume = 0.12,
			speed = 2.2,
			looped = true,
			envelope = env(5, nil, 3),
			effects = { eq(-40, -10, 0), tremolo(0.06, 0.8, 0.3) },
		},
	},
})

-- Gymnasium: a vast, slow hall; the deep body stretched under a twelve-second room, air moving high in the rafters.
define("DroneGym", {
	bus = "Ambience",
	priority = 10,
	maxVoices = 2,
	looped = true,
	space = { reverb(12, -3, -2) },
	layers = {
		{
			sample = "Falling",
			volume = 0.85,
			speed = 0.2,
			looped = true,
			envelope = env(3, nil, 3),
			effects = { eq(6, -6, -36), tremolo(0.07, 0.4, 0.5) },
		},
		{
			sample = "Falling",
			volume = 0.5,
			speed = 0.38,
			timePosition = 0.5,
			looped = true,
			envelope = env(3, nil, 3),
			effects = { flanger(0.04, 0.8, 0.4), eq(0, -4, -20) },
		},
		{
			sample = "Falling",
			volume = 0.2,
			speed = 0.9,
			timePosition = 0.2,
			looped = true,
			envelope = env(5, nil, 3),
			effects = { eq(-16, -4, -6), tremolo(0.05, 0.7, 0.5) },
		},
	},
})

-- Flooded pool: water lapping the tiles (two staggered copies of the swim loop, so one always covers the other's
-- seam), the deep body, damp air; a wet tiled hall.
define("DronePool", {
	bus = "Ambience",
	priority = 10,
	maxVoices = 2,
	looped = true,
	space = { reverb(9, -4) },
	layers = {
		{
			sample = "Swim",
			volume = 0.45,
			speed = 0.5,
			looped = true,
			envelope = env(3, nil, 3),
			effects = { eq(2, -2, -12), chorus(0.1, 0.5, 0.4) },
		},
		{
			sample = "Swim",
			volume = 0.3,
			speed = 0.38,
			timePosition = 0.4,
			looped = true,
			envelope = env(4, nil, 3),
			effects = { eq(4, -6, -20), tremolo(0.11, 0.5, 0.5) },
		},
		{
			sample = "Falling",
			volume = 0.55,
			speed = 0.22,
			looped = true,
			envelope = env(3, nil, 3),
			effects = { eq(5, -8, -36), chorus(0.04, 0.4, 0.3) },
		},
		{
			sample = "Falling",
			volume = 0.15,
			speed = 0.5,
			timePosition = 0.7,
			looped = true,
			envelope = env(4, nil, 3),
			effects = { eq(-6, -6, -20) },
		},
	},
})

-- Roof: the storm. Gusting wind, rain hiss, patter on the roof, a low rumble under the clouds; dry, it is outdoors.
define("DroneRoof", {
	bus = "Ambience",
	priority = 10,
	maxVoices = 2,
	looped = true,
	["repeat"] = pulse(0.4, 0.2),
	layers = {
		{
			sample = "Falling",
			volume = 0.75,
			speed = 1,
			looped = true,
			envelope = env(2, nil, 3),
			effects = { eq(-4, 0, -4), tremolo(0.28, 0.5, 0.6), flanger(0.05, 0.4, 0.3) },
		},
		{
			sample = "Swim",
			volume = 0.5,
			speed = 1.85,
			looped = true,
			envelope = env(2, nil, 3),
			effects = { eq(-18, -2, 3), chorus(0.6, 0.5, 0.4) },
		},
		{
			sample = "Falling",
			volume = 0.45,
			speed = 0.26,
			timePosition = 0.5,
			looped = true,
			envelope = env(4, nil, 3),
			effects = { eq(6, -10, -40), tremolo(0.06, 0.6, 0.5) },
		},
		-- Patter: a few drops on the roof every pulse.
		{
			sample = "WaterImpact",
			volume = 0.22,
			speed = r(2, 2.6),
			region = r(0, 0.2),
			regionJitter = 0.1,
			grains = grains(2, 4, 0.04, 0.12),
			volumeJitter = 0.5,
			effects = { eq(-24, -2, 4) },
		},
	},
})

-- Lobby (the safe zone): a warm boiler throb, soft air, water moving in the pipes, a faint motor hum. Less
-- dissonant on purpose.
define("DroneLobby", {
	bus = "Ambience",
	priority = 10,
	maxVoices = 2,
	looped = true,
	space = { reverb(2.2, -10) },
	layers = {
		{
			sample = "Falling",
			volume = 0.7,
			speed = 0.3,
			looped = true,
			envelope = env(2, nil, 3),
			effects = { eq(7, -6, -40), tremolo(0.75, 0.25, 0.5) },
		},
		{
			sample = "Falling",
			volume = 0.25,
			speed = 0.5,
			timePosition = 0.4,
			looped = true,
			envelope = env(3, nil, 3),
			effects = { eq(2, -6, -22), chorus(0.2, 0.4, 0.4) },
		},
		{
			sample = "Swim",
			volume = 0.08,
			speed = 0.6,
			looped = true,
			envelope = env(4, nil, 3),
			effects = { eq(0, -6, -18) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.035,
			speed = 0.6,
			region = r(0.02, 0.03),
			looped = true,
			envelope = env(4, nil, 3),
			effects = { distortion(0.3), eq(-12, -2, -24) },
		},
	},
})

-- The building groaning somewhere far below (bed stinger, 2D): the explosion slowed to a crawl and faded in so the
-- blast never reads as a blast, low-passed into a rumble with a slow shudder, dying away in a long reverb.
define("FarRumble", {
	bus = "Ambience",
	priority = 14,
	maxVoices = 2,
	layers = {
		{
			sample = "Explosion",
			volume = 0.75,
			speed = r(0.2, 0.27),
			envelope = env(1.4, nil, 0.5),
			effects = { eq(6, -8, -36), tremolo(0.9, 0.3, 0.5), reverb(8, -5) },
		},
		{
			sample = "Falling",
			volume = 0.3,
			speed = 0.3,
			duration = 4,
			envelope = env(1.5, nil, 2.2),
			effects = { eq(4, -10, -36) },
		},
	},
})

-- Under the pool's surface (2D bed while submerged): everything above is gone, only pressure and bubbles.
define("UnderwaterBed", {
	bus = "Ambience",
	priority = 20,
	maxVoices = 1,
	looped = true,
	["repeat"] = pulse(0.9, 0.5),
	layers = {
		{
			sample = "Swim",
			volume = 0.5,
			speed = 0.3,
			looped = true,
			envelope = env(0.3, nil, 0.6),
			effects = { eq(6, -24, -60), chorus(0.4, 0.5, 0.5) },
		},
		{
			sample = "Falling",
			volume = 0.3,
			speed = 0.2,
			looped = true,
			envelope = env(0.3, nil, 0.6),
			effects = { eq(6, -30, -70) },
		},
		{
			sample = "WaterImpact",
			volume = 0.2,
			speed = r(1.4, 1.9),
			region = r(0.05, 0.3),
			regionJitter = 0.04,
			chance = 0.6,
			grains = grains(1, 3, 0.05, 0.15),
			effects = { eq(4, -18, -50), chorus(2, 0.4, 0.5) },
		},
	},
})

---------------------------------------------------------------- emitters and stingers

-- Fluorescent tube: a 120 Hz loop-region hum (10 ms slice at speed 1.2) plus chopped ballast buzz.
define("FluorescentBuzz", {
	bus = "World",
	priority = 8,
	maxVoices = 6,
	rollOff = r(3, 28),
	looped = true,
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.22,
			speed = 1.2,
			region = r(0.02, 0.03),
			looped = true,
			envelope = env(0.3, nil, 0.3),
			effects = { distortion(0.6), eq(-20, 2, -6), tremolo(0.7, 0.2, 0.5) },
		},
		{
			sample = "Falling",
			volume = 0.12,
			speed = 2.2,
			looped = true,
			envelope = env(0.3, nil, 0.3),
			effects = { tremolo(20, 0.7, 0.4), eq(-40, -6, 2) },
		},
	},
})

-- Boiler (lobby / basement emitters): a throbbing low roar (the wind loop slowed and low-passed, pulsing like a
-- burner), air through the flue, a 60 Hz motor hum, an occasional pipe knock.
define("BoilerHum", {
	bus = "World",
	priority = 10,
	maxVoices = 3,
	rollOff = r(8, 70),
	looped = true,
	["repeat"] = pulse(1.8, 0.3),
	layers = {
		{
			sample = "Falling",
			volume = 0.8,
			speed = 0.28,
			looped = true,
			envelope = env(1, nil, 1),
			effects = { eq(8, -6, -40), tremolo(0.9, 0.3, 0.5) },
		},
		{
			sample = "Falling",
			volume = 0.3,
			speed = 0.4,
			timePosition = 0.5,
			looped = true,
			envelope = env(1, nil, 1),
			effects = { eq(4, -4, -24) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.08,
			speed = 0.6,
			region = r(0.02, 0.03),
			looped = true,
			envelope = env(1, nil, 1),
			effects = { distortion(0.4), eq(-10, -2, -20) },
		},
		{
			sample = "JumpLand",
			volume = 0.35,
			speed = 0.35,
			chance = 0.5,
			effects = { eq(6, -6, -30), reverb(1.5, -10) },
		},
	},
})

-- The building settling: a slowed loop-region tone sagging in pitch under a resonant wind drag, ringing in the
-- concrete around it.
define("MetalCreak", {
	bus = "World",
	priority = 18,
	maxVoices = 3,
	rollOff = r(10, 120),
	space = { reverb(4, -5) },
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.35,
			speed = r(0.22, 0.3),
			region = r(0.01, 0.05),
			looped = true,
			duration = 1.6,
			glide = glide(0.6, 1.4),
			envelope = env(0.3, nil, 0.8),
			effects = { flanger(0.4, 0.8, 0.6), distortion(0.35) },
		},
		{
			sample = "Falling",
			volume = 0.3,
			speed = r(0.36, 0.44),
			region = r(0.1, 1.1),
			duration = 1.4,
			envelope = env(0.4, nil, 0.7),
			effects = { flanger(0.3, 0.7, 0.6), eq(-8, 6, -14) },
		},
	},
})

-- Something far away in the building, groaning: the cry slowed to a moan, sagging, drowned in reverb.
define("DistantGroan", {
	bus = "World",
	priority = 16,
	maxVoices = 2,
	rollOff = r(20, 160),
	space = { reverb(8.5, -2) },
	layers = {
		{
			sample = "Ouch",
			volume = 0.8,
			speed = r(0.3, 0.36),
			region = r(0.05, 0.3),
			looped = true,
			duration = 2.4,
			glide = glide(0.8, 2),
			envelope = env(0.8, nil, 1.2),
			effects = { pitch(0.6), eq(4, -2, -20) },
		},
		{
			sample = "Explosion",
			volume = 0.5,
			speed = 0.22,
			region = r(0.2, 1.5),
			duration = 2.6,
			envelope = env(1, nil, 1.2),
			effects = { eq(4, -8, -30) },
		},
	},
})

---------------------------------------------------------------- scripted level moments (Scenes)

-- A bang somewhere in the overhead pipes: a hard knock, the pipe ringing down its length (a slowed slider tick through
-- a tight comb echo, the tube's mode), the knock's weight, a softer knock answering, the clang travelling away.
define("PipeBang", {
	bus = "World",
	priority = 40,
	maxVoices = 2,
	rollOff = r(10, 140),
	caption = "Caption.PipeBang",
	space = { reverb(2.8, -4) },
	layers = {
		{
			sample = "FootstepsPlastic",
			volume = 1.6,
			speed = r(0.42, 0.5),
			region = r(0, 0.12),
			effects = { distortion(0.6), eq(6, 4, -8), compressor(-18, 10, 0.001, 0.2, 6) },
		},
		{
			sample = "VolumeSlider",
			volume = 1.1,
			speed = r(0.26, 0.32),
			effects = { echo(0.017, 0.78, -3), flanger(0.25, 0.5, 0.35), eq(-8, 6, -10) },
		},
		{ sample = "JumpLand", volume = 0.9, speed = 0.55, effects = { eq(8, -4, -24) } },
		{
			sample = "FootstepsPlastic",
			volume = 0.8,
			speed = r(0.5, 0.58),
			region = r(0, 0.12),
			delay = 0.42,
			delayJitter = 0.12,
			chance = 0.7,
			effects = { distortion(0.5), eq(4, 2, -10), echo(0.017, 0.6, -6) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.45,
			speed = r(0.36, 0.44),
			delay = 0.16,
			grains = grains(2, 4, 0.16, 0.3),
			volumeJitter = 0.4,
			effects = { echo(0.032, 0.5, -8), eq(-14, 2, -12) },
		},
	},
})

-- A boiler surging: the burner coughs and roars up (the wind loop slowed, throbbing and rising), a deep whump in the
-- firebox, steam hissing from a valve, the pipework groaning under the pressure, a knock as it settles.
define("BoilerSurge", {
	bus = "World",
	priority = 44,
	maxVoices = 1,
	rollOff = r(12, 160),
	caption = "Caption.BoilerSurge",
	duck = { duck("Ambience", 0.55, 0.2, 1.2, 1.4) },
	layers = {
		{
			sample = "Falling",
			volume = 1.1,
			speed = 0.3,
			region = r(0.1, 1.1),
			looped = true,
			duration = 2.3,
			envelope = env(0.35, nil, 1.1),
			glide = glide(1.3, 1.1),
			effects = { eq(10, -2, -32), distortion(0.3), tremolo(7.5, 0.5, 0.5) },
		},
		{ sample = "Explosion", volume = 0.9, speed = 0.42, region = r(0, 1.4), effects = { eq(8, -6, -26) } },
		{
			sample = "Falling",
			volume = 0.45,
			speed = r(2.4, 2.8),
			region = r(0.2, 1),
			looped = true,
			duration = 1.4,
			delay = 0.4,
			envelope = env(0.3, 0.4, 0.7),
			effects = { eq(-32, -6, 6) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.2,
			speed = r(0.22, 0.28),
			region = r(0.02, 0.05),
			looped = true,
			duration = 1.7,
			delay = 0.25,
			glide = glide(0.7, 1.5),
			envelope = env(0.4, nil, 0.8),
			effects = { flanger(0.4, 0.8, 0.6), distortion(0.4) },
		},
		{ sample = "JumpLand", volume = 0.6, speed = 0.45, delay = 1.6, effects = { eq(6, -4, -24) } },
	},
})

-- Something heavy dragged across the ceiling void, a stroke at a time (looped until the scene stops it): a body
-- sliding on board (the cloth rustle slowed and boxed in), grit scraping under it, a dull knock now and then, a joist
-- creaking.
define("CeilingDrag", {
	bus = "World",
	priority = 38,
	maxVoices = 1,
	rollOff = r(10, 120),
	caption = "Caption.CeilingDrag",
	looped = true,
	["repeat"] = pulse(0.9, 0.35),
	layers = {
		{
			sample = "GetUp",
			volume = 1.2,
			speed = r(0.42, 0.55),
			duration = 0.75,
			envelope = env(0.12, nil, 0.4),
			effects = { eq(6, 0, -16), echo(0.015, 0.5, -8) },
		},
		{
			sample = "Falling",
			volume = 0.5,
			speed = r(1.1, 1.5),
			region = r(0.1, 1.1),
			regionJitter = 0.1,
			looped = true,
			duration = 0.6,
			envelope = env(0.1, nil, 0.3),
			effects = { echo(0.013, 0.65, -6), distortion(0.35), eq(-24, 4, -8), tremolo(6, 0.6, 0.35) },
		},
		{
			sample = "JumpLand",
			volume = 0.6,
			speed = r(0.5, 0.62),
			delay = 0.2,
			delayJitter = 0.3,
			chance = 0.45,
			effects = { eq(6, -6, -24) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.14,
			speed = r(0.3, 0.42),
			region = r(0.02, 0.03),
			looped = true,
			duration = 0.5,
			delay = 0.3,
			delayJitter = 0.3,
			chance = 0.35,
			glide = glide(0.75, 0.45),
			envelope = env(0.12, nil, 0.25),
			effects = { flanger(0.5, 0.7, 0.5), distortion(0.3) },
		},
	},
})

-- A child whispering somewhere in the dark: breath noise shaped into syllables (the wind sped up into a hiss, the
-- lows cut away, chopped by a low-duty tremolo at a speaking rate) in two short phrases, a faint voiced edge under the
-- first, far down a reverberant room.
define("ChildWhisper", {
	bus = "World",
	priority = 34,
	maxVoices = 1,
	rollOff = r(10, 110),
	caption = "Caption.ChildWhisper",
	space = { reverb(4.5, -3) },
	layers = {
		{
			sample = "Falling",
			volume = 0.7,
			speed = r(2.2, 2.5),
			region = r(0.1, 1.1),
			looped = true,
			duration = 1.5,
			envelope = env(0.15, nil, 0.4),
			effects = { eq(-40, 0, 6), tremolo(6.5, 0.9, 0.4), chorus(0.6, 0.3, 0.4) },
		},
		{
			sample = "Falling",
			volume = 0.55,
			speed = r(2.4, 2.7),
			region = r(0.1, 1.1),
			looped = true,
			duration = 1,
			delay = 1.9,
			delayJitter = 0.2,
			envelope = env(0.12, nil, 0.45),
			effects = { eq(-40, 0, 6), tremolo(7.5, 0.9, 0.35) },
		},
		{
			sample = "Ouch",
			volume = 0.12,
			speed = r(1.8, 2),
			region = r(0.06, 0.24),
			looped = true,
			duration = 0.9,
			delay = 0.25,
			envelope = env(0.2, nil, 0.4),
			effects = { pitch(1.2), eq(-40, -8, 0), tremolo(6.5, 0.9, 0.4) },
		},
	},
})

-- A child giggling far off in the dark: the voiced grunt pitched up into a small voice and cut into a run of short
-- grains at a giggle's rate, a quick intake of breath, one last giggle sagging away.
define("ChildLaugh", {
	bus = "World",
	priority = 36,
	maxVoices = 1,
	rollOff = r(10, 120),
	caption = "Caption.ChildLaugh",
	space = { reverb(5.5, -2) },
	layers = {
		{
			sample = "Oof",
			volume = 0.7,
			speed = r(2.1, 2.35),
			region = r(0.04, 0.16),
			duration = 0.08,
			envelope = env(0.005, 0.03, 0.04),
			grains = grains(4, 6, 0.13, 0.17),
			volumeJitter = 0.25,
			effects = { pitch(1.12), eq(-30, 2, -2), echo(0.09, 0.2, -12) },
		},
		{
			sample = "Falling",
			volume = 0.25,
			speed = 3,
			region = r(0.2, 0.6),
			duration = 0.22,
			delay = 0.85,
			envelope = env(0.05, nil, 0.12),
			effects = { eq(-40, -2, 4) },
		},
		{
			sample = "Oof",
			volume = 0.5,
			speed = r(2, 2.2),
			region = r(0.04, 0.16),
			duration = 0.1,
			delay = 1.15,
			envelope = env(0.005, 0.04, 0.05),
			grains = grains(2, 3, 0.14, 0.18),
			glide = glide(0.82, 0.4),
			effects = { pitch(1.12), eq(-30, 2, -2), echo(0.09, 0.2, -12) },
		},
	},
})

-- Something knocked loose clattering down: the hit, a tin ring, two bounces, a rattle as it rolls to a stop.
define("ObjectFall", {
	bus = "World",
	priority = 40,
	maxVoices = 2,
	rollOff = r(8, 110),
	caption = "Caption.ObjectFall",
	space = { reverb(1.6, -8) },
	layers = {
		{ sample = "JumpLand", volume = 1.1, speed = r(0.85, 0.95), effects = { eq(4, -2, -8) } },
		{
			sample = "VolumeSlider",
			volume = 0.8,
			speed = r(0.5, 0.6),
			effects = { echo(0.021, 0.5, -6), distortion(0.3), eq(-12, 4, -4) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.8,
			speed = r(0.75, 0.85),
			region = r(0, 0.15),
			delay = 0.3,
			effects = { eq(-4, 4, -2), echo(0.021, 0.35, -10) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.5,
			speed = r(0.85, 0.95),
			region = r(0, 0.15),
			delay = 0.5,
			effects = { eq(-4, 4, -2) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.35,
			speed = r(0.9, 1.3),
			delay = 0.62,
			grains = grains(4, 7, 0.04, 0.08),
			volumeJitter = 0.5,
			effects = { eq(-14, 2, -2), echo(0.03, 0.3, -10) },
		},
	},
})

-- The Creature glitching out of the world: air sucked backwards into nothing (the wind swelling and rising, then cut
-- dead), a static crackle through it, a sub-bass pop as it goes.
define("CreatureVanish", {
	bus = "Monster",
	priority = 86,
	maxVoices = 1,
	rollOff = r(8, 120),
	caption = "Caption.CreatureVanish",
	layers = {
		{
			sample = "Falling",
			volume = 1,
			speed = 1.3,
			region = r(0.1, 1.1),
			duration = 0.4,
			envelope = env(0.34, 0, 0.03),
			glide = glide(2.2, 0.36),
			effects = { eq(-20, 2, 4), flanger(6, 0.8, 0.7) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.6,
			speed = r(2.4, 2.8),
			region = r(0, 0.3),
			delay = 0.12,
			grains = grains(3, 5, 0.035, 0.06),
			volumeJitter = 0.4,
			effects = { distortion(0.85), eq(-20, 2, 6) },
		},
		{ sample = "JumpLand", volume = 1, speed = 0.38, delay = 0.36, effects = { eq(10, -12, -40) } },
	},
})

-- The beat of silence after the snap (2D, for everyone near): the ambience and the world drop away under one slow,
-- heavy heartbeat and the pressure of a held breath in the ears.
define("ScareHush", {
	bus = "Body",
	priority = 70,
	maxVoices = 1,
	caption = "Caption.Heartbeat",
	duck = { duck("Ambience", 0.1, 0.06, 1, 1.8), duck("World", 0.45, 0.06, 0.7, 0.4) },
	layers = {
		{
			sample = "JumpLand",
			volume = 1.9,
			speed = r(0.38, 0.41),
			region = r(0, 0.2),
			delay = 0.3,
			envelope = env(0.004, 0.11, 0.2),
			effects = { eq(9, -14, -40), compressor(-24, 8, 0.002, 0.15, 6) },
		},
		{
			sample = "JumpLand",
			volume = 1.3,
			speed = r(0.45, 0.48),
			region = r(0, 0.2),
			delay = 0.6,
			envelope = env(0.004, 0.08, 0.2),
			effects = { eq(9, -16, -40), compressor(-24, 8, 0.002, 0.15, 6) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.05,
			speed = 0.2,
			region = r(0.02, 0.026),
			looped = true,
			duration = 1.5,
			envelope = env(0.4, nil, 0.8),
			effects = { eq(-10, -20, -40) },
		},
	},
})

---------------------------------------------------------------- interface (2D)

define("UiClick", {
	bus = "UI",
	priority = 50,
	maxVoices = 4,
	layers = {
		{ sample = "VolumeSlider", volume = 0.6, speed = r(1, 1.05), effects = { eq(-6, 0, 0) } },
	},
})

define("UiConfirm", {
	bus = "UI",
	priority = 52,
	maxVoices = 2,
	space = { reverb(0.8, -14) },
	layers = {
		{ sample = "VolumeSlider", volume = 0.55, speed = 0.9 },
		{ sample = "VolumeSlider", volume = 0.55, speed = 1.35, delay = 0.07 },
	},
})

define("UiBack", {
	bus = "UI",
	priority = 50,
	maxVoices = 2,
	space = { reverb(0.8, -14) },
	layers = {
		{ sample = "VolumeSlider", volume = 0.5, speed = 1.2 },
		{ sample = "VolumeSlider", volume = 0.5, speed = 0.8, delay = 0.07 },
	},
})

---------------------------------------------------------------- footsteps (generated per surface)

type FootstepRecipe = { main: Layer, extras: { Layer } }

local FOOTSTEPS: { [Enums.SurfaceKind]: FootstepRecipe } = {
	Concrete = {
		main = {
			sample = "FootstepsPlastic",
			volume = 0.9,
			speed = r(0.62, 0.72),
			region = r(0, 0.17),
			regionJitter = 0.03,
			volumeJitter = 0.15,
			effects = { eq(3, 0, -6) },
		},
		extras = {
			{
				sample = "FootstepsPlastic",
				volume = 0.22,
				speed = r(1.8, 2.1),
				region = r(0.05, 0.2),
				regionJitter = 0.04,
				chance = 0.6,
				effects = { eq(-30, -6, 2) },
			},
		},
	},
	Tile = {
		main = {
			sample = "FootstepsPlastic",
			volume = 0.85,
			speed = r(0.95, 1.08),
			region = r(0, 0.17),
			regionJitter = 0.03,
			volumeJitter = 0.15,
			effects = { eq(-4, 2, 4), reverb(0.8, -14) },
		},
		extras = {
			{
				sample = "VolumeSlider",
				volume = 0.06,
				speed = r(0.9, 1.2),
				chance = 0.3,
				effects = { eq(-30, 0, 0) },
			},
		},
	},
	Wood = {
		main = {
			sample = "FootstepsPlastic",
			volume = 0.85,
			speed = r(0.68, 0.78),
			region = r(0, 0.17),
			regionJitter = 0.03,
			volumeJitter = 0.15,
			effects = { eq(4, 2, -8) },
		},
		extras = {
			{ sample = "JumpLand", volume = 0.35, speed = r(0.85, 0.95), effects = { eq(4, 0, -16) } },
			{
				sample = "VolumeSlider",
				volume = 0.1,
				speed = r(0.28, 0.34),
				chance = 0.12,
				effects = { flanger(0.5, 0.6, 0.5), eq(-10, 2, -10) },
			},
		},
	},
	Metal = {
		main = {
			sample = "FootstepsPlastic",
			volume = 0.9,
			speed = r(0.8, 0.9),
			region = r(0, 0.17),
			regionJitter = 0.03,
			volumeJitter = 0.15,
			effects = { flanger(0.4, 0.6, 0.5), eq(-2, 6, 2), echo(0.03, 0.4, -6) },
		},
		extras = {
			{
				sample = "VolumeSlider",
				volume = 0.3,
				speed = r(0.45, 0.55),
				effects = { distortion(0.25), reverb(1, -8) },
			},
		},
	},
	Water = {
		main = {
			sample = "Swim",
			volume = 0.8,
			speed = r(1.1, 1.3),
			region = r(0, 0.4),
			regionJitter = 0.1,
			volumeJitter = 0.15,
			effects = { eq(0, 0, -4) },
		},
		extras = {
			{
				sample = "WaterImpact",
				volume = 0.5,
				speed = r(1.4, 1.7),
				region = r(0, 0.25),
				regionJitter = 0.04,
			},
		},
	},
	Glass = {
		main = {
			sample = "FootstepsPlastic",
			volume = 0.9,
			speed = r(1.6, 1.9),
			region = r(0, 0.17),
			regionJitter = 0.03,
			volumeJitter = 0.15,
			effects = { eq(-12, 2, 6) },
		},
		extras = {
			{
				sample = "VolumeSlider",
				volume = 0.3,
				speed = r(2.8, 4),
				grains = grains(2, 3, 0.035, 0.06),
				volumeJitter = 0.4,
				effects = { eq(-40, -4, 6), echo(0.013, 0.4, -8) },
			},
		},
	},
	Grass = {
		main = {
			sample = "FootstepsPlastic",
			volume = 0.5,
			speed = r(0.5, 0.58),
			region = r(0, 0.17),
			regionJitter = 0.03,
			volumeJitter = 0.15,
			effects = { eq(0, -6, -14) },
		},
		extras = {
			{
				sample = "GetUp",
				volume = 0.5,
				speed = r(1.3, 1.6),
				region = r(0, 0.3),
				regionJitter = 0.05,
				effects = { eq(-20, -2, 2) },
			},
		},
	},
	Carpet = {
		main = {
			sample = "FootstepsPlastic",
			volume = 0.45,
			speed = r(0.55, 0.62),
			region = r(0, 0.17),
			regionJitter = 0.03,
			volumeJitter = 0.15,
			effects = { eq(2, -8, -24) },
		},
		extras = {
			{
				sample = "GetUp",
				volume = 0.25,
				speed = r(1, 1.2),
				region = r(0, 0.3),
				regionJitter = 0.05,
				effects = { eq(-12, -4, -10) },
			},
		},
	},
}

local SPRINT_VOLUME = 1.35
local SPRINT_SPEED = 1.07

local function scaledSpeed(speed: number | Range, factor: number): number | Range
	if type(speed) == "number" then
		return math.clamp(speed * factor, SPEED_RANGE.min, SPEED_RANGE.max)
	end
	return r(speed.min * factor, speed.max * factor)
end

local function sprintLayer(layer: Layer): Layer
	local copy = table.clone(layer)
	copy.volume = math.min(layer.volume * SPRINT_VOLUME, VOLUME_RANGE.max)
	copy.speed = scaledSpeed(layer.speed, SPRINT_SPEED)
	return copy
end

local function footstepName(surface: Enums.SurfaceKind, sprinting: boolean): string
	return (if sprinting then "FootstepSprint" else "Footstep") .. surface
end

for _, surface: Enums.SurfaceKind in Enums.SurfaceKind do
	local recipe = FOOTSTEPS[surface]
	assert(recipe, "missing footstep recipe for " .. surface)

	local walkLayers: { Layer } = { recipe.main }
	for _, extra in recipe.extras do
		table.insert(walkLayers, extra)
	end
	define(footstepName(surface, false), {
		bus = "Player",
		priority = 30,
		maxVoices = 8,
		rollOff = r(5, 70),
		layers = walkLayers,
	})

	local sprintLayers: { Layer } = { sprintLayer(recipe.main) }
	for _, extra in recipe.extras do
		table.insert(sprintLayers, sprintLayer(extra))
	end
	-- Running feet scuff and skid after the strike.
	table.insert(sprintLayers, {
		sample = "FootstepsPlastic",
		volume = 0.25,
		speed = r(1.4, 1.7),
		region = r(0.08, 0.25),
		regionJitter = 0.03,
		delay = 0.03,
		chance = 0.7,
		effects = { eq(-24, -2, 2) },
	})
	define(footstepName(surface, true), {
		bus = "Player",
		priority = 36,
		maxVoices = 8,
		rollOff = r(7, 110),
		layers = sprintLayers,
	})
end

--------------------------------------------------------------------------------
-- Ambience stingers per bed
--------------------------------------------------------------------------------

-- The explosion is only ever heard here, as a sparse far rumble (FarRumble), never as a loop.
local BEDS: { [string]: { Stinger } } = {
	DroneBasement = {
		stinger("FarRumble", 20, 45, nil),
		stinger("DistantGroan", 28, 60, r(40, 90)),
		stinger("MetalCreak", 14, 32, r(25, 70)),
		stinger("DripStinger", 5, 12, r(8, 26)),
	},
	DroneHallways = {
		stinger("FarRumble", 30, 60, nil, 0.8),
		stinger("MetalCreak", 12, 28, r(20, 70)),
		stinger("DistantGroan", 35, 70, r(50, 110)),
		stinger("DripStinger", 9, 20, r(10, 30)),
	},
	DroneScience = {
		stinger("FarRumble", 30, 60, nil, 0.8),
		stinger("MetalCreak", 14, 30, r(20, 70)),
		stinger("DripStinger", 7, 16, r(8, 26)),
		stinger("DistantGroan", 40, 80, r(50, 110)),
	},
	DroneGym = {
		stinger("FarRumble", 25, 55, nil),
		stinger("MetalCreak", 10, 24, r(30, 90)),
		stinger("DistantGroan", 30, 65, r(60, 130)),
	},
	DronePool = {
		stinger("FarRumble", 30, 60, nil, 0.8),
		stinger("DripStinger", 3, 8, r(6, 30)),
		stinger("MetalCreak", 16, 34, r(20, 80)),
		stinger("DistantGroan", 40, 80, r(50, 120)),
	},
	DroneRoof = {
		stinger("DistantThunder", 14, 34, nil),
		stinger("MetalCreak", 18, 40, r(15, 60)),
	},
	DroneLobby = {
		stinger("FarRumble", 40, 90, nil, 0.5),
		stinger("MetalCreak", 30, 70, r(10, 40), 0.6),
		stinger("DripStinger", 10, 24, r(6, 20)),
	},
}

---------------------------------------------------------------- the floor objectives
-- The objective stations and locks (ObjectiveService), the same recipes as the web build's objectives/sounds.js:
--   ObjFuseClick       a cartridge fuse snapping into its clips            ObjBreakerThrow  the main breaker's clunk and the mains hum
--   ObjKeyJingle       a ring of keys (pickups, the unlock's rattle)       ObjKeysWork      the keys worked in a padlock (loop)
--   ObjPadlockClack    a padlock springing open                            ObjBubbling      the fume hood's mix bubbling and hissing (loop)
--   ObjAcidSizzle      acid eating into steel                              ObjGeneratorPull the pull-start's cord and the sputter catching
--   ObjGeneratorRun    the generator running (loop)                        ObjMotorWhine    the stairwell door motor winding (loop)
--   ObjValveSqueal     a seized valve stem turning (loop)                  ObjBoltSnap      bolt cutters biting through a link
--   ObjChainDrop       a chain slithering off and landing                  ObjLockRattle    a locked padlock / chain rattled (denied)
--   ObjKeypadDenied    the keypad's denied double beep                     ObjKeypadAccept  the keypad's rising accept chirp
--   ObjExitClunk       the stairwell door's lock bolts throwing back       ObjLockerSearch  a locker door eased open to look inside
--   ObjWheelFit        the valve wheel clanking onto its stem              ObjItemPickup    a heavy item taken up (tools, the wheel)

define("ObjFuseClick", {
	bus = "World",
	priority = 45,
	maxVoices = 3,
	rollOff = r(4, 45),
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.45,
			speed = r(2.4, 2.8),
			effects = { eq(-20, 2, 6) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.8,
			speed = 1.9,
			region = r(0, 0.06),
			delay = 0.03,
			effects = { eq(-10, 6, 4) },
		},
		{
			sample = "JumpLand",
			volume = 0.35,
			speed = 1.7,
			delay = 0.05,
			effects = { eq(-6, 2, -6) },
		},
	},
})

define("ObjBreakerThrow", {
	bus = "World",
	priority = 75,
	maxVoices = 2,
	rollOff = r(10, 160),
	caption = "Caption.Breaker",
	duck = { duck("Ambience", 0.6, 0.01, 0.4, 1) },
	space = { reverb(2.4, -6) },
	layers = {
		{
			sample = "JumpLand",
			volume = 1.5,
			speed = r(0.48, 0.55),
			effects = { eq(8, 0, -12), compressor(-18, 6, 0.002, 0.15, 4) },
		},
		{
			sample = "Explosion",
			volume = 0.7,
			speed = 1.3,
			region = r(0, 0.22),
			delay = 0.01,
			effects = { distortion(0.3), eq(4, -2, -10) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.6,
			speed = 2.2,
			region = r(0, 0.2),
			delay = 0.04,
			grains = grains(2, 4, 0.03, 0.05),
			effects = { distortion(0.5), eq(-18, 2, 6), echo(0.015, 0.35, -8) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.45,
			speed = 0.16,
			region = r(0.01, 0.05),
			delay = 0.25,
			duration = 3.6,
			looped = true,
			envelope = env(0.5, 1.4, 1.6),
			effects = { tremolo(6, 0.25), eq(6, 2, -24) },
		},
	},
})

define("ObjKeyJingle", {
	bus = "Player",
	priority = 45,
	maxVoices = 3,
	rollOff = r(3, 40),
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.32,
			speed = r(2.6, 3.6),
			grains = grains(5, 8, 0.03, 0.07),
			volumeJitter = 0.4,
			effects = { eq(-24, 0, 6), chorus(4, 0.3, 0.5) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.35,
			speed = r(2.2, 2.6),
			region = r(0, 0.05),
			delay = 0.02,
			grains = grains(2, 4, 0.04, 0.09),
			effects = { eq(-20, 4, 8) },
		},
	},
})

define("ObjKeysWork", {
	bus = "World",
	priority = 45,
	maxVoices = 2,
	rollOff = r(4, 50),
	looped = true,
	["repeat"] = pulse(0.42, 0.1),
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.3,
			speed = r(2.4, 3.4),
			grains = grains(3, 6, 0.03, 0.08),
			volumeJitter = 0.4,
			effects = { eq(-24, 0, 6), chorus(4, 0.3, 0.5) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.45,
			speed = r(1.2, 1.5),
			region = r(0, 0.08),
			chance = 0.6,
			effects = { eq(-12, 6, 2), flanger(4, 0.4, 0.5) },
		},
	},
})

define("ObjPadlockClack", {
	bus = "World",
	priority = 55,
	maxVoices = 2,
	rollOff = r(4, 60),
	layers = {
		{
			sample = "FootstepsPlastic",
			volume = 0.9,
			speed = 1.35,
			region = r(0, 0.07),
			effects = { eq(-6, 6, 2) },
		},
		{
			sample = "JumpLand",
			volume = 0.5,
			speed = 1.5,
			delay = 0.04,
			effects = { eq(-4, 4, -4) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.35,
			speed = 1.9,
			delay = 0.05,
			effects = { eq(-18, 2, 4), reverb(0.6, -12) },
		},
	},
})

define("ObjBubbling", {
	bus = "World",
	priority = 45,
	maxVoices = 2,
	rollOff = r(4, 60),
	caption = "Caption.Bubbling",
	looped = true,
	["repeat"] = pulse(0.3, 0.08),
	layers = {
		{
			sample = "Falling",
			volume = 0.45,
			speed = 2.1,
			looped = true,
			effects = { eq(-30, -4, 6), tremolo(7, 0.4) },
		},
		{
			sample = "WaterImpact",
			volume = 0.4,
			speed = r(2.2, 3.2),
			region = r(0.05, 0.15),
			regionJitter = 0.05,
			grains = grains(2, 5, 0.04, 0.1),
			volumeJitter = 0.5,
			effects = { eq(-12, 4, -12), chorus(2.5, 0.5, 0.5) },
		},
	},
})

define("ObjAcidSizzle", {
	bus = "World",
	priority = 55,
	maxVoices = 3,
	rollOff = r(6, 80),
	caption = "Caption.AcidSizzle",
	layers = {
		{
			sample = "Falling",
			volume = 0.9,
			speed = r(2.6, 3),
			region = r(0.1, 1.1),
			duration = 3.2,
			looped = true,
			envelope = env(0.03, 1.8, 1.3),
			effects = { eq(-30, -2, 8), distortion(0.35) },
		},
		{
			sample = "Swim",
			volume = 0.5,
			speed = r(3, 3.4),
			duration = 2.8,
			looped = true,
			envelope = env(0.05, 1.6, 1.1),
			effects = { eq(-24, 0, 6), distortion(0.5) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.25,
			speed = 3.2,
			grains = grains(6, 10, 0.05, 0.18),
			volumeJitter = 0.6,
			effects = { eq(-30, 0, 4) },
		},
	},
})

define("ObjGeneratorPull", {
	bus = "World",
	priority = 70,
	maxVoices = 2,
	rollOff = r(8, 150),
	space = { reverb(2, -8) },
	layers = {
		{
			sample = "Jump",
			volume = 0.8,
			speed = 1.35,
			glide = glide(0.7, 0.35),
			effects = { eq(-6, 4, 2) },
		},
		{
			sample = "Explosion",
			volume = 0.5,
			speed = r(1.6, 2),
			region = r(0, 0.09),
			delay = 0.3,
			grains = grains(5, 7, 0.07, 0.12),
			volumeJitter = 0.4,
			effects = { distortion(0.4), eq(6, 2, -14) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.5,
			speed = 0.42,
			region = r(0.01, 0.05),
			delay = 0.85,
			duration = 0.9,
			looped = true,
			envelope = env(0.2, 0.4, 0.3),
			glide = glide(1.25, 0.6),
			effects = { tremolo(14, 0.6), distortion(0.3) },
		},
	},
})

define("ObjGeneratorRun", {
	bus = "World",
	priority = 60,
	maxVoices = 2,
	rollOff = r(8, 130),
	caption = "Caption.Generator",
	looped = true,
	["repeat"] = pulse(0.16, 0.02),
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.45,
			speed = 0.5,
			region = r(0.01, 0.05),
			looped = true,
			effects = { tremolo(13, 0.55), distortion(0.35), eq(6, 2, -14) },
		},
		{
			sample = "Falling",
			volume = 0.35,
			speed = 0.5,
			looped = true,
			effects = { eq(8, -6, -30) },
		},
		{
			sample = "JumpLand",
			volume = 0.22,
			speed = r(1.1, 1.3),
			volumeJitter = 0.3,
			effects = { eq(6, 0, -12) },
		},
	},
})

define("ObjMotorWhine", {
	bus = "World",
	priority = 50,
	maxVoices = 2,
	rollOff = r(8, 120),
	caption = "Caption.Motor",
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.28,
			speed = 1.05,
			region = r(0.01, 0.05),
			looped = true,
			effects = { flanger(0.35, 0.5, 0.5), eq(-12, 6, -4) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.12,
			speed = 1.58,
			region = r(0.02, 0.06),
			looped = true,
			effects = { tremolo(3, 0.3), eq(-18, 4, 0) },
		},
		{
			sample = "Falling",
			volume = 0.18,
			speed = 0.8,
			looped = true,
			effects = { eq(-6, 2, -22) },
		},
	},
})

define("ObjValveSqueal", {
	bus = "World",
	priority = 50,
	maxVoices = 2,
	rollOff = r(6, 90),
	looped = true,
	["repeat"] = pulse(0.95, 0.15),
	space = { reverb(2.6, -6) },
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.35,
			speed = r(0.7, 0.85),
			region = r(0.01, 0.05),
			duration = 0.8,
			looped = true,
			envelope = env(0.1, 0.3, 0.35),
			glide = glide(1.35, 0.7),
			effects = { flanger(0.6, 0.8, 0.5), distortion(0.4) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.4,
			speed = 0.8,
			region = r(0, 0.1),
			effects = { eq(-4, 6, -6), echo(0.03, 0.3, -10) },
		},
	},
})

define("ObjBoltSnap", {
	bus = "World",
	priority = 70,
	maxVoices = 2,
	rollOff = r(8, 140),
	layers = {
		{
			sample = "Explosion",
			volume = 0.8,
			speed = 2.4,
			region = r(0, 0.06),
			effects = { distortion(0.4), eq(-12, 4, 6) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 1,
			speed = 1.7,
			region = r(0, 0.05),
			delay = 0.01,
			effects = { eq(-8, 6, 6) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.4,
			speed = 3.1,
			delay = 0.02,
			effects = { eq(-24, 0, 8), reverb(0.8, -10) },
		},
	},
})

define("ObjChainDrop", {
	bus = "World",
	priority = 60,
	maxVoices = 2,
	rollOff = r(8, 110),
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.35,
			speed = r(1.8, 2.8),
			grains = grains(8, 10, 0.03, 0.06),
			volumeJitter = 0.5,
			effects = { eq(-20, 2, 6), chorus(5, 0.4, 0.5) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.6,
			speed = r(1.1, 1.6),
			region = r(0, 0.06),
			grains = grains(4, 7, 0.04, 0.08),
			effects = { eq(-8, 6, 2) },
		},
		{
			sample = "JumpLand",
			volume = 0.9,
			speed = 0.9,
			delay = 0.42,
			effects = { eq(6, 2, -8) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.3,
			speed = r(1.4, 2),
			delay = 0.45,
			grains = grains(3, 5, 0.03, 0.06),
			effects = { eq(-18, 4, 2), reverb(1.2, -10) },
		},
	},
})

define("ObjLockRattle", {
	bus = "World",
	priority = 40,
	maxVoices = 2,
	rollOff = r(3, 35),
	layers = {
		{
			sample = "FootstepsPlastic",
			volume = 0.7,
			speed = r(1.3, 1.6),
			region = r(0, 0.06),
			grains = grains(3, 5, 0.05, 0.08),
			effects = { eq(-10, 6, 2), flanger(6, 0.4, 0.5) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.25,
			speed = r(1.9, 2.4),
			grains = grains(3, 4, 0.05, 0.08),
			effects = { eq(-20, 2, 4) },
		},
	},
})

define("ObjKeypadDenied", {
	bus = "World",
	priority = 40,
	maxVoices = 2,
	rollOff = r(3, 35),
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.35,
			speed = 0.75,
			region = r(0.02, 0.026),
			duration = 0.16,
			looped = true,
			envelope = env(0.005, 0.12, 0.03),
			effects = { eq(-12, 4, -6), distortion(0.2) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.35,
			speed = 0.62,
			region = r(0.02, 0.026),
			delay = 0.22,
			duration = 0.16,
			looped = true,
			envelope = env(0.005, 0.12, 0.03),
			effects = { eq(-12, 4, -6), distortion(0.2) },
		},
	},
})

define("ObjKeypadAccept", {
	bus = "World",
	priority = 50,
	maxVoices = 2,
	rollOff = r(4, 50),
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.32,
			speed = 1.4,
			region = r(0.02, 0.026),
			duration = 0.1,
			looped = true,
			envelope = env(0.005, 0.07, 0.02),
			effects = { eq(-18, 4, 0) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.32,
			speed = 1.9,
			region = r(0.02, 0.026),
			delay = 0.12,
			duration = 0.18,
			looped = true,
			envelope = env(0.005, 0.12, 0.04),
			effects = { eq(-18, 4, 0), reverb(0.5, -12) },
		},
	},
})

define("ObjExitClunk", {
	bus = "World",
	priority = 80,
	maxVoices = 2,
	rollOff = r(12, 200),
	caption = "Caption.ExitUnlock",
	duck = { duck("Ambience", 0.55, 0.01, 0.5, 1) },
	space = { reverb(2.8, -5) },
	layers = {
		{
			sample = "JumpLand",
			volume = 1.6,
			speed = r(0.42, 0.48),
			effects = { eq(9, -2, -16), compressor(-18, 6, 0.002, 0.15, 4) },
		},
		{
			sample = "Explosion",
			volume = 0.7,
			speed = 1.15,
			region = r(0, 0.3),
			delay = 0.02,
			effects = { distortion(0.25), eq(5, -2, -10) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.8,
			speed = 1.4,
			region = r(0, 0.12),
			delay = 0.05,
			grains = grains(2, 3, 0.06, 0.1),
			effects = { eq(-12, 6, 4), echo(0.03, 0.3, -8) },
		},
	},
})

define("ObjLockerSearch", {
	bus = "World",
	priority = 35,
	maxVoices = 3,
	rollOff = r(3, 30),
	layers = {
		{
			sample = "VolumeSlider",
			volume = 0.22,
			speed = r(0.3, 0.36),
			region = r(0.01, 0.05),
			duration = 0.9,
			looped = true,
			envelope = env(0.2, 0.3, 0.4),
			glide = glide(0.75, 0.8),
			effects = { flanger(0.5, 0.7, 0.5), distortion(0.2) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.35,
			speed = 0.75,
			region = r(0, 0.08),
			delay = 0.1,
			effects = { eq(-4, 4, -8) },
		},
	},
})

define("ObjWheelFit", {
	bus = "World",
	priority = 55,
	maxVoices = 2,
	rollOff = r(6, 80),
	layers = {
		{
			sample = "JumpLand",
			volume = 1,
			speed = 1.05,
			effects = { eq(4, 4, -8) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.8,
			speed = 1.1,
			region = r(0, 0.1),
			delay = 0.03,
			grains = grains(2, 3, 0.08, 0.14),
			effects = { eq(-8, 6, 2), echo(0.025, 0.35, -8) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.3,
			speed = 0.9,
			delay = 0.05,
			effects = { reverb(1.6, -8) },
		},
	},
})

define("ObjItemPickup", {
	bus = "Player",
	priority = 45,
	maxVoices = 2,
	layers = {
		{
			sample = "GetUp",
			volume = 0.45,
			speed = 1.1,
			region = r(0, 0.3),
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.45,
			speed = 1.2,
			region = r(0, 0.06),
			delay = 0.06,
			effects = { eq(-10, 6, 0) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.25,
			speed = 1.3,
			delay = 0.08,
			effects = { eq(-12, 2, 0) },
		},
	},
})

--------------------------------------------------------------------------------
-- Every preset name the spec and architecture require (the specs assert each one exists).
--------------------------------------------------------------------------------

local REQUIRED: { string } = {
	"Screech",
	"Heartbeat",
	"HeartbeatFast",
	"VentScrape",
	"VentBreathing",
	"TrapSnap",
	"BoneCrunch",
	"Drip",
	"GlassCrunch",
	"DroneBasement",
	"DroneHallways",
	"DroneScience",
	"DroneGym",
	"DronePool",
	"DroneRoof",
	"DroneLobby",
	"EmfStatic",
	"ChemHiss",
	"GateSlam",
	"LightBurst",
	"Thunder",
	"Rain",
	"Splash",
	"Gasp",
	"Breathing",
	"BreathingPanic",
	"MetalCrash",
	"Unscrew",
	"DoorSmash",
	"FireDoorSwing",
	"FireDoorLatch",
	"DoorCreak",
	"FluorescentBuzz",
	"BoilerHum",
	"UiClick",
	"UiConfirm",
	"Lunge",
}
for _, surface: Enums.SurfaceKind in Enums.SurfaceKind do
	table.insert(REQUIRED, footstepName(surface, false))
	table.insert(REQUIRED, footstepName(surface, true))
end

--------------------------------------------------------------------------------
-- Freeze everything: presets are shared, read-only data.
--------------------------------------------------------------------------------

local function deepFreeze(value: any)
	if type(value) ~= "table" or table.isfrozen(value) then
		return
	end
	for _, child in value do
		deepFreeze(child)
	end
	table.freeze(value)
end

deepFreeze(presets)
deepFreeze(BEDS)
deepFreeze(EFFECTS)
table.sort(order)
table.freeze(order)
table.freeze(REQUIRED)
table.freeze(EFFECT_KINDS)
table.freeze(DEFAULT_ROLLOFF)

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

local SynthPresets = {}

SynthPresets.Presets = presets
SynthPresets.Effects = EFFECTS
SynthPresets.EffectKinds = EFFECT_KINDS
SynthPresets.Beds = BEDS
SynthPresets.Required = REQUIRED
SynthPresets.DefaultRollOff = DEFAULT_ROLLOFF
SynthPresets.SpeedRange = table.freeze(SPEED_RANGE)
SynthPresets.VolumeRange = table.freeze(VOLUME_RANGE)
SynthPresets.MinGrainSpacing = MIN_GRAIN_SPACING
SynthPresets.MaxGrainCount = MAX_GRAIN_COUNT
SynthPresets.MaxPresetReverbs = MAX_PRESET_REVERBS
SynthPresets.MaxToneRegion = MAX_TONE_REGION
SynthPresets.MaxTail = MAX_TAIL

function SynthPresets.get(name: string): Preset?
	return presets[name]
end

function SynthPresets.has(name: string): boolean
	return presets[name] ~= nil
end

-- Every preset name, sorted (frozen; the dev "sound" command and the dev panel audition every recipe from it).
function SynthPresets.names(): { string }
	return order
end

-- The footstep preset for a surface; unknown surfaces fall back to Concrete.
function SynthPresets.footstep(surface: string, sprinting: boolean?): string
	local known: Enums.SurfaceKind = if Enums.has(Enums.SurfaceKind, surface)
		then (surface :: any) :: Enums.SurfaceKind
		else "Concrete"
	return footstepName(known, sprinting == true)
end

-- A layer is a bed layer (runs for the voice's whole life) when it loops without a duration.
function SynthPresets.isBedLayer(layer: Layer): boolean
	return layer.looped == true and layer.duration == nil
end

-- True when a voice of this preset runs until it is stopped (looped presets and presets with bed layers).
function SynthPresets.isLooped(name: string): boolean
	local preset = presets[name]
	if not preset then
		return false
	end
	if preset.looped == true then
		return true
	end
	for _, layer in preset.layers do
		if SynthPresets.isBedLayer(layer) then
			return true
		end
	end
	return false
end

-- 3D distances for a preset on a bus (its own rollOff, else the bus default).
function SynthPresets.rollOff(preset: Preset): Range
	return preset.rollOff or DEFAULT_ROLLOFF[preset.bus] or WORLD_ROLLOFF
end

function SynthPresets.effectSpec(kind: string): EffectSpec?
	return EFFECTS[kind :: EffectKind]
end

-- Seconds an effect chain keeps sounding after its input stops (what its SoundGroup must outlive the grains by).
-- Reverb rings for its DecayTime; an echo repeats until feedback has taken it TAIL_FLOOR_DB below its wet level;
-- chorus / flanger delay lines add a few tens of ms. Effects run in series, so tails add. Capped at MaxTail.
function SynthPresets.chainTail(chain: { Effect }?): number
	local tail = 0
	for _, effect in (chain or {}) :: { Effect } do
		local props = effect.props
		if effect.kind == "Reverb" then
			tail += SynthPresets.clampEffectProp("Reverb", "DecayTime", props.DecayTime or 1.5)
		elseif effect.kind == "Echo" then
			local delay = SynthPresets.clampEffectProp("Echo", "Delay", props.Delay or 1)
			local feedback = SynthPresets.clampEffectProp("Echo", "Feedback", props.Feedback or 0.5)
			local wet = SynthPresets.clampEffectProp("Echo", "WetLevel", props.WetLevel or 0)
			local repeats = 1
			if feedback >= 0.999 then
				repeats = math.huge
			elseif feedback > 0.001 then
				-- wet + n * 20 log10(feedback) <= floor
				repeats = math.max(1, (TAIL_FLOOR_DB - math.min(wet, 0)) / (20 * math.log10(feedback)))
			end
			tail += delay * repeats
		elseif effect.kind == "Chorus" or effect.kind == "Flanger" then
			tail += MODULATION_TAIL
		end
	end
	return math.min(tail, MAX_TAIL)
end

-- Number of Reverb effects a preset uses (its layers' chains plus its space).
function SynthPresets.reverbCount(preset: Preset): number
	local count = 0
	for _, effect in (preset.space or {}) :: { Effect } do
		if effect.kind == "Reverb" then
			count += 1
		end
	end
	for _, layer in preset.layers do
		for _, effect in (layer.effects or {}) :: { Effect } do
			if effect.kind == "Reverb" then
				count += 1
			end
		end
	end
	return count
end

-- Clamps one effect property into its documented range (unknown props pass through unchanged).
function SynthPresets.clampEffectProp(kind: string, prop: string, value: number): number
	local spec = EFFECTS[kind :: EffectKind]
	local range = if spec then spec.props[prop] else nil
	if not range then
		return value
	end
	return math.clamp(value, range.min, range.max)
end

-- Problems with one effect (unknown kind, unknown property, value outside the documented range).
function SynthPresets.validateEffect(effect: Effect, where: string): { string }
	local problems: { string } = {}
	local spec = EFFECTS[effect.kind]
	if not spec then
		table.insert(problems, string.format("%s: unknown effect kind %s", where, tostring(effect.kind)))
		return problems
	end
	for prop, value in effect.props do
		local range = spec.props[prop]
		if not range then
			table.insert(problems, string.format("%s: %s has no property %s", where, effect.kind, prop))
		elseif type(value) ~= "number" or value ~= value or value < range.min or value > range.max then
			table.insert(
				problems,
				string.format(
					"%s: %s.%s = %s outside [%s, %s]",
					where,
					effect.kind,
					prop,
					tostring(value),
					tostring(range.min),
					tostring(range.max)
				)
			)
		end
	end
	return problems
end

local function checkRange(problems: { string }, where: string, value: Range, low: number, high: number)
	if value.min > value.max or value.min < low or value.max > high then
		table.insert(
			problems,
			string.format(
				"%s: {%s, %s} must be ordered inside [%s, %s]",
				where,
				tostring(value.min),
				tostring(value.max),
				tostring(low),
				tostring(high)
			)
		)
	end
end

local function validateLayer(problems: { string }, name: string, index: number, layer: Layer)
	local where = string.format("%s.layers[%d]", name, index)
	local sampleEntry = SoundLibrary.get(layer.sample)
	if not sampleEntry then
		table.insert(problems, where .. ": unknown sample " .. tostring(layer.sample))
		return
	end
	local length = sampleEntry.duration
	if layer.volume < VOLUME_RANGE.min or layer.volume > VOLUME_RANGE.max then
		table.insert(problems, where .. ": volume outside [0, 4]")
	end
	local speed = layer.speed
	if type(speed) == "number" then
		if speed < SPEED_RANGE.min or speed > SPEED_RANGE.max then
			table.insert(problems, where .. ": speed outside [0.05, 8]")
		end
	else
		checkRange(problems, where .. ".speed", speed, SPEED_RANGE.min, SPEED_RANGE.max)
	end
	local regionMin, regionMax = 0, length
	local region = layer.region
	if region then
		checkRange(problems, where .. ".region", region, 0, length)
		if region.max - region.min < SoundLibrary.MinRegion then
			table.insert(problems, where .. ": region shorter than SoundLibrary.MinRegion")
		end
		regionMin, regionMax = region.min, region.max
	end
	local jitter = layer.regionJitter
	if jitter and (jitter < 0 or jitter > length) then
		table.insert(problems, where .. ": regionJitter outside [0, sample length]")
	end
	local timePosition = layer.timePosition
	if timePosition and (timePosition < 0 or timePosition >= regionMax - regionMin) then
		table.insert(problems, where .. ": timePosition must lie inside the region")
	end
	for _, field in { "delay", "delayJitter", "duration" } do
		local value = (layer :: any)[field]
		if value ~= nil and (type(value) ~= "number" or value < 0) then
			table.insert(problems, where .. ": " .. field .. " must be >= 0")
		end
	end
	local chance = layer.chance
	if chance and (chance < 0 or chance > 1) then
		table.insert(problems, where .. ": chance outside [0, 1]")
	end
	local volumeJitter = layer.volumeJitter
	if volumeJitter and (volumeJitter < 0 or volumeJitter > 1) then
		table.insert(problems, where .. ": volumeJitter outside [0, 1]")
	end
	local envelope = layer.envelope
	if envelope then
		if envelope.attack < 0 or envelope.release < 0 or (envelope.hold ~= nil and envelope.hold < 0) then
			table.insert(problems, where .. ": envelope times must be >= 0")
		end
	end
	local glideSpec = layer.glide
	if glideSpec then
		if glideSpec.time <= 0 or glideSpec.to <= 0 or glideSpec.to > 4 then
			table.insert(problems, where .. ": glide needs time > 0 and 0 < to <= 4")
		end
	end
	local grainSpec = layer.grains
	if grainSpec then
		checkRange(problems, where .. ".grains.count", grainSpec.count, 1, MAX_GRAIN_COUNT)
		checkRange(problems, where .. ".grains.spacing", grainSpec.spacing, MIN_GRAIN_SPACING, 2)
		if
			grainSpec.count.min ~= math.floor(grainSpec.count.min)
			or grainSpec.count.max ~= math.floor(grainSpec.count.max)
		then
			table.insert(problems, where .. ": grains.count must be whole numbers")
		end
	end
	if SynthPresets.isBedLayer(layer) then
		if region == nil then
			if not sampleEntry.seamless then
				table.insert(problems, where .. ": a whole-file bed loop needs a seamless sample, not " .. layer.sample)
			end
		elseif region.max - region.min > MAX_TONE_REGION then
			table.insert(problems, where .. ": a bed loop region longer than MaxToneRegion restarts on a seam")
		end
	end
	for effectIndex, effect in (layer.effects or {}) :: { Effect } do
		for _, problem in SynthPresets.validateEffect(effect, string.format("%s.effects[%d]", where, effectIndex)) do
			table.insert(problems, problem)
		end
	end
end

-- Every problem with the shipped data (empty when healthy). Specs assert it; clients log it once in Studio.
function SynthPresets.validate(): { string }
	local problems: { string } = {}
	for _, name in order do
		local preset = presets[name]
		if not Enums.has(Enums.AudioBus, preset.bus) then
			table.insert(problems, name .. ": unknown bus " .. tostring(preset.bus))
		end
		if #preset.layers == 0 then
			table.insert(problems, name .. ": no layers")
		end
		if preset.priority < 0 or preset.priority > 100 then
			table.insert(problems, name .. ": priority outside [0, 100]")
		end
		if preset.maxVoices < 1 or preset.maxVoices ~= math.floor(preset.maxVoices) then
			table.insert(problems, name .. ": maxVoices must be a whole number >= 1")
		end
		local caption = preset.caption
		if caption and not Strings.has(caption) then
			table.insert(problems, name .. ": unknown caption key " .. caption)
		end
		local rollOff = preset.rollOff
		if rollOff and (rollOff.min <= 0 or rollOff.max <= rollOff.min) then
			table.insert(problems, name .. ": rollOff needs 0 < min < max")
		end
		local pulseSpec = preset["repeat"]
		if
			pulseSpec
			and (pulseSpec.interval <= 0.05 or pulseSpec.jitter < 0 or pulseSpec.jitter >= pulseSpec.interval * 2)
		then
			table.insert(problems, name .. ": repeat needs interval > 0.05 and 0 <= jitter < 2 x interval")
		end
		for _, duckSpec in (preset.duck or {}) :: { Duck } do
			if not Enums.has(Enums.AudioBus, duckSpec.bus) or duckSpec.bus == preset.bus then
				table.insert(problems, name .. ": duck must target another valid bus")
			end
			if
				duckSpec.gain < 0
				or duckSpec.gain > 1
				or duckSpec.attack < 0
				or duckSpec.hold < 0
				or duckSpec.release < 0
			then
				table.insert(problems, name .. ": duck gain must be in [0, 1] and times >= 0")
			end
		end
		for index, layer in preset.layers do
			validateLayer(problems, name, index, layer)
		end
		for index, effect in (preset.space or {}) :: { Effect } do
			for _, problem in SynthPresets.validateEffect(effect, string.format("%s.space[%d]", name, index)) do
				table.insert(problems, problem)
			end
		end
		if SynthPresets.reverbCount(preset) > MAX_PRESET_REVERBS then
			table.insert(problems, name .. ": more than MaxPresetReverbs Reverb effects")
		end
	end
	for _, name in REQUIRED do
		if presets[name] == nil then
			table.insert(problems, "missing required preset " .. name)
		end
	end
	for bed, stingers in BEDS do
		if presets[bed] == nil then
			table.insert(problems, "stingers for unknown bed " .. bed)
		end
		for index, entry in stingers do
			local where = string.format("Beds.%s[%d]", bed, index)
			local preset = presets[entry.preset]
			if not preset then
				table.insert(problems, where .. ": unknown preset " .. entry.preset)
				continue
			end
			if SynthPresets.isLooped(entry.preset) then
				table.insert(problems, where .. ": stingers must be one-shots")
			end
			checkRange(problems, where .. ".interval", entry.interval, 1, 600)
			local distance = entry.distance
			if distance then
				checkRange(problems, where .. ".distance", distance, 0, SynthPresets.rollOff(preset).max)
			end
		end
	end
	return problems
end

return table.freeze(SynthPresets)
