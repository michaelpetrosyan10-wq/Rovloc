--!strict
-- CameraRig: look input (mouse, gamepad, touch) and the eye pivot of an R15 rig.
--
-- Look input. Every device feeds one per-frame delta that FirstPersonController adds to yaw / pitch inside its
-- render step, so input never lags a frame:
--   * Mouse: raw InputObject.Delta of every MouseMovement event since the last frame (not GetMouseDelta, which the
--     Roblox menu sensitivity rescales), only while the cursor is locked to the centre (CursorController locks it in
--     play). x CameraConfig.Mouse.RadiansPerPixel x the MouseSensitivity setting. No smoothing, no acceleration.
--   * Gamepad: the right stick through a radial deadzone and a power response curve (fine aim near the centre, full
--     rate at the rim), x GamepadRadiansPerSecond x GamepadSensitivity; pitch runs at PITCH_RATIO of the yaw rate.
--     Holding the stick at the rim for a moment ramps a yaw boost so a full turn stays quick.
--   * Touch: one finger tracked by its InputObject from the moment it lands outside any GUI (gameProcessed false:
--     the movement thumbstick, the jump button and every HUD button are GUI) and on the look side of the screen (right
--     of TOUCH_LOOK_MIN_X, or anywhere in the top band); its position deltas x TouchRadiansPerPixel x
--     TouchSensitivity. Other fingers are ignored until it lifts.
-- InvertY flips pitch on every device. Pitch ranges come from the camera state: input cannot push past a limit, and
-- when the range tightens (crawling into a duct) the pitch eases inside instead of snapping.
--
-- Eye pivot. The eye is measured from the rig's rest pose (Motor6D C0 / C1 of Root -> Waist -> Neck, which ignore
-- the animator's Transforms), so it sits where the visible head is. It rotates about the neck by NECK_SHARE of the
-- pitch: looking down carries the eye forward over the chest, which keeps the torso out of the near plane and puts
-- your own feet in view, as a real neck does.
--
-- LookRelay quantization: int16 per angle (MathUtil.quantizeAngle); a sample is due when either angle moved more
-- than an epsilon in quantized units (wrap-aware at ±pi).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)

export type LookSettings = {
	mouse: number,
	gamepad: number,
	touch: number,
	invertY: boolean,
}

export type EyeMetrics = {
	neckHeight: number, -- rest neck joint above the root centre
	neckForward: number, -- rest neck joint ahead of the root centre
	eyeUp: number, -- eye above the neck joint
	eyeForward: number, -- eye ahead of the neck joint
}

export type Rig = {
	Connect: (self: Rig, trove: Trove.Trove) -> (),
	Consume: (self: Rig, dt: number, settings: LookSettings, enabled: boolean) -> (number, number),
	Reset: (self: Rig) -> (),
	HasTouch: (self: Rig) -> boolean,
}

local CameraRig = {}

CameraRig.GamepadDeadzone = 0.14
CameraRig.GamepadExponent = 1.7
CameraRig.PitchRatio = 0.75
CameraRig.TouchLookMinX = 0.4 -- fraction of the screen width; the left side belongs to the movement thumbstick
CameraRig.TouchLookTop = 0.3 -- fraction of the screen height; the top band looks from anywhere
CameraRig.NeckShare = 0.6
CameraRig.LookEpsilon = 64 -- int16 units, about 0.35 degrees

local BOOST_THRESHOLD = 0.92
local BOOST_DELAY = 0.22
local BOOST_RAMP = 0.35
local BOOST_MAX = 1.6
local SETTLE_SPEED = 10 -- 1/s pitch easing back into a tightened range
local SETTLE_MIN_RATE = 0.6 -- rad/s minimum easing rate (no asymptotic crawl)
local INT16_SPAN = 65534

local EYE_ABOVE_HEAD_CENTRE = 0.08 -- share of the head height
local EYE_FORWARD_SHARE = 0.28 -- share of the head depth
local DEFAULT_EYE_UP = 0.6

CameraRig.DefaultEye = table.freeze({
	neckHeight = CameraConfig.EyeHeightAboveRoot.Standing - DEFAULT_EYE_UP,
	neckForward = 0,
	eyeUp = DEFAULT_EYE_UP,
	eyeForward = 0.3,
} :: EyeMetrics)

--------------------------------------------------------------------------------
-- Pure maths
--------------------------------------------------------------------------------

-- Radial deadzone + power curve; keeps the stick's direction. Output magnitude 0..1.
function CameraRig.gamepadCurve(stick: Vector2, deadzone: number, exponent: number): Vector2
	local magnitude = stick.Magnitude
	if magnitude <= deadzone or magnitude ~= magnitude then
		return Vector2.zero
	end
	local normalized = math.min((magnitude - deadzone) / (1 - deadzone), 1)
	return stick.Unit * (normalized ^ exponent)
