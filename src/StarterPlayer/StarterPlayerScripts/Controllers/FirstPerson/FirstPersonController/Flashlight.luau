--!strict
-- Flashlight: the local dual-cone flashlight, its battery and EMF interference, and the shared EMF rule.
--
-- Beam. One invisible, anchored, never-queried part under the current camera carries two SpotLights: the inner cone
-- (INNER_ANGLE, INNER_RANGE, bright; shadows only when the render budget allows them) and the outer cone
-- (OUTER_ANGLE, OUTER_RANGE, dim, never shadowed). The part sits just ahead of the torch lens (HandRig) or, without
-- a torch, a little right of and below the eye; its orientation chases the player's look with a slight lag (a
-- damped slerp), pitched down a little while the torch is lowered for sprinting.
--
-- Switch. The Flashlight action predicts on/off at once (turning on needs battery > 0; a dead cell only clicks),
-- sends FlashlightToggle { on }, and plays UiClick. The prediction stands for RECONCILE_GRACE or until the server's
-- FlashlightOn agrees; after that FlashlightOn wins (the server turns the light off when the cell runs dry).
-- Toggles are spaced at least TOGGLE_COOLDOWN apart (the remote allows 4/s).
--
-- Battery. Extrapolated from the Battery meter attributes; full brightness down to LowBattery (15 %), then dimming
-- and warming toward a dying orange, with a sputter in the last 5 %.
--
-- EMF. The Creature disturbs electronics within CreatureConfig.Senses.EmfRadius (45 studs; full strength inside
-- EMF_FULL_SHARE of it), or from inside a wall vent next to my room: Creature.InVent and the AdjacentZones of the
-- VentShaft segment it is in (Creature.VentSegmentId -> the VentShaft part with that SegmentId) contain the
-- listener's ZoneId (then at least VentAdjacentIntensity). The light flickers (value noise dims it, seeded
-- dropouts black it out briefly, both deeper and faster with intensity, scaled by FlashScale) and an EmfStatic loop
-- plays on the Body bus at a volume following the intensity, whether or not the light is on. emfIntensity /
-- flickerFactor / emfAt are shared with RemoteFlashlightRenderer through FirstPersonController, so teammates'
-- lights obey the same rule. Flicker runs on server time, so every client sees a given light flicker the same way.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local SoundSynthesizer = require(ReplicatedStorage.Shared.Audio.SoundSynthesizer)
local Tags = require(ReplicatedStorage.Shared.Tags)

local AudioController = require(script.Parent.Parent.Parent.Core.AudioController)

local log = Log.new("Flashlight")

local P = Attributes.Player
local C = Attributes.Creature
local W = Attributes.World

export type UpdateContext = {
	dt: number,
	now: number, -- os.clock()
	serverNow: number,
	look: CFrame, -- the player's look at the eye (no bob or shake)
	lowered: number, -- 0..1, torch lowered for sprinting
	allowed: boolean, -- false hides the beam (dead, spectating, camera handed back)
	camera: Camera?,
	zoneId: string?,
	flashScale: number,
}

export type Light = {
	Toggle: (self: Light, now: number) -> (),
	Update: (self: Light, context: UpdateContext) -> (),
	SetShadows: (self: Light, enabled: boolean) -> (),
	IsOn: (self: Light) -> boolean,
	GetOutput: (self: Light) -> number,
	GetEmf: (self: Light) -> number,
	GetBatteryFraction: (self: Light) -> number,
	Reset: (self: Light) -> (),
	Destroy: (self: Light) -> (),
}

local Flashlight = {}

Flashlight.EmfRadius = CreatureConfig.Senses.EmfRadius
Flashlight.VentAdjacentIntensity = 0.55
Flashlight.LowBattery = 0.15
Flashlight.ReconcileGrace = 0.8

local EMF_FULL_SHARE = 0.15 -- full interference inside this share of the radius
local NOISE_PERIOD = 4096 -- server time is folded into this period before noise (keeps math.noise precise)
local FLICKER_BASE_HZ = 5
local FLICKER_EXTRA_HZ = 16
local DROPOUT_HZ = 9
local DROPOUT_CHANCE = 0.42 -- share of dropout slots at full intensity
local DROPOUT_LEVEL = 0.04
local LOW_FLOOR = 0.3 -- brightness share left at an almost empty cell
local SPUTTER_BELOW = 0.05
local STATIC_THRESHOLD = 0.04
local STATIC_VOLUME_EPSILON = 0.04

