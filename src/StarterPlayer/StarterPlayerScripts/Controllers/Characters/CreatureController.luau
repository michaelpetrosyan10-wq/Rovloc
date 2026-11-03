--!strict
-- CreatureController: animates the run's Creature on this client with the ProceduralAnimator and the Creature
-- profile. Motor6D.Transform does not replicate, so every client poses the Creature itself, from replicated state.
--
--   * Rig: the Creature appears (tag Creature, under Workspace) when a run places it and goes with the run. It gets
--     an Animator as soon as its joints exist (retried while they replicate); a rig that loses joints is re-attached.
--   * Inputs, read when the driver is about to step the rig (LOD): the profile state from MonsterState + PoseMode +
--     InVent (Creature.resolveState), the hunch from PoseMode Hunched, the root's velocity (replicated assembly
--     velocity, or measured from its motion when the server moves it kinematically), grounded (a short ray; always
--     in ducts and water), server time as the animator clock (so actions and seeded twitches line up on every
--     client) and the look: the player whose UserId is TargetUserId (their eyes; the camera for this client's own
--     player), measured from the Creature's eye point (SpatialQuery.creatureEye). With no target the head scans by
--     itself. The rig steps at full rate while it hunts this client's player, otherwise under the render budget's
--     LOD (RenderBudgetController animNear / animFar, applied by CharacterAnimationController); beyond animFar this
--     controller's own per-frame work (pupils, loop volumes) pauses too.
--   * Actions: PlayAction(name, startAt?) layers a one-shot (NeckSnap, Lunge, LockerRip, DoorSmash, Vanish, Reveal)
--     at server time `startAt`. Timelines drive them through the SequenceController track kind "creature" (each
--     key's value is an action name, played at the key's server time; late keys fast-forward), and the matching
--     OneShots play them too: CreatureVanish -> Vanish, CreatureReveal -> Reveal, Jumpscare -> Lunge, and
--     LockerRip / DoorSmash when the Creature is near their subject. The same action at the same moment from two
--     sources plays once. Actions asked for before the Creature exists wait for it (while they would still run).
--   * Hidden: LocalTransparencyModifier 1 on every part of the Creature (this controller is its only writer of it),
--     its sounds silenced; back to 0 when it reappears.
--   * Pupils: the pinprick Neon pupils are faint in the light and brighten (less transparent, slightly larger) while
--     the Creature is in a duct or in darkness (the summed falloff of the LevelLight fixtures' lit lights at its eyes).
--   * Audio (AudioController.PlayLocal, SynthPresets names): while InVent, looped VentScrape + VentBreathing follow
--     the root in 3D (everyone hears it in the walls), louder with speed; footsteps at the feet from the animator's
--     plants (heavy and slow on two legs: the surface's footstep slowed and boosted; claws skittering in ducts);
--     an occasional CreatureGrowl at the head while it chases, scheduled on server-time slots so every client hears
--     the same growl.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local Creature = require(ReplicatedStorage.Shared.Animation.ProceduralAnimator.Profiles.Creature)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local CreatureRigBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.CreatureRigBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local ProceduralAnimator = require(ReplicatedStorage.Shared.Animation.ProceduralAnimator)
local SoundSynthesizer = require(ReplicatedStorage.Shared.Audio.SoundSynthesizer)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Timeline = require(ReplicatedStorage.Shared.Sequence.Timeline)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)

local Controllers = script.Parent.Parent
local AudioController = require(Controllers.Core.AudioController)
local RenderBudgetController = require(Controllers.Core.RenderBudgetController)
local SequenceController = require(Controllers.Core.SequenceController)
local CharacterAnimationController = require(script.Parent.CharacterAnimationController)

local log = Log.new("CreatureController")

local C = Attributes.Creature
local W = Attributes.World

export type LightSample = { position: Vector3, brightness: number, range: number }

local TRACK_KIND = "creature"
local CREATURE_SEED = 8517 -- every client seeds the Creature's variation the same way
local JOINT_WAIT_SECONDS = 10
local GROUND_MARGIN = 1.2
local TELEPORT_DISTANCE = 12 -- a jump this far in one step is a teleport, not motion
local VELOCITY_DAMP = 12
local EXTRAS_HZ = 10 -- pupils, darkness and loop volumes
local DARK_EXPOSURE = 0.12 -- below this the pupils glow fully
local LIT_EXPOSURE = 0.9 -- above this they are at their faintest
local LIGHT_REACH = 70 -- fixtures further than this from the eyes are ignored
local PUPIL_FAINT = 0.72 -- pupil transparency in the light
local PUPIL_BRIGHT = 0
local PUPIL_GROW = 1.35 -- pupil size factor at full glow
local PUPIL_SPEED = 3
local PUPIL_EPSILON = 0.004 -- smaller glow changes are not written
local LOOP_FADE = 0.6
local LOOP_VOLUME_FADE = 0.25
local SCRAPE_QUIET = 0.3
local BREATH_QUIET = 0.65
local GROWL_SLOT = 4.5 -- seconds; at most one growl per slot
local GROWL_CHANCE = 0.65
local HEAVY_SPEED = 0.72 -- footstep playback speed on two legs (deeper, heavier)
local HEAVY_SPRINT_SPEED = 0.66
local HEAVY_VOLUME = 1.5
local SKITTER_SPEED = 1.45
local SKITTER_VOLUME = 0.6
local SUBJECT_REACH = 24 -- LockerRip / DoorSmash OneShots animate the Creature only this close to their subject
local DUPLICATE_WINDOW = 0.05 -- the same action within this many seconds of a running one is the same moment
local QUADRUPED_STATES: { [string]: boolean } = { VentCrawl = true, VentRetreat = true }
local CHASE_STATES: { [string]: boolean } = { WallChase = true, VentChase = true }
local ONESHOT_ACTIONS: { [string]: string } = {
	CreatureVanish = "Vanish",
	CreatureReveal = "Reveal",
	Jumpscare = "Lunge",
	LockerRip = "LockerRip",
	DoorSmash = "DoorSmash",
}
local NEEDS_SUBJECT: { [string]: boolean } = { LockerRip = true, DoorSmash = true }

type Pupil = { part: BasePart, size: Vector3, transparency: number }

type Entry = {
	model: Model,
	root: BasePart,
	animator: ProceduralAnimator.Animator,
	trove: Trove.Trove,
	parts: { BasePart },
	pupils: { Pupil },
	rayParams: RaycastParams,
	groundDistance: number,
	lastPosition: Vector3?,
	velocity: Vector3,
	speed: number,
	hidden: boolean,
	glow: number,
	extrasClock: number,
	scrape: SoundSynthesizer.Voice?,
	breathing: SoundSynthesizer.Voice?,
	growlSlot: number, -- the last growl slot dealt with
	growlPlan: number, -- the slot `growlAt` was drawn for
	growlAt: number?,
}

type Pending = { name: string, startAt: number }

local CreatureController = {}

CreatureController.Name = "CreatureController"
CreatureController.TrackKind = TRACK_KIND

local serviceTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local current: Entry? = nil
local waiting: Trove.Trove? = nil
local pending: { Pending } = {}
local lights: { BasePart } = {}
local zones: { BasePart } = {}
local waters: { BasePart } = {}
local budgetFar = ProceduralAnimator.DefaultFar

--------------------------------------------------------------------------------
-- Pure helpers (specced)
--------------------------------------------------------------------------------

-- The profile state and hunch for the Creature's replicated attributes.
function CreatureController.resolveState(monsterState: unknown, poseMode: unknown, inVent: unknown): (string, number)
	return Creature.resolveState(monsterState, poseMode, inVent), Creature.hunchFor(poseMode)
end

-- The root's velocity: the replicated assembly velocity, or (when the server moves the root kinematically and that
-- reads still) its displacement over the step; teleports read as still.
function CreatureController.estimateVelocity(assembly: Vector3, displacement: Vector3, dt: number): Vector3
	if displacement.Magnitude > TELEPORT_DISTANCE or dt <= 0 then
		return if MathUtil.isFiniteVector(assembly) and assembly.Magnitude < 200 then assembly else Vector3.zero
	end
	local measured = displacement / dt
	if MathUtil.isFiniteVector(assembly) and assembly.Magnitude >= measured.Magnitude * 0.5 then
		return assembly
	end
	return measured
