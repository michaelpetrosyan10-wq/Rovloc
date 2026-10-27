--!strict
-- LightingController: the only run-time writer of the LevelLight fixtures' lights, plus every client lighting moment.
--
--   * Active set. A fixture's lights only render while its level is in focus: the CurrentLevel during a run (the
--     Lobby when no run is going), plus the layout the camera is actually in (the LevelId of the Zone volume holding
--     the camera; the lobby footprint and the school's floor bands only when no zone holds it, e.g. inside a duct or
--     before the world is built). Stairwell lights (LevelId = the lower level) join when either level the stairwell
--     joins is in focus. Broken fixtures (BaseBrightness 0) and burst bulbs stay dark. SetBudget caps the set to the nearest `maxActive` fixtures and gates shadows. Every
--     fixture outside the set is Enabled = false, so the GPU only ever sees a few dozen lights.
--   * Flicker. Fixtures sharing a FlickerGroup flicker together: smooth value noise, sharp dropouts, and seeded
--     blackouts (with a stuttering recovery) scheduled in fixed time slots. Everything is a pure function of
--     (RunSeed or 1, group, server time), so every client sees the same flicker on the same frame. Only lights in
--     the active set are animated.
--   * OneShot "Lightning" (args.intensity?, args.stages? 1|2): a two-stage flash on Lighting (Brightness,
--     OutdoorAmbient, ExposureCompensation), the Terrain cloud deck and a client-local ColorCorrectionEffect, scaled
--     by SetFlashScale (P3 settings) and damped when the camera is indoors. Rest values are captured when a flash
--     starts and restored when it ends (server changes made mid-flash are adopted as the new rest).
--   * OneShot "LightBurst" (args.lightId or the fixture as subject): the bulb surges to 4x, stutters, dies, and
--     throws sparks (a default-texture ParticleEmitter). Burst bulbs stay dead until the run ends. Audio for both
--     moments is the server's job (AudioCue), except the ambient storm below.
--   * Ambient storm. While the camera is outdoors (in a Roof zone, or outside every building) a seeded,
--     server-time-synced schedule throws lightning with locally played thunder, because the roof has almost no
--     fixtures. It stays quiet for a while after any scripted Lightning, and SetStormEnabled(false) hands the sky to a
--     later phase entirely.
--   * SetOverride(lightId, brightness?) pins a fixture's brightness for Timeline tracks (P3) and the pool floodlight
--     switch (P7); an override forces the fixture into the active set and wins over flicker and burnt bulbs.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LightingRig = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LightingRig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local log = Log.new("LightingController")

local W = Attributes.World
local M = Attributes.Match

local LOBBY = "Lobby"
local PRIMARY_LIGHT = "Light" -- the fixture's main light (SchoolShellBuilder.buildLight); others are fills
local SECONDARY_RATIO = 0.35 -- a fill's share of the primary when the fixture has no authored brightness
local MIN_ON = 0.004 -- below this brightness a light is switched off instead of dimmed
local WRITE_EPSILON = 0.004
local REFRESH_INTERVAL = 0.25
local DEFAULT_BUDGET = 48
local NOISE_PERIOD = 4096 -- noise is sampled on server time modulo this (keeps math.noise inputs precise)

-- Flicker
local RECOVERY_SECONDS = 0.45
local RECOVERY_HZ = 14

-- Light burst
local BURST_PEAK = 4
local BURST_FALLBACK_BASE = 1
local SPARK_COUNT = 34
local SPARK_DISTANCE = 160
local SPARK_LIFETIME = 2.5
local BURNT_TINT = Color3.fromRGB(14, 13, 12)

-- Lightning
local FLASH_BRIGHTNESS = 5
local FLASH_EXPOSURE = 1.1
local FLASH_OUTDOOR = Color3.fromRGB(150, 160, 192)
local FLASH_CLOUDS = Color3.fromRGB(214, 220, 242)
local FLASH_TINT = Color3.fromRGB(206, 216, 255)
local FLASH_GRADE_BRIGHTNESS = 0.22
local FLASH_GRADE_CONTRAST = 0.18
local FLASH_GRADE_SATURATION = -0.25
local INDOOR_FLASH = 0.18
local MAX_SCHEDULE_AHEAD = 10
local FLASH_GRADE_NAME = "LightningFlash"

-- Ambient storm
local STORM_SLOT = 11
local STORM_CHANCE = 0.8
local STORM_QUIET_AFTER_SCRIPTED = 8
local STORM_FIRE_WINDOW = 0.5

type LightRec = {
	light: Light,
	ratio: number,
	shadows: boolean,
	written: number,
	enabled: boolean,
}

type Entry = {
	fixture: BasePart,
	id: string,
	position: Vector3,
	layoutId: string,
	fromLevel: string?,
	toLevel: string?,
	group: string?,
	base: number,
	lights: { LightRec },
	active: boolean,
	dead: boolean,
	burstStart: number?,
	color: Color3,
	childConnection: RBXScriptConnection?,
}

export type FlickerProfile = {
	rate: number,
	depth: number,
	dropRate: number,
	dropThreshold: number,
	slotLength: number,
	blackoutChance: number,
	minBlackout: number,
	maxBlackout: number,
	noiseSeed: number,
	dropSeed: number,
}

