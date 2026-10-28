--!strict
-- DoorService: the run's fixture doors (DoorBuilder kind "Doors": the stairwell airlock fire doors, the Level 1
-- hallway gate and ajar classroom door, the roof stairwell door). The only writer of DoorState and, after the build,
-- of every fixture door leaf pose.
--
-- Index. Fixtures are rebuilt every run into Workspace.Runtime.<level> by WorldService.BeginRun, just before this
-- service's BeginRun, which scans every AirlockDoor / ScriptedDoor model there (tag signals catch any built later).
-- Each door is found by its ScriptedId (HallwayGate, ClassroomDoor, RoofStairDoor) or its DoorId, per level.
-- Initial states: airlock doors Open (built open), the gate Open (rolled up), the ClassroomDoor Open at its built
-- ajar pose, the RoofStairDoor Closed (snapped shut silently).
--
-- States (SetState; `plan` is the table): Open = the fully open pose; Closed and Locked = the shut pose, and Locked
-- additionally refuses RequestOpen (the gameplay path: a prompt or a mechanic asking for a door), while scripts may
-- still SetState it open; Smashed = DoorBuilder.setSmashed, and nothing changes a smashed door again. Closed <-> Locked
-- moves nothing. Re-entering the current state, an unknown door or a smashed door returns false.
--
-- Motion. `seconds` is the motion time (default per kind and direction, scaled by how far the door has to travel;
-- 0 snaps, silently). Server-authoritative: the motion starts GameConfig.OneShotLead from now, and the server poses
-- the anchored leaves every Heartbeat along it (DoorMotion, on server time), so collision follows the door and the
-- server's final pose lands at the end. A OneShot announces it to every client (kind GateSlam for the gate coming
-- down, DoorSmash for a smash, otherwise "Door"; args per DoorMotion), and DoorController renders the same motion
-- every PreRender, so it looks smooth.
--
-- Never crushing. Before every swing step the leaves' boxes over the next LOOKAHEAD seconds of travel (a pose at least
-- every SAMPLE_STEP of openness, BLOCK_MARGIN wider) are tested against every living player character: a body box
-- built from the root (characterBox, separating-axis test, so it works in every collision group: vent, locked,
-- normal) and the engine's view of the real limbs (Workspace:GetPartBoundsInBox with OverlapParams including only the
-- characters). A leaf that would touch someone stops short where it is: a "held" OneShot parks the clients' leaves
-- there and the landing sound is cancelled. A held door tests the whole rest of its travel, and once that has been
-- clear for CLEAR_SECONDS it finishes at the pace it had (a new OneShot), so it never creeps back onto the same
-- player. Opening and closing both stop; a smash does not.
--
-- Sounds (AudioService, SynthPresets) at the opening's centre: a fire door swings with FireDoorSwing and lands with
-- FireDoorLatch; the classroom and roof doors swing with DoorCreak and shut with a softer FireDoorLatch; the gate
-- rises with MetalCreak and comes down with GateSlam at the moment it lands; a smash plays DoorSmash. Landing cues are
-- scheduled for the end of the motion and stopped when a hold or a new motion interrupts it. The gate and the fire
-- doors slamming shut also emit the DoorSlam noise (NoiseAndDirectorService) on their level when they land.
--
-- Dev commands: door <id> <open|close|lock|smash> [seconds] (a door on your level by ScriptedId or DoorId) and doors
-- (read-only: every door on your level).
--
-- Pure rules (tests/Specs/Doors.spec.luau): plan, defaultSeconds, easeFor, oneShotKind, characterBox, boxesOverlap,
-- localBounds, sweepValues. SetClock swaps the time source and StepMotions runs one Heartbeat step, so specs drive a
-- motion on a fake clock.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local DoorMotion = require(ReplicatedStorage.Shared.Sequence.DoorMotion)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local DoorBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.DoorBuilder)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)

local AudioService = require(ServerScriptService.Services.Core.AudioService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)

local log = Log.new("Doors")

local P = Attributes.Player
local M = Attributes.Match
local W = Attributes.World

export type Clock = { now: () -> number }

export type Plan = "Refuse" | "StateOnly" | "Swing" | "Smash"

export type Travel = { open: number, close: number }

type Mode = DoorMotion.Mode
type Motion = DoorMotion.Motion

type LeafBox = {
	name: string,
	rest: CFrame, -- the leaf's rest pivot (the door's Base never moves)
	center: CFrame, -- its colliding parts' box, relative to the leaf pivot
	size: Vector3,
}

type Body = { cframe: CFrame, size: Vector3 }

