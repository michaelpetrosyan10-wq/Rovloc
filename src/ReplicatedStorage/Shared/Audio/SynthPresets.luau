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
--   effects       SoundEffect chain in order (first = highest Priority); kinds and ranges in SynthPresets.Effects
-- Preset fields: bus, layers, rollOff {min, max} (3D distances; nil = bus default when placed in 3D), priority
-- (0..100, voice stealing), maxVoices (concurrent voices of this preset), caption (Strings key), looped (the voice
-- runs until stopped), repeat {interval, jitter} (how a looped voice re-triggers its non-bed layers: heartbeat
-- pulses, drips, rain patter), duck (other buses dipped while this plays).
--
-- Loop-region tones: a looped region a few milliseconds long repeats fast enough to become a pitched tone
-- (period = region length / speed), e.g. a 10 ms slice of the slider tick at speed 1.2 hums at 120 Hz.

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

-- Default 3D distances per bus when a preset without rollOff is placed in the world.
local WORLD_ROLLOFF = r(8, 120)
local DEFAULT_ROLLOFF: { [Enums.AudioBus]: Range } = {
	Ambience = r(10, 90),
	World = WORLD_ROLLOFF,
	Monster = r(10, 160),
	Player = r(6, 80),
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
define("VentScrape", {
	bus = "Monster",
	priority = 85,
	maxVoices = 2,
	rollOff = r(10, 180),
	caption = "Caption.VentScrape",
	looped = true,
	["repeat"] = pulse(1.35, 0.45),
	layers = {
		-- Sheet-metal drone: wind dragged slow through a flanger and a resonant mid band, pulsing with each limb.
		{
			sample = "Falling",
			volume = 0.9,
			speed = 0.55,
			region = r(0.15, 1.1),
			looped = true,
			envelope = env(0.4, nil, 0.6),
			effects = {
				flanger(0.35, 0.8, 0.75),
				eq(-6, 7, -4),
				distortion(0.25),
				tremolo(3.2, 0.55, 0.6),
				echo(0.12, 0.45, -4),
			},
		},
		-- Claws: slowed footstep transients sliced at random, scraped in bursts every stride.
		{
			sample = "FootstepsPlastic",
			volume = 1.1,
			speed = r(0.32, 0.45),
			region = r(0, 0.3),
			regionJitter = 0.05,
			grains = grains(5, 8, 0.09, 0.22),
			volumeJitter = 0.25,
			effects = { chorus(1.2, 0.5, 0.5), flanger(2, 0.5, 0.6), eq(-4, 7, 2), echo(0.09, 0.5, -3) },
		},
		-- Duct rattle: a slice of the slider tick looped into a crushed ~9 Hz flutter, the steel straining.
		{
			sample = "VolumeSlider",
			volume = 0.28,
			speed = 0.35,
			region = r(0.01, 0.05),
			looped = true,
			envelope = env(0.8, nil, 0.8),
			effects = { distortion(0.7), flanger(0.6, 0.7, 0.6), tremolo(1.5, 0.6, 0.5), eq(-10, 4, -8) },
		},
		-- Body drag: cloth rustle slowed into a heavy torso sliding on steel.
		{
			sample = "GetUp",
			volume = 0.8,
			speed = r(0.45, 0.55),
			delay = 0.2,
			delayJitter = 0.15,
			grains = grains(1, 2, 0.3, 0.6),
			effects = { eq(4, 3, -10), echo(0.08, 0.4, -6) },
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
	bus = "Player",
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
	bus = "Player",
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
	bus = "Player",
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

define("BreathingPanic", {
	bus = "Player",
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
			effects = { eq(-20, 0, -4) },
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
		{
			sample = "Oof",
			volume = 0.25,
			speed = r(1.2, 1.32),
			delay = 0.5,
			chance = 0.35,
			effects = { eq(-14, 2, -2) },
		},
	},
})

-- A loud gasp (failed breath hold): the grunt sped up into a sharp intake with a burst of air.
define("Gasp", {
	bus = "Player",
	priority = 80,
	maxVoices = 2,
	rollOff = r(6, 90),
	caption = "Caption.Gasp",
	layers = {
		{
			sample = "Oof",
			volume = 1.3,
			speed = r(1.15, 1.3),
			envelope = env(0.01, nil, 0.15),
			effects = { eq(-12, 4, 2), reverb(0.6, -12) },
		},
		{
			sample = "Falling",
			volume = 0.8,
			speed = 1.4,
			region = r(0.1, 0.5),
			duration = 0.45,
			envelope = env(0.02, 0.15, 0.25),
			effects = { eq(-24, 2, 4) },
		},
		{
			sample = "Ouch",
			volume = 0.4,
			speed = r(0.95, 1.05),
			delay = 0.18,
			chance = 0.5,
			effects = { eq(-10, 2, -4) },
		},
	},
})

-- EMF interference (looped, 2D): crushed and chopped wind hiss, crackle grains, a buzzing loop-region tone.
define("EmfStatic", {
	bus = "Player",
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
			region = r(0.1, 1),
			looped = true,
			envelope = env(0.08, nil, 0.25),
			effects = { distortion(0.8), tremolo(17, 0.85, 0.3), eq(-30, 0, 4) },
		},
		{
			sample = "FootstepsPlastic",
			volume = 0.45,
			speed = r(2.5, 3.5),
			region = r(0, 0.3),
			regionJitter = 0.08,
			grains = grains(4, 9, 0.02, 0.09),
			volumeJitter = 0.5,
			effects = { distortion(0.9), eq(-24, 2, 6) },
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

-- Bear trap: a crushed strike, ringing iron, a rattling spring, the weight of the jaws, the crack of the hit.
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
			volume = 1.4,
			speed = r(0.42, 0.5),
			effects = { distortion(0.35), flanger(0.2, 0.9, 0.5), echo(0.05, 0.55, -2), reverb(1.6, -6) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.6,
			speed = r(1.4, 1.8),
			delay = 0.03,
			grains = grains(4, 6, 0.025, 0.05),
			effects = { eq(-20, 2, 4), echo(0.04, 0.4, -8) },
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
		{
			sample = "FootstepsPlastic",
			volume = 1.6,
			speed = r(0.55, 0.7),
			region = r(0, 0.3),
			regionJitter = 0.04,
			grains = grains(3, 5, 0.02, 0.05),
			effects = { distortion(0.7), eq(4, 6, -6) },
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

-- One drop: the splash's first transient sped up hard and cut short, pitch and level different every time.
-- Played looped (e.g. a DripPipe emitter) it re-triggers on the pulse.
define("Drip", {
	bus = "World",
	priority = 15,
	maxVoices = 8,
	rollOff = r(4, 60),
	["repeat"] = pulse(2.2, 1.3),
	layers = {
		{
			sample = "WaterImpact",
			volume = 0.6,
			speed = r(2.6, 3.7),
			region = r(0, 0.12),
			regionJitter = 0.02,
			duration = 0.12,
			volumeJitter = 0.25,
			envelope = env(0.002, 0.05, 0.06),
			effects = { eq(-30, -2, 4), echo(0.11, 0.35, -10), reverb(1.4, -8) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.18,
			speed = r(1.6, 2.3),
			delay = 0.004,
			chance = 0.5,
			effects = { eq(-40, -6, 2), reverb(1.2, -10) },
		},
	},
})

-- Broken glass and cans underfoot: sped-up transient clusters, skittering shards, crushed tin, body weight.
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
			grains = grains(4, 7, 0.015, 0.04),
			effects = { eq(-18, 2, 8), distortion(0.5) },
		},
		{
			sample = "VolumeSlider",
			volume = 0.5,
			speed = r(2.8, 4.2),
			delay = 0.02,
			grains = grains(5, 9, 0.02, 0.07),
			volumeJitter = 0.4,
			effects = { eq(-40, -4, 6), echo(0.025, 0.3, -10) },
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
		{
			sample = "VolumeSlider",
			volume = 0.7,
			speed = r(3, 4.5),
			delay = 0.01,
			grains = grains(7, 12, 0.015, 0.05),
			volumeJitter = 0.5,
			effects = { eq(-40, -4, 6), echo(0.03, 0.3, -8) },
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
			grains = grains(4, 7, 0.01, 0.03),
			effects = { distortion(0.75), eq(4, 6, 2), compressor(-18, 10, 0.001, 0.2, 6) },
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
			grains = grains(6, 10, 0.02, 0.06),
			volumeJitter = 0.4,
			effects = { eq(-40, -4, 6), echo(0.03, 0.3, -8) },
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

---------------------------------------------------------------- weather

-- Thunder (2D): a close crack some of the time, the main rolling rumble, and a far second roll.
define("Thunder", {
	bus = "Ambience",
	priority = 70,
	maxVoices = 2,
	caption = "Caption.Thunder",
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
			effects = { reverb(9, -2), eq(6, -6, -24), tremolo(2.2, 0.35, 0.5) },
		},
		{
			sample = "Explosion",
			volume = 1,
			speed = r(0.18, 0.22),
			region = r(0.4, 1.8),
			delay = 0.9,
			delayJitter = 0.3,
			effects = { eq(6, -10, -40), tremolo(1.1, 0.5, 0.5), reverb(10, -4) },
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
	layers = {
		{
			sample = "Explosion",
			volume = 0.9,
			speed = r(0.2, 0.26),
			region = r(0.1, 1.8),
			effects = { reverb(10, -4), eq(6, -10, -40), tremolo(1.4, 0.5, 0.5) },
		},
		{
			sample = "Explosion",
			volume = 0.6,
			speed = 0.16,
			region = r(0.3, 1.8),
			delay = 0.6,
			delayJitter = 0.4,
			effects = { eq(6, -14, -50), reverb(12, -6) },
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

-- Basement: the building groaning (explosion slowed to a crawl, twice, detuned so loop seams never align),
-- stale air through the boiler room, water ticking in old pipes; long concrete reverb, slow tremolo breathing.
define("DroneBasement", {
	bus = "Ambience",
	priority = 10,
	maxVoices = 2,
	looped = true,
	layers = {
		{
			sample = "Explosion",
			volume = 0.9,
			speed = 0.24,
			region = r(0.15, 1.6),
			looped = true,
			envelope = env(3, nil, 3),
			effects = { eq(4, -6, -30), reverb(8, -4, -2), tremolo(0.18, 0.35, 0.5) },
		},
		{
			sample = "Explosion",
			volume = 0.6,
			speed = 0.31,
			region = r(0.3, 1.7),
			timePosition = 0.4,
			looped = true,
			envelope = env(4, nil, 3),
			effects = { eq(3, -8, -36), reverb(10, -6, -4), flanger(0.05, 0.5, 0.35) },
		},
		{
			sample = "Falling",
			volume = 0.5,
			speed = 0.32,
			region = r(0.1, 1.1),
			looped = true,
			envelope = env(3, nil, 3),
			effects = { flanger(0.07, 0.6, 0.4), eq(2, -4, -24), reverb(6, -8) },
		},
		{
			sample = "Swim",
			volume = 0.15,
			speed = 0.4,
			region = r(0, 0.8),
			looped = true,
			envelope = env(4, nil, 3),
			effects = { eq(4, -8, -30), chorus(0.2, 0.5, 0.5), reverb(5, -6) },
		},
	},
})

-- Hallways: wind moaning down long broken corridors, a thin whistle, the far groan, a dying mains hum.
define("DroneHallways", {
	bus = "Ambience",
	priority = 10,
	maxVoices = 2,
	looped = true,
	layers = {
		{
			sample = "Falling",
			volume = 0.6,
			speed = 0.45,
			region = r(0.1, 1.1),
			looped = true,
			envelope = env(3, nil, 3),
			effects = { flanger(0.06, 0.7, 0.45), eq(-2, 0, -16), reverb(5, -6), tremolo(0.12, 0.4, 0.5) },
		},
		{
			sample = "Falling",
			volume = 0.35,
			speed = 0.62,
			region = r(0.2, 1),
			timePosition = 0.3,
			looped = true,
			envelope = env(4, nil, 3),
			effects = { eq(-10, -2, -10), chorus(0.15, 0.6, 0.5), reverb(6, -8) },
		},
		{
			sample = "Explosion",
			volume = 0.55,
			speed = 0.27,
			region = r(0.2, 1.6),
			looped = true,
			envelope = env(3, nil, 3),
			effects = { eq(4, -8, -34), reverb(9, -6), tremolo(0.09, 0.4, 0.5) },
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

-- Science hall: an eerie chorused air, bubbling in forgotten tanks, the low groan, a gas leak swelling.
define("DroneScience", {
	bus = "Ambience",
	priority = 10,
	maxVoices = 2,
	looped = true,
	layers = {
		{
			sample = "Falling",
			volume = 0.45,
			speed = 0.58,
			region = r(0.1, 1.1),
			looped = true,
			envelope = env(3, nil, 3),
			effects = { chorus(0.25, 0.7, 0.6), eq(-8, 2, -12), reverb(5, -6), tremolo(0.15, 0.3, 0.5) },
		},
		{
			sample = "Swim",
			volume = 0.22,
			speed = 0.35,
			region = r(0, 0.8),
			looped = true,
			envelope = env(4, nil, 3),
			effects = { flanger(0.3, 0.6, 0.5), eq(2, -4, -20), reverb(4, -6) },
		},
		{
			sample = "Explosion",
			volume = 0.55,
			speed = 0.26,
			region = r(0.2, 1.6),
			looped = true,
			envelope = env(3, nil, 3),
			effects = { eq(4, -8, -34), reverb(9, -6) },
		},
		{
			sample = "Falling",
			volume = 0.12,
			speed = 2.2,
			region = r(0.1, 1.1),
			looped = true,
			envelope = env(5, nil, 3),
			effects = { eq(-40, -10, 0), tremolo(0.6, 0.8, 0.3), reverb(3, -6) },
		},
	},
})

-- Gymnasium: a vast, slow hall; the groan stretched under a twelve-second reverb, air high in the rafters.
define("DroneGym", {
	bus = "Ambience",
	priority = 10,
	maxVoices = 2,
	looped = true,
	layers = {
		{
			sample = "Explosion",
			volume = 0.8,
			speed = 0.2,
			region = r(0.1, 1.7),
			looped = true,
			envelope = env(3, nil, 3),
			effects = { eq(5, -6, -36), reverb(12, -2, -4), tremolo(0.07, 0.4, 0.5) },
		},
		{
			sample = "Falling",
			volume = 0.5,
			speed = 0.38,
			region = r(0.1, 1.1),
			looped = true,
			envelope = env(3, nil, 3),
			effects = { flanger(0.04, 0.8, 0.4), eq(0, -4, -20), reverb(10, -4) },
		},
		{
			sample = "Falling",
			volume = 0.2,
			speed = 0.9,
			region = r(0.2, 1.1),
			timePosition = 0.5,
			looped = true,
			envelope = env(5, nil, 3),
			effects = { eq(-16, -4, -6), reverb(12, -2), tremolo(0.05, 0.7, 0.5) },
		},
	},
})

-- Flooded pool: water lapping the tiles, a slower swell, the deep groan, a wet tiled-hall reverb.
define("DronePool", {
	bus = "Ambience",
	priority = 10,
	maxVoices = 2,
	looped = true,
	layers = {
		{
			sample = "Swim",
			volume = 0.45,
			speed = 0.5,
			region = r(0, 0.8),
			looped = true,
			envelope = env(3, nil, 3),
			effects = { eq(2, -2, -12), reverb(9, -4), chorus(0.1, 0.5, 0.4) },
		},
		{
			sample = "Swim",
			volume = 0.25,
			speed = 0.38,
			region = r(0.1, 0.8),
			timePosition = 0.3,
			looped = true,
			envelope = env(4, nil, 3),
			effects = { eq(4, -6, -20), reverb(10, -6), tremolo(0.11, 0.5, 0.5) },
		},
		{
			sample = "Explosion",
			volume = 0.45,
			speed = 0.22,
			region = r(0.2, 1.6),
			looped = true,
			envelope = env(3, nil, 3),
			effects = { eq(4, -8, -36), reverb(11, -4) },
		},
		{
			sample = "Falling",
			volume = 0.15,
			speed = 0.5,
			region = r(0.1, 1.1),
			looped = true,
			envelope = env(4, nil, 3),
			effects = { eq(-6, -6, -20), reverb(8, -6) },
		},
	},
})

-- Roof: the storm. Gusting wind, rain hiss, patter on the roof, the far rumble; dry, it is outdoors.
define("DroneRoof", {
	bus = "Ambience",
	priority = 10,
	maxVoices = 2,
	looped = true,
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
			sample = "WaterImpact",
			volume = 0.28,
			speed = 2.2,
			region = r(0, 0.5),
			looped = true,
			envelope = env(2, nil, 3),
			effects = { eq(-24, -2, 4), chorus(1.1, 0.4, 0.5) },
		},
		{
			sample = "Explosion",
			volume = 0.4,
			speed = 0.18,
			region = r(0.3, 1.7),
			looped = true,
			envelope = env(4, nil, 3),
			effects = { eq(6, -10, -40), reverb(6, -10), tremolo(0.06, 0.6, 0.5) },
		},
	},
})

-- Lobby (the safe zone): a warm boiler throb, soft air, water moving in the pipes. Less dissonant on purpose.
define("DroneLobby", {
	bus = "Ambience",
	priority = 10,
	maxVoices = 2,
	looped = true,
	layers = {
		{
			sample = "Explosion",
			volume = 0.6,
			speed = 0.3,
			region = r(0.2, 1.4),
			looped = true,
			envelope = env(2, nil, 3),
			effects = { eq(6, -6, -40), tremolo(0.75, 0.25, 0.5), reverb(2.2, -10) },
		},
		{
			sample = "Falling",
			volume = 0.25,
			speed = 0.5,
			region = r(0.1, 1.1),
			looped = true,
			envelope = env(3, nil, 3),
			effects = { eq(2, -6, -22), chorus(0.2, 0.4, 0.4), reverb(2, -10) },
		},
		{
			sample = "Swim",
			volume = 0.08,
			speed = 0.6,
			region = r(0, 0.8),
			looped = true,
			envelope = env(4, nil, 3),
			effects = { eq(0, -6, -18), reverb(2, -8) },
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
			region = r(0, 0.8),
			looped = true,
			envelope = env(0.3, nil, 0.6),
			effects = { eq(6, -24, -60), chorus(0.4, 0.5, 0.5) },
		},
		{
			sample = "Falling",
			volume = 0.3,
			speed = 0.2,
			region = r(0.1, 1.1),
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
			region = r(0.1, 1.1),
			looped = true,
			envelope = env(0.3, nil, 0.3),
			effects = { tremolo(20, 0.7, 0.4), eq(-40, -6, 2) },
		},
	},
})

-- Boiler (lobby / basement emitters): a throbbing low roar, air, a 60 Hz motor hum, an occasional pipe knock.
define("BoilerHum", {
	bus = "World",
	priority = 10,
	maxVoices = 3,
	rollOff = r(8, 70),
	looped = true,
	["repeat"] = pulse(1.8, 0.3),
	layers = {
		{
			sample = "Explosion",
			volume = 0.7,
			speed = 0.28,
			region = r(0.2, 1.4),
			looped = true,
			envelope = env(1, nil, 1),
			effects = { eq(8, -6, -40), tremolo(0.9, 0.3, 0.5) },
		},
		{
			sample = "Falling",
			volume = 0.3,
			speed = 0.4,
			region = r(0.1, 1.1),
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

-- The building settling: a slowed loop-region tone sagging in pitch under a resonant wind drag.
define("MetalCreak", {
	bus = "World",
	priority = 18,
	maxVoices = 3,
	rollOff = r(10, 120),
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
			effects = { flanger(0.4, 0.8, 0.6), distortion(0.35), reverb(4, -4) },
		},
		{
			sample = "Falling",
			volume = 0.3,
			speed = r(0.36, 0.44),
			region = r(0.1, 1.1),
			duration = 1.4,
			envelope = env(0.4, nil, 0.7),
			effects = { flanger(0.3, 0.7, 0.6), eq(-8, 6, -14), reverb(4, -6) },
		},
	},
})

-- Something far away in the building, groaning: the cry slowed to a moan, sagging, drowned in reverb.
define("DistantGroan", {
	bus = "World",
	priority = 16,
	maxVoices = 2,
	rollOff = r(20, 160),
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
			effects = { pitch(0.6), reverb(8, -2), eq(4, -2, -20) },
		},
		{
			sample = "Explosion",
			volume = 0.5,
			speed = 0.22,
			region = r(0.2, 1.5),
			duration = 2.6,
			envelope = env(1, nil, 1.2),
			effects = { reverb(9, -4), eq(4, -8, -30) },
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
	layers = {
		{ sample = "VolumeSlider", volume = 0.55, speed = 0.9, effects = { reverb(0.8, -14) } },
		{ sample = "VolumeSlider", volume = 0.55, speed = 1.35, delay = 0.07, effects = { reverb(0.8, -14) } },
	},
})

define("UiBack", {
	bus = "UI",
	priority = 50,
	maxVoices = 2,
	layers = {
		{ sample = "VolumeSlider", volume = 0.5, speed = 1.2, effects = { reverb(0.8, -14) } },
		{ sample = "VolumeSlider", volume = 0.5, speed = 0.8, delay = 0.07, effects = { reverb(0.8, -14) } },
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
				grains = grains(2, 4, 0.02, 0.05),
				volumeJitter = 0.4,
				effects = { eq(-40, -4, 6) },
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

local BEDS: { [string]: { Stinger } } = {
	DroneBasement = {
		stinger("DistantGroan", 28, 60, r(40, 90)),
		stinger("MetalCreak", 14, 32, r(25, 70)),
		stinger("Drip", 5, 12, r(8, 26)),
	},
	DroneHallways = {
		stinger("MetalCreak", 12, 28, r(20, 70)),
		stinger("DistantGroan", 35, 70, r(50, 110)),
		stinger("Drip", 9, 20, r(10, 30)),
	},
	DroneScience = {
		stinger("MetalCreak", 14, 30, r(20, 70)),
		stinger("Drip", 7, 16, r(8, 26)),
		stinger("DistantGroan", 40, 80, r(50, 110)),
	},
	DroneGym = {
		stinger("MetalCreak", 10, 24, r(30, 90)),
		stinger("DistantGroan", 30, 65, r(60, 130)),
	},
	DronePool = {
		stinger("Drip", 3, 8, r(6, 30)),
		stinger("MetalCreak", 16, 34, r(20, 80)),
		stinger("DistantGroan", 40, 80, r(50, 120)),
	},
	DroneRoof = {
		stinger("DistantThunder", 14, 34, nil),
		stinger("MetalCreak", 18, 40, r(15, 60)),
	},
	DroneLobby = {
		stinger("MetalCreak", 30, 70, r(10, 40), 0.6),
		stinger("Drip", 10, 24, r(6, 20)),
	},
}

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

function SynthPresets.get(name: string): Preset?
	return presets[name]
end

function SynthPresets.has(name: string): boolean
	return presets[name] ~= nil
end

-- Every preset name, sorted.
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
		checkRange(problems, where .. ".grains.count", grainSpec.count, 1, 32)
		checkRange(problems, where .. ".grains.spacing", grainSpec.spacing, 0, 2)
		if
			grainSpec.count.min ~= math.floor(grainSpec.count.min)
			or grainSpec.count.max ~= math.floor(grainSpec.count.max)
		then
			table.insert(problems, where .. ": grains.count must be whole numbers")
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