end

-- World yaw / pitch (MathUtil convention) from `eye` toward `target`; nil when they coincide.
function CreatureController.lookAt(eye: Vector3, target: Vector3): (number?, number?)
	local delta = target - eye
	if delta.Magnitude < 1e-3 or not MathUtil.isFiniteVector(delta) then
		return nil, nil
	end
	local yaw, pitch = MathUtil.yawPitchFromVector(delta)
	return yaw, pitch
end

-- Summed light falling on `point`: each lit source adds brightness * (1 - distance / range)^2 inside its range.
function CreatureController.exposure(point: Vector3, samples: { LightSample }): number
	local total = 0
	for _, sample in samples do
		if sample.brightness > 0 and sample.range > 0 then
			local distance = (sample.position - point).Magnitude
			if distance < sample.range then
				local falloff = 1 - distance / sample.range
				total += sample.brightness * falloff * falloff
			end
		end
	end
	return total
end

-- How brightly the pupils glow (0 faint .. 1 bright): fully in a duct or in the dark, fading out as light rises.
function CreatureController.pupilGlow(inVent: boolean, exposure: number): number
	if inVent then
		return 1
	end
	return 1 - MathUtil.smoothstep(DARK_EXPOSURE, LIT_EXPOSURE, exposure)
end

-- Pupil transparency and size factor for a glow.
function CreatureController.pupilLook(glow: number): (number, number)
	local g = MathUtil.clamp01(glow)
	return MathUtil.lerp(PUPIL_FAINT, PUPIL_BRIGHT, g), MathUtil.lerp(1, PUPIL_GROW, g)