type Door = {
	model: Model,
	id: string,
	scriptedId: string?,
	kind: Enums.DoorKind,
	levelId: Enums.LevelId?,
	fromLevel: Enums.LevelId?,
	toLevel: Enums.LevelId?,
	height: number,
	state: Enums.DoorState,
	openness: number, -- where the leaves stand now (0 shut .. 1 fully open)
	smash: number, -- smash progress once smashed
	smashFrom: number, -- the openness a smash tore the leaves from
	motion: Motion?, -- in flight, stepped every Heartbeat
	held: boolean, -- a swing stopped short of a player, waiting for a clear doorway
	target: number, -- the swing's destination (kept while held)
	speed: number, -- openness per second of the swing (a resumed swing keeps its pace)
	clearSince: number?, -- while held: when the doorway was last seen clear
	recheckAt: number, -- while held: when to test the doorway again
	motionId: number,
	leaves: { LeafBox },
	landing: AudioService.CueHandle?,
}

local FIXTURE_KINDS: { [string]: boolean } = { Ajar = true, Gate = true, Airlock = true, RoofDoor = true }
local INITIAL_STATES: { [string]: Enums.DoorState } = {
	Airlock = "Open",
	Gate = "Open",
	Ajar = "Open",
	RoofDoor = "Closed",
}
-- Seconds for a full travel (shut <-> fully open) per kind; shorter travels take proportionally less.
local TRAVEL: { [string]: Travel } = {
	Airlock = { open = 1.6, close = 1.6 },
	Gate = { open = 2.8, close = 0.35 },
	Ajar = { open = 1.2, close = 0.9 },
	RoofDoor = { open = 1.2, close = 0.9 },
}
local FALLBACK_TRAVEL: Travel = { open = 1.2, close = 1.2 }
local SLAM_KINDS: { [string]: boolean } = { Gate = true, Airlock = true }
local DOOR_STATES: { [string]: Enums.DoorState } = {
	open = "Open",
	close = "Closed",
	closed = "Closed",
	lock = "Locked",
	locked = "Locked",
	smash = "Smashed",
	smashed = "Smashed",
}

local DOOR_ONESHOT: Enums.OneShotKind = "Door"
local SLAM_ONESHOT: Enums.OneShotKind = "GateSlam"
local SMASH_ONESHOT: Enums.OneShotKind = "DoorSmash"
local SLAM_NOISE: Enums.NoiseKind = "DoorSlam"
local FIRE_SWING_PRESET = "FireDoorSwing"
local LATCH_PRESET = "FireDoorLatch"
local CREAK_PRESET = "DoorCreak"
local GATE_RISE_PRESET = "MetalCreak"
local GATE_SLAM_PRESET = "GateSlam"
local SMASH_PRESET = "DoorSmash"
local LIGHT_LATCH_VOLUME = 0.55

local SMASH_SECONDS = 0.7
local MIN_SECONDS = 0.12 -- the shortest default motion (a door that is nearly where it is going)
local LOOKAHEAD = 0.25 -- seconds of travel tested ahead of the leaves
local SWEEP_SAMPLES = 4 -- at least this many poses are tested across a stretch (plus its start)
local SAMPLE_STEP = 0.05 -- and at least one every this much openness
local BLOCK_MARGIN = 0.2 -- studs added around each leaf's box
local CLEAR_SECONDS = 0.3 -- a held door waits this long after the doorway clears
local HELD_RECHECK = 1 / GameConfig.ServerTickHz -- a held door tests its doorway at the server tick rate
local BODY_WIDTH = 3.2 -- a standing R15 body with its arms in, plus slack
local BODY_DEPTH = 1.6
local BODY_HEAD_ROOM = 2.5 -- from the root's top to the top of the head
local EPSILON = 1e-4
local DEFAULT_HEIGHT = 10
local LIVE_PHASES: { [string]: boolean } = { Deploying = true, InRun = true }

local DoorService = {}

DoorService.Name = "DoorService"
DoorService.Lookahead = LOOKAHEAD
DoorService.ClearSeconds = CLEAR_SECONDS
DoorService.BlockMargin = BLOCK_MARGIN
DoorService.SmashSeconds = SMASH_SECONDS
DoorService.InitialStates = table.freeze(table.clone(INITIAL_STATES))
DoorService.Travel = table.freeze(table.clone(TRAVEL))

local stateChanged: Signal.Signal<Model, Enums.DoorState, Enums.DoorState> = Signal.new()

-- (door, previous, next) after a door's DoorState changed (its motion has been started).
DoorService.StateChanged = stateChanged