local INNER_ANGLE = 40
local INNER_RANGE = 60 -- SpotLight.Range maximum
local INNER_BRIGHTNESS = 8
local OUTER_ANGLE = 80
local OUTER_RANGE = 48
local OUTER_BRIGHTNESS = 2.2
-- Presence glow: a dim, short, unshadowed light around the player (on whether or not the torch is), so whatever is
-- within arm's reach always reads in the dark without lighting up the room.
local GLOW_RANGE = 10
local GLOW_BRIGHTNESS = 0.45
local GLOW_COLOR = Color3.fromRGB(176, 190, 214)
local BEAM_COLOR = Color3.fromRGB(255, 238, 212)
local DYING_COLOR = Color3.fromRGB(255, 176, 112)
local LAG_SPEED = 16 -- 1/s damped slerp of the beam toward the look
local LOWERED_PITCH = math.rad(7)
-- The beam fires from just in front of the eyes, slightly right and low (look space): nothing of the player's own
-- body, hand or torch model can sit between the light and the world, so the shadowed inner cone is never blocked by
-- the player. The hand-held torch model (HandRig) stays the visual source.
local BEAM_OFFSET = Vector3.new(0.3, -0.25, -0.6)
local TOGGLE_COOLDOWN = 0.22

export type Cones = {
	innerAngle: number,
	innerRange: number,
	innerBrightness: number,
	outerAngle: number,
	outerRange: number,
	outerBrightness: number,
	offset: Vector3, -- look space, from the eye
}

-- The torch's dual cone as the holder sees it (RemoteFlashlightRenderer lights a spectated teammate's torch the
-- same way, from inside their eyes).
Flashlight.Cones = table.freeze({
	innerAngle = INNER_ANGLE,
	innerRange = INNER_RANGE,
	innerBrightness = INNER_BRIGHTNESS,
	outerAngle = OUTER_ANGLE,
	outerRange = OUTER_RANGE,
	outerBrightness = OUTER_BRIGHTNESS,
	offset = BEAM_OFFSET,
} :: Cones)
local SAMPLE_TTL = 0.008

--------------------------------------------------------------------------------
-- Pure maths
--------------------------------------------------------------------------------

-- EMF interference 0..1 for a Creature `distance` studs away (or in an adjacent wall vent).
function Flashlight.emfIntensity(distance: number, radius: number, ventAdjacent: boolean): number
	local level = 0
	if distance == distance and radius > 0 and distance < radius then
		level = MathUtil.smoothstep(radius, radius * EMF_FULL_SHARE, distance)
	end
	if ventAdjacent then
		level = math.max(level, Flashlight.VentAdjacentIntensity)
	end
	return MathUtil.clamp01(level)
end

-- Brightness multiplier 0..1 of a light under EMF `intensity` at time `t` (deterministic per seed and time).
function Flashlight.flickerFactor(intensity: number, t: number, seed: number): number
	if not (intensity > 0) then
		return 1
	end
	local level = MathUtil.clamp01(intensity)
	local slot = math.floor(t * DROPOUT_HZ)
	local roll = MathUtil.hash(string.format("%d:%d", math.floor(seed), slot)) / 4294967296
	if roll < level * DROPOUT_CHANCE then
		return DROPOUT_LEVEL
	end
	local folded = t % NOISE_PERIOD
	local wave = MathUtil.noise1(folded * (FLICKER_BASE_HZ + FLICKER_EXTRA_HZ * level), seed) * 0.5 + 0.5
	local dim = level * (0.25 + 0.45 * MathUtil.clamp01(wave))
	return MathUtil.clamp01(1 - dim)
end

-- Brightness multiplier 0..1 of a cell at `fraction` charge.
function Flashlight.batteryFactor(fraction: number): number
	if not (fraction > 0) then
		return 0
	end
	if fraction >= Flashlight.LowBattery then
		return 1
	end
	return MathUtil.lerp(LOW_FLOOR, 1, fraction / Flashlight.LowBattery)
end

-- Beam colour at `fraction` charge (warms as the cell dies).
function Flashlight.beamColor(fraction: number): Color3
	local warmth = 1 - MathUtil.clamp01(fraction / Flashlight.LowBattery)
	return BEAM_COLOR:Lerp(DYING_COLOR, warmth)
end

-- Sputter multiplier of an almost empty cell.
function Flashlight.sputter(fraction: number, t: number, seed: number): number
	if fraction >= SPUTTER_BELOW or not (fraction > 0) then
		return 1
	end
	local depth = 1 - fraction / SPUTTER_BELOW
	local wave = MathUtil.noise1((t % NOISE_PERIOD) * 11, seed + 101) * 0.5 + 0.5
	return MathUtil.clamp01(1 - 0.55 * depth * MathUtil.clamp01(wave))
end

-- Whether the light is on: the local prediction for `grace` seconds after a toggle, then the server's attribute.
function Flashlight.resolveOn(
	serverOn: boolean,
	predicted: boolean?,
	predictedAt: number?,
	now: number,
	grace: number
): boolean
	if predicted == nil or predictedAt == nil or predicted == serverOn then
		return serverOn
	end
	if now - predictedAt <= grace then
		return predicted
	end
	return serverOn
