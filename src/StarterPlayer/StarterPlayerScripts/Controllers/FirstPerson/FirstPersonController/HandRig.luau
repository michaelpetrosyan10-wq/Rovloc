--!strict
-- HandRig: the local player's real-body hands and the torch they carry.
--
-- Torch. A procedural flashlight (knurled body, rubber grip band, tail cap, switch, flared head, chrome lens ring and
-- a lens that turns Neon while the beam is lit) built from cylinders, massless and never colliding, queried or
-- touched, client-local inside the character. One Weld mounts it: in the right fist (RightHand) for the
-- "Flashlight" pose, otherwise clipped to the left chest strap (UpperTorso), so it is never lost when the hands are
-- busy. GetLens() is the lens frame the beam starts from.
--
-- Poses (SetPose(name, target?)):
--   * Flashlight  right hand in front of the chest holding the torch along the look (the IK goal follows yaw and part
--                 of the pitch from the right shoulder, so the beam lines up with the view), lowered toward the hip
--                 while sprinting; left hand free.
--   * Free        both hands released to the animator; torch on the chest.
--   * Pry         both hands on the jaws of a bear trap at `target` (its frame: -Z away from the player, +Y up), palms
--                 down, gripping hard.
--   * Ripcord     right hand on the ripcord handle at `target`, left hand on the opposite riser strap.
--   * SlitGrip    fingertips of both hands hooked into the locker slits at `target`.
-- Placements for Pry / Ripcord / SlitGrip are fixed offsets in the target's frame; a pose that needs a target and
-- has none falls back to Free. While the body itself needs the hands (crawling a duct or downed, swimming, grabbed),
-- the Flashlight pose stows the torch on the chest and releases the hands. Goals go to
-- CharacterAnimationController.SetHandTarget / SetHandGrip (bound with Bind); blending between poses is the
-- animator's IK.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

local log = Log.new("HandRig")

export type Pose = "Flashlight" | "Free" | "Pry" | "Ripcord" | "SlitGrip"
export type Hand = "Left" | "Right"

export type AnimationApi = {
	SetHandTarget: (hand: Hand, target: CFrame?) -> (),
	SetHandGrip: (hand: Hand, grip: number) -> (),
}

export type Placement = {
	left: CFrame?,
	right: CFrame?,
	leftGrip: number,
	rightGrip: number,
	torchInHand: boolean,
}

export type UpdateContext = {
	dt: number,
	look: CFrame, -- the eye with the player's look (no bob)
	moveState: Enums.MoveState,
	lit: boolean, -- lens glows
	active: boolean, -- false releases both hands (dead, camera handed back)
}

local HandRig = {}

HandRig.Poses = table.freeze({ "Flashlight", "Free", "Pry", "Ripcord", "SlitGrip" } :: { Pose })

-- Right shoulder (R15 RightShoulder joint) from the eye, in yaw space.
local SHOULDER = Vector3.new(1, -0.84, 0.34)
-- Held torch from the shoulder, in the pitched frame: the fist sits low on the right of the view (about 0.42 right,
-- 0.55 down and 0.95 ahead of the eye when looking level), so the torch head and lens show in the corner of the view.
local HOLD_REACH = Vector3.new(-0.58, 0.29, -1.29)
local LOWERED_REACH = Vector3.new(-0.45, -0.76, -0.84) -- torch at the hip while sprinting, in yaw space
local LOWERED_TILT = math.rad(-38)
local PITCH_SHARE = 0.8 -- the arm follows this share of the look pitch
local LOWER_SPEED = 9 -- 1/s

local HAND_MOUNT = CFrame.new(0, -0.08, -0.12) -- torch grip in the RightHand frame
local CHEST_MOUNT = CFrame.new(-0.52, 0.42, -0.82) -- torch on the left chest strap, in the UpperTorso frame
local LENS_OFFSET = CFrame.new(0, 0, -0.77) -- lens face in the torch frame
local CYLINDER = CFrame.Angles(0, math.pi / 2, 0) -- part X (cylinder axis) along the torch's Z

local BODY_COLOR = Color3.fromRGB(38, 40, 43)
local GRIP_COLOR = Color3.fromRGB(20, 20, 21)
local RING_COLOR = Color3.fromRGB(150, 152, 156)
local LENS_OFF = Color3.fromRGB(196, 206, 214)
local LENS_ON = Color3.fromRGB(255, 240, 214)

local BUSY_STATES: { [string]: boolean } = {
	VentCrawling = true,
	VentScurrying = true,
	DownedCrawling = true,
	Treading = true,
	Freestyle = true,
	Underwater = true,
	Grabbed = true,
	Parachuting = true,
}

--------------------------------------------------------------------------------
-- Pure placement maths
--------------------------------------------------------------------------------

-- True when the body needs both hands for itself, so the torch is stowed.
function HandRig.handsBusy(moveState: Enums.MoveState): boolean
	return BUSY_STATES[moveState] == true
end

