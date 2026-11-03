--!strict
-- AudioController: everything the client hears that it was not explicitly asked to play by another controller.
--
--   * Mixer: AudioBuses + VoicePool are set up in Init (the SoundGroup tree, pools, length probes).
--   * Cues: AudioCue from AudioService plays in sync with server time. Early cues wait until startAt. A cue up to
--     LATE_SNAP late plays from its start (a quarter second of network jitter is not worth losing the attack);
--     later ones start part-way through (startOffset = now - startAt); one-shots later than
--     GameConfig.OneShotMaxLate are dropped (looped presets always start, fast-forwarded: late joiners get the
--     server's active loops re-sent with their original startAt). Every cue has an id; AudioStop { id, fade } fades
--     that voice out, or cancels it if it is still waiting to start.
--   * Acoustics: 5 Hz client point-in-box against the Zone parts finds the listener's room; its AcousticPreset
--     drives AudioBuses.setEnvironment. A move state overrides it (in a duct -> Vent, submerged -> Underwater) and
--     SetEnvironmentOverride (later phases: vent transitions, cutscenes) overrides both. No zone = Outdoor.
--   * Ambience bed: the level's layout.ambience drone (the room the listener stands in decides; otherwise
--     CurrentLevel during a run; the Lobby bed between runs), crossfaded on change, with the bed's stingers
--     (SynthPresets.Beds) scattered around the listener at seeded random intervals. Submerged -> UnderwaterBed.
--   * Emitters: AmbientEmitter (attr Preset) and DripPipe parts near the listener get looping voices; only the
--     nearest MAX_EMITTER_VOICES within each preset's rollOff play at once.
--   * Volumes: AudioBuses applies the SettingsSchema defaults; the P3 SettingsController calls AudioBuses.setVolume.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local AudioBuses = require(ReplicatedStorage.Shared.Audio.AudioBuses)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local SoundSynthesizer = require(ReplicatedStorage.Shared.Audio.SoundSynthesizer)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local VoicePool = require(ReplicatedStorage.Shared.Audio.VoicePool)

local log = Log.new("AudioController")

local W = Attributes.World
local M = Attributes.Match
local P = Attributes.Player

local ZONE_INTERVAL = 0.2
local EMITTER_INTERVAL = 0.5
local BED_INTERVAL = 0.5
local MAX_EMITTER_VOICES = 8
local EMITTER_HYSTERESIS = 0.85 -- active emitters rank as if this much closer (no flapping at the boundary)
local EMITTER_FADE_IN = 0.8
local EMITTER_FADE_OUT = 0.6
local ENV_FADE = 0.8
local ENV_FADE_FAST = 0.25
local BED_FADE = 3
local BED_FADE_FAST = 0.6
local STINGER_HEIGHT = 4
local LOOP_CUE_FADE = 0.4
local STOP_FADE = 0.4
local MAX_STOP_FADE = 10
local LATE_SNAP = 0.25
local UNDERWATER_BED = "UnderwaterBed"
local DRIP_PRESET = "Drip"
local LOBBY_LAYOUT = "Lobby"
local RUN_PHASES: { Enums.MatchPhase } = { "Deploying", "InRun", "RunEnded" }

type EmitterCandidate = { instance: Instance, preset: string, distance: number }

local AudioController = {}

AudioController.Name = "AudioController"
AudioController.MaxEmitterVoices = MAX_EMITTER_VOICES

local serviceTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local localRandom = Random.new()

-- Acoustics
local override: Enums.AcousticPreset? = nil
local zones: { BasePart } = {}
local zonesByLevel: { [string]: { BasePart } } = {}
local zoneLevel: { [BasePart]: string } = {}
local currentZone: BasePart? = nil

-- Ambience bed
local bedName: string? = nil
local bedVoice: SoundSynthesizer.Voice? = nil
local stingerTimes: { number } = {}
local ambienceByLayout: { [string]: string } = {}

-- Emitters
local emitters: { [Instance]: boolean } = {}
local emitterVoices: { [Instance]: SoundSynthesizer.Voice } = {}

-- Cues by id: voices playing, and cues still waiting for their startAt (true = cancelled by AudioStop).
local cueVoices: { [number]: SoundSynthesizer.Voice } = {}
local waitingCues: { [number]: boolean } = {}

local zoneClock = 0
local emitterClock = 0
local bedClock = 0

--------------------------------------------------------------------------------
-- Listener
--------------------------------------------------------------------------------

