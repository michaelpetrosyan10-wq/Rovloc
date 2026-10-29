--!strict
-- FirstPersonController: the first-person player. The only writer of Workspace.CurrentCamera (type, CFrame, FOV,
-- focus) and of Player.CameraMode.
--
-- The camera is Scriptable whenever this controller is enabled (reasserted every frame, so no engine camera script
-- ever moves it), and Player.CameraMode is LockFirstPerson while a character exists: in the lobby and in runs alike.
-- One BindToRenderStep at Enum.RenderPriority.Camera.Value + 1 runs every frame, in this order:
--   1. MovementController predicts the MoveState from the held inputs, stamina and the replicated state, and sets
--      the local WalkSpeed (so the eye height and FOV below use this frame's posture).
--   2. Camera state = a state a later phase forced (ForceCameraState) or CameraStates.fromMoveState; its pitch range
--      (unless SetPitchLimits overrides a bound).
--   3. CameraRig turns this frame's mouse / stick / touch input into yaw and pitch (raw, no smoothing).
--   4. Eye. Render steps run after the previous physics step, so the root read here is final for this frame. The
--      root's height is spring-smoothed (steps, stairs and landings never jolt; the lag is capped and a server move
--      of more than SNAP_DISTANCE snaps and adopts the new facing); X / Z are used as they are, so nothing swims.
--      eye = smoothed root + the rig's measured neck-pivot eye for this look (CameraRig) + the camera-state offset
--      (CameraStates, spring-smoothed, rotated by yaw). A dead body's eye rides its Head instead. A sphere cast in
--      the Default group from the root centre to the eye pulls the eye in front of any wall it would sit inside
--      (instantly), and lets it back out smoothly.
--   5. Panic (PanicVFX) senses the Creature and integrates; ViewBob adds gait bob, breathing sway and shakes on top
--      of the look (never into it).
--   6. FOV = the BaseFov setting + the sprint bonus + the panic bonus and heartbeat warp (both scaled by the
--      MotionScale setting), eased at CameraConfig.FieldOfView.LerpSpeed.
--   7. CameraStack blends any pushed overrides (Cutscene > Jumpscare > Spectating > Struggle > Trapped) over that
--      base view; the result goes to the camera.
--   8. The root's yaw follows the look: Humanoid.AutoRotate is off and a client-made AlignOrientation (OneAttachment)
--      on the own root targets the camera yaw; it lets go while a ControlLock is held (the server anchors the
--      root), while dead, and while a later phase suspends it (vent rails drive their own orientation).
--   9. HandRig poses the hands and torch, Flashlight aims the beam from the lens, BodyRenderer hides the head (after
--      the camera has moved), PanicVFX applies its grade, blur, vignette and loops.
--  10. CharacterAnimationController.SetLocalLook(yaw, pitch); LookRelay at GameConfig.LookRelayHz with int16 angles,
--      only when an angle moved more than CameraRig.LookEpsilon (plus one settled sample after the look stops, and a
--      resend every RESEND_SECONDS for the unreliable channel).
-- Respawns rebind everything and face the spawn's direction; a dead character's camera stays at its head; with no
-- character the camera holds its last eye and can still look around. SetEnabled(false) hands the camera back to the
-- engine (Custom, Classic, AutoRotate on, cursor unlocked, body fully visible) while movement prediction carries on.
-- Input: Sprint (hold), Crouch (toggle), Dive (hold) and Flashlight (tap) come from InputController; look input is
-- ignored while the Menu or Cutscene context is live, the cursor is free, or a Jumpscare / Cutscene lock is held.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Spring = require(ReplicatedStorage.Shared.Util.Spring)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local Core = script.Parent.Parent.Core
local CursorController = require(Core.CursorController)
local InputController = require(Core.InputController)
local RenderBudgetController = require(Core.RenderBudgetController)
local SettingsController = require(Core.SettingsController)
local CharacterAnimationController = require(script.Parent.Parent.Characters.CharacterAnimationController)

local BodyRenderer = require(script.BodyRenderer)
local CameraRig = require(script.CameraRig)
local CameraStack = require(script.CameraStack)
local CameraStates = require(script.CameraStates)
local Flashlight = require(script.Flashlight)
local HandRig = require(script.HandRig)
local MovementController = require(script.MovementController)
local PanicVFX = require(script.PanicVFX)
local ViewBob = require(script.ViewBob)

