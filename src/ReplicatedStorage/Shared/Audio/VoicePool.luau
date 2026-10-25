--!strict
-- Client voice budget and instance pools for SoundSynthesizer.
--
-- Budget. Every playing voice holds one Slot on its bus. Caps per bus (Monster 6, World 16, Ambience 8, Player 12,
-- UI 6) plus each preset's own maxVoices. When a cap is reached the newcomer may steal a slot: the lowest priority
-- loses first, then the quietest at the listener (authored gain x distance attenuation), then the oldest. A voice
-- that outranks the newcomer is never stolen; the newcomer is refused instead. One-shots placed further from the
-- listener than their rollOff.max are culled before they ever take a slot.
--
-- Pools. Sounds, SoundEffects (per kind) and Attachments are recycled instead of created and destroyed per voice.
-- 3D voices play through a pooled Attachment parented to the attach target (a BasePart, a Model's primary part)
-- or, for bare positions, to one client-local anchor part. An Attachment target hosts the Sounds directly.
-- 2D voices play from a folder in SoundService.
--
-- Measurement. setup() loads one probe Sound per SoundLibrary sample and records each file's real TimeLength, so
-- PlaybackRegions are resolved against the true length (see SoundLibrary.resolveRegion).

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local SoundLibrary = require(ReplicatedStorage.Shared.Audio.SoundLibrary)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)

local log = Log.new("VoicePool")

export type Slot = {
	id: number,
	bus: Enums.AudioBus,
	preset: string,
	priority: number,
	startedAt: number,
	rollOff: SynthPresets.Range?, -- nil for 2D voices
	position: () -> Vector3?, -- current world position (nil = 2D)
	gain: () -> number, -- current authored gain (before distance)
	steal: () -> (), -- stops the voice immediately (short fade) when another voice takes the slot
	active: boolean,
}

export type AdmitRequest = {
	bus: Enums.AudioBus,
	preset: string,
	priority: number,
	maxVoices: number,
	rollOff: SynthPresets.Range?,
	position: () -> Vector3?,
	gain: () -> number,
	steal: () -> (),
	cull: boolean, -- apply the distance pre-cull (one-shots)
}

-- What pickVictim compares (pure data, so the rule is testable without instances).
export type Candidate = { priority: number, audibility: number, startedAt: number }

export type Emitter = {
	parent: Instance, -- where the voice's Sounds are parented
	attachment: Attachment?, -- pooled attachment owned by the voice (returned on release)
	follow: Instance?, -- the instance the voice follows (nil for fixed positions and 2D)
	spatial: boolean,
}

local CAPS: { [Enums.AudioBus]: number } = {
	Monster = 6,
	World = 16,
	Ambience = 8,
	Player = 12,
	UI = 6,
}

local MAX_LIVE_SOUNDS = 160 -- hard ceiling on Sounds in use at once (grain storms degrade, never explode)
local MAX_FREE_SOUNDS = 64
local MAX_FREE_EFFECTS_PER_KIND = 32
local MAX_FREE_ATTACHMENTS = 48
local PROBE_TIMEOUT = 30
local AUDIBILITY_EPSILON = 1e-4

local VoicePool = {}

VoicePool.Caps = table.freeze(CAPS)
VoicePool.MaxLiveSounds = MAX_LIVE_SOUNDS

local isSetUp = false
local freeFolder: Folder? = nil
local voices2D: Folder? = nil
local anchorPart: BasePart? = nil

local slots: { Slot } = {}
local nextSlotId = 0

-- Free Sounds grouped by the file they last held, so a reused Sound rarely has to load anything.
local freeSounds: { [string]: { Sound } } = {}
local freeSoundCount = 0
local soundsInUse = 0
local freeEffects: { [string]: { SoundEffect } } = {}
local freeAttachments: { Attachment } = {}

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

local function folder(name: string, parent: Instance): Folder
	local existing = parent:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	local created = Instance.new("Folder")
	created.Name = name
	created.Parent = parent
	return created
end