local function characterRoot(): BasePart?
	local player = localPlayer
	local character = if player then player.Character else nil
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- Where "I" am for acoustics and ambience: my character, else the camera (spectating, loading, cutscenes).
local function listenerPoint(): Vector3
	local root = characterRoot()
	if root then
		return root.Position
	end
	return VoicePool.listenerPosition()
end

local function localMoveState(): string
	local player = localPlayer
	if not player then
		return ""
	end
	return Attributes.getString(player, P.MoveState, "")
end

--------------------------------------------------------------------------------
-- Zones and acoustics
--------------------------------------------------------------------------------

local function addZone(instance: Instance)
	if not instance:IsA("BasePart") or zoneLevel[instance] ~= nil then
		return
	end
	local level = Attributes.getString(instance, W.LevelId, "")
	zoneLevel[instance] = level
	table.insert(zones, instance)
	local bucket = zonesByLevel[level]
	if not bucket then
		bucket = {}
		zonesByLevel[level] = bucket
	end
	table.insert(bucket, instance)
end

local function removeZone(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local level = zoneLevel[instance]
	if level == nil then
		return
	end
	zoneLevel[instance] = nil
	local index = table.find(zones, instance)
	if index then
		table.remove(zones, index)
	end
	local bucket = zonesByLevel[level]
	if bucket then
		local bucketIndex = table.find(bucket, instance)
		if bucketIndex then
			table.remove(bucket, bucketIndex)
		end
	end
	if currentZone == instance then
		currentZone = nil
	end
end

local function findIn(list: { BasePart }?, point: Vector3, skip: BasePart?): BasePart?
	if not list then
		return nil
	end
	for _, zone in list do
		if zone ~= skip and zone.Parent ~= nil and SpatialQuery.pointInPart(zone, point) then
			return zone
		end
	end
	return nil
end

-- The Zone part containing `point`: last zone first, then the zones of the same level, then every zone.
local function zoneAt(point: Vector3): BasePart?
	local last = currentZone
	if last and last.Parent ~= nil and SpatialQuery.pointInPart(last, point) then
		return last
	end
	local level = if last then zoneLevel[last] else nil
	local found = if level then findIn(zonesByLevel[level], point, last) else nil
	if found then
		return found
	end
	return findIn(zones, point, nil)
end

local function zonePreset(zone: BasePart?): Enums.AcousticPreset
	if zone == nil then
		return "Outdoor"
	end
	local value = Attributes.getString(zone, W.AcousticPreset, "Room")
	if Enums.has(Enums.AcousticPreset, value) then
		return value :: Enums.AcousticPreset
	end
	return "Room"
end

local function movePreset(): Enums.AcousticPreset?
	local moveState = localMoveState()
	if moveState == "VentCrawling" or moveState == "VentScurrying" then
		return "Vent"
	elseif moveState == "Underwater" then
		return "Underwater"
	end
	return nil
end

local function desiredEnvironment(): Enums.AcousticPreset
	local forced: Enums.AcousticPreset? = override
	if forced ~= nil then
		return forced :: Enums.AcousticPreset
	end
	local fromMove: Enums.AcousticPreset? = movePreset()
	if fromMove ~= nil then
		return fromMove :: Enums.AcousticPreset
	end
	return zonePreset(currentZone)
end

local function refreshEnvironment(fast: boolean)
	local target: Enums.AcousticPreset = desiredEnvironment()
	if target ~= AudioBuses.getEnvironment() then
		AudioBuses.setEnvironment(target, if fast then ENV_FADE_FAST else ENV_FADE)
	end
end

--------------------------------------------------------------------------------
-- Ambience bed
--------------------------------------------------------------------------------

local function layoutAmbience(layoutId: string): string?
	local cached = ambienceByLayout[layoutId]
	if cached then
		return cached
	end
	local layout = Builder.getLayout(layoutId)
	if not layout then
		return nil
	end
	local name = layout.ambience
	if not SoundSynthesizer.has(name) then
		log.warnThrottled("bed" .. layoutId, 60, "layout %s ambience %s is not a preset", layoutId, tostring(name))
		return nil
	end
	ambienceByLayout[layoutId] = name
	return name
end

local function desiredBed(): string?
	if localMoveState() == "Underwater" then
		return UNDERWATER_BED
	end
	local zone = currentZone
	if zone then
		local level = zoneLevel[zone] or ""
		if level ~= "" then
			local fromZone = layoutAmbience(level)
			if fromZone then
				return fromZone
			end
		end
	end
	local phase = Attributes.getString(ReplicatedStorage, M.MatchPhase, "Booting")
	local level = Attributes.getString(ReplicatedStorage, M.CurrentLevel, "")
	if level ~= "" and table.find(RUN_PHASES, phase :: any) ~= nil then
		local fromLevel = layoutAmbience(level)
		if fromLevel then
			return fromLevel
		end
	end
	return layoutAmbience(LOBBY_LAYOUT)
end

local function resetStingers(name: string?)
	table.clear(stingerTimes)
	local stingers = if name then SynthPresets.Beds[name] else nil
	if not stingers then
		return
	end
	local now = os.clock()
	for index, stinger in stingers do
		stingerTimes[index] = now + localRandom:NextNumber(stinger.interval.min, stinger.interval.max)
	end
end

local function refreshBed()
	local target = desiredBed()
	local voice = bedVoice
	if target == bedName and (target == nil or (voice ~= nil and voice:IsPlaying())) then
		return
	end
	local fast = target == UNDERWATER_BED or bedName == UNDERWATER_BED
	local fade = if fast then BED_FADE_FAST else BED_FADE
	if voice then
		voice:Stop(fade)
		bedVoice = nil
	end
	bedName = target
	resetStingers(target)
	if target == nil then
		return
	end
	local started = SoundSynthesizer.play(target, { fadeIn = fade, looped = true })
	bedVoice = started
	if not started then
		log.warnThrottled("bedStart" .. target, 30, "ambience bed %s could not start", target)
	end
end

local function playStingers()
	local name = bedName
	local stingers = if name then SynthPresets.Beds[name] else nil
	if not stingers then
		return
	end
	local now = os.clock()
	for index, stinger in stingers do
		local due = stingerTimes[index]
		if due == nil or now < due then
			continue
		end
		stingerTimes[index] = now + localRandom:NextNumber(stinger.interval.min, stinger.interval.max)
		local options: SoundSynthesizer.PlayOptions = {
			volume = stinger.volume,
			seed = localRandom:NextInteger(1, 2_147_483_646),
		}
		local distance = stinger.distance
		if distance then
			local angle = localRandom:NextNumber(0, math.pi * 2)
			local radius = localRandom:NextNumber(distance.min, distance.max)
			local height = localRandom:NextNumber(-STINGER_HEIGHT * 0.5, STINGER_HEIGHT)
			options.position = listenerPoint() + Vector3.new(math.cos(angle) * radius, height, math.sin(angle) * radius)
		end
		SoundSynthesizer.play(stinger.preset, options)
	end
end

--------------------------------------------------------------------------------
-- Emitters
--------------------------------------------------------------------------------

local function emitterPreset(instance: Instance): string?
	local named = instance:GetAttribute(W.Preset)
	if type(named) == "string" and SoundSynthesizer.has(named) then
		return named
	end
	if instance:HasTag(Tags.DripPipe) then
		return DRIP_PRESET
	end
	return nil
end

local function emitterPosition(instance: Instance): Vector3?
	if instance:IsA("BasePart") then
		return instance.Position
	elseif instance:IsA("Attachment") then
		return instance.WorldPosition
	elseif instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	return nil
end

local function stopEmitter(instance: Instance, fade: number)
	local voice = emitterVoices[instance]
	if voice then
		emitterVoices[instance] = nil
		voice:Stop(fade)
	end
end

local function addEmitter(instance: Instance)
	emitters[instance] = true
end

local function removeEmitter(instance: Instance)
	if instance.Parent ~= nil and (instance:HasTag(Tags.AmbientEmitter) or instance:HasTag(Tags.DripPipe)) then
		return -- still tagged with the other emitter tag
	end
	emitters[instance] = nil
	stopEmitter(instance, EMITTER_FADE_OUT)
end

local function startEmitter(instance: Instance, preset: string)
	local voice = SoundSynthesizer.play(preset, {
		attach = instance,
		position = emitterPosition(instance),
		looped = true,
		fadeIn = EMITTER_FADE_IN,
		seed = MathUtil.hash(instance:GetFullName()),
	})
	if not voice then
		return
	end
	emitterVoices[instance] = voice
	voice.Ended:Connect(function()
		if emitterVoices[instance] == voice then
			emitterVoices[instance] = nil
		end
	end)
end

local function refreshEmitters()
	local listener = VoicePool.listenerPosition()
	local candidates: { EmitterCandidate } = {}
	for instance in table.clone(emitters) do
		if instance.Parent == nil then
			-- Destroyed or removed: forget it (its tags may still read as present on the dead instance).
			emitters[instance] = nil
			stopEmitter(instance, 0)
			continue
		end
		if not instance:IsDescendantOf(Workspace) then
			continue
		end
		local preset = emitterPreset(instance)
		local position = emitterPosition(instance)
		if not preset or not position then
			continue
		end
		local presetData = SynthPresets.get(preset)
		if not presetData then
			continue
		end
		local distance = (position - listener).Magnitude
		if distance > SynthPresets.rollOff(presetData).max then
			continue
		end
		local rank = if emitterVoices[instance] then distance * EMITTER_HYSTERESIS else distance
		table.insert(candidates, { instance = instance, preset = preset, distance = rank })
	end
	table.sort(candidates, function(a: EmitterCandidate, b: EmitterCandidate): boolean
		return a.distance < b.distance
	end)

	local keep: { [Instance]: string } = {}
	for index = 1, math.min(#candidates, MAX_EMITTER_VOICES) do
		local candidate = candidates[index]
		keep[candidate.instance] = candidate.preset
	end
	for instance, voice in table.clone(emitterVoices) do
		local preset = keep[instance]
		if preset == nil or preset ~= voice.Preset or not voice:IsPlaying() then
			stopEmitter(instance, EMITTER_FADE_OUT)
		end
	end
	for instance, preset in keep do
		if emitterVoices[instance] == nil then
			startEmitter(instance, preset)
		end
	end
end

--------------------------------------------------------------------------------
-- Cues
--------------------------------------------------------------------------------

-- How far into a cue to start it when it arrives `late` seconds after its startAt: small network lateness is not
-- worth skipping the attack for; real lateness (a late joiner, a hitch) is skipped so the voice stays in sync.
function AudioController.cueStartOffset(late: number): number
	if late < LATE_SNAP then
		return 0
	end
	return late
end

local function playCue(cue: Types.AudioCuePayload)
	local id = cue.id
	if waitingCues[id] ~= nil then
		local cancelled = waitingCues[id]
		waitingCues[id] = nil
		if cancelled then
			return -- AudioStop arrived before it started
		end
	end
	local existing = cueVoices[id]
	if existing and existing:IsPlaying() then
		return -- a duplicate (re-sent) cue for a voice that is already playing
	end
	local late = math.max(0, Workspace:GetServerTimeNow() - cue.startAt)
	local duration = cue.duration
	local remaining = if duration then duration - late else nil
	if remaining and remaining <= 0 then
		return -- a timed loop that already finished before this client heard about it
	end
	local attach = cue.attach
	local options: SoundSynthesizer.PlayOptions = {
		seed = cue.seed,
		volume = cue.volume,
		startOffset = AudioController.cueStartOffset(late),
		position = cue.position,
	}
	if attach and attach:IsDescendantOf(Workspace) then
		options.attach = attach
	end
	local voice = SoundSynthesizer.play(cue.preset, options)
	if not voice then
		return
	end
	cueVoices[id] = voice
	voice.Ended:Connect(function()
		if cueVoices[id] == voice then
			cueVoices[id] = nil
		end
	end)
	if remaining and SoundSynthesizer.isLooped(cue.preset) then
		task.delay(remaining, function()
			voice:Stop(LOOP_CUE_FADE)
		end)
	end
end

local function onCue(payload: any)
	if
		type(payload) ~= "table"
		or type(payload.preset) ~= "string"
		or type(payload.startAt) ~= "number"
		or type(payload.id) ~= "number"
	then
		return
	end
	local raw = payload :: { [string]: any }
	local cue: Types.AudioCuePayload = {
		id = raw.id,
		preset = raw.preset,
		position = if typeof(raw.position) == "Vector3" then raw.position else nil,
		attach = if typeof(raw.attach) == "Instance" then raw.attach else nil,
		startAt = raw.startAt,
		seed = if type(raw.seed) == "number" then raw.seed else localRandom:NextInteger(1, 2_147_483_646),
		volume = if type(raw.volume) == "number" then raw.volume else nil,
		duration = if type(raw.duration) == "number" then raw.duration else nil,
	}
	if not SoundSynthesizer.has(cue.preset) then
		log.warnThrottled("cue" .. cue.preset, 30, "AudioCue for unknown preset %s", cue.preset)
		return
	end
	local late = Workspace:GetServerTimeNow() - cue.startAt
	if late > GameConfig.OneShotMaxLate and not SoundSynthesizer.isLooped(cue.preset) then
		return
	end
	if late < 0 then
		if waitingCues[cue.id] == nil then
			waitingCues[cue.id] = false
			task.delay(-late, playCue, cue)
		end
	else
		playCue(cue)
	end
end

local function onStop(payload: any)
	if type(payload) ~= "table" or type(payload.id) ~= "number" then
		return
	end
	local raw = payload :: { [string]: any }
	local id = raw.id :: number
	local fade = if type(raw.fade) == "number" and raw.fade == raw.fade
		then math.clamp(raw.fade, 0, MAX_STOP_FADE)
		else STOP_FADE
	if waitingCues[id] ~= nil then
		waitingCues[id] = true
	end
	local voice = cueVoices[id]
	if voice then
		cueVoices[id] = nil
		voice:Stop(fade)
	end
end

--------------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------------

local function onHeartbeat(dt: number)
	zoneClock += dt
	emitterClock += dt
	bedClock += dt
	if zoneClock >= ZONE_INTERVAL then
		zoneClock = 0
		currentZone = zoneAt(listenerPoint())
		refreshEnvironment(false)
	end
	if bedClock >= BED_INTERVAL then
		bedClock = 0
		refreshBed()
		playStingers()
	end
	if emitterClock >= EMITTER_INTERVAL then
		emitterClock = 0
		refreshEmitters()
	end
end

local function watchTag(tag: string, added: (Instance) -> (), removed: (Instance) -> ())
	serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(tag), added)
	serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(tag), removed)
	for _, instance in CollectionService:GetTagged(tag) do
		added(instance)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function AudioController.Init()
	AudioBuses.setup()
	VoicePool.setup()