local realClock: Clock = {
	now = function(): number
		return Workspace:GetServerTimeNow()
	end,
}

local clock: Clock = realClock
local serviceTrove = Trove.new()
local doors: { [Model]: Door } = {}
local moving: { [Door]: boolean } = {}
local participants: { [Player]: boolean } = {}
local running = false
local live = false
local oneShotSeq = 0
local initialized = false

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/Doors.spec.luau)
--------------------------------------------------------------------------------

-- What SetState(current -> nextState) does: refuse it, change the state only (Closed <-> Locked share the shut pose),
-- swing to the returned openness, or smash.
function DoorService.plan(current: Enums.DoorState, nextState: Enums.DoorState): (Plan, number?)
	if current == "Smashed" or current == nextState then
		return "Refuse", nil
	end
	if nextState == "Smashed" then
		return "Smash", nil
	end
	if nextState == "Open" then
		return "Swing", 1
	end
	if current == "Closed" or current == "Locked" then
		return "StateOnly", nil
	end
	return "Swing", 0
end

-- The default motion time for a door of `kind` going from `from` to `to` (openness; a smash ignores both).
function DoorService.defaultSeconds(kind: Enums.DoorKind, mode: Mode, from: number, to: number): number
	if mode == "Smash" then
		return SMASH_SECONDS
	end
	local travel = TRAVEL[kind] or FALLBACK_TRAVEL
	local full = if to > from then travel.open else travel.close
	return math.max(MIN_SECONDS, full * math.abs(to - from))
end

-- The ease of a motion: a grille drops under its own weight (In), a smash is shaped by its pose (Linear), every
-- swing eases in and out (a door closer, a door opening).
function DoorService.easeFor(kind: Enums.DoorKind, mode: Mode, closing: boolean): DoorMotion.Ease
	if mode == "Smash" then
		return "Linear"
	end
	if kind == "Gate" and closing then
		return "In"
	end
	return "InOut"
end

-- The OneShot kind that announces a motion.
function DoorService.oneShotKind(kind: Enums.DoorKind, mode: Mode, closing: boolean): Enums.OneShotKind
	if mode == "Smash" then
		return SMASH_ONESHOT
	end
	if kind == "Gate" and closing then
		return SLAM_ONESHOT
	end
	return DOOR_ONESHOT
end

-- An upright box around a standing character, from its root (feet to the top of the head, arms in), turned to the
-- root's heading.
function DoorService.characterBox(rootCFrame: CFrame, rootSize: Vector3, hipHeight: number): (CFrame, Vector3)
	local feet = -(math.max(hipHeight, 0) + rootSize.Y * 0.5)
	local top = rootSize.Y * 0.5 + BODY_HEAD_ROOM
	local look = rootCFrame.LookVector
	local yaw = if math.abs(look.X) + math.abs(look.Z) > 1e-4 then math.atan2(-look.X, -look.Z) else 0
	local cframe = CFrame.new(rootCFrame.Position) * CFrame.Angles(0, yaw, 0) * CFrame.new(0, (feet + top) * 0.5, 0)
	return cframe, Vector3.new(BODY_WIDTH, top - feet, BODY_DEPTH)
end

local function projectedRadius(half: Vector3, x: Vector3, y: Vector3, z: Vector3, axis: Vector3): number
	return half.X * math.abs(x:Dot(axis)) + half.Y * math.abs(y:Dot(axis)) + half.Z * math.abs(z:Dot(axis))
end

-- Whether two oriented boxes intersect (separating-axis test over the 15 candidate axes).
function DoorService.boxesOverlap(a: CFrame, aSize: Vector3, b: CFrame, bSize: Vector3): boolean
	local ha, hb = aSize * 0.5, bSize * 0.5
	local ax, ay, az = a.RightVector, a.UpVector, a.LookVector
	local bx, by, bz = b.RightVector, b.UpVector, b.LookVector
	local offset = b.Position - a.Position
	local axes: { Vector3 } = {
		ax,
		ay,
		az,
		bx,
		by,
		bz,
		ax:Cross(bx),
		ax:Cross(by),
		ax:Cross(bz),
		ay:Cross(bx),
		ay:Cross(by),
		ay:Cross(bz),
		az:Cross(bx),
		az:Cross(by),
		az:Cross(bz),
	}
	for _, axis in axes do
		local length = axis.Magnitude
		if length < 1e-6 then
			continue -- parallel edges: covered by the face axes
		end
		local unit = axis / length
		local distance = math.abs(offset:Dot(unit))
		if distance > projectedRadius(ha, ax, ay, az, unit) + projectedRadius(hb, bx, by, bz, unit) then
			return false
		end
	end
	return true
