--!strict
-- InvestigateNoise: the Creature goes to where it believes a noise came from (Hearing's position: exact for loud
-- noises, blurred for quiet ones) at InvestigateNoise speed, then searches.
--
-- The search (searchPlan) works outward from the spot: a look around; the lockers of that room, nearest first (it
-- stands at each door, hunched, and peeks through the LockerInspector hook: "Caught" is a Locker jumpscare on the
-- occupant, "HiddenSafe" and "Empty" move on; without a hook it only looks); the room's open vent grates (it crouches
-- at the mouth and peers in: a crawler on that duct within PeerRange with a clear line from its eyes is spotted, and
-- the brain sends it after them); then up to two rooms through open doorways. A louder (or equally loud) noise
-- re-targets it; the search gives up after SearchSeconds. Nothing found ends the state (Patrol).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)

local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)

local Brain = require(script.Parent.Parent.Brain)
local Perception = require(script.Parent.Parent.Perception)

type Context = Brain.Context

export type StepKind = "Look" | "Locker" | "Grate" | "Room"

export type Step = {
	kind: StepKind,
	position: Vector3, -- where to stand (floor point)
	face: Vector3?, -- direction to look once there
	seconds: number,
	locker: Instance?,
	grateId: string?,
}

export type LockerSpot = { locker: Instance, front: CFrame } -- front: floor point before the door, facing away
export type GrateSpot = { grateId: string, stand: CFrame } -- stand: floor point before the opening, facing away

export type PlanInput = {
	at: Vector3,
	room: Brain.Room?,
	neighbours: { Brain.Room },
	lockers: { LockerSpot },
	grates: { GrateSpot },
	look: Vector3, -- the way it faced on arrival
}

type Phase = "Approach" | "Search"
type Stage = "Start" | "Travel" | "Hold"

type Inspection = { locker: Instance, started: number, verdict: Types.LockerVerdict? }

type Run = {
	investigation: Brain.Investigation?,
	phase: Phase,
	steps: { Step },
	index: number,
	stage: Stage,
	deadline: number,
	inspection: Inspection?,
}

local NAME: Enums.MonsterState = "InvestigateNoise"
local SEARCH_SECONDS = 35
local MAX_LOCKERS = 3
local MAX_GRATES = 2
local MAX_ROOMS = 2
local LOOK_SECONDS = 1.4
local LOCKER_SECONDS = 1.6
local PEER_SECONDS = 2.4
local ROOM_SECONDS = 1.3
local PEER_RANGE = 14
local ARRIVE = 3
local SPOT_ARRIVE = 1.2
local INSPECT_TIMEOUT = GameConfig.BreathHoldMaxSeconds + 4
local LOCKER_REACH = 8 -- a late "Caught" verdict still counts this close to the locker
local EXIT_ANCHOR = "ExitAnchor"

local InvestigateNoise = {}

InvestigateNoise.Name = NAME
InvestigateNoise.SearchSeconds = SEARCH_SECONDS
InvestigateNoise.PeerRange = PEER_RANGE

local runs: { [Context]: Run } = setmetatable({}, { __mode = "k" }) :: any

--------------------------------------------------------------------------------
-- Pure helpers
--------------------------------------------------------------------------------

local function byDistance<T>(list: { T }, at: Vector3, place: (T) -> Vector3): { T }
	local sorted = table.clone(list)
	table.sort(sorted, function(a: T, b: T): boolean
		return (place(a) - at).Magnitude < (place(b) - at).Magnitude
	end)
	return sorted
end

-- The search around `input.at`: look, lockers, grates, neighbouring rooms (see the header).
function InvestigateNoise.searchPlan(input: PlanInput): { Step }
	local steps: { Step } = {}
	local flatLook = MathUtil.flat(input.look)
	local back = if flatLook.Magnitude > 1e-3 then -flatLook.Unit else Vector3.new(0, 0, 1)
	table.insert(steps, { kind = "Look", position = input.at, face = back, seconds = LOOK_SECONDS })
	local lockers = byDistance(input.lockers, input.at, function(spot: LockerSpot): Vector3
		return spot.front.Position
	end)
	for index, spot in lockers do
		if index > MAX_LOCKERS then
			break
		end
		table.insert(steps, {
			kind = "Locker",
			position = spot.front.Position,
			face = -spot.front.LookVector,
			seconds = LOCKER_SECONDS,
			locker = spot.locker,
		})
	end
	local grates = byDistance(input.grates, input.at, function(spot: GrateSpot): Vector3
		return spot.stand.Position
	end)
	for index, spot in grates do
		if index > MAX_GRATES then
			break
		end
		table.insert(steps, {
			kind = "Grate",
			position = spot.stand.Position,
			face = -spot.stand.LookVector,
			seconds = PEER_SECONDS,
			grateId = spot.grateId,
		})
	end
	local rooms = byDistance(input.neighbours, input.at, function(room: Brain.Room): Vector3
		return room.centre
	end)
	for index, room in rooms do
		if index > MAX_ROOMS then
			break
		end
		table.insert(steps, { kind = "Room", position = room.centre, face = nil, seconds = ROOM_SECONDS })
	end
	return steps
