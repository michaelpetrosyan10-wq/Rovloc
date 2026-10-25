--!strict
-- Client-local mixer: a SoundGroup tree under SoundService and the room acoustics applied to it.
--
--   SoundService
--   └── Master (SoundGroup, safety compressor)
--       ├── Ambience   beds and stingers (only an EQ: muffled underwater / in ducts)
--       ├── World      props, doors, traps, weather on location           ┐
--       ├── Monster    the Creature                                       ├ environment chain
--       ├── Player     footsteps, breathing, heartbeat, gasps              ┘ (EQ, Chorus, Reverb, Echo)
--       └── UI         interface clicks (dry)
--
-- Environment DSP: every Enums.AcousticPreset maps to values for one fixed chain on the World / Player / Monster
-- groups (Equalizer -> Chorus -> Reverb -> Echo). Every preset sets every property, with "off" written as neutral
-- values (0 dB EQ, Chorus Mix 0, WetLevel -80), so switching rooms is a smooth interpolation of numbers, never a
-- swap of instances. Effects that sit fully neutral after a fade are disabled to save DSP.
--
-- Final group volume = user volume (SettingsSchema, set by SettingsController via setVolume) x duck gain
-- (presets dip other buses: a screech pulls the ambience down) x environment gain.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)

local log = Log.new("AudioBuses")

export type BusName = Enums.AudioBus | "Master"

-- One environment = a value for every property of every slot in the chain.
export type EnvironmentSpec = {
	effects: { SynthPresets.Effect }, -- exactly one per CHAIN slot, in CHAIN order
	ambience: SynthPresets.Effect, -- Equalizer on the Ambience group
	gain: number, -- multiplier on the environment groups (underwater is quieter)
}

export type Tree = {
	master: SoundGroup,
	groups: { [Enums.AudioBus]: SoundGroup },
	masterCompressor: CompressorSoundEffect,
	chains: { [Enums.AudioBus]: { SoundEffect } }, -- environment chain per environment bus, CHAIN order
	ambienceEq: EqualizerSoundEffect,
}

type DuckState = { gain: number, attack: number, hold: number, release: number, startedAt: number }

local MASTER_NAME = "Master"
local CHAIN: { SynthPresets.EffectKind } = { "Equalizer", "Chorus", "Reverb", "Echo" }
local ENVIRONMENT_BUSES: { Enums.AudioBus } = { "World", "Player", "Monster" }
local DEFAULT_FADE = 0.8

local SETTING_KEYS: { [string]: string } = {
	Master = "MasterVolume",
	Ambience = "AmbienceVolume",
	World = "WorldVolume",
	Monster = "MonsterVolume",
	Player = "PlayerVolume",
	UI = "UIVolume",
}

--------------------------------------------------------------------------------
-- Environment presets
--------------------------------------------------------------------------------

local function eq(low: number, mid: number, high: number): SynthPresets.Effect
	return { kind = "Equalizer", props = { LowGain = low, MidGain = mid, HighGain = high } }
end

local function chorus(rate: number, depth: number, mix: number): SynthPresets.Effect
	return { kind = "Chorus", props = { Rate = rate, Depth = depth, Mix = mix } }
end

local function reverb(decay: number, wet: number, dry: number, density: number, diffusion: number): SynthPresets.Effect
	return {
		kind = "Reverb",
		props = { DecayTime = decay, WetLevel = wet, DryLevel = dry, Density = density, Diffusion = diffusion },
	}
end

local function echo(delay: number, feedback: number, wet: number, dry: number): SynthPresets.Effect
	return { kind = "Echo", props = { Delay = delay, Feedback = feedback, WetLevel = wet, DryLevel = dry } }
end

local NO_CHORUS = chorus(0.5, 0.15, 0)
local NO_ECHO_DELAY = 0.1

local function environment(
	envEq: SynthPresets.Effect,
	envChorus: SynthPresets.Effect,
	envReverb: SynthPresets.Effect,
	envEcho: SynthPresets.Effect,
	ambience: SynthPresets.Effect,
	gain: number
): EnvironmentSpec
	return { effects = { envEq, envChorus, envReverb, envEcho }, ambience = ambience, gain = gain }
