--!strict
-- CreatureBody: the Creature's physical body on the server. MonsterAIService (the only writer of the Creature's
-- attributes) drives it; this module touches parts and constraints only.
--
--   * Ownership: the Creature is a server-owned assembly. Reassert() hands every unanchored assembly back to the
--     server (SetNetworkOwner(nil)) and, in Studio, audits on the next frame that nobody else owns it. It runs after
--     every anchor change and every placement.
--   * Pose: SetPose(poseMode) resizes and re-lays the CreatureHitbox (CreatureRigBuilder.setHitbox) for the pose:
--     tall for Biped, shorter for Hunched, a low long box centred on the rail for Quadruped, on the water line for
--     Swim.
--   * Hidden: a hidden Creature's hitbox stops answering queries (flasks fly through, nothing hits it); clients hide
--     the rig from the Hidden attribute.
--   * Kinematic modes (the vent rail, swimming, scripted holds, dormancy) anchor the root and place it by CFrame; the
--     floor mode leaves it unanchored and lets the Humanoid walk it (WalkSpeed per state, AutoRotate).
--   * Facing on the floor: an AlignOrientation on the root (OneAttachment, off by default) turns it to a direction
--     with AutoRotate off; releasing the face hands rotation back to the Humanoid. Anchored, the root is turned
--     directly.
--   * Stuck detection is a pure tracker: no progress of MinProgress studs for CreatureConfig.Repath.StuckSeconds while
--     trying to move counts as stuck.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local CreatureRigBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.CreatureRigBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)

local log = Log.new("CreatureBody")

local NAMES = CreatureRigBuilder.PartNames
local RIG = CreatureConfig.Rig

local FACE_ATTACHMENT = "AIFacing"
local FACE_ALIGN = "AIFacingAlign"
local FACE_RESPONSIVENESS = 14
local FACE_TORQUE = 4e6
local MIN_PROGRESS = 1.2 -- studs the root must move within StuckSeconds while trying to

export type Body = {
	model: Model,
	root: BasePart,
	humanoid: Humanoid?,
	hitbox: BasePart?,
	pose: Enums.PoseMode,
	anchored: boolean,
	hidden: boolean,
	SetPose: (self: Body, pose: Enums.PoseMode) -> (),
	SetAnchored: (self: Body, anchored: boolean) -> (),
	SetHidden: (self: Body, hidden: boolean) -> (),
	SetWalkSpeed: (self: Body, speed: number) -> (),
	Face: (self: Body, direction: Vector3?) -> (),
	PlaceAt: (self: Body, cframe: CFrame) -> (),
	Reassert: (self: Body) -> (),
	GetCFrame: (self: Body) -> CFrame,
	GetPosition: (self: Body) -> Vector3,
	Destroy: (self: Body) -> (),
}

export type StuckTracker = {
	Sample: (self: StuckTracker, position: Vector3, now: number, trying: boolean) -> boolean,
	Reset: (self: StuckTracker) -> (),
}

local CreatureBody = {}

-- Height of the root's centre above the floor when the Creature stands.
CreatureBody.RootHeight = RIG.HipHeight + RIG.RootSize.Y / 2
CreatureBody.MinProgress = MIN_PROGRESS

-- A flat (horizontal) unit direction, or nil when `direction` has no horizontal part.
function CreatureBody.flatDirection(direction: Vector3): Vector3?
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-4 then
		return nil
	end
	return flat.Unit
end

-- No progress of `minProgress` studs for `seconds` while trying to move (pure; the caller samples it).
function CreatureBody.newStuckTracker(seconds: number, minProgress: number?): StuckTracker
	local need = minProgress or MIN_PROGRESS
	local anchor: Vector3? = nil
	local since = 0
	local tracker: StuckTracker
	tracker = {
		Sample = function(_self: StuckTracker, position: Vector3, now: number, trying: boolean): boolean
			local from = anchor
			if not trying or from == nil then
				anchor = position
				since = now
				return false
			end
			if (position - from).Magnitude >= need then
				anchor = position
				since = now
				return false
			end
			if now - since >= seconds then
				anchor = position
				since = now
				return true
			end
			return false
		end,
		Reset = function(_self: StuckTracker)
			anchor = nil
			since = 0
		end,
	}
	return tracker
end

local function findPart(model: Model, name: string): BasePart?
	local found = model:FindFirstChild(name)
	return if found and found:IsA("BasePart") then found else nil
end