local log = Log.new("FirstPerson")

local P = Attributes.Player

export type OverrideSource = CameraStack.Source
export type MoveMode = MovementController.Mode
export type HandPose = HandRig.Pose

local RENDER_STEP = "RovlocFirstPersonCamera"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1
local MAX_DT = 0.1

local HEIGHT_SPEED = 26 -- rad/s, root height smoothing on the ground (critically damped)
local HEIGHT_SPEED_AIR = 60 -- tighter in the air: jumps and falls must not float
local MAX_HEIGHT_LAG = 0.9 -- studs the smoothed height may trail the root
local OFFSET_SPEED = 11 -- camera-state offset (crouch, crawl) transitions
local DEATH_SPEED = 14 -- eye following a falling dead head
local SNAP_DISTANCE = 8 -- a root jump this large in one frame is a server move
local MIN_EYE_ABOVE_FLOOR = 0.6
local CAMERA_RADIUS = 0.2
local CAMERA_SKIN = 0.05
local COLLISION_RELEASE = 6 -- studs/s the eye returns after a wall stops pushing it in
local COLLISION_REFRESH = 0.5 -- seconds between exclusion-list rebuilds
local LOOK_SETTLE = 0.2 -- seconds of stillness before the last small look change is sent
local RESEND_SECONDS = 1
local EXERTION_BELOW = 0.45 -- stamina share under which breathing gets heavy

local FirstPersonController = {}

FirstPersonController.Name = "FirstPersonController"

local localPlayer: Player? = Players.LocalPlayer
local serviceTrove = Trove.new()
local characterTrove = Trove.new()

local enabled = true
local started = false
local bindSerial = 0

-- Character
local character: Model? = nil
local humanoid: Humanoid? = nil
local root: BasePart? = nil
local head: BasePart? = nil
local eyeMetrics: CameraRig.EyeMetrics = CameraRig.DefaultEye
local align: AlignOrientation? = nil
local bodySubject: Model? = nil -- a later phase's subject for BodyRenderer (nil = own character)

-- Look and eye
local yaw = 0
local pitch = 0
local pitchMinOverride: number? = nil
local pitchMaxOverride: number? = nil
local forcedStates: { [string]: { state: Enums.CameraState, order: number } } = {}
local forceOrder = 0
local cameraState: Enums.CameraState = "Standing"
local eyeCFrame = CFrame.identity
local eyeReady = false -- false until the first character's eye exists (the engine camera shows until then)
local lastRootPosition: Vector3? = nil
local snapNext = true
local deathActive = false
local collisionDistance = math.huge
local collisionParams: RaycastParams? = nil
local collisionRefreshAt = -math.huge
local fov = CameraConfig.FieldOfView.Base
local yawSuspended: { [string]: boolean } = {}

local heightSpring = Spring.number(0, HEIGHT_SPEED, 1)
local offsetSpring = Spring.vector(Vector3.zero, OFFSET_SPEED, 1)
local deathSpring = Spring.vector(Vector3.zero, DEATH_SPEED, 1)

-- Parts
local rig = CameraRig.new()
local stack = CameraStack.new()
local bob = ViewBob.new()
local movement: MovementController.Movement? = nil
local panic: PanicVFX.PanicFx? = nil
local flashlight: Flashlight.Light? = nil
local pendingFloors: { [string]: number } = {}

-- Settings and budget
local lookSettings: CameraRig.LookSettings = { mouse = 1, gamepad = 1, touch = 1, invertY = false }
local baseFov = CameraConfig.FieldOfView.Base
local motionScale = 1
local flashScale = 1
local budgetDof = true

-- LookRelay
local relayClock = 0
local sentYaw: number? = nil
local sentPitch: number? = nil
local lastRelayAt = -math.huge

local predictedChanged: Signal.Signal<Enums.MoveState, Enums.MoveState> = Signal.new()
FirstPersonController.PredictedMoveStateChanged = predictedChanged

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

local function readSettings()
	lookSettings = {
		mouse = SettingsController.GetNumber("MouseSensitivity"),
		gamepad = SettingsController.GetNumber("GamepadSensitivity"),
		touch = SettingsController.GetNumber("TouchSensitivity"),
		invertY = SettingsController.GetBool("InvertY"),
	}
	baseFov = SettingsController.GetNumber("BaseFov")
	motionScale = MathUtil.clamp01(SettingsController.GetNumber("MotionScale"))
	flashScale = MathUtil.clamp01(SettingsController.GetNumber("FlashScale"))