end

local FLAT = eq(0, 0, 0)

-- Classrooms, offices, storage: a short, damped room. Also the fallback for unknown presets.
local ROOM = environment(FLAT, NO_CHORUS, reverb(0.9, -14, 0, 0.8, 0.9), echo(NO_ECHO_DELAY, 0, -80, 0), FLAT, 1)

local ENVIRONMENTS: { [Enums.AcousticPreset]: EnvironmentSpec } = {
	Room = ROOM,
	-- Long corridors: a longer tail and a faint flutter between the parallel walls.
	Corridor = environment(eq(0, 0, -1), NO_CHORUS, reverb(1.8, -11, 0, 0.9, 0.7), echo(0.09, 0.2, -20, 0), FLAT, 1),
	-- Gym and pool hall: a huge tail and a late slap off the far wall.
	Hall = environment(eq(1, 0, -2), NO_CHORUS, reverb(4.5, -7, 0, 1, 0.9), echo(0.28, 0.25, -16, 0), FLAT, 1),
	-- Inside a duct: boxy, metallic, a tight comb echo ringing in the bore.
	Vent = environment(
		eq(-6, 4, -8),
		NO_CHORUS,
		reverb(0.6, -6, 0, 0.4, 0.2),
		echo(0.035, 0.55, -7, 0),
		eq(-4, -2, -10),
		1
	),
	-- Submerged: heavy low-pass muffle with a slow pressure wobble; the world goes quiet.
	Underwater = environment(
		eq(4, -26, -60),
		chorus(0.6, 0.35, 0.5),
		reverb(2.5, -4, -6, 1, 1),
		echo(NO_ECHO_DELAY, 0, -80, 0),
		eq(2, -24, -60),
		0.75
	),
	-- Roof and street: nearly dry, a light slap back off the surrounding buildings.
	Outdoor = environment(FLAT, NO_CHORUS, reverb(0.4, -30, 0, 0.3, 0.3), echo(0.45, 0.18, -22, 0), FLAT, 1),
	-- Stair towers: a hard concrete shaft with a pronounced slap echo.
	Stairwell = environment(eq(0, 1, -2), NO_CHORUS, reverb(2.6, -9, 0, 1, 0.6), echo(0.14, 0.35, -13, 0), FLAT, 1),
	-- Basement: concrete everywhere, long and dark.
	Basement = environment(eq(2, 0, -3), NO_CHORUS, reverb(3.2, -8, 0, 1, 0.75), echo(0.2, 0.25, -18, 0), FLAT, 1),
	-- Boiler-room lobby: warm and enclosed, no slap.
	Lobby = environment(
		eq(2, 0, -2),
		NO_CHORUS,
		reverb(1.6, -12, 0, 0.9, 0.8),
		echo(NO_ECHO_DELAY, 0, -80, 0),
		FLAT,
		1
	),
}

local function deepFreeze(value: any)
	if type(value) ~= "table" or table.isfrozen(value) then
		return
	end
	for _, child in value do
		deepFreeze(child)
	end
	table.freeze(value)
end

deepFreeze(ENVIRONMENTS)
table.freeze(CHAIN)
table.freeze(ENVIRONMENT_BUSES)

