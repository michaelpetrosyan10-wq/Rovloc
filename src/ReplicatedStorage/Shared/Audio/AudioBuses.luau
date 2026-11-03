--!strict
-- Client-local mixer: a SoundGroup tree under SoundService and the room acoustics applied to it.
--
--   SoundService
--   └── Master (SoundGroup, safety compressor)
--       ├── Ambience   beds and stingers (only an EQ: muffled underwater / in ducts)
--       ├── Room       the environment chain (EQ, Chorus, Reverb, Echo), shared by the three buses below
--       │   ├── World      props, doors, traps, weather on location
--       │   ├── Monster    the Creature
--       │   └── Player     footsteps, gasps, crawling: sounds bodies make out in the world
--       ├── Body       inside the listener: heartbeat, breathing, EMF static (only an EQ, never room reverb)
--       └── UI         interface clicks (dry)
--
-- Environment DSP: every Enums.AcousticPreset maps to values for one fixed chain on the Room group (Equalizer ->
-- Chorus -> Reverb -> Echo), which World / Monster / Player route through: one chain for all three instead of a
-- copy per bus. Every preset sets every property, with "off" written as neutral values (0 dB EQ, Chorus Mix 0,
-- WetLevel -80), so switching rooms is a smooth interpolation of numbers, never a swap of instances. Effects that sit
-- fully neutral after a fade are disabled to save DSP. Ambience and Body only follow the environment through an EQ
-- (muffled underwater and in ducts), so a heartbeat never smears into a basement-long tail.
--
-- Final group volume = user volume (SettingsSchema, set by SettingsController via setVolume; Body follows the
-- Player volume unless set on its own) x duck gain (presets dip other buses: a screech pulls the ambience down);
-- the environment gain (underwater is quieter) sits on Room.

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
	body: SynthPresets.Effect, -- Equalizer on the Body group
	gain: number, -- multiplier on the Room group (underwater is quieter)
}

export type Tree = {
	master: SoundGroup,
	room: SoundGroup, -- carries the environment chain; World / Monster / Player are its children
	groups: { [Enums.AudioBus]: SoundGroup },
	masterCompressor: CompressorSoundEffect,
	chain: { SoundEffect }, -- the environment chain on Room, CHAIN order
	ambienceEq: EqualizerSoundEffect,
	bodyEq: EqualizerSoundEffect,
}

type DuckState = { gain: number, attack: number, hold: number, release: number, startedAt: number }

local MASTER_NAME = "Master"
local ROOM_NAME = "Room"
local CHAIN: { SynthPresets.EffectKind } = { "Equalizer", "Chorus", "Reverb", "Echo" }
local ECHO_SLOT = 4
local ENVIRONMENT_BUSES: { Enums.AudioBus } = { "World", "Player", "Monster" }
local DEFAULT_FADE = 0.8
-- An echo at or below this wet level is inaudible, so its Delay may jump without a click.
local SILENT_WET = -79

local SETTING_KEYS: { [string]: string } = {
	Master = "MasterVolume",
	Ambience = "AmbienceVolume",
	World = "WorldVolume",
	Monster = "MonsterVolume",
	Player = "PlayerVolume",
	UI = "UIVolume",
}
-- Buses without a setting of their own follow another bus's user volume until setVolume addresses them directly.
local FOLLOWS: { [string]: string } = { Body = "Player" }

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

local FLAT = eq(0, 0, 0)

local function environment(
	envEq: SynthPresets.Effect,
	envChorus: SynthPresets.Effect,
	envReverb: SynthPresets.Effect,
	envEcho: SynthPresets.Effect,
	ambience: SynthPresets.Effect,
	gain: number,
	body: SynthPresets.Effect?
): EnvironmentSpec
	return {
		effects = { envEq, envChorus, envReverb, envEcho },
		ambience = ambience,
		body = body or FLAT,
		gain = gain,
	}
end

-- Classrooms, offices, storage: a short, damped room. Also the fallback for unknown presets.
local ROOM = environment(FLAT, NO_CHORUS, reverb(0.9, -14, 0, 0.8, 0.9), echo(NO_ECHO_DELAY, 0, -80, 0), FLAT, 1)