end

-- The box (centre relative to `pivot`, and size) around `parts`; nil when there are none.
function DoorService.localBounds(pivot: CFrame, parts: { BasePart }): (CFrame?, Vector3?)
	if #parts == 0 then
		return nil, nil
	end
	local lowX, lowY, lowZ = math.huge, math.huge, math.huge
	local highX, highY, highZ = -math.huge, -math.huge, -math.huge
	for _, part in parts do
		local half = part.Size * 0.5
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local world = part.CFrame:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))
					local corner = pivot:PointToObjectSpace(world)
					lowX, lowY, lowZ = math.min(lowX, corner.X), math.min(lowY, corner.Y), math.min(lowZ, corner.Z)
					highX, highY, highZ =
						math.max(highX, corner.X), math.max(highY, corner.Y), math.max(highZ, corner.Z)
				end
			end
		end
	end
	local low = Vector3.new(lowX, lowY, lowZ)
	local high = Vector3.new(highX, highY, highZ)
	return CFrame.new((low + high) * 0.5), high - low
end

-- `samples` + 1 evenly spaced values from `from` to `to` (both included).
function DoorService.sweepValues(from: number, to: number, samples: number): { number }
	local count = math.max(1, math.floor(samples))
	local out: { number } = {}
	for i = 0, count do
		table.insert(out, from + (to - from) * i / count)
	end
	return out
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function levelAttribute(model: Model, key: string): Enums.LevelId?
	local value = model:GetAttribute(key)
	if type(value) == "string" and Enums.has(Enums.LevelId, value) then
		return (value :: any) :: Enums.LevelId
	end
	return nil
end

-- The level `player` stands on: ZoneService's LevelId, else the run's current level.
local function playerLevel(player: Player): Enums.LevelId?
	for _, value in { player:GetAttribute(P.LevelId), ReplicatedStorage:GetAttribute(M.CurrentLevel) } do
		if type(value) == "string" and Enums.has(Enums.LevelId, value) then
			return (value :: any) :: Enums.LevelId
		end
	end
	return nil
end

-- The middle of the doorway (cues and noise come from here).
local function centreOf(door: Door): Vector3
	return (door.model.WorldPivot * CFrame.new(0, door.height * 0.5, 0)).Position
end

-- A leaf's colliding parts (all of its parts when none collide).
local function leafParts(leaf: Model): { BasePart }
	local colliding: { BasePart } = {}
	local all: { BasePart } = {}
	for _, descendant in leaf:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(all, descendant)
			if descendant.CanCollide then
				table.insert(colliding, descendant)
			end
		end
	end
	return if #colliding > 0 then colliding else all
end

local function leafBoxes(model: Model): { LeafBox }
	local out: { LeafBox } = {}
	for _, name in DoorBuilder.leafNames(model) do
		local leaf = model:FindFirstChild(name)
		local rest = PropKit.leafRest(model, name)
		if not (leaf and leaf:IsA("Model") and rest) then
			continue
		end
		local center, size = DoorService.localBounds(leaf.WorldPivot, leafParts(leaf))
		if center and size then
			table.insert(out, { name = name, rest = rest, center = center, size = size })
		end
	end
	return out
end

local function inRuntime(instance: Instance): boolean
	local runtime = Instances.runtime()
	return runtime ~= nil and instance:IsDescendantOf(runtime)
end

local function sortedById(list: { Door }): { Model }
	table.sort(list, function(a: Door, b: Door): boolean
		return a.id < b.id
	end)
	local out: { Model } = {}
	for _, door in list do
		table.insert(out, door.model)
	end
	return out
end

--------------------------------------------------------------------------------
-- Blocking
--------------------------------------------------------------------------------

-- Every living player character that could stand in a doorway: run participants and everyone in the server.
local function bodies(): ({ Body }, { Instance })
	local boxes: { Body } = {}
	local characters: { Instance } = {}
	local seen: { [Player]: boolean } = {}
	local function add(player: Player)
		if seen[player] then
			return
		end
		seen[player] = true
		local character = player.Character
		local root = Instances.characterRoot(player)
		local humanoid = Instances.characterHumanoid(player)
		if not (character and root and humanoid and humanoid.Health > 0) then
			return
		end
		local cframe, size = DoorService.characterBox(root.CFrame, root.Size, humanoid.HipHeight)
		table.insert(boxes, { cframe = cframe, size = size })
		table.insert(characters, character)
	end
	for player in participants do
		add(player)
	end
	for _, player in Players:GetPlayers() do
		add(player)
	end
	return boxes, characters