-- Neutral (inaudible) value per property: a slot whose props all sit at these values can be disabled.
local NEUTRAL: { [SynthPresets.EffectKind]: { [string]: number } } = {
	Equalizer = { LowGain = 0, MidGain = 0, HighGain = 0 },
	Chorus = { Mix = 0 },
	Reverb = { WetLevel = -80 },
	Echo = { WetLevel = -80 },
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local tree: Tree? = nil
local userVolume: { [string]: number } = {}
local ducks: { [Enums.AudioBus]: { DuckState } } = {}
local environmentName: Enums.AcousticPreset = "Room"
local envGain = 1
-- Current numeric values per chain slot (shared by every environment bus) and the active fade.
local current: { { [string]: number } } = {}
local currentAmbience: { [string]: number } = {}
local fade: {
	from: { { [string]: number } },
	to: { { [string]: number } },
	fromAmbience: { [string]: number },
	toAmbience: { [string]: number },
	fromGain: number,
	toGain: number,
	startedAt: number,
	duration: number,
}? =
	nil
local stepConnection: RBXScriptConnection? = nil

local AudioBuses = {}

AudioBuses.Buses = Enums.AudioBus
AudioBuses.EnvironmentBuses = ENVIRONMENT_BUSES
AudioBuses.Chain = CHAIN
AudioBuses.Environments = ENVIRONMENTS

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

local function newEffect(kind: SynthPresets.EffectKind): SoundEffect
	local spec = SynthPresets.Effects[kind]
	local effect = Instance.new(spec.className :: any) :: SoundEffect
	effect.Name = kind
	for prop, value in spec.defaults do
		(effect :: any)[prop] = value
	end
	return effect
end

local function writeProps(effect: SoundEffect, kind: SynthPresets.EffectKind, props: { [string]: number })
	for prop, value in props do
		(effect :: any)[prop] = SynthPresets.clampEffectProp(kind, prop, value)
	end
end

local function isNeutral(kind: SynthPresets.EffectKind, props: { [string]: number }): boolean
	local neutral = NEUTRAL[kind]
	if not neutral then
		return false
	end
	for prop, value in neutral do
		local actual = props[prop]
		if actual == nil or math.abs(actual - value) > 1e-3 then
			return false
		end
	end
	return true
end

-- Creates the whole group tree under `parent` (no module state is touched; specs build into a scratch folder).
function AudioBuses.build(parent: Instance): Tree
	local master = Instance.new("SoundGroup")
	master.Name = MASTER_NAME
	master.Volume = 1

	-- Safety limiter: a screech over thunder over a slam must never clip on phone speakers.
	local masterCompressor = Instance.new("CompressorSoundEffect")
	masterCompressor.Name = "Limiter"
	masterCompressor.Threshold = -12
	masterCompressor.Ratio = 6
	masterCompressor.Attack = 0.005
	masterCompressor.Release = 0.25
	masterCompressor.GainMakeup = 2
	masterCompressor.Priority = 0
	masterCompressor.Parent = master

	local groups: { [Enums.AudioBus]: SoundGroup } = {}
	local chains: { [Enums.AudioBus]: { SoundEffect } } = {}
	local ambienceEq: EqualizerSoundEffect? = nil
	for _, bus: Enums.AudioBus in Enums.AudioBus do
		local group = Instance.new("SoundGroup")
		group.Name = bus
		group.Volume = 1
		group.Parent = master
		groups[bus] = group
		if table.find(ENVIRONMENT_BUSES, bus) then
			local chain: { SoundEffect } = {}
			for index, kind: SynthPresets.EffectKind in CHAIN do
				local effect = newEffect(kind)
				effect.Priority = #CHAIN - index + 1 -- first in the chain = highest priority
				effect.Parent = group
				chain[index] = effect
			end
			chains[bus] = chain
		elseif bus == "Ambience" then
			local effect = Instance.new("EqualizerSoundEffect")
			effect.Name = "Equalizer"
			effect.LowGain = 0
			effect.MidGain = 0
			effect.HighGain = 0
			effect.Priority = 1
			effect.Parent = group
			ambienceEq = effect
		end
	end
	assert(ambienceEq, "Ambience bus missing from Enums.AudioBus")

	master.Parent = parent
	return {
		master = master,
		groups = groups,
		masterCompressor = masterCompressor,
		chains = chains,
		ambienceEq = ambienceEq,
	}
end

-- Writes an environment's values onto a tree immediately (no fade; does not touch module state).
function AudioBuses.applyEnvironment(target: Tree, preset: Enums.AcousticPreset)
	local spec = ENVIRONMENTS[preset] or ROOM
	for _, bus: Enums.AudioBus in ENVIRONMENT_BUSES do
		local chain = target.chains[bus]
		for index, kind: SynthPresets.EffectKind in CHAIN do
			local effect = chain[index]
			local props = spec.effects[index].props
			writeProps(effect, kind, props)
			effect.Enabled = not isNeutral(kind, props)
		end
	end
	writeProps(target.ambienceEq, "Equalizer", spec.ambience.props)
	target.ambienceEq.Enabled = not isNeutral("Equalizer", spec.ambience.props)
end

--------------------------------------------------------------------------------
-- Volumes and ducking
--------------------------------------------------------------------------------

local function duckGain(bus: Enums.AudioBus, now: number): number
	local list = ducks[bus]
	if not list then
		return 1
	end
	local gain = 1
	local index = 1
	while index <= #list do
		local entry = list[index]
		local t = now - entry.startedAt
		local depth: number
		if t < entry.attack then
			depth = if entry.attack > 0 then t / entry.attack else 1
		elseif t < entry.attack + entry.hold then
			depth = 1
		elseif t < entry.attack + entry.hold + entry.release then
			depth = 1 - (t - entry.attack - entry.hold) / math.max(entry.release, 1e-3)
		else
			table.remove(list, index)
			continue
		end
		gain = math.min(gain, MathUtil.lerp(1, entry.gain, depth))
		index += 1
	end
	if #list == 0 then
		ducks[bus] = nil
	end
	return gain
end

local function applyVolumes(now: number)
	local built = tree
	if not built then
		return
	end
	built.master.Volume = userVolume.Master or 1
	for _, bus: Enums.AudioBus in Enums.AudioBus do
		local gain = (userVolume[bus] or 1) * duckGain(bus, now)
		if table.find(ENVIRONMENT_BUSES, bus) then
			gain *= envGain
		end
		built.groups[bus].Volume = math.clamp(gain, 0, 10)
	end
end

--------------------------------------------------------------------------------
-- Environment fades
--------------------------------------------------------------------------------

local function snapshot(spec: EnvironmentSpec): ({ { [string]: number } }, { [string]: number })
	local slots: { { [string]: number } } = {}
	for index, effect in spec.effects do
		slots[index] = table.clone(effect.props)
	end
	return slots, table.clone(spec.ambience.props)
end

local function writeCurrent(enableAll: boolean)
	local built = tree
	if not built then
		return
	end
	for _, bus: Enums.AudioBus in ENVIRONMENT_BUSES do
		local chain = built.chains[bus]
		for index, kind: SynthPresets.EffectKind in CHAIN do
			local effect = chain[index]
			local props = current[index]
			writeProps(effect, kind, props)
			effect.Enabled = enableAll or not isNeutral(kind, props)
		end
	end
	writeProps(built.ambienceEq, "Equalizer", currentAmbience)
	built.ambienceEq.Enabled = enableAll or not isNeutral("Equalizer", currentAmbience)
end

local function lerpProps(from: { [string]: number }, to: { [string]: number }, alpha: number): { [string]: number }
	local out: { [string]: number } = {}
	for prop, target in to do
		local start = from[prop]
		out[prop] = if start == nil then target else MathUtil.lerp(start, target, alpha)
	end
	return out
end

local function step()
	local now = os.clock()
	local active = fade
	if active then
		local alpha = MathUtil.smoothstep(0, 1, (now - active.startedAt) / math.max(active.duration, 1e-3))
		for index in CHAIN do
			local props = lerpProps(active.from[index], active.to[index], alpha)
			-- Delay jumps instead of sweeping (a swept delay line is an audible pitch smear).
			if active.to[index].Delay ~= nil then
				props.Delay = active.to[index].Delay
			end
			current[index] = props
		end
		currentAmbience = lerpProps(active.fromAmbience, active.toAmbience, alpha)
		envGain = MathUtil.lerp(active.fromGain, active.toGain, alpha)
		local finished = alpha >= 1
		writeCurrent(not finished)
		if finished then
			fade = nil
		end
	end
	applyVolumes(now)
	if fade == nil and next(ducks) == nil then
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

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Builds the client mixer under SoundService (idempotent). Client only: the server never makes audio.
function AudioBuses.setup()
	if tree ~= nil then
		return
	end
	if not RunService:IsClient() then
		log.warnThrottled("server", 60, "AudioBuses.setup called on the server; the mixer is client-only")
		return
	end
	local stale = SoundService:FindFirstChild(MASTER_NAME)
	if stale and stale:IsA("SoundGroup") then
		stale:Destroy()
	end
	for _, setting in SettingsSchema.List do
		for bus, key in SETTING_KEYS do
			if setting.key == key and setting.kind == "Number" then
				userVolume[bus] = setting.default
			end
		end
	end
	tree = AudioBuses.build(SoundService)
	local spec = ENVIRONMENTS[environmentName]
	current, currentAmbience = snapshot(spec)
	envGain = spec.gain
	writeCurrent(false)
	applyVolumes(os.clock())
end

function AudioBuses.isReady(): boolean
	return tree ~= nil
end

local function ready(): Tree
	if tree == nil then
		AudioBuses.setup()
	end
	local built = tree
	assert(built, "AudioBuses is client-only")
	return built
end

function AudioBuses.group(bus: Enums.AudioBus): SoundGroup
	return ready().groups[bus]
end

function AudioBuses.master(): SoundGroup
	return ready().master
end

-- User volume for a bus (or "Master"), 0..1 from settings (values up to 2 are accepted for boosts).
function AudioBuses.setVolume(bus: BusName, volume: number)
	if bus ~= "Master" and not Enums.has(Enums.AudioBus, bus) then
		log.warnThrottled("bus" .. tostring(bus), 30, "setVolume: unknown bus %s", tostring(bus))
		return
	end
	if type(volume) ~= "number" or volume ~= volume then
		return
	end
	userVolume[bus] = math.clamp(volume, 0, 2)
	applyVolumes(os.clock())
end

function AudioBuses.getVolume(bus: BusName): number
	return userVolume[bus] or 1
end

-- Fades the room acoustics of World / Player / Monster (and the Ambience EQ) to `preset` over `fadeSeconds`.
function AudioBuses.setEnvironment(preset: Enums.AcousticPreset, fadeSeconds: number?)
	local spec = ENVIRONMENTS[preset]
	if not spec then
		log.warnThrottled("env" .. tostring(preset), 30, "unknown acoustic preset %s", tostring(preset))
		return
	end
	if preset == environmentName and fade == nil then
		return
	end
	environmentName = preset
	if tree == nil then
		-- Remembered; applied when setup() builds the tree.
		return
	end
	local duration = fadeSeconds or DEFAULT_FADE
	local toSlots, toAmbience = snapshot(spec)
	if duration <= 0 then
		fade = nil
		current, currentAmbience = toSlots, toAmbience
		envGain = spec.gain
		writeCurrent(false)
		applyVolumes(os.clock())
		return
	end
	local fromSlots: { { [string]: number } } = {}
	for index in CHAIN do
		fromSlots[index] = table.clone(current[index])
	end
	fade = {
		from = fromSlots,
		to = toSlots,
		fromAmbience = table.clone(currentAmbience),
		toAmbience = toAmbience,
		fromGain = envGain,
		toGain = spec.gain,
		startedAt = os.clock(),
		duration = duration,
	}
	writeCurrent(true)
	ensureStepping()
end

function AudioBuses.getEnvironment(): Enums.AcousticPreset
	return environmentName
end

-- Dips `bus` to `gain` (0..1) with an attack / hold / release shape. Overlapping ducks take the deepest dip.
function AudioBuses.duck(bus: Enums.AudioBus, gain: number, attack: number, hold: number, release: number)
	if not Enums.has(Enums.AudioBus, bus) or tree == nil then
		return
	end
	local list = ducks[bus]
	if not list then
		list = {}
		ducks[bus] = list
	end
	table.insert(list, {
		gain = math.clamp(gain, 0, 1),
		attack = math.max(attack, 0),
		hold = math.max(hold, 0),
		release = math.max(release, 0),
		startedAt = os.clock(),
	})
	ensureStepping()
end

return table.freeze(AudioBuses)
