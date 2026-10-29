--!strict
-- ParachuteController: the roof jump and the ending on this client (spec, Level 5). ParachuteService judges the jump
-- (Player Parachute / ParachuteAt / ParachuteAuto, ParachuteMotion's rules); this client predicts it so every moment
-- answers at once, and shoots the finale.
--
--   * The edge. Playing on the roof, not jumped, near the jump gap: ParachuteMotion.edgeHint as the HUD hint
--     (Hud.RoofLeap with a pack on; Hud.RoofNoPack without: that fall kills).
--   * Freefall, from the frame the root leaves the roof with a pack on (ParachuteMotion.offRoof, the server's own rule):
--     the "Parachute" input context (Ripcord: Space, A or the PULL CORD touch button), the device's Hud.Ripcord.* hint,
--     the wind roaring louder with speed (WindRush) and the view buffeting. The cord fires ParachutePull and opens the
--     canopy here at once: a local LinearVelocity at ParachuteMotion.canopyVelocity, dropped as soon as the server's own
--     ParachuteDescent reaches this client (or after PREDICT_SECONDS if the server refused). The ground coming up to
--     AutoDeployClearance opens it by itself, by the server's rule (the late, harder canopy).
--   * Canopy: the right hand yanks the ripcord (HandRig "Ripcord", then "Free": both hands up on the risers),
--     CanopyDeploy and the opening jolt (ParachuteMotion.deployJolt), the canopy fluttering (CanopyFlutter). The camera
--     (camera state ParachuteLookback and a Cutscene override) turns smoothly over LOOKBACK_BLEND from where the
--     player was looking and locks back up at the ledge they jumped from (ParachuteMotion.lookback, with the canopy's
--     sway). The base look follows it, so the body, the torch, LookRelay and anyone spectating look up at the ledge
--     too. The HUD hides and the ambient storm stops: the finale owns the sky. From here until the finale's fade is black
--     (or the server's landing hold ends) the Cutscene input context holds the view, which also holds back the ESCAPED
--     summary (EscapeSummaryController waits for it).
--   * Landed, from touchdown (the server anchors the body a moment later): every descent constraint is switched off
--     locally on the same frame, ParachuteLanding (HardLanding after an auto-deploy), the knees taking it
--     (ParachuteMotion.landingDip), and the lookback held from the ground.
--   * The roof scenes' tracks (Scenes.RoofTracks): roofShake (the blows on the door shake cameras within
--     RoofDoor.ShakeRadius), roofPanic (the panic floor of players still on the roof near the door), finaleFocus (the
--     lookback tightens from the ledge onto the Creature's eyes and the view narrows to FOCUS_FOV), finalePanic and
--     finaleFade (a black screen at FADE_ORDER: over the panic vignette and the HUD's overlay, under the HUD and every
--     menu, so the ESCAPED summary draws above it). The finale's fade, focus and panic are for its jumpers (Canopy or
--     Landed) and for spectators (Dead / Spectating); "L5_Touchdown" is only for args.subject. A completed fade holds
--     black until the run ends, or lifts after BLACK_HOLD when no RunSummary came (someone is still up there): then the
--     jump is over on this client and the view (camera, HUD, hands) is the player's again.
-- Everything is released when the run ends.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local ParachuteMotion = require(ReplicatedStorage.Shared.Sequence.ParachuteMotion)
local Scenes = require(ReplicatedStorage.Shared.Sequence.Scenes)
local SoundSynthesizer = require(ReplicatedStorage.Shared.Audio.SoundSynthesizer)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Timeline = require(ReplicatedStorage.Shared.Sequence.Timeline)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local Controllers = script.Parent.Parent
local AudioController = require(Controllers.Core.AudioController)
local InputController = require(Controllers.Core.InputController)
local LightingController = require(Controllers.Core.LightingController)
local SequenceController = require(Controllers.Core.SequenceController)
local SettingsController = require(Controllers.Core.SettingsController)
local FirstPersonController = require(Controllers.FirstPerson.FirstPersonController)
local HUD = require(Controllers.HUD)
local UIKit = require(Controllers.HUD.UIKit)

local log = Log.new("Parachute")

local P = Attributes.Player
local M = Attributes.Match

type Voice = SoundSynthesizer.Voice
type Phase = "Ground" | "Freefall" | "Canopy" | "Landed"

local TOKEN = "Parachute"
local FINALE_PANIC = "RoofFinale"
local ROOF_PANIC = "RoofDoor"
local OVERRIDE: Enums.CameraOverride = "Cutscene"
local LOOKBACK_STATE: Enums.CameraState = "ParachuteLookback"
local CONTEXT: Enums.InputContext = "Parachute"
local VIEW_CONTEXT: Enums.InputContext = "Cutscene"
local VIEW_TOKEN = "ParachuteView"
local HOLD_LOCK: Enums.ControlLock = "Parachute"
local LOOKBACK_BLEND = 0.9
local OVERRIDE_BLEND_OUT = 0.6
local FOCUS_FOV = 46
local PREDICT_SECONDS = 1.5 -- a local canopy the server has not confirmed by then is dropped
local RIPCORD_SECONDS = 0.35 -- the hand stays on the handle this long after the pull
local SHAKE_EVERY = 0.15
local GROUND_REACH = 400
local WIND_SPEED_FULL = 120 -- studs/s of fall at which the wind is at full volume
local FADE_ORDER = 18
local BLACK_HOLD = 8
local FADE_OUT_SECONDS = 1.2
local DESCENT_FORCE = 2e5
local DESCENT_NAME = "ParachuteDescent"
local PREDICT_NAME = "ParachutePredict"
local AIRBORNE_SERVER: { [string]: boolean } = { Freefall = true, Canopy = true }
local WATCHING: { [string]: boolean } = { Dead = true, Spectating = true }
local PLAYING: { [string]: boolean } = { Alive = true, Downed = true }
local ROOF = Scenes.RoofDoor
local ROOF_ARGS = Scenes.RoofArgs
local ROOF_TRACKS = Scenes.RoofTracks

local ParachuteController = {}

ParachuteController.Name = "ParachuteController"

local localPlayer: Player? = Players.LocalPlayer
local serviceTrove = Trove.new()

local phase: Phase = "Ground"
local leftFrom: Vector3? = nil
local direction: Vector3? = nil
local auto = false
local deployedAt: number? = nil
local landedAt: number? = nil
local hardLanding = false
local predicted: Instance? = nil
local predictedAt = 0
local lookStart = 0
local startYaw, startPitch = 0, 0
local source: { cframe: () -> CFrame, fov: number?, blendIn: number?, blendOut: number? }? = nil
local overridden = false
local focus = 0
local focusHead: Vector3? = nil
local hint: string? = nil
local wind: Voice? = nil
local flutter: Voice? = nil
local nextShakeAt = 0
local ripcordHold = false -- falling: the right hand rides the ripcord handle
local ripcordUntil = 0 -- after the pull: it stays on it until then
local handOnCord = false
local fadeGui: ScreenGui? = nil
local fadeFrame: Frame? = nil
local fadeAlpha = 0
local fadeOutFrom: number? = nil -- os.clock() when a held fade started lifting
local fadeHeldAt: number? = nil
local summaryShown = false
local viewHeld = false -- the Cutscene input context is pushed for the finale
local heldSeen = false -- the server's landing hold (ControlLock Parachute) has reached this client
local finished = false -- this jump is over here (see finishView)
local hudHidden = false
local stormStopped = false
local panicFloors: { [string]: boolean } = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function serverState(): Enums.ParachuteState
	local player = localPlayer
	local value = if player then player:GetAttribute(P.Parachute) else nil
	return if Enums.has(Enums.ParachuteState, value) then (value :: any) :: Enums.ParachuteState else "None"
end

local function lifeState(): string
	local player = localPlayer
	return if player then Attributes.getString(player, P.LifeState, "Lobby") else "Lobby"
end

local function onRoof(): boolean
	return ReplicatedStorage:GetAttribute(M.CurrentLevel) == ParachuteMotion.LevelId
		and ReplicatedStorage:GetAttribute(M.MatchPhase) == "InRun"
end

local function motionScale(): number
	return MathUtil.clamp01(SettingsController.GetNumber("MotionScale"))
end

local function vectorArg(ctx: Timeline.Context, name: string): Vector3?
	local value = ctx.args[name]
	return if typeof(value) == "Vector3" then value :: Vector3 else nil
end

local function listener(): Vector3?
	local camera = Workspace.CurrentCamera
	return if camera then camera.CFrame.Position else nil
end

local function groundUnder(root: BasePart): number?
	local exclude: { Instance } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(exclude, character)
		end
	end
	local creature = Instances.creature()
	if creature then
		table.insert(exclude, creature)
	end
	local hit =
		Workspace:Raycast(root.CFrame.Position, Vector3.new(0, -GROUND_REACH, 0), SpatialQuery.worldParams(exclude))
	return if hit then hit.Position.Y else nil
end

local function setPanic(token: string, value: number?)
	if value == nil then
		if panicFloors[token] then
			panicFloors[token] = nil
			FirstPersonController.SetPanicFloor(token, nil)
		end
		return
	end
	panicFloors[token] = true
	FirstPersonController.SetPanicFloor(token, MathUtil.clamp01(value))
end

local function stopVoice(voice: Voice?, fade: number)
	if voice then
		voice:Stop(fade)
	end
end

--------------------------------------------------------------------------------
-- The fade
--------------------------------------------------------------------------------

local function ensureFade(): Frame?
	local frame = fadeFrame
	if frame and frame.Parent ~= nil then
		return frame
	end
	local player = localPlayer
	local playerGui = if player then player:FindFirstChildOfClass("PlayerGui") else nil
	if not playerGui then
		return nil
	end
	local gui = UIKit.screenGui("FinaleFade", FADE_ORDER, Enum.ScreenInsets.None)
	gui.IgnoreGuiInset = true
	local black = Instance.new("Frame")
	black.Name = "Black"
	black.BorderSizePixel = 0
	black.BackgroundColor3 = Color3.new(0, 0, 0)
	black.BackgroundTransparency = 1
	black.Size = UDim2.fromScale(1, 1)
	black.Parent = gui
	gui.Parent = playerGui
	fadeGui = gui
	fadeFrame = black
	return black
end

local function setFade(alpha: number)
	fadeAlpha = MathUtil.clamp01(alpha)
	local frame = if fadeAlpha > 0 then ensureFade() else fadeFrame
	if frame then
		frame.BackgroundTransparency = 1 - fadeAlpha
		local gui = fadeGui
		if gui then
			gui.Enabled = fadeAlpha > 0
		end
	end
end

local function liftFade()
	fadeHeldAt = nil
	if fadeAlpha > 0 then
		fadeOutFrom = os.clock()
	end
end

-- Whether a finale track of `ctx` is for this client: args.subject's alone when set, else the finale's jumpers and
-- spectators.
local function inFinale(ctx: Timeline.Context): boolean
	local subject = ctx.args[ROOF_ARGS.Subject]
	local player = localPlayer
	if subject ~= nil then
		return player ~= nil and subject == player.UserId
	end
	return phase == "Canopy" or phase == "Landed" or WATCHING[lifeState()] == true
end

--------------------------------------------------------------------------------
-- The lookback camera
--------------------------------------------------------------------------------

local function lookbackFrame(): CFrame
	local now = os.clock()
	local eye = FirstPersonController.GetEyeCFrame().Position
	local aim = ParachuteMotion.ledgeAim(leftFrom or eye)
	local head = focusHead
	local weight = MathUtil.smoothstep(0, 1, focus)
	local target = if head and weight > 0 then aim:Lerp(head, weight) else aim
	local targetYaw, targetPitch = MathUtil.yawPitchFromVector(target - eye)
	local blend = MathUtil.smoothstep(0, LOOKBACK_BLEND, now - lookStart)
	local yaw = startYaw + MathUtil.angleDelta(startYaw, targetYaw) * blend
	local pitch = MathUtil.lerp(startPitch, targetPitch, blend)
	FirstPersonController.SetLook(yaw, pitch)
	local scale = motionScale()
	local view = ParachuteMotion.lookback(eye, eye + MathUtil.vectorFromYawPitch(yaw, pitch), now - lookStart, scale)
	local opened = deployedAt
	if opened then
		view *= ParachuteMotion.deployJolt(now - opened, scale)
	end
	local down = landedAt
	if down then
		view *= ParachuteMotion.landingDip(now - down, hardLanding, scale)
	end
	local current = source
	if current then
		current.fov = if weight > 0
			then MathUtil.lerp(SettingsController.GetNumber("BaseFov"), FOCUS_FOV, weight)
			else nil
	end
	return view
end

local function startLookback()
	if overridden then
		return
	end
	overridden = true
	lookStart = os.clock()
	startYaw, startPitch = FirstPersonController.GetLook()
	local layer = { cframe = lookbackFrame, fov = nil, blendIn = 0.05, blendOut = OVERRIDE_BLEND_OUT }
	source = layer
	FirstPersonController.ForceCameraState(TOKEN, LOOKBACK_STATE)
	FirstPersonController.PushOverride(OVERRIDE, layer)
	if not hudHidden then
		hudHidden = true
		HUD.SetVisible(false)
	end
	if not stormStopped then
		stormStopped = true
		LightingController.SetStormEnabled(false)
	end
end

-- The finale owns the view (the Cutscene input context: no other actions, no look input; the ESCAPED summary waits).
local function holdView()
	if not viewHeld then
		viewHeld = true
		InputController.PushContext(VIEW_CONTEXT, VIEW_TOKEN)
	end
end

local function freeView()
	if viewHeld then
		viewHeld = false
		InputController.PopContext(VIEW_TOKEN)
	end
end

--------------------------------------------------------------------------------
-- The jump
--------------------------------------------------------------------------------

local function clearHint()
	if hint then
		HUD.ClearHint(hint)
		hint = nil
	end
end

local function showHint(key: string?)
	if key == hint then
		return
	end
	clearHint()
	if key then
		hint = key
		HUD.ShowHint(key, 0)
	end
end

local function dropPrediction()
	local instance = predicted
	predicted = nil
	if instance then
		instance:Destroy()
	end
end

local function predict(root: BasePart, velocity: Vector3)
	dropPrediction()
	local attachment = Instance.new("Attachment")
	attachment.Name = PREDICT_NAME
	local constraint = Instance.new("LinearVelocity")
	constraint.Name = PREDICT_NAME
	constraint.Attachment0 = attachment
	constraint.RelativeTo = Enum.ActuatorRelativeTo.World
	constraint.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	constraint.VectorVelocity = velocity
	constraint.ForceLimitsEnabled = true
	constraint.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	constraint.MaxForce = DESCENT_FORCE
	constraint.Parent = attachment
	attachment.Parent = root
	predicted = attachment
	predictedAt = os.clock()
end

local function ripcordTarget(): CFrame?
	local player = localPlayer
	local character = if player then player.Character else nil
	local pack = if character then character:FindFirstChild("ParachuteBackpack") else nil
	local handle = if pack then pack:FindFirstChild("RipcordHandle") else nil
	local attachment = if handle then handle:FindFirstChild("Ripcord") else nil
	if attachment and attachment:IsA("Attachment") then
		return attachment.WorldCFrame
	end
	local torso = if character then character:FindFirstChild("UpperTorso") else nil
	if torso and torso:IsA("BasePart") then
		return torso.CFrame * CFrame.new(0.5, -0.3, -0.7)
	end
	return nil
end

local function enterFreefall(position: Vector3)
	phase = "Freefall"
	leftFrom = position
	direction = ParachuteMotion.outward(position)
	clearHint()
	InputController.PushContext(CONTEXT, TOKEN)
	local key = "Hud.Ripcord." .. InputController.GetDevice()
	hint = key
	HUD.ShowHint(key, 0)
	stopVoice(wind, 0)
	wind = AudioController.PlayLocal("WindRush", { looped = true, fadeIn = 0.25, volume = 0.5 })
	nextShakeAt = 0
	ripcordHold = true
end

-- The canopy opens on this client (`pulled`: by the cord, which tells the server; else by itself or the server).
local function enterCanopy(root: BasePart?, opensAuto: boolean, pulled: boolean)
	if phase == "Canopy" or phase == "Landed" then
		return
	end
	local from = leftFrom
	if from == nil and root then
		from = root.CFrame.Position
		leftFrom = from
	end
	if direction == nil then
		direction = ParachuteMotion.outward(from or Vector3.zero)
	end
	phase = "Canopy"
	auto = opensAuto
	deployedAt = os.clock()
	if pulled then
		Net.Client.fire("ParachutePull", {})
	end
	if root and root:FindFirstChild(DESCENT_NAME) == nil then
		predict(root, ParachuteMotion.canopyVelocity(direction or Vector3.zero, opensAuto))
	end
	InputController.PopContext(TOKEN)
	clearHint()
	stopVoice(wind, 0.6)
	wind = nil
	AudioController.PlayLocal("CanopyDeploy", { volume = 1 })
	stopVoice(flutter, 0)
	flutter = AudioController.PlayLocal("CanopyFlutter", { looped = true, fadeIn = 1.2, volume = 0.8 })
	ripcordHold = false
	ripcordUntil = os.clock() + RIPCORD_SECONDS
	FirstPersonController.Shake(2.2, 0.5)
	startLookback()
	holdView()
end

local function switchOffDescent(root: BasePart?)
	dropPrediction()
	if not root then
		return
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("LinearVelocity") then
			descendant.Enabled = false
		end
	end
end

local function enterLanded(root: BasePart?, hard: boolean)
	if phase == "Landed" then
		return
	end
	if phase ~= "Canopy" then
		startLookback()
	end
	holdView()
	phase = "Landed"
	landedAt = os.clock()
	hardLanding = hard
	switchOffDescent(root)
	InputController.PopContext(TOKEN)
	clearHint()
	stopVoice(wind, 0.3)
	wind = nil
	stopVoice(flutter, 1.5)
	flutter = nil
	AudioController.PlayLocal(if hard then "HardLanding" else "ParachuteLanding", { volume = 1 })
	FirstPersonController.SetHandPose("Free", nil)
	FirstPersonController.Shake(if hard then 3 else 1.2, if hard then 0.6 else 0.35)
end

-- Gives the view back: the camera, the HUD, the sky, the hands, the panic floors.
local function restoreView()
	freeView()
	ripcordHold, ripcordUntil = false, 0
	if handOnCord then
		handOnCord = false
		FirstPersonController.SetHandPose("Flashlight", nil)
	end
	dropPrediction()
	InputController.PopContext(TOKEN)
	clearHint()
	stopVoice(wind, 0.3)
	stopVoice(flutter, 0.6)
	wind, flutter = nil, nil
	if overridden then
		overridden = false
		source = nil
		FirstPersonController.PopOverride(OVERRIDE)
		FirstPersonController.ForceCameraState(TOKEN, nil)
		FirstPersonController.SetHandPose("Flashlight", nil)
	end
	if hudHidden then
		hudHidden = false
		HUD.SetVisible(true)
	end
	if stormStopped then
		stormStopped = false
		LightingController.SetStormEnabled(true)
	end
	for token in table.clone(panicFloors) do
		setPanic(token, nil)
	end
end

-- Back to the ground state (the run ended, the jump was reset, this player died).
local function release()
	phase = "Ground"
	leftFrom, direction, deployedAt, landedAt = nil, nil, nil, nil
	auto, hardLanding = false, false
	focus, focusHead = 0, nil
	finished, heldSeen = false, false
	restoreView()
end

-- This jump is over on this client (escaped; the finale has played and the run goes on for someone still up there):
-- the view goes back to the player, and nothing re-enters the jump until the run ends.
local function finishView()
	finished = true
	restoreView()
end

local function pull()
	if phase ~= "Freefall" then
		return
	end
	local root = Instances.characterRoot(localPlayer :: Player)
	if lifeState() ~= "Alive" then
		return
	end
	enterCanopy(root, false, true)
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function stepFreefall(root: BasePart, now: number)
	local fall = math.max(0, -root.AssemblyLinearVelocity.Y)
	local loud = MathUtil.clamp01(fall / WIND_SPEED_FULL)
	local voice = wind
	if voice then
		voice:SetVolume(0.35 + 0.85 * loud, 0.1)
	end
	if now >= nextShakeAt then
		nextShakeAt = now + SHAKE_EVERY
		FirstPersonController.Shake(0.3 + 1.3 * loud, SHAKE_EVERY * 2)
	end
	local ground = groundUnder(root)
	if ground and ParachuteMotion.autoDeployDue(root.CFrame.Position.Y, ground) then
		enterCanopy(root, true, false)
	end
end

local function stepCanopy(root: BasePart)
	local server = serverState()
	if predicted and (root:FindFirstChild(DESCENT_NAME) ~= nil or os.clock() - predictedAt > PREDICT_SECONDS) then
		if server ~= "Canopy" and root:FindFirstChild(DESCENT_NAME) == nil then
			log.debug("the server did not open the canopy; dropping the prediction")
		end
		dropPrediction()
	end
	local humanoid = Instances.characterHumanoid(localPlayer :: Player)
	local touched = humanoid ~= nil and humanoid.FloorMaterial ~= Enum.Material.Air
	if not touched then
		local ground = groundUnder(root)
		local height = if humanoid then humanoid.HipHeight + root.Size.Y / 2 else nil
		touched = ground ~= nil and ParachuteMotion.landed(root.CFrame.Position.Y, ground, height)
	end
	if touched and os.clock() - (deployedAt or 0) > 0.2 then
		enterLanded(root, auto)
	end
end

local function stepFade(now: number)
	local held = fadeHeldAt
	if held and not summaryShown and now - held >= BLACK_HOLD then
		-- no summary: the run goes on for someone still up there, and the view is this player's again
		liftFade()
		if phase == "Landed" then
			finishView()
		end
	end
	local lifting = fadeOutFrom
	if lifting then
		local u = MathUtil.clamp01((now - lifting) / FADE_OUT_SECONDS)
		setFade(fadeAlpha * (1 - u))
		if u >= 1 or fadeAlpha <= 0.001 then
			fadeOutFrom = nil
			setFade(0)
		end
	end
end

-- The right hand on the ripcord handle while falling and through the pull (the body moves fast: re-aimed every frame),
-- then up on the risers.
local function stepHand(now: number)
	local wanted = ripcordHold or now < ripcordUntil
	if wanted then
		local target = ripcordTarget()
		if target then
			FirstPersonController.SetHandPose("Ripcord", target)
			handOnCord = true
		end
	elseif handOnCord then
		handOnCord = false
		FirstPersonController.SetHandPose(if phase == "Ground" then "Flashlight" else "Free", nil)
	end
end

local function frame()
	local now = os.clock()
	stepFade(now)
	stepHand(now)
	local player = localPlayer
	if not player then
		return
	end
	local server = serverState()
	local root = Instances.characterRoot(player)
	if phase ~= "Ground" and server == "None" and WATCHING[lifeState()] then
		release()
		return
	end
	if finished then
		return
	end
	if phase == "Landed" then
		-- the server's hold ends when the finale has played for this player: the view is theirs, the summary may show
		local held = Attributes.getString(player, P.ControlLock, "None") == HOLD_LOCK
		if held then
			heldSeen = true
		elseif heldSeen then
			freeView()
			if fadeAlpha < 0.5 then
				finishView()
			end
		end
		return
	end
	if phase == "Ground" then
		if server == "Landed" then
			enterLanded(root, player:GetAttribute(P.ParachuteAuto) == true)
		elseif server == "Canopy" then
			enterCanopy(root, player:GetAttribute(P.ParachuteAuto) == true, false)
		elseif root and onRoof() and PLAYING[lifeState()] then
			local position = root.CFrame.Position
			local packed = server == "Packed" or AIRBORNE_SERVER[server] == true
			if packed and ParachuteMotion.offRoof(position) then
				enterFreefall(position)
			elseif lifeState() == "Alive" then
				showHint(ParachuteMotion.edgeHint(position, packed))
			else
				showHint(nil)
			end
		else
			showHint(nil)
		end
		return
	end
	if phase == "Freefall" then
		if server == "Canopy" then
			enterCanopy(root, player:GetAttribute(P.ParachuteAuto) == true, false)
		elseif server == "Landed" then
			enterLanded(root, true)
		elseif root then
			stepFreefall(root, now)
		end
	elseif phase == "Canopy" then
		if server == "Landed" then
			enterLanded(root, auto)
		elseif root then
			stepCanopy(root)
		end
	end
end

--------------------------------------------------------------------------------
-- Track handlers
--------------------------------------------------------------------------------

local SHAKE: Timeline.TrackHandler = {
	mode = "Events",
	fire = function(ctx: Timeline.Context, track: Timeline.Track, key: Timeline.Key, late: number)
		local amplitude = key.value
		local door = vectorArg(ctx, track.arg or ROOF_ARGS.Door)
		local here = listener()
		if type(amplitude) ~= "number" or not (door and here) or late > Timeline.LateTolerance then
			return
		end
		local distance = (here - door).Magnitude
		if distance > ROOF.ShakeRadius then
			return
		end
		local falloff = 1 - distance / ROOF.ShakeRadius
		FirstPersonController.Shake(amplitude * (0.35 + 0.65 * falloff) * motionScale(), 0.45)
	end,
}

local PANIC: Timeline.TrackHandler = {
	mode = "Continuous",
	apply = function(ctx: Timeline.Context, track: Timeline.Track, value: Timeline.Value)
		local door = vectorArg(ctx, track.arg or ROOF_ARGS.Door)
		local here = listener()
		local near = door ~= nil and here ~= nil and (here - door).Magnitude <= ROOF.PanicRadius
		if type(value) ~= "number" or phase ~= "Ground" or not near then
			setPanic(ROOF_PANIC, nil)
			return
		end
		setPanic(ROOF_PANIC, value)
	end,
	stop = function(_ctx: Timeline.Context, _track: Timeline.Track, _completed: boolean)
		setPanic(ROOF_PANIC, nil)
	end,
}

local FOCUS: Timeline.TrackHandler = {
	mode = "Continuous",
	apply = function(ctx: Timeline.Context, _track: Timeline.Track, value: Timeline.Value)
		if type(value) ~= "number" then
			return
		end
		focus = MathUtil.clamp01(value)
		focusHead = vectorArg(ctx, ROOF_ARGS.Head)
	end,
	stop = function(_ctx: Timeline.Context, _track: Timeline.Track, _completed: boolean)
		focus = 0
	end,
}

local FINALE_PANIC_TRACK: Timeline.TrackHandler = {
	mode = "Continuous",
	apply = function(ctx: Timeline.Context, _track: Timeline.Track, value: Timeline.Value)
		if type(value) ~= "number" or not inFinale(ctx) then
			setPanic(FINALE_PANIC, nil)
			return
		end
		setPanic(FINALE_PANIC, value)
	end,
	stop = function(_ctx: Timeline.Context, _track: Timeline.Track, _completed: boolean)
		setPanic(FINALE_PANIC, nil)
	end,
}

local FADE: Timeline.TrackHandler = {
	mode = "Continuous",
	apply = function(ctx: Timeline.Context, _track: Timeline.Track, value: Timeline.Value)
		if type(value) ~= "number" or not inFinale(ctx) then
			return
		end
		fadeOutFrom = nil
		setFade(value)
	end,
	stop = function(ctx: Timeline.Context, _track: Timeline.Track, completed: boolean)
		if not inFinale(ctx) then
			return
		end
		if completed and fadeAlpha >= 0.99 then
			-- black: the finale is over for this player and the ESCAPED summary may take the screen
			fadeHeldAt = os.clock()
			freeView()
		else
			liftFade()
		end
	end,
}

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function ParachuteController.Init()
	SequenceController.RegisterTrackHandler(ROOF_TRACKS.Shake, SHAKE)
	SequenceController.RegisterTrackHandler(ROOF_TRACKS.Panic, PANIC)
	SequenceController.RegisterTrackHandler(ROOF_TRACKS.Focus, FOCUS)
	SequenceController.RegisterTrackHandler(ROOF_TRACKS.FinalePanic, FINALE_PANIC_TRACK)
	SequenceController.RegisterTrackHandler(ROOF_TRACKS.Fade, FADE)
	serviceTrove:Add(InputController.Action("Ripcord"):Connect(function(inputPhase: InputController.Phase)
		if inputPhase == "Begin" then
			pull()
		end
	end))
end

function ParachuteController.Start()
	serviceTrove:Connect(RunService.PreRender, function()
		xpcall(frame, function(err: any)
			log.warnThrottled("frame", 10, "parachute frame failed: %s\n%s", tostring(err), debug.traceback())
		end)
	end)
	local connection = Net.Client.on("RunSummary", function(_payload: any)
		summaryShown = true
	end)
	if connection then
		serviceTrove:Add(connection)
	end
end

function ParachuteController.OnRunStarted(_info: Types.RunInfo)
	release()
	summaryShown = false
	fadeHeldAt = nil
	fadeOutFrom = nil
	setFade(0)
end

function ParachuteController.OnRunEnded()
	release()
	summaryShown = false
	liftFade()
end

return table.freeze(ParachuteController)