end

local function leafWorld(door: Door, leaf: LeafBox, openness: number): CFrame?
	local transform = DoorBuilder.openTransform(door.model, leaf.name, openness)
	if not transform then
		return nil
	end
	return leaf.rest * transform * leaf.center
end

local function padded(size: Vector3): Vector3
	return size + Vector3.new(2 * BLOCK_MARGIN, 2 * BLOCK_MARGIN, 2 * BLOCK_MARGIN)
end

-- Whether moving the leaves from openness `from` to `to` would touch a player.
local function obstructed(door: Door, from: number, to: number): boolean
	if #door.leaves == 0 then
		return false
	end
	local boxes, characters = bodies()
	if #boxes == 0 then
		return false
	end
	local samples = math.max(SWEEP_SAMPLES, math.ceil(math.abs(to - from) / SAMPLE_STEP))
	for _, value in DoorService.sweepValues(from, to, samples) do
		for _, leaf in door.leaves do
			local world = leafWorld(door, leaf, value)
			if not world then
				continue
			end
			local size = padded(leaf.size)
			for _, body in boxes do
				if DoorService.boxesOverlap(world, size, body.cframe, body.size) then
					return true
				end
			end
		end
	end
	-- the engine's view of the real limbs, half way along and at the far end of the stretch
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = characters
	params.RespectCanCollide = false
	for _, value in { (from + to) * 0.5, to } do
		for _, leaf in door.leaves do
			local world = leafWorld(door, leaf, value)
			if world and #Workspace:GetPartBoundsInBox(world, padded(leaf.size), params) > 0 then
				return true
			end
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Moments
--------------------------------------------------------------------------------

local function announce(door: Door, kind: Enums.OneShotKind, motion: Motion, held: boolean)
	door.motionId += 1
	oneShotSeq += 1
	local event: Types.OneShotEvent = {
		seq = oneShotSeq,
		kind = kind,
		subject = door.model,
		startAt = motion.startAt,
		args = DoorMotion.toArgs({
			doorId = door.id,
			levelId = door.levelId or "",
			motionId = door.motionId,
			state = door.state,
			held = held,
			motion = motion,
		}),
	}
	Net.Server.fireAll("OneShot", event)
end

local function stopLanding(door: Door)
	local landing = door.landing
	door.landing = nil
	if landing then
		landing:Stop(0)
	end
end

-- The cues of a motion that starts now (`resumed`: a held swing setting off again).
local function playCues(door: Door, motion: Motion, resumed: boolean)
	local at = centreOf(door)
	if motion.mode == "Smash" then
		AudioService.PlayAt(SMASH_PRESET, at)
		return
	end
	local closing = motion.to < motion.from
	local shuts = closing and motion.to <= EPSILON
	if door.kind == "Gate" then
		if shuts then
			door.landing = AudioService.PlayAt(GATE_SLAM_PRESET, at, { delay = motion.seconds })
		elseif not closing and not resumed then
			AudioService.PlayAt(GATE_RISE_PRESET, at)
		end
		return
	end
	local fire = door.kind == "Airlock"
	AudioService.PlayAt(if fire then FIRE_SWING_PRESET else CREAK_PRESET, at)
	if shuts then
		door.landing = AudioService.PlayAt(
			LATCH_PRESET,
			at,
			{ delay = motion.seconds, volume = if fire then 1 else LIGHT_LATCH_VOLUME }
		)
	end
end

--------------------------------------------------------------------------------
-- Motions
--------------------------------------------------------------------------------

local function poseDoor(door: Door, mode: Mode, value: number)
	DoorMotion.pose(door.model, mode, value, door.smashFrom)
	if mode == "Swing" then
		door.openness = value
	else
		door.smash = value
	end
end

local function cancelMotion(door: Door)
	door.motion = nil
	door.held = false
	door.clearSince = nil
	moving[door] = nil
	stopLanding(door)
end

local function begin(door: Door, motion: Motion, kind: Enums.OneShotKind, resumed: boolean)
	door.motion = motion
	door.held = false
	door.clearSince = nil
	moving[door] = true
	announce(door, kind, motion, false)
	playCues(door, motion, resumed)
end