end

local function applyBudget(budget: RenderBudgetController.Budget)
	budgetDof = budget.dof
	local light = flashlight
	if light then
		light:SetShadows(budget.shadows)
	end
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function forcedCameraState(): Enums.CameraState?
	local best: Enums.CameraState? = nil
	local bestOrder = -1
	for _, entry in forcedStates do
		if entry.order > bestOrder then
			best = entry.state
			bestOrder = entry.order
		end
	end
	return best
end

local function lookInputAllowed(player: Player): boolean
	local context = InputController.GetContext()
	if context == "Menu" or context == "Cutscene" or CursorController.IsFree() then
		return false
	end
	local lock = Attributes.getString(player, P.ControlLock, "None")
	return lock ~= "Jumpscare" and lock ~= "Cutscene"
end

local function refreshCollisionParams(now: number): RaycastParams
	local params = collisionParams
	if params and now < collisionRefreshAt then
		return params
	end
	collisionRefreshAt = now + COLLISION_REFRESH
	local exclude: { Instance } = {}
	for _, other in Players:GetPlayers() do
		local model = other.Character
		if model then
			table.insert(exclude, model)
		end
	end
	local creature = Instances.creature()
	if creature then
		table.insert(exclude, creature)
	end
	local camera = Workspace.CurrentCamera
	if camera then
		table.insert(exclude, camera)
	end
	local fresh = RaycastParams.new()
	fresh.FilterType = Enum.RaycastFilterType.Exclude
	fresh.FilterDescendantsInstances = exclude
	fresh.CollisionGroup = "Default"
	fresh.RespectCanCollide = true
	fresh.IgnoreWater = true
	collisionParams = fresh
	return fresh
end

-- Pulls `desired` in front of whatever solid lies between the root centre and it.
local function resolveCollision(origin: Vector3, desired: Vector3, dt: number, snap: boolean, now: number): Vector3
	local toEye = desired - origin
	local length = toEye.Magnitude
	if length < 1e-3 then
		return desired
	end
	local hit = Workspace:Spherecast(origin, CAMERA_RADIUS, toEye, refreshCollisionParams(now))
	local allowed = if hit then math.max(0, hit.Distance - CAMERA_SKIN) else length
	if snap or allowed < collisionDistance then
		collisionDistance = allowed
	else
		collisionDistance = math.min(allowed, collisionDistance + COLLISION_RELEASE * dt)
	end
	if not hit and collisionDistance >= length then
		collisionDistance = math.huge
		return desired
	end
	return origin + toEye.Unit * math.min(collisionDistance, length)
end

local function isDead(player: Player, hum: Humanoid): boolean
	return hum.Health <= 0
		or hum:GetState() == Enum.HumanoidStateType.Dead
		or Attributes.getString(player, P.LifeState, "") == "Dead"
end

