--!strict
-- LevelScenesController: plays the level scenes (Shared/Sequence/Scenes) on this client. Init registers every scene
-- timeline with SequenceController (the server starts them with OneShot "Timeline") and the track kinds they use
-- beyond the built-in "sound" / "light" and CreatureController's "creature":
--
--   sceneCamera  (events, subject only) "Flinch": FirstPersonController.PushOverride("Cutscene") with the stumble
--                (Scenes.Flinch, scaled by the MotionScale setting) applied over the player's own eye, and, when the
--                server says they can see the Creature (args.focus), their view dragged onto its eyes from the snap
--                (Scenes.PullWeight) and held there. "Release" (persistent, so a late start still ends) hands the
--                held look back (SetLook to where the camera was looking, so nothing swings) and pops the override.
--   scenePanic   (continuous, subject only) the subject's panic floor (heartbeat, breathing, grade); cleared at the end.
--   nearSound    (events) a 2D preset for listeners within Scenes.ClassroomScare.HushRadius of the track's `arg` point
--                (the hush: the ambience ducks away under one heartbeat).
--   movingSound  (continuous 0..1) the track's `target` preset riding a client-local Attachment from args.from to
--                args.to (something dragging away across the ceiling); faded out and removed at the end.
--   lightScale   (continuous) the light in the `arg` arg at that factor of its BaseBrightness
--                (LightingController.SetOverride), released at the end.
-- Everything a scene holds (override, panic floor, voices, light overrides) is released when its timeline ends or is
-- stopped, and when the run ends.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Scenes = require(ReplicatedStorage.Shared.Sequence.Scenes)
local SoundSynthesizer = require(ReplicatedStorage.Shared.Audio.SoundSynthesizer)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Timeline = require(ReplicatedStorage.Shared.Sequence.Timeline)

local Controllers = script.Parent.Parent
local AudioController = require(Controllers.Core.AudioController)
local LightingController = require(Controllers.Core.LightingController)
local SequenceController = require(Controllers.Core.SequenceController)
local SettingsController = require(Controllers.Core.SettingsController)
local FirstPersonController = require(Controllers.FirstPerson.FirstPersonController)

local log = Log.new("LevelScenes")

local W = Attributes.World

type Voice = SoundSynthesizer.Voice

type CameraSession = {
	id: string,
	startAt: number,
	focus: boolean,
	head: Vector3?,
	scale: number,
	lastView: CFrame?,
}

type Mover = { attachment: Attachment, voice: Voice? }

type LightHold = { lightId: string, base: number }

local OVERRIDE: Enums.CameraOverride = "Cutscene"
local PANIC_TOKEN = "LevelScene"
local BLEND_IN = 0.03
local BLEND_OUT = 0.2
local MOVER_FADE_IN = 0.4
local MOVER_FADE_OUT = 0.8
local ARGS = Scenes.Args
local TRACKS = Scenes.Tracks

local LevelScenesController = {}

LevelScenesController.Name = "LevelScenesController"

local localPlayer: Player? = Players.LocalPlayer
local camera: CameraSession? = nil
local panicHeld = false
local movers: { [Timeline.Track]: Mover } = {}
local lightHolds: { [Timeline.Track]: LightHold } = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function isSubject(ctx: Timeline.Context): boolean
	local player = localPlayer
	return player ~= nil and ctx.args[ARGS.Subject] == player.UserId
end

local function vectorArg(ctx: Timeline.Context, name: string?): Vector3?
	local value = if name then ctx.args[name] else nil
	return if typeof(value) == "Vector3" then value :: Vector3 else nil
end

local function stringArg(ctx: Timeline.Context, name: string?): string?
	local value = if name then ctx.args[name] else nil
	return if type(value) == "string" then value else nil
end

local function listenerPosition(): Vector3?
	local current = Workspace.CurrentCamera
	return if current then current.CFrame.Position else nil
end

