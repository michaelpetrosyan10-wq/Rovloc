--!strict
-- CharacterAnimationController: animates every player character on this client (its own and every teammate's)
-- with the ProceduralAnimator and the PlayerR15 profile. Motor6D.Transform does not replicate, so each client
-- poses every rig itself.
--
--   * Rigs: an Animator per character, created when the character appears (CharacterAdded, respawns, joins) as soon
--     as its R15 joints exist, destroyed when it goes (CharacterRemoving, leaving, the rig losing joints).
--   * Inputs, read only when the driver is about to step a rig (LOD): the move state (the local player: the
--     predicted state from SetLocalMoveState, except server-only override states, which win at once; others: the
--     replicated MoveState attribute), LifeState (Downed forces the crawl, Dead the limp body), root velocity from
--     AssemblyLinearVelocity, grounded from Humanoid.FloorMaterial (a short ray for other players, whose Humanoids
--     this client does not simulate) and the look: SetLocalLook every frame from the camera for the local player,
--     LookBroadcast samples (int16, dequantized, smoothed) for the others.
--   * Footsteps: each plant the animator reports is resolved to a SurfaceKind (PoolWater volume -> Water; the floor
--     part's Surface attribute; its material through the Palette; the room's Zone Surface; Concrete), played with
--     SynthPresets.footstep(surface, sprint) through AudioController.PlayLocal (3D at the foot for others; 2D and
--     quieter for the local player, whose ears are above the feet) and fired on Footstep.
--   * Hands: SetHandTarget / SetHandGrip drive the local rig's arm IK (HandRig's flashlight, pry and grip poses);
--     they survive respawns.
--   * Feet: near rigs probe the floor under each foot (stairs, debris, ramps) so planted feet meet it.
--   * LOD: RenderBudgetController's animNear / animFar go to ProceduralAnimator.SetLod; the local rig always runs at
--     full rate.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Palette = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Palette)
local PlayerR15 = require(ReplicatedStorage.Shared.Animation.ProceduralAnimator.Profiles.PlayerR15)
local ProceduralAnimator = require(ReplicatedStorage.Shared.Animation.ProceduralAnimator)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)

local Controllers = script.Parent.Parent
local AudioController = require(Controllers.Core.AudioController)
local RenderBudgetController = require(Controllers.Core.RenderBudgetController)

local log = Log.new("CharacterAnimation")

local P = Attributes.Player
local W = Attributes.World

export type Hand = "Left" | "Right"
export type LookSample = { yaw: number, pitch: number }

local SELF_FOOTSTEP_VOLUME = 0.55 -- own footsteps are heard from the head, 2D
local JOINT_WAIT_SECONDS = 10 -- how long a new character may take to receive its joints
local LOOK_DAMP = 14
local GROUND_RAY_MARGIN = 0.8 -- remote grounded test: floor within the rig's hip height plus this
local SURFACE_RAY_UP = 1.2
local SURFACE_RAY_DOWN = 3
local WATER_PROBE_LIFT = 0.3
local DEAD: string = PlayerR15.DeadState
local DOWNED: Enums.MoveState = "DownedCrawling"
local STANDING: Enums.MoveState = "Standing"

-- States only the server decides (the override stack): they beat the local prediction immediately.
local SERVER_STATES: { Enums.MoveState } = { "Scripted", "Grabbed", "Trapped", "Hiding", "Parachuting", DOWNED }
-- Server states that also beat being Downed (a downed player can still be grabbed, scripted or held).
local OVER_DOWNED: { Enums.MoveState } = { "Scripted", "Grabbed", "Trapped", "Hiding" }

type Entry = {
	player: Player,
	model: Model,
	root: BasePart,
	humanoid: Humanoid?,
	animator: ProceduralAnimator.Animator,
	trove: Trove.Trove,
	isLocal: boolean,
	lookYaw: number,
	lookPitch: number,
	rayParams: RaycastParams,
	groundDistance: number,
}

local CharacterAnimationController = {}

CharacterAnimationController.Name = "CharacterAnimationController"
CharacterAnimationController.SelfFootstepVolume = SELF_FOOTSTEP_VOLUME

local footstep: Signal.Signal<Player, Vector3, Enums.SurfaceKind, boolean> = Signal.new()
-- (player, foot position, surface, sprinting): every footstep this client hears, its own included.
CharacterAnimationController.Footstep = footstep

local serviceTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local entries: { [Player]: Entry } = {}
local waiting: { [Player]: Trove.Trove } = {}
local playerTroves: { [Player]: Trove.Trove } = {}
local remoteLooks: { [number]: LookSample } = {}
local zones: { BasePart } = {}
local waters: { BasePart } = {}
local lastZone: { [Player]: BasePart } = {}

local predictedState: Enums.MoveState? = nil
local localLook: LookSample? = nil
local handTargets: { [Hand]: CFrame? } = {}
local handGrips: { [Hand]: number } = { Left = 0, Right = 0 }

--------------------------------------------------------------------------------
-- Pure helpers (specced)
--------------------------------------------------------------------------------

-- The profile state a rig should show. `predicted` is the local client's own prediction (nil for other players).
function CharacterAnimationController.resolveState(
	lifeState: string?,
	serverState: string?,
	predicted: string?,
	dead: boolean
): string
	if dead or lifeState == "Dead" then
		return DEAD
	end
	local server: Enums.MoveState? = if Enums.has(Enums.MoveState, serverState)
		then (serverState :: any) :: Enums.MoveState
		else nil
	if lifeState == "Downed" then
		if server and table.find(OVER_DOWNED, server) then
			return server
		end
		return DOWNED
	end
	if server and table.find(SERVER_STATES, server) then
		if server == DOWNED and lifeState ~= nil and lifeState ~= "Downed" and lifeState ~= "Spectating" then
			-- A stale crawl override after a revive: the life state is the fresher truth.
			if predicted and Enums.has(Enums.MoveState, predicted) then
				return predicted
			end
			return STANDING
		end
		return server
	end
	if predicted and Enums.has(Enums.MoveState, predicted) then
		return predicted
	end
	return server or STANDING
end

-- Material -> footstep surface, derived from the Palette (the most common surface among entries using it).
local materialSurfaces: { [Enum.Material]: Enums.SurfaceKind } = {}
do
	local counts: { [Enum.Material]: { [string]: number } } = {}
	for _, key in Palette.keys() do
		local entry = Palette.get(key)
		local bucket = counts[entry.material]
		if not bucket then
			bucket = {}
			counts[entry.material] = bucket
		end
		bucket[entry.surface] = (bucket[entry.surface] or 0) + 1
	end
	for material, bucket in counts do
		local best: Enums.SurfaceKind? = nil
		local bestCount = 0
		for _, surface: Enums.SurfaceKind in Enums.SurfaceKind do
			local count = bucket[surface] or 0
			if count > bestCount then
				best = surface
				bestCount = count
			end
		end
		if best then
			materialSurfaces[material] = best
		end
	end
	materialSurfaces[Enum.Material.Water] = "Water"
end

function CharacterAnimationController.materialSurface(material: Enum.Material): Enums.SurfaceKind?
	return materialSurfaces[material]
end

-- The footstep surface for a step: standing in water, the floor part's Surface attribute, its material, the room's
-- Surface, else Concrete.
function CharacterAnimationController.surfaceFor(
	inWater: boolean,
	partSurface: unknown,
	material: Enum.Material?,
	zoneSurface: unknown
): Enums.SurfaceKind
	if inWater then
		return "Water"
	end
	if Enums.has(Enums.SurfaceKind, partSurface) then
		return (partSurface :: any) :: Enums.SurfaceKind
	end
	if material then
		local fromMaterial: Enums.SurfaceKind? = materialSurfaces[material]
		if fromMaterial ~= nil then
			return fromMaterial :: Enums.SurfaceKind
		end
	end
	if Enums.has(Enums.SurfaceKind, zoneSurface) then
		return (zoneSurface :: any) :: Enums.SurfaceKind
	end
	return "Concrete"
end