local function poseOf(model: Model): Enums.PoseMode
	local value = model:GetAttribute("PoseMode")
	if type(value) == "string" and Enums.has(Enums.PoseMode, value) then
		return value :: Enums.PoseMode
	end
	return "Biped"
end

-- The body of `model` (nil when it has no HumanoidRootPart).
function CreatureBody.attach(model: Model): Body?
	local root = findPart(model, NAMES.Root)
	if not root then
		log.warn("%s has no %s; the Creature cannot move", model:GetFullName(), NAMES.Root)
		return nil
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local hitbox = findPart(model, NAMES.Hitbox)

	local attachment = root:FindFirstChild(FACE_ATTACHMENT)
	if not (attachment and attachment:IsA("Attachment")) then
		local created = Instance.new("Attachment")
		created.Name = FACE_ATTACHMENT
		created.Parent = root
		attachment = created
	end
	local align = root:FindFirstChild(FACE_ALIGN)
	if not (align and align:IsA("AlignOrientation")) then
		local created = Instance.new("AlignOrientation")
		created.Name = FACE_ALIGN
		created.Mode = Enum.OrientationAlignmentMode.OneAttachment
		created.Attachment0 = attachment :: Attachment
		created.Responsiveness = FACE_RESPONSIVENESS
		created.MaxTorque = FACE_TORQUE
		created.RigidityEnabled = false
		created.Enabled = false
		created.Parent = root
		align = created
	end
	local faceAlign = align :: AlignOrientation

	local body: Body
	body = {
		model = model,
		root = root,
		humanoid = humanoid,
		hitbox = hitbox,
		pose = poseOf(model),
		anchored = root.Anchored,
		hidden = false,

		SetPose = function(self: Body, pose: Enums.PoseMode)
			if self.pose == pose then
				return
			end
			self.pose = pose
			CreatureRigBuilder.setHitbox(self.model, pose)
		end,

		SetAnchored = function(self: Body, anchored: boolean)
			self.anchored = anchored
			if self.root.Anchored == anchored then
				return
			end
			self.root.Anchored = anchored
			if anchored then
				faceAlign.Enabled = false
			else
				self.root.AssemblyLinearVelocity = Vector3.zero
				self.root.AssemblyAngularVelocity = Vector3.zero
			end
			self:Reassert()
		end,

		SetHidden = function(self: Body, hidden: boolean)
			self.hidden = hidden
			local box = self.hitbox
			if box then
				box.CanQuery = not hidden
			end
		end,

		SetWalkSpeed = function(self: Body, speed: number)
			local walker = self.humanoid
			if walker and walker.WalkSpeed ~= speed then
				walker.WalkSpeed = speed
			end
		end,

		Face = function(self: Body, direction: Vector3?)
			local walker = self.humanoid
			local flat = if direction then CreatureBody.flatDirection(direction) else nil
			if flat == nil then
				faceAlign.Enabled = false
				if walker then
					walker.AutoRotate = true
				end
				return
			end
			if self.root.Anchored then
				local position = self.root.CFrame.Position
				self.root.CFrame = CFrame.lookAt(position, position + flat)
				return
			end
			if walker then
				walker.AutoRotate = false
			end
			faceAlign.CFrame = CFrame.lookAt(Vector3.zero, flat)
			faceAlign.Enabled = true
		end,

		PlaceAt = function(self: Body, cframe: CFrame)
			self.root.CFrame = cframe
			if not self.root.Anchored then
				self.root.AssemblyLinearVelocity = Vector3.zero
				self.root.AssemblyAngularVelocity = Vector3.zero
				self:Reassert()
			end
		end,

		Reassert = function(self: Body)
			local part = self.root
			if part.Anchored or not part:IsDescendantOf(Workspace) then
				return
			end
			local allowed = part:CanSetNetworkOwnership()
			if not allowed then
				return
			end
			part:SetNetworkOwner(nil)
			if RunService:IsStudio() then
				task.defer(function()
					if part.Parent and not part.Anchored and part:GetNetworkOwner() ~= nil then
						log.warn("the Creature's root is owned by %s, not the server", tostring(part:GetNetworkOwner()))
					end
				end)
			end
		end,

		GetCFrame = function(self: Body): CFrame
			return self.root.CFrame
		end,

		GetPosition = function(self: Body): Vector3
			return self.root.CFrame.Position
		end,

		Destroy = function(_self: Body)
			faceAlign.Enabled = false
		end,
	}
	return body
end

return table.freeze(CreatureBody)