local function probeSamples(parent: Instance)
	local probes: { Instance } = {}
	local pending = 0
	for _, key in SoundLibrary.Keys do
		local entry = SoundLibrary.Samples[key]
		local probe = Instance.new("Sound")
		probe.Name = "Probe_" .. key
		probe.Volume = 0
		local finished = false
		local function record()
			if finished then
				return
			end
			if probe.IsLoaded and probe.TimeLength > 0 then
				finished = true
				pending -= 1
				SoundLibrary.recordLength(key, probe.TimeLength)
				probe:Destroy()
			end
		end
		pending += 1
		probe.Loaded:Connect(record)
		probe.SoundId = entry.path
		probe.Parent = parent
		table.insert(probes, probe)
		record()
	end
	-- Ask the engine to load them now (off the calling thread: setup runs inside controller Init).
	task.spawn(function()
		xpcall(function()
			ContentProvider:PreloadAsync(probes)
		end, function(err: any)
			log.warnThrottled("preload", 60, "sample preload failed: %s", tostring(err))
		end)
		for _, probe in probes do
			if probe.Parent ~= nil and probe:IsA("Sound") and probe.IsLoaded then
				local key = SoundLibrary.keyForPath(probe.SoundId)
				if key and not SoundLibrary.isMeasured(key) and probe.TimeLength > 0 then
					SoundLibrary.recordLength(key, probe.TimeLength)
				end
			end
		end
	end)
	task.delay(PROBE_TIMEOUT, function()
		if pending > 0 then
			log.info("%d sample length(s) not measured yet; their catalog estimates stay in use", pending)
		end
		for _, probe in probes do
			if probe.Parent ~= nil then
				probe:Destroy()
			end
		end
	end)
end

-- Creates the pool folders, the 3D anchor part and the length probes. Client only, idempotent, never yields.
function VoicePool.setup()
	if isSetUp then
		return
	end
	if not RunService:IsClient() then
		log.warnThrottled("server", 60, "VoicePool.setup called on the server; voices are client-only")
		return
	end
	isSetUp = true

	local root = folder("RovlocVoices", SoundService)
	freeFolder = folder("Free", root)
	voices2D = folder("Voices2D", root)
	probeSamples(folder("Probes", root))

	local anchorFolder = folder("RovlocAudio", Workspace)
	local part = Instance.new("Part")
	part.Name = "AudioAnchor"
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = CFrame.identity
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.Transparency = 1
	part.Locked = true
	part.Parent = anchorFolder
	anchorPart = part
end

function VoicePool.isReady(): boolean
	return isSetUp
end

--------------------------------------------------------------------------------
-- Listener and audibility
--------------------------------------------------------------------------------

function VoicePool.listenerPosition(): Vector3
	local camera = Workspace.CurrentCamera
	if camera then
		return camera.CFrame.Position
	end
	return Vector3.zero
end

-- Approximate InverseTapered attenuation (1 inside min, inverse falloff, tapered to 0 at max).
function VoicePool.attenuation(distance: number, rollOff: SynthPresets.Range): number
	if distance <= rollOff.min then
		return 1
	end
	if distance >= rollOff.max then
		return 0
	end
	local inverse = rollOff.min / distance
	local taper = 1 - (distance - rollOff.min) / math.max(rollOff.max - rollOff.min, 1e-3)
	return inverse * taper
end

-- True when a sound at `position` would be past its rollOff.max from the listener (do not start it).
function VoicePool.shouldCull(position: Vector3?, rollOff: SynthPresets.Range?): boolean
	if position == nil or rollOff == nil then
		return false
	end
	return (position - VoicePool.listenerPosition()).Magnitude > rollOff.max
end

local function audibility(slot: Slot, listener: Vector3): number
	local gain = slot.gain()
	local rollOff = slot.rollOff
	local position = slot.position()
	if rollOff == nil or position == nil then
		return gain
	end
	return gain * VoicePool.attenuation((position - listener).Magnitude, rollOff)
end

--------------------------------------------------------------------------------
-- Stealing
--------------------------------------------------------------------------------

-- True when `a` should be stolen before `b`: lower priority, else quieter, else older.
local function ranksBelow(a: Candidate, b: Candidate): boolean
	if a.priority ~= b.priority then
		return a.priority < b.priority
	end
	local delta = a.audibility - b.audibility
	if math.abs(delta) > AUDIBILITY_EPSILON then
		return delta < 0
	end
	return a.startedAt < b.startedAt
end

-- Index of the candidate an incoming voice of `incomingPriority` should steal, or nil when every candidate
-- outranks it. Lowest priority first, then the quietest, then the oldest.
function VoicePool.pickVictim(candidates: { Candidate }, incomingPriority: number): number?
	local bestIndex: number? = nil
	local best: Candidate? = nil
	for index, candidate in candidates do
		if candidate.priority > incomingPriority then
			continue
		end
		if best == nil or ranksBelow(candidate, best) then
			best = candidate
			bestIndex = index
		end
	end
	return bestIndex
end

local function removeSlot(slot: Slot)
	slot.active = false
	local index = table.find(slots, slot)
	if index then
		table.remove(slots, index)
	end
end

local function evict(victim: Slot)
	removeSlot(victim)
	xpcall(victim.steal, function(err: any)
		log.warnThrottled("steal", 10, "stealing voice %s failed: %s", victim.preset, tostring(err))
	end)
end