end

--------------------------------------------------------------------------------
-- EMF sensor (shared)
--------------------------------------------------------------------------------

type CreatureSample = { position: Vector3, inVent: boolean, segment: string? }

local shafts: { [string]: { [Instance]: { [string]: boolean } } } = {}
local shaftSegment: { [Instance]: string } = {}
local indexStarted = false
local sample: CreatureSample? = nil
local sampledAt = -math.huge

local function unindexShaft(instance: Instance)
	local segment = shaftSegment[instance]
	if segment == nil then
		return
	end
	shaftSegment[instance] = nil
	local parts = shafts[segment]
	if parts then
		parts[instance] = nil
		if next(parts) == nil then
			shafts[segment] = nil
		end
	end
end

local function indexShaft(instance: Instance)
	unindexShaft(instance)
	local segment = Attributes.getString(instance, W.SegmentId, "")
	if segment == "" then
		return
	end
	local zones: { [string]: boolean } = {}
	for _, zone in Attributes.getList(instance, W.AdjacentZones) do
		zones[zone] = true
	end
	local parts = shafts[segment]
	if not parts then
		parts = {}
		shafts[segment] = parts
	end
	parts[instance] = zones
	shaftSegment[instance] = segment
end

local function ensureIndex()
	if indexStarted then
		return
	end
	indexStarted = true
	CollectionService:GetInstanceAddedSignal(Tags.VentShaft):Connect(indexShaft)
	CollectionService:GetInstanceRemovedSignal(Tags.VentShaft):Connect(unindexShaft)
	for _, instance in CollectionService:GetTagged(Tags.VentShaft) do
		indexShaft(instance)
	end
end

local function creatureSample(): CreatureSample?
	local now = os.clock()
	if now - sampledAt < SAMPLE_TTL then
		return sample
	end
	sampledAt = now
	ensureIndex()
	local creature = Instances.creature()
	local root = Instances.creatureRoot()
	if not creature or not root then
		sample = nil
		return nil
	end
	local segment = creature:GetAttribute(C.VentSegmentId)
	sample = {
		position = root.CFrame.Position,
		inVent = Attributes.getBool(creature, C.InVent, false),
		segment = if type(segment) == "string" and segment ~= "" then segment else nil,
	}
	return sample
end

-- Is `zoneId` adjacent to the vent segment `segment`?
function Flashlight.segmentTouches(segment: string, zoneId: string): boolean
	ensureIndex()
	local parts = shafts[segment]
	if not parts then
		return false
	end
	for _, zones in parts do
		if zones[zoneId] then
			return true
		end
	end
	return false
end