local function fixtureBase(lightId: string): number?
	for _, instance in CollectionService:GetTagged(Tags.LevelLight) do
		if instance.Name == lightId then
			return math.max(0, Attributes.getNumber(instance, W.BaseBrightness, 0))
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- sceneCamera
--------------------------------------------------------------------------------

local function cameraFrame(session: CameraSession): CFrame
	local t = serverNow() - session.startAt
	local eye = FirstPersonController.GetEyeCFrame()
	local view = eye
	local head = session.head
	if session.focus and head then
		view = Scenes.Pulled(eye, head, Scenes.PullWeight(t))
	end
	session.lastView = view
	return view * Scenes.Flinch(t, session.scale)
end

-- Ends the subject's camera scene (only `id`'s when given): the look it was holding becomes the player's look.
local function endCamera(id: string?)
	local session = camera
	if not session or (id ~= nil and session.id ~= id) then
		return
	end
	camera = nil
	local view = session.lastView
	if session.focus and view then
		local yaw, pitch = MathUtil.yawPitchFromVector(view.LookVector)
		FirstPersonController.SetLook(yaw, pitch)
	end
	FirstPersonController.PopOverride(OVERRIDE)
end

local function startCamera(ctx: Timeline.Context)
	endCamera(nil)
	local session: CameraSession = {
		id = ctx.id,
		startAt = ctx.startAt,
		focus = ctx.args[ARGS.Focus] == true,
		head = vectorArg(ctx, ARGS.Head),
		scale = MathUtil.clamp01(SettingsController.GetNumber("MotionScale")),
		lastView = nil,
	}
	camera = session
	FirstPersonController.PushOverride(OVERRIDE, {
		cframe = function(): CFrame
			return cameraFrame(session)
		end,
		blendIn = BLEND_IN,
		blendOut = BLEND_OUT,
	})
end

local CAMERA: Timeline.TrackHandler = {
	mode = "Events",
	fire = function(ctx: Timeline.Context, _track: Timeline.Track, key: Timeline.Key, _late: number)
		if not isSubject(ctx) then
			return
		end
		if key.value == "Flinch" then
			startCamera(ctx)
		elseif key.value == "Release" then
			endCamera(ctx.id)
		end
	end,
	stop = function(ctx: Timeline.Context, _track: Timeline.Track, _completed: boolean)
		endCamera(ctx.id)
	end,
}

--------------------------------------------------------------------------------
-- scenePanic
--------------------------------------------------------------------------------

local PANIC: Timeline.TrackHandler = {
	mode = "Continuous",
	apply = function(ctx: Timeline.Context, _track: Timeline.Track, value: Timeline.Value)
		if type(value) ~= "number" or not isSubject(ctx) then
			return
		end
		panicHeld = true
		FirstPersonController.SetPanicFloor(PANIC_TOKEN, MathUtil.clamp01(value))
	end,
	stop = function(ctx: Timeline.Context, _track: Timeline.Track, _completed: boolean)
		if panicHeld and isSubject(ctx) then
			panicHeld = false
			FirstPersonController.SetPanicFloor(PANIC_TOKEN, nil)
		end
	end,
}

--------------------------------------------------------------------------------
-- nearSound
--------------------------------------------------------------------------------

local NEAR_SOUND: Timeline.TrackHandler = {
	mode = "Events",
	fire = function(ctx: Timeline.Context, track: Timeline.Track, key: Timeline.Key, late: number)
		local preset = key.value
		local source = vectorArg(ctx, track.arg)
		local listener = listenerPosition()
		if type(preset) ~= "string" or not SynthPresets.has(preset) or not (source and listener) then
			return
		end
		if (listener - source).Magnitude > Scenes.ClassroomScare.HushRadius then
			return
		end
		AudioController.PlayLocal(preset, {
			volume = track.volume,
			startOffset = if late > Timeline.LateTolerance then late else nil,
		})
	end,
}