-- The right-hand goal for holding the torch along the look; `lowered` 0..1 blends toward the sprint carry.
function HandRig.flashlightTarget(look: CFrame, lowered: number): CFrame
	local _, yaw = look:ToOrientation()
	local pitch = math.asin(math.clamp(look.LookVector.Y, -1, 1))
	local heading = CFrame.new(look.Position) * CFrame.fromOrientation(0, yaw, 0)
	local shoulder = heading * CFrame.new(SHOULDER)
	local raised = shoulder * CFrame.fromOrientation(pitch * PITCH_SHARE, 0, 0)
	local held =
		CFrame.lookAt(raised:PointToWorldSpace(HOLD_REACH), raised:PointToWorldSpace(HOLD_REACH) + look.LookVector)
	local carryPoint = shoulder:PointToWorldSpace(LOWERED_REACH)
	local carry = CFrame.new(carryPoint) * heading.Rotation * CFrame.Angles(LOWERED_TILT, 0, 0)
	local t = MathUtil.smoothstep(0, 1, lowered)
	if t <= 0 then
		return held
	elseif t >= 1 then
		return carry
	end
	return held:Lerp(carry, t)
end

-- Hand goals for a pose. `flashlight` is the Flashlight-pose goal for this frame.
function HandRig.placements(pose: Pose, target: CFrame?, flashlight: CFrame): Placement
	if pose == "Flashlight" then
		return { left = nil, right = flashlight, leftGrip = 0.15, rightGrip = 1, torchInHand = true }
	end
	if target == nil or pose == "Free" then
		return { left = nil, right = nil, leftGrip = 0, rightGrip = 0, torchInHand = false }
	end
	if pose == "Pry" then
		return {
			left = target * CFrame.new(-0.42, 0.12, 0.05) * CFrame.Angles(math.rad(-70), 0, math.rad(10)),
			right = target * CFrame.new(0.42, 0.12, 0.05) * CFrame.Angles(math.rad(-70), 0, math.rad(-10)),
			leftGrip = 1,
			rightGrip = 1,
			torchInHand = false,
		}
	elseif pose == "Ripcord" then
		return {
			left = target * CFrame.new(-0.9, 0.55, 0.2) * CFrame.Angles(0, 0, math.rad(15)),
			right = target * CFrame.Angles(math.rad(-20), 0, 0),
			leftGrip = 0.8,
			rightGrip = 1,
			torchInHand = false,
		}
	end
	-- SlitGrip
	return {
		left = target * CFrame.new(-0.55, 0.06, 0.12) * CFrame.Angles(math.rad(-10), 0, math.rad(4)),
		right = target * CFrame.new(0.55, 0.06, 0.12) * CFrame.Angles(math.rad(-10), 0, math.rad(-4)),
		leftGrip = 0.65,
		rightGrip = 0.65,
		torchInHand = false,
	}
end

--------------------------------------------------------------------------------
-- Torch model
--------------------------------------------------------------------------------

type Torch = {
	model: Model,
	body: Part,
	lens: Part,
	mount: Weld,
}

local function cylinder(model: Model, name: string, length: number, diameter: number): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(length, diameter, diameter)
	part.Anchored = false
	part.Massless = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model
	return part
end

-- Places `part` at `offset` along the torch axis (torch frame -Z forward) and welds it to the body.
local function attach(body: Part, part: BasePart, offset: CFrame)
	part.CFrame = body.CFrame * CYLINDER:Inverse() * offset * CYLINDER
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = body
	weld.Part1 = part
	weld.Parent = part
end

local function buildTorch(character: Model): Torch
	local model = Instance.new("Model")
	model.Name = "FirstPersonTorch"

	local body = cylinder(model, "Body", 0.86, 0.24)
	body.Material = Enum.Material.DiamondPlate
	body.Color = BODY_COLOR
	body.CFrame = CYLINDER

	local grip = cylinder(model, "Grip", 0.34, 0.27)
	grip.Material = Enum.Material.Rubber
	grip.Color = GRIP_COLOR
	attach(body, grip, CFrame.new(0, 0, 0.12))

	local tail = cylinder(model, "TailCap", 0.08, 0.26)
	tail.Material = Enum.Material.Metal
	tail.Color = BODY_COLOR
	attach(body, tail, CFrame.new(0, 0, 0.45))

	local switch = Instance.new("Part")
	switch.Name = "Switch"
	switch.Size = Vector3.new(0.07, 0.05, 0.14)
	switch.Material = Enum.Material.Rubber
	switch.Color = GRIP_COLOR
	switch.Massless = true
	switch.CanCollide = false
	switch.CanQuery = false
	switch.CanTouch = false
	switch.CastShadow = false
	switch.Parent = model
	switch.CFrame = body.CFrame * CYLINDER:Inverse() * CFrame.new(0, 0.13, -0.18)
	local switchWeld = Instance.new("WeldConstraint")
	switchWeld.Part0 = body
	switchWeld.Part1 = switch
	switchWeld.Parent = switch

	local head = cylinder(model, "Head", 0.26, 0.34)
	head.Material = Enum.Material.Metal
	head.Color = BODY_COLOR
	attach(body, head, CFrame.new(0, 0, -0.56))

	local ring = cylinder(model, "LensRing", 0.05, 0.36)
	ring.Material = Enum.Material.Metal
	ring.Color = RING_COLOR
	ring.Reflectance = 0.15
	attach(body, ring, CFrame.new(0, 0, -0.71))

	local lens = cylinder(model, "Lens", 0.03, 0.28)
	lens.Material = Enum.Material.Glass
	lens.Color = LENS_OFF
	lens.Transparency = 0.25
	attach(body, lens, CFrame.new(0, 0, -0.735))

	local mount = Instance.new("Weld")
	mount.Name = "TorchMount"
	mount.C1 = CYLINDER:Inverse()
	mount.Part1 = body
	mount.Parent = body

	model.PrimaryPart = body
	model.Parent = character
	return { model = model, body = body, lens = lens, mount = mount }