end

-- Duct loop volumes (scrape, breathing) for the Creature's speed.
function CreatureController.ventVolumes(speed: number): (number, number)
	local pace = MathUtil.clamp01(speed / CreatureConfig.Speeds.VentChase)
	return MathUtil.lerp(SCRAPE_QUIET, 1, pace), MathUtil.lerp(BREATH_QUIET, 1, pace)
end

-- The server time a growl plays in growl slot `slot` (nil: a quiet slot). The same on every client.
function CreatureController.growlAt(slot: number, seed: number): number?
	local roll = MathUtil.seededRandom(seed, "Growl:" .. tostring(slot))
	if roll:NextNumber() >= GROWL_CHANCE then
		return nil
	end
	return (slot + roll:NextNumber(0.05, 0.85)) * GROWL_SLOT
end

-- Footstep playback (speed, volume) for an animator plant: claws skitter in the ducts, two legs land heavy.
function CreatureController.footstepVoice(state: string, sprint: boolean, volume: number): (number, number)
	if QUADRUPED_STATES[state] then
		return SKITTER_SPEED, volume * SKITTER_VOLUME
	end
	return if sprint then HEAVY_SPRINT_SPEED else HEAVY_SPEED, volume * HEAVY_VOLUME
end

-- True when `startAt` repeats an action already running from (nearly) the same moment.
function CreatureController.isDuplicate(runningStart: number?, startAt: number): boolean
	return runningStart ~= nil and math.abs(runningStart - startAt) <= DUPLICATE_WINDOW
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
		local index = table.find(list, instance :: any)
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

