--!strict
-- PanicVFX: the local player's panic level (0..1) and everything it drives.
--
-- Target panic = clamp01(max(proximity, chase floor, external floors) + downed bonus):
--   * proximity: the Creature (Instances.creature(), not Hidden) between CameraConfig.Panic.CreatureNearDistance
--     (1) and CreatureFarDistance (0) on a smoothstep; full weight with line of sight (eye to the Creature's eye,
--     a Default-group ray that ignores every character and the Creature itself, so lockers and desks block it),
--     OCCLUDED_SHARE of it through walls (it is right there, you can hear it). Sensed at SENSE_HZ.
--   * chase floor: the Creature's TargetUserId is me and its MonsterState is WallChase or VentChase.
--   * external floors: SetFloor(token, value) from later systems (struggles, scripted beats); the highest wins.
--   * Downed: +DOWNED_BONUS.
-- Panic approaches the target at CameraConfig.Panic.RiseSpeed per second going up and FallSpeed going down.
--
-- Outputs (Apply):
--   * a ColorCorrectionEffect and a DepthOfFieldEffect parented under the current camera (LightingController owns
--     Lighting; these are ours): saturation, contrast and a red tint scale with panic; far blur only when the render
--     budget allows depth of field;
--   * a vignette: a full-screen ScreenGui of four edge frames whose UIGradients fade from the screen edge inward
--     (no images). It is faint at rest, closes in and darkens with panic, and throbs with the heartbeat at high
--     panic (the throb scales with FlashScale);
--   * the FOV bonus (fovBonus, scaled by MotionScale; FirstPersonController adds it) and a heartbeat-synced FOV warp;
--   * Body-bus loops through AudioController.PlayLocal: Heartbeat above HEART_SLOW, HeartbeatFast above HEART_FAST;
--     Breathing above BREATH_SLOW, BreathingPanic above BREATH_FAST, where the breathing level is the higher of panic
--     and exertion (low stamina). Thresholds have hysteresis; volume follows the level; loops that something else
--     stopped (AudioController ends Body voices with the run) are restarted when still wanted.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local SoundSynthesizer = require(ReplicatedStorage.Shared.Audio.SoundSynthesizer)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)

local AudioController = require(script.Parent.Parent.Parent.Core.AudioController)

local C = Attributes.Creature
local Panic = CameraConfig.Panic

export type TargetInputs = {
	proximity: number,
	chased: boolean,
	floor: number,
	downed: boolean,
}

export type ApplyContext = {
	camera: Camera?,
	dof: boolean, -- render budget allows depth of field
	flashScale: number,
	visible: boolean, -- false hides every effect (camera handed back, no character)
	exertion: number, -- 0..1 breathlessness from low stamina
}

export type PanicFx = {
	SetFloor: (self: PanicFx, token: string, value: number?) -> (),
	ClearFloors: (self: PanicFx) -> (),
	Sense: (self: PanicFx, dt: number, eye: Vector3?) -> (),
	Step: (self: PanicFx, dt: number, downed: boolean) -> number,
	Apply: (self: PanicFx, dt: number, context: ApplyContext) -> (),
	GetPanic: (self: PanicFx) -> number,
	IsChased: (self: PanicFx) -> boolean,
	FovWarp: (self: PanicFx, motionScale: number) -> number,
	Destroy: (self: PanicFx) -> (),
}

local PanicVFX = {}

PanicVFX.OccludedShare = 0.3
PanicVFX.DownedBonus = 0.4

local SENSE_HZ = 10
local CHASE_STATES: { [string]: boolean } = { WallChase = true, VentChase = true }

local HEART_SLOW = 0.25
local HEART_FAST = 0.62
local BREATH_SLOW = 0.18
local BREATH_FAST = 0.55
local HYSTERESIS = 0.06
local HEART_SLOW_PERIOD = 0.92 -- SynthPresets Heartbeat pulse interval
local HEART_FAST_PERIOD = 0.43 -- SynthPresets HeartbeatFast pulse interval
local LOOP_FADE_IN = 0.8
local LOOP_FADE_OUT = 1.2
local VOLUME_EPSILON = 0.03

local REST_VIGNETTE = 0.28 -- edge opacity with no panic
local VIGNETTE_REST_DEPTH = 0.2 -- edge band size (share of the screen) at rest
local VIGNETTE_FULL_DEPTH = 0.42
local SIDE_SHARE = 0.55 -- side bands are a share of the width, so they read as thick as the top and bottom
local PULSE_OPACITY = 0.12
local WARP_DEGREES = 1.4
local DOF_FOCUS = 9
local DOF_RADIUS_REST = 26
local DOF_RADIUS_FULL = 12
local EFFECT_MIN = 0.004

