--!strict
-- JumpscareController: what being caught by the Creature looks like on this client, and what a teammate's catch
-- feels like nearby. JumpscareHandler (server) decides everything (the lock, the outcome); this only presents it.
--
-- Victim. The PrivateCue "JumpscareVictim" { kind, face } (startAt, endsAt) opens a session that runs on server time,
-- so it lands with the screech and the sting (both cued for the same startAt). startAt is honoured: nothing shows
-- before it, a late cue fast-forwards into the moment, and one that arrives after the hold is dropped. Elapsed time
-- is measured from startAt; the hold ends ("the cut") at endsAt, when the server downs or executes the victim.
--   * At startAt: InputContext "Cutscene" (nothing bound, look input stops), HUD.SetVisible(false), panic floor 1,
--     and FirstPersonController.PushOverride("Jumpscare", { cframe, fov = CameraConfig.FieldOfView.JumpscareFov })
--     with an almost instant blend in. The camera snaps onto the Creature's FaceFrontAttachment (the live, animated
--     head, so the face stays framed through the Lunge CreatureController plays for the same OneShot; the cue's face
--     point turned toward the eye while the rig is not there) at startDistance (where the eye was, clamped) and lunges
--     in to CreatureConfig.Jumpscare.FaceDistance over LungeSeconds on an overshooting ease: the face slams in past
--     FaceDistance and recoils to it (faceLockCFrame). On top, a violent shake (shakeOffset: noise rotation of up to
--     CameraConfig.Shake.JumpscareAmplitude times the envelope, peaking at the slam and sustained through the hold,
--     plus a positional jitter).
--   * The school is dark and the torch beam follows the player's own look, not the override, so a local PointLight
--     rides the locked camera and lights the face (faceLight): it flares with the snap and the slam, then holds,
--     stuttering like a torch under the Creature's interference.
--   * A procedural overlay ScreenGui (Frames and UIGradients only): a white flash at the snap, a red one at the slam,
--     a pulsing red vignette through the hold (overlay), and a hard cut to black at the end. Under the black the
--     override is popped (instantly), the face light goes out and the look is turned toward the Creature, the way the
--     server turned the body.
--   * After a beat in black, input, HUD and panic are handed back and the black fades out.
--   MotionScale scales the shake and the lunge's travel (0: a still camera held at FaceDistance); FlashScale scales
--   the flashes, the vignette's pulse and the light's stutter (0: no flashes, a steady vignette and a steady light; the
--   face is always lit). A catch called off early (the server's
--   aborted cue, the Jumpscare lock released before the hold is over, a new character) cuts to black at once and
--   restores after a shorter beat; the run ending tears everything down at once.
-- Witnesses. OneShot "Jumpscare" for somebody else (CreatureController already plays the Creature's Lunge for it):
-- at its startAt, within WitnessRadius / StingRadius of the victim, a distance-scaled shake (FirstPersonController.Shake,
-- which MotionScale scales), a local JumpscareSting quieter with distance and a short panic floor.
--
-- Pure maths (tests/Specs/Jumpscare.spec.luau): lungeProgress, lungeDistance, faceLock, faceLockCFrame,
-- startDistanceFor, shakeEnvelope, shakeOffset, cameraCFrame, overlay, faceLight, holdLength, witnessShake,
-- witnessSting, witnessPanic.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local CreatureRigBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.CreatureRigBuilder)

local Controllers = script.Parent.Parent
local AudioController = require(Controllers.Core.AudioController)
local InputController = require(Controllers.Core.InputController)
local SettingsController = require(Controllers.Core.SettingsController)
local FirstPersonController = require(Controllers.FirstPerson.FirstPersonController)
local HUD = require(Controllers.HUD)

local log = Log.new("JumpscareClient")

local P = Attributes.Player
local J = CreatureConfig.Jumpscare

local TOKEN = "Jumpscare"
local WITNESS_TOKEN = "JumpscareWitness"
local OVERRIDE: Enums.CameraOverride = "Jumpscare"
local CONTEXT: Enums.InputContext = "Cutscene"
local LOCK: Enums.ControlLock = "Jumpscare"
local VICTIM_CUE: Enums.CueKind = "JumpscareVictim"
local ONESHOT_KIND: Enums.OneShotKind = "Jumpscare"
local STING_PRESET = "JumpscareSting"
local FACE_ATTACHMENT = CreatureRigBuilder.PartNames.FaceAttachment