local function rangeOf(light: Light): number
	if light:IsA("PointLight") or light:IsA("SpotLight") or light:IsA("SurfaceLight") then
		return light.Range
	end
	return 0
end

-- The lit fixtures near `point`, as light samples.
local function lightSamples(point: Vector3): { LightSample }
	local samples: { LightSample } = {}
	for _, fixture in lights do
		if fixture.Parent == nil then
			continue
		end
		local position = fixture.Position
		if (position - point).Magnitude > LIGHT_REACH then
			continue
		end
		for _, child in fixture:GetChildren() do
			if child:IsA("Light") and child.Enabled and child.Brightness > 0 then
				table.insert(samples, { position = position, brightness = child.Brightness, range = rangeOf(child) })
			end
		end
	end
	return samples
end

local function inWater(point: Vector3): boolean
	for _, volume in waters do
		if volume.Parent ~= nil and SpatialQuery.pointInPart(volume, point) then
			return true
		end
	end
	return false
end

local function zoneSurface(point: Vector3): unknown
	for _, zone in zones do
		if zone.Parent ~= nil and SpatialQuery.pointInPart(zone, point) then
			return zone:GetAttribute(W.Surface)
		end
	end
	return nil
end

local function surfaceAt(entry: Entry, position: Vector3): Enums.SurfaceKind
	local hit = Workspace:Raycast(position + Vector3.new(0, 1.2, 0), Vector3.new(0, -4.2, 0), entry.rayParams)
	local partSurface: unknown = nil
	local material: Enum.Material? = nil
	if hit then
		partSurface = hit.Instance:GetAttribute(W.Surface)
		material = hit.Material
	end
	local fromMaterial = if material then CharacterAnimationController.materialSurface(material) else nil
	local zone = if partSurface == nil and fromMaterial == nil then zoneSurface(position) else nil
	return CharacterAnimationController.surfaceFor(
		inWater(position + Vector3.new(0, 0.3, 0)),
		partSurface,
		material,
		zone
	)
end

--------------------------------------------------------------------------------
-- Inputs
--------------------------------------------------------------------------------

local function targetEyes(userId: number): Vector3?
	if userId == 0 then
		return nil
	end
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return nil
	end
	if player == localPlayer then
		local camera = Workspace.CurrentCamera
		if camera then
			return camera.CFrame.Position
		end
	end
	local character = player.Character
	if not character or not character:IsDescendantOf(Workspace) then
		return nil
	end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.Position
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position + Vector3.new(0, 1.5, 0) else nil
end

local function feed(entry: Entry, animator: ProceduralAnimator.Animator, dt: number)
	local model = entry.model
	local root = entry.root
	local stateName, hunch = CreatureController.resolveState(
		model:GetAttribute(C.MonsterState),
		model:GetAttribute(C.PoseMode),
		model:GetAttribute(C.InVent)
	)
	local position = root.Position
	local last = entry.lastPosition
	entry.lastPosition = position
	local displacement = if last then position - last else Vector3.zero
	local raw = CreatureController.estimateVelocity(root.AssemblyLinearVelocity, displacement, dt)
	entry.velocity = entry.velocity:Lerp(raw, MathUtil.damp(VELOCITY_DAMP, dt))
	entry.speed = Vector3.new(entry.velocity.X, 0, entry.velocity.Z).Magnitude

	local grounded = true
	if not QUADRUPED_STATES[stateName] and stateName ~= "Swim" then
		grounded = Workspace:Raycast(
			position,
			Vector3.new(0, -(entry.groundDistance + GROUND_MARGIN), 0),
			entry.rayParams
		) ~= nil
	end

	local poseMode = Attributes.getString(model, C.PoseMode, "Biped")
	local targetId = Attributes.getNumber(model, C.TargetUserId, 0)
	local eyes = targetEyes(targetId)
	local yaw, pitch = nil, nil
	if eyes then
		yaw, pitch = CreatureController.lookAt(SpatialQuery.creatureEye(root, poseMode), eyes)
	end
	local focused = yaw ~= nil
	Creature.setFocus(animator.Map, focused)
	Creature.setHunch(animator.Map, hunch)
	animator:SetPriority(localPlayer ~= nil and targetId == localPlayer.UserId)
	animator:SetInputs({
		moveState = stateName,
		velocity = entry.velocity,
		grounded = grounded,
		lookYaw = yaw or ProceduralAnimator.yawOf(root.CFrame),
		lookPitch = pitch or 0,
		time = Workspace:GetServerTimeNow(),
	})
