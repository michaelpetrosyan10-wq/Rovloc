--!strict
-- ViewBob: procedural camera motion layered on top of the look (never fed back into it).
--
--   * Gait bob. A phase counts gait cycles (two footfalls each) and advances at CameraConfig.Bob.WalkFrequency x the
--     MoveState profile's cadence x the speed ratio (clamped, so slowing down fades the bob instead of stretching it
--     into slow motion). Per cycle: the eye dips at each footfall (vertical, twice a cycle, zero mean), nods down a
--     beat later (pitch), and sways once side to side (roll + a small lateral shift). Amplitude follows a smoothed
--     intensity (speed / the profile's nominal speed, faded in the air), so starting, stopping and posture changes
--     ease in and out.
--   * Breathing sway. A slow pitch swell with a little yaw drift, strongest when standing still; panic speeds it up
--     and deepens it (CameraConfig.Bob.PanicBreathMultiplier). Its phase is integrated, so a changing rate never
--     jumps.
--   * Shake. Shake(amplitudeDeg, seconds) impulses: value noise at CameraConfig.Shake.Frequency on three axes,
--     decaying at CameraConfig.Shake.Decay per second and fading out over the impulse's last quarter second; the
--     strongest live impulse leads and the others add a fraction. A continuous chase tremor (ChaseAmplitude x the
--     chase drive) sits underneath.
-- Everything is multiplied by the MotionScale setting (0 = a perfectly still camera). The pure pieces are exported
-- for the specs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

local CameraStates = require(script.Parent.CameraStates)

export type Inputs = {
	speed: number, -- horizontal studs/s
	profile: CameraStates.BobProfile,
	panic: number, -- 0..1
	motionScale: number, -- 0..1
	chase: number, -- 0..1 continuous tremor drive
	grounded: boolean,
}

type Impulse = { amplitude: number, seconds: number, age: number }

export type Bob = {
	Step: (self: Bob, dt: number, inputs: Inputs) -> CFrame,
	Shake: (self: Bob, amplitudeDeg: number, seconds: number) -> (),
	Reset: (self: Bob) -> (),
	Phase: (self: Bob) -> number,
}

local ViewBob = {}

local TAU = math.pi * 2
local B = CameraConfig.Bob
local S = CameraConfig.Shake

local INTENSITY_SMOOTH = 7 -- 1/s approach of the bob intensity
local AIR_INTENSITY = 0.2 -- share of the bob kept while airborne
local MAX_INTENSITY = 1.25
local MIN_CADENCE = 0.55 -- the gait never runs slower than this share of its nominal cadence while it shows
local PITCH_LAG = 0.6 -- radians the nod trails the dip
local LATERAL_SHARE = 0.35 -- lateral sway (studs) as a share of the vertical amplitude
local BREATH_RATE_PANIC = 1.6 -- breathing rate multiplier added at full panic
local BREATH_YAW_SHARE = 0.35
local IDLE_SPEED = 0.6 -- below this ratio of nominal speed the breathing sway is fully present
local SHAKE_TAIL = 0.25 -- seconds over which an impulse fades out at its end
local SHAKE_EXTRA = 0.35 -- share of the non-leading impulses added on top
local MAX_IMPULSES = 8
local SHAKE_SEED = 7

-- Gait bob at `phase` (cycles) for an intensity 0..1+ and amplitude multiplier. Degrees and studs:
-- pitch (look up positive), roll, vertical, lateral.
function ViewBob.bob(phase: number, intensity: number, amplitude: number): (number, number, number, number)
	local theta = TAU * phase
	local scale = intensity * amplitude
	local vertical = -B.WalkVertical * scale * math.cos(2 * theta)
	local pitch = -B.WalkPitch * scale * math.cos(2 * theta - PITCH_LAG)
	local roll = B.WalkRoll * scale * math.sin(theta)
	local lateral = B.WalkVertical * LATERAL_SHARE * scale * math.sin(theta)
	return pitch, roll, vertical, lateral
end

-- Breathing sway at `phase` (breath cycles) for a panic level. Degrees: pitch, yaw.
function ViewBob.breath(phase: number, panic: number): (number, number)
	local depth = B.IdleBreathPitch * (1 + (B.PanicBreathMultiplier - 1) * MathUtil.clamp01(panic))
	local pitch = depth * math.sin(TAU * phase)
	local yaw = depth * BREATH_YAW_SHARE * math.sin(math.pi * phase + 1.3)
	return pitch, yaw
end

-- Breathing rate (cycles per second) for a panic level.
function ViewBob.breathRate(panic: number): number
	return B.IdleBreathFrequency * (1 + BREATH_RATE_PANIC * MathUtil.clamp01(panic))
end

-- Envelope 0..1 of a shake impulse `age` seconds into its `seconds` lifetime.
function ViewBob.shakeEnvelope(age: number, seconds: number, decay: number): number
	if age < 0 or seconds <= 0 or age >= seconds then
		return 0
	end
	local tail = math.min(SHAKE_TAIL, seconds)
	local fade = MathUtil.clamp01((seconds - age) / tail)
	return math.exp(-decay * age) * fade
end

-- Shake rotation (degrees pitch, yaw, roll) at time `t` for an amplitude, from seeded value noise.
function ViewBob.shakeAngles(t: number, amplitude: number, seed: number): (number, number, number)
	local x = t * S.Frequency
	return amplitude * MathUtil.noise1(x, seed),
		amplitude * 0.8 * MathUtil.noise1(x, seed + 17),
		amplitude * 0.6 * MathUtil.noise1(x, seed + 31)
end

-- Target bob intensity for a speed under a profile.
function ViewBob.intensity(speed: number, profile: CameraStates.BobProfile, grounded: boolean): number
	if profile.amplitude <= 0 or profile.nominalSpeed <= 0 then
		return 0
	end
	local ratio = math.clamp(speed / profile.nominalSpeed, 0, MAX_INTENSITY)
	return if grounded then ratio else ratio * AIR_INTENSITY
end

function ViewBob.new(): Bob
	local phase = 0
	local intensity = 0
	local amplitude = 1
	local breathPhase = 0
	local clock = 0
	local impulses: { Impulse } = {}

	local bob: Bob = {
		Step = function(_self: Bob, dt: number, inputs: Inputs): CFrame
			clock += dt
			local profile = inputs.profile
			local blend = MathUtil.damp(INTENSITY_SMOOTH, dt)
			intensity = MathUtil.lerp(intensity, ViewBob.intensity(inputs.speed, profile, inputs.grounded), blend)
			amplitude = MathUtil.lerp(amplitude, profile.amplitude, blend)
			if intensity > 1e-3 and profile.nominalSpeed > 0 then
				local cadence = math.clamp(inputs.speed / profile.nominalSpeed, MIN_CADENCE, MAX_INTENSITY)
				phase = (phase + dt * B.WalkFrequency * profile.frequency * cadence) % 1
			end
			breathPhase = (breathPhase + dt * ViewBob.breathRate(inputs.panic)) % 2

			local pitch, roll, vertical, lateral = ViewBob.bob(phase, intensity, amplitude)
			local idle = 1 - MathUtil.clamp01(intensity / IDLE_SPEED)
			local breathPitch, breathYaw = ViewBob.breath(breathPhase, inputs.panic)
			local breathShare = 0.35 + 0.65 * idle
			pitch += breathPitch * breathShare
			local yaw = breathYaw * breathShare

			-- Shake: the strongest live impulse leads, the rest add a share; the chase tremor sits underneath.
			local lead = 0
			local extra = 0
			for index = #impulses, 1, -1 do
				local impulse = impulses[index]
				impulse.age += dt
				local level = impulse.amplitude * ViewBob.shakeEnvelope(impulse.age, impulse.seconds, S.Decay)
				if impulse.age >= impulse.seconds then
					table.remove(impulses, index)
				elseif level > lead then
					extra += lead
					lead = level
				else
					extra += level
				end
			end
			local shake = lead + extra * SHAKE_EXTRA + S.ChaseAmplitude * MathUtil.clamp01(inputs.chase)
			if shake > 1e-4 then
				local sp, sy, sr = ViewBob.shakeAngles(clock, shake, SHAKE_SEED)
				pitch += sp
				yaw += sy
				roll += sr
			end

			local motion = MathUtil.clamp01(inputs.motionScale)
			return CFrame.new(lateral * motion, vertical * motion, 0)
				* CFrame.fromOrientation(math.rad(pitch * motion), math.rad(yaw * motion), math.rad(roll * motion))
		end,
		Shake = function(_self: Bob, amplitudeDeg: number, seconds: number)
			if not (amplitudeDeg > 0 and seconds > 0) or amplitudeDeg ~= amplitudeDeg or seconds ~= seconds then
				return
			end
			table.insert(impulses, {
				amplitude = math.min(amplitudeDeg, 20),
				seconds = math.min(seconds, 30),
				age = 0,
			})
			while #impulses > MAX_IMPULSES do
				table.remove(impulses, 1)
			end
		end,
		Reset = function(_self: Bob)
			phase = 0
			intensity = 0
			amplitude = 1
			table.clear(impulses)
		end,
		Phase = function(_self: Bob): number
			return phase
		end,
	}
	return bob
end

return table.freeze(ViewBob)