local TAU = math.pi * 2
local LUNGE = J.LungeSeconds
local HOLD = J.HoldSeconds
local FACE_DISTANCE = J.FaceDistance
local FOV = CameraConfig.FieldOfView.JumpscareFov

-- Lunge: where it starts and how it lands.
local MIN_START_DISTANCE = FACE_DISTANCE + 0.9
local MAX_START_DISTANCE = 5.5
local OVERSHOOT = 2.2 -- back-ease tension: the face slams about 15% of the travel past FaceDistance, then recoils
local CLOSEST = FACE_DISTANCE * 0.6 -- the slam never brings the camera nearer the face than this
-- The slam (the overshoot's deepest point) as a share of the lunge: where u = t - 1 minimises the back ease.
local SLAM_SHARE = 1 - 2 * OVERSHOOT / (3 * (OVERSHOOT + 1))
local SLAM_AT = LUNGE * SLAM_SHARE
local BLEND_IN = 0.04 -- seconds: the snap onto the face

-- Shake (multiples of CameraConfig.Shake.JumpscareAmplitude).
local SHAKE_DEGREES = CameraConfig.Shake.JumpscareAmplitude
local SHAKE_HZ = 19
local SHAKE_ONSET = 1
local SHAKE_SLAM = 1.8
local SHAKE_HOLD = 0.65
local SHAKE_DECAY = 5 -- 1/s from the slam toward the held level
local SHAKE_STUDS = 0.07 -- positional jitter at an envelope of 1

-- Overlay (opacities 0..1).
local FLASH_PEAK = 0.9
local SLAM_TINT = 0.6
local FLASH_SECONDS = 0.16
local VIGNETTE_PEAK = 0.55
local VIGNETTE_RISE = 0.08
local VIGNETTE_PULSE = 0.35 -- share of the vignette the pulse takes away at its trough (times FlashScale)
local VIGNETTE_HZ = 2.4 -- a smooth throb, well under three flashes a second
local BEAT = 0.6 -- seconds held in black after the cut
local ABORT_BEAT = 0.2
local FADE = 0.7 -- seconds the black takes to fade out
local DISPLAY_ORDER = 40 -- over the HUD (20) and its overlay (15)
local WHITE = Color3.fromRGB(255, 247, 238)
local BLOOD = Color3.fromRGB(150, 6, 4)
local BLOOD_EDGE = Color3.fromRGB(60, 0, 0)
local BLACK = Color3.new(0, 0, 0)
local PAINT_EPSILON = 0.002

-- Face light (PointLight brightness).
local LIGHT_FLARE = 5 -- at the snap
local LIGHT_SLAM = 2 -- added at the slam
local LIGHT_HOLD = 1.6 -- through the hold
local LIGHT_FLARE_DECAY = 8 -- 1/s from the snap's flare to the held level
local LIGHT_STUTTER = 0.35 -- share the stutter takes away at its deepest (times FlashScale)
local LIGHT_STUTTER_HZ = 6
local LIGHT_RANGE = 7
local LIGHT_COLOR = Color3.fromRGB(206, 220, 255)
local LIGHT_RISE = 0.25 -- studs above the camera, so the brow throws the sockets into shadow

-- Timing guards.
local MAX_LEAD = 1 -- seconds a cue may be scheduled ahead (clock skew guard)
local MAX_HOLD = 6 -- seconds from startAt an endsAt may lie
local LOCK_SLACK = 0.25 -- a Jumpscare lock released this close to the cut is the normal end, not an abort
local FACE_RESOLVE_INTERVAL = 0.25

-- Witnesses.
local WITNESS_RADIUS = 45
local WITNESS_SHAKE = CameraConfig.Shake.ImpactAmplitude * 2
local WITNESS_SHAKE_SECONDS = 0.9
local STING_RADIUS = 70
local STING_FULL = 8 -- full volume this close
local STING_VOLUME = 0.65
local WITNESS_PANIC = 0.7
local WITNESS_PANIC_SECONDS = 3

export type Overlay = { flash: number, tint: number, vignette: number, black: number }

type Paint = {
	gui: ScreenGui,
	edges: { Frame },
	tint: Frame,
	flash: Frame,
	black: Frame,
	written: { [Frame]: number },
}

type Session = {
	kind: string,
	startAt: number, -- server time
	cutAt: number, -- seconds after startAt the cut to black lands
	beat: number,
	facePoint: Vector3?, -- the cue's face point (fallback when the rig is not there)
	face: Attachment?,
	faceResolvedAt: number,
	fallbackFace: CFrame,
	startDistance: number,
	motionScale: number,
	flashScale: number,
	seed: number,
	trove: Trove.Trove,
	paint: Paint?,
	light: PointLight?,
	sawLock: boolean,
	hudWasVisible: boolean,
	begun: boolean,
	cut: boolean,
	restored: boolean,
}

local JumpscareController = {}

JumpscareController.Name = "JumpscareController"
JumpscareController.MinStartDistance = MIN_START_DISTANCE
JumpscareController.MaxStartDistance = MAX_START_DISTANCE
JumpscareController.Closest = CLOSEST
JumpscareController.SlamAt = SLAM_AT
JumpscareController.Beat = BEAT
JumpscareController.AbortBeat = ABORT_BEAT
JumpscareController.Fade = FADE
JumpscareController.LightHold = LIGHT_HOLD
JumpscareController.LightStutter = LIGHT_STUTTER
JumpscareController.WitnessRadius = WITNESS_RADIUS
JumpscareController.StingRadius = STING_RADIUS

local serviceTrove = Trove.new()
local runTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local session: Session? = nil
local witnessGeneration = 0

--------------------------------------------------------------------------------
-- Pure maths (specs: tests/Specs/Jumpscare.spec.luau)
--------------------------------------------------------------------------------

local function finiteOr(value: number, fallback: number): number
	return if MathUtil.isFinite(value) then value else fallback
end

-- Back ease out: 0 at 0, 1 at 1, overshooting above 1 in between.
local function backOut(t: number, tension: number): number
	local u = t - 1
	return 1 + (tension + 1) * u * u * u + tension * u * u
end

-- A fast spike at `at`: 1 there, falling (squared) to 0 over FLASH_SECONDS.
local function spike(t: number, at: number): number
	local age = t - at
	if age < 0 or age >= FLASH_SECONDS then
		return 0
	end
	local fall = 1 - age / FLASH_SECONDS
	return fall * fall
end

-- How far through the lunge (0..1) the moment is `elapsed` seconds after startAt.
function JumpscareController.lungeProgress(elapsed: number): number
	return MathUtil.clamp01(finiteOr(elapsed, 0) / LUNGE)
end

-- The camera's distance from the face at lunge `progress`: from `startDistance` (its travel scaled by `motionScale`)
-- in to FaceDistance on the back ease, never nearer than Closest.
function JumpscareController.lungeDistance(startDistance: number, progress: number, motionScale: number): number
	local motion = MathUtil.clamp01(finiteOr(motionScale, 1))
	local start = math.max(finiteOr(startDistance, FACE_DISTANCE), FACE_DISTANCE)
	local from = FACE_DISTANCE + (start - FACE_DISTANCE) * motion
	local eased = backOut(MathUtil.clamp01(finiteOr(progress, 0)), OVERSHOOT)
	return math.max(from + (FACE_DISTANCE - from) * eased, CLOSEST)
end

-- The camera `distance` studs out along the face's look, looking straight back at it, upright with the face.
function JumpscareController.faceLock(face: CFrame, distance: number): CFrame
	local target = face.Position
	if not MathUtil.isFiniteVector(target) then
		return face
	end
	local reach = math.max(finiteOr(distance, FACE_DISTANCE), 0.05)
	return CFrame.lookAt(target + face.LookVector * reach, target, face.UpVector)
end

-- The face-locked camera (no shake) for a face attachment frame and lunge progress.
function JumpscareController.faceLockCFrame(
	face: CFrame,
	progress: number,
	startDistance: number,
	motionScale: number
): CFrame
	return JumpscareController.faceLock(face, JumpscareController.lungeDistance(startDistance, progress, motionScale))
end

-- Where the lunge starts: the eye's distance from the face, clamped to [MinStartDistance, MaxStartDistance].
function JumpscareController.startDistanceFor(eye: Vector3, face: Vector3): number
	local offset = face - eye
	if not MathUtil.isFiniteVector(offset) then
		return MIN_START_DISTANCE
	end
	return math.clamp(offset.Magnitude, MIN_START_DISTANCE, MAX_START_DISTANCE)
end

-- The shake's strength (multiples of the jumpscare amplitude) `elapsed` seconds after startAt: from the onset up to
-- the slam, then decaying toward the held level; nothing outside the lunge and hold.
function JumpscareController.shakeEnvelope(elapsed: number): number
	if not MathUtil.isFinite(elapsed) or elapsed < 0 or elapsed >= LUNGE + HOLD then
		return 0
	end
	if elapsed < SLAM_AT then
		return MathUtil.lerp(SHAKE_ONSET, SHAKE_SLAM, MathUtil.smoothstep(0, SLAM_AT, elapsed))
	end
	return SHAKE_HOLD + (SHAKE_SLAM - SHAKE_HOLD) * math.exp(-SHAKE_DECAY * (elapsed - SLAM_AT))
end

-- The shake as a camera-space offset: rotation (pitch, yaw, roll) and a small jitter, from seeded smooth noise.
function JumpscareController.shakeOffset(elapsed: number, motionScale: number, seed: number): CFrame
	local level = JumpscareController.shakeEnvelope(elapsed) * MathUtil.clamp01(finiteOr(motionScale, 1))
	if level <= 0 then
		return CFrame.identity
	end
	local x = elapsed * SHAKE_HZ
	local function wobble(offset: number): number
		return math.clamp(MathUtil.noise1(x, seed + offset), -1, 1)
	end
	local turn = math.rad(SHAKE_DEGREES) * level
	local reach = SHAKE_STUDS * level
	return CFrame.new(wobble(43) * reach, wobble(59) * reach, 0)
		* CFrame.Angles(wobble(0) * turn, wobble(17) * turn * 0.8, wobble(31) * turn * 1.2)
end

-- The victim's camera `elapsed` seconds after startAt: the face lock along the lunge, shaken.
function JumpscareController.cameraCFrame(
	face: CFrame,
	elapsed: number,
	startDistance: number,
	motionScale: number,
	seed: number
): CFrame
	local locked =
		JumpscareController.faceLockCFrame(face, JumpscareController.lungeProgress(elapsed), startDistance, motionScale)
	return locked * JumpscareController.shakeOffset(elapsed, motionScale, seed)
end

-- The overlay `elapsed` seconds after startAt, for a cut `cutAt` seconds in held `beat` seconds in black: the snap's
-- white flash and the slam's red one (FlashScale), the red vignette (its pulse FlashScale), then black: on at once at
-- the cut, held for the beat, faded out over Fade.
function JumpscareController.overlay(elapsed: number, flashScale: number, cutAt: number, beat: number): Overlay
	local t = finiteOr(elapsed, 0)
	local scale = MathUtil.clamp01(finiteOr(flashScale, 1))
	local cut = math.max(finiteOr(cutAt, LUNGE + HOLD), 0)
	local hold = math.max(finiteOr(beat, BEAT), 0)
	if t < 0 then
		return { flash = 0, tint = 0, vignette = 0, black = 0 }
	end
	if t >= cut then
		return {
			flash = 0,
			tint = 0,
			vignette = 0,
			black = 1 - MathUtil.smoothstep(cut + hold, cut + hold + FADE, t),
		}
	end
	local trough = 0.5 - 0.5 * math.cos(TAU * VIGNETTE_HZ * t)
	return {
		flash = FLASH_PEAK * scale * spike(t, 0),
		tint = SLAM_TINT * scale * spike(t, SLAM_AT),
		vignette = VIGNETTE_PEAK * MathUtil.smoothstep(0, VIGNETTE_RISE, t) * (1 - VIGNETTE_PULSE * scale * trough),
		black = 0,
	}
end

-- The face light's brightness `elapsed` seconds after startAt, for a cut `cutAt` seconds in: a flare at the snap and
-- another at the slam over the held level, dimmed by a stutter scaled by FlashScale; dark outside the moment.
function JumpscareController.faceLight(elapsed: number, flashScale: number, cutAt: number): number
	local t = finiteOr(elapsed, 0)
	local cut = math.max(finiteOr(cutAt, LUNGE + HOLD), 0)
	if t < 0 or t >= cut then
		return 0
	end
	local scale = MathUtil.clamp01(finiteOr(flashScale, 1))
	local level = LIGHT_HOLD
		+ (LIGHT_FLARE - LIGHT_HOLD) * math.exp(-LIGHT_FLARE_DECAY * t)
		+ LIGHT_SLAM * spike(t, SLAM_AT)
	local stutter = 0.5 + 0.5 * math.clamp(MathUtil.noise1(t * LIGHT_STUTTER_HZ, 5), -1, 1)
	return level * (1 - LIGHT_STUTTER * scale * stutter)
end

-- Seconds from startAt to the cut, from the cue's endsAt (the lunge plus the hold when it is missing or absurd).
function JumpscareController.holdLength(startAt: number, endsAt: number?): number
	if endsAt == nil or not MathUtil.isFinite(endsAt) or not MathUtil.isFinite(startAt) then
		return LUNGE + HOLD
	end
	local length = endsAt - startAt
	if length <= 0 or length > MAX_HOLD then
		return LUNGE + HOLD
	end
	return length
end

-- A witness's jolt (degrees) `distance` studs from the victim; 0 beyond WitnessRadius.
function JumpscareController.witnessShake(distance: number): number
	if not MathUtil.isFinite(distance) or distance >= WITNESS_RADIUS then
		return 0
	end
	local falloff = 1 - math.max(0, distance) / WITNESS_RADIUS
	return WITNESS_SHAKE * falloff * falloff
end

-- A witness's sting volume `distance` studs from the victim: full within StingFull, 0 beyond StingRadius.
function JumpscareController.witnessSting(distance: number): number
	if not MathUtil.isFinite(distance) or distance >= STING_RADIUS then
		return 0
	end
	local falloff = 1 - MathUtil.clamp01((math.max(0, distance) - STING_FULL) / (STING_RADIUS - STING_FULL))
	return STING_VOLUME * falloff * falloff
end

-- A witness's panic floor `distance` studs from the victim; 0 beyond WitnessRadius.
function JumpscareController.witnessPanic(distance: number): number
	if not MathUtil.isFinite(distance) or distance >= WITNESS_RADIUS then
		return 0
	end
	return WITNESS_PANIC * (1 - math.max(0, distance) / WITNESS_RADIUS)
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function myUserId(): number?
	local player = localPlayer
	return if player then player.UserId else nil
end

-- Seconds until server time `startAt` (0 when it has passed), capped against skew.
local function leadTo(startAt: unknown): number
	if type(startAt) ~= "number" or not MathUtil.isFinite(startAt) then
		return 0
	end
	return math.clamp(startAt - serverNow(), 0, MAX_LEAD)
end

local function settingScale(key: string): number
	return MathUtil.clamp01(finiteOr(SettingsController.GetNumber(key), 1))
end

-- The camera's position: where this client sees from (a spectator's camera rides a teammate).
local function listenerPosition(): Vector3
	local camera = Workspace.CurrentCamera
	if camera then
		return camera.CFrame.Position
	end
	return FirstPersonController.GetEyeCFrame().Position