-- The eye for this frame (steps 4 of the frame order).
local function computeEye(
	dt: number,
	now: number,
	state: Enums.MoveState,
	forced: Enums.CameraState?,
	rootPart: BasePart,
	hum: Humanoid,
	dead: boolean
): Vector3
	local rootPosition = rootPart.Position
	local snap = snapNext
	local previous = lastRootPosition
	if previous and (rootPosition - previous).Magnitude > SNAP_DISTANCE then
		snap = true
		-- A server move (spawn slot, airlock, vent exit, correction): look where it put us.
		yaw = MathUtil.yawPitchFromVector(rootPart.CFrame.LookVector)
	end
	lastRootPosition = rootPosition
	snapNext = false

	local grounded = hum.FloorMaterial ~= Enum.Material.Air
	if snap then
		heightSpring:reset(rootPosition.Y)
	else
		heightSpring.target = rootPosition.Y
		heightSpring.speed = if grounded then HEIGHT_SPEED else HEIGHT_SPEED_AIR
		heightSpring:step(dt)
		local lag = heightSpring.position - rootPosition.Y
		if math.abs(lag) > MAX_HEIGHT_LAG then
			heightSpring.position = rootPosition.Y + math.sign(lag) * MAX_HEIGHT_LAG
		end
	end
	local smoothedRoot = Vector3.new(rootPosition.X, heightSpring.position, rootPosition.Z)

	local offsetTarget = CameraStates.offset(state, forced)
	if snap then
		offsetSpring:reset(offsetTarget)
	else
		offsetSpring.target = offsetTarget
		offsetSpring:step(dt)
	end

	local heading = CFrame.fromOrientation(0, yaw, 0)
	local desired = smoothedRoot
		+ CameraRig.eyeOffset(eyeMetrics, yaw, pitch)
		+ heading:VectorToWorldSpace(offsetSpring.position)

	local headPart = head
	if dead and headPart and headPart.Parent ~= nil then
		local target = headPart.CFrame:PointToWorldSpace(Vector3.new(0, headPart.Size.Y * 0.08, -eyeMetrics.eyeForward))
		if not deathActive then
			deathActive = true
			deathSpring:reset(if snap then target else eyeCFrame.Position)
		end
		deathSpring.target = target
		desired = deathSpring:step(dt)
	else
		deathActive = false
		if grounded then
			local floorY = rootPosition.Y - (hum.HipHeight + rootPart.Size.Y * 0.5)
			if desired.Y < floorY + MIN_EYE_ABOVE_FLOOR then
				desired = Vector3.new(desired.X, floorY + MIN_EYE_ABOVE_FLOOR, desired.Z)
			end
		end
	end
	return resolveCollision(smoothedRoot, desired, dt, snap, now)
end

local function updateBodyYaw(hum: Humanoid, locked: boolean, dead: boolean)
	local constraint = align
	if constraint and constraint.Parent ~= nil then
		local follow = enabled and not locked and not dead and next(yawSuspended) == nil
		if constraint.Enabled ~= follow then
			constraint.Enabled = follow
		end
		if follow then
			constraint.CFrame = CFrame.fromOrientation(0, yaw, 0)
		end
	end
	local autoRotate = not enabled
	if hum.AutoRotate ~= autoRotate then
		hum.AutoRotate = autoRotate
	end
end