local function stealFrom(pool: { Slot }, incomingPriority: number, listener: Vector3): boolean
	local candidates: { Candidate } = {}
	for index, slot in pool do
		candidates[index] = {
			priority = slot.priority,
			audibility = audibility(slot, listener),
			startedAt = slot.startedAt,
		}
	end
	local victimIndex = VoicePool.pickVictim(candidates, incomingPriority)
	if victimIndex == nil then
		return false
	end
	evict(pool[victimIndex])
	return true
end

-- Reserves a slot for a new voice, stealing one if a cap is full. Nil = culled (too far) or refused (outranked).
function VoicePool.admit(request: AdmitRequest): Slot?
	if request.cull and VoicePool.shouldCull(request.position(), request.rollOff) then
		return nil
	end
	local listener = VoicePool.listenerPosition()

	-- Per-preset cap: a new instance of the same sound always replaces the least audible / oldest one.
	local samePreset: { Slot } = {}
	for _, slot in slots do
		if slot.preset == request.preset then
			table.insert(samePreset, slot)
		end
	end
	if #samePreset >= math.max(1, request.maxVoices) then
		if not stealFrom(samePreset, math.huge, listener) then
			return nil
		end
	end

	-- Bus cap: priority stealing.
	local cap = CAPS[request.bus] or 8
	local onBus: { Slot } = {}
	for _, slot in slots do
		if slot.bus == request.bus then
			table.insert(onBus, slot)
		end
	end
	if #onBus >= cap then
		if not stealFrom(onBus, request.priority, listener) then
			return nil
		end
	end

	nextSlotId += 1
	local slot: Slot = {
		id = nextSlotId,
		bus = request.bus,
		preset = request.preset,
		priority = request.priority,
		startedAt = os.clock(),
		rollOff = request.rollOff,
		position = request.position,
		gain = request.gain,
		steal = request.steal,
		active = true,
	}
	table.insert(slots, slot)
	return slot
end

function VoicePool.release(slot: Slot)
	if slot.active then
		removeSlot(slot)
	end
end

function VoicePool.activeCount(bus: Enums.AudioBus?): number
	if bus == nil then
		return #slots
	end
	local count = 0
	for _, slot in slots do
		if slot.bus == bus then
			count += 1
		end
	end
	return count
end

function VoicePool.soundsInUse(): number
	return soundsInUse
end

--------------------------------------------------------------------------------
-- Sound pool
--------------------------------------------------------------------------------

local function onSoundLoaded(sound: Sound)
	local key = SoundLibrary.keyForPath(sound.SoundId)
	if key and not SoundLibrary.isMeasured(key) and sound.TimeLength > 0 then
		SoundLibrary.recordLength(key, sound.TimeLength)
	end
end

local function resetSound(sound: Sound)
	sound.Looped = false
	sound.PlaybackRegionsEnabled = false
	sound.PlaybackSpeed = 1
	sound.Volume = 0
	sound.TimePosition = 0
	sound.PlayOnRemove = false
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = 10
	sound.RollOffMaxDistance = 100
	-- SoundGroup is left as-is: every grain assigns its bus group before it plays.
end

local function takeFree(path: string): Sound?
	local exact = freeSounds[path]
	if exact and #exact > 0 then
		freeSoundCount -= 1
		return table.remove(exact)
	end
	for _, list in freeSounds do
		if #list > 0 then
			freeSoundCount -= 1
			return table.remove(list)
		end
	end
	return nil
end

-- A clean Sound holding `path` (silent, settings reset), or nil when MaxLiveSounds are already in use.
-- Sounds that last played the same file are preferred, so they are already loaded.
function VoicePool.acquireSound(path: string): Sound?
	if soundsInUse >= MAX_LIVE_SOUNDS then
		log.warnThrottled("sounds", 10, "voice pool exhausted (%d sounds in use); dropping a grain", soundsInUse)
		return nil
	end
	local sound = takeFree(path)
	if sound == nil then
		local created = Instance.new("Sound")
		created.Name = "Voice"
		created.Loaded:Connect(function()
			onSoundLoaded(created)
		end)
		sound = created
	end
	assert(sound, "unreachable")
	resetSound(sound)
	if sound.SoundId ~= path then
		sound.SoundId = path
	end
	soundsInUse += 1
	return sound
end

-- Returns a Sound to the pool. Its effects must already have been released. Destroyed Sounds are dropped.
function VoicePool.releaseSound(sound: Sound)
	soundsInUse = math.max(0, soundsInUse - 1)
	local target = freeFolder
	local ok = pcall(function()
		sound:Stop()
		sound.Parent = target
	end)
	if not ok or target == nil or freeSoundCount >= MAX_FREE_SOUNDS then
		pcall(function()
			sound:Destroy()
		end)
		return
	end
	local path = sound.SoundId
	local list = freeSounds[path]
	if not list then
		list = {}
		freeSounds[path] = list
	end
	table.insert(list, sound)
	freeSoundCount += 1