end

--------------------------------------------------------------------------------
-- Visibility, pupils, audio
--------------------------------------------------------------------------------

local function writeHidden(entry: Entry)
	local value = if entry.hidden then 1 else 0
	for _, part in entry.parts do
		if part.LocalTransparencyModifier ~= value then
			part.LocalTransparencyModifier = value
		end
	end
end

local function stopLoops(entry: Entry, fade: number)
	local scrape, breathing = entry.scrape, entry.breathing
	entry.scrape, entry.breathing = nil, nil
	if scrape then
		scrape:Stop(fade)
	end
	if breathing then
		breathing:Stop(fade)
	end
end

local function updateLoops(entry: Entry)
	local inVent = Attributes.getBool(entry.model, C.InVent, false)
	if not inVent or entry.hidden then
		stopLoops(entry, LOOP_FADE)
		return
	end
	local scrapeVolume, breathVolume = CreatureController.ventVolumes(entry.speed)
	local scrape, breathing = entry.scrape, entry.breathing
	if scrape and scrape:IsPlaying() then
		scrape:SetVolume(scrapeVolume, LOOP_VOLUME_FADE)
	else
		entry.scrape = AudioController.PlayLocal(
			"VentScrape",
			{ attach = entry.root :: Instance, volume = scrapeVolume, fadeIn = LOOP_FADE }
		)
	end
	if breathing and breathing:IsPlaying() then
		breathing:SetVolume(breathVolume, LOOP_VOLUME_FADE)
	else
		entry.breathing = AudioController.PlayLocal(
			"VentBreathing",
			{ attach = entry.root :: Instance, volume = breathVolume, fadeIn = LOOP_FADE }
		)
	end
end

local function updateGrowl(entry: Entry, now: number)
	if entry.hidden or not CHASE_STATES[Attributes.getString(entry.model, C.MonsterState, "")] then
		return
	end
	local slot = math.floor(now / GROWL_SLOT)
	if slot == entry.growlSlot then
		return
	end
	if entry.growlPlan ~= slot then
		entry.growlPlan = slot
		entry.growlAt = CreatureController.growlAt(slot, CREATURE_SEED)
	end
	local at = entry.growlAt
	if at == nil then
		entry.growlSlot = slot
		return
	end
	if now < at then
		return
	end
	entry.growlSlot = slot
	if now - at > 0.5 then
		return -- joined the slot too late to start the growl cleanly
	end
	local head = entry.model:FindFirstChild("Head")
	local source: Instance = if head and head:IsA("BasePart") then head else entry.root
	AudioController.PlayLocal("CreatureGrowl", {
		attach = source,
		seed = slot % 2_147_483_646 + 1,
	})
end

local function updatePupils(entry: Entry, dt: number)
	local inVent = Attributes.getBool(entry.model, C.InVent, false)
	local exposure = 0
	if not inVent then
		local poseMode = Attributes.getString(entry.model, C.PoseMode, "Biped")
		exposure = CreatureController.exposure(
			SpatialQuery.creatureEye(entry.root, poseMode),
			lightSamples(entry.root.Position)
		)
	end
	local target = CreatureController.pupilGlow(inVent, exposure)
	entry.glow = MathUtil.dampNumber(entry.glow, target, PUPIL_SPEED, dt)
	local transparency, scale = CreatureController.pupilLook(entry.glow)
	for _, pupil in entry.pupils do
		local part = pupil.part
		if part.Parent == nil then
			continue
		end
		local wanted = math.max(pupil.transparency, transparency)
		if math.abs(part.Transparency - wanted) > PUPIL_EPSILON then
			part.Transparency = wanted
			part.Size = pupil.size * scale
		end
	end
