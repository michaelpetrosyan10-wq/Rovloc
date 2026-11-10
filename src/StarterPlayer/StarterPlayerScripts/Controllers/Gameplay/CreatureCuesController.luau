--!strict
-- CreatureCuesController: the Creature's moments for this player alone (docs/MONSTER.md 11; the website's
-- web/src/creature/sounds.js and view.js). Outputs only: the server decides every one of them.
--
--   * PrivateCue "Scare" (args.scare, Enums.ScareKind):
--       Reveal, Fakeout  the reveal scare (no catch): a phantom of its head, mask and tatters snaps into view
--                        PhantomAhead studs in front of the camera for PhantomSeconds (in 0.05, out 0.09), cocked over
--                        and glitching, lit cold from one side; the torch stutters on it; a 5.5 degree camera jolt;
--                        RevealSting for a teleport's reveal, FakeoutShriek inside a fake-out hiding spot.
--       Stare            StareSting: it caught you looking.
--       GiveUp           GiveUpSwell; the chase music fades out.
--       TorchStutter     the torch stutters for args.seconds (the teleport's warning), with its crackle.
--       HideWarn         the hiding spot's knock at 35 s (HideWarn).
--       HideKick         shoved out at 45 s, or pulled out by a teammate (HideKick).
--   * The chase music, from the replicated attributes: while it chases this player (MonsterState WallChase,
--     TargetUserId me) the ChasePulse loop faded in over 0.4 s with the ChaseSting at its start; a 1.4 s fade-out when
--     it ends.
--   * The rattle: while it stalks (Patrol, Teleport, Search, HidingResponse, InvestigateNoise) within RattleRadius (22)
--     of this player's eye, unhidden, CreatureRattle at its eye every U(4.5, 8) s.
--
-- Pure (tests/Specs/CreatureCues.spec.luau): chased, stalking, rattleGap, phantomWeight.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local SoundSynthesizer = require(ReplicatedStorage.Shared.Audio.SoundSynthesizer)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local Controllers = script.Parent.Parent
local AudioController = require(Controllers.Core.AudioController)
local FirstPersonController = require(Controllers.FirstPerson.FirstPersonController)

local log = Log.new("CreatureCues")

local C = Attributes.Creature

local CHASE_FADE_IN = 0.4
local CHASE_FADE_OUT = 1.4
local RATTLE_MIN = 4.5
local RATTLE_MAX = 8
local RATTLE_RADIUS = CreatureConfig.Senses.RattleRadius
local REVEAL_JOLT = 5.5 -- degrees
local REVEAL_JOLT_SECONDS = 0.35
local TORCH_REVEAL = 0.36 -- the torch stutters on the phantom this long
local PHANTOM_AHEAD = 3.4
local PHANTOM_SECONDS = 0.36
local PHANTOM_IN = 0.05
local PHANTOM_OUT = 0.09
local PHANTOM_COCK = math.rad(26)
local PHANTOM_LIGHT = Color3.fromRGB(196, 214, 255)

local STALKING: { [string]: boolean } = {
	Patrol = true,
	Teleport = true,
	Search = true,
	HidingResponse = true,
	InvestigateNoise = true,
}

local SCARE_SOUNDS: { [string]: string } = {
	Reveal = "RevealSting",
	Fakeout = "FakeoutShriek",
	Stare = "StareSting",
	GiveUp = "GiveUpSwell",
	TorchStutter = "TorchStutter",
	HideWarn = "HideWarn",
	HideKick = "HideKick",
}

local CreatureCuesController = {}

CreatureCuesController.Name = "CreatureCuesController"
CreatureCuesController.PhantomSeconds = PHANTOM_SECONDS
CreatureCuesController.PhantomAhead = PHANTOM_AHEAD

local serviceTrove = Trove.new()
local runTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local chaseVoice: SoundSynthesizer.Voice? = nil
local wasChased = false
local nextRattleAt = math.huge
local rattleRandom = Random.new()

--------------------------------------------------------------------------------
-- Pure rules
--------------------------------------------------------------------------------

-- Whether the Creature in `state` with `targetUserId` chases the player `userId`.
function CreatureCuesController.chased(state: string, targetUserId: number, userId: number?): boolean
	return state == "WallChase" and userId ~= nil and targetUserId == userId
end

-- Whether a state is the stalk (the rattle's states).
function CreatureCuesController.stalking(state: string): boolean
	return STALKING[state] == true
end

-- Seconds to the next rattle for a uniform `roll` in [0, 1).
function CreatureCuesController.rattleGap(roll: number): number
	return RATTLE_MIN + (RATTLE_MAX - RATTLE_MIN) * MathUtil.clamp01(roll)
end

-- How visible the phantom is `elapsed` seconds into the reveal (0..1): in over 0.05, out over the last 0.09.
function CreatureCuesController.phantomWeight(elapsed: number): number
	if not (elapsed >= 0 and elapsed <= PHANTOM_SECONDS) then
		return 0
	end
	local fadeIn = MathUtil.clamp01(elapsed / PHANTOM_IN)
	local fadeOut = MathUtil.clamp01((PHANTOM_SECONDS - elapsed) / PHANTOM_OUT)
	return math.min(fadeIn, fadeOut)
end

--------------------------------------------------------------------------------
-- The reveal's phantom
--------------------------------------------------------------------------------

-- The Head and every part welded to it (the mask, its detail, the crown), cloned and anchored, kept as offsets.
local function phantomParts(model: Model): ({ { part: BasePart, offset: CFrame } }, Folder?)
	local head = model:FindFirstChild("Head")
	if not (head and head:IsA("BasePart")) then
		return {}, nil
	end
	local folder = Instance.new("Folder")
	folder.Name = "CreaturePhantom"
	local out: { { part: BasePart, offset: CFrame } } = {}
	local function add(part: BasePart)
		local copy = part:Clone()
		for _, child in copy:GetChildren() do
			if child:IsA("JointInstance") or child:IsA("WeldConstraint") or child:IsA("Constraint") then
				child:Destroy()
			end
		end
		copy.Anchored = true
		copy.CanCollide = false
		copy.CanQuery = false
		copy.CanTouch = false
		copy.CastShadow = false
		copy.Parent = folder
		table.insert(out, { part = copy, offset = head.CFrame:ToObjectSpace(part.CFrame) })
	end
	add(head)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("WeldConstraint") then
			local a, b = descendant.Part0, descendant.Part1
			local other = if a == head then b elseif b == head then a else nil
			if other and other ~= head then
				add(other)
			end
		end
	end
	return out, folder
end

local function revealPhantom(startAt: number)
	local model = Instances.creature()
	local camera = Workspace.CurrentCamera
	if not (model and camera) then
		return
	end
	local parts, folder = phantomParts(model)
	if not folder or #parts == 0 then
		return
	end
	local face = model:FindFirstChild("FaceFrontAttachment", true)
	local headPart = model:FindFirstChild("Head")
	local faceInHead = if face
			and face:IsA("Attachment")
			and headPart
			and face.Parent == headPart
		then face.CFrame
		else CFrame.new(0, 0, -0.6)
	local light = Instance.new("PointLight")
	light.Color = PHANTOM_LIGHT
	light.Range = 8
	light.Brightness = 0
	light.Shadows = false
	light.Parent = parts[1].part
	folder.Parent = camera
	local trove = Trove.new()
	runTrove:Add(trove)
	trove:Add(folder)
	local seed = rattleRandom:NextNumber() * 100
	trove:Connect(RunService.RenderStepped, function()
		local elapsed = Workspace:GetServerTimeNow() - startAt
		if elapsed > PHANTOM_SECONDS then
			trove:Destroy()
			return
		end
		local weight = CreatureCuesController.phantomWeight(elapsed)
		local view = camera.CFrame
		local glitch = (math.noise(elapsed * 40, seed) * 2) * (1 - elapsed / PHANTOM_SECONDS)
		-- the face toward the camera, cocked over, half in shadow
		local facePose = view
			* CFrame.new(0, -0.15, -PHANTOM_AHEAD)
			* CFrame.Angles(0, math.pi, 0)
			* CFrame.Angles(0, 0, PHANTOM_COCK + math.rad(8) * glitch)
		local headCFrame = facePose * faceInHead:Inverse()
		for _, entry in parts do
			entry.part.CFrame = headCFrame * entry.offset
			entry.part.LocalTransparencyModifier = 1 - weight
		end
		light.Brightness = 3 * weight
	end)
	FirstPersonController.Shake(REVEAL_JOLT, REVEAL_JOLT_SECONDS)
	FirstPersonController.StutterTorch(TORCH_REVEAL)
end

--------------------------------------------------------------------------------
-- Cues
--------------------------------------------------------------------------------

local function onScare(args: { [string]: any }, startAt: number)
	local kind = args.scare
	if type(kind) ~= "string" then
		return
	end
	local sound = SCARE_SOUNDS[kind]
	if sound then
		AudioController.PlayLocal(sound, { startOffset = math.max(0, Workspace:GetServerTimeNow() - startAt) })
	end
	if kind == "Reveal" or kind == "Fakeout" then
		revealPhantom(startAt)
	elseif kind == "TorchStutter" then
		local seconds = args.seconds
		FirstPersonController.StutterTorch(
			if type(seconds) == "number" then seconds else CreatureConfig.Teleport.WarningSeconds
		)
	elseif kind == "GiveUp" then
		local voice = chaseVoice
		chaseVoice = nil
		if voice then
			voice:Stop(CHASE_FADE_OUT)
		end
	end
end

local function onPrivateCue(payload: any)
	if type(payload) ~= "table" or payload.kind ~= "Scare" then
		return
	end
	local args = payload.args
	local startAt = payload.startAt
	if type(args) ~= "table" then
		return
	end
	onScare(args, if type(startAt) == "number" then startAt else Workspace:GetServerTimeNow())
end

--------------------------------------------------------------------------------
-- The chase music and the rattle
--------------------------------------------------------------------------------

local function stopChase(fade: number)
	local voice = chaseVoice
	chaseVoice = nil
	if voice then
		voice:Stop(fade)
	end
end

local function step()
	local model = Instances.creature()
	local root = Instances.creatureRoot()
	local userId = if localPlayer then localPlayer.UserId else nil
	local state = if model then Attributes.getString(model, C.MonsterState, "Dormant") else "Dormant"
	local target = if model then Attributes.getNumber(model, C.TargetUserId, 0) else 0
	local chased = CreatureCuesController.chased(state, target, userId)
	if chased and not wasChased then
		AudioController.PlayLocal("ChaseSting")
		stopChase(0)
		chaseVoice = AudioController.PlayLocal("ChasePulse", { fadeIn = CHASE_FADE_IN, looped = true })
	elseif wasChased and not chased then
		stopChase(CHASE_FADE_OUT)
	end
	wasChased = chased

	local now = os.clock()
	if
		not (model and root)
		or not CreatureCuesController.stalking(state)
		or Attributes.getBool(model, C.Hidden, false)
	then
		nextRattleAt = math.huge
		return
	end
	local camera = Workspace.CurrentCamera
	local eye = SpatialQuery.creatureEye(root, Attributes.getString(model, C.PoseMode, "Biped"))
	local near = camera ~= nil and (camera.CFrame.Position - eye).Magnitude <= RATTLE_RADIUS
	if not near then
		nextRattleAt = math.huge
		return
	end
	if nextRattleAt == math.huge then
		nextRattleAt = now + CreatureCuesController.rattleGap(rattleRandom:NextNumber()) * 0.5
	elseif now >= nextRattleAt then
		nextRattleAt = now + CreatureCuesController.rattleGap(rattleRandom:NextNumber())
		AudioController.PlayLocal("CreatureRattle", { position = eye })
	end
end

local function clear()
	runTrove:Clean()
	stopChase(0)
	wasChased = false
	nextRattleAt = math.huge
end

function CreatureCuesController.Init()
	serviceTrove:Add(clear)
end

function CreatureCuesController.Start()
	local cues = Net.Client.on("PrivateCue", onPrivateCue)
	if cues then
		serviceTrove:Add(cues)
	end
	serviceTrove:Connect(RunService.Heartbeat, function()
		xpcall(step, function(err: any)
			log.warnThrottled("step", 10, "cue step failed: %s", tostring(err))
		end)
	end)
end

function CreatureCuesController.OnRunStarted(_info: Types.RunInfo)
	clear()
end

function CreatureCuesController.OnRunEnded()
	clear()
end

return CreatureCuesController