end

-- Whether a crawler at `rail` is in view of a Creature peering into the grate on `grateNode` with mouth `mouth`.
function InvestigateNoise.peerSees(
	rail: VentGraph.RailPoint,
	grateNode: string,
	mouth: Vector3,
	lineClear: boolean
): boolean
	if not lineClear then
		return false
	end
	if rail.a ~= grateNode and rail.b ~= grateNode then
		return false
	end
	return (rail.position - mouth).Magnitude <= PEER_RANGE
end

--------------------------------------------------------------------------------
-- World reads
--------------------------------------------------------------------------------

local function lockersIn(levelId: string, zoneId: string): { LockerSpot }
	local runtime = Instances.runtime()
	local out: { LockerSpot } = {}
	if not runtime then
		return out
	end
	for _, locker in CollectionService:GetTagged(Tags.HideableLocker) do
		if not locker:IsDescendantOf(runtime) then
			continue
		end
		if
			Attributes.getString(locker, Attributes.World.LevelId, "") ~= levelId
			or Attributes.getString(locker, Attributes.World.ZoneId, "") ~= zoneId
		then
			continue
		end
		local anchor = PropKit.findAttachment(locker, EXIT_ANCHOR)
		if anchor then
			table.insert(out, { locker = locker, front = PropKit.attachmentWorld(anchor) })
		end
	end
	return out
end

local function gratesIn(ctx: Context, zoneId: string): { GrateSpot }
	local out: { GrateSpot } = {}
	local graph = ctx.graph
	if not graph then
		return out
	end
	for id, grate in graph.grates do
		local state = ctx.grateState(id)
		if grate.facingZoneId == zoneId and (state == "Open" or state == "Kicked") then
			table.insert(out, { grateId = id, stand = ctx.standPoint(grate) })
		end
	end
	return out
end

local function buildSearch(ctx: Context, at: Vector3): { Step }
	local level = ctx.level
	local room = if level then Brain.roomAt(level, at) else nil
	local neighbours: { Brain.Room } = {}
	local lockers: { LockerSpot } = {}
	local grates: { GrateSpot } = {}
	if level and room then
		for _, id in (level.neighbours[room.id] or {}) :: { string } do
			local other = level.rooms[id]
			if other and other.kind ~= "Chase" then
				table.insert(neighbours, other)
			end
		end
		lockers = lockersIn(level.levelId, room.id)
		grates = gratesIn(ctx, room.id)
	end
	return InvestigateNoise.searchPlan({
		at = at,
		room = room,
		neighbours = neighbours,
		lockers = lockers,
		grates = grates,
		look = ctx.body:GetCFrame().LookVector,
	})
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local function runOf(ctx: Context): Run
	local run = runs[ctx]
	if not run then
		run = {
			investigation = nil,
			phase = "Approach",
			steps = {},
			index = 1,
			stage = "Start",
			deadline = 0,
			inspection = nil,
		}
		runs[ctx] = run
	end
	return run
end

local function begin(ctx: Context, run: Run, investigation: Brain.Investigation?)
	run.investigation = investigation
	run.phase = "Approach"
	run.steps = {}
	run.index = 1
	run.stage = "Start"
	run.inspection = nil
	run.deadline = ctx.now() + SEARCH_SECONDS
	ctx.body:SetPose("Biped")
	local goal = if investigation then investigation.position else ctx.body:GetPosition()
	ctx.mover:GoTo(goal, { arrive = ARRIVE })
end

local function occupantOf(locker: Instance): Player?
	local userId = locker:GetAttribute(Attributes.World.OccupantUserId)
	if type(userId) ~= "number" then
		return nil
	end
	return Players:GetPlayerByUserId(userId)
end

