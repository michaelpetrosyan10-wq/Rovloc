--!strict
-- DoorController: renders every fixture door's motion on this client. DoorService (server) decides and steps the
-- anchored leaves for collision; this controller poses the same leaves every PreRender from the server's OneShot
-- (kinds "Door", "GateSlam" and "DoorSmash", args per Shared/Sequence/DoorMotion) on server time, so doors move
-- smoothly instead of at the replication rate and end on exactly the pose the server's replication settles on.
--   * startAt is honoured: the leaves hold their start pose until then; a message that arrives late renders from
--     the right point of its motion, and one that arrives after its motion ended (a long stall) snaps to the end
--     pose. A client that joins later never saw the message and simply has the server's replicated pose.
--   * Per door, a message older than the newest one played (motionId) is dropped; a newer one replaces the running
--     motion.
--   * Held (the server stopped a swing short of a player): the leaves ease from wherever this client has them to the
--     held pose in HOLD_BLEND seconds and stay there until the server resumes (the next message).
--   * Impacts shake the camera of the local player, falling off with distance, at the moment they land: the gate
--     slamming down (GateSlam, within SLAM_RADIUS), a door being smashed (DoorSmash, within SMASH_RADIUS) and a fire
--     door latching shut (within LATCH_RADIUS). A newer message for the door cancels a pending impact.
-- The run ending drops every motion (the doors are rebuilt with the next run).
--
-- Pure (tests/Specs/Doors.spec.luau): accept, renderMotion, impactFor, impactShake. Apply / Render drive the same
-- path the OneShot handler and the PreRender step use, so specs pose a real built door with them.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local DoorMotion = require(ReplicatedStorage.Shared.Sequence.DoorMotion)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local Controllers = script.Parent.Parent
local FirstPersonController = require(Controllers.FirstPerson.FirstPersonController)

local log = Log.new("DoorClient")

local W = Attributes.World

type Motion = DoorMotion.Motion
type Message = DoorMotion.Message

export type ImpactKind = "Slam" | "Smash" | "Latch"

export type Impact = { kind: ImpactKind, at: number } -- server time it lands

type Playing = {
	model: Model,
	motion: Motion,
}

local DOOR_KINDS: { [string]: boolean } = { Door = true, GateSlam = true, DoorSmash = true }

local HOLD_BLEND = 0.15 -- seconds the leaves take to settle on a held pose
local SMASH_IMPACT_DELAY = 0.12 -- the blow lands just after the smash starts
local IMPACT_LATE = 0.3 -- an impact this long past is not felt any more
local MAX_LEAD = 2 -- seconds an impact may be scheduled ahead (clock skew guard)
local DEFAULT_HEIGHT = 10

local IMPACTS: { [ImpactKind]: { radius: number, amplitude: number, seconds: number } } = {
	Slam = { radius = 30, amplitude = 2.4, seconds = 0.7 },
	Smash = { radius = 34, amplitude = 3.2, seconds = 0.8 },
	Latch = { radius = 12, amplitude = 0.8, seconds = 0.35 },
}

local DoorController = {}

DoorController.Name = "DoorController"
DoorController.HoldBlend = HOLD_BLEND
DoorController.Impacts = table.freeze(table.clone(IMPACTS))

local serviceTrove = Trove.new()
local playing: { [Model]: Playing } = {}
local lastMotion: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local lastValue: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local pendingImpacts: { [Model]: thread } = {}

--------------------------------------------------------------------------------
-- Pure maths (specs: tests/Specs/Doors.spec.luau)
--------------------------------------------------------------------------------

-- Whether a message with `motionId` should play over the newest one played for that door.
function DoorController.accept(lastId: number?, motionId: number): boolean
	return lastId == nil or motionId > lastId
end

-- The motion this client renders for `message`: the server's motion, or for a hold a short settle from what this
-- client shows now (`current`, nil when it shows nothing moving) to the held pose, starting at `now`.
function DoorController.renderMotion(message: Message, current: number?, now: number): Motion
	local motion = message.motion
	if not message.held then
		return motion
	end
	local from = if current ~= nil then current else motion.to
	return {
		mode = "Swing",
		from = from,
		to = motion.to,
		startAt = now,
		seconds = if math.abs(from - motion.to) > 1e-4 then HOLD_BLEND else 0,
		ease = "InOut",
		smashFrom = 0,
	}
end

-- The impact a message's motion lands with (nil for none): the gate's slam, a smash, a fire door latching shut.
function DoorController.impactFor(oneShotKind: string, doorKind: string, message: Message): Impact?
	if message.held then
		return nil
	end
	local motion = message.motion
	if oneShotKind == "DoorSmash" and motion.seconds > 0 then
		return { kind = "Smash", at = motion.startAt + SMASH_IMPACT_DELAY }
	end
	local shuts = motion.mode == "Swing" and motion.to <= 1e-4 and motion.from > 1e-4 and motion.seconds > 0
	if not shuts then
		return nil
	end
	if oneShotKind == "GateSlam" or doorKind == "Gate" then
		return { kind = "Slam", at = DoorMotion.endsAt(motion) }
	end
	if doorKind == "Airlock" then
		return { kind = "Latch", at = DoorMotion.endsAt(motion) }
	end
	return nil
end