-- EMF intensity at a world position for a listener standing in `zoneId` (the Player's ZoneId attribute).
function Flashlight.emfAt(position: Vector3, zoneId: string?): number
	local creature = creatureSample()
	if not creature then
		return 0
	end
	local adjacent = false
	local segment = creature.segment
	if creature.inVent and segment ~= nil and zoneId ~= nil and zoneId ~= "" then
		adjacent = Flashlight.segmentTouches(segment, zoneId)
	end
	return Flashlight.emfIntensity((creature.position - position).Magnitude, Flashlight.EmfRadius, adjacent)
end

--------------------------------------------------------------------------------
-- Local light
--------------------------------------------------------------------------------

local function newSpot(parent: Instance, name: string, angle: number, range: number, shadows: boolean): SpotLight
	local light = Instance.new("SpotLight")
	light.Name = name
	light.Face = Enum.NormalId.Front
	light.Angle = angle
	light.Range = range
	light.Brightness = 0
	light.Color = BEAM_COLOR
	light.Shadows = shadows
	light.Enabled = false
	light.Parent = parent
	return light
end

function Flashlight.new(player: Player): Light
	local part = Instance.new("Part")
	part.Name = "FlashlightBeam"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	local inner = newSpot(part, "Inner", INNER_ANGLE, INNER_RANGE, true)
	local outer = newSpot(part, "Outer", OUTER_ANGLE, OUTER_RANGE, false)
	local glow = Instance.new("PointLight")
	glow.Name = "Glow"
	glow.Range = GLOW_RANGE
	glow.Brightness = GLOW_BRIGHTNESS
	glow.Color = GLOW_COLOR
	glow.Shadows = false
	glow.Enabled = false
	glow.Parent = part

	local predicted: boolean? = nil
	local predictedAt: number? = nil
	local lastToggleAt = -math.huge
	local on = false
	local output = 0
	local emf = 0
	local batteryFraction = 1
	local shadows = true
	local rotation: CFrame? = nil
	local staticVoice: SoundSynthesizer.Voice? = nil
	local staticVolume = 0
	local destroyed = false

	local function stopStatic()
		local voice = staticVoice
		staticVoice = nil
		if voice then
			voice:Stop(0.5)
		end
	end

	local function driveStatic(level: number)
		if level < STATIC_THRESHOLD then
			stopStatic()
			return
		end
		local volume = 0.25 + 0.75 * level
		local voice = staticVoice
		if voice == nil or not voice:IsPlaying() then
			staticVolume = volume
			staticVoice = AudioController.PlayLocal("EmfStatic", { looped = true, fadeIn = 0.3, volume = volume })
		elseif math.abs(volume - staticVolume) > STATIC_VOLUME_EPSILON then
			staticVolume = volume
			voice:SetVolume(volume, 0.15)
		end
	end

	local light: Light = {
		Toggle = function(_self: Light, now: number)
			if destroyed or now - lastToggleAt < TOGGLE_COOLDOWN then
				return
			end
			lastToggleAt = now
			AudioController.PlayLocal("UiClick")
			local want = not on
			if want and batteryFraction <= 0 then
				return -- a dead cell: the switch clicks and nothing happens
			end
			predicted = want
			predictedAt = now
			on = want
			xpcall(Net.Client.fire, function(err: any)
				log.warnThrottled("toggle", 10, "FlashlightToggle failed: %s", tostring(err))
			end, "FlashlightToggle", { on = want })
		end,
		Update = function(_self: Light, context: UpdateContext)
			if destroyed then
				return
			end
			local serverOn = Attributes.getBool(player, P.FlashlightOn, false)
			if predicted ~= nil and predicted == serverOn then
				predicted, predictedAt = nil, nil
			end
			on = Flashlight.resolveOn(serverOn, predicted, predictedAt, context.now, Flashlight.ReconcileGrace)

			local maxBattery = Attributes.getNumber(player, P.BatteryMax, GameConfig.BatteryMax)
			local battery =
				Attributes.readMeter(player, P.Battery, P.BatteryRate, P.BatteryAt, maxBattery, context.serverNow)
			batteryFraction = if maxBattery > 0 then MathUtil.clamp01(battery / maxBattery) else 0

			emf = if context.allowed then Flashlight.emfAt(context.look.Position, context.zoneId) else 0
			driveStatic(emf)

			local camera = context.camera
			local holder = Instances.cosmetic()
			if camera == nil or not context.allowed then
				output = 0
				inner.Enabled = false
				outer.Enabled = false
				glow.Enabled = false
				rotation = nil
				return
			end
			-- A client-local folder in Workspace, never the camera: lights under the camera are not reliably rendered.
			if part.Parent ~= holder then
				part.Parent = holder
			end
			if not glow.Enabled then
				glow.Enabled = true
			end

			local target = context.look.Rotation
				* CFrame.Angles(-LOWERED_PITCH * MathUtil.clamp01(context.lowered), 0, 0)
			local previous = rotation
			local current: CFrame = if previous
				then previous:Lerp(target, MathUtil.damp(LAG_SPEED, context.dt))
				else target
			rotation = current
			local position = context.look:PointToWorldSpace(BEAM_OFFSET)
			part.CFrame = CFrame.new(position) * current

			if not (on and batteryFraction > 0) then
				output = 0
				if inner.Enabled then
					inner.Enabled = false
				end
				if outer.Enabled then
					outer.Enabled = false
				end
				return
			end

			local seed = player.UserId
			local flicker = Flashlight.flickerFactor(emf, context.serverNow, seed)
			flicker = 1 - (1 - flicker) * MathUtil.clamp01(context.flashScale)
			output = Flashlight.batteryFactor(batteryFraction)
				* Flashlight.sputter(batteryFraction, context.serverNow, seed)
				* flicker
			local color = Flashlight.beamColor(batteryFraction)
			inner.Enabled = output > 0.01
			outer.Enabled = output > 0.01
			inner.Brightness = INNER_BRIGHTNESS * output
			outer.Brightness = OUTER_BRIGHTNESS * output
			if inner.Color ~= color then
				inner.Color = color
				outer.Color = color
			end
			if inner.Shadows ~= shadows then
				inner.Shadows = shadows
			end
		end,
		SetShadows = function(_self: Light, enabled: boolean)
			shadows = enabled
		end,
		IsOn = function(_self: Light): boolean
			return on
		end,
		GetOutput = function(_self: Light): number
			return output
		end,
		GetEmf = function(_self: Light): number
			return emf
		end,
		GetBatteryFraction = function(_self: Light): number
			return batteryFraction
		end,
		Reset = function(_self: Light)
			predicted, predictedAt = nil, nil
			rotation = nil
		end,
		Destroy = function(_self: Light)
			destroyed = true
			stopStatic()
			part:Destroy()
		end,
	}
	return light
end

return table.freeze(Flashlight)