-- Peeks into `locker` through the hook (in its own thread: a hiding player's breath check takes a while).
local function inspect(ctx: Context, run: Run, locker: Instance)
	local inspector = ctx.lockerInspector()
	if not inspector then
		return
	end
	local inspection: Inspection = { locker = locker, started = ctx.now(), verdict = nil }
	run.inspection = inspection
	local hook = inspector
	task.spawn(function()
		local ok, verdict = pcall(hook, locker)
		local result: Types.LockerVerdict = if ok and (verdict == "Caught" or verdict == "HiddenSafe")
			then verdict
			else "Empty"
		inspection.verdict = result
		if result ~= "Caught" then
			return
		end
		local occupant = occupantOf(locker)
		local front = PropKit.findAttachment(locker, EXIT_ANCHOR)
		local near = front ~= nil
			and (PropKit.attachmentWorld(front).Position - ctx.body:GetPosition()).Magnitude <= LOCKER_REACH
		if occupant and near then
			ctx.tryCatch(occupant, "Locker")
		end
	end)
end

-- While peering into grate `grateId`: any crawler in view is spotted.
local function peer(ctx: Context, grateId: string)
	local graph = ctx.graph
	local grate = if graph then graph.grates[grateId] else nil
	if not grate then
		return
	end
	local eye = Perception.creatureEye(ctx.creature)
	for _, player in ctx.ventOccupants() do
		local rail = ctx.railPointOf(player)
		local playerEye = Perception.playerEye(player)
		if
			rail
			and playerEye
			and InvestigateNoise.peerSees(rail, grate.nodeId, grate.mouth, ctx.lineClear(eye, playerEye))
		then
			ctx.noteSpotted(player)
		end
	end
end

local function nextStep(ctx: Context, run: Run)
	run.index += 1
	run.stage = "Start"
	run.inspection = nil
	ctx.body:SetPose("Biped")
end

-- At the step's spot: look, peek (with the inspector) or peer, for the step's beat.
local function startHold(ctx: Context, run: Run, step: Step)
	run.stage = "Hold"
	if step.kind == "Locker" or step.kind == "Grate" then
		ctx.body:SetPose("Hunched")
	end
	ctx.mover:Hold(step.seconds, step.face)
	local locker = step.locker
	if step.kind == "Locker" and locker then
		inspect(ctx, run, locker)
	end
end

function InvestigateNoise.enter(ctx: Context, _from: Enums.MonsterState)
	local speed = ctx.speedOf(NAME)
	ctx.mover:SetSpeed(speed)
	ctx.body:SetWalkSpeed(speed)
	ctx.mover:SetRepathInterval(CreatureConfig.Repath.PatrolInterval / 2)
	ctx.body:Face(nil)
	begin(ctx, runOf(ctx), ctx.investigation)
end

function InvestigateNoise.update(ctx: Context, _dt: number)
	local run = runOf(ctx)
	local current = run.investigation
	local heard = ctx.heard
	if heard and (current == nil or heard.rank >= current.rank or run.phase == "Search") then
		local fresh: Brain.Investigation = { position = heard.position, rank = heard.rank, at = heard.at }
		ctx.investigation = fresh
		begin(ctx, run, fresh)
		return
	end
	if ctx.now() > run.deadline then
		ctx.stateDone = true
		return
	end
	local mover = ctx.mover
	local busy = mover:Busy()
	local status = mover:Status()
	if run.phase == "Approach" then
		if busy or status == "Moving" then
			return
		end
		run.phase = "Search"
		local at = if status == "Idle" and current then current.position else ctx.body:GetPosition()
		run.steps = buildSearch(ctx, at)
		run.index = 1
		run.stage = "Start"
		return
	end
	local step = run.steps[run.index]
	if not step then
		ctx.stateDone = true
		return
	end
	if run.stage == "Start" then
		if busy then
			return
		end
		if step.kind == "Look" then
			startHold(ctx, run, step)
		else
			run.stage = "Travel"
			mover:GoTo(step.position, { arrive = if step.kind == "Room" then ARRIVE else SPOT_ARRIVE })
		end
		return
	end
	if run.stage == "Travel" then
		if busy or status == "Moving" then
			return
		end
		if status == "Failed" or status == "Stuck" then
			nextStep(ctx, run)
			return
		end
		startHold(ctx, run, step)
		return
	end
	local grateId = step.grateId
	if step.kind == "Grate" and grateId then
		peer(ctx, grateId)
	end
	local inspection = run.inspection
	if inspection and inspection.verdict == nil and ctx.now() - inspection.started < INSPECT_TIMEOUT then
		return
	end
	if busy then
		return
	end
	nextStep(ctx, run)
end

function InvestigateNoise.exit(ctx: Context, _to: Enums.MonsterState)
	local run = runOf(ctx)
	run.inspection = nil
	ctx.body:SetPose("Biped")
	ctx.body:Face(nil)
	ctx.investigation = nil
end

return table.freeze(InvestigateNoise)