end

--------------------------------------------------------------------------------
-- Runtime (one local rig)
--------------------------------------------------------------------------------

local api: AnimationApi? = nil
local character: Model? = nil
local torch: Torch? = nil
local pose: Pose = "Flashlight"
local poseTarget: CFrame? = nil
local lowered = 0
local lensLit: boolean? = nil
local released = true

local function callApi(fn: (Hand, any) -> (), hand: Hand, value: any)
	xpcall(fn, function(err: any)
		log.warnThrottled("api", 10, "hand goal failed: %s", tostring(err))
	end, hand, value)
end

local function release()
	local bound = api
	if bound and not released then
		callApi(bound.SetHandTarget, "Left", nil)
		callApi(bound.SetHandTarget, "Right", nil)
		callApi(bound.SetHandGrip, "Left", 0)
		callApi(bound.SetHandGrip, "Right", 0)
	end
	released = true
end

local function mountTorch(inHand: boolean)
	local current = torch
	local model = character
	if not current or not model then
		return
	end
	local part0: Instance? = model:FindFirstChild(if inHand then "RightHand" else "UpperTorso")
	if part0 == nil or not part0:IsA("BasePart") then
		part0 = model:FindFirstChild("UpperTorso")
		inHand = false
	end
	if part0 == nil or not part0:IsA("BasePart") then
		return
	end
	local mount = current.mount
	local offset = if inHand then HAND_MOUNT else CHEST_MOUNT
	if mount.Part0 ~= part0 then
		mount.Part0 = part0
	end
	if mount.C0 ~= offset then
		mount.C0 = offset
	end
end

function HandRig.Bind(animation: AnimationApi)
	api = animation
end

-- Builds the torch into a new character (nil removes it).
function HandRig.SetCharacter(model: Model?)
	local previous = torch
	torch = nil
	if previous then
		previous.model:Destroy()
	end
	release()
	character = model
	lowered = 0
	lensLit = nil
	if model then
		local ok, result = pcall(buildTorch, model)
		if ok then
			torch = result
			mountTorch(pose == "Flashlight")
		else
			log.warn("torch build failed: %s", tostring(result))
		end
	end
end

function HandRig.SetPose(name: Pose, target: CFrame?)
	if table.find(HandRig.Poses, name) == nil then
		log.warnThrottled("pose" .. tostring(name), 30, "unknown hand pose %s", tostring(name))
		return
	end
	pose = name
	poseTarget = target
end

function HandRig.GetPose(): Pose
	return pose
end

-- World frame of the torch lens (beam origin), if the torch exists.
function HandRig.GetLens(): CFrame?
	local current = torch
	if not current or current.body.Parent == nil then
		return nil
	end
	return current.body.CFrame * CYLINDER:Inverse() * LENS_OFFSET
end

function HandRig.Update(context: UpdateContext)
	local sprinting = context.moveState == "Sprinting"
	lowered = MathUtil.dampNumber(lowered, if sprinting then 1 else 0, LOWER_SPEED, context.dt)

	local current = torch
	if current and lensLit ~= context.lit then
		lensLit = context.lit
		current.lens.Material = if context.lit then Enum.Material.Neon else Enum.Material.Glass
		current.lens.Color = if context.lit then LENS_ON else LENS_OFF
		current.lens.Transparency = if context.lit then 0 else 0.25
	end

	local busy = HandRig.handsBusy(context.moveState)
	local effective: Pose = pose
	if effective == "Flashlight" and busy then
		effective = "Free"
	end
	if not context.active then
		effective = "Free"
	end
	local placement = HandRig.placements(effective, poseTarget, HandRig.flashlightTarget(context.look, lowered))
	mountTorch(placement.torchInHand)

	local bound = api
	if not bound then
		return
	end
	if placement.left == nil and placement.right == nil then
		release()
		return
	end
	released = false
	callApi(bound.SetHandTarget, "Left", placement.left)
	callApi(bound.SetHandTarget, "Right", placement.right)
	callApi(bound.SetHandGrip, "Left", placement.leftGrip)
	callApi(bound.SetHandGrip, "Right", placement.rightGrip)
end

-- The sprint carry blend 0..1 (the beam dips with it).
function HandRig.GetLowered(): number
	return lowered
end

return HandRig
