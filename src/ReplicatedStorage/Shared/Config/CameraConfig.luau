--!strict
-- First-person camera tuning and the eye points the server uses for line of sight.
-- Offsets are relative to the normal standing eye (Humanoid.CameraOffset semantics, rotated by camera yaw).

local CameraConfig = {}

CameraConfig.StateOffsets = table.freeze({
	Standing = Vector3.new(0, 0, 0),
	Crouching = Vector3.new(0, -1.5, 0),
	VentCrawling = Vector3.new(0, -2.1, -0.5),
	DownedCrawling = Vector3.new(0, -2.3, 0),
	LockerPeeking = Vector3.new(0, -0.15, 0),
	ParachuteLookback = Vector3.new(0, 0, 0),
	Cinematic = Vector3.new(0, 0, 0), -- the shot places the camera
	Cockpit = Vector3.new(0, -0.3, 0), -- the seat's eye (EyeHeightAboveRoot.Seated)
	LookBack = Vector3.new(0, 0, 0), -- the view turns (ParkourConfig.LookBack); the eye stays
} :: { [string]: Vector3 })

-- Eye height above the HumanoidRootPart centre, per server MoveState. Used for Creature LOS and
-- the jumpscare face-lock, since the server never sees client-side poses.
CameraConfig.EyeHeightAboveRoot = table.freeze({
	Standing = 1.5,
	Sprinting = 1.4,
	Crouching = 0,
	VentCrawling = -0.6,
	VentScurrying = -0.6,
	DownedCrawling = -0.8,
	Hiding = 1.3,
	Trapped = 1.1,
	Parachuting = 1.5,
	Scripted = 1.5,
	Sliding = 0, -- as Crouching (docs/design/game-spec-v2.md 3.1: eye -1.5)
	Leaping = 1.4, -- the root rides ParkourRules.leap; the eye rides it at the sprint height
	Seated = 1.2, -- a plane seat
} :: { [string]: number })

CameraConfig.FieldOfView = table.freeze({
	Base = 70, -- the settings menu overrides this baseline
	SprintBonus = 6,
	PanicMaxBonus = 12,
	JumpscareFov = 55,
	LerpSpeed = 6,
})

CameraConfig.Pitch = table.freeze({
	Min = -80,
	Max = 80,
	VentMin = -35,
	VentMax = 35,
	TrappedLookDown = -55, -- forced tilt toward the trapped leg
	ParachuteLookUp = 55,
})

CameraConfig.Bob = table.freeze({
	WalkFrequency = 1.9, -- cycles per second at walk speed
	WalkPitch = 0.6, -- degrees
	WalkRoll = 0.45,
	WalkVertical = 0.07, -- studs
	SprintMultiplier = 1.7,
	CrouchMultiplier = 0.55,
	VentMultiplier = 0.8,
	IdleBreathFrequency = 0.22,
	IdleBreathPitch = 0.35,
	PanicBreathMultiplier = 2.4,
})

CameraConfig.Shake = table.freeze({
	ChaseAmplitude = 0.35, -- degrees, scaled by panic
	JumpscareAmplitude = 4,
	ImpactAmplitude = 1.6,
	Frequency = 14,
	Decay = 3.5,
})

CameraConfig.Panic = table.freeze({
	CreatureNearDistance = 18, -- full panic at or inside this distance with line of sight
	CreatureFarDistance = 80, -- no proximity panic beyond this
	ChaseFloor = 0.55, -- minimum panic while being chased
	RiseSpeed = 1.5,
	FallSpeed = 0.25,
	Saturation = -0.55, -- ColorCorrection at full panic
	Contrast = 0.25,
	TintRed = Color3.fromRGB(255, 205, 205),
	DofFarIntensity = 0.45,
	VignetteTransparencyAtFull = 0.15,
})

CameraConfig.Mouse = table.freeze({
	RadiansPerPixel = 0.0035, -- multiplied by the sensitivity setting
	GamepadRadiansPerSecond = 3.6,
	TouchRadiansPerPixel = 0.006,
})

return table.freeze(CameraConfig)