end

local function onRender(dt: number)
	local entry = current
	if not entry or entry.root.Parent == nil then
		return
	end
	local now = Workspace:GetServerTimeNow()
	updateGrowl(entry, now)
	entry.extrasClock += dt
	if entry.extrasClock < 1 / EXTRAS_HZ then
		return
	end
	local step = entry.extrasClock
	entry.extrasClock = 0
	local camera = Workspace.CurrentCamera
	local far = camera ~= nil and (camera.CFrame.Position - entry.root.Position).Magnitude > budgetFar
	updateLoops(entry)
	if not far then
		updatePupils(entry, step)
	end
end

local function onFootstep(entry: Entry, event: ProceduralAnimator.FootstepEvent)
	if entry.hidden then
		return
	end
	local surface = surfaceAt(entry, event.position)
	local speed, volume = CreatureController.footstepVoice(event.state, event.sprint, event.volume)
	AudioController.PlayLocal(SynthPresets.footstep(surface, event.sprint), {
		position = event.position,
		volume = volume,
		speed = speed,
	})
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

local function startAction(entry: Entry, name: string, startAt: number): boolean
	local map = entry.animator.Map
	if CreatureController.isDuplicate(Creature.actionStart(map, name), startAt) then
		return true
	end
	return Creature.playAction(map, name, startAt)
end

local function flushPending(entry: Entry)
	local now = Workspace:GetServerTimeNow()
	for _, item in pending do
		if now - item.startAt <= (Creature.ActionDurations[item.name] or 0) then
			startAction(entry, item.name, item.startAt)
		end
	end
	table.clear(pending)
end

--------------------------------------------------------------------------------
-- Rig
--------------------------------------------------------------------------------

local function detach()
	local pendingTrove = waiting
	if pendingTrove then
		waiting = nil
		pendingTrove:Destroy()
	end
	local entry = current
	if entry then
		current = nil
		entry.trove:Destroy()
	end
end

local attach: (model: Model) -> ()

local PUPILS: { [string]: boolean } = {
	[CreatureRigBuilder.PartNames.LeftPupil] = true,
	[CreatureRigBuilder.PartNames.RightPupil] = true,
}

local function collectParts(model: Model): ({ BasePart }, { Pupil })
	local parts: { BasePart } = {}
	local pupils: { Pupil } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
			if PUPILS[descendant.Name] then
				table.insert(
					pupils,
					{ part = descendant, size = descendant.Size, transparency = descendant.Transparency }
				)
			end
		end
	end
	return parts, pupils
end

-- What the Creature stands on: its own collision group's view of the world (Default geometry; never players,
-- corpses or the MonsterPassthrough trims, desks and lockers it walks through).
local function floorParams(model: Model): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }
	params.CollisionGroup = CollisionGroups.Monster
	params.IgnoreWater = true
	params.RespectCanCollide = true
	return params
end