local function relayLook(dt: number, now: number, lookYaw: number, lookPitch: number)
	relayClock += dt
	local interval = 1 / GameConfig.LookRelayHz
	if relayClock < interval then
		return
	end
	relayClock = math.min(relayClock - interval, interval)
	local due, qYaw, qPitch = CameraRig.shouldSendLook(sentYaw, sentPitch, lookYaw, lookPitch, CameraRig.LookEpsilon)
	if not due then
		local unsent = qYaw ~= sentYaw or qPitch ~= sentPitch
		due = (unsent and now - lastRelayAt >= LOOK_SETTLE) or now - lastRelayAt >= RESEND_SECONDS
	end
	if not due then
		return
	end
	sentYaw, sentPitch = qYaw, qPitch
	lastRelayAt = now
	xpcall(Net.Client.fire, function(err: any)
		log.warnThrottled("relay", 10, "LookRelay failed: %s", tostring(err))
	end, "LookRelay", { yaw = qYaw, pitch = qPitch })
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function renderFrame(deltaTime: number)
	local player = localPlayer
	local move = movement
	local fx = panic
	local light = flashlight
	if not player or not move or not fx or not light then
		return
	end
	local dt = math.clamp(deltaTime, 0, MAX_DT)
	local now = os.clock()
	local serverNow = Workspace:GetServerTimeNow()
	local camera = Workspace.CurrentCamera

	-- 1. Posture
	local state: Enums.MoveState = move:Step(dt, {
		now = now,
		serverNow = serverNow,
		sprintHeld = InputController.IsHeld("Sprint"),
		diveHeld = InputController.IsHeld("Dive"),
	})

	-- 2. Camera state and pitch range
	local forced: Enums.CameraState? = forcedCameraState()
	cameraState = forced or CameraStates.fromMoveState(state)
	local minDeg, maxDeg = CameraStates.pitchLimits(cameraState)
	local minPitch = math.rad(pitchMinOverride or minDeg)
	local maxPitch = math.rad(pitchMaxOverride or maxDeg)
	if minPitch > maxPitch then
		minPitch, maxPitch = maxPitch, minPitch
	end

	-- 3. Look
	local dYaw, dPitch = rig:Consume(dt, lookSettings, enabled and lookInputAllowed(player))
	yaw = MathUtil.wrapAngle(yaw + dYaw)
	pitch = CameraRig.settlePitch(CameraRig.applyPitch(pitch, dPitch, minPitch, maxPitch), minPitch, maxPitch, dt)

	-- 4. Eye
	local model = character
	local rootPart = root
	local hum = humanoid
	local lifeState = Attributes.getString(player, P.LifeState, "Lobby")
	local hasBody = false
	local dead = false
	local grounded = false
	local eye = eyeCFrame.Position
	if model and model.Parent ~= nil and rootPart and rootPart.Parent ~= nil and hum and hum.Parent ~= nil then
		hasBody = true
		dead = isDead(player, hum)
		grounded = hum.FloorMaterial ~= Enum.Material.Air
		eye = computeEye(dt, now, state, forced, rootPart, hum, dead)
		eyeReady = true
	end
	eyeCFrame = CFrame.new(eye) * CFrame.fromOrientation(pitch, yaw, 0)

	-- 5. Panic and motion
	fx:Sense(dt, if hasBody then eye else nil)
	local level = fx:Step(dt, lifeState == "Downed")
	local offset = bob:Step(dt, {
		speed = if dead then 0 else move:GetSpeed(),
		profile = CameraStates.bob(state),
		panic = level,
		motionScale = motionScale,
		chase = if fx:IsChased() then level else 0,
		grounded = grounded,
	})
	local base = eyeCFrame * offset

	-- 6. FOV
	local F = CameraConfig.FieldOfView
	local sprintBonus = if state == "Sprinting" and move:IsMoving() then F.SprintBonus * motionScale else 0
	local fovTarget = baseFov + sprintBonus + PanicVFX.fovBonus(level, motionScale) + fx:FovWarp(motionScale)
	fov = MathUtil.dampNumber(fov, fovTarget, F.LerpSpeed, dt)

	-- 7. Overrides and the camera
	stack:Step(dt)
	local finalCFrame, finalFov = stack:Evaluate(base, fov)
	local ownsView = eyeReady or stack:Coverage() > 0
	if enabled and camera and ownsView then
		if camera.CameraType ~= Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Scriptable
		end
		camera.CFrame = finalCFrame
		camera.Focus = finalCFrame
		camera.FieldOfView = finalFov
	end

	-- 8. Body yaw
	if hasBody and hum then
		updateBodyYaw(hum, move:IsLocked(), dead)
	end

	-- 9. Hands, beam, body, panic visuals
	local alive = hasBody and not dead and lifeState ~= "Spectating"
	HandRig.Update({
		dt = dt,
		look = eyeCFrame,
		moveState = state,
		lit = light:GetOutput() > 0.05,
		active = enabled and alive,
	})
	light:Update({
		dt = dt,
		now = now,
		serverNow = serverNow,
		look = eyeCFrame,
		lowered = HandRig.GetLowered(),
		allowed = enabled and alive,
		camera = camera,
		zoneId = Attributes.getString(player, P.ZoneId, ""),
		flashScale = flashScale,
	})
	BodyRenderer.Render(if enabled and camera and ownsView then finalCFrame.Position else nil)
	local stamina = move:GetStaminaFraction()
	fx:Apply(dt, {
		camera = camera,
		dof = budgetDof,
		flashScale = flashScale,
		visible = enabled and hasBody,
		exertion = MathUtil.clamp01((EXERTION_BELOW - stamina) / EXERTION_BELOW),
	})

	-- 10. Animation look and LookRelay
	local relayYaw, relayPitch = yaw, pitch
	if not enabled and camera then
		relayYaw, relayPitch = MathUtil.yawPitchFromVector(camera.CFrame.LookVector)
	end
	CharacterAnimationController.SetLocalLook(relayYaw, relayPitch)
	if hasBody then
		relayLook(dt, now, relayYaw, relayPitch)
	end
end

local function onRenderStep(deltaTime: number)
	xpcall(renderFrame, function(err: any)
		log.warnThrottled("frame", 5, "frame failed: %s\n%s", tostring(err), debug.traceback())
	end, deltaTime)
end

--------------------------------------------------------------------------------
-- Character
--------------------------------------------------------------------------------