export type BlackoutSlot = {
	slot: number,
	startsAt: number, -- server time; -1 when the slot has no blackout
	endsAt: number,
}

type GroupState = {
	profile: FlickerProfile,
	blackout: BlackoutSlot,
	frame: number,
	factor: number,
}

type Flash = {
	started: number, -- os.clock()
	strength: number,
	stages: number,
}

type RestState = {
	brightness: number,
	outdoorAmbient: Color3,
	exposure: number,
	cloudColor: Color3?,
}

type Bounds = { min: Vector3, max: Vector3 }

export type Stats = {
	registered: number,
	active: number,
	lit: number,
	budget: number,
	shadows: boolean,
	focus: { string },
	viewLayout: string?,
	outdoors: boolean,
	flashing: boolean,
}

local LightingController = {}

LightingController.Name = "LightingController"
LightingController.RecoverySeconds = RECOVERY_SECONDS
LightingController.DefaultBudget = DEFAULT_BUDGET

local serviceTrove = Trove.new()
local runTrove = serviceTrove:Extend()

-- Registry
local entries: { [BasePart]: Entry } = {}
local entryList: { Entry } = {}
local byId: { [string]: Entry } = {}
local originalRatio: { [Light]: number } = setmetatable({}, { __mode = "k" }) :: any
local originalShadows: { [Light]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- Active set
local activeList: { Entry } = {}
local dirty = true
local refreshClock = 0
local budgetMax = DEFAULT_BUDGET
local budgetShadows = true
local focusLayouts: { string } = {}
local viewLayout: string? = nil
local viewOutdoors = false
local overrides: { [string]: number } = {}

-- Flicker
local seedBase = 1
local groups: { [string]: GroupState } = {}
local frameId = 0

-- Lightning
local flashScale = 1
local flashes: { Flash } = {}
local rest: RestState? = nil
local lastWrite: RestState? = nil
local flashGrade: ColorCorrectionEffect? = nil
local lastScripted = -math.huge

-- Storm
local stormEnabled = true
local stormSlot = -1
local stormAt: number? = nil
local stormFired = false
local stormIntensity = 0.7
local stormStages = 2
local stormThunderDelay = 1

--------------------------------------------------------------------------------
-- Pure helpers (specs: tests/Specs/ClientLighting.spec.luau)
--------------------------------------------------------------------------------

-- The seeded flicker character of one group.
function LightingController.flickerProfile(seed: number, group: string): FlickerProfile
	local random = MathUtil.seededRandom(seed, "flicker:" .. group)
	return {
		rate = random:NextNumber(1.5, 7),
		depth = random:NextNumber(0.25, 0.75),
		dropRate = random:NextNumber(4, 11),
		dropThreshold = random:NextNumber(0.55, 0.85),
		slotLength = random:NextNumber(7, 16),
		blackoutChance = random:NextNumber(0.3, 0.65),
		minBlackout = 0.15,
		maxBlackout = random:NextNumber(0.8, 2.6),
		noiseSeed = random:NextNumber(0, 1000),
		dropSeed = random:NextNumber(0, 1000),
	}
end

-- The blackout scheduled in time slot `slot` (if any). A blackout and its recovery always fit inside the slot.
function LightingController.blackoutSlot(
	seed: number,
	group: string,
	profile: FlickerProfile,
	slot: number
): BlackoutSlot
	local random = MathUtil.seededRandom(seed, string.format("blackout:%s:%d", group, slot))
	if random:NextNumber() >= profile.blackoutChance then
		return { slot = slot, startsAt = -1, endsAt = -1 }
	end
	local length = profile.slotLength
	local duration = random:NextNumber(profile.minBlackout, profile.maxBlackout)
	local latest = math.max(0, length - duration - RECOVERY_SECONDS)
	local startsAt = slot * length + random:NextNumber(0, latest)
	return { slot = slot, startsAt = startsAt, endsAt = startsAt + duration }
end

-- Brightness multiplier in [0, 1] for a group at server time `t`, given that slot's blackout.
function LightingController.flickerFactor(profile: FlickerProfile, blackout: BlackoutSlot, t: number): number
	if blackout.startsAt >= 0 then
		if t >= blackout.startsAt and t < blackout.endsAt then
			return 0
		end
		if t >= blackout.endsAt and t < blackout.endsAt + RECOVERY_SECONDS then
			local phase = math.floor((t - blackout.endsAt) * RECOVERY_HZ)
			return if phase % 2 == 0 then 0.12 else 0.85
		end
	end
	local sample = t % NOISE_PERIOD
	local wave = MathUtil.noise1(sample * profile.rate, profile.noiseSeed)
	local factor = 1 - profile.depth * MathUtil.smoothstep(-0.2, 0.8, wave)
	local drop = MathUtil.noise1(sample * profile.dropRate, profile.dropSeed)
	if drop > profile.dropThreshold then
		factor *= 0.12
	end
	return math.clamp(factor, 0, 1)
end

-- Stateless flicker sample (what every client computes for `group` at server time `t`).
function LightingController.flickerAt(seed: number, group: string, t: number): number
	local profile = LightingController.flickerProfile(seed, group)
	local slot = math.floor(t / profile.slotLength)
	return LightingController.flickerFactor(profile, LightingController.blackoutSlot(seed, group, profile, slot), t)
end

-- Lightning envelope in [0, 1] at `t` seconds into a flash; nil once it is over. Two stages: a first strike that
-- decays into a short dark gap, then the brighter main flash with a long tail. One stage: a single strike.
function LightingController.lightningEnvelope(t: number, stages: number): number?
	if t < 0 then
		return 0
	end
	if stages >= 2 then
		if t < 0.05 then
			return 0.65 * t / 0.05
		elseif t < 0.11 then
			return 0.65
		elseif t < 0.3 then
			return MathUtil.lerp(0.65, 0.06, (t - 0.11) / 0.19)
		elseif t < 0.42 then
			return 0.04
		elseif t < 0.47 then
			return MathUtil.lerp(0.04, 1, (t - 0.42) / 0.05)
		elseif t < 0.6 then
			return 1
		elseif t < 1.7 then
			return math.exp(-4 * (t - 0.6))
		end
		return nil
	end
	if t < 0.05 then
		return t / 0.05
	elseif t < 0.12 then
		return 1
	elseif t < 1.1 then
		return math.exp(-4.5 * (t - 0.12))
	end
	return nil
end

-- Brightness multiplier of a bursting bulb `t` seconds in; nil once it is dead.
function LightingController.burstMultiplier(t: number): number?
	if t < 0.05 then
		return MathUtil.lerp(1, BURST_PEAK, math.max(0, t) / 0.05)
	elseif t < 0.14 then
		return BURST_PEAK * (0.92 + 0.08 * math.sin(t * 190))
	elseif t < 0.42 then
		if math.floor(t * 30) % 2 == 0 then
			return 2.5 * (1 - (t - 0.14) / 0.28)
		end
		return 0
	end
	return nil
end

local lobbyBoundsCache: Bounds? = nil
local schoolBoundsCache: Bounds? = nil

local function lobbyBounds(): Bounds?
	if lobbyBoundsCache then
		return lobbyBoundsCache
	end
	local layout = Builder.getLayout(LOBBY)
	if not layout or #layout.rooms == 0 then
		return nil
	end
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	local top = layout.height
	for _, room in layout.rooms do
		local rect = room.rect
		minX = math.min(minX, rect.x)
		minZ = math.min(minZ, rect.z)
		maxX = math.max(maxX, rect.x + rect.w)
		maxZ = math.max(maxZ, rect.z + rect.d)
		top = math.max(top, room.height or layout.height)
	end
	local origin = WorldConfig.levelOrigin(LOBBY)
	local margin = 12
	local bounds: Bounds = {
		min = origin + Vector3.new(minX - margin, -12, minZ - margin),
		max = origin + Vector3.new(maxX + margin, top + 30, maxZ + margin),
	}
	lobbyBoundsCache = bounds
	return bounds
end

local function schoolBounds(): Bounds
	if schoolBoundsCache then
		return schoolBoundsCache
	end
	local minX, maxX = 0, WorldConfig.FootprintSize.X
	for _, tower in WorldConfig.Towers do
		minX = math.min(minX, tower.minX)
		maxX = math.max(maxX, tower.maxX)
	end
	local margin = 6
	local origin = WorldConfig.SchoolOrigin
	local roof = WorldConfig.levelElevation(Enums.LevelId[#Enums.LevelId])
	local bounds: Bounds = {
		min = origin + Vector3.new(minX - margin, -12, -margin),
		max = origin + Vector3.new(maxX + margin, roof + 60, WorldConfig.FootprintSize.Y + margin),
	}
	schoolBoundsCache = bounds
	return bounds
end

local function inside(bounds: Bounds, point: Vector3): boolean
	local lo, hi = bounds.min, bounds.max
	return point.X >= lo.X
		and point.X <= hi.X
		and point.Y >= lo.Y
		and point.Y <= hi.Y
		and point.Z >= lo.Z
		and point.Z <= hi.Z
end

-- The layout a world point is in by position alone: "Lobby", a LevelId (by the school's floor bands; a point counts
-- as a level once it is above the middle of the slab under that floor), or nil outside both (the street, the sky).
local function bandLayout(point: Vector3): string?
	local lobby = lobbyBounds()
	if lobby and inside(lobby, point) then
		return LOBBY
	end
	if not inside(schoolBounds(), point) then
		return nil
	end
	local found: string = Enums.LevelId[1]
	local localY = point.Y - WorldConfig.SchoolOrigin.Y
	for _, levelId: Enums.LevelId in Enums.LevelId do
		if localY >= WorldConfig.levelElevation(levelId) - WorldConfig.SlabThickness * 0.5 then
			found = levelId
		end
	end
	return found
end

-- Zone volumes (Tags.Zone: one per room and stairwell). Cached once Start has hooked the tag signals; before that
-- (pure use, specs) every lookup reads the tag fresh.
local zoneCache: { BasePart }? = nil
local zoneSignalsHooked = false

local function zoneParts(): { BasePart }
	local cached = zoneCache
	if cached then
		return cached
	end
	local list: { BasePart } = {}
	for _, instance in CollectionService:GetTagged(Tags.Zone) do
		if instance:IsA("BasePart") then
			table.insert(list, instance)
		end
	end
	if zoneSignalsHooked then
		zoneCache = list
	end
	return list
end

-- The zone holding `point` (the smallest one where volumes meet), plus whether any zone exists at all.
local function zoneAt(point: Vector3): (BasePart?, boolean)
	local parts = zoneParts()
	local best: BasePart? = nil
	local bestVolume = math.huge
	for _, part in parts do
		if part.Parent ~= nil and SpatialQuery.pointInPart(part, point) then
			local size = part.Size
			local volume = size.X * size.Y * size.Z
			if volume < bestVolume then
				best = part
				bestVolume = volume
			end
		end
	end
	return best, #parts > 0
end

export type Place = {
	layoutId: string?, -- "Lobby", a LevelId, or nil outside every building
	zoneId: string?, -- the room or stairwell holding the point, if any
	roomKind: string?,
	outdoors: boolean, -- sees the sky
}

-- Where a world point is. A Zone volume decides when one holds the point: its LevelId is the layout (a stairwell,
-- tagged with its lower level, takes the floor band the point is in, so its top landing focuses the upper level), and
-- only a Roof zone is outdoors. With no zone holding it (a duct, a wall, the street) the floor bands decide and the
-- point is outdoors only outside every building, unless no zone exists yet (world not built), when the roof band
-- counts as outdoors too.
function LightingController.placeAt(point: Vector3): Place
	local zone, zonesExist = zoneAt(point)
	if zone then
		local levelId = Attributes.getString(zone, W.LevelId, "")
		if levelId ~= "" then
			local roomKind = Attributes.getString(zone, W.RoomKind, "")
			local layoutId = levelId
			if roomKind == "Stairwell" then
				local band = bandLayout(point)
				local from = table.find(Enums.LevelId, levelId :: any)
				local at = if band then table.find(Enums.LevelId, band :: any) else nil
				if from and at and at > from then
					layoutId = band :: string
				end
			end
			return {
				layoutId = layoutId,
				zoneId = Attributes.getString(zone, W.ZoneId, zone.Name),
				roomKind = if roomKind ~= "" then roomKind else nil,
				outdoors = roomKind == "Roof",
			}
		end
	end
	local layoutId = bandLayout(point)
	return {
		layoutId = layoutId,
		zoneId = nil,
		roomKind = nil,
		outdoors = layoutId == nil or (not zonesExist and LightingController.isOutdoors(layoutId)),
	}
end

-- The layout a world point is in (see placeAt).
function LightingController.layoutAt(point: Vector3): string?
	return LightingController.placeAt(point).layoutId
end

-- The layout-only outdoors guess (the roof level, or outside every building). placeAt refines it per zone.
function LightingController.isOutdoors(layoutId: string?): boolean
	return layoutId == nil or layoutId == Enums.LevelId[#Enums.LevelId]
end

--------------------------------------------------------------------------------
-- Viewpoint and focus
--------------------------------------------------------------------------------

local function viewPoint(): Vector3
	local camera = Workspace.CurrentCamera
	if camera then
		return camera.CFrame.Position
	end
	local root = Instances.characterRoot(Players.LocalPlayer)
	if root then
		return root.CFrame.Position
	end
	return WorldConfig.levelOrigin(LOBBY)
end

local function currentLevel(): Enums.LevelId?
	local value = ReplicatedStorage:GetAttribute(M.CurrentLevel)
	if type(value) == "string" and Enums.has(Enums.LevelId, value) then
		return (value :: any) :: Enums.LevelId
	end
	return nil
end

--------------------------------------------------------------------------------
-- Writing lights
--------------------------------------------------------------------------------

local function writeRec(rec: LightRec, brightness: number)
	local on = brightness > MIN_ON
	if on and math.abs(brightness - rec.written) > WRITE_EPSILON then
		rec.light.Brightness = brightness
		rec.written = brightness
	end
	if on ~= rec.enabled then
		rec.light.Enabled = on
		rec.enabled = on
	end
end

local function switchOff(entry: Entry)
	for _, rec in entry.lights do
		if rec.enabled then
			rec.light.Enabled = false
			rec.enabled = false
		end
	end
end

local function applyShadows(entry: Entry)
	for _, rec in entry.lights do
		local wanted = rec.shadows and budgetShadows
		if rec.light.Shadows ~= wanted then
			rec.light.Shadows = wanted
		end
	end
end

local function groupState(name: string): GroupState
	local state = groups[name]
	if not state then
		local profile = LightingController.flickerProfile(seedBase, name)
		state = {
			profile = profile,
			blackout = { slot = -math.huge, startsAt = -1, endsAt = -1 },
			frame = -1,
			factor = 1,
		}
		groups[name] = state
	end
	return state
end

local function groupFactor(name: string, t: number): number
	local state = groupState(name)
	if state.frame == frameId then
		return state.factor
	end
	local profile = state.profile
	local slot = math.floor(t / profile.slotLength)
	if slot ~= state.blackout.slot then
		state.blackout = LightingController.blackoutSlot(seedBase, name, profile, slot)
	end
	state.factor = LightingController.flickerFactor(profile, state.blackout, t)
	state.frame = frameId
	return state.factor
end

-- A dead bulb's fixture goes dark and sooty (client-local; restored when the run ends).
local function burnFixture(entry: Entry)
	entry.fixture.Color = entry.color:Lerp(BURNT_TINT, 0.75)
end

-- The primary light's brightness for this frame.
local function entryBrightness(entry: Entry, t: number, now: number): number
	local burstStart = entry.burstStart
	if burstStart then
		local multiplier = LightingController.burstMultiplier(now - burstStart)
		if multiplier then
			local base = if entry.base > 0 then entry.base else BURST_FALLBACK_BASE
			return base * multiplier
		end
		entry.burstStart = nil
		entry.dead = true
		burnFixture(entry)
		dirty = true
	end
	local override = overrides[entry.id]
	if override ~= nil then
		return override
	end
	if entry.dead or entry.base <= 0 then
		return 0
	end
	local group = entry.group
	if group then
		return entry.base * groupFactor(group, t)
	end
	return entry.base
end

local function updateEntry(entry: Entry, t: number, now: number)
	local brightness = entryBrightness(entry, t, now)
	for _, rec in entry.lights do
		writeRec(rec, brightness * rec.ratio)
	end
end

--------------------------------------------------------------------------------
-- Active set
--------------------------------------------------------------------------------

local function isForced(entry: Entry): boolean
	return entry.burstStart ~= nil or overrides[entry.id] ~= nil
end

local function isWanted(entry: Entry, focus: { [string]: boolean }): boolean
	if isForced(entry) then
		return true
	end
	if entry.dead or entry.base <= 0 then
		return false
	end
	local fromLevel, toLevel = entry.fromLevel, entry.toLevel
	if fromLevel or toLevel then
		return (fromLevel ~= nil and focus[fromLevel] == true) or (toLevel ~= nil and focus[toLevel] == true)
	end
	return focus[entry.layoutId] == true
end

local function refreshActive()
	local view = viewPoint()
	local place = LightingController.placeAt(view)
	local here = place.layoutId
	viewLayout = here
	viewOutdoors = place.outdoors

	local focus: { [string]: boolean } = {}
	local list: { string } = {}
	local level = currentLevel()
	local base: string = level or LOBBY
	focus[base] = true
	table.insert(list, base)
	if here and not focus[here] then
		focus[here] = true
		table.insert(list, here)
	end
	focusLayouts = list

	local forced: { Entry } = {}
	local candidates: { Entry } = {}
	for _, entry in entryList do
		if isWanted(entry, focus) then
			table.insert(if isForced(entry) then forced else candidates, entry)
		end
	end
	local room = math.max(0, budgetMax - #forced)
	if #candidates > room then
		table.sort(candidates, function(a: Entry, b: Entry): boolean
			return (a.position - view).Magnitude < (b.position - view).Magnitude
		end)
	end

	local nextActive: { Entry } = forced
	for i = 1, math.min(room, #candidates) do
		table.insert(nextActive, candidates[i])
	end
	local keep: { [Entry]: boolean } = {}
	for _, entry in nextActive do
		keep[entry] = true
	end
	for _, entry in activeList do
		if not keep[entry] and entry.active then
			entry.active = false
			switchOff(entry)
		end
	end
	for _, entry in nextActive do
		if not entry.active then
			entry.active = true
			for _, rec in entry.lights do
				rec.written = -1
			end
			applyShadows(entry)
		end
	end
	activeList = nextActive
end

--------------------------------------------------------------------------------
-- Registry
--------------------------------------------------------------------------------

local function addLight(entry: Entry, light: Light)
	for _, rec in entry.lights do
		if rec.light == light then
			return
		end
	end
	local ratio = originalRatio[light]
	if ratio == nil then
		if entry.base > 0 and light.Brightness > 0 then
			ratio = light.Brightness / entry.base
		elseif light.Name == PRIMARY_LIGHT then
			ratio = 1
		else
			ratio = SECONDARY_RATIO
		end
		originalRatio[light] = ratio
	end
	local shadows = originalShadows[light]
	if shadows == nil then
		shadows = light.Shadows
		originalShadows[light] = shadows
	end
	local rec: LightRec = {
		light = light,
		ratio = ratio or 1,
		shadows = shadows == true,
		written = -1,
		enabled = light.Enabled,
	}
	table.insert(entry.lights, rec)
	if entry.active then
		applyShadows(entry)
	elseif rec.enabled then
		light.Enabled = false
		rec.enabled = false
	end
end

local function stairwellOf(fixture: Instance): Instance?
	local stairs = Instances.stairwells()
	if not stairs or not fixture:IsDescendantOf(stairs) then
		return nil
	end
	local node: Instance = fixture
	local parent = node.Parent
	while parent and parent ~= stairs do
		node = parent
		parent = node.Parent
	end
	return if parent == stairs then node else nil
end

local function register(instance: Instance)
	if not instance:IsA("BasePart") or entries[instance] then
		return
	end
	local stairwell = stairwellOf(instance)
	local fromLevel: string? = nil
	local toLevel: string? = nil
	if stairwell then
		local from = Attributes.getString(stairwell, W.FromLevel, "")
		local to = Attributes.getString(stairwell, W.ToLevel, "")
		fromLevel = if from ~= "" then from else nil
		toLevel = if to ~= "" then to else nil
	end
	local group = Attributes.getString(instance, W.FlickerGroup, "")
	local entry: Entry = {
		fixture = instance,
		id = instance.Name,
		position = instance.CFrame.Position,
		layoutId = Attributes.getString(instance, W.LevelId, ""),
		fromLevel = fromLevel,
		toLevel = toLevel,
		group = if group ~= "" then group else nil,
		base = math.max(0, Attributes.getNumber(instance, W.BaseBrightness, 0)),
		lights = {},
		active = false,
		dead = false,
		burstStart = nil,
		color = instance.Color,
		childConnection = nil,
	}
	entries[instance] = entry
	table.insert(entryList, entry)
	if byId[entry.id] and byId[entry.id] ~= entry then
		log.warnThrottled("dup:" .. entry.id, 30, "two LevelLight fixtures are named %s", entry.id)
	end
	byId[entry.id] = entry
	for _, child in instance:GetChildren() do
		if child:IsA("Light") then
			addLight(entry, child)
		end
	end
	entry.childConnection = instance.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Light") then
			addLight(entry, child)
		end
	end)
	dirty = true
end

local function unregister(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local entry = entries[instance]
	if not entry then
		return
	end
	entries[instance] = nil
	local index = table.find(entryList, entry)
	if index then
		entryList[index] = entryList[#entryList]
		entryList[#entryList] = nil
	end
	if byId[entry.id] == entry then
		byId[entry.id] = nil
	end
	local connection = entry.childConnection
	if connection then
		connection:Disconnect()
	end
	local activeIndex = table.find(activeList, entry)
	if activeIndex then
		table.remove(activeList, activeIndex)
	end
	entry.active = false
	dirty = true
end

--------------------------------------------------------------------------------
-- Light burst
--------------------------------------------------------------------------------

local function emitSparks(entry: Entry)
	if (entry.position - viewPoint()).Magnitude > SPARK_DISTANCE then
		return
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = "BurstSparks"
	attachment.Position = Vector3.new(0, -entry.fixture.Size.Y * 0.5, 0)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Sparks"
	emitter.Enabled = false
	emitter.Rate = 0
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 246, 220), Color3.fromRGB(255, 132, 36))
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Brightness = 3
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.14),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.7, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.35, 0.9)
	emitter.Speed = NumberRange.new(6, 16)
	emitter.SpreadAngle = Vector2.new(75, 75)
	emitter.Acceleration = Vector3.new(0, -45, 0)
	emitter.Drag = 1.5
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Parent = attachment
	attachment.Parent = entry.fixture
	emitter:Emit(SPARK_COUNT)
	runTrove:Add(attachment)
	runTrove:Delay(0.12, function()
		if emitter.Parent then
			emitter:Emit(math.floor(SPARK_COUNT * 0.3))
		end
	end)
	runTrove:Delay(SPARK_LIFETIME, function()
		runTrove:Remove(attachment)
	end)
end

local function startBurst(entry: Entry, elapsed: number)
	if entry.dead and overrides[entry.id] == nil then
		return
	end
	entry.burstStart = os.clock() - elapsed
	emitSparks(entry)
	dirty = true
end

local function killNow(entry: Entry)
	entry.burstStart = nil
	entry.dead = true
	burnFixture(entry)
	dirty = true
end

--------------------------------------------------------------------------------
-- Lightning
--------------------------------------------------------------------------------

local function grade(): ColorCorrectionEffect
	local existing = flashGrade
	if existing and existing.Parent == Lighting then
		return existing
	end
	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = FLASH_GRADE_NAME
	effect.Enabled = false
	effect.Brightness = 0
	effect.Contrast = 0
	effect.Saturation = 0
	effect.TintColor = Color3.new(1, 1, 1)
	effect.Parent = Lighting
	flashGrade = effect
	serviceTrove:Add(effect)
	return effect
end

local function sameColor(a: Color3, b: Color3): boolean
	return math.abs(a.R - b.R) < 0.004 and math.abs(a.G - b.G) < 0.004 and math.abs(a.B - b.B) < 0.004
end

local function captureRest(): RestState
	local clouds = LightingRig.clouds()
	return {
		brightness = Lighting.Brightness,
		outdoorAmbient = Lighting.OutdoorAmbient,
		exposure = Lighting.ExposureCompensation,
		cloudColor = if clouds then clouds.Color else nil,
	}
end

-- Writes the flash at envelope value `e` (already scaled), adopting any server change made since the last write.
local function applyFlash(e: number)
	local state = rest
	local wrote = lastWrite
	local clouds = LightingRig.clouds()
	if not state then
		state = captureRest()
		rest = state
	elseif wrote then
		if math.abs(Lighting.Brightness - wrote.brightness) > 0.001 then
			state.brightness = Lighting.Brightness
		end
		if not sameColor(Lighting.OutdoorAmbient, wrote.outdoorAmbient) then
			state.outdoorAmbient = Lighting.OutdoorAmbient
		end
		if math.abs(Lighting.ExposureCompensation - wrote.exposure) > 0.001 then
			state.exposure = Lighting.ExposureCompensation
		end
		local wroteClouds = wrote.cloudColor
		if clouds and (state.cloudColor == nil or (wroteClouds and not sameColor(clouds.Color, wroteClouds))) then
			state.cloudColor = clouds.Color
		end
	end
	assert(state, "unreachable")

	local brightness = state.brightness + FLASH_BRIGHTNESS * e
	local outdoor = state.outdoorAmbient:Lerp(FLASH_OUTDOOR, math.clamp(e, 0, 1))
	local exposure = state.exposure + FLASH_EXPOSURE * e
	Lighting.Brightness = brightness
	Lighting.OutdoorAmbient = outdoor
	Lighting.ExposureCompensation = exposure
	local cloudColor: Color3? = nil
	local restClouds = state.cloudColor
	if clouds and restClouds then
		local flashed = restClouds:Lerp(FLASH_CLOUDS, math.clamp(e, 0, 1))
		clouds.Color = flashed
		cloudColor = flashed
	end
	lastWrite = {
		brightness = Lighting.Brightness,
		outdoorAmbient = Lighting.OutdoorAmbient,
		exposure = Lighting.ExposureCompensation,
		cloudColor = if clouds then clouds.Color else cloudColor,
	}

	local effect = grade()
	effect.Enabled = true
	effect.Brightness = FLASH_GRADE_BRIGHTNESS * e
	effect.Contrast = FLASH_GRADE_CONTRAST * e
	effect.Saturation = FLASH_GRADE_SATURATION * e
	effect.TintColor = Color3.new(1, 1, 1):Lerp(FLASH_TINT, math.clamp(e, 0, 1))
end

-- Restores the rest state (an envelope of 0 writes exactly the rest values, after adopting server changes).
local function endFlash()
	if rest then
		applyFlash(0)
	end
	rest = nil
	lastWrite = nil
	local effect = flashGrade
	if effect then
		effect.Enabled = false
	end
end

local function startFlash(intensity: number, stages: number, elapsed: number)
	-- Decided from the camera right now (the active-set refresh only runs at 4 Hz).
	local outdoors = LightingController.placeAt(viewPoint()).outdoors
	local indoor = if outdoors then 1 else INDOOR_FLASH
	local strength = math.clamp(intensity, 0, 2) * flashScale * indoor
	if strength <= 0 then
		return
	end
	table.insert(flashes, { started = os.clock() - elapsed, strength = strength, stages = stages })
end

local function updateFlashes(now: number)
	if #flashes == 0 then
		return
	end
	local value = 0
	for i = #flashes, 1, -1 do
		local flash = flashes[i]
		local envelope = LightingController.lightningEnvelope(now - flash.started, flash.stages)
		if envelope == nil then
			table.remove(flashes, i)
		else
			value = math.max(value, envelope * flash.strength)
		end
	end
	if #flashes == 0 then
		endFlash()
	else
		applyFlash(value)
	end
end

local function playThunder(volume: number)
	xpcall(function()
		local AudioController = require(script.Parent.AudioController)
		AudioController.PlayLocal("Thunder", { volume = volume })
	end, function(err: any)
		log.warnThrottled("thunder", 30, "thunder failed: %s", tostring(err))
	end)
end

local function updateStorm(t: number)
	if not stormEnabled then
		return
	end
	local slot = math.floor(t / STORM_SLOT)
	if slot ~= stormSlot then
		stormSlot = slot
		stormFired = false
		local random = MathUtil.seededRandom(seedBase, string.format("storm:%d", slot))
		if random:NextNumber() < STORM_CHANCE then
			stormAt = slot * STORM_SLOT + random:NextNumber(0.5, STORM_SLOT - 2)
		else
			stormAt = nil
		end
		stormIntensity = random:NextNumber(0.4, 0.95)
		stormStages = if random:NextNumber() < 0.6 then 2 else 1
		stormThunderDelay = random:NextNumber(0.4, 2.6)
	end
	local at = stormAt
	if stormFired or at == nil or t < at then
		return
	end
	stormFired = true
	if t - at > STORM_FIRE_WINDOW or not viewOutdoors then
		return
	end
	if os.clock() - lastScripted < STORM_QUIET_AFTER_SCRIPTED then
		return
	end
	startFlash(stormIntensity, stormStages, t - at)
	local volume = 0.55 + 0.45 * stormIntensity
	runTrove:Delay(stormThunderDelay, playThunder, volume)
end

--------------------------------------------------------------------------------
-- OneShot moments
--------------------------------------------------------------------------------

local function argNumber(args: { [string]: any }, key: string, default: number): number
	local value = args[key]
	if type(value) == "number" and MathUtil.isFinite(value) then
		return value
	end
	return default
end

local function burstTarget(payload: { [string]: any }, args: { [string]: any }): Entry?
	local id = args.lightId
	if type(id) == "string" then
		local entry = byId[id]
		if entry then
			return entry
		end
	end
	local subject = payload.subject
	if typeof(subject) == "Instance" and subject:IsA("BasePart") then
		return entries[subject]
	end
	return nil
end

local function onOneShot(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local event = payload :: { [string]: any }
	local kind = event.kind
	if kind ~= "Lightning" and kind ~= "LightBurst" then
		return
	end
	local args: { [string]: any } = if type(event.args) == "table" then event.args else {}
	local now = Workspace:GetServerTimeNow()
	local startAt = if type(event.startAt) == "number" and MathUtil.isFinite(event.startAt) then event.startAt else now
	local lead = math.min(startAt - now, MAX_SCHEDULE_AHEAD)
	local late = math.max(0, -lead)

	if kind == "Lightning" then
		lastScripted = os.clock()
		if late > GameConfig.OneShotMaxLate then
			return
		end
		local intensity = argNumber(args, "intensity", 1)
		local stages = if argNumber(args, "stages", 2) >= 2 then 2 else 1
		if lead > 0 then
			runTrove:Delay(lead, startFlash, intensity, stages, 0)
		else
			startFlash(intensity, stages, late)
		end
		return
	end

	local entry = burstTarget(event, args)
	if not entry then
		log.warnThrottled(
			"burst:" .. tostring(args.lightId),
			10,
			"LightBurst for unknown light %s",
			tostring(args.lightId)
		)
		return
	end
	if late > GameConfig.OneShotMaxLate then
		killNow(entry)
	elseif lead > 0 then
		runTrove:Delay(lead, startBurst, entry, 0)
	else
		startBurst(entry, late)
	end
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function onHeartbeat(dt: number)
	frameId += 1
	refreshClock += dt
	if dirty or refreshClock >= REFRESH_INTERVAL then
		refreshClock = 0
		dirty = false
		refreshActive()
	end
	local t = Workspace:GetServerTimeNow()
	local now = os.clock()
	for _, entry in activeList do
		updateEntry(entry, t, now)
	end
	updateFlashes(now)
	updateStorm(t)
end

local function resetSeed(seed: number)
	seedBase = seed
	table.clear(groups)
	stormSlot = -1
	stormAt = nil
	stormFired = false
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function LightingController.Init()
	local seed = ReplicatedStorage:GetAttribute(M.RunSeed)
	resetSeed(if type(seed) == "number" then seed else 1)
end

function LightingController.Start()
	local function dropZones()
		zoneCache = nil
		dirty = true
	end
	zoneSignalsHooked = true
	serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(Tags.Zone), dropZones)
	serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(Tags.Zone), dropZones)
	serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(Tags.LevelLight), register)
	serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(Tags.LevelLight), unregister)
	for _, instance in CollectionService:GetTagged(Tags.LevelLight) do
		register(instance)
	end
	serviceTrove:Connect(ReplicatedStorage:GetAttributeChangedSignal(M.CurrentLevel), function()
		dirty = true
	end)
	local connection = Net.Client.on("OneShot", onOneShot)
	if connection then
		serviceTrove:Add(connection)
	end
	serviceTrove:Connect(RunService.Heartbeat, onHeartbeat)
end

function LightingController.OnRunStarted(info: Types.RunInfo)
	resetSeed(info.seed)
	dirty = true
end

function LightingController.OnRunEnded()
	runTrove:Clean()
	table.clear(flashes)
	endFlash()
	table.clear(overrides)
	for _, entry in entryList do
		entry.burstStart = nil
		if entry.dead then
			entry.dead = false
			entry.fixture.Color = entry.color
		end
	end
	resetSeed(1)
	dirty = true
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Lightning strength multiplier from settings (0 = no screen flash at all; thunder still plays).
function LightingController.SetFlashScale(scale: number)
	if type(scale) ~= "number" or not MathUtil.isFinite(scale) then
		return
	end
	flashScale = math.clamp(scale, 0, 1)
end

-- Render budget (P3 RenderBudgetController): the nearest `maxActive` fixtures render; `shadows` gates every
-- fixture's authored shadows.
function LightingController.SetBudget(maxActive: number, shadows: boolean)
	if type(maxActive) ~= "number" or maxActive ~= maxActive then
		return
	end
	budgetMax = math.max(0, math.floor(maxActive))
	if budgetShadows ~= shadows then
		budgetShadows = shadows
		for _, entry in activeList do
			applyShadows(entry)
		end
	end
	dirty = true
end

-- Pins a fixture (by its light id = fixture name) to `brightness` (the primary light's value; fills keep their
-- ratio). nil releases it back to the active set rules, flicker and burn state. Overrides end with the run.
function LightingController.SetOverride(lightId: string, brightness: number?)
	if brightness ~= nil then
		if type(brightness) ~= "number" or not MathUtil.isFinite(brightness) then
			return
		end
		overrides[lightId] = math.max(0, brightness)
	else
		overrides[lightId] = nil
	end
	dirty = true
end

-- Lets a later phase own the sky (P8 finale): false stops the ambient roof storm.
function LightingController.SetStormEnabled(enabled: boolean)
	stormEnabled = enabled
end

-- Plays a lightning flash locally right now (dev tools, local scripted moments).
function LightingController.Flash(intensity: number?, stages: number?)
	startFlash(intensity or 1, if (stages or 2) >= 2 then 2 else 1, 0)
end

-- True when a fixture with this light id is registered.
function LightingController.HasLight(lightId: string): boolean
	return byId[lightId] ~= nil
end

function LightingController.GetStats(): Stats
	local lit = 0
	for _, entry in activeList do
		for _, rec in entry.lights do
			if rec.enabled then
				lit += 1
				break
			end
		end
	end
	return {
		registered = #entryList,
		active = #activeList,
		lit = lit,
		budget = budgetMax,
		shadows = budgetShadows,
		focus = table.clone(focusLayouts),
		viewLayout = viewLayout,
		outdoors = viewOutdoors,
		flashing = #flashes > 0,
	}
end

return LightingController