-- Tries to animate `model`; false while it still lacks joints.
local function tryAttach(model: Model): boolean
	if #ProceduralAnimator.missingJoints(model, Creature.Profile) > 0 then
		return false
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return false
	end
	local animator, reason = ProceduralAnimator.new(model, Creature.Profile, { seed = CREATURE_SEED })
	if not animator then
		log.warn("cannot animate the Creature: %s", tostring(reason))
		return true
	end
	local trove = Trove.new()
	trove:Add(animator)
	local parts, pupils = collectParts(model)
	local entry: Entry = {
		model = model,
		root = root,
		animator = animator,
		trove = trove,
		parts = parts,
		pupils = pupils,
		rayParams = floorParams(model),
		groundDistance = -animator.Map.groundY,
		lastPosition = nil,
		velocity = Vector3.zero,
		speed = 0,
		hidden = Attributes.getBool(model, C.Hidden, false),
		glow = 0,
		extrasClock = 0,
		scrape = nil,
		breathing = nil,
		growlSlot = math.floor(Workspace:GetServerTimeNow() / GROWL_SLOT),
		growlPlan = -1,
		growlAt = nil,
	}
	current = entry

	animator:SetInputProvider(function(target: ProceduralAnimator.Animator, dt: number)
		if not ProceduralAnimator.JointMap.isIntact(target.Map) then
			task.defer(function()
				if current == entry then
					detach()
					if model:IsDescendantOf(Workspace) then
						attach(model)
					end
				end
			end)
			return
		end
		feed(entry, target, dt)
	end)
	animator:SetGroundProbe(function(origin: Vector3, direction: Vector3): Vector3?
		local hit = Workspace:Raycast(origin, direction, entry.rayParams)
		return if hit then hit.Position else nil
	end)
	trove:Add(animator.Footstep:Connect(function(event: ProceduralAnimator.FootstepEvent)
		onFootstep(entry, event)
	end))
	trove:Connect(model:GetAttributeChangedSignal(C.Hidden), function()
		entry.hidden = Attributes.getBool(model, C.Hidden, false)
		writeHidden(entry)
		if entry.hidden then
			stopLoops(entry, 0.1)
		end
	end)
	trove:Connect(model.DescendantAdded, function(descendant: Instance)
		if descendant:IsA("BasePart") and table.find(entry.parts, descendant) == nil then
			table.insert(entry.parts, descendant)
			descendant.LocalTransparencyModifier = if entry.hidden then 1 else 0
		end
	end)
	trove:Add(function()
		stopLoops(entry, LOOP_FADE)
		if model.Parent ~= nil then
			entry.hidden = false
			writeHidden(entry)
			for _, pupil in entry.pupils do
				pupil.part.Transparency = pupil.transparency
				pupil.part.Size = pupil.size
			end
		end
	end)
	writeHidden(entry)
	flushPending(entry)
	return true
end

function attach(model: Model)
	detach()
	if tryAttach(model) then
		return
	end
	-- Joints still replicating: retry as descendants arrive, for a while.
	local retry = Trove.new()
	waiting = retry
	local queued = false
	retry:Connect(model.DescendantAdded, function()
		if queued then
			return
		end
		queued = true
		task.defer(function()
			queued = false
			if waiting ~= retry then
				return
			end
			if not model:IsDescendantOf(Workspace) then
				detach()
				return
			end
			if tryAttach(model) then
				waiting = nil
				retry:Destroy()
			end
		end)
	end)
	retry:Delay(JOINT_WAIT_SECONDS, function()
		if waiting == retry then
			log.warn("the Creature never received its joints; it stays unanimated")
			waiting = nil
			retry:Destroy()
		end
	end)
end

local function onTagged(instance: Instance)
	if not instance:IsA("Model") or not instance:IsDescendantOf(Workspace) then
		return
	end
	local entry = current
	if entry and entry.model == instance then
		return
	end
	attach(instance)
end