local function unbindCharacter()
	characterTrove:Clean()
	character, humanoid, root, head, align = nil, nil, nil, nil, nil
	eyeMetrics = CameraRig.DefaultEye
	lastRootPosition = nil
	deathActive = false
	collisionDistance = math.huge
	local move = movement
	if move then
		move:SetCharacter(nil, nil)
	end
	if bodySubject == nil then
		BodyRenderer.SetSubject(nil)
	end
	local player = localPlayer
	if player and enabled then
		player.CameraMode = Enum.CameraMode.Classic
	end
end

local function bindCharacter(model: Model)
	local player = localPlayer
	if not player then
		return
	end
	bindSerial += 1
	local serial = bindSerial
	local hum = model:FindFirstChildOfClass("Humanoid") or model:WaitForChild("Humanoid", 10)
	local rootPart = model:FindFirstChild("HumanoidRootPart") or model:WaitForChild("HumanoidRootPart", 10)
	local headPart = model:FindFirstChild("Head") or model:WaitForChild("Head", 5)
	if serial ~= bindSerial or player.Character ~= model then
		return
	end
	if not (hum and hum:IsA("Humanoid") and rootPart and rootPart:IsA("BasePart")) then
		log.warn("character %s has no Humanoid / HumanoidRootPart; first person not bound", model:GetFullName())
		return
	end
	unbindCharacter()
	character = model
	humanoid = hum
	root = rootPart
	head = if headPart and headPart:IsA("BasePart") then headPart else nil
	eyeMetrics = CameraRig.measureEye(model)

	local attachment = Instance.new("Attachment")
	attachment.Name = "FirstPersonYaw"
	attachment.Parent = rootPart
	local constraint = Instance.new("AlignOrientation")
	constraint.Name = "FirstPersonYaw"
	constraint.Mode = Enum.OrientationAlignmentMode.OneAttachment
	constraint.AlignType = Enum.AlignType.AllAxes
	constraint.Attachment0 = attachment
	constraint.RigidityEnabled = false
	constraint.Responsiveness = 200
	constraint.MaxTorque = 1e7
	constraint.MaxAngularVelocity = math.huge
	constraint.CFrame = rootPart.CFrame.Rotation
	constraint.Enabled = false
	constraint.Parent = rootPart
	characterTrove:Add(constraint)
	characterTrove:Add(attachment)
	align = constraint
	hum.AutoRotate = not enabled

	local move = movement
	if move then
		move:SetCharacter(hum, rootPart)
	end
	HandRig.SetCharacter(model)
	characterTrove:Add(function()
		HandRig.SetCharacter(nil)
	end)
	if bodySubject == nil then
		BodyRenderer.SetSubject(model)
	end
	local light = flashlight
	if light then
		light:Reset()
	end

	yaw = MathUtil.yawPitchFromVector(rootPart.CFrame.LookVector)
	pitch = 0
	snapNext = true
	rig:Reset()
	bob:Reset()
	if enabled then
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	end
	CharacterAnimationController.SetLocalMoveState(if move then move:GetState() else "Standing")
end

local function onCharacterRemoving(model: Model)
	if model == character then
		unbindCharacter()
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function FirstPersonController.Init()
	local player = localPlayer
	assert(player, "FirstPersonController runs on the client")
	local move = MovementController.new(player)
	local fx = PanicVFX.new(player)
	local light = Flashlight.new(player)
	movement, panic, flashlight = move, fx, light
	for token, value in pendingFloors do
		fx:SetFloor(token, value)
	end
	table.clear(pendingFloors)
	serviceTrove:Add(function()
		fx:Destroy()
		light:Destroy()
	end)

	HandRig.Bind({
		SetHandTarget = CharacterAnimationController.SetHandTarget,
		SetHandGrip = CharacterAnimationController.SetHandGrip,
	})
	readSettings()
	fov = baseFov
	applyBudget(RenderBudgetController.GetBudget())
	serviceTrove:Add(SettingsController.Changed:Connect(function(_key: string, _value: number | boolean)
		readSettings()
	end))
	serviceTrove:Add(RenderBudgetController.BudgetChanged:Connect(applyBudget))

	serviceTrove:Add(InputController.Action("Sprint"):Connect(function(phase: InputController.Phase)
		move:SetSprint(phase == "Begin")
	end))
	serviceTrove:Add(InputController.Action("Crouch"):Connect(function(phase: InputController.Phase)
		if phase == "Begin" then
			move:ToggleCrouch()
		end
	end))
	serviceTrove:Add(InputController.Action("Dive"):Connect(function(phase: InputController.Phase)
		move:SetDive(phase == "Begin")
	end))
	serviceTrove:Add(InputController.Action("Flashlight"):Connect(function(phase: InputController.Phase)
		if phase == "Begin" then
			light:Toggle(os.clock())
		end
	end))
	serviceTrove:Add(move.Changed:Connect(function(new: Enums.MoveState, old: Enums.MoveState)
		CharacterAnimationController.SetLocalMoveState(new)
		predictedChanged:Fire(new, old)
	end))