local function swing(door: Door, target: number, seconds: number?)
	cancelMotion(door)
	local now = clock.now()
	local from = door.openness
	local duration = seconds or DoorService.defaultSeconds(door.kind, "Swing", from, target)
	local closing = target < from
	door.target = target
	if duration <= 0 or math.abs(target - from) <= EPSILON then
		poseDoor(door, "Swing", target)
		announce(door, DOOR_ONESHOT, {
			mode = "Swing",
			from = target,
			to = target,
			startAt = now,
			seconds = 0,
			ease = "Linear",
			smashFrom = 0,
		}, false)
		return
	end
	door.speed = math.abs(target - from) / duration
	begin(door, {
		mode = "Swing",
		from = from,
		to = target,
		startAt = now + GameConfig.OneShotLead,
		seconds = duration,
		ease = DoorService.easeFor(door.kind, "Swing", closing),
		smashFrom = 0,
	}, DoorService.oneShotKind(door.kind, "Swing", closing), false)
end

local function smash(door: Door, seconds: number?)
	cancelMotion(door)
	local now = clock.now()
	door.smashFrom = door.openness
	local duration = seconds or SMASH_SECONDS
	if duration <= 0 then
		poseDoor(door, "Smash", 1)
		announce(door, SMASH_ONESHOT, {
			mode = "Smash",
			from = 1,
			to = 1,
			startAt = now,
			seconds = 0,
			ease = "Linear",
			smashFrom = door.smashFrom,
		}, false)
		return
	end
	begin(door, {
		mode = "Smash",
		from = 0,
		to = 1,
		startAt = now + GameConfig.OneShotLead,
		seconds = duration,
		ease = "Linear",
		smashFrom = door.smashFrom,
	}, SMASH_ONESHOT, false)
end

-- Stops a swing where the leaves stand (they would touch a player next).
local function hold(door: Door, now: number)
	door.motion = nil
	door.held = true
	door.clearSince = nil
	door.recheckAt = now + HELD_RECHECK
	stopLanding(door)
	announce(door, DOOR_ONESHOT, {
		mode = "Swing",
		from = door.openness,
		to = door.openness,
		startAt = now,
		seconds = 0,
		ease = "InOut",
		smashFrom = 0,
	}, true)
	log.debug("%s held at %.2f: someone is in the doorway", door.id, door.openness)
end

local function resume(door: Door, now: number)
	local from, target = door.openness, door.target
	local closing = target < from
	local duration = math.max(MIN_SECONDS, math.abs(target - from) / math.max(door.speed, EPSILON))
	begin(door, {
		mode = "Swing",
		from = from,
		to = target,
		startAt = now + GameConfig.OneShotLead,
		seconds = duration,
		ease = DoorService.easeFor(door.kind, "Swing", closing),
		smashFrom = 0,
	}, DOOR_ONESHOT, true)
end

local function land(door: Door, motion: Motion)
	door.motion = nil
	door.landing = nil
	moving[door] = nil
	if motion.mode == "Swing" and motion.to <= EPSILON and motion.from > EPSILON and SLAM_KINDS[door.kind] and live then
		NoiseAndDirectorService.Emit(centreOf(door), SLAM_NOISE, { levelId = door.levelId })
	end
end

local function stepDoor(door: Door, now: number)
	if door.model.Parent == nil then
		cancelMotion(door)
		return
	end
	if door.held then
		if now < door.recheckAt then
			return
		end
		door.recheckAt = now + HELD_RECHECK
		if obstructed(door, door.openness, door.target) then
			door.clearSince = nil
			return
		end
		local since = door.clearSince
		if since == nil then
			door.clearSince = now
		elseif now - since >= CLEAR_SECONDS then
			resume(door, now)
		end
		return
	end
	local motion = door.motion
	if motion == nil then
		moving[door] = nil
		return
	end
	if now < motion.startAt then
		return
	end
	if motion.mode == "Swing" then
		local horizon = math.min(now + LOOKAHEAD, DoorMotion.endsAt(motion))
		local ahead = DoorMotion.valueAt(motion, horizon)
		if obstructed(door, door.openness, ahead) then
			hold(door, now)
			return
		end
	end
	local value, done = DoorMotion.valueAt(motion, now)
	poseDoor(door, motion.mode, value)
	if done then
		land(door, motion)
	end
end

-- One Heartbeat step of every moving door at the clock's time (Start drives it; specs call it by hand).
function DoorService.StepMotions()
	local now = clock.now()
	for door in table.clone(moving) do
		stepDoor(door, now)
	end
end

--------------------------------------------------------------------------------
-- Tracking
--------------------------------------------------------------------------------

local function forget(model: Model)
	local door = doors[model]
	if not door then
		return
	end
	cancelMotion(door)
	doors[model] = nil