local function onUntagged(instance: Instance)
	local entry = current
	if entry and entry.model == instance then
		detach()
		local other = Instances.creature()
		if other then
			attach(other)
		end
	end
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- Plays action `name` (Creature.Actions) on the Creature from server time `startAt` (default now). Late starts
-- fast-forward; replaying an action restarts it. Before the Creature exists the action waits for it. False for
-- unknown names.
function CreatureController.PlayAction(name: string, startAt: number?): boolean
	if not Creature.isAction(name) then
		log.warnThrottled("action:" .. tostring(name), 30, "no Creature action %s", tostring(name))
		return false
	end
	local at = if startAt ~= nil and MathUtil.isFinite(startAt) then startAt else Workspace:GetServerTimeNow()
	local entry = current
	if entry then
		return startAction(entry, name, at)
	end
	-- No Creature yet: keep it (dropping any waiting action that would already have finished).
	local now = Workspace:GetServerTimeNow()
	for index = #pending, 1, -1 do
		local item = pending[index]
		if item.name == name or now - item.startAt > (Creature.ActionDurations[item.name] or 0) then
			table.remove(pending, index)
		end
	end
	table.insert(pending, { name = name, startAt = at })
	return true
end

-- Ends `name` (every action when nil) on the Creature now.
function CreatureController.StopAction(name: string?)
	local entry = current
	if entry then
		Creature.stopAction(entry.animator.Map, name)
	end
	for index = #pending, 1, -1 do
		if name == nil or pending[index].name == name then
			table.remove(pending, index)
		end
	end
end

-- The Creature model being animated (nil while there is none).
function CreatureController.GetModel(): Model?
	local entry = current
	return if entry then entry.model else nil
end

-- The Animator posing the Creature (later phases read its state and part frames).
function CreatureController.GetAnimator(): ProceduralAnimator.Animator?
	local entry = current
	return if entry then entry.animator else nil
end

--------------------------------------------------------------------------------
-- Timeline track + OneShots
--------------------------------------------------------------------------------

local TRACK: Timeline.TrackHandler = {
	mode = "Events",
	fire = function(ctx: Timeline.Context, _track: Timeline.Track, key: Timeline.Key, _late: number)
		local name = key.value
		if type(name) ~= "string" then
			log.warnThrottled(
				"track:" .. ctx.id,
				30,
				"timeline %s: creature key at %.2f is not an action name",
				ctx.id,
				key.t
			)
			return
		end
		CreatureController.PlayAction(name, ctx.startAt + key.t)
	end,
}

local function subjectNear(subject: unknown): boolean
	local entry = current
	if not entry then
		return true -- queued: the Creature does not exist yet to measure from
	end
	local position: Vector3? = nil
	if typeof(subject) == "Instance" then
		local instance = subject :: Instance
		if instance:IsA("BasePart") then
			position = instance.Position
		elseif instance:IsA("Model") then
			position = instance:GetPivot().Position
		end
	end
	return position ~= nil and (position - entry.root.Position).Magnitude <= SUBJECT_REACH
end

local function onOneShot(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local kind = payload.kind
	local action = if type(kind) == "string" then ONESHOT_ACTIONS[kind] else nil
	if action == nil then
		return
	end
	if NEEDS_SUBJECT[action] and not subjectNear(payload.subject) then
		return
	end
	local startAt = if type(payload.startAt) == "number" then payload.startAt else nil
	CreatureController.PlayAction(action, startAt)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function CreatureController.Init()
	SequenceController.RegisterTrackHandler(TRACK_KIND, TRACK)
	watchParts(Tags.LevelLight, lights)
	watchParts(Tags.Zone, zones)
	watchParts(Tags.PoolWater, waters)
	serviceTrove:Add(RenderBudgetController.BudgetChanged:Connect(function(budget: RenderBudgetController.Budget)
		budgetFar = budget.animFar
	end))
end

function CreatureController.Start()
	budgetFar = RenderBudgetController.GetBudget().animFar
	local connection = Net.Client.on("OneShot", onOneShot)
	if connection then
		serviceTrove:Add(connection)
	end
	serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(Tags.Creature), onTagged)
	serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(Tags.Creature), onUntagged)
	serviceTrove:Connect(RunService.PreRender, onRender)
	serviceTrove:Add(detach)
	local existing = Instances.creature()
	if existing then
		attach(existing)
	end
end

function CreatureController.OnRunEnded()
	table.clear(pending)
end

return table.freeze(CreatureController)