--------------------------------------------------------------------------------
-- Pure maths
--------------------------------------------------------------------------------

-- Proximity panic for a Creature `distance` studs away.
function PanicVFX.proximity(distance: number, visible: boolean): number
	if distance ~= distance then
		return 0
	end
	local raw = 1 - MathUtil.smoothstep(Panic.CreatureNearDistance, Panic.CreatureFarDistance, distance)
	return if visible then raw else raw * PanicVFX.OccludedShare
end

function PanicVFX.target(inputs: TargetInputs): number
	local level = math.max(inputs.proximity, if inputs.chased then Panic.ChaseFloor else 0, inputs.floor)
	if inputs.downed then
		level += PanicVFX.DownedBonus
	end
	return MathUtil.clamp01(level)
end

-- Panic after `dt` seconds moving toward `target` (rises fast, falls slowly).
function PanicVFX.integrate(current: number, target: number, dt: number): number
	local rate = if target > current then Panic.RiseSpeed else Panic.FallSpeed
	return MathUtil.clamp01(MathUtil.approach(current, target, rate * math.max(dt, 0)))
end

function PanicVFX.fovBonus(panic: number, motionScale: number): number
	return CameraConfig.FieldOfView.PanicMaxBonus * MathUtil.clamp01(panic) * MathUtil.clamp01(motionScale)
end

-- ColorCorrection values: saturation, contrast, tint.
function PanicVFX.grade(panic: number): (number, number, Color3)
	local p = MathUtil.clamp01(panic)
	return Panic.Saturation * p, Panic.Contrast * p, Color3.new(1, 1, 1):Lerp(Panic.TintRed, p)
end

-- Vignette edge opacity (0..1) for a panic level and a heartbeat pulse 0..1.
function PanicVFX.vignetteOpacity(panic: number, pulse: number, flashScale: number): number
	local p = MathUtil.clamp01(panic)
	local full = 1 - Panic.VignetteTransparencyAtFull
	local base = MathUtil.lerp(REST_VIGNETTE, full, p)
	return MathUtil.clamp01(base + PULSE_OPACITY * p * MathUtil.clamp01(pulse) * MathUtil.clamp01(flashScale))
end

-- Which heartbeat loop a panic level wants, given the one playing (hysteresis on both thresholds).
function PanicVFX.heartbeatPreset(panic: number, current: string?): string?
	local fastEdge = if current == "HeartbeatFast" then HEART_FAST - HYSTERESIS else HEART_FAST
	local slowEdge = if current ~= nil then HEART_SLOW - HYSTERESIS else HEART_SLOW
	if panic >= fastEdge then
		return "HeartbeatFast"
	elseif panic >= slowEdge then
		return "Heartbeat"
	end
	return nil
end

-- Which breathing loop a breathlessness level wants, given the one playing.
function PanicVFX.breathingPreset(level: number, current: string?): string?
	local fastEdge = if current == "BreathingPanic" then BREATH_FAST - HYSTERESIS else BREATH_FAST
	local slowEdge = if current ~= nil then BREATH_SLOW - HYSTERESIS else BREATH_SLOW
	if level >= fastEdge then
		return "BreathingPanic"
	elseif level >= slowEdge then
		return "Breathing"
	end
	return nil
end

-- Heartbeat pulse 0..1 at `phase` (beats): a sharp lub and a softer dub.
function PanicVFX.pulse(phase: number): number
	local p = phase % 1
	local lub = math.exp(-((p - 0.05) / 0.06) ^ 2)
	local dub = 0.6 * math.exp(-((p - 0.33) / 0.07) ^ 2)
	return math.max(lub, dub)
end

--------------------------------------------------------------------------------
-- Runtime
--------------------------------------------------------------------------------

type Loop = { preset: string?, voice: SoundSynthesizer.Voice?, volume: number }

local function newEdge(parent: Instance, name: string, rotation: number): (Frame, UIGradient)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.Active = false
	frame.Selectable = false
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.45, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = frame
	frame.Parent = parent
	return frame, gradient
end

local function stopLoop(loop: Loop)
	local voice = loop.voice
	loop.voice = nil
	loop.preset = nil
	if voice then
		voice:Stop(LOOP_FADE_OUT)
	end