-- LookBroadcast payload -> dequantized look per UserId. Malformed samples are skipped.
function CharacterAnimationController.parseLookBroadcast(payload: unknown): { [number]: LookSample }
	local out: { [number]: LookSample } = {}
	if type(payload) ~= "table" then
		return out
	end
	local samples = (payload :: any).samples
	if type(samples) ~= "table" then
		return out
	end
	for _, sample in samples :: { any } do
		if type(sample) ~= "table" then
			continue
		end
		local userId = sample.userId
		local yaw = sample.yaw
		local pitch = sample.pitch
		if userId == nil then
			userId, yaw, pitch = sample[1], sample[2], sample[3]
		end
		if
			type(userId) == "number"
			and type(yaw) == "number"
			and type(pitch) == "number"
			and MathUtil.isFinite(yaw)
			and MathUtil.isFinite(pitch)
		then
			out[userId] = {
				yaw = MathUtil.dequantizeAngle(yaw),
				pitch = math.clamp(MathUtil.dequantizeAngle(pitch), -math.pi / 2, math.pi / 2),
			}
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- World queries
--------------------------------------------------------------------------------

local function watchParts(tag: string, list: { BasePart })
	local function added(instance: Instance)
		if instance:IsA("BasePart") and table.find(list, instance) == nil then
			table.insert(list, instance)
		end
	end
	local function removed(instance: Instance)
		if not instance:IsA("BasePart") then
			return
		end
		local index = table.find(list, instance)
		if index then
			table.remove(list, index)
		end
	end
	serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(tag), added)
	serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(tag), removed)
	for _, instance in CollectionService:GetTagged(tag) do
		added(instance)
	end
end

local function inWater(point: Vector3): boolean
	for _, volume in waters do
		if volume.Parent ~= nil and SpatialQuery.pointInPart(volume, point) then
			return true
		end
	end
	return false
end

local function zoneSurface(player: Player, point: Vector3): unknown
	local last = lastZone[player]
	if last and last.Parent ~= nil and SpatialQuery.pointInPart(last, point) then
		return last:GetAttribute(W.Surface)
	end
	for _, zone in zones do
		if zone.Parent ~= nil and SpatialQuery.pointInPart(zone, point) then
			lastZone[player] = zone
			return zone:GetAttribute(W.Surface)
		end
	end
	return nil
end

local function surfaceAt(entry: Entry, position: Vector3): Enums.SurfaceKind
	local hit = Workspace:Raycast(
		position + Vector3.new(0, SURFACE_RAY_UP, 0),
		Vector3.new(0, -(SURFACE_RAY_UP + SURFACE_RAY_DOWN), 0),
		entry.rayParams
	)
	local partSurface: unknown = nil
	local material: Enum.Material? = nil
	if hit then
		partSurface = hit.Instance:GetAttribute(W.Surface)
		material = hit.Material
	end
	local wet = inWater(position + Vector3.new(0, WATER_PROBE_LIFT, 0))
	local zone = if partSurface == nil and (material == nil or materialSurfaces[material] == nil)
		then zoneSurface(entry.player, position)
		else nil
	return CharacterAnimationController.surfaceFor(wet, partSurface, material, zone)
end

--------------------------------------------------------------------------------
-- Inputs
--------------------------------------------------------------------------------

local function cameraLook(): LookSample?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local yaw, pitch = MathUtil.yawPitchFromVector(camera.CFrame.LookVector)
	return { yaw = yaw, pitch = pitch }
end

local function isGrounded(entry: Entry): boolean
	local humanoid = entry.humanoid
	if entry.isLocal and humanoid then
		return humanoid.FloorMaterial ~= Enum.Material.Air
	end
	local root = entry.root
	local hit = Workspace:Raycast(
		root.Position,
		Vector3.new(0, -(entry.groundDistance + GROUND_RAY_MARGIN), 0),
		entry.rayParams
	)
	return hit ~= nil
end

local function stateFor(entry: Entry): string
	local player = entry.player
	local humanoid = entry.humanoid
	local dead = humanoid ~= nil and humanoid.Health <= 0
	local lifeState = player:GetAttribute(P.LifeState)
	local serverState = player:GetAttribute(P.MoveState)
	return CharacterAnimationController.resolveState(
		if type(lifeState) == "string" then lifeState else nil,
		if type(serverState) == "string" then serverState else nil,
		if entry.isLocal then predictedState else nil,
		dead
	)
end