end

-- Starts managing a built fixture door and puts it in its initial state. False when the model is not a complete
-- fixture door. Tracking a door twice is harmless.
function DoorService.Track(model: Model): boolean
	if doors[model] then
		return true
	end
	local kind = model:GetAttribute(W.DoorKind)
	local id = model:GetAttribute(W.DoorId)
	if not (type(kind) == "string" and FIXTURE_KINDS[kind] and type(id) == "string" and model.PrimaryPart) then
		log.warn("%s is not a complete fixture door; left alone", model:GetFullName())
		return false
	end
	local doorKind: Enums.DoorKind = (kind :: any) :: Enums.DoorKind
	local scripted = model:GetAttribute(W.ScriptedId)
	local initial: Enums.DoorState = INITIAL_STATES[doorKind]
	local door: Door = {
		model = model,
		id = id,
		scriptedId = if type(scripted) == "string" then scripted else nil,
		kind = doorKind,
		levelId = levelAttribute(model, W.LevelId),
		fromLevel = levelAttribute(model, W.FromLevel),
		toLevel = levelAttribute(model, W.ToLevel),
		height = Attributes.getNumber(model, W.DoorHeight, DEFAULT_HEIGHT),
		state = initial,
		openness = DoorMotion.opennessOf(model),
		smash = 0,
		smashFrom = 0,
		motion = nil,
		held = false,
		target = 0,
		speed = 1,
		clearSince = nil,
		recheckAt = 0,
		motionId = 0,
		leaves = leafBoxes(model),
		landing = nil,
	}
	if initial ~= "Open" and door.openness > EPSILON then
		poseDoor(door, "Swing", 0)
	end
	door.target = door.openness
	Attributes.set(model, W.DoorState, initial)
	doors[model] = door
	return true
end

local function onDoorTagged(instance: Instance)
	if running and instance:IsA("Model") and instance.Parent ~= nil and inRuntime(instance) then
		DoorService.Track(instance)
	end
end

local function onDoorUntagged(instance: Instance)
	if instance:IsA("Model") and not (instance:HasTag(Tags.AirlockDoor) or instance:HasTag(Tags.ScriptedDoor)) then
		forget(instance)
	end
end

local function scan()
	for _, tag in { Tags.AirlockDoor, Tags.ScriptedDoor } do
		for _, instance in CollectionService:GetTagged(tag) do
			onDoorTagged(instance)
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Replaces the time source (specs pass a fake clock; nil restores server time).
function DoorService.SetClock(fake: Clock?)
	clock = fake or realClock
end

-- The door on `levelId` whose ScriptedId (HallwayGate, ClassroomDoor, RoofStairDoor) or DoorId is `id`.
function DoorService.Get(levelId: Enums.LevelId, id: string): Model?
	for model, door in doors do
		if door.levelId == levelId and (door.scriptedId == id or door.id == id) and model.Parent ~= nil then
			return model
		end
	end
	return nil
end

-- Every fixture door on `levelId`, by DoorId.
function DoorService.ForLevel(levelId: Enums.LevelId): { Model }
	local list: { Door } = {}
	for model, door in doors do
		if door.levelId == levelId and model.Parent ~= nil then
			table.insert(list, door)
		end
	end
	return sortedById(list)
end

-- The airlock fire doors of the stairwells leading out of or into `levelId` (FromLevel or ToLevel), by DoorId.
function DoorService.Airlocks(levelId: Enums.LevelId): { Model }
	local list: { Door } = {}
	for model, door in doors do
		if
			door.kind == "Airlock"
			and (door.fromLevel == levelId or door.toLevel == levelId)
			and model.Parent ~= nil
		then
			table.insert(list, door)
		end
	end
	return sortedById(list)
end

function DoorService.GetState(door: Model): Enums.DoorState
	local entry = doors[door]
	if entry then
		return entry.state
	end
	local value = door:GetAttribute(W.DoorState)
	if Enums.has(Enums.DoorState, value) then
		return (value :: any) :: Enums.DoorState
	end
	return "Open"
end