end

-- Keeps `loop` playing `want` at `volume` (nil stops it).
local function driveLoop(loop: Loop, want: string?, volume: number)
	if want == nil then
		stopLoop(loop)
		return
	end
	local voice = loop.voice
	if loop.preset ~= want or voice == nil or not voice:IsPlaying() then
		if voice then
			voice:Stop(LOOP_FADE_OUT * 0.5)
		end
		loop.preset = want
		loop.volume = volume
		loop.voice = AudioController.PlayLocal(want, { looped = true, fadeIn = LOOP_FADE_IN, volume = volume })
		return
	end
	if math.abs(loop.volume - volume) > VOLUME_EPSILON then
		loop.volume = volume
		voice:SetVolume(volume, 0.4)
	end
end

function PanicVFX.new(player: Player): PanicFx
	local panic = 0
	local floors: { [string]: number } = {}
	local proximity = 0
	local chased = false
	local senseClock = math.huge
	local heartPhase = 0
	local heart: Loop = { preset = nil, voice = nil, volume = 0 }
	local breath: Loop = { preset = nil, voice = nil, volume = 0 }
	local destroyed = false

	local grade: ColorCorrectionEffect? = nil
	local focus: DepthOfFieldEffect? = nil
	local gui: ScreenGui? = nil
	local edges: { Frame } = {}
	local lastOpacity = -1
	local lastDepth = -1

	local function ensureGui(): ScreenGui?
		local existing = gui
		if existing and existing.Parent ~= nil then
			return existing
		end
		local playerGui = player:FindFirstChildOfClass("PlayerGui")
		if not playerGui then
			return nil
		end
		local screen = Instance.new("ScreenGui")
		screen.Name = "PanicVignette"
		screen.ResetOnSpawn = false
		screen.ScreenInsets = Enum.ScreenInsets.None
		screen.DisplayOrder = -10
		screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		local top = newEdge(screen, "Top", 90)
		top.Position = UDim2.fromScale(0, 0)
		local bottom = newEdge(screen, "Bottom", -90)
		bottom.AnchorPoint = Vector2.new(0, 1)
		bottom.Position = UDim2.fromScale(0, 1)
		local left = newEdge(screen, "Left", 0)
		left.Position = UDim2.fromScale(0, 0)
		local right = newEdge(screen, "Right", 180)
		right.AnchorPoint = Vector2.new(1, 0)
		right.Position = UDim2.fromScale(1, 0)
		edges = { top, bottom, left, right }
		lastOpacity = -1
		lastDepth = -1
		screen.Parent = playerGui
		gui = screen
		return screen
	end

	local function ensureEffects(camera: Camera)
		local cc = grade
		if not cc or cc.Parent ~= camera then
			if cc then
				cc:Destroy()
			end
			local made = Instance.new("ColorCorrectionEffect")
			made.Name = "PanicGrade"
			made.Enabled = false
			made.Parent = camera
			grade = made
		end
		local dof = focus
		if not dof or dof.Parent ~= camera then
			if dof then
				dof:Destroy()
			end
			local made = Instance.new("DepthOfFieldEffect")
			made.Name = "PanicFocus"
			made.Enabled = false
			made.NearIntensity = 0
			made.FocusDistance = DOF_FOCUS
			made.Parent = camera
			focus = made
		end
	end

	local function sense(eye: Vector3?)
		proximity = 0
		chased = false
		local creature = Instances.creature()
		local root = Instances.creatureRoot()
		if not creature or not root then
			return
		end
		local target = creature:GetAttribute(C.TargetUserId)
		local state = Attributes.getString(creature, C.MonsterState, "Dormant")
		chased = target == player.UserId and CHASE_STATES[state] == true
		if eye == nil or Attributes.getBool(creature, C.Hidden, false) then
			return
		end
		local creatureEye = SpatialQuery.creatureEye(root, Attributes.getString(creature, C.PoseMode, "Biped"))
		local distance = (creatureEye - eye).Magnitude
		if distance >= Panic.CreatureFarDistance then
			return
		end
		local exclude: { Instance } = { creature }
		for _, other in Players:GetPlayers() do
			local character = other.Character
			if character then
				table.insert(exclude, character)
			end
		end
		local camera = Workspace.CurrentCamera
		if camera then
			table.insert(exclude, camera)
		end
		local visible = SpatialQuery.lineClear(eye, creatureEye, SpatialQuery.losParams(exclude), creature)
		proximity = PanicVFX.proximity(distance, visible)
	end

	local fx: PanicFx = {
		SetFloor = function(_self: PanicFx, token: string, value: number?)
			if value == nil or value ~= value then
				floors[token] = nil
			else
				floors[token] = MathUtil.clamp01(value)
			end
		end,
		ClearFloors = function(_self: PanicFx)
			table.clear(floors)
		end,
		Sense = function(_self: PanicFx, dt: number, eye: Vector3?)
			senseClock += dt
			if senseClock < 1 / SENSE_HZ then
				return
			end
			senseClock = 0
			sense(eye)
		end,
		Step = function(_self: PanicFx, dt: number, downed: boolean): number
			local floor = 0
			for _, value in floors do
				floor = math.max(floor, value)
			end
			local target = PanicVFX.target({ proximity = proximity, chased = chased, floor = floor, downed = downed })
			panic = PanicVFX.integrate(panic, target, dt)
			local period = if panic >= HEART_FAST then HEART_FAST_PERIOD else HEART_SLOW_PERIOD
			heartPhase = (heartPhase + dt / period) % 1
			return panic
		end,
		Apply = function(_self: PanicFx, _dt: number, context: ApplyContext)
			if destroyed then
				return
			end
			local camera = context.camera
			local visible = context.visible and camera ~= nil
			local p = if visible then panic else 0
			if camera then
				ensureEffects(camera)
			end
			local cc = grade
			if cc then
				local saturation, contrast, tint = PanicVFX.grade(p)
				local on = p > EFFECT_MIN
				if cc.Enabled ~= on then
					cc.Enabled = on
				end
				if on then
					cc.Saturation = saturation
					cc.Contrast = contrast
					cc.TintColor = tint
				end
			end
			local dof = focus
			if dof then
				local on = context.dof and p > EFFECT_MIN * 5
				if dof.Enabled ~= on then
					dof.Enabled = on
				end
				if on then
					dof.FarIntensity = Panic.DofFarIntensity * p
					dof.InFocusRadius = MathUtil.lerp(DOF_RADIUS_REST, DOF_RADIUS_FULL, p)
				end
			end

			local screen = if visible then ensureGui() else gui
			if screen then
				if screen.Enabled ~= visible then
					screen.Enabled = visible
				end
				if visible then
					local opacity = PanicVFX.vignetteOpacity(p, PanicVFX.pulse(heartPhase), context.flashScale)
					local depth = MathUtil.lerp(VIGNETTE_REST_DEPTH, VIGNETTE_FULL_DEPTH, p)
					if math.abs(opacity - lastOpacity) > 0.004 then
						lastOpacity = opacity
						for _, edge in edges do
							edge.BackgroundTransparency = 1 - opacity
						end
					end
					if math.abs(depth - lastDepth) > 0.002 then
						lastDepth = depth
						edges[1].Size = UDim2.fromScale(1, depth)
						edges[2].Size = UDim2.fromScale(1, depth)
						edges[3].Size = UDim2.fromScale(depth * SIDE_SHARE, 1)
						edges[4].Size = UDim2.fromScale(depth * SIDE_SHARE, 1)
					end
				end
			end

			local breathless = math.max(p, if visible then MathUtil.clamp01(context.exertion) else 0)
			local wantHeart = if visible then PanicVFX.heartbeatPreset(p, heart.preset) else nil
			driveLoop(heart, wantHeart, 0.35 + 0.65 * p)
			local wantBreath = if visible then PanicVFX.breathingPreset(breathless, breath.preset) else nil
			driveLoop(breath, wantBreath, 0.3 + 0.7 * breathless)
		end,
		GetPanic = function(_self: PanicFx): number
			return panic
		end,
		IsChased = function(_self: PanicFx): boolean
			return chased
		end,
		FovWarp = function(_self: PanicFx, motionScale: number): number
			return WARP_DEGREES * panic * PanicVFX.pulse(heartPhase) * MathUtil.clamp01(motionScale)
		end,
		Destroy = function(_self: PanicFx)
			destroyed = true
			stopLoop(heart)
			stopLoop(breath)
			local cc, dof, screen = grade, focus, gui
			grade, focus, gui = nil, nil, nil
			if cc then
				cc:Destroy()
			end
			if dof then
				dof:Destroy()
			end
			if screen then
				screen:Destroy()
			end
		end,
	}
	return fx
end

return table.freeze(PanicVFX)