end

function FirstPersonController.Start()
	local player = localPlayer
	if not player or started then
		return
	end
	started = true
	rig:Connect(serviceTrove)
	CursorController.SetLockWhenIdle(enabled)
	serviceTrove:Connect(player.CharacterAdded, function(model: Model)
		bindCharacter(model)
	end)
	serviceTrove:Connect(player.CharacterRemoving, onCharacterRemoving)
	RunService:BindToRenderStep(RENDER_STEP, RENDER_PRIORITY, onRenderStep)
	serviceTrove:Add(function()
		RunService:UnbindFromRenderStep(RENDER_STEP)
	end)
	local existing = player.Character
	if existing then
		task.spawn(bindCharacter, existing)
	end
end

function FirstPersonController.OnRunStarted(_info: Types.RunInfo)
	snapNext = true
end

-- Run-scoped camera state ends with the run: overrides blend out, floors, forced states, pitch limits, hand poses,
-- yaw suspensions and the movement mode hint are cleared.
function FirstPersonController.OnRunEnded()
	stack:Clear(false)
	local fx = panic
	if fx then
		fx:ClearFloors()
	end
	table.clear(forcedStates)
	table.clear(yawSuspended)
	pitchMinOverride, pitchMaxOverride = nil, nil
	HandRig.SetPose("Flashlight")
	local move = movement
	if move then
		move:SetModeHint(nil)
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function FirstPersonController.PushOverride(kind: Enums.CameraOverride, source: OverrideSource)
	if not Enums.has(Enums.CameraOverride, kind) or type(source) ~= "table" or type(source.cframe) ~= "function" then
		log.warnThrottled(
			"override" .. tostring(kind),
			30,
			"PushOverride(%s) needs a source with cframe()",
			tostring(kind)
		)
		return
	end
	stack:Push(kind, source)
end

function FirstPersonController.PopOverride(kind: Enums.CameraOverride)
	stack:Pop(kind)
end

-- The player's look (radians): yaw 0 faces -Z, pitch up positive.
function FirstPersonController.GetLook(): (number, number)
	return yaw, pitch
end

function FirstPersonController.SetLook(newYaw: number, newPitch: number)
	if newYaw ~= newYaw or newPitch ~= newPitch then
		return
	end
	yaw = MathUtil.wrapAngle(newYaw)
	pitch = math.clamp(newPitch, -math.rad(89), math.rad(89))
end

-- Overrides the camera state's pitch range (degrees); nil restores that bound's default.
function FirstPersonController.SetPitchLimits(minDeg: number?, maxDeg: number?)
	pitchMinOverride = if minDeg ~= nil and minDeg == minDeg then math.clamp(minDeg, -89, 89) else nil
	pitchMaxOverride = if maxDeg ~= nil and maxDeg == maxDeg then math.clamp(maxDeg, -89, 89) else nil
end

function FirstPersonController.Shake(amplitudeDeg: number, seconds: number)
	bob:Shake(amplitudeDeg, seconds)
end

function FirstPersonController.SetPanicFloor(token: string, value: number?)
	local fx = panic
	if fx then
		fx:SetFloor(token, value)
	elseif value == nil then
		pendingFloors[token] = nil
	else
		pendingFloors[token] = MathUtil.clamp01(value)
	end
end

-- Silences the panic breathing loop while any token holds it (a held breath: the locker check); the heart stays.
function FirstPersonController.SuppressBreathing(token: string, suppressed: boolean)
	local fx = panic
	if fx then
		fx:SetBreathSuppressed(token, suppressed)
	end
end

function FirstPersonController.GetPanic(): number
	local fx = panic
	return if fx then fx:GetPanic() else 0
end

function FirstPersonController.GetPredictedMoveState(): Enums.MoveState
	local move = movement
	return if move then move:GetState() else "Standing"
end