end

-- Yaw rate multiplier after holding the stick at the rim for `heldSeconds`.
function CameraRig.turnBoost(heldSeconds: number): number
	return 1 + (BOOST_MAX - 1) * MathUtil.clamp01((heldSeconds - BOOST_DELAY) / BOOST_RAMP)
end

-- Adds an input delta to pitch without letting input push past a limit (radians).
function CameraRig.applyPitch(pitch: number, delta: number, minPitch: number, maxPitch: number): number
	if delta > 0 then
		return math.min(pitch + delta, math.max(pitch, maxPitch))
	elseif delta < 0 then
		return math.max(pitch + delta, math.min(pitch, minPitch))
	end
	return pitch
end

-- Eases a pitch that lies outside [minPitch, maxPitch] back inside (radians); a pitch inside is unchanged.
function CameraRig.settlePitch(pitch: number, minPitch: number, maxPitch: number, dt: number): number
	if pitch > maxPitch then
		local eased = MathUtil.dampNumber(pitch, maxPitch, SETTLE_SPEED, dt)
		return math.max(maxPitch, math.min(eased, pitch - SETTLE_MIN_RATE * dt))
	elseif pitch < minPitch then
		local eased = MathUtil.dampNumber(pitch, minPitch, SETTLE_SPEED, dt)
		return math.min(minPitch, math.max(eased, pitch + SETTLE_MIN_RATE * dt))
	end
	return pitch
end

-- Should a touch that started at `position` drive the look?
function CameraRig.isLookTouch(position: Vector2, viewport: Vector2, gameProcessed: boolean): boolean
	if gameProcessed or viewport.X <= 0 or viewport.Y <= 0 then
		return false
	end
	return position.X >= viewport.X * CameraRig.TouchLookMinX or position.Y <= viewport.Y * CameraRig.TouchLookTop
end

-- Look angles as LookRelay int16 values.
function CameraRig.quantizeLook(yaw: number, pitch: number): (number, number)
	return MathUtil.quantizeAngle(yaw), MathUtil.quantizeAngle(pitch)
end

-- Distance between two int16 angles, the short way round.
function CameraRig.lookDistance(a: number, b: number): number
	local delta = (a - b) % INT16_SPAN
	if delta > INT16_SPAN / 2 then
		delta = INT16_SPAN - delta
	end
	return delta
end

-- (due, quantizedYaw, quantizedPitch): due when nothing was sent yet or either angle moved more than `epsilon`.
function CameraRig.shouldSendLook(
	lastYaw: number?,
	lastPitch: number?,
	yaw: number,
	pitch: number,
	epsilon: number
): (boolean, number, number)
	local qYaw, qPitch = CameraRig.quantizeLook(yaw, pitch)
	if lastYaw == nil or lastPitch == nil then
		return true, qYaw, qPitch
	end
	local due = CameraRig.lookDistance(qYaw, lastYaw) > epsilon or CameraRig.lookDistance(qPitch, lastPitch) > epsilon
	return due, qYaw, qPitch
end

local function motor(parent: Instance?, name: string, part0: Instance?, part1: Instance?): Motor6D?
	if parent == nil then
		return nil
	end
	local joint = parent:FindFirstChild(name)
	if joint and joint:IsA("Motor6D") and joint.Part0 == part0 and joint.Part1 == part1 then
		return joint
	end
	return nil
end

-- Eye metrics from a character's rest pose (R15 Root / Waist / Neck), or the defaults if the rig is not R15-shaped.
function CameraRig.measureEye(character: Model): EyeMetrics
	local root = character:FindFirstChild("HumanoidRootPart")
	local lower = character:FindFirstChild("LowerTorso")
	local upper = character:FindFirstChild("UpperTorso")
	local head = character:FindFirstChild("Head")
	local rootJoint = motor(lower, "Root", root, lower)
	local waist = motor(upper, "Waist", lower, upper)
	local neck = motor(head, "Neck", upper, head)
	if not (rootJoint and waist and neck and head and head:IsA("BasePart")) then
		return CameraRig.DefaultEye
	end
	local neckFrame = rootJoint.C0 * rootJoint.C1:Inverse() * waist.C0 * waist.C1:Inverse() * neck.C0
	local headCentre = neckFrame * neck.C1:Inverse()
	local size = head.Size
	local eyeUp = (headCentre.Y - neckFrame.Y) + size.Y * EYE_ABOVE_HEAD_CENTRE
	return {
		neckHeight = math.clamp(neckFrame.Y, 0.3, 2.6),
		neckForward = math.clamp(-neckFrame.Z, -0.5, 0.5),
		eyeUp = math.clamp(eyeUp, 0.2, 1.2),
		eyeForward = math.clamp(size.Z * EYE_FORWARD_SHARE, 0.18, 0.45),
	}