end

function AudioController.Start()
	local connection = Net.Client.on("AudioCue", onCue)
	if connection then
		serviceTrove:Add(connection)
	end
	local stopConnection = Net.Client.on("AudioStop", onStop)
	if stopConnection then
		serviceTrove:Add(stopConnection)
	end

	watchTag(Tags.Zone, addZone, removeZone)
	watchTag(Tags.AmbientEmitter, addEmitter, removeEmitter)
	watchTag(Tags.DripPipe, addEmitter, removeEmitter)

	serviceTrove:Connect(ReplicatedStorage:GetAttributeChangedSignal(M.CurrentLevel), refreshBed)
	serviceTrove:Connect(ReplicatedStorage:GetAttributeChangedSignal(M.MatchPhase), refreshBed)
	local player = localPlayer
	if player then
		serviceTrove:Connect(player:GetAttributeChangedSignal(P.MoveState), function()
			refreshEnvironment(true)
			refreshBed()
		end)
	end

	serviceTrove:Connect(RunService.Heartbeat, onHeartbeat)
	currentZone = zoneAt(listenerPoint())
	AudioBuses.setEnvironment(desiredEnvironment(), 0)
	refreshBed()
end

function AudioController.OnRunStarted(_info: Types.RunInfo)
	refreshBed()