-- Changes a door's state and starts its motion (see the header). `seconds` = motion time (default per kind; 0 snaps).
-- False for an unknown door, a smashed door or a no-op.
function DoorService.SetState(door: Model, state: Enums.DoorState, seconds: number?): boolean
	local entry = doors[door]
	if not entry or not Enums.has(Enums.DoorState, state) then
		return false
	end
	local duration: number? = nil
	if seconds ~= nil and MathUtil.isFinite(seconds) then
		duration = math.max(0, seconds)
	end
	local plan: Plan, target: number? = DoorService.plan(entry.state, state)
	if plan == "Refuse" then
		return false
	end
	local previous: Enums.DoorState = entry.state
	entry.state = state
	Attributes.set(door, W.DoorState, state)
	if plan == "Swing" and target then
		swing(entry, target, duration)
	elseif plan == "Smash" then
		smash(entry, duration)
	end
	log.info("%s %s -> %s", entry.id, previous, state)
	stateChanged:Fire(door, previous, state)
	return true
end

-- The gameplay path to opening a door (a prompt, a mechanic): refused while it is Locked or Smashed.
function DoorService.RequestOpen(door: Model, seconds: number?): boolean
	local entry = doors[door]
	if not entry or entry.state == "Locked" or entry.state == "Smashed" then
		return false
	end
	return DoorService.SetState(door, "Open", seconds)
end

-- Whether the door's leaves are moving, or stopped short of a player waiting to finish.
function DoorService.IsMoving(door: Model): boolean
	local entry = doors[door]
	return entry ~= nil and (entry.motion ~= nil or entry.held)
end

-- Whether the door's motion is held short of a player.
function DoorService.IsHeld(door: Model): boolean
	local entry = doors[door]
	return entry ~= nil and entry.held
end

--------------------------------------------------------------------------------
-- Dev commands
--------------------------------------------------------------------------------

local function describe(model: Model): string
	local door = doors[model]
	if not door then
		return model.Name
	end
	local motion = if door.held then " (held)" elseif door.motion then " (moving)" else ""
	return string.format("%s %s%s", door.scriptedId or door.id, door.state, motion)
end

local function doorCommand(player: Player, args: { string }): string?
	local id, verb = args[1], args[2]
	local state: Enums.DoorState? = if verb then DOOR_STATES[string.lower(verb)] else nil
	if id == nil or state == nil then
		return "usage: door <ScriptedId|DoorId> <open|close|lock|smash> [seconds]"
	end
	local seconds = tonumber(args[3])
	local found: Model? = nil
	local level: Enums.LevelId? = playerLevel(player)
	if level then
		found = DoorService.Get(level, id)
	end
	if not found then
		for _, levelId: Enums.LevelId in Enums.LevelId do
			found = DoorService.Get(levelId, id)
			if found then
				break
			end
		end
	end
	if not found then
		return string.format("no door %q in this run", id)
	end
	if not DoorService.SetState(found, state, seconds) then
		return describe(found) .. ": unchanged"
	end
	return describe(found)
end

local function doorsCommand(player: Player, _args: { string }): string?
	local level: Enums.LevelId? = playerLevel(player)
	if not level then
		return "no run in progress"
	end
	local lines: { string } = {}
	for _, model in DoorService.ForLevel(level) do
		table.insert(lines, describe(model))
	end
	if #lines == 0 then
		return "no doors on " .. level
	end
	return level .. ": " .. table.concat(lines, ", ")
end

local function registerDevCommands()
	DevToolsService.Register(
		"door",
		"door <id> <open|close|lock|smash> [seconds]: drive a fixture door on your level",
		doorCommand
	)
	DevToolsService.Register("doors", "doors: the fixture doors on your level and their states", doorsCommand, true)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function onPhaseChanged(phase: Enums.MatchPhase)
	live = running and LIVE_PHASES[phase] == true
end

local function forgetAll()
	for model in table.clone(doors) do
		forget(model)
	end
	table.clear(moving)
end

function DoorService.Init()
	if initialized then
		return
	end
	initialized = true
	for _, tag in { Tags.AirlockDoor, Tags.ScriptedDoor } do
		serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(tag), onDoorTagged)
		serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(tag), onDoorUntagged)
	end
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(onPhaseChanged))
	registerDevCommands()
end

function DoorService.Start()
	serviceTrove:Connect(RunService.Heartbeat, function()
		if next(moving) == nil then
			return
		end
		xpcall(DoorService.StepMotions, function(err: any)
			log.warnThrottled("step", 10, "door motion failed: %s", tostring(err))
		end)
	end)
end

function DoorService.BeginRun(ctx: Types.RunContext)
	forgetAll()
	table.clear(participants)
	for _, player in ctx.participants do
		participants[player] = true
	end
	running = true
	live = true
	scan()
end

function DoorService.EndRun()
	running = false
	live = false
	forgetAll()
	table.clear(participants)
end

function DoorService.OnPlayerRemoving(player: Player)
	participants[player] = nil
end

return DoorService