end

local function findFace(): Attachment?
	local creature = Instances.creature()
	local face = if creature then creature:FindFirstChild(FACE_ATTACHMENT, true) else nil
	return if face and face:IsA("Attachment") then face else nil
end

-- The face the camera locks onto this frame: the rig's (animated) face attachment, else the fallback.
local function faceFrame(current: Session): CFrame
	local face = current.face
	if face == nil or face.Parent == nil then
		local now = os.clock()
		if now - current.faceResolvedAt >= FACE_RESOLVE_INTERVAL then
			current.faceResolvedAt = now
			current.face = findFace()
			face = current.face
		end
	end
	if face and face.Parent ~= nil then
		local world = face.WorldCFrame
		if MathUtil.isFiniteVector(world.Position) then
			return world
		end
	end
	return current.fallbackFace
end

--------------------------------------------------------------------------------
-- Overlay
--------------------------------------------------------------------------------

local function layer(parent: Instance, name: string, color: Color3, zIndex: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.ZIndex = zIndex
	frame.Parent = parent
	return frame
end

-- One vignette edge: blood-dark at the screen edge, clear inward (UIGradient transparency, no images).
local function edge(
	parent: Instance,
	name: string,
	rotation: number,
	size: UDim2,
	position: UDim2,
	anchor: Vector2
): Frame
	local frame = layer(parent, name, BLOOD_EDGE, 1)
	frame.Size = size
	frame.Position = position
	frame.AnchorPoint = anchor
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.45, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = frame
	return frame
end

local function buildPaint(): Paint?
	local player = localPlayer
	local playerGui = if player then player:FindFirstChildOfClass("PlayerGui") else nil
	if not playerGui then
		return nil
	end
	local screen = Instance.new("ScreenGui")
	screen.Name = "JumpscareOverlay"
	screen.ResetOnSpawn = false
	screen.ScreenInsets = Enum.ScreenInsets.None
	screen.DisplayOrder = DISPLAY_ORDER
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	local edges = {
		edge(screen, "Top", 90, UDim2.fromScale(1, 0.34), UDim2.fromScale(0, 0), Vector2.zero),
		edge(screen, "Bottom", -90, UDim2.fromScale(1, 0.34), UDim2.fromScale(0, 1), Vector2.new(0, 1)),
		edge(screen, "Left", 0, UDim2.fromScale(0.3, 1), UDim2.fromScale(0, 0), Vector2.zero),
		edge(screen, "Right", 180, UDim2.fromScale(0.3, 1), UDim2.fromScale(1, 0), Vector2.new(1, 0)),
	}
	local paint: Paint = {
		gui = screen,
		edges = edges,
		tint = layer(screen, "Tint", BLOOD, 2),
		flash = layer(screen, "Flash", WHITE, 3),
		black = layer(screen, "Black", BLACK, 4),
		written = {},
	}
	screen.Parent = playerGui
	return paint
end

local function setOpacity(paint: Paint, frame: Frame, opacity: number)
	local value = MathUtil.clamp01(opacity)
	local last = paint.written[frame]
	if last ~= nil and math.abs(last - value) < PAINT_EPSILON and (value > 0 or last == 0) then
		return
	end
	paint.written[frame] = value
	frame.BackgroundTransparency = 1 - value
end

local function applyOverlay(current: Session, elapsed: number)
	local paint = current.paint
	if not paint then
		return
	end
	local o = JumpscareController.overlay(elapsed, current.flashScale, current.cutAt, current.beat)
	for _, frame in paint.edges do
		setOpacity(paint, frame, o.vignette)
	end
	setOpacity(paint, paint.tint, o.tint)
	setOpacity(paint, paint.flash, o.flash)
	setOpacity(paint, paint.black, o.black)
end

-- A local light under the camera (client-only, never replicated), carried with the locked view.
local function buildLight(): PointLight?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local carrier = Instance.new("Part")
	carrier.Name = "JumpscareFaceLight"
	carrier.Anchored = true
	carrier.CanCollide = false
	carrier.CanQuery = false
	carrier.CanTouch = false
	carrier.CastShadow = false
	carrier.Transparency = 1
	carrier.Size = Vector3.new(0.2, 0.2, 0.2)
	local light = Instance.new("PointLight")
	light.Color = LIGHT_COLOR
	light.Range = LIGHT_RANGE
	light.Shadows = false
	light.Brightness = 0
	light.Parent = carrier
	carrier.Parent = camera
	return light
end

local function dropLight(current: Session)
	local light = current.light
	current.light = nil
	local carrier = if light then light.Parent else nil
	if carrier then
		carrier:Destroy()
	elseif light then
		light:Destroy()
	end
end

--------------------------------------------------------------------------------
-- Session
--------------------------------------------------------------------------------

local function cameraFor(current: Session): CFrame
	local elapsed = math.clamp(serverNow() - current.startAt, 0, current.cutAt)
	return JumpscareController.cameraCFrame(
		faceFrame(current),
		elapsed,
		current.startDistance,
		current.motionScale,
		current.seed
	)
end

local function begin(current: Session)
	current.begun = true
	current.motionScale = settingScale("MotionScale")
	current.flashScale = settingScale("FlashScale")
	InputController.PushContext(CONTEXT, TOKEN)
	current.hudWasVisible = HUD.IsVisible()
	if current.hudWasVisible then
		HUD.SetVisible(false)
	end
	FirstPersonController.SetPanicFloor(TOKEN, 1)

	local eye = FirstPersonController.GetEyeCFrame()
	current.face = findFace()
	current.faceResolvedAt = os.clock()
	local liveFace = current.face
	local facePoint = if liveFace then liveFace.WorldCFrame.Position else current.facePoint
	if facePoint and MathUtil.isFiniteVector(facePoint) and (facePoint - eye.Position).Magnitude > 1e-3 then
		current.fallbackFace = CFrame.lookAt(facePoint, eye.Position)
		current.startDistance = JumpscareController.startDistanceFor(eye.Position, facePoint)
	else
		-- No face to find at all: one in front of the eye, looking back at it.
		current.startDistance = MIN_START_DISTANCE
		current.fallbackFace = CFrame.lookAt(eye * Vector3.new(0, 0, -MIN_START_DISTANCE), eye.Position)
	end

	FirstPersonController.PushOverride(OVERRIDE, {
		cframe = function(): CFrame
			return cameraFor(current)
		end,
		fov = FOV,
		blendIn = BLEND_IN,
		blendOut = 0,
	})
	current.paint = buildPaint()
	current.light = buildLight()
	log.debug("caught (%s): lunge from %.2f studs", current.kind, current.startDistance)
end

-- Under the black: the override goes (instantly) and the look turns the way the server turned the body.
local function cut(current: Session)
	current.cut = true
	local toward = faceFrame(current).Position - FirstPersonController.GetEyeCFrame().Position
	FirstPersonController.PopOverride(OVERRIDE)
	dropLight(current)
	if MathUtil.isFiniteVector(toward) and Vector3.new(toward.X, 0, toward.Z).Magnitude > 1e-3 then
		local yaw = MathUtil.yawPitchFromVector(toward)
		FirstPersonController.SetLook(yaw, 0)
	end
end

local function restore(current: Session)
	current.restored = true
	InputController.PopContext(TOKEN)
	FirstPersonController.SetPanicFloor(TOKEN, nil)
	if current.hudWasVisible and not HUD.IsVisible() then
		HUD.SetVisible(true)
	end
end

local function endSession(current: Session)
	if session == current then
		session = nil
	end
	current.trove:Destroy()
	if current.begun and not current.cut then
		current.cut = true
		FirstPersonController.PopOverride(OVERRIDE)
	end
	if current.begun and not current.restored then
		restore(current)
	end
	dropLight(current)
	local paint = current.paint
	current.paint = nil
	if paint then
		paint.gui:Destroy()
	end
end

-- Calls the moment off: before it showed, it simply ends; once shown, it cuts to black now with a short beat.
local function abortSession(current: Session)
	if not current.begun then
		endSession(current)
		return
	end
	local elapsed = serverNow() - current.startAt
	if elapsed < current.cutAt then
		current.cutAt = math.max(0, elapsed)
		current.beat = ABORT_BEAT
	end
end

local function step(current: Session)
	if session ~= current then
		return
	end
	local elapsed = serverNow() - current.startAt
	if not current.begun then
		if elapsed < 0 then
			return
		end
		if elapsed >= current.cutAt then
			endSession(current) -- it is already over: nothing left to show
			return
		end
		begin(current)
	end
	if not current.cut and elapsed >= current.cutAt then
		cut(current)
	end
	if not current.restored and elapsed >= current.cutAt + current.beat then
		restore(current)
	end
	applyOverlay(current, elapsed)
	local light = current.light
	local carrier = if light then light.Parent else nil
	if light and carrier and carrier:IsA("BasePart") then
		carrier.CFrame = cameraFor(current) * CFrame.new(0, LIGHT_RISE, 0)
		light.Brightness = JumpscareController.faceLight(elapsed, current.flashScale, current.cutAt)
	end
	if elapsed >= current.cutAt + current.beat + FADE then
		endSession(current)
	end
end

local function watchLock(current: Session, player: Player)
	local function check()
		local lock = player:GetAttribute(P.ControlLock)
		if lock == LOCK then
			current.sawLock = true
		elseif current.sawLock and serverNow() - current.startAt < current.cutAt - LOCK_SLACK then
			abortSession(current) -- the server let go well before the hold was over
		end
	end
	current.trove:Connect(player:GetAttributeChangedSignal(P.ControlLock), check)
	check()
end

local function startSession(args: { [string]: any }, startAt: unknown, endsAt: unknown)
	local player = localPlayer
	if not player then
		return
	end
	local now = serverNow()
	local start = if type(startAt) == "number" and MathUtil.isFinite(startAt)
		then math.min(startAt, now + MAX_LEAD)
		else now
	local cutAt = JumpscareController.holdLength(start, if type(endsAt) == "number" then endsAt else nil)
	if now - start >= cutAt then
		return -- arrived after the hold: the moment is gone
	end
	local existing = session
	if existing then
		endSession(existing)
	end
	local face = args.face
	local kind = args.kind
	local current: Session = {
		kind = if type(kind) == "string" then kind else "Hallway",
		startAt = start,
		cutAt = cutAt,
		beat = BEAT,
		facePoint = if typeof(face) == "Vector3" and MathUtil.isFiniteVector(face) then face else nil,
		face = nil,
		faceResolvedAt = -math.huge,
		fallbackFace = CFrame.identity,
		startDistance = MIN_START_DISTANCE,
		motionScale = 1,
		flashScale = 1,
		seed = (player.UserId + math.floor(start * 10)) % 997,
		trove = Trove.new(),
		paint = nil,
		light = nil,
		sawLock = false,
		hudWasVisible = true,
		begun = false,
		cut = false,
		restored = false,
	}
	session = current
	current.trove:Connect(RunService.PreRender, function()
		step(current)
	end)
	current.trove:Connect(player.CharacterAdded, function()
		abortSession(current)
	end)
	watchLock(current, player)
	step(current)
end

--------------------------------------------------------------------------------
-- Witnesses
--------------------------------------------------------------------------------

local function raiseWitnessPanic(level: number)
	witnessGeneration += 1
	local generation = witnessGeneration
	FirstPersonController.SetPanicFloor(WITNESS_TOKEN, level)
	runTrove:Delay(WITNESS_PANIC_SECONDS, function()
		if witnessGeneration == generation then
			FirstPersonController.SetPanicFloor(WITNESS_TOKEN, nil)
		end
	end)
end

-- Where the catch happens: the event's position, else its subject's (the victim's character).
local function eventPosition(args: { [string]: any }, subject: unknown): Vector3?
	local position = args.position
	if typeof(position) == "Vector3" and MathUtil.isFiniteVector(position) then
		return position
	end
	if typeof(subject) == "Instance" and (subject :: Instance):IsA("Model") then
		return (subject :: Model):GetPivot().Position
	end
	return nil
end

local function witness(args: { [string]: any }, subject: unknown, startAt: unknown)
	if session ~= nil then
		return -- this client is in its own catch
	end
	local position = eventPosition(args, subject)
	if position == nil then
		return
	end
	local distance = (listenerPosition() - position).Magnitude
	local shake = JumpscareController.witnessShake(distance)
	local volume = JumpscareController.witnessSting(distance)
	local panic = JumpscareController.witnessPanic(distance)
	if shake <= 0 and volume <= 0 and panic <= 0 then
		return
	end
	runTrove:Delay(leadTo(startAt), function()
		if shake > 0 then
			FirstPersonController.Shake(shake, WITNESS_SHAKE_SECONDS)
		end
		if volume > 0 then
			AudioController.PlayLocal(STING_PRESET, { volume = volume })
		end
		if panic > 0 then
			raiseWitnessPanic(panic)
		end
	end)
end

--------------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------------

local function onPrivateCue(payload: any)
	if type(payload) ~= "table" or payload.kind ~= VICTIM_CUE then
		return
	end
	local args: { [string]: any } = if type(payload.args) == "table" then payload.args else {}
	if args.aborted == true then
		local current = session
		if current then
			abortSession(current)
		end
		return
	end
	startSession(args, payload.startAt, payload.endsAt)
end

local function onOneShot(payload: any)
	if type(payload) ~= "table" or payload.kind ~= ONESHOT_KIND then
		return
	end
	local args: { [string]: any } = if type(payload.args) == "table" then payload.args else {}
	local me = myUserId()
	if me == nil or args.userId == me then
		return -- the victim's own moment comes with the JumpscareVictim cue
	end
	local startAt = payload.startAt
	if type(startAt) == "number" and serverNow() - startAt > GameConfig.OneShotMaxLate then
		return
	end
	witness(args, payload.subject, startAt)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function JumpscareController.Init()
	serviceTrove:Add(function()
		local current = session
		if current then
			endSession(current)
		end
	end)
	serviceTrove:Add(runTrove)
end

function JumpscareController.Start()
	if not localPlayer then
		log.warn("no local player; jumpscares are not presented")
		return
	end
	local cueConnection = Net.Client.on("PrivateCue", onPrivateCue)
	if cueConnection then
		serviceTrove:Add(cueConnection)
	end
	local oneShotConnection = Net.Client.on("OneShot", onOneShot)
	if oneShotConnection then
		serviceTrove:Add(oneShotConnection)
	end
end

function JumpscareController.OnRunStarted(_info: Types.RunInfo)
	witnessGeneration += 1
	FirstPersonController.SetPanicFloor(WITNESS_TOKEN, nil)
end

function JumpscareController.OnRunEnded()
	local current = session
	if current then
		endSession(current)
	end
	runTrove:Clean()
	witnessGeneration += 1
	FirstPersonController.SetPanicFloor(WITNESS_TOKEN, nil)
end

return table.freeze(JumpscareController)