function FirstPersonController.SetEnabled(on: boolean)
	if on == enabled then
		return
	end
	enabled = on
	local player = localPlayer
	local camera = Workspace.CurrentCamera
	CursorController.SetLockWhenIdle(on)
	if on then
		snapNext = true
		if player and character then
			player.CameraMode = Enum.CameraMode.LockFirstPerson
		end
		if bodySubject == nil then
			BodyRenderer.SetSubject(character)
		end
		return
	end
	rig:Reset()
	if camera then
		camera.CameraType = Enum.CameraType.Custom
	end
	if player then
		player.CameraMode = Enum.CameraMode.Classic
	end
	local hum = humanoid
	if hum then
		hum.AutoRotate = true
	end
	local constraint = align
	if constraint then
		constraint.Enabled = false
	end
	BodyRenderer.Restore()
	BodyRenderer.SetSubject(nil)
end

function FirstPersonController.IsEnabled(): boolean
	return enabled
end

--------------------------------------------------------------------------------
-- Beyond the contract
--------------------------------------------------------------------------------

function FirstPersonController.GetCameraState(): Enums.CameraState
	return cameraState
end

-- Pins a camera state (LockerPeeking, ParachuteLookback, ...) under `token`; nil releases it. The latest pin wins.
function FirstPersonController.ForceCameraState(token: string, state: Enums.CameraState?)
	if state == nil then
		forcedStates[token] = nil
		return
	end
	if not Enums.has(Enums.CameraState, state) then
		log.warnThrottled("state" .. tostring(state), 30, "unknown camera state %s", tostring(state))
		return
	end
	forceOrder += 1
	forcedStates[token] = { state = state, order = forceOrder }
end

-- Hand poses for later phases: "Flashlight" (default), "Free", "Pry", "Ripcord", "SlitGrip" (relative to target),
-- "Flask" (the right hand at target).
function FirstPersonController.SetHandPose(pose: HandPose, target: CFrame?)
	HandRig.SetPose(pose, target)
end

-- Stops the root's yaw following the camera while any token holds it (a vent rail orients the body itself).
function FirstPersonController.SuspendBodyYaw(token: string, suspended: boolean)
	if suspended then
		yawSuspended[token] = true
	else
		yawSuspended[token] = nil
	end
end

-- The locomotion mode the client knows before the server's MoveState says so (vent entry, water); nil clears it.
function FirstPersonController.SetMoveModeHint(mode: MoveMode?)
	local move = movement
	if move then
		move:SetModeHint(mode)
	end
end

-- BodyRenderer's subject (a spectated teammate); nil returns to the own character.
function FirstPersonController.SetBodySubject(model: Model?)
	bodySubject = model
	BodyRenderer.SetSubject(if model then model else if enabled then character else nil)
end

-- The player's eye and look this frame (no bob, shake or overrides).
function FirstPersonController.GetEyeCFrame(): CFrame
	return eyeCFrame
end

function FirstPersonController.IsFlashlightOn(): boolean
	local light = flashlight
	return light ~= nil and light:IsOn()
end

-- EMF interference 0..1 at the local flashlight this frame.
function FirstPersonController.GetEmf(): number
	local light = flashlight
	return if light then light:GetEmf() else 0
end

-- The shared EMF rule (RemoteFlashlightRenderer): intensity at a world position for a listener in `zoneId`.
function FirstPersonController.EmfIntensityAt(position: Vector3, zoneId: string?): number
	return Flashlight.emfAt(position, zoneId)
end

-- Brightness 0..1 of a flashlight with a cell at `batteryFraction` under EMF `emf` at server time `t` (battery
-- dimming, sputter and flicker, the flicker scaled by the FlashScale setting).
function FirstPersonController.FlashlightLevel(batteryFraction: number, emf: number, t: number, seed: number): number
	local flicker = 1 - (1 - Flashlight.flickerFactor(emf, t, seed)) * flashScale
	return Flashlight.batteryFactor(batteryFraction) * Flashlight.sputter(batteryFraction, t, seed) * flicker
end

-- Beam colour for a cell at `batteryFraction`.
function FirstPersonController.BeamColor(batteryFraction: number): Color3
	return Flashlight.beamColor(batteryFraction)
end

-- The torch's dual-cone shape (angles, ranges, brightness at full output, the beam's look-space offset).
FirstPersonController.BeamCones = Flashlight.Cones

return FirstPersonController