--------------------------------------------------------------------------------
-- movingSound
--------------------------------------------------------------------------------

local function dropMover(track: Timeline.Track)
	local mover = movers[track]
	if not mover then
		return
	end
	movers[track] = nil
	local voice = mover.voice
	if voice then
		voice:Stop(MOVER_FADE_OUT)
	end
	local attachment = mover.attachment
	task.delay(MOVER_FADE_OUT + 0.2, function()
		attachment:Destroy()
	end)
end

local MOVING_SOUND: Timeline.TrackHandler = {
	mode = "Continuous",
	apply = function(ctx: Timeline.Context, track: Timeline.Track, value: Timeline.Value)
		local from, to = vectorArg(ctx, ARGS.From), vectorArg(ctx, ARGS.To)
		local preset = track.target
		if type(value) ~= "number" or not (from and to and preset) then
			return
		end
		local mover = movers[track]
		if not mover then
			if not SynthPresets.has(preset) then
				log.warnThrottled("moving:" .. preset, 30, "%s: unknown moving sound preset %s", ctx.id, preset)
				return
			end
			local attachment = Instance.new("Attachment")
			attachment.Name = "SceneSound"
			attachment.Parent = Workspace.Terrain
			attachment.WorldPosition = from
			local voice = AudioController.PlayLocal(preset, {
				attach = attachment :: Instance,
				volume = track.volume,
				fadeIn = MOVER_FADE_IN,
				looped = true,
			})
			mover = { attachment = attachment, voice = voice }
			movers[track] = mover
		end
		mover.attachment.WorldPosition = from:Lerp(to, MathUtil.clamp01(value))
	end,
	stop = function(_ctx: Timeline.Context, track: Timeline.Track, _completed: boolean)
		dropMover(track)
	end,
}

--------------------------------------------------------------------------------
-- lightScale
--------------------------------------------------------------------------------

local LIGHT_SCALE: Timeline.TrackHandler = {
	mode = "Continuous",
	apply = function(ctx: Timeline.Context, track: Timeline.Track, value: Timeline.Value)
		if type(value) ~= "number" then
			return
		end
		local hold = lightHolds[track]
		if not hold then
			local lightId = stringArg(ctx, track.arg)
			local base = if lightId then fixtureBase(lightId) else nil
			if not (lightId and base and base > 0) then
				return
			end
			hold = { lightId = lightId, base = base }
			lightHolds[track] = hold
		end
		local held = hold :: LightHold
		LightingController.SetOverride(held.lightId, held.base * math.max(0, value))
	end,
	stop = function(_ctx: Timeline.Context, track: Timeline.Track, _completed: boolean)
		local hold = lightHolds[track]
		if hold then
			lightHolds[track] = nil
			LightingController.SetOverride(hold.lightId, nil)
		end
	end,
}

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function releaseAll()
	endCamera(nil)
	if panicHeld then
		panicHeld = false
		FirstPersonController.SetPanicFloor(PANIC_TOKEN, nil)
	end
	for track in table.clone(movers) do
		dropMover(track)
	end
	for track, hold in table.clone(lightHolds) do
		lightHolds[track] = nil
		LightingController.SetOverride(hold.lightId, nil)
	end
end

function LevelScenesController.Init()
	SequenceController.RegisterTrackHandler(TRACKS.SubjectCamera, CAMERA)
	SequenceController.RegisterTrackHandler(TRACKS.SubjectPanic, PANIC)
	SequenceController.RegisterTrackHandler(TRACKS.NearSound, NEAR_SOUND)
	SequenceController.RegisterTrackHandler(TRACKS.MovingSound, MOVING_SOUND)
	SequenceController.RegisterTrackHandler(TRACKS.LightScale, LIGHT_SCALE)
	for id, spec in Scenes.timelines() do
		SequenceController.RegisterTimeline(id, spec)
	end
end

function LevelScenesController.OnRunEnded()
	releaseAll()
end

return table.freeze(LevelScenesController)