end

function AudioController.OnRunEnded()
	-- Run-scoped voices (the Creature, footsteps, heartbeat / breathing / static) end with the run; beds and
	-- emitters stay.
	SoundSynthesizer.stopAll("Monster", 0.5)
	SoundSynthesizer.stopAll("Player", 0.5)
	SoundSynthesizer.stopAll("Body", 0.5)
	refreshBed()
end

-- Plays a preset locally (UI clicks, own footsteps, panic layers). See SoundSynthesizer.PlayOptions.
function AudioController.PlayLocal(preset: string, options: SoundSynthesizer.PlayOptions?): SoundSynthesizer.Voice?
	return SoundSynthesizer.play(preset, options)
end

-- Forces the room acoustics (vent transitions, cutscenes); nil hands control back to zones and move states.
function AudioController.SetEnvironmentOverride(preset: Enums.AcousticPreset?)
	if preset ~= nil and not Enums.has(Enums.AcousticPreset, preset) then
		log.warnThrottled("override" .. tostring(preset), 30, "unknown acoustic preset %s", tostring(preset))
		return
	end
	override = preset
	refreshEnvironment(true)
end

function AudioController.GetEnvironment(): Enums.AcousticPreset
	return AudioBuses.getEnvironment()
end

-- The Zone part the listener stands in (client-side point-in-box), if any.
function AudioController.GetZone(): BasePart?
	return currentZone
end

return table.freeze(AudioController)