end

--------------------------------------------------------------------------------
-- Effect pool
--------------------------------------------------------------------------------

-- A SoundEffect of `kind` reset to engine defaults and enabled, or nil for an unknown kind.
function VoicePool.acquireEffect(kind: SynthPresets.EffectKind): SoundEffect?
	local spec = SynthPresets.Effects[kind]
	if not spec then
		return nil
	end
	local list = freeEffects[kind]
	local reused = if list then table.remove(list) else nil
	local effect: SoundEffect = if reused then reused else Instance.new(spec.className :: any) :: SoundEffect
	effect.Name = kind
	for prop, value in spec.defaults do
		(effect :: any)[prop] = value
	end
	effect.Enabled = true
	effect.Priority = 0
	return effect
end

function VoicePool.releaseEffect(kind: SynthPresets.EffectKind, effect: SoundEffect)
	local target = freeFolder
	local list = freeEffects[kind]
	if not list then
		list = {}
		freeEffects[kind] = list
	end
	local ok = pcall(function()
		effect.Parent = target
	end)
	if not ok or target == nil or #list >= MAX_FREE_EFFECTS_PER_KIND then
		pcall(function()
			effect:Destroy()
		end)
		return
	end
	table.insert(list, effect)
end

--------------------------------------------------------------------------------
-- Emitters (3D placement)
--------------------------------------------------------------------------------

local function acquireAttachment(parent: BasePart, cframe: CFrame): Attachment
	local attachment = table.remove(freeAttachments)
	if attachment == nil then
		local created = Instance.new("Attachment")
		created.Name = "VoiceEmitter"
		attachment = created
	end
	assert(attachment, "unreachable")
	attachment.CFrame = cframe
	attachment.Parent = parent
	return attachment
end

local function releaseAttachment(attachment: Attachment)
	local park = anchorPart
	local ok = pcall(function()
		attachment.Parent = park
	end)
	if not ok or park == nil or #freeAttachments >= MAX_FREE_ATTACHMENTS then
		pcall(function()
			attachment:Destroy()
		end)
		return
	end
	table.insert(freeAttachments, attachment)
end

local function partOf(target: Instance): BasePart?
	if target:IsA("BasePart") then
		return target
	end
	if target:IsA("Model") then
		local primary = target.PrimaryPart
		if primary then
			return primary
		end
		local root = target:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			return root
		end
		return target:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

-- Where a voice plays from: following `attach` when it is a usable instance, else fixed at `position`, else 2D.
function VoicePool.acquireEmitter(attach: Instance?, position: Vector3?): Emitter?
	if not isSetUp then
		return nil
	end
	if attach and attach:IsDescendantOf(Workspace) then
		if attach:IsA("Attachment") then
			return { parent = attach :: Instance, attachment = nil, follow = attach :: Instance, spatial = true }
		end
		local part = partOf(attach)
		if part then
			local attachment = acquireAttachment(part, CFrame.identity)
			return {
				parent = attachment :: Instance,
				attachment = attachment,
				follow = part :: Instance,
				spatial = true,
			}
		end
	end
	if position then
		local anchor = anchorPart
		if anchor then
			local attachment = acquireAttachment(anchor, CFrame.new(position))
			return { parent = attachment :: Instance, attachment = attachment, follow = nil, spatial = true }
		end
	end
	local flat = voices2D
	if flat == nil then
		return nil
	end
	return { parent = flat :: Instance, attachment = nil, follow = nil, spatial = false }
end

function VoicePool.releaseEmitter(emitter: Emitter)
	local attachment = emitter.attachment
	if attachment then
		emitter.attachment = nil
		releaseAttachment(attachment)
	end
end

-- Current world position of an emitter (nil for 2D).
function VoicePool.emitterPosition(emitter: Emitter): Vector3?
	if not emitter.spatial then
		return nil
	end
	local parent = emitter.parent
	if parent:IsA("Attachment") then
		return parent.WorldPosition
	end
	return nil
end

-- False once the emitter's host was destroyed or removed from the world (its Sounds can no longer be heard).
function VoicePool.emitterAlive(emitter: Emitter): boolean
	local parent = emitter.parent
	if not emitter.spatial then
		return parent.Parent ~= nil
	end
	return parent:IsDescendantOf(Workspace)
end

-- Moves a fixed-position emitter (no effect on emitters that follow an instance).
function VoicePool.moveEmitter(emitter: Emitter, position: Vector3)
	local attachment = emitter.attachment
	if attachment and emitter.follow == nil then
		attachment.CFrame = CFrame.new(position)
	end
end

return table.freeze(VoicePool)