end

-- The eye relative to the root centre (world axes) for a look, before any camera-state offset.
function CameraRig.eyeOffset(metrics: EyeMetrics, yaw: number, pitch: number): Vector3
	local heading = CFrame.fromOrientation(0, yaw, 0)
	local neckTurn = CFrame.fromOrientation(pitch * CameraRig.NeckShare, yaw, 0)
	return Vector3.new(0, metrics.neckHeight, 0)
		+ heading:VectorToWorldSpace(Vector3.new(0, 0, -metrics.neckForward))
		+ neckTurn:VectorToWorldSpace(Vector3.new(0, metrics.eyeUp, -metrics.eyeForward))
end

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

function CameraRig.new(): Rig
	local mouse = Vector2.zero
	local touch = Vector2.zero
	local stick = Vector2.zero
	local boostHeld = 0
	local lookTouch: InputObject? = nil
	local lookTouchPosition = Vector2.zero

	local function releaseTouch()
		lookTouch = nil
	end

	local rig: Rig = {
		Connect = function(_self: Rig, trove: Trove.Trove)
			trove:Connect(UserInputService.InputChanged, function(input: InputObject, _processed: boolean)
				local inputType = input.UserInputType
				if inputType == Enum.UserInputType.MouseMovement then
					if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
						mouse += Vector2.new(input.Delta.X, input.Delta.Y)
					end
				elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
					stick = Vector2.new(input.Position.X, input.Position.Y)
				end
			end)
			trove:Connect(UserInputService.InputEnded, function(input: InputObject, _processed: boolean)
				if input.KeyCode == Enum.KeyCode.Thumbstick2 then
					stick = Vector2.zero
				end
			end)
			trove:Connect(UserInputService.GamepadDisconnected, function()
				stick = Vector2.zero
			end)
			trove:Connect(UserInputService.TouchStarted, function(input: InputObject, processed: boolean)
				if lookTouch ~= nil then
					return
				end
				local camera = Workspace.CurrentCamera
				local position = Vector2.new(input.Position.X, input.Position.Y)
				if camera and CameraRig.isLookTouch(position, camera.ViewportSize, processed) then
					lookTouch = input
					lookTouchPosition = position
				end
			end)
			trove:Connect(UserInputService.TouchMoved, function(input: InputObject, _processed: boolean)
				if input ~= lookTouch then
					return
				end
				local position = Vector2.new(input.Position.X, input.Position.Y)
				touch += position - lookTouchPosition
				lookTouchPosition = position
			end)
			trove:Connect(UserInputService.TouchEnded, function(input: InputObject, _processed: boolean)
				if input == lookTouch then
					releaseTouch()
				end
			end)
			trove:Connect(UserInputService.WindowFocusReleased, function()
				releaseTouch()
				stick = Vector2.zero
				mouse = Vector2.zero
			end)
		end,
		Consume = function(_self: Rig, dt: number, settings: LookSettings, enabled: boolean): (number, number)
			local mouseDelta, touchDelta = mouse, touch
			mouse, touch = Vector2.zero, Vector2.zero
			if not enabled then
				boostHeld = 0
				releaseTouch()
				return 0, 0
			end
			local invert = if settings.invertY then -1 else 1
			local M = CameraConfig.Mouse
			local yaw = -mouseDelta.X * M.RadiansPerPixel * settings.mouse
			local pitch = -mouseDelta.Y * M.RadiansPerPixel * settings.mouse * invert
			yaw -= touchDelta.X * M.TouchRadiansPerPixel * settings.touch
			pitch -= touchDelta.Y * M.TouchRadiansPerPixel * settings.touch * invert

			local curved = CameraRig.gamepadCurve(stick, CameraRig.GamepadDeadzone, CameraRig.GamepadExponent)
			if math.abs(curved.X) >= BOOST_THRESHOLD then
				boostHeld += dt
			else
				boostHeld = 0
			end
			local rate = M.GamepadRadiansPerSecond * settings.gamepad * dt
			yaw -= curved.X * rate * CameraRig.turnBoost(boostHeld)
			pitch += curved.Y * rate * CameraRig.PitchRatio * invert
			return yaw, pitch
		end,
		Reset = function(_self: Rig)
			mouse, touch, stick = Vector2.zero, Vector2.zero, Vector2.zero
			boostHeld = 0
			releaseTouch()
		end,
		HasTouch = function(_self: Rig): boolean
			return lookTouch ~= nil
		end,
	}
	return rig
end

return table.freeze(CameraRig)