local function feed(entry: Entry, animator: ProceduralAnimator.Animator, dt: number)
	local root = entry.root
	local velocity = if root.Anchored then Vector3.zero else root.AssemblyLinearVelocity
	local look: LookSample?
	if entry.isLocal then
		look = localLook or cameraLook()
	else
		look = remoteLooks[entry.player.UserId]
	end
	if look then
		local blend = MathUtil.damp(LOOK_DAMP, dt)
		entry.lookYaw += MathUtil.angleDelta(entry.lookYaw, look.yaw) * (if entry.isLocal then 1 else blend)
		entry.lookPitch += (look.pitch - entry.lookPitch) * (if entry.isLocal then 1 else blend)
	else
		entry.lookYaw = ProceduralAnimator.yawOf(root.CFrame)
		entry.lookPitch = 0
	end
	animator:SetInputs({
		moveState = stateFor(entry),
		velocity = velocity,
		grounded = isGrounded(entry),
		lookYaw = entry.lookYaw,
		lookPitch = entry.lookPitch,
	})
end

--------------------------------------------------------------------------------
-- Footsteps
--------------------------------------------------------------------------------

local function onFootstep(entry: Entry, event: ProceduralAnimator.FootstepEvent)
	local surface: Enums.SurfaceKind = surfaceAt(entry, event.position)
	local preset = SynthPresets.footstep(surface, event.sprint)
	if entry.isLocal then
		AudioController.PlayLocal(preset, { volume = event.volume * SELF_FOOTSTEP_VOLUME })
	else
		AudioController.PlayLocal(preset, { position = event.position, volume = event.volume })
	end
	footstep:Fire(entry.player, event.position, surface, event.sprint)
end

--------------------------------------------------------------------------------
-- Rigs
--------------------------------------------------------------------------------

local function detach(player: Player)
	local pending = waiting[player]
	if pending then
		waiting[player] = nil
		pending:Destroy()
	end
	local entry = entries[player]
	if entry then
		entries[player] = nil
		entry.trove:Destroy()
	end
	lastZone[player] = nil
end

local function applyHands(animator: ProceduralAnimator.Animator)
	for _, hand: Hand in { "Left", "Right" } :: { Hand } do
		animator:SetHandTarget(hand, handTargets[hand])
		animator:SetHandGrip(hand, handGrips[hand])
	end
end

local attach: (player: Player, model: Model) -> ()

-- Tries to animate `model`; false while it still lacks joints.
local function tryAttach(player: Player, model: Model): boolean
	if #ProceduralAnimator.missingJoints(model, PlayerR15.Profile) > 0 then
		return false
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return false
	end
	local isLocal = player == localPlayer
	local animator, reason =
		ProceduralAnimator.new(model, PlayerR15.Profile, { seed = player.UserId, priority = isLocal })
	if not animator then
		log.warn("cannot animate %s: %s", player.Name, tostring(reason))
		return true
	end
	local trove = Trove.new()
	trove:Add(animator)
	local params = SpatialQuery.worldParams({ model })
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local yaw, pitch = ProceduralAnimator.yawOf(root.CFrame), 0
	local entry: Entry = {
		player = player,
		model = model,
		root = root,
		humanoid = humanoid,
		animator = animator,
		trove = trove,
		isLocal = isLocal,
		lookYaw = yaw,
		lookPitch = pitch,
		rayParams = params,
		groundDistance = -animator.Map.groundY,
	}
	entries[player] = entry
	animator:SetInputProvider(function(target: ProceduralAnimator.Animator, dt: number)
		if not ProceduralAnimator.JointMap.isIntact(target.Map) then
			task.defer(function()
				if entries[player] == entry then
					detach(player)
					if model.Parent ~= nil and player.Character == model then
						-- The rig was rebuilt under us (joints replaced): start over on the new joints.
						attach(player, model)
					end
				end
			end)
			return
		end
		feed(entry, target, dt)
	end)
	animator:SetGroundProbe(function(origin: Vector3, direction: Vector3): Vector3?
		local hit = Workspace:Raycast(origin, direction, params)
		return if hit then hit.Position else nil
	end)
	trove:Add(animator.Footstep:Connect(function(event: ProceduralAnimator.FootstepEvent)
		onFootstep(entry, event)
	end))
	if isLocal then
		applyHands(animator)
	end
	return true
end

function attach(player: Player, model: Model)
	detach(player)
	if tryAttach(player, model) then
		return
	end
	-- Joints still replicating: retry as descendants arrive, for a while.
	local pending = Trove.new()
	waiting[player] = pending
	local queued = false
	local function retry()
		queued = false
		if waiting[player] ~= pending then
			return
		end
		if model.Parent == nil or player.Character ~= model then
			detach(player)
			return
		end
		if tryAttach(player, model) then
			waiting[player] = nil
			pending:Destroy()
		end
	end
	pending:Connect(model.DescendantAdded, function()
		if not queued then
			queued = true
			task.defer(retry)
		end
	end)
	pending:Delay(JOINT_WAIT_SECONDS, function()
		if waiting[player] == pending then
			log.warn("%s's character never received its R15 joints; it stays unanimated", player.Name)
			waiting[player] = nil
			pending:Destroy()
		end
	end)