local ENVIRONMENTS: { [Enums.AcousticPreset]: EnvironmentSpec } = {
	Room = ROOM,
	-- Long corridors: a longer tail and a faint flutter between the parallel walls.
	Corridor = environment(eq(0, 0, -1), NO_CHORUS, reverb(1.8, -11, 0, 0.9, 0.7), echo(0.09, 0.2, -20, 0), FLAT, 1),
	-- Gym and pool hall: a huge tail and a late slap off the far wall.
	Hall = environment(eq(1, 0, -2), NO_CHORUS, reverb(4.5, -7, 0, 1, 0.9), echo(0.28, 0.25, -16, 0), FLAT, 1),
	-- Inside a duct: boxy, metallic, a tight comb echo ringing in the bore. Your own body sounds boxed in too.
	Vent = environment(
		eq(-6, 4, -8),
		NO_CHORUS,
		reverb(0.6, -6, 0, 0.4, 0.2),
		echo(0.035, 0.55, -7, 0),
		eq(-4, -2, -10),
		1,
		eq(1, -1, -4)
	),
	-- Submerged: heavy low-pass muffle with a slow pressure wobble; the world goes quiet. The heartbeat stays (it is
	-- heard through the body), only dulled.
	Underwater = environment(
		eq(4, -26, -60),
		chorus(0.6, 0.35, 0.5),
		reverb(2.5, -4, -6, 1, 1),
		echo(NO_ECHO_DELAY, 0, -80, 0),
		eq(2, -24, -60),
		0.75,
		eq(4, -10, -30)
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

type Props = { [string]: number }

local tree: Tree? = nil
local userVolume: { [string]: number } = {}
local explicitVolume: { [string]: boolean } = {}
local ducks: { [Enums.AudioBus]: { DuckState } } = {}
local environmentName: Enums.AcousticPreset = "Room"
local envGain = 1
-- Current numeric values per chain slot and of the two EQs, and the active fade.
local current: { Props } = {}
local currentAmbience: Props = {}
local currentBody: Props = {}
local fade: {
	from: { Props },
	to: { Props },
	fromAmbience: Props,
	toAmbience: Props,
	fromBody: Props,
	toBody: Props,
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

local function writeProps(effect: SoundEffect, kind: SynthPresets.EffectKind, props: Props)
	for prop, value in props do
		(effect :: any)[prop] = SynthPresets.clampEffectProp(kind, prop, value)
	end
end

local function isNeutral(kind: SynthPresets.EffectKind, props: Props): boolean
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

local function newEq(name: string, parent: Instance): EqualizerSoundEffect
	local effect = Instance.new("EqualizerSoundEffect")
	effect.Name = name
	effect.LowGain = 0
	effect.MidGain = 0
	effect.HighGain = 0
	effect.Priority = 1
	effect.Parent = parent
	return effect
end

local function newGroup(name: string, parent: Instance): SoundGroup
	local group = Instance.new("SoundGroup")
	group.Name = name
	group.Volume = 1
	group.Parent = parent
	return group
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

	local room = newGroup(ROOM_NAME, master)
	local chain: { SoundEffect } = {}
	for index, kind: SynthPresets.EffectKind in CHAIN do
		local effect = newEffect(kind)
		effect.Priority = #CHAIN - index + 1 -- first in the chain = highest priority
		effect.Parent = room
		chain[index] = effect
	end

	local groups: { [Enums.AudioBus]: SoundGroup } = {}
	local ambienceEq: EqualizerSoundEffect? = nil
	local bodyEq: EqualizerSoundEffect? = nil
	for _, bus: Enums.AudioBus in Enums.AudioBus do
		local routed = table.find(ENVIRONMENT_BUSES, bus) ~= nil
		local group = newGroup(bus, if routed then room else master)
		groups[bus] = group
		if bus == "Ambience" then
			ambienceEq = newEq("Equalizer", group)
		elseif bus == "Body" then
			bodyEq = newEq("Equalizer", group)
		end
	end
	assert(ambienceEq, "Ambience bus missing from Enums.AudioBus")
	assert(bodyEq, "Body bus missing from Enums.AudioBus")

	master.Parent = parent
	return {
		master = master,
		room = room,
		groups = groups,
		masterCompressor = masterCompressor,
		chain = chain,
		ambienceEq = ambienceEq,
		bodyEq = bodyEq,
	}
end

local function writeEq(effect: EqualizerSoundEffect, props: Props, enableAll: boolean)
	writeProps(effect, "Equalizer", props)
	effect.Enabled = enableAll or not isNeutral("Equalizer", props)
end

-- Writes an environment's values onto a tree immediately (no fade; does not touch module state).
function AudioBuses.applyEnvironment(target: Tree, preset: Enums.AcousticPreset)
	local spec = ENVIRONMENTS[preset] or ROOM
	for index, kind: SynthPresets.EffectKind in CHAIN do
		local effect = target.chain[index]
		local props = spec.effects[index].props
		writeProps(effect, kind, props)
		effect.Enabled = not isNeutral(kind, props)
	end
	writeEq(target.ambienceEq, spec.ambience.props, false)
	writeEq(target.bodyEq, spec.body.props, false)
end

-- The echo Delay to hold during a fade from one Echo setting to another. A delay line that jumps while it is
-- audible clicks, so: entering an echo from silence jumps to the new delay at once (nothing is ringing yet);
-- fading an echo out to silence keeps the old delay until the fade has finished; between two audible echoes the
-- delay jumps at the start of the fade (sweeping it would smear the pitch of everything in the line).
function AudioBuses.fadeDelay(from: Props, to: Props, alpha: number): number
	local toDelay = to.Delay or from.Delay or NO_ECHO_DELAY
	local fromDelay = from.Delay or toDelay
	local fromSilent = (from.WetLevel or -80) <= SILENT_WET
	local toSilent = (to.WetLevel or -80) <= SILENT_WET
	if toSilent and not fromSilent and alpha < 1 then
		return fromDelay
	end
	return toDelay
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

local function userGain(bus: string): number
	local followed = FOLLOWS[bus]
	if followed and not explicitVolume[bus] then
		return userVolume[followed] or 1
	end
	return userVolume[bus] or 1
end

local function applyVolumes(now: number)
	local built = tree
	if not built then
		return
	end
	built.master.Volume = userVolume.Master or 1
	built.room.Volume = math.clamp(envGain, 0, 10)
	for _, bus: Enums.AudioBus in Enums.AudioBus do
		built.groups[bus].Volume = math.clamp(userGain(bus) * duckGain(bus, now), 0, 10)
	end
end

--------------------------------------------------------------------------------
-- Environment fades
--------------------------------------------------------------------------------

local function snapshot(spec: EnvironmentSpec): ({ Props }, Props, Props)
	local slots: { Props } = {}
	for index, effect in spec.effects do
		slots[index] = table.clone(effect.props)
	end
	return slots, table.clone(spec.ambience.props), table.clone(spec.body.props)
end

local function writeCurrent(enableAll: boolean)
	local built = tree
	if not built then
		return
	end
	for index, kind: SynthPresets.EffectKind in CHAIN do
		local effect = built.chain[index]
		local props = current[index]
		writeProps(effect, kind, props)
		effect.Enabled = enableAll or not isNeutral(kind, props)
	end
	writeEq(built.ambienceEq, currentAmbience, enableAll)
	writeEq(built.bodyEq, currentBody, enableAll)
end

local function lerpProps(from: Props, to: Props, alpha: number): Props
	local out: Props = {}
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
			if index == ECHO_SLOT then
				props.Delay = AudioBuses.fadeDelay(active.from[index], active.to[index], alpha)
			end
			current[index] = props
		end
		currentAmbience = lerpProps(active.fromAmbience, active.toAmbience, alpha)
		currentBody = lerpProps(active.fromBody, active.toBody, alpha)
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
			if setting.key == key and setting.kind == "Number" and userVolume[bus] == nil then
				userVolume[bus] = setting.default
			end
		end
	end
	tree = AudioBuses.build(SoundService)
	local spec = ENVIRONMENTS[environmentName]
	current, currentAmbience, currentBody = snapshot(spec)
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
	explicitVolume[bus] = true
	applyVolumes(os.clock())
end

-- The user volume a bus plays at (a following bus reports the volume it follows until set directly).
function AudioBuses.getVolume(bus: BusName): number
	return userGain(bus)
end

-- Fades the room acoustics (the Room chain, the Ambience and Body EQs, the environment gain) to `preset` over
-- `fadeSeconds`.
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
	local toSlots, toAmbience, toBody = snapshot(spec)
	if duration <= 0 then
		fade = nil
		current, currentAmbience, currentBody = toSlots, toAmbience, toBody
		envGain = spec.gain
		writeCurrent(false)
		applyVolumes(os.clock())
		return
	end
	local fromSlots: { Props } = {}
	for index in CHAIN do
		fromSlots[index] = table.clone(current[index])
	end
	fade = {
		from = fromSlots,
		to = toSlots,
		fromAmbience = table.clone(currentAmbience),
		toAmbience = toAmbience,
		fromBody = table.clone(currentBody),
		toBody = toBody,
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