-- Camera shake (degrees, seconds) of an impact `distance` studs away: quadratic falloff to nothing at its radius.
function DoorController.impactShake(kind: ImpactKind, distance: number): (number, number)
	local spec = IMPACTS[kind]
	if not spec or not MathUtil.isFinite(distance) or distance >= spec.radius then
		return 0, 0
	end
	local falloff = 1 - math.max(0, distance) / spec.radius
	return spec.amplitude * falloff * falloff, spec.seconds
end

--------------------------------------------------------------------------------
-- Doors
--------------------------------------------------------------------------------

local function isDoor(instance: Instance?, doorId: string): boolean
	return instance ~= nil and instance:IsA("Model") and instance:GetAttribute(W.DoorId) == doorId
end

-- The door a message is about: its subject, else the tagged door with that DoorId on that level.
local function resolveDoor(subject: unknown, message: Message): Model?
	if typeof(subject) == "Instance" and isDoor(subject :: Instance, message.doorId) then
		return subject :: Model
	end
	for _, tag in { Tags.AirlockDoor, Tags.ScriptedDoor } do
		for _, instance in CollectionService:GetTagged(tag) do
			if isDoor(instance, message.doorId) and instance:GetAttribute(W.LevelId) == message.levelId then
				return instance :: Model
			end
		end
	end
	return nil
end

local function centreOf(model: Model): Vector3
	local height = Attributes.getNumber(model, W.DoorHeight, DEFAULT_HEIGHT)
	return (model.WorldPivot * CFrame.new(0, height * 0.5, 0)).Position
end

local function cancelImpact(model: Model)
	local thread = pendingImpacts[model]
	pendingImpacts[model] = nil
	if thread and coroutine.status(thread) == "suspended" then
		task.cancel(thread)
	end
end

local function scheduleImpact(model: Model, impact: Impact, now: number)
	local wait = impact.at - now
	if wait < -IMPACT_LATE or wait > MAX_LEAD then
		return
	end
	pendingImpacts[model] = task.delay(math.max(0, wait), function()
		pendingImpacts[model] = nil
		if model.Parent == nil then
			return
		end
		local eye = FirstPersonController.GetEyeCFrame().Position
		local amplitude, seconds = DoorController.impactShake(impact.kind, (eye - centreOf(model)).Magnitude)
		if amplitude > 0 then
			FirstPersonController.Shake(amplitude, seconds)
		end
	end)
end

local function render(model: Model, entry: Playing, now: number): boolean
	local motion = entry.motion
	local value, done = DoorMotion.valueAt(motion, now)
	DoorMotion.pose(model, motion.mode, value, motion.smashFrom)
	if motion.mode == "Swing" then
		lastValue[model] = value
	else
		lastValue[model] = nil
	end
	return done
end

-- Plays `message` (from a OneShot of `oneShotKind`) on `model` at server time `now`. False when it is older than
-- what the door already played.
function DoorController.Apply(model: Model, message: Message, oneShotKind: string, now: number): boolean
	if not DoorController.accept(lastMotion[model], message.motionId) then
		return false
	end
	lastMotion[model] = message.motionId
	cancelImpact(model)
	local entry: Playing = { model = model, motion = DoorController.renderMotion(message, lastValue[model], now) }
	playing[model] = entry
	-- render at once: a late message snaps, and the leaves are on the motion before the next frame
	if render(model, entry, now) then
		playing[model] = nil
	end
	local impact = DoorController.impactFor(oneShotKind, Attributes.getString(model, W.DoorKind, ""), message)
	if impact then
		scheduleImpact(model, impact, now)
	end
	return true
end

-- One frame of every playing door at server time `now` (the PreRender step).
function DoorController.Render(now: number)
	for model, entry in playing do
		if model.Parent == nil then
			playing[model] = nil
			continue
		end
		if render(model, entry, now) then
			playing[model] = nil
		end
	end
end

-- Whether `model` still has a motion to render.
function DoorController.IsPlaying(model: Model): boolean
	return playing[model] ~= nil
end

local function onOneShot(payload: any)
	if type(payload) ~= "table" or not DOOR_KINDS[payload.kind] then
		return
	end
	local args = payload.args
	local startAt = payload.startAt
	if type(args) ~= "table" or type(startAt) ~= "number" then
		return
	end
	local message = DoorMotion.fromArgs(args, startAt)
	if not message then
		log.warnThrottled("malformed", 10, "malformed %s OneShot dropped", tostring(payload.kind))
		return
	end
	local model = resolveDoor(payload.subject, message)
	if not model then
		return
	end
	DoorController.Apply(model, message, payload.kind, Workspace:GetServerTimeNow())
end

local function clear()
	for model in table.clone(pendingImpacts) do
		cancelImpact(model)
	end
	table.clear(playing)
	table.clear(lastMotion)
	table.clear(lastValue)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function DoorController.Init()
	serviceTrove:Add(clear)
end

function DoorController.Start()
	local connection = Net.Client.on("OneShot", onOneShot)
	if connection then
		serviceTrove:Add(connection)
	end
	serviceTrove:Connect(RunService.PreRender, function()
		if next(playing) ~= nil then
			DoorController.Render(Workspace:GetServerTimeNow())
		end
	end)
end

function DoorController.OnRunStarted(_info: Types.RunInfo)
	clear()
end

function DoorController.OnRunEnded()
	clear()
end

-- Kinds this controller renders (the server's DoorService announces exactly these).
DoorController.OneShotKinds = table.freeze({ "Door", "GateSlam", "DoorSmash" } :: { Enums.OneShotKind })

return table.freeze(DoorController)