end

local function watchPlayer(player: Player)
	if playerTroves[player] then
		return
	end
	local trove = Trove.new()
	playerTroves[player] = trove
	trove:Connect(player.CharacterAdded, function(model: Model)
		attach(player, model)
	end)
	trove:Connect(player.CharacterRemoving, function(model: Model)
		local entry = entries[player]
		if (entry and entry.model == model) or waiting[player] then
			detach(player)
		end
	end)
	local current = player.Character
	if current then
		attach(player, current)
	end
end

local function unwatchPlayer(player: Player)
	detach(player)
	local trove = playerTroves[player]
	if trove then
		playerTroves[player] = nil
		trove:Destroy()
	end
	remoteLooks[player.UserId] = nil
end

local function onLookBroadcast(payload: any)
	for userId, sample in CharacterAnimationController.parseLookBroadcast(payload) do
		remoteLooks[userId] = sample
	end
end

local function applyBudget(budget: RenderBudgetController.Budget)
	ProceduralAnimator.SetLod(budget.animNear, budget.animFar)
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- The local player's predicted move state (MovementController calls this on every change).
function CharacterAnimationController.SetLocalMoveState(state: Enums.MoveState)
	if Enums.has(Enums.MoveState, state) then
		predictedState = state
	end
end

-- The local look (camera yaw / pitch, radians, MathUtil convention), every frame.
function CharacterAnimationController.SetLocalLook(yaw: number, pitch: number)
	if MathUtil.isFinite(yaw) and MathUtil.isFinite(pitch) then
		localLook = { yaw = yaw, pitch = pitch }
	end
end

-- A world-space grip frame for the local hand to hold (see PlayerR15.Grip): position = where the item is held,
-- LookVector = the item's forward, UpVector = its top. nil releases the hand back to the animation.
function CharacterAnimationController.SetHandTarget(hand: Hand, target: CFrame?)
	if hand ~= "Left" and hand ~= "Right" then
		return
	end
	handTargets[hand] = target
	local entry = if localPlayer then entries[localPlayer] else nil
	if entry then
		entry.animator:SetHandTarget(hand, target)
	end
end

-- How tightly the local hand grips: 0 open .. 1 fist.
function CharacterAnimationController.SetHandGrip(hand: Hand, grip: number)
	if (hand ~= "Left" and hand ~= "Right") or not MathUtil.isFinite(grip) then
		return
	end
	handGrips[hand] = math.clamp(grip, 0, 1)
	local entry = if localPlayer then entries[localPlayer] else nil
	if entry then
		entry.animator:SetHandGrip(hand, handGrips[hand])
	end
end

-- The animated character model of `player` (nil while it has none or it is not animated yet).
function CharacterAnimationController.GetRig(player: Player): Model?
	local entry = entries[player]
	return if entry then entry.model else nil
end

-- The Animator posing `player`'s character (later phases read its state, phase and part frames).
function CharacterAnimationController.GetAnimator(player: Player): ProceduralAnimator.Animator?
	local entry = entries[player]
	return if entry then entry.animator else nil
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function CharacterAnimationController.Init()
	watchParts(Tags.Zone, zones)
	watchParts(Tags.PoolWater, waters)
end

function CharacterAnimationController.Start()
	applyBudget(RenderBudgetController.GetBudget())
	serviceTrove:Add(RenderBudgetController.BudgetChanged:Connect(applyBudget))
	local connection = Net.Client.on("LookBroadcast", onLookBroadcast)
	if connection then
		serviceTrove:Add(connection)
	end
	serviceTrove:Connect(Players.PlayerAdded, watchPlayer)
	serviceTrove:Connect(Players.PlayerRemoving, unwatchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
end

function CharacterAnimationController.OnRunEnded()
	-- Run-scoped looks go stale with the run; the next broadcasts refill them.
	table.clear(remoteLooks)
end

return table.freeze(CharacterAnimationController)
